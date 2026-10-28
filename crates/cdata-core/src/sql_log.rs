//! SQL operation logging helpers.
//!
//! 记录完整 SQL；参数仅还原为日志文本，不参与数据库执行。

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
    record_detail(session_id, operation, sql, started, succeeded, message);
}

/// Record a batch with its complete SQL and batch duration.
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
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        crate::operation_log::record(entry)
    }));
}

pub fn sql_batch(statements: &[String]) -> String {
    statements.join(";\n")
}

/// MySQL 预处理语句在服务端绑定参数。这里仅为日志生成含实际值的可读 SQL。
/// 引号和注释里的问号不是参数，不替换；数据库始终使用原 SQL 和原参数执行。
pub fn render_sql(sql: &str, params: &[mysql_async::Value]) -> String {
    if params.is_empty() {
        return sql.to_string();
    }
    let offsets = utf16_byte_offsets(sql);
    let mut output = String::with_capacity(sql.len());
    let mut cursor = 0;
    let mut values = params.iter();
    let mut placeholders = 0;
    for token in crate::lexer::tokenize(sql) {
        let start = offsets[token.start as usize];
        let end = offsets[token.end as usize];
        if token.kind != crate::lexer::SqlTokenKind::Operator || &sql[start..end] != "?" {
            continue;
        }
        output.push_str(&sql[cursor..start]);
        placeholders += 1;
        if let Some(value) = values.next() {
            output.push_str(&crate::value::mysql_value_sql_literal(value));
        } else {
            output.push('?');
        }
        cursor = end;
    }
    output.push_str(&sql[cursor..]);
    if placeholders != params.len() {
        output.push_str("\n-- 日志参数数量不匹配，原始参数：");
        output.push_str(
            &params
                .iter()
                .map(crate::value::mysql_value_sql_literal)
                .collect::<Vec<_>>()
                .join(", "),
        );
    }
    output
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

pub fn safe_mysql_error(error: &mysql_async::Error) -> String {
    match error {
        mysql_async::Error::Server(server) => {
            format!(
                "MySQL error {} (SQLSTATE {}): {}",
                server.code, server.state, server.message
            )
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
    fn update_log_contains_actual_value_primary_key_and_limit() {
        let sql = "UPDATE `unifly`.`uf_admin_op_log` SET `scope` = ? WHERE `id` = ? LIMIT 1";
        let params = [
            mysql_async::Value::Bytes(b"2".to_vec()),
            mysql_async::Value::UInt(18446744073709551615),
        ];
        assert_eq!(render_sql(sql, &params), "UPDATE `unifly`.`uf_admin_op_log` SET `scope` = '2' WHERE `id` = 18446744073709551615 LIMIT 1");
    }

    #[test]
    fn literal_sql_is_preserved_including_strings_numbers_and_comments() {
        let sql = "SELECT '完整内容', 123 /* 保留注释 */ LIMIT 1001";
        assert_eq!(render_sql(sql, &[]), sql);
        assert_eq!(sql_batch(&[sql.to_string()]), sql);
    }

    #[test]
    fn replaces_only_parameter_markers_and_preserves_exact_values() {
        let sql = "UPDATE `中文😀` SET `a?` = ?, note = '?' /* ? */ WHERE id = ?";
        let params = [
            mysql_async::Value::Bytes("O'Reilly\\路径😀".as_bytes().to_vec()),
            mysql_async::Value::NULL,
        ];
        let rendered = render_sql(sql, &params);
        assert!(
            rendered.contains("`a?` = 'O\\'Reilly\\\\路径😀'"),
            "{rendered}"
        );
        assert!(rendered.contains("note = '?' /* ? */ WHERE id = NULL"));
        let decimal = "123456789012345678901234567890.1234567890";
        assert_eq!(
            render_sql(
                "SELECT ?",
                &[mysql_async::Value::Bytes(decimal.as_bytes().to_vec())]
            ),
            format!("SELECT '{decimal}'")
        );
    }

    #[test]
    fn mysql_failure_messages_keep_original_server_text() {
        let error = mysql_async::Error::Server(mysql_async::ServerError {
            code: 1064,
            state: "42000".into(),
            message: "syntax error near 'super-secret'".into(),
        });
        let message = safe_mysql_error(&error);
        assert_eq!(
            message,
            "MySQL error 1064 (SQLSTATE 42000): syntax error near 'super-secret'"
        );
    }
}
