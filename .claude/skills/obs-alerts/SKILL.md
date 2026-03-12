---
name: obs-alerts
description: Show active alerts and their resolution steps. Use this skill whenever the user asks about alerts, wants to know if anything is broken or firing, asks about Alertmanager state, mentions alert silences, or wants to troubleshoot a specific alert like OTelCollectorDown, LokiDown, HighSessionCost, or SensitiveFileAccess. Also use when the user says "any alerts?" or "is everything ok" in the context of the obs stack.
disable-model-invocation: false
---

# Obs Alerts

Active alerts, silences, and resolution guidance.

## Queries to run

Use `scripts/obs-api.sh`. Run independent queries in parallel.

### Active alerts

```bash
scripts/obs-api.sh am /api/v2/alerts --raw --jq 'if length == 0 then "No active alerts" else .[] | "\(.labels.alertname)\t\(.labels.severity // "?")\t\(.status.state)\t\(.startsAt)" end'
```

### Silences

```bash
scripts/obs-api.sh am /api/v2/silences --raw --jq '.[] | select(.status.state == "active") | "\(.matchers | map("\(.name)=\(.value)") | join(", "))\tuntil \(.endsAt)"'
```

### Prometheus rule states (firing/pending)

```bash
scripts/obs-api.sh prom /api/v1/rules --raw --jq '.data.groups[].rules[] | select(.state == "firing" or .state == "pending") | "\(.name)\t\(.state)\t\(.annotations.summary // "")"'
```

### Total rule count

```bash
scripts/obs-api.sh prom /api/v1/rules --raw --jq '[.data.groups[].rules | length] | add'
```

## Resolution hints

For alert-specific fix instructions, read `references/resolution-hints.md` in this skill directory.

## Output columns

| Column | Source |
|--------|--------|
| Alert | alertname label |
| Severity | severity label |
| Status | firing/pending |
| Since | startsAt timestamp |
| Description | summary annotation |

For output format options (table/csv/json), read `.claude/skills/obs-shared/assets/output-formats.md`.

## Presentation

1. Alert table: Alert | Severity | Status | Since
2. If alerts are firing, read `references/resolution-hints.md` and provide the fix
3. If silences are active, mention them
4. If no alerts: "All clear. 0 of 16 rules firing."
5. Show total rule count for context
