# Milestone 3: the review's decisions

Output of the design review that ran before this milestone was implemented. Kept because the
reasoning behind several non-obvious rules lives here and nowhere else.

25 decisions, 13 rejected, 28 test cases.

## Decisions

### 1. `balance-provenance-only-from-the-dateless-request` (blocking)

Replace the parameter table row `| start-date, end-date | Always sent together, as whole-day epoch seconds |` with `| start-date, end-date | Only when transactions are being fetched; always as a pair, as UTC-midnight epoch seconds |`, and add a row `| balances-only=1 | The one refresh that reads balances; sent with version=2 and nothing else |`. Delete the sentence "A historical window returns historical transactions but the same current balance, and writing that as the balance for an old window would be wrong." and replace it with: "A request carrying an `end-date` returns the balance **as of that end-date**, and sets `balance-date` to the end-date it was given (verified live: end-date 1763510400 returned balance-date 1763510400 and a balance $733 lower than today's). So `balance`, `available-balance` and `balance-date` are read only from the response to `GET {base}/accounts?version=2&balances-only=1`, which carries neither date. On any dated response those three fields are parsed and discarded." Implementation: every sync begins with exactly one `version=2&balances-only=1` request. It is the only response allowed to run `UPDATE account SET balance_cents=?, available_cents=?, balance_date=?, holdings_count=?, last_seen_in_sync_at=? WHERE id=? AND ?>=balance_date` (the trailing guard is the new balance_date, so a late response cannot regress a newer one), and the only response allowed to INSERT an account row at all — a windowed response containing an account id the database does not hold skips that account and logs it, because balance_date is NOT NULL and a window cannot supply a trustworthy one. The ingestion entry point takes an explicit `enum ResponseKind { case balances, window(start: Int64, end: Int64) }`; the balance-writing code path is unreachable from `.window`.

**Why.** Three lenses probed this independently and all three got balance-date echoing the requested end-date with a genuinely historical balance value. SYNC.md's stated fact is wrong and its own protective rule is unreachable under its own parameter table: if every request carries an end-date, no request qualifies to write a balance, balance_date never moves, and after 7 days ENGINE.md holds every account out and the dashboard reads "I can't work this out right now" over a healthy feed. The other branch is worse — a nine-window backfill ends with today's row holding a ten-month-old balance $915 wrong.

### 2. `balances-only-is-not-transaction-evidence` (blocking)

Add to "What the answer means": "Every response is ingested together with the request that produced it. A response to a request carrying `balances-only=1` says **nothing** about transactions: the Bridge returns `\"transactions\": []` for every account (see Tests/Fixtures/Demo/v2-balances-only.json), which is byte-identical to 'this account had no transactions'. The protocol also lists `transactions` as optional on Account, so an absent key and an empty array are the same statement. Only a response to a request that did **not** carry `balances-only=1` may advance `tx_synced_through`, resolve or void a pending row, or count toward the backfill's empty-window run." Implementation: the three rules take `ResponseKind` and assert `case .window` before acting; `ingest(_:kind: .balances)` touches only the account row's balance columns, `last_seen_in_sync_at`, `holdings_count` and the absent-account sweep.

**Why.** With the design's own cadence (balances-only every six hours, one full pull a day), two routine refreshes on a Monday afternoon void every live pending row and advance every watermark to Monday on the strength of responses that by definition contained no transactions — and can also satisfy the backfill's two-empty-windows stop, ending the history walk early while the app tells the owner how far back its history goes.

### 3. `never-build-a-span-over-44-days-and-capped-is-a-hard-failure` (blocking)

Add to "Filling in history": "No request the app builds ever spans more than 44 days, on any path. The incremental start-date is `min(tx_synced_through) - 5 days`; when `today - that` exceeds 44 days the request is not sent — the same 44-day backwards walk used on first connection is planned instead and runs under the backfill budget. An account frozen at its old watermark by an error therefore produces more windows, never one over-long request." Split the `gen.api` row of the error table into two rows: `| gen.api, recommendation text ("exceeds recommended range of 45 days") | The developer | Logged only |` and `| gen.api, any text containing "cap" or "limit" | The whole response | Hard failure: nothing from this response is written — no transaction, no watermark, no backfill progress — the sync stops and the diagnostics pane records it |`. Add: "The app can only produce this by building a request it promised not to build, so a unit test asserts every request the planner emits has `end-date - start-date <= 44 days`, and a fixture test asserts ingesting Tests/Fixtures/Demo/v2-range-capped.json writes zero rows and advances zero watermarks."

**Why.** Live: a 120-day span returns HTTP 200 with the cap as a gen.api entry and 31 days silently missing; the accounts carry no error of their own, so under the current rules every watermark advances over the hole and nothing ever asks again. The design guarantees the trigger by freezing an errored account's watermark for as long as the connection is broken. I rejected the sibling proposal to advance watermarks to "the oldest day actually covered by the data": an account with no transactions in the window yields no such day, and clamping the span makes the computation unnecessary. Live probe P3 also returned the cap message for a request that was not over 90 days, so the text cannot be used to infer what the server actually served — which is why the rule is "discard the whole response" rather than "work out what was lost".

### 4. `account-write-must-not-clobber-owner-or-sync-columns` (blocking)

Add a paragraph to "Not storing the same thing twice": "An account row holds three kinds of column. Server-owned: remote_name, conn_name, org_id, org_name, currency, balance_cents, available_cents, balance_date, holdings_count, last_seen_in_sync_at. Owner-owned: display_name, user_type, include_in_safe_to_spend, amounts_reversed, archived_at and every cc_* field. Sync-owned: tx_synced_through, backfilled_through, history_coverage_start, created_at. A sync writes only the first group. `INSERT OR REPLACE` is banned: it deletes the row, `ON DELETE CASCADE` takes the owner's whole transaction history with it, and the account id changes under every foreign key pointing at it. GRDB's default `upsert`/`save` is banned for the same reason in miniature — its targetless `DO UPDATE SET` writes every non-primary-key column, so a routine refresh silently undoes the owner's account-type correction and resets backfilled_through." Implementation: one cached statement, `db.cachedStatement(sql:)`, `INSERT INTO account (source, conn_id, external_id, remote_name, conn_name, org_id, org_name, display_name, currency, balance_cents, available_cents, balance_date, holdings_count, last_seen_in_sync_at, created_at) VALUES (...) ON CONFLICT (source, conn_id, external_id) WHERE external_id IS NOT NULL DO UPDATE SET remote_name=excluded.remote_name, conn_name=excluded.conn_name, org_id=excluded.org_id, org_name=excluded.org_name, currency=excluded.currency, last_seen_in_sync_at=excluded.last_seen_in_sync_at RETURNING id` — the `WHERE external_id IS NOT NULL` in the conflict target is load-bearing, because account_natural_key is a partial index and SQLite rejects the statement without it (and GRDB's `upsertAndFetch(onConflict:)` cannot emit it). Balances are written by the separate guarded UPDATE named in the balance-provenance decision, never in this statement.

**Why.** Measured against this exact schema: INSERT OR REPLACE moved the row id 1→2, dropped 200 bank_transaction rows to 0, nulled recurring_charge.paying_account_id, and reset user_type, include_in_safe_to_spend and display_name. GRDB's default upsert avoids the cascade but still nulls user_type, include_in_safe_to_spend and backfilled_through on every one of the twelve refreshes a day. SYNC.md specifies transaction identity in detail and says nothing at all about the account write, so whichever of the two obvious implementations is chosen, the owner loses data.

### 5. `decode-the-access-url-with-urlcomponents` (blocking)

Rewrite step 4 of "Getting a credential" as: "A 200 returns an access URL with a username and password in it. The app splits it with `URLComponents(url:resolvingAgainstBaseURL: false)` and reads `.user` and `.password`, which are percent-**decoded**. `URL.user()` and `URL.password()` must never supply these values — verified on this toolchain, they return the still-encoded `ab%40cd` / `pq%2Frs%40tu` despite `percentEncoded: false` being the default, and the demo credential is literally `demo:demo`, so every fixture hides it. They stay in `SimpleFINCredential.init` only for the 'the stored base URL carries no credentials' rejection check, where the encoded form is harmless. The header is built as `Data("\(user):\(password)".utf8).base64EncodedString()`." Add to step 6: "A 403 on the **first** `/accounts` request after a claim is never reported as the gen.auth 'paste a new setup token' banner. A credential stored sixty seconds ago cannot have gone stale, so it reads: 'SimpleFIN rejected the credential I just stored. This is a bug in Spendable, not a problem with your token — don't generate another one.'" Add the claim fixture whose body is `an access URL for host beta-bridge.simplefin.org, path /simplefin, whose encoded user is `ab%40cd` and whose encoded password is `pq%2Frs%40tu` (written out in parts here rather than as one URL, because the repository's own pre-commit hook refuses a URL with credentials in it and cannot tell an invented one from the owner's real one)`.

**Why.** Verified here just now. The first real access URL whose password contains @ / : + or a space is stored percent-encoded, passes the byte-for-byte read-back as 'stored successfully', produces a 403, and SYNC.md's own table then tells the owner to mint a fresh single-use token — which burns identically, forever, because the correct password was in the discarded claim response.

### 6. `keychain-failure-is-its-own-state-both-ways` (blocking)

Add to "Getting a credential", after step 5: "If the Keychain write or its read-back fails after a 200 claim, the claim result is **kept in memory for the rest of the app session** and never discarded on the first failure. The screen says: 'Your setup token has already been used up — don't generate another one yet. macOS wouldn't let me save the connection. Unlock your login keychain (or click Allow) and press Retry.' Retry re-attempts the write against the retained value." Add to "When a connection quietly dies": "`CredentialStore.load()` returns nil for `errSecItemNotFound` and only that. `errSecInteractionNotAllowed` (-25308), `errSecAuthFailed` (-25293) and `errSecUserCanceled` (-128) are a distinct state — 'macOS wouldn't let me read your saved connection. Unlock your login keychain and try again.' — and must never reach the gen.auth banner, which is reserved for a server that answered 403. The item is created by `SecItemAdd` from the app, so the app is its only trusted application: after a re-signing the system prompts or denies rather than reporting the item missing, which on a free Personal Team with a weekly-reissued profile is routine. `kSecAttrAccessible` is silently ignored by the file-based login keychain this app uses; it is added only if the app ever moves to the data-protection keychain, in the same change as `kSecUseDataProtectionKeychain`, and not before."

**Why.** The single most expensive failure in the whole document — a spent single-use token with the access URL dropped on the floor — has no rule at all, and the read-side failure routes a locked keychain to advice that burns tokens. Both are ordinary on this machine given the signing decision in PLAN item 1.

### 7. `the-token-and-the-credential-must-be-unreflectable` (blocking)

Replace "Errors carry a status code and a hostname and nothing else" with: "URLSession errors are converted at the boundary into a small app enum keyed off `URLError.Code`; no app error ever stores an `underlying: Error`, because `String(describing:)` of a URLError from the claim POST contains `NSErrorFailingURLKey=https://…/simplefin/claim/<the live setup token>` while `localizedDescription` does not — so a redaction test that greps for the password passes while the token goes into the unified log. A setup token is a bearer credential: whoever reads it out of a log can claim it and get live read access to the owner's banks. No URL derived from the claim path is ever logged, interpolated into an alert, or put in a `fatalError`/`precondition` message. The setup-token field's own validation failure says 'That doesn't look like a SimpleFIN setup token' and never echoes what the paste decoded to." Add: "`SimpleFINCredential` also conforms to `CustomReflectable` with `var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }` — verified here, a struct whose description and debugDescription both return `<redacted>` still yields `- password: \"SUPERSECRET\"` from `dump(_:to:)` and hands the value over through `Mirror(reflecting:).children`." The redaction test runs every error path with a distinctive sentinel token and password and asserts the sentinel appears in none of `String(describing:)`, `String(reflecting:)`, `dump(_:to:)` output, `localizedDescription`, or `(error as NSError).userInfo.description`.

**Why.** Verified on this toolchain: dump and Mirror walk straight past the redaction the document relies on, and the claim-path URLError carries the live token in userInfo. PLAN M3 item G's test as written goes green through both holes.

### 8. `budget-is-a-reservation-on-a-rolling-window-behind-one-runner` (blocking)

Replace the opening of "Not asking too often" with: "The Bridge expects at most 24 requests a day, in a time zone it never states, and disables the token beyond that. The app therefore counts a **rolling 24 hours**, not a calendar day: `sync_state` holds the timestamps of the last 24 requests, and a request is refused when 14 of them fall inside the trailing 24 hours. A per-local-day ceiling of 12 permits 24 inside one server day — the disable threshold exactly — by spending 12 late on one Chicago evening and 12 early the next morning, and a time-zone change resets it for free. Of the 14, at most 6 in any rolling 24 hours may be backfill windows, so a first connection deliberately spreads over two days instead of colliding with the scheduler." Add: "A request is **reserved before it is sent**: one serialized write re-reads the timestamp list, refuses or appends, and commits, and only then is the URLSession task created. A crash or a timeout between spending and recording can then only over-count, which is safe; counting successes instead under-counts, and the server counts every request it served whether or not the app got the answer. Every request counts, including failures, and a failed request is not retried within the same sync — the next scheduled activity tries again. All syncs of every origin (the six-hourly activity, the launch poll, wake, day-change, manual Refresh) run through one actor holding a `sync_state` lease row with an owner and an expiry, so two triggers firing at the same instant coalesce into one run rather than both reading the same count and both sending."

**Why.** Merges three findings whose failure modes compound: the boundary doubling, the counter that records successes rather than reservations, and the five independent M4 triggers with no single-flight. Any one of them reaches 24 and the owner must hand-mint a new token, which the whole section exists to prevent. I set 14 rather than the proposed 10 because routine need is 5–6 a day and the walk needs 6 more; 14 with a correct rolling reservation leaves 10 of headroom under the server's limit, which is more real slack than 12 per local day ever gave.

### 9. `backfill-arithmetic-and-persisted-terminal-state` (blocking)

Replace the first paragraph of "Filling in history" with: "On first connection the app walks backwards in 44-day windows with a 5-day overlap, newest first. Each window advances the cursor 39 days, so *n* windows reach 44 + 39(*n*−1) days back: **eleven windows reach 434 days**, which clears thirteen months. Nine would reach 356 — inside one year, so the most recent occurrence of every annual charge billed 357 to 365 days ago would be missed, and milestone 5 would have nothing to detect. The walk stops at whichever comes first: two consecutive **transaction-bearing** windows in which no account returned a single transaction; a window whose start is on or before 400 days ago; or eleven windows. At most six windows run in any rolling 24 hours, so a first connection completes on the second day." Add: "The walk's whole state is persisted in `sync_state`, not just a date: the window index, the consecutive-empty run, and a terminal reason of `running`, `exhausted-history`, `out-of-budget` or `failed`. Only `out-of-budget` and `failed` resume; `exhausted-history` is never re-walked until the owner asks or the credential is replaced. 'Nothing new' means the response contained no transactions for any account in that window, never 'no rows we did not already have', so an overlapping resume cannot end the walk early. An account carrying an `act.*` or `con.*` error in a window does not advance its `backfilled_through` and that window is re-requested — the same rule the incremental watermark already has." `history_coverage_start` is written only for windows that actually returned data, so the subscriptions screen can never claim history the walk never asked for.

**Why.** Four defects in one mechanism: the thirteen-month stop is unreachable dead text under nine 44-day windows; nothing on disk distinguishes 'the bank has no more history' from 'the budget ran out', and the two demand opposite behaviour on the next launch (re-walking three windows every day forever, or recording a stalled walk as complete and lying about coverage); and the errored-account rule was stated only for the incremental watermark. The 44 stays — a 44-day window with both dates drew an empty errlist live, a 45-day span warns — so the fix is the window count, not the width.

### 10. `a-transaction-id-is-a-hint-not-an-identity` (blocking)

Replace "Overlapping rows are recognised and not duplicated" with: "The protocol promises a transaction id is *unique* within an account, never that it is *stable* between two responses. The public demo server derives its ids from the requested `start-date` — the same 21 charges came back with 21 different ids when start-date moved by one hour, zero ids in common — and the owner's own specification says pending charges re-post under a new id. So `UNIQUE(account_id, external_id)` is the fast path, not the identity. When an incoming settled row's (account_id, external_id) is unknown, the app gathers the existing non-void rows for that account with the same `effective_date`, `amount_cents` and `description` whose `external_id` does **not** appear anywhere in this response for this account, pairs them greedily with the incoming unmatched rows of that same signature — min(existing, incoming) pairs — and **updates** each paired row's `external_id`, `last_seen_at`, `payee`, `memo` and `mcc` rather than inserting. Left-over incoming rows are inserted; left-over existing rows are untouched." Add: "`start-date` and `end-date` are UTC-midnight epoch seconds derived from the target `CalendarDay`, never local midnight: local midnight moves by an hour across a DST change and by hours when the owner travels, and on a server that keys its data off the requested start-date that alone re-keys every row in the overlap. `end-date` is the UTC midnight of the day **after** the window's last day, because the protocol defines it as exclusive."

**Why.** Without this, every 44-day window's five-day overlap re-arrives under fresh ids on each backfill window by construction, so the milestone's own acceptance run ('a second sync inserts 0 duplicate rows, demonstrated against live demo /accounts') duplicates roughly eight windows' worth of overlap, and spent-this-month doubles over the overlap on real data. I rejected the proposed fingerprint column with a UNIQUE index: a hard uniqueness constraint on (account, day, amount, merchant) silently destroys the second of two genuinely identical charges — two $5 coffees on the same day — which is a worse error than a duplicate, and it would cost a migration. Greedy pairing, guarded by 'not present in this response' and by matching counts, handles both cases and needs no schema change.

### 11. `pending-is-resolved-by-evidence-never-by-absence` (blocking)

Replace the three pending bullets with: "— A pending row returned in this response stays pending, with its fields refreshed, and is **not a candidate for supersession by anything in the same response**: a row the bank is still reporting as pending has not posted, whatever else matches. — A settled row supersedes a pending row only when the pending row is absent from this response and the two share account, exact `amount_cents`, normalised description and fall within **ten** days. Matching is one-to-one, run as a single pass over the candidate set rather than a lookup per row: each settled row claims at most one pending row and each pending row is claimed at most once, oldest to oldest. If two or more candidates remain indistinguishable after that pass, **none** is superseded — losing a real charge is worse than showing a hold for one more day. — A pending row is never voided for being absent from a response. It is voided only by a supersession, or by age: a pending row whose `effective_date` is more than ten days old and which no response has returned since is marked `voided_at` with a recorded reason. Every sync loads that account's unresolved pending rows in full, regardless of the window it asked for — there are a handful of them." Add to the parameter table note: "`pending=1` is sent whenever transactions are fetched, but a pending transaction's `posted` may be 0, which is before every `start-date` the app will ever send, so a server that filters on `posted` cannot return them at all. That is the second reason absence is never evidence." Add a synthetic fixture with `posted: 0, pending: true`; the demo data contains none.

**Why.** Merges four findings that all end with the database holding a charge the owner did not make or losing one they did: the six-day-old hold no request ever covers again and no rule can retire; the two-consecutive-absences rule firing on balances-only responses or on rows the server filtered out by posted=0; and a settled row claiming a still-live second identical pending charge. I rejected the proposed ±25% amount band for tips and hotel holds: it can attribute a settled charge to the wrong hold, and with the ten-day age-out in place its only benefit is removing a ten-day interim double-count — not worth a rule that can silently delete a real charge.

### 12. `void-and-superseded-rows-are-history-not-money` (blocking)

Add to "Not storing the same thing twice", immediately after 'Rows are never deleted': "A row with `voided_at` or `superseded_by` set is history, not money. **Every** total, count, grouping, average and detection query carries `AND voided_at IS NULL AND superseded_by IS NULL`; the only reads that include such rows are the per-transaction audit view and the reconciliation pass itself."

**Why.** The section specifies the write side completely and the read side not at all, so the default aggregate — the exact `SELECT SUM(amount_cents) FROM bank_transaction WHERE account_id = ? AND effective_date >= ?` the performance rules mandate — counts a voided $400 hold and the real $312.50 charge together, and milestone 5 reads a voided pending plus its settled twin as a cadence. Nothing looks broken; the totals are just bigger than the owner's spending. I rejected the proposed partial index to go with it: at a year of rows the existing (account_id, effective_date DESC) index plus a filter is fast, and the index would cost a migration for no measurable gain.

### 13. `decode-the-window-then-insert-it` (blocking)

Replace the first two Memory bullets with: "— One write transaction **per window response**, opened after the network request has completed and closed before the next request begins, and the raw `Data` is released when its scope ends. The window's rows, `backfilled_through`, `history_coverage_start` and the watermarks of the accounts present without an error of their own all commit in that same transaction, so progress and data can never disagree after a crash. — The response is decoded into values and then inserted; nothing accumulates across windows. Inserting from inside `init(from:)` is dropped: Foundation's JSONDecoder is not a streaming decoder — it scans and index-maps the whole document before any `init(from:)` runs, which measured at +4.2 MB for decoding one key of a 2 MB body against +6.4 MB for the whole model, so the shape saves about 2 MB of a 6.4 MB peak on a pathological body and nothing at all on a real one (a live 44-day window was 33 KB decompressed, decoding whole for +0.4 MB). What it costs is the rule one section above: 'a value that will not parse fails that account rather than becoming zero' requires catching an error part-way through a decode that has already written rows, leaving accounts 1..n committed and n+1..N never reached, after which the absent-account sweep marks healthy accounts as stopped updating. It also needs a Database smuggled through `JSONDecoder.userInfo` in an `@unchecked Sendable` box, defeating GRDB's own guarantee under Swift 6 strict concurrency." Add: "Within a window, one prepared statement per table, obtained with `db.cachedStatement(sql:)` and reused — measured 20.6 ms for 6,000 upserts in one transaction with a reused statement against 246.9 ms one autocommitted `db.execute` per row. The sync engine is a non-isolated actor holding the Sendable AppDatabase and awaits `try await dbPool.write { }`, so the writer queue is never held across a network round trip."

**Why.** 'One write transaction' with no stated scope reads either as spanning the whole backfill — which makes the per-window resume promise false, since an uncommitted transaction persists no progress, and parks the single writer across nine round trips while the owner waits to mark a bill paid — or as no explicit transaction at all, which is 12x slower. The insert-inside-init design buys almost nothing and makes the document's own per-account failure rule unimplementable without committing partial rows.

### 14. `redirects-diagnosed-and-re-anchored-once` (material)

Replace 'Redirects are refused: a redirect off the expected host with an `Authorization` header attached would hand the credential to whoever answered' with: "Redirects are never followed automatically. `URLSession` is used with a per-task delegate via `session.data(for:delegate:)` — never `URLSession.shared` and never `data(for:)` with no delegate, which silently follows a 302 and even converts the empty-body claim POST to a GET — implementing `urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)` and calling `completionHandler(nil)`, which completes the task with the 3xx itself. The reason is not that the credential would leak: verified here, CFNetwork strips a manually-set `Authorization` header across a redirect, same host or not. The reason is that following one silently downgrades the request to unauthenticated, and against the Bridge an unauthenticated request is a 403, which this document's own table turns into 'your connection died — paste a new setup token'." Then add: "A 3xx is its own diagnosed state, never the generic 'couldn't reach SimpleFIN'. `bridge.simplefin.org` — the host in the owner's specification's own example access URL, and the host the Bridge's sign-up link still points at — answers every path with `302 Location: https://beta-bridge.simplefin.org/`, dropping the path and the query (re-verified today), so it can be neither followed nor ignored. On a 3xx whose `Location` is an `https` URL whose host is `simplefin.org` or a subdomain of it, the app retries **once** against that origin with the original path and query, the credential re-attached from the Keychain; on a 200 it rewrites the stored base URL to the new origin so the redirect is not paid for again, and tells the owner 'SimpleFIN moved to beta-bridge.simplefin.org — I've followed it.' The retry counts against the request budget. A `Location` on any other host, or a second redirect, is a hard error naming the host, and no second setup token is consumed before the host is corrected."

**Why.** Two lenses reached opposite conclusions — refuse everything versus follow. Refusing everything leaves an owner whose token was minted on the production host permanently dead with a message that reads like a network blip, burning single-use tokens; following blindly sends the request to a marketing homepage and manufactures a fake gen.auth. The narrow same-registrable-domain, path-preserving, one-shot re-anchor is the only version that survives both a live migration and a hostile Location header. It also corrects the document's stated rationale, which is factually wrong on this platform and invites an implementer to relax the rule.

### 15. `explicit-coding-keys-no-key-strategy` (material)

Add to "What the answer means": "`available-balance` and `balance-date` are hyphenated; `conn_id`, `org_id` and `org_name` are snake_case. No single `JSONDecoder.keyDecodingStrategy` is correct for this document, so the response decoder sets **none** and every key is an explicit `CodingKey`. The natural mistake is mirroring `Account`'s `databaseColumnDecodingStrategy = .convertFromSnakeCase` onto the decoder: verified against Tests/Fixtures/Demo/v2-balances-only.json, `.convertFromSnakeCase` maps conn_id correctly and leaves `availableBalance` and `balanceDate` nil on all three accounts with no thrown error — and 'unknown keys are ignored' is exactly what turns that into silence. `balance-date` is non-optional in the model so a wrong key throws loudly; `available-balance` is legitimately optional and cannot protect itself, so it is covered by fixtures instead." Add two synthetic fixtures to the M3 list: an account with `available-balance` strictly less than `balance`, and one with `available-balance` greater than `balance`.

**Why.** In every committed fixture and in every live response available-balance equals balance to the cent, so a silent nil is invisible to the entire current test plan. On real data ENGINE.md uses the bank's available balance for a confirmed current account: an account with balance 1000.00 and available 800.00 would be counted at $1,000, with a confident sentence saying which figure it used.

### 16. `error-routing-is-total-and-correctly-attributed` (material)

Rewrite the error table's routing rules as: "`act.*` is resolved by (`conn_id`, `account_id`) when the entry carries a conn_id — the same natural key the account table uses, because the protocol guarantees an account id is unique only *within* a connection. With no conn_id, the error attaches to an account row only when exactly one row across all connections has that external_id; otherwise it is shown once against the response, attributed to SimpleFIN, without claiming which account it concerns. `con.*` with a conn_id applies to every account of that connection; with no conn_id it is shown globally rather than dropped. A `con.*` error whose connection contributes **no** accounts to this response, or which matches no account row, is shown as its own line under the number against the stored accounts of that connection — routing it to zero accounts is the same as hiding a dead connection." Add two rows: `| a naked "gen." or any unrecognised gen.* subcode | The whole connection | The server's msg shown as a plain notice attributed to SimpleFIN |` and `| gen.api mentioning a rate, quota or request count | The whole token | Every remaining scheduled and launch sync is cancelled for the rest of the rolling day, a quota-tripped flag is written to sync_state, manual Refresh stays available with an explicit warning |`. Add: "Only `gen.auth` reaches the re-claim banner. An unknown code must never get there."

**Why.** The owner with a personal and a joint login at the same bank holds two accounts whose external_id is the same string — the demo's own ids are 'Demo Checking' — so a bare act.failed flags the wrong one, and ENGINE.md then drops the healthy account's money from the total while the failing one keeps contributing a frozen balance. The table is also not total over the protocol's own codes while the protocol requires a naked-prefix fallback, and gen.auth and gen.api have opposite handling, so an unknown gen.* either burns a working token or is invisible.

### 17. `decode-the-deprecated-errors-array-and-error-status-bodies` (material)

Add to "What the answer means": "A v2 response is also decoded for the deprecated `errors` array of strings. The protocol lists it as deprecated, not removed, and the Bridge's developer guide says the rate-limit warning appears there: 'Making more requests than expected will eventually cause warning messages to appear in the errors array.' Its strings are treated as unattributed server notices, and any one mentioning a rate, quota or request count trips the same quota flag as a gen.api quota warning. Response headers carry no quota information of any kind (verified: Cloudflare, no X-RateLimit-*), so these notices and the app's own counter are the only two signals that exist." Change the status-handling sentence to: "200 is parsed; on 402 and 403 the body is also parsed for `errlist` and the server's `msg` is shown as plain text attributed to SimpleFIN beneath the app's own sentence — the 403 fixture proves an error status still carries a structured body, and the Bridge's guide says to always show those errors. For 402 the app's own sentence says what was observed — 'SimpleFIN answered "payment required", which usually means the subscription needs renewing' — rather than asserting a cause the server never gave. Anything else is 'couldn't reach SimpleFIN' with the status and host in the log and nothing else."

**Why.** The one warning that arrives before the token is disabled is being dropped in a key the decoder ignores, and the token being disabled is the outcome the whole budget section exists to prevent. Decoding one extra optional array is close to free.

### 18. `a-replaced-credential-must-not-duplicate-every-account` (material)

Add a short section "When the credential is replaced": "A new access URL can carry a different `conn_id` for the same bank. Because the natural key is (source, conn_id, external_id), every account would then fail the lookup and be inserted fresh, and for the first seven days both rows are recent enough for the engine to count — the demo's own numbers would put $115,385.51 into the total twice, and when the old row finally ages out the figure falls by its balance while its bills stop being subtracted too, landing high rather than low. So: when an incoming account matches no row on (source, conn_id, external_id), the app looks for exactly one non-archived `simplefin` row with the same (org_id, external_id) **whose own conn_id does not appear in this response's `connections` array**, and adopts it by updating conn_id in place. Both guards matter: 'exactly one' and 'the old connection is gone' are what stop two logins at the same bank — which the protocol says are two connections with independent account-id namespaces — from being merged into one row. An incoming account matching nothing is genuinely new. An existing row still unmatched after a replacement keeps its data, is marked as not updating, and is linked through `replaced_by` only when the owner says so."

**Why.** The schema already carries `replaced_by` for exactly this and the sync contract never mentions it. The unguarded version of this fix — matching on (org_id, external_id) alone — would merge two genuinely different accounts, which is why the two guards are stated as part of the rule rather than left to the implementer.

### 19. `record-holdings-now-migration-v3` (material)

Replace 'Accounts carry a `holdings` array, which this app ignores' with: "Some accounts carry a `holdings` array — it is a Bridge extension and appears nowhere in the protocol, and it is present on some accounts and absent on others. Its contents are ignored, but its **size is recorded**, because SimpleFIN carries no account type and the presence of holdings is the strongest signal in the whole response that a balance is a market value rather than money. In the committed fixtures Demo Savings carries a holding worth $105,884.80 of AAPL while Demo Checking carries none, and its name is 'SimpleFIN Savings' — so milestone 4's keyword guesser would type it savings, the owner would tick the savings opt-in that ENGINE.md provides, and six figures of stock would become spendable money that moves with the market every day." Migration **v3** contains exactly one statement: `ALTER TABLE account ADD COLUMN holdings_count INTEGER NOT NULL DEFAULT 0`, written from the balances-only response alongside the balance columns. Milestone 3 only records it. State the milestone-4 consequence in this document now: an account with `holdings_count > 0` is never guessed checking or savings from its name and is never counted in a total even if the owner opts in, with a plain sentence saying why.

**Why.** The plan front-loaded the schema so M3–M6 need no migrations and this one field was missed; recording it now costs one forward-only ALTER and prevents the guesser from being built against data it does not have. This is the only schema change milestone 3 needs.

### 20. `what-fails-that-account-actually-means` (material)

Replace 'a value that will not parse fails that account rather than becoming zero' with: "A value that will not parse fails **that account**, which means precisely: the account keeps its previous balance columns and its previous watermark, is marked as not updating, and contributes nothing new to this sync. It is never dropped, never zeroed, and never deleted, and the rest of the response is ingested normally. The Bridge's amounts are not all two-decimal — a holding came back as `\"market_value\":\"105884.8\"` — and the protocol allows `currency` to be a URL such as `https://www.example.com/flight-miles`, which ENGINE.md's non-USD rule already holds out: the app stores that string, never renders it as a link and never fetches it."

**Why.** 'Fails that account' is the pivot of the strict-decoding rule and is nowhere defined; the two readings are 'keep the last known good row' and 'drop the account', and dropping it would make the app claim an account vanished — which triggers the immediate not-updating sweep on a feed that is fine.

### 21. `the-credential-goes-to-one-host-and-nowhere-else` (material)

Add to "Asking for data": "The `Authorization` header is sent only to the host stored in the Keychain item's base URL. The response hands the app three server-controlled URLs — `connections[].sfin_url`, `connections[].org_url`, and v1's `org.sfin-url`/`org.domain` — and none of them is ever dialled, by this milestone or any later one; they are display strings at most, and never a clickable link. Any future per-connection refresh builds its request from the Keychain base URL and the account id, never from a URL the response chose." Also pin the session: `configuration.connectionProxyDictionary = [:]`, `httpShouldSetCookies = false`, `httpAdditionalHeaders = nil`, `waitsForConnectivity = false`, `tlsMinimumSupportedProtocolVersion = .TLSv12`. Replace 'nothing is written to disk by URLSession' with: "URLSession writes no cache, cookie or credential file. That is not the whole disk story: `CFNETWORK_DIAGNOSTICS` writes full request headers, `Authorization` included, into ~/Library/Logs/CrashReporter, so it must never appear in project.yml or any scheme; and an Xcode memory graph is a process corpse containing the base64 header verbatim, so a `.memgraph` never goes into the repository or onto a bug report. A crash report does not dump the heap, which is why no `fatalError` or `precondition` message may interpolate a credential-derived value."

**Why.** The only host rule in the document forbids hardcoding, which is the opposite of the actual risk; nothing forbids taking a host from the response body. The proxy line matters because this app is built on a developer's Mac, where a debugging proxy's root certificate in the login keychain plus a system proxy is an ordinary state, and an ephemeral session will hand that proxy live bank read access in cleartext.

### 22. `memory-test-that-can-actually-fail` (material)

Replace the last Memory bullet with: "A test pushes a synthetic year — about 6,000 transactions across four accounts, generated in the test rather than committed as JSON — through the real windowed ingestion path, against a `DatabaseQueue` so the page cache is one connection. `phys_footprint` is **reported, never asserted**: it does not come back down (measured, freed malloc pages stay resident: base 19.74 → peak 26.14 → after 26.13 MB), and the absolute gate would be measured inside the test host app, which already reaches 45 MB peak running the existing 106 tests with nothing bank-related in the process. Three things are asserted instead: (a) live heap — `malloc_zone_statistics(nil, &s).size_in_use` before and after, returning to within 1 MB of baseline (measured: it returns exactly), after `releaseMemory()` and `malloc_zone_pressure_relief(nil, 0)`; (b) a structural high-water mark — an injected counter asserting the number of decoded transaction values alive at once never exceeds one window's worth, which is the actual requirement and is what makes a year-in-one-array implementation fail; (c) the `Data` release proved directly, by building the fixture with `Data(bytesNoCopy:count:deallocator: .custom { … freed = true … })` and asserting `freed == false` inside the ingest scope and `true` after it returns."

**Why.** As specified the test cannot fail on what it exists to prevent: holding 6,000 decoded transactions in one array costs +2.17 MB, which passes a '<25 MB delta' gate with 22 MB to spare, while the '<60 MB absolute' gate has about 15 MB of real headroom in a host process whose variance is larger than that — it would fail and pass for reasons that have nothing to do with the app.

### 23. `the-demo-credential-never-touches-the-real-item` (minor)

Add to "Never in a log, never in a file": "There is one real Keychain item, `service = com.nullterminater.spendable.simplefin`, `account = access`. The DEBUG-only 'Connect to the public demo' action writes to `account = access-demo`, compiled in under `#if DEBUG` and enabled only when `SPENDABLE_DEBUG_CONTAINER` is set, because Debug and Release builds share a bundle id and a login keychain and one `SecItemUpdate` would otherwise destroy the owner's real access URL — unrecoverable without hand-minting a new single-use token. If the real item exists, the demo action refuses to run without an explicit confirmation naming what it would replace." And: "Replacing a credential is two-phase: the new one is written to `account = access-pending`, read back, and proved with one live `balances-only=1` request; only then is it promoted to `access` and the pending item deleted. A working credential is never destroyed before its replacement has answered 200."

**Why.** Milestone 3's own acceptance criteria require running the demo action, and milestone 9's re-claim flow has the same shape in the other direction — both currently overwrite the single item in place, so a debugging session in milestone 5, or a re-claim that returns a URL the app then cannot use, leaves the owner with no working credential and no way back except a new token.

### 24. `name-the-bank-from-the-connections-array` (minor)

Add to "What the answer means": "The institution label for an account is `connections[].name` matched on `conn_id` — the protocol makes `name` required on Connection and says it should include the financial institution name — falling back to `org_name`, then to the account's own `name`, never to an empty string. `org_name` is not in the protocol's Connection attribute table at all, though it appears in every live response, and on the demo it reads 'SimpleFIN Bridge' while `name` reads 'SimpleFIN Demo' — so reaching for `org_name` first would make the con.auth sentence say 'SimpleFIN Bridge needs you to sign in again', which tells the owner nothing about which login to fix. `conn_name`, `org_id` and `org_name` are stored on the account row at sync time so the label survives a response whose `connections` array is empty, and an account whose conn_id matches no entry is still stored and shown under its own name."

**Why.** The wording this document promises — 'Chase needs you to sign in again on the SimpleFIN website' — can only come from this join, and the join is never specified while the schema has the columns waiting.

### 25. `close-the-two-credential-leak-paths-the-repo-actually-has` (minor)

Add `.githooks/commit-msg` running the same four patterns the pre-commit hook runs (userinfo URL with the demo allowlist, base64-of-https, literal `Basic <b64>`, GitHub tokens) against `$1`, installed by `scripts/bootstrap.sh` alongside pre-commit; `.githooks/` currently contains only `pre-commit`, which scans staged file contents, so the commit message this document names as protected is unguarded. In `scripts/capture-demo-fixtures.sh`, delete the `echo "Claiming $CLAIM"` line and stop passing the access URL as a curl argument — feed it through `curl --config -` on stdin — because argv is visible in `ps` to every local process. Add one sentence to SYNC.md: "No tool in this repository ever accepts a credential or a claim URL as a command-line argument, and the commit-msg hook is what makes the promise about commit messages true."

**Why.** The section asserts protection that is not implemented, and the capture script is the template anyone will copy the day they need to reproduce a real-token failure.

## Findings deliberately rejected

- **`content-fingerprint-unique-index`** — A UNIQUE index on (account, day, amount, merchant) silently destroys the second of two genuinely identical charges and costs a migration; greedy guarded id-adoption gets the same dedupe with no schema change and no data loss.
- **`pending-match-amount-band`** — A ±25% band can attribute a settled charge to the wrong hold; with the ten-day age-out in place its only benefit is removing an interim double-count, which is not worth a rule that can delete a real charge.
- **`partial-index-for-voided-superseded`** — The filter is required, the index is not — at a year of rows the existing (account_id, effective_date DESC) index plus the predicate is fast, and the index would cost a migration for no measurable gain.
- **`watermark-from-the-oldest-transaction-actually-returned`** — Unreliable for an account with no transactions in the window, and unnecessary once no request the app builds can exceed 44 days and a cap message discards the whole response.
- **`copy-access-url-escape-hatch`** — Putting live bank read access on the clipboard to survive a Keychain failure trades a recoverable inconvenience for an unrecoverable leak; retaining the claim in memory with a Retry covers the same case.
- **`raise-the-ceiling-so-the-backfill-finishes-in-one-day`** — Finishing the walk on connection day requires spending the entire rolling budget in one sitting; spreading eleven windows over two days at six a day is visible, deliberate and leaves headroom under the 24-request disable threshold.
- **`streaming-json-parser-or-urlsession-bytes`** — Foundation ships no parser that consumes an AsyncSequence, a real window is 33 KB decompressed, and transactions are nested inside their account so the account row must be written first — hand-writing an incremental parser to save ~2 MB is the worst trade in the document.
- **`phys-footprint-as-the-memory-gate`** — It never returns to baseline and is dominated by the XCTest host's own variance; kept as a reported number, replaced as a gate by live heap, a structural counter and a direct Data-release proof.
- **`auto-follow-redirects-with-the-credential-reattached`** — Accepted only for an https Location on simplefin.org or a subdomain, once, path preserved; a general re-attach would send live bank credentials to whatever host answered.
- **`support-the-v1-response-shape`** — The app is v2-only by settled decision; v1-default.json stays as a fixture proving what happens without version=2, not as a decode path.
- **`add-ksecattraccessible-now`** — It is a silent no-op in the file-based login keychain this app uses; it belongs in the same change as kSecUseDataProtectionKeychain if that ever happens, and a line in the document saying so is the whole fix.
- **`owner-facing-quota-and-progress-wording`** — Milestone 4 owns every sentence the owner reads about sync progress and budget; milestone 3 records the quota-tripped flag, the terminal reason and the window counts so that milestone has real numbers to print.
- **`re-walk-exhausted-history-periodically`** — A connection whose institution holds only 90 days would re-prove the same emptiness three requests a day forever; re-walking happens only on the owner's request or a credential replacement.

## Test cases

### 1. Claim decodes a percent-encoded access URL

**Setup.** URLProtocol stub: POST to the decoded setup-token URL returns HTTP 200, body exactly `an access URL for host beta-bridge.simplefin.org, path /simplefin, whose encoded user is `ab%40cd` and whose encoded password is `pq%2Frs%40tu` (written out in parts here rather than as one URL, because the repository's own pre-commit hook refuses a URL with credentials in it and cannot tell an invented one from the owner's real one)`, no trailing newline. InMemoryCredentialStore empty.

**Expected.** Stored credential is baseURL `https://beta-bridge.simplefin.org/simplefin`, username `ab@cd`, password `pq/rs@tu`. The Authorization header the client then builds base64-decodes to exactly `ab@cd:pq/rs@tu`. The POST that was sent carried `Content-Length: 0` and a zero-byte body.

### 2. Claim 403 on an already-used token

**Setup.** Stub returns HTTP 403 with the body from Tests/Fixtures/Demo/claim-already-used.txt (`Forbidden (was it already claimed?)`). Credential store empty.

**Expected.** The exact owner-facing string 'This setup token was already used or doesn't exist. If you didn't use it in another app, someone else may have — disable it on the SimpleFIN website, then generate a fresh one.' Credential store is still empty; no Keychain write was attempted.

### 3. Keychain write fails after a successful claim

**Setup.** Stub returns 200 with a valid access URL. CredentialStore.save throws CredentialStoreError.keychain(errSecInteractionNotAllowed) on the first call and succeeds on the second.

**Expected.** After the first failure: no partial state written, the claim result is still held by the claim coordinator, and the message contains 'Your setup token has already been used up — don't generate another one yet.' Calling Retry writes successfully without re-POSTing (assert the stub recorded exactly one POST) and the stored password equals the one from the original 200.

### 4. Keychain read failure is not a dead connection

**Setup.** Database holds two synced accounts. CredentialStore.load() throws CredentialStoreError.keychain(errSecAuthFailed).

**Expected.** State is 'keychain unreadable' with the unlock-your-login-keychain wording. The gen.auth re-claim banner is NOT shown, no request is sent, no request budget is spent, and no account is marked not-updating.

### 5. Claim against the redirecting production host

**Setup.** Stub: POST https://bridge.simplefin.org/simplefin/claim/TOKEN returns 302 with `Location: https://beta-bridge.simplefin.org/` (path and query dropped). POST https://beta-bridge.simplefin.org/simplefin/claim/TOKEN returns 200 with a valid access URL.

**Expected.** Exactly two POSTs are recorded, the second to the beta host at the ORIGINAL path `/simplefin/claim/TOKEN`. The credential is stored. Variant: Location `https://evil.example.com/` produces a hard error naming the host, zero further requests, and no request to evil.example.com in the stub's record.

### 6. /accounts redirect never leaks and re-anchors once

**Setup.** Credential base `https://bridge.simplefin.org/simplefin`. Stub: GET .../accounts?version=2&balances-only=1 returns 302 `Location: https://beta-bridge.simplefin.org/`; the same path on beta-bridge returns v2-balances-only.json.

**Expected.** The 302 is not followed by URLSession (assert the delegate's willPerformHTTPRedirection was called and answered nil). Exactly one retry is sent, to `https://beta-bridge.simplefin.org/simplefin/accounts?version=2&balances-only=1`, carrying the Authorization header. The stored credential's baseURL is now the beta origin. Two requests were charged to the budget.

### 7. Hyphenated keys decode

**Setup.** Decode Tests/Fixtures/Demo/v2-balances-only.json with the production response decoder.

**Expected.** All three accounts decode with balanceDate == 1789516800 and availableBalance non-nil ('115385.51', '25951.11', '0.00'), connId == 'CON-SIMPLEFIN-DEMO'. A second assertion fails the build if the decoder has any keyDecodingStrategy set.

### 8. available-balance below and above balance

**Setup.** Two synthetic v2 fixtures: account A balance '1000.00' available '800.00'; account B balance '1000.00' available '1200.00'. Both typed checking and user-confirmed.

**Expected.** A: available_cents == 80000 and the engine's disclosure uses $800. B: available_cents == 120000 is stored but the engine uses the plain balance (ENGINE.md refuses a larger available) and the account is flagged type-suspicious.

### 9. Missing errlist is a decode failure

**Setup.** Body `{"accounts":[],"connections":[]}` with HTTP 200.

**Expected.** Ingestion throws a decoding error. No account is touched, no watermark moves, and the response is NOT treated as 'no errors'.

### 10. Window response never writes a balance

**Setup.** Account row: external_id 'Demo Checking', balance_cents 2595111, available_cents 2595111, balance_date 1789516800. Ingest Tests/Fixtures/Demo/v2-window.json as kind .window(start:end:) — its account balance is a different value dated 1789516800 — then a synthetic window whose balance is '25035.51' with balance-date 1786074187.

**Expected.** After both ingests, balance_cents, available_cents and balance_date are byte-identical to their starting values. Transactions from both windows are stored.

### 11. Balances-only response is not transaction evidence

**Setup.** Database holds three pending rows (effective_date today−2) and tx_synced_through = today−1 for each account, and a backfill in state running with consecutive_empty = 0. Ingest Tests/Fixtures/Demo/v2-balances-only.json twice as kind .balances.

**Expected.** All three pending rows are still pending with voided_at NULL and superseded_by NULL. tx_synced_through is unchanged on every account. consecutive_empty is still 0. Balance columns and last_seen_in_sync_at are updated.

### 12. Capped response is a hard failure

**Setup.** Database holds accounts with tx_synced_through = 2026-06-01 and 500 existing transactions. Ingest Tests/Fixtures/Demo/v2-range-capped.json (errlist contains 'Requested date range exceeds limit of 90 days and was capped.').

**Expected.** Zero rows inserted, transaction count still 500, every tx_synced_through and backfilled_through unchanged, the sync ends in a recorded failure state, and the diagnostics entry names the cap. Separately: the planner emits no request with end-date − start-date > 44 days for any watermark from today back to 2024.

### 13. gen.api 45-day recommendation is noise

**Setup.** Ingest Tests/Fixtures/Demo/v2-window.json, whose errlist contains only 'Requested date range exceeds recommended range of 45 days.'

**Expected.** All 89 transactions per account are stored, watermarks advance, no owner-visible state changes, and the entry appears only in the sync log — attached to no account.

### 14. Quota warning stops the day

**Setup.** Response A: HTTP 200, `{"errlist":[{"code":"gen.api","msg":"You have made 20 of 24 allowed requests today"}],"accounts":[...],"connections":[...]}`. Response B: HTTP 200 with `"errors":["You are approaching your request limit"]` and an empty errlist.

**Expected.** In both cases a quota-tripped flag is written to sync_state, every remaining scheduled and launch sync in the rolling day is refused, manual Refresh still runs with a warning, and the accounts in the body are still ingested normally.

### 15. Dead connection: gen.auth with an empty account list

**Setup.** Database holds two simplefin accounts with balances and watermarks. Response: HTTP 403, body Tests/Fixtures/Demo/v2-bad-credentials.json.

**Expected.** Both accounts keep their balance_cents, available_cents, balance_date and tx_synced_through exactly. Both are marked not-updating immediately (not after ageing). The re-claim banner is shown once. The server's msg 'Forbidden' is shown as plain text attributed to SimpleFIN. ENGINE.md's output for this state contains no figure.

### 16. 403 immediately after a claim is not a dead connection

**Setup.** Claim succeeds and stores a credential; the very first /accounts request returns HTTP 403 with a gen.auth errlist.

**Expected.** The message is the 'SimpleFIN rejected the credential I just stored… don't generate another one' wording. The re-claim banner is NOT shown and the credential is not deleted.

### 17. act.failed with an ambiguous account id

**Setup.** Two accounts: (conn_id 'CON-A', external_id 'Checking') and (conn_id 'CON-B', external_id 'Checking'). Response errlist: `[{"code":"act.failed","msg":"Failed to get all transactions. Try again later.","account_id":"Checking"}]` with no conn_id, both accounts present in the body.

**Expected.** Neither account row carries the error. It is shown once against the response, attributed to SimpleFIN. Both watermarks still advance. Variant with `"conn_id":"CON-B"` present: only the CON-B row carries the error and only its watermark is frozen.

### 18. con.auth for a connection that returned no accounts

**Setup.** Database holds two accounts on conn_id 'CON-A'. Response: accounts array contains only CON-B's accounts; errlist `[{"code":"con.auth","msg":"Forbidden","conn_id":"CON-A"}]`.

**Expected.** The con.auth line is surfaced against the two stored CON-A accounts ('… needs you to sign in again on the SimpleFIN website'), those two keep their balances and watermarks and are marked not-updating, and CON-B's accounts ingest normally. The error is not silently dropped for matching zero accounts in the response body.

### 19. Account upsert preserves owner and sync columns

**Setup.** Account id 1: external_id 'Demo Savings', display_name 'My Emergency Fund', user_type 'checking', include_in_safe_to_spend 1, cc_statement_cents 41200, backfilled_through set, 200 bank_transaction rows, one recurring_charge with paying_account_id 1. Ingest v2-balances-only.json twice.

**Expected.** account.id is still 1; display_name, user_type, include_in_safe_to_spend, cc_statement_cents, amounts_reversed and backfilled_through are unchanged; bank_transaction count is still 200; recurring_charge.paying_account_id is still 1; balance_cents, available_cents, balance_date, holdings_count and last_seen_in_sync_at are updated. remote_name is updated to 'SimpleFIN Savings'.

### 20. Overlap dedupe and id churn

**Setup.** (a) Ingest v2-window.json twice unchanged. (b) Ingest it once, then ingest a copy with every transaction id and posted shifted by +3600 (the live demo's behaviour when start-date moves an hour) as a second window.

**Expected.** (a) Row count after the second ingest equals the count after the first; ids are reused across the two demo accounts and both accounts' rows exist (178 rows, not 89). (b) Row count is unchanged; each affected row's external_id now equals the new id and last_seen_at has advanced; no row was inserted.

### 21. Two identical charges are never collapsed

**Setup.** Account holds two settled rows: same day, −$5.00, description 'BLUE BOTTLE', ids X1 and X2. A later response returns the same two charges under new ids Y1 and Y2.

**Expected.** Exactly two rows remain, carrying Y1 and Y2. Variant: the response returns only ONE of them under a new id Y1 — one existing row adopts Y1, the other is left untouched, and the row count is still two. Variant: the account holds one such row and the response contains two — one adopts, one is inserted, giving two rows, not three.

### 22. A pending row still reported is never superseded

**Setup.** Sep 8 response: pending P-1 (posted 0, transacted_at Sep 8, −64.00, 'WHOLEFOODS MKT 10231'). Sep 10 response: P-1 still pending plus a new pending P-2, same amount and description, dated Sep 10. Sep 11 response: P-1 absent, settled S-1 (−64.00, same description, posted Sep 11), P-2 still pending.

**Expected.** After Sep 11: exactly two live charges — S-1 settled, P-2 pending with superseded_by NULL and voided_at NULL — and P-1 superseded_by = S-1's row id. The account's spend aggregate for Sep 8–11 is −128.00, not −64.00 and not −192.00.

### 23. A hold that posts late and different is aged out, not stranded

**Setup.** Sep 1 pending AUTH-77, −400.00, 'MARRIOTT HOTELS'. Returned unchanged Sep 2–8. Sep 9 settled TXN-91240, −312.50, same description. Syncs run daily to Sep 12 with start-date = watermark − 5 days, so no response after Sep 6 covers Sep 1.

**Expected.** No supersession fires (amounts differ). On Sep 11 (ten days after effective_date, and absent from every response since) AUTH-77 gets voided_at set with a recorded reason. The September spend aggregate, filtered on voided_at IS NULL AND superseded_by IS NULL, is −312.50.

### 24. Void and superseded rows leave every total

**Setup.** Account with ten settled rows totalling −500.00 plus one pending row of −42.00. Void the pending row.

**Expected.** The account's spend aggregate moves by exactly 42.00 and equals −500.00. Every query in the sync and detection paths is asserted to carry the voided_at/superseded_by predicate (a test that greps the SQL the ingestion and aggregate layers emit is acceptable).

### 25. Backfill plan, resume, and terminal state

**Setup.** Today 2026-09-14, no history. Plan the walk; run windows 1–3 successfully; window 4's request fails with a transport error; relaunch the app.

**Expected.** The plan has 11 windows, none spanning more than 44 days, each overlapping the previous by 5 days, reaching at least 2025-08-14 (396 days). After window 3, backfilled_through reflects window 3 only and its rows and progress committed in the same transaction. The failure records terminal reason 'failed' and does not advance backfilled_through. The relaunch resumes at window 4 and does not re-request windows 1–3. Variant: windows 2 and 3 return zero transactions for every account — terminal reason 'exhausted-history', and the next launch sends no backfill request at all.

### 26. Budget reservation, rolling window, and single flight

**Setup.** (a) Reserve a request, then kill the process before the URLSession task completes. (b) sync_state holds 14 request timestamps, the most recent at 19:00 local on Sep 14. (c) Two sync triggers invoked concurrently on the same actor with 13 reservations already held.

**Expected.** (a) On relaunch the rolling count includes that request (over-count, never under-count). (b) At 00:05 local on Sep 15 a request is still refused, because 14 timestamps remain inside the trailing 24 hours; the first is permitted only once the oldest timestamp is more than 24 hours old. (c) Exactly one HTTP request is issued and the count goes to 14, not 15; the second trigger coalesces into the same run.

### 27. Memory of a synthetic year

**Setup.** Generate ~6,000 transactions across four accounts in the test, split into the 11 planned windows, and push them through the real ingestion path against a DatabaseQueue.

**Expected.** malloc_zone_statistics size_in_use after ingest (following releaseMemory() and malloc_zone_pressure_relief) is within 1 MB of the pre-ingest baseline; the injected live-value counter never exceeds one window's transaction count; the fixture Data's custom deallocator reports freed == false inside the ingest scope and true after it returns. phys_footprint peak and delta are printed, not asserted. A deliberately-wrong implementation that accumulates all 6,000 decoded values fails assertion two.

### 28. Nothing reflects the credential or the token

**Setup.** Run every error path (claim transport failure, claim 403, /accounts 403, 402, 3xx, decode failure, Keychain failure) with sentinel setup token 'SENTINELTOKEN12345' and sentinel password 'SENTINELPASSWORD67890'.

**Expected.** Neither sentinel appears in String(describing:), String(reflecting:), dump(_:to:) output, localizedDescription, or (error as NSError).userInfo.description for any error produced, nor in any log line captured during the run.

