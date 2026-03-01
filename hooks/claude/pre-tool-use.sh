#!/usr/bin/env bash
# hooks/claude/pre-tool-use.sh — Claude Code PreToolUse guard hook
#
# Stdin JSON:
#   { "session_id", "tool_name", "tool_input", "tool_use_id",
#     "transcript_path", "cwd", "permission_mode", "hook_event_name" }
#
# Blocks access to sensitive files (.env, credentials, keys, etc.) with exit 2.
# No metrics emission — PostToolUse already handles counting.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/sensitive-patterns.sh"

input="$(cat)"

tool_input="$(jq -r '.tool_input // "{}" | if type == "string" then . else tostring end' <<< "$input" 2>/dev/null || echo "{}")"

sensitive_match=$(check_sensitive_access "$tool_input")
if [[ -n "$sensitive_match" ]]; then
  echo "Blocked: access to sensitive file $sensitive_match" >&2
  exit 2
fi

exit 0
