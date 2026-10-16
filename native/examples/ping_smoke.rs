//! Two-process ping over relays: `serve <secret-byte>` prints a ticket and
//! waits; `ping <secret-byte> <ticket>` dials it and prints RTT and diagnostics.
use std::{ffi::{CStr, CString}, time::Duration};

use mentos_net::*;

fn take(p: *mut std::os::raw::c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
    mentos_free(p);
    Some(s)
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let proxy = std::env::var("HTTPS_PROXY").unwrap_or_default();
    let o = CString::new(format!(r#"{{"privacy":"tor","proxy":"{proxy}"}}"#)).unwrap();
    assert_eq!(mentos_set_options(o.as_ptr()), 0);
    let secret = [args[2].parse::<u8>().unwrap(); 32];
    let dir = std::env::temp_dir().join(format!("mentos-ping-{}", args[2]));
    let d = CString::new(dir.to_string_lossy().as_bytes()).unwrap();
    assert_eq!(mentos_start(secret.as_ptr(), 32, d.as_ptr(), d.as_ptr()), 0);
    for _ in 0..40 {
        std::thread::sleep(Duration::from_millis(500));
        if take(mentos_status()).unwrap_or_default().contains("relay.n0") {
            break;
        }
    }
    if args[1] == "serve" {
        println!("TICKET {}", take(mentos_ticket()).unwrap());
        std::thread::sleep(Duration::from_secs(60));
        return;
    }
    let t = CString::new(args[3].clone()).unwrap();
    let peer = take(mentos_add_ticket(t.as_ptr())).expect("ticket");
    let p = CString::new(peer).unwrap();
    let rtt = mentos_ping(p.as_ptr());
    println!("PING rtt_us={rtt} err={:?}", take(mentos_last_error()));
    println!("{}", take(mentos_diagnostics()).unwrap_or_default());
}
