# Mentos roadmap

Mentos has no central server. Content lives on the device that made it, and it reaches other people only while that device is reachable, unless the author lets someone keep a copy. Everything is signed, everything travels over iroh (direct QUIC with hole punching, encrypted relays as the fallback), and the user can always see where their data is and who holds it.

This document turns the feature list and the manifesto into ordered, buildable work. Each item says what "done" means and which layer it touches: **Core** (the Rust iroh node plus the Dart protocol engine, which together should become the reusable *Mentos Core*) or **App** (Flutter UI).

Status: ✅ shipped on this branch · 🚧 partial · 📐 designed, not built · ⏳ later

## 0. Architecture: App and Core

Goal: other apps can be built on the same core.

| Layer | Contents today | Target |
|---|---|---|
| `native/` (Rust) | iroh endpoint, direct ALPN, blob ALPN, gossip | `mentos-core` crate: same, plus diagnostics, privacy transports, calls/streams ALPN |
| `lib/net`, `lib/data` (Dart) | Engine (protocol, auth, sync, delivery), encrypted SQLite, media store | `mentos_core` Dart package with no Flutter imports, consumed by the app |
| `lib/features`, `lib/widgets` | UI | stays in the app |

Steps: 📐 move `lib/net`, `lib/data`, `lib/core/crypto` into `packages/mentos_core` once the Engine is split by domain (social, chat, spaces, files, network). New features in this roadmap go in their own files so the split is mechanical.

## 1. Iroh core improvements

| Feature | Plan | Status |
|---|---|---|
| Network diagnostics | Expose iroh's net report (UDP v4/v6, NAT mapping type, public addresses, captive portal, latency to every relay, preferred relay), home relay connection state, bound sockets, and per-connection QUIC stats (RTT, cwnd, bytes, loss, congestion events, path list). Diagnostics screen with a one-tap shareable report. | ✅ |
| Stronger anonymity | Three privacy levels: **Standard** (direct + relay), **Hide my IP** (relay-only: no IP transports, so peers never learn your address), **Tor** (relay-only, and relay/DNS traffic goes through a local Tor HTTP proxy such as Orbot on `127.0.0.1:8118`, so the relay sees a Tor exit instead of you). | ✅ |
| Node explorer | Every node on the map opens a detail page: identity, relationship, routes, live RTT, traffic counters, topics shared, items served, kept copies, ping. | ✅ |
| Local discovery | mDNS address lookup so phones on the same Wi-Fi connect with no internet. | 📐 |
| Custom relays | Let users add/self-host relays; show which relay each peer uses. | 📐 |
| iroh-blobs | Replace the custom blob ALPN with iroh-blobs for resumable, range-verified (BLAKE3) transfers and multi-source downloads (torrent-style). Unlocks pause/resume across restarts. | 📐 |
| iroh-docs | Use for opt-in replication ("let others store my stuff"): range-based set reconciliation instead of full re-queries. | ⏳ |

## 2. Social experience (Instagram / X / Telegram / Threads)

| Feature | Plan | Status |
|---|---|---|
| View counters | Views on every feed post and channel post. Groups: "Seen by" list with names and times, like Telegram. | ✅ |
| Story reactions | Quick emoji reactions on stories, delivered to the author and shown in the viewer list. | ✅ |
| Story stickers | Emoji, text, link, mention and location-free "question" stickers placed on the story; link stickers open the link, mention stickers open the profile. | ✅ |
| Channels (Telegram-style) | One-to-many broadcast with subscribe/unsubscribe, subscriber count, per-post views, pinned post, comments on/off, silent posts, a directory of channels from people you know. | ✅ |
| Notifications | Real OS notifications with per-category switches (DMs, groups, mentions, replies, likes, follows, invites, transfers, stories), message previews on/off, quiet hours. | ✅ |
| Existing | Feed, stories, likes, bookmarks, comments, replies, reposts, polls, DMs, group chats, spaces with channels and forums, broadcasts. | ✅ |
| Threads-style polish | Quote posts, thread composer (multi-part post), "replies" tab on profiles. | 📐 |
| Hashtags & mentions | Tappable `#tag` / `@name`, local tag pages. | 📐 |

## 3. User control and nerdy tools

| Feature | Plan | Status |
|---|---|---|
| Data Explorer | Browse everything stored on the device: every table, every signed item by kind and scope, sizes, raw signed envelopes with on-device signature verification, custody grants, files, delivery queue. Export everything (or a filter) as JSON. | ✅ |
| Hosting files | Collections/folders, descriptions and tags, pin/unhost, per-file request counts, search across everyone you know, "seeding" view. | ✅ |
| Transfer controls | Auto-accept from contacts, max auto-accept size, concurrent transfer limit, retry failed, clear finished, per-transfer route/RTT/speed details. | ✅ |
| Accounts | Multiple identities on one device with a switcher, restore from phrase, per-account storage. | ✅ |
| Biometrics | Biometric unlock; PIN with salted slow hash and attempt throttling. | ✅ |

## 4. Big new features (need design sign-off)

### Voice and video calls 📐
- Signalling over the existing direct channel (`call` control messages: offer, accept, decline, end, mute state).
- Media over a dedicated `mentos-call/0` ALPN: one QUIC connection, unreliable datagrams for audio/video frames, a stream for control. iroh already gives E2E encryption and NAT traversal; relay fallback works but adds latency.
- Audio: Opus 48 kHz mono 20 ms frames (needs an Opus codec in Rust, e.g. `audiopus`), capture/playback through a small platform plugin.
- Video: H.264/VP8 from the platform encoder (Android MediaCodec) to keep CPU low.
- Group calls: mesh up to ~4 peers; above that an SFU role picked among participants (the best-connected peer forwards).
- Risk: needs real-device testing on two phones; the codec and audio plugin are the bulk of the work.

### Streaming 📐
Live broadcast to a channel: the streamer publishes segments as blobs and announces them on the channel's gossip topic; viewers fetch from the streamer and from other viewers (each viewer re-serves recent segments, so load spreads like a swarm). Shares the codec work with calls.

### Digital payments (peer-maintained currency) 📐 — needs a decision
A currency without a server must prevent double spending. Options:
1. **Mutual credit** (recommended first): balances are bilateral IOUs signed by both sides; no global ledger, no double-spend problem, works offline. Good for tipping and paying friends.
2. **Account chains with witness quorum** (Nano-style block lattice): each account has its own signed chain; a send is final when a quorum of online witness nodes co-sign it. Needs a Sybil-resistant witness set, which is the hard part.
3. **Integrate an existing network** (e.g. Lightning or a stablecoin) instead of a new currency.
Mentos should not ship anything that looks like money until the threat model is written and reviewed.

## 5. Reliability work still open (from `review/PROJECT_REVIEW_2026-10-10.md`)
Invite key disclosure before acceptance, key rotation on leave, plaintext key files at rest, bounded gossip queues. These come before a public release.

## 6. Release
APK build needs: Rust Android targets + NDK (`native/build-android.ps1`), then `flutter build apk --release`.
