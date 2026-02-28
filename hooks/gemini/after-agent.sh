#!/usr/bin/env bash
# hooks/gemini/after-agent.sh — Gemini CLI AfterAgent hook
#
# Fires after the agent loop completes (once per turn).
# Gemini passes agent context on stdin (JSON).
# Env vars: GEMINI_SESSION_ID, GEMINI_PROJECT_DIR, GEMINI_CWD
#
# Must output valid JSON to stdout.
# Emits: events_total counter to Prometheus via OTel Collector.
# Loki logs are handled by Gemini's native OTel export.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/git-context.sh"
source "${SCRIPT_DIR}/../lib/metrics.sh"

input="$(cat)"

cwd="$(jq -r '.cwd // ""' <<< "$input" 2>/dev/null)"
[[ -z "$cwd" ]] && cwd="${GEMINI_CWD:-${GEMINI_PROJECT_DIR:-}}"

# Git context
get_git_context "$cwd"

# Emit OTLP metrics for Prometheus
evt_labels=$(jq -n -c --arg s "gemini-cli" --arg e "turn_end" --arg g "$GIT_REPO" \
  '{source:$s, event_type:$e, git_repo:$g}')
emit_counter "events"  "1"  "$evt_labels"

# Gemini requires JSON output on stdout
echo '{}'
exit 0
