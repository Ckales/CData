//! 连接高级选项（SSL、超时、SSH）和主机密钥确认的 FFI 接口。规则都在 core，这里只做翻译。

use flutter_rust_bridge::frb;

pub use cdata_core::options::{
    ConnectionOptions, SshAuth, SshHop, SshOptions, SslMode, SslOptions, TimeoutOptions,
};
pub use cdata_core::ssh::{HostKeyIssue, HostKeyIssueKind};

use crate::api::db::Result;

#[frb(mirror(ConnectionOptions))]
pub struct _ConnectionOptions {
    pub ssl: SslOptions,
    pub timeouts: TimeoutOptions,
    pub ssh: SshOptions,
}

#[frb(mirror(SslMode))]
pub enum _SslMode {
    Disabled,
    Required,
    VerifyIdentity,
}

#[frb(mirror(SslOptions))]
pub struct _SslOptions {
    pub mode: SslMode,
    pub ca_path: Option<String>,
    pub cert_path: Option<String>,
    pub key_path: Option<String>,
}

#[frb(mirror(TimeoutOptions))]
pub struct _TimeoutOptions {
    pub connect_secs: Option<u32>,
    pub query_secs: Option<u32>,
}

#[frb(mirror(SshOptions))]
pub struct _SshOptions {
    pub hops: Vec<SshHop>,
}

#[frb(mirror(SshHop))]
pub struct _SshHop {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub auth: SshAuth,
}

#[frb(mirror(SshAuth))]
pub enum _SshAuth {
    Password,
    PrivateKey { path: String },
    Agent,
}

#[frb(mirror(HostKeyIssue))]
pub struct _HostKeyIssue {
    pub host: String,
    pub port: u16,
    pub fingerprint: String,
    pub algorithm: String,
    pub kind: HostKeyIssueKind,
}

#[frb(mirror(HostKeyIssueKind))]
pub enum _HostKeyIssueKind {
    Unknown,
    Mismatch,
}

/// 默认选项。界面新建连接时用它，不在 Dart 侧另写一份默认值
#[frb(sync)]
pub fn default_connection_options() -> ConnectionOptions {
    ConnectionOptions::default()
}

/// 用户确认指纹后信任这台主机：写进 known_hosts。只认这次运行里连接时见过的那把密钥
pub fn trust_host_key(host: String, port: u16, fingerprint: String) -> Result<()> {
    cdata_core::ssh::trust_host_key(&host, port, &fingerprint).map_err(|err| err.to_string())
}
