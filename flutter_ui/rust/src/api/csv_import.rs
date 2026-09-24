//! CSV 导入的 FFI 接口。解析、NULL 规则、映射校验、写库全在 cdata-core 的 import.rs，这里只做翻译。
//!
//! 模块不叫 import：生成的 Dart 文件名会撞上 Dart 的关键字。

use flutter_rust_bridge::frb;

pub use cdata_core::import::{
    CsvPreview, ImportOptions, ImportOutcome, ImportProgress, ImportReport, ImportRequest, ImportStatus,
    ImportTarget, OnError, PreviewRow, RowError, TargetColumn,
};
use cdata_core::export::ExportEncoding;
use cdata_core::value::DisplayCell;

use crate::api::db::{on_runtime, to_message, Result};

#[frb(mirror(ImportOptions))]
pub struct _ImportOptions {
    pub encoding: ExportEncoding,
    pub delimiter: String,
    pub header: bool,
    pub null_text: String,
}

#[frb(mirror(PreviewRow))]
pub struct _PreviewRow {
    pub line: u64,
    pub cells: Vec<DisplayCell>,
    pub error: Option<String>,
}

#[frb(mirror(CsvPreview))]
pub struct _CsvPreview {
    pub header: Vec<String>,
    pub column_count: u64,
    pub rows: Vec<PreviewRow>,
    pub error: Option<String>,
}

#[frb(mirror(TargetColumn))]
pub struct _TargetColumn {
    pub name: String,
    pub column_type: String,
    pub nullable: bool,
    pub auto_increment: bool,
    pub is_binary: bool,
    pub generated: bool,
    pub mandatory: bool,
}

#[frb(mirror(ImportTarget))]
pub struct _ImportTarget {
    pub schema: String,
    pub table: String,
    pub columns: Vec<TargetColumn>,
    pub sql_mode: String,
    pub strict: bool,
}

#[frb(mirror(OnError))]
pub enum _OnError {
    RollbackAll,
    SkipRow,
}

#[frb(mirror(ImportRequest))]
pub struct _ImportRequest {
    pub path: String,
    pub options: ImportOptions,
    pub schema: String,
    pub table: String,
    pub mapping: Vec<Option<u32>>,
    pub batch_rows: u32,
    pub on_error: OnError,
}

#[frb(mirror(RowError))]
pub struct _RowError {
    pub line: u64,
    pub reason: String,
}

#[frb(mirror(ImportProgress))]
pub struct _ImportProgress {
    pub bytes_read: u64,
    pub total_bytes: u64,
    pub rows_read: u64,
    pub rows_inserted: u64,
    pub rows_failed: u64,
}

#[frb(mirror(ImportOutcome))]
pub enum _ImportOutcome {
    Completed,
    RolledBack,
    Stopped(String),
}

#[frb(mirror(ImportReport))]
pub struct _ImportReport {
    pub progress: ImportProgress,
    pub outcome: ImportOutcome,
    pub errors: Vec<RowError>,
}

#[frb(mirror(ImportStatus))]
pub enum _ImportStatus {
    Running(ImportProgress),
    Finished(ImportReport),
}

/// 读前 limit 行预览。有表头时表头不算在 limit 里
pub fn preview_csv(path: String, options: ImportOptions, limit: u64) -> Result<CsvPreview> {
    cdata_core::import::preview(&path, &options, limit as usize)
}

/// 按表头建议一个映射：下标是 CSV 列，值是目标列下标，null 表示跳过
#[frb(sync)]
pub fn suggest_mapping(header: Vec<String>, columns: Vec<TargetColumn>) -> Vec<Option<u32>> {
    cdata_core::import::suggest_mapping(&header, &columns)
}

/// 目标表的列（能不能写、要不要必填）和当前 sql_mode
pub async fn prepare_import(session_id: u64, database: String, table: String) -> Result<ImportTarget> {
    on_runtime(async move { cdata_core::session::prepare_import(session_id, &database, &table).await }).await
}

/// 在后台开始导入，返回任务 id。映射不对、文件打不开当场报错
pub async fn start_import(session_id: u64, request: ImportRequest) -> Result<u64> {
    on_runtime(async move { cdata_core::session::start_import(session_id, request).await }).await
}

/// 进度，结束后是报告。界面轮询
pub fn import_status(job_id: u64) -> Result<ImportStatus> {
    cdata_core::import::status(job_id).map_err(to_message)
}

pub fn cancel_import(job_id: u64) -> Result<()> {
    cdata_core::import::cancel(job_id).map_err(to_message)
}

/// 失败的行另存成 CSV，返回行数
pub fn save_import_errors(job_id: u64, path: String) -> Result<u64> {
    cdata_core::import::save_errors(job_id, &path).map_err(to_message)
}

/// 关掉任务并删掉错误行临时文件。对话框关闭时必须调
pub fn close_import(job_id: u64) -> Result<()> {
    cdata_core::import::close(job_id).map_err(to_message)
}
