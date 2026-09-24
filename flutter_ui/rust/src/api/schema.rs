//! 库表清单的 FFI 接口。侧栏用。

use flutter_rust_bridge::frb;

pub use cdata_core::schema::TableInfo;

use crate::api::db::{on_runtime, Result};

#[frb(mirror(TableInfo))]
pub struct _TableInfo {
    pub name: String,
    pub estimated_rows: u64,
    pub is_view: bool,
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
