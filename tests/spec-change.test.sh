#!/usr/bin/env bash
# scripts/spec-change.sh (spec merge, WP1): AC parsing, normalised AC hash, expects/touches against a base, change.json validation, overlap of siblings.
# Deterministic, synthetic fixtures only (no model, no git). Run: tests/spec-change.test.sh
set -u
. "$(dirname "$0")/lib/common.sh"
SC="$KIT/scripts/spec-change.sh"
B="$T/specs/LOGIN"; mkdir -p "$B/specs/login-social" "$B/specs/login-entry"

# ---- fixtures: a base, two sibling deltas, a broken delta ----
cat > "$B/specs/login-social/spec.md" <<'EOF'
# Login social

## ADDED Requirements

### Requirement: Social sign-in

SHALL start the provider flow.

#### Scenario: AC-login-social-1 - Start flow
- **WHEN** the user taps a provider
- **THEN** the provider screen opens

#### Scenario: AC-login-social-3 - New user
- **WHEN** a new user returns from the provider
- **THEN** no session is started and sign-up completion opens

#### Scenario: AC-login-social-5 (withdrawn) - Old merge
- **THEN** WITHDRAWN: replaced by AC-login-social-1

### Requirement: Provider errors

SHALL show an error.

#### Scenario: AC-login-social-2 - Provider error
- **WHEN** the provider returns an error
- **THEN** the error message is shown

#### Scenario: AC-login-social-9 - Last one
- **THEN** nothing else happens
EOF
cat > "$B/specs/login-entry/spec.md" <<'EOF'
## ADDED Requirements

### Requirement: Web entry

#### Scenario: AC-login-entry-1 - Landing
- **THEN** the landing page opens
EOF
# a change dir: mk <slug> <createdAt> ; its delta is written by the caller to $T/<slug>/specs/login-social/spec.md
mk() { mkdir -p "$T/$1/specs/login-social"; }
mk fix-timeout; mk apple-email; mk bad; mk same
cat > "$T/fix-timeout/specs/login-social/spec.md" <<'EOF'
## ADDED Requirements

### Requirement: Provider timeout

#### Scenario: AC-login-social-10 - Timeout shows the error
- **WHEN** the provider does not answer
- **THEN** the timeout error is shown

## MODIFIED Requirements

### Requirement: Provider errors

#### Scenario: AC-login-social-2 - Provider error
- **WHEN** the provider returns an error or times out
- **THEN** the error message is shown

#### Scenario: AC-login-social-9 - Last one
- **THEN** nothing else happens
EOF
cat > "$T/apple-email/specs/login-social/spec.md" <<'EOF'
## ADDED Requirements

### Requirement: Apple hidden e-mail

#### Scenario: AC-login-social-10 - Apple hidden e-mail sign-in
- **THEN** the relay address is stored

## MODIFIED Requirements

### Requirement: Provider errors

#### Scenario: AC-login-social-2 - Provider error
- **WHEN** the provider returns an error
- **THEN** a retry button is shown with the error message

#### Scenario: AC-login-social-9 - Last one
- **THEN** nothing else happens

### Requirement: Social sign-in

#### Scenario: AC-login-social-1 - Start flow
- **WHEN** the user taps a provider
- **THEN** the provider screen opens

#### Scenario: AC-login-social-3 - New user
- **WHEN** a new user returns from the provider
- **THEN** the account is created and the home page opens
EOF
# same ADDED id and the same words as fix-timeout (whitespace differs only)
cat > "$T/same/specs/login-social/spec.md" <<'EOF'
## ADDED Requirements
### Requirement: Provider timeout (copy)
#### Scenario: AC-login-social-10 -   Timeout shows the error
-   **WHEN** the provider does not answer
-	**THEN** the timeout error is shown
EOF
cat > "$T/bad/specs/login-social/spec.md" <<'EOF'
## ADDED Requirements

### Requirement: Reuses things

#### Scenario: AC-login-social-5 - Reuses a withdrawn id
- **THEN** x

#### Scenario: AC-login-social-1 - Exists already
- **THEN** x

#### Scenario: A scenario without an id
- **THEN** x

## MODIFIED Requirements

### Requirement: Ghost

#### Scenario: AC-login-social-77 - Not in the base
- **THEN** x

### Requirement: Social sign-in

#### Scenario: AC-login-social-1 - Start flow changed
- **THEN** y

## REMOVED Requirements

### Requirement: Provider errors

#### Scenario: AC-login-social-99 - Not in the base
- **THEN** x
EOF

js() { "$SC" "$@" 2>/dev/null; }

echo "parse"
P="$(js parse "$B")"
eq "ids in file order, per capability" "$(printf '%s' "$P" | jq -r '[.acs[].id] | join(",")')" "AC-login-entry-1,AC-login-social-1,AC-login-social-3,AC-login-social-5,AC-login-social-2,AC-login-social-9"
eq "a withdrawn AC is flagged, others are not" "$(printf '%s' "$P" | jq -r '[.acs[] | select(.withdrawn) | .id] | join(",")')" "AC-login-social-5"
eq "requirements keep their AC set and section" "$(printf '%s' "$P" | jq -r '.requirements[] | select(.title == "Social sign-in") | "\(.capability)/\(.section)/\(.acs | join("+"))"')" "login-social/ADDED/AC-login-social-1+AC-login-social-3+AC-login-social-5"
h1="$(printf '%s' "$P" | jq -r '.acs[] | select(.id == "AC-login-social-2") | .hash')"
echo "$h1" | grep -Eq '^[0-9a-f]{64}$' && ok "the hash is sha256" || bad "the hash is sha256 ($h1)"
# same words, other whitespace/blank lines/CRLF => same hash; the changed words => another hash
W="$T/ws/specs/login-social"; mkdir -p "$W"
printf '### Requirement: X\r\n\r\n####   Scenario:   AC-login-social-2   -   Provider error  \r\n\r\n-   **WHEN**  the provider returns an error\r\n-\t**THEN** the error message   is shown\r\n\r\n' > "$W/spec.md"
eq "whitespace, blank lines and CRLF do not change the hash" "$(js parse "$T/ws" | jq -r '.acs[0].hash')" "$h1"
eq "an unchanged AC hashes the same in the base and in a delta" "$(js parse "$T/fix-timeout" | jq -r '.acs[] | select(.id == "AC-login-social-9") | .hash')" "$(printf '%s' "$P" | jq -r '.acs[] | select(.id == "AC-login-social-9") | .hash')"
nocheck "changed words change the hash" test "$(js parse "$T/fix-timeout" | jq -r '.acs[] | select(.id == "AC-login-social-2") | .hash')" = "$h1"
# a spec that has a changes/ directory hashes its base files only
mkdir -p "$B/changes/fix-timeout"; cp -R "$T/fix-timeout/specs" "$B/changes/fix-timeout/"
eq "changes/ under a base is not parsed as base content" "$(js parse "$B" | jq -r '.acs | length')" "6"
eq "an empty directory is an error (rc 1)" "$(mkdir -p "$T/empty" && rc "$SC" parse "$T/empty")" 1

echo "compute (expects / touches)"
A="$(js compute "$T/fix-timeout" --base "$B")"
eq "A: added 10, modified 2, 9 unchanged" "$(printf '%s' "$A" | jq -r '"\(.added | join(","))/\(.modified | join(","))/\(.unchanged | join(","))/\(.removed | join(","))"')" "AC-login-social-10/AC-login-social-2/AC-login-social-9/"
eq "A: touches = added + modified (an unchanged AC is not touched)" "$(printf '%s' "$A" | jq -r '.touches | join(",")')" "AC-login-social-10,AC-login-social-2"
eq "A: expects holds the base hash of the modified AC only" "$(printf '%s' "$A" | jq -c '.expects | to_entries | map(.key)')" '["AC-login-social-2"]'
eq "A: expects value = the normalised base hash" "$(printf '%s' "$A" | jq -r '.expects["AC-login-social-2"]')" "$h1"
eq "A: no problems" "$(printf '%s' "$A" | jq -r '.problems | length')" 0
Bc="$(js compute "$T/apple-email" --base "$B")"
eq "B: added 10, modified 2 and 3, 1 unchanged" "$(printf '%s' "$Bc" | jq -r '"\(.added | join(","))/\(.modified | join(","))/\(.unchanged | join(","))"')" "AC-login-social-10/AC-login-social-2,AC-login-social-3/AC-login-social-1,AC-login-social-9"
eq "check rc 0 for a clean delta" "$(rc "$SC" compute "$T/apple-email" --base "$B")" 0

echo "bad deltas are named, not guessed"
X="$(js compute "$T/bad" --base "$B")"; rcx="$(rc "$SC" compute "$T/bad" --base "$B")"
eq "problems => rc 1, JSON still printed" "$rcx/$(printf '%s' "$X" | jq -r '.problems | length > 0')" "1/true"
pb() { printf '%s' "$X" | jq -r '.problems[]' | grep -q -- "$1" && ok "problem: $2" || bad "problem: $2"; }
pb 'AC-login-social-5.*withdrawn' "ADDED reuses a withdrawn id"
pb 'AC-login-social-1.*exists' "ADDED of an id the base already has"
pb 'without an AC id' "a scenario without an AC id"
pb 'Ghost.*no AC of the base' "MODIFIED that matches nothing in the base"
pb 'AC-login-social-99.*not in the base' "REMOVED of a missing AC"
pb 'Social sign-in.*drops AC-login-social-3' "MODIFIED requirement that silently drops an AC"
nocheck "a withdrawn base AC left out of a MODIFIED requirement is not a drop" bash -c '"$0" compute "$1" --base "$2" | jq -r ".problems[]" | grep -q "drops AC-login-social-5"' "$SC" "$T/bad" "$B"
mkdir -p "$T/rm/specs/login-social"
printf '## REMOVED Requirements\n### Requirement: Provider errors\n**Reason**: gone\n' > "$T/rm/specs/login-social/spec.md"
eq "REMOVED requirement without scenarios removes its active ACs (header match)" "$(js compute "$T/rm" --base "$B" | jq -r '.removed | join(",")')" "AC-login-social-2,AC-login-social-9"
mkdir -p "$T/wd/specs/login-social"
printf '## MODIFIED Requirements\n### Requirement: Provider errors\n#### Scenario: AC-login-social-2 (withdrawn) - Provider error\n- **THEN** WITHDRAWN\n#### Scenario: AC-login-social-9 - Last one\n- **THEN** nothing else happens\n' > "$T/wd/specs/login-social/spec.md"
eq "a withdrawn marker inside MODIFIED counts as a removal" "$(js compute "$T/wd" --base "$B" | jq -r '"\(.removed | join(","))/\(.modified | join(","))"')" "AC-login-social-2/"

echo "moved (the base changed under a change)"
# the change records expects (as update-specs will)
jq -n --argjson e "$(printf '%s' "$A" | jq -c .expects)" --argjson t "$(printf '%s' "$A" | jq -c .touches)" '{slug:"fix-timeout", title:"Timeout", kind:"fix", label:"1.1", status:"open", createdAt:"2026-01-02T10:00:00Z",
  base:{version:"1.0", contentHash:("a" * 64)}, expects:$e, touches:$t}' > "$T/fix-timeout/change.json"
jq -n --argjson e "$(printf '%s' "$Bc" | jq -c .expects)" --argjson t "$(printf '%s' "$Bc" | jq -c .touches)" '{slug:"apple-email", title:"Apple", kind:"feature", label:"1.1", status:"open", createdAt:"2026-01-03T10:00:00Z",
  base:{version:"1.0", contentHash:("a" * 64)}, expects:$e, touches:$t}' > "$T/apple-email/change.json"
check "moved reads expects from change.json" "$SC" moved "$T/fix-timeout" --base "$B"
cp "$B/specs/login-social/spec.md" "$T/base.orig"
sed -i.bak 's/the error message is shown/the localised error message is shown/' "$B/specs/login-social/spec.md"; rm -f "$B/specs/login-social/spec.md.bak"
eq "an edited base AC is reported (rc 1, id on stdout)" "$(rc "$SC" moved "$T/fix-timeout" --base "$B")/$("$SC" moved "$T/fix-timeout" --base "$B" 2>/dev/null)" "1/AC-login-social-2"
cp "$T/base.orig" "$B/specs/login-social/spec.md"
check "restored base: rc 0 again" "$SC" moved "$T/fix-timeout" --base "$B"

echo "overlap of siblings"
O="$(js overlap "$T/fix-timeout" "$T/apple-email" --base "$B")"
eq "same id ADDED with different words is a collision" "$(printf '%s' "$O" | jq -c '.collisions | map({id, same, changes})')" '[{"id":"AC-login-social-10","same":false,"changes":["fix-timeout","apple-email"]}]'
eq "the same AC modified by both is shared" "$(printf '%s' "$O" | jq -c '.shared | map({id, changes})')" '[{"id":"AC-login-social-2","changes":["fix-timeout","apple-email"]}]'
eq "changes are ordered by createdAt, not by argument order" "$(js overlap "$T/apple-email" "$T/fix-timeout" --base "$B" | jq -c '.collisions[0].changes')" '["fix-timeout","apple-email"]'
eq "same id, same normalised words: collision with same=true" "$(js overlap "$T/fix-timeout" "$T/same" --base "$B" | jq -c '.collisions | map({id, same})')" '[{"id":"AC-login-social-10","same":true}]'
eq "disjoint changes: nothing" "$(js overlap "$T/rm" "$T/same" --base "$B" | jq -c '[.collisions, .shared]')" '[[],[]]'

echo "validate change.json"
check "a good change validates (schema only)" "$SC" validate "$T/fix-timeout"
check "a good change validates against the base" "$SC" validate "$T/fix-timeout" --base "$B"
vt() { # vt <name> <jq filter that breaks change.json>  => must fail
  mkdir -p "$T/v/$1"; cp -R "$T/fix-timeout/specs" "$T/v/$1/"; jq "$2" "$T/fix-timeout/change.json" > "$T/v/$1/change.json"
  nocheck "rejected: $1" "$SC" validate "$T/v/$1"; }
vt slug '.slug = "other"'
vt kind '.kind = "chore"'
vt label '.label = "v1"'
vt status '.status = "done"'
vt createdAt 'del(.createdAt)'
vt basehash '.base.contentHash = "xyz"'
vt expects '.expects = {"AC-login-social-2": "short"}'
vt touches '.touches = "AC-login-social-2"'
vt applied-missing '.status = "applied"'
vt resolution '.resolutions = [{"item": "AC-login-social-2"}]'
vt renames '.renames = {"AC-login-social-10": 11}'
mkdir -p "$T/v/ok"; cp -R "$T/fix-timeout/specs" "$T/v/ok/"
jq '.slug = "ok" | .status = "applied" | .applied = {version:"1.1", at:"2026-01-04T10:00:00Z", sha:"abc"} | .renames = {"AC-login-social-10": "AC-login-social-11"} | .resolutions = [{item:"AC-login-social-2", decision:"combine", why:"both", by:"ana"}]' "$T/fix-timeout/change.json" > "$T/v/ok/change.json"
check "applied + renames + resolutions validate" "$SC" validate "$T/v/ok"
mkdir -p "$T/v/stale"; cp -R "$T/fix-timeout/specs" "$T/v/stale/"; jq '.touches = ["AC-login-social-2"]' "$T/fix-timeout/change.json" > "$T/v/stale/change.json"
nocheck "touches that differ from the delta are rejected against the base" "$SC" validate "$T/v/stale" --base "$B"
nocheck "a delta with problems is rejected against the base" "$SC" validate "$T/bad" --base "$B"
nocheck "a missing change.json is rejected" "$SC" validate "$T/rm"

echo "coverage"
CV="$T/cv"; mkdir -p "$CV/specs/social" "$CV/changes/c1/specs/social"
printf '### Requirement: R\n#### Scenario: AC-social-1 - a\n- **THEN** a\n#### Scenario: AC-social-10 - b\n- **THEN** b\n' > "$CV/specs/social/spec.md"; { echo "## MODIFIED Requirements"; cat "$CV/specs/social/spec.md"; } > "$CV/changes/c1/specs/social/spec.md"
echo '{"slug":"c1","status":"applied","touches":["AC-social-1"]}' > "$CV/changes/c1/change.json"
printf -- '- covers AC-social-10 only\n' > "$CV/changes/c1/tasks.md"
nocheck "a task for AC-social-10 does not cover AC-social-1" "$SC" coverage "$CV"
printf -- '- covers AC-social-1 and AC-social-10\n' > "$CV/changes/c1/tasks.md"
check "tasks that name the AC cover it" "$SC" coverage "$CV"

echo "usage"
eq "no verb (rc 2)" "$(rc "$SC")" 2
eq "unknown verb (rc 2)" "$(rc "$SC" nope)" 2
eq "compute without --base (rc 2)" "$(rc "$SC" compute "$T/fix-timeout")" 2
finish spec-change
