//! 执行过的 SQL 和收藏的 SQL。存用户数据目录的 JSON，和连接配置、列布局分开放。

use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::connections::{Error, Result};

/// 历史最多留这么多条，旧的丢掉
const HISTORY_LIMIT: usize = 500;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HistoryEntry {
    pub sql: String,
    /// Unix 毫秒，界面按本地时区显示
    pub executed_at: i64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Favorite {
    pub id: String,
    pub name: String,
    pub sql: String,
}

pub(crate) fn data_file(env_name: &str, file_name: &str) -> Result<PathBuf> {
    // 测试指到临时文件，免得改掉用户真实的数据
    if let Ok(path) = std::env::var(env_name) {
        return Ok(PathBuf::from(path));
    }
    let base = dirs::data_dir().ok_or(Error::NoDataDir)?;
    Ok(base.join("CData").join(file_name))
}

fn read_json<T: for<'de> Deserialize<'de>>(path: &PathBuf) -> Result<Vec<T>> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let text = fs::read_to_string(path).map_err(|e| Error::Io(e.to_string()))?;
    serde_json::from_str(&text).map_err(|e| Error::Parse(e.to_string()))
}

fn write_json<T: Serialize>(path: &PathBuf, items: &[T]) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| Error::Io(e.to_string()))?;
    }
    let text = serde_json::to_string_pretty(items).map_err(|e| Error::Parse(e.to_string()))?;
    fs::write(path, text).map_err(|e| Error::Io(e.to_string()))
}

fn now_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn history_path() -> Result<PathBuf> {
    data_file("CDATA_HISTORY_PATH", "history.json")
}

fn favorites_path() -> Result<PathBuf> {
    data_file("CDATA_FAVORITES_PATH", "favorites.json")
}

/// 历史，最新的在前
pub fn history() -> Result<Vec<HistoryEntry>> {
    read_json(&history_path()?)
}

/// 记一条。和最近一条一样就只更新时间，连着点十次运行不刷出十条
pub fn add_history(sql: &str) -> Result<()> {
    let sql = sql.trim();
    if sql.is_empty() {
        return Ok(());
    }

    let path = history_path()?;
    let mut entries: Vec<HistoryEntry> = read_json(&path)?;
    if entries.first().is_some_and(|last| last.sql == sql) {
        entries.remove(0);
    }
    entries.insert(0, HistoryEntry { sql: sql.to_string(), executed_at: now_millis() });
    entries.truncate(HISTORY_LIMIT);
    write_json(&path, &entries)
}

pub fn favorites() -> Result<Vec<Favorite>> {
    read_json(&favorites_path()?)
}

/// 收藏一条，返回它的 id。同名的覆盖，不另起一条
pub fn save_favorite(name: &str, sql: &str) -> Result<String> {
    let path = favorites_path()?;
    let mut items: Vec<Favorite> = read_json(&path)?;

    let id = match items.iter_mut().find(|f| f.name == name) {
        Some(existing) => {
            existing.sql = sql.to_string();
            existing.id.clone()
        }
        None => {
            let id = format!("fav-{}", now_millis());
            items.push(Favorite { id: id.clone(), name: name.to_string(), sql: sql.to_string() });
            id
        }
    };
    write_json(&path, &items)?;
    Ok(id)
}

/// 删收藏。删不存在的要报错，不静默成功
pub fn delete_favorite(id: &str) -> Result<()> {
    let path = favorites_path()?;
    let mut items: Vec<Favorite> = read_json(&path)?;
    let before = items.len();
    items.retain(|f| f.id != id);
    if items.len() == before {
        return Err(Error::NotFound(id.to_string()));
    }
    write_json(&path, &items)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 两个测试都碰环境变量，放一个测试里串行跑
    #[test]
    fn history_and_favorites_round_trip() {
        let dir = std::env::temp_dir().join(format!("cdata-history-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        // SAFETY: 只有这个测试碰这两个变量
        unsafe {
            std::env::set_var("CDATA_HISTORY_PATH", dir.join("history.json"));
            std::env::set_var("CDATA_FAVORITES_PATH", dir.join("favorites.json"));
        }

        assert!(history().unwrap().is_empty());
        add_history("SELECT 1").unwrap();
        add_history("  SELECT 2  ").unwrap();
        add_history("SELECT 2").unwrap();
        add_history("   ").unwrap();
        let sqls: Vec<String> = history().unwrap().into_iter().map(|e| e.sql).collect();
        assert_eq!(sqls, ["SELECT 2", "SELECT 1"], "最新的在前，连着重复的只留一条，空的不记");

        for i in 0..(HISTORY_LIMIT + 5) {
            add_history(&format!("SELECT {i}")).unwrap();
        }
        assert_eq!(history().unwrap().len(), HISTORY_LIMIT);

        let id = save_favorite("日报", "SELECT * FROM daily").unwrap();
        let same = save_favorite("日报", "SELECT * FROM daily_v2").unwrap();
        assert_eq!(id, same, "同名覆盖");
        let all = favorites().unwrap();
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].sql, "SELECT * FROM daily_v2");

        delete_favorite(&id).unwrap();
        assert!(favorites().unwrap().is_empty());
        assert!(delete_favorite(&id).is_err());

        unsafe {
            std::env::remove_var("CDATA_HISTORY_PATH");
            std::env::remove_var("CDATA_FAVORITES_PATH");
        }
        std::fs::remove_dir_all(&dir).ok();
    }
}
