#!/usr/bin/env bash
# hooks/claude/stop.sh — Claude Code Stop hook
#
# Stdin JSON:
#   { "session_id", "transcript_path", "cwd", "hook_event_name",
#     "stop_hook_active", "last_assistant_message" }
#
# Emits: events_total(session_end) counter to Prometheus via OTel Collector.
# All token/cost/session metrics come from Claude's native OTel export.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/git-context.sh"
source "${SCRIPT_DIR}/../lib/metrics.sh"

input="$(cat)"

# Don't re-fire if already in a stop hook loop
stop_active="$(jq -r '.stop_hook_active // false' <<< "$input")"
[[ "$stop_active" == "true" ]] && exit 0

cwd="$(jq -r '.cwd // ""' <<< "$input")"

# Git context
get_git_context "$cwd"

# Emit session_end event
evt_labels=$(jq -n -c --arg s "claude-code" --arg e "session_end" --arg g "$GIT_REPO" \
  '{source:$s, event_type:$e, git_repo:$g}')
emit_counter "events" "1" "$evt_labels"

exit 0
