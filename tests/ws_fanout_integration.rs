//! Redis WS fan-out (Phase 4 multi-replica realtime).
//!
//! Requires a reachable Redis; set `REDIS_TEST_URL` (e.g.
//! `redis://127.0.0.1:6379`) to run, otherwise the tests skip so CI without
//! Redis stays green. The full publish → Redis → subscribe → local-socket
//! loop is exercised in-process; the two-instance topology differs only in
//! which process the subscriber runs in, since replicas share nothing but
//! Redis and Postgres.

#![cfg(feature = "redis")]

use goods4ncu::api::ws;
use goods4ncu::lifecycle::ShutdownController;
use goods4ncu::services::ws_fanout;
use std::time::Duration;
use uuid::Uuid;

fn redis_url() -> Option<String> {
    match std::env::var("REDIS_TEST_URL") {
        Ok(url) if !url.trim().is_empty() => Some(url),
        _ => {
            eprintln!("skipping: set REDIS_TEST_URL to run WS fanout tests");
            None
        }
    }
}

#[tokio::test]
async fn broadcast_round_trips_through_redis_to_local_sockets() {
    let Some(url) = redis_url() else { return };

    let controller = ShutdownController::new();
    let fanout = tokio::spawn(ws_fanout::run(url, controller.signal(), false));

    // Wait for the subscriber + publisher to come up.
    tokio::time::sleep(Duration::from_millis(500)).await;

    let user_id = format!("fanout-user-{}", Uuid::new_v4().simple());
    let mut rx = ws::register_test_connection(&user_id);

    // The broadcast goes out via the installed Redis publisher, comes back
    // through the subscription, and lands on the locally registered socket.
    let payload = format!("{{\"event\":\"fanout-test\",\"n\":\"{}\"}}", Uuid::new_v4());
    ws::broadcast_to_user(&user_id, &payload);

    let received = tokio::time::timeout(Duration::from_secs(5), rx.recv())
        .await
        .expect("fanout delivery within 5s")
        .expect("connection open");
    match received {
        axum::extract::ws::Message::Text(text) => assert_eq!(text.as_str(), payload),
        other => panic!("unexpected frame: {other:?}"),
    }

    // A message published for another user must not reach this socket.
    ws::broadcast_to_user(&format!("other-{}", Uuid::new_v4().simple()), "{}");
    assert!(
        tokio::time::timeout(Duration::from_millis(500), rx.recv())
            .await
            .is_err(),
        "misdirected delivery"
    );

    controller.trigger();
    let _ = tokio::time::timeout(Duration::from_secs(5), fanout).await;
}

#[tokio::test]
async fn subscriber_shuts_down_cleanly() {
    let Some(url) = redis_url() else { return };

    let controller = ShutdownController::new();
    let fanout = tokio::spawn(ws_fanout::run(url, controller.signal(), false));
    tokio::time::sleep(Duration::from_millis(300)).await;

    controller.trigger();
    tokio::time::timeout(Duration::from_secs(5), fanout)
        .await
        .expect("fanout must honour shutdown")
        .expect("fanout task must not panic");
}

#[tokio::test]
async fn fanout_fails_fast_in_replicated_mode_when_redis_unreachable() {
    let controller = ShutdownController::new();
    let fanout = tokio::spawn(ws_fanout::run(
        "redis://127.0.0.1:1/0".to_string(),
        controller.signal(),
        true,
    ));
    let res = fanout.await;
    assert!(
        res.is_err(),
        "fanout task must fail-fast / panic in replicated mode when redis is down"
    );
}

/// Full two-instance topology: two independent server processes share only
/// Redis and Postgres; a WebSocket client on instance A receives a payload
/// published by a party outside instance A's process (here: the test acting
/// as instance B's publisher). Requires `FANOUT_E2E=1`, a built binary, the
/// dev database and Redis.
#[tokio::test]
async fn two_instances_deliver_across_processes() {
    if std::env::var("FANOUT_E2E").as_deref() != Ok("1") {
        eprintln!("skipping: set FANOUT_E2E=1 (needs built binary, dev DB, Redis)");
        return;
    }
    let Some(url) = redis_url() else { return };

    let spawn = |port: u16| {
        std::process::Command::new(env!("CARGO_BIN_EXE_goods4ncu"))
            .env("SERVER_PORT", port.to_string())
            .env("REDIS_URL", &url)
            .env("SHUTDOWN_DRAIN_SECS", "0")
            .env("SHUTDOWN_TIMEOUT_SECS", "5")
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn instance")
    };
    let mut instance_a = spawn(4101);
    let mut instance_b = spawn(4102);

    let client = reqwest::Client::new();
    for port in [4101u16, 4102] {
        let mut ready = false;
        for _ in 0..60 {
            if let Ok(resp) = client
                .get(format!("http://127.0.0.1:{port}/api/readyz"))
                .send()
                .await
            {
                if resp.status().is_success() {
                    ready = true;
                    break;
                }
            }
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
        assert!(ready, "instance on :{port} never became ready");
    }

    // Register a fresh user through instance A and open a real WebSocket.
    let username = format!("fanout_e2e_{}", Uuid::new_v4().simple());
    let register: serde_json::Value = client
        .post("http://127.0.0.1:4101/api/auth/register")
        .json(&serde_json::json!({ "username": username, "password": "Fanout-e2e-pass1" }))
        .send()
        .await
        .expect("register")
        .json()
        .await
        .expect("register json");
    let token = register["token"].as_str().expect("token").to_string();
    let user_id = register["user_id"].as_str().expect("user_id").to_string();

    let mut request =
        tokio_tungstenite::tungstenite::client::IntoClientRequest::into_client_request(
            "ws://127.0.0.1:4101/api/ws",
        )
        .expect("ws request");
    request.headers_mut().insert(
        "Authorization",
        format!("Bearer {token}").parse().expect("header"),
    );
    let (mut socket, _) = tokio_tungstenite::connect_async(request)
        .await
        .expect("ws connect to instance A");

    // Publish from OUTSIDE instance A's process — exactly what instance B's
    // outbox worker does for a user whose socket lives on A.
    tokio::time::sleep(Duration::from_millis(500)).await;
    let redis_client = redis::Client::open(url.as_str()).expect("redis client");
    let mut conn = redis::aio::ConnectionManager::new(redis_client)
        .await
        .expect("redis conn");
    let marker = format!("cross-process-{}", Uuid::new_v4().simple());
    ws_fanout::publish(&mut conn, &user_id, &format!("{{\"event\":\"{marker}\"}}"))
        .await
        .expect("publish");

    use futures_util::StreamExt;
    let frame = tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            match socket.next().await {
                Some(Ok(tokio_tungstenite::tungstenite::Message::Text(text))) => {
                    if text.contains(&marker) {
                        return text.to_string();
                    }
                }
                Some(Ok(_)) => continue,
                other => panic!("socket ended: {other:?}"),
            }
        }
    })
    .await
    .expect("cross-process delivery within 10s");
    assert!(frame.contains(&marker));

    // Orderly SIGTERM drain for both instances.
    for instance in [&mut instance_a, &mut instance_b] {
        sigterm(instance.id());
    }
    for instance in [&mut instance_a, &mut instance_b] {
        let _ = instance.wait();
    }
}

/// SIGTERM via /bin/kill so both instances exercise the real drain path.
fn sigterm(pid: u32) {
    let _ = std::process::Command::new("kill")
        .args(["-TERM", &pid.to_string()])
        .status();
}
