# TODO006 Lighter reading at a session's first start

- **Priority**: Low
- **Status**: Needs decision
- **Risk**: every session spends 3-6k tokens on rules before its first task, much of it on parts its role rarely
  uses; on a small project that is a large share of a session's whole run.

In the unitconv trial (2026-11-03), Reviewer, core and the boss each named the first-start reading as their biggest
cost. Word counts then: `skills/join/SKILL.md` 1053, `references/boss.md` 1314, `merges.md` 881, `mailbox.md` 701,
`reviewer.md` 240. The reading table in `/zerg:join` has the boss read boss.md, merges.md and mailbox.md, Reviewer
reviewer.md and mailbox.md, and any other session merges.md (minus the boss's section) and mailbox.md.

- Reviewer read mailbox.md (message formats, withdraw, tunnel) before knowing it had nothing to do, and the trial
  never sent it a review.
- A worker with a one-commit task read merges.md's Reviewer and withdraw parts and mailbox.md's tunnel rules.

## Options

1. Defer by need: Reviewer reads mailbox.md at its first review request; merges.md opens with the worker path, so
   a worker stops reading at the boss's section; rare cases (withdraw, tunnel) move to the end of their files.
2. Shorten the references themselves, rule by rule.
3. Leave them.

## Recommendation

Option 1, measured before and after (tokens read at the first start per role) and checked with a team run, since a
rule a session skips is a rule it can't follow.
