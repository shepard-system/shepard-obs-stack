---
name: obs-sessions
description: Show recent AI coding sessions with details. Use this skill whenever the user asks about their recent sessions, wants to see session history, asks "what did I do today/yesterday", wants to know which models were used, how many tools were called per session, or asks about session duration and traces. Also use when the user wants to find a specific session or compare sessions across providers.
disable-model-invocation: false
---

# Obs Sessions

## Live Data

### Claude Sessions (recent, from Tempo span-metrics)
!`./scripts/obs-api.sh prom '/api/v1/query' --data-urlencode 'query=sort_desc(sum by (session_id, model) (traces_spanmetrics_calls_total{span_name="claude.session"}))' 2>&1 | jq -r '.data.result[:20] | .[] | "\(.metric.session_id)\t\(.metric.model)\t\(.value[1])"' 2>/dev/null || echo "No Claude sessions in span-metrics"`

### Gemini Sessions (recent)
!`./scripts/obs-api.sh prom '/api/v1/query' --data-urlencode 'query=sort_desc(sum by (session_id, model) (traces_spanmetrics_calls_total{span_name="gemini.session"}))' 2>&1 | jq -r '.data.result[:20] | .[] | "\(.metric.session_id)\t\(.metric.model)\t\(.value[1])"' 2>/dev/null || echo "No Gemini sessions"`

### Codex Sessions (recent)
!`./scripts/obs-api.sh prom '/api/v1/query' --data-urlencode 'query=sort_desc(sum by (session_id, model) (traces_spanmetrics_calls_total{span_name="codex.session"}))' 2>&1 | jq -r '.data.result[:20] | .[] | "\(.metric.session_id)\t\(.metric.model)\t\(.value[1])"' 2>/dev/null || echo "No Codex sessions"`

### Session Details (Tempo traces — last 10 Claude sessions)
!`./scripts/obs-api.sh tempo '/api/search?q=%7Bspan%3Aname%3D%22claude.session%22%7D&limit=10' 2>&1 | jq -r '.traces[:10][] | "\(.traceID)\t\(.rootServiceName)\t\(.durationMs)ms\t\(.startTimeUnixNano | tonumber / 1e9 | todate)"' 2>/dev/null || echo "No traces in Tempo"`

### Tool Count per Session (top 10 sessions by tools)
!`./scripts/obs-api.sh prom '/api/v1/query' --data-urlencode 'query=topk(10, sum by (session_id) (traces_spanmetrics_calls_total{span_name=~"claude.tool.*"}))' 2>&1 | jq -r '.data.result[] | "\(.metric.session_id)\ttools: \(.value[1])"' 2>/dev/null || echo "No tool span-metrics"`

### Claude Cost per Session (native OTel)
!`./scripts/obs-api.sh prom '/api/v1/query' --data-urlencode 'query=sort_desc(max by (session_id) (shepherd_claude_code_cost_usage_USD_total))' 2>&1 | jq -r '.data.result[:10] | .[] | "\(.metric.session_id)\t$\(.value[1])"' 2>/dev/null || echo "No per-session cost data"`

## Instructions

1. Combine the data above into a session table:
   - Columns: Provider | Session (short ID) | Model | Duration | Tools | Cost
   - Sort by most recent first
   - Truncate session IDs to first 8 chars for readability
2. Highlight sessions with high cost (>$1), many tools (>50), or errors.
3. If Tempo has trace data, mention that the user can view full traces in Grafana Session Timeline dashboard.
4. If no sessions found: "No sessions recorded. Use a CLI with hooks installed, then check `/obs-status`."
5. Maximum 20 sessions in the table.
