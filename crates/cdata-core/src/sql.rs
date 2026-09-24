//! SQL 生成与改写。界面不要自己拼 SQL，标识符转义都在这里做。

/// 反引号包裹，标识符里的反引号按 MySQL 规则双写转义
pub fn quote_ident(name: &str) -> String {
    format!("`{}`", name.replace('`', "``"))
}

/// 浏览整张表
pub fn browse_table(table: &str) -> String {
    format!("SELECT * FROM {}", quote_ident(table))
}

/// 给任意查询加排序。
///
/// 包成子查询而不是去改原 SQL：用户的 SQL 可能已经有 ORDER BY、LIMIT、UNION，
/// 想在原句上正确插一个 ORDER BY 就得真正解析 SQL，包一层是等价且不会改错的做法。
///
/// 排序交给服务端做，不在本地排 —— collation、NULL 的位置、数字型字符串
/// 这些规则只有 MySQL 自己算得准，本地排会和 `ORDER BY` 的结果对不上。
pub fn with_order_by(sql: &str, column: &str, ascending: bool) -> String {
    let direction = if ascending { "ASC" } else { "DESC" };
    format!(
        "SELECT * FROM (\n{}\n) AS cdata_sorted ORDER BY {} {}",
        sql.trim().trim_end_matches(';'),
        quote_ident(column),
        direction
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identifiers_are_escaped() {
        assert_eq!(quote_ident("orders"), "`orders`");
        // 关键字和带反引号的表名都不能把 SQL 拼坏
        assert_eq!(quote_ident("order"), "`order`");
        assert_eq!(quote_ident("we`ird"), "`we``ird`");
    }

    #[test]
    fn browse_table_quotes_the_name() {
        assert_eq!(browse_table("big_rows"), "SELECT * FROM `big_rows`");
    }

    #[test]
    fn order_by_wraps_instead_of_rewriting() {
        let sql = with_order_by("SELECT * FROM orders", "amount", false);
        assert!(sql.contains("AS cdata_sorted ORDER BY `amount` DESC"), "{sql}");
        assert!(sql.contains("SELECT * FROM orders"), "原查询要原样保留：{sql}");
    }

    #[test]
    fn order_by_survives_existing_order_and_limit() {
        // 原句已经有 ORDER BY 和 LIMIT，包子查询不会改坏它的语义
        let sql = with_order_by("SELECT * FROM orders ORDER BY id LIMIT 10", "amount", true);
        assert!(sql.contains("ORDER BY id LIMIT 10"), "{sql}");
        assert!(sql.trim_end().ends_with("ORDER BY `amount` ASC"), "{sql}");
    }

    #[test]
    fn trailing_semicolon_is_dropped() {
        // 分号留着会让子查询语法错
        let sql = with_order_by("SELECT * FROM orders;", "id", true);
        assert!(!sql.contains(";"), "{sql}");
    }
}
