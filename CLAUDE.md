# Spendable — rules for anyone working in this repo

This app reads the owner's real bank accounts. Every rule here is hard.

## Secrets and data

- The SimpleFIN access URL, setup tokens, real balances, account numbers and real transactions never enter this repo: not in code, tests, fixtures, docs, commit messages, logs, screenshots or profiling artifacts. Test fixtures are the public demo data (`demo:demo@beta-bridge.simplefin.org`) or synthetic.
- Never run `git commit --no-verify`, never `git add -f`, never loosen `.gitignore` or the pre-commit hook to admit a blocked file. The hook in `.githooks/` is the last line of defence; `scripts/bootstrap.sh` enables it.
- Never read the real Keychain item from the command line. Never print or log credentials, request URLs with credentials, or HTTP bodies. Logging uses static strings, status codes and hostnames only.
- If you are about to write a real balance, account number or token into a file in this repo, stop and tell the owner instead.
- Instruments traces, memgraphs and xcresult bundles go under `~/Library/Application Support/Spendable-profiles/`, never inside the repo.

## Build

- Use `xcodebuild` and `xcrun`. The bare `swift` on this Mac is a broken swiftly shim.
- The Xcode project is generated: edit `project.yml`, then run `scripts/bootstrap.sh` (xcodegen). Never edit a `.pbxproj`. The `.xcodeproj` is gitignored.
- Signing: free Personal Team `UW2KV7XB66`, automatic signing, `-allowProvisioningUpdates` approved by the owner. App Group `UW2KV7XB66.spendable`. Bundle id `com.nullterminater.spendable`, widget `com.nullterminater.spendable.widget`.
- GRDB is the only dependency, pinned exactly in `project.yml`. Adding another package needs the owner's explicit yes first.
- Deployment target macOS 15.0, Swift 6 language mode, strict concurrency.
```
scripts/bootstrap.sh
xcodebuild -project Spendable.xcodeproj -scheme Spendable -configuration Debug -derivedDataPath DerivedData -allowProvisioningUpdates build
xcodebuild -project Spendable.xcodeproj -scheme Spendable -destination 'platform=macOS' -derivedDataPath DerivedData test
```

`-derivedDataPath DerivedData` is not optional. Every measurement script, and every verify command in `README.md` and `docs/HANDOFF.md`, looks for the app at `DerivedData/Build/Products/Debug/Spendable.app`. Without the flag the build goes to `~/Library/Developer/Xcode/DerivedData/Spendable-<hash>/` and those commands either refuse to run or quietly measure an older binary and report its numbers as current. `DerivedData/` is gitignored.

## Code rules (from the spec)

- Money is `Int64` cents everywhere. No `Double`, and no `Decimal` outside the currency formatter at the display edge.
- Never load the transaction table into memory. Totals, counts and groupings are SQL aggregates. Lists page with `LazyVStack`.
- Tests use in-memory GRDB databases, never a database path inside the repo.
- One coalesced scheduler for sync. No per-view timers, nothing that wakes the process when nothing changed. `NSBackgroundActivityScheduler` has no fire-time property, so the app never manufactures one with a `Timer`, a `DispatchSourceTimer`, or a re-`schedule` on a short computed interval.
- Plain English in the UI: no jargon without a gloss on the same screen, numbers inside sentences, no editorialising about spending.
- A negative safe-to-spend is never a negative headline. Where there is room it reads `$0 (balance: -$121)`; in the menu bar and the small widget it reads `$0 (-$121) ⚠`. The minus is whatever sign the owner's locale uses, not a typographic minus. The shortfall is rounded **away** from zero so it is never understated, is shown to the cent when it is under a dollar, and the per-day allowance in that state is `$0 a day`. A bare `$0` therefore has one meaning only: nothing left, and not short. `SafeToSpendDisplay` in `Sources/Spendable/Engine/SafeToSpendNarrative.swift` is the only place these strings are built.
- An account the bank reports holdings for holds shares or funds, not money. It is never counted towards what can be spent, whatever it is called, whatever type it is given and whatever the owner has opted into — and the app never offers a switch to change that, because a switch there would imply a share portfolio could become this month's spending money. A `checking` or `cash` **guess** on an account the app has not yet fetched transactions for does not count until it has. (`docs/PLAN.md` rule 11, and `docs/reviews/milestone-4-review.md`, `holdings-before-a-guess-counts`.)
- The sync budget is 14 requests in a rolling 24 hours, of which at most 6 may be history windows, and no request the app builds ever spans more than 44 days. Where `docs/PLAN.md` says 12 a day, 45-day windows or 9 windows, it is stale and `docs/SYNC.md` governs.

## Process

- Small commits with real messages. Each milestone ends with an annotated tag `v0.N-<name>` whose message carries the measured numbers.
- Do not start the next milestone until the owner has seen the current one run.
- Read `docs/HANDOFF.md` before writing any code. It says which milestones are built, what milestone 4 contains, which contracts have been superseded, and which traps cost real time to find.
- The plan and every decision the owner has made is `docs/PLAN.md`. Its numbered decision list binds every other document — including rule 11 (2026-09-15: an account holding shares or funds is never counted, and no switch is offered) and the negative-headline rule above.
- Then read what the work needs. There are six documents and three reviews, and they are not interchangeable:
  - `docs/HANDOFF.md` — where the project actually is: milestones 1–3 built, measured and tagged; milestone 4 implemented; validation and owner acceptance. Start here.
  - `docs/ENGINE.md` — the safe-to-spend contract (milestone 2, shipped).
  - `docs/SYNC.md` — the SimpleFIN client and sync contract (milestone 3, shipped).
  - `docs/CONNECTING.md` — the milestone 4 implementation contract, including owner-approved rejected-credential repair (PLAN rule 13). Otherwise: **where it and `docs/reviews/milestone-4-review.md` disagree, the review wins.** Never implement a rule from it without checking the review first.
  - `docs/reviews/milestone-4-review.md` — the authority for the rest of milestone 4: 27 decisions, 8 findings rejected, 25 test cases, kept verbatim. Read it before writing any more milestone 4 code.
  - `docs/reviews/milestone-2-review.md` and `docs/reviews/milestone-3-review.md` — why several shipped rules look odd.
  - `README.md` — how to build, how to verify each milestone, and the measured numbers.
- Every contract is written as a document, attacked by several independent readers, and only then implemented. That practice has found, in every design so far, at least one rule that would have silently produced a wrong number about the owner's money. Do the same for milestone 5 (subscription detection) and milestone 6 (credit cards).
