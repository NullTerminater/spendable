# Where this project is

Written 15 September 2026, at the point milestone 4 was half built; brought up to date on
16 September after every claim in every document was checked against the code. Anyone picking this
up — a person or another session — should be able to carry on from here without re-deriving
anything.

The plan and every decision the owner has made is `docs/PLAN.md`. Read that first if you have not.
`CLAUDE.md` names all six documents and the three reviews, and which of them have been superseded.

## State at a glance

| Milestone | State | Tag |
|---|---|---|
| 1. Project skeleton, signing, schema, manual accounts, window | **Done, reviewed by the owner** | `v0.1-skeleton` |
| 2. Safe-to-spend engine, disclosure, pay schedule, manual bills | **Done, reviewed by the owner** | `v0.2-engine` |
| 3. SimpleFIN client, Keychain, chunked budgeted sync, memory test | **Done, reviewed by the owner** | `v0.3-simplefin` |
| 4. Real-token setup, account types, staleness display, scheduler | **Half built — see below** | — |
| 5. Recurring-charge detection, confirm/dismiss, subscription totals | Not started | — |
| 6. Credit cards: due day, statement balance, minimum | Not started | — |
| 7. `MenuBarExtra`: the number in the bar, compact panel | Not started | — |
| 8. WidgetKit extension over a summary file | Not started (a throwaway stub exists from milestone 1) | — |
| 9. Settings, re-claim, diagnostics, final performance pass | Not started | — |

188 tests pass and `main` is pushed to the private remote, including the half of milestone 4 that is
built. Nothing is sitting uncommitted.

## How to verify what is done

```bash
scripts/bootstrap.sh
xcodebuild -project Spendable.xcodeproj -scheme Spendable -configuration Debug -derivedDataPath DerivedData -allowProvisioningUpdates build
xcodebuild -project Spendable.xcodeproj -scheme Spendable -destination 'platform=macOS' -derivedDataPath DerivedData test
```

`-derivedDataPath DerivedData` is not optional: the measurement scripts and the demo command below
all look for the app at `DerivedData/Build/Products/Debug/Spendable.app`, and without the flag they
either refuse to run or measure an older binary.

Milestones 1 and 2 are visible in the app: run it, open the window from the menu bar icon, add an
account and a bill. Milestone 3 has no screen of its own; drive it against SimpleFIN's public demo:

```bash
open --env SPENDABLE_DEBUG_CONTAINER=/tmp/spendable-demo --env SPENDABLE_DEBUG_CONNECT_DEMO=1 DerivedData/Build/Products/Debug/Spendable.app
```

That claims a fresh single-use demo token, stores it under a separate keychain item from any real
connection, syncs, and writes what it did to `/tmp/spendable-demo/measurements.log`.

## Measured numbers

From `scripts/measure-launch.sh`, `measure-memory.sh` and `leaks-diff.sh`, Debug build, against a
scratch container. Targets from the specification: warm launch under 300 ms, idle under 60 MB, under
120 MB with the window open, near-zero idle CPU.

| Milestone | Warm launch | Idle | With window | Leaks |
|---|---|---|---|---|
| 1 | 200 ms | 14.3 MB | 21.7–22.4 MB | 0 |
| 2 | 153 ms | 14.5 MB | 26.0–26.9 MB | 0 |
| 3 | 161 ms | 14.8 MB | 26.4–27.2 MB | 0 |

Both safe-to-spend figures compute in 4.3 ms on 40 accounts and 120 bills. Storing a year of
transactions (5,984 rows, 11 windows) grows the live heap by 229 KB.

---

# Milestone 4: exactly where it stopped

## Why it stopped

The session ran out of usage twice during milestone 4's design review, and then the owner asked for
this handoff. Nothing is blocked on a decision or a problem — it stopped mid-implementation.

## The design and its review are complete

`docs/CONNECTING.md` is the design. It was then attacked by four independent readers before
implementation, the same practice used for milestones 2 and 3. That review is
**`docs/reviews/milestone-4-review.md`**: 27 decisions, 8 findings rejected and 25 test cases, kept
verbatim.

**Read that file before writing any more milestone 4 code.** It contains the complete final rule
set — the guesser's algorithm and word lists, the exact sentences the owner reads, the scheduler
contract — and several of its decisions are not things anyone would arrive at unaided.
`docs/CONNECTING.md` was rewritten on 16 September to carry the review's rules in place of the nine
it overruled, so it can be read on its own again; the review is still the authority, and it holds
the word lists and worked test cases CONNECTING deliberately does not repeat.

The reviews for milestones 2 and 3 are in the same folder. They were rescued from a session
scratchpad that was about to be deleted; they explain why several shipped rules look odd.

## Built, working, tested and committed

- **`Sources/Spendable/SimpleFIN/AccountTypeGuess.swift`** — the account-type guesser, complete and
  matching the review's specified algorithm: normalise, strip the bank's own name, match whole words
  and phrases never substrings, longest phrase first, and refuse to guess when two strong categories
  collide. `Tests/SpendableTests/AccountTypeGuessTests.swift` covers it against the review's table of
  real US bank names, including the traps: "ALLIANT CREDIT UNION CHECKING" is a current account,
  "CARDINAL CHECKING" is not a card, "SAVINGS SECURED VISA" and "MONEY MARKET CHECKING" ask rather
  than guess, "CITI DOUBLE CASH" is not cash, "FIDELITY CASH MANAGEMENT" is investments.
- **`Sources/Spendable/SimpleFIN/SyncState.swift`** — the `sync_state` keys the scheduler's gates
  need (`balances-synced-at`, `transactions-pulled-at`, `sync-attempted-at`,
  `sync-failures-in-a-row`, `connected-at`), plus `SyncShape` and `SyncPolicy`, a pure decision about
  whether to sync and what to ask for. `Tests/SpendableTests/SyncPolicyTests.swift` covers it.
- **`Sources/Spendable/SimpleFIN/SyncCoordinator.swift`** — rewritten. Three mechanisms the review's
  blocking findings depend on are fixed inside this file, and one of those findings is only half
  done:
  - a real single-flight `Task`, because an actor serialises statements rather than whole operations,
    so two triggers would each have got past the budget check at a different `await` and each spent a
    request. **The decision this serves, `one-coordinator-one-scheduler`, is not finished:**
    `AppModel` still has no `syncCoordinator` property and `DebugLaunchOptions` still constructs its
    own instance, and two instances share no single-flight state. See item 9 under "Not built yet";
  - `SyncShape`, so transactions are actually fetched again after the first history walk ends. The
    old code declared a `reason` parameter and never read it, which meant no transaction would ever
    have been fetched again;
  - a report that distinguishes "still filling in history" from a failure, because every first
    connection ends on a budget refusal by design and the old code called that an error. A window
    that *failed* mid-walk used to report the walk as finished; that is fixed. Still outstanding in
    this file, from `history-progress-says-a-date-not-a-fraction`: `SyncReport` lacks
    `enum HistoryStop { case noMoreHistory, reachedThirteenMonths, budget, failed }` and
    `historyStopped`, so "that's as far as your bank goes" cannot be told from "I'll carry on
    tomorrow". Item 6 below owns the screen wording; this one is a coordinator change.
- **The investments rule in the engine** — an account the bank reports holdings for is held out of
  every total whatever it is called, whatever type it is given and whatever the owner opts into, with
  wording in `SafeToSpendNarrative`, `MainWindowView` and `OverviewView`. This came out of milestone
  3's review: the demo's own savings account holds six figures of Apple stock and is called
  "SimpleFIN Savings". Holdings are now tested **before** the type and before credit, so an untyped
  share account is never offered the four-way type picker whose "credit" answer would print "You owe
  $128,400" about a portfolio. Two tests pin it, one of them over every type an account can be
  given. The remaining order work — `loan`, `superseded-pending-answer` and
  `not-looked-inside-yet` — is item 4 under "Not built yet".

## Not built yet

In the order I would do them. Each item names the decision in
`docs/reviews/milestone-4-review.md` that specifies it.

1. **Migration v4** (`migration-v4`). Six columns on `account`: `guessed_from_name`, `guess_class`,
   `holdings_observed_at`, `resumed_updating_at`, `merge_candidate_for`, `merge_answered_at`. Add the
   matching properties to `Account` and the name to `AppDatabase.allMigrations`. Nothing else in the
   schema changes in this milestone. **Do this first** — most of what follows needs those columns.
2. **Wire the guesser into ingestion** (`the-guess-is-computed-once`). Compute the guess once, in the
   transaction that inserts the account row, from `remote_name`; store it with
   `guessed_from_name`; never recompute it. A later rename must never re-type an account.
3. **`holdings_observed_at`** (`holdings-before-a-guess-counts`). Set it on any **dated** answer that
   carried a `holdings` key, empty or not. A balances-only answer never sets it. Then a `checking` or
   `cash` *guess* on an account that has never had a dated answer does not count yet — a new
   `HeldOutReason.notLookedInsideYet`. This is what stops an $18,000 brokerage sweep account named
   "…CASH MANAGEMENT" entering the headline as spendable money. The coordinator must also carry on
   into `fetchTransactions` in the same run when `outcome.accountsInserted > 0`, so that normally
   resolves within minutes.
4. **Engine classification order** (same decision, last paragraph). The final order is archived →
   superseded-pending-answer → currency → loan → investments → not-looked-inside-yet → no type →
   credit → savings opt-in → not updating → age. Investments already sits above "no type" and above
   credit, which is the half that matters for the owner's rule 11; the three steps still missing are
   `loan`, `superseded-pending-answer` (item 10) and `not-looked-inside-yet` (item 3), and each
   needs its own `HeldOutReason` or standing.
5. **What a guess may do to the number** (`what-a-guess-may-do-to-the-number`). Per-outcome
   permissions and the exact row sentences.
6. **The setup screen** (`the-paste-field`, `nothing-is-written-before-the-keychain-write-verifies`,
   `who-holds-the-unsaved-claim`, `keychain-error-knows-which-operation-failed`,
   `setup-screen-second-visit`, `claim-cut-off-in-flight`,
   `history-progress-says-a-date-not-a-fraction`). The screen where a real token is pasted.
7. **The two credential banners** (`two-credential-banners`). Different titles, bodies, icons and
   buttons: one asks the owner to paste a new token, the other to unlock their keychain. Confusing
   them costs them a setup token, so the keychain banner must never render a paste field.
8. **Type confirmation in the UI** (`confirming-a-guess-moves-the-number`). Confirming a checking
   guess unlocks the bank's available balance, which *moves the headline*, and the app must say so.
9. **One coordinator, one scheduler** (`one-coordinator-one-scheduler`, `scheduler-lifecycle`,
   `background-activity-completion-contract`, `tolerance-versus-the-overdue-gate`,
   `wake-and-launch-before-the-network`). `AppModel` owns a single `SyncCoordinator` and a single
   `NSBackgroundActivityScheduler`; the completion handler must be called exactly once on every path
   or syncing stops silently forever; `NWPathMonitor` so an offline wake does not spend a request.
10. **The remaining states and wording** (`one-connection-fails-others-fine`, `vanished-and-returned`,
    `non-usd-balances`, `archiving-confirmation`, `the-accounts-screen-says-what-it-left-out`,
    `connected-but-no-accounts`, `manual-account-the-bank-duplicates`).
11. **Tests** for all of the above, from the review's 25 cases.
12. **Measure, commit in small pieces, tag `v0.4-connected`, then stop** and let the owner run it.

## The one question the review raised — now answered

The review asked whether a `checking` or `cash` guess should be held out until the app has looked
inside the account. The owner answered on 15 September: **safe is always better than faster.** They
have no shares, expect never to, and would treat them as savings rather than spending money if they
did. So the safe reading stands, and it is now rule 11 in `docs/PLAN.md`:

- An account holding shares or funds is never counted, and **no switch is offered** to change that.
  Offering one would be a control that does nothing, and would suggest a share portfolio could
  become this month's spending money.
- A `checking` or `cash` guess on an account not yet looked inside does not count until a dated
  answer has arrived for it.

There are no open questions for the owner.

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
- **`osascript` has no assistive access here**, so the UI cannot be clicked from a shell. Drive it
  with the Debug-only environment variables instead: `SPENDABLE_DEBUG_CONTAINER`, `_SCREEN`,
  `_FIGURE`, `_SEED_SAMPLE`, `_OPEN_WINDOW`, `_MEMORY_CYCLE`, `_ENGINE_BENCH`, `_CONNECT_DEMO`.
- **`log show` returns nothing for this app from a shell.** Measurements are read from
  `<container>/measurements.log` instead. Screen Recording is granted, so
  `screencapture -x -o -l <windowID>` works; there is a small `listwindows` helper pattern in the
  session notes for finding the window id via `CGWindowListCopyWindowInfo`.
- **The pre-commit hook rightly rejects credential-shaped literals in test files.** Build such URLs
  at runtime with `URLComponents` rather than weakening the hook. There is also a `commit-msg` hook.

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
