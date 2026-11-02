#!/usr/bin/env bash
# Phase machine for the spec-driven workflow. The only thing that moves a task forward; hooks read the state it keeps.
#   start <slug> --risk low|medium|high --proposal <proposal.md> [--profile small|standard|high-assurance]
#                                                                  open a task (call after the user confirmed the risk label; the profile defaults to standard)
#   advance <phase> [--test-cmd CMD]                               move to the next phase if its gate holds
#   status | phase | check-fresh | fingerprint | abort
#   transitions                                                    the valid phase moves and what each one requires
#   evidence [--json]                                              the open task's independent evidence per role: valid|missing|block|stale|untrusted|wrong-task|conflict (F04)
#   policy [--json]                                                what the open task's profile and risk require (scripts/workflow.sh)
# Phases, strictly in order: intake -> proposed -> red -> green -> verified -> pr -> done
#   proposed  proposal.md has a Definition of Done with items (high: design.md also has a race/ordering/timing section)
#   red       --test-cmd runs and FAILS      green     --test-cmd runs and PASSES
#   verified  low: the verify command passes; medium/high: a PASS verdict recorded by the SubagentStop hook for THIS diff
#   gate edit <path> | gate push                                   exit 0 = allowed; exit 1 + reason on stdout = out of phase (hooks and git hooks call this)
#   ci-check                                                       CI gate: this diff needs a committed attestation (see below)
#   mode                                                           effective SDD_MODE: strict (default) | guided | off
#   task                                                           slug of the open task (empty when none); budget and ledger follow it
# Profile (process weight) is not risk (the gates): small = low risk only, standard = this workflow, high-assurance = an independent verifier PASS
#   at every risk, plus a handoff check for writing and deciding roles (workflow.sh). A profile never removes a gate. Both are fixed once the task starts.
# High risk (F04): verified, pr and done also need a PASS from each of verifier, reviewer and security-auditor that was produced by a REGISTERED agent run
#   (trust=spawned), on this diff, for this task. Evidence recorded by hand is kept but never satisfies that gate. `_spawn`, `_evidence`, `_spawn-close`
#   and `_verdict` are for the hooks and run-role.sh only (guard-pr.sh refuses them from the model's shell). Spec: docs/design-evidence.md.
# A refused move leaves the state untouched, prints why, and records phase.reject with a --reason (telemetry). Two advances at once: one wins.
# State lives in <project-dir>/.sdd/state.json (git-ignored).
set -u
SDKIT_ENV_VERIFY_BASE="${VERIFY_BASE:-}"; SDKIT_CI_BASE=""   # CI: the base ref as the CI environment gave it, before any settings file is read
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$(dirname "${BASH_SOURCE[0]}")/env.sh" || { echo "sdkit: env.sh is missing next to $(basename "$0"): run sdkit upgrade" >&2; exit 1; }; sdkit_env_load "$PROJECT_DIR"   # project dir (.sdkit, or a pre-1.0 one) and sdkit.env + sdkit.local.env, parsed
SDD_MODE="${SDD_MODE:-strict}"
STATE_DIR="$PROJECT_DIR/$KIT_DIR/.sdd"
STATE="$STATE_DIR/state.json"
PHASES="intake proposed red green verified pr done"
PROFILES="small standard high-assurance"
WF="$(dirname "${BASH_SOURCE[0]}")/workflow.sh"   # policy: what a profile adds (agents in flight, ...). It reads the state; only this script moves it

# tele <type> [flags]: one telemetry event for the open task (scripts/telemetry.sh). Off unless TELEMETRY=1; a failure here never changes what sdd does.
TELE="$(dirname "${BASH_SOURCE[0]}")/telemetry.sh"; TELE_PHASE=""
tele() {
  [ "${TELEMETRY:-}" = 1 ] && [ -x "$TELE" ] || return 0
  local t="" a=(); [ -f "$STATE" ] && t="$(jq -r '.task // empty' "$STATE" 2>/dev/null)"; [ -n "$t" ] && a=(--task "$t")
  "$TELE" emit "$@" ${a[@]+"${a[@]}"} >/dev/null 2>&1 || true
}
# report_final <status>: the Value Report of the task that is ending (scripts/report.sh finalize). Off unless VALUE_REPORT=on; prints on stderr, once per task,
# and a problem in it never changes what sdd does (the report reads records; it takes no part in a decision).
REPORT="$(dirname "${BASH_SOURCE[0]}")/report.sh"
report_final() {
  [ "${VALUE_REPORT:-}" = on ] && [ -x "$REPORT" ] || return 0
  local t=""; [ -f "$STATE" ] && t="$(jq -r '.task // empty' "$STATE" 2>/dev/null)"
  "$REPORT" finalize --status "$1" ${t:+--slug "$t"} >&2 2>&1 || true; return 0
}
# a refused phase move is an event too (TELE_PHASE is set while cmd_advance is checking a gate)
REASON=""   # why the move was refused (set by reject): one word from the telemetry reasons
die() {
  printf 'sdd: %s\n' "$*" >&2
  if [ -n "$TELE_PHASE" ]; then   # tests: the red/green gate refused because of the test run; every other refusal is a gate
    case "$REASON:$TELE_PHASE" in tests-*:*|:red|:green) tele phase.reject --phase "$TELE_PHASE" --category tests ${REASON:+--reason "$REASON"} ;; *) tele phase.reject --phase "$TELE_PHASE" --category gate ${REASON:+--reason "$REASON"} ;; esac
  fi
  exit 1
}
reject() { REASON="$1"; shift; die "$@"; }
need_state() { [ -f "$STATE" ] || die "no active task. Start one: sdd.sh start <slug> --risk <low|medium|high> --proposal <path>"; }
get() { jq -r "$1 // empty" "$STATE"; }
put() {  # read-modify-write under a lock: the hook (verdict) and the orchestrator can write at the same time
  local tmp rc; sdkit_lock "$STATE"; tmp="$(mktemp "$STATE.XXXXXX")"
  jq "$@" "$STATE" > "$tmp" && mv "$tmp" "$STATE"; rc=$?; rm -f "$tmp"; sdkit_unlock "$STATE"; return $rc
}
index_of() { local i=0 p; for p in $PHASES; do [ "$p" = "$1" ] && { echo "$i"; return; }; i=$((i + 1)); done; echo -1; }
# The only valid move is to the next phase (PHASES is the one definition; there is no way back except abort). Empty after the last one.
next_phase() { echo $PHASES | cut -d' ' -f$(( $(index_of "$1") + 2 )); }
needs_verifier() { [ "$1" != low ] || [ "$2" = high-assurance ]; }   # <risk> <profile>

kit_cmd() { case "$1" in "") echo "$PLUGIN_ROOT/$2" ;; /*) echo "$1" ;; *) echo "$PROJECT_DIR/$1" ;; esac; }
diff_base() {  # CI: the base the job gave; otherwise DIFF_BASE_CMD, or resolve-base.sh next to this script
  [ -n "$SDKIT_CI_BASE" ] && { echo "$SDKIT_CI_BASE"; return; }
  local r b; if [ -n "${DIFF_BASE_CMD:-}" ]; then r="$(kit_cmd "$DIFF_BASE_CMD" "")"; else r="$(dirname "${BASH_SOURCE[0]}")/resolve-base.sh"; fi
  b="$(cd "$PROJECT_DIR" && "$r" 2>/dev/null)"; echo "${b:-${VERIFY_BASE:-}}"
}

# Files that differ from where this branch left the diff base (tracked or not). The base moving on does not change the list.
# The workflow state and the attestations are not part of the change they describe.
# NUL-separated, so no file name is ever quoted or split. Returns non-zero when git cannot answer (unknown base, shallow clone): callers fail closed.
changed_files_z() (
  set -o pipefail
  base="$(diff_base)"
  cd "$PROJECT_DIR" || exit 1
  git rev-parse -q --verify "$base^{commit}" >/dev/null || exit 1
  mb="$(git merge-base "$base" HEAD 2>/dev/null)" || mb="$base"
  { git diff -z --name-only --no-renames "$mb" -- . ":!$KIT_DIR/.sdd" ":!$KIT_DIR/attestations" || exit 1
    git ls-files -z -o --exclude-standard -- . ":!$KIT_DIR/.sdd" ":!$KIT_DIR/attestations" || exit 1; } | sort -z -u
)
changed_files() ( set -o pipefail; changed_files_z | tr '\0' '\n' )

# fp_entry <path>: what the fingerprint records for one changed path: "<mode> <object id>", or "deleted"
fp_entry() {
  local f="$1" id
  if [ -L "$f" ]; then id="$(printf '%s' "$(readlink "$f")" | git hash-object --stdin)" && printf '120000 %s' "$id"
  elif [ -d "$f" ]; then   # a submodule (gitlink): its checked-out commit, or the recorded one when it is not checked out (CI)
    if [ -e "$f/.git" ]; then id="$(git -C "$f" rev-parse -q --verify HEAD)"; else id="$(git ls-files -s -- "$f" | awk '$1 == "160000" {print $2; exit}')"; fi
    [ -n "$id" ] && printf '160000 %s' "$id"
  elif [ -f "$f" ]; then id="$(git hash-object -- "$f")" && if [ -x "$f" ]; then printf '100755 %s' "$id"; else printf '100644 %s' "$id"; fi
  elif [ -e "$f" ]; then return 1
  else printf deleted; fi
}

# Hash of every changed path's mode and content. Stable across commit and rebase onto a moved base; changes on any further edit, chmod or submodule bump.
# Prints nothing and returns 1 when the diff cannot be listed or hashed: an empty fingerprint never matches anything.
fingerprint() (
  set -o pipefail
  cd "$PROJECT_DIR" || exit 1
  list="$(mktemp)" || exit 1; trap 'rm -f "$list"' EXIT
  changed_files_z > "$list" || { echo "sdd: cannot list the changes against '$(diff_base)' (unknown ref? fetch it; CI needs the full history)" >&2; exit 1; }
  while IFS= read -r -d '' f; do
    e="$(fp_entry "$f")" || { echo "sdd: cannot fingerprint '$f'" >&2; exit 1; }
    printf '%s\0%s\n' "$f" "$e"
  done < "$list" | sdkit_sha256 || { echo "sdd: cannot hash the diff (needs shasum, sha256sum or openssl)" >&2; exit 1; }
)

# ROUTING=on (tiered) picks the model per task from `size:`. A delegated task (a task line with `role:`) without one would silently run on its role's own tier,
# and that is exactly what an orchestrator that skipped references/model-routing.md does, so `advance proposed` refuses it. ROUTE_REQUIRE_SIZE=0 opts out.
missing_sizes() {  # <tasks.md>: the ids of task lines that name a role but carry no size:
  awk '/^[[:space:]]*-[[:space:]]*\[[ xX]\]/ && /role:/ && !/size:/ { sub(/^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*/, ""); split($0, a, " "); printf "%s ", a[1] }' "$1" 2>/dev/null
}
has_dod() {  # a "Definition of Done" heading followed by at least one list item
  awk '{l=tolower($0)} l ~ /^#+[ \t]+.*definition of done/{on=1; next} on && /^#+[ \t]/{exit} on && /^[ \t]*([-*]|[0-9]+\.)[ \t]+[^ \t]/{found=1} END{exit !found}' "$1"
}
has_race_section() { grep -qiE '^#+[ \t]+.*(race|ordering|timing)' "$1"; }

cmd_start() {
  local slug="${1:-}" risk="" proposal="" why profile=standard; shift || true
  while [ $# -gt 0 ]; do case "$1" in --risk) risk="$2"; shift ;; --proposal) proposal="$2"; shift ;; --profile) profile="$2"; shift ;; *) die "unknown option $1" ;; esac; shift; done
  [ -n "$slug" ] || die "usage: start <slug> --risk <low|medium|high> --proposal <path>"
  case "$slug" in .*|*[!A-Za-z0-9._-]*) die "slug '$slug' may only use letters, digits, '.', '_' and '-', and may not start with '.'" ;; esac
  case "$risk" in low|medium|high) ;; *) die "--risk must be low, medium or high (the user-confirmed label)" ;; esac
  [ -n "$proposal" ] || die "--proposal <path to the proposal.md that will hold the Definition of Done> is required"
  case " $PROFILES " in *" $profile "*) ;; *) die "--profile must be one of: $PROFILES" ;; esac
  [ "$profile" = small ] && [ "$risk" != low ] && die "profile small is for low risk only (this task is $risk). Use standard or high-assurance; a lighter profile never lowers a gate."
  [ -f "$STATE" ] && die "task '$(get .task)' is still open (phase $(get .phase)). Finish it or run: sdd.sh abort"
  [ "$SDD_MODE" = off ] || why="$(floor_validate "${RISK_FLOOR_GLOBS:-}")" || die "RISK_FLOOR_GLOBS is invalid: $why (expected level:glob,level:glob with level low|medium|high)"
  mkdir -p "$STATE_DIR"
  sdkit_lock "$STATE"   # two starts at once: the second sees the first's file
  if [ -f "$STATE" ]; then sdkit_unlock "$STATE"; die "task '$(get .task)' is still open (phase $(get .phase)). Finish it or run: sdd.sh abort"; fi
  jq -n --arg t "$slug" --arg r "$risk" --arg p "$proposal" --arg pf "$profile" --arg now "$(date -u +%FT%TZ)" \
    '{task:$t,risk:$r,profile:$pf,proposal:$p,phase:"intake",startedAt:$now,history:[{phase:"intake",at:$now}]}' > "$STATE"
  sdkit_unlock "$STATE"
  tele task.start --task "$slug" --risk "$risk" --profile "$profile" --phase intake
  [ "${TELEMETRY:-}" = 1 ] && [ "$profile" != standard ] && [ -x "$WF" ] && "$WF" announce >/dev/null 2>&1   # the handoff-check level this profile sets, as one decision event
  echo "task '$slug' opened (risk=$risk, profile=$profile, phase=intake). Write the proposal with a Definition of Done, then: sdd.sh advance proposed"
}

run_test_cmd() {  # run_test_cmd <cmd> -> exit status of the command
  local t0 rc=0; [ "${TELEMETRY:-}" = 1 ] && [ -x "$TELE" ] && t0="$("$TELE" now-ms 2>/dev/null)"
  (cd "$PROJECT_DIR" && bash -c "$1") >"$STATE_DIR/last-test.log" 2>&1 || rc=$?
  [ -n "${t0:-}" ] && tele test.result --phase "$TELE_PHASE" --outcome "$([ "$rc" = 0 ] && echo pass || echo fail)" --dur-ms "$(( $("$TELE" now-ms) - t0 ))" --q duration=actual
  return $rc
}

# The committed proof that this diff was verified: CI cannot see the git-ignored state, it checks this file instead.
# Written only here; it vouches for the repo's own rules, so protect <project-dir>/attestations/ with code review (CODEOWNERS).
write_attestation() {
  local dir="$PROJECT_DIR/$KIT_DIR/attestations" fl; mkdir -p "$dir"
  fl="$(floor_of "${RISK_FLOOR_GLOBS:-}" 2>/dev/null)" && fl="${fl%% *}" || fl=low   # the floor this diff had, for the record; CI recomputes it
  jq -n --arg t "$(get .task)" --arg r "$(get .risk)" --arg pf "$(get .profile)" --arg v "$(get .verdict.result)" --arg f "$1" \
        --argjson ev "$(jq -c '(.evidence // {}) | with_entries(.value |= {result,trust,fingerprint})' "$STATE" 2>/dev/null || echo '{}')" \
        --arg fl "$fl" --arg b "$(diff_base)" --arg k "$(jq -r .version "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null || cat "$PROJECT_DIR/$KIT_DIR/.scaffold-version" 2>/dev/null || echo unknown)" --arg now "$(date -u +%FT%TZ)" \
    '{task:$t,risk:$r,profile:($pf | if . == "" then "standard" else . end),floor:$fl,verdict:$v,evidence:$ev,fingerprint:$f,base:$b,kit:$k,at:$now}' > "$dir/$(get .task).json"
  echo "attestation written: $KIT_DIR/attestations/$(get .task).json (commit it with the change)"
}

# Agents still in flight block green and verified, but only where the profile asks for it (high-assurance); the answer comes from workflow.sh
wf_gate() {  # <green|verified> <profile>
  local m; [ "$2" = high-assurance ] && [ -x "$WF" ] || return 0
  m="$("$WF" gate "$1" 2>/dev/null)" || reject agents-pending "$m"
}

# <phase> -> what moving into it requires (the same checks cmd_advance makes; shown by `sdd.sh transitions`)
entry_rule() {
  case "$1" in
    proposed) echo "proposal.md has a Definition of Done list (high risk: design.md has a race/ordering/timing section)" ;;
    red) echo "--test-cmd runs and FAILS" ;;
    green) echo "the tests PASS, the risk floor holds, no agent is still in flight (high-assurance)" ;;
    verified) echo "the risk floor holds; low: the verify command passes; medium/high/high-assurance: an independent PASS for this exact diff" ;;
    pr) echo "none beyond verified: the push gate already holds the diff to the verified one before a PR exists" ;;
    done) echo "none (the PR is merged: the user's call)" ;;
  esac
}
cmd_transitions() {
  local prev="" p
  for p in $PHASES; do [ -n "$prev" ] && printf '%-18s %s\n' "$prev > $p" "$(entry_rule "$p")"; prev="$p"; done
  printf '%-18s %s\n' "verified|pr > verified" "re-verification, only while the verified diff is stale: the same checks as verified"
  printf '%-18s %s\n' "any > (aborted)" "sdd.sh abort; the only way back, and it ends the task"
}

cmd_advance() {
  need_state
  local target="${1:-}" test_cmd=""; shift || true
  while [ $# -gt 0 ]; do case "$1" in --test-cmd) test_cmd="$2"; shift ;; *) die "unknown option $1" ;; esac; shift; done
  local cur risk profile want seq xf="." xa=() att=""; cur="$(get .phase)"; risk="$(get .risk)"; profile="$(get .profile)"; profile="${profile:-standard}"   # (no profile = a task opened before F03)
  seq="$(get .evseq)"; seq="${seq:-0}"   # the evidence this advance judged; the move below is refused if more arrives meanwhile
  TELE_PHASE="$target"
  [ "$(index_of "$target")" -ge 0 ] || reject unknown-phase "unknown phase '$target' (phases: $PHASES)"
  want="$(next_phase "$cur")"
  # re-verification: once verified, a later edit makes the evidence stale and the only way forward is to verify again (same checks, same gate)
  if [ "$target" = verified ] && { [ "$cur" = verified ] || [ "$cur" = pr ]; } && [ "$(get .verifiedFingerprint)" != "$(fingerprint)" ]; then want=verified; fi
  [ "$target" = "$want" ] || reject not-next "cannot go from '$cur' to '$target'; the next phase is '${want:-none}'. Phases are not skipped."

  case "$target" in
    proposed)
      local proposal="$PROJECT_DIR/$(get .proposal)"
      [ -f "$proposal" ] || reject no-artifact "proposal not found: $(get .proposal)"
      if [ "${ROUTING:-off}" = on ] && [ "${ROUTE_POLICY:-tiered}" = tiered ] && [ "${ROUTE_REQUIRE_SIZE:-1}" != 0 ] && [ -f "$(dirname "$proposal")/tasks.md" ]; then
        local nosize; nosize="$(missing_sizes "$(dirname "$proposal")/tasks.md")"
        [ -z "$nosize" ] || reject no-task-size "$(dirname "$(get .proposal)")/tasks.md: ${nosize}have no size:. ROUTING=on routes the model by task size. Read references/model-routing.md, give every delegated task size: small|medium|large, and run this again (ROUTE_REQUIRE_SIZE=0 in sdkit.env gives up per-task routing)."
      fi
      has_dod "$proposal" || reject no-dod "$(get .proposal) has no 'Definition of Done' section with at least one list item. Each acceptance criterion needs a testable line."
      if [ "$risk" = high ]; then
        local design; design="$(dirname "$proposal")/design.md"
        [ -f "$design" ] && has_race_section "$design" || reject no-design "high risk: $(dirname "$(get .proposal)")/design.md needs a race / ordering / timing scenario section."
      fi ;;
    red)
      [ -n "$test_cmd" ] || reject no-artifact "--test-cmd is required: the command that runs the new tests"
      run_test_cmd "$test_cmd" && reject tests-pass "the tests PASS, so they prove nothing yet. They must fail for the right reason first (see $KIT_DIR/.sdd/last-test.log)."
      xf='.testCmd=$x'; xa=(--arg x "$test_cmd") ;;   # written with the move below, never before it
    green)
      local red_cmd; red_cmd="$(get .testCmd)"
      [ -z "$test_cmd" ] || [ -z "$red_cmd" ] || [ "$test_cmd" = "$red_cmd" ] || reject test-cmd-changed "GREEN re-runs the command that failed at RED ('$red_cmd'); a different command proves nothing about those tests. Run 'sdd.sh advance green' without --test-cmd."
      test_cmd="${red_cmd:-$test_cmd}"
      [ -n "$test_cmd" ] || reject no-artifact "--test-cmd is required"
      wf_gate green "$profile"
      run_test_cmd "$test_cmd" || { tail -20 "$STATE_DIR/last-test.log" >&2; reject tests-fail "the tests still fail (full output: $KIT_DIR/.sdd/last-test.log)"; }
      enforce_floor "$risk" ;;
    verified)
      enforce_floor "$risk"
      [ -f "$PROJECT_DIR/$(get .proposal)" ] || reject no-artifact "proposal not found: $(get .proposal) (it was there at 'proposed')"
      wf_gate verified "$profile"
      local fp; fp="$(fingerprint)" || reject no-fingerprint "cannot fingerprint the diff (see the message above)"
      if ! needs_verifier "$risk" "$profile"; then
        local verify; verify="$(kit_cmd "${VERIFY_CMD:-}" "stacks/$STACK/scripts/verify.sh")"
        if [ -x "$verify" ]; then
          (cd "$PROJECT_DIR" && "$verify") >"$STATE_DIR/last-verify.log" 2>&1 || { tail -20 "$STATE_DIR/last-verify.log" >&2; tele verify.result --outcome fail --source verify-cmd; reject verify-failed "the verify command failed"; }
          tele verify.result --outcome pass --source verify-cmd
        else
          echo "sdd: no verify command at $verify; low-risk gate passes on the green tests alone" >&2
        fi
      else
        local verdict why; verdict="$(get .verdict.result)"; why="$risk risk"; [ "$profile" = high-assurance ] && why="profile high-assurance"
        if [ "$verdict" = BLOCK ]; then
          reject verdict-block "the verifier BLOCKed this change. $(retry_hint)"
        fi
        [ "$verdict" = PASS ] || reject no-verdict "$why needs an independent verifier PASS (current: ${verdict:-none}). Run the verifier agent on a clean context; its verdict is recorded automatically."
        [ "$(get .verdict.fingerprint)" = "$fp" ] || reject stale-verdict "the diff changed after the verifier ran. Run the verifier again on the current diff."
      fi
      evidence_gate live
      xf='.verifiedFingerprint=$x'; xa=(--arg x "$fp"); att="$fp" ;;
    pr) evidence_gate live ;;   # high risk: the evidence must still match the diff that goes into the PR
    done) evidence_gate recorded ;;   # high risk: the merge moved the diff, so the check is against what was verified
  esac
  # the move is made only if the phase is still the one this advance checked: a second advance at the same moment loses here
  local eg=0; case "$target" in verified|pr|done) eg=1 ;; esac   # the gates that read evidence refuse to move on evidence that changed after they judged it
  put "${xa[@]+"${xa[@]}"}" --arg p "$target" --arg c "$cur" --argjson sq "$seq" --argjson eg "$eg" --arg now "$(date -u +%FT%TZ)" \
    'if .phase != $c then error("phase moved") elif $eg == 1 and (.evseq // 0) != $sq then error("evidence moved") else '"$xf"' | .phase=$p | .history += [{phase:$p,at:$now}] end' 2>/dev/null \
    || reject concurrent "the task changed while this advance was running (phase '$(get .phase)', evidence recorded meanwhile or another advance won); nothing was changed by this call."
  TELE_PHASE=""
  [ -n "$att" ] && write_attestation "$att"   # after the move: a refused or lost advance never leaves a proof behind
  tele phase.enter --from "$cur" --to "$target"
  [ "$target" = done ] && tele task.end --outcome completed
  [ "$target" = done ] && report_final completed
  if [ "$target" = done ]; then rm -f "$PROJECT_DIR/$KIT_DIR/.frozen"; rm -rf "$STATE_DIR"; echo "task closed"; else echo "phase: $target"; fi
  # a phase boundary is the cheapest place to drop the conversation: everything decided is in files now (stderr: stdout stays the phase line)
  if [ "${CONTEXT_HINT:-}" = 1 ]; then case "$target" in
    proposed) echo "boundary: the proposal is in $(dirname "$(get .proposal)")/ and the plan in $KIT_DIR/work/. If this session is large, /clear (or a new session) and resume with the task id loses nothing." >&2 ;;
    green) echo "boundary: tests are green. Verification starts from files only, so a /clear or new session here loses nothing." >&2 ;;
  esac; fi
}

# After a BLOCK: the one automatic retry (state.sh retry) may already be spent; then the next step is the user, not another run.
retry_hint() {
  local f="$PROJECT_DIR/$KIT_DIR/work/$(get .task)/state.json"
  if [ -f "$f" ] && jq -e '(.retries // {}) | length > 0' "$f" >/dev/null 2>&1; then
    echo "The one automatic retry is already spent: stop and ask the user."
  else
    echo "Implementation bug: one retry (state.sh <slug> retry <task>), then the verifier again. Spec gap: back to the plan gate and tell the user."
  fi
}

# --- independent evidence (F04) -----------------------------------------------------------------------------------------------
# Three roles judge a change independently: verifier, reviewer, security-auditor. Their verdicts are stored per role in state.json (.evidence), bound to
# the task and to the fingerprint of the diff, with a trust level:
#   spawned       produced by an agent run that was REGISTERED when it started (`_spawn`, called by the Claude Code PreToolUse hook or by run-role.sh)
#                 and whose registration this record consumed, on the same diff. Only this satisfies the high-risk gate.
#   unregistered  the host said an agent stopped but no spawn was registered (hook missing, older host wiring)
#   manual        recorded by hand (parse-verdict.sh --record on a host without hooks, or the legacy `_verdict`)
# A claim of a trusted source that cannot be backed by a registration is refused, not downgraded. The latest record per role wins, so a newer BLOCK
# always replaces an older PASS; a manual PASS never displaces a trusted PASS of the same diff. Every attempt is appended to .evidenceLog (last 40).
EV_ROLES="verifier reviewer security-auditor"
ev_role() { local r="${1##*:}"; r="${r%-deep}"; case "$r" in verifier|reviewer|security-auditor) echo "$r" ;; *) return 1 ;; esac; }

# Hook / run-role only: an independent role is being started; remember the diff it will see.
cmd__spawn() {
  local role src=hook run=""; role="$(ev_role "${1:-}")" || exit 0; shift
  while [ $# -gt 0 ]; do case "$1" in --source) src="$2"; shift ;; --run) run="$2"; shift ;; esac; shift; done
  [ -f "$STATE" ] || exit 0
  local fp; fp="$(fingerprint)" || exit 1
  put --arg r "$role" --arg s "$src" --arg run "$run" --arg fp "$fp" --arg now "$(date -u +%FT%TZ)" \
    '.spawns = (((.spawns // []) + [{role:$r,source:$s,run:$run,fp:$fp,at:$now}]) | .[-16:])'
}

# Hook / run-role only: the agent never answered (host error, killed): its registration is dropped and nothing is recorded as evidence.
#   _spawn-close --run ID [--reason WHY]           run-role: the registration with that run id
#   _spawn-close --role ROLE --source hook         Claude Code hook: a stopped agent that left no answer; the newest run-less registration of the role
cmd__spawn_close() {
  local run="" why=interrupted role="" src=hook
  while [ $# -gt 0 ]; do case "$1" in --run) run="$2"; shift ;; --reason) why="$2"; shift ;; --role) role="$(ev_role "$2")" || exit 0; shift ;; --source) src="$2"; shift ;; esac; shift; done
  [ -f "$STATE" ] && { [ -n "$run" ] || [ -n "$role" ]; } || exit 0
  put --arg run "$run" --arg role "$role" --arg src "$src" --arg why "$why" --arg now "$(date -u +%FT%TZ)" '
    (if $run != "" then ((.spawns // []) | map(.run == $run) | index(true))
     else ((.spawns // []) | map(.role == $role and .source == $src and .run == "") | rindex(true)) end) as $i
    | (if $i == null then {} else .spawns[$i] end) as $s
    | (if $i == null then . else .spawns |= del(.[$i]) end)
    | if $i == null and $run == "" then .
      else .evidenceLog = (((.evidenceLog // []) + [{role:($s.role // $role),run:$run,accepted:false,reason:$why,at:$now}]) | .[-40:]) end'
}

# Hook / run-role / parse-verdict.sh --record: record one role's verdict against the diff as it is right now.
#   _evidence <role> <PASS|BLOCK> [--source manual|hook|run-role] [--run ID] [--task SLUG]
# Exit: 0 recorded (the line says which trust), 1 refused (reason on stdout), 4 no task is open (nothing to record against; evidence after done lands here).
cmd__evidence() {
  [ -f "$STATE" ] || { echo "no active task" >&2; exit 4; }
  local role result src=manual run="" task="" n fp entry
  role="$(ev_role "${1:-}")" || die "evidence role must be verifier, reviewer or security-auditor"
  result="${2:-}"; case "$result" in PASS|BLOCK) ;; *) die "verdict must be PASS or BLOCK" ;; esac; shift 2
  while [ $# -gt 0 ]; do case "$1" in --source) src="$2"; shift ;; --run) run="$2"; shift ;; --task) task="$2"; shift ;; *) die "unknown option $1" ;; esac; shift; done
  case "$src" in manual|hook|run-role) ;; *) die "--source must be manual, hook or run-role" ;; esac
  n="$$-$RANDOM-$(date +%s)"; fp="$(fingerprint)" || die "cannot fingerprint the diff, nothing recorded"
  put --arg role "$role" --arg result "$result" --arg src "$src" --arg run "$run" --arg task "$task" --arg n "$n" --arg fp "$fp" --arg now "$(date -u +%FT%TZ)" '
    def logit($acc; $reason; $trust): .evidenceLog = (((.evidenceLog // []) + [{n:$n,role:$role,result:$result,run:$run,source:$src,trust:$trust,fp:$fp,at:$now,accepted:$acc,reason:$reason}]) | .[-40:]);
    def drop($gone): .spawns = [(.spawns // [])[] | select(. as $x | ($gone | index($x)) == null)];
    def refuse($reason; $gone): drop($gone) | logit(false; $reason; "-");
    def accept($trust; $gone):
      drop($gone) | .evseq = ((.evseq // 0) + 1) | (if $run != "" then .usedRuns = (((.usedRuns // []) + [{run:$run,role:$role}]) | .[-200:]) else . end) | (.evidence[$role] // null) as $old
      | if $trust != "spawned" and $result == "PASS" and $old != null and $old.trust == "spawned" and $old.result == "PASS" and $old.fingerprint == $fp
        then logit(false; "kept-trusted"; $trust)
        else .evidence[$role] = {result:$result,fingerprint:$fp,task:.task,trust:$trust,source:$src,run:$run,at:$now,seq:.evseq}
             | (if $role == "verifier" then .verdict = {result:$result,fingerprint:$fp,at:$now} else . end)
             | logit(true; "recorded"; $trust) end;
    (.spawns // []) as $sp
    | ([$sp[] | select(.role == $role and .source == $src)]) as $mine
    | if $task != "" and $task != .task then refuse("task-mismatch"; [])
      elif $run != "" and ((.usedRuns // []) | any(.run == $run and .role != $role)) then refuse("role-conflict"; [])
      elif $run != "" and ((.usedRuns // []) | any(.run == $run)) then refuse("duplicate"; [])
      elif $src == "run-role" then
        ([$mine[] | select(.run == $run)] | last) as $reg
        | if $run == "" or $reg == null then refuse("unknown-run"; [])
          elif $reg.fp != $fp then refuse("stale-at-record"; [$reg])
          else accept("spawned"; [$reg]) end
      elif $src == "hook" and $run != "" then
        ([$mine[] | select(.fp == $fp)] | last) as $reg | [$mine[] | select(.fp != $fp)] as $old
        | if ($old | length) > 0 then refuse("stale-at-record"; $old)
          elif $reg != null then accept("spawned"; [$reg])
          else accept("unregistered"; []) end
      else accept("manual"; []) end' || die "could not write the state"
  entry="$(jq -c --arg n "$n" '[(.evidenceLog // [])[] | select(.n == $n)] | last // empty' "$STATE" 2>/dev/null)"
  [ -n "$entry" ] || { echo "no active task" >&2; exit 4; }   # the task ended while this was running
  if [ "$(jq -r .accepted <<< "$entry")" = true ]; then
    echo "evidence: $role $result trust=$(jq -r .trust <<< "$entry")"
    if [ "$role" = verifier ]; then
      tele verify.result --outcome "$result" --source verifier
      [ "$result" = BLOCK ] && tele failure --category verdict-block --source verifier
    fi
    return 0
  fi
  case "$(jq -r .reason <<< "$entry")" in
    kept-trusted) echo "evidence: $role $result ignored (a trusted PASS for this diff is already recorded)"; return 0 ;;
    *) echo "evidence refused ($(jq -r .reason <<< "$entry")): $role $result" ; exit 1 ;;
  esac
}
# the original hook-only command, kept: a verifier verdict recorded by hand
cmd__verdict() { need_state; local r="${1:-}"; shift || true; cmd__evidence verifier "$r" "$@" >/dev/null; }

# ev_table <live|recorded> <role...>: one line per role "<role> TAB <state> TAB <verdict> TAB <trust> TAB <run>". The state is the whole story of its validity:
#   valid | missing | block | wrong-task | untrusted | stale | conflict (the same run id under two roles). live = against the diff as it is now;
#   recorded = against the fingerprint verified (the diff no longer exists after the merge, so `done` cannot recompute it).
ev_table() {
  local ref; if [ "$1" = live ]; then ref="${EV_REF:-$(fingerprint)}"; else ref="$(get .verifiedFingerprint)"; fi; shift   # EV_REF: a fingerprint the caller already computed
  jq -r --arg ref "$ref" --arg roles "$*" '
    . as $s | ($roles | split(" ") | map(select(. != ""))) as $rs
    | $rs[] as $r | ($s.evidence[$r] // null) as $e
    | [$r, (if $e == null then "missing"
            elif $e.result != "PASS" then "block"
            elif $e.task != $s.task then "wrong-task"
            elif $e.trust != "spawned" then "untrusted"
            elif $ref == "" or $e.fingerprint != $ref then "stale"
            elif ($e.run // "") == "" or ([$s.evidence[] | .run] | map(select(. == $e.run)) | length) > 1 then "conflict"
            else "valid" end), ($e.result // "-"), ($e.trust // "-"), (($e.run // "") | if . == "" then "-" else . end)] | @tsv' "$STATE"
}

ev_roles_required() {  # the roles the open task's profile and risk require independent evidence from (scripts/workflow.sh is the one policy)
  local r=""; [ -x "$WF" ] && r="$("$WF" evidence-roles 2>/dev/null)"
  [ -z "$r" ] && [ "$(get .risk)" = high ] && r="$EV_ROLES"   # fail closed: a policy script that is missing or broken never lowers the high-risk requirement
  [ -n "$r" ] && echo "$r"; return 0
}

# evidence_gate <live|recorded>: refuses (and says why) unless every required role has valid evidence
evidence_gate() {
  local roles role st n=0 want; roles="$(ev_roles_required)"; [ -n "$roles" ] || return 0
  want="$(echo $roles | wc -w | tr -d ' ')"
  while IFS=$'\t' read -r role st _; do
    n=$((n + 1))
    case "$st" in
      valid) ;;
      missing)    reject no-evidence "risk high needs an independent $role verdict (current: none). Run the $role agent on a clean context; its verdict is recorded automatically (Claude Code hook, or scripts/run-role.sh)." ;;
      block)      reject evidence-block "the $role BLOCKed this change. $(retry_hint)" ;;
      wrong-task) reject task-mismatch "the recorded $role evidence belongs to another task." ;;
      untrusted)  reject untrusted-evidence "the $role verdict was not produced by a registered agent run (recorded by hand, or the spawn was never registered), so it cannot satisfy risk high. Run the $role with the host's agent tool on Claude Code, or with scripts/run-role.sh." ;;
      stale)      reject stale-evidence "the diff changed after the $role ran (or no diff was verified). Run the $role again on the current diff." ;;
      conflict)   reject role-conflict "the $role evidence shares an agent run with another role: each role must be a separate agent run." ;;
      *)          reject no-evidence "$role evidence is $st." ;;
    esac
  done < <(ev_table "$1" $roles)
  [ "$n" = "$want" ] || reject no-evidence "the evidence state could not be read (expected $want roles, got $n): treated as missing."   # a failing query never opens the gate
}

cmd_evidence() {  # read-only view: every role, its validity state against the diff as it is now
  need_state
  local req rows; req="$(ev_roles_required | tr '\n' ' ')"
  if [ "${2:-}" = --with-fingerprint ]; then EV_REF="$(fingerprint)"; fi   # route.sh: the states and the fingerprint they were judged against, from one diff hash
  rows="$(ev_table live $EV_ROLES)"
  if [ "${1:-}" = --json ] && [ "${2:-}" = --with-fingerprint ]; then
    printf '%s\n' "$rows" | jq -R -s --arg req "$req" --arg fp "$EV_REF" '{fingerprint:$fp, roles:(split("\n") | map(select(. != "") | split("\t") | . as $f | {role:$f[0], state:$f[1], verdict:$f[2], trust:$f[3], run:$f[4], required:((($req | split(" ")) | index($f[0])) != null)}))}'
  elif [ "${1:-}" = --json ]; then
    printf '%s\n' "$rows" | jq -R -s --arg req "$req" 'split("\n") | map(select(. != "") | split("\t") | . as $f | {role:$f[0], state:$f[1], verdict:$f[2], trust:$f[3], run:$f[4], required:((($req | split(" ")) | index($f[0])) != null)})'
  else
    printf '%s\n' "$rows" | while IFS=$'\t' read -r role st v tr run; do
      mark=""; case " $req " in *" $role "*) mark="  (required)" ;; esac   # (not inside $(...): bash 3.2 cannot parse a case there)
      printf '%-18s %-10s verdict=%-5s trust=%-12s run=%s%s\n' "$role" "$st" "$v" "$tr" "$run" "$mark"
    done
  fi
}

cmd_check_fresh() {  # exit 0 only when the verified diff is the diff that exists now
  need_state
  [ "$(index_of "$(get .phase)")" -ge "$(index_of verified)" ] || exit 1
  [ "$(get .verifiedFingerprint)" = "$(fingerprint)" ]
}

matches_glob_list() {  # <path> <comma globs>: basename or whole path matches
  local path="$1" glob base patterns; base="$(basename "$path")"
  # read into an array: an unquoted `for glob in $2` would expand the patterns against the files in the current directory
  [ -n "$2" ] || return 1   # (bash 3.2 + set -u: an empty array expansion is an error)
  IFS=',' read -r -a patterns <<< "$2"
  for glob in "${patterns[@]}"; do
    [ -z "$glob" ] && continue
    case "$base" in $glob) return 0 ;; esac
    case "$path" in $glob) return 0 ;; esac
  done
  return 1
}

# --- risk floor (optional, off while RISK_FLOOR_GLOBS is empty) ---------------------------------------------------------------
# RISK_FLOOR_GLOBS=level:glob[,level:glob...]   level = low|medium|high, glob = the same kind as PROTECTED_PATHS/SECRET_GLOBS (basename or path).
# A task whose actual diff (changed_files, the set the fingerprint covers) touches a matching file may not carry a lower risk label than the
# strictest matching level. It is checked when the tests go green, when the task is verified, and in ci-check, where an attestation of a lower
# risk does not satisfy it. The label stays the user's; the floor only stops it from being too low for what the diff really touches.
risk_rank() { case "$1" in medium) echo 1 ;; high) echo 2 ;; *) echo 0 ;; esac; }   # low, and anything unknown, is the lowest

floor_validate() {  # <globs>: exit 0 when empty or well-formed; else print why and exit 1
  local entry list=()
  [ -n "$1" ] || return 0
  IFS=',' read -r -a list <<< "$1"
  for entry in "${list[@]}"; do
    [ -n "$entry" ] || continue
    case "$entry" in low:?*|medium:?*|high:?*) ;; *) echo "'$entry' is not <low|medium|high>:<glob>"; return 1 ;; esac
  done
  return 0
}

floor_of() {  # <globs>: print "<level> <first file that sets it>", or "low" when no changed file matches; exit 2 (and the reason) when invalid
  local globs="$1" best=low bestf="" f entry list=() why
  why="$(floor_validate "$globs")" || { echo "$why"; return 2; }
  [ -n "$globs" ] || { echo low; return 0; }
  IFS=',' read -r -a list <<< "$globs"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    for entry in "${list[@]}"; do
      [ -n "$entry" ] || continue
      matches_glob_list "$f" "${entry#*:}" || continue
      [ "$(risk_rank "${entry%%:*}")" -gt "$(risk_rank "$best")" ] && { best="${entry%%:*}"; bestf="$f"; }
    done
  done < <(changed_files)
  echo "$best${bestf:+ $bestf}"
}

floor_hit() {  # <globs> <file>: does any entry match the file (at any level)?
  local entry list=()
  [ -n "$1" ] || return 1
  IFS=',' read -r -a list <<< "$1"
  for entry in "${list[@]}"; do [ -n "$entry" ] && matches_glob_list "$2" "${entry#*:}" && return 0; done
  return 1
}

# enforce_floor <task risk>: strict refuses, guided warns, off does nothing
enforce_floor() {
  [ -n "${RISK_FLOOR_GLOBS:-}" ] && [ "$SDD_MODE" != off ] || return 0
  local res rc lvl file msg; res="$(floor_of "$RISK_FLOOR_GLOBS")"; rc=$?
  if [ "$rc" != 0 ]; then msg="RISK_FLOOR_GLOBS is invalid: $res (expected level:glob,level:glob with level low|medium|high)"
  else
    lvl="${res%% *}"; file="${res#* }"
    [ "$(risk_rank "$1")" -ge "$(risk_rank "$lvl")" ] && return 0
    msg="the diff touches '$file', which needs risk $lvl or higher (RISK_FLOOR_GLOBS), but this task is '$1'. A label cannot be lowered to fit a diff: ask the user to confirm the higher label, run 'sdd.sh abort', and open the task again with --risk $lvl."
  fi
  [ "$SDD_MODE" = guided ] && { echo "sdd (warning): $msg" >&2; return 0; }
  reject risk-floor "$msg"
}

# The single decision point for "may this happen in the current phase?". Hooks (Claude, Cursor, Gemini, OpenCode) and
# the git hooks all ask here, so every host enforces the same rule.
#   edit <path>  no task / intake -> docs, specs and project files only;  proposed -> test files only;  red and later -> anything
#   push         needs phase verified or pr, and the verified diff must still be the current one
cmd_gate() {
  [ "$SDD_MODE" = off ] && exit 0
  local kind="${1:-}" phase; phase="$([ -f "$STATE" ] && get .phase)"
  case "$kind" in
    edit)
      [ -n "${2:-}" ] || exit 0
      local rel; rel="$(sdkit_relpath "$PROJECT_DIR" "$2")"   # docs/../src/x and .sdkit/./.sdd/x are judged as what they really are
      [ -n "$rel" ] || exit 0
      case "$rel" in "$KIT_DIR"/.sdd/*|"$KIT_DIR"/attestations/*) echo "The workflow state and attestations are written only by sdd.sh and the verifier hook."; exit 1 ;; esac
      matches_glob_list "$rel" "$KIT_DIR/*,openspec/*,docs/*,*.md,${SDD_FREE_GLOBS:-}" && exit 0
      case "$phase" in
        "") echo "No spec-driven task is open, so '$rel' may not change yet. Start one with the spec-driven-dev skill (it opens the task after you confirm the risk label)."; exit 1 ;;
        intake) echo "Task '$(get .task)' is in 'intake': write the proposal with a Definition of Done and run 'sdd.sh advance proposed' before changing '$rel'."; exit 1 ;;
        proposed)
          matches_glob_list "$rel" "${SDD_TEST_GLOBS:-*_test.go,*.test.ts,*.test.tsx,*.test.js,*.spec.ts,*.spec.js,test_*.py,*_test.py,*Test.java,*Tests.java,*IT.java,*Test.kt,*Tests.kt,tests/*,test/*,*/tests/*,*/test/*,*/__tests__/*,src/test/*}" && exit 0
          echo "Phase 'proposed' is test-first: only test files may change. Write the failing test, then run 'sdd.sh advance red --test-cmd <cmd>'. '$rel' is not a test file (SDD_TEST_GLOBS)."; exit 1 ;;
      esac ;;
    push)
      case "$phase" in
        "") echo "Pushing or opening a PR outside a spec-driven task. Start one with the spec-driven-dev skill."; exit 1 ;;
        verified|pr) cmd_check_fresh 2>/dev/null || { echo "The diff changed after verification. Re-run the verifier, then 'sdd.sh advance verified'."; exit 1; } ;;
        *) echo "Task is in phase '$phase'; push and PR come after 'verified' (tests green, then verification)."; exit 1 ;;
      esac ;;
    *) die "usage: gate edit <path> | gate push" ;;
  esac
}

# Server-side check (run it in CI on the PR branch, with VERIFY_BASE=origin/<target branch>): every change that is not only
# docs/specs/project files needs a committed attestation for exactly this diff; medium and high also need a verifier PASS.
# With RISK_FLOOR_GLOBS the attestation's risk must also reach the floor of the files the diff really touches (recomputed here, never
# read from the attestation), and a file that matches a floor entry needs an attestation even where it would otherwise be free.
# ci_settings_from_base <base>: every setting comes from the base branch's committed settings file, so a pull request cannot loosen the gate
# that judges it (SDD_FREE_GLOBS=*, SDD_MODE=off, DIFF_BASE_CMD=...). Without one on the base (first adoption) this branch's settings stay.
ci_settings_from_base() {
  local tmp key; tmp="$(mktemp)"
  if ! (cd "$PROJECT_DIR" && git show "$1:$KIT_DIR/$KIT_ENV") > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; echo "sdd ci-check: the base branch has no $KIT_DIR/$KIT_ENV yet (first adoption): using this branch's settings"; return 0
  fi
  for key in $(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p; s/^[[:space:]]*:[[:space:]]+"?\$\{([A-Za-z_][A-Za-z0-9_]*):=.*/\1/p' \
               "$PROJECT_DIR/$KIT_DIR/$KIT_ENV" "$PROJECT_DIR/$KIT_DIR/sdkit.local.env" 2>/dev/null | sort -u); do
    _sdkit_env_refused "$key" || unset "$key"
  done
  SDKIT_ENV_QUIET=1 sdkit_env_load_file "$tmp"; rm -f "$tmp"
  STACK="${STACK:-$SDKIT_DEFAULT_STACK}"; SDD_MODE="${SDD_MODE:-strict}"
}

# Server-side check (run it in CI on the PR branch, with VERIFY_BASE=origin/<target branch> set by the CI job): every change that is not only
# docs/specs/project files needs a committed attestation for exactly this diff; medium and high also need a verifier PASS.
# Settings come from the base branch (ci_settings_from_base); DIFF_BASE_CMD is never run here. It fails closed: an unknown base, a diff that
# cannot be listed or hashed, or an attestation without a real fingerprint never passes. With RISK_FLOOR_GLOBS (the base's, plus any this
# branch adds) the attestation's risk must reach the floor of the files the diff really touches.
# The attestation itself is a file the author commits: this proves the flow was run for this diff, not who ran it. Review it like code.
cmd_ci_check() {
  local gated="" f why all_globs res lvl="low" lfile="" head_globs="${RISK_FLOOR_GLOBS:-}" files
  [ -n "$SDKIT_ENV_VERIFY_BASE" ] || { echo "sdd ci-check: FAIL VERIFY_BASE=origin/<target branch> must come from the CI job's environment"; return 1; }
  SDKIT_CI_BASE="$SDKIT_ENV_VERIFY_BASE"
  (cd "$PROJECT_DIR" && git rev-parse -q --verify "$SDKIT_CI_BASE^{commit}" >/dev/null) || {
    echo "sdd ci-check: FAIL base '$SDKIT_CI_BASE' is not a known commit (fetch the target branch; the checkout needs the full history)"; return 1; }
  ci_settings_from_base "$SDKIT_CI_BASE"
  [ "$SDD_MODE" = off ] && { echo "sdd ci-check: SDD_MODE=off on the base branch, skipped"; return 0; }
  why="$(floor_validate "$head_globs")" || { echo "sdd ci-check: FAIL RISK_FLOOR_GLOBS in this branch is invalid: $why"; return 1; }
  why="$(floor_validate "${RISK_FLOOR_GLOBS:-}")" || { echo "sdd ci-check: FAIL RISK_FLOOR_GLOBS on the base branch is invalid: $why"; return 1; }
  all_globs="${RISK_FLOOR_GLOBS:-}"; [ -n "$head_globs" ] && all_globs="$head_globs${all_globs:+,$all_globs}"
  if [ -n "$all_globs" ]; then res="$(floor_of "$all_globs")"; lvl="${res%% *}"; lfile="${res#* }"; fi
  files="$(changed_files)" || { echo "sdd ci-check: FAIL cannot list the changes against $SDKIT_CI_BASE"; return 1; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    matches_glob_list "$f" "$KIT_DIR/*,openspec/*,docs/*,*.md,${SDD_FREE_GLOBS:-}" && ! floor_hit "$all_globs" "$f" || gated="$gated $f"
  done <<< "$files"
  [ -n "$gated" ] || { echo "sdd ci-check: no code changes against $SDKIT_CI_BASE, nothing to attest"; return 0; }
  local fp a r v miss reason=""; fp="$(fingerprint)" || { echo "sdd ci-check: FAIL cannot fingerprint the diff"; return 1; }
  for a in "$PROJECT_DIR/$KIT_DIR"/attestations/*.json; do
    [ -f "$a" ] || continue
    [ "$(jq -r '.fingerprint // ""' "$a" 2>/dev/null)" = "$fp" ] || continue   # fp is 64 hex characters, so an empty or broken one never matches
    r="$(jq -r '.risk // "low"' "$a")"; v="$(jq -r '.verdict // ""' "$a")"
    if [ "$(risk_rank "$r")" -lt "$(risk_rank "$lvl")" ]; then
      reason="$(basename "$a"): risk $r is below the risk floor $lvl set by '$lfile' (RISK_FLOOR_GLOBS)"; continue
    fi
    if { [ "$r" != low ] || [ "$(jq -r '.profile // ""' "$a")" = high-assurance ]; } && [ "$v" != PASS ]; then reason="$(basename "$a"): risk $r (profile $(jq -r '.profile // "standard"' "$a")) needs a verifier PASS, found '$v'"; continue; fi
    if [ "$r" = high ]; then   # high risk: each independent role has a trusted PASS for exactly this diff (the attestation records them; the file is reviewed like code)
      miss="$(jq -r --arg fp "$fp" '[("verifier","reviewer","security-auditor") as $x | select(((.evidence[$x].result // "") != "PASS") or ((.evidence[$x].trust // "") != "spawned") or ((.evidence[$x].fingerprint // "") != $fp)) | $x] | join(",")' "$a")"
      [ -z "$miss" ] || { reason="$(basename "$a"): risk high needs a trusted PASS for this diff from verifier, reviewer and security-auditor; missing, blocked or untrusted: $miss"; continue; }
    fi
    echo "sdd ci-check: ok, $(basename "$a") attests this diff (risk $r, verdict ${v:-n/a}, risk floor $lvl)"; return 0
  done
  if [ -n "$reason" ]; then
    echo "sdd ci-check: FAIL $reason"
    [ "$lvl" = low ] || echo "  Open the task again with --risk $lvl or higher (the user confirms the label), verify it, and commit the new attestation."
    return 1
  fi
  echo "sdd ci-check: FAIL no attestation for this diff (fingerprint ${fp:0:12}). Changed:$gated"
  echo "  Run the spec-driven-dev flow to 'verified' on this exact diff and commit $KIT_DIR/attestations/<task>.json."
  echo "  Editing a file after verification invalidates it: re-verify, then commit the new attestation."
  return 1
}

cmd_status() {
  if [ ! -f "$STATE" ]; then echo "no active task"; return; fi
  printf 'task=%s risk=%s phase=%s' "$(get .task)" "$(get .risk)" "$(get .phase)"
  [ -n "$(get .profile)" ] && [ "$(get .profile)" != standard ] && printf ' profile=%s' "$(get .profile)"
  [ -n "$(get .verdict.result)" ] && printf ' verdict=%s' "$(get .verdict.result)"
  case "$(get .phase)" in verified|pr) cmd_check_fresh 2>/dev/null || printf ' evidence=stale' ;; esac
  printf '\n'
}

case "${1:-}" in
  start) shift; cmd_start "$@" ;;
  advance) shift; cmd_advance "$@" ;;
  status) cmd_status ;;
  transitions) cmd_transitions ;;
  policy) shift; [ -x "$WF" ] || { echo "sdd: workflow.sh is missing: run sdkit upgrade" >&2; exit 1; }; "$WF" policy "$@" ;;
  phase) [ -f "$STATE" ] && get .phase || true ;;
  check-fresh) cmd_check_fresh ;;
  gate) shift; ( cmd_gate "$@" ); rc=$?   # a subshell: cmd_gate exits, and a refusal is worth an event
        [ "$rc" = 0 ] || tele phase.reject --phase "$([ -f "$STATE" ] && get .phase)" --category gate --reason out-of-phase --source "gate-${1:-}"
        exit "$rc" ;;
  mode) echo "$SDD_MODE" ;;
  floor) shift; if [ "${1:-}" = --validate ]; then why="$(floor_validate "${RISK_FLOOR_GLOBS:-}")" || { echo "$why"; exit 2; }; else floor_of "${RISK_FLOOR_GLOBS:-}"; fi ;;
  task) get .task 2>/dev/null || true ;;
  ci-check) cmd_ci_check ;;
  fingerprint) fingerprint ;;
  abort) # sdd.sh abort [failed|blocked|partial]: the task ends without finishing; the word is the terminal state the Value Report states (default: aborted)
    case "${2:-}" in failed|blocked|partial) rst="$2" ;; *) rst=aborted ;; esac
    [ -f "$STATE" ] && { tele task.end --outcome aborted; report_final "$rst"; }; rm -rf "$STATE_DIR"; rm -f "$PROJECT_DIR/$KIT_DIR/.frozen"; echo "task aborted" ;;
  _verdict) shift; cmd__verdict "$@" ;;
  _evidence) shift; cmd__evidence "$@" ;;
  _spawn) shift; cmd__spawn "$@" ;;
  _spawn-close) shift; cmd__spawn_close "$@" ;;
  evidence) shift; cmd_evidence "$@" ;;
  *) sed -n '2,10p' "$0"; exit 2 ;;
esac
