# shepard-obs-stack

[![Grafana](https://img.shields.io/badge/Grafana-12.4.0-F46800?logo=grafana&logoColor=white)](https://grafana.com/)
[![Prometheus](https://img.shields.io/badge/Prometheus-v3.9.1-E6522C?logo=prometheus&logoColor=white)](https://prometheus.io/)
[![Loki](https://img.shields.io/badge/Loki-3.6.7-2C3239?logo=grafana&logoColor=white)](https://grafana.com/oss/loki/)
[![OTel Collector](https://img.shields.io/badge/OTel_Collector-0.146.0-4B44CE?logo=opentelemetry&logoColor=white)](https://opentelemetry.io/docs/collector/)
[![License: Elastic-2.0](https://img.shields.io/badge/License-Elastic--2.0-blue.svg)](LICENSE)
[![Tests](https://github.com/shepard-system/shepard-obs-stack/actions/workflows/test.yml/badge.svg)](https://github.com/shepard-system/shepard-obs-stack/actions/workflows/test.yml)

**The Eye** — self-hosted observability for AI coding assistants.

You use Claude Code, Codex, or Gemini CLI every day.
You have no idea how much they cost, which tools they call, or whether they're actually helping.
This fixes that.

![Cost Dashboard](docs/screenshots/cost-dashboard.png)

<details>
<summary>More screenshots</summary>

**Tools** — 5K calls across all three CLIs, top tools ranked, failing tools by error count:

![Tools Dashboard](docs/screenshots/tools-dashboard.png)

**Operations** — live event rate, breakdown by source and event type:

![Operations Dashboard](docs/screenshots/operations-dashboard.png)

**Claude Code Deep Dive** — per-model cost, token breakdown, cache efficiency, productivity ratio:

![Claude Deep Dive](docs/screenshots/claude-deep-dive.png)

**Claude Code Deep Dive (Tools)** — tool decisions, active time breakdown:

![Claude Deep Dive Tools](docs/screenshots/claude-deep-dive-tools.png)

**Quality** — cache hit rates, error rates, session trends:

![Quality Dashboard](docs/screenshots/quality-dashboard.png)

</details>

## Table of Contents

- [Highlights](#highlights)
- [Quick Start](#quick-start)
- [Dashboards](#dashboards)
- [How It Works](#how-it-works)
- [Hook Setup](#hook-setup)
- [Rust Accelerator](#rust-accelerator-optional)
- [Alerting](#alerting)
- [Services](#services)
- [Architecture](#architecture)
- [Project Structure](#project-structure)
- [Contributing](#contributing)
- [License](#license)

## Highlights

- **One command** to start: `./scripts/init.sh` — 6 services, 8 dashboards, under a minute
- **Three CLIs supported**: Claude Code, Codex, Gemini CLI — hooks + native OpenTelemetry
- **Eight Grafana dashboards** auto-provisioned: cost, tools, operations, quality, per-provider deep dives, and session timeline
- **Minimal dependencies** — Docker, plus `bash`, `curl`, and `jq` on the host for hooks and tests. No Python, no Node, no cloud accounts
- **Optional [Rust accelerator](https://github.com/shepard-system/shepard-hooks-rs)** — drop-in `shepard-hook` binary replaces bash+jq+curl. Hooks auto-detect it; falls back to bash if absent
- **Works offline** — everything runs on localhost, your data stays on your machine

## Quick Start

**Prerequisites:** Docker (with Compose v2), `curl`, `jq`, and at least one AI CLI installed.

```bash
git clone https://github.com/shepard-system/shepard-obs-stack.git
cd shepard-obs-stack
./scripts/init.sh          # starts stack + health check
./hooks/install.sh         # injects hooks into your CLI configs
```

Open [localhost:3000](http://localhost:3000) (admin / shepherd). Use your CLI as usual — data appears in dashboards within seconds.

```bash
./scripts/test-signal.sh   # verify the full pipeline (11 checks)
```

## Dashboards

### Unified (cross-provider)

| Dashboard      | Question it answers                     |
|----------------|-----------------------------------------|
| **Cost**       | How much is this costing me?            |
| **Tools**      | Who is performing and who is wandering? |
| **Operations** | What is happening right now?            |
| **Quality**    | How well is the system working?         |

### Deep Dive (per-provider)

| Dashboard       | What you see                                            |
|-----------------|---------------------------------------------------------|
| **Claude Code** | Token usage, cost by model, tool decisions, active time |
| **Codex**       | Sessions, API latency percentiles, reasoning tokens     |
| **Gemini CLI**  | Token breakdown, latency heatmap, tool call routing     |

### Session Timeline

| Dashboard            | What you see                                                                               |
|----------------------|--------------------------------------------------------------------------------------------|
| **Session Timeline** | Synthetic traces from all 3 CLI session logs — tool call waterfall, MCP timing, sub-agents |

Click any Trace ID to open the full waterfall in Grafana Explore → Tempo.

Dashboard template variables: **Tools** and **Operations** support `$source` and `$git_repo` filtering. 
**Deep Dive** dashboards use `$model`. **Session Timeline** uses `$provider`. **Cost** and **Quality** show aggregated data without filters.

## How It Works

AI CLIs emit telemetry through two channels:

```
AI CLI (Claude Code / Codex / Gemini)
    │
    ├── bash hooks → OTLP metrics (tool calls, events, git context)
    │                 └─→ OTel Collector :4318
    │
    └── native OTel → gRPC (tokens, cost, logs, traces)
                       └─→ OTel Collector :4317
                             │
                             ├── metrics → Prometheus :9090
                             ├── logs → Loki :3100
                             └── traces → Tempo :3200
                                           │
Loki recording rules ──── remote_write ───→ Prometheus
                                           │
Grafana :3000 ←── PromQL + LogQL ──────────┘
```

**Hooks** provide what native OTel cannot: git repo context and labeled tool/event counters. 
Everything else (tokens, cost, sessions) comes from native OTel export.

## Hook Setup

```bash
./hooks/install.sh              # all detected CLIs
./hooks/install.sh claude       # specific CLI
./hooks/install.sh codex gemini # selective
./hooks/uninstall.sh            # clean removal
```

The installer auto-detects installed CLIs and merges hook configuration into their config files (creating backups first).

| CLI         | Hooks                                                 | Native OTel signals     |
|-------------|-------------------------------------------------------|-------------------------|
| Claude Code | `PreToolUse`, `PostToolUse`, `SessionStart`, `Stop`   | metrics + logs          |
| Codex CLI   | `agent-turn-complete`                                 | logs                    |
| Gemini CLI  | `AfterTool`, `AfterAgent`, `AfterModel`, `SessionEnd` | metrics + logs + traces |

## Rust Accelerator (optional)

All hooks work out of the box with bash + jq + curl. For faster execution, you can optionally install the [Rust accelerator](https://github.com/shepard-system/shepard-hooks-rs) — a single static binary that replaces the entire bash pipeline:

```bash
./scripts/install-accelerator.sh           # latest release → hooks/bin/ (no sudo)
./scripts/install-accelerator.sh v0.1.0    # specific version
```

The installer downloads a pre-built binary from [GitHub Releases](https://github.com/shepard-system/shepard-hooks-rs/releases) (linux/macOS, x64/arm64) and verifies it against the `SHA256SUMS` file published with each release. The binary is placed in `hooks/bin/` (gitignored, project-local).

Hooks auto-detect it via `hooks/lib/accelerator.sh` (project-local → PATH → bash fallback). No configuration needed — if the binary is present, hooks use it; if not, they fall back to bash.

Remove with `./hooks/uninstall.sh` or simply delete `hooks/bin/`.

## Alerting

Alertmanager runs on :9093 with 15 alert rules in three tiers:

| Tier               | Alerts | Examples                                                                                                                              |
|--------------------|--------|---------------------------------------------------------------------------------------------------------------------------------------|
| **Infrastructure** | 6      | `OTelCollectorDown`, `TempoDown`, `CollectorHighMemory`, export failures                                                              |
| **Pipeline**       | 4      | `LokiDown`, `PrometheusTargetDown`, `TempoDown`, `LokiRecordingRulesFailing`                                                          |
| **Business logic** | 5      | `HighSessionCost` (>$10/hr), `HighTokenBurn` (>50k tok/min), `HighToolErrorRate` (>10%), `SensitiveFileAccess`, `NoTelemetryReceived` |

Inhibit rules suppress business-logic alerts when infrastructure is down.

Native Telegram, Slack, and Discord receivers are included — uncomment and configure in `configs/alertmanager/alertmanager.yaml`:

```yaml
# telegram_configs:
#   - bot_token: 'YOUR_BOT_TOKEN'
#     chat_id: YOUR_CHAT_ID
#     send_resolved: true
```

## Services

| Service        | Port      | Purpose              |
|----------------|-----------|----------------------|
| Grafana        | 3000      | Dashboards & explore |
| Prometheus     | 9090      | Metrics & alerts     |
| Loki           | 3100      | Log aggregation      |
| Tempo          | 3200      | Distributed tracing  |
| Alertmanager   | 9093      | Alert routing        |
| OTel Collector | 4317/4318 | OTLP gRPC + HTTP     |

## Architecture

<details>
<summary>C4 diagrams (click to expand)</summary>

### System Context

![C1 System Context](docs/c4/c1-system-context.svg)

### Containers

![C2 Container](docs/c4/c2-container.svg)

### Hook Components

![C3 Hook Components](docs/c4/c3-hooks-components.svg)

### Hook Event Flow

![C4 Hook Event Flow](docs/c4/c4-hook-event-flow.svg)

### Event Schema Normalization

![C5 Event Schema Normalization](docs/c4/c5-event-schema-normalization.svg)

</details>

## Project Structure

```
shepard-obs-stack/
├── docker-compose.yaml
├── .env.example
├── hooks/
│   ├── bin/                   # Rust accelerator binary (gitignored, downloaded)
│   ├── lib/                   # shared: accelerator, git context, OTLP metrics + traces, sensitive file detection, session parser
│   ├── claude/                # PreToolUse + PostToolUse + SessionStart + Stop
│   ├── codex/                 # notify.sh (agent-turn-complete)
│   ├── gemini/                # AfterTool + AfterAgent + AfterModel + SessionEnd
│   ├── install.sh             # auto-detect + inject
│   └── uninstall.sh           # clean removal
├── scripts/
│   ├── init.sh                # bootstrap
│   ├── install-accelerator.sh # download Rust accelerator to hooks/bin/
│   ├── test-signal.sh         # pipeline verification (11 checks)
│   └── render-c4.sh           # render PlantUML → SVG
├── tests/
│   ├── run-all.sh             # test orchestrator (--e2e for Docker smoke)
│   ├── test-shell-syntax.sh   # bash -n + shellcheck
│   ├── test-config-validate.sh # JSON + YAML validation
│   ├── test-hooks.sh          # behavioral tests (21 tests)
│   ├── test-parsers.sh        # session parser tests (24 tests)
│   └── fixtures/              # minimal session logs (Claude, Codex, Gemini)
├── configs/
│   ├── otel-collector/        # receivers → processors → exporters
│   ├── prometheus/            # scrape targets + alert rules
│   ├── alertmanager/          # routing, Telegram/Slack/Discord receivers
│   ├── loki/                  # storage + 15 recording rules
│   ├── tempo/                 # trace storage, 7d retention
│   └── grafana/               # provisioning + 8 dashboard JSONs
└── docs/c4/                   # architecture diagrams
```

## Testing

87 automated tests across 4 suites, plus a Docker-based E2E smoke test:

```bash
bash tests/run-all.sh         # unit tests: syntax, configs, hooks, parsers
bash tests/run-all.sh --e2e   # + Docker E2E (starts stack, runs test-signal.sh)
```

| Suite | Tests | What it checks |
|-------|-------|----------------|
| Shell Syntax | 23 | `bash -n` on all scripts, shellcheck (if installed) |
| Config Validation | 19 | JSON dashboards (jq) + YAML configs (PyYAML) |
| Hook Behavior | 21 | PreToolUse guard, PostToolUse metrics, Stop compaction, SessionStart, Gemini/Codex |
| Session Parsers | 24 | Span count, required fields, attributes, error status, trace_id consistency |

CI runs automatically on push/PR via [GitHub Actions](.github/workflows/test.yml).

## Contributing

Issues and pull requests are welcome. Before submitting changes, run the tests:

```bash
bash tests/run-all.sh
```

## License

[Elastic License 2.0](LICENSE) — free to use, modify, and distribute. Cannot be offered as a hosted or managed service.

Part of the [Shepard System](https://github.com/shepard-system).
