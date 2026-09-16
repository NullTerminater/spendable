# Milestone 4 — connecting a bank: the review's decisions

This is the output of the design review that ran against `docs/CONNECTING.md` before milestone 4
was implemented, kept verbatim because the implementation is not finished and the next person needs
the rules rather than a summary of them. The same practice found 42 problems in milestone 2's
design and 40 in milestone 3's.

27 decisions, 8 findings rejected, 25 test cases.

## Decisions

### 1. `type-guesser-algorithm-and-word-lists` (blocking)

Replace the whole "The name is the evidence" table in docs/CONNECTING.md with this rule set, implemented as a pure function `AccountTypeGuess.guess(remoteName:institutionNames:) -> Guess` in a new file Sources/Spendable/SimpleFIN/AccountTypeGuess.swift, with no database, clock or network.

SOURCE. `remote_name` only, exactly as the server sent it. Never `display_name` (the owner's rename must never re-type an account), never the balance, never `available_cents`, never `conn_name`/`org_name` except as the strip list below.

NORMALISE, once: (1) `name.precomposedStringWithCompatibilityMapping`; (2) `.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()`; (3) replace every character not in [a-z0-9] with one space; (4) split on spaces, drop empties; (5) drop tokens matching `^[0-9]+$` and `^[x*]+[0-9]*$`; (6) remove the phrases `federal credit union`, `credit union`, then the tokens `bank`, `banking`, `na`, `fsb`, `fcu`, `cu`, then every token of the same normalisation applied to `conn_name` and `org_name`. Phrase removal happens on the token stream before any matching, so `credit` can never survive out of `credit union`.

MATCH. Never substring, ever — `contains("card")` must not fire on `cardinal`. Multi-token phrases first, longest first, left to right, consuming their tokens; then single tokens over what remains. For matching only, both the token and the table entry drop a trailing `s` when the token is 5 characters or longer and does not end in `ss` (so `savings`→`saving`, `shares`→`share`, `reserves`→`reserve`, while `access` and `business` are untouched).

LISTS, matched in this order.
1. never-money (class `investment`): brokerage, invest, investment, investor, ira, roth, 401k, 403b, 457, sep, rollover, custodial, ugma, utma, annuity, portfolio, "cash management", cma, "money market fund", "settlement fund", sweep, advisory, managed, "mutual fund", 529.
2. loan (class `loan`): mortgage, loan, "student loan", heloc, "line of credit", lease. `student` alone is NOT in this list — "Student Checking" is a real checking account.
3. checking: checking, chequing, chkg, dda, "share draft", "draft account", "current account", spending, debit, corriente.
4. savings: saving, saver, "money market", "share savings", "regular share", emergency, "rainy day", "christmas club", "vacation club", certificate, "share certificate", cd, cds, ahorro.
5. cash: wallet, pocket, "petty cash", "cash on hand". The bare token `cash` is NOT a keyword.
6. credit: card, "credit card", "charge card", cardmember, "credit line", credit, visa, mastercard, "master card", amex, "american express", tarjeta, credito.
7. NEVER a keyword, written into the doc as an exclusion list so nobody re-adds them: platinum, select, signature, preferred, world, elite, gold, blue, freedom, venture, quicksilver, sapphire, reserve, reward, cashback, "cash back", discover, cash, everyday, total, access, advantage, premier, plus, one, 360, essential, complete, secure, "high yield", online, free, student, business.

TIE-BREAKS, in order: (a) any loan hit ⇒ class `loan`, no type; (b) any never-money hit ⇒ class `investment`, no type; (c) hits in two or more of checking/savings/cash/credit ⇒ no type, ask; (d) exactly one of those categories hit ⇒ that type; (e) no hit ⇒ no type, ask.

The balance sign may never write `guessed_type`, may never corroborate one, and is not an input to this function at all. Worked answers the tests must reproduce: "ALLIANT CREDIT UNION CHECKING ...4417"→checking; "Capital One 360 Checking"→checking; "Discover Cashback Debit"→checking; "NAVY FEDERAL CREDIT UNION - EVERYDAY CHECKING"→checking; "SHARE DRAFT"→checking; "Cuenta Corriente"→checking; "AMERICAN EXPRESS HIGH YIELD SAVINGS" (org "American Express National Bank")→savings; "WELLS FARGO PLATINUM SAVINGS"→savings; "SHARE CERTIFICATE"→savings; "PETTY CASH"→cash; "CHASE SAPPHIRE PREFERRED CARD"→credit; "Tarjeta de Crédito"→credit; "SAVINGS SECURED VISA"→ask; "MONEY MARKET CHECKING"→ask; "VISA DEBIT ...4417"→ask; "CITI DOUBLE CASH ...4417"→ask; "BLUE CASH EVERYDAY ...41007"→ask; "CHASE SAPPHIRE RESERVE"→ask; "PLATINUM SELECT 4417"→ask; "TOTAL ACCESS ...1234"→ask; "CARDINAL CHECKING ...4417" (org "Cardinal Credit Union")→checking; "FIDELITY CASH MANAGEMENT ...4412"→investment; "VANGUARD SETTLEMENT FUND"→investment; "CHASE AUTO LOAN"→loan.

**Why.** The doc gave four word lists, no algorithm and no precedence. Both readings an implementer would reach for are wrong in opposite directions: whitespace tokens miss "CHECKING-4417" and "Chase Total Checking®" so the owner's only current account is held out and the engine answers "I can't work this out right now"; substring matching types "CARDINAL CHECKING" as a card. The marketing words the doc listed as credit evidence (platinum, sapphire, rewards, discover) sit on deposit products, and the bare token `cash` sits on "CITI DOUBLE CASH" — a card whose $2,847.19 owed would have been added to the headline as money. Ambiguity now resolves to a free question rather than to a number.

### 2. `what-a-guess-may-do-to-the-number` (blocking)

Replace "What a guess is allowed to do" in docs/CONNECTING.md with exactly these permissions, one per outcome of the guesser above.

- `loan`: `guessed_type` NULL, `guess_class = 'loan'`. Contributes nothing. Never asks for a type and never offers the four-way picker. Row: "Chase Auto Loan is money you owe, not money you have, so it isn't counted here." Does not make the total incomplete — nothing is missing.
- `investment`: `guessed_type` NULL, `guess_class = 'investment'`. Contributes nothing, ever, and there is no opt-in. Row: "Fidelity Cash Management holds shares and funds, not money. What it's worth goes up and down with the market, so I never count it — there's no switch for this one." Does not make the total incomplete.
- `checking` or `cash`: `guessed_type` written. Counts at `balance_cents` as soon as `holdings_observed_at IS NOT NULL` (see the holdings decision), badged with "Is this right?". Never uses `available_cents` — that stays gated on `user_type == .checking` exactly as SafeToSpend.swift:305 has it.
- `savings`: `guessed_type` written. Held out as savings-not-counted. The "Count this towards what I can spend" checkbox is drawn only when `holdings_observed_at IS NOT NULL AND guess_class IS NULL` — fix MainWindowView.swift:148, which today draws it whenever `effectiveType == .savings` and so offers a switch that does nothing on an account the engine holds out for holdings.
- `credit`: `guessed_type` written. Contributes nothing. While `user_type` is NULL the row and the disclosure use the guess wording, not the milestone 6 statement prompt: "I think CHASE SAPPHIRE PREFERRED CARD is a credit card, going by its name, so I'm not counting it as money you have. It shows $1,180 owed. Is that right?" SafeToSpendNarrative.swift's "You owe $1,180 on X. No number here subtracts that — tell me its statement balance…" is reserved for `user_type == .credit`.
- no type (ask): `guessed_type` NULL, `guess_class` NULL. Held out, named under the number, total marked incomplete. Row: "What kind of account is SoFi Money? I can't count it until I know." plus the four buttons carrying Account.swift's existing glosses. When the balance is negative the question is sharper, rendered live from the current balance and stored nowhere: "TOTAL ACCESS 1234 is $47.20 in the red. Is this a credit card, or a checking account that's overdrawn?" — with the same four buttons.

Also record in the doc, so the next reader does not re-derive the wrong safeguard: the exposure from a card guessed as a deposit account is its whole balance appearing as money the owner has, not its credit limit; the available-balance rule is a separate and smaller protection. And record that `amounts_reversed` is a no-op for anything typed credit, because the card sentence takes `.magnitude` — it must never be offered to the owner as the fix for a wrong type.

**Why.** A negative balance promoting a guess to credit was a verdict, not a hint: SafeToSpend.swift classifies credit before it ever reaches a held-out reason, so an overdrawn BMO "TOTAL ACCESS" at −$47.20 would contribute nothing, raise no question, leave the total looking complete, and print "You owe $47" — and the owner's one visible remedy, "amounts look reversed", would not change the sentence. Asking is free; a silent classification of exactly the population PLAN's binding Q4 reserves for asking is not.

### 3. `migration-v4` (blocking)

Add one forward-only migration, registered after "v3-sync-bookkeeping" and listed in the migration-name array:

migrator.registerMigration("v4-account-type-guess") { db in
  try db.execute(sql: "ALTER TABLE account ADD COLUMN guessed_from_name TEXT")
  try db.execute(sql: "ALTER TABLE account ADD COLUMN guess_class TEXT CHECK (guess_class IS NULL OR guess_class IN ('investment','loan'))")
  try db.execute(sql: "ALTER TABLE account ADD COLUMN holdings_observed_at INTEGER")
  try db.execute(sql: "ALTER TABLE account ADD COLUMN resumed_updating_at INTEGER")
  try db.execute(sql: "ALTER TABLE account ADD COLUMN merge_candidate_for INTEGER REFERENCES account(id) ON DELETE SET NULL")
  try db.execute(sql: "ALTER TABLE account ADD COLUMN merge_answered_at INTEGER")
}

Add the matching properties to `Account` (`guessedFromName`, `guessClass`, `holdingsObservedAt`, `resumedUpdatingAt`, `mergeCandidateFor`, `mergeAnsweredAt`) and to `Account.manual(...)` as nil. No other schema change is permitted in milestone 4. `guess_class` and `guessed_from_name` are recorded now and read by milestone 9's settings screen later; nothing in milestone 4 edits them from the UI.

**Why.** Four separate decisions below need durable facts the schema has no column for: what the guess was computed from, that an account is not money at all, whether the bank has ever told us what is inside it, that an account has just started updating again, and which hand-entered account a synced one may be a duplicate of. Batching them into one named migration keeps the owner's real data through a single upgrade.

### 4. `holdings-before-a-guess-counts` (blocking)

Three changes, together.

(1) Ingestion: in `SimpleFINIngest.recordHoldings`, set `holdings_observed_at = nowSeconds` whenever the answer to a **dated** request carried a `holdings` key for that account, empty or not — the early `guard !holdings.isEmpty` keeps governing `holdings_count`, but no longer governs the observation stamp. A balances-only answer never sets it. When `holdings_count` goes above zero, also set `guess_class = 'investment'`.

(2) Coordinator: after the balances step, if `outcome.accountsInserted > 0`, carry on into `fetchTransactions` in the same run even when the decided shape was `.balancesOnly` — the budget guard already refuses if there is no room. Add the sentence to CONNECTING.md: "A balances refresh that turns up an account I've never seen carries on and fetches that account's transactions in the same run, because that answer is the only one that says whether the account holds money or shares."

(3) Engine: a `checking` or `cash` **guess** (`user_type IS NULL`) on an account with `holdings_observed_at IS NULL` does not count. New `HeldOutReason.notLookedInsideYet`, row and disclosure sentence: "I haven't looked inside Fidelity Cash Management yet, so I don't know whether it holds money or shares and funds. I'll know once I've fetched its transactions — usually within a few minutes, and by tomorrow at the latest." The total is marked incomplete while it lasts. A confirmed `user_type` bypasses this gate entirely.

Also pin the classification order, which ENGINE.md's order sentence never named and the code placed between credit and savings. `SafeToSpendEngine.classify` becomes, in order: archived → superseded-pending-answer → currency → loan → investments → not-looked-inside-yet → no type → credit → savings opt-in → not updating → age. `loan` is `guess_class == "loan"`; `investments` is `guess_class == "investment" || holdingsCount > 0`. Moving investments above "no type" is what makes CONNECTING.md's "never counted even if the owner opts in" true for an account nobody has typed, and is what stops the app asking a question whose "credit" answer prints "You owe $128,400 on SimpleFIN Savings". Add `HeldOutReason.isALoan` with the loan sentence. This is an addition to ENGINE.md's order sentence, not a change to any row of its table.

**Why.** "Holdings beat every keyword" protected nothing at the only moment it mattered: holdings are recorded only from a dated answer, and a dated answer cannot create an account, so every account has `holdings_count = 0` at the instant it is first classified. A Fidelity Cash Management account created by a routine 10:14 balances refresh, with `transactions-pulled-at` set at 06:10, would count $18,412.66 of a money-market position as spendable for twenty hours. Change (2) collapses that window to the same run for essentially every case, which is why change (3) almost never shows and PLAN's binding Q4 ("keyword-backed guesses count immediately") still holds in practice.

### 5. `manual-account-the-bank-duplicates` (blocking)

Write PLAN milestone 4 item D into docs/CONNECTING.md, and count one side only until it is answered.

MATCH, evaluated once at the moment a simplefin account row is INSERTED: for every non-archived `source = 'manual'` account, normalise both names with the guesser's normalisation (institution tokens NOT stripped) and drop the stop tokens checking, chequing, saving, cash, card, credit, account, my, the, bank. If at least one token remains in both and any token is shared, set the manual row's `merge_candidate_for` to the new synced row's id. Matching generously is deliberate: a false positive holds money out with a sentence, a false negative doubles the headline.

WHILE UNANSWERED (`merge_candidate_for IS NOT NULL AND merge_answered_at IS NULL`) the manual row takes a new standing `.supersededPendingAnswer` whose arithmetic is exactly the archived rule — it contributes nothing, **and its bills keep being subtracted and are named**. It must not use ordinary held-out semantics, which would stop subtracting Rent and push the headline up by $1,500 at the moment the owner is being asked a question.

SCREEN, above both rows: "You added Chase Checking by hand, and your bank has now sent an account with almost the same name. Are these the same account? Until you tell me, I'm counting only the $1,240.18 your bank sent — never both, so this number can't be doubled." Buttons: "Yes, the same account" and "No, two different accounts". Line under the number while it waits: "$1,200 in your hand-entered Chase Checking isn't counted while I wait to hear whether it's the same account as the one your bank sent. The bills you pay from it are still being subtracted."

ON "YES", in one write transaction: copy the manual row's `display_name`, `user_type`, `cc_due_day`, `cc_minimum_cents`, `cc_statement_cents`, `cc_statement_entered_at`, `cc_has_credit_balance` and `include_in_safe_to_spend` onto the synced row where the synced row's value is NULL; `UPDATE recurring_charge SET paying_account_id = <synced id> WHERE paying_account_id = <manual id>`; set the manual row's `archived_at` and `replaced_by = <synced id>`; set `merge_answered_at`. Then say: "I'll use your bank's figures from now on, and I've kept the name, type and bills you set up. Your hand-entered Chase Checking is put away." If the copied `user_type` is checking, append the available-balance sentence from the confirm-a-guess decision, because inheriting a confirmed type is what unlocks `available_cents`.

ON "NO": set `merge_answered_at`, clear `merge_candidate_for`, and say "I'll count both from now on." The pair is never re-offered.

**Why.** The owner has been running this app since milestone 1 with hand-entered accounts for the very institutions SimpleFIN is about to send, and nothing in the engine deduplicates: two Chase Checking rows, both typed checking, both fresh, both contribute. The first screen after connecting a real bank would read "$1,830 safe to spend" against a true $630, with a disclosure naming Chase twice. The schema already carries `replaced_by` for this and the plan already promised it; the document under review contains no merge at all.

### 6. `one-coordinator-one-scheduler` (blocking)

State in CONNECTING.md, next to "One scheduler": "One coordinator. There is exactly one `SyncCoordinator` in the process." `AppModel` gains `private(set) var syncCoordinator: SyncCoordinator?`, created in the same place the database is opened and handed to the scheduler block, the Refresh button, the launch poll, and the wake and day-change observers. No other code may construct one; change `DebugLaunchOptions` (Sources/Spendable/App/DebugLaunchOptions.swift:83) to take the shared instance rather than building its own.

**Why.** SYNC.md's "two triggers at the same instant become one run" is `SyncCoordinator.inFlight`, an instance property; two instances share no single-flight state and an actor only serialises calls to itself. With the scheduler and the Refresh button each building their own, a 12:00:00 activity and a 12:00:20 Refresh both reserve a balances request, both read `SELECT MIN(tx_synced_through)` before either writes, both fetch the same incremental window, and both load `BackfillProgress` at index 3 and buy the same 44-day span twice — six of the day's fourteen requests for three windows of data, turning the eleven-window first-connection walk into a three-day walk.

### 7. `background-activity-completion-contract` (blocking)

Write the contract into CONNECTING.md and implement it exactly: the activity block is

scheduler.schedule { completion in
    Task { [coordinator] in
        defer { completion(.finished) }
        _ = await coordinator.syncIfDue(trigger: .scheduled)
    }
}

`completion(.finished)` is called on every path, including a credential problem, a budget refusal, a `SimpleFINFailure` and a decode failure — `syncIfDue` never throws, so `defer` covers all of them. `.deferred` is never returned: a refusal or a failure is a reason to wait for the next interval, not to be run again sooner, and returning it manufactures exactly the repeated wakeups with nothing changed that the specification bans. The `NSBackgroundActivityScheduler` is a stored property of `AppModel` with identifier `com.nullterminater.spendable.sync`, created once, never a local, and `invalidate()`d before release — a deallocated scheduler stops firing.

**Why.** `NSBackgroundActivityScheduler` does not reschedule a repeating activity until the completion handler is called. With the obvious bridge — a Task that calls `completion(.finished)` only on the success path — a Tuesday morning locked login keychain returns a `credentialProblem` at `run()`'s first `return`, the handler is never called, and the activity never fires again for the life of the process. On an LSUIElement app that opens at login and is never relaunched, that is eleven days of the Overview showing Tuesday's balance under "as of Tuesday" with no banner: the green-tick-over-dead-data failure the specification names.

### 8. `nothing-is-written-before-the-keychain-write-verifies` (blocking)

Add to CONNECTING.md, in "Pasting a setup token": "Until the Keychain write has been read back and verified, the app makes no `/accounts` request and writes no account row. A connection that is not saved is not a connection." The claim result lives only in memory (see the retention decision) and the only thing Retry does is attempt the Keychain write again; on success the first sync then runs normally. Do not build the `unsaved-connection-at` state key, and do not mark accounts not-updating on a failed save — with nothing written there is nothing to mark.

**Why.** The reviewed alternative was to sync with the retained credential and then repair the consequences. That leaves `SyncPolicy.load`'s `isConnected` true forever (it ORs in `COUNT(*) FROM account WHERE source = 'simplefin'`), leaves real balances in the database that the engine keeps counting for seven days — Chase Checking $1,240 still in a $412 headline on 18 September while the real balance is $260 after rent — and then blames the bank with "Your bank stopped sending new balances on 15 September" when the bank never stopped. Not writing anything is cheaper than every repair, and SYNC.md already orders the steps this way: verify the write "before it does anything else with the response".

### 9. `who-holds-the-unsaved-claim` (blocking)

Name the owner of the retention in CONNECTING.md and make it process-scoped: `AppModel` gains `private(set) var unsavedConnection: SimpleFINCredential?`. It is never SwiftUI `@State`, never held by `MainWindowState`, and never held by the setup view — `MainWindowController.windowWillClose` nils the content view, the toolbar, the delegate and `Self.current`, so every one of those dies the moment the owner closes the window or switches sidebar rows, taking a spent token's only copy with it.

While it is set, a banner appears in the same slot on **every** screen, carrying the Retry, with the full text: "I claimed your setup token, so that token is used up now — don't make another one yet. macOS wouldn't let me save the connection, but I still have it. Unlock your login keychain and press Try again. Don't quit Spendable until this works: if you quit, the connection is lost and you'll need a new setup token." Buttons "Try again" and "Open Keychain Access". State in the doc that Retry is reachable from every screen, not only the setup screen.

Add an `NSApplicationDelegate` whose `applicationShouldTerminate` returns `.terminateLater` while `unsavedConnection != nil`, behind a modal: "Your bank connection isn't saved yet. If you quit now it's gone and you'll have to make a new setup token on the SimpleFIN website." with "Quit anyway" and "Keep Spendable open". `SpendableApp`'s MenuBarExtra currently has `Button("Quit Spendable") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")` and there is no `applicationShouldTerminate` anywhere in Sources/, so ⌘Q ends the process silently today. Surfacing this banner in the menu bar is milestone 7; exposing it on `AppModel` now is what makes that possible.

**Why.** SYNC.md says the claim result "is kept in memory for the rest of the session" and CONNECTING.md offers a Retry, and neither says which object holds it. Every plausible SwiftUI home dies long before the session does. At 21:40 with a locked keychain, the owner goes to unlock it and first hits ⌘W — the live access URL is released, the setup token is already spent, the app never says so, and their only recovery is a hand-made new token: the exact pain the specification is written to avoid.

### 10. `keychain-error-knows-which-operation-failed` (blocking)

`CredentialStoreError.keychain(OSStatus)` becomes `case keychain(OSStatus, while: Operation)` with `enum Operation { case reading, writing }`. `load()` throws `.reading`; `SecItemUpdate`/`SecItemAdd` in `save()` throw `.writing`; the read-back inside `save()` maps any thrown `.reading` to `.writing` before it leaves `save()`. `ownerFacingMessage`'s refusal branch then picks by operation: `.reading` keeps "macOS wouldn't let me read your saved connection. Unlock your login keychain and try again."; `.writing` returns "macOS wouldn't let me save the connection. Unlock your login keychain and press Try again." On the claim path the setup screen shows the full banner text from the retention decision, which leads with the spent token. `.verificationFailed`'s "Nothing has been kept." is replaced on the claim path by that same banner text, because the token has in fact been consumed and a wrong item may now sit in the Keychain.

While `unsavedConnection != nil` the setup screen shows Retry and no Connect button and no paste field, so a second claim of the same token is impossible.

**Why.** `ownerFacingMessage` tests `isRefusalRatherThanAbsence` before the switch and returns the *read* sentence for every errSecInteractionNotAllowed / errSecAuthFailed / errSecUserCanceled / errSecNotAvailable — including the ones `save()` throws. At 21:40 the owner cancels the unlock dialog, reads "macOS wouldn't let me read your saved connection… try again", presses Connect again with the token still in the field, and gets a 403 that the outcomes table renders as "someone else may have — disable it on the SimpleFIN website". The app accuses a third party of stealing a token it spent itself ninety seconds earlier, and sends the owner to disable a token that is already dead.

### 11. `setup-screen-second-visit` (blocking)

Add a row to CONNECTING.md's outcomes table and resolve three states before the screen draws a field at all. `try credentials.load()` returns a credential → no field, no Connect button: "You're already connected to SimpleFIN. Changing the connection comes in a later version." `load()` **throws** → fail closed, still no field: "macOS wouldn't let me check your saved connection, so I won't replace it. Unlock your login keychain and open this again." `load()` returns nil → the paste field. State explicitly that re-connecting is milestone 9, so nothing in milestone 4 ever calls `save()` over an existing item.

**Why.** The screen ships in milestone 4 and is the only door to the connect flow, so it is reachable while connected, and the doc has no row for that. `load()` throws rather than returning nil on a locked keychain, so a `try?` or a `!= nil` test renders the first-run state over a perfectly good credential: after a restart the owner goes hunting, is invited to paste, makes a fresh token, and burns it — `SecItemUpdate` then fails against the same locked keychain. And `KeychainCredentialStore.save` begins with an in-place `SecItemUpdate` with no backup, which is exactly the atomic replacement PLAN reserves for milestone 9.

### 12. `two-credential-banners` (blocking)

Write both banners out in CONNECTING.md, with different icons and no token control anywhere on the macOS one.

Credential rejected (`gen.auth` from a server that actually answered) — icon `exclamationmark.triangle.fill`, orange. Title: "Your bank connection has stopped working". Body: "SimpleFIN won't accept the connection Spendable saved, so no new balances are coming in. Make a new setup token on the SimpleFIN website and paste it here." One button: "Paste a new setup token".

macOS refused the Keychain read — icon `lock.fill`, never the exclamation mark the other one uses. Title: "macOS won't let me open your saved connection". Body: "Your connection is still saved and your SimpleFIN setup token is still good — your Mac's login keychain is locked, so I can't read it. Unlock it and press Try again. Don't make a new setup token: you don't need one." Buttons: "Try again" and "Open Keychain Access". No control anywhere on this banner leads to the paste field.

Also replace the outcomes table's truncated Keychain row, which quotes only the first sentence of SYNC.md's message, with the full banner text from the retention decision.

**Why.** The doc says the two states "must never be confused" and then writes only one of them out, so both will be built as an orange strip with a button and the owner — who has seen the first one before — will act on the first. On the morning they changed their Mac password, that costs them a setup token they did not need, and the keychain write for the new one fails for the same reason, and quitting to start again throws away the in-memory credential.

### 13. `one-connection-fails-others-fine` (blocking)

Route SYNC.md's `con.*` text to the screen, which CONNECTING.md never does. On the row of every account of a troubled connection: "Not counted. Chase needs you to sign in again on the SimpleFIN website." Under the number: "$3,160 in Chase Total Checking isn't counted, because Chase needs you to sign in again on the SimpleFIN website. SimpleFIN said: \"Connection to Chase requires re-authentication.\" I'll start counting it again on the next check after you've done that." — server text as plain text, attributed, per SYNC.md. At the top of the accounts screen when some connections answered and others did not: "Your Ally accounts updated at 12:14 today. Your Chase accounts didn't — see the note on each of them." The generic stopped-updating sentence must not be used for these accounts.

**Why.** `SimpleFINIngest` already sets `not_updating_since` for every account of a troubled connection, and the account is still in the accounts array with a balance dated today. With only the two causes of silence the doc describes, the owner reads "Your bank stopped sending new balances on September 15" about a bank that sent a balance on September 15, their headline drops from $1,460 to "$0 (balance: −$1,700)", and nothing on screen tells them the one action that fixes it. The specification names this sentence word for word.

### 14. `confirming-a-guess-moves-the-number` (blocking)

Say it before and after. The confirm control reads "Is Chase Total Checking a checking account — money you spend from day to day?" with "Yes, that's right" and "No, it's something else". When `available_cents` is present and differs from `balance_cents`, print under the Yes button before it is pressed: "If you confirm this, I'll switch to the $940 your bank says is free to spend right now instead of its $1,200 balance. The $260 difference is payments that haven't finished going through." After it is pressed, as a line directly under the number until the next sync: "You confirmed Chase Total Checking is a checking account, so I've switched to the $940 your bank says is free to spend right now. That's why what you can spend went from $690 to $430 — the $260 is payments that haven't finished going through."

**Why.** Two correct rules collide the moment the owner uses the control: a keyword-backed guess counts at `balance_cents`, and `available_cents` is unlocked only by `user_type == .checking`. Chase Total Checking arriving at $1,200 with $940 available counts at $1,200; the owner presses "yes, that's right" and what they can spend falls by $260. The disclosure's account line changes its gloss, but the headline moves first and the disclosure is collapsed. From the owner's side, agreeing with the app made them poorer and nothing said why.

### 15. `wake-and-launch-before-the-network` (blocking)

Two changes in the milestone 4 scheduler layer, neither touching SYNC.md's settled reserve-before-send rule.

(1) Hold one `NWPathMonitor` (Network framework), started once alongside the coordinator. On a `.wake` or `.launch` trigger, if `currentPath.status != .satisfied`, wait for the first `.satisfied` update up to 60 seconds and then call `syncIfDue`; if it has not become satisfied within 60 seconds, drop the trigger entirely — the next one will come.

(2) In `SyncCoordinator.recordFailure()`, do not increment `sync-failures-in-a-row` when the failure is `.couldNotReachServer(.offline)`. The server did not fail and the Mac was not online. `sync-attempted-at` still throttles, so nothing is uncapped.

(3) Make the `dayIsFull` wording conditional on `balances-synced-at` being from today. When it is not: "I've used up today's requests to SimpleFIN, so I can't fetch anything new right now. The balances below are from yesterday evening." — the last clause rendered by `AsOf`. SYNC.md's existing sentence stays for the case it was written for.

**Why.** `NSWorkspace.didWakeNotification` is posted the instant the lid opens, seconds before Wi-Fi associates, and `SimpleFINClient.makeSession()` deliberately sets `waitsForConnectivity = false`. The request is already reserved, so a laptop carried between coffee shop, car and office spends four of fourteen requests on requests that never left the Mac, and climbs to a six-hour back-off by 14:00. At 16:00 the owner sees yesterday's balances, presses Refresh, and reads "Already refreshed today" — to an app that has successfully refreshed zero times today.

### 16. `scheduler-lifecycle` (material)

Give the scheduler an explicit lifecycle in CONNECTING.md, owned by `AppModel`. `startScheduling()` is called at the end of the first successful connection — the same step that writes `sync_state` key `connected-at` — and at app start-up when `connected-at` is present. `stopScheduling()` calls `invalidate()`, releases the instance, and clears `connected-at`, `sync-failures-in-a-row` and `sync-attempted-at`; milestone 9's disconnect UI is the only caller and is out of scope here, but the entry point is not. A re-connect creates a fresh instance with the same identifier.

Drop the `hasSyncedAccounts` fallback from `SyncPolicy.load`: `policy.isConnected = connected`. To keep that safe, any sync that completes a balances read writes `connected-at` if it is absent, in the same transaction as `balances-synced-at`.

**Why.** "Nothing is scheduled at all until a credential exists" has no mirror. The credential first exists on the setup screen, and if the scheduler is only created at start-up then an owner who connects at 14:10 on Tuesday gets no background refresh until the app is next launched — weeks, for an LSUIElement app that opens at login. And `isConnected` ORs in `COUNT(*) FROM account WHERE source = 'simplefin'` while SYNC.md forbids deleting account rows, so once connected it can never become false: after a future disconnect the activity keeps firing every six hours forever, each fire calling `SecItemCopyMatching` and potentially raising a password prompt from an app with no window.

### 17. `tolerance-versus-the-overdue-gate` (material)

Separate the gate from the interval. Add `SyncPolicy.balancesStaleAfterForActivity: TimeInterval = 5 * 3_600`, used by `decide` for the `.scheduled`, `.wake` and `.dayChanged` triggers; `.launch` and `.manual` keep `balancesStaleAfter = 6 * 3_600`, because SYNC.md pins the launch rule at six hours. The activity keeps interval 6 hours and tolerance 1 hour. Write into CONNECTING.md: "Balances are due at five hours and the system is asked for them at six with an hour of slack, so a fire that lands early is used rather than thrown away." Add to the `SyncPolicy` test table: `balancesSyncedAt` 5 h 15 m ago, trigger `.scheduled`, expected `.sync(.balancesOnly)`.

**Why.** XPC activity runs opportunistically inside its interval when the Mac is awake and on power, and the tolerance widens that further. With the gate and the interval both at six hours, a fire at 11:45 after a 06:30 sync computes 5 h 15 m < 6 h, returns `.skip("balances are recent")`, and the next chance is measured from that fire — around 17:00. The owner at their desk all day opens the window at 16:30 to decide whether to buy something and reads a figure built on a ten-hour-old balance, from an app that promises a refresh every six hours. `quietAfterAnyAttempt` (30 min) already prevents the looser gate from stacking requests.

### 18. `non-usd-balances` (material)

Give `Cents.format` a currency parameter at the display edge (default "USD") and pass `account.currency` from `AccountRow`; Cents.swift:102 currently pins `currencyCode = "USD"` unconditionally and MainWindowView.swift:164 formats every balance through it. The row amount for a CAD account reads "CA$2,400.00". The row sentence replaces "Not in US dollars, so it isn't counted." with: "Tangerine Savings holds 2,400.00 Canadian dollars. I only work in US dollars and I won't guess an exchange rate, so this one stays out of every total. Adding it by hand as dollars would make what you can spend wrong, so I'd leave it as it is." Under the number: "Tangerine Savings isn't in the figures above, because it's in Canadian dollars." Add a currency paragraph to CONNECTING.md, which does not mention currency anywhere today.

**Why.** The owner's binding decision excludes any non-USD account from every total, and the inherited row then prints its foreign balance with a dollar sign next to a caption saying it isn't counted. A Tangerine account at CAD 2,400.00 reads "$2,400.00 — not in US dollars, so it isn't counted", and the owner's reasonable next move is to type $2,400 in by hand, which puts 2,400 Canadian dollars into what they can spend as US dollars.

### 19. `archiving-confirmation` (material)

Write the control CONNECTING.md names but never writes. The context-menu "Put away" action confirms with the arithmetic in the sentence: "Put Chase Total Checking away? Its $3,160 stops counting straight away. The $1,700 of bills you pay from it keeps being subtracted, because that money still has to come from somewhere — so what you can spend goes from $1,460 to $0 (balance: −$1,700) until you tell me which account pays Rent $1,500 and Internet $200 now. You can bring the account back later." Buttons "Put it away" and "Cancel". The figures are computed from the engine before and after, never hard-coded. Immediately afterwards, as a line under the number: "Rent $1,500 and Internet $200 still come out of Chase Total Checking, which you've put away. Tell me which account pays them now." (SafeToSpendNarrative already emits a sentence of this shape; the confirmation is what is missing.)

**Why.** Archiving is one click from a context menu, it is the only action in milestone 4 that can move the number by an account's whole balance, and its consequence is the opposite of what "put away" suggests to someone tidying up. $1,460 becomes "$0 (balance: −$1,700)" and the reason lives four lines down inside a disclosure the owner has not opened.

### 20. `the-accounts-screen-says-what-it-left-out` (material)

Add a summary at the top of the accounts screen, composed from what actually happened, never a fixed phrase: "Two of your five accounts are in what you can spend: Chase Total Checking and Cash. Ally Online Savings isn't, because you haven't asked me to count savings. SoFi Money isn't, because I don't know what kind of account it is. Chase Freedom is a card, so what's on it is money you owe." Directly above it, whenever any account has no type: "One account is waiting for you to say what kind it is. Until you do, its $3,500 isn't part of what you can spend." — the count and the amount from the engine's held-out blocks, and the plural agreed. This is the sentence CONNECTING.md means by "the app says the total is incomplete" and PLAN means by "a banner counting unconfirmed accounts"; no bare percentage, no judgement about the owner's money.

**Why.** The doc promises that an untyped account is "named under the number" and that "the app says the total is incomplete", and writes neither sentence. The accounts screen as built shows a list of rows and no summary at all, so after the first real sync an owner with $11,500 sitting outside a $690 headline is left to do their own arithmetic over captions they may not read.

### 21. `vanished-and-returned` (material)

Split the stopped-updating sentence by cause, and write the return. Vanished from an otherwise good sync while the balance is still recent: "Chase Total Checking held $3,160 on September 15, and that's the last figure I have. It wasn't in what SimpleFIN sent at 12:14 today, so I've stopped counting it until it comes back." Balance genuinely old: keep the existing wording, which is right for that case. On the return, set `resumed_updating_at` in the same statement that clears `not_updating_since` in `SimpleFINIngest`, and show a line under the number for the rest of that calendar day: "Chase Total Checking is updating again. Its $3,160 is back in the figures, which is why what you can spend went from $0 to $1,460."

**Why.** The doc's one synced sentence names the balance date, which in the vanish case is today — so the owner reads that the balance is from today and that the bank has stopped sending balances, in one sentence. And the reverse transition has no sentence at all: at 18:14 Chase comes back, `not_updating_since` is cleared, and what they can spend jumps from "$0 (balance: −$1,700)" to "$1,460" between two glances at the same screen with nothing on it to account for the change.

### 22. `the-guess-is-computed-once` (material)

Add to "A correction is permanent": `guessed_type` and `guess_class` are computed exactly once, in the transaction that inserts the row, from `remote_name`, and are never recomputed. `guessed_from_name` stores the exact string they were computed from. `SimpleFINIngest.upsertAccount` rewrites `remote_name` on every balances sync, and a later change to it never re-types an account and never changes what contributes. When `remote_name` differs from `guessed_from_name` and `user_type IS NULL`, the row's existing "Is this right?" control gains one sentence and the number does not move: "Your bank now calls this account PLATINUM SELECT 4417. I've been counting it as checking — is that still right?" The single exception: an account that has never had any type (`guessed_type IS NULL AND user_type IS NULL AND guess_class IS NULL`) may have its guess recomputed on a rename, and even then only to fill in the question's default — never to move the account into counting on its own.

**Why.** The permanence rule covers `user_type` only, and the doc never says when the guess is computed or whether it is recomputed, while sync rewrites the evidence with no owner action. An account that arrived as "CHECKING ...4417" and is re-sent as "PLATINUM SELECT 4417" after a re-link would, if the guess re-ran, flip to credit during the 04:14 refresh: over breakfast the headline goes from "$2,560 safe to spend" to "$0 (balance: −$1,643)" under a row still labelled "CHECKING ...4417", because `display_name` is never touched by sync and the only thing that changed is a field the owner cannot see.

### 23. `connected-but-no-accounts` (material)

Add an outcomes row for HTTP 200 with an empty `accounts` array and an empty `errlist` on a first connection, with its own screen: "Connected — your setup token worked and I've saved the connection. SimpleFIN didn't send any accounts, which usually means no bank is linked to your SimpleFIN account yet, or one is still being set up. Go to the SimpleFIN website, link a bank, then press Check again. Don't make another setup token: this one is working." Buttons "Check again" and "Open the SimpleFIN website". Replace the milestone 1 empty state at MainWindowView.swift:90 — "Add an account by hand to start. Connecting your bank through SimpleFIN comes in a later step." — with "Add an account by hand, or connect your bank through SimpleFIN."

**Why.** SYNC.md's protection against a silently dead connection is written over accounts already in the database, and on a first connection there are none. An owner who subscribes and generates a token before linking a bank sees "I found 0 accounts" followed by an empty state whose text now says the connect feature does not exist yet — so everything on screen says the connection did not happen, and the reasonable next move is a second setup token and a second live credential against their bank.

### 24. `claim-cut-off-in-flight` (material)

Keep in memory — never the token, never a hash of it — the instant of the last claim attempt this session, and branch the 403 on it. After a dropped claim: "I couldn't reach SimpleFIN, so I don't know whether that setup token was used or not. Don't press Connect again with this one — if it did go through, it's already spent. Make a fresh setup token on the SimpleFIN website and paste that instead." When a 403 follows a local attempt within the last hour: "That setup token has already been used — by this app, a few minutes ago, when the connection dropped. It's spent and it can't be reused. Make one new setup token on the SimpleFIN website and paste it here. Nothing has gone wrong with your bank and there's nothing to disable." SYNC.md's compromise wording is kept only when no recent local attempt is on record.

**Why.** The outcomes table maps a network failure to "Check your internet connection", which invites pressing Connect again — but the claim POST may well have been served before the reply was lost, so the retry returns 403 and the owner is told that someone else may have their bank credential and sent to disable something on the SimpleFIN website, which is not the fix. Telling a financially illiterate owner they may have been compromised, over an app's own spent token, is the worst sentence in the flow.

### 25. `the-paste-field` (material)

Keep the field's purpose, change its surfaces. Use `SecureField` with an explicit "Show" toggle the owner must press, and prove the paste landed with a line under it that contains none of the value: "Pasted — 138 characters." Add a visible "Paste" button beside the field that reads `NSPasteboard.general.string(forType: .string)`, so the screen does not depend on an Edit ▸ Paste key equivalent that `SpendableApp` (MenuBarExtra with no `.commands { }`) may not provide; verify ⌘V on the real build during acceptance, before a real token is in the clipboard. While the setup screen is up: `window.sharingType = .none` and `window.isRestorable = false` — neither is set today, so the token is in every screenshot, screen recording and Screen Sharing session, and AppKit writes `~/Library/Saved Application State/com.nullterminater.spendable.savedState/` on the next ⌘Q. On the field: `.writingToolsBehavior(.disabled)`, `.autocorrectionDisabled()`, no `textContentType`. On success or cancel: clear the state, call `removeAllActions()` on the window's field editor's `undoManager`, and resign first responder. Restate SYNC.md's memory promise in CONNECTING.md as a lifetime bound — "nothing keeps a reference to the pasted text after the claim returns" — rather than as erasure, because a Swift `String` has immutable copy-on-write storage and no zeroing API.

**Why.** The stated reason for a plain field — the owner needs to see that the paste landed — does not require rendering a live bearer credential, and the doc contradicts itself by refusing to echo the token into an alert because that "puts it somewhere it can be screenshotted" while putting it on screen for the whole connect. An `NSTextField`'s `AXValue` is the token in clear to any process with Accessibility permission (a launcher, a clipboard manager, a window manager), and the window's undo stack outlives the setup screen. The access URL it yields is live read access to the owner's accounts until revoked.

### 26. `history-progress-says-a-date-not-a-fraction` (material)

`SyncReport` gains `enum HistoryStop { case noMoreHistory, reachedThirteenMonths, budget, failed }` and a `historyStopped: HistoryStop?`, derived from `BackfillProgress.state` and the refusal. Also fix `fillInHistory`: `report.stillFillingHistory = report.refusal != nil` leaves it false when a window *fails* mid-walk even though `progress.state` is still `.running` and the walk will resume — set it true for a failure as well.

The screen says a date, never a fraction, using the `coveredBackTo` / `history_coverage_start` already stored. In progress: "Getting your past spending — I've gone back as far as August 3 so far. You don't need to wait for this." On `.budget`: "I've got your accounts and balances, and your spending back to August 3. I'll fetch the older months over the next day or two. Nothing here is waiting on you." On `.noMoreHistory` or `.reachedThirteenMonths`: "I've got your accounts and balances, and your spending back to August 3 — that's as far as your bank goes." Delete "window 3 of 11" from CONNECTING.md.

While editing, write example dates the way the app renders them on an en_US Mac — "September 3", per `CalendarDay.shortPhrase` — and use "as of today" rather than "as of this morning", which claims a time of day `AsOf.dayPhrase` has no basis for. (PLAN's "window 3 of 9" is the stale number; 11 matches `BackfillPlan.windows`.)

**Why.** The denominator is a fact about the app, not the owner's bank, and the two common endings are indistinguishable in the report: a walk that ends `.exhausted` produces a report byte-identical to a clean finish, so a bank exposing 90 days leaves the owner staring at "window 5 of 11" and, if the budget sentence is reused there, waiting indefinitely for five windows the app will never request — `guard progress.state == .running else { return }` sees to that. Meanwhile a full-history bank really does stop at 6 of 11 on day one and really will continue. "Window" is also jargon with no gloss on the same screen.

### 27. `the-fixed-random-minute` (minor)

Replace the bullet "At a fixed minute chosen once at random and kept" with what is true: "`NSBackgroundActivityScheduler` has no phase, start date or fire-time property — the first fire is relative to the `schedule(_:)` call and the system then slides it within the tolerance. The hour of slack is what scatters the request away from the top of the hour; the app does not choose its own fire time, and must never use a `Timer`, a `DispatchSourceTimer` or a re-`schedule` with a computed short interval to manufacture one." Note in the doc that SYNC.md's "at a fixed minute chosen away from the top of the hour" describes an intent the API cannot express, and that the tolerance delivers it in practice. Implement nothing further.

**Why.** The sentence promises a behaviour the API cannot provide, and the only way to satisfy it literally is a repeating timer in an LSUIElement app — exactly what the specification forbids and what App Nap throttles into uselessness. Leaving the claim in place invites an implementer to build that.

## Findings deliberately rejected

- **`keyword-table-has-no-precedence`** — Its fix — the checking and savings lists win outright over credit — silently types "Savings Secured Visa" as savings and "Chase Freedom Rewards Checking" as checking, putting card debt into the headline; the strong-collision-asks rule plus the exclusion list covers every example it raises.
- **`type-guess-liability-with-no-credit-word`** — Its liability-capable-evidence rule is subsumed: with `cash` and `everyday` removed from the keyword table entirely and the marketing words demoted to an explicit never-a-keyword list, no strong deposit token appears on any real US card name, so the extra blocking rule only over-asks (it would refuse to type "Discover Cashback Debit", a real $2,800 checking account).
- **`type-guess-balance-sign-promotion`** — One part rejected: storing the balance the question was asked about. The row sentence is rendered live from the current balance, which cannot go stale and needs no column.
- **`fixed-random-minute-not-expressible`** — Its enforcement half — a persisted `scheduler-minute-offset` and skipping a `.scheduled` fire that lands in the first three minutes of an hour — throws away a whole six-hour cycle to solve a politeness problem the one-hour tolerance already scatters; that is the same harm as the tolerance-versus-gate finding. The doc rewrite is kept, the mechanism is not.
- **`stale-balances-after-unsaved-claim`** — Its fix (a durable `unsaved-connection-at` key, plus marking every account written in that session as not updating) repairs consequences that no longer exist once nothing is written or requested before the Keychain read-back verifies.
- **`plain-token-field-macos-surfaces`** — Two parts rejected: "Pasted: 138 characters, ending 9F2A" still echoes four characters of a bearer credential — a count alone proves the paste; and grepping the savedState bundle cannot be an in-process XCTest, so it becomes an acceptance step instead.
- **`type-guess-holdings-arrive-too-late`** — Its suggestion of an `investments` case on `AccountType` is rejected — it would let the owner type an account into a state the engine has no rule for; `guess_class` plus the existing holdings test does the same job without touching the type enum.
- **`keychain-save-shows-read-wording`** — One part rejected: keeping a SHA-256 of the claimed token in memory to refuse a second claim. Once the retained claim replaces Connect with Retry and hides the field, a second claim of the same token is unreachable and the hash buys nothing.

## Test cases the implementation must satisfy

### 1. Guesser: unambiguous deposit and card names

**Setup.** AccountTypeGuess.guess with no institution names, on: "CHASE TOTAL CHECKING", "Capital One 360 Checking", "Chase Total Checking®", "CHECKING-4417", "TOTAL CHKG/4417", "SHARE DRAFT", "Discover Cashback Debit", "Ally Online Savings", "SHARE SAVINGS", "REGULAR SHARES", "12 MONTH CERTIFICATE", "PETTY CASH", "CHASE SAPPHIRE PREFERRED CARD", "Costco Anywhere Visa", "CREDIT CARD ...9921".

**Expected.** checking, checking, checking, checking, checking, checking, checking, savings, savings, savings, savings, cash, credit, credit, credit. Every one has guess_class nil.

### 2. Guesser: institution phrases are stripped before matching

**Setup.** guess("ALLIANT CREDIT UNION CHECKING ...4417", institutionNames: []); guess("NAVY FEDERAL CREDIT UNION - EVERYDAY CHECKING", institutionNames: ["Navy Federal Credit Union"]); guess("AMERICAN EXPRESS HIGH YIELD SAVINGS ...1234", institutionNames: ["American Express National Bank"]); guess("DISCOVER ONLINE SAVINGS", institutionNames: ["Discover Bank"]); guess("CARDINAL CHECKING ...4417", institutionNames: ["Cardinal Credit Union"]).

**Expected.** checking, checking, savings, savings, checking. In particular "CARDINAL" never produces a credit hit — matching is by token, never substring — and "credit union" is removed as a phrase before the token "credit" can be seen.

### 3. Guesser: two strong categories means ask, never a guess

**Setup.** guess on "SAVINGS SECURED VISA", "MONEY MARKET CHECKING", "VISA DEBIT ...4417", "AMERICAN EXPRESS HIGH YIELD SAVINGS" with institutionNames: [] (no institution to strip).

**Expected.** All four return no type and no class: guessed_type nil, guess_class nil, outcome .ask. None is typed savings, checking or credit.

### 4. Guesser: marketing words never guess on their own

**Setup.** guess on "PLATINUM SELECT 4417", "CHASE SAPPHIRE RESERVE", "CITI DOUBLE CASH ...4417", "CITI CUSTOM CASH", "BLUE CASH EVERYDAY ...41007", "CASH MAGNET", "TOTAL ACCESS ...1234", "Acct 4412", "Chase Freedom Unlimited", "Venture Rewards"; and guess("WELLS FARGO PLATINUM SAVINGS", institutionNames: ["Wells Fargo Bank"]).

**Expected.** The first ten all return .ask with guessed_type nil. "WELLS FARGO PLATINUM SAVINGS" returns savings — a weak marketing word neither guesses nor blocks. No input in this case ever returns cash or credit.

### 5. Guesser: never-money and loan names

**Setup.** guess on "FIDELITY CASH MANAGEMENT ...4412", "VANGUARD SETTLEMENT FUND", "SCHWAB BROKERAGE", "ROTH IRA", "MONEY MARKET FUND", "CHASE AUTO LOAN", "HELOC", "Sallie Mae Student Loan", and "WELLS FARGO STUDENT CHECKING".

**Expected.** The first five: guessed_type nil, guess_class "investment". The next three: guessed_type nil, guess_class "loan". "WELLS FARGO STUDENT CHECKING" returns checking with guess_class nil — the bare token `student` is not a loan word.

### 6. Guesser: folding, plurals, masks and punctuation

**Setup.** guess on "Cuenta Corriente", "Cuenta de Ahorros", "Tarjeta de Crédito", "FIDELITY GOVERNMENT CASH RESERVES", "Checking (…4417)", "SAVINGS xxxx1234", "Acct 4412".

**Expected.** checking, savings, credit, .ask (cash and reserve are both excluded words), checking, savings, .ask. Digit-only and mask tokens contribute no evidence; "ahorros"→"ahorro" and "reserves"→"reserve" through the trailing-s rule, while "access" in another name is left intact.

### 7. Holdings beat a keyword, and no type question is ever asked

**Setup.** Insert a simplefin account named "SimpleFIN Savings", balance 128,400.00, guessed savings, holdings_observed_at set and holdings_count 6 from a dated answer. Classify with the engine.

**Expected.** standing == .heldOut(.holdsInvestments); contributedCents == 0; the row shows "SimpleFIN Savings holds shares and funds, not money…"; the "Count this towards what I can spend" checkbox is absent; the four-way type picker is absent; the account is not named as making the total incomplete. Setting include_in_safe_to_spend = true changes nothing about the figure.

### 8. A keyword-backed guess counts, an unmatched one does not

**Setup.** Two simplefin accounts, both holdings_observed_at set, both USD, balance-dated today, user_type nil: "CHASE TOTAL CHECKING" $1,240.18 (guessed checking) and "SoFi Money" $3,500.00 (no guess). No bills.

**Expected.** Month figure = $1,240 (rounded down). Chase is counted(.fresh) and contributes 124018; SoFi is .heldOut(.typeNotSet), contributes 0, appears under the number, and the accounts screen shows "One account is waiting for you to say what kind it is. Until you do, its $3,500 isn't part of what you can spend."

### 9. A checking guess waits for an answer that lists holdings

**Setup.** A balances-only ingest creates "FIDELITY CASH MANAGEMENT ...4412" — for this case force the guesser to checking by using the name "FIDELITY PREMIUM CHECKING" — balance 18,412.66, holdings_observed_at NULL. Another account, Chase Checking $638, is counted. Classify.

**Expected.** The Fidelity row is .heldOut(.notLookedInsideYet), contributes 0, and reads "I haven't looked inside … yet …". Month figure is $638, not $19,050, and the total is marked incomplete. After a dated answer sets holdings_observed_at with an empty holdings array, the same account classifies as counted(.fresh) and the figure becomes $19,050.

### 10. A new account pulls its own transactions in the same run

**Setup.** transactions-pulled-at = 4 hours ago (so shapeNeeded returns .balancesOnly), budget fresh at 14 remaining. The balances answer contains one account the database has never seen.

**Expected.** The run does not stop after the balances step: fetchTransactions is entered, at least one dated request is spent, and holdings_observed_at is non-NULL for the new account when the run returns. With outcome.accountsInserted == 0 on an otherwise identical run, no dated request is spent.

### 11. A correction survives a later sync, and a rename never re-types

**Setup.** Account inserted on 15 Sep as remote_name "CHECKING ...4417", guessed_type checking, guessed_from_name "CHECKING ...4417". The owner sets user_type = .savings. On 8 Oct a balances sync sends remote_name "PLATINUM SELECT 4417" for the same conn_id/external_id.

**Expected.** After the sync: user_type is still .savings, guessed_type is still checking, guessed_from_name is unchanged, display_name is unchanged, and the contributed figure is identical to before the sync. With user_type instead left NULL, the same sync leaves guessed_type checking and the figure unmoved, and the row shows "Your bank now calls this account PLATINUM SELECT 4417. I've been counting it as checking — is that still right?"

### 12. The manual account the bank duplicates is not counted twice

**Setup.** Manual accounts: "Chase Checking" $1,200 (user_type checking) and "Cash" $60 (user_type cash). A first sync inserts "CHASE TOTAL CHECKING" $1,240.18 and "Ally Online Savings" $8,000. Bills: Rent $500 paid from the manual Chase row. Classify.

**Expected.** The manual Chase row has merge_candidate_for set to the synced row's id and standing .supersededPendingAnswer: contributes 0, and Rent $500 is still subtracted and named. The manual "Cash" row is never flagged (only stop tokens in its name). Month figure = 1240.18 + 60 − 500 = $800, never $2,000. On "Yes, the same account": the recurring_charge row's paying_account_id now points at the synced account, the manual row has archived_at and replaced_by set, the synced row's user_type is checking, and the figure is unchanged at $800.

### 13. Confirming a guess switches to the available balance and says so

**Setup.** "Chase Total Checking", balance_cents 120000, available_cents 94000, guessed checking, user_type nil, holdings_observed_at set. Bills $510 confirmed this month. The owner presses "Yes, that's right".

**Expected.** Before: contributed 120000, headline $690, and the confirm control shows "If you confirm this, I'll switch to the $940 …". After: user_type == .checking, contributed 94000, headline $430, and a line sits directly under the number reading "You confirmed Chase Total Checking is a checking account, so I've switched to the $940 … what you can spend went from $690 to $430 …".

### 14. The scheduler decides, for each last-sync time and budget

**Setup.** SyncPolicy table, isConnected true, no failures, requestsRemaining 14 unless stated. Rows: (a) balancesSyncedAt 5 h 15 m ago, trigger .scheduled; (b) same, trigger .launch; (c) balancesSyncedAt 6 h 30 m ago, trigger .launch; (d) attemptedAt 10 min ago, balancesSyncedAt 8 h ago, trigger .wake; (e) requestsRemaining 0, trigger .manual; (f) requestsRemaining 0, trigger .scheduled; (g) serverWarnedAboutTheRate true, trigger .manual; (h) transactionsPulledAt 25 h ago, balancesSyncedAt 7 h ago, trigger .scheduled; (i) isConnected false, trigger .scheduled; (j) failuresInARow 3, attemptedAt 90 min ago, balancesSyncedAt 9 h ago, trigger .wake.

**Expected.** (a) .sync(.balancesOnly) — the five-hour activity gate; (b) .skip("balances are recent") — launch stays at six hours; (c) .sync; (d) .skip("tried recently"); (e) .skip("no requests left today"); (f) .skip("no requests left today"); (g) .skip("SimpleFIN warned about the rate"); (h) .sync(.balancesAndTransactions); (i) .skip("no bank connected"); (j) .skip("tried recently") — back-off for three failures is 2 h.

### 15. Two triggers through the shared coordinator become one run

**Setup.** One SyncCoordinator instance, a stub client that suspends for 500 ms on /accounts. Fire syncIfDue(.scheduled), then 200 ms later fire the Refresh path (.manual) against the same instance. Read RequestBudget.remaining before and after.

**Expected.** remaining drops by exactly one for the balances step; the second call's report has joinedARunInProgress == true and the same outcome; the stub client saw exactly one balances request. The same test through two separately constructed coordinators must fail — it is the regression this guards.

### 16. The background activity always calls its completion handler

**Setup.** Drive the scheduler block with a credential store whose load() throws CredentialStoreError.keychain(errSecInteractionNotAllowed, while: .reading). Then repeat with a store that returns a credential and a client that throws SimpleFINFailure.couldNotReachServer(.offline), and again with a budget already at 14 spent.

**Expected.** In all three runs the completion handler is called exactly once, with .finished, and never with .deferred. The report in run one carries credentialProblem and the failure count is unchanged.

### 17. An offline wake costs no back-off and no false 'already refreshed'

**Setup.** NWPathMonitor reports .unsatisfied. Fire the .wake trigger. Then make the path .satisfied but the client throw .couldNotReachServer(.offline) and fire .wake again after the quiet period. Finally set the budget to 14 spent with balances-synced-at from yesterday 19:40 and press Refresh.

**Expected.** Run one: no request is reserved, no attempt is recorded, the trigger is dropped after the 60-second wait elapses. Run two: one request is reserved, sync-failures-in-a-row stays 0, sync-attempted-at is written. Refresh: the message is "I've used up today's requests to SimpleFIN, so I can't fetch anything new right now. The balances below are from yesterday evening." and never "Already refreshed today."

### 18. The setup screen's error paths, including the Keychain failure and Retry

**Setup.** (a) Paste "not-base64!!"; (b) claim returns 403 with no local attempt on record; (c) the claim POST throws URLError.timedOut, then Connect is pressed again; (d) claim returns 200 and save() throws .keychain(errSecUserCanceled, while: .writing); then press Try again with save() succeeding; (e) open the screen while load() returns a credential; (f) open the screen while load() throws errSecInteractionNotAllowed.

**Expected.** (a) "That doesn't look like a SimpleFIN setup token" and nothing from the field is in the message; no request is sent. (b) the compromise wording from SYNC.md. (c) the dropped-claim sentence, and Connect is disabled for that token; a subsequent 403 produces "That setup token has already been used — by this app, a few minutes ago…" and never the compromise wording. (d) the banner leads with "I claimed your setup token, so that token is used up now…", no /accounts request has been made and no account row exists; AppModel.unsavedConnection is non-nil; after Try again succeeds, the credential is in the store, connected-at is written, the scheduler is started and the first sync runs. (e) no field, "You're already connected to SimpleFIN…". (f) no field, "macOS wouldn't let me check your saved connection, so I won't replace it…", and save() is never called.

### 19. The two credential banners are distinct

**Setup.** Render the banner for a SimpleFINFailure carrying gen.auth with an empty accounts array, and the banner for CredentialStoreError.keychain(errSecInteractionNotAllowed, while: .reading).

**Expected.** Different titles, different bodies, different system images (exclamationmark.triangle.fill vs lock.fill). The gen.auth banner has exactly one button, "Paste a new setup token". The macOS banner has "Try again" and "Open Keychain Access", contains the words "Don't make a new setup token", and contains no control that opens the paste field.

### 20. A partial first sync is not an error

**Setup.** First connection, budget fresh. The balances answer carries three accounts. The walk fetches six windows and the seventh is refused with .backfillIsFullForToday; coveredBackTo is 2026-08-03.

**Expected.** report.balancesRefreshed true, report.failure nil, report.refusal == .backfillIsFullForToday, report.stillFillingHistory true, report.historyStopped == .budget, connectionIsWorking true, needsAttention false. The screen reads "I've got your accounts and balances, and your spending back to August 3. I'll fetch the older months over the next day or two…" and no error is shown next to any account. Requests spent: 7.

### 21. A history walk that ends because the bank has no more history

**Setup.** Same first connection, but windows 4 and 5 return no new rows so BackfillProgress.state becomes .exhausted at nextWindowIndex 5, coveredBackTo 2026-06-18. Separately, a window that throws SimpleFINFailure mid-walk while progress.state is still .running.

**Expected.** Case one: report.historyStopped == .noMoreHistory, stillFillingHistory false, and the screen reads "…back to June 18 — that's as far as your bank goes." and never promises to carry on tomorrow. Case two: stillFillingHistory is true even though refusal is nil.

### 22. One connection fails while another is fine

**Setup.** A sync answers with Ally's accounts fine and errlist [{"code":"con.auth","msg":"Connection to Chase requires re-authentication","conn_id":"CON-CHASE-1"}]; Chase Total Checking is still in the accounts array with balance 3160.00 dated today.

**Expected.** Chase's row reads "Not counted. Chase needs you to sign in again on the SimpleFIN website." and never "Your bank stopped sending new balances…". The line under the number quotes SimpleFIN's own words attributed to SimpleFIN. The accounts screen header names which connections updated and which did not. Ally's accounts still classify as counted(.fresh). No banner appears — this is not gen.auth.

### 23. An account that vanishes and then comes back

**Setup.** Chase Total Checking $3,160 balance-dated 06:12 today; bills $1,700 from it. The 12:14 sync returns Ally only. Then the 18:14 sync returns both.

**Expected.** After 12:14: standing .heldOut(.stoppedUpdating), the row reads "Chase Total Checking held $3,160 on September 15, and that's the last figure I have. It wasn't in what SimpleFIN sent at 12:14 today, so I've stopped counting it until it comes back.", and its bills are not subtracted. After 18:14: not_updating_since is NULL, resumed_updating_at is today, the account is counted, and a line under the number reads "Chase Total Checking is updating again. Its $3,160 is back in the figures, which is why what you can spend went from $0 to $1,460." The next calendar day the line is gone.

### 24. A non-USD account is never shown with a dollar sign

**Setup.** A simplefin account "Tangerine Savings", currency "CAD", balance 2400.00, alongside Chase Checking $612.40.

**Expected.** The row amount renders "CA$2,400.00" (en_US locale), the row sentence names Canadian dollars and warns against re-entering it by hand, the month figure is $612 and excludes it, and the string "$2,400.00" with a bare dollar sign appears nowhere on the screen.

### 25. Connected with no accounts, and putting an account away

**Setup.** (a) Claim succeeds, save verifies, /accounts returns {"errlist":[],"accounts":[],"connections":[]} with no accounts in the database. (b) Separately: Chase Total Checking $3,160 counted, Rent $1,500 and Internet $200 paid from it, month figure $1,460; the owner chooses Put away.

**Expected.** (a) The zero-accounts screen is shown with "Check again" and "Open the SimpleFIN website", the credential is kept, connected-at is written, and the words "generate a fresh one" appear nowhere. The accounts empty state reads "Add an account by hand, or connect your bank through SimpleFIN." (b) A confirmation appears first, containing $3,160, $1,700, $1,460 and "$0 (balance: −$1,700)", computed from the engine; cancelling leaves the figure at $1,460; confirming archives the row, leaves Rent and Internet subtracted, and shows the orphaned-bills line under the number.

## Open question for the owner

- PLAN decision 4 says keyword-backed account-type guesses count immediately. The holdings decision qualifies that for checking and cash guesses only: such a guess does not count until an answer that lists holdings has been seen for that account — normally the same sync, because a balances refresh that turns up a new account now carries on and fetches its transactions in the same run. In the rare case where that dated answer is refused by the budget or fails, a genuinely-checking account is visibly held out with a sentence for up to a day instead of counting. Confirm this narrow qualification, which is what stops an $18,412 brokerage sweep balance named "…CHECKING" from entering the headline as spendable money.
