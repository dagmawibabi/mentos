//! iroh node for Mentos: direct QUIC, gossip topics, content-addressed blobs.
//!
//! Exposed as a small C ABI so Flutter can load `libmentos_net.so` on Android
//! without a code generator.

use std::{
    collections::{HashMap, VecDeque},
    ffi::{CStr, CString},
    future::Future,
    os::raw::c_char,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex, Once, OnceLock, Weak,
    },
    time::Duration,
};

#[cfg(target_os = "android")]
mod android;
mod call;
mod diag;

use anyhow::{anyhow, Context, Result};
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine as _;
use bytes::Bytes;
use iroh::{
    endpoint::{Connection, RecvStream, SendStream},
    protocol::{AcceptError, ProtocolHandler, Router},
    Endpoint, EndpointAddr, EndpointId, PublicKey, SecretKey, Watcher,
};
use iroh_gossip::{
    api::{Event, GossipSender},
    Gossip, TopicId,
};
use n0_future::StreamExt;
use sha2::{Digest, Sha256};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    runtime::Runtime,
    sync::Semaphore,
    task::JoinHandle,
};

const DIRECT_ALPN: &[u8] = b"mentos/0";
const BLOB_ALPN: &[u8] = b"mentos-blob/0";
const MAX_DIRECT: usize = 2 * 1024 * 1024;
const MAX_BLOB: u64 = 80 * 1024 * 1024;
const MAX_EVENTS: usize = 256;
const MAX_EVENT_BYTES: usize = 4 * 1024 * 1024;
/// Both peers must agree on this. A frame over the limit is not rejected by
/// `broadcast`; gossip's send loop fails later and drops the whole neighbor
/// connection, so callers are checked against [`MAX_BROADCAST`] first.
const GOSSIP_MAX_FRAME: usize = 64 * 1024;
/// Headroom for gossip's own framing (message id, topic, scope).
const MAX_BROADCAST: usize = GOSSIP_MAX_FRAME - 1024;
const MAX_INBOUND_STREAMS: usize = 32;
const MAX_BLOB_SERVES: usize = 8;

type EventQ = Arc<Mutex<VecDeque<String>>>;

static RT: OnceLock<Runtime> = OnceLock::new();
static LAST_ERR: Mutex<Option<String>> = Mutex::new(None);
static NODE: Mutex<Option<Arc<Node>>> = Mutex::new(None);
static STARTING: AtomicBool = AtomicBool::new(false);
static GENERATION: AtomicU64 = AtomicU64::new(0);
static CONN_SEQ: AtomicU64 = AtomicU64::new(0);
/// The previous node's shutdown. A new bind waits for it so two endpoints
/// with the same key are not registered with the relay at once.
static SHUTDOWN: Mutex<Option<JoinHandle<()>>> = Mutex::new(None);
static BLOB_SERVES: Semaphore = Semaphore::const_new(MAX_BLOB_SERVES);

/// A panic unwinding out of an `extern "C"` fn aborts the whole app, so every
/// FFI entry point runs inside this.
fn guard<T>(fallback: T, f: impl FnOnce() -> T) -> T {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(v) => v,
        Err(_) => {
            set_err("native panic");
            fallback
        }
    }
}

fn rt() -> &'static Runtime {
    RT.get_or_init(|| {
        install_panic_log();
        tokio::runtime::Builder::new_multi_thread()
            .thread_name("mentos-net")
            // The default 2 MiB worker stack overflows inside the QUIC handshake
            // on Android and the process is aborted.
            .thread_stack_size(8 * 1024 * 1024)
            .enable_all()
            .build()
            .expect("tokio runtime")
    })
}

pub(crate) fn install_panic_log() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        std::panic::set_hook(Box::new(|info| {
            #[cfg(target_os = "android")]
            android::log_error(&format!("native panic: {info}"));
            #[cfg(not(target_os = "android"))]
            eprintln!("mentos native panic: {info}");
        }));
    });
}

/// Park this OS thread until [fut] finishes, without nested `Runtime::block_on`.
/// Dart used to `Isolate.run` every FFI call; that spawned so many DartWorker
/// threads that Windows failed with "Could not start thread".
fn wait<T: Send + 'static>(fut: impl Future<Output = T> + Send + 'static) -> Result<T> {
    let (tx, rx) = std::sync::mpsc::sync_channel(1);
    rt().spawn(async move {
        let _ = tx.send(fut.await);
    });
    rx.recv().map_err(|_| anyhow!("iroh runtime stopped"))
}

fn go<F>(fut: F)
where
    F: Future<Output = ()> + Send + 'static,
{
    rt().spawn(fut);
}

fn set_err(e: impl std::fmt::Display) {
    let msg = e.to_string();
    #[cfg(target_os = "android")]
    android::log_error(&msg);
    if let Ok(mut g) = LAST_ERR.lock() {
        *g = Some(msg);
    }
}

fn cstr(p: *const c_char) -> Result<String> {
    if p.is_null() {
        return Err(anyhow!("null string"));
    }
    Ok(unsafe { CStr::from_ptr(p) }.to_str()?.to_owned())
}

fn heap_str(s: impl Into<String>) -> *mut c_char {
    match CString::new(s.into()) {
        Ok(c) => c.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

fn hex_id(id: EndpointId) -> String {
    hex::encode(id.as_bytes())
}

fn parse_id(s: &str) -> Result<EndpointId> {
    let t = s.trim().to_lowercase();
    let bytes = hex::decode(&t).context("id is not hex")?;
    let arr: [u8; 32] = bytes.try_into().map_err(|_| anyhow!("id must be 32 bytes"))?;
    PublicKey::from_bytes(&arr).map_err(|e| anyhow!("{e}"))
}

fn parse_topic(s: &str) -> Result<TopicId> {
    let bytes = hex::decode(s.trim()).context("topic is not hex")?;
    let arr: [u8; 32] = bytes.try_into().map_err(|_| anyhow!("topic must be 32 bytes"))?;
    Ok(TopicId::from_bytes(arr))
}

fn parse_addr(s: &str) -> Result<EndpointAddr> {
    let t = s.trim();
    if let Ok(addr) = serde_json::from_str::<EndpointAddr>(t) {
        return Ok(addr);
    }
    if let Some((id, relay)) = t.split_once('|') {
        let mut addr = EndpointAddr::from(parse_id(id)?);
        if let Ok(url) = relay.parse() {
            addr = addr.with_relay_url(url);
        }
        return Ok(addr);
    }
    Ok(EndpointAddr::from(parse_id(t)?))
}

fn push_event(q: &EventQ, value: serde_json::Value) {
    let Ok(s) = serde_json::to_string(&value) else {
        return;
    };
    if s.len() > MAX_EVENT_BYTES {
        return;
    }
    let Ok(mut g) = q.lock() else {
        return;
    };
    g.push_back(s);
    let mut bytes: usize = g.iter().map(String::len).sum();
    while (g.len() > MAX_EVENTS || bytes > MAX_EVENT_BYTES) && !g.is_empty() {
        if let Some(old) = g.pop_front() {
            bytes = bytes.saturating_sub(old.len());
        } else {
            break;
        }
    }
}

fn mutex<'a, T>(m: &'a Mutex<T>) -> std::sync::MutexGuard<'a, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

fn sha256_file(path: &Path) -> Result<[u8; 32]> {
    let mut f = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    std::io::copy(&mut f, &mut hasher)?;
    Ok(hasher.finalize().into())
}

struct Node {
    endpoint: Endpoint,
    router: Router,
    gossip: Gossip,
    blob_dir: PathBuf,
    events: EventQ,
    tickets: Mutex<HashMap<EndpointId, EndpointAddr>>,
    /// Live connections per peer. A hotspot often gives us an inbound link we
    /// did not dial; replacing that with a later failed dial drops the only
    /// path that can carry a reply.
    conns: Mutex<HashMap<EndpointId, Vec<(u64, Connection)>>>,
    /// Serializes dials per peer so concurrent sends share one connection.
    dials: Mutex<HashMap<EndpointId, Arc<tokio::sync::Mutex<()>>>>,
    topics: Mutex<HashMap<String, TopicSlot>>,
    /// Set while a blob fetch should stop. A flag that is already true means
    /// cancel won the race before the fetch task started.
    cancels: Mutex<HashMap<String, Arc<AtomicBool>>>,
    /// Long-lived tasks that hold an `Arc<Node>`; aborted on stop.
    background: Mutex<Vec<JoinHandle<()>>>,
}

struct TopicSlot {
    sender: GossipSender,
    task: JoinHandle<()>,
}

impl Node {
    fn emit(&self, v: serde_json::Value) {
        push_event(&self.events, v);
    }

    fn remember(&self, addr: EndpointAddr) {
        if let Ok(mut t) = self.tickets.lock() {
            t.insert(addr.id, addr);
        }
    }

    fn addr_for(&self, id: EndpointId) -> EndpointAddr {
        self.tickets
            .lock()
            .ok()
            .and_then(|t| t.get(&id).cloned())
            .unwrap_or_else(|| EndpointAddr::from(id))
    }

    fn live_conns(&self, id: EndpointId) -> Vec<Connection> {
        mutex(&self.conns)
            .get(&id)
            .map(|list| {
                list.iter()
                    .filter(|(_, c)| c.close_reason().is_none())
                    .map(|(_, c)| c.clone())
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Must be called once per connection, inbound or outbound. When both
    /// peers dial each other at once there are two live connections; each
    /// gets its own reader so nothing sent on either is lost.
    fn cache_conn(self: &Arc<Self>, id: EndpointId, conn: Connection) {
        let seq = CONN_SEQ.fetch_add(1, Ordering::Relaxed);
        let was_up = {
            let mut g = mutex(&self.conns);
            let list = g.entry(id).or_default();
            list.retain(|(_, c)| c.close_reason().is_none());
            let was_up = !list.is_empty();
            if list.len() >= 4 {
                list.remove(0);
            }
            list.push((seq, conn.clone()));
            was_up
        };
        if !was_up {
            self.emit(serde_json::json!({"t":"link","peer": hex_id(id),"up": true}));
        }
        let n = self.clone();
        let watch = conn.clone();
        tokio::spawn(async move {
            watch.closed().await;
            let gone = {
                let mut g = mutex(&n.conns);
                let Some(list) = g.get_mut(&id) else {
                    return;
                };
                let before = list.iter().any(|(_, c)| c.close_reason().is_none());
                list.retain(|(s, c)| *s != seq && c.close_reason().is_none());
                let after = !list.is_empty();
                if list.is_empty() {
                    g.remove(&id);
                }
                before && !after
            };
            if gone {
                n.emit(serde_json::json!({"t":"link","peer": hex_id(id),"up": false}));
            }
        });
        // Blobs ride this same connection. A second dial (different ALPN) uses
        // the peer's public address and dies on a phone hotspot.
        let dir = self.blob_dir.clone();
        let bi = conn.clone();
        tokio::spawn(accept_blob_streams(bi, dir));
        let events = self.events.clone();
        tokio::spawn(async move {
            // One slow 2 MiB stream over a relay must not hold up every
            // message behind it, so each stream is read on its own task.
            let budget = Arc::new(Semaphore::new(MAX_INBOUND_STREAMS));
            while let Ok(mut recv) = conn.accept_uni().await {
                let Ok(permit) = budget.clone().acquire_owned().await else {
                    break;
                };
                let events = events.clone();
                tokio::spawn(async move {
                    let _permit = permit;
                    let read =
                        tokio::time::timeout(Duration::from_secs(60), read_len_prefixed(&mut recv)).await;
                    if let Ok(Ok(data)) = read {
                        push_event(
                            &events,
                            serde_json::json!({
                                "t": "direct",
                                "from": hex_id(id),
                                "data": B64.encode(&data),
                            }),
                        );
                    }
                });
            }
        });
    }

    /// The peer that dialed us is reachable on this path even when a fresh
    /// dial to their public address fails (phone hotspot, no hairpin NAT).
    async fn remember_remote(self: &Arc<Self>, id: EndpointId) {
        let Some(info) = self.endpoint.remote_info(id).await else {
            return;
        };
        let addr = EndpointAddr::from_parts(info.id(), info.addrs().map(|a| a.addr().clone()));
        self.remember(addr);
    }

    async fn dial_fresh(self: &Arc<Self>, id: EndpointId) -> Result<Connection> {
        self.remember_remote(id).await;
        let conn = self
            .endpoint
            .connect(self.addr_for(id), DIRECT_ALPN)
            .await
            .context("connect")?;
        self.cache_conn(id, conn.clone());
        let _ = self.remember_remote(id).await;
        Ok(conn)
    }

    async fn get_direct(self: &Arc<Self>, id: EndpointId) -> Result<Connection> {
        if let Some(c) = self.live_conns(id).into_iter().next() {
            return Ok(c);
        }
        let lock = mutex(&self.dials)
            .entry(id)
            .or_insert_with(|| Arc::new(tokio::sync::Mutex::new(())))
            .clone();
        let _dialing = lock.lock().await;
        if let Some(c) = self.live_conns(id).into_iter().next() {
            return Ok(c);
        }
        self.dial_fresh(id).await
    }

    async fn send_bytes(self: &Arc<Self>, id: EndpointId, buf: &[u8]) -> Result<()> {
        for conn in self.live_conns(id) {
            if write_len_prefixed_conn(&conn, buf).await.is_ok() {
                return Ok(());
            }
        }
        let lock = mutex(&self.dials)
            .entry(id)
            .or_insert_with(|| Arc::new(tokio::sync::Mutex::new(())))
            .clone();
        let _dialing = lock.lock().await;
        for conn in self.live_conns(id) {
            if write_len_prefixed_conn(&conn, buf).await.is_ok() {
                return Ok(());
            }
        }
        let conn = self.dial_fresh(id).await?;
        write_len_prefixed_conn(&conn, buf).await
    }
}

async fn write_len_prefixed_conn(conn: &Connection, data: &[u8]) -> Result<()> {
    // A connection whose peer vanished can block here until the idle timeout;
    // give up early so the caller can dial a fresh path.
    let mut send = tokio::time::timeout(Duration::from_secs(5), conn.open_uni())
        .await
        .map_err(|_| anyhow!("open stream timed out"))?
        .context("open stream")?;
    write_len_prefixed(&mut send, data).await
}

async fn write_len_prefixed(send: &mut SendStream, data: &[u8]) -> Result<()> {
    if data.len() > MAX_DIRECT {
        return Err(anyhow!("message too large"));
    }
    send.write_all(&(data.len() as u32).to_be_bytes()).await?;
    send.write_all(data).await?;
    send.finish()?;
    Ok(())
}

async fn read_len_prefixed(recv: &mut RecvStream) -> Result<Vec<u8>> {
    let mut hdr = [0u8; 4];
    recv.read_exact(&mut hdr).await?;
    let n = u32::from_be_bytes(hdr) as usize;
    if n > MAX_DIRECT {
        return Err(anyhow!("message too large"));
    }
    let mut buf = vec![0u8; n];
    recv.read_exact(&mut buf).await?;
    Ok(buf)
}

/// Weak so the router (owned by the node) does not keep the node alive.
#[derive(Clone)]
struct DirectProto {
    node: Arc<OnceLock<Weak<Node>>>,
}

impl std::fmt::Debug for DirectProto {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("DirectProto")
    }
}

impl ProtocolHandler for DirectProto {
    fn accept(&self, connection: Connection) -> impl std::future::Future<Output = Result<(), AcceptError>> + Send {
        let slot = self.node.clone();
        async move {
            let id = connection.remote_id();
            let n = slot.get().and_then(Weak::upgrade);
            if let Some(n) = n {
                n.remember_remote(id).await;
                n.cache_conn(id, connection.clone());
            }
            // Returning drops the router's clone. Hold it until the peer
            // leaves so a reply can still open a stream on this connection.
            connection.closed().await;
            Ok(())
        }
    }
}

#[derive(Debug, Clone)]
struct BlobProto {
    blob_dir: PathBuf,
}

impl ProtocolHandler for BlobProto {
    fn accept(&self, connection: Connection) -> impl std::future::Future<Output = Result<(), AcceptError>> + Send {
        accept_blob_streams(connection, self.blob_dir.clone())
    }
}

async fn accept_blob_streams(conn: Connection, dir: PathBuf) -> Result<(), AcceptError> {
    while let Ok((send, recv)) = conn.accept_bi().await {
        let dir = dir.clone();
        tokio::spawn(async move {
            let Ok(_permit) = BLOB_SERVES.acquire().await else {
                return;
            };
            let _ = serve_blob(dir, send, recv).await;
        });
    }
    Ok(())
}

async fn serve_blob(dir: PathBuf, mut send: SendStream, mut recv: RecvStream) -> Result<()> {
    let mut hash = [0u8; 64];
    tokio::time::timeout(Duration::from_secs(20), recv.read_exact(&mut hash))
        .await
        .map_err(|_| anyhow!("blob request timed out"))??;
    let name = std::str::from_utf8(&hash)?.to_lowercase();
    if !name.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(anyhow!("bad hash"));
    }
    let path = dir.join(&name);
    if !path.is_file() {
        send.write_all(&0u64.to_be_bytes()).await?;
        send.finish()?;
        return Ok(());
    }
    let meta = tokio::fs::metadata(&path).await?;
    if meta.len() > MAX_BLOB {
        return Err(anyhow!("blob too large"));
    }
    send.write_all(&meta.len().to_be_bytes()).await?;
    let mut f = tokio::fs::File::open(&path).await?;
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let n = f.read(&mut buf).await?;
        if n == 0 {
            break;
        }
        tokio::time::timeout(STALL, send.write_all(&buf[..n]))
            .await
            .map_err(|_| anyhow!("blob reader stalled"))??;
    }
    send.finish()?;
    Ok(())
}

/// How long a blob transfer may make no progress before it is abandoned.
const STALL: Duration = Duration::from_secs(20);

/// Large files over a relay are slow. The deadline grows with the size so
/// a healthy transfer is not cut off, while [`STALL`] catches dead ones.
fn blob_deadline(len: u64) -> Duration {
    const FLOOR_BYTES_PER_SEC: u64 = 64 * 1024;
    Duration::from_secs(45 + len / FLOOR_BYTES_PER_SEC)
}

/// Prefer a connection that is already up. Fall back to the blob protocol
/// for a peer that only serves files on that ALPN.
async fn open_blob(node: &Node, peer: EndpointId) -> Result<(SendStream, RecvStream)> {
    if let Some(conn) = node.live_conns(peer).into_iter().next() {
        if let Ok(Ok(pair)) = tokio::time::timeout(Duration::from_secs(6), conn.open_bi()).await {
            return Ok(pair);
        }
    }
    let conn = node
        .endpoint
        .connect(node.addr_for(peer), BLOB_ALPN)
        .await
        .context("blob connect")?;
    conn.open_bi().await.context("open blob stream")
}

fn blob_name(hash: &str) -> Result<String> {
    let name = hash.trim().to_lowercase();
    if name.len() != 64 || !name.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(anyhow!("bad hash"));
    }
    Ok(name)
}

fn cancel_flag(node: &Node, hash: &str) -> Arc<AtomicBool> {
    mutex(&node.cancels)
        .entry(hash.to_string())
        .or_insert_with(|| Arc::new(AtomicBool::new(false)))
        .clone()
}

async fn fetch_blob(node: &Node, hash: &str, peer: EndpointId) -> Result<bool> {
    let hash = blob_name(hash)?;
    let dest = node.blob_dir.join(&hash);
    if dest.is_file() {
        return Ok(true);
    }
    let flag = cancel_flag(node, &hash);
    if flag.load(Ordering::Relaxed) {
        mutex(&node.cancels).remove(&hash);
        return Ok(false);
    }
    let tmp = dest.with_extension("part");
    let result = fetch_blob_body(node, &hash, peer, &tmp, flag).await;
    mutex(&node.cancels).remove(&hash);
    if !matches!(result, Ok(true)) {
        let _ = tokio::fs::remove_file(&tmp).await;
    }
    result
}

async fn fetch_blob_body(
    node: &Node,
    hash: &str,
    peer: EndpointId,
    tmp: &Path,
    flag: Arc<AtomicBool>,
) -> Result<bool> {
    let dest = node.blob_dir.join(hash);
    let header = async {
        let (mut send, mut recv) = open_blob(node, peer).await?;
        send.write_all(hash.as_bytes()).await?;
        send.finish()?;
        let mut lenb = [0u8; 8];
        recv.read_exact(&mut lenb).await?;
        anyhow::Ok((recv, u64::from_be_bytes(lenb)))
    };
    let (mut recv, len) = tokio::time::timeout(Duration::from_secs(30), header)
        .await
        .map_err(|_| anyhow!("blob request timed out"))??;
    if len == 0 || len > MAX_BLOB {
        return Ok(false);
    }
    let deadline = tokio::time::Instant::now() + blob_deadline(len);
    let mut f = tokio::fs::File::create(tmp).await?;
    let mut left = len;
    let mut buf = vec![0u8; 64 * 1024];
    let mut hasher = Sha256::new();
    while left > 0 {
        if flag.load(Ordering::Relaxed) {
            return Ok(false);
        }
        if tokio::time::Instant::now() >= deadline {
            return Err(anyhow!("blob fetch timed out"));
        }
        let chunk = left.min(buf.len() as u64) as usize;
        let n = match tokio::time::timeout(STALL, recv.read(&mut buf[..chunk])).await {
            Ok(Ok(Some(n))) => n,
            Ok(Ok(None)) => 0,
            Ok(Err(e)) => return Err(anyhow!("blob read: {e}")),
            Err(_) => return Err(anyhow!("blob read stalled")),
        };
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
        f.write_all(&buf[..n]).await?;
        left -= n as u64;
    }
    f.flush().await?;
    drop(f);
    if flag.load(Ordering::Relaxed) || left != 0 {
        return Ok(false);
    }
    if hex::encode(hasher.finalize()) != hash {
        return Err(anyhow!("blob hash mismatch"));
    }
    tokio::fs::rename(tmp, &dest).await?;
    Ok(true)
}

async fn start_node(secret: [u8; 32], blob_dir: PathBuf) -> Result<Arc<Node>> {
    std::fs::create_dir_all(&blob_dir)?;
    let sk = SecretKey::from_bytes(&secret);
    let events: EventQ = Arc::new(Mutex::new(VecDeque::new()));

    let endpoint = diag::builder()?
        .secret_key(sk)
        .alpns(vec![DIRECT_ALPN.to_vec(), BLOB_ALPN.to_vec(), iroh_gossip::ALPN.to_vec(), call::CALL_ALPN.to_vec()])
        .bind()
        .await
        .context("bind endpoint")?;

    let gossip = Gossip::builder()
        .max_message_size(GOSSIP_MAX_FRAME)
        .spawn(endpoint.clone());

    let node_slot: Arc<OnceLock<Weak<Node>>> = Arc::new(OnceLock::new());
    let direct = DirectProto {
        node: node_slot.clone(),
    };
    let blobs = BlobProto {
        blob_dir: blob_dir.clone(),
    };

    let router = Router::builder(endpoint.clone())
        .accept(DIRECT_ALPN, direct)
        .accept(BLOB_ALPN, blobs)
        .accept(iroh_gossip::ALPN, gossip.clone())
        .accept(call::CALL_ALPN, call::CallProto)
        .spawn();

    let node = Arc::new(Node {
        endpoint: endpoint.clone(),
        router,
        gossip,
        blob_dir,
        events: events.clone(),
        tickets: Mutex::new(HashMap::new()),
        conns: Mutex::new(HashMap::new()),
        dials: Mutex::new(HashMap::new()),
        topics: Mutex::new(HashMap::new()),
        cancels: Mutex::new(HashMap::new()),
        background: Mutex::new(Vec::new()),
    });
    let _ = node_slot.set(Arc::downgrade(&node));

    let n = node.clone();
    let watch = tokio::spawn(async move {
        let _ = tokio::time::timeout(Duration::from_secs(12), n.endpoint.online()).await;
        n.emit(serde_json::json!({"t":"status"}));
        let mut stream = n.endpoint.watch_addr().stream();
        let mut last = std::time::Instant::now() - Duration::from_secs(3);
        while stream.next().await.is_some() {
            if n.endpoint.is_closed() {
                break;
            }
            if last.elapsed() < Duration::from_secs(2) {
                continue;
            }
            last = std::time::Instant::now();
            n.emit(serde_json::json!({"t":"status"}));
        }
    });
    mutex(&node.background).push(watch);

    Ok(node)
}

async fn join_topic(node: &Arc<Node>, topic_hex: String, bootstrap: Vec<EndpointId>) -> Result<()> {
    {
        let mut topics = mutex(&node.topics);
        if let Some(old) = topics.remove(&topic_hex) {
            old.task.abort();
        }
    }
    let tid = parse_topic(&topic_hex)?;
    let topic = node.gossip.subscribe(tid, bootstrap).await?;
    let (sender, mut receiver) = topic.split();
    let events = node.events.clone();
    let key = topic_hex.clone();
    let task = tokio::spawn(async move {
        while let Some(Ok(ev)) = receiver.next().await {
            match ev {
                Event::Received(m) => {
                    push_event(
                        &events,
                        serde_json::json!({
                            "t": "gossip",
                            "topic": key,
                            "from": hex_id(m.delivered_from),
                            "data": B64.encode(&m.content),
                        }),
                    );
                }
                Event::NeighborUp(id) => {
                    push_event(
                        &events,
                        serde_json::json!({"t":"neighbor","topic": key,"peer": hex_id(id),"up": true}),
                    );
                }
                Event::NeighborDown(id) => {
                    push_event(
                        &events,
                        serde_json::json!({"t":"neighbor","topic": key,"peer": hex_id(id),"up": false}),
                    );
                }
                Event::Lagged => {}
            }
        }
    });
    // Two joins for one topic can race past the removal above.
    if let Some(old) = mutex(&node.topics).insert(topic_hex, TopicSlot { sender, task }) {
        old.task.abort();
    }
    Ok(())
}

fn with_node<T>(f: impl FnOnce(&Arc<Node>) -> T) -> Result<T> {
    let g = mutex(&NODE);
    let n = g.as_ref().ok_or_else(|| anyhow!("not started"))?;
    Ok(f(n))
}

fn start_inner(
    secret: *const u8,
    secret_len: usize,
    _data_dir: *const c_char,
    blob_dir: *const c_char,
) -> i32 {
    if secret.is_null() || secret_len < 32 {
        set_err("secret must be 32 bytes");
        return -1;
    }
    let mut seed = [0u8; 32];
    unsafe { std::ptr::copy_nonoverlapping(secret, seed.as_mut_ptr(), 32) };
    let blob = match cstr(blob_dir) {
        Ok(s) => PathBuf::from(s),
        Err(e) => {
            set_err(e);
            return -1;
        }
    };
    {
        let g = mutex(&NODE);
        if let Some(n) = g.as_ref() {
            if !n.endpoint.is_closed() {
                return 0;
            }
        }
    }
    if STARTING.swap(true, Ordering::AcqRel) {
        return 0;
    }
    let generation = GENERATION.load(Ordering::Acquire);
    rt().spawn(async move {
        let previous = mutex(&SHUTDOWN).take();
        if let Some(previous) = previous {
            let _ = tokio::time::timeout(Duration::from_secs(4), previous).await;
        }
        // A panic inside bind used to die with the worker. Catch it here so
        // the process stays up and the next start can try again.
        let joined = tokio::spawn(async move {
            tokio::time::timeout(Duration::from_secs(20), start_node(seed, blob)).await
        })
        .await;
        STARTING.store(false, Ordering::Release);
        let generation_ok = GENERATION.load(Ordering::Acquire) == generation;
        if !generation_ok {
            if let Ok(Ok(Ok(n))) = &joined {
                n.endpoint.close().await;
            }
            return;
        }
        match joined {
            Ok(Ok(Ok(n))) => *mutex(&NODE) = Some(n),
            Ok(Ok(Err(e))) => set_err(e),
            Ok(Err(_)) => set_err("endpoint bind timed out"),
            Err(e) => set_err(format!("endpoint bind panicked: {e}")),
        }
    });
    0
}

fn stop_inner() -> i32 {
    GENERATION.fetch_add(1, Ordering::AcqRel);
    STARTING.store(false, Ordering::Release);
    let node = mutex(&NODE).take();
    if let Some(n) = node {
        // Called from the Flutter UI thread. Driving iroh's shutdown here with
        // `block_on` ran QUIC teardown on that thread's small stack and froze
        // the UI, so it runs on the runtime and the next start waits for it.
        let job = rt().spawn(async move {
            for (_, t) in mutex(&n.topics).drain() {
                t.task.abort();
            }
            for t in mutex(&n.background).drain(..) {
                t.abort();
            }
            let conns: Vec<Connection> = mutex(&n.conns)
                .drain()
                .flat_map(|(_, list)| list.into_iter().map(|(_, c)| c))
                .collect();
            for c in &conns {
                c.close(0u32.into(), b"bye");
            }
            let _ = tokio::time::timeout(Duration::from_secs(3), async {
                n.router.shutdown().await.ok();
                n.endpoint.close().await;
            })
            .await;
        });
        *mutex(&SHUTDOWN) = Some(job);
    }
    0
}

fn send_inner(peer: *const c_char, data: *const u8, len: usize) -> i32 {
    let peer = match cstr(peer).and_then(|s| parse_id(&s)) {
        Ok(p) => p,
        Err(e) => {
            set_err(e);
            return 0;
        }
    };
    if data.is_null() {
        return 0;
    }
    let buf = unsafe { std::slice::from_raw_parts(data, len) }.to_vec();
    let n = match with_node(|n| n.clone()) {
        Ok(n) => n,
        Err(e) => {
            set_err(e);
            return 0;
        }
    };
    let sent = wait(async move {
        match tokio::time::timeout(Duration::from_secs(20), n.send_bytes(peer, &buf)).await {
            Ok(Ok(())) => true,
            Ok(Err(e)) => {
                set_err(e);
                false
            }
            Err(_) => {
                set_err("send timed out");
                false
            }
        }
    });
    match sent {
        Ok(true) => 1,
        Ok(false) => 0,
        Err(e) => {
            set_err(e);
            0
        }
    }
}

fn connect_inner(peer: *const c_char) -> i32 {
    let peer = match cstr(peer).and_then(|s| parse_id(&s)) {
        Ok(p) => p,
        Err(e) => {
            set_err(e);
            return 0;
        }
    };
    let n = match with_node(|n| n.clone()) {
        Ok(n) => n,
        Err(e) => {
            set_err(e);
            return 0;
        }
    };
    go(async move {
        match tokio::time::timeout(Duration::from_secs(20), n.get_direct(peer)).await {
            Ok(Ok(_)) => {}
            Ok(Err(e)) => set_err(e),
            Err(_) => set_err("connect timed out"),
        }
    });
    1
}

fn ticket_inner() -> *mut c_char {
    match with_node(|n| serde_json::to_string(&n.endpoint.addr()).unwrap_or_default()) {
        Ok(s) => heap_str(s),
        Err(e) => {
            set_err(e);
            std::ptr::null_mut()
        }
    }
}

fn add_ticket_inner(ticket: *const c_char) -> *mut c_char {
    let addr = match cstr(ticket).and_then(|s| parse_addr(&s)) {
        Ok(a) => a,
        Err(e) => {
            set_err(e);
            return std::ptr::null_mut();
        }
    };
    match with_node(|n| {
        n.remember(addr.clone());
        hex_id(addr.id)
    }) {
        Ok(id) => heap_str(id),
        Err(e) => {
            set_err(e);
            std::ptr::null_mut()
        }
    }
}

fn join_inner(topic: *const c_char, bootstrap: *const c_char) -> i32 {
    let topic = match cstr(topic) {
        Ok(t) => t,
        Err(e) => {
            set_err(e);
            return -1;
        }
    };
    let boot = cstr(bootstrap).unwrap_or_default();
    let ids: Vec<EndpointId> = boot
        .split(',')
        .filter(|s| !s.trim().is_empty())
        .filter_map(|s| parse_id(s).ok())
        .collect();
    let n = match with_node(|n| n.clone()) {
        Ok(n) => n,
        Err(e) => {
            set_err(e);
            return -1;
        }
    };
    go(async move {
        if let Err(e) = join_topic(&n, topic, ids).await {
            set_err(e);
        }
    });
    0
}

fn leave_inner(topic: *const c_char) -> i32 {
    let topic = match cstr(topic) {
        Ok(t) => t,
        Err(e) => {
            set_err(e);
            return -1;
        }
    };
    match with_node(|n| {
        if let Some(t) = mutex(&n.topics).remove(&topic) {
            t.task.abort();
        }
    }) {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

fn broadcast_inner(topic: *const c_char, data: *const u8, len: usize) -> i32 {
    let topic = match cstr(topic) {
        Ok(t) => t,
        Err(e) => {
            set_err(e);
            return -1;
        }
    };
    if data.is_null() {
        return -1;
    }
    if len > MAX_BROADCAST {
        set_err("message too large for topic");
        return -1;
    }
    let buf = Bytes::copy_from_slice(unsafe { std::slice::from_raw_parts(data, len) });
    let sender = match with_node(|n| mutex(&n.topics).get(&topic).map(|t| t.sender.clone())) {
        Ok(Some(s)) => s,
        Ok(None) => {
            set_err("not subscribed");
            return -1;
        }
        Err(e) => {
            set_err(e);
            return -1;
        }
    };
    let sent = wait(async move {
        match tokio::time::timeout(Duration::from_secs(12), sender.broadcast(buf)).await {
            Ok(Ok(_)) => true,
            Ok(Err(e)) => {
                set_err(e);
                false
            }
            Err(_) => {
                set_err("broadcast timed out");
                false
            }
        }
    });
    match sent {
        Ok(true) => 0,
        _ => -1,
    }
}

fn import_blob_inner(path: *const c_char) -> *mut c_char {
    let src = match cstr(path) {
        Ok(p) => PathBuf::from(p),
        Err(e) => {
            set_err(e);
            return std::ptr::null_mut();
        }
    };
    let n = match with_node(|n| n.clone()) {
        Ok(n) => n,
        Err(e) => {
            set_err(e);
            return std::ptr::null_mut();
        }
    };
    match (|| -> Result<String> {
        if std::fs::metadata(&src)?.len() > MAX_BLOB {
            return Err(anyhow!("file is too large to share"));
        }
        let hash = hex::encode(sha256_file(&src)?);
        let dest = n.blob_dir.join(&hash);
        if !dest.exists() && std::fs::rename(&src, &dest).is_err() {
            let tmp = dest.with_extension("import");
            std::fs::copy(&src, &tmp)?;
            std::fs::rename(&tmp, &dest)?;
        }
        let _ = std::fs::remove_file(&src);
        Ok(hash)
    })() {
        Ok(h) => heap_str(h),
        Err(e) => {
            set_err(e);
            std::ptr::null_mut()
        }
    }
}

fn fetch_blob_inner(hash: *const c_char, peer: *const c_char) -> i32 {
    let hash = match cstr(hash) {
        Ok(h) => h.to_lowercase(),
        Err(e) => {
            set_err(e);
            return 0;
        }
    };
    let peer = match cstr(peer).and_then(|s| parse_id(&s)) {
        Ok(p) => p,
        Err(e) => {
            set_err(e);
            return 0;
        }
    };
    let n = match with_node(|n| n.clone()) {
        Ok(n) => n,
        Err(e) => {
            set_err(e);
            return 0;
        }
    };
    match wait(async move { fetch_blob(&n, &hash, peer).await }).and_then(|r| r) {
        Ok(true) => 1,
        Ok(false) => 0,
        Err(e) => {
            set_err(e);
            0
        }
    }
}

fn cancel_fetch_inner(hash: *const c_char) -> i32 {
    let hash = match cstr(hash).and_then(|h| blob_name(&h)) {
        Ok(h) => h,
        Err(e) => {
            set_err(e);
            return 0;
        }
    };
    let n = match with_node(|n| n.clone()) {
        Ok(n) => n,
        Err(e) => {
            set_err(e);
            return 0;
        }
    };
    let mut g = mutex(&n.cancels);
    if let Some(flag) = g.get(&hash) {
        flag.store(true, Ordering::Relaxed);
    } else {
        g.insert(hash, Arc::new(AtomicBool::new(true)));
    }
    1
}

fn blob_path_inner(hash: *const c_char) -> *mut c_char {
    let hash = match cstr(hash) {
        Ok(h) => h.to_lowercase(),
        Err(e) => {
            set_err(e);
            return std::ptr::null_mut();
        }
    };
    let hash = match blob_name(&hash) {
        Ok(h) => h,
        Err(e) => {
            set_err(e);
            return std::ptr::null_mut();
        }
    };
    match with_node(|n| n.blob_dir.join(hash).to_string_lossy().into_owned()) {
        Ok(p) => heap_str(p),
        Err(e) => {
            set_err(e);
            std::ptr::null_mut()
        }
    }
}

fn status_inner() -> *mut c_char {
    let n = match with_node(|n| n.clone()) {
        Ok(n) => n,
        Err(e) => {
            set_err(e);
            return std::ptr::null_mut();
        }
    };
    let addr = n.endpoint.addr();
    let mut relays = Vec::new();
    let mut directs = Vec::new();
    for a in &addr.addrs {
        match a {
            iroh::TransportAddr::Relay(url) => relays.push(url.to_string()),
            iroh::TransportAddr::Ip(sa) => directs.push(sa.to_string()),
            _ => {}
        }
    }
    let home = relays.first().cloned();
    let links: Vec<serde_json::Value> = mutex(&n.conns)
        .iter()
        .filter_map(|(id, list)| {
            let conn = list
                .iter()
                .find(|(_, c)| c.close_reason().is_none())
                .map(|(_, c)| c.clone())?;
            let paths = conn.paths();
            let selected = paths.iter().find(|p| p.is_selected());
            let kind = selected.as_ref().map(|p| {
                if p.is_ip() { "direct" } else if p.is_relay() { "relay" } else { "none" }
            }).unwrap_or("none");
            let rtt = selected.as_ref().map(|p| p.rtt().as_millis() as u64);
            let routes: Vec<serde_json::Value> = paths.iter().filter_map(|p| {
                let (kind, address) = match p.remote_addr() {
                    iroh::TransportAddr::Relay(url) => ("relay", url.to_string()),
                    iroh::TransportAddr::Ip(addr) => ("direct", addr.to_string()),
                    _ => return None,
                };
                Some(serde_json::json!({"kind": kind, "address": address,
                    "selected": p.is_selected(), "rtt": p.rtt().as_millis() as u64}))
            }).collect();
            Some(serde_json::json!({"peer": hex_id(*id), "kind": kind, "rtt": rtt, "paths": routes}))
        })
        .collect();
    let topics = mutex(&n.topics).len();
    let body = serde_json::json!({
        "nodeId": hex_id(n.endpoint.id()),
        "running": !n.endpoint.is_closed(),
        "relayUrl": home,
        "relays": relays,
        "directAddrs": directs,
        "links": links,
        "engine": "iroh",
        "topics": topics,
        "routeTelemetry": 1,
    });
    heap_str(body.to_string())
}

fn poll_event_inner() -> *mut c_char {
    match with_node(|n| mutex(&n.events).pop_front()) {
        Ok(Some(s)) => heap_str(s),
        _ => std::ptr::null_mut(),
    }
}

fn last_error_inner() -> *mut c_char {
    match LAST_ERR.lock().ok().and_then(|g| g.clone()) {
        Some(s) => heap_str(s),
        None => std::ptr::null_mut(),
    }
}

// ---------------------------------------------------------------------------
// C ABI

const NULL: *mut c_char = std::ptr::null_mut();

#[no_mangle]
pub extern "C" fn mentos_start(
    secret: *const u8,
    secret_len: usize,
    data_dir: *const c_char,
    blob_dir: *const c_char,
) -> i32 {
    guard(-1, || start_inner(secret, secret_len, data_dir, blob_dir))
}

#[no_mangle]
pub extern "C" fn mentos_stop() -> i32 {
    guard(-1, stop_inner)
}

#[no_mangle]
pub extern "C" fn mentos_send(peer: *const c_char, data: *const u8, len: usize) -> i32 {
    guard(0, || send_inner(peer, data, len))
}

#[no_mangle]
pub extern "C" fn mentos_connect(peer: *const c_char) -> i32 {
    guard(0, || connect_inner(peer))
}

#[no_mangle]
pub extern "C" fn mentos_ticket() -> *mut c_char {
    guard(NULL, ticket_inner)
}

#[no_mangle]
pub extern "C" fn mentos_add_ticket(ticket: *const c_char) -> *mut c_char {
    guard(NULL, || add_ticket_inner(ticket))
}

#[no_mangle]
pub extern "C" fn mentos_join(topic: *const c_char, bootstrap: *const c_char) -> i32 {
    guard(-1, || join_inner(topic, bootstrap))
}

#[no_mangle]
pub extern "C" fn mentos_leave(topic: *const c_char) -> i32 {
    guard(-1, || leave_inner(topic))
}

#[no_mangle]
pub extern "C" fn mentos_broadcast(topic: *const c_char, data: *const u8, len: usize) -> i32 {
    guard(-1, || broadcast_inner(topic, data, len))
}

#[no_mangle]
pub extern "C" fn mentos_import_blob(path: *const c_char) -> *mut c_char {
    guard(NULL, || import_blob_inner(path))
}

#[no_mangle]
pub extern "C" fn mentos_fetch_blob(hash: *const c_char, peer: *const c_char) -> i32 {
    guard(0, || fetch_blob_inner(hash, peer))
}

#[no_mangle]
pub extern "C" fn mentos_cancel_fetch(hash: *const c_char) -> i32 {
    guard(0, || cancel_fetch_inner(hash))
}

#[no_mangle]
pub extern "C" fn mentos_blob_path(hash: *const c_char) -> *mut c_char {
    guard(NULL, || blob_path_inner(hash))
}

#[no_mangle]
pub extern "C" fn mentos_status() -> *mut c_char {
    guard(NULL, status_inner)
}

#[no_mangle]
pub extern "C" fn mentos_poll_event() -> *mut c_char {
    guard(NULL, poll_event_inner)
}

#[no_mangle]
pub extern "C" fn mentos_last_error() -> *mut c_char {
    guard(NULL, last_error_inner)
}

#[no_mangle]
pub extern "C" fn mentos_free(p: *mut c_char) {
    guard((), || {
        if !p.is_null() {
            unsafe { drop(CString::from_raw(p)) };
        }
    })
}

#[no_mangle]
pub extern "C" fn mentos_set_options(json: *const c_char) -> i32 {
    guard(-1, || diag::set_options_inner(json))
}

#[no_mangle]
pub extern "C" fn mentos_diagnostics() -> *mut c_char {
    guard(std::ptr::null_mut(), diag::diagnostics_inner)
}

#[no_mangle]
pub extern "C" fn mentos_ping(peer: *const c_char) -> i64 {
    guard(-1, || diag::ping_inner(peer))
}

#[no_mangle]
pub extern "C" fn mentos_network_change() -> i32 {
    guard(-1, diag::network_change_inner)
}

#[no_mangle]
pub extern "C" fn mentos_call_listen(call_id: *const c_char, peers: *const c_char) -> i32 {
    guard(-1, || call::listen_inner(call_id, peers))
}

#[no_mangle]
pub extern "C" fn mentos_call_dial(call_id: *const c_char, peer: *const c_char) -> i32 {
    guard(-1, || call::dial_inner(call_id, peer))
}

#[no_mangle]
pub extern "C" fn mentos_call_send(call_id: *const c_char, data: *const u8, len: usize) -> i32 {
    guard(-1, || call::send_inner(call_id, data, len))
}

#[no_mangle]
pub extern "C" fn mentos_call_recv(call_id: *const c_char, peer_out: *mut u8, buf: *mut u8, cap: usize) -> i32 {
    guard(-1, || call::recv_inner(call_id, peer_out, buf, cap))
}

#[no_mangle]
pub extern "C" fn mentos_call_max_datagram(call_id: *const c_char) -> i32 {
    guard(0, || call::max_datagram_inner(call_id))
}

#[no_mangle]
pub extern "C" fn mentos_call_drop_peer(call_id: *const c_char, peer: *const c_char) -> i32 {
    guard(-1, || call::drop_peer_inner(call_id, peer))
}

#[no_mangle]
pub extern "C" fn mentos_call_close(call_id: *const c_char) -> i32 {
    guard(-1, || call::close_inner(call_id))
}

#[no_mangle]
pub extern "C" fn mentos_call_stats(call_id: *const c_char) -> *mut c_char {
    guard(std::ptr::null_mut(), || call::stats_inner(call_id))
}
