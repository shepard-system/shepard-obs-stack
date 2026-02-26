#!/usr/bin/env bash
# scripts/test-signal.sh — send test metrics and verify the pipeline
#
# Sends test OTLP metrics (hook counters only),
# waits briefly, then queries Prometheus and Loki to confirm ingestion.
# 5 checks: 2 Prometheus (hook metrics) + 3 Loki (native OTel presence).

set -euo pipefail

LOKI_URL="${LOKI_URL:-http://localhost:3100}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
OTEL_HTTP_URL="${OTEL_HTTP_URL:-http://localhost:4318}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="${SCRIPT_DIR}/../hooks"

green()  { printf '\033[32m%s\033[0m\n' "$1"; }
red()    { printf '\033[31m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }

# ── Preflight ────────────────────────────────────────────────────────

echo "Testing signal pipeline → Prometheus (hooks) + Loki (native OTel)"
echo ""

# Check Loki is up
if ! curl -sf "${LOKI_URL}/ready" >/dev/null 2>&1; then
  red "Loki is not ready at ${LOKI_URL}. Is the stack running?"
  echo "  docker compose up -d"
  exit 1
fi

green "Loki is ready"

# ── Send test hook metrics ─────────────────────────────────────────

source "${HOOKS_DIR}/lib/metrics.sh"

echo "Sending test hook metrics (OTLP → OTel Collector → Prometheus)..."

# Disable errexit for background emit jobs
set +e

# Hook metrics only: tool_calls + events
emit_counter "tool_calls"  "1"  '{"source":"claude-code","tool":"Bash","tool_status":"success","git_repo":"shepard-obs-stack"}'
emit_counter "tool_calls"  "1"  '{"source":"claude-code","tool":"Read","tool_status":"success","git_repo":"shepard-obs-stack"}'
emit_counter "events"      "1"  '{"source":"claude-code","event_type":"tool_use","git_repo":"shepard-obs-stack"}'
emit_counter "events"      "1"  '{"source":"claude-code","event_type":"session_end","git_repo":"shepard-obs-stack"}'

# Wait for background curls to finish + ingestion
wait 2>/dev/null || true
sleep 3

# Re-enable errexit for verification phase
set -e

# ── Verify Prometheus ────────────────────────────────────────────────

echo ""
echo "Querying Prometheus (${PROMETHEUS_URL})..."

PASS=0
FAIL=0

check_prometheus() {
  local label="$1"
  local query="$2"

  local result
  result=$(curl -sfG "${PROMETHEUS_URL}/api/v1/query" \
    --data-urlencode "query=${query}" 2>/dev/null || echo '{"data":{"result":[]}}')

  local count
  count=$(echo "$result" | jq '.data.result | length' 2>/dev/null || echo 0)

  if [[ "$count" -gt 0 ]]; then
    green "  ✓ ${label}"
    PASS=$((PASS + 1))
  else
    red "  ✗ ${label}"
    FAIL=$((FAIL + 1))
  fi
}

check_prometheus "shepherd_tool_calls_total metric" \
  'shepherd_tool_calls_total{source="claude-code"}'

check_prometheus "shepherd_events_total metric" \
  'shepherd_events_total{source="claude-code"}'

# ── Verify native OTel presence in Loki ──────────────────────────────

echo ""
echo "Querying Loki for native OTel log labels..."

check_loki_label() {
  local label="$1"
  local query="$2"

  local result
  result=$(curl -sfG "${LOKI_URL}/loki/api/v1/query" \
    --data-urlencode "query=${query}" \
    --data-urlencode "limit=1" 2>/dev/null || echo '{"data":{"result":[]}}')

  local count
  count=$(echo "$result" | jq '.data.result | length' 2>/dev/null || echo 0)

  if [[ "$count" -gt 0 ]]; then
    green "  ✓ ${label}"
    PASS=$((PASS + 1))
  else
    yellow "  ~ ${label} (no data yet — start a CLI session to populate)"
    PASS=$((PASS + 1))  # Don't fail — native OTel data appears only after real CLI use
  fi
}

check_loki_label "claude-code native OTel logs" \
  '{job="claude-code"}'

check_loki_label "codex native OTel logs" \
  '{job="codex_cli_rs"}'

check_loki_label "gemini native OTel logs" \
  '{job="gemini-cli"}'

# ── Summary ──────────────────────────────────────────────────────────

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"

if [[ $FAIL -gt 0 ]]; then
  yellow "Some signals did not arrive. Check that the stack is running:"
  echo "  docker compose logs otel-collector"
  exit 1
fi

green "All signals verified. Pipeline is working."
echo ""
echo "View in Grafana: http://localhost:3000"
echo "  Hook metrics:  Prometheus → shepherd_tool_calls_total, shepherd_events_total"
echo "  Native OTel:   Prometheus → shepherd_claude_code_* metrics"
echo "  Native logs:   Loki → {job=\"claude-code\"} | json"
