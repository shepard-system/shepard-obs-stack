#!/usr/bin/env bash
# tests/test-config-validate.sh — validate YAML and JSON config files
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0 FAIL=0

pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "    $2"; }

# --- JSON validation (jq required) ---
echo "JSON validation"

if ! command -v jq &>/dev/null; then
  echo "  ✗ jq not found — cannot validate JSON"
  exit 1
fi

while IFS= read -r -d '' f; do
  rel="${f#"$REPO_ROOT"/}"
  if jq empty "$f" 2>/dev/null; then
    pass "$rel"
  else
    fail "$rel" "$(jq empty "$f" 2>&1 | head -1)"
  fi
done < <(find "$REPO_ROOT/configs" -name '*.json' -print0 2>/dev/null)

# --- YAML validation ---
echo ""
echo "YAML validation"

validate_yaml() {
  local f="$1"
  if command -v python3 &>/dev/null; then
    python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$f" 2>&1
  elif command -v yq &>/dev/null; then
    yq eval '.' "$f" >/dev/null 2>&1
  else
    echo "SKIP"
    return 0
  fi
}

yaml_validator="none"
if command -v python3 &>/dev/null && python3 -c "import yaml" 2>/dev/null; then
  yaml_validator="python3"
elif command -v yq &>/dev/null; then
  yaml_validator="yq"
fi

if [[ "$yaml_validator" == "none" ]]; then
  echo "  ~ no YAML validator found (install PyYAML or yq) — skipped"
else
  while IFS= read -r -d '' f; do
    rel="${f#"$REPO_ROOT"/}"
    err=$(validate_yaml "$f" 2>&1)
    if [[ $? -eq 0 && "$err" != "SKIP" ]]; then
      pass "$rel"
    else
      fail "$rel" "$err"
    fi
  done < <(find "$REPO_ROOT/configs" \( -name '*.yaml' -o -name '*.yml' \) -print0 | sort -z)
fi

echo ""
echo "Config validation: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
