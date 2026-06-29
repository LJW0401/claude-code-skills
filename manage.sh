#!/usr/bin/env bash
#
# Claude Code / Codex Skills 管理脚本
# 在 ~/.claude/skills/ 或 ~/.codex/skills/ 中安装、卸载、更新符号链接
#

set -euo pipefail

# --- 配置 ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_NAME="$(basename "$SCRIPT_DIR")"
CLAUDE_SKILLS_DIR="${CLAUDE_HOME:-$HOME/.claude}/skills"
CODEX_SKILLS_DIR="${CODEX_HOME:-$HOME/.codex}/skills"
SKILLS_DIR=""
TARGET_NAME=""

# 递归扫描所有包含 SKILL.md 的目录
# SKILLS[i] 为 skill 名称（SKILL.md 所在目录的 basename）
# SKILL_PATHS[i] 为相对于仓库根目录的路径（用作 symlink target 的相对部分）
SKILLS=()
SKILL_PATHS=()
declare -A SEEN_NAMES=()

while IFS= read -r -d '' skill_md; do
  skill_dir="$(dirname "$skill_md")"
  rel_path="${skill_dir#$SCRIPT_DIR/}"
  skill_name="$(basename "$skill_dir")"

  if [[ -n "${SEEN_NAMES[$skill_name]:-}" ]]; then
    echo "[ERROR] skill 名称冲突：${rel_path} 与 ${SEEN_NAMES[$skill_name]} 同名（${skill_name}），请重命名其中一个" >&2
    exit 1
  fi
  SEEN_NAMES[$skill_name]="$rel_path"

  SKILLS+=("$skill_name")
  SKILL_PATHS+=("$rel_path")
done < <(find "$SCRIPT_DIR" -type f -name SKILL.md -not -path '*/node_modules/*' -not -path '*/.git/*' -print0 | sort -z)

if [[ ${#SKILLS[@]} -eq 0 ]]; then
  echo "未找到任何 skill 目录（需包含 SKILL.md）"
  exit 1
fi

# 根据 skill 名称获取相对路径
skill_path_for() {
  local name="$1" i
  for i in "${!SKILLS[@]}"; do
    if [[ "${SKILLS[$i]}" == "$name" ]]; then
      echo "${SKILL_PATHS[$i]}"
      return 0
    fi
  done
  return 1
}

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

FORCE=0
TARGET=""

set_target() {
  local target="$1"
  case "$target" in
    claude|claude-code)
      TARGET="claude"
      TARGET_NAME="Claude Code"
      SKILLS_DIR="$CLAUDE_SKILLS_DIR"
      ;;
    codex)
      TARGET="codex"
      TARGET_NAME="Codex"
      SKILLS_DIR="$CODEX_SKILLS_DIR"
      ;;
    *)
      error "未知安装目标：${target}（可选：claude, codex）"
      usage
      exit 1
      ;;
  esac
}

require_target() {
  if [[ -z "$TARGET" ]]; then
    error "缺少安装目标，请指定 claude 或 codex"
    usage
    exit 1
  fi
}

ensure_skills_dir() {
  if [[ -d "$SKILLS_DIR" ]]; then
    return 0
  fi

  warn "${TARGET_NAME} skills 目录不存在，将创建：${SKILLS_DIR}/"
  mkdir -p "$SKILLS_DIR"
  ok "已创建 ${SKILLS_DIR}/"
}

target_for() {
  local rel="$1"
  echo "${SCRIPT_DIR}/${rel}"
}

old_relative_target_for() {
  local rel="$1"
  echo "${REPO_NAME}/${rel}"
}

# --- 安装 ---
do_install() {
  ensure_skills_dir
  info "安装 skill 链接到 ${TARGET_NAME}：${SKILLS_DIR}/"
  local installed=0 skipped=0

  for skill in "${SKILLS[@]}"; do
    local rel target link
    rel="$(skill_path_for "$skill")"
    target="$(target_for "$rel")"
    link="${SKILLS_DIR}/${skill}"

    if [[ -L "$link" ]]; then
      local current
      current="$(readlink "$link")"
      if [[ "$current" == "$target" ]]; then
        warn "${skill} 已安装，跳过"
        ((skipped++)) || true
        continue
      elif (( FORCE )); then
        rm "$link"
        warn "${skill} 原指向 ${current}，已被 force 覆盖"
      else
        error "${skill} 已存在但指向 ${current}，请先卸载或使用 --force 强制覆盖"
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
  info "卸载 ${TARGET_NAME} skill 链接：${SKILLS_DIR}/"
  local removed=0 skipped=0

  for skill in "${SKILLS[@]}"; do
    local rel target old_target old_flat_target link
    rel="$(skill_path_for "$skill")"
    target="$(target_for "$rel")"
    old_target="$(old_relative_target_for "$rel")"
    old_flat_target="${REPO_NAME}/${skill}"
    link="${SKILLS_DIR}/${skill}"

    if [[ -L "$link" ]]; then
      local current
      current="$(readlink "$link")"
      if [[ "$current" == "$target" || "$current" == "$old_target" || "$current" == "$old_flat_target" ]]; then
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
  ensure_skills_dir
  info "更新 ${TARGET_NAME} skill 链接：${SKILLS_DIR}/"
  local updated=0

  for skill in "${SKILLS[@]}"; do
    local rel target old_target old_flat_target link
    rel="$(skill_path_for "$skill")"
    target="$(target_for "$rel")"
    old_target="$(old_relative_target_for "$rel")"
    old_flat_target="${REPO_NAME}/${skill}"
    link="${SKILLS_DIR}/${skill}"

    # 删除旧链接（仅删除属于本项目的，除非 -f 强制）
    if [[ -L "$link" ]]; then
      local current
      current="$(readlink "$link")"
      # 兼容历史一级路径与新的多级路径
      if [[ "$current" != "$target" && "$current" != "$old_target" && "$current" != "$old_flat_target" ]]; then
        if (( FORCE )); then
          warn "${skill} 原指向 ${current}，已被 force 覆盖"
        else
          error "${skill} 链接指向 ${current}，不属于本项目，跳过（可加 -f 强制覆盖）"
          continue
        fi
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
  info "${TARGET_NAME} Skill 链接状态：${SKILLS_DIR}/"
  echo ""

  for skill in "${SKILLS[@]}"; do
    local rel target old_target old_flat_target link
    rel="$(skill_path_for "$skill")"
    target="$(target_for "$rel")"
    old_target="$(old_relative_target_for "$rel")"
    old_flat_target="${REPO_NAME}/${skill}"
    link="${SKILLS_DIR}/${skill}"

    if [[ -L "$link" ]]; then
      local current
      current="$(readlink "$link")"
      if [[ "$current" == "$target" ]]; then
        ok "${skill} -> ${current}"
      elif [[ "$current" == "$old_target" || "$current" == "$old_flat_target" ]]; then
        warn "${skill} -> ${current} (本项目旧格式，可执行 update)"
      else
        warn "${skill} -> ${current} (非本项目或路径过期，可执行 update)"
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
Claude Code / Codex Skills 管理脚本

用法: $(basename "$0") <命令> <claude|codex> [选项]
      $(basename "$0") <命令> --target <claude|codex> [选项]

命令:
  install     安装 skill（创建符号链接）
  uninstall   卸载 skill（删除符号链接）
  update      更新 skill（重建符号链接）
  status      查看当前安装状态

目标:
  claude      安装到 ${CLAUDE_SKILLS_DIR}/
  codex       安装到 ${CODEX_SKILLS_DIR}/

选项:
  -t, --target <target>  指定安装目标：claude 或 codex
  -f, force, --force  对 install / update：覆盖指向其它项目的同名 symlink

示例:
  $(basename "$0") install claude
  $(basename "$0") install codex
  $(basename "$0") update --target codex --force

Skill 列表:
$(printf '  - %s\n' "${SKILLS[@]}")
HELP
}

# --- 入口 ---
CMD="${1:-}"
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|force|--force) FORCE=1 ;;
    -t|--target)
      shift
      if [[ $# -eq 0 ]]; then
        error "--target 需要参数：claude 或 codex"
        usage
        exit 1
      fi
      set_target "$1"
      ;;
    claude|claude-code|codex)
      set_target "$1"
      ;;
    *) error "未知参数：$1"; usage; exit 1 ;;
  esac
  shift
done

case "$CMD" in
  install)   require_target; do_install   ;;
  uninstall) require_target; do_uninstall ;;
  update)    require_target; do_update    ;;
  status)    require_target; do_status    ;;
  *)         usage        ;;
esac
