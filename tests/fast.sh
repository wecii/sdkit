#!/usr/bin/env bash
# Run the test files in parallel and say how long each took. A file over the budget (default 30 s) is flagged: split it or make it cheaper.
# Usage: tests/fast.sh [--no-docker] [-j JOBS] [-b SECONDS] [file ...]     (default: every tests/*.test.sh; JOBS = half the cores)
# By default the run happens inside a small Debian container (tests/docker/Dockerfile): the same tools everywhere, and no endpoint-security scanner on every
# spawned process. --no-docker runs on this machine. Inside the container SDKIT_IN_DOCKER=1 is set, so it never nests.
# Every file in tests/ is expected to stay under the budget (30 s): keep a test to a few cases that share one scratch repo. tests/old/ holds the long
# pre-slimming versions as a reference only; nothing runs them.
# Wall time is the slowest file, not the sum. Files are independent (each makes its own temp directory). Exit 1 if any file fails.
set -u
cd "$(dirname "$0")/.." || exit 2
docker_run=1; args=()
for a in "$@"; do if [ "$a" = --no-docker ]; then docker_run=0; else args+=("$a"); fi; done
set -- ${args[@]+"${args[@]}"}
if [ "$docker_run" = 1 ] && [ -z "${SDKIT_IN_DOCKER:-}" ]; then
  command -v docker >/dev/null && docker info >/dev/null 2>&1 || { echo "fast.sh: docker is not available (install/start it, or run with --no-docker)" >&2; exit 2; }
  docker build -q -t sdkit-tests -f tests/docker/Dockerfile tests/docker >/dev/null || exit 2
  # the repo is copied into the container's own filesystem (a bind mount is slow on macOS) and committed as a fresh git repo (a worktree's .git file points
  # outside); tests/old is a reference, never run
  exec docker run --rm -e SDKIT_IN_DOCKER=1 -v "$PWD:/src:ro" sdkit-tests bash -c 'cp -R /src/. /work/ 2>/dev/null; rm -rf /work/tests/old /work/.git; git init -q -b main /work; git -C /work add -A >/dev/null 2>&1; git -C /work commit -qm snapshot >/dev/null 2>&1; exec bash tests/fast.sh "$@"' _ "$@"
fi
jobs=$(( $(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4) / 2 )); [ "$jobs" -ge 1 ] || jobs=1; budget=30
while [ $# -gt 0 ]; do case "$1" in -j) jobs="$2"; shift 2 ;; -b) budget="$2"; shift 2 ;; *) break ;; esac; done
files=("$@"); [ ${#files[@]} -gt 0 ] || { files=(tests/*.test.sh); }
out="$(mktemp -d)"; trap 'rm -rf "$out"' EXIT
export PATH="$PWD/tests/stubs:$PATH" FAST_OUT="$out"
one() { local f="$1" n s e rc; n="$(basename "$f")"; s=$SECONDS; printf '[%s] start  %s\n' "$(date +%H:%M:%S)" "$n"; bash "$f" > "$FAST_OUT/$n.log" 2>&1; rc=$?; e=$((SECONDS - s)); printf '%s %s %s\n' "$e" "$rc" "$f" > "$FAST_OUT/$n.time"; printf '[%s] done   %s  %ss rc=%s\n' "$(date +%H:%M:%S)" "$n" "$e" "$rc"; }
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
