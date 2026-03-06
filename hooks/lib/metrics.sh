#!/usr/bin/env bash
# hooks/lib/metrics.sh — emit OTLP Sum metrics to OTel Collector
#
# Usage: source this file, then call emit_counter
#
# Dependencies: curl, jq
# Pushes OTLP Sum metrics (DELTA temporality) via HTTP JSON to localhost:4318.
# OTel Collector's deltatocumulative processor converts them to cumulative
# counters for Prometheus (with shepherd_ prefix).

OTEL_HTTP_URL="${OTEL_HTTP_URL:-http://localhost:4318}"

# emit_counter "metric_name" numeric_value '{"source":"claude-code","model":"opus"}'
emit_counter() {
  local name="$1"
  local value="$2"
  local labels_json="${3:-}"
  [[ -z "$labels_json" ]] && labels_json="{}"

  # Rust accelerator: delegate to shepard-hook if available
  source "${BASH_SOURCE[0]%/*}/accelerator.sh"
  if [[ -n "$SHEPARD_HOOK" ]]; then
    "$SHEPARD_HOOK" emit-metric "$name" "$value" "$labels_json" &
    disown
    return
  fi

  local now_ns
  now_ns="$(date +%s)000000000"

  # Build attributes array from labels JSON
  local attrs
  attrs=$(jq -c '[to_entries[] | {key: .key, value: {stringValue: (.value | tostring)}}]' <<< "$labels_json" 2>/dev/null)
  [[ -z "$attrs" ]] && attrs="[]"

  local payload
  payload=$(jq -n -c \
    --arg name "$name" \
    --argjson value "$value" \
    --arg ts "$now_ns" \
    --argjson attrs "$attrs" \
    '{
      resourceMetrics: [{
        resource: {
          attributes: [{
            key: "service.name",
            value: { stringValue: "shepherd-hooks" }
          }]
        },
        scopeMetrics: [{
          scope: { name: "shepherd-hooks" },
          metrics: [{
            name: $name,
            sum: {
              dataPoints: [{
                asDouble: $value,
                timeUnixNano: $ts,
                attributes: $attrs
              }],
              aggregationTemporality: 1,
              isMonotonic: true
            }
          }]
        }]
      }]
    }')

  # Fire-and-forget — don't block the CLI (max 5s to prevent zombie curls)
  curl -s --max-time 5 -o /dev/null -w "" \
    -H "Content-Type: application/json" \
    -XPOST "${OTEL_HTTP_URL}/v1/metrics" \
    -d "$payload" &
  disown
}
