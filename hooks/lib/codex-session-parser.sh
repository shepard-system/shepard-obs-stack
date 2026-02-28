#!/usr/bin/env bash
# hooks/lib/codex-session-parser.sh — parse Codex CLI JSONL session logs into trace data
#
# Usage: bash codex-session-parser.sh /path/to/session.jsonl
#
# Session files: ~/.codex/sessions/YYYY/MM/DD/rollout-*-{uuid}.jsonl
# Entry types: session_meta, turn_context, response_item, event_msg, compacted
#
# Output format (one JSON per line):
#   { "trace_id", "span_id", "parent_span_id", "name", "start_ns", "end_ns",
#     "status": 0|2, "attributes": {...} }
#
# Dependencies: jq (1.6+)

set -u

SESSION_FILE="${1:?Usage: codex-session-parser.sh <session.jsonl>}"
[[ -f "$SESSION_FILE" ]] || { echo "File not found: $SESSION_FILE" >&2; exit 1; }

jq -n -c '

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

# ===== Read all entries =====
[inputs] |

# --- Session metadata from session_meta entry ---
(map(select(.type == "session_meta")) | .[0].payload // null) as $meta |
if $meta == null then empty else

($meta.id // "") as $session_id |
($session_id | gsub("-"; "")) as $trace_id |
"0000000000000001" as $root_sid |

# Model from first turn_context
(map(select(.type == "turn_context") | .payload.model // empty) | .[0] // "unknown") as $model |

# Git info
($meta.git.branch // "unknown") as $git_branch |
($meta.git.repository_url // "" | gsub(".*/"; "") | gsub("\\.git$"; "")) as $git_repo |

# Session start/end from first and last timestamps
(map(.timestamp // empty) | sort) as $ts |
($ts[0] // "") as $t_start |
($ts[-1] // "") as $t_end |

# --- Token aggregation: last token_count with non-null info ---
(map(select(.type == "event_msg" and .payload.type == "token_count" and .payload.info != null) |
  .payload.info.total_token_usage) | last // {}) as $tok |
{
  input: ($tok.input_tokens // 0),
  output: ($tok.output_tokens // 0),
  cache_read: ($tok.cached_input_tokens // 0),
  reasoning: ($tok.reasoning_output_tokens // 0),
  total: ($tok.total_tokens // 0)
} as $tokens |

# --- Tool calls: join function_call → function_call_output by call_id ---
([.[] | select(.type == "response_item" and .payload.type == "function_call") |
  {key: .payload.call_id, value: {name: .payload.name, ts: .timestamp, args: .payload.arguments}}
] | from_entries) as $calls |

([.[] | select(.type == "response_item" and .payload.type == "function_call_output") |
  {key: .payload.call_id, value: {ts: .timestamp}}
] | from_entries) as $outputs |

# Build ordered tool list
[$calls | to_entries[] | .value + {call_id: .key}] as $tools_unsorted |
[$tools_unsorted | sort_by(.ts)[] |
  . as $t |
  ($outputs[$t.call_id].ts // $t.ts) as $end_ts |
  # Parse arguments JSON for input params
  ($t.args | if type == "string" then (fromjson? // {}) else (. // {}) end) as $args |
  {name: $t.name, call_id: $t.call_id, ts: $t.ts, end_ts: $end_ts,
   command: (($args.cmd // $args.command // "")[:200]),
   file_path: ($args.file_path // $args.path // "")}
] as $tools |

# --- Turns: count task_started events ---
([.[] | select(.type == "event_msg" and .payload.type == "task_started")] | length) as $turn_count |

# --- Compaction: context_compacted events ---
([.[] | select(.type == "event_msg" and .payload.type == "context_compacted") |
  {ts: .timestamp}
]) as $compactions |

# --- Interruptions: turn_aborted events ---
([.[] | select(.type == "event_msg" and .payload.type == "turn_aborted")] | length) as $interruption_count |

# --- Stop reason from last task_complete or turn_aborted ---
(map(select(.type == "event_msg" and (.payload.type == "task_complete" or .payload.type == "turn_aborted"))) |
  last // null | if . == null then "unknown" elif .payload.type == "turn_aborted" then "interrupted" else "end_turn" end
) as $stop_reason |

# ===== Emit spans =====

# 1. Root session span
{trace_id: $trace_id, span_id: $root_sid, parent_span_id: "",
 name: "codex.session",
 start_ns: ($t_start | ts_to_ns), end_ns: ($t_end | ts_to_ns),
 status: 0,
 attributes: (
   {"session.id": $session_id, "model": $model, "provider": "codex",
    "git.branch": $git_branch, "git.repo": $git_repo,
    "tokens.input": ($tokens.input | tostring),
    "tokens.output": ($tokens.output | tostring),
    "tokens.cache_read": ($tokens.cache_read | tostring),
    "tokens.reasoning": ($tokens.reasoning | tostring),
    "tokens.total": ($tokens.total | tostring),
    "tool.count": ($tools | length | tostring),
    "turn.count": ($turn_count | tostring),
    "compaction.count": ($compactions | length | tostring),
    "stop_reason": $stop_reason} +
   (if $interruption_count > 0 then
     {"has_interruption": "true", "interruption.count": ($interruption_count | tostring)}
   else {} end)
 )},

# 2. Tool call spans (span_id offset: 16)
($tools | to_entries[] |
  (.key + 16) as $i | .value as $t |
  {trace_id: $trace_id, span_id: ($i | pad16), parent_span_id: $root_sid,
   name: "codex.tool.\($t.name)",
   start_ns: ($t.ts | ts_to_ns), end_ns: ($t.end_ts | ts_to_ns),
   status: 0,
   attributes: (
     {"tool.name": $t.name} +
     (if $t.command != "" then {"tool.input.command": $t.command} else {} end) +
     (if $t.file_path != "" then {"tool.input.file_path": $t.file_path} else {} end)
   )}),

# 3. Compaction spans (span_id offset: 30016)
($compactions | to_entries[] |
  (.key + 30016) as $i | .value as $c |
  {trace_id: $trace_id, span_id: ($i | pad16), parent_span_id: $root_sid,
   name: "codex.compaction",
   start_ns: ($c.ts | ts_to_ns), end_ns: ($c.ts | ts_to_ns),
   status: 0,
   attributes: {}})

end
' < "$SESSION_FILE"
