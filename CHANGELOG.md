# Changelog

All notable changes to shepard-obs-stack ("The Eye") are documented here.

## [Unreleased]

_Nothing yet._

## [1.3.0] — 2026-03-19

### Added

- **Comparative dashboard** (9th): side-by-side provider comparison with 5 rows, 14 panels —
  sessions, cost, tokens, cache efficiency, tool calls, errors, top repos, quality stats.
  Consistent provider color coding: Claude (purple), Gemini (green), Codex (amber).
  Template variable `$git_repo` for filtering hook metrics.
- **`/obs-compare` skill** — provider comparison from the CLI: sessions, cost, tokens,
  tool calls, errors, top repos in one report.

## [1.2.0] — 2026-03-19

### Added

- **Claude Code skills** (6 slash commands): `/obs-status`, `/obs-cost`, `/obs-sessions`,
  `/obs-tools`, `/obs-alerts`, `/obs-query` — query the obs stack directly from Claude Code
  without switching to the browser.
- **`scripts/obs-api.sh`** — centralized API client for all obs stack services. Auth-ready:
  supports `SHEPARD_API_TOKEN` (Bearer), `SHEPARD_CA_CERT` (TLS), `SHEPARD_GRAFANA_TOKEN`.
- **Per-session context breakdown** — session parser enriched with `context.*` attributes:
  character counts and token estimates for tool output, user prompts, compact summaries.
  Context Breakdown row added to Claude Deep Dive dashboard.
- **Per-turn spans** — `claude.turn` spans gated by `SHEPARD_DETAILED_TRACES=1` with
  per-turn token breakdown (input, output, cache read, cache create, tool count).
- **Hook metrics**: `shepherd_context_chars_total`, `shepherd_context_compaction_pre_tokens_total`.
- **Test suite** (128 tests, 4 suites): shell syntax (24), config validation (26),
  hook behavior (41), session parsers (37). Run with `bash tests/run-all.sh`.
- **CI workflow** (`.github/workflows/test.yml`): unit tests + Docker E2E smoke.
- **Loki scrape job** in Prometheus (`loki:3100`) for proper health monitoring.
- **ShepherdServicesDown** alert for OTel Collector Prometheus exporter (port 8889).
- **Alert regression tests** — rule counts per file + expression guards.

### Fixed

- **LokiDown alert** — split from collector exporter check into dedicated Loki scrape job.
- **All dashboard PromQL** — fixed for per-session native OTel metrics (`max_over_time`
  instead of `increase`, `round()` on all integer counters).
- **Compaction arithmetic error in stop.sh**.

### Changed

- Alert count: 15 → 16 rules (LokiDown split into LokiDown + ShepherdServicesDown).
- Dashboard count: 8 → 9.
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
