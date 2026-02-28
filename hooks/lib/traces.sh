#!/usr/bin/env bash
# hooks/lib/traces.sh — emit OTLP trace spans to OTel Collector
#
# Usage: source this file, then call emit_spans
#
# Dependencies: curl, jq
# Sends ExportTraceServiceRequest JSON to localhost:4318/v1/traces.
# All spans in a single request share the same resource (service.name).
#
# Input: newline-delimited JSON spans from session-parser.sh:
#   { "trace_id", "span_id", "parent_span_id", "name", "start_ns", "end_ns",
#     "status": 0|2, "attributes": {...} }
# Status codes: 0 = STATUS_CODE_UNSET/OK, 2 = STATUS_CODE_ERROR

OTEL_HTTP_URL="${OTEL_HTTP_URL:-http://localhost:4318}"

# emit_spans "service_name" < spans.jsonl
# Reads span JSON lines from stdin, batches into one OTLP request.
emit_spans() {
  local service_name="${1:-claude-code-session}"

  # Read all spans from stdin into a jq-compatible array
  local spans_json
  spans_json=$(jq -sc '.' 2>/dev/null)

  # Empty input — nothing to emit
  [[ "$spans_json" == "[]" || -z "$spans_json" ]] && return 0

  # Build OTLP ExportTraceServiceRequest
  local payload
  payload=$(jq -c \
    --arg svc "$service_name" \
    '
    # Convert each span to OTLP format
    [.[] | {
      traceId: .trace_id,
      spanId: .span_id,
      parentSpanId: .parent_span_id,
      name: .name,
      kind: 1,
      startTimeUnixNano: .start_ns,
      endTimeUnixNano: .end_ns,
      attributes: [
        .attributes | to_entries[] |
        {
          key: .key,
          value: (
            if (.value | test("^[0-9]+$")) then
              { intValue: .value }
            else
              { stringValue: .value }
            end
          )
        }
      ],
      status: { code: (.status // 0) }
    }] |
    {
      resourceSpans: [{
        resource: {
          attributes: [{
            key: "service.name",
            value: { stringValue: $svc }
          }]
        },
        scopeSpans: [{
          scope: { name: "shepherd-session-parser", version: "0.1.0" },
          spans: .
        }]
      }]
    }
    ' <<< "$spans_json" 2>/dev/null)

  [[ -z "$payload" ]] && return 1

  # Fire-and-forget
  curl -s -o /dev/null -w "" \
    -H "Content-Type: application/json" \
    -XPOST "${OTEL_HTTP_URL}/v1/traces" \
    -d "$payload" &
  disown
}
