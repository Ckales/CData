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
    /// 值是一行一个的列表，见 [`filter_in_values`]
    In,
    NotIn,
}

/// 一条筛选条件。column 是结果集里的列名（有别名就是别名），IS NULL 类运算符忽略 value
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FilterCondition {
    pub column: String,
    pub op: FilterOp,
    pub value: String,
}

/// 一组条件，按 match_all 用 AND 或 OR 连起来。组里可以再套组，
/// 这样才写得出 (A AND B) OR (C AND D)
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FilterGroup {
    pub match_all: bool,
    pub items: Vec<FilterItem>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum FilterItem {
    Condition(FilterCondition),
    Group(FilterGroup),
}

/// LIKE 的转义字符。不用反斜杠：反斜杠在字符串字面量里的含义随 NO_BACKSLASH_ESCAPES 变，
/// 换一个普通字符，不管服务器开没开这个 sql_mode 都一样
const LIKE_ESCAPE: char = '|';

/// 一条预处理语句最多 65535 个占位符，超了 MySQL 报错，这里先拦下来说清楚
const MAX_PARAMS: usize = 65535;

/// 单层条件的筛选，等价于只有一组的 [`build_filtered_view`]
pub fn build_view(
    sql: &str,
    conditions: &[FilterCondition],
    match_all: bool,
    sort: Option<(&str, bool)>,
) -> Result<Statement, String> {
    let mut items = Vec::with_capacity(conditions.len());
    for condition in conditions {
        items.push(FilterItem::Condition(condition.clone()));
    }
    build_filtered_view(sql, &FilterGroup { match_all, items }, sort)
}

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
pub fn build_filtered_view(
    sql: &str,
    filter: &FilterGroup,
    sort: Option<(&str, bool)>,
) -> Result<Statement, String> {
    if filter.items.is_empty() && sort.is_none() {
        return Ok(Statement { sql: sql.to_string(), params: Vec::new() });
    }

    let mut params = Vec::new();
    // 最外层的空组就是没有筛选；里层的空组在 group_sql 里拒绝
    let where_clause = if filter.items.is_empty() {
        None
    } else {
        Some(group_sql(filter, &mut params)?)
    };
    if params.len() > MAX_PARAMS {
        return Err(format!(
            "筛选一共有 {} 个值，超过 MySQL 单条语句 {MAX_PARAMS} 个参数的上限，请减少 IN 列表里的值",
            params.len()
        ));
    }

    // 原句末尾的分号留着会让子查询语法错；换行包住，原句末尾的 `-- 注释` 不会吞掉右括号
    let mut out = format!(
        "SELECT * FROM (\n{}\n) AS cdata_view",
        sql.trim().trim_end_matches(';')
    );
    if let Some(where_clause) = where_clause {
        out.push_str(" WHERE ");
        out.push_str(&where_clause);
    }
    if let Some((column, ascending)) = sort {
        let direction = if ascending { "ASC" } else { "DESC" };
        out.push_str(&format!(" ORDER BY {} {}", quote_ident(column), direction));
    }

    Ok(Statement { sql: out, params })
}

/// 一组条件拼成 `(a) AND (b) AND (…)`，里层的组再包一层括号
fn group_sql(group: &FilterGroup, params: &mut Vec<Value>) -> Result<String, String> {
    let mut parts = Vec::with_capacity(group.items.len());
    for item in &group.items {
        match item {
            FilterItem::Condition(condition) => {
                parts.push(format!("({})", condition_sql(condition, params)?));
            }
            FilterItem::Group(inner) => {
                // 空的 AND 组算真、空的 OR 组算假，哪种都不是用户想要的，不替他挑
                if inner.items.is_empty() {
                    return Err("有一个分组里没有条件，请删掉这个分组或者往里加条件".to_string());
                }
                parts.push(format!("({})", group_sql(inner, params)?));
            }
        }
    }
    let joiner = if group.match_all { " AND " } else { " OR " };
    Ok(parts.join(joiner))
}

fn condition_sql(condition: &FilterCondition, params: &mut Vec<Value>) -> Result<String, String> {
    if condition.column.is_empty() {
        return Err("筛选条件没有选列".to_string());
    }
    let column = quote_ident(&condition.column);
    let value = &condition.value;

    // NOT LIKE / <> / NOT IN 对 NULL 的结果是 NULL，NULL 行不会出现在「不包含」「≠」「不属于」里。
    // 这是 MySQL 的语义，和直接写 WHERE 一致，不在这里偷偷补 OR IS NULL
    let (part, values) = match condition.op {
        FilterOp::Eq => (format!("{column} = ?"), vec![value.clone()]),
        FilterOp::NotEq => (format!("{column} <> ?"), vec![value.clone()]),
        FilterOp::Lt => (format!("{column} < ?"), vec![value.clone()]),
        FilterOp::LtEq => (format!("{column} <= ?"), vec![value.clone()]),
        FilterOp::Gt => (format!("{column} > ?"), vec![value.clone()]),
        FilterOp::GtEq => (format!("{column} >= ?"), vec![value.clone()]),
        FilterOp::Contains => (
            format!("{column} LIKE ? ESCAPE '{LIKE_ESCAPE}'"),
            vec![format!("%{}%", escape_like(value))],
        ),
        FilterOp::NotContains => (
            format!("{column} NOT LIKE ? ESCAPE '{LIKE_ESCAPE}'"),
            vec![format!("%{}%", escape_like(value))],
        ),
        FilterOp::StartsWith => (
            format!("{column} LIKE ? ESCAPE '{LIKE_ESCAPE}'"),
            vec![format!("{}%", escape_like(value))],
        ),
        FilterOp::EndsWith => (
            format!("{column} LIKE ? ESCAPE '{LIKE_ESCAPE}'"),
            vec![format!("%{}", escape_like(value))],
        ),
        FilterOp::IsNull => (format!("{column} IS NULL"), Vec::new()),
        FilterOp::IsNotNull => (format!("{column} IS NOT NULL"), Vec::new()),
        FilterOp::In | FilterOp::NotIn => {
            let values = filter_in_values(value).map_err(|err| format!("{}：{err}", condition.column))?;
            let marks = vec!["?"; values.len()].join(", ");
            let keyword = if condition.op == FilterOp::In { "IN" } else { "NOT IN" };
            (format!("{column} {keyword} ({marks})"), values)
        }
    };

    for value in values {
        params.push(Value::Bytes(value.into_bytes()));
    }
    Ok(part)
}

/// IN / NOT IN 的值列表：一行一个，原样绑定。
///
/// 不按逗号切，值里本来就可能有逗号。拒绝三种情况，都不替用户猜：
/// - 空列表：`IN ()` 是语法错误，当成「全不命中」或「全命中」都是替用户定语义；
/// - 空行：多半是手滑，要匹配空字符串请用「=」；
/// - `NULL`：`x IN (…, NULL)` 命中不了 NULL 行，`x NOT IN (…, NULL)` 永远不为真，
///   写进去只会得到意料之外的空结果。文本 "NULL" 也一并拒绝，要匹配它请用「=」。
pub fn filter_in_values(text: &str) -> Result<Vec<String>, String> {
    // 从表格里复制一列，末尾常带一个换行（Windows 上是 \r\n）
    let body = text.strip_suffix('\n').unwrap_or(text);
    if body.is_empty() || body == "\r" {
        return Err("IN 列表是空的，至少要写一个值（一行一个）".to_string());
    }

    let mut values = Vec::new();
    for (index, line) in body.split('\n').enumerate() {
        let line = line.strip_suffix('\r').unwrap_or(line);
        if line.is_empty() {
            return Err(format!("IN 列表第 {} 行是空的；要匹配空字符串请用「=」", index + 1));
        }
        if line.eq_ignore_ascii_case("NULL") {
            return Err(format!(
                "IN 列表第 {} 行是 NULL：IN 里的 NULL 命中不了 NULL 行，NOT IN 里有 NULL 永远不为真。\
                 要找 NULL 请另加一条「为 NULL」条件，用「满足任一」连起来",
                index + 1
            ));
        }
        values.push(line.to_string());
    }
    Ok(values)
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

    fn leaf(column: &str, op: FilterOp, value: &str) -> FilterItem {
        FilterItem::Condition(condition(column, op, value))
    }

    fn group(match_all: bool, items: Vec<FilterItem>) -> FilterItem {
        FilterItem::Group(FilterGroup { match_all, items })
    }

    #[test]
    fn in_list_is_one_placeholder_per_line() {
        let conditions = vec![
            condition("id", FilterOp::In, "1\n2,5\n3\n"),
            condition("name", FilterOp::NotIn, "张三\r\n李四"),
        ];
        let stmt = build_view("SELECT * FROM t", &conditions, true, None).unwrap();
        assert!(
            stmt.sql.ends_with("WHERE (`id` IN (?, ?, ?)) AND (`name` NOT IN (?, ?))"),
            "{}",
            stmt.sql
        );
        // 逗号不是分隔符；末尾换行和 \r 是粘贴带进来的，不算值
        assert_eq!(stmt.params, vec![text("1"), text("2,5"), text("3"), text("张三"), text("李四")]);
    }

    #[test]
    fn in_list_refuses_empty_blank_lines_and_null() {
        for value in ["", "\n", "\r\n"] {
            let err = filter_in_values(value).unwrap_err();
            assert!(err.contains("至少要写一个值"), "{value:?} → {err}");
        }
        assert!(filter_in_values("1\n\n2").unwrap_err().contains("第 2 行是空的"));
        // NOT IN (…, NULL) 永远不为真，不能让它静默地返回空结果
        let err = filter_in_values("1\nnull").unwrap_err();
        assert!(err.contains("第 2 行是 NULL"), "{err}");

        let conditions = vec![condition("id", FilterOp::NotIn, "1\nNULL")];
        let err = build_view("SELECT * FROM t", &conditions, true, None).unwrap_err();
        assert!(err.starts_with("id："), "错误要指出是哪一列：{err}");
    }

    #[test]
    fn in_list_keeps_values_verbatim() {
        // 前后空格、LIKE 通配符都原样绑定，IN 不是 LIKE
        assert_eq!(filter_in_values(" a \n50%_\nNULLABLE").unwrap(), [" a ", "50%_", "NULLABLE"]);
    }

    #[test]
    fn nested_groups_get_their_own_parentheses() {
        // (a = 1 AND b = 2) OR (c IN (3, 4) AND (d IS NULL OR d < 5))
        let filter = FilterGroup {
            match_all: false,
            items: vec![
                group(true, vec![leaf("a", FilterOp::Eq, "1"), leaf("b", FilterOp::Eq, "2")]),
                group(
                    true,
                    vec![
                        leaf("c", FilterOp::In, "3\n4"),
                        group(false, vec![leaf("d", FilterOp::IsNull, ""), leaf("d", FilterOp::Lt, "5")]),
                    ],
                ),
            ],
        };
        let stmt = build_filtered_view("SELECT * FROM t", &filter, Some(("a", true))).unwrap();
        assert_eq!(
            stmt.sql,
            "SELECT * FROM (\nSELECT * FROM t\n) AS cdata_view WHERE \
             ((`a` = ?) AND (`b` = ?)) OR ((`c` IN (?, ?)) AND ((`d` IS NULL) OR (`d` < ?))) ORDER BY `a` ASC"
        );
        // 参数顺序和占位符出现的顺序一致
        assert_eq!(stmt.params, vec![text("1"), text("2"), text("3"), text("4"), text("5")]);
    }

    #[test]
    fn flat_build_view_matches_a_single_group() {
        let conditions = vec![condition("a", FilterOp::Eq, "1"), condition("b", FilterOp::Contains, "x")];
        let flat = build_view("SELECT * FROM t", &conditions, false, None).unwrap();
        let filter = FilterGroup {
            match_all: false,
            items: vec![leaf("a", FilterOp::Eq, "1"), leaf("b", FilterOp::Contains, "x")],
        };
        assert_eq!(flat, build_filtered_view("SELECT * FROM t", &filter, None).unwrap());
    }

    #[test]
    fn empty_inner_group_is_refused_but_empty_top_level_means_no_filter() {
        let filter = FilterGroup { match_all: true, items: vec![leaf("a", FilterOp::Eq, "1"), group(false, vec![])] };
        assert!(build_filtered_view("SELECT 1", &filter, None).unwrap_err().contains("分组里没有条件"));

        let empty = FilterGroup { match_all: true, items: vec![] };
        assert_eq!(build_filtered_view("SELECT 1;", &empty, None).unwrap().sql, "SELECT 1;");
    }

    #[test]
    fn too_many_in_values_are_refused_before_mysql_does() {
        let mut lines = Vec::new();
        for i in 0..=MAX_PARAMS {
            lines.push(i.to_string());
        }
        let conditions = vec![condition("id", FilterOp::In, &lines.join("\n"))];
        let err = build_view("SELECT * FROM t", &conditions, true, None).unwrap_err();
        assert!(err.contains("65535"), "{err}");
    }
}
