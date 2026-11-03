#!/usr/bin/env bash
# F11: the zero-cost baseline is deterministic, honest about what it does not measure, and compare refuses incomparable inputs.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; CB="$ROOT/bench/costbase.sh"; T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; failed=0
eq() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ok   $1"; else failed=$((failed + 1)); echo "  FAIL $1 (got '$2', wanted '$3')"; fi; }
"$CB" capture a --out "$T" >/dev/null 2>&1
A="$T/a.costbase.json"; B="$T/b.costbase.json"; jq '.label="b"' "$A" > "$B"
eq "no model is called"                        "$(jq .model_calls "$A")" 0
eq "cost per accepted task is NOT MEASURED"    "$(jq -r .cost_per_accepted_task "$A" | cut -c1-12)" "NOT MEASURED"
eq "normalisation fixes every format-only rerun" "$(jq .verdict_format.avoidable_reruns_with "$A")" 0
eq "the pre-F08 arm had avoidable reruns"      "$([ "$(jq .verdict_format.avoidable_reruns_without "$A")" -gt 0 ] && echo yes)" yes
eq "no semantic case is ever accepted"         "$(jq '.verdict_format | .wrongly_accepted_with + .wrongly_accepted_without' "$A")" 0
eq "both failure lines survive the bounded view" "$(jq .context.tool_output.failure_lines_kept_of_2 "$A")" 2
eq "compare works on the same fixture set"     "$("$CB" compare "$A" "$B" >/dev/null 2>&1; echo $?)" 0
jq '.fixture_sha="other"' "$B" > "$T/c.json"
eq "compare refuses a different fixture set"   "$("$CB" compare "$A" "$T/c.json" >/dev/null 2>&1; echo $?)" 3
echo "costbase: $pass passed, $failed failed"; [ "$failed" = 0 ]
