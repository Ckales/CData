//! 连真库的集成测试。
//!
//! 连接信息从 CDATA_TEST_* 环境变量读，没配就整体跳过 —— 凭据不进源码。
//! 需要的测试库和表见 README 的「开发」一节。

use cdata_core::db::{open_pool, run_query, ConnectionConfig};
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
    })
}

/// 取第一行某列的值，列名对不上直接 panic —— 测试里不该有兜底
fn cell(result: &cdata_core::db::ResultSet, row: usize, column: &str) -> CellValue {
    let index = result
        .columns
        .iter()
        .position(|c| c.name == column)
        .unwrap_or_else(|| panic!("结果集里没有列 {column}"));
    result.rows[row][index].clone()
}

#[tokio::test]
async fn type_zoo_survives_a_real_round_trip() {
    let Some(config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };

    let pool = open_pool(&config);
    let result = run_query(
        &pool,
        "SELECT * FROM type_zoo ORDER BY id",
        100,
    )
    .await
    .expect("查询 type_zoo 失败");

    assert_eq!(result.rows.len(), 2);
    assert!(!result.truncated);

    // u64 上界：塞进 i64 会溢出
    assert_eq!(
        cell(&result, 0, "big_unsigned"),
        CellValue::UInt(18446744073709551615)
    );
    // i64 下界
    assert_eq!(
        cell(&result, 0, "big_signed"),
        CellValue::Int(-9223372036854775808)
    );
    // DECIMAL 必须是精确文本，不能变成 1234567.8899999999
    assert_eq!(
        cell(&result, 0, "amount"),
        CellValue::Text("1234567.8900".to_string())
    );
    // FLOAT 不能泄漏 f32 转 f64 的精度垃圾
    assert_eq!(cell(&result, 0, "ratio"), CellValue::Text("0.1".to_string()));
    // 零日期：chrono 表示不了，必须原样
    assert_eq!(
        cell(&result, 0, "d_zero"),
        CellValue::Text("0000-00-00".to_string())
    );
    // 微秒不能被截掉
    assert_eq!(
        cell(&result, 0, "dt_micro"),
        CellValue::Text("2026-09-23 14:30:05.123456".to_string())
    );
    // TIME 下界，天数要折算进小时
    assert_eq!(
        cell(&result, 0, "t_neg"),
        CellValue::Text("-838:59:59".to_string())
    );
    assert_eq!(
        cell(&result, 0, "txt_cn"),
        CellValue::Text("订单已完成".to_string())
    );
    // BLOB 走字节，不尝试解码
    assert_eq!(
        cell(&result, 0, "blob_col"),
        CellValue::Bytes(vec![0x00, 0xFF, 0x10])
    );
    // NULL 不能变成空串
    assert_eq!(cell(&result, 0, "nullable_txt"), CellValue::Null);

    pool.disconnect().await.ok();
}

#[tokio::test]
async fn truncation_is_explicit_not_silent() {
    let Some(config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };

    let pool = open_pool(&config);
    let result = run_query(&pool, "SELECT * FROM big_rows ORDER BY id", 500)
        .await
        .expect("查询 big_rows 失败");

    assert_eq!(result.rows.len(), 500);
    assert!(result.truncated, "超上限必须标记截断，不能静默丢行");

    pool.disconnect().await.ok();
}

#[tokio::test]
async fn reads_one_hundred_thousand_rows() {
    let Some(config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };

    let pool = open_pool(&config);
    let started = std::time::Instant::now();
    let result = run_query(&pool, "SELECT * FROM big_rows ORDER BY id", 200_000)
        .await
        .expect("查询 big_rows 失败");
    let elapsed = started.elapsed();

    assert_eq!(result.rows.len(), 100_000);
    assert!(!result.truncated);
    assert_eq!(result.columns.len(), 6);

    // 末行抽查，确认没有在读取过程中错位
    assert_eq!(cell(&result, 99_999, "name"), CellValue::Text("用户100000".to_string()));

    eprintln!("读取 10 万行耗时 {:?}", elapsed);

    pool.disconnect().await.ok();
}

#[tokio::test]
async fn session_keeps_rows_and_serves_windows() {
    let Some(config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };

    let id = cdata_core::session::open_session(&config);
    let summary = cdata_core::session::execute(id, "SELECT * FROM big_rows ORDER BY id", 200_000)
        .await
        .expect("查询失败");

    assert_eq!(summary.total_rows, 100_000);
    assert!(!summary.truncated);
    // 单表结果按「服务器/库.表」记布局
    let key = summary.layout_key.as_deref().expect("单表结果应该有布局键");
    assert_eq!(key, format!("{}:{}/{}.big_rows", config.host, config.port, config.database.as_deref().unwrap()));

    // 界面滚到中间，只取两百行
    let window = cdata_core::session::fetch_window(id, 50_000, 200).expect("取窗口失败");
    assert_eq!(window.len(), 200);
    // id 是 INT UNSIGNED，但驱动只对 BIGINT UNSIGNED 用 UInt —— 小的无符号值装得进 i64。
    // 所以「这列是不是无符号」要看列元数据，不能从 CellValue 的变体反推
    assert_eq!(window[0][0], CellValue::Int(50_001));

    // 越界不报错，返回实际拿得到的部分
    let tail = cdata_core::session::fetch_window(id, 99_950, 200).expect("取窗口失败");
    assert_eq!(tail.len(), 50);

    cdata_core::session::close_session(id).await.expect("关闭失败");

    // 关掉之后再用同一个 id 必须报错，不能静默返回空
    assert!(cdata_core::session::fetch_window(id, 0, 10).is_err());
}

/// 编辑测试会改数据，各自用独立的表，避免并行跑的时候互相干扰
#[tokio::test]
async fn editing_a_cell_writes_back_and_updates_cache() {
    let Some(config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };

    let id = cdata_core::session::open_session(&config);
    let summary = cdata_core::session::execute(
        id,
        "SELECT id, name, amount, note FROM edit_target ORDER BY id",
        100,
    )
    .await
    .expect("查询失败");

    // 单表 + 有主键 + 主键在结果集里 → 可编辑
    let target = match &summary.editability {
        cdata_core::edit::Editability::Editable(t) => t.clone(),
        cdata_core::edit::Editability::ReadOnly(reason) => panic!("应该可编辑，却是只读：{reason}"),
    };
    assert_eq!(target.table, "edit_target");
    assert_eq!(target.key_indexes, vec![0]);

    // 改第一行的 amount。DECIMAL 必须精确写回，不能被转成浮点
    cdata_core::session::apply_edit(id, 0, 2, CellValue::Text("999.99".into()))
        .await
        .expect("写回失败");

    // 本地缓存要同步，否则界面还显示旧值
    let window = cdata_core::session::fetch_window(id, 0, 1).expect("取窗口失败");
    assert_eq!(window[0][2], CellValue::Text("999.99".to_string()));

    // 回读数据库确认真的落盘了
    let verify = cdata_core::session::execute(
        id,
        "SELECT amount FROM edit_target WHERE id = 1",
        10,
    )
    .await
    .expect("回读失败");
    let rows = cdata_core::session::fetch_window(id, 0, 1).expect("取窗口失败");
    assert_eq!(verify.total_rows, 1);
    assert_eq!(rows[0][0], CellValue::Text("999.99".to_string()));

    // 改回去，让测试可重复跑
    let restore = cdata_core::session::execute(
        id,
        "SELECT id, name, amount, note FROM edit_target ORDER BY id",
        100,
    )
    .await
    .expect("查询失败");
    assert!(matches!(
        restore.editability,
        cdata_core::edit::Editability::Editable(_)
    ));
    cdata_core::session::apply_edit(id, 0, 2, CellValue::Text("100.00".into()))
        .await
        .expect("还原失败");

    cdata_core::session::close_session(id).await.ok();
}

#[tokio::test]
async fn writing_null_and_chinese_round_trips() {
    let Some(config) = config_from_env() else {
        return;
    };

    let id = cdata_core::session::open_session(&config);
    cdata_core::session::execute(
        id,
        "SELECT id, name, amount, note FROM edit_target ORDER BY id",
        100,
    )
    .await
    .expect("查询失败");

    // 第二行的 note 本来是 NULL，写中文进去
    cdata_core::session::apply_edit(id, 1, 3, CellValue::Text("订单已完成".into()))
        .await
        .expect("写中文失败");

    let reread = cdata_core::session::execute(
        id,
        "SELECT note FROM edit_target WHERE id = 2",
        10,
    )
    .await
    .expect("回读失败");
    assert_eq!(reread.total_rows, 1);
    let rows = cdata_core::session::fetch_window(id, 0, 1).expect("取窗口失败");
    assert_eq!(rows[0][0], CellValue::Text("订单已完成".to_string()));

    // 再写回 NULL —— 不能变成空字符串
    cdata_core::session::execute(
        id,
        "SELECT id, name, amount, note FROM edit_target ORDER BY id",
        100,
    )
    .await
    .expect("查询失败");
    cdata_core::session::apply_edit(id, 1, 3, CellValue::Null)
        .await
        .expect("写 NULL 失败");

    let final_read = cdata_core::session::execute(
        id,
        "SELECT note FROM edit_target WHERE id = 2",
        10,
    )
    .await
    .expect("回读失败");
    assert_eq!(final_read.total_rows, 1);
    let rows = cdata_core::session::fetch_window(id, 0, 1).expect("取窗口失败");
    assert_eq!(rows[0][0], CellValue::Null, "NULL 不能被写成空字符串");

    cdata_core::session::close_session(id).await.ok();
}

#[tokio::test]
async fn table_without_primary_key_refuses_editing() {
    let Some(config) = config_from_env() else {
        return;
    };

    let id = cdata_core::session::open_session(&config);
    let summary = cdata_core::session::execute(id, "SELECT a, b FROM no_pk", 100)
        .await
        .expect("查询失败");

    match &summary.editability {
        cdata_core::edit::Editability::ReadOnly(reason) => {
            assert!(reason.contains("没有主键"), "原因要说清楚：{reason}");
        }
        cdata_core::edit::Editability::Editable(_) => panic!("无主键表不该可编辑"),
    }

    // 硬来也得被挡住
    let err = cdata_core::session::apply_edit(id, 0, 1, CellValue::Text("x".into()))
        .await
        .unwrap_err();
    assert!(err.to_string().contains("没有主键"), "{err}");

    cdata_core::session::close_session(id).await.ok();
}

#[tokio::test]
async fn join_result_refuses_editing() {
    let Some(config) = config_from_env() else {
        return;
    };

    let id = cdata_core::session::open_session(&config);
    let summary = cdata_core::session::execute(
        id,
        "SELECT e.id, n.b FROM edit_target e JOIN no_pk n ON n.a = e.id",
        100,
    )
    .await
    .expect("查询失败");

    match &summary.editability {
        cdata_core::edit::Editability::ReadOnly(reason) => {
            assert!(reason.contains("多张表"), "原因要说清楚：{reason}");
        }
        cdata_core::edit::Editability::Editable(_) => panic!("JOIN 结果不该可编辑"),
    }
    assert_eq!(summary.layout_key, None, "JOIN 结果没有稳定的列归属，不记布局");

    cdata_core::session::close_session(id).await.ok();
}

#[tokio::test]
async fn missing_primary_key_column_refuses_editing() {
    let Some(config) = config_from_env() else {
        return;
    };

    let id = cdata_core::session::open_session(&config);
    // 没 SELECT 主键，定位不到行
    let summary = cdata_core::session::execute(id, "SELECT name, amount FROM edit_target", 100)
        .await
        .expect("查询失败");

    match &summary.editability {
        cdata_core::edit::Editability::ReadOnly(reason) => {
            assert!(reason.contains("主键列"), "原因要说清楚：{reason}");
        }
        cdata_core::edit::Editability::Editable(_) => panic!("缺主键列不该可编辑"),
    }

    cdata_core::session::close_session(id).await.ok();
}

#[tokio::test]
async fn composite_primary_key_is_editable() {
    let Some(config) = config_from_env() else {
        return;
    };

    let id = cdata_core::session::open_session(&config);
    let summary = cdata_core::session::execute(
        id,
        "SELECT shop_id, order_no, amount FROM edit_composite ORDER BY order_no",
        100,
    )
    .await
    .expect("查询失败");

    match &summary.editability {
        cdata_core::edit::Editability::Editable(t) => {
            assert_eq!(t.key_indexes, vec![0, 1], "复合主键两列都要参与定位");
        }
        cdata_core::edit::Editability::ReadOnly(reason) => panic!("应该可编辑：{reason}"),
    }

    cdata_core::session::close_session(id).await.ok();
}

#[tokio::test]
async fn execute_handles_statements_without_result_set() {
    let Some(config) = config_from_env() else {
        return;
    };

    let id = cdata_core::session::open_session(&config);

    // UPDATE 没有结果集，execute 必须正常返回而不是卡住
    let summary = cdata_core::session::execute(
        id,
        "UPDATE edit_target SET note='探针' WHERE id = 1",
        10,
    )
    .await
    .expect("UPDATE 应该能跑");
    assert_eq!(summary.total_rows, 0);
    assert!(summary.columns.is_empty());

    // 跑完之后连接要还能用，不能因为结果集没清干净而卡死下一条
    let next = cdata_core::session::execute(id, "SELECT note FROM edit_target WHERE id = 1", 10)
        .await
        .expect("后续查询应该能跑");
    assert_eq!(next.total_rows, 1);

    cdata_core::session::close_session(id).await.ok();
}

#[tokio::test]
async fn order_by_wrapper_actually_sorts_on_the_server() {
    let Some(config) = config_from_env() else {
        return;
    };

    let id = cdata_core::session::open_session(&config);

    // 原句带 LIMIT：包子查询后语义是「先取前 100 行，再对这 100 行排序」
    let sql = cdata_core::sql::with_order_by(
        "SELECT id, name FROM big_rows ORDER BY id LIMIT 100",
        "id",
        false,
    );
    let summary = cdata_core::session::execute(id, &sql, 200).await.expect("排序查询失败");
    assert_eq!(summary.total_rows, 100);

    let rows = cdata_core::session::fetch_window(id, 0, 1).expect("取窗口失败");
    assert_eq!(rows[0][0], CellValue::Int(100), "降序后第一行应该是 100");

    // 升序
    let asc = cdata_core::sql::with_order_by(
        "SELECT id, name FROM big_rows ORDER BY id LIMIT 100",
        "id",
        true,
    );
    cdata_core::session::execute(id, &asc, 200).await.expect("排序查询失败");
    let rows = cdata_core::session::fetch_window(id, 0, 1).expect("取窗口失败");
    assert_eq!(rows[0][0], CellValue::Int(1));

    cdata_core::session::close_session(id).await.ok();
}

/// 数一下某个条件下的行数，用独立会话查，不碰被测会话的缓存
async fn count_where(config: &ConnectionConfig, sql: &str) -> i64 {
    let id = cdata_core::session::open_session(config);
    cdata_core::session::execute(id, sql, 10).await.expect("计数失败");
    let rows = cdata_core::session::fetch_window(id, 0, 1).expect("取窗口失败");
    cdata_core::session::close_session(id).await.ok();
    match rows[0][0] {
        CellValue::Int(n) => n,
        ref other => panic!("COUNT(*) 应该是整数，实际 {other:?}"),
    }
}

#[tokio::test]
async fn insert_reads_back_real_values_and_delete_removes_it() {
    let Some(config) = config_from_env() else {
        return;
    };

    let id = cdata_core::session::open_session(&config);
    let summary = cdata_core::session::execute(
        id,
        "SELECT id, name, amount, note FROM edit_target ORDER BY id",
        100,
    )
    .await
    .expect("查询失败");
    let before = summary.total_rows;

    // id 交给自增，note 交给 DEFAULT
    let total = cdata_core::session::insert_row(
        id,
        vec![
            None,
            Some(CellValue::Text("新增行".into())),
            Some(CellValue::Text("12.3".into())),
            None,
        ],
    )
    .await
    .expect("插入失败");
    assert_eq!(total, before + 1);

    // 缓存里是从库里读回来的真实值：自增 id 回填、DECIMAL 按列定义补齐小数位、DEFAULT 是 NULL
    let row = cdata_core::session::fetch_window(id, before, 1).expect("取窗口失败").remove(0);
    let CellValue::Int(new_id) = row[0] else {
        panic!("自增主键没有回填：{:?}", row[0]);
    };
    assert_eq!(row[1], CellValue::Text("新增行".to_string()));
    assert_eq!(row[2], CellValue::Text("12.30".to_string()), "要显示库里存的值，不是用户填的");
    assert_eq!(row[3], CellValue::Null);

    let total = cdata_core::session::delete_rows(id, vec![before]).await.expect("删除失败");
    assert_eq!(total, before);
    assert_eq!(
        count_where(&config, &format!("SELECT COUNT(*) FROM edit_target WHERE id = {new_id}")).await,
        0
    );

    cdata_core::session::close_session(id).await.ok();
}

#[tokio::test]
async fn batch_delete_rolls_back_when_any_row_is_stale() {
    let Some(config) = config_from_env() else {
        return;
    };

    let id = cdata_core::session::open_session(&config);
    let summary = cdata_core::session::execute(
        id,
        "SELECT id, name FROM edit_target ORDER BY id",
        100,
    )
    .await
    .expect("查询失败");
    let first = summary.total_rows;

    cdata_core::session::insert_row(id, vec![None, Some(CellValue::Text("回滚-1".into()))])
        .await
        .expect("插入失败");
    cdata_core::session::insert_row(id, vec![None, Some(CellValue::Text("回滚-2".into()))])
        .await
        .expect("插入失败");
    let rows = cdata_core::session::fetch_window(id, first, 2).expect("取窗口失败");
    let (CellValue::Int(id1), CellValue::Int(id2)) = (&rows[0][0], &rows[1][0]) else {
        panic!("自增主键没有回填：{rows:?}");
    };

    // 别人先把第二行删了，缓存里的第二行成了过期数据
    let other = cdata_core::session::open_session(&config);
    cdata_core::session::execute(other, &format!("DELETE FROM edit_target WHERE id = {id2}"), 10)
        .await
        .expect("外部删除失败");

    let err = cdata_core::session::delete_rows(id, vec![first, first + 1])
        .await
        .unwrap_err();
    assert!(err.to_string().contains("回滚"), "{err}");

    // 第一行删成功过，但必须被回滚回来
    assert_eq!(
        count_where(&config, &format!("SELECT COUNT(*) FROM edit_target WHERE id = {id1}")).await,
        1,
        "一批里有一行失败，整批都不能生效"
    );
    // 失败时缓存也不能动
    let window = cdata_core::session::fetch_window(id, first, 10).expect("取窗口失败");
    assert_eq!(window.len(), 2);

    cdata_core::session::execute(other, &format!("DELETE FROM edit_target WHERE id = {id1}"), 10)
        .await
        .expect("清理失败");
    cdata_core::session::close_session(other).await.ok();
    cdata_core::session::close_session(id).await.ok();
}

#[tokio::test]
async fn insert_without_full_composite_key_is_refused_before_writing() {
    let Some(config) = config_from_env() else {
        return;
    };

    let before = count_where(&config, "SELECT COUNT(*) FROM edit_composite").await;

    let id = cdata_core::session::open_session(&config);
    cdata_core::session::execute(id, "SELECT shop_id, order_no, amount FROM edit_composite", 100)
        .await
        .expect("查询失败");

    // order_no 没填，插进去也找不回来 —— 必须在写库之前就拒绝
    let err = cdata_core::session::insert_row(
        id,
        vec![Some(CellValue::Int(7)), None, Some(CellValue::Text("3.00".into()))],
    )
    .await
    .unwrap_err();
    assert!(err.to_string().contains("复合主键"), "{err}");
    assert_eq!(count_where(&config, "SELECT COUNT(*) FROM edit_composite").await, before);

    cdata_core::session::close_session(id).await.ok();
}

#[tokio::test]
async fn read_only_result_refuses_insert_and_delete() {
    let Some(config) = config_from_env() else {
        return;
    };

    let id = cdata_core::session::open_session(&config);
    cdata_core::session::execute(id, "SELECT a, b FROM no_pk", 100)
        .await
        .expect("查询失败");

    let err = cdata_core::session::insert_row(id, vec![None, None]).await.unwrap_err();
    assert!(err.to_string().contains("没有主键"), "{err}");
    let err = cdata_core::session::delete_rows(id, vec![0]).await.unwrap_err();
    assert!(err.to_string().contains("没有主键"), "{err}");

    cdata_core::session::close_session(id).await.ok();
}
