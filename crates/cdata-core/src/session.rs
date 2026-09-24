//! 会话层：连接和结果集都常驻这里，界面只按窗口取行。
//!
//! 十万行结果集留在 Rust 侧，Dart 侧任何时候只持有可视区的两百来行。
//! 这是 FFI 契约的核心：**不要把整个结果集搬过 FFI**。

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

use mysql_async::prelude::Queryable;
use mysql_async::Pool;

use crate::db::{open_pool, run_query, ColumnMeta, ConnectionConfig, ResultSet};
use crate::edit::{build_update, detect_editability, Editability};
use crate::value::CellValue;

#[derive(Debug)]
pub enum Error {
    /// 会话不存在，通常是界面拿着已关闭的 id 继续用
    NoSuchSession(u64),
    /// 会话还没跑过查询
    NoResult(u64),
    Mysql(String),
    /// 结果集不可编辑，附带具体原因
    NotEditable(String),
    /// 写回没有按预期生效
    EditFailed(String),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::NoSuchSession(id) => write!(f, "会话 {id} 不存在"),
            Error::NoResult(id) => write!(f, "会话 {id} 还没有查询结果"),
            Error::Mysql(message) => write!(f, "MySQL 错误：{message}"),
            Error::NotEditable(reason) => write!(f, "{reason}"),
            Error::EditFailed(reason) => write!(f, "{reason}"),
        }
    }
}

impl std::error::Error for Error {}

impl From<mysql_async::Error> for Error {
    fn from(err: mysql_async::Error) -> Self {
        Error::Mysql(err.to_string())
    }
}

pub type Result<T> = std::result::Result<T, Error>;

/// 一次查询的概况。行数据不在这里，要按窗口单独取
#[derive(Debug, Clone)]
pub struct QuerySummary {
    pub columns: Vec<ColumnMeta>,
    pub total_rows: u64,
    /// 达到上限被截断，界面必须显式提示
    pub truncated: bool,
    /// 能不能编辑。不能的话带着原因，界面要显示出来而不是闷着禁用
    pub editability: Editability,
}

struct Session {
    pool: Pool,
    result: Option<ResultSet>,
    editability: Option<Editability>,
}

struct Store {
    sessions: HashMap<u64, Session>,
    next_id: u64,
}

fn store() -> &'static Mutex<Store> {
    static STORE: OnceLock<Mutex<Store>> = OnceLock::new();
    STORE.get_or_init(|| {
        Mutex::new(Store {
            sessions: HashMap::new(),
            next_id: 1,
        })
    })
}

/// 开一个会话。这里只建池，真正的 TCP 连接等到第一次查询才发生
pub fn open_session(config: &ConnectionConfig) -> u64 {
    let pool = open_pool(config);

    let mut guard = store().lock().unwrap();
    let id = guard.next_id;
    guard.next_id += 1;
    guard.sessions.insert(
        id,
        Session {
            pool,
            result: None,
            editability: None,
        },
    );
    id
}

/// 跑查询并把结果留在会话里，只回概况
pub async fn execute(session_id: u64, sql: &str, max_rows: usize) -> Result<QuerySummary> {
    // 先把池克隆出来再释放锁，避免把锁持过 await
    let pool = {
        let guard = store().lock().unwrap();
        let session = guard
            .sessions
            .get(&session_id)
            .ok_or(Error::NoSuchSession(session_id))?;
        session.pool.clone()
    };

    let result = run_query(&pool, sql, max_rows).await?;
    let editability = detect_editability(&pool, &result.columns).await;

    let summary = QuerySummary {
        columns: result.columns.clone(),
        total_rows: result.rows.len() as u64,
        truncated: result.truncated,
        editability: editability.clone(),
    };

    let mut guard = store().lock().unwrap();
    let session = guard
        .sessions
        .get_mut(&session_id)
        .ok_or(Error::NoSuchSession(session_id))?;
    session.result = Some(result);
    session.editability = Some(editability);

    Ok(summary)
}

/// 取一段行。越界不报错，返回实际拿得到的部分，界面按返回长度渲染
pub fn fetch_window(session_id: u64, offset: u64, limit: u64) -> Result<Vec<Vec<CellValue>>> {
    let guard = store().lock().unwrap();
    let session = guard
        .sessions
        .get(&session_id)
        .ok_or(Error::NoSuchSession(session_id))?;
    let result = session.result.as_ref().ok_or(Error::NoResult(session_id))?;

    let start = (offset as usize).min(result.rows.len());
    let end = start.saturating_add(limit as usize).min(result.rows.len());

    Ok(result.rows[start..end].to_vec())
}

/// 取一段行的**显示文本**，供网格渲染。
///
/// 和 fetch_window 是两个场景，刻意分开：渲染要的是一屏文本、一次调用；
/// 编辑要的是单个单元格的原始值。合成一个接口会让每屏都多传一份用不上的数据，
/// 而按单元格调 FFI 拿文本又会把调用次数放大到几千次。
pub fn fetch_window_text(session_id: u64, offset: u64, limit: u64) -> Result<Vec<Vec<String>>> {
    let rows = fetch_window(session_id, offset, limit)?;

    let mut out = Vec::with_capacity(rows.len());
    for row in &rows {
        let mut texts = Vec::with_capacity(row.len());
        for cell in row {
            texts.push(crate::value::display_text(cell));
        }
        out.push(texts);
    }
    Ok(out)
}

/// 会话所在服务器的库列表
pub async fn list_databases(session_id: u64) -> Result<Vec<String>> {
    let pool = pool_of(session_id)?;
    Ok(crate::schema::list_databases(&pool).await?)
}

/// 某个库的表和视图
pub async fn list_tables(session_id: u64, database: &str) -> Result<Vec<crate::schema::TableInfo>> {
    let pool = pool_of(session_id)?;
    Ok(crate::schema::list_tables(&pool, database).await?)
}

/// 取会话的连接池并立刻释放锁，不把锁持过 await
fn pool_of(session_id: u64) -> Result<Pool> {
    let guard = store().lock().unwrap();
    let session = guard
        .sessions
        .get(&session_id)
        .ok_or(Error::NoSuchSession(session_id))?;
    Ok(session.pool.clone())
}

/// 改一个单元格并写回数据库。
///
/// 值没变就不发 SQL —— 这样 affected_rows 为 0 就一定是定位失败，而不是
/// 「MySQL 对相同值不计数」的歧义。写回成功后同步更新本地缓存，
/// 否则界面显示的还是旧值。
pub async fn apply_edit(
    session_id: u64,
    row_index: u64,
    column_index: u64,
    new_value: CellValue,
) -> Result<()> {
    let row_index = row_index as usize;
    let column_index = column_index as usize;

    // 需要的东西一次取齐再释放锁，不把锁持过 await
    let (pool, target, columns, row) = {
        let guard = store().lock().unwrap();
        let session = guard
            .sessions
            .get(&session_id)
            .ok_or(Error::NoSuchSession(session_id))?;
        let result = session.result.as_ref().ok_or(Error::NoResult(session_id))?;

        let target = match session.editability.as_ref() {
            Some(Editability::Editable(target)) => target.clone(),
            Some(Editability::ReadOnly(reason)) => {
                return Err(Error::NotEditable(reason.clone()))
            }
            None => return Err(Error::NoResult(session_id)),
        };

        let row = result
            .rows
            .get(row_index)
            .ok_or_else(|| Error::EditFailed(format!("行下标 {row_index} 越界")))?
            .clone();

        (session.pool.clone(), target, result.columns.clone(), row)
    };

    let old_value = row
        .get(column_index)
        .ok_or_else(|| Error::EditFailed(format!("列下标 {column_index} 越界")))?;
    if old_value == &new_value {
        return Ok(());
    }

    let statement = build_update(&target, &columns, &row, column_index, &new_value)
        .map_err(Error::NotEditable)?;

    let mut conn = pool.get_conn().await?;
    conn.exec_drop(&statement.sql, statement.params).await?;
    let affected = conn.affected_rows();

    if affected != 1 {
        return Err(Error::EditFailed(format!(
            "预期影响 1 行，实际 {affected} 行，改动可能没有生效或定位到了错误的行"
        )));
    }

    let mut guard = store().lock().unwrap();
    let session = guard
        .sessions
        .get_mut(&session_id)
        .ok_or(Error::NoSuchSession(session_id))?;
    let result = session
        .result
        .as_mut()
        .ok_or(Error::NoResult(session_id))?;
    result.rows[row_index][column_index] = new_value;

    Ok(())
}

/// 关会话并断开连接池。界面关标签页时必须调，否则连接一直挂着
pub async fn close_session(session_id: u64) -> Result<()> {
    let session = {
        let mut guard = store().lock().unwrap();
        guard
            .sessions
            .remove(&session_id)
            .ok_or(Error::NoSuchSession(session_id))?
    };

    session.pool.disconnect().await?;
    Ok(())
}
