# Payments: mutual credit

Mentos does not have a coin. It has **mutual credit**: when Ada pays Bo 10 credits, Ada now owes Bo 10, or Bo owes Ada 10 less. Credits are promises between two people, recorded by both of them, and nothing else.

This was chosen over a peer-maintained currency because a currency needs global agreement on who owns what. Without a server, that means a consensus system (a blockchain or a witness quorum) and a way to stop one person from running many fake nodes. Mutual credit needs neither: each balance concerns exactly two people, and both of them sign every change to it.

## How it works

- Every pair of people has one **credit line**: a chain of entries kept only on their two phones. The line's id is a hash of both node ids.
- An entry says: *line, sequence number, hash of the previous entry, payer, payee, amount, memo, time*. The amount is an integer in hundredths, up to one million credits.
- **Only the payer proposes.** The payer signs the entry with their Ed25519 identity key and sends it over the direct, end-to-end encrypted iroh channel. The proposal waits in a durable outbox until it is delivered.
- The payee checks the entry fits their copy of the chain (next sequence number, previous hash matches, payer and payee are the two of them, sane amount and time) and that the payer's signature is valid.
- Each person sets a **limit**: how much a contact may owe them. Default zero. If the payment keeps the payee's balance within the limit, the payee's phone countersigns automatically. Otherwise it waits for the payee to approve or decline.
- The payee sends back their signature. The payer checks it and records the entry. An entry counts only when it carries **both** signatures.
- To settle, the other person pays back. There is no undo.

## What this protects against

| Threat | Why it fails |
|---|---|
| Someone forges a payment from you | Entries need your Ed25519 signature. Tested: an entry signed by a third key is refused. |
| Someone changes an amount or memo after signing | Signatures cover the exact canonical bytes. Tested: a tampered amount is refused. |
| Replaying an old payment | The sequence number and previous hash pin each entry to one position in the chain; a replay of a settled entry only re-sends the existing acceptance. Tested. |
| Dropping or reordering history | Each entry includes the previous entry's hash, and both people hold the chain. The app re-verifies the whole chain when you open a credit line ("every entry signed by both"). |
| Being made to owe without consent | You only owe someone after you sign the entry yourself. |
| Being paid "too much" by someone who will never settle | The limit you set caps how much a person can owe you without your explicit approval. |
| Both people paying at the same moment | Both proposals claim the same position. The lower node id wins; the other phone countersigns that one and re-proposes its own after it. Tested: both phones end with identical chains. |
| A lost acceptance leaves a payment hanging | Unanswered proposals are re-sent; countersigning is idempotent. Tested. |
| Strangers sending payment spam | Messages arrive only over authenticated direct connections; blocked people are ignored; over-limit payments wait silently for approval. |

## What it does not do

- **Credits have no value outside the relationship.** You cannot pass Bo's debt to Cy. That would need transitive credit paths (as in Ripple's original design), which is a possible next step, not something that exists.
- **No enforcement.** If someone never pays back, the record proves the debt but nothing forces settlement. The limit is the protection.
- **Losing your phone without a backup loses your copy of the chains.** Your contacts still hold theirs, signed by you; restoring from your recovery phrase does not automatically fetch them yet.
- **Not money.** There is no exchange rate, no cash out, no link to a bank or any currency. Nothing in the app should describe credits as money, and the wallet's help text says so.
- **Timestamps are the payer's clock**, accepted within ten minutes of the payee's.

## Before anyone relies on it
- Chain recovery from a contact after a restore.
- A dispute flow (mark an entry as contested; both sides keep the evidence).
- An outside review of the signing and validation code in `lib/net/pay/`.
