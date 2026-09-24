//! 服务器状态页的 FFI 接口。进程、变量、状态、慢日志的读取和 KILL / SET GLOBAL 的拦截都在
//! cdata-core 的 server.rs，这里只做翻译。

use flutter_rust_bridge::frb;

pub use cdata_core::server::{
    KillMode, ProcessInfo, ProcessList, SetVariablePlan, SlowLogConfig, SlowLogEntry, StatusCounter, StatusSnapshot,
    Variable, VariableList, VariableScope,
};
use cdata_core::value::DisplayCell;

use crate::api::db::{on_runtime, Result};

#[frb(mirror(ProcessInfo))]
pub struct _ProcessInfo {
    pub id: u64,
    pub user: DisplayCell,
    pub host: DisplayCell,
    pub db: DisplayCell,
    pub command: DisplayCell,
    pub time: DisplayCell,
    pub state: DisplayCell,
    pub info: DisplayCell,
    pub is_own: bool,
}

#[frb(mirror(ProcessList))]
pub struct _ProcessList {
    pub processes: Vec<ProcessInfo>,
    pub truncated: bool,
    pub notice: Option<String>,
}

#[frb(mirror(KillMode))]
pub enum _KillMode {
    Query,
    Connection,
}

#[frb(mirror(VariableScope))]
pub enum _VariableScope {
    Global,
    Session,
}

#[frb(mirror(Variable))]
pub struct _Variable {
    pub name: String,
    pub value: DisplayCell,
}

#[frb(mirror(VariableList))]
pub struct _VariableList {
    pub variables: Vec<Variable>,
    pub truncated: bool,
}

#[frb(mirror(StatusCounter))]
pub struct _StatusCounter {
    pub name: String,
    pub value: DisplayCell,
    pub delta: Option<String>,
    pub rate: Option<String>,
}

#[frb(mirror(StatusSnapshot))]
pub struct _StatusSnapshot {
    pub taken_at_ms: u64,
    pub counters: Vec<StatusCounter>,
    pub truncated: bool,
}

#[frb(mirror(SlowLogConfig))]
pub struct _SlowLogConfig {
    pub slow_query_log: DisplayCell,
    pub log_output: DisplayCell,
    pub long_query_time: DisplayCell,
    pub slow_query_log_file: DisplayCell,
    pub enabled: bool,
    pub table_unavailable: Option<String>,
}

#[frb(mirror(SlowLogEntry))]
pub struct _SlowLogEntry {
    pub start_time: DisplayCell,
    pub user_host: DisplayCell,
    pub query_time: DisplayCell,
    pub lock_time: DisplayCell,
    pub rows_sent: DisplayCell,
    pub rows_examined: DisplayCell,
    pub db: DisplayCell,
    pub sql_text: DisplayCell,
}

#[frb(mirror(SetVariablePlan))]
pub struct _SetVariablePlan {
    pub statement: String,
    pub current_value: DisplayCell,
    pub warnings: Vec<String>,
}

/// 进程列表，CData 自己的连接标了 is_own
pub async fn server_processes(session_id: u64) -> Result<ProcessList> {
    on_runtime(async move { cdata_core::session::server_processes(session_id).await }).await
}

/// KILL QUERY / KILL CONNECTION。target 是用户确认时看到的那一行，和现在对不上 core 会拒绝
pub async fn kill_process(session_id: u64, target: ProcessInfo, mode: KillMode) -> Result<()> {
    on_runtime(async move { cdata_core::session::kill_process(session_id, &target, mode).await }).await
}

pub async fn server_variables(session_id: u64, scope: VariableScope) -> Result<VariableList> {
    on_runtime(async move { cdata_core::session::server_variables(session_id, scope).await }).await
}

/// SHOW GLOBAL STATUS。previous 是上一次拿到的快照，差值和每秒增量按它算
pub async fn server_status(session_id: u64, previous: Option<StatusSnapshot>) -> Result<StatusSnapshot> {
    on_runtime(async move { cdata_core::session::server_status(session_id, previous.as_ref()).await }).await
}

pub async fn slow_log_config(session_id: u64) -> Result<SlowLogConfig> {
    on_runtime(async move { cdata_core::session::slow_log_config(session_id).await }).await
}

pub async fn slow_log_entries(session_id: u64, limit: u32) -> Result<Vec<SlowLogEntry>> {
    on_runtime(async move { cdata_core::session::slow_log_entries(session_id, limit).await }).await
}

/// 预览 SET GLOBAL：语句、现在的值、影响范围
pub async fn preview_set_global(session_id: u64, name: String, value: String) -> Result<SetVariablePlan> {
    on_runtime(async move { cdata_core::session::preview_set_global(session_id, &name, &value).await }).await
}

/// 执行预览过的 SET GLOBAL，返回服务器存下的新值。statement 是预览拿到的语句
pub async fn apply_set_global(session_id: u64, name: String, value: String, statement: String) -> Result<DisplayCell> {
    on_runtime(async move { cdata_core::session::apply_set_global(session_id, &name, &value, &statement).await })
        .await
}
