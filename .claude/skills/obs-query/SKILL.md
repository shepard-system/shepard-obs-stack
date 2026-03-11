---
name: obs-query
description: Execute PromQL or LogQL queries against Prometheus and Loki. Use this skill whenever the user wants to run a custom query, check a specific metric value, search logs, asks "what is the value of metric X", wants to explore data in Prometheus or Loki, or pastes a PromQL/LogQL expression. Also use when the user asks to query traces, check recording rules output, or debug metric values that don't match dashboard expectations.
disable-model-invocation: false
---

# Obs Query

Execute a PromQL (Prometheus) or LogQL (Loki) query and interpret results.

## How to detect query type

- **LogQL**: starts with `{` (stream selector) — route to Loki
- **PromQL**: everything else — route to Prometheus

## How to execute

Use `scripts/obs-api.sh` with `--jq` and `--raw` to query and format results in a single command (no pipes needed):

**PromQL instant query:**
```bash
./scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[] | "\(.metric) \(.value[1])"' --data-urlencode "query=<EXPR>"
```

**PromQL range query** (for time series):
```bash
./scripts/obs-api.sh prom /api/v1/query_range --raw --jq '.data.result[] | "\(.metric) \(.values | length) points"' --data-urlencode "query=<EXPR>" --data-urlencode "start=$(date -v-1H +%s)" --data-urlencode "end=$(date +%s)" --data-urlencode "step=60"
```

**LogQL query:**
```bash
./scripts/obs-api.sh loki /loki/api/v1/query_range --raw --jq '.data.result[].values[][] ' --data-urlencode "query=<EXPR>" --data-urlencode "limit=20"
```

## Query Examples (for reference)

### PromQL
- `up` — all scrape targets
- `shepherd_tool_calls_total` — raw tool call counters
- `sum(increase(shepherd_tool_calls_total[1h]))` — total tool calls in last hour
- `topk(5, sum by (tool) (increase(shepherd_tool_calls_total[24h])))` — top 5 tools
- `shepherd_claude_code_cost_usage_USD_total` — Claude cost per session
- `rate(shepherd_events_total[5m])` — event rate
- `traces_spanmetrics_calls_total{span_name="claude.session"}` — session trace counts

### LogQL
- `{service_name="claude-code"}` — Claude logs
- `{service_name="codex_cli_rs"}` — Codex logs
- `{service_name="gemini-cli"}` — Gemini logs
- `{service_name="claude-code"} | json | line_format "{{.body}}"` — parsed Claude log bodies
- `count_over_time({service_name="claude-code"}[1h])` — log count in last hour

## Instructions

1. Take the user's query from the skill argument (everything after `/obs-query`).
2. If no query provided, show the examples above and ask what they'd like to query.
3. Detect query type (LogQL vs PromQL).
4. Execute using `./scripts/obs-api.sh` with appropriate `--jq` filter.
5. Parse the JSON response and format results:
   - For instant vectors: table of metric labels + value
   - For range vectors: note the time range and summarize
   - For log streams: show log lines with timestamps
6. If the query fails, show the error and suggest fixes (common issues: missing quotes, wrong metric name).
7. **Safety**: Only execute read-only GET queries. Never POST, PUT, DELETE, or call admin endpoints.
