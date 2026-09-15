#!/bin/sh
# Captures SimpleFIN responses from the PUBLIC demo account into Tests/Fixtures/Demo/.
#
# The demo data belongs to nobody: three made-up accounts on SimpleFIN's own server. No real
# balance, account or credential ever goes near this repo. The developer guide hands out a fresh
# single-use setup token on every page load, so this script claims one rather than storing any.
#
# Run it only when the protocol changes; the fixtures it writes are committed and the tests read
# them offline. It spends about five of the 24 requests a day that a token is allowed.
#
# Usage: scripts/capture-demo-fixtures.sh
set -eu

cd "$(dirname "$0")/.."
OUT=Tests/Fixtures/Demo
mkdir -p "$OUT"

GUIDE=https://beta-bridge.simplefin.org/info/developers

echo "Fetching a fresh demo setup token from the developer guide..."
TOKEN=$(curl -sL --max-time 20 "$GUIDE" | grep -oE 'aHR0[A-Za-z0-9+/=]{40,}' | head -1)
[ -n "$TOKEN" ] || { echo "capture: no demo token on the page; has the guide changed?" >&2; exit 1; }

CLAIM=$(printf '%s' "$TOKEN" | base64 --decode)
case "$CLAIM" in
  https://*) ;;
  *) echo "capture: the token did not decode to an https URL" >&2; exit 1 ;;
esac
# The claim URL is not printed and not passed as an argument: argv is visible in `ps` to every
# process on this Mac, and a terminal's scrollback outlives the command.
echo "Claiming a fresh demo token..."

ACCESS=$(curl -s --max-time 20 -H "Content-Length: 0" -X POST "$CLAIM")
case "$ACCESS" in
  https://*@*) ;;
  *) echo "capture: claim did not return an access URL (it may already be used)" >&2; exit 1 ;;
esac

# Only ever the demo credentials reach a file, and only in the sanitised base below.
BASE=$(printf '%s' "$ACCESS" | sed -E 's#//[^@]+@#//#')
echo "Access URL claimed; server base is $BASE"

NOW=$(date +%s)
D45=$((NOW - 45 * 86400))
D400=$((NOW - 400 * 86400))

fetch() {
  name=$1
  query=$2
  code=$(curl -s --max-time 60 "${ACCESS}/accounts?${query}" -o "$OUT/$name.json" -w '%{http_code}')
  size=$(wc -c < "$OUT/$name.json" | tr -d ' ')
  echo "  $name.json  HTTP $code  ${size} bytes  (?$query)"
}

echo "Capturing:"
fetch v2-balances-only "version=2&balances-only=1"
fetch v2-window        "version=2&pending=1&start-date=${D45}"
fetch v2-range-capped  "version=2&pending=1&start-date=${D400}"
fetch v1-default       "balances-only=1"

# What a wrong password looks like. Credentials go in the -u flag, never in the URL, for the same
# reason the app puts them in a header: a URL with a password in it ends up in logs and histories.
curl -s --max-time 20 -u 'demo:wrong-on-purpose' "${BASE}/accounts?version=2" \
  -o "$OUT/v2-bad-credentials.json" -w '  v2-bad-credentials.json  HTTP %{http_code}\n'

# Claiming an already-claimed token is the 403 the app has to explain.
curl -s --max-time 20 -H "Content-Length: 0" -X POST "$CLAIM" -o "$OUT/claim-already-used.txt" \
  -w '  claim-already-used.txt  HTTP %{http_code}\n'

echo "Checking nothing credential-shaped was written..."
if grep -rlE 'https?://[^/[:space:]"]+:[^/[:space:]@"]+@' "$OUT" 2>/dev/null | grep -q .; then
  echo "capture: a captured file contains a URL with credentials; refusing to leave it" >&2
  exit 1
fi
echo "Done. Fixtures in $OUT"
