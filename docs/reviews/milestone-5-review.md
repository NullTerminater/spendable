# Milestone 5 — recurring-charge detection: the review's decisions

This is the output of the design review that ran against the 21 September draft of
`docs/DETECTION.md` on 28 September 2026, before any milestone 5 code existed. It is kept verbatim
because the implementation is not written yet and the next person needs the rules, not a summary.
`docs/DETECTION.md` has been rewritten to match. Where the two disagree, this document wins.

**Who read it.** Two independent readers:

- **Reader A**, money correctness: any rule that could make safe-to-spend or the monthly total
  silently wrong. The agent first assigned to this lens was stopped before it finished and could
  not be resumed within the session's two-agent limit. The lead wrote this lens instead, and did so
  before reading reader B's findings.
- **Reader B**, data, storage and algorithm: coverage, invalidation, identity, bounds, and the
  shipped code the contract depends on.

Reader B then attacked reader A's findings and the lead's first adjudications. That cross-check
broke seven of the ten adjudications with concrete cases, and the decisions below include those
corrections. 11 findings came from A and 29 from B (8 of B's were blockers).

No build, test or measurement was run for this review. The review environment had no Xcode.

28 decisions, 7 findings rejected, 30 test cases, 1 open question for the owner.

## Decisions

### 1. `automatic-inference-never-raises-the-figure` (blocking)

Every automatic rule in milestone 5 may **lower** safe-to-spend or leave it alone. It may never
raise it. Only two things may raise the figure:

- bank evidence that the money has already left a balance the figure counts (decisions 13 and 15)
- an owner action: Dismiss, Mark cancelled, Mark paid, setting a transfer's destination, or
  "Not this payment"

Every later decision was checked against this rule. It follows rule 11's "safe is always better
than faster": wrongly holding money back is the cheap mistake, and wrongly releasing it is the
expensive one.

**Why.** The draft had four separate paths that raised the figure on inference:

- "Maybe cancelled?" removing a bill
- automatic transfer pairing
- a late debit settling the next occurrence
- moving an anchor later

Each is fixed below. Stating the rule once stops the fifth.

### 2. `maybe-cancelled-is-display-only` (blocking, departs from PLAN M5.F — see the open question)

"Maybe cancelled?" is a flag on the row and a line in the Overview disclosure. It does **not**
remove the bill from safe-to-spend or from the monthly total. The bill keeps counting until the
owner taps **Mark cancelled** (persisted) or **Still active** (clears the flag).

The lateness line must be visible in both places, because a cancelled bill that nobody flags is
subtracted once in every window forever: "Netflix hasn't charged since July 5. I'm still counting
it — tap Mark cancelled if you stopped paying for it."

The evidence gates in decision 4 still apply, because a false flag nudges the owner towards Mark
cancelled, which does raise the figure.

PLAN M5.F ("flagged items leave totals and safe-to-spend") and its acceptance line change
accordingly. M5.F appears in PLAN section 2, "Decisions I will make by default (veto at any
milestone review)". It is not a numbered owner decision, and rule 11, added a day later, puts
safety first.

**Why.** Absence of a charge has many causes. The bank may change the descriptor (B-11). The owner
may move the bill to another card. The merchant may bill late. A feed hole may be invisible to the
coverage fields (B-01). Or the charge may still be posting (B-02). If a $1,400 rent is flagged after
its descriptor changes, the headline is $1,400 too high. That is the overdraft direction.

### 3. `coverage-is-a-table-of-fetched-intervals` (blocking)

`tx_synced_through` (MAX) and `history_coverage_start` (MIN) cannot show a gap, so they stay for
the sync planner only.

v5 adds `tx_coverage(account_id, start_at, end_at, first_fetched_at, last_fetched_at)`, keyed on
`(account_id, start_at)` and `WITHOUT ROWID`. It works as follows:

- **Written:** in the same transaction and at the same code point as the `tx_synced_through` UPDATE
  in `ingestWindow`, which is already guarded (account present, not troubled, every amount read, no
  gen.auth, not capped).
- **Coalesced:** on write, so each account keeps a few non-overlapping rows.
- **Proof query:** "was [x, y) fetched with no gap?" is one indexed lookup,
  `start_at <= x AND end_at >= y`.
- **Evidence floor:** coverage is clipped at the evidence floor, the account's oldest live settled
  `effective_date`. A clean empty answer proves nothing about a period the institution does not
  serve.

None of the following writes a row: a balances-only answer, a budget pause, a failed or refused
window, an `act.*`/`con.*` error, a vanished account, or an unreadable amount. So none of them can
prove anything.

**Upgrade path:**

- Legacy scalars are **not** converted to intervals.
- v5 sets the history walk back to running, so real intervals are recorded within the existing
  6-window budget.
- The walk gets its own wording: "Rechecking your past spending so I can find bills — as far back as
  August so far."
- Until the intervals exist, the annual rule and the lateness flag say the period "hasn't been
  checked yet".

The "History goes back to" line reads only `tx_coverage`: "I've checked your Chase Checking back to
April 3." If there is an older island, it adds ", and some of January".

(B-01, B-03, B-29, cross-check 9)

### 4. `absence-needs-proof` (blocking)

These rules decide when an expected occurrence counts as missing:

- **Proven absent:** an occurrence expected on detection day E is proven absent only when all three
  hold:
  - one `tx_coverage` row covers the posted-instant span [E − tol − 1 day, E + tol + 5 days + 1 day)
  - no pending debit matches the series within tolerance
  - an account-wide search finds no debit, under **any** merchant key, within the tolerance window
    and within the series' band or a unique price step

  The account-wide search runs on the existing `(account_id, effective_date)` index.
- **A different name:** when an unlinked candidate is found, the row says "Possibly charged under a
  different name on September 3". It does not link until the owner confirms.
- **The flag:** "Maybe cancelled?" requires that the **two most recent** expected occurrences are
  both proven absent. For an annual bill it is one occurrence, with the span extended by 90 days.
- **Clock:** no rule reads the wall clock. Series on a dense key (decision 9) are never flagged.

When the merchant key comes from `payee`, also store `merchant_alt` = the normalized
`description`. A track may continue a series whose key equals its members' alternate key.

(B-02, B-11)

### 5. `invalidation-by-sql-triggers` (blocking)

The max-rowid cursor of PLAN M5.G is replaced by a durable queue,
`detection_dirty(account_id, merchant_key, enqueued_at, attempts, failed_at)`, keyed on
`(account_id, merchant_key)` and `WITHOUT ROWID`. `merchant_key = '*'` means the whole account, and
`'*coverage'` means re-evaluate lateness only.

The queue is fed by AFTER triggers created in v5:

- **bank_transaction insert:** enqueues the new key.
- **bank_transaction update:** enqueues the old and the new key when one of these columns changes:
  `account_id`, `posted`, `transacted_at`, `amount_cents`, `description`, `payee`, `memo`,
  `pending`, `merchant_normalized`, `superseded_by`, `voided_at`.
- **account update:** enqueues `'*'` when one of these columns changes: `amounts_reversed`,
  `user_type`, `currency`, `archived_at`, `replaced_by`, `holdings_count`, `guess_class`.
- **Manual recurring_charge update:** enqueues the old and new key when one of these owner columns
  changes: `statement_merchant`, `paying_account_id`, `cadence`, `amount_cents`, `status`.
- **tx_coverage insert:** enqueues `'*coverage'`.

Rules:

- **Change guard.** Every trigger has a `WHEN OLD.x IS NOT NEW.x OR …` guard. SQLite fires
  `UPDATE OF` even for unchanged values, and the known-ID UPDATE rewrites every row of every
  overlap. Without the guard every merchant is requeued daily.
- **Why triggers.** Hooks would miss the set-based age-out UPDATE in `reconcilePending`, and every
  direct INSERT in tests and fixtures.
- **Detector writes.** The detector writes only detector tables and detector-owned columns, none of
  which is in a trigger's column list. This makes "do not requeue detector-only link writes"
  structural.
- **Unused column.** `bank_transaction.recurring_charge_id` (v1) stays NULL and is documented as
  unused.

(B-06, cross-check 10)

### 6. `one-detection-worker` (blocking)

`actor DetectionWorker` is owned by `AppModel` next to the coordinator. Only one drain runs at a
time, as with `SyncCoordinator.sync`.

It drains at three points:

- at the end of every `SyncCoordinator.run` that wrote a window, including partial progress
- at startup, not awaited, and only if dirty work or an unfinished backfill exists (one indexed read
  on a clean launch)
- after owner actions that enqueue work

There is no timer and no retry loop. "It will try again" means the next pull, launch or owner
action, and the UI says so: "Bill detection couldn't finish. I'll try again after the next
refresh."

The worker processes keys in batches:

- **Batches:** each batch is one write transaction, closed after 25 keys or 50 ms of compute.
- **Per key:** read the bounded history, compute, write only the differences, then delete the dirty
  row. All of this happens in the same transaction.
- **Failures:** a throwing batch rolls back. Its keys are then retried one per transaction. A key
  that fails 3 times gets `failed_at` and is skipped until it is enqueued again.
- **No-op writes:** if nothing changed, nothing is written, so observers do not churn.

Launch must stay under 300 ms with 300 dirty keys queued.

(B-07, B-21)

### 7. `merchant-key-rules` (blocking)

Ingestion writes the key. `store` computes `MerchantKey.normalize(payee:description:memo:)` and
writes `merchant_normalized` and a new `normalizer_version` in all three statements: known-ID
UPDATE, content-adoption UPDATE, and INSERT.

**Backfill:**

- The worker runs it, never the migration.
- It uses a keyset cursor in `sync_state`: 500 rows per batch by id, updating only rows that differ.
- No clustering runs until the cursor has finished for the current version. Matching payments on
  existing series may continue.
- Bumping the version resets the cursor. Dismissals follow their keys (decision 11).

**Rules**, pinned by a table-driven test:

1. `payee` if non-empty after trimming, else `description`.
2. Unicode compatibility decomposition, then drop combining marks and non-ASCII. Uppercase with no
   locale (an az/tr locale must not produce `İ`). Replace everything outside `[A-Z0-9&./ ]` with a
   space.
3. Strip PLAN M5.A's processor prefixes at token 0 only, longest first, and repeat. If stripping a
   prefix leaves nothing, the prefix's own brand is the key: `AMZN Mktp US*2K4LQ09` becomes
   `AMZN MKTP`, and never merges with `AMAZON PRIME`. The same applies to `APL*` and `GOOGLE *`.
4. `APPLE.COM/BILL` becomes `APPLE`. A `.COM`/`.NET` tail and a `WWW.` head are dropped.
5. Remove reference tokens:
   - all digits and at least 3 long
   - `#`-led
   - `X{2,}\d+`
   - a run of 4 or more digits inside a token
   - MMDD and MM/DD

   Keep mixed tokens with at least 2 letters (`1PASSWORD`, `23ANDME`, `7ELEVEN`).
6. Drop the last token only, and only if it is a USPS state code outside
   {CO, IN, OR, ME, OK, HI, OH, LA, PA, DE, AL, MD}, or a code followed only by `US`/`USA`. Never
   guess city words.
7. Keep the first **three** significant tokens, plus any trailing product word from
   {PRIME, KINDLE, AUDIBLE, MUSIC, TV, PLUS, PREMIUM, VIDEO, STORAGE, ICLOUD, ONE}. The stopwords
   are {THE, OF, AND, &, INC, LLC, LTD, CO, CORP, COMPANY, USA, US, ONLINE, PAYMENT, PURCHASE}.
8. If the result is empty, use the first non-stopword token after prefix stripping. If that is also
   empty, the row gets a unique excluded key and never groups with anything.

(B-08, B-16, cross-check 8; reader B's two-token proposal rejected below)

### 8. `detection-day-and-index` (blocking)

v5 adds a virtual generated column `detect_at`:

- `transacted_at`, when it is positive, not after `posted`, and at most 10 days before it
- otherwise `posted` when it is positive
- otherwise `transacted_at` when it is positive
- otherwise NULL

It never uses `first_seen_at` or now. `SimpleFINIngest.effectiveDate` falls back to now, so a NULL
`detect_at` is how undated rows are kept out of cadence.

The index is `bank_transaction_detect ON bank_transaction(account_id, merchant_normalized,
detect_at) WHERE voided_at IS NULL AND superseded_by IS NULL`. Every detector query repeats that
predicate verbatim. A test asserts through EXPLAIN QUERY PLAN that the index is used and the
single-column merchant index is not.

Other date rules:

- **UTC days.** Evidence days are UTC calendar days from bank instants. They convert to a local
  `CalendarDay` by year, month and day, never by instant.
- **One basis per track.** If any member of a track lacks a valid transacted date, the whole track
  measures gaps on `posted`.

(B-13, B-23, B-24, B-25)

### 9. `bounded-per-key-algorithm` (blocking)

Each dirty key is recomputed from its whole bounded history, so incremental output equals full
output. The steps, inside the worker's transaction:

1. **Count.** Count live rows for (account, key) with `detect_at >= today − 430 days`, answered
   from the index. More than **400** makes the key dense: it abstains (below). Never `LIMIT` a
   larger set.
2. **Fetch.** Fetch those rows ordered by `detect_at, id`: id, amount, detect_at, pending, posted.
   Sign-correct with the account's `amounts_reversed` (a no-op for credit). Settled, dated debits
   enter clustering. Credits go to refund pairing. Pending rows go to payment matching only.
3. **Refunds.** Pair refunds one to one (decision 17).
4. **Amount tracks.** Build tracks greedily in date order:
   - A row joins the unique track with `|a − c|·100 ≤ 5·c`.
   - If two tracks qualify, it joins the one whose expected next day is nearest. A tie leaves the
     row ambiguous: it joins nothing, and every track it could have joined is capped at suggested.
   - A price step needs all of the following:
     - a track of at least 2 members
     - `75·c ≤ 100·a ≤ 150·c`
     - a day at least 0.75 of the track's median gap after its last member
     - exactly one such track
   - Prefer an existing same-price track over a step. A step applies only on settled debits.
5. **Cadence.** Fit a cadence using calendar-day gaps:
   - Windows: weekly [5,9], biweekly [12,16], monthly [26,35], quarterly [80,100], annual
     [340,395].
   - Fitting gaps f of n must satisfy `5·f ≥ 4·n`, so 2 to 4 gaps must all fit.
   - One gap of about double the cadence may count as a skipped occurrence. That skip is allowed
     only when the track has at least 3 gaps, and it is never used to choose between cadences.
   - The median is the lower middle of the gaps after halving the skip, `(g + 1) / 2`, and it must
     fit.
   - **Phase test:** before any weekly or biweekly reading, if members fall into at most two
     day-of-month clusters (±2 days) that each fit monthly, the result is two monthly tracks.
   - With fewer than 6 members and two possible readings, the track stays suggested.
6. **Status.** 2 members is suggested. 3 or more is confirmed by auto, unless the track is capped
   or suppressed. Status only moves forward (decision 12).
7. **Reconcile.** Match tracks to series (decision 10), write link differences and `detected_*`
   columns, and clear the key.

**A dense key:**

- creates no new series or links and changes no status
- keeps its existing confirmed series counted
- may settle an occurrence only through a targeted query that finds **exactly one** row in
  tolerance and band
- is never flagged "Maybe cancelled?"

The Bills screen says once: "I don't look for bills among places you pay very often, like AMZN
MKTP. If one of them is a bill, add it yourself."

(B-12, B-13, B-14, B-15)

### 10. `series-identity-is-the-row` (blocking)

A series is identified by its row id, never by anything derived from its data. `fingerprint` becomes
an opaque token (`s<id>`) written after insert. It is kept only because the v1 column and its
UNIQUE index exist.

Evidence lives in a new table:
`recurring_occurrence(transaction_id PRIMARY KEY, recurring_charge_id, occurrence_day, role,
linked_amount_cents, linked_by, created_at)`.

- **Roles:** `role` is `evidence`, `payment` or `pending_payment`.
- **Constraints:** the primary key means one transaction belongs to at most one series. A partial
  unique index on `(recurring_charge_id, occurrence_day) WHERE role IN
  ('payment','pending_payment')` means one occurrence is settled by at most one transaction.
- **Settled wins:** a settled link replaces a pending link for the same occurrence in the same
  transaction. The two are never kept side by side.
- **Deletion:** there is no ON DELETE CASCADE (decision 22).

A newly computed track matches an existing series in this order:

1. **Linked members.** If the track's members are already linked to exactly one series, the track
   continues it. If they are linked to two or more series, the result is ambiguous: keep the
   links, change no status, and leave new members unassigned.
2. **Lineage continuation.** If no member is linked, look for one existing series on the same
   account, key and cadence whose last linked occurrence is within 2 intervals before the track
   starts, and whose amount fits the band or a unique step. Exactly one candidate: continue it. Two
   or more: the new row is suggestion-only.

   To continue a **dismissed or cancelled** series, the track must also:
   - fall on the same day of the cycle, within tolerance
   - not overlap in time with that series' own charges
3. **Otherwise.** Check suppression (decision 11), then create a new series.

A newest-first backfill therefore cannot resurrect a dismissal. Two plans at the same price cannot
collide on the UNIQUE index.

(B-09, cross-check 7b)

### 11. `suppression-and-lineage` (blocking)

Dismissing or cancelling writes a row in
`detection_suppression(id, account_id, merchant_key, cadence, band_low_cents, band_high_cents,
charge_id, kind, created_at, undone_at)`. `kind` is `dismissed` or `cancelled`.

A new track is suppressed only when all three hold:

- an active suppression on the same (account, key, cadence) exists
- the track's current amount is within [low × 0.95, high × 1.05], compared as integers
- the track does not overlap in time with the suppressed series' own charges, since overlap proves
  the two are distinct

Then:

- **Dismissed:** the track attaches to the dismissed row and is never shown again. Dismiss means
  "this is not a bill".
- **Cancelled:** the row shows "Charged again after you marked it cancelled".
  - Only charges whose **transaction** day is after the cancel day plus tolerance count as "again".
    This stops the in-flight final charge from triggering the note.
  - Once three such occurrences exist, the row counts again, badged, following decision 4's rule.
- **Undo:** is immediate. It sets `undone_at`, restores the status and enqueues the key, all in one
  transaction.
- **Renormalization:** carries suppressions to the new key or keys that received the dismissed
  series' linked transactions, in the same batch.

A Debug listing, and later M9's management screen, shows what each dismissal is absorbing.

(B-10, cross-check 7a/7b)

### 12. `status-only-moves-forward` (blocking)

The detector never moves a series from confirmed to suggested, and never touches a dismissed or
cancelled row. This holds even when refunds, voids, rekeys or a horizon slide leave a confirmed
series with fewer than three live members.

The row keeps counting and says "The charges I found this bill from have changed — check it's still
right."

(A7, B-26)

### 13. `paid-through-is-computed-from-live-links` (blocking)

`next_expected_date` keeps its shipped meaning as the paid-through marker owned by the owner:

- set by the form and by Mark paid
- for a detected row, set once at creation to its anchor (satisfying M2 review §23)

The detector never advances it.

The **effective** marker is computed at query time by the pure engine. It is the later of:

- `next_expected_date`
- the occurrence after the latest **live** payment link

A payment link is live when all of the following hold:

- its role is `payment`
- its transaction is settled, not voided and not superseded
- its absolute amount still equals `linked_amount_cents`

So a void, a correction or a stuck drain lowers the marker at the next commit, and nothing waits on
the worker.

Owner controls on a detected or adopted row:

- **"Not this payment"** removes the link and writes
  `recurring_link_rejection(transaction_id, recurring_charge_id, created_at)` in one transaction.
  The detector never relinks a rejected pair.
- **Editing the due date or cadence** resets `next_expected_date` to the new due date in the same
  UPDATE.

Replay is idempotent. Evidence is "the occurrence after the latest live link", never "the stored
marker plus one". Mark paid after the debit has already linked therefore gives the same marker.

(A3, B-27's MAX-only rule rejected below, cross-check 2)

### 14. `settle-tolerance-and-anchor` (blocking)

A settled debit settles an occurrence only when it falls within tolerance of that occurrence.
Tolerance is `min(cap, floor(stepDays/2) − 1)` with these caps:

| Cadence | Cap (days) |
|---|---|
| Weekly | 2 |
| Biweekly | 5 |
| Monthly | 5 |
| Quarterly | 10 |
| Annual | 20 |

Outside tolerance the debit is evidence and moves no marker, so a late debit can never settle the
next occurrence and drop an unpaid one.

**Anchors:**

- **At creation:** when members fall on the 29th–31st and on the last day of a short month, the
  anchor day is the latest day of the month seen. Otherwise it is the most recent member's day.
- **Moving earlier:** automatic re-anchoring may only move the anchor earlier. It needs two
  consecutive debits outside tolerance, within ±2 days of each other in day of the cycle, and each
  within 40% of the interval of an occurrence.
- **Moving later:** this is a suggestion only: "Rent now seems to come out around the 12th. Change
  its due day?" Moving later would take a bill out of the until-payday window.
- **Owner overrides:** the owner's anchor override bit blocks all automatic re-anchoring.

(A4, A10, cross-check 5)

### 15. `payment-found-awaiting-balance` (blocking)

Balances come only from balances-only requests, and dated rows from dated ones (HANDOFF, "A request
carrying an end-date…"). A settled debit can therefore be newer than the counted balance.

A live payment link is withheld (still subtracted) while
`utcDay(min(balance_date, last_seen_in_sync_at)) <= utcDay(posted)`. Both sides are UTC. The
same-day case is ambiguous, so it is withheld, and the next refresh releases it.

- **Selection:** candidates are selected by posted recency
  (`effective_date >= balance_date − 2 days`), not by occurrence day, so a September 30 bill posting
  October 1 is not lost.
- **Emission:** each is emitted like `retainedObligation`, with `dueDay = max(postedDay, window
  start)` and a new treatment `paymentFoundAwaitingBalance`.
- **Wording:** "Payment found. I'll stop counting it once your bank's balance shows it."
- **Scope:** withholding applies only while the paying account is counted, as with the M2
  retention.

This supersedes the milestone 2 review §8 clause "a settled-transaction match (M5) never triggers
retention".

When the available balance is in use, a hold that settles is subtracted twice for up to a day. That
is the safe direction, and it is accepted.

(A5, cross-check 3)

### 16. `pending-suppression` (blocking)

A `pending_payment` link never moves any marker. At query time it removes exactly one occurrence,
and only when all of the following hold:

- the paying account is counted and its available balance is in use
- `min(balance_date, last_seen_in_sync_at) >= first_seen_at + 60 s` of the pending row
- the row is still pending, not voided and not superseded
- the match was unique: one same-account, same-key, in-band row within tolerance

The first run after a hold appears usually fails the time test, because balances are fetched
before the window that shows the hold. That is the safe direction. Do not "fix" it.

(A6, cross-check 4)

### 17. `refunds-one-to-one` (material)

Refunds keep the draft's rule. A credit pairs with a debit only when all of the following hold:

- same account and key
- the absolute amount is exactly equal
- the credit comes 0 to 30 days after the debit
- the debit is unpaired
- there is exactly one such candidate, walking credits oldest first

When pairing succeeds, the debit leaves clustering. When it is ambiguous or partial, nothing pairs
and every candidate stays as evidence. A late refund requeues through the insert trigger. Refund
pairing never re-opens an occurrence as unpaid, and never changes status (decision 12).

### 18. `transfers-need-an-owner-destination` (blocking)

Detection never writes `kind = transfer`. A transfer into a counted account is not subtracted, so
a false pairing would raise the figure.

Transfer-pairing evidence is a same-amount credit on another owned synced account within 3 days,
on at least 2 occurrences. It moves the row to a "Looks like a move between your accounts" section.
The row stays a subtracted bill until the owner confirms the destination, and it is excluded from
the **subscription monthly total**, since excluding it from a display total cannot raise the figure.

Keyword lists (AUTOPAY, ZELLE, …) are never evidence of a transfer (PLAN decision 3). ENGINE's
destination treatment is unchanged.

(A2, cross-check 6)

### 19. `accounts-that-are-not-spending-money` (material)

No new series is created on an account whose standing is `heldOut(.holdsInvestments)` or
`heldOut(.isALoan)`. The check uses `SafeToSpendEngine.classify`, not a second copy of rule 11.

Series that already exist when an account is reclassified keep their status (decision 12). The
engine already does not subtract them. They also leave the subscription monthly total, so a fund
purchase never reads as a monthly bill.

Non-USD series are detected, shown in their own currency, and excluded from USD totals.

(A8, cross-check 10)

### 20. `manual-adoption-and-same-bill` (material)

The manual form gains an optional field, "How does this show up on your statement?", stored as
`statement_merchant` (M2 review §22).

A detected track adopts into a manual row only when all of the following hold:

- the row's normalized statement merchant equals the track key or its alternate key
- same paying account and cadence
- the amount is within band
- the due day is within tolerance
- exactly one manual row qualifies

After adoption:

- The row keeps its name, amount, cadence, anchor and paid-through marker.
- Payment links may move its effective marker forward (decision 13).
- Detection never calls `markPaid` and never reduces a manual balance.

Anything short of that leaves both rows counted. The disclosure then offers **Same bill**, which
moves the links, suppresses the detected row and keeps the manual one, in one transaction, with
immediate Undo. Name similarity, or amount and date alone, never merge anything.

### 21. `owner-columns-and-revisions` (blocking)

v1's `amount_cents`, `cadence`, `paying_account_id` and `next_expected_date` stay the **effective**
values the engine reads.

v5 adds:

- detector-owned columns: `detected_amount_cents`, `detected_cadence`, `detected_anchor_date`,
  `detected_last_seen_day`, `detected_member_count`, `amount_changed_from_cents`
- `owner_overrides INTEGER NOT NULL DEFAULT 0`, a bitmask: amount 1, cadence 2, account 4,
  merchant 8, anchor 16
- `revision INTEGER NOT NULL DEFAULT 0`

The detector writes `detected_*` always, and copies a value into an effective column only when that
field's override bit is clear.

Every owner write goes through a named-column UPDATE guarded by revision:

- `updateBill(id:expectedRevision:edit:)` sends only the fields the owner changed and sets their
  override bits.
- `markPaid(id:expectedMarker:balanceAlreadyUpdated:)` applies only if the marker is still the one
  the owner saw.
- `setStatus(id:from:to:)` applies only if the status is still `from`.

On a mismatch the result is `.changedSinceOpened`. The form reloads and says "This bill changed
while you were editing. Check the details and save again."

(B-19, B-27)

### 22. `delete-is-for-manual-rows-only` (material)

Delete is offered only for `source = manual` rows with no occurrence links. Detected rows offer
Dismiss or Mark cancelled only.

`recurring_occurrence.recurring_charge_id` deliberately has no ON DELETE action. A delete that
would orphan evidence fails in the store with an owner message rather than silently dropping
lineage.

(B-20)

### 23. `schema-v5` (blocking)

v5 is one forward-only migration. v1–v4 are untouched. It contains:

- `tx_coverage`
- `detection_dirty`
- `recurring_occurrence`
- `recurring_link_rejection`
- `detection_suppression`
- `bank_transaction`: `normalizer_version`, `merchant_alt`, virtual `detect_at`, index
  `bank_transaction_detect`
- `recurring_charge`: the columns in decision 21, plus:
  - `statement_merchant`
  - `currency TEXT NOT NULL DEFAULT 'USD'`
  - `announced_at`
  - `inferred_inactive_since`
  - `inference_checked_through`
  - `still_active_through`
  - `transfer_evidence INTEGER NOT NULL DEFAULT 0`
  - virtual `monthly_cents`
- the triggers in decision 5, created after the columns they read
- setting the history walk back to running (decision 3)

A migration test runs `upTo: "v4"`, inserts M4-shaped rows, migrates, and asserts:

- every row survived
- `currency = 'USD'`
- no trigger fired for the migration's own writes

(B-28)

### 24. `monthly-total-in-sql` (blocking)

`monthly_cents` is a virtual column equal to `Cadence.monthlyEquivalentCents` for positive amounts:

| Cadence | `monthly_cents` |
|---|---|
| Weekly | `(amount_cents*52 + 6)/12` |
| Biweekly | `(amount_cents*26 + 6)/12` |
| Monthly | `amount_cents` |
| Quarterly | `(amount_cents + 1)/3` |
| Annual | `(amount_cents + 6)/12` |

13900 → 1158. A test checks SQL against Swift for every cadence over 10,000 positive amounts. The
detector writes positive magnitudes only.

The monthly total sums per-row rounded values:
`SUM(monthly_cents)` over `status = 'confirmed' AND kind <> 'transfer' AND transfer_evidence = 0
AND currency = 'USD'`, joined to account to drop:

- `holdings_count > 0`
- `guess_class IN ('investment','loan')`

A test asserts this predicate agrees with `classify`. Flagged "maybe cancelled" rows stay in the
total (decision 2). Suggested, dismissed and cancelled rows are out.

(B-17, B-28, cross-check 1)

### 25. `bills-screen` (material)

- **Paging:** SQL keyset pages of at most 50 rows in a `LazyVStack`, ordered by
  `monthly_cents DESC, id ASC`. Section predicates run in SQL. The lateness inference is the
  materialized, recomputable `inferred_inactive_since` that the worker writes on every drain and
  on `'*coverage'`. It is never an owner status.
- **Sections:**
  - confirmed bills and subscriptions
  - "These might be bills" (suggested)
  - yearly charges
  - maybe cancelled (still counted, decision 2)
  - looks like a move between your accounts
  - scheduled transfers
- **Each row states:** currency, cadence, paying account, next date, how it was found, and any price
  change ("went up from $9.99 to $10.99 in August").
- **Controls:** auto-confirmed rows carry an "Auto-detected — not right?" badge with Dismiss.
  Suggestions have Confirm and Dismiss. Flagged rows have Still active and Mark cancelled.
- **Notice:** "N new bills found" counts rows with `announced_at IS NULL`, stored in the database
  and cleared when Bills is viewed.
- **Stall notice:** "Bill detection hasn't seen new transactions since September 2" appears when the
  newest `tx_coverage.last_fetched_at` across counted accounts is more than 3 days old while
  balances are fresh. It never reads `transactions-pulled-at`.

### 26. `observation` (material)

`SpendableStore.Snapshot` adds two bounded queries, and nothing else from `bank_transaction`:

1. per charge, the latest live payment link's occurrence day (an aggregate)
2. live payment and pending-payment links whose transaction's `effective_date >= min(counted
   balance_date) − 2 days`, with `pending`, `posted`, `first_seen_at` and amount

Snapshot then refetches once per ingest commit, which is acceptable. The Bills list observes its
visible page and the SUM separately, outside Snapshot.

The engine gains a `payments` input and stays pure.

(B-18, cross-check 3b)

### 27. `shipped-defects-this-milestone-touches` (material)

- **B-05 (fixed in M5):** a row voided by age-out that the bank reports again under the same id is
  un-voided, whether pending or settled. The fix applies only when `voided_reason` is the age-out
  reason, and it lives in the known-ID UPDATE.
- **B-22 (fixed in M5):** the settled-row read in `reconcilePending` is bounded to the pending rows'
  date range ±10 days, on the existing index.
- **B-03 (superseded):** detection and the history line read only `tx_coverage`. The
  `history_coverage_start` behaviour is recorded but not changed.
- **B-04 (not fixed in M5; recorded for the owner):** `fetchTransactions` uses the minimum watermark
  over all accounts. One vanished or long-errored account can therefore stop every transaction pull
  after 44 days, silently, and the v5 re-walk ends in the same stall. M5 adds only the stall notice
  in decision 25. The planner fix changes request spending and needs its own reviewed change and
  tests.

### 28. `single-yearly-charge` (material)

A single charge is suggested, never counted, and labelled "Looks like a yearly charge — is it?"
only when all of the following hold:

- it is at least $20
- it is one settled debit
- one coalesced coverage interval, clipped at the evidence floor, contains it, spans at least 300
  days, and holds no other same-key or alternate-key settled debit
- its payee, description or memo carries ANNUAL, YEARLY, RENEWAL, MEMBERSHIP, PRIME, SUBSCR or
  ONE YEAR

Positive rows never qualify. The yearly section explains an empty list with the coverage line from
decision 3.

## Findings deliberately rejected

- **PLAN M5.F exclusion of flagged bills** — replaced by decision 2, pending the owner's answer
  below. It raises the figure on an inference from absence.
- **Automatic transfer pairing (draft: "an unambiguous paired debit/credit … establishes transfer
  identity")** — a same-day equal credit from someone else would make a Zelle rent vanish from the
  figure. Pairing is display evidence only (decision 18).
- **B-27's "detector writes next_expected_date only forward (MAX)"** — the owner could never move a
  wrong link's marker back, and a stale stored value raises the figure while a drain is stuck.
  Replaced by the live computation in decision 13.
- **B-16's two significant tokens** — `CITY OF SPRINGFIELD UTILITIES` and `… PARKING` would merge.
  Three tokens with an explicit stopword list, plus `merchant_alt` and the account-wide absence
  search, cover the split case. A split double-subtracts, which is safe. A merge is not.
- **A4's flat ±5-day tolerance** — an annual renewal 12 days late would never settle. Replaced by
  the per-cadence caps in decision 14.
- **Seeding `tx_coverage` from `tx_synced_through`/`history_coverage_start`** — these scalars
  cannot show a gap and overstate empty windows (B-01, B-03). Re-walk instead.
- **Delete-all/insert-all of links on each drain** — it churns observation and loses owner-made
  links. Write set differences only (decision 6).

## Test cases

All synthetic. None may use real data.

1. **Normalization table** (decision 7): SQ \*BLUE BOTTLE, PAYPAL \*SPOTIFY, TST\*, Netflix.com vs
   NETFLIX.COM, APPLE.COM/BILL, AMZN Mktp US\*2K4LQ09 → AMZN MKTP, Amazon Prime, 1PASSWORD, 23ANDME,
   7-ELEVEN, CITY OF SPRINGFIELD UTILITIES vs PARKING, SPOTIFY USA NEW YORK NY, "… CO", Turkish-locale
   uppercasing, SQ \*PAYPAL \*X.
2. **Apple at 2.99 and 9.99:** two monthly series, never one.
3. **Two 0.99 plans charged on the 3rd and 19th:** two monthly series, no UNIQUE violation, no
   biweekly series. Then cancel one: the other stays monthly.
4. **Spotify 9.99 → 10.99:** one series, `amount_changed_from_cents` 999, the price-change sentence.
5. **Gym with a skipped month, and a biweekly gym.** Also the gap sets {30, 58} passes,
   {30, 60, 31} passes, and {30, 31, 29, 45} fails.
6. **"Pay day!" positive series:** never detected.
7. **Refunds:** one-to-one full refund; two equal debits with one credit (nothing pairs); a partial
   refund; a late refund requeues.
8. **Old-row correction below any cursor:** an amount corrected on a year-old row, a rekey, and
   payee arriving later all move the row between keys and enqueue both keys.
9. **Identical overlap re-ingest:** zero rows enqueued. The bulk age-out void enqueues. A direct
   INSERT enqueues. Toggling `amounts_reversed` expands `'*'`.
10. **Voided hold returns settled under the same id:** un-voided, joins the series (B-05).
11. **Partial first sync:** windows 1–6, dismiss, then windows 7–11 with older lower prices. No new
    row, no status change.
12. **Dismissed Apple 9.99 ends, then Apple 12.99 starts:** a new suggested row, not absorbed. The
    same starting while 9.99 still runs: also a new row.
13. **Cancelled Sep 20:** a Sep 18 charge posting Sep 21 is not "charged again". Three charges
    transacted after Sep 25 count again, badged.
14. **Payee appears mid-history on a utility:** no flag, "possibly charged under a different name",
    still counted.
15. **Weekly gym, one missed charge, the next still posting:** not flagged until the posting-lag
    margin passes. Flagged after two proven-absent occurrences, and still subtracted.
16. **Maybe cancelled then Still active:** the flag clears and the figure is unchanged throughout.
    Mark cancelled raises the figure by exactly one occurrence.
17. **Account absent from one backfill window:** the annual rule refuses, and the coverage line shows
    the gap.
18. **90-day institution with empty older windows:** coverage is clipped at the evidence floor.
19. **Payment found while the balance is older than the posting day** (UTC+4 and UTC−7 variants):
    withheld with the new sentence, and released by the next balance. A September 30 bill posting
    October 1 stays withheld across the month boundary.
20. **Pending match on an available-balance account:** suppresses one occurrence only after a
    later balance. Void, supersession, account reclassification and a plain-balance account each
    restore it. A settled link replaces the pending link.
21. **Settled payment later voided, and an amount corrected out of band:** the effective marker
    steps back at the next commit with the worker disabled.
22. **"Not this payment":** the marker steps back and the pair is never relinked.
23. **Replay idempotence:** replay the same pull three times, Mark paid, replay again. The markers
    are identical.
24. **Rent paid late twice (5th → 12th):** no automatic later anchor, a suggestion instead, and the
    until-payday figure unchanged. An annual renewal 12 days late settles.
25. **Manual rent with statement merchant:** adopts, keeps the owner's name, amount and marker, and
    never reduces a manual balance. Without the field: both counted, then Same bill with Undo.
26. **Detected transfer-shaped series:** subtracted, excluded from the subscription total, and
    subtracted until the owner sets a destination. Then ENGINE's destination treatment applies.
27. **Fund purchases on an account with holdings:** no series. Reclassifying an account with series
    removes them from the monthly total without changing their status.
28. **Stale form against the detector:** stale save, stale Mark paid and dismiss-versus-save each
    return `.changedSinceOpened`. Delete is refused on a detected row.
29. **Bounded work:**
    - a dense key of 401 rows creates nothing and settles only on a unique match
    - full versus incremental output is byte-equal under shuffled enqueue order
    - EXPLAIN QUERY PLAN uses `bank_transaction_detect`
    - a poison key is quarantined after 3 attempts while the other keys drain
30. **Totals:**
    - SQL `monthly_cents` equals Swift
    - 13900 yearly contributes 1158
    - the total is independent of loaded pages
    - confirming a suggestion changes Overview immediately
    - v4 → v5 migration preserves every row

## Open question for the owner

**Should a bill that looks cancelled stop counting on its own?** Your plan (M5.F) says a detected
bill that has not charged for two cycles is flagged "Maybe cancelled?" *and* leaves safe-to-spend
and the monthly total. This review keeps it counted until you tap **Mark cancelled**, and shows the
flag and a sentence instead (decision 2).

The trade-off in one example:

- **Review's rule:** a cancelled $15 Netflix keeps $15 held back each month until you tap the
  button.
- **Plan's rule:** a $1,400 rent whose bank description changed could disappear from the number
  without you doing anything.

Everything is built the review's way unless you say otherwise. Switching back is one predicate in
the total and one in the engine.
