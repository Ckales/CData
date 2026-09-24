//! 会话与查询的 FFI 接口。
//!
//! core 是 async（mysql_async 要 tokio），这里用一个进程级 runtime 把它 block 成同步调用。
//! FRB 会把每个调用放到自己的 worker 线程上，所以 block_on 不会卡住 Dart 的 UI 线程。

use std::sync::OnceLock;

use flutter_rust_bridge::frb;
use tokio::runtime::Runtime;

pub use cdata_core::db::{ColumnKind, ColumnMeta, ConnectionConfig};
pub use cdata_core::edit::{Editability, EditTarget};
pub use cdata_core::export::{ExportEncoding, ExportFormat, ExportOptions, ExportSummary};
pub use cdata_core::session::QuerySummary;
pub use cdata_core::sql::{FilterCondition, FilterOp};
pub use cdata_core::CellValue;
use cdata_core::value::DisplayCell;

use crate::api::options::{ConnectionOptions, HostKeyIssue};

#[frb(mirror(ConnectionConfig))]
pub struct _ConnectionConfig {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
    pub database: Option<String>,
    pub options: ConnectionOptions,
    pub ssh_secrets: Vec<Option<String>>,
    pub saved_id: Option<String>,
}

/// 开会话失败。主机密钥没通过校验时带着 host_key，界面据此问用户要不要信任；
/// 其余情况只有 message
#[frb(dart_code = "
  @override
  String toString() => message;
")]
pub struct OpenSessionError {
    pub message: String,
    pub host_key: Option<HostKeyIssue>,
}

#[frb(mirror(ColumnMeta))]
pub struct _ColumnMeta {
    pub name: String,
    pub org_name: String,
    pub org_table: String,
    pub schema: String,
    pub is_binary: bool,
    pub kind: ColumnKind,
}

#[frb(mirror(ColumnKind))]
pub enum _ColumnKind {
    Text,
    Number,
    Json,
    Date,
    DateTime,
    Time,
    Enum,
    Set,
    Binary,
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
    pub layout_key: Option<String>,
}

#[frb(mirror(FilterOp))]
pub enum _FilterOp {
    Eq,
    NotEq,
    Lt,
    LtEq,
    Gt,
    GtEq,
    Contains,
    NotContains,
    StartsWith,
    EndsWith,
    IsNull,
    IsNotNull,
}

#[frb(mirror(FilterCondition))]
pub struct _FilterCondition {
    pub column: String,
    pub op: FilterOp,
    pub value: String,
}

#[frb(mirror(ExportFormat))]
pub enum _ExportFormat {
    Csv,
    SqlInsert,
}

#[frb(mirror(ExportEncoding))]
pub enum _ExportEncoding {
    Utf8,
    Utf8Bom,
    Gbk,
}

#[frb(mirror(ExportOptions))]
pub struct _ExportOptions {
    pub format: ExportFormat,
    pub encoding: ExportEncoding,
    pub delimiter: String,
    pub header: bool,
    pub null_text: String,
    pub table_name: String,
}

#[frb(mirror(ExportSummary))]
pub struct _ExportSummary {
    pub rows_written: u64,
    pub source_truncated: bool,
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

/// 开会话，返回会话 id。直连时还没有真正连上，第一次查询才建立 TCP 连接；
/// 走 SSH 时当场建隧道，未知主机、密钥不符、认证失败在这里就报出来
pub async fn open_session(config: ConnectionConfig) -> std::result::Result<u64, OpenSessionError> {
    runtime()
        .spawn(async move { cdata_core::session::open_session(&config).await })
        .await
        .map_err(|err| OpenSessionError { message: format!("任务没能跑完：{err}"), host_key: None })?
        .map_err(|err| OpenSessionError {
            host_key: err.host_key_issue().cloned(),
            message: err.to_string(),
        })
}

/// 跑查询，结果留在 Rust 侧，只回概况
pub async fn execute(session_id: u64, sql: String, max_rows: u64) -> Result<QuerySummary> {
    on_runtime(async move {
        cdata_core::session::execute(session_id, &sql, max_rows as usize).await
    })
    .await
}

/// 在原查询上套筛选和排序再跑。SQL 在 core 里生成，条件的值走参数化。
/// 没有条件、sort_column 为 null 时就是原样跑 sql
pub async fn execute_view(
    session_id: u64,
    sql: String,
    conditions: Vec<FilterCondition>,
    match_all: bool,
    sort_column: Option<String>,
    sort_ascending: bool,
    max_rows: u64,
) -> Result<QuerySummary> {
    on_runtime(async move {
        let sort = sort_column.as_deref().map(|column| (column, sort_ascending));
        cdata_core::session::execute_view(
            session_id,
            &sql,
            &conditions,
            match_all,
            sort,
            max_rows as usize,
        )
        .await
    })
    .await
}

/// 取可视区的显示文本，网格渲染走这条。整个结果集不跨 FFI，界面滚到哪取到哪
pub fn fetch_window_text(session_id: u64, offset: u64, limit: u64) -> Result<Vec<Vec<DisplayCell>>> {
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

/// 插一行，返回新的总行数。values[i] 为 null 表示这一列交给 DEFAULT / 自增
pub async fn insert_row(session_id: u64, values: Vec<Option<CellValue>>) -> Result<u64> {
    on_runtime(async move { cdata_core::session::insert_row(session_id, values).await }).await
}

/// 在一个事务里删若干行，返回新的总行数。任何一行没删成就整体回滚
pub async fn delete_rows(session_id: u64, row_indexes: Vec<u64>) -> Result<u64> {
    on_runtime(async move { cdata_core::session::delete_rows(session_id, row_indexes).await })
        .await
}

/// 把一片单元格编码成 TSV，列按 column_indexes 的顺序。选区不用在界面窗口里
pub fn copy_range(
    session_id: u64,
    row_start: u64,
    row_count: u64,
    column_indexes: Vec<u64>,
) -> Result<String> {
    cdata_core::session::copy_range(session_id, row_start, row_count, column_indexes)
        .map_err(to_message)
}

/// 解析剪贴板里的 TSV。不带引号的 NULL 是 NULL，其余都是文本；不是规整矩形就报错
pub fn parse_clipboard(text: String) -> Result<Vec<Vec<CellValue>>> {
    cdata_core::clipboard::decode(&text)
}

/// 从 row_start 起把一块值粘进这几列，返回写了多少格。一个事务，任何一格失败整体回滚
pub async fn paste_cells(
    session_id: u64,
    row_start: u64,
    column_indexes: Vec<u64>,
    values: Vec<Vec<CellValue>>,
) -> Result<u64> {
    on_runtime(async move {
        cdata_core::session::paste_cells(session_id, row_start, column_indexes, values).await
    })
    .await
}

/// 结果集某一列的 ENUM / SET 可选值，按定义顺序
pub async fn column_choices(session_id: u64, column_index: u64) -> Result<Vec<String>> {
    on_runtime(async move { cdata_core::session::column_choices(session_id, column_index).await })
        .await
}

/// 把结果集的一段写成文件，row_count 为 null 表示到末尾。行不经过 FFI
pub fn export_rows(
    session_id: u64,
    path: String,
    row_start: u64,
    row_count: Option<u64>,
    column_indexes: Vec<u64>,
    options: ExportOptions,
) -> Result<ExportSummary> {
    cdata_core::session::export_rows(session_id, &path, row_start, row_count, column_indexes, &options)
        .map_err(to_message)
}

/// 关会话并断开连接池
pub async fn close_session(session_id: u64) -> Result<()> {
    on_runtime(async move { cdata_core::session::close_session(session_id).await }).await
}
