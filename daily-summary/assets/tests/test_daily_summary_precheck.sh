#!/usr/bin/env bash
# 职责：回归测试 daily-summary 定时包装脚本的“今日是否有会话”前置检查。
# 边界：只验证包装脚本会在 Codex-only 当天继续执行，不测试总结正文生成质量。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

make_fake_bin() {
  local bin="$1"
  mkdir -p "$bin"

  cat >"$bin/lark-cli" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then
  exit 0
fi
echo "unexpected lark-cli call: $*" >&2
exit 2
SH
  chmod +x "$bin/lark-cli"

  cat >"$bin/codex" <<'SH'
#!/usr/bin/env bash
echo "$*" >"$HOME/codex-called"
exit 0
SH
  chmod +x "$bin/codex"
}

make_home() {
  local name="$1"
  local home="$TMP_ROOT/$name/home"
  mkdir -p \
    "$home/.claude/projects" \
    "$home/.local/state/daily-summary" \
    "$home/ClaudeCode/tools/daily-summary"
  cat >"$home/ClaudeCode/tools/daily-summary/daily-summary.conf" <<'CONF'
EXECUTOR=codex
CONF
  echo "$home"
}

add_codex_session() {
  HOME="$1" python3 - <<'PY'
import json
import os
import sqlite3
from datetime import datetime

home = os.environ["HOME"]
today = datetime.now().astimezone().date().isoformat()
codex_dir = os.path.join(home, ".codex")
session_dir = os.path.join(codex_dir, "sessions", *today.split("-"))
os.makedirs(session_dir, exist_ok=True)

rollout = os.path.join(session_dir, "rollout-test.jsonl")
local_ten = datetime.fromisoformat(today + "T10:00:00").astimezone()
with open(rollout, "w", encoding="utf-8") as fp:
    fp.write(json.dumps({
        "timestamp": local_ten.isoformat(),
        "type": "event_msg",
        "payload": {"type": "user_message", "message": "Codex-only work"},
    }, ensure_ascii=False) + "\n")

db = os.path.join(codex_dir, "state_5.sqlite")
con = sqlite3.connect(db)
con.execute(
    "create table threads (rollout_path text, cwd text, git_branch text, title text, updated_at integer)"
)
con.execute(
    "insert into threads values (?, ?, ?, ?, ?)",
    (rollout, os.path.join(home, "project"), "main", "Codex-only", int(local_ten.timestamp())),
)
con.commit()
con.close()
PY
}

run_script() {
  local home="$1"
  local bin="$TMP_ROOT/bin"
  make_fake_bin "$bin"
  HOME="$home" PATH="$bin:$PATH" bash "$ROOT/daily-summary.sh"
}

codex_home="$(make_home codex-only)"
add_codex_session "$codex_home"
run_script "$codex_home"

if [ ! -s "$codex_home/codex-called" ]; then
  echo "expected Codex executor to be called for Codex-only activity" >&2
  exit 1
fi

empty_home="$(make_home empty-day)"
run_script "$empty_home"

if [ -e "$empty_home/codex-called" ]; then
  echo "expected empty day to skip Codex executor" >&2
  exit 1
fi
