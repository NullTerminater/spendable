# Milestone 5 continuation handoff

Updated 28 September 2026. Read this first, then HANDOFF.md and the contracts below.

**Update, later on 28 September.** Resume step 2 is done:

- Two independent readers attacked DETECTION.md, and one of them cross-checked the other.
- All eight areas below are adjudicated in `docs/reviews/milestone-5-review.md`: 28 decisions,
  7 rejections, 30 test cases, and 1 open owner question ("maybe cancelled" keeps counting).
- DETECTION.md was rewritten to match. Where the text below calls DETECTION.md an unreviewed draft,
  or lists the eight areas as unresolved, it is historical.
- The handoff documents are committed. The Mac working-clone paths below held no unique work and
  can be ignored.
- The review ran without Xcode. Nothing was built, tested or measured.

**Update, end of 28 September.** Step 3 was done without a compiler: 11 commits on branch
`main-sii1hq`, ending with the code-review fixes. The implementation addendum in the review lists
the known gaps. Steps 4–5 (build, test, synthetic acceptance, measurements, tag) remain, and all of
them run on the owner's Mac. HANDOFF.md says exactly what to run.

## Exact state

- **M1–M4 are implemented. M5 has a draft contract only.** No M5 application code, migration,
  tests, benchmarks, commits or tag exist. Do not describe DETECTION.md as implemented or approved.
- The owner ran the M4 app, quit/reopened it and reported: **“so far so good. I quit and opened
  again, info survives.”** They then explicitly said **“You can proceed”** after M5 was identified
  as the next milestone. M5 is authorized; do not ask again merely to start it.
- Do not infer that the owner specifically corrected an account type, measured first-sync memory,
  or reviewed M5. Those have not been reported. Stop before M6 until the owner sees M5 run.
- Latest request is this handoff. Implementation paused for transfer to another AI.
- **Maximum three agents total, including the lead.** Two assistants completed independent
  code/plan surveys. Independent reviews of the subsequent DETECTION.md draft did **not** finish.
  Their survey findings are preserved below. Do not wait for old agents to complete the review.

## Checkouts and delivery

Normal project, delivery location and real app:

```text
/Users/javidanaghayev/Developer/spendable
/Users/javidanaghayev/Developer/spendable/docs
/Users/javidanaghayev/Developer/spendable/DerivedData/Build/Products/Debug/Spendable.app
```

Persistent M5 working clone:

```text
/Users/javidanaghayev/Documents/Codex/2026-09-15/users-javidanaghayev-developer-spendable-docs/work/spendable-m5
```

Both checkouts were verified on `main` at
`bb2b9bb66007131b5c53d1cc4530761151a0fd2b` before saving these handoff documents. Normal checkout
was clean; M5 clone contained only untracked `docs/DETECTION.md`. This handoff operation adds
`docs/MILESTONE-5-HANDOFF.md`, copies the draft to the normal docs folder and updates `docs/HANDOFF.md`
in both locations. These documentation changes are **uncommitted**. No source changes are hidden
in another M5 branch. Recheck status before editing or merging.

- Normal origin: `git@github.com:NullTerminater/spendable.git`.
- **M5 clone origin is the local normal checkout**, not GitHub. Do not push its branch into the
  normal checkout's checked-out `main`. Commit work, then fetch/fast-forward into the normal
  checkout after checking for owner changes; push from there.
- Existing annotated tags: `v0.1-skeleton`, `v0.2-engine`, `v0.3-simplefin`, `v0.4-connected`.
  M4 main/tag were previously pushed and remote access/privacy checked (SSH works; unauthenticated
  repository API returns 404). This was not rechecked during the handoff.
- Ignore the older `work/spendable-final` clone for M5. Keep source/commits persistent: a previous
  `/private/tmp` working copy disappeared during a pause and had to be reconstructed.

## Read order and authority

1. `CLAUDE.md` — hard privacy, build, arithmetic, paging and process rules.
2. `docs/HANDOFF.md` — shipped behavior, historical measurements and machine pitfalls.
3. `docs/PLAN.md` — **numbered owner decisions bind every other document**; M5 is the scope.
4. `docs/ENGINE.md` and `docs/reviews/milestone-2-review.md` — obligations, paid markers,
   pending/settled matching, manual duplicate handling and transfer arithmetic.
5. `docs/SYNC.md`, relevant M3 review and `SimpleFINIngest.swift` — actual ingestion/coverage.
6. `docs/DETECTION.md` — 150-line **unreviewed draft**, written 21 September, retained verbatim.
7. `docs/CONNECTING.md`, M4 review, README as needed. CONNECTING is now implemented for M4;
   the old warning that all M4 wording was merely intended is historical, not current state.

Required process: write contract → several independent readers attack it → adjudicate findings
and record decisions → implement. The first step exists; the draft-specific review is unfinished.
There is no M5 review document yet. Do not substitute the earlier surveys for review of the draft.

## What M5 must deliver

- Normalize merchants at ingestion and backfill; settled debit recurrence only. Positive and
  pending rows still need normalized identities for refunds/payment matching.
- Cadences: weekly 5–9 days, biweekly 12–16, monthly 26–35, quarterly 80–100, annual 340–395.
  Transaction date precedes posted date for detection; current `effective_date` prefers posted.
  At least 80% of gaps fit, median fits, one doubled interval may represent a skipped payment.
- Two occurrences suggest without counting; three auto-confirm and count with visible badge,
  Dismiss and unread “N new bills found” notice. Stable suppression survives reruns/price changes.
- Current-price ±5% band; a unique sequential -25%/+50% price step after at least 0.75 interval
  continues the series. Separate overlapping Apple subscriptions remain separate.
- Single annual charge: >=$20, >=300 days credible coverage, no other same-merchant debit,
  annual/renewal/membership/Prime keyword evidence; suggest only. Show history coverage.
- Manual bill adoption without duplicate subtraction; safe bank-payment association; transfers
  separate; query-time lateness/cancellation handling; confirm/dismiss/cancel/still-active controls.
- SQL-paged `LazyVStack`, monthly-cost sorting, total independent of loaded pages. Sum per-row
  rounded Int64 cents: weekly 52/12, biweekly 26/12, monthly 1, quarterly 1/3, annual 1/12;
  $139/year contributes $11.58/month. Suggestions and transfers excluded from that total.
- Full synthetic acceptance, regression tests and measured M5 performance; annotated
  `v0.5-detection`, README/HANDOFF updated, normal checkout delivered and private remote pushed.

## Survey findings and unresolved review decisions

**1. Transfer rule is resolved by binding owner decision 3.** PLAN M5.D's keyword shortcut and
blanket safe-to-spend exclusion are stale. AUTOPAY/ZELLE/VENMO/ACH PMT/TRANSFER alone do not prove
money went to an owned account. Verizon autopay and Zelle rent remain bills. ENGINE excludes
counted-to-counted transfers but still subtracts transfers into excluded savings/cards. Preserve
that behavior. Draft proposes owner-confirmed destinations or unambiguous owned-account pairs;
the proof required for automatic pairing still needs review.

**2. “Maybe cancelled” remains disputed.** PLAN M5.F explicitly removes flagged items from totals
and safe-to-spend. One survey recommends retaining confirmed bills until explicit cancellation.
The lead's draft retains the requested M5.F exclusion, strengthens reliable-coverage gates and
calls it a reversible forecast inference. This is a proposed adjudication, **not an owner-approved
new rule or completed independent review**. Resolve against authoritative documents; if a genuine
owner decision is required, ask about this specific arithmetic change, not permission to do M5.

**3. Coverage is not established by two dates.** `ingestWindow` sets `tx_synced_through` using MAX
and `history_coverage_start` using MIN after successful per-account windows. Those fields alone
cannot prove continuous coverage between the endpoints. The draft demands no gaps for cancellation
and annual inference but does not yet specify storage/algorithm that proves that. Review and define
it before implementation. Fresh balances after a failed/budget-paused transaction pull must not
erase a bill. Use bank evidence dates, not wall clock, and account for errors/vanished accounts.

**4. Max-rowid checkpoint is inadequate.** Existing-ID corrections, content-based rekeying,
pending→settled, supersessions and voids mutate old rows. Draft replaces the plan's cursor with
durable dirty account+merchant work, enqueued atomically for old and new identities. Queue clearing
and detection writes must commit together. Changes to sign/type/manual evidence also invalidate
work. SQL triggers versus explicit ingestion hooks, schema and exact APIs are **not chosen**.

**5. Paid-through markers are money, not display dates.** `next_expected_date` means everything
before it has been paid. Pending rows must never advance it permanently. Suppress one uniquely
matched occurrence only while the classifier actually uses available balance; disappearance,
voiding or reclassification reverses suppression. Bank matches must not call manual `markPaid`
(which can reduce a manual balance). One transaction settles at most one occurrence. Settled
payments newer than the counted balance need withholding until the balance catches up; do not
mislabel that as an owner action. Association schema and engine inputs remain to be designed.

**6. Stable identity and owner control need explicit ownership.** Dismissed/cancelled fingerprints
cannot depend on the latest amount or a price increase resurrects Spotify. Retain lineage and
links; keep parallel subscriptions distinct. Manual adoption requires one explicit statement
merchant + account/cadence/amount/date match, preserves owner corrections and paid-through state.
Approximate amount/date alone cannot silently merge (M2 review §22). Draft proposes Same bill
and immediate Undo; exact merge/suppression behavior still needs review.

**7. Refunds are one-to-one.** Same account/merchant, exact opposite amount within 30 days;
ambiguous/partial refunds cannot erase multiple debits. Late credits must requeue old evidence.

**8. Bounded processing is mandatory.** Never load the transaction table. Stream or use SQL
aggregates and bounded merchant history; define an explicit abstention behavior for dense merchants.
Do not silently truncate enough history to manufacture confidence. Require an indexed query plan.
The draft has no final per-merchant bound or concrete clustering algorithm yet.

## Code map for implementation

Paths below are relative to the chosen repo checkout.

| Area | File and important behavior |
|---|---|
| Schema | `Sources/Spendable/Storage/AppDatabase.swift`: migrations v1–v4 shipped; add forward-only v5. Existing tables already have merchant, recurring links and fingerprints. |
| Bill model | `Storage/RecurringCharge.swift`: Int64 cents, source/kind/status/confirmedBy, anchor, next marker, destination, last seen/change/fingerprint, manual-paid retention. Preserve month-end anchoring. |
| Ingestion | `SimpleFIN/SimpleFINIngest.swift`: `store` has known-ID UPDATE, content-adoption UPDATE, INSERT; `reconcilePending` mutates superseded/voided rows; `ingestWindow` updates coverage. All need correct invalidation. |
| Sync | `SimpleFIN/SyncCoordinator.swift`: `run` awaits `fetchTransactions`; drain detection afterward even with partial progress, without another request. |
| Startup | `App/AppModel.swift`: database opening already detached; sole coordinator/scheduler owner. Recover queued detection work without blocking the main actor. |
| Observation | `App/SpendableStore.swift`: Snapshot currently reads accounts, all recurring rows, pay schedule and sync state, **not transactions**. New payment evidence needs observation dependencies. |
| Mutation races | `SpendableStore.save`/`markPaid` write captured whole rows. Fetch fresh state inside the write and update owned fields so an old form cannot erase a new detection/payment. Sign changes/account merges need invalidation. |
| Engine | `Engine/SafeToSpend.swift`: pure compute, classification, `treatment`, `retainedObligation`, `heldBackBills`; no transaction input yet. Keep headline/disclosure/held-back arithmetic consistent. |
| Bills UI | `UI/BillsView.swift`: currently unpaged `List`, in-memory sorting, confirmed total includes transfers. Contains BillForm/MarkPaidForm. No statement-merchant field, detection actions or notice yet. |
| Debug | `App/DebugLaunchOptions.swift` and Debug fixture code in `AppModel.swift`; extend with synthetic-only M5 fixtures/benchmarks. |

A metadata side table versus extra recurring columns, occurrence association schema and cross-file
APIs were discussed but **not decided or implemented**. Agree them before splitting coding work.
Suggested division: one agent detector/schema/core tests, another Bills/store/paging tests, lead
sync/engine integration/fixtures/validation. Avoid overlapping file ownership.

## Privacy, build and verification constraints

- Never read real Keychain credentials or the real database from CLI. Never put real bank data,
  tokens, credential URLs, balances or history into files/logs/screenshots/profiles. Synthetic only.
- The owner may have the real app running. **Do not use global `pkill Spendable`, inspect its UI,
  or assume an old PID is valid.** Target a verified synthetic process/container for tests/profiling.
  Existing measurement scripts use broad pkill: do not run them unchanged alongside the real app.
- Money is Int64 cents; no floating-point money, no Decimal outside display formatting. No new
  dependency without owner approval. GRDB pinned at 7.11.1. One scheduler, no view timers.
- Use `xcodebuild`/`xcrun`; bare `swift` is a broken shim. Xcode project is generated via
  `scripts/bootstrap.sh`; edit `project.yml`, never pbxproj. Always `-derivedDataPath DerivedData`.
- Personal Team `UW2KV7XB66`, automatic signing and `-allowProvisioningUpdates` already authorized.
  Owner accepted Xcode license on 21 September; a fresh build/test passed afterward.
- Documents/FileProvider builds can gain FinderInfo xattrs and fail signing. Validate in the normal
  checkout or a temporary build copy copied without xattrs; keep source in the persistent clone.
- Profiles/xcresults/memgraphs belong under
  `/Users/javidanaghayev/Library/Application Support/Spendable-profiles/`, never repo.
- Tests use in-memory GRDB, synthetic fixtures, isolated credentials. Hooks are enabled in M5
  clone (`core.hooksPath=.githooks`); never bypass hooks, force-add ignored files or weaken ignores.
- Current sandbox permits writes in the projectless workspace, not arbitrary original-repo writes.
  Use the tool's normal permission escalation when necessary; authorization for M5 already exists.

Last completed validation is **M4**, not M5: 238 tests/26 suites passed on 21 September; signed
Debug build and strict signature verification passed. Warm launch 165 ms, idle 17.5 MB, window
32.8–33.5 MB, zero leaks after five cycles. Synthetic year: 5,984 rows/11 windows, 203 KB live-heap
growth. The older 60-minute idle profile used the pre-receipt-fix revision; README states limits.
Real-first-sync footprint remains unmeasured. No build/test was run for this draft-only M5 work.

M5 requires: full detection over 6,000 synthetic settled rows (wall time and peak footprint delta),
30-row incremental pass (time and indexed EXPLAIN QUERY PLAN), 300-row paged Bills scrolling
(Time Profiler main-thread/frame evidence and bottom footprint), idle comparison and leaks. Test
all contract cases, notably old-row mutation, refund ambiguity, price/dismissal lineage, manual
adoption, pending reversal, stale balances, coverage holes and immediate total updates.

## Resume sequence

1. Check both Git states; keep these uncommitted docs. Choose the persistent M5 clone or explicitly
   continue in the normal checkout. Do not accidentally overwrite unrelated work.
2. Have two independent readers review DETECTION.md. Resolve the eight areas above, choose schema,
   bounded algorithm and APIs, and record an M5 review document. Update the draft accordingly.
3. Implement and test M5 in coherent commits; keep documentation claims aligned with actual code.
4. Build and exercise synthetic UI; gather required measurements without touching the real app.
5. Deliver to the normal checkout; update README/HANDOFF with exact results/limitations; annotate
   `v0.5-detection`, verify remote privacy/access and push. Show the owner M5 and stop before M6.
