//! SQL 生成与改写。界面不要自己拼 SQL，标识符转义和值的参数化都在这里做。

use mysql_async::Value;
use serde::{Deserialize, Serialize};

/// 一条语句。SQL 和参数分开，值永远走参数化，不拼进 SQL
#[derive(Debug, Clone, PartialEq)]
pub struct Statement {
    pub sql: String,
    pub params: Vec<Value>,
}

/// 反引号包裹，标识符里的反引号按 MySQL 规则双写转义
pub fn quote_ident(name: &str) -> String {
    format!("`{}`", name.replace('`', "``"))
}

/// 浏览整张表
pub fn browse_table(table: &str) -> String {
    format!("SELECT * FROM {}", quote_ident(table))
}

/// 筛选运算符。值一律按字符串绑定，由 MySQL 按列类型转换
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum FilterOp {
    Eq,
    NotEq,
    Lt,
    LtEq,
    Gt,
    GtEq,
    Contains,
    NotContains,
    StartsWith,
    EndsWith,
    IsNull,
    IsNotNull,
}

/// 一条筛选条件。column 是结果集里的列名（有别名就是别名），IS NULL 类运算符忽略 value
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FilterCondition {
    pub column: String,
    pub op: FilterOp,
    pub value: String,
}

/// LIKE 的转义字符。不用反斜杠：反斜杠在字符串字面量里的含义随 NO_BACKSLASH_ESCAPES 变，
/// 换一个普通字符，不管服务器开没开这个 sql_mode 都一样
const LIKE_ESCAPE: char = '|';

/// 给任意查询加筛选和排序。
///
/// 包成子查询而不是去改原 SQL：用户的 SQL 可能已经有 WHERE、ORDER BY、LIMIT、UNION，
/// 想在原句上正确插条件就得真正解析 SQL，包一层是等价且不会改错的做法。
/// MySQL 会把这层派生表合并掉，列元数据里的原始表还在，筛选后照样能编辑。
///
/// 排序交给服务端做，不在本地排 —— collation、NULL 的位置、数字型字符串
/// 这些规则只有 MySQL 自己算得准。
///
/// 既没有条件也不排序时原样返回，不多包一层。
pub fn build_view(
    sql: &str,
    conditions: &[FilterCondition],
    match_all: bool,
    sort: Option<(&str, bool)>,
) -> Result<Statement, String> {
    if conditions.is_empty() && sort.is_none() {
        return Ok(Statement { sql: sql.to_string(), params: Vec::new() });
    }

    let mut parts = Vec::with_capacity(conditions.len());
    let mut params = Vec::new();
    for condition in conditions {
        if condition.column.is_empty() {
            return Err("筛选条件没有选列".to_string());
        }
        let column = quote_ident(&condition.column);
        let value = &condition.value;

        // NOT LIKE / <> 对 NULL 的结果是 NULL，NULL 行不会出现在「不包含」「≠」里。
        // 这是 MySQL 的语义，和直接写 WHERE 一致，不在这里偷偷补 OR IS NULL
        let (part, param) = match condition.op {
            FilterOp::Eq => (format!("{column} = ?"), Some(value.clone())),
            FilterOp::NotEq => (format!("{column} <> ?"), Some(value.clone())),
            FilterOp::Lt => (format!("{column} < ?"), Some(value.clone())),
            FilterOp::LtEq => (format!("{column} <= ?"), Some(value.clone())),
            FilterOp::Gt => (format!("{column} > ?"), Some(value.clone())),
            FilterOp::GtEq => (format!("{column} >= ?"), Some(value.clone())),
            FilterOp::Contains => (
                format!("{column} LIKE ? ESCAPE '{LIKE_ESCAPE}'"),
                Some(format!("%{}%", escape_like(value))),
            ),
            FilterOp::NotContains => (
                format!("{column} NOT LIKE ? ESCAPE '{LIKE_ESCAPE}'"),
                Some(format!("%{}%", escape_like(value))),
            ),
            FilterOp::StartsWith => (
                format!("{column} LIKE ? ESCAPE '{LIKE_ESCAPE}'"),
                Some(format!("{}%", escape_like(value))),
            ),
            FilterOp::EndsWith => (
                format!("{column} LIKE ? ESCAPE '{LIKE_ESCAPE}'"),
                Some(format!("%{}", escape_like(value))),
            ),
            FilterOp::IsNull => (format!("{column} IS NULL"), None),
            FilterOp::IsNotNull => (format!("{column} IS NOT NULL"), None),
        };

        parts.push(format!("({part})"));
        if let Some(param) = param {
            params.push(Value::Bytes(param.into_bytes()));
        }
    }

    // 原句末尾的分号留着会让子查询语法错；换行包住，原句末尾的 `-- 注释` 不会吞掉右括号
    let mut out = format!(
        "SELECT * FROM (\n{}\n) AS cdata_view",
        sql.trim().trim_end_matches(';')
    );
    if !parts.is_empty() {
        let joiner = if match_all { " AND " } else { " OR " };
        out.push_str(" WHERE ");
        out.push_str(&parts.join(joiner));
    }
    if let Some((column, ascending)) = sort {
        let direction = if ascending { "ASC" } else { "DESC" };
        out.push_str(&format!(" ORDER BY {} {}", quote_ident(column), direction));
    }

    Ok(Statement { sql: out, params })
}

/// 用户输入里的 % 和 _ 是字面字符，不是通配符
fn escape_like(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for ch in value.chars() {
        if ch == LIKE_ESCAPE || ch == '%' || ch == '_' {
            out.push(LIKE_ESCAPE);
        }
        out.push(ch);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn condition(column: &str, op: FilterOp, value: &str) -> FilterCondition {
        FilterCondition { column: column.to_string(), op, value: value.to_string() }
    }

    fn text(s: &str) -> Value {
        Value::Bytes(s.as_bytes().to_vec())
    }

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
    fn nothing_to_add_keeps_the_sql_untouched() {
        let stmt = build_view("SELECT * FROM orders;", &[], true, None).unwrap();
        assert_eq!(stmt.sql, "SELECT * FROM orders;");
    }

    #[test]
    fn order_by_wraps_instead_of_rewriting() {
        let stmt = build_view("SELECT * FROM orders", &[], true, Some(("amount", false))).unwrap();
        assert_eq!(stmt.sql, "SELECT * FROM (\nSELECT * FROM orders\n) AS cdata_view ORDER BY `amount` DESC");
    }

    #[test]
    fn existing_order_limit_and_semicolon_survive() {
        let stmt = build_view(
            "SELECT * FROM orders ORDER BY id LIMIT 10;",
            &[],
            true,
            Some(("amount", true)),
        )
        .unwrap();
        assert!(stmt.sql.contains("ORDER BY id LIMIT 10\n)"), "{}", stmt.sql);
        assert!(!stmt.sql.contains(';'), "{}", stmt.sql);
    }

    #[test]
    fn trailing_line_comment_does_not_swallow_the_paren() {
        let stmt = build_view("SELECT * FROM orders -- 看这里", &[], true, Some(("id", true))).unwrap();
        assert!(stmt.sql.contains("-- 看这里\n)"), "{}", stmt.sql);
    }

    #[test]
    fn conditions_are_parameterised_and_joined() {
        let conditions = vec![
            condition("amount", FilterOp::GtEq, "10.5"),
            condition("note", FilterOp::IsNull, "被忽略"),
            condition("name", FilterOp::Eq, "'; DROP TABLE orders; --"),
        ];
        let stmt = build_view("SELECT * FROM orders", &conditions, true, Some(("id", false))).unwrap();

        assert_eq!(
            stmt.sql,
            "SELECT * FROM (\nSELECT * FROM orders\n) AS cdata_view \
             WHERE (`amount` >= ?) AND (`note` IS NULL) AND (`name` = ?) ORDER BY `id` DESC"
        );
        // 值走参数，绝不拼进 SQL；IS NULL 不占参数
        assert_eq!(stmt.params, vec![text("10.5"), text("'; DROP TABLE orders; --")]);
    }

    #[test]
    fn any_match_uses_or() {
        let conditions = vec![condition("a", FilterOp::Eq, "1"), condition("b", FilterOp::Eq, "2")];
        let stmt = build_view("SELECT * FROM t", &conditions, false, None).unwrap();
        assert!(stmt.sql.ends_with("WHERE (`a` = ?) OR (`b` = ?)"), "{}", stmt.sql);
    }

    #[test]
    fn like_wildcards_in_user_input_are_literal() {
        let conditions = vec![
            condition("name", FilterOp::Contains, "50%_off|x"),
            condition("name", FilterOp::StartsWith, "张"),
            condition("name", FilterOp::EndsWith, "三"),
        ];
        let stmt = build_view("SELECT * FROM t", &conditions, true, None).unwrap();

        assert!(stmt.sql.contains("`name` LIKE ? ESCAPE '|'"), "{}", stmt.sql);
        assert_eq!(
            stmt.params,
            vec![text("%50|%|_off||x%"), text("张%"), text("%三")]
        );
    }

    #[test]
    fn filter_column_names_are_quoted() {
        let conditions = vec![condition("we`ird", FilterOp::Eq, "1")];
        let stmt = build_view("SELECT * FROM t", &conditions, true, None).unwrap();
        assert!(stmt.sql.contains("(`we``ird` = ?)"), "{}", stmt.sql);
    }

    #[test]
    fn condition_without_column_is_refused() {
        let conditions = vec![condition("", FilterOp::Eq, "1")];
        assert!(build_view("SELECT * FROM t", &conditions, true, None).unwrap_err().contains("列"));
    }
}
