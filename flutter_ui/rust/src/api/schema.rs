//! 库表清单的 FFI 接口。侧栏用。

use flutter_rust_bridge::frb;

pub use cdata_core::schema::TableInfo;
pub use cdata_core::alter::{
    AlterPlan, CheckDraft, ColumnDraft, ForeignKeyDraft, IndexDraft, IndexKind, TableDraft, TableOptionsDraft,
};
pub use cdata_core::structure::{
    CheckDef, ColumnDef, DefaultValue, ForeignKeyDef, IndexDef, IndexPart, TableStructure,
};

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
    pub parts: Vec<IndexPart>,
    pub index_type: String,
    pub comment: String,
}

#[frb(mirror(IndexPart))]
pub struct _IndexPart {
    pub column: Option<String>,
    pub prefix: Option<u32>,
    pub descending: bool,
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

#[frb(mirror(CheckDef))]
pub struct _CheckDef {
    pub name: String,
    pub expression: String,
    pub enforced: bool,
}

#[frb(mirror(TableStructure))]
pub struct _TableStructure {
    pub columns: Vec<ColumnDef>,
    pub indexes: Vec<IndexDef>,
    pub foreign_keys: Vec<ForeignKeyDef>,
    pub create_sql: String,
    pub table_collation: Option<String>,
    pub table_charset: Option<String>,
    pub engine: Option<String>,
    pub table_comment: String,
    pub auto_increment: Option<u64>,
    pub row_format: Option<String>,
    pub checks: Option<Vec<CheckDef>>,
}

#[frb(mirror(ColumnDraft))]
pub struct _ColumnDraft {
    pub original_name: Option<String>,
    pub name: String,
    pub column_type: String,
    pub nullable: bool,
    pub default: DefaultValue,
    pub auto_increment: bool,
    pub on_update: Option<String>,
    pub comment: String,
    pub collation: Option<String>,
    pub locked: Option<String>,
}

#[frb(mirror(IndexKind))]
pub enum _IndexKind {
    Primary,
    Unique,
    Normal,
    Fulltext,
    Spatial,
}

#[frb(mirror(IndexDraft))]
pub struct _IndexDraft {
    pub original_name: Option<String>,
    pub name: String,
    pub kind: IndexKind,
    pub parts: Vec<IndexPart>,
    pub comment: String,
    pub locked: Option<String>,
}

#[frb(mirror(ForeignKeyDraft))]
pub struct _ForeignKeyDraft {
    pub original_name: Option<String>,
    pub name: String,
    pub columns: Vec<String>,
    pub referenced_schema: String,
    pub referenced_table: String,
    pub referenced_columns: Vec<String>,
    pub on_update: String,
    pub on_delete: String,
}

#[frb(mirror(CheckDraft))]
pub struct _CheckDraft {
    pub original_name: Option<String>,
    pub name: String,
    pub expression: String,
    pub enforced: bool,
}

#[frb(mirror(TableOptionsDraft))]
pub struct _TableOptionsDraft {
    pub engine: String,
    pub charset: Option<String>,
    pub collation: Option<String>,
    pub comment: String,
    pub auto_increment: Option<u64>,
    pub row_format: Option<String>,
    pub convert_charset: bool,
}

#[frb(mirror(TableDraft))]
pub struct _TableDraft {
    pub columns: Vec<ColumnDraft>,
    pub indexes: Vec<IndexDraft>,
    pub foreign_keys: Vec<ForeignKeyDraft>,
    pub checks: Vec<CheckDraft>,
    pub options: TableOptionsDraft,
}

#[frb(mirror(AlterPlan))]
pub struct _AlterPlan {
    pub statements: Vec<String>,
    pub dangers: Vec<String>,
    pub notes: Vec<String>,
}

/// 读到的结构转成可编辑的草稿，哪些列、索引锁住由 core 判定
#[frb(sync)]
pub fn table_draft(structure: TableStructure) -> TableDraft {
    cdata_core::alter::table_draft(&structure)
}

/// 预览一批结构改动：语句、危险操作、执行须知
pub async fn preview_alter(
    session_id: u64,
    database: String,
    table: String,
    original: TableStructure,
    draft: TableDraft,
) -> Result<AlterPlan> {
    on_runtime(async move {
        cdata_core::session::preview_alter(session_id, &database, &table, &original, &draft).await
    })
    .await
}

/// 执行预览过的改动。statements 是预览时拿到的语句，重新生成的不一致就不执行
pub async fn apply_alter(
    session_id: u64,
    database: String,
    table: String,
    original: TableStructure,
    draft: TableDraft,
    statements: Vec<String>,
) -> Result<()> {
    on_runtime(async move {
        cdata_core::session::apply_alter(session_id, &database, &table, &original, &draft, &statements).await
    })
    .await
}

/// 新建表的起始草稿：自增主键 id、InnoDB，默认值由 core 定
#[frb(sync)]
pub fn new_table_draft() -> TableDraft {
    cdata_core::alter::new_table_draft()
}

/// 预览新建表。同名的表或视图已经存在就报错
pub async fn preview_create_table(
    session_id: u64,
    database: String,
    table: String,
    draft: TableDraft,
) -> Result<AlterPlan> {
    on_runtime(async move { cdata_core::session::preview_create_table(session_id, &database, &table, &draft).await })
        .await
}

/// 执行预览过的建表。statements 是预览时拿到的语句，重新生成的不一致就不执行
pub async fn create_table(
    session_id: u64,
    database: String,
    table: String,
    draft: TableDraft,
    statements: Vec<String>,
) -> Result<()> {
    on_runtime(async move {
        cdata_core::session::create_table(session_id, &database, &table, &draft, &statements).await
    })
    .await
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
