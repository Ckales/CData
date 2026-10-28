//! SQL 操作日志的只读接口，存储和保留规则都在 core。

use crate::api::db::Result;
use crate::api::value::OperationLogEntry;

pub fn list_operation_logs() -> Result<Vec<OperationLogEntry>> {
    cdata_core::operation_log::list().map_err(|error| error.to_string())
}
