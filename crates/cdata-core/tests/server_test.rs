//! 服务器状态页，连真库。
//!
//! 不改服务器配置：SET GLOBAL 只测预览和「预览不一致就拒绝」，真正执行的 SET 只在测试自己的连接上做 SESSION 级。
//! KILL 只对测试自己另开的、不在 CData 连接池里的连接做。
use std::time::{Duration, Instant};

use cdata_core::db::ConnectionConfig;
use cdata_core::options::ConnectionOptions;
use cdata_core::server::{build_set_variable, KillMode, ProcessInfo, VariableScope};
use cdata_core::session::{
    apply_set_global, close_session, kill_process, open_session, preview_set_global, server_processes,
    server_status, server_variables, slow_log_config, slow_log_entries, Error,
};
use mysql_async::prelude::Queryable;

fn config_from_env() -> Option<ConnectionConfig> {
    let host = std::env::var("CDATA_TEST_HOST").ok()?;
    let port = std::env::var("CDATA_TEST_PORT").ok()?.parse().ok()?;
    let user = std::env::var("CDATA_TEST_USER").ok()?;
    let password = std::env::var("CDATA_TEST_PASSWORD").ok()?;
    let database = std::env::var("CDATA_TEST_DB").ok()?;
    Some(ConnectionConfig {
        host,
        port,
        user,
        password,
        database: Some(database),
        options: ConnectionOptions::default(),
        ssh_secrets: Vec::new(),
        saved_id: None,
    })
}

/// 不经过 CData 连接池的连接：模拟「别人的连接」，只有它能被 KILL
async fn outside_conn(config: &ConnectionConfig) -> mysql_async::Conn {
    let opts = mysql_async::OptsBuilder::default()
        .ip_or_hostname(config.host.clone())
        .tcp_port(config.port)
        .user(Some(config.user.clone()))
        .pass(Some(config.password.clone()))
        .prefer_socket(false);
    mysql_async::Conn::new(opts).await.unwrap()
}

fn marker(name: &str) -> String {
    format!("cdata-server-test-{name}-{}", rand::random::<u32>())
}

/// 在进程列表里按语句里的标记找到那条线程
async fn find_process(session: u64, marker: &str) -> ProcessInfo {
    for _ in 0..50 {
        let list = server_processes(session).await.unwrap();
        for process in list.processes {
            if process.info.text.contains(marker) && !process.info.text.contains("PROCESSLIST") {
                return process;
            }
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    panic!("进程列表里找不到 {marker}");
}

/// 读进程列表的那条连接自己也在列表里，要标成 CData 自己的连接，并且 KILL 会被拦住
#[tokio::test]
async fn own_connection_is_marked_and_cannot_be_killed() {
    let Some(config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };
    let session = open_session(&config).await.unwrap();

    let list = server_processes(session).await.unwrap();
    let own = list
        .processes
        .iter()
        .find(|process| process.info.text == "SHOW FULL PROCESSLIST" && process.is_own)
        .expect("读列表的那条连接应该标成自己的")
        .clone();
    assert!(!own.user.placeholder);

    for mode in [KillMode::Query, KillMode::Connection] {
        let err = kill_process(session, &own, mode).await.unwrap_err();
        assert!(matches!(err, Error::BadInput(_)), "{err}");
        assert!(err.to_string().contains("CData 自己"), "{err}");
    }
    // 连接还活着
    server_processes(session).await.unwrap();

    // 另一个标签连同一台服务器：它的连接池也算自己的
    let other_tab = open_session(&config).await.unwrap();
    let other_list = server_processes(other_tab).await.unwrap();
    let other_reader = other_list
        .processes
        .iter()
        .find(|process| process.info.text == "SHOW FULL PROCESSLIST")
        .unwrap()
        .id;
    let seen_from_first = server_processes(session).await.unwrap();
    let same = seen_from_first
        .processes
        .iter()
        .find(|process| process.id == other_reader)
        .expect("另一个标签的连接闲置在它的池里，列表里应该有");
    assert!(same.is_own, "线程 {other_reader} 是另一个标签的连接");

    close_session(other_tab).await.unwrap();
    close_session(session).await.unwrap();
}

/// KILL QUERY 只停语句：SLEEP 提前返回，连接还能接着用
#[tokio::test]
async fn kill_query_stops_statement_and_keeps_connection() {
    let Some(config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };
    let session = open_session(&config).await.unwrap();
    let mut victim = outside_conn(&config).await;
    let tag = marker("query");

    let sql = format!("SELECT SLEEP(30) /* {tag} */");
    let started = Instant::now();
    let running = tokio::spawn(async move {
        let result: Option<i64> = victim.query_first(sql).await.unwrap();
        (victim, result)
    });

    let target = find_process(session, &tag).await;
    assert!(!target.is_own);
    assert!(target.info.text.contains("SLEEP(30)"), "要显示完整语句：{}", target.info.text);
    kill_process(session, &target, KillMode::Query).await.unwrap();

    let (mut victim, result) = tokio::time::timeout(Duration::from_secs(10), running).await.unwrap().unwrap();
    assert_eq!(result, Some(1), "被 KILL QUERY 打断的 SLEEP 返回 1");
    assert!(started.elapsed() < Duration::from_secs(20));
    let alive: Option<i64> = victim.query_first("SELECT 7").await.unwrap();
    assert_eq!(alive, Some(7), "KILL QUERY 不断开连接");

    let _ = victim.disconnect().await;
    close_session(session).await.unwrap();
}

/// KILL CONNECTION 断开整条连接
#[tokio::test]
async fn kill_connection_drops_it() {
    let Some(config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };
    let session = open_session(&config).await.unwrap();
    let mut victim = outside_conn(&config).await;
    let tag = marker("connection");

    let sql = format!("SELECT SLEEP(30) /* {tag} */");
    let running = tokio::spawn(async move {
        let result: Result<Option<i64>, mysql_async::Error> = victim.query_first(sql).await;
        (victim, result)
    });

    let target = find_process(session, &tag).await;
    kill_process(session, &target, KillMode::Connection).await.unwrap();

    let (mut victim, result) = tokio::time::timeout(Duration::from_secs(10), running).await.unwrap().unwrap();
    assert!(result.is_err(), "连接被断开，语句应该报错：{result:?}");
    let after: Result<Option<i64>, _> = victim.query_first("SELECT 1").await;
    assert!(after.is_err(), "连接已经断开");

    // 线程收尾要一小会儿，这期间 Command 是 Killed
    let mut gone = false;
    for _ in 0..30 {
        let processes = server_processes(session).await.unwrap().processes;
        if processes.iter().all(|process| process.id != target.id) {
            gone = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(gone, "线程应该没了");
    close_session(session).await.unwrap();
}

/// 确认之后线程换了语句，KILL QUERY 不执行；线程已经不在也不执行
#[tokio::test]
async fn kill_refuses_stale_target() {
    let Some(config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };
    let session = open_session(&config).await.unwrap();
    let mut victim = outside_conn(&config).await;
    let tag = marker("stale");

    let sql = format!("SELECT SLEEP(3) /* {tag} */");
    let running = tokio::spawn(async move {
        let result: Option<i64> = victim.query_first(sql).await.unwrap();
        (victim, result)
    });

    let target = find_process(session, &tag).await;
    let mut changed = target.clone();
    changed.info.text = "SELECT 1".to_string();
    let err = kill_process(session, &changed, KillMode::Query).await.unwrap_err();
    assert!(err.to_string().contains("和确认时不一样"), "{err}");

    let (victim, result) = running.await.unwrap();
    assert_eq!(result, Some(0), "SLEEP 没被打断，正常睡完返回 0");
    drop(victim);

    // 连接断开后线程不在了
    tokio::time::sleep(Duration::from_millis(300)).await;
    let err = kill_process(session, &target, KillMode::Connection).await.unwrap_err();
    assert!(err.to_string().contains("已经"), "{err}");

    close_session(session).await.unwrap();
}

#[tokio::test]
async fn variables_and_status() {
    let Some(config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };
    let session = open_session(&config).await.unwrap();

    for scope in [VariableScope::Global, VariableScope::Session] {
        let list = server_variables(session, scope).await.unwrap();
        assert!(!list.truncated);
        let max = list.variables.iter().find(|v| v.name == "max_connections").expect("max_connections");
        assert!(!max.value.placeholder);
    }
    // 连接池的 setup 在每条连接上 SET NAMES utf8mb4，会话值要反映出来
    let session_vars = server_variables(session, VariableScope::Session).await.unwrap();
    let client = session_vars.variables.iter().find(|v| v.name == "character_set_client").unwrap();
    assert_eq!(client.value.text, "utf8mb4");

    let first = server_status(session, None).await.unwrap();
    let questions = first.counters.iter().find(|c| c.name == "Questions").unwrap();
    assert!(questions.delta.is_none(), "第一次没有差值");

    tokio::time::sleep(Duration::from_millis(200)).await;
    let second = server_status(session, Some(&first)).await.unwrap();
    let questions = second.counters.iter().find(|c| c.name == "Questions").unwrap();
    assert!(questions.delta.as_deref().is_some_and(|d| d.starts_with('+')), "{questions:?}");
    assert!(questions.rate.as_deref().is_some_and(|r| r.ends_with("/s")), "{questions:?}");
    let running = second.counters.iter().find(|c| c.name == "Threads_running").unwrap();
    assert!(running.delta.is_some() && running.rate.is_none(), "{running:?}");

    close_session(session).await.unwrap();
}

/// 只读配置；log_output 不含 TABLE 时读表要拒绝并给出文件路径
#[tokio::test]
async fn slow_log_reports_where_it_goes() {
    let Some(config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };
    let session = open_session(&config).await.unwrap();

    let slow = slow_log_config(session).await.unwrap();
    match &slow.table_unavailable {
        Some(reason) => {
            let err = slow_log_entries(session, 20).await.unwrap_err();
            assert_eq!(&err.to_string(), reason);
            if slow.log_output.text.contains("FILE") {
                assert!(reason.contains(&slow.slow_query_log_file.text), "{reason}");
            }
        }
        None => {
            let entries = slow_log_entries(session, 20).await.unwrap();
            assert!(entries.len() <= 20);
        }
    }

    close_session(session).await.unwrap();
}

/// 生成的 SET 语句服务器认不认：只在测试自己的连接上 SET SESSION，连接用完就断
#[tokio::test]
async fn generated_set_statements_work_at_session_scope() {
    let Some(config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };
    let mut conn = outside_conn(&config).await;

    let cases = [
        ("long_query_time", "3.5", "3.500000"),
        ("sort_buffer_size", "524288", "524288"),
        ("sql_safe_updates", "ON", "1"),
        ("time_zone", "+08:00", "+08:00"),
    ];
    for (name, value, expected) in cases {
        let statement = build_set_variable(VariableScope::Session, name, value, false).unwrap();
        conn.query_drop(&statement).await.unwrap_or_else(|err| panic!("{statement}: {err}"));
        let now: Option<String> = conn.query_first(format!("SELECT CAST(@@SESSION.{name} AS CHAR)")).await.unwrap();
        assert_eq!(now.as_deref(), Some(expected), "{statement}");
    }

    let _ = conn.disconnect().await;
}

/// SET GLOBAL 只预览不执行；预览过的语句对不上时拒绝，而且一定是在执行之前拒绝
#[tokio::test]
async fn set_global_previews_and_refuses_mismatch() {
    let Some(config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };
    let session = open_session(&config).await.unwrap();

    let before = server_variables(session, VariableScope::Global).await.unwrap();
    let current = before.variables.iter().find(|v| v.name == "long_query_time").unwrap().value.clone();

    let plan = preview_set_global(session, "long_query_time", "2").await.unwrap();
    assert_eq!(plan.statement, "SET GLOBAL long_query_time = 2");
    assert_eq!(plan.current_value, current);
    assert!(plan.warnings.iter().any(|w| w.contains("重启")), "{:?}", plan.warnings);

    // 值就是现在的值：万一比对失效真的执行了，服务器配置也不变
    let err = apply_set_global(session, "long_query_time", &current.text, "SET GLOBAL long_query_time = 99")
        .await
        .unwrap_err();
    assert!(err.to_string().contains("和预览时不一样"), "{err}");

    let err = preview_set_global(session, "cdata_no_such_variable", "1").await.unwrap_err();
    assert!(err.to_string().contains("没有全局变量"), "{err}");
    // 只有会话级的变量
    let err = preview_set_global(session, "insert_id", "1").await.unwrap_err();
    assert!(err.to_string().contains("没有全局变量"), "{err}");
    let err = preview_set_global(session, "max_connections; DROP TABLE x", "1").await.unwrap_err();
    assert!(matches!(err, Error::BadInput(_)), "{err}");

    let after = server_variables(session, VariableScope::Global).await.unwrap();
    let now = after.variables.iter().find(|v| v.name == "long_query_time").unwrap();
    assert_eq!(now.value, current, "全局值不能被测试改掉");

    close_session(session).await.unwrap();
}
