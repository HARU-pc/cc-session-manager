#!/usr/bin/env bash
# SessionEnd hook: セッション概略+resume IDを ~/.claude/sessions/index.db に保存
# SQLite版。INSERT OR REPLACE でID重複時上書き（resume保存対応）。

set -u

DB="$HOME/.claude/sessions/index.db"
mkdir -p "$(dirname "$DB")"

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

ENDED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# スキーマ作成（冪等）+ UPSERT
# bind variable で SQLi 完全回避
sqlite3 "$DB" <<SQL
CREATE TABLE IF NOT EXISTS sessions (
  id          TEXT PRIMARY KEY,
  cwd         TEXT,
  ended_at    TEXT NOT NULL,
  reason      TEXT,
  title       TEXT,
  summary     TEXT,
  turns       INTEGER DEFAULT 0,
  duration_ms INTEGER DEFAULT 0,
  transcript  TEXT
);
CREATE INDEX IF NOT EXISTS idx_sessions_cwd      ON sessions(cwd);
CREATE INDEX IF NOT EXISTS idx_sessions_ended_at ON sessions(ended_at DESC);

.parameter set :id        $(printf '%s' "$SESSION_ID" | jq -Rs .)
.parameter set :cwd       $(printf '%s' "$CWD"        | jq -Rs .)
.parameter set :ended_at  $(printf '%s' "$ENDED_AT"   | jq -Rs .)
.parameter set :reason    $(printf '%s' "$REASON"     | jq -Rs .)
.parameter set :title     $(printf '%s' "$TITLE"      | jq -Rs .)
.parameter set :summary   $(printf '%s' "$SUMMARY"    | jq -Rs .)
.parameter set :turns     $TURNS
.parameter set :duration  $DURATION
.parameter set :tx        $(printf '%s' "$TRANSCRIPT" | jq -Rs .)

INSERT OR REPLACE INTO sessions
  (id, cwd, ended_at, reason, title, summary, turns, duration_ms, transcript)
VALUES
  (:id, :cwd, :ended_at, :reason, :title, :summary, :turns, :duration, :tx);
SQL

exit 0
