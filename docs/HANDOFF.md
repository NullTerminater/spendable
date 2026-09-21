# Where this project is

Updated 21 September 2026 after implementing and validating milestone 4. Read `docs/PLAN.md` for the
owner's decisions, `docs/CONNECTING.md` for the implemented connection contract, and
`docs/reviews/milestone-4-review.md` for its original review. The owner's new rule 13
explicitly permits safe repair of rejected credentials in this milestone.

## State at a glance

| Milestone | State | Tag |
|---|---|---|
| 1. Skeleton, signing, schema, manual accounts, window | Done, owner reviewed | `v0.1-skeleton` |
| 2. Engine, disclosure, pay schedule, manual bills | Done, owner reviewed | `v0.2-engine` |
| 3. SimpleFIN client, Keychain, budgeted sync | Done, owner reviewed | `v0.3-simplefin` |
| 4. Setup, account corrections, connection repair, scheduler | Implemented; validation below; owner acceptance pending | `v0.4-connected` |
| 5–9. Detection, cards, menu number, widget, settings | Not started | — |

Do not start milestone 5 until the owner has run and reviewed milestone 4.

## What milestone 4 now contains

- Migration v4 adds exactly the six reviewed account columns. Insert-only guesses retain their
  original name; dated holdings evidence gates guessed spending accounts. Loans and investments
  remain outside spendable money, with no ineffective opt-in control.
- Setup uses a masked field, explicit Show/Paste, character count, clearing and undo-buffer removal.
  A claimed credential stays in `AppModel` until Keychain verification succeeds. Retry never claims
  twice; quitting with an unsaved claim warns first. Locked Keychain and rejected credentials have
  different banners and remedies.
- Previously rejected connections can be repaired. Sync pauses around replacement; the old
  encrypted credential remains active through candidate read-back, then one atomic Keychain update
  promotes the verified candidate. The request budget survives replacement. History restarts while
  stored accounts, corrections and bills remain. A newly claimed credential rejected immediately
  prompts a retry/diagnostic first; a deliberate replacement requires the in-app warning. An opaque
  receipt stored with the encrypted credential lets startup/setup finish database bookkeeping after
  a crash between Keychain promotion and the database commit, without another token or request.
- `AppModel` owns the sole coordinator and scheduler. Launch, wake, local day change, Refresh and
  scheduled activity use it. The activity repeats every six hours with one hour of tolerance;
  five-hour automatic and six-hour launch gates remain separate. Completion runs exactly once.
- Rows explain guesses, missing holdings evidence, connection errors, stale/vanished/returned
  accounts, non-USD balances, and excluded savings. Confirmation explains the available-balance
  change. Duplicate questions count one side; accepting carries owner corrections and bill links
  across atomically. Archiving previews the arithmetic and continues subtracting unpaid bills.
- History progress reports a covered date and distinguishes bank exhaustion, the thirteen-month
  app limit, budget pauses and failures. A new account forces a dated fetch in the same run.
- `sync_state` is `WITHOUT ROWID`: `SyncState.set/clear` explicitly notify GRDB observations.
  Without this, history progress and confirmation-message expiry silently stop updating.

## Verification

The final suite passes **238 tests in 26 suites** in the normal checkout on 21 September.
Its signed Debug build succeeds and strict signature verification passes. The synthetic year test stores 5,984 rows in eleven windows with **203 KB** live-heap
growth. Native synthetic checks exercised secure paste, invalid-token clearing and undo removal,
duplicate acceptance, archive arithmetic, locked-Keychain retry, first-rejection replacement
confirmation, and the unsaved-claim quit warning (including retention after the window closes).
A real setup token has not been used by the builder; no real account contents were inspected or
captured. The 16 September idle check completed: 14.9 → 15.1 MB, 0.0% sampled CPU,
180 ms additional CPU time, and one logged sync attempt spending zero requests. This profile used
`2759b59`, before the final receipt fix; launch/window/full-leak measurements were repeated on the
21 September receipt build: 165 ms warm launch, 17.5 MB idle, at most 33.5 MB with the window,
and zero leaks after five open/close cycles.
See README for the measurement dates, revision boundaries and sampling limits.

Build from the normal checkout:

```bash
scripts/bootstrap.sh
xcodebuild -project Spendable.xcodeproj -scheme Spendable -configuration Debug -derivedDataPath DerivedData -allowProvisioningUpdates build
xcodebuild -project Spendable.xcodeproj -scheme Spendable -destination 'platform=macOS' -derivedDataPath DerivedData test
```

`-derivedDataPath DerivedData` is required by the measurement scripts. Raw test results and profiles
belong under `~/Library/Application Support/Spendable-profiles/`, never in the repository.

Synthetic UI replay, with no real credential or data:

```bash
open -n --env SPENDABLE_DEBUG_CONTAINER=/tmp/spendable-m4-review --env SPENDABLE_DEBUG_FIXTURE=accounts --env SPENDABLE_DEBUG_SCREEN=accounts --env SPENDABLE_DEBUG_OPEN_WINDOW=1 DerivedData/Build/Products/Debug/Spendable.app
```

Use a different empty scratch folder for each replay. `SPENDABLE_DEBUG_FIXTURE` uses an in-memory
credential store. Other fixture names are documented in `docs/CONNECTING.md`. These are Debug
environment switches; there is no Debug > Replay fixture menu and no lowered-budget UI.

## Owner acceptance still needed

Open the normal app, choose **Connect your bank**, and paste a real setup token directly there,
never into chat. Review account guesses, correct one, then relaunch and check it persisted. The
builder's synthetic checks do not substitute for bank-specific behavior or the first Keychain
consent dialog. Real-first-sync footprint remains unmeasured until that owner-run flow; report
only the footprint number, never account contents. Replacing a working connection stays in
milestone 9. Its disconnect implementation must clear `credential-generation-applied` alongside
connection metadata, so an intentional deletion cannot look like missing tracked credentials.

## Earlier measurements

| Milestone | Warm launch | Idle footprint | With window | Leaks |
|---|---|---|---|---|
| 1 | 200 ms | 14.3 MB | 21.7–22.4 MB | 0 |
| 2 | 153 ms | 14.5 MB | 26.0–26.9 MB | 0 |
| 3 | 161 ms | 14.8 MB | 26.4–27.2 MB | 0 |

See `README.md` for the latest measurements and definitions. Milestone 3's engine benchmark was
4.3 ms on 40 accounts and 120 bills; its synthetic year test stored 5,984 rows across 11 windows
with 229 KB live-heap growth.

---

# Things that cost real time to discover

Do not rediscover these.

## macOS and this machine

- **`NSHostingView` as a window's content view resizes the window.** Used directly as `contentView`,
  or through `NSHostingController` as `contentViewController`, SwiftUI resizes the window to the
  content's ideal size after every layout, silently, whatever `sizingOptions` says — a loading
  spinner shrank the window to 151×53 and undid the user's own resizing within 100 ms. Fix: put the
  hosting view inside a plain `NSView` container pinned by constraints, set the window's minimum in
  AppKit, and use an `NSToolbar` rather than SwiftUI's `.toolbar`. **Reuse this for Settings in
  milestone 9.**
- **`URL.user()` and `URL.password()` return percent-encoded values**, despite the documented
  default. Use `URLComponents.user` / `.password`. This would have stored a wrong password, verified
  it against itself, and spent the owner's single-use token finding out.
- **Signing** works on the free Personal Team `UW2KV7XB66` with a Team-ID-style App Group
  (`UW2KV7XB66.spendable`) and the file-based login keychain. No provisioning profile is involved.
- **`osascript` has no assistive access here.** Native computer-use tooling can operate the
  synthetic app; shell-driven verification uses the Debug-only environment variables: `SPENDABLE_DEBUG_CONTAINER`, `_SCREEN`,
  `_FIGURE`, `_SEED_SAMPLE`, `_OPEN_WINDOW`, `_MEMORY_CYCLE`, `_ENGINE_BENCH`, `_CONNECT_DEMO`, `_FIXTURE`.
- **`log show` returns nothing for this app from a shell.** Measurements are read from
  `<container>/measurements.log` instead. Screen Recording is granted, so
  `screencapture -x -o -l <windowID>` works; there is a small `listwindows` helper pattern in the
  session notes for finding the window id via `CGWindowListCopyWindowInfo`.
- **The pre-commit hook rightly rejects credential-shaped literals in test files.** Build such URLs
  at runtime with `URLComponents` rather than weakening the hook. There is also a `commit-msg` hook.

- **Build outside File Provider folders.** The projectless Documents scratch copy gained FinderInfo
  metadata on the widget bundle and code signing refused it. Validation moved to a local `/private/tmp`
  checkout copied without extended attributes. The normal `~/Developer/spendable` checkout remains
  the delivery location; the temporary copy is only a validation workspace.

- **Keep committed source in a persistent checkout.** `/private/tmp` was cleared during a paused
  session, after its final receipt fix had passed tests but before delivery. The fix and final docs
  were restored from the session into a persistent working copy and revalidated in the normal checkout. Temporary folders
  are for build/measurement copies; preserve commits in the normal checkout before pausing.

## SimpleFIN, verified against the live server

- **A request carrying an `end-date` is answered with the balance as of that date.** Balances come
  only from `version=2&balances-only=1`, which carries no dates.
- **A balances-only answer returns `transactions: []` for every account**, indistinguishable from
  "this account had no transactions". The request kind must travel with the response, or routine
  refreshes will void live pending charges and march watermarks over unfetched days.
- **`INSERT OR REPLACE` on `account` cascades away the owner's whole transaction history.** Use a
  named-column `ON CONFLICT … DO UPDATE`.
- **`gen.api` "may be capped" is advice; "was capped" is a hole in the data.** Tell them apart by
  tense, or good responses get thrown away.
- **Transaction ids are not stable.** Unique within an account, never promised stable between
  answers. The public demo fabricates fresh ids *and* amounts on every request, so it cannot verify
  deduplication either way.
- **The quota is 24 requests a day and the token is disabled past it**, which would cost the owner a
  hand-made setup token. The app's own budget is a rolling 24 hours, not a calendar day.

## The practice that has been worth the most

Write the contract as a document first, have it attacked by several independent readers, then
implement. It found 42 problems in milestone 2's engine design, 40 in milestone 3's sync design, and
in milestone 4's design 27 decisions and 8 rejections — including, in each case, at least one rule
that would have silently produced a wrong number about the owner's money. `docs/ENGINE.md`,
`docs/SYNC.md` and `docs/CONNECTING.md` are those contracts; `docs/reviews/` holds what came back.

The same practice run over the **documents** on 16 September, checking every factual claim against
the shipped code, returned 105 findings and seven real code defects — among them a shortfall
sentence printed on payday morning, a transaction amount silently dropped while its watermark
advanced past it, and a keychain error that told the owner to retry a read when a write had failed.
A document that contradicts the code is worse than a missing one, because it will be believed. It is
worth re-running before each tag.

Do the same for milestone 5 (subscription detection) and milestone 6 (credit cards). Both are full
of the same kind of quiet arithmetic error.
