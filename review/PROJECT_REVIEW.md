# Mentos project review — 8 October 2026

Mentos has a substantial feature set: identity recovery, direct and group chats, spaces, forums, feeds, stories, polls, encrypted attachments, custody controls, and file transfers. The Flutter interface and Rust transport are separated reasonably well, and signatures, authenticated encryption, SQL parameters, and downloaded-blob hash verification are useful foundations.

**Assessment: prototype / private testing stage. I would not release it as a secure messenger yet.** The most important defects concern authorization, network delivery, UI blocking, and data lifecycle. A successful signature proves who authored a message; it does not establish that its body is valid or that its author may perform its action.

This review changed no application implementation. It added this report and a small local reproduction script.

## Evidence and limits

- Read the Flutter engine, models, storage, crypto, transport bindings, Rust network implementation, settings, and representative user flows and platform configuration.
- `flutter analyze --no-pub`: completed with **four informational lints**, no reported analyzer errors or warnings. Exit code 1 due to the lints. Three concern null-aware syntax; one concerns BuildContext use after an await in [lib/widgets/media.dart:571](D:/Projects/VibeCoded/mentos/mentos/lib/widgets/media.dart:571).
- `cargo check --locked --offline`: **passed**.
- `flutter test --no-pub`: did not produce test results during the review and was stopped after remaining stalled. Other Flutter build processes were already running on this machine; I did not stop those. The precise reason for the stalled test run was not established. **The existing four-test suite is not counted as passed.**
- `dart --packages=.dart_tool/package_config.json review/probe.dart`: completed. Synthetic local probes reproduced member-to-owner metadata changes, unauthorized poll closure, malformed signed message rendering casts, and leftover plaintext after failed decryption.
- The probes exercise model/crypto behavior and the same membership predicate used by ingestion; they are **not** a two-device exploit demonstration.
- No live account data was read. No hostile traffic was sent. No real-device UI, background lifecycle, multi-peer, or release-package test was performed.
- Dependency advisory/CVE auditing was not performed. These are findings in this project's own implementation, not a claim that its dependencies have no vulnerabilities.

**Priorities:** P1 = resolve before public release; P2 = correctness, resilience, or experience gap that should follow promptly.

## Findings

### 1. P1 — Any group member can take over group ownership

**Evidence:** [lib/net/engine.dart:739](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:739), [lib/net/engine.dart:865](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:865), [lib/data/models.dart:591](D:/Projects/VibeCoded/mentos/mentos/lib/data/models.dart:591).

For both group messages and metadata, authorization only checks `g.has(e.author)`. A signed `K.group` update from an ordinary member is then passed to `withMeta`, which accepts the supplied owner, member list, and roles. A member can become owner, remove other members, or assign privileges.

**Reproduce:** sign a group metadata envelope as an existing non-owner member, set `owner` to that member, and ingest it with a current timestamp. The local probe confirms the signature, membership gate, and ownership mutation.

**Fix:** define action-specific permissions in the engine, require the current owner's authorization for ownership and membership changes, and model ownership transfer separately. UI-only role checks do not protect the protocol.

### 2. P1 — An outsider can establish space membership by sending their own signed content

**Evidence:** [lib/net/engine.dart:734](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:734), [lib/net/engine.dart:549](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:549), [lib/net/engine.dart:482](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:482).

Space authorization rejects banned identities but otherwise accepts unknown authors. Unknown identities default to `Role.member`. A peer that learns a space ID can send a direct signed `K.member` item into its metadata scope without knowing the space key. That item is retained, `_knownMembers` then includes its author, and subsequent direct history queries pass `_isMember`.

**Impact:** injection into private spaces and potentially disclosure of retained space history to someone who never held an invite. Knowing the space ID is a prerequisite; randomly guessing the generated ID is not the proposed attack.

**Fix:** require verifiable admission by the owner or an authorized inviter, maintain explicit membership state, and enforce it consistently on direct ingest, gossip ingest, and history serving.

### 3. P1 — Removing a member does not revoke access to encrypted group/space traffic

**Evidence:** [lib/net/engine.dart:563](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:563), [lib/net/engine.dart:590](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:590), [lib/net/engine.dart:626](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:626), [lib/net/engine.dart:1982](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:1982), [lib/data/models.dart:539](D:/Projects/VibeCoded/mentos/mentos/lib/data/models.dart:539).

Membership changes retain the same group/space key. A removed member can keep decrypting future topic messages if they continue receiving the topic. Gossip history queries also trust the encrypted request's claimed `a` and do not check current membership before sending retained content directly to it.

**Fix:** rotate keys at membership changes, distribute the new key only to authorized members, version key epochs, authenticate the requester, and apply current membership checks to every history route. A modified client will not voluntarily forget an old key.

### 4. P1 — Downloading an attachment blocks the Flutter UI thread

**Evidence:** [lib/net/iroh_transport.dart:154](D:/Projects/VibeCoded/mentos/mentos/lib/net/iroh_transport.dart:154), [lib/net/iroh_native.dart:195](D:/Projects/VibeCoded/mentos/mentos/lib/net/iroh_native.dart:195), [native/src/lib.rs:55](D:/Projects/VibeCoded/mentos/mentos/native/src/lib.rs:55), [native/src/lib.rs:747](D:/Projects/VibeCoded/mentos/mentos/native/src/lib.rs:747).

The asynchronous Dart wrapper calls synchronous FFI directly. Rust then parks the caller in `rx.recv()` until a network fetch finishes. There is no application-level overall deadline around that fetch.

**Impact:** a slow or stalled attachment can freeze rendering, timers, progress updates, and cancellation. Native import also synchronously hashes and copies files on the caller thread.

**Fix:** use a long-lived worker isolate or a completion/event-based native API, with bounded work, explicit deadlines, and cancellation. Merely declaring the Dart wrapper `async` does not move the work off the UI isolate.

### 5. P1 — Outgoing direct connections have no receive loop

**Evidence:** [native/src/lib.rs:188](D:/Projects/VibeCoded/mentos/mentos/native/src/lib.rs:188), [native/src/lib.rs:237](D:/Projects/VibeCoded/mentos/mentos/native/src/lib.rs:237), [native/src/lib.rs:549](D:/Projects/VibeCoded/mentos/mentos/native/src/lib.rs:549).

Incoming connections enter `DirectProto.accept`, which reads incoming unidirectional streams. `get_direct` creates an outgoing connection and caches it without starting the corresponding reader. The other endpoint reuses its cached connection to reply, but the originating endpoint has no code reading those reply streams.

**Impact:** a single initiated connection can carry messages in one direction while hello responses, history results, or acknowledgements in the reverse direction go unread. Simultaneous connections can obscure this during casual testing.

**Fix:** install one receive task per connection regardless of which endpoint initiated it. Verify with a two-node test in which only A initiates and B replies on that connection.

**Validation:** source-traced; not reproduced with two live nodes.

### 6. P1 — Startup can lose topic subscriptions and still report “online”

**Evidence:** [native/src/lib.rs:502](D:/Projects/VibeCoded/mentos/mentos/native/src/lib.rs:502), [lib/net/iroh_transport.dart:28](D:/Projects/VibeCoded/mentos/mentos/lib/net/iroh_transport.dart:28), [lib/net/iroh_transport.dart:122](D:/Projects/VibeCoded/mentos/mentos/lib/net/iroh_transport.dart:122), [lib/net/engine.dart:106](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:106), [lib/net/engine.dart:324](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:324).

Native start returns before `NODE` is ready. The engine immediately joins its topics; native calls made before readiness fail, while the transport swallows these errors. Topic maps are populated before successful subscription. The later status event only emits a UI update and does not retry the joins. OfflineTransport also lets engine startup label itself online.

**Fix:** await an explicit native-ready signal, propagate startup/join failures, retry failed subscriptions, and derive connection state from confirmed transport state.

### 7. P1 — Signed malformed content can poison chat/feed rendering

**Evidence:** [lib/data/models.dart:131](D:/Projects/VibeCoded/mentos/mentos/lib/data/models.dart:131), [lib/net/engine.dart:659](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:659), [lib/net/engine.dart:1755](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:1755), [lib/widgets/media.dart:51](D:/Projects/VibeCoded/mentos/mentos/lib/widgets/media.dart:51).

Envelope parsing checks only a few top-level strings. It does not validate body schemas for each kind. A correctly signed DM with `text: 42` can be ingested, but the message view later casts text to String and throws. If retained under an active sync grant, the bad item can survive restart. Invalid media hashes also reach `cached()`, which throws before the guarded fetch path.

**Fix:** validate protocol version, allowed kind/scope combinations, timestamps, body field types, collection sizes, media hashes and keys, and numeric bounds before retention or side effects. Quarantine malformed persisted records instead of repeatedly crashing a view.

**Validation:** the local probe confirms the malformed text passes parsing/signature verification and throws at the rendering cast. It does not demonstrate a whole-process crash.

### 8. P1 — Secret storage is plaintext, non-atomic, and uses a shared Windows directory

**Evidence:** [lib/data/keys.dart:7](D:/Projects/VibeCoded/mentos/mentos/lib/data/keys.dart:7), [lib/data/keys.dart:50](D:/Projects/VibeCoded/mentos/mentos/lib/data/keys.dart:50), [lib/state/session.dart:78](D:/Projects/VibeCoded/mentos/mentos/lib/state/session.dart:78).

The identity seed and database key live together in plaintext `keys.json`. The file is overwritten directly, so interruption can corrupt the only local key copy. Permission-setting failures and exit codes are ignored. On Windows, any machine with D: defaults to `D:\\mentos`, rather than a per-user application directory; viewed plaintext media has no corresponding explicit access restriction.

**Impact:** filesystem/backup exposure can reveal both identity and encrypted-database access. Multiple users or instances can collide on the same storage. ACL exposure depends on the actual filesystem permissions; those were not inspected.

**Fix:** protect key material with platform-backed secret storage, use per-user roots, verify restrictive permissions, and save secrets atomically with recovery handling.

### 9. P1 — “Erase identity” can recursively delete an arbitrary configured directory

**Evidence:** [lib/state/session.dart:78](D:/Projects/VibeCoded/mentos/mentos/lib/state/session.dart:78), [lib/state/session.dart:167](D:/Projects/VibeCoded/mentos/mentos/lib/state/session.dart:167).

`MENTOS_HOME` is accepted as the complete data directory. Wipe recursively deletes that root with no ownership marker or boundary check. If someone configures an existing Documents/project directory as the home, wiping Mentos deletes unrelated contents too.

**Fix:** create an app-owned child directory, maintain a storage ownership marker, reject unsafe roots, and delete only known app-owned paths. Test with a temporary parent directory containing an unrelated sentinel file.

### 10. P1 — The default disappearing timer does not affect new messages

**Evidence:** [lib/features/settings/settings_screen.dart:93](D:/Projects/VibeCoded/mentos/mentos/lib/features/settings/settings_screen.dart:93), [lib/net/engine.dart:1211](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:1211), [lib/data/db.dart:419](D:/Projects/VibeCoded/mentos/mentos/lib/data/db.dart:419).

The setting is saved but not read when creating chats or sending messages. Chats default to TTL 0, and `sendMessage` reads only the chat-specific value.

**Impact:** a user selects disappearing messages globally, yet new conversations continue storing messages without expiry.

**Fix:** apply the configured default when a chat is created, clearly separate inherited and overridden timers, and test both sender and recipient expiry.

### 11. P1 — Inbound event queues permit unbounded memory growth

**Evidence:** [native/src/lib.rs:149](D:/Projects/VibeCoded/mentos/mentos/native/src/lib.rs:149), [native/src/lib.rs:254](D:/Projects/VibeCoded/mentos/mentos/native/src/lib.rs:254), [native/src/lib.rs:460](D:/Projects/VibeCoded/mentos/mentos/native/src/lib.rs:460), [lib/net/iroh_transport.dart:41](D:/Projects/VibeCoded/mentos/mentos/lib/net/iroh_transport.dart:41).

The 4,000-event cap in `Node.emit` is bypassed by direct and gossip handlers, which push straight into the shared queue. Dart drains only 32 events per 50 ms. Direct frames may be up to 2 MiB, and application item/invite/transfer maps also lack practical per-peer budgets.

**Impact:** a peer can outpace consumption and drive memory growth or application termination. The queue can grow especially badly while a synchronous file download stalls Dart.

**Fix:** bound queued bytes as well as event counts, limit peers/concurrency/rates, introduce backpressure, and reject excessive payloads before expensive parsing or cryptography.

### 12. P2 — Failed decryption leaves a file that is later treated as a valid cache hit

**Evidence:** [lib/core/crypto/crypto.dart:124](D:/Projects/VibeCoded/mentos/mentos/lib/core/crypto/crypto.dart:124), [lib/data/media_store.dart:139](D:/Projects/VibeCoded/mentos/mentos/lib/data/media_store.dart:139), [lib/data/media_store.dart:184](D:/Projects/VibeCoded/mentos/mentos/lib/data/media_store.dart:184).

Decryption writes directly into the final view path. On authentication failure it closes the output without deleting it; `cached()` later treats existence alone as success. Wrong keys can leave empty files; a later-chunk failure can leave a valid plaintext prefix.

**Validation:** corrupting the final authentication tag left a **262,144-byte plaintext file** in the local probe.

**Fix:** decrypt into a temporary path, remove it on any error, validate the expected length, and rename into the cache only after full success.

### 13. P2 — Chats and history queries stop at the oldest 2,000 items

**Evidence:** [lib/data/db.dart:105](D:/Projects/VibeCoded/mentos/mentos/lib/data/db.dart:105), [lib/net/engine.dart:457](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:457), [lib/net/engine.dart:1595](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:1595).

The query sorts ascending and takes the first 2,000 items. Display and direct history serving use that bounded result without a continuation cursor. Once a chat grows past the limit, newer persisted messages disappear from the loaded conversation and subsequent history responses.

**Fix:** load the newest page for display, paginate older items with stable timestamp/ID cursors, and support complete resumable history synchronization.

### 14. P2 — Sending and cancelling have misleading completion semantics

**Evidence:** [native/src/lib.rs:549](D:/Projects/VibeCoded/mentos/mentos/native/src/lib.rs:549), [lib/net/engine.dart:1046](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:1046), [lib/net/engine.dart:1730](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:1730), [lib/net/engine.dart:2035](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:2035), [lib/net/engine.dart:2097](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:2097).

Native send returns success when the task is scheduled and discards actual network failures. Publishing persists a message and ignores distribution results; the view defaults it to “sent.” There is no durable pending/failed/retry state. Reconnection history pulls may recover some messages, but they do not provide an explicit delivery contract.

Cancel changes transfer state and sends a control message but does not cancel the fetch. The completion path can subsequently overwrite “cancelled” with “done.”

**Fix:** durable outgoing jobs, native completion events, per-message delivery acknowledgements, honest pending/failed states, retry/backoff, and cancellation propagated to the actual I/O task.

### 15. P2 — Any participant can close someone else's poll

**Evidence:** [lib/net/views.dart:25](D:/Projects/VibeCoded/mentos/mentos/lib/net/views.dart:25), [lib/net/views.dart:48](D:/Projects/VibeCoded/mentos/mentos/lib/net/views.dart:48).

Poll closure is applied from a vote's `close` flag or an edit's `closePoll` flag without checking the poll owner's identity. The edit text has an author check, but poll closure is outside it.

**Validation:** reproduced with a non-owner signed vote.

**Fix:** only the poll owner or an explicitly authorized moderator may close it; also validate option indices and define how late votes are handled.

### 16. P2 — Privacy/discovery controls are bypassable as access controls

**Evidence:** [lib/net/engine.dart:396](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:396), [lib/net/engine.dart:466](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:466), [lib/net/engine.dart:569](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:569), [lib/net/engine.dart:1055](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:1055).

When discovery is disabled, direct feed access is allowed if the requesting peer “follows me.” A peer can set that flag itself by sending a follow message. Feed gossip is also unsealed and published without consulting the discovery flag. Profile/story/files queries do not use the same discovery gate.

**Impact:** “discovery off” must not be presented or relied on as a private audience boundary.

**Fix:** distinguish recommendation/discovery preferences from approved audience access. If private feeds are intended, require explicit approval and audience encryption across both direct and gossip paths.

### 17. P2 — Several visible settings and group-admin actions are ineffective

**Evidence:** [lib/state/settings.dart:14](D:/Projects/VibeCoded/mentos/mentos/lib/state/settings.dart:14), [lib/features/settings/settings_screen.dart:113](D:/Projects/VibeCoded/mentos/mentos/lib/features/settings/settings_screen.dart:113), [lib/net/engine.dart:1982](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:1982), [lib/features/chats/group_info_screen.dart:71](D:/Projects/VibeCoded/mentos/mentos/lib/features/chats/group_info_screen.dart:71).

`autoDownload`, `systemNotify`, and `reduceMotion` are stored and displayed but have no behavior consumers elsewhere in the reviewed application. Media still loads automatically; alerts are still pushed without consulting the banner preference.

Role-only group updates are saved locally but not published, because `updateGroup` only compares name and members. The UI lets moderators invite people, but `inviteToGroup` returns unless the caller is the owner.

**Fix:** implement and test every exposed control end to end; compare the full shared metadata when publishing and align UI permissions with engine permissions.

### 18. P2 — Platform and release support is incomplete

**Evidence:** [lib/net/iroh_native.dart:84](D:/Projects/VibeCoded/mentos/mentos/lib/net/iroh_native.dart:84), [android/app/build.gradle.kts:19](D:/Projects/VibeCoded/mentos/mentos/android/app/build.gradle.kts:19), [android/app/build.gradle.kts:36](D:/Projects/VibeCoded/mentos/mentos/android/app/build.gradle.kts:36), [windows/CMakeLists.txt:93](D:/Projects/VibeCoded/mentos/mentos/windows/CMakeLists.txt:93), [ios/Runner/Info.plist:1](D:/Projects/VibeCoded/mentos/mentos/ios/Runner/Info.plist:1).

Native-library loading is implemented only for Android and Windows. Other desktop/mobile targets silently fall back to OfflineTransport. The project also imports dart:io/FFI directly, so the presence of a web scaffold does not establish web support. iOS privacy usage descriptions for camera/microphone are absent from the checked-in plist and require platform validation before those flows can be supported.

Android release uses debug signing and the example application ID. Windows bundling opportunistically copies an existing DLL instead of ensuring that the matching native source was built; a missing DLL silently disables networking.

**Fix:** explicitly declare supported targets, make required native artifacts part of reproducible builds, fail loudly when missing, and configure release identity/signing and platform permissions.

### 19. P1 — Reboot trusts retained delete requests that were never authorized to delete their targets

**Evidence:** [lib/net/engine.dart:106](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:106), [lib/net/engine.dart:685](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:685), [lib/net/engine.dart:836](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:836).

Ingestion retains mutation envelopes before checking whether their authors may delete the referenced target. A peer can submit a signed delete into a post-reply scope belonging to this device, set keep=true, and target a known item ID. The immediate delete side effect correctly declines to delete an owned item, but leaves the delete envelope stored. On restart, every stored delete target is added to the global tombstone set without rechecking target ownership or moderation authority. The targeted content is then hidden and rejected if fetched again.

**Fix:** authorize mutations against their target before retaining them as effective operations, and rebuild tombstones only from validated deletes with correct scope binding. Add a regression test covering unauthorized delete ingestion, restart, and visibility of the original item.

**Validation:** source-traced; restart behavior was not executed against a live database.

## Additional correctness and product gaps

- **Attachment limits:** import accepts arbitrarily large files, while the Rust protocol refuses ciphertext above 80 MiB. Encryption overhead counts toward that limit. Empty encrypted files are represented by zero bytes, which the fetch protocol also treats as “missing.” Add consistent preflight limits and an unambiguous empty-file representation. See [native/src/lib.rs:40](D:/Projects/VibeCoded/mentos/mentos/native/src/lib.rs:40), [native/src/lib.rs:354](D:/Projects/VibeCoded/mentos/mentos/native/src/lib.rs:354), [lib/data/media_store.dart:60](D:/Projects/VibeCoded/mentos/mentos/lib/data/media_store.dart:60).
- **Attachment lifetime/reference counting:** expiry can delete a blob for an owned message even if another forwarded message references it. Conversely, retained expired content checks references before deleting the expiring item, so its own reference can prevent cleanup. See [lib/net/engine.dart:236](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:236).
- **Recovery is incomplete:** the phrase restores the identity key, but does not encode contacts, group/space membership, shared keys, local history, or settings. A fresh database has no contact graph to start fetching from automatically. The onboarding recovery wording should explain prerequisites and limits. See [lib/features/onboarding/onboarding_screen.dart:307](D:/Projects/VibeCoded/mentos/mentos/lib/features/onboarding/onboarding_screen.dart:307), [lib/state/session.dart:145](D:/Projects/VibeCoded/mentos/mentos/lib/state/session.dart:145), [lib/net/engine.dart:265](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:265).
- **Group invites disappear on restart:** pending incoming/outgoing invites live in memory while invite activity is stored, leaving potentially stale activity with no actionable invite. See [lib/net/engine.dart:79](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:79), [lib/net/engine.dart:2186](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:2186).
- **Analytics are misleading:** unique viewers are calculated from the authors of your own posts, producing effectively zero or one rather than unique viewing identities. See [lib/net/engine.dart:2244](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:2244).
- **Migration is not transactional:** copying keys before the rest of the data can leave a partial destination that future launches treat as migrated. Use staging, verification, and a completion marker before removing the old directory. See [lib/state/session.dart:92](D:/Projects/VibeCoded/mentos/mentos/lib/state/session.dart:92).
- **Documentation/testing:** README remains the Flutter starter text; the supplied tests cover four crypto happy-path/tamper scenarios. No checked-in engine authorization, storage migration, multi-peer integration, or widget suites were found.
- **Privacy wording:** “no servers” is misleading while the native transport uses relays; a stable public-key identity is pseudonymous. Consent and revocation govern cooperating clients and cannot force recipients to erase independently copied content. State those boundaries accurately.

## Features needed to complete the experience

| Priority | Addition or completion | Definition of done |
|---|---|---|
| First | Reliable outgoing queue and sync status | Pending/sent/delivered/read/failed are truthful; restart-safe retries; clear offline expectations; paginated synchronization. |
| First | Complete encrypted backup and device migration | Export/import history, contacts, memberships, shared keys and preferences; verified restore; separate identity recovery from data recovery. |
| First | Trust and membership management | Contact fingerprint verification, message requests, owner-authorized invites, expiring/revocable invites, key rotation, ownership transfer, and moderation audit history. |
| First | App lock and secret protection | OS-backed keys, optional biometric/PIN unlock, protected recovery display, automatic relock, and deliberate clipboard handling. |
| First | Background delivery and notifications | Supported mobile lifecycle behavior, reconnect on resume, real notifications and badge counts, and quiet/mute preferences that work. Explain any limits imposed by peer availability. |
| Next | Search and navigation | Search messages/posts/files/people; filters by chat/author/date/type; jump to result; shared-media browser; older-history pagination. File-name search already exists and should be extended. |
| Next | Resilient transfer manager | Real cancel/pause/resume, transfer persistence, per-file limits, low-storage checks, accurate progress, retry controls, and bandwidth/download preferences. |
| Next | Storage and retention dashboard | Breakdown by conversation/space, quota controls, safe cleanup, reference-aware deletion, and clear explanation of which peers keep copies. Existing custody information provides a starting point. |
| Next | Drafts and composition recovery | Persist drafts per conversation, recover unsent attachments, handle upload failures without losing text, and confirm destructive navigation. |
| Next | Accessibility and language support | Large-text layouts, keyboard/focus navigation, screen-reader labels, reduced motion, localization and tested RTL layouts. |
| Next | Diagnostics and trustworthy onboarding | Explain online-only versus retained content, provide native startup/reconnection diagnostics, export redacted logs, and make troubleshooting actionable. |
| Later | Explicit multi-device support | Device enrollment, separate revocable device keys, synchronization, and a clear policy for simultaneous use; avoid treating copying the same seed as a complete device model. |

Calls, bots, and richer discovery could follow, but expanding surface area before authorization and delivery are reliable would make the project harder to secure.

## Suggested implementation sequence

1. Close authorization and malformed-payload gaps; add adversarial tests before changing the protocol.
2. Fix connection readers, startup readiness, asynchronous file I/O, send completion, and cancellation; verify two nodes with only one side initiating.
3. Protect keys and storage roots; make migration, backup, expiry, and cleanup crash-safe.
4. Complete settings, pagination, and user-visible delivery states.
5. Establish release builds and integration coverage, then add the next-priority experience features.

For release verification, exercise offline recipients, reconnects, two simultaneous connections, removed members retaining old keys, malformed signed input, chats over 2,000 items, wrong-key attachments, expired forwarded media, low disk space, interrupted key writes, and clean-device restore.
