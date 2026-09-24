//! SQL 词法切分。编辑器高亮和补全共用。
//!
//! 只切 token，不做语法分析；切不对的地方宁可当成普通标识符，也不报错 ——
//! 编辑器里的 SQL 大部分时间都是写了一半的。
//!
//! 位置用 **UTF-16 下标**：Dart 的字符串按 UTF-16 计数，给字节下标的话中文一多就错位。

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SqlTokenKind {
    Keyword,
    Identifier,
    /// 反引号包起来的标识符
    QuotedIdentifier,
    String,
    Number,
    Comment,
    /// @var、@@session.x
    Variable,
    Operator,
    /// ( ) , ; .
    Punctuation,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SqlToken {
    pub kind: SqlTokenKind,
    /// UTF-16 下标，左闭右开
    pub start: u32,
    pub end: u32,
}

/// 高亮用的关键字。只放保留字和类型名，`status`、`name` 这类常见列名不算
pub const KEYWORDS: &[&str] = &[
    "ADD", "ALL", "ALTER", "AND", "AS", "ASC", "AUTO_INCREMENT", "BETWEEN", "BIGINT", "BINARY",
    "BIT", "BLOB", "BOOL", "BOOLEAN", "BY", "CALL", "CASCADE", "CASE", "CAST", "CHANGE", "CHAR",
    "CHARACTER", "CHECK", "COLLATE", "COLUMN", "CONSTRAINT", "CONVERT", "CREATE", "CROSS",
    "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "DATABASE", "DATABASES", "DATE",
    "DATETIME", "DECIMAL", "DECLARE", "DEFAULT", "DELETE", "DESC", "DESCRIBE", "DISTINCT", "DIV",
    "DOUBLE", "DROP", "DUPLICATE", "ELSE", "ELSEIF", "END", "ENUM", "ESCAPE", "EXISTS", "EXPLAIN",
    "FALSE", "FLOAT", "FOR", "FOREIGN", "FROM", "FULLTEXT", "FUNCTION", "GRANT", "GROUP", "HAVING",
    "IF", "IGNORE", "IN", "INDEX", "INNER", "INSERT", "INT", "INTEGER", "INTERVAL", "INTO", "IS",
    "JOIN", "JSON", "KEY", "KEYS", "LEFT", "LIKE", "LIMIT", "LOCK", "LONGBLOB", "LONGTEXT",
    "MEDIUMBLOB", "MEDIUMINT", "MEDIUMTEXT", "MOD", "MODIFY", "NATURAL", "NOT", "NULL", "NUMERIC",
    "OFFSET", "ON", "OR", "ORDER", "OUTER", "OVER", "PARTITION", "PRIMARY", "PROCEDURE", "RANGE",
    "RECURSIVE", "REFERENCES", "REGEXP", "RENAME", "REPLACE", "RETURN", "RETURNS", "REVOKE",
    "RIGHT", "RLIKE", "ROLLBACK", "ROW", "ROWS", "SCHEMA", "SELECT", "SET", "SHOW", "SIGNED",
    "SMALLINT", "TABLE", "TABLES", "TEXT", "THEN", "TIME", "TIMESTAMP", "TINYBLOB", "TINYINT",
    "TINYTEXT", "TO", "TRIGGER", "TRUE", "TRUNCATE", "UNION", "UNIQUE", "UNSIGNED", "UPDATE", "USE",
    "USING", "VALUES", "VARBINARY", "VARCHAR", "VIEW", "WHEN", "WHERE", "WINDOW", "WITH", "XOR",
    "YEAR", "ZEROFILL",
];

pub fn is_keyword(word: &str) -> bool {
    let upper = word.to_ascii_uppercase();
    KEYWORDS.binary_search(&upper.as_str()).is_ok()
}

fn is_ident_char(ch: char) -> bool {
    ch.is_alphanumeric() || ch == '_' || ch == '$' || !ch.is_ascii()
}

/// 切 token。空白不出 token；没闭合的字符串、注释一直算到末尾
pub fn tokenize(sql: &str) -> Vec<SqlToken> {
    let chars: Vec<char> = sql.chars().collect();
    // 第 i 个字符的 UTF-16 下标，多放一个末尾位置
    let mut offsets = Vec::with_capacity(chars.len() + 1);
    let mut offset = 0u32;
    for ch in &chars {
        offsets.push(offset);
        offset += ch.len_utf16() as u32;
    }
    offsets.push(offset);

    let mut tokens = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        let ch = chars[i];
        let start = i;
        let next = chars.get(i + 1).copied();

        let kind = if ch.is_whitespace() {
            i += 1;
            continue;
        } else if ch == '#' || (ch == '-' && next == Some('-') && chars.get(i + 2).is_none_or(|c| c.is_whitespace() || c.is_control())) {
            // MySQL 的 -- 注释后面必须跟空白，`--1` 是两个减号
            while i < chars.len() && chars[i] != '\n' {
                i += 1;
            }
            SqlTokenKind::Comment
        } else if ch == '/' && next == Some('*') {
            i += 2;
            while i < chars.len() && !(chars[i] == '*' && chars.get(i + 1) == Some(&'/')) {
                i += 1;
            }
            i = (i + 2).min(chars.len());
            SqlTokenKind::Comment
        } else if ch == '\'' || ch == '"' {
            i = skip_quoted(&chars, i, ch, true);
            SqlTokenKind::String
        } else if ch == '`' {
            i = skip_quoted(&chars, i, '`', false);
            SqlTokenKind::QuotedIdentifier
        } else if matches!(ch, 'x' | 'X' | 'b' | 'B' | 'n' | 'N') && next == Some('\'') {
            // X'0A'、b'101'、N'文本'
            i = skip_quoted(&chars, i + 1, '\'', true);
            SqlTokenKind::String
        } else if ch.is_ascii_digit() || (ch == '.' && next.is_some_and(|c| c.is_ascii_digit())) {
            i = skip_number(&chars, i);
            // 1abc 在 MySQL 里是合法标识符
            if i < chars.len() && is_ident_char(chars[i]) && chars[i] != '.' {
                while i < chars.len() && is_ident_char(chars[i]) {
                    i += 1;
                }
                SqlTokenKind::Identifier
            } else {
                SqlTokenKind::Number
            }
        } else if ch == '@' {
            i += 1;
            if chars.get(i) == Some(&'@') {
                i += 1;
            }
            while i < chars.len() && (is_ident_char(chars[i]) || chars[i] == '.') {
                i += 1;
            }
            SqlTokenKind::Variable
        } else if is_ident_char(ch) {
            while i < chars.len() && is_ident_char(chars[i]) {
                i += 1;
            }
            let word: String = chars[start..i].iter().collect();
            if is_keyword(&word) {
                SqlTokenKind::Keyword
            } else {
                SqlTokenKind::Identifier
            }
        } else if matches!(ch, '(' | ')' | ',' | ';' | '.') {
            i += 1;
            SqlTokenKind::Punctuation
        } else {
            i += 1;
            SqlTokenKind::Operator
        };

        tokens.push(SqlToken { kind, start: offsets[start], end: offsets[i] });
    }
    tokens
}

/// 跳过引号包的一段，返回结束位置（闭合引号之后）。重复引号是转义；字符串里反斜杠也是转义
fn skip_quoted(chars: &[char], start: usize, quote: char, backslash_escapes: bool) -> usize {
    let mut i = start + 1;
    while i < chars.len() {
        let ch = chars[i];
        if backslash_escapes && ch == '\\' {
            i += 2;
            continue;
        }
        if ch == quote {
            if chars.get(i + 1) == Some(&quote) {
                i += 2;
                continue;
            }
            return i + 1;
        }
        i += 1;
    }
    chars.len()
}

fn skip_number(chars: &[char], start: usize) -> usize {
    let mut i = start;
    if chars[i] == '0' && matches!(chars.get(i + 1), Some('x') | Some('X')) {
        i += 2;
        while i < chars.len() && chars[i].is_ascii_hexdigit() {
            i += 1;
        }
        return i;
    }
    while i < chars.len() && chars[i].is_ascii_digit() {
        i += 1;
    }
    if i < chars.len() && chars[i] == '.' {
        i += 1;
        while i < chars.len() && chars[i].is_ascii_digit() {
            i += 1;
        }
    }
    if i < chars.len() && matches!(chars[i], 'e' | 'E') {
        let mut j = i + 1;
        if j < chars.len() && matches!(chars[j], '+' | '-') {
            j += 1;
        }
        if j < chars.len() && chars[j].is_ascii_digit() {
            i = j;
            while i < chars.len() && chars[i].is_ascii_digit() {
                i += 1;
            }
        }
    }
    i
}

#[cfg(test)]
mod tests {
    use super::*;
    use SqlTokenKind::*;

    /// (类型, 原文) 对，方便断言
    // SqlTokenKind::String 把 String 遮住了，这里写全路径
    fn pieces(sql: &str) -> Vec<(SqlTokenKind, std::string::String)> {
        let units: Vec<u16> = sql.encode_utf16().collect();
        let mut out = Vec::new();
        for token in tokenize(sql) {
            let text = std::string::String::from_utf16(&units[token.start as usize..token.end as usize]).unwrap();
            out.push((token.kind, text));
        }
        out
    }

    #[test]
    fn keywords_must_be_sorted_for_binary_search() {
        let mut sorted = KEYWORDS.to_vec();
        sorted.sort_unstable();
        assert_eq!(sorted, KEYWORDS);
    }

    #[test]
    fn basic_select() {
        assert_eq!(
            pieces("select id, `order` from t where a >= 1.5e3"),
            vec![
                (Keyword, "select".into()),
                (Identifier, "id".into()),
                (Punctuation, ",".into()),
                (QuotedIdentifier, "`order`".into()),
                (Keyword, "from".into()),
                (Identifier, "t".into()),
                (Keyword, "where".into()),
                (Identifier, "a".into()),
                (Operator, ">".into()),
                (Operator, "=".into()),
                (Number, "1.5e3".into()),
            ]
        );
    }

    #[test]
    fn strings_with_escapes_and_doubled_quotes() {
        assert_eq!(
            pieces(r#"'it''s' "a\"b" X'0A' `we``ird`"#),
            vec![
                (String, "'it''s'".into()),
                (String, r#""a\"b""#.into()),
                (String, "X'0A'".into()),
                (QuotedIdentifier, "`we``ird`".into()),
            ]
        );
    }

    #[test]
    fn three_comment_styles_and_minus_minus_without_space() {
        assert_eq!(
            pieces("a -- 注释\n# hash\n/* 块 */ b--1"),
            vec![
                (Identifier, "a".into()),
                (Comment, "-- 注释".into()),
                (Comment, "# hash".into()),
                (Comment, "/* 块 */".into()),
                (Identifier, "b".into()),
                (Operator, "-".into()),
                (Operator, "-".into()),
                (Number, "1".into()),
            ]
        );
    }

    #[test]
    fn unterminated_string_runs_to_the_end_instead_of_failing() {
        assert_eq!(pieces("select 'abc"), vec![(Keyword, "select".into()), (String, "'abc".into())]);
    }

    #[test]
    fn offsets_are_utf16_units() {
        // 😀 占两个 UTF-16 单位，中文各占一个
        let tokens = tokenize("'😀中' x");
        assert_eq!(tokens[0], SqlToken { kind: String, start: 0, end: 5 });
        assert_eq!(tokens[1], SqlToken { kind: Identifier, start: 6, end: 7 });
    }

    #[test]
    fn variables_and_chinese_identifiers() {
        assert_eq!(
            pieces("@@session.sql_mode @x 用户表"),
            vec![
                (Variable, "@@session.sql_mode".into()),
                (Variable, "@x".into()),
                (Identifier, "用户表".into()),
            ]
        );
    }

    #[test]
    fn common_column_names_are_not_keywords() {
        assert!(!is_keyword("status"));
        assert!(!is_keyword("name"));
        assert!(is_keyword("Select"));
    }
}
