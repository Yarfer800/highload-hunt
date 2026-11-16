#!/usr/bin/env bash
# install.sh — install the highload-hunt skill into AI agent harnesses.
#
# Usage:
#   ./install.sh --list                     # show detected hosts and target paths
#   ./install.sh --host claude              # symlink into ~/.claude/skills
#   ./install.sh --all                      # every detected host
#   ./install.sh --project .                # project-local .claude/skills + .agents/skills
#   ./install.sh --host opencode --mode copy
#   ./install.sh --host claude --uninstall
#
# Hosts: claude, codex, dsh, opencode, agents, gemini, antigravity, project
# Default mode is symlink, so `git pull` updates every host at once.

set -uo pipefail

SKILL_NAME="highload-hunt"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="link"
HOSTS=()
UNINSTALL=0
FORCE=0
DRY=0
PROJECT_DIR=""

say() { printf '%s\n' "$*"; }
warn() { printf 'warn: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 2; }

host_dir() {
  case "$1" in
    claude)      printf '%s' "$HOME/.claude/skills" ;;
    codex)       printf '%s' "$HOME/.codex/skills" ;;
    dsh)         printf '%s' "$HOME/.dsh/skills" ;;
    opencode)    printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skills" ;;
    agents)      printf '%s' "$HOME/.agents/skills" ;;
    gemini)      printf '%s' "$HOME/.gemini/skills" ;;
    antigravity) printf '%s' "$HOME/.antigravity/skills" ;;
    project)     printf '%s' "${PROJECT_DIR:-$PWD}/.agents/skills" ;;
    project-claude) printf '%s' "${PROJECT_DIR:-$PWD}/.claude/skills" ;;
    *) return 1 ;;
  esac
}

host_note() {
  case "$1" in
    claude)      printf 'Claude Code (user-level skills)' ;;
    codex)       printf 'Codex (skills dir, AGENTS.md fallback below)' ;;
    dsh)         printf 'DeepSeek Harness native skill root' ;;
    opencode)    printf 'OpenCode / ECC catalog' ;;
    agents)      printf 'Cross-host .agents/skills root' ;;
    gemini)      printf 'Gemini CLI' ;;
    antigravity) printf 'Antigravity' ;;
    project)     printf 'project-local skills (.agents/skills)' ;;
    project-claude) printf 'project-local skills (.claude/skills)' ;;
  esac
}

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOSTS+=("${2:-}"); shift 2 ;;
    --all) HOSTS=("claude" "codex" "dsh" "opencode" "agents" "gemini" "antigravity"); shift ;;
    --project) PROJECT_DIR="${2:-$PWD}"; HOSTS+=("project" "project-claude"); shift 2 ;;
    --mode) MODE="${2:-link}"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --list)
      say "host        target                                      status"
      for h in claude codex dsh opencode agents gemini antigravity; do
        dir="$(host_dir "$h")"
        parent_ok="missing"; [ -d "$(dirname "$dir")" ] && parent_ok="parent exists"
        installed="no"; [ -e "$dir/$SKILL_NAME" ] && installed="yes"
        printf '%-11s %-43s %s, installed=%s\n' "$h" "$dir" "$parent_ok" "$installed"
      done
      exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[ -f "$SRC_DIR/SKILL.md" ] || die "SKILL.md not found next to install.sh ($SRC_DIR)"
grep -q "^name: $SKILL_NAME$" "$SRC_DIR/SKILL.md" || warn "SKILL.md frontmatter name differs from $SKILL_NAME"

case "$MODE" in link|copy) ;; *) die "--mode must be link or copy" ;; esac

target_dirs() {
  local host dir seen=" "
  for host in "${HOSTS[@]}"; do
    dir="$(host_dir "$host")" || die "unknown host: $host"
    case "$seen" in *" $dir "*) continue ;; esac
    seen="$seen$dir "
    printf '%s\n' "$dir"
  done
}

uninstall_from() {
  local dir="$1" dest="$1/$SKILL_NAME"
  if [ -L "$dest" ]; then
    rm -f "$dest"; say "unlinked $dest"
  elif [ -f "$dest/SKILL.md" ] && grep -q "^name: $SKILL_NAME$" "$dest/SKILL.md"; then
    rm -rf "$dest"; say "removed $dest"
  elif [ -e "$dest" ]; then
    warn "refusing to remove $dest: not a $SKILL_NAME symlink or skill copy"
  else
    say "not installed: $dest"
  fi
}

install_into() {
  local dir="$1" dest="$1/$SKILL_NAME"

  if [ "$DRY" -eq 1 ]; then
    say "would $([ "$MODE" = link ] && echo symlink || echo copy) $SRC_DIR -> $dest"
    return 0
  fi

  mkdir -p "$dir" || { warn "cannot create $dir"; return 1; }

  if [ -e "$dest" ] || [ -L "$dest" ]; then
    if [ -L "$dest" ] && [ "$(readlink -f "$dest")" = "$(readlink -f "$SRC_DIR")" ] && [ "$MODE" = link ]; then
      say "already linked: $dest"
      return 0
    fi
    if [ "$FORCE" -eq 0 ]; then
      warn "$dest exists, skipping (use --force to replace)"
      return 1
    fi
    rm -rf "$dest"
  fi

  if [ "$MODE" = link ]; then
    ln -s "$SRC_DIR" "$dest" || { warn "symlink failed: $dest"; return 1; }
    say "linked $dest -> $SRC_DIR"
  else
    mkdir -p "$dest" || return 1
    cp -R "$SRC_DIR/SKILL.md" "$SRC_DIR/references" "$SRC_DIR/templates" "$SRC_DIR/scripts" "$dest/" || return 1
    say "copied skill to $dest"
  fi
}

if [ "${#HOSTS[@]}" -eq 0 ]; then
  usage
  say ""
  say "no host selected. Detected:"
  for h in claude codex dsh opencode agents gemini antigravity; do
    [ -d "$(dirname "$(host_dir "$h")")" ] && say "  $h -> $(host_dir "$h")"
  done
  say ""
  say "try: ./install.sh --host claude"
  exit 0
fi

rc=0
while IFS= read -r dir; do
  [ -n "$dir" ] || continue
  hostname_guess="$dir"
  if [ "$UNINSTALL" -eq 1 ]; then
    uninstall_from "$dir"
  else
    install_into "$dir" || rc=1
  fi
done < <(target_dirs)

if [ "$UNINSTALL" -eq 0 ] && [ "$DRY" -eq 0 ]; then
  cat <<EOF

Verify:
  head -5 "$(host_dir "${HOSTS[0]}")/$SKILL_NAME/SKILL.md"
  bash "$(host_dir "${HOSTS[0]}")/$SKILL_NAME/scripts/perf-doctor.sh" /path/to/project

Hosts that read AGENTS.md instead of a skills dir (Antigravity, Gemini fallback,
Codex fallback) get this block — append it to AGENTS.md manually:

  ## Highload performance hunts
  When asked to load-test, stress-test, benchmark, or explain slowness under
  traffic, read ~/.agents/skills/$SKILL_NAME/SKILL.md and follow its phases and
  hard gates. Report first; do not change production code before approval.
EOF
fi

exit "$rc"
