//! 编辑器里的一段 SQL：切成多条语句、生成执行计划语句。

use crate::lexer::{tokenize, SqlToken, SqlTokenKind};

/// 按分号切成多条语句。字符串、注释、反引号里的分号不算，只有注释和空白的片段丢掉。
///
/// 两种情况拒绝，不猜：
/// - `DELIMITER` 是命令行客户端的指令，服务器不认识；
/// - 存储过程 / 函数 / 触发器 / 事件的 `BEGIN … END` 体里有分号，按分号切会把定义切碎
pub fn split_statements(sql: &str) -> Result<Vec<String>, String> {
    let units: Vec<u16> = sql.encode_utf16().collect();
    let tokens = tokenize(sql);

    let mut statements = Vec::new();
    let mut start = 0usize;
    let mut segment: Vec<&SqlToken> = Vec::new();
    for token in &tokens {
        let is_separator = token.kind == SqlTokenKind::Punctuation && text_of(&units, token) == ";";
        if is_separator {
            push_statement(&units, start, token.start as usize, &segment, &mut statements)?;
            start = token.end as usize;
            segment.clear();
            continue;
        }
        segment.push(token);
    }
    push_statement(&units, start, units.len(), &segment, &mut statements)?;
    Ok(statements)
}

fn push_statement(
    units: &[u16],
    start: usize,
    end: usize,
    segment: &[&SqlToken],
    statements: &mut Vec<String>,
) -> Result<(), String> {
    let mut words = Vec::new();
    for token in segment {
        if token.kind == SqlTokenKind::Comment {
            continue;
        }
        words.push(text_of(units, token).to_ascii_uppercase());
    }
    if words.is_empty() {
        return Ok(());
    }

    if words[0] == "DELIMITER" {
        return Err("DELIMITER 是命令行客户端的指令，服务器不认识；这里按分号分隔语句，不需要它".to_string());
    }
    let defines_routine = words[0] == "CREATE"
        && words.iter().any(|word| matches!(word.as_str(), "PROCEDURE" | "FUNCTION" | "TRIGGER" | "EVENT"));
    if defines_routine && words.iter().any(|word| word == "BEGIN") {
        return Err(
            "存储过程、函数、触发器、事件的 BEGIN … END 体里有分号，按分号切会把定义切碎，暂不支持在编辑器里执行"
                .to_string(),
        );
    }

    // 切分点都落在 token 边界上，不会把一个字符的两个 UTF-16 单元拆开
    let text = String::from_utf16(&units[start..end]).map_err(|e| e.to_string())?;
    statements.push(text.trim().to_string());
    Ok(())
}

fn text_of(units: &[u16], token: &SqlToken) -> String {
    String::from_utf16_lossy(&units[token.start as usize..token.end as usize])
}

/// 执行计划要跑的语句。只收一条；已经写了 EXPLAIN / DESCRIBE 的原样返回。
/// 不加 ANALYZE：EXPLAIN ANALYZE 会真的执行语句，对 UPDATE / DELETE 就是写库。
/// 显式写 FORMAT=TRADITIONAL：MySQL 9 默认 explain_format=TREE，整个计划挤在一个单元格里，网格上没法看
pub fn explain_sql(sql: &str) -> Result<String, String> {
    let statements = split_statements(sql)?;
    if statements.len() != 1 {
        return Err(format!("执行计划只能看一条语句，现在有 {} 条", statements.len()));
    }
    let statement = statements.into_iter().next().unwrap();

    let first_word = statement.split_whitespace().next().unwrap_or("").to_ascii_uppercase();
    if matches!(first_word.as_str(), "EXPLAIN" | "DESCRIBE" | "DESC") {
        return Ok(statement);
    }
    Ok(format!("EXPLAIN FORMAT=TRADITIONAL {statement}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_on_semicolons_outside_strings_comments_and_identifiers() {
        let sql = "SELECT 'a;b' AS `x;y`; -- 注释里的 ; 不算\nUPDATE t SET v = \"c;d\" WHERE id = 1 /* ; */;\n";
        let statements = split_statements(sql).unwrap();
        assert_eq!(
            statements,
            vec![
                "SELECT 'a;b' AS `x;y`".to_string(),
                "-- 注释里的 ; 不算\nUPDATE t SET v = \"c;d\" WHERE id = 1 /* ; */".to_string(),
            ]
        );
    }

    #[test]
    fn drops_empty_and_comment_only_segments() {
        let statements = split_statements(";; SELECT 1 ;  -- 结尾只有注释\n").unwrap();
        assert_eq!(statements, vec!["SELECT 1".to_string()]);
        assert!(split_statements("  -- 什么都没有\n").unwrap().is_empty());
    }

    #[test]
    fn keeps_chinese_text_intact() {
        let statements = split_statements("SELECT '订单;已完成'; SELECT '😀'").unwrap();
        assert_eq!(statements, vec!["SELECT '订单;已完成'".to_string(), "SELECT '😀'".to_string()]);
    }

    #[test]
    fn refuses_delimiter_and_routine_bodies() {
        assert!(split_statements("DELIMITER //\nSELECT 1//").is_err());
        let procedure = "CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END";
        assert!(split_statements(procedure).is_err());
        // 事务的 BEGIN 不是存储过程
        assert_eq!(split_statements("BEGIN; UPDATE t SET v = 1; COMMIT").unwrap().len(), 3);
    }

    #[test]
    fn explain_takes_exactly_one_statement() {
        assert_eq!(explain_sql("SELECT * FROM t;").unwrap(), "EXPLAIN FORMAT=TRADITIONAL SELECT * FROM t");
        assert_eq!(explain_sql("explain select 1").unwrap(), "explain select 1");
        assert!(explain_sql("SELECT 1; SELECT 2").is_err());
        assert!(explain_sql("  ").is_err());
    }
}
