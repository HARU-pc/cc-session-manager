# SessionEnd hook 詳細仕様

ファイル: `hooks/session-end-save.sh`

## 役割

Claude Code セッション終了時に発火し、セッション概略 + resume ID を `~/.claude/sessions/index.db` へ UPSERT する。

## 起動経路

`~/.claude/settings.json` の `hooks.SessionEnd[].hooks[]` に登録された command 経由で起動。

```json
"SessionEnd": [
  { "hooks": [{ "type": "command", "command": "bash \"$HOME/.claude/hooks/session-end-save.sh\"" }] }
]
```

## 入力 (stdin JSON)

| キー | 型 | 必須 | 内容 |
|---|---|---|---|
| `session_id` | string | ◯ | resume 用 ID（UUID） |
| `transcript_path` | string | △ | 会話ログ JSONL 絶対パス |
| `cwd` | string | △ | セッション作業ディレクトリ |
| `hook_event_name` | string | — | `"SessionEnd"` 固定 |
| `reason` | string | — | `clear` / `resume` / `logout` / `prompt_input_exit` / `bypass_permissions_disabled` / `other` |
| `session_title` | string | — | セッションタイトル |
| `turn_count` | number | — | ターン数 |
| `duration_ms` | number | — | 経過ミリ秒 |

`session_id` 不在時は no-op 終了。

## 処理フロー

1. **stdin 全読込** → `INPUT` 変数
2. **フィールド抽出**: `jq -r '.<field> // empty'` / `// "default"`
3. **session_id 必須チェック** → 不在なら `exit 0`
4. **概略生成** (`transcript_path` 存在時のみ):
   ```jq
   map(select(.type=="user" and (.isSidechain // false) == false))
   | map(.message.content)
   | map(if type=="string" then . elif type=="array" then (map(select(.type=="text") | .text) | join(" ")) else "" end)
   | map(select(length > 0 and (startswith("<") | not)))
   | .[0] // ""
   ```
   - `type=="user"` かつ `isSidechain != true` のメッセージのみ
   - content が string / array どちらでも text 抽出
   - 空文字 / `<` 始まり（システムタグ等）を除外
   - 最初の 1 件を採用、改行 → スペース、200 文字切詰
5. **title 補完**: `session_title` 空なら `summary` を流用
6. **ended_at 生成**: `date -u +%Y-%m-%dT%H:%M:%SZ`
7. **DDL + UPSERT** を 1 つの `sqlite3` ヒアドキュメントで実行（接続オープン 1 回で完結）

## SQL

```sql
CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY, cwd TEXT, ended_at TEXT NOT NULL,
  reason TEXT, title TEXT, summary TEXT,
  turns INTEGER DEFAULT 0, duration_ms INTEGER DEFAULT 0, transcript TEXT
);
CREATE INDEX IF NOT EXISTS idx_sessions_cwd      ON sessions(cwd);
CREATE INDEX IF NOT EXISTS idx_sessions_ended_at ON sessions(ended_at DESC);

.parameter set :id        "<jq -Rs>"
.parameter set :cwd       "<jq -Rs>"
... (全 9 カラム)

INSERT OR REPLACE INTO sessions (...) VALUES (:id, :cwd, ...);
```

`INSERT OR REPLACE` により同一 `id` の既存行は完全置換 → resume 保存時の重複排除。

## SQLi 対策

- 全文字列パラメータを `printf '%s' "$VAR" | jq -Rs .` で JSON 文字列化 → `.parameter set` のリテラル引数に投入
- 数値パラメータ（`turns` / `duration`）は jq 経由で抽出済み。シェル展開時の混入リスクなし
- ユーザー入力（session_title 等）に SQL メタ文字含まれてもバインド変数として安全に扱われる

## 終了コード

| 終了コード | 状況 |
|---|---|
| 0 | 正常完了 / `session_id` 不在で no-op |
| 0 | sqlite3 失敗時も `exit 0`（`set -u` のみ、`set -e` 未使用） |

hook はセッション終了処理を妨げない方針 (`exit 0` 固定)。エラーログは sqlite3 stderr に流れる。

## 副作用

- DB ファイル: `~/.claude/sessions/index.db`（不在時 `mkdir -p` で作成）
- WAL モード時: `index.db-wal` / `index.db-shm` 生成（gitignore 済）

## テスト

```sh
echo '{"session_id":"test-uuid","transcript_path":"/tmp/x","cwd":"/tmp","reason":"clear","turn_count":1,"duration_ms":1000}' \
  | bash ~/.claude/hooks/session-end-save.sh
sqlite3 -json ~/.claude/sessions/index.db "SELECT * FROM sessions WHERE id='test-uuid'" | jq .
sqlite3 ~/.claude/sessions/index.db "DELETE FROM sessions WHERE id='test-uuid'"
```

## 既知の制約

- `matcher` 非対応 → 全 SessionEnd で発火（特定 reason のみ等の絞込不可）
- decision control 不可（hook はブロック不能）
- transcript 巨大時 jq が遅い可能性あり。実測で問題化したら head 制限検討
