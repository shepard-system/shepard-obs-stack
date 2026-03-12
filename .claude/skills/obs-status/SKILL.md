---
name: obs-status
description: Check obs stack health and service status. Use this skill whenever the user asks about stack health, whether services are running, if telemetry is flowing, why dashboards show no data, or anything related to the obs stack being up or down. Also use when troubleshooting "no data" issues, checking if Prometheus/Loki/Tempo/Grafana are reachable, or after running docker compose up to verify everything started correctly.
disable-model-invocation: false
---

# Obs Stack Status

Check health of all 6 obs stack services, scrape targets, alerts, and last telemetry.

## Queries to run

Use `scripts/obs-api.sh` to query each service. Run independent checks in parallel.

### Step 1: Service health (run all in parallel)

```bash
scripts/obs-api.sh grafana /api/health
scripts/obs-api.sh loki /ready
scripts/obs-api.sh prom /-/healthy
scripts/obs-api.sh am /-/healthy
scripts/obs-api.sh tempo /ready
```

If a command fails or returns empty, the service is down.

### Step 2: Prometheus scrape targets

```bash
scripts/obs-api.sh prom /api/v1/targets --raw --jq '.data.activeTargets[] | "\(.labels.job)\t\(.health)"'
```

### Step 3: Active alerts

```bash
scripts/obs-api.sh am /api/v2/alerts --raw --jq 'if length == 0 then "No active alerts" else .[] | "\(.labels.alertname)\t\(.labels.severity // "?")" end'
```

### Step 4: Last telemetry received

```bash
scripts/obs-api.sh prom '/api/v1/query?query=max(shepherd_events_total)' --raw --jq '.data.result[0].value'
scripts/obs-api.sh prom '/api/v1/query?query=max(shepherd_claude_code_cost_usage_USD_total)' --raw --jq '.data.result[0].value'
```

## Output columns

| Column | Source |
|--------|--------|
| Service | service name |
| Port | 3000, 3100, 9090, 9093, 3200, 4317/4318 |
| Status | UP if healthy response, DOWN if empty/error |

For output format options (table/csv/json), read `.claude/skills/obs-shared/assets/output-formats.md`.

## Presentation

1. Service status table (name | port | status)
2. Scrape targets (job | health)
3. Active alerts with severity (if any)
4. Last telemetry — how long ago
5. If any service is DOWN: suggest `docker compose up -d` or `docker compose logs <service> --tail=20`
