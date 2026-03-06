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

# --- Prometheus rule validation (promtool, optional) ---
echo ""
echo "Prometheus rule validation"

if command -v promtool &>/dev/null; then
  for f in "$REPO_ROOT"/configs/prometheus/alerts/*.yaml; do
    rel="${f#"$REPO_ROOT"/}"
    if promtool check rules "$f" >/dev/null 2>&1; then
      pass "$rel"
    else
      fail "$rel" "$(promtool check rules "$f" 2>&1 | head -1)"
    fi
  done
  # Validate prometheus.yaml (uses env vars, check syntax only)
  prom_cfg="$REPO_ROOT/configs/prometheus/prometheus.yaml"
  rel="${prom_cfg#"$REPO_ROOT"/}"
  # promtool check config doesn't expand env vars, so skip it — rules are the main value
else
  echo "  ~ promtool not found — skipped (install prometheus for full validation)"
fi

# --- Alert expression regression tests ---
echo ""
echo "Alert expression regression"

assert_alert_expr() {
  local file="$1" alert="$2" expected_pattern="$3"
  local rel="${file#"$REPO_ROOT"/}"
  local expr
  # Extract the expr line immediately following the alert declaration
  expr=$(grep -A5 "alert: ${alert}$" "$file" | grep 'expr:' | head -1)
  if echo "$expr" | grep -q "$expected_pattern"; then
    pass "$alert expr contains $expected_pattern ($rel)"
  else
    fail "$alert expr missing $expected_pattern ($rel)" "got: $expr"
  fi
}

assert_alert_count() {
  local file="$1" expected="$2"
  local rel="${file#"$REPO_ROOT"/}"
  local count
  count=$(grep -c '^\s*- alert:' "$file" || true)
  if [[ "$count" -eq "$expected" ]]; then
    pass "$rel has $expected alert rules"
  else
    fail "$rel expected $expected rules, got $count"
  fi
}

ALERTS_DIR="$REPO_ROOT/configs/prometheus/alerts"

# Rule counts per file
assert_alert_count "$ALERTS_DIR/infra.yaml" 6
assert_alert_count "$ALERTS_DIR/pipeline.yaml" 5
assert_alert_count "$ALERTS_DIR/services.yaml" 5

# Key expressions that must not drift
assert_alert_expr "$ALERTS_DIR/pipeline.yaml" "LokiDown" 'job="loki"'
assert_alert_expr "$ALERTS_DIR/pipeline.yaml" "ShepherdServicesDown" 'job="shepherd-services"'
assert_alert_expr "$ALERTS_DIR/infra.yaml" "OTelCollectorDown" 'job="otel-collector"'

echo ""
echo "Config validation: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
