# HUMANS.md

Written 2026-11-18 from a full read of the sources on ai/main. Audience:
a competent developer who did not write this code and wants to understand,
navigate, and safely develop it.

## What this is

agent-team.el is an Emacs package (Emacs 28.1+, no external Elisp
dependencies) that is the operator-side cockpit for a "multi-model AI
agent team": a system in which GitHub Actions rotates CLI coding agents
(OpenCode, Goose, Qoder, CodeBuddy, Cursor, and others) through work
segments while all team state lives in plain Org files inside the repo.
The package scaffolds that setup into any project (a CI workflow, a
harness Dockerfile, a team-creation prompt) and then supplies the
day-to-day commands: compose dispatches onto the board, flip task
statuses with Org clocking, send protocol-formatted chat messages, view
the chat as an archive or a live surface, dispatch chat messages to
cloud LLM members, and ask a judgment endpoint ("Jev") for calibrated
yes/no calls.

This repository is also a live instance of its own system. The tracked
agent-team/ directory holds the running team's board, chat, control
file, roster, and charter, and .github/workflows/ci.yml is the chain
that keeps agents working on this repo itself. When you edit files here
you are editing a machine's workspace while it runs.

## Mental model

Keep two layers apart:

1. The Emacs package: six .el files plus tests, templates, and harness
   configs. All entry points are interactive commands.
2. The team runtime: Org files under agent-team/ that humans (via the
   package) and CI agents (via shell plus the baked team-chat command)
   both read and write.

Data flow for work:

- agent-team/TODOS.org (the board) is the single source of truth.
  Dispatch items land under the "* Board" heading via
  agent-team-insert-dispatch, which also copies the dispatch text to the
  kill-ring for pasting into the member's chat.
- agent-team/CHAT.org is the one chat: an append-only Org file with a
  fixed message grammar. Emacs sends with agent-team-chat-send; CI seats
  send with agent-team-chat-send-batch (baked as the team-chat command;
  fields come from AGENT_CHAT_* environment variables). Nobody
  hand-writes entries.
- agent-team/CONTROL.org is the control plane. The keys the Elisp code
  reads are #+OBJECTIVE, #+OBJECTIVE-STATE, #+TURN, #+KILL-SWITCH, and
  #+STALL-COUNT (agent-team-control-set writes them). The embedded TEAM
  CI brief in agent-team.el also documents #+PAUSE-AFTER-TODO and
  #+CHAIN-PAUSE, which the CI chain reads.
- .github/workflows/ci.yml runs five jobs in order: test (byte-compile
  plus ERT, the landing gate), probe (seat liveness, never a quality
  gate), harness (builds the ci/docker/harness image from the ci
  submodule), turn (one agent segment: session restore, the segment
  itself in the preinstalled container, session scrub and upload, branch
  push), and finalize (auto-merge behind the test gate, Jev review,
  stall accounting, and self-dispatch of the next run while the
  objective is open). The turn pointer now lives in the GitHub Actions
  variable CHAIN_TURN, with the #+TURN: line in CONTROL.org as
  fallback.
- agent-team/MEMBERS.org maps roles to model@platform ids. For "cloud
  members" a :PROPERTIES: drawer adds :TRANSPORT:, :ENDPOINT:, :AUTH:,
  :PERSONA:, and :PRIVACY:.

The same CHAT.org file has four views:

- The raw file view (agent-team-chat-open defined in agent-team.el;
  auto-revert-tail keeps it current).
- The archive render "*agent-team Chat*" (agent-team-chat.el): a
  read-only re-render in a friendlier grammar, for after a restart or
  for history.
- The live render "*agent-team Live*" (agent-team-live.el): mtime
  polling, unread overlays, send and dispatch keys. The data-flow law
  (design docs in docs/) names this the only interactive surface.
- The GitHub poller (agent-team-watch-chat in agent-team.el): fetches
  the file over HTTPS on a timer; built for Emacs on Android where no
  git binary exists.

## Code map

| Path | Role |
|---|---|
| agent-team.el | Core: pure helpers, scaffolding (agent-team-init), dispatch composer, status flips, chat send, secret law, control plane, Jev/gateway calls, teamify prompt builder, GitHub chat poller, one-command project setup (agent-team-setup-project), workflow domains. |
| agent-team-chat.el | CHAT.org archive reader: parser, renderer, derived message ids, chat-member:/chat-msg: links, touch mode. |
| agent-team-bridge.el | Dispatch engine for llm-api cloud members: MEMBERS.org registry, eligibility and loop law, queued/err lifecycle, OpenAI-compatible transport. |
| agent-team-clock.el | TIME LAW: flip the dispatched board item to ONGOING and open an Org clock at prompt-send time. Needs agent-org. |
| agent-team-sessions.el | "*agent-team: team*" dashboard over per-role agent-org sessions: control switches, active board tasks, mailbox counts, recent exchanges. |
| agent-team-live.el | The live chat surface: renders local CHAT.org, polls mtime, unread overlay, send (c) and dispatch (d). |
| tests/ | ERT suites: agent-team-test.el (also covers the clock), agent-team-chat-test.el, agent-team-bridge-test.el, agent-team-live-test.el. Fixtures in tests/fixtures/. |
| templates/ | TEAMIFY.org and BOOTSTRAP.org (mode layers), COMMON.org (the master prompt), CANDIDATES.org (hiring pool), agent-team.yml (CI chain template with {{SLOT}} tokens), WORKFLOWS.org (non-coding workflow contract). |
| docker/harness/ | opencode.json, goose-config.yaml, Dockerfile: agent configs copied or scaffolded into target projects. |
| .github/workflows/ci.yml | The chain itself. Sibling workflows: cb-window, llmfisher, mcode-probe, secret-relay, secret-sync, token-keeper. |
| .github/scripts/ | secret-guard.sh (redaction at commit choke points), sync_secrets.py, cb_window_ci.py. |
| scripts/gh_app_mint.sh | Mints a GitHub App installation token from env-provided key material. |
| agent-team/ | Live team state: board, chat, control, roster, charter, demo, and a frozen mailbox archive. Not sample data. |
| ci/ | Submodule pointing at khaalidrafi/agent-team-ci: the shared CI kit (harness Dockerfile, law_brief.sh, commit_msg_guard.sh, review scripts). |
| docs/ | Binding designs: CLOUD-BRIDGE-DESIGN.org, LIVE-TEAM-CHAT-DESIGN.org; plus OPENBOT-PORT.org, INTEGRATION-ADMINEVERYWHERE.org, PSTACK-TEAM.org, PSTACK-TEAM-WORKFLOW.org. |

Load-bearing symbols in agent-team.el: agent-team--parse-members and
agent-team--normalize-member-id (roster parsing);
agent-team-insert-dispatch with agent-team--read-counter and
agent-team--bump-counter-in-file (board dispatches);
agent-team-flip-status with agent-team--next-status (status cycle);
agent-team--chat-format, agent-team--chat-append-1,
agent-team-chat-send, agent-team-chat-send-batch (the one append path);
agent-team-env-names, agent-team-env-look, agent-team-env-require
(secret law); agent-team-control-get, agent-team-control-set,
agent-team-kill-switch (control plane); agent-team-jev-ask and
agent-team--jev-payload (gateway); agent-team-teamify-prompt with
agent-team--template, agent-team--strip-template-header, and
agent-team--demote-headings (prompt builder); agent-team-watch-chat with
agent-team-chat--render, --callback, --fetch (GitHub poller);
agent-team-setup-project with agent-team--scaffold-ci,
agent-team--detect-gate, agent-team--default-slots,
agent-team--fill-slots, agent-team--unfilled-slots (project setup);
agent-team-workflows, agent-team--workflow, agent-team-set-workflow
(workflow domains).

## Core algorithms

- Regex-only Org parsing, on purpose. Every parser walks lines with
  regexes instead of org-element; AI-REVIEW.org records this as a
  deliberate "simple over clever" choice. The central one,
  agent-team-chat--parse-messages in agent-team-chat.el, is a single
  forward pass: a line starting "* MSG " opens a message, ":KEY: value"
  lines collect properties, other lines (not "# " comments, "#+"
  keywords, or a new "* " heading) collect the body. Linear in the
  number of lines, no backtracking. The same style parses MEMBERS.org
  (agent-team--parse-members) and the mailbox inboxes
  (agent-team-sessions--mailbox).
- Member id normalization. agent-team--normalize-member-id accepts both
  "model @ platform" prose and compact "model@platform", drops a
  trailing "(annotation)", collapses whitespace, and requires exactly
  one "@". A heading tail with no "@" is not a member id, which is how
  plain section headings are rejected instead of being parsed as seats.
- Dispatch numbering. The board carries a "# DISPATCH counter: N"
  comment line. agent-team--read-counter regexes it out (default 0) and
  agent-team--bump-counter-in-file rewrites the line in place through
  find-file-noselect plus save-buffer. Task ids are zero-padded to three
  digits. The exact line format is a known fragility (AI-REVIEW.org).
- Chat grammar and derived ids. agent-team--chat-format renders one
  entry: a "* MSG <from> -> @<to> :<kind>:" headline carrying routing in
  Org tags, a :PROPERTIES: drawer (FROM, TO, KIND, REPO, PRIORITY,
  RISK, WHEN), and a two-space indented body. WHEN is an inactive
  timestamp like "[2026-10-21 Wed 09:00 UTC]". Appends go to end of file
  only. Because the file is append-only and union-merged, message ids
  are derived without touching the file:
  agent-team-chat--msg-id returns "msg-" plus the first 8 hex chars of
  a sha1 over FROM, a NUL byte, WHEN, a NUL byte, and the first 80 body
  characters; entries missing :WHEN: degrade to positional
  msg-legacy-NNN ids.
- Bridge eligibility and loop law. agent-team-bridge--eligible-p
  classifies each message. A message is dispatchable only when it is
  addressed to exactly one llm-api member (the :TO: drawer names the id,
  or the body carries a [[chat-member:ID]] link). TO=all is a broadcast
  and is never dispatched. A message from an llm-api member is never
  relayed onward unless the chat file declares a non-empty #+AUTOPILOT:
  keyword, and even then agent-team-bridge--hop-budget-p bounds the
  chain: a backward walk counting consecutive llm-api replies, refused
  past the default of 4. Addressed but undeliverable messages (no
  :TRANSPORT: declared, training-privacy lane, hop budget exhausted)
  get the queued-then-err lifecycle; loop-law bars are silent
  non-delivery by design.
- Bridge dispatch cycle. agent-team-bridge--dispatch-index parses the
  file, classifies, stamps ":queued:" plus :MEMBER:/:CHANNEL: drawers on
  the heading, builds the prompt (persona file text plus a fixed
  team-law paragraph as the system message; the last 20 messages
  rendered author-labeled, bodies flattened and capped at 400
  characters, as the conversation), POSTs an OpenAI-compatible
  chat/completions request, then appends the reply through
  agent-team--chat-append-1 (FROM is the member id, TO is the original
  sender, KIND is note) and drops the queued tag. Errors retag ":err:"
  and append one "BRIDGE-ERR: <reason>" line.
  agent-team-bridge-tick scans the last 50 entries (the scan window) and
  dispatches oldest first.
- TIME LAW clock transform. agent-team-clock--pick chooses the board
  item: an explicit TASK pin wins (it may adopt a REVIEW item; work
  clocks and review clocks are separate), then the first open item
  whose section text mentions the role, then the first open item. The
  two fallbacks never pick a REVIEW item; DONE, CANCELLED, and DEFERRED
  are never touched. agent-team-clock--apply then rewrites the line
  list: keyword becomes ONGOING, and a "CLOCK: <ts>" line goes into the
  existing :LOGBOOK: or into a fresh drawer placed after planning lines
  (SCHEDULED, DEADLINE, CLOSED) and a :PROPERTIES: drawer. It is
  idempotent: an existing open clock changes nothing. The hook
  agent-team-clock--on-prompt-send hangs off
  agent-org-prompt-send-hook with errors demoted, so a broken clock can
  never block a send.
- Incremental chat rendering. Two diff strategies over the same
  append-only file. The GitHub poller (agent-team-chat--render in
  agent-team.el) keeps the previously rendered text and, when the new
  text has the old text as a prefix, overlays the appended region with
  a "new" face. The local live surface (agent-team-live--render)
  compares file mtime and parsed message count instead, and overlays
  from the first unseen "** " heading; the buffer-local state variables
  are marked permanent-local so they survive the org-mode re-init that
  each rebuild performs.
- Gate detection and slot filling. agent-team--detect-gate picks the
  landing gate by file presence, in order: pytest (pytest.ini,
  pyproject.toml, or setup.cfg), npm (package.json), make (Makefile),
  Elisp (an agent-team.el in the root), else a loud placeholder that
  fails. agent-team--fill-slots does plain {{NAME}} string replacement
  against templates/agent-team.yml; agent-team--unfilled-slots lists
  leftover tokens and agent-team--scaffold-ci errors when any remain.
- Jev round trip. agent-team-jev-ask POSTs to
  agent-team-gateway-url + "/v1/systemone" a JSON body built by
  agent-team--jev-payload: the region text as state, the model id from
  the constant agent-team--jev-model (currently "jev-1.14.0"), and one
  "noul" question. curl runs with a 90 second timeout. The answer is
  read from the response at answers.q.noul; 0.5 or above reads yes. The
  model id is pinned in exactly one place, and the ERT test
  agent-team-jev-model-pinned-current fails if any of the scanned law
  files carries a different dated id.
- Workflow domains. agent-team-workflows is a table of four domains
  (coding, writing, reporting, research), each with dispatch types, a
  role skeleton, and a review gate. The board's "#+WORKFLOW:" line
  selects one; coding is the default and unknown names fall back to
  coding. agent-team-set-workflow rewrites the line and a "* WORKFLOW:"
  section idempotently, and agent-team-insert-dispatch appends a
  WORKFLOW gate line to non-coding dispatch bodies.

## Invariants and gotchas

- The board is the single source of truth. Chat handoffs never count as
  work (AGENTS.md, agent-team/CHARTER.md).
- CHAT.org is append-only. Never edit or delete existing entries. The
  one writer is agent-team--chat-append-1; the bridge's lifecycle tag on
  entries it stamped, its BRIDGE-ERR lines, and its replies are the
  narrow sanctioned exception. Hand-writing an entry breaks the rules
  the CI seats operate under.
- .gitattributes sets merge=union on agent-team/CHAT.org,
  agent-team/mailbox/*.org, and agent-team/AGENT-TEAM-TODOS.org, so
  merges keep both sides and concurrent appends are never lost. Do not
  "clean up" those files.
- Regex parsing is load-bearing. The counter line must read exactly
  "# DISPATCH counter: N"; dispatches insert under the first "* Board"
  heading; chat parsing keys on "* MSG " headlines. Odd files break
  these; AI-REVIEW.org tracks the known cases.
- agent-team.el has its footer in the middle. (provide 'agent-team) sits
  at line 760 and ";;; agent-team.el ends here" at line 762, with about
  1150 more lines after them (prompt builder, GitHub poller, project
  setup). Everything still loads, because the whole file is one load
  unit, but do not trust the footer when navigating.
- agent-team-flip-status enforces no roles. DONE is terminal in the
  cycle, but "only the EM flips DONE" is convention, not code.
- Secrets: values never travel. Commands print env var names only;
  agent-team-env-look answers set, unset, or nonstandard and never shows
  a value. GOMODEL_MASTER_KEY must be in the environment for gateway
  commands. The teamify PAT travels inside the built prompt only. The
  bridge resolves :AUTH: aliases through auth-source or an
  AGENT_TEAM_BRIDGE_AUTH_<ALIAS> environment variable, in memory.
- Soft dependencies. agent-org is optional at compile time
  (require with nil t) and required at runtime by the clock
  (agent-team-clock-in errors without it) and the session commands.
  agent-team-live.el guards the bridge with fboundp: viewing and
  composing work without agent-team-bridge.el, the d dispatch key does
  not.
- Gateway URL resolution order (stated in the agent-team-gateway-url
  docstring): the GOMODEL_GATEWAY_URL override, then
  https://ai.khalidrafi.tech, then localhost:8080; only when nothing
  answers does CI boot its own gomodel. Ping contract: GET / answering
  404 or 200 means up.
- agent-team/ is live state, not examples. CONTROL.org is read by CI
  every run; mailbox/ is a frozen archive (never write there);
  agent-team/CANDIDATES.org is a symlink to ../templates/CANDIDATES.org.
- Tests are offline and deterministic by design. The bridge suite stubs
  the HTTP, auth, and autopilot seams. Do not add network calls to the
  suite.
- Compiled "*.elc" files in a working tree are ignored build artifacts
  (.gitignore); they are not tracked.
- The ci/ submodule pin matters: the harness Dockerfile and the law
  scripts come from it. CI checks out with submodules recursive.

## Developing

Requirements: Emacs 28.1+ and curl (for gateway calls). On CI, Emacs is
installed with "sudo apt-get install emacs-nox".

Minimal test run (from README.org):

    emacs -Q --batch -L . -L tests -l tests/agent-team-test.el \
      --eval '(ert-run-tests-batch-and-exit "agent-team")'

Full local gate (mirrors the CI test job):

    for f in agent-team.el agent-team-sessions.el agent-team-clock.el \
             agent-team-chat.el agent-team-bridge.el agent-team-live.el; do
      emacs -Q --batch -L . --eval \
        "(unless (byte-compile-file \"$f\") (kill-emacs 1))"
    done
    emacs -Q --batch -L . -L tests -l tests/agent-team-test.el \
      -l tests/agent-team-chat-test.el \
      -l tests/agent-team-bridge-test.el \
      -l tests/agent-team-live-test.el \
      --eval '(ert-run-tests-batch-and-exit "agent-team")'

CI lives in .github/workflows/ci.yml: jobs test, probe, harness, turn,
finalize, in that order, on cron '17 1,5,9,13,17,21 * * *' and on
workflow_dispatch.

Branch law: ai/main is the integration trunk (the "team-truth" branch).
CI seats do their work on ai/turn-* branches; the chain's finalize
merges those behind the test gate. Seats never push ai/main directly.
Lead-owned files, which seats may read and cite but never edit:
.github/workflows/*, .github/scripts/*, agent-team/CONTROL.org, and
.gitattributes.

Submodule: update with "git submodule update --init --recursive" (ci
points at khaalidrafi/agent-team-ci, branch main).

License: GPL-3.0-or-later.
