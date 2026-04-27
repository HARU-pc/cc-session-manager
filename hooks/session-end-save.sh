#!/usr/bin/env bash
# SessionEnd hook: セッション概略+resume IDを ~/.claude/sessions/index.jsonl に追記
# 軽量抽出方式 — transcriptから最初のユーザー発話を切り出すのみ。LLM呼出なし。

set -u

INDEX="$HOME/.claude/sessions/index.jsonl"
mkdir -p "$(dirname "$INDEX")"

# stdin の JSON を読込
INPUT=$(cat)

# 必須フィールド抽出
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
REASON=$(echo "$INPUT" | jq -r '.reason // "other"')
TITLE=$(echo "$INPUT" | jq -r '.session_title // empty')
TURNS=$(echo "$INPUT" | jq -r '.turn_count // 0')
DURATION=$(echo "$INPUT" | jq -r '.duration_ms // 0')

# session_id 必須。無ければ何もせず終了
[ -z "$SESSION_ID" ] && exit 0

# 概略生成: 最初のユーザー発話（type=user, isSidechain!=true, content先頭）から200文字抽出
SUMMARY=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  SUMMARY=$(jq -rs '
    map(select(.type=="user" and (.isSidechain // false) == false))
    | map(.message.content)
    | map(if type=="string" then . elif type=="array" then (map(select(.type=="text") | .text) | join(" ")) else "" end)
    | map(select(length > 0 and (startswith("<") | not)))
    | .[0] // ""
  ' "$TRANSCRIPT" 2>/dev/null | tr '\n' ' ' | cut -c1-200)
fi

# title未設定時は概略を流用
[ -z "$TITLE" ] && TITLE="$SUMMARY"

# レコード生成して追記
jq -cn \
  --arg id "$SESSION_ID" \
  --arg cwd "$CWD" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg reason "$REASON" \
  --arg title "$TITLE" \
  --arg summary "$SUMMARY" \
  --arg transcript "$TRANSCRIPT" \
  --argjson turns "$TURNS" \
  --argjson duration "$DURATION" \
  '{id:$id, cwd:$cwd, ended_at:$ts, reason:$reason, title:$title, summary:$summary, turns:$turns, duration_ms:$duration, transcript:$transcript}' \
  >> "$INDEX"

exit 0
