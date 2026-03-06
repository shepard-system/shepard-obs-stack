# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

**shepard-obs-stack** ("The Eye") — Docker-based observability for AI coding assistants (Claude Code, Codex, Gemini CLI). 
Hybrid telemetry: bash hooks emit OTLP metrics (git context + tool/event counters); native OTel export provides logs, traces, and richer provider-specific metrics. 
All data flows through OTel Collector into Prometheus, Loki, and Tempo; 8 Grafana dashboards auto-provision on startup.

## Quick Start

```bash
./scripts/init.sh               # bootstrap: env, docker compose up, health check
./hooks/install.sh              # inject hooks + native OTel into CLI configs
./scripts/test-signal.sh        # verify pipeline (11 checks)
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
  --data-urlencode 'query={service_name="claude-code"}' --data-urlencode 'limit=5' | jq .

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
| 3200 | Tempo          | Distributed tracing      |
| 9095 | Tempo          | gRPC (internal)          |
| 4317 | OTel Collector | OTLP gRPC receiver       |
| 4318 | OTel Collector | OTLP HTTP receiver       |
| 8888 | OTel Collector | Collector metrics        |
| 8889 | OTel Collector | Prometheus exporter (internal, not host-exposed) |

## Architecture & Data Flow

```
AI CLI (Claude Code / Codex / Gemini)
    ├── hooks/*.sh (git context + tool/event counters)
    │   └── curl POST → OTel Collector :4318 (OTLP HTTP → metrics)
    └── native OTel → OTel Collector :4317 (gRPC)
        ├── metrics → Prometheus (claude_code.*, gen_ai.client.*)
        ├── logs → Loki ({service_name="claude-code"}, {service_name="codex_cli_rs"}, {service_name="gemini-cli"})
        └── traces → Tempo
    ▼
Loki :3100
    └── recording rules → Prometheus :9090 (Codex metrics, 15 rules, 1m interval)
    ▼
Grafana dashboards:
    Unified (01-04):   hook metrics (tools/events) + native OTel metrics (cost/tokens)
    Deep-Dive (10-12): native OTel metrics + logs (provider-specific)
    Session Timeline (13): synthetic traces from JSONL parser
    ▲
Prometheus :9090 ← scrapes OTel Collector :8889 + Tempo :3200
    └─→ Alertmanager :9093 → Telegram/Slack/Discord
```

**Key pipeline detail:** Hooks emit DELTA sum metrics. OTel Collector's `deltatocumulative` processor converts them to cumulative counters before Prometheus scrapes them. 
The Prometheus exporter applies `shepherd` namespace, so all metrics get the `shepherd_` prefix.

## Key Conventions

**Metrics naming:** All metrics in Prometheus have `shepherd_` prefix (applied by OTel Collector's Prometheus exporter namespace). 
Hook metrics additionally have `_total` suffix (counters). 
Native OTel metrics: dots become underscores (e.g., `claude_code.cost_usage.USD` → `shepherd_claude_code_cost_usage_USD_total`).

**Fire-and-forget hooks:** `hooks/lib/metrics.sh:emit_counter()` uses `curl -s & disown` to avoid blocking the CLI.
Hooks must never block or slow down the AI assistant.

**Rust accelerator resolution:** All hooks source `hooks/lib/accelerator.sh` which sets `$SHEPARD_HOOK` via 3-step lookup:
`hooks/bin/shepard-hook` (project-local) → `command -v shepard-hook` (PATH) → empty (bash fallback).
Install with `./scripts/install-accelerator.sh` — downloads to `hooks/bin/` (gitignored, no sudo).

**Dashboard provisioning:** Dashboards in `configs/grafana/dashboards/*.json` are auto-loaded by Grafana on startup. 
Edits made in the Grafana UI are **lost on container restart**. 
Always edit the JSON files directly. 
Tools and Operations dashboards use `$source` and `$git_repo` variables. 
Deep Dive dashboards use `$model`. Session Timeline uses `$provider`. 
Cost and Quality have no template variables.

**Install backups:** `hooks/install.sh` creates `.bak.<timestamp>` backups of CLI config files before modifying them. 
Uninstall does NOT restore backups.

**jq deep-merge in install.sh:** Hook and native OTel config is merged into existing CLI settings using jq's `*` (recursive merge), preserving user's existing config.

**Dashboard query convention:** PromQL for all numeric panels (rates, totals, gauges). LogQL only for log stream/table panels. 
Deep-dive dashboards may use LogQL `| json | unwrap` for providers that only emit logs (Codex). 
Session Timeline (13) uses PromQL `traces_spanmetrics_calls_total` for stat/table panels and Tempo trace search for the Session Traces table only.

**Hook shell options:** All hooks use `set -u` (not `set -euo pipefail`). `set -e` causes silent SIGPIPE kills in fire-and-forget pipelines; 
`set -o pipefail` amplifies this. Hooks must never fail or block the CLI.

## Hooks

Hooks provide what native OTel cannot: **git context** (`git_repo`, `git_branch`) and **labeled tool/event counters**. 
All token/cost/session metrics come from native OTel.

```
hooks/
├── bin/
│   └── shepard-hook              ← downloaded Rust accelerator (gitignored)
├── lib/
│   ├── accelerator.sh            ← resolve $SHEPARD_HOOK (project-local → PATH → empty)
│   ├── git-context.sh            ← get_git_context(cwd) → $GIT_REPO, $GIT_BRANCH
│   ├── metrics.sh                ← emit_counter(name, value, labels_json) → OTLP HTTP
│   ├── sensitive-patterns.sh     ← check_sensitive_access(tool_input) → detects .env, credentials, keys
│   ├── traces.sh                 ← emit_spans(service_name) → OTLP HTTP /v1/traces
│   ├── session-parser.sh         ← parse Claude JSONL → enriched span JSONL (jq)
│   ├── codex-session-parser.sh   ← parse Codex JSONL → span JSONL (jq)
│   └── gemini-session-parser.sh  ← parse Gemini JSON → span JSONL (jq)
├── claude/
│   ├── pre-tool-use.sh           ← PreToolUse guard: blocks sensitive file access (exit 2)
│   ├── post-tool-use.sh          ← tool_calls_total + events_total (tool_use) + sensitive_file_access
│   ├── session-start.sh          ← SessionStart (compact): re-injects project conventions after compaction
│   └── stop.sh                   ← events_total (session_end) + compaction_events + session parser → Tempo
├── codex/
│   └── notify.sh                 ← events_total (turn_end) + session parser → Tempo
├── gemini/
│   ├── after-tool.sh             ← tool_calls_total + events_total (tool_use) + sensitive_file_access
│   ├── after-agent.sh            ← events_total (turn_end)
│   ├── after-model.sh            ← events_total (model_call)
│   └── session-end.sh            ← events_total (session_end) + session parser → Tempo
├── install.sh                    ← auto-detect CLIs + inject hooks + native OTel config
└── uninstall.sh                  ← remove hooks + native OTel from CLI configs
```

### Hook Metrics (Prometheus)

| Metric                                 | Dimensions                          | Emitted by       |
|----------------------------------------|-------------------------------------|------------------|
| `shepherd_events_total`                | source, event_type, git_repo        | all hooks        |
| `shepherd_tool_calls_total`            | source, tool, tool_status, git_repo | tool_use hooks   |
| `shepherd_sensitive_file_access_total` | source, tool, git_repo              | tool_use hooks   |
| `shepherd_compaction_events_total`     | source, git_repo                    | Claude stop hook |

Tool status detection: hooks grep `tool_response` for error patterns (exit code, traceback, FAILED, panic) → `tool_status="error"` or `"success"`.

Sensitive file detection: hooks check `tool_input` for patterns (`.env`, `credentials`, `secrets`, `.pem`, `.key`, `id_rsa`, `.aws/`) via `lib/sensitive-patterns.sh`.

### Native OTel Integration

`install.sh` also enables native OTel export from each CLI:

| CLI         | Transport       | Signals                                                     | Config location                               |
|-------------|-----------------|-------------------------------------------------------------|-----------------------------------------------|
| Claude Code | OTLP gRPC :4317 | metrics (`claude_code.*`) + logs                            | `~/.claude/settings.json` `"env"` block       |
| Codex       | OTLP gRPC :4317 | logs (`service_name=codex_cli_rs`) + traces                 | `~/.codex/config.toml` `[otel]` section       |
| Gemini CLI  | OTLP gRPC :4317 | metrics (`gemini_cli.*`, `gen_ai.client.*`) + logs + traces | `~/.gemini/settings.json` `"telemetry"` block |

Native OTel metric names after Prometheus ingestion follow the pattern: `shepherd_<cli>_<metric>_<unit>_total`. 
See `configs/otel-collector/config.yaml` for the full pipeline and the Native OTel Metric Catalog section below for the complete list.

### Native OTel Metric Catalog

After Prometheus ingestion with `shepherd` namespace (dots→underscores, `_total` suffix):

| Metric                                                 | Source | Dimensions                                         |
|--------------------------------------------------------|--------|----------------------------------------------------|
| `shepherd_claude_code_cost_usage_USD_total`            | Claude | model                                              |
| `shepherd_claude_code_token_usage_tokens_total`        | Claude | type (input/output/cacheRead/cacheCreation), model |
| `shepherd_claude_code_session_count_total`             | Claude | — (not emitted by Claude Code ≤v2.1.63)            |
| `shepherd_claude_code_active_time_seconds_total`       | Claude | model                                              |
| `shepherd_claude_code_lines_of_code_count_total`       | Claude | —                                                  |
| `shepherd_claude_code_code_edit_tool_decision_total`   | Claude | —                                                  |
| `shepherd_gemini_cli_token_usage_total`                | Gemini | type (input/output/thought/cache/tool), model      |
| `shepherd_gemini_cli_tool_call_count_total`            | Gemini | function_name, success, tool_type                  |
| `shepherd_gemini_cli_session_count_total`              | Gemini | —                                                  |
| `shepherd_gemini_cli_api_request_count_total`          | Gemini | status_code                                        |
| `shepherd_gen_ai_client_operation_duration_seconds_*`  | Gemini | gen_ai_request_model (histogram)                   |
| `shepherd_gemini_cli_tool_call_latency_milliseconds_*` | Gemini | function_name (histogram)                          |

### Native OTel Log Sources

| Service name   | Source | Event types in Loki                                                                                          |
|----------------|--------|--------------------------------------------------------------------------------------------------------------|
| `claude-code`  | Claude | `claude_code.api_request`, `claude_code.tool_decision`, `claude_code.tool_result`, `claude_code.user_prompt` |
| `codex_cli_rs` | Codex  | OTLP logs with token/model attributes                                                                        |
| `gemini-cli`   | Gemini | metrics + logs + traces                                                                                      |

## Loki Recording Rules

15 recording rules in `configs/loki/rules/fake/codex.yaml` pre-compute Codex LogQL into Prometheus metrics.
Loki ruler evaluates every 1m → remote_write to Prometheus.

3 rule groups:

| Group       | Metrics                                                                                                |
|-------------|--------------------------------------------------------------------------------------------------------|
| **Counts**  | `shepherd:codex:{sessions,api_requests,model_calls,tool_results,tool_calls_by_tool,tool_decisions}:1m` |
| **Tokens**  | `shepherd:codex:{tokens_input,tokens_output,tokens_cached,tokens_reasoning,tokens_tool}:1m`            |
| **Latency** | `shepherd:codex:{api_latency_ms_sum,api_latency_ms_count,api_latency_ms_p50,api_latency_ms_p95}:1m`    |

Key config requirements:
- `ruler.wal.dir: /tmp/loki/ruler-wal` (must be writable)
- `limits_config.max_query_series: 5000` (default 500 too low)
- Prometheus: `--web.enable-remote-write-receiver` flag
- Directory: `rules/fake/` — `fake` = tenant ID when `auth_enabled: false`

## Dashboards

| Grafana Title (sort order) | UID                         | Data Source                         | File                                                  |
|----------------------------|-----------------------------|-------------------------------------|-------------------------------------------------------|
| 01 Claude Code Deep Dive   | `shepherd-claude-deep-dive` | Prometheus + Loki                   | `configs/grafana/dashboards/10-claude-deep-dive.json` |
| 02 Gemini CLI Deep Dive    | `shepherd-gemini-deep-dive` | Prometheus + Loki                   | `configs/grafana/dashboards/12-gemini-deep-dive.json` |
| 03 Codex Deep Dive         | `shepherd-codex-deep-dive`  | Prometheus (recording rules) + Loki | `configs/grafana/dashboards/11-codex-deep-dive.json`  |
| 04 Cost                    | `shepherd-cost`             | Prometheus                          | `configs/grafana/dashboards/01-cost.json`             |
| 05 Tools                   | `shepherd-tools`            | Prometheus                          | `configs/grafana/dashboards/02-tools.json`            |
| 06 Operations              | `shepherd-operations`       | Prometheus + Loki                   | `configs/grafana/dashboards/03-operations.json`       |
| 07 Quality                 | `shepherd-quality`          | Prometheus                          | `configs/grafana/dashboards/04-quality.json`          |
| 08 Session Timeline        | `shepherd-session-timeline` | Prometheus (span-metrics) + Tempo   | `configs/grafana/dashboards/13-session-timeline.json` |

Deep-dive dashboards (01–03) are provider-specific using native OTel. Unified dashboards (04–07) aggregate across providers.
Session Timeline (08) shows synthetic traces parsed from all 3 CLI session logs with `$provider` variable.
Stat/table panels use Prometheus `traces_spanmetrics_calls_total` counters (generated by Tempo's span-metrics processor).
Session Traces table uses Tempo trace search. Tool Duration Distribution uses Prometheus `traces_spanmetrics_latency_bucket`.

## Config Structure

```
configs/
├── otel-collector/config.yaml          ← OTLP receivers → deltatocumulative → batch → resource → exporters
├── prometheus/
│   ├── prometheus.yaml                 ← Scrape targets (self, collector:8888, collector:8889, tempo:3200)
│   └── alerts/                         ← infra.yaml, pipeline.yaml, services.yaml
├── alertmanager/alertmanager.yaml      ← Route + Telegram/Slack/Discord receivers + inhibit rules
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

Alertmanager on :9093 with 15 alert rules in three tiers.
Telegram, Slack, and Discord receivers included (commented out — configure in `configs/alertmanager/alertmanager.yaml`).

Alert rule files in `configs/prometheus/alerts/`:
- **infra.yaml** — `OTelCollectorDown`, `CollectorExportFailed{Spans,Metrics,Logs}`, `CollectorHighMemory`, `PrometheusHighMemory`
- **pipeline.yaml** — `LokiDown`, `TempoDown`, `PrometheusTargetDown`, `LokiRecordingRulesFailing`
- **services.yaml** — `HighSessionCost` (>$10/hr), `HighTokenBurn` (>50k tok/min), `HighToolErrorRate` (>10%), `SensitiveFileAccess`, `NoTelemetryReceived`

Inhibit rules: `OTelCollectorDown` suppresses all business-logic alerts. `LokiDown` suppresses `LokiRecordingRulesFailing` and `HighTokenBurn`.

## Troubleshooting

**No metrics in Prometheus after test-signal.sh:**
1. Check OTel Collector logs: `docker compose logs otel-collector --tail=20`
2. Verify collector is scraping: `curl -s http://localhost:8889/metrics | grep shepherd_`
3. Confirm Prometheus scrape target is up: `curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health}'`

**No logs in Loki:**
Native OTel logs won't appear until you actually use a CLI with hooks installed.
Loki labels to check: `{service_name="claude-code"}`, `{service_name="codex_cli_rs"}`, `{service_name="gemini-cli"}`.

**Dashboard shows "No data":**
Ensure time range is correct (dashboards default to "Last 1 hour"). 
Hook metrics require at least one tool call or session event. Native OTel metrics require a real CLI session.

**Hooks not firing:**
Verify hooks are installed: check `~/.claude/settings.json` for `.hooks` key, `~/.codex/config.toml` for `notify` line, `~/.gemini/settings.json` for `.hooks` key. Re-run `./hooks/install.sh`.

## Session Timeline (Synthetic Traces)

All 3 CLI hooks parse session logs into synthetic OTLP traces → Tempo via OTel Collector.
Each provider has its own parser, all producing the same unified span schema.

**Pipelines:**
- Claude: `stop.sh` → `session-parser.sh` (JSONL) → Tempo service `claude-code-session`
- Codex: `notify.sh` → `codex-session-parser.sh` (JSONL) → Tempo service `codex-session`
- Gemini: `session-end.sh` → `gemini-session-parser.sh` (JSON) → Tempo service `gemini-session`

**Span types generated:**

| Span Name                 | Claude             | Codex              | Gemini       |
|---------------------------|--------------------|--------------------|--------------|
| `{provider}.session`      | root span          | root span          | root span    |
| `{provider}.session.meta` | marker child       | marker child       | marker child |
| `{provider}.tool.*`       | tool calls         | function calls     | tool calls   |
| `claude.mcp.*`            | MCP calls          | —                  | —            |
| `claude.agent.*`          | sub-agents         | —                  | —            |
| `{provider}.compaction`   | context compaction | context compaction | —            |

**Session meta marker span:** Each parser emits a zero-duration `{provider}.session.meta` child span (span_id=0x02, parent=root). 
This was originally needed because Tempo's local-blocks processor does not index root spans. 
Now that Session Timeline uses Prometheus span-metrics (which DO index root spans), the `session.meta` spans 
are no longer required for dashboard queries but are kept for backward compatibility in trace views.

**Root span attributes (all providers):**
`session.id`, `model`, `provider`, `git.branch`, `git.repo`, `tokens.input`, `tokens.output`, `tokens.cache_read`,
`tokens.total`, `tool.count`, `tool.error_count`, `turn.count`, `compaction.count`, `stop_reason`, `has_interruption`
Provider-specific: `tokens.cache_create` (Claude), `thinking.block_count` (Claude, Gemini), `tokens.reasoning` (Codex, Gemini)

**Tool span attributes:** `tool.name`, `tool.is_error` (Claude, Gemini only — not Codex), `tool.input.file_path`, `tool.input.command`, `tool.input.pattern`

**Key details:**
- Deterministic IDs: trace_id = UUID without dashes, span_id = sequential hex (pad16)
- ISO 8601 → nanoseconds via jq `strptime`+`mktime` (no perl/shasum dependencies)
- Claude: requestId dedup (streaming snapshots), tool join by `tool_use_id`
- Codex: function_call/function_call_output join by `call_id`, cumulative tokens from last `token_count`
- Gemini: single JSON (not JSONL), inline toolCalls with status
- Error status: OTLP status code 2 for error spans, detected from `is_error`/`status`
- Fire-and-forget: `( parser | emit_spans ) </dev/null >/dev/null 2>&1 &` — fully detached
- Tempo's `metrics_generator` produces `traces_spanmetrics_calls_total` and `traces_spanmetrics_latency_bucket`
- Session Timeline stat/table panels use Prometheus `traces_spanmetrics_calls_total` with `round(sum(increase(...[$__range])))` pattern. Session counting uses `*.session` root spans (not `*.session.meta` — zero-duration marker spans are unreliable in span-metrics).
- Tempo `overrides.defaults.global.max_bytes_per_trace: 0` — disables trace size limit (default 5MB drops large session traces). MUST be at `overrides.defaults.global` — placing at `overrides.defaults` directly crashes Tempo.
- Tempo `metrics_generator.processors`: only `service-graphs` and `span-metrics`. `local-blocks` was removed to eliminate OOM risk (parquet block copies in RAM).
- Tempo compactor: `max_compaction_objects: 4`, `compaction_window: 1h` — limits RAM usage during block merges. Pool: `max_workers: 10`, `queue_depth: 100` (cluster defaults of 100/10000 cause OOM on local).

## Testing

```bash
bash tests/run-all.sh         # 87 unit tests (syntax, configs, hooks, parsers)
bash tests/run-all.sh --e2e   # + Docker E2E smoke (starts stack, runs test-signal.sh)
```

4 test suites:
- **test-shell-syntax.sh** — `bash -n` on all 23 scripts + shellcheck (if installed)
- **test-config-validate.sh** — 8 JSON dashboards (jq) + 11 YAML configs (PyYAML/yq)
- **test-hooks.sh** — 21 behavioral tests with mock curl/git. Uses `SHEPARD_TEST_MODE=1` to bypass Rust accelerator and test bash code path.
- **test-parsers.sh** — 24 tests against fixtures in `tests/fixtures/`. Verifies span count, required fields, attributes, error status, trace_id consistency.

CI: `.github/workflows/test.yml` runs unit tests on every push/PR, then E2E smoke with Docker Compose.

Always run `bash tests/run-all.sh` before committing changes to hooks, configs, or parsers.

## Known Limitations

- **Codex**: notify hook payload has no `total_token_usage` — tokens always 0, cost always 0. Events are tracked. Native OTel config accepted but sends zero data.
- **Gemini CLI**: hooks tested and working. Hook config format uses nested `matcher`/`hooks` schema (not flat `command` arrays). See `install.sh` for the correct format.
- **Empty model labels**: test data may create metrics with `model=""`. PromQL queries filter with `model!=""` where needed.

