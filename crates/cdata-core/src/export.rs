//! 把结果集导出成 CSV 或 INSERT 语句。
//!
//! 数据直接从会话缓存的行里写文件，不经过 FFI。先写临时文件、成功后再改名，
//! 中途出错（比如 GBK 表示不了某个字）不会留下一个看起来完整、其实缺了一半的文件。

use std::fs::{self, File};
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::db::ColumnMeta;
use crate::sql::quote_ident;
use crate::value::CellValue;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ExportFormat {
    Csv,
    SqlInsert,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ExportEncoding {
    Utf8,
    /// 带 BOM，Windows 上的 Excel 靠它认出 UTF-8
    Utf8Bom,
    Gbk,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ExportOptions {
    pub format: ExportFormat,
    pub encoding: ExportEncoding,
    /// CSV 分隔符，必须是单个字符
    pub delimiter: String,
    /// CSV 第一行写列名
    pub header: bool,
    /// CSV 里 NULL 写成什么：空、NULL、\N。和它撞车的文本一律加引号区分
    pub null_text: String,
    /// INSERT 的目标表。空串表示用结果集的来源表，来源不是单张表就报错
    pub table_name: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ExportSummary {
    pub rows_written: u64,
    /// 结果集本身被截断过，导出的不是完整数据
    pub source_truncated: bool,
}

/// INSERT 每条语句带多少行
const ROWS_PER_INSERT: usize = 100;

/// 写文件。columns 按导出顺序给列下标
pub fn write_file(
    path: &Path,
    columns: &[ColumnMeta],
    rows: &[Vec<CellValue>],
    column_indexes: &[usize],
    options: &ExportOptions,
) -> Result<u64, String> {
    for &index in column_indexes {
        if index >= columns.len() {
            return Err(format!("列下标 {index} 越界"));
        }
    }
    if column_indexes.is_empty() {
        return Err("没有选要导出的列".to_string());
    }

    let temp = temp_path(path);
    let result = write_to(&temp, columns, rows, column_indexes, options);
    match result {
        Ok(()) => {
            fs::rename(&temp, path).map_err(|e| format!("保存文件失败：{e}"))?;
            Ok(rows.len() as u64)
        }
        Err(err) => {
            // 半截的临时文件留着只会误导人
            let _ = fs::remove_file(&temp);
            Err(err)
        }
    }
}

pub(crate) fn temp_path(path: &Path) -> PathBuf {
    let mut name = path.file_name().map(|n| n.to_os_string()).unwrap_or_default();
    name.push(".cdata-part");
    path.with_file_name(name)
}

fn write_to(
    path: &Path,
    columns: &[ColumnMeta],
    rows: &[Vec<CellValue>],
    column_indexes: &[usize],
    options: &ExportOptions,
) -> Result<(), String> {
    let file = File::create(path).map_err(|e| format!("创建文件失败：{e}"))?;
    let mut out = Encoder { writer: BufWriter::new(file), encoding: options.encoding };

    if options.encoding == ExportEncoding::Utf8Bom {
        out.raw(&[0xEF, 0xBB, 0xBF])?;
    }

    match options.format {
        ExportFormat::Csv => write_csv(&mut out, columns, rows, column_indexes, options)?,
        ExportFormat::SqlInsert => write_sql(&mut out, columns, rows, column_indexes, options)?,
    }

    out.writer.flush().map_err(|e| format!("写文件失败：{e}"))
}

/// 按目标编码写文本。GBK 表示不了的字符报错并带上位置，不替换成 ?
pub(crate) struct Encoder {
    pub(crate) writer: BufWriter<File>,
    pub(crate) encoding: ExportEncoding,
}

impl Encoder {
    pub(crate) fn text(&mut self, text: &str, location: &str) -> Result<(), String> {
        match self.encoding {
            ExportEncoding::Utf8 | ExportEncoding::Utf8Bom => self.raw(text.as_bytes()),
            ExportEncoding::Gbk => {
                let (bytes, _, had_errors) = encoding_rs::GBK.encode(text);
                if had_errors {
                    return Err(format!("{location} 里有 GBK 表示不了的字符，换成 UTF-8 导出"));
                }
                self.raw(&bytes)
            }
        }
    }

    pub(crate) fn raw(&mut self, bytes: &[u8]) -> Result<(), String> {
        self.writer.write_all(bytes).map_err(|e| format!("写文件失败：{e}"))
    }
}

fn write_csv(
    out: &mut Encoder,
    columns: &[ColumnMeta],
    rows: &[Vec<CellValue>],
    column_indexes: &[usize],
    options: &ExportOptions,
) -> Result<(), String> {
    let mut delimiter_chars = options.delimiter.chars();
    let delimiter = match (delimiter_chars.next(), delimiter_chars.next()) {
        (Some(ch), None) => ch,
        _ => return Err(format!("分隔符必须是单个字符，现在是 {:?}", options.delimiter)),
    };
    let separator = delimiter.to_string();

    if options.header {
        let mut fields = Vec::with_capacity(column_indexes.len());
        for &index in column_indexes {
            fields.push(csv_quote(&columns[index].name, delimiter, &options.null_text));
        }
        out.text(&fields.join(&separator), "表头")?;
        out.raw(b"\r\n")?;
    }

    for (row_number, row) in rows.iter().enumerate() {
        let mut fields = Vec::with_capacity(column_indexes.len());
        for &index in column_indexes {
            let field = match &row[index] {
                CellValue::Null => options.null_text.clone(),
                CellValue::Int(n) => n.to_string(),
                CellValue::UInt(n) => n.to_string(),
                CellValue::Double(n) => n.to_string(),
                CellValue::Text(text) => csv_quote(text, delimiter, &options.null_text),
                CellValue::Bytes(bytes) | CellValue::InvalidText(bytes) => hex(bytes, "0x"),
            };
            fields.push(field);
        }
        let location = format!("第 {} 行", row_number + 1);
        out.text(&fields.join(&separator), &location)?;
        out.raw(b"\r\n")?;
    }
    Ok(())
}

/// RFC 4180 的引号规则，外加一条：和 NULL 的写法撞车的文本也加引号（空串就写成 ""）
pub(crate) fn csv_quote(text: &str, delimiter: char, null_text: &str) -> String {
    let needs_quotes = text == null_text
        || text.contains(delimiter)
        || text.contains(['"', '\r', '\n']);
    if needs_quotes {
        format!("\"{}\"", text.replace('"', "\"\""))
    } else {
        text.to_string()
    }
}

fn write_sql(
    out: &mut Encoder,
    columns: &[ColumnMeta],
    rows: &[Vec<CellValue>],
    column_indexes: &[usize],
    options: &ExportOptions,
) -> Result<(), String> {
    let table = if options.table_name.is_empty() {
        match crate::edit::single_source_table(columns) {
            Ok((_, table)) => table,
            Err(reason) => return Err(format!("{reason}。请填写要导出到的表名")),
        }
    } else {
        options.table_name.clone()
    };

    // 列来自这张表就用原始列名，别名写进 INSERT 会找不到列；导出到别的表就用结果集里的列名
    let mut names = Vec::with_capacity(column_indexes.len());
    for &index in column_indexes {
        let column = &columns[index];
        let name = if column.org_table == table { &column.org_name } else { &column.name };
        names.push(quote_ident(name));
    }
    let head = format!("INSERT INTO {} ({}) VALUES\n", quote_ident(&table), names.join(", "));

    let charset = match options.encoding {
        ExportEncoding::Gbk => "gbk",
        ExportEncoding::Utf8 | ExportEncoding::Utf8Bom => "utf8mb4",
    };
    // 字符串里的反斜杠按转义符写。临时去掉 NO_BACKSLASH_ESCAPES，导入时不管服务器怎么配都一样
    out.text(
        &format!(
            "-- CData 导出，{} 行\nSET NAMES {charset};\n\
             SET @CDATA_OLD_SQL_MODE = @@SESSION.sql_mode;\n\
             SET SESSION sql_mode = REPLACE(@@SESSION.sql_mode, 'NO_BACKSLASH_ESCAPES', '');\n\n",
            rows.len()
        ),
        "文件头",
    )?;

    for (chunk_index, chunk) in rows.chunks(ROWS_PER_INSERT).enumerate() {
        out.text(&head, "表名或列名")?;
        for (offset, row) in chunk.iter().enumerate() {
            let mut values = Vec::with_capacity(column_indexes.len());
            for &index in column_indexes {
                values.push(sql_literal(&row[index]));
            }
            let last = offset + 1 == chunk.len();
            let line = format!("  ({}){}\n", values.join(", "), if last { ";" } else { "," });
            let location = format!("第 {} 行", chunk_index * ROWS_PER_INSERT + offset + 1);
            out.text(&line, &location)?;
        }
    }

    out.text("\nSET SESSION sql_mode = @CDATA_OLD_SQL_MODE;\n", "文件尾")
}

/// 值写成 SQL 字面量。文本一律加引号，由 MySQL 按列类型转（DECIMAL 这样不丢精度）
fn sql_literal(cell: &CellValue) -> String {
    match cell {
        CellValue::Null => "NULL".to_string(),
        CellValue::Int(n) => n.to_string(),
        CellValue::UInt(n) => n.to_string(),
        CellValue::Double(n) => n.to_string(),
        CellValue::Text(text) => {
            let mut escaped = String::with_capacity(text.len() + 2);
            escaped.push('\'');
            for ch in text.chars() {
                match ch {
                    '\'' => escaped.push_str("''"),
                    '\\' => escaped.push_str("\\\\"),
                    '\0' => escaped.push_str("\\0"),
                    // Windows 上 Ctrl-Z 会被当成文件结束
                    '\u{1a}' => escaped.push_str("\\Z"),
                    other => escaped.push(other),
                }
            }
            escaped.push('\'');
            escaped
        }
        // 二进制和解不了码的字节原样导出，X'' 对空值也合法（0x 不行）
        CellValue::Bytes(bytes) | CellValue::InvalidText(bytes) => format!("X'{}'", hex(bytes, "")),
    }
}

fn hex(bytes: &[u8], prefix: &str) -> String {
    let mut out = String::with_capacity(prefix.len() + bytes.len() * 2);
    out.push_str(prefix);
    for byte in bytes {
        out.push_str(&format!("{byte:02X}"));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::ColumnKind;

    fn column(name: &str, org_name: &str) -> ColumnMeta {
        ColumnMeta {
            name: name.to_string(),
            org_name: org_name.to_string(),
            org_table: "orders".to_string(),
            schema: "shop".to_string(),
            is_binary: false,
            kind: ColumnKind::Text,
            decimals: 0,
        }
    }

    fn options(format: ExportFormat) -> ExportOptions {
        ExportOptions {
            format,
            encoding: ExportEncoding::Utf8,
            delimiter: ",".to_string(),
            header: true,
            null_text: String::new(),
            table_name: String::new(),
        }
    }

    fn sample() -> (Vec<ColumnMeta>, Vec<Vec<CellValue>>) {
        let columns = vec![column("id", "id"), column("备注", "note"), column("amount", "amount")];
        let rows = vec![
            vec![CellValue::Int(1), CellValue::Text("a,b \"引号\"".into()), CellValue::Text("1.50".into())],
            vec![CellValue::UInt(u64::MAX), CellValue::Null, CellValue::Text(String::new())],
            vec![CellValue::Int(3), CellValue::Text("it's C:\\temp".into()), CellValue::Bytes(vec![0x00, 0xFF])],
        ];
        (columns, rows)
    }

    fn export_to_string(options: &ExportOptions, column_indexes: &[usize]) -> Result<Vec<u8>, String> {
        let (columns, rows) = sample();
        let dir = std::env::temp_dir().join(format!("cdata-export-{}-{:?}", std::process::id(), std::thread::current().id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("out.txt");
        let result = write_file(&path, &columns, &rows, column_indexes, options);
        let bytes = fs::read(&path).ok();
        fs::remove_dir_all(&dir).ok();
        result.map(|_| bytes.expect("成功时文件必须在"))
    }

    #[test]
    fn csv_quotes_like_rfc4180_and_keeps_null_apart_from_empty_string() {
        let bytes = export_to_string(&options(ExportFormat::Csv), &[0, 1, 2]).unwrap();
        let text = String::from_utf8(bytes).unwrap();
        assert_eq!(
            text,
            "id,备注,amount\r\n\
             1,\"a,b \"\"引号\"\"\",1.50\r\n\
             18446744073709551615,,\"\"\r\n\
             3,it's C:\\temp,0x00FF\r\n"
        );
    }

    #[test]
    fn csv_null_text_that_collides_with_a_value_gets_quoted() {
        let mut opts = options(ExportFormat::Csv);
        opts.null_text = "NULL".to_string();
        opts.header = false;
        opts.delimiter = "\t".to_string();

        let (columns, _) = sample();
        let rows = vec![vec![CellValue::Null, CellValue::Text("NULL".into()), CellValue::Text(String::new())]];
        let dir = std::env::temp_dir().join(format!("cdata-export-null-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("out.tsv");
        write_file(&path, &columns, &rows, &[0, 1, 2], &opts).unwrap();
        let text = fs::read_to_string(&path).unwrap();
        fs::remove_dir_all(&dir).ok();

        assert_eq!(text, "NULL\t\"NULL\"\t\r\n");
    }

    #[test]
    fn sql_uses_original_column_names_and_escapes_strings() {
        let bytes = export_to_string(&options(ExportFormat::SqlInsert), &[0, 1, 2]).unwrap();
        let text = String::from_utf8(bytes).unwrap();

        assert!(text.contains("SET NAMES utf8mb4;"), "{text}");
        // 别名「备注」写进 INSERT 会找不到列，要用原始列名 note
        assert!(text.contains("INSERT INTO `orders` (`id`, `note`, `amount`) VALUES\n"), "{text}");
        assert!(text.contains("  (1, 'a,b \"引号\"', '1.50'),\n"), "{text}");
        assert!(text.contains("  (18446744073709551615, NULL, ''),\n"), "{text}");
        assert!(text.contains("  (3, 'it''s C:\\\\temp', X'00FF');\n"), "{text}");
        assert!(text.trim_end().ends_with("SET SESSION sql_mode = @CDATA_OLD_SQL_MODE;"), "{text}");
    }

    #[test]
    fn sql_into_another_table_uses_result_column_names() {
        let mut opts = options(ExportFormat::SqlInsert);
        opts.table_name = "archive".to_string();
        let text = String::from_utf8(export_to_string(&opts, &[1]).unwrap()).unwrap();
        assert!(text.contains("INSERT INTO `archive` (`备注`) VALUES"), "{text}");
    }

    #[test]
    fn sql_without_a_single_source_table_asks_for_a_name() {
        let (mut columns, rows) = sample();
        columns[0].org_table = "users".to_string();
        let path = std::env::temp_dir().join(format!("cdata-export-join-{}.sql", std::process::id()));
        let err = write_file(&path, &columns, &rows, &[0, 1], &options(ExportFormat::SqlInsert)).unwrap_err();
        assert!(err.contains("表名"), "{err}");
        assert!(!path.exists(), "失败时不能留下文件");
        assert!(!temp_path(&path).exists(), "临时文件也要清掉");
    }

    #[test]
    fn gbk_refuses_characters_it_cannot_represent_and_leaves_no_file() {
        let mut opts = options(ExportFormat::Csv);
        opts.encoding = ExportEncoding::Gbk;
        let columns = vec![column("name", "name")];
        let rows = vec![vec![CellValue::Text("中文".into())], vec![CellValue::Text("emoji 😀".into())]];
        let path = std::env::temp_dir().join(format!("cdata-export-gbk-{}.csv", std::process::id()));

        let err = write_file(&path, &columns, &rows, &[0], &opts).unwrap_err();
        assert!(err.contains("第 2 行"), "要指出是哪一行：{err}");
        assert!(!path.exists());
        assert!(!temp_path(&path).exists());

        // 能表示的正常写成 GBK 字节
        let ok_rows = vec![vec![CellValue::Text("中文".into())]];
        opts.header = false;
        write_file(&path, &columns, &ok_rows, &[0], &opts).unwrap();
        assert_eq!(fs::read(&path).unwrap(), [0xD6, 0xD0, 0xCE, 0xC4, b'\r', b'\n']);
        fs::remove_file(&path).ok();
    }

    #[test]
    fn utf8_bom_is_written_first() {
        let mut opts = options(ExportFormat::Csv);
        opts.encoding = ExportEncoding::Utf8Bom;
        let bytes = export_to_string(&opts, &[0]).unwrap();
        assert_eq!(&bytes[..3], [0xEF, 0xBB, 0xBF]);
    }

    #[test]
    fn multi_char_delimiter_is_refused() {
        let mut opts = options(ExportFormat::Csv);
        opts.delimiter = ";;".to_string();
        assert!(export_to_string(&opts, &[0]).unwrap_err().contains("单个字符"));
    }

    #[test]
    fn sql_splits_into_batches() {
        let columns = vec![column("id", "id")];
        let mut rows = Vec::new();
        for i in 0..250 {
            rows.push(vec![CellValue::Int(i)]);
        }
        let path = std::env::temp_dir().join(format!("cdata-export-batch-{}.sql", std::process::id()));
        write_file(&path, &columns, &rows, &[0], &options(ExportFormat::SqlInsert)).unwrap();
        let text = fs::read_to_string(&path).unwrap();
        fs::remove_file(&path).ok();
        assert_eq!(text.matches("INSERT INTO").count(), 3, "250 行分成 100 + 100 + 50");
    }
}
