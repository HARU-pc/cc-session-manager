# データモデル仕様

## 1. SQLite DB

### ファイル

`~/.claude/sessions/index.db`

WAL モード時は `index.db-wal` / `index.db-shm` が同階層に生成される（gitignore 済）。

### `sessions` テーブル

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
  transcript  TEXT                 -- transcript 絶対パス
);
```

### カラム詳細

| カラム | 型 | 制約 | 内容 | 例 |
|---|---|---|---|---|
| `id` | TEXT | PRIMARY KEY | Claude Code の session_id（UUID v4） | `055b9dae-a52c-43e0-955a-79b24aca3e47` |
| `cwd` | TEXT | NULL 可 | セッションの作業ディレクトリ絶対パス | `/Users/haru/projects/cc-session-manager` |
| `ended_at` | TEXT | NOT NULL | 終了時刻 UTC ISO8601 | `2026-04-27T05:32:18Z` |
| `reason` | TEXT | NULL 可 | 終了理由 | `clear` / `resume` / `logout` / `prompt_input_exit` / `bypass_permissions_disabled` / `other` |
| `title` | TEXT | NULL 可 | タイトル（未設定時 summary 流用） | `cc-sessionsの検索でサマリーをﾐﾔｽｸ` |
| `summary` | TEXT | NULL 可 | 最初の user 発話先頭 200 字 | `claude code終了時など...` |
| `turns` | INTEGER | DEFAULT 0 | ターン数 | `42` |
| `duration_ms` | INTEGER | DEFAULT 0 | 経過ミリ秒 | `1843200` |
| `transcript` | TEXT | NULL 可 | transcript JSONL 絶対パス | `/Users/haru/.claude/projects/.../<id>.jsonl` |

### インデックス

```sql
CREATE INDEX idx_sessions_cwd      ON sessions(cwd);
CREATE INDEX idx_sessions_ended_at ON sessions(ended_at DESC);
```

| インデックス | 想定クエリ |
|---|---|
| `idx_sessions_cwd` | `WHERE cwd = ?` 絞込（`cc-sessions` 既定動作） |
| `idx_sessions_ended_at` | `ORDER BY ended_at DESC` 一覧表示 |

### 設計判断

- **PRIMARY KEY = session_id**: resume 時の上書きを `INSERT OR REPLACE` で実現。append-only JSONL 時代の重複行問題を解消
- **ended_at は TEXT (ISO8601)**: SQLite に専用日時型なし。strftime 関数で localtime 変換可能。文字列比較で正しくソート可能
- **summary 200 字制限**: hook 内で切詰。DB 制約ではなくアプリ層担保（柔軟性確保）
- **正規化なし**: cwd 等の繰返し値があっても単一テーブル。クエリ単純さ優先

## 2. ファイル配置

| パス | 役割 | git 管理 |
|---|---|---|
| `<repo>/hooks/session-end-save.sh` | hook 本体 | ◯ |
| `<repo>/bin/cc-sessions` | TUI ランチャー | ◯ |
| `<repo>/install.sh` | セットアップ | ◯ |
| `<repo>/spec/` | 仕様書群 | ◯ |
| `<repo>/.private/` | ローカル作業領域 | ✕（gitignore） |
| `~/.claude/hooks/session-end-save.sh` | repo への symlink | — |
| `~/.local/bin/cc-sessions` (or `$CC_BIN_DIR/`) | repo への symlink | — |
| `~/.claude/sessions/index.db` | SQLite DB 本体 | — |
| `~/.claude/sessions/index.db-{wal,shm}` | SQLite ジャーナル | — |
| `~/.claude/sessions/index.jsonl.bak.<ts>` | マイグレーション後の旧 JSONL（参考保管） | — |
| `~/.claude/settings.json` | hook 登録 | — |
| `~/.claude/settings.json.bak.<ts>` | install 実行毎のバックアップ | — |

## 3. transcript JSONL 構造（参考）

`~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`

各行 1 イベント。主要 type:

| type | 内容 |
|---|---|
| `file-history-snapshot` | ファイル変更スナップショット |
| `user` | ユーザー発話。`message.content` は string or `[{type:"text",text:...}]` |
| `assistant` | アシスタント発話 |

主要フィールド: `cwd` / `gitBranch` / `isSidechain` / `message` / `parentUuid` / `sessionId` / `timestamp` / `type` / `uuid` / `version`

hook の概略抽出は `type=="user"` かつ `isSidechain != true` の最初の 1 件から text 結合。

## 4. マイグレーション履歴

### v0 → v1: JSONL → SQLite（実装済）

- 変更時期: 初期版
- 旧形式: `~/.claude/sessions/index.jsonl`（append-only）
- 新形式: `~/.claude/sessions/index.db`（SQLite, `sessions` テーブル）
- 移行ツール: `install.sh`（`index.jsonl` 存在 & `index.db` 不在時に自動実行）
- 後方互換: なし（旧 JSONL は `.bak.<ts>` 退避後リタイア）

### 将来のスキーマ変更ポリシー

- `install.sh` 内にマイグレーション処理追加。既存 `index.db` の `PRAGMA user_version` 等で世代判定
- 破壊的変更時は `index.db.bak.<ts>` 自動退避
- README / 本ファイル「マイグレーション履歴」節へ追記必須
