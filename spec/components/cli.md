# cc-sessions CLI 詳細仕様

ファイル: `bin/cc-sessions`

## 役割

`~/.claude/sessions/index.db` から過去セッションを fzf TUI で検索し、選択後 `claude --resume <id>` を即実行する。

## 起動形

| 形 | 動作 |
|---|---|
| `cc-sessions` | 現 `$PWD` に紐づくセッション一覧（既定） |
| `cc-sessions --all` | 全 cwd を対象 |
| `cc-sessions --cwd <PATH>` | 指定 cwd のセッション |
| `cc-sessions -h` / `--help` | 使用法表示 |
| `cc-sessions _preview <id>` | （内部用）fzf preview 再帰呼出 |
| `cc-sessions _list <mode> <cwd>` | （内部用）fzf 一覧/reload 用 TSV 出力 |
| `cc-sessions _edit_title <id>` | （内部用）title 1行編集 → DB UPDATE |
| `cc-sessions _edit_summary <id>` | （内部用）`$EDITOR` で summary 編集 → DB UPDATE |

## main フロー

1. **DB 存在確認**: `[ ! -s "$DB" ]` → `exit 1`
2. **モード判定**: 引数解析で `MODE=cwd|all`、`TARGET_CWD` 確定
3. **自身パス解決**: `SELF=$(command -v "$0")` → 絶対パス化（symlink 経由でも実体を取得）
4. **一覧取得**: `"$SELF" _list "$MODE" "$TARGET_CWD"` で TSV 3 列を取得（reload 経路と共通化）
5. **fzf 起動**:
   ```
   fzf --delimiter='\t' --with-nth=2 \
       --preview="$SELF _preview {1}" \
       --preview-window='right:55%:wrap' \
       --bind="ctrl-e:execute($SELF _edit_title {1})+reload($SELF _list MODE CWD)+refresh-preview" \
       --bind="ctrl-s:execute($SELF _edit_summary {1})+reload($SELF _list MODE CWD)+refresh-preview" \
       --header='enter=resume / ctrl-e=edit title / ctrl-s=edit summary / ctrl-c=quit / mode=<MODE> / cols: ended | turns | cwd | title' \
       --ansi
   ```
6. **選択結果から resume**:
   - `id` = `cut -f1`、`cwd` = `cut -f3`
   - cwd が存在ディレクトリかつ現在と異なる → `cd "$SCWD" && exec claude --resume "$ID"`
   - そうでなければ `exec claude --resume "$ID"`

## `_list` サブコマンド

fzf 初期一覧と `reload` バインド先で共通利用。引数: `mode` (`cwd`/`all`) + `cwd` (絶対パス)。

### 処理

- `--all` モード: `WHERE=""`
- `--cwd` モード: `WHERE="WHERE cwd = :cwd"`、`.parameter set :cwd` でバインド
- SELECT 6 列: `id` / `ended_local` / `turns` / `cwd_short` / `title` / `cwd_full`
  - `ended_at` → `strftime('%Y-%m-%d %H:%M', ended_at, 'localtime')` でローカル時刻化
  - `cwd` → `$HOME` プレフィックス一致時 `~/...` 短縮
  - `title` → `NULLIF(title, '')` で空ならば `summary` フォールバック、tab → space 置換、120 文字切詰
  - `ORDER BY ended_at DESC`
- `awk -F'\t'` で `printf "%-16s  %4s turns  %-30s  %s"` 整形 → 3 列 TSV `id\tdisplay_text\tcwd_full` 出力

## `_preview` サブコマンド

fzf プレースホルダ `{1}` がシェル展開時にシングルクォート付与される問題を回避するため、自身を再帰呼出。

```
cc-sessions _preview <ID>
```

### 処理

1. **ID サニタイズ**: `case "$ID" in *[!0-9a-fA-F-]*) echo "invalid id"; exit 1 ;; esac`
   - UUID フォーマット（hex + ハイフン）以外を reject → SQLi 完全防御
2. **SELECT 実行**: `sqlite3 -json "$DB" "SELECT * FROM sessions WHERE id = '$ID';"`
3. **jq 整形出力**:
   ```
   ID:       <id>
   Title:    <title>
   Ended:    <ended_at>
   Turns:    <turns>
   Duration: <sec>
   Reason:   <reason>
   CWD:      <cwd>

   --- Summary ---
   <summary>

   --- Transcript ---
   <path>
   ```

## `_edit_title` / `_edit_summary` サブコマンド

fzf キーバインド (`ctrl-e` / `ctrl-s`) から `execute(...)` 経由で呼出。編集後 `reload(...)` で一覧再描画 + `refresh-preview` で詳細再描画。

### 共通

- ID サニタイズ: `_validate_id` 関数 (UUID hex+ハイフンのみ許可。空 ID も reject)
- DB UPDATE は `.parameter set :id` / `:title` (or `:summary`) のバインド変数経由必須。文字列補間禁止 (SQLi/シェル展開完全防御)
- 編集対象列以外は不変 (`UPDATE sessions SET title = :title WHERE id = :id`)

### `_edit_title <id>`

- 現 title を `printf` で stderr に表示
- `IFS= read -r NEW < /dev/tty` で 1 行入力
- 空入力時はキャンセル (UPDATE 実行せず exit 0)
- 1 行制限 (改行不可)。長文は `_edit_summary` 側を使う想定

### `_edit_summary <id>`

- 現 summary を `mktemp` で一時ファイルに書出
- `${EDITOR:-vi}` 起動 (`< /dev/tty > /dev/tty` で TUI 確保)
- 編集後ファイル内容を読込 → 変更なし時は exit 0 (UPDATE 省略)
- 一時ファイルは `trap 'rm -f "$TMP"' EXIT` で確実削除
- 改行含む複数行可

### 設計判断

- **DB スキーマ不変**: `title` / `summary` 列は元から TEXT NULL 可。新カラム追加なし → マイグレーション不要
- **resume 上書き耐性**: hook 側 `INSERT OR REPLACE` は同セッション再 resume 時に走るが、ユーザー編集 title/summary は次回 resume 終了で上書きされる仕様。意図的編集を残したい場合は別設計 (`is_user_edited` フラグ等) が必要 → 現バージョンでは非対応 (拡張ポイント)

### 設計判断: なぜ `_preview` 再帰呼出か

検討した代替案と却下理由:

| 案 | 問題 |
|---|---|
| `--preview="sqlite3 ... '{1}' ..."` 直接埋込 | fzf が `{1}` をシェルで一重引用符で囲んで展開 → SQL 内で `''value''` となり構文エラー |
| `bash -c '...' _ {1}` ラッパー | 内側の jq quoting がカスケードして parse error |
| `.parameter set :id <値>` ヒアドキュメント | 改行解釈で `.parameter set` がヘルプ扱いされ失敗するケースあり |
| 自身を `_preview` サブコマンド再帰呼出 | quoting 1 段で済む。引数として ID 受領 → サニタイズ → 直接埋込で安全。**採用** |

## SELF パス解決

```bash
SELF="$(command -v "$0" 2>/dev/null || echo "$0")"
case "$SELF" in /*) ;; *) SELF="$PWD/$SELF" ;; esac
```

- 通常呼出 (`cc-sessions`) → `command -v` が `$CC_BIN_DIR/cc-sessions` 解決
- 直接実行 (`./cc-sessions`) → 相対パスを `$PWD` 結合で絶対化
- symlink でも `command -v` はリンクパスを返す。`exec` 呼出時はリンク先で実行されるため問題なし

## 戻り値

| 終了コード | 状況 |
|---|---|
| 0 | resume 実行 / fzf キャンセル / `--help` |
| 1 | DB 不在 / 該当セッションなし / `_preview` で不正 ID |

## 既知の制約

- title / summary に tab 文字含む場合は事前 `REPLACE(..., char(9), ' ')` で除去（TSV 区切り破壊防止）
- 120 文字超 title は切詰のみ。省略記号付加なし
- fzf preview は ID 1 件単位の再 SELECT。大量レコードでも O(1)
