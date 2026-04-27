# cc-session-manager

Claude Code セッション終了時に概略+resume IDを自動保存し、fzf TUIから検索・再開する仕組み。

## Claude Code 標準 `--resume` との比較

`claude --resume` は対話 UI 内蔵の resume picker。本ツールは外部 SQLite + fzf による拡張。

| 項目 | 標準 `claude --resume` | cc-sessions |
|---|---|---|
| 起動方法 | `claude --resume` (対話 picker) / `claude --resume <id>` (直接) | `cc-sessions` (fzf TUI) / `claude --resume <id>` (直接) |
| 一覧データ源 | Claude Code 内部状態 | `~/.claude/sessions/index.db` (SQLite) |
| cwd 絞込 | プロジェクト単位の自動絞込 | 既定 現 cwd / `--all` 全件 / `--cwd <path>` 指定 |
| 概略表示 | 直近メッセージ抜粋 | 最初のユーザー発話 先頭 200 字 (SessionEnd 時抽出) |
| タイトル編集 | 不可 | `Ctrl-E` で編集 |
| 概略編集 | 不可 | `Ctrl-S` で `$EDITOR` 起動 |
| 終了理由記録 | なし | `reason` カラム (clear/resume/logout 等) |
| ターン数・経過時間 | 表示なし | `turns` / `duration_ms` 記録 |
| 全文検索 | picker 内 fuzzy | fzf fuzzy + SQL 直叩き可 |
| プロジェクト跨ぎ検索 | 制限あり | `--all` で全 cwd 横断 |
| 外部依存 | なし | `fzf` / `jq` / `sqlite3` 必要 |
| データ永続性 | Claude Code 管理 (内部仕様変更で消失リスク) | 独立 DB (本ツール側で寿命管理) |

使い分け: 同一プロジェクト内 直近 resume → 標準で十分。プロジェクト跨ぎ検索・編集メモ・終了理由フィルタ → cc-sessions。

## 依存

`fzf` / `jq` / `sqlite3` / `bash` / `claude` (Claude Code CLI)

## インストール

```sh
git clone https://github.com/HARU-pc/cc-session-manager.git ~/projects/cc-session-manager
cd ~/projects/cc-session-manager
./install.sh
```

`install.sh` の動作:
- `bin/cc-sessions` を `~/.local/bin/cc-sessions` に symlink（`CC_BIN_DIR` で配置先変更可、例: `CC_BIN_DIR=~/scripts ./install.sh`）
- `hooks/session-end-save.sh` を `~/.claude/hooks/session-end-save.sh` に symlink
- `~/.claude/settings.json` に SessionEnd hook 登録（既存設定はバックアップ）
- `~/.claude/sessions/` ディレクトリ作成

## ファイル構成（インストール後）

- `<repo>/hooks/session-end-save.sh` — SessionEnd hook 本体
- `<repo>/bin/cc-sessions` — fzf TUI ランチャー
- `~/.claude/hooks/session-end-save.sh` → repo への symlink
- `~/.local/bin/cc-sessions` → repo への symlink（or `$CC_BIN_DIR/cc-sessions`）
- `~/.claude/sessions/index.db` — セッション記録 DB（SQLite、gitignore 済）
- `~/.claude/settings.json` — hook 登録

## SessionEnd hook 仕様

### stdin JSON フィールド

| キー | 型 | 内容 |
|---|---|---|
| `session_id` | string | resume 用 ID |
| `transcript_path` | string | 会話ログ（JSONL）絶対パス |
| `cwd` | string | セッション作業ディレクトリ |
| `hook_event_name` | string | `"SessionEnd"` 固定 |
| `reason` | string | 終了理由（下記参照） |
| `session_title` | string? | セッションタイトル（任意） |
| `turn_count` | number | ターン数 |
| `duration_ms` | number | 経過ミリ秒 |

### `reason` 値

`clear` / `resume` / `logout` / `prompt_input_exit` / `bypass_permissions_disabled` / `other`

### settings.json 登録

`matcher` 非対応。`hooks.SessionEnd[].hooks[]` に直接配置。decision control 不可（ブロック不可）。

```json
"SessionEnd": [
  {
    "hooks": [
      {
        "type": "command",
        "command": "bash \"$HOME/.claude/hooks/session-end-save.sh\""
      }
    ]
  }
]
```

## transcript JSONL 構造（参考）

各行 1 イベント。主要 type:

- `file-history-snapshot` — ファイル変更スナップショット
- `user` — ユーザー発話。`message.content` は string or `[{type:"text",text:...}]`
- `assistant` — アシスタント発話
- フィールド: `cwd` / `gitBranch` / `isSidechain` / `message` / `parentUuid` / `sessionId` / `timestamp` / `type` / `uuid` / `version` 等

軽量抽出方式: `type=="user"` かつ `isSidechain != true` の最初のメッセージから text を結合し先頭 200 文字を概略とする。LLM 呼出なし。

## index.db スキーマ（SQLite）

```sql
CREATE TABLE sessions (
  id          TEXT PRIMARY KEY,    -- session_id（resume用）
  cwd         TEXT,                -- 作業ディレクトリ
  ended_at    TEXT NOT NULL,       -- UTC ISO8601
  reason      TEXT,                -- 終了理由
  title       TEXT,                -- タイトル or 概略
  summary     TEXT,                -- 最初のユーザー発話 先頭200文字
  turns       INTEGER DEFAULT 0,
  duration_ms INTEGER DEFAULT 0,
  transcript  TEXT                 -- transcript絶対パス
);
CREATE INDEX idx_sessions_cwd      ON sessions(cwd);
CREATE INDEX idx_sessions_ended_at ON sessions(ended_at DESC);
```

`id` 主キーのため、resume保存時は `INSERT OR REPLACE` で同レコード上書き（重複なし）。

---

## 使用方法

### 日常利用

#### セッション一覧（現 cwd 絞込）

```sh
cc-sessions
```

fzf 起動。↑↓で選択、Enter で `claude --resume <id>` 実行。preview に JSON 全項目表示。

#### キーバインド

| キー | 動作 |
|---|---|
| `Enter` | `claude --resume <id>` 実行 |
| `Ctrl-E` | 選択行の **title 編集** (1行入力。空入力でキャンセル) |
| `Ctrl-S` | 選択行の **summary 編集** (`$EDITOR` 起動。複数行可。未設定時 `vi`) |
| `Ctrl-C` | 終了 |

編集後は一覧と preview が即時 reload。

> **注意**: 同セッションを再 resume → 終了すると hook の `INSERT OR REPLACE` でユーザー編集の title/summary が上書きされる。永続的にメモを残したい場合は別カラム化が必要 (拡張ポイント)。

#### 全セッション

```sh
cc-sessions --all
```

cwd 関係なく全件表示。プロジェクト跨ぎで探す時。

#### 指定 cwd

```sh
cc-sessions --cwd /path/to/project
```

#### 直接 resume（fzf 不要）

```sh
claude --resume <session_id>
```

index.jsonl から ID 直接コピーして使う場合。

### セッション記録の確認

```sh
sqlite3 ~/.claude/sessions/index.db \
  "SELECT id, ended_at, turns, title FROM sessions ORDER BY ended_at DESC LIMIT 5;"
```

JSON で見たい場合:
```sh
sqlite3 -json ~/.claude/sessions/index.db \
  "SELECT * FROM sessions ORDER BY ended_at DESC LIMIT 5" | jq .
```

### 記録のリセット

```sh
sqlite3 ~/.claude/sessions/index.db "DELETE FROM sessions;"
# or 全DB削除
rm ~/.claude/sessions/index.db
```

## 動作確認

hook 単体テスト:

```sh
echo '{"session_id":"test","transcript_path":"/tmp/x","cwd":"/tmp","reason":"clear","turn_count":1,"duration_ms":1000}' \
  | bash ~/.claude/hooks/session-end-save.sh
sqlite3 -json ~/.claude/sessions/index.db "SELECT * FROM sessions WHERE id='test'" | jq .
```

## トラブルシューティング

| 症状 | 原因・対処 |
|---|---|
| index.db に追記されない | hook 未発火。`reason` 確認。Claude Code 再起動後試す |
| `cc-sessions: command not found` | `$CC_BIN_DIR`（既定 `~/.local/bin`）が PATH 未追加。`export PATH="$HOME/.local/bin:$PATH"` を rc に追記 |
| fzf preview 文字化け | `LC_ALL=ja_JP.UTF-8 cc-sessions` |
| 概略が空 | transcript に user メッセージ無し or `isSidechain=true` のみ |
| resume 失敗 | session_id 期限切れ・transcript 削除済み。`claude --resume` 直接で確認 |

## 拡張アイデア

- 概略品質向上: 軽量抽出 → LLM 要約（gemini 等）への切替
- 自動アーカイブ: 古いレコード削除（30日以上等）
- タグ付け: 手動マーク列追加
- 全文検索: `cc-sessions` に `--grep <keyword>` 追加

## License

MIT License — see [LICENSE](LICENSE)
