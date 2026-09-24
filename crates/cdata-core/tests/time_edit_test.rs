//! TIME 编辑器依赖的列元数据：decimals 是不是列的小数秒位数。只读，不写数据。
//!
//! 连接信息从 CDATA_TEST_* 环境变量读，没配就跳过。

use cdata_core::db::{ColumnKind, ConnectionConfig};
use cdata_core::options::ConnectionOptions;
use cdata_core::value::check_time_text;
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

#[tokio::test]
async fn time_columns_report_their_fractional_digits() {
    let Some(config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };
    let id = cdata_core::session::open_session(&config).await.unwrap();

    let summary = cdata_core::session::execute(
        id,
        "SELECT t_neg, CAST('-100:00:00.5' AS TIME(2)) AS t2, CAST('1:00:00' AS TIME(6)) AS t6 FROM type_zoo LIMIT 1",
        10,
    )
    .await
    .expect("查询失败");
    let mut decimals = Vec::new();
    for column in &summary.columns {
        assert_eq!(column.kind, ColumnKind::Time, "{}", column.name);
        decimals.push(column.decimals);
    }
    assert_eq!(decimals, [0, 2, 6]);

    // 读回来的原文拿去校验必须能过：编辑器打开什么都不改就保存，不能被自己拒绝
    let rows = cdata_core::session::fetch_window(id, 0, 1).unwrap();
    for (index, cell) in rows[0].iter().enumerate() {
        let CellValue::Text(text) = cell else {
            panic!("TIME 应该是文本，实际 {cell:?}");
        };
        assert_eq!(check_time_text(text, decimals[index]), Ok(()), "{text}");
    }
    // 走二进制协议，小数秒总是补足 6 位，和列精度无关；尾部的 0 不算超出精度
    assert_eq!(rows[0][1], CellValue::Text("-100:00:00.500000".into()));

    cdata_core::session::close_session(id).await.ok();
}
