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
source "${SCRIPT_DIR}/../lib/traces.sh"

input="${1:-}"
[[ -z "$input" ]] && exit 0

event_type_raw="$(jq -r '.type // ""' <<< "$input")"
[[ "$event_type_raw" != "agent-turn-complete" ]] && exit 0

cwd="$(jq -r '.cwd // ""' <<< "$input")"
thread_id="$(jq -r '.["thread-id"] // ""' <<< "$input")"

# Git context
get_git_context "$cwd"

# Emit OTLP metrics for Prometheus
evt_labels=$(jq -n -c --arg s "codex" --arg e "turn_end" --arg g "$GIT_REPO" \
  '{source:$s, event_type:$e, git_repo:$g}')
emit_counter "events"  "1"  "$evt_labels"

# --- Session log parser → synthetic traces to Tempo ---
# Locate JSONL: ~/.codex/sessions/YYYY/MM/DD/rollout-*-{thread_id}.jsonl
if [[ -n "$thread_id" ]]; then
  session_dir="${HOME}/.codex/sessions/$(date -u +%Y/%m/%d)"
  session_file=$(ls -t "${session_dir}"/rollout-*-"${thread_id}".jsonl 2>/dev/null | head -1)

  if [[ -n "$session_file" && -f "$session_file" ]]; then
    (
      bash "${SCRIPT_DIR}/../lib/codex-session-parser.sh" "$session_file" \
        | emit_spans "codex-session"
    ) </dev/null >/dev/null 2>&1 &
    disown
  fi
fi

exit 0
