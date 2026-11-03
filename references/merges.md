# Merges

Only the boss writes `main`: other sessions' work only by fast-forwarding to an exact commit that was checked as the
bytes that land, its own shared-file edits as direct commits. Each merge request is one commit on top of `main`,
squashed and checked by the session that sends it.

## Worktrees and branches

- Every other session works in `.claude/worktrees/<role>` on branch `<role>`, created from `main` as its first act:
  `git worktree add .claude/worktrees/<role> -b <role> main`.
- The boss works in the main checkout on `main`, and nobody else works there. Reviewer looks at each hash in a
  throwaway tree (`reviewer.md`).
- While a request is pending, keep committing on `<role>`; after "merged", `git rebase --onto main <the hash you
  sent>` carries those commits over. `task.py squash` refuses until the request is "merged", "returned" or withdrawn.
- Branch names are often also folder names (`api`): where git could read one as a path, write `refs/heads/api`.

## Before a merge request

1. **Review** by one subagent for code (data and docs need none): correctness, regressions, the project's conventions,
   docs made wrong. Fix what it finds or say why not. If the harness refuses the subagent, review your own diff
   against `main` and say so.
2. **Sweep for loose ends**: every finding is a fix, a todo, a note or a plan.
3. **Squash**: commit your work first (a WIP commit is fine). `task.py squash -m <message file> --who <role> --why
   "<summary>"` rebases on `main` and squashes to one commit in one step, and refuses a commit that would change files
   your branch never touched (a stale base silently reverts others' work); name a deliberate deletion or revert with
   `--deletes F` or `--restores F`. The message follows the Git rules in `/zerg:join`.
4. **Checks** on that commit: `task.py --at <hash> check --who <role> --why "..."` (with the same `--deletes` or
   `--restores`) runs them in a throwaway tree, so `runs.log` shows the exact commit and your worktree stays free.
5. **Reviewer**, when you judge the change risky, cross-area or touching shared code: send it that hash with what
   your subagent found and fixed. On "ready", fix the LOW findings you take up, squash and check again, and go on to
   the merge request without sending it back. On "ready after fixes", fix, squash and check again, and send Reviewer
   the new hash; it compares the two.
6. **Mail the merge request** (`mailbox.md`) to the boss, naming the hash Reviewer approved and any LOW fixes made
   since, if it reviewed. If `main` moves after your checks, send it anyway: the boss rebases and checks it again.
   To replace a pending request with a bigger squash, mail the boss "withdraw <hash>" first (`task.py squash`
   refuses until then), then squash, check and send a new request.

## Subagents

Within a session, delegate independent chunks to subagents: an investigation across many files, the review before a
merge request, a parallel implementation in separate files. Tell a subagent:

- the goal and what "done" looks like;
- which files it may change and that it commits only those (or none: report only);
- how to report back (a short summary with file:line evidence; what it checked and what it didn't).

Treat its report as claims: spot-check them before passing them on. A subagent is cheaper than a session when the work
is a bounded chunk; a session is better when the work needs a long memory of its own (a product area, a pipeline, an
ongoing dialogue with the user).

## Merging into `main` (boss)

One request at a time, in the order they arrive, skipping any its sender withdrew.

1. Read the merge request: exact hash, checks, review findings and what became of each.
2. Read the diff (`git diff --stat main...<hash>`, then the parts that matter): within the task's area or naming the
   shared files it changes, notes changed with the code they describe, nothing reverting someone else's line. Send
   anything risky that skipped Reviewer to Reviewer first, or return it.
3. `task.py prepare <hash> --from <role> --who boss --why "<summary>"`, in a throwaway tree: it passes the commit
   through when it is one commit on top of `main` whose checks passed on a clean tree, and otherwise rebases it and
   runs the checks. It prints the merge command to run next, or, on a conflict or a request of several commits, the
   "returned" mail to send the sender.
4. The merge command it printed, `task.py merge <hash> --from <role>:<the hash they sent> --who boss --why "..."`: it
   refuses unless the main checkout is clean and on `main` and the hash is a fast-forward, then journals the merge
   and mails "merged" to the sender.
5. Tell a session whose files the merge touched what changed for it.

The boss's own direct commits to the shared files it owns go in between requests.

## Conflicts

- The branch that lands second resolves: `task.py prepare` returns a request that conflicts with `main`, and the
  sender squashes it on the new `main` (`task.py squash`) and sends it again. The boss decides who gives way when
  sessions disagree.
- A conflict in a generated file (an API spec, client code, a lockfile) is resolved by regenerating it on the rebased
  tree, never by merging it by hand.
