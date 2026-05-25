#!/usr/bin/env bash
# 职责：每天 21:00 由 systemd timer 触发，无头调用 Claude Code 跑 daily-summary skill，
#       复盘当天 09:00–21:00 的 Claude Code / Codex 会话，生成 HTML 并发到本人飞书邮箱。
# 设计：daily-summary 是让 Claude 自行驱动工具（find/python/lark-cli）走完全程的 skill，
#       故无头运行需 --dangerously-skip-permissions 放开工具权限（无人值守，个人机）。
# 关键依赖：claude、lark-cli、python3。fail-first：任一步失败即非零退出，不静默兜底。

set -euo pipefail

STATE="$HOME/.local/state/daily-summary"
TODAY="$(date +%F)"
cd "$STATE"   # skill 默认把 HTML 落盘到 CWD，固定到 state 目录

log() { echo "[$(date '+%F %T')] $*"; }

log "=== daily-summary 开始，目标日期 $TODAY ==="

# 发邮件前确认 token 有效，过期直接失败（避免静默不发）
if ! lark-cli doctor --offline >/dev/null 2>&1; then
  log "lark-cli 本地状态异常，终止。"; exit 1
fi

claude --print --dangerously-skip-permissions <<EOF
使用 daily-summary skill 复盘今天（$TODAY）09:00–21:00 的工作：
扫描本机 Claude Code / Codex 会话，按 skill 流程生成 HTML 文档并通过 lark-cli
发送到我的飞书邮箱（收件人地址用 lark-cli 现场获取，不要硬编码）。
直接发送，无需向我确认。完成后只回报 HTML 路径和邮件 message_id。
EOF

log "=== daily-summary 完成 ==="
