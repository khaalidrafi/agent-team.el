# AGENTS.md — operating manual for agents working in khaalidrafi/agent-team.el

REPO-OWNED (Owner order 2026-10-20 19:21Z: "The repo should have its own
AGENTS.md" — supersedes the earlier untrack order; this file is tracked).
This is the repo's own agent law: every member, acting seat, and the Lead
reads THIS file first. Global Owner law lives outside the repo and is
never committed here.

## What this repo is

`agent-team.el` — the Emacs package for the multi-model agent team: board
(TODOS.org), dispatch composer, status flips, the team mesh
(TEAM-CHAT.org), the control plane (TEAM-CONTROL.org), the secret law
commands, and the Owner's gateway client. The team ALSO runs on CI
(.github/workflows/ci.yml): scheduled/dispatched turns rotate seats through
real work segments and self-chain until the objective completes.

## File map (source-of-truth chain)

- `agent-team/TEAM-CONTROL.org` — chain switches: `#+KILL-SWITCH`,
  `#+OBJECTIVE`, `#+OBJECTIVE-STATE`, `#+TURN` (seat pointer),
  `#+STALL-COUNT`. CI reads it verbatim every run.
- `agent-team/TODOS.org` — the BOARD, single source of truth
  for work; chat handoffs never count.
- `agent-team/TEAM-CHAT.org` — ONE append-only chat buffer (mailbox/ is a
  frozen archive; never write there).
- `agent-team/MEMBERS.org` — roster + ranks + SECRET/SESSION
  law text.
- `STATE.org`, `README.org`, `AI-REVIEW.org` — cross-session state, facts,
  review queue.

## LAWS (violating any of these is a chain fault)

1. FORMAT LAW (17:55Z): every chat message is an Org headline carrying
   FROM (`* MSG <from> -> @<to> :<kind>:`), routing in Org tags, fields in
   a `:PROPERTIES:` drawer (`:FROM:`/`:TO:`/`:KIND:`/`:WHEN:`/`:CHANNEL:`),
   body indented, WHEN an Org inactive timestamp. Append at EOF only;
   never edit or delete existing entries.
2. TELEGRAM LAW (17:55Z): every Telegram-bound message opens with
   `FROM:` and `TO:` lines.
3. SECRET LAW (18:27Z): credentials NEVER travel in chat, files, commits,
   or messages — only as ENV VAR NAMES. A peer asked for a credential
   replies with the NAME + has-it/absent (Emacs: `M-x agent-team-env-look`),
   and the asker reads the value from their OWN environment
   (`(getenv "NAME")`). Never echo a value. The SECRET GUARD
   (.github/scripts/secret-guard.sh) redacts leaked values at every
   commit/ingest/artifact choke point.
4. SESSION LAW (18:27Z): agents' CLI session files are collected at turn
   end, scrubbed of secrets, uploaded as `sessions-<seat>-*` artifacts
   (30d), and restored before the same seat's next turn — resume with
   context instead of starting cold.
5. OWNER LOCK (17:47Z): the Telegram bridge ingests ONLY the Owner's
   chat (secret TELEGRAM_OWNER_ID); every other chat is dropped and
   counted — impersonation impossible.
6. DOCKER LAW (Owner 2026-10-20): agents are PREINSTALLED in the harness
   image (docker/harness/); CI never installs bodies at turn time. Keys
   are env-injected, never baked.
7. SEAT BOUNDARIES: seats never edit Lead-owned files (.github/workflows/*,
   agent-team/TEAM-CONTROL.org, .gitattributes) — read and cite them with
   file:line evidence instead. Seats never push to ai/main (the chain's
   finalize auto-merges their branch behind the gate).
8. BOARD DISCIPLINE: work items live on the BOARD. Mark ONGOING at start,
   log evidence in `:LOGBOOK:`, never self-mark DONE (Lead-only gate).
9. IDENTITY: commit as your seat identity, never as a generic bot.
10. NO SPEND, no destructive actions, stay in scope of the item you picked;
    escalate to @lead as `:escalation:` after 2 failed self-attempts.

## Emacs members — quick reference

- `M-x agent-team-init` — scaffold team files in a new repo
- `M-x agent-team-chat-append` / `agent-team-chat-open` /
  `agent-team-chat-tail` / `agent-team-chat-pings-to` — the team mesh
- `M-x agent-team-env-names` / `agent-team-env-look` / `agent-team-env-require`
  — secret law (names only, never values)
- `M-x agent-team-control-get` / `agent-team-control-set` /
  `agent-team-kill-switch` — the control plane (Lead)
- `M-x agent-team-insert-dispatch` / `agent-team-flip-status` — the board
- `M-x agent-team-jev-ask` / `agent-team-gateway-ping` — Owner gateway
  (key = GOMODEL_MASTER_KEY env; command refuses to run when unset)

## CI chain in one paragraph

`test` (byte-compile + ert) → `probe` (seat liveness) → `harness` (build
the preinstalled image) → `turn` (TG ingest → session restore → one agent
segment in the container → session scrub+upload → branch push + rotation
advance) → `finalize` (auto-merge behind the byte-compile gate → stall
accounting → SELF-DISPATCH the next run while the objective is open).
The chain stops only on KILL-SWITCH ON, OBJECTIVE-STATE COMPLETE, no
objective, or tests red; a no-progress streak shifts to backoff, never
to failure. Owner gets every verdict mirrored on Telegram.
