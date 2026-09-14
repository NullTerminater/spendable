#!/bin/sh
# Runs the `leaks` tool against the Debug app after N main-window open/close cycles and prints
# the leak count. Zero is the expectation at every milestone.
#
# Usage: scripts/leaks-diff.sh [path/to/Spendable.app] [cycles]
set -eu

APP=${1:-DerivedData/Build/Products/Debug/Spendable.app}
CYCLES=${2:-5}
[ -d "$APP" ] || { echo "leaks-diff: no app at $APP (build first)" >&2; exit 1; }

EXTRA=""
[ -n "${SPENDABLE_DEBUG_CONTAINER:-}" ] && EXTRA="--env SPENDABLE_DEBUG_CONTAINER=$SPENDABLE_DEBUG_CONTAINER"

pkill -x Spendable 2>/dev/null || true
sleep 1
# shellcheck disable=SC2086
open $EXTRA --env SPENDABLE_DEBUG_MEMORY_CYCLE="$CYCLES" "$APP"
sleep $((9 + CYCLES * 7))
PID=$(pgrep -x Spendable || true)
[ -n "$PID" ] || { echo "leaks-diff: app did not stay running" >&2; exit 1; }

echo "leaks after $CYCLES window cycles:"
leaks "$PID" 2>/dev/null | grep -E 'leaks for|total leaked bytes' || echo "  leaks unavailable (is this a Debug build?)"

pkill -x Spendable 2>/dev/null || true
