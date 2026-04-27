#!/usr/bin/env bash
#
# Link Claude Code skills into Codex so Codex can discover and use them.
#

set -euo pipefail

CLAUDE_SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
CODEX_SKILLS_DIR="${CODEX_SKILLS_DIR:-$HOME/.codex/skills}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

load_skills() {
  SKILLS=()

  if [[ ! -d "$CLAUDE_SKILLS_DIR" ]]; then
    error "Claude skills directory not found: ${CLAUDE_SKILLS_DIR}"
    exit 1
  fi

  local dir
  for dir in "$CLAUDE_SKILLS_DIR"/*/; do
    [[ -f "${dir}SKILL.md" ]] && SKILLS+=("$(basename "$dir")")
  done

  if [[ ${#SKILLS[@]} -eq 0 ]]; then
    error "No Claude Code skills found in ${CLAUDE_SKILLS_DIR}"
    exit 1
  fi
}

is_managed_link() {
  local link="$1"
  local skill="$2"
  local current

  [[ -L "$link" ]] || return 1
  current="$(readlink "$link")"
  [[ "$current" == "${CLAUDE_SKILLS_DIR}/${skill}" || "$current" == "${CLAUDE_SKILLS_DIR}/${skill}/" ]]
}

do_install() {
  load_skills
  mkdir -p "$CODEX_SKILLS_DIR"

  info "Link Claude Code skills into ${CODEX_SKILLS_DIR}/"
  local installed=0 skipped=0
  local skill source link current

  for skill in "${SKILLS[@]}"; do
    source="${CLAUDE_SKILLS_DIR}/${skill}"
    link="${CODEX_SKILLS_DIR}/${skill}"

    if [[ -L "$link" ]]; then
      current="$(readlink "$link")"
      if is_managed_link "$link" "$skill"; then
        warn "${skill} already linked, skip"
      else
        error "${skill} already links to ${current}, skip"
      fi
      ((skipped++)) || true
      continue
    fi

    if [[ -e "$link" ]]; then
      error "${skill} exists in Codex skills and is not a symlink, skip"
      ((skipped++)) || true
      continue
    fi

    ln -s "$source" "$link"
    ok "${skill} -> ${source}"
    ((installed++)) || true
  done

  echo ""
  info "Done: ${installed} linked, ${skipped} skipped"
}

do_update() {
  load_skills
  mkdir -p "$CODEX_SKILLS_DIR"

  info "Refresh Claude Code skill links in ${CODEX_SKILLS_DIR}/"
  local updated=0 skipped=0
  local skill source link current

  for skill in "${SKILLS[@]}"; do
    source="${CLAUDE_SKILLS_DIR}/${skill}"
    link="${CODEX_SKILLS_DIR}/${skill}"

    if [[ -L "$link" ]]; then
      current="$(readlink "$link")"
      if ! is_managed_link "$link" "$skill"; then
        error "${skill} already links to ${current}, skip"
        ((skipped++)) || true
        continue
      fi
      rm "$link"
    elif [[ -e "$link" ]]; then
      error "${skill} exists in Codex skills and is not a symlink, skip"
      ((skipped++)) || true
      continue
    fi

    ln -s "$source" "$link"
    ok "${skill} -> ${source}"
    ((updated++)) || true
  done

  echo ""
  info "Done: ${updated} refreshed, ${skipped} skipped"
}

do_uninstall() {
  load_skills

  info "Remove Claude Code skill links from ${CODEX_SKILLS_DIR}/"
  local removed=0 skipped=0
  local skill link current

  for skill in "${SKILLS[@]}"; do
    link="${CODEX_SKILLS_DIR}/${skill}"

    if [[ -L "$link" ]]; then
      current="$(readlink "$link")"
      if is_managed_link "$link" "$skill"; then
        rm "$link"
        ok "${skill} removed"
        ((removed++)) || true
      else
        warn "${skill} links to ${current}, not managed by this script"
        ((skipped++)) || true
      fi
    elif [[ -e "$link" ]]; then
      warn "${skill} exists in Codex skills and is not a symlink"
      ((skipped++)) || true
    else
      warn "${skill} not linked"
      ((skipped++)) || true
    fi
  done

  echo ""
  info "Done: ${removed} removed, ${skipped} skipped"
}

do_status() {
  load_skills

  info "Claude Code -> Codex skill link status"
  echo ""
  local skill source link current

  for skill in "${SKILLS[@]}"; do
    source="${CLAUDE_SKILLS_DIR}/${skill}"
    link="${CODEX_SKILLS_DIR}/${skill}"

    if [[ -L "$link" ]]; then
      current="$(readlink "$link")"
      if is_managed_link "$link" "$skill"; then
        ok "${skill} -> ${current}"
      else
        warn "${skill} -> ${current} (different target)"
      fi
    elif [[ -e "$link" ]]; then
      warn "${skill} exists in Codex skills and is not a symlink"
    else
      echo -e "  ${RED}x${NC}  ${skill} not linked -> ${source}"
    fi
  done
}

usage() {
  cat <<HELP
${CYAN}Claude Code -> Codex skill linker${NC}

Usage: $(basename "$0") <command>

Commands:
  install     Create missing symlinks in ~/.codex/skills/
  update      Recreate symlinks managed by this script
  uninstall   Remove symlinks managed by this script
  status      Show link status

Environment:
  CLAUDE_SKILLS_DIR  Source directory, default: ~/.claude/skills
  CODEX_SKILLS_DIR   Target directory, default: ~/.codex/skills
HELP
}

case "${1:-}" in
  install)   do_install   ;;
  update)    do_update    ;;
  uninstall) do_uninstall ;;
  status)    do_status    ;;
  *)         usage        ;;
esac
