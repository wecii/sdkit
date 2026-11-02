#!/usr/bin/env bash
# Changed files -> the focused tests that cover them (F10). Deterministic, no LLM, conservative: anything the map does not know runs everything.
# Usage: test-select.sh list|run [--map FILE] [--base REF | --files "a b c"] [--tier T1|T3] [--no-cache]
#   Map (default <project-dir>/test-map.conf, else tests/test-map.conf), one rule per line, `#` comments:
#       @all  => <command> [;; <command>...]          the full suite (tier T3); required
#       <ERE on the changed path> => <command> [;; <command>...] | ALL | NONE
#   ALL = the @all commands (shared modules); NONE = nothing to run for it (docs only). The first rule is not special: every changed
#   file is matched against every rule and the commands are united. A file matching no rule selects ALL (never guess).
#   Changed files: --files, else `git diff --name-only <base>` + untracked (base: --base, default HEAD). Nothing changed -> nothing to run.
#   --tier T3 forces the full suite (milestones, risk boundaries); a mandatory high-risk test belongs in the map's `@always` line
#   (`@always => <command>`), which runs in every tier except an empty change.
#   run: executes the commands (up to --jobs N at a time, results always printed in map order) with `set -o pipefail` semantics (a failing command fails the run; no pipe hides it), prints
#   `[T1] <cmd> ... ok|FAIL (Ns)` per command, the full output goes to a log file whose path is printed on failure, and a summary line
#   `tests: tier=T1 commands=N ran=R cached=C failed=F skipped_suites=S elapsed=Ns`. A GREEN command is cached per exact tree + command
#   (HEAD, diff, untracked content outside <project-dir>, the command, the map); failures are never cached; --no-cache ignores the cache.
# Exit: 0 all green (or nothing to run), 1 a command failed, 2 usage / no map / no @all.
set -u
mode="${1:-}"; shift 2>/dev/null || true
map=""; base=HEAD; files=""; tier=""; nocache=0
cores="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"; jobs="${TEST_SELECT_JOBS:-$(( cores / 3 < 1 ? 1 : cores / 3 ))}"   # commands run this many at a time (--jobs N, TEST_SELECT_JOBS; 1 = in order)
while [ $# -gt 0 ]; do case "$1" in --map) map="$2"; shift ;; --base) base="$2"; shift ;; --files) files="$2"; shift ;; --tier) tier="$2"; shift ;; --no-cache) nocache=1 ;; --jobs) jobs="$2"; shift ;; *) echo "test-select: unknown option $1" >&2; exit 2 ;; esac; shift; done
case "$mode" in list|run) ;; *) echo "usage: test-select.sh list|run [--map F] [--base REF|--files \"a b\"] [--tier T1|T3] [--no-cache] [--jobs N]" >&2; exit 2 ;; esac
top="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$top" || exit 2
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_DIR=.sdkit; [ -f "$here/env.sh" ] && { . "$here/env.sh" 2>/dev/null; SDKIT_ENV_QUIET=1 sdkit_env_load "$top" 2>/dev/null; }
[ -n "$map" ] || for c in "$KIT_DIR/test-map.conf" tests/test-map.conf; do [ -f "$c" ] && { map="$c"; break; }; done
[ -f "$map" ] || { echo "test-select: no map (looked for $KIT_DIR/test-map.conf and tests/test-map.conf): run the full suite" >&2; exit 2; }
all="$(sed -n 's/^@all[[:space:]]*=>[[:space:]]*//p' "$map" | head -1)"; always="$(sed -n 's/^@always[[:space:]]*=>[[:space:]]*//p' "$map" | head -1)"
[ -n "$all" ] || { echo "test-select: $map has no '@all =>' line" >&2; exit 2; }
if [ -z "$files" ]; then files="$( { git diff --name-only "$base" 2>/dev/null; git ls-files -o --exclude-standard; } | sort -u)"; else files="$(printf '%s\n' "$files" | tr ' ' '\n' | awk 'NF')"; fi   # one path per line: paths may hold spaces
[ -n "${files//[[:space:]]/}" ] || { echo "tests: nothing changed, nothing to run"; exit 0; }

sel=""; why=""; full=0
if [ "$tier" = T3 ]; then full=1; why="tier T3 requested"; fi
# the map is read once, in bash: matching each changed file against each rule used to start four processes per pair (seconds per call)
RE_SP='^bash( -[a-z]+ [a-z]+)* +([A-Za-z0-9_./-]+\.sh)( .*)?$'   # the script a map command runs (group 2)
RES=(); RHSS=()
while IFS= read -r line; do
  case "$line" in ''|'#'*|'@'*) continue ;; esac
  re="${line%%=>*}"; rhs="${line#*=>}"
  re="${re%"${re##*[![:space:]]}"}"; rhs="${rhs#"${rhs%%[![:space:]]*}"}"; rhs="${rhs%"${rhs##*[![:space:]]}"}"
  RES+=("$re"); RHSS+=("$rhs")
done < "$map"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  hit=0
  for ((ri = 0; ri < ${#RES[@]}; ri++)); do
    re="${RES[$ri]}"; rhs="${RHSS[$ri]}"
    if [[ "$f" =~ $re ]]; then
      hit=1
      case "$rhs" in
        ALL) full=1; why="${why:+$why; }$f matches shared rule" ;;
        NONE) ;;
        *'\1'*) sel="$sel$(printf '%s\n' "$f" | sed -E "s#$re#$(printf '%s' "$rhs" | sed 's/[#&]/\\&/g')#")"$'\n' ;;
        *) sel="$sel$rhs"$'\n' ;;
      esac
    fi
  done
  [ "$hit" = 1 ] || { full=1; why="${why:+$why; }$f is not in the map (conservative: run all)"; }
done <<< "$files"
cmds=""
if [ "$full" = 1 ]; then cmds="$all"; else cmds="$sel"; fi
[ -n "$always" ] && cmds="$cmds"$'\n'"$always"
cmds="$(printf '%s\n' "$cmds" | sed 's/[[:space:]]*;;[[:space:]]*/\n/g' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | awk 'NF && !seen[$0]++')"
# A map rule can name a test script that no longer exists. Deleted IN THIS CHANGE (the path is among the changed files and gone from disk) = a deliberate deletion:
# that command is dropped with a note. Missing for any other reason = a broken map or checkout: it stays and FAILS at its turn (see the loop), never hidden.
gone=""; kept=""
while IFS= read -r c; do
  [ -n "$c" ] || continue
  sp=""; [[ "$c" =~ $RE_SP ]] && sp="${BASH_REMATCH[2]}"
  if [ -n "$sp" ] && [ ! -f "$sp" ] && printf '%s\n' "$files" | grep -Fxq -- "$sp"; then gone="${gone}${gone:+, }$sp"; else kept="$kept$c"$'\n'; fi
done <<< "$cmds"
cmds="$(printf '%s' "$kept" | awk 'NF')"
[ -z "$gone" ] || echo "test-select: not run, deleted in this change: $gone (remove or update the rule in the map)" >&2
t="T1"; [ "$full" = 1 ] && t="T3"
nall="$(printf '%s\n' "$all" | sed 's/[[:space:]]*;;[[:space:]]*/\n/g' | awk 'NF' | wc -l | tr -d ' ')"; ncmd="$(printf '%s\n' "$cmds" | awk 'NF' | wc -l | tr -d ' ')"
skipped=$(( nall > ncmd ? nall - ncmd : 0 )); [ "$full" = 1 ] && skipped=0
[ -n "$cmds" ] || { echo "tests: tier=T0 (no test covers: $(printf '%s' "$files" | tr '\n' ' ')) commands=0"; exit 0; }
if [ "$mode" = list ]; then echo "# tier=$t ${why:+reason: $why}"; printf '%s\n' "$cmds"; exit 0; fi

tree_key() {  # exact tree + map + command
  { git rev-parse HEAD 2>/dev/null; git diff HEAD 2>/dev/null
    git ls-files -o --exclude-standard | grep -v "^$KIT_DIR/" | while IFS= read -r f; do printf '%s\n' "$f"; [ -f "$f" ] && shasum "$f"; done
    cat "$map"; printf '%s\n' "$1"
    # what else changes the result of a green run: the project's settings (including the personal file git ignores), the price table, the day (prices have
    # effective dates), the tools, and the environment variables that switch kit behaviour. Bounded: nothing here changes within a run.
    for f in "$KIT_DIR/sdkit.env" "$KIT_DIR/sdkit.local.env" "$KIT_DIR/pricing.json" "$KIT_DIR/models.json"; do [ -f "$f" ] && { printf '%s\n' "$f"; shasum "$f"; }; done
    date -u +%F; bash --version | head -1; jq --version 2>/dev/null; git --version
    env | grep -E '^(SDKIT_|SDD_|ROUTE_|ROUTING=|TELEMETRY|USAGE_LOG|TOKEN_BUDGET|MAX_SPAWNS|CONTRACTS|RESULT_ENVELOPE|VALUE_REPORT|TZ=)' | sort; } | shasum | cut -d' ' -f1
}
cache="$top/$KIT_DIR/.test-cache"; log="$(mktemp "${TMPDIR:-/tmp}/sdkit-tests.XXXXXX")"
ran=0; cached=0; failed=0; ctime=0; cached_s=0; s0=$(date +%s)
# Pass 1 (in order): a missing script fails, an identical tree already green is reused. Pass 2: what is left runs up to $jobs at a time (the wait is the
# slowest suite, not the sum). Pass 3 (in order): results are printed and cached in the order of the map, whatever order they finished in.
jd="$(mktemp -d "${TMPDIR:-/tmp}/sdkit-tests.d.XXXXXX")"; njobs=0
while IFS= read -r c; do
  [ -n "$c" ] || continue
  sp=""; [[ "$c" =~ $RE_SP ]] && sp="${BASH_REMATCH[2]}"
  if [ -n "$sp" ] && [ ! -f "$sp" ]; then failed=$((failed + 1)); ran=$((ran + 1)); echo "[$t] $c ... FAIL: the map names $sp, which does not exist and was not deleted in this change (broken map or checkout)"; continue; fi
  k="$(tree_key "$c")"
  if [ "$nocache" = 0 ] && [ -f "$cache/$k" ]; then cached=$((cached + 1)); case "$(cat "$cache/$k" 2>/dev/null)" in ''|*[!0-9]*) ;; *) cached_s=$((cached_s + $(cat "$cache/$k"))) ;; esac; echo "[$t] $c ... ok (cached: identical tree already green)"; continue; fi
  njobs=$((njobs + 1)); printf '%s' "$c" > "$jd/$njobs.cmd"; printf '%s' "$k" > "$jd/$njobs.key"
done <<< "$cmds"
if [ "$njobs" -gt 0 ]; then
  export JD="$jd"
  seq 1 "$njobs" | xargs -P "$jobs" -I{} bash -c 'c0=$(date +%s); bash -o pipefail -c "$(cat "$JD/{}.cmd")" > "$JD/{}.out" 2>&1; echo $? > "$JD/{}.rc"; echo $(( $(date +%s) - c0 )) > "$JD/{}.dt"'
  n=1
  while [ "$n" -le "$njobs" ]; do
    c="$(cat "$jd/$n.cmd")"; k="$(cat "$jd/$n.key")"; rc="$(cat "$jd/$n.rc" 2>/dev/null || echo 1)"; dt="$(cat "$jd/$n.dt" 2>/dev/null || echo 0)"
    cat "$jd/$n.out" >> "$log" 2>/dev/null; ran=$((ran + 1))
    if [ "$rc" = 0 ]; then echo "[$t] $c ... ok (${dt}s)"; ctime=$((ctime + dt)); mkdir -p "$cache" && printf '%s\n' "$dt" > "$cache/$k"; ls -t "$cache" 2>/dev/null | tail -n +101 | while IFS= read -r o; do rm -f "$cache/$o"; done
    else failed=$((failed + 1)); echo "[$t] $c ... FAIL rc=$rc (${dt}s); full output: $log"; tail -15 "$jd/$n.out" | sed 's/^/    /'; fi
    n=$((n + 1))
  done
fi
rm -rf "$jd"
echo "tests: tier=$t commands=$ncmd ran=$ran cached=$cached failed=$failed skipped_suites=$skipped elapsed=$(( $(date +%s) - s0 ))s${why:+ reason: $why}"
# Value Report evidence (scripts/report.sh): what was selected, run, reused from the cache and left out. Counts and seconds only; never a path or a command.
# cached_s = the recorded duration of the cached green runs (measured earlier); the time of skipped suites was never measured and is not recorded.
if [ "${VALUE_REPORT:-}" = on ] || [ "${TELEMETRY:-}" = 1 ]; then
  rslug="$(sdkit_active_slug "$top" 2>/dev/null || true)"
  [ -n "$rslug" ] && [ -d "$top/$KIT_DIR/work/$rslug" ] && printf '{"ts":"%s","tier":"%s","all_commands":%s,"commands":%s,"ran":%s,"cached":%s,"failed":%s,"skipped_suites":%s,"elapsed_s":%s,"ran_s":%s,"cached_s":%s}\n' \
    "$(date -u +%FT%TZ)" "$t" "$nall" "$ncmd" "$ran" "$cached" "$failed" "$skipped" "$(( $(date +%s) - s0 ))" "$ctime" "$cached_s" >> "$top/$KIT_DIR/work/$rslug/selection.jsonl" 2>/dev/null
fi
[ "$failed" = 0 ] && { [ "$failed" = 0 ] && rm -f "$log"; exit 0; }
exit 1
