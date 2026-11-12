#!/usr/bin/env bash
# Smoke checks of the kit's small deterministic scripts: verdict/plan parsing, task state and write scope, read-only role and host-adapter hooks, plan-waves, run-role dry runs,
# init/doctor/sync/CI template, machine install, open-pr dispatch, formula, publishability scan, sdkit entry point, stack verify. Each case says whether it must pass or fail.
# Run: tests/smoke.test.sh
set -u
. "$(dirname "$0")/lib/common.sh"
export PATH="$KIT/tests/stubs:$PATH" OPENSPEC_STUB_LOG="$T/openspec.log"
# expect <name> <exit-code> <command...>
expect() { local name="$1" want="$2" got; shift 2; "$@" >"$T/out" 2>&1; got=$?
  if [ "$got" = "$want" ]; then ok "$name"; else bad "$name (exit $got, wanted $want)"; sed 's/^/    /' "$T/out" | head -8; fi; }
has() { local pat="$1"; shift; "$@" | grep -q -- "$pat"; }
sh_repo() { git_repo "$1" >/dev/null 2>&1; }   # a repo on main with one commit

# --- parse-verdict ---
cat > "$T/v-pass.txt" <<'X'
DOD
- D1 handles retry | PASS | retry_test.go:12
- D2 logs error | PASS | log_test.go:3
FINDINGS
- PLAUSIBLE | a.go:4 | maybe racy | two writers
VERIFY
- command: verify.sh | result: green | ok
VERDICT: PASS
X
sed 's/VERDICT: PASS/VERDICT: BLOCK/' "$T/v-pass.txt" > "$T/v-inconsistent.txt"
printf '## Definition of Done\n- D1: a | Verified by: unit test\n- D2: b | Verified by: unit test\n- D3: c | Verified by: manual check\n' > "$T/prop3.md"
expect "verdict pass" 0 "$KIT/scripts/parse-verdict.sh" "$T/v-pass.txt"
expect "verdict inconsistent with its DoD lines" 2 "$KIT/scripts/parse-verdict.sh" "$T/v-inconsistent.txt"
expect "verdict skipping a DoD item" 2 "$KIT/scripts/parse-verdict.sh" "$T/v-pass.txt" --proposal "$T/prop3.md"

# --- check-plan-parity ---
cat > "$T/plan.md" <<'X'
# Plan
## 3. Definition of Done
- D1: Retries three times | Verified by: integration test
- D2: logs the error | Verified by: unit test
## 5. Execution plan
- [ ] T1 add retry | role: developer | writes: svc/ | after:
- [ ] T2 tests | role: test-writer | writes: svc/x_test.go | after: T1
X
sed 's/Retries three times/Retries twice/' "$T/plan.md" > "$T/prop-text.md"
grep -v 'D2' "$T/plan.md" > "$T/prop-missing.md"
expect "parity equal" 0 "$KIT/scripts/check-plan-parity.sh" "$T/plan.md" "$T/plan.md" "$T/plan.md"
expect "parity text differs" 1 "$KIT/scripts/check-plan-parity.sh" "$T/plan.md" "$T/prop-text.md"
expect "parity text differs but --loose" 0 "$KIT/scripts/check-plan-parity.sh" "$T/plan.md" "$T/prop-text.md" --loose
expect "parity missing item" 1 "$KIT/scripts/check-plan-parity.sh" "$T/plan.md" "$T/prop-missing.md"

# --- state.sh retry rule, check-writes.sh scope (legacy project dir on purpose) ---
repo="$T/repo"; mkdir -p "$repo/.claude" "$repo/svc" "$repo/other"; : > "$repo/.claude/project.env"; printf 'work/\n' > "$repo/.claude/.gitignore"
echo a > "$repo/svc/a.go"; echo b > "$repo/other/b.go"; git_repo "$repo" >/dev/null 2>&1
cd "$repo" || exit 1
expect "state init" 0 "$KIT/scripts/state.sh" demo init medium feat/x
expect "state rejects a bad status" 2 "$KIT/scripts/state.sh" demo task T1 weird
expect "state first retry allowed" 0 "$KIT/scripts/state.sh" demo retry T1
expect "state second retry refused" 1 "$KIT/scripts/state.sh" demo retry T1
printf -- '- [ ] T1 impl | role: developer | writes: svc/ | after:\n- [ ] T2 docs | role: developer | after:\n' > "$T/tasks.md"
echo changed >> svc/a.go
expect "writes inside scope" 0 "$KIT/scripts/check-writes.sh" "$T/tasks.md" T1 HEAD
echo changed >> other/b.go
expect "writes outside scope" 1 "$KIT/scripts/check-writes.sh" "$T/tasks.md" T1 HEAD
expect "writes on a read-only task" 1 "$KIT/scripts/check-writes.sh" "$T/tasks.md" T2 HEAD
cd "$KIT" || exit 1

# --- hooks: read-only roles and host adapters ---
H="$T/hrepo"; mkdir -p "$H/.claude"; printf 'SECRET_GLOBS=.env*\nPROTECTED_PATHS=infra\nRUN_ROLE_MODEL_LIGHT=m-light\nRUN_ROLE_MODEL_STANDARD=m-std\nRUN_ROLE_MODEL_STRONG=m-strong\n' > "$H/.claude/project.env"; git -C "$H" init -q
ro() { printf '%s' "$1" | CLAUDE_PROJECT_DIR="$H" "$KIT/hooks/guard-readonly.sh"; }
expect "readonly role cannot Write" 0 bash -c "$(declare -f ro); H='$H' KIT='$KIT'; ro '{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"a\"},\"agent_type\":\"spec-driven-kit:verifier\"}' | grep -q '\"permissionDecision\": \"deny\"'"
expect "readonly role cannot chain git commit" 0 bash -c "$(declare -f ro); H='$H' KIT='$KIT'; ro '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git status && git commit -am x\"},\"agent_type\":\"reviewer\"}' | grep -q deny"
expect "readonly role may git diff | tail" 0 bash -c "$(declare -f ro); H='$H' KIT='$KIT'; [ -z \"\$(ro '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git diff main...HEAD 2>&1 | tail -40\"},\"agent_type\":\"verifier\"}')\" ]"
expect "writer role may Write" 0 bash -c "$(declare -f ro); H='$H' KIT='$KIT'; [ -z \"\$(ro '{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"a\"},\"agent_type\":\"developer\"}')\" ]"
gem() { printf '%s' "$1" | "$KIT/hooks/adapt.sh" gemini guard-secrets.sh 2>/dev/null; }
expect "gemini adapter denies .env read (exit 2)" 2 gem '{"hook_event_name":"BeforeTool","tool_name":"read_file","tool_input":{"file_path":".env"},"cwd":"'"$H"'"}'
expect "gemini adapter allows another file" 0 gem '{"hook_event_name":"BeforeTool","tool_name":"read_file","tool_input":{"file_path":"main.go"},"cwd":"'"$H"'"}'
expect "cursor adapter denies .env read" 0 bash -c "printf '%s' '{\"hook_event_name\":\"beforeReadFile\",\"file_path\":\".env.local\",\"workspace_roots\":[\"$H\"]}' | '$KIT/hooks/adapt.sh' cursor guard-secrets.sh | grep -q '\"permission\": \"deny\"'"

# --- plan-waves: grouping, size field, MAX_PARALLEL cap, cycle ---
printf -- '- [ ] T1 a | role: developer | size: large | writes: a/\n- [ ] T2 b | role: developer | writes: b/ | after: T1\n- [ ] T3 c | role: test-writer | writes: a/x_test.go\n- [ ] T4 d | role: developer | writes: d/\n' > "$T/w.md"
for i in 1 2 3 4 5; do printf -- '- [ ] P%s p | role: developer | writes: dir%s/\n' "$i" "$i"; done > "$T/w-wide.md"
pw() { env -u MAX_PARALLEL "$KIT/scripts/plan-waves.sh" "$@"; }
firstwave() { head -1 | grep -o 'P[0-9]' | wc -l | tr -d ' '; }
expect "plan-waves groups by dependency and shows size" 0 has 'wave 1: T1(developer,large)' pw "$T/w.md"
eq "plan-waves default cap is 3" "$(pw "$T/w-wide.md" | firstwave)" 3
eq "plan-waves MAX_PARALLEL=2 caps the wave" "$(MAX_PARALLEL=2 "$KIT/scripts/plan-waves.sh" "$T/w-wide.md" | firstwave)" 2
eq "plan-waves cap keeps every task" "$(MAX_PARALLEL=2 "$KIT/scripts/plan-waves.sh" "$T/w-wide.md" | grep -o 'P[0-9]' | sort -u | wc -l | tr -d ' ')" 5
printf -- '- [ ] A x | after: B\n- [ ] B y | after: A\n' > "$T/w-cycle.md"
expect "plan-waves cycle fails" 1 pw "$T/w-cycle.md"

# --- run-role dry runs: per-host command line, --tier model choice ---
printf 'ROLE: verifier\nTASK: x\n' > "$T/handoff.md"
rr() { (cd "$H" && "$KIT/scripts/run-role.sh" "$@" --handoff "$T/handoff.md" --dry-run); }
expect "run-role codex: read-only role gets a read-only sandbox" 0 has '--sandbox read-only' rr verifier --host codex
expect "run-role codex: writer gets workspace-write" 0 has '--sandbox workspace-write' rr developer --host codex
expect "run-role gemini: plan mode for a read-only role" 0 has '--approval-mode plan' rr verifier --host gemini
expect "run-role --tier large picks the strong model" 0 has '--model m-strong' rr developer --host claude --tier large
expect "run-role without --tier keeps the role tier" 0 has '--model m-std' rr developer --host claude
expect "run-role: an independent role never drops below its tier" 0 has '--model m-std' rr verifier --host claude --tier light
expect "run-role --model beats --tier" 0 has '--model forced' rr developer --host claude --tier large --model forced
expect "run-role unknown host" 2 rr verifier --host nope
expect "run-role bad tier" 2 rr developer --host claude --tier huge

# --- init (stack detection, CI template, OpenSpec), doctor, sync drift ---
G="$T/go"; mkdir -p "$G"; git -C "$G" init -q -b main; printf 'module x' > "$G/go.mod"; : > "$OPENSPEC_STUB_LOG"
expect "init --ci rejects an unknown host" 2 "$KIT/bin/init.sh" --ci svn "$G"
expect "init detects go, installs the CI gate and runs openspec init" 0 bash -c "'$KIT/bin/init.sh' --host claude,codex --ci gitlab '$G' >/dev/null && grep -q '^STACK=go' '$G/.sdkit/sdkit.env' && grep -q 'typed-nil' '$G/.sdkit/known-pitfalls.md' && grep -qE 'sdd[.]sh.? ci-check' '$G/.gitlab-ci.yml' && ! grep -q '__KIT_DIR__' '$G/.gitlab-ci.yml' && grep -q -- '--tools claude,codex' '$OPENSPEC_STUB_LOG' && test -f '$G/openspec/config.yaml'"
expect "the CI gate's env.sh is not git-ignored" 1 git -C "$G" check-ignore -q .sdkit/scripts/env.sh
expect "doctor sees the CI gate and the openspec skills" 0 bash -c "out=\$('$KIT/bin/doctor.sh' '$G' 2>&1); printf '%s' \"\$out\" | grep -q 'CI runs the spec-driven gate' && printf '%s' \"\$out\" | grep -q 'openspec skills present for Claude Code' && printf '%s' \"\$out\" | grep -q 'project.md still has TODO placeholders'"
expect "sync --check is clean after init" 0 "$KIT/bin/sync.sh" --check "$G"
echo "# local edit" >> "$G/.sdkit/scripts/sdd.sh"
expect "sync --check reports drift without modifying" 1 "$KIT/bin/sync.sh" --check "$G"
expect "doctor warns about drift" 0 bash -c "'$KIT/bin/doctor.sh' '$G' 2>&1 | grep -q 'differ from the kit'"


# --- stack verify scripts ---
PY="$T/py"; sh_repo "$PY"; ( cd "$PY" && printf '[project]\n' > pyproject.toml && git add -A && git commit -qm b && git checkout -qb f ) >/dev/null 2>&1
echo 'def g(:' > "$PY/bad.py"; expect "python verify fails on a syntax error" 1 bash -c "cd '$PY' && '$KIT/stacks/python/scripts/verify.sh' --fast --no-cache"
echo 'def g(): return 1' > "$PY/bad.py"; expect "python verify passes on valid code" 0 bash -c "cd '$PY' && '$KIT/stacks/python/scripts/verify.sh' --fast --no-cache"
GD="$T/gen"; mkdir -p "$GD/.claude"; sh_repo "$GD"; ( cd "$GD" && git checkout -qb f && echo b > b ) >/dev/null 2>&1
printf 'STACK=generic\nVERIFY_TEST_CMD=false\n' > "$GD/.claude/project.env"; expect "generic verify fails when VERIFY_TEST_CMD fails" 1 bash -c "cd '$GD' && '$KIT/stacks/generic/scripts/verify.sh' --no-cache"
printf 'STACK=generic\nVERIFY_TEST_CMD=true\n' > "$GD/.claude/project.env"; expect "generic verify passes when it passes" 0 bash -c "cd '$GD' && '$KIT/stacks/generic/scripts/verify.sh' --no-cache"
RP="$T/rnp"; sh_repo "$RP"; rnbase="$(git -C "$RP" rev-parse HEAD)"
printf '%s\n' 'const L = () => (' '  <FlatList' '    data={d}' '    renderItem={({ item }) => (' '      <View style={{ padding: 4 }}><Text>{item.name}</Text></View>' '    )}' '  />' ');' > "$RP/List.tsx"
expect "rn policy warns on an inline style inside renderItem" 0 bash -c "cd '$RP' && VERIFY_LIB='$KIT/scripts/verify-lib.sh' VERIFY_MERGE_BASE='$rnbase' VERIFY_CHANGED=List.tsx VERIFY_CHANGED_SRC=List.tsx bash '$KIT/stacks/react-native/verify.d.example/10-forbidden-patterns.sh.example' | grep -q 'WARN: List.tsx has an inline style'"

# --- machine install ---
xdg="$T/xdg"
expect "install.sh registers the kit" 0 bash -c "XDG_CONFIG_HOME='$xdg' '$KIT/bin/install.sh' >/dev/null && grep -qx '$KIT' '$xdg/spec-driven-kit/home'"
expect "install.sh --status ok" 0 env XDG_CONFIG_HOME="$xdg" "$KIT/bin/install.sh" --status
expect "install.sh --uninstall then --status fails" 1 bash -c "XDG_CONFIG_HOME='$xdg' '$KIT/bin/install.sh' --uninstall >/dev/null && XDG_CONFIG_HOME='$xdg' '$KIT/bin/install.sh' --status"

# --- open-pr.sh host dispatch (gh/glab stubbed) ---
pr="$T/pr"; prbin="$T/prbin"; mkdir -p "$pr/.claude" "$prbin"; : > "$pr/.claude/project.env"; sh_repo "$pr"; git -C "$pr" checkout -qb feat
for t in gh glab; do printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s $*" >> "%s/calls"\n' "$t" "$T" > "$prbin/$t"; chmod +x "$prbin/$t"; done
echo "the description" > "$T/desc.md"; git -C "$pr" remote add origin https://github.com/o/r.git
opr() { (cd "$pr" && PATH="$prbin:$PATH" "$KIT/scripts/open-pr.sh" T "$T/desc.md" main); }
expect "open-pr refuses an unpushed branch" 1 env PR_HOST=github bash -c "$(declare -f opr); pr='$pr' prbin='$prbin' KIT='$KIT' T='$T'; opr"
git -C "$pr" update-ref refs/remotes/origin/feat HEAD
rm -f "$T/calls"; expect "open-pr auto picks gh from a github origin" 0 env PR_HOST=auto bash -c "$(declare -f opr); pr='$pr' prbin='$prbin' KIT='$KIT' T='$T'; opr && grep -q '^gh pr create --base main --head feat' '$T/calls'"
git -C "$pr" remote set-url origin git@gitlab.example.com:g/r.git
rm -f "$T/calls"; expect "open-pr gitlab calls glab mr create" 0 env PR_HOST=auto bash -c "$(declare -f opr); pr='$pr' prbin='$prbin' KIT='$KIT' T='$T'; opr && grep -q '^glab mr create --source-branch feat --target-branch main' '$T/calls'"
git -C "$pr" remote set-url origin https://git.example.org/g/r.git
expect "open-pr auto fails on an unknown origin" 2 env PR_HOST=auto bash -c "$(declare -f opr); pr='$pr' prbin='$prbin' KIT='$KIT' T='$T'; opr"
oprc() { (cd "$pr" && PATH="$prbin:$PATH" "$KIT/scripts/open-pr.sh" --check); }
git -C "$pr" remote set-url origin https://bitbucket.org/o/r.git
expect "open-pr --check lists a missing Bitbucket token and opens nothing" 2 env -u BITBUCKET_TOKEN PR_HOST=bitbucket BITBUCKET_EMAIL=a@b.c bash -c "$(declare -f oprc); pr='$pr' prbin='$prbin' KIT='$KIT'; out=\$(oprc 2>&1); rc=\$?; case \"\$out\" in *BITBUCKET_TOKEN*) exit \$rc ;; *) exit 9 ;; esac"
git -C "$pr" remote set-url origin https://github.com/o/r.git
expect "open-pr --check passes for github with an authenticated gh" 0 env PR_HOST=github bash -c "$(declare -f oprc); pr='$pr' prbin='$prbin' KIT='$KIT'; oprc"

# --- Homebrew formula, publishability scan, sdkit entry point ---
gf="$T/gf"; mkdir -p "$gf/packaging/homebrew" "$gf/.claude-plugin"; cp "$KIT/packaging/homebrew/gen-formula.sh" "$gf/packaging/homebrew/"; echo '{"version":"9.9.9"}' > "$gf/.claude-plugin/plugin.json"
git -C "$gf" init -q -b main; git -C "$gf" remote add origin git@example.org:o/r.git; git -C "$gf" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x
expect "formula: refuses a release without its tag" 1 "$gf/packaging/homebrew/gen-formula.sh"
git -C "$gf" tag v9.9.9; gfrev="$(git -C "$gf" rev-parse HEAD)"
expect "formula: a tagged release pins tag and revision" 0 has "revision: \"$gfrev\"" "$gf/packaging/homebrew/gen-formula.sh"
expect "formula: credentials in the URL are stripped" 1 has 'dummy-pw' "$KIT/packaging/homebrew/gen-formula.sh" --head-only --repo-url https://user:dummy-pw@example.org/r.git
expect "committed formula parses and uses git" 0 bash -c "{ ! command -v ruby >/dev/null || ruby -c '$KIT/Formula/sdkit.rb' >/dev/null; } && grep -q 'using: :git' '$KIT/Formula/sdkit.rb'"
expect "scan: this repository has no hard findings" 0 "$KIT/packaging/scan-publishable.sh"
sd="$T/scan"; mkdir -p "$sd/packaging"; git -C "$sd" init -q -b main; cp "$KIT/packaging/scan-publishable.sh" "$sd/packaging/"
printf 'token = "%s"\nkey=%s\n' "abcdef1234567890" "ghp_$(printf 'a%.0s' $(seq 1 30))" > "$sd/leak.txt"; git -C "$sd" add -A
expect "scan: a planted token is caught" 1 bash -c "cd '$sd' && ./packaging/scan-publishable.sh"
expect "sdkit version" 0 has '^sdkit [0-9]' "$KIT/bin/sdkit" version
expect "sdkit rejects unknown commands" 2 "$KIT/bin/sdkit" nope
ln -s "$KIT/bin/sdkit" "$T/sk-link"
eq "sdkit works through a symlink" "$("$T/sk-link" where)" "$KIT"
finish smoke
