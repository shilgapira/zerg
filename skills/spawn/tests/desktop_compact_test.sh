#!/bin/bash
# Tests scripts/desktop_compact.sh against throwaway folders, never a real project.
set -u
dc="$(cd "$(dirname "$0")/.." && pwd)/scripts/desktop_compact.sh"
root="$(mktemp -d)"; root="$(cd "$root" && pwd -P)"
pass=0 fail=0
ok() {
  if [ "$1" = "$2" ]; then
    pass=$((pass+1)); echo "  ok   $3"
  else
    fail=$((fail+1)); echo "  FAIL $3: expected [$2] got [$1]"
  fi
}
key() {
  osascript -l JavaScript -e "function run(a){var t=\$.NSString.stringWithContentsOfFileEncodingError(a[0],4,null).js;
    var o=JSON.parse(t); return o.hasOwnProperty('autoCompactWindow')?String(o.autoCompactWindow):'none'}" \
    "$1/.claude/settings.local.json" 2>/dev/null || echo nofile
}
# Runs JavaScript $2 on JSON file $1 parsed as o and writes it back, as Claude Code might.
edit_json() {
  osascript -l JavaScript -e "function run(a){var p=a[0];
    var o=JSON.parse(\$.NSString.stringWithContentsOfFileEncodingError(p,4,null).js); $2;
    \$(JSON.stringify(o)).writeToFileAtomicallyEncodingError(p,true,4,null)}" "$1"
}
settings_sha() { shasum -a 256 < "$1/.claude/settings.local.json"; }
orig='{
    "permissions": {"allow": ["Bash(ls:*)"]}
}'

echo "1. no settings file, no .claude dir"
d="$root/t1"; mkdir -p "$d"
"$dc" set --dir "$d" --autocompact 500k >/dev/null; ok "$(key "$d")" 500000 "key set"
"$dc" restore --dir "$d" >/dev/null; ok "$([ -e "$d/.claude" ] && echo exists || echo gone)" gone \
  "file and .claude removed"

echo "2. existing file, untouched meanwhile: byte-exact restore"
d="$root/t2"; mkdir -p "$d/.claude"; printf '%s\n' "$orig" > "$d/.claude/settings.local.json"
before="$(settings_sha "$d")"
"$dc" set --dir "$d" --autocompact 450k >/dev/null; ok "$(key "$d")" 450000 "key set to 450k"
ok "$(grep -c 'Bash(ls' "$d/.claude/settings.local.json")" 1 "other keys kept"
"$dc" restore --dir "$d" >/dev/null; ok "$(settings_sha "$d")" "$before" "byte-exact restore"

echo "3. existing file changed by Claude Code meanwhile: only our key reverted"
d="$root/t3"; mkdir -p "$d/.claude"; printf '%s\n' "$orig" > "$d/.claude/settings.local.json"
"$dc" set --dir "$d" --autocompact 500k >/dev/null
edit_json "$d/.claude/settings.local.json" 'o.permissions.allow.push("Bash(git:*)")'
"$dc" restore --dir "$d" >/dev/null; ok "$(key "$d")" none "our key removed"
ok "$(grep -c 'Bash(git' "$d/.claude/settings.local.json")" 1 "concurrent change kept"

echo "4. user already had a value, file changed meanwhile: original value back"
d="$root/t4"; mkdir -p "$d/.claude"; printf '{"autoCompactWindow": 300000}\n' > "$d/.claude/settings.local.json"
"$dc" set --dir "$d" --autocompact 500k >/dev/null; ok "$(key "$d")" 500000 "overridden to 500k"
edit_json "$d/.claude/settings.local.json" 'o.extra=1'
"$dc" restore --dir "$d" >/dev/null; ok "$(key "$d")" 300000 "original 300000 back"

echo "5. stale state from a run that never restored"
d="$root/t5"; mkdir -p "$d/.claude"; printf '%s\n' "$orig" > "$d/.claude/settings.local.json"
before="$(settings_sha "$d")"
"$dc" set --dir "$d" --autocompact 400k >/dev/null; "$dc" set --dir "$d" --autocompact 600k >/dev/null
ok "$(key "$d")" 600000 "second set wins"
"$dc" restore --dir "$d" >/dev/null; ok "$(settings_sha "$d")" "$before" "user original back, not our first key"

echo "6. watchdog restores after the timeout"
d="$root/t6"; mkdir -p "$d/.claude"; printf '%s\n' "$orig" > "$d/.claude/settings.local.json"
before="$(settings_sha "$d")"
SPAWN_COMPACT_TIMEOUT=2 "$dc" set --dir "$d" --autocompact 500k >/dev/null; sleep 4
ok "$(settings_sha "$d")" "$before" "restored by watchdog"

echo "7. explicit restore stops the watchdog"
d="$root/t7"; mkdir -p "$d"
SPAWN_COMPACT_TIMEOUT=30 "$dc" set --dir "$d" --autocompact 500k >/dev/null
st="${TMPDIR%/}/claude-spawn/compact-$(printf '%s' "$d" | shasum -a 256 | cut -c1-16)"
wpid="$(cat "$st/watchdog.pid")"
"$dc" restore --dir "$d" >/dev/null; sleep 0.3
ok "$(kill -0 "$wpid" 2>/dev/null && echo alive || echo stopped)" stopped "watchdog killed"

echo "8. invalid JSON is left untouched"
d="$root/t8"; mkdir -p "$d/.claude"; printf '{broken\n' > "$d/.claude/settings.local.json"
"$dc" set --dir "$d" --autocompact 500k >/dev/null 2>&1; ok "$?" 1 "set fails"
ok "$(cat "$d/.claude/settings.local.json")" "{broken" "file unchanged"
"$dc" restore --dir "$d" >/dev/null; ok "$(cat "$d/.claude/settings.local.json")" "{broken" "restore is a no-op"

echo "9. auto and bad values"
d="$root/t9"; mkdir -p "$d"
ok "$("$dc" set --dir "$d" --autocompact auto)" "autocompact auto: settings left unchanged" "auto leaves settings"
ok "$("$dc" set --dir "$d")" "autocompact auto: settings left unchanged" "no value means auto"
ok "$([ -e "$d/.claude" ] && echo exists || echo none)" none "nothing created for auto"
"$dc" set --dir "$d" --autocompact 50k >/dev/null 2>&1; ok "$?" 1 "50k rejected"
ok "$("$dc" protocol --report-to 'Orch' | cut -c1-60)" "You are a worker session started by the Claude Code session " \
  "protocol text"

statedir() { echo "${TMPDIR%/}/claude-spawn/compact-$(printf '%s' "$1" | shasum -a 256 | cut -c1-16)"; }

echo "10. symlinked settings file is refused"
d="$root/t10"; mkdir -p "$d/.claude"; printf '{"a":1}\n' > "$d/real.json"
ln -s ../real.json "$d/.claude/settings.local.json"
"$dc" set --dir "$d" --autocompact 500k >/dev/null 2>&1; ok "$?" 1 "set fails"
ok "$([ -L "$d/.claude/settings.local.json" ] && echo link || echo file)" link "link kept"

echo "11. crash after the write, before the hash was recorded: exact backup restored"
d="$root/t11"; mkdir -p "$d/.claude"; printf '%s\n' "$orig" > "$d/.claude/settings.local.json"
before="$(settings_sha "$d")"
SPAWN_COMPACT_TIMEOUT=30 "$dc" set --dir "$d" --autocompact 500k >/dev/null; rm -f "$(statedir "$d")/written.sha"
"$dc" restore --dir "$d" >/dev/null; ok "$(settings_sha "$d")" "$before" "backup restored"
ok "$([ -d "$(statedir "$d")" ] && echo kept || echo gone)" gone "state dropped"

echo "12. file left as invalid JSON by someone else: restore keeps the state and says so"
d="$root/t12"; mkdir -p "$d/.claude"; printf '%s\n' "$orig" > "$d/.claude/settings.local.json"
SPAWN_COMPACT_TIMEOUT=30 "$dc" set --dir "$d" --autocompact 500k >/dev/null
printf '{broken\n' > "$d/.claude/settings.local.json"
"$dc" restore --dir "$d" >/dev/null 2>&1; ok "$?" 1 "restore fails"
ok "$([ -d "$(statedir "$d")" ] && echo kept || echo gone)" kept "state kept"
"$dc" set --dir "$d" --autocompact 500k >/dev/null 2>&1; ok "$?" 1 "next set refuses"
printf '%s\n' "$orig" > "$d/.claude/settings.local.json"
"$dc" restore --dir "$d" >/dev/null; ok "$?" 0 "restore works once the file is valid"

echo "13. a non-numeric timeout is rejected"
d="$root/t13"; mkdir -p "$d"
SPAWN_COMPACT_TIMEOUT=abc "$dc" set --dir "$d" --autocompact 500k >/dev/null 2>&1; ok "$?" 1 "set fails"
ok "$([ -e "$d/.claude" ] && echo exists || echo none)" none "nothing written"

echo "14. a lock left by a killed run is taken over"
d="$root/t14"; mkdir -p "$d"; sh -c "exit 0" & dead=$!; wait "$dead"
mkdir -p "$(statedir "$d").lock"; echo "$dead" > "$(statedir "$d").lock/pid"
"$dc" set --dir "$d" --autocompact 500k >/dev/null 2>&1; ok "$?" 0 "set takes the lock over"
"$dc" restore --dir "$d" >/dev/null
ok "$([ -e "$(statedir "$d").lock" ] && echo held || echo released)" released "lock released"

echo "== $pass passed, $fail failed"
rm -rf "$root"
[ "$fail" = 0 ]
