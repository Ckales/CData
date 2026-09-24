//! MySQL 连接与查询执行。
//!
//! 值的解释全部委托给 value.rs，这里只负责把连接建起来、把行取回来、把列元数据带上。

use mysql_async::consts::ColumnType;
use mysql_async::prelude::*;
use mysql_async::{Column, Opts, OptsBuilder, Pool};
use serde::{Deserialize, Serialize};

use crate::value::{cell_from_value, CellValue};

/// binary collation 的 id
const BINARY_COLLATION_ID: u16 = 63;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConnectionConfig {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
    pub database: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ColumnMeta {
    /// 显示名。`SELECT id AS uid` 时是 uid
    pub name: String,
    /// 原始列名。写 UPDATE 要用这个，别名写进 SQL 会报错
    pub org_name: String,
    /// 原始表名。空串表示这列不是直接来自某张表（表达式、聚合、常量）
    pub org_table: String,
    /// 列所属的库
    pub schema: String,
    /// 二进制列，值按字节处理，不尝试解码成文本
    pub is_binary: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResultSet {
    pub columns: Vec<ColumnMeta>,
    pub rows: Vec<Vec<CellValue>>,
    /// 达到 max_rows 被截断。界面必须显式提示，不能静默丢数据
    pub truncated: bool,
}

/// 建连接池。失败直接上抛，不做重试掩盖问题
pub fn open_pool(config: &ConnectionConfig) -> Pool {
    let mut builder = OptsBuilder::default()
        .ip_or_hostname(config.host.clone())
        .tcp_port(config.port)
        .user(Some(config.user.clone()))
        .pass(Some(config.password.clone()))
        // 不设就走服务器默认的握手字符集，中文会按 latin1 解出乱码 —— 不报错、数据全错。
        // 必须用 setup 而不是 init：连接池归还连接时会 reset 会话，init 不重跑，SET NAMES 会丢
        .setup(vec!["SET NAMES utf8mb4"]);

    if let Some(database) = &config.database {
        builder = builder.db_name(Some(database.clone()));
    }

    Pool::new(Opts::from(builder))
}

/// 跑一条查询。超过 max_rows 停止读取并标记截断，不静默丢行
pub async fn run_query(
    pool: &Pool,
    sql: &str,
    max_rows: usize,
) -> Result<ResultSet, mysql_async::Error> {
    let mut conn = pool.get_conn().await?;

    // 用 prepared statement 跑，文本协议下所有值都是 Bytes，拿不到真实数值类型
    let mut result = conn.exec_iter(sql, ()).await?;

    let columns = match result.columns() {
        Some(cols) => build_columns(&cols),
        None => Vec::new(),
    };

    let mut rows = Vec::new();
    let mut truncated = false;

    while let Some(row) = result.next().await? {
        if rows.len() >= max_rows {
            truncated = true;
            break;
        }
        rows.push(build_row(row, &columns));
    }

    // 截断时剩余的行必须读完或丢弃，否则连接状态不干净、无法复用
    if truncated {
        result.drop_result().await?;
    }

    Ok(ResultSet {
        columns,
        rows,
        truncated,
    })
}

fn build_columns(columns: &[Column]) -> Vec<ColumnMeta> {
    let mut metas = Vec::with_capacity(columns.len());
    for column in columns {
        metas.push(ColumnMeta {
            name: column.name_str().to_string(),
            org_name: column.org_name_str().to_string(),
            org_table: column.org_table_str().to_string(),
            schema: column.schema_str().to_string(),
            is_binary: is_binary_column(column),
        });
    }
    metas
}

/// 判断列是否按字节处理。
///
/// 不能只看 charset：DECIMAL、DATE、INT 这些数值和日期类型的 collation 也是 binary(63)，
/// 但它们的字节是 ASCII 字面量，当成二进制会让 DECIMAL 显示成一串字节。
/// 只有字符串家族才存在「二进制还是文本」之分，BIT 和 GEOMETRY 则永远是原始字节。
fn is_binary_column(column: &Column) -> bool {
    match column.column_type() {
        ColumnType::MYSQL_TYPE_BIT | ColumnType::MYSQL_TYPE_GEOMETRY => true,

        ColumnType::MYSQL_TYPE_STRING
        | ColumnType::MYSQL_TYPE_VAR_STRING
        | ColumnType::MYSQL_TYPE_VARCHAR
        | ColumnType::MYSQL_TYPE_BLOB
        | ColumnType::MYSQL_TYPE_TINY_BLOB
        | ColumnType::MYSQL_TYPE_MEDIUM_BLOB
        | ColumnType::MYSQL_TYPE_LONG_BLOB => column.character_set() == BINARY_COLLATION_ID,

        _ => false,
    }
}

fn build_row(row: mysql_async::Row, columns: &[ColumnMeta]) -> Vec<CellValue> {
    let values = row.unwrap();

    let mut cells = Vec::with_capacity(values.len());
    for (index, value) in values.into_iter().enumerate() {
        // 列元数据缺位说明结果集和列信息对不上，按二进制处理避免伪造出文本
        let is_binary = columns.get(index).map(|c| c.is_binary).unwrap_or(true);
        cells.push(cell_from_value(value, is_binary));
    }
    cells
}
