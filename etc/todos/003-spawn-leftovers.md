# TODO003 Spawn and flow test leftovers

- **Priority**: Low
- **Status**: Ready
- **Risk**: a rerun after a half-failed launch opens a second tab; `make clean` can lose a user's settings file.

Found by a review of the shell scripts before the repo went public:
- A failure after the tab opened (finding its tty, `do script`, `input text` in `apple_terminal.sh` and
  `ghostty.sh`) gives the same "failed to open a <terminal> tab" as a failure before any tab opened, while
  `references/terminal.md` says an error before a tab opened is safe to rerun. The caller can't tell the cases apart.
- `make clean` deletes all of `$TMPDIR/claude-spawn`, including Desktop auto-compact state (`compact-*/backup`);
  if that state is live, the user's original `settings.local.json` is lost.
- `tests/flow.sh` breaks when the repo or scratch path has a space (unquoted `$Z`, `$B`, `> $B/...`), and its UDP
  connect to 10.254.254.254 prints a traceback on a machine with no route.

## Options

1. Track whether a tab was created and say so ("a tab opened but the command was not typed; close it"); have
   `make clean` skip `compact-*`; quote the paths in flow.sh.
2. Leave them.

## Recommendation

Option 1. The tab message touches the AppleScript paths, so it needs a live launch in Terminal.app and Ghostty.
