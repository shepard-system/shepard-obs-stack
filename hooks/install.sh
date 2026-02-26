#!/usr/bin/env bash
# hooks/install.sh — auto-detect AI CLIs and inject hook configs
#
# Usage:
#   ./hooks/install.sh              # install all detected CLIs
#   ./hooks/install.sh claude       # install only Claude Code
#   ./hooks/install.sh codex gemini # install Codex + Gemini
#
# Supported providers: claude, codex, gemini

set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLED=0

green()  { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
red()    { printf '\033[31m%s\033[0m\n' "$1"; }

# ── Claude Code ──────────────────────────────────────────────────────

install_claude() {
  local config_dir="$HOME/.claude"
  local config_file="$config_dir/settings.json"

  if ! command -v claude &>/dev/null; then
    yellow "Claude Code  — not found, skipping"
    return
  fi

  mkdir -p "$config_dir"

  # Back up existing config
  if [[ -f "$config_file" ]]; then
    cp "$config_file" "${config_file}.bak.$(date +%s)"
  fi

  # Read existing config or start fresh
  local existing='{}'
  [[ -f "$config_file" ]] && existing="$(cat "$config_file")"

  # Merge hooks into existing config
  local hook_config
  hook_config=$(jq -n \
    --arg post_tool "${HOOKS_DIR}/claude/post-tool-use.sh" \
    --arg stop "${HOOKS_DIR}/claude/stop.sh" \
    '{
      hooks: {
        PostToolUse: [{
          hooks: [{
            type: "command",
            command: $post_tool
          }]
        }],
        Stop: [{
          hooks: [{
            type: "command",
            command: $stop
          }]
        }]
      }
    }')

  # Native OTel: env vars scoped to Claude Code via settings.json "env" block
  local otel_env
  otel_env=$(jq -n '{
    env: {
      "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
      "OTEL_METRICS_EXPORTER": "otlp",
      "OTEL_LOGS_EXPORTER": "otlp",
      "OTEL_EXPORTER_OTLP_PROTOCOL": "grpc",
      "OTEL_EXPORTER_OTLP_ENDPOINT": "http://localhost:4317",
      "OTEL_METRIC_EXPORT_INTERVAL": "10000",
      "OTEL_LOGS_EXPORT_INTERVAL": "5000",
      "OTEL_LOG_TOOL_DETAILS": "1"
    }
  }')

  # Deep merge: existing config + hooks + native OTel env
  echo "$existing" | jq --argjson hooks "$hook_config" --argjson otel "$otel_env" '. * $hooks * $otel' > "$config_file"

  green "Claude Code  — hooks + native OTel installed → $config_file"

  INSTALLED=$((INSTALLED + 1))
}

# ── Codex CLI ────────────────────────────────────────────────────────

install_codex() {
  local config_dir="$HOME/.codex"
  local config_file="$config_dir/config.toml"

  if ! command -v codex &>/dev/null; then
    yellow "Codex CLI    — not found, skipping"
    return
  fi

  mkdir -p "$config_dir"

  # Back up existing config
  if [[ -f "$config_file" ]]; then
    cp "$config_file" "${config_file}.bak.$(date +%s)"
  fi

  local notify_line="notify = [\"/bin/bash\", \"${HOOKS_DIR}/codex/notify.sh\"]"

  if [[ -f "$config_file" ]] && grep -q '^notify' "$config_file"; then
    # Replace existing notify line
    sed -i.tmp "s|^notify.*|${notify_line}|" "$config_file"
    rm -f "${config_file}.tmp"
  elif [[ -f "$config_file" ]]; then
    # Prepend notify line before any sections
    local tmp
    tmp=$(mktemp)
    echo "$notify_line" > "$tmp"
    echo "" >> "$tmp"
    cat "$config_file" >> "$tmp"
    mv "$tmp" "$config_file"
  else
    echo "$notify_line" > "$config_file"
  fi

  # Native OTel: add [otel] section if not present
  if ! grep -q '^\[otel\]' "$config_file" 2>/dev/null; then
    cat >> "$config_file" <<'OTEL_EOF'

[otel]
environment = "dev"
exporter = { otlp-grpc = { endpoint = "http://localhost:4317" } }
trace_exporter = { otlp-grpc = { endpoint = "http://localhost:4317" } }
OTEL_EOF
    green "Codex CLI    — native OTel (logs + traces) added → $config_file"
  fi

  green "Codex CLI    — hooks installed → $config_file"
  INSTALLED=$((INSTALLED + 1))
}

# ── Gemini CLI ───────────────────────────────────────────────────────

install_gemini() {
  local config_dir="$HOME/.gemini"
  local config_file="$config_dir/settings.json"

  if ! command -v gemini &>/dev/null; then
    yellow "Gemini CLI   — not found, skipping"
    return
  fi

  mkdir -p "$config_dir"

  # Back up existing config
  if [[ -f "$config_file" ]]; then
    cp "$config_file" "${config_file}.bak.$(date +%s)"
  fi

  local existing='{}'
  [[ -f "$config_file" ]] && existing="$(cat "$config_file")"

  local hook_config
  hook_config=$(jq -n \
    --arg after_tool "${HOOKS_DIR}/gemini/after-tool.sh" \
    --arg after_agent "${HOOKS_DIR}/gemini/after-agent.sh" \
    --arg after_model "${HOOKS_DIR}/gemini/after-model.sh" \
    --arg session_end "${HOOKS_DIR}/gemini/session-end.sh" \
    '{
      hooks: {
        AfterTool: [{
          command: ["bash", $after_tool]
        }],
        AfterAgent: [{
          command: ["bash", $after_agent]
        }],
        AfterModel: [{
          command: ["bash", $after_model]
        }],
        SessionEnd: [{
          command: ["bash", $session_end]
        }]
      }
    }')

  # Merge hooks + native OTel telemetry config
  local telemetry_config
  telemetry_config=$(jq -n '{
    telemetry: {
      enabled: true,
      target: "local",
      otlpEndpoint: "http://localhost:4317",
      otlpProtocol: "grpc"
    }
  }')

  echo "$existing" | jq --argjson hooks "$hook_config" --argjson telem "$telemetry_config" '. * $hooks * $telem' > "$config_file"

  green "Gemini CLI   — hooks + native OTel installed → $config_file"
  INSTALLED=$((INSTALLED + 1))
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
      echo "  No args  — install all detected CLIs"
      echo "  With args — install only specified providers"
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

echo "shepherd-hooks installer"
echo "========================"
echo ""

# Make all hooks executable
chmod +x "${HOOKS_DIR}"/claude/*.sh 2>/dev/null || true
chmod +x "${HOOKS_DIR}"/codex/*.sh 2>/dev/null || true
chmod +x "${HOOKS_DIR}"/gemini/*.sh 2>/dev/null || true
chmod +x "${HOOKS_DIR}"/lib/*.sh 2>/dev/null || true

for provider in "${PROVIDERS[@]}"; do
  "install_${provider}"
done

echo ""
if [[ $INSTALLED -eq 0 ]]; then
  red "No supported CLIs found. Install Claude Code, Codex, or Gemini CLI first."
  exit 1
fi

echo "${INSTALLED} CLI(s) configured. Start the obs stack:"
echo "  docker compose up -d"
echo ""
echo "Verify with:"
echo "  ./scripts/test-signal.sh"
