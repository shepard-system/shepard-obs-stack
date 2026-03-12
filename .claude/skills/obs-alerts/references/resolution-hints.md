# Alert Resolution Hints

Known alerts and suggested fixes for the obs stack.

## Infrastructure Tier

| Alert | Fix |
|-------|-----|
| **OTelCollectorDown** | `docker compose restart otel-collector` — check logs: `docker compose logs otel-collector --tail=20` |
| **CollectorExportFailedSpans** | Check collector logs for export errors, verify Tempo is up |
| **CollectorExportFailedMetrics** | Check collector logs, verify Prometheus is up and scraping |
| **CollectorExportFailedLogs** | Check collector logs, verify Loki is up |
| **CollectorHighMemory** | Reduce batch size in `configs/otel-collector/config.yaml` or increase container memory limit |
| **PrometheusHighMemory** | Reduce retention or increase memory limit in docker-compose.yaml |

## Pipeline Tier

| Alert | Fix |
|-------|-----|
| **LokiDown** | `docker compose restart loki` — check disk space, WAL at `/loki/ruler-wal` |
| **ShepherdServicesDown** | OTel Collector exporter endpoint (:8889) down — usually means collector needs restart |
| **TempoDown** | `docker compose restart tempo` — check memory (2G limit), verify WAL directory |
| **PrometheusTargetDown** | Check which target is down: `scripts/obs-api.sh prom /api/v1/targets --raw --jq '.data.activeTargets[] | select(.health=="down")'` |
| **LokiRecordingRulesFailing** | Check Loki ruler logs, verify `configs/loki/rules/fake/codex.yaml` syntax |

## Services Tier

| Alert | Fix |
|-------|-----|
| **HighSessionCost** | Review session in Grafana Cost dashboard — model choice or long session? Consider switching to cheaper model. |
| **HighTokenBurn** | Check for runaway loops or large file reads. Look at Operations dashboard event stream. |
| **HighToolErrorRate** | Check Quality dashboard — which tools are failing? Common: Read on deleted files, Bash timeout. |
| **SensitiveFileAccess** | Check Operations dashboard for which files were accessed. Review PreToolUse guard patterns. |
| **NoTelemetryReceived** | Hooks not installed or CLI not in use. Run `./hooks/install.sh` and verify with `./scripts/test-signal.sh`. |

## Inhibit Rules

These suppress downstream alerts to reduce noise:
- `OTelCollectorDown` → suppresses `ShepherdServicesDown` + all business-logic alerts
- `LokiDown` → suppresses `LokiRecordingRulesFailing` + `HighTokenBurn`
- `ShepherdServicesDown` → suppresses `NoTelemetryReceived`, `HighToolErrorRate`, `HighSessionCost`
