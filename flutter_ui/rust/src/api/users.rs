//! 用户与权限管理的 FFI 接口。语句生成、转义、拦截规则都在 cdata-core 的 users.rs，这里只做翻译。
//!
//! 密码只作为参数从 Dart 传进来，不出现在任何返回值里：预览的语句里是 `'***'`。

use flutter_rust_bridge::frb;

pub use cdata_core::users::{
    Account, AccountGrants, ChangePlan, GrantEntry, GrantLevel, GrantScope, UserAdmin, UserChange, UserRow,
};

use crate::api::db::{on_runtime, Result};

#[frb(mirror(Account))]
pub struct _Account {
    pub user: String,
    pub host: String,
}

#[frb(mirror(UserRow))]
pub struct _UserRow {
    pub account: Account,
    pub plugin: String,
    pub locked: bool,
    pub password_expired: Option<String>,
    pub is_current: bool,
}

#[frb(mirror(UserAdmin))]
pub struct _UserAdmin {
    pub current: Account,
    pub users: Vec<UserRow>,
    pub users_unavailable: Option<String>,
    pub plugins: Vec<String>,
    pub global_privileges: Vec<String>,
    pub database_privileges: Vec<String>,
    pub table_privileges: Vec<String>,
}

#[frb(mirror(GrantScope))]
pub enum _GrantScope {
    Global,
    Database,
    Table,
    Column,
    Routine,
    Role,
    Proxy,
    Unparsed,
}

#[frb(mirror(GrantEntry))]
pub struct _GrantEntry {
    pub scope: GrantScope,
    pub target: String,
    pub privileges: Vec<String>,
    pub grant_option: bool,
    pub partial_revoke: bool,
    pub role: Option<Account>,
    pub statement: String,
}

#[frb(mirror(AccountGrants))]
pub struct _AccountGrants {
    pub entries: Vec<GrantEntry>,
    pub statements: Vec<String>,
}

#[frb(mirror(GrantLevel))]
pub enum _GrantLevel {
    Global,
    Database { database: String },
    Table { database: String, table: String },
}

#[frb(mirror(UserChange))]
pub enum _UserChange {
    Create { account: Account, plugin: Option<String> },
    SetPassword { account: Account },
    SetLocked { account: Account, locked: bool },
    Drop { account: Account },
    Grant { account: Account, level: GrantLevel, privileges: Vec<String>, with_grant_option: bool },
    Revoke { account: Account, level: GrantLevel, privileges: Vec<String> },
    GrantRole { account: Account, role: Account },
    RevokeRole { account: Account, role: Account },
}

#[frb(mirror(ChangePlan))]
pub struct _ChangePlan {
    pub statement: String,
    pub dangers: Vec<String>,
    pub notes: Vec<String>,
}

/// 用户管理页打开时的全部信息，一次取齐
pub async fn load_user_admin(session_id: u64) -> Result<UserAdmin> {
    on_runtime(async move { cdata_core::session::load_user_admin(session_id).await }).await
}

/// 一个账号的 SHOW GRANTS：分层的项和原文
pub async fn account_grants(session_id: u64, account: Account) -> Result<AccountGrants> {
    on_runtime(async move { cdata_core::session::account_grants(session_id, &account).await }).await
}

/// 预览变更。password 只有新建和改密码时给
pub async fn preview_user_change(session_id: u64, change: UserChange, password: Option<String>) -> Result<ChangePlan> {
    on_runtime(async move {
        cdata_core::session::preview_user_change(session_id, &change, password.as_deref()).await
    })
    .await
}

/// 执行预览过的变更。statement 是预览时拿到的语句
pub async fn apply_user_change(
    session_id: u64,
    change: UserChange,
    password: Option<String>,
    statement: String,
) -> Result<()> {
    on_runtime(async move {
        cdata_core::session::apply_user_change(session_id, &change, password.as_deref(), &statement).await
    })
    .await
}
