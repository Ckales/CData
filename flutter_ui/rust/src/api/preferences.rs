//! 偏好设置的 FFI 接口。取值范围在 core 校验。

use flutter_rust_bridge::frb;

pub use cdata_core::preferences::{Preferences, ThemeMode};

use crate::api::db::Result;

#[frb(mirror(ThemeMode))]
pub enum _ThemeMode {
    System,
    Light,
    Dark,
}

#[frb(mirror(Preferences))]
pub struct _Preferences {
    pub theme: ThemeMode,
    pub editor_font_size: u32,
    pub max_rows: u64,
}

/// 没存过就是默认值；存的值不合法报错
pub fn load_preferences() -> Result<Preferences> {
    cdata_core::preferences::load().map_err(|err| err.to_string())
}

pub fn save_preferences(preferences: Preferences) -> Result<()> {
    cdata_core::preferences::save(&preferences).map_err(|err| err.to_string())
}

/// 默认值也由 core 给，Dart 侧不另写一份
#[frb(sync)]
pub fn default_preferences() -> Preferences {
    Preferences::default()
}
