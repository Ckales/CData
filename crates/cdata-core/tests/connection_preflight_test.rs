//! Deterministic connection checkout tests against a tiny local MySQL protocol peer.
//! No database server, SQL fixture, or external credentials are involved.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use cdata_core::db::{open_pool, run_sql_import, ConnectionConfig};
use cdata_core::options::ConnectionOptions;
use cdata_core::sql_import::ImportStatement;
use mysql_async::prelude::Queryable;

fn packet(stream: &mut TcpStream) -> Vec<u8> {
    let mut header = [0u8; 4];
    stream.read_exact(&mut header).expect("read packet header");
    let len =
        usize::from(header[0]) | (usize::from(header[1]) << 8) | (usize::from(header[2]) << 16);
    let mut body = vec![0; len];
    stream.read_exact(&mut body).expect("read packet body");
    body
}

fn send_packet(stream: &mut TcpStream, seq: u8, body: &[u8]) {
    let len = body.len();
    stream
        .write_all(&[len as u8, (len >> 8) as u8, (len >> 16) as u8, seq])
        .expect("write packet header");
    stream.write_all(body).expect("write packet body");
}

fn ok_packet(stream: &mut TcpStream, seq: u8) {
    // OK, affected rows 0, insert id 0, status AUTOCOMMIT, warnings 0.
    send_packet(stream, seq, &[0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00]);
}

fn handshake(stream: &mut TcpStream, id: u32) {
    const CAPS: u32 = 0x0008_8200; // PROTOCOL_41 | SECURE_CONNECTION | PLUGIN_AUTH
    let mut greeting = vec![10];
    greeting.extend_from_slice(b"8.0.0-test\0");
    greeting.extend_from_slice(&id.to_le_bytes());
    greeting.extend_from_slice(b"12345678");
    greeting.push(0);
    greeting.extend_from_slice(&(CAPS as u16).to_le_bytes());
    greeting.push(45); // utf8mb4_general_ci
    greeting.extend_from_slice(&0x0002u16.to_le_bytes());
    greeting.extend_from_slice(&((CAPS >> 16) as u16).to_le_bytes());
    greeting.push(21);
    greeting.extend_from_slice(&[0; 10]);
    greeting.extend_from_slice(b"abcdefghijkl\0");
    greeting.extend_from_slice(b"mysql_native_password\0");
    send_packet(stream, 0, &greeting);
    let _client_response = packet(stream);
    ok_packet(stream, 2);
}

fn next_command(stream: &mut TcpStream) -> (u8, Vec<u8>) {
    let mut header = [0u8; 4];
    stream.read_exact(&mut header).expect("read command header");
    let len =
        usize::from(header[0]) | (usize::from(header[1]) << 8) | (usize::from(header[2]) << 16);
    let mut body = vec![0; len];
    stream.read_exact(&mut body).expect("read command body");
    (body[0], body[1..].to_vec())
}

fn is_setup(payload: &[u8]) -> bool {
    payload.starts_with(b"SET NAMES utf8mb4")
}

fn eof_packet(stream: &mut TcpStream, seq: u8) {
    send_packet(stream, seq, &[0xfe, 0x00, 0x00, 0x02, 0x00]);
}

fn lenenc_string(out: &mut Vec<u8>, value: &[u8]) {
    assert!(value.len() < 251);
    out.push(value.len() as u8);
    out.extend_from_slice(value);
}

fn column_packet(name: &[u8]) -> Vec<u8> {
    let mut column = Vec::new();
    for part in [b"def".as_slice(), b"", b"", b"", name, name] {
        lenenc_string(&mut column, part);
    }
    column.push(0x0c); // fixed length fields follow
    column.extend_from_slice(&45u16.to_le_bytes());
    column.extend_from_slice(&20u32.to_le_bytes());
    column.push(0x08); // MYSQL_TYPE_LONGLONG
    column.extend_from_slice(&0u16.to_le_bytes());
    column.push(0);
    column.extend_from_slice(&[0, 0]);
    column
}

fn query_reply(stream: &mut TcpStream, payload: &[u8]) {
    if is_setup(payload) {
        ok_packet(stream, 1);
    } else if payload.starts_with(b"SELECT @@max_allowed_packet,@@wait_timeout") {
        send_packet(stream, 1, &[2]); // two columns
        send_packet(stream, 2, &column_packet(b"@@max_allowed_packet"));
        send_packet(stream, 3, &column_packet(b"@@wait_timeout"));
        eof_packet(stream, 4);
        let mut row = Vec::new();
        lenenc_string(&mut row, b"4194304");
        lenenc_string(&mut row, b"28800");
        send_packet(stream, 5, &row);
        eof_packet(stream, 6);
    } else {
        ok_packet(stream, 1);
    }
}

fn config(port: u16, connect_secs: u32) -> ConnectionConfig {
    let mut options = ConnectionOptions::default();
    options.timeouts.connect_secs = Some(connect_secs);
    ConnectionConfig {
        host: "127.0.0.1".into(),
        port,
        user: "synthetic_test_user".into(),
        password: String::new(),
        database: None,
        options,
        ssh_secrets: Vec::new(),
        saved_id: None,
    }
}

#[tokio::test]
async fn get_conn_pings_before_business_query() {
    let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        handshake(&mut stream, 1);
        let mut commands = Vec::new();
        loop {
            let (command, payload) = next_command(&mut stream);
            commands.push((command, payload.clone()));
            match command {
                0x0e => ok_packet(&mut stream, 1), // COM_PING
                0x03 => {
                    let is_business =
                        String::from_utf8_lossy(&payload).contains("cdata_test_preflight");
                    query_reply(&mut stream, &payload);
                    if is_business {
                        break;
                    }
                }
                other => assert_eq!(other, 0x03, "unexpected MySQL command"),
            }
        }
        commands
    });

    let pool = open_pool(&config(port, 2)).await.unwrap();
    let mut conn = pool.get_conn().await.expect("checkout should pass ping");
    conn.query_drop("SET @cdata_test_preflight = 1")
        .await
        .unwrap();
    let commands = server.join().unwrap();
    let ping = commands.iter().position(|(code, _)| *code == 0x0e);
    let business = commands.iter().position(|(code, payload)| {
        *code == 0x03 && String::from_utf8_lossy(payload).contains("cdata_test_preflight")
    });
    assert!(
        ping.is_some(),
        "get_conn must issue COM_PING before returning a connection; commands: {commands:?}"
    );
    assert!(
        business.is_some(),
        "business query should reach the fake server"
    );
    assert!(
        ping.unwrap() < business.unwrap(),
        "COM_PING must precede business SQL: {commands:?}"
    );
}

#[tokio::test]
async fn failed_ping_discards_connection_and_retries_with_a_fresh_one() {
    let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let port = listener.local_addr().unwrap().port();
    let (tx, rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let (mut old, _) = listener.accept().unwrap();
        old.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
        handshake(&mut old, 11);
        // mysql_async may apply configured setup on creation and pool checkout.
        loop {
            let (command, payload) = next_command(&mut old);
            if command == 0x03 {
                query_reply(&mut old, &payload);
                continue;
            }
            if command == 0x0e {
                break;
            }
            panic!("unexpected preflight command {command:#x}");
        }
        // Return a protocol ERR for the ping. The checkout must discard this connection.
        send_packet(
            &mut old,
            1,
            &[0xff, 0xbf, 0x0f, b'#', b'H', b'Y', b'0', b'0', b'0'],
        );

        let (mut fresh, _) = listener.accept().unwrap();
        fresh
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        handshake(&mut fresh, 12);
        loop {
            let (command, payload) = next_command(&mut fresh);
            if command == 0x03 {
                query_reply(&mut fresh, &payload);
                continue;
            }
            assert_eq!(
                command, 0x0e,
                "replacement connection must be pinged before SQL"
            );
            ok_packet(&mut fresh, 1);
            break;
        }
        tx.send(()).unwrap();
        let (query, _) = next_command(&mut fresh);
        assert_eq!(query, 0x03);
        ok_packet(&mut fresh, 1);
    });

    let pool = open_pool(&config(port, 3)).await.unwrap();
    let mut conn = pool
        .get_conn()
        .await
        .expect("failed ping should trigger reconnect");
    conn.query_drop("SET @cdata_test_retry = 1").await.unwrap();
    rx.recv_timeout(Duration::from_secs(3))
        .expect("fresh connection accepted");
    server.join().unwrap();
}

#[tokio::test]
async fn connect_timeout_covers_a_nonresponsive_ping() {
    let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        handshake(&mut stream, 21);
        loop {
            let (command, payload) = next_command(&mut stream);
            if command == 0x03 {
                query_reply(&mut stream, &payload);
                continue;
            }
            assert_eq!(command, 0x0e, "get_conn should wait for COM_PING");
            break;
        }
        // Keep the socket open without replying; dropping the client ends this handler.
        let mut byte = [0u8; 1];
        let _ = stream.read(&mut byte);
    });

    let pool = open_pool(&config(port, 1)).await.unwrap();
    let started = tokio::time::Instant::now();
    let result = pool.get_conn().await;
    let err = result.expect_err("nonresponsive ping must time out");
    assert!(
        matches!(
            err,
            mysql_async::Error::Other(ref source)
                if source.downcast_ref::<cdata_core::db::ConnectFailed>().is_some()
        ),
        "timeout should be reported as ConnectFailed, got {err:?}"
    );
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "connect timeout must include ping: {:?}",
        started.elapsed()
    );
    pool.disconnect().await.unwrap();
    server.join().unwrap();
}

#[tokio::test]
async fn import_retries_failed_preflight_then_runs_each_statement_once() {
    let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = thread::spawn(move || {
        let (mut old, _) = listener.accept().unwrap();
        old.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
        handshake(&mut old, 31);
        loop {
            let (command, payload) = next_command(&mut old);
            if command == 0x03 {
                query_reply(&mut old, &payload);
                continue;
            }
            assert_eq!(
                command, 0x0e,
                "old connection must be preflighted before import"
            );
            send_packet(
                &mut old,
                1,
                &[0xff, 0xbf, 0x0f, b'#', b'H', b'Y', b'0', b'0', b'0'],
            );
            break;
        }

        let (mut fresh, _) = listener.accept().unwrap();
        fresh
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        handshake(&mut fresh, 32);
        loop {
            let (command, payload) = next_command(&mut fresh);
            if command == 0x03 {
                query_reply(&mut fresh, &payload);
                continue;
            }
            assert_eq!(command, 0x0e, "replacement connection must pass preflight");
            ok_packet(&mut fresh, 1);
            break;
        }

        let mut business_queries = Vec::new();
        loop {
            let (command, payload) = next_command(&mut fresh);
            assert_eq!(command, 0x03);
            let sql = String::from_utf8(payload).unwrap();
            if sql.starts_with("USE ") {
                ok_packet(&mut fresh, 1);
            } else {
                business_queries.push(sql);
                ok_packet(&mut fresh, 1);
                if business_queries.len() == 2 {
                    break;
                }
            }
        }
        business_queries
    });

    let pool = open_pool(&config(port, 3)).await.unwrap();
    let statements = [
        ImportStatement {
            sql: "INSERT INTO t VALUES (1)".into(),
            line: 2,
        },
        ImportStatement {
            sql: "INSERT INTO t VALUES (2)".into(),
            line: 3,
        },
    ];
    let summary = run_sql_import(&pool, &statements, "synthetic_db")
        .await
        .unwrap();
    assert_eq!(summary.executed, 2);
    assert_eq!(summary.failure, None);
    assert_eq!(
        server.join().unwrap(),
        ["INSERT INTO t VALUES (1)", "INSERT INTO t VALUES (2)"]
    );
}

#[tokio::test]
async fn import_does_not_reconnect_or_replay_after_connection_drops_during_sql() {
    let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let port = listener.local_addr().unwrap().port();
    let (finished_tx, finished_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        handshake(&mut stream, 41);
        loop {
            let (command, payload) = next_command(&mut stream);
            if command == 0x03 {
                query_reply(&mut stream, &payload);
                continue;
            }
            assert_eq!(command, 0x0e, "import must preflight before SQL");
            ok_packet(&mut stream, 1);
            break;
        }

        let (use_command, _) = next_command(&mut stream);
        assert_eq!(use_command, 0x03);
        ok_packet(&mut stream, 1);
        let (command, payload) = next_command(&mut stream);
        assert_eq!(command, 0x03);
        assert_eq!(payload, b"INSERT INTO t VALUES ('bad')");
        // The server has received the statement but disconnects before responding. Since the
        // outcome is ambiguous, the importer must report failure without replaying it elsewhere.
        drop(stream);
        finished_rx
            .recv_timeout(Duration::from_secs(3))
            .expect("import should finish after the connection drops");
        listener.set_nonblocking(true).unwrap();
        match listener.accept() {
            Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {}
            Ok((_, addr)) => {
                panic!("unexpected retry connection after ambiguous SQL result: {addr}")
            }
            Err(err) => panic!("listener check failed: {err}"),
        }
    });

    let pool = open_pool(&config(port, 3)).await.unwrap();
    let statements = [
        ImportStatement {
            sql: "INSERT INTO t VALUES ('bad')".into(),
            line: 5,
        },
        ImportStatement {
            sql: "INSERT INTO t VALUES (2)".into(),
            line: 6,
        },
    ];
    let summary = run_sql_import(&pool, &statements, "synthetic_db")
        .await
        .unwrap();
    assert_eq!(summary.executed, 0);
    let failure = summary.failure.expect("connection loss should be recorded");
    assert_eq!(failure.statement, 1);
    assert_eq!(failure.line, 5);
    finished_tx.send(()).unwrap();
    server.join().unwrap();
}
