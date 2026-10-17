# The Mentos ledger

Mentos coins are one ledger that the phones on the network keep together. There is no server, miner, validator set or operator. This document describes the protocol in `lib/net/pay/coin.dart` (`coin-v3`, gossip topic `mentos-coin-v3`).

## Accounts are signed chains

Every account is a chain of entries signed with its owner's Ed25519 key. Each entry names the hash of the previous one (`prev`) and carries the next sequence number. Only the owner can append, and nobody can reorder or drop entries without the owner's signature. The signed bytes are a fixed-key-order JSON body. Entries without the escrow fields (`x`) keep the exact v1 bytes, so ledgers written by earlier versions still verify.

| Kind | Signed by | Effect |
|---|---|---|
| `mint` | new identity | Draws the 5.00 welcome grant from the treasury, once. The bytes are fully determined by the key, so restoring a phrase recreates the same grant rather than a second one. |
| `send` | payer | Moves coins to another account. Memos starting `task:` or `resource:` add a 5% service fee for the treasury, paid by the sender (legacy rule). |
| `reward` | worker | Draws the contribution reward for a legacy service receipt, once per receipt. |
| `lock` | payer | Opens an escrow hold for a payee: `until` (deadline), optional `ack` (accept-by) and optional `arb` (arbiter). The amount leaves the payer's balance. |
| `ack` | payee | Accepts the hold. After this the payer can no longer cancel it. |
| `release` | payer, or arbiter after a dispute | Pays some or all of the hold to the payee, minus the trade fee. |
| `refund` | payee, or arbiter after a dispute | Hands some or all of the hold back to the payer. |
| `cancel` | payer, before `ack` | Takes the whole hold back. |
| `dispute` | payer, before `until` | Freezes the hold: no claim is possible, and only release, refund or the arbiter can settle it. |
| `claim` | payee, after `until`, if accepted and never disputed | Collects what is left, minus the trade fee. |

The treasury address is `sha256("mentos:network-treasury:v1")`. No key exists for it, so it can never sign. It starts with the whole supply (100,000,000.00), and grants, fees, rewards and checkmarks only move that supply around. Escrow releases and claims for `order:`, `task:`, `resource:` and `ad:` holds pay a 2% trade fee to the treasury, taken from the payee's side. Exchange holds pay no fee.

## Everyone computes the same view

`compileCoin(pool, votes)` is a pure function. Given the same set of entries and votes, every phone produces the same balances, holds and chains:

- Entries are applied earliest first, by `(timestamp, hash)`. An entry is only ready once its chain predecessor has been applied and, for spending entries, once the account can cover it. For escrow steps, the hold must exist.
- Escrow steps are accepted into the chain even when they change nothing (a claim after a dispute, say). They are recorded as **void**, so a single late step never blocks the rest of an account's chain.
- Supply is conserved. Balances plus coins held in escrow always total the endowment; the tests check this under random reorderings.

Entries are checked at ingestion: signature, shape, timestamp at most 10 minutes in the future, at most 20,000 entries per account, and an existing parent. Entries that arrive before their parent wait as orphans.

## Double spends, votes and finality

Two entries at the same place in one chain are a double spend, and both signatures prove the owner made them. The ledger handles it in three ways:

1. **Votes.** Each phone signs a vote (`mentos-coin-vote:v1|account|seq|hash`) for the first entry it stores at each place, and never for a second one. Votes are gossiped and synced with the account. A phone that votes for two entries at the same place has both of its votes ignored, and an account's votes on its own chain do not count.
2. **Fork choice.** Where a chain forks, the walk follows the branch with more voting stake. Stake is each voter's balance plus what they hold in escrow, taken from a vote-free first pass so the weighting is not circular. Ties, or no votes at all, go to the lower hash.
3. **Flagging.** The account is marked as a double spender everywhere. The marketplace shows this next to the person's name, and the losing payment shows as *conflicted*.

Confirmation levels shown in the wallet:

- **Accepted**: counted by this phone.
- **Witnessed**: at least one other phone voted for it.
- **Final**: no competing entry and enough witnesses (three, or everyone else in a smaller network).
- **Conflicted**: a competing entry exists.

Sellers can wait for *Final* before shipping anything valuable.

## Sync

All nodes join the coin topic. They announce per-account summaries (entry count, digest of hashes, vote count). When two phones meet, each sends the accounts the other lacks, along with their votes. Messages that depend on a payment (orders, task offers, trades) attach a bundle: the payment plus a few of its ancestors, so the recipient can verify it immediately.

## What this is not

- **Not Byzantine consensus.** Two partitions that have not met can disagree, and a payment can be reorganised if a competing branch later gathers more stake. Votes make that much harder, but they do not make it impossible.
- **Sybil-limited, not Sybil-proof.** Identities are free. Each one gets a 5.00 grant while the treasury lasts, and that grant counts as voting stake.
- **Backdated disputes.** A payer can backdate a dispute to just before the deadline. Without an arbiter, this freezes the hold for both sides rather than benefiting the payer.
- **Not money.** Mentos are not redeemable outside the network. A birr price is an agreement between two people.
