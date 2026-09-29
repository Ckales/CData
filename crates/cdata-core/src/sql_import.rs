//! SQL 文件导入：文件编码和客户端分隔符只在 core 解释。

use std::fs;

use serde::{Deserialize, Serialize};

use crate::export::ExportEncoding;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SqlImportFailure {
    /// 从 1 开始的语句序号和文件行号。
    pub statement: u64,
    pub line: u64,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SqlImportSummary {
    pub executed: u64,
    pub affected_rows: u64,
    /// 前面的语句已经生效，不承诺整体回滚。
    pub failure: Option<SqlImportFailure>,
}

pub(crate) fn server_error_message(server: &mysql_async::ServerError) -> String {
    let prefix = format!("MySQL 错误 {} ({})", server.code, server.state);
    let detail = match server.code {
        1046 => "No database selected".to_string(),
        1048 => "非空列不能写入 NULL".to_string(),
        1050 => "表已存在".to_string(),
        1052 => {
            // 只放行可验证的列标识符与固定句式。任意服务器原文可能包含 SQL 字面量或凭据。
            let parsed = server
                .message
                .strip_prefix("Column '")
                .and_then(|rest| rest.split_once("' in "))
                .and_then(|(column, context)| {
                    let context = context.strip_suffix(" is ambiguous")?;
                    let safe_name = !column.is_empty()
                        && column.len() <= 128
                        && column
                            .chars()
                            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '.' | '$'));
                    let safe_context =
                        matches!(context, "field list" | "order clause" | "group statement");
                    (safe_name && safe_context)
                        .then(|| format!("Column '{column}' in {context} is ambiguous"))
                });
            parsed.unwrap_or_else(|| "Column name is ambiguous".to_string())
        }
        1054 => "列不存在".to_string(),
        1062 => "唯一键冲突（重复值已隐藏）".to_string(),
        1064 => "SQL syntax error (SQL excerpt hidden)".to_string(),
        1146 => "表不存在".to_string(),
        1292 | 1366 => "字段值格式不正确（原值已隐藏）".to_string(),
        1406 => "字段值超出长度限制".to_string(),
        1452 => "外键约束未满足".to_string(),
        _ => return prefix,
    };
    format!("{prefix}：{detail}")
}

pub struct ImportStatement {
    pub sql: String,
    pub line: u64,
}

/// 只接受明确指定的编码；文件必须先完整解析成功，才开始向服务器写入。
pub fn read_statements(
    path: &str,
    encoding: ExportEncoding,
) -> Result<Vec<ImportStatement>, String> {
    let bytes = fs::read(path).map_err(|e| format!("读取 SQL 文件失败：{e}"))?;
    let text = match encoding {
        ExportEncoding::Utf8 | ExportEncoding::Utf8Bom => {
            let bytes = bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(&bytes);
            std::str::from_utf8(bytes)
                .map_err(|e| format!("SQL 文件不是有效的 UTF-8（字节 {}）：{e}", e.valid_up_to()))?
                .to_string()
        }
        ExportEncoding::Gbk => encoding_rs::GBK
            .decode_without_bom_handling_and_without_replacement(&bytes)
            .ok_or("SQL 文件不是有效的 GBK".to_string())?
            .into_owned(),
    };
    split_statements(&text)
}

/// MySQL 客户端的 DELIMITER 只用于切文件，不能发给服务器。
/// 引号、反引号和注释里的分隔符保持原样；/*! ... */ 是服务器会执行的注释。
pub fn split_statements(sql: &str) -> Result<Vec<ImportStatement>, String> {
    let bytes = sql.as_bytes();
    let mut statements = Vec::new();
    let mut delimiter = ";".to_string();
    let mut start = 0;
    let mut line_start = 0;
    let mut line = 1u64;
    let mut statement_line = 1u64;
    let mut has_code = false;
    let mut quote = 0u8;
    let mut block_comment = false;
    let mut line_comment = false;
    let mut i = 0;

    while i < bytes.len() {
        let ch = bytes[i];
        let next = bytes.get(i + 1).copied();

        if ch == b'\n' {
            line += 1;
            line_start = i + 1;
            line_comment = false;
        }
        if line_comment {
            i += 1;
            continue;
        }
        if block_comment {
            if ch == b'*' && next == Some(b'/') {
                block_comment = false;
                i += 2;
            } else {
                i += 1;
            }
            continue;
        }
        if quote != 0 {
            if ch == b'\\' && quote != b'`' {
                if next == Some(b'\n') {
                    line += 1;
                    line_start = i + 2;
                }
                i = (i + 2).min(bytes.len());
            } else if ch == quote {
                if next == Some(quote) {
                    i += 2;
                } else {
                    quote = 0;
                    i += 1;
                }
            } else {
                i += 1;
            }
            continue;
        }

        if i == line_start {
            let end = sql[i..].find('\n').map_or(bytes.len(), |offset| i + offset);
            let trimmed = sql[i..end].trim();
            if trimmed.eq_ignore_ascii_case("DELIMITER") {
                return Err(format!("第 {line} 行的 DELIMITER 无效"));
            }
            if trimmed
                .get(..9)
                .is_some_and(|prefix| prefix.eq_ignore_ascii_case("DELIMITER"))
                && trimmed
                    .as_bytes()
                    .get(9)
                    .is_some_and(u8::is_ascii_whitespace)
            {
                if has_code {
                    return Err(format!("第 {line} 行的 DELIMITER 必须在语句之间"));
                }
                let new_delimiter = trimmed[9..].trim();
                if new_delimiter.is_empty() || new_delimiter.chars().any(char::is_whitespace) {
                    return Err(format!("第 {line} 行的 DELIMITER 无效"));
                }
                delimiter = new_delimiter.to_string();
                i = end;
                start = end;
                continue;
            }
        }

        if bytes[i..].starts_with(delimiter.as_bytes()) {
            if has_code {
                statements.push(ImportStatement {
                    sql: sql[start..i].trim().to_string(),
                    line: statement_line,
                });
            }
            i += delimiter.len();
            start = i;
            has_code = false;
            continue;
        }
        if ch == b'#'
            || (ch == b'-' && next == Some(b'-') && bytes.get(i + 2).is_none_or(|c| *c <= b' '))
        {
            line_comment = true;
            i += if ch == b'#' { 1 } else { 2 };
            continue;
        }
        if ch == b'/' && next == Some(b'*') {
            if bytes.get(i + 2) == Some(&b'!') && !has_code {
                statement_line = line;
                has_code = true;
            }
            block_comment = true;
            i += 2;
            continue;
        }
        if matches!(ch, b'\'' | b'"' | b'`') {
            if !has_code {
                statement_line = line;
                has_code = true;
            }
            quote = ch;
            i += 1;
            continue;
        }
        if !ch.is_ascii_whitespace() && !has_code {
            statement_line = line;
            has_code = true;
        }
        i += 1;
    }

    if quote != 0 || block_comment {
        return Err(format!("第 {line} 行附近有未闭合的引号或注释"));
    }
    if has_code {
        statements.push(ImportStatement {
            sql: sql[start..].trim().to_string(),
            line: statement_line,
        });
    }
    if statements.is_empty() {
        return Err("SQL 文件没有可执行的语句".to_string());
    }
    Ok(statements)
}

#[cfg(test)]
mod tests {
    use super::{read_statements, server_error_message, split_statements};
    use crate::export::ExportEncoding;

    #[test]
    fn imports_dump_delimiters_and_executable_comments() {
        let sql = "-- 开头\n/*!40101 SET NAMES utf8mb4 */;\nDELIMITER //\nCREATE PROCEDURE p() BEGIN SELECT 'a;//'; SELECT 2; END//\nDELIMITER ;\nINSERT INTO t VALUES ('中文;--'), (1);";
        let statements = split_statements(sql).unwrap();
        assert_eq!(statements.len(), 3);
        assert_eq!(statements[0].line, 2);
        assert!(statements[0].sql.contains("/*!40101 SET NAMES utf8mb4 */"));
        assert!(statements[1].sql.contains("SELECT 2; END"));
        assert_eq!(statements[2].line, 6);
    }

    #[test]
    fn refuses_bad_file_before_running_any_statement() {
        assert!(split_statements("SELECT 1;\nSELECT 'unfinished").is_err());
        assert!(split_statements("DELIMITER \nSELECT 1").is_err());
    }

    #[test]
    fn file_encoding_is_explicit_and_lossless() {
        let path = std::env::temp_dir().join(format!(
            "cdata_sql_import_encoding_{}.sql",
            std::process::id()
        ));
        let (gbk, _, _) = encoding_rs::GBK.encode("SELECT '中文';");
        std::fs::write(&path, gbk.as_ref()).unwrap();
        assert!(read_statements(path.to_str().unwrap(), ExportEncoding::Utf8).is_err());
        let statements = read_statements(path.to_str().unwrap(), ExportEncoding::Gbk).unwrap();
        assert_eq!(statements[0].sql, "SELECT '中文'");
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn import_error_explains_ambiguous_column_without_leaking_sql_literals() {
        let ambiguous = mysql_async::ServerError {
            code: 1052,
            state: "23000".into(),
            message: "Column 'id' in field list is ambiguous".into(),
        };
        assert_eq!(
            server_error_message(&ambiguous),
            "MySQL 错误 1052 (23000)：Column 'id' in field list is ambiguous"
        );

        let syntax = mysql_async::ServerError {
            code: 1064,
            state: "42000".into(),
            message: "SQL syntax error near 'IDENTIFIED BY supersecret'".into(),
        };
        assert!(!server_error_message(&syntax).contains("supersecret"));

        let unsafe_column = mysql_async::ServerError {
            code: 1052,
            state: "23000".into(),
            message: "Column 'secret value' in field list is ambiguous".into(),
        };
        assert_eq!(
            server_error_message(&unsafe_column),
            "MySQL 错误 1052 (23000)：Column name is ambiguous"
        );

        let duplicate = mysql_async::ServerError {
            code: 1062,
            state: "23000".into(),
            message: "Duplicate entry 'secret-token' for key 'uq_key'".into(),
        };
        assert_eq!(
            server_error_message(&duplicate),
            "MySQL 错误 1062 (23000)：唯一键冲突（重复值已隐藏）"
        );
    }
}
