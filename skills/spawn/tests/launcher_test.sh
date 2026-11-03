#!/bin/bash
# The generated launcher under the shells a tab may run: the prompt reaches claude byte for byte as one argument,
# and nothing in it runs. Uses --dry-run and a stub claude, so no tab opens.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir "$work/dir"
fail=0

printf '%s\n' "Please don't touch main." "see foo) then \$(touch $work/ran) and \`touch $work/ran\`" '1) first step' \
  'a trailing \ backslash, "double" and '"'"'single'"'"' quotes, $HOME and ${HOME}' > "$work/prompt.txt"
"$here/scripts/launch.sh" --name "Bob's API" --prompt-file "$work/prompt.txt" --dir "$work/dir" --dry-run \
  > "$work/dry.txt" 2>&1 || { echo "FAIL: dry run"; cat "$work/dry.txt"; exit 1; }
sed -n '/^{/,$p' "$work/dry.txt" > "$work/launcher.sh"
# The prompt is the last argument of claude.
printf '%s\n' 'claude() { for a in "$@"; do :; done; printf "%s" "$a" > "$SPAWN_TEST_OUT"; }' 'clear() { :; }' \
  > "$work/stub.sh"

for sh in /bin/bash zsh; do
  command -v "$sh" > /dev/null || { echo "skip: $sh not found"; continue; }
  rm -f "$work/ran" "$work/out.txt"
  SPAWN_TEST_OUT="$work/out.txt" "$sh" -c '. "$1"; . "$2"' _ "$work/stub.sh" "$work/launcher.sh" > /dev/null 2>&1
  if [ -e "$work/ran" ]; then
    echo "FAIL: $sh ran a command from the prompt"; fail=1
  elif ! cmp -s "$work/prompt.txt" "$work/out.txt"; then
    echo "FAIL: $sh changed the prompt"; diff "$work/prompt.txt" "$work/out.txt"; fail=1
  else
    echo "ok: $sh"
  fi
done
exit "$fail"
