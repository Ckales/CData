//! 结果网格的列布局（列宽、列顺序），按「服务器 + 表」记住。
//!
//! 存用户数据目录的 layouts.json，和连接配置分开：这是界面偏好，丢了只是回到默认宽度。

use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::connections::{Error, Result};
use crate::db::ColumnMeta;
use crate::edit::single_source_table;

/// 一列的布局。在列表里的位置就是显示顺序
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ColumnLayout {
    pub name: String,
    pub width: f64,
}

/// 布局键。只有结果集来自单张表时才有 —— JOIN、表达式结果的列没有稳定归属，不记
pub fn layout_key(server: &str, columns: &[ColumnMeta]) -> Option<String> {
    let (schema, table) = single_source_table(columns).ok()?;
    Some(format!("{server}/{schema}.{table}"))
}

fn layouts_path() -> Result<PathBuf> {
    // 测试指到临时文件，免得改掉用户真实的布局
    if let Ok(path) = std::env::var("CDATA_LAYOUTS_PATH") {
        return Ok(PathBuf::from(path));
    }

    let base = dirs::data_dir().ok_or(Error::NoDataDir)?;
    Ok(base.join("CData").join("layouts.json"))
}

fn read_all() -> Result<BTreeMap<String, Vec<ColumnLayout>>> {
    let path = layouts_path()?;
    if !path.exists() {
        return Ok(BTreeMap::new());
    }

    let text = fs::read_to_string(&path).map_err(|e| Error::Io(e.to_string()))?;
    serde_json::from_str(&text).map_err(|e| Error::Parse(e.to_string()))
}

/// 某张表记住的布局。没记过是空列表，不是错误
pub fn load(key: &str) -> Result<Vec<ColumnLayout>> {
    Ok(read_all()?.remove(key).unwrap_or_default())
}

/// 记住布局。
///
/// 同一张表可能这次只 SELECT 了几列：这次没出现的列保留上次的宽度，排在后面，
/// 否则查一次 `SELECT id, name` 就把其他列的宽度全冲掉了。
pub fn save(key: &str, columns: Vec<ColumnLayout>) -> Result<()> {
    let mut all = read_all()?;

    let mut merged = columns;
    if let Some(previous) = all.remove(key) {
        for old in previous {
            if !merged.iter().any(|c| c.name == old.name) {
                merged.push(old);
            }
        }
    }
    all.insert(key.to_string(), merged);

    let path = layouts_path()?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| Error::Io(e.to_string()))?;
    }
    let text = serde_json::to_string_pretty(&all).map_err(|e| Error::Parse(e.to_string()))?;
    fs::write(&path, text).map_err(|e| Error::Io(e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn column(name: &str, table: &str) -> ColumnMeta {
        ColumnMeta {
            name: name.to_string(),
            org_name: name.to_string(),
            org_table: table.to_string(),
            schema: "shop".to_string(),
            is_binary: false,
            kind: crate::db::ColumnKind::Text,
            decimals: 0,
        }
    }

    fn layout(name: &str, width: f64) -> ColumnLayout {
        ColumnLayout { name: name.to_string(), width }
    }

    #[test]
    fn key_only_for_single_table_results() {
        let single = vec![column("id", "orders"), column("amount", "orders")];
        assert_eq!(
            layout_key("127.0.0.1:3306", &single),
            Some("127.0.0.1:3306/shop.orders".to_string())
        );

        let join = vec![column("id", "orders"), column("name", "users")];
        assert_eq!(layout_key("127.0.0.1:3306", &join), None);
    }

    #[test]
    fn save_keeps_widths_of_columns_not_in_this_query() {
        let dir = std::env::temp_dir().join(format!("cdata-layouts-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        // SAFETY: 只有这一个测试碰 CDATA_LAYOUTS_PATH
        unsafe { std::env::set_var("CDATA_LAYOUTS_PATH", dir.join("layouts.json")) };

        assert!(load("s/shop.orders").unwrap().is_empty(), "没记过是空列表");

        save("s/shop.orders", vec![layout("id", 80.0), layout("name", 200.0), layout("note", 300.0)])
            .unwrap();
        // 这次只查了两列，还换了顺序
        save("s/shop.orders", vec![layout("name", 250.0), layout("id", 90.0)]).unwrap();

        assert_eq!(
            load("s/shop.orders").unwrap(),
            vec![layout("name", 250.0), layout("id", 90.0), layout("note", 300.0)]
        );
        // 别的表不受影响
        assert!(load("s/shop.users").unwrap().is_empty());

        unsafe { std::env::remove_var("CDATA_LAYOUTS_PATH") };
        std::fs::remove_dir_all(&dir).ok();
    }
}
