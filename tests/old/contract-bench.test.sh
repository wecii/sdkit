#!/usr/bin/env bash
# F02 benchmark tests: the contract fixtures and the F01 scenarios, simulated (nothing here starts a live host CLI). Every run is a whole workflow
# (14-40 s each), so the runs go in parallel; the checks read their results afterwards. Run: tests/slow/contract-bench.test.sh
set -u
KIT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', wanted '$3')"; fi; }

echo "contract benchmarks (simulated)"
BN="$KIT/bench/run.sh"
eq "a real contracted run is refused (not decided yet)" "$("$BN" run low-single-file --real --contracts --host claude --yes >/dev/null 2>&1; echo $?)" 2
eq "five contract fixtures"                            "$("$BN" list contracts | wc -l | tr -d ' ')" 5
eq "the F01 list is unchanged"                         "$("$BN" list | wc -l | tr -d ' ')" 4
CS="contract-valid-single contract-invalid-handoff contract-multi-chain contract-interrupted contract-verifier-evidence"
# all simulated runs at once: the contract fixtures twice (reproducibility), the four F01 scenarios once
for s in $CS; do "$BN" run "$s" --out "$T/bc1" >/dev/null 2>&1 & "$BN" run "$s" --out "$T/bc2" >/dev/null 2>&1 & done
for s in low-single-file medium-multi-file high-independent-verify multi-agent-handoff; do "$BN" run "$s" --out "$T/f1/$s" >/dev/null 2>&1 & done
wait
for s in $CS; do
  eq "$s: reproducible"                                "$(jq -S -c .deterministic "$T/bc1/$s.simulated.json" 2>/dev/null | shasum | cut -c1-12)" "$(jq -S -c .deterministic "$T/bc2/$s.simulated.json" 2>/dev/null | shasum | cut -c1-12)"
  eq "$s: reaches done"                                "$(jq -r .summary.status "$T/bc1/$s.simulated.json" 2>/dev/null)" completed
done
eq "valid single: one handoff, one result, no failure" "$(jq -r '"\(.summary.contracts.handoffs) \(.summary.contracts.results) \(.summary.contracts.invalid)"' "$T/bc1/contract-valid-single.simulated.json")" "1 1 0"
eq "invalid handoff: detected, retried once, recovered" "$(jq -r '"\(.summary.contracts.by_reason | keys | join(",")) retries=\(.summary.retries)"' "$T/bc1/contract-invalid-handoff.simulated.json")" "malformed,missing-field retries=1"
eq "multi-agent chain: every agent contracted"         "$(jq -r '"\(.summary.contracts.handoffs) \(.summary.contracts.results)"' "$T/bc1/contract-multi-chain.simulated.json")" "7 7"
eq "interrupted: the failure is a host-error and a no-result" "$(jq -r '"\(.summary.failures.by_category["host-error"]) \(.summary.contracts.by_reason["no-result"])"' "$T/bc1/contract-interrupted.simulated.json")" "1 1"
eq "verifier fixture: verdict recorded separately"     "$(jq -r '.summary.verification.final' "$T/bc1/contract-verifier-evidence.simulated.json")" PASS
for s in low-single-file medium-multi-file high-independent-verify multi-agent-handoff; do
  eq "F01 $s: no contract event without a contract"    "$(jq -r '.summary.contracts.checked' "$T/f1/$s/$s.simulated.json")" 0
done

echo
echo "contract benchmarks: $pass passed, $fail failed"
[ "$fail" = 0 ]
