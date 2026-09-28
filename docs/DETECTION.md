# Recurring-charge detection — milestone 5 contract

Draft for independent review, 21 September 2026. PLAN's numbered owner decisions govern.
This document makes milestone 5 implementable alongside the shipped ENGINE and SYNC contracts.
The owner checked persistence after quitting/reopening milestone 4 and explicitly authorized M5.

## Evidence and boundaries

Detection is local, uses no extra requests, and runs off the main actor after a transaction pull
(including a partially completed pull) and once at startup to recover unfinished work. No timers.
Every query ignores voided and superseded transactions. Scope is account, currency, merchant and
cadence; similarly named merchants on different accounts never silently merge. Non-USD recurring
rows are displayed in their own currency and excluded from the USD monthly total and engine.
Bank amount direction follows the account's effective sign convention, including amounts_reversed
for deposit accounts; credit signs use the existing bank-debit convention, not balance signs.

Normalize all rows, including credits and pending debits, so refunds and payment evidence can be
compared. Only settled debits establish recurrence. Use payee when nonempty, else description;
memo supplies annual keywords, never silently changes a nonempty merchant identity. Uppercase,
ASCII-fold, strip documented processor prefixes, numeric reference tokens and URL tails, retain
product words, special-case APPLE.COM/BILL, and retain at most three significant words. Avoid
discarding an arbitrary final pair of merchant words as a city: remove a trailing city/state only
when there is a recognized state suffix. AMZN marketplace remains distinct from AMAZON PRIME.

Use transaction date when positive, otherwise posted date; undated rows cannot establish cadence.
Calendar-day gaps, not seconds, determine weekly [5,9], biweekly [12,16], monthly [26,35], quarterly
[80,100], and annual [340,395] recurrence. At least 80% of gaps must fit, with at most one gap in
twice the cadence window interpreted as one missed occurrence. The median adjusted gap must fit.
Two observations suggest; three confirm automatically and start counting visibly. A single annual
candidate needs at least $20, >=300 days of successfully fetched history covering that merchant,
one settled debit, and ANNUAL/YEARLY/RENEWAL/MEMBERSHIP/PRIME/SUBSCR/ONE YEAR evidence. It is only
a suggestion, even if the merchant name is familiar. Positive paydays never qualify.

Match refunds one-to-one, same account/merchant and exact absolute amount, within 30 calendar days
after the debit. A credit cannot erase two debits. Ambiguity/partial refunds retain the debit as
evidence; no amount-sign shortcut erases an entire merchant. A late refund requeues that merchant.

## Series identity, changes and corrections

An amount is within a series at +/-5% of its current amount, using integer comparisons. A unique
sequential price step from -25% to +50%, at least 0.75 of the interval after the previous charge,
continues that series; record the old amount and change month. Prefer an existing same-price track
over a price-step interpretation. Overlapping different prices are separate tracks, including
APPLE 2.99 and 9.99. Ambiguous assignments stay suggestions, never create confidence from one
transaction counted twice. One transaction belongs to at most one series.

Fingerprints are permanent identities scoped to account/currency/merchant/cadence and the initial
amount track. Do not rebuild them from the latest price. Dismissed/cancelled rows remain and follow
the same unique price-step lineage; they never reactivate automatically. Historical matched row
links help retain identity on replay and corrections. A new debit after cancellation gets a visible
"Charged again after you marked it cancelled" note. Confirm/dismiss/cancel are durable writes.

A uniquely matching manual bill adopts evidence in its existing row. Require an explicit statement
merchant (new optional field in the manual form), same paying account, cadence, amount band and
compatible due date. Name similarity or amount/date alone cannot prove identity. Preserve its name,
owner amount/cadence/anchor and explicit paid-through state. Ambiguous duplicates remain counted,
with a Same bill action that merges evidence and permanently suppresses the duplicate atomically.
Owner edits use freshly fetched rows and named-column/field ownership, never overwrite newer
detection evidence from an old form. Editing a detected amount/cadence/account/merchant establishes
an owner override; later runs may attach evidence but cannot reverse that correction.

## Payments, balances and forecasts

Store each matched transaction's bill and occurrence date. Pending matches require one unique
same-account/merchant/amount/date candidate (+/-5 days); ambiguous matches do not waive an obligation.
Pending rows never advance the durable paid-through marker. At query time they suppress exactly
one occurrence only if the engine is actually using that account's available balance. A void,
supersession, sign correction, plain balance, or account reclassification reverses that suppression.

Settled matches advance the detected forecast from the last observed occurrence with its original
calendar anchor (month ends do not drift). Do not call the manual Mark paid action. Replay is
idempotent; corrections and voids reconcile against the remaining live evidence. Explicit owner
paid-through state remains authoritative for manual rows. If a matched settled debit is newer than
the counted balance, keep its amount withheld until that balance catches up: "Payment found;
waiting for your balance to catch up." Do not label this as an owner payment or reduce bank balances.
One debit settles at most one occurrence. Skipped historical periods are not charged again.

## Transfers, lateness and cancellation

Binding PLAN decision 3 supersedes M5.D's broad keyword shortcut. AUTOPAY, PAYMENT THANK YOU,
ONLINE PMT, ACH PMT, CRD PMT, ZELLE, VENMO or TRANSFER alone do not prove an own-account movement.
An owner-confirmed destination or an unambiguous paired debit/credit to another owned account
establishes transfer identity. A merchant autopay or Zelle rent remains a bill. Transfers have their
own section and never enter the subscription monthly total. Safe-to-spend uses ENGINE's existing
destination treatment: counted-to-counted excluded, money into excluded savings/cards subtracted.

M5.F deliberately excludes a sufficiently overdue detected bill when labelled "Maybe cancelled?";
this is a forecast inference, not a persisted cancellation. Strengthen its evidence gate: both the
balance and successful dated transaction coverage must extend beyond last seen + two intervals
(annual: next expected +90 days), with no account/connection error, coverage gap or vanished account.
Use the earlier of balance_date and tx_synced_through, never wall-clock time. Manual bills without
bank-linked evidence cannot be flagged. Insufficient coverage says the period has not been checked;
it cannot remove a bill. Between expected+grace and that threshold keep counting and show lateness.
The flag is computed, not a destructive status write; new evidence automatically restores counting.
Still active records the evidence cutoff acknowledged by the owner, restores counting immediately,
and does not move the paid-through marker. It may be flagged again only after another complete
cadence of new reliable coverage. Mark cancelled persists cancellation and suppression lineage.
This retains the explicit M5.F acceptance behavior; the review must assess its evidence boundary.

## Storage and incremental work

Forward-only migration v5; do not alter v1-v4. Add detection metadata and occurrence association
storage plus a durable dirty work queue. Keep schema details with the implementation below before
merging code. Existing recurring-charge fields retain their shipped meaning.

The old max-rowid proposal is replaced: transaction insertion, correction, rekey, pending settlement,
void, supersession and merchant changes atomically enqueue both affected old/new account+merchant
keys. Account sign/type changes and manual evidence edits also enqueue affected groups. Backfill
normalization with a streaming cursor and queue existing merchants. A crash cannot acknowledge work
without committing its bill/link changes. A single worker transaction owns each merchant drain.
Do not requeue detector-only link writes. No transaction-table arrays: SQL aggregates/cursors and
bounded per-merchant history. A dense or ambiguous merchant beyond a documented bound must abstain
and retain existing owner decisions, not silently sample enough rows to auto-confirm it. Queries
must use the account/merchant/date index; dirty work deletion and series changes commit together.
Expose failures as "Bill detection couldn't finish; it will try again" and leave queued work intact.

## Presentation and totals

Bills & subscriptions uses SQL pages of at most 50 rows in LazyVStack, sorted by monthly cents
descending then stable ID. Confirmed bills/subscriptions, suggested bills, annual callouts, maybe
cancelled items and scheduled transfers are clearly distinguished. Paginated display must not make
the total depend on loaded pages. The engine may keep the much smaller recurring-charge collection;
it must never fetch transaction history into memory. Overview immediately observes confirmations,
dismissals, cancellations, evidence and account classification changes.

Use per-row rounded integer monthly equivalents (52/12,26/12,1,1/3,1/12), then sum. Confirmed active
USD bills/subscriptions count; suggestions, dismissed/cancelled, inferred inactive and transfers do
not. Yearly 13900 cents contributes 1158. Card-billed subscriptions remain in monthly cost; ENGINE's
existing card fallback governs until M6. Each row states its currency, cadence, paying account,
next date, confidence and any price change; no unexplained internal terminology.

Unread auto-confirmations show "N new bills found" until Bills is viewed. Keep an auto-detected
badge with Dismiss; suggestions have Confirm/Dismiss, inactive items Still active/Mark cancelled.
Dismiss and cancellation retain records rather than DELETE; offer immediate Undo as well as the
later M9 management surface. Show per-account history coverage so limited annual findings are
explained. No credentials or real data in fixtures, logs, screenshots or measurement artifacts.

## Verification and acceptance

Test normalization variants; APPLE two amounts; marketplace versus Prime; Spotify price change;
skipped-month and biweekly gyms; one annual Costco; positive paydays; one-to-one/late refunds;
old-row corrections below any cursor; movement between merchants; pending settlement and reversal;
idempotent replay; manual adoption and ambiguity; stable dismissal after price changes; owner edits
surviving sync; transfer words versus actual owned destinations; currency/sign gates; missing/error
coverage preventing cancellation; Still active restoring totals; and bounded paging/sorted totals.

Measure full detection on 6,000 settled synthetic rows, incremental after 30, query plan, peak
footprint, scrolling 300 paged bill rows, idle and leaks. Run the full regression suite and native
synthetic acceptance, record exact revision/build and measurement limits. Annotated v0.5-detection
includes measured numbers. Owner reviews M5 before M6 starts. Real data stays solely in the app.
