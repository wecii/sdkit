# React Native checks (bare or Expo, TS or JS) for the shared verify engine (scripts/verify-core.sh). Sourced by verify.sh.
# Never builds native code (no prebuild, gradle, xcodebuild, pod install, metro).
STACK_SOURCE_RE='\.(tsx?|jsx?)$'

for _n in "$ENGINE_DIR/node-lib.sh" "$ENGINE_DIR/../../_node/scripts/node-lib.sh"; do [ -f "$_n" ] && { . "$_n"; break; }; done
type node_check >/dev/null 2>&1 || { echo "node-lib.sh not found next to $0 or in stacks/_node/scripts/" >&2; exit 1; }

# node_exec_found <dir> <bin>: a locally installed binary exists (node_exec runs only those)
node_exec_found() { [ -x "$1/node_modules/.bin/$2" ] || [ -x "$ROOT/node_modules/.bin/$2" ]; }

stack_run() {
  local f pkg PKGS files rel native

  # native and app-config changes cannot be verified here
  native="$(printf '%s\n' "$CHANGED" | grep -E '(^|/)(ios|android)/|(^|/)(app\.json|app\.config\.[a-z]+|Podfile|build\.gradle)$' || true)"
  [ -n "$native" ] && warn "native/config files changed (ios/android/app config): build and smoke-test on a device or simulator, verify does not"

  PKGS="$(for f in $CHANGED_SRC; do [ -f "$f" ] && node_pkg_of "$f"; done | sort -u)"
  for pkg in $PKGS; do
    step "package $pkg: typecheck"
    if [ -f "$pkg/tsconfig.json" ]; then node_check "$pkg" typecheck typecheck tsc --noEmit
    else warn "typecheck skipped in $pkg: no tsconfig.json"; fi
    [ "$FAST" = 1 ] && continue

    # changed sources of this package, absolute paths
    files=""
    for f in $CHANGED_SRC; do
      [ -f "$f" ] || continue
      [ "$(node_pkg_of "$f")" = "$pkg" ] && files="$files $ROOT/$f"
    done

    step "package $pkg: lint"
    if ! node_has_script "$pkg" lint && ! node_exec_found "$pkg" eslint && node_exec_found "$pkg" prettier; then
      # no eslint: the formatting check is the only style gate there is
      # shellcheck disable=SC2086
      node_exec "$pkg" prettier --check $files || fail "prettier --check: $pkg (run prettier --write)"
    else
      # shellcheck disable=SC2086
      node_check "$pkg" lint lint eslint $files
    fi

    step "package $pkg: test"
    if [ ! -d "$pkg/node_modules" ] && [ ! -d "$ROOT/node_modules" ]; then
      warn "tests skipped in $pkg: dependencies not installed"
    elif node_has_script "$pkg" test; then
      if jq -e '.scripts.test | test("no test specified")' "$pkg/package.json" >/dev/null 2>&1; then
        warn "no tests in $pkg (npm default test script)"
      else node_run "$pkg" test || fail "test: $pkg"; fi
    elif node_has_dep "$pkg" jest; then
      # shellcheck disable=SC2086
      node_exec "$pkg" jest --findRelatedTests $files --passWithNoTests || fail "jest: $pkg"
    else
      warn "no tests in $pkg: no 'test' script and no jest dependency"
    fi
  done
}
