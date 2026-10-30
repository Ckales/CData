//! 导入 / 导出进行中的进度。界面轮询，不走流。
//! 一个会话同时只跑一个文件操作（对话框是模态的），所以按会话各占一格。

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileProgress {
    pub done: u64,
    /// 0 表示还不知道总数：导入还在读文件，或导出的是整张表（不先 COUNT）
    pub total: u64,
}

fn slots() -> &'static Mutex<HashMap<u64, FileProgress>> {
    static SLOTS: OnceLock<Mutex<HashMap<u64, FileProgress>>> = OnceLock::new();
    SLOTS.get_or_init(|| Mutex::new(HashMap::new()))
}

pub fn reset_file_progress(session_id: u64) {
    slots()
        .lock()
        .unwrap()
        .insert(session_id, FileProgress::default());
}

pub fn set_file_progress(session_id: u64, done: u64, total: u64) {
    slots()
        .lock()
        .unwrap()
        .insert(session_id, FileProgress { done, total });
}

pub fn file_progress(session_id: u64) -> FileProgress {
    slots()
        .lock()
        .unwrap()
        .get(&session_id)
        .copied()
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sessions_do_not_share_a_slot() {
        // 用不会和别的测试撞上的 id
        let a = u64::MAX - 1;
        let b = u64::MAX - 2;
        reset_file_progress(a);
        reset_file_progress(b);
        set_file_progress(a, 3, 10);
        set_file_progress(b, 1, 4);
        assert_eq!(file_progress(a), FileProgress { done: 3, total: 10 });
        assert_eq!(file_progress(b), FileProgress { done: 1, total: 4 });
        assert_eq!(file_progress(u64::MAX - 3), FileProgress::default());
    }
}
