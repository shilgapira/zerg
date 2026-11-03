# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

zerg is a Claude Code plugin. It runs a team of parallel Claude Code sessions on one git repo: a boss session hands
out work and lands merges, sessions each own an area in their own worktree, and a Reviewer session reviews risky
changes. They talk through a file mailbox. The repo is both the plugin and a one-plugin marketplace (`zerg@zerg`).

## Commands

```bash
claude plugin validate .                   # manifests, skills
tests/flow.sh <new empty dir>              # the scripts end to end, through bin/zerg, in a scratch repo
cd skills/spawn && make check test dry-run # the launcher's own checks (bash -n, osacompile, desktop_compact tests)
```

`tests/flow.sh` is the regression test for `scripts/`. Run it after any script change and read its output: it
prints each step rather than asserting everything.

A real test is a team run: set up a scratch project under `etc/scratch/` with `/zerg:setup`. Drive its sessions from
outside with a tmux server of your own (`tmux -L <name> send-keys`, `capture-pane -p`), and spawn opens the team in
that server's windows. Paste long prompts with `load-buffer` and `paste-buffer -p`, because `send-keys` drops text
from a long line. Answer a folder-trust prompt once, in the project's root. `/exit` in a session with a running
waiter asks before stopping it.

For development, the plugin is installed from this folder (`claude plugin marketplace add <this repo>`, then
`claude plugin install zerg@zerg`). A local-path install runs in place, so the checked-out branch is what sessions
load. Running sessions pick up edits only after `/reload-plugins`. An older install can still be a copy: when
`~/.claude/plugins/installed_plugins.json` gives zerg an `installPath` under `~/.claude/plugins/cache/`, sessions run
that snapshot, and `claude --plugin-dir <this repo>` loads the folder for one session. A copied install refreshes
only when `version` in `.claude-plugin/plugin.json` changes, so bump it with any change to a project's layout.

## Layout

- `skills/join/SKILL.md`: `/zerg:join <role>`, the rules every team session follows. Each role reads more from
  `references/` at its first start.
- `skills/setup/SKILL.md`: `/zerg:setup` (user-only), the bootstrap that sets a repo up for a team.
- `skills/spawn/`: `/zerg:spawn`, which opens a named session in a new terminal tab or Claude Desktop. It has its own
  `CLAUDE.md`, `Makefile` and tests; read those before changing it. It must run on a stock Mac with no Python (bash,
  AppleScript and JXA only), unlike `scripts/`.
- `skills/tunnel/SKILL.md`: `/zerg:tunnel`, a channel from the boss to an agent session on another computer.
  `scripts/tunnel.py` is both its server (on the boss's computer) and its client: the other computer downloads that
  same file, so its client half must run there alone, without `mail.py` or a project.
- `references/`: what each role reads at its first start (`boss.md`, `reviewer.md`, `merges.md`, `mailbox.md`,
  `resources.md`), and `layout.md`, the project layout and what the workflow relies on from Claude Code.
- `scripts/`: `task.py` (locks, checks, squash, prepare, merge, open), `mail.py` (the mailbox and its waiter),
  `usage.py` (plan usage, macOS only), `init.py` (writes `templates/project/` into a project), `tunnel.py`. Python
  3.9+ standard library only.
- `bin/zerg`: the command sessions run (`zerg task|mail|usage|init|tunnel`). It is on the Bash tool's PATH while the
  plugin is enabled, and finds Python as `py -3`, `python3`, then `python`, skipping the Windows Store placeholders.
- `templates/`: the project files `init.py` writes, plus the state file and todo/note/plan templates.
- `etc/notes/lessons.md`: why the rules exist, one incident per row. It is for maintainers and isn't loaded by
  sessions.
- `etc/todos/`: known issues and deferred work, one file each (`templates/todo.md`), numbered by hand.
- `etc/scratch/` (gitignored): trial projects and their findings.

## Things that span several files

- **No plugin paths in project files.** An installed plugin lives in a folder that changes with every version, so
  state files, kickoffs, hints and the allow rules in `templates/project/.claude/settings.json` use the bare `zerg`
  command. `${CLAUDE_PLUGIN_ROOT}` and `${CLAUDE_SKILL_DIR}` are substituted only in SKILL.md files, not in
  `references/*.md`, nor in the Bash tool.
- **Docs and scripts name each other.** SKILL.md and the references call the scripts `task.py`, `mail.py` and
  `usage.py`, which join's SKILL.md defines as `zerg task` etc. The scripts print hints and kickoffs that the docs
  describe (for example `task.py open` prints what `/zerg:spawn` needs). Change both sides together.
- **Where scripts look.** Every script works on the git tree of the current directory. `.zerg/` (mail, state files,
  journal, runs.log, slot locks) is gitignored as a whole and exists only in the main checkout, found through
  `git rev-parse --git-common-dir`; the tracked `etc/zerg/` (config.json, project.md) is in every checkout.
  The checks come from the config of the tree being checked; slots, tasks and the usage stop come from the main
  checkout's `etc/zerg/config.json`. Unknown config keys fail loudly (`CONFIG_KEYS` in `task.py`).
- **Skill text budget.** After a compaction, Claude Code re-attaches only the first ~5k tokens of an invoked skill,
  so `skills/join/SKILL.md` holds only what every session needs; role detail goes in `references/`.
- **The waiter** (`mail.py wait`) is the one mechanism every session depends on. It exits without reading mail
  once the session in `CLAUDE_PID` is gone, because Claude Desktop on Windows leaves background jobs running
  after a session closes.
- **Windows.** Sessions run the scripts from Git Bash. `.gitattributes` keeps `*.sh` and `bin/zerg` at LF. Process
  checks use `OpenProcess`, not `os.kill`.

## Conventions

- Skill text: sessions repeat it back to the user, so write rules as what to do, not "don't X", in plain words, with
  no coined terms a session might echo.
- ASCII only, in code and docs alike: `--` or a colon rather than dashes, `->` rather than arrows, straight quotes.
- Wrap at 120 columns.
- A rule added or changed because of something that went wrong in a team run gets a row in `etc/notes/lessons.md`:
  what happened, then the rule.

Commits follow Conventional Commits, with a body saying why, then short bullets.
