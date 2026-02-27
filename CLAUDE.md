# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

**shepard-obs-stack** ("The Eye") — Docker-based observability for AI coding assistants (Claude Code, Codex, Gemini CLI). Hybrid telemetry: bash hooks emit OTLP metrics (git context + tool/event counters); native OTel export provides logs, traces, and richer provider-specific metrics. All data flows through OTel Collector into Prometheus, Loki, and Tempo; 8 Grafana dashboards auto-provision on startup.

## Quick Start

```bash
./scripts/init.sh               # bootstrap: env, docker compose up, health check
./hooks/install.sh              # inject hooks + native OTel into CLI configs
./scripts/test-signal.sh        # verify pipeline (9 checks)
```

Open http://localhost:3000 (admin / shepherd).

## Common Commands

```bash
# Stack lifecycle
docker compose up -d                          # start all 6 services
docker compose down                           # stop (preserves volumes)
docker compose down -v                        # stop + delete all data
docker compose restart otel-collector         # restart single service
docker compose logs -f loki --tail=50         # tail service logs

# Verify services
curl -s http://localhost:3100/ready           # Loki health
curl -s http://localhost:3000/api/health      # Grafana health
curl -s http://localhost:9090/-/healthy       # Prometheus health

# Hook management
./hooks/install.sh claude                     # install for specific CLI
./hooks/uninstall.sh                          # remove all hooks + native OTel
./hooks/install.sh codex gemini               # selective install

# Test a hook manually (simulate Claude PostToolUse)
echo '{"tool_name":"Read","tool_response":"ok","cwd":"/tmp"}' | bash hooks/claude/post-tool-use.sh

# Query Prometheus directly
curl -s 'http://localhost:9090/api/v1/query?query=shepherd_tool_calls_total' | jq .
curl -s 'http://localhost:9090/api/v1/query?query=shepherd_events_total' | jq .

# Query Loki directly
curl -s 'http://localhost:3100/loki/api/v1/query_range' \
  --data-urlencode 'query={job="claude-code"}' --data-urlencode 'limit=5' | jq .

# Render C4 architecture diagrams (requires Docker)
./scripts/render-c4.sh
```

## Port Map

| Port | Service        | Description          |
|------|----------------|----------------------|
| 3000 | Grafana        | Dashboards & explore |
| 3100 | Loki           | Log aggregation      |
| 9090 | Prometheus     | Metrics & alerts     |
| 9093 | Alertmanager   | Alert routing        |
| 3200 | Tempo          | Distributed tracing  |
| 4317 | OTel Collector | OTLP gRPC receiver   |
| 4318 | OTel Collector | OTLP HTTP receiver   |
| 8888 | OTel Collector | Collector metrics    |
| 8889 | OTel Collector | Prometheus exporter  |

## Architecture & Data Flow

```
AI CLI (Claude Code / Codex / Gemini)
    ├── hooks/*.sh (git context + tool/event counters)
    │   └── curl POST → OTel Collector :4318 (OTLP HTTP → metrics)
    └── native OTel → OTel Collector :4317 (gRPC)
        ├── metrics → Prometheus (claude_code.*, gen_ai.client.*)
        ├── logs → Loki ({job="claude-code"}, {job="codex_cli_rs"}, {job="gemini-cli"})
        └── traces → Tempo
    ▼
Loki :3100
    └── recording rules → Prometheus :9090 (Codex metrics, 15 rules, 1m interval)
    ▼
Grafana dashboards:
    Unified (01-04):   hook metrics (tools/events) + native OTel metrics (cost/tokens)
    Deep-Dive (10-12): native OTel metrics + logs (provider-specific)
    ▲
Prometheus :9090 ← scrapes OTel Collector :8889
    └─→ Alertmanager :9093 → webhook
```

**Key pipeline detail:** Hooks emit DELTA sum metrics. OTel Collector's `deltatocumulative` processor converts them to cumulative counters before Prometheus scrapes them. The Prometheus exporter applies `shepherd` namespace, so all metrics get the `shepherd_` prefix.

## Key Conventions

**Metrics naming:** All metrics in Prometheus have `shepherd_` prefix (applied by OTel Collector's Prometheus exporter namespace). Hook metrics additionally have `_total` suffix (counters). Native OTel metrics: dots become underscores (e.g., `claude_code.cost_usage.USD` → `shepherd_claude_code_cost_usage_USD_total`).

**Fire-and-forget hooks:** `hooks/lib/metrics.sh:emit_counter()` uses `curl -s & disown` to avoid blocking the CLI. Hooks must never block or slow down the AI assistant.

**Dashboard provisioning:** Dashboards in `configs/grafana/dashboards/*.json` are auto-loaded by Grafana on startup. Edits made in the Grafana UI are **lost on container restart**. Always edit the JSON files directly. All dashboards use `$source` and `$git_repo` template variables.

**Install backups:** `hooks/install.sh` creates `.bak.<timestamp>` backups of CLI config files before modifying them. Uninstall does NOT restore backups.

**jq deep-merge in install.sh:** Hook and native OTel config is merged into existing CLI settings using jq's `*` (recursive merge), preserving user's existing config.

**Dashboard query convention:** PromQL for all numeric panels (rates, totals, gauges). LogQL only for log stream/table panels. Deep-dive dashboards may use LogQL `| json | unwrap` for providers that only emit logs (Codex).

## Hooks

Hooks provide what native OTel cannot: **git context** (`git_repo`, `git_branch`) and **labeled tool/event counters**. All token/cost/session metrics come from native OTel.

```
hooks/
├── lib/
│   ├── git-context.sh       ← get_git_context(cwd) → $GIT_REPO, $GIT_BRANCH
│   ├── metrics.sh           ← emit_counter(name, value, labels_json) → OTLP HTTP
│   ├── traces.sh            ← emit_spans(service_name) → OTLP HTTP /v1/traces
│   └── session-parser.sh    ← parse Claude JSONL → span JSONL (jq)
├── claude/
│   ├── post-tool-use.sh     ← tool_calls_total + events_total (tool_use)
│   └── stop.sh              ← events_total (session_end) + session log parser → Tempo
├── codex/
│   └── notify.sh            ← events_total (turn_end)
├── gemini/
│   ├── after-tool.sh        ← tool_calls_total + events_total (tool_use)
│   ├── after-agent.sh       ← events_total (turn_end)
│   ├── after-model.sh       ← events_total (model_call)
│   └── session-end.sh       ← events_total (session_end) ONLY
├── install.sh               ← auto-detect CLIs + inject hooks + native OTel config
└── uninstall.sh             ← remove hooks + native OTel from CLI configs
```

### Hook Metrics (Prometheus)

| Metric                      | Dimensions                          | Emitted by     |
|-----------------------------|-------------------------------------|----------------|
| `shepherd_events_total`     | source, event_type, git_repo        | all hooks      |
| `shepherd_tool_calls_total` | source, tool, tool_status, git_repo | tool_use hooks |

Tool status detection: hooks grep `tool_response` for error patterns (exit code, traceback, FAILED, panic) → `tool_status="error"` or `"success"`.

### Native OTel Integration

`install.sh` also enables native OTel export from each CLI:

| CLI         | Transport       | Signals                                        | Config location             |
|-------------|-----------------|------------------------------------------------|-----------------------------|
| Claude Code | OTLP gRPC :4317 | metrics (`claude_code.*`) + logs               | `~/.claude/settings.json` `"env"` block |
| Codex       | OTLP gRPC :4317 | logs (`job=codex_cli_rs`) + traces             | `~/.codex/config.toml` `[otel]` section |
| Gemini CLI  | OTLP gRPC :4317 | metrics (`gemini_cli.*`, `gen_ai.client.*`) + logs + traces | `~/.gemini/settings.json` `"telemetry"` block |

Native OTel metric names after Prometheus ingestion follow the pattern: `shepherd_<cli>_<metric>_<unit>_total`. See `configs/otel-collector/config.yaml` for the full pipeline and the Native OTel Metric Catalog section below for the complete list.

### Native OTel Metric Catalog

After Prometheus ingestion with `shepherd` namespace (dots→underscores, `_total` suffix):

| Metric                                               | Source | Dimensions                                         |
|------------------------------------------------------|--------|----------------------------------------------------|
| `shepherd_claude_code_cost_usage_USD_total`          | Claude | model                                              |
| `shepherd_claude_code_token_usage_tokens_total`      | Claude | type (input/output/cacheRead/cacheCreation), model |
| `shepherd_claude_code_session_count_total`           | Claude | —                                                  |
| `shepherd_claude_code_active_time_seconds_total`     | Claude | model                                              |
| `shepherd_claude_code_lines_of_code_count_total`     | Claude | —                                                  |
| `shepherd_claude_code_code_edit_tool_decision_total` | Claude | —                                                  |
| `shepherd_gemini_cli_token_usage_total`              | Gemini | type (input/output/thought/cache/tool), model      |
| `shepherd_gemini_cli_tool_call_count_total`          | Gemini | function_name, success, tool_type                  |
| `shepherd_gemini_cli_session_count_total`            | Gemini | —                                                  |
| `shepherd_gemini_cli_api_request_count_total`        | Gemini | —                                                  |
| `shepherd_gen_ai_client_operation_duration_seconds_*` | Gemini | gen_ai_request_model (histogram)                   |
| `shepherd_gemini_cli_tool_call_latency_milliseconds_*` | Gemini | function_name (histogram)                        |

### Native OTel Log Sources

| Job label      | Source    | Event types in Loki                                                                           |
|----------------|-----------|-----------------------------------------------------------------------------------------------|
| `claude-code`  | Claude    | `claude_code.api_request`, `claude_code.tool_decision`, `claude_code.tool_result`, `claude_code.user_prompt` |
| `codex_cli_rs` | Codex     | OTLP logs with token/model attributes                                                         |
| `gemini-cli`   | Gemini    | metrics + logs + traces                                                                       |

## Loki Recording Rules

15 recording rules in `configs/loki/rules/fake/codex.yaml` pre-compute Codex LogQL into Prometheus metrics.
Loki ruler evaluates every 1m → remote_write to Prometheus.

3 rule groups:

| Group      | Metrics                                                                                       |
|------------|-----------------------------------------------------------------------------------------------|
| **Counts** | `shepherd:codex:{sessions,api_requests,model_calls,tool_results,tool_calls_by_tool,tool_decisions}:1m` |
| **Tokens** | `shepherd:codex:{tokens_input,tokens_output,tokens_cached,tokens_reasoning,tokens_tool}:1m`   |
| **Latency**| `shepherd:codex:{api_latency_ms_sum,api_latency_ms_count,api_latency_ms_p50,api_latency_ms_p95}:1m`  |

Key config requirements:
- `ruler.wal.dir: /tmp/loki/ruler-wal` (must be writable)
- `limits_config.max_query_series: 5000` (default 500 too low)
- Prometheus: `--web.enable-remote-write-receiver` flag
- Directory: `rules/fake/` — `fake` = tenant ID when `auth_enabled: false`

## Dashboards

| Dashboard            | UID                         | Data Source                          | File                                              |
|----------------------|-----------------------------|--------------------------------------|----------------------------------------------------|
| Cost                 | `shepherd-cost`             | Prometheus                           | `configs/grafana/dashboards/01-cost.json`          |
| Tools                | `shepherd-tools`            | Prometheus                           | `configs/grafana/dashboards/02-tools.json`         |
| Operations           | `shepherd-operations`       | Prometheus + Loki                    | `configs/grafana/dashboards/03-operations.json`    |
| Quality              | `shepherd-quality`          | Prometheus                           | `configs/grafana/dashboards/04-quality.json`       |
| Claude Deep Dive     | `shepherd-claude-deep-dive` | Prometheus + Loki                    | `configs/grafana/dashboards/10-claude-deep-dive.json` |
| Codex Deep Dive      | `shepherd-codex-deep-dive`  | Prometheus (recording rules) + Loki  | `configs/grafana/dashboards/11-codex-deep-dive.json`  |
| Gemini Deep Dive     | `shepherd-gemini-deep-dive` | Prometheus + Loki                    | `configs/grafana/dashboards/12-gemini-deep-dive.json` |
| Session Timeline     | `shepherd-session-timeline` | Tempo + Prometheus (span-metrics)    | `configs/grafana/dashboards/13-session-timeline.json` |

Unified dashboards (01–04) aggregate across providers. Deep-dive dashboards (10–12) are provider-specific using native OTel. Session Timeline (13) shows synthetic traces parsed from Claude Code JSONL session logs.

## Config Structure

```
configs/
├── otel-collector/config.yaml          ← OTLP receivers → deltatocumulative → batch → exporters
├── prometheus/
│   ├── prometheus.yaml                 ← Scrape targets (self, collector:8888, collector:8889)
│   └── alerts/                         ← infra.yaml, pipeline.yaml, services.yaml
├── alertmanager/alertmanager.yaml      ← Route + webhook receiver + inhibit rules
├── loki/
│   ├── loki-config.yaml               ← Filesystem storage, TSDB schema v13, 7d retention, ruler config
│   └── rules/fake/codex.yaml          ← 15 recording rules (counts, tokens, latency)
├── tempo/tempo-config.yaml             ← Local WAL + blocks, 7d retention, metrics_generator
└── grafana/
    ├── provisioning/
    │   ├── datasources/datasources.yaml  ← Prometheus, Loki, Tempo (cross-linked)
    │   └── dashboards/dashboards.yaml    ← Auto-load from /dashboards
    └── dashboards/                       ← 8 JSON files (see Dashboards table above)
```

## Alerting

Alertmanager on :9093. Default config routes critical alerts to a webhook receiver (placeholder URL — configure in `configs/alertmanager/alertmanager.yaml`). Inhibit rules suppress NoEventsReceived/HighTokenBurn when LokiDown fires.

Alert rule files in `configs/prometheus/alerts/`:
- **infra.yaml** — OTelCollectorDown, CollectorHighMemory, export failures
- **pipeline.yaml** — LokiDown, PrometheusTargetDown
- **services.yaml** — HighErrorRate, HighLatencyP99, NoTelemetryReceived

## Troubleshooting

**No metrics in Prometheus after test-signal.sh:**
1. Check OTel Collector logs: `docker compose logs otel-collector --tail=20`
2. Verify collector is scraping: `curl -s http://localhost:8889/metrics | grep shepherd_`
3. Confirm Prometheus scrape target is up: `curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health}'`

**No logs in Loki:**
Native OTel logs won't appear until you actually use a CLI with hooks installed. Loki labels to check: `{job="claude-code"}`, `{job="codex_cli_rs"}`, `{job="gemini-cli"}`.

**Dashboard shows "No data":**
Ensure time range is correct (dashboards default to "Last 1 hour"). Hook metrics require at least one tool call or session event. Native OTel metrics require a real CLI session.

**Hooks not firing:**
Verify hooks are installed: check `~/.claude/settings.json` for `.hooks` key, `~/.codex/config.toml` for `notify` line, `~/.gemini/settings.json` for `.hooks` key. Re-run `./hooks/install.sh`.

## Session Timeline (Synthetic Traces)

Claude Code's Stop hook parses JSONL session logs (`~/.claude/projects/{slug}/{session_id}.jsonl`) into synthetic OTLP traces and sends them to Tempo via OTel Collector.

**Pipeline:** `stop.sh` → `session-parser.sh` (single-pass jq) → span JSONL → `emit_spans()` (traces.sh) → `/v1/traces` → Tempo

**Span types generated:**
- `claude.session` — root span (session duration, model, git branch)
- `claude.tool.*` — tool call spans (Read, Edit, Bash, etc.) with duration
- `claude.mcp.*` — MCP tool calls with native `elapsedTimeMs` timing
- `claude.agent.*` — sub-agent spans grouped by agentId

**Key details:**
- Deterministic IDs: trace_id = UUID without dashes, span_id = sequential hex (pad16)
- ISO 8601 → nanoseconds via jq `strptime`+`mktime` (no perl/shasum dependencies)
- Tool calls joined by `tool_use_id`: tool_use entry provides start, tool_result provides end
- Fire-and-forget: `( parser | emit_spans ) </dev/null >/dev/null 2>&1 &` — fully detached, never blocks the CLI
- Tempo's `metrics_generator` produces `traces_spanmetrics_calls_total` and `traces_spanmetrics_duration_seconds_*` for the dashboard stats

## Known Limitations

- **Codex**: notify hook payload has no `total_token_usage` — tokens always 0, cost always 0. Events are tracked. Native OTel config accepted but sends zero data.
- **Gemini CLI**: hooks installed but not yet tested with real session data.
- **Empty model labels**: test data may create metrics with `model=""`. PromQL queries filter with `model!=""` where needed.

