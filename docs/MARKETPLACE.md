# Marketplace and Mentos network protocol

## User flows

- Marketplace supports searchable categories, My work, publishing and editing listings, up to eight public attachments, and removal propagated to contacts. Listing revisions are accepted only from their original authenticated publisher. Owned listings are resent on reconnection. Discovery is between reachable contacts, not a globally indexed catalog.
- Tasks have a dedicated `/market/task/:id` workspace: application/withdrawal, owner assignment, submission with text and file evidence, review, requested revisions, acceptance/payment, dispute, worker release, and cancellation before assignment. The task owner publishes the canonical state; worker requests travel through the durable outbox. Evidence and activity are public listing content. Private discussions belong in chat.
- Tasks are **not escrowed**. Acceptance needs the owner's available balance. Disputes pause acceptance and are resolved by the participants; there is no automatic arbitrator. Completed task receipts must be checked against the local accepted ledger view. Task records persist separately from the recent-listing cache.
- Starter plugins are free declarative sticker, phrase, and accent packs. Publishers can release the same formats for free or for Mentos. Installation validates type, size, and content; it does not execute code or grant file/network access. Stickers and phrases appear in chat/channel composers; accents are applied from the installed pack sheet. Arbitrary third-party executable plugins are intentionally not supported.
- Channel owners can invite contacts; invitees receive an Activity entry and choose Subscribe. Subscriptions remain signed by the subscriber. Broadcasts use the shared chat composer and post renderer for pictures, video, files, voice recordings, stickers, and polls. Silent posting and pinned posts remain available.

## Treasury rules

The treasury address is SHA-256 of `mentos:network-treasury:v1`. It is a reserved ledger account, with no operator and no private key. It cannot sign outgoing payments. It is created holding `Coin.supply` (100,000,000.00 Mentos). That endowment is the entire supply; grants, fees, and rewards only move it.

- A new identity draws 5.00 from the treasury once, signed by its own key. The draw is the same bytes on every restore. It is accepted only while the treasury can cover 5.00, so a later checkmark or service fee can fund a grant that was waiting. Creating identities does not mint new coins.
- Paid checkmarks require an accepted payment to that address with memo `badge` or `badge:<amount>`, for at least the price in force just before that payment. The price is 10.00 at a full treasury and rises by 0.01 for every 5.00 drawn out, capped at 1,000.00. Refills bring it back down. An arbitrary payment to a friend does not qualify.
- Service payments whose memo starts with `task:` or `resource:` debit the payer by `amount + floor(amount / 20)`. The recipient receives `amount`; the treasury receives the additional fee. One Mentos is 100 minor units. The UI discloses this 5% fee before payment.
- The recipient can sign a `reward` transaction naming that accepted service receipt (`reward:<hash>`), extending their own account chain. Its only valid amount is `min(floor(receipt.amount / 20), 10)` minor units. It debits the treasury and credits the recipient.
- A receipt is redeemable once in an accepted view. Insufficient treasury funds, missing/rejected receipts, wrong recipients, forged signatures and wrong reward amounts cannot produce accepted rewards. Each reward is at most the fee contributed by its receipt, so circular service payments do not drain unrelated treasury funding.
- Reward rules are protocol code, not mutable local settings. There is no privileged withdrawal. Checkmark revenue remains in the treasury; this version does not invent an unverifiable automatic bandwidth/storage meter or discretionary treasury grants.
- Task and plugin/resource purchases use serialized `payOnce` receipt references. Ad claims use per-listing/per-recipient references and cannot exceed the advertised budget in the paying device's accepted ledger view.

## Upgrade and security boundary

This revision uses `coin-v2` application messages and the `mentos-coin-v2` gossip topic. All participating clients must upgrade; v1 peers do not understand treasury reward transactions or service fees. Existing signed ledger records are retained. Do not mix old and new software against the same identity/database.

The ledger checks Ed25519 signatures at ingestion, validates transaction shape, and deterministically derives balances from the known transaction pool. This is still an experimental peer ledger, **not Byzantine consensus or irreversible cryptocurrency settlement**. Different partitions may have different balances; conflicting account chains can reorganize, including payments, rewards, and checkmarks. Welcome grants are per cryptographic identity, and identities are cheap to create. Payment receipts establish that payment occurred, not that useful external work occurred. Production economic security needs a separate consensus, issuance, and verified-resource design and independent review.

## Verification

`flutter test test/market_workflows_test.dart test/market_ui_test.dart test/coin_test.dart test/channels_test.dart`

Set `MENTOS_CAPTURE_UI=1` to save phone-size light/dark previews under `build/market-previews`. Tests cover task transitions, authorization, payment retry idempotency, free pack validation, treasury supply conservation and single redemption, and screen rendering.
