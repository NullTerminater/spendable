# Reading the bank

This is the contract for the SimpleFIN client and the sync engine: how the app gets a credential,
how it asks for data, what it does with the answer, and what it does when the answer is bad. It is
written out in full for the same reason `docs/ENGINE.md` is — a wrong rule here puts wrong numbers
in front of someone who is trusting them.

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
  for every account, so the count is only ever taken from an answer that actually lists them.

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
5. **It writes the credential to the Keychain and reads it back, comparing byte for byte, before it
   does anything else with the response.** A setup token is single-use: if the write silently failed
   the token would be spent and unrecoverable.
6. A 403 means the token was already claimed or never existed: "This setup token was already used or
   doesn't exist. If you didn't use it in another app, someone else may have — disable it on the
   SimpleFIN website, then generate a fresh one." Any other status asks for a fresh token.

The claim response is held in memory only until the Keychain write is confirmed, and never logged.

**If the Keychain write fails after a successful claim**, the token is already spent and the answer
exists nowhere else, so it is kept in memory for the rest of the session rather than discarded:
"Your setup token has already been used up — don't generate another one yet. macOS wouldn't let me
save the connection. Unlock your login keychain and press Retry."

Reading is the same distinction in reverse. Only `errSecItemNotFound` means "not connected".
`errSecInteractionNotAllowed`, `errSecAuthFailed` and `errSecUserCanceled` are macOS refusing, which
is its own state — "macOS wouldn't let me read your saved connection" — and must never reach the
re-connect banner, which is reserved for a server that actually answered 403.

## Asking for data

`GET {base}/accounts` with HTTP Basic credentials **in an `Authorization` header**, never in the
URL. A URL with credentials in it ends up in logs, crash reports and error messages; a header does
not.

| Parameter | When |
|---|---|
| `version=2` | Always |
| `balances-only=1` | The one request that reads balances. Sent with `version=2` and nothing else |
| `start-date`, `end-date` | Only when transactions are being fetched, always as a pair, as **UTC** midnight |
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

Status handling: 200 is parsed; 402 is "your SimpleFIN subscription needs renewing"; 403 is the
whole-token failure below; anything else is a plain "couldn't reach SimpleFIN" with the status
recorded in the log and nothing else.

## What the answer means

Decoding is strict in one direction and forgiving in the other: unknown keys are ignored, but a
missing `errlist` is a decoding failure rather than "no errors". Amounts are parsed by the exact
cents parser; a value that will not parse fails that account rather than becoming zero.

Every error is routed by the prefix of its code, because the subcode may be one the app has never
heard of:

| Code | Belongs to | What the owner sees |
|---|---|---|
| `act.*` | The named account | Shown against that account |
| `con.*` | Every account of that connection | "Chase needs you to sign in again on the SimpleFIN website" |
| `gen.auth` | The whole connection | A banner: the saved connection no longer works, paste a new setup token |
| `gen.api` | The developer | Logged only. It is about how the app asked, not about the owner |
| anything else | Treated as its prefix | |

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
rolling 24 hours, of which at most 6 may be history windows — so filling in history deliberately
spreads over two days rather than colliding with the day's ordinary refreshes. Every sync runs
through one actor, so two triggers at the same instant become one run.

The cadence inside that budget:

- A balances-only refresh every six hours, at a fixed minute chosen away from the top of the hour,
  since the Bridge is busiest then.
- A full transaction pull once a day.
- On launch, only if the last successful sync is more than six hours old.
- Manual refresh while budget remains; otherwise: "Already refreshed today. SimpleFIN only gets new
  bank data about once a day, so there's nothing new to fetch."

The data is a day old by nature. Asking more often cannot make it newer.

## Filling in history

**No request the app builds ever spans more than 44 days, on any path.** When the gap since a
watermark is wider than that, the backwards walk is planned instead of one long request the server
would trim. A `gen.api` message saying the range *was* capped is a hard failure: nothing from that
answer is written — no transaction, no watermark, no progress — because the app cannot tell which
part is missing, and a gap nobody notices is worse than a sync that failed loudly.

On first connection the app walks backwards in **44-day windows with a 5-day overlap**, newest
first, sending both dates every time, as UTC midnight. It stops at whichever comes first: two
consecutive windows with nothing new, thirteen months, or the window limit.

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
matched on what it *is*: same account, same day, same amount, same description, and an id that
appears nowhere in this answer. Matches are paired off greedily rather than one at a time, which is
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
- A row with `voided_at` or `superseded_by` set is history, not money. Every total, count and
  grouping carries `AND voided_at IS NULL AND superseded_by IS NULL`.

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

**An account write touches only the columns the server owns**: the remote name, the connection
fields, the currency, the balances, the holdings count and when it was last seen. `INSERT OR
REPLACE` is banned outright — it deletes the row first, and the cascade would take the owner's whole
transaction history with it — and so is a blanket upsert, which would quietly undo the owner's
account-type correction on every refresh.

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

- The response is decoded and inserted inside one write transaction, and the raw data is released as
  soon as its scope ends.
- Nothing accumulates an array of every transaction. Rows are inserted as they are decoded.
- Sync work happens off the main actor, at utility priority.
- A test pushes a year of synthetic transactions through the real ingestion path and asserts the
  **live heap** returns to where it started, measured with `malloc_zone_statistics`. `phys_footprint`
  is reported but not asserted: freed malloc pages stay resident so it does not come back down, and
  inside a test host it is dominated by the rest of the suite. A second test proves the response
  data is released when its scope ends, using a buffer that reports its own deallocation.
