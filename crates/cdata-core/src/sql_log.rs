//! SQL operation logging helpers.
//!
//! Values are never interpolated into SQL templates here. String, numeric, and comment
//! tokens are redacted before the template is persisted, and administrative statements
//! that can carry credentials are summarized instead of retained.

use std::time::{Instant, SystemTime, UNIX_EPOCH};

use crate::operation_log::OperationLogEntry;

/// Record a completed SQL operation. Log storage errors must never replace the business result.
pub fn record(
    session_id: u64,
    operation: &str,
    sql: &str,
    started: Instant,
    succeeded: bool,
    message: impl Into<String>,
) {
    record_detail(
        session_id,
        operation,
        &redact_sql(sql),
        started,
        succeeded,
        message,
    );
}

/// Record already-redacted details, used for a batch whose statements need independent
/// credential checks while still producing one accurate batch duration.
pub fn record_detail(
    session_id: u64,
    operation: &str,
    detail: &str,
    started: Instant,
    succeeded: bool,
    message: impl Into<String>,
) {
    let entry = OperationLogEntry {
        session_id,
        operation: operation.to_string(),
        detail: detail.to_string(),
        succeeded,
        message: message.into(),
        executed_at: now_millis(),
        elapsed_ms: started.elapsed().as_millis().min(u64::MAX as u128) as u64,
    };
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| crate::operation_log::record(entry)));
}

pub fn redact_sql_batch(statements: &[String]) -> String {
    statements
        .iter()
        .map(|sql| redact_sql(sql))
        .collect::<Vec<_>>()
        .join(";\n")
}

pub fn operation_name(sql: &str) -> &'static str {
    let tokens = crate::lexer::tokenize(sql);
    let Some(first) = tokens
        .iter()
        .find(|token| !matches!(token.kind, crate::lexer::SqlTokenKind::Comment))
    else {
        return "query";
    };
    let offsets = utf16_byte_offsets(sql);
    let word = sql[offsets[first.start as usize]..offsets[first.end as usize]].to_ascii_uppercase();
    match word.as_str() {
        "INSERT" | "REPLACE" => "insert",
        "UPDATE" => "update",
        "DELETE" => "delete",
        "CREATE" | "ALTER" | "DROP" | "TRUNCATE" | "RENAME" => "ddl",
        _ => "query",
    }
}

pub fn record_mysql_result<T>(
    session_id: u64,
    operation: &str,
    sql: &str,
    started: Instant,
    result: &Result<T, mysql_async::Error>,
) {
    match result {
        Ok(_) => record(session_id, operation, sql, started, true, "完成"),
        Err(error) => record(
            session_id,
            operation,
            sql,
            started,
            false,
            safe_mysql_error(error),
        ),
    }
}

/// Redact literals and comments using the shared lexer (whose offsets are UTF-16 indices).
pub fn redact_sql(sql: &str) -> String {
    let tokens = crate::lexer::tokenize(sql);
    let offsets = utf16_byte_offsets(sql);
    if is_sensitive_admin_sql(sql, &tokens, &offsets) {
        return "[敏感管理语句已隐藏]".to_string();
    }

    let mut output = String::with_capacity(sql.len());
    let mut cursor = 0usize;
    for token in tokens {
        let start = offsets[token.start as usize];
        let end = offsets[token.end as usize];
        if start < cursor || end > sql.len() || start > end {
            continue;
        }
        output.push_str(&sql[cursor..start]);
        match token.kind {
            crate::lexer::SqlTokenKind::String => output.push_str("'[已隐藏]'"),
            crate::lexer::SqlTokenKind::Number => output.push('?'),
            crate::lexer::SqlTokenKind::Comment => output.push_str("/* 已隐藏 */"),
            _ => output.push_str(&sql[start..end]),
        }
        cursor = end;
    }
    output.push_str(&sql[cursor..]);
    output
}

fn utf16_byte_offsets(text: &str) -> Vec<usize> {
    let mut offsets = Vec::with_capacity(text.encode_utf16().count() + 1);
    for (byte, ch) in text.char_indices() {
        for _ in 0..ch.len_utf16() {
            offsets.push(byte);
        }
    }
    offsets.push(text.len());
    offsets
}

fn is_sensitive_admin_sql(sql: &str, tokens: &[crate::lexer::SqlToken], offsets: &[usize]) -> bool {
    use crate::lexer::SqlTokenKind;

    let words: Vec<String> = tokens
        .iter()
        .cloned()
        .into_iter()
        .filter(|token| {
            !matches!(
                token.kind,
                SqlTokenKind::String | SqlTokenKind::Number | SqlTokenKind::Comment
            )
        })
        .filter_map(|token| {
            let start = offsets[token.start as usize];
            let end = offsets[token.end as usize];
            sql.get(start..end).map(str::to_ascii_uppercase)
        })
        .collect();
    let joined = words.join(" ");

    [
        "CREATE USER",
        "ALTER USER",
        "DROP USER",
        "CREATE ROLE",
        "ALTER ROLE",
        "DROP ROLE",
        "GRANT ",
        "REVOKE ",
        "SET PASSWORD",
        "IDENTIFIED BY",
        "CHANGE MASTER",
        "CHANGE REPLICATION SOURCE",
    ]
    .iter()
    .any(|prefix| joined.starts_with(prefix))
}

pub fn safe_mysql_error(error: &mysql_async::Error) -> String {
    match error {
        mysql_async::Error::Server(server) => {
            format!("MySQL error {} (SQLSTATE {})", server.code, server.state)
        }
        mysql_async::Error::Io(_) => "连接中断，语句可能已执行，请确认数据库状态".to_string(),
        mysql_async::Error::Driver(mysql_async::DriverError::ConnectionClosed) => {
            "连接中断，语句可能已执行，请确认数据库状态".to_string()
        }
        mysql_async::Error::Driver(_) => "MySQL 驱动错误".to_string(),
        mysql_async::Error::Url(_) => "连接配置错误，SQL 未发送".to_string(),
        mysql_async::Error::Other(inner)
            if inner.downcast_ref::<crate::db::ConnectFailed>().is_some() =>
        {
            "连接失败，SQL 未发送".to_string()
        }
        mysql_async::Error::Other(inner)
            if inner.downcast_ref::<crate::db::QueryTimedOut>().is_some() =>
        {
            "查询超时，请确认数据库状态".to_string()
        }
        mysql_async::Error::Other(_) => "操作失败".to_string(),
    }
}

fn now_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis().min(i64::MAX as u128) as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redact_sql_hides_literals_numbers_comments_and_handles_unicode_offsets() {
        let sql = "SELECT 名称 FROM 用户 WHERE 密钥 = '秘密' AND id = 123 /* token */";
        let redacted = redact_sql(sql);
        assert!(redacted.contains("名称"));
        assert!(redacted.contains("用户"));
        assert!(!redacted.contains("秘密"));
        assert!(!redacted.contains("123"));
        assert!(!redacted.contains("token"));
        assert!(redacted.contains("密钥 = '[已隐藏]'"));
    }

    #[test]
    fn sensitive_account_statements_are_hidden_as_a_whole() {
        for sql in [
            "CREATE USER 'admin'@'%' IDENTIFIED BY 'secret'",
            "ALTER USER user IDENTIFIED BY 'secret'",
            "SET PASSWORD FOR user = 'secret'",
            "GRANT ALL ON *.* TO user IDENTIFIED BY 'secret'",
        ] {
            let redacted = redact_sql(sql);
            assert!(!redacted.contains("secret"), "{redacted}");
            assert!(!redacted.contains("admin"), "{redacted}");
            assert_eq!(redacted, "[敏感管理语句已隐藏]");
        }
    }

    #[test]
    fn mysql_failure_messages_do_not_include_server_text() {
        let error = mysql_async::Error::Server(mysql_async::ServerError {
            code: 1064,
            state: "42000".into(),
            message: "syntax error near 'super-secret'".into(),
        });
        let message = safe_mysql_error(&error);
        assert_eq!(message, "MySQL error 1064 (SQLSTATE 42000)");
        assert!(!message.contains("super-secret"));
    }
}
