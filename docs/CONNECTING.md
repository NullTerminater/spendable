# Connecting a bank, and keeping it connected

The contract for milestone 4: how the owner attaches their bank, how the app decides what kind of
account each one is, what it says when a balance goes quiet, and how often it asks. `docs/SYNC.md`
covers what happens on the wire; this covers what the owner sees and what the app does on its own.

## Pasting a setup token

One screen, one field. The owner makes a token on the SimpleFIN website and pastes it here.

- The field is a plain text field, never a secure one: the owner needs to see that the paste landed,
  and hiding it helps nobody when the value is already on their clipboard.
- **What they pasted is never echoed back to them in an error.** "That doesn't look like a SimpleFIN
  setup token" is the whole message. A setup token is a bearer credential; repeating it into an
  alert puts it somewhere it can be screenshotted.
- It is validated before a byte goes out: base64, decoding to an `https` URL with a host.
- Connecting shows what is happening in order: "Asking SimpleFIN for your accounts…", then
  "Getting your history: window 3 of 11." — a sentence, not a spinner, because the history walk
  takes several requests and stops deliberately partway.

Outcomes, in the owner's words:

| What happened | What they read |
|---|---|
| Worked | "Connected. I found 3 accounts." and the accounts screen |
| Token already used | "This setup token was already used or doesn't exist…" |
| Keychain refused the write | "Your setup token has already been used up — don't generate another one yet." plus Retry |
| No internet | "I couldn't reach SimpleFIN. Check your internet connection." |
| Subscription lapsed (402) | What was observed, plus SimpleFIN's own words |
| Budget spent mid-history | "I'll carry on filling in your history tomorrow" — the connection is fine |

A history walk that stops on budget is **not** a failed connection. The accounts and balances are
already in; the app says so rather than showing an error next to a bank that is working.

## Deciding what kind of account each one is

SimpleFIN does not say. It gives a name, a balance and a currency, so the app guesses — and the
specification is explicit that getting this wrong silently is worse than asking.

**The name is the evidence.** Lower-cased, matched against words a person would recognise:

| Type | Words |
|---|---|
| checking | checking, chequing, current, spending, everyday, debit |
| savings | savings, saver, money market, reserve, emergency, rainy |
| credit | credit, card, visa, mastercard, amex, american express, discover, platinum, sapphire, rewards |
| cash | cash, wallet, pocket |

**Holdings beat every keyword.** An account the bank reports holdings for is investments, whatever
it is called, and is never guessed as checking, savings or cash. The demo shows why: its savings
account holds six figures of Apple stock and is called "SimpleFIN Savings", so a name-based guess
would have turned a share portfolio into spendable money that moves with the market. Such an account
is **never counted in a total even if the owner opts in**, and says why on its own row.

**The balance sign is a weak hint, never a verdict.** A negative balance on an account with no
keyword suggests a card, but the SimpleFIN protocol never defines a sign convention for what an
account owes, and real feeds differ by bank. So it promotes a guess from "none" to "credit" and
never overrules a keyword.

**What a guess is allowed to do.** A guess backed by a keyword counts toward the number straight
away, with "Is this right?" on its own row — the owner can see it and change it in one click. An
account with no keyword and no holdings is **not** counted: it appears with "Tell me what kind of
account this is", it is named under the number, and the app says the total is incomplete. That is
the specification's rule that an unanswered question is better than a silent wrong answer.

**A correction is permanent.** It is stored separately from the guess and the guess never overwrites
it, so a later sync cannot undo it. The same is true of a renamed account, an "amounts look
reversed" correction, and the savings opt-in.

**The bank's available balance is only used once the owner has confirmed the account is a current
account** — never on a guess. A guessed-checking account that is really a card would otherwise put
its credit limit into the number.

## An account that goes quiet

The engine already decides what counts (`docs/ENGINE.md`); this is what the owner reads.

Each account row says when its balance is from, in words: "as of this morning", "as of Thursday",
"as of 3 September". Past a few days it says so; past a week it stops counting and says that too,
differently depending on whose fault it is:

- Hand-entered: "You last updated this on 3 September. Update it and I'll count it again."
- Synced: "Your bank stopped sending new balances on 14 August, so I don't know what's in it now."

An account that **vanishes from an otherwise good sync** is marked as not updating from that moment,
not after its balance ages out. That is the failure the specification names: other apps have shipped
a green tick over data that stopped a month ago.

When SimpleFIN rejects the whole credential, a banner sits above everything: "SimpleFIN no longer
accepts the saved connection. Paste a new setup token." When macOS merely refuses to *read* the
keychain, that is a different banner and must never be confused with the first, because one asks the
owner to burn a token and the other asks them to unlock their keychain.

An account can be put away. Archiving hides it from the accounts list and from every total, but its
bills keep being subtracted — a closed account cannot pay anything, so that money comes out of an
account that is counted, and the app says so rather than deciding quietly.

## How often the app asks

One scheduler for the whole app. No polling, nothing that wakes the process when nothing has
changed, and everything inside the budget in `docs/SYNC.md` (14 requests in a rolling day, of which
6 may be history).

- **One `NSBackgroundActivityScheduler`**, every 6 hours, tolerance 1 hour, at utility quality of
  service. The system coalesces it with other work rather than waking the Mac for it.
- **At a fixed minute chosen once at random** and kept, because the Bridge is busiest at the top of
  the hour and tells developers so.
- **On launch, only if the last successful sync is more than 6 hours old.** Opening the app ten
  times in an afternoon costs nothing.
- **On wake and on the day changing**, only if a sync is already overdue, debounced so ten wakes in
  an evening are one check.
- **Manual refresh** runs while budget remains, and otherwise says why.

Balances are cheap and come every time. A full transaction pull happens once a day, because
SimpleFIN itself only collects from banks about once a day: asking more often cannot produce newer
numbers, and the specification says so.

Nothing is scheduled at all until a credential exists. An app with no bank connected does no work.
