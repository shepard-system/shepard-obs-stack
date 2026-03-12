# PromQL & LogQL Examples

Quick reference for querying the obs stack.

## PromQL (Prometheus)

### Basics
- `up` — all scrape targets with health status
- `shepherd_tool_calls_total` — raw tool call counters
- `shepherd_events_total` — raw event counters

### Hook Metrics (aggregated across sessions)
- `sum(increase(shepherd_tool_calls_total[1h]))` — total tool calls in last hour
- `topk(5, sum by (tool) (increase(shepherd_tool_calls_total[24h])))` — top 5 tools
- `sum by (source) (increase(shepherd_events_total[1h]))` — events by provider
- `sum(increase(shepherd_sensitive_file_access_total[24h]))` — sensitive access count

### Native OTel — Claude
- `shepherd_claude_code_cost_usage_USD_total` — cost per session (has `session_id`, `model` labels)
- `shepherd_claude_code_token_usage_tokens_total` — tokens per session (`type`: input/output/cacheRead/cacheCreation)
- `count(max_over_time(shepherd_claude_code_session_count_total[24h]))` — count distinct sessions

### Native OTel — Gemini
- `shepherd_gemini_cli_token_usage_total` — tokens (`type`: input/output/thought/cache/tool)
- `shepherd_gemini_cli_tool_call_count_total` — tool calls by `function_name`
- `shepherd_gemini_cli_api_request_count_total` — API requests by `status_code`

### Recording Rules — Codex
- `shepherd:codex:sessions:1m` — session count (1m buckets, use `sum_over_time`)
- `shepherd:codex:tokens_input:1m` / `shepherd:codex:tokens_output:1m` — tokens
- `shepherd:codex:tool_calls_by_tool:1m` — tool calls by `tool_name`

### Span Metrics (from Tempo)
- `traces_spanmetrics_calls_total{span_name="claude.session"}` — session trace counts
- `traces_spanmetrics_calls_total{span_name=~"claude.tool.*"}` — tool call traces
- `traces_spanmetrics_latency_bucket{span_name=~"*.tool.*"}` — tool duration histogram

## LogQL (Loki)

### Stream Selectors
- `{service_name="claude-code"}` — Claude Code logs
- `{service_name="codex_cli_rs"}` — Codex CLI logs
- `{service_name="gemini-cli"}` — Gemini CLI logs

### Filtering & Parsing
- `{service_name="claude-code"} | json` — parse JSON log body
- `{service_name="claude-code"} | json | line_format "{{.body}}"` — show just the body
- `{service_name="claude-code"} |= "error"` — filter for errors
- `{service_name="claude-code"} | json | body_event_type="claude_code.tool_result"` — filter by event type

### Aggregations
- `count_over_time({service_name="claude-code"}[1h])` — log count in last hour
- `rate({service_name="claude-code"}[5m])` — log rate
- `sum by (service_name) (count_over_time({service_name=~".+"}[1h]))` — logs per service

## Key Gotchas

- Native OTel metrics have per-session `session_id` label — use `max_over_time()` not `increase()` for totals
- `increase()` returns floats — wrap in `round()` for integer counters
- Codex recording rules: label is `tool_name` (not `tool`)
- Empty model label: filter with `model!=""` when grouping
