# How Spendable works out what you can spend

This is the contract for the safe-to-spend engine. It is written out in full because every rule
here changes a number the owner acts on, and a silently wrong rule is worse than a missing feature.
`Tests/SpendableTests/SafeToSpendTests.swift` follows this document case for case.

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
| Held out — stopped updating | Balance over 7 whole days old | No | **Not** subtracted |
| Held out — savings not counted | Savings the owner has not opted in | No | Not subtracted |
| Held out — type not set | No type, guessed or confirmed | No | Not subtracted |
| Held out — not US dollars | Currency is not USD | No | Not subtracted |
| Credit card | Type is credit | Never | See the card rule |
| Archived | The owner put it away | No | **Subtracted**, and said so |

Order matters: archived, then currency, then no type, then credit, then savings opt-in, then age.

**Stale means**: over 3 whole days for a hand-entered balance, over 2 for a synced one. Over 7 for
either and the account stops counting. A balance dated in the future is treated as today.

**Held out accounts keep their bills.** Dropping an account's money while still subtracting its
bills is arithmetically indefensible: an eight-day gap in one feed would turn $3,160 of real money
into "you're $1,643 short". Both halves leave together, and they are disclosed together (below).

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

**Transfers.** A charge of kind `transfer` is money moving between the owner's own accounts, so
what matters is where it lands. Into an account that is counted, it is not subtracted — the total
already counts both sides. Into savings that is not counted, into a card, or into an account that
no longer exists, it is subtracted: the money has left. With **no destination recorded** it is
subtracted, and the app asks where it goes rather than guessing quietly.

A scheduled payment to an outside company — a phone bill on autopay, rent, a utility — is a **bill**
and is subtracted like any other. Being automatic does not make it stop being money leaving.

## Credit cards

Exactly one thing is counted per card per window, so a card's spending is counted once and never
twice. In order:

1. **The card has a live statement** (a statement balance entered, due date not yet passed):
   subtract the statement payment. Bills charged to the card are listed, not subtracted.
   Unreachable before milestone 6, which adds those fields.
2. **No live statement, but a standing transfer pays the card**: subtract that transfer. Bills
   charged to the card are listed as counted through it.
3. **Neither**: subtract the bills charged to the card at full value, each labelled as being on a
   card with no statement entered. Without this, four milestones would pass with a card's bills
   subtracted by nothing at all.

A card's balance is described only as debt owed and never enters a total. Whenever a card has no
live statement the app says: "You owe $1,180 on Chase Sapphire. No number here subtracts that —
tell me its statement balance and the day it's due and I'll count the payment."

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
- **No** → the bill keeps being subtracted, dated on the day it was marked, until a balance for that
  account arrives that was recorded after the moment it was marked. It is listed separately, under
  its own total: "You've already paid $500 of this, and I'm still counting it: Rent $500 — you told
  me you paid this on September 1, and the Chase Checking balance I have still includes it."

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
payday and the end of the month are named with their total in the same sentence: "then $142 more is
due before the month ends (car insurance, Sep 28)." Neither figure is ever shown without its
window: "Safe to spend this month (Sep 1–30)" and "Until payday (Oct 3)".

**Pay that has landed but is not in the balance.** When the newest counted balance predates the most
recent payday, the figure says so instead of reading as a shortfall the owner does not have: "Your
pay from Sep 25 isn't in these balances yet — the newest balance here is from Sep 24."

## Neither figure counts a paycheck you have not been paid

Money arrives when it arrives. The explanation says so in as many words.

## When there is no answer

The engine never answers "$0" to mean "I don't know". Nothing left and no idea are different things
and the owner acts differently on each.

- **No accounts at all** → no figure. "I don't know yet. Add an account and I'll work out what you
  can spend."
- **Accounts exist but not one can be counted** → no figure. "I can't work this out right now,"
  then one line per account saying what it last held and when. No per-day allowance, no shortfall
  sentence, no "$0" anywhere. The menu bar shows the icon and a warning, and no number.

## Showing a figure

- Whole dollars, **rounded down**, so a headline is never a cent more generous than the truth.
- An amount **under a dollar is shown to the cent** ("$0.75"), so real money never reads as the
  same "$0" the shortfall state uses.
- **Below zero is shown as `$0 (balance: −$121)`**, with the shortfall rounded **away** from zero
  so it is never understated, and shown to the cent when it is under a dollar. Being short of the
  month's bills is debt, not spending money. The per-day allowance in that state is $0. The
  explanation says "You're $121 short of this month's bills."
- A bare "$0" therefore has exactly one meaning: nothing left, and not short.
- The menu bar and the small widget carry the shortfall in brackets and a warning mark; everywhere
  with room, a number appears inside a sentence.

## The explanation

Rendered from the engine's own output, never re-derived by a view.

1. **What you have.** Composed from what actually contributed, never a fixed phrase: "You have
   $1,290: $1,200 in checking, $40 in cash, and $50 in Ally Savings, which you asked me to count."
   Counted savings is always named separately, because it is the opt-in part. With one account the
   summary line is dropped. Then one line per account, with the balance term glossed: "Chase
   Checking $1,200 — what your bank says is free to spend right now, which leaves out payments that
   haven't finished going through, as of this morning."
2. **What's still due.** Two totals, never one. First what was subtracted, with its own total and a
   dated line each. Then, separately, what the owner has already paid but is still being counted.
   Then, separately again, bills that are due but did **not** come off the number, each with its
   reason. The numbers on the screen add up.
3. **The answer.** "That leaves $630." / "That leaves $0.00 — nothing left." / "You're $121 short of
   this month's bills." / "That leaves the whole $3,120 — but only because nothing has been
   subtracted."
4. **What I left out.** Accounts that were held out, each shown as one block with its own bills and
   the net of the two — never as two unrelated lines. A block whose net is negative is promoted to
   the line directly under the number, because a clean figure with a hole behind it is worse than an
   untidy one. Then cards with no statement, bills with no due date, and always: "This doesn't count
   your next paycheck."

Each figure has its own sentences. The month figure never says "payday" and the payday figure never
says "this month".

When the owner has entered no bills at all, part 2 says so rather than printing "$0 of bills are
still due": "You haven't told me about any bills yet, so I haven't subtracted anything." That reads
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
