# cc-session-manager

Claude Code セッション終了時に概略+resume IDを自動保存し、fzf TUIから検索・再開する仕組み。

## 依存

`fzf` / `jq` / `bash` / `claude` (Claude Code CLI)

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
- `~/.claude/sessions/index.jsonl` — セッション記録 DB（追記型 JSONL、gitignore 済）
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

## index.jsonl レコード構造

```json
{
  "id": "<session_id>",
  "cwd": "<作業ディレクトリ>",
  "ended_at": "<UTC ISO8601>",
  "reason": "<終了理由>",
  "title": "<タイトル or 概略>",
  "summary": "<最初のユーザー発話 先頭200文字>",
  "turns": <number>,
  "duration_ms": <number>,
  "transcript": "<transcript絶対パス>"
}
```

---

## 使用方法

### 日常利用

#### セッション一覧（現 cwd 絞込）

```sh
cc-sessions
```

fzf 起動。↑↓で選択、Enter で `claude --resume <id>` 実行。preview に JSON 全項目表示。

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
tail -5 ~/.claude/sessions/index.jsonl | jq .
```

### 記録のリセット

```sh
: > ~/.claude/sessions/index.jsonl
```

## 動作確認

hook 単体テスト:

```sh
echo '{"session_id":"test","transcript_path":"/tmp/x","cwd":"/tmp","reason":"clear","turn_count":1,"duration_ms":1000}' \
  | bash ~/.claude/hooks/session-end-save.sh
tail -1 ~/.claude/sessions/index.jsonl | jq .
```

## トラブルシューティング

| 症状 | 原因・対処 |
|---|---|
| index.jsonl に追記されない | hook 未発火。`reason` 確認。Claude Code 再起動後試す |
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
