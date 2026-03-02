#!/usr/bin/env bash
# hooks/lib/sensitive-patterns.sh — detect access to sensitive files
#
# Usage: source this file, then call check_sensitive_access "$tool_input_json"
# Returns matched file path/command on stdout if sensitive, empty otherwise.

# File path patterns — checked against file_path and notebook_path
SENSITIVE_FILE_PATTERNS='(\.env$|\.env\.|credentials|secrets|\.pem$|\.key$|id_rsa|id_ed25519|\.p12$|password|token\.json|\.secret|\.aws/)'

# Command patterns — more specific to avoid false positives (e.g. "aws configure export-credentials")
SENSITIVE_CMD_PATTERNS='(\.env[[:space:]]|\.env$|/\.env|credentials\.|credentials/|/secrets/|/secrets$|\.pem[[:space:]]|\.pem$|\.key[[:space:]]|\.key$|id_rsa|id_ed25519|\.p12[[:space:]]|\.p12$|token\.json|\.secret|\.aws/)'

check_sensitive_access() {
  local tool_input="$1"
  local file_path command

  file_path=$(jq -r '.file_path // .notebook_path // ""' <<< "$tool_input" 2>/dev/null || echo "")
  command=$(jq -r '.command // ""' <<< "$tool_input" 2>/dev/null || echo "")

  if echo "$file_path" | grep -qiE "$SENSITIVE_FILE_PATTERNS" 2>/dev/null; then
    echo "$file_path"
  elif echo "$command" | grep -qiE "$SENSITIVE_CMD_PATTERNS" 2>/dev/null; then
    echo "$command"
  fi
}
