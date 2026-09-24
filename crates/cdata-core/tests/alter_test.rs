//! 表结构编辑连真库的测试。
//!
//! 连接信息从 CDATA_TEST_* 环境变量读，没配就跳过。
//! 数据安全：执行语义用 CREATE TEMPORARY TABLE 测（只在这条连接上，断开自动消失）；
//! 要走 information_schema 的用 alter_probe_* 探针表（IF NOT EXISTS），每个测试结束时结构改回原样。
//! 从不 DROP TABLE / TRUNCATE，也不碰别的表。

use cdata_core::alter::{plan_alter, run_statements, table_draft, ColumnDraft, IndexKind, TableDraft};
use cdata_core::db::{open_pool, ConnectionConfig};
use cdata_core::options::ConnectionOptions;
use cdata_core::session;
use cdata_core::structure::{ColumnDef, DefaultValue, IndexDef, IndexPart, TableStructure};
use mysql_async::prelude::Queryable;
use mysql_async::Conn;

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

async fn show_create(conn: &mut Conn, table: &str) -> String {
    let row: Option<(String, String)> = conn.query_first(format!("SHOW CREATE TABLE `{table}`")).await.unwrap();
    row.unwrap().1
}

/// 建表语句按行排序后比较：删了重建的索引在 SHOW CREATE 里会换位置，但结构是一样的
fn sorted_lines(sql: &str) -> Vec<String> {
    let mut lines: Vec<String> = sql.lines().map(|line| line.trim_end_matches(',').to_string()).collect();
    lines.sort();
    lines
}

fn column_mut<'a>(draft: &'a mut TableDraft, name: &str) -> &'a mut ColumnDraft {
    draft.columns.iter_mut().find(|c| c.name == name).unwrap_or_else(|| panic!("草稿里没有列 {name}"))
}

/// 预览再执行，走和界面一样的路径
async fn preview_and_apply(id: u64, database: &str, table: &str, original: &TableStructure, draft: &TableDraft) {
    let plan = session::preview_alter(id, database, table, original, draft).await.expect("预览失败");
    session::apply_alter(id, database, table, original, draft, &plan.statements)
        .await
        .unwrap_or_else(|err| panic!("执行失败：{err}\n{:?}", plan.statements));
}

const ROUNDTRIP_DDL: &str = "CREATE TABLE IF NOT EXISTS alter_probe_roundtrip (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  code VARCHAR(20) CHARACTER SET latin1 COLLATE latin1_bin NOT NULL DEFAULT 'a''b' COMMENT '说明',
  price DECIMAL(12,2) NOT NULL DEFAULT '0.00',
  note VARCHAR(50) DEFAULT NULL COMMENT 'it''s',
  bs VARCHAR(10) DEFAULT 'a\\\\b' COMMENT 'c\\\\d',
  u CHAR(36) NOT NULL DEFAULT (uuid()),
  w VARCHAR(20) DEFAULT (concat('x','y')),
  ts DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  st ENUM('draft','it''s') NOT NULL DEFAULT 'draft',
  body TEXT,
  PRIMARY KEY (id),
  KEY idx_code_desc (code, price DESC),
  UNIQUE KEY uk_u (u),
  KEY idx_note_prefix (note(10)) COMMENT '前缀',
  FULLTEXT KEY ft_body (body)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='alter 测试探针'";

/// 探针表各列的原注释。测试中途失败留下的改动，下一次开头按它复位
const ROUNDTRIP_COMMENTS: [(&str, &str); 3] = [("code", "说明"), ("note", "it's"), ("bs", "c\\d")];

/// 本任务最大的数据风险：MODIFY 只改注释，其余属性（字符集、默认值、ON UPDATE、自增、降序索引）都不能被重置
#[tokio::test]
async fn modify_keeps_every_other_attribute_through_information_schema() {
    let Some(config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };
    let database = config.database.clone().unwrap();
    let id = session::open_session(&config).await.unwrap();
    session::execute(id, ROUNDTRIP_DDL, 1).await.expect("建探针表失败");

    // 复位：上一次中途失败的话注释可能还是改过的样子
    let current = session::table_structure(id, &database, "alter_probe_roundtrip").await.unwrap();
    let mut reset = table_draft(&current);
    for column in &mut reset.columns {
        if column.locked.is_some() {
            continue;
        }
        column.comment = ROUNDTRIP_COMMENTS.iter().find(|(name, _)| *name == column.name).map(|(_, c)| c.to_string()).unwrap_or_default();
    }
    reset.indexes.iter_mut().find(|i| i.name == "idx_code_desc").unwrap().comment = String::new();
    if session::preview_alter(id, &database, "alter_probe_roundtrip", &current, &reset).await.is_ok() {
        preview_and_apply(id, &database, "alter_probe_roundtrip", &current, &reset).await;
    }

    let pool = open_pool(&config).await.unwrap();
    let mut conn = pool.get_conn().await.unwrap();
    let create_before = show_create(&mut conn, "alter_probe_roundtrip").await;
    let before = session::table_structure(id, &database, "alter_probe_roundtrip").await.unwrap();

    let mut draft = table_draft(&before);
    // information_schema 里表达式默认值的引号写成 \'，照抄回去是错的，这一列必须锁住
    assert!(column_mut(&mut draft, "w").locked.is_some(), "表达式里带引号的列应该锁住");
    for column in &mut draft.columns {
        assert!(column.name == "w" || column.locked.is_none(), "{} 不该锁住：{:?}", column.name, column.locked);
        if column.locked.is_none() {
            column.comment = "probe".to_string();
        }
    }
    // 降序索引删了重建，DESC 不能丢
    draft.indexes.iter_mut().find(|i| i.name == "idx_code_desc").unwrap().comment = "probe".to_string();

    let plan = session::preview_alter(id, &database, "alter_probe_roundtrip", &before, &draft).await.unwrap();
    assert_eq!(plan.statements.len(), 1, "{:?}", plan.statements);
    assert!(plan.dangers.is_empty(), "只改注释不该有危险提示：{:?}", plan.dangers);
    preview_and_apply(id, &database, "alter_probe_roundtrip", &before, &draft).await;

    let after = session::table_structure(id, &database, "alter_probe_roundtrip").await.unwrap();
    for (old, new) in before.columns.iter().zip(&after.columns) {
        assert_eq!(
            (&old.name, &old.column_type, old.nullable, &old.default, &old.extra, &old.collation),
            (&new.name, &new.column_type, new.nullable, &new.default, &new.extra, &new.collation),
            "改注释不能动到别的属性"
        );
        if old.name != "w" {
            assert_eq!(new.comment, "probe");
        }
    }
    let rebuilt = after.indexes.iter().find(|i| i.name == "idx_code_desc").unwrap();
    assert_eq!(rebuilt.columns, ["code", "price DESC"]);
    assert_eq!(rebuilt.comment, "probe");

    // 改回去，建表语句逐行一致
    let mut restore = table_draft(&after);
    for column in &mut restore.columns {
        if column.locked.is_none() {
            column.comment = ROUNDTRIP_COMMENTS.iter().find(|(name, _)| *name == column.name).map(|(_, c)| c.to_string()).unwrap_or_default();
        }
    }
    restore.indexes.iter_mut().find(|i| i.name == "idx_code_desc").unwrap().comment = String::new();
    preview_and_apply(id, &database, "alter_probe_roundtrip", &after, &restore).await;

    let create_after = show_create(&mut conn, "alter_probe_roundtrip").await;
    assert_eq!(sorted_lines(&create_before), sorted_lines(&create_after), "改回去后结构应该和开始时一样");
    let final_structure = session::table_structure(id, &database, "alter_probe_roundtrip").await.unwrap();
    assert_eq!(final_structure.columns, before.columns);

    drop(conn);
    pool.disconnect().await.ok();
    session::close_session(id).await.ok();
}

#[tokio::test]
async fn preview_refuses_a_stale_structure_and_counts_nulls() {
    let Some(config) = config_from_env() else {
        return;
    };
    let database = config.database.clone().unwrap();
    let id = session::open_session(&config).await.unwrap();
    session::execute(
        id,
        "CREATE TABLE IF NOT EXISTS alter_probe_nulls (id INT NOT NULL PRIMARY KEY, note VARCHAR(10) NULL) ENGINE=InnoDB",
        1,
    )
    .await
    .unwrap();
    session::execute(id, "INSERT IGNORE INTO alter_probe_nulls VALUES (1, NULL), (2, 'x')", 1).await.unwrap();

    let structure = session::table_structure(id, &database, "alter_probe_nulls").await.unwrap();
    let mut draft = table_draft(&structure);
    let note = column_mut(&mut draft, "note");
    note.nullable = false;
    note.default = DefaultValue::NoDefault;

    // 只预览不执行，表不动
    let plan = session::preview_alter(id, &database, "alter_probe_nulls", &structure, &draft).await.unwrap();
    assert!(plan.dangers.iter().any(|d| d.contains("现有 1 行是 NULL")), "{:?}", plan.dangers);

    let mut stale = structure.clone();
    stale.columns[1].comment = "别人改过".to_string();
    let err = session::preview_alter(id, &database, "alter_probe_nulls", &stale, &draft).await.unwrap_err();
    assert!(err.to_string().contains("被改过"), "{err}");

    let err = session::apply_alter(id, &database, "alter_probe_nulls", &structure, &draft, &["SELECT 1".to_string()])
        .await
        .unwrap_err();
    assert!(err.to_string().contains("和预览时不一样"), "{err}");

    session::close_session(id).await.ok();
}

/// 删掉又加回同名外键要拆两条；第 2 条失败时报告第 1 条已经生效
#[tokio::test]
async fn foreign_key_readd_splits_and_reports_partial_failure() {
    let Some(config) = config_from_env() else {
        return;
    };
    let database = config.database.clone().unwrap();
    let id = session::open_session(&config).await.unwrap();
    for ddl in [
        "CREATE TABLE IF NOT EXISTS alter_probe_parent (\
            id INT UNSIGNED NOT NULL PRIMARY KEY, code VARCHAR(20) NOT NULL, UNIQUE KEY uk_code (code)\
         ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
        "CREATE TABLE IF NOT EXISTS alter_probe_child (\
            id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,\
            parent_id INT UNSIGNED NOT NULL,\
            parent_code VARCHAR(20) DEFAULT NULL,\
            CONSTRAINT fk_probe_parent FOREIGN KEY (parent_id) REFERENCES alter_probe_parent (id) ON DELETE CASCADE\
         ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
    ] {
        session::execute(id, ddl, 1).await.expect("建探针表失败");
    }

    let pool = open_pool(&config).await.unwrap();
    let mut conn = pool.get_conn().await.unwrap();
    let create_before = show_create(&mut conn, "alter_probe_child").await;
    let start = session::table_structure(id, &database, "alter_probe_child").await.unwrap();
    assert_eq!(start.foreign_keys.len(), 1, "探针表的外键被上一次中途失败弄丢了，手动加回：{create_before}");

    // 改 ON DELETE：同名外键删了重加
    let mut draft = table_draft(&start);
    draft.foreign_keys[0].on_delete = "RESTRICT".to_string();
    let plan = session::preview_alter(id, &database, "alter_probe_child", &start, &draft).await.unwrap();
    assert_eq!(plan.statements.len(), 2, "{:?}", plan.statements);
    preview_and_apply(id, &database, "alter_probe_child", &start, &draft).await;
    let changed = session::table_structure(id, &database, "alter_probe_child").await.unwrap();
    assert_eq!(changed.foreign_keys[0].on_delete, "RESTRICT");

    // 第 2 条引用不存在的列，必然失败；第 1 条删外键已经生效
    let mut broken = table_draft(&changed);
    broken.foreign_keys[0].referenced_columns = vec!["no_such_column".to_string()];
    let plan = session::preview_alter(id, &database, "alter_probe_child", &changed, &broken).await.unwrap();
    let err = session::apply_alter(id, &database, "alter_probe_child", &changed, &broken, &plan.statements)
        .await
        .unwrap_err()
        .to_string();
    assert!(err.contains("第 2 条（共 2 条）执行失败") && err.contains("前 1 条已经生效"), "{err}");

    // 外键没了，按原样加回
    let dropped = session::table_structure(id, &database, "alter_probe_child").await.unwrap();
    assert!(dropped.foreign_keys.is_empty());
    let mut restore = table_draft(&dropped);
    let mut fk = table_draft(&start).foreign_keys.remove(0);
    fk.original_name = None;
    restore.foreign_keys.push(fk);
    preview_and_apply(id, &database, "alter_probe_child", &dropped, &restore).await;

    let create_after = show_create(&mut conn, "alter_probe_child").await;
    assert_eq!(sorted_lines(&create_before), sorted_lines(&create_after));

    drop(conn);
    pool.disconnect().await.ok();
    session::close_session(id).await.ok();
}

fn simple_column(name: &str, column_type: &str) -> ColumnDef {
    ColumnDef {
        name: name.to_string(),
        column_type: column_type.to_string(),
        nullable: true,
        default: DefaultValue::Null,
        extra: String::new(),
        comment: String::new(),
        collation: None,
    }
}

fn new_column(name: &str, column_type: &str, nullable: bool, default: DefaultValue, comment: &str) -> ColumnDraft {
    ColumnDraft {
        original_name: None,
        name: name.to_string(),
        column_type: column_type.to_string(),
        nullable,
        default,
        auto_increment: false,
        on_update: None,
        comment: comment.to_string(),
        collation: None,
        locked: None,
    }
}

fn column_order(create_sql: &str) -> Vec<String> {
    let mut names = Vec::new();
    for line in create_sql.lines() {
        if let Some(rest) = line.trim().strip_prefix('`') {
            names.push(rest[..rest.find('`').unwrap()].to_string());
        }
    }
    names
}

/// 临时表上验证一条 ALTER 里多个 FIRST / AFTER、改名、在改名后的列上建索引的执行语义
#[tokio::test]
async fn one_alter_moves_renames_and_indexes_on_a_temporary_table() {
    let Some(config) = config_from_env() else {
        return;
    };
    let pool = open_pool(&config).await.unwrap();
    let mut conn = pool.get_conn().await.unwrap();
    conn.query_drop("CREATE TEMPORARY TABLE alter_tmp_order (a INT, b INT, c INT, d INT, e INT, KEY idx_b (b))")
        .await
        .unwrap();

    let index = IndexDef {
        name: "idx_b".to_string(),
        unique: false,
        columns: vec!["b".to_string()],
        parts: vec![IndexPart { column: Some("b".to_string()), prefix: None, descending: false }],
        index_type: "BTREE".to_string(),
        comment: String::new(),
    };
    let original = TableStructure {
        columns: ["a", "b", "c", "d", "e"].iter().map(|n| simple_column(n, "int")).collect(),
        indexes: vec![index],
        foreign_keys: Vec::new(),
        create_sql: String::new(),
        table_collation: None,
    };

    // 目标：e, a, bb(原 b), x(新), d；删 c；原来 b 上的索引跟着改名；新建 (bb, x) 索引
    let mut draft = table_draft(&original);
    let mut columns = draft.columns.clone();
    columns.retain(|c| c.name != "c");
    let e = columns.remove(3);
    columns.insert(0, e); // e a b d
    let b = columns.iter_mut().find(|c| c.name == "b").unwrap();
    b.name = "bb".to_string();
    b.comment = "改名".to_string();
    columns.insert(3, new_column("x", "varchar(10)", false, DefaultValue::Literal(String::new()), "")); // e a bb x d
    draft.columns = columns;
    draft.indexes[0].parts[0].column = Some("bb".to_string());
    draft.indexes.push(cdata_core::alter::IndexDraft {
        original_name: None,
        name: "idx_bb_x".to_string(),
        kind: IndexKind::Normal,
        parts: vec![
            IndexPart { column: Some("bb".to_string()), prefix: None, descending: false },
            IndexPart { column: Some("x".to_string()), prefix: Some(4), descending: false },
        ],
        comment: String::new(),
        locked: None,
    });

    let database = config.database.clone().unwrap();
    let (plan, _) = plan_alter(&database, "alter_tmp_order", &original, &draft, false).unwrap();
    assert_eq!(plan.statements.len(), 1, "{:?}", plan.statements);
    run_statements(&mut conn, &plan.statements).await.unwrap_or_else(|(_, err)| panic!("{err}\n{}", plan.statements[0]));

    let create = show_create(&mut conn, "alter_tmp_order").await;
    assert_eq!(column_order(&create), ["e", "a", "bb", "x", "d"], "{create}");
    assert!(create.contains("KEY `idx_b` (`bb`)"), "{create}");
    assert!(create.contains("KEY `idx_bb_x` (`bb`,`x`(4))"), "{create}");
    assert!(create.contains("`bb` int DEFAULT NULL COMMENT '改名'"), "{create}");
    assert!(create.contains("`x` varchar(10) NOT NULL DEFAULT ''"), "{create}");

    drop(conn);
    pool.disconnect().await.ok();
}

/// 反斜杠和单引号在两种 sql_mode 下都要原样落库
#[tokio::test]
async fn string_literals_survive_both_sql_modes() {
    let Some(config) = config_from_env() else {
        return;
    };
    let database = config.database.clone().unwrap();
    let pool = open_pool(&config).await.unwrap();
    let mut conn = pool.get_conn().await.unwrap();

    for (index, no_backslash_escapes) in [false, true].into_iter().enumerate() {
        let table = format!("alter_tmp_mode{index}");
        let mode = if no_backslash_escapes {
            "SET SESSION sql_mode = CONCAT(@@SESSION.sql_mode, ',NO_BACKSLASH_ESCAPES')"
        } else {
            "SET SESSION sql_mode = REPLACE(@@SESSION.sql_mode, 'NO_BACKSLASH_ESCAPES', '')"
        };
        conn.query_drop(mode).await.unwrap();
        conn.query_drop(format!("CREATE TEMPORARY TABLE {table} (id INT NOT NULL PRIMARY KEY)")).await.unwrap();

        let mut id_column = simple_column("id", "int");
        id_column.nullable = false;
        id_column.default = DefaultValue::NoDefault;
        let original = TableStructure { columns: vec![id_column], indexes: vec![], foreign_keys: vec![], create_sql: String::new(), table_collation: None };
        let mut draft = table_draft(&original);
        draft.columns.push(new_column("s", "varchar(40)", true, DefaultValue::Literal("it's a\\b\\n".to_string()), "c\\d'e"));

        let (plan, _) = plan_alter(&database, &table, &original, &draft, no_backslash_escapes).unwrap();
        run_statements(&mut conn, &plan.statements).await.unwrap_or_else(|(_, err)| panic!("{err}\n{}", plan.statements[0]));

        conn.query_drop(format!("INSERT INTO {table} (id) VALUES (1)")).await.unwrap();
        let value: Option<String> = conn.query_first(format!("SELECT s FROM {table}")).await.unwrap();
        assert_eq!(value.as_deref(), Some("it's a\\b\\n"), "NO_BACKSLASH_ESCAPES={no_backslash_escapes}");

        let columns: Vec<mysql_async::Row> = conn.query(format!("SHOW FULL COLUMNS FROM {table}")).await.unwrap();
        let comment: String = columns[1].get("Comment").unwrap();
        assert_eq!(comment, "c\\d'e", "NO_BACKSLASH_ESCAPES={no_backslash_escapes}");
    }

    drop(conn);
    pool.disconnect().await.ok();
}
