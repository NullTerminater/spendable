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

Filled in at each milestone from the scripts in `scripts/`. Targets from the spec: warm launch to visible menu bar item under 300 ms, idle resident memory under 60 MB with only the menu bar, under 120 MB with the main window open, near-zero idle CPU.

| Milestone | Warm launch | First launch | Idle footprint (bar only) | With window | After close | Notes |
|-----------|-------------|--------------|---------------------------|-------------|-------------|-------|
| (pending) |             |              |                           |             |             |       |

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
