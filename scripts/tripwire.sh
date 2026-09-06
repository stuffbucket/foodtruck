#!/usr/bin/env bash
set -euo pipefail

# Proves that running FoodTruck's tests changed nothing on this machine.
#
# The env-var sandbox the tests use is good but not airtight, and the leaks are
# specific and measured rather than theoretical. On macOS 26, Foundation resolves
# the home directory through getpwuid(getuid()) and IGNORES $HOME, so
# NSHomeDirectory(), homeDirectoryForCurrentUser and ~ expansion all point at the
# real home no matter what the environment says. cfprefsd serves `defaults` by
# user id, so HOME=/tmp defaults write still hits the real domain. launchctl is
# per-uid. The keychain, /opt/homebrew and /usr/local are outside $HOME entirely.
#
# So this script does not try to prevent those writes. It detects them. Snapshot
# the host, run whatever you were going to run, snapshot again, and fail loudly
# on any difference. A leak becomes a red CI run instead of a mystery six months
# from now.
#
#   scripts/tripwire.sh -- .build/debug/foodtruck selftest

REAL_HOME="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory | awk '{print $2}')"

# A snapshot is a best-effort census, not an assertion. Absent files and
# unreadable directories are entirely normal here, so errexit is off for the
# duration: under `set -euo pipefail` a missing ~/.profile aborts the whole
# script with no output at all -- which is exactly the silent dead end this
# project promises not to ship. Learned the hard way, on the first run.
snapshot() (
  # pipefail too, not just errexit: it makes the pipeline inherit a failure
  # from any command inside the group, which is every one of them at some
  # point on some machine.
  set +e +o pipefail
  {
    ls -A "$REAL_HOME"
    find "$REAL_HOME/Library/LaunchAgents" -maxdepth 1
    find "$REAL_HOME/.config" "$REAL_HOME/.local/share" "$REAL_HOME/.local/state" -maxdepth 2
    ls "$REAL_HOME/Library/Preferences"
    ls /opt/homebrew/bin /usr/local/bin
    ls /Library/LaunchDaemons /Library/LaunchAgents /etc/paths.d /etc/manpaths.d
    # Spotlight spawns a transient launchd job per indexing task, with a
    # generated label, and they appear and vanish on their own: measured, this
    # snapshot differs from itself across a bare `sleep 6` about half the time.
    # Leaving them in makes the tripwire fail at random, and a guard that cries
    # wolf is worse than no guard because people learn to re-run it. Anything a
    # recipe could install carries a real label, never a generated one.
    launchctl list | awk '{print $3}' | grep -v '^com\.apple\.mdworker\.'
    security list-keychains
    ls /Volumes
    shasum "$REAL_HOME"/.zshrc "$REAL_HOME"/.zprofile "$REAL_HOME"/.zshenv \
           "$REAL_HOME"/.bash_profile "$REAL_HOME"/.profile "$REAL_HOME"/.gitconfig
  } 2>/dev/null | sort
  exit 0
)

[ "${1:-}" = "--" ] && shift
[ $# -gt 0 ] || { echo "usage: $0 -- <command> [args...]" >&2; exit 64; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

snapshot > "$WORK/before"
STATUS=0
"$@" || STATUS=$?
snapshot > "$WORK/after"

if ! diff -u "$WORK/before" "$WORK/after" > "$WORK/diff"; then
  echo "" >&2
  echo "HOST POLLUTION — the command below changed this machine:" >&2
  printf '  %s\n' "$*" >&2
  echo "" >&2
  sed -n '3,60p' "$WORK/diff" >&2
  echo "" >&2
  echo "No test may require a global change. Point the write at Locations(root:)" >&2
  echo "instead, or declare a higher blast radius on the recipe." >&2
  exit 1
fi

echo "tripwire: host unchanged"
exit "$STATUS"
