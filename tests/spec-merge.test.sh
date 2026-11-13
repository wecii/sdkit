#!/usr/bin/env bash
# Spec changes end to end (spec merge, WP3): change new, drift, check, apply of one change, apply of two siblings (plan, renumber, resolutions, revision label).
# Deterministic: a local bare repo as origin, synthetic specs, no model, no PR host. Run: tests/spec-merge.test.sh
set -u
. "$(dirname "$0")/lib/common.sh"
O="$T/origin.git"; R="$T/r"; git init -q --bare -b main "$O"
git_repo "$R"; cd "$R"; git remote add origin "$O"
mkdir -p .sdkit; printf 'BASE_BRANCH=main\nSTACK=generic\nPR_HOST=github\n' > .sdkit/sdkit.env
BIN="$T/bin"; mkdir -p "$BIN"; echo "body" > "$T/body.md"; echo '[]' > "$T/none.json"
cat > "$BIN/gh" <<EOS
#!/usr/bin/env bash
case "\$1 \$2" in
  "pr list") [ -f "$T/pr" ] && echo "https://example.test/pr/1"; exit 0 ;;
  "pr create") echo x >> "$T/pr"; echo "https://example.test/pr/1" ;;
  "pr edit") while [ \$# -gt 0 ]; do [ "\$1" = --body-file ] && cp "\$2" "$T/lastbody"; shift; done ;;
esac
EOS
chmod +x "$BIN/gh"; export PATH="$BIN:$PATH"
export CLAUDE_PROJECT_DIR="$R"; S="$KIT/scripts/spec.sh"; RV="$KIT/scripts/review.sh"
# mkbase <id>: an approved base on main (capability "social": AC 1, 2, 9)
mkbase() {
  mkdir -p "specs/$1/specs/social"
  printf '## ADDED Requirements\n\n### Requirement: Sign-in\n\n#### Scenario: AC-social-1 - Start\n- **THEN** the provider screen opens\n\n#### Scenario: AC-social-2 - Error\n- **THEN** the error is shown\n\n#### Scenario: AC-social-9 - Last\n- **THEN** nothing else\n' > "specs/$1/specs/social/spec.md"
  git add -A; git commit -qm "base $1"
  jq -n --arg i "$1" --arg h "$("$RV" hash "$1")" '{id:$i, version:"1.0", status:"approved", contentHash:$h, review:{}, history:[{version:"1.0", sha:"x", at:"2026-01-01T00:00:00Z", contentHash:$h}]}' > "specs/$1/spec.meta.json"
  git add -A; git commit -qm "approve $1"; git push -q origin main
}
# delta <id> <slug> <new ac number> <error text>: adds AC-social-<n> and rewrites AC-social-2; a tasks.md that mentions both
delta() {
  local d="specs/$1/changes/$2"; mkdir -p "$d/specs/social"
  printf '## ADDED Requirements\n\n### Requirement: Extra %s\n\n#### Scenario: AC-social-%s - Extra %s\n- **THEN** extra %s\n\n## MODIFIED Requirements\n\n### Requirement: Sign-in\n\n#### Scenario: AC-social-1 - Start\n- **THEN** the provider screen opens\n\n#### Scenario: AC-social-2 - Error\n- **THEN** %s\n\n#### Scenario: AC-social-9 - Last\n- **THEN** nothing else\n' "$2" "$3" "$2" "$2" "$4" > "$d/specs/social/spec.md"
  printf -- '- [ ] 1.1 AC-social-%s and AC-social-2 for %s\n' "$3" "$2" > "$d/tasks.md"
  "$S" change refresh "$1" "$2" >/dev/null && git add -A && git commit -qm "delta $2" && git push -q origin "spec/$1--$2"
}
mkbase S1; mkbase S0; mkbase LOGIN

echo "change new"
mkbase DRAFT; jq '.status = "draft"' specs/DRAFT/spec.meta.json > "$T/m" && mv "$T/m" specs/DRAFT/spec.meta.json; git add -A; git commit -qm draft; git push -q origin main
nocheck "an unapproved base is refused" "$S" change new DRAFT x
nocheck "a slug with -- is refused" "$S" change new S1 a--b
check "change new creates the branch and change.json" "$S" change new S1 solo --kind fix --title "Solo fix"
eq "branch spec/S1--solo, label 1.1, base 1.0" "$(git rev-parse --abbrev-ref HEAD)/$(jq -r '"\(.label)/\(.base.version)/\(.status)"' specs/S1/changes/solo/change.json)" "spec/S1--solo/1.1/1.0/open"
git checkout -q main
nocheck "an existing slug is refused" "$S" change new S1 solo
git checkout -q spec/S1--solo

echo "one change, base unmoved"
delta S1 solo 10 "the error is shown with a retry"
eq "refresh recorded expects and touches" "$(jq -r '"\(.touches | join(","))/\(.expects | keys | join(","))"' specs/S1/changes/solo/change.json)" "AC-social-10,AC-social-2/AC-social-2"
nocheck "check fails before the apply" "$S" check S1
check "drift: none" "$S" drift S1
check "apply exits 0" "$S" apply S1
eq "revision 1.1, draft, change applied" "$(jq -r '"\(.version)/\(.status)"' specs/S1/spec.meta.json)/$(jq -r .status specs/S1/changes/solo/change.json)" "1.1/draft/applied"
grep -q 'AC-social-10 - Extra solo' specs/S1/specs/social/spec.md && grep -q 'with a retry' specs/S1/specs/social/spec.md && ok "the delta is in the base" || bad "the delta is in the base"
grep -q 'AC-social-9 - Last' specs/S1/specs/social/spec.md && ok "untouched ACs stay" || bad "untouched ACs stay"
grep -q 'Change: solo' specs/S1/tasks.md && ok "the change's tasks are appended, tagged" || bad "the change's tasks are appended, tagged"
check "check passes after the apply" "$S" check S1
eq "a spec with no change: check OK" "$(rc "$S" check S0)" 0
git add -A; git commit -qm "apply solo"; git checkout -q main

echo "removal and a missing task are caught"
check "change new rm" "$S" change new S0 rm
mkdir -p specs/S0/changes/rm/specs/social
printf '## REMOVED Requirements\n\n### Requirement: Sign-in\n\n#### Scenario: AC-social-9 - Last\n- **THEN** gone\n' > specs/S0/changes/rm/specs/social/spec.md
check "apply of a removal" "$S" apply S0
eq "touches is filled by apply even without a refresh" "$(jq -r '.touches | join(",")' specs/S0/changes/rm/change.json)" "AC-social-9"
grep -q 'AC-social-9 (withdrawn)' specs/S0/specs/social/spec.md && ok "removed AC is withdrawn, id kept" || bad "removed AC is withdrawn, id kept"
git add -A; git commit -qm "apply rm"; git checkout -q main

echo "siblings"
"$S" change new LOGIN fix-a --kind fix >/dev/null; delta LOGIN fix-a 10 "text from A"
git checkout -q main; sleep 1; "$S" change new LOGIN feat-b >/dev/null; delta LOGIN feat-b 10 "text from B"
"$RV" begin LOGIN--feat-b --target specs/LOGIN/changes/feat-b >/dev/null && "$RV" record LOGIN--feat-b --verdict PASS --isolation fresh --findings "$T/none.json" >/dev/null
nocheck "publish of a change needs the change's own review (A has none here)" bash -c "cd '$R' && git checkout -q spec/LOGIN--fix-a && '$S' publish LOGIN --title t --body-file '$T/body.md'; r=\$?; git checkout -q spec/LOGIN--feat-b; exit \$r"
check "publish an open change" "$S" publish LOGIN --title "Change feat-b" --body-file "$T/body.md"
eq "the base version is untouched" "$(jq -r '"\(.version)/\(.history | length)"' specs/LOGIN/spec.meta.json)" "1.0/1"
grep -q 'SIBLINGS: fix-a: do not merge alone' "$T/lastbody" && ok "the PR body carries the sibling block" || bad "the PR body carries the sibling block"
eq "drift on B names A (rc 3)" "$(rc "$S" drift LOGIN)" 3
"$S" drift LOGIN | grep -q 'SIBLINGS: fix-a' && ok "drift names the sibling" || bad "drift names the sibling"
nocheck "check on B alone fails" "$S" check LOGIN
eq "apply on B alone exits 3 and changes nothing" "$(rc "$S" apply LOGIN)/$(git status --porcelain -- specs | wc -l | tr -d ' ')" "3/0"
git push -q origin spec/LOGIN--fix-a:main; SHA_A="$(git rev-parse spec/LOGIN--fix-a)"
eq "gate d: a sibling merged alone on main is not an approved revision (rc 1)" "$(rc "$S" approved-sha LOGIN --sha "$SHA_A")" 1
git merge -q --no-edit origin/spec/LOGIN--fix-a || bad "git merge of the sibling is clean"
eq "both siblings share label 1.1" "$(jq -r .label specs/LOGIN/changes/fix-a/change.json)/$(jq -r .label specs/LOGIN/changes/feat-b/change.json)" "1.1/1.1"
eq "apply with both present exits 3 with a plan" "$(rc "$S" apply LOGIN)/$(test -f .sdkit/work/spec-merge/LOGIN/plan.json && echo plan)" "3/plan"
eq "plan names the collision and the shared AC" "$(jq -r '"\(.collisions[0].id)/\(.shared[0].id)/\(.changes | length)"' .sdkit/work/spec-merge/LOGIN/plan.json)" "AC-social-10/AC-social-2/2"
for sl in fix-a feat-b; do
  jq '.resolutions = [{item:"AC-social-2", decision:"B wins", why:"test", by:"ana"}]' specs/LOGIN/changes/$sl/change.json > "$T/cj" && mv "$T/cj" specs/LOGIN/changes/$sl/change.json
done
check "apply after the resolutions exits 0" "$S" apply LOGIN
eq "merged revision is 1.2 (siblings share 1.1)" "$(jq -r .version specs/LOGIN/spec.meta.json)" "1.2"
eq "the earlier change keeps AC 10, the later is renumbered to 11" "$(grep -c 'AC-social-10 - Extra fix-a' specs/LOGIN/specs/social/spec.md)/$(grep -c 'AC-social-11 - Extra feat-b' specs/LOGIN/specs/social/spec.md)/$(jq -r '.renames["AC-social-10"]' specs/LOGIN/changes/feat-b/change.json)" "1/1/AC-social-11"
grep -q 'AC-social-11 and AC-social-2 for feat-b' specs/LOGIN/tasks.md && ok "the later change's tasks were rewritten" || bad "the later change's tasks were rewritten"
eq "both changes applied, all ACs present" "$(jq -r .status specs/LOGIN/changes/fix-a/change.json)/$(jq -r .status specs/LOGIN/changes/feat-b/change.json)/$(grep -c 'Scenario: AC-' specs/LOGIN/specs/social/spec.md)" "applied/applied/5"
check "check passes on the merged revision" "$S" check LOGIN
git add -A; git commit -qm "merged revision"
"$RV" begin LOGIN >/dev/null && "$RV" record LOGIN --verdict PASS --isolation fresh --findings "$T/none.json" >/dev/null
check "publish the merged revision" "$S" publish LOGIN --title "LOGIN 1.2" --body-file "$T/body.md"
eq "revision 1.2 recorded once in the history" "$(jq -r '"\(.version)/\(.history[-1].version)/\(.history | length)"' specs/LOGIN/spec.meta.json)" "1.2/1.2/2"
echo "approval of the merged revision, then tasks of the revision only"
check "promote prepares the revision" "$S" promote LOGIN
git push -q origin spec/LOGIN--feat-b spec/LOGIN--feat-b:main; SHA_M="$(git rev-parse HEAD)"
check "gate d: the merged revision is approved" "$S" approved-sha LOGIN --sha "$SHA_M"
jq -n --arg sha "$SHA_M" '{specId:"LOGIN",specVersion:"1.2",specSha:$sha,parent:"P-1",tasks:[]}' > "$T/rev.json"
sed -i.bak 's/"tasks":\[\]/"tasks":[{"ref":"A","title":"a","risk":"low","acceptanceCriteria":["AC-social-10"],"dependsOn":[],"scope":["x"]}]/' "$T/rev.json" 2>/dev/null; rm -f "$T/rev.json.bak"
eq "tasks.sh lists both changes of the revision" "$("$KIT/scripts/tasks.sh" changes "$T/rev.json" | sort | tr '\n' ' ')" "feat-b fix-a "
eq "only the ACs the revision added or modified need tasks (renamed id included)" "$("$KIT/scripts/tasks.sh" acs "$T/rev.json" --revision | tr '\n' ' ')" "AC-social-10 AC-social-11 AC-social-2 "

echo "gate c: pre-push (SPEC_CHECK_ON_PUSH)"
git checkout -q -b spec/LOGIN; HEADSHA="$(git rev-parse HEAD)"; ZERO="$(printf '0%.0s' $(seq 40))"
jq '.status = "open"' specs/LOGIN/changes/fix-a/change.json > "$T/cj" && cp "$T/cj" specs/LOGIN/changes/fix-a/change.json
gpe() { local on="$1"; shift; printf 'refs/heads/%s %s refs/heads/%s %s\n' "$1" "$HEADSHA" "$2" "$ZERO" | SDD_SKIP=1 GUARD_SKIP_VERIFY=1 SPEC_CHECK_ON_PUSH="$on" "$KIT/scripts/guard.sh" pre-push; }
eq "off by default: the push of the base branch passes" "$(rc gpe '' spec/LOGIN spec/LOGIN)" 0
eq "on: the base branch with an unapplied change is refused" "$(rc gpe 1 spec/LOGIN spec/LOGIN)" 1
eq "on: a change branch is never checked (it goes to review)" "$(rc gpe 1 spec/LOGIN spec/LOGIN--fix-a)" 0
git checkout -q -- specs/LOGIN/changes/fix-a/change.json
eq "on: a whole spec passes" "$(rc gpe 1 spec/LOGIN spec/LOGIN)" 0

echo "renumber: a new number never hits another id of the same change"
RN="$T/rn"; mkdir -p "$RN/specs/social" "$RN/changes/x/specs/social" "$RN/changes/y/specs/social"
printf '### Requirement: R\n#### Scenario: AC-social-1 - one\n- **THEN** a\n' > "$RN/specs/social/spec.md"
printf '## ADDED Requirements\n### Requirement: X\n#### Scenario: AC-social-5 - x\n- **THEN** x\n' > "$RN/changes/x/specs/social/spec.md"
printf '## ADDED Requirements\n### Requirement: Y\n#### Scenario: AC-social-5 - y5\n- **THEN** y\n#### Scenario: AC-social-6 - y6\n- **THEN** y\n' > "$RN/changes/y/specs/social/spec.md"
echo '{"slug":"x","createdAt":"2026-01-01T00:00:00Z"}' > "$RN/changes/x/change.json"; echo '{"slug":"y","createdAt":"2026-01-02T00:00:00Z","touches":["AC-social-5","AC-social-6"]}' > "$RN/changes/y/change.json"
eq "y's 5 becomes 7 (not 6, which y already has); x keeps 5" "$("$KIT/scripts/spec-apply.sh" renumber "$RN" x y)/$(jq -c .touches "$RN/changes/y/change.json")" 'y AC-social-5 AC-social-7/["AC-social-7","AC-social-6"]'

echo "open-pr.sh update and close (Bitbucket REST against a local stub)"
cat > "$T/bb.py" <<'PYX'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
log = open(sys.argv[1], "a")
class H(BaseHTTPRequestHandler):
    def _r(self, body):
        data = json.dumps(body).encode(); self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self): self._r({"values": [{"id": 7, "links": {"html": {"href": "https://bb.test/pr/7"}}}]})
    def _w(self):
        n = int(self.headers.get("Content-Length") or 0); log.write(self.command + " " + self.path + " " + self.rfile.read(n).decode() + "\n"); log.flush(); self._r({})
    do_PUT = do_POST = _w
    def log_message(self, *a): pass
import socketserver
class S(HTTPServer):
    def server_bind(self):  # HTTPServer.server_bind does a reverse DNS lookup that can take seconds
        socketserver.TCPServer.server_bind(self); self.server_name = "localhost"; self.server_port = self.socket.getsockname()[1]
srv = S(("127.0.0.1", 0), H); f = open(sys.argv[2], "w"); f.write(str(srv.server_port)); f.close(); srv.serve_forever()
PYX
python3 "$T/bb.py" "$T/bb.log" "$T/bb.port" & BBPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/bb.port" ] && break; sleep 0.3; done
BR="$T/bbrepo"; git_repo "$BR"; ( cd "$BR" && git remote add origin https://u:dummy-pw@bitbucket.org/ws/repo.git && git checkout -q -b spec/X--y && git update-ref refs/remotes/origin/spec/X--y HEAD )
printf 'new body\n' > "$T/nb.md"
export PR_HOST=bitbucket PR_API_BASE="http://127.0.0.1:$(cat "$T/bb.port")"
eq "update prints the PR url" "$(cd "$BR" && "$KIT/scripts/open-pr.sh" --repo-dir "$BR" --update "New title" "$T/nb.md" 2>/dev/null)" "https://bb.test/pr/7"
grep -q 'PUT /repositories/ws/repo/pullrequests/7 .*New title.*new body' "$T/bb.log" && ok "update PUTs title and description" || bad "update PUTs title and description"
printf 'merged into LOGIN--a\n' > "$T/note.md"
check "close a sibling PR with a note" "$KIT/scripts/open-pr.sh" --repo-dir "$BR" --close spec/X--other "ignored" "$T/note.md"
grep -q 'POST /repositories/ws/repo/pullrequests/7/comments .*merged into' "$T/bb.log" && grep -q 'POST .*/pullrequests/7/decline' "$T/bb.log" && ok "close comments, then declines" || bad "close comments, then declines"
kill $BBPID 2>/dev/null; unset PR_HOST PR_API_BASE
finish spec-merge
