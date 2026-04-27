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
