# Connecting a bank, and keeping it connected

> **Superseded in part, and not yet implemented. Read `docs/reviews/milestone-4-review.md` first.**
> This was the design for milestone 4. It was then reviewed before implementation, and the review
> overruled several of its rules: the account-type keyword table, the balance-sign hint, the
> "holdings beat every keyword" claim, what a guess may do to the number, the paste field, the
> "window 3 of 11" progress sentence, the scheduler's fixed random minute, and "nothing is
> scheduled until a credential exists". The review's 27 decisions are the rule set to implement;
> where it and this document disagree, the review wins. The passages below have been rewritten to
> carry the review's rules, so this file can be read on its own again — but the review is still the
> authority, and it holds the word lists and the worked test cases this file deliberately does not
> repeat.
>
> **Milestone 4 is half built as of 16 September 2026.** Built: `AccountTypeGuess`, `SyncState` /
> `SyncPolicy`, `SyncCoordinator`, and the rule that an account holding shares is never counted.
> Not built: the setup screen, both credential banners, the scheduler, the type controls, migration
> v4, the manual-to-synced merge, and every owner-facing sentence quoted below. Ingestion still
> writes `guessed_type = NULL` (`Sources/Spendable/SimpleFIN/SimpleFINIngest.swift:287`), so no
> synced account has a type today. Everything below in the present tense is intended behaviour, not
> behaviour you can run. `docs/HANDOFF.md` lists what remains, in order.

The contract for milestone 4: how the owner attaches their bank, how the app decides what kind of
account each one is, what it says when a balance goes quiet, and how often it asks. `docs/SYNC.md`
covers what happens on the wire; this covers what the owner sees and what the app does on its own.

## Pasting a setup token

One screen, one field. The owner makes a token on the SimpleFIN website and pastes it here.

- The field is a `SecureField` with an explicit "Show" toggle the owner must press. The paste is
  proved by a line under the field that contains none of the value: "Pasted — 138 characters." Not
  the last four characters; a count alone proves the paste, and four characters of a bearer
  credential are still four characters of a bearer credential.
- A visible "Paste" button sits beside the field, reading `NSPasteboard.general.string(forType: .string)`,
  so the screen does not depend on an Edit ▸ Paste key equivalent that `SpendableApp` — a
  `MenuBarExtra` with no `.commands { }` — may not provide. Verify ⌘V on the real build during
  acceptance, before a real token is ever in the clipboard.
- While the setup screen is up: `window.sharingType = .none` and `window.isRestorable = false`, so
  the token is not in screenshots, screen recordings, Screen Sharing sessions, or the saved-state
  bundle AppKit writes on the next ⌘Q. On the field: `.writingToolsBehavior(.disabled)`,
  `.autocorrectionDisabled()`, no `textContentType`. On success or cancel: clear the state, call
  `removeAllActions()` on the window's field editor's `undoManager`, and resign first responder.
- `docs/SYNC.md`'s memory promise is a lifetime bound, not erasure: nothing keeps a reference to the
  pasted text after the claim returns. A Swift `String` has immutable copy-on-write storage and no
  zeroing API, so promising erasure would be a promise the language cannot keep.
- **What they pasted is never echoed back to them in an error.** "That doesn't look like a SimpleFIN
  setup token" is the whole message. A setup token is a bearer credential; repeating it into an
  alert puts it somewhere it can be screenshotted.
- It is validated before a byte goes out: base64, decoding to an `https` URL with a host
  (`SimpleFINClient.claimURL`).
- Connecting shows what is happening in order, in sentences, never a spinner and never a fraction:
  "Asking SimpleFIN for your accounts…", then a date. A window count is a fact about the app, not
  about the owner's bank, and "window" is jargon with no gloss on the same screen. In progress:
  "Getting your past spending — I've gone back as far as August 3 so far. You don't need to wait for
  this." When the day's history budget runs out: "I've got your accounts and balances, and your
  spending back to August 3. I'll fetch the older months over the next day or two. Nothing here is
  waiting on you." When the bank has no more history, or thirteen months is reached: "I've got your
  accounts and balances, and your spending back to August 3 — that's as far as your bank goes." The
  date comes from `BackfillProgress.coveredBackTo` / `history_coverage_start`, which are already
  stored.
- Telling those two endings apart needs one more change to `SyncCoordinator`, not built: `SyncReport`
  gains `enum HistoryStop { case noMoreHistory, reachedThirteenMonths, budget, failed }` and a
  `historyStopped: HistoryStop?` derived from `BackfillProgress.state` and the refusal. (The other
  half of that review decision — a failed window reporting the walk as finished — is fixed.)

Outcomes, in the owner's words:

| What happened | What they read |
|---|---|
| Worked, with accounts | "Connected. I found 3 accounts." and the accounts screen |
| Worked, no accounts (200, empty `accounts`, empty `errlist`) | "Connected — your setup token worked and I've saved the connection. SimpleFIN didn't send any accounts, which usually means no bank is linked to your SimpleFIN account yet, or one is still being set up. Go to the SimpleFIN website, link a bank, then press Check again. Don't make another setup token: this one is working." Buttons "Check again" and "Open the SimpleFIN website" |
| Token already used, no local attempt on record | "This setup token was already used or doesn't exist. If you didn't use it in another app, someone else may have — disable it on the SimpleFIN website, then generate a fresh one." |
| Claim dropped in flight | "I couldn't reach SimpleFIN, so I don't know whether that setup token was used or not. Don't press Connect again with this one — if it did go through, it's already spent. Make a fresh setup token on the SimpleFIN website and paste that instead." Connect is disabled for that token |
| 403 within an hour of a local claim attempt | "That setup token has already been used — by this app, a few minutes ago, when the connection dropped. It's spent and it can't be reused. Make one new setup token on the SimpleFIN website and paste it here. Nothing has gone wrong with your bank and there's nothing to disable." |
| Keychain refused the write | The retained-claim banner: "I claimed your setup token, so that token is used up now — don't make another one yet. macOS wouldn't let me save the connection, but I still have it. Unlock your login keychain and press Try again. Don't quit Spendable until this works: if you quit, the connection is lost and you'll need a new setup token." Buttons "Try again" and "Open Keychain Access" |
| Keychain refused the read, on a second visit | No field and no Connect button: "macOS wouldn't let me check your saved connection, so I won't replace it. Unlock your login keychain and open this again." `save()` is never called |
| Already connected, on a second visit | No field and no Connect button: "You're already connected to SimpleFIN. Changing the connection comes in a later version." Re-connecting is milestone 9; nothing in milestone 4 ever calls `save()` over an existing item |
| No internet | "I couldn't reach SimpleFIN. Check your internet connection." |
| Subscription lapsed (402) | What was observed, plus SimpleFIN's own words, attributed |
| Budget spent mid-history | "I'll carry on filling in your history tomorrow" — the connection is fine |

A history walk that stops on budget is **not** a failed connection. The accounts and balances are
already in; the app says so rather than showing an error next to a bank that is working.

Until the Keychain write has been read back and verified, the app makes no `/accounts` request and
writes no account row. A connection that is not saved is not a connection. The claim result lives
only in memory, on `AppModel.unsavedConnection`, and the only thing Retry does is attempt the
Keychain write again; on success the first sync then runs normally.

One code change belongs with this screen: `MainWindowView.swift`'s empty state still reads "Add an
account by hand to start. Connecting your bank through SimpleFIN comes in a later step." It is true
today and becomes false the moment the setup screen ships, so it changes in the same commit, to "Add
an account by hand, or connect your bank through SimpleFIN."

## Deciding what kind of account each one is

SimpleFIN does not say. It gives a name, a balance and a currency, so the app guesses — and the
specification is explicit that getting this wrong silently is worse than asking.

**State, 16 September 2026.** The guesser itself is built and tested
(`Sources/Spendable/SimpleFIN/AccountTypeGuess.swift`, `Tests/SpendableTests/AccountTypeGuessTests.swift`)
and is a pure function with no database, clock or network. It is **not wired into ingestion**:
`SimpleFINIngest.upsertAccount` still inserts every new row with `guessed_type = NULL`
(`SimpleFINIngest.swift:287`), and there is no UI control for the owner to set a type on a synced
account. Until both are done, every synced account is held out as `.typeNotSet` and the rest of this
section describes intended behaviour. Wiring it in needs migration v4 first (review decision 3),
because the guess is stored with `guessed_from_name` and `guess_class`, which the schema has no
columns for.

**The name is the evidence, matched as whole words.**
`AccountTypeGuess.guess(remoteName:institutionNames:)` is a pure function over `remote_name` exactly
as the server sent it — never `display_name` (the owner's rename must never re-type an account),
never the balance, never `available_cents`.

It normalises once: compatibility mapping; diacritic-, case- and width-insensitive folding under
`en_US_POSIX`; every character that is not a–z or 0–9 becomes a space; digit-only and mask tokens
(`4417`, `xxxx1234`, `****`) are dropped because they say which account, never what kind; and a
trailing `s` comes off tokens of five characters or more that do not end in `ss`, so `savings` and
`saving` are one word while `access` and `business` are untouched. It then removes the phrases
`federal credit union` and `credit union` — as phrases, before any matching, so `credit` can never
survive out of `credit union` and turn a credit union's current account into a card — and then the
tokens `bank`, `banking`, `na`, `fsb`, `fcu`, `cu` and every token of the institution's own name.

Matching is **never** by substring: `contains("card")` must not fire on `cardinal`. Multi-token
phrases match first, longest first, consuming their tokens, so `money market fund` wins over
`money market` and `credit card` is never read as two separate words.

Six lists are matched in this order: never-money (class `investment`), loan (class `loan`),
checking, savings, cash, credit. Tie-breaks, in order: (a) any loan hit means class `loan` and no
type; (b) any never-money hit means class `investment` and no type; (c) hits in two or more of
checking/savings/cash/credit mean no type, ask; (d) exactly one of those means that type; (e) no hit
means no type, ask. Two strong categories is not a close call to be settled by precedence — "Savings
Secured Visa" is a card and "Money Market Checking" is a current account, and no ordering gets both
right. Asking costs a click; guessing costs the owner money.

The words themselves — the six lists, the never-a-keyword exclusion list (platinum, select,
signature, preferred, world, elite, gold, blue, freedom, venture, quicksilver, sapphire, reserve,
reward, cashback, cash back, discover, cash, everyday, total, access, advantage, premier, plus, one,
360, essential, complete, secure, high yield, online, free, student, business) and the 25 worked
answers the tests reproduce — are decision 1 of `docs/reviews/milestone-4-review.md`, and
`AccountTypeGuess.swift` is the second copy. Do not write a third here and let them drift.

One trap inside the lists themselves: digit-only tokens are dropped by normalisation, so the
review's `529` and `457` entries can never match — "529 COLLEGE SAVINGS" is typed **savings** today
and would be offered the count-towards-spending switch. Anything spelled with a letter (`401k`,
`403b`) survives and does match. If a digit-led never-money name is ever to be caught, it has to be
caught as a phrase over surviving tokens ("college saving", "deferred comp"), never by putting a
bare number back into a list normalisation has already thrown away.

The table this document carried until 15 September 2026 is deleted rather than corrected. It had
four word lists, no algorithm and no precedence, and its own lists typed a credit card as a deposit
account: `cash` was listed as cash evidence, so "CITI DOUBLE CASH" — a card — would have been typed
cash and its balance counted as money the owner has; and platinum, sapphire, rewards and discover
were listed as credit evidence although all four sit on deposit products ("Wells Fargo Platinum
Savings", "Discover Online Savings").

**The balance sign is not an input at all.** It may never write `guessed_type` and may never
corroborate one. `AccountTypeGuess.guess` takes no balance and must not gain one: the protocol
defines no sign convention for what an account owes, real feeds differ by bank, and an overdrawn
current account and a card look identical from the sign alone. Promoting a guess on the sign is a
verdict, not a hint — a mistyped overdrawn current account would contribute nothing, raise no
question, leave the total looking complete, and print "You owe $47".

A negative balance makes the *question* sharper instead, rendered live from the current balance and
stored nowhere: "TOTAL ACCESS 1234 is $47.20 in the red. Is this a credit card, or a checking
account that's overdrawn?" — with the same four buttons as any untyped account.

**Holdings are the truth about an account, but they arrive late.** An account the bank reports
holdings for is investments whatever it is called, is never counted, and has **no opt-in switch
anywhere** — offering one would be a control that does nothing, and would suggest a share portfolio
could become this month's spending money (`SafeToSpend.swift`'s `classify`, `MainWindowView.swift`'s
`offersTheSavingsSwitch`). The demo shows why: its savings account holds $115,385.51 with a holding
called "Shares of Apple" and is named "SimpleFIN Savings", so a name-based guess alone would have
turned a share portfolio into spendable money that moves with the market.

But holdings cannot protect the *first* classification. They are recorded only from an answer that
lists them, and a dated answer cannot create an account (`SimpleFINIngest.swift`), so every account
has `holdings_count = 0` at the instant it is first typed. Three things close that window, and all
three are review decision 4:

- A **dated** answer that carried a `holdings` key, empty or not, stamps `holdings_observed_at`. A
  balances-only answer never stamps it: it returns an empty holdings array for every account, which
  is the same shape as an account that genuinely holds none.
- A balances refresh that turns up an account the app has never seen carries on and fetches that
  account's transactions in the same run, because that answer is the only one that says whether the
  account holds money or shares.
- Until that stamp exists, a `checking` or `cash` **guess** does not count. It is held out as
  `HeldOutReason.notLookedInsideYet` and the total is marked incomplete: "I haven't looked inside
  Fidelity Cash Management yet, so I don't know whether it holds money or shares and funds. I'll
  know once I've fetched its transactions — usually within a few minutes, and by tomorrow at the
  latest." A confirmed `user_type` bypasses this gate entirely.

Classification order, pinned: archived → superseded-pending-answer → currency → loan → investments →
not-looked-inside-yet → no type → credit → savings opt-in → not updating → age. `loan` is
`guess_class == 'loan'`; investments is `guess_class == 'investment' || holdings_count > 0`.
Investments sits **above** "no type" and above credit: that is what makes "never counted even if the
owner opts in" true for an account nobody has typed, and what stops the app asking a question whose
"credit" answer would print "You owe $128,400 on SimpleFIN Savings". As of 16 September 2026 the
shipped order is archived → currency → investments → no type → credit → savings opt-in → not
updating → age; `loan`, `superseded-pending-answer` and `not-looked-inside-yet` do not exist yet, and
there is no `holdings_observed_at` column.

**What a guess is allowed to do**, one rule per outcome of the guesser:

- `loan`: `guessed_type` NULL, `guess_class = 'loan'`. Contributes nothing. Never asks for a type
  and never offers the four-way picker. Row: "Chase Auto Loan is money you owe, not money you have,
  so it isn't counted here." Does not make the total incomplete — nothing is missing.
- `investment`: `guessed_type` NULL, `guess_class = 'investment'`. Contributes nothing, ever, and
  there is no opt-in. Row: "Fidelity Cash Management holds shares and funds, not money. What it's
  worth goes up and down with the market, so I never count it — there's no switch for this one."
  Does not make the total incomplete.
- `checking` or `cash`: `guessed_type` written. Counts at `balance_cents` as soon as
  `holdings_observed_at IS NOT NULL`, badged with "Is this right?". Never uses `available_cents` —
  that stays gated on a confirmed `user_type == .checking`.
- `savings`: `guessed_type` written, held out as savings-not-counted. The "Count this towards what I
  can spend" checkbox is drawn only when `holdings_observed_at IS NOT NULL AND guess_class IS NULL`.
- `credit`: `guessed_type` written. Contributes nothing. While `user_type` is NULL the row and the
  disclosure use the guess wording, not milestone 6's statement prompt: "I think CHASE SAPPHIRE
  PREFERRED CARD is a credit card, going by its name, so I'm not counting it as money you have. It
  shows $1,180 owed. Is that right?"
- no type (ask): `guessed_type` NULL, `guess_class` NULL. Held out, named under the number, total
  marked incomplete. Row: "What kind of account is SoFi Money? I can't count it until I know." plus
  the four buttons carrying `AccountType.gloss`.

Two things to record so the next reader does not re-derive the wrong safeguard. The exposure from a
card guessed as a deposit account is **its whole balance appearing as money the owner has**, not its
credit limit; the available-balance rule below is a separate and smaller protection. And
`amounts_reversed` is a no-op for anything typed credit, because the card sentence takes
`.magnitude` (`MainWindowView.swift`'s `balanceSentence`) — it must never be offered to the owner as
the fix for a wrong type.

None of these controls exists yet. `AccountRow` renders the type as static text and the only type
picker in the app is inside `ManualAccountForm`, reachable only for hand-entered accounts, so today
an untyped synced account can never be answered and never counts. The four-way picker, the "Is this
right?" badge and the confirm control are review decisions 2 and 14, and are unbuilt.

**A correction is permanent.** It is stored separately from the guess and the guess never overwrites
it, so a later sync cannot undo it. The same is true of a renamed account, an "amounts look
reversed" correction, and the savings opt-in.

**The bank's available balance is only used once the owner has confirmed the account is a current
account** — `user_type == .checking`, never a guess. An available balance *larger* than the balance
is ignored even then and reported as ignored, because that is the shape of a credit line
(`SafeToSpend.swift`'s `classify`, and PLAN's binding decision on the sign).

Because this rule is gated on confirmation, **confirming a guess moves the number**, and the app has
to say so before and after. The control reads "Is Chase Total Checking a checking account — money
you spend from day to day?" with "Yes, that's right" and "No, it's something else". When
`available_cents` is present and differs from `balance_cents`, print under the Yes button *before*
it is pressed: "If you confirm this, I'll switch to the $940 your bank says is free to spend right
now instead of its $1,200 balance. The $260 difference is payments that haven't finished going
through." After it is pressed, as a line directly under the number until the next sync: "You
confirmed Chase Total Checking is a checking account, so I've switched to the $940 your bank says is
free to spend right now. That's why what you can spend went from $690 to $430 — the $260 is payments
that haven't finished going through." Otherwise agreeing with the app makes the owner poorer and
nothing says why. Not built.

### What the accounts screen says it left out

A summary at the top of the accounts screen, composed from what actually happened, never a fixed
phrase: "Two of your five accounts are in what you can spend: Chase Total Checking and Cash. Ally
Online Savings isn't, because you haven't asked me to count savings. SoFi Money isn't, because I
don't know what kind of account it is. Chase Freedom is a card, so what's on it is money you owe."

Directly above it, whenever any account has no type: "One account is waiting for you to say what
kind it is. Until you do, its $3,500 isn't part of what you can spend." — the count and the amount
come from the engine's held-out blocks and the plural agrees. This is the sentence this document
means by "the app says the total is incomplete" and PLAN means by "a banner counting unconfirmed
accounts". No bare percentage, and no judgement about the owner's money.

Not built: the accounts screen has no summary today, and no string anywhere says a total is
incomplete.

## The account you added by hand that your bank has now sent

Evaluated once, at the moment a simplefin row is INSERTED: for every non-archived `source = 'manual'`
account, normalise both names with the guesser's normalisation (institution tokens **not** stripped)
and drop the stop tokens checking, chequing, saving, cash, card, credit, account, my, the, bank. If
at least one token remains in both and any token is shared, set the manual row's
`merge_candidate_for` to the new synced row's id. Matching generously is deliberate: a false
positive holds money out with a sentence, a false negative doubles the headline.

While it is unanswered (`merge_candidate_for IS NOT NULL AND merge_answered_at IS NULL`) the manual
row takes a new standing `.supersededPendingAnswer` whose arithmetic is exactly the archived rule —
it contributes nothing, **and its bills keep being subtracted and are named**. It must not use
ordinary held-out semantics, which would stop subtracting Rent and push the headline *up* by $1,500
at the moment the owner is being asked a question.

Above both rows: "You added Chase Checking by hand, and your bank has now sent an account with
almost the same name. Are these the same account? Until you tell me, I'm counting only the $1,240.18
your bank sent — never both, so this number can't be doubled." Buttons: "Yes, the same account" and
"No, two different accounts". Under the number while it waits: "$1,200 in your hand-entered Chase
Checking isn't counted while I wait to hear whether it's the same account as the one your bank sent.
The bills you pay from it are still being subtracted."

On "Yes", in one write transaction: copy the manual row's `display_name`, `user_type`, `cc_due_day`,
`cc_minimum_cents`, `cc_statement_cents`, `cc_statement_entered_at`, `cc_has_credit_balance` and
`include_in_safe_to_spend` onto the synced row wherever the synced row's value is NULL;
`UPDATE recurring_charge SET paying_account_id = <synced id> WHERE paying_account_id = <manual id>`;
set the manual row's `archived_at` and `replaced_by = <synced id>`; set `merge_answered_at`. Then
say: "I'll use your bank's figures from now on, and I've kept the name, type and bills you set up.
Your hand-entered Chase Checking is put away." If the copied `user_type` is checking, append the
available-balance sentence from the confirm-a-guess rule, because inheriting a confirmed type is
what unlocks `available_cents`.

On "No": set `merge_answered_at`, clear `merge_candidate_for`, and say "I'll count both from now on."
The pair is never re-offered.

Not built: no `merge_candidate_for` / `merge_answered_at` columns, no `.supersededPendingAnswer`
standing, no screen. Nothing in the engine deduplicates today, so two Chase Checking rows both
contribute. PLAN's milestone 4 item D already promised this.

## An account that goes quiet

The engine already decides what counts (`docs/ENGINE.md`); this is what the owner reads.

Each account row says when its balance is from, in words, and never claims a time of day the balance
date does not carry: "as of today", "as of yesterday", "as of Thursday" within the last six days,
then "as of Sep 3" (`AsOf.dayPhrase`, `Sources/Spendable/UI/AsOf.swift`). The sentences under the
number use the longer form from `CalendarDay.shortPhrase` — "September 3". Two formatters is
deliberate: the row is a caption and the disclosure is prose.

Past a few days the row says so. Past a week it stops counting and says that too — and the cause is
named under the number, where there is room for a sentence:

- Hand-entered: "$1,200 in Cash isn't counted. You last updated it on September 3."
- Synced, balance genuinely old: "$3,160 in Chase Total Checking isn't counted. Your bank stopped
  sending new balances on August 14, so I don't know what's in it now."
- Synced, vanished from an otherwise good sync while the balance is still recent — a different cause
  and not yet written: "Chase Total Checking held $3,160 on September 15, and that's the last figure
  I have. It wasn't in what SimpleFIN sent at 12:14 today, so I've stopped counting it until it
  comes back." Without this, the one synced sentence names a balance date that is *today* and says
  the bank has stopped sending balances, in the same breath.
- On the return: set `resumed_updating_at` in the same statement that clears `not_updating_since`,
  and show a line under the number for the rest of that calendar day: "Chase Total Checking is
  updating again. Its $3,160 is back in the figures, which is why what you can spend went from $0
  to $1,460." Without it, the figure jumps between two glances at the same screen with nothing on it
  to account for the change.

The account row itself is one sentence for every cause today — "Not counted. Nothing new since
Sep 3." (`MainWindowView.swift`'s `standingSentence`) — and does not distinguish the owner's stale
hand entry from their bank's silence. The vanished and resumed cases are review decision 21, and
neither is built.

An account that **vanishes from an otherwise good sync** is marked as not updating from that moment,
not after its balance ages out. That is the failure the specification names: other apps have shipped
a green tick over data that stopped a month ago.

**One connection fails, the others are fine.** SimpleFIN reports trouble per connection, in
`errlist` codes beginning `con.`, while still answering for everything else — and ingestion already
marks those accounts as not updating. These accounts must never get the generic stopped-updating
sentence, because their balance is from today and their bank has not stopped sending balances.

On the row of every account of a troubled connection: "Not counted. Chase needs you to sign in again
on the SimpleFIN website." Under the number: "$3,160 in Chase Total Checking isn't counted, because
Chase needs you to sign in again on the SimpleFIN website. SimpleFIN said: 'Connection to Chase
requires re-authentication.' I'll start counting it again on the next check after you've done that."
— the server's words as plain text, attributed, per `docs/SYNC.md`. At the top of the accounts screen
when some connections answered and others did not: "Your Ally accounts updated at 12:14 today. Your
Chase accounts didn't — see the note on each of them."

This is not the credential banner: a `con.*` code is one bank, `gen.auth` is the whole connection.
Not built. Review decision 13, blocking.

Two credential states produce two banners. They must never look alike, and the macOS one must carry
no control that leads to the paste field.

**Credential rejected** — a `gen.auth` code from a server that actually answered. Icon
`exclamationmark.triangle.fill`, orange. Title: "Your bank connection has stopped working". Body:
"SimpleFIN won't accept the connection Spendable saved, so no new balances are coming in. Make a new
setup token on the SimpleFIN website and paste it here." One button: "Paste a new setup token". When
the server supplied its own words, they are appended as plain text, attributed, exactly as
`SimpleFINFailure.ownerFacingMessage` already does.

**macOS refused the Keychain read** — icon `lock.fill`, never the exclamation mark the other one
uses. Title: "macOS won't let me open your saved connection". Body: "Your connection is still saved
and your SimpleFIN setup token is still good — your Mac's login keychain is locked, so I can't read
it. Unlock it and press Try again. Don't make a new setup token: you don't need one." Buttons: "Try
again" and "Open Keychain Access". No control anywhere on this banner leads to the paste field.

A third banner, the retained unsaved claim, is in "Pasting a setup token" and leads with the spent
token.

`CredentialStoreError` now records which way the keychain was being used when it refused, so the
read sentence and the save sentence are already distinct at the source
(`CredentialStore.swift`'s `Operation`). Neither banner **view** is built: there is no banner view
anywhere in `Sources/`.

An account can be put away. Archiving hides it from the accounts list and from every total, but its
bills keep being subtracted — a closed account cannot pay anything, so that money comes out of an
account that is counted, and the app says so rather than deciding quietly.

Because it is the only action in milestone 4 that can move the number by an account's whole balance,
the context-menu "Put away" action confirms first, with the arithmetic in the sentence and every
figure computed from the engine before and after, never hard-coded: "Put Chase Total Checking away?
Its $3,160 stops counting straight away. The $1,700 of bills you pay from it keeps being subtracted,
because that money still has to come from somewhere — so what you can spend goes from $1,460 to
$0 (balance: -$1,700) until you tell me which account pays Rent $1,500 and Internet $200 now. You
can bring the account back later." Buttons "Put it away" and "Cancel". Immediately afterwards, as a
line under the number: "Rent $1,500 and Internet $200 still come out of Chase Total Checking, which
you've put away. Tell me which account pays them now."

Not built: there is no "Put away" action and no confirmation. The only archive path today is
`ManualAccountForm`'s "Remove this account", which is reachable for hand-entered accounts only and
is worded as a removal.

**An account that isn't in dollars.** The owner's binding decision excludes any non-USD account from
every total, and the engine does that already. `Cents.format` takes a currency at the display edge
and `AccountRow` passes `account.currency`, so a Canadian balance renders "CA$2,400.00" rather than
"$2,400.00" beside a caption saying it isn't counted — that part is done. What is not built is the
wording: the row sentence should replace "Not in US dollars, so it isn't counted." with "Tangerine
Savings holds 2,400.00 Canadian dollars. I only work in US dollars and I won't guess an exchange
rate, so this one stays out of every total. Adding it by hand as dollars would make what you can
spend wrong, so I'd leave it as it is." Under the number: "Tangerine Savings isn't in the figures
above, because it's in Canadian dollars." Review decision 18.

## How often the app asks

One scheduler for the whole app. No polling, nothing that wakes the process when nothing has
changed, and everything inside the budget in `docs/SYNC.md` (14 requests in a rolling day, of which
6 may be history).

- **One coordinator.** There is exactly one `SyncCoordinator` in the process. `AppModel` holds
  `private(set) var syncCoordinator: SyncCoordinator?`, created where the database is opened and
  handed to the scheduler block, the Refresh button, the launch poll and the wake and day-change
  observers. No other code constructs one — `DebugLaunchOptions.swift` builds its own today and must
  be changed to take the shared instance. `SyncCoordinator.inFlight` is an instance property, so two
  instances share no single-flight state, and an actor only serialises calls to itself.
- **One `NSBackgroundActivityScheduler`**, a stored property of `AppModel` with identifier
  `com.nullterminater.spendable.sync`, created once, never a local, `invalidate()`d before release —
  a deallocated scheduler stops firing. Interval 6 hours, tolerance 1 hour, utility quality of
  service. The system coalesces it with other work rather than waking the Mac for it.
- **The activity block always finishes.** It is exactly:

      scheduler.schedule { completion in
          Task { [coordinator] in
              defer { completion(.finished) }
              _ = await coordinator.syncIfDue(trigger: .scheduled)
          }
      }

  `completion(.finished)` is called on every path — a credential problem, a budget refusal, a
  `SimpleFINFailure`, a decode failure — because `syncIfDue` never throws and `defer` covers all of
  them. `.deferred` is never returned: a refusal or a failure is a reason to wait for the next
  interval, not to run again sooner. `NSBackgroundActivityScheduler` does not reschedule until the
  handler is called, so a handler that runs only on the success path means one locked keychain stops
  syncing forever, silently, on an app that opens at login and is never relaunched.
- **The app does not choose its own fire time.** `NSBackgroundActivityScheduler` has no phase, start
  date or fire-time property — the first fire is relative to the `schedule(_:)` call and the system
  then slides it within the tolerance. The hour of slack is what scatters the request away from the
  top of the hour, which the Bridge asks for; there is nothing else to implement. Never use a
  `Timer`, a `DispatchSourceTimer` or a re-`schedule` with a computed short interval to manufacture
  a fixed minute. `docs/SYNC.md`'s "at a fixed minute chosen away from the top of the hour"
  describes an intent the API cannot express, and the tolerance delivers it in practice. Review
  decision 27 also rejected the enforcement half — a persisted minute offset, and skipping fires
  near the hour.
- **Balances are due at five hours and the system is asked for them at six with an hour of slack, so
  a fire that lands early is used rather than thrown away.**
  `SyncPolicy.balancesStaleAfterForActivity` is 5 hours for the `.scheduled`, `.wake` and
  `.dayChanged` triggers; `.launch` and `.manual` keep `balancesStaleAfter` at 6 hours, because
  `docs/SYNC.md` pins the launch rule at six. `quietAfterAnyAttempt` (30 minutes) already stops the
  looser gate stacking requests.
- **On launch, only if the last successful balances read is six hours old or more.** Opening the app
  ten times in an afternoon costs nothing. (`SyncPolicy.balancesStaleAfter`, and the comparison
  is `>=`.)
- **On wake and on the day changing**, only if a sync is already overdue, and never within thirty
  minutes of any previous attempt (`SyncPolicy.quietAfterAnyAttempt`), so ten wakes in an evening
  are one check. The gate for these triggers is five hours, not six — see the bullet above.
- **Not before the network is there.** One `NWPathMonitor`, started once alongside the coordinator.
  On a `.wake` or `.launch` trigger, if `currentPath.status != .satisfied`, wait for the first
  `.satisfied` update for up to 60 seconds and then call `syncIfDue`; if it has not become satisfied
  within 60 seconds, drop the trigger entirely — the next one will come.
  `NSWorkspace.didWakeNotification` is posted the instant the lid opens, seconds before Wi-Fi
  associates, and the request is reserved before it is sent.
- **An offline attempt is not a failure.** `SyncCoordinator.recordFailure()` does not increment
  `sync-failures-in-a-row` when the failure is `.couldNotReachServer(.offline)`: the server did not
  fail and the Mac was not online. `sync-attempted-at` still throttles, so nothing is uncapped.
- **Manual refresh** runs while budget remains, and otherwise says why. When the day is full and
  `balances-synced-at` is not from today, the message is "I've used up today's requests to
  SimpleFIN, so I can't fetch anything new right now. The balances below are from yesterday
  evening." — the last clause rendered by `AsOf` — never "Already refreshed today", which would be
  false on a day that has refreshed nothing.
- **Lifecycle.** `startScheduling()` is called at the end of the first successful connection — the
  same step that writes `sync_state` key `connected-at` — and at start-up when `connected-at` is
  present. `stopScheduling()` calls `invalidate()`, releases the instance and clears `connected-at`,
  `sync-failures-in-a-row` and `sync-attempted-at`; milestone 9's disconnect UI is its only caller.

Not built: there is no `NSBackgroundActivityScheduler` anywhere in `Sources/`, `AppModel` holds no
coordinator, `SyncPolicy` has no `balancesStaleAfterForActivity` (one 6-hour constant serves every
trigger), `syncIfDue` is called by no production code, the only wake observer in the app
(`SpendableStore.swift`) recomputes the figure and never syncs, there is no Refresh button, and there
is no `NWPathMonitor`. Review decision 15, blocking.

Balances are cheap and come every time. A full transaction pull happens once a day, because
SimpleFIN itself only collects from banks about once a day: asking more often cannot produce newer
numbers, and the specification says so.

Nothing is scheduled until the database says a connection exists — `sync_state` key `connected-at`,
never a Keychain read. Asking macOS whether a credential is there would turn a locked login keychain
into an app that silently stops scheduling anything, and would raise a password prompt from an app
with no window. `SyncPolicy.isConnected` should be that key's presence and nothing else: the
`COUNT(*) FROM account WHERE source = 'simplefin'` fallback in `SyncState.load` must go, because
account rows are never deleted, so with it `isConnected` can never become false again and a future
disconnect would leave the activity firing every six hours forever. To keep that safe, any sync that
completes a balances read writes `connected-at` if it is absent, in the same transaction as
`balances-synced-at`.

The rule has a mirror: the credential first exists on the setup screen, so the first successful
connection calls `startScheduling()` itself, in the same step that writes `connected-at`. An app
with no bank connected does no work; an app that was connected at 14:10 does not wait for the next
launch.
