# FR — dsh-superagent: best ideas for the chain

GitHub issue: khaalidrafi/agent-team.el#3 — issue-body edit is blocked by PAT scope (Issues:write missing), so THIS FILE is the live text (REV 2) and supersedes the issue body.

---

Owner order 2026-11-02 #hq: learn `dsh-superagent` (starting at deepseek-ai on GH) and add the best ideas to agent-team.
REV 2 per Owner correction: no pilot on a repo I don't lead — org-learn removed (it is the Lead's seat since the 2026-11-01 addendum). The ideas land on the chain I run: agent-team.el core + teamify kit + the cron loop.

## Source (verified, docs 000–003 read)
* github.com/deepseek-ai/dsh-superagent-prototype — MIT, TypeScript on DeepSeek Harness (DSH), self-declared research prototype, last commit 2026-10-31, ~3.9k stars. Docs: 000 philosophy, 001 domain model, 002 authorization, 003 execution (000–008 exist).
* Philosophy: "take as little human attention as possible, and give as much value as possible" — act only when asked or when a written Policy rule allows; speak only when a person must act or can use a result; stop by impact, not effort; report honestly.

## The pattern (as the docs actually specify it)
Source → Trigger → Thread → Eval → Decision → Mandate → Ticket → Assignment → Executor → Channel.
* Eval has two layers: a deterministic gate (admission table: explicit / inferred / not admitted) then model assessment. Decisions: accept / stop / ignore / unavailable.
* Mandate is immutable: only accept creates it, a person's stop withdraws it, failed revalidation revokes it. Wider scope = a new Ticket.
* Ticket owns its own state (open → ended → resumed by a person's message); it never follows the Executor session's state — Assignments (pending → running → ended) are replaceable.
* Reports use a fixed vocabulary: progress / waiting / ready / blocked / failed / dropped; questions to humans are a structured Attention field, never inferred from free text.
* Concurrency keeps one extra slot reserved so a person's message always wakes their ticket — "new work cannot prevent a person from continuing an existing Ticket."
* Stored work: decisions are stored first, done after; per-ticket ordered outbound queue; retries with backoff (delivery 2s→1m, channel 5s→300s).
* Subscription fan-out: later human messages on a followed thread reach the live ticket without re-Eval; an ended ticket resumes under the SAME mandate only if it revalidates against the current Policy.
* Auto-merge guardrails: only the ticket's own PR, ready, approvals cover head, <200 changed lines, withdrawn before any new push, never merged as the agent's own account.
* Accept modes per source: off / observe (record "would accept") / auto — progressive trust, start narrow.

## Best ideas → agent-team (mapped, in landing order)
1. **Gate before work** — deterministic admission (kill-switch, NOT-TOUCH paths, sender allow-list, strength) runs BEFORE the seat's model acts. Kill-switch already sits at step 2 of the cron RUN; allow-list + strength are the addition.
2. **Structured reports** — CHAT.org seat reports adopt progress/waiting/ready/blocked/failed/dropped; Owner-bound questions become structured Attention rows, one concrete question at a time.
3. **Human-reserved slot** — an Owner/human message on CHAT.org always outranks queued repo work in the same tick (mirror of the reserved-slot rule).
4. **Record-only dial** — new CONTROL.org switch `#+ACCEPT-MODE: off|observe|auto`; every newly teamified repo starts in observe for N ticks ("would accept" logged, nothing written).
5. **Mandate line** — each turn writes an immutable mandate line on its TODOS.org row (repo, allowed paths, max commits, matched rule, CONTROL version). The one-line audit answer to "why did the agent do this?".
6. **Durable outbox** — board/CHAT.org write happens FIRST, push after; a failed push retries with backoff and is never silently dropped (mirrors stored-work).
7. **Resume under mandate** — a follow-up on a CHAT.org thread resumes a DONE row only if its mandate revalidates against current CONTROL.org; else it goes back through the gate.
8. **Merge guardrails** — Lead merge law: only the ticket's own PR, <200 changed lines, approvals current, withdrawn before any new push, never merged as the seat's own account.
9. **Ticket ≠ session (largest)** — the TODOS.org row owns work state; a stalled seat is re-assigned under the same mandate without re-planning (formalizes the STALL law).

## Landing
* 1–4 are text law → cron prompt + kit TEAMIFY templates. No code.
* 5–8 need a CONTROL.org/TODOS.org schema bump (agent-team.el elisp).
* 9 is the big one — chain-runner change; separate FR once 1–4 prove out.

Status: waiting on Owner go for 1–4.
