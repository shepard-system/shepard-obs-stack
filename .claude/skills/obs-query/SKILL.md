---
name: obs-query
description: Execute PromQL or LogQL queries against Prometheus and Loki. Use this skill whenever the user wants to run a custom query, check a specific metric value, search logs, asks "what is the value of metric X", wants to explore data in Prometheus or Loki, or pastes a PromQL/LogQL expression. Also use when the user asks to query traces, check recording rules output, or debug metric values that don't match dashboard expectations.
disable-model-invocation: false
---

# Obs Query

Execute arbitrary PromQL or LogQL queries and present results.

## Query type detection

- **LogQL**: starts with `{` (stream selector) → route to Loki
- **PromQL**: everything else → route to Prometheus

## How to execute

### PromQL instant query

```bash
scripts/obs-api.sh prom /api/v1/query --raw --jq '.data.result' --data-urlencode "query=<EXPR>"
```

### PromQL range query

```bash
scripts/obs-api.sh prom /api/v1/query_range --raw --jq '.data.result' --data-urlencode "query=<EXPR>" --data-urlencode "start=$(date -v-1H +%s)" --data-urlencode "end=$(date +%s)" --data-urlencode "step=60"
```

### LogQL query

```bash
scripts/obs-api.sh loki /loki/api/v1/query_range --raw --jq '.data.result' --data-urlencode "query=<EXPR>" --data-urlencode "limit=20"
```

## Examples

For a comprehensive list of PromQL and LogQL examples, read `references/examples.md` in this skill directory.

## Output

For output format options (table/csv/json), read `.claude/skills/obs-shared/assets/output-formats.md`.

## Instructions

1. Take the user's query from the skill argument (everything after `/obs-query`)
2. If no query provided, read `references/examples.md` and show common examples
3. Detect query type and execute with appropriate endpoint
4. Format results as table (instant vectors), summary (range), or log lines
5. If query fails, show the error and suggest fixes
6. **Safety**: read-only GET queries only — never POST, PUT, DELETE, or admin endpoints
