#!/usr/bin/env bash
set -uo pipefail

# Changes the code on purpose, one edit at a time, and checks that the tests
# notice.
#
# A passing suite proves the tests ran, not that they would have caught
# anything -- the same distinction `Check.vacuous` exists for, applied to the
# tests themselves. So each mutant is a small, plausible mistake: a comparison
# flipped, a guard inverted, a constant negated. If the suite still passes, no
# test was actually watching that line, and the report says so.
#
#   scripts/mutate.sh                      # the inventory sources
#   scripts/mutate.sh path/to/File.swift   # something specific
#   MUTATE_MAX=10 scripts/mutate.sh        # a quicker sample
#
# Three outcomes per mutant:
#   killed    the suite failed. The line is watched.
#   SURVIVED  the suite passed. Nothing was watching. This is the finding.
#   skipped   the mutant did not compile, so it proves nothing either way.
#
# TWO PRECONDITIONS, both learned the hard way.
#
# Every target must be committed and clean. Restoring used to mean copying the
# file to a temp directory and copying it back from a trap. A trap does not run
# when the machine is restarted, and the temp copy does not survive it either,
# so a run that was interrupted left a mutated working tree that looked normal:
# `git status` showed the file as modified along with all the real work, and
# nothing said which line was a lie. It stayed there for an hour. Restoring
# through git instead means the mutation is always visible as a diff and
# `git checkout` always undoes it, whatever killed the run.
#
# And the suite must not touch the host. A mutant can invert a safety gate --
# `shouldProbe` decides which programs get executed, and flipping one `false`
# to `true` there turns "run twenty-three declared tools" into "run every
# executable on this machine", including GUI apps and installer stubs. That
# happened. It is survivable only because the tests are sealed into a sandbox
# (`sealed()` in Suites.swift), so the worst an inverted gate can reach is a
# handful of fixture shell scripts. Do not remove that seal.

BIN=".build/debug/foodtruck"
MAX="${MUTATE_MAX:-40}"

if [ $# -gt 0 ]; then
  TARGETS=("$@")
else
  TARGETS=(
    Sources/FoodTruckKit/Inventory/Scan.swift
    Sources/FoodTruckKit/Inventory/Probe.swift
    Sources/FoodTruckKit/Inventory/Managers.swift
    Sources/FoodTruckKit/Inventory/Inventory.swift
    Sources/FoodTruckKit/Inventory/InventoryStore.swift
    Sources/FoodTruckKit/Engine/InventoryRecipe.swift
  )
fi

# Pairs of "sed pattern>>>replacement". Each is a mistake somebody could
# actually make, rather than random noise: the point is to model a plausible
# wrong line, not to corrupt the file.
OPERATORS=(
  ' == >>> != '
  ' != >>> == '
  ' && >>> || '
  ' || >>> && '
  '[[:<:]]true[[:>:]]>>>false'
  '[[:<:]]false[[:>:]]>>>true'
  '\.isEmpty>>>.isEmpty == false'
  '\.first>>>.last'
  ' > >>> >= '
  ' < >>> <= '
)

git rev-parse --git-dir > /dev/null 2>&1 || {
  echo "mutate: not a git repository, and git is how mutations are undone" >&2
  exit 1
}
for file in "${TARGETS[@]}"; do
  git ls-files --error-unmatch -- "$file" > /dev/null 2>&1 || {
    echo "mutate: $file is not tracked by git." >&2
    echo "        Commit it first. An interrupted run leaves the mutation on" >&2
    echo "        disk, and git is the only thing that can show and undo it." >&2
    exit 1
  }
  git diff --quiet -- "$file" || {
    echo "mutate: $file has uncommitted changes." >&2
    echo "        Refusing to start: a mutation would be indistinguishable" >&2
    echo "        from your own edits, and restoring would discard them." >&2
    exit 1
  }
done

WORK="$(mktemp -d)"
CURRENT=""
# Restores from git, not from a copy. Survives anything that leaves the
# repository intact, and leaves a visible diff if something does not.
restore() { [ -n "$CURRENT" ] && git checkout -- "$CURRENT" && CURRENT=""; }
trap 'restore; rm -rf "$WORK"' EXIT INT TERM

# Collect candidates first, so the run has a known size before it starts.
: > "$WORK/candidates"
for file in "${TARGETS[@]}"; do
  [ -f "$file" ] || { echo "no such file: $file" >&2; exit 66; }
  for op in "${OPERATORS[@]}"; do
    pattern="${op%%>>>*}"
    replacement="${op##*>>>}"
    # Comment lines are skipped. Mutating prose proves nothing, and this file
    # is heavily commented, so leaving them in would drown the real signal.
    grep -n -- "$pattern" "$file" 2>/dev/null | while IFS=: read -r n _; do
      body="$(sed -n "${n}p" "$file")"
      case "$(echo "$body" | sed 's/^[[:space:]]*//')" in
        //*|/\**|\**) continue ;;
      esac
      printf '%s\t%s\t%s\t%s\n' "$file" "$n" "$pattern" "$replacement" >> "$WORK/candidates"
    done
  done
done

TOTAL="$(wc -l < "$WORK/candidates" | tr -d ' ')"
[ "$TOTAL" -gt 0 ] || { echo "no mutation candidates found"; exit 0; }

# Spread the sample across the whole file set rather than taking the first N,
# which would only ever test the top of the first file.
if [ "$TOTAL" -gt "$MAX" ]; then
  awk -v total="$TOTAL" -v max="$MAX" \
      'NR % int((total + max - 1) / max) == 1' "$WORK/candidates" > "$WORK/sample"
else
  cp "$WORK/candidates" "$WORK/sample"
fi
RUNNING="$(wc -l < "$WORK/sample" | tr -d ' ')"

echo "mutation testing: $RUNNING of $TOTAL candidates across ${#TARGETS[@]} files"
echo "if this is interrupted, \`git status\` will show the mutated file and"
echo "\`git checkout -- <file>\` will undo it."
echo ""

killed=0; survived=0; skipped=0; index=0
: > "$WORK/survivors"

while IFS=$'\t' read -r file line pattern replacement; do
  index=$((index + 1))
  CURRENT="$file"
  before="$(sed -n "${line}p" "$file" | sed 's/^[[:space:]]*//')"
  sed -i '' "${line}s/${pattern}/${replacement}/" "$file"
  after="$(sed -n "${line}p" "$file" | sed 's/^[[:space:]]*//')"

  label="$(printf '%s:%s' "$(basename "$file")" "$line")"
  if [ "$before" = "$after" ]; then
    skipped=$((skipped + 1))
    printf '  %2s/%s  skipped   %-28s (no change)\n' "$index" "$RUNNING" "$label"
  elif ! swift build > "$WORK/build.log" 2>&1; then
    skipped=$((skipped + 1))
    printf '  %2s/%s  skipped   %-28s (does not compile)\n' "$index" "$RUNNING" "$label"
  # Order is fixed here on purpose. A mutant must be killed by a test that
  # actually covers it, not by a shuffle that happened to expose it.
  elif "$BIN" selftest --in-order > "$WORK/test.log" 2>&1; then
    survived=$((survived + 1))
    printf '  %2s/%s  SURVIVED  %-28s %s\n' "$index" "$RUNNING" "$label" "$after"
    printf '%s:%s\n    was: %s\n    now: %s\n' "$file" "$line" "$before" "$after" >> "$WORK/survivors"
  else
    killed=$((killed + 1))
    by="$(grep -m1 '^not ok' "$WORK/test.log" | sed 's/^not ok [0-9]* - //')"
    printf '  %2s/%s  killed    %-28s by %s\n' "$index" "$RUNNING" "$label" "${by:-a test}"
  fi
  restore
done < "$WORK/sample"

swift build > /dev/null 2>&1

echo ""
echo "killed $killed, survived $survived, skipped $skipped"
if [ "$survived" -gt 0 ]; then
  echo ""
  echo "SURVIVORS — these lines can be changed without any test objecting:"
  sed 's/^/  /' "$WORK/survivors"
  exit 1
fi
echo "every mutant was caught"
