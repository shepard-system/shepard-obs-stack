---
name: obs-cost
description: Show AI coding cost and token usage. Use this skill whenever the user asks how much they spent, wants a cost breakdown by provider or model, asks about token consumption, wants to compare Claude vs Gemini costs, or mentions anything about budget, spend, billing, or usage dollars. Supports time ranges like today, yesterday, week, 24h. Even if the user just says "how much did I spend" or "cost report" — use this skill.
disable-model-invocation: false
---

# Obs Cost Report

Cost and token usage breakdown by provider and model.

## Arguments

User may specify a time range. Default: `24h`.
Mapping: `today` → `24h`, `yesterday` → offset query, `week` → `7d`.
Replace `[24h]` in queries below with the appropriate range.

## Queries to run

Use `scripts/obs-api.sh` for all queries. Run independent queries in parallel.

### Claude cost by model

```bash
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[] | select(.metric.model != "") | "\(.metric.model)\t\(.value[1])"' --data-urlencode 'query=sort_desc(sum by (model) (max_over_time(shepherd_claude_code_cost_usage_USD_total[24h])))'
```

### Claude cost total

```bash
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[0].value[1] // "0"' --data-urlencode 'query=sum(max_over_time(shepherd_claude_code_cost_usage_USD_total[24h]))'
```

### Claude tokens by type

```bash
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[] | select(.metric.type != "") | "\(.metric.type)\t\(.value[1])"' --data-urlencode 'query=sort_desc(sum by (type) (max_over_time(shepherd_claude_code_token_usage_tokens_total[24h])))'
```

### Gemini tokens by type

```bash
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[] | select(.metric.type != "") | "\(.metric.type)\t\(.value[1])"' --data-urlencode 'query=sort_desc(sum by (type) (max_over_time(shepherd_gemini_cli_token_usage_total[24h])))'
```

### Codex tokens

```bash
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[0].value[1] // "0"' --data-urlencode 'query=sum(sum_over_time(shepherd:codex:tokens_input:1m[24h]))'
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[0].value[1] // "0"' --data-urlencode 'query=sum(sum_over_time(shepherd:codex:tokens_output:1m[24h]))'
```

### Session count per provider

```bash
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[0].value[1] // "0"' --data-urlencode 'query=count(max_over_time(shepherd_claude_code_session_count_total[24h]))'
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[0].value[1] // "0"' --data-urlencode 'query=count(max_over_time(shepherd_gemini_cli_session_count_total[24h]))'
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[0].value[1] // "0"' --data-urlencode 'query=sum(sum_over_time(shepherd:codex:sessions:1m[24h]))'
```

## Output columns

| Section | Columns |
|---------|---------|
| Cost by model | Model \| Cost ($) |
| Tokens | Provider \| Type \| Count |
| Sessions | Provider \| Count |

For output format options (table/csv/json), read `.claude/skills/obs-shared/assets/output-formats.md`.

## Presentation

1. **Total cost** (sum across providers)
2. **Cost by model** table
3. **Token breakdown** per provider (input/output/cache)
4. **Session count** per provider
5. Calculate cost-per-session and tokens-per-dollar where meaningful
6. If all values are 0: "No activity in the last 24h. Stack may not be receiving telemetry — try `/obs-status`."
7. Note: only Claude emits cost metrics. Gemini and Codex show tokens only.
