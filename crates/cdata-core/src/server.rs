//! 服务器状态：进程列表、系统变量、状态计数、慢日志。
//!
//! 这里只在调用方给的连接上跑，取连接和认出「CData 自己的连接」由 session.rs 负责。
//! 值一律经 value.rs 解释成 DisplayCell，界面不解析这里给出的任何文本。

use std::sync::OnceLock;
use std::time::Instant;

use mysql_async::prelude::Queryable;
use mysql_async::{Conn, Value};

use crate::db::{read_result, ResultSet};
use crate::session::{Error, Result};
use crate::value::{cell_from_value, display_cell, CellValue, DisplayCell};

/// 列表最多读多少行。进程、变量、状态正常都是几百行，超了显式标截断
const MAX_ROWS: usize = 10_000;

/// ER_NO_SUCH_THREAD：KILL 的线程不存在
const ER_NO_SUCH_THREAD: u16 = 1094;
/// ER_KILL_DENIED_ERROR：KILL 别的账号的线程但没有权限
const ER_KILL_DENIED: u16 = 1095;

#[derive(Debug, Clone, PartialEq)]
pub struct ProcessInfo {
    pub id: u64,
    pub user: DisplayCell,
    pub host: DisplayCell,
    pub db: DisplayCell,
    pub command: DisplayCell,
    /// 当前状态持续的秒数
    pub time: DisplayCell,
    pub state: DisplayCell,
    /// 正在执行的完整语句，空闲时是 NULL
    pub info: DisplayCell,
    /// CData 自己在用的连接，不许在这里 KILL
    pub is_own: bool,
}

#[derive(Debug, Clone)]
pub struct ProcessList {
    pub processes: Vec<ProcessInfo>,
    pub truncated: bool,
    /// 看不到别的账号的线程时说明原因
    pub notice: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KillMode {
    /// KILL QUERY：只停正在执行的语句，连接保留
    Query,
    /// KILL CONNECTION：断开整条连接，没提交的事务回滚
    Connection,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VariableScope {
    Global,
    Session,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Variable {
    pub name: String,
    pub value: DisplayCell,
}

#[derive(Debug, Clone)]
pub struct VariableList {
    pub variables: Vec<Variable>,
    pub truncated: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct StatusCounter {
    pub name: String,
    pub value: DisplayCell,
    /// 和上次刷新相比的差值，带正负号。第一次刷新、值不是整数时为 None
    pub delta: Option<String>,
    /// 每秒增量。瞬时值（Threads_running 这类）、计数器被重置时为 None
    pub rate: Option<String>,
}

#[derive(Debug, Clone)]
pub struct StatusSnapshot {
    /// 采样时刻，本进程内的单调毫秒数，只用来算下一次的每秒增量
    pub taken_at_ms: u64,
    pub counters: Vec<StatusCounter>,
    pub truncated: bool,
}

#[derive(Debug, Clone)]
pub struct SlowLogConfig {
    pub slow_query_log: DisplayCell,
    pub log_output: DisplayCell,
    pub long_query_time: DisplayCell,
    pub slow_query_log_file: DisplayCell,
    pub enabled: bool,
    /// log_output 不含 TABLE 时说明为什么读不到、日志在哪；含 TABLE 时为 None
    pub table_unavailable: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SlowLogEntry {
    pub start_time: DisplayCell,
    pub user_host: DisplayCell,
    pub query_time: DisplayCell,
    pub lock_time: DisplayCell,
    pub rows_sent: DisplayCell,
    pub rows_examined: DisplayCell,
    pub db: DisplayCell,
    pub sql_text: DisplayCell,
}

#[derive(Debug, Clone)]
pub struct SetVariablePlan {
    pub statement: String,
    pub current_value: DisplayCell,
    pub warnings: Vec<String>,
}

/// 进程列表，带上权限不足的说明。
///
/// 用 SHOW FULL PROCESSLIST 而不是 performance_schema.processlist：后者要 MySQL 8.0.22+ 且
/// performance_schema=ON，MariaDB 和关了 performance_schema 的服务器上没有；两者权限规则一样
/// （没有 PROCESS 只看得到自己账号的线程），FULL 给的是完整语句，不截在 100 个字符。
/// 线程很多时 SHOW PROCESSLIST 要持全局锁，8.0.22+ 可以在服务器上开 performance_schema_show_processlist
/// 让它改走 performance_schema，这里不用改。
pub async fn read_processes(conn: &mut Conn, own_ids: &[u32]) -> Result<ProcessList> {
    let mut list = list_processes(conn, own_ids).await?;

    let probe = read_result(
        conn,
        "SELECT CURRENT_USER(), EXISTS(SELECT 1 FROM information_schema.USER_PRIVILEGES \
         WHERE PRIVILEGE_TYPE IN ('PROCESS', 'SUPER'))",
        Vec::new(),
        1,
    )
    .await?;
    let row = probe.rows.first().ok_or_else(|| Error::Mysql("读不到当前账号".to_string()))?;
    let has_process = matches!(row[1], CellValue::Int(1) | CellValue::UInt(1));
    // CURRENT_USER() 是 user@host，进程列表的 User 列只有 user
    let current_user = match &row[0] {
        CellValue::Text(text) => text.rsplit_once('@').map(|(user, _)| user.to_string()),
        _ => None,
    };

    let mut only_own = true;
    for process in &list.processes {
        if Some(&process.user.text) != current_user.as_ref() {
            only_own = false;
            break;
        }
    }
    // USER_PRIVILEGES 看不到经角色得到的权限，所以还要看列表里是不是真的只有自己的线程
    if !has_process && only_own {
        list.notice = Some(
            "当前账号没有 PROCESS 权限，MySQL 只返回本账号自己的线程，别的账号的连接这里看不到".to_string(),
        );
    }
    Ok(list)
}

async fn list_processes(conn: &mut Conn, own_ids: &[u32]) -> Result<ProcessList> {
    let statement = "SHOW FULL PROCESSLIST";
    let result = read_result(conn, statement, Vec::new(), MAX_ROWS).await?;
    let id = column_index(&result, "Id", statement)?;
    let user = column_index(&result, "User", statement)?;
    let host = column_index(&result, "Host", statement)?;
    let db = column_index(&result, "db", statement)?;
    let command = column_index(&result, "Command", statement)?;
    let time = column_index(&result, "Time", statement)?;
    let state = column_index(&result, "State", statement)?;
    let info = column_index(&result, "Info", statement)?;

    let mut processes = Vec::with_capacity(result.rows.len());
    for row in &result.rows {
        let thread_id = match row[id] {
            CellValue::UInt(value) => value,
            CellValue::Int(value) if value >= 0 => value as u64,
            ref other => return Err(Error::Mysql(format!("进程列表的 Id 不是整数：{other:?}"))),
        };
        processes.push(ProcessInfo {
            id: thread_id,
            user: display_cell(&row[user]),
            host: display_cell(&row[host]),
            db: display_cell(&row[db]),
            command: display_cell(&row[command]),
            time: display_cell(&row[time]),
            state: display_cell(&row[state]),
            info: display_cell(&row[info]),
            is_own: own_ids.iter().any(|own| u64::from(*own) == thread_id),
        });
    }
    Ok(ProcessList { processes, truncated: result.truncated, notice: None })
}

/// KILL 一个线程。
///
/// 拦三种情况：CData 自己的连接；线程已经不在；和用户确认时看到的不是同一个
/// （账号、来源变了，或者 KILL QUERY 时它已经在跑另一条语句）—— 进程列表是几秒前的快照，
/// 按旧快照 KILL QUERY 可能停掉一条用户根本没看到的语句
pub async fn kill(conn: &mut Conn, target: &ProcessInfo, mode: KillMode, own_ids: &[u32]) -> Result<()> {
    if own_ids.iter().any(|own| u64::from(*own) == target.id) {
        return Err(Error::BadInput(format!(
            "线程 {} 是 CData 自己正在用的连接，不能在这里 KILL：会打断本工具的查询，或让连接池里的连接失效",
            target.id
        )));
    }

    let current = list_processes(conn, own_ids).await?;
    let Some(now) = current.processes.iter().find(|process| process.id == target.id) else {
        return Err(Error::BadInput(format!("线程 {} 已经不在进程列表里（可能已经结束），没有 KILL", target.id)));
    };
    if now.user != target.user || now.host != target.host {
        return Err(Error::BadInput(format!(
            "线程 {} 的账号或来源和确认时不一样了，没有 KILL，请刷新后重新确认",
            target.id
        )));
    }
    if mode == KillMode::Query && now.info != target.info {
        return Err(Error::BadInput(format!(
            "线程 {} 现在执行的语句和确认时不一样了，没有 KILL，请刷新后重新确认",
            target.id
        )));
    }

    conn.query_drop(kill_sql(target.id, mode)).await.map_err(|err| match err {
        mysql_async::Error::Server(ref server) if server.code == ER_KILL_DENIED => Error::Mysql(format!(
            "{}。KILL 别的账号的线程需要 CONNECTION_ADMIN（或 SUPER）权限",
            server.message
        )),
        mysql_async::Error::Server(ref server) if server.code == ER_NO_SUCH_THREAD => {
            Error::BadInput(format!("线程 {} 已经结束了", target.id))
        }
        other => Error::from(other),
    })
}

/// id 是整数，直接写进语句没有注入的余地
pub fn kill_sql(thread_id: u64, mode: KillMode) -> String {
    match mode {
        KillMode::Query => format!("KILL QUERY {thread_id}"),
        KillMode::Connection => format!("KILL CONNECTION {thread_id}"),
    }
}

pub async fn read_variables(conn: &mut Conn, scope: VariableScope) -> Result<VariableList> {
    let statement = match scope {
        VariableScope::Global => "SHOW GLOBAL VARIABLES",
        VariableScope::Session => "SHOW SESSION VARIABLES",
    };
    let result = read_result(conn, statement, Vec::new(), MAX_ROWS).await?;
    Ok(VariableList { variables: name_values(&result, statement)?, truncated: result.truncated })
}

/// SHOW GLOBAL STATUS，和上一次的快照比出差值和每秒增量
pub async fn read_status(conn: &mut Conn, previous: Option<&StatusSnapshot>) -> Result<StatusSnapshot> {
    let statement = "SHOW GLOBAL STATUS";
    let result = read_result(conn, statement, Vec::new(), MAX_ROWS).await?;
    let taken_at_ms = now_ms();
    let values = name_values(&result, statement)?;
    Ok(StatusSnapshot {
        taken_at_ms,
        counters: compare_status(previous, values, taken_at_ms),
        truncated: result.truncated,
    })
}

fn now_ms() -> u64 {
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_millis() as u64
}

/// 按名字对上一次的值算差值。每秒增量只给累计计数器
pub fn compare_status(
    previous: Option<&StatusSnapshot>,
    current: Vec<Variable>,
    taken_at_ms: u64,
) -> Vec<StatusCounter> {
    let mut before = std::collections::HashMap::new();
    let mut elapsed_ms = 0;
    if let Some(previous) = previous {
        elapsed_ms = taken_at_ms.saturating_sub(previous.taken_at_ms);
        for counter in &previous.counters {
            if let Some(number) = counter_number(&counter.value) {
                before.insert(counter.name.as_str(), number);
            }
        }
    }

    let mut counters = Vec::with_capacity(current.len());
    for variable in current {
        let mut delta = None;
        let mut rate = None;
        if let (Some(now), Some(then)) = (counter_number(&variable.value), before.get(variable.name.as_str())) {
            let diff = now - then;
            delta = Some(if diff > 0 { format!("+{diff}") } else { diff.to_string() });
            // 计数器变小说明被 FLUSH STATUS 重置过，算不出每秒
            if diff >= 0 && elapsed_ms > 0 && !is_gauge(&variable.name) {
                rate = Some(format!("{:.1}/s", diff as f64 * 1000.0 / elapsed_ms as f64));
            }
        }
        counters.push(StatusCounter { name: variable.name, value: variable.value, delta, rate });
    }
    counters
}

/// 状态值是不是非负整数。别的（ON、版本号、小数）不算差值
fn counter_number(value: &DisplayCell) -> Option<i128> {
    if value.placeholder || value.text.is_empty() || !value.text.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    value.text.parse().ok()
}

/// 瞬时值而不是累计计数器：差值有意义，每秒没有意义。
// ponytail: 按前缀列了常见的几类，没列全；漏掉的瞬时值会多显示一个没意义的每秒增量
fn is_gauge(name: &str) -> bool {
    const PREFIXES: [&str; 12] = [
        "Threads_",
        "Open_",
        "Uptime",
        "Max_used_connections",
        "Innodb_buffer_pool_pages_",
        "Innodb_buffer_pool_bytes_",
        "Innodb_row_lock_current_waits",
        "Innodb_row_lock_time_avg",
        "Innodb_row_lock_time_max",
        "Innodb_page_size",
        "Innodb_num_open_files",
        "Current_tls_",
    ];
    PREFIXES.iter().any(|prefix| name.starts_with(prefix))
}

const SLOW_LOG_STATEMENT: &str = "SHOW GLOBAL VARIABLES WHERE Variable_name IN \
     ('slow_query_log', 'log_output', 'long_query_time', 'slow_query_log_file')";

pub async fn slow_log_config(conn: &mut Conn) -> Result<SlowLogConfig> {
    let result = read_result(conn, SLOW_LOG_STATEMENT, Vec::new(), 10).await?;
    let variables = name_values(&result, SLOW_LOG_STATEMENT)?;
    slow_log_config_from(&variables)
}

pub fn slow_log_config_from(variables: &[Variable]) -> Result<SlowLogConfig> {
    let find = |name: &str| {
        variables
            .iter()
            .find(|variable| variable.name == name)
            .map(|variable| variable.value.clone())
            .ok_or_else(|| Error::Mysql(format!("服务器没有返回变量 {name}")))
    };
    let slow_query_log = find("slow_query_log")?;
    let log_output = find("log_output")?;
    let long_query_time = find("long_query_time")?;
    let slow_query_log_file = find("slow_query_log_file")?;

    let enabled = !slow_query_log.placeholder && slow_query_log.text.eq_ignore_ascii_case("ON");
    let mut to_table = false;
    let mut to_file = false;
    if !log_output.placeholder {
        for output in log_output.text.split(',') {
            to_table |= output.trim().eq_ignore_ascii_case("TABLE");
            to_file |= output.trim().eq_ignore_ascii_case("FILE");
        }
    }
    let table_unavailable = if to_table {
        None
    } else if to_file {
        Some(format!(
            "log_output = {}：慢日志写在服务器上的文件 {} 里。CData 是客户端，读不到服务器上的文件\
             （走 SSH 隧道也一样，隧道只转发 MySQL 端口），请登录服务器查看。\
             想在这里看，要把 log_output 改成包含 TABLE（例如 FILE,TABLE），之后的慢查询才会写进 mysql.slow_log",
            log_output.text, slow_query_log_file.text
        ))
    } else {
        Some(format!("log_output = {}：慢日志不写到任何地方", log_output.text))
    };

    Ok(SlowLogConfig { slow_query_log, log_output, long_query_time, slow_query_log_file, enabled, table_unavailable })
}

/// 从 mysql.slow_log 读最近 limit 条。log_output 不含 TABLE 时拒绝并说明日志在哪
pub async fn read_slow_log(conn: &mut Conn, limit: u32) -> Result<Vec<SlowLogEntry>> {
    let config = slow_log_config(conn).await?;
    if let Some(reason) = config.table_unavailable {
        return Err(Error::BadInput(reason));
    }

    let result = read_result(
        conn,
        "SELECT start_time, user_host, query_time, lock_time, rows_sent, rows_examined, db, sql_text \
         FROM mysql.slow_log ORDER BY start_time DESC LIMIT ?",
        vec![Value::UInt(u64::from(limit))],
        limit as usize,
    )
    .await?;

    let mut entries = Vec::with_capacity(result.rows.len());
    for row in result.rows {
        // sql_text 是 MEDIUMBLOB，列元数据是二进制，但这一列存的就是客户端发来的语句原文。
        // 按 UTF-8 严格解码：解不了走 InvalidText 显式标出，不替换字符，也不去猜别的编码
        let sql_text = match &row[7] {
            CellValue::Bytes(bytes) => cell_from_value(Value::Bytes(bytes.clone()), false),
            other => other.clone(),
        };
        entries.push(SlowLogEntry {
            start_time: display_cell(&row[0]),
            user_host: display_cell(&row[1]),
            query_time: display_cell(&row[2]),
            lock_time: display_cell(&row[3]),
            rows_sent: display_cell(&row[4]),
            rows_examined: display_cell(&row[5]),
            db: display_cell(&row[6]),
            sql_text: display_cell(&sql_text),
        });
    }
    Ok(entries)
}

/// 生成 SET 语句。
///
/// 纯数字（整数或小数）不加引号：数值型变量收到字符串会报 1232 Incorrect argument type。
/// 其余一律按字符串字面量，ON / OFF、枚举值、路径都这样传。
// ponytail: 字符串型变量要设成纯数字（比如 init_connect='1'）会被当成数字发出去、被服务器拒绝；
// 真遇到再加一个「按字符串」的开关
pub fn build_set_variable(
    scope: VariableScope,
    name: &str,
    value: &str,
    no_backslash_escapes: bool,
) -> std::result::Result<String, String> {
    if !is_variable_name(name) {
        return Err(format!("变量名 {name} 不合法：只能是字母、数字、下划线，组件变量可以带一个点"));
    }
    let keyword = match scope {
        VariableScope::Global => "GLOBAL",
        VariableScope::Session => "SESSION",
    };
    let literal = if is_plain_number(value) {
        value.to_string()
    } else {
        crate::alter::sql_string(value, no_backslash_escapes)
    };
    Ok(format!("SET {keyword} {name} = {literal}"))
}

fn is_variable_name(name: &str) -> bool {
    let mut parts = name.split('.');
    let (Some(first), second, None) = (parts.next(), parts.next(), parts.next()) else {
        return false;
    };
    let valid = |part: &str| {
        !part.is_empty()
            && !part.starts_with(|c: char| c.is_ascii_digit())
            && part.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
    };
    valid(first) && second.is_none_or(valid)
}

fn is_plain_number(value: &str) -> bool {
    let unsigned = value.strip_prefix('-').unwrap_or(value);
    let (whole, fraction) = match unsigned.split_once('.') {
        Some((whole, fraction)) => (whole, Some(fraction)),
        None => (unsigned, None),
    };
    let digits = |part: &str| !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit());
    digits(whole) && fraction.is_none_or(digits)
}

/// 预览 SET GLOBAL：生成的语句、现在的值、影响范围
pub async fn plan_set_global(conn: &mut Conn, name: &str, value: &str) -> Result<SetVariablePlan> {
    let current_value = global_value(conn, name).await?;
    let statement = set_global_on(conn, name, value).await?;
    Ok(SetVariablePlan {
        statement,
        current_value,
        warnings: vec![
            "改的是服务器的全局值：之后新建的连接都用新值，已经连着的连接会话值不变；\
             只有全局值的变量（比如 max_connections、slow_query_log）立即对所有连接生效"
                .to_string(),
            "只改运行中的服务器，重启后恢复成配置文件里的值；要持久化得用 SET PERSIST 或改 my.cnf，这里不提供"
                .to_string(),
            "需要 SYSTEM_VARIABLES_ADMIN（或 SUPER）权限".to_string(),
        ],
    })
}

/// 执行预览过的 SET GLOBAL，返回服务器实际存下的新值。
/// 在执行的这条连接上按它的 sql_mode 重新生成，和预览时的语句不一致就不执行
pub async fn apply_set_global(conn: &mut Conn, name: &str, value: &str, previewed: &str) -> Result<DisplayCell> {
    let statement = set_global_on(conn, name, value).await?;
    if statement != previewed {
        return Err(Error::BadInput("要执行的语句和预览时不一样了（sql_mode 变了），请重新预览".to_string()));
    }
    conn.query_drop(&statement).await?;
    global_value(conn, name).await
}

async fn set_global_on(conn: &mut Conn, name: &str, value: &str) -> Result<String> {
    let sql_mode: String = conn.query_first("SELECT @@SESSION.sql_mode").await?.unwrap_or_default();
    let no_backslash_escapes = sql_mode.split(',').any(|mode| mode == "NO_BACKSLASH_ESCAPES");
    build_set_variable(VariableScope::Global, name, value, no_backslash_escapes).map_err(Error::BadInput)
}

/// 用 = 而不是 LIKE 找：LIKE 里的 _ 是通配符，会匹配到别的变量
async fn global_value(conn: &mut Conn, name: &str) -> Result<DisplayCell> {
    let statement = "SHOW GLOBAL VARIABLES WHERE Variable_name = ?";
    let result = read_result(conn, statement, vec![Value::from(name)], 2).await?;
    let variables = name_values(&result, statement)?;
    match variables.into_iter().next() {
        Some(variable) => Ok(variable.value),
        None => Err(Error::BadInput(format!("服务器上没有全局变量 {name}（只有会话级的变量不能 SET GLOBAL）"))),
    }
}

/// SHOW VARIABLES / STATUS 的两列。名字必须是文本，不是的话报错而不是拿占位当名字
fn name_values(result: &ResultSet, statement: &str) -> Result<Vec<Variable>> {
    let name = column_index(result, "Variable_name", statement)?;
    let value = column_index(result, "Value", statement)?;
    let mut variables = Vec::with_capacity(result.rows.len());
    for row in &result.rows {
        let CellValue::Text(variable_name) = &row[name] else {
            return Err(Error::Mysql(format!("{statement} 返回的变量名不是文本：{:?}", row[name])));
        };
        variables.push(Variable { name: variable_name.clone(), value: display_cell(&row[value]) });
    }
    Ok(variables)
}

fn column_index(result: &ResultSet, name: &str, statement: &str) -> Result<usize> {
    result
        .columns
        .iter()
        .position(|column| column.name.eq_ignore_ascii_case(name))
        .ok_or_else(|| Error::Mysql(format!("{statement} 没有返回 {name} 列")))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(value: &str) -> DisplayCell {
        DisplayCell { text: value.to_string(), placeholder: false }
    }

    fn variable(name: &str, value: &str) -> Variable {
        Variable { name: name.to_string(), value: text(value) }
    }

    #[test]
    fn numbers_go_bare_and_everything_else_is_quoted() {
        let global = |value| build_set_variable(VariableScope::Global, "long_query_time", value, false).unwrap();
        assert_eq!(global("2"), "SET GLOBAL long_query_time = 2");
        assert_eq!(global("0.5"), "SET GLOBAL long_query_time = 0.5");
        assert_eq!(global("-1"), "SET GLOBAL long_query_time = -1");
        assert_eq!(global("ON"), "SET GLOBAL long_query_time = 'ON'");
        assert_eq!(global("1e3"), "SET GLOBAL long_query_time = '1e3'");
        assert_eq!(global("1."), "SET GLOBAL long_query_time = '1.'");
        assert_eq!(global(""), "SET GLOBAL long_query_time = ''");
        assert_eq!(global("2; DROP TABLE t"), "SET GLOBAL long_query_time = '2; DROP TABLE t'");
    }

    #[test]
    fn string_values_follow_no_backslash_escapes() {
        let with = build_set_variable(VariableScope::Session, "init_connect", r"it's C:\x", false).unwrap();
        assert_eq!(with, r"SET SESSION init_connect = 'it''s C:\\x'");
        let without = build_set_variable(VariableScope::Session, "init_connect", r"it's C:\x", true).unwrap();
        assert_eq!(without, r"SET SESSION init_connect = 'it''s C:\x'");
    }

    #[test]
    fn variable_names_are_validated_not_quoted() {
        assert!(build_set_variable(VariableScope::Global, "validate_password.length", "8", false).is_ok());
        for bad in ["", "a b", "x=1;", "`x`", "a.b.c", ".a", "1abc", "max_connections--"] {
            assert!(build_set_variable(VariableScope::Global, bad, "1", false).is_err(), "{bad}");
        }
    }

    #[test]
    fn kill_statements() {
        assert_eq!(kill_sql(42, KillMode::Query), "KILL QUERY 42");
        assert_eq!(kill_sql(42, KillMode::Connection), "KILL CONNECTION 42");
    }

    #[test]
    fn status_deltas_and_rates() {
        let first = StatusSnapshot {
            taken_at_ms: 1_000,
            counters: compare_status(
                None,
                vec![
                    variable("Questions", "100"),
                    variable("Threads_running", "5"),
                    variable("Ssl_version", ""),
                    variable("Com_select", "50"),
                ],
                1_000,
            ),
            truncated: false,
        };
        assert!(first.counters.iter().all(|counter| counter.delta.is_none() && counter.rate.is_none()));

        let second = compare_status(
            Some(&first),
            vec![
                variable("Questions", "120"),
                variable("Threads_running", "3"),
                variable("Ssl_version", ""),
                variable("Com_select", "10"),
                variable("Bytes_sent", "7"),
            ],
            3_000,
        );
        assert_eq!(second[0].delta.as_deref(), Some("+20"));
        assert_eq!(second[0].rate.as_deref(), Some("10.0/s"));
        assert_eq!(second[1].delta.as_deref(), Some("-2"), "瞬时值有差值");
        assert_eq!(second[1].rate, None, "瞬时值没有每秒");
        assert_eq!(second[2].delta, None, "不是数字不算");
        assert_eq!(second[3].delta.as_deref(), Some("-40"));
        assert_eq!(second[3].rate, None, "计数器被重置过，算不出每秒");
        assert_eq!(second[4].delta, None, "上次没有的不算");
    }

    #[test]
    fn placeholders_are_not_numbers() {
        let null = DisplayCell { text: "NULL".to_string(), placeholder: true };
        assert_eq!(counter_number(&null), None);
        assert_eq!(counter_number(&text("18446744073709551615")), Some(18446744073709551615));
    }

    fn slow_config(output: &str) -> SlowLogConfig {
        slow_log_config_from(&[
            variable("slow_query_log", "ON"),
            variable("log_output", output),
            variable("long_query_time", "10.000000"),
            variable("slow_query_log_file", "/var/lib/mysql/host-slow.log"),
        ])
        .unwrap()
    }

    #[test]
    fn slow_log_file_only_says_where_it_is() {
        let file = slow_config("FILE");
        assert!(file.enabled);
        let reason = file.table_unavailable.unwrap();
        assert!(reason.contains("/var/lib/mysql/host-slow.log"), "{reason}");
        assert!(reason.contains("读不到服务器上的文件"), "{reason}");

        assert!(slow_config("FILE,TABLE").table_unavailable.is_none());
        assert!(slow_config("TABLE").table_unavailable.is_none());
        assert!(slow_config("NONE").table_unavailable.unwrap().contains("不写到任何地方"));
    }

    #[test]
    fn slow_log_config_refuses_missing_variables() {
        let result = slow_log_config_from(&[variable("slow_query_log", "OFF")]);
        assert!(result.is_err());
    }
}
