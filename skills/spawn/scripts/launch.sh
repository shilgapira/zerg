#!/bin/bash
# Usage: launch.sh --name NAME --prompt-file FILE [--report-to SESSION] [--dir DIR] [--permission-mode MODE]
#                  [--autocompact auto|TOKENS] [--dry-run]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

die() { echo "spawn: $*" >&2; exit 1; }

# shellcheck source=/dev/null
. "$here/lib/worker.sh"

if [ "${CLAUDE_CODE_ENTRYPOINT:-}" = claude-desktop ]; then
  reference="$(cd "$here/.." && pwd)/references/claude-desktop.md"
  # Git Bash: the Read tool takes the C:\ form
  if command -v cygpath >/dev/null 2>&1; then reference="$(cygpath -w "$reference")"; fi
  die "this is Claude Desktop; launch.sh cannot open a tab here. Do not retry or work around it." \
    "Read $reference and follow it from now on, instead of references/terminal.md."
fi

windows=0
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*)
    [ -n "${WT_SESSION:-}" ] ||
      die "on Windows only Windows Terminal is supported; tell the user, and do not retry or work around it"
    windows=1 ;;
esac

# LC_ALL=C: in a UTF-8 locale sed fails on invalid UTF-8, and inside $(...) that would leave an empty value.
shquote() { printf "'%s'" "$(printf '%s' "$1" | LC_ALL=C sed "s/'/'\\\\''/g")"; }

name="" prompt_file="" report_to="" dir="$PWD" mode=auto autocompact=auto dry_run=0
while [ $# -gt 0 ]; do
  case "$1" in
    --name | --prompt-file | --report-to | --dir | --permission-mode | --autocompact)
      [ $# -ge 2 ] || die "$1 needs a value" ;;
  esac
  case "$1" in
    --name) name="${2:-}"; shift 2 ;;
    --prompt-file) prompt_file="${2:-}"; shift 2 ;;
    --report-to) report_to="${2:-}"; shift 2 ;;
    --dir) dir="${2:-}"; shift 2 ;;
    --permission-mode) mode="${2:-}"; shift 2 ;;
    --autocompact) autocompact="${2:-}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$name" ] || die "--name is required"
[[ "$name" != *[[:cntrl:]]* ]] || die "--name must not contain control characters"
# The modes claude --help lists.
case "$mode" in
  acceptEdits | auto | bypassPermissions | manual | dontAsk | plan) ;;
  *) die "invalid --permission-mode: $mode (acceptEdits, auto, bypassPermissions, manual, dontAsk, plan)" ;;
esac
[ -n "$prompt_file" ] || die "--prompt-file is required"
[ -f "$prompt_file" ] || die "prompt file not found: $prompt_file"
[ -s "$prompt_file" ] || die "prompt file is empty: $prompt_file"
[ -d "$dir" ] || die "directory not found: $dir"
dir="$(cd "$dir" && pwd)"

ac_value="$(normalize_autocompact "$autocompact")" || die "invalid --autocompact: $autocompact (auto, or 100k to 1M)"

caller_tty=""
pid=$$
while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
  t="$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  if [ -n "$t" ] && [ "$t" != "??" ]; then caller_tty="/dev/$t"; break; fi
  pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
done

if [ "$windows" = 1 ]; then
  terminal=windows_terminal
elif [ -n "${TMUX:-}" ]; then
  terminal=tmux
else
  case "${TERM_PROGRAM:-}" in
    Apple_Terminal) terminal=apple_terminal ;;
    iTerm.app) terminal=iterm ;;
    ghostty) terminal=ghostty ;;
    *) die "unsupported terminal (TERM_PROGRAM='${TERM_PROGRAM:-}', not in tmux);" \
         "add scripts/terminals/<name>.sh to support it" ;;
  esac
fi
case "$terminal" in
  tmux | windows_terminal) ;;
  *) [ -n "$caller_tty" ] || die "could not find the calling session's tty" ;;
esac

if [ -n "${TMPDIR:-}" ] || [ "$windows" = 1 ]; then
  launcher_dir="${TMPDIR:-/tmp}"; launcher_dir="${launcher_dir%/}/claude-spawn"
  mkdir -p "$launcher_dir"
else
  # In the shared /tmp another user could replace a launcher before the new tab sources it
  launcher_dir="/tmp/claude-spawn-$(id -u)"
  mkdir -p -m 700 "$launcher_dir"
  [ -d "$launcher_dir" ] && [ ! -L "$launcher_dir" ] && [ -O "$launcher_dir" ] ||
    die "$launcher_dir is not a folder of your own; remove it or set TMPDIR"
  chmod 700 "$launcher_dir"
fi
umask 077
slug="$(printf '%s' "$name" | tr -cs 'A-Za-z0-9' '-' | sed 's/^-//;s/-$//')"
if [ "$terminal" = windows_terminal ]; then
  # one file per value, so nothing in the name or prompt passes through a command-line parser on the way in
  [[ "$dir" != *";"* ]] || die "--dir must not contain ';' (Windows Terminal treats it as a command separator)"
  launcher="$launcher_dir/${slug:-session}-$(date +%Y%m%d-%H%M%S)-$$"
  mkdir "$launcher"
  printf '%s' "$name" > "$launcher/name.txt"
  printf '%s' "$(cygpath -w "$dir")" > "$launcher/dir.txt"
  printf '%s' "$mode" > "$launcher/mode.txt"
  [ "$ac_value" = auto ] || printf '%s' "$ac_value" > "$launcher/autocompact.txt"
  [ -z "$report_to" ] || printf '%s' "$(report_protocol "$report_to")" > "$launcher/system.txt"
  cp "$prompt_file" "$launcher/prompt.txt"
  if [ "$(cat "$launcher"/*.txt | wc -c)" -gt 30000 ]; then
    rm -rf "$launcher"; die "prompt too long for a Windows command line; keep the prompt file under about 28 KB"
  fi
else
  launcher="$launcher_dir/${slug:-session}-$(date +%Y%m%d-%H%M%S)-$$.sh"
  eof="SPAWN_PROMPT_$(date +%s)_$$"
  grep -qx "$eof" "$prompt_file" && die "prompt file contains the heredoc delimiter $eof"
  {
    printf '{\n'
    printf 'rm -f %s\n' "$(shquote "$launcher")"
    printf 'clear\n'
    printf 'printf %s %s\n' "$(shquote '\nNew agent session:\n\033[1m%s\033[0m\n\n')" \
      "$(shquote "$name")"
    # set by a terminal first started inside a Claude session; a worker with them is a child, unreachable by name
    printf 'unset CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_ENTRYPOINT CLAUDECODE CLAUDE_CODE_SSE_PORT\n'
    # never inside $(...): there bash 3.2 lets an apostrophe or ")" in the prompt break out (CLAUDE.md, Traps)
    printf 'IFS= read -r -d %s spawn_prompt <<%s\n' "''" "$(shquote "$eof")"
    cat "$prompt_file"
    printf '\n%s\n' "$eof"
    printf 'cd %s &&\n' "$(shquote "$dir")"
    printf 'claude -n %s' "$(shquote "$name")"
    printf ' --permission-mode %s' "$(shquote "$mode")"
    [ "$ac_value" = auto ] || printf ' --autocompact %s' "$ac_value"
    if [ -n "$report_to" ]; then
      printf ' --append-system-prompt %s' "$(shquote "$(report_protocol "$report_to")")"
    fi
    # drop the newline the heredoc keeps before the delimiter
    printf ' "${spawn_prompt%%\n}"\nunset spawn_prompt\n}\n'
  } > "$launcher"
  tab_command=". $(shquote "$launcher")"
fi

echo "terminal: $terminal"
echo "caller tty: ${caller_tty:-none}"
echo "launcher: $launcher"
if [ "$dry_run" = 1 ]; then
  if [ -d "$launcher" ]; then
    for f in "$launcher"/*; do printf -- '--- %s\n%s\n' "${f##*/}" "$(cat "$f")"; done
  else
    cat "$launcher"
  fi
  rm -rf "$launcher"
  exit 0
fi

# shellcheck source=/dev/null
. "$here/lib/shield.sh"
# shellcheck source=/dev/null
. "$here/terminals/$terminal.sh"
open_tab || { rm -rf "$launcher"; die "failed to open a $terminal tab"; }
echo "launched: $name"
