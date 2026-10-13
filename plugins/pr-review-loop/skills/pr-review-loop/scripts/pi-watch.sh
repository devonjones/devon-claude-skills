#!/usr/bin/env bash
# Watch a Pi review run as it happens: tool calls, what the model says, and a
# running token / cost tally - the view a Claude Code agent gives you.
#
# Usage: pi-watch.sh [--latest | <run.jsonl>] [--once]
#   --latest (default)  the newest run in $PI_REVIEW_CACHE_DIR/runs
#   --once              print what is there and exit instead of following
#
# pi-review.sh writes every run's event stream to
# ${PI_REVIEW_CACHE_DIR:-~/.cache/pr-review-loop}/runs/<time>-<agent>-<sha>-<model>.jsonl

set -euo pipefail

RUNS="${PI_REVIEW_CACHE_DIR:-$HOME/.cache/pr-review-loop}/runs"
FILE="" FOLLOW=true
for a in "$@"; do
    case "$a" in
        --once) FOLLOW=false ;;
        --latest) FILE="" ;;
        *) FILE="$a" ;;
    esac
done
if [[ -z "$FILE" ]]; then
    FILE="$(ls -t "$RUNS"/*.jsonl 2>/dev/null | head -n 1)" || true
    [[ -n "$FILE" ]] || { echo "No runs in $RUNS yet." >&2; exit 1; }
fi
[[ -r "$FILE" ]] || { echo "Cannot read $FILE" >&2; exit 1; }
echo "== $(basename "$FILE")"

if [[ "$FOLLOW" == true ]]; then src=(tail -n +1 -F "$FILE"); else src=(cat "$FILE"); fi
"${src[@]}" 2>/dev/null | jq -nRr --unbuffered '
  def short($n): tostring | gsub("\\s+"; " ") | if length > $n then .[0:$n] + "…" else . end;
  def k: if . >= 1000000 then "\(. / 100000 | round / 10)M" elif . >= 1000 then "\(. / 1000 | round)K" else tostring end;
  def clock($s): "[\($s | floor | tostring | " " * (4 - length) + .)s]";
  def args($t; $a):
    if $t == "bash" then $a.command
    elif $t == "report_finding" then "\($a.severity) \($a.file):\($a.line)  \($a.title)"
    elif $t == "reopen_thread" then "thread \($a.comment_id): \($a.reason)"
    elif $t == "finish_review" then "(report closed)"
    else ($a.path // $a.pattern // $a.file_path // (if $a == {} then "." else ($a | tojson) end)) end;
  foreach (inputs | fromjson? // empty) as $e (
    {t0: null, now: null, in: 0, out: 0, cr: 0, usd: 0, emit: null};
    .emit = null
    | (($e.message.timestamp // null) as $ts | if $ts then .now = $ts | .t0 //= $ts else . end)
    | (if .t0 and .now then (.now - .t0) / 1000 else 0 end) as $s
    | if $e.type == "tool_execution_start" then
        .emit = "\(clock($s)) \($e.toolName | . + " " * (14 - length)) \(args($e.toolName; $e.args // {}) | short(110))"
      elif $e.type == "tool_execution_end" and ($e.isError // false) then
        .emit = "\(clock($s))   ! \($e.toolName) failed: \($e.result | short(100))"
      elif $e.type == "message_end" and $e.message.role == "assistant" then
        ($e.message.usage // {}) as $u
        | .in += ($u.input // 0) | .out += ($u.output // 0) | .cr += ($u.cacheRead // 0)
        | .usd += ($u.cost.total // 0)
        | ([$e.message.content[]? | select(.type == "text") | .text] | join(" ")) as $txt
        | .emit = ((if ($txt | length) > 0 then "\(clock($s)) » \($txt | short(150))\n" else "" end)
                   + (if $e.message.stopReason == "error" then "\(clock($s)) !! \($e.message.errorMessage // "provider error")\n" else "" end)
                   + "         tokens in \(.in | k) · out \(.out | k) · cache \(.cr | k) · $\(.usd * 10000 | round / 10000)")
      elif $e.type == "agent_end" then
        .emit = "== finished after \($s | floor)s"
      else . end;
    .emit // empty)'
