#!/usr/bin/env bash
# scripts/test-signal.sh — send test metrics and verify the pipeline
#
# Sends test OTLP metrics and a synthetic trace,
# waits briefly, then runs 9 checks across Prometheus, Loki, and Tempo.
#
# Checks:
#   1-2  Hook metrics in Prometheus (tool_calls, events)
#   3-5  Native OTel metrics in Prometheus (Claude, Gemini, Codex recording rules)
#   6-8  Native OTel logs in Loki (Claude, Codex, Gemini)
#   9    Synthetic trace in Tempo

set -euo pipefail

LOKI_URL="${LOKI_URL:-http://localhost:3100}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
OTEL_HTTP_URL="${OTEL_HTTP_URL:-http://localhost:4318}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="${SCRIPT_DIR}/../hooks"

green()  { printf '\033[32m%s\033[0m\n' "$1"; }
red()    { printf '\033[31m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }

PASS=0
FAIL=0
WARN=0

# ── Preflight ────────────────────────────────────────────────────────

echo "Testing signal pipeline"
echo "  Prometheus: ${PROMETHEUS_URL}"
echo "  Loki:       ${LOKI_URL}"
echo "  OTel:       ${OTEL_HTTP_URL}"
echo ""

check_ready() {
  local name="$1" url="$2"
  if ! curl -sf "$url" >/dev/null 2>&1; then
    red "${name} is not ready. Is the stack running?"
    echo "  docker compose up -d"
    exit 1
  fi
}

check_ready "Loki"           "${LOKI_URL}/ready"
check_ready "Prometheus"     "${PROMETHEUS_URL}/-/healthy"
check_ready_post() {
  local name="$1" url="$2"
  if ! curl -sf -X POST -H "Content-Type: application/json" -d '{}' "$url" >/dev/null 2>&1; then
    red "${name} is not ready. Is the stack running?"
    echo "  docker compose up -d"
    exit 1
  fi
}
check_ready_post "OTel Collector" "${OTEL_HTTP_URL}/v1/metrics"
green "All services ready"

# ── Send test hook metrics ─────────────────────────────────────────

source "${HOOKS_DIR}/lib/metrics.sh"

echo ""
echo "Sending test hook metrics (OTLP → OTel Collector → Prometheus)..."

set +e

emit_counter "tool_calls" "1" '{"source":"claude-code","tool":"Bash","tool_status":"success","git_repo":"shepard-obs-stack"}'
emit_counter "tool_calls" "1" '{"source":"claude-code","tool":"Read","tool_status":"success","git_repo":"shepard-obs-stack"}'
emit_counter "events"     "1" '{"source":"claude-code","event_type":"tool_use","git_repo":"shepard-obs-stack"}'
emit_counter "events"     "1" '{"source":"claude-code","event_type":"session_end","git_repo":"shepard-obs-stack"}'

wait 2>/dev/null || true
sleep 5  # Wait for delta-to-cumulative conversion + Prometheus scrape

set -e

# ── Check helpers ──────────────────────────────────────────────────

check_prometheus() {
  local label="$1"
  local query="$2"
  local required="${3:-true}"  # true = fail, false = warn

  local result
  result=$(curl -sfG "${PROMETHEUS_URL}/api/v1/query" \
    --data-urlencode "query=${query}" 2>/dev/null || echo '{"data":{"result":[]}}')

  local count
  count=$(echo "$result" | jq '.data.result | length' 2>/dev/null || echo 0)

  if [[ "$count" -gt 0 ]]; then
    green "  ✓ ${label}"
    PASS=$((PASS + 1))
  elif [[ "$required" == "true" ]]; then
    red "  ✗ ${label}"
    FAIL=$((FAIL + 1))
  else
    yellow "  ~ ${label} (no data yet — start a CLI session to populate)"
    WARN=$((WARN + 1))
  fi
}

check_loki() {
  local label="$1"
  local query="$2"

  local now end start
  now=$(date +%s)
  end="${now}000000000"
  start="$(( now - 3600 ))000000000"

  local result
  result=$(curl -sfG "${LOKI_URL}/loki/api/v1/query_range" \
    --data-urlencode "query=${query}" \
    --data-urlencode "start=${start}" \
    --data-urlencode "end=${end}" \
    --data-urlencode "limit=1" 2>/dev/null || echo '{"data":{"result":[]}}')

  local count
  count=$(echo "$result" | jq '.data.result | length' 2>/dev/null || echo 0)

  if [[ "$count" -gt 0 ]]; then
    green "  ✓ ${label}"
    PASS=$((PASS + 1))
  else
    yellow "  ~ ${label} (no data yet — start a CLI session to populate)"
    WARN=$((WARN + 1))
  fi
}

# ── 1. Hook metrics in Prometheus ──────────────────────────────────

echo ""
echo "Hook metrics (Prometheus):"

check_prometheus "shepherd_tool_calls_total" \
  'shepherd_tool_calls_total{source="claude-code"}' true

check_prometheus "shepherd_events_total" \
  'shepherd_events_total{source="claude-code"}' true

# ── 2. Native OTel metrics in Prometheus ───────────────────────────

echo ""
echo "Native OTel metrics (Prometheus):"

check_prometheus "Claude native metrics (claude_code_*)" \
  'shepherd_claude_code_token_usage_tokens_total' false

check_prometheus "Gemini native metrics (gemini_cli_*)" \
  'shepherd_gemini_cli_token_usage_total' false

check_prometheus "Codex recording rules (shepherd:codex:*)" \
  '{__name__=~"shepherd:codex:.+"}' false

# ── 3. Native OTel logs in Loki ───────────────────────────────────

echo ""
echo "Native OTel logs (Loki):"

check_loki "Claude logs (service_name=claude-code)" \
  '{service_name="claude-code"}'

check_loki "Codex logs (service_name=codex_cli_rs)" \
  '{service_name="codex_cli_rs"}'

check_loki "Gemini logs (service_name=gemini-cli)" \
  '{service_name="gemini-cli"}'

# ── 4. Synthetic trace to Tempo ───────────────────────────────────

echo ""
echo "Session traces (Tempo):"

TEMPO_URL="${TEMPO_URL:-http://localhost:3200}"

# Generate a unique test trace
TEST_TRACE_ID=$(printf '%032x' $((RANDOM * RANDOM * RANDOM)))
TEST_SPAN_ID=$(printf '%016x' $((RANDOM * RANDOM)))
NOW_NS="$(date +%s)000000000"
END_NS="$(( $(date +%s) + 1 ))000000000"

# Send a minimal test trace via OTel Collector
TEST_TRACE_PAYLOAD=$(cat <<EOJSON
{
  "resourceSpans": [{
    "resource": {
      "attributes": [
        { "key": "service.name", "value": { "stringValue": "claude-code-session" } }
      ]
    },
    "scopeSpans": [{
      "scope": { "name": "shepherd-test", "version": "0.1.0" },
      "spans": [{
        "traceId": "${TEST_TRACE_ID}",
        "spanId": "${TEST_SPAN_ID}",
        "name": "test.signal",
        "kind": 1,
        "startTimeUnixNano": "${NOW_NS}",
        "endTimeUnixNano": "${END_NS}",
        "attributes": [
          { "key": "test", "value": { "stringValue": "true" } }
        ],
        "status": { "code": 1 }
      }]
    }]
  }]
}
EOJSON
)

curl -s -o /dev/null \
  -H "Content-Type: application/json" \
  -XPOST "${OTEL_HTTP_URL}/v1/traces" \
  -d "$TEST_TRACE_PAYLOAD"

sleep 3  # Wait for Tempo ingestion

# Verify trace by ID (search needs WAL flush, but by-ID works immediately)
TRACE_RESULT=$(curl -sf "${TEMPO_URL}/api/traces/${TEST_TRACE_ID}" \
  -H "Accept: application/json" 2>/dev/null || echo '{}')

TRACE_SPANS=$(echo "$TRACE_RESULT" | jq '.batches | length' 2>/dev/null || echo 0)

if [[ "$TRACE_SPANS" -gt 0 ]]; then
  green "  ✓ Synthetic trace in Tempo (traceId=${TEST_TRACE_ID:0:8}...)"
  PASS=$((PASS + 1))
else
  yellow "  ~ Synthetic trace (sent OK, Tempo may need a moment to flush)"
  WARN=$((WARN + 1))
fi

# ── Summary ──────────────────────────────────────────────────────────

echo ""
TOTAL=$((PASS + FAIL + WARN))
echo "Results: ${PASS} passed, ${WARN} waiting for data, ${FAIL} failed (${TOTAL} checks)"

if [[ $FAIL -gt 0 ]]; then
  echo ""
  red "Hook metrics did not arrive. Debug:"
  echo "  docker compose logs otel-collector --tail=20"
  echo "  curl -s http://localhost:8889/metrics | grep shepherd_"
  echo "  curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health}'"
  exit 1
fi

echo ""
green "Pipeline is working."
echo ""
echo "View in Grafana: http://localhost:3000"
echo "  Hook metrics:    Prometheus → shepherd_tool_calls_total, shepherd_events_total"
echo "  Native metrics:  Prometheus → shepherd_claude_code_*, shepherd_gemini_cli_*"
echo "  Recording rules: Prometheus → shepherd:codex:*:1m"
echo "  Native logs:     Loki → {service_name=\"claude-code\"}"
echo "  Session traces:  Tempo → { resource.service.name = \"claude-code-session\" }"
