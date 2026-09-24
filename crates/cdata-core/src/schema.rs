//! 库和表的清单。侧栏用。

use mysql_async::prelude::*;
use serde::{Deserialize, Serialize};

use crate::db::DbPool;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TableInfo {
    pub name: String,
    /// InnoDB 的行数是估算值，可能和实际差很多，界面上不要当精确值展示
    pub estimated_rows: u64,
    pub is_view: bool,
}

/// 用户库列表。系统库单独排在后面，平时用不到但也不藏起来
pub async fn list_databases(pool: &DbPool) -> Result<Vec<String>, mysql_async::Error> {
    let mut conn = pool.get_conn().await?;
    let names: Vec<String> = conn
        .query(
            "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA \
             ORDER BY SCHEMA_NAME IN ('information_schema','mysql','performance_schema','sys'), \
                      SCHEMA_NAME",
        )
        .await?;
    Ok(names)
}

/// 某个库的表和视图
pub async fn list_tables(pool: &DbPool, database: &str) -> Result<Vec<TableInfo>, mysql_async::Error> {
    let mut conn = pool.get_conn().await?;
    let rows: Vec<(String, Option<u64>, String)> = conn
        .exec(
            "SELECT TABLE_NAME, TABLE_ROWS, TABLE_TYPE FROM information_schema.TABLES \
             WHERE TABLE_SCHEMA = ? ORDER BY TABLE_NAME",
            (database,),
        )
        .await?;

    let mut tables = Vec::with_capacity(rows.len());
    for (name, estimated_rows, table_type) in rows {
        tables.push(TableInfo {
            name,
            // 视图的 TABLE_ROWS 是 NULL，估不出来就给 0，界面按 is_view 区分展示
            estimated_rows: estimated_rows.unwrap_or(0),
            // information_schema、performance_schema 里的是 SYSTEM VIEW，也是视图，不能当表编辑
            is_view: table_type == "VIEW" || table_type == "SYSTEM VIEW",
        });
    }
    Ok(tables)
}
