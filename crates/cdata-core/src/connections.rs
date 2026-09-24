//! 保存的连接。
//!
//! **密码绝不进配置文件**：配置存用户数据目录的 JSON，密码单独进系统钥匙串
//! （macOS Keychain / Windows Credential Manager）。配置文件会被备份、同步、
//! 误传进仓库，钥匙串不会。

use std::fs;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::db::ConnectionConfig;
use crate::options::{ConnectionOptions, SshHop};

const KEYRING_SERVICE: &str = "com.ckales.cdata";

#[derive(Debug)]
pub enum Error {
    Io(String),
    Parse(String),
    Keyring(String),
    NoDataDir,
    NotFound(String),
    /// 值超出允许范围，比如偏好设置里的行数上限
    Invalid(String),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Io(message) => write!(f, "读写配置失败：{message}"),
            Error::Parse(message) => write!(f, "配置文件格式不对：{message}"),
            Error::Keyring(message) => write!(f, "钥匙串操作失败：{message}"),
            Error::NoDataDir => write!(f, "找不到用户数据目录"),
            Error::NotFound(id) => write!(f, "没有保存过的连接 {id}"),
            Error::Invalid(message) => write!(f, "{message}"),
        }
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;

/// 一条保存的连接。**没有 password 字段，而且不要加**
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SavedConnection {
    /// 钥匙串里也用这个 id 当账号名
    pub id: String,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub user: String,
    pub database: Option<String>,
    /// SSL、超时、SSH。加这个字段之前保存的连接没有它，按默认值读出来，不报解析错误
    #[serde(default)]
    pub options: ConnectionOptions,
}

impl SavedConnection {
    /// 配上密码变成可以直接连的配置。SSH 的密码 / 口令连接时按 saved_id 去钥匙串取
    pub fn with_password(&self, password: String) -> ConnectionConfig {
        ConnectionConfig {
            host: self.host.clone(),
            port: self.port,
            user: self.user.clone(),
            password,
            database: self.database.clone(),
            options: self.options.clone(),
            ssh_secrets: Vec::new(),
            saved_id: Some(self.id.clone()),
        }
    }
}

/// SSH 密码 / 口令在钥匙串里的账号名。
///
/// 带上这一跳的 user@host:port 而不是只用序号：跳板机和目标机调换顺序、或者改了主机之后，
/// 旧的密码不会被发给另一台服务器
fn ssh_secret_account(id: &str, hop: &SshHop) -> String {
    format!("{id}#ssh:{}", hop.label())
}

/// 保存某一跳的 SSH 密码或私钥口令，只进钥匙串
pub fn save_ssh_secret(id: &str, hop: &SshHop, secret: &str) -> Result<()> {
    let entry = keyring::Entry::new(KEYRING_SERVICE, &ssh_secret_account(id, hop))
        .map_err(|e| Error::Keyring(e.to_string()))?;
    entry.set_password(secret).map_err(|e| Error::Keyring(e.to_string()))
}

/// 取某一跳的 SSH 密码或口令。**不经过 FFI**：只在 core 连接时使用，界面拿不到
pub fn load_ssh_secret(id: &str, hop: &SshHop) -> Result<Option<String>> {
    let entry = keyring::Entry::new(KEYRING_SERVICE, &ssh_secret_account(id, hop))
        .map_err(|e| Error::Keyring(e.to_string()))?;
    match entry.get_password() {
        Ok(secret) => Ok(Some(secret)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(e) => Err(Error::Keyring(e.to_string())),
    }
}

fn config_path() -> Result<PathBuf> {
    // 测试用环境变量指到临时文件，免得跑一次测试就把用户真实的连接清单改了
    if let Ok(path) = std::env::var("CDATA_CONFIG_PATH") {
        return Ok(PathBuf::from(path));
    }

    let base = dirs::data_dir().ok_or(Error::NoDataDir)?;
    Ok(base.join("CData").join("connections.json"))
}

/// 读全部保存的连接。文件不存在就是空列表，不是错误
pub fn list() -> Result<Vec<SavedConnection>> {
    let path = config_path()?;
    if !path.exists() {
        return Ok(Vec::new());
    }

    let text = fs::read_to_string(&path).map_err(|e| Error::Io(e.to_string()))?;
    serde_json::from_str(&text).map_err(|e| Error::Parse(e.to_string()))
}

/// 新增或更新一条连接。密码为 None 表示不动钥匙串里已有的那份
pub fn save(connection: &SavedConnection, password: Option<&str>) -> Result<()> {
    let mut all = list()?;
    match all.iter().position(|c| c.id == connection.id) {
        Some(index) => all[index] = connection.clone(),
        None => all.push(connection.clone()),
    }
    write_all(&all)?;

    if let Some(password) = password {
        store_password(&connection.id, password)?;
    }
    Ok(())
}

/// 删连接，钥匙串里的密码一并删掉，不留孤儿凭据
pub fn delete(id: &str) -> Result<()> {
    let mut all = list()?;
    let Some(index) = all.iter().position(|c| c.id == id) else {
        return Err(Error::NotFound(id.to_string()));
    };
    let removed = all.remove(index);
    write_all(&all)?;

    // 钥匙串里本来就没有也算删成功，不因为这个让整个删除失败
    let mut accounts = vec![id.to_string()];
    for hop in &removed.options.ssh.hops {
        accounts.push(ssh_secret_account(id, hop));
    }
    for account in accounts {
        if let Ok(entry) = keyring::Entry::new(KEYRING_SERVICE, &account) {
            let _ = entry.delete_credential();
        }
    }
    Ok(())
}

fn write_all(connections: &[SavedConnection]) -> Result<()> {
    let path = config_path()?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| Error::Io(e.to_string()))?;
    }

    let text = serde_json::to_string_pretty(connections).map_err(|e| Error::Parse(e.to_string()))?;
    fs::write(&path, text).map_err(|e| Error::Io(e.to_string()))
}

fn store_password(id: &str, password: &str) -> Result<()> {
    let entry = keyring::Entry::new(KEYRING_SERVICE, id).map_err(|e| Error::Keyring(e.to_string()))?;
    entry
        .set_password(password)
        .map_err(|e| Error::Keyring(e.to_string()))
}

/// 取密码。没存过返回 None，界面据此提示用户输一次
pub fn load_password(id: &str) -> Result<Option<String>> {
    let entry = keyring::Entry::new(KEYRING_SERVICE, id).map_err(|e| Error::Keyring(e.to_string()))?;
    match entry.get_password() {
        Ok(password) => Ok(Some(password)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(e) => Err(Error::Keyring(e.to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn saved_connection_has_no_password_field() {
        let connection = SavedConnection {
            id: "c1".into(),
            name: "本地".into(),
            host: "127.0.0.1".into(),
            port: 3306,
            user: "root".into(),
            database: Some("shop".into()),
            options: ConnectionOptions::default(),
        };

        // 序列化结果里绝不能出现任何密码痕迹 —— 这个文件会被备份和同步
        let json = serde_json::to_string(&connection).unwrap();
        assert!(!json.contains("password"), "配置里不该有 password 字段：{json}");
        assert!(json.contains("127.0.0.1"));
    }

    #[test]
    fn config_saved_before_options_existed_still_loads() {
        let old = r#"[{"id":"c1","name":"本地","host":"127.0.0.1","port":3306,"user":"root","database":null}]"#;
        let all: Vec<SavedConnection> = serde_json::from_str(old).unwrap();
        assert_eq!(all[0].options, ConnectionOptions::default());
    }

    /// 配置文件的增删查往返。密码一律传 None，测试不碰钥匙串（会弹系统授权框）
    #[test]
    fn save_list_delete_round_trip() {
        let dir = std::env::temp_dir().join(format!("cdata-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("connections.json");
        // SAFETY: 测试单线程跑这一段，set_var 不会和别的线程打架
        unsafe { std::env::set_var("CDATA_CONFIG_PATH", &path) };

        // 文件不存在时是空列表，不是错误
        assert_eq!(list().unwrap().len(), 0);

        let connection = SavedConnection {
            id: "c1".into(),
            name: "本地".into(),
            host: "127.0.0.1".into(),
            port: 3306,
            user: "root".into(),
            database: Some("shop".into()),
            options: ConnectionOptions::default(),
        };
        save(&connection, None).unwrap();
        assert_eq!(list().unwrap(), vec![connection.clone()]);

        // 落盘的内容里不能有密码痕迹
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(!text.contains("password"), "配置文件里出现了 password：{text}");

        // 同 id 再存是覆盖，不是追加
        let renamed = SavedConnection { name: "改了名".into(), ..connection.clone() };
        save(&renamed, None).unwrap();
        let all = list().unwrap();
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].name, "改了名");

        delete("c1").unwrap();
        assert_eq!(list().unwrap().len(), 0);

        // 删不存在的要报错，不能静默成功
        assert!(delete("c1").is_err());

        unsafe { std::env::remove_var("CDATA_CONFIG_PATH") };
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn with_password_builds_a_usable_config() {
        let connection = SavedConnection {
            id: "c1".into(),
            name: "本地".into(),
            host: "127.0.0.1".into(),
            port: 3306,
            user: "root".into(),
            database: None,
            options: ConnectionOptions::default(),
        };

        let config = connection.with_password("secret".into());
        assert_eq!(config.host, "127.0.0.1");
        assert_eq!(config.password, "secret");
        assert_eq!(config.database, None);
    }
}
