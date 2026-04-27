# install.sh 詳細仕様

ファイル: `install.sh`

## 役割

repo を clone した状態から、Claude Code 連携に必要なファイル配置・設定登録・既存データのマイグレーションを冪等に実行する。

## 起動

```sh
./install.sh
# or
CC_BIN_DIR=~/scripts ./install.sh
```

## 環境変数

| 変数 | 既定 | 用途 |
|---|---|---|
| `CC_BIN_DIR` | `$HOME/.local/bin` | `cc-sessions` symlink 配置先 |

## 処理フロー

### 1. パス解決

```bash
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
HOOK_DIR="$CLAUDE_DIR/hooks"
SESS_DIR="$CLAUDE_DIR/sessions"
BIN_DIR="${CC_BIN_DIR:-$HOME/.local/bin}"
SETTINGS="$CLAUDE_DIR/settings.json"
```

### 2. ディレクトリ作成

`mkdir -p "$HOOK_DIR" "$SESS_DIR" "$BIN_DIR"`

### 3. symlink 配置 (`link()` 関数)

```bash
link() {
  local src="$1" dst="$2"
  if [ -L "$dst" ]; then rm "$dst"
  elif [ -e "$dst" ]; then mv "$dst" "$dst.bak.$(date +%s)"; fi
  ln -s "$src" "$dst"
}
```

- 既存 symlink → 削除
- 既存実体 → `.bak.<unixtime>` 退避
- 新規 symlink 作成

対象:
- `$REPO_DIR/hooks/session-end-save.sh` → `$HOOK_DIR/session-end-save.sh`
- `$REPO_DIR/bin/cc-sessions` → `$BIN_DIR/cc-sessions`

### 4. settings.json 初期化

不在時 `{"hooks":{}}` 生成。

### 5. 依存チェック

| コマンド | 不在時の挙動 |
|---|---|
| `jq` | `ERROR` で `exit 1` |
| `sqlite3` | `ERROR` で `exit 1` |
| `fzf` | `WARN` のみ（hook 単体は動くため） |

### 6. JSONL → SQLite マイグレーション

**実行条件**: `index.jsonl` 存在 かつ `index.db` 不在 のときのみ。

#### 処理

1. `index.db` 作成 + DDL 実行（テーブル + インデックス）
2. レコード変換:
   ```bash
   jq -rs 'sort_by(.ended_at) | .[] | @json' "$JSONL" | while IFS= read -r rec; do
     sqlite3 "$DB" <<SQL
   .parameter set :id        $(echo "$rec" | jq '.id')
   .parameter set :cwd       $(echo "$rec" | jq '.cwd // ""')
   ...
   INSERT OR REPLACE INTO sessions (...) VALUES (...);
   SQL
   done
   ```
3. **ended_at 昇順 + INSERT OR REPLACE** → 同 ID 重複時は最新 (= 後勝ち = `ended_at` 最大) が残る
4. 完了後 `index.jsonl` を `.bak.<unixtime>` へリネーム
5. `SELECT COUNT(*) FROM sessions` で件数報告

#### 設計判断

- `.import /dev/stdin` 採用しなかった理由: CSV 形式での衝突回避が複雑。bind variable 経由なら型・エスケープを sqlite3 が処理
- 1 レコード = 1 sqlite3 呼出: 数百〜数千件想定で実用上問題なし。バルク化は将来必要時に検討

### 7. settings.json への hook 登録

```bash
cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"

CMD='bash "$HOME/.claude/hooks/session-end-save.sh"'
jq --arg cmd "$CMD" '
  .hooks = (.hooks // {})
  | .hooks.SessionEnd = (.hooks.SessionEnd // [])
  | if any(.hooks.SessionEnd[]?; (.hooks // [])[]?.command == $cmd)
    then .
    else .hooks.SessionEnd += [{hooks:[{type:"command",command:$cmd}]}]
    end
' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
```

- 必ず `.bak.<unixtime>` で退避
- 重複登録防止: `any(... .command == $cmd)` で既存チェック
- 構造保持: `.hooks` / `.hooks.SessionEnd` 不在時の補完を `// {}` / `// []` で

### 8. PATH チェック

`$BIN_DIR` が `$PATH` に未含有なら警告 + `~/.zshrc` 追記コマンド提示:

```sh
export PATH="$BIN_DIR:$PATH"
```

## 冪等性

| 観点 | 担保方法 |
|---|---|
| symlink | 既存削除 / 実体退避 → 再作成 |
| DB DDL | `CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS` |
| settings.json hook 登録 | `any(... .command == $cmd)` で重複検出 |
| マイグレーション | `index.db` 存在時はスキップ |

複数回実行しても破壊せず、最新 repo の内容を反映。

## 終了コード

| 終了コード | 状況 |
|---|---|
| 0 | 正常完了 |
| 1 | 必須依存（`jq` / `sqlite3`）不在 |
| 非0 | `set -eu` 下での予期せぬ失敗（symlink 失敗等） |

## 既知の制約

- `set -eu` のため、設定書込中の途中失敗時に `.bak` のみ残る可能性あり。手動復元: `mv $SETTINGS.bak.<最新> $SETTINGS`
- マイグレーションは 1 度だけ。再実行希望時は `index.db` 削除後に再実行
- WSL / cygwin 等の symlink エミュレーション環境は未検証
