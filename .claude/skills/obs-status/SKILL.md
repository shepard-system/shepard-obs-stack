---
name: obs-status
description: Check obs stack health and service status. Use this skill whenever the user asks about stack health, whether services are running, if telemetry is flowing, why dashboards show no data, or anything related to the obs stack being up or down. Also use when troubleshooting "no data" issues, checking if Prometheus/Loki/Tempo/Grafana are reachable, or after running docker compose up to verify everything started correctly.
disable-model-invocation: false
---

# Obs Stack Status

## Service Health

### Grafana
!`./scripts/obs-api.sh grafana /api/health 2>&1 || echo "DOWN"`

### Loki
!`./scripts/obs-api.sh loki /ready 2>&1 || echo "DOWN"`

### Prometheus
!`./scripts/obs-api.sh prom /-/healthy 2>&1 || echo "DOWN"`

### Alertmanager
!`./scripts/obs-api.sh am /-/healthy 2>&1 || echo "DOWN"`

### Tempo
!`./scripts/obs-api.sh tempo /ready 2>&1 || echo "DOWN"`

### OTel Collector
!`./scripts/obs-api.sh collector /metrics --max-time 3 2>&1 | head -1 || echo "DOWN"`

## Prometheus Targets
!`./scripts/obs-api.sh prom /api/v1/targets 2>&1 | jq -r '.data.activeTargets[] | "\(.labels.job)\t\(.health)\t\(.lastScrape | split("T")[0:2] | join("T"))"' 2>/dev/null || echo "Cannot reach Prometheus"`

## Active Alerts
!`./scripts/obs-api.sh am /api/v2/alerts 2>&1 | jq -r 'if length == 0 then "No active alerts" else .[] | "[\(.labels.severity // "?")] \(.labels.alertname): \(.annotations.summary // .annotations.description // "no description")" end' 2>/dev/null || echo "Cannot reach Alertmanager"`

## Last Telemetry
!`./scripts/obs-api.sh prom '/api/v1/query?query=max(shepherd_events_total)' 2>&1 | jq -r '.data.result[0] | "Last event value: \(.value[1]) at \(.value[0] | todate)"' 2>/dev/null || echo "No hook metrics found"`
!`./scripts/obs-api.sh prom '/api/v1/query?query=max(shepherd_claude_code_cost_usage_USD_total)' 2>&1 | jq -r '.data.result[0] | "Last Claude cost value: \(.value[1]) at \(.value[0] | todate)"' 2>/dev/null || echo "No Claude native metrics"`

## Instructions

Format the data above as a concise health report:
1. Service status table (name | port | status)
2. Prometheus scrape targets (job | health | last scrape)
3. Active alerts (if any) with severity
4. Last telemetry timestamps — how long ago
5. If any service is DOWN, suggest: `docker compose up -d` or check logs with `docker compose logs <service>`
