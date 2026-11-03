# Layout and harness

## Layout

```
<project>/                     the main checkout: the boss works here, on main
  etc/notes/                   facts worth keeping, one subject per file
  etc/todos/                   open items, NNN-slug.md, each number used once
  etc/plans/                   researched work set aside for later
  etc/zerg/config.json         read by task.py
  etc/zerg/project.md          the team's setup: product areas, the user's preferences, the project's rules
  .claude/settings.json        allow rules for read-only git and zerg's bookkeeping commands
  .claude/worktrees/<role>/    one git worktree per session, on branch <role> (gitignored)
  .zerg/                       gitignored, and exists ONLY in the main checkout
    team/journal.md            one stamped line per merge, decision and stop: the user's catch-up (boss)
    team/runs.log              two lines per task.py run: who, why, commit, result (task.py)
    state/<role>.md            each session's live state, survives compaction
    mail/<role>/               the mailbox: unread messages, read/ for read ones
    data/                      kept but not in git: the user's material at the root, a session's in data/<role>/
    locks/                     slot locks, the user test and the todo counter (task.py)
    tunnel/<role>/             a channel to a session on another computer: key, secret, staged files (tunnel.py)
    temp/<role>/               disposable: scratch, build output, screenshots, task.py output
```

Losing `temp/` costs nothing (the user may clear it any time; move anything a todo cites to `data/` first);
the rest of `.zerg/` is lost for good, so include `.zerg/` minus `temp/` in whatever backup the project uses
(`data/` may hold credentials and large clones).

## Harness

What the workflow relies on from Claude Code. When the harness changes, update this table and the files that point
here.

| Mechanism | Provided by | Used for | Assumption |
|---|---|---|---|
| Background jobs that wake the session | Bash with `run_in_background` (its tool timeout doesn't apply) | The mail waiter, long builds and tests | A tracked job's exit wakes the session; a process started with `&` does not |
| Scheduled prompts | `CronCreate`, `CronList`, `CronDelete` | The boss's health check (`boss.md`) | Session-only: gone when the session ends |
| Session-to-session messages | `SendMessage` (`ListAgents` for names) | Waking a session marked CHECK, urgent stops | Lost when nobody listens; a run of about ten with no user message in between may be dropped. Mail is never capped, so everything else goes by mail |
| Starting sessions | `/zerg:spawn` with what `task.py open` prints (Terminal.app, iTerm2, Ghostty, tmux, Windows Terminal, Claude Desktop); else the user with the command and kickoff `task.py open` prints | The bootstrap opening the boss, the boss opening the others | The kickoff's first line, `/zerg:join <role>`, is expanded as a slash command; the first launch may show macOS Automation (Terminal.app: Accessibility) prompts |
| Permissions | Auto mode, and allow rules in `.claude/settings.json` for read-only git and zerg's mailbox and bookkeeping commands | Running the scripts and git without prompts | A command auto mode won't approve stops the session on a prompt only the user can answer |
| Subagents | The Agent tool | Reviews before merge requests, investigations, bounded chunks (`merges.md`, Subagents) | They share the session's machine and permissions, not its context; a launch may be refused |
| Skills | `/zerg:join <role>` | Loading the core rules | The invoked skill's text is re-attached after a compaction (its first ~5k tokens); after `claude --resume` it may be gone, so the session runs `/zerg:join` again |
| Usage limits | The plan's 5-hour and weekly limits; `usage.py` reads them (macOS) | The boss's pause before the limit stops everyone | At a limit every session stops mid-task; after the reset the harness tells each to continue, and it resumes from its state file |
