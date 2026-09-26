//! 会话层：连接和结果集都常驻这里，界面只按窗口取行。
//!
//! 十万行结果集留在 Rust 侧，Dart 侧任何时候只持有可视区的两百来行。
//! 这是 FFI 契约的核心：**不要把整个结果集搬过 FFI**。

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

use mysql_async::prelude::Queryable;
use mysql_async::TxOpts;

use crate::db::{
    open_pool, run_query_with_params, run_script, ColumnMeta, ConnectFailed, ConnectionConfig, DbPool, OpenError,
    QueryTimedOut, ResultSet,
};
use crate::sql::{build_view, FilterCondition};
use crate::edit::{
    build_delete, build_insert, build_select_by_key, build_update, detect_editability,
    is_auto_increment, EditTarget, Editability,
};
use crate::value::{CellValue, DisplayCell};

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
    /// 界面给的参数不对：选区越界、剪贴板格式不规整、筛选条件缺列、连接选项说不通
    BadInput(String),
    /// 取连接时就失败了（连不上、连接超时、隧道建不起来）。语句还没发出去，肯定没执行
    Connect(String),
    /// 语句发出去之后连接断了。**可能执行了也可能没执行**，不自动重试
    ConnectionLost(String),
    /// 查询超时，已经尝试让服务器停掉
    QueryTimeout(String),
    /// SSH 隧道建不起来。主机密钥的问题带着指纹，界面可以据此问用户
    Ssh(crate::ssh::Error),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::NoSuchSession(id) => write!(f, "会话 {id} 不存在"),
            Error::NoResult(id) => write!(f, "会话 {id} 还没有查询结果"),
            Error::Mysql(message) => write!(f, "MySQL 错误：{message}"),
            Error::NotEditable(reason) => write!(f, "{reason}"),
            Error::EditFailed(reason) => write!(f, "{reason}"),
            Error::BadInput(reason) => write!(f, "{reason}"),
            Error::Connect(reason) => write!(f, "{reason}（语句还没有发出，没有执行）"),
            Error::ConnectionLost(reason) => write!(
                f,
                "连接断开了（{reason}）。这条语句可能已经执行，也可能没有执行，请确认后再决定是否重跑；\
                 下一次操作会自动重新连接"
            ),
            Error::QueryTimeout(reason) => write!(f, "{reason}"),
            Error::Ssh(err) => write!(f, "{err}"),
        }
    }
}

impl std::error::Error for Error {}

impl Error {
    /// 主机密钥没通过校验时的详情。未知主机可以让用户确认指纹后调 ssh::trust_host_key
    pub fn host_key_issue(&self) -> Option<&crate::ssh::HostKeyIssue> {
        match self {
            Error::Ssh(crate::ssh::Error::HostKey(issue)) => Some(issue),
            _ => None,
        }
    }
}

/// 服务器主动断开连接时发来的错误码：
/// 1053 服务器正在关闭，4031 闲置太久被服务器断开，3169 会话被 KILL（MySQL 8），1927 连接被 KILL（MariaDB）
pub(crate) const CONNECTION_GONE_CODES: [u16; 4] = [1053, 4031, 3169, 1927];

impl From<mysql_async::Error> for Error {
    /// 按「语句有没有可能执行」分类：取连接时的失败、执行中断线、超时、其余的 MySQL 错误
    fn from(err: mysql_async::Error) -> Self {
        match err {
            mysql_async::Error::Other(inner) => {
                let inner = match inner.downcast::<ConnectFailed>() {
                    Ok(failed) => return Error::Connect(failed.to_string()),
                    Err(other) => other,
                };
                match inner.downcast::<QueryTimedOut>() {
                    Ok(timed_out) => Error::QueryTimeout(timed_out.to_string()),
                    Err(other) => Error::Mysql(other.to_string()),
                }
            }
            mysql_async::Error::Io(io) => Error::ConnectionLost(io.to_string()),
            mysql_async::Error::Driver(mysql_async::DriverError::ConnectionClosed) => {
                Error::ConnectionLost("服务器关闭了连接".to_string())
            }
            mysql_async::Error::Server(server) if CONNECTION_GONE_CODES.contains(&server.code) => {
                Error::ConnectionLost(server.to_string())
            }
            other => Error::Mysql(other.to_string()),
        }
    }
}

impl From<OpenError> for Error {
    fn from(err: OpenError) -> Self {
        match err {
            OpenError::BadOptions(reason) => Error::BadInput(reason),
            OpenError::Ssh(err) => Error::Ssh(err),
        }
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
    /// 记列宽列序用的键。结果集不是来自单张表时为 None，不记
    pub layout_key: Option<String>,
}

struct Session {
    pool: DbPool,
    /// host:port（走 SSH 时带上隧道出口），拼布局键用
    server: String,
    result: Option<ResultSet>,
    editability: Option<Editability>,
    /// 补全用的库表列目录。load_catalog 之后才有
    catalog: crate::complete::Catalog,
    /// 多语句脚本和执行计划的每个结果集各放一个子会话，和父会话共用连接池。
    /// 这样取行、编辑、导出、复制都按会话 id 走原来的接口，不用再加一个「第几个结果」的参数
    children: Vec<u64>,
    /// 子会话的父会话。子会话不拥有连接池，关的时候不断开
    parent: Option<u64>,
}

/// 脚本里一条语句的结果
#[derive(Debug, Clone)]
pub struct StatementOutcome {
    pub sql: String,
    /// 有结果集的语句：结果在这个子会话里。INSERT / UPDATE 这类没有结果集，是 None
    pub session_id: Option<u64>,
    pub summary: Option<QuerySummary>,
    pub affected_rows: u64,
}

/// 脚本在第几条（从 0 数）失败。它前面的语句都已经执行，DDL 和自动提交的写入撤不回来
#[derive(Debug, Clone)]
pub struct StatementFailure {
    pub index: u32,
    pub sql: String,
    pub message: String,
}

#[derive(Debug, Clone)]
pub struct ScriptSummary {
    pub outcomes: Vec<StatementOutcome>,
    pub failure: Option<StatementFailure>,
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

/// 开一个会话。直连时只建池，真正的 TCP 连接等到第一次查询才发生；
/// 走 SSH 时当场建隧道，主机密钥和认证的问题在这里就报出来
pub async fn open_session(config: &ConnectionConfig) -> Result<u64> {
    let pool = open_pool(config).await?;
    // 走隧道时 host:port 是从 SSH 服务器看过去的地址，常常就是 127.0.0.1:3306，
    // 不带上隧道出口的话会和本机库的列布局混在一起
    let server = match config.options.ssh.hops.last() {
        Some(exit) => format!("{}:{} via {}", config.host, config.port, exit.label()),
        None => format!("{}:{}", config.host, config.port),
    };

    let mut guard = store().lock().unwrap();
    let id = guard.next_id;
    guard.next_id += 1;
    guard.sessions.insert(
        id,
        Session {
            pool,
            server,
            result: None,
            editability: None,
            catalog: crate::complete::Catalog::default(),
            children: Vec::new(),
            parent: None,
        },
    );
    Ok(id)
}

/// 按顺序跑一段多语句 SQL，全部在同一条连接上。先清掉这个会话上一轮的子结果
pub async fn execute_script(session_id: u64, sql: &str, max_rows: usize) -> Result<ScriptSummary> {
    let statements = crate::script::split_statements(sql).map_err(Error::BadInput)?;
    if statements.is_empty() {
        return Err(Error::BadInput("没有可执行的语句".to_string()));
    }

    drop_child_results(session_id)?;
    let (pool, server) = session_pool(session_id)?;
    let run = run_script(&pool, &statements, max_rows).await?;

    let mut outcomes = Vec::with_capacity(run.results.len());
    for (index, result) in run.results.into_iter().enumerate() {
        outcomes.push(add_outcome(session_id, &pool, &server, statements[index].clone(), result).await?);
    }

    let failure = run.failure.map(|(index, err)| StatementFailure {
        index: index as u32,
        sql: statements[index].clone(),
        message: Error::from(err).to_string(),
    });
    Ok(ScriptSummary { outcomes, failure })
}

/// 看一条语句的执行计划，结果作为一个子结果。普通 EXPLAIN 不执行语句本身
pub async fn explain(session_id: u64, sql: &str, max_rows: usize) -> Result<StatementOutcome> {
    let statement = crate::script::explain_sql(sql).map_err(Error::BadInput)?;
    let (pool, server) = session_pool(session_id)?;
    let result = run_query_with_params(&pool, &statement, Vec::new(), max_rows).await?;
    add_outcome(session_id, &pool, &server, statement, result).await
}

/// 关掉这个会话挂着的子结果。界面开始新一轮运行时调，旧的结果标签随之作废
pub fn drop_child_results(session_id: u64) -> Result<()> {
    let mut guard = store().lock().unwrap();
    let session = guard
        .sessions
        .get_mut(&session_id)
        .ok_or(Error::NoSuchSession(session_id))?;
    let children = std::mem::take(&mut session.children);
    for child in children {
        guard.sessions.remove(&child);
    }
    Ok(())
}

fn session_pool(session_id: u64) -> Result<(DbPool, String)> {
    let guard = store().lock().unwrap();
    let session = guard
        .sessions
        .get(&session_id)
        .ok_or(Error::NoSuchSession(session_id))?;
    Ok((session.pool.clone(), session.server.clone()))
}

/// 有结果集的放进一个新的子会话；没有结果集的只记影响行数
async fn add_outcome(
    parent_id: u64,
    pool: &DbPool,
    server: &str,
    sql: String,
    result: ResultSet,
) -> Result<StatementOutcome> {
    let affected_rows = result.affected_rows;
    if result.columns.is_empty() {
        return Ok(StatementOutcome { sql, session_id: None, summary: None, affected_rows });
    }

    let (summary, editability) = summarize(pool, server, &result).await;
    let mut guard = store().lock().unwrap();
    // 父会话在执行期间被关掉了，结果没处挂，直接报错
    if !guard.sessions.contains_key(&parent_id) {
        return Err(Error::NoSuchSession(parent_id));
    }
    let id = guard.next_id;
    guard.next_id += 1;
    guard.sessions.insert(
        id,
        Session {
            pool: pool.clone(),
            server: server.to_string(),
            result: Some(result),
            editability: Some(editability),
            catalog: crate::complete::Catalog::default(),
            children: Vec::new(),
            parent: Some(parent_id),
        },
    );
    guard.sessions.get_mut(&parent_id).unwrap().children.push(id);
    Ok(StatementOutcome { sql, session_id: Some(id), summary: Some(summary), affected_rows })
}

async fn summarize(pool: &DbPool, server: &str, result: &ResultSet) -> (QuerySummary, Editability) {
    let editability = detect_editability(pool, &result.columns).await;
    let summary = QuerySummary {
        columns: result.columns.clone(),
        total_rows: result.rows.len() as u64,
        truncated: result.truncated,
        editability: editability.clone(),
        layout_key: crate::layouts::layout_key(server, &result.columns),
    };
    (summary, editability)
}

/// 跑查询并把结果留在会话里，只回概况
pub async fn execute(session_id: u64, sql: &str, max_rows: usize) -> Result<QuerySummary> {
    execute_statement(session_id, sql, Vec::new(), max_rows).await
}

/// 在原查询上套筛选和排序再跑。条件的值走参数化，SQL 由 core 生成
pub async fn execute_view(
    session_id: u64,
    sql: &str,
    conditions: &[FilterCondition],
    match_all: bool,
    sort: Option<(&str, bool)>,
    max_rows: usize,
) -> Result<QuerySummary> {
    let statement = build_view(sql, conditions, match_all, sort).map_err(Error::BadInput)?;
    execute_statement(session_id, &statement.sql, statement.params, max_rows).await
}

async fn execute_statement(
    session_id: u64,
    sql: &str,
    params: Vec<mysql_async::Value>,
    max_rows: usize,
) -> Result<QuerySummary> {
    // 先把池克隆出来再释放锁，避免把锁持过 await
    let (pool, server) = session_pool(session_id)?;

    let result = run_query_with_params(&pool, sql, params, max_rows).await?;
    let (summary, editability) = summarize(&pool, &server, &result).await;

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
pub fn fetch_window_text(session_id: u64, offset: u64, limit: u64) -> Result<Vec<Vec<DisplayCell>>> {
    let rows = fetch_window(session_id, offset, limit)?;

    let mut out = Vec::with_capacity(rows.len());
    for row in &rows {
        let mut texts = Vec::with_capacity(row.len());
        for cell in row {
            texts.push(crate::value::display_cell(cell));
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

/// 把结果集的一段导出成文件。row_count 为 None 表示从 row_start 到末尾。
///
/// 导出的是会话里缓存的这份结果：包括当前的筛选和排序，也包括它的截断状态 ——
/// 截断过的结果导出去也是不完整的，summary 里要带上，界面必须说清楚。
pub fn export_rows(
    session_id: u64,
    path: &str,
    row_start: u64,
    row_count: Option<u64>,
    column_indexes: Vec<u64>,
    options: &crate::export::ExportOptions,
) -> Result<crate::export::ExportSummary> {
    let guard = store().lock().unwrap();
    let session = guard
        .sessions
        .get(&session_id)
        .ok_or(Error::NoSuchSession(session_id))?;
    let result = session.result.as_ref().ok_or(Error::NoResult(session_id))?;

    let start = row_start as usize;
    let end = match row_count {
        Some(count) => start.saturating_add(count as usize),
        None => result.rows.len(),
    };
    if start > end || end > result.rows.len() {
        return Err(Error::BadInput(format!(
            "导出区域到第 {end} 行，结果集只有 {} 行",
            result.rows.len()
        )));
    }

    let mut columns = Vec::with_capacity(column_indexes.len());
    for index in column_indexes {
        columns.push(index as usize);
    }

    // ponytail: 写文件时一直持着会话锁，十万行几百毫秒；更大的量再改成先拷一份行再释放锁
    let rows_written = crate::export::write_file(
        std::path::Path::new(path),
        &result.columns,
        &result.rows[start..end],
        &columns,
        options,
    )
    .map_err(Error::BadInput)?;

    Ok(crate::export::ExportSummary { rows_written, source_truncated: result.truncated })
}

/// 结果集某一列的 ENUM / SET 可选值，按定义顺序。
/// 要知道来源表才查得到，表达式列、JOIN 里看不出来源的列直接报错
pub async fn column_choices(session_id: u64, column_index: u64) -> Result<Vec<String>> {
    let (pool, column) = {
        let guard = store().lock().unwrap();
        let session = guard
            .sessions
            .get(&session_id)
            .ok_or(Error::NoSuchSession(session_id))?;
        let result = session.result.as_ref().ok_or(Error::NoResult(session_id))?;
        let column = result
            .columns
            .get(column_index as usize)
            .ok_or_else(|| Error::BadInput(format!("列下标 {column_index} 越界")))?
            .clone();
        (session.pool.clone(), column)
    };

    if column.org_table.is_empty() {
        return Err(Error::BadInput(format!("列 {} 不是直接来自某张表，读不到可选值", column.name)));
    }
    crate::structure::column_choices(&pool, &column.schema, &column.org_table, &column.org_name)
        .await?
        .ok_or_else(|| Error::BadInput(format!("列 {} 不是 ENUM / SET", column.name)))
}

/// 读一个库的表和列放进会话，给补全用。返回表的数量。
///
/// 一条 information_schema 查询取齐，不按表逐个查
pub async fn load_catalog(session_id: u64, database: &str) -> Result<u64> {
    let pool = pool_of(session_id)?;
    let mut conn = pool.get_conn().await?;
    let rows: Vec<(String, String)> = conn
        .exec(
            "SELECT TABLE_NAME, COLUMN_NAME FROM information_schema.COLUMNS \
             WHERE TABLE_SCHEMA = ? ORDER BY TABLE_NAME, ORDINAL_POSITION",
            (database,),
        )
        .await?;
    drop(conn);

    let mut catalog = crate::complete::Catalog::default();
    for (table, column) in rows {
        match catalog.tables.last_mut() {
            Some(last) if last.name == table => last.columns.push(column),
            _ => catalog.tables.push(crate::complete::CatalogTable { name: table, columns: vec![column] }),
        }
    }
    let count = catalog.tables.len() as u64;

    let mut guard = store().lock().unwrap();
    let session = guard
        .sessions
        .get_mut(&session_id)
        .ok_or(Error::NoSuchSession(session_id))?;
    session.catalog = catalog;
    Ok(count)
}

/// 补全。纯计算，读的是 load_catalog 缓存的目录，不访问数据库；没加载过就只有关键字
pub fn complete_sql(session_id: u64, sql: &str, cursor: u32) -> Result<crate::complete::Completion> {
    let guard = store().lock().unwrap();
    let session = guard
        .sessions
        .get(&session_id)
        .ok_or(Error::NoSuchSession(session_id))?;
    Ok(crate::complete::complete(sql, cursor, &session.catalog))
}

/// 一张表的列、索引、外键和建表语句
pub async fn table_structure(
    session_id: u64,
    database: &str,
    table: &str,
) -> Result<crate::structure::TableStructure> {
    let pool = pool_of(session_id)?;
    Ok(crate::structure::table_structure(&pool, database, table).await?)
}

/// 预览一批表结构改动：生成的语句、危险操作、执行须知。
///
/// 可空改成 NOT NULL 的列当场数一次现有的 NULL，数出来的行数放进危险提示
pub async fn preview_alter(
    session_id: u64,
    database: &str,
    table: &str,
    original: &crate::structure::TableStructure,
    draft: &crate::alter::TableDraft,
) -> Result<crate::alter::AlterPlan> {
    let pool = pool_of(session_id)?;
    let mut conn = pool.get_conn().await?;
    let (mut plan, not_null_columns) = plan_alter_on(&mut conn, database, table, original, draft).await?;

    for column in not_null_columns {
        let sql = format!(
            "SELECT COUNT(*) FROM {}.{} WHERE {} IS NULL",
            crate::sql::quote_ident(database),
            crate::sql::quote_ident(table),
            crate::sql::quote_ident(&column)
        );
        let nulls: u64 = conn.query_first(sql).await?.unwrap_or(0);
        if nulls > 0 {
            plan.dangers.push(format!(
                "列 {column} 改成 NOT NULL，现有 {nulls} 行是 NULL：严格模式下这次 ALTER 会失败；\
                 非严格模式下这些 NULL 会被改成该类型的零值（0、''、零日期）"
            ));
        } else {
            plan.notes.push(format!("列 {column} 改成 NOT NULL：刚查过，现在没有 NULL 值"));
        }
    }
    Ok(plan)
}

/// 执行预览过的改动。在同一条连接上重新核对结构、按这条连接的 sql_mode 重新生成，
/// 和预览时的语句不一致就不执行
pub async fn apply_alter(
    session_id: u64,
    database: &str,
    table: &str,
    original: &crate::structure::TableStructure,
    draft: &crate::alter::TableDraft,
    previewed: &[String],
) -> Result<()> {
    let pool = pool_of(session_id)?;
    let mut conn = pool.get_conn().await?;
    let (plan, _) = plan_alter_on(&mut conn, database, table, original, draft).await?;
    if plan.statements != previewed {
        return Err(Error::BadInput(
            "要执行的语句和预览时不一样了（表结构或 sql_mode 变了），请重新预览".to_string(),
        ));
    }

    run_planned(&mut conn, &plan.statements).await
}

/// 按顺序执行一批 DDL。失败时说清楚第几条失败、这一条和前面的生效了没有
async fn run_planned(conn: &mut mysql_async::Conn, statements: &[String]) -> Result<()> {
    let total = statements.len();
    crate::alter::run_statements(conn, statements).await.map_err(|(index, err)| {
        let err = Error::from(err);
        let this_one = if matches!(err, Error::ConnectionLost(_)) {
            "这一条可能已经生效也可能没有，请重新读取结构确认"
        } else {
            "这一条没有生效"
        };
        let before = if index == 0 {
            "前面没有已执行的语句".to_string()
        } else {
            format!("前 {index} 条已经生效，不会回滚")
        };
        Error::EditFailed(format!("第 {} 条（共 {total} 条）执行失败：{err}。{this_one}；{before}", index + 1))
    })
}

/// 核对版本和结构，读这条连接的 sql_mode，生成语句
async fn plan_alter_on(
    conn: &mut mysql_async::Conn,
    database: &str,
    table: &str,
    original: &crate::structure::TableStructure,
    draft: &crate::alter::TableDraft,
) -> Result<(crate::alter::AlterPlan, Vec<String>)> {
    let version: String = conn.query_first("SELECT VERSION()").await?.unwrap_or_default();
    if !crate::alter::supports_alter(&version) {
        return Err(Error::BadInput(format!(
            "结构编辑只支持 MySQL 8.0.13 及以上（当前 {version}）：更早的版本和 MariaDB 读出来的默认值规则不同，\
             没法保证改列时原样带上原有定义"
        )));
    }

    // 编辑器打开之后别人改过表的话，照旧草稿 MODIFY 会把别人的改动覆盖回去
    let fresh = crate::structure::read_structure(conn, database, table).await?;
    if !fresh.create_sql.starts_with("CREATE TABLE") {
        return Err(Error::BadInput("只有普通表能用结构编辑器修改，视图请直接写 SQL".to_string()));
    }
    // AUTO_INCREMENT 每次插入都会变，不算结构改动；草稿里的自增值是「要设成多少」，不和它比
    if fresh.columns != original.columns
        || fresh.indexes != original.indexes
        || fresh.foreign_keys != original.foreign_keys
        || fresh.checks != original.checks
        || fresh.engine != original.engine
        || fresh.table_charset != original.table_charset
        || fresh.table_collation != original.table_collation
        || fresh.table_comment != original.table_comment
        || fresh.row_format != original.row_format
    {
        return Err(Error::BadInput(
            "表结构在打开编辑器之后被改过，请关掉编辑器重新打开，免得把别人的改动覆盖回去".to_string(),
        ));
    }

    let no_backslash_escapes = no_backslash_escapes(conn).await?;
    crate::alter::plan_alter(database, table, &fresh, draft, no_backslash_escapes).map_err(Error::BadInput)
}

/// 导入前读目标表：列能不能写、要不要必填，以及当前 sql_mode 是不是 strict
pub async fn prepare_import(session_id: u64, database: &str, table: &str) -> Result<crate::import::ImportTarget> {
    let pool = pool_of(session_id)?;
    crate::import::prepare(&pool, database, table).await
}

/// 在后台开始导入，返回任务 id。进度和结果用 import::status 取
pub async fn start_import(session_id: u64, request: crate::import::ImportRequest) -> Result<u64> {
    let pool = pool_of(session_id)?;
    crate::import::start(pool, request).await
}

/// 取会话的连接池并立刻释放锁，不把锁持过 await
fn pool_of(session_id: u64) -> Result<DbPool> {
    let guard = store().lock().unwrap();
    let session = guard
        .sessions
        .get(&session_id)
        .ok_or(Error::NoSuchSession(session_id))?;
    Ok(session.pool.clone())
}

/// 改一个单元格并写回数据库。
///
/// 值没变就不发 SQL。连接开了 CLIENT_FOUND_ROWS，affected_rows 是匹配行数，
/// 不为 1 就是定位失败。写回后按主键重读这一行放进缓存 —— 用户填 `7.5`，
/// DECIMAL(12,2) 存的是 `7.50`，缓存里放填的值就是在显示假数据。
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
        let target = edit_target(session, session_id)?;

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

    drop(conn);
    let fresh = reread_row(&pool, &target, &columns, &row).await?;

    let mut guard = store().lock().unwrap();
    let session = guard
        .sessions
        .get_mut(&session_id)
        .ok_or(Error::NoSuchSession(session_id))?;
    let result = session
        .result
        .as_mut()
        .ok_or(Error::NoResult(session_id))?;
    result.rows[row_index] = fresh;

    Ok(())
}

/// 按主键从库里重读缓存里的一行，右键「刷新行」用。
///
/// 库里已经没有这一行（被删了或主键被改了）就报错，缓存原样留着 —— 不替用户把行删掉，
/// 让他重新查询确认。
pub async fn refresh_row(session_id: u64, row_index: u64) -> Result<()> {
    let row_index = row_index as usize;
    let (pool, target, columns, row) = {
        let guard = store().lock().unwrap();
        let session = guard
            .sessions
            .get(&session_id)
            .ok_or(Error::NoSuchSession(session_id))?;
        let result = session.result.as_ref().ok_or(Error::NoResult(session_id))?;
        let target = edit_target(session, session_id)?;
        let row = result
            .rows
            .get(row_index)
            .ok_or_else(|| Error::EditFailed(format!("行下标 {row_index} 越界")))?
            .clone();
        (session.pool.clone(), target, result.columns.clone(), row)
    };

    let select = build_select_by_key(&target, &columns, &row).map_err(Error::EditFailed)?;
    let reread = run_query_with_params(&pool, &select.sql, select.params, 1).await?;
    let fresh = reread.rows.into_iter().next().ok_or_else(|| {
        Error::EditFailed("库里已经找不到这一行（可能被删除或改了主键），请重新查询".to_string())
    })?;

    let mut guard = store().lock().unwrap();
    let session = guard
        .sessions
        .get_mut(&session_id)
        .ok_or(Error::NoSuchSession(session_id))?;
    let result = session.result.as_mut().ok_or(Error::NoResult(session_id))?;
    result.rows[row_index] = fresh;
    Ok(())
}

/// 按主键从库里重读一行。写库之后用它刷新缓存，界面显示的永远是库里真实存下的值
async fn reread_row(
    pool: &DbPool,
    target: &EditTarget,
    columns: &[ColumnMeta],
    row: &[CellValue],
) -> Result<Vec<CellValue>> {
    let select = build_select_by_key(target, columns, row).map_err(Error::EditFailed)?;
    let reread = run_query_with_params(pool, &select.sql, select.params, 1).await?;
    reread.rows.into_iter().next().ok_or_else(|| {
        Error::EditFailed(
            "已写入，但按主键读不回这一行（可能被 MySQL 转换了主键值），请重新查询确认".to_string(),
        )
    })
}

/// 把一片单元格编码成 TSV，复制用。
///
/// 直接读会话里的整份结果，选区超出界面当前窗口也没关系，不用把行搬过 FFI。
/// column_indexes 按显示顺序给，TSV 里的列就是这个顺序。
pub fn copy_range(
    session_id: u64,
    row_start: u64,
    row_count: u64,
    column_indexes: Vec<u64>,
) -> Result<String> {
    let guard = store().lock().unwrap();
    let session = guard
        .sessions
        .get(&session_id)
        .ok_or(Error::NoSuchSession(session_id))?;
    let result = session.result.as_ref().ok_or(Error::NoResult(session_id))?;

    let start = row_start as usize;
    let end = start.saturating_add(row_count as usize);
    if end > result.rows.len() {
        return Err(Error::BadInput(format!(
            "复制区域到第 {end} 行，结果集只有 {} 行",
            result.rows.len()
        )));
    }

    let mut columns = Vec::with_capacity(column_indexes.len());
    for index in column_indexes {
        columns.push(index as usize);
    }
    crate::clipboard::encode(&result.rows[start..end], &columns).map_err(Error::BadInput)
}

/// 从 row_start 行起，把一块值粘贴进 column_indexes 这几列，返回写了多少个单元格。
///
/// 和批量删除一样放一个事务，任何一格没写成就整体回滚。主键列、二进制列拒绝粘贴。
/// 写完按主键重读改过的行，缓存里放库里真实存下的值。
pub async fn paste_cells(
    session_id: u64,
    row_start: u64,
    column_indexes: Vec<u64>,
    values: Vec<Vec<CellValue>>,
) -> Result<u64> {
    let row_start = row_start as usize;
    let mut column_indexes_usize = Vec::with_capacity(column_indexes.len());
    for index in column_indexes {
        column_indexes_usize.push(index as usize);
    }
    let column_indexes = column_indexes_usize;

    // 先全部生成好再动库，任何一格有问题都一格不写
    let (pool, target, columns, statements, touched) = {
        let guard = store().lock().unwrap();
        let session = guard
            .sessions
            .get(&session_id)
            .ok_or(Error::NoSuchSession(session_id))?;
        let result = session.result.as_ref().ok_or(Error::NoResult(session_id))?;
        let target = edit_target(session, session_id)?;

        if row_start + values.len() > result.rows.len() {
            return Err(Error::BadInput(format!(
                "从第 {} 行粘贴 {} 行会超出结果集末尾（共 {} 行）",
                row_start + 1,
                values.len(),
                result.rows.len()
            )));
        }
        for &index in &column_indexes {
            let column = result
                .columns
                .get(index)
                .ok_or_else(|| Error::BadInput(format!("列下标 {index} 越界")))?;
            if target.key_indexes.contains(&index) {
                return Err(Error::NotEditable(format!(
                    "粘贴区域包含主键列 {}，改主键要用专门的流程",
                    column.name
                )));
            }
            if column.is_binary {
                return Err(Error::NotEditable(format!(
                    "粘贴区域包含二进制列 {}，暂不支持粘贴",
                    column.name
                )));
            }
        }

        let mut statements = Vec::new();
        let mut touched = Vec::new();
        for (offset, pasted_row) in values.iter().enumerate() {
            if pasted_row.len() != column_indexes.len() {
                return Err(Error::BadInput(format!(
                    "第 {} 行有 {} 个值，选中的是 {} 列",
                    offset + 1,
                    pasted_row.len(),
                    column_indexes.len()
                )));
            }

            let row_index = row_start + offset;
            let row = &result.rows[row_index];
            let mut changed = false;
            for (value, &column_index) in pasted_row.iter().zip(&column_indexes) {
                if &row[column_index] == value {
                    continue;
                }
                let statement = build_update(&target, &result.columns, row, column_index, value)
                    .map_err(Error::NotEditable)?;
                statements.push((row_index, statement));
                changed = true;
            }
            if changed {
                touched.push((row_index, row.clone()));
            }
        }

        (session.pool.clone(), target, result.columns.clone(), statements, touched)
    };

    if statements.is_empty() {
        return Ok(0);
    }
    let written = statements.len() as u64;

    // ponytail: 一格一条 UPDATE，粘贴几千格以内够用；更大再改成一行一条多列 SET
    let mut conn = pool.get_conn().await?;
    let mut tx = conn.start_transaction(TxOpts::default()).await?;
    for (row_index, statement) in statements {
        tx.exec_drop(&statement.sql, statement.params).await?;
        let affected = tx.affected_rows();
        if affected != 1 {
            tx.rollback().await?;
            return Err(Error::EditFailed(format!(
                "第 {} 行预期修改 1 行，实际 {affected} 行，已整体回滚（不支持事务的引擎无法回滚，请重新查询确认）",
                row_index + 1
            )));
        }
    }
    tx.commit().await?;
    drop(conn);

    let mut fresh_rows = Vec::with_capacity(touched.len());
    for (row_index, row) in &touched {
        fresh_rows.push((*row_index, reread_row(&pool, &target, &columns, row).await?));
    }

    let mut guard = store().lock().unwrap();
    let session = guard
        .sessions
        .get_mut(&session_id)
        .ok_or(Error::NoSuchSession(session_id))?;
    let result = session.result.as_mut().ok_or(Error::NoResult(session_id))?;
    for (row_index, fresh) in fresh_rows {
        result.rows[row_index] = fresh;
    }

    Ok(written)
}

/// 插一行并把它追加到结果集末尾，返回新的总行数。
///
/// `values[i]` 为 None 表示这一列交给 DEFAULT / AUTO_INCREMENT。
/// 插入前先确认插完能按主键找回这一行，找不回就拒绝 —— 不然库里多了一行、界面却看不到。
/// 追加进缓存的是从库里读回来的真实值，不是用户填的值。
pub async fn insert_row(session_id: u64, values: Vec<Option<CellValue>>) -> Result<u64> {
    let (pool, target, columns) = {
        let guard = store().lock().unwrap();
        let session = guard
            .sessions
            .get(&session_id)
            .ok_or(Error::NoSuchSession(session_id))?;
        let result = session.result.as_ref().ok_or(Error::NoResult(session_id))?;
        (session.pool.clone(), edit_target(session, session_id)?, result.columns.clone())
    };

    let insert = build_insert(&target, &columns, &values).map_err(Error::NotEditable)?;

    // 没填（或填了 NULL）的主键列。只有「单列主键 + 自增」能靠 LAST_INSERT_ID 找回
    let mut missing_keys = Vec::new();
    for &key_index in &target.key_indexes {
        if matches!(values[key_index], None | Some(CellValue::Null)) {
            missing_keys.push(key_index);
        }
    }
    let generated_key = match missing_keys.as_slice() {
        [] => None,
        [key_index] if target.key_indexes.len() == 1 => {
            let key_column = &columns[*key_index];
            if !is_auto_increment(&pool, &target.schema, &target.table, &key_column.org_name).await? {
                return Err(Error::NotEditable(format!(
                    "主键列 {} 没有填值，且不是自增列，插入后无法定位这一行",
                    key_column.name
                )));
            }
            Some(*key_index)
        }
        _ => {
            return Err(Error::NotEditable(
                "复合主键的每一列都要填值，否则插入后无法定位这一行".to_string(),
            ))
        }
    };

    let mut conn = pool.get_conn().await?;
    conn.exec_drop(&insert.sql, insert.params).await?;
    let affected = conn.affected_rows();
    if affected != 1 {
        return Err(Error::EditFailed(format!("预期插入 1 行，实际 {affected} 行")));
    }

    // 拼一行只有主键有意义的「定位行」，交给 build_select_by_key 生成 WHERE
    let mut locator = vec![CellValue::Null; columns.len()];
    for &key_index in &target.key_indexes {
        if let Some(value) = &values[key_index] {
            locator[key_index] = value.clone();
        }
    }
    if let Some(key_index) = generated_key {
        let id = conn.last_insert_id().filter(|id| *id != 0).ok_or_else(|| {
            Error::EditFailed("已插入，但拿不到自增主键，请重新查询确认".to_string())
        })?;
        locator[key_index] = CellValue::UInt(id);
    }
    drop(conn);

    let row = reread_row(&pool, &target, &columns, &locator).await?;

    let mut guard = store().lock().unwrap();
    let session = guard
        .sessions
        .get_mut(&session_id)
        .ok_or(Error::NoSuchSession(session_id))?;
    let result = session.result.as_mut().ok_or(Error::NoResult(session_id))?;
    result.rows.push(row);

    Ok(result.rows.len() as u64)
}

/// 删若干行，返回新的总行数。
///
/// 放在一个事务里，每条都必须恰好删掉 1 行，否则整体回滚 —— 缓存里的行可能已经被
/// 别人删了或改了主键，删一半留一半比全不删更难收拾。
pub async fn delete_rows(session_id: u64, row_indexes: Vec<u64>) -> Result<u64> {
    let mut row_indexes: Vec<usize> = row_indexes.into_iter().map(|i| i as usize).collect();
    // 重复的下标会让第二条 DELETE 影响 0 行，把整批都回滚掉
    row_indexes.sort_unstable();
    row_indexes.dedup();

    let (pool, statements) = {
        let guard = store().lock().unwrap();
        let session = guard
            .sessions
            .get(&session_id)
            .ok_or(Error::NoSuchSession(session_id))?;
        let result = session.result.as_ref().ok_or(Error::NoResult(session_id))?;
        let target = edit_target(session, session_id)?;

        // 先全部生成好再动库，任何一行有问题都一条不删
        let mut statements = Vec::with_capacity(row_indexes.len());
        for &row_index in &row_indexes {
            let row = result
                .rows
                .get(row_index)
                .ok_or_else(|| Error::EditFailed(format!("行下标 {row_index} 越界")))?;
            let statement =
                build_delete(&target, &result.columns, row).map_err(Error::NotEditable)?;
            statements.push(statement);
        }
        (session.pool.clone(), statements)
    };

    // ponytail: 一行一条 DELETE，几千行以内够用；要删上万行再改成按主键 IN 分批
    // MyISAM 这类不支持事务的引擎回滚无效，报错信息里要说清楚
    let mut conn = pool.get_conn().await?;
    let mut tx = conn.start_transaction(TxOpts::default()).await?;
    for (statement, &row_index) in statements.into_iter().zip(&row_indexes) {
        tx.exec_drop(&statement.sql, statement.params).await?;
        let affected = tx.affected_rows();
        if affected != 1 {
            tx.rollback().await?;
            return Err(Error::EditFailed(format!(
                "第 {} 行预期删除 1 行，实际 {affected} 行，已整体回滚（不支持事务的引擎无法回滚，请重新查询确认）",
                row_index + 1
            )));
        }
    }
    tx.commit().await?;

    let mut guard = store().lock().unwrap();
    let session = guard
        .sessions
        .get_mut(&session_id)
        .ok_or(Error::NoSuchSession(session_id))?;
    let result = session.result.as_mut().ok_or(Error::NoResult(session_id))?;
    // 从后往前删，前面的下标才不会错位
    for &row_index in row_indexes.iter().rev() {
        result.rows.remove(row_index);
    }

    Ok(result.rows.len() as u64)
}

/// 会话结果集的写回目标。只读的直接带着原因报错
fn edit_target(session: &Session, session_id: u64) -> Result<EditTarget> {
    match session.editability.as_ref() {
        Some(Editability::Editable(target)) => Ok(target.clone()),
        Some(Editability::ReadOnly(reason)) => Err(Error::NotEditable(reason.clone())),
        None => Err(Error::NoResult(session_id)),
    }
}

/// 关会话并断开连接池。界面关标签页时必须调，否则连接一直挂着
pub async fn close_session(session_id: u64) -> Result<()> {
    let session = {
        let mut guard = store().lock().unwrap();
        let session = guard
            .sessions
            .remove(&session_id)
            .ok_or(Error::NoSuchSession(session_id))?;
        for child in &session.children {
            guard.sessions.remove(child);
        }
        if let Some(parent) = session.parent {
            if let Some(parent) = guard.sessions.get_mut(&parent) {
                parent.children.retain(|id| *id != session_id);
            }
        }
        session
    };

    // 子会话和父会话共用连接池，只有父会话关的时候才断开
    if session.parent.is_none() {
        session.pool.disconnect().await?;
    }
    Ok(())
}

// ---- 服务器状态：server.rs 的薄包装 ----

/// 连同一台服务器的所有会话的连接池取出过的线程 id。每个标签各有各的池，都算 CData 自己的连接。
/// 要在取到这次用的连接之后再调，这条连接自己才在里面
fn own_connection_ids(session_id: u64) -> Result<Vec<u32>> {
    let guard = store().lock().unwrap();
    let server = &guard
        .sessions
        .get(&session_id)
        .ok_or(Error::NoSuchSession(session_id))?
        .server;
    let mut ids = Vec::new();
    for session in guard.sessions.values() {
        if &session.server == server {
            ids.extend(session.pool.connection_ids());
        }
    }
    Ok(ids)
}

/// 进程列表，CData 自己的连接标出来
pub async fn server_processes(session_id: u64) -> Result<crate::server::ProcessList> {
    let pool = pool_of(session_id)?;
    let mut conn = pool.get_conn().await?;
    let own_ids = own_connection_ids(session_id)?;
    crate::server::read_processes(&mut conn, &own_ids).await
}

/// KILL QUERY / KILL CONNECTION。拒绝 CData 自己的连接，和确认时看到的对不上也拒绝
pub async fn kill_process(
    session_id: u64,
    target: &crate::server::ProcessInfo,
    mode: crate::server::KillMode,
) -> Result<()> {
    let pool = pool_of(session_id)?;
    let mut conn = pool.get_conn().await?;
    let own_ids = own_connection_ids(session_id)?;
    crate::server::kill(&mut conn, target, mode, &own_ids).await
}

/// SHOW GLOBAL / SESSION VARIABLES。会话值来自连接池里的一条连接，归还时会被重置
pub async fn server_variables(
    session_id: u64,
    scope: crate::server::VariableScope,
) -> Result<crate::server::VariableList> {
    let pool = pool_of(session_id)?;
    let mut conn = pool.get_conn().await?;
    crate::server::read_variables(&mut conn, scope).await
}

/// SHOW GLOBAL STATUS，和 previous 比出差值
pub async fn server_status(
    session_id: u64,
    previous: Option<&crate::server::StatusSnapshot>,
) -> Result<crate::server::StatusSnapshot> {
    let pool = pool_of(session_id)?;
    let mut conn = pool.get_conn().await?;
    crate::server::read_status(&mut conn, previous).await
}

pub async fn slow_log_config(session_id: u64) -> Result<crate::server::SlowLogConfig> {
    let pool = pool_of(session_id)?;
    let mut conn = pool.get_conn().await?;
    crate::server::slow_log_config(&mut conn).await
}

/// mysql.slow_log 最近 limit 条。log_output 不含 TABLE 时拒绝并说明日志在哪
pub async fn slow_log_entries(session_id: u64, limit: u32) -> Result<Vec<crate::server::SlowLogEntry>> {
    let pool = pool_of(session_id)?;
    let mut conn = pool.get_conn().await?;
    crate::server::read_slow_log(&mut conn, limit).await
}

pub async fn preview_set_global(session_id: u64, name: &str, value: &str) -> Result<crate::server::SetVariablePlan> {
    let pool = pool_of(session_id)?;
    let mut conn = pool.get_conn().await?;
    crate::server::plan_set_global(&mut conn, name, value).await
}

/// 执行预览过的 SET GLOBAL，返回服务器存下的新值
pub async fn apply_set_global(session_id: u64, name: &str, value: &str, previewed: &str) -> Result<DisplayCell> {
    let pool = pool_of(session_id)?;
    let mut conn = pool.get_conn().await?;
    crate::server::apply_set_global(&mut conn, name, value, previewed).await
}

/// 用户管理页打开时的全部信息：当前账号、账号清单、认证插件、各层可选的权限
pub async fn load_user_admin(session_id: u64) -> Result<crate::users::UserAdmin> {
    let mut conn = pool_of(session_id)?.get_conn().await?;
    crate::users::load(&mut conn).await
}

/// 一个账号的 SHOW GRANTS，分层解析后连同原文返回
pub async fn account_grants(session_id: u64, account: &crate::users::Account) -> Result<crate::users::AccountGrants> {
    let mut conn = pool_of(session_id)?.get_conn().await?;
    crate::users::account_grants(&mut conn, account).await
}

/// 预览一次账号或权限变更。返回的语句里密码是 `'***'`
pub async fn preview_user_change(
    session_id: u64,
    change: &crate::users::UserChange,
    password: Option<&str>,
) -> Result<crate::users::ChangePlan> {
    let mut conn = pool_of(session_id)?.get_conn().await?;
    crate::users::preview_change(&mut conn, change, password).await
}

/// 执行预览过的变更。previewed 是预览时拿到的语句，重新生成的不一致就不执行
pub async fn apply_user_change(
    session_id: u64,
    change: &crate::users::UserChange,
    password: Option<&str>,
    previewed: &str,
) -> Result<()> {
    let mut conn = pool_of(session_id)?.get_conn().await?;
    crate::users::apply_change(&mut conn, change, password, previewed).await
}

/// 字符串里的反斜杠怎么转义取决于执行语句那条连接的 sql_mode
async fn no_backslash_escapes(conn: &mut mysql_async::Conn) -> Result<bool> {
    let sql_mode: String = conn.query_first("SELECT @@SESSION.sql_mode").await?.unwrap_or_default();
    Ok(sql_mode.split(',').any(|mode| mode == "NO_BACKSLASH_ESCAPES"))
}

/// 预览新建表。同名的表或视图已经存在就拒绝
pub async fn preview_create_table(
    session_id: u64,
    database: &str,
    table: &str,
    draft: &crate::alter::TableDraft,
) -> Result<crate::alter::AlterPlan> {
    let pool = pool_of(session_id)?;
    let mut conn = pool.get_conn().await?;
    plan_create_on(&mut conn, database, table, draft).await
}

/// 执行预览过的建表。在同一条连接上重新核对、重新生成，和预览时的语句不一致就不执行。
/// 语句是不带 IF NOT EXISTS 的 CREATE TABLE，核对之后才冒出来的同名表也会让它报错，不会误用别人的表
pub async fn create_table(
    session_id: u64,
    database: &str,
    table: &str,
    draft: &crate::alter::TableDraft,
    previewed: &[String],
) -> Result<()> {
    let pool = pool_of(session_id)?;
    let mut conn = pool.get_conn().await?;
    let plan = plan_create_on(&mut conn, database, table, draft).await?;
    if plan.statements != previewed {
        return Err(Error::BadInput(
            "要执行的语句和预览时不一样了（sql_mode 变了），请重新预览".to_string(),
        ));
    }
    crate::alter::run_statements(&mut conn, &plan.statements).await.map_err(|(_, err)| Error::from(err))
}

async fn plan_create_on(
    conn: &mut mysql_async::Conn,
    database: &str,
    table: &str,
    draft: &crate::alter::TableDraft,
) -> Result<crate::alter::AlterPlan> {
    let version: String = conn.query_first("SELECT VERSION()").await?.unwrap_or_default();
    if !crate::alter::supports_alter(&version) {
        return Err(Error::BadInput(format!(
            "新建表只支持 MySQL 8.0.13 及以上（当前 {version}）：和结构编辑用的是同一套生成规则"
        )));
    }
    let existing: Option<String> = conn
        .exec_first(
            "SELECT TABLE_TYPE FROM information_schema.TABLES WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?",
            (database, table),
        )
        .await?;
    if let Some(kind) = existing {
        let what = if kind == "VIEW" { "视图" } else { "表" };
        return Err(Error::BadInput(format!("{database} 里已经有叫 {table} 的{what}，换个名字")));
    }

    let no_backslash_escapes = no_backslash_escapes(conn).await?;
    let supports_check = crate::alter::supports_check(&version);
    crate::alter::plan_create(database, table, draft, no_backslash_escapes, supports_check).map_err(Error::BadInput)
}

/// 在原查询上套分组筛选（可嵌套、带 IN）和排序再跑。execute_view 是只有一组时的特例。
/// 加在文件末尾：这个文件另有人在改，分组筛选只在这里接一个入口
pub async fn execute_filtered_view(
    session_id: u64,
    sql: &str,
    filter: &crate::sql::FilterGroup,
    sort: Option<(&str, bool)>,
    max_rows: usize,
) -> Result<QuerySummary> {
    let statement = crate::sql::build_filtered_view(sql, filter, sort).map_err(Error::BadInput)?;
    execute_statement(session_id, &statement.sql, statement.params, max_rows).await
}

/// 预览侧栏右键对整张表的写库操作（改名、复制、删除、清空）
pub async fn preview_table_action(
    session_id: u64,
    database: &str,
    table: &str,
    action: &crate::table_ops::TableAction,
) -> Result<crate::alter::AlterPlan> {
    let pool = pool_of(session_id)?;
    let mut conn = pool.get_conn().await?;
    plan_table_action_on(&mut conn, database, table, action).await
}

/// 执行预览过的表操作。在同一条连接上重新生成，和预览时的语句不一致就不执行
pub async fn apply_table_action(
    session_id: u64,
    database: &str,
    table: &str,
    action: &crate::table_ops::TableAction,
    previewed: &[String],
) -> Result<()> {
    let pool = pool_of(session_id)?;
    let mut conn = pool.get_conn().await?;
    let plan = plan_table_action_on(&mut conn, database, table, action).await?;
    if plan.statements != previewed {
        return Err(Error::BadInput(
            "要执行的语句和预览时不一样了（表被改过或换成了视图），请重新操作".to_string(),
        ));
    }
    run_planned(&mut conn, &plan.statements).await
}

/// 是表还是视图从 information_schema 读，不信界面传的
async fn plan_table_action_on(
    conn: &mut mysql_async::Conn,
    database: &str,
    table: &str,
    action: &crate::table_ops::TableAction,
) -> Result<crate::alter::AlterPlan> {
    let kind: Option<String> = conn
        .exec_first(
            "SELECT TABLE_TYPE FROM information_schema.TABLES WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?",
            (database, table),
        )
        .await?;
    let Some(kind) = kind else {
        return Err(Error::BadInput(format!("{database} 里没有 {table}，可能已经被删除或改名，请刷新侧栏")));
    };
    let is_view = kind == "VIEW" || kind == "SYSTEM VIEW";

    let columns = match action {
        crate::table_ops::TableAction::Duplicate { with_data: true, .. } => {
            crate::structure::read_columns(conn, database, table).await?
        }
        _ => Vec::new(),
    };
    crate::table_ops::plan_action(database, table, is_view, &columns, action).map_err(Error::BadInput)
}

/// 精确行数。information_schema 里的是估算值，这里真的 COUNT(*) 一遍，大表会慢
pub async fn count_rows(session_id: u64, database: &str, table: &str) -> Result<u64> {
    let pool = pool_of(session_id)?;
    let mut conn = pool.get_conn().await?;
    let count: Option<u64> = conn.query_first(crate::table_ops::count_sql(database, table)).await?;
    count.ok_or_else(|| Error::BadInput("COUNT(*) 没有返回结果".to_string()))
}

/// ANALYZE / CHECK / OPTIMIZE / REPAIR TABLE，返回 MySQL 给的消息
pub async fn run_maintenance(
    session_id: u64,
    database: &str,
    table: &str,
    op: crate::table_ops::Maintenance,
) -> Result<Vec<crate::table_ops::MaintenanceMessage>> {
    let pool = pool_of(session_id)?;
    let mut conn = pool.get_conn().await?;
    // 结果列是 Table / Op / Msg_type / Msg_text
    let rows: Vec<(String, String, String, String)> =
        conn.query(crate::table_ops::maintenance_sql(database, table, op)).await?;
    let mut messages = Vec::with_capacity(rows.len());
    for (_, _, msg_type, text) in rows {
        messages.push(crate::table_ops::MaintenanceMessage { msg_type, text });
    }
    Ok(messages)
}

/// 这张表的 INSERT 模板，复制到剪贴板用
pub async fn insert_template(session_id: u64, database: &str, table: &str) -> Result<String> {
    let pool = pool_of(session_id)?;
    let columns = crate::structure::table_columns(&pool, database, table).await?;
    if columns.is_empty() {
        return Err(Error::BadInput(format!("读不到 {table} 的列，可能已经被删除或改名")));
    }
    Ok(crate::table_ops::insert_template(table, &columns))
}
