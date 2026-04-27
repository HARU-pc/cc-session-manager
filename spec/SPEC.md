# cc-session-manager 設計仕様書（全体概観）

機能別の詳細仕様は本ファイル末尾「関連ドキュメント」を参照。

## 1. 目的

Claude Code (CLI) のセッション終了時に概略 + resume ID を SQLite DB へ自動保存し、`fzf` TUI で過去セッションを検索 → `claude --resume <id>` を即実行する。

## 2. ユースケース

| ID | シナリオ |
|---|---|
| UC-1 | 別プロジェクトで作業中だったセッションを思い出して再開 |
| UC-2 | 直近終了したセッションを cwd 絞込で素早く再開 |
| UC-3 | タイトル / 概略から過去セッションを横断検索（`--all`） |
| UC-4 | resume したセッションの記録を最新状態で保持（重複行を作らない） |

## 3. システム構成

```
+--------------------+        SessionEnd hook         +--------------------+
| Claude Code CLI    | ─────────────────────────────> | session-end-save.sh |
| (claude)           |  stdin: JSON {session_id,...}  | (bash + jq + sqlite3)|
+--------------------+                                +----------+---------+
         ^                                                       │
         │ exec claude --resume <id>                             │ INSERT OR REPLACE
         │                                                       v
+--------+-----------+    SELECT     +-------------------------------+
| cc-sessions (TUI)  | <───────────> | ~/.claude/sessions/index.db   |
| (bash + fzf + jq   |               | (SQLite, sessions table)      |
|  + sqlite3)        |               +-------------------------------+
+--------------------+
```

## 4. コンポーネント一覧

| コンポーネント | 役割 | 詳細仕様 |
|---|---|---|
| `hooks/session-end-save.sh` | SessionEnd hook 本体。セッション終了時に概略抽出 + DB UPSERT | [components/hook.md](./components/hook.md) |
| `bin/cc-sessions` | fzf TUI ランチャー。一覧 → preview → resume | [components/cli.md](./components/cli.md) |
| `install.sh` | セットアップ + JSONL→SQLite マイグレーション | [components/install.md](./components/install.md) |
| `~/.claude/sessions/index.db` | SQLite DB。`sessions` テーブル | [data/schema.md](./data/schema.md) |

## 5. 主要データフロー

### 5.1 セッション終了 → 記録

```
claude (SessionEnd) ──stdin JSON──> session-end-save.sh
  ├─ session_id 必須チェック
  ├─ transcript_path から最初の user 発話を抽出 → summary (200字)
  ├─ session_title なければ summary を title に流用
  └─ INSERT OR REPLACE INTO sessions (...)
```

### 5.2 一覧 → resume

```
cc-sessions
  ├─ SELECT id, ended_at(local), turns, cwd_short, title FROM sessions WHERE cwd=:cwd
  ├─ awk で表示列整形 → fzf
  ├─ fzf preview: cc-sessions _preview <id> (再帰呼出 + UUID サニタイズ)
  └─ 選択 → cd <cwd> && exec claude --resume <id>
```

## 6. 横断的方針

| 項目 | 方針 |
|---|---|
| SQL 安全性 | バインド変数 `.parameter set :name` 必須。文字列補間禁止（例外: UUID 等フォーマット検証済み値のみ） |
| 冪等性 | `install.sh` / hook の DDL は `CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS` |
| 後方互換 | 既存ユーザーの `~/.claude/sessions/` は破壊しない。スキーマ変更時は `install.sh` にマイグレーション追加 |
| バックアップ | `settings.json` / 既存 symlink 実体は `.bak.<unixtime>` で退避 |
| 依存 | `bash` / `jq` / `sqlite3` / `fzf` / `claude` のみ。追加禁止（不可避時のみ README + install 同時更新） |

## 7. 非目標

- 複数マシン間 DB 同期（個人ローカル前提）
- セッション内容の改竄防止（透過的記録のみ）
- Windows ネイティブ対応（macOS / Linux + bash 前提）
- LLM による高品質要約（拡張アイデア。本体は軽量抽出のみ）

## 8. 既知の制約

- `matcher` 非対応 hook 仕様のため SessionEnd ブロック制御不可
- `claude --resume` の ID 期限切れ・transcript 削除時はエラー（DB 側では検知不可）
- fzf 未インストール環境では TUI 起動不可（hook は単独動作）

## 9. パフォーマンス想定

| 操作 | 想定計算量 | 実測目安 |
|---|---|---|
| hook 1回 | O(transcript_size) — jq 1パス | 〜数百 ms |
| 一覧表示（cwd絞込） | O(log n) — `idx_sessions_cwd` 利用 | <50ms / 数千件 |
| 一覧表示（--all） | O(n) — フルスキャン | <200ms / 1万件 |
| preview 1回 | O(1) — PRIMARY KEY 検索 | <10ms |

ローカル単独利用前提で 10万件超えても実用範囲。

## 10. 拡張ポイント（ロードマップ候補）

- 概略品質向上: 軽量抽出 → LLM 要約（`gemini` 等）切替
- 自動アーカイブ: 30 日超レコード削除コマンド
- タグ付け: `tags TEXT` 列追加 + 手動マーク UI
- 全文検索: `cc-sessions --grep <keyword>`（`LIKE` → 規模次第で FTS5 仮想テーブル）
- export: `--export json|csv` で他ツール連携

## 関連ドキュメント

### components/ — 実装単位の詳細

- [components/hook.md](./components/hook.md) — SessionEnd hook 詳細仕様
- [components/cli.md](./components/cli.md) — `cc-sessions` TUI 詳細仕様
- [components/install.md](./components/install.md) — `install.sh` 詳細仕様

### data/ — データ設計

- [data/schema.md](./data/schema.md) — DB スキーマ + ファイル配置

### cross-cutting/ — 横断関心事

- [cross-cutting/security.md](./cross-cutting/security.md) — 脅威モデル + 対策
- [cross-cutting/conventions.md](./cross-cutting/conventions.md) — コーディング規約・命名・運用ルール
