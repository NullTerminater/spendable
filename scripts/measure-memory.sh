#!/bin/sh
# Reports the app's physical footprint (phys_footprint, the number Xcode's gauge shows) at idle
# with only the menu bar, with the main window open, and after the window is closed, for N cycles.
# The Debug build measures itself when launched with SPENDABLE_DEBUG_MEMORY_CYCLE and appends the
# numbers to measurements.log in its container; this script launches it that way, waits, and
# prints them. It also cross-checks the idle number externally with vmmap.
#
# Usage: scripts/measure-memory.sh [path/to/Spendable.app] [cycles]
# Set SPENDABLE_DEBUG_CONTAINER=/some/dir to keep the run away from the real database.
set -eu

APP=${1:-DerivedData/Build/Products/Debug/Spendable.app}
CYCLES=${2:-3}
[ -d "$APP" ] || { echo "measure-memory: no app at $APP (build first)" >&2; exit 1; }

CONTAINER=${SPENDABLE_DEBUG_CONTAINER:-"$HOME/Library/Group Containers/UW2KV7XB66.spendable"}
MLOG="$CONTAINER/measurements.log"
EXTRA=""
[ -n "${SPENDABLE_DEBUG_CONTAINER:-}" ] && EXTRA="--env SPENDABLE_DEBUG_CONTAINER=$SPENDABLE_DEBUG_CONTAINER"

pkill -x Spendable 2>/dev/null || true
sleep 1
rm -f "$MLOG"

# shellcheck disable=SC2086
open $EXTRA --env SPENDABLE_DEBUG_MEMORY_CYCLE="$CYCLES" "$APP"
sleep 5
PID=$(pgrep -x Spendable || true)
[ -n "$PID" ] || { echo "measure-memory: app did not stay running" >&2; exit 1; }

echo "external cross-check at idle (vmmap):"
vmmap --summary "$PID" 2>/dev/null | grep -E 'Physical footprint' || echo "  vmmap unavailable"

# 3 s idle + (3 s open + 3 s closed) per cycle, plus slack.
sleep $((4 + CYCLES * 7))

echo "app-reported footprint (task_info phys_footprint):"
grep -E '^footprint|^memory cycle' "$MLOG" 2>/dev/null || echo "  no measurements logged"

pkill -x Spendable 2>/dev/null || true
