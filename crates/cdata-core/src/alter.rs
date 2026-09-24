//! 表结构编辑：把界面攒下的一批改动和原结构比对，生成 ALTER TABLE。
//!
//! 界面用 `table_draft` 把读到的结构转成草稿，改完整份交回来，这里做比对。
//! 改列时整列定义从草稿重新渲染；草稿是从原定义来的，没动过的字符集、注释、默认值
//! 原样带上，不会被 MODIFY 悄悄重置。没把握原样重建的列和索引（生成列、不可见列、
//! 函数索引……）标成锁定，只能删除或改名，不能改定义。

use std::collections::{HashMap, HashSet};

use mysql_async::prelude::Queryable;
use mysql_async::Conn;
use serde::{Deserialize, Serialize};

use crate::sql::quote_ident;
use crate::structure::{ColumnDef, DefaultValue, ForeignKeyDef, IndexDef, IndexPart, TableStructure};

/// 可编辑的一列
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ColumnDraft {
    /// 原来的列名。新加的列是 None
    pub original_name: Option<String>,
    pub name: String,
    pub column_type: String,
    pub nullable: bool,
    pub default: DefaultValue,
    pub auto_increment: bool,
    /// ON UPDATE 后面的表达式，MySQL 只认 CURRENT_TIMESTAMP[(n)]
    pub on_update: Option<String>,
    pub comment: String,
    /// None 表示用表的默认排序规则
    pub collation: Option<String>,
    /// 为什么这一列没法原样重建。锁住的列只能删除或改名
    pub locked: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum IndexKind {
    Primary,
    Unique,
    /// 普通索引
    Normal,
    Fulltext,
    Spatial,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct IndexDraft {
    pub original_name: Option<String>,
    /// 主键固定叫 PRIMARY，改名无效
    pub name: String,
    pub kind: IndexKind,
    /// 列名是草稿里的新列名
    pub parts: Vec<IndexPart>,
    pub comment: String,
    /// 为什么这个索引没法原样重建。锁住的索引只能删除或改名
    pub locked: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ForeignKeyDraft {
    pub original_name: Option<String>,
    pub name: String,
    pub columns: Vec<String>,
    pub referenced_schema: String,
    pub referenced_table: String,
    pub referenced_columns: Vec<String>,
    pub on_update: String,
    pub on_delete: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TableDraft {
    pub columns: Vec<ColumnDraft>,
    pub indexes: Vec<IndexDraft>,
    pub foreign_keys: Vec<ForeignKeyDraft>,
}

/// 要执行的语句和执行前必须让用户看到的提示
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AlterPlan {
    pub statements: Vec<String>,
    /// 可能丢数据、丢约束的操作，界面要醒目标出
    pub dangers: Vec<String>,
    /// 隐式提交、分几条执行、失败时哪些已生效
    pub notes: Vec<String>,
}

const TEXT_TYPES: &[&str] = &["char", "varchar", "tinytext", "text", "mediumtext", "longtext", "enum", "set"];
const FK_ACTIONS: &[&str] = &["RESTRICT", "CASCADE", "SET NULL", "NO ACTION", "SET DEFAULT"];

/// 读到的结构转成草稿。锁定原因在这里一次定下来
pub fn table_draft(structure: &TableStructure) -> TableDraft {
    let table_collation = structure.table_collation.as_deref();
    TableDraft {
        columns: structure.columns.iter().map(|column| column_draft(column, table_collation)).collect(),
        indexes: structure.indexes.iter().map(|index| index_draft(index, &structure.create_sql)).collect(),
        foreign_keys: structure.foreign_keys.iter().map(foreign_key_draft).collect(),
    }
}

fn column_draft(column: &ColumnDef, table_collation: Option<&str>) -> ColumnDraft {
    let mut draft = ColumnDraft {
        original_name: Some(column.name.clone()),
        name: column.name.clone(),
        column_type: column.column_type.clone(),
        nullable: column.nullable,
        default: column.default.clone(),
        auto_increment: false,
        on_update: None,
        comment: column.comment.clone(),
        collation: column.collation.clone(),
        locked: None,
    };
    match parse_extra(&column.extra) {
        Ok((auto_increment, on_update)) => {
            draft.auto_increment = auto_increment;
            draft.on_update = on_update;
        }
        Err(reason) => {
            draft.locked = Some(reason);
            return draft;
        }
    }
    // 渲染不出来的原定义，改了也写不回去
    if let Err(reason) = column_definition(&draft, table_collation, false) {
        draft.locked = Some(reason);
    }
    draft
}

/// EXTRA 里认得的只有这几样；生成列、INVISIBLE、SRID 之类都不认，整列锁住
fn parse_extra(extra: &str) -> Result<(bool, Option<String>), String> {
    let words: Vec<&str> = extra.split_whitespace().collect();
    let mut auto_increment = false;
    let mut on_update = None;
    let mut i = 0;
    while i < words.len() {
        let word = words[i];
        if word.eq_ignore_ascii_case("auto_increment") {
            auto_increment = true;
            i += 1;
        } else if word.eq_ignore_ascii_case("DEFAULT_GENERATED") {
            // 表达式默认值的标记，DefaultValue::Expression 已经表达了
            i += 1;
        } else if word.eq_ignore_ascii_case("on")
            && i + 2 < words.len()
            && words[i + 1].eq_ignore_ascii_case("update")
        {
            on_update = Some(words[i + 2].to_string());
            i += 3;
        } else {
            return Err(format!("列属性「{extra}」没法原样重建（生成列、不可见列等），只能删除或改名"));
        }
    }
    Ok((auto_increment, on_update))
}

fn index_draft(index: &IndexDef, create_sql: &str) -> IndexDraft {
    let kind = if index.name == "PRIMARY" {
        IndexKind::Primary
    } else if index.index_type == "FULLTEXT" {
        IndexKind::Fulltext
    } else if index.index_type == "SPATIAL" {
        IndexKind::Spatial
    } else if index.unique {
        IndexKind::Unique
    } else {
        IndexKind::Normal
    };

    let mut locked = None;
    if !matches!(index.index_type.as_str(), "BTREE" | "FULLTEXT" | "SPATIAL") {
        locked = Some(format!("索引类型 {} 没法原样重建，只能删除或改名", index.index_type));
    } else if index.parts.iter().any(|part| part.column.is_none()) {
        locked = Some("函数索引读不到表达式，没法原样重建，只能删除或改名".to_string());
    } else if index_line_has_version_comment(create_sql, &index.name) {
        // SHOW CREATE 里 INVISIBLE、WITH PARSER 这些都写在 /*!… */ 里，information_schema 读不全
        locked = Some("索引带有 INVISIBLE / WITH PARSER 之类的属性，没法原样重建，只能删除或改名".to_string());
    }

    IndexDraft {
        original_name: Some(index.name.clone()),
        name: index.name.clone(),
        kind,
        parts: index.parts.clone(),
        comment: index.comment.clone(),
        locked,
    }
}

fn index_line_has_version_comment(create_sql: &str, name: &str) -> bool {
    let marker = format!("KEY {} (", quote_ident(name));
    create_sql.lines().any(|line| line.contains(&marker) && line.contains("/*!"))
}

fn foreign_key_draft(fk: &ForeignKeyDef) -> ForeignKeyDraft {
    ForeignKeyDraft {
        original_name: Some(fk.name.clone()),
        name: fk.name.clone(),
        columns: fk.columns.clone(),
        referenced_schema: fk.referenced_schema.clone(),
        referenced_table: fk.referenced_table.clone(),
        referenced_columns: fk.referenced_columns.clone(),
        on_update: fk.on_update.clone(),
        on_delete: fk.on_delete.clone(),
    }
}

/// 结构编辑要求 MySQL 8.0.13+：更早的版本没有 DEFAULT_GENERATED 标记，CURRENT_TIMESTAMP
/// 默认值读出来和字面量分不开；MariaDB 的 COLUMN_DEFAULT 规则也不一样。拿不准就不做
pub fn supports_alter(version: &str) -> bool {
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
    (major, minor, patch) >= (8, 0, 13)
}

/// 字符串字面量。单引号双写在哪种 sql_mode 下都对；反斜杠只有没开 NO_BACKSLASH_ESCAPES 时才要双写，
/// 所以要按执行这条语句的连接的 sql_mode 生成
fn sql_string(text: &str, no_backslash_escapes: bool) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('\'');
    for ch in text.chars() {
        match ch {
            '\'' => out.push_str("''"),
            '\\' if !no_backslash_escapes => out.push_str("\\\\"),
            other => out.push(other),
        }
    }
    out.push('\'');
    out
}

/// 类型、表达式默认值这类原样拼进 DDL 的片段：只许在括号和引号里出现逗号，
/// 不许有分号、注释、反斜杠，免得一个类型写出第二个子句来
fn check_fragment(text: &str, what: &str) -> Result<(), String> {
    if text.trim().is_empty() {
        return Err(format!("{what}不能为空"));
    }
    if text.contains('\\') {
        return Err(format!("{what}「{text}」里有反斜杠：它的含义随 NO_BACKSLASH_ESCAPES 变，没法保证照原样执行"));
    }
    let chars: Vec<char> = text.chars().collect();
    let mut depth = 0;
    let mut i = 0;
    while i < chars.len() {
        let ch = chars[i];
        match ch {
            '\'' | '"' | '`' => {
                // 引号里的同种引号双写
                let mut j = i + 1;
                loop {
                    if j >= chars.len() {
                        return Err(format!("{what}「{text}」里的引号没有闭合"));
                    }
                    if chars[j] == ch {
                        if chars.get(j + 1) == Some(&ch) {
                            j += 2;
                            continue;
                        }
                        break;
                    }
                    j += 1;
                }
                i = j;
            }
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if depth < 0 {
                    return Err(format!("{what}「{text}」的括号不配对"));
                }
            }
            ',' if depth == 0 => return Err(format!("{what}「{text}」里有括号外的逗号")),
            ';' | '#' => return Err(format!("{what}「{text}」里不能有 {ch}")),
            '-' if chars.get(i + 1) == Some(&'-') => return Err(format!("{what}「{text}」里不能有注释")),
            '/' if chars.get(i + 1) == Some(&'*') => return Err(format!("{what}「{text}」里不能有注释")),
            _ => {}
        }
        i += 1;
    }
    if depth != 0 {
        return Err(format!("{what}「{text}」的括号不配对"));
    }
    Ok(())
}

/// `varchar(20)` → `varchar`
fn base_type(column_type: &str) -> String {
    let trimmed = column_type.trim();
    let end = trimmed.find(|c: char| c == '(' || c.is_whitespace()).unwrap_or(trimmed.len());
    trimmed[..end].to_ascii_lowercase()
}

/// `varchar(20)` → 20。只认括号里就一个数的
fn type_length(column_type: &str) -> Option<u64> {
    let open = column_type.find('(')?;
    let close = column_type[open..].find(')')? + open;
    column_type[open + 1..close].trim().parse().ok()
}

fn is_current_timestamp(expression: &str) -> bool {
    let upper = expression.trim().to_ascii_uppercase();
    let Some(rest) = upper.strip_prefix("CURRENT_TIMESTAMP") else {
        return false;
    };
    if rest.is_empty() {
        return true;
    }
    let Some(inner) = rest.strip_prefix('(').and_then(|r| r.strip_suffix(')')) else {
        return false;
    };
    inner.chars().all(|c| c.is_ascii_digit())
}

/// 可空列没有「无默认值」这一说：不写 DEFAULT 就是 DEFAULT NULL
fn effective_default(column: &ColumnDraft) -> DefaultValue {
    if column.nullable && column.default == DefaultValue::NoDefault {
        return DefaultValue::Null;
    }
    column.default.clone()
}

/// 没写排序规则的字符串列用表的默认值
fn effective_collation(column: &ColumnDraft, table_collation: Option<&str>) -> Option<String> {
    if column.collation.is_some() {
        return column.collation.clone();
    }
    if TEXT_TYPES.contains(&base_type(&column.column_type).as_str()) {
        return table_collation.map(str::to_string);
    }
    None
}

/// 一列的完整定义，不含列名和位置。
///
/// 排序规则和表默认相同时不写 COLLATE：写了的话 MySQL 会把这一列记成「显式指定字符集」，
/// SHOW CREATE 从此多出一段 CHARACTER SET，真库测试踩到过
fn column_definition(
    column: &ColumnDraft,
    table_collation: Option<&str>,
    no_backslash_escapes: bool,
) -> Result<String, String> {
    check_fragment(&column.column_type, "类型")?;
    let base = base_type(&column.column_type);
    let mut sql = column.column_type.trim().to_string();

    let explicit_collation = column.collation.as_deref().filter(|collation| Some(*collation) != table_collation);
    if let Some(collation) = explicit_collation {
        if !TEXT_TYPES.contains(&base.as_str()) {
            return Err(format!(
                "列 {}：{base} 不是字符串类型，不能指定排序规则 {collation}，请清空排序规则",
                column.name
            ));
        }
        if collation.is_empty() || !collation.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
            return Err(format!("列 {}：排序规则「{collation}」不合法", column.name));
        }
        sql.push_str(" COLLATE ");
        sql.push_str(collation);
    }

    sql.push_str(if column.nullable { " NULL" } else { " NOT NULL" });

    match effective_default(column) {
        DefaultValue::NoDefault => {}
        DefaultValue::Null => {
            if !column.nullable {
                return Err(format!("列 {} 是 NOT NULL，默认值不能是 NULL", column.name));
            }
            sql.push_str(" DEFAULT NULL");
        }
        DefaultValue::Literal(value) => {
            // information_schema 里 BIT 的默认值是 b'101'，BINARY 的补了 \0，都不是原始值
            if matches!(base.as_str(), "bit" | "binary" | "varbinary") {
                return Err(format!(
                    "列 {}：{base} 列的字面量默认值读出来不是原始字节，没法可靠地写回，只能删除或改名",
                    column.name
                ));
            }
            sql.push_str(" DEFAULT ");
            sql.push_str(&sql_string(&value, no_backslash_escapes));
        }
        DefaultValue::Expression(expression) => {
            // information_schema 里表达式中的引号被写成 \'，照抄回去是错的，check_fragment 会拒绝
            check_fragment(&expression, "默认值表达式")?;
            // CURRENT_TIMESTAMP 是时间类型的专用写法，其余表达式要带括号（8.0.13+）
            if is_current_timestamp(&expression) {
                sql.push_str(" DEFAULT ");
                sql.push_str(expression.trim());
            } else {
                sql.push_str(&format!(" DEFAULT ({})", expression.trim()));
            }
        }
    }

    if column.auto_increment {
        sql.push_str(" AUTO_INCREMENT");
    }
    if let Some(on_update) = &column.on_update {
        if !is_current_timestamp(on_update) {
            return Err(format!("列 {}：ON UPDATE 只能是 CURRENT_TIMESTAMP[(n)]", column.name));
        }
        sql.push_str(" ON UPDATE ");
        sql.push_str(on_update.trim());
    }
    if !column.comment.is_empty() {
        sql.push_str(" COMMENT ");
        sql.push_str(&sql_string(&column.comment, no_backslash_escapes));
    }
    Ok(sql)
}

/// 比较定义时忽略名字、身份和锁定标记，默认值、排序规则按生效的比
fn same_definition(a: &ColumnDraft, b: &ColumnDraft, table_collation: Option<&str>) -> bool {
    a.column_type.trim() == b.column_type.trim()
        && a.nullable == b.nullable
        && effective_default(a) == effective_default(b)
        && a.auto_increment == b.auto_increment
        && a.on_update == b.on_update
        && a.comment == b.comment
        && effective_collation(a, table_collation) == effective_collation(b, table_collation)
}

/// 最长递增子序列：留在原位的列尽量多，只有其余的列需要 FIRST / AFTER
fn keep_in_place(positions: &[usize]) -> Vec<bool> {
    let n = positions.len();
    let mut length = vec![1usize; n];
    let mut previous = vec![usize::MAX; n];
    for i in 0..n {
        for j in 0..i {
            if positions[j] < positions[i] && length[j] + 1 > length[i] {
                length[i] = length[j] + 1;
                previous[i] = j;
            }
        }
    }
    let mut keep = vec![false; n];
    let Some(mut at) = (0..n).max_by_key(|&i| length[i]) else {
        return keep;
    };
    loop {
        keep[at] = true;
        if previous[at] == usize::MAX {
            break;
        }
        at = previous[at];
    }
    keep
}

fn index_parts_sql(name: &str, parts: &[IndexPart]) -> Result<String, String> {
    let mut rendered = Vec::with_capacity(parts.len());
    for part in parts {
        let Some(column) = &part.column else {
            return Err(format!("索引 {name} 有一段没有列名，函数索引请用 SQL 修改"));
        };
        let mut text = quote_ident(column);
        if let Some(length) = part.prefix {
            text.push_str(&format!("({length})"));
        }
        if part.descending {
            text.push_str(" DESC");
        }
        rendered.push(text);
    }
    Ok(format!("({})", rendered.join(", ")))
}

fn add_index_sql(index: &IndexDraft, no_backslash_escapes: bool) -> Result<String, String> {
    let parts = index_parts_sql(&index.name, &index.parts)?;
    let mut sql = match index.kind {
        IndexKind::Primary => format!("ADD PRIMARY KEY {parts}"),
        IndexKind::Unique => format!("ADD UNIQUE INDEX {} {parts}", quote_ident(&index.name)),
        IndexKind::Normal => format!("ADD INDEX {} {parts}", quote_ident(&index.name)),
        IndexKind::Fulltext => format!("ADD FULLTEXT INDEX {} {parts}", quote_ident(&index.name)),
        IndexKind::Spatial => format!("ADD SPATIAL INDEX {} {parts}", quote_ident(&index.name)),
    };
    if !index.comment.is_empty() {
        sql.push_str(" COMMENT ");
        sql.push_str(&sql_string(&index.comment, no_backslash_escapes));
    }
    Ok(sql)
}

fn drop_index_sql(name: &str) -> String {
    if name == "PRIMARY" {
        "DROP PRIMARY KEY".to_string()
    } else {
        format!("DROP INDEX {}", quote_ident(name))
    }
}

fn idents(names: &[String]) -> String {
    let quoted: Vec<String> = names.iter().map(|name| quote_ident(name)).collect();
    quoted.join(", ")
}

fn add_foreign_key_sql(fk: &ForeignKeyDraft) -> String {
    format!(
        "ADD CONSTRAINT {} FOREIGN KEY ({}) REFERENCES {}.{} ({}) ON DELETE {} ON UPDATE {}",
        quote_ident(&fk.name),
        idents(&fk.columns),
        quote_ident(&fk.referenced_schema),
        quote_ident(&fk.referenced_table),
        idents(&fk.referenced_columns),
        fk.on_delete,
        fk.on_update,
    )
}

/// 类型变化的提示。同一种字符串类型加长是安全的，缩短和换类型都可能截断或转换失败
fn type_change_danger(name: &str, old_type: &str, new_type: &str) -> Option<String> {
    if old_type.trim().eq_ignore_ascii_case(new_type.trim()) {
        return None;
    }
    let old_base = base_type(old_type);
    let same_family = old_base == base_type(new_type) && matches!(old_base.as_str(), "char" | "varchar" | "binary" | "varbinary");
    if same_family {
        if let (Some(old_length), Some(new_length)) = (type_length(old_type), type_length(new_type)) {
            if new_length >= old_length {
                return None;
            }
            return Some(format!(
                "列 {name} 长度 {old_length} → {new_length}：超长的值会被截断（严格模式下这次 ALTER 会报错失败）"
            ));
        }
    }
    Some(format!("列 {name} 类型 {old_type} → {new_type}：已有的值可能被截断、舍入或转换失败"))
}

fn lower(name: &str) -> String {
    name.to_lowercase()
}

/// 比对原结构和草稿，生成 ALTER TABLE。
///
/// 能合成一条就合成一条：InnoDB 的一条 ALTER 要么全部生效要么都不生效。
/// 只有删掉又加回同名外键时被迫拆成两条，MySQL 不允许在同一条里做（报 1826）。
///
/// 返回的第二项是「可空改成 NOT NULL」的列（原列名），调用方要去数一数现有的 NULL。
/// no_backslash_escapes 要取自执行这些语句的那条连接
pub fn plan_alter(
    schema: &str,
    table: &str,
    original: &TableStructure,
    draft: &TableDraft,
    no_backslash_escapes: bool,
) -> Result<(AlterPlan, Vec<String>), String> {
    let nbe = no_backslash_escapes;
    let table_collation = original.table_collation.as_deref();
    let original_drafts = table_draft(original);

    // ---- 列 ----
    if draft.columns.is_empty() {
        return Err("表至少要留一列".to_string());
    }
    let mut original_columns: HashMap<&str, &ColumnDraft> = HashMap::new();
    for column in &original_drafts.columns {
        original_columns.insert(column.name.as_str(), column);
    }

    let mut seen_names = HashSet::new();
    let mut used_originals = HashSet::new();
    // 原列名 → 新列名，索引和外键比对时用
    let mut renames: HashMap<String, String> = HashMap::new();
    let mut draft_names = HashSet::new();
    for column in &draft.columns {
        if column.name.trim().is_empty() {
            return Err("有一列没有名字".to_string());
        }
        if !seen_names.insert(lower(&column.name)) {
            return Err(format!("列名 {} 重复了（MySQL 的列名不区分大小写）", column.name));
        }
        draft_names.insert(lower(&column.name));
        if let Some(original_name) = &column.original_name {
            if !original_columns.contains_key(original_name.as_str()) {
                return Err(format!("原表里没有列 {original_name}，请重新打开编辑器"));
            }
            if !used_originals.insert(original_name.clone()) {
                return Err(format!("原来的列 {original_name} 在草稿里出现了两次"));
            }
            renames.insert(original_name.clone(), column.name.clone());
        }
    }

    // 留下来的老列，按草稿顺序排它们原来的位置
    let mut existing_positions = Vec::new();
    for column in &draft.columns {
        if let Some(original_name) = &column.original_name {
            let position = original_drafts
                .columns
                .iter()
                .position(|c| &c.name == original_name)
                .expect("上面刚校验过原列名存在");
            existing_positions.push(position);
        }
    }
    let keep = keep_in_place(&existing_positions);

    let mut dangers = Vec::new();
    let mut not_null_columns = Vec::new();
    let mut drop_foreign_keys = Vec::new();
    let mut drop_indexes = Vec::new();
    let mut drop_columns = Vec::new();
    let mut column_clauses = Vec::new();
    let mut rename_indexes = Vec::new();
    let mut add_indexes = Vec::new();
    let mut add_foreign_keys = Vec::new();

    for column in &original_drafts.columns {
        if !used_originals.contains(&column.name) {
            drop_columns.push(format!("DROP COLUMN {}", quote_ident(&column.name)));
            dangers.push(format!("删除列 {}：这一列的数据会永久丢失", column.name));
        }
    }

    let mut existing_index = 0;
    for (position, column) in draft.columns.iter().enumerate() {
        let placement = if position == 0 {
            " FIRST".to_string()
        } else {
            format!(" AFTER {}", quote_ident(&draft.columns[position - 1].name))
        };

        let Some(original_name) = &column.original_name else {
            let definition = column_definition(column, table_collation, nbe)?;
            column_clauses.push(format!("ADD COLUMN {} {definition}{placement}", quote_ident(&column.name)));
            continue;
        };

        let moved = !keep[existing_index];
        existing_index += 1;
        let before = original_columns[original_name.as_str()];
        let renamed = &column.name != original_name;
        let changed = !same_definition(before, column, table_collation);

        if !changed && !moved {
            if renamed {
                // RENAME COLUMN 不碰定义，锁住的列也能改名
                column_clauses.push(format!(
                    "RENAME COLUMN {} TO {}",
                    quote_ident(original_name),
                    quote_ident(&column.name)
                ));
            }
            continue;
        }
        // 锁定原因以原结构为准，不信界面传回来的
        if let Some(reason) = &before.locked {
            let action = if changed { "修改" } else { "移动" };
            return Err(format!("列 {original_name} 不能{action}：{reason}"));
        }

        let definition = column_definition(column, table_collation, nbe)?;
        let placement = if moved { placement } else { String::new() };
        if renamed {
            column_clauses.push(format!(
                "CHANGE COLUMN {} {} {definition}{placement}",
                quote_ident(original_name),
                quote_ident(&column.name)
            ));
        } else {
            column_clauses.push(format!("MODIFY COLUMN {} {definition}{placement}", quote_ident(&column.name)));
        }

        if let Some(danger) = type_change_danger(original_name, &before.column_type, &column.column_type) {
            dangers.push(danger);
        }
        let old_collation = effective_collation(before, table_collation);
        let new_collation = effective_collation(column, table_collation);
        if old_collation.is_some() && new_collation.is_some() && old_collation != new_collation {
            dangers.push(format!(
                "列 {original_name} 排序规则 {} → {}：已有的数据要转换字符集，转换不了的字符会报错或变成 ?",
                old_collation.unwrap_or_default(),
                new_collation.unwrap_or_default()
            ));
        }
        if before.nullable && !column.nullable {
            not_null_columns.push(original_name.clone());
        }
    }

    // ---- 索引 ----
    let mut original_indexes: HashMap<&str, &IndexDraft> = HashMap::new();
    for index in &original_drafts.indexes {
        original_indexes.insert(index.name.as_str(), index);
    }
    let mut index_names = HashSet::new();
    let mut used_indexes = HashSet::new();
    let mut primary_count = 0;
    for index in &draft.indexes {
        let name = if index.kind == IndexKind::Primary { "PRIMARY" } else { index.name.as_str() };
        if index.kind == IndexKind::Primary {
            primary_count += 1;
        } else if name.trim().is_empty() {
            return Err("有一个索引没有名字".to_string());
        } else if name.eq_ignore_ascii_case("PRIMARY") {
            return Err("PRIMARY 只能用作主键的名字".to_string());
        }
        if !index_names.insert(lower(name)) {
            return Err(format!("索引名 {name} 重复了"));
        }
        if index.parts.is_empty() {
            return Err(format!("索引 {name} 没有列"));
        }
        for part in &index.parts {
            // 没有列名的是锁住的函数索引，原样保留时不用管；要重建时 add_index_sql 会拒绝
            let Some(column) = &part.column else {
                continue;
            };
            if !draft_names.contains(&lower(column)) {
                return Err(format!("索引 {name} 引用了不存在的列 {column}"));
            }
            if part.prefix == Some(0) {
                return Err(format!("索引 {name} 的前缀长度不能是 0"));
            }
        }
        if let Some(original_name) = &index.original_name {
            if !original_indexes.contains_key(original_name.as_str()) {
                return Err(format!("原表里没有索引 {original_name}，请重新打开编辑器"));
            }
            if !used_indexes.insert(original_name.clone()) {
                return Err(format!("原来的索引 {original_name} 在草稿里出现了两次"));
            }
        }
    }
    if primary_count > 1 {
        return Err("一张表只能有一个主键".to_string());
    }

    for index in &original_drafts.indexes {
        if !used_indexes.contains(&index.name) {
            drop_indexes.push(drop_index_sql(&index.name));
            if index.name == "PRIMARY" {
                dangers.push("删除主键：没有主键的表在 CData 里不能再编辑行".to_string());
            } else {
                dangers.push(format!("删除索引 {}", index.name));
            }
        }
    }

    for index in &draft.indexes {
        let Some(original_name) = &index.original_name else {
            add_indexes.push(add_index_sql(index, nbe)?);
            continue;
        };
        let before = original_indexes[original_name.as_str()];
        // 原索引里的列名按草稿里的改名换成新名字再比；MySQL 改列名时会自动改索引
        let mut expected_parts = before.parts.clone();
        for part in &mut expected_parts {
            if let Some(column) = &part.column {
                if let Some(new_name) = renames.get(column) {
                    part.column = Some(new_name.clone());
                }
            }
        }
        let new_name = if index.kind == IndexKind::Primary { "PRIMARY" } else { index.name.as_str() };
        let unchanged = before.kind == index.kind && expected_parts == index.parts && before.comment == index.comment;
        if unchanged {
            if new_name != original_name {
                rename_indexes.push(format!("RENAME INDEX {} TO {}", quote_ident(original_name), quote_ident(new_name)));
            }
            continue;
        }
        if let Some(reason) = &before.locked {
            return Err(format!("索引 {original_name} 不能修改：{reason}"));
        }
        drop_indexes.push(drop_index_sql(original_name));
        add_indexes.push(add_index_sql(index, nbe)?);
        if original_name == "PRIMARY" && index.kind != IndexKind::Primary {
            dangers.push("删除主键：没有主键的表在 CData 里不能再编辑行".to_string());
        }
    }

    // ---- 外键 ----
    let mut original_fks: HashMap<&str, &ForeignKeyDraft> = HashMap::new();
    for fk in &original_drafts.foreign_keys {
        original_fks.insert(fk.name.as_str(), fk);
    }
    let mut fk_names = HashSet::new();
    let mut used_fks = HashSet::new();
    for fk in &draft.foreign_keys {
        if fk.name.trim().is_empty() {
            return Err("有一个外键没有名字".to_string());
        }
        if !fk_names.insert(lower(&fk.name)) {
            return Err(format!("外键名 {} 重复了", fk.name));
        }
        if fk.columns.is_empty() || fk.columns.len() != fk.referenced_columns.len() {
            return Err(format!("外键 {}：本表的列和引用的列要一样多，且至少一列", fk.name));
        }
        for column in &fk.columns {
            if !draft_names.contains(&lower(column)) {
                return Err(format!("外键 {} 引用了不存在的列 {column}", fk.name));
            }
        }
        if fk.referenced_table.trim().is_empty() || fk.referenced_schema.trim().is_empty() {
            return Err(format!("外键 {} 没有填引用的表", fk.name));
        }
        if fk.referenced_columns.iter().any(|c| c.trim().is_empty()) {
            return Err(format!("外键 {} 有引用列没填", fk.name));
        }
        for action in [&fk.on_delete, &fk.on_update] {
            if !FK_ACTIONS.contains(&action.as_str()) {
                return Err(format!("外键 {} 的动作「{action}」不认识", fk.name));
            }
        }
        if let Some(original_name) = &fk.original_name {
            if !original_fks.contains_key(original_name.as_str()) {
                return Err(format!("原表里没有外键 {original_name}，请重新打开编辑器"));
            }
            if !used_fks.insert(original_name.clone()) {
                return Err(format!("原来的外键 {original_name} 在草稿里出现了两次"));
            }
        }
    }

    let mut dropped_fk_names = Vec::new();
    for fk in &original_drafts.foreign_keys {
        if !used_fks.contains(&fk.name) {
            drop_foreign_keys.push(format!("DROP FOREIGN KEY {}", quote_ident(&fk.name)));
            dropped_fk_names.push(fk.name.clone());
            dangers.push(format!("删除外键 {}：不再检查引用完整性", fk.name));
        }
    }
    for fk in &draft.foreign_keys {
        let Some(original_name) = &fk.original_name else {
            add_foreign_keys.push(add_foreign_key_sql(fk));
            continue;
        };
        let before = original_fks[original_name.as_str()];
        let mut expected = before.clone();
        for column in &mut expected.columns {
            if let Some(new_name) = renames.get(column) {
                *column = new_name.clone();
            }
        }
        if &expected == fk {
            continue;
        }
        // MySQL 没有改外键（包括改名）这一说，只能删了重加
        drop_foreign_keys.push(format!("DROP FOREIGN KEY {}", quote_ident(original_name)));
        dropped_fk_names.push(original_name.clone());
        add_foreign_keys.push(add_foreign_key_sql(fk));
    }

    // ---- 合成语句 ----
    let target = format!("{}.{}", quote_ident(schema), quote_ident(table));
    let readded_same_name = draft
        .foreign_keys
        .iter()
        .any(|fk| dropped_fk_names.iter().any(|dropped| dropped.eq_ignore_ascii_case(&fk.name)));

    let mut statements = Vec::new();
    let mut main_clauses = Vec::new();
    if readded_same_name {
        statements.push(alter_statement(&target, &drop_foreign_keys));
    } else {
        main_clauses.extend(drop_foreign_keys);
    }
    main_clauses.extend(drop_indexes);
    main_clauses.extend(drop_columns);
    main_clauses.extend(column_clauses);
    main_clauses.extend(rename_indexes);
    main_clauses.extend(add_indexes);
    main_clauses.extend(add_foreign_keys);
    if !main_clauses.is_empty() {
        statements.push(alter_statement(&target, &main_clauses));
    }
    if statements.is_empty() {
        return Err("没有任何改动".to_string());
    }

    let mut notes = vec!["MySQL 的 DDL 会隐式提交当前事务，执行后不能回滚。大表上改列或调整顺序会重建整张表，可能要很久。".to_string()];
    if statements.len() == 1 {
        notes.push("合成 1 条 ALTER TABLE 执行：失败时整条都不生效。".to_string());
    } else {
        notes.push(format!(
            "分成 2 条执行：MySQL 不允许在同一条 ALTER 里删掉又加回同名外键，所以第 1 条先删外键 {}，第 2 条做其余改动。\
             如果第 2 条失败，第 1 条已经生效：这些外键已被删除，需要手动加回。",
            dropped_fk_names.join("、")
        ));
    }
    if statements.iter().any(|statement| statement.contains('\\')) {
        let mode = if nbe { "已开启" } else { "未开启" };
        notes.push(format!(
            "字符串里的反斜杠按当前连接的 sql_mode（NO_BACKSLASH_ESCAPES {mode}）转义。复制到别处执行前，先确认那边的 sql_mode 一致。"
        ));
    }

    Ok((AlterPlan { statements, dangers, notes }, not_null_columns))
}

fn alter_statement(target: &str, clauses: &[String]) -> String {
    format!("ALTER TABLE {target}\n  {}", clauses.join(",\n  "))
}

/// 在给定连接上依次执行。失败时返回失败的是第几条（从 0 数）和错误，前面的已经生效
pub async fn run_statements(conn: &mut Conn, statements: &[String]) -> Result<(), (usize, mysql_async::Error)> {
    for (index, statement) in statements.iter().enumerate() {
        conn.query_drop(statement).await.map_err(|err| (index, err))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn column(name: &str, column_type: &str, nullable: bool, default: DefaultValue) -> ColumnDef {
        ColumnDef {
            name: name.to_string(),
            column_type: column_type.to_string(),
            nullable,
            default,
            extra: String::new(),
            comment: String::new(),
            collation: None,
        }
    }

    fn part(column: &str) -> IndexPart {
        IndexPart { column: Some(column.to_string()), prefix: None, descending: false }
    }

    fn index(name: &str, unique: bool, columns: &[&str]) -> IndexDef {
        IndexDef {
            name: name.to_string(),
            unique,
            columns: columns.iter().map(|c| c.to_string()).collect(),
            parts: columns.iter().map(|c| part(c)).collect(),
            index_type: "BTREE".to_string(),
            comment: String::new(),
        }
    }

    /// 带各种属性的表：主键自增、latin1 列、带引号和反斜杠的默认值与注释、表达式默认值、ON UPDATE
    fn sample() -> TableStructure {
        let mut id = column("id", "int unsigned", false, DefaultValue::NoDefault);
        id.extra = "auto_increment".to_string();
        let mut code = column("code", "varchar(20)", false, DefaultValue::Literal("a'b".to_string()));
        code.collation = Some("latin1_bin".to_string());
        code.comment = "说明".to_string();
        let mut note = column("note", "varchar(50)", true, DefaultValue::Null);
        note.collation = Some("utf8mb4_0900_ai_ci".to_string());
        note.comment = "c\\d".to_string();
        let mut ts = column("ts", "datetime(3)", false, DefaultValue::Expression("CURRENT_TIMESTAMP(3)".to_string()));
        ts.extra = "DEFAULT_GENERATED on update CURRENT_TIMESTAMP(3)".to_string();
        let price = column("price", "decimal(12,2)", false, DefaultValue::Literal("0.00".to_string()));

        TableStructure {
            columns: vec![id, code, note, ts, price],
            indexes: vec![index("PRIMARY", true, &["id"]), index("idx_code", false, &["code", "price"])],
            foreign_keys: vec![ForeignKeyDef {
                name: "fk_price".to_string(),
                columns: vec!["price".to_string()],
                referenced_schema: "shop".to_string(),
                referenced_table: "prices".to_string(),
                referenced_columns: vec!["amount".to_string()],
                on_update: "RESTRICT".to_string(),
                on_delete: "CASCADE".to_string(),
            }],
            create_sql: String::new(),
            table_collation: Some("utf8mb4_0900_ai_ci".to_string()),
        }
    }

    fn plan(original: &TableStructure, draft: &TableDraft) -> Result<(AlterPlan, Vec<String>), String> {
        plan_alter("shop", "t", original, draft, false)
    }

    fn statement(original: &TableStructure, draft: &TableDraft) -> String {
        let (plan, _) = plan(original, draft).unwrap();
        assert_eq!(plan.statements.len(), 1, "{:?}", plan.statements);
        plan.statements[0].clone()
    }

    fn column_mut<'a>(draft: &'a mut TableDraft, name: &str) -> &'a mut ColumnDraft {
        draft.columns.iter_mut().find(|c| c.name == name).unwrap()
    }

    #[test]
    fn unchanged_draft_is_no_change() {
        let original = sample();
        assert_eq!(plan(&original, &table_draft(&original)).unwrap_err(), "没有任何改动");
    }

    /// 本任务最大的数据风险：只改一个属性，MODIFY 里其余属性必须原样带上
    #[test]
    fn modify_carries_the_full_original_definition() {
        let original = sample();
        let mut draft = table_draft(&original);
        column_mut(&mut draft, "code").comment = "新注释".to_string();
        column_mut(&mut draft, "ts").comment = "时间".to_string();
        column_mut(&mut draft, "id").comment = "主键".to_string();

        assert_eq!(
            statement(&original, &draft),
            "ALTER TABLE `shop`.`t`\n  \
             MODIFY COLUMN `id` int unsigned NOT NULL AUTO_INCREMENT COMMENT '主键',\n  \
             MODIFY COLUMN `code` varchar(20) COLLATE latin1_bin NOT NULL DEFAULT 'a''b' COMMENT '新注释',\n  \
             MODIFY COLUMN `ts` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '时间'"
        );
    }

    #[test]
    fn rename_only_uses_rename_column_and_keeps_indexes_and_fks() {
        let original = sample();
        let mut draft = table_draft(&original);
        column_mut(&mut draft, "price").name = "amount".to_string();
        // 界面改列名时顺手把索引和外键里的列名换掉
        draft.indexes[1].parts[1].column = Some("amount".to_string());
        draft.foreign_keys[0].columns[0] = "amount".to_string();

        assert_eq!(statement(&original, &draft), "ALTER TABLE `shop`.`t`\n  RENAME COLUMN `price` TO `amount`");
    }

    #[test]
    fn rename_and_modify_uses_change_with_full_definition() {
        let original = sample();
        let mut draft = table_draft(&original);
        let note = column_mut(&mut draft, "note");
        note.name = "memo".to_string();
        note.column_type = "varchar(80)".to_string();

        assert_eq!(
            statement(&original, &draft),
            "ALTER TABLE `shop`.`t`\n  \
             CHANGE COLUMN `note` `memo` varchar(80) NULL DEFAULT NULL COMMENT 'c\\\\d'"
        );
        let (plan, _) = plan(&original, &draft).unwrap();
        assert!(plan.dangers.is_empty(), "加长 VARCHAR 不算危险：{:?}", plan.dangers);
    }

    #[test]
    fn strings_follow_no_backslash_escapes() {
        assert_eq!(sql_string("it's a\\b", false), "'it''s a\\\\b'");
        assert_eq!(sql_string("it's a\\b", true), "'it''s a\\b'");

        let original = sample();
        let mut draft = table_draft(&original);
        column_mut(&mut draft, "note").default = DefaultValue::Literal("x\\y".to_string());
        let (plan, _) = plan_alter("shop", "t", &original, &draft, true).unwrap();
        assert!(plan.statements[0].contains("DEFAULT 'x\\y' COMMENT 'c\\d'"), "{}", plan.statements[0]);
        assert!(plan.notes.iter().any(|n| n.contains("NO_BACKSLASH_ESCAPES 已开启")), "{:?}", plan.notes);
    }

    #[test]
    fn identifiers_are_quoted_and_escaped() {
        let original = sample();
        let mut draft = table_draft(&original);
        column_mut(&mut draft, "note").name = "we`ird".to_string();
        let (plan, _) = plan_alter("my`db", "t`1", &original, &draft, false).unwrap();
        assert_eq!(plan.statements[0], "ALTER TABLE `my``db`.`t``1`\n  RENAME COLUMN `note` TO `we``ird`");
    }

    #[test]
    fn four_kinds_of_default_render_differently() {
        let original = sample();
        let mut draft = table_draft(&original);
        let mut added = |name: &str, column_type: &str, nullable: bool, default: DefaultValue| {
            draft.columns.push(ColumnDraft {
                original_name: None,
                name: name.to_string(),
                column_type: column_type.to_string(),
                nullable,
                default,
                auto_increment: false,
                on_update: None,
                comment: String::new(),
                collation: None,
                locked: None,
            });
        };
        added("a", "int", false, DefaultValue::NoDefault);
        added("b", "int", true, DefaultValue::Null);
        added("c", "varchar(10)", false, DefaultValue::Literal(String::new()));
        added("d", "char(36)", false, DefaultValue::Expression("uuid()".to_string()));
        added("e", "datetime", true, DefaultValue::NoDefault);

        let sql = statement(&original, &draft);
        assert!(sql.contains("ADD COLUMN `a` int NOT NULL AFTER `price`"), "{sql}");
        assert!(sql.contains("ADD COLUMN `b` int NULL DEFAULT NULL AFTER `a`"), "{sql}");
        assert!(sql.contains("ADD COLUMN `c` varchar(10) NOT NULL DEFAULT '' AFTER `b`"), "空串默认值不能丢：{sql}");
        assert!(sql.contains("ADD COLUMN `d` char(36) NOT NULL DEFAULT (uuid()) AFTER `c`"), "{sql}");
        assert!(sql.contains("ADD COLUMN `e` datetime NULL DEFAULT NULL AFTER `d`"), "可空列的无默认值就是 NULL：{sql}");
    }

    #[test]
    fn not_null_column_cannot_default_to_null() {
        let original = sample();
        let mut draft = table_draft(&original);
        column_mut(&mut draft, "note").nullable = false;
        let err = plan(&original, &draft).unwrap_err();
        assert!(err.contains("不能是 NULL"), "{err}");

        column_mut(&mut draft, "note").default = DefaultValue::NoDefault;
        let (_, not_null) = plan(&original, &draft).unwrap();
        assert_eq!(not_null, ["note"], "可空改 NOT NULL 要去数 NULL");
    }

    #[test]
    fn moves_only_position_the_columns_that_left_their_place() {
        let original = sample(); // id code note ts price
        let mut draft = table_draft(&original);
        let price = draft.columns.remove(4);
        draft.columns.insert(0, price); // price id code note ts
        assert_eq!(
            statement(&original, &draft),
            "ALTER TABLE `shop`.`t`\n  MODIFY COLUMN `price` decimal(12,2) NOT NULL DEFAULT '0.00' FIRST"
        );

        let mut draft = table_draft(&original);
        draft.columns.swap(1, 2); // id note code ts price
        let sql = statement(&original, &draft);
        assert_eq!(sql.matches(" AFTER ").count() + sql.matches(" FIRST").count(), 1, "只动一列：{sql}");
    }

    #[test]
    fn keep_in_place_is_a_longest_increasing_run() {
        assert_eq!(keep_in_place(&[0, 1, 2]), [true, true, true]);
        assert_eq!(keep_in_place(&[2, 0, 1]), [false, true, true]);
        assert_eq!(keep_in_place(&[]), Vec::<bool>::new());
        let keep = keep_in_place(&[3, 0, 1, 4, 2]);
        assert_eq!(keep.iter().filter(|k| **k).count(), 3);
    }

    #[test]
    fn dangerous_operations_are_listed() {
        let original = sample();
        let mut draft = table_draft(&original);
        draft.columns.retain(|c| c.name != "note");
        column_mut(&mut draft, "code").column_type = "varchar(5)".to_string();
        column_mut(&mut draft, "price").column_type = "int".to_string();
        draft.indexes.clear();
        let (plan, _) = plan(&original, &draft).unwrap();

        let dangers = plan.dangers.join("\n");
        assert!(dangers.contains("删除列 note"), "{dangers}");
        assert!(dangers.contains("列 code 长度 20 → 5"), "{dangers}");
        assert!(dangers.contains("列 price 类型 decimal(12,2) → int"), "{dangers}");
        assert!(dangers.contains("删除主键"), "{dangers}");
        assert!(dangers.contains("删除索引 idx_code"), "{dangers}");
        assert!(plan.statements[0].contains("DROP PRIMARY KEY"), "{}", plan.statements[0]);
    }

    #[test]
    fn collation_change_is_dangerous_and_numbers_reject_collation() {
        let original = sample();
        let mut draft = table_draft(&original);
        column_mut(&mut draft, "code").collation = Some("utf8mb4_bin".to_string());
        let (plan, _) = plan(&original, &draft).unwrap();
        assert!(plan.dangers[0].contains("排序规则 latin1_bin → utf8mb4_bin"), "{:?}", plan.dangers);

        // 排序规则清空就是用表默认，和原来相同就不算改动；和表默认相同时也不写 COLLATE
        let mut draft = table_draft(&original);
        column_mut(&mut draft, "note").collation = None;
        assert_eq!(plan_alter("shop", "t", &original, &draft, false).unwrap_err(), "没有任何改动");

        let mut draft = table_draft(&original);
        column_mut(&mut draft, "code").column_type = "int".to_string();
        let err = plan_alter("shop", "t", &original, &draft, false).unwrap_err();
        assert!(err.contains("不是字符串类型"), "{err}");
    }

    #[test]
    fn index_changes() {
        let original = sample();

        let mut draft = table_draft(&original);
        draft.indexes[1].name = "idx_code_price".to_string();
        assert_eq!(statement(&original, &draft), "ALTER TABLE `shop`.`t`\n  RENAME INDEX `idx_code` TO `idx_code_price`");

        let mut draft = table_draft(&original);
        draft.indexes[1].kind = IndexKind::Unique;
        draft.indexes[1].parts = vec![
            IndexPart { column: Some("code".to_string()), prefix: Some(4), descending: false },
            IndexPart { column: Some("price".to_string()), prefix: None, descending: true },
        ];
        assert_eq!(
            statement(&original, &draft),
            "ALTER TABLE `shop`.`t`\n  DROP INDEX `idx_code`,\n  ADD UNIQUE INDEX `idx_code` (`code`(4), `price` DESC)"
        );

        let mut draft = table_draft(&original);
        draft.indexes[0].parts.push(part("code"));
        draft.indexes.push(IndexDraft {
            original_name: None,
            name: "ft".to_string(),
            kind: IndexKind::Fulltext,
            parts: vec![part("note")],
            comment: "全文".to_string(),
            locked: None,
        });
        assert_eq!(
            statement(&original, &draft),
            "ALTER TABLE `shop`.`t`\n  DROP PRIMARY KEY,\n  ADD PRIMARY KEY (`id`, `code`),\n  ADD FULLTEXT INDEX `ft` (`note`) COMMENT '全文'"
        );
    }

    #[test]
    fn index_referencing_a_dropped_column_is_rejected() {
        let original = sample();
        let mut draft = table_draft(&original);
        draft.columns.retain(|c| c.name != "code");
        let err = plan(&original, &draft).unwrap_err();
        assert!(err.contains("索引 idx_code 引用了不存在的列 code"), "{err}");
    }

    #[test]
    fn foreign_keys_add_and_drop_and_readd_splits() {
        let original = sample();

        let mut draft = table_draft(&original);
        draft.foreign_keys.clear();
        let (plan, _) = plan_alter("shop", "t", &original, &draft, false).unwrap();
        assert_eq!(plan.statements, ["ALTER TABLE `shop`.`t`\n  DROP FOREIGN KEY `fk_price`"]);
        assert!(plan.dangers[0].contains("删除外键 fk_price"));

        let mut draft = table_draft(&original);
        draft.foreign_keys[0].on_delete = "SET NULL".to_string();
        column_mut(&mut draft, "code").comment = "x".to_string();
        let (plan, _) = plan_alter("shop", "t", &original, &draft, false).unwrap();
        assert_eq!(plan.statements.len(), 2, "同名外键删了再加，必须拆开：{:?}", plan.statements);
        assert_eq!(plan.statements[0], "ALTER TABLE `shop`.`t`\n  DROP FOREIGN KEY `fk_price`");
        assert!(plan.statements[1].ends_with(
            "ADD CONSTRAINT `fk_price` FOREIGN KEY (`price`) REFERENCES `shop`.`prices` (`amount`) ON DELETE SET NULL ON UPDATE RESTRICT"
        ));
        assert!(plan.notes.iter().any(|n| n.contains("第 1 条已经生效")), "{:?}", plan.notes);

        let mut draft = table_draft(&original);
        draft.foreign_keys[0].on_delete = "DROP TABLE".to_string();
        assert!(plan_alter("shop", "t", &original, &draft, false).unwrap_err().contains("不认识"));
    }

    #[test]
    fn fragments_cannot_smuggle_a_second_clause() {
        assert!(check_fragment("decimal(12,2) unsigned", "类型").is_ok());
        assert!(check_fragment("enum('a,b','it''s',')')", "类型").is_ok());
        assert!(check_fragment("int, DROP COLUMN x", "类型").is_err());
        assert!(check_fragment("int; DROP TABLE x", "类型").is_err());
        assert!(check_fragment("int -- x", "类型").is_err());
        assert!(check_fragment("int /* x */", "类型").is_err());
        assert!(check_fragment("enum('a", "类型").is_err());
        assert!(check_fragment("1)", "默认值表达式").is_err());
        assert!(check_fragment("enum('a\\\\b')", "类型").is_err(), "COLUMN_TYPE 里的反斜杠随 sql_mode 变");
    }

    #[test]
    fn columns_that_cannot_be_rebuilt_are_locked() {
        let mut generated = column("g", "int", true, DefaultValue::Null);
        generated.extra = "VIRTUAL GENERATED".to_string();
        let mut bits = column("flags", "bit(8)", true, DefaultValue::Literal("b'101'".to_string()));
        bits.extra = String::new();
        let mut quoted_expr = column("w", "varchar(20)", true, DefaultValue::Expression("concat(_utf8mb4\\'x\\')".to_string()));
        quoted_expr.extra = "DEFAULT_GENERATED".to_string();
        let mut invisible = column("inv", "int", true, DefaultValue::Null);
        invisible.extra = "INVISIBLE".to_string();

        let mut original = sample();
        original.columns.extend([generated, bits, quoted_expr, invisible]);
        let draft = table_draft(&original);
        for name in ["g", "flags", "w", "inv"] {
            let locked = &draft.columns.iter().find(|c| c.name == name).unwrap().locked;
            assert!(locked.is_some(), "{name} 应该锁住");
        }
        assert!(draft.columns[0].locked.is_none());

        // 锁住的列能改名、能删，不能改定义
        let mut rename = draft.clone();
        column_mut(&mut rename, "g").name = "g2".to_string();
        assert!(statement(&original, &rename).contains("RENAME COLUMN `g` TO `g2`"));

        let mut modify = draft.clone();
        column_mut(&mut modify, "g").comment = "x".to_string();
        assert!(plan(&original, &modify).unwrap_err().contains("列 g 不能修改"));

        // 界面谎报「没锁」也没用，以原结构为准
        let mut lie = draft.clone();
        column_mut(&mut lie, "w").locked = None;
        column_mut(&mut lie, "w").comment = "x".to_string();
        assert!(plan(&original, &lie).is_err());
    }

    #[test]
    fn functional_and_invisible_indexes_are_locked() {
        let mut original = sample();
        let mut functional = index("idx_expr", false, &["code"]);
        functional.parts[0].column = None;
        original.indexes.push(functional);
        original.indexes.push(index("idx_hidden", false, &["note"]));
        original.create_sql = "CREATE TABLE `t` (\n  KEY `idx_hidden` (`note`) /*!80000 INVISIBLE */\n)".to_string();

        let draft = table_draft(&original);
        assert!(draft.indexes[2].locked.is_some());
        assert!(draft.indexes[3].locked.is_some());
        assert!(draft.indexes[1].locked.is_none());

        // 有函数索引的表照样能改别的；函数索引本身不能改
        let mut other = draft.clone();
        column_mut(&mut other, "code").comment = "x".to_string();
        assert!(statement(&original, &other).contains("MODIFY COLUMN `code`"));
        let mut functional = draft.clone();
        functional.indexes[2].comment = "x".to_string();
        assert!(plan(&original, &functional).unwrap_err().contains("idx_expr 不能修改"));
    }

    #[test]
    fn duplicate_names_are_rejected_case_insensitively() {
        let original = sample();
        let mut draft = table_draft(&original);
        column_mut(&mut draft, "note").name = "CODE".to_string();
        assert!(plan(&original, &draft).unwrap_err().contains("重复"));
    }

    #[test]
    fn server_version_gate() {
        assert!(supports_alter("9.6.0"));
        assert!(supports_alter("8.0.13"));
        assert!(supports_alter("8.4.2-log"));
        assert!(!supports_alter("8.0.12"));
        assert!(!supports_alter("5.7.44"));
        assert!(!supports_alter("10.11.6-MariaDB"));
        assert!(!supports_alter("garbage"));
    }
}
