//! 执行过的 SQL 和收藏的 SQL。存用户数据目录的 JSON，和连接配置、列布局分开放。

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::connections::{Error, Result};
use crate::preferences;

static HISTORY_LOCK: Mutex<()> = Mutex::new(());
static BACKUP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

static SESSION_QUERY_HISTORY: OnceLock<Mutex<Vec<HistoryEntry>>> = OnceLock::new();

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
    crate::operation_log::write_json_atomic(path, items)
}

fn backup_prefix(path: &std::path::Path) -> String {
    format!(
        "{}.corrupt-",
        path.file_name().unwrap_or_default().to_string_lossy()
    )
}

/// 只对可重新收集的 SQL 历史启用：损坏内容完整备份，随后新建空历史。
/// 读文件失败不属于格式损坏，不能自动重建。
fn read_history_json(path: &PathBuf) -> Result<Vec<HistoryEntry>> {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(Error::Io(error.to_string())),
    };
    if let Ok(entries) = serde_json::from_slice(&bytes) {
        return Ok(entries);
    }

    let (backup, mut file) = loop {
        let sequence = BACKUP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let backup = path.with_file_name(format!(
            "{}{}-{}-{sequence}.bak",
            backup_prefix(path),
            now_millis(),
            std::process::id()
        ));
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&backup)
        {
            Ok(file) => break (backup, file),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(Error::Io(format!(
                    "历史损坏，备份失败，原文件未改动：{error}"
                )))
            }
        }
    };
    let result = file.write_all(&bytes).and_then(|()| file.sync_all());
    drop(file);
    if let Err(error) = result {
        let _ = fs::remove_file(&backup);
        return Err(Error::Io(format!(
            "历史损坏，备份失败，原文件未改动：{error}"
        )));
    }
    write_json::<HistoryEntry>(path, &[])?;
    Ok(Vec::new())
}

/// 新历史开始淘汰旧 SQL 后，损坏备份才失去保留价值。只清理本文件的备份。
fn remove_history_backups(path: &std::path::Path) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| Error::Io("历史路径没有父目录".into()))?;
    let prefix = backup_prefix(path);
    for entry in fs::read_dir(parent).map_err(|error| Error::Io(error.to_string()))? {
        let entry = entry.map_err(|error| Error::Io(error.to_string()))?;
        let name = entry.file_name();
        let name = name.to_string_lossy();
        let ours = name
            .strip_prefix(&prefix)
            .and_then(|suffix| suffix.strip_suffix(".bak"))
            .is_some_and(|suffix| {
                let parts: Vec<_> = suffix.split('-').collect();
                parts.len() == 3
                    && parts
                        .iter()
                        .all(|part| !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit()))
            });
        if ours
            && entry
                .file_type()
                .map_err(|error| Error::Io(error.to_string()))?
                .is_file()
        {
            fs::remove_file(entry.path()).map_err(|error| Error::Io(error.to_string()))?;
        }
    }
    Ok(())
}

fn append_history(path: &PathBuf, sql: &str, limit: usize) -> Result<()> {
    let mut entries = read_history_json(path)?;
    let duplicate = entries.first().is_some_and(|entry| entry.sql == sql);
    let exceeds_limit = entries.len() + usize::from(!duplicate) > limit;
    push_history(&mut entries, sql, limit);
    write_json(path, &entries)?;
    if exceeds_limit {
        remove_history_backups(path)?;
    }
    Ok(())
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

fn query_history_path() -> Result<PathBuf> {
    data_file("CDATA_QUERY_HISTORY_PATH", "query_history.json")
}

fn session_query_history() -> &'static Mutex<Vec<HistoryEntry>> {
    SESSION_QUERY_HISTORY.get_or_init(|| Mutex::new(Vec::new()))
}

fn push_history(entries: &mut Vec<HistoryEntry>, sql: &str, limit: usize) {
    if entries.first().is_some_and(|last| last.sql == sql) {
        entries.remove(0);
    }
    entries.insert(
        0,
        HistoryEntry {
            sql: sql.to_string(),
            executed_at: now_millis(),
        },
    );
    entries.truncate(limit);
}

fn favorites_path() -> Result<PathBuf> {
    data_file("CDATA_FAVORITES_PATH", "favorites.json")
}

/// 历史，最新的在前
pub fn history() -> Result<Vec<HistoryEntry>> {
    let _guard = HISTORY_LOCK.lock().unwrap();
    let mut entries = read_history_json(&history_path()?)?;
    entries.truncate(preferences::load()?.transcript_history_limit as usize);
    Ok(entries)
}

/// 记一条。和最近一条一样就只更新时间，连着点十次运行不刷出十条
pub fn add_history(sql: &str) -> Result<()> {
    let sql = sql.trim();
    if sql.is_empty() {
        return Ok(());
    }

    let _guard = HISTORY_LOCK.lock().unwrap();
    append_history(
        &history_path()?,
        sql,
        preferences::load()?.transcript_history_limit as usize,
    )
}

/// Query view 的最近查询。关闭跨启动保存时只读当前进程的内存记录。
pub fn query_history() -> Result<Vec<HistoryEntry>> {
    let _guard = HISTORY_LOCK.lock().unwrap();
    let preferences = preferences::load()?;
    let mut entries = if preferences.save_query_history {
        read_history_json(&query_history_path()?)?
    } else {
        session_query_history().lock().unwrap().clone()
    };
    entries.truncate(preferences.query_history_limit as usize);
    Ok(entries)
}

pub fn add_query_history(sql: &str) -> Result<()> {
    let sql = sql.trim();
    if sql.is_empty() {
        return Ok(());
    }
    let _guard = HISTORY_LOCK.lock().unwrap();
    let preferences = preferences::load()?;
    if preferences.save_query_history {
        append_history(
            &query_history_path()?,
            sql,
            preferences.query_history_limit as usize,
        )
    } else {
        let mut entries = session_query_history().lock().unwrap();
        push_history(&mut entries, sql, preferences.query_history_limit as usize);
        Ok(())
    }
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
            items.push(Favorite {
                id: id.clone(),
                name: name.to_string(),
                sql: sql.to_string(),
            });
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

    fn with_history_files(test: impl FnOnce(&std::path::Path)) {
        let _env = crate::preferences::PREFS_ENV_LOCK.lock().unwrap();
        let dir =
            std::env::temp_dir().join(format!("cdata-history-recovery-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        unsafe {
            std::env::set_var("CDATA_HISTORY_PATH", dir.join("history.json"));
            std::env::set_var("CDATA_QUERY_HISTORY_PATH", dir.join("query_history.json"));
            std::env::set_var("CDATA_PREFERENCES_PATH", dir.join("preferences.json"));
        }
        preferences::save(&preferences::Preferences::default()).unwrap();
        test(&dir);
        unsafe {
            std::env::remove_var("CDATA_HISTORY_PATH");
            std::env::remove_var("CDATA_QUERY_HISTORY_PATH");
            std::env::remove_var("CDATA_PREFERENCES_PATH");
        }
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn damaged_histories_are_backed_up_and_current_sql_is_collected() {
        with_history_files(|dir| {
            for name in ["history.json", "query_history.json"] {
                for damaged in [
                    br#"[{"sql":"SELECT old","executed_at":1}] trailing"#.as_slice(),
                    b"[{\"sql\":\"unfinished",
                    &[0xff, 0xfe],
                    b"{}",
                    b"[{}]",
                ] {
                    let path = dir.join(name);
                    fs::write(&path, damaged).unwrap();
                    let entries = if name == "history.json" {
                        add_history("SELECT new").unwrap();
                        history().unwrap()
                    } else {
                        add_query_history("SELECT new").unwrap();
                        query_history().unwrap()
                    };
                    assert_eq!(entries.len(), 1);
                    assert_eq!(entries[0].sql, "SELECT new");
                    assert!(
                        fs::read_dir(dir).unwrap().any(|entry| {
                            let p = entry.unwrap().path();
                            p.file_name()
                                .unwrap()
                                .to_string_lossy()
                                .starts_with(&format!("{name}.corrupt-"))
                                && fs::read(p).unwrap() == damaged
                        }),
                        "原始字节必须完整备份"
                    );
                }
            }
        });
    }

    #[test]
    fn backups_are_removed_only_when_corresponding_history_exceeds_limit() {
        with_history_files(|dir| {
            preferences::save(&preferences::Preferences {
                transcript_history_limit: 2,
                query_history_limit: 3,
                ..preferences::Preferences::default()
            })
            .unwrap();
            fs::write(dir.join("history.json"), b"broken transcript").unwrap();
            fs::write(dir.join("query_history.json"), b"broken query").unwrap();
            add_history("SELECT 1").unwrap();
            add_query_history("SELECT query").unwrap();
            add_history("SELECT 2").unwrap();
            add_history("SELECT 2").unwrap(); // 去重不应触发淘汰或删除备份
            let backups = |name: &str| {
                fs::read_dir(dir)
                    .unwrap()
                    .filter(|entry| {
                        entry
                            .as_ref()
                            .unwrap()
                            .file_name()
                            .to_string_lossy()
                            .starts_with(&format!("{name}.corrupt-"))
                    })
                    .count()
            };
            assert_eq!(backups("history.json"), 1);
            let unrelated = dir.join("history.json.corrupt-not-ours.bak");
            fs::write(&unrelated, b"unrelated").unwrap();
            add_history("SELECT 3").unwrap();
            assert_eq!(history().unwrap().len(), 2);
            assert_eq!(backups("history.json"), 1); // 不属于本机制的文件保留
            assert_eq!(fs::read(unrelated).unwrap(), b"unrelated");
            assert_eq!(backups("query_history.json"), 1);
            add_query_history("SELECT q2").unwrap();
            add_query_history("SELECT q3").unwrap();
            assert_eq!(backups("query_history.json"), 1);
            add_query_history("SELECT q4").unwrap();
            assert_eq!(backups("query_history.json"), 0);
            assert_eq!(query_history().unwrap().len(), 3);
        });
    }

    #[test]
    fn valid_files_and_io_errors_do_not_trigger_recovery() {
        with_history_files(|dir| {
            let path = dir.join("history.json");
            fs::write(&path, b"[] \n").unwrap();
            assert!(history().unwrap().is_empty());
            assert_eq!(fs::read_dir(dir).unwrap().count(), 2); // 偏好设置和历史
            fs::remove_file(&path).unwrap();
            fs::create_dir(&path).unwrap();
            assert!(history().is_err());
            assert!(path.is_dir());
            assert_eq!(fs::read_dir(dir).unwrap().count(), 2);
        });
    }

    #[cfg(unix)]
    #[test]
    fn failed_backup_preserves_damaged_history() {
        use std::os::unix::fs::PermissionsExt;
        with_history_files(|dir| {
            let path = dir.join("history.json");
            fs::write(&path, b"broken").unwrap();
            let permissions = fs::metadata(dir).unwrap().permissions();
            fs::set_permissions(dir, fs::Permissions::from_mode(0o500)).unwrap();
            let result = add_history("SELECT new");
            fs::set_permissions(dir, permissions).unwrap();
            assert!(result.unwrap_err().to_string().contains("备份失败"));
            assert_eq!(fs::read(path).unwrap(), b"broken");
        });
    }

    #[test]
    fn concurrent_history_updates_preserve_every_entry() {
        with_history_files(|_| {
            std::thread::scope(|scope| {
                for i in 0..32 {
                    scope.spawn(move || add_history(&format!("SELECT {i}")).unwrap());
                }
            });
            assert_eq!(history().unwrap().len(), 32);
        });
    }

    /// 两个测试都碰环境变量，放一个测试里串行跑
    #[test]
    fn history_and_favorites_round_trip() {
        let _lock = crate::preferences::PREFS_ENV_LOCK.lock().unwrap();
        let dir = std::env::temp_dir().join(format!("cdata-history-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        // SAFETY: 只有这个测试碰这两个变量
        unsafe {
            std::env::set_var("CDATA_HISTORY_PATH", dir.join("history.json"));
            std::env::set_var("CDATA_FAVORITES_PATH", dir.join("favorites.json"));
            std::env::set_var("CDATA_QUERY_HISTORY_PATH", dir.join("query_history.json"));
            std::env::set_var("CDATA_PREFERENCES_PATH", dir.join("preferences.json"));
        }

        preferences::save(&preferences::Preferences::default()).unwrap();

        assert!(history().unwrap().is_empty());
        add_history("SELECT 1").unwrap();
        add_history("  SELECT 2  ").unwrap();
        add_history("SELECT 2").unwrap();
        add_history("   ").unwrap();
        let sqls: Vec<String> = history().unwrap().into_iter().map(|e| e.sql).collect();
        assert_eq!(
            sqls,
            ["SELECT 2", "SELECT 1"],
            "最新的在前，连着重复的只留一条，空的不记"
        );

        for i in 0..505 {
            add_history(&format!("SELECT {i}")).unwrap();
        }
        assert_eq!(
            history().unwrap().len(),
            preferences::load().unwrap().transcript_history_limit as usize
        );

        for i in 0..105 {
            add_query_history(&format!("SELECT query_{i}")).unwrap();
        }
        assert_eq!(query_history().unwrap().len(), 100);
        let saved = std::fs::read_to_string(dir.join("query_history.json")).unwrap();
        preferences::save(&preferences::Preferences {
            save_query_history: false,
            ..preferences::Preferences::default()
        })
        .unwrap();
        assert!(query_history().unwrap().is_empty());
        add_query_history("SELECT session_only").unwrap();
        assert_eq!(query_history().unwrap()[0].sql, "SELECT session_only");
        assert_eq!(
            std::fs::read_to_string(dir.join("query_history.json")).unwrap(),
            saved
        );

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
            std::env::remove_var("CDATA_QUERY_HISTORY_PATH");
            std::env::remove_var("CDATA_PREFERENCES_PATH");
        }
        std::fs::remove_dir_all(&dir).ok();
    }
}
