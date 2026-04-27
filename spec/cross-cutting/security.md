# セキュリティ仕様

## 1. 脅威モデル

ローカル単独利用前提のため、攻撃者は基本的に「悪意ある transcript / 設定値」経由でしか触れない。ネットワーク経由の脅威は範囲外。

| 脅威 | 影響 | 対策 |
|---|---|---|
| SQLi via session_id / cwd / title / summary | 任意 SQL 実行 → DB 破壊 | `.parameter set` バインド変数。文字列補間ゼロ |
| SQLi via fzf preview の `{1}` | 任意 SQL 実行 | UUID フォーマット `case` パターンサニタイズ + 直接埋込前に reject |
| settings.json 構造破壊 | Claude Code 起動不能 | jq による構造的更新 + 必ず `.bak.<unixtime>` 取得 |
| symlink 上書き事故 | ユーザー実体ファイル消失 | 既存リンクは `rm`、実体は `mv` で `.bak.<unixtime>` 退避 |
| transcript 巨大化 → jq OOM | hook 失敗 | jq stderr 抑制 + 200 文字切詰で出力サイズ固定 |
| 悪意ある transcript の `<` 始まり content | システムタグ偽装 → 概略汚染 | `select(startswith("<") | not)` で除外 |
| シェル展開時の引数注入 | 任意コマンド実行 | 全変数を `"$VAR"` 形式で quote。`set -u` で未定義変数即エラー |
| SQLite WAL ファイル取り違え | データ整合性破壊 | `index.db-*` を gitignore。バックアップ時は WAL 含めて取得 |

## 2. SQL 安全規約

### 必須ルール

**全ての SQL 文において、外部入力（stdin / 引数 / ファイル）由来の値は `.parameter set :name` バインド変数経由で投入すること。**

```bash
# OK
.parameter set :id $(printf '%s' "$VAR" | jq -Rs .)
SELECT * FROM sessions WHERE id = :id;

# NG（SQLi 化）
sqlite3 "$DB" "SELECT * FROM sessions WHERE id = '$VAR';"
```

### 例外条件

UUID 等のフォーマットを **事前に case パターンマッチで検証** した値のみ、SQL 文字列への直接埋込を許可。

```bash
# 許可される形（cc-sessions の _preview 実装）
case "$ID" in
  *[!0-9a-fA-F-]*) echo "invalid id"; exit 1 ;;
esac
sqlite3 -json "$DB" "SELECT * FROM sessions WHERE id = '$ID';"
```

理由: fzf preview の引数受渡で、バインド変数のヒアドキュメント形式が動作不安定だったため。サニタイズ済み UUID なら攻撃面ゼロ。

### レビュー時のチェックリスト

- [ ] 新規 SQL 文に `${...}` / `$VAR` の直接埋込はないか
- [ ] あった場合、該当値は事前にフォーマット検証済みか
- [ ] バインド変数化できなかった理由が明記されているか

## 3. ファイルシステム安全規約

### バックアップ義務

以下の操作前に必ず `.bak.<unixtime>` で退避:

| 対象 | 操作 | 退避タイミング |
|---|---|---|
| `~/.claude/settings.json` | jq での更新 | install.sh 実行毎 |
| 既存 symlink の実体ファイル | symlink 上書き | install.sh の `link()` 関数 |
| `index.jsonl` | SQLite マイグレーション後 | install.sh のマイグレーション処理末 |

### ディレクトリ作成は `mkdir -p`

並行実行や既存ディレクトリでも失敗しないこと。

### 削除は最小限

- 既存 symlink (`-L` 判定) のみ `rm` 許可
- 実ファイル / 実ディレクトリの `rm` は実装中に追加禁止。必要時は `mv` で `.bak` 退避

## 4. 入力検証

### hook stdin

- `session_id` 必須。不在時 no-op exit
- 他フィールドは `// empty` / `// "default"` で欠損許容
- 数値フィールド（`turns` / `duration_ms`）は jq で抽出 → 直接 SQL 数値リテラル化（jq 出力は安全）

### CLI 引数

| 引数 | 検証 |
|---|---|
| `--cwd <PATH>` | パス文字列のまま使用（`-d` で実在確認は resume 直前） |
| `_preview <ID>` | UUID フォーマット case パターン必須 |
| その他 | `case "${1:-}"` で network 化、未知引数は help へフォールスルー |

## 5. 権限・実行コンテキスト

- hook / CLI は **ユーザー権限** で実行。root / sudo 不要・想定外
- DB ファイルは `~/.claude/sessions/` 配下（既定パーミッション 644 想定）
- symlink 実体は repo 配下（ユーザー所有想定）

## 6. ロギング・監査

現状、実行ログは記録しない。失敗時は標準エラーへの出力のみ。

将来監査要件発生時は:
- hook 実行ログ → `~/.claude/sessions/hook.log`（追記型）
- CLI 実行ログ → 不要（インタラクティブ前提）
