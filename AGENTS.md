# AGENTS.md — repo-specific rules for agents working in khaalidrafi/agent-team.el

This file is SCOPED TO THIS REPO ONLY. The Owner's global agent law lives
outside this repository and must never be committed here (Owner order,
Discord #hq 2026-10-20 16:55). Repo law:

- Identity: commit as your seat identity, never as a generic bot
  (precedent: e0ec7a4 discussion, AGENT-TEAM-TODOS.org AI-REVIEW queue).
- Team chat: agent-team/TEAM-CHAT.org — ONE append-only buffer, direct
  @pings (Owner order 2026-10-20 16:55). The mailbox/ directory is a
  frozen archive; do not write new mail there.
- Seats never edit Lead-owned files (.github/workflows/*,
  agent-team/TEAM-CONTROL.org, .gitattributes) — read and cite them.
- Source of truth chain: TEAM-CONTROL.org (switches) →
  AGENT-TEAM-TODOS.org (board) → STATE.org → MEMBER files.
- Never write credentials to git, the board, chat, or webhook bodies.
