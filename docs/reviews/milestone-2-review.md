# Milestone 2: the review's decisions

Output of the design review that ran before this milestone was implemented. Kept because the
reasoning behind several non-obvious rules lives here and nowhere else.

25 decisions, 7 rejected, 25 test cases.

## Decisions

### 1. `occurrence-generation-forward-only` (blocking)

In "Turning a recurring charge into dated occurrences", delete step 1's words "forward or backward" and the sentence about stepping backward, and replace steps 1-2 with: "Occurrences are generated FORWARD ONLY. Let `effectiveFirst = max(first, next_expected_date)`. If `next_expected_date < first`, step forward by the cadence to the first occurrence on or after `first`; otherwise start at `next_expected_date` itself. Emit occurrences until one falls after `last`. No occurrence earlier than `next_expected_date` is ever emitted, in any window: everything before the paid-through marker is settled by definition. A charge whose marker is later than `last` contributes no occurrences at all. A bill forgotten since June still contributes exactly one September occurrence, because the marker (Jun 1) is before the window and is stepped forward to Sep 1." `RecurringCharge.occurrences(in:calendar:)` in the working tree already implements exactly this; the document is what is wrong.

**Why.** Three independent lenses found the same defect and it is the single worst bug in the design: the backward step can only ever reach dates the marker says are already paid, so marking a monthly bill paid changes the calendar-month figure by exactly $0 forever, and the cross-month payday window subtracts the same rent twice. It also makes PLAN milestone 2's own acceptance criterion ('$40 this month' vs '$460 short if rent is unpaid') unreachable, since paid and unpaid give the same number.

### 2. `anchor-separate-from-paid-through-marker` (blocking)

In "Month-length arithmetic", add: "`anchor_date` is the charge's first occurrence and is written once at creation and never rewritten. Occurrence k is always `anchor + k steps`, clamped to the target month's last day at emission time only; a clamped value is never stored. `next_expected_date` is only the paid-through marker." Replace "Marking a bill paid ... advances this date by exactly one step" with: "Marking a bill paid sets `next_expected_date` to the next anchor-derived occurrence STRICTLY AFTER the current marker — never to the previous marker plus one step." Keep the v2 migration already in AppDatabase.swift (`anchor_date INTEGER`, backfilled from `next_expected_date`), and keep `RecurringCharge.markingPaidOnce` / `occurrence(index:anchor:)`, which implement this.

**Why.** Without a stored anchor the first February clamp becomes the new anchor and a bill due on the 31st drifts to the 28th (2027) or 29th (2028) permanently — three days early, forever, changing which payday window it falls in. The document already promises Jan 31 -> Feb 28 -> Mar 31 but, as written, cannot deliver it on the normal path. Two lenses found it independently; the working tree already carries the column and the arithmetic, so only the document is behind.

### 3. `obligation-table-is-a-total-function-over-one-classification` (blocking)

Replace the whole "Which obligations are subtracted" table with a rule keyed on ONE classification. Classify every account row exactly once into: contributes / stale-but-counted / dead-by-staleness / archived / untyped / credit / excluded-savings / non-USD. The same value drives the balance total, the obligation filter, and every disclosure line, so the two sides can never disagree. Then, for an obligation with paying account P: (1) P is NULL, or P is archived, or P's row is missing -> SUBTRACT (an account the owner closed cannot pay anything; the bill is still owed and will come out of money that IS counted). (2) P is dead-by-staleness and not archived -> DO NOT SUBTRACT. (3) P is excluded savings, credit (see the card rule), untyped, or non-USD -> DO NOT SUBTRACT. Untyped line: "paid from PLATINUM SELECT 4417, which isn't counted until you tell me what kind of account it is." Non-USD line: "paid from <account>, which isn't in US dollars and isn't counted." Archiving an account that still has confirmed obligations pointing at it must prompt in-app: "$85 of bills still come out of Old Credit Union Checking. Which account pays them now?" with an 'I don't pay this any more' option that cancels the charge. Also delete "or archived" from the Dead row of the freshness table and give archived its own row: "Archived — not counted, never named under the number, never raises the warning glyph; visible only in the accounts list."

**Why.** Merges four findings and both judge verdicts. The current table is not a total function (no row for untyped or non-USD) and is arithmetically indefensible for dead accounts: it drops the asset and keeps the liability, so an 8-day gap turns $3,160 of real money into '$0, you're $1,643 short'. Where the raw findings and the judges conflicted on archived accounts, the judges win and both reached the same place: archived must keep subtracting, or archiving a closed account silently deletes $1,400 of rent from the figure and creates an overdraft.

### 4. `held-out-block-with-its-net` (blocking)

Add to the disclosure spec: "For each account held out by the rule above (dead-by-staleness, excluded savings, untyped, non-USD), its last known balance AND every obligation paid from it are disclosed as ONE block with its net — never as two unrelated lines. Net positive: 'Chase Checking stopped updating Aug 14. Not counted: its last balance $3,120, and $1,212 of bills paid from it — on those last figures, $1,908 left over.' Net negative: 'Chase Checking stopped updating Aug 14. Not counted: its last balance $50, and $1,200 of bills paid from it — on those last figures it was $1,150 short.' When a block's net is NEGATIVE, that sentence is promoted to the line directly under the number, alongside the existing '+ $X in <account> not counted — stopped updating <date>' line; it is not left inside the disclosure. The held-out lines are always ADDITIVE: whenever the counted pool is itself short, the shortfall sentence still appears, scoped to what was counted — 'Of the accounts I can see, you're $1,172 short of this month's bills.' The per-day allowance is still shown in this state, because it is derived from the counted pool the adjacent sentence names." Dead wording splits by source: hand-entered — "$40 in Wallet cash isn't counted. You last updated it on September 3. Update it and I'll count it again."; synced — "$3,120 in Chase Checking isn't counted. Your bank stopped sending new balances on August 14, so I don't know what's in it now."

**Why.** Holding the asset out without the liability was the bug; holding both out as two separate footnotes creates the mirror-image bug (a clean '$2,040' with a $1,150 hole one click away), which the judge showed is more dangerous because it reads as a healthy number. Netting the block and promoting a negative net is the only form that cannot mislead in either direction. Two judges disagreed on whether the per-day allowance survives; I keep it, because suppressing it whenever any account goes stale blanks the number the owner uses daily, and the promoted sentence already carries the caveat.

### 5. `no-contributing-account-means-no-figure` (blocking)

Add a terminal state to "Showing a figure": "When the set of contributing accounts is empty — no account rows at all, or every candidate is dead, archived, untyped, non-USD or excluded — the engine produces NO figure. It never produces $0. With zero account rows the headline is 'I don't know yet.' and under it 'Add an account and I'll work out what you can spend.' With accounts that all failed the rules the headline is 'I can't work this out right now.' and under it one line per account: 'Chase Checking was $3,120 when you last updated it on August 14 — update it and I'll work this out.' In both states there is no per-day allowance line (not '$0 a day'), no shortfall sentence, no disclosure parts 1-3, and no '$0' anywhere on any surface. The menu bar shows the icon and the warning glyph with no number, extending PLAN Q6's icon-only rule from 'zero accounts exist' to 'no figure exists'. Exception so this cannot fire on noise: a dead account whose last known balance is $0 and which carries no confirmed obligations does not count toward this state and is only named under 'What was left out'." Because the engine now classifies in Swift (see the pure-engine decision), the empty case is `contributing.isEmpty`, not a NULL SUM.

**Why.** Merges the no-accounts and all-accounts-dead findings with judge B's R5. A SUM over zero rows is NULL in SQLite and either throws on decode or is coerced to a confident '$0' — the app's first-ever output, and a statement about the owner's money rather than an admission it has none. In the vacation case the current rules go further and assert '$0, you're $1,643 short' about $3,160 the owner actually has.

### 6. `card-billed-obligations-priority-rule` (blocking)

Replace the credit-card row in the obligation table AND the credit-card sentence in the Transfers paragraph with one per-card rule, evaluated once per computation, never per occurrence. Definition: a credit account C HAS A LIVE STATEMENT iff `cc_statement_cents IS NOT NULL` (0 counts as entered) AND the due date derived from `cc_due_day` is on or after today. In milestones 2-5 those columns are always NULL, so no card ever has a live statement. For each credit account C, exactly one card-related source is subtracted per window, first branch that applies: (1) live statement -> subtract the statement obligation and nothing else for C; bills paying C are listed not subtracted ("charged to your Chase Sapphire — counted through that card"), and a confirmed transfer whose destination is C is listed not subtracted ("this pays your Chase Sapphire — counted as that card's statement"). (2) no live statement, but a confirmed `kind='transfer'` charge with `destination_account_id = C` exists -> subtract that transfer's occurrences; bills paying C are listed not subtracted ("charged to your Chase Sapphire — counted through the payment you make to that card"). (3) otherwise -> subtract every confirmed occurrence of every bill whose `paying_account_id = C` at full amount, labelled "charged to your Chase Sapphire, which has no statement entered — counted here instead". Branch 3 is the only one reachable in M2-M5. Required disclosure whenever a card has no live statement: "You owe $1,180 on Chase Sapphire. No number here subtracts that — tell me its statement balance and due day and I'll count the payment." When a live statement of $0 is entered: "Chase Sapphire: statement $0 entered — nothing subtracted for this card this cycle."

**Why.** As written, card-billed bills are subtracted by neither rule for four milestones — $254.98 a month counted nowhere while the disclosure claims it is 'counted through that card' — and the hole reopens every cycle after M6 between the due date passing and the next statement being typed. The judge's per-card priority ordering is used rather than the raw fix's per-occurrence gate, which is not computable from `cc_statement_cents`/`cc_due_day` and would split one card's bills across two contradictory explanations in a single list. Nothing here reopens PLAN decision 3: direct subtraction happens only when there is no card obligation to count through.

### 7. `transfer-destination` (blocking)

Keep the v2 migration already registered in AppDatabase.swift (`destination_account_id INTEGER REFERENCES account(id) ON DELETE SET NULL`) — do NOT fix this by editing `schemaV1`, which is a silent no-op on the owner's real database while every in-memory test passes. Add to the manual bill form a destination picker that appears and is REQUIRED whenever `kind = 'transfer'` (SQLite cannot add a CHECK by ALTER, so the invariant lives in Swift plus a test). Add the missing null case to ENGINE.md's Transfers paragraph: "A transfer with no destination is subtracted — assume the money leaves — and is listed as 'Transfer $500 — tell me which account it goes into, or I have to assume it's gone.'" State the three destinations explicitly: destination contributes -> not subtracted, listed as "moves $500 into Ally Savings, which is already counted"; destination does not contribute -> subtracted; destination NULL -> subtracted with the sentence above. Add a migration test: migrate `upTo: "v1"`, insert a milestone-1-shaped `recurring_charge` row, migrate fully, assert the row survived with a NULL destination and `anchor_date = next_expected_date`.

**Why.** The transfer rule turns entirely on the destination account and schema v1 had no column for it, so the engine could not evaluate its own rule; whichever branch an implementer hardcoded was $500 a month wrong in one direction for half the owner's transfers, with two byte-identical database states producing two correct answers. The working tree has already added the column; what is still missing is the form field, the NULL rule, and the migration test that proves an existing row survives.

### 8. `mark-paid-action-and-retention` (blocking)

Three parts, all in M2. (1) Add an 'I've paid this' action with undo to every bill row — the engine contract already assumes it exists and PLAN M2.F never scoped it. (2) Record the fact, do not infer it: add `last_marked_paid_at INTEGER` and `paid_reflected_in_balance INTEGER` to `recurring_charge` in the existing v2 migration (never use `updated_at`, which a rename or an M5 detection write also touches). When the paying account is hand-entered, 'I've paid this' shows ONE checkbox, defaulting UNCHECKED: "Have you already updated <Chase Checking> to a balance with this $500 taken out?" Unchecked -> store `last_marked_paid_at = now`, `paid_reflected_in_balance = 0` and keep subtracting. Checked -> nothing is retained. For a SYNCED paying account no question is asked: retain while the account's `balance_date` INSTANT is <= `last_marked_paid_at` and release as soon as a sync brings a `balance_date` strictly after it (this is the one stated exception to whole-day arithmetic, because two same-day events cannot be ordered by day). A settled-transaction match (M5) never triggers retention; a pending match does. Retention applies only while the paying account still contributes its balance, so it terminates at the 7-day dead threshold at the latest; with no paying account set, retain while any contributing balance instant is <= `last_marked_paid_at`. (3) A retained obligation is dated on the DAY IT WAS MARKED, clamped into the window — not on its own due date — so paying October's rent early on Sep 20 still comes out of September, and it is emitted as one synthetic obligation, never re-emitted by the generator. (4) Disclosure: a paid bill NEVER appears in part 2's 'still due' list or its subtotal. Part 2 gains a second, separately subtotalled group: "You've already paid $500 of this, and I'm still counting it: Rent $500 — you told me you paid this on September 1, and the Chase Checking balance I have still includes it." with the remedy "If you've since updated Chase Checking, tick 'already taken out' on this bill and I'll stop counting it." Part 3 reads "$1,240 minus $110 still due minus $500 already paid leaves $630." (5) Separately, for a bill NOT yet marked paid whose paying account's `balance_date` is on or after the occurrence date, add: "You updated Chase on Sep 2, after this Sep 1 bill. If it's already come out, mark it paid and this number goes up by $1,400."

**Why.** Merges the M2 mark-paid gap with the judged retention rule. In M2 every balance is retyped by hand, normally AFTER paying something, so the figure either charges a post-payment balance for the payment again or — the moment mark-paid ships — jumps up by $500 at the instant $500 leaves. The judge's explicit checkbox replaces the proposed 'balance_date on or before the mark day' test, which is wrong in the likelier ordering (owner updates the balance first, then marks paid, and gets a $500 UNDER-statement) and whose own remedy sentence cannot work, because any same-day update still satisfies it.

### 9. `disclosure-part-2-two-totals` (blocking)

Split part 2 into two paragraphs with two different totals, in this order. Subtracted first: "$500 of your bills comes out of the money above." then one line per subtracted obligation, largest first: "Rent $500 — due October 1". Then, only when such obligations exist: "Two more bills are due this month, but they don't come out of the money above: Spotify $12 is charged to your Chase card, and Car insurance $98 comes out of Ally Savings, which isn't counted here." Part 3 then reads "That leaves $740." and the three numbers on screen add up. Part 4 keeps accounts that were left out and drops the duplicated obligation lines.

**Why.** Part 2 currently prints one undefined total. Read as all obligations it prints '$610 still due' above 'That leaves $740' from $1,240 — the owner subtracts and gets $630, and either thinks $110 vanished or stops trusting the number. Read as subtracted-only it prints '$500 still due' when $610 is genuinely due this month. The disclosure exists so that have minus due equals answer is checkable by someone who does not know what a balance is; both readings break that.

### 10. `per-figure-disclosure-sentences` (blocking)

State that the month sentences and the payday sentences are two separate sets and NEITHER may be rendered for the other figure. Month set (unchanged): "$500 of your bills comes out of the money above" / "That leaves $740." / "You're $120 short of this month's bills." Payday set, always keyed to the payday date and never to a month: part 2 "$500 of bills are due between now and your payday on October 3." with lines "Rent $500 — due October 1"; part 3 "That leaves $740 to last until October 3 — about $148.00 a day." or, when short, "You're $300 short of the bills due before your payday on October 3."; part 4 "This is only money you have now. Your paycheck on October 3 isn't part of it." Make the explanation a per-figure value; whichever figure `settings.primary_figure` names owns the headline AND the disclosure, and the other figure's sentences are available too. State that `calendarMonth` is primary until the setting says otherwise, and that the until-payday label always names the date ("Until payday (Oct 3)").

**Why.** Only one set of sentences exists and every one of them says 'this month', while the until-payday window deliberately crosses the month boundary — the document's own example prints 'Rent $500 — expected Oct 1' underneath 'still due this month' in a September figure, and prints 'This doesn't count your next paycheck' under a figure whose entire definition is the paycheck's arrival. From M9, with until-payday primary, a '$728' headline would sit above 'That leaves $1,228.'

### 11. `freshness-is-whole-calendar-days-in-swift` (blocking)

In "Freshness tiers" state: "`balance_date` is converted to a `CalendarDay` in the owner's current calendar and time zone, and the tier is `CalendarDay.days(to:)` between that day and today — never elapsed seconds, never `julianday()`, never `(now - balance_date)/86400`, never SQL date arithmetic. The future clamp is a clamp of the derived `CalendarDay` to today's `CalendarDay`." Because the tier can then only change at midnight — exactly when the day-rollover trigger fires — the invariant 'the figure only changes when data changes or the day rolls over' becomes true.

**Why.** Merges two findings. `balance_date` is an instant and the document never said how to turn it into 'whole days', so the two natural readings differ by one whenever the stored time-of-day is later than the reading time — roughly half the time — and at the dead boundary that swings an entire $3,120 account in or out of the headline with no warning line. The elapsed-seconds reading is worse still: it flips the tier at 6:10pm with nothing scheduled to notice, so the app shows the superseded number all evening.

### 12. `days-not-instants-in-every-comparison` (blocking)

Add to Vocabulary and to the occurrence algorithm: "Every persisted date-like value (`next_expected_date`, `anchor_date`, `balance_date`, `cc_statement_entered_at`) is normalised to start of day before it is written — `RecurringCharge.manual` already does this via `CalendarDay.epochSeconds()` — and the engine converts every persisted instant to a `CalendarDay` before any comparison, ordering or stepping. Window membership is tested as `first <= day && day <= last` on `CalendarDay` values; it is NEVER a `BETWEEN` over epoch seconds and never a `Date` comparison. Cadence steps use `Calendar` date components (`byAdding: .day` / `.month`), never `addingTimeInterval` or arithmetic on seconds." Add a write-time assertion test that no `recurring_charge` row is ever stored with a non-midnight `next_expected_date` or `anchor_date`.

**Why.** A SwiftUI DatePicker keeps the time-of-day of its bound Date, so a bill added at 14:37 and due on the window's last day compares as 'after last' and is silently dropped for the whole month it is due in — $1,400 of rent absent from the figure and from the disclosure. The same drop hits every bill due the day before payday, and PLAN M2's 'bill due on payday excluded' test passes while masking it. Stepping 14*86400 seconds across the Nov 1 2026 fall-back also lands a biweekly charge on the wrong calendar day.

### 13. `no-bills-entered-state` (blocking)

Add a distinct state for zero obligations. When no recurring charge exists at all, part 2 reads: "You haven't told me about any bills yet, so I haven't subtracted anything. Until you add your rent and the bills that come out automatically, this number is just what's in your accounts." Part 3 reads: "That leaves the whole $3,120 — but only because nothing has been subtracted." and the Overview shows the 'Add a bill' control next to it. When bills exist but none falls in the window, the sentence is DIFFERENT and must stay separate: "None of your bills are due between now and the end of the month." Never print "$0 of bills are still due this month" for either case.

**Why.** In M2 the only way a bill exists is hand entry on a separate screen, so an empty bill table is the normal state for the first days of use. '$0 of bills are still due this month', carrying the full authority of the disclosure, reads to a financially illiterate owner as a check the app performed against their bank — and they spend against a $1,400 rent the app has never been told about.

### 14. `bills-outside-the-payday-window-are-named` (blocking)

Define the hold-back set H = every obligation the subtraction rules would subtract whose occurrence date falls in [next payday, last day of the current month] — inside the calendar-month window and outside the until-payday window. Whenever H is non-empty the until-payday line MUST carry, in the same sentence, H's total and the name and date of its largest members (all of them up to three, then "and N more"): "Until payday (Sep 25): $984, about $89.45 a day — then $142 more is due before the month ends (car insurance, Sep 28)." When the next obligation falls on payday itself, say so: "Bills due after September 24 aren't in this number. The next one is Rent $1,200 on September 25 — the same day you're paid." The clause is produced by the engine's explanation struct, never assembled by the view. Also state the invariant as intended: "On every day before the last payday of the month the until-payday window is a strict subset of the calendar-month window, so the until-payday figure is the LARGER of the two. This is the point of it. Neither figure is ever shown without its window: 'Safe to spend this month (Sep 1-30)' and 'Until payday (Sep 25)'." One guard: when the calendar-month figure is NEGATIVE, the until-payday per-day allowance is not shown as a number and not shown as '$0'; it is replaced by "Until payday (Sep 25): $984 — but you're $120 short of this month's bills; $1,104 of them is due after payday."

**Why.** Merges the payday-window omission finding with the judged fix for the two figures disagreeing. A $1,200 rent due on payday is invisible in the payday figure for eleven days, and if that figure is primary the menu bar reads $1,300 until the rent bounces. Naming H is the honest fix; the proposed min-clamp across windows is rejected (see rejected list) because it divides a 30-day numerator by an 11-day divisor and would print '$1,500 left, about $9 a day'.

### 15. `payday-pending-provenance` (material)

Add to "The until-payday figure": "Let `lastPayday` be the largest payday on or before today, and `newestContributingBalanceDay` the maximum clamped `balance_date` day over the accounts contributing to this figure. The figure is in state `payPending` when `newestContributingBalanceDay < lastPayday`. Nothing about the arithmetic changes — same window, same divisor, the paycheck stays uncounted, and a non-positive figure still reads '$0 (balance: -$1,112)' with a $0 allowance. When `payPending` holds AND the figure is not positive, the panel's primary sentence and disclosure part 3 lead with the cause and then give the arithmetic: 'Your pay from Sep 25 isn't in these balances yet — the newest balance here is from Sep 24. Counted without it, the bills due before Oct 9 come to $1,412 against the $300 your bank last showed.' The bare 'You're $X short' sentence is not rendered for this figure in that state. When `payPending` holds and the figure is positive, it adds no sentence."

**Why.** On payday morning the window jumps forward 14 days against a balance stamped before the deposit landed, producing the most alarming screen the app can show on the day the owner is best off. The trigger is balance provenance, not 'today is a payday': gating on the latter misses the identical false shortfall the next day (balances still stamped Sep 24) and misfires in M2, where `Account.manual` stamps `balanceDate = now` so an account edited on payday morning defeats the gate.

### 16. `display-rounding-and-menu-bar` (material)

Replace the rounding rules in "Showing a figure". (1) No positive amount ever displays as '$0': figures are whole dollars floored toward negative infinity EXCEPT that an exact figure strictly between $0.00 and $1.00 is shown to the cent ('$0.75'). (2) Shortfalls round away from zero and show cents under a dollar: -$120.60 reads '$0 (balance: -$121)' and 'You're $121 short of this month's bills'; -$0.40 reads '$0 (balance: -$0.40)'. (3) The per-day allowance is ALWAYS shown to the cent, never in whole dollars: `allowance_cents = floor(remainder_cents / days)`, days = today inclusive to payday exclusive, min 1, rendered 'about $1.99 a day' / 'about $57.27 a day'. (4) When the remainder is positive but `allowance_cents` is 0, omit the per-day phrase entirely rather than printing $0.00: 'Until payday on September 25: $0.05 left.' '$0 a day' is spoken only when the remainder is not positive. (5) Part 3 has exactly four forms: 'That leaves $630.' / 'That leaves $0.75.' / 'That leaves $0.00 — nothing left.' / 'You're $121 short of this month's bills.' (6) The menu bar and small widget carry the shortfall parenthetical: '$0 (-$121) ⚠', and the shortfall state joins the warning-glyph trigger list. With (1) and (2) in force a bare '$0' on any surface has exactly one meaning — nothing left and not short — and the document says so.

**Why.** Merges the rounding finding with the menu-bar finding. Whole-dollar flooring of a per-day quantity understates by up to 50% well above the $1 band ($21.99 over 11 days prints 'about $1 a day'), and a positive sub-dollar remainder prints the same '$0' as a $2,010 shortfall on the two surfaces the owner looks at all day — identical pixels whether they are exactly even or deeply short. The proposed 'less than $1 a day' wording is rejected in favour of exact cents, which is never generous and reconciles with the headline.

### 17. `available-balance-gate` (material)

Replace "For a `checking` account with a non-null `available_cents`, the available balance is used" with: "`available_cents` is used only when `user_type == checking` — the owner's own confirmation, not a keyword guess. A keyword-guessed checking account uses `balance_cents` until the owner confirms the type. And if `available_cents > balance_cents` on an account typed checking, `balance_cents` is used and the account is named in the disclosure's left-out section: 'Chase Total Checking's "available" is higher than its balance, so that extra looks like a credit line, not money; I used the balance.'" In M2 every account is hand-entered with `user_type` set, so nothing changes there.

**Why.** PLAN's binding default is 'use available-balance only for accounts whose type is confirmed checking; flag as suspicious if available-balance > balance', repeated in M2.B and M4.B; ENGINE.md dropped both halves and defines type as 'the guess if no correction'. From M4 a bank that folds a $4,000 overdraft line into available-balance would put $4,300 in the headline for an account holding $300 — the exact shape the spec's non-negotiable rule names.

### 18. `disclosure-part-1-composition` (material)

Compose part 1 from what actually contributed instead of the fixed phrase 'in checking and cash'. One type: 'You have $40 in cash.' Two: 'You have $1,240: $40 in cash and $1,200 in Ally Savings, which you asked me to count.' Three: 'You have $1,290: $1,200 in checking, $40 in cash, and $50 in Ally Savings, which you asked me to count.' Counted savings is ALWAYS called out separately, because it is the opt-in part. When exactly one account contributes, drop the summary line entirely and print only the account line. Gloss the balance term on every account line: 'Chase Checking $1,200 — what your bank says is free to spend right now, which leaves out payments that haven't finished going through. As of this morning.' / 'Ally Savings $1,200 — your bank's balance. It may not have caught up with payments still going through. As of today.' / 'Wallet cash $40 — the amount you entered by hand, as of Tuesday.' Replace the hardcoded 'as of this morning' with `AsOf.dayPhrase` ('today' / 'yesterday' / 'Thursday' / 'Sep 3'), which milestone 1 already ships.

**Why.** Merges three wording findings. The fixed sentence names types the owner may not have, is word-for-word identical before and after ticking a savings account whose $8,000 is most of the headline, and duplicates the single account line when only one account contributes. 'Available balance' is unglossed jargon in the one sentence the spec requires it to appear in, for an owner told to assume 'available credit' is meaningless to them. 'As of this morning' is false for a balance stamped 6pm today.

### 19. `obligation-line-wording` (material)

Replace the part-2 obligation labels with three, and in M2 never claim to have looked at a feed. Future: 'Rent $500 — due October 1.' Today: 'Rent $500 — due today.' Past: 'Spotify $12 — was due September 5. I'm still subtracting it until you mark it paid.' with the 'I've paid this' control on that row. When the marker is more than one step behind: 'Rent $500 — was due June 1 and hasn't been marked paid since. I'm only subtracting one month of it.' From milestone 5, 'hasn't shown up yet' may replace the past wording ONLY on accounts whose transactions the app actually reads.

**Why.** 'Hasn't shown up yet' is literally impossible in M2 — there is no transaction feed in which anything could show up — so it tells the owner the app checked their bank when the only thing that moves the marker is their own tap; they wait for it to clear itself and the $12 stays subtracted all month. There is also no wording at all for a bill due today, which currently renders identically to one a fortnight away, and nothing tells the owner that three of four unpaid months are missing from the number.

### 20. `single-classification-pure-engine` (material)

Replace "The balance total is a single SQL aggregate ... the engine never sums balances in Swift" with: "One query fetches every account row the engine needs (including archived rows, which the obligation rule reads) with named columns — `id, display_name, source, currency, COALESCE(user_type, guessed_type) AS effective_type, balance_cents, available_cents, balance_date, include_in_safe_to_spend, amounts_reversed, archived_at, cc_statement_cents, cc_due_day`. A pure `SafeToSpendEngine.compute(accounts:charges:anchorDay:today:) -> SafeToSpendResult` imports no GRDB, never calls `Date()`, classifies each row exactly once, sums at most a couple of dozen `Int64`s, and returns the figure and the explanation together, so the headline and the disclosure are the same arithmetic by construction. The spec's 'never a Swift reduce' rule governs the transaction table, which is still never read into memory." Everything in the occurrence, window, figure and display sections is unit-tested with value structs and literal `CalendarDay`s, with no database; only the fetch returning the right rows, the v1->v2 migration, and `ValueObservation` retriggering need `AppDatabase.inMemory()`.

**Why.** 'A single SQL aggregate' plus a Swift-rendered disclosure forces the inclusion rule to be written twice, and the two drift invisibly: `currency = 'USD'` in SQL is BINARY-collated and excludes a 'usd' row, while a Swift disclosure builder naturally written as `uppercased() == "USD"` counts it — headline '$40' above 'You have $2,340 ... That leaves $2,340'. The same split exists for `include_in_safe_to_spend = 1` versus `!= false` on NULL. It also pins tier boundaries, window construction and cadence stepping — the parts most likely to be wrong — behind a database.

### 21. `day-rollover-trigger` (material)

Replace "at the first observation after the calendar day rolls over" with a named trigger: "A calendar day changing writes nothing to the database, so no `ValueObservation` fires. The app subscribes to `NSCalendarDayChanged`, `NSSystemTimeZoneDidChange`, `NSSystemClockDidChange` and `NSWorkspace.didWakeNotification`, all funnelling into one `todayDidChange` path that recomputes `CalendarDay.today()`, cancels the existing `DatabaseCancellable` and restarts the observation with the new day-boundary arguments. Fallback if `NSCalendarDayChanged` proves unreliable in an LSUIElement process: one NON-repeating timer at the next 00:00:01 local, rescheduled on each fire — one wake per day." The pure engine takes `today: CalendarDay` as a parameter, so tests need no clock; the wiring is tested by posting `NSCalendarDayChanged` and asserting exactly one recomputation with the new boundaries.

**Why.** With no trigger the figure stays on yesterday's window until the 6-hour scheduler happens to fire (up to 7 hours with tolerance), and worse: an observation created before midnight carries yesterday's bound window arguments, so a write arriving after midnight re-fetches with stale parameters — the number moves, looking current, while still being computed for the wrong month. At 00:05 on Oct 1 the widget (pinned to local midnight) and the menu bar would show different numbers from the same data on the same Mac.

### 22. `duplicate-obligation-prompt-not-silent-collapse` (material)

When two confirmed obligations have occurrences within 5 days of each other with amounts within 5%, SUBTRACT BOTH and put one prompt at the top of the disclosure: "Two bills of $1,400 are both due October 1 — Rent and PROPERTYMGMT ACH. If they're the same bill, tell me and I'll count it once." with a one-tap 'same bill' action that cancels the detected one and adopts its `merchant_normalized` onto the manual row. Do NOT collapse them automatically. Separately, add an optional "How does this show up on your statement?" field to the M2 manual bill form that writes `merchant_normalized`, so M5's adoption path can actually fire.

**Why.** A manual bill has no merchant string and rent's bank descriptor will never match the name the owner typed, so M5's stated adoption defence cannot fire and rent is double-subtracted. Where the raw finding proposed silent collapse on 5 days / 5%, I reject that: it would also merge a $1,400 rent on the 1st with a $1,400 car payment on the 3rd, deleting a real bill and inflating the figure — the overdraft direction, and the one ENGINE.md's 'never a cent more generous than the truth' rule forbids. Subtracting both errs toward panic, which one tap fixes and the prompt explains.

### 23. `confirmed-charge-with-no-due-date` (material)

State that the confirmed-obligation query is `status = 'confirmed' AND next_expected_date IS NOT NULL` (already true of `RecurringCharge.confirmed()`), and add the companion query `SELECT id, name, amount_cents FROM recurring_charge WHERE status = 'confirmed' AND next_expected_date IS NULL` feeding a line under 'What was left out': "Gym $45 — I don't know when this is next due, so it isn't subtracted." The M2 bill form makes the date non-optional; the M5 auto-confirm path must set `next_expected_date` in the same write that sets `status = 'confirmed'`.

**Why.** The column is nullable with no constraint tying it to `confirmed`, so the natural optional-binding implementation drops the row without a trace: not subtracted, and absent from both disclosure lists, while the Bills screen shows it sitting there confirmed with an auto-detected badge. The screen whose whole job is to make every subtraction visible would be silent about a bill the owner can see elsewhere in the app.

### 24. `amounts-reversed-in-the-balance` (minor)

State the rule in ENGINE.md and apply it in the one place the contributing balance is chosen: `contributed = (amounts_reversed ? -1 : 1) * (user_type == .checking && available_cents != nil && available_cents <= balance_cents ? available_cents! : balance_cents)`. If the toggle is instead meant to be credit-only, say that in ENGINE.md and hide the control on non-credit rows.

**Why.** `account.amounts_reversed` exists in schema v1 and PLAN M4.B surfaces it as a per-account toggle on any account, not just cards, yet ENGINE.md — which the tests follow case for case — never mentions it. An institution reporting checking as '-2300.00' would give a headline $2,300 too low, and the owner ticking the correction would watch the number not move a cent. Either answer is fine; silence is not, because the column exists and the UI already plans to write it.

### 25. `observation-column-scope` (minor)

Give each observation an explicit `.select()` of only the columns the engine reads — `account(archived_at, currency, user_type, guessed_type, include_in_safe_to_spend, source, balance_cents, available_cents, balance_date, display_name, amounts_reversed, cc_statement_cents, cc_due_day)`, `settings(primary_figure)`, `recurring_charge(status, kind, amount_cents, cadence, anchor_date, next_expected_date, paying_account_id, destination_account_id, name, last_marked_paid_at, paid_reflected_in_balance)`, `pay_schedule(anchor_day)` — never `Account.fetchAll(db)`, which compiles to `SELECT *` and puts every column in the tracked region. Use `ValueObservation.trackingConstantRegion` plus `.removeDuplicates()`. Test: start the observation, `UPDATE account SET tx_synced_through = ?` and assert zero further emissions, then `UPDATE account SET balance_cents = ?` and assert exactly one.

**Why.** From M3 every balances-only refresh writes `last_seen_in_sync_at` and `tx_synced_through` on every row, and a chunked first sync writes `backfilled_through` nine times in a row; with a SELECT * region each of those republishes the figure and re-renders the whole disclosure although no balance or date moved. That is the behaviour the spec's performance section forbids and the wakeup count M4 has to report.

## Findings deliberately rejected

- **`until-payday-min-clamp`** — Clamping the per-day allowance to min(payday remainder, month remainder) mixes a 30-day numerator with an 11-day divisor: $1,500 in hand, rent $1,400 due Sep 30, payday Sep 25 would print 'Until payday: $1,500, about $9 a day'. It also deletes the exact correction the spec asked for ('punishing on the 1st'), and `pay_schedule` stores no paycheck amount, so the engine is in no position to assume the next paycheck is $0. The mandatory hold-back clause is kept instead.
- **`next-expected-day-text-column`** — Adding a `next_expected_day TEXT` column alongside the INTEGER one is churn: the v2 migration already stores `anchor_date` and `next_expected_date` as start-of-day epochs, and the actual defect (a bill on the window's last day being dropped) is fixed by comparing through `CalendarDay`, not by a third date representation.
- **`suppress-figure-whenever-a-dead-account-carries-bills`** — Blanking the number every time any dead account happens to carry a bill overturns PLAN decision 6 in the ordinary partial case and over-fires on noise (a dead $0 Venmo row with a $4 subscription). Refusal is limited to the empty-contributing-pool case, where $0 would be manufactured rather than computed.
- **`auto-collapse-duplicate-obligations`** — Collapsing two obligations within 5 days and 5% would merge a $1,400 rent on the 1st with a $1,400 car payment on the 3rd, silently deleting a real bill and inflating the figure. Both are subtracted and a prompt asks; see the duplicate-obligation decision.
- **`less-than-a-dollar-a-day-wording`** — 'Less than $1 a day' discards an actionable number and does not reconcile with the headline ($10 over 11 days implies up to $11). Exact cents ('about $0.99 a day') is never generous, reconciles, and also fixes the adjacent $1-$9 band the wording leaves wrong.
- **`edit-schemav1-to-add-destination`** — Editing the `schemaV1` string is a silent no-op on the owner's real database (v1 is already recorded in `grdb_migrations`, GRDB does not checksum migration bodies, and `eraseDatabaseOnSchemaChange` is not set) while every in-memory test passes. The registered v2 migration is the fix; only the missing migration test is outstanding.
- **`suppress-per-day-allowance-when-accounts-are-held-out`** — One judge wanted the allowance absent whenever a dead account's balance and bills were held out. Held out correctly, the allowance is an honest quotient of the pool the adjacent sentence names, and blanking it whenever any account goes stale removes the number the owner uses daily. The promoted net sentence carries the caveat instead.

## Test cases

### 1. paid_monthly_bill_not_resubtracted

**Setup.** Today 2026-09-14, America/Chicago. Accounts: Chase Checking (manual, checking) $2,600.00, balance_date 2026-09-14. Charge: Rent $1,400.00, monthly, anchor_date 2026-09-01, marked paid on 2026-09-01 with 'already taken out' TICKED, so next_expected_date = 2026-10-01. Pay anchor 2026-09-11.

**Expected.** Calendar-month window [Sep 1, Sep 30]: zero occurrences (marker Oct 1 > Sep 30). Month figure exactly $2,600.00, headline 'You can spend $2,600 this month'. Until-payday window [Sep 1, Sep 24]: zero occurrences, figure $2,600.00, divisor 11, allowance floor(260000/11)=23636 -> 'about $236.36 a day'. Part 2 prints 'None of your bills are due between now and the end of the month.' No 'Rent $1,400 — expected Sep 1' line anywhere. Regression assert: the month figure differs from the same fixture with the bill unpaid ($1,200).

### 2. marked_paid_but_balance_not_yet_updated

**Setup.** Today 2026-09-14. Chase Checking (manual, checking) $4,000.00, balance_date 2026-09-01 (entered that morning, before rent went out). Rent $1,400.00 monthly, anchor 2026-09-01, marked paid on 2026-09-01 with the checkbox UNTICKED: last_marked_paid_at = 2026-09-01, paid_reflected_in_balance = 0, next_expected_date = 2026-10-01.

**Expected.** Month figure $4,000.00 - $1,400.00 = $2,600.00. Part 2's 'still due' list is empty with its own $0 subtotal; the second group reads 'You've already paid $1,400 of this, and I'm still counting it: Rent $1,400 — you told me you paid this on September 1, and the Chase Checking balance I have still includes it.' plus 'If you've since updated Chase Checking, tick "already taken out" on this bill and I'll stop counting it.' Part 3: '$4,000 minus $0 still due minus $1,400 already paid leaves $2,600.' Rent is emitted exactly once (dated Sep 1, the mark day), never twice.

### 3. month_end_anchor_non_leap_2027

**Setup.** Charges anchored on 2027-01-29, 2027-01-30 and 2027-01-31, monthly, marked paid three times each. Calendar America/Chicago.

**Expected.** 29th: Jan 29 -> Feb 28 -> Mar 29 -> Apr 29. 30th: Jan 30 -> Feb 28 -> Mar 30 -> Apr 30. 31st: Jan 31 -> Feb 28 -> Mar 31 -> Apr 30. In every case the stored anchor_date is unchanged from the original January date after all three marks, and the third step returns to the anchor day where the month has one.

### 4. month_end_anchor_leap_2028

**Setup.** Charges anchored on 2028-01-29, 2028-01-30 and 2028-01-31, monthly, marked paid three times each.

**Expected.** 29th: Jan 29 -> Feb 29 -> Mar 29 -> Apr 29. 30th: Jan 30 -> Feb 29 -> Mar 30 -> Apr 30. 31st: Jan 31 -> Feb 29 -> Mar 31 -> Apr 30. anchor_date unchanged throughout. Assert the 31st case differs from the 2027 run only at February (Feb 29 vs Feb 28) and reconverges at Mar 31.

### 5. weekly_bill_five_times_in_a_month

**Setup.** Today 2026-10-01. Chase Checking (manual, checking) $500.00, balance_date 2026-10-01. Gym $25.00 weekly, anchor_date and next_expected_date both 2026-10-01 (a Thursday). No pay anchor.

**Expected.** October window [Oct 1, Oct 31] emits Oct 1, 8, 15, 22, 29 — five occurrences, $125.00 subtracted. Month figure $375.00. Part 2 lists five dated lines, the first reading 'Gym $25 — due today.' Second assertion: the same charge with next_expected_date advanced to 2026-10-22 (paid through Oct 15) emits only Oct 22 and Oct 29 = $50.00, figure $450.00.

### 6. cross_month_payday_window

**Setup.** Today 2026-09-28. Pay anchor 2026-09-05 (paydays Sep 5, Sep 19, Oct 3). Chase Checking (manual, checking) $1,240.00, balance_date 2026-09-28. Rent $500.00 monthly, anchor 2026-09-01, September's occurrence marked paid with the checkbox ticked, so next_expected_date = 2026-10-01.

**Expected.** Month figure: window [Sep 1, Sep 30], no occurrence, $1,240.00. Until-payday: next payday Oct 3, window [Sep 1, Oct 2], emits Oct 1, figure $740.00, divisor Sep 28..Oct 2 = 5, allowance floor(74000/5)=14800 -> 'about $148.00 a day'. Payday disclosure part 2: '$500 of bills are due between now and your payday on October 3.' with 'Rent $500 — due October 1'. The string 'this month' appears nowhere in the payday explanation; the month explanation uses no payday wording.

### 7. bill_due_on_payday_excluded_and_named

**Setup.** Today 2026-09-14. Pay anchor 2026-09-11 (next payday Sep 25). Chase Checking (manual, checking) $1,300.00, balance_date 2026-09-14. Rent $1,200.00 monthly, anchor and next_expected_date 2026-09-25.

**Expected.** Until-payday window [Sep 1, Sep 24] excludes the Sep 25 occurrence: figure $1,300.00, divisor 11, allowance floor(130000/11)=11818 -> 'about $118.18 a day'. The payday line MUST carry: 'Bills due after September 24 aren't in this number. The next one is Rent $1,200 on September 25 — the same day you're paid.' Calendar-month figure $100.00. A run with the clause suppressed must fail the test.

### 8. after_payday_holdback_clause_and_cent_allowance

**Setup.** Today 2026-09-14. Pay anchor 2026-09-11. Chase Checking (manual, checking) $2,400.00, balance_date 2026-09-14. Unpaid bills paying Chase: Rent $1,400.00 (marker Sep 1), Netflix $15.99 (Sep 8), car insurance $142.00 (Sep 28).

**Expected.** Month: subtracts $1,557.99 -> $842.01, headline '$842'. Until-payday: window [Sep 1, Sep 24] subtracts $1,415.99 -> $984.01, headline '$984', divisor 11, allowance floor(98401/11)=8945 -> 'about $89.45 a day'. The payday line reads '...about $89.45 a day — then $142 more is due before the month ends (car insurance, Sep 28).' Assert the hold-back set total is exactly $142.00 and names car insurance / Sep 28. Assert no test asserts allowance <= month remainder / divisor (that invariant is false by design).

### 9. dead_account_with_bills_net_positive

**Setup.** Today 2026-09-14. Chase Checking (manual, checking) $3,120.00, balance_date 2026-08-14 (31 days -> dead). Wallet cash (manual, cash) $40.00, balance_date 2026-09-14. Unpaid bills, both paying Chase: Rent $1,200.00 (marker Sep 1), Spotify $12.00 (marker Sep 5). Pay anchor 2026-09-11.

**Expected.** Month figure exactly $40.00 (Chase's balance out, Chase's $1,212.00 of bills out with it). Headline 'You can spend $40 this month'. Under the number: '+ $3,120 in Chase Checking not counted — stopped updating Aug 14' and the block 'Chase Checking stopped updating Aug 14. Not counted: its last balance $3,120, and $1,212 of bills paid from it — on those last figures, $1,908 left over.' Menu bar '$40' with the warning glyph. No shortfall sentence anywhere. Per-day allowance still shown: until-payday figure $40.00, divisor 11, 'about $3.63 a day'.

### 10. dead_account_with_bills_net_negative_promoted

**Setup.** Today 2026-09-14. Chase Checking (manual, checking) $50.00, balance_date 2026-08-14 (dead). Ally Checking (manual, checking) $2,000.00, balance_date 2026-09-14. Wallet cash $40.00, balance_date 2026-09-14. Rent $1,200.00 monthly, marker 2026-09-01, paying Chase.

**Expected.** Month figure $2,040.00. The sentence 'Chase Checking stopped updating Aug 14. Not counted: its last balance $50, and $1,200 of bills paid from it — on those last figures it was $1,150 short.' appears on the line directly under the number, not only inside the disclosure. Assert the promoted sentence is present in the headline-adjacent payload, not just the explanation body.

### 11. every_account_dead_no_figure

**Setup.** Today 2026-09-14. Chase Checking (manual, checking) $3,120.00 and Wallet cash (manual, cash) $40.00, both balance_date 2026-09-04 (10 days -> dead). Unpaid bills all paying Chase: Rent $1,400.00 (Sep 1), Verizon $85.00 (Sep 8), Netflix $15.99 (Sep 8), car insurance $142.00 (Sep 28) = $1,642.99. Pay anchor 2026-09-11.

**Expected.** NO figure is produced for either window. Headline 'I can't work this out right now.' with 'Chase Checking was $3,120 when you last updated it on September 4 — update it and I'll work this out.' and the same for Wallet cash $40. Assert the rendered output contains no '$0', no per-day allowance line, and no shortfall sentence. Menu bar shows the icon plus the warning glyph and no number.

### 12. archived_account_with_a_bill

**Setup.** Today 2026-09-14. Chase Checking (manual, checking) $900.00, balance_date 2026-09-14. Old Credit Union Checking (manual, checking) $0.00, archived_at 2026-09-10. Gym $85.00 monthly, marker 2026-09-20, paying_account_id = Old Credit Union Checking.

**Expected.** Month figure $900.00 - $85.00 = $815.00 — the archived account's obligation IS still subtracted. Disclosure carries 'Gym $85 still pays from Old Credit Union Checking, which you archived — tell me which account pays it now.' Assert the archived account is NOT named under the number, does not appear in any 'not counted' list, and raises no warning glyph.

### 13. bill_charged_to_a_card_with_no_statement

**Setup.** Today 2026-09-14, milestone 2. Chase Checking (manual, checking) $2,400.00, balance_date 2026-09-14. Chase Sapphire (manual, credit) balance -$1,180.00, cc_statement_cents NULL, cc_due_day NULL. Unpaid bills paying Sapphire: Netflix $15.99 (Sep 8), Spotify $11.99 (Sep 12), Verizon $85.00 (Sep 20), car insurance $142.00 (Sep 25) = $254.98. Unpaid Rent $1,400.00 (Sep 1) paying Chase Checking.

**Expected.** Month figure 2,400.00 - 1,400.00 - 254.98 = $745.02, headline '$745'. Each of the four card lines reads 'charged to your Chase Sapphire, which has no statement entered — counted here instead' and each is inside part 2's SUBTRACTED subtotal. 'What was left out' carries 'You owe $1,180 on Chase Sapphire. No number here subtracts that — tell me its statement balance and due day and I'll count the payment.' The card balance is never added to any total.

### 14. card_autopay_transfer_takes_priority_over_card_billed_subs

**Setup.** Today 2026-09-14. Chase Checking (manual, checking) $2,400.00. Chase Sapphire (manual, credit) -$1,180.00, no statement entered. Transfer 'Sapphire autopay' $500.00 monthly, kind='transfer', marker 2026-09-20, paying Chase Checking, destination_account_id = Chase Sapphire. Same four card-billed bills totalling $254.98. No other bills.

**Expected.** Exactly $500.00 is subtracted for the card: month figure $1,900.00. The four card-billed bills are listed, NOT subtracted, each reading 'charged to your Chase Sapphire — counted through the payment you make to that card'. Assert the total subtracted for the card is $500.00 and never $754.98.

### 15. excluded_savings_transfer

**Setup.** Today 2026-09-14. Chase Checking (manual, checking) $2,000.00, Ally Savings (manual, savings) $5,000.00 with include_in_safe_to_spend NULL. Transfer $500.00 monthly, kind='transfer', marker 2026-09-20, paying Chase Checking, destination Ally Savings. All balance_dates 2026-09-14.

**Expected.** Ally contributes nothing. Month figure $2,000.00 - $500.00 = $1,500.00. Part 2's subtracted list contains the transfer. 'What was left out' names Ally Savings as savings not counted.

### 16. included_savings_transfer_and_null_destination

**Setup.** Same accounts as the previous case but Ally Savings has include_in_safe_to_spend = 1. Variant B: identical to variant A except destination_account_id is NULL.

**Expected.** Variant A: month figure $7,000.00 — the transfer is NOT subtracted and is listed as 'moves $500 into Ally Savings, which is already counted'. Variant B: month figure $6,500.00 — subtracted, with the line 'Transfer $500 — tell me which account it goes into, or I have to assume it's gone.' Assert A and B differ by exactly $500.00 and that the manual bill form refuses to save a kind='transfer' row with no destination.

### 17. untyped_paying_account

**Setup.** Today 2026-09-14. 'Household 4412' (simplefin, user_type NULL, guessed_type NULL) $4,000.00, balance_date 2026-09-14. Chase Checking (manual, checking) $2,000.00, balance_date 2026-09-14. Unpaid Rent $1,800.00, marker 2026-09-01, paying Household 4412.

**Expected.** Month figure exactly $2,000.00 — neither the $4,000 nor the $1,800 enters the arithmetic. One paired disclosure item: 'Household 4412 isn't counted until you tell me what kind of account it is, and neither is the $1,800 of bills paid from it.' Second assertion: setting user_type = checking moves both at once, giving $4,200.00.

### 18. no_accounts

**Setup.** Today 2026-09-14. Zero rows in `account`. Zero rows in `recurring_charge`. No pay anchor.

**Expected.** No figure. Headline 'I don't know yet.' with 'Add an account and I'll work out what you can spend.' Assert the rendered output contains no '$0', no disclosure parts 1-3, and no per-day allowance. Assert the engine does not throw (the old NULL-SUM decode path must not exist).

### 19. no_bills_entered

**Setup.** Today 2026-09-14. Chase Checking (manual, checking) $3,120.00, balance_date 2026-09-14. Zero rows in `recurring_charge`. Variant B: one confirmed Rent $1,400.00 whose marker is 2026-11-01.

**Expected.** Variant A: month figure $3,120.00; part 2 reads 'You haven't told me about any bills yet, so I haven't subtracted anything. Until you add your rent and the bills that come out automatically, this number is just what's in your accounts.' and part 3 'That leaves the whole $3,120 — but only because nothing has been subtracted.' Variant B: same figure but part 2 reads 'None of your bills are due between now and the end of the month.' Assert the two sentences are different and that '$0 of bills are still due this month' is never emitted.

### 20. no_pay_anchor

**Setup.** Today 2026-09-14. Chase Checking (manual, checking) $1,240.00, balance_date 2026-09-14. Unpaid Rent $500.00, marker 2026-09-01. `pay_schedule` empty.

**Expected.** Month figure $740.00 computed normally with its full disclosure. The until-payday slot produces no figure, no divisor and no allowance, and reads 'Tell me the day of your next payday and I'll work this out.' Assert no hold-back clause and no payPending state is computed. With primary_figure = 'calendarMonth' the menu bar is unaffected.

### 21. exactly_zero

**Setup.** Today 2026-09-14. Chase Checking (manual, checking) $1,400.00, balance_date 2026-09-14. Unpaid Rent $1,400.00, marker 2026-09-01, paying Chase.

**Expected.** Remainder exactly 0 cents. Headline 'Safe to spend: $0' with NO parenthetical. Part 3 'That leaves $0.00 — nothing left.' No shortfall sentence. This state contributes no warning glyph. Assert the menu-bar string differs from the negative case's string.

### 22. negative_figure_and_menu_bar

**Setup.** Today 2026-09-14. Chase Checking (manual, checking) $1,279.40, balance_date 2026-09-14. Unpaid Rent $1,400.00, marker 2026-09-01, paying Chase. Pay anchor 2026-09-11.

**Expected.** Remainder -$120.60. Headline 'Safe to spend: $0 (balance: -$121)' — rounded AWAY from zero. Per-day allowance $0 (spoken as '$0 a day'). Part 3 'You're $121 short of this month's bills.' Menu bar and small widget '$0 (-$121)' with the warning glyph. Assert the menu-bar string is not equal to the exactly-zero case's string. Second variant: remainder -$0.40 renders '$0 (balance: -$0.40)'.

### 23. remainder_under_one_dollar

**Setup.** Today 2026-09-14, pay anchor 2026-09-11 (divisor 11). Variant A: Chase Checking $1,400.75, unpaid Rent $1,400.00 marker Sep 1. Variant B: Chase Checking $1,400.05, same rent. Variant C: Chase Checking $1,421.99, same rent.

**Expected.** A: headline '$0.75' (never '$0'), allowance floor(75/11)=6 -> 'about $0.06 a day', part 3 'That leaves $0.75.' B: headline '$0.05', allowance floor(5/11)=0 so the per-day phrase is OMITTED entirely — 'Until payday on September 25: $0.05 left.' and never 'about $0.00 a day'. C: headline '$21', allowance floor(2199/11)=199 -> 'about $1.99 a day' (never 'about $1 a day'). Assert no rendered string on any surface contains a bare '$0' while the exact figure is positive.

### 24. freshness_boundary_ignores_time_of_day

**Setup.** Chase Checking (manual, checking) $3,120.00. Variant A: balance_date 2026-09-06 23:00 CDT, evaluated 2026-09-14 00:30 CDT. Variant B: balance_date 2026-09-07 00:00 CDT, same evaluation instant. Variant C: balance_date 2026-09-10 23:00 CDT, same evaluation instant. Variant D: A's data evaluated at 2026-09-14 23:59 CDT.

**Expected.** A: 8 calendar days -> DEAD, excluded, named under the number with 'stopped updating Sep 6'. B: 7 days -> STALE, counted, headline gains 'as of Sep 7 — may have changed'. C: 4 days -> STALE, counted. D: identical classification to A — the tier must not depend on the time of the reading. Assert an elapsed-seconds implementation (which makes A 7 days and C 3 days) fails.

### 25. payday_today_balance_predates_the_pay

**Setup.** Pay anchor 2026-09-25 (paydays Sep 25, Oct 9). Chase Checking (manual, checking) $300.00, balance_date 2026-09-24. Unpaid Rent $1,400.00 marker 2026-10-01 and Spotify $12.00 marker 2026-10-05, both paying Chase. Variant A: today 2026-09-25. Variant B: today 2026-09-26, balances still stamped Sep 24. Variant C: today 2026-09-25 with a second contributing account stamped 2026-09-25.

**Expected.** A: next payday Oct 9, window [Sep 1, Oct 8], figure exactly -$1,112.00, headline '$0 (balance: -$1,112)', allowance $0; payPending is SET, and the explanation reads 'Your pay from Sep 25 isn't in these balances yet — the newest balance here is from Sep 24. Counted without it, the bills due before Oct 9 come to $1,412 against the $300 your bank last showed.' with no bare 'You're $1,112 short' sentence. B: payPending still SET (a 'today is a payday' gate would fail this). C: payPending NOT set. Assert the arithmetic is byte-identical across A and C — only the wording differs.

