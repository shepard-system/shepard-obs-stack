#!/usr/bin/env bash
# tests/test-shell-syntax.sh — bash -n syntax check + optional shellcheck lint
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0 FAIL=0

pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "    $2"; }

echo "Shell syntax (bash -n)"

while IFS= read -r -d '' f; do
  rel="${f#"$REPO_ROOT"/}"
  if bash -n "$f" 2>/dev/null; then
    pass "$rel"
  else
    fail "$rel" "$(bash -n "$f" 2>&1)"
  fi
done < <(find "$REPO_ROOT/hooks" "$REPO_ROOT/scripts" -name '*.sh' -print0 2>/dev/null)

# Shellcheck (optional — non-fatal)
if command -v shellcheck &>/dev/null; then
  echo ""
  echo "Shellcheck lint"
  SC_WARN=0
  while IFS= read -r -d '' f; do
    rel="${f#"$REPO_ROOT"/}"
    output=$(shellcheck -S warning -e SC1091,SC2034 "$f" 2>&1 || true)
    if [[ -z "$output" ]]; then
      pass "$rel"
    else
      SC_WARN=$((SC_WARN+1))
      echo "  ~ $rel (warnings)"
      echo "$output" | head -5 | sed 's/^/    /'
    fi
  done < <(find "$REPO_ROOT/hooks" "$REPO_ROOT/scripts" -name '*.sh' -print0 2>/dev/null)
  [[ $SC_WARN -gt 0 ]] && echo "  ($SC_WARN files with shellcheck warnings — non-fatal)"
else
  echo ""
  echo "  ~ shellcheck not installed (skipped)"
fi

echo ""
echo "Shell syntax: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
