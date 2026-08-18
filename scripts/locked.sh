#!/bin/sh
# THE BUILD MUTEX: every compiling task runs through this, so concurrent
# invocations serialize instead of fighting over .build. A lock older than 10
# minutes is stale (a killed build) and gets stolen.
#   scripts/locked.sh <command...>
set -e
lock="${TMPDIR:-/tmp}/awake-build.lock"
while ! mkdir "$lock" 2>/dev/null; do
  if [ -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
    rmdir "$lock" 2>/dev/null || true
  else
    sleep 2
  fi
done
trap 'rmdir "$lock" 2>/dev/null' EXIT
"$@"
