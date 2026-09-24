//! 用户与权限管理：账号清单、SHOW GRANTS 的分层解析、账号和权限变更语句的生成与执行。
//!
//! **密码没法走参数**：MySQL 的 CREATE USER / ALTER USER 不接受 `IDENTIFIED BY ?`（9.6 实测，
//! 预处理和 PREPARE 都报 1064），只能写成字符串字面量拼进语句。所以：
//! - 预览出来的语句里密码一律写成 `'***'`。真正带密码的那条只在 apply_change 里现拼、执行完就丢，
//!   不进返回值、不进报错；
//! - 字面量按执行它的那条连接的 sql_mode 转义：单引号双写，没开 NO_BACKSLASH_ESCAPES 时反斜杠双写。
//!   连接字符集固定 utf8mb4（db.rs 的 SET NAMES），不存在 GBK 那种多字节吃掉反斜杠的问题；
//! - 密码不放进 UserChange，单独传：FRB 生成的 Dart 类 toString 会带上所有字段，放进去哪天就被打进日志；
//! - 执行失败的报错里抹掉密码。语法错误（1064）的 `near '…'` 可能带着被截断的密码片段，整条换掉。

use mysql_async::prelude::*;
use mysql_async::Conn;
use serde::{Deserialize, Serialize};

use crate::session::{Error, Result};
use crate::sql::quote_ident;

/// 预览里代替密码的字面量
const MASKED_PASSWORD: &str = "'***'";

const ALL_PRIVILEGES: &str = "ALL PRIVILEGES";
const GRANT_OPTION: &str = "GRANT OPTION";

/// ER_PARSE_ERROR：报错带着出错位置之后的语句片段
const ER_PARSE_ERROR: u16 = 1064;
/// ER_TABLEACCESS_DENIED_ERROR：没有读 mysql.user 的权限
const ER_TABLEACCESS_DENIED: u16 = 1142;

/// 库级能授的静态权限（MySQL 手册「Permissible Privileges for GRANT and REVOKE」）。
/// SHOW PRIVILEGES 的 Context 列粒度不够（比如 Select 只写了 Tables），分层按手册来，再和服务器的清单取交集
const DATABASE_PRIVILEGES: &[&str] = &[
    "ALTER", "ALTER ROUTINE", "CREATE", "CREATE ROUTINE", "CREATE TEMPORARY TABLES", "CREATE VIEW", "DELETE",
    "DROP", "EVENT", "EXECUTE", "INDEX", "INSERT", "LOCK TABLES", "REFERENCES", "SELECT", "SHOW VIEW", "TRIGGER",
    "UPDATE",
];

/// 表级能授的静态权限
const TABLE_PRIVILEGES: &[&str] = &[
    "ALTER", "CREATE", "CREATE VIEW", "DELETE", "DROP", "INDEX", "INSERT", "REFERENCES", "SELECT", "SHOW VIEW",
    "TRIGGER", "UPDATE",
];

/// 一个 MySQL 账号。用户名区分大小写，主机名不区分
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Account {
    pub user: String,
    pub host: String,
}

impl Account {
    /// 写进语句的形式：两段都用反引号，不受 NO_BACKSLASH_ESCAPES 影响
    fn sql(&self) -> String {
        format!("{}@{}", quote_ident(&self.user), quote_ident(&self.host))
    }

    /// 提示文字里的写法，和 MySQL 报错里的一致
    pub fn label(&self) -> String {
        format!("'{}'@'{}'", self.user, self.host)
    }

    fn same(&self, other: &Account) -> bool {
        self.user == other.user && self.host.eq_ignore_ascii_case(&other.host)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UserRow {
    pub account: Account,
    pub plugin: String,
    pub locked: bool,
    /// 密码过期的原因，没过期是 None
    pub password_expired: Option<String>,
    /// 就是当前登录的这个账号
    pub is_current: bool,
}

/// 用户管理页打开时要的全部东西，一次取齐
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UserAdmin {
    /// CURRENT_USER()：服务器实际用来认证的账号，可能是 `%` 这类通配主机
    pub current: Account,
    pub users: Vec<UserRow>,
    /// 读不了 mysql.user 的原因。这时 users 为空，只能看当前账号自己的权限
    pub users_unavailable: Option<String>,
    /// 服务器上已启用的认证插件
    pub plugins: Vec<String>,
    /// 各层能勾选的权限，按 SHOW PRIVILEGES 的顺序。ALL PRIVILEGES、GRANT OPTION 不在里面，单独勾
    pub global_privileges: Vec<String>,
    pub database_privileges: Vec<String>,
    pub table_privileges: Vec<String>,
}

/// 权限的层级。界面按这个顺序分组
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum GrantScope {
    Global,
    Database,
    Table,
    Column,
    /// 存储过程、函数
    Routine,
    Role,
    Proxy,
    /// 解析不了的语句，原文照登
    Unparsed,
}

/// SHOW GRANTS 里的一项
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GrantEntry {
    pub scope: GrantScope,
    /// 显示用：`*.*`、`shop.*`、`shop.orders`、`shop.orders.amount`、`PROCEDURE shop.p`、角色账号。
    /// 库名保持 MySQL 存的样子，`cdata\_dev` 里的反斜杠表示 _ 不当通配符
    pub target: String,
    pub privileges: Vec<String>,
    /// WITH GRANT OPTION；角色是 WITH ADMIN OPTION
    pub grant_option: bool,
    /// partial_revokes 开着时的 REVOKE 行：从上一层的权限里扣掉这一块
    pub partial_revoke: bool,
    /// 角色授予时是哪个角色
    pub role: Option<Account>,
    /// 出自哪条语句
    pub statement: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AccountGrants {
    pub entries: Vec<GrantEntry>,
    /// SHOW GRANTS 的原文，复制用
    pub statements: Vec<String>,
}

/// 授权 / 回收的层级
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum GrantLevel {
    Global,
    Database { database: String },
    Table { database: String, table: String },
}

/// 一次账号或权限变更。密码不在这里，单独传（见模块注释）
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum UserChange {
    /// plugin 为 None 用服务器默认
    Create { account: Account, plugin: Option<String> },
    SetPassword { account: Account },
    SetLocked { account: Account, locked: bool },
    Drop { account: Account },
    Grant { account: Account, level: GrantLevel, privileges: Vec<String>, with_grant_option: bool },
    /// privileges 里可以有 GRANT OPTION
    Revoke { account: Account, level: GrantLevel, privileges: Vec<String> },
    GrantRole { account: Account, role: Account },
    RevokeRole { account: Account, role: Account },
}

impl UserChange {
    fn account(&self) -> &Account {
        match self {
            UserChange::Create { account, .. }
            | UserChange::SetPassword { account }
            | UserChange::SetLocked { account, .. }
            | UserChange::Drop { account }
            | UserChange::Grant { account, .. }
            | UserChange::Revoke { account, .. }
            | UserChange::GrantRole { account, .. }
            | UserChange::RevokeRole { account, .. } => account,
        }
    }

    fn needs_password(&self) -> bool {
        matches!(self, UserChange::Create { .. } | UserChange::SetPassword { .. })
    }
}

/// 预览。statement 里的密码是 `'***'`
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChangePlan {
    pub statement: String,
    /// 醒目提示的风险
    pub dangers: Vec<String>,
    /// 执行须知
    pub notes: Vec<String>,
}

/// 生成语句要用到的服务器状态。预览和执行各在自己的连接上读一次
#[derive(Debug, Clone)]
struct Context {
    current: Account,
    /// 当前账号直接被授予的角色（不追嵌套的角色）
    current_roles: Vec<Account>,
    global_privileges: Vec<String>,
    database_privileges: Vec<String>,
    table_privileges: Vec<String>,
    plugins: Vec<String>,
    /// 开着时库级授权里的 _ 和 % 不是通配符
    partial_revokes: bool,
    /// 进程列表里能看到的、用户名和目标账号相同的连接数。只在删除时读
    connections: u64,
}

/// 用户管理页打开时读的全部信息。没权限读 mysql.user 不算失败，带着原因返回
pub async fn load(conn: &mut Conn) -> Result<UserAdmin> {
    check_version(conn).await?;
    let current = current_account(conn).await?;
    let (global_privileges, database_privileges, table_privileges) = server_privileges(conn).await?;
    let plugins = auth_plugins(conn).await?;

    let default_lifetime: u32 = conn.query_first("SELECT @@GLOBAL.default_password_lifetime").await?.unwrap_or(0);
    let listed: std::result::Result<Vec<(String, String, String, String, String, Option<u32>, Option<i64>)>, _> = conn
        .query(
            "SELECT User, Host, plugin, account_locked, password_expired, password_lifetime, \
             TIMESTAMPDIFF(SECOND, password_last_changed, NOW()) FROM mysql.user ORDER BY User, Host",
        )
        .await;

    let mut users = Vec::new();
    let mut users_unavailable = None;
    match listed {
        Ok(rows) => {
            for (user, host, plugin, locked, expired, lifetime, since_change) in rows {
                let account = Account { user, host };
                users.push(UserRow {
                    is_current: account.same(&current),
                    account,
                    plugin,
                    locked: locked == "Y",
                    password_expired: password_expired(&expired, lifetime, default_lifetime, since_change),
                });
            }
        }
        Err(mysql_async::Error::Server(err)) if err.code == ER_TABLEACCESS_DENIED => {
            users_unavailable = Some(format!(
                "当前账号 {} 没有读 mysql.user 的权限，列不出服务器上的账号（{}）。下面只能查看当前账号自己的权限",
                current.label(),
                err.message
            ));
        }
        Err(err) => return Err(err.into()),
    }

    Ok(UserAdmin {
        current,
        users,
        users_unavailable,
        plugins,
        global_privileges,
        database_privileges,
        table_privileges,
    })
}

/// 一个账号的 SHOW GRANTS，逐条解析成分层的项，原文一并带上
pub async fn account_grants(conn: &mut Conn, account: &Account) -> Result<AccountGrants> {
    check_account(account).map_err(Error::BadInput)?;
    let statements: Vec<String> = conn.query(format!("SHOW GRANTS FOR {}", account.sql())).await?;
    let mut entries = Vec::new();
    for statement in &statements {
        entries.extend(parse_grant(statement));
    }
    Ok(AccountGrants { entries, statements })
}

/// 预览一次变更。当前登录账号的删除、锁定、回收在这里就拒绝
pub async fn preview_change(conn: &mut Conn, change: &UserChange, password: Option<&str>) -> Result<ChangePlan> {
    let context = read_context(conn, change).await?;
    plan(change, &context, password).map_err(Error::BadInput)
}

/// 执行预览过的变更。在这条连接上重新读状态、重新生成，和预览的语句不一致就不执行；
/// 带密码的那条按这条连接的 sql_mode 转义
pub async fn apply_change(conn: &mut Conn, change: &UserChange, password: Option<&str>, previewed: &str) -> Result<()> {
    let context = read_context(conn, change).await?;
    let plan = plan(change, &context, password).map_err(Error::BadInput)?;
    if plan.statement != previewed {
        return Err(Error::BadInput(
            "要执行的语句和预览时不一样了（服务器设置或当前账号变了），请重新预览".to_string(),
        ));
    }

    let sql_mode: String = conn.query_first("SELECT @@SESSION.sql_mode").await?.unwrap_or_default();
    let no_backslash_escapes = sql_mode.split(',').any(|mode| mode == "NO_BACKSLASH_ESCAPES");
    // 不带密码的变更用不到这个字面量
    let password_sql = match password {
        Some(password) => crate::alter::sql_string(password, no_backslash_escapes),
        None => MASKED_PASSWORD.to_string(),
    };
    let sql = statement(change, &context, &password_sql).map_err(Error::BadInput)?;
    conn.query_drop(&sql).await.map_err(|err| scrub(err, password))
}

/// 用户管理和结构编辑同一道门槛：MySQL 8.0.13+，MariaDB 的账号表和角色语法都不一样
async fn check_version(conn: &mut Conn) -> Result<()> {
    let version: String = conn.query_first("SELECT VERSION()").await?.unwrap_or_default();
    if !crate::alter::supports_alter(&version) {
        return Err(Error::BadInput(format!(
            "用户管理只支持 MySQL 8.0.13 及以上（当前 {version}）：更早的版本和 MariaDB 的账号表、SHOW GRANTS 格式不同"
        )));
    }
    Ok(())
}

async fn current_account(conn: &mut Conn) -> Result<Account> {
    let text: String = conn
        .query_first("SELECT CURRENT_USER()")
        .await?
        .ok_or_else(|| Error::BadInput("CURRENT_USER() 没有返回值".to_string()))?;
    // 主机名里不会有 @，用户名里可能有，所以从右边切
    let (user, host) = text
        .rsplit_once('@')
        .ok_or_else(|| Error::BadInput(format!("CURRENT_USER() 返回了看不懂的值：{text}")))?;
    Ok(Account { user: user.to_string(), host: host.to_string() })
}

/// SHOW PRIVILEGES 分成全局 / 库 / 表三层。USAGE 不是权限，PROXY 语法不同，GRANT OPTION 单独勾
async fn server_privileges(conn: &mut Conn) -> Result<(Vec<String>, Vec<String>, Vec<String>)> {
    let rows: Vec<(String, String, String)> = conn.query("SHOW PRIVILEGES").await?;
    let mut global = Vec::new();
    let mut database = Vec::new();
    let mut table = Vec::new();
    for (name, _context, _comment) in rows {
        let upper = name.to_ascii_uppercase();
        if matches!(upper.as_str(), "USAGE" | "PROXY" | GRANT_OPTION) {
            continue;
        }
        if DATABASE_PRIVILEGES.contains(&upper.as_str()) {
            database.push(upper.clone());
        }
        if TABLE_PRIVILEGES.contains(&upper.as_str()) {
            table.push(upper.clone());
        }
        global.push(upper);
    }
    Ok((global, database, table))
}

async fn auth_plugins(conn: &mut Conn) -> Result<Vec<String>> {
    Ok(conn
        .query(
            "SELECT PLUGIN_NAME FROM information_schema.PLUGINS \
             WHERE PLUGIN_TYPE = 'AUTHENTICATION' AND PLUGIN_STATUS = 'ACTIVE' ORDER BY PLUGIN_NAME",
        )
        .await?)
}

async fn read_context(conn: &mut Conn, change: &UserChange) -> Result<Context> {
    check_version(conn).await?;
    let current = current_account(conn).await?;

    // SHOW GRANTS 不带 FOR 查的是自己，不需要额外权限
    let own: Vec<String> = conn.query("SHOW GRANTS").await?;
    let mut current_roles = Vec::new();
    for line in &own {
        for entry in parse_grant(line) {
            if let Some(role) = entry.role {
                current_roles.push(role);
            }
        }
    }

    let (global_privileges, database_privileges, table_privileges) = server_privileges(conn).await?;
    let plugins = auth_plugins(conn).await?;
    let partial_revokes: i64 = conn.query_first("SELECT @@GLOBAL.partial_revokes").await?.unwrap_or(0);

    let mut connections = 0;
    if let UserChange::Drop { account } = change {
        // 进程列表只有用户名没有账号的主机部分；没有 PROCESS 权限时只看得到自己的连接
        connections = conn
            .exec_first("SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE USER = ?", (account.user.as_str(),))
            .await?
            .unwrap_or(0);
    }

    Ok(Context {
        current,
        current_roles,
        global_privileges,
        database_privileges,
        table_privileges,
        plugins,
        partial_revokes: partial_revokes != 0,
        connections,
    })
}

/// 密码过期的原因。password_lifetime 为 NULL 跟随全局 default_password_lifetime，0 表示永不过期
fn password_expired(flag: &str, lifetime: Option<u32>, default_lifetime: u32, seconds_since_change: Option<i64>) -> Option<String> {
    if flag == "Y" {
        return Some("已被设为过期，下次登录必须先改密码".to_string());
    }
    let (days, source) = match lifetime {
        Some(days) => (days, "账号"),
        None => (default_lifetime, "全局 default_password_lifetime"),
    };
    if days == 0 {
        return None;
    }
    let elapsed = seconds_since_change?;
    if elapsed > i64::from(days) * 86_400 {
        return Some(format!("超过了{source}设定的 {days} 天有效期"));
    }
    None
}

/// 生成预览：校验、拦截当前账号、列出风险和须知
fn plan(change: &UserChange, context: &Context, password: Option<&str>) -> std::result::Result<ChangePlan, String> {
    check_password(change, password)?;
    let target = change.account();
    let label = target.label();
    let is_self = target.same(&context.current);
    let is_own_role = context.current_roles.iter().any(|role| role.same(target));

    match change {
        UserChange::Drop { .. } if is_self => {
            return Err(format!("{label} 是当前登录的账号，不能删除：删掉之后这条连接一断就再也登不回来"));
        }
        UserChange::SetLocked { locked: true, .. } if is_self => {
            return Err(format!("{label} 是当前登录的账号，不能锁定：锁上之后新连接（包括断线重连）都登不上"));
        }
        UserChange::Revoke { .. } | UserChange::RevokeRole { .. } if is_self => {
            return Err(format!(
                "{label} 是当前登录的账号，不在这里回收它自己的权限，免得把自己锁在外面；确实要收，请换一个有权限的账号来做"
            ));
        }
        _ => {}
    }

    let statement = statement(change, context, MASKED_PASSWORD)?;
    let mut dangers = Vec::new();
    let mut notes = Vec::new();
    if change.needs_password() {
        notes.push("密码在预览里显示为 ***，只在执行时发给服务器".to_string());
    }

    match change {
        UserChange::Create { plugin: None, .. } => {
            notes.push("认证插件用服务器默认（authentication_policy 的第一项）".to_string());
        }
        UserChange::Create { .. } => {}
        UserChange::SetPassword { .. } => {
            if is_self {
                dangers.push(format!(
                    "{label} 是当前登录的账号：已经连着的连接不受影响，但这个应用保存的连接密码还是旧的，\
                     之后新开的连接（包括断线重连）会登不上，改完请到连接设置里更新密码"
                ));
            }
            notes.push("已经连着的会话不受影响；账号上「密码已过期」的标记会一起清掉".to_string());
        }
        UserChange::SetLocked { locked: true, .. } => {
            notes.push("锁定只拦新连接，已经连着的会话不会被断开".to_string());
        }
        UserChange::SetLocked { locked: false, .. } => {}
        UserChange::Drop { account } => {
            dangers.push(format!("删除账号 {label}：它的全部权限一起删掉，撤不回来"));
            let mut kept = "DROP USER 不会断开这个账号已有的连接：已经连着的会话照常可用，直到它自己断开；\
                            要立刻切断，请到进程列表里 KILL 它的连接"
                .to_string();
            if context.connections > 0 {
                kept.push_str(&format!(
                    "。进程列表里现在能看到 {} 个用户名为 {} 的连接",
                    context.connections, account.user
                ));
            }
            dangers.push(kept);
        }
        UserChange::Grant { level, with_grant_option, .. } => {
            if *with_grant_option {
                notes.push("WITH GRANT OPTION：这个账号可以把它在这一层的权限再授予别人".to_string());
            }
            level_notes(level, context, &mut notes);
        }
        UserChange::Revoke { level, privileges, .. } => {
            for privilege in privileges {
                let upper = privilege.to_ascii_uppercase();
                if upper == ALL_PRIVILEGES {
                    dangers.push(format!("回收 ALL PRIVILEGES：{label} 在这一层的全部权限都会被收回"));
                }
                if upper == GRANT_OPTION {
                    dangers.push(format!("回收 GRANT OPTION：{label} 之后不能再把这一层的权限授予别人"));
                }
            }
            level_notes(level, context, &mut notes);
        }
        UserChange::GrantRole { .. } => {
            notes.push(
                "角色要激活才生效：登录后 SET ROLE，或设为默认角色（SET DEFAULT ROLE），或服务器开了 activate_all_roles_on_login"
                    .to_string(),
            );
        }
        UserChange::RevokeRole { .. } => {
            notes.push("已经 SET ROLE 激活了这个角色的会话，要重新设置角色或重新连接才失去它的权限".to_string());
        }
    }

    if is_own_role && matches!(change, UserChange::Drop { .. } | UserChange::Revoke { .. }) {
        dangers.push(format!(
            "{label} 是当前登录账号 {} 的角色：改完之后你自己从这个角色得到的权限也没了",
            context.current.label()
        ));
    }

    Ok(ChangePlan { statement, dangers, notes })
}

fn level_notes(level: &GrantLevel, context: &Context, notes: &mut Vec<String>) {
    if let GrantLevel::Database { database } = level {
        if !context.partial_revokes && (database.contains('_') || database.contains('%')) {
            notes.push(format!(
                "库级授权里 _ 和 % 是通配符，库名 {database} 里的已转义成 \\_ \\%，只匹配这一个库"
            ));
        }
    }
    notes.push(
        "已经连着的会话：表级权限的变化下一条语句就生效，库级的要等下一次 USE，全局的要重新连接才生效".to_string(),
    );
}

fn check_password(change: &UserChange, password: Option<&str>) -> std::result::Result<(), String> {
    match (change.needs_password(), password) {
        (true, None) => Err("要填密码".to_string()),
        (true, Some("")) => Err("密码不能为空：空密码的账号知道用户名就能登录".to_string()),
        (true, Some(password)) if password.contains('\0') => Err("密码里不能有 NUL 字符".to_string()),
        (false, Some(_)) => Err("这个操作不需要密码".to_string()),
        _ => Ok(()),
    }
}

/// 名字里有 NUL 的话反引号也包不住
fn check_name(name: &str, what: &str) -> std::result::Result<(), String> {
    if name.contains('\0') {
        return Err(format!("{what}里不能有 NUL 字符"));
    }
    Ok(())
}

fn check_account(account: &Account) -> std::result::Result<(), String> {
    check_name(&account.user, "用户名")?;
    check_name(&account.host, "主机")
}

/// 生成语句。password_sql 是已经转义好的字面量，预览时是 `'***'`
fn statement(change: &UserChange, context: &Context, password_sql: &str) -> std::result::Result<String, String> {
    check_account(change.account())?;
    let sql = match change {
        UserChange::Create { account, plugin } => {
            if account.user.is_empty() {
                return Err("用户名不能为空：匿名账号会匹配任意用户名，不在这里建".to_string());
            }
            if account.host.is_empty() {
                return Err("主机不能为空；允许从任意主机登录请写 %".to_string());
            }
            let with = match plugin {
                None => String::new(),
                Some(plugin) => {
                    // 插件名直接写进语句，只认服务器上启用的
                    if !context.plugins.contains(plugin) {
                        return Err(format!("服务器上没有启用认证插件 {plugin}"));
                    }
                    format!(" WITH {plugin}")
                }
            };
            format!("CREATE USER {} IDENTIFIED{with} BY {password_sql}", account.sql())
        }
        UserChange::SetPassword { account } => format!("ALTER USER {} IDENTIFIED BY {password_sql}", account.sql()),
        UserChange::SetLocked { account, locked } => {
            format!("ALTER USER {} ACCOUNT {}", account.sql(), if *locked { "LOCK" } else { "UNLOCK" })
        }
        UserChange::Drop { account } => format!("DROP USER {}", account.sql()),
        UserChange::Grant { account, level, privileges, with_grant_option } => format!(
            "GRANT {} ON {} TO {}{}",
            privilege_list(level, privileges, context, false)?,
            level_sql(level, context.partial_revokes)?,
            account.sql(),
            if *with_grant_option { " WITH GRANT OPTION" } else { "" }
        ),
        UserChange::Revoke { account, level, privileges } => format!(
            "REVOKE {} ON {} FROM {}",
            privilege_list(level, privileges, context, true)?,
            level_sql(level, context.partial_revokes)?,
            account.sql()
        ),
        UserChange::GrantRole { account, role } | UserChange::RevokeRole { account, role } => {
            check_account(role)?;
            if role.same(account) {
                return Err("不能把账号作为角色授予它自己".to_string());
            }
            match change {
                UserChange::GrantRole { .. } => format!("GRANT {} TO {}", role.sql(), account.sql()),
                _ => format!("REVOKE {} FROM {}", role.sql(), account.sql()),
            }
        }
    };
    Ok(sql)
}

/// 权限名直接写进语句，所以只认服务器在这一层支持的名字
fn privilege_list(
    level: &GrantLevel,
    privileges: &[String],
    context: &Context,
    revoke: bool,
) -> std::result::Result<String, String> {
    let (allowed, level_name) = match level {
        GrantLevel::Global => (&context.global_privileges, "全局"),
        GrantLevel::Database { .. } => (&context.database_privileges, "库级"),
        GrantLevel::Table { .. } => (&context.table_privileges, "表级"),
    };
    if privileges.is_empty() {
        return Err("没有选权限".to_string());
    }

    let mut names: Vec<String> = Vec::new();
    for privilege in privileges {
        let upper = privilege.to_ascii_uppercase();
        let known = upper == ALL_PRIVILEGES || (revoke && upper == GRANT_OPTION) || allowed.contains(&upper);
        let plain = upper.chars().all(|ch| ch.is_ascii_alphanumeric() || ch == '_' || ch == ' ');
        if !known || !plain {
            if upper == GRANT_OPTION {
                return Err("授予 GRANT OPTION 请勾选 WITH GRANT OPTION".to_string());
            }
            return Err(format!("「{privilege}」不是服务器支持的{level_name}权限"));
        }
        if !names.contains(&upper) {
            names.push(upper);
        }
    }
    let has_all = names.iter().any(|name| name == ALL_PRIVILEGES);
    if has_all && names.iter().any(|name| name != ALL_PRIVILEGES && name != GRANT_OPTION) {
        return Err("ALL PRIVILEGES 已经包含这一层的其他权限，不要和它们一起选".to_string());
    }
    Ok(names.join(", "))
}

fn level_sql(level: &GrantLevel, partial_revokes: bool) -> std::result::Result<String, String> {
    match level {
        GrantLevel::Global => Ok("*.*".to_string()),
        GrantLevel::Database { database } => {
            if database.is_empty() {
                return Err("没有填库名".to_string());
            }
            check_name(database, "库名")?;
            // 库级授权里 _ 和 % 是通配符（partial_revokes 开着时除外），不转义的话 cdata_dev 会连 cdataxdev 一起授出去。
            // 反斜杠本身是转义符，库名里带反斜杠没法写得不含糊
            if partial_revokes {
                return Ok(format!("{}.*", quote_ident(database)));
            }
            if database.contains('\\') {
                return Err(format!("库名 {database} 里有反斜杠：它在库级授权里是转义符，没法保证只匹配这一个库"));
            }
            let escaped = database.replace('_', "\\_").replace('%', "\\%");
            Ok(format!("{}.*", quote_ident(&escaped)))
        }
        GrantLevel::Table { database, table } => {
            if database.is_empty() || table.is_empty() {
                return Err("没有填库名或表名".to_string());
            }
            check_name(database, "库名")?;
            check_name(table, "表名")?;
            // 表级授权里的库名不是通配模式，原样写
            Ok(format!("{}.{}", quote_ident(database), quote_ident(table)))
        }
    }
}

/// 执行失败的报错里抹掉密码。语法错误带着截断的语句片段，可能只剩密码的一截，整条换掉
fn scrub(err: mysql_async::Error, password: Option<&str>) -> Error {
    let Some(password) = password else {
        return Error::from(err);
    };
    if let mysql_async::Error::Server(server) = &err {
        if server.code == ER_PARSE_ERROR {
            return Error::EditFailed(
                "MySQL 报语法错误（1064）。原始报错里带着语句片段，可能含密码，已隐去".to_string(),
            );
        }
    }
    let mut message = Error::from(err).to_string();
    for form in [
        crate::alter::sql_string(password, false),
        crate::alter::sql_string(password, true),
        password.to_string(),
    ] {
        // 两种转义形式去掉外面那对引号，最后是原文
        let inner = if form.starts_with('\'') { &form[1..form.len() - 1] } else { form.as_str() };
        message = message.replace(inner, "***");
    }
    Error::EditFailed(message)
}

#[derive(Debug, Clone, PartialEq)]
enum Token {
    /// 转成大写
    Word(String),
    /// 反引号或单引号里的内容，双写的引号已还原
    Quoted(String),
    Symbol(char),
}

/// 没闭合的引号返回 None
fn tokenize(line: &str) -> Option<Vec<Token>> {
    let chars: Vec<char> = line.chars().collect();
    let mut tokens = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        let ch = chars[i];
        if ch.is_whitespace() {
            i += 1;
            continue;
        }
        if ch == '`' || ch == '\'' {
            let mut text = String::new();
            i += 1;
            loop {
                let inner = *chars.get(i)?;
                i += 1;
                if inner != ch {
                    text.push(inner);
                    continue;
                }
                if chars.get(i) == Some(&ch) {
                    text.push(ch);
                    i += 1;
                    continue;
                }
                break;
            }
            tokens.push(Token::Quoted(text));
            continue;
        }
        if ch.is_ascii_alphanumeric() || ch == '_' {
            let start = i;
            while i < chars.len() && (chars[i].is_ascii_alphanumeric() || chars[i] == '_') {
                i += 1;
            }
            let word: String = chars[start..i].iter().collect();
            tokens.push(Token::Word(word.to_ascii_uppercase()));
            continue;
        }
        tokens.push(Token::Symbol(ch));
        i += 1;
    }
    Some(tokens)
}

fn is_word(token: Option<&Token>, word: &str) -> bool {
    matches!(token, Some(Token::Word(w)) if w == word)
}

/// `user`@`host`，返回账号和下一个位置
fn account_at(tokens: &[Token], pos: usize) -> Option<(Account, usize)> {
    match (tokens.get(pos)?, tokens.get(pos + 1)?, tokens.get(pos + 2)?) {
        (Token::Quoted(user), Token::Symbol('@'), Token::Quoted(host)) => {
            Some((Account { user: user.clone(), host: host.clone() }, pos + 3))
        }
        _ => None,
    }
}

/// SHOW GRANTS 的一行拆成若干项。看不懂的整行作为一项 Unparsed，原文照登
pub fn parse_grant(line: &str) -> Vec<GrantEntry> {
    if let Some(entries) = parse_grant_tokens(line) {
        return entries;
    }
    vec![GrantEntry {
        scope: GrantScope::Unparsed,
        target: String::new(),
        privileges: Vec::new(),
        grant_option: false,
        partial_revoke: false,
        role: None,
        statement: line.to_string(),
    }]
}

fn parse_grant_tokens(line: &str) -> Option<Vec<GrantEntry>> {
    let tokens = tokenize(line)?;
    let partial_revoke = match tokens.first()? {
        Token::Word(word) if word == "GRANT" => false,
        Token::Word(word) if word == "REVOKE" => true,
        _ => return None,
    };
    let entry = |scope, target: String, privileges: Vec<String>, grant_option, role| GrantEntry {
        scope,
        target,
        privileges,
        grant_option,
        partial_revoke,
        role,
        statement: line.to_string(),
    };

    // 角色：GRANT `r1`@`%`,`r2`@`%` TO `u`@`h` [WITH ADMIN OPTION]
    if matches!(tokens.get(1), Some(Token::Quoted(_))) {
        let mut roles = Vec::new();
        let mut pos = 1;
        loop {
            let (role, next) = account_at(&tokens, pos)?;
            roles.push(role);
            pos = next;
            match tokens.get(pos)? {
                Token::Symbol(',') => pos += 1,
                Token::Word(word) if word == "TO" || word == "FROM" => break,
                _ => return None,
            }
        }
        let (_, next) = account_at(&tokens, pos + 1)?;
        let admin = tail_option(&tokens[next..], "ADMIN")?;
        let mut entries = Vec::new();
        for role in roles {
            entries.push(entry(GrantScope::Role, role.label(), Vec::new(), admin, Some(role)));
        }
        return Some(entries);
    }

    // 权限列表到 ON 为止，每项可以带列清单：SELECT (`a`, `b`)
    let mut items: Vec<(String, Vec<String>)> = Vec::new();
    let mut pos = 1;
    loop {
        let mut words = Vec::new();
        while let Some(Token::Word(word)) = tokens.get(pos) {
            if word == "ON" {
                break;
            }
            words.push(word.clone());
            pos += 1;
        }
        if words.is_empty() {
            return None;
        }
        let mut columns = Vec::new();
        if tokens.get(pos) == Some(&Token::Symbol('(')) {
            pos += 1;
            loop {
                let Token::Quoted(column) = tokens.get(pos)? else { return None };
                columns.push(column.clone());
                pos += 1;
                match tokens.get(pos)? {
                    Token::Symbol(',') => pos += 1,
                    Token::Symbol(')') => {
                        pos += 1;
                        break;
                    }
                    _ => return None,
                }
            }
        }
        items.push((words.join(" "), columns));
        match tokens.get(pos)? {
            Token::Symbol(',') => pos += 1,
            Token::Word(word) if word == "ON" => {
                pos += 1;
                break;
            }
            _ => return None,
        }
    }

    // GRANT PROXY ON `u`@`h` TO …
    if items.len() == 1 && items[0].0 == "PROXY" {
        let (proxied, next) = account_at(&tokens, pos)?;
        if !is_word(tokens.get(next), "TO") {
            return None;
        }
        let (_, next) = account_at(&tokens, next + 1)?;
        let grant_option = tail_option(&tokens[next..], "GRANT")?;
        return Some(vec![entry(GrantScope::Proxy, proxied.label(), vec!["PROXY".to_string()], grant_option, None)]);
    }

    let mut routine = None;
    if let Some(Token::Word(word)) = tokens.get(pos) {
        match word.as_str() {
            "TABLE" => pos += 1,
            "FUNCTION" | "PROCEDURE" => {
                routine = Some(word.clone());
                pos += 1;
            }
            _ => return None,
        }
    }
    let database = match tokens.get(pos)? {
        Token::Symbol('*') => None,
        Token::Quoted(name) => Some(name.clone()),
        _ => return None,
    };
    if tokens.get(pos + 1)? != &Token::Symbol('.') {
        return None;
    }
    let object = match tokens.get(pos + 2)? {
        Token::Symbol('*') => None,
        Token::Quoted(name) => Some(name.clone()),
        _ => return None,
    };
    pos += 3;
    if !is_word(tokens.get(pos), "TO") && !is_word(tokens.get(pos), "FROM") {
        return None;
    }
    let (_, next) = account_at(&tokens, pos + 1)?;
    let grant_option = tail_option(&tokens[next..], "GRANT")?;

    let (scope, target) = match (&routine, &database, &object) {
        (None, None, None) => (GrantScope::Global, "*.*".to_string()),
        (None, Some(database), None) => (GrantScope::Database, format!("{database}.*")),
        (None, Some(database), Some(table)) => (GrantScope::Table, format!("{database}.{table}")),
        (Some(kind), Some(database), Some(name)) => (GrantScope::Routine, format!("{kind} {database}.{name}")),
        _ => return None,
    };

    let mut own = Vec::new();
    let mut columns: Vec<(String, Vec<String>)> = Vec::new();
    for (privilege, privilege_columns) in items {
        if privilege_columns.is_empty() {
            own.push(privilege);
            continue;
        }
        if scope != GrantScope::Table {
            return None;
        }
        for column in privilege_columns {
            match columns.iter_mut().find(|(name, _)| *name == column) {
                Some((_, privileges)) => privileges.push(privilege.clone()),
                None => columns.push((column, vec![privilege.clone()])),
            }
        }
    }

    let mut entries = Vec::new();
    if !own.is_empty() {
        entries.push(entry(scope, target.clone(), own, grant_option, None));
    }
    for (column, privileges) in columns {
        entries.push(entry(GrantScope::Column, format!("{target}.{column}"), privileges, grant_option, None));
    }
    Some(entries)
}

/// 账号后面只允许什么都没有，或者 WITH <kind> OPTION。别的子句（AS … WITH ROLE 之类）看不懂，返回 None
fn tail_option(tail: &[Token], kind: &str) -> Option<bool> {
    match tail {
        [] => Some(false),
        [Token::Word(with), Token::Word(what), Token::Word(option)] if with == "WITH" && what == kind && option == "OPTION" => {
            Some(true)
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn account(user: &str, host: &str) -> Account {
        Account { user: user.to_string(), host: host.to_string() }
    }

    fn context() -> Context {
        let strings = |names: &[&str]| names.iter().map(|name| name.to_string()).collect::<Vec<_>>();
        Context {
            current: account("admin", "%"),
            current_roles: vec![account("app_role", "%")],
            global_privileges: strings(&["SELECT", "INSERT", "RELOAD", "CREATE USER", "BACKUP_ADMIN"]),
            database_privileges: strings(&["SELECT", "INSERT"]),
            table_privileges: strings(&["SELECT", "INSERT"]),
            plugins: strings(&["caching_sha2_password", "sha256_password"]),
            partial_revokes: false,
            connections: 0,
        }
    }

    fn grant(level: GrantLevel, privileges: &[&str]) -> UserChange {
        UserChange::Grant {
            account: account("bob", "localhost"),
            level,
            privileges: privileges.iter().map(|p| p.to_string()).collect(),
            with_grant_option: false,
        }
    }

    fn revoke(target: Account, privileges: &[&str]) -> UserChange {
        UserChange::Revoke {
            account: target,
            level: GrantLevel::Global,
            privileges: privileges.iter().map(|p| p.to_string()).collect(),
        }
    }

    #[test]
    fn parses_global_database_table_and_column_layers() {
        let global = parse_grant("GRANT SELECT, RELOAD ON *.* TO `bob`@`localhost` WITH GRANT OPTION");
        assert_eq!(global.len(), 1);
        assert_eq!(global[0].scope, GrantScope::Global);
        assert_eq!(global[0].target, "*.*");
        assert_eq!(global[0].privileges, vec!["SELECT", "RELOAD"]);
        assert!(global[0].grant_option);

        let dynamic = parse_grant("GRANT BACKUP_ADMIN,CLONE_ADMIN ON *.* TO `bob`@`localhost`");
        assert_eq!(dynamic[0].privileges, vec!["BACKUP_ADMIN", "CLONE_ADMIN"]);

        let database = parse_grant("GRANT CREATE TEMPORARY TABLES, LOCK TABLES ON `cdata\\_dev`.* TO `bob`@`localhost`");
        assert_eq!(database[0].scope, GrantScope::Database);
        assert_eq!(database[0].target, "cdata\\_dev.*", "库名保持 MySQL 存的样子，反斜杠说明 _ 不是通配符");
        assert_eq!(database[0].privileges, vec!["CREATE TEMPORARY TABLES", "LOCK TABLES"]);

        let mixed = parse_grant("GRANT SELECT (`a`, `b``c`), INSERT, UPDATE (`a`) ON `shop`.`orders` TO `bob`@`%`");
        assert_eq!(mixed.len(), 3, "{mixed:?}");
        assert_eq!((mixed[0].scope, mixed[0].target.as_str()), (GrantScope::Table, "shop.orders"));
        assert_eq!(mixed[0].privileges, vec!["INSERT"]);
        assert_eq!((mixed[1].scope, mixed[1].target.as_str()), (GrantScope::Column, "shop.orders.a"));
        assert_eq!(mixed[1].privileges, vec!["SELECT", "UPDATE"]);
        assert_eq!(mixed[2].target, "shop.orders.b`c", "反引号双写要还原");
        assert_eq!(mixed[2].privileges, vec!["SELECT"]);
    }

    #[test]
    fn parses_roles_proxy_routines_and_partial_revokes() {
        let roles = parse_grant("GRANT `r1`@`%`,`r2`@`localhost` TO `bob`@`localhost` WITH ADMIN OPTION");
        assert_eq!(roles.len(), 2);
        assert_eq!(roles[0].scope, GrantScope::Role);
        assert_eq!(roles[1].role, Some(account("r2", "localhost")));
        assert!(roles[1].grant_option);

        let proxy = parse_grant("GRANT PROXY ON ``@`` TO `root`@`localhost` WITH GRANT OPTION");
        assert_eq!(proxy[0].scope, GrantScope::Proxy);
        assert!(proxy[0].grant_option);

        let routine = parse_grant("GRANT EXECUTE, ALTER ROUTINE ON PROCEDURE `shop`.`refund` TO `bob`@`%`");
        assert_eq!((routine[0].scope, routine[0].target.as_str()), (GrantScope::Routine, "PROCEDURE shop.refund"));

        let revoked = parse_grant("REVOKE INSERT ON `mysql`.* FROM `bob`@`%`");
        assert_eq!(revoked[0].scope, GrantScope::Database);
        assert!(revoked[0].partial_revoke);
    }

    #[test]
    fn unknown_shapes_are_kept_verbatim() {
        for line in [
            "GRANT SELECT ON *.* TO `bob`@`%` AS `bob`@`%` WITH ROLE DEFAULT",
            "GRANT SELECT ON `unclosed.* TO `bob`@`%`",
            "SET DEFAULT ROLE ALL TO `bob`@`%`",
        ] {
            let entries = parse_grant(line);
            assert_eq!(entries.len(), 1);
            assert_eq!(entries[0].scope, GrantScope::Unparsed);
            assert_eq!(entries[0].statement, line);
        }
    }

    #[test]
    fn preview_masks_the_password_and_accounts_are_backtick_quoted() {
        let change = UserChange::Create { account: account("o'k`x", "10.0.%"), plugin: None };
        let plan = plan(&change, &context(), Some("s3cret'\\")).unwrap();
        assert_eq!(plan.statement, "CREATE USER `o'k``x`@`10.0.%` IDENTIFIED BY '***'");
        assert!(!plan.statement.contains("s3cret"));

        let with_plugin = UserChange::Create { account: account("bob", "localhost"), plugin: Some("sha256_password".into()) };
        let plan = super::plan(&with_plugin, &context(), Some("pw")).unwrap();
        assert_eq!(plan.statement, "CREATE USER `bob`@`localhost` IDENTIFIED WITH sha256_password BY '***'");

        let unknown = UserChange::Create {
            account: account("bob", "localhost"),
            plugin: Some("x BY 'a'; DROP USER root".into()),
        };
        assert!(super::plan(&unknown, &context(), Some("pw")).is_err(), "插件名只认服务器启用的");
    }

    #[test]
    fn password_rules() {
        let change = UserChange::SetPassword { account: account("bob", "localhost") };
        assert!(plan(&change, &context(), None).is_err());
        assert!(plan(&change, &context(), Some("")).is_err());
        assert!(plan(&change, &context(), Some("a\0b")).is_err());
        let lock = UserChange::SetLocked { account: account("bob", "localhost"), locked: true };
        assert!(plan(&lock, &context(), Some("pw")).is_err(), "不需要密码的操作不收密码");
        assert!(plan(&UserChange::Create { account: account("", "localhost"), plugin: None }, &context(), Some("pw")).is_err());
        assert!(plan(&UserChange::Create { account: account("bob", ""), plugin: None }, &context(), Some("pw")).is_err());
    }

    #[test]
    fn current_account_cannot_be_dropped_locked_or_revoked() {
        let me = account("admin", "%");
        assert!(plan(&UserChange::Drop { account: me.clone() }, &context(), None).unwrap_err().contains("当前登录"));
        assert!(plan(&UserChange::SetLocked { account: me.clone(), locked: true }, &context(), None).is_err());
        assert!(plan(&revoke(me.clone(), &["SELECT"]), &context(), None).is_err());
        let role = UserChange::RevokeRole { account: me.clone(), role: account("app_role", "%") };
        assert!(plan(&role, &context(), None).is_err());
        // 主机名不区分大小写
        let mut local = context();
        local.current = account("admin", "localhost");
        assert!(plan(&UserChange::Drop { account: account("admin", "LOCALHOST") }, &local, None).is_err());

        let unlock = plan(&UserChange::SetLocked { account: me.clone(), locked: false }, &context(), None).unwrap();
        assert_eq!(unlock.statement, "ALTER USER `admin`@`%` ACCOUNT UNLOCK");
        let password = plan(&UserChange::SetPassword { account: me }, &context(), Some("new")).unwrap();
        assert!(password.dangers.iter().any(|d| d.contains("连接设置")), "{:?}", password.dangers);

        // 同名不同主机不是自己
        assert!(plan(&UserChange::Drop { account: account("admin", "localhost") }, &context(), None).is_ok());
    }

    #[test]
    fn dangers_for_drop_revoke_all_grant_option_and_own_role() {
        let mut ctx = context();
        ctx.connections = 2;
        let drop = plan(&UserChange::Drop { account: account("bob", "localhost") }, &ctx, None).unwrap();
        assert_eq!(drop.statement, "DROP USER `bob`@`localhost`");
        assert!(drop.dangers.iter().any(|d| d.contains("不会断开") && d.contains("2 个")), "{:?}", drop.dangers);

        let all = plan(&revoke(account("bob", "localhost"), &["all privileges", "grant option"]), &context(), None).unwrap();
        assert_eq!(all.statement, "REVOKE ALL PRIVILEGES, GRANT OPTION ON *.* FROM `bob`@`localhost`");
        assert!(all.dangers.iter().any(|d| d.contains("ALL PRIVILEGES")));
        assert!(all.dangers.iter().any(|d| d.contains("GRANT OPTION")));

        let own_role = plan(&revoke(account("app_role", "%"), &["SELECT"]), &context(), None).unwrap();
        assert!(own_role.dangers.iter().any(|d| d.contains("角色")), "{:?}", own_role.dangers);
        let drop_role = plan(&UserChange::Drop { account: account("app_role", "%") }, &context(), None).unwrap();
        assert!(drop_role.dangers.iter().any(|d| d.contains("的角色")));
    }

    #[test]
    fn privileges_are_whitelisted_per_level() {
        let ok = plan(&grant(GrantLevel::Global, &["select", "BACKUP_ADMIN", "select"]), &context(), None).unwrap();
        assert_eq!(ok.statement, "GRANT SELECT, BACKUP_ADMIN ON *.* TO `bob`@`localhost`");

        let database = GrantLevel::Database { database: "shop".into() };
        assert!(plan(&grant(database.clone(), &["RELOAD"]), &context(), None).is_err(), "RELOAD 只有全局");
        assert!(plan(&grant(GrantLevel::Global, &["SELECT ON *.* TO x; DROP USER root; --"]), &context(), None).is_err());
        assert!(plan(&grant(GrantLevel::Global, &[]), &context(), None).is_err());
        assert!(plan(&grant(GrantLevel::Global, &["ALL PRIVILEGES", "SELECT"]), &context(), None).is_err());
        assert!(plan(&grant(GrantLevel::Global, &["GRANT OPTION"]), &context(), None).unwrap_err().contains("WITH GRANT OPTION"));

        let with_option = UserChange::Grant {
            account: account("bob", "localhost"),
            level: GrantLevel::Table { database: "shop".into(), table: "or`ders".into() },
            privileges: vec!["ALL PRIVILEGES".into()],
            with_grant_option: true,
        };
        let plan = plan(&with_option, &context(), None).unwrap();
        assert_eq!(plan.statement, "GRANT ALL PRIVILEGES ON `shop`.`or``ders` TO `bob`@`localhost` WITH GRANT OPTION");
    }

    #[test]
    fn database_level_wildcards_are_escaped_unless_partial_revokes() {
        let level = GrantLevel::Database { database: "cdata_dev%".into() };
        let escaped = plan(&grant(level.clone(), &["SELECT"]), &context(), None).unwrap();
        assert_eq!(escaped.statement, "GRANT SELECT ON `cdata\\_dev\\%`.* TO `bob`@`localhost`");
        assert!(escaped.notes.iter().any(|n| n.contains("通配符")));

        let mut ctx = context();
        ctx.partial_revokes = true;
        let literal = plan(&grant(level, &["SELECT"]), &ctx, None).unwrap();
        assert_eq!(literal.statement, "GRANT SELECT ON `cdata_dev%`.* TO `bob`@`localhost`");

        let backslash = GrantLevel::Database { database: "a\\b".into() };
        assert!(plan(&grant(backslash, &["SELECT"]), &context(), None).is_err());
        // 表级授权里的库名不是通配模式
        let table = GrantLevel::Table { database: "cdata_dev".into(), table: "t_1".into() };
        assert_eq!(
            plan(&grant(table, &["SELECT"]), &context(), None).unwrap().statement,
            "GRANT SELECT ON `cdata_dev`.`t_1` TO `bob`@`localhost`"
        );
    }

    #[test]
    fn real_statement_escapes_the_password_by_sql_mode() {
        let change = UserChange::SetPassword { account: account("bob", "localhost") };
        let password = "a'b\\c";
        let normal = statement(&change, &context(), &crate::alter::sql_string(password, false)).unwrap();
        assert_eq!(normal, "ALTER USER `bob`@`localhost` IDENTIFIED BY 'a''b\\\\c'");
        let no_backslash = statement(&change, &context(), &crate::alter::sql_string(password, true)).unwrap();
        assert_eq!(no_backslash, "ALTER USER `bob`@`localhost` IDENTIFIED BY 'a''b\\c'");
    }

    #[test]
    fn errors_never_carry_the_password() {
        let server = |code, message: &str| {
            mysql_async::Error::Server(mysql_async::ServerError { code, message: message.to_string(), state: "HY000".into() })
        };
        let parse = scrub(server(1064, "near 'Sup3r' at line 1"), Some("xxSup3r"));
        assert!(!parse.to_string().contains("Sup3r"), "{parse}");

        let other = scrub(server(1819, "policy rejected 'it''s\\\\x' and it's\\x"), Some("it's\\x"));
        let text = other.to_string();
        assert!(!text.contains("it's") && !text.contains("it''s"), "{text}");
        assert!(text.contains("***"));
    }

    #[test]
    fn password_expiry() {
        assert!(password_expired("Y", None, 0, None).unwrap().contains("设为过期"));
        assert_eq!(password_expired("N", None, 0, Some(10_000_000)), None, "全局 0 永不过期");
        assert!(password_expired("N", None, 90, Some(91 * 86_400)).unwrap().contains("90 天"));
        assert_eq!(password_expired("N", Some(0), 90, Some(91 * 86_400)), None, "账号 0 覆盖全局");
        assert_eq!(password_expired("N", Some(30), 0, Some(29 * 86_400)), None);
        assert!(password_expired("N", Some(30), 0, Some(31 * 86_400)).is_some());
    }
}
