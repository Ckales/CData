//! schema 感知的补全：表名、列名、别名、关键字。
//!
//! 只靠词法 token 判断上下文，不做完整语法分析 —— 补全时的 SQL 几乎都是写了一半的。
//! 作用域按括号层级算：光标所在的那层 SELECT 看得到自己 FROM 里的表，
//! 也看得到外层的（相关子查询），看不到更里层子查询的。
//!
//! 派生表 `(SELECT …) AS x` 和 CTE `WITH x AS (…)` 的列从子查询的 select 列表推：
//! 有别名用别名，普通列用列名，`*` 展开来源表的列，没别名的表达式不给候选 ——
//! MySQL 给它起的名字是表达式原文，猜不准就不猜。

use serde::{Deserialize, Serialize};

use crate::lexer::{tokenize, SqlToken, SqlTokenKind, KEYWORDS};

/// 一个库的表和列，补全用
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Catalog {
    pub tables: Vec<CatalogTable>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CatalogTable {
    pub name: String,
    pub columns: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CompletionKind {
    Table,
    Column,
    /// 当前作用域里的别名
    Alias,
    Keyword,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CompletionItem {
    pub label: String,
    /// 实际插入的文本。需要时带反引号，关键字转大写
    pub insert_text: String,
    pub kind: CompletionKind,
    /// 列属于哪张表之类的附加信息
    pub detail: String,
}

/// 补全结果。用 insert_text 替换 [replace_start, replace_end)，都是 UTF-16 下标
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Completion {
    pub replace_start: u32,
    pub replace_end: u32,
    pub items: Vec<CompletionItem>,
}

/// 最多给这么多条，再多弹窗里也翻不过来
const MAX_ITEMS: usize = 50;

/// 语句里引用的一张表：真名和别名（没写别名时别名为空）
#[derive(Debug, Clone, PartialEq)]
struct TableRef {
    /// 派生表没有名字，是空串；CTE 是 CTE 的名字
    name: String,
    alias: String,
    /// 派生表和 CTE 推出来的输出列；普通表是 None，列去目录里查
    derived: Option<Vec<String>>,
}

/// 推断作用域时要一路带着的东西
struct Ctx<'a> {
    text_of: &'a dyn Fn(&SqlToken) -> String,
    catalog: &'a Catalog,
    /// 光标位置。光标所在的派生表对它自己不可见
    cursor: u32,
}

/// 语句开头 WITH 定义的一个 CTE
struct Cte {
    name: String,
    columns: Vec<String>,
}

pub fn complete(sql: &str, cursor: u32, catalog: &Catalog) -> Completion {
    let units: Vec<u16> = sql.encode_utf16().collect();
    let cursor = cursor.min(units.len() as u32);
    let tokens = tokenize(sql);
    let text_of = |token: &SqlToken| String::from_utf16_lossy(&units[token.start as usize..token.end as usize]);

    // 光标所在的词：替换它，并用光标前的部分当前缀
    let word_index = tokens.iter().position(|t| {
        t.start < cursor
            && cursor <= t.end
            && matches!(t.kind, SqlTokenKind::Identifier | SqlTokenKind::Keyword | SqlTokenKind::QuotedIdentifier)
    });
    let (replace_start, replace_end, prefix) = match word_index {
        Some(index) => {
            let token = &tokens[index];
            let typed = String::from_utf16_lossy(&units[token.start as usize..cursor as usize]);
            (token.start, token.end, typed.trim_start_matches('`').to_string())
        }
        None => (cursor, cursor, String::new()),
    };
    // 字符串和注释里不补全。没闭合的（行注释、写了一半的字符串）一直到末尾都算里面
    let inside_literal = tokens.iter().any(|t| {
        if !matches!(t.kind, SqlTokenKind::String | SqlTokenKind::Comment) || t.start >= cursor {
            return false;
        }
        cursor < t.end || (cursor == t.end && !is_closed(&text_of(t)))
    });
    if inside_literal {
        return Completion { replace_start: cursor, replace_end: cursor, items: Vec::new() };
    }

    // 判断上下文时注释不算：`FROM /* 表 */ |`、`FROM orders /* x */ o` 都要照常认
    let mut tokens_without_comments = Vec::with_capacity(tokens.len());
    for token in &tokens {
        if token.kind != SqlTokenKind::Comment {
            tokens_without_comments.push(token.clone());
        }
    }
    let tokens = tokens_without_comments;
    // 光标前的 token（不含光标所在的词）
    let mut before = Vec::new();
    for token in &tokens {
        if token.end <= replace_start {
            before.push(token);
        }
    }

    let ctx = Ctx { text_of: &text_of, catalog, cursor: replace_start };
    let scope = tables_in_scope(&tokens, &ctx);
    let mut items = Vec::new();

    // `别名.` 或 `表名.`：只补这张表的列
    let qualifier = match before.as_slice() {
        [.., name, dot] if text_of(dot) == "." && is_name(name) => Some(unquote(&text_of(name))),
        _ => None,
    };
    if let Some(qualifier) = qualifier {
        if let Some((detail, columns)) = resolve(&scope, &qualifier, catalog) {
            for column in &columns {
                push(&mut items, column, CompletionKind::Column, &detail, &prefix);
            }
        }
        return finish(replace_start, replace_end, items);
    }

    if expects_table(&before, &text_of) {
        for table in &catalog.tables {
            push(&mut items, &table.name, CompletionKind::Table, "", &prefix);
        }
        return finish(replace_start, replace_end, items);
    }

    // 其他位置：作用域里的列（里层优先）、别名、表名，最后是关键字
    let mut seen = Vec::new();
    for table_ref in &scope {
        if let Some((detail, columns)) = ref_columns(table_ref, catalog) {
            for column in &columns {
                if !seen.contains(column) {
                    seen.push(column.clone());
                    push(&mut items, column, CompletionKind::Column, &detail, &prefix);
                }
            }
        }
    }
    for table_ref in &scope {
        if table_ref.alias.is_empty() {
            // 没写别名的派生表（MySQL 本来就不允许）没有名字可补
            if !table_ref.name.is_empty() {
                push(&mut items, &table_ref.name, CompletionKind::Table, "", &prefix);
            }
        } else {
            let detail = if table_ref.name.is_empty() { "子查询" } else { &table_ref.name };
            push(&mut items, &table_ref.alias, CompletionKind::Alias, detail, &prefix);
        }
    }
    for keyword in KEYWORDS {
        push(&mut items, keyword, CompletionKind::Keyword, "", &prefix);
    }
    finish(replace_start, replace_end, items)
}

fn finish(replace_start: u32, replace_end: u32, mut items: Vec<CompletionItem>) -> Completion {
    items.truncate(MAX_ITEMS);
    Completion { replace_start, replace_end, items }
}

/// 名字匹配前缀（不分大小写）才加进去
fn push(items: &mut Vec<CompletionItem>, label: &str, kind: CompletionKind, detail: &str, prefix: &str) {
    if !label.to_lowercase().starts_with(&prefix.to_lowercase()) {
        return;
    }
    let insert_text = match kind {
        CompletionKind::Keyword => label.to_ascii_uppercase(),
        _ => quote_if_needed(label),
    };
    items.push(CompletionItem {
        label: label.to_string(),
        insert_text,
        kind,
        detail: detail.to_string(),
    });
}

/// 普通标识符原样插入；含特殊字符、以数字开头、或者撞了关键字的加反引号
fn quote_if_needed(name: &str) -> String {
    let mut chars = name.chars();
    let plain = chars.next().is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '$')
        && !crate::lexer::is_keyword(name);
    if plain {
        name.to_string()
    } else {
        crate::sql::quote_ident(name)
    }
}

/// 字符串或注释有没有正常收尾。行注释到行尾就结束，光标停在它末尾仍然在注释里
fn is_closed(text: &str) -> bool {
    if text.starts_with("/*") {
        return text.len() >= 4 && text.ends_with("*/");
    }
    if text.starts_with("--") || text.starts_with('#') {
        return false;
    }
    // X'..'、N'..' 这类带前缀的字符串，看最后一个字符是不是那个引号
    let Some(quote) = text.chars().find(|c| matches!(c, '\'' | '"')) else {
        return true;
    };
    text.chars().count() >= 2 && text.ends_with(quote) && text.len() > text.find(quote).unwrap_or(0) + 1
}

fn is_name(token: &SqlToken) -> bool {
    matches!(token.kind, SqlTokenKind::Identifier | SqlTokenKind::QuotedIdentifier)
}

fn unquote(text: &str) -> String {
    match text.strip_prefix('`').and_then(|t| t.strip_suffix('`')) {
        Some(inner) => inner.replace("``", "`"),
        None => text.to_string(),
    }
}

fn find_table<'a>(catalog: &'a Catalog, name: &str) -> Option<&'a CatalogTable> {
    catalog.tables.iter().find(|t| t.name.eq_ignore_ascii_case(name))
}

/// 一个表引用的列和补全时显示的来源。派生表 / CTE 用推出来的列，普通表查目录
fn ref_columns(table_ref: &TableRef, catalog: &Catalog) -> Option<(String, Vec<String>)> {
    if let Some(columns) = &table_ref.derived {
        let label = if table_ref.alias.is_empty() { &table_ref.name } else { &table_ref.alias };
        return Some((label.clone(), columns.clone()));
    }
    let table = find_table(catalog, &table_ref.name)?;
    Some((table.name.clone(), table.columns.clone()))
}

/// 限定名先按别名找，再按没写别名的表名（含 CTE）找，最后才去目录里找同名表
fn resolve(scope: &[TableRef], qualifier: &str, catalog: &Catalog) -> Option<(String, Vec<String>)> {
    for table_ref in scope {
        if table_ref.alias.eq_ignore_ascii_case(qualifier) {
            return ref_columns(table_ref, catalog);
        }
    }
    for table_ref in scope {
        if table_ref.alias.is_empty() && table_ref.name.eq_ignore_ascii_case(qualifier) {
            return ref_columns(table_ref, catalog);
        }
    }
    let table = find_table(catalog, qualifier)?;
    Some((table.name.clone(), table.columns.clone()))
}

/// 前一个有意义的 token 是 FROM / JOIN / UPDATE / INTO / TABLE，或者是 FROM 列表里的逗号
fn expects_table(before: &[&SqlToken], text_of: &dyn Fn(&SqlToken) -> String) -> bool {
    let Some(last) = before.last() else {
        return false;
    };
    let last_text = text_of(last).to_ascii_uppercase();
    if last.kind == SqlTokenKind::Keyword {
        return matches!(last_text.as_str(), "FROM" | "JOIN" | "UPDATE" | "INTO" | "TABLE" | "DESCRIBE");
    }
    if last_text != "," {
        return false;
    }
    // 逗号：往回找到同一层最近的子句关键字，是 FROM 才是在列表里写下一张表
    let mut depth = 0i32;
    for token in before.iter().rev().skip(1) {
        let text = text_of(token);
        match text.as_str() {
            ")" => depth += 1,
            "(" if depth == 0 => return false,
            "(" => depth -= 1,
            _ => {}
        }
        if depth == 0 && token.kind == SqlTokenKind::Keyword {
            let upper = text.to_ascii_uppercase();
            if is_clause_keyword(&upper) {
                return upper == "FROM";
            }
        }
    }
    false
}

fn is_clause_keyword(upper: &str) -> bool {
    matches!(
        upper,
        "SELECT" | "FROM" | "WHERE" | "ON" | "SET" | "GROUP" | "ORDER" | "HAVING" | "LIMIT" | "VALUES"
            | "JOIN" | "UPDATE" | "INTO" | "UNION" | "USING"
    )
}

/// 光标看得到的表：光标所在括号层及所有外层，里层在前。
/// 只收同一层的 FROM / JOIN / UPDATE / INTO 后面的表，更里层子查询的表不算
fn tables_in_scope(tokens: &[SqlToken], ctx: &Ctx) -> Vec<TableRef> {
    let text_of = ctx.text_of;
    let cursor = ctx.cursor;
    // 当前语句：光标前后最近的分号之间
    let mut start = 0;
    let mut end = tokens.len();
    for (index, token) in tokens.iter().enumerate() {
        if text_of(token) == ";" {
            if token.end <= cursor {
                start = index + 1;
            } else {
                end = index;
                break;
            }
        }
    }
    let statement = &tokens[start..end];

    // 每个 token 的括号层级，以及光标所在位置的「括号链」：从外到里每层左括号的下标
    let mut depths = Vec::with_capacity(statement.len());
    let mut open_stack: Vec<usize> = Vec::new();
    let mut cursor_chain: Option<Vec<usize>> = None;
    for (index, token) in statement.iter().enumerate() {
        if cursor_chain.is_none() && token.start >= cursor {
            cursor_chain = Some(open_stack.clone());
        }
        let text = text_of(token);
        if text == ")" {
            open_stack.pop();
        }
        depths.push(open_stack.len());
        if text == "(" {
            open_stack.push(index);
        }
    }
    let chain = cursor_chain.unwrap_or(open_stack);

    // 从里到外，每层的范围是那个左括号到它配对的右括号；最外层是整条语句
    let mut levels: Vec<(usize, usize, usize)> = Vec::new(); // (起, 止, 层级)
    for (level, &open) in chain.iter().enumerate().rev() {
        let depth = level + 1;
        let mut close = statement.len();
        for (index, token) in statement.iter().enumerate().skip(open + 1) {
            if depths[index] < depth || (text_of(token) == ")" && depths[index] == depth - 1) {
                close = index;
                break;
            }
        }
        levels.push((open + 1, close, depth));
    }
    levels.push((0, statement.len(), 0));

    let ctes = collect_ctes(statement, &depths, ctx);
    let mut refs = Vec::new();
    for (from, to, depth) in levels {
        collect_refs(&statement[from..to], &depths[from..to], depth, ctx, &ctes, &mut refs);
    }
    refs
}

/// 在一层里找 `FROM a [AS] x, b y JOIN c ON …` 这样的表引用
fn collect_refs(
    tokens: &[SqlToken],
    depths: &[usize],
    depth: usize,
    ctx: &Ctx,
    ctes: &[Cte],
    refs: &mut Vec<TableRef>,
) {
    let text_of = ctx.text_of;
    let mut expecting = false;
    let mut in_from_list = false;
    let mut i = 0;
    while i < tokens.len() {
        if depths[i] != depth {
            i += 1;
            continue;
        }
        let token = &tokens[i];
        let text = text_of(token);
        let upper = text.to_ascii_uppercase();

        if token.kind == SqlTokenKind::Keyword {
            if matches!(upper.as_str(), "FROM" | "JOIN" | "UPDATE" | "INTO") {
                expecting = true;
                in_from_list = upper == "FROM";
            } else if is_clause_keyword(&upper) {
                expecting = false;
                in_from_list = false;
            }
            i += 1;
            continue;
        }
        if text == "," && in_from_list {
            expecting = true;
            i += 1;
            continue;
        }
        // 派生表：FROM (SELECT …) [AS] x [(c1, c2)]
        if expecting && text == "(" {
            let close = matching_close(tokens, depths, i, depth, text_of);
            let inner = i + 1..close;
            if let Some(mut columns) = derived_columns(&tokens[inner.clone()], &depths[inner], depth + 1, ctx, ctes) {
                let mut next = close + 1;
                if tokens.get(next).is_some_and(|t| text_of(t).eq_ignore_ascii_case("AS")) {
                    next += 1;
                }
                let mut alias = String::new();
                if let Some(candidate) = tokens.get(next).filter(|t| is_name(t)) {
                    alias = unquote(&text_of(candidate));
                    next += 1;
                }
                if tokens.get(next).is_some_and(|t| text_of(t) == "(") {
                    let list_close = matching_close(tokens, depths, next, depth, text_of);
                    columns = names_in(&tokens[next + 1..list_close], text_of);
                    next = list_close + 1;
                }
                // 光标在这个子查询里面时，它自己的别名在里面是看不到的
                let cursor_inside = tokens[i].end <= ctx.cursor
                    && tokens.get(close).is_none_or(|t| ctx.cursor <= t.start);
                if !cursor_inside {
                    refs.push(TableRef { name: String::new(), alias, derived: Some(columns) });
                }
                expecting = false;
                i = next;
                continue;
            }
        }
        if !(expecting && is_name(token)) {
            i += 1;
            continue;
        }

        // 表名，可能带库名前缀：db.table
        let mut name = unquote(&text);
        let mut next = i + 1;
        let mut qualified = false;
        if tokens.get(next).is_some_and(|t| text_of(t) == ".")
            && tokens.get(next + 1).is_some_and(is_name)
        {
            name = unquote(&text_of(&tokens[next + 1]));
            next += 2;
            qualified = true;
        }
        // 不带库名时 CTE 优先于同名的表
        let mut derived = None;
        if !qualified {
            for cte in ctes {
                if cte.name.eq_ignore_ascii_case(&name) {
                    derived = Some(cte.columns.clone());
                    break;
                }
            }
        }
        // 别名：AS x 或直接跟一个不是关键字的名字
        let mut alias = String::new();
        if tokens.get(next).is_some_and(|t| text_of(t).eq_ignore_ascii_case("AS")) {
            next += 1;
        }
        if let Some(candidate) = tokens.get(next) {
            if is_name(candidate) {
                alias = unquote(&text_of(candidate));
                next += 1;
            }
        }
        refs.push(TableRef { name, alias, derived });
        expecting = false;
        i = next;
    }
}

/// open 处左括号配对的右括号下标；写了一半没闭合就是末尾
fn matching_close(
    tokens: &[SqlToken],
    depths: &[usize],
    open: usize,
    depth: usize,
    text_of: &dyn Fn(&SqlToken) -> String,
) -> usize {
    for index in open + 1..tokens.len() {
        if depths[index] == depth && text_of(&tokens[index]) == ")" {
            return index;
        }
    }
    tokens.len()
}

/// 括号里逗号分隔的名字列表，比如 CTE 和派生表后面写的列名
fn names_in(tokens: &[SqlToken], text_of: &dyn Fn(&SqlToken) -> String) -> Vec<String> {
    let mut names = Vec::new();
    for token in tokens {
        if is_name(token) {
            names.push(unquote(&text_of(token)));
        }
    }
    names
}

/// 语句开头 `WITH [RECURSIVE] a [(c1, c2)] AS (…), b AS (…)` 定义的 CTE。
/// 后面的 CTE 可以引用前面的，所以按顺序推
fn collect_ctes(statement: &[SqlToken], depths: &[usize], ctx: &Ctx) -> Vec<Cte> {
    let text_of = ctx.text_of;
    let mut ctes = Vec::new();
    let keyword_at = |index: usize, word: &str| {
        statement.get(index).is_some_and(|t| t.kind == SqlTokenKind::Keyword && text_of(t).eq_ignore_ascii_case(word))
    };
    if !keyword_at(0, "WITH") {
        return ctes;
    }
    let mut i = if keyword_at(1, "RECURSIVE") { 2 } else { 1 };

    while let Some(name_token) = statement.get(i).filter(|t| is_name(t)) {
        let name = unquote(&text_of(name_token));
        i += 1;

        let mut explicit = None;
        if statement.get(i).is_some_and(|t| text_of(t) == "(") {
            let close = matching_close(statement, depths, i, 0, text_of);
            explicit = Some(names_in(&statement[i + 1..close], text_of));
            i = close + 1;
        }
        if !keyword_at(i, "AS") || !statement.get(i + 1).is_some_and(|t| text_of(t) == "(") {
            break;
        }
        let open = i + 1;
        let close = matching_close(statement, depths, open, 0, text_of);
        let columns = match explicit {
            Some(columns) => columns,
            // 递归 CTE 的列名由第一段（非递归部分）决定，和普通子查询一样推
            None => derived_columns(&statement[open + 1..close], &depths[open + 1..close], 1, ctx, &ctes)
                .unwrap_or_default(),
        };
        ctes.push(Cte { name, columns });

        i = close + 1;
        if !statement.get(i).is_some_and(|t| text_of(t) == ",") {
            break;
        }
        i += 1;
    }
    ctes
}

/// 子查询的输出列名。tokens 是括号里面的部分，depth 是它们的层级。
/// 不是 SELECT（比如 `FROM (t1 JOIN t2)`）返回 None
fn derived_columns(
    tokens: &[SqlToken],
    depths: &[usize],
    depth: usize,
    ctx: &Ctx,
    ctes: &[Cte],
) -> Option<Vec<String>> {
    let text_of = ctx.text_of;
    let first = tokens.first()?;
    // ((SELECT …) UNION …)：列名由第一段决定
    if text_of(first) == "(" {
        let close = matching_close(tokens, depths, 0, depth, text_of);
        return derived_columns(&tokens[1..close], &depths[1..close], depth + 1, ctx, ctes);
    }
    if !(first.kind == SqlTokenKind::Keyword && text_of(first).eq_ignore_ascii_case("SELECT")) {
        return None;
    }

    // 只看第一段 SELECT：UNION 后面各段的列名不算数，来源表也不算
    let mut end = tokens.len();
    for index in 1..tokens.len() {
        if depths[index] == depth && text_of(&tokens[index]).eq_ignore_ascii_case("UNION") {
            end = index;
            break;
        }
    }

    // select 列表按本层的逗号切开，到本层的 FROM 之类子句关键字为止
    let mut items: Vec<Vec<&SqlToken>> = vec![Vec::new()];
    for index in 1..end {
        let token = &tokens[index];
        let upper = text_of(token).to_ascii_uppercase();
        if depths[index] == depth {
            if token.kind == SqlTokenKind::Keyword
                && matches!(upper.as_str(), "FROM" | "WHERE" | "GROUP" | "HAVING" | "ORDER" | "LIMIT" | "INTO" | "WINDOW")
            {
                break;
            }
            if upper == "," {
                items.push(Vec::new());
                continue;
            }
            // SELECT DISTINCT a：修饰词不是列
            if items.len() == 1 && items[0].is_empty() && matches!(upper.as_str(), "DISTINCT" | "ALL") {
                continue;
            }
        }
        items.last_mut().unwrap().push(token);
    }

    let mut sources: Option<Vec<TableRef>> = None;
    let mut columns: Vec<String> = Vec::new();
    for item in &items {
        let names = match item_output(item, text_of) {
            ItemOutput::Name(name) => vec![name],
            ItemOutput::Star(qualifier) => {
                // `*` 才需要知道来源表，用到时再找
                let sources = sources.get_or_insert_with(|| {
                    let mut refs = Vec::new();
                    collect_refs(&tokens[..end], &depths[..end], depth, ctx, ctes, &mut refs);
                    refs
                });
                star_columns(sources, qualifier.as_deref(), ctx.catalog)
            }
            ItemOutput::Unknown => Vec::new(),
        };
        for name in names {
            if !columns.iter().any(|c| c.eq_ignore_ascii_case(&name)) {
                columns.push(name);
            }
        }
    }
    Some(columns)
}

/// select 列表里一项的输出列
enum ItemOutput {
    Name(String),
    /// `*` 或 `t.*`
    Star(Option<String>),
    /// 没有别名的表达式，MySQL 拿表达式原文当列名，不猜
    Unknown,
}

fn item_output(item: &[&SqlToken], text_of: &dyn Fn(&SqlToken) -> String) -> ItemOutput {
    let Some(last) = item.last() else {
        return ItemOutput::Unknown;
    };
    let count = item.len();
    let last_text = text_of(last);

    // expr AS alias，别名也可以写成字符串：AS 'x'
    if count >= 3 && text_of(item[count - 2]).eq_ignore_ascii_case("AS") {
        if is_name(last) {
            return ItemOutput::Name(unquote(&last_text));
        }
        if last.kind == SqlTokenKind::String {
            return match unquote_string(&last_text) {
                Some(name) => ItemOutput::Name(name),
                None => ItemOutput::Unknown,
            };
        }
        return ItemOutput::Unknown;
    }

    if last_text == "*" {
        return match item {
            [_] => ItemOutput::Star(None),
            [table, dot, _] if is_name(table) && text_of(dot) == "." => ItemOutput::Star(Some(unquote(&text_of(table)))),
            [_, first_dot, table, dot, _] if text_of(first_dot) == "." && is_name(table) && text_of(dot) == "." => {
                ItemOutput::Star(Some(unquote(&text_of(table))))
            }
            _ => ItemOutput::Unknown,
        };
    }

    // 普通列：a、t.a、db.t.a
    let mut plain = count % 2 == 1;
    for (index, token) in item.iter().enumerate() {
        let ok = if index % 2 == 0 { is_name(token) } else { text_of(token) == "." };
        plain = plain && ok;
    }
    if plain {
        return ItemOutput::Name(unquote(&last_text));
    }

    // 省略 AS 的别名：COUNT(*) cnt、t.b c、'x' c。前面是运算符（a + b）或关键字（a DIV b）
    // 时最后那个名字是表达式的一部分，不是别名；CASE … END x 例外
    if count >= 2 && is_name(last) {
        let prev = item[count - 2];
        let prev_text = text_of(prev);
        let is_expression_tail = prev_text == "."
            || prev.kind == SqlTokenKind::Operator
            || (prev.kind == SqlTokenKind::Keyword && !prev_text.eq_ignore_ascii_case("END"));
        if !is_expression_tail {
            return ItemOutput::Name(unquote(&last_text));
        }
    }
    ItemOutput::Unknown
}

/// `*` 展开成来源表的列；`t.*` 只展开 t。来源表不在目录里就少那一截，不编
fn star_columns(sources: &[TableRef], qualifier: Option<&str>, catalog: &Catalog) -> Vec<String> {
    let mut columns = Vec::new();
    for source in sources {
        if let Some(qualifier) = qualifier {
            let label = if source.alias.is_empty() { &source.name } else { &source.alias };
            if !label.eq_ignore_ascii_case(qualifier) {
                continue;
            }
        }
        if let Some((_, source_columns)) = ref_columns(source, catalog) {
            columns.extend(source_columns);
        }
    }
    columns
}

/// 字符串写的别名：'x'、"x"。带反斜杠的转义随 sql_mode 变，不猜
fn unquote_string(text: &str) -> Option<String> {
    let quote = text.chars().next()?;
    if !matches!(quote, '\'' | '"') || text.len() < 2 || !text.ends_with(quote) || text.contains('\\') {
        return None;
    }
    let inner = &text[1..text.len() - 1];
    Some(inner.replace(&format!("{quote}{quote}"), &quote.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn catalog() -> Catalog {
        Catalog {
            tables: vec![
                CatalogTable { name: "orders".into(), columns: vec!["id".into(), "user_id".into(), "amount".into()] },
                CatalogTable { name: "users".into(), columns: vec!["id".into(), "name".into(), "order".into()] },
                CatalogTable { name: "用户表".into(), columns: vec!["昵称".into()] },
            ],
        }
    }

    /// `|` 标出光标位置
    fn at(sql_with_cursor: &str) -> Completion {
        let cursor = sql_with_cursor.find('|').expect("要标出光标");
        let sql = sql_with_cursor.replacen('|', "", 1);
        let cursor16 = sql[..cursor].encode_utf16().count() as u32;
        complete(&sql, cursor16, &catalog())
    }

    fn labels(completion: &Completion) -> Vec<String> {
        let mut out = Vec::new();
        for item in &completion.items {
            out.push(item.label.clone());
        }
        out
    }

    #[test]
    fn tables_after_from_and_join() {
        assert_eq!(labels(&at("SELECT * FROM |")), ["orders", "users", "用户表"]);
        assert_eq!(labels(&at("SELECT * FROM orders o JOIN us|")), ["users"]);
        assert_eq!(labels(&at("SELECT * FROM orders, u|")), ["users"], "FROM 列表里逗号后面也是表");
    }

    #[test]
    fn comma_in_select_list_is_not_a_table_position() {
        let completion = at("SELECT id, | FROM orders");
        assert_eq!(completion.items[0].label, "id");
        assert_eq!(completion.items[0].kind, CompletionKind::Column);
    }

    #[test]
    fn alias_dot_completes_that_tables_columns() {
        assert_eq!(labels(&at("SELECT u.| FROM orders o JOIN users AS u ON u.id = o.user_id")), ["id", "name", "order"]);
        assert_eq!(labels(&at("SELECT o.am| FROM orders o")), ["amount"]);
        // 没写别名时用表名限定也行
        assert_eq!(labels(&at("SELECT users.n| FROM users")), ["name"]);
    }

    #[test]
    fn unqualified_columns_come_from_tables_in_scope() {
        let completion = at("SELECT | FROM orders o JOIN users u ON 1");
        let items = &completion.items;
        assert_eq!(items[0].label, "id");
        assert_eq!(items[0].detail, "orders");
        // 同名列只出一次，后面是另一张表独有的列
        assert_eq!(labels(&completion)[..5], ["id", "user_id", "amount", "name", "order"]);

        // 带前缀时别名和关键字也在：u 开头的有列 user_id、别名 u、关键字 UNION 等
        let prefixed = at("SELECT u| FROM orders o JOIN users u ON 1");
        assert_eq!(prefixed.items[0].label, "user_id");
        assert!(prefixed.items.iter().any(|i| i.kind == CompletionKind::Alias && i.label == "u"));
        assert!(prefixed.items.iter().any(|i| i.kind == CompletionKind::Keyword && i.label == "UNION"));
    }

    #[test]
    fn subquery_sees_outer_aliases_but_not_the_other_way_round() {
        // 相关子查询里：自己的 users 和外层的 orders 都看得到
        let inner = at("SELECT * FROM orders o WHERE EXISTS (SELECT 1 FROM users u WHERE u.id = o.| )");
        assert_eq!(labels(&inner), ["id", "user_id", "amount"]);

        // 外层看不到子查询里的别名 u，u. 解析不出来
        let outer = at("SELECT u.| FROM orders o WHERE o.user_id IN (SELECT id FROM users u)");
        assert!(outer.items.is_empty(), "{:?}", labels(&outer));
    }

    #[test]
    fn only_the_current_statement_counts() {
        let completion = at("SELECT * FROM users; SELECT | FROM orders");
        assert_eq!(completion.items[0].detail, "orders");
        assert!(!completion.items.iter().any(|i| i.detail == "users"));
    }

    #[test]
    fn replaces_the_whole_word_under_the_cursor() {
        let completion = at("SELECT * FROM us|ers_old");
        assert_eq!(completion.replace_start, 14);
        assert_eq!(completion.replace_end, 23);
        assert_eq!(labels(&completion), ["users"]);
    }

    #[test]
    fn names_that_need_quoting_are_quoted() {
        let completion = at("SELECT u.or| FROM users u");
        assert_eq!(completion.items[0].insert_text, "`order`", "撞关键字要加反引号");
        let chinese = at("SELECT * FROM 用|");
        assert_eq!(chinese.items[0].insert_text, "`用户表`");
        let keyword = at("SEL|");
        assert_eq!(keyword.items[0].insert_text, "SELECT");
    }

    #[test]
    fn nothing_inside_strings_and_comments() {
        assert!(at("SELECT 'FROM |' FROM orders").items.is_empty());
        assert!(at("SELECT 1 -- FROM |").items.is_empty());
        assert!(at("SELECT 'FROM |").items.is_empty(), "写了一半的字符串");
        assert!(at("SELECT /* FROM |").items.is_empty(), "没闭合的块注释");
        // 闭合的块注释后面照常补全
        assert_eq!(labels(&at("SELECT * FROM /* 表 */|")), ["orders", "users", "用户表"]);
    }

    #[test]
    fn schema_qualified_table_and_quoted_alias() {
        assert_eq!(labels(&at("SELECT `x`.| FROM shop.orders AS `x`")), ["id", "user_id", "amount"]);
        assert_eq!(labels(&at("SELECT o.| FROM orders /* 订单 */ o")), ["id", "user_id", "amount"]);
    }

    #[test]
    fn utf16_positions_with_chinese_before_the_cursor() {
        let completion = at("SELECT '中文', 昵| FROM 用户表");
        assert_eq!(labels(&completion), ["昵称"]);
        assert_eq!(completion.replace_start, 13);
        assert_eq!(completion.replace_end, 14);
    }

    #[test]
    fn derived_table_columns_come_from_its_select_list() {
        // 别名优先，普通列用列名；来源表不在目录里也推得出来
        assert_eq!(labels(&at("SELECT x.| FROM (SELECT a, b AS c FROM t) AS x")), ["a", "c"]);
        let completion = at("SELECT x.| FROM (SELECT id, amount AS total FROM orders) AS x");
        assert_eq!(labels(&completion), ["id", "total"]);
        assert_eq!(completion.items[0].detail, "x");
        // 不写 AS、限定列名、反引号别名
        assert_eq!(labels(&at("SELECT x.| FROM (SELECT o.user_id, o.amount `金额` FROM orders o) x")), ["user_id", "金额"]);
    }

    #[test]
    fn expressions_without_alias_give_no_candidate() {
        let completion = at("SELECT x.| FROM (SELECT id + 1, COUNT(*), amount * 2 AS double_amount, SUM(amount) s FROM orders) x");
        assert_eq!(labels(&completion), ["double_amount", "s"], "没别名的表达式不能编个名字出来");
        // a DIV b 里的 b 不是别名；CASE … END 后面的是
        let completion = at("SELECT x.| FROM (SELECT id DIV user_id, CASE WHEN id THEN 1 END flag FROM orders) x");
        assert_eq!(labels(&completion), ["flag"]);
    }

    #[test]
    fn star_in_derived_table_expands_the_source_tables() {
        assert_eq!(labels(&at("SELECT x.| FROM (SELECT * FROM orders) x")), ["id", "user_id", "amount"]);
        // t.* 只展开那一张；同名列只出一次
        assert_eq!(
            labels(&at("SELECT x.| FROM (SELECT u.*, o.amount FROM orders o JOIN users u ON 1) x")),
            ["id", "name", "order", "amount"]
        );
        // 来源不在目录里就少那一截，不编
        assert_eq!(labels(&at("SELECT x.| FROM (SELECT *, 1 AS one FROM nowhere) x")), ["one"]);
    }

    #[test]
    fn derived_tables_nest_and_show_up_unqualified() {
        let sql = "SELECT x.| FROM (SELECT * FROM (SELECT id AS inner_id FROM orders) y) x";
        assert_eq!(labels(&at(sql)), ["inner_id"]);

        let completion = at("SELECT | FROM (SELECT id, name AS who FROM users) AS x");
        assert_eq!(labels(&completion)[..2], ["id", "who"]);
        assert!(completion.items.iter().any(|i| i.kind == CompletionKind::Alias && i.label == "x" && i.detail == "子查询"));
    }

    #[test]
    fn derived_table_with_column_list_and_union() {
        assert_eq!(labels(&at("SELECT x.| FROM (SELECT id, amount FROM orders) AS x (a, b)")), ["a", "b"]);
        // UNION 的列名由第一段决定
        assert_eq!(labels(&at("SELECT x.| FROM (SELECT id AS k FROM orders UNION SELECT name FROM users) x")), ["k"]);
    }

    #[test]
    fn inside_a_derived_table_its_own_alias_is_not_visible() {
        let completion = at("SELECT * FROM (SELECT | FROM users) x");
        assert_eq!(completion.items[0].detail, "users");
        assert!(!completion.items.iter().any(|i| i.label == "x"), "{:?}", labels(&completion));
        // 里面照样能用自己的表
        assert_eq!(labels(&at("SELECT * FROM (SELECT u.| FROM users u) x")), ["id", "name", "order"]);
    }

    #[test]
    fn cte_columns() {
        let sql = "WITH big AS (SELECT id, amount AS total FROM orders WHERE amount > 10) SELECT big.| FROM big";
        assert_eq!(labels(&at(sql)), ["id", "total"]);
        // 显式列名、后一个 CTE 引用前一个、给 CTE 起别名
        let sql = "WITH RECURSIVE a (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM a), \
                   b AS (SELECT a.*, 2 AS two FROM a) SELECT q.| FROM b q";
        assert_eq!(labels(&at(sql)), ["n", "two"]);
        // CTE 和真表同名时 CTE 优先
        assert_eq!(labels(&at("WITH orders AS (SELECT 1 AS z) SELECT orders.| FROM orders")), ["z"]);
        // 不带限定时 CTE 的列也在候选里
        assert_eq!(labels(&at("WITH big AS (SELECT amount AS total FROM orders) SELECT t| FROM big"))[0], "total");
    }
}
