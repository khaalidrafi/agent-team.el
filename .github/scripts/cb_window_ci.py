#!/usr/bin/env python3
"""CodeBuddy OAuth WINDOW on CI (runs inside the GitHub Actions job).

v4 (runs 39481111876 / 39483540900 / 39485306549 / 39486356977 post-mortems):
  - v2: blind timed keystrokes + URL regex requiring /login -> missed the
    device-flow URL entirely.
  - v3: transcript echo WORKED (root cause visible) but the first screen is
    the FOLDER-TRUST dialog, keystrokes fired before it, and the URL
    capture matched the dialog's "Learn more" docs link (false positive).
  - v4: FULLY MARKER-DRIVEN — answer the trust dialog when it appears,
    handle the region menu when it appears, watch for ANY real auth URL
    (docs links are noise now), and dump the full de-spammed transcript
    every 30s so the URL is readable from the run log even if the
    automated capture misses it.
"""
import base64, os, pty, re, select, fcntl, termios, struct, signal
import subprocess, sys, tarfile, time, io, glob
from pathlib import Path

DUR = int(os.environ.get("CB_WINDOW_DUR", "780"))
URL_WAIT = int(os.environ.get("CB_URL_WAIT", "240"))
TG_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
TG_CHAT = os.environ.get("TELEGRAM_OWNER_ID", "")
PUBKEY_B64 = os.environ.get("CB_SEAL_PUBKEY", "")
HOME = Path.home()
CB = HOME / ".codebuddy"
SHIM = Path("/tmp/cb-browser-url.txt")
OUT_LOG = Path("/tmp/cb-ci-tui.log")
NOISE = ("plugins", "logs", "traces", "shell-snapshots", "projects", "diagnostics")

ANSI = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\x1b[=>]")
URL_RE = re.compile(rb"https?://[^\s\"'<>]{8,}", re.I)
# a candidate auth URL names codebuddy/tencent and is NOT documentation
URL_NOISE = ("/docs", "docs.", "qoder.com", "github.com", "api.", "telegram.org",
             "npmjs", "registry", "codebuddy.ai/settings")


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
url_sent = False
transcript = bytearray()
last_echo = 0.0
last_dump = 0.0
last_send = 0.0
sent_trust = 0
sent_region = 0


def elapsed():
    return time.time() - start


def clean_text():
    txt = ANSI.sub(b"", bytes(transcript)).decode("utf-8", "replace")
    return re.sub(r"[ \t]+", " ", txt)


def clean_tail(n=900):
    txt = re.sub(r"\s+", " ", clean_text()).strip()
    return txt[-n:]


def echo():
    global last_echo
    if time.time() - last_echo >= 12:
        last_echo = time.time()
        print(f"TUI[{int(elapsed())}s]: {clean_tail()}", flush=True)


def dump_full(tag):
    txt = clean_text()
    lines = [l.strip() for l in txt.splitlines() if l.strip()]
    seen, out = set(), []
    for l in lines:
        key = l[:60]
        if key in seen and ("Waiting" in l or "Cancel" in l):
            continue
        seen.add(key)
        out.append(l)
    print(f"TUI_FULL[{tag}@{int(elapsed())}s]: " + " | ".join(out)[:6000], flush=True)


URL_RE_OK = re.compile(r"https?://[^\s\"'<>]*(codebuddy|tencent)[^\s\"'<>]*", re.I)


def find_url():
    for m in URL_RE_OK.finditer(clean_text()):
        u = m.group(0)
        if not any(n in u.lower() for n in URL_NOISE):
            return u
    if SHIM.exists():
        u = SHIM.read_text().strip()
        if u and u.startswith("http") and not any(n in u.lower() for n in URL_NOISE):
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
            "CODEBUDDY AUTH WINDOW — OPEN NOW (~13 minutes). THIS is the "
            "real auth link (the earlier message was a false capture of a "
            "docs link — disregard it).\n\n"
            "Open it and finish sign-in inside the window; the CLI is "
            "polling live. If your browser ends at a failed 127.0.0.1 "
            "page, that is fine — copy the FULL address-bar URL to #hq. "
            "The moment you approve, the built-in models go live.\n\n"
            + url)
    print(f"URL_READY: {url[:120]}", flush=True)


def maybe_send(data: bytes, what: str):
    """Throttle keystrokes: never two within 6s (a stray second Enter
    jumps menus — v2/v3 evidence)."""
    global last_send
    if time.time() - last_send < 6:
        return False
    os.write(fd, data)
    last_send = time.time()
    print(f"KEY: {what} @ {elapsed():.0f}s", flush=True)
    return True


# ---------------- phase 1: drive to the login URL (marker-driven) -------
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
    view = clean_tail(1500).lower()

    # 1. folder-trust dialog — ALWAYS first screen on a fresh tree
    if ("trust the files" in view or "trust folder" in view) and sent_trust < 3:
        if maybe_send(b"\r", "trust-dialog Enter"):
            sent_trust += 1
    # 2. region menu (numbered options mentioning Intl/overseas/global)
    elif any(w in view for w in ("international", "overseas", "region",
                                 "mainland")) and sent_region < 2:
        if maybe_send(b"\x1b[B", "region arrow-down"):
            sent_region += 1
    elif sent_region in (1,) and sent_trust >= 1:
        if maybe_send(b"\r", "region confirm Enter"):
            sent_region = 2
    # 3. periodic full transcript dumps — the URL cannot hide from these
    if time.time() - last_dump >= 30:
        last_dump = time.time()
        dump_full("probe")
    echo()

if not url_sent:
    print("URL_READY: never — dumping final transcript for post-mortem", flush=True)
    dump_full("final")

# ---------------- phase 2: landing watch (keep answering prompts) -------
BASE = snapshot()
landed = None
end = start + DUR
print(f"LANDING_WATCH: baseline {len(BASE)} files", flush=True)
while time.time() < end:
    if not os.path.exists(f"/proc/{pid}"):
        print("CLI exited early", flush=True)
        break
    time.sleep(10)
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
    # keep answering the trust dialog if a later prompt re-appears
    view = clean_tail(600).lower()
    if ("trust the files" in view or "trust folder" in view) and sent_trust < 5:
        maybe_send(b"\r", "phase2 trust-dialog Enter")
        sent_trust += 1
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
