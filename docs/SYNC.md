# Reading the bank

This is the contract for the SimpleFIN client and the sync engine: how the app gets a credential,
how it asks for data, what it does with the answer, and what it does when the answer is bad. It is
written out in full for the same reason `docs/ENGINE.md` is — a wrong rule here puts wrong numbers
in front of someone who is trusting them.

Everything below about the server's behaviour was checked against the live SimpleFIN Bridge on
2026-09-14, not inferred from the specification. Where the two differ, the live behaviour is noted.

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
  capped." A 45-day span with **no** `end-date` also warns; the same span **with** an explicit
  `end-date` does not. So every request sends both dates, and windows are 44 days.
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
  has posted. Accounts carry a `holdings` array, which this app ignores.

## Getting a credential

1. The owner pastes a setup token, which is a base64-encoded URL.
2. The app decodes it and checks the result is an `https` URL with a host. Anything else is rejected
   before a single byte goes out.
3. It POSTs to that URL with an empty body and `Content-Length: 0`.
4. A 200 returns an access URL: a URL with a username and password in it. The app splits it into a
   base URL, a username and a password, and requires all three.
5. **It writes the credential to the Keychain and reads it back, comparing byte for byte, before it
   does anything else with the response.** A setup token is single-use: if the write silently failed
   the token would be spent and unrecoverable.
6. A 403 means the token was already claimed or never existed: "This setup token was already used or
   doesn't exist. If you didn't use it in another app, someone else may have — disable it on the
   SimpleFIN website, then generate a fresh one." Any other status asks for a fresh token.

The claim response is held in memory only until the Keychain write is confirmed, and never logged.

## Asking for data

`GET {base}/accounts` with HTTP Basic credentials **in an `Authorization` header**, never in the
URL. A URL with credentials in it ends up in logs, crash reports and error messages; a header does
not.

| Parameter | When |
|---|---|
| `version=2` | Always |
| `balances-only=1` | Routine refreshes, which are most of them |
| `start-date`, `end-date` | Always sent together, as whole-day epoch seconds |
| `pending=1` | Whenever transactions are being fetched |

The session is ephemeral with no cache, no cookies and no credential store, so nothing is written to
disk by URLSession. **Redirects are refused**: a redirect off the expected host with an
`Authorization` header attached would hand the credential to whoever answered. Only `https`.

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

The Bridge expects at most 24 requests a day and disables the token beyond that. The app keeps a
**local ceiling of 12 a day**, counted in `sync_state` and reset at local midnight:

- A balances-only refresh every six hours, at a fixed minute chosen away from the top of the hour,
  since the Bridge is busiest then.
- A full transaction pull once a day.
- On launch, only if the last successful sync is more than six hours old.
- Manual refresh while budget remains; otherwise: "Already refreshed today. SimpleFIN only gets new
  bank data about once a day, so there's nothing new to fetch."

The data is a day old by nature. Asking more often cannot make it newer.

## Filling in history

On first connection the app walks backwards in **44-day windows with a 5-day overlap**, newest
first, sending both dates every time. It stops at whichever comes first: two consecutive windows
with nothing new, thirteen months, or nine windows.

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

Pending transactions change. They can vanish, or post later with a different id and a slightly
different amount. So on each sync:

- A pending row still present stays pending, with its fields refreshed.
- A settled row that matches an earlier pending one — same account, same amount, same normalised
  description, within five days — marks that pending row as superseded rather than adding a second.
- A pending row absent from two consecutive responses that covered its date is marked void, not
  deleted. Rows are never deleted; the owner's history is not the app's to throw away.

`posted` is 0 for a pending transaction, so the date used for everything is `posted` when it is
non-zero, otherwise `transacted_at`, otherwise the day it was first seen.

Balances are only ever taken from a request with no `end-date`. A historical window returns
historical transactions but the same current balance, and writing that as the balance for an old
window would be wrong.

## Never in a log, never in a file

The credential is one Keychain item; nothing else stores it. `SimpleFINCredential` prints as
`<redacted>` in both description forms, so it cannot be interpolated into a message by accident.
Errors carry a status code and a hostname and nothing else. No response body, no URL with
credentials, no balance and no transaction is ever logged, at any level.

The test fixtures are the public demo data or written by hand. No real balance, account number or
token goes into this repository, including in a commit message.

## Memory

The specification's target is a menu bar app that is effectively free to run, and a year of
transactions must not be held in memory to be stored.

- The response is decoded and inserted inside one write transaction, and the raw data is released as
  soon as its scope ends.
- Nothing accumulates an array of every transaction. Rows are inserted as they are decoded.
- Sync work happens off the main actor, at utility priority.
- A test pushes a year of synthetic transactions through the real ingestion path and asserts the
  process's physical footprint stays inside its budget.
