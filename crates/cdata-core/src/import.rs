//! 把 CSV 导入到已有的表。
//!
//! 规则和 export.rs 对称，同样的选项导出再导回来数据必须一模一样：
//! - 没加引号、且正好等于 null_text 的字段是 NULL；加了引号的永远是文本（空串导出成 `""`）
//! - 二进制列导出成不加引号的 `0x…` 十六进制，导入时按**目标列的元数据**解回字节，不看值猜
//! - 编码由用户选，不猜；解码失败报出第几行，不替换成 U+FFFD
//!
//! 文件边读边解析边写库，不整个读进内存。值一律按文本走 prepared statement 的参数，
//! 由 MySQL 按列类型转换；导入用的连接临时加上 STRICT_ALL_TABLES，放不下的值报错而不是被截断。

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{BufWriter, Read};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use encoding_rs::{Decoder, DecoderResult};
use mysql_async::prelude::*;
use mysql_async::{Conn, Value};
use serde::{Deserialize, Serialize};

use crate::db::{run_query, DbPool};
use crate::export::{csv_quote, temp_path, Encoder, ExportEncoding};
use crate::session::{Error, Result};
use crate::sql::quote_ident;
use crate::structure::{table_columns, DefaultValue};
use crate::value::{value_to_mysql, CellValue, DisplayCell};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ImportOptions {
    /// 和导出共用一套编码选项：UTF-8 / UTF-8 BOM / GBK
    pub encoding: ExportEncoding,
    /// 必须是单个字符，不能是双引号或换行
    pub delimiter: String,
    /// 第一行是列名
    pub header: bool,
    /// 没加引号时表示 NULL 的写法：空、NULL、\N
    pub null_text: String,
}

/// 预览的一行
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PreviewRow {
    /// 这条记录在文件里从第几行开始（字段里有换行时一条记录占多行）
    pub line: u64,
    /// NULL 是占位，其余是原文
    pub cells: Vec<DisplayCell>,
    /// 列数和第一行对不上
    pub error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CsvPreview {
    /// 有表头时是表头，没有时为空
    pub header: Vec<String>,
    /// 以第一条记录（表头或第一行数据）为准
    pub column_count: u64,
    pub rows: Vec<PreviewRow>,
    /// 预览范围内就读不下去了：引号没闭合、解码失败。rows 是出错前读到的部分
    pub error: Option<String>,
}

/// 目标表的一列。能不能写、要不要必填都在这里判定好，界面只管显示
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TargetColumn {
    pub name: String,
    pub column_type: String,
    pub nullable: bool,
    pub auto_increment: bool,
    /// 按字节处理的列（BLOB、BINARY、BIT、GEOMETRY）。来自结果集的列元数据
    pub is_binary: bool,
    /// 生成列，不能写
    pub generated: bool,
    /// 不映射就插不进去：NOT NULL、没有默认值、不是自增
    pub mandatory: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ImportTarget {
    pub schema: String,
    pub table: String,
    pub columns: Vec<TargetColumn>,
    /// 当前会话默认的 sql_mode
    pub sql_mode: String,
    /// sql_mode 里有 STRICT_TRANS_TABLES 或 STRICT_ALL_TABLES。
    /// 不是的话导入连接会临时加上 STRICT_ALL_TABLES，界面要告诉用户
    pub strict: bool,
}

/// 有错误行时怎么办
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum OnError {
    /// 整个导入一个事务，有任何一行失败就全部回滚。所有行照样试一遍，把错误收集全
    RollbackAll,
    /// 每批一个事务，失败的行跳过，其余照常提交
    SkipRow,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ImportRequest {
    pub path: String,
    pub options: ImportOptions,
    pub schema: String,
    pub table: String,
    /// 下标是 CSV 的列，值是目标表列的下标（ImportTarget.columns），None 表示跳过这一列
    pub mapping: Vec<Option<u32>>,
    /// 每条 INSERT 带几行
    pub batch_rows: u32,
    pub on_error: OnError,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RowError {
    /// 文件里的行号
    pub line: u64,
    pub reason: String,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ImportProgress {
    pub bytes_read: u64,
    pub total_bytes: u64,
    /// 读到的数据行，不含表头
    pub rows_read: u64,
    /// 运行中是已经写进表的行（整体回滚模式下还没提交）；结束后是真正提交了的行
    pub rows_inserted: u64,
    pub rows_failed: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ImportOutcome {
    /// 读完了整个文件并提交。跳过模式下可能有被跳过的行
    Completed,
    /// 整体回滚模式下有失败的行，一行都没写进去
    RolledBack,
    /// 中途停了：文件读不下去、连接断了、用户取消。原因里说清楚已经提交了什么
    Stopped(String),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ImportReport {
    pub progress: ImportProgress,
    pub outcome: ImportOutcome,
    /// 前 MAX_REPORTED_ERRORS 条失败原因。全部失败行在错误行文件里
    pub errors: Vec<RowError>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ImportStatus {
    Running(ImportProgress),
    Finished(ImportReport),
}

/// 报告里最多带几条失败原因
const MAX_REPORTED_ERRORS: usize = 100;

/// 一条语句最多 65535 个占位符
const MAX_PLACEHOLDERS: usize = 65535;

/// 每读这么多行刷新一次进度
const PROGRESS_EVERY: u64 = 1000;

/// 导入连接在非 strict 时执行：在原有 sql_mode 上加 STRICT_ALL_TABLES，其余标志不动
pub const FORCE_STRICT_SQL: &str =
    "SET SESSION sql_mode = CONCAT_WS(',', NULLIF(@@SESSION.sql_mode, ''), 'STRICT_ALL_TABLES')";

/// 一次从文件读多少字节
const CHUNK_BYTES: usize = 64 * 1024;

const UTF8_BOM: [u8; 3] = [0xEF, 0xBB, 0xBF];

// ---------------------------------------------------------------- 解析

#[derive(Debug, Clone, PartialEq)]
struct Field {
    text: String,
    /// 区分 `NULL` 和 `"NULL"`、空字段和 `""`，全靠这一位
    quoted: bool,
}

#[derive(Debug, Clone, PartialEq)]
struct Record {
    line: u64,
    fields: Vec<Field>,
}

/// 字段在哪结束
enum FieldEnd {
    Delimiter,
    Record,
}

/// 流式 RFC 4180 解析器。
///
/// 不用 csv crate：它不告诉调用方字段有没有加引号，而 NULL 和文本 "NULL" 的区分全靠这个。
/// 先解码再按字符切分：GBK 双字节的第二个字节可以落在 0x40–0x7E，按字节切会把 `|` 这类分隔符切错。
struct CsvReader<R: Read> {
    reader: R,
    decoder: Decoder,
    encoding_name: &'static str,
    delimiter: char,
    /// 开头为检查 BOM 多读的字节，第一次解码时用掉
    head: Vec<u8>,
    /// 已解码、还没消费完的文本
    text: String,
    pos: usize,
    /// 解码遇到了非法字节。它前面已经解出来的文本要先消费完，再报错，行号才对
    decode_failed: bool,
    eof: bool,
    /// 当前字符所在的行，从 1 开始
    line: u64,
    bytes_read: u64,
}

impl<R: Read> CsvReader<R> {
    fn open(mut reader: R, options: &ImportOptions) -> std::result::Result<Self, String> {
        let delimiter = parse_delimiter(&options.delimiter)?;

        let mut head = Vec::with_capacity(UTF8_BOM.len());
        let read = (&mut reader)
            .take(UTF8_BOM.len() as u64)
            .read_to_end(&mut head)
            .map_err(|e| format!("读文件失败：{e}"))?;
        let has_bom = head == UTF8_BOM;
        match (options.encoding, has_bom) {
            (ExportEncoding::Utf8Bom, false) => {
                return Err("编码选的是 UTF-8（带 BOM），但文件开头没有 BOM，请改选 UTF-8".to_string())
            }
            (ExportEncoding::Utf8, true) => {
                return Err("文件开头有 UTF-8 的 BOM，编码请选 UTF-8（带 BOM）".to_string())
            }
            (ExportEncoding::Gbk, true) => {
                return Err("文件开头是 UTF-8 的 BOM，编码却选了 GBK".to_string())
            }
            _ => {}
        }
        if has_bom {
            head.clear();
        }

        let (encoding, encoding_name) = match options.encoding {
            ExportEncoding::Utf8 | ExportEncoding::Utf8Bom => (encoding_rs::UTF_8, "UTF-8"),
            ExportEncoding::Gbk => (encoding_rs::GBK, "GBK"),
        };
        Ok(CsvReader {
            reader,
            decoder: encoding.new_decoder_without_bom_handling(),
            encoding_name,
            delimiter,
            head,
            text: String::new(),
            pos: 0,
            decode_failed: false,
            eof: false,
            line: 1,
            bytes_read: read as u64,
        })
    }

    /// 再解一块文本。text 已经消费完时调
    fn fill(&mut self) -> std::result::Result<(), String> {
        self.text.clear();
        self.pos = 0;
        let mut chunk = vec![0u8; CHUNK_BYTES];
        while self.text.is_empty() && !self.eof && !self.decode_failed {
            let read = loop {
                match self.reader.read(&mut chunk) {
                    Ok(n) => break n,
                    Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(e) => return Err(format!("读文件失败：{e}")),
                }
            };
            self.bytes_read += read as u64;
            let last = read == 0;
            let mut src = std::mem::take(&mut self.head);
            src.extend_from_slice(&chunk[..read]);

            let mut offset = 0;
            loop {
                let needed = self
                    .decoder
                    .max_utf8_buffer_length_without_replacement(src.len() - offset)
                    .expect("一块 64KB 算缓冲长度不会溢出");
                self.text.reserve(needed);
                let (result, consumed) =
                    self.decoder.decode_to_string_without_replacement(&src[offset..], &mut self.text, last);
                offset += consumed;
                match result {
                    DecoderResult::InputEmpty => break,
                    DecoderResult::OutputFull => continue,
                    DecoderResult::Malformed(_, _) => {
                        self.decode_failed = true;
                        break;
                    }
                }
            }
            if last {
                self.eof = true;
            }
        }
        Ok(())
    }

    fn next_char(&mut self) -> std::result::Result<Option<char>, String> {
        if self.pos >= self.text.len() {
            self.fill()?;
            if self.text.is_empty() {
                if self.decode_failed {
                    return Err(format!(
                        "第 {} 行有 {} 解不了的字节，文件可能不是这个编码",
                        self.line, self.encoding_name
                    ));
                }
                return Ok(None);
            }
        }
        let ch = self.text[self.pos..].chars().next().expect("pos 在字符边界上");
        self.pos += ch.len_utf8();
        if ch == '\n' {
            self.line += 1;
        }
        Ok(Some(ch))
    }

    /// 读下一条记录。文件读完返回 None；引号、换行、编码的问题直接报错，后面的内容没法可靠地读下去
    fn next_record(&mut self) -> std::result::Result<Option<Record>, String> {
        let line = self.line;
        let Some(mut ch) = self.next_char()? else {
            return Ok(None);
        };
        let mut fields = Vec::new();
        loop {
            let (field, end) = if ch == '"' { self.quoted_field()? } else { self.unquoted_field(ch)? };
            fields.push(field);
            if let FieldEnd::Record = end {
                return Ok(Some(Record { line, fields }));
            }
            match self.next_char()? {
                Some(next) => ch = next,
                // `a,b,` 结尾：最后还有一个空字段
                None => {
                    fields.push(Field { text: String::new(), quoted: false });
                    return Ok(Some(Record { line, fields }));
                }
            }
        }
    }

    fn unquoted_field(&mut self, first: char) -> std::result::Result<(Field, FieldEnd), String> {
        let mut text = String::new();
        let mut current = Some(first);
        loop {
            let end = match current {
                None | Some('\n') => Some(FieldEnd::Record),
                Some('\r') => {
                    self.expect_line_feed()?;
                    Some(FieldEnd::Record)
                }
                Some(ch) if ch == self.delimiter => Some(FieldEnd::Delimiter),
                Some('"') => {
                    return Err(format!(
                        "第 {} 行：没加引号的字段里出现了双引号。含双引号的字段要整个用双引号包起来，里面的双引号写两遍",
                        self.line
                    ))
                }
                Some(ch) => {
                    text.push(ch);
                    None
                }
            };
            if let Some(end) = end {
                return Ok((Field { text, quoted: false }, end));
            }
            current = self.next_char()?;
        }
    }

    /// 开头的引号已经读掉了
    fn quoted_field(&mut self) -> std::result::Result<(Field, FieldEnd), String> {
        let start_line = self.line;
        let mut text = String::new();
        loop {
            match self.next_char()? {
                None => return Err(format!("第 {start_line} 行开始的引号到文件末尾都没有闭合")),
                Some('"') => {
                    let end = match self.next_char()? {
                        Some('"') => {
                            text.push('"');
                            continue;
                        }
                        None | Some('\n') => FieldEnd::Record,
                        Some('\r') => {
                            self.expect_line_feed()?;
                            FieldEnd::Record
                        }
                        Some(ch) if ch == self.delimiter => FieldEnd::Delimiter,
                        Some(ch) => {
                            return Err(format!(
                                "第 {} 行：引号闭合后紧跟着 {ch:?}，应该是分隔符或换行",
                                self.line
                            ))
                        }
                    };
                    return Ok((Field { text, quoted: true }, end));
                }
                Some(ch) => text.push(ch),
            }
        }
    }

    fn expect_line_feed(&mut self) -> std::result::Result<(), String> {
        match self.next_char()? {
            Some('\n') => Ok(()),
            _ => Err(format!("第 {} 行：\\r 后面没有 \\n，只认 \\n 和 \\r\\n 两种换行", self.line)),
        }
    }
}

fn parse_delimiter(delimiter: &str) -> std::result::Result<char, String> {
    let mut chars = delimiter.chars();
    match (chars.next(), chars.next()) {
        (Some('"' | '\r' | '\n'), None) => Err(format!("分隔符不能是 {delimiter:?}")),
        (Some(ch), None) => Ok(ch),
        _ => Err(format!("分隔符必须是单个字符，现在是 {delimiter:?}")),
    }
}

fn open_file(path: &str, options: &ImportOptions) -> std::result::Result<(CsvReader<File>, u64), String> {
    let file = File::open(path).map_err(|e| format!("打不开文件：{e}"))?;
    let total = file.metadata().map_err(|e| format!("读文件信息失败：{e}"))?.len();
    Ok((CsvReader::open(file, options)?, total))
}

/// 读前 limit 行给界面预览。有表头时表头不算在 limit 里
pub fn preview(path: &str, options: &ImportOptions, limit: usize) -> std::result::Result<CsvPreview, String> {
    let (reader, _) = open_file(path, options)?;
    preview_from(reader, options, limit)
}

fn preview_from<R: Read>(
    mut reader: CsvReader<R>,
    options: &ImportOptions,
    limit: usize,
) -> std::result::Result<CsvPreview, String> {
    let mut preview = CsvPreview { header: Vec::new(), column_count: 0, rows: Vec::new(), error: None };
    if options.header {
        match reader.next_record() {
            Ok(Some(record)) => {
                preview.column_count = record.fields.len() as u64;
                for field in record.fields {
                    preview.header.push(field.text);
                }
            }
            Ok(None) => return Ok(preview),
            Err(message) => {
                preview.error = Some(message);
                return Ok(preview);
            }
        }
    }

    while preview.rows.len() < limit {
        let record = match reader.next_record() {
            Ok(Some(record)) => record,
            Ok(None) => break,
            Err(message) => {
                preview.error = Some(message);
                break;
            }
        };
        if preview.column_count == 0 {
            preview.column_count = record.fields.len() as u64;
        }
        let error = column_count_error(&record, preview.column_count as usize);
        let mut cells = Vec::with_capacity(record.fields.len());
        for field in &record.fields {
            if is_null(field, &options.null_text) {
                cells.push(DisplayCell { text: "NULL".to_string(), placeholder: true });
            } else {
                cells.push(DisplayCell { text: field.text.clone(), placeholder: false });
            }
        }
        preview.rows.push(PreviewRow { line: record.line, cells, error });
    }
    Ok(preview)
}

fn is_null(field: &Field, null_text: &str) -> bool {
    !field.quoted && field.text == null_text
}

fn column_count_error(record: &Record, expected: usize) -> Option<String> {
    if record.fields.len() == expected {
        return None;
    }
    Some(format!("有 {} 列，应该是 {expected} 列", record.fields.len()))
}

// ---------------------------------------------------------------- 值与映射

/// 一个字段按目标列解释成单元格值。和 export.rs 的写法一一对应
fn field_value(field: &Field, is_binary: bool, null_text: &str) -> std::result::Result<CellValue, String> {
    if is_null(field, null_text) {
        return Ok(CellValue::Null);
    }
    if !is_binary {
        return Ok(CellValue::Text(field.text.clone()));
    }
    // 导出把二进制写成不加引号的 0x 十六进制；加了引号的是文本，不能当字节塞进二进制列
    if !field.quoted {
        if let Some(bytes) = parse_hex(&field.text) {
            return Ok(CellValue::Bytes(bytes));
        }
    }
    Err("是二进制列，值要写成不加引号的 0x 开头十六进制（和导出一致）".to_string())
}

fn parse_hex(text: &str) -> Option<Vec<u8>> {
    let digits = text.strip_prefix("0x")?;
    if digits.len() % 2 != 0 || !digits.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let mut bytes = Vec::with_capacity(digits.len() / 2);
    for pair in digits.as_bytes().chunks(2) {
        let pair = std::str::from_utf8(pair).ok()?;
        bytes.push(u8::from_str_radix(pair, 16).ok()?);
    }
    Some(bytes)
}

/// 按表头给一个默认映射：名字相同（不分大小写，和 MySQL 列名规则一致）的就对上，生成列不参与。
/// 只是建议，界面必须让用户能改
pub fn suggest_mapping(header: &[String], columns: &[TargetColumn]) -> Vec<Option<u32>> {
    let mut taken = vec![false; columns.len()];
    let mut mapping = Vec::with_capacity(header.len());
    for name in header {
        let wanted = name.to_lowercase();
        let mut found = None;
        for (index, column) in columns.iter().enumerate() {
            if !taken[index] && !column.generated && column.name.to_lowercase() == wanted {
                taken[index] = true;
                found = Some(index as u32);
                break;
            }
        }
        mapping.push(found);
    }
    mapping
}

/// 检查映射，返回 (CSV 列下标, 目标列下标)。说不通的一律拒绝，不在写库时才发现
pub fn validate_mapping(
    columns: &[TargetColumn],
    mapping: &[Option<u32>],
) -> std::result::Result<Vec<(usize, usize)>, String> {
    let mut pairs = Vec::new();
    let mut mapped = vec![false; columns.len()];
    for (csv_index, target) in mapping.iter().enumerate() {
        let Some(target) = target else { continue };
        let target = *target as usize;
        let column = columns
            .get(target)
            .ok_or_else(|| format!("第 {} 列映射到的表列下标 {target} 越界", csv_index + 1))?;
        if column.generated {
            return Err(format!("{} 是生成列，不能写入", column.name));
        }
        if mapped[target] {
            return Err(format!("表列 {} 被映射了不止一次", column.name));
        }
        mapped[target] = true;
        pairs.push((csv_index, target));
    }
    if pairs.is_empty() {
        return Err("没有映射任何列".to_string());
    }

    let mut missing = Vec::new();
    for (index, column) in columns.iter().enumerate() {
        if column.mandatory && !mapped[index] {
            missing.push(column.name.as_str());
        }
    }
    if !missing.is_empty() {
        return Err(format!(
            "{} 不允许 NULL 也没有默认值，必须映射一列 CSV",
            missing.join("、")
        ));
    }
    Ok(pairs)
}

/// 一行 CSV 变成 INSERT 的参数。能在写库前看出来的问题在这里报
fn row_params(
    record: &Record,
    pairs: &[(usize, usize)],
    columns: &[TargetColumn],
    null_text: &str,
) -> std::result::Result<Vec<Value>, String> {
    let mut params = Vec::with_capacity(pairs.len());
    for &(csv_index, target) in pairs {
        let column = &columns[target];
        let value = field_value(&record.fields[csv_index], column.is_binary, null_text)
            .map_err(|reason| format!("列 {} {reason}", column.name))?;
        // 自增列写 NULL 是让 MySQL 生成下一个值，合法
        if value == CellValue::Null && !column.nullable && !column.auto_increment {
            return Err(format!("列 {} 不允许 NULL", column.name));
        }
        params.push(value_to_mysql(&value));
    }
    Ok(params)
}

fn insert_sql(schema: &str, table: &str, names: &[&str], rows: usize) -> String {
    let mut quoted = Vec::with_capacity(names.len());
    for name in names {
        quoted.push(quote_ident(name));
    }
    let one_row = format!("({})", vec!["?"; names.len()].join(", "));
    format!(
        "INSERT INTO {}.{} ({}) VALUES {}",
        quote_ident(schema),
        quote_ident(table),
        quoted.join(", "),
        vec![one_row.as_str(); rows].join(", ")
    )
}

// ---------------------------------------------------------------- 目标表

/// 读目标表的列和当前 sql_mode。只接受支持事务的实体表：
/// 不支持事务的引擎回滚不了，出错时也没法用 SAVEPOINT 逐行找出是哪一行
pub async fn prepare(pool: &DbPool, schema: &str, table: &str) -> Result<ImportTarget> {
    let mut conn = pool.get_conn().await?;
    let info: Option<(String, Option<String>, Option<String>)> = conn
        .exec_first(
            "SELECT t.TABLE_TYPE, t.ENGINE, e.TRANSACTIONS FROM information_schema.TABLES t \
             LEFT JOIN information_schema.ENGINES e ON e.ENGINE = t.ENGINE \
             WHERE t.TABLE_SCHEMA = ? AND t.TABLE_NAME = ?",
            (schema, table),
        )
        .await?;
    let sql_mode: String = conn
        .query_first("SELECT @@SESSION.sql_mode")
        .await?
        .ok_or_else(|| Error::Mysql("读不到 sql_mode".to_string()))?;
    drop(conn);

    let Some((table_type, engine, transactions)) = info else {
        return Err(Error::BadInput(format!("表 {schema}.{table} 不存在")));
    };
    if table_type != "BASE TABLE" {
        return Err(Error::BadInput(format!("{table} 不是表（{table_type}），只能导入到表")));
    }
    if transactions.as_deref() != Some("YES") {
        return Err(Error::BadInput(format!(
            "表 {table} 的引擎（{}）不支持事务：出错时回滚不了，也没法逐行找出错误行，暂不支持导入",
            engine.as_deref().unwrap_or("未知")
        )));
    }

    let defs = table_columns(pool, schema, table).await?;
    // 二进制与否只由列元数据决定（db.rs 的 is_binary_column），这里查一个空结果集拿元数据。
    // 显式列出列名：SELECT * 不包含 INVISIBLE 列
    let mut names = Vec::with_capacity(defs.len());
    for def in &defs {
        names.push(quote_ident(&def.name));
    }
    let probe = format!(
        "SELECT {} FROM {}.{} LIMIT 0",
        names.join(", "),
        quote_ident(schema),
        quote_ident(table)
    );
    let metas = run_query(pool, &probe, 0).await?.columns;
    if metas.len() != defs.len() {
        return Err(Error::Mysql(format!(
            "表 {table} 的列定义有 {} 列，结果集元数据有 {} 列，对不上",
            defs.len(),
            metas.len()
        )));
    }

    let mut columns = Vec::with_capacity(defs.len());
    for (def, meta) in defs.into_iter().zip(metas) {
        let auto_increment = def.extra.contains("auto_increment");
        // EXTRA 里 DEFAULT_GENERATED 是表达式默认值，VIRTUAL / STORED GENERATED 才是生成列
        let generated = def.extra.contains("VIRTUAL GENERATED") || def.extra.contains("STORED GENERATED");
        let mandatory = !def.nullable && def.default == DefaultValue::NoDefault && !auto_increment && !generated;
        columns.push(TargetColumn {
            name: def.name,
            column_type: def.column_type,
            nullable: def.nullable,
            auto_increment,
            is_binary: meta.is_binary,
            generated,
            mandatory,
        });
    }

    let strict = sql_mode.contains("STRICT_TRANS_TABLES") || sql_mode.contains("STRICT_ALL_TABLES");
    Ok(ImportTarget { schema: schema.to_string(), table: table.to_string(), columns, sql_mode, strict })
}

// ---------------------------------------------------------------- 任务

struct ImportJob {
    status: Mutex<ImportStatus>,
    cancel: AtomicBool,
    /// 失败行写在这里。任务从表里移走、执行也结束之后随 Drop 删掉
    error_path: PathBuf,
}

impl Drop for ImportJob {
    fn drop(&mut self) {
        // 没有失败行时文件从没建过，删不掉是正常的
        let _ = fs::remove_file(&self.error_path);
    }
}

fn jobs() -> &'static Mutex<HashMap<u64, Arc<ImportJob>>> {
    static JOBS: OnceLock<Mutex<HashMap<u64, Arc<ImportJob>>>> = OnceLock::new();
    JOBS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn job(job_id: u64) -> Result<Arc<ImportJob>> {
    let guard = jobs().lock().unwrap();
    guard
        .get(&job_id)
        .cloned()
        .ok_or_else(|| Error::BadInput(format!("导入任务 {job_id} 不存在")))
}

/// 检查请求、打开文件，然后在后台开始导入，返回任务 id。
/// 映射不对、文件打不开、表头列数对不上在这里就报错，不会开始写库。
/// 必须在 tokio runtime 里调用
pub async fn start(pool: DbPool, request: ImportRequest) -> Result<u64> {
    let target = prepare(&pool, &request.schema, &request.table).await?;
    let pairs = validate_mapping(&target.columns, &request.mapping).map_err(Error::BadInput)?;
    if request.batch_rows == 0 {
        return Err(Error::BadInput("每批行数至少是 1".to_string()));
    }
    let (mut reader, total_bytes) = open_file(&request.path, &request.options).map_err(Error::BadInput)?;

    let mut header = None;
    if request.options.header {
        let record = reader.next_record().map_err(Error::BadInput)?;
        let Some(record) = record else {
            return Err(Error::BadInput("文件是空的".to_string()));
        };
        if record.fields.len() != request.mapping.len() {
            return Err(Error::BadInput(format!(
                "表头有 {} 列，映射给的是 {} 列。文件可能在预览之后改过，请重新预览",
                record.fields.len(),
                request.mapping.len()
            )));
        }
        header = Some(record.fields);
    }

    static NEXT_JOB: AtomicU64 = AtomicU64::new(1);
    let job_id = NEXT_JOB.fetch_add(1, Ordering::Relaxed);
    let job = Arc::new(ImportJob {
        status: Mutex::new(ImportStatus::Running(ImportProgress { total_bytes, ..Default::default() })),
        cancel: AtomicBool::new(false),
        error_path: std::env::temp_dir().join(format!("cdata-import-errors-{}-{job_id}.csv", std::process::id())),
    });
    jobs().lock().unwrap().insert(job_id, job.clone());

    let errors = ErrorFile {
        path: job.error_path.clone(),
        out: None,
        header,
        options: request.options.clone(),
        written: 0,
    };
    let mut run = Run {
        job,
        target,
        pairs,
        request,
        progress: ImportProgress { total_bytes, ..Default::default() },
        pending: 0,
        errors: Vec::new(),
        error_file: errors,
    };
    // ponytail: 读文件是阻塞 IO，直接放在 tokio 任务里（一次 64KB，本地盘够快）；慢的网络盘再改 spawn_blocking
    tokio::spawn(async move {
        let outcome = run.execute(&pool, reader).await;
        run.finish(outcome);
    });
    Ok(job_id)
}

/// 任务的当前进度，结束后是最终报告
pub fn status(job_id: u64) -> Result<ImportStatus> {
    Ok(job(job_id)?.status.lock().unwrap().clone())
}

/// 请求取消。处理完当前这一批就停；整体回滚模式下全部回滚，跳过模式下已提交的批次保留
pub fn cancel(job_id: u64) -> Result<()> {
    job(job_id)?.cancel.store(true, Ordering::Relaxed);
    Ok(())
}

/// 把失败行另存成 CSV：原始字段原样保留，末尾加一列错误原因。返回写了几行
pub fn save_errors(job_id: u64, path: &str) -> Result<u64> {
    let job = job(job_id)?;
    let failed = match &*job.status.lock().unwrap() {
        ImportStatus::Running(_) => return Err(Error::BadInput("导入还没结束".to_string())),
        ImportStatus::Finished(report) => report.progress.rows_failed,
    };
    if failed == 0 {
        return Err(Error::BadInput("没有失败的行".to_string()));
    }
    let path = Path::new(path);
    let temp = temp_path(path);
    let copied = fs::copy(&job.error_path, &temp).and_then(|_| fs::rename(&temp, path));
    if let Err(err) = copied {
        let _ = fs::remove_file(&temp);
        return Err(Error::BadInput(format!("保存错误行失败：{err}")));
    }
    Ok(failed)
}

/// 关掉任务。还在跑的会先取消；错误行临时文件等执行真正停下后删除
pub fn close(job_id: u64) -> Result<()> {
    let job = jobs()
        .lock()
        .unwrap()
        .remove(&job_id)
        .ok_or_else(|| Error::BadInput(format!("导入任务 {job_id} 不存在")))?;
    job.cancel.store(true, Ordering::Relaxed);
    Ok(())
}

/// 导入为什么停下
enum Stop {
    Cancelled,
    /// 读文件、写错误行文件出错
    File(String),
    /// 连接断了、SAVEPOINT 没了（死锁等让 MySQL 回滚了整个事务）、影响行数不对
    Database(Error),
    /// COMMIT 本身出错：这一批到底提交没有，从客户端分辨不出来
    Commit(Error, u64),
}

impl From<mysql_async::Error> for Stop {
    fn from(err: mysql_async::Error) -> Self {
        Stop::Database(err.into())
    }
}

/// 一次导入的执行状态
struct Run {
    job: Arc<ImportJob>,
    target: ImportTarget,
    pairs: Vec<(usize, usize)>,
    request: ImportRequest,
    progress: ImportProgress,
    /// 写进了当前事务、还没提交的行
    pending: u64,
    errors: Vec<RowError>,
    error_file: ErrorFile,
}

impl Run {
    async fn execute<R: Read>(&mut self, pool: &DbPool, reader: CsvReader<R>) -> std::result::Result<(), Stop> {
        // 导入独占一条连接，结束后断开而不是还回池里：
        // 临时改的 sql_mode 和没收尾的事务都不会漏到用户后面的查询里
        let mut conn = pool.get_conn().await?;
        let result = self.execute_on(&mut conn, reader).await;
        if result.is_err() {
            // 断开时服务器也会回滚没提交的事务，这里显式回滚只是不等超时
            let _ = conn.query_drop("ROLLBACK").await;
        }
        let _ = conn.disconnect().await;
        result
    }

    async fn execute_on<R: Read>(
        &mut self,
        conn: &mut Conn,
        mut reader: CsvReader<R>,
    ) -> std::result::Result<(), Stop> {
        // 非 strict 模式下 MySQL 会把放不下的值静默截断或转换成 0，导入完根本发现不了。
        // 只在这条连接上加，用户自己的查询会话不受影响
        if !self.target.strict {
            conn.query_drop(FORCE_STRICT_SQL).await?;
        }

        let column_count = self.request.mapping.len();
        // 一条语句的占位符有上限，列多的表每批少放几行
        let batch_rows = (self.request.batch_rows as usize).min(MAX_PLACEHOLDERS / self.pairs.len()).max(1);
        let mut batch: Vec<(Record, Vec<Value>)> = Vec::with_capacity(batch_rows);

        conn.query_drop("START TRANSACTION").await?;
        loop {
            if self.job.cancel.load(Ordering::Relaxed) {
                return Err(Stop::Cancelled);
            }
            let record = reader.next_record().map_err(Stop::File)?;
            self.progress.bytes_read = reader.bytes_read;
            let Some(record) = record else { break };
            self.progress.rows_read += 1;

            let checked = match column_count_error(&record, column_count) {
                Some(reason) => Err(reason),
                None => row_params(&record, &self.pairs, &self.target.columns, &self.request.options.null_text),
            };
            match checked {
                Ok(params) => batch.push((record, params)),
                Err(reason) => self.fail_row(&record, reason)?,
            }

            if batch.len() >= batch_rows {
                self.flush(conn, &mut batch).await?;
                if self.request.on_error == OnError::SkipRow {
                    self.commit(conn).await?;
                    conn.query_drop("START TRANSACTION").await?;
                }
                self.publish();
            } else if self.progress.rows_read % PROGRESS_EVERY == 0 {
                self.publish();
            }
        }
        self.flush(conn, &mut batch).await?;

        if self.request.on_error == OnError::RollbackAll && self.progress.rows_failed > 0 {
            conn.query_drop("ROLLBACK").await?;
            self.pending = 0;
            return Ok(());
        }
        self.commit(conn).await
    }

    async fn commit(&mut self, conn: &mut Conn) -> std::result::Result<(), Stop> {
        if let Err(err) = conn.query_drop("COMMIT").await {
            return Err(Stop::Commit(err.into(), self.pending));
        }
        self.progress.rows_inserted += self.pending;
        self.pending = 0;
        self.publish();
        Ok(())
    }

    /// 整批一条 INSERT。失败就退回批前的 SAVEPOINT，逐行重试，找出到底是哪几行
    async fn flush(&mut self, conn: &mut Conn, batch: &mut Vec<(Record, Vec<Value>)>) -> std::result::Result<(), Stop> {
        if batch.is_empty() {
            return Ok(());
        }
        let mut names = Vec::with_capacity(self.pairs.len());
        for &(_, target) in &self.pairs {
            names.push(self.target.columns[target].name.as_str());
        }
        let schema = &self.request.schema;
        let table = &self.request.table;

        let mut params = Vec::with_capacity(batch.len() * self.pairs.len());
        for (_, row) in batch.iter() {
            params.extend(row.iter().cloned());
        }
        conn.query_drop("SAVEPOINT cdata_batch").await?;
        match conn.exec_drop(insert_sql(schema, table, &names, batch.len()), params).await {
            Ok(()) => {
                expect_affected(conn, batch.len())?;
                self.pending += batch.len() as u64;
                batch.clear();
                return Ok(());
            }
            Err(err) if is_row_error(&err) => {}
            Err(err) => return Err(err.into()),
        }

        // SAVEPOINT 不在了（死锁、锁超时回滚了整个事务）这里会报错，走 Stop::Database，
        // 不会在事务外继续自动提交
        conn.query_drop("ROLLBACK TO SAVEPOINT cdata_batch").await?;
        let single = insert_sql(schema, table, &names, 1);
        for (record, row) in batch.drain(..) {
            conn.query_drop("SAVEPOINT cdata_row").await?;
            match conn.exec_drop(&single, row).await {
                Ok(()) => {
                    expect_affected(conn, 1)?;
                    self.pending += 1;
                }
                Err(mysql_async::Error::Server(err)) if !is_gone(err.code) => {
                    conn.query_drop("ROLLBACK TO SAVEPOINT cdata_row").await?;
                    self.fail_row(&record, format!("MySQL 错误 {}：{}", err.code, err.message))?;
                }
                Err(err) => return Err(err.into()),
            }
        }
        Ok(())
    }

    fn fail_row(&mut self, record: &Record, reason: String) -> std::result::Result<(), Stop> {
        self.progress.rows_failed += 1;
        self.error_file.write(record, &reason).map_err(Stop::File)?;
        if self.errors.len() < MAX_REPORTED_ERRORS {
            self.errors.push(RowError { line: record.line, reason });
        }
        Ok(())
    }

    fn publish(&self) {
        let mut progress = self.progress.clone();
        progress.rows_inserted += self.pending;
        *self.job.status.lock().unwrap() = ImportStatus::Running(progress);
    }

    fn finish(mut self, result: std::result::Result<(), Stop>) {
        let flushed = self.error_file.finish();
        let committed = self.progress.rows_inserted;
        let outcome = match (result, flushed) {
            (Ok(()), Err(message)) | (Err(Stop::File(message)), _) => ImportOutcome::Stopped(stopped_message(&message, committed)),
            (Err(Stop::Database(err)), _) => ImportOutcome::Stopped(stopped_message(&err.to_string(), committed)),
            (Err(Stop::Cancelled), _) => ImportOutcome::Stopped(stopped_message("已取消", committed)),
            (Err(Stop::Commit(err, rows)), _) => ImportOutcome::Stopped(stopped_message(
                &format!("{err}。提交最后 {rows} 行时出错，这 {rows} 行有没有写进去不确定，请查询确认"),
                committed,
            )),
            (Ok(()), Ok(())) if self.request.on_error == OnError::RollbackAll && self.progress.rows_failed > 0 => {
                ImportOutcome::RolledBack
            }
            (Ok(()), Ok(())) => ImportOutcome::Completed,
        };
        let report = ImportReport { progress: self.progress.clone(), outcome, errors: std::mem::take(&mut self.errors) };
        *self.job.status.lock().unwrap() = ImportStatus::Finished(report);
    }
}

fn stopped_message(reason: &str, committed: u64) -> String {
    if committed == 0 {
        format!("{reason}。没有提交任何行")
    } else {
        format!("{reason}。之前已提交的 {committed} 行留在表里")
    }
}

fn expect_affected(conn: &Conn, rows: usize) -> std::result::Result<(), Stop> {
    let affected = conn.affected_rows();
    if affected != rows as u64 {
        return Err(Stop::Database(Error::EditFailed(format!("预期插入 {rows} 行，实际 {affected} 行"))));
    }
    Ok(())
}

fn is_gone(code: u16) -> bool {
    crate::session::CONNECTION_GONE_CODES.contains(&code)
}

/// 这一批里某些行的数据有问题（类型、长度、唯一键……），值得逐行重试。连接层面的问题不算
fn is_row_error(err: &mysql_async::Error) -> bool {
    matches!(err, mysql_async::Error::Server(server) if !is_gone(server.code))
}

/// 失败行写成 CSV，编码、分隔符、NULL 写法和原文件一样，改好了可以原样再导一次
struct ErrorFile {
    path: PathBuf,
    out: Option<Encoder>,
    header: Option<Vec<Field>>,
    options: ImportOptions,
    written: u64,
}

impl ErrorFile {
    fn write(&mut self, record: &Record, reason: &str) -> std::result::Result<(), String> {
        let delimiter = parse_delimiter(&self.options.delimiter)?;
        if self.out.is_none() {
            let file = File::create(&self.path).map_err(|e| format!("创建错误行文件失败：{e}"))?;
            let mut out = Encoder { writer: BufWriter::new(file), encoding: self.options.encoding };
            if self.options.encoding == ExportEncoding::Utf8Bom {
                out.raw(&UTF8_BOM)?;
            }
            if let Some(header) = &self.header {
                let line = error_line(header, "错误原因", delimiter, &self.options.null_text);
                out.text(&line, "错误行文件的表头")?;
            }
            self.out = Some(out);
        }
        let out = self.out.as_mut().expect("上面刚建好");
        self.written += 1;
        let reason = format!("第 {} 行：{reason}", record.line);
        let line = error_line(&record.fields, &reason, delimiter, &self.options.null_text);
        out.text(&line, &format!("错误行文件第 {} 行", self.written))
    }

    fn finish(&mut self) -> std::result::Result<(), String> {
        match self.out.as_mut() {
            Some(out) => std::io::Write::flush(&mut out.writer).map_err(|e| format!("写错误行文件失败：{e}")),
            None => Ok(()),
        }
    }
}

/// 原始字段原样写回：加过引号的照样加（NULL 和 "NULL" 才不会混），没加的原文照写
fn error_line(fields: &[Field], reason: &str, delimiter: char, null_text: &str) -> String {
    let mut parts = Vec::with_capacity(fields.len() + 1);
    for field in fields {
        if field.quoted {
            parts.push(format!("\"{}\"", field.text.replace('"', "\"\"")));
        } else {
            parts.push(field.text.clone());
        }
    }
    parts.push(csv_quote(reason, delimiter, null_text));
    let mut line = parts.join(&delimiter.to_string());
    line.push_str("\r\n");
    line
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::{ColumnKind, ColumnMeta};
    use crate::export::{write_file, ExportFormat, ExportOptions};

    fn options(null_text: &str) -> ImportOptions {
        ImportOptions {
            encoding: ExportEncoding::Utf8,
            delimiter: ",".to_string(),
            header: false,
            null_text: null_text.to_string(),
        }
    }

    fn records_from(bytes: &[u8], options: &ImportOptions) -> std::result::Result<Vec<Record>, String> {
        let mut reader = CsvReader::open(bytes, options)?;
        let mut records = Vec::new();
        while let Some(record) = reader.next_record()? {
            records.push(record);
        }
        Ok(records)
    }

    fn texts(record: &Record) -> Vec<(&str, bool)> {
        let mut out = Vec::new();
        for field in &record.fields {
            out.push((field.text.as_str(), field.quoted));
        }
        out
    }

    /// 每次只给一个字节的读取器，测跨块边界：多字节字符、"" 转义、\r\n 被切开
    struct OneByte<'a>(&'a [u8]);

    impl Read for OneByte<'_> {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            if self.0.is_empty() || buf.is_empty() {
                return Ok(0);
            }
            buf[0] = self.0[0];
            self.0 = &self.0[1..];
            Ok(1)
        }
    }

    #[test]
    fn parses_rfc4180_quotes_newlines_and_empty_fields() {
        let input = "a,\"b,1\",\"say \"\"hi\"\"\"\r\n\"多\r\n行\",,\"\"\r\nx,y,\n";
        let records = records_from(input.as_bytes(), &options("NULL")).unwrap();
        assert_eq!(records.len(), 3);
        assert_eq!(texts(&records[0]), [("a", false), ("b,1", true), ("say \"hi\"", true)]);
        assert_eq!(texts(&records[1]), [("多\r\n行", true), ("", false), ("", true)]);
        // 字段里的换行不算新记录，但行号要按文件里的物理行算
        assert_eq!((records[0].line, records[1].line, records[2].line), (1, 2, 4));
        assert_eq!(texts(&records[2]), [("x", false), ("y", false), ("", false)]);
    }

    #[test]
    fn last_record_without_newline_and_trailing_delimiter() {
        let records = records_from(b"a,b\nc,", &options("")).unwrap();
        assert_eq!(texts(&records[1]), [("c", false), ("", false)]);
    }

    #[test]
    fn empty_line_is_a_record_with_one_empty_field() {
        // 单列导出时 NULL（null_text 为空）就是一个空行，不能被吞掉
        let records = records_from(b"a\r\n\r\nb\r\n", &options("")).unwrap();
        assert_eq!(records.len(), 3);
        assert_eq!(texts(&records[1]), [("", false)]);
    }

    #[test]
    fn chunk_boundaries_do_not_change_the_result() {
        let input = "中文,\"引\"\"号\"\r\n\"跨\r\n行\",😀\r\n";
        let whole = records_from(input.as_bytes(), &options("")).unwrap();
        let mut reader = CsvReader::open(OneByte(input.as_bytes()), &options("")).unwrap();
        let mut split = Vec::new();
        while let Some(record) = reader.next_record().unwrap() {
            split.push(record);
        }
        assert_eq!(split, whole);
        assert_eq!(texts(&whole[0]), [("中文", false), ("引\"号", true)]);
    }

    #[test]
    fn null_and_empty_string_are_told_apart() {
        let records = records_from(b"NULL,\"NULL\",,\"\"\r\n", &options("NULL")).unwrap();
        let mut values = Vec::new();
        for field in &records[0].fields {
            values.push(field_value(field, false, "NULL").unwrap());
        }
        assert_eq!(
            values,
            [
                CellValue::Null,
                CellValue::Text("NULL".into()),
                CellValue::Text(String::new()),
                CellValue::Text(String::new()),
            ]
        );

        // null_text 为空时：空字段是 NULL，"" 是空串
        let records = records_from(b",\"\"\r\n", &options("")).unwrap();
        assert_eq!(field_value(&records[0].fields[0], false, "").unwrap(), CellValue::Null);
        assert_eq!(field_value(&records[0].fields[1], false, "").unwrap(), CellValue::Text(String::new()));

        // \N 也一样，加了引号的 "\N" 是文本
        let records = records_from(b"\\N,\"\\N\"\r\n", &options("\\N")).unwrap();
        assert_eq!(field_value(&records[0].fields[0], false, "\\N").unwrap(), CellValue::Null);
        assert_eq!(field_value(&records[0].fields[1], false, "\\N").unwrap(), CellValue::Text("\\N".into()));
    }

    #[test]
    fn binary_columns_take_unquoted_hex_only() {
        let field = |text: &str, quoted| Field { text: text.to_string(), quoted };
        assert_eq!(field_value(&field("0x00FF", false), true, "NULL").unwrap(), CellValue::Bytes(vec![0, 255]));
        assert_eq!(field_value(&field("0x", false), true, "NULL").unwrap(), CellValue::Bytes(vec![]));
        assert_eq!(field_value(&field("NULL", false), true, "NULL").unwrap(), CellValue::Null);
        for bad in [field("0x00FF", true), field("abc", false), field("0x0", false), field("0x+1", false)] {
            assert!(field_value(&bad, true, "NULL").unwrap_err().contains("十六进制"), "{bad:?}");
        }
        // 文本列里的 0x 就是文本
        assert_eq!(field_value(&field("0x00FF", false), false, "NULL").unwrap(), CellValue::Text("0x00FF".into()));
    }

    #[test]
    fn quote_errors_are_reported_with_line_numbers() {
        let err = records_from(b"a,b\nc,\"open\nd\n", &options("")).unwrap_err();
        assert!(err.contains("第 2 行开始的引号"), "{err}");

        let err = records_from(b"a,b\nc,d\"e\n", &options("")).unwrap_err();
        assert!(err.contains("第 2 行") && err.contains("双引号"), "{err}");

        let err = records_from(b"a\n\"x\"y\n", &options("")).unwrap_err();
        assert!(err.contains("第 2 行") && err.contains("引号闭合后"), "{err}");

        let err = records_from(b"a\rb\n", &options("")).unwrap_err();
        assert!(err.contains("第 1 行") && err.contains("\\r"), "{err}");
    }

    #[test]
    fn decode_errors_name_the_line_instead_of_replacing() {
        // 第 3 行有一个 latin1 的 é，不是合法 UTF-8
        let err = records_from(b"a\nb\nc\xE9\n", &options("")).unwrap_err();
        assert!(err.contains("第 3 行") && err.contains("UTF-8"), "{err}");
        assert!(!err.contains('\u{FFFD}'));

        // 分块读取时同样报对行号
        let mut reader = CsvReader::open(OneByte(b"a\nb\nc\xE9\n"), &options("")).unwrap();
        let mut result = Ok(None);
        for _ in 0..4 {
            result = reader.next_record();
            if result.is_err() {
                break;
            }
        }
        assert!(result.unwrap_err().contains("第 3 行"));

        // UTF-8 的中文按 GBK 读：E4 B8 AD 里的 AD 后面跟 \n，不是合法的 GBK 双字节
        let mut gbk = options("");
        gbk.encoding = ExportEncoding::Gbk;
        let err = records_from("x\n中\n".as_bytes(), &gbk).unwrap_err();
        assert!(err.contains("第 2 行") && err.contains("GBK"), "{err}");
    }

    #[test]
    fn gbk_is_decoded_even_with_ascii_looking_trail_bytes() {
        // 「亅」的 GBK 是 81 7C，第二个字节正好是 |。按字节切分会把它当成分隔符
        let mut gbk = options("");
        gbk.encoding = ExportEncoding::Gbk;
        gbk.delimiter = "|".to_string();
        let (bytes, _, _) = encoding_rs::GBK.encode("亅|中文\r\n");
        assert_eq!(&bytes[..2], [0x81, 0x7C]);
        let records = records_from(&bytes, &gbk).unwrap();
        assert_eq!(texts(&records[0]), [("亅", false), ("中文", false)]);
    }

    #[test]
    fn bom_must_match_the_chosen_encoding() {
        let mut with_bom = UTF8_BOM.to_vec();
        with_bom.extend_from_slice(b"id\r\n1\r\n");

        let err = records_from(&with_bom, &options("")).unwrap_err();
        assert!(err.contains("BOM"), "{err}");

        let mut bom = options("");
        bom.encoding = ExportEncoding::Utf8Bom;
        let records = records_from(&with_bom, &bom).unwrap();
        assert_eq!(texts(&records[0]), [("id", false)], "BOM 不能混进第一个列名");
        assert!(records_from(b"id\r\n", &bom).unwrap_err().contains("没有 BOM"));
    }

    #[test]
    fn bad_delimiters_are_refused() {
        for delimiter in ["", ";;", "\"", "\n"] {
            let mut opts = options("");
            opts.delimiter = delimiter.to_string();
            assert!(records_from(b"a", &opts).is_err(), "{delimiter:?}");
        }
    }

    #[test]
    fn preview_marks_nulls_and_column_count_errors() {
        let mut opts = options("NULL");
        opts.header = true;
        let input = "id,note\r\n1,NULL\r\n2,\"NULL\"\r\n3\r\n4,x\r\n";
        let reader = CsvReader::open(input.as_bytes(), &opts).unwrap();
        let preview = preview_from(reader, &opts, 3).unwrap();

        assert_eq!(preview.header, ["id", "note"]);
        assert_eq!(preview.column_count, 2);
        assert_eq!(preview.rows.len(), 3, "表头不算在 limit 里");
        assert!(preview.rows[0].cells[1].placeholder);
        assert!(!preview.rows[1].cells[1].placeholder);
        assert_eq!(preview.rows[1].cells[1].text, "NULL");
        assert_eq!(preview.rows[2].line, 4);
        assert!(preview.rows[2].error.as_deref().unwrap().contains("1 列"));
        assert!(preview.error.is_none());
    }

    #[test]
    fn preview_keeps_rows_read_before_a_fatal_error() {
        let reader = CsvReader::open(&b"a\nb\n\"c\n"[..], &options("")).unwrap();
        let preview = preview_from(reader, &options(""), 10).unwrap();
        assert_eq!(preview.rows.len(), 2);
        assert!(preview.error.unwrap().contains("第 3 行"));
    }

    fn target(name: &str) -> TargetColumn {
        TargetColumn {
            name: name.to_string(),
            column_type: "varchar(20)".to_string(),
            nullable: true,
            auto_increment: false,
            is_binary: false,
            generated: false,
            mandatory: false,
        }
    }

    #[test]
    fn suggested_mapping_matches_names_case_insensitively() {
        let mut generated = target("total");
        generated.generated = true;
        let columns = vec![target("id"), target("Name"), generated];
        let header = vec!["name".to_string(), "ID".to_string(), "total".to_string(), "extra".to_string(), "id".to_string()];
        // 生成列不建议；同一列不会被建议两次
        assert_eq!(suggest_mapping(&header, &columns), [Some(1), Some(0), None, None, None]);
    }

    #[test]
    fn mapping_is_validated_before_writing() {
        let mut required = target("req");
        required.mandatory = true;
        let mut generated = target("total");
        generated.generated = true;
        let columns = vec![target("id"), required, generated];

        assert_eq!(validate_mapping(&columns, &[Some(1), None, Some(0)]).unwrap(), [(0, 1), (2, 0)]);
        assert!(validate_mapping(&columns, &[None, None]).unwrap_err().contains("没有映射"));
        assert!(validate_mapping(&columns, &[Some(0)]).unwrap_err().contains("req"));
        assert!(validate_mapping(&columns, &[Some(1), Some(1)]).unwrap_err().contains("不止一次"));
        assert!(validate_mapping(&columns, &[Some(1), Some(2)]).unwrap_err().contains("生成列"));
        assert!(validate_mapping(&columns, &[Some(1), Some(9)]).unwrap_err().contains("越界"));
    }

    #[test]
    fn not_null_columns_reject_null_before_reaching_mysql() {
        let mut strict = target("amount");
        strict.nullable = false;
        let mut auto = target("id");
        auto.nullable = false;
        auto.auto_increment = true;
        let columns = vec![auto, strict];
        let record = Record {
            line: 7,
            fields: vec![Field { text: "NULL".into(), quoted: false }, Field { text: "NULL".into(), quoted: false }],
        };
        // 自增列写 NULL 合法
        assert!(row_params(&record, &[(0, 0)], &columns, "NULL").is_ok());
        let err = row_params(&record, &[(0, 0), (1, 1)], &columns, "NULL").unwrap_err();
        assert!(err.contains("amount") && err.contains("NULL"), "{err}");
    }

    #[test]
    fn insert_sql_uses_placeholders_only() {
        assert_eq!(
            insert_sql("shop", "or`ders", &["id", "note"], 2),
            "INSERT INTO `shop`.`or``ders` (`id`, `note`) VALUES (?, ?), (?, ?)"
        );
    }

    #[test]
    fn error_line_keeps_original_quoting() {
        let fields = vec![
            Field { text: "NULL".into(), quoted: false },
            Field { text: "NULL".into(), quoted: true },
            Field { text: "a\"b".into(), quoted: true },
        ];
        assert_eq!(error_line(&fields, "第 3 行：x,y", ',', "NULL"), "NULL,\"NULL\",\"a\"\"b\",\"第 3 行：x,y\"\r\n");
    }

    fn meta(name: &str, is_binary: bool) -> ColumnMeta {
        ColumnMeta {
            name: name.to_string(),
            org_name: name.to_string(),
            org_table: "t".to_string(),
            schema: "s".to_string(),
            is_binary,
            kind: if is_binary { ColumnKind::Binary } else { ColumnKind::Text },
            decimals: 0,
        }
    }

    /// 导出时的值读回来应该是什么：数字本来就按文本交给 MySQL，其余原样
    fn expected_after_import(cell: &CellValue) -> CellValue {
        match cell {
            CellValue::Int(n) => CellValue::Text(n.to_string()),
            CellValue::UInt(n) => CellValue::Text(n.to_string()),
            CellValue::Double(n) => CellValue::Text(n.to_string()),
            other => other.clone(),
        }
    }

    #[test]
    fn export_then_import_gives_back_the_same_values() {
        let columns = vec![meta("id", false), meta("备注", false), meta("bin", true)];
        let rows = vec![
            vec![CellValue::Int(-1), CellValue::Text("a,b \"引号\"\r\n换行".into()), CellValue::Bytes(vec![0, 0xFF])],
            vec![CellValue::UInt(u64::MAX), CellValue::Null, CellValue::Bytes(vec![])],
            vec![CellValue::Double(0.1), CellValue::Text(String::new()), CellValue::Null],
            vec![CellValue::Int(3), CellValue::Text("NULL".into()), CellValue::Bytes(vec![0x30])],
            vec![CellValue::Int(4), CellValue::Text("\\N".into()), CellValue::Null],
            vec![CellValue::Int(5), CellValue::Text("中文；\t制表".into()), CellValue::Null],
        ];
        let dir = std::env::temp_dir().join(format!("cdata-import-roundtrip-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();

        for encoding in [ExportEncoding::Utf8, ExportEncoding::Utf8Bom, ExportEncoding::Gbk] {
            for null_text in ["", "NULL", "\\N"] {
                for delimiter in [",", ";", "\t"] {
                    let label = format!("{encoding:?} null={null_text:?} delimiter={delimiter:?}");
                    let path = dir.join("rt.csv");
                    let export = ExportOptions {
                        format: ExportFormat::Csv,
                        encoding,
                        delimiter: delimiter.to_string(),
                        header: true,
                        null_text: null_text.to_string(),
                        table_name: String::new(),
                    };
                    write_file(&path, &columns, &rows, &[0, 1, 2], &export).unwrap();

                    let import = ImportOptions {
                        encoding,
                        delimiter: delimiter.to_string(),
                        header: true,
                        null_text: null_text.to_string(),
                    };
                    let bytes = fs::read(&path).unwrap();
                    let records = records_from(&bytes, &import).unwrap_or_else(|e| panic!("{label}: {e}"));
                    assert_eq!(texts(&records[0]), [("id", false), ("备注", false), ("bin", false)], "{label}");
                    assert_eq!(records.len(), rows.len() + 1, "{label}");
                    for (record, row) in records[1..].iter().zip(&rows) {
                        for (index, (field, cell)) in record.fields.iter().zip(row).enumerate() {
                            let value = field_value(field, columns[index].is_binary, null_text)
                                .unwrap_or_else(|e| panic!("{label}: {e}"));
                            assert_eq!(value, expected_after_import(cell), "{label} 第 {} 行", record.line);
                        }
                    }
                }
            }
        }
        fs::remove_dir_all(&dir).ok();
    }
}
