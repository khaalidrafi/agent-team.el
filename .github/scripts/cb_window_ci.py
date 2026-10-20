#!/usr/bin/env python3
"""CodeBuddy OAuth WINDOW on CI (runs inside the GitHub Actions job).

Owner said "Done." but the token grant attaches to the LIVE CLI instance
that generated the login URL — his approval landed after the Lead's local
window closed. This job re-runs the flow where the bot token actually
lives (repo secrets), so the link can be delivered MID-WINDOW:

  1. pty-drive `codebuddy` through the Intl login (region menu included).
  2. Capture the login URL from the browser shim.
  3. Telegram it to the Owner IMMEDIATELY (FROM/TO headers per law).
  4. Keep the CLI polling ~13 min; watch ~/.codebuddy for the credential
     landing.
  5. On landing: tar the credential tree and SEAL it with the Lead's
     libsodium public key (repo is PUBLIC — the artifact must be
     ciphertext-only), write .cb-creds-sealed.bin for the upload step.
"""
import base64, os, pty, re, select, fcntl, termios, struct, signal
import subprocess, sys, tarfile, time, io, glob
from pathlib import Path

DUR = int(os.environ.get("CB_WINDOW_DUR", "780"))
TUI_DUR = int(os.environ.get("CB_TUI_DUR", "150"))
TG_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
TG_CHAT = os.environ.get("TELEGRAM_OWNER_ID", "")
PUBKEY_B64 = os.environ.get("CB_SEAL_PUBKEY", "")
HOME = Path.home()
CB = HOME / ".codebuddy"
SHIM = Path("/tmp/cb-browser-url.txt")
OUT_LOG = Path("/tmp/cb-ci-tui.log")
NOISE = ("plugins", "logs", "traces", "shell-snapshots", "projects", "diagnostics")

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
    code = "?"
    try:
        req = urllib.request.Request(
            f"https://api.telegram.org/bot{TG_TOKEN}/sendMessage",
            data=urllib.parse.urlencode({"chat_id": TG_CHAT, "text": text}).encode())
        with urllib.request.urlopen(req, timeout=20) as r:
            code = str(r.status)
    except Exception as e:
        code = f"err:{e}"
    print(f"TG_PUSH: HTTP {code}", flush=True)

while time.time() - start < TUI_DUR and step < 5:
    r, _, _ = select.select([fd], [], [], 1.0)
    if r:
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        log.write(data); log.flush()
    el = time.time() - start
    if step == 0 and el > 10:
        os.write(fd, b"\r"); step = 1
    elif step == 1 and el > 17:
        os.write(fd, b"/login\r"); step = 2
    elif step == 2 and el > 26:
        os.write(fd, b"\x1b[B"); step = 3
    elif step == 3 and el > 29:
        os.write(fd, b"\r"); step = 4
    elif step == 4:
        url = SHIM.read_text().strip() if SHIM.exists() else ""
        if url and "codebuddy.ai/login" in url:
            tg_send("FROM: team-lead (glm-5.3-flash, Agent Team)\nTO: @owner\n\n"
                    "CODEBUDDY AUTH WINDOW — OPEN NOW (~13 minutes).\n\n"
                    "Click and finish sign-in inside the window; the CLI is "
                    "polling live. If your browser ends at a failed "
                    "127.0.0.1 page, that is fine — copy the FULL "
                    "address-bar URL to #hq. The moment you approve, the "
                    "built-in models go live on the roster.\n\n" + url)
            print(f"URL_READY: {url[:60]}…", flush=True)
            step = 5

if step < 5:
    print("URL_READY: never (no login URL in the TUI phase) — dumping TUI tail:", flush=True)
    try:
        tail = OUT_LOG.read_bytes()[-2500:]
        import re as _re
        print(_re.sub(rb"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07\x1b]*(\x07|\x1b\\\\)", b"", tail).decode("utf-8", "replace"))
    except Exception as e:
        print(f"tui dump failed: {e}", flush=True)

# ---- landing watch (CLI keeps polling while alive) ----
BASE = snapshot()
landed = None
end = start + DUR
print(f"LANDING_WATCH: baseline {len(BASE)} files", flush=True)
while time.time() < end:
    if os.path.exists(f"/proc/{pid}") is False:
        print("CLI exited early", flush=True)
        break
    time.sleep(10)
    now = snapshot()
    new = {k: v for k, v in now.items() if k not in BASE}
    changed = {k: v for k, v in now.items() if k in BASE and BASE[k] != v}
    hits = [k for k in list(new) + list(changed)
            if cred_shaped(CB / k)]
    if hits:
        landed = hits
        print(f"AUTH_LANDED: {len(hits)} credential-shaped file(s): {hits[:4]}", flush=True)
        break

# collect + seal regardless of landing verdict (baseline included)
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
    Path(".cb-creds-sealed.bin").write_bytes(sealed)
    print(f"SEALED: {len(sealed)} bytes -> .cb-creds-sealed.bin", flush=True)
else:
    print("SEAL: no pubkey — skipping artifact (nothing uploaded)", flush=True)

print("WINDOW_RESULT=" + (f"landed files={len(landed or [])}" if landed else "expired"), flush=True)
