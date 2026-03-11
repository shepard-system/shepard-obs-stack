---
name: obs-alerts
description: Show active alerts and their resolution steps. Use this skill whenever the user asks about alerts, wants to know if anything is broken or firing, asks about Alertmanager state, mentions alert silences, or wants to troubleshoot a specific alert like OTelCollectorDown, LokiDown, HighSessionCost, or SensitiveFileAccess. Also use when the user says "any alerts?" or "is everything ok" in the context of the obs stack.
disable-model-invocation: false
---

# Obs Alerts

## Live Data

### Active Alerts
!`./scripts/obs-api.sh am /api/v2/alerts --raw --jq 'if length == 0 then "No active alerts" else .[] | "[\(.status.state)] \(.labels.severity // "unknown") | \(.labels.alertname) | since \(.startsAt) | \(.annotations.summary // .annotations.description // "no description")" end' || echo "Cannot reach Alertmanager"`

### Alert Groups
!`./scripts/obs-api.sh am /api/v2/alerts/groups --raw --jq '.[] | select(.alerts | length > 0) | "Group: \(.labels | to_entries | map("\(.key)=\(.value)") | join(", ")) — \(.alerts | length) alert(s)"' || echo "No alert groups"`

### Silences
!`./scripts/obs-api.sh am /api/v2/silences --raw --jq '.[] | select(.status.state == "active") | "Silence: \(.matchers | map("\(.name)\(.isRegex | if . then "=~" else "=" end)\(.value)") | join(", ")) until \(.endsAt)"' || echo "No active silences"`

### Prometheus Alert Rules (firing/pending)
!`./scripts/obs-api.sh prom /api/v1/rules --raw --jq '.data.groups[].rules[] | select(.state == "firing" or .state == "pending") | "[\(.state)] \(.name) — \(.annotations.summary // .labels.severity // "")"' || echo "All rules inactive"`

### Alert Rule Summary
!`./scripts/obs-api.sh prom /api/v1/rules --raw --jq '[.data.groups[].rules | length] | add' || echo "Cannot count rules"`

## Resolution Hints

Known alerts and suggested fixes:
- **OTelCollectorDown**: `docker compose restart otel-collector` — check logs with `docker compose logs otel-collector --tail=20`
- **LokiDown**: `docker compose restart loki` — check disk space, Loki WAL at `/loki/ruler-wal`
- **TempoDown**: `docker compose restart tempo` — check memory (2G limit), verify WAL directory
- **PrometheusTargetDown**: Check which target is down in Prometheus UI targets page
- **ShepherdServicesDown**: OTel Collector exporter endpoint down — usually means collector needs restart
- **CollectorExportFailed***: Check collector logs for export errors, verify downstream service is up
- **CollectorHighMemory** / **PrometheusHighMemory**: Consider reducing retention or increasing container memory limits
- **HighSessionCost**: Review session in Grafana Cost dashboard — model choice or long session?
- **HighTokenBurn**: Check for runaway loops or large file reads
- **HighToolErrorRate**: Check Quality dashboard — which tools are failing?
- **SensitiveFileAccess**: Check which files were accessed in Operations dashboard
- **NoTelemetryReceived**: Hooks not installed or CLI not running. Try `./hooks/install.sh` and verify with `./scripts/test-signal.sh`
- **LokiRecordingRulesFailing**: Check Loki ruler logs, verify `rules/fake/codex.yaml` syntax

## Instructions

1. Show active alerts as a table: Severity | Alert | Status | Since | Description
2. If alerts are firing, match them to the Resolution Hints above and provide the fix.
3. If silences are active, mention them (something is intentionally suppressed).
4. If no alerts: "All clear. No active or pending alerts."
5. Show total rule count for context (e.g., "0 of 16 rules firing").
