//! 库表清单的 FFI 接口。侧栏用。

use flutter_rust_bridge::frb;

pub use cdata_core::schema::TableInfo;
pub use cdata_core::structure::{ColumnDef, DefaultValue, ForeignKeyDef, IndexDef, TableStructure};

use crate::api::db::{on_runtime, Result};

#[frb(mirror(TableInfo))]
pub struct _TableInfo {
    pub name: String,
    pub estimated_rows: u64,
    pub is_view: bool,
}

#[frb(mirror(DefaultValue))]
pub enum _DefaultValue {
    NoDefault,
    Null,
    Literal(String),
    Expression(String),
}

#[frb(mirror(ColumnDef))]
pub struct _ColumnDef {
    pub name: String,
    pub column_type: String,
    pub nullable: bool,
    pub default: DefaultValue,
    pub extra: String,
    pub comment: String,
    pub collation: Option<String>,
}

#[frb(mirror(IndexDef))]
pub struct _IndexDef {
    pub name: String,
    pub unique: bool,
    pub columns: Vec<String>,
    pub index_type: String,
    pub comment: String,
}

#[frb(mirror(ForeignKeyDef))]
pub struct _ForeignKeyDef {
    pub name: String,
    pub columns: Vec<String>,
    pub referenced_schema: String,
    pub referenced_table: String,
    pub referenced_columns: Vec<String>,
    pub on_update: String,
    pub on_delete: String,
}

#[frb(mirror(TableStructure))]
pub struct _TableStructure {
    pub columns: Vec<ColumnDef>,
    pub indexes: Vec<IndexDef>,
    pub foreign_keys: Vec<ForeignKeyDef>,
    pub create_sql: String,
}

/// 一张表的列、索引、外键和建表语句，结构页一次取齐
pub async fn table_structure(
    session_id: u64,
    database: String,
    table: String,
) -> Result<TableStructure> {
    on_runtime(async move {
        cdata_core::session::table_structure(session_id, &database, &table).await
    })
    .await
}

/// 服务器上的库列表
pub async fn list_databases(session_id: u64) -> Result<Vec<String>> {
    on_runtime(async move { cdata_core::session::list_databases(session_id).await }).await
}

/// 某个库的表和视图
pub async fn list_tables(session_id: u64, database: String) -> Result<Vec<TableInfo>> {
    on_runtime(async move { cdata_core::session::list_tables(session_id, &database).await }).await
}

/// 浏览整张表的 SQL。标识符转义在 core 里做，界面不要自己拼
pub fn browse_sql(table: String) -> String {
    cdata_core::sql::browse_table(&table)
}
