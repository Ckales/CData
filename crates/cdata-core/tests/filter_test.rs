//! 分组筛选和 IN / NOT IN 连真库的测试。只读 big_rows，不写数据。
//!
//! 连接信息从 CDATA_TEST_* 环境变量读，没配就跳过。每条都和手写 WHERE 的计数对比，
//! 生成的 SQL 和 MySQL 自己的语义不一致就会在这里露出来。

use cdata_core::db::ConnectionConfig;
use cdata_core::options::ConnectionOptions;
use cdata_core::sql::{FilterCondition, FilterGroup, FilterItem, FilterOp};
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

fn leaf(column: &str, op: FilterOp, value: &str) -> FilterItem {
    FilterItem::Condition(FilterCondition { column: column.to_string(), op, value: value.to_string() })
}

fn group(match_all: bool, items: Vec<FilterItem>) -> FilterGroup {
    FilterGroup { match_all, items }
}

/// 手写 SQL 的 COUNT(*)，拿来和筛选结果比
async fn count(session_id: u64, sql: &str) -> u64 {
    cdata_core::session::execute(session_id, sql, 10).await.expect("计数失败");
    let rows = cdata_core::session::fetch_window(session_id, 0, 1).expect("取窗口失败");
    match rows[0][0] {
        CellValue::Int(n) => n as u64,
        ref other => panic!("COUNT(*) 应该是整数，实际 {other:?}"),
    }
}

async fn filtered(session_id: u64, filter: &FilterGroup) -> u64 {
    let summary = cdata_core::session::execute_filtered_view(
        session_id,
        "SELECT * FROM big_rows",
        filter,
        Some(("id", true)),
        200_000,
    )
    .await
    .expect("筛选失败");
    assert!(!summary.truncated);
    summary.total_rows
}

#[tokio::test]
async fn in_and_not_in_match_hand_written_where() {
    let Some(config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };
    let id = cdata_core::session::open_session(&config).await.unwrap();

    // 值按字符串绑定，数值列由 MySQL 转换；不存在的 id 不影响
    let filter = group(true, vec![leaf("id", FilterOp::In, "1\n2\n3\n999999999\n")]);
    assert_eq!(filtered(id, &filter).await, 3);
    let rows = cdata_core::session::fetch_window(id, 0, 3).unwrap();
    assert_eq!(rows[0][0], CellValue::Int(1), "排序照样生效");

    let filter = group(true, vec![leaf("id", FilterOp::LtEq, "10"), leaf("id", FilterOp::NotIn, "2\n4")]);
    assert_eq!(filtered(id, &filter).await, 8);

    // NOT IN 不命中 NULL 行，和手写的一样，不偷偷补 OR IS NULL
    let filter = group(true, vec![leaf("note", FilterOp::NotIn, "不会有这个值")]);
    let expected = count(id, "SELECT COUNT(*) FROM big_rows WHERE note NOT IN ('不会有这个值')").await;
    let nulls = count(id, "SELECT COUNT(*) FROM big_rows WHERE note IS NULL").await;
    assert!(nulls > 0, "测试库里 note 要有 NULL，这条才有意义");
    assert_eq!(filtered(id, &filter).await, expected);

    cdata_core::session::close_session(id).await.ok();
}

#[tokio::test]
async fn nested_groups_match_hand_written_where() {
    let Some(config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };
    let id = cdata_core::session::open_session(&config).await.unwrap();

    // (id <= 100 AND status = 1) OR (id IN (200, 300) AND (note IS NULL OR note LIKE '%'))
    let filter = group(
        false,
        vec![
            FilterItem::Group(group(true, vec![leaf("id", FilterOp::LtEq, "100"), leaf("status", FilterOp::Eq, "1")])),
            FilterItem::Group(group(
                true,
                vec![
                    leaf("id", FilterOp::In, "200\n300"),
                    FilterItem::Group(group(
                        false,
                        vec![leaf("note", FilterOp::IsNull, ""), leaf("note", FilterOp::StartsWith, "")],
                    )),
                ],
            )),
        ],
    );
    let expected = count(
        id,
        "SELECT COUNT(*) FROM big_rows WHERE (id <= 100 AND status = 1) \
         OR (id IN (200, 300) AND (note IS NULL OR note LIKE '%'))",
    )
    .await;
    assert!(expected > 0);
    assert_eq!(filtered(id, &filter).await, expected);

    // 分组筛选后列元数据里的原始表还在，照样能编辑
    let summary = cdata_core::session::execute_filtered_view(
        id,
        "SELECT id, name FROM big_rows",
        &group(true, vec![leaf("id", FilterOp::In, "1")]),
        None,
        10,
    )
    .await
    .unwrap();
    assert!(matches!(summary.editability, cdata_core::edit::Editability::Editable(_)), "{:?}", summary.editability);

    cdata_core::session::close_session(id).await.ok();
}

#[tokio::test]
async fn bad_lists_are_refused_before_reaching_the_server() {
    let Some(config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };
    let id = cdata_core::session::open_session(&config).await.unwrap();

    for value in ["", "1\nNULL"] {
        let filter = group(true, vec![leaf("id", FilterOp::NotIn, value)]);
        let err = cdata_core::session::execute_filtered_view(id, "SELECT * FROM big_rows", &filter, None, 10)
            .await
            .unwrap_err();
        assert!(err.to_string().contains("id："), "{err}");
    }

    cdata_core::session::close_session(id).await.ok();
}
