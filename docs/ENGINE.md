# How Spendable works out what you can spend

This is the contract for the safe-to-spend engine. It is written out in full because every rule
here changes a number the owner acts on, and a silently wrong rule is worse than a missing feature.
`Tests/SpendableTests/SafeToSpendTests.swift` follows this document case for case, except that the
two month-end anchor cases are in `Tests/SpendableTests/RecurringChargeTests.swift` (February 28th
and 29th from a January 31st anchor), where the occurrence generator itself is tested.

An earlier draft of this document was reviewed before any of it was built, by five independent
readers working from the owner's specification, the plan and the schema. They found forty-two
problems in it. The rules below are the corrected ones; where a rule looks fussy, it is usually
because the draft version of it produced a wrong number in a case worth naming.

## Vocabulary

- **Day** — a calendar day in the owner's current calendar and time zone. Every date rule is in
  whole days, so a daylight-saving change cannot move a bill and a balance taken at 11pm is not a
  day older than one taken at 1am the same date. Days are `CalendarDay`; persisted day values are
  normalised to the start of the day before they are written.
  The single exception is deciding whether a balance was recorded before or after the owner said
  they paid a bill, which compares the two instants, because both can happen on the same day.
- **Obligation** — one dated amount the owner owes: one occurrence of a recurring charge, or (from
  milestone 6) one credit-card statement payment.
- **Window** — the span of days an obligation must fall in to count toward a figure.
- **Figure** — the calendar-month answer or the until-payday answer.

## One classification, used for everything

Every account is classified **once**, and that one value decides what it contributes, whether its
bills come off the number, and every sentence written about it. The total and the explanation are
therefore the same arithmetic by construction and cannot drift apart.

| Standing | When | Contributes | Its bills |
|---|---|---|---|
| Counted (fresh) | Everything below passes and the balance is recent | Yes | Subtracted |
| Counted (stale) | Same, but the balance is old enough to mention | Yes | Subtracted |
| Held out — stopped updating | Its feed has failed (`not_updating_since` is set), or the balance is over 7 whole days old | No | **Not** subtracted |
| Held out — savings not counted | Savings the owner has not opted in | No | Not subtracted |
| Held out — type not set | No type, guessed or confirmed | No | Not subtracted |
| Held out — not US dollars | Currency is not USD | No | Not subtracted |
| Held out — holds shares or funds | The bank reports holdings against it (`holdings_count` > 0) | No | Not subtracted |
| Credit card | Type is credit | Never | See the card rule |
| Archived | The owner put it away | No | **Subtracted**, and said so |

Order matters, and the order shipped today is: archived, then currency, then investments, then no
type, then credit, then the savings opt-in, then a dead connection, then age. Milestone 4 adds three
steps in front of and around investments; `docs/reviews/milestone-4-review.md`
(`holdings-before-a-guess-counts`) pins the final order — archived → superseded-pending-answer →
currency → loan → investments → not-looked-inside-yet → no type → credit → savings opt-in → not
updating → age — and none of those three new steps is built yet.

**Shares and funds are never money.** An account the bank reports holdings against is held out of
every total, whatever its name and whatever the owner has opted into, and no "count this" switch is
offered for it at all — offering one would be a control that does nothing, and would suggest a share
portfolio could become this month's spending money. The owner made this binding on 15 September
(`docs/PLAN.md` rule 11). The investments test is applied before the type test, the credit test and
the savings test, so neither an untyped share account nor a confirmed savings opt-in can reach past
it; that ordering is also what stops the app asking a question whose "credit" answer would print
"You owe $128,400" about a share portfolio. SimpleFIN carries no account type, so the number of
holdings is the strongest signal in the whole response that a balance is a market value: the public
demo's savings account holds six figures of Apple stock and is called "SimpleFIN Savings", so a name
alone would have made it spendable (`docs/reviews/milestone-3-review.md`,
`holdings-are-a-type-signal`). Its row reads: "Holds shares or funds, not money. What it's worth
moves with the market, so it's never counted towards what you can spend — there's no switch for this
one."

**Stale means**: over 3 whole days for a hand-entered balance, over 2 for a synced one. Over 7 for
either and the account stops counting. A balance dated in the future is treated as today.

**Stopped updating has two triggers, and they are not the same.** An account that vanishes from an
otherwise good response, or that carries an `act.*` or `con.*` error of its own, is marked as not
updating from that moment and stops counting immediately — it does not wait for its balance to age
out, and `classify` says so in its own comment. Separately, a balance over 7 whole days old stops
counting on age alone, even from a feed that is still answering. The first case is a dead connection
and the second is a stalled one, and they get different sentences (`docs/SYNC.md`, "When a
connection quietly dies").

**A held-out account's bills leave the number with it, and are disclosed with it.** Dropping an
account's money while still subtracting its bills is arithmetically indefensible: an eight-day gap
in one feed would turn $3,160 of real money into "you're $1,643 short". Both halves leave together,
and they are disclosed together (below). So a held-out account subtracts nothing: not its balance,
and not the bills paid from it. The two are shown as one block with its net, never as two unrelated
lines.

**Archived accounts are the exception**, in the other direction. Archiving is the owner's own
tidy-up action for an account they have closed. A closed account cannot pay anything, so a bill
still pointing at one is money that will come out of an account that *is* counted — it stays
subtracted, and the app says so and asks which account pays it now. An archived account is never
named under the number and never raises a warning.

**Which balance.** The bank's available balance is used only when the owner has **confirmed** the
account is a current account, never on a keyword guess, and never when it is larger than the plain
balance — a bigger "available" is the shape of a credit line, not money. The disclosure names which
one was used. An account marked as having its amounts reversed contributes the other sign.

## Which obligations are subtracted

Only charges with status `confirmed`. A `suggested` charge never moves a number; `dismissed` and
`cancelled` never count. A confirmed charge with no due date cannot be placed in any window, so it
is not subtracted and is named in the explanation.

An obligation is subtracted when the money leaves the pool the figure just added up:

- **No paying account named, or the account no longer exists** → subtracted. It still has to come
  from somewhere, and the only money on the table is money that is counted.
- **Paying account is counted** → subtracted.
- **Paying account is archived** → subtracted, and named.
- **Paying account is held out** → not subtracted, and disclosed with that account's balance.
- **Paying account is a credit card** → see the card rule.

**Transfers.** The transfer rule is settled before the paying account is looked at, so the rows
above do not apply to a transfer: only the destination decides. A charge of kind `transfer` is money
moving between the owner's own accounts, so what matters is where it lands. Into an account that is
counted, it is not subtracted — the total already counts both sides. Into savings that is not
counted, into any other held-out account, into a card, into an account the owner has archived, or
into an account that no longer exists, it is subtracted: the money has left. With **no destination
recorded** it is subtracted, and the app asks where it goes rather than guessing quietly.

A scheduled payment to an outside company — a phone bill on autopay, rent, a utility — is a **bill**
and is subtracted like any other. Being automatic does not make it stop being money leaving.

## Credit cards

At most one thing is counted per card per window, so a card's spending can never be counted twice.
In order:

1. **The card has a live statement** (a statement balance entered, due date not yet passed):
   subtract the statement payment. Bills charged to the card are listed, not subtracted.
   Unreachable today: the columns (`cc_statement_cents`, `cc_due_day`, `cc_minimum_cents`,
   `cc_statement_entered_at`) have existed since migration v1, but nothing writes them and
   `hasLiveStatement` is a stub that always answers no. Milestone 6 adds the entry UI, carries those
   values onto the classified account, and implements that one function; it adds no columns.
2. **No live statement, but a standing transfer pays the card**: that transfer is subtracted in
   whichever windows its own occurrences fall in, and the bills charged to the card are listed as
   counted through it in every window. The two are decided against different spans on purpose — the
   card is recognised as "paid by transfer" from the existence of the transfer, not from its dates —
   so a window the payment does not fall into counts nothing for that card. In the until-payday
   window that amount is still named by the hold-back sentence.
3. **Neither**: subtract the bills charged to the card at full value, each labelled as being on a
   card with no statement entered. Without this, four milestones would pass with a card's bills
   subtracted by nothing at all.

A card's balance is described only as debt owed and never enters a total. For every card with a
balance that is not zero, the app says: "You owe $1,180.00 on Chase Sapphire. No number here
subtracts that — tell me its statement balance and the day it's due and I'll count the payment." A
card with a zero balance is not mentioned. From milestone 6 the sentence is skipped for a card whose
statement has been entered and whose due date has not passed, because the payment is then counted.

## Turning a recurring charge into dated occurrences

Two dates, doing two different jobs:

- **`anchor_date`** is the charge's first occurrence. It is written once and never rewritten.
  Occurrence *k* is always the anchor plus *k* steps, clamped to the length of the month it lands
  in at the moment it is worked out. A clamped value is never stored.
- **`next_expected_date`** is the **paid-through marker**: everything before it is settled,
  everything from it onward is still owed. Marking a bill paid moves it to the next anchor-derived
  occurrence strictly after it — never to "the old marker plus one step".

Keeping them apart is what stops a bill due on the 31st from drifting. Measured from the anchor,
January 31st goes to February 28th and back to March 31st. Stepping one month at a time from each
result, it would go to February 28th and stay on the 28th for good, three days early, forever.

Occurrences in a window run **forward only** from the marker. Stepping backwards could only ever
reach dates the marker says are already paid, so it would re-subtract paid bills and marking a bill
paid would never change the number at all. Consequences worth stating:

- Rent paid for October has a marker of October 1, so the September window contains nothing.
- A bill forgotten since June contributes exactly one occurrence to September, not four.
- A bill due on the 5th and not yet marked paid is still subtracted, and reads "was due September 5.
  I'm still subtracting it until you mark it paid."

Steps: weekly 7 days, biweekly 14 days, monthly 1 month, quarterly 3 months, annual 12 months.

## When the owner says they have paid a bill

Marking a bill paid moves the marker, which takes it out of the window. But the money leaves the
account before the balance in the app catches up, so doing only that would raise the number by the
bill's amount at the exact moment the owner became poorer.

So the action asks one question: **"Have you already taken this off the balance it came out of?"**

- **Yes** → nothing more to do.
- **No** → the bill keeps being subtracted until a balance for that account arrives that was
  recorded strictly after the moment it was marked. It is dated the day it was marked, or the first
  day of the window if it was marked earlier than that, and it is listed separately under its own
  total: "You've already paid $500.00 of this, and I'm still counting it: Rent $500.00 — you told me
  you paid this on September 1, and the Chase Checking balance I have still includes it." When the
  charge names no paying account the same line reads "…and the balance I have still includes it."
  Three cases end the retention early: the balance catching up, the paying account ceasing to be
  counted (its bills leave with its money, as above), and the mark falling after the end of the
  window being worked out.

## The calendar-month figure

> Everything counted, minus every obligation dated anywhere in this calendar month.

Window: the first of the month through the last day of the month.

The window starts on the 1st, not today, so a bill that was due on the 5th and has not been paid
stays subtracted. Dropping it would inflate the number in exactly the situation where the owner can
least afford it.

## The until-payday figure

> The same money, minus every obligation from the first of this month through the day before the
> next payday.

Paydays fall every 14 days from an anchor day the owner gives. The next payday is the first one
**strictly after** today, so on payday itself the figure looks ahead to the following one rather
than covering zero days.

The window can cross into the next month: on September 28 with a payday of October 3 it runs
September 1 to October 2, and so includes October's rent, which the month figure excludes.

**Per-day allowance** = what is left ÷ days from today inclusive to payday exclusive, rounded down,
shown to the cent. When the remainder is positive but the daily share rounds to nothing, the app
says nothing about a daily share rather than saying "$0 a day".

**Bills after payday are named, not hidden.** For most of the month the until-payday window is a
strict subset of the month window, so the until-payday figure is the *larger* of the two — that is
the point of it. What makes that honest rather than misleading is that the bills falling between
payday and the end of the month are named with their total in the same sentence: "Then $142.00 more
is due before the month ends (Car insurance, September 28)." With two or three bills it becomes
"(Car insurance, Verizon; the first on September 28)", and with more than three "(Car insurance,
Verizon, Gym and 2 more; the first on September 28)" — at most three are named, largest first.
Neither figure is ever shown without its window: "Safe to spend this month (Sep 1–Sep 30)" and
"Until payday (October 3)". The month label abbreviates the month at both ends; every other sentence
in the app spells it out in full ("September 28").

**Pay that has landed but is not in the balance.** When the newest counted balance predates the most
recent payday, the figure says so instead of reading as a shortfall the owner does not have: "Your
pay from September 25 isn't in these balances yet — the newest balance here is from September 24."
In that state part 3 leads with the cause and then gives the arithmetic, and the bare "You're $X
short" sentence is not rendered at all (`docs/reviews/milestone-2-review.md` §15).

## Neither figure counts a paycheck you have not been paid

Money arrives when it arrives. The explanation says so in as many words.

## When there is no answer

The engine never answers "$0" to mean "I don't know". Nothing left and no idea are different things
and the owner acts differently on each.

- **No accounts at all** → no figure. "I don't know yet. Add an account and I'll work out what you
  can spend."
- **Accounts exist but not one can be counted** → no figure. "I can't work this out right now,"
  then one line per account saying what it last held and when. No per-day allowance, no shortfall
  sentence, no "$0" anywhere. An account the owner has put away is not among those lines. The menu
  bar will show the icon and a warning and no number; that surface is milestone 7 and is not built —
  today the menu bar is a placeholder icon with an "Open Spendable" item. This holds however little
  the held-out accounts contain: accounts that exist but cannot be counted mean the app does not
  know, even when every one of them is empty and owes nothing.

## Showing a figure

- Whole dollars, **rounded down**, so a headline is never a cent more generous than the truth.
- An amount **under a dollar is shown to the cent** ("$0.75"), so real money never reads as the
  same "$0" the shortfall state uses.
- **Below zero is shown as `$0 (balance: -$121)`**, with the shortfall rounded **away** from zero
  so it is never understated, and shown to the cent when it is under a dollar
  (`$0 (balance: -$0.40)`). The minus sign is whatever the owner's locale uses, not a typographic
  minus. Being short of the month's bills is debt, not spending money. The per-day allowance in that
  state is $0. The explanation says "You're $121 short of this month's bills."
- Nothing left and not short is the only state that reads "$0.00". A bare "$0" appears nowhere on
  its own: it exists only as the first half of the shortfall headline, which always carries its
  parenthetical.
- Everywhere with room, a number appears inside a sentence. The compact form for the menu bar and
  the small widget carries the shortfall in brackets with a warning mark ("$0 (-$121) ⚠");
  `SafeToSpendDisplay.compact` already produces it and is covered by tests, but nothing renders it
  yet — the menu bar is milestone 7 and the widget is milestone 8.

## The explanation

Rendered from the engine's own output, never re-derived by a view.

1. **What you have.** Composed from what actually contributed, never a fixed phrase: "You have
   $1,290.00: $1,200.00 in checking, $40.00 in cash and $50.00 in Ally Savings, which you asked me
   to count." Amounts in the explanation are exact cents — the headline is the only place that
   rounds — and the list is joined "a, b and c", with no comma before "and". Counted savings is
   always named separately, because it is the opt-in part. With one account the summary line is
   dropped. Then one line per account, biggest first, with the balance term glossed and the day
   given by `AsOf.dayPhrase` — "today", "yesterday", a weekday, or a date, never "this morning",
   which is false for a balance stamped at 6pm today: "Chase Checking $1,200.00 — what your bank
   says is free to spend right now, which leaves out payments that haven't finished going through,
   as of today." A synced account whose plain balance was used reads "— your bank's balance, which
   may not have caught up with payments still going through, as of yesterday."; a hand-entered one
   reads "— the amount you entered by hand, as of Tuesday."
2. **What's still due.** Two totals, never one. First what was subtracted, with its own total and a
   dated line each. Then, separately, what the owner has already paid but is still being counted.
   Then, separately again, bills that are due but did **not** come off the number, each with its
   reason. The numbers on the screen add up.
3. **The answer.** Exact cents, because this is the disclosure and not the headline. Six forms:
   "That leaves $630.00." (month) / "That leaves $630.00 to last until September 25 — about $57.27 a
   day." (payday; the daily clause is dropped entirely when the share rounds to nothing while money
   is left) / "That leaves $0.00 — nothing left." / "That leaves the whole $3,120.00 — but only
   because nothing has been subtracted." / "You're $121 short of this month's bills." (the payday
   figure says "short of the bills due before your payday on October 9") / and, whenever the figure
   has any held-out account behind it, the same shortfall sentence prefixed "Of the accounts I can
   see, you're $121 short of this month's bills." `docs/reviews/milestone-2-review.md` §16 asked for
   four forms in whole dollars; the cents here are deliberate (`Cents.swift`) and the code is what
   the tests pin, so the document was corrected rather than the code. One line reverses it if the
   owner prefers the review's wording.
4. **What I left out.** Accounts that were held out, each shown as one block with its own bills and
   the net of the two — never as two unrelated lines. Two kinds of block also appear on the line
   directly under the number, where a caveat cannot be missed: every account whose feed has stopped,
   whatever its net, because a healthy-looking figure over data that died is the failure this app
   most has to avoid; and any other held-out block whose net is negative, because a clean figure
   with a hole behind it is worse than an untidy one. A block shown under the number is also listed
   here, so the same sentence appears twice on the Overview screen. Then any account whose
   "available" balance was ignored for looking like a credit line, cards with a balance and no
   statement, bills still pointing at an account the owner has put away, bills with no due date,
   and always: "This doesn't count your next paycheck." (the payday figure says "This is only money
   you have now. Your paycheck on October 3 isn't part of it.").

Each figure has its own sentences. The month figure never says "payday" and the payday figure never
says "this month".

When the owner has entered no bills at all, part 2 says so rather than printing "$0 of bills are
still due": "You haven't told me about any bills yet, so I haven't subtracted anything. Until you
add your rent and the bills that come out automatically, this number is just what's in your
accounts." That reads
very differently from "None of your bills are due between now and the end of the month", which is
what it says when bills exist but none falls in the window.

## Where the arithmetic happens

`SafeToSpendEngine.compute` is pure: accounts, charges, a pay schedule, and today, in; a figure and
its explanation, out. It opens no database, reads no clock and imports no GRDB, so every rule above
is tested with literal days and amounts and no test needs a database.

The account table is a handful of rows and is fetched whole. The specification's rule that totals
are SQL aggregates governs the **transaction** table, which is never read into memory, in this
milestone or any later one.

Each screen observes the narrowest query it needs. The figure is recomputed when accounts, charges,
the pay schedule or settings change — and when the calendar day rolls over, which writes nothing to
the database and so is driven by `NSCalendarDayChanged` (with time-zone and wake notifications),
never by a polling timer.
