#!/usr/bin/env bash
# Run the test files in parallel and say how long each took. A file over the budget (default 30 s) is flagged: split it or make it cheaper.
# Usage: tests/fast.sh [-j JOBS] [-b SECONDS] [--all] [file ...]     (default: every tests/*.test.sh and tests/run.sh, JOBS = half the cores)
# tests/slow/ holds the end-to-end tests whose single run is a whole simulated workflow (14-40 s each): they stay out of the everyday loop and run
# with --all (CI, before a release). A file in tests/ is expected to stay under the budget (30 s).
# Wall time is the slowest file, not the sum. Files are independent (each makes its own temp directory). Exit 1 if any file fails.
set -u
cd "$(dirname "$0")/.." || exit 2
jobs=$(( $(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4) / 2 )); [ "$jobs" -ge 1 ] || jobs=1; budget=30
all=0
while [ $# -gt 0 ]; do case "$1" in -j) jobs="$2"; shift 2 ;; -b) budget="$2"; shift 2 ;; --all) all=1; shift ;; *) break ;; esac; done
files=("$@"); [ ${#files[@]} -gt 0 ] || { files=(tests/*.test.sh tests/run.sh); [ "$all" = 0 ] || files+=(tests/slow/*.test.sh); }
out="$(mktemp -d)"; trap 'rm -rf "$out"' EXIT
export PATH="$PWD/tests/stubs:$PATH" FAST_OUT="$out"
one() { local f="$1" n s e rc; n="$(basename "$f")"; s=$SECONDS; bash "$f" > "$FAST_OUT/$n.log" 2>&1; rc=$?; e=$((SECONDS - s)); printf '%s %s %s\n' "$e" "$rc" "$f" > "$FAST_OUT/$n.time"; }
export -f one
t0=$SECONDS
printf '%s\n' "${files[@]}" | xargs -P "$jobs" -I{} bash -c 'one {}'
bad=0; over=0
printf '%6s  %-4s %s\n' sec rc file
for t in "$out"/*.time; do cat "$t"; done | sort -rn | while read -r e rc f; do
  flag=""; [ "$e" -gt "$budget" ] && flag="  <-- over ${budget}s"; [ "$rc" != 0 ] && flag="$flag  FAILED"
  printf '%6s  %-4s %s%s\n' "$e" "$rc" "$f" "$flag"
done
for t in "$out"/*.time; do read -r e rc f < "$t"; [ "$rc" = 0 ] || { bad=$((bad + 1)); echo "--- $f"; grep -E "FAIL" "$out/$(basename "$f").log" | head -5; }; [ "$e" -gt "$budget" ] && over=$((over + 1)); done
echo "wall $((SECONDS - t0))s | $over file(s) over ${budget}s, $bad failed"
[ "$bad" = 0 ]
