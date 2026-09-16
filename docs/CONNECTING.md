# Connecting a bank, and keeping it connected

Milestone 4 implements the setup screen, account questions, connection explanations and automatic
refresh described here. This is the current behavior contract, not a record of completed acceptance
checks. Build results, measurements and release status belong in [HANDOFF.md](HANDOFF.md) and
[README.md](../README.md).

[PLAN.md](PLAN.md) contains the owner's binding decisions. The
[milestone 4 review](reviews/milestone-4-review.md) supplies the detailed algorithm, 27 decisions and
25 acceptance cases. Its safety rules supersede the original design. The owner subsequently
approved **safe recovery of a rejected credential in milestone 4**: the rejection banner now leads
to a working repair flow. Changing an existing **working** connection remains milestone 9.
The [milestone 3 review's first-request safeguard](reviews/milestone-3-review.md) still applies:
a credential that has never been accepted is diagnosed separately, without automatically asking
the owner to burn another token.
[SYNC.md](SYNC.md) governs requests and ingestion; [ENGINE.md](ENGINE.md) governs arithmetic.

## Pasting a setup token

The Connect your bank screen first checks the saved connection. A failed Keychain read is never
treated as an absent credential. A working connection shows no token field:

> You're already connected to SimpleFIN. Changing a working connection comes in a later version.

A failed read shows no field either:

> macOS wouldn't let me check your saved connection, so I won't replace it. Unlock your login
> keychain and open this again.

An initial connection, or a rejected connection being repaired, offers a `SecureField`, an explicit
**Show** toggle and a **Paste** button. The confirmation contains only a count: "Pasted — 138
characters." Validation requires base64 decoding to an HTTPS URL with a host, before any request.
Invalid input reads "That doesn't look like a SimpleFIN setup token." Errors never echo the token.

While this screen is visible, the implementation sets the window's `sharingType = .none` and
`isRestorable = false`; OS screen-capture protection has not been verified. Writing Tools and
autocorrection are disabled on the field. Connecting, cancelling or leaving the screen clears the
text and field editor's undo actions and resigns first responder. This bounds references to pasted
text; it does not promise zeroing of Swift's immutable string storage. The claim result remains a
credential, handled separately below.

The first step reads "Asking SimpleFIN for your accounts…". Until the Keychain write is read back
and verified, a first connection sends no `/accounts` request and writes no account row.
`AppModel.unsavedConnection` retains a claimed credential for the process lifetime if saving fails.
The same banner appears on every screen, with **Try again** and **Open Keychain Access**:

> I claimed your setup token, so that token is used up now — don't make another one yet. macOS
> wouldn't let me save the connection, but I still have it. Unlock your login keychain and press
> Try again. Don't quit Spendable until this works: if you quit, the connection is lost and you'll
> need a new setup token.

Retry saves this retained credential; it never claims the token again. The field and Connect button
stay hidden while it is retained. Closing a window does not lose it. Quitting asks:

> Your bank connection isn't saved yet. If you quit now it's gone and you'll have to make a new
> setup token on the SimpleFIN website.

The buttons are **Quit anyway** and **Keep Spendable open**. Successful saving records
`connected-at`, starts scheduling and starts the first sync.

When a claim is interrupted, the field has already been cleared and Connect is disabled until new
text is entered. The app keeps only the attempt time, never the token or a hash of it:

> I couldn't reach SimpleFIN, so I don't know whether that setup token was used or not. Don't press
> Connect again with this one — if it did go through, it's already spent. Make a fresh setup token
> on the SimpleFIN website and paste that instead.

A 403 within an hour of a local attempt uses `ConnectionPresentation.locallyUsedToken`, explaining
that this app may have spent it when the connection dropped. Without a recent local attempt,
[SYNC.md](SYNC.md)'s existing explanation applies. Subscription and server errors retain
SimpleFIN's own words, attributed as plain text.

## A saved connection that needs attention

| State | Title and icon | Actions |
|---|---|---|
| SimpleFIN rejects a previously accepted credential | "Your bank connection has stopped working"; `exclamationmark.triangle.fill` | **Paste a new setup token** |
| SimpleFIN rejects a newly saved credential before accepting it | First-request diagnostic, distinct from a previously working connection dying | **Try again**, or explicitly confirmed **Replace anyway…** |
| macOS refuses the read | "macOS won't let me open your saved connection"; `lock.fill` | **Try again**, **Open Keychain Access** |

The rejection body reads:

> SimpleFIN won't accept the connection Spendable saved, so no new balances are coming in. Make a
> new setup token on the SimpleFIN website and paste it here.

The macOS body reads:

> Your connection is still saved — macOS wouldn't let me read it. Unlock your login keychain and
> press Try again. Don't make a new setup token: you don't need one.

There is no paste action on the macOS banner. A temporary read refusal does not erase the separate
fact that SimpleFIN rejected a credential; after unlocking, repair remains available.

A rejection before a newly saved credential has ever succeeded uses the earlier review's diagnostic:

> SimpleFIN rejected the credential I just stored. This is a bug in Spendable, not a problem with
> your token — don't generate another one.

The credential stays saved. The setup screen shows no paste field and makes no claim that the
connection is working. **Try again** or **Check again** uses the saved credential. Deliberate
recovery is still possible through **Replace anyway…**, but first the app explains that retrying
needs no new token, that a replacement token will be spent, and that the current credential remains
saved until the replacement is verified. Only **Replace the saved connection** records that choice
and opens the paste field; **Keep the saved connection** changes nothing. This distinction and the
owner's choice survive restart and temporary Keychain refusals.

Repair preserves accounts, history and owner corrections. The coordinator pauses new runs and
waits for the current run before changing credentials. The replacement is staged inside the same
encrypted Keychain item while ordinary reads still return the original. The staged payload is read
back and verified, then one Keychain update promotes it. A failed stage or promotion leaves the
original active and the new claim retained for Retry. Retry recognises an already-promoted
credential if later database bookkeeping failed. Successful saving clears the durable rejection
marker without requiring another request to fit today's budget. An old run's report cannot restore
the repaired connection's rejection banner. Working connections do not offer replacement.

## Accounts and past spending arriving

A successful connection says "Connected. I found 3 accounts." History progress gives a date,
never a window fraction:

> Getting your past spending — I've gone back as far as August 3 so far. You don't need to wait
> for this.

When its request allowance is spent:

> I've got your accounts and balances, and your spending back to August 3. I'll fetch the older
> months over the next day or two. Nothing here is waiting on you.

`SyncReport.historyStopped` distinguishes `budget`, `failed`, `noMoreHistory` and
`reachedThirteenMonths`. Bank exhaustion says "that's as far as your bank goes"; the app's own
limit says "that's the thirteen months of history this app keeps". A restarted history walk counts
successfully returned transactions even when they are already stored, so replay does not falsely
mean the bank has no older history. A failed window leaves progress
resumable. A budget stop after balances arrive is a working connection, not a failed one. Progress
is observed during foreground and scheduled refresh, without polling.

An empty, error-free account response keeps the credential and has its own state:

> Connected — your setup token worked and I've saved the connection. SimpleFIN didn't send any
> accounts, which usually means no bank is linked to your SimpleFIN account yet, or one is still
> being set up. Go to the SimpleFIN website, link a bank, then press Check again. Don't make another
> setup token: this one is working.

The actions are **Check again** and **Open the SimpleFIN website**. The accounts empty state reads
"Add an account by hand, or connect your bank through SimpleFIN."

## Deciding which balances count

`AccountTypeGuess.guess(remoteName:institutionNames:)` uses the server's name, never the owner's
rename, balance sign or available balance. It normalises names, strips institution words, matches
whole tokens and phrases, and asks when strong categories conflict. Exact word lists and worked
names are in review decision 1 and `AccountTypeGuess.swift`. Marketing words such as platinum,
sapphire, discover, everyday and bare cash never establish a type. Digit-only tokens are ignored;
consequently the legacy `457` and `529` entries alone cannot match.

Guess and source name are stored on insertion. Later bank renames do not re-type accounts. Owner
choices survive every sync. Holdings are the deliberate exception to the initial class: observing
any holdings marks investments permanently. Loans and investments offer no type picker or switch.

| Outcome | Effect |
|---|---|
| Loan | Never counted; no type question; does not make the total incomplete |
| Investment name or observed holdings | Never counted, even after an earlier opt-in; no switch |
| Checking or cash guess | Counts its balance only after a dated answer carried a holdings key, even empty |
| Savings | Excluded unless opted in; a synced account's switch waits for holdings observation |
| Credit guess | Never counted as money held; asks whether the guess is right |
| No type | Excluded and named; the total is incomplete until the owner answers |

An investment says:

> SimpleFIN Savings holds shares and funds, not money. What it's worth goes up and down with the
> market, so I never count it — there's no switch for this one.

A checking or cash guess awaiting a dated answer says:

> I haven't looked inside Fidelity Cash Management yet, so I don't know whether it holds money or
> shares and funds. I'll know once I've fetched its transactions — usually within a few minutes,
> and by tomorrow at the latest.

A balances refresh that inserts an account therefore continues into transaction fetching in that
run, subject to budget. PLAN rule 11 approves this safer holdings gate. An owner-confirmed type
bypasses the observation gate, but never the investment rule.

Unknown accounts ask "What kind of account is SoFi Money? I can't count it until I know." A
negative balance sharpens the question without storing a type:

> TOTAL ACCESS 1234 is $47.20 in the red. Is this a credit card, or a checking account that's
> overdrawn?

The four type buttons include `AccountType.gloss`. The summary names what counted and what was
left out: "One account is waiting for you to say what kind it is. Until you do, its $3,500 isn't
part of what you can spend."

Guesses show **Is this right?**, **Yes, that's right** and **No, it's something else**. Confirming
checking can unlock the available balance, so the control explains the change first:

> If you confirm this, I'll switch to the $940 your bank says is free to spend right now instead
> of its $1,200 balance. The $260 difference is payments that haven't finished going through.

The before/after figure then appears under the number until the next successful balances sync or
another local change alters the computed result, so an old explanation cannot describe a new total.
An available amount above the balance remains ignored. **Amounts look reversed** is permanent and
is never offered for credit, where debt uses the balance's magnitude. A card mistaken for a deposit
exposes its whole balance as money; the available-balance gate is a separate protection.

Non-USD accounts stay out of every total and display their own currency, such as "CA$2,400.00" on
an en_US Mac. Their explanation names the currency and warns that adding it by hand as dollars
would make the figure wrong. Nothing converts currencies implicitly.

## Duplicate manual accounts, silence and archiving

On inserting a synced account, ingestion compares its normalised name with active manual accounts,
ignoring generic account words. A possible duplicate puts the manual row in
`supersededPendingAnswer`: no contributed balance, but its bills remain subtracted and named. The
question above the rows offers **Yes, the same account** and **No, two different accounts**, and
explains that both balances are never added while the answer is pending.

Yes uses one transaction to preserve owner metadata on the synced row, move the bills, archive the
manual row, set `replaced_by`, and record the answer. The success message reads:

> I'll use your bank's figures from now on, and I've kept the name, type and bills you set up.
> Your hand-entered Chase Checking is put away.

An inherited checking type also explains any available-balance change. Since `display_name` and
`cc_has_credit_balance` are non-nullable, an unchanged bank-supplied name is available for
inheritance, and the card flag is inherited only when the synced row has no owner type or statement
details. Existing corrections are kept. No clears the candidate and records the answer: "I'll
count both from now on." An answered pair is not offered again.

Every balance is dated: "as of today", "as of Thursday", or an older calendar date. An old manual
balance says "You last updated this on September 3. Update it and I'll count it again." An old
synced balance says "Your bank stopped sending new balances on August 14, so I don't know what's
in it now."

A missing account stops counting immediately after an otherwise good sync. Its row names the last
balance date and the check in which it vanished; its bills follow ENGINE.md's held-out rule. A
return records `resumed_updating_at` and is explained under the number for that calendar day. The
message includes before/after figures when the old figure is known; otherwise it says the app can
work it out again instead of inventing a zero.

A connection-level error is different from a missing account. Its row can say "Not counted. Chase
needs you to sign in again on the SimpleFIN website." The line under the number attributes
SimpleFIN's message. The accounts header names which connections updated and which did not, while
healthy accounts keep counting. Dated connection/account errors merge and deduplicate their notices with balance errors and leave
that history window retryable. Persisted `connection-notices` preserve these explanations across
restarts; `con.*` does not create the whole-credential banner.

**Put away** asks for confirmation with engine-derived balance, bill names, bill total and
before/after figure. A $3,160 balance with $1,700 of bills shows the move from $1,460 to
"$0 (balance: -$1,700)", with the locale's minus sign. Cancelling changes nothing. Confirming
hides the account while its orphaned bills stay subtracted and are named under the number. The
manual editor has no separate unconfirmed removal action.

## Schema and automatic refresh

The forward-only `v4-account-type-guess` migration adds exactly six nullable account columns:
`guessed_from_name`, `guess_class` (loan or investment), `holdings_observed_at`,
`resumed_updating_at`, `merge_candidate_for` (account foreign key), and `merge_answered_at`.
Connection notices and rejection state use existing `sync_state`; there are no other M4 schema
changes. Classification order is:

archived → superseded-pending-answer → currency → loan → investments → not-looked-inside-yet →
no type → credit → savings opt-in → not updating → age.

`AppModel` owns one `SyncCoordinator`, shared by setup, Refresh, the demo driver, launch, wake, day
change and one retained `NSBackgroundActivityScheduler`. Concurrent triggers join one run. The
activity identifier is `com.nullterminater.spendable.sync`, with a six-hour interval, one-hour
tolerance and utility quality of service. Every callback finishes exactly once with `.finished`,
including errors and refusals; never `.deferred`.

- The budget is **14 requests per rolling 24 hours**, with at most **6** history requests. A
  reservation is made before sending and is not refunded on network failure.
- Scheduled, wake and day-change checks are due at five hours; launch waits at least six hours.
  The earlier activity gate makes opportunistic early fires useful.
- Automatic triggers obey a thirty-minute quiet period after any attempt and failure backoff.
  Manual refresh bypasses age/backoff gates, but respects budget and server rate warnings.
- Launch, wake and day-change checks wait up to sixty seconds for an online network path. Timeout drops the trigger
  without an attempt or request. An actual offline request still records both, but does not
  increase the server-failure backoff.
- Balances come every run. Transactions are normally daily; new accounts force a dated fetch in
  that run so holdings can be inspected.
- Scheduling starts after a verified connection, or on launch when `connected-at` exists. Routine
  scheduling uses that fact, not old account rows or repeated Keychain probes. Opening setup
  reconciles an already-saved credential if a crash happened before `connected-at` was written,
  without spending another token. `stopScheduling()` invalidates the
  activity, removes observers and clears connection/attempt/failure state for the later disconnect UI.
- The API cannot express a fixed minute. Its tolerance allows coalescing; the app adds no repeating
  timer, minute offset, top-of-hour skip or short rescheduling loop.

Budget exhaustion uses the last successful balance date. If no refresh succeeded today it says
"I've used up today's requests to SimpleFIN, so I can't fetch anything new right now", followed
by the balances' date, rather than claiming it already refreshed today.

## Verification boundaries

Automated cases use in-memory databases, synthetic accounts and stub network/credential stores.
`AccountConnectionTests`, `AccountPresentationTests`, `ConnectionFlowTests`, coordinator tests and
the existing suites cover migration, arithmetic, retained claims, recovery, shared runs and the
review's failure paths. The real field's Paste/Show/Cancel behavior, keyboard paste, window privacy,
quit interception and rendered account states also require app acceptance checks using synthetic
values or the public demo. Real credentials, balances and account numbers never belong in fixtures,
screenshots or profiling artifacts. Test counts, acceptance results and performance measurements
are recorded with the release, not inferred from the presence of tests.


## Synthetic replay in a Debug build

Set both `SPENDABLE_DEBUG_CONTAINER` to a fresh scratch directory and
`SPENDABLE_DEBUG_FIXTURE` to one of these values. This selects an in-memory credential store
(or a synthetic read-refusing store for `locked`), never the real Keychain item. Set
`SPENDABLE_DEBUG_SCREEN=connect` or `accounts` and `SPENDABLE_DEBUG_OPEN_WINDOW=1` to open the
relevant screen. These are environment switches, not an in-app Debug menu.

| Fixture | Purpose |
|---|---|
| `setup` | Empty masked token field and validation |
| `accounts` | Duplicate question, guessed checking, unknown type, savings, non-USD account and one bill |
| `rejected` | Repair of a previously rejected saved connection |
| `fresh-rejected` | First-use rejection warning and deliberate replacement confirmation |
| `locked` | Keychain refusal; retries continue to refuse without offering a field |
| `unsaved` | Retained claim and quit warning |
| `empty` | Saved connection with no accounts |

Replay credentials point to a reserved `.invalid` host. These fixtures exercise the interface;
network outcomes and replacement failure injection are covered by the stubbed tests instead.
