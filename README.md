# Mentos

Peer-to-peer social and messaging with no central server. Posts, stories, chats, groups, spaces, channels and hosted files live on the device that made them and travel directly between phones over [iroh](https://iroh.computer): QUIC with hole punching, and encrypted relays when a direct path is impossible.

- Content is signed by its author and stays on their device. Others see it while the author is reachable.
- Anyone can let others keep a copy, so their content stays available while they are offline. Nothing is kept without consent.
- People can see and export everything stored on their phone, inspect the network, and choose how much of their IP address to reveal (direct, relay only, or Tor).

## Layout

| Path | What it is |
|---|---|
| `native/` | Rust iroh node behind a small C ABI: direct messages, gossip topics, content-addressed blobs, diagnostics, privacy transports |
| `lib/net/` | Protocol engine: signed envelopes, authorization, sync, delivery queue, transfers |
| `lib/data/` | Encrypted SQLite store (SQLite3 Multiple Ciphers), media store, key vault |
| `lib/features/` | Flutter screens |
| `test/` | Engine and widget tests. They run the real engine and database against an in-process transport |
| `docs/` | `ROADMAP.md` (plan and status), `MESSAGE_DELIVERY.md` |

## Build

Requirements: Flutter 3.47 (Dart 3.13), Rust 1.99 (see `native/rust-toolchain.toml`), and for Android the NDK `28.2.13676358` and [`cargo-ndk`](https://github.com/bbqsrc/cargo-ndk).

```sh
# Native library for Android (arm64)
cd native
cargo ndk -t arm64-v8a -P 26 -o ../android/app/src/main/jniLibs build --release

# App
cd ..
flutter pub get
flutter build apk --release
```

Release builds are signed with `android/key.properties` when it exists. Without it the release APK is unsigned.

Without the native library the app still runs, fully offline.

## Test

```sh
flutter analyze lib test
flutter test
cd native && cargo test
```

`native/examples/` holds two live smoke tests against the public n0 relays: `diag_smoke` prints a diagnostics report, and `ping_smoke` connects two nodes and measures round trip.
