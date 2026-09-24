//! 列布局（列宽、列顺序）的 FFI 接口。合并规则在 core，这里只做翻译。

use flutter_rust_bridge::frb;

pub use cdata_core::layouts::ColumnLayout;

use crate::api::db::Result;

#[frb(mirror(ColumnLayout))]
pub struct _ColumnLayout {
    pub name: String,
    pub width: f64,
}

/// 某张表记住的布局，没记过是空列表
pub fn load_layout(key: String) -> Result<Vec<ColumnLayout>> {
    cdata_core::layouts::load(&key).map_err(|err| err.to_string())
}

/// 记住布局。这次没出现的列保留上次的宽度
pub fn save_layout(key: String, columns: Vec<ColumnLayout>) -> Result<()> {
    cdata_core::layouts::save(&key, columns).map_err(|err| err.to_string())
}
