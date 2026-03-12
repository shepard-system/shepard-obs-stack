---
name: obs-tools
description: Show tool usage statistics and error rates. Use this skill whenever the user asks about which tools are used most, tool error rates, wants to see Read/Edit/Bash/Grep call counts, asks about tool failures, sensitive file access, or wants a breakdown of tool usage by provider or repository. Also trigger when the user mentions "tool stats", "what tools did I use", or asks about tool performance.
disable-model-invocation: false
---

# Obs Tools Report

Tool usage, error rates, and breakdown by provider and repo.

## Queries to run

Use `scripts/obs-api.sh`. Run independent queries in parallel.

### Top 15 tools by call count (24h)

```bash
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[] | "\(.metric.tool)\t\(.value[1])"' --data-urlencode 'query=topk(15, sort_desc(sum by (tool) (round(increase(shepherd_tool_calls_total[24h])))))'
```

### Tool calls by provider (24h)

```bash
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[] | "\(.metric.source)\t\(.value[1])"' --data-urlencode 'query=sort_desc(sum by (source) (round(increase(shepherd_tool_calls_total[24h]))))'
```

### Tool calls by repo (24h)

```bash
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[] | select(.metric.git_repo != "") | "\(.metric.git_repo)\t\(.value[1])"' --data-urlencode 'query=sort_desc(sum by (git_repo) (round(increase(shepherd_tool_calls_total[24h]))))'
```

### Error rate by tool (24h)

```bash
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[] | "\(.metric.tool)\t\(.value[1])%"' --data-urlencode 'query=sort_desc(sum by (tool) (round(increase(shepherd_tool_calls_total{tool_status="error"}[24h]))) / sum by (tool) (round(increase(shepherd_tool_calls_total[24h]))) * 100 > 0)'
```

### Totals (24h)

```bash
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[0].value[1] // "0"' --data-urlencode 'query=round(sum(increase(shepherd_tool_calls_total[24h])))'
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[0].value[1] // "0"' --data-urlencode 'query=round(sum(increase(shepherd_tool_calls_total{tool_status="error"}[24h])))'
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[0].value[1] // "0"' --data-urlencode 'query=round(sum(increase(shepherd_sensitive_file_access_total[24h])))'
```

### Gemini native tool metrics (24h)

```bash
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[] | "\(.metric.function_name)\t\(.value[1])"' --data-urlencode 'query=topk(10, sort_desc(sum by (function_name) (round(increase(shepherd_gemini_cli_tool_call_count_total[24h])))))'
```

## Output columns

| Column | Source |
|--------|--------|
| Tool | tool name |
| Calls | total invocations |
| Errors | error count |
| Error Rate | errors/calls % |

For output format options (table/csv/json), read `.claude/skills/obs-shared/assets/output-formats.md`.

## Presentation

1. **Summary line**: "847 tool calls, 3 errors (0.4%), 0 sensitive access"
2. **Top tools** table: Tool | Calls | Error Rate
3. **By provider** breakdown
4. **By repo** breakdown
5. Flag tools with error rate > 10%
6. If sensitive file access > 0, highlight as security note
7. If no data: "No tool calls recorded in the last 24h."
