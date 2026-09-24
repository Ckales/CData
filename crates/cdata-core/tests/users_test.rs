//! 用户与权限管理连真库的测试。
//!
//! 连接信息从 CDATA_TEST_* 环境变量读，没配就跳过。
//! 账号安全：只建名字以 cdata_probe_ 开头、主机为 localhost 的探针账号（名字带随机后缀，和别的测试互不干扰），
//! 只授测试库上的权限，不授全局权限；结束时只 DROP 本测试自己建的探针，DROP 前核对前缀。
//! 对当前测试账号只做预览（验证拦截），从不执行任何改动。
//! 密码是运行时随机生成的，断言信息里不带密码。

use cdata_core::db::{open_pool, ConnectionConfig};
use cdata_core::options::ConnectionOptions;
use cdata_core::session;
use cdata_core::users::{self, Account, GrantLevel, GrantScope, UserChange};
use mysql_async::prelude::Queryable;
use mysql_async::Conn;

const PROBE_PREFIX: &str = "cdata_probe_";

fn config_from_env() -> Option<ConnectionConfig> {
    Some(ConnectionConfig {
        host: std::env::var("CDATA_TEST_HOST").ok()?,
        port: std::env::var("CDATA_TEST_PORT").ok()?.parse().ok()?,
        user: std::env::var("CDATA_TEST_USER").ok()?,
        password: std::env::var("CDATA_TEST_PASSWORD").ok()?,
        database: Some(std::env::var("CDATA_TEST_DB").ok()?),
        options: ConnectionOptions::default(),
        ssh_secrets: Vec::new(),
        saved_id: None,
    })
}

fn random_text(len: usize) -> String {
    use rand::RngExt;
    let alphabet: Vec<char> = "abcdefghijkmnpqrstuvwxyz23456789".chars().collect();
    let mut rng = rand::rng();
    let mut out = String::new();
    for _ in 0..len {
        out.push(alphabet[rng.random_range(0..alphabet.len())]);
    }
    out
}

/// 带上所有需要转义的字符：单引号、反斜杠、双引号、通配符、中文
fn random_password() -> String {
    format!("Aa1'\\\"%_中{}", random_text(20))
}

fn probe(suffix: &str) -> Account {
    Account { user: format!("{PROBE_PREFIX}{suffix}"), host: "localhost".to_string() }
}

/// 只删本测试建的探针账号
async fn drop_probe(conn: &mut Conn, account: &Account) {
    assert!(account.user.starts_with(PROBE_PREFIX) && account.host == "localhost", "只允许删探针账号");
    conn.query_drop(format!("DROP USER IF EXISTS '{}'@'localhost'", account.user)).await.unwrap();
}

async fn login(config: &ConnectionConfig, account: &Account, password: &str) -> Result<Conn, String> {
    let mut probe_config = config.clone();
    probe_config.user = account.user.clone();
    probe_config.password = password.to_string();
    // 刚建的账号还没有测试库的权限，不带默认库
    probe_config.database = None;
    let pool = open_pool(&probe_config).await.map_err(|err| err.to_string())?;
    pool.get_conn().await.map_err(|err| err.to_string())
}

async fn preview_and_apply(id: u64, change: &UserChange, password: Option<&str>) -> users::ChangePlan {
    let plan = session::preview_user_change(id, change, password).await.unwrap_or_else(|err| panic!("预览失败：{err}"));
    session::apply_user_change(id, change, password, &plan.statement)
        .await
        .unwrap_or_else(|err| panic!("执行失败：{err}\n{}", plan.statement));
    plan
}

async fn scopes(id: u64, account: &Account) -> Vec<(GrantScope, String)> {
    let grants = session::account_grants(id, account).await.unwrap();
    let mut out = Vec::new();
    for entry in grants.entries {
        out.push((entry.scope, entry.target));
    }
    out
}

#[tokio::test]
async fn user_lifecycle_against_real_server() {
    let Some(config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };
    let suffix = random_text(8);
    let user = probe(&suffix);
    let role = probe(&format!("{suffix}_r"));

    // 测试体放进单独的任务：中途 panic 也能走到下面的清理
    let body = tokio::spawn(lifecycle(config.clone(), user.clone(), role.clone()));
    let outcome = body.await;

    let pool = open_pool(&config).await.unwrap();
    let mut conn = pool.get_conn().await.unwrap();
    drop_probe(&mut conn, &user).await;
    drop_probe(&mut conn, &role).await;
    if let Err(err) = outcome {
        std::panic::resume_unwind(err.into_panic());
    }
}

async fn lifecycle(config: ConnectionConfig, user: Account, role: Account) {
    let database = config.database.clone().unwrap();
    let id = session::open_session(&config).await.unwrap();
    let admin = session::load_user_admin(id).await.unwrap();
    let me = admin.current.clone();
    assert!(admin.users_unavailable.is_none());
    assert!(admin.users.iter().any(|row| row.account == me && row.is_current), "账号清单里要标出当前账号");
    assert!(admin.database_privileges.contains(&"SELECT".to_string()));
    assert!(!admin.table_privileges.contains(&"RELOAD".to_string()));

    // 当前账号：删除、锁定、回收只预览就被拦下，什么都不执行
    for change in [
        UserChange::Drop { account: me.clone() },
        UserChange::SetLocked { account: me.clone(), locked: true },
        UserChange::Revoke { account: me.clone(), level: GrantLevel::Global, privileges: vec!["SELECT".into()] },
    ] {
        let err = session::preview_user_change(id, &change, None).await.unwrap_err().to_string();
        assert!(err.contains("当前登录"), "{err}");
    }

    // 新建：预览里没有密码，登得上说明字面量转义对了
    let password = random_password();
    let create = UserChange::Create { account: user.clone(), plugin: None };
    let plan = preview_and_apply(id, &create, Some(&password)).await;
    assert!(plan.statement.ends_with("IDENTIFIED BY '***'"), "{}", plan.statement);
    assert!(!plan.statement.contains(&password[4..]));
    let mut probe_conn = login(&config, &user, &password).await.expect("新建的账号用原密码登不上");

    let admin = session::load_user_admin(id).await.unwrap();
    let row = admin.users.iter().find(|row| row.account == user).expect("账号清单里没有新建的账号");
    assert!(!row.locked && row.password_expired.is_none() && !row.is_current);
    assert!(!row.plugin.is_empty());

    // 没有 mysql.user 权限时说明原因，不算失败
    let limited = users::load(&mut probe_conn).await.unwrap();
    assert!(limited.users.is_empty());
    let reason = limited.users_unavailable.expect("探针账号读不了 mysql.user，要带着原因");
    assert!(reason.contains("mysql.user"), "{reason}");
    assert_eq!(limited.current, user);

    // 库级授权：库名里的 _ 要转义，只授测试库本身
    let on_database = GrantLevel::Database { database: database.clone() };
    let grant = UserChange::Grant {
        account: user.clone(),
        level: on_database.clone(),
        privileges: vec!["SELECT".into(), "INSERT".into()],
        with_grant_option: false,
    };
    preview_and_apply(id, &grant, None).await;
    let expected = format!("{}.*", database.replace('_', "\\_"));
    assert!(scopes(id, &user).await.contains(&(GrantScope::Database, expected.clone())), "{:?}", scopes(id, &user).await);
    let count: Option<u64> = probe_conn
        .query_first(format!("SELECT COUNT(*) FROM `{database}`.edit_target"))
        .await
        .expect("授了库级 SELECT 还读不了表");
    assert!(count.is_some());

    // 表级 + 回收
    let on_table = GrantLevel::Table { database: database.clone(), table: "edit_target".into() };
    let grant_table = UserChange::Grant {
        account: user.clone(),
        level: on_table.clone(),
        privileges: vec!["UPDATE".into()],
        with_grant_option: true,
    };
    preview_and_apply(id, &grant_table, None).await;
    let grants = session::account_grants(id, &user).await.unwrap();
    let table_entry = grants.entries.iter().find(|entry| entry.scope == GrantScope::Table).expect("没有表级权限");
    assert_eq!(table_entry.target, format!("{database}.edit_target"));
    assert!(table_entry.grant_option);
    assert!(grants.statements.iter().any(|line| line.contains("WITH GRANT OPTION")));

    let revoke_table = UserChange::Revoke {
        account: user.clone(),
        level: on_table,
        privileges: vec!["UPDATE".into(), "GRANT OPTION".into()],
    };
    let plan = preview_and_apply(id, &revoke_table, None).await;
    assert!(plan.dangers.iter().any(|danger| danger.contains("GRANT OPTION")), "{:?}", plan.dangers);
    assert!(!scopes(id, &user).await.iter().any(|(scope, _)| *scope == GrantScope::Table));

    // 角色（只用探针账号当角色）。顺带走一遍显式指定认证插件
    preview_and_apply(id, &UserChange::Create { account: role.clone(), plugin: Some("caching_sha2_password".into()) }, Some(&random_password())).await;
    preview_and_apply(id, &UserChange::GrantRole { account: user.clone(), role: role.clone() }, None).await;
    let grants = session::account_grants(id, &user).await.unwrap();
    assert!(grants.entries.iter().any(|entry| entry.role.as_ref() == Some(&role)), "{:?}", grants.statements);
    preview_and_apply(id, &UserChange::RevokeRole { account: user.clone(), role: role.clone() }, None).await;
    assert!(!scopes(id, &user).await.iter().any(|(scope, _)| *scope == GrantScope::Role));

    // 预览之后语句变了就不执行
    let stale = session::apply_user_change(id, &grant, None, "GRANT SELECT ON *.* TO `x`@`y`").await;
    assert!(stale.is_err());

    // 改密码：先手动设成过期，改完标记清掉。在开了 NO_BACKSLASH_ESCAPES 的连接上执行，反斜杠照样对
    let pool = open_pool(&config).await.unwrap();
    let mut conn = pool.get_conn().await.unwrap();
    conn.query_drop(format!("ALTER USER '{}'@'localhost' PASSWORD EXPIRE", user.user)).await.unwrap();
    let admin = session::load_user_admin(id).await.unwrap();
    let row = admin.users.iter().find(|row| row.account == user).unwrap();
    assert!(row.password_expired.is_some(), "设了 PASSWORD EXPIRE 要显示过期");

    conn.query_drop("SET SESSION sql_mode = CONCAT(@@SESSION.sql_mode, ',NO_BACKSLASH_ESCAPES')").await.unwrap();
    let new_password = random_password();
    let set_password = UserChange::SetPassword { account: user.clone() };
    let plan = users::preview_change(&mut conn, &set_password, Some(&new_password)).await.unwrap();
    users::apply_change(&mut conn, &set_password, Some(&new_password), &plan.statement).await.unwrap();
    drop(conn);
    pool.disconnect().await.unwrap();
    assert!(login(&config, &user, &password).await.is_err(), "旧密码不该还能登");
    login(&config, &user, &new_password).await.expect("NO_BACKSLASH_ESCAPES 下改的密码登不上");
    let admin = session::load_user_admin(id).await.unwrap();
    assert!(admin.users.iter().find(|row| row.account == user).unwrap().password_expired.is_none());

    // 锁定：只拦新连接，已经连着的照常可用
    let mut live = login(&config, &user, &new_password).await.unwrap();
    let lock = UserChange::SetLocked { account: user.clone(), locked: true };
    preview_and_apply(id, &lock, None).await;
    let still: Option<u8> = live.query_first("SELECT 1").await.expect("锁定不该断开已有连接");
    assert_eq!(still, Some(1));
    assert!(login(&config, &user, &new_password).await.is_err(), "锁定后新连接应该被拒");
    assert!(session::load_user_admin(id).await.unwrap().users.iter().any(|row| row.account == user && row.locked));
    preview_and_apply(id, &UserChange::SetLocked { account: user.clone(), locked: false }, None).await;
    login(&config, &user, &new_password).await.expect("解锁后登不上");

    // 删除：DROP USER 不断开已有连接（实测），提示里要带上能看到的连接数
    let drop_user = UserChange::Drop { account: user.clone() };
    let plan = preview_and_apply(id, &drop_user, None).await;
    assert!(plan.dangers.iter().any(|danger| danger.contains("不会断开")), "{:?}", plan.dangers);
    assert!(plan.dangers.iter().any(|danger| danger.contains("个用户名为")), "探针连接还开着：{:?}", plan.dangers);
    let still: Option<u8> = live.query_first("SELECT 1").await.expect("DROP USER 之后已有连接应该还在");
    assert_eq!(still, Some(1));
    assert!(login(&config, &user, &new_password).await.is_err(), "删掉之后不该还能登");
    assert!(!session::load_user_admin(id).await.unwrap().users.iter().any(|row| row.account == user));

    drop(live);
    drop(probe_conn);
    session::close_session(id).await.unwrap();
}
