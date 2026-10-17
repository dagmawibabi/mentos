# Marketplace

The marketplace is anonymous and peer to peer. Identities are pseudonymous keys, there is no server, and every Mentos that changes hands moves through the ledger's escrow (`docs/COIN.md`). The code is in `lib/net/market/` (engine) and `lib/features/market/` (UI).

## Listings travel the whole network

A listing is a signed record (`Listing` in `listing.dart`):

- **Identity and versioning.** It has an id that names its author, a revision number and a kind-specific body. Only the author can change it, and only by signing a higher revision. Withdrawing a listing signs a tombstone.
- **Propagation.** New revisions flood the `mentos-market-v1` gossip topic. When two phones link up, they compare revision summaries and exchange whatever the other lacks, including reviews. Because listings are signed, any phone can relay them, so a listing reaches people its author has never met.
- **Limits.** Every listing is validated without throwing before it is stored: types, lengths, money bounds, media references and URLs. Limits are 24 KB per listing, 60 live listings per author and 5,000 per phone. Listings expire after 45 days unless refreshed (the author's phone re-signs its own listings weekly), and listings from blocked people are dropped.
- **Carriers.** The phone that first passed a listing on is recorded as its *carrier*. Ads pay carriers.

Kinds: `item` (shop), `task`, `ad`, `resource` (storage and compute), `exchange` (Mentos for birr), `plugin` (declarative packs), and `space` (a public space's directory entry).

## Shop

1. **Cart.** Items, quantities and options are kept per seller.
2. **Checkout.** One escrow per seller covers items plus delivery, priced from the current listings. The buyer can pick one of the seller's listed arbiters, or none. Delivery details go only to the seller, over the encrypted direct channel, and are stored in the encrypted database (wiped with the identity).
3. **Seller.** Accepts (signs `ack`, and stock is decremented and republished) or declines (full refund). Then marks the order shipped with tracking text, or delivers files for digital goods. Digital listings can auto-deliver files the seller attached privately.
4. **Buyer.** Can cancel before acceptance, confirm receipt (release), or open a dispute (which also sends the case to the arbiter, if one was chosen).
5. **Payout.** The seller's phone claims a matured hold the buyer never disputed. An arbiter can split a disputed hold.
6. **Reviews.** After payout, either side can leave one signed review per escrow. A review only counts when the ledger shows its author and subject on opposite sides of that escrow. Reputation (sales, purchases, tasks, disputes, stars, checkmark, double-spend flag) is computed from the ledger and these reviews.

## Tasks

1. **Posting.** The owner posts a reward, deadline, acceptance criteria and the evidence they want (text, photos, files, links).
2. **Picking.** Workers apply with a pitch. The owner picks one, and the reward moves into escrow for them; the others are told they were not chosen.
3. **Doing the work.** The worker accepts, then submits evidence. Photos and files stay on the worker's phone and are fetched when the owner opens them. The owner ticks each criterion before approving.
4. **Review.** The owner either approves (release), asks for changes, or disputes (sending the case to the arbiter).
5. **Leaving or claiming.** The worker can decline or withdraw by handing the reward back. If the owner never reviews, the worker's phone claims the hold after the deadline plus the review window.

## Ads

1. **Campaigns.** A campaign sets a budget, a price per view and per click, a daily cap, an end date, a target (a listing, a profile or a link) and the split between viewer and carrier.
2. **Showing.** Viewers opt in under *Earn from ads*. Feeds then show a sponsored card after every six posts, capped at three showings per campaign per day.
3. **Receipts.** After a card has been on screen for 1.5 s, the viewer's phone signs a receipt naming the campaign, the day and the carrier, and sends it to the advertiser.
4. **Payment.** The advertiser's phone verifies each receipt and enforces these limits:
   - one paid view and one paid click per viewer per campaign per day
   - 300 paid views per carrier per day
   - the campaign's daily cap and budget
   - viewers must have a ledger account and not be flagged

   Earnings build up per payee and are paid in batches. A campaign pauses when the advertiser's balance runs out and ends when its budget or time is used up.

Receipts prove a signature, not attention, and cheap identities can still farm small amounts.

## Resources

1. **Diagnostics.** These are measured on the device and attached to the offer:
   - CPU: single-core and all-core SHA-256 throughput, giving a score
   - memory
   - free storage, plus disk write and read speed
   - network path: direct or relayed, relay latency, UDP
2. **Storage leases.**
   - The renter pays the whole term into escrow.
   - Files are encrypted on the renter's phone, and the provider fetches only ciphertext, never the key. Leased bytes do not count against the provider's own media quota, and the provider refuses overbooking.
   - Before handing a file over, the renter computes ten one-time challenges (`sha256(nonce ‖ ciphertext)`). Every 12 hours the renter's phone sends one, and only a provider holding every byte can answer.
   - Each passed audit releases the share of the term that has elapsed. Two failures in a row dispute the hold.
   - The renter can free local space and fetch a file back from the provider later. Ending early pays for the days used, and the provider hands back the rest and deletes the files.
3. **Compute jobs.** Jobs come from a fixed menu: gzip compression, photo resize and compress, and proof-of-work stamps. They run in an isolate, and nothing a renter sends is executed as code. Price is units × price per unit, where a unit is 1 MB of input or one difficulty step. The renter's phone verifies each result before releasing payment (decompress and compare, check image bounds, re-hash the stamp) and disputes a bad one.

## Exchange (Mentos ↔ birr)

Offers state a side, a rate in birr per Mentos, limits, payment methods, a payment window and terms. The Mentos seller always locks first:

1. The seller locks the Mentos in escrow for the buyer, and shares private payout details over the encrypted channel.
2. The buyer accepts, pays birr outside the app, and marks it paid.
3. The seller releases once the birr arrives. If it never arrives, the seller disputes before the window closes. If the seller goes silent after being paid, the buyer claims the hold when the window closes.

Arbiters listed on the offer can settle disputes. Birr never touches the ledger.

## Plugins

Sticker, phrase and accent packs are data, validated on install. They never run code. Paid packs are bought with a single payment.

## Public spaces

When an owner makes a space public, a `space` listing carrying the owner-signed invite is published. The owner's phone refreshes it when the name, description or member count changes, and withdraws it when the space goes private. *Discover spaces* lists every public space on the network. Space invites in chats and posts render as cards that join in one tap.

## Verification

`flutter test test/market_workflows_test.dart test/escrow_test.dart test/coin_test.dart test/market_ui_test.dart`

Set `MENTOS_CAPTURE_UI=1` to save phone-size previews of the market screens under `build/market-previews`.
