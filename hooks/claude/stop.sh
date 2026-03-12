#!/usr/bin/env bash
# hooks/claude/stop.sh — Claude Code Stop hook
#
# Stdin JSON:
#   { "session_id", "transcript_path", "cwd", "hook_event_name",
#     "stop_hook_active", "last_assistant_message" }
#
# Emits: events_total(session_end) counter to Prometheus via OTel Collector.
# Then launches session-parser.sh in background to generate synthetic traces → Tempo.
# All token/cost/session metrics come from Claude's native OTel export.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Rust accelerator: full hook replacement
source "${SCRIPT_DIR}/../lib/accelerator.sh"
if [[ -n "$SHEPARD_HOOK" ]]; then
  "$SHEPARD_HOOK" hook claude stop
  exit $?
fi
source "${SCRIPT_DIR}/../lib/git-context.sh"
source "${SCRIPT_DIR}/../lib/metrics.sh"
source "${SCRIPT_DIR}/../lib/traces.sh"

input="$(cat)"

# Don't re-fire if already in a stop hook loop
stop_active="$(jq -r '.stop_hook_active // false' <<< "$input")"
[[ "$stop_active" == "true" ]] && exit 0

cwd="$(jq -r '.cwd // ""' <<< "$input")"
session_id="$(jq -r '.session_id // ""' <<< "$input")"

# Git context
get_git_context "$cwd"

# Emit session_end event
evt_labels=$(jq -n -c --arg s "claude-code" --arg e "session_end" --arg g "$GIT_REPO" \
  '{source:$s, event_type:$e, git_repo:$g}')
emit_counter "events" "1" "$evt_labels"

# --- Session log parser → synthetic traces to Tempo ---
# Locate JSONL session file: ~/.claude/projects/{slug}/{session_id}.jsonl
if [[ -n "$session_id" && -n "$cwd" ]]; then
  slug=$(echo "$cwd" | sed 's|/|-|g')
  session_file="${HOME}/.claude/projects/${slug}/${session_id}.jsonl"

  if [[ -f "$session_file" ]]; then
    # Emit compaction count if any compaction events occurred
    compaction_count=$(grep -c '"compact_boundary"' "$session_file" 2>/dev/null || true)
    if [[ "$compaction_count" -gt 0 ]]; then
      comp_labels=$(jq -n -c --arg s "claude-code" --arg g "$GIT_REPO" \
        '{source:$s, git_repo:$g}')
      emit_counter "compaction_events" "$compaction_count" "$comp_labels"
    fi

    # Parse session log, emit context metrics + traces — fully detached
    (
      parser_output=$(bash "${SCRIPT_DIR}/../lib/session-parser.sh" "$session_file")
      [[ -z "$parser_output" ]] && exit 0

      # Extract context breakdown from root span (first line) — single jq call
      context_data=$(echo "$parser_output" | head -1 | jq -r '[
        .attributes["context.tool_output_chars"] // "0",
        .attributes["context.user_prompt_chars"] // "0",
        .attributes["context.compact_summary_chars"] // "0",
        .attributes["context.compaction_pre_tokens"] // "0"
      ] | join("\t")')
      IFS=$'\t' read -r tool_chars user_chars summary_chars pre_tokens <<< "$context_data"

      # Emit context char metrics (by type) — only if > 0
      for pair in "tool_output:$tool_chars" "user_prompt:$user_chars" "compact_summary:$summary_chars"; do
        type="${pair%%:*}"; val="${pair#*:}"
        if [[ "$val" -gt 0 ]] 2>/dev/null; then
          labels=$(jq -n -c --arg s "claude-code" --arg t "$type" --arg g "$GIT_REPO" \
            '{source:$s, type:$t, git_repo:$g}')
          emit_counter "context_chars" "$val" "$labels"
        fi
      done

      # Emit compaction pre-tokens metric
      if [[ "$pre_tokens" -gt 0 ]] 2>/dev/null; then
        labels=$(jq -n -c --arg s "claude-code" --arg g "$GIT_REPO" \
          '{source:$s, git_repo:$g}')
        emit_counter "context_compaction_pre_tokens" "$pre_tokens" "$labels"
      fi

      # Emit traces to Tempo
      echo "$parser_output" | emit_spans "claude-code-session"
    ) </dev/null >/dev/null 2>&1 &
    disown
  fi
fi

exit 0
