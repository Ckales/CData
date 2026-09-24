//! MySQL 值 → 单元格值的保真映射。
//!
//! 这一层的唯一职责是「不产出假正确的数据」：宁可保留原始文本、宁可显式标记无法解码，
//! 也不做任何有损转换或编码猜测。整个项目里 MySQL 值只在这里被解释一次。

use mysql_async::Value;
use serde::{Deserialize, Serialize};

/// 一个单元格的值。数值类型只保留能无损表示的，其余一律走原始文本。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum CellValue {
    Null,
    Int(i64),
    /// unsigned BIGINT 可以超过 i64::MAX，必须独立表示
    UInt(u64),
    Double(f64),
    /// DECIMAL、日期时间、FLOAT 以及所有文本列，保留 MySQL 的原始表示
    Text(String),
    /// BLOB / BINARY 列
    Bytes(Vec<u8>),
    /// 声明为文本列、但字节不是合法 UTF-8。不猜编码，原样上交由界面提示
    InvalidText(Vec<u8>),
}

/// MySQL 值转单元格值。is_binary_column 来自列元数据的字符集，不从值本身猜
pub fn cell_from_value(value: Value, is_binary_column: bool) -> CellValue {
    match value {
        Value::NULL => CellValue::Null,
        Value::Int(n) => CellValue::Int(n),
        Value::UInt(n) => CellValue::UInt(n),
        Value::Double(n) => CellValue::Double(n),

        // f32 转 f64 会把 f32 的精度垃圾暴露出来（0.1f32 as f64 = 0.10000000149011612），
        // 用最短往返表示存成文本，列是否为数值由列元数据决定，不靠这里的类型
        Value::Float(n) => CellValue::Text(n.to_string()),

        // DECIMAL 也走这里：原样保留字符串，转 f64 会丢金额精度
        Value::Bytes(bytes) => bytes_to_cell(bytes, is_binary_column),

        Value::Date(year, month, day, hour, min, sec, micros) => {
            CellValue::Text(format_datetime(year, month, day, hour, min, sec, micros))
        }
        Value::Time(is_negative, days, hours, minutes, seconds, micros) => {
            CellValue::Text(format_time(is_negative, days, hours, minutes, seconds, micros))
        }
    }
}

/// 二进制列直接给字节；文本列必须是合法 UTF-8，否则显式标记而不是替换成 U+FFFD
fn bytes_to_cell(bytes: Vec<u8>, is_binary_column: bool) -> CellValue {
    if is_binary_column {
        return CellValue::Bytes(bytes);
    }

    match String::from_utf8(bytes) {
        Ok(text) => CellValue::Text(text),
        Err(err) => CellValue::InvalidText(err.into_bytes()),
    }
}

/// 按 MySQL 的字面形式格式化，零日期 0000-00-00 必须原样保留
fn format_datetime(year: u16, month: u8, day: u8, hour: u8, min: u8, sec: u8, micros: u32) -> String {
    let date = format!("{:04}-{:02}-{:02}", year, month, day);

    // DATE 列没有时间部分，MySQL 给的是全零
    if hour == 0 && min == 0 && sec == 0 && micros == 0 {
        return date;
    }

    let time = format!("{:02}:{:02}:{:02}", hour, min, sec);
    if micros == 0 {
        return format!("{} {}", date, time);
    }
    format!("{} {}.{:06}", date, time, micros)
}

/// TIME 的范围是 ±838:59:59，天数要折算进小时
fn format_time(is_negative: bool, days: u32, hours: u8, minutes: u8, seconds: u8, micros: u32) -> String {
    let total_hours = days * 24 + hours as u32;
    let sign = if is_negative { "-" } else { "" };

    if micros == 0 {
        return format!("{}{:02}:{:02}:{:02}", sign, total_hours, minutes, seconds);
    }
    format!(
        "{}{:02}:{:02}:{:02}.{:06}",
        sign, total_hours, minutes, seconds, micros
    )
}

/// 校验要写进 TIME 列的文本，合法返回 Ok，原文照写不改。
///
/// TIME 是一段时长而不是一天里的时刻：范围 -838:59:59 到 838:59:59，小时可以超过 23。
/// 只收 `[-]H:MM:SS[.ffffff]`（小时 1–3 位），MySQL 另外几种宽松写法（`D HH:MM`、`HHMMSS`）
/// 一概拒绝，免得 `12:30` 被理解成 12 小时 30 分还是 12 分 30 秒要人去猜。
///
/// fsp 是列定义的小数秒位数（列元数据的 decimals），超过 6 表示不固定（表达式）。
/// 多出来的非零小数位 MySQL 会悄悄舍入，这里拒绝而不是替用户截断。
/// 超出范围在非严格 sql_mode 下会被夹到 ±838:59:59，同样先拦下
pub fn check_time_text(text: &str, fsp: u8) -> Result<(), String> {
    const FORMAT: &str = "格式是 [-]时:分:秒[.微秒]，比如 -12:30:00 或 100:00:00.5";
    let body = text.strip_prefix('-').unwrap_or(text);
    let (clock, fraction) = match body.split_once('.') {
        Some((clock, fraction)) => (clock, Some(fraction)),
        None => (body, None),
    };

    let parts: Vec<&str> = clock.split(':').collect();
    let all_digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
    if parts.len() != 3
        || !all_digits(parts[0])
        || parts[0].len() > 3
        || parts[1].len() != 2
        || parts[2].len() != 2
        || !all_digits(parts[1])
        || !all_digits(parts[2])
    {
        return Err(format!("不是合法的 TIME：{FORMAT}"));
    }
    let hours: u32 = parts[0].parse().unwrap();
    let minutes: u32 = parts[1].parse().unwrap();
    let seconds: u32 = parts[2].parse().unwrap();
    if minutes > 59 || seconds > 59 {
        return Err("分和秒都只能是 00–59".to_string());
    }

    let fraction = fraction.unwrap_or("");
    if text.contains('.') && (!all_digits(fraction) || fraction.len() > 6) {
        return Err("小数秒是 1–6 位数字".to_string());
    }
    let has_fraction = fraction.bytes().any(|b| b != b'0');
    if hours > 838 || (hours == 838 && minutes == 59 && seconds == 59 && has_fraction) {
        return Err("TIME 的范围是 -838:59:59 到 838:59:59".to_string());
    }

    let fsp = fsp.min(6) as usize;
    if fraction.len() > fsp && fraction.bytes().skip(fsp).any(|b| b != b'0') {
        return Err(if fsp == 0 {
            "这一列不存小数秒，写进去会被 MySQL 舍入；请去掉小数部分".to_string()
        } else {
            format!("这一列只存 {fsp} 位小数秒，多出的位数会被 MySQL 舍入；请只写 {fsp} 位")
        });
    }
    Ok(())
}

/// 单元格在网格里的显示文本。NULL 和不可读内容用明确占位，不返回空串冒充正常值
pub fn display_text(value: &CellValue) -> String {
    match value {
        CellValue::Null => "NULL".to_string(),
        CellValue::Int(n) => n.to_string(),
        CellValue::UInt(n) => n.to_string(),
        CellValue::Double(n) => n.to_string(),
        CellValue::Text(text) => text.clone(),
        CellValue::Bytes(bytes) => format!("<二进制 {} 字节>", bytes.len()),
        CellValue::InvalidText(bytes) => format!("<无法解码 {} 字节>", bytes.len()),
    }
}

/// 网格里的一格。placeholder 表示显示的不是值本身（NULL、二进制、解码失败），
/// 界面据此画成另一种样式 —— 不能靠文字反推，内容恰好是 "NULL" 的文本也是真实文本
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DisplayCell {
    pub text: String,
    pub placeholder: bool,
}

pub fn display_cell(value: &CellValue) -> DisplayCell {
    let placeholder = matches!(value, CellValue::Null | CellValue::Bytes(_) | CellValue::InvalidText(_));
    DisplayCell { text: display_text(value), placeholder }
}

/// 二进制内容的十六进制视图：偏移、16 字节一行、可打印 ASCII。
/// 太大的 BLOB 只显示前 limit 字节，并在末尾写明总长，不假装显示了全部
pub fn hex_dump(bytes: &[u8], limit: usize) -> String {
    let shown = &bytes[..bytes.len().min(limit)];
    let mut lines = Vec::with_capacity(shown.len() / 16 + 2);

    for (line_index, chunk) in shown.chunks(16).enumerate() {
        let mut hex = String::with_capacity(48);
        let mut ascii = String::with_capacity(16);
        for (i, byte) in chunk.iter().enumerate() {
            if i == 8 {
                hex.push(' ');
            }
            hex.push_str(&format!("{byte:02X} "));
            ascii.push(if byte.is_ascii_graphic() || *byte == b' ' { *byte as char } else { '.' });
        }
        lines.push(format!("{:08X}  {hex:<49} {ascii}", line_index * 16));
    }

    if bytes.len() > shown.len() {
        lines.push(format!("…… 只显示前 {} 字节，共 {} 字节", shown.len(), bytes.len()));
    }
    lines.join("\n")
}

/// 把 JSON 文本格式化成缩进形式，也用来校验：不合法就返回解析错误（带行列号）。
///
/// 键的顺序和数字的原始写法都保留（见 Cargo.toml 里 serde_json 的特性），
/// 格式化只改空白，不改内容。
pub fn format_json(text: &str) -> Result<String, String> {
    let value: serde_json::Value =
        serde_json::from_str(text).map_err(|err| format!("不是合法的 JSON：{err}"))?;
    serde_json::to_string_pretty(&value).map_err(|err| err.to_string())
}

/// 单元格值转回 MySQL 值，写回时用。
///
/// Text 一律当字符串绑定，由 MySQL 按目标列的类型转换 —— 这是走参数化后最保真的做法：
/// 我们不知道 `"1234567.89"` 该进 DECIMAL 还是 VARCHAR，MySQL 知道。自己先转成 f64
/// 再绑定反而会丢精度。
pub fn value_to_mysql(cell: &CellValue) -> Value {
    match cell {
        CellValue::Null => Value::NULL,
        CellValue::Int(n) => Value::Int(*n),
        CellValue::UInt(n) => Value::UInt(*n),
        CellValue::Double(n) => Value::Double(*n),
        CellValue::Text(text) => Value::Bytes(text.as_bytes().to_vec()),
        CellValue::Bytes(bytes) => Value::Bytes(bytes.clone()),
        // 原样送回去。这些字节本来就不是合法文本，任何"修复"都是伪造
        CellValue::InvalidText(bytes) => Value::Bytes(bytes.clone()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn null_and_integers() {
        assert_eq!(cell_from_value(Value::NULL, false), CellValue::Null);
        assert_eq!(cell_from_value(Value::Int(-42), false), CellValue::Int(-42));
    }

    #[test]
    fn unsigned_bigint_beyond_i64_survives() {
        // 18446744073709551615 塞进 i64 会溢出，必须走 UInt
        let max = u64::MAX;
        assert_eq!(cell_from_value(Value::UInt(max), false), CellValue::UInt(max));
    }

    #[test]
    fn decimal_keeps_exact_text() {
        // 金额场景：转 f64 会变成 1234567.8899999999，这里必须原样
        let raw = b"1234567.89".to_vec();
        assert_eq!(
            cell_from_value(Value::Bytes(raw), false),
            CellValue::Text("1234567.89".to_string())
        );
    }

    #[test]
    fn float_does_not_leak_f32_noise() {
        // 0.1f32 as f64 = 0.10000000149011612，用户要看到的是 0.1
        assert_eq!(
            cell_from_value(Value::Float(0.1), false),
            CellValue::Text("0.1".to_string())
        );
    }

    #[test]
    fn zero_date_is_preserved() {
        // MySQL 允许 0000-00-00，chrono 表示不了，所以全程走文本
        assert_eq!(
            cell_from_value(Value::Date(0, 0, 0, 0, 0, 0, 0), false),
            CellValue::Text("0000-00-00".to_string())
        );
    }

    #[test]
    fn datetime_with_and_without_micros() {
        assert_eq!(
            cell_from_value(Value::Date(2026, 9, 23, 14, 30, 5, 0), false),
            CellValue::Text("2026-09-23 14:30:05".to_string())
        );
        assert_eq!(
            cell_from_value(Value::Date(2026, 9, 23, 14, 30, 5, 123456), false),
            CellValue::Text("2026-09-23 14:30:05.123456".to_string())
        );
    }

    #[test]
    fn date_only_has_no_time_part() {
        assert_eq!(
            cell_from_value(Value::Date(2026, 9, 23, 0, 0, 0, 0), false),
            CellValue::Text("2026-09-23".to_string())
        );
    }

    #[test]
    fn negative_time_folds_days_into_hours() {
        // -838:59:59 是 TIME 的下界，34 天 22 小时
        assert_eq!(
            cell_from_value(Value::Time(true, 34, 22, 59, 59, 0), false),
            CellValue::Text("-838:59:59".to_string())
        );
    }

    #[test]
    fn time_accepts_durations_beyond_a_day_and_negative() {
        for ok in ["00:00:00", "-838:59:59", "838:59:59", "838:59:59.000000", "100:00:00.5", "-0:00:00.000001", "8:05:09"] {
            assert_eq!(check_time_text(ok, 6), Ok(()), "{ok}");
        }
    }

    #[test]
    fn time_refuses_other_shapes_and_out_of_range() {
        for bad in ["", "-", "12:30", "1 12:00:00", "123000", " 12:00:00", "12:0:00", "1000:00:00", "12:00:00.", "12:00:00.1234567", "12:00:00.1a", "+12:00:00"] {
            assert!(check_time_text(bad, 6).is_err(), "{bad:?} 不该通过");
        }
        assert!(check_time_text("12:60:00", 6).unwrap_err().contains("00–59"));
        assert!(check_time_text("839:00:00", 6).unwrap_err().contains("范围"));
        assert!(check_time_text("-838:59:59.5", 6).unwrap_err().contains("范围"));
    }

    #[test]
    fn time_refuses_digits_the_column_would_round_away() {
        // TIME(2)：二进制协议读回来总是 6 位，尾部补零不算多
        assert_eq!(check_time_text("12:00:00.500000", 2), Ok(()));
        assert_eq!(check_time_text("12:00:00.12", 2), Ok(()));
        assert!(check_time_text("12:00:00.125", 2).unwrap_err().contains("只存 2 位"));
        assert!(check_time_text("12:00:00.5", 0).unwrap_err().contains("不存小数秒"));
        // decimals = 31 是表达式列，不固定，按 6 位算
        assert_eq!(check_time_text("12:00:00.123456", 31), Ok(()));
    }

    #[test]
    fn binary_column_stays_bytes() {
        let raw = vec![0x00, 0xFF, 0x10];
        assert_eq!(
            cell_from_value(Value::Bytes(raw.clone()), true),
            CellValue::Bytes(raw)
        );
    }

    #[test]
    fn text_column_with_broken_utf8_is_flagged_not_mangled() {
        // latin1 的 0xE9，声明成 utf8 列。不能替换成 U+FFFD 假装没事
        let raw = vec![0x41, 0xE9, 0x42];
        assert_eq!(
            cell_from_value(Value::Bytes(raw.clone()), false),
            CellValue::InvalidText(raw)
        );
    }

    #[test]
    fn display_marks_unreadable_content_instead_of_faking_it() {
        // 空串会让人以为这列真的是空值，二进制和解码失败都必须看得出来
        assert_eq!(display_text(&CellValue::Null), "NULL");
        // 显示文字一样，但只有真正的 NULL 是占位
        assert!(display_cell(&CellValue::Null).placeholder);
        assert!(!display_cell(&CellValue::Text("NULL".into())).placeholder);
        assert!(!display_cell(&CellValue::Text("<二进制 12 字节>".into())).placeholder);
        assert!(display_cell(&CellValue::Bytes(vec![1])).placeholder);
        assert!(display_cell(&CellValue::InvalidText(vec![0xE9])).placeholder);
        assert_eq!(display_text(&CellValue::Bytes(vec![0u8; 12])), "<二进制 12 字节>");
        assert_eq!(
            display_text(&CellValue::InvalidText(vec![0xE9, 0x42])),
            "<无法解码 2 字节>"
        );
    }

    #[test]
    fn display_keeps_exact_numbers() {
        assert_eq!(display_text(&CellValue::UInt(u64::MAX)), "18446744073709551615");
        assert_eq!(display_text(&CellValue::Text("1234567.89".into())), "1234567.89");
    }

    #[test]
    fn write_back_keeps_decimal_and_bytes_intact() {
        // DECIMAL 以字符串绑定，交给 MySQL 按列类型转，自己转 f64 会丢精度
        assert_eq!(
            value_to_mysql(&CellValue::Text("1234567.89".into())),
            Value::Bytes(b"1234567.89".to_vec())
        );
        assert_eq!(value_to_mysql(&CellValue::Null), Value::NULL);
        assert_eq!(
            value_to_mysql(&CellValue::UInt(u64::MAX)),
            Value::UInt(u64::MAX)
        );
        // 无法解码的字节原样送回，不做任何"修复"
        assert_eq!(
            value_to_mysql(&CellValue::InvalidText(vec![0xE9, 0x42])),
            Value::Bytes(vec![0xE9, 0x42])
        );
    }

    #[test]
    fn value_survives_a_full_round_trip() {
        for original in [
            CellValue::Null,
            CellValue::Int(-42),
            CellValue::UInt(u64::MAX),
            CellValue::Text("订单已完成".into()),
            CellValue::Bytes(vec![0x00, 0xFF]),
        ] {
            let is_binary = matches!(original, CellValue::Bytes(_));
            let back = cell_from_value(value_to_mysql(&original), is_binary);
            assert_eq!(back, original, "{original:?} 往返后变了");
        }
    }

    #[test]
    fn format_json_keeps_key_order_and_number_precision() {
        let formatted = format_json(r#"{"z":1,"a":12345678901234567890.123456789,"m":[1.0,true,null]}"#)
            .expect("应该能格式化");
        assert_eq!(
            formatted,
            "{\n  \"z\": 1,\n  \"a\": 12345678901234567890.123456789,\n  \"m\": [\n    1.0,\n    true,\n    null\n  ]\n}"
        );
    }

    #[test]
    fn format_json_reports_where_it_broke() {
        let err = format_json("{\"a\": 1,}").unwrap_err();
        assert!(err.contains("line 1"), "{err}");
    }

    #[test]
    fn hex_dump_shows_offsets_and_ascii() {
        let dump = hex_dump(b"CData\x00\xFF", 1024);
        assert_eq!(dump, "00000000  43 44 61 74 61 00 FF                              CData..");
    }

    #[test]
    fn hex_dump_says_when_it_is_truncated() {
        let dump = hex_dump(&[0u8; 40], 32);
        assert_eq!(dump.lines().count(), 3);
        assert!(dump.ends_with("只显示前 32 字节，共 40 字节"), "{dump}");
    }

    #[test]
    fn chinese_text_round_trips() {
        let raw = "订单已完成".as_bytes().to_vec();
        assert_eq!(
            cell_from_value(Value::Bytes(raw), false),
            CellValue::Text("订单已完成".to_string())
        );
    }
}
