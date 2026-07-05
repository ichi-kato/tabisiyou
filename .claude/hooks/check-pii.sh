#!/usr/bin/env bash
# PreToolUse フック: 個人情報が GitHub に上がる操作をブロックする
# 検知したら exit 2（ツール実行拒否）で理由を stderr に返す
set -u

INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')

# 許可するメールアドレス（GitHub の匿名アドレスと bot のみ）
ALLOW_RE='([0-9]+\+)?[A-Za-z0-9._-]+@users\.noreply\.github\.com|noreply@github\.com|noreply@anthropic\.com'
EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
PHONE_RE='0[5789]0-?[0-9]{4}-?[0-9]{4}|\+81[- ]?[0-9]{1,4}[- ]?[0-9]{2,4}[- ]?[0-9]{3,4}'

# stdin のテキストを検査し、問題があれば内容を出力して 1 を返す
scan() {
  local text found
  text=$(cat)
  found=$(printf '%s' "$text" | grep -oE "$EMAIL_RE" | grep -vE "^($ALLOW_RE)$" | sort -u | head -3)
  if [ -n "$found" ]; then printf '許可されていないメールアドレス: %s' "$found"; return 1; fi
  found=$(printf '%s' "$text" | grep -oE "$PHONE_RE" | sort -u | head -3)
  if [ -n "$found" ]; then printf '電話番号らしき文字列: %s' "$found"; return 1; fi
  return 0
}

block() {
  {
    echo "【個人情報ブロック】$1"
    echo "CLAUDE.md の絶対ルールにより、この操作を中止しました。個人情報を取り除いてから再実行してください。"
  } >&2
  exit 2
}

case "$TOOL" in
  Bash)
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
    case "$CMD" in
      *"git commit"*|*"git push"*) : ;;
      *) exit 0 ;;
    esac
    res=$(printf '%s' "$CMD" | scan) || block "コマンド文字列に検出 — $res"
    if [[ "$CMD" == *"git commit"* ]]; then
      res=$(git diff --cached | scan) || block "コミット予定の変更に検出 — $res"
      email=$(git config user.email 2>/dev/null || true)
      printf '%s' "$email" | grep -qE "^($ALLOW_RE)$" \
        || block "git user.email が匿名アドレスではありません: ${email:-（未設定）}"
    fi
    if [[ "$CMD" == *"git push"* ]]; then
      # どのリモートにもまだ存在しないコミット（= 送信され得る内容）を検査
      res=$(git log --branches --not --remotes --patch 2>/dev/null | scan) \
        || block "push 予定のコミット内容に検出 — $res"
      res=$(git log --branches --format='%ae%n%ce' 2>/dev/null | sort -u | scan) \
        || block "コミットの author/committer に検出 — $res"
    fi
    ;;
  mcp__github__*)
    # GitHub への書き込み系 MCP ツール: 入力 JSON 全体を検査
    res=$(printf '%s' "$INPUT" | jq -r '.tool_input // {} | tostring' | scan) \
      || block "GitHub ツールの入力に検出 — $res"
    ;;
esac

exit 0
