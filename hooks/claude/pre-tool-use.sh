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

# Extract file_path only — guard blocks direct file access tools (Read, Write, Edit, Glob)
# Bash command checking is intentionally skipped here to avoid false positives
# (e.g. "aws configure export-credentials"). PostToolUse still counts command-based access.
file_path="$(jq -r '.tool_input // {} | if type == "string" then . else . end | .file_path // .notebook_path // ""' <<< "$input" 2>/dev/null || echo "")"

if [[ -n "$file_path" ]] && echo "$file_path" | grep -qiE "$SENSITIVE_FILE_PATTERNS" 2>/dev/null; then
  echo "Blocked: access to sensitive file $file_path" >&2
  exit 2
fi

exit 0
