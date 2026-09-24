//! CData 的 MySQL 核心逻辑。零 UI 依赖，所有行为变更和测试都发生在这里。

pub mod clipboard;
pub mod connections;
pub mod db;
pub mod edit;
pub mod layouts;
pub mod schema;
pub mod session;
pub mod sql;
pub mod value;

pub use value::{cell_from_value, display_text, value_to_mysql, CellValue};
