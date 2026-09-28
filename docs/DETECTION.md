# Recurring-charge detection — milestone 5 contract

Reviewed 28 September 2026. The review is `docs/reviews/milestone-5-review.md` (28 decisions). Where
this document and that review disagree, the review wins. PLAN's numbered owner decisions bind both.
The one departure from PLAN's milestone 5 text, "Maybe cancelled?" no longer removing a bill, is put
to the owner as an open question at the end of the review. Nothing here is implemented yet.

## The rule every other rule obeys

Automatic detection may lower safe-to-spend or leave it alone. It never raises it. Only two things
raise the figure:

- bank evidence that the money has already left a counted balance
- an owner action: Dismiss, Mark cancelled, Mark paid, "Not this payment", or setting a transfer's
  destination

Everything below is checked against this (review 1).

## Evidence and boundaries

Detection is local and spends no requests. It runs on a background worker (review 6):

- after each transaction pull, including a partial one
- at launch, if unfinished work exists
- after owner actions that change its inputs

There are no timers.

**Scope.** A series belongs to one account, one currency, one merchant key and one cadence.
Similarly named merchants on different accounts never merge. Detection skips accounts the engine
classifies as holding shares or funds, or as loans (review 19). Non-USD series are shown in their
own currency and kept out of USD totals.

**Which rows count.** Every query ignores voided and superseded rows. Direction follows the
account's `amounts_reversed`, which has no effect on credit accounts, the same as the engine. Only
settled, dated debits establish recurrence. Credits are used for refund pairing only, and pending
rows for payment matching only.

**Merchant keys.** Every row, of any sign or state, gets a merchant key at ingestion. Existing rows
get one through a resumable backfill. No clustering runs until the backfill has finished. The rules
are pinned in review 7:

- payee first, else description
- locale-free ASCII uppercasing
- processor prefixes stripped, with the prefix's brand kept when nothing follows it
- reference tokens removed
- a final state code dropped, and nothing else
- the first three significant tokens after a fixed stopword list, plus product words

When the key comes from the payee, the description's key is also stored as an alternate.

**Dates.** The detection day is the transaction date when it is plausible (not after posting, and
at most 10 days before it), else the posted date. An undated row has no detection day and never
joins a series. Days are UTC calendar days from bank instants, converted to local days by date,
never by instant (review 8).

## Finding a series

Each merchant key is recomputed from its whole history over the last 430 days, so a partial run and
a full run give the same answer (review 9). The steps:

1. **Count.** Count first. A key with more than 400 rows in 430 days is too dense to read: no new
   series and no status changes. Existing confirmed series keep counting, and settle only on a
   unique match. The Bills screen says the app does not look for bills among places the owner pays
   very often.
2. **Pair refunds.** Refunds pair one-to-one with an exact-amount debit on the same account and key,
   0 to 30 days earlier. Any ambiguity or partial refund pairs nothing (review 17).
3. **Build amount tracks.** A charge joins a track within ±5% of the track's current amount,
   compared as integers.
   - A price step continues a track when all of these hold:
     - the charge is from -25% to +50% of the current amount
     - it lands at least 0.75 of the track's median gap after the last charge
     - it is the only such track
     - it is settled
   - Prefer an existing same-price track over a price step.
   - Overlapping different prices are separate tracks.
   - A charge that fits two tracks equally joins neither, and both are capped at suggested.
4. **Fit a cadence.** Calendar-day gaps fit weekly [5,9], biweekly [12,16], monthly [26,35],
   quarterly [80,100] or annual [340,395].
   - At least 80% of the gaps must fit, measured as `5·fit ≥ 4·gaps`.
   - The lower median must fit.
   - One doubled gap may count as a skipped charge. This is allowed only with at least three gaps,
     and never to choose between cadences.
   - Two day-of-month clusters that each fit monthly are two monthly series, never one biweekly.
5. **Set the status.** Two charges make a suggestion. Three confirm automatically and start counting,
   visibly badged (PLAN decision 4).
6. **Single yearly charges.** A single yearly charge is only ever a suggestion (review 28). It needs
   all of the following:
   - at least $20
   - one continuously fetched stretch of at least 300 days around it with no other charge from that
     merchant
   - a yearly keyword

## Identity, dismissal and owner control

**Identity.** A series is identified by its database row, not by anything derived from its data.
Evidence is stored as links from transactions to series (review 10):

- one transaction belongs to at most one series
- one occurrence is paid by at most one transaction

A newly computed track continues the series its charges are already linked to. If none are linked,
it continues the one unambiguous series on the same account, merchant and cadence that ended just
before it. A newest-first history backfill therefore cannot resurrect a dismissed bill.

**Dismissing and cancelling** (review 11):

- Both write a suppression for the account, merchant, cadence and amount band, and keep the row.
- A new track matching a dismissal is attached and never shown.
- A dismissal never absorbs a track that runs alongside it, or one on a different day of the cycle.
- After Mark cancelled, only charges made after the cancel day (plus tolerance) show "Charged again
  after you marked it cancelled". Three of them count again, badged.
- Undo is immediate.

**Status.** Status only moves forward. Nothing automatic un-confirms a bill, even when the charges it
was found from are later refunded, corrected or aged out. The row asks the owner to check it
instead (review 12).

**Owner edits** (review 21):

- Owner edits change only the fields touched, and set an override bit per field.
- Later detection records its own reading in separate columns and never overwrites an overridden
  field.
- Every owner write checks a revision. A form opened before a detection or payment write reloads
  instead of overwriting it.
- Delete exists only for manual rows with no linked evidence (review 22).

**Manual bills** (review 20) gain an optional "How does this show up on your statement?" field.

- A detected track adopts a manual row only when all of the following match the one manual row
  that qualifies:
  - the statement merchant
  - the account and cadence
  - the amount band
  - the due day within tolerance
- After adoption the owner's name, amount, anchor and paid-through date stand.
- Otherwise both rows count, and the disclosure offers **Same bill** with Undo. Name similarity, or
  amount and date alone, never merge anything.

## Payments, balances and forecasts

**Paid-through.** `next_expected_date` stays the owner's paid-through marker. For a detected row it
is set once, to the anchor. The engine computes the **effective** marker at query time as the later
of:

- that date
- the occurrence after the latest live payment link

A payment link is live when its transaction is settled, not voided or superseded, and its amount is
unchanged since it was linked. A void, correction or refund therefore steps the marker back
immediately, without waiting for the worker. "Not this payment" removes a link for good. Detection
never calls Mark paid and never touches a manual balance (review 13).

**Tolerance.** A settled debit pays an occurrence only within this tolerance of it:

| Cadence | Tolerance |
|---|---|
| Weekly | ±2 days |
| Biweekly | ±5 days |
| Monthly | ±5 days |
| Quarterly | ±10 days |
| Annual | ±20 days |

A debit outside it is evidence only, so a late charge can never pay the next occurrence and drop an
unpaid one.

**Anchors.** Anchors keep month ends from drifting. Automatic re-anchoring may only move a due day
earlier. A later day is suggested to the owner (review 14).

**Payment found, balance not caught up** (review 15). Balances and dated transactions arrive in
different requests. While the paying account's balance is not from a later UTC day than the
payment's posting, the payment stays subtracted: "Payment found. I'll stop counting it once your
bank's balance shows it." This replaces the milestone 2 review's statement that a settled match
never triggers retention.

**Pending charges** (review 16). A pending match never moves a marker. It removes exactly one
occurrence at query time, and only when all of the following hold:

- the account's available balance is in use
- that balance arrived after the hold was first seen
- the hold is still live
- the match is unique

## Transfers, lateness and cancellation

**Transfers** (review 18):

- Detection never classifies anything as a transfer. Keywords such as AUTOPAY or ZELLE are not
  evidence (PLAN decision 3).
- A same-amount credit on another owned account, seen at least twice, moves the row to "Looks like a
  move between your accounts".
- That row stays subtracted until the owner names the destination.
- It is left out of the subscription total. From then on ENGINE's destination rule applies.

**Absence** (review 4). A charge is proven absent only when all of the following hold:

- a continuously fetched stretch covers its expected day plus tolerance and a 5-day posting margin
- no pending charge matches
- no debit of that amount appears on the account under any merchant name

A nearby unmatched debit reads "Possibly charged under a different name on September 3."

**"Maybe cancelled?"** (review 2) needs the two most recent occurrences both proven absent. For an
annual bill it needs one, plus 90 days.

- The flag is shown on the row and in the Overview disclosure.
- The bill **keeps counting** in safe-to-spend and the monthly total. A bill that is late but not
  flagged keeps counting and says so.
- **Still active** clears the flag.
- **Mark cancelled** persists the cancellation and its suppression, and only then stops counting.

**Coverage** (review 3) comes from a table of intervals actually fetched, written in the same
transaction as each successful dated window. A balances-only answer, a budget pause, an error or a
vanished account proves nothing. Milestone 5 re-walks history once, within the existing request
budget, to fill the table. Until then, coverage-dependent findings say the period "hasn't been
checked yet".

## Storage and incremental work

Schema v5 is forward-only (review 23). It adds:

- the coverage, dirty-work, occurrence-link, link-rejection and suppression tables
- merchant columns, a generated detection day and the `(account, merchant, detection day)` index
- owner, detected, currency, revision and inference columns on `recurring_charge`
- a generated `monthly_cents`

**Dirty work.** SQL triggers enqueue the old and new account and merchant keys in the same
transaction as any real change to a transaction, an account's sign or type, or a manual bill's
matching fields. A change guard stops unchanged rewrites from enqueuing anything. The detector's own
writes are never in a trigger's column list (review 5).

**The worker** (review 6):

- clears a key in the same transaction that writes its result
- quarantines a key that fails three times
- shows "Bill detection couldn't finish. I'll try again after the next refresh."

## Presentation and totals

**Bills & subscriptions** (review 25):

- **Paging:** keyset pages of at most 50 rows in a `LazyVStack`, by monthly cost then id.
- **Sections:** confirmed, "These might be bills", yearly, maybe cancelled (still counted), looks
  like a move between accounts, and scheduled transfers.
- **Each row says:** its currency, cadence, paying account, next date, how it was found, and any
  price change ("went up from $9.99 to $10.99 in August").
- **Notice:** "N new bills found" shows until Bills is viewed.
- **History line:** the per-account coverage line explains an empty yearly section.
- **Stall notice:** "Bill detection hasn't seen new transactions since September 2" appears when
  coverage has stopped advancing while balances are fresh.

**The monthly total** (review 24) is one SQL sum of per-row rounded monthly cents:

| Cadence | Monthly share |
|---|---|
| Weekly | 52/12 |
| Biweekly | 26/12 |
| Monthly | 1 |
| Quarterly | 1/3 |
| Annual | 1/12 |

A yearly 13900 contributes 1158. The sum covers:

- **Included:** confirmed USD bills and subscriptions, including flagged ones.
- **Excluded:** suggestions, dismissed and cancelled rows, transfers and transfer-shaped rows, and
  rows on share, fund or loan accounts.

It never depends on which pages are loaded.

**Overview** (review 26) observes the charges plus two bounded queries of payment links, never
transaction history.

## Verification and acceptance

The 30 synthetic test cases are in review "Test cases".

Measurements:

- full detection over 6,000 synthetic settled rows (wall time and peak footprint delta)
- an incremental pass after 30 rows (time, and the query plan showing the detection index)
- scrolling 300 paged bill rows
- idle footprint and leaks

Run the full suite and a synthetic acceptance with `-derivedDataPath DerivedData` on the owner's Mac.
Record the exact revision and the limits of each measurement. The annotated `v0.5-detection` tag
carries the measured numbers. The owner sees milestone 5 run before milestone 6 starts. Real data
stays in the app.
