//! SSH 隧道。
//!
//! 用纯 Rust 的 russh 建隧道，不调系统的 `ssh -L`：系统 ssh 做密码认证要么需要 TTY，
//! 要么要借 SSH_ASKPASS 把密码交给一个外部程序；Windows 自带的 OpenSSH 对 askpass 的支持
//! 又和 macOS 不一样。主机密钥确认、错误信息也只能靠解析 ssh 的输出文本。
//!
//! 工作方式：在 127.0.0.1 上随机开一个端口，mysql_async 连这个端口；每来一条 TCP 连接，
//! 就在 SSH 会话上开一个 direct-tcpip 通道转发到 MySQL。跳板机就是在上一跳的通道里再跑一层 SSH。
//!
//! 主机密钥一律对照 known_hosts：没见过的拒绝并带上指纹，由用户确认后调 trust_host_key；
//! 和记录不一致的直接拒绝，不给「仍然继续」的选项。

use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use russh::client::{self, AuthResult, Handle, Msg};
use russh::keys::agent::client::{AgentClient, AgentStream};
use russh::keys::agent::AgentIdentity;
use russh::keys::{Algorithm, HashAlg, PrivateKey, PrivateKeyWithHashAlg, PublicKey, PublicKeyOrCertificate};
use russh::{Channel, Preferred};
use tokio::net::TcpListener;

use crate::options::{SshAuth, SshHop};

#[derive(Debug)]
pub enum Error {
    /// 主机密钥没通过 known_hosts 校验。界面据此问用户要不要信任
    HostKey(HostKeyIssue),
    Other(String),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::HostKey(issue) => match issue.kind {
                HostKeyIssueKind::Unknown => write!(
                    f,
                    "SSH 主机 {}:{} 不在 known_hosts 里，密钥指纹 {}（{}）。确认是你要连的服务器后再选择信任",
                    issue.host, issue.port, issue.fingerprint, issue.algorithm
                ),
                HostKeyIssueKind::Mismatch => write!(
                    f,
                    "SSH 主机 {}:{} 的密钥和 known_hosts 里的记录不一致（现在是 {}，{}），已拒绝连接。\
                     可能是服务器重装过，也可能有人在中间冒充；确认无误后请手动修改 known_hosts",
                    issue.host, issue.port, issue.fingerprint, issue.algorithm
                ),
            },
            Error::Other(message) => write!(f, "{message}"),
        }
    }
}

impl std::error::Error for Error {}

#[derive(Debug, Clone, PartialEq)]
pub struct HostKeyIssue {
    pub host: String,
    pub port: u16,
    /// OpenSSH 同款格式：`SHA256:...`
    pub fingerprint: String,
    /// 密钥类型，如 ssh-ed25519
    pub algorithm: String,
    pub kind: HostKeyIssueKind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostKeyIssueKind {
    /// known_hosts 里没有这台主机，可以让用户确认后信任
    Unknown,
    /// 有记录但对不上。只能拒绝
    Mismatch,
}

/// 主机密钥和 known_hosts 记录对照的结论
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostKeyVerdict {
    Trusted,
    Unknown,
    Mismatch,
}

/// 对照这台主机在 known_hosts 里的全部记录。
///
/// 有记录但没有一条相同就算不一致，**不管类型是否相同**：russh 自带的判断在类型不同时
/// 当作「没见过」，于是服务器换一种类型的密钥就能绕过不一致的拦截，变成一次普通的信任确认。
/// 为了不因此误报，连接前会把已记录的类型排到协商列表最前面（见 client_config），和 OpenSSH 一样
pub fn judge_host_key(presented: &PublicKey, recorded: &[PublicKey]) -> HostKeyVerdict {
    if recorded.is_empty() {
        return HostKeyVerdict::Unknown;
    }
    for key in recorded {
        if key.key_data() == presented.key_data() {
            return HostKeyVerdict::Trusted;
        }
    }
    HostKeyVerdict::Mismatch
}

/// 和 OpenSSH 共用 ~/.ssh/known_hosts：用户在终端里 ssh 过的主机这里直接认得
fn known_hosts_path() -> Result<PathBuf, Error> {
    // 测试用环境变量指到临时文件，免得跑一次测试就往用户真实的 known_hosts 里写东西
    if let Ok(path) = std::env::var("CDATA_KNOWN_HOSTS_PATH") {
        return Ok(PathBuf::from(path));
    }
    let home = dirs::home_dir().ok_or_else(|| Error::Other("找不到用户目录，读不了 known_hosts".to_string()))?;
    Ok(home.join(".ssh").join("known_hosts"))
}

/// 这台主机在 known_hosts 里记录的密钥。文件不存在就是没有记录。
///
/// 支持 `host`、`[host]:port` 和哈希过的主机名；通配符模式、`@cert-authority`、`@revoked`
/// 这几种写法 russh 不认，对应的行会被当作不相关跳过
fn recorded_keys(host: &str, port: u16) -> Result<Vec<PublicKey>, Error> {
    let path = known_hosts_path()?;
    let entries = russh::keys::known_hosts::known_host_keys_path(host, port, &path).map_err(|err| {
        Error::Other(format!("读 known_hosts（{}）失败：{err}", path.display()))
    })?;

    let mut keys = Vec::with_capacity(entries.len());
    for (_line, key) in entries {
        keys.push(key);
    }
    Ok(keys)
}

fn fingerprint(key: &PublicKey) -> String {
    key.fingerprint(HashAlg::Sha256).to_string()
}

/// 连接时遇到的、还没被信任的主机密钥。trust_host_key 只认这里记下的，
/// 界面只传指纹回来，不传密钥本身 —— 写进 known_hosts 的一定是真正从服务器上看到的那把
struct PendingKey {
    host: String,
    port: u16,
    key: PublicKey,
}

fn pending_keys() -> &'static Mutex<Vec<PendingKey>> {
    static PENDING: OnceLock<Mutex<Vec<PendingKey>>> = OnceLock::new();
    PENDING.get_or_init(|| Mutex::new(Vec::new()))
}

/// 信任一台主机的密钥：追加到 known_hosts。
///
/// 只接受本次运行里连接时看到过、并且报了「未知主机」的那把密钥，指纹要完全一致。
/// 写入前再对照一次：这期间 known_hosts 如果已经有了不同的记录，照样拒绝
pub fn trust_host_key(host: &str, port: u16, fingerprint_text: &str) -> Result<(), Error> {
    let key = {
        let pending = pending_keys().lock().unwrap();
        let mut found = None;
        for entry in pending.iter() {
            if entry.host == host && entry.port == port && fingerprint(&entry.key) == fingerprint_text {
                found = Some(entry.key.clone());
                break;
            }
        }
        found.ok_or_else(|| {
            Error::Other(format!(
                "没有 {host}:{port} 指纹为 {fingerprint_text} 的待确认密钥，请重新连接一次再确认"
            ))
        })?
    };

    match judge_host_key(&key, &recorded_keys(host, port)?) {
        HostKeyVerdict::Trusted => {}
        HostKeyVerdict::Mismatch => {
            return Err(Error::Other(format!(
                "known_hosts 里已经有 {host}:{port} 的另一把密钥，不能再追加，请先手动处理"
            )))
        }
        HostKeyVerdict::Unknown => {
            let path = known_hosts_path()?;
            russh::keys::known_hosts::learn_known_hosts_path(host, port, &key, &path).map_err(|err| {
                Error::Other(format!("写 known_hosts（{}）失败：{err}", path.display()))
            })?;
        }
    }

    pending_keys()
        .lock()
        .unwrap()
        .retain(|entry| !(entry.host == host && entry.port == port));
    Ok(())
}

/// russh 的回调：校验服务器密钥，把没通过的原因留给调用方
struct Verifier {
    host: String,
    port: u16,
    recorded: Vec<PublicKey>,
    problem: Arc<Mutex<Option<Error>>>,
}

impl client::Handler for Verifier {
    type Error = russh::Error;

    async fn check_server_key(&mut self, server_key: &PublicKeyOrCertificate) -> Result<bool, Self::Error> {
        let key = match server_key {
            PublicKeyOrCertificate::PublicKey { key, .. } => key,
            // 我们没有声明支持主机证书，服务器仍然出示证书就说明协商不对，拒绝
            PublicKeyOrCertificate::Certificate(_) => {
                *self.problem.lock().unwrap() = Some(Error::Other(format!(
                    "SSH 主机 {}:{} 出示的是证书，暂不支持 CA 签发的主机证书",
                    self.host, self.port
                )));
                return Ok(false);
            }
        };

        let verdict = judge_host_key(key, &self.recorded);
        if verdict == HostKeyVerdict::Trusted {
            return Ok(true);
        }

        let kind = if verdict == HostKeyVerdict::Unknown {
            let mut pending = pending_keys().lock().unwrap();
            pending.retain(|entry| !(entry.host == self.host && entry.port == self.port));
            pending.push(PendingKey { host: self.host.clone(), port: self.port, key: key.clone() });
            HostKeyIssueKind::Unknown
        } else {
            HostKeyIssueKind::Mismatch
        };
        *self.problem.lock().unwrap() = Some(Error::HostKey(HostKeyIssue {
            host: self.host.clone(),
            port: self.port,
            fingerprint: fingerprint(key),
            algorithm: key.algorithm().to_string(),
            kind,
        }));
        Ok(false)
    }
}

fn same_key_type(a: &Algorithm, b: &Algorithm) -> bool {
    match (a, b) {
        // ssh-rsa / rsa-sha2-256 / rsa-sha2-512 是同一把 RSA 密钥的不同签名方式
        (Algorithm::Rsa { .. }, Algorithm::Rsa { .. }) => true,
        _ => a == b,
    }
}

fn client_config(recorded: &[PublicKey]) -> Arc<client::Config> {
    let mut preferred = Preferred::default();
    let mut algorithms = preferred.key.to_vec();
    // 已记录的类型排前面（稳定排序，其余保持原顺序），服务器才会出示我们认得的那把密钥
    algorithms.sort_by_key(|algorithm| {
        !recorded.iter().any(|key| same_key_type(&key.algorithm(), algorithm))
    });
    preferred.key = algorithms.into();

    Arc::new(client::Config {
        preferred,
        // 隧道可能闲置很久，靠心跳发现对端已经没了；连续 3 次没回应就断开，下次用时重建
        keepalive_interval: Some(Duration::from_secs(15)),
        keepalive_max: 3,
        nodelay: true,
        ..Default::default()
    })
}

type Session = Handle<Verifier>;

/// 按顺序连上每一跳并认证。返回整条链：后面的会话跑在前面会话的通道上，前面的不能先释放
async fn connect_chain(hops: &[SshHop], secrets: &[Option<String>]) -> Result<Vec<Session>, Error> {
    let mut chain: Vec<Session> = Vec::with_capacity(hops.len());
    for (hop, secret) in hops.iter().zip(secrets) {
        let recorded = recorded_keys(&hop.host, hop.port)?;
        let config = client_config(&recorded);
        let problem = Arc::new(Mutex::new(None));
        let verifier = Verifier {
            host: hop.host.clone(),
            port: hop.port,
            recorded,
            problem: problem.clone(),
        };

        let connected = match chain.last() {
            None => client::connect(config, (hop.host.as_str(), hop.port), verifier).await,
            Some(previous) => {
                let channel = previous
                    .channel_open_direct_tcpip(hop.host.clone(), u32::from(hop.port), "127.0.0.1", 0)
                    .await
                    .map_err(|err| Error::Other(format!("跳板机没能转发到 {}：{err}", hop.label())))?;
                client::connect_stream(config, channel.into_stream(), verifier).await
            }
        };

        let mut session = match connected {
            Ok(session) => session,
            Err(err) => {
                if let Some(problem) = problem.lock().unwrap().take() {
                    return Err(problem);
                }
                return Err(Error::Other(format!("连不上 SSH 服务器 {}：{err}", hop.label())));
            }
        };
        authenticate(&mut session, hop, secret.as_deref()).await?;
        chain.push(session);
    }
    Ok(chain)
}

async fn authenticate(session: &mut Session, hop: &SshHop, secret: Option<&str>) -> Result<(), Error> {
    let label = hop.label();
    let result = match &hop.auth {
        SshAuth::Password => {
            let Some(password) = secret else {
                return Err(Error::Other(format!("{label} 用密码认证，但没有提供密码")));
            };
            session
                .authenticate_password(hop.user.clone(), password)
                .await
                .map_err(|err| Error::Other(format!("{label} 密码认证出错：{err}")))?
        }
        SshAuth::PrivateKey { path } => {
            let key = load_private_key(path, secret)?;
            let rsa_hash = session
                .best_supported_rsa_hash()
                .await
                .map_err(|err| Error::Other(format!("{label} 协商签名算法出错：{err}")))?
                .flatten();
            session
                .authenticate_publickey(hop.user.clone(), PrivateKeyWithHashAlg::new(Arc::new(key), rsa_hash))
                .await
                .map_err(|err| Error::Other(format!("{label} 私钥认证出错：{err}")))?
        }
        SshAuth::Agent => {
            if secret.is_some() {
                return Err(Error::Other(format!("{label} 用 ssh-agent 认证，不需要密码或口令")));
            }
            return authenticate_with_agent(session, hop).await;
        }
    };

    match result {
        AuthResult::Success => Ok(()),
        AuthResult::Failure { partial_success: true, .. } => Err(Error::Other(format!(
            "{label} 这一步认证通过了，但服务器还要求其他认证（多因素），暂不支持"
        ))),
        AuthResult::Failure { .. } => Err(Error::Other(format!("{label} 拒绝了认证"))),
    }
}

/// 读私钥。口令为 None 时只能读没加密的私钥
pub fn load_private_key(path: &str, passphrase: Option<&str>) -> Result<PrivateKey, Error> {
    match russh::keys::load_secret_key(path, passphrase) {
        Ok(key) => Ok(key),
        Err(russh::keys::Error::KeyIsEncrypted) => {
            Err(Error::Other(format!("私钥 {path} 设了口令，请提供口令")))
        }
        Err(err) if passphrase.is_some() => {
            Err(Error::Other(format!("读不了私钥 {path}（口令可能不对）：{err}")))
        }
        Err(err) => Err(Error::Other(format!("读不了私钥 {path}：{err}"))),
    }
}

async fn authenticate_with_agent(session: &mut Session, hop: &SshHop) -> Result<(), Error> {
    let label = hop.label();
    let mut agent = connect_agent().await?;
    let identities = agent
        .request_identities()
        .await
        .map_err(|err| Error::Other(format!("读取 ssh-agent 里的密钥失败：{err}")))?;
    let rsa_hash = session
        .best_supported_rsa_hash()
        .await
        .map_err(|err| Error::Other(format!("{label} 协商签名算法出错：{err}")))?
        .flatten();

    let mut tried = 0;
    for identity in identities {
        // agent 里的证书暂不支持，只用普通公钥
        let AgentIdentity::PublicKey { key, .. } = identity else {
            continue;
        };
        tried += 1;
        let hash = if key.algorithm().is_rsa() { rsa_hash } else { None };
        let result = session
            .authenticate_publickey_with(hop.user.clone(), key, hash, &mut agent)
            .await
            .map_err(|err| Error::Other(format!("{label} 用 ssh-agent 认证出错：{err}")))?;
        if matches!(result, AuthResult::Success) {
            return Ok(());
        }
    }

    if tried == 0 {
        return Err(Error::Other("ssh-agent 里没有可用的密钥".to_string()));
    }
    Err(Error::Other(format!("{label} 拒绝了 ssh-agent 里的全部 {tried} 把密钥")))
}

type Agent = AgentClient<Box<dyn AgentStream + Send + Unpin + 'static>>;

#[cfg(unix)]
async fn connect_agent() -> Result<Agent, Error> {
    let agent = AgentClient::connect_env()
        .await
        .map_err(|err| Error::Other(format!("连不上 ssh-agent（SSH_AUTH_SOCK）：{err}")))?;
    Ok(agent.dynamic())
}

/// Windows 自带 OpenSSH 的 agent 服务固定用这个命名管道。Pageant 暂不支持
#[cfg(windows)]
async fn connect_agent() -> Result<Agent, Error> {
    let agent = AgentClient::connect_named_pipe(r"\\.\pipe\openssh-ssh-agent")
        .await
        .map_err(|err| Error::Other(format!("连不上 Windows 的 ssh-agent 服务：{err}")))?;
    Ok(agent.dynamic())
}

struct Shared {
    hops: Vec<SshHop>,
    /// 断线后重建隧道要用，只在内存里
    secrets: Vec<Option<String>>,
    target_host: String,
    target_port: u16,
    connect_timeout: Option<Duration>,
    /// 空表示还没连上或者已经作废
    chain: tokio::sync::Mutex<Vec<Session>>,
    /// 转发时建隧道失败的原因。本地端口那头只能看到「连接被关闭」，真正的原因从这里取
    last_error: Mutex<Option<String>>,
}

impl Shared {
    async fn connect(&self) -> Result<Vec<Session>, Error> {
        let work = connect_chain(&self.hops, &self.secrets);
        let Some(limit) = self.connect_timeout else {
            return work.await;
        };
        match tokio::time::timeout(limit, work).await {
            Ok(result) => result,
            Err(_) => Err(Error::Other(format!("SSH 隧道 {} 秒内没有建立起来", limit.as_secs()))),
        }
    }

    /// 开一条到 MySQL 的转发通道。SSH 会话断了就先重建 —— 这里还没有任何语句，重建是安全的
    async fn open_channel(&self) -> Result<Channel<Msg>, Error> {
        let mut chain = self.chain.lock().await;
        let alive = !chain.is_empty() && chain.iter().all(|session| !session.is_closed());
        if !alive {
            chain.clear();
            *chain = self.connect().await?;
        }

        let Some(last) = chain.last() else {
            return Err(Error::Other("SSH 隧道没有可用的会话".to_string()));
        };
        let opened = last
            .channel_open_direct_tcpip(self.target_host.clone(), u32::from(self.target_port), "127.0.0.1", 0)
            .await;
        match opened {
            Ok(channel) => Ok(channel),
            Err(err) => {
                // 会话看着还在但开不了通道，下次用时整条链重建
                chain.clear();
                Err(Error::Other(format!(
                    "SSH 服务器没能转发到 MySQL {}:{}：{err}",
                    self.target_host, self.target_port
                )))
            }
        }
    }
}

/// 一条 SSH 隧道。drop 时停止监听，已有的转发随各自的连接结束
pub struct Tunnel {
    local_port: u16,
    shared: Arc<Shared>,
    accept_task: tokio::task::JoinHandle<()>,
}

impl Drop for Tunnel {
    fn drop(&mut self) {
        self.accept_task.abort();
    }
}

impl Tunnel {
    /// 连上 SSH 并开始在本地端口监听。SSH 这一步当场做完，主机密钥、认证的问题立刻暴露，
    /// 不拖到第一次查询时变成一句「连接被关闭」
    pub async fn open(
        hops: Vec<SshHop>,
        secrets: Vec<Option<String>>,
        target_host: String,
        target_port: u16,
        connect_timeout: Option<Duration>,
    ) -> Result<Tunnel, Error> {
        if hops.is_empty() {
            return Err(Error::Other("没有配置 SSH 主机".to_string()));
        }
        if secrets.len() != hops.len() {
            return Err(Error::Other(format!(
                "SSH 有 {} 跳，但给了 {} 份密码 / 口令",
                hops.len(),
                secrets.len()
            )));
        }

        let shared = Arc::new(Shared {
            hops,
            secrets,
            target_host,
            target_port,
            connect_timeout,
            chain: tokio::sync::Mutex::new(Vec::new()),
            last_error: Mutex::new(None),
        });
        let chain = shared.connect().await?;
        *shared.chain.lock().await = chain;

        // 只听回环地址，不对局域网开放
        let listener = TcpListener::bind(("127.0.0.1", 0))
            .await
            .map_err(|err| Error::Other(format!("开本地转发端口失败：{err}")))?;
        let local_port = listener
            .local_addr()
            .map_err(|err| Error::Other(format!("读本地转发端口失败：{err}")))?
            .port();

        let accept_task = tokio::spawn(accept_loop(listener, shared.clone()));
        Ok(Tunnel { local_port, shared, accept_task })
    }

    pub fn local_port(&self) -> u16 {
        self.local_port
    }

    /// 取出最近一次转发失败的原因
    pub fn take_error(&self) -> Option<String> {
        self.shared.last_error.lock().unwrap().take()
    }
}

async fn accept_loop(listener: TcpListener, shared: Arc<Shared>) {
    loop {
        let mut socket = match listener.accept().await {
            Ok((socket, _)) => socket,
            Err(_) => {
                // 文件句柄耗尽之类的临时错误，歇一下再接，免得空转
                tokio::time::sleep(Duration::from_millis(200)).await;
                continue;
            }
        };
        let shared = shared.clone();
        tokio::spawn(async move {
            match shared.open_channel().await {
                Ok(channel) => {
                    let mut stream = channel.into_stream();
                    // 任何一头断开都结束转发；mysql_async 那头自己会看到连接断了并报错
                    let _ = tokio::io::copy_bidirectional(&mut socket, &mut stream).await;
                }
                Err(err) => {
                    // socket 随之关闭，MySQL 的连接尝试立刻失败，原因从 take_error 取
                    *shared.last_error.lock().unwrap() = Some(err.to_string());
                }
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use russh::keys::ssh_key::private::Ed25519Keypair;
    use russh::keys::EcdsaCurve;

    /// 固定种子生成一次性密钥，不往仓库里放任何密钥文件
    fn ed25519(seed: u8) -> PrivateKey {
        PrivateKey::from(Ed25519Keypair::from_seed(&[seed; 32]))
    }

    fn ecdsa() -> PrivateKey {
        PrivateKey::random(&mut rand::rng(), Algorithm::Ecdsa { curve: EcdsaCurve::NistP256 }).unwrap()
    }

    #[test]
    fn host_key_verdicts() {
        let a = ed25519(1).public_key().clone();
        let b = ed25519(2).public_key().clone();
        assert_eq!(judge_host_key(&a, &[]), HostKeyVerdict::Unknown);
        assert_eq!(judge_host_key(&a, &[b.clone(), a.clone()]), HostKeyVerdict::Trusted);
        assert_eq!(judge_host_key(&a, &[b]), HostKeyVerdict::Mismatch);
    }

    #[test]
    fn a_different_key_type_counts_as_mismatch() {
        // 记录的是 ECDSA，服务器出示 ed25519：不能当成「没见过」让用户点一下信任就过去
        let recorded = ecdsa().public_key().clone();
        assert_eq!(judge_host_key(ed25519(1).public_key(), &[recorded]), HostKeyVerdict::Mismatch);
    }

    #[test]
    fn preferred_host_key_types_follow_known_hosts() {
        let recorded = ecdsa().public_key().clone();
        let config = client_config(std::slice::from_ref(&recorded));
        assert_eq!(config.preferred.key[0], recorded.algorithm(), "已记录的类型要排第一：{:?}", config.preferred.key);

        let default_order = Preferred::default().key.to_vec();
        assert_eq!(client_config(&[]).preferred.key.to_vec(), default_order, "没有记录时保持默认顺序");
    }

    /// known_hosts 的读、判定、信任、再读是一条完整的往返。用临时文件，不碰用户的 ~/.ssh
    #[test]
    fn trust_writes_known_hosts_and_refuses_what_was_never_seen() {
        let a = ed25519(1).public_key().clone();
        let b = ed25519(2).public_key().clone();

        let dir = std::env::temp_dir().join(format!("cdata-ssh-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("known_hosts");
        let line_b = b.to_openssh().unwrap();
        std::fs::write(&path, format!("# 注释\n[bastion.example]:2222 {line_b}\n")).unwrap();
        // SAFETY: 这个环境变量只有本测试用，同进程里没有别的测试读写它
        unsafe { std::env::set_var("CDATA_KNOWN_HOSTS_PATH", &path) };

        // 非 22 端口按 [host]:port 匹配，22 端口按裸主机名
        assert_eq!(recorded_keys("bastion.example", 2222).unwrap(), vec![b.clone()]);
        assert!(recorded_keys("bastion.example", 22).unwrap().is_empty());

        // 没在连接时见过的密钥，指纹对了也不能信任
        assert!(trust_host_key("db.example", 22, &fingerprint(&a)).is_err());

        // 模拟一次连接时看到了未知主机
        pending_keys().lock().unwrap().push(PendingKey { host: "db.example".into(), port: 22, key: a.clone() });
        // 指纹对不上的不写
        assert!(trust_host_key("db.example", 22, &fingerprint(&b)).is_err());
        trust_host_key("db.example", 22, &fingerprint(&a)).unwrap();
        assert_eq!(judge_host_key(&a, &recorded_keys("db.example", 22).unwrap()), HostKeyVerdict::Trusted);
        // 原有的行还在
        assert_eq!(recorded_keys("bastion.example", 2222).unwrap(), vec![b.clone()]);

        // 已有记录的主机出现另一把密钥：拒绝追加
        pending_keys().lock().unwrap().push(PendingKey { host: "bastion.example".into(), port: 2222, key: a.clone() });
        let err = trust_host_key("bastion.example", 2222, &fingerprint(&a)).unwrap_err();
        assert!(err.to_string().contains("另一把密钥"), "{err}");

        unsafe { std::env::remove_var("CDATA_KNOWN_HOSTS_PATH") };
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn encrypted_private_key_needs_the_right_passphrase() {
        use russh::keys::ssh_key::LineEnding;

        let dir = std::env::temp_dir().join(format!("cdata-ssh-key-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("id_ed25519");

        let plain = ed25519(7);
        let encrypted = plain.encrypt(&mut rand::rng(), "correct horse").unwrap();
        std::fs::write(&path, encrypted.to_openssh(LineEnding::LF).unwrap().as_bytes()).unwrap();
        let path_text = path.to_string_lossy().into_owned();

        let err = load_private_key(&path_text, None).unwrap_err().to_string();
        assert!(err.contains("设了口令"), "{err}");
        let err = load_private_key(&path_text, Some("wrong")).unwrap_err().to_string();
        assert!(err.contains("口令可能不对"), "{err}");
        let loaded = load_private_key(&path_text, Some("correct horse")).unwrap();
        assert_eq!(loaded.public_key(), plain.public_key());

        std::fs::remove_dir_all(&dir).ok();
    }
}
