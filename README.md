# Spendable

A private, single-user macOS menu bar app that answers one question: **how much money can I actually spend right now?**

It reads bank balances and transactions through a SimpleFIN Bridge subscription (read-only), keeps everything in a local SQLite database on this Mac, and computes the answer in the main window. The menu bar currently opens that window; the number in the bar and desktop widget arrive in later milestones. No cloud, no telemetry, no accounts. It never moves money.

This repository is private and stays that way. Nothing that touches money is ever committed: no tokens, no access URLs, no real balances or transactions. `CLAUDE.md` holds the rules; `docs/PLAN.md` the plan and every decision; `docs/HANDOFF.md` where the project actually is; `docs/ENGINE.md` and `docs/SYNC.md` the contracts for the shipped engine and sync; `docs/CONNECTING.md` the milestone 4 implementation contract. The owner’s numbered decisions in `docs/PLAN.md` take precedence; otherwise `docs/reviews/milestone-4-review.md` wins where the two disagree.

## Setup

```
scripts/bootstrap.sh          # generates Spendable.xcodeproj, enables git hooks
open Spendable.xcodeproj      # or build from the command line, see CLAUDE.md
```

Requirements: macOS 15+, Xcode 26, `xcodegen` (`brew install xcodegen`). Signing uses the free Personal Team already registered in Xcode.

Build and test with `-derivedDataPath DerivedData`, which every command below assumes:

```bash
xcodebuild -project Spendable.xcodeproj -scheme Spendable -configuration Debug -derivedDataPath DerivedData -allowProvisioningUpdates build
```

## Where this is

Milestones 1–3 are built, measured and owner-reviewed. Milestone 4 now implements real-token
setup, account corrections, connection repair, staleness wording and the shared sync scheduler.
Migration v4 and the UI are present; `docs/CONNECTING.md` describes their actual behavior.
238 tests pass in 26 suites on 21 September; the normal checkout’s signed Debug build succeeds. `docs/HANDOFF.md` records validation. Real-bank acceptance remains with the owner:
paste the token only into the app, review the accounts, correct a type and check it survives a
relaunch. Milestone 5 has not started.

## Measured numbers

Filled in at each milestone from the scripts in `scripts/` (Debug build, this Mac, scratch container). Targets from the spec: warm launch to visible menu bar item under 300 ms, idle resident memory under 60 MB with only the menu bar, under 120 MB with the main window open, near-zero idle CPU. "Footprint" is `phys_footprint`, the number Xcode's memory gauge shows; it is smaller than RSS because shared framework pages are not counted.

| Milestone | Warm launch (3rd of 3) | First measured launch | Idle footprint (bar only) | With window open | After window closed | Leaks after 5 open/close cycles | Idle CPU |
|-----------|------------------------|--------------------------|---------------------------|------------------|---------------------|---------------------------------|----------|
| 1 (v0.1-skeleton) | 200 ms (runs: 147, 200) | 201 ms | 14.3 MB | 21.7–22.4 MB | 21.7–22.3 MB | 0 leaks, 0 bytes | 0.0 %, 10 ms of CPU time over 10 s idle |
| 2 (v0.2-engine) | 153 ms (runs: 159, 153) | 400 ms | 14.5 MB | 26.0–26.9 MB | 25.9–26.7 MB | 0 leaks, 0 bytes | unchanged |
| 3 (v0.3-simplefin) | 161 ms (runs: 193, 161) | 174 ms | 14.8 MB | 26.4–27.2 MB | 26.3–27.0 MB | 0 leaks, 0 bytes | unchanged |
| 4 (v0.4-connected) | 165 ms (runs: 166, 165) | 1,103 ms | 17.5 MB | 32.8–33.5 MB | 31.5–31.9 MB | 0 leaks, 0 bytes | 0.0% sampled; 180 ms CPU during idle check |

Milestone 4's launch, window and full-leak measurements were repeated on 21 September with the
238-test recovery-receipt build in the normal checkout. The first launch after building took
1,103 ms; warm launches were 166 and 165 ms. The window test used six synthetic accounts and one
bill. All five closes released the window; footprint settled near 31.8 MB. Framework caches remain
resident, as in earlier milestones. The restored receipt implementation passed the full suite again
on 21 September, and the app passed strict code-signature verification.

The long idle check used revision `2759b59`, before the final receipt-only recovery fix. Its monitor
waited 3,600 seconds; wall-clock timestamps spanned 09:03:36–10:31:07 on 16 September. Footprint
went from 14.9 to 15.1 MB (**0.2 MB drift**), sampled CPU was 0.0%, cumulative CPU rose by 180 ms,
and the `top` IDLEW samples were 2 and 3. The log recorded one completed sync attempt with zero
requests; it does not identify which trigger woke it. These samples are not a full wakeup trace.
The earlier five-cycle leak comparison also found zero leaks. Allocations/Leaks, Time Profiler,
memgraphs and test results are retained outside the repo under `Spendable-profiles`.
Real-first-sync footprint awaits owner acceptance.

Storing a year of transactions — 5,984 rows across four accounts in eleven windows, through the real
ingestion path — grew the live heap by **203 KB** in the 21 September suite. The test host's
physical footprint rounded to 53 MB before and 54 MB after. Heap growth is asserted below 4 MB;
physical footprint is reported because resident freed pages and other tests affect it.

The milestone 3 engine benchmark worked out both figures in **4.3 ms** (slowest of 500 runs: 4.7 ms) on 40 accounts and 120 bills
— several times more of each than the app will ever really hold, and with weekly bills, which are
the worst case for expanding occurrences. It runs when the data changes or the day rolls over, not
on a timer.

Notes on milestone 1: after the window closes, a heap dump contains no window, hosting or view objects of ours, so the view hierarchy is released; the ~8 MB that stays resident is AppKit and SwiftUI framework caches from the first window, and it does not grow across cycles (cycles 2 and 3 are within 1 MB of each other). The database with only the schema is 4 KB plus a 119 KB WAL file. The main window's SwiftUI content is hosted inside a plain container view on purpose: as the window's content view, `NSHostingView` resizes the window to the content's ideal size after every layout on macOS 26, which shrank the window and undid the user's resizing.

## Verifying a milestone yourself

```
scripts/bootstrap.sh
open Spendable.xcodeproj        # Run the Spendable scheme
```

Milestone 1: a coin icon appears in the menu bar. Open Spendable from it, add an account by hand (name, kind, balance), quit and reopen, and it is still there. Edit an account by double-clicking it. At milestone 1 nothing was calculated; milestone 2 added the figures below.

Milestone 3 supplied the bank connection; milestone 4 supplies its setup screen. To watch the whole path run against SimpleFIN's public demo — it
claims a fresh single-use token, stores it under a **separate** keychain item (`access-demo`) from
any real connection, and syncs:

```bash
open --env SPENDABLE_DEBUG_CONTAINER=/tmp/spendable-demo --env SPENDABLE_DEBUG_CONNECT_DEMO=1 DerivedData/Build/Products/Debug/Spendable.app
```

Both variables are required: `SPENDABLE_DEBUG_CONNECT_DEMO=1` is what triggers the claim and the
sync, and the app refuses to run it unless `SPENDABLE_DEBUG_CONTAINER` is also set, so it can never
touch the real container. It writes what it did to `/tmp/spendable-demo/measurements.log`.
`docs/SYNC.md` is the contract every rule follows.

Milestone 2: the window has three screens. **Accounts** is milestone 1, plus a tick box on savings to count it. **Bills** is where you add your rent and anything that comes out automatically, with a monthly total at the top and an "I've paid this" action on each row. **What you can spend** is the answer: a number, and under "How is this worked out?" the whole sum in sentences. Set a payday and a second figure appears, covering only the days until you are next paid, with the bills that fall after it named rather than hidden. `docs/ENGINE.md` is the contract every one of those rules follows.

Milestone 4: choose **Connect your bank** in the sidebar. A saved working connection hides the
paste field; a locked Keychain offers Retry; a rejected connection offers safe repair. In **Accounts**,
confirm or correct the kind, answer any duplicate question, and use **Put away…** to preview an
archive's effect before accepting it. `docs/CONNECTING.md` lists the synthetic Debug fixtures.
The real-token flow and real-first-sync footprint have not been exercised by the builder.

To reproduce the numbers above without touching your real data:

```
export SPENDABLE_DEBUG_CONTAINER=/tmp/spendable-measure
scripts/measure-launch.sh DerivedData/Build/Products/Debug/Spendable.app 3
scripts/measure-memory.sh DerivedData/Build/Products/Debug/Spendable.app 3
scripts/leaks-diff.sh   DerivedData/Build/Products/Debug/Spendable.app 5
```

Debug builds also accept `SPENDABLE_DEBUG_OPEN_WINDOW=1` (open the window at launch) and `SPENDABLE_DEBUG_SEED_SAMPLE=1` (add three made-up accounts to an empty store), passed with `open --env`.

## Layout

```
project.yml            xcodegen project definition (edit this, never the pbxproj)
Sources/Spendable/     the app
Sources/SpendableWidget/  milestone 1 widget stub; summary reader arrives in milestone 8
Tests/SpendableTests/  unit tests (in-memory databases only)
Tests/Fixtures/        public demo snapshots and synthetic data, nothing real
scripts/               bootstrap and measurement scripts
docs/                  PLAN, HANDOFF, and the ENGINE / SYNC / CONNECTING contracts
docs/reviews/          the three design reviews, verbatim; the milestone 4 one is authoritative
```
