#!/usr/bin/env bash
# 职责：daily-summary 定时服务的安装/管理脚本。把同目录下的包装脚本与 systemd
#       user unit 部署到位，并提供启用、查看、手动触发、卸载等子命令。
# 用法：./manage.sh {install|status|run|restart|logs|uninstall}
# 关键依赖：systemd（user 实例）、loginctl、lark-cli（install 时校验登录态）。
#          fail-first：任一步失败即非零退出，不静默兜底。

set -euo pipefail

# 资源目录（本脚本所在处，含 daily-summary.sh / .service / .timer / .conf）
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BIN_DIR="$HOME/ClaudeCode/tools/daily-summary"
UNIT_DIR="$HOME/.config/systemd/user"
STATE_DIR="$HOME/.local/state/daily-summary"
LOG="$STATE_DIR/summary.log"
UNIT="daily-summary.timer"
CONFIG="$BIN_DIR/daily-summary.conf"

usage() { echo "用法：$0 {install|status|run|restart|logs|uninstall}"; exit 1; }

cmd_install() {
  echo "[install] 校验 lark-cli 登录态..."
  lark-cli doctor --offline >/dev/null 2>&1 || {
    echo "lark-cli 本地状态异常，请先 lark-cli auth login。"; exit 1; }

  echo "[install] 部署脚本与 unit..."
  mkdir -p "$BIN_DIR" "$STATE_DIR" "$UNIT_DIR"
  install -m 755 "$SRC/daily-summary.sh"      "$BIN_DIR/daily-summary.sh"
  install -m 644 "$SRC/daily-summary.service" "$UNIT_DIR/daily-summary.service"
  install -m 644 "$SRC/daily-summary.timer"   "$UNIT_DIR/daily-summary.timer"
  if [ ! -f "$CONFIG" ]; then
    install -m 644 "$SRC/daily-summary.conf" "$CONFIG"
  else
    echo "[install] 保留已有配置：$CONFIG"
  fi

  echo "[install] 开启 linger（注销后仍常驻）..."
  loginctl enable-linger "$USER"

  echo "[install] 启用并启动定时器..."
  systemctl --user daemon-reload
  systemctl --user enable --now "$UNIT"

  echo "[install] 完成。下次触发："
  systemctl --user list-timers "$UNIT" --no-pager
}

cmd_status() {
  systemctl --user list-timers "$UNIT" --all --no-pager || true
  echo "---"
  systemctl --user status daily-summary.service --no-pager || true
  echo "--- config: $CONFIG"
  if [ -f "$CONFIG" ]; then
    sed -n '1,80p' "$CONFIG"
  else
    echo "配置文件不存在，将在 install/restart 时创建默认配置。"
  fi
}

cmd_run() {
  echo "[run] 立即手动触发一次（会真发邮件）..."
  systemctl --user start daily-summary.service
  echo "[run] 已触发，日志见：$LOG"
}

cmd_restart() {
  echo "[restart] 重新部署脚本、unit 与配置，并重启定时器（用于改动后生效）..."
  install -m 755 "$SRC/daily-summary.sh"      "$BIN_DIR/daily-summary.sh"
  install -m 644 "$SRC/daily-summary.service" "$UNIT_DIR/daily-summary.service"
  install -m 644 "$SRC/daily-summary.timer"   "$UNIT_DIR/daily-summary.timer"
  install -m 644 "$SRC/daily-summary.conf" "$CONFIG"
  echo "[restart] 已更新配置：$CONFIG"
  systemctl --user daemon-reload
  systemctl --user restart "$UNIT"
  echo "[restart] 完成。下次触发："
  systemctl --user list-timers "$UNIT" --no-pager
}

cmd_logs() {
  [ -f "$LOG" ] || { echo "暂无日志：$LOG"; exit 0; }
  tail -n 40 -f "$LOG"
}

cmd_uninstall() {
  echo "[uninstall] 停用定时器并移除 unit..."
  systemctl --user disable --now "$UNIT" 2>/dev/null || true
  rm -f "$UNIT_DIR/daily-summary.timer" "$UNIT_DIR/daily-summary.service"
  rm -f "$BIN_DIR/daily-summary.sh"
  systemctl --user daemon-reload
  echo "[uninstall] 完成（配置、日志与历史 HTML 保留在 $BIN_DIR 和 $STATE_DIR）。"
}

case "${1:-}" in
  install)   cmd_install ;;
  status)    cmd_status ;;
  run)       cmd_run ;;
  restart)   cmd_restart ;;
  logs)      cmd_logs ;;
  uninstall) cmd_uninstall ;;
  *)         usage ;;
esac
