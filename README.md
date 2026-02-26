# shepard-obs-stack

[![Grafana](https://img.shields.io/badge/Grafana-12.4.0-F46800?logo=grafana&logoColor=white)](https://grafana.com/)
[![Prometheus](https://img.shields.io/badge/Prometheus-v3.9.1-E6522C?logo=prometheus&logoColor=white)](https://prometheus.io/)
[![Loki](https://img.shields.io/badge/Loki-3.6.7-2C3239?logo=grafana&logoColor=white)](https://grafana.com/oss/loki/)
[![Tempo](https://img.shields.io/badge/Tempo-2.10.1-2C3239?logo=grafana&logoColor=white)](https://grafana.com/oss/tempo/)
[![OTel Collector](https://img.shields.io/badge/OTel_Collector-0.146.0-4B44CE?logo=opentelemetry&logoColor=white)](https://opentelemetry.io/docs/collector/)
[![Alertmanager](https://img.shields.io/badge/Alertmanager-v0.30.1-E6522C?logo=prometheus&logoColor=white)](https://prometheus.io/docs/alerting/latest/alertmanager/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**The Eye** — observability infrastructure for AI coding assistants.

A cloneable repo. A `docker compose` you can run. Seven dashboards you can see in ten minutes.

## Architecture

### System Context

![C1 System Context](docs/c4/c1-system-context.svg)

### Containers

![C2 Container](docs/c4/c2-container.svg)

## Quick Start

```bash
git clone https://github.com/shepard-system/shepard-obs-stack.git
cd shepard-obs-stack
./scripts/init.sh
```

Open [http://localhost:3000](http://localhost:3000) (admin / shepherd) — 7 dashboards in the **Shepherd** folder.

## Data Flow

Hooks emit **OTLP metrics** (git context + labeled counters). Logs and traces come from **native OTel export**.

```
AI CLI (Claude Code / Codex / Gemini)
    ├── hooks/*.sh → OTel Collector :4318 (OTLP metrics)
    └── native OTel → OTel Collector :4317 (gRPC)
        ├── metrics → Prometheus
        ├── logs → Loki
        └── traces → Tempo
    ▼
Loki recording rules → Prometheus (Codex metrics, 15 rules, 1m)
    ▼
Grafana: PromQL + LogQL → 7 dashboards
    ▲
Prometheus → Alertmanager → webhook
```

## Dashboards

### Unified (01–04)

Aggregate across all providers. `$source` and `$git_repo` template variables.

| Dashboard      | Question it answers                     |
|----------------|-----------------------------------------|
| **Cost**       | How much is this costing me?            |
| **Tools**      | Who is performing and who is wandering? |
| **Operations** | What is happening right now?            |
| **Quality**    | How well is the system working?         |

### Deep-Dive (10–12)

Provider-specific dashboards using **native OTel telemetry**.

| Dashboard                 | Data Source                         |
|---------------------------|-------------------------------------|
| **Claude Code Deep Dive** | Prometheus + Loki                   |
| **Codex Deep Dive**       | Prometheus (recording rules) + Loki |
| **Gemini CLI Deep Dive**  | Prometheus + Loki                   |

All 7 dashboards auto-provision on `docker compose up`.

## Hook Setup

```bash
./hooks/install.sh              # all detected CLIs
./hooks/install.sh claude       # specific provider
./hooks/install.sh codex gemini # selective
```

Detects installed CLIs and injects hook configuration + native OTel export:

| CLI         | Hook Events                                           | Config File               |
|-------------|-------------------------------------------------------|---------------------------|
| Claude Code | `PostToolUse`, `Stop` + native OTel via `"env"` block | `~/.claude/settings.json` |
| Codex CLI   | `agent-turn-complete` + `[otel]` gRPC export          | `~/.codex/config.toml`    |
| Gemini CLI  | `AfterTool`, `AfterAgent`, `AfterModel`, `SessionEnd` + telemetry | `~/.gemini/settings.json` |

```bash
./hooks/uninstall.sh            # remove all hooks + native OTel
./scripts/test-signal.sh        # verify pipeline
```

## Services

| Service        | Port | Purpose                   |
|----------------|------|---------------------------|
| Grafana        | 3000 | Dashboards & explore      |
| Loki           | 3100 | Log aggregation (LogQL)   |
| Prometheus     | 9090 | Metrics & alerts (PromQL) |
| Alertmanager   | 9093 | Alert routing & webhooks  |
| Tempo          | 3200 | Distributed tracing       |
| OTel Collector | 4317 | OTLP gRPC receiver        |
| OTel Collector | 4318 | OTLP HTTP receiver        |

## Project Structure

```
shepard-obs-stack/
├── docker-compose.yaml
├── .env.example
├── hooks/
│   ├── lib/
│   │   ├── git-context.sh   ← Extract git repo + branch from cwd
│   │   └── metrics.sh       ← OTLP metric emission via OTel Collector
│   ├── claude/              ← PostToolUse + Stop handlers
│   ├── codex/               ← agent-turn-complete handler
│   ├── gemini/              ← AfterTool + AfterAgent + AfterModel + SessionEnd
│   ├── install.sh           ← Auto-detect CLIs + inject configs
│   └── uninstall.sh         ← Remove hooks from CLI configs
├── scripts/
│   ├── init.sh              ← Bootstrap: env, docker compose up, health check
│   ├── test-signal.sh       ← Verify pipeline
│   └── render-c4.sh         ← Render C4 diagrams to SVG (requires Docker)
├── configs/
│   ├── otel-collector/      ← OTLP receivers → deltatocumulative → batch → exporters
│   ├── prometheus/          ← Scrape targets + alert rules
│   ├── alertmanager/        ← Alert routing, webhook receiver, inhibit rules
│   ├── loki/                ← Log storage, 7d retention, recording rules
│   ├── tempo/               ← Trace storage, 7d retention
│   └── grafana/
│       ├── provisioning/    ← Datasources + dashboard provider
│       └── dashboards/      ← 7 JSON dashboards (4 unified + 3 deep-dive)
└── docs/c4/                 ← C4 architecture diagrams (.puml + .svg)
```

## License

MIT — see [LICENSE](LICENSE).

Part of the [Shepard System](https://github.com/shepard-system).
