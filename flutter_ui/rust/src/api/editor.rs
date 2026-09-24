//! SQL 编辑器的 FFI 接口：高亮用的词法切分、历史、收藏。规则都在 core。

use flutter_rust_bridge::frb;

pub use cdata_core::complete::{Completion, CompletionItem, CompletionKind};
pub use cdata_core::history::{Favorite, HistoryEntry};
pub use cdata_core::lexer::{SqlToken, SqlTokenKind};

use crate::api::db::{on_runtime, to_message, Result};

#[frb(mirror(SqlTokenKind))]
pub enum _SqlTokenKind {
    Keyword,
    Identifier,
    QuotedIdentifier,
    String,
    Number,
    Comment,
    Variable,
    Operator,
    Punctuation,
}

#[frb(mirror(SqlToken))]
pub struct _SqlToken {
    pub kind: SqlTokenKind,
    pub start: u32,
    pub end: u32,
}

#[frb(mirror(HistoryEntry))]
pub struct _HistoryEntry {
    pub sql: String,
    pub executed_at: i64,
}

#[frb(mirror(Favorite))]
pub struct _Favorite {
    pub id: String,
    pub name: String,
    pub sql: String,
}

#[frb(mirror(CompletionKind))]
pub enum _CompletionKind {
    Table,
    Column,
    Alias,
    Keyword,
}

#[frb(mirror(CompletionItem))]
pub struct _CompletionItem {
    pub label: String,
    pub insert_text: String,
    pub kind: CompletionKind,
    pub detail: String,
}

#[frb(mirror(Completion))]
pub struct _Completion {
    pub replace_start: u32,
    pub replace_end: u32,
    pub items: Vec<CompletionItem>,
}

/// 读一个库的表和列缓存在会话里，给补全用。返回表的数量
pub async fn load_catalog(session_id: u64, database: String) -> Result<u64> {
    on_runtime(async move { cdata_core::session::load_catalog(session_id, &database).await }).await
}

/// 补全。纯计算读缓存的目录，敲键时调，所以是同步调用。位置都是 UTF-16 下标
#[frb(sync)]
pub fn complete_sql(session_id: u64, sql: String, cursor: u32) -> Result<Completion> {
    cdata_core::session::complete_sql(session_id, &sql, cursor).map_err(to_message)
}

/// 切 token，位置是 UTF-16 下标。编辑器每次重绘都调，所以是同步调用
#[frb(sync)]
pub fn tokenize_sql(sql: String) -> Vec<SqlToken> {
    cdata_core::lexer::tokenize(&sql)
}

/// 执行过的 SQL，最新的在前
pub fn list_history() -> Result<Vec<HistoryEntry>> {
    cdata_core::history::history().map_err(|err| err.to_string())
}

pub fn add_history(sql: String) -> Result<()> {
    cdata_core::history::add_history(&sql).map_err(|err| err.to_string())
}

pub fn list_favorites() -> Result<Vec<Favorite>> {
    cdata_core::history::favorites().map_err(|err| err.to_string())
}

/// 收藏，同名覆盖，返回 id
pub fn save_favorite(name: String, sql: String) -> Result<String> {
    cdata_core::history::save_favorite(&name, &sql).map_err(|err| err.to_string())
}

pub fn delete_favorite(id: String) -> Result<()> {
    cdata_core::history::delete_favorite(&id).map_err(|err| err.to_string())
}
