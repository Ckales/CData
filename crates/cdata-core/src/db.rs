//! MySQL 连接与查询执行。
//!
//! 值的解释全部委托给 value.rs，这里只负责把连接建起来、把行取回来、把列元数据带上。

use std::sync::Arc;
use std::time::Duration;

use mysql_async::consts::{ColumnFlags, ColumnType};
use mysql_async::prelude::*;
use mysql_async::{ClientIdentity, Column, Conn, Opts, OptsBuilder, Pool, SslOpts, Value};
use serde::{Deserialize, Serialize};

use crate::options::{ConnectionOptions, SshAuth, SslMode, SslOptions};
use crate::ssh::Tunnel;
use crate::value::{cell_from_value, CellValue};

/// binary collation 的 id
const BINARY_COLLATION_ID: u16 = 63;

/// ER_QUERY_INTERRUPTED：语句被 KILL QUERY 打断
const ER_QUERY_INTERRUPTED: u16 = 1317;

/// 超时后发了 KILL QUERY，再等原连接这么久确认语句停下来
const KILL_GRACE: Duration = Duration::from_secs(5);

/// 可以直接连的配置，带着密码，只在内存里用。
/// 不实现 Serialize，Debug 手写并隐去密码：免得哪天被顺手打进日志或写进文件
#[derive(Clone)]
pub struct ConnectionConfig {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
    pub database: Option<String>,
    pub options: ConnectionOptions,
    /// 每一跳 SSH 的密码或私钥口令，和 `options.ssh.hops` 一一对应；为空表示一份都没给。
    /// 只在内存里，不落盘。没给的那一跳，如果有 saved_id 就去钥匙串里取
    pub ssh_secrets: Vec<Option<String>>,
    /// 来自哪条保存的连接。只用来在钥匙串里找 SSH 密码 / 口令，临时连接为 None
    pub saved_id: Option<String>,
}

impl std::fmt::Debug for ConnectionConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ConnectionConfig")
            .field("host", &self.host)
            .field("port", &self.port)
            .field("user", &self.user)
            .field("password", &"<隐去>")
            .field("database", &self.database)
            .field("options", &self.options)
            .field("ssh_secrets", &format!("<{} 份，隐去>", self.ssh_secrets.len()))
            .field("saved_id", &self.saved_id)
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ColumnMeta {
    /// 显示名。`SELECT id AS uid` 时是 uid
    pub name: String,
    /// 原始列名。写 UPDATE 要用这个，别名写进 SQL 会报错
    pub org_name: String,
    /// 原始表名。空串表示这列不是直接来自某张表（表达式、聚合、常量）
    pub org_table: String,
    /// 列所属的库
    pub schema: String,
    /// 二进制列，值按字节处理，不尝试解码成文本
    pub is_binary: bool,
    /// 这一列用什么编辑器。只由列元数据决定，不看值
    pub kind: ColumnKind,
    /// 列定义里的小数位：时间类型是小数秒位数，DECIMAL 是标度；超过 6（通常是 31）表示不固定。
    /// TIME 编辑器靠它判断输入的小数秒会不会被 MySQL 舍入
    pub decimals: u8,
}

/// 列的类别，界面按它选编辑器
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ColumnKind {
    Text,
    Number,
    Json,
    Date,
    DateTime,
    Time,
    Enum,
    Set,
    /// BLOB、BINARY、BIT、GEOMETRY 等按字节处理的列
    Binary,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResultSet {
    pub columns: Vec<ColumnMeta>,
    pub rows: Vec<Vec<CellValue>>,
    /// 达到 max_rows 被截断。界面必须显式提示，不能静默丢数据
    pub truncated: bool,
    /// INSERT / UPDATE / DELETE 等影响的行数。截断时没读到结尾，是 0
    pub affected_rows: u64,
}

/// 连接池加上它的超时设置和 SSH 隧道。
///
/// 所有取连接都走 `get_conn`，连接超时才能对每一个入口都生效；
/// 隧道跟着池走，池还在隧道就在
#[derive(Clone)]
pub struct DbPool {
    pool: Pool,
    connect_timeout: Option<Duration>,
    query_timeout: Option<Duration>,
    tunnel: Option<Arc<Tunnel>>,
    /// 这个池取出过的连接的线程 id。服务器状态页据此认出 CData 自己的连接，不让用户 KILL 掉
    connection_ids: Arc<std::sync::Mutex<std::collections::HashSet<u32>>>,
}

#[derive(Debug)]
pub enum OpenError {
    BadOptions(String),
    Ssh(crate::ssh::Error),
}

impl std::fmt::Display for OpenError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            OpenError::BadOptions(message) => write!(f, "{message}"),
            OpenError::Ssh(err) => write!(f, "{err}"),
        }
    }
}

impl std::error::Error for OpenError {}

/// 取连接阶段就失败了：语句还没发出去，肯定没有执行
#[derive(Debug)]
pub struct ConnectFailed(pub String);

impl std::fmt::Display for ConnectFailed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "连不上服务器：{}", self.0)
    }
}

impl std::error::Error for ConnectFailed {}

/// 查询超过时限
#[derive(Debug)]
pub struct QueryTimedOut {
    pub seconds: u64,
    /// 发出 KILL QUERY 后，原连接在宽限期内确认语句已经停下
    pub confirmed_stopped: bool,
    /// KILL QUERY 本身没发成功的原因
    pub kill_error: Option<String>,
}

impl std::fmt::Display for QueryTimedOut {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "查询超过 {} 秒，", self.seconds)?;
        if let Some(reason) = &self.kill_error {
            return write!(
                f,
                "而且没能让服务器停止这条语句（{reason}），它可能还在服务器上执行，请到进程列表里确认"
            );
        }
        if self.confirmed_stopped {
            write!(f, "已让服务器停止这条语句（KILL QUERY）")?;
        } else {
            write!(f, "已发出 KILL QUERY，但没等到服务器确认停止，原连接已丢弃")?;
        }
        // KILL 之前刚好执行完的写操作已经生效，被打断的会回滚 —— 从客户端分辨不出是哪一种
        write!(f, "。如果是写操作，它可能已经执行完，也可能被回滚了，请确认后再决定是否重跑")
    }
}

impl std::error::Error for QueryTimedOut {}

/// 把 SSL 选项翻译成 mysql_async 的设置。Disabled 返回 None。
///
/// tls_host 是校验证书用的主机名：走 SSH 隧道时实际连的是 127.0.0.1，
/// 但证书上写的是 MySQL 服务器自己的名字，要按用户填的主机名校验
fn build_ssl_opts(ssl: &SslOptions, tls_host: Option<&str>) -> Option<SslOpts> {
    let mut opts = match ssl.mode {
        SslMode::Disabled => return None,
        SslMode::Required => SslOpts::default()
            .with_danger_accept_invalid_certs(true)
            .with_danger_skip_domain_validation(true),
        SslMode::VerifyIdentity => SslOpts::default(),
    };

    if let Some(ca_path) = &ssl.ca_path {
        // 指定了 CA 就只信它，和 mysql 客户端的 --ssl-ca 一致
        opts = opts
            .with_root_certs(vec![std::path::PathBuf::from(ca_path).into()])
            .with_disable_built_in_roots(true);
    }
    if let (Some(cert_path), Some(key_path)) = (&ssl.cert_path, &ssl.key_path) {
        let identity = ClientIdentity::new(
            std::path::PathBuf::from(cert_path).into(),
            std::path::PathBuf::from(key_path).into(),
        );
        opts = opts.with_client_identity(Some(identity));
    }
    if let Some(host) = tls_host {
        opts = opts.with_danger_tls_hostname_override(Some(host.to_string()));
    }
    Some(opts)
}

/// 建连接池。选项不对直接拒绝；配了 SSH 就当场把隧道连上，主机密钥和认证的问题立刻暴露。
/// 不走 SSH 时这里只建池，真正的 TCP 连接等到第一次查询才发生
pub async fn open_pool(config: &ConnectionConfig) -> Result<DbPool, OpenError> {
    config.options.validate().map_err(OpenError::BadOptions)?;
    let hops = &config.options.ssh.hops;
    if !config.ssh_secrets.is_empty() && config.ssh_secrets.len() != hops.len() {
        return Err(OpenError::BadOptions(format!(
            "SSH 有 {} 跳，但给了 {} 份密码 / 口令",
            hops.len(),
            config.ssh_secrets.len()
        )));
    }
    let timeouts = &config.options.timeouts;

    let mut tunnel = None;
    let mut host = config.host.clone();
    let mut port = config.port;
    let mut tls_host = None;
    if !hops.is_empty() {
        let secrets = resolve_ssh_secrets(config)?;
        let opened = Tunnel::open(hops.clone(), secrets, config.host.clone(), config.port, timeouts.connect())
            .await
            .map_err(OpenError::Ssh)?;
        host = "127.0.0.1".to_string();
        port = opened.local_port();
        tls_host = Some(config.host.as_str());
        tunnel = Some(Arc::new(opened));
    }

    let mut builder = OptsBuilder::default()
        .ip_or_hostname(host)
        .tcp_port(port)
        .user(Some(config.user.clone()))
        .pass(Some(config.password.clone()))
        // mysql_async 默认 prefer_socket = true：TCP 连上后读服务器的 @@socket，再去连**本机**
        // 同名的 unix socket。远程服务器的 socket 路径和本机 MySQL 一样（/tmp/mysql.sock 很常见）时，
        // 会悄悄连到本机那个库；走隧道时连的是 127.0.0.1，更是必中。unix socket 上也不做 TLS
        .prefer_socket(false)
        .ssl_opts(build_ssl_opts(&config.options.ssl, tls_host))
        // 不设就走服务器默认的握手字符集，中文会按 latin1 解出乱码 —— 不报错、数据全错。
        // 必须用 setup 而不是 init：连接池归还连接时会 reset 会话，init 不重跑，SET NAMES 会丢
        .setup(vec!["SET NAMES utf8mb4"])
        // UPDATE 返回「匹配到的行数」而不是「真正变了的行数」。写回靠 affected_rows == 1
        // 判断定位成功，不开的话写入和原值相同的内容（粘贴时很常见）会被误判成没找到这一行
        .client_found_rows(true);

    if let Some(database) = &config.database {
        builder = builder.db_name(Some(database.clone()));
    }

    Ok(DbPool {
        pool: Pool::new(Opts::from(builder)),
        connect_timeout: timeouts.connect(),
        query_timeout: timeouts.query(),
        tunnel,
        connection_ids: Arc::default(),
    })
}

/// 每一跳的密码 / 口令。
///
/// 两个来源，前者优先：界面这次传进来的（刚输入、还没保存，或者想临时换一个），
/// 然后是这条保存的连接在钥匙串里的那份。都没有就是 None：私钥没加密、用 agent 时本来就不需要
fn resolve_ssh_secrets(config: &ConnectionConfig) -> Result<Vec<Option<String>>, OpenError> {
    let hops = &config.options.ssh.hops;
    let mut secrets = Vec::with_capacity(hops.len());
    for (index, hop) in hops.iter().enumerate() {
        if let Some(given) = config.ssh_secrets.get(index).cloned().flatten() {
            secrets.push(Some(given));
            continue;
        }
        // agent 不需要，就不去钥匙串里翻，免得弹系统授权框
        let stored = match (&config.saved_id, &hop.auth) {
            (Some(saved_id), SshAuth::Password | SshAuth::PrivateKey { .. }) => {
                crate::connections::load_ssh_secret(saved_id, hop)
                    .map_err(|err| OpenError::BadOptions(err.to_string()))?
            }
            _ => None,
        };
        secrets.push(stored);
    }
    Ok(secrets)
}

impl DbPool {
    /// 取一条连接。闲置连接已经被服务器断开（重启、wait_timeout、被 KILL）时，
    /// mysql_async 取出来会先检查套接字，坏的丢掉换新的 —— 这就是断线重连，发生在任何语句之前。
    ///
    /// 这一步的失败统一包成 ConnectFailed：语句还没发出去，界面可以明确告诉用户没有执行
    pub async fn get_conn(&self) -> Result<Conn, mysql_async::Error> {
        let attempt = self.pool.get_conn();
        let result = match self.connect_timeout {
            Some(limit) => match tokio::time::timeout(limit, attempt).await {
                Ok(result) => result,
                Err(_) => {
                    let reason = self
                        .tunnel_error()
                        .unwrap_or_else(|| format!("{} 秒内没有连上", limit.as_secs()));
                    return Err(mysql_async::Error::Other(Box::new(ConnectFailed(reason))));
                }
            },
            None => attempt.await,
        };

        if let Ok(conn) = &result {
            self.connection_ids.lock().unwrap().insert(conn.id());
        }
        result.map_err(|err| {
            // 隧道那头失败时，mysql_async 只看到本地端口的连接被关掉，真正的原因在隧道里
            let reason = self.tunnel_error().unwrap_or_else(|| err.to_string());
            mysql_async::Error::Other(Box::new(ConnectFailed(reason)))
        })
    }

    /// 取出过的连接的线程 id，包括已经断开的。
    // ponytail: 只增不减，断开的连接也留着；服务器重启后线程 id 从头编号，旧 id 可能撞上别人的新连接，
    // 被误认成自己的（只会多拦，不会少拦）。要精确就得在连接断开时移除，mysql_async 没有这个回调
    pub fn connection_ids(&self) -> Vec<u32> {
        self.connection_ids.lock().unwrap().iter().copied().collect()
    }

    fn tunnel_error(&self) -> Option<String> {
        self.tunnel.as_ref().and_then(|tunnel| tunnel.take_error())
    }

    /// 断开池里的全部连接。隧道随最后一个 DbPool 副本释放
    pub async fn disconnect(self) -> Result<(), mysql_async::Error> {
        self.pool.disconnect().await
    }

    /// 另开一条连接停掉 connection_id 上正在跑的语句。KILL 自己用户的线程不需要额外权限
    async fn kill_query(&self, connection_id: u32) -> Result<(), mysql_async::Error> {
        let mut conn = self.get_conn().await?;
        conn.query_drop(format!("KILL QUERY {connection_id}")).await
    }
}

/// 跑一条查询。超过 max_rows 停止读取并标记截断，不静默丢行
pub async fn run_query(
    pool: &DbPool,
    sql: &str,
    max_rows: usize,
) -> Result<ResultSet, mysql_async::Error> {
    run_query_with_params(pool, sql, Vec::new(), max_rows).await
}

/// 带参数的查询。行的解释和 run_query 走同一条路，回读单行时用。
///
/// 设了查询超时的话，到点就另开一条连接 KILL QUERY，之后一律按超时报错。
/// 不能到点后再「看它是不是正好跑完了」：`SELECT SLEEP(n)` 被 KILL QUERY 打断时返回 1 而不报错，
/// 按结果判断会把被打断的查询当成正常完成
pub async fn run_query_with_params(
    pool: &DbPool,
    sql: &str,
    params: Vec<Value>,
    max_rows: usize,
) -> Result<ResultSet, mysql_async::Error> {
    let mut conn = pool.get_conn().await?;
    let (result, usable) = run_on_conn(pool, &mut conn, sql, params, max_rows).await;
    if !usable {
        // 状态不明的连接不还回池里，下一次操作换一条新的
        let _ = conn.disconnect().await;
    }
    result
}

/// 一段脚本的执行结果。failure 是第几条（从 0 数）失败和原因，它之前的语句都已经执行了
pub struct ScriptRun {
    pub results: Vec<ResultSet>,
    pub failure: Option<(usize, mysql_async::Error)>,
}

/// 多条语句按顺序在**同一条连接**上跑：SET @x、临时表、前面建后面用，都要同一个会话才成立。
/// 遇到第一条失败就停，不继续执行后面的 —— 后面的语句多半依赖前面的结果
pub async fn run_script(
    pool: &DbPool,
    statements: &[String],
    max_rows: usize,
) -> Result<ScriptRun, mysql_async::Error> {
    let mut conn = pool.get_conn().await?;
    let mut results = Vec::with_capacity(statements.len());

    for (index, sql) in statements.iter().enumerate() {
        let (result, usable) = run_on_conn(pool, &mut conn, sql, Vec::new(), max_rows).await;
        match result {
            Ok(result) => results.push(result),
            Err(err) => {
                if !usable {
                    let _ = conn.disconnect().await;
                }
                return Ok(ScriptRun { results, failure: Some((index, err)) });
            }
        }
    }
    Ok(ScriptRun { results, failure: None })
}

/// 在给定连接上跑一条，带查询超时。第二项为 false 表示连接状态不明，调用方必须丢掉它
async fn run_on_conn(
    pool: &DbPool,
    conn: &mut Conn,
    sql: &str,
    params: Vec<Value>,
    max_rows: usize,
) -> (Result<ResultSet, mysql_async::Error>, bool) {
    let Some(limit) = pool.query_timeout else {
        return (read_result(conn, sql, params, max_rows).await, true);
    };

    let connection_id = conn.id();
    let mut running = Box::pin(read_result(conn, sql, params, max_rows));
    if let Ok(result) = tokio::time::timeout(limit, &mut running).await {
        return (result, true);
    }

    // 服务器已经卡死时 KILL 本身也可能挂住，同样要有时限
    let kill_error = match tokio::time::timeout(KILL_GRACE, pool.kill_query(connection_id)).await {
        Ok(Ok(())) => None,
        Ok(Err(err)) => Some(err.to_string()),
        Err(_) => Some(format!("KILL QUERY {} 秒内没有完成", KILL_GRACE.as_secs())),
    };
    // 等原连接把被打断的语句收完，连接状态干净了才能还回池里
    let finished = match tokio::time::timeout(KILL_GRACE, &mut running).await {
        Ok(Ok(_)) => true,
        Ok(Err(mysql_async::Error::Server(ref err))) if err.code == ER_QUERY_INTERRUPTED => true,
        Ok(Err(_)) | Err(_) => false,
    };
    drop(running);

    let err = mysql_async::Error::Other(Box::new(QueryTimedOut {
        seconds: limit.as_secs(),
        confirmed_stopped: kill_error.is_none() && finished,
        kill_error,
    }));
    (Err(err), finished)
}

pub(crate) async fn read_result(
    conn: &mut Conn,
    sql: &str,
    params: Vec<Value>,
    max_rows: usize,
) -> Result<ResultSet, mysql_async::Error> {
    // 用 prepared statement 跑，文本协议下所有值都是 Bytes，拿不到真实数值类型
    let mut result = conn.exec_iter(sql, params).await?;

    let columns = match result.columns() {
        Some(cols) => build_columns(&cols),
        None => Vec::new(),
    };

    let mut rows = Vec::new();
    let mut truncated = false;

    while let Some(row) = result.next().await? {
        if rows.len() >= max_rows {
            truncated = true;
            break;
        }
        rows.push(build_row(row, &columns));
    }

    // 截断时剩余的行必须读完或丢弃，否则连接状态不干净、无法复用
    let affected_rows = if truncated {
        result.drop_result().await?;
        0
    } else {
        result.affected_rows()
    };

    Ok(ResultSet {
        columns,
        rows,
        truncated,
        affected_rows,
    })
}

fn build_columns(columns: &[Column]) -> Vec<ColumnMeta> {
    let mut metas = Vec::with_capacity(columns.len());
    for column in columns {
        metas.push(ColumnMeta {
            name: column.name_str().to_string(),
            org_name: column.org_name_str().to_string(),
            org_table: column.org_table_str().to_string(),
            schema: column.schema_str().to_string(),
            is_binary: is_binary_column(column),
            kind: column_kind(column),
            decimals: column.decimals(),
        });
    }
    metas
}

/// 判断列是否按字节处理。
///
/// 不能只看 charset：DECIMAL、DATE、INT 这些数值和日期类型的 collation 也是 binary(63)，
/// 但它们的字节是 ASCII 字面量，当成二进制会让 DECIMAL 显示成一串字节。
/// 只有字符串家族才存在「二进制还是文本」之分，BIT 和 GEOMETRY 则永远是原始字节。
fn is_binary_column(column: &Column) -> bool {
    match column.column_type() {
        ColumnType::MYSQL_TYPE_BIT | ColumnType::MYSQL_TYPE_GEOMETRY => true,

        ColumnType::MYSQL_TYPE_STRING
        | ColumnType::MYSQL_TYPE_VAR_STRING
        | ColumnType::MYSQL_TYPE_VARCHAR
        | ColumnType::MYSQL_TYPE_BLOB
        | ColumnType::MYSQL_TYPE_TINY_BLOB
        | ColumnType::MYSQL_TYPE_MEDIUM_BLOB
        | ColumnType::MYSQL_TYPE_LONG_BLOB => column.character_set() == BINARY_COLLATION_ID,

        _ => false,
    }
}

/// 列类别。ENUM / SET 在结果集元数据里是 STRING 加标志位，不是单独的类型
fn column_kind(column: &Column) -> ColumnKind {
    if is_binary_column(column) {
        return ColumnKind::Binary;
    }
    let flags = column.flags();
    if flags.contains(ColumnFlags::ENUM_FLAG) {
        return ColumnKind::Enum;
    }
    if flags.contains(ColumnFlags::SET_FLAG) {
        return ColumnKind::Set;
    }

    match column.column_type() {
        ColumnType::MYSQL_TYPE_JSON => ColumnKind::Json,
        ColumnType::MYSQL_TYPE_DATE | ColumnType::MYSQL_TYPE_NEWDATE => ColumnKind::Date,
        ColumnType::MYSQL_TYPE_DATETIME
        | ColumnType::MYSQL_TYPE_DATETIME2
        | ColumnType::MYSQL_TYPE_TIMESTAMP
        | ColumnType::MYSQL_TYPE_TIMESTAMP2 => ColumnKind::DateTime,
        ColumnType::MYSQL_TYPE_TIME | ColumnType::MYSQL_TYPE_TIME2 => ColumnKind::Time,
        ColumnType::MYSQL_TYPE_ENUM => ColumnKind::Enum,
        ColumnType::MYSQL_TYPE_SET => ColumnKind::Set,
        ColumnType::MYSQL_TYPE_TINY
        | ColumnType::MYSQL_TYPE_SHORT
        | ColumnType::MYSQL_TYPE_LONG
        | ColumnType::MYSQL_TYPE_LONGLONG
        | ColumnType::MYSQL_TYPE_INT24
        | ColumnType::MYSQL_TYPE_YEAR
        | ColumnType::MYSQL_TYPE_FLOAT
        | ColumnType::MYSQL_TYPE_DOUBLE
        | ColumnType::MYSQL_TYPE_DECIMAL
        | ColumnType::MYSQL_TYPE_NEWDECIMAL => ColumnKind::Number,
        _ => ColumnKind::Text,
    }
}

fn build_row(row: mysql_async::Row, columns: &[ColumnMeta]) -> Vec<CellValue> {
    let values = row.unwrap();

    let mut cells = Vec::with_capacity(values.len());
    for (index, value) in values.into_iter().enumerate() {
        // 列元数据缺位说明结果集和列信息对不上，按二进制处理避免伪造出文本
        let is_binary = columns.get(index).map(|c| c.is_binary).unwrap_or(true);
        cells.push(cell_from_value(value, is_binary));
    }
    cells
}
