#!/usr/bin/env bash
# hooks/claude/session-start.sh — Claude Code SessionStart hook (matcher: compact)
#
# Stdin JSON:
#   { "session_id", "transcript_path", "cwd", "permission_mode",
#     "hook_event_name", "source", "model" }
#
# Re-injects project conventions to stdout after context compaction.
# Claude sees stdout as context. Keep it concise and fast — no jq/curl/git needed.

cat <<'EOF'
[Post-compaction context — shepard-obs-stack]
- Metrics: shepherd_ prefix (OTel Collector Prometheus exporter namespace)
- Hook shell: set -u only (NOT set -euo pipefail — SIGPIPE kills)
- Fire-and-forget: emit_counter uses curl -s & disown — never block CLI
- Dashboards: edit JSON in configs/grafana/dashboards/ (UI edits lost on restart)
- PromQL: increase() returns floats → wrap in round() for counters
- Empty model labels: filter with model!=""
- Git identity: Shepard (digitalashes@users.noreply.github.com), GPG-signed
- Hook metrics: tool_calls, events, sensitive_file_access, compaction_events (all _total)
- Native OTel: dots→underscores (claude_code.cost_usage.USD → shepherd_claude_code_cost_usage_USD_total)
- Loki: service_name="claude-code" / "codex_cli_rs" / "gemini-cli"
- Session Timeline: Prometheus span-metrics (NOT Tempo local-blocks)
- PreToolUse guard active: blocks .env, credentials, .pem, .key, id_rsa, .aws/ etc.
EOF

exit 0
