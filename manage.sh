#!/usr/bin/env bash
#
# Claude Code Skills 管理脚本
# 在 ~/.claude/skills/ 中安装、卸载、更新符号链接
#

set -euo pipefail

# --- 配置 ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_NAME="$(basename "$SCRIPT_DIR")"
SKILLS_DIR="$(dirname "$SCRIPT_DIR")"

# 自动扫描包含 SKILL.md 的子目录
SKILLS=()
for dir in "$SCRIPT_DIR"/*/; do
  [[ -f "${dir}SKILL.md" ]] && SKILLS+=("$(basename "$dir")")
done

if [[ ${#SKILLS[@]} -eq 0 ]]; then
  echo "未找到任何 skill 目录（需包含 SKILL.md）"
  exit 1
fi

# --- 颜色 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# --- 安装 ---
do_install() {
  info "安装 skill 链接到 ${SKILLS_DIR}/"
  local installed=0 skipped=0

  for skill in "${SKILLS[@]}"; do
    local target="${REPO_NAME}/${skill}"
    local link="${SKILLS_DIR}/${skill}"

    if [[ -L "$link" ]]; then
      local current
      current="$(readlink "$link")"
      if [[ "$current" == "$target" ]]; then
        warn "${skill} 已安装，跳过"
        ((skipped++)) || true
        continue
      else
        error "${skill} 已存在但指向 ${current}，请先卸载或手动处理"
        ((skipped++)) || true
        continue
      fi
    elif [[ -e "$link" ]]; then
      error "${skill} 已存在且不是符号链接，跳过"
      ((skipped++)) || true
      continue
    fi

    ln -s "$target" "$link"
    ok "${skill} -> ${target}"
    ((installed++)) || true
  done

  echo ""
  info "安装完成：${installed} 个已安装，${skipped} 个跳过"
}

# --- 卸载 ---
do_uninstall() {
  info "卸载 skill 链接"
  local removed=0 skipped=0

  for skill in "${SKILLS[@]}"; do
    local link="${SKILLS_DIR}/${skill}"

    if [[ -L "$link" ]]; then
      local current
      current="$(readlink "$link")"
      if [[ "$current" == "${REPO_NAME}/${skill}" ]]; then
        rm "$link"
        ok "${skill} 已卸载"
        ((removed++)) || true
      else
        warn "${skill} 链接指向 ${current}，不属于本项目，跳过"
        ((skipped++)) || true
      fi
    elif [[ -e "$link" ]]; then
      warn "${skill} 不是符号链接，跳过"
      ((skipped++)) || true
    else
      warn "${skill} 不存在，跳过"
      ((skipped++)) || true
    fi
  done

  echo ""
  info "卸载完成：${removed} 个已卸载，${skipped} 个跳过"
}

# --- 更新 ---
do_update() {
  info "更新 skill 链接"
  local updated=0

  for skill in "${SKILLS[@]}"; do
    local target="${REPO_NAME}/${skill}"
    local link="${SKILLS_DIR}/${skill}"

    # 删除旧链接（仅删除属于本项目的）
    if [[ -L "$link" ]]; then
      local current
      current="$(readlink "$link")"
      if [[ "$current" != "${REPO_NAME}/${skill}" ]]; then
        error "${skill} 链接指向 ${current}，不属于本项目，跳过"
        continue
      fi
      rm "$link"
    elif [[ -e "$link" ]]; then
      error "${skill} 不是符号链接，跳过"
      continue
    fi

    ln -s "$target" "$link"
    ok "${skill} -> ${target}"
    ((updated++)) || true
  done

  echo ""
  info "更新完成：${updated} 个已更新"
}

# --- 状态 ---
do_status() {
  info "Skill 链接状态："
  echo ""

  for skill in "${SKILLS[@]}"; do
    local link="${SKILLS_DIR}/${skill}"
    local target="${REPO_NAME}/${skill}"

    if [[ -L "$link" ]]; then
      local current
      current="$(readlink "$link")"
      if [[ "$current" == "$target" ]]; then
        ok "${skill} -> ${current}"
      else
        warn "${skill} -> ${current} (非本项目)"
      fi
    elif [[ -e "$link" ]]; then
      warn "${skill} 存在但非符号链接"
    else
      echo -e "  ${RED}✗${NC}  ${skill} 未安装"
    fi
  done
}

# --- 帮助 ---
usage() {
  cat <<HELP
${CYAN}Claude Code Skills 管理脚本${NC}

用法: $(basename "$0") <命令>

命令:
  install     安装 skill（创建符号链接到 ~/.claude/skills/）
  uninstall   卸载 skill（删除符号链接）
  update      更新 skill（重建符号链接）
  status      查看当前安装状态

Skill 列表:
$(printf '  - %s\n' "${SKILLS[@]}")
HELP
}

# --- 入口 ---
case "${1:-}" in
  install)   do_install   ;;
  uninstall) do_uninstall ;;
  update)    do_update    ;;
  status)    do_status    ;;
  *)         usage        ;;
esac
