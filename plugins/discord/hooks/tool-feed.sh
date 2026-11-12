#!/usr/bin/env bash
# tool-feed — the agent's tool calls, live, in the Discord chat that started the turn.
# Ships with this plugin (hooks/hooks.json): UserPromptSubmit → start · PreToolUse → tool · Stop → stop.
#   start  reads chat_id from the <channel source="plugin:discord:discord" chat_id="…"> tag; CLI turns = no feed
#   tool   one line "🔧 <tool>: <what>" (Bash → its description, Read/Write/Edit → path, MCP → first argument),
#          secrets masked; lines within ~1.5 s are posted together as ONE NEW message (never edits)
#   stop   "✅ N tools · Xm Ys"
# Config (env):  DISCORD_TOOL_FEED=0 turns it off · DISCORD_TOOL_FEED_THINK=1 adds 💭/💬 lines from the transcript
#                DISCORD_TOOL_FEED_BATCH=1.5 seconds per batch · token: DISCORD_BOT_TOKEN, else <state dir>/.env
# Never blocks Claude: exits 0 fast; Discord calls run in the background. History: docs/TOOL-FEED.md.
set -uo pipefail
MODE="${1:-tool}"
[ "${DISCORD_TOOL_FEED:-1}" = 0 ] && exit 0
if [ "$MODE" = _send ]; then IN="{}"; else IN=$(cat); fi
STATE_DIR="${DISCORD_STATE_DIR:-$HOME/.claude/channels/discord}"
if [ -z "${DISCORD_BOT_TOKEN:-}" ] && [ -f "$STATE_DIR/.env" ]; then   # same rule as server.ts: real env wins
  DISCORD_BOT_TOKEN=$(sed -n 's/^DISCORD_BOT_TOKEN=//p' "$STATE_DIR/.env" | tail -1); export DISCORD_BOT_TOKEN
fi
[ -n "${DISCORD_BOT_TOKEN:-}" ] || exit 0
command -v jq >/dev/null || exit 0
SID="${TOOL_FEED_SID:-$(printf '%s' "$IN" | jq -r '.session_id // "x"')}"; export TOOL_FEED_SID="$SID"
DIR="$STATE_DIR/tool-feed"; mkdir -p "$DIR"
ST="$DIR/$SID.json"; LOCK="$DIR/$SID.lock"; PEND="$DIR/$SID.pending"
BATCH="${DISCORD_TOOL_FEED_BATCH:-1.5}"
TOOL_FEED_THINK="${DISCORD_TOOL_FEED_THINK:-0}"

locked() {  # locked <cmd or function…>: flock on Linux, a mkdir lock where flock is missing (macOS)
  local rc
  if command -v flock >/dev/null; then
    exec 8>"$LOCK"; flock 8; "$@"; rc=$?; flock -u 8; return $rc
  fi
  local i=0; until mkdir "$LOCK.d" 2>/dev/null; do i=$((i+1)); [ $i -gt 100 ] && break; sleep 0.05; done
  "$@"; rc=$?; rmdir "$LOCK.d" 2>/dev/null; return $rc
}
API=https://discord.com/api/v10
now() { date +%s; }
hm() { TZ=Asia/Bangkok date +%H:%M:%S; }

mask() {  # strip anything that looks like a secret before it leaves the machine
  sed -E -e 's/apiv3_[A-Za-z0-9_-]+/apiv3_***/g' \
         -e 's/(Bearer|Bot) [A-Za-z0-9._-]{12,}/\1 ***/g' \
         -e 's/((pass(word)?|token|secret|key|PASS|TOKEN|SECRET|KEY)[A-Za-z_]*[=:] *)[^ "'"'"']+/\1***/g' \
         -e 's/-u [^ :]+:[^ ]+/-u ***/g' -e 's/-P "?[^ "]+"?/-P ***/g'
}

render() {  # buffered lines -> content of ONE new message (≤ 1900 chars)
  jq -r '.buf | join("\n")' "$ST" | sed -E 's/([*~`|])/\\\1/g' | cut -c1-1900   # escape markdown except _
}

send() {  # post the buffered lines as a NEW message (no edits — like NSM), then empty the buffer
  local body chat
  [ "$(jq -r '(.buf // []) | length' "$ST")" = 0 ] && return 0
  chat=$(jq -r '.chat' "$ST")
  body=$(render | jq -Rs '{content: ., flags: 4096, allowed_mentions: {parse: []}}')
  curl -s -m 8 -o /dev/null -X POST "$API/channels/$chat/messages" -H "Authorization: Bot $DISCORD_BOT_TOKEN" \
    -H 'content-type: application/json' -d "$body"
  jq '.buf = []' "$ST" > "$ST.tmp" && mv "$ST.tmp" "$ST"
}

flush_later() {  # coalesce: one background sender at a time; the token stays in the environment, never in argv
  [ -e "$PEND" ] && return 0
  : > "$PEND"
  nohup bash -c 'sleep "$1"; mv "$2" "$2.done" 2>/dev/null; "$3" _send < /dev/null' _ \
    "${1:-$BATCH}" "$PEND" "$0" >/dev/null 2>&1 &
}

ingest() {  # new transcript entries since last call -> "HH:MM:SS think (Ns)" / "HH:MM:SS say <first words>"
  local tp tl n
  tp=$(printf '%s' "$IN" | jq -r '.transcript_path // ""'); [ -f "$tp" ] || return 0
  tl=$(jq -r '.tl // 0' "$ST"); n=$(wc -l < "$tp")
  if [ "$tl" = 0 ]; then  # turn began before tl was recorded: start from now, never replay history
    jq --argjson n "$n" '.tl = $n' "$ST" > "$ST.tmp" && mv "$ST.tmp" "$ST"; return 0
  fi
  [ "$n" -gt "$tl" ] || return 0
  tail -n +"$((tl + 1))" "$tp" | head -n "$((n - tl))" | jq -c 'select(.timestamp) | {ts: .timestamp, type,
      b: [(.message.content // []) | if type == "array" then .[] else empty end | select(type == "object") | .type],
      text: ([(.message.content // []) | if type == "array" then .[] else empty end | select(type == "object" and .type == "text") | .text] | join(" "))}' 2>/dev/null \
  | jq -rs --arg prev "$(jq -r '.lastts // ""' "$ST")" '
      def t: sub("\\.[0-9]+Z$"; "Z") | fromdate;
      def bkk: t + 25200 | strftime("%H:%M:%S");
      reduce .[] as $e ({p: $prev, out: []};
        if ($e.type == "assistant" and ($e.b | index("thinking"))) then
          .out += [($e.ts | bkk) + " 💭 think (" + (if .p != "" then (($e.ts | t) - (.p | t) | tostring) + "s" else "…" end) + ")"]
        elif ($e.type == "assistant" and ($e.b | index("text")) and ($e.text | length) > 0) then
          .out += [($e.ts | bkk) + " 💬 " + ($e.text | gsub("[\\n`]"; " ") | .[0:60])]
        else . end
        | .p = $e.ts)
      | .out[], "LASTTS " + .p' > "$ST.new" 2>/dev/null || return 0
  local last; last=$(grep '^LASTTS ' "$ST.new" | tail -1 | cut -d' ' -f2)
  local add; add=$(grep -v '^LASTTS ' "$ST.new" | jq -R . | jq -s .)
  jq --argjson add "$add" --arg n "$n" --arg last "$last" \
    '.lines += $add | .lines = .lines[-40:] | .tl = ($n|tonumber) | .lastts = (if $last == "" then .lastts else $last end)' \
    "$ST" > "$ST.tmp" && mv "$ST.tmp" "$ST"
  mv "$ST.new" "$ST.new.done" 2>/dev/null
}

case "$MODE" in
_send)
  [ -f "$ST" ] && locked send ;;
start)
  chat=$(printf '%s' "$IN" | jq -r '.prompt // ""' | grep -oE 'source="plugin:discord:discord" chat_id="[0-9]+"' | tail -1 | grep -oE '[0-9]{10,}')
  if [ -z "$chat" ]; then mv "$ST" "$ST.off" 2>/dev/null; exit 0; fi
  jq -n --arg c "$chat" --arg h "$(TZ=Asia/Bangkok date +%H:%M)" --argjson t "$(now)" \
    '{chat: $c, n: 0, lines: [], buf: [], t0: $t, t0h: $h}' > "$ST"
  tp=$(printf '%s' "$IN" | jq -r '.transcript_path // ""')
  [ -f "$tp" ] && jq --argjson n "$(wc -l < "$tp")" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.tl = $n | .lastts = $ts' "$ST" > "$ST.tmp" && mv "$ST.tmp" "$ST" ;;
tool)
  [ -f "$ST" ] || exit 0
  name=$(printf '%s' "$IN" | jq -r '.tool_name // "?"')
  case "$name" in mcp__plugin_discord_discord__react|mcp__plugin_discord_discord__edit_message) exit 0 ;; esac
  what=$(printf '%s' "$IN" | jq -r '
    .tool_input as $i
    | if .tool_name == "Bash" then ($i.description // $i.command // "")
      elif (.tool_name|test("^(Read|Write|Edit)$")) then (($i.file_path // "") | split("/") | .[-2:] | join("/"))
      elif .tool_name == "mcp__plugin_discord_discord__reply" then "reply to Discord"
      else ([$i | .. | strings] | .[0] // "") end' | tr '\n' ' ' | mask | cut -c1-60)
  short=$(printf '%s' "$name" | sed -E 's/^mcp__([^_]+(_[^_]+)*)__//; s/^plugin_discord_discord__/discord /')
  line="🔧 $short"; [ -n "${what// /}" ] && line="$line: $what"
  [ "$TOOL_FEED_THINK" = 1 ] && locked ingest
  locked bash -c 'jq --arg l "$1" ".n += 1 | .buf += [\$l]" "$2" > "$2.tmp" && mv "$2.tmp" "$2"' _ "$line" "$ST"
  flush_later ;;
stop)
  [ -f "$ST" ] || exit 0
  [ "$(jq -r '.n' "$ST")" = 0 ] && exit 0
  [ "$TOOL_FEED_THINK" = 1 ] && locked ingest
  dur=$(( $(now) - $(jq -r '.t0' "$ST") ))
  locked bash -c 'jq --arg f "$1" ".buf += [\$f]" "$2" > "$2.tmp" && mv "$2.tmp" "$2"' _ \
    "$(printf '✅ %s tools · %dm %02ds' "$(jq -r '.n' "$ST")" $((dur/60)) $((dur%60)))" "$ST"
  flush_later 0.2 ;;
esac
exit 0
