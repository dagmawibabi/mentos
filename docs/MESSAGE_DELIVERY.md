# Message delivery

Direct chats, group chats and space-channel messages now use a durable per-recipient delivery queue. The signed message and its recipient snapshot are committed in one encrypted SQLite transaction. Existing pending message entries in the old outbox are migrated when the engine starts; other protocol operations continue using that outbox.

## What users see

- **Waiting to send:** saved locally and waiting for a send attempt. Offline time does not consume attempts while the transport is stopped.
- **Sending:** a transport call is in progress.
- **Sent · awaiting confirmation:** bytes were handed to the transport; the recipient has not acknowledged this message.
- **Delivered:** the recipient's application accepted this exact signed message. This does not promise permanent storage: existing consent-based retention still applies.
- **Read:** a read receipt naming this message arrived from its recipient, with receipts enabled there.
- **Delivery unconfirmed:** six attempts have completed without confirmation. Manual retry or a recipient reconnection starts another retry cycle.
- **Retries cancelled:** further attempts stopped. An in-progress send can still arrive; a valid late receipt updates the status to delivered/read.
- **Saved locally:** there were no other known eligible recipients when the message was created.

Unconfirmed messages have inline **Retry** / **Stop retrying** actions, also available in the long-press menu. Message info updates live with each recipient's state, attempt count and any failure explanation. Group status only becomes delivered/read when all tracked recipients reach that state. Retrying leaves confirmed recipients alone.

## Recovery and protocol

- The engine drains at most 32 due jobs per pass, with up to four concurrent engine-level calls. Native message I/O may serialize these calls further. A single pump prevents overlapping timer/reconnect/manual attempts.
- Backoff is 10, 20, 40, 80, 160 and up to 300 seconds, checked on the existing 15-second tick. After six attempts automatic retries pause. A stopped/unavailable transport preserves queued jobs.
- Startup recovers interrupted sending jobs. Link-up revives unconfirmed jobs for that peer. Explicit cancellation survives restart and reconnection; only a manual retry reactivates it.
- Direct `ack` controls include `id` and `scope`; `seen` controls include a bounded `ids` list and `scope`. The engine uses the authenticated connection peer as the receipt author. Scope timestamps remain for older peers, but never confirm newly tracked messages on their own.
- Duplicate accepted messages are acknowledged again. Concurrent direct ingestion of the same ID is serialized. Read markers are per-message, so late arrivals cannot inherit the read state of a newer message.
- Receipt controls use the durable existing outbox. Pending read controls are discarded when read receipts are disabled.
- Recipient membership/block status is rechecked before every retry. Group/space recipients are the known eligible members at send time; this is not a guarantee of delivery to undiscovered members or members who join later.
- New chat messages use direct recipient sends rather than counting a gossip broadcast as delivery. Other group/space events continue using the existing gossip protocol.
- Deleting a message/chat or expiring content removes its pending message jobs. Cancelled jobs are excluded from the sender's history responses to that recipient. Cancellation cannot remove copies already received by another device.

## Compatibility and limits

Both endpoints need this version for exact per-message confirmation. An older client may receive a message but only return a cumulative timestamp receipt; the sender will honestly show delivery as unconfirmed rather than infer receipt of missing messages. Older already-sent messages keep their previous receipt behavior.

This adds foreground/restart/reconnect recovery, not an OS background delivery service. Delivery still needs the sender and recipient to be reachable at some overlapping time. It does not add store-and-forward servers or guarantees about operating-system suspension.

## Validation

`test/delivery_test.dart` uses the real engine and encrypted SQLite store with an in-process transport. It covers restart, legacy-queue migration, duplicate/lost ACK recovery, per-recipient group retry, authenticated receipts, identical timestamps, cancellation races, concurrent pumps, deletion/expiry, retry exhaustion, out-of-order read state, cancelled history and a phone-width widget interaction test. The existing crypto suite remains applicable. Real-device relay/direct and mobile suspension testing are still needed before release.
