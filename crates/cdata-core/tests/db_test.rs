//! 连真库的集成测试。
//!
//! 连接信息从 CDATA_TEST_* 环境变量读，没配就整体跳过 —— 凭据不进源码。
//! 需要的测试库和表见 README 的「开发」一节。

use cdata_core::db::{open_pool, run_query, ConnectionConfig};
use cdata_core::options::ConnectionOptions;
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

    let pool = open_pool(&config).await.unwrap();
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

    let pool = open_pool(&config).await.unwrap();
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

    let pool = open_pool(&config).await.unwrap();
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

    let id = cdata_core::session::open_session(&config).await.unwrap();
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

    let id = cdata_core::session::open_session(&config).await.unwrap();
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

    let id = cdata_core::session::open_session(&config).await.unwrap();
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

    let id = cdata_core::session::open_session(&config).await.unwrap();
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

    let id = cdata_core::session::open_session(&config).await.unwrap();
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

    let id = cdata_core::session::open_session(&config).await.unwrap();
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

    let id = cdata_core::session::open_session(&config).await.unwrap();
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

    let id = cdata_core::session::open_session(&config).await.unwrap();

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

    let id = cdata_core::session::open_session(&config).await.unwrap();
    let base = "SELECT id, name FROM big_rows ORDER BY id LIMIT 100";

    // 原句带 LIMIT：包子查询后语义是「先取前 100 行，再对这 100 行排序」
    let summary = cdata_core::session::execute_view(id, base, &[], true, Some(("id", false)), 200)
        .await
        .expect("排序查询失败");
    assert_eq!(summary.total_rows, 100);
    let rows = cdata_core::session::fetch_window(id, 0, 1).expect("取窗口失败");
    assert_eq!(rows[0][0], CellValue::Int(100), "降序后第一行应该是 100");

    cdata_core::session::execute_view(id, base, &[], true, Some(("id", true)), 200)
        .await
        .expect("排序查询失败");
    let rows = cdata_core::session::fetch_window(id, 0, 1).expect("取窗口失败");
    assert_eq!(rows[0][0], CellValue::Int(1));

    cdata_core::session::close_session(id).await.ok();
}

fn condition(column: &str, op: cdata_core::sql::FilterOp, value: &str) -> cdata_core::sql::FilterCondition {
    cdata_core::sql::FilterCondition { column: column.to_string(), op, value: value.to_string() }
}

#[tokio::test]
async fn filter_and_sort_run_on_the_server() {
    use cdata_core::sql::FilterOp;
    let Some(config) = config_from_env() else {
        return;
    };

    let id = cdata_core::session::open_session(&config).await.unwrap();

    // 数字比较 + 降序：值按字符串绑定，MySQL 按列类型转
    let summary = cdata_core::session::execute_view(
        id,
        "SELECT * FROM big_rows",
        &[condition("id", FilterOp::LtEq, "3")],
        true,
        Some(("id", false)),
        200,
    )
    .await
    .expect("筛选失败");
    assert_eq!(summary.total_rows, 3);
    let rows = cdata_core::session::fetch_window(id, 0, 3).expect("取窗口失败");
    assert_eq!(rows[0][0], CellValue::Int(3));

    // 中文 LIKE：用户9999 和 用户99990 … 用户99999
    let summary = cdata_core::session::execute_view(
        id,
        "SELECT id, name AS 名字 FROM big_rows",
        &[condition("名字", FilterOp::Contains, "用户9999")],
        true,
        None,
        200,
    )
    .await
    .expect("筛选失败");
    assert_eq!(summary.total_rows, 11, "按别名筛选，别名也要能用");

    // 任一满足
    let summary = cdata_core::session::execute_view(
        id,
        "SELECT * FROM big_rows",
        &[condition("id", FilterOp::Eq, "1"), condition("id", FilterOp::Eq, "2")],
        false,
        None,
        200,
    )
    .await
    .expect("筛选失败");
    assert_eq!(summary.total_rows, 2);

    // IS NULL 和直接写 WHERE 的结果一致
    let nulls = cdata_core::session::execute_view(
        id,
        "SELECT * FROM big_rows",
        &[condition("note", FilterOp::IsNull, "")],
        true,
        None,
        200_000,
    )
    .await
    .expect("筛选失败");
    assert!(nulls.total_rows > 0, "开发库里 note 有 NULL");
    assert_eq!(
        nulls.total_rows as i64,
        count_where(&config, "SELECT COUNT(*) FROM big_rows WHERE note IS NULL").await
    );

    cdata_core::session::close_session(id).await.ok();
}

#[tokio::test]
async fn filtered_result_is_still_editable() {
    use cdata_core::sql::FilterOp;
    let Some(config) = config_from_env() else {
        return;
    };

    let id = cdata_core::session::open_session(&config).await.unwrap();
    let summary = cdata_core::session::execute_view(
        id,
        "SELECT id, name, amount FROM edit_target",
        &[condition("id", FilterOp::Eq, "1")],
        true,
        Some(("id", true)),
        100,
    )
    .await
    .expect("筛选失败");

    // 包一层派生表后，列元数据里的原始表还在，照样能按主键写回
    match &summary.editability {
        cdata_core::edit::Editability::Editable(target) => assert_eq!(target.table, "edit_target"),
        cdata_core::edit::Editability::ReadOnly(reason) => panic!("筛选后应该还能编辑：{reason}"),
    }
    assert!(summary.layout_key.is_some(), "筛选后列布局也要能记");

    cdata_core::session::close_session(id).await.ok();
}

/// 数一下某个条件下的行数，用独立会话查，不碰被测会话的缓存
async fn count_where(config: &ConnectionConfig, sql: &str) -> i64 {
    let id = cdata_core::session::open_session(config).await.unwrap();
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

    let id = cdata_core::session::open_session(&config).await.unwrap();
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

    let id = cdata_core::session::open_session(&config).await.unwrap();
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
    let other = cdata_core::session::open_session(&config).await.unwrap();
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

    let id = cdata_core::session::open_session(&config).await.unwrap();
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

    let id = cdata_core::session::open_session(&config).await.unwrap();
    cdata_core::session::execute(id, "SELECT a, b FROM no_pk", 100)
        .await
        .expect("查询失败");

    let err = cdata_core::session::insert_row(id, vec![None, None]).await.unwrap_err();
    assert!(err.to_string().contains("没有主键"), "{err}");
    let err = cdata_core::session::delete_rows(id, vec![0]).await.unwrap_err();
    assert!(err.to_string().contains("没有主键"), "{err}");

    cdata_core::session::close_session(id).await.ok();
}

#[tokio::test]
async fn edit_caches_what_the_database_stored_not_what_was_typed() {
    let Some(config) = config_from_env() else {
        return;
    };

    let id = cdata_core::session::open_session(&config).await.unwrap();
    let summary = cdata_core::session::execute(
        id,
        "SELECT id, name, amount FROM edit_target ORDER BY id",
        100,
    )
    .await
    .expect("查询失败");
    let index = summary.total_rows;
    cdata_core::session::insert_row(id, vec![None, Some(CellValue::Text("缓存回读".into())), None])
        .await
        .expect("插入失败");

    // DECIMAL(12,2) 存进去是 7.50，缓存里要是库里的值
    cdata_core::session::apply_edit(id, index, 2, CellValue::Text("7.5".into()))
        .await
        .expect("写回失败");
    let row = cdata_core::session::fetch_window(id, index, 1).expect("取窗口失败").remove(0);
    assert_eq!(row[2], CellValue::Text("7.50".to_string()), "界面要显示库里真实存下的值");

    cdata_core::session::delete_rows(id, vec![index]).await.expect("清理失败");
    cdata_core::session::close_session(id).await.ok();
}

/// 在 edit_target 末尾插 n 行给粘贴测试用，返回第一行的下标和这些行的 id
async fn insert_scratch_rows(session: u64, first: u64, n: usize, tag: &str) -> Vec<i64> {
    for i in 0..n {
        cdata_core::session::insert_row(
            session,
            vec![None, Some(CellValue::Text(format!("{tag}-{i}"))), None, None],
        )
        .await
        .expect("插入失败");
    }
    let rows = cdata_core::session::fetch_window(session, first, n as u64).expect("取窗口失败");
    let mut ids = Vec::new();
    for row in rows {
        match row[0] {
            CellValue::Int(id) => ids.push(id),
            ref other => panic!("自增主键没有回填：{other:?}"),
        }
    }
    ids
}

#[tokio::test]
async fn paste_writes_a_block_and_caches_stored_values() {
    let Some(config) = config_from_env() else {
        return;
    };

    let id = cdata_core::session::open_session(&config).await.unwrap();
    let summary = cdata_core::session::execute(
        id,
        "SELECT id, name, amount, note FROM edit_target ORDER BY id",
        100,
    )
    .await
    .expect("查询失败");
    let first = summary.total_rows;
    insert_scratch_rows(id, first, 2, "粘贴").await;

    // 从表格软件粘两行两列：amount、note。note 第二行是 NULL
    let values = cdata_core::clipboard::decode("1.5\t备注一\r\n2\tNULL\r\n").expect("解析失败");
    let written = cdata_core::session::paste_cells(id, first, vec![2, 3], values)
        .await
        .expect("粘贴失败");
    // 第二行 note 本来就是 NULL，没变的格子不写
    assert_eq!(written, 3);

    let rows = cdata_core::session::fetch_window(id, first, 2).expect("取窗口失败");
    assert_eq!(rows[0][2], CellValue::Text("1.50".to_string()), "缓存里是库里存的值");
    assert_eq!(rows[0][3], CellValue::Text("备注一".to_string()));
    assert_eq!(rows[1][2], CellValue::Text("2.00".to_string()));
    assert_eq!(rows[1][3], CellValue::Null);

    // 复制出来就是库里的值，列按给的顺序
    let tsv = cdata_core::session::copy_range(id, first, 2, vec![3, 2]).expect("复制失败");
    assert_eq!(tsv, "备注一\t1.50\nNULL\t2.00");

    // 再粘一遍同样的值：开了 CLIENT_FOUND_ROWS，写入相同内容不会被误判成定位失败
    let rewritten = cdata_core::session::paste_cells(id, first, vec![2], vec![vec![CellValue::Text("1.5".into())]])
        .await
        .expect("写入相同的值不该失败");
    assert_eq!(rewritten, 1);

    cdata_core::session::delete_rows(id, vec![first, first + 1]).await.expect("清理失败");
    cdata_core::session::close_session(id).await.ok();
}

#[tokio::test]
async fn paste_refuses_primary_key_and_out_of_range_before_writing() {
    let Some(config) = config_from_env() else {
        return;
    };

    let id = cdata_core::session::open_session(&config).await.unwrap();
    let summary = cdata_core::session::execute(
        id,
        "SELECT id, name FROM edit_target ORDER BY id",
        100,
    )
    .await
    .expect("查询失败");
    let total = summary.total_rows;

    let err = cdata_core::session::paste_cells(id, 0, vec![0], vec![vec![CellValue::Text("99".into())]])
        .await
        .unwrap_err();
    assert!(err.to_string().contains("主键"), "{err}");

    let two_rows = vec![vec![CellValue::Text("x".into())], vec![CellValue::Text("y".into())]];
    let err = cdata_core::session::paste_cells(id, total - 1, vec![1], two_rows)
        .await
        .unwrap_err();
    assert!(err.to_string().contains("超出"), "{err}");

    cdata_core::session::close_session(id).await.ok();
}

#[tokio::test]
async fn paste_rolls_back_when_any_row_is_stale() {
    let Some(config) = config_from_env() else {
        return;
    };

    let id = cdata_core::session::open_session(&config).await.unwrap();
    let summary = cdata_core::session::execute(
        id,
        "SELECT id, name, amount, note FROM edit_target ORDER BY id",
        100,
    )
    .await
    .expect("查询失败");
    let first = summary.total_rows;
    let ids = insert_scratch_rows(id, first, 2, "粘贴回滚").await;

    // 别人把第二行删了
    let other = cdata_core::session::open_session(&config).await.unwrap();
    cdata_core::session::execute(other, &format!("DELETE FROM edit_target WHERE id = {}", ids[1]), 10)
        .await
        .expect("外部删除失败");

    let values = vec![vec![CellValue::Text("改了".into())], vec![CellValue::Text("也改了".into())]];
    let err = cdata_core::session::paste_cells(id, first, vec![1], values).await.unwrap_err();
    assert!(err.to_string().contains("回滚"), "{err}");

    // 第一行写成功过，但必须被回滚
    assert_eq!(
        count_where(&config, &format!("SELECT COUNT(*) FROM edit_target WHERE id = {} AND name = '粘贴回滚-0'", ids[0])).await,
        1
    );

    cdata_core::session::execute(other, &format!("DELETE FROM edit_target WHERE id = {}", ids[0]), 10)
        .await
        .expect("清理失败");
    cdata_core::session::close_session(other).await.ok();
    cdata_core::session::close_session(id).await.ok();
}

#[tokio::test]
async fn table_structure_reads_columns_indexes_foreign_keys_and_ddl() {
    use cdata_core::structure::DefaultValue;
    let Some(config) = config_from_env() else {
        return;
    };
    let database = config.database.clone().unwrap();

    // 结构测试要有索引和外键，自己建两张探针表（只增不删，重复跑不影响）
    let setup = cdata_core::session::open_session(&config).await.unwrap();
    for ddl in [
        "CREATE TABLE IF NOT EXISTS structure_parent (\
            id INT UNSIGNED PRIMARY KEY, code VARCHAR(20) NOT NULL, UNIQUE KEY uk_code (code)\
         ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
        "CREATE TABLE IF NOT EXISTS structure_child (\
            id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,\
            parent_id INT UNSIGNED NOT NULL,\
            title VARCHAR(100) NOT NULL DEFAULT '' COMMENT '标题',\
            body TEXT,\
            status ENUM('draft','done') NOT NULL DEFAULT 'draft',\
            created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,\
            KEY idx_title_prefix (title(10), status),\
            CONSTRAINT fk_child_parent FOREIGN KEY (parent_id) REFERENCES structure_parent (id) ON DELETE CASCADE\
         ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
    ] {
        cdata_core::session::execute(setup, ddl, 1).await.expect("建探针表失败");
    }

    let structure = cdata_core::session::table_structure(setup, &database, "structure_child")
        .await
        .expect("读结构失败");

    let names: Vec<&str> = structure.columns.iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, ["id", "parent_id", "title", "body", "status", "created_at"]);

    let column = |name: &str| structure.columns.iter().find(|c| c.name == name).unwrap().clone();
    assert_eq!(column("id").default, DefaultValue::NoDefault);
    assert!(column("id").extra.contains("auto_increment"));
    assert_eq!(column("title").default, DefaultValue::Literal(String::new()), "空串默认值不是没有默认值");
    assert_eq!(column("title").comment, "标题");
    assert_eq!(column("body").default, DefaultValue::Null);
    assert_eq!(column("status").column_type, "enum('draft','done')");
    assert_eq!(column("status").default, DefaultValue::Literal("draft".into()));
    assert_eq!(column("created_at").default, DefaultValue::Expression("CURRENT_TIMESTAMP".into()));

    assert_eq!(structure.indexes[0].name, "PRIMARY", "主键排第一");
    let prefix = structure.indexes.iter().find(|i| i.name == "idx_title_prefix").unwrap();
    assert!(!prefix.unique);
    assert_eq!(prefix.columns, ["title(10)", "status"]);

    assert_eq!(structure.foreign_keys.len(), 1);
    let fk = &structure.foreign_keys[0];
    assert_eq!(fk.name, "fk_child_parent");
    assert_eq!(fk.columns, ["parent_id"]);
    assert_eq!(fk.referenced_table, "structure_parent");
    assert_eq!(fk.referenced_columns, ["id"]);
    assert_eq!(fk.on_delete, "CASCADE");

    assert!(structure.create_sql.starts_with("CREATE TABLE `structure_child`"), "{}", structure.create_sql);

    let parent = cdata_core::session::table_structure(setup, &database, "structure_parent")
        .await
        .expect("读结构失败");
    assert!(parent.indexes.iter().any(|i| i.name == "uk_code" && i.unique));

    cdata_core::session::close_session(setup).await.ok();
}

#[tokio::test]
async fn column_kinds_come_from_metadata_and_choices_from_the_table() {
    use cdata_core::db::ColumnKind;
    let Some(config) = config_from_env() else {
        return;
    };

    let id = cdata_core::session::open_session(&config).await.unwrap();
    // 包一层筛选的派生表，类别也不能丢
    let summary = cdata_core::session::execute_view(id, "SELECT * FROM type_zoo", &[], true, Some(("id", true)), 10)
        .await
        .expect("查询失败");

    let kind = |name: &str| summary.columns.iter().find(|c| c.name == name).unwrap().kind;
    assert_eq!(kind("id"), ColumnKind::Number);
    assert_eq!(kind("amount"), ColumnKind::Number);
    assert_eq!(kind("d_zero"), ColumnKind::Date);
    assert_eq!(kind("dt_micro"), ColumnKind::DateTime);
    assert_eq!(kind("t_neg"), ColumnKind::Time);
    assert_eq!(kind("txt_cn"), ColumnKind::Text);
    assert_eq!(kind("json_col"), ColumnKind::Json);
    assert_eq!(kind("enum_col"), ColumnKind::Enum);
    assert_eq!(kind("set_col"), ColumnKind::Set);
    assert_eq!(kind("blob_col"), ColumnKind::Binary);
    assert_eq!(kind("bit_col"), ColumnKind::Binary);

    let enum_index = summary.columns.iter().position(|c| c.name == "enum_col").unwrap() as u64;
    let choices = cdata_core::session::column_choices(id, enum_index).await.expect("读可选值失败");
    assert_eq!(choices, ["draft", "paid", "refunded"]);

    let set_index = summary.columns.iter().position(|c| c.name == "set_col").unwrap() as u64;
    let choices = cdata_core::session::column_choices(id, set_index).await.expect("读可选值失败");
    assert_eq!(choices, ["x", "y", "z"]);

    let err = cdata_core::session::column_choices(id, 0).await.unwrap_err();
    assert!(err.to_string().contains("不是 ENUM"), "{err}");

    cdata_core::session::close_session(id).await.ok();
}

#[tokio::test]
async fn export_writes_the_current_view_and_reports_truncation() {
    use cdata_core::export::{ExportEncoding, ExportFormat, ExportOptions};
    use cdata_core::sql::FilterOp;
    let Some(config) = config_from_env() else {
        return;
    };

    let id = cdata_core::session::open_session(&config).await.unwrap();
    // 导出的是当前视图：筛选后降序的 3 行
    cdata_core::session::execute_view(
        id,
        "SELECT id, name, amount FROM big_rows",
        &[condition("id", FilterOp::LtEq, "3")],
        true,
        Some(("id", false)),
        100,
    )
    .await
    .expect("查询失败");

    let dir = std::env::temp_dir().join(format!("cdata-export-db-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("rows.csv");
    let options = ExportOptions {
        format: ExportFormat::Csv,
        encoding: ExportEncoding::Utf8,
        delimiter: ",".to_string(),
        header: true,
        null_text: String::new(),
        table_name: String::new(),
    };

    let summary = cdata_core::session::export_rows(id, path.to_str().unwrap(), 0, None, vec![0, 1, 2], &options)
        .expect("导出失败");
    assert_eq!(summary.rows_written, 3);
    assert!(!summary.source_truncated);
    assert_eq!(
        std::fs::read_to_string(&path).unwrap(),
        "id,name,amount\r\n3,用户3,3.69\r\n2,用户2,2.46\r\n1,用户1,1.23\r\n"
    );

    // 截断过的结果集导出去要带着截断标记
    cdata_core::session::execute(id, "SELECT id FROM big_rows ORDER BY id", 10).await.expect("查询失败");
    let summary = cdata_core::session::export_rows(id, path.to_str().unwrap(), 0, None, vec![0], &options)
        .expect("导出失败");
    assert_eq!(summary.rows_written, 10);
    assert!(summary.source_truncated, "截断过的结果导出去也是不完整的，必须告诉界面");

    std::fs::remove_dir_all(&dir).ok();
    cdata_core::session::close_session(id).await.ok();
}

#[tokio::test]
async fn completion_uses_the_loaded_catalog() {
    let Some(config) = config_from_env() else {
        return;
    };
    let database = config.database.clone().unwrap();

    let id = cdata_core::session::open_session(&config).await.unwrap();
    // 没加载目录时只有关键字，不报错
    let before = cdata_core::session::complete_sql(id, "SELECT * FROM ", 14).expect("补全失败");
    assert!(before.items.is_empty(), "没有目录就没有表可补");

    let tables = cdata_core::session::load_catalog(id, &database).await.expect("读目录失败");
    assert!(tables >= 5);

    let sql = "SELECT e. FROM edit_target e";
    let completion = cdata_core::session::complete_sql(id, sql, 9).expect("补全失败");
    let mut labels = Vec::new();
    for item in &completion.items {
        labels.push(item.label.as_str());
    }
    assert_eq!(labels, ["id", "name", "amount", "note"]);

    let completion = cdata_core::session::complete_sql(id, "SELECT * FROM big", 17).expect("补全失败");
    assert_eq!(completion.items[0].label, "big_rows");

    cdata_core::session::close_session(id).await.ok();
}

/// information_schema 里是 SYSTEM VIEW，也要标成视图：侧栏按它给视图图标，编辑按它拒绝
#[tokio::test]
async fn system_views_are_listed_as_views() {
    let Some(config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };
    let pool = open_pool(&config).await.unwrap();
    let tables = cdata_core::schema::list_tables(&pool, "information_schema").await.unwrap();
    let tables_view = tables.iter().find(|t| t.name == "TABLES").expect("information_schema 里应该有 TABLES");
    assert!(tables_view.is_view, "SYSTEM VIEW 没被当成视图");
}
