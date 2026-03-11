---
name: obs-cost
description: Show AI coding cost and token usage. Use this skill whenever the user asks how much they spent, wants a cost breakdown by provider or model, asks about token consumption, wants to compare Claude vs Gemini costs, or mentions anything about budget, spend, billing, or usage dollars. Supports time ranges like today, yesterday, week, 24h. Even if the user just says "how much did I spend" or "cost report" — use this skill.
disable-model-invocation: false
---

# Obs Cost Report

## Args
The user may provide a time range argument. Default: last 24h.
Mapping: `today` → `[TIME_TO_NOW]`, `yesterday` → offset query, `week` → `[7d]`, `24h`/default → `[24h]`.

## Live Data

### Claude Code Cost (24h, by model)
!`./scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[] | "\(.metric.model)\t$\(.value[1])"' --data-urlencode 'query=sort_desc(sum by (model) (max_over_time(shepherd_claude_code_cost_usage_USD_total{model!=""}[24h])))' || echo "No cost data"`

### Claude Code Cost Total (24h)
!`./scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[0].value[1] // "0"' --data-urlencode 'query=sum(max_over_time(shepherd_claude_code_cost_usage_USD_total[24h]))' || echo "0"`

### Token Usage — Claude (24h, by type)
!`./scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[] | "\(.metric.type)\t\(.value[1])"' --data-urlencode 'query=sort_desc(sum by (type) (max_over_time(shepherd_claude_code_token_usage_tokens_total{type!=""}[24h])))' || echo "No token data"`

### Token Usage — Gemini (24h, by type)
!`./scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[] | "\(.metric.type)\t\(.value[1])"' --data-urlencode 'query=sort_desc(sum by (type) (max_over_time(shepherd_gemini_cli_token_usage_total{type!=""}[24h])))' || echo "No Gemini token data"`

### Token Usage — Codex (24h)
!`./scripts/obs-api.sh prom /api/v1/query --raw --jq '"input\t" + (.data.result[0].value[1] // "0")' --data-urlencode 'query=sum(sum_over_time(shepherd:codex:tokens_input:1m[24h]))' || echo "No Codex data"`
!`./scripts/obs-api.sh prom /api/v1/query --raw --jq '"output\t" + (.data.result[0].value[1] // "0")' --data-urlencode 'query=sum(sum_over_time(shepherd:codex:tokens_output:1m[24h]))' || echo "No Codex data"`

### Sessions Count (24h)
!`./scripts/obs-api.sh prom /api/v1/query --raw --jq '"Claude: " + (.data.result[0].value[1] // "0")' --data-urlencode 'query=count(max_over_time(shepherd_claude_code_session_count_total[24h]))' || echo "Claude: 0"`
!`./scripts/obs-api.sh prom /api/v1/query --raw --jq '"Gemini: " + (.data.result[0].value[1] // "0")' --data-urlencode 'query=count(max_over_time(shepherd_gemini_cli_session_count_total[24h]))' || echo "Gemini: 0"`
!`./scripts/obs-api.sh prom /api/v1/query --raw --jq '"Codex: " + (.data.result[0].value[1] // "0")' --data-urlencode 'query=sum(sum_over_time(shepherd:codex:sessions:1m[24h]))' || echo "Codex: 0"`

## Instructions

1. If the user specified a time range, note it — but the queries above use 24h. Mention if adjustment is needed and offer to re-query.
2. Format as a cost report:
   - **Total cost** (sum across providers)
   - **Cost by model** table
   - **Token breakdown** per provider (input/output/cache)
   - **Session count** per provider
3. Calculate cost-per-session and tokens-per-dollar where meaningful.
4. If all values are 0: "No activity in the last 24h. Stack may not be receiving telemetry — try `/obs-status`."
5. Note: Gemini and Codex don't emit cost metrics natively. Only Claude has dollar amounts.
