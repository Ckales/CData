//! 连接的高级选项：SSL、超时、SSH 隧道。
//!
//! 这里只放「怎么连」的配置，**不放任何密码或口令**：这个结构会原样存进 connections.json。
//! SSH 的密码和私钥口令走 `ConnectionConfig::ssh_secrets` 或系统钥匙串。

use std::path::Path;
use std::time::Duration;

use serde::{Deserialize, Serialize};

/// 旧版 connections.json 里没有这个字段，读出来就是默认值。
/// 容器级 `serde(default)` 让以后新增的字段同样能从旧文件读出来，不用每加一个字段就报解析错误
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct ConnectionOptions {
    pub ssl: SslOptions,
    pub timeouts: TimeoutOptions,
    pub ssh: SshOptions,
}

/// 对应 MySQL 客户端的 `--ssl-mode`，但少了两档：
///
/// - PREFERRED：mysql_async 只有「必须加密」和「不加密」两种，服务器不支持 SSL 时没法降级，
///   做不出「能加密就加密」的语义。硬凑的话要么等于 Required，要么等于 Disabled，都是在骗人。
/// - VERIFY_CA：mysql_async 跳过主机名校验靠匹配 rustls 错误文本里的 "NotValidForName"，
///   rustls 0.23 的错误文本已经不含这个词，结果「只校验 CA」实际上仍然校验主机名，
///   和 VerifyIdentity 没有区别。见 DEV_NOTES。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SslMode {
    /// 不加密。和以前的行为一样
    Disabled,
    /// 加密，但不校验服务器证书，防窃听不防中间人
    Required,
    /// 加密，校验证书链和主机名
    VerifyIdentity,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct SslOptions {
    pub mode: SslMode,
    /// 只信任这个 CA。不填时 VerifyIdentity 用内置的公共 CA 根证书（Mozilla 那一套，不是系统钥匙串）
    pub ca_path: Option<String>,
    /// 客户端证书和私钥要么都填要么都不填
    pub cert_path: Option<String>,
    pub key_path: Option<String>,
}

impl Default for SslOptions {
    fn default() -> Self {
        SslOptions {
            mode: SslMode::Disabled,
            ca_path: None,
            cert_path: None,
            key_path: None,
        }
    }
}

impl SslOptions {
    /// 选项组合是否说得通。说不通就拒绝，不悄悄忽略某个填了的字段
    pub fn validate(&self) -> Result<(), String> {
        let has_any_path = self.ca_path.is_some() || self.cert_path.is_some() || self.key_path.is_some();
        if self.mode == SslMode::Disabled {
            if has_any_path {
                return Err("SSL 已关闭，但填了证书路径。请清空证书路径，或者选一个加密模式".to_string());
            }
            return Ok(());
        }

        if self.mode == SslMode::Required && self.ca_path.is_some() {
            return Err(
                "Required 模式不校验服务器证书，填的 CA 证书不会被使用。要校验证书请选 VerifyIdentity".to_string(),
            );
        }
        if self.cert_path.is_some() != self.key_path.is_some() {
            return Err("客户端证书和客户端私钥要一起填".to_string());
        }

        for (label, path) in [
            ("CA 证书", &self.ca_path),
            ("客户端证书", &self.cert_path),
            ("客户端私钥", &self.key_path),
        ] {
            if let Some(path) = path {
                if !Path::new(path).is_file() {
                    return Err(format!("{label}文件不存在：{path}"));
                }
            }
        }
        Ok(())
    }
}

/// 单位秒。None 表示不限时
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct TimeoutOptions {
    /// 建立连接（含 SSH 隧道、TLS 握手、登录）的时限
    pub connect_secs: Option<u32>,
    /// 单条查询的时限。超时后用另一条连接 KILL QUERY 让服务器停掉这条语句
    pub query_secs: Option<u32>,
}

impl Default for TimeoutOptions {
    fn default() -> Self {
        // 不设的话连一个不通的地址要等系统 TCP 超时（macOS 上一分多钟），界面像卡死了。
        // 查询默认不限时：跑几分钟的报表很常见，默认掐掉比卡住更糟
        TimeoutOptions {
            connect_secs: Some(10),
            query_secs: None,
        }
    }
}

impl TimeoutOptions {
    pub fn validate(&self) -> Result<(), String> {
        if self.connect_secs == Some(0) || self.query_secs == Some(0) {
            return Err("超时要大于 0 秒；不限时请留空".to_string());
        }
        Ok(())
    }

    pub fn connect(&self) -> Option<Duration> {
        self.connect_secs.map(|secs| Duration::from_secs(u64::from(secs)))
    }

    pub fn query(&self) -> Option<Duration> {
        self.query_secs.map(|secs| Duration::from_secs(u64::from(secs)))
    }
}

/// SSH 隧道。hops 为空表示直连。
///
/// 按连接顺序排：前面的是跳板机，最后一跳是替我们去连 MySQL 的那台。
/// 只有一跳就是普通的 `ssh -L`，两跳相当于 `ssh -J jump -L ... target`
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct SshOptions {
    pub hops: Vec<SshHop>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SshHop {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub auth: SshAuth,
}

impl SshHop {
    /// user@host:port，钥匙串账号和错误信息都用它
    pub fn label(&self) -> String {
        format!("{}@{}:{}", self.user, self.host, self.port)
    }
}

/// 认证方式。密码和私钥口令不在这里
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum SshAuth {
    Password,
    /// 私钥文件路径。有没有口令看 ssh_secrets 里给没给
    PrivateKey { path: String },
    /// 用 ssh-agent（macOS / Linux 读 SSH_AUTH_SOCK，Windows 用 OpenSSH 的命名管道）
    Agent,
}

impl SshOptions {
    pub fn validate(&self) -> Result<(), String> {
        for (index, hop) in self.hops.iter().enumerate() {
            let position = index + 1;
            if hop.host.trim().is_empty() {
                return Err(format!("第 {position} 跳 SSH 没有填主机"));
            }
            if hop.user.trim().is_empty() {
                return Err(format!("第 {position} 跳 SSH 没有填用户名"));
            }
            if hop.port == 0 {
                return Err(format!("第 {position} 跳 SSH 的端口不能是 0"));
            }
            if let SshAuth::PrivateKey { path } = &hop.auth {
                if !Path::new(path).is_file() {
                    return Err(format!("第 {position} 跳 SSH 的私钥文件不存在：{path}"));
                }
            }
        }
        Ok(())
    }
}

impl ConnectionOptions {
    pub fn validate(&self) -> Result<(), String> {
        self.ssl.validate()?;
        self.timeouts.validate()?;
        self.ssh.validate()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_file(name: &str) -> String {
        let path = std::env::temp_dir().join(format!("cdata-options-{}-{name}", std::process::id()));
        std::fs::write(&path, b"x").unwrap();
        path.to_string_lossy().into_owned()
    }

    #[test]
    fn missing_options_in_old_json_read_as_defaults() {
        // 旧版只有这几个字段，没有 options
        let options: ConnectionOptions = serde_json::from_str("{}").unwrap();
        assert_eq!(options, ConnectionOptions::default());

        // 只写了一部分的也能读，缺的字段取默认
        let options: ConnectionOptions =
            serde_json::from_str(r#"{"timeouts":{"query_secs":30}}"#).unwrap();
        assert_eq!(options.timeouts.query_secs, Some(30));
        assert_eq!(options.timeouts.connect_secs, Some(10));
        assert_eq!(options.ssl.mode, SslMode::Disabled);
    }

    #[test]
    fn ssl_combinations_that_do_not_make_sense_are_rejected() {
        let ca = temp_file("ca.pem");

        let disabled_with_path = SslOptions { ca_path: Some(ca.clone()), ..SslOptions::default() };
        assert!(disabled_with_path.validate().is_err(), "关闭 SSL 时填的证书不能被悄悄忽略");

        let required_with_ca =
            SslOptions { mode: SslMode::Required, ca_path: Some(ca.clone()), ..SslOptions::default() };
        let err = required_with_ca.validate().unwrap_err();
        assert!(err.contains("VerifyIdentity"), "{err}");

        let cert_only = SslOptions {
            mode: SslMode::Required,
            cert_path: Some(ca.clone()),
            ..SslOptions::default()
        };
        assert!(cert_only.validate().is_err());

        let missing_file = SslOptions {
            mode: SslMode::VerifyIdentity,
            ca_path: Some("/nonexistent/cdata-ca.pem".to_string()),
            ..SslOptions::default()
        };
        assert!(missing_file.validate().unwrap_err().contains("不存在"));

        let ok = SslOptions { mode: SslMode::VerifyIdentity, ca_path: Some(ca.clone()), ..SslOptions::default() };
        assert!(ok.validate().is_ok());
        std::fs::remove_file(&ca).ok();
    }

    #[test]
    fn zero_timeout_is_rejected() {
        let zero = TimeoutOptions { connect_secs: Some(0), query_secs: None };
        assert!(zero.validate().is_err(), "0 秒是「立即超时」还是「不限」说不清，直接拒绝");
        assert!(TimeoutOptions { connect_secs: None, query_secs: None }.validate().is_ok());
    }

    #[test]
    fn ssh_hops_need_host_user_and_existing_key() {
        let hop = SshHop {
            host: "bastion".into(),
            port: 22,
            user: "ops".into(),
            auth: SshAuth::Agent,
        };
        assert!(SshOptions { hops: vec![hop.clone()] }.validate().is_ok());

        let no_user = SshHop { user: " ".into(), ..hop.clone() };
        assert!(SshOptions { hops: vec![hop.clone(), no_user] }
            .validate()
            .unwrap_err()
            .contains("第 2 跳"));

        let missing_key = SshHop {
            auth: SshAuth::PrivateKey { path: "/nonexistent/id_ed25519".into() },
            ..hop
        };
        assert!(SshOptions { hops: vec![missing_key] }.validate().is_err());
    }
}
