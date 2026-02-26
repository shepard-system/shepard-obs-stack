#!/usr/bin/env bash
# hooks/uninstall.sh — remove shepherd hooks from AI CLI configs
#
# Usage:
#   ./hooks/uninstall.sh              # uninstall all
#   ./hooks/uninstall.sh claude       # uninstall only Claude Code
#   ./hooks/uninstall.sh codex gemini # uninstall Codex + Gemini
#
# Supported providers: claude, codex, gemini

set -euo pipefail

REMOVED=0

green()  { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
red()    { printf '\033[31m%s\033[0m\n' "$1"; }

# ── Claude Code ──────────────────────────────────────────────────────

uninstall_claude() {
  local config_file="$HOME/.claude/settings.json"

  if [[ ! -f "$config_file" ]]; then
    yellow "Claude Code  — no config found, skipping"
    return
  fi

  if ! jq -e '.hooks' "$config_file" &>/dev/null; then
    yellow "Claude Code  — no hooks configured, skipping"
    return
  fi

  # Remove hooks + native OTel env block, keep everything else
  local tmp
  tmp=$(mktemp)
  jq 'del(.hooks) | del(.env)' "$config_file" > "$tmp" && mv "$tmp" "$config_file"

  green "Claude Code  — hooks + native OTel removed from $config_file"
  REMOVED=$((REMOVED + 1))
}

# ── Codex CLI ────────────────────────────────────────────────────────

uninstall_codex() {
  local config_file="$HOME/.codex/config.toml"

  if [[ ! -f "$config_file" ]]; then
    yellow "Codex CLI    — no config found, skipping"
    return
  fi

  if ! grep -q '^notify' "$config_file"; then
    yellow "Codex CLI    — no hooks configured, skipping"
    return
  fi

  # Remove the notify line
  sed -i.tmp '/^notify/d' "$config_file"
  rm -f "${config_file}.tmp"

  # Remove [otel] section and its contents
  if grep -q '^\[otel\]' "$config_file" 2>/dev/null; then
    sed -i.tmp '/^\[otel\]/,/^\[/{/^\[otel\]/d;/^\[/!d;}' "$config_file"
    rm -f "${config_file}.tmp"
    green "Codex CLI    — native OTel config removed"
  fi

  # Remove empty file if nothing left
  if [[ ! -s "$config_file" ]] || [[ "$(tr -d '[:space:]' < "$config_file")" == "" ]]; then
    rm -f "$config_file"
  fi

  green "Codex CLI    — hooks removed from $config_file"
  REMOVED=$((REMOVED + 1))
}

# ── Gemini CLI ───────────────────────────────────────────────────────

uninstall_gemini() {
  local config_file="$HOME/.gemini/settings.json"

  if [[ ! -f "$config_file" ]]; then
    yellow "Gemini CLI   — no config found, skipping"
    return
  fi

  if ! jq -e '.hooks' "$config_file" &>/dev/null; then
    yellow "Gemini CLI   — no hooks configured, skipping"
    return
  fi

  local tmp
  tmp=$(mktemp)
  jq 'del(.hooks) | del(.telemetry)' "$config_file" > "$tmp" && mv "$tmp" "$config_file"

  green "Gemini CLI   — hooks + native OTel removed from $config_file"
  REMOVED=$((REMOVED + 1))
}

# ── Main ─────────────────────────────────────────────────────────────

PROVIDERS=("$@")
ALL_PROVIDERS=(claude codex gemini)

# Validate arguments
for p in "${PROVIDERS[@]}"; do
  case "$p" in
    claude|codex|gemini) ;;
    -h|--help)
      echo "Usage: $0 [claude] [codex] [gemini]"
      echo ""
      echo "  No args  — uninstall all"
      echo "  With args — uninstall only specified providers"
      exit 0
      ;;
    *)
      red "Unknown provider: $p"
      echo "Supported: claude, codex, gemini"
      exit 1
      ;;
  esac
done

# Default to all if no args
if [[ ${#PROVIDERS[@]} -eq 0 ]]; then
  PROVIDERS=("${ALL_PROVIDERS[@]}")
fi

echo "shepherd-hooks uninstaller"
echo "=========================="
echo ""

for provider in "${PROVIDERS[@]}"; do
  "uninstall_${provider}"
done

echo ""
if [[ $REMOVED -eq 0 ]]; then
  echo "Nothing to remove."
else
  echo "${REMOVED} CLI(s) cleaned up."
fi
