#!/usr/bin/env bash
# hooks/lib/session-parser.sh — parse Claude Code JSONL session logs into trace data
#
# Usage: bash session-parser.sh /path/to/session.jsonl
#
# Reads a Claude Code session JSONL file, extracts tool calls with timestamps,
# sub-agent references, and MCP timing. Outputs newline-delimited JSON spans
# suitable for OTLP trace emission.
#
# Output format (one JSON per line):
#   { "trace_id", "span_id", "parent_span_id", "name", "start_ns", "end_ns", "attributes": {...} }
#
# Dependencies: grep, jq, shasum
# Performance: ~0.3s for 43MB file (grep pre-filters 90% of lines)

set -u

SESSION_FILE="${1:?Usage: session-parser.sh <session.jsonl>}"
[[ -f "$SESSION_FILE" ]] || { echo "File not found: $SESSION_FILE" >&2; exit 1; }

# --- Deterministic IDs from session/message UUIDs ---

# trace_id: 32 hex chars from session_id
make_trace_id() {
  echo -n "$1" | shasum -a 256 | cut -c1-32
}

# span_id: 16 hex chars from uuid
make_span_id() {
  echo -n "$1" | shasum -a 256 | cut -c1-16
}

# ISO 8601 → nanoseconds since epoch
ts_to_ns() {
  local ts="$1"
  # macOS date doesn't support %N — use perl for sub-second precision
  perl -e '
    use Time::Piece;
    my $ts = $ARGV[0];
    $ts =~ s/Z$//;
    my ($dt, $frac) = split /\./, $ts;
    $frac //= "0";
    $frac = substr($frac . "000000000", 0, 9);
    my $t = Time::Piece->strptime($dt, "%Y-%m-%dT%H:%M:%S");
    printf "%d%s\n", $t->epoch, $frac;
  ' "$ts" 2>/dev/null || echo "0"
}

# --- Extract session metadata ---

SESSION_ID=$(grep -m1 '"sessionId"' "$SESSION_FILE" | jq -r '.sessionId // empty' 2>/dev/null)
[[ -z "$SESSION_ID" ]] && { echo "No sessionId found" >&2; exit 1; }

TRACE_ID=$(make_trace_id "$SESSION_ID")
ROOT_SPAN_ID=$(make_span_id "root-${SESSION_ID}")

# Session start/end timestamps — find first/last non-null timestamp
SESSION_START=$(grep -m1 '"type":"user"\|"type":"assistant"' "$SESSION_FILE" | jq -r '.timestamp // empty' 2>/dev/null)
SESSION_END=$(tail -50 "$SESSION_FILE" | grep '"type":"user"\|"type":"assistant"\|"type":"progress"' | tail -1 | jq -r '.timestamp // empty' 2>/dev/null)

SESSION_START_NS=$(ts_to_ns "$SESSION_START")
SESSION_END_NS=$(ts_to_ns "$SESSION_END")

# Model (from first assistant message with a real model)
MODEL=$(grep '"assistant"' "$SESSION_FILE" | head -5 | jq -r 'select(.message.model != null and .message.model != "<synthetic>") | .message.model' 2>/dev/null | head -1)
MODEL="${MODEL:-unknown}"

# Git branch
GIT_BRANCH=$(head -20 "$SESSION_FILE" | jq -r 'select(.gitBranch != null) | .gitBranch' 2>/dev/null | head -1)
GIT_BRANCH="${GIT_BRANCH:-unknown}"

# --- Emit root session span ---

jq -n -c \
  --arg tid "$TRACE_ID" \
  --arg sid "$ROOT_SPAN_ID" \
  --arg name "claude.session" \
  --arg start "$SESSION_START_NS" \
  --arg end "$SESSION_END_NS" \
  --arg model "$MODEL" \
  --arg branch "$GIT_BRANCH" \
  --arg session "$SESSION_ID" \
  '{
    trace_id: $tid,
    span_id: $sid,
    parent_span_id: "",
    name: $name,
    start_ns: $start,
    end_ns: $end,
    attributes: {
      "session.id": $session,
      "model": $model,
      "git.branch": $branch
    }
  }'

# --- Extract tool calls (tool_use → tool_result pairs) ---

TOOL_USE_TMP=$(mktemp)
TOOL_RESULT_TMP=$(mktemp)
JOINED_TMP=$(mktemp)
trap 'rm -f "$TOOL_USE_TMP" "$TOOL_RESULT_TMP" "$JOINED_TMP"' EXIT

# Extract tool_use entries
grep '"tool_use"' "$SESSION_FILE" | jq -c '
  select(.type == "assistant") |
  . as $msg |
  .message.content[]? |
  select(.type == "tool_use") |
  {
    tool_use_id: .id,
    tool_name: .name,
    start_ts: $msg.timestamp,
    tokens_out: ($msg.message.usage.output_tokens // 0)
  }
' 2>/dev/null > "$TOOL_USE_TMP"

# Extract tool_result entries
grep '"tool_result"' "$SESSION_FILE" | jq -c '
  select(.type == "user") |
  . as $msg |
  .message.content[]? |
  select(.type == "tool_result") |
  { tool_use_id: .tool_use_id, end_ts: $msg.timestamp }
' 2>/dev/null > "$TOOL_RESULT_TMP"

# Join in jq: slurp both files, build lookup, emit spans
jq -n -c \
  --arg tid "$TRACE_ID" \
  --arg psid "$ROOT_SPAN_ID" \
  --slurpfile results "$TOOL_RESULT_TMP" '

  # Build lookup: tool_use_id → end_ts
  ([$results[] | {key: .tool_use_id, value: .end_ts}] | from_entries) as $end_map |

  # Read uses from stdin
  [inputs] | .[] |
  . as $use |
  ($end_map[$use.tool_use_id] // $use.start_ts) as $end_ts |
  {
    tool_use_id: $use.tool_use_id,
    tool_name: $use.tool_name,
    start_ts: $use.start_ts,
    end_ts: $end_ts,
    tokens_out: $use.tokens_out,
    trace_id: $tid,
    parent_span_id: $psid
  }
' "$TOOL_USE_TMP" > "$JOINED_TMP" 2>/dev/null

# Convert timestamps and emit final span JSON
while IFS= read -r span; do
  start_ts=$(jq -r '.start_ts' <<< "$span")
  end_ts=$(jq -r '.end_ts' <<< "$span")
  tool_name=$(jq -r '.tool_name' <<< "$span")
  tool_use_id=$(jq -r '.tool_use_id' <<< "$span")
  tokens_out=$(jq -r '.tokens_out' <<< "$span")

  start_ns=$(ts_to_ns "$start_ts")
  end_ns=$(ts_to_ns "$end_ts")
  # span_id: 16 hex chars from tool_use_id hash
  span_id=$(make_span_id "$tool_use_id")

  jq -n -c \
    --arg tid "$TRACE_ID" \
    --arg sid "$span_id" \
    --arg psid "$ROOT_SPAN_ID" \
    --arg name "claude.tool.${tool_name}" \
    --arg start "$start_ns" \
    --arg end "$end_ns" \
    --arg tool "$tool_name" \
    --arg tok "$tokens_out" \
    '{
      trace_id: $tid, span_id: $sid, parent_span_id: $psid,
      name: $name, start_ns: $start, end_ns: $end,
      attributes: { "tool.name": $tool, "tokens.output": $tok }
    }'
done < "$JOINED_TMP"

# --- Extract MCP progress spans (have native timing) ---

grep '"mcp_progress"' "$SESSION_FILE" | \
  jq -c 'select(.data.status == "completed")' 2>/dev/null | \
while IFS= read -r entry; do
  ts=$(jq -r '.timestamp' <<< "$entry")
  elapsed_ms=$(jq -r '.data.elapsedTimeMs // 0' <<< "$entry")
  server=$(jq -r '.data.serverName // "unknown"' <<< "$entry")
  tool=$(jq -r '.data.toolName // "unknown"' <<< "$entry")
  uuid=$(jq -r '.uuid' <<< "$entry")

  end_ns=$(ts_to_ns "$ts")
  # start = end - elapsed_ms (convert ms to ns)
  start_ns=$(perl -e "printf '%d', $end_ns - ($elapsed_ms * 1000000)" 2>/dev/null || echo "$end_ns")
  span_id=$(make_span_id "$uuid")

  jq -n -c \
    --arg tid "$TRACE_ID" \
    --arg sid "$span_id" \
    --arg psid "$ROOT_SPAN_ID" \
    --arg name "claude.mcp.${server}.${tool}" \
    --arg start "$start_ns" \
    --arg end "$end_ns" \
    --arg server "$server" \
    --arg tool "$tool" \
    --arg elapsed "$elapsed_ms" \
    '{
      trace_id: $tid,
      span_id: $sid,
      parent_span_id: $psid,
      name: $name,
      start_ns: $start,
      end_ns: $end,
      attributes: {
        "mcp.server": $server,
        "mcp.tool": $tool,
        "mcp.duration_ms": $elapsed
      }
    }'
done

# --- Extract sub-agent spans ---

grep '"agent_progress"' "$SESSION_FILE" | \
  jq -c 'select(.data.message.type == "user") | {
    agent_id: .data.agentId,
    timestamp: .timestamp,
    prompt_preview: (.data.prompt[:80] // "")
  }' 2>/dev/null | \
  jq -sc 'group_by(.agent_id) | .[] | {
    agent_id: .[0].agent_id,
    start_ts: (map(.timestamp) | sort | .[0]),
    end_ts: (map(.timestamp) | sort | .[-1]),
    prompt_preview: .[0].prompt_preview
  }' 2>/dev/null | \
  jq -c '.' 2>/dev/null | \
while IFS= read -r agent; do
  agent_id=$(jq -r '.agent_id' <<< "$agent")
  start_ts=$(jq -r '.start_ts' <<< "$agent")
  end_ts=$(jq -r '.end_ts' <<< "$agent")
  prompt=$(jq -r '.prompt_preview' <<< "$agent")

  start_ns=$(ts_to_ns "$start_ts")
  end_ns=$(ts_to_ns "$end_ts")
  span_id=$(make_span_id "agent-${agent_id}")

  jq -n -c \
    --arg tid "$TRACE_ID" \
    --arg sid "$span_id" \
    --arg psid "$ROOT_SPAN_ID" \
    --arg name "claude.agent.${agent_id}" \
    --arg start "$start_ns" \
    --arg end "$end_ns" \
    --arg agent_id "$agent_id" \
    --arg prompt "$prompt" \
    '{
      trace_id: $tid,
      span_id: $sid,
      parent_span_id: $psid,
      name: $name,
      start_ns: $start,
      end_ns: $end,
      attributes: {
        "agent.id": $agent_id,
        "agent.prompt": $prompt
      }
    }'
done
