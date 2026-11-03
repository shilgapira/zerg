# TODO001 Windows and unusual filesystems

- **Priority**: Low
- **Status**: Ready
- **Risk**: a session on Windows, or on a filesystem without hard links, hits a traceback or a wait that never ends.

Found by a review of the scripts before the repo went public (read, not reproduced on Windows):
- `scripts/mail.py` `read_all` catches only `FileNotFoundError` around `os.replace`. On Windows, renaming a message
  another process has open (peek, status, the pending-request scan) raises `PermissionError` (WinError 32), so
  `wait --read` can die. `unlock` in `task.py` already retries on that error.
- `scripts/task.py` `write_new` treats every `os.link` error as "taken". On a filesystem without hard links (exFAT,
  some network shares) every slot waits forever, with no holder named.
- `skills/spawn/scripts/launch.sh` caps a Windows Terminal job at 30000 bytes before `wt_launcher.ps1` escapes
  quotes (one extra `\` per `"`), so a quote-heavy prompt can pass the check and then exceed 32767 characters.
- `task.py` prints in the console's encoding, so a non-ASCII path shows garbled in its output on Windows (the files
  are right; only the text shown is not).

## Options

1. Fix each: retry briefly on `PermissionError`; let `write_new` fail loudly on errors other than `FileExistsError`
   (and Windows' `PermissionError`); count quotes and backslashes in the cap, or measure after escaping in the ps1;
   reconfigure task.py's stdout to UTF-8 as mail.py does.
2. Leave them until someone hits them.

## Recommendation

Option 1, tested on a Windows machine through `/zerg:tunnel`, since none of these can be checked on macOS.
