---
name: obs-sessions
description: Show recent AI coding sessions with details. Use this skill whenever the user asks about their recent sessions, wants to see session history, asks "what did I do today/yesterday", wants to know which models were used, how many tools were called per session, or asks about session duration and traces. Also use when the user wants to find a specific session or compare sessions across providers.
disable-model-invocation: false
---

# Obs Sessions

Recent sessions across all providers with model, tools, cost, and duration.

## Queries to run

Use `scripts/obs-api.sh`. Run independent queries in parallel.

### Claude sessions (from native OTel cost metrics — has session_id + model)

```bash
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[:20] | .[] | "\(.metric.session_id)\t\(.metric.model)\t\(.value[1])"' --data-urlencode 'query=sort_desc(max by (session_id, model) (shepherd_claude_code_cost_usage_USD_total))'
```

### Tempo traces (all providers — has traceID, service, duration)

```bash
scripts/obs-api.sh tempo '/api/search?q=%7Bspan%3Aname%3D%22claude.session%22%7D&limit=10' --raw --jq '.traces[:10][] | "\(.traceID)\t\(.rootServiceName)\t\(.durationMs)ms"'
scripts/obs-api.sh tempo '/api/search?q=%7Bspan%3Aname%3D%22gemini.session%22%7D&limit=10' --raw --jq '.traces[:10][] | "\(.traceID)\t\(.rootServiceName)\t\(.durationMs)ms"'
scripts/obs-api.sh tempo '/api/search?q=%7Bspan%3Aname%3D%22codex.session%22%7D&limit=10' --raw --jq '.traces[:10][] | "\(.traceID)\t\(.rootServiceName)\t\(.durationMs)ms"'
```

### Session count per provider

```bash
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[0].value[1] // "0"' --data-urlencode 'query=count(max_over_time(shepherd_claude_code_session_count_total[24h]))'
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[0].value[1] // "0"' --data-urlencode 'query=count(max_over_time(shepherd_gemini_cli_session_count_total[24h]))'
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result[0].value[1] // "0"' --data-urlencode 'query=sum(sum_over_time(shepherd:codex:sessions:1m[24h]))'
```

## Output columns

| Column | Source |
|--------|--------|
| Provider | claude/gemini/codex (from Tempo service name) |
| Session | first 8 chars of session_id or traceID |
| Model | from Claude cost metrics (others: from Tempo trace attributes if available) |
| Duration | from Tempo trace |
| Cost | Claude native OTel (others: `—`) |

For output format options (table/csv/json), read `.claude/skills/obs-shared/assets/output-formats.md`.

## Presentation

1. Session table sorted by most recent, max 20 rows
2. Truncate session IDs to first 8 chars
3. Highlight sessions with high cost (>$1), many tools (>50), or errors
4. Mention Grafana Session Timeline dashboard for full trace view
5. If no sessions: "No sessions recorded. Use a CLI with hooks installed, then check `/obs-status`."
