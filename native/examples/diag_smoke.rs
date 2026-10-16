//! Starts a node, waits for it to come online and prints the diagnostics JSON.
//! `cargo run --example diag_smoke -- '{"privacy":"relay"}'`
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
    let opts = std::env::args().nth(1).unwrap_or_else(|| "{}".into());
    let o = CString::new(opts).unwrap();
    assert_eq!(mentos_set_options(o.as_ptr()), 0, "{:?}", take(mentos_last_error()));
    let secret = [7u8; 32];
    let dir = std::env::temp_dir().join("mentos-diag-smoke");
    let d = CString::new(dir.to_string_lossy().as_bytes()).unwrap();
    assert_eq!(mentos_start(secret.as_ptr(), 32, d.as_ptr(), d.as_ptr()), 0);
    for _ in 0..40 {
        std::thread::sleep(Duration::from_millis(500));
        if let Some(s) = take(mentos_diagnostics()) {
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            if v["net"].is_object() || v["relays"].as_array().is_some_and(|r| !r.is_empty()) {
                println!("{}", serde_json::to_string_pretty(&v).unwrap());
                println!("status: {}", take(mentos_status()).unwrap_or_default());
                return;
            }
        }
    }
    println!("no report; last error: {:?}", take(mentos_last_error()));
    println!("status: {}", take(mentos_status()).unwrap_or_default());
}
