#!/usr/bin/env bash
# 职责：每天 21:00 由 systemd timer 触发，无头调用 Claude Code 跑 daily-summary skill，
#       复盘当天 09:00–21:00 的 Claude Code / Codex 会话，生成 HTML 并发到本人飞书邮箱。
# 设计：daily-summary 是让 Claude 自行驱动工具（find/python/lark-cli）走完全程的 skill，
#       故无头运行需 --dangerously-skip-permissions 放开工具权限（无人值守，个人机）。
#       开始/完成/失败时弹桌面通知（notify-send），便于无人值守时感知进度。
# 关键依赖：claude、lark-cli、python3、notify-send（可选）。
#          fail-first：核心步骤失败即非零退出，不静默兜底；通知失败不影响主流程。

set -euo pipefail

STATE="$HOME/.local/state/daily-summary"
TODAY="$(date +%F)"
cd "$STATE"   # skill 默认把 HTML 落盘到 CWD，固定到 state 目录

log() { echo "[$(date '+%F %T')] $*"; }

# 桌面通知：systemd user service 里需显式给出 session bus 地址才能弹到桌面。
# 通知是辅助信号，失败（无 notify-send / 无图形会话）不应中断主流程。
notify() {  # notify <summary> <body> [urgency]
  command -v notify-send >/dev/null 2>&1 || return 0
  DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus" \
    notify-send -a "每日总结" -u "${3:-normal}" "$1" "$2" 2>/dev/null || true
}

# 任何非正常退出都弹一条失败通知
trap 'notify "每日总结失败" "运行出错，详见 $STATE/summary.log" critical' ERR

log "=== daily-summary 开始，目标日期 $TODAY ==="
notify "开始今日总结" "正在复盘 $TODAY 09:00–21:00 的工作…"

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
notify "今日总结完成" "$TODAY 复盘已生成并发送到飞书邮箱。"
