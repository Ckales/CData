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

/// 多张表或整个库导出成一个 SQL 文件。和结果集的 ExportOptions 分开：
/// 结果集导出不知道库里还有哪些表，也不该写 DROP / CREATE。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SqlDumpOptions {
    pub encoding: ExportEncoding,
    /// CREATE DATABASE IF NOT EXISTS + USE
    pub create_database: bool,
    /// DROP TABLE / VIEW IF EXISTS
    pub drop_table: bool,
    /// SHOW CREATE 的原文
    pub create_table: bool,
    /// 表数据写成 INSERT。视图没有数据可导
    pub include_data: bool,
}

/// SHOW CREATE DATABASE 没有 IF NOT EXISTS，原样导入时库已存在就会失败
pub(crate) fn create_database_if_not_exists(show_create: &str) -> Result<String, String> {
    let sql = show_create.trim().trim_end_matches(';').trim();
    if sql.is_empty() {
        return Err("SHOW CREATE DATABASE 没有返回语句".to_string());
    }
    let upper = sql.to_ascii_uppercase();
    if upper.starts_with("CREATE DATABASE IF NOT EXISTS") {
        return Ok(sql.to_string());
    }
    const PREFIX: &str = "CREATE DATABASE";
    if upper.starts_with(PREFIX) {
        return Ok(format!(
            "CREATE DATABASE IF NOT EXISTS{}",
            &sql[PREFIX.len()..]
        ));
    }
    Err(format!("认不出的建库语句：{sql}"))
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ExportSummary {
    pub rows_written: u64,
    /// 结果集本身被截断过，导出的不是完整数据
    pub source_truncated: bool,
}

/// INSERT 每条语句带多少行
const ROWS_PER_INSERT: u64 = 100;

/// 写文件。columns 按导出顺序给列下标
pub fn write_file(
    path: &Path,
    columns: &[ColumnMeta],
    rows: &[Vec<CellValue>],
    column_indexes: &[usize],
    options: &ExportOptions,
) -> Result<u64, String> {
    let mut writer = ExportWriter::create(path, columns, column_indexes, options)?;
    for row in rows {
        writer.write_row(row)?;
    }
    writer.finish()
}

pub(crate) fn temp_path(path: &Path) -> PathBuf {
    let mut name = path
        .file_name()
        .map(|n| n.to_os_string())
        .unwrap_or_default();
    name.push(".cdata-part");
    path.with_file_name(name)
}

/// 逐行写导出文件。结果网格一次给一段缓存的行，整表导出边从库里读边写，两边走同一套格式规则。
///
/// 写的是临时文件，finish 成功后才改名成目标文件。没 finish 就丢掉（中途出错）会删掉临时文件，
/// 不会留下一个看起来完整、其实缺了一半的文件
pub struct ExportWriter {
    /// finish 或 drop 时先取出来关掉文件再删改名：Windows 上删不掉打开着的文件
    out: Option<Encoder>,
    path: PathBuf,
    temp: PathBuf,
    column_indexes: Vec<usize>,
    format: RowFormat,
    rows: u64,
    /// 当前这张表已经写进 INSERT 的行数。换表时归零，避免上一张表的批次把下一张的头吞掉
    batch_rows: u64,
    /// 当前 INSERT 还没写分号。换表、写 DDL、收尾之前要先补上
    insert_open: bool,
}

enum RowFormat {
    Csv {
        delimiter: char,
        separator: String,
        null_text: String,
    },
    /// head 是 `INSERT INTO … VALUES\n`，每 ROWS_PER_INSERT 行重复一次
    Sql { head: String },
}

impl ExportWriter {
    /// 先校验选项再建文件，选项不对时不留下任何文件；然后写 BOM 和文件头
    pub fn create(
        path: &Path,
        columns: &[ColumnMeta],
        column_indexes: &[usize],
        options: &ExportOptions,
    ) -> Result<Self, String> {
        for &index in column_indexes {
            if index >= columns.len() {
                return Err(format!("列下标 {index} 越界"));
            }
        }
        if column_indexes.is_empty() {
            return Err("没有选要导出的列".to_string());
        }
        let format = match options.format {
            ExportFormat::Csv => {
                let mut delimiter_chars = options.delimiter.chars();
                let delimiter = match (delimiter_chars.next(), delimiter_chars.next()) {
                    (Some(ch), None) => ch,
                    _ => {
                        return Err(format!(
                            "分隔符必须是单个字符，现在是 {:?}",
                            options.delimiter
                        ))
                    }
                };
                RowFormat::Csv {
                    delimiter,
                    separator: delimiter.to_string(),
                    null_text: options.null_text.clone(),
                }
            }
            ExportFormat::SqlInsert => RowFormat::Sql {
                head: insert_head(columns, column_indexes, options)?,
            },
        };

        let temp = temp_path(path);
        let file = File::create(&temp).map_err(|e| format!("创建文件失败：{e}"))?;
        let mut writer = ExportWriter {
            out: Some(Encoder {
                writer: BufWriter::new(file),
                encoding: options.encoding,
            }),
            path: path.to_path_buf(),
            temp,
            column_indexes: column_indexes.to_vec(),
            format,
            rows: 0,
            batch_rows: 0,
            insert_open: false,
        };
        writer.write_header(columns, options)?;
        Ok(writer)
    }

    /// 一个 SQL 文件，还没有具体的表。后面用 write_sql 写 DDL，begin_insert + write_row 写数据
    pub fn create_sql_dump(path: &Path, encoding: ExportEncoding) -> Result<Self, String> {
        let options = ExportOptions {
            format: ExportFormat::SqlInsert,
            encoding,
            delimiter: ",".to_string(),
            header: false,
            null_text: String::new(),
            table_name: String::new(),
        };
        let temp = temp_path(path);
        let file = File::create(&temp).map_err(|e| format!("创建文件失败：{e}"))?;
        let mut writer = ExportWriter {
            out: Some(Encoder {
                writer: BufWriter::new(file),
                encoding,
            }),
            path: path.to_path_buf(),
            temp,
            column_indexes: Vec::new(),
            format: RowFormat::Sql {
                head: String::new(),
            },
            rows: 0,
            batch_rows: 0,
            insert_open: false,
        };
        writer.write_header(&[], &options)?;
        Ok(writer)
    }

    /// 写一段 SQL（建库、删表、建表、USE）。若上一张表的 INSERT 还没结束，先补分号
    pub fn write_sql(&mut self, sql: &str) -> Result<(), String> {
        if !matches!(self.format, RowFormat::Sql { .. }) {
            return Err("只有 SQL 导出能写语句".to_string());
        }
        self.close_insert()?;
        self.out().text(sql, "语句")
    }

    /// 接下来的 write_row 写成这张表的 INSERT。列名按给出的顺序，调用方传原始列名
    pub fn begin_insert(&mut self, table: &str, column_names: &[String]) -> Result<(), String> {
        if table.is_empty() {
            return Err("表名是空的".to_string());
        }
        if column_names.is_empty() {
            return Err(format!("{table} 没有列"));
        }
        self.close_insert()?;
        let mut names = Vec::with_capacity(column_names.len());
        for name in column_names {
            names.push(quote_ident(name));
        }
        self.format = RowFormat::Sql {
            head: format!(
                "INSERT INTO {} ({}) VALUES\n",
                quote_ident(table),
                names.join(", ")
            ),
        };
        self.column_indexes = (0..column_names.len()).collect();
        self.batch_rows = 0;
        Ok(())
    }

    fn close_insert(&mut self) -> Result<(), String> {
        if self.insert_open {
            self.out().raw(b";\n\n")?;
            self.insert_open = false;
        }
        Ok(())
    }

    fn out(&mut self) -> &mut Encoder {
        self.out
            .as_mut()
            .expect("ExportWriter 在 finish 之后不能再写")
    }

    fn write_header(
        &mut self,
        columns: &[ColumnMeta],
        options: &ExportOptions,
    ) -> Result<(), String> {
        if options.encoding == ExportEncoding::Utf8Bom {
            self.out().raw(&[0xEF, 0xBB, 0xBF])?;
        }
        match &self.format {
            RowFormat::Csv {
                delimiter,
                separator,
                null_text,
            } => {
                if !options.header {
                    return Ok(());
                }
                let mut fields = Vec::with_capacity(self.column_indexes.len());
                for &index in &self.column_indexes {
                    fields.push(csv_quote(&columns[index].name, *delimiter, null_text));
                }
                let line = format!("{}\r\n", fields.join(separator));
                self.out().text(&line, "表头")
            }
            RowFormat::Sql { .. } => {
                let charset = match options.encoding {
                    ExportEncoding::Gbk => "gbk",
                    ExportEncoding::Utf8 | ExportEncoding::Utf8Bom => "utf8mb4",
                };
                // 字符串里的反斜杠按转义符写。临时去掉 NO_BACKSLASH_ESCAPES，导入时不管服务器怎么配都一样
                let header = format!(
                    "-- CData 导出\nSET NAMES {charset};\n\
                     SET @CDATA_OLD_SQL_MODE = @@SESSION.sql_mode;\n\
                     SET SESSION sql_mode = REPLACE(@@SESSION.sql_mode, 'NO_BACKSLASH_ESCAPES', '');\n\n"
                );
                self.out().text(&header, "文件头")
            }
        }
    }

    /// 写一行。row 是结果集的整行，按 create 时给的列下标取
    pub fn write_row(&mut self, row: &[CellValue]) -> Result<(), String> {
        let location = format!("第 {} 行", self.rows + 1);
        let line = match &self.format {
            RowFormat::Csv {
                delimiter,
                separator,
                null_text,
            } => {
                let mut fields = Vec::with_capacity(self.column_indexes.len());
                for &index in &self.column_indexes {
                    let field = match &row[index] {
                        CellValue::Null => null_text.clone(),
                        CellValue::Int(n) => n.to_string(),
                        CellValue::UInt(n) => n.to_string(),
                        CellValue::Double(n) => n.to_string(),
                        CellValue::Text(text) => csv_quote(text, *delimiter, null_text),
                        CellValue::Bytes(bytes) | CellValue::InvalidText(bytes) => hex(bytes, "0x"),
                    };
                    fields.push(field);
                }
                format!("{}\r\n", fields.join(separator))
            }
            RowFormat::Sql { head } => {
                if head.is_empty() {
                    return Err("还没指定 INSERT 的表".to_string());
                }
                let mut values = Vec::with_capacity(self.column_indexes.len());
                for &index in &self.column_indexes {
                    values.push(sql_literal(&row[index]));
                }
                // 不知道后面还有没有行，所以分隔符写在行前：每批第一行前写 INSERT 头，其余行前写逗号
                if self.batch_rows % ROWS_PER_INSERT == 0 {
                    let head = head.clone();
                    if self.insert_open {
                        self.out().raw(b";\n")?;
                    }
                    self.out().text(&head, "表名或列名")?;
                    self.insert_open = true;
                    format!("  ({})", values.join(", "))
                } else {
                    format!(",\n  ({})", values.join(", "))
                }
            }
        };
        self.out().text(&line, &location)?;
        self.rows += 1;
        self.batch_rows += 1;
        Ok(())
    }

    /// 写文件尾、落盘、改名成目标文件，返回写了多少行
    pub fn finish(mut self) -> Result<u64, String> {
        let rows = self.rows;
        if let RowFormat::Sql { .. } = self.format {
            let mut tail = String::new();
            if self.insert_open {
                tail.push_str(";\n");
                self.insert_open = false;
            }
            tail.push_str(&format!(
                "\n-- 共 {rows} 行\nSET SESSION sql_mode = @CDATA_OLD_SQL_MODE;\n"
            ));
            self.out().text(&tail, "文件尾")?;
        }
        let mut out = self.out.take().expect("ExportWriter 只能 finish 一次");
        out.writer.flush().map_err(|e| format!("写文件失败：{e}"))?;
        drop(out);
        fs::rename(&self.temp, &self.path).map_err(|e| format!("保存文件失败：{e}"))?;
        Ok(rows)
    }
}

impl Drop for ExportWriter {
    /// 没 finish 成功就丢掉的，删掉半截的临时文件。改名成功后临时文件已经不在了，删除失败无所谓
    fn drop(&mut self) {
        drop(self.out.take());
        let _ = fs::remove_file(&self.temp);
    }
}

/// INSERT 的头：目标表名和列名
fn insert_head(
    columns: &[ColumnMeta],
    column_indexes: &[usize],
    options: &ExportOptions,
) -> Result<String, String> {
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
        let name = if column.org_table == table {
            &column.org_name
        } else {
            &column.name
        };
        names.push(quote_ident(name));
    }
    Ok(format!(
        "INSERT INTO {} ({}) VALUES\n",
        quote_ident(&table),
        names.join(", ")
    ))
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
                    return Err(format!(
                        "{location} 里有 GBK 表示不了的字符，换成 UTF-8 导出"
                    ));
                }
                self.raw(&bytes)
            }
        }
    }

    pub(crate) fn raw(&mut self, bytes: &[u8]) -> Result<(), String> {
        self.writer
            .write_all(bytes)
            .map_err(|e| format!("写文件失败：{e}"))
    }
}

/// RFC 4180 的引号规则，外加一条：和 NULL 的写法撞车的文本也加引号（空串就写成 ""）
pub(crate) fn csv_quote(text: &str, delimiter: char, null_text: &str) -> String {
    let needs_quotes =
        text == null_text || text.contains(delimiter) || text.contains(['"', '\r', '\n']);
    if needs_quotes {
        format!("\"{}\"", text.replace('"', "\"\""))
    } else {
        text.to_string()
    }
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
        let columns = vec![
            column("id", "id"),
            column("备注", "note"),
            column("amount", "amount"),
        ];
        let rows = vec![
            vec![
                CellValue::Int(1),
                CellValue::Text("a,b \"引号\"".into()),
                CellValue::Text("1.50".into()),
            ],
            vec![
                CellValue::UInt(u64::MAX),
                CellValue::Null,
                CellValue::Text(String::new()),
            ],
            vec![
                CellValue::Int(3),
                CellValue::Text("it's C:\\temp".into()),
                CellValue::Bytes(vec![0x00, 0xFF]),
            ],
        ];
        (columns, rows)
    }

    fn export_to_string(
        options: &ExportOptions,
        column_indexes: &[usize],
    ) -> Result<Vec<u8>, String> {
        let (columns, rows) = sample();
        let dir = std::env::temp_dir().join(format!(
            "cdata-export-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
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
        let rows = vec![vec![
            CellValue::Null,
            CellValue::Text("NULL".into()),
            CellValue::Text(String::new()),
        ]];
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
        assert!(
            text.contains("INSERT INTO `orders` (`id`, `note`, `amount`) VALUES\n"),
            "{text}"
        );
        assert!(text.contains("  (1, 'a,b \"引号\"', '1.50'),\n"), "{text}");
        assert!(
            text.contains("  (18446744073709551615, NULL, ''),\n"),
            "{text}"
        );
        assert!(
            text.contains("  (3, 'it''s C:\\\\temp', X'00FF');\n"),
            "{text}"
        );
        assert!(
            text.trim_end()
                .ends_with("SET SESSION sql_mode = @CDATA_OLD_SQL_MODE;"),
            "{text}"
        );
    }

    #[test]
    fn sql_into_another_table_uses_result_column_names() {
        let mut opts = options(ExportFormat::SqlInsert);
        opts.table_name = "archive".to_string();
        let text = String::from_utf8(export_to_string(&opts, &[1]).unwrap()).unwrap();
        assert!(
            text.contains("INSERT INTO `archive` (`备注`) VALUES"),
            "{text}"
        );
    }

    #[test]
    fn sql_without_a_single_source_table_asks_for_a_name() {
        let (mut columns, rows) = sample();
        columns[0].org_table = "users".to_string();
        let path =
            std::env::temp_dir().join(format!("cdata-export-join-{}.sql", std::process::id()));
        let err = write_file(
            &path,
            &columns,
            &rows,
            &[0, 1],
            &options(ExportFormat::SqlInsert),
        )
        .unwrap_err();
        assert!(err.contains("表名"), "{err}");
        assert!(!path.exists(), "失败时不能留下文件");
        assert!(!temp_path(&path).exists(), "临时文件也要清掉");
    }

    #[test]
    fn gbk_refuses_characters_it_cannot_represent_and_leaves_no_file() {
        let mut opts = options(ExportFormat::Csv);
        opts.encoding = ExportEncoding::Gbk;
        let columns = vec![column("name", "name")];
        let rows = vec![
            vec![CellValue::Text("中文".into())],
            vec![CellValue::Text("emoji 😀".into())],
        ];
        let path =
            std::env::temp_dir().join(format!("cdata-export-gbk-{}.csv", std::process::id()));

        let err = write_file(&path, &columns, &rows, &[0], &opts).unwrap_err();
        assert!(err.contains("第 2 行"), "要指出是哪一行：{err}");
        assert!(!path.exists());
        assert!(!temp_path(&path).exists());

        // 能表示的正常写成 GBK 字节
        let ok_rows = vec![vec![CellValue::Text("中文".into())]];
        opts.header = false;
        write_file(&path, &columns, &ok_rows, &[0], &opts).unwrap();
        assert_eq!(
            fs::read(&path).unwrap(),
            [0xD6, 0xD0, 0xCE, 0xC4, b'\r', b'\n']
        );
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
        assert!(export_to_string(&opts, &[0])
            .unwrap_err()
            .contains("单个字符"));
    }

    #[test]
    fn sql_with_no_rows_is_still_a_valid_script() {
        let path =
            std::env::temp_dir().join(format!("cdata-export-empty-{}.sql", std::process::id()));
        let rows_written = write_file(
            &path,
            &[column("id", "id")],
            &[],
            &[0],
            &options(ExportFormat::SqlInsert),
        )
        .unwrap();
        let text = fs::read_to_string(&path).unwrap();
        fs::remove_file(&path).ok();
        assert_eq!(rows_written, 0);
        assert!(
            !text.contains("INSERT"),
            "空表不能写出没有 VALUES 的 INSERT：{text}"
        );
        assert!(!text.contains(";\n;"), "{text}");
        assert!(text.contains("-- 共 0 行"), "{text}");
    }

    #[test]
    fn dropping_an_unfinished_writer_leaves_no_file() {
        let path =
            std::env::temp_dir().join(format!("cdata-export-abandon-{}.csv", std::process::id()));
        let mut writer = ExportWriter::create(
            &path,
            &[column("id", "id")],
            &[0],
            &options(ExportFormat::Csv),
        )
        .unwrap();
        writer.write_row(&[CellValue::Int(1)]).unwrap();
        drop(writer);
        assert!(!path.exists());
        assert!(!temp_path(&path).exists(), "半截的临时文件要删掉");
    }

    #[test]
    fn sql_splits_into_batches() {
        let columns = vec![column("id", "id")];
        let mut rows = Vec::new();
        for i in 0..250 {
            rows.push(vec![CellValue::Int(i)]);
        }
        let path =
            std::env::temp_dir().join(format!("cdata-export-batch-{}.sql", std::process::id()));
        write_file(
            &path,
            &columns,
            &rows,
            &[0],
            &options(ExportFormat::SqlInsert),
        )
        .unwrap();
        let text = fs::read_to_string(&path).unwrap();
        fs::remove_file(&path).ok();
        assert_eq!(
            text.matches("INSERT INTO").count(),
            3,
            "250 行分成 100 + 100 + 50"
        );
    }

    #[test]
    fn sql_dump_closes_each_table_before_the_next() {
        let dir = std::env::temp_dir().join(format!("cdata-export-dump-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("dump.sql");
        let mut writer = ExportWriter::create_sql_dump(&path, ExportEncoding::Utf8).unwrap();
        writer
            .write_sql("USE `shop`;\nSET FOREIGN_KEY_CHECKS=0;\n")
            .unwrap();
        writer.begin_insert("orders", &["id".to_string()]).unwrap();
        writer.write_row(&[CellValue::Int(1)]).unwrap();
        writer.write_row(&[CellValue::Int(2)]).unwrap();
        writer.write_sql("DROP TABLE IF EXISTS `items`;\n").unwrap();
        writer
            .begin_insert("items", &["id".to_string(), "name".to_string()])
            .unwrap();
        writer
            .write_row(&[CellValue::Int(9), CellValue::Text("a'b".into())])
            .unwrap();
        let rows = writer.finish().unwrap();
        let text = fs::read_to_string(&path).unwrap();
        fs::remove_dir_all(&dir).ok();

        assert_eq!(rows, 3);
        assert_eq!(text.matches("SET NAMES").count(), 1, "文件头只写一次");
        assert!(
            text.contains("USE `shop`;\nSET FOREIGN_KEY_CHECKS=0;\n"),
            "{text}"
        );
        assert!(text.contains("INSERT INTO `orders` (`id`) VALUES\n  (1),\n  (2);\n\nDROP TABLE IF EXISTS `items`;\n"), "{text}");
        assert!(
            text.contains("INSERT INTO `items` (`id`, `name`) VALUES\n  (9, 'a''b');\n"),
            "{text}"
        );
        assert_eq!(
            text.matches("SET SESSION sql_mode = @CDATA_OLD_SQL_MODE;")
                .count(),
            1
        );
    }

    #[test]
    fn create_database_statement_gains_if_not_exists() {
        assert_eq!(
            create_database_if_not_exists(
                "CREATE DATABASE `shop` /*!40100 DEFAULT CHARACTER SET utf8mb4 */"
            )
            .unwrap(),
            "CREATE DATABASE IF NOT EXISTS `shop` /*!40100 DEFAULT CHARACTER SET utf8mb4 */"
        );
        assert_eq!(
            create_database_if_not_exists("CREATE DATABASE IF NOT EXISTS `shop`").unwrap(),
            "CREATE DATABASE IF NOT EXISTS `shop`"
        );
        assert!(create_database_if_not_exists("").is_err());
        assert!(create_database_if_not_exists("DROP DATABASE `shop`").is_err());
    }
}
