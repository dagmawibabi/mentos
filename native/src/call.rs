//! Real-time media for calls and live streams.
//!
//! A call is a set of QUIC connections on the `mentos-call/0` ALPN, one per
//! remote participant, keyed by a call id the app chose during signalling.
//! Media rides unreliable QUIC datagrams: a late audio frame is worthless,
//! so nothing is retransmitted. iroh already encrypts every byte end to end.
//!
//! Inbound connections are accepted only for a call id the app registered
//! with [`listen_inner`] (or dialed itself), and only from the peers the app
//! allowed, so nobody can push media at a phone that did not answer.

use std::{
    collections::{HashMap, HashSet, VecDeque},
    os::raw::c_char,
    sync::{Arc, Mutex},
    time::Duration,
};

use anyhow::{anyhow, Result};
use bytes::Bytes;
use iroh::{
    endpoint::Connection,
    protocol::{AcceptError, ProtocolHandler},
    EndpointId,
};

use crate::{cstr, go, heap_str, hex_id, mutex, parse_id, set_err, with_node, Node};

pub(crate) const CALL_ALPN: &[u8] = b"mentos-call/0";

/// Per call, packets waiting for the app. Beyond this the oldest are
/// dropped: stale media is worse than missing media.
const MAX_QUEUED: usize = 400;
const MAX_ID: usize = 80;

struct Call {
    allowed: HashSet<EndpointId>,
    conns: HashMap<EndpointId, Connection>,
    inbox: VecDeque<(EndpointId, Bytes)>,
}

static CALLS: Mutex<Option<HashMap<String, Call>>> = Mutex::new(None);

fn with_calls<T>(f: impl FnOnce(&mut HashMap<String, Call>) -> T) -> T {
    let mut g = mutex(&CALLS);
    f(g.get_or_insert_with(HashMap::new))
}

fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= MAX_ID && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn emit(id: &str, peer: EndpointId, up: bool) {
    let _ = with_node(|n| n.emit(serde_json::json!({"t": "call", "id": id, "peer": hex_id(peer), "up": up})));
}

/// Registers the connection and pumps its datagrams into the call's inbox
/// until it closes.
fn attach(call_id: String, peer: EndpointId, conn: Connection) {
    let fresh = with_calls(|calls| {
        let Some(c) = calls.get_mut(&call_id) else {
            return false;
        };
        if let Some(old) = c.conns.insert(peer, conn.clone()) {
            old.close(0u32.into(), b"replaced");
        }
        true
    });
    if !fresh {
        conn.close(0u32.into(), b"no such call");
        return;
    }
    emit(&call_id, peer, true);
    go(async move {
        loop {
            match conn.read_datagram().await {
                Ok(data) => with_calls(|calls| {
                    if let Some(c) = calls.get_mut(&call_id) {
                        if c.inbox.len() >= MAX_QUEUED {
                            c.inbox.pop_front();
                        }
                        c.inbox.push_back((peer, data));
                    }
                }),
                Err(_) => break,
            }
        }
        let was = with_calls(|calls| {
            calls
                .get_mut(&call_id)
                .map(|c| match c.conns.get(&peer) {
                    Some(cur) if cur.stable_id() == conn.stable_id() => {
                        c.conns.remove(&peer);
                        true
                    }
                    _ => false,
                })
                .unwrap_or(false)
        });
        if was {
            emit(&call_id, peer, false);
        }
    });
}

#[derive(Clone)]
pub(crate) struct CallProto;

impl std::fmt::Debug for CallProto {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("CallProto")
    }
}

impl ProtocolHandler for CallProto {
    fn accept(&self, connection: Connection) -> impl std::future::Future<Output = Result<(), AcceptError>> + Send {
        async move {
            let peer = connection.remote_id();
            let Ok(Ok((mut send, mut recv))) =
                tokio::time::timeout(Duration::from_secs(10), connection.accept_bi()).await
            else {
                return Ok(());
            };
            // A peer that opens the stream and never names a call must not
            // hold the connection open forever.
            let named = tokio::time::timeout(Duration::from_secs(10), async {
                let mut len = [0u8; 1];
                recv.read_exact(&mut len).await.ok()?;
                if len[0] as usize > MAX_ID {
                    return None;
                }
                let mut raw = vec![0u8; len[0] as usize];
                recv.read_exact(&mut raw).await.ok()?;
                Some(raw)
            })
            .await;
            let Ok(Some(raw)) = named else {
                connection.close(1u32.into(), b"no call id");
                return Ok(());
            };
            let call_id = String::from_utf8_lossy(&raw).into_owned();
            let ok = valid_id(&call_id)
                && with_calls(|calls| calls.get(&call_id).is_some_and(|c| c.allowed.contains(&peer)));
            let _ = send.write_all(&[ok as u8]).await;
            let _ = send.finish();
            if !ok {
                connection.close(1u32.into(), b"not invited");
                return Ok(());
            }
            attach(call_id, peer, connection.clone());
            connection.closed().await;
            Ok(())
        }
    }
}

fn parse_peers(list: &str) -> Result<HashSet<EndpointId>> {
    list.split(',').map(str::trim).filter(|s| !s.is_empty()).map(parse_id).collect()
}

/// Opens (or extends) a call and allows inbound connections from `peers`
/// (comma separated node ids).
pub(crate) fn listen_inner(call_id: *const c_char, peers: *const c_char) -> i32 {
    let r = (|| -> Result<()> {
        let id = cstr(call_id)?;
        if !valid_id(&id) {
            return Err(anyhow!("bad call id"));
        }
        let allowed = parse_peers(&cstr(peers)?)?;
        with_calls(|calls| {
            calls
                .entry(id)
                .or_insert_with(|| Call { allowed: HashSet::new(), conns: HashMap::new(), inbox: VecDeque::new() })
                .allowed
                .extend(allowed)
        });
        Ok(())
    })();
    match r {
        Ok(()) => 0,
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

/// Dials `peer` for an already registered call. Returns at once; a
/// `{"t":"call","up":true}` event reports the connection.
pub(crate) fn dial_inner(call_id: *const c_char, peer: *const c_char) -> i32 {
    let r = (|| -> Result<(String, EndpointId, Arc<Node>)> {
        let id = cstr(call_id)?;
        let peer = parse_id(&cstr(peer)?)?;
        let known = with_calls(|calls| calls.get(&id).is_some_and(|c| c.allowed.contains(&peer)));
        if !known {
            return Err(anyhow!("call not registered for that peer"));
        }
        Ok((id, peer, with_node(|n| n.clone())?))
    })();
    let (id, peer, n) = match r {
        Ok(v) => v,
        Err(e) => {
            set_err(e);
            return -1;
        }
    };
    go(async move {
        let attempt = async {
            let conn = n.endpoint.connect(n.addr_for(peer), CALL_ALPN).await?;
            let (mut send, mut recv) = conn.open_bi().await?;
            send.write_all(&[id.len() as u8]).await?;
            send.write_all(id.as_bytes()).await?;
            send.finish()?;
            let mut ok = [0u8; 1];
            recv.read_exact(&mut ok).await?;
            if ok[0] != 1 {
                return Err(anyhow!("peer declined the media connection"));
            }
            Ok::<_, anyhow::Error>(conn)
        };
        match tokio::time::timeout(Duration::from_secs(20), attempt).await {
            Ok(Ok(conn)) => attach(id, peer, conn),
            Ok(Err(e)) => {
                set_err(e);
                emit(&id, peer, false);
            }
            Err(_) => {
                set_err("call dial timed out");
                emit(&id, peer, false);
            }
        }
    });
    0
}

/// Sends one datagram to every connected participant. Returns how many
/// accepted it, or -1 when the call is unknown.
pub(crate) fn send_inner(call_id: *const c_char, data: *const u8, len: usize) -> i32 {
    let Ok(id) = cstr(call_id) else {
        return -1;
    };
    if data.is_null() || len == 0 {
        return 0;
    }
    let bytes = Bytes::copy_from_slice(unsafe { std::slice::from_raw_parts(data, len) });
    let conns: Option<Vec<Connection>> = with_calls(|calls| calls.get(&id).map(|c| c.conns.values().cloned().collect()));
    let Some(conns) = conns else {
        return -1;
    };
    let mut sent = 0;
    for c in conns {
        if c.max_datagram_size().is_some_and(|m| m >= len) && c.send_datagram(bytes.clone()).is_ok() {
            sent += 1;
        }
    }
    sent
}

/// Smallest datagram any participant's path allows right now, or 0.
pub(crate) fn max_datagram_inner(call_id: *const c_char) -> i32 {
    let Ok(id) = cstr(call_id) else {
        return 0;
    };
    with_calls(|calls| {
        calls
            .get(&id)
            .and_then(|c| c.conns.values().filter_map(|x| x.max_datagram_size()).min())
            .map(|m| m.min(i32::MAX as usize) as i32)
            .unwrap_or(0)
    })
}

/// Pops one packet: writes the sender's 32-byte id into `peer_out` and the
/// payload into `buf`. Returns the payload length, 0 when empty, -1 when the
/// call is unknown, -2 when `cap` is too small (the packet is dropped).
pub(crate) fn recv_inner(call_id: *const c_char, peer_out: *mut u8, buf: *mut u8, cap: usize) -> i32 {
    let Ok(id) = cstr(call_id) else {
        return -1;
    };
    if peer_out.is_null() || buf.is_null() {
        return -1;
    }
    let next = with_calls(|calls| calls.get_mut(&id).map(|c| c.inbox.pop_front()));
    match next {
        None => -1,
        Some(None) => 0,
        Some(Some((peer, data))) => {
            if data.len() > cap {
                return -2;
            }
            unsafe {
                std::ptr::copy_nonoverlapping(peer.as_bytes().as_ptr(), peer_out, 32);
                std::ptr::copy_nonoverlapping(data.as_ptr(), buf, data.len());
            }
            data.len() as i32
        }
    }
}

/// Hangs up: closes every media connection and forgets the call.
pub(crate) fn close_inner(call_id: *const c_char) -> i32 {
    let Ok(id) = cstr(call_id) else {
        return -1;
    };
    let gone = with_calls(|calls| calls.remove(&id));
    if let Some(c) = gone {
        for conn in c.conns.values() {
            conn.close(0u32.into(), b"hangup");
        }
    }
    0
}

/// Drops one participant from a call (they left a group call).
pub(crate) fn drop_peer_inner(call_id: *const c_char, peer: *const c_char) -> i32 {
    let (Ok(id), Ok(peer)) = (cstr(call_id), cstr(peer).and_then(|p| parse_id(&p))) else {
        return -1;
    };
    let conn = with_calls(|calls| {
        calls.get_mut(&id).and_then(|c| {
            c.allowed.remove(&peer);
            c.conns.remove(&peer)
        })
    });
    if let Some(conn) = conn {
        conn.close(0u32.into(), b"left");
    }
    0
}

/// Live link quality per participant, as JSON.
pub(crate) fn stats_inner(call_id: *const c_char) -> *mut c_char {
    let Ok(id) = cstr(call_id) else {
        return std::ptr::null_mut();
    };
    let conns: Vec<(EndpointId, Connection)> =
        with_calls(|calls| calls.get(&id).map(|c| c.conns.iter().map(|(k, v)| (*k, v.clone())).collect()).unwrap_or_default());
    let peers: Vec<serde_json::Value> = conns
        .iter()
        .map(|(peer, c)| {
            let s = c.stats();
            let sel = c.paths().iter().find(|p| p.is_selected()).map(|p| (p.is_ip(), p.rtt()));
            serde_json::json!({
                "peer": hex_id(*peer),
                "direct": sel.map(|x| x.0),
                "rttMs": sel.map(|x| x.1.as_secs_f64() * 1000.0),
                "txBytes": s.udp_tx.bytes,
                "rxBytes": s.udp_rx.bytes,
                "lostPackets": s.lost_packets,
                "maxDatagram": c.max_datagram_size(),
            })
        })
        .collect();
    heap_str(serde_json::json!({ "id": id, "peers": peers }).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn call_ids_are_restricted() {
        assert!(valid_id("abc-123_X"));
        assert!(!valid_id(""));
        assert!(!valid_id("../etc"));
        assert!(!valid_id(&"a".repeat(81)));
    }

    #[test]
    fn unknown_calls_are_rejected() {
        let id = std::ffi::CString::new("never-registered").unwrap();
        let mut peer = [0u8; 32];
        let mut buf = [0u8; 16];
        assert_eq!(recv_inner(id.as_ptr(), peer.as_mut_ptr(), buf.as_mut_ptr(), 16), -1);
        assert_eq!(send_inner(id.as_ptr(), buf.as_ptr(), 4), -1);
    }
}
