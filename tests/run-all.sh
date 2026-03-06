#!/usr/bin/env bash
# tests/run-all.sh — test suite orchestrator
#
# Runs all unit tests (shell syntax, config validation, hooks, parsers).
# Use --e2e to also run Docker-based E2E smoke test (scripts/test-signal.sh).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

E2E=false
[[ "${1:-}" == "--e2e" ]] && E2E=true

green()  { printf '\033[32m%s\033[0m\n' "$1"; }
red()    { printf '\033[31m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }

SUITE_PASS=0 SUITE_FAIL=0

run_suite() {
  local name="$1" script="$2"
  echo ""
  echo "═══════════════════════════════════════════"
  echo " $name"
  echo "═══════════════════════════════════════════"
  if bash "$script"; then
    SUITE_PASS=$((SUITE_PASS+1))
    green "  → $name: PASSED"
  else
    SUITE_FAIL=$((SUITE_FAIL+1))
    red "  → $name: FAILED"
  fi
}

run_suite "Shell Syntax"        "$SCRIPT_DIR/test-shell-syntax.sh"
run_suite "Config Validation"   "$SCRIPT_DIR/test-config-validate.sh"
run_suite "Hook Behavior"       "$SCRIPT_DIR/test-hooks.sh"
run_suite "Session Parsers"     "$SCRIPT_DIR/test-parsers.sh"

if [[ "$E2E" == "true" ]]; then
  echo ""
  echo "═══════════════════════════════════════════"
  echo " E2E Smoke (Docker)"
  echo "═══════════════════════════════════════════"
  if ! command -v docker &>/dev/null; then
    yellow "  ~ docker not found — skipping E2E"
  else
    cd "$REPO_ROOT"
    docker compose up -d --wait 2>/dev/null
    if bash "$REPO_ROOT/scripts/test-signal.sh"; then
      SUITE_PASS=$((SUITE_PASS+1))
      green "  → E2E Smoke: PASSED"
    else
      SUITE_FAIL=$((SUITE_FAIL+1))
      red "  → E2E Smoke: FAILED"
    fi
  fi
fi

echo ""
echo "═══════════════════════════════════════════"
TOTAL=$((SUITE_PASS + SUITE_FAIL))
if [[ $SUITE_FAIL -eq 0 ]]; then
  green "All $TOTAL test suites passed."
else
  red "$SUITE_FAIL of $TOTAL test suites failed."
fi
echo "═══════════════════════════════════════════"

[[ $SUITE_FAIL -eq 0 ]]
