#!/bin/sh
# Launches the built Debug app several times and reports the time from process start (the
# kernel's p_starttime, so dyld and runtime start-up are included) to the menu bar item being on
# screen. The app measures this itself (LaunchTiming) and appends it to measurements.log in its
# container; the same number also goes to the unified log under category "launch".
#
# The first run after a build is the cold number; the later runs are the warm numbers the spec's
# 300 ms target is judged on. All are printed.
#
# Usage: scripts/measure-launch.sh [path/to/Spendable.app] [runs]
# Set SPENDABLE_DEBUG_CONTAINER=/some/dir to keep the run away from the real database.
set -eu

APP=${1:-DerivedData/Build/Products/Debug/Spendable.app}
RUNS=${2:-3}
[ -d "$APP" ] || { echo "measure-launch: no app at $APP (build first)" >&2; exit 1; }

CONTAINER=${SPENDABLE_DEBUG_CONTAINER:-"$HOME/Library/Group Containers/UW2KV7XB66.spendable"}
MLOG="$CONTAINER/measurements.log"
EXTRA=""
[ -n "${SPENDABLE_DEBUG_CONTAINER:-}" ] && EXTRA="--env SPENDABLE_DEBUG_CONTAINER=$SPENDABLE_DEBUG_CONTAINER"

pkill -x Spendable 2>/dev/null || true
sleep 1

i=1
while [ "$i" -le "$RUNS" ]; do
  rm -f "$MLOG"
  # shellcheck disable=SC2086
  open $EXTRA "$APP"
  sleep 3
  MS=$(grep -oE 'launch-to-bar [0-9]+' "$MLOG" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || true)
  if [ "$i" -eq 1 ]; then label="first launch after build"; else label="warm launch $i of $RUNS"; fi
  echo "$label: ${MS:-?} ms to visible menu bar item"
  pkill -x Spendable 2>/dev/null || true
  sleep 1
  i=$((i + 1))
done
