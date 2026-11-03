"""File mailbox between the Claude Code sessions of one project.

Messages live in the main checkout's .zerg/mail/<role>/ (found through git from the current directory, so every
worktree uses the same mailbox), one Markdown file each, written atomically. Reading moves them to <role>/read/. A
running `wait` keeps a heartbeat file in the inbox, which `status` uses to tell whether a session is listening.
`mail.py` below is this file, run as `zerg mail`.

    mail.py send --from FROM --to TO SUBJECT [--body-file F]
                             body from stdin unless --body-file; TO is roles joined by commas, where "all"
                             (everyone but FROM) may appear
    mail.py read ROLE        print unread messages, oldest first, and mark them read
    mail.py peek ROLE        list unread messages without marking them
    mail.py wait ROLE [--read] [--timeout S]
                             block until ROLE has unread mail (exit 0; with --read, print it and mark it read) or
                             the timeout passes (default: none while CLAUDE_PID names the session, else 12 hours;
                             exit 1); exits at once when another waiter for ROLE is running. Run it as a tracked
                             background job to be woken by new mail
    mail.py last ROLE [N]    reprint the N newest read messages (default 1)
    mail.py status           per role: session title, waiter state, unread mail and its age, last mail
                             sent; CHECK marks a role with mail unread for long and nobody listening
    mail.py roles            known roles (one inbox folder each; `task.py open` creates one)
"""

from __future__ import annotations

import argparse
import datetime
import functools
import json
import os
import re
import subprocess
import sys
import threading
import time
from pathlib import Path

POLL_S = 3.0
HEARTBEAT = ".waiting"
# A waiter refreshes its heartbeat every poll, so an older one means the waiter is gone.
HEARTBEAT_STALE_S = 30.0
# A session reads its mail and restarts its waiter within this, so a shorter gap is not reported as gone.
GRACE_S = 120.0
CHECK_AFTER_S = 600.0
ROLE_RE = re.compile(r"^[a-z][a-z0-9_-]*$")
STAMP_LOCK = threading.Lock()
LAST_STAMP = ""


@functools.cache
def main_checkout() -> Path:
    """Exits when the current directory isn't in a zerg project."""
    proc = subprocess.run(["git", "rev-parse", "--git-common-dir"], capture_output=True, text=True,
                          encoding="utf-8", errors="replace")
    if proc.returncode:
        sys.exit(f"mail: {Path.cwd()} is not in a git repository: run mail.py from your worktree")
    main = (Path.cwd() / proc.stdout.strip()).resolve().parent
    if not (main / "etc" / "zerg" / "config.json").is_file():
        sys.exit(f"mail: {main} is not a zerg project (no etc/zerg/config.json)")
    return main


def box() -> Path:
    return main_checkout() / ".zerg" / "mail"


def roles() -> list[str]:
    if not box().is_dir():
        sys.exit(f"mail: no mailbox at {box()} (task.py open ROLE --title ... makes an inbox)")
    return sorted(p.name for p in box().iterdir() if p.is_dir() and ROLE_RE.match(p.name))


def inbox(role: str) -> Path:
    if role not in roles():
        sys.exit(f"mail: unknown role {role!r}, known: {', '.join(roles()) or 'none'} "
                 "(task.py open ROLE --title ... creates one)")
    return box() / role


def unread(role: str) -> list[Path]:
    return sorted(inbox(role).glob("*.md"))


def deliver(sender: str, to: str, subject: str, body: str, via: str = "") -> list[str]:
    """Also called by tunnel.py for mail from another computer, with `via` naming the channel in a header."""
    check_sender(sender, subject)
    groups = {"all": [r for r in roles() if r != sender]}
    targets = list(dict.fromkeys(t for part in to.split(",") for t in groups.get(part.strip(), [part.strip()])))
    if not targets:
        sys.exit(f"mail: {to!r} names nobody")
    for role in targets:
        inbox(role)
    global LAST_STAMP
    with STAMP_LOCK:  # one name per message, even from the tunnel server's threads (one pid, one sender)
        while True:
            now = datetime.datetime.now()
            stamp = now.strftime("%Y%m%d-%H%M%S-") + f"{now.microsecond // 1000:03d}"
            if stamp != LAST_STAMP:
                LAST_STAMP = stamp
                break
            time.sleep(0.001)  # Windows clocks tick every 15.6 ms before Python 3.13: wait for the next one
    text = (f"From: {sender}\nTo: {to}\nTime: {now.isoformat(timespec='seconds')}\nSubject: {subject}\n"
            + (f"Via: {via} (another computer)\n" if via else "") + f"\n{body.strip()}\n")
    for role in targets:
        folder = inbox(role)
        name = f"{stamp}-{sender}-{os.getpid()}.md"
        tmp = folder / f".{name}.tmp"
        with open(tmp, "w", encoding="utf-8", newline="\n") as f:  # write_text has no newline= before 3.10
            f.write(text)
        os.replace(tmp, folder / name)
    return targets


def check_sender(sender: str, subject: str) -> None:
    inbox(sender)
    if "\n" in subject or "\r" in subject:
        sys.exit("mail: a subject is one line: the body goes on stdin or --body-file")


def cmd_send(ns: argparse.Namespace) -> None:
    if ns.body:
        sys.exit("mail: the body goes on stdin or --body-file, not on the command line")
    check_sender(ns.sender, ns.subject)  # before waiting on stdin
    body = Path(ns.body_file).read_text(encoding="utf-8") if ns.body_file else sys.stdin.read()
    print(f"mail: sent to {', '.join(deliver(ns.sender, ns.to, ns.subject, body))}")


def read_all(role: str) -> int:
    """Claims each message by moving it before printing, so two readers never print the same one."""
    count = 0
    for path in unread(role):
        claimed = path.parent / "read" / path.name
        try:
            os.replace(path, claimed)
        except FileNotFoundError:
            continue  # another reader took it
        print(f"===== {path.name}\n{claimed.read_text(encoding='utf-8')}")
        count += 1
    return count


def cmd_last(ns: argparse.Namespace) -> None:
    for path in sorted((inbox(ns.role) / "read").glob("*.md"))[-max(ns.n, 1):]:
        print(f"===== {path.name}\n{path.read_text(encoding='utf-8')}")


def refuse_remote(role: str) -> None:
    """A tunnel role is a session on another computer; reading its mail here would keep the mail from it."""
    if (main_checkout() / ".zerg" / "tunnel" / role).is_dir():
        sys.exit(f"mail: {role} is a session on another computer: its mail goes to it through `zerg tunnel`. "
                 f"`mail.py peek {role}` lists what waits for it")


def cmd_read(ns: argparse.Namespace) -> None:
    refuse_remote(ns.role)
    if not read_all(ns.role):
        print("mail: no unread messages")


def subject_of(path: Path) -> str:
    return next((line for line in path.read_text(encoding="utf-8").splitlines() if line.startswith("Subject: ")), "")


def cmd_peek(ns: argparse.Namespace) -> None:
    for path in unread(ns.role):
        try:
            print(path.name, subject_of(path))
        except FileNotFoundError:
            pass  # read meanwhile


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def pid_alive(pid: int) -> bool:
    if os.name == "nt":
        # os.kill(pid, 0) terminates the process on Windows, so ask the kernel instead.
        import ctypes
        kernel32 = ctypes.windll.kernel32
        handle = kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            return False
        code = ctypes.c_ulong()
        kernel32.GetExitCodeProcess(handle, ctypes.byref(code))
        kernel32.CloseHandle(handle)
        return code.value == 259  # STILL_ACTIVE
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def live_waiter(role: str) -> int | None:
    """Checks the pid too, since a killed waiter never marks its heartbeat ended."""
    beat = read_json(box() / role / HEARTBEAT)
    if beat.get("ended") or time.time() - beat.get("time", 0) >= HEARTBEAT_STALE_S:
        return None
    pid = beat.get("pid")
    return pid if isinstance(pid, int) and pid_alive(pid) else None


def cmd_wait(ns: argparse.Namespace) -> None:
    refuse_remote(ns.role)
    beat = inbox(ns.role) / HEARTBEAT
    if pid := live_waiter(ns.role):
        print(f"mail: a waiter for {ns.role} is already running (pid {pid}); it wakes you, don't start another")
        return
    owner = int(os.environ["CLAUDE_PID"]) if os.environ.get("CLAUDE_PID", "").isdigit() else None
    # With its session known, the waiter ends with that session; a timeout would only wake an idle one for nothing.
    timeout = ns.timeout if ns.timeout is not None else (None if owner else 43200.0)
    deadline = time.time() + timeout if timeout is not None else None
    try:
        while deadline is None or time.time() < deadline:
            if owner and not pid_alive(owner):
                print(f"mail: the session this waiter served (pid {owner}) is gone; leaving the mail unread")
                sys.exit(1)
            beat.write_text(json.dumps({"pid": os.getpid(), "time": time.time()}), encoding="utf-8")
            if messages := unread(ns.role):
                if ns.read:
                    read_all(ns.role)
                else:
                    print(f"mail: {len(messages)} unread for {ns.role}, run: zerg mail read {ns.role}")
                return
            time.sleep(POLL_S)
    finally:
        # Kept, marked ended, so `status` can tell how long the role has had no waiter.
        beat.write_text(json.dumps({"pid": os.getpid(), "time": time.time(), "ended": True}), encoding="utf-8")
    print(f"mail: no mail for {ns.role} after {timeout:.0f}s, restart the waiter")
    sys.exit(1)


def minutes(seconds: float) -> str:
    return f"{seconds / 60:.0f} min"


def title(role: str) -> str:
    try:
        with open(main_checkout() / ".zerg" / "state" / f"{role}.md", encoding="utf-8-sig") as f:
            first = f.readline()
    except OSError:
        return "-"
    m = re.match(r"# Session: (.+?) \(mail role ", first)
    return m[1] if m else "-"


def arrived(path: Path) -> float | None:
    """None when a reader moved the message since the folder was listed."""
    try:
        return path.stat().st_mtime
    except FileNotFoundError:
        return None


def cmd_status(_: argparse.Namespace) -> None:
    last: dict[str, float] = {}
    for path in box().rglob("*.md"):
        if (m := re.match(r"\d{8}-\d{6}-\d{3}-([a-z0-9_-]+)-\d+\.md$", path.name)) and (t := arrived(path)):
            last[m[1]] = max(last.get(m[1], 0.0), t)
    now = time.time()
    for role in roles():
        beat = read_json(box() / role / HEARTBEAT)
        gone = now - beat.get("time", 0)
        listening = live_waiter(role)
        if listening:
            state = "listening"
        elif not beat:
            state = "never started"
        elif gone < GRACE_S:
            state = "between reads"
        else:
            state = f"gone {minutes(gone)}"
        mail = [t for t in map(arrived, unread(role)) if t is not None]
        oldest = now - min(mail) if mail else 0.0
        check = not listening and oldest > CHECK_AFTER_S
        sent = f"{minutes(now - last[role])} ago" if role in last else "never"
        print(f"{role:<14} {title(role):<24} {state:<16} unread {len(mail):<2}"
              f"{f' (oldest {minutes(oldest)})' if mail else '':<16} last sent {sent:<12}{'  CHECK' if check else ''}")


def main() -> None:
    # Git Bash on Windows hands Python a cp1252 console, mail bodies are UTF-8.
    for stream in (sys.stdout, sys.stdin):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("send")
    p.add_argument("--from", dest="sender", metavar="FROM", required=True)
    p.add_argument("--to", metavar="TO", required=True)
    p.add_argument("subject")
    p.add_argument("--body-file")
    # A body here is refused with a hint rather than argparse's own error.
    p.add_argument("body", nargs="*", default=[], help=argparse.SUPPRESS)
    p.set_defaults(fn=cmd_send)
    for name, fn in (("read", cmd_read), ("peek", cmd_peek)):
        p = sub.add_parser(name)
        p.add_argument("role")
        p.set_defaults(fn=fn)
    p = sub.add_parser("wait")
    p.add_argument("role")
    p.add_argument("--read", action="store_true", help="print the mail and mark it read before exiting")
    p.add_argument("--timeout", type=float)
    p.set_defaults(fn=cmd_wait)
    p = sub.add_parser("last")
    p.add_argument("role")
    p.add_argument("n", nargs="?", type=int, default=1)
    p.set_defaults(fn=cmd_last)
    sub.add_parser("roles").set_defaults(fn=lambda _: print("\n".join(roles())))
    sub.add_parser("status").set_defaults(fn=cmd_status)
    ns = parser.parse_args()
    ns.fn(ns)


if __name__ == "__main__":
    main()
