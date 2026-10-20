#!/usr/bin/env python3
"""CodeBuddy OAuth WINDOW on CI (runs inside the GitHub Actions job).

v2 fixes after run 39481111876 (WINDOW_RESULT=expired, URL never captured):
  - TRANSCRIPT ECHO: the pty TUI transcript is echoed into the run log
    (ANSI-stripped tail every ~12s) so a failed capture is debuggable.
  - CONTENT-AWARE pacing: keystrokes fire on transcript markers, not blind
    sleeps; every marker miss is logged.
  - URL capture from BOTH the browser shim AND the raw transcript text.
  - Artifact written NON-hidden (cb-creds-sealed.bin) — v4 upload skips
    dotfiles unless include-hidden-files.
"""
import base64, os, pty, re, select, fcntl, termios, struct, signal
import subprocess, sys, tarfile, time, io, glob
from pathlib import Path

DUR = int(os.environ.get("CB_WINDOW_DUR", "780"))
URL_WAIT = int(os.environ.get("CB_URL_WAIT", "150"))
TG_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
TG_CHAT = os.environ.get("TELEGRAM_OWNER_ID", "")
PUBKEY_B64 = os.environ.get("CB_SEAL_PUBKEY", "")
HOME = Path.home()
CB = HOME / ".codebuddy"
SHIM = Path("/tmp/cb-browser-url.txt")
OUT_LOG = Path("/tmp/cb-ci-tui.log")
URL_RE = re.compile(rb"https://www\.codebuddy\.ai/login\?[^\s\x1b\x07\"]+")
NOISE = ("plugins", "logs", "traces", "shell-snapshots", "projects", "diagnostics")

ANSI = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\x1b[=>]")

for p in ("/tmp/fakebrowser", "/tmp/xdg-open"):
    p = Path(p)
    p.write_text('#!/bin/bash\necho "$@" >> /tmp/cb-browser-url.txt\n')
    p.chmod(0o755)

env = dict(os.environ)
env.update(TERM="xterm-256color", BROWSER="/tmp/fakebrowser",
           PATH="/tmp:" + env["PATH"])
env.pop("CI", None)
SHIM.write_text("")

pid, fd = pty.fork()
if pid == 0:
    os.chdir("/tmp")
    os.execvpe("codebuddy", ["codebuddy", "--permission-mode", "dontAsk"], env)

fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 45, 150, 0, 0))
log = OUT_LOG.open("wb")
start = time.time()
step = 0
url_sent = False
transcript = bytearray()
last_echo = 0.0


def clean_tail(n=900):
    txt = ANSI.sub(b"", bytes(transcript[-2400:])).decode("utf-8", "replace")
    txt = re.sub(r"\s+", " ", txt).strip()
    return txt[-n:]


def echo(force=False):
    global last_echo
    if force or time.time() - last_echo >= 12:
        last_echo = time.time()
        print(f"TUI[{int(elapsed())}s]: {clean_tail()}", flush=True)


def dump_full(tag):
    """Print the WHOLE cleaned transcript (v3 post-mortem aid: the device
    URL can scroll past before any tail-only echo) — capped at 6000 chars
    of cleaned text, oldest first."""
    txt = ANSI.sub(b"", bytes(transcript)).decode("utf-8", "replace")
    txt = re.sub(r"[ \t]+", " ", txt)
    lines = [l.strip() for l in txt.splitlines() if l.strip()]
    seen, out = set(), []
    for l in lines:  # spinner frames spam — dedupe while keeping order
        key = l[:60]
        if key in seen and "Waiting" in l:
            continue
        seen.add(key)
        out.append(l)
    print(f"TUI_FULL[{tag}]: " + " | ".join(out)[:6000], flush=True)


def elapsed():
    return time.time() - start


URL_RE = re.compile(rb"https?://[^\s\"'<>]{8,}", re.I)
# hosts that are NOT the login URL (noise from the CLI's own traffic hints)
URL_NOISE = ("qoder.com", "github.com", "api.", "telegram.org", "npmjs", "registry")


def find_url():
    """Scan the WHOLE transcript for candidate auth URLs. Device-flow URLs
    do not always contain 'login' (v2 missed exactly that — run
    39485306549: the CLI sat in 'Waiting for auth' with its URL already
    scrolled past). Any non-noise https URL is a candidate."""
    for m in URL_RE.finditer(bytes(transcript)):
        u = m.group(0).decode(errors="replace")
        if not any(n in u.lower() for n in URL_NOISE):
            return u
    if SHIM.exists():
        u = SHIM.read_text().strip()
        if u and u.startswith("http"):
            return u
    return ""


def snapshot():
    out = {}
    for f in CB.rglob("*"):
        rel = str(f.relative_to(CB))
        if rel.split("/")[0] in NOISE or not f.is_file():
            continue
        try:
            out[rel] = (f.stat().st_mtime, f.stat().st_size)
        except OSError:
            pass
    return out


def cred_shaped(path: Path) -> bool:
    try:
        head = path.read_bytes()[:20000]
    except OSError:
        return False
    return bool(re.search(rb"(access|refresh)[_]?token|api[_]?key|Bearer [A-Za-z0-9]", head, re.I))


def tg_send(text: str) -> None:
    if not (TG_TOKEN and TG_CHAT):
        print("TG_PUSH: skipped (secrets unavailable)", flush=True)
        return
    import urllib.request, urllib.parse
    try:
        req = urllib.request.Request(
            f"https://api.telegram.org/bot{TG_TOKEN}/sendMessage",
            data=urllib.parse.urlencode({"chat_id": TG_CHAT, "text": text}).encode())
        with urllib.request.urlopen(req, timeout=20) as r:
            body = r.read().decode()[:120]
            print(f"TG_PUSH: HTTP {r.status} {body}", flush=True)
    except Exception as e:
        print(f"TG_PUSH: err {e}", flush=True)


def deliver(url: str) -> None:
    global url_sent
    if url_sent:
        return
    url_sent = True
    tg_send("FROM: team-lead (glm-5.3-flash, Agent Team)\nTO: @owner\n\n"
            "CODEBUDDY AUTH WINDOW — OPEN NOW (~13 minutes).\n\n"
            "Click and finish sign-in inside the window; the CLI is polling "
            "live. If your browser ends at a failed 127.0.0.1 page, that is "
            "fine — copy the FULL address-bar URL to #hq. The moment you "
            "approve, the built-in models go live on the roster.\n\n" + url)
    print(f"URL_READY: {url[:100]}", flush=True)


# ---------------- phase 1: drive to the login URL ----------------
while elapsed() < URL_WAIT and not url_sent:
    r, _, _ = select.select([fd], [], [], 1.0)
    if r:
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        transcript.extend(data)
        log.write(data)
        log.flush()
        u = find_url()
        if u:
            dump_full("url-found")
            deliver(u)
            break
    t = elapsed()
    view = clean_tail(400).lower()

    def marker(*words):
        return any(w in view for w in words)

    if step == 0 and (marker("sign in", "login", "auth", "get started", "welcome")
                      or t > 12):
        os.write(fd, b"\r"); step = 1
        print(f"STEP1: Enter @ {t:.0f}s", flush=True)
    elif step == 1 and (marker(">", "command", "input", "search") or t > 18):
        os.write(fd, b"/login\r"); step = 2
        print(f"STEP2: /login @ {t:.0f}s", flush=True)
    elif step == 2 and t > 24:
        # region menu: pick the Intl/overseas entry (arrow-down then Enter,
        # retried once — menu order is not guaranteed)
        os.write(fd, b"\x1b[B")
        print(f"STEP3: arrow-down @ {t:.0f}s", flush=True)
        step = 3
    elif step == 3 and t > 27:
        os.write(fd, b"\r")
        print(f"STEP4: Enter @ {t:.0f}s", flush=True)
        step = 4
    elif step == 4 and t > 33:
        # second chance: some builds need another Enter on the region list
        os.write(fd, b"\r")
        print(f"STEP5: extra Enter @ {t:.0f}s", flush=True)
        step = 5
    echo()

if not url_sent:
    print("URL_READY: never — dumping final transcript for post-mortem", flush=True)
    dump_full("final")
    print("TUI_FINAL: " + clean_tail(1800), flush=True)

# ---------------- phase 2: landing watch ----------------
BASE = snapshot()
landed = None
end = start + DUR
print(f"LANDING_WATCH: baseline {len(BASE)} files", flush=True)
while time.time() < end:
    if not os.path.exists(f"/proc/{pid}"):
        print("CLI exited early", flush=True)
        break
    time.sleep(10)
    # keep draining pty so the CLI never blocks on a full buffer
    while True:
        rr, _, _ = select.select([fd], [], [], 0)
        if not rr:
            break
        try:
            data = os.read(fd, 65536)
        except OSError:
            data = b""
        if not data:
            break
        transcript.extend(data)
        log.write(data)
        log.flush()
        u = find_url()
        if u:
            dump_full("url-found-phase2")
            deliver(u)
    now = snapshot()
    new = {k: v for k, v in now.items() if k not in BASE}
    changed = {k: v for k, v in now.items() if k in BASE and BASE[k] != v}
    hits = [k for k in list(new) + list(changed) if cred_shaped(CB / k)]
    if hits:
        landed = hits
        print(f"AUTH_LANDED: {len(hits)} credential-shaped file(s): {hits[:4]}", flush=True)
        break

# ---------------- phase 3: collect + seal ----------------
try:
    os.kill(pid, signal.SIGKILL)
except Exception:
    pass

buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w:gz") as tf:
    for f in CB.rglob("*"):
        rel = str(f.relative_to(CB))
        if rel.split("/")[0] in NOISE or not f.is_file():
            continue
        tf.add(str(f), arcname=rel)
raw = buf.getvalue()
print(f"COLLECTED: {len(raw)} bytes of ~/.codebuddy tree", flush=True)

if PUBKEY_B64:
    from nacl.public import PublicKey, SealedBox
    sealed = SealedBox(PublicKey(base64.b64decode(PUBKEY_B64))).encrypt(raw)
    Path("cb-creds-sealed.bin").write_bytes(sealed)
    print(f"SEALED: {len(sealed)} bytes -> cb-creds-sealed.bin", flush=True)
else:
    print("SEAL: no pubkey — skipping artifact (nothing uploaded)", flush=True)

print("WINDOW_RESULT=" + (f"landed files={len(landed or [])}" if landed else
                          ("url-sent-awaiting-landing" if url_sent else "expired")),
      flush=True)
print(f"TRANSCRIPT_BYTES: {len(transcript)}", flush=True)
