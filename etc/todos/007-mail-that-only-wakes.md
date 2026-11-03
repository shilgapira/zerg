# TODO007 Boss mail that only wakes an idle session

- **Priority**: Low
- **Status**: Needs decision
- **Risk**: every mail costs its recipient a full turn on its context (read the waiter's output, restart the
  waiter, often a state file edit); on a long run with a chatty boss that adds up to many wasted turns.

Seen in three trials (2026-11-03), each flagged by the sessions that got the mail:
- unitconv (run5): the boss mailed Reviewer "standing by", then "focus done: hold"; each only woke it to restart
  its waiter.
- colstats (run6): Reviewer got "standby: nothing yet" and "heads-up: slice 2 review coming"; stats got "hold:
  slice 1 done" and "fyi: report touches stats.py" within a minute of its "merged".
- shapes (run7): the pause mail and then the resume woke circles, which had nothing in flight, twice for nothing.

Nothing in `references/boss.md` asks for these mails; the boss sends them to be thorough. The pause step there says
to "send one mail to everyone".

## Options

1. One sentence in boss.md: mail a session only when it has something to act on (a task, an answer, a change that
   affects its work), and fold notes into the next real mail; the pause mail goes only to sessions with work in
   flight, since an idle session takes work only from the boss's mail.
2. Only the pause narrowing from option 1.
3. Leave it.

## Recommendation

Option 1, checked with a team run that the boss still tells sessions what they need (a "merged" and a changed file
in their area, for instance).
