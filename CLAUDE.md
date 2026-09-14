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
xcodebuild -project Spendable.xcodeproj -scheme Spendable -configuration Debug -allowProvisioningUpdates build
xcodebuild -project Spendable.xcodeproj -scheme Spendable -destination 'platform=macOS' test
```

## Code rules (from the spec)

- Money is `Int64` cents everywhere. No `Double`, and no `Decimal` outside the currency formatter at the display edge.
- Never load the transaction table into memory. Totals, counts and groupings are SQL aggregates. Lists page with `LazyVStack`.
- Tests use in-memory GRDB databases, never a database path inside the repo.
- One coalesced scheduler for sync. No per-view timers, nothing that wakes the process when nothing changed.
- Plain English in the UI: no jargon without a gloss on the same screen, numbers inside sentences, no editorialising about spending.
- A negative safe-to-spend is shown as `$0 (balance: −$X)`, never as a negative headline.

## Process

- Small commits with real messages. Each milestone ends with an annotated tag `v0.N-<name>` whose message carries the measured numbers.
- Do not start the next milestone until the owner has seen the current one run.
- The plan with every decision is `docs/PLAN.md`.
