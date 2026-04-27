#!/usr/bin/env bash
# install.sh: cc-session-manager セットアップ
# - hooks/bin を symlink で配置
# - settings.json に SessionEnd hook 追記（既存設定はバックアップ）
# - sessions ディレクトリ作成

set -eu

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
HOOK_DIR="$CLAUDE_DIR/hooks"
SESS_DIR="$CLAUDE_DIR/sessions"
BIN_DIR="${CC_BIN_DIR:-$HOME/.local/bin}"
SETTINGS="$CLAUDE_DIR/settings.json"

echo "==> repo: $REPO_DIR"
echo "==> bin:  $BIN_DIR (override: CC_BIN_DIR=...)"

mkdir -p "$HOOK_DIR" "$SESS_DIR" "$BIN_DIR"

# symlink (既存があれば backup)
link() {
  local src="$1" dst="$2"
  if [ -L "$dst" ]; then rm "$dst"
  elif [ -e "$dst" ]; then mv "$dst" "$dst.bak.$(date +%s)"; fi
  ln -s "$src" "$dst"
  echo "linked: $dst -> $src"
}

link "$REPO_DIR/hooks/session-end-save.sh" "$HOOK_DIR/session-end-save.sh"
link "$REPO_DIR/bin/cc-sessions" "$BIN_DIR/cc-sessions"

# settings.json hook 登録
if [ ! -f "$SETTINGS" ]; then
  echo '{"hooks":{}}' > "$SETTINGS"
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required" >&2; exit 1
fi
if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "ERROR: sqlite3 required" >&2; exit 1
fi

# 既存 index.jsonl があれば SQLite へマイグレーション
JSONL="$SESS_DIR/index.jsonl"
DB="$SESS_DIR/index.db"
if [ -s "$JSONL" ] && [ ! -f "$DB" ]; then
  echo "==> migrating $JSONL -> $DB"
  sqlite3 "$DB" <<'SQL'
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
SQL

  # ended_at昇順でINSERT OR REPLACE → 同ID重複時は最新が残る
  # 各レコードを bind variable 経由で安全に投入
  jq -rs 'sort_by(.ended_at) | .[] | @json' "$JSONL" | while IFS= read -r rec; do
    sqlite3 "$DB" <<SQL
.parameter set :id        $(echo "$rec" | jq '.id')
.parameter set :cwd       $(echo "$rec" | jq '.cwd // ""')
.parameter set :ended_at  $(echo "$rec" | jq '.ended_at')
.parameter set :reason    $(echo "$rec" | jq '.reason // ""')
.parameter set :title     $(echo "$rec" | jq '.title // ""')
.parameter set :summary   $(echo "$rec" | jq '.summary // ""')
.parameter set :turns     $(echo "$rec" | jq '.turns // 0')
.parameter set :duration  $(echo "$rec" | jq '.duration_ms // 0')
.parameter set :tx        $(echo "$rec" | jq '.transcript // ""')

INSERT OR REPLACE INTO sessions
  (id, cwd, ended_at, reason, title, summary, turns, duration_ms, transcript)
VALUES
  (:id, :cwd, :ended_at, :reason, :title, :summary, :turns, :duration, :tx);
SQL
  done

  COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM sessions;")
  echo "==> migrated $COUNT records"
  mv "$JSONL" "$JSONL.bak.$(date +%s)"
fi

cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"

CMD='bash "$HOME/.claude/hooks/session-end-save.sh"'
TMP=$(mktemp)
jq --arg cmd "$CMD" '
  .hooks = (.hooks // {})
  | .hooks.SessionEnd = (.hooks.SessionEnd // [])
  | if any(.hooks.SessionEnd[]?; (.hooks // [])[]?.command == $cmd)
    then .
    else .hooks.SessionEnd += [{hooks:[{type:"command",command:$cmd}]}]
    end
' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"

echo "==> settings.json updated: $SETTINGS"

# 依存チェック
for c in fzf jq; do
  command -v "$c" >/dev/null 2>&1 || echo "WARN: $c not found"
done

# PATH チェック
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "WARN: $BIN_DIR not in PATH. add to ~/.zshrc:"; echo "  export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

echo "==> done. next session end will be recorded."
