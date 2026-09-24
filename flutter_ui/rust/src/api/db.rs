//! 会话与查询的 FFI 接口。
//!
//! core 是 async（mysql_async 要 tokio），这里用一个进程级 runtime 把它 block 成同步调用。
//! FRB 会把每个调用放到自己的 worker 线程上，所以 block_on 不会卡住 Dart 的 UI 线程。

use std::sync::OnceLock;

use flutter_rust_bridge::frb;
use tokio::runtime::Runtime;

pub use cdata_core::db::{ColumnMeta, ConnectionConfig};
pub use cdata_core::edit::{Editability, EditTarget};
pub use cdata_core::session::QuerySummary;
pub use cdata_core::CellValue;

#[frb(mirror(ConnectionConfig))]
pub struct _ConnectionConfig {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
    pub database: Option<String>,
}

#[frb(mirror(ColumnMeta))]
pub struct _ColumnMeta {
    pub name: String,
    pub org_name: String,
    pub org_table: String,
    pub schema: String,
    pub is_binary: bool,
}

#[frb(mirror(EditTarget))]
pub struct _EditTarget {
    pub schema: String,
    pub table: String,
    pub key_indexes: Vec<usize>,
}

#[frb(mirror(Editability))]
pub enum _Editability {
    Editable(EditTarget),
    ReadOnly(String),
}

#[frb(mirror(QuerySummary))]
pub struct _QuerySummary {
    pub columns: Vec<ColumnMeta>,
    pub total_rows: u64,
    pub truncated: bool,
    pub editability: Editability,
}

pub(crate) fn runtime() -> &'static Runtime {
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| Runtime::new().expect("创建 tokio runtime 失败"))
}

/// 错误按人话过 FFI。
///
/// 用 anyhow 的话 FRB 会按 Debug 格式化，把整段 Rust 调用栈甩到界面上
/// （`core::result::Result<...>::from_residual` 之类），真正有用的那句
/// 「Access denied」反而被埋掉。让问题暴露指的是让人看懂，不是倒一屏堆栈。
pub(crate) type Result<T> = std::result::Result<T, String>;

/// 把异步活交给自己的 tokio runtime，FRB 的 worker 线程只等结果。
///
/// **不能在这里 block_on**：那会占住 FRB 的 worker 线程，线程池就那么大，
/// 并发调用一多就全被阻塞，界面直接卡死。
pub(crate) async fn on_runtime<F, T>(future: F) -> Result<T>
where
    F: std::future::Future<Output = std::result::Result<T, cdata_core::session::Error>>
        + Send
        + 'static,
    T: Send + 'static,
{
    runtime()
        .spawn(future)
        .await
        .map_err(|err| format!("任务没能跑完：{err}"))?
        .map_err(to_message)
}

pub(crate) fn to_message(err: cdata_core::session::Error) -> String {
    err.to_string()
}

/// 开会话，返回会话 id。此时还没有真正连上，第一次查询才建立 TCP 连接
pub fn open_session(config: ConnectionConfig) -> u64 {
    cdata_core::session::open_session(&config)
}

/// 跑查询，结果留在 Rust 侧，只回概况
pub async fn execute(session_id: u64, sql: String, max_rows: u64) -> Result<QuerySummary> {
    on_runtime(async move {
        cdata_core::session::execute(session_id, &sql, max_rows as usize).await
    })
    .await
}

/// 取可视区的显示文本，网格渲染走这条。整个结果集不跨 FFI，界面滚到哪取到哪
pub fn fetch_window_text(session_id: u64, offset: u64, limit: u64) -> Result<Vec<Vec<String>>> {
    cdata_core::session::fetch_window_text(session_id, offset, limit).map_err(to_message)
}

/// 取可视区的原始值，编辑单元格时走这条
pub fn fetch_window(session_id: u64, offset: u64, limit: u64) -> Result<Vec<Vec<CellValue>>> {
    cdata_core::session::fetch_window(session_id, offset, limit).map_err(to_message)
}

/// 改一个单元格并写回。不可编辑、定位不到行、影响行数不为 1 都会报错
pub async fn apply_edit(
    session_id: u64,
    row_index: u64,
    column_index: u64,
    new_value: CellValue,
) -> Result<()> {
    on_runtime(async move {
        cdata_core::session::apply_edit(session_id, row_index, column_index, new_value).await
    })
    .await
}

/// 关会话并断开连接池
pub async fn close_session(session_id: u64) -> Result<()> {
    on_runtime(async move { cdata_core::session::close_session(session_id).await }).await
}
