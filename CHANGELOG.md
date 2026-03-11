# Changelog

All notable changes to shepard-obs-stack ("The Eye") are documented here.

## [Unreleased]

### Added

- **Claude Code skills** (6 slash commands): `/obs-status`, `/obs-cost`, `/obs-sessions`,
  `/obs-tools`, `/obs-alerts`, `/obs-query` — query the obs stack directly from Claude Code
  without switching to the browser. Covers health checks, cost reports, session summaries,
  tool usage, active alerts, and free-form PromQL/LogQL queries.
- **`scripts/obs-api.sh`** — centralized API client for all obs stack services. Auth-ready:
  supports `SHEPARD_API_TOKEN` (Bearer), `SHEPARD_CA_CERT` (TLS), `SHEPARD_GRAFANA_TOKEN`
  via environment variables. Defaults to plain HTTP on localhost for single-machine use.
- **LokiDown alert was checking OTel Collector, not Loki** — `up{job="shepherd-services"}`
  monitored the collector exporter (port 8889), not Loki itself. Now uses dedicated
  `up{job="loki"}` scrape job. Old check renamed to `ShepherdServicesDown`.
- **Test suite** (113 tests, 4 suites): shell syntax (23), config validation (25),
  hook behavior (41), session parsers (24). Run with `bash tests/run-all.sh`.
- **CI workflow** (`.github/workflows/test.yml`): unit tests + Docker E2E smoke.
  shellcheck and promtool installed in CI for lint and rule validation.
- **Loki scrape job** in Prometheus (`loki:3100`) for proper health monitoring.
- **ShepherdServicesDown** alert for OTel Collector Prometheus exporter (port 8889).
- `SHEPARD_TEST_MODE` env var in `accelerator.sh` — bypasses Rust binary for testing bash path.
- Test fixtures for all 3 session parsers (`tests/fixtures/`).
- **promtool validation** in CI — `promtool check rules` on all Prometheus alert files.
- **Alert regression tests** — rule counts per file + expression guards (LokiDown, ShepherdServicesDown, OTelCollectorDown).

### Fixed

- **LokiDown alert** — split from collector exporter check into dedicated Loki scrape job.
- **Compaction arithmetic error in stop.sh** — `grep -c` returns "0" with exit 1,
  `|| echo "0"` produced `"0\n0"`, causing `-gt` comparison to fail.

### Changed

- Alert count: 15 → 16 rules (LokiDown split into LokiDown + ShepherdServicesDown).
- Inhibit rules: `OTelCollectorDown` now also suppresses `ShepherdServicesDown`;
  `ShepherdServicesDown` suppresses `NoTelemetryReceived`, `HighToolErrorRate`, `HighSessionCost`.
- `.gitignore`: un-ignore `.claude/skills/` for tracking slash-command skills in the repo.

## [1.1.0] — 2026-03-05

### Added

- **Rust accelerator** integration — optional `shepard-hook` binary replaces bash+jq+curl.
  Install with `./scripts/install-accelerator.sh`. Falls back to bash if not installed.
- **Gemini Deep Dive** panels: Error Rate by Model, Calls by Tool Type, Tool Stats table.
- C4 architecture diagrams (C1 system context, C3 hooks components, C5 event schema).

### Fixed

- Gemini Deep Dive dashboard: query labels, model filters, layout, NaN mappings.
- install-accelerator.sh: BSD sed compatibility, macOS asset name detection.
- uninstall.sh: accelerator binary cleanup.

## [1.0.0] — 2026-03-01

Initial public release. Docker-based observability for AI coding assistants
(Claude Code, Codex CLI, Gemini CLI).

### Stack

- **6 services**: OTel Collector 0.146.0, Prometheus v3.9.1, Loki 3.6.7,
  Tempo 2.10.1, Grafana 12.4.0, Alertmanager v0.30.1
- One-command bootstrap: `./scripts/init.sh`
- Pipeline validation: `./scripts/test-signal.sh` (11 checks)

### Hooks

- **Claude Code**: `PreToolUse` + `PostToolUse` + `SessionStart` + `Stop` hooks
  - PreToolUse guard blocks access to sensitive files (`.env`, credentials, keys) with exit 2
  - SessionStart (matcher: compact) re-injects project conventions after context compaction
  - PostToolUse emits tool calls, events, and sensitive file access counters
  - Stop emits session end events, compaction counts, and triggers session trace parser
- **Codex CLI**: `notify` hook — events, session traces
- **Gemini CLI**: `AfterTool` + `AfterAgent` + `AfterModel` + `SessionEnd` hooks
- Auto-installer: `./hooks/install.sh` (detects installed CLIs, merges config via jq)
- Clean uninstall: `./hooks/uninstall.sh`
- Sensitive file detection: shared `lib/sensitive-patterns.sh` for `.env`, credentials,
  keys, `.aws/` etc. — separate patterns for file paths vs commands to avoid false positives
- Fire-and-forget: hooks never block the AI assistant (`curl -s & disown`)
- Git context enrichment: `git_repo` + `git_branch` labels on all metrics

### Native OTel Integration

- Claude Code: metrics (`claude_code.*`) + logs via OTLP gRPC
- Codex CLI: logs + traces via OTLP gRPC; 15 Loki recording rules convert
  LogQL into Prometheus metrics (counts, tokens, latency)
- Gemini CLI: metrics (`gemini_cli.*`, `gen_ai.client.*`) + logs + traces via OTLP gRPC

### Dashboards (8)

- **Cost** (01): total spend, cost by model, token distribution, cache economics
- **Tools** (02): tool frequency, top 10, error rate, failing tools
- **Operations** (03): event rates by source/type, live event stream
- **Quality** (04): session KPIs, cache efficiency, latency percentiles, productivity ratio
- **Claude Code Deep Dive** (10): native OTel tokens/cost, active time, tool decisions
- **Codex Deep Dive** (11): recording-rule metrics, reasoning ratio, API latency
- **Gemini CLI Deep Dive** (12): model routing, tool latency heatmap, stats-for-nerds table
- **Session Timeline** (13): synthetic traces from all 3 CLIs, span-metrics stats,
  tool duration distribution, Tempo trace search

### Session Timeline

- Synthetic OTLP traces parsed from CLI session logs (JSONL/JSON)
- 3 dedicated parsers: Claude, Codex, Gemini — unified span schema
- Span types: session root, session meta, tool calls, MCP calls, sub-agents, compactions
- Tempo span-metrics generate `traces_spanmetrics_calls_total` and
  `traces_spanmetrics_latency_bucket` for stat/table panels

### Alerting (15 rules, 3 tiers)

- **Infrastructure** (6): OTelCollectorDown, CollectorExportFailed{Spans,Metrics,Logs},
  CollectorHighMemory, PrometheusHighMemory
- **Pipeline** (4): LokiDown, TempoDown, PrometheusTargetDown, LokiRecordingRulesFailing
- **Services** (5): HighSessionCost (>$10/hr), HighTokenBurn (>50k tok/min),
  HighToolErrorRate (>10%), SensitiveFileAccess, NoTelemetryReceived
- Inhibit rules: OTelCollectorDown suppresses business-logic alerts;
  LokiDown suppresses LokiRecordingRulesFailing + HighTokenBurn
- Alertmanager with Telegram, Slack, and Discord receivers (configurable)

### Documentation

- README with quick start, port map, data flow diagram
- CLAUDE.md with full architecture reference
- C4 architecture diagrams (rendered via `./scripts/render-c4.sh`)
