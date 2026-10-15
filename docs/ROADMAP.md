# Mentos roadmap

Mentos has no central server. Content lives on the device that made it, and it reaches other people only while that device is reachable, unless the author lets someone keep a copy. Everything is signed, everything travels over iroh (direct QUIC with hole punching, encrypted relays as the fallback), and the user can always see where their data is and who holds it.

This document turns the feature list and the manifesto into ordered, buildable work. Each item says what "done" means and which layer it touches: **Core** (the Rust iroh node plus the Dart protocol engine, which together should become the reusable *Mentos Core*) or **App** (Flutter UI).

Status: ✅ built and tested · 🚧 partly built · 📐 designed, not built · ⏳ later

## 0. Architecture: App and Core

Goal: other apps can be built on the same core.

| Layer | Contents today | Target |
|---|---|---|
| `native/` (Rust) | iroh endpoint, direct ALPN, blob ALPN, gossip, diagnostics, privacy transports | `mentos-core` crate: same, plus calls/streams ALPN |
| `lib/net`, `lib/data` (Dart) | Engine (protocol, auth, sync, delivery), encrypted SQLite, media store | `mentos_core` Dart package with no Flutter imports, consumed by the app |
| `lib/features`, `lib/widgets` | UI | stays in the app |

📐 Move `lib/net`, `lib/data` and `lib/core/crypto` into `packages/mentos_core` once the Engine is split by domain (social, chat, spaces, files, network). New code is already going into separate files that use only the Engine's public surface (`engine_net.dart`, `engine_data.dart`), so they can move as they are.

## 1. Iroh core

| Feature | What was built | Status |
|---|---|---|
| Network diagnostics | Native `mentos_diagnostics` exposes iroh's net report (UDP v4/v6, NAT mapping behaviour, public addresses, captive portal, latency to every relay, preferred relay), home relay state, bound sockets, and per-connection QUIC stats (RTT, congestion window, bytes, loss, path list, known addresses). Diagnostics screen with a plain-language summary and a shareable report (peer ids shortened). Verified against live n0 relays. | ✅ |
| Stronger anonymity | Privacy modes chosen before the endpoint binds: **Standard**; **Hide my IP** (relay only: no IP sockets, so peers never learn your address); **Tor** (relay only, with relay and DNS traffic through a local HTTP CONNECT proxy such as Orbot on `127.0.0.1:8118`). Verified: in Tor mode the node binds no local sockets, its ticket carries only a relay address, and two nodes still connect and ping. | ✅ |
| Node explorer | Every node opens a detail page: relationship, route diagram, ping with history, traffic and loss, known addresses, shared gossip topics, custody in both directions, identity. | ✅ |
| Local discovery | mDNS address lookup so phones on the same Wi-Fi connect without internet. | 📐 |
| Custom relays | Let people add or self-host relays; show which relay each peer uses. | 📐 |
| iroh-blobs | Replace the custom blob protocol with iroh-blobs: resumable, BLAKE3-verified ranges and downloading from several seeders at once. Needed for pause/resume that survives a restart. | 📐 |
| iroh-docs | Range-based set reconciliation for opt-in replication instead of full re-queries. | ⏳ |

## 2. Social (Instagram, X, Telegram, Threads)

| Feature | What was built | Status |
|---|---|---|
| View counters | A post counts a view after a moment on screen, like an impression. Cards show the count; authors see who viewed. Views now carry the same keep consent as likes, so counts survive restarts. | ✅ |
| Seen by (groups) | Delivery records when each recipient confirmed and read a message. Group message info lists readers with times, then delivered, then waiting. | ✅ |
| Story reactions | Reaction bar (❤️ 😂 😮 😢 🔥 👏). Fixed two bugs: reactions on stories were rejected by every recipient, and likes, views and reactions went to the viewer's followers instead of the story's author. | ✅ |
| Story stickers and links | Emoji, text, link, @mention and question stickers; drag, pinch and long-press to remove. Links open after a confirmation; only http/https are accepted. | ✅ |
| Story replies | Replies and answers to questions land in the author's DMs with a header showing what they answer. | ✅ |
| Channels | Signed subscriptions the owner can count, subscribe/leave/mute, pinned post, comments on/off, silent posts, view counts, channel directory. With comments off, comments are hidden and the reply box disappears everywhere; a modified client could still send one, but it is not shown. | ✅ |
| Notifications | OS notifications per category (DMs, groups, mentions, replies, likes, followers, stories, channels, invitations, transfers), previews on/off, quiet hours, muted chats (mentions still get through). | ✅ |
| Background delivery | Notifications only arrive while the app process is alive. A foreground service (Android) would keep the node running. | 📐 |
| Already there | Feed, stories, likes, bookmarks, comments, replies, reposts, polls, DMs, group chats, spaces with channels and forums. | ✅ |
| Threads-style polish | Quote posts, multi-part thread composer, a Replies tab on profiles. | 📐 |
| Hashtags and mentions in posts | Tappable `#tag` and `@name`, local tag pages. Mentions already trigger notifications. | 🚧 |

## 3. Control and nerdy tools

| Feature | What was built | Status |
|---|---|---|
| Data Explorer | Every signed item (yours, kept, and live in memory) by kind and scope, search, on-device signature verification, what points at what, raw tables with secrets hidden, delete local copies, and JSON export that keeps signatures (secrets redacted unless asked). | ✅ |
| Hosting files | Description, folder and tags; filter by folder; sort by newest, name, size or downloads; search #tags; real download counts; details with seeders and hash. | ✅ |
| Transfer controls | Download queue with a parallel limit, auto-accept from people you follow up to a size, retry, clear finished, combined speed and time left. | ✅ |
| Pause and resume | Needs iroh-blobs ranges (see section 1). | 📐 |
| Accounts | Several identities on one device, each with its own keys, database and files; switch, add (with a way back), erase. | ✅ |
| App lock | PIN stored as salted PBKDF2 (old PINs upgraded on unlock), backoff that survives restarts, biometric errors shown. | ✅ |

## 4. Big features that need a decision first

### Voice and video calls 📐
- Signalling over the existing direct channel (`call` control messages: offer, accept, decline, end, mute state).
- Media over a dedicated `mentos-call/0` ALPN: unreliable QUIC datagrams for frames, a stream for control. iroh already gives encryption and NAT traversal; a relay path works but adds latency.
- Audio: Opus 48 kHz mono, 20 ms frames, through a small platform audio plugin.
- Video: the platform's hardware encoder (Android MediaCodec, H.264) to keep battery use sane.
- Group calls: full mesh up to about four people; above that the best-connected participant forwards (a peer-hosted SFU).
- Risk: needs two real phones to test; the audio plugin and codec are most of the work.

### Streaming 📐
A live stream is a channel whose posts are short media segments. The streamer announces each segment on the channel's gossip topic; viewers fetch it from the streamer or from other viewers, who re-serve recent segments. Shares the codec work with calls.

### Payments (a peer-maintained currency) 📐 — needs a decision
Without a server, a currency must stop double spending. Options:
1. **Mutual credit** (suggested first): balances are IOUs signed by both people. No global ledger, no double spending, works offline. Good for tips and paying friends.
2. **Account chains with a witness quorum** (Nano-style): each account signs its own chain; a payment is final when enough online witnesses co-sign. The hard part is choosing witnesses that cannot be faked by one person running many nodes.
3. **Use an existing network** (Lightning or a stablecoin) instead of a new currency.

Nothing that looks like money should ship before its threat model is written and reviewed.

## 5. Reliability work still open
From `review/PROJECT_REVIEW_2026-10-10.md`: group keys sent before an invite is accepted, no key rotation when someone leaves, key files stored in plain files, unbounded gossip queues. These should be fixed before a public release.

## 6. Building
See the README. The APK needs the Rust library built for Android first (`native/build-android.ps1`, or `cargo ndk -t arm64-v8a -P 26 -o android/app/src/main/jniLibs build --release` from `native/`).
