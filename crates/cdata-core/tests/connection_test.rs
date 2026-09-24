//! 连接增强：SSL、超时、断线重连、SSH 隧道。
//!
//! 连真库的部分从 CDATA_TEST_* 环境变量读连接信息，没配就跳过。
//! SSH 隧道用进程内的 russh 服务端来测，不依赖本机 sshd，也不改任何系统设置。

use std::time::{Duration, Instant};

use russh::keys::PublicKey;

use cdata_core::db::ConnectionConfig;
use cdata_core::options::{ConnectionOptions, SshAuth, SshHop, SslMode};
use cdata_core::session::{self, Error};
use cdata_core::ssh::HostKeyIssueKind;
use cdata_core::CellValue;

fn config_from_env() -> Option<ConnectionConfig> {
    Some(ConnectionConfig {
        host: std::env::var("CDATA_TEST_HOST").ok()?,
        port: std::env::var("CDATA_TEST_PORT").ok()?.parse().ok()?,
        user: std::env::var("CDATA_TEST_USER").ok()?,
        password: std::env::var("CDATA_TEST_PASSWORD").ok()?,
        database: Some(std::env::var("CDATA_TEST_DB").ok()?),
        options: ConnectionOptions::default(),
        ssh_secrets: Vec::new(),
        saved_id: None,
    })
}

/// 跑一条查询，取第一行第一列
async fn first_cell(session_id: u64, sql: &str) -> Result<CellValue, Error> {
    session::execute(session_id, sql, 10).await?;
    let rows = session::fetch_window(session_id, 0, 1)?;
    Ok(rows[0][0].clone())
}

fn text(value: CellValue) -> String {
    match value {
        CellValue::Text(text) => text,
        other => panic!("预期文本，实际 {other:?}"),
    }
}

fn int(value: CellValue) -> i64 {
    match value {
        CellValue::Int(n) => n,
        CellValue::UInt(n) => n as i64,
        other => panic!("预期整数，实际 {other:?}"),
    }
}

#[tokio::test]
async fn connections_go_over_tcp_not_a_local_unix_socket() {
    let Some(config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };

    // mysql_async 默认会读服务器的 @@socket 再去连本机同名 socket。
    // 走 TCP 时 PROCESSLIST 的 HOST 带端口（host:port），走 unix socket 时只有 localhost
    let id = session::open_session(&config).await.unwrap();
    let host = text(
        first_cell(id, "SELECT HOST FROM information_schema.PROCESSLIST WHERE ID = CONNECTION_ID()")
            .await
            .unwrap(),
    );
    assert!(host.contains(':'), "应该走 TCP，实际客户端地址是 {host}");
    session::close_session(id).await.ok();
}

#[tokio::test]
async fn ssl_required_encrypts_and_disabled_does_not() {
    let Some(mut config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };

    let plain = session::open_session(&config).await.unwrap();
    let cipher = first_cell(plain, "SELECT VARIABLE_VALUE FROM performance_schema.session_status WHERE VARIABLE_NAME = 'Ssl_cipher'")
        .await
        .unwrap();
    assert_eq!(text(cipher), "", "Disabled 不应该加密");
    session::close_session(plain).await.ok();

    config.options.ssl.mode = SslMode::Required;
    let encrypted = session::open_session(&config).await.unwrap();
    let cipher = first_cell(encrypted, "SELECT VARIABLE_VALUE FROM performance_schema.session_status WHERE VARIABLE_NAME = 'Ssl_cipher'")
        .await
        .unwrap();
    assert_ne!(text(cipher), "", "Required 必须加密");
    session::close_session(encrypted).await.ok();
}

#[tokio::test]
async fn ssl_verify_identity_rejects_a_certificate_it_cannot_trust() {
    let Some(mut config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };

    // 不给 CA 就只信内置的公共根证书；测试库用的是自签证书，必须被拒绝，而且是在连接阶段
    config.options.ssl.mode = SslMode::VerifyIdentity;
    let id = session::open_session(&config).await.unwrap();
    let err = session::execute(id, "SELECT 1", 10).await.unwrap_err();
    assert!(matches!(err, Error::Connect(_)), "证书不可信应该是连接失败：{err}");
    session::close_session(id).await.ok();

    // 给了 CA（CDATA_TEST_SSL_CA）：证书链要能验过。之后要么连上且加密，
    // 要么只卡在主机名上（MySQL 自动生成的证书没有 subjectAltName），不能再是「不认识签发者」
    let Ok(ca_path) = std::env::var("CDATA_TEST_SSL_CA") else {
        eprintln!("跳过 CA 部分：未配置 CDATA_TEST_SSL_CA");
        return;
    };
    config.options.ssl.ca_path = Some(ca_path);
    let id = session::open_session(&config).await.unwrap();
    match session::execute(id, "SELECT 1", 10).await {
        Ok(_) => {}
        Err(err) => {
            let message = err.to_string();
            assert!(!message.contains("UnknownIssuer"), "给了 CA 仍然不认识签发者：{message}");
            assert!(message.contains("not valid for name"), "预期只卡在主机名校验上：{message}");
        }
    }
    session::close_session(id).await.ok();
}

#[tokio::test]
async fn contradictory_ssl_options_are_rejected_before_connecting() {
    let Some(mut config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };
    config.options.ssl.ca_path = Some("/nonexistent/ca.pem".into());
    let err = session::open_session(&config).await.unwrap_err();
    assert!(matches!(err, Error::BadInput(_)), "{err}");
}

/// 不需要真库：本地开一个只接受 TCP、从不发 MySQL 握手的端口
#[tokio::test]
async fn connect_timeout_gives_up_on_a_silent_server() {
    let silent = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let mut options = ConnectionOptions::default();
    options.timeouts.connect_secs = Some(1);
    let config = ConnectionConfig {
        host: "127.0.0.1".into(),
        port: silent.local_addr().unwrap().port(),
        user: "nobody".into(),
        password: String::new(),
        database: None,
        options,
        ssh_secrets: Vec::new(),
        saved_id: None,
    };

    let id = session::open_session(&config).await.unwrap();
    let started = Instant::now();
    let err = session::execute(id, "SELECT 1", 10).await.unwrap_err();
    assert!(started.elapsed() < Duration::from_secs(3), "连接超时没生效：{:?}", started.elapsed());
    match err {
        Error::Connect(message) => assert!(message.contains("1 秒内没有连上"), "{message}"),
        other => panic!("预期连接失败，实际 {other}"),
    }
    session::close_session(id).await.ok();
}

#[tokio::test]
async fn query_timeout_stops_the_statement_on_the_server() {
    let Some(config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };
    let mut limited = config.clone();
    limited.options.timeouts.query_secs = Some(1);

    let probe = format!("cdata_timeout_probe_{}", std::process::id());
    let id = session::open_session(&limited).await.unwrap();
    let started = Instant::now();
    let err = session::execute(id, &format!("SELECT SLEEP(5) AS {probe}"), 10).await.unwrap_err();
    let elapsed = started.elapsed();

    // SLEEP 被 KILL QUERY 打断时返回 1 而不报错 —— 不能因此把它当成正常完成
    match &err {
        Error::QueryTimeout(message) => assert!(message.contains("已让服务器停止"), "{message}"),
        other => panic!("预期查询超时，实际 {other}"),
    }
    assert!(elapsed < Duration::from_secs(4), "超时后要立刻停，实际等了 {elapsed:?}");

    // 用另一条不限时的会话到服务器上确认这条语句已经没了。
    // 查询条件拆开拼，免得这条查询自己的文本也匹配上
    let observer = session::open_session(&config).await.unwrap();
    let running = int(
        first_cell(
            observer,
            &format!(
                "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE INFO LIKE CONCAT('%cdata_timeout', '_probe_{}%')",
                std::process::id()
            ),
        )
        .await
        .unwrap(),
    );
    assert_eq!(running, 0, "超时的语句还在服务器上跑");

    // 被打断的连接状态是干净的，同一个会话接着能用
    assert_eq!(int(first_cell(id, "SELECT 1").await.unwrap()), 1);
    session::close_session(id).await.ok();
    session::close_session(observer).await.ok();
}

#[tokio::test]
async fn idle_connection_dropped_by_the_server_is_replaced_on_next_use() {
    let Some(config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };

    let id = session::open_session(&config).await.unwrap();
    let before = int(first_cell(id, "SELECT CONNECTION_ID()").await.unwrap());

    // 模拟服务器重启 / wait_timeout：从别的连接把它踢掉（这时它在池里闲着）
    // 先等连接池把它 reset 完：KILL 落在 COM_RESET_CONNECTION 途中会被 reset 清掉
    tokio::time::sleep(Duration::from_millis(300)).await;
    let killer = session::open_session(&config).await.unwrap();
    session::execute(killer, &format!("KILL {before}"), 10).await.unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;
    let alive = int(
        first_cell(killer, &format!("SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE ID = {before}"))
            .await
            .unwrap(),
    );
    assert_eq!(alive, 0, "前提不成立：连接没被踢掉");

    // 下一次操作自动换一条新连接，不报错
    let after = int(first_cell(id, "SELECT CONNECTION_ID()").await.unwrap());
    assert_ne!(before, after, "应该换了一条新连接");

    session::close_session(id).await.ok();
    session::close_session(killer).await.ok();
}

#[tokio::test]
async fn connection_lost_mid_statement_is_reported_as_uncertain_and_not_retried() {
    let Some(config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };

    let id = session::open_session(&config).await.unwrap();
    let probe = format!("cdata_lost_probe_{}", std::process::id());
    let sql = format!("SELECT SLEEP(3) AS {probe}");
    let running = tokio::spawn(async move { session::execute(id, &sql, 10).await });
    tokio::time::sleep(Duration::from_millis(500)).await;

    // 连接归还池子是异步的，不能假设 SLEEP 用的就是上一条语句的连接，到进程列表里按语句找。
    // 查询条件拆开拼，免得这条查询自己的文本也匹配上
    let killer = session::open_session(&config).await.unwrap();
    let connection_id = int(
        first_cell(
            killer,
            &format!(
                "SELECT ID FROM information_schema.PROCESSLIST WHERE INFO LIKE CONCAT('%cdata_lost', '_probe_{}%')",
                std::process::id()
            ),
        )
        .await
        .unwrap(),
    );
    session::execute(killer, &format!("KILL {connection_id}"), 10).await.unwrap();

    let started = Instant::now();
    let outcome = running.await.unwrap();
    // 要是偷偷重试了，这里会在又一个 3 秒后返回成功
    assert!(started.elapsed() < Duration::from_secs(2), "等太久了，像是被重试了：{:?}", started.elapsed());
    match outcome {
        Err(Error::ConnectionLost(_)) => {}
        Err(other) => panic!("预期断线错误，实际 {other}"),
        Ok(_) => panic!("连接被踢掉了，语句不应该成功"),
    }
    let message = Error::ConnectionLost("x".into()).to_string();
    assert!(message.contains("可能已经执行，也可能没有执行"), "{message}");

    // 之后照常能用
    assert_eq!(int(first_cell(id, "SELECT 1").await.unwrap()), 1);
    session::close_session(id).await.ok();
    session::close_session(killer).await.ok();
}

// ---- SSH：进程内的 russh 服务端 ----

mod fake_sshd {
    use std::sync::{Arc, Mutex};

    use russh::keys::ssh_key::private::Ed25519Keypair;
    use russh::keys::{PrivateKey, PublicKey};
    use russh::server::{self, Auth, Msg, Session};
    use russh::{Channel, ChannelOpenFailure};
    use tokio::net::{TcpListener, TcpStream};

    pub fn host_key(seed: u8) -> PrivateKey {
        PrivateKey::from(Ed25519Keypair::from_seed(&[seed; 32]))
    }

    /// 只接受一个密码或一把公钥，支持 direct-tcpip 转发
    #[derive(Clone)]
    pub struct Credentials {
        pub password: Option<String>,
        pub public_key: Option<PublicKey>,
    }

    struct Handler {
        credentials: Credentials,
    }

    impl server::Handler for Handler {
        type Error = russh::Error;

        async fn auth_password(&mut self, _user: &str, password: &str) -> Result<Auth, Self::Error> {
            if self.credentials.password.as_deref() == Some(password) {
                return Ok(Auth::Accept);
            }
            Ok(Auth::reject())
        }

        async fn auth_publickey(&mut self, _user: &str, key: &PublicKey) -> Result<Auth, Self::Error> {
            if self.credentials.public_key.as_ref() == Some(key) {
                return Ok(Auth::Accept);
            }
            Ok(Auth::reject())
        }

        async fn channel_open_direct_tcpip(
            &mut self,
            channel: Channel<Msg>,
            host: &str,
            port: u32,
            _originator_address: &str,
            _originator_port: u32,
            reply: server::ChannelOpenHandle,
            _session: &mut Session,
        ) -> Result<(), Self::Error> {
            let target = (host.to_string(), port as u16);
            tokio::spawn(async move {
                match TcpStream::connect(target).await {
                    Ok(mut tcp) => {
                        reply.accept().await;
                        let mut stream = channel.into_stream();
                        let _ = tokio::io::copy_bidirectional(&mut tcp, &mut stream).await;
                    }
                    Err(_) => reply.reject(ChannelOpenFailure::ConnectFailed).await,
                }
            });
            Ok(())
        }
    }

    pub struct Server {
        pub port: u16,
        /// 已建立的会话，测试里用来模拟服务端断开
        pub sessions: Arc<Mutex<Vec<server::Handle>>>,
    }

    pub async fn start(key: PrivateKey, credentials: Credentials) -> Server {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let config = Arc::new(server::Config {
            keys: vec![key],
            auth_rejection_time: std::time::Duration::from_millis(10),
            auth_rejection_time_initial: Some(std::time::Duration::ZERO),
            ..Default::default()
        });
        let sessions = Arc::new(Mutex::new(Vec::new()));
        let registry = sessions.clone();
        tokio::spawn(async move {
            loop {
                let Ok((socket, _)) = listener.accept().await else { continue };
                let handler = Handler { credentials: credentials.clone() };
                if let Ok(running) = server::run_stream(config.clone(), socket, handler).await {
                    registry.lock().unwrap().push(running.handle());
                    tokio::spawn(running);
                }
            }
        });
        Server { port, sessions }
    }
}

fn hop(port: u16, auth: SshAuth) -> SshHop {
    SshHop { host: "127.0.0.1".into(), port, user: "tester".into(), auth }
}

/// 打开会话；遇到未知主机就确认指纹再开一次，模拟用户点了「信任」
async fn open_trusting(config: &ConnectionConfig, expected_port: u16, expected_key: &PublicKey) -> u64 {
    let err = session::open_session(config).await.unwrap_err();
    let issue = err.host_key_issue().unwrap_or_else(|| panic!("预期未知主机，实际 {err}")).clone();
    assert_eq!(issue.kind, HostKeyIssueKind::Unknown);
    assert_eq!(issue.port, expected_port);
    assert_eq!(issue.fingerprint, expected_key.fingerprint(russh::keys::HashAlg::Sha256).to_string());
    assert!(err.to_string().contains(&issue.fingerprint), "错误信息里要带指纹：{err}");

    cdata_core::ssh::trust_host_key(&issue.host, issue.port, &issue.fingerprint).unwrap();
    session::open_session(config).await.unwrap()
}

/// 一个用例里把 SSH 的流程串起来：known_hosts 用临时文件，环境变量只有这里设
#[tokio::test(flavor = "multi_thread")]
async fn ssh_tunnel_end_to_end_with_a_local_russh_server() {
    let Some(config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };

    let dir = std::env::temp_dir().join(format!("cdata-ssh-e2e-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let known_hosts = dir.join("known_hosts");
    // SAFETY: 本测试文件里只有这个用例读写这个环境变量
    unsafe { std::env::set_var("CDATA_KNOWN_HOSTS_PATH", &known_hosts) };

    // 跳板机：密码认证
    let jump_key = fake_sshd::host_key(11);
    let jump = fake_sshd::start(
        jump_key.clone(),
        fake_sshd::Credentials { password: Some("jump-pass".into()), public_key: None },
    )
    .await;

    // 目标机：带口令的私钥认证
    let user_key = fake_sshd::host_key(21);
    let key_path = dir.join("id_ed25519");
    let encrypted = user_key.encrypt(&mut rand::rng(), "key-pass").unwrap();
    std::fs::write(&key_path, encrypted.to_openssh(russh::keys::ssh_key::LineEnding::LF).unwrap().as_bytes()).unwrap();
    let target_key = fake_sshd::host_key(12);
    let target = fake_sshd::start(
        target_key.clone(),
        fake_sshd::Credentials { password: None, public_key: Some(user_key.public_key().clone()) },
    )
    .await;

    // 1. 单跳密码：先报未知主机，信任后连通
    let mut single = config.clone();
    single.options.ssh.hops = vec![hop(jump.port, SshAuth::Password)];
    single.ssh_secrets = vec![Some("jump-pass".into())];
    let id = open_trusting(&single, jump.port, jump_key.public_key()).await;
    assert_eq!(int(first_cell(id, "SELECT 1").await.unwrap()), 1);

    // 2. SSH 会话被服务端断掉之后，下一次操作自动重建隧道并换新连接
    for handle in jump.sessions.lock().unwrap().drain(..) {
        tokio::spawn(async move {
            let _ = handle.disconnect(russh::Disconnect::ByApplication, "bye".into(), "en".into()).await;
        });
    }
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(int(first_cell(id, "SELECT 2").await.unwrap()), 2, "隧道断了之后应该自动重建");
    session::close_session(id).await.ok();

    // 3. 密码错：认证失败，信息里不出现密码
    let mut wrong = single.clone();
    wrong.ssh_secrets = vec![Some("not-the-password".into())];
    let err = session::open_session(&wrong).await.unwrap_err().to_string();
    assert!(err.contains("拒绝了认证"), "{err}");
    assert!(!err.contains("not-the-password"), "错误信息里不能带密码：{err}");

    // 4. 跳板机 + 带口令的私钥
    let mut jumped = config.clone();
    jumped.options.ssh.hops = vec![
        hop(jump.port, SshAuth::Password),
        hop(target.port, SshAuth::PrivateKey { path: key_path.to_string_lossy().into_owned() }),
    ];
    jumped.ssh_secrets = vec![Some("jump-pass".into()), Some("key-pass".into())];
    let id = open_trusting(&jumped, target.port, target_key.public_key()).await;
    assert_eq!(int(first_cell(id, "SELECT 3").await.unwrap()), 3);
    session::close_session(id).await.ok();

    // 5. 主机密钥和记录对不上：拒绝，也不能靠 trust_host_key 绕过去
    let impostor = fake_sshd::start(
        fake_sshd::host_key(13),
        fake_sshd::Credentials { password: Some("jump-pass".into()), public_key: None },
    )
    .await;
    let recorded = jump_key.public_key().to_openssh().unwrap();
    let mut lines = std::fs::read_to_string(&known_hosts).unwrap();
    lines.push_str(&format!("[127.0.0.1]:{} {recorded}\n", impostor.port));
    std::fs::write(&known_hosts, lines).unwrap();

    let mut spoofed = single.clone();
    spoofed.options.ssh.hops = vec![hop(impostor.port, SshAuth::Password)];
    let err = session::open_session(&spoofed).await.unwrap_err();
    let issue = err.host_key_issue().unwrap_or_else(|| panic!("预期主机密钥不符，实际 {err}")).clone();
    assert_eq!(issue.kind, HostKeyIssueKind::Mismatch);
    assert!(cdata_core::ssh::trust_host_key(&issue.host, issue.port, &issue.fingerprint).is_err());

    unsafe { std::env::remove_var("CDATA_KNOWN_HOSTS_PATH") };
    std::fs::remove_dir_all(&dir).ok();
}

/// 真 sshd 的冒烟测试。需要：
/// CDATA_TEST_SSH_HOST / CDATA_TEST_SSH_PORT / CDATA_TEST_SSH_USER，
/// 认证三选一：CDATA_TEST_SSH_PASSWORD，或 CDATA_TEST_SSH_KEY（可选 CDATA_TEST_SSH_KEY_PASSPHRASE），
/// 或 CDATA_TEST_SSH_AGENT=1；
/// 以及从 SSH 服务器看过去的 MySQL 地址 CDATA_TEST_SSH_MYSQL_HOST / CDATA_TEST_SSH_MYSQL_PORT。
/// 主机必须已经在 ~/.ssh/known_hosts 里（这个测试不替你信任任何主机）
#[tokio::test]
async fn ssh_tunnel_against_a_real_sshd() {
    let Some(mut config) = config_from_env() else {
        eprintln!("跳过：未配置 CDATA_TEST_* 环境变量");
        return;
    };
    let (Ok(host), Ok(port), Ok(user), Ok(mysql_host), Ok(mysql_port)) = (
        std::env::var("CDATA_TEST_SSH_HOST"),
        std::env::var("CDATA_TEST_SSH_PORT"),
        std::env::var("CDATA_TEST_SSH_USER"),
        std::env::var("CDATA_TEST_SSH_MYSQL_HOST"),
        std::env::var("CDATA_TEST_SSH_MYSQL_PORT"),
    ) else {
        eprintln!("跳过：未配置 CDATA_TEST_SSH_* 环境变量");
        return;
    };

    let (auth, secret) = if let Ok(password) = std::env::var("CDATA_TEST_SSH_PASSWORD") {
        (SshAuth::Password, Some(password))
    } else if let Ok(path) = std::env::var("CDATA_TEST_SSH_KEY") {
        (SshAuth::PrivateKey { path }, std::env::var("CDATA_TEST_SSH_KEY_PASSPHRASE").ok())
    } else if std::env::var("CDATA_TEST_SSH_AGENT").is_ok() {
        (SshAuth::Agent, None)
    } else {
        eprintln!("跳过：没有配置 SSH 认证方式");
        return;
    };

    config.host = mysql_host;
    config.port = mysql_port.parse().unwrap();
    config.options.ssh.hops = vec![SshHop { host, port: port.parse().unwrap(), user, auth }];
    config.ssh_secrets = vec![secret];
    let id = session::open_session(&config).await.unwrap();
    assert_eq!(int(first_cell(id, "SELECT 1").await.unwrap()), 1);
    session::close_session(id).await.ok();
}
