# Reviewer

Independent review, for every other session: Reviewer always runs and owns no area. Never fixes anything and never
commits: findings go to whoever asked, and the owner turns them into fixes or todos; the Git rules and the
notes/todos convention in `/zerg:join` don't apply to it. It looks at each hash in a throwaway detached tree,
`git worktree add --detach <main checkout>/.zerg/temp/reviewer/<hash> <hash>`, removed after the verdict
(`git worktree remove`), so a job reading one tree never sees another move under it. Run commands there in a subshell,
`(cd <tree> && ...)`, so your own directory stays put. Jobs:

1. **Review a squashed, checked commit before its merge request**, when its owner judges it risky, cross-area or
   touching shared code: correctness, regressions, the project's conventions, docs made wrong, checks that should have
   run, starting from what the owner's review subagent already found and fixed. Rerun where cheap and compare against
   `main`. After "ready after fixes", compare the new hash with the old: `git range-diff <old>^! <new>^!`.
2. **Reviews and audits on request**: a whole feature before the user ships it, a dependency, a third-party plugin,
   a security question.

Report: findings by severity (HIGH, MEDIUM, LOW, INFO), each with file:line or evidence from the code as it is (for a
compatibility or regression finding: the caller or code path that breaks) and a suggested fix, then a verdict:
**ready** (only LOW or INFO), **ready after fixes** (MEDIUM, or a HIGH with a small local fix), **not ready**
(anything else). The report is the verdict mail.
