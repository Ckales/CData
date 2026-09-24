//! CellValue 跨 FFI 的镜像声明与薄包装。
//!
//! 所有解释规则都在 cdata-core，这里只做翻译。改了 core 的 CellValue，
//! 下面的 mirror 必须同步改，否则生成的 Dart 类型会和实际数据对不上。

use flutter_rust_bridge::frb;

// 按裸名导入，生成的代码会把镜像类型引用为 crate::api::value::<Name>
pub use cdata_core::CellValue;

#[frb(mirror(CellValue))]
pub enum _CellValue {
    Null,
    Int(i64),
    UInt(u64),
    Double(f64),
    Text(String),
    Bytes(Vec<u8>),
    InvalidText(Vec<u8>),
}

/// 单元格在网格里的显示文本
pub fn display_text(value: CellValue) -> String {
    cdata_core::display_text(&value)
}
