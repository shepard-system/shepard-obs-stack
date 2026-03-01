#!/usr/bin/env bash
# hooks/lib/sensitive-patterns.sh — detect access to sensitive files
#
# Usage: source this file, then call check_sensitive_access "$tool_input_json"
# Returns matched file path/command on stdout if sensitive, empty otherwise.

SENSITIVE_PATTERNS='(\.env$|\.env\.|credentials|secrets|\.pem$|\.key$|id_rsa|id_ed25519|\.p12$|password|token\.json|\.secret|\.aws/)'

check_sensitive_access() {
  local tool_input="$1"
  local file_path command

  file_path=$(jq -r '.file_path // .notebook_path // ""' <<< "$tool_input" 2>/dev/null || echo "")
  command=$(jq -r '.command // ""' <<< "$tool_input" 2>/dev/null || echo "")

  if echo "$file_path" | grep -qiE "$SENSITIVE_PATTERNS" 2>/dev/null; then
    echo "$file_path"
  elif echo "$command" | grep -qiE "$SENSITIVE_PATTERNS" 2>/dev/null; then
    echo "$command"
  fi
}
