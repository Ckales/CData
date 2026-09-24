//! CSV 导入连真库的测试。
//!
//! 连接信息从 CDATA_TEST_* 环境变量读，没配就跳过。测试库有别人同时在用，所以：
//! - 只用自己的探针表 import_probe（CREATE TABLE IF NOT EXISTS，不删表）
//! - 每个测试写入的行带一个本次运行专属的 run_tag，结束时按它 DELETE 掉
//! - 先把要断言的数据读出来、清理完再断言，断言失败也不留垃圾行

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use cdata_core::db::{open_pool, run_query_with_params, ConnectionConfig, DbPool, ResultSet};
use cdata_core::export::{write_file, ExportEncoding, ExportFormat, ExportOptions};
use cdata_core::import::{
    self, ImportOptions, ImportOutcome, ImportReport, ImportRequest, ImportStatus, OnError,
};
use cdata_core::options::ConnectionOptions;
use mysql_async::prelude::*;
use mysql_async::Value;

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

struct Probe {
    pool: DbPool,
    schema: String,
    /// 本次运行专属的前缀，清理时按它删
    tag: String,
    dir: std::path::PathBuf,
}

async fn probe(name: &str) -> Option<Probe> {
    let config = config_from_env()?;
    let schema = config.database.clone().expect("CDATA_TEST_DB 已配置");
    let pool = open_pool(&config).await.unwrap();
    let mut conn = pool.get_conn().await.unwrap();
    conn.query_drop(
        "CREATE TABLE IF NOT EXISTS import_probe (
           id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
           run_tag VARCHAR(64) NOT NULL,
           txt VARCHAR(20) NULL,
           amount DECIMAL(12,2) NULL,
           bin VARBINARY(16) NULL,
           req INT NOT NULL,
           note TEXT NULL,
           dt DATETIME(6) NULL,
           total INT AS (req * 2) VIRTUAL,
           KEY idx_run_tag (run_tag)
         ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
    )
    .await
    .unwrap();
    drop(conn);

    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let tag = format!("imp-{name}-{}-{nanos}", std::process::id());
    let dir = std::env::temp_dir().join(&tag);
    std::fs::create_dir_all(&dir).unwrap();
    Some(Probe { pool, schema, tag, dir })
}

impl Probe {
    async fn rows(&self, tag: &str) -> ResultSet {
        run_query_with_params(
            &self.pool,
            "SELECT txt, amount, bin, req, note, dt, total FROM import_probe WHERE run_tag = ? ORDER BY id",
            vec![Value::from(tag)],
            1000,
        )
        .await
        .unwrap()
    }

    async fn cleanup(&self) {
        let mut conn = self.pool.get_conn().await.unwrap();
        conn.exec_drop("DELETE FROM import_probe WHERE run_tag LIKE ?", (format!("{}%", self.tag),))
            .await
            .unwrap();
        std::fs::remove_dir_all(&self.dir).ok();
    }

    async fn import(&self, path: &std::path::Path, options: ImportOptions, header: &[String], on_error: OnError, batch_rows: u32) -> ImportReport {
        let target = import::prepare(&self.pool, &self.schema, "import_probe").await.unwrap();
        let request = ImportRequest {
            path: path.to_string_lossy().into_owned(),
            options,
            schema: self.schema.clone(),
            table: "import_probe".to_string(),
            mapping: import::suggest_mapping(header, &target.columns),
            batch_rows,
            on_error,
        };
        let job = import::start(self.pool.clone(), request).await.unwrap();
        let report = wait(job).await;
        import::close(job).unwrap();
        report
    }
}

async fn wait(job: u64) -> ImportReport {
    for _ in 0..3000 {
        if let ImportStatus::Finished(report) = import::status(job).unwrap() {
            return report;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("导入 60 秒没结束");
}

fn names(list: &[&str]) -> Vec<String> {
    let mut out = Vec::new();
    for name in list {
        out.push(name.to_string());
    }
    out
}

#[tokio::test]
async fn exported_csv_imports_back_identically() {
    let Some(probe) = probe("rt").await else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };
    let source = format!("{}-src", probe.tag);
    let mut conn = probe.pool.get_conn().await.unwrap();
    let rows: Vec<(Option<&str>, Option<&str>, Option<Vec<u8>>, i32, Option<&str>, Option<&str>)> = vec![
        (Some("a,b \"q\""), Some("1234567.89"), Some(vec![0x00, 0xFF]), 1, Some("多\r\n行"), Some("2026-09-24 01:02:03.000004")),
        (None, None, None, 2, Some(""), None),
        (Some("NULL"), Some("0.00"), Some(vec![]), 3, Some("\\N"), None),
        (Some(""), Some("-5.10"), None, 4, Some("中文；\t制表"), None),
        (Some("\\N"), None, Some(vec![0x30]), -5, None, Some("2026-01-01 00:00:00.000000")),
    ];
    for (txt, amount, bin, req, note, dt) in rows {
        conn.exec_drop(
            "INSERT INTO import_probe (run_tag, txt, amount, bin, req, note, dt) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (source.as_str(), txt, amount, bin, req, note, dt),
        )
        .await
        .unwrap();
    }
    drop(conn);

    let combos = [
        (ExportEncoding::Utf8, ",", "NULL"),
        (ExportEncoding::Utf8Bom, ";", ""),
        (ExportEncoding::Gbk, "\t", "\\N"),
    ];
    let mut outcomes = Vec::new();
    for (index, (encoding, delimiter, null_text)) in combos.iter().enumerate() {
        let copy = format!("{}-copy{index}", probe.tag);
        // 导出一份结果集：run_tag 换成副本的标记，其余列原样
        let result = run_query_with_params(
            &probe.pool,
            "SELECT CAST(? AS CHAR) AS run_tag, txt, amount, bin, req, note, dt FROM import_probe WHERE run_tag = ? ORDER BY id",
            vec![Value::from(copy.as_str()), Value::from(source.as_str())],
            1000,
        )
        .await
        .unwrap();
        let path = probe.dir.join(format!("rt{index}.csv"));
        let export = ExportOptions {
            format: ExportFormat::Csv,
            encoding: *encoding,
            delimiter: delimiter.to_string(),
            header: true,
            null_text: null_text.to_string(),
            table_name: String::new(),
        };
        let all: Vec<usize> = (0..result.columns.len()).collect();
        write_file(&path, &result.columns, &result.rows, &all, &export).unwrap();

        let options = ImportOptions {
            encoding: *encoding,
            delimiter: delimiter.to_string(),
            header: true,
            null_text: null_text.to_string(),
        };
        let header = names(&["run_tag", "txt", "amount", "bin", "req", "note", "dt"]);
        let report = probe.import(&path, options, &header, OnError::RollbackAll, 2).await;
        outcomes.push((format!("{encoding:?}"), report, probe.rows(&copy).await));
    }
    let original = probe.rows(&source).await;
    probe.cleanup().await;

    assert_eq!(original.rows.len(), 5);
    for (label, report, copied) in outcomes {
        assert_eq!(report.outcome, ImportOutcome::Completed, "{label}: {report:?}");
        assert_eq!(report.progress.rows_inserted, 5, "{label}");
        assert_eq!(report.progress.rows_failed, 0, "{label}");
        assert_eq!(copied.rows, original.rows, "{label}：NULL、空串、\"NULL\"、二进制、换行都要原样回来");
    }
}

/// 第 3 行 NULL 进 NOT NULL（写库前就拦下）、第 4 行 abc 进 DECIMAL、第 5 行超长、
/// 第 6 行少一列；第 7–8 行是一条带换行的记录，第 9 行正常
const MIXED: &str = "run_tag,txt,amount,req,note\r\n\
TAG,ok1,1.00,1,a\r\n\
TAG,bad-null,2.00,NULL,b\r\n\
TAG,bad-decimal,abc,3,c\r\n\
TAG,012345678901234567890,4.00,4,d\r\n\
TAG,short,5.00,5\r\n\
TAG,\"ok6\r\nmulti\",6.00,6,e\r\n\
TAG,ok7,NULL,7,\"NULL\"\r\n";

fn utf8_options() -> ImportOptions {
    ImportOptions {
        encoding: ExportEncoding::Utf8,
        delimiter: ",".to_string(),
        header: true,
        null_text: "NULL".to_string(),
    }
}

#[tokio::test]
async fn skip_mode_keeps_good_rows_and_collects_every_bad_one() {
    let Some(probe) = probe("skip").await else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };
    let path = probe.dir.join("mixed.csv");
    std::fs::write(&path, MIXED.replace("TAG", &probe.tag)).unwrap();
    let header = names(&["run_tag", "txt", "amount", "req", "note"]);

    // 每批 2 行：坏行落在不同批里，要靠 SAVEPOINT 逐行重试才能找出来
    let target = import::prepare(&probe.pool, &probe.schema, "import_probe").await.unwrap();
    let request = ImportRequest {
        path: path.to_string_lossy().into_owned(),
        options: utf8_options(),
        schema: probe.schema.clone(),
        table: "import_probe".to_string(),
        mapping: import::suggest_mapping(&header, &target.columns),
        batch_rows: 2,
        on_error: OnError::SkipRow,
    };
    let job = import::start(probe.pool.clone(), request).await.unwrap();
    let report = wait(job).await;
    let error_path = probe.dir.join("errors.csv");
    let saved = import::save_errors(job, &error_path.to_string_lossy());
    let error_csv = std::fs::read_to_string(&error_path).unwrap_or_default();
    import::close(job).unwrap();
    let rows = probe.rows(&probe.tag).await;
    probe.cleanup().await;

    assert_eq!(report.outcome, ImportOutcome::Completed, "{report:?}");
    assert_eq!(report.progress.rows_read, 7);
    assert_eq!(report.progress.rows_inserted, 3);
    assert_eq!(report.progress.rows_failed, 4);
    let mut failed_lines = Vec::new();
    for error in &report.errors {
        failed_lines.push(error.line);
    }
    failed_lines.sort();
    assert_eq!(failed_lines, [3, 4, 5, 6]);
    let reason = |line: u64| report.errors.iter().find(|e| e.line == line).unwrap().reason.clone();
    assert!(reason(3).contains("req") && reason(3).contains("NULL"), "{}", reason(3));
    // 非 strict 下这两行会被 MySQL 静默改成 0 和截断，导入连接强制 strict 才会报错
    assert!(reason(4).contains("1366") || reason(4).contains("decimal"), "{}", reason(4));
    assert!(reason(5).contains("1406"), "{}", reason(5));
    assert!(reason(6).contains("4 列"), "{}", reason(6));

    let mut texts = Vec::new();
    for row in &rows.rows {
        texts.push(row[0].clone());
    }
    assert_eq!(
        texts,
        [
            cdata_core::CellValue::Text("ok1".into()),
            cdata_core::CellValue::Text("ok6\r\nmulti".into()),
            cdata_core::CellValue::Text("ok7".into()),
        ]
    );
    // ok7：不加引号的 NULL 是 NULL，加了引号的 "NULL" 是文本
    assert_eq!(rows.rows[2][1], cdata_core::CellValue::Null);
    assert_eq!(rows.rows[2][4], cdata_core::CellValue::Text("NULL".into()));
    // 没映射的生成列照常算出来
    assert_eq!(rows.rows[0][6], cdata_core::CellValue::Int(2));

    assert_eq!(saved.unwrap(), 4);
    let lines: Vec<&str> = error_csv.split("\r\n").collect();
    assert_eq!(lines[0], "run_tag,txt,amount,req,note,错误原因");
    assert!(error_csv.contains(&format!("{},bad-null,2.00,NULL,b,第 3 行：", probe.tag)), "{error_csv}");
    assert!(error_csv.contains(&format!("{},short,5.00,5,第 6 行：", probe.tag)), "{error_csv}");
}

#[tokio::test]
async fn rollback_mode_writes_nothing_but_still_reports_every_bad_row() {
    let Some(probe) = probe("rollback").await else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };
    let path = probe.dir.join("mixed.csv");
    std::fs::write(&path, MIXED.replace("TAG", &probe.tag)).unwrap();
    let header = names(&["run_tag", "txt", "amount", "req", "note"]);
    let report = probe.import(&path, utf8_options(), &header, OnError::RollbackAll, 2).await;
    let rows = probe.rows(&probe.tag).await;
    probe.cleanup().await;

    assert_eq!(report.outcome, ImportOutcome::RolledBack, "{report:?}");
    assert_eq!(report.progress.rows_inserted, 0);
    assert_eq!(report.progress.rows_failed, 4);
    assert!(rows.rows.is_empty(), "整体回滚后表里不能留下任何一行");
}

#[tokio::test]
async fn target_columns_and_sql_mode_are_read_from_the_server() {
    let Some(probe) = probe("target").await else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };
    let target = import::prepare(&probe.pool, &probe.schema, "import_probe").await.unwrap();
    let mut conn = probe.pool.get_conn().await.unwrap();
    let session_mode: String = conn.query_first("SELECT @@SESSION.sql_mode").await.unwrap().unwrap();
    // 共享的测试库不能改全局 sql_mode，只在这条连接上模拟非 strict，验证导入连接加 strict 的语句
    let mut forced = Vec::new();
    for start in ["", "ONLY_FULL_GROUP_BY"] {
        conn.exec_drop("SET SESSION sql_mode = ?", (start,)).await.unwrap();
        conn.query_drop(import::FORCE_STRICT_SQL).await.unwrap();
        let mode: String = conn.query_first("SELECT @@SESSION.sql_mode").await.unwrap().unwrap();
        forced.push(mode);
    }
    // 改过会话变量的连接不还回池里
    conn.disconnect().await.unwrap();
    let missing = import::prepare(&probe.pool, &probe.schema, "import_probe_does_not_exist").await;

    // 必填列没映射：开始前就拒绝，不写库
    let path = probe.dir.join("no_req.csv");
    std::fs::write(&path, format!("run_tag,txt\r\n{},x\r\n", probe.tag)).unwrap();
    let request = ImportRequest {
        path: path.to_string_lossy().into_owned(),
        options: utf8_options(),
        schema: probe.schema.clone(),
        table: "import_probe".to_string(),
        mapping: import::suggest_mapping(&names(&["run_tag", "txt"]), &target.columns),
        batch_rows: 100,
        on_error: OnError::SkipRow,
    };
    let refused = import::start(probe.pool.clone(), request).await;
    let rows = probe.rows(&probe.tag).await;
    probe.cleanup().await;

    let column = |name: &str| target.columns.iter().find(|c| c.name == name).unwrap().clone();
    assert!(column("id").auto_increment && !column("id").mandatory);
    assert!(column("run_tag").mandatory);
    assert!(column("req").mandatory);
    assert!(!column("txt").mandatory && column("txt").nullable);
    assert!(column("bin").is_binary && !column("txt").is_binary);
    assert!(column("total").generated && !column("total").mandatory);

    assert_eq!(forced, ["STRICT_ALL_TABLES", "ONLY_FULL_GROUP_BY,STRICT_ALL_TABLES"]);
    assert_eq!(target.sql_mode, session_mode);
    assert_eq!(target.strict, session_mode.contains("STRICT_TRANS_TABLES") || session_mode.contains("STRICT_ALL_TABLES"));

    assert!(missing.unwrap_err().to_string().contains("不存在"));
    let err = refused.unwrap_err().to_string();
    assert!(err.contains("req"), "{err}");
    assert!(rows.rows.is_empty());
}
