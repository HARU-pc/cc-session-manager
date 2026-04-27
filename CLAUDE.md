# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## アーキテクチャ概観

Claude Code (CLI) の `SessionEnd` hook を起点に、終了セッションの概略+resume IDを SQLite (`~/.claude/sessions/index.db`) に UPSERT 保存し、`fzf` TUI から検索 → `claude --resume <id>` を実行する仕組み。3コンポーネント構成:

- `hooks/session-end-save.sh` — Claude Code から stdin JSON (`session_id` / `transcript_path` / `cwd` / `reason` / `turn_count` / `duration_ms` 等) を受け、transcript JSONL から最初の非 sidechain `user` 発話を 200 字抽出 → `INSERT OR REPLACE INTO sessions`。`session_id` 主キーで resume 上書き対応。
- `bin/cc-sessions` — fzf TUI ランチャー。デフォルトは現在 `cwd` で絞込、`--all` で全件、`--cwd <path>` で指定。preview は内部 `_preview` サブコマンド再帰呼出 (UUID 形式チェックでサニタイズ)。Enter で `cd <cwd> && exec claude --resume <id>`。
- `install.sh` — `~/.local/bin/cc-sessions` と `~/.claude/hooks/session-end-save.sh` へ symlink、`~/.claude/settings.json` に `SessionEnd` hook 登録 (既存設定 `.bak.<unixtime>` 退避)、旧 `index.jsonl` があれば SQLite へマイグレーション。

データフロー・スキーマ・脅威モデル等の設計詳細は **`spec/SPEC.md` をエントリポイント** として `spec/components/` `spec/data/` `spec/cross-cutting/` 配下を参照。実装変更前に必ず該当 spec を読む。

## 主要コマンド

```sh
# インストール (symlink + settings.json hook 登録)
./install.sh

# fzf TUI 起動 (現 cwd)
cc-sessions
cc-sessions --all                 # 全 cwd
cc-sessions --cwd /path/to/proj   # 指定 cwd

# hook 単体テスト (動作確認の標準手順)
echo '{"session_id":"test","transcript_path":"/tmp/x","cwd":"/tmp","reason":"clear","turn_count":1,"duration_ms":1000}' \
  | bash ~/.claude/hooks/session-end-save.sh
sqlite3 -json ~/.claude/sessions/index.db "SELECT * FROM sessions WHERE id='test'" | jq .

# DB 直接確認
sqlite3 ~/.claude/sessions/index.db \
  "SELECT id, ended_at, turns, title FROM sessions ORDER BY ended_at DESC LIMIT 5;"

# DB リセット
sqlite3 ~/.claude/sessions/index.db "DELETE FROM sessions;"
```

テストフレームワーク無し。変更ファイル別の最低限チェック:

- `hooks/session-end-save.sh` 変更時 → 上記 hook 単体テストコマンド
- `bin/cc-sessions` 変更時 → ローカル DB に対し fzf 起動 + preview 表示確認
- `install.sh` 変更時 → 別マシン or `CC_BIN_DIR=~/scripts ./install.sh` で再現確認

## ブランチ運用

main への直 commit / 直 push 禁止。**必ず branch を切って PR 経由**:

1. `git checkout -b <topic-branch>`
2. 変更 commit
3. `git push -u origin <topic-branch>`
4. `gh pr create`
5. レビュー後 main へ merge

README typo 等軽微修正も原則 PR (履歴追跡性のため)。

## コミット規約

subject 先頭に `[xxx]` プレフィックス必須。1 PR 1 トピック。

| プレフィックス | 用途 |
|---|---|
| `[feat]` | 新機能追加 |
| `[fix]` | バグ修正 |
| `[update]` | 既存機能の改善・更新 |
| `[refactor]` | 挙動を変えないリファクタ |
| `[docs]` | ドキュメントのみ変更 (spec のみの誤字修正含む) |
| `[chore]` | ビルド・補助ツール・依存等 |
| `[test]` | テスト追加・修正 |

例: `[fix] fzf preview の SQL 組立を _preview サブコマンド化`

## セキュリティ

- SQL 組立は `.parameter set` バインド変数必須。文字列補間禁止 (外部入力混入時 SQLi 化)
- 例外: UUID 等フォーマット検証済み値のみ直接埋め込み可 (現 `bin/cc-sessions` の `_preview` サブコマンド case サニタイズ参照)

## 互換性

- `index.db` スキーマ変更時は `install.sh` にマイグレーション追加。既存ユーザーの DB を壊さない
- `settings.json` 操作時は必ずバックアップ (`.bak.<timestamp>`)

## 依存

`bash` / `jq` / `sqlite3` / `fzf` / `claude` のみ。**追加禁止**。不可避な場合は README の「依存」節と `install.sh` の依存チェックに同時反映。

## 仕様書 — 単一ソース

設計仕様は `spec/` 配下を単一ソース。

```
spec/
├── SPEC.md             全体概観 (必ずここから読む)
├── components/         実装単位の詳細
│   ├── hook.md         hooks/session-end-save.sh
│   ├── cli.md          bin/cc-sessions
│   └── install.md      install.sh
├── data/
│   └── schema.md       DB スキーマ + ファイル配置 + マイグレーション履歴
└── cross-cutting/      横断関心事
    ├── security.md     脅威モデル + SQL/FS 安全規約
    └── conventions.md  コーディング規約 + 運用ルール
```

### 更新義務 (同一 PR 内で必須)

| 変更内容 | 更新対象 |
|---|---|
| 新コンポーネント追加 | `spec/components/<name>.md` 新規 + `spec/SPEC.md` の関連ドキュメント節追記 |
| 既存コンポーネント挙動変更 | 該当 `spec/components/<name>.md` |
| DB スキーマ変更 | `spec/data/schema.md` + マイグレーション履歴節 |
| セキュリティ規約変更 | `spec/cross-cutting/security.md` |
| コーディング規約・運用ルール変更 | `spec/cross-cutting/conventions.md` |
| ユーザー向け手順変更 | `README.md` (spec ではない) |

### 役割分担 — 混在禁止

- `README.md` — ユーザー向け手順 (インストール / 使用方法 / トラブル対応)
- `spec/` — 設計判断・データモデル・拡張ポイント・脅威モデル
- `CLAUDE.md` — AI 向け運用ルール (本ファイル)

README に設計判断を書かない。spec に手順を書かない。
