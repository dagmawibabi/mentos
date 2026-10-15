//! Gives iroh the Android `JavaVM` and application `Context` before any socket opens.
//!
//! System DNS is read over JNI. Without this context, `ndk_context` panics with
//! "android context was not initialized" the first time the endpoint binds, and
//! that panic takes the process down.

use std::ffi::{c_char, c_void, CString};
use std::sync::atomic::{AtomicBool, Ordering};

use jni::objects::{JClass, JObject};
use jni::{Env, EnvUnowned};

static INSTALLED: AtomicBool = AtomicBool::new(false);

unsafe extern "C" {
    fn __android_log_write(prio: i32, tag: *const c_char, text: *const c_char) -> i32;
}

pub fn log_error(msg: &str) {
    log(6, msg);
}

fn log(prio: i32, msg: &str) {
    let Ok(tag) = CString::new("mentos_net") else {
        return;
    };
    let Ok(text) = CString::new(msg.replace('\0', " ")) else {
        return;
    };
    unsafe {
        __android_log_write(prio, tag.as_ptr(), text.as_ptr());
    }
}

fn install(env: &Env<'_>, context: JObject<'_>) -> jni::errors::Result<()> {
    if context.as_raw().is_null() {
        log_error("iroh context was null");
        return Ok(());
    }
    if INSTALLED.swap(true, Ordering::SeqCst) {
        return Ok(());
    }
    let vm = match env.get_java_vm() {
        Ok(vm) => vm,
        Err(e) => {
            INSTALLED.store(false, Ordering::SeqCst);
            return Err(e);
        }
    };
    let global = match env.new_global_ref(context) {
        Ok(global) => global,
        Err(e) => {
            INSTALLED.store(false, Ordering::SeqCst);
            return Err(e);
        }
    };
    // Leak the global ref. iroh keeps using this Context for the process lifetime.
    let ctx = global.into_raw() as *mut c_void;
    let java_vm = vm.get_raw() as *mut c_void;
    unsafe {
        iroh::dns::install_android_jni_context(java_vm, ctx);
    }
    log(4, "iroh Android context installed");
    Ok(())
}

#[no_mangle]
pub extern "system" fn Java_app_mentos_MentosApp_installIroh<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
    context: JObject<'local>,
) {
    crate::install_panic_log();
    let outcome = env.with_env(|env| install(env, context));
    match outcome.into_outcome() {
        jni::Outcome::Ok(()) => {}
        jni::Outcome::Err(e) => log_error(&format!("iroh context: {e}")),
        jni::Outcome::Panic(_) => log_error("iroh context panicked"),
    }
}
