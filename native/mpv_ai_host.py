#!/usr/bin/env python3
"""Native messaging host for the "mpv AI chain" browser extension.

Chrome starts this process, writes one length-prefixed JSON request to stdin,
reads one length-prefixed JSON reply from stdout, and closes the pipe. The
process is short-lived by design: no port, no daemon, no state between calls,
so a crash can never wedge the browser.

Requests
--------
    {"cmd": "ping"}
        Report what the host resolved on PATH and where it logs. Lets the
        options page distinguish "host not installed" from "mpv not installed".

    {"cmd": "play", "url": "https://...", "profile": "ai"|"nr"|"plain",
     "fullscreen": true, "args": "--start=10", "format": "bv*+ba/b",
     "title": "..."}
        Start the matching mpv wrapper detached and return its pid. The URL is
        handed to mpv as-is; for site URLs mpv's own ytdl hook runs yt-dlp.

Security
--------
The only thing this host can do is start one of three fixed executables with
a validated http(s) URL. There is no shell, no command interpolation, and no
way for the caller to choose the program: the profile maps to a name, the name
is resolved on PATH, and the argument list is passed to execve(2) directly.

Protocol errors, refused URLs and spawn failures are logged to
$XDG_STATE_HOME/mpv-ai-extension/launch.log and reported as {"ok": false}.
Nothing is ever written to stdout except the framed reply.
"""

from __future__ import annotations

import json
import os
import shlex
import shutil
import struct
import subprocess
import sys
import time
from pathlib import Path

MAX_MESSAGE = 1 << 20  # 1 MiB; a request is a few hundred bytes
MAX_URL = 8192
LOG_MAX_BYTES = 1 << 20

HOST_NAME = "com.hyperramzey.mpv_ai"
PROFILES = {"ai": "mpv-ai", "nr": "mpv-nr", "plain": "mpv"}
TOOLS = ("mpv-ai", "mpv-nr", "mpv", "yt-dlp")

HOME = Path.home()
STATE_DIR = Path(os.environ.get("XDG_STATE_HOME") or HOME / ".local" / "state")
LOG_PATH = STATE_DIR / "mpv-ai-extension" / "launch.log"


class ProtocolError(Exception):
    """The byte stream from the browser is not a valid native message."""


def build_path() -> str:
    """PATH for the child, with the user's own bin directories first.

    A browser started from a desktop launcher often does not inherit the login
    shell's PATH, so ~/.local/bin (where mpv-ai, mpv-nr and yt-dlp live) is
    prepended explicitly instead of trusted to be present.
    """
    parts = [
        str(HOME / ".local" / "bin"),
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/local/sbin",
        "/usr/sbin",
        "/sbin",
    ]
    for entry in os.environ.get("PATH", "").split(os.pathsep):
        if entry and entry not in parts:
            parts.append(entry)
    return os.pathsep.join(parts)


PATH = build_path()


def log(message: str) -> None:
    """Append one line to the launch log; never raise into the protocol."""
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        if LOG_PATH.exists() and LOG_PATH.stat().st_size > LOG_MAX_BYTES:
            LOG_PATH.replace(LOG_PATH.with_name(LOG_PATH.name + ".1"))
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        with LOG_PATH.open("a", encoding="utf-8") as handle:
            handle.write(f"{stamp} {message}\n")
    except OSError:
        pass


def check_url(raw: object) -> tuple[bool, str]:
    """Accept only absolute http(s) URLs with a host and no control bytes."""
    if not isinstance(raw, str):
        return False, "url must be a string"
    url = raw.strip()
    if not url:
        return False, "url is empty"
    if len(url) > MAX_URL:
        return False, f"url is longer than {MAX_URL} bytes"
    if any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in url):
        return False, "url contains control characters"
    scheme, sep, rest = url.partition("://")
    if not sep:
        return False, "url is not absolute (missing scheme://)"
    if scheme.lower() not in ("http", "https"):
        return False, f"unsupported scheme: {scheme}"
    host = rest.split("/", 1)[0].split("?", 1)[0].split("#", 1)[0]
    if not host:
        return False, "url has no host"
    return True, url


def check_format(raw: object) -> tuple[bool, str]:
    """yt-dlp format selectors contain no whitespace; reject anything that does."""
    if raw is None:
        return True, ""
    if not isinstance(raw, str):
        return False, "format must be a string"
    value = raw.strip()
    if not value:
        return True, ""
    if len(value) > 256:
        return False, "format is too long"
    if any(ch.isspace() or ord(ch) < 0x20 for ch in value):
        return False, "format contains whitespace"
    return True, value


def check_args(raw: object) -> tuple[bool, list[str]]:
    """Split the user's extra arguments with shell quoting rules, without a shell."""
    if raw is None:
        return True, []
    if not isinstance(raw, str):
        return False, "args must be a string"
    text = raw.strip()
    if not text:
        return True, []
    try:
        parts = shlex.split(text, posix=True)
    except ValueError as exc:
        return False, f"cannot parse extra arguments: {exc}"
    if len(parts) > 64:
        return False, "too many extra arguments"
    return True, parts


def resolve(profile: str) -> tuple[str | None, str]:
    """Map a profile name to an executable on PATH."""
    name = PROFILES[profile]
    found = shutil.which(name, path=PATH)
    if not found:
        return None, (
            f"{name} was not found on PATH. Expected it in ~/.local/bin "
            f"(see the README's install section). PATH used: {PATH}"
        )
    return found, ""


def handle_ping() -> dict:
    tools = {name: shutil.which(name, path=PATH) or "" for name in TOOLS}
    return {
        "ok": True,
        "host": os.path.abspath(__file__),
        "python": f"{sys.version.split()[0]} ({sys.executable})",
        "path": PATH,
        "tools": tools,
        "log": str(LOG_PATH),
    }


def handle_play(msg: dict) -> dict:
    profile = msg.get("profile", "ai")
    if profile not in PROFILES:
        return {"ok": False, "error": f"unknown profile: {profile!r}"}

    ok, url_or_error = check_url(msg.get("url"))
    if not ok:
        log(f"refused url: {url_or_error}")
        return {"ok": False, "error": url_or_error}
    url = url_or_error

    ok, fmt_or_error = check_format(msg.get("format"))
    if not ok:
        return {"ok": False, "error": fmt_or_error}
    fmt = fmt_or_error

    ok, args_or_error = check_args(msg.get("args"))
    if not ok:
        return {"ok": False, "error": args_or_error}
    extra = args_or_error

    exe, error = resolve(profile)
    if not exe:
        log(f"spawn failed: {error}")
        return {"ok": False, "error": error}

    argv = [exe]
    if fmt:
        argv.append(f"--ytdl-format={fmt}")
    if msg.get("fullscreen"):
        argv.append("--fullscreen")
    argv.extend(extra)
    argv.append(url)

    try:
        child = subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            cwd=str(HOME),
            env={**os.environ, "PATH": PATH, "HOME": str(HOME)},
            close_fds=True,
            # Own session: mpv must survive the host process exiting, and the
            # browser closing the pipe must not deliver SIGHUP to it.
            start_new_session=True,
        )
    except OSError as exc:
        log(f"spawn failed: {exc}: {argv!r}")
        return {"ok": False, "error": f"cannot start {exe}: {exc}"}

    log(f"started pid {child.pid} profile={profile} argv={argv!r}")
    return {
        "ok": True,
        "pid": child.pid,
        "argv": argv,
        "exe": exe,
        "title": msg.get("title") or "",
    }


def handle(msg: object) -> dict:
    if not isinstance(msg, dict):
        return {"ok": False, "error": "request must be a JSON object"}
    cmd = msg.get("cmd")
    if cmd == "ping":
        return handle_ping()
    if cmd == "play":
        return handle_play(msg)
    return {"ok": False, "error": f"unknown command: {cmd!r}"}


def read_exact(stream, size: int) -> bytes | None:
    chunks = bytearray()
    while len(chunks) < size:
        chunk = stream.read(size - len(chunks))
        if not chunk:
            return None
        chunks.extend(chunk)
    return bytes(chunks)


def read_message(stream) -> object | None:
    header = read_exact(stream, 4)
    if header is None:
        return None
    (length,) = struct.unpack("<I", header)
    if length == 0:
        raise ProtocolError("empty message")
    if length > MAX_MESSAGE:
        raise ProtocolError(f"message of {length} bytes exceeds the limit")
    body = read_exact(stream, length)
    if body is None:
        raise ProtocolError("truncated message")
    try:
        return json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProtocolError(f"invalid JSON: {exc}") from exc


def write_message(stream, obj: dict) -> None:
    payload = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    stream.write(struct.pack("<I", len(payload)) + payload)
    stream.flush()


def main() -> int:
    stdin = sys.stdin.buffer
    stdout = sys.stdout.buffer
    if len(sys.argv) > 1:
        log(f"host started by {sys.argv[1]}")
    while True:
        try:
            msg = read_message(stdin)
        except ProtocolError as exc:
            log(f"protocol error: {exc}")
            write_message(stdout, {"ok": False, "error": str(exc)})
            return 1
        if msg is None:
            return 0
        reply = handle(msg)
        write_message(stdout, reply)
        # Chrome sends one message per process; loop anyway so a future
        # long-lived port reuses the same code path.


if __name__ == "__main__":
    sys.exit(main())
