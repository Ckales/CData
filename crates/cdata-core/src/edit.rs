//! 单元格写回：能不能编辑、怎么定位那一行、生成什么 SQL。
//!
//! 这里最重要的规则是**拿不准就拒绝**。没有可靠的唯一定位键、结果来自多张表、定位列没查出来，
//! 一律禁止编辑并说明原因。猜一个「看起来能用」的 WHERE 条件可能改掉成千上万行。

use mysql_async::prelude::*;
use mysql_async::Value;
use serde::{Deserialize, Serialize};

use crate::db::{ColumnMeta, DbPool};
use crate::sql::{quote_ident, Statement};
use crate::value::{value_to_mysql, CellValue};

/// 结果集的可编辑性。不可编辑时带上原因，界面要显示出来而不是灰掉了事
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum Editability {
    Editable(EditTarget),
    ReadOnly(String),
}

/// 编辑时用什么定位一行
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EditTarget {
    pub schema: String,
    pub table: String,
    /// 主键或非空唯一索引列在结果集里的下标，按索引顺序排列
    pub key_indexes: Vec<usize>,
}

/// 判断结果集能不能编辑。
///
/// 只支持单表查询：所有列都来自同一张实体表，且定位索引列全在结果集里。
/// JOIN、聚合、表达式列一律只读——它们没有可靠的回写目标。
pub async fn detect_editability(pool: &DbPool, columns: &[ColumnMeta]) -> Editability {
    if columns.is_empty() {
        return Editability::ReadOnly("结果集没有列".to_string());
    }

    let (schema, table) = match single_source_table(columns) {
        Ok(pair) => pair,
        Err(reason) => return Editability::ReadOnly(reason),
    };

    let indexes = match unique_index_columns(pool, &schema, &table).await {
        Ok(indexes) => indexes,
        Err(err) => return Editability::ReadOnly(format!("读取定位索引失败：{err}")),
    };
    let key_indexes = match select_key_indexes(columns, &indexes) {
        Ok(indexes) => indexes,
        Err(reason) => return Editability::ReadOnly(format!("表 {table}：{reason}")),
    };

    Editability::Editable(EditTarget {
        schema,
        table,
        key_indexes,
    })
}

/// 所有列必须来自同一张实体表
pub(crate) fn single_source_table(columns: &[ColumnMeta]) -> Result<(String, String), String> {
    let mut source: Option<(String, String)> = None;

    for column in columns {
        if column.org_table.is_empty() {
            return Err(format!(
                "列 {} 不是直接来自某张表（表达式或聚合结果），整个结果集只读",
                column.name
            ));
        }

        let current = (column.schema.clone(), column.org_table.clone());
        match &source {
            None => source = Some(current),
            Some(first) if first == &current => {}
            Some(first) => {
                return Err(format!(
                    "结果集来自多张表（{} 和 {}），不能编辑",
                    first.1, current.1
                ))
            }
        }
    }

    source.ok_or_else(|| "结果集没有可写的来源表".to_string())
}

// (索引名, 原始列名；表达式索引为 None, 是否允许 NULL)
type IndexColumn = (String, Option<String>, String);

async fn unique_index_columns(
    pool: &DbPool,
    schema: &str,
    table: &str,
) -> Result<Vec<IndexColumn>, mysql_async::Error> {
    let mut conn = pool.get_conn().await?;
    conn.exec(
        "SELECT INDEX_NAME, COLUMN_NAME, NULLABLE FROM information_schema.STATISTICS \
         WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? AND NON_UNIQUE = 0 \
         ORDER BY INDEX_NAME, SEQ_IN_INDEX",
        (schema, table),
    )
    .await
}

fn select_key_indexes(columns: &[ColumnMeta], rows: &[IndexColumn]) -> Result<Vec<usize>, String> {
    let mut indexes = std::collections::BTreeMap::<&str, Vec<&IndexColumn>>::new();
    for row in rows {
        indexes.entry(&row.0).or_default().push(row);
    }
    // 有主键时继续使用主键；仅在无主键时选用其他唯一索引。
    let candidates: Vec<_> = match indexes.get("PRIMARY") {
        Some(primary) => {
            for row in primary {
                if let Some(key) = &row.1 {
                    if !columns.iter().any(|column| &column.org_name == key) {
                        return Err(format!(
                            "查询结果里没有主键列 {key}，无法定位行。把它加进 SELECT 才能编辑"
                        ));
                    }
                }
            }
            vec![primary]
        }
        None => indexes.values().collect(),
    };
    for index in candidates {
        // 可空 UNIQUE 允许多个 NULL，表达式索引也无法由原始列直接定位。
        if index.iter().any(|row| row.1.is_none() || !row.2.is_empty()) {
            continue;
        }
        let positions: Option<Vec<usize>> = index
            .iter()
            .map(|row| {
                columns
                    .iter()
                    .position(|column| Some(&column.org_name) == row.1.as_ref())
            })
            .collect();
        if let Some(positions) = positions {
            return Ok(positions);
        }
    }
    Err(
        "没有可用的完整非空唯一定位键，不能编辑；需要主键或非空唯一索引，且其所有列都在查询结果中"
            .to_string(),
    )
}

/// 主键列是不是自增。插入时没填主键，只有自增列才能靠 LAST_INSERT_ID 找回这一行
pub async fn is_auto_increment(
    pool: &DbPool,
    schema: &str,
    table: &str,
    column: &str,
) -> Result<bool, mysql_async::Error> {
    let mut conn = pool.get_conn().await?;
    let extra: Option<String> = conn
        .exec_first(
            "SELECT EXTRA FROM information_schema.COLUMNS \
             WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? AND COLUMN_NAME = ?",
            (schema, table, column),
        )
        .await?;
    Ok(extra.is_some_and(|extra| extra.contains("auto_increment")))
}

/// 生成改一个单元格的 UPDATE。
///
/// 加 `LIMIT 1` 是最后一道保险：定位键由唯一索引保证唯一，真出现重复时也只会动一行。
pub fn build_update(
    target: &EditTarget,
    columns: &[ColumnMeta],
    row: &[CellValue],
    column_index: usize,
    new_value: &CellValue,
) -> Result<Statement, String> {
    build_row_update(target, columns, row, &[(column_index, new_value.clone())])
        .map(|(statement, _)| statement)
}

/// 使用旧定位键更新整行中的多列，并返回按新键重读所需的定位值。
/// 同一行的定位列与普通列一次写入，避免中间键值导致后续 UPDATE 找不到行。
pub(crate) fn build_row_update(
    target: &EditTarget,
    columns: &[ColumnMeta],
    row: &[CellValue],
    changes: &[(usize, CellValue)],
) -> Result<(Statement, Vec<CellValue>), String> {
    if changes.is_empty() {
        return Err("没有要更新的列".to_string());
    }
    let (conditions, key_params) = key_conditions(target, columns, row)?;
    let mut assignments = Vec::with_capacity(changes.len());
    let mut assigned_columns: Vec<&str> = Vec::with_capacity(changes.len());
    let mut params = Vec::with_capacity(changes.len() + key_params.len());
    let mut locator = row.to_vec();
    for (column_index, value) in changes {
        let column = columns
            .get(*column_index)
            .ok_or_else(|| format!("列下标 {column_index} 越界"))?;
        // 重复投影同一物理列时，按粘贴顺序以最后一个值为准，只生成一个 SET。
        if let Some(position) = assigned_columns
            .iter()
            .position(|name| *name == column.org_name)
        {
            params[position] = value_to_mysql(value);
        } else {
            assigned_columns.push(&column.org_name);
            assignments.push(format!("{} = ?", quote_ident(&column.org_name)));
            params.push(value_to_mysql(value));
        }
        // SELECT 可能多次投影同一个原始列，定位值也要同步更新。
        for (index, candidate) in columns.iter().enumerate() {
            if candidate.org_name == column.org_name {
                *locator
                    .get_mut(index)
                    .ok_or_else(|| format!("这一行缺少列 {}", column.name))? = value.clone();
            }
        }
    }
    params.extend(key_params);
    let sql = format!(
        "UPDATE {} SET {} WHERE {} LIMIT 1",
        table_ident(target),
        assignments.join(", "),
        conditions,
    );
    Ok((Statement { sql, params }, locator))
}

/// 生成删一行的 DELETE。和 UPDATE 一样按定位键定位、带 LIMIT 1
pub fn build_delete(
    target: &EditTarget,
    columns: &[ColumnMeta],
    row: &[CellValue],
) -> Result<Statement, String> {
    let (conditions, params) = key_conditions(target, columns, row)?;
    let sql = format!(
        "DELETE FROM {} WHERE {} LIMIT 1",
        table_ident(target),
        conditions
    );
    Ok(Statement { sql, params })
}

/// 生成插一行的 INSERT。
///
/// `values[i]` 为 None 表示这一列不写，交给表的 DEFAULT / AUTO_INCREMENT；
/// 这和 `Some(CellValue::Null)` 是两回事，后者是明确写入 NULL。
pub fn build_insert(
    target: &EditTarget,
    columns: &[ColumnMeta],
    values: &[Option<CellValue>],
) -> Result<Statement, String> {
    if values.len() != columns.len() {
        return Err(format!(
            "新行有 {} 个值，结果集有 {} 列，对不上",
            values.len(),
            columns.len()
        ));
    }

    let mut names = Vec::new();
    let mut params = Vec::new();
    for (column, value) in columns.iter().zip(values) {
        if let Some(value) = value {
            names.push(quote_ident(&column.org_name));
            params.push(value_to_mysql(value));
        }
    }

    let placeholders = vec!["?"; names.len()].join(", ");
    let sql = format!(
        "INSERT INTO {} ({}) VALUES ({})",
        table_ident(target),
        names.join(", "),
        placeholders,
    );

    Ok(Statement { sql, params })
}

/// 按定位键把一行读回来，列和结果集一一对应。
///
/// 插入后要用它拿到真实存储的值：DEFAULT、自增、MySQL 的类型转换都只有读回来才知道，
/// 拿用户填的值直接塞进缓存就是在显示「假正确」的数据。
pub fn build_select_by_key(
    target: &EditTarget,
    columns: &[ColumnMeta],
    row: &[CellValue],
) -> Result<Statement, String> {
    let (conditions, params) = key_conditions(target, columns, row)?;

    let mut names = Vec::with_capacity(columns.len());
    for column in columns {
        names.push(quote_ident(&column.org_name));
    }

    let sql = format!(
        "SELECT {} FROM {} WHERE {} LIMIT 1",
        names.join(", "),
        table_ident(target),
        conditions,
    );
    Ok(Statement { sql, params })
}

/// 按定位键定位一行的 WHERE 条件和参数
fn key_conditions(
    target: &EditTarget,
    columns: &[ColumnMeta],
    row: &[CellValue],
) -> Result<(String, Vec<Value>), String> {
    let mut conditions = Vec::with_capacity(target.key_indexes.len());
    let mut params = Vec::with_capacity(target.key_indexes.len());

    for &key_index in &target.key_indexes {
        let key_column = columns
            .get(key_index)
            .ok_or_else(|| format!("定位列下标 {key_index} 越界"))?;
        let key_value = row
            .get(key_index)
            .ok_or_else(|| format!("这一行缺少定位列 {}", key_column.name))?;

        // 定位列为 NULL 说明这行数据本身就不对，不能拿它当定位条件
        if key_value == &CellValue::Null {
            return Err(format!(
                "定位列 {} 是 NULL，无法定位这一行",
                key_column.name
            ));
        }

        conditions.push(format!("{} = ?", quote_ident(&key_column.org_name)));
        params.push(value_to_mysql(key_value));
    }

    Ok((conditions.join(" AND "), params))
}

fn table_ident(target: &EditTarget) -> String {
    format!(
        "{}.{}",
        quote_ident(&target.schema),
        quote_ident(&target.table)
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn column(name: &str, table: &str) -> ColumnMeta {
        ColumnMeta {
            name: name.to_string(),
            org_name: name.to_string(),
            org_table: table.to_string(),
            schema: "shop".to_string(),
            is_binary: false,
            kind: crate::db::ColumnKind::Text,
            decimals: 0,
        }
    }

    fn target() -> EditTarget {
        EditTarget {
            schema: "shop".to_string(),
            table: "orders".to_string(),
            key_indexes: vec![0],
        }
    }

    fn index(name: &str, column: &str, nullable: bool) -> IndexColumn {
        (
            name.into(),
            Some(column.into()),
            if nullable { "YES" } else { "" }.into(),
        )
    }

    #[test]
    fn app_strings_unique_key_locates_update_delete_and_refresh() {
        let columns = vec![
            column("svalue", "sp_app_strings"),
            column("lanid", "sp_app_strings"),
            column("skey", "sp_app_strings"),
        ];
        let indexes = vec![index("skey", "skey", false), index("skey", "lanid", false)];
        let target = EditTarget {
            schema: "sportkeep".into(),
            table: "sp_app_strings".into(),
            key_indexes: select_key_indexes(&columns, &indexes).unwrap(),
        };
        assert_eq!(target.key_indexes, vec![2, 1]);
        let row = vec![
            CellValue::Text("old".into()),
            CellValue::UInt(11),
            CellValue::Text("100_for_trouble_zone".into()),
        ];
        let update = build_update(&target, &columns, &row, 0, &CellValue::Text("".into())).unwrap();
        assert_eq!(update.sql, "UPDATE `sportkeep`.`sp_app_strings` SET `svalue` = ? WHERE `skey` = ? AND `lanid` = ? LIMIT 1");
        assert_eq!(
            update.params,
            vec![
                Value::Bytes(vec![]),
                Value::Bytes(b"100_for_trouble_zone".to_vec()),
                Value::UInt(11)
            ]
        );
        assert!(build_delete(&target, &columns, &row)
            .unwrap()
            .sql
            .contains("WHERE `skey` = ? AND `lanid` = ? LIMIT 1"));
        assert!(build_select_by_key(&target, &columns, &row)
            .unwrap()
            .sql
            .contains("WHERE `skey` = ? AND `lanid` = ? LIMIT 1"));
        let (statement, locator) =
            build_row_update(&target, &columns, &row, &[(1, CellValue::UInt(12))]).unwrap();
        assert_eq!(
            statement.params,
            vec![
                Value::UInt(12),
                Value::Bytes(b"100_for_trouble_zone".to_vec()),
                Value::UInt(11)
            ]
        );
        assert_eq!(
            build_select_by_key(&target, &columns, &locator)
                .unwrap()
                .params,
            vec![
                Value::Bytes(b"100_for_trouble_zone".to_vec()),
                Value::UInt(12)
            ]
        );
    }

    #[test]
    fn primary_key_remains_preferred() {
        let columns = vec![column("id", "t"), column("code", "t")];
        let indexes = vec![index("PRIMARY", "id", false), index("code", "code", false)];
        assert_eq!(select_key_indexes(&columns, &indexes).unwrap(), vec![0]);
        assert!(select_key_indexes(&columns[1..], &indexes)
            .unwrap_err()
            .contains("没有主键列 id"));
    }

    #[test]
    fn unique_key_must_be_non_nullable_direct_columns_and_complete() {
        let columns = vec![column("code", "t")];
        assert!(select_key_indexes(&columns, &[]).is_err());
        assert!(select_key_indexes(&columns, &[index("code", "code", true)]).is_err());
        assert!(select_key_indexes(&columns, &[("expr".into(), None, "".into())]).is_err());
        assert!(select_key_indexes(
            &columns,
            &[
                index("pair", "code", false),
                index("pair", "missing", false)
            ]
        )
        .is_err());
    }

    #[test]
    fn selects_another_complete_unique_index_when_first_is_unusable() {
        let mut code = column("code", "t");
        code.name = "alias".into();
        let indexes = vec![
            index("a", "missing", false),
            index("b", "code", true),
            index("c", "code", false),
        ];
        assert_eq!(select_key_indexes(&[code], &indexes).unwrap(), vec![0]);
    }

    #[test]
    fn single_table_is_accepted() {
        let columns = vec![column("id", "orders"), column("amount", "orders")];
        assert_eq!(
            single_source_table(&columns),
            Ok(("shop".to_string(), "orders".to_string()))
        );
    }

    #[test]
    fn join_is_rejected_with_a_reason() {
        let columns = vec![column("id", "orders"), column("name", "users")];
        let err = single_source_table(&columns).unwrap_err();
        assert!(err.contains("多张表"), "原因要说清楚：{err}");
    }

    #[test]
    fn expression_column_is_rejected() {
        let columns = vec![column("id", "orders"), column("total", "")];
        let err = single_source_table(&columns).unwrap_err();
        assert!(err.contains("表达式"), "原因要说清楚：{err}");
    }

    #[test]
    fn update_uses_primary_key_and_parameters() {
        let columns = vec![column("id", "orders"), column("amount", "orders")];
        let row = vec![CellValue::Int(42), CellValue::Text("1.00".into())];

        let stmt = build_update(
            &target(),
            &columns,
            &row,
            1,
            &CellValue::Text("9.99".into()),
        )
        .expect("应该能生成");

        assert_eq!(
            stmt.sql,
            "UPDATE `shop`.`orders` SET `amount` = ? WHERE `id` = ? LIMIT 1"
        );
        // 值走参数，绝不拼进 SQL
        assert_eq!(
            stmt.params,
            vec![Value::Bytes(b"9.99".to_vec()), Value::Int(42)]
        );
    }

    #[test]
    fn null_primary_key_refuses_to_locate_the_row() {
        let columns = vec![column("id", "orders"), column("amount", "orders")];
        let row = vec![CellValue::Null, CellValue::Text("1.00".into())];

        let err = build_update(
            &target(),
            &columns,
            &row,
            1,
            &CellValue::Text("9.99".into()),
        )
        .unwrap_err();
        assert!(err.contains("NULL"), "原因要说清楚：{err}");
    }

    #[test]
    fn editing_primary_key_uses_old_key_and_rereads_new_key() {
        let columns = vec![column("id", "orders"), column("amount", "orders")];
        let row = vec![CellValue::Int(42), CellValue::Text("1.00".into())];

        let (statement, locator) =
            build_row_update(&target(), &columns, &row, &[(0, CellValue::Int(43))]).unwrap();
        assert_eq!(
            statement.sql,
            "UPDATE `shop`.`orders` SET `id` = ? WHERE `id` = ? LIMIT 1"
        );
        assert_eq!(statement.params, vec![Value::Int(43), Value::Int(42)]);
        assert_eq!(
            build_select_by_key(&target(), &columns, &locator)
                .unwrap()
                .params,
            vec![Value::Int(43)]
        );
    }

    #[test]
    fn row_update_changes_composite_key_and_payload_atomically() {
        let columns = vec![
            column("a", "orders"),
            column("b", "orders"),
            column("amount", "orders"),
        ];
        let target = EditTarget {
            key_indexes: vec![0, 1],
            ..target()
        };
        let row = vec![
            CellValue::Int(1),
            CellValue::Int(2),
            CellValue::Text("old".into()),
        ];
        let changes = vec![
            (0, CellValue::Int(3)),
            (1, CellValue::Int(4)),
            (2, CellValue::Text("new".into())),
        ];
        let (statement, locator) = build_row_update(&target, &columns, &row, &changes).unwrap();
        assert_eq!(statement.sql, "UPDATE `shop`.`orders` SET `a` = ?, `b` = ?, `amount` = ? WHERE `a` = ? AND `b` = ? LIMIT 1");
        assert_eq!(
            statement.params,
            vec![
                Value::Int(3),
                Value::Int(4),
                Value::Bytes(b"new".to_vec()),
                Value::Int(1),
                Value::Int(2)
            ]
        );
        assert_eq!(
            build_select_by_key(&target, &columns, &locator)
                .unwrap()
                .params,
            vec![Value::Int(3), Value::Int(4)]
        );
    }

    #[test]
    fn editing_an_aliased_duplicate_key_updates_the_locator() {
        let mut alias = column("id", "orders");
        alias.name = "alias".into();
        let columns = vec![column("id", "orders"), alias];
        let row = vec![CellValue::Int(1), CellValue::Int(1)];
        let (_, locator) =
            build_row_update(&target(), &columns, &row, &[(1, CellValue::Int(2))]).unwrap();
        assert_eq!(
            build_select_by_key(&target(), &columns, &locator)
                .unwrap()
                .params,
            vec![Value::Int(2)]
        );
    }

    #[test]
    fn duplicate_projections_write_one_assignment_with_the_final_value() {
        let columns = vec![column("id", "orders"), column("id", "orders")];
        let row = vec![CellValue::Int(1), CellValue::Int(1)];
        let (statement, locator) = build_row_update(
            &target(),
            &columns,
            &row,
            &[(0, CellValue::Int(2)), (1, CellValue::Int(3))],
        )
        .unwrap();
        assert_eq!(
            statement.sql,
            "UPDATE `shop`.`orders` SET `id` = ? WHERE `id` = ? LIMIT 1"
        );
        assert_eq!(statement.params, vec![Value::Int(3), Value::Int(1)]);
        assert_eq!(locator, vec![CellValue::Int(3), CellValue::Int(3)]);
    }

    #[test]
    fn composite_key_builds_all_conditions() {
        let columns = vec![
            column("shop_id", "orders"),
            column("order_no", "orders"),
            column("amount", "orders"),
        ];
        let row = vec![
            CellValue::Int(7),
            CellValue::Text("A-1".into()),
            CellValue::Text("1.00".into()),
        ];
        let multi_target = EditTarget {
            schema: "shop".to_string(),
            table: "orders".to_string(),
            key_indexes: vec![0, 1],
        };

        let stmt = build_update(
            &multi_target,
            &columns,
            &row,
            2,
            &CellValue::Text("2.00".into()),
        )
        .expect("应该能生成");

        assert_eq!(
            stmt.sql,
            "UPDATE `shop`.`orders` SET `amount` = ? WHERE `shop_id` = ? AND `order_no` = ? LIMIT 1"
        );
        assert_eq!(stmt.params.len(), 3);
    }

    #[test]
    fn delete_locates_by_primary_key() {
        let columns = vec![column("id", "orders"), column("amount", "orders")];
        let row = vec![CellValue::Int(42), CellValue::Text("1.00".into())];

        let stmt = build_delete(&target(), &columns, &row).expect("应该能生成");
        assert_eq!(
            stmt.sql,
            "DELETE FROM `shop`.`orders` WHERE `id` = ? LIMIT 1"
        );
        assert_eq!(stmt.params, vec![Value::Int(42)]);
    }

    #[test]
    fn delete_refuses_null_primary_key() {
        let columns = vec![column("id", "orders"), column("amount", "orders")];
        let row = vec![CellValue::Null, CellValue::Text("1.00".into())];
        assert!(build_delete(&target(), &columns, &row)
            .unwrap_err()
            .contains("NULL"));
    }

    #[test]
    fn insert_skips_default_columns_but_keeps_explicit_null() {
        let columns = vec![
            column("id", "orders"),
            column("amount", "orders"),
            column("note", "orders"),
        ];
        // id 交给自增，amount 写值，note 明确写 NULL —— 不写和写 NULL 不能混为一谈
        let values = vec![
            None,
            Some(CellValue::Text("9.99".into())),
            Some(CellValue::Null),
        ];

        let stmt = build_insert(&target(), &columns, &values).expect("应该能生成");
        assert_eq!(
            stmt.sql,
            "INSERT INTO `shop`.`orders` (`amount`, `note`) VALUES (?, ?)"
        );
        assert_eq!(
            stmt.params,
            vec![Value::Bytes(b"9.99".to_vec()), Value::NULL]
        );
    }

    #[test]
    fn insert_with_all_defaults_is_valid_sql() {
        let columns = vec![column("id", "orders"), column("amount", "orders")];
        let stmt = build_insert(&target(), &columns, &[None, None]).expect("应该能生成");
        assert_eq!(stmt.sql, "INSERT INTO `shop`.`orders` () VALUES ()");
        assert!(stmt.params.is_empty());
    }

    #[test]
    fn insert_refuses_mismatched_value_count() {
        let columns = vec![column("id", "orders"), column("amount", "orders")];
        assert!(build_insert(&target(), &columns, &[None])
            .unwrap_err()
            .contains("对不上"));
    }

    #[test]
    fn select_by_key_uses_original_column_names() {
        let mut aliased = column("amount", "orders");
        aliased.name = "total".to_string();
        let columns = vec![column("id", "orders"), aliased];
        let row = vec![CellValue::UInt(7), CellValue::Null];

        let stmt = build_select_by_key(&target(), &columns, &row).expect("应该能生成");
        // 别名写进 SELECT 列表没问题，但要和 UPDATE 一致用原始列名，避免同名歧义
        assert_eq!(
            stmt.sql,
            "SELECT `id`, `amount` FROM `shop`.`orders` WHERE `id` = ? LIMIT 1"
        );
        assert_eq!(stmt.params, vec![Value::UInt(7)]);
    }
}
