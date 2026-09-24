//! 保存的连接的 FFI 接口。
//!
//! 密码不在 SavedConnection 里，界面拿到的永远是不含凭据的配置；
//! 要密码得单独调 load_password，它从系统钥匙串读。

use flutter_rust_bridge::frb;

pub use cdata_core::connections::SavedConnection;

use crate::api::db::Result;
use crate::api::options::{ConnectionOptions, SshHop};

#[frb(mirror(SavedConnection))]
pub struct _SavedConnection {
    pub id: String,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub user: String,
    pub database: Option<String>,
    pub options: ConnectionOptions,
}

fn to_message(err: cdata_core::connections::Error) -> String {
    err.to_string()
}

/// 全部保存的连接。没有配置文件时返回空列表，不报错
pub fn list_connections() -> Result<Vec<SavedConnection>> {
    cdata_core::connections::list().map_err(to_message)
}

/// 新增或更新。password 为 None 表示保留钥匙串里已有的那份
pub fn save_connection(connection: SavedConnection, password: Option<String>) -> Result<()> {
    cdata_core::connections::save(&connection, password.as_deref()).map_err(to_message)
}

/// 删连接，钥匙串里的密码一并清掉
pub fn delete_connection(id: String) -> Result<()> {
    cdata_core::connections::delete(&id).map_err(to_message)
}

/// 从钥匙串取密码。没存过返回 null，界面据此提示用户输一次
pub fn load_password(id: String) -> Result<Option<String>> {
    cdata_core::connections::load_password(&id).map_err(to_message)
}

/// 保存某一跳的 SSH 密码或私钥口令，只进钥匙串。
/// 没有对应的读取接口：连接时 core 按 ConnectionConfig.saved_id 自己去取，界面拿不到
pub fn save_ssh_secret(id: String, hop: SshHop, secret: String) -> Result<()> {
    cdata_core::connections::save_ssh_secret(&id, &hop, &secret).map_err(to_message)
}
