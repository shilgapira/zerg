# TODO002 task.py and mail.py edge cases

- **Priority**: Low
- **Status**: Ready
- **Risk**: rare misuse or races give a confusing error, a traceback, or a second waiter.

Found by a review of the scripts before the repo went public, each confirmed by an experiment:
- `zerg init` in a subfolder of a repo, or in a worktree, writes files there and then fails with "no
  etc/zerg/config.json" (`scripts/init.py`): refuse unless the folder is the repo's top level and main checkout.
- `load_config` (`scripts/task.py`): `"tasks": []` crashes with AttributeError, `"checks": {...}` gets a misleading
  message, `timeout: true` passes (a bool is an int), and slot names, which become lock file names, aren't checked.
- Heartbeat and lock entries are rewritten in place (`write_text`), so a waiter that reads one at that instant sees
  `{}` and may start a second waiter: write to a temp file and `os.replace`, as `deliver` does.
- The stale-base guard parses `git diff --name-status` without `-z`; a file name with a tab, newline or `"` is
  C-quoted by git and then confuses `rev-parse`.
- Stopping an `--at` run (SIGTERM to the outer task.py) removes its throwaway tree while the inner run continues in
  it; forward the signal to the child first.

## Options

1. Fix them one commit each, with a flow.sh step where one fits.
2. Leave them: each needs misuse, odd file names or a narrow race.

## Recommendation

Option 1, the init and load_config items first, since a new user is most likely to meet those.
