//! CData 的 MySQL 核心逻辑。零 UI 依赖，所有行为变更和测试都发生在这里。

pub mod alter;
pub mod clipboard;
pub mod complete;
pub mod connections;
pub mod db;
pub mod edit;
pub mod export;
pub mod history;
pub mod import;
pub mod layouts;
pub mod lexer;
pub mod options;
pub mod preferences;
pub mod schema;
pub mod script;
pub mod server;
pub mod session;
pub mod sql;
pub mod ssh;
pub mod structure;
pub mod users;
pub mod value;

pub use value::{cell_from_value, display_text, value_to_mysql, CellValue};
