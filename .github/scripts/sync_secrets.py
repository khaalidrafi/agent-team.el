#!/usr/bin/env python3
"""secret-sync — seal THIS repo's Actions secrets into target repos.

Run by .github/workflows/secret-sync.yml (workflow_dispatch).
Law: values live only in env; logs carry names + HTTP results, never values.
Standing order (Owner, 2026-10-24): every team repo always holds the FULL set.
"""
import base64
import json
import os
import sys
import urllib.request

from nacl import encoding, public

NAMES = (
    "AA_API_KEY", "BAI_API_KEY", "CLOUDFLARE_ACCOUNT_ID", "CLOUDFLARE_API_KEY",
    "CODEBUDDY_AUTH_TOKEN", "GEMINI_API_KEY", "GH_PAT", "GMI_API_KEY",
    "GOMODEL_MASTER_KEY", "GROQ_API_KEY", "MCODE_AUTH_JSON", "NAVYAI_API_KEY",
    "OLLAMA_CLOUD_API_KEY", "OPENCODE_API_KEY", "OPENROUTER_API_KEY",
    "QODER_PERSONAL_ACCESS_TOKEN", "TELEGRAM_BOT_TOKEN", "TELEGRAM_OWNER_ID",
    "TOKENHARBOR_API_KEY", "TYPESAFE_API_KEY", "XPLABS_API_KEY", "ZAI_API_KEY",
)

TARGETS = [t.strip() for t in (sys.argv[1] if len(sys.argv) > 1 else "").split(",") if t.strip()]
if not TARGETS:
    raise SystemExit("FATAL: no target repos given")
PAT = os.environ.get("GH_PAT")
if not PAT:
    raise SystemExit("FATAL: GH_PAT env missing")


def api(method, url, payload=None):
    req = urllib.request.Request(
        url, method=method,
        data=json.dumps(payload).encode() if payload is not None else None)
    req.add_header("Authorization", f"Bearer {PAT}")
    req.add_header("Accept", "application/vnd.github+json")
    if payload is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=30) as r:
        body = r.read().decode()
        return r.status, (json.loads(body) if body else None)


def main():
    values = {n: os.environ[n] for n in NAMES if os.environ.get(n)}
    skipped = [n for n in NAMES if not os.environ.get(n)]
    print(f"source secrets present: {len(values)}/{len(NAMES)}")
    if skipped:
        print(f"absent in source (skipped): {skipped}")
    if not values:
        raise SystemExit("FATAL: nothing to sync")
    grand = 0
    for repo in TARGETS:
        st, pk = api("GET", f"https://api.github.com/repos/{repo}/actions/secrets/public-key")
        box = public.SealedBox(public.PublicKey(pk["key"].encode(), encoding.Base64Encoder()))
        ok = fail = 0
        for name, val in values.items():
            enc = box.encrypt(val.encode())
            try:
                st, _ = api("PUT",
                            f"https://api.github.com/repos/{repo}/actions/secrets/{name}",
                            {"encrypted_value": base64.b64encode(enc).decode(),
                             "key_id": pk["key_id"]})
                ok += 1
            except Exception as e:
                fail += 1
                print(f"FAIL {name} -> {repo}: {e}")
        print(f"{repo}: sealed {ok}/{len(values)} (fail {fail})")
        grand += ok
    print(f"DONE: {grand} seals across {len(TARGETS)} repo(s); names-only above")


if __name__ == "__main__":
    main()
