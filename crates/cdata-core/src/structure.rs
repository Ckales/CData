//! 表结构：列定义、索引、外键、建表语句。结构查看、类型编辑器、补全都从这里取列信息。

use mysql_async::prelude::*;
use mysql_async::{Conn, Row};
use serde::{Deserialize, Serialize};

use crate::db::DbPool;
use crate::sql::quote_ident;

/// 列的默认值。information_schema 里 COLUMN_DEFAULT 为 NULL 有两种意思，要结合可空性区分
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum DefaultValue {
    /// 没有默认值：NOT NULL 且没写 DEFAULT，插入时必须给值（或者是自增列）
    NoDefault,
    /// 默认 NULL
    Null,
    /// 字面量默认值，原样保留（不带引号）
    Literal(String),
    /// 表达式默认值，比如 CURRENT_TIMESTAMP
    Expression(String),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ColumnDef {
    pub name: String,
    /// 完整类型，比如 `decimal(12,2) unsigned`、`enum('draft','done')`
    pub column_type: String,
    pub nullable: bool,
    pub default: DefaultValue,
    /// auto_increment、on update CURRENT_TIMESTAMP、VIRTUAL GENERATED 之类
    pub extra: String,
    pub comment: String,
    /// 只有字符串列有
    pub collation: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct IndexDef {
    pub name: String,
    pub unique: bool,
    /// 按顺序的列，给人看的。前缀索引写成 `title(10)`，降序带 ` DESC`，函数索引写成 `<表达式>`
    pub columns: Vec<String>,
    /// 和 columns 一一对应的结构化信息，改索引时按它重建，不去解析上面的显示文本
    pub parts: Vec<IndexPart>,
    pub index_type: String,
    pub comment: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct IndexPart {
    /// 函数索引的这一段没有列名
    pub column: Option<String>,
    /// 前缀长度，`title(10)` 的 10
    pub prefix: Option<u32>,
    pub descending: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ForeignKeyDef {
    pub name: String,
    pub columns: Vec<String>,
    pub referenced_schema: String,
    pub referenced_table: String,
    pub referenced_columns: Vec<String>,
    pub on_update: String,
    pub on_delete: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CheckDef {
    pub name: String,
    /// information_schema 的 CHECK_CLAUSE 原文，只用来显示：里面的引号写成了 \'，不能照抄回 DDL
    pub expression: String,
    pub enforced: bool,
}

/// 一张表的完整结构。结构页一次要全部，合成一个接口返回
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TableStructure {
    pub columns: Vec<ColumnDef>,
    pub indexes: Vec<IndexDef>,
    pub foreign_keys: Vec<ForeignKeyDef>,
    /// SHOW CREATE 的原文。视图也能拿到（CREATE VIEW …）
    pub create_sql: String,
    /// 表的默认排序规则。列的排序规则和它相同时，改列不写 COLLATE，免得列变成「显式指定」。视图没有
    pub table_collation: Option<String>,
    pub table_charset: Option<String>,
    /// 引擎。视图没有
    pub engine: Option<String>,
    pub table_comment: String,
    /// 取自 SHOW CREATE 的 AUTO_INCREMENT=，只用来显示。information_schema 里那个有统计缓存，会过时
    pub auto_increment: Option<u64>,
    /// 显式指定的 ROW_FORMAT（CREATE_OPTIONS 里的），没指定是 None。
    /// TABLES.ROW_FORMAT 是实际生效的，不能拿来当「指定了」
    pub row_format: Option<String>,
    /// CHECK 约束。None 表示这个服务器读不了（MySQL 8.0.16 之前、MariaDB），不等于「没有」
    pub checks: Option<Vec<CheckDef>>,
}

/// 是不是 MySQL 并且不低于给定版本。MariaDB 一律 false：很多 information_schema 的规则和 MySQL 不同
pub fn mysql_at_least(version: &str, min: (u32, u32, u32)) -> bool {
    if version.to_ascii_lowercase().contains("mariadb") {
        return false;
    }
    let numbers: Vec<u32> = version
        .split(|c: char| !c.is_ascii_digit())
        .take(3)
        .map(|part| part.parse().unwrap_or(0))
        .collect();
    let [major, minor, patch] = numbers[..] else {
        return false;
    };
    (major, minor, patch) >= min
}

pub async fn table_structure(
    pool: &DbPool,
    schema: &str,
    table: &str,
) -> Result<TableStructure, mysql_async::Error> {
    let mut conn = pool.get_conn().await?;
    read_structure(&mut conn, schema, table).await
}

/// 在给定连接上读结构。改结构时读结构、查 sql_mode、执行 ALTER 要在同一条连接上
pub async fn read_structure(
    conn: &mut Conn,
    schema: &str,
    table: &str,
) -> Result<TableStructure, mysql_async::Error> {
    let columns = read_columns(conn, schema, table).await?;

    // COLLATION 是 A / D / NULL：D 是降序（MySQL 8），重建索引时不能丢
    let index_rows: Vec<(String, i64, Option<String>, Option<i64>, Option<String>, String, String)> = conn
        .exec(
            "SELECT INDEX_NAME, NON_UNIQUE, COLUMN_NAME, SUB_PART, COLLATION, INDEX_TYPE, INDEX_COMMENT \
             FROM information_schema.STATISTICS \
             WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? \
             ORDER BY INDEX_NAME = 'PRIMARY' DESC, INDEX_NAME, SEQ_IN_INDEX",
            (schema, table),
        )
        .await?;

    let mut indexes: Vec<IndexDef> = Vec::new();
    for (name, non_unique, column, sub_part, collation, index_type, comment) in index_rows {
        let part = IndexPart {
            column,
            prefix: sub_part.map(|length| length as u32),
            descending: collation.as_deref() == Some("D"),
        };
        // 函数索引（MySQL 8.0.13+）没有列名；表达式本身在建表语句里看
        let mut label = part.column.clone().unwrap_or_else(|| "<表达式>".to_string());
        if let Some(length) = part.prefix {
            label = format!("{label}({length})");
        }
        if part.descending {
            label.push_str(" DESC");
        }
        match indexes.last_mut() {
            Some(last) if last.name == name => {
                last.columns.push(label);
                last.parts.push(part);
            }
            _ => indexes.push(IndexDef {
                name,
                unique: non_unique == 0,
                columns: vec![label],
                parts: vec![part],
                index_type,
                comment,
            }),
        }
    }

    let fk_rows: Vec<(String, String, String, String, String, String, String)> = conn
        .exec(
            "SELECT k.CONSTRAINT_NAME, k.COLUMN_NAME, k.REFERENCED_TABLE_SCHEMA, \
                    k.REFERENCED_TABLE_NAME, k.REFERENCED_COLUMN_NAME, r.UPDATE_RULE, r.DELETE_RULE \
             FROM information_schema.KEY_COLUMN_USAGE k \
             JOIN information_schema.REFERENTIAL_CONSTRAINTS r \
               ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA \
              AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME \
              AND r.TABLE_NAME = k.TABLE_NAME \
             WHERE k.TABLE_SCHEMA = ? AND k.TABLE_NAME = ? AND k.REFERENCED_TABLE_NAME IS NOT NULL \
             ORDER BY k.CONSTRAINT_NAME, k.ORDINAL_POSITION",
            (schema, table),
        )
        .await?;

    let mut foreign_keys: Vec<ForeignKeyDef> = Vec::new();
    for (name, column, ref_schema, ref_table, ref_column, on_update, on_delete) in fk_rows {
        match foreign_keys.last_mut() {
            Some(last) if last.name == name => {
                last.columns.push(column);
                last.referenced_columns.push(ref_column);
            }
            _ => foreign_keys.push(ForeignKeyDef {
                name,
                columns: vec![column],
                referenced_schema: ref_schema,
                referenced_table: ref_table,
                referenced_columns: vec![ref_column],
                on_update,
                on_delete,
            }),
        }
    }

    // 表返回 (Table, Create Table)，视图返回 (View, Create View, …)，建表语句都在第 2 列
    let create_row: Option<Row> = conn
        .query_first(format!("SHOW CREATE TABLE {}.{}", quote_ident(schema), quote_ident(table)))
        .await?;
    let create_sql = create_row
        .and_then(|row| row.get::<String, usize>(1))
        .unwrap_or_default();

    type TableRow = (Option<String>, Option<String>, Option<String>, Option<String>, Option<String>);
    let table_row: Option<TableRow> = conn
        .exec_first(
            "SELECT t.TABLE_COLLATION, c.CHARACTER_SET_NAME, t.ENGINE, t.TABLE_COMMENT, t.CREATE_OPTIONS \
             FROM information_schema.TABLES t \
             LEFT JOIN information_schema.COLLATIONS c ON c.COLLATION_NAME = t.TABLE_COLLATION \
             WHERE t.TABLE_SCHEMA = ? AND t.TABLE_NAME = ?",
            (schema, table),
        )
        .await?;
    let (table_collation, table_charset, engine, table_comment, create_options) = table_row.unwrap_or_default();

    // CHECK_CONSTRAINTS 是 8.0.16 才有的；MariaDB 也有这张表，但 TABLE_CONSTRAINTS 没有 ENFORCED 列
    let version: String = conn.query_first("SELECT VERSION()").await?.unwrap_or_default();
    let checks = if mysql_at_least(&version, (8, 0, 16)) {
        let rows: Vec<(String, String, String)> = conn
            .exec(
                "SELECT tc.CONSTRAINT_NAME, cc.CHECK_CLAUSE, tc.ENFORCED \
                 FROM information_schema.TABLE_CONSTRAINTS tc \
                 JOIN information_schema.CHECK_CONSTRAINTS cc \
                   ON cc.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA AND cc.CONSTRAINT_NAME = tc.CONSTRAINT_NAME \
                 WHERE tc.TABLE_SCHEMA = ? AND tc.TABLE_NAME = ? AND tc.CONSTRAINT_TYPE = 'CHECK' \
                 ORDER BY tc.CONSTRAINT_NAME",
                (schema, table),
            )
            .await?;
        let mut checks = Vec::with_capacity(rows.len());
        for (name, expression, enforced) in rows {
            checks.push(CheckDef { name, expression, enforced: enforced == "YES" });
        }
        Some(checks)
    } else {
        None
    };

    Ok(TableStructure {
        columns,
        indexes,
        foreign_keys,
        auto_increment: create_auto_increment(&create_sql),
        create_sql,
        table_collation,
        table_charset,
        engine,
        table_comment: table_comment.unwrap_or_default(),
        row_format: explicit_row_format(create_options.as_deref().unwrap_or("")),
        checks,
    })
}

/// CREATE_OPTIONS 形如 `row_format=DYNAMIC stats_persistent=0`
fn explicit_row_format(create_options: &str) -> Option<String> {
    for option in create_options.split_whitespace() {
        if let Some(value) = option.strip_prefix("row_format=") {
            return Some(value.to_string());
        }
    }
    None
}

/// SHOW CREATE 的表选项行 `) ENGINE=InnoDB AUTO_INCREMENT=100 DEFAULT CHARSET=… COMMENT='…'`。
/// 只看 COMMENT= 之前的部分，免得表注释里的字被当成选项
fn create_auto_increment(create_sql: &str) -> Option<u64> {
    let line = create_sql.lines().find(|line| line.starts_with(") ENGINE="))?;
    let options = line.split(" COMMENT=").next().unwrap_or(line);
    let rest = options.split(" AUTO_INCREMENT=").nth(1)?;
    let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    digits.parse().ok()
}

/// 一张表的列定义，按表里的顺序
pub async fn table_columns(
    pool: &DbPool,
    schema: &str,
    table: &str,
) -> Result<Vec<ColumnDef>, mysql_async::Error> {
    let mut conn = pool.get_conn().await?;
    read_columns(&mut conn, schema, table).await
}

async fn read_columns(conn: &mut Conn, schema: &str, table: &str) -> Result<Vec<ColumnDef>, mysql_async::Error> {
    let rows: Vec<Row> = conn
        .exec(
            "SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, EXTRA, \
                    COLUMN_COMMENT, COLLATION_NAME \
             FROM information_schema.COLUMNS \
             WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? ORDER BY ORDINAL_POSITION",
            (schema, table),
        )
        .await?;

    let mut columns = Vec::with_capacity(rows.len());
    for row in rows {
        let (name, column_type, is_nullable, default, extra, comment, collation): (
            String,
            String,
            String,
            Option<String>,
            String,
            String,
            Option<String>,
        ) = mysql_async::from_row(row);

        let nullable = is_nullable == "YES";
        columns.push(ColumnDef {
            name,
            column_type,
            nullable,
            default: classify_default(default, nullable, &extra),
            extra,
            comment,
            collation,
        });
    }
    Ok(columns)
}

/// COLUMN_DEFAULT 为 NULL 时：可空列是「默认 NULL」，不可空列是「没有默认值」。
/// MySQL 8 的表达式默认值在 EXTRA 里带 DEFAULT_GENERATED
fn classify_default(default: Option<String>, nullable: bool, extra: &str) -> DefaultValue {
    match default {
        Some(value) if extra.contains("DEFAULT_GENERATED") => DefaultValue::Expression(value),
        Some(value) => DefaultValue::Literal(value),
        None if nullable => DefaultValue::Null,
        None => DefaultValue::NoDefault,
    }
}

/// 从 `enum('a','b')` / `set('x','y')` 里取出可选值。值里的单引号在 COLUMN_TYPE 中写成 ''
pub fn parse_choices(column_type: &str) -> Option<Vec<String>> {
    let lower = column_type.to_ascii_lowercase();
    let body = if lower.starts_with("enum(") {
        &column_type[5..]
    } else if lower.starts_with("set(") {
        &column_type[4..]
    } else {
        return None;
    };
    let body = body.strip_suffix(')')?;

    let mut choices = Vec::new();
    let mut chars = body.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch != '\'' {
            continue; // 值之间的逗号
        }
        let mut value = String::new();
        loop {
            match chars.next()? {
                '\'' if chars.peek() == Some(&'\'') => {
                    chars.next();
                    value.push('\'');
                }
                '\'' => break,
                other => value.push(other),
            }
        }
        choices.push(value);
    }
    Some(choices)
}

/// 某张表某一列的 ENUM / SET 可选值。不是这两种类型就是 None
pub async fn column_choices(
    pool: &DbPool,
    schema: &str,
    table: &str,
    column: &str,
) -> Result<Option<Vec<String>>, mysql_async::Error> {
    let mut conn = pool.get_conn().await?;
    let column_type: Option<String> = conn
        .exec_first(
            "SELECT COLUMN_TYPE FROM information_schema.COLUMNS \
             WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? AND COLUMN_NAME = ?",
            (schema, table, column),
        )
        .await?;
    Ok(column_type.and_then(|t| parse_choices(&t)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_enum_and_set_choices_with_quotes_and_commas() {
        assert_eq!(
            parse_choices("enum('draft','it''s','a,b')"),
            Some(vec!["draft".to_string(), "it's".to_string(), "a,b".to_string()])
        );
        assert_eq!(parse_choices("set('x','y')"), Some(vec!["x".to_string(), "y".to_string()]));
        assert_eq!(parse_choices("varchar(20)"), None);
    }

    #[test]
    fn table_options_come_from_the_right_places() {
        assert_eq!(explicit_row_format("row_format=DYNAMIC stats_persistent=0"), Some("DYNAMIC".to_string()));
        assert_eq!(explicit_row_format(""), None);
        let create = "CREATE TABLE `t` (\n  `id` int NOT NULL AUTO_INCREMENT\n) ENGINE=InnoDB AUTO_INCREMENT=100 DEFAULT CHARSET=utf8mb4 COMMENT='x AUTO_INCREMENT=5'";
        assert_eq!(create_auto_increment(create), Some(100));
        let no_counter = "CREATE TABLE `t` (\n  `id` int\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT=' AUTO_INCREMENT=5'";
        assert_eq!(create_auto_increment(no_counter), None, "注释里的字不能当成选项");
    }

    #[test]
    fn version_gate() {
        assert!(mysql_at_least("8.0.16", (8, 0, 16)));
        assert!(mysql_at_least("9.6.0", (8, 0, 16)));
        assert!(!mysql_at_least("8.0.15-log", (8, 0, 16)));
        assert!(!mysql_at_least("10.11.6-MariaDB", (8, 0, 16)));
        assert!(!mysql_at_least("garbage", (8, 0, 16)));
    }

    #[test]
    fn missing_default_depends_on_nullability() {
        assert_eq!(classify_default(None, true, ""), DefaultValue::Null);
        assert_eq!(classify_default(None, false, "auto_increment"), DefaultValue::NoDefault);
    }

    #[test]
    fn literal_and_expression_defaults_are_told_apart() {
        assert_eq!(
            classify_default(Some("draft".into()), false, ""),
            DefaultValue::Literal("draft".into())
        );
        // 空字符串默认值是字面量，不能当成「没有默认值」
        assert_eq!(classify_default(Some(String::new()), false, ""), DefaultValue::Literal(String::new()));
        assert_eq!(
            classify_default(Some("CURRENT_TIMESTAMP".into()), false, "DEFAULT_GENERATED"),
            DefaultValue::Expression("CURRENT_TIMESTAMP".into())
        );
    }
}
