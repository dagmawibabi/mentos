//! Network diagnostics and privacy transports.
//!
//! Diagnostics read what iroh already measures: the net report (UDP reach,
//! NAT mapping behaviour, public addresses, relay latencies), the home relay
//! connection, and QUIC statistics for every live connection.
//!
//! Privacy modes are applied when the endpoint binds:
//! - `standard`: direct UDP paths plus relays.
//! - `relay`: no IP transports. Peers only ever see the relay's address, never ours.
//! - `tor`: relay-only, and all relay/DNS HTTP(S) traffic goes through a local
//!   HTTP CONNECT proxy (Orbot exposes one on 127.0.0.1:8118), so the relay sees
//!   a Tor exit instead of this device.

use std::{os::raw::c_char, sync::Mutex, time::Duration};

use anyhow::{anyhow, Result};
use iroh::{
    endpoint::{presets, Builder},
    unstable_net_report::Probe,
    Endpoint, TransportAddr, Watcher,
};

use crate::{cstr, heap_str, hex_id, mutex, parse_id, set_err, wait, with_node};

#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) enum Privacy {
    #[default]
    Standard,
    RelayOnly,
    Tor,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct Options {
    pub privacy: Privacy,
    pub proxy: Option<String>,
}

static OPTIONS: Mutex<Option<Options>> = Mutex::new(None);

pub(crate) fn options() -> Options {
    mutex(&OPTIONS).clone().unwrap_or_default()
}

pub(crate) fn parse_options(json: &str) -> Result<Options> {
    let v: serde_json::Value = serde_json::from_str(json)?;
    let privacy = match v.get("privacy").and_then(|p| p.as_str()).unwrap_or("standard") {
        "standard" => Privacy::Standard,
        "relay" => Privacy::RelayOnly,
        "tor" => Privacy::Tor,
        other => return Err(anyhow!("unknown privacy mode {other}")),
    };
    let proxy = v
        .get("proxy")
        .and_then(|p| p.as_str())
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .map(str::to_owned);
    if let Some(p) = &proxy {
        let url = url::Url::parse(p).map_err(|e| anyhow!("bad proxy url: {e}"))?;
        if url.scheme() != "http" && url.scheme() != "https" {
            return Err(anyhow!("proxy must be an http:// CONNECT proxy"));
        }
    }
    if privacy == Privacy::Tor && proxy.is_none() {
        return Err(anyhow!("tor mode needs a proxy url"));
    }
    Ok(Options { privacy, proxy })
}

/// The endpoint builder with this device's privacy choices applied.
pub(crate) fn builder() -> Result<Builder> {
    let o = options();
    let mut b = Endpoint::builder(presets::N0);
    if o.privacy != Privacy::Standard {
        b = b.clear_ip_transports();
    }
    if let Some(p) = o.proxy.as_deref() {
        b = b.proxy_url(url::Url::parse(p)?);
    }
    Ok(b)
}

fn privacy_name(p: &Privacy) -> &'static str {
    match p {
        Privacy::Standard => "standard",
        Privacy::RelayOnly => "relay",
        Privacy::Tor => "tor",
    }
}

fn probe_name(p: Probe) -> &'static str {
    match p {
        Probe::Https => "https",
        Probe::QadIpv4 => "udp4",
        Probe::QadIpv6 => "udp6",
        #[allow(unreachable_patterns)]
        _ => "other",
    }
}

fn ms(d: Duration) -> f64 {
    (d.as_secs_f64() * 1000.0 * 10.0).round() / 10.0
}

fn addr_json(a: &TransportAddr) -> Option<(&'static str, String)> {
    match a {
        TransportAddr::Relay(url) => Some(("relay", url.to_string())),
        TransportAddr::Ip(sa) => Some(("direct", sa.to_string())),
        _ => None,
    }
}

pub(crate) fn diagnostics_inner() -> *mut c_char {
    let n = match with_node(|n| n.clone()) {
        Ok(n) => n,
        Err(e) => {
            set_err(e);
            return std::ptr::null_mut();
        }
    };
    let opts = options();
    let built = wait(async move {
        let ep = &n.endpoint;
        let report = ep.net_report().get();
        let net = report.map(|r| {
            let latencies: Vec<serde_json::Value> = r
                .relay_latency
                .iter()
                .map(|(probe, url, d)| {
                    serde_json::json!({"relay": url.to_string(), "probe": probe_name(probe), "ms": ms(d)})
                })
                .collect();
            serde_json::json!({
                "udpV4": r.udp_v4,
                "udpV6": r.udp_v6,
                "mappingVariesV4": r.mapping_varies_by_dest_ipv4,
                "mappingVariesV6": r.mapping_varies_by_dest_ipv6,
                "preferredRelay": r.preferred_relay.as_ref().map(|u| u.to_string()),
                "globalV4": r.global_v4.map(|a| a.to_string()),
                "globalV6": r.global_v6.map(|a| a.to_string()),
                "captivePortal": r.captive_portal,
                "latencies": latencies,
            })
        });
        let relays: Vec<serde_json::Value> = ep
            .home_relay_status()
            .get()
            .iter()
            .map(|s| {
                serde_json::json!({
                    "url": s.url().to_string(),
                    "connected": s.is_connected(),
                    "error": s.last_error().map(|e| e.to_string()),
                })
            })
            .collect();
        let bound: Vec<String> = ep.bound_sockets().iter().map(|s| s.to_string()).collect();

        let conns: Vec<(iroh::EndpointId, iroh::endpoint::Connection)> = mutex(&n.conns)
            .iter()
            .flat_map(|(id, list)| {
                list.iter()
                    .filter(|(_, c)| c.close_reason().is_none())
                    .map(move |(_, c)| (*id, c.clone()))
            })
            .collect();
        let mut peers = Vec::new();
        for (id, conn) in conns {
            let s = conn.stats();
            let paths: Vec<serde_json::Value> = conn
                .paths()
                .iter()
                .filter_map(|p| {
                    let (kind, address) = addr_json(&p.remote_addr())?;
                    let ps = p.stats();
                    Some(serde_json::json!({
                        "kind": kind,
                        "address": address,
                        "selected": p.is_selected(),
                        "rttMs": ms(p.rtt()),
                        "cwnd": ps.cwnd,
                        "txBytes": ps.udp_tx.bytes,
                        "rxBytes": ps.udp_rx.bytes,
                        "lostPackets": ps.lost_packets,
                        "congestionEvents": ps.congestion_events,
                    }))
                })
                .collect();
            let known: Vec<serde_json::Value> = match ep.remote_info(id).await {
                Some(info) => info
                    .addrs()
                    .filter_map(|a| {
                        let (kind, address) = addr_json(a.addr())?;
                        let active = matches!(a.usage(), iroh::endpoint::TransportAddrUsage::Active);
                        Some(serde_json::json!({"kind": kind, "address": address, "active": active}))
                    })
                    .collect(),
                None => Vec::new(),
            };
            peers.push(serde_json::json!({
                "peer": hex_id(id),
                "alpn": String::from_utf8_lossy(conn.alpn()).to_string(),
                "side": format!("{:?}", conn.side()).to_lowercase(),
                "txBytes": s.udp_tx.bytes,
                "rxBytes": s.udp_rx.bytes,
                "txDatagrams": s.udp_tx.datagrams,
                "rxDatagrams": s.udp_rx.datagrams,
                "lostPackets": s.lost_packets,
                "lostBytes": s.lost_bytes,
                "paths": paths,
                "knownAddrs": known,
            }));
        }
        serde_json::json!({
            "nodeId": hex_id(ep.id()),
            "privacy": privacy_name(&opts.privacy),
            "proxy": opts.proxy,
            "net": net,
            "relays": relays,
            "bound": bound,
            "connections": peers,
            "topics": mutex(&n.topics).len(),
        })
    });
    match built {
        Ok(v) => heap_str(v.to_string()),
        Err(e) => {
            set_err(e);
            std::ptr::null_mut()
        }
    }
}

/// Dials [peer] if needed and returns the selected path's round trip in
/// microseconds, or -1.
pub(crate) fn ping_inner(peer: *const c_char) -> i64 {
    let peer = match cstr(peer).and_then(|s| parse_id(&s)) {
        Ok(p) => p,
        Err(e) => {
            set_err(e);
            return -1;
        }
    };
    let n = match with_node(|n| n.clone()) {
        Ok(n) => n,
        Err(e) => {
            set_err(e);
            return -1;
        }
    };
    let r = wait(async move {
        let conn = tokio::time::timeout(Duration::from_secs(15), n.get_direct(peer))
            .await
            .map_err(|_| anyhow!("ping timed out"))??;
        // A fresh connection's RTT estimate settles after a few packets.
        tokio::time::sleep(Duration::from_millis(250)).await;
        let paths = conn.paths();
        let rtt = paths
            .iter()
            .find(|p| p.is_selected())
            .map(|p| p.rtt())
            .ok_or_else(|| anyhow!("no selected path"))?;
        Ok::<i64, anyhow::Error>(rtt.as_micros() as i64)
    });
    match r {
        Ok(Ok(v)) => v,
        Ok(Err(e)) | Err(e) => {
            set_err(e);
            -1
        }
    }
}

pub(crate) fn set_options_inner(json: *const c_char) -> i32 {
    match cstr(json).and_then(|s| parse_options(&s)) {
        Ok(o) => {
            *mutex(&OPTIONS) = Some(o);
            0
        }
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

pub(crate) fn network_change_inner() -> i32 {
    match with_node(|n| n.clone()) {
        Ok(n) => {
            crate::go(async move { n.endpoint.network_change().await });
            0
        }
        Err(e) => {
            set_err(e);
            -1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_modes() {
        assert_eq!(parse_options(r#"{"privacy":"relay"}"#).unwrap().privacy, Privacy::RelayOnly);
        assert_eq!(parse_options("{}").unwrap().privacy, Privacy::Standard);
        let tor = parse_options(r#"{"privacy":"tor","proxy":"http://127.0.0.1:8118"}"#).unwrap();
        assert_eq!(tor.privacy, Privacy::Tor);
        assert_eq!(tor.proxy.as_deref(), Some("http://127.0.0.1:8118"));
    }

    #[test]
    fn rejects_bad_options() {
        assert!(parse_options(r#"{"privacy":"tor"}"#).is_err());
        assert!(parse_options(r#"{"privacy":"nope"}"#).is_err());
        assert!(parse_options(r#"{"proxy":"socks5://127.0.0.1:9050"}"#).is_err());
        assert!(parse_options("not json").is_err());
    }
}
