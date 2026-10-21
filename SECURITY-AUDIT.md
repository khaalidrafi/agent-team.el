# Security audit — `khaalidrafi/agent-team.el`

- **Audited commit:** `774832e` (branch `ai/main`, single squashed commit)
- **Date:** 2026-10-21
- **Scope:** all tracked files (4 workflows, 3 scripts, 2 Emacs packages, harness
  image, Org team files), the Actions trust model, and the credential paths in
  the live `ci.yml` chain.
- **Method:** static review of every workflow/script line; dynamic verification
  of the secret guard, the tar/restore path and the committed history in
  throwaway repos; `gh api` checks on repo visibility/protection.
- **Not covered:** the value of any repo secret (no access), live run logs, the
  Lead's local box, and any history older than the squashed commit — the
  "162-commit audit" claimed in `AGENT-TEAM-MEMBERS.org:243` cannot be verified
  from this checkout (`git rev-list --count HEAD` = 1).

This document is an advisory. It is not a board item and does not change the
team's laws.

## 1. Verdict

The repo holds **no plaintext credential** (verified: GitHub PAT, Telegram bot
token, `sk-*`, `pt-*`, AWS and Slack shapes, plus an entropy/`Bearer`/
`x-access-token` sweep over tree and history — zero hits). The image really does
keep keys out (`docker/harness/Dockerfile:6-8`, `docker/harness/opencode.json:8`).

The risk is not a leaked secret; it is the **credential-handling architecture**.
A public repo runs an autonomous LLM agent with shell access inside a container
that has a **write-mounted checkout containing the job's `GITHUB_TOKEN`**, while
that token carries `contents: write` **and** `actions: write` — enough to
dispatch a workflow that seals every repo secret to an attacker-chosen public
key. The controls meant to stop this (SECRET GUARD, owner lock, "seats never
touch Lead files") are bypassable, non-blocking, or only prompt-level.

| Severity | Count |
|---|---|
| Critical | 3 |
| High | 5 |
| Medium | 6 |
| Low / Info | 5 |

## 2. Findings

### AT-01 — Critical — The agent inside the turn container can read the job's `GITHUB_TOKEN`; that token can exfiltrate every repo secret

**CWE-522 / CWE-269.** `ci.yml:64-65` grants the whole workflow
`contents: write` + `actions: write`; `ci.yml:213` gives the `turn` job no
`permissions:` override, so it inherits both.

`ci.yml:309-310` (and `:339-340`, `:821`, `:984`) rewrite the git remote as

```
https://x-access-token:${{ github.token }}@github.com/…
```

which persists the token in `$PWD/.git/config` (checkout's credential header is
there too — `persist-credentials` is never disabled). `ci.yml:681-688` then runs
the agent container with

```
docker run --rm --user 1001:1001 -v "$PWD":/workspace -w /workspace \
  -e OPENROUTER_API_KEY -e ZAI_API_KEY -e GROQ_API_KEY \
  -e CODEBUDDY_AUTH_TOKEN -e QODER_PERSONAL_ACCESS_TOKEN … bash /workspace/.turn-inside.sh
```

`--user 1001:1001` is the runner's own uid and the checkout is world-readable,
so the agent — an LLM steered by repo text, chat text and Telegram text — can
`cat .git/config` and lift the token.

**Exploit chain (no other precondition):**

1. read the token from `/workspace/.git/config`;
2. `POST .../actions/workflows/secret-relay.yml/dispatches` with
   `{"ref":"ai/main","inputs":{"seal_pubkey":"<attacker libsodium key>"}}`
   (`actions: write`; `secret-relay.yml:17-22`);
3. poll `GET .../actions/runs`, download the `relay-sealed` artifact
   (`secret-relay.yml:65-71`), decrypt locally → TELEGRAM_BOT_TOKEN,
   TELEGRAM_OWNER_ID/CHAT_ID, QODER PAT, GROQ/OPENROUTER/ZAI keys.

The same token also allows a direct push/force-push to the **default branch**
`ai/main` (repo is PUBLIC, `gh api .../rulesets` → `[]`), which the pipeline's
"seats never push to ai/main" rule forbids only in prose; and `actions: write`
allows cancelling runs and deleting artifacts/logs (audit tampering).

**Fix:** `permissions: contents: read` at workflow level; per-job grants
(`finalize` needs `contents: write` + `actions: write`; `turn` needs
`contents: write` only, or a branch-scoped GitHub App token);
`persist-credentials: false` on checkout and **never** write the token into
`$PWD/.git/config` (pass it per command via `git -c http.extraheader=…` from a
file outside `$PWD`, and delete it before the container starts); add a ruleset
on `ai/main` (require the `test` check, block force-push, restrict pushers); do
not pass provider keys as `-e` to a container that also has network egress and a
writable repo.

### AT-02 — Critical — `secret-relay.yml` is a permanent "seal all secrets to my key" endpoint

**CWE-620 / CWE-269.** `secret-relay.yml:16-22` takes the recipient key from a
`workflow_dispatch` **input**; `:34-42` puts seven repo secrets in the job env;
`:58-60` seals them; `:65-71` uploads the ciphertext as an artifact.

Any principal that can dispatch workflows — including the `GITHUB_TOKEN` from
AT-01, any collaborator with write, any future compromised integration — gets
all seven secrets in a form only *it* can open. The comment calls this "one-off
Lead ops", but the workflow is permanent, has no `environment:` protection, no
allowed-actor check, and no fixed recipient key.

**Fix:** delete the file after use, or gate it with `environment: secrets-relay`
+ required reviewer, drop the `seal_pubkey` input (pin a rotated recipient key in
code), add `permissions: contents: read` and a `github.actor` allow-list. Rotate
every secret this workflow has ever sealed — it has already run.

### AT-03 — Critical — Agent-writable scripts are executed with credentials

**CWE-829 / CWE-494.** The "LEAD-OWNED FILES" boundary in the turn brief
(`ci.yml:519-522`) covers `.github/workflows/*`, `TEAM-CONTROL.org` and
`.gitattributes` — **not** `.github/scripts/*`. Yet:

- `ci.yml:386` runs `bash .github/scripts/secret-guard.sh file "$CHAT"` in a step
  whose env holds `TELEGRAM_BOT_TOKEN` (`:326-329`);
- `ci.yml:734`, `:760`, `:849` run the same script in steps holding the git token
  (AT-01) and, at `:760`, the provider keys (`:221-240`);
- `cb-window.yml:51` runs `python3 .github/scripts/cb_window_ci.py` with
  `TELEGRAM_BOT_TOKEN` + `TELEGRAM_OWNER_ID` in env (`:38-39`);
- both files are executed from the **checked-out default branch**, i.e. from code
  an agent merged one turn earlier.

A seat that edits `secret-guard.sh` (a plausible "fix the guard" task) gets
arbitrary code execution with credentials inside the pipeline — and the guard is
the last thing between a leaked key and `git push`. GitHub blocks `GITHUB_TOKEN`
pushes that modify workflow files (hence `ci.yml:66-69`), but it does not block
scripts.

**Fix:** move these scripts under a Lead-owned path *and* execute the copy from
the base revision (`git show origin/ai/main:.github/scripts/secret-guard.sh`),
verify a pinned `sha256`, or inline them into the workflow; better, run the guard
as its own job with `contents: read` and no provider secrets.

### AT-04 — High — The Telegram owner lock is bypassed on the content path

**CWE-863 / CWE-74.** `ci.yml:359-360` correctly counts owner vs non-owner
messages and `:361-364` exits when no owner message is pending. But the block
that actually writes to the chat (`:380-381`) filters **only** on
`chat.type == "private"` — there is no `chat.id == OWNER` term:

```jq
.result[] | select(.message.chat.type=="private") | select(.message.text) | …
```

So whenever the Owner and anyone else are in the same 20-update window, the
stranger's text is written **verbatim** into `agent-team/TEAM-CHAT.org` — a file
in a **public** repo that the next turn feeds to the agent as `BRIEF`
(`:515-530`). That is unauthenticated third-party prompt injection into an agent
holding provider keys and the AT-01 token, plus arbitrary Org injection into the
team record. It contradicts the "impersonation impossible" claim at `:316-322`.

**Fix:** add `and ((.message.chat.id|tostring) == $owner)` to the `:380` filter
(and check `.message.from.id` too); append only sanitized, quoted text; assert
the number of appended messages equals `COUNT` before committing.

### AT-05 — High — Any Telegram user can permanently wedge the Owner channel (unauthenticated DoS)

**CWE-400 / CWE-693.** `getUpdates` is called with `limit=20` and **no offset**
(`ci.yml:342-343`). If 20 non-owner messages are queued, `COUNT` is 0, and the
script exits at `:364` **before** confirming the offset (`:390-392`). The same 20
attacker updates are therefore returned on every run and the Owner's messages
never reach the queue head. No credential and no repo access are required — only
the bot's username.

**Fix:** advance the offset past non-owner updates before any early exit, or
persist `offset` between runs; rate-limit and drop non-owner traffic.

### AT-06 — High — Session artifacts are published to a public repo and the scrubber misses real key shapes

**CWE-200 / CWE-532.** `ci.yml:722-750` tars each seat's CLI session tree
(`~/.qoder`, `~/.config/goose/sessions`, `~/.local/share/opencode`,
`~/.codebuddy/projects|sessions`, `/usr/local/lib/qoder-home/.qoder`) and uploads
it as `sessions-<seat>-*` with 30-day retention. Artifact access follows repo
read permission and this repo is **PUBLIC** — treat every session tarball as
readable by any GitHub account.

The only protection is `secret-guard.sh file`, which (proven in AT-07) does not
recognise `gsk_…` (Groq), `sk-or-v1-…` (OpenRouter), Z.ai key shapes, Discord
webhook URLs or `Bearer` headers — all of which occur in real CLI session logs
(`llmfisher.yml:32-46` lists the key inventory; `cb_window_ci.py:156` itself
greps for `access|refresh token`, `api key`, `Bearer`).

Compounding it: `ci.yml:680` creates `$PWD/.sessions-restore` **inside the
repo** and mounts it read-only into the next container, so a previous agent's
files (including `~/.bashrc`, CLI configs, hooks) are replayed into the next
turn — cross-turn persistence that `--rm` was meant to prevent — and an agent
obeying "commit everything on this branch" commits them, because they are not
ignored (AT-15).

**Fix:** do not publish session artifacts from a public repo, or seal them
(`SealedBox`) like the credential artifacts; scrub with a real scanner
(gitleaks/trufflehog: provider rules + entropy, whole file) and **fail** on a
hit; keep `.sessions-restore` in `$RUNNER_TEMP`; restore only allow-listed paths
(never dotfiles, never hooks).

### AT-07 — High — The SECRET GUARD is not a control (six proven defects)

**CWE-693 / CWE-532.** `.github/scripts/secret-guard.sh` is described in
`AGENTS.md:44-47` and `AGENT-TEAM-MEMBERS.org:252-255` as the backstop "before
every push". Measured behaviour:

1. **History is not rewritten.** `branch` mode redacts the working tree and
   `git commit --amend`s only `HEAD` (`:68-79`). A value introduced in an earlier
   commit of the same branch survives; the branch is pushed at `ci.yml:761` and
   merged at `:827`, so the secret reaches `ai/main` history. *Verified:* scratch
   repo, secret in commit 2, guard run before push → tip clean, `git log -p`
   still yields the secret.
2. **Wrong secret inventory.** `:46` matches only
   `GROQ|OPENROUTER|ZAI|ZHIPU|QODER|TELEGRAM|LARK|CODEBUDDY|OPENAI|ANTHROPIC`.
   Missing: `GEMINI_API_KEY`, `OLLAMA_CLOUD_API_KEY`, `CLOUDFLARE_API_KEY`,
   `GOMODEL_MASTER_KEY`, `CF_TUNNEL_TOKEN`, `DISCORD_WEBHOOK_TEAM_HQ`
   (`ci.yml:1012`), `AA/BAI/GMI/NAVYAI/TOKENHARBOR/TYPESAFE_*`. The values are
   read from the **current step's** env (`:26-48`), and the push steps (`:760`,
   `:849`) export no provider keys — exact-value matching is a no-op exactly
   where it matters.
3. **Wrong patterns.** *Verified:* `sk-or-v1-…`, `gsk_…`, a Z.ai-style key and a
   Discord webhook URL pass through untouched; only `ghp_…`/`pt-…` shapes match.
4. **False positives corrupt content.** `pt-[A-Za-z0-9]{8,}` rewrites ordinary
   words: `script-20261021-runner` → `scri[REDACTED:pattern]-runner`, silently
   mangling Org prose, commit messages and identifiers.
5. **Values containing `|` are not redacted at all.** `:31` escapes every
   non-alnum as `\|`, but in GNU sed BRE `\|` is the alternation operator, so the
   pattern becomes something else. *Verified:* `SECRET_GUARD_VALUES='a|b-XYZ…'`
   → `redactions=0`, value intact.
6. **It cannot fail.** `:81-82` always `exit 0`; callers ignore the status
   (`ci.yml:760`), and in `finalize` it runs **after** `git add` on a tree whose
   parent commits already contain the value (`:849-850`) — it can only change the
   merge commit, never the history it merges.

**Fix:** replace it with `gitleaks`/`trufflehog` over the **full history and the
pushed range**, fail closed, with the missing provider rules; keep exact-value
matching as an extra, not the primary. Rotate anything that has passed through
the current guard.

### AT-08 — High — Agent branches auto-merge into the public default branch; the "byte-compile gate" executes agent-authored Elisp

**CWE-284 / CWE-94.** `ci.yml:827` merges any branch named by the previous job's
output (`--no-ff`); `:847` gates it on
`emacs -Q --batch … (byte-compile-file "agent-team.el")`; `:850` pushes to
`ai/main`. But `batch-byte-compile` **evaluates top-level forms** — a file
containing `(shell-command "…")` runs it in `finalize`, which holds
`contents: write` + `actions: write` and a token in `.git/config`. The gate is an
execution surface, not a safety gate; it also compiles only one of the two
packages.

There is no branch protection (`rulesets: []`, PUBLIC repo, default branch
`ai/main`), so any token holder can push, force-push or delete refs directly and
skip the merge path entirely.

**Fix:** merge through a real review gate (PR + required owner approval +
required `test` check) with a purpose-scoped GitHub App token; compile in a
throwaway container with `--network none`, no token, no secrets and a read-only
checkout; compile **both** packages; add the ruleset.

### AT-09 — Medium — Workflow-wide over-granting of `GITHUB_TOKEN`

`ci.yml:63-65` gives every job `contents: write` + `actions: write`, including
`test` (`:76-77`, which runs on `push` **and** `pull_request`) and `probe`
(`:104-107`). `actions: write` lets a compromised step cancel runs, delete
artifacts/logs and dispatch workflows — destroying the audit trail of the very
incident it causes. `harness` adds `packages: write` (`:176-178`). The three ops
workflows declare no `permissions:` at all.

**Fix:** default to `contents: read`; grant the minimum per job; keep
`actions: write` only on the self-dispatch step of `finalize` (or replace it with
a `workflow_run` chain that needs no write token).

### AT-10 — Medium — `harness` builds and publishes PR-controlled code

`ci.yml:173-202` runs on **every** event (no `if:`), builds `docker/harness` from
the event ref with network access, and pushes
`ghcr.io/khaalidrafi/agent-team-harness:latest` (`:191-195`) with
`packages: write`. A same-repo PR — which any agent holding the AT-01 token can
open — replaces the public `:latest` image. The `test` job likewise executes the
PR's Elisp (top-level forms) on a runner. Fork PRs are saved only by GitHub's
read-only token downgrade (keep "Send write tokens to workflows from pull
requests" **off**; prefer explicit `permissions:` over relying on it).

**Fix:** `if: github.event_name != 'pull_request'` on `harness`; build PR images
without `push:`; run ert/compile with `permissions: contents: read`.

### AT-11 — Medium — `GITHUB_ENV` is fed from an agent-writable file

`ci.yml:696-700`:

```bash
sed -n '/TURN_RESULT=/p' /tmp/.turn-out.txt > /tmp/.turn-result.tmp
[ -s /tmp/.turn-result.tmp ] && cp /tmp/.turn-result.tmp "$PWD/.turn-result.txt"
[ -s "$PWD/.turn-result.txt" ] || echo "TURN_RESULT=BLOCKED …" > "$PWD/.turn-result.txt"
cat "$PWD/.turn-result.txt" >> "$GITHUB_ENV"
```

`$PWD` is the container's writable `/workspace` and `.turn-result.txt` is not
ignored (AT-15). The file is concatenated into `$GITHUB_ENV` with no shape
validation, so *if* the container exits 0 without emitting a verdict line (or
rewrites the running `.turn-inside.sh`), every line in the agent-authored file
becomes an environment variable for the remaining steps — `BASH_ENV=`,
`GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_n` (credential-helper injection),
`SECRET_GUARD_VALUES=`, `PATH=` — i.e. code execution in the push step that holds
the token.

**Fix:** never `cat` container output into `$GITHUB_ENV`; match
`^TURN_RESULT=[A-Za-z0-9 _().:-]{1,80}$` and write one fixed variable; keep the
verdict file in `$RUNNER_TEMP`.

### AT-12 — Medium — Unpinned third-party code runs with credentials

- `docker/harness/Dockerfile:20`, `:51`: `curl -fsSL … | bash` (OpenCode, Qoder —
  no version, no checksum).
- `Dockerfile:64`: `npm install -g @tencent-ai/codebuddy-code` (no version).
- `Dockerfile:10`, `llmfisher.yml:121`: `debian:stable-slim`,
  `python:3.12-alpine` (mutable tags).
- `cb-window.yml:48-50`, `secret-relay.yml:44`: `npm i -g …` / `pip install pynacl`
  at run time, unpinned, inside jobs holding the Telegram bot token and (relay)
  seven repo secrets.
- `actions/checkout@v4`, `docker/build-push-action@v6`, `upload-artifact@v4` …
  tag-pinned, not SHA-pinned, in a workflow with `contents: write`.

Each is a path from a compromised upstream to the credentials in env.
**Fix:** digest-pin images, SHA-pin actions, version + `sha256sum` installers, and
move `npm`/`pip` installs into the image build (the DOCKER LAW already says so);
add an egress allow-list to credentialed jobs.

### AT-13 — Medium — The CodeBuddy window leaks a transcript and trains the Owner to click pipeline links

`cb-window.yml:56-63` uploads `cb-transcript.txt` — the raw TUI dump written by
`cb_window_ci.py:132` — as a public-repo artifact. It can contain the OAuth login
URL **including its `state` parameter** (`cb_window_ci.py:32,190`), the account
identity and partial tokens. The workflow also installs an unpinned npm package
(`:48`) and drives an interactive login while holding `TELEGRAM_BOT_TOKEN`
(`:38`), then Telegrams the Owner a login link (`cb_window_ci.py:183-189`) under a
13-minute deadline (`:42-46`) — a reusable phishing/consent-fatigue pattern any
write-token holder can trigger at will.

**Fix:** drop the transcript upload; never upload anything containing `state=` or
tokens; pin the npm package; require an `environment:` approval before the window
opens.

### AT-14 — Medium — Untrusted tar handling / restore

`ci.yml:730-736` extracts the container-produced `.turn-sessions.tgz` on the host
and `:660-680` extracts the previous artifact into `.sessions-restore`. GNU tar
does strip absolute names and reject `..` members (verified: exit 2, nothing
escaped), so this is not direct traversal — but there is no member allow-list, no
size/count cap (decompression bomb on the runner), and symlink members are
preserved and re-mounted into the next container. With AT-06 it is a persistence
channel, not just a report.

**Fix:** `tar --no-same-owner --no-overwrite-dir`, validate members against an
allow-list, cap total size/entries, refuse symlinks/hardlinks/device nodes.

### AT-15 — Low — `.gitignore` does not cover the pipeline's own secret-bearing paths

`.gitignore:1-3` is `*~`, `*.elc`, `.agent-org/`. Not ignored (verified with
`git check-ignore`): `.turn-result.txt`, `.turn-inside.sh`,
`.turn-sessions.tgz`, `.sessions-restore/`, `relay-sealed.bin`,
`cb-creds-sealed.bin`, `sessions-*.tgz`, `.env`, `*.pem`. The turn brief tells
seats to commit their work, so a `git add -A` publishes whatever is lying in the
workspace. **Fix:** ignore all of the above plus `*.key`, `*.p12`, `credentials*`;
add a pre-commit guard that refuses staged paths outside an allow-list on turn
branches.

### AT-16 — Low — Gateway key handling in the Emacs client

`agent-team.el:34-38` captures `GOMODEL_MASTER_KEY` into a `defcustom` at load
(one `customize-save-variable` and the key is plaintext on disk), and
`:509-535` passes it as a `curl` **argv** element (`"Authorization: Bearer %s"`),
visible in `/proc/<pid>/cmdline` and `ps` to any local user for the duration of
the call. **Fix:** read the env var at call time, pass the header via
`--config -`, and never persist it.

### AT-17 — Low — Committed bytecode

`.github/scripts/__pycache__/cb_window_ci.cpython-313.pyc` is tracked
(`git ls-files -s`). It is stale build output, unreviewable in diffs, and a place
to hide code from review. **Fix:** `git rm -r --cached` + ignore `__pycache__/`.

### AT-18 — Low — Sealed-artifact design

`cb-window.yml:41` hardcodes one long-lived libsodium public key; both artifact
uploads use `retention-days: 1` — retention is not deletion (caches and forks can
outlive it); there is no key rotation or epoch; and the ciphertext is readable by
anyone with repo read. **Fix:** rotate the sealing keypair per run and publish
the ephemeral public key with the run; delete the artifact in the same job after
collection.

### AT-19 — Info — Self-modifying law and union merges

`AGENTS.md`, `templates/AGENT-TEAM-COMMON.org`, `agent-team/AGENT-TEAM-MEMBERS.org`
and the board are writable by the same agents they bind, so "never do X" is a
suggestion the next turn can rewrite. `.gitattributes:6-8` union-merges
`TEAM-CHAT.org`, the board and mailboxes, which duplicates lines on conflict and
has already glued a report body into the wrong message (`AI-REVIEW.org:23-27`);
union merges can also smuggle content past a reviewer who reads only the diff.
**Fix:** keep the laws and the guard/config outside the agents' write scope, and
replace union merge with a conflict-failing merge plus a repair step.

## 3. What is already good

- No credential in the tree or the (single) commit — verified across six shape
  families plus an entropy sweep. The harness image bakes configs only
  (`Dockerfile:70-78`).
- The container is non-root, `--rm`, without the Docker socket, `--privileged` or
  host networking (`ci.yml:681-688`).
- `pull_request` is used, not `pull_request_target`; fork PRs get a read-only
  token and no secrets — keep it that way.
- The owner-lock idea and the "names only, never values" law are the right
  primitives — AT-04/AT-05 are implementation bugs, not design failures.
- Dead-seat tolerance, stall accounting and the kill switch are real availability
  controls; the chain degrades instead of failing.

## 4. Remediation order

1. **Today** — rotate every secret that `secret-relay.yml` could seal; delete or
   environment-gate `secret-relay.yml` and `cb-window.yml`.
2. **Today** — remove `actions: write` from the workflow default; add a ruleset
   protecting `ai/main`; set `persist-credentials: false` and stop writing the
   token into `$PWD/.git/config`.
3. **This week** — move `.github/scripts/*` out of agent write scope and execute
   them from the base revision; fix the Telegram filter (`:380`) and the offset
   starvation; stop publishing session artifacts from the public repo (or seal
   them); replace the guard with gitleaks (fail closed, full history).
4. **This week** — stop feeding `$GITHUB_ENV` from the container; validate the
   verdict; add the missing `.gitignore` rules.
5. **Next** — digest/version pinning, `harness` off `pull_request`, a sandboxed
   byte-compile gate, per-job least privilege, an egress allow-list for the turn
   container, and a `SECURITY.md` threat model whose first line is: *assume an
   agent can read every credential in its env and filesystem, and will follow any
   text in its context.*

## 5. Verification commands

```bash
# no credential shapes in tree/history
git grep -nIE '(ghp_|github_pat_|sk-[A-Za-z0-9]{16,}|pt-[A-Za-z0-9]{8,}|[0-9]{8,10}:[A-Za-z0-9_-]{30,})'
git log --all -p | grep -nIE '(ghp_|sk-[A-Za-z0-9]{20,}|x-access-token:[^@[:space:]]{8,})'

# secret guard reality check (scratch repo)
git init /tmp/sg && cd /tmp/sg && git commit --allow-empty -m c1 \
  && echo 'pt-ABCDEFGH12345678' > leak.txt && git add . && git commit -m c2 \
  && cp <repo>/.github/scripts/secret-guard.sh . && bash secret-guard.sh branch HEAD~1 \
  && git log -p | grep -c ABCDEFGH12345678   # -> still present

# repo posture
gh api repos/khaalidrafi/agent-team.el/rulesets
gh repo view khaalidrafi/agent-team.el --json visibility,defaultBranchRef
```




