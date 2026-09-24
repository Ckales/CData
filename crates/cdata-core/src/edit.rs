//! 单元格写回：能不能编辑、怎么定位那一行、生成什么 SQL。
//!
//! 这里最重要的规则是**拿不准就拒绝**。没有主键、结果来自多张表、主键列没查出来，
//! 一律禁止编辑并说明原因。猜一个「看起来能用」的 WHERE 条件可能改掉成千上万行。

use mysql_async::prelude::*;
use mysql_async::{Pool, Value};
use serde::{Deserialize, Serialize};

use crate::db::ColumnMeta;
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
    /// 主键列在结果集里的下标。按主键顺序排列
    pub key_indexes: Vec<usize>,
}

/// 判断结果集能不能编辑。
///
/// 只支持单表查询：所有列都来自同一张实体表，且主键列全在结果集里。
/// JOIN、聚合、表达式列一律只读——它们没有可靠的回写目标。
pub async fn detect_editability(pool: &Pool, columns: &[ColumnMeta]) -> Editability {
    if columns.is_empty() {
        return Editability::ReadOnly("结果集没有列".to_string());
    }

    let (schema, table) = match single_source_table(columns) {
        Ok(pair) => pair,
        Err(reason) => return Editability::ReadOnly(reason),
    };

    let key_columns = match primary_key_columns(pool, &schema, &table).await {
        Ok(keys) => keys,
        Err(err) => return Editability::ReadOnly(format!("读取主键失败：{err}")),
    };

    if key_columns.is_empty() {
        return Editability::ReadOnly(format!(
            "表 {table} 没有主键，无法安全定位行，不能编辑"
        ));
    }

    // 主键列必须都在结果集里，否则定位不到具体哪一行
    let mut key_indexes = Vec::with_capacity(key_columns.len());
    for key in &key_columns {
        match columns.iter().position(|c| &c.org_name == key) {
            Some(index) => key_indexes.push(index),
            None => {
                return Editability::ReadOnly(format!(
                    "查询结果里没有主键列 {key}，无法定位行。把它加进 SELECT 才能编辑"
                ))
            }
        }
    }

    Editability::Editable(EditTarget {
        schema,
        table,
        key_indexes,
    })
}

/// 所有列必须来自同一张实体表
fn single_source_table(columns: &[ColumnMeta]) -> Result<(String, String), String> {
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

async fn primary_key_columns(
    pool: &Pool,
    schema: &str,
    table: &str,
) -> Result<Vec<String>, mysql_async::Error> {
    let mut conn = pool.get_conn().await?;
    let rows: Vec<String> = conn
        .exec(
            "SELECT COLUMN_NAME FROM information_schema.STATISTICS \
             WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? AND INDEX_NAME = 'PRIMARY' \
             ORDER BY SEQ_IN_INDEX",
            (schema, table),
        )
        .await?;
    Ok(rows)
}

/// 一条写回语句。SQL 和参数分开，值永远走参数化，不拼进 SQL
#[derive(Debug, Clone, PartialEq)]
pub struct UpdateStatement {
    pub sql: String,
    pub params: Vec<Value>,
}

/// 生成改一个单元格的 UPDATE。
///
/// 加 `LIMIT 1` 是最后一道保险：主键理应唯一，真出现重复时也只会动一行。
pub fn build_update(
    target: &EditTarget,
    columns: &[ColumnMeta],
    row: &[CellValue],
    column_index: usize,
    new_value: &CellValue,
) -> Result<UpdateStatement, String> {
    let column = columns
        .get(column_index)
        .ok_or_else(|| format!("列下标 {column_index} 越界"))?;

    if target.key_indexes.contains(&column_index) {
        return Err(format!("{} 是主键列，改主键要用专门的流程", column.name));
    }

    let mut params = vec![value_to_mysql(new_value)];
    let mut conditions = Vec::with_capacity(target.key_indexes.len());

    for &key_index in &target.key_indexes {
        let key_column = columns
            .get(key_index)
            .ok_or_else(|| format!("主键列下标 {key_index} 越界"))?;
        let key_value = row
            .get(key_index)
            .ok_or_else(|| format!("这一行缺少主键列 {}", key_column.name))?;

        // 主键为 NULL 说明这行数据本身就不对，不能拿它当定位条件
        if key_value == &CellValue::Null {
            return Err(format!("主键列 {} 是 NULL，无法定位这一行", key_column.name));
        }

        conditions.push(format!("{} = ?", quote_ident(&key_column.org_name)));
        params.push(value_to_mysql(key_value));
    }

    let sql = format!(
        "UPDATE {}.{} SET {} = ? WHERE {} LIMIT 1",
        quote_ident(&target.schema),
        quote_ident(&target.table),
        quote_ident(&column.org_name),
        conditions.join(" AND "),
    );

    Ok(UpdateStatement { sql, params })
}

/// 反引号包裹，标识符里的反引号按 MySQL 规则双写转义
fn quote_ident(name: &str) -> String {
    format!("`{}`", name.replace('`', "``"))
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
        }
    }

    fn target() -> EditTarget {
        EditTarget {
            schema: "shop".to_string(),
            table: "orders".to_string(),
            key_indexes: vec![0],
        }
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

        let stmt = build_update(&target(), &columns, &row, 1, &CellValue::Text("9.99".into()))
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

        let err = build_update(&target(), &columns, &row, 1, &CellValue::Text("9.99".into()))
            .unwrap_err();
        assert!(err.contains("NULL"), "原因要说清楚：{err}");
    }

    #[test]
    fn editing_the_primary_key_itself_is_refused() {
        let columns = vec![column("id", "orders"), column("amount", "orders")];
        let row = vec![CellValue::Int(42), CellValue::Text("1.00".into())];

        let err =
            build_update(&target(), &columns, &row, 0, &CellValue::Int(43)).unwrap_err();
        assert!(err.contains("主键"), "原因要说清楚：{err}");
    }

    #[test]
    fn identifiers_with_backticks_are_escaped() {
        assert_eq!(quote_ident("we`ird"), "`we``ird`");
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

        let stmt =
            build_update(&multi_target, &columns, &row, 2, &CellValue::Text("2.00".into()))
                .expect("应该能生成");

        assert_eq!(
            stmt.sql,
            "UPDATE `shop`.`orders` SET `amount` = ? WHERE `shop_id` = ? AND `order_no` = ? LIMIT 1"
        );
        assert_eq!(stmt.params.len(), 3);
    }
}
