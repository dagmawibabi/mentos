# Mentos

Peer-to-peer social and messaging with no central server. Posts, stories, chats, groups, spaces, channels, files, calls, and the Mentos ledger live on the device that made them. They travel over [iroh](https://iroh.computer): QUIC, hole punching, and the public n0 relays when a direct path is impossible. Relays move ciphertext. They do not store accounts or content.

- Content is signed by its author (Ed25519). Recipients see it while a source is reachable.
- An author can consent to others keeping a copy (`kp`). Nothing is kept without that bit, and nothing is kept that this device did not accept.
- People can export everything on the phone, inspect the network, and choose how much of their IP to reveal: direct, relay only, or Tor.

There is no account server, no store-and-forward, and no global index. Two devices exchange data only while both are reachable at the same time, unless a third device has been allowed to keep a copy.

## Stack

| Layer | What |
|---|---|
| App | Flutter, Dart 3.13 (`sdk: ^3.13.0`). Riverpod, go_router. Fonts: Geist, Geist Mono |
| Protocol | Dart `Engine` in `lib/net/`. Signed envelopes, authorization, sync, delivery queue |
| Store | SQLite3 Multiple Ciphers (`hooks.user_defines.sqlite3.source: sqlite3mc`), keyed per device. Media files beside it |
| Identity | Ed25519 seed. 24-word BIP39 phrase restores the same key. Public key hex **is** the user id and the iroh `EndpointId` |
| Network | Rust crate `mentos_net` (`native/`). iroh 1.3 (`unstable-net-report`) + iroh-gossip 0.101. C ABI, no codegen. Library name: `libmentos_net` |
| Toolchain | Rust 1.99 (`native/rust-toolchain.toml`). Android NDK `28.2.13676358`, API 26, [`cargo-ndk`](https://github.com/bbqsrc/cargo-ndk) |

Supported native build today: **Android arm64**. iOS, macOS, Linux, and Windows shells exist; without `libmentos_net` the app opens `OfflineTransport` and stays local. Web is not a target.

## Architecture

```
features/  widgets/     Flutter UI. Reads Engine through Riverpod providers.
     │
state/                 session, settings, accounts, notifications
     │
lib/net/Engine         protocol. Only this layer decides what is stored or shown.
     │  Transport      the only network interface the engine knows
     │
native/  iroh Endpoint presets::N0
         four ALPNs on one endpoint
```

One identity, one endpoint. `Endpoint::builder(presets::N0)` dials the public [n0](https://iroh.computer) relays. Direct UDP is tried first; the relay is the fallback. A ticket is `endpointId` or `endpointId|relayUrl`.

| ALPN | Use | Limit |
|---|---|---|
| `mentos/0` | Authenticated direct messages (control, DMs, receipts, payments) | 2 MiB |
| `mentos-blob/0` | Custom content-addressed blob fetch. SHA-256 of the bytes, checked before rename | 512 MiB |
| iroh-gossip | Topic broadcast. Topic id is SHA-256 of a label (`mentos-feed:<author>`, `mentos-space:<id>`, `mentos-gdm:<id>`, `mentos-coin-v2`) | broadcast payload ≤ 63 KiB |
| `mentos-call/0` | One QUIC connection per call peer. Media is unreliable datagrams. Inbound accepted only for a call id and peer the app registered | — |

Privacy is chosen **before bind** (`mentos_set_options`, `native/src/diag.rs`):

| Mode | Behavior |
|---|---|
| `standard` | Direct UDP plus relays |
| `relay` | `clear_ip_transports`. Peers see the relay address, never this device's IP |
| `tor` | Relay only, plus an `http://` CONNECT proxy (Orbot: `http://127.0.0.1:8118`) for relay and DNS |

Changing privacy rebinds the endpoint. Two endpoints with the same key must not be registered with the relay at once; a new bind waits for the previous shutdown.

Dart polls native events (`mentos_poll_event`). Every `extern "C"` entry is panic-guarded. Strings returned across FFI are freed with `mentos_free`. The Tokio runtime is one process-wide multi-thread runtime named `mentos-net` (8 MiB stacks; the default overflows inside the QUIC handshake on Android).

### What an item is

Everything a person creates is one signed `Envelope` (`lib/data/models.dart`).

- `payload` is the exact JSON the signature covers. Relay it verbatim. Never re-encode it.
- Wire form is `{p, s}`. Fields inside the payload: `v` (1), `id`, `k` (kind), `a` (author), `s` (scope), `t` (ms), `b` (body), `kp` (keep consent).
- `Envelope.sane` and `allowedHere` reject kinds in the wrong scope. A profile in a chat used to pass a participant check and wipe history.
- Ingest verifies the signature, checks authorization (`Engine._authorized`), then either stores it or holds it in memory.

Storage tiers (`Engine`):

| Tier | Meaning |
|---|---|
| owned | Created here. Encrypted DB. Served to peers |
| kept | Someone else's item, `kp` set, this device accepted. Stored and served for them |
| live | Everything else. Memory only, dropped when no source is reachable |

Chat messages use a durable per-recipient queue (`lib/data/delivery.dart`). A gossip broadcast is not delivery. Direct `ack` / `seen` name the message id. See `docs/MESSAGE_DELIVERY.md`.

### Coins

One shared ledger, not a chain and not Byzantine consensus. Treasury is SHA-256 of `mentos:network-treasury:v1`, created holding the whole supply. New identities draw 5.00 once, signed by their own key. Later payments chain to the sender's previous hash and are gossiped on `mentos-coin-v2`. Conflicting spends: lower hash wins. Application tag is `coin-v2`. Details and the fee rules: `docs/MARKETPLACE.md`, code in `lib/net/pay/coin.dart`.

## Where to change what

| Path | Touch it for |
|---|---|
| `lib/features/` | Screens. Do not put protocol decisions here |
| `lib/widgets/` | Shared UI |
| `lib/core/router.dart` | Routes. Shell has five branches |
| `lib/state/providers.dart` | Riverpod. Widgets watch `Engine.changes` keys in `Ch` (`lib/net/engine.dart`) |
| `lib/net/engine.dart` | Protocol: publish, ingest, sync, groups, spaces. Large. Read the method you are changing, do not restyle the file |
| `lib/net/market.dart` | `part` of the engine. Listings and tasks |
| `lib/net/engine_net.dart`, `engine_data.dart` | Diagnostics and export. Public `Engine` surface only, so they can move later |
| `lib/net/transport.dart` | `Transport` interface. Production is `iroh_transport.dart`; tests use `test/support/fake_net.dart` |
| `lib/net/iroh_native.dart` | C ABI lookups. Optional symbols stay optional so an older `.so` still loads |
| `lib/data/models.dart` | `K`, `Scope`, `Envelope`. New kinds need `known`, `allowedHere`, and `sane` |
| `lib/data/db.dart` | Schema. Bump `user_version` and migrate. Do not rewrite old rows in a way that breaks signatures |
| `lib/data/keys.dart` | `identity.json` and `db.key`. Writes are temp-file then rename. A bad identity file must refuse to start, not mint a new key over the old one |
| `lib/core/crypto/crypto.dart` | Ed25519, XChaCha20-Poly1305 (space/group seals), AES-GCM |
| `native/src/lib.rs` | Endpoint, direct, gossip, blobs, FFI |
| `native/src/call.rs` | `mentos-call/0` |
| `native/src/diag.rs` | Net report and privacy modes |
| `native/src/android.rs` | JNI `Context` for iroh DNS. Installed before any socket |
| `docs/` | `ROADMAP.md` (status), `MESSAGE_DELIVERY.md`, `PAYMENTS.md` (old bilateral credit, not the live ledger), `MARKETPLACE.md` |

UI state comes from the engine. If a screen and a test disagree, the engine and `test/` win.

## Rules

These are the ones that get broken by a drive-by change:

1. No server, no hidden relay storage, no new account system. Availability is "a source is online" or "someone consented to keep a copy."
2. Do not re-serialize a signed payload. Compare and store the original string.
3. Do not treat a gossip send as delivered. Chat delivery is the direct queue plus an authenticated ack from that peer.
4. Group keys go to an invitee only after they accept. Rotate the key when someone leaves.
5. Call media is accepted only for peers the app invited on that call id.
6. Coin rules are protocol, not settings. Do not mint outside the treasury. Do not mix `coin-v2` with older ledger messages on the same identity.
7. Secrets (PIN hash, space/group/file keys) stay out of exports unless the caller passed `secrets: true`.
8. FFI: catch panics, free returned strings, do not `block_on` the iroh runtime from inside it. Dart calls `wait()`, which parks the OS thread on a channel.
9. New protocol behavior needs a test on the real `Engine` and encrypted SQLite against `TestTransport`. Widget tests do not replace that.
10. `lib/net` and `lib/data` should not gain Flutter imports. The roadmap splits them into a core package; `engine_net.dart` and `engine_data.dart` already stay on the public surface.

## Build

```sh
# Android arm64. From native/
cargo ndk -t arm64-v8a -P 26 -o ../android/app/src/main/jniLibs build --release

# or, on Windows, native/build-android.ps1
# (sets ANDROID_NDK_HOME if unset, drops every .so except libmentos_net.so)

cd ..
flutter pub get
flutter build apk --release
```

Release builds sign with `android/key.properties` when that file exists. Without it the APK is unsigned. Without the native library the app still runs, fully offline.

`native/` release profile is `lto = "thin"` and `codegen-units = 8`. Fat LTO OOMs a 16 GB link.

## Test

```sh
flutter analyze lib test
flutter test
cd native && cargo test
```

`test/support/fake_net.dart` is an in-process authenticated transport. It runs the real engine and the real encrypted database. No sockets, no accounts, no user data. Feature tests live next to it (`delivery_test.dart`, `coin_test.dart`, `group_keys_test.dart`, `market_workflows_test.dart`, …).

Narrow runs that matter when you touch money or markets:

```sh
flutter test test/market_workflows_test.dart test/market_ui_test.dart test/coin_test.dart test/channels_test.dart
```

`MENTOS_CAPTURE_UI=1` writes phone-size light/dark previews under `build/market-previews`.

Live smoke against the public n0 relays, from `native/`:

| Example | What it checks |
|---|---|
| `cargo run --example diag_smoke` | Net report |
| `cargo run --example ping_smoke` | Two nodes, round trip |
| `cargo run --example call_smoke` | `mentos-call/0` datagrams |

## Docs

| File | Read it when |
|---|---|
| `docs/ROADMAP.md` | What is built, designed, or later, and which layer owns it |
| `docs/MESSAGE_DELIVERY.md` | Queue states, backoff, ack shape |
| `docs/MARKETPLACE.md` | Tasks, plugins, treasury, `coin-v2` |
| `docs/PAYMENTS.md` | Threat model of the removed bilateral credit lines. The live wallet is the shared ledger |

## Contributing

Work from this tree. Match the surrounding file: short comments that state an invariant, not a narration of the next line.

- Protocol change: engine (or a `part` / extension on the public surface) plus a `test/` that fails before the fix. Name the peer, the message, and the restart case.
- UI change: a provider and a screen. If the data is wrong, fix the engine, not the widget.
- Native change: keep the C ABI stable or make the new symbol optional in `iroh_native.dart`. Add a `cargo test` or an example if it only shows up on a real endpoint.
- Schema change: a new `user_version` step in `lib/data/db.dart`. Old signed payloads stay byte-identical.
- Do not commit `android/key.properties`, identity files, `db.key`, or anything under a device data dir.

Open questions and unfinished work are tracked as status rows in `docs/ROADMAP.md`, not as a second list here.
