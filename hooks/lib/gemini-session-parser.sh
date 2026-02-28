#!/usr/bin/env bash
# hooks/lib/gemini-session-parser.sh — parse Gemini CLI JSON session logs into trace data
#
# Usage: bash gemini-session-parser.sh /path/to/session.json
#
# Session files: ~/.gemini/tmp/{project}/chats/session-*.json
# Single JSON with messages array (NOT JSONL).
#
# Output format (one JSON per line):
#   { "trace_id", "span_id", "parent_span_id", "name", "start_ns", "end_ns",
#     "status": 0|2, "attributes": {...} }
#
# Dependencies: jq (1.6+)

set -u

SESSION_FILE="${1:?Usage: gemini-session-parser.sh <session.json>}"
[[ -f "$SESSION_FILE" ]] || { echo "File not found: $SESSION_FILE" >&2; exit 1; }

jq -c '

# --- Helper functions ---

def to_hex:
  def _h: if . < 10 then . + 48 else . - 10 + 97 end | [.] | implode;
  if . == 0 then "0"
  elif . < 16 then _h
  else ((. / 16 | floor) | to_hex) + ((. % 16) | _h)
  end;

def pad16:
  if . == 0 then "0000000000000000"
  else to_hex | ("0000000000000000" + .) | .[-16:]
  end;

def pad9: tostring | ("000000000" + .) | .[-9:];

def ts_parts:
  if . == null or . == "" then {s: 0, ns: 0}
  else
    split(".") |
    (.[0] | strptime("%Y-%m-%dT%H:%M:%S") | mktime | floor) as $epoch |
    ((.[1] // "0") | rtrimstr("Z") | (. + "000000000")[:9] | tonumber) as $frac |
    {s: $epoch, ns: $frac}
  end;

def parts_to_ns: "\(.s)\(.ns | pad9)";
def ts_to_ns: ts_parts | parts_to_ns;

# ===== Read session JSON =====
.sessionId as $session_id |
if $session_id == null or $session_id == "" then empty else

($session_id | gsub("-"; "")) as $trace_id |
"0000000000000001" as $root_sid |
"0000000000000002" as $meta_sid |

.startTime as $t_start |
.lastUpdated as $t_end |
.messages as $msgs |

# Model from first gemini message
([$msgs[] | select(.type == "gemini") | .model // empty] | .[0] // "unknown") as $model |

# --- Token aggregation across all gemini messages ---
([$msgs[] | select(.type == "gemini") | .tokens // empty] |
  { input: (map(.input // 0) | add // 0),
    output: (map(.output // 0) | add // 0),
    cached: (map(.cached // 0) | add // 0),
    thoughts: (map(.thoughts // 0) | add // 0),
    tool: (map(.tool // 0) | add // 0),
    total: (map(.total // 0) | add // 0) }
) as $tokens |

# --- Flatten all tool calls with parent message context ---
[
  $msgs[] | select(.type == "gemini") |
  . as $m |
  (.toolCalls // [])[] |
  {name: .name, args: .args, status: .status, timestamp: .timestamp,
   msg_ts: $m.timestamp}
] as $all_tools |

# Count errors
([$all_tools[] | select(.status == "error" or .status == "cancelled")] | length) as $tool_error_count |

# Turn count (user messages)
([$msgs[] | select(.type == "user")] | length) as $turn_count |

# Thinking blocks
([$msgs[] | select(.type == "gemini") | (.thoughts // [])[] ] | length) as $thinking_count |

# Interruptions (info messages with "Request cancelled")
([$msgs[] | select(.type == "info" and .content == "Request cancelled.")] | length) as $interruption_count |

# ===== Emit spans =====

# 1. Root session span
{trace_id: $trace_id, span_id: $root_sid, parent_span_id: "",
 name: "gemini.session",
 start_ns: ($t_start | ts_to_ns), end_ns: ($t_end | ts_to_ns),
 status: 0,
 attributes: (
   {"session.id": $session_id, "model": $model, "provider": "gemini-cli",
    "tokens.input": ($tokens.input | tostring),
    "tokens.output": ($tokens.output | tostring),
    "tokens.cache_read": ($tokens.cached | tostring),
    "tokens.reasoning": ($tokens.thoughts | tostring),
    "tokens.total": ($tokens.total | tostring),
    "tool.count": ($all_tools | length | tostring),
    "tool.error_count": ($tool_error_count | tostring),
    "turn.count": ($turn_count | tostring),
    "thinking.block_count": ($thinking_count | tostring),
    "stop_reason": "end_turn"} +
   (if $interruption_count > 0 then
     {"has_interruption": "true", "interruption.count": ($interruption_count | tostring)}
   else {} end)
 )},

# 1b. Session meta marker (child of root — root spans are not indexed by Tempo local-blocks)
{trace_id: $trace_id, span_id: $meta_sid, parent_span_id: $root_sid,
 name: "gemini.session.meta",
 start_ns: ($t_start | ts_to_ns), end_ns: ($t_start | ts_to_ns),
 status: 0,
 attributes: {"session.id": $session_id, "provider": "gemini-cli"}},

# 2. Tool call spans (span_id offset: 16)
($all_tools | to_entries[] |
  (.key + 16) as $i | .value as $t |
  # Tool start = parent message timestamp, end = tool timestamp (or msg if missing)
  ($t.msg_ts) as $start |
  ($t.timestamp // $t.msg_ts) as $end |
  ($t.status == "error" or $t.status == "cancelled") as $is_err |
  # Extract input params from args
  ($t.args // {}) as $args |
  {trace_id: $trace_id, span_id: ($i | pad16), parent_span_id: $root_sid,
   name: "gemini.tool.\($t.name)",
   start_ns: ($start | ts_to_ns), end_ns: ($end | ts_to_ns),
   status: (if $is_err then 2 else 0 end),
   attributes: (
     {"tool.name": $t.name,
      "tool.is_error": (if $is_err then "true" else "false" end)} +
     (if ($args.file_path // "") != "" then {"tool.input.file_path": $args.file_path} else {} end) +
     (if ($args.command // "") != "" then {"tool.input.command": ($args.command[:200])} else {} end) +
     (if ($args.query // "") != "" then {"tool.input.pattern": $args.query} else {} end) +
     (if ($args.pattern // "") != "" then {"tool.input.pattern": $args.pattern} else {} end)
   )})

end
' "$SESSION_FILE"
