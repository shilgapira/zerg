# Lessons

What went wrong in earlier multi-session projects, and the rule each one produced.

| What happened | Rule |
|---|---|
| Sessions forgot their own unmerged commits after a few compactions; work was nearly lost. | The boss audits unmerged work at every pause and after its own compactions (`task.py audit`), asks each owner about commits that haven't landed, and keeps the answers in its state file. |
| Sessions drifted from the rules after compactions (stopped restarting waiters, skipped reviews). | The rules every session needs are in the skill's core (SKILL.md), re-attached after a compaction, and the error-prone steps (squash, merge, the waiter's restart) are commands, not prose. |
| A session's waiter died and mail sat unread for hours; the session looked like it was waiting for a decision. | Health check every 30 minutes with `mail.py status`; wake sessions marked CHECK. When the user asks "is X stuck?", check its waiter first. |
| A session sat for hours on a permission prompt nobody saw. | Sessions run in auto mode; the mailbox and read-only commands are allowlisted. A session that stays CHECK after a wake-up: tell the user which session to look at. |
| A session refused an action asked another session to do it. | Never work around a permission denial, never ask another session to do what was denied. List it for the user. |
| Session worktrees grew to hundreds of GB (caches, scratch, finished worktrees). | Scratch only in `.zerg/temp/<role>/`, kept data once in `.zerg/data/<role>/`, a per-tool cache decision (`skills/setup/SKILL.md`); remove a worktree and branch as soon as its work is merged. |
| Two sessions used the same resource at once (both launched the app); a benchmark measured another session's build. | Shared resources go through `task.py` slots; timing runs in a quiet window (`usertest --for`). |
| Timing moved by 7% from machine load alone. | Baselines on a quiet machine; settle a suspected regression by running old and new back to back. |
| A merged branch had moved after the merge request: unreviewed commits landed. | Merge only the exact hash named, never a branch name, and only as a fast-forward. |
| Too many sessions burned tokens overnight without visible progress. | One focused goal at a time, chunks small enough to review in one sitting; add a session only when the work clearly splits. |
| The account hit its usage limit twice overnight; every session stopped mid-task for hours. | The boss pauses at the stop the user set (`usage.py --stop-at`); sessions keep their exact next steps in the state file, so each resumes alone after the reset. |
| The user said "don't schedule more work" and sessions kept starting new tasks. | It means no new assignments: let running work reach a safe point, then hold. |
| A session killed every process with a program's name, including other sessions' jobs. | Kill by PID only. |
| The same failing test was rerun unchanged, twice. | Two identical failures mean stop and diagnose. |
| A wrong first call by the boss sent a session down the wrong path; another session knew why. | Before deciding on a technical question, ask the session that owns the code; reverse quickly when shown wrong. |
| A word meant one thing to the sessions and another to the user ("lighter" read as brightness, not size). | Plain words; when the user misreads one, record the preferred word in the user's standing preferences in `etc/zerg/project.md`. |
| A result was reported as done when only "it built" had been checked. | Name the level of verification in every claim. |
| Hand-offs were sent twice, by mail and by direct message, waking the receiver twice and spending the capped direct messages. | The mail waiter wakes the receiver; never send a direct message that repeats a mail. |
| Merging rebased, squashed and rechecked commits already on top of `main`; the recheck never found anything. | Sessions squash and check; such a commit lands unchanged (`task.py prepare` passes it through). |
| A report presented the boss's own question as something the user had asked. | Every question in a report names who asks it. |
| A squash onto a `main` that had moved reverted another session's merged work, four times in one night. | Squash only with `task.py squash`, which rebases and squashes in one step and refuses changes to files the branch never touched. |
| A command chain with `cd` failed halfway and ran its last git command in the main checkout, detaching `main`. | Never `cd` into another checkout: `git -C <path>`; the boss merges with `task.py merge`, which checks the checkout first. |
| A Merging session mostly relayed: across the trials it passed most requests through, and resolved 2 conflicts in 158 requests on the largest team; small teams never used it. | No Merging session: the boss runs `task.py prepare` (rebase and recheck in a throwaway tree) and `task.py merge`; a conflict goes back to the sender, who knows the intent. |
| Driving Windows tests from a Mac over a LAN link: its token traveled in clear text in every message, a one-shot listener was unreachable between messages, and a DHCP change left a listener on a vanished address. | `/zerg:tunnel`: TLS with a certificate pinned in the prompt the user pastes, and a secret that never crosses the network before the pin is checked; only the boss's computer listens, mail waits in the inbox until fetched, and the client finds a moved boss by scanning the old address's neighbours for the pinned certificate. |
| The boss's health check ran every 30 minutes through about 20 idle hours, a full turn on the boss's context each time, and one run hit the usage limit. | The health check runs only while work is in flight, and a run that finds nothing says nothing to the user. |
| `mail.py send FROM TO` was typed the other way round, and the boss's first task mails landed in its own inbox with no error. | `mail.py send --from FROM --to TO`: named flags, and the old form fails naming both. |
| Reviewer QA'd `main` after every move of it, 9 rounds that found nothing, and fixes for LOW findings went back for a second review round. | Reviewer reviews what it's asked to, and a "ready" verdict's LOW fixes go to the merge request without another round. |
| Held sessions turned their waiters off: mail sent to them sat unread, and resuming took a direct message to each. | The waiter has no timeout while its session runs, so a held session keeps listening and resuming is a mail. |
| Idle branches stayed on their last merged commit while main moved on, so sessions started new tasks on old code and docs; squash and prepare rebase what ships, but not what a session read. | A session in a worktree rebases on `main` when it takes a task, unless a merge request is pending. |
