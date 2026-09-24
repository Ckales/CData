//! 剪贴板的 TSV 编解码，和 Excel / Numbers 的格式对齐：制表符分列、换行分行，
//! 含制表符、换行、双引号的字段整个用双引号包起来，内部的双引号双写。
//!
//! 表格软件没有 NULL，这里约定：**不带引号的 `NULL` 是 NULL**，内容恰好是文本 "NULL"
//! 时复制成带引号的 `"NULL"`。在 CData 里复制再粘贴，NULL 和文本 "NULL" 不会混。
//! 空字段是空字符串，不是 NULL。

use crate::value::CellValue;

/// 把若干行的指定列编码成 TSV，列按 columns 给的顺序
pub fn encode(rows: &[Vec<CellValue>], columns: &[usize]) -> Result<String, String> {
    let mut lines = Vec::with_capacity(rows.len());
    for row in rows {
        let mut fields = Vec::with_capacity(columns.len());
        for &column in columns {
            let cell = row
                .get(column)
                .ok_or_else(|| format!("列下标 {column} 越界"))?;
            fields.push(encode_field(cell));
        }
        lines.push(fields.join("\t"));
    }
    Ok(lines.join("\n"))
}

fn encode_field(cell: &CellValue) -> String {
    match cell {
        CellValue::Null => "NULL".to_string(),
        CellValue::Int(n) => n.to_string(),
        CellValue::UInt(n) => n.to_string(),
        CellValue::Double(n) => n.to_string(),
        CellValue::Text(text) => {
            let needs_quotes =
                text == "NULL" || text.contains(['\t', '\n', '\r', '"']);
            if needs_quotes {
                format!("\"{}\"", text.replace('"', "\"\""))
            } else {
                text.clone()
            }
        }
        // 显示用的占位（<二进制 12 字节>）粘到别处就成了假数据，复制真实字节的十六进制
        CellValue::Bytes(bytes) | CellValue::InvalidText(bytes) => {
            let mut hex = String::with_capacity(2 + bytes.len() * 2);
            hex.push_str("0x");
            for byte in bytes {
                hex.push_str(&format!("{byte:02X}"));
            }
            hex
        }
    }
}

/// 解析剪贴板里的 TSV。结果必须是规整的矩形，每行列数不同就拒绝，不猜怎么对齐
pub fn decode(text: &str) -> Result<Vec<Vec<CellValue>>, String> {
    let mut rows: Vec<Vec<CellValue>> = Vec::new();
    let mut row = Vec::new();
    let mut field = String::new();
    // 字段以引号开头；这样的 NULL 是文本，不是 NULL
    let mut quoted = false;
    let mut in_quotes = false;

    let mut chars = text.chars().peekable();
    while let Some(ch) = chars.next() {
        if in_quotes {
            if ch == '"' {
                if chars.peek() == Some(&'"') {
                    chars.next();
                    field.push('"');
                } else {
                    in_quotes = false;
                }
            } else {
                field.push(ch);
            }
            continue;
        }

        match ch {
            '"' if field.is_empty() && !quoted => {
                quoted = true;
                in_quotes = true;
            }
            '\t' => row.push(finish_field(&mut field, &mut quoted)),
            '\r' | '\n' => {
                // Windows 的 Excel 用 \r\n
                if ch == '\r' && chars.peek() == Some(&'\n') {
                    chars.next();
                }
                row.push(finish_field(&mut field, &mut quoted));
                rows.push(std::mem::take(&mut row));
            }
            _ => field.push(ch),
        }
    }

    if in_quotes {
        return Err("剪贴板内容的引号没有闭合，不是合法的表格数据".to_string());
    }
    // 最后一行没有换行结尾。表格软件通常会在末尾补一个换行，那种情况这里什么都不剩
    if !field.is_empty() || quoted || !row.is_empty() {
        row.push(finish_field(&mut field, &mut quoted));
        rows.push(row);
    }

    let Some(first) = rows.first() else {
        return Err("剪贴板是空的".to_string());
    };
    let width = first.len();
    for (index, row) in rows.iter().enumerate() {
        if row.len() != width {
            return Err(format!(
                "第 {} 行有 {} 列，第 1 行有 {width} 列，不是规整的一块区域",
                index + 1,
                row.len()
            ));
        }
    }
    Ok(rows)
}

fn finish_field(field: &mut String, quoted: &mut bool) -> CellValue {
    let text = std::mem::take(field);
    let was_quoted = std::mem::replace(quoted, false);
    if !was_quoted && text == "NULL" {
        CellValue::Null
    } else {
        CellValue::Text(text)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(s: &str) -> CellValue {
        CellValue::Text(s.to_string())
    }

    #[test]
    fn encodes_in_the_given_column_order() {
        let rows = vec![
            vec![CellValue::Int(1), text("a"), CellValue::UInt(u64::MAX)],
            vec![CellValue::Int(2), text("b"), CellValue::Null],
        ];
        assert_eq!(
            encode(&rows, &[2, 0]).unwrap(),
            "18446744073709551615\t1\nNULL\t2"
        );
    }

    #[test]
    fn null_and_the_text_null_stay_distinguishable() {
        let rows = vec![vec![CellValue::Null, text("NULL"), text("")]];
        let tsv = encode(&rows, &[0, 1, 2]).unwrap();
        assert_eq!(tsv, "NULL\t\"NULL\"\t");
        assert_eq!(decode(&tsv).unwrap(), rows, "空串也不能变成 NULL");
    }

    #[test]
    fn fields_with_tabs_newlines_and_quotes_are_quoted() {
        let rows = vec![vec![text("a\tb"), text("第一行\n第二行"), text("说\"好\"")]];
        let tsv = encode(&rows, &[0, 1, 2]).unwrap();
        assert_eq!(tsv, "\"a\tb\"\t\"第一行\n第二行\"\t\"说\"\"好\"\"\"");
        assert_eq!(decode(&tsv).unwrap(), rows);
    }

    #[test]
    fn binary_is_copied_as_hex_not_as_the_placeholder() {
        let rows = vec![vec![CellValue::Bytes(vec![0x00, 0xFF, 0x10])]];
        assert_eq!(encode(&rows, &[0]).unwrap(), "0x00FF10");
    }

    #[test]
    fn excel_crlf_and_trailing_newline_are_handled() {
        assert_eq!(
            decode("1\ta\r\n2\tb\r\n").unwrap(),
            vec![vec![text("1"), text("a")], vec![text("2"), text("b")]]
        );
    }

    #[test]
    fn a_single_empty_cell_is_an_empty_string() {
        assert_eq!(decode("\n").unwrap(), vec![vec![text("")]]);
    }

    #[test]
    fn ragged_rows_are_refused() {
        let err = decode("1\t2\n3").unwrap_err();
        assert!(err.contains("规整"), "{err}");
    }

    #[test]
    fn unclosed_quote_is_refused() {
        assert!(decode("\"abc").unwrap_err().contains("引号"));
    }

    #[test]
    fn empty_clipboard_is_refused() {
        assert!(decode("").unwrap_err().contains("空"));
    }
}
