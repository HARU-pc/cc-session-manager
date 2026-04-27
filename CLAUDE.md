# cc-session-manager — Repo Rules

## ブランチ運用

今後の変更は **必ず branch を切って PR 経由で main に反映** すること。main への直 commit / 直 push 禁止。

### 手順

1. `git checkout -b <topic-branch>` で作業ブランチ作成
2. 変更 commit
3. `git push -u origin <topic-branch>`
4. `gh pr create` で PR 作成
5. レビュー後 main へ merge

### 例外

- README typo 修正など軽微な文書のみ変更時も、原則 PR を通すこと（履歴追跡性のため）

## コミット規約

### プレフィックス必須

subject 先頭に変更種別プレフィックスを `[xxx]` 形式で付与。

| プレフィックス | 用途 |
|---|---|
| `[feat]` | 新機能追加 |
| `[fix]` | バグ修正 |
| `[update]` | 既存機能の改善・更新 |
| `[refactor]` | 挙動を変えないリファクタ |
| `[docs]` | ドキュメントのみ変更 |
| `[chore]` | ビルド・補助ツール・依存等 |
| `[test]` | テスト追加・修正 |

例: `[fix] fzf preview の SQL 組立を _preview サブコマンド化`

### 構成

- subject + body 構成。subject は1行・簡潔要約
- 1 PR 1 トピック。無関係変更を混ぜない

## 動作確認

変更ファイル別の最低限チェック:

- `hooks/session-end-save.sh` 変更時: README の hook 単体テストコマンドで動作確認
- `bin/cc-sessions` 変更時: ローカル DB に対し fzf 起動 → preview 表示確認
- `install.sh` 変更時: 別マシン or `CC_BIN_DIR` 切替で再現確認

## セキュリティ

- SQL 組立時は `.parameter set` バインド変数必須。文字列補間禁止（外部入力混入時 SQLi 化）
- 例外: UUID 等フォーマット検証済み値のみ直接埋め込み可（現 `bin/cc-sessions` の `_preview` サブコマンド case サニタイズ参照）

## 互換性

- `index.db` スキーマ変更時は `install.sh` にマイグレーション追加。既存ユーザーの DB を壊さない
- `settings.json` 操作時は必ずバックアップ（`.bak.<timestamp>`）

## 依存

- bash / jq / sqlite3 / fzf / claude 以外の依存追加禁止
- 追加が不可避な場合は README の「依存」節と `install.sh` の依存チェックに同時反映

## 仕様書

設計仕様は `spec/` 配下を単一ソースとする。`spec/SPEC.md` がエントリポイント。

### ディレクトリ構成

```
spec/
├── SPEC.md             全体概観（必ずここから読む）
├── components/         実装単位の詳細
│   ├── hook.md         hooks/session-end-save.sh
│   ├── cli.md          bin/cc-sessions
│   └── install.md      install.sh
├── data/
│   └── schema.md       DBスキーマ + ファイル配置 + マイグレーション履歴
└── cross-cutting/      横断関心事
    ├── security.md     脅威モデル + SQL/FS安全規約
    └── conventions.md  コーディング規約 + 運用ルール
```

### 更新義務

変更内容に応じて、**同一 PR 内で** 該当仕様書を更新すること。

| 変更内容 | 更新対象 |
|---|---|
| 新コンポーネント追加 | `spec/components/<name>.md` 新規 + `spec/SPEC.md` の関連ドキュメント節追記 |
| 既存コンポーネント挙動変更 | 該当 `spec/components/<name>.md` |
| DB スキーマ変更 | `spec/data/schema.md` + マイグレーション履歴節 |
| セキュリティ規約変更 | `spec/cross-cutting/security.md` |
| コーディング規約・運用ルール変更 | `spec/cross-cutting/conventions.md` |
| ユーザー向け手順変更 | `README.md`（spec ではない） |

### 役割分担

- `README.md` — ユーザー向け手順（インストール / 使用方法 / トラブル対応）
- `spec/` — 設計判断・データモデル・拡張ポイント・脅威モデル
- `CLAUDE.md` — AI 向け運用ルール（本ファイル）

役割を混在させない。README に設計判断を書かない、spec に手順を書かない。

### 軽微な修正

仕様書のみの誤字・表現修正は `[docs]` プレフィックスで OK。
