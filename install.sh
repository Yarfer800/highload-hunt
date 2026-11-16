#!/usr/bin/env bash
# install.sh — install the highload-hunt skill (and its slash command) into AI agent harnesses.
#
# Usage:
#   ./install.sh --list                     # show detected hosts, skill and command targets
#   ./install.sh --host claude              # symlink into ~/.claude/skills + ~/.claude/commands
#   ./install.sh --all                      # every detected host
#   ./install.sh --project .                # project-local .claude and .agents dirs
#   ./install.sh --host opencode --mode copy
#   ./install.sh --host claude --uninstall
#   ./install.sh --host codex --no-commands
#
# Hosts: claude, codex, dsh, opencode, agents, gemini, antigravity, project
# Default mode is symlink, so `git pull` updates every host at once.

set -uo pipefail

SKILL_NAME="highload-hunt"
COMMAND_NAME="highload-hunt.md"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="link"
HOSTS=()
UNINSTALL=0
FORCE=0
DRY=0
WITH_COMMANDS=1
PROJECT_DIR=""

say() { printf '%s\n' "$*"; }
warn() { printf 'warn: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 2; }

host_dir() {
  case "$1" in
    claude)         printf '%s' "$HOME/.claude/skills" ;;
    codex)          printf '%s' "$HOME/.codex/skills" ;;
    dsh)            printf '%s' "$HOME/.dsh/skills" ;;
    opencode)       printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skills" ;;
    agents)         printf '%s' "$HOME/.agents/skills" ;;
    gemini)         printf '%s' "$HOME/.gemini/skills" ;;
    antigravity)    printf '%s' "$HOME/.antigravity/skills" ;;
    project)        printf '%s' "${PROJECT_DIR:-$PWD}/.agents/skills" ;;
    project-claude) printf '%s' "${PROJECT_DIR:-$PWD}/.claude/skills" ;;
    *) return 1 ;;
  esac
}

# Harnesses with a real custom-command directory. Others use the skill only.
command_dir() {
  case "$1" in
    claude)         printf '%s' "$HOME/.claude/commands" ;;
    codex)          printf '%s' "$HOME/.codex/prompts" ;;
    opencode)       printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/commands" ;;
    project-claude) printf '%s' "${PROJECT_DIR:-$PWD}/.claude/commands" ;;
    *) return 1 ;;
  esac
}

host_note() {
  case "$1" in
    claude)      printf 'Claude Code (user-level skills + commands)' ;;
    codex)       printf 'Codex (skills + prompts)' ;;
    dsh)         printf 'DeepSeek Harness native skill root (no command dir)' ;;
    opencode)    printf 'OpenCode / ECC catalog (skills + commands)' ;;
    agents)      printf 'Cross-host .agents/skills root (no command dir)' ;;
    gemini)      printf 'Gemini CLI (skills; commands are TOML, use AGENTS.md block)' ;;
    antigravity) printf 'Antigravity (skills; use AGENTS.md block)' ;;
    project)     printf 'project-local .agents/skills' ;;
    project-claude) printf 'project-local .claude/skills + commands' ;;
  esac
}

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOSTS+=("${2:-}"); shift 2 ;;
    --all) HOSTS=("claude" "codex" "dsh" "opencode" "agents" "gemini" "antigravity"); shift ;;
    --project) PROJECT_DIR="${2:-$PWD}"; HOSTS+=("project" "project-claude"); shift 2 ;;
    --mode) MODE="${2:-link}"; shift 2 ;;
    --no-commands) WITH_COMMANDS=0; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --list)
      printf '%-15s %-46s %-9s %s\n' "host" "skill target" "installed" "command target"
      for h in claude codex dsh opencode agents gemini antigravity; do
        dir="$(host_dir "$h")"
        installed="no"; [ -e "$dir/$SKILL_NAME" ] && installed="yes"
        if cdir="$(command_dir "$h")"; then cstatus="$cdir/$COMMAND_NAME"; else cstatus="—"; fi
        printf '%-15s %-46s %-9s %s\n' "$h" "$dir" "$installed" "$cstatus"
      done
      exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[ -f "$SRC_DIR/SKILL.md" ] || die "SKILL.md not found next to install.sh ($SRC_DIR)"
grep -q "^name: $SKILL_NAME$" "$SRC_DIR/SKILL.md" || warn "SKILL.md frontmatter name differs from $SKILL_NAME"
if [ "$WITH_COMMANDS" -eq 1 ] && [ ! -f "$SRC_DIR/commands/$COMMAND_NAME" ]; then
  warn "commands/$COMMAND_NAME missing; commands will be skipped"
  WITH_COMMANDS=0
fi

case "$MODE" in link|copy) ;; *) die "--mode must be link or copy" ;; esac

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

install_command() {
  local host="$1" cdir dest
  [ "$WITH_COMMANDS" -eq 1 ] || return 0
  if ! cdir="$(command_dir "$host")"; then
    say "command: not supported for $host (skill only)"
    return 0
  fi
  dest="$cdir/$COMMAND_NAME"
  local src="$SRC_DIR/commands/$COMMAND_NAME"

  if [ "$DRY" -eq 1 ]; then
    say "would install command -> $dest"
    return 0
  fi

  mkdir -p "$cdir" || { warn "cannot create $cdir"; return 1; }
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    if [ -L "$dest" ] && [ "$(readlink -f "$dest")" = "$(readlink -f "$src")" ] && [ "$MODE" = link ]; then
      say "already linked: $dest"
      return 0
    fi
    if [ "$MODE" = copy ] && cmp -s "$src" "$dest"; then
      say "already copied: $dest"
      return 0
    fi
    if [ "$FORCE" -eq 0 ]; then
      warn "$dest exists, skipping command (use --force to replace)"
      return 1
    fi
    rm -f "$dest"
  fi

  if [ "$MODE" = link ]; then
    ln -s "$src" "$dest" && say "linked command $dest"
  else
    cp "$src" "$dest" && say "copied command $dest"
  fi
}

uninstall_command() {
  local host="$1" cdir dest
  [ "$WITH_COMMANDS" -eq 1 ] || return 0
  command_dir "$host" >/dev/null || return 0
  cdir="$(command_dir "$host")"
  dest="$cdir/$COMMAND_NAME"
  if [ -L "$dest" ]; then
    rm -f "$dest"; say "unlinked $dest"
  elif [ -f "$dest" ] && grep -q "Yarfer800/highload-hunt" "$dest"; then
    rm -f "$dest"; say "removed $dest"
  elif [ -e "$dest" ]; then
    warn "refusing to remove $dest: not a highload-hunt command"
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
seen=" "
for host in "${HOSTS[@]}"; do
  dir="$(host_dir "$host")" || die "unknown host: $host"
  case "$seen" in *" $dir "*)
    continue ;;
  esac
  seen="$seen$dir "

  if [ "$UNINSTALL" -eq 1 ]; then
    uninstall_from "$dir"
    uninstall_command "$host"
  else
    install_into "$dir" || rc=1
    install_command "$host" || warn "command install failed for $host"
  fi
done

if [ "$UNINSTALL" -eq 0 ] && [ "$DRY" -eq 0 ]; then
  first_dir="$(host_dir "${HOSTS[0]}")"
  cat <<EOF

Verify:
  head -5 "$first_dir/$SKILL_NAME/SKILL.md"
  bash "$first_dir/$SKILL_NAME/scripts/perf-doctor.sh" /path/to/project

Slash commands installed:
  Claude Code          /highload-hunt
  Codex                /highload-hunt (prompt)
  OpenCode             /highload-hunt

Hosts that read AGENTS.md instead of a skills dir (Antigravity, Gemini fallback,
Codex fallback) get this block — append it to AGENTS.md manually:

  ## Highload performance hunts
  When asked to load-test, stress-test, benchmark, or explain slowness under
  traffic, read ~/.agents/skills/$SKILL_NAME/SKILL.md and follow its phases and
  hard gates. Report first; do not change production code before approval.
EOF
fi

exit "$rc"
