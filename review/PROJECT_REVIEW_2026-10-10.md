# Mentos review — 10 October 2026

**Assessment: substantial prototype; not ready to promise secure, reliable messaging to public users.** The main release blockers are protocol validation, data loss during backup, incomplete revocation, and incomplete deletion. Adding more social features should follow those fixes.

This is a fresh source review of the current Flutter/Dart application and Rust transport. The older October 8 report is not an accurate list of current defects. No application implementation was changed.

## Evidence and limits

- Inspected protocol ingestion, authorization, group/space membership, storage, keys, crypto, backups, transfers, settings, and representative UI/platform configuration.
- `cargo check --locked --offline`: passed.
- Synthetic Dart probes: passed execution; reproduced malformed-poll rendering failure, acceptance of a profile in a DM by the current shape/membership predicates, and unchanged group key after a member departure. Also confirmed the previous ownership-takeover example no longer changes the owner. Script: [probe_2026_10_10.dart](D:/Projects/VibeCoded/mentos/mentos/review/probe_2026_10_10.dart).
- These are model/predicate probes and source traces, not full two-device exploits or end-to-end tests.
- Direct `dart analyze lib test`: completed, exit 0, with four informational lints and no errors or warnings. Three concern null-aware syntax; one flags BuildContext use across an async gap in `lib/widgets/media.dart:593`. The initial Flutter analyzer wrapper stalled and was stopped before this direct attempt.
- Flutter tests did not complete during the review, including a retry with version checking disabled. The review-owned stalled process was stopped. No passing Flutter test result is claimed. The test attempt reached a sqlite3 native hook process; the reason for the delay was not established.
- No real account storage was inspected, hostile traffic sent, release package tested, dependency advisory audit performed, or mobile background behavior tested. The checkout has no Git metadata, so there is no commit identifier or tracked-file exposure assessment.

P1 means resolve before public release. P2 means significant correctness, resilience, or usability work.

## Release blockers

### 1. P1 — Wrong-kind signed messages can delete received chat history

The DM authorization branch checks scope participants but not the allowed item kind. `K.profile` is therefore permitted in a DM between the attacker and recipient. Its side effect loops over the entire supplied scope and deletes every other non-owned stored item, treating them as old profiles. In an existing group, a member can similarly submit a profile in the group chat scope and remove retained received messages there.

Evidence: [authorization](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:944), [profile cleanup](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:1018). The synthetic probe confirms the valid signature, `sane` result, and DM predicate. Deletion is source-traced, not exercised against a live database.

Fix: enforce an explicit kind/scope matrix before persistence or side effects; require profiles in `profile:<author>` and constrain cleanup to profile records. Test adversarial kinds in every scope.

### 2. P1 — Signed malformed nested content still breaks rendering

`Envelope.sane` checks a few top-level fields but not poll shapes, media hashes/keys, profile biography types, or many mutation fields. A signed message with `poll: {q: 'test', o: 42}` passes validation and throws `_TypeError` in `Poll.fromJson`. With chat retention enabled it can persist and repeatedly break conversation rendering. Invalid media hashes also reach `cached()` outside an error handler.

Evidence: [validation](D:/Projects/VibeCoded/mentos/mentos/lib/data/models.dart:158), [poll parsing](D:/Projects/VibeCoded/mentos/mentos/lib/net/views.dart:85), [media loading](D:/Projects/VibeCoded/mentos/mentos/lib/widgets/media.dart:52).

Fix: total, non-throwing schema validation for each kind, including scope structure, protocol version, nested types, lengths, numeric bounds, hashes and keys. Quarantine malformed stored records and render a recoverable placeholder. This is a confirmed rendering exception, not a demonstrated whole-process crash.

### 3. P1 — Backups can omit committed chats or produce inconsistent snapshots

The database uses WAL mode, but `exportVault` copies only the live `mentos.db` file without a backup transaction, checkpoint/close, or WAL snapshot. Recent committed writes can still be in `mentos.db-wal`. Import also copies directly into the destination before verifying the phrase/database and has no staged rollback.

Evidence: [WAL setup](D:/Projects/VibeCoded/mentos/mentos/lib/data/db.dart:21), [export/import](D:/Projects/VibeCoded/mentos/mentos/lib/state/session.dart:184). SQLite documents that WAL is part of persistent database state and must not be separated from a live database: [SQLite WAL documentation](https://www.sqlite.org/wal.html).

Fix: create a consistent encrypted snapshot using the database backup API or a properly coordinated closed-database copy; stage imports, verify decryption/integrity, then replace atomically. Test restore into a clean directory while recent writes remain uncheckpointed.

### 4. P1 — Invites disclose group keys before acceptance; departures do not rotate them

`inviteToGroup` sends the current group key and member list before the invite is accepted. A modified recipient can retain that key even after declining. Separately, `leaveGroup` publishes metadata; the receiver's `K.group` branch updates members but does not rotate the key. Rotation exists for owner-initiated removal in `updateGroup`, not for this departure path.

Evidence: [invite payload](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:2521), [leave](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:2252), [received metadata](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:1112). The departure probe confirms the member is removed while the key remains unchanged.

Impact: nonmembers retaining a key can decrypt future group traffic if they continue receiving the topic. This contradicts the invite UI's promise that nothing is shared before acceptance.

Fix: invite with metadata only; distribute keys after admission. Have the owner commit membership changes and rotate/version keys for every departure/removal. Define offline recovery and acknowledgment for key transitions.

### 5. P1 — Erasing an identity leaves plaintext temporary exports

`MediaStore.export` writes decrypted files into the app's `tmp/` directory. Wipe deletes `blobs`, `view`, and `node`, but omits `tmp`. Plaintext shared/opened attachments can survive an explicit identity erase until a later successful media initialization cleans them.

Evidence: [plaintext export](D:/Projects/VibeCoded/mentos/mentos/lib/data/media_store.dart:293), [wipe directory list](D:/Projects/VibeCoded/mentos/mentos/lib/state/session.dart:261).

Fix: delete all app-owned plaintext scratch files during wipe and define cleanup after sharing, locking, and expiry. Test using a synthetic exported file and verify it is gone immediately after wipe.

### 6. P1 — Deleted and expired messages remain in the durable outbox

Deletion/expiry removes items but does not remove their serialized payloads from `outbox`. The retry loop sends queued payloads without checking whether the original item is deleted or expired. Thus expired content remains stored and can be sent later; a compliant recipient may reject it, but a modified recipient still receives the content. Deleting an unsent message also does not cancel its original send job.

Evidence: [expiry](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:324), [deletion](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:1504), [retry loop](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:445).

Fix: cancel original send jobs transactionally with deletion, prune expired outbox entries, and recheck validity immediately before sending. Keep deletion-control messages separate from the original content job.

### 7. P1 — Gossip queues and automatic custody downloads lack resource bounds

Direct events now use a capped emitter, but gossip handlers still push directly into the shared queue with no cap. Even the direct cap counts events rather than bytes, allowing a very large memory footprint for multi-megabyte frames. Dart dispatches async event handlers without a concurrency budget. `MediaStore.keep` also downloads retained attachments without `_ensureRoom`, bypassing the configured storage quota; this route runs independently of the visible auto-load-media preference.

Evidence: [gossip queue](D:/Projects/VibeCoded/mentos/mentos/native/src/lib.rs:555), [direct emitter](D:/Projects/VibeCoded/mentos/mentos/native/src/lib.rs:175), [custody downloads](D:/Projects/VibeCoded/mentos/mentos/lib/data/media_store.dart:252), [trigger](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:1005).

Fix: bound queued bytes, processing concurrency and per-peer rates. Reserve disk capacity for every download path using validated actual sizes; expose a separate custody-download policy if it intentionally differs from preview auto-download. Risk is memory/disk exhaustion; no stress test was performed.

### 8. P1 — Filesystem access exposes identity and database keys

Identity and DB keys are now separate files, but both remain plaintext. The Windows default still uses shared `D:\mentos` when D: exists. ACL commands fail silently and exit codes are ignored. Database encryption therefore does not protect a copied vault directory containing its key material. Exact exposure to other OS users depends on actual directory ACLs, which were not inspected.

Evidence: [key storage](D:/Projects/VibeCoded/mentos/mentos/lib/data/keys.dart:9), [storage root](D:/Projects/VibeCoded/mentos/mentos/lib/state/session.dart:78).

Fix: use per-user application storage and platform-backed secret protection, verify permissions, and retain the explicit recovery-phrase export workflow.

## Other correctness and experience gaps

| Priority | Finding and effect | Evidence and corrective direction |
|---|---|---|
| P2 | Secret writes still have a crash window: `_atomic` deletes the destination before renaming the temporary file. Startup does not recover the temporary identity. | [keys.dart:66](D:/Projects/VibeCoded/mentos/mentos/lib/data/keys.dart:66). Use durable atomic replacement with recovery handling. |
| P2 | Migration can overwrite a destination store: it checks `.migrated`, but not whether the destination already holds a different identity/database, then copies files over it. | [session.dart:92](D:/Projects/VibeCoded/mentos/mentos/lib/state/session.dart:92). Refuse conflicting stores and stage/verify migration before removing the source. |
| P2 | Files larger than the native 80 MiB encrypted limit can be imported and offered successfully, but cannot be served/fetched. Imports also synchronously hash/copy through FFI on the UI isolate. | [native limit](D:/Projects/VibeCoded/mentos/mentos/native/src/lib.rs:362), [import](D:/Projects/VibeCoded/mentos/mentos/native/src/lib.rs:868), [Dart caller](D:/Projects/VibeCoded/mentos/mentos/lib/net/iroh_transport.dart:140). Validate ciphertext size before import and move import work to a worker. Account for encryption overhead. |
| P2 | Older history becomes inaccessible: queries now correctly return the newest 2,000 records, but UI/history sync has no cursor for older pages. | [db.dart:122](D:/Projects/VibeCoded/mentos/mentos/lib/data/db.dart:122), [engine.dart:683](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:683). Add stable timestamp/ID pagination and resumable history sync. |
| P2 | Android biometric unlock is misconfigured. MainActivity extends FlutterActivity; the plugin requires FlutterFragmentActivity. Errors are swallowed by the unlock screen. | [MainActivity.kt:5](D:/Projects/VibeCoded/mentos/mentos/android/app/src/main/kotlin/app/mentos/MainActivity.kt:5), [plugin instructions](https://pub.dev/documentation/local_auth_android/latest/index.html). Correct integration and surface recoverable errors; verify on a device. |
| P2 | PIN protection has no attempt throttling and stores an unsalted fast SHA-256 hash. It is a UI gate, not encryption tied to the PIN. | [lock_gate.dart:84](D:/Projects/VibeCoded/mentos/mentos/lib/features/settings/lock_gate.dart:84). Add delay/lockout, platform authentication, and a clear security model. |
| P2 | iOS/macOS/Linux have generated app shells but no native library candidates; transport falls back to offline. Web also has unconditional IO/FFI dependencies. | [iroh_native.dart:96](D:/Projects/VibeCoded/mentos/mentos/lib/net/iroh_native.dart:96), [factory](D:/Projects/VibeCoded/mentos/mentos/lib/net/transport_factory.dart:8). Document the supported platform matrix or implement/test native packaging per platform. |
| P2 | Group moderators are shown invite/promote/remove controls that engine methods reject for nonowners. | [group_info_screen.dart:29](D:/Projects/VibeCoded/mentos/mentos/lib/features/chats/group_info_screen.dart:29), [updateGroup](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:2263), [invite](D:/Projects/VibeCoded/mentos/mentos/lib/net/engine.dart:2521). Align UI capabilities with protocol permissions and return meaningful errors. |
| P2 | Restore can remain stuck busy on missing files or failed copies: `_restore` catches only FormatException, while import throws StateError/FileSystemException. | [onboarding_screen.dart:48](D:/Projects/VibeCoded/mentos/mentos/lib/features/onboarding/onboarding_screen.dart:48). Handle all expected errors, reset busy in finally, and guard mounted state. |

Additional release work: no application-level integration tests were found for hostile peers, migration/restore, long histories, or offline retry. The five existing tests primarily cover crypto and poll closure. Native binaries are copied from prebuilt locations rather than enforced as part of one reproducible source build. The README remains the Flutter starter text. Signing files are present locally but are ignored by Android's `.gitignore`; their presence alone is not evidence of a committed credential leak.

## Improvements already present

Do not reopen the old report wholesale: group metadata now prevents the demonstrated ownership takeover; nonowners cannot close polls through the earlier vote flag; failed file decryption uses a temporary file and cleans failure output; blob fetching uses a worker lane with timeout/cancellation; outgoing connections have receive tasks; startup has readiness retries; default DM TTL is applied; an outbox and failed/sending states exist; history selects the newest window; wipe no longer recursively deletes the entire configured root. These improvements need integration coverage, and several still have the edge cases above.

## Features to complete the experience

### First: make existing promises dependable

1. **Delivery and recovery center:** per-recipient pending/delivered/read status, explicit retry/cancel actions, persistent failure explanations, and recovery after restart. A retry DB method exists but has no UI caller.
2. **Verified backup/restore:** snapshot progress, integrity checks, backup timestamp/version, phrase validation before replacement, and a restore rehearsal. Explain that the phrase restores identity; history needs a vault or consenting peers.
3. **Real background notifications:** OS notification integration, privacy-safe previews, permission onboarding, and documented offline/background delivery behavior. Current `_notify` only creates in-app alerts; there is no notification/background service integration in the inspected manifest/dependencies.
4. **Complete membership management:** explicit accept/decline state, persistent invitations, expiring/revocable invites, owner transfer, reliable leave/remove semantics, key epochs and role-aware controls.
5. **Storage controls that cover everything:** visible encrypted/plaintext/cache usage, quota enforcement, download policy by network and file size, resumable transfers, and retryable actionable errors.

### Next: remove everyday friction

6. **Full-text message search and history navigation:** search inside/across conversations, date/author/attachment filters, jump to result, and older-history pagination. Existing chat-list filtering and hosted-file search are not message search.
7. **Persistent drafts:** text, reply target, selected media and edit state preserved across navigation/restarts, with a clear discard action.
8. **Incoming share and invite links:** OS share targets, tappable contact/group links and QR workflows with a preview of what access accepting grants.
9. **Identity verification and device management:** compare fingerprints/QRs, trusted-contact status, explicit device linking and revocation; define what using the same recovery phrase on multiple devices does.
10. **Abuse controls:** message requests from unknown peers, rate limits, block propagation, moderator action history and user-controlled reporting/export. Preserve the app's decentralized privacy model.
11. **Accessibility and localization:** screen-reader testing, keyboard/focus support, large text, contrast checks, and RTL/localized layouts. Treat these as tested release criteria, not just settings.
12. **Useful support diagnostics:** sanitized export of connection errors, relay/direct status, native version and pending jobs; recovery actions for missing native binaries or corrupted local data.

Later, after reliability is established: calls, scheduled messages, richer discovery and additional social formats. Mentos already has chats, groups, spaces, forums, broadcasts, stories, polls, bookmarks and transfers; feature breadth is not the main missing ingredient.

## Suggested implementation order

1. Protocol kind/schema validation and adversarial regression tests.
2. Consistent backup/restore, complete wipe, outbox expiry/deletion, protected keys.
3. Membership/key lifecycle and bounded network/storage work.
4. Two-device integration tests, Android lifecycle testing, and reproducible release packaging.
5. Search, drafts, notifications, invitations and diagnostics.
