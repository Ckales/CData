//! 用户侧 SQL 操作记录。按偏好设置保留最近若干条完整日志。

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::connections::{Error, Result};

pub const MAX_ENTRIES: usize = crate::preferences::MAX_OPERATION_LOG_LIMIT as usize;

static LOG_LOCK: Mutex<()> = Mutex::new(());
static PENDING_STORAGE_ERROR: Mutex<Option<String>> = Mutex::new(None);
static TEMP_FILE_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OperationLogEntry {
    pub session_id: u64,
    pub operation: String,
    pub detail: String,
    pub succeeded: bool,
    pub message: String,
    /// Unix 毫秒。
    pub executed_at: i64,
    pub elapsed_ms: u64,
}

fn log_path() -> Result<PathBuf> {
    crate::history::data_file("CDATA_OPERATION_LOG_PATH", "operation_log.json")
}

fn normalize_entries(entries: &mut Vec<OperationLogEntry>, limit: usize) {
    // `sort_by` is stable, so newly inserted equal-timestamp entries stay first.
    entries.sort_by(|left, right| right.executed_at.cmp(&left.executed_at));
    entries.truncate(limit);
}

fn read_entries(path: &Path) -> Result<Vec<OperationLogEntry>> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let text = fs::read_to_string(path).map_err(|error| Error::Io(error.to_string()))?;
    serde_json::from_str(&text).map_err(|error| Error::Parse(error.to_string()))
}

fn write_entries_atomic(path: &Path, entries: &[OperationLogEntry]) -> Result<()> {
    write_entries_atomic_with(path, entries, |from, to| fs::rename(from, to))
}

fn write_entries_atomic_with(
    path: &Path,
    entries: &[OperationLogEntry],
    replace: impl FnOnce(&Path, &Path) -> std::io::Result<()>,
) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| Error::Io("操作日志路径没有父目录".into()))?;
    fs::create_dir_all(parent).map_err(|error| Error::Io(error.to_string()))?;
    let contents =
        serde_json::to_vec_pretty(entries).map_err(|error| Error::Parse(error.to_string()))?;

    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("operation_log.json");
    let (temp_path, mut temp_file) = loop {
        let sequence = TEMP_FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let temp_path = parent.join(format!(
            ".{file_name}.{}.{}.tmp",
            std::process::id(),
            sequence
        ));
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp_path)
        {
            Ok(file) => break (temp_path, file),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(Error::Io(error.to_string())),
        }
    };

    let write_result = temp_file
        .write_all(&contents)
        .and_then(|()| temp_file.sync_all());
    drop(temp_file);
    if let Err(error) = write_result {
        let _ = fs::remove_file(&temp_path);
        return Err(Error::Io(error.to_string()));
    }

    if let Err(error) = replace(&temp_path, path) {
        let _ = fs::remove_file(&temp_path);
        return Err(Error::Io(error.to_string()));
    }
    Ok(())
}

/// 返回日志，最新记录在前，按偏好设置的条数裁剪。
pub fn list() -> Result<Vec<OperationLogEntry>> {
    let _guard = LOG_LOCK.lock().unwrap();
    if let Some(message) = PENDING_STORAGE_ERROR.lock().unwrap().take() {
        return Err(Error::Io(message));
    }

    let path = match log_path() {
        Ok(path) => path,
        Err(error) => return remember_error(error),
    };
    let mut entries = match read_entries(&path) {
        Ok(entries) => entries,
        Err(error) => return remember_error(error),
    };
    let limit = crate::preferences::load()?.operation_log_limit as usize;
    let original = entries.clone();
    normalize_entries(&mut entries, limit);
    if entries != original {
        if let Err(error) = write_entries_atomic(&path, &entries) {
            return remember_error(error);
        }
    }
    Ok(entries)
}

/// 保存一条记录，并裁掉超出上限的旧记录。
pub fn record(entry: OperationLogEntry) -> Result<()> {
    let _guard = LOG_LOCK.lock().unwrap();
    let path = match log_path() {
        Ok(path) => path,
        Err(error) => return remember_error(error),
    };
    let limit = match crate::preferences::load() {
        Ok(preferences) => preferences.operation_log_limit as usize,
        Err(error) => return remember_error(error),
    };
    match append_entry(&path, entry, limit) {
        Ok(()) => Ok(()),
        Err(error) => remember_error(error),
    }
}

fn append_entry(path: &Path, entry: OperationLogEntry, limit: usize) -> Result<()> {
    let mut entries = read_entries(path)?;
    entries.insert(0, entry);
    normalize_entries(&mut entries, limit);
    write_entries_atomic(path, &entries)
}

fn remember_error<T>(error: Error) -> Result<T> {
    *PENDING_STORAGE_ERROR.lock().unwrap() = Some(error.to_string());
    Err(error)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(id: u64, executed_at: i64) -> OperationLogEntry {
        OperationLogEntry {
            session_id: id,
            operation: "edit_cell".into(),
            detail: format!("row={id}"),
            succeeded: true,
            message: "完成".into(),
            executed_at,
            elapsed_ms: 3,
        }
    }

    #[test]
    fn newest_first_and_count_limit() {
        let now = 2_000_000_000_000;
        let mut entries = vec![
            entry(1, now - 500),
            entry(2, now - 50),
            entry(3, now - 300),
            entry(4, now - 20),
        ];

        normalize_entries(&mut entries, MAX_ENTRIES);
        assert_eq!(
            entries
                .iter()
                .map(|item| item.session_id)
                .collect::<Vec<_>>(),
            [4, 2, 3, 1]
        );

        let mut too_many: Vec<_> = (0..(MAX_ENTRIES + 1))
            .map(|index| entry(index as u64, now - index as i64))
            .collect();
        normalize_entries(&mut too_many, MAX_ENTRIES);
        assert_eq!(too_many.len(), MAX_ENTRIES);
        assert_eq!(too_many[0].session_id, 0);
        assert_eq!(
            too_many[MAX_ENTRIES - 1].session_id,
            (MAX_ENTRIES - 1) as u64
        );
    }

    #[test]
    fn persisted_round_trip_uses_json_file() {
        let directory = std::env::temp_dir().join(format!(
            "cdata-operation-log-{}-{}",
            std::process::id(),
            TEMP_FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        let path = directory.join("operation_log.json");
        let expected = vec![entry(42, 1_900_000_000_000)];

        write_entries_atomic(&path, &expected).unwrap();
        assert_eq!(read_entries(&path).unwrap(), expected);

        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn appending_respects_configured_retention_limit() {
        let directory = std::env::temp_dir().join(format!(
            "cdata-operation-log-append-{}-{}",
            std::process::id(),
            TEMP_FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        let path = directory.join("operation_log.json");
        let older = entry(1, 100);
        let newer = entry(2, 200);

        append_entry(&path, older.clone(), 1).unwrap();
        append_entry(&path, newer.clone(), 1).unwrap();

        assert_eq!(read_entries(&path).unwrap(), [newer]);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn failed_atomic_replace_preserves_existing_file() {
        let directory = std::env::temp_dir().join(format!(
            "cdata-operation-log-failed-replace-{}-{}",
            std::process::id(),
            TEMP_FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        let path = directory.join("operation_log.json");
        let old_entries = vec![entry(1, 100)];
        write_entries_atomic(&path, &old_entries).unwrap();

        let error = write_entries_atomic_with(&path, &[entry(2, 200)], |_, _| {
            Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "simulated replace failure",
            ))
        });

        assert!(matches!(error, Err(Error::Io(_))));
        assert_eq!(read_entries(&path).unwrap(), old_entries);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn malformed_persisted_json_is_reported() {
        let directory = std::env::temp_dir().join(format!(
            "cdata-operation-log-invalid-{}-{}",
            std::process::id(),
            TEMP_FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&directory).unwrap();
        let path = directory.join("operation_log.json");
        fs::write(&path, "{").unwrap();

        assert!(matches!(read_entries(&path), Err(Error::Parse(_))));

        fs::remove_dir_all(directory).unwrap();
    }
}
