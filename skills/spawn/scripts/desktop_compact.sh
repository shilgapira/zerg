#!/bin/bash
# Usage: desktop_compact.sh set --dir DIR [--autocompact auto|TOKENS]
#        desktop_compact.sh restore --dir DIR
#        desktop_compact.sh protocol --report-to SESSION   (prints the report-back text for the kickoff prompt)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
self="$here/$(basename "$0")"

die() { echo "spawn: $*" >&2; exit 1; }

# shellcheck source=/dev/null
. "$here/lib/worker.sh"

cmd="${1:-}"
[ $# -gt 0 ] && shift
dir="" autocompact=auto report_to=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dir | --autocompact | --report-to) [ $# -ge 2 ] || die "$1 needs a value" ;;
  esac
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --autocompact) autocompact="$2"; shift 2 ;;
    --report-to) report_to="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [ "$cmd" = protocol ]; then
  [ -n "$report_to" ] || die "--report-to is required"
  report_protocol "$report_to"
  echo
  exit 0
fi
case "$cmd" in
  set | restore) ;;
  *) die "usage: desktop_compact.sh set|restore --dir DIR [--autocompact VALUE], or protocol --report-to SESSION" ;;
esac
[ -n "$dir" ] || die "--dir is required"
[ -d "$dir" ] || die "directory not found: $dir"
dir="$(cd "$dir" && pwd -P)"
settings="$dir/.claude/settings.local.json"
state_root="${TMPDIR:-/tmp}"; state_root="${state_root%/}/claude-spawn"
state="$state_root/compact-$(printf '%s' "$dir" | shasum -a 256 | cut -c1-16)"
lock="$state.lock"
timeout="${SPAWN_COMPACT_TIMEOUT:-60}"
[[ "$timeout" =~ ^[0-9]+$ ]] || die "SPAWN_COMPACT_TIMEOUT must be a whole number of seconds: $timeout"

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

put() { printf '%s' "$2" > "$1.tmp" && mv "$1.tmp" "$1"; }

# Prints the previous autoCompactWindow of file $1 as JSON, or none; with $2, sets it to $2 (JSON) or removes it (none).
json_key() {
  osascript -l JavaScript - "$@" <<'JXA'
ObjC.import('Foundation');
function run(argv) {
  var path = argv[0], value = argv[1], fm = $.NSFileManager.defaultManager;
  var obj = {};
  if (fm.fileExistsAtPath(path)) {
    var text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null).js;
    if (text.trim() !== '') obj = JSON.parse(text);
  }
  if (obj === null || typeof obj !== 'object' || Array.isArray(obj)) throw new Error('settings is not a JSON object');
  var previous = Object.prototype.hasOwnProperty.call(obj, 'autoCompactWindow')
    ? JSON.stringify(obj.autoCompactWindow) : 'none';
  if (value === undefined) return previous;
  if (value === 'none') delete obj.autoCompactWindow; else obj.autoCompactWindow = JSON.parse(value);
  var out = $(JSON.stringify(obj, null, 2) + '\n');
  if (!out.writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null)) {
    throw new Error('write failed');
  }
  return previous;
}
JXA
}

acquire_lock() {
  local i holder
  mkdir -p "$state_root"
  for i in $(seq 1 50); do
    if mkdir "$lock" 2>/dev/null; then echo $$ > "$lock/pid"; return 0; fi
    # a holder killed before its EXIT trap leaves the lock behind
    holder="$(cat "$lock/pid" 2>/dev/null)"
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null && [ "$(cat "$lock/pid" 2>/dev/null)" = "$holder" ]; then
      rm -f "$lock/pid"; rmdir "$lock" 2>/dev/null; continue
    fi
    sleep 0.1
  done
  die "another desktop_compact.sh run holds $lock; remove it if no launch is in progress"
}
release_lock() { rm -f "$lock/pid"; rmdir "$lock" 2>/dev/null || true; }

# Skips the caller: the watchdog bash -c may be our parent or, in bash 5.1+, exec into us.
stop_watchdog() {
  local pid
  [ -f "$state/watchdog.pid" ] || return 0
  pid="$(cat "$state/watchdog.pid")"
  [ "$pid" != "$PPID" ] && [ "$pid" != "$$" ] || return 0
  ps -p "$pid" -o command= 2>/dev/null | grep -q desktop_compact.sh || return 0
  kill "$pid" 2>/dev/null || true
}

restore_locked() {
  [ -d "$state" ] || return 0
  if [ ! -f "$state/written.sha" ] ||
    { [ -f "$settings" ] && [ "$(sha "$settings")" = "$(cat "$state/written.sha")" ]; }; then
    if [ -f "$state/backup" ]; then
      cp -p "$state/backup" "$settings"
    else
      rm -f "$settings"
    fi
  elif [ -f "$settings" ]; then
    json_key "$settings" "$(cat "$state/previous")" >/dev/null || return 1
  fi
  [ ! -f "$state/created_claude_dir" ] || rmdir "$dir/.claude" 2>/dev/null || true
  stop_watchdog
  rm -rf "$state"
}

acquire_lock
trap release_lock EXIT

if [ "$cmd" = restore ]; then
  if [ ! -d "$state" ]; then
    echo "nothing to restore for $dir"
    exit 0
  fi
  restore_locked || die "could not revert autoCompactWindow in $settings (not a JSON object); state kept in $state"
  echo "autocompact setting reverted for $dir"
  exit 0
fi

value="$(normalize_autocompact "$autocompact")" || die "invalid --autocompact: $autocompact (auto, or 100k to 1M)"
# Restore a state left by an earlier run first, so our own key is never backed up as the user setting.
restore_locked ||
  die "a previous run's change to $settings could not be reverted (not a JSON object); state kept in $state"
[ "$value" != auto ] || { echo "autocompact auto: settings left unchanged"; exit 0; }
[ ! -L "$settings" ] || die "$settings is a symlink; not changing it"

rm -rf "$state.new"
mkdir "$state.new"
[ -d "$dir/.claude" ] || touch "$state.new/created_claude_dir"
[ ! -f "$settings" ] || cp -p "$settings" "$state.new/backup"
previous="$(json_key "$settings")" || { rm -rf "$state.new"; die "$settings is not a JSON object; not changing it"; }
put "$state.new/previous" "$previous"
mv "$state.new" "$state"

mkdir -p "$dir/.claude"
if ! json_key "$settings" "$value" >/dev/null; then
  restore_locked || true
  die "could not update $settings"
fi
put "$state/written.sha" "$(sha "$settings")"

nohup /bin/bash -c 'sleep "$1"; "$2" restore --dir "$3"' _ "$timeout" "$self" "$dir" >/dev/null 2>&1 &
put "$state/watchdog.pid" "$!"
echo "autocompact $value set in $settings; restore once the worker has started" \
  "(list_events shows its first message), or it restores itself in ${timeout}s"
