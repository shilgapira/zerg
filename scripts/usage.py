"""The Claude plan's usage, so the boss can pause the project before the limit stops every session.

    usage.py              5-hour and weekly use, e.g. "5h 44% (resets 16:20, in 2h 37m), week 60% (resets Sun 10:59,
                          in 4d 2h)", in local time
    usage.py --json       the endpoint's full answer
    usage.py --stop-at 90 exit 2 when either figure is at or over 90%; without it, in a zerg project, the stop is
                          "usage_stop" in etc/zerg/config.json (default 90)

macOS only: it reads Claude Code's OAuth token from the Keychain (never printing it) and asks the usage endpoint that
Claude Code's /usage uses. That endpoint is undocumented, so every failure says what broke.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import http.client
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import NoReturn

URL = "https://api.anthropic.com/api/oauth/usage"
KEYCHAIN_SERVICE = "Claude Code-credentials"


def fail(why: str) -> NoReturn:
    sys.exit(f"usage: {why}")


def token() -> str:
    if sys.platform != "darwin":
        fail("only macOS is supported (the token is read from the Keychain); check /usage in Claude Code instead")
    # with CLAUDE_CONFIG_DIR set, Claude Code keeps the token under a name suffixed with a hash of that folder
    services = [KEYCHAIN_SERVICE]
    if config_dir := os.environ.get("CLAUDE_CONFIG_DIR"):
        services.insert(0, f"{KEYCHAIN_SERVICE}-{hashlib.sha256(config_dir.encode()).hexdigest()[:8]}")
    for service in services:
        try:
            raw = subprocess.run(["security", "find-generic-password", "-s", service, "-w"],
                                 capture_output=True, text=True, timeout=20)
        except (OSError, subprocess.TimeoutExpired) as e:
            fail(f"could not run `security` to read the Keychain: {e}")
        if not raw.returncode:
            break
    else:
        fail(f"no readable Keychain entry {' or '.join(map(repr, services))} (is Claude Code logged in with a "
             f"claude.ai account? security said: {raw.stderr.strip() or raw.returncode})")
    try:
        return json.loads(raw.stdout)["claudeAiOauth"]["accessToken"]
    except (ValueError, KeyError, TypeError):
        fail("the Keychain entry no longer has claudeAiOauth.accessToken: Claude Code changed how it stores the token")


def fetch() -> dict:
    request = urllib.request.Request(URL, headers={"anthropic-beta": "oauth-2025-04-20"})
    # never forwarded if the endpoint redirects elsewhere
    request.add_unredirected_header("Authorization", f"Bearer {token()}")
    try:
        # no proxy, whatever the environment says: the token goes straight to api.anthropic.com
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(request, timeout=20) as response:
            return json.load(response)
    except urllib.error.HTTPError as e:
        hint = {401: "the token expired or was revoked: use Claude Code once so it refreshes",
                403: "the account may not expose usage this way", 404: "the endpoint moved: it is undocumented"}
        fail(f"HTTP {e.code} {e.reason} from {URL}; {hint.get(e.code, 'unexpected answer')}")
    except urllib.error.URLError as e:
        fail(f"could not reach {URL}: {e.reason}")
    except (http.client.HTTPException, OSError) as e:  # OSError: on Python 3.9 a read timeout isn't a TimeoutError
        fail(f"the connection to {URL} failed: {type(e).__name__} {e}")
    except ValueError:
        fail(f"{URL} answered with something that is not JSON: the endpoint changed")


def configured_stop() -> float | None:
    proc = subprocess.run(["git", "rev-parse", "--git-common-dir"], capture_output=True, text=True,
                          encoding="utf-8", errors="replace")
    if proc.returncode:
        return None
    config = Path.cwd() / proc.stdout.strip() / ".." / "etc" / "zerg" / "config.json"
    try:
        return float(json.loads(config.read_text(encoding="utf-8")).get("usage_stop", 90))
    except (OSError, ValueError, AttributeError, TypeError):
        return None


def when(stamp: str) -> str:
    """Local time plus the time left, so nobody misreads a UTC time as local."""
    try:
        at = datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00")).astimezone()
    except ValueError:
        return stamp
    left = max(0, int((at - datetime.datetime.now().astimezone()).total_seconds()) // 60)
    days, hours, minutes = left // 1440, left // 60 % 24, left % 60
    span = f"{days}d {hours}h" if days else f"{hours}h {minutes}m" if hours else f"{minutes}m"
    day = "" if at.date() == datetime.date.today() else at.strftime("%a ")
    return f"{day}{at.strftime('%H:%M')}, in {span}"


def figure(data: dict, key: str) -> tuple[float, str] | None:
    """A limit's use and reset time; None when the plan has no such limit."""
    if isinstance(data, dict) and key in data and data[key] is None:
        return None
    try:
        part = data[key]
        return float(part["utilization"]), when(str(part["resets_at"]))
    except (KeyError, TypeError, ValueError):
        fail(f"the answer has no {key}.utilization / {key}.resets_at any more: the endpoint changed "
             f"(keys: {', '.join(sorted(data)) if isinstance(data, dict) else type(data).__name__})")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--stop-at", type=float, help="exit 2 when the 5-hour or weekly figure reaches this percent")
    ns = parser.parse_args()
    if ns.stop_at is None:
        ns.stop_at = configured_stop()
    data = fetch()
    if ns.json:
        print(json.dumps(data, indent=1))
        return
    parts, used = [], []
    for label, key in (("5h", "five_hour"), ("week", "seven_day")):
        if (got := figure(data, key)) is None:
            parts.append(f"{label}: no limit")
        else:
            parts.append(f"{label} {got[0]:.0f}% (resets {got[1]})")
            used.append(got[0])
    print(", ".join(parts))
    if ns.stop_at is not None and used and max(used) >= ns.stop_at:
        print(f"usage: at or over the {ns.stop_at:g}% stop: pause the project (references/boss.md, Pause and resume)")
        sys.exit(2)


if __name__ == "__main__":
    main()
