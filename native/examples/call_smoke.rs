//! Two-process call over relays: `a <ticket-file>` waits for `b`, then both
//! exchange 50 datagrams and report what arrived.
use std::{ffi::{CStr, CString}, time::{Duration, Instant}};

use mentos_net::*;

fn take(p: *mut std::os::raw::c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
    mentos_free(p);
    Some(s)
}

fn c(s: &str) -> CString {
    CString::new(s).unwrap()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let role = args[1].as_str();
    let file = &args[2];
    let proxy = std::env::var("HTTPS_PROXY").unwrap_or_default();
    assert_eq!(mentos_set_options(c(&format!(r#"{{"privacy":"tor","proxy":"{proxy}"}}"#)).as_ptr()), 0);
    let secret = [if role == "a" { 21u8 } else { 22u8 }; 32];
    let dir = c(&std::env::temp_dir().join(format!("mentos-call-{role}")).to_string_lossy());
    assert_eq!(mentos_start(secret.as_ptr(), 32, dir.as_ptr(), dir.as_ptr()), 0);
    for _ in 0..40 {
        std::thread::sleep(Duration::from_millis(500));
        if take(mentos_status()).unwrap_or_default().contains("relay.n0") {
            break;
        }
    }
    let me: serde_json::Value = serde_json::from_str(&take(mentos_status()).unwrap()).unwrap();
    let me = me["nodeId"].as_str().unwrap().to_string();
    // Exchange tickets through a shared file.
    std::fs::write(format!("{file}.{role}"), take(mentos_ticket()).unwrap()).unwrap();
    let other = if role == "a" { "b" } else { "a" };
    let deadline = Instant::now() + Duration::from_secs(60);
    let ticket = loop {
        if let Ok(t) = std::fs::read_to_string(format!("{file}.{other}")) {
            break t;
        }
        assert!(Instant::now() < deadline, "no ticket from {other}");
        std::thread::sleep(Duration::from_millis(200));
    };
    let peer = take(mentos_add_ticket(c(&ticket).as_ptr())).unwrap();
    let call = c("smoke-call");
    // BLOCK=1 makes `a` invite someone else, so `b` must be refused.
    let allow = if role == "a" && std::env::var("BLOCK").is_ok() { hex_zero_key() } else { peer.clone() };
    assert_eq!(mentos_call_listen(call.as_ptr(), c(&allow).as_ptr()), 0);
    if role == "b" {
        std::thread::sleep(Duration::from_secs(2));
        assert_eq!(mentos_call_dial(call.as_ptr(), c(&peer).as_ptr()), 0);
    }
    let mut connected = false;
    for _ in 0..80 {
        if mentos_call_max_datagram(call.as_ptr()) > 0 {
            connected = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    println!("{role} connected={connected} max_datagram={}", mentos_call_max_datagram(call.as_ptr()));
    let mut got = 0;
    let mut from_ok = true;
    let mut peer_buf = [0u8; 32];
    let mut buf = [0u8; 2048];
    let start = Instant::now();
    let mut sent = 0;
    while start.elapsed() < Duration::from_secs(8) {
        if sent < 50 {
            let payload = format!("{me}:{sent}:{}", "x".repeat(600));
            if mentos_call_send(call.as_ptr(), payload.as_ptr(), payload.len()) > 0 {
                sent += 1;
            }
        }
        loop {
            let n = mentos_call_recv(call.as_ptr(), peer_buf.as_mut_ptr(), buf.as_mut_ptr(), buf.len());
            if n <= 0 {
                break;
            }
            let text = String::from_utf8_lossy(&buf[..n as usize]);
            from_ok &= text.starts_with(&peer);
            got += 1;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    println!("{role} sent={sent} received={got} sender_ok={from_ok}");
    println!("{role} stats {}", take(mentos_call_stats(call.as_ptr())).unwrap_or_default());
    mentos_call_close(call.as_ptr());
}

/// A syntactically valid node id nobody owns.
fn hex_zero_key() -> String {
    "3b6a27bcceb6a42d62a3a8d02a6f0d73653215771de243a63ac048a18b59da29".to_string()
}
