//! 偏好设置。存用户数据目录的 preferences.json，丢了只是回到默认值。

use std::fs;

use serde::{Deserialize, Serialize};

use crate::connections::{Error, Result};
use crate::history::data_file;

/// 结果集行数上限的上限。十万行是定下来的取舍（见 ROADMAP），偏好只能往小调
pub const MAX_ROWS_LIMIT: u64 = 100_000;

const FONT_SIZE_MIN: u32 = 10;
const FONT_SIZE_MAX: u32 = 24;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ThemeMode {
    System,
    Light,
    Dark,
}

/// serde(default)：以后加了字段，旧文件里缺的那几项取默认值，不因为升级就整个读不出来
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Preferences {
    pub theme: ThemeMode,
    /// SQL 编辑器字号
    pub editor_font_size: u32,
    /// 一次查询最多取多少行，超过截断并提示
    pub max_rows: u64,
}

impl Default for Preferences {
    fn default() -> Self {
        Preferences {
            theme: ThemeMode::System,
            editor_font_size: 13,
            max_rows: MAX_ROWS_LIMIT,
        }
    }
}

impl Preferences {
    /// 不合法就拒绝，不悄悄夹到范围里 —— 用户填 50 万，存下来变成 10 万，他会以为数据全了
    pub fn validate(&self) -> Result<()> {
        if self.max_rows == 0 || self.max_rows > MAX_ROWS_LIMIT {
            return Err(Error::Invalid(format!(
                "行数上限要在 1 到 {MAX_ROWS_LIMIT} 之间，现在是 {}",
                self.max_rows
            )));
        }
        if self.editor_font_size < FONT_SIZE_MIN || self.editor_font_size > FONT_SIZE_MAX {
            return Err(Error::Invalid(format!(
                "编辑器字号要在 {FONT_SIZE_MIN} 到 {FONT_SIZE_MAX} 之间，现在是 {}",
                self.editor_font_size
            )));
        }
        Ok(())
    }
}

/// 读偏好。文件不存在是默认值；文件里的值不合法报错，由界面告诉用户
pub fn load() -> Result<Preferences> {
    let path = data_file("CDATA_PREFERENCES_PATH", "preferences.json")?;
    if !path.exists() {
        return Ok(Preferences::default());
    }

    let text = fs::read_to_string(&path).map_err(|e| Error::Io(e.to_string()))?;
    let preferences: Preferences = serde_json::from_str(&text).map_err(|e| Error::Parse(e.to_string()))?;
    preferences.validate()?;
    Ok(preferences)
}

/// 校验通过才写
pub fn save(preferences: &Preferences) -> Result<()> {
    preferences.validate()?;

    let path = data_file("CDATA_PREFERENCES_PATH", "preferences.json")?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| Error::Io(e.to_string()))?;
    }
    let text = serde_json::to_string_pretty(preferences).map_err(|e| Error::Parse(e.to_string()))?;
    fs::write(&path, text).map_err(|e| Error::Io(e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_out_of_range_values() {
        let too_many = Preferences { max_rows: MAX_ROWS_LIMIT + 1, ..Preferences::default() };
        assert!(too_many.validate().is_err());

        let zero = Preferences { max_rows: 0, ..Preferences::default() };
        assert!(zero.validate().is_err());

        let tiny_font = Preferences { editor_font_size: 6, ..Preferences::default() };
        assert!(tiny_font.validate().is_err());

        assert!(Preferences::default().validate().is_ok());
    }

    #[test]
    fn missing_fields_take_defaults() {
        let preferences: Preferences = serde_json::from_str(r#"{"theme":"Dark"}"#).unwrap();
        assert_eq!(preferences.theme, ThemeMode::Dark);
        assert_eq!(preferences.max_rows, MAX_ROWS_LIMIT);
    }

    #[test]
    fn save_load_round_trip() {
        let dir = std::env::temp_dir().join(format!("cdata-prefs-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("preferences.json");
        // SAFETY: 只有这个测试读写这个变量
        unsafe { std::env::set_var("CDATA_PREFERENCES_PATH", &path) };

        // 文件不存在是默认值，不是错误
        assert_eq!(load().unwrap(), Preferences::default());

        let changed = Preferences { theme: ThemeMode::Dark, editor_font_size: 15, max_rows: 5000 };
        save(&changed).unwrap();
        assert_eq!(load().unwrap(), changed);

        // 不合法的值存不进去，文件保持上一次的内容
        let invalid = Preferences { max_rows: 0, ..changed.clone() };
        assert!(save(&invalid).is_err());
        assert_eq!(load().unwrap(), changed);

        // 手改文件写进了不合法的值：读的时候报错，不悄悄换成默认值
        std::fs::write(&path, r#"{"max_rows": 999999}"#).unwrap();
        assert!(load().is_err());

        std::fs::remove_dir_all(&dir).unwrap();
    }
}
