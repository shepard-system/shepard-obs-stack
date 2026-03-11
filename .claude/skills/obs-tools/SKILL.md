---
name: obs-tools
description: Show tool usage statistics and error rates. Use this skill whenever the user asks about which tools are used most, tool error rates, wants to see Read/Edit/Bash/Grep call counts, asks about tool failures, sensitive file access, or wants a breakdown of tool usage by provider or repository. Also trigger when the user mentions "tool stats", "what tools did I use", or asks about tool performance.
disable-model-invocation: false
---

# Obs Tools Report

## Live Data

### Top 15 Tools by Call Count (24h)
!`./scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[] | "\(.metric.tool)\t\(.value[1])"' --data-urlencode 'query=topk(15, sort_desc(sum by (tool) (round(increase(shepherd_tool_calls_total[24h])))))' || echo "No tool data"`

### Tool Calls by Provider (24h)
!`./scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[] | "\(.metric.source)\t\(.value[1])"' --data-urlencode 'query=sort_desc(sum by (source) (round(increase(shepherd_tool_calls_total[24h]))))' || echo "No data"`

### Tool Calls by Repo (24h)
!`./scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[] | "\(.metric.git_repo)\t\(.value[1])"' --data-urlencode 'query=sort_desc(sum by (git_repo) (round(increase(shepherd_tool_calls_total{git_repo!=""}[24h]))))' || echo "No repo data"`

### Error Rate by Tool (24h, tools with errors only)
!`./scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[] | "\(.metric.tool)\t\(.value[1])%"' --data-urlencode 'query=sort_desc(sum by (tool) (round(increase(shepherd_tool_calls_total{tool_status="error"}[24h]))) / sum by (tool) (round(increase(shepherd_tool_calls_total[24h]))) * 100 > 0)' || echo "No errors — clean run"`

### Total Tool Calls vs Errors (24h)
!`./scripts/obs-api.sh prom /api/v1/query --raw --jq '"Total calls: " + (.data.result[0].value[1] // "0")' --data-urlencode 'query=round(sum(increase(shepherd_tool_calls_total[24h])))' || echo "Total calls: 0"`
!`./scripts/obs-api.sh prom /api/v1/query --raw --jq '"Total errors: " + (.data.result[0].value[1] // "0")' --data-urlencode 'query=round(sum(increase(shepherd_tool_calls_total{tool_status="error"}[24h])))' || echo "Total errors: 0"`

### Sensitive File Access (24h)
!`./scripts/obs-api.sh prom /api/v1/query --raw --jq '"Sensitive access: " + (.data.result[0].value[1] // "0")' --data-urlencode 'query=round(sum(increase(shepherd_sensitive_file_access_total[24h])))' || echo "Sensitive access: 0"`

### Gemini Tools (24h, native OTel)
!`./scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[] | "\(.metric.function_name)\t\(.value[1])"' --data-urlencode 'query=topk(10, sort_desc(sum by (function_name) (round(increase(shepherd_gemini_cli_tool_call_count_total[24h])))))' || echo "No Gemini native tool data"`

## Instructions

1. Format as a tool usage report:
   - **Summary line**: "847 tool calls, 3 errors (0.4%), 0 sensitive access"
   - **Top tools** table: Tool | Calls | Error Rate
   - **By provider** breakdown
   - **By repo** breakdown
2. Flag tools with error rate > 10% (investigate these).
3. If sensitive file access > 0, highlight it as a security note.
4. If no data: "No tool calls recorded in the last 24h."
