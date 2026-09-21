# Reading the bank

This is the contract for the SimpleFIN client and the sync engine: how the app gets a credential,
how it asks for data, what it does with the answer, and what it does when the answer is bad. It is
written out in full for the same reason `docs/ENGINE.md` is — a wrong rule here puts wrong numbers
in front of someone who is trusting them.

This describes the implementation through milestone 4. [CONNECTING.md](CONNECTING.md) covers its
setup and recovery screens; [PLAN.md](PLAN.md), binding rule 13, records the owner's approval
to repair a rejected credential now. Replacing a working credential remains milestone 9. The
milestone 3 and 4 review files are preserved as historical decisions, not edited to look like a
record of shipped behavior.

Everything below about the server's behaviour was checked against the live SimpleFIN Bridge on
2026-09-14 and 2026-09-15, not inferred from the specification. Where the two differ, the live
behaviour is noted.

An earlier draft of this document was reviewed before any of it was built, by five readers working
from the specification, the schema and their own probes of the live server. They found forty
problems in it, four of which would have shipped: a balance rule that could never fire, a rule that
read a balances-only answer as proof no transactions existed, an account write that would have
deleted the owner's transaction history, and a password decoded with an API that returns it still
percent-encoded — which would have stored a wrong password, verified it against itself, and spent
the single-use token doing so.

## What the server actually does

- The host is `beta-bridge.simplefin.org`. `bridge.simplefin.org/simplefin/...` redirects there. The
  base URL comes from the claimed access URL and is never hardcoded.
- The protocol document is version 2. **Without a `version` parameter the server answers in the v1
  shape** (`errors` as strings, an `org` object per account). With `version=2` it answers with
  `errlist` (structured errors carrying `conn_id` / `account_id`), a `connections` array, and a
  `conn_id` on each account. The two are mutually exclusive on the wire, and only v2 can put an
  error next to the account it belongs to, which the owner's specification requires. The app is
  v2-only and always sends `version=2`.
- **A request is capped at 90 days** and carries a `gen.api` warning above 45. Asking for a year
  returns the most recent ~89 days with "Requested date range exceeds limit of 90 days and was
  capped." That arrives as HTTP 200 and looks complete. The two `gen.api` messages must be told
  apart by tense: "may be capped" is advice, "was capped" is a hole in the data.
- **A request carrying an `end-date` is answered with the balance as of that date**, and sets
  `balance-date` to the end-date it was given. This is why the balance rule below is what it is: a
  history window returns a genuinely historical balance, not today's.
- **Historical windows do return historical data.** A window 180 to 135 days back returned 166
  transactions from March to May. Walking backwards in windows is therefore worth doing; how far
  back anything exists varies by institution.
- **The quota is 24 requests a day**, warnings first, then the access token is disabled — which
  forces the owner to make a new setup token by hand, the exact thing the specification calls
  painful. The app keeps its own, lower budget.
- Wrong credentials return HTTP 403 with `{"errlist":[{"code":"gen.auth","msg":"Forbidden"}],
  "accounts":[],"connections":[]}`. **An empty account list with a `gen.auth` error is exactly what
  a dead connection looks like**, and is the failure the specification warns about most.
- Claiming an already-claimed token returns HTTP 403 with the plain text body
  `Forbidden (was it already claimed?)`.
- Transactions carry `id`, `posted`, `amount`, `description`, and the Bridge extras `payee`, `memo`,
  `transacted_at` and `mcc`. The `pending` key is **absent** rather than false when a transaction
  has posted. Some accounts carry a `holdings` array — a Bridge extension, absent from the protocol.
  Its contents are ignored but its **size is recorded**, because SimpleFIN carries no account type
  and holdings are the strongest signal that a balance is a market value rather than money: the
  demo's savings account holds six figures of stock and is called "SimpleFIN Savings", so a
  name-based guess would make it spendable. A balances-only answer returns an empty holdings array
  for every account, so that empty array is not evidence. A positive array on either request shape
  records investment holdings. A dated answer with a holdings key also records
  `holdings_observed_at`, even when the array is empty; only that dated evidence releases the
  checking/cash guess gate described in [ENGINE.md](ENGINE.md).

## Getting a credential

1. The owner pastes a setup token, which is a base64-encoded URL.
2. The app decodes it and checks the result is an `https` URL with a host. Anything else is rejected
   before a single byte goes out.
3. It POSTs to that URL with an empty body and `Content-Length: 0`.
4. A 200 returns an access URL: a URL with a username and password in it. The app splits it with
   `URLComponents`, reading `.user` and `.password`, and requires all three parts.
   **Never `URL.user()` or `URL.password()`**: verified on this toolchain, they return the values
   still percent-encoded despite the documented default, so a password of `pq/rs@tu` arrives as
   `pq%2Frs%40tu`. Writing that to the Keychain and reading it back compares equal to itself, so the
   app would "verify" a password the server will never accept, with the single-use token already
   spent.
5. **It writes the credential to the Keychain and reads it back, comparing the credential and receipt, before it
   does anything else with the response.** A setup token is single-use: if the write silently failed
   the token would be spent and unrecoverable.
6. A 403 on the claim means the token was already claimed or never existed: "This setup token was already used or
   doesn't exist. If you didn't use it in another app, someone else may have — disable it on the
   SimpleFIN website, then generate a fresh one." A local claim attempt in the preceding hour uses
   the more specific spent-token explanation in [CONNECTING.md](CONNECTING.md). A dropped claim
   explains that the app cannot know whether the token was spent; other failures retain their own
   subscription, server or malformed-answer diagnosis.

The claimed credential is held in memory until its save is verified, and is never logged.

**If the Keychain write fails after a successful claim**, the token is already spent and the answer
exists nowhere else, so it must be kept in memory for the rest of the session rather than discarded,
and the owner told: "Your setup token has already been used up — don't generate another one yet.
macOS wouldn't let me save the connection. Unlock your login keychain and press Retry."
Milestone 4 implements this in `AppModel.unsavedConnection`: closing a window retains it, Try again
retries saving without another POST, and no first-connection account request is sent before the
read-back verifies. Quitting while it is unsaved requires the explicit warning in CONNECTING.
Successful saving records `connected-at` and starts the shared scheduler and first sync.

A newly saved credential carries `awaiting-first-balance` until the first successful balances
answer. A rejection before that point says "SimpleFIN rejected the credential I just stored. This
is a bug in Spendable, not a problem with your token — don't generate another one." The saved
credential remains available to Check again; a normal re-claim prompt must not burn another token
automatically. The distinction survives relaunch. The owner may explicitly confirm Replace anyway,
recorded separately as `unverified-replacement-approved`; a newly saved replacement gets the same
first-answer protection again. Both flags clear on successful balances.

Recovery of a previously rejected credential follows PLAN rule 13 and CONNECTING: pause new
syncs, let the current run finish, stage and verify the replacement while the old credential remains
readable, then promote it. Saving failure retains the new claim for Retry and preserves the old
credential. Successful replacement clears the rejection marker, restarts `backfill-progress` and
clears `transactions-pulled-at`; accounts, transactions, corrections, rolling request budgets and
quota warnings remain. Reports from the old credential cannot overwrite the new presentation.
If a replacement sends a different `conn_id`, ingestion adopts exactly one existing non-archived
synced row matching `(org_id, external_id)` only when its old connection is absent from the response's
`connections` array. Two live logins at the same institution therefore remain separate. An unmatched
old account keeps its data and is marked as not updating when absent from a nonempty balance answer.

**A saved credential must survive the gap before database bookkeeping.** Each new save or promotion
stores an opaque random receipt inside the encrypted Keychain payload. The receipt is unrelated to
the credential's contents; it is not a token, password or credential hash. Loading the credential and
its receipt is one atomic read. The database stores only the applied receipt's generation under
`credential-generation-applied` in `sync_state`. On startup, on setup entry, and before the first
ordinary sync or repair controls can proceed, the app reconciles an unapplied receipt: it applies the connection/replacement
bookkeeping and the generation marker in the same database transaction. This repairs a crash after
Keychain promotion even when the database still says the old credential was rejected. It consumes
no requests, changes no budget or quota reservations, and does not reset history again once that
receipt has been applied.

Legacy Keychain payloads without receipts remain readable while no generation has been tracked.
A missing receipt after one has been tracked fails closed; it never opens a fresh token field.
If the Keychain save has been read back successfully but database bookkeeping fails, the connection
is durable. The app offers Check again to retry local bookkeeping before any request; it does not
claim that quitting would lose the saved connection or ask for another setup token.

Reading is the same distinction in reverse. Only `errSecItemNotFound` means "not connected".
`errSecInteractionNotAllowed`, `errSecAuthFailed` and `errSecUserCanceled` are macOS refusing, which
is its own state — "macOS wouldn't let me read your saved connection" — and must never reach the
re-connect banner, which requires an actual server credential rejection (HTTP 403 or `gen.auth`
inside HTTP 200), with the first-answer distinction above.

## Asking for data

`GET {base}/accounts` with HTTP Basic credentials **in an `Authorization` header**, never in the
URL. A URL with credentials in it ends up in logs, crash reports and error messages; a header does
not.

| Parameter | When |
|---|---|
| `version=2` | Always |
| `balances-only=1` | The one request that reads balances. Sent with `version=2` and nothing else |
| `start-date`, `end-date` | Only when transactions are being fetched, always as a pair, as **UTC** midnight. `end-date` is **exclusive** — the protocol's "before, but not on" — so a window whose last day is the 14th is sent as the midnight that begins the 15th. Sending the 14th would silently drop the 14th |
| `pending=1` | Whenever transactions are being fetched |

The session is ephemeral with no cache, no cookies, no credential store and no proxy, so URLSession
writes no cache, cookie or credential file. That is not the whole disk story: `CFNETWORK_DIAGNOSTICS`
writes full request headers, `Authorization` included, into `~/Library/Logs/CrashReporter`, so it
must never appear in `project.yml` or a scheme; and an Xcode memory graph is a process corpse
containing the header verbatim, so a `.memgraph` never goes into this repository or onto a bug
report.

**Redirects are never followed.** Not because the header would leak — CFNetwork strips a manually
set `Authorization` across a redirect — but because following one silently downgrades the request to
unauthenticated, and an unauthenticated request to the Bridge answers 403, which this document's own
table would then turn into "your connection died, paste a new setup token". A 3xx is its own
diagnosed state, named by where it points: `bridge.simplefin.org` answers every path with a 302 to
the beta root, dropping the path and query, so it can be neither followed nor ignored.

**The `Authorization` header goes to one host: the one in the Keychain item's base URL.** The
response hands the app three server-controlled URLs — `sfin_url`, `org_url`, `org.domain` — and none
is ever dialled, in this milestone or any later one. They are display strings at most.

Status handling: 200 is parsed; 402 is "SimpleFIN answered 'payment required', which usually means
the subscription needs renewing", with the server's own words appended when it sent any; 403 is the
whole-token failure below; a 3xx is the redirect failure above, named by the host it points at and
never followed; anything else is "SimpleFIN answered in a way I didn't expect (503). Nothing has
changed; I'll try again later." — the number, and nothing else from the response. A request that
never got an answer at all is separate: it becomes "I couldn't reach SimpleFIN", with no URL and no
underlying error kept.

## What the answer means

Decoding is strict in one direction and forgiving in the other: unknown keys are ignored, but a
missing `errlist` is a decoding failure rather than "no errors". Amounts are parsed by the exact
cents parser, and a value that will not parse is never turned into zero and never quietly dropped. A
**balance** that will not parse fails that account: it keeps the balance it had, is marked as not
updating, and gets a notice of its own. A **transaction** amount that will not parse leaves that
account's window uncovered — the rows that could be read are still stored, because a charge arriving
twice is handled and a charge arriving never is not, but the watermark stays where it was so the
span is asked for again, and the owner gets a notice saying a charge is missing.

Every error is routed by the prefix of its code, because the subcode may be one the app has never
heard of:

| Code | Belongs to | What the owner sees |
|---|---|---|
| `act.*` | The named account | Shown against that account |
| `con.*` | Every account of that connection | Shown against every account of that connection, in SimpleFIN's own words — the app writes none of these sentences itself |
| `gen.auth` | The whole connection | A rejected-credential banner, or the first-answer diagnostic above when the credential has never been accepted |
| `gen.api` about how the app asked | The developer | Logged only. It is about how the app asked, not about the owner |
| `gen.api` about the rate | The owner, and the budget | Shown once, attributed to SimpleFIN, and `quota-tripped-at` is written: every non-manual sync stops for twenty-four hours, and a manual refresh is refused with "SimpleFIN warned that I've been asking too often, so I've stopped for today to keep your connection working." Recognised in the deprecated `errors` array too, which is where the Bridge's own guide says the warning arrives |
| anything else | Treated as its prefix | |

`SimpleFINIngest.route` attaches every error to an account, a connection, the whole credential,
everything, or the developer, and returns `SyncOutcome.notices`. Milestone 4 persists the balance
answer's notices in `connection-notices` and displays account and connection causes in their rows
and disclosure. Notices first received in a dated answer are deduplicated and merged into that
stored list in the same write as ingestion, and also appended to the run's report. A historical
answer cannot erase a balance failure notice. Scoped errors mark the affected accounts as not
updating and leave the dated window incomplete, so the same span is retried.

`gen.auth` inside HTTP 200 is a rejection, never a successful balance. A rejection during history
also persists `credential-rejected` and marks the synced accounts as not updating, even if balances
arrived earlier in the run. `connectionIsWorking` is false and `needsAttention` is true for that
report. The original balances and transaction history remain stored.

Error text from the server is shown as plain text, never as markup, and is always attributed to
SimpleFIN rather than presented as the app's own words.

## When a connection quietly dies

The failure the owner's specification calls out by name: a connection that returns
`gen.auth: Forbidden` and an empty account list while the dashboard still looks healthy, sometimes
for weeks. Other apps have shipped a green tick over data that stopped a month ago.

So: **a sync that returns no accounts is never treated as "you have no accounts".** Every account
carries `last_seen_in_sync_at`. After a successful response, accounts that were present keep their
new timestamp; accounts that were previously seen and are now absent keep their last known balance
and are marked as not updating **immediately**, not after a week of ageing. The engine already
excludes them from the total and names them under the number.

A response whose `accounts` array is empty while the database holds accounts never advances any
watermark and never overwrites a balance.

## Not asking too often

The Bridge expects at most 24 requests a day, in a time zone it never states, and disables the token
beyond that. So the app counts a **rolling 24 hours**, never a calendar day: a per-day ceiling of
twelve permits twenty-four inside one server day by spending twelve late one evening and twelve
early the next morning, and a time-zone change resets it for free.

A request is **reserved before it is sent**, in its own committed write, so a crash between spending
and recording can only ever over-count, which is safe. Counting successes instead would under-count,
and the server counts every request it served whether or not the answer arrived. At most 14 in any
rolling 24 hours, of which at most 6 may be backfill windows — so filling in history deliberately
spreads over two days rather than colliding with the day's ordinary refreshes.

There is exactly **one** `SyncCoordinator` in the process, owned by `AppModel` and handed to the
scheduler, the Refresh button, the launch poll and the wake and day-change observers; no other code
constructs one. It holds the run in progress as a single `Task` that a second trigger joins rather
than starting again, and the joining report says so (`joinedARunInProgress`). An actor alone is not
enough — it serialises statements, not whole operations, so two triggers would each get past the
budget check at a different `await` and each spend a request — and two *instances* share no
single-flight state at all: both reserve a balances request, both read `MIN(tx_synced_through)`
before either writes, and both buy the same 44-day window. Milestone 4 supplies this shared owner;
the Debug demo path also uses its coordinator. Tests may construct isolated coordinators against
their own stores, but production triggers never construct a second one.

The cadence inside that budget:

- The process owns one `NSBackgroundActivityScheduler`, with a six-hour interval, one hour of
  tolerance and utility quality of service. The hour of slack scatters the request away from the top of the hour,
  which the Bridge is busiest at. The API has no phase, start date or fire-time property, so the app
  cannot pick its own minute, and must never manufacture one with a `Timer`, a `DispatchSourceTimer`
  or a re-`schedule` on a short computed interval — that is the polling the specification forbids.
- A full transaction pull when the last one is more than twenty-four hours old:
  `SyncPolicy.transactionsStaleAfter`, measured from `transactions-pulled-at`. Every successfully
  completed dated window, including backfill, writes that timestamp; a window with a scoped error
  or unreadable transaction amount does not. Otherwise a run asks only for balances, except that
  inserting a new account forces a dated request so its holdings can be inspected. A new account
  also restarts a terminal history walk; neither this nor credential replacement resets budgets.
- On launch, `balances-synced-at` must be six hours old or more. Scheduled, wake and day-change
  triggers use five hours, so an activity firing early within its tolerance is not thrown away.
  Every automatic trigger also requires that nothing was *attempted* in the last thirty minutes
  (`quietAfterAnyAttempt`), the failure back-off has run out (half an hour, an hour, two, then six,
  by `sync-failures-in-a-row`), and the budget and SimpleFIN's own rate warning both allow it.
  A missing successful-balances timestamp is due immediately, subject to those same gates.
  Launch, wake and day change first wait for an online `NWPathMonitor` event, at most sixty seconds,
  without polling. An offline request that still occurs records its attempt and budget reservation,
  but does not increment the bank-failure count.
- Manual refresh bypasses time and failure-backoff gates, but respects the rolling budget and
  server quota warning. If the day is full, "Already refreshed today" is used only when successful
  balances really arrived today; otherwise the message says requests are spent and gives the last
  balance date. A quota warning asks the owner to wait. Exhausting only the backfill share after
  balances arrive is unfinished progress, with the older-history message from CONNECTING, not a
  broken connection.

Every scheduled run calls the OS activity's completion exactly once, through `SyncActivity.run`
or the local reconciliation-failure exit, even when policy skips, the Keychain refuses, the Mac is
offline or the budget is spent. It updates the same observable syncing and history-progress state
as a foreground refresh.

The data is a day old by nature. Asking more often cannot make it newer.

The shared cadence, budget and connection facts are kept in `sync_state`; per-account watermarks
remain on the account rows. `request-timestamps` and `backfill-request-timestamps` are the two rolling
counts; `quota-tripped-at` records SimpleFIN's own warning about the rate, and for twenty-four hours
after it every non-manual sync is skipped and a manual one is refused out loud; `balances-synced-at`
and `transactions-pulled-at` are the two cadence gates; `sync-attempted-at` is written before the
first request of a run, so a Mac waking again and again with no network backs off instead of
spending the day on requests nobody answered; `sync-failures-in-a-row` drives the back-off ladder of
half an hour, an hour, two, then six; `connected-at` is how the app knows it is connected — a
database fact, never a Keychain read, because asking macOS would turn a locked login keychain into
an app that silently stops scheduling; and `backfill-progress` is the history walk's place in the
queue. `connection-notices` stores the attributed notices shown by M4, `credential-rejected` stores
an explicit server rejection, and `awaiting-first-balance` plus `unverified-replacement-approved`
preserve the first-answer/recovery distinction above. `credential-generation-applied` identifies
the encrypted Keychain receipt whose bookkeeping has been committed. No credential, setup token or
credential-derived hash is stored in any of these rows.

## Filling in history

**No request the app builds ever spans more than 44 days, on any path**: the planner's windows are
44 days inclusive, and the incremental window refuses a wider gap outright. When the gap since a
watermark is wider than that, the backwards walk is planned instead of one long request the server
would trim. The client re-checks before building a URL, and its guard is one day loose — it compares
a zero-based day difference against 44, so a 45-day window would pass it. Nothing builds one, and 45
days only earns the Bridge's advisory warning rather than a trimmed answer; a test pinning 44 and 45
exactly would close it. A `gen.api` message saying the range *was* capped is a hard failure: nothing from that
answer is written — no transaction, no watermark, no progress — because the app cannot tell which
part is missing, and a gap nobody notices is worse than a sync that failed loudly.

On first connection the app walks backwards in **44-day windows with a 5-day overlap**, newest
first, sending both dates every time, as UTC midnight. Each window steps back thirty-nine days, so
eleven of them cover the thirteen months the app is willing to look — the eleventh reaching a little
over fourteen months back, because a window that crosses the boundary is still asked for whole. It
stops at whichever comes first: two consecutive successful windows with no transactions returned,
or the end of that list. A replay containing transaction ids already stored locally is not empty.
A routed account or connection error, or an unreadable transaction amount, leaves the window incomplete:
its cursor stays put and the next run asks for that same span again.
(The planner's `limit: 12` is a guard rather than a stop rule; the thirteen-month reach always ends
the walk first.)

The walk is the lowest-priority work in the app. Before each window it looks at the budget again and
stops while six or fewer of the day's fourteen requests are left —
`SyncCoordinator.headroomForOrdinaryWork` — so the day's balance refreshes and the owner pressing
Refresh always have room. Between that and the six-window share, a first connection fills in its
history over two days, and while it does the run reports `stillFillingHistory` rather than a failure:
a budget pause after balances arrived is a working connection, not a broken one.

Progress is written after every window, so a crash, a quit or a spent budget resumes where it left
off rather than starting again. Each account records how far back its history actually reaches, so
the subscriptions screen can say "history goes back to 12 June" instead of implying it looked
further.

Afterwards, sync is incremental: `start-date` is the oldest per-account watermark minus five days,
which is the overlap the Bridge itself recommends for transactions that post late. Overlapping rows
are recognised and not duplicated.

A watermark only moves forward for an account that was present in the response **with no error of
its own**. An account that errored keeps its old watermark, so the next sync asks again for the same
span instead of stepping over the gap.

## Not storing the same thing twice

A transaction's id is unique **within an account**, not globally — the demo server reuses every id
across its three accounts — so rows are keyed on the account and the id together.

But an id is a **hint, not an identity**. The protocol promises uniqueness, never stability, and the
owner's specification says a hold re-posts under a new one. So a row the app cannot place by id is
matched on what it *is*: same account, same amount, same description, the same effective moment **to
the second** — the `posted` value itself, not the calendar day it falls in — and an id that appears
nowhere in this answer. A charge that comes back with a shifted `posted` timestamp is not recognised
by this path; a hold that re-posts is caught by the ten-day reconciliation below instead. Matches are paired off greedily rather than one at a time, which is
what makes two identical coffees on the same day stay two rows, one-and-two become two, and
two-and-one stay two. Collapsing them would delete money the owner actually spent.

(The public demo server cannot verify any of this: it fabricates a fresh set of transactions on
every request, with new ids *and* new amounts, so nothing in it is the same charge twice.)

Pending transactions change. They can vanish, or post later with a different id and a slightly
different amount. So on each sync:

- A pending row still present stays pending, with its fields refreshed.
- A hold the bank is **still reporting in this answer** is never superseded, whatever else in the
  response looks like it. It has not posted; the bank just said so.
- A settled row supersedes a hold only when the hold is absent from this answer and the two share an
  account, an exact amount and a description, within ten days. Matching is one-to-one. If two
  candidates are indistinguishable, **neither** is superseded: showing a hold for one more day is
  better than attributing a charge to the wrong one and losing a real one.
- A hold is **never** voided merely for being absent. The app asks for a five-day overlap, so an
  older hold falls outside the window it asked for and its absence says nothing. It is written off
  only by age: ten days old, and not seen since. Rows are never deleted; the owner's history is not
  the app's to throw away.
- A row with `voided_at` or `superseded_by` set is history, not money. Every query that reads
  `bank_transaction` carries `AND voided_at IS NULL AND superseded_by IS NULL`. Today that means
  every query inside `SimpleFINIngest`, which is the only code that reads the table: the figure is
  built from balances and bills, so no total, count or grouping over transactions exists yet. The
  rule is written here in advance, for the transaction list and the merchant groupings in a later
  milestone — the first one that forgets the clause will show the owner money they did not spend.

`posted` is 0 for a pending transaction, so the date used for everything is `posted` when it is
non-zero, otherwise `transacted_at`, otherwise the day it was first seen.

**Balances come from one request and one only**: `version=2&balances-only=1`, which carries neither
date. Every sync begins with it, and it is the only answer allowed to write `balance_cents`,
`available_cents` or `balance_date`, and the only one allowed to create an account row at all — a
window cannot supply a balance date worth trusting. On any dated answer those three fields are
parsed and thrown away. A balance is also refused if it is older than the one already stored, so a
late reply cannot put back a stale figure.

**A balances-only answer says nothing about transactions.** The Bridge returns `"transactions": []`
for every account, which is byte-identical to "this account had no transactions in the window". So
only an answer to a request that did *not* carry `balances-only=1` may advance a watermark, resolve
a hold, or count toward the history walk's stop rule. Otherwise two routine refreshes on a Monday
afternoon would void every live hold and march every watermark forward on the strength of answers
that by definition contained no transactions.

**Sync updates server facts and derived sync state, preserving owner choices.** Existing rows
receive the remote name, connection fields, currency, guarded balances, holdings evidence and
seen/stopped/resumed timestamps. The name-based `guessed_type`, `guess_class` and `guessed_from_name`
are written on insertion, not recomputed on rename; observed holdings can permanently establish the
investment class. Confirmed types, display names and other owner corrections survive every refresh.
`INSERT OR REPLACE` is banned outright — it deletes the row first, and the cascade would take the
owner's whole transaction history with it — and so is a blanket upsert. The manual-duplicate
candidate and owner-confirmed merge rules are specified in CONNECTING and ENGINE.

## Never in a log, never in a file

The credential is one Keychain item; nothing else stores it. `SimpleFINCredential` prints as
`<redacted>` in both description forms, so it cannot be interpolated into a message by accident.
Errors carry a status code and a hostname and nothing else. No response body, no URL with
credentials, no balance and no transaction is ever logged, at any level.

The test fixtures are the public demo data or written by hand. No real balance, account number or
token goes into this repository, including in a commit message — `.githooks/commit-msg` is what
makes that promise true rather than hopeful, and no tool in this repository ever accepts a credential
or a claim URL as a command-line argument, because argv is visible in `ps` to every local process.

`SimpleFINCredential` also conforms to `CustomReflectable` with an empty mirror. Both description
forms returning "redacted" is not enough on its own: `dump()` and anything else built on `Mirror`
walks the stored properties and prints the password verbatim.

No app error ever stores an underlying `Error`. A `URLError` from the claim request carries the
failing URL in its `userInfo`, and that URL contains the setup token — a bearer credential.
`localizedDescription` hides it while `String(describing:)` does not, so a redaction test that
checked only the description would pass while the token went into the log.

There is one real Keychain item, `account = access`. The Debug-only demo connection writes to
`account = access-demo`, because Debug and Release share a bundle identifier and a login keychain,
and one careless write would destroy an access URL that cannot be recovered without making a new
token by hand.

## Memory

The specification's target is a menu bar app that is effectively free to run, and a year of
transactions must not be held in memory to be stored.

- The raw response `Data` is decoded once, inside the client, and is gone when that call returns.
  The decoded answer is then turned into rows inside one write transaction.
- What is bounded is the window, not the row. One answer — at most 44 days, for the accounts on one
  connection — is held while it is inserted, and nothing is carried from one window to the next,
  which is why a year can go in but is never in memory: a year is eleven separate windows. Rows are
  not streamed as they are decoded; `JSONDecoder` builds the whole `transactions` array first, and
  the matcher holds a dictionary of the rows it cannot place by id. Keeping the window small is what
  keeps this cheap.
- Sync work happens off the main actor: `SyncCoordinator` is a plain actor, and a run is an
  unstructured task inside it. The task inherits its caller's priority; milestone 4 sets `.utility`
  quality of service on the background activity itself.
- A test pushes a year of synthetic transactions through the real ingestion path and asserts the
  **live heap** comes back to within four megabytes of where it started, measured with
  `malloc_zone_statistics` after `PRAGMA shrink_memory`; the four megabytes are SQLite's own page
  cache, which grows with the database and is not the app holding transactions. A version that
  accumulated every decoded row would be holding several times that. `phys_footprint` is reported
  but not asserted: freed malloc pages stay resident so it does not come back down, and inside a
  test host it is dominated by the rest of the suite. A second test proves the response data is
  released when its scope ends, using a buffer that reports its own deallocation.
