//! 表结构：列定义、索引、外键、建表语句。结构查看、类型编辑器、补全都从这里取列信息。

use mysql_async::prelude::*;
use mysql_async::{Pool, Row};
use serde::{Deserialize, Serialize};

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
    /// 按顺序的列。前缀索引写成 `title(10)`，函数索引读不到列名时写成 `<表达式>`
    pub columns: Vec<String>,
    pub index_type: String,
    pub comment: String,
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

/// 一张表的完整结构。结构页一次要全部，合成一个接口返回
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TableStructure {
    pub columns: Vec<ColumnDef>,
    pub indexes: Vec<IndexDef>,
    pub foreign_keys: Vec<ForeignKeyDef>,
    /// SHOW CREATE 的原文。视图也能拿到（CREATE VIEW …）
    pub create_sql: String,
}

pub async fn table_structure(
    pool: &Pool,
    schema: &str,
    table: &str,
) -> Result<TableStructure, mysql_async::Error> {
    let columns = table_columns(pool, schema, table).await?;

    let mut conn = pool.get_conn().await?;
    let index_rows: Vec<(String, i64, Option<String>, Option<i64>, String, String)> = conn
        .exec(
            "SELECT INDEX_NAME, NON_UNIQUE, COLUMN_NAME, SUB_PART, INDEX_TYPE, INDEX_COMMENT \
             FROM information_schema.STATISTICS \
             WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? \
             ORDER BY INDEX_NAME = 'PRIMARY' DESC, INDEX_NAME, SEQ_IN_INDEX",
            (schema, table),
        )
        .await?;

    let mut indexes: Vec<IndexDef> = Vec::new();
    for (name, non_unique, column, sub_part, index_type, comment) in index_rows {
        // 函数索引（MySQL 8.0.13+）没有列名；表达式本身在建表语句里看
        let mut part = column.unwrap_or_else(|| "<表达式>".to_string());
        if let Some(length) = sub_part {
            part = format!("{part}({length})");
        }
        match indexes.last_mut() {
            Some(last) if last.name == name => last.columns.push(part),
            _ => indexes.push(IndexDef {
                name,
                unique: non_unique == 0,
                columns: vec![part],
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

    Ok(TableStructure { columns, indexes, foreign_keys, create_sql })
}

/// 一张表的列定义，按表里的顺序
pub async fn table_columns(
    pool: &Pool,
    schema: &str,
    table: &str,
) -> Result<Vec<ColumnDef>, mysql_async::Error> {
    let mut conn = pool.get_conn().await?;
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
    pool: &Pool,
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
