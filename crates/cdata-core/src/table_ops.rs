//! 侧栏右键对整张表的操作：改名、复制、删除、清空、维护语句、INSERT 模板。
//!
//! 这里只生成语句，不碰连接。写库的几种都走和改表一样的「预览 → 确认 → 核对后执行」，
//! 预览结果复用 AlterPlan，界面用同一个确认框。

use serde::{Deserialize, Serialize};

use crate::alter::AlterPlan;
use crate::sql::quote_ident;
use crate::structure::ColumnDef;

/// 要预览确认的写库操作
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum TableAction {
    Rename { new_name: String },
    /// 复制表结构，with_data 为 true 时连数据一起复制
    Duplicate { new_name: String, with_data: bool },
    Drop,
    Truncate,
}

/// 表维护语句。结果是 MySQL 返回的一组消息，不改数据
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub enum Maintenance {
    Analyze,
    Check,
    Optimize,
    Repair,
}

/// 维护语句返回的一行消息，Msg_type 是 status / info / note / warning / error
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MaintenanceMessage {
    pub msg_type: String,
    pub text: String,
}

fn target(database: &str, table: &str) -> String {
    format!("{}.{}", quote_ident(database), quote_ident(table))
}

/// 生成列写不进值，复制数据和 INSERT 模板都要跳过。EXTRA 里是 VIRTUAL GENERATED / STORED GENERATED
fn is_generated(column: &ColumnDef) -> bool {
    column.extra.contains("GENERATED")
}

/// 生成要执行的语句和提示。is_view 由调用方从 information_schema 读，不信界面传的。
/// columns 只有复制数据时用到
pub fn plan_action(
    database: &str,
    table: &str,
    is_view: bool,
    columns: &[ColumnDef],
    action: &TableAction,
) -> Result<AlterPlan, String> {
    let from = target(database, table);
    let mut plan = AlterPlan { statements: Vec::new(), dangers: Vec::new(), notes: Vec::new() };

    match action {
        TableAction::Rename { new_name } => {
            check_new_name(table, new_name)?;
            plan.statements.push(format!("RENAME TABLE {from} TO {}", target(database, new_name)));
            plan.notes.push(
                "其他视图、存储过程、触发器里写死的旧名字不会跟着改，改名后它们会失效".to_string(),
            );
        }
        TableAction::Duplicate { new_name, with_data } => {
            if is_view {
                return Err(format!("{table} 是视图，不能复制；要复制请拿它的 CREATE VIEW 改名后执行"));
            }
            check_new_name(table, new_name)?;
            let to = target(database, new_name);
            plan.statements.push(format!("CREATE TABLE {to} LIKE {from}"));
            plan.notes.push("CREATE TABLE … LIKE 带上列、索引和默认值，不带外键约束和触发器".to_string());
            if *with_data {
                let mut names = Vec::new();
                for column in columns {
                    if !is_generated(column) {
                        names.push(quote_ident(&column.name));
                    }
                }
                if names.is_empty() {
                    return Err(format!("{table} 没有可以复制数据的列"));
                }
                let list = names.join(", ");
                plan.statements.push(format!("INSERT INTO {to} ({list})\nSELECT {list} FROM {from}"));
                plan.notes.push(
                    "分两条执行：建表是 DDL、会隐式提交，复制数据失败时新表已经建好、里面是空的".to_string(),
                );
                if names.len() < columns.len() {
                    plan.notes.push("生成列不复制值，由新表按表达式重新算".to_string());
                }
            }
        }
        TableAction::Drop => {
            if is_view {
                plan.statements.push(format!("DROP VIEW {from}"));
                plan.dangers.push(format!("删除视图 {table} 的定义，不能撤销（底层表的数据不受影响）"));
            } else {
                plan.statements.push(format!("DROP TABLE {from}"));
                plan.dangers.push(format!("删除表 {table} 和里面的全部数据，不能撤销"));
            }
        }
        TableAction::Truncate => {
            if is_view {
                return Err(format!("{table} 是视图，没有数据可以清空"));
            }
            plan.statements.push(format!("TRUNCATE TABLE {from}"));
            plan.dangers.push(format!("清空表 {table} 的全部数据，不能撤销，自增计数从头开始"));
            plan.notes.push("被其他表的外键引用时 MySQL 会拒绝清空".to_string());
        }
    }
    Ok(plan)
}

/// 新名字原样交给 MySQL，不修剪：修剪过的名字和用户看到的不是同一个
fn check_new_name(table: &str, new_name: &str) -> Result<(), String> {
    if new_name.is_empty() {
        return Err("新名字不能为空".to_string());
    }
    if new_name == table {
        return Err("新名字和原来一样".to_string());
    }
    Ok(())
}

pub fn maintenance_sql(database: &str, table: &str, op: Maintenance) -> String {
    let keyword = match op {
        Maintenance::Analyze => "ANALYZE",
        Maintenance::Check => "CHECK",
        Maintenance::Optimize => "OPTIMIZE",
        Maintenance::Repair => "REPAIR",
    };
    format!("{keyword} TABLE {}", target(database, table))
}

pub fn count_sql(database: &str, table: &str) -> String {
    format!("SELECT COUNT(*) FROM {}", target(database, table))
}

/// INSERT 模板：列名写全，值用 ? 占位。生成列写不进值，不列出来
pub fn insert_template(table: &str, columns: &[ColumnDef]) -> String {
    let mut names = Vec::new();
    for column in columns {
        if !is_generated(column) {
            names.push(quote_ident(&column.name));
        }
    }
    let placeholders = vec!["?"; names.len()].join(", ");
    format!("INSERT INTO {} ({})\nVALUES\n\t({placeholders});", quote_ident(table), names.join(", "))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::structure::DefaultValue;

    fn column(name: &str, extra: &str) -> ColumnDef {
        ColumnDef {
            name: name.to_string(),
            column_type: "int".to_string(),
            nullable: true,
            default: DefaultValue::Null,
            extra: extra.to_string(),
            comment: String::new(),
            collation: None,
        }
    }

    #[test]
    fn rename_quotes_both_names_and_keeps_database() {
        let action = TableAction::Rename { new_name: "new`name".to_string() };
        let plan = plan_action("shop", "orders", false, &[], &action).unwrap();
        assert_eq!(plan.statements, ["RENAME TABLE `shop`.`orders` TO `shop`.`new``name`"]);
        assert!(plan.dangers.is_empty());
    }

    #[test]
    fn rename_rejects_empty_or_unchanged_name() {
        for name in ["", "orders"] {
            let action = TableAction::Rename { new_name: name.to_string() };
            assert!(plan_action("shop", "orders", false, &[], &action).is_err(), "{name:?}");
        }
    }

    #[test]
    fn duplicate_with_data_skips_generated_columns() {
        let columns = [column("id", "auto_increment"), column("total", "STORED GENERATED"), column("note", "")];
        let action = TableAction::Duplicate { new_name: "orders_copy".to_string(), with_data: true };
        let plan = plan_action("shop", "orders", false, &columns, &action).unwrap();
        assert_eq!(
            plan.statements,
            [
                "CREATE TABLE `shop`.`orders_copy` LIKE `shop`.`orders`",
                "INSERT INTO `shop`.`orders_copy` (`id`, `note`)\nSELECT `id`, `note` FROM `shop`.`orders`",
            ]
        );
        assert!(plan.notes.iter().any(|note| note.contains("生成列")));
    }

    #[test]
    fn duplicate_without_data_is_one_statement() {
        let action = TableAction::Duplicate { new_name: "orders_copy".to_string(), with_data: false };
        let plan = plan_action("shop", "orders", false, &[column("id", "")], &action).unwrap();
        assert_eq!(plan.statements, ["CREATE TABLE `shop`.`orders_copy` LIKE `shop`.`orders`"]);
    }

    #[test]
    fn views_cannot_be_duplicated_or_truncated_but_drop_uses_drop_view() {
        let duplicate = TableAction::Duplicate { new_name: "v2".to_string(), with_data: false };
        assert!(plan_action("shop", "v", true, &[], &duplicate).is_err());
        assert!(plan_action("shop", "v", true, &[], &TableAction::Truncate).is_err());

        let plan = plan_action("shop", "v", true, &[], &TableAction::Drop).unwrap();
        assert_eq!(plan.statements, ["DROP VIEW `shop`.`v`"]);
    }

    #[test]
    fn drop_and_truncate_are_flagged_as_dangerous() {
        for action in [TableAction::Drop, TableAction::Truncate] {
            let plan = plan_action("shop", "orders", false, &[], &action).unwrap();
            assert_eq!(plan.dangers.len(), 1, "{action:?}");
        }
    }

    #[test]
    fn insert_template_lists_writable_columns_with_placeholders() {
        let columns = [column("id", "auto_increment"), column("total", "VIRTUAL GENERATED"), column("note", "")];
        assert_eq!(insert_template("orders", &columns), "INSERT INTO `orders` (`id`, `note`)\nVALUES\n\t(?, ?);");
    }

    #[test]
    fn maintenance_and_count_quote_names() {
        assert_eq!(maintenance_sql("shop", "a`b", Maintenance::Optimize), "OPTIMIZE TABLE `shop`.`a``b`");
        assert_eq!(count_sql("shop", "orders"), "SELECT COUNT(*) FROM `shop`.`orders`");
    }
}
