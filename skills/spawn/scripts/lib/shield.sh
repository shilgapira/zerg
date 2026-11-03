# $2 is in tenths of a second.
wait_for() { local i=0; while [ ! -e "$1" ] && [ "$i" -lt "$2" ]; do sleep 0.1; i=$((i + 1)); done; [ -e "$1" ]; }

front_app() {
  osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true' \
    2>/dev/null || true
}

activate_app() {
  [ -n "$1" ] && [ "$1" != "${2:-}" ] || return 0
  osascript -e "tell application id \"$1\" to activate" >/dev/null 2>&1 || true
}

window_bounds_by_order() {
  osascript -l JavaScript - "$1" "$2" "$3" 2>/dev/null <<'JXA' || true
ObjC.import('CoreGraphics');
function run(argv) {
  var owner = argv[0], index = parseInt(argv[1], 10), expected = parseInt(argv[2], 10);
  var onScreenOnly = 1;
  var list = ObjC.castRefToObject($.CGWindowListCopyWindowInfo(onScreenOnly, 0)).js;
  var wins = list.map(function (w) { return w.js; }).filter(function (d) {
    return d.kCGWindowOwnerName && d.kCGWindowOwnerName.js === owner && d.kCGWindowLayer.js === 0;
  });
  if (wins.length !== expected || !(index >= 1 && index <= wins.length)) return '';
  var b = wins[index - 1].kCGWindowBounds.js;
  var x = b.X.js, y = b.Y.js;
  return [x, y, x + b.Width.js, y + b.Height.js].join(' ');
}
JXA
}

# Best effort: if the panel never shows, the launch goes ahead without it.
shield_start() {
  shield_dir="$launcher_dir/shield-$$"
  mkdir -p "$shield_dir"
  osascript -l JavaScript "$here/lib/input_shield.js" "$1" "$2" "$shield_dir" "${@:3}" >/dev/null 2>&1 &
  shield_pid=$!
  wait_for "$shield_dir/shown" 20 && sleep 1
  return 0
}

shield_refocus() {
  touch "$shield_dir/focus"
  wait_for "$shield_dir/ready" 15 || true
}

shield_running() { [ ! -e "$shield_dir/shown" ] || kill -0 "$shield_pid" 2>/dev/null; }

shield_launching() { touch "$shield_dir/launching"; }
shield_restoring() { touch "$shield_dir/restoring"; }

shield_abort() { kill "$shield_pid" 2>/dev/null || true; }

shield_finish() {
  touch "$shield_dir/close"
  wait "$shield_pid" 2>/dev/null || true
  rm -rf "$shield_dir"
}
