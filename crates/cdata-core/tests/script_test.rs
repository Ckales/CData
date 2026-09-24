//! 多语句脚本和执行计划，连真库。
//!
//! 只读，写入都落在临时表上（连接归还池子时随 reset 消失），不改动测试库里的任何表。
use cdata_core::db::ConnectionConfig;
use cdata_core::edit::Editability;
use cdata_core::options::ConnectionOptions;
use cdata_core::session::{
    close_session, execute, execute_script, explain, fetch_window, open_session, Error,
};
use cdata_core::CellValue;

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

/// 脚本里的语句要在同一条连接上跑：用户变量、临时表都是会话级的，换了连接就没了
#[tokio::test]
async fn script_statements_share_one_connection() {
    let Some(config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };
    let session = open_session(&config).await.unwrap();

    let sql = "SET @base = 41;\n\
               SELECT @base + 1 AS answer;\n\
               CREATE TEMPORARY TABLE script_probe (id INT);\n\
               INSERT INTO script_probe VALUES (1), (2);\n\
               SELECT COUNT(*) AS n FROM script_probe;";
    let summary = execute_script(session, sql, 100).await.unwrap();
    assert!(summary.failure.is_none(), "{:?}", summary.failure);
    assert_eq!(summary.outcomes.len(), 5);

    // SET、CREATE、INSERT 没有结果集
    assert!(summary.outcomes[0].session_id.is_none());
    assert_eq!(summary.outcomes[3].affected_rows, 2);
    assert!(summary.outcomes[3].session_id.is_none());

    let answer = summary.outcomes[1].session_id.expect("SELECT 要有结果集");
    assert_eq!(fetch_window(answer, 0, 1).unwrap()[0][0], CellValue::Int(42));
    let count = summary.outcomes[4].session_id.unwrap();
    assert_eq!(fetch_window(count, 0, 1).unwrap()[0][0], CellValue::Int(2));

    close_session(session).await.unwrap();
    // 父会话关掉，子结果跟着没了
    assert!(matches!(fetch_window(answer, 0, 1), Err(Error::NoSuchSession(_))));
}

/// 第一条失败就停：后面的语句多半依赖前面的结果，继续跑只会错上加错
#[tokio::test]
async fn script_stops_at_first_failure_and_says_which() {
    let Some(config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };
    let session = open_session(&config).await.unwrap();

    let sql = "SELECT 1 AS a; SELECT * FROM cdata_no_such_table; SELECT 3 AS c";
    let summary = execute_script(session, sql, 100).await.unwrap();
    assert_eq!(summary.outcomes.len(), 1, "失败之后的语句不该执行");
    let failure = summary.failure.expect("第二条应该失败");
    assert_eq!(failure.index, 1);
    assert_eq!(failure.sql, "SELECT * FROM cdata_no_such_table");
    assert!(failure.message.contains("cdata_no_such_table"), "{}", failure.message);

    close_session(session).await.unwrap();
}

/// 新一轮脚本清掉上一轮的子结果；关子会话不影响父会话的连接池
#[tokio::test]
async fn child_results_are_replaced_and_do_not_own_the_pool() {
    let Some(config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };
    let session = open_session(&config).await.unwrap();

    let first = execute_script(session, "SELECT 1 AS a; SELECT 2 AS b", 100).await.unwrap();
    let old_child = first.outcomes[0].session_id.unwrap();
    let second = execute_script(session, "SELECT 3 AS c; SELECT 4 AS d", 100).await.unwrap();
    assert!(matches!(fetch_window(old_child, 0, 1), Err(Error::NoSuchSession(_))));

    // 关掉一个子结果，父会话照样能查
    close_session(second.outcomes[0].session_id.unwrap()).await.unwrap();
    let summary = execute(session, "SELECT 5 AS e", 100).await.unwrap();
    assert_eq!(summary.total_rows, 1);
    assert_eq!(fetch_window(second.outcomes[1].session_id.unwrap(), 0, 1).unwrap()[0][0], CellValue::Int(4));

    close_session(session).await.unwrap();
}

/// 子结果和普通结果一样能判断可编辑性 —— 编辑、导出都按子会话 id 走原来的接口
#[tokio::test]
async fn script_results_keep_editability() {
    let Some(config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };
    let session = open_session(&config).await.unwrap();

    let summary = execute_script(session, "SELECT id, name FROM edit_target ORDER BY id; SELECT 1 AS x", 100)
        .await
        .unwrap();
    let table_result = summary.outcomes[0].summary.as_ref().unwrap();
    assert!(matches!(table_result.editability, Editability::Editable(_)), "{:?}", table_result.editability);
    let constant = summary.outcomes[1].summary.as_ref().unwrap();
    assert!(matches!(constant.editability, Editability::ReadOnly(_)));

    close_session(session).await.unwrap();
}

#[tokio::test]
async fn explain_returns_the_plan_without_running_the_statement() {
    let Some(config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };
    let session = open_session(&config).await.unwrap();

    let outcome = explain(session, "SELECT * FROM big_rows WHERE id = 1;", 100).await.unwrap();
    assert_eq!(outcome.sql, "EXPLAIN FORMAT=TRADITIONAL SELECT * FROM big_rows WHERE id = 1");
    let summary = outcome.summary.expect("执行计划是结果集");
    let names: Vec<&str> = summary.columns.iter().map(|c| c.name.as_str()).collect();
    assert!(names.contains(&"select_type") && names.contains(&"key"), "{names:?}");

    assert!(matches!(explain(session, "SELECT 1; SELECT 2", 100).await, Err(Error::BadInput(_))));
    close_session(session).await.unwrap();
}
