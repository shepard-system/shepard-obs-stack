#!/usr/bin/env bash
# hooks/codex/notify.sh — Codex CLI notify hook
#
# Codex passes the event JSON as the first positional argument.
# Schema:
#   { "type": "agent-turn-complete", "thread-id", "turn-id", "cwd",
#     "input-messages", "last-assistant-message" }
#
# Emits: events_total counter to Prometheus via OTel Collector.
# Loki logs are handled by Codex native OTel export ({job="codex_cli_rs"}).
# Note: Codex notify payload has no token data — tokens always 0.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/git-context.sh"
source "${SCRIPT_DIR}/../lib/metrics.sh"

input="${1:-}"
[[ -z "$input" ]] && exit 0

event_type_raw="$(jq -r '.type // ""' <<< "$input")"
[[ "$event_type_raw" != "agent-turn-complete" ]] && exit 0

cwd="$(jq -r '.cwd // ""' <<< "$input")"

# Git context
get_git_context "$cwd"

# Emit OTLP metrics for Prometheus
evt_labels=$(jq -n -c --arg s "codex" --arg e "turn_end" --arg g "$GIT_REPO" \
  '{source:$s, event_type:$e, git_repo:$g}')
emit_counter "events"  "1"  "$evt_labels"

exit 0
