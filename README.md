# Spendable

A private, single-user macOS menu bar app that answers one question: **how much money can I actually spend right now?**

It reads bank balances and transactions through a SimpleFIN Bridge subscription (read-only), keeps everything in a local SQLite database on this Mac, and shows the answer in the menu bar, a main window, and a desktop widget. No cloud, no telemetry, no accounts. It never moves money.

This repository is private and stays that way. Nothing that touches money is ever committed: no tokens, no access URLs, no real balances or transactions. See `CLAUDE.md` for the rules and `docs/PLAN.md` for the plan and every decision behind it.

## Setup

```
scripts/bootstrap.sh          # generates Spendable.xcodeproj, enables git hooks
open Spendable.xcodeproj      # or build from the command line, see CLAUDE.md
```

Requirements: macOS 15+, Xcode 26, `xcodegen` (`brew install xcodegen`). Signing uses the free Personal Team already registered in Xcode.

## Measured numbers

Filled in at each milestone from the scripts in `scripts/` (Debug build, this Mac, scratch container). Targets from the spec: warm launch to visible menu bar item under 300 ms, idle resident memory under 60 MB with only the menu bar, under 120 MB with the main window open, near-zero idle CPU. "Footprint" is `phys_footprint`, the number Xcode's memory gauge shows; it is smaller than RSS because shared framework pages are not counted.

| Milestone | Warm launch (3rd of 3) | First launch after build | Idle footprint (bar only) | With window open | After window closed | Leaks after 5 open/close cycles | Idle CPU |
|-----------|------------------------|--------------------------|---------------------------|------------------|---------------------|---------------------------------|----------|
| 1 (v0.1-skeleton) | 158 ms (runs: 150, 158) | 157 ms | 14.3 MB | 22.8–23.8 MB | 22.8–23.7 MB | 0 leaks, 0 bytes | 0.0 %, CPU time unchanged over 10 s |

Notes on milestone 1: after the window closes, a heap dump contains no window, hosting or view objects of ours, so the view hierarchy is released; the ~9 MB that stays resident is AppKit and SwiftUI framework caches from the first window, and it does not grow across cycles (cycle 2 and 3 are within 1 MB of each other). The database with only the schema is 4 KB plus a 119 KB WAL file.

## Verifying a milestone yourself

```
scripts/bootstrap.sh
open Spendable.xcodeproj        # Run the Spendable scheme
```

Milestone 1: a coin icon appears in the menu bar. Open Spendable from it, add an account by hand (name, kind, balance), quit and reopen, and it is still there. Edit an account by double-clicking it. Nothing is calculated yet.

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
Sources/SpendableWidget/  the WidgetKit extension (reads a summary file, never the database)
Tests/SpendableTests/  unit tests (in-memory databases only)
Tests/Fixtures/        public demo snapshots and synthetic data, nothing real
scripts/               bootstrap and measurement scripts
docs/                  plan and decisions
```
