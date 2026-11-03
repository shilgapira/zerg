# Shared resources and the task runner

Several sessions on one machine compete for things only one job should use at a time: a local test database, a
fixed port, docker containers, a device or emulator, the running app, a heavy build that saturates the CPU.
`task.py` is the single entry point that keeps them from colliding (`task.py -h` lists its tasks, including the
project's own from `etc/zerg/config.json`).

## What it gives every task

- **Slots**: named resources with a capacity (`slots` in `etc/zerg/config.json`). A task takes a slot for its whole
  run; others wait and print who holds it. Locks live in the main checkout's `.zerg/locks/`, so every worktree sees
  them; a lock whose holder and job are gone, or whose lease ran out, is cleared automatically.
- **A hard timeout**: every job is killed when its time is up, with its whole process tree, by PID.
- **Logs**, in the main checkout: full output in `.zerg/temp/<who>/`, one file per job; two lines per task in
  `.zerg/team/runs.log` (start, then done or failed), with the commit, whether the tree was dirty, `--who` and `--why`.
- **Stopping**: `task.py slots` shows each running task's PID; `kill <pid>` stops the task and its job (on Windows,
  `taskkill /T` the job's own PID).

## When the user tests, and quiet windows

```bash
task.py usertest 90                          # the user is trying it: nothing automated starts for 90 min
task.py usertest 60 --slots gpu --no-wait    # only the gpu slot, without waiting for running jobs
task.py usertest 30 --for performance        # quiet window: only performance's runs start
task.py usertest --end
```

`usertest` waits for running jobs to finish before saying it's set, then no new locked job starts until `--end`.
It only stops what goes through `task.py`; a command run directly is invisible to it. A quiet window (`--for`) is
for benchmarks: timing moves by several percent with machine load alone, so baselines and comparisons run in one,
old and new back to back.

## Built-in tasks

- `run --slot NAME [--timeout S] -- COMMAND`: any command, holding one of NAME's slots, with a timeout and the
  usual logs.
- `todos` / `todos next --who <role>`: open todos by priority; the next todo number from a counter every worktree
  shares.
- `check`, `squash`, `prepare`, `merge`, `--at HASH`: `merges.md`. `journal`, `open`: `boss.md`.
- `audit [BASE]`: commits not on BASE per branch, whether each branch's changes already landed, uncommitted files
  per worktree (the boss's routine is in `boss.md`).
- Project tasks (build, test, run, a shared stack) are `tasks` in `etc/zerg/config.json`, run as
  `task.py <name> [-- args]`; the config is boss-owned, so sessions change it on their branch and name the change in
  the merge request.
