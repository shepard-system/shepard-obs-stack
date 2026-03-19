---
name: obs-compare
description: Compare AI coding providers side by side. Use this skill whenever the user asks to compare Claude vs Gemini vs Codex, wants a provider comparison, asks "which provider is better/cheaper/faster", wants to see differences between CLIs, or mentions "compare", "versus", "vs", "head to head", "side by side". Also trigger when the user asks which provider they use most, which has more errors, or which burns more tokens.
disable-model-invocation: false
---

# Obs Comparative Report

Side-by-side comparison of Claude Code, Gemini CLI, and Codex.

## Arguments

User may specify a time range. Default: `24h`.
Mapping: `today` → `24h`, `yesterday` → offset query, `week` → `7d`.
Replace `[24h]` in queries below with the appropriate range.

## Queries to run

Use `scripts/obs-api.sh` for all queries. Run independent queries in parallel.

### Sessions per provider

```bash
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[0].value[1] // "0"' --data-urlencode 'query=count(max_over_time(shepherd_claude_code_session_count_total[24h]))'
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[0].value[1] // "0"' --data-urlencode 'query=count(max_over_time(shepherd_gemini_cli_session_count_total[24h]))'
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[0].value[1] // "0"' --data-urlencode 'query=round(sum(sum_over_time(shepherd:codex:sessions:1m[24h])))'
```

### Cost (Claude only)

```bash
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[0].value[1] // "0"' --data-urlencode 'query=sum(max_over_time(shepherd_claude_code_cost_usage_USD_total[24h]))'
```

### Input tokens per provider

```bash
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[0].value[1] // "0"' --data-urlencode 'query=round(sum(max_over_time(shepherd_claude_code_token_usage_tokens_total{type="input"}[24h])))'
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[0].value[1] // "0"' --data-urlencode 'query=round(sum(max_over_time(shepherd_gemini_cli_token_usage_total{type="input"}[24h])))'
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[0].value[1] // "0"' --data-urlencode 'query=round(sum(sum_over_time(shepherd:codex:tokens_input:1m[24h])))'
```

### Output tokens per provider

```bash
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[0].value[1] // "0"' --data-urlencode 'query=round(sum(max_over_time(shepherd_claude_code_token_usage_tokens_total{type="output"}[24h])))'
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[0].value[1] // "0"' --data-urlencode 'query=round(sum(max_over_time(shepherd_gemini_cli_token_usage_total{type="output"}[24h])))'
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[0].value[1] // "0"' --data-urlencode 'query=round(sum(sum_over_time(shepherd:codex:tokens_output:1m[24h])))'
```

### Cache efficiency per provider

```bash
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[0].value[1] // "0"' --data-urlencode 'query=sum(max_over_time(shepherd_claude_code_token_usage_tokens_total{type="cacheRead"}[24h])) / clamp_min(sum(max_over_time(shepherd_claude_code_token_usage_tokens_total{type="input"}[24h])) + sum(max_over_time(shepherd_claude_code_token_usage_tokens_total{type="cacheRead"}[24h])), 1)'
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[0].value[1] // "0"' --data-urlencode 'query=sum(max_over_time(shepherd_gemini_cli_token_usage_total{type="cache"}[24h])) / clamp_min(sum(max_over_time(shepherd_gemini_cli_token_usage_total{type="input"}[24h])) + sum(max_over_time(shepherd_gemini_cli_token_usage_total{type="cache"}[24h])), 1)'
```

### Tool calls per provider

Source labels: `claude-code`, `gemini-cli`, `codex`.

```bash
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[] | "\(.metric.source)\t\(.value[1])"' --data-urlencode 'query=sort_desc(sum by (source) (round(increase(shepherd_tool_calls_total[24h]))))'
```

### Tool errors per provider

```bash
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[] | "\(.metric.source)\t\(.value[1])"' --data-urlencode 'query=sort_desc(sum by (source) (round(increase(shepherd_tool_calls_total{tool_status="error"}[24h]))))'
```

### Top repos

```bash
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[] | select(.metric.git_repo != "") | "\(.metric.git_repo)\t\(.value[1])"' --data-urlencode 'query=topk(5, sort_desc(sum by (git_repo) (round(increase(shepherd_events_total[24h])))))'
```

## Output columns

| Section | Columns |
|---------|---------|
| Overview | Provider \| Sessions \| Cost \| Tool Calls \| Errors |
| Tokens | Provider \| Input \| Output \| Cache Efficiency |
| Repos | Repo \| Events |

For output format options (table/csv/json), read `.claude/skills/obs-shared/assets/output-formats.md`.

## Presentation

1. **Overview table**: one row per provider (Claude, Gemini, Codex) with sessions, cost, tool calls, errors
2. **Token table**: input/output/cache per provider, format large numbers with K/M suffixes
3. **Cache efficiency**: show as percentage, highlight provider with best efficiency
4. **Top repos**: ordered list
5. Highlight notable differences: "Claude has 3× more tool calls than Gemini"
6. Note: cost metrics available for Claude only. Codex tokens may be 0 (known limitation).
7. If all values are 0: "No activity in the last 24h. Try `/obs-status` to check stack health."
8. Dashboard link: http://localhost:3000/d/shepherd-comparative
