# コーディング規約・運用ルール

## 1. シェルスクリプト規約

### 基本

- shebang: `#!/usr/bin/env bash`
- `set -u` 必須（未定義変数即エラー）
- `set -e` は **必要箇所のみ** 採用。hook 系では `exit 0` 固定の方が事故が少ない
- 全変数は `"$VAR"` 形式で quote
- ファイル冒頭に 2 行コメントで「役割 + 主要設計判断」記述

### 命名

- 関数: `snake_case`
- 環境変数（公開）: `CC_<SCREAMING_SNAKE_CASE>` プレフィックス（例: `CC_BIN_DIR`）
- ローカル変数: 短く一意（`SELF` / `MODE` / `WHERE` 等の慣用名 OK）
- サブコマンド名: `_` プレフィックスで内部用を明示（例: `_preview`）

### コメント

- 1 行 / ブロック共に「**WHY** を書く」。WHAT は識別子で表現
- 設計判断（quoting 地獄回避等）は該当箇所直前に明記

## 2. SQL 規約

詳細: [security.md](./security.md) §2

要点:
- 外部入力は `.parameter set :name` バインド変数必須
- 例外は UUID 等フォーマット検証済み値のみ
- DDL は `CREATE ... IF NOT EXISTS` で冪等化

## 3. JSON / jq 規約

- 文字列化: `printf '%s' "$VAR" | jq -Rs .`（`-R`=raw input, `-s`=slurp）
- 欠損許容: `// empty` / `// "default"`
- 1 行出力: `jq -c`、整形出力: `jq .`

## 4. ディレクトリ・ファイル命名

```
<repo>/
├── bin/              実行可能スクリプト（symlink 配置元）
├── hooks/            Claude Code hook スクリプト
├── install.sh        セットアップ
├── README.md         ユーザー向け手順書
├── CLAUDE.md         AI 向け運用ルール
└── spec/             設計仕様書
    ├── SPEC.md       全体概観（エントリポイント）
    ├── components/   実装単位の詳細仕様
    ├── data/         データモデル
    └── cross-cutting/ 横断関心事
```

新規コンポーネント追加時は `spec/components/<name>.md` を新規作成し、`SPEC.md` の関連ドキュメント節に追記。

## 5. コミット規約

詳細: `CLAUDE.md` §コミット規約

要点:
- subject 先頭に `[feat]` / `[fix]` / `[update]` / `[refactor]` / `[docs]` / `[chore]` / `[test]` プレフィックス必須
- subject 1 行・簡潔要約、body で詳細
- 1 PR 1 トピック

## 6. ブランチ・PR 運用

詳細: `CLAUDE.md` §ブランチ運用

要点:
- main 直 commit 禁止
- topic ブランチ → PR → merge
- 軽微な修正でも PR 経由

## 7. 仕様書更新ルール

機能追加・データモデル変更・コンポーネント間責務変更時は **同一 PR 内で `spec/` を更新** すること。

| 変更内容 | 更新対象 |
|---|---|
| 新コンポーネント追加 | `spec/components/<name>.md` 新規 + `spec/SPEC.md` 関連ドキュメント節追記 |
| 既存コンポーネント挙動変更 | 該当 `spec/components/<name>.md` |
| DB スキーマ変更 | `spec/data/schema.md` + マイグレーション履歴節 |
| セキュリティ規約変更 | `spec/cross-cutting/security.md` |
| 規約自体の変更 | 本ファイル |
| ユーザー向け手順変更 | `README.md` |

README と spec の役割を混在させない。README はユーザー向け手順、spec は設計判断。

## 8. 動作確認義務

変更ファイル別の最低限テスト:

| 変更ファイル | 確認方法 |
|---|---|
| `hooks/session-end-save.sh` | `spec/components/hook.md` のテストコマンド実行 |
| `bin/cc-sessions` | ローカル DB に対し fzf 起動 → preview 表示確認 |
| `install.sh` | 別マシン or `CC_BIN_DIR` 切替で再現確認、または既存 `~/.claude/sessions/` を退避してから再実行 |

## 9. 依存追加禁止

`bash` / `jq` / `sqlite3` / `fzf` / `claude` 以外の依存追加は原則禁止。

不可避な場合のみ:
1. 追加理由を PR description に明記
2. README §依存 へ追記
3. `install.sh` の依存チェックブロックへ追加
4. `spec/components/install.md` 更新
