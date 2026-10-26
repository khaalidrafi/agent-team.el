;;; agent-team-test.el --- tests for agent-team  -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'agent-team)
(require 'agent-team-clock)

(ert-deftest agent-team-format-header ()
  (should (equal
           (agent-team--format-header
            "DISPATCH" 7 "web" "fix-login" "Fix kimi login" "EM — Kimi-K2.6 @ kimi.ai"
            "Site Reliability Engineer — Qwen3.8-Flash @ Qoder" "P1" 2)
           "DISPATCH #7 — web/fix-login: Fix kimi login
FROM: EM — Kimi-K2.6 @ kimi.ai
TO: Site Reliability Engineer — Qwen3.8-Flash @ Qoder
PRIORITY: P1 · ORDER: 2")))

(ert-deftest agent-team-bump-counter ()
  (should (equal (agent-team--bump-counter "# DISPATCH counter: 41")
                 "# DISPATCH counter: 42"))
  (should (equal (agent-team--bump-counter "nothing here") nil)))

(ert-deftest agent-team-next-status ()
  (should (equal (agent-team--next-status "PROGRESS") "BLOCKED"))
  (should (equal (agent-team--next-status "BLOCKED") "REVIEW"))
  (should (equal (agent-team--next-status "REVIEW") "DONE"))
  ;; DONE is terminal: stays DONE (only the EM re-opens via TODO)
  (should (equal (agent-team--next-status "DONE") "DONE"))
  (should (equal (agent-team--next-status "UNKNOWN") nil)))

(ert-deftest agent-team-parse-members ()
  (let ((tmp (make-temp-file "members" nil ".org"
"* Build Engineer — GLM-5.3 @ chat.z.ai
  - owns: guix packages
* Platform Engineer — Qwen3.8-Flash @ Qoder
")))
    (should (equal (agent-team--parse-members tmp)
                   '(("Platform Engineer" . "Qwen3.8-Flash@Qoder")
                     ("Build Engineer" . "GLM-5.3@chat.z.ai"))))))

;; ci/01: the board drifted into three id grammars and the old regexp matched
;; only the compact one, silently dropping every spaced heading.  The parser
;; now normalizes instead of rejecting.
(ert-deftest agent-team-parse-members-tolerates-id-grammars ()
  (let ((tmp (make-temp-file "members" nil ".org"
"* Team Lead — qwen3.8-flash@qoder (ACTING, OUTGOING)
* Director of Engineering — glm-5.3-flash @ chat.z.ai
* Software Engineer — groq/qwen3.8-27b @opencode-codespaces
  - duties: features
* QA Engineer — deepseek-v4.1-flash@ opencode/local
* Intern bench (no-data to intern, never rejected)
* WEB MODE (box going down) — who survives the shutdown
")))
    (should (equal (agent-team--parse-members tmp)
                   '(("QA Engineer" . "deepseek-v4.1-flash@opencode/local")
                     ("Software Engineer" . "groq/qwen3.8-27b@opencode-codespaces")
                     ("Director of Engineering" . "glm-5.3-flash@chat.z.ai")
                     ("Team Lead" . "qwen3.8-flash@qoder"))))))

(ert-deftest agent-team-normalize-member-id ()
  (should (equal (agent-team--normalize-member-id "GLM-5.3 @ chat.z.ai")
                 "GLM-5.3@chat.z.ai"))
  (should (equal (agent-team--normalize-member-id "glm-5.3-flash@zai (restored)")
                 "glm-5.3-flash@zai"))
  ;; not a member id: no "@" (this is what keeps prose headings out of the roster)
  (should (eq (agent-team--normalize-member-id "who survives the shutdown") nil))
  (should (eq (agent-team--normalize-member-id "") nil)))

(ert-deftest agent-team-init-scaffolds ()
  (let ((tmp (make-temp-file "proj" t)))
    (agent-team-init tmp)
    (should (file-exists-p (expand-file-name "agent-team/TODOS.org" tmp)))
    (should (file-exists-p (expand-file-name "agent-team/MEMBERS.org" tmp)))
    (should (file-exists-p (expand-file-name "STATE.org" tmp)))
    ;; second run must not clobber
    (should-error (agent-team-init tmp))))

;;; Sessions bridge (agent-team-sessions.el) — pure parsers, no agent-org
;;; and no live agents required.

(require 'agent-team-sessions)

(ert-deftest agent-team-sessions-control ()
  (let ((ctl (agent-team-sessions--control
              "#+OBJECTIVE: mesh/01 peer mesh proof
#+OBJECTIVE-STATE: OPEN
#+KILL-SWITCH: OFF
#+TURN: zai/glm-4.7-flash@opencode (Quality Assurance Engineer)
#+STALL-COUNT: 3")))
    (should (equal (plist-get ctl :objective) "mesh/01 peer mesh proof"))
    (should (equal (plist-get ctl :state) "OPEN"))
    (should (equal (plist-get ctl :kill) "OFF"))
    (should (equal (plist-get ctl :turn)
                   "zai/glm-4.7-flash@opencode (Quality Assurance Engineer)"))
    (should (equal (plist-get ctl :stall) "3")))
  ;; OBJECTIVE must not leak into OBJECTIVE-STATE or vice versa
  (should (equal (plist-get (agent-team-sessions--control
                             "#+OBJECTIVE-STATE: COMPLETE\n#+OBJECTIVE: x")
                            :state)
                 "COMPLETE")))

(ert-deftest agent-team-sessions-exchanges ()
  (let ((body "#+TITLE: Goose — agent-team
:PROPERTIES:
:ID: 7c1f-1234
:END:
* verify the mailbox bus

 #+ATTR_TEXINFO: :author Qwen3.8-27B
 #+begin_quote
  Grammar verified, cite agent-team/mailbox/PROTOCOL.org:30.
 #+end_quote
  :tool:
  - COMPLETE read PROTOCOL.org

* dispatch QA on the union merge

 #+ATTR_TEXINFO: :author Qwen3.8-27B
 #+begin_quote
  Done.
 #+end_quote

;; queue
* NEXT
* PROMPT
"))
    (let ((cases (agent-team-sessions--exchanges body)))
      (should (= (length cases) 2))
      (should (equal (car (nth 0 cases)) "verify the mailbox bus"))
      (should (equal (cdr (nth 0 cases)) "Qwen3.8-27B"))
      (should (equal (car (nth 1 cases)) "dispatch QA on the union merge")))
    ;; limit keeps the NEWEST exchanges, oldest first
    (let ((cases (agent-team-sessions--exchanges body 1)))
      (should (equal (mapcar #'car cases) '("dispatch QA on the union merge"))))
    ;; queue headings never become exchanges
    (should (null (agent-team-sessions--exchanges "* NEXT\n* PROMPT\n")))))

(ert-deftest agent-team-sessions-mailbox ()
  (let* ((mail "#+TITLE: INBOX — Team Lead

* MSG [2026-10-20 Tue 15:04] lead -> principal-engineer :dispatch:
  :PROPERTIES:
  :STATUS: READ
  :END:
  OBJECTIVE mesh/01. Verify the bus.

* MSG [2026-10-20 Tue 15:46] quality-assurance-engineer -> lead :report:
  :PROPERTIES:
  :STATUS: UNREAD
  :END:
  RESULT: DONE
  EVIDENCE: grammar ok
")
         (parsed (agent-team-sessions--mailbox mail)))
    (should (= (nth 0 parsed) 1))          ; one UNREAD
    (should (= (nth 1 parsed) 2))          ; two messages total
    (should (equal (nth 0 (nth 2 parsed)) "quality-assurance-engineer"))
    (should (equal (nth 1 (nth 2 parsed)) "lead"))
    (should (equal (nth 2 (nth 2 parsed)) "RESULT: DONE")))
  (should (equal (agent-team-sessions--mailbox "#+TITLE: INBOX — empty\n")
                 '(0 0 nil))))

(ert-deftest agent-team-sessions-board-tasks ()
  (let ((tasks (agent-team-sessions--board-tasks
                "#+TITLE: BOARD
* HEADER not a task
** DONE old item
** PROGRESS [2026-10-20] demo/01 turn-system demo :demo/01:
** TODO review the sessions bridge :sessions/01:
* MSG [x] a -> b :report:
")))
    (should (= (length tasks) 2))
    (should (equal (car (nth 0 tasks)) "PROGRESS"))
    (should (string-prefix-p "[2026-10-20] demo/01" (cdr (nth 0 tasks))))
    (should (equal (car (nth 1 tasks)) "TODO"))))

(ert-deftest agent-team-sessions-registry ()
  (let ((agent-team-sessions-registry nil)
        (buf (get-buffer-create " =Goose:test [1]=")))
    (agent-team-sessions-register "principal-engineer" buf)
    (should (eq (agent-team-sessions--session-buffer "principal-engineer") buf))
    ;; re-register replaces, never duplicates
    (agent-team-sessions-register "principal-engineer" buf)
    (should (= (length agent-team-sessions-registry) 1))
    (agent-team-sessions-forget "principal-engineer")
    (should (null (agent-team-sessions--session-buffer "principal-engineer")))
    (kill-buffer buf)))

(ert-deftest agent-team-env-shape-p ()
  (should (agent-team--env-shape-p "QODER_PERSONAL_ACCESS_TOKEN"))
  (should-not (agent-team--env-shape-p "DISCORD_WEBHOOK_TEAM"))
  (should (agent-team--env-shape-p "GOMODEL_MASTER_KEY"))
  (should (agent-team--env-shape-p "OPENROUTER_API_KEY"))
  (should (agent-team--env-shape-p "LARK_WEBHOOK_PRINCIPAL_ENGINEER"))
  (should (not (agent-team--env-shape-p "PATH")))
  (should (not (agent-team--env-shape-p "HOME")))
  (should (not (agent-team--env-shape-p "MY_SECRET_THING")))
  (should (not (agent-team--env-shape-p "qoder_token"))))

(ert-deftest agent-team-control-apply-replaces ()
  (let* ((in "#+TITLE: control\n#+TURN: seat-a\n#+STALL-COUNT: 3\n\n* Notes\n")
         (out (agent-team--control-apply in "TURN" "seat-b")))
    (should (string-match-p "^\\#\\+TURN: seat-b$" out))
    (should-not (string-match-p "seat-a" out))
    (should (string-match-p "^\\#\\+STALL-COUNT: 3$" out))))

(ert-deftest agent-team-control-apply-inserts-before-headline ()
  (let* ((in "#+TITLE: control\n\n* Notes\nbody\n")
         (out (agent-team--control-apply in "KILL-SWITCH" "ON")))
    (should (string-match-p "^\\#\\+KILL-SWITCH: ON$" out))
    ;; the line lands in the header block, never after the first headline
    (should (< (string-match "^\\#\\+KILL-SWITCH" out)
               (string-match "^\\* Notes" out)))))

(ert-deftest agent-team-control-apply-appends-when-no-headline ()
  (let* ((in "#+TITLE: control\n")
         (out (agent-team--control-apply in "OBJECTIVE" "burn the board")))
    (should (string-match-p "^\\#\\+OBJECTIVE: burn the board$" out))))

(ert-deftest agent-team-chat-format ()
  (let* ((msg (agent-team--chat-format
               "platform-engineer" "@lead" "report"
               "RESULT: DONE\nEVIDENCE: file:12" "[2026-10-21 Wed 09:00 UTC]"))
         (lines (split-string msg "\n")))
    ;; headline carries the FROM (Owner law: headings contain FROM content)
    (should (string-prefix-p "* MSG platform-engineer -> @lead :report:" (nth 0 lines)))
    (should (string-match-p ":msg:platform-engineer:lead:report:" (nth 0 lines)))
    (should (equal ":PROPERTIES:" (nth 1 lines)))
    (should (equal ":FROM: platform-engineer" (nth 2 lines)))
    (should (equal ":TO: lead" (nth 3 lines)))
    (should (equal ":KIND: report" (nth 4 lines)))
    (should (equal ":WHEN: [2026-10-21 Wed 09:00 UTC]" (nth 5 lines)))
    (should (equal ":END:" (nth 6 lines)))
    ;; body lines indented two spaces
    (should (equal "  RESULT: DONE" (nth 7 lines)))
    (should (equal "  EVIDENCE: file:12" (nth 8 lines)))))

;; --- live team chat viewer (Owner order 2026-10-21 09:16Z: view team chat
;; live on Emacs on Android) — offline tests, no network. ---

(ert-deftest agent-team-chat-url-builders ()
  ;; public repo → anonymous raw URL (Android: no credentials needed)
  (should (equal
           (agent-team-chat--url "khaalidrafi/agent-team.el" "ai/main"
                                 "agent-team/TEAM-CHAT.org" nil)
           "https://raw.githubusercontent.com/khaalidrafi/agent-team.el/ai/main/agent-team/TEAM-CHAT.org"))
  ;; private repo → Contents API with the raw-media Accept + bearer
  (should (equal
           (agent-team-chat--url "o/r" "b" "p/a.org" "tok")
           "https://api.github.com/repos/o/r/contents/p/a.org?ref=b"))
  (should (equal (cdr (assoc "Authorization" (agent-team-chat--headers "tok")))
                 "Bearer tok"))
  ;; anonymous mode: NO auth headers — but a UA always rides along
  (should (null (assoc "Authorization" (agent-team-chat--headers nil))))
  (should (null (assoc "Accept" (agent-team-chat--headers nil))))
  (should (assoc "User-Agent" (agent-team-chat--headers nil))))

(ert-deftest agent-team-chat-msg-count ()
  (should (= (agent-team-chat--msg-count
              "#+TITLE: TEAM-CHAT.org
* MSG lead -> @release-engineer :dispatch:      :msg:lead:release-engineer:dispatch:
* MSG release-engineer -> @lead :report:        :msg:release-engineer:lead:report:
* MSG lead -> @all :note:                       :msg:lead:all:note:")
             3))
  (should (= (agent-team-chat--msg-count "no messages yet") 0)))

(ert-deftest agent-team-chat-render-follows-tail-and-highlights ()
  (let ((buf (get-buffer-create " *agent-team chat render test*")))
    (unwind-protect
        (progn
          (agent-team-chat--render
           buf "* MSG a -> @b :note:  :msg:a:b:note:\n:PROPERTIES:\n:FROM: a\n:END:\n  hello\n")
          (with-current-buffer buf
            (should (derived-mode-p 'org-mode))
            (should agent-team-chat-live-mode)
            (should buffer-read-only)
            (should (= (agent-team-chat--msg-count (buffer-string)) 1))
            (should (= (point) (point-max)))     ; follows tail from empty
            (should (string-match-p "ok" agent-team-chat--status)))
          ;; append-only growth: tail gets the new face, point follows
          (agent-team-chat--render
           buf "* MSG a -> @b :note:  :msg:a:b:note:\n:PROPERTIES:\n:FROM: a\n:END:\n  hello\n* MSG c -> @d :report:  :msg:c:d:report:\n  RESULT: DONE\n")
          (with-current-buffer buf
            (should (= (agent-team-chat--msg-count (buffer-string)) 2))
            (should (= (point) (point-max)))
            (should (overlays-in 1 (point-max)))
            ;; reader scrolled up: render must NOT yank them to the tail
            (goto-char (point-min))
            (agent-team-chat--render buf (buffer-string))
            (should (= (point) (point-min)))))
      (kill-buffer buf))))

(ert-deftest agent-team-chat-non-growth-resets ()
  ;; A union-merge reordering is not append-only: no new-face overlay, view
  ;; stays sane (this is the fallback path, not the normal one).
  (let ((buf (get-buffer-create " *agent-team chat reorder test*")))
    (unwind-protect
        (progn
          (agent-team-chat--render buf "one\n")
          (agent-team-chat--render buf "zero\none\n")
          (with-current-buffer buf
            (should (string-match-p "zero" (buffer-string)))
            (should buffer-read-only)))
      (kill-buffer buf))))

(ert-deftest agent-team-chat-timer-lifecycle ()
  (let ((buf (get-buffer-create " *agent-team chat timer test*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq agent-team-chat--repo "o/r" agent-team-chat--branch "b"
                  agent-team-chat--path "p" agent-team-chat--busy t)
            (agent-team-chat-live-mode 1)
            (setq agent-team-chat--timer
                  (run-at-time 1000 1000 #'agent-team-chat--tick buf))
            (should agent-team-chat--timer)
            ;; teardown cancels and clears
            (agent-team-chat--teardown)
            (should (null agent-team-chat--timer)))
          ;; tick on a dead buffer is a no-op, never an error
          (kill-buffer buf)
          (should (null (agent-team-chat--tick buf))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest agent-team-chat-failed-keeps-content ()
  (let ((buf (get-buffer-create " *agent-team chat fail test*")))
    (unwind-protect
        (progn
          (agent-team-chat--render buf "* MSG a -> @b :note:\n")
          (agent-team-chat--failed buf "HTTP 404 — no chat at this repo@branch yet")
          (with-current-buffer buf
            (should (string-match-p "MSG a" (buffer-string))) ; last good kept
            (should (= agent-team-chat--errs 1))
            (should (null agent-team-chat--busy))))
      (kill-buffer buf))))

;;; One-command project setup (Owner order 2026-10-21 10:12Z) ----------------

(ert-deftest agent-team-fill-slots-and-unfilled ()
  (let* ((filled (agent-team--fill-slots
                  "repo={{REPO}} cron='{{CRON}}' file={{WORKFLOW_FILE}}"
                  '(("REPO" . "o/r") ("CRON" . "17 * * * *") ("WORKFLOW_FILE" . "agent-team.yml")))))
    (should (string-match-p "repo=o/r" filled))
    (should (string-match-p (regexp-quote "cron='17 * * * *'") filled))
    (should (null (agent-team--unfilled-slots filled))))
  ;; a missing slot stays visible, not silently dropped
  (let ((part (agent-team--fill-slots "{{A}} {{B}}" '(("A" . "x")))))
    (should (equal '("B") (agent-team--unfilled-slots part)))))

(ert-deftest agent-team-template-slots-all-covered ()
  "Every {{TOKEN}} in templates/agent-team.yml is fillable by
`agent-team--default-slots' — the template and the defaults can never
drift apart (this is the setup command's core invariant)."
  (let* ((root (make-temp-file "at-tpl-" t))
         (tpl (agent-team--template "agent-team.yml"))
         (slots (agent-team--default-slots root "khaalidrafi/testrepo"))
         (filled (agent-team--fill-slots tpl slots)))
    (should (equal '() (agent-team--unfilled-slots filled)))
    ;; the fill is project-aware: project name, repo slug (bare slug is
    ;; the canonical form); no chat-mirror secret since 2026-10-26
    ;; (Discord retired after Telegram)
    (should (string-match-p "testrepo — CI agent-team chain" filled))
    (should-not (string-match-p "DISCORD_WEBHOOK" filled))
    ;; engine defaults ride inside: gomodel health step + Jev judgment
    (should (string-match-p "GoModel lane health" filled))
    (should (string-match-p "Jev judgment" filled))
    (should (string-match-p "workflows/agent-team.yml/dispatches" filled))
    (delete-directory root t)))

(ert-deftest agent-team-detect-gate-pytest ()
  (let* ((root (make-temp-file "at-gate-" t))
         (py (expand-file-name "pyproject.toml" root)))
    (write-region "[project]\nname = \"x\"\n" nil py)
    (let ((gate (agent-team--detect-gate root)))
      (should (equal "pytest" (plist-get gate :name)))
      (should (string-match-p "python -m pytest -q" (plist-get gate :run)))
      (should (string-match-p "python -m pytest -q" (plist-get gate :cmd))))
    (delete-directory root t)))

(ert-deftest agent-team-detect-gate-fallback-is-loud ()
  (let* ((root (make-temp-file "at-gate2-" t))
         (gate (agent-team--detect-gate root)))
    (should (string-match-p "PLACEHOLDER" (plist-get gate :name)))
    (should (string-match-p "exit 1" (plist-get gate :cmd)))
    (delete-directory root t)))

(ert-deftest agent-team-repo-slug-parses-origin ()
  (let* ((root (make-temp-file "at-slug-" t))
         (default-directory root))
    (call-process "git" nil nil nil "init" "-q" "-b" "ai/main" ".")
    (call-process "git" nil nil nil "remote" "add" "origin"
                  "https://github.com/khaalidrafi/admincraft.git")
    (should (equal "khaalidrafi/admincraft" (agent-team--repo-slug root)))
    (delete-directory root t)))

(ert-deftest agent-team-scaffold-writes-the-chain ()
  (let* ((root (make-temp-file "at-scaf-" t))
         (report (agent-team--scaffold-ci root "khaalidrafi/testrepo"))
         (wf (expand-file-name ".github/workflows/agent-team.yml" root))
         (sg (expand-file-name ".github/scripts/secret-guard.sh" root))
         (oc (expand-file-name "docker/harness/opencode.json" root)))
    ;; the chain lands, fully filled
    (should (file-exists-p wf))
    (let ((yml (with-temp-buffer (insert-file-contents wf) (buffer-string))))
      (should (equal '() (agent-team--unfilled-slots yml)))
      ;; the fill is slug-aware (bare slug is the canonical form; the
      ;; full owner/slug pair rides github.repository at run time)
      (should (string-match-p "testrepo — CI agent-team chain" yml))
      (should (string-match-p "secrets.GROQ_API_KEY" yml))
      (should-not (string-match-p "TELEGRAM_" yml))
      (should-not (string-match-p "api.telegram.org" yml)))
    ;; guard + pkg configs land; the Dockerfile scaffolds — and NO
    ;; AGENTS.md (repo root OR harness law invention) is ever created
    (should-not (file-exists-p (expand-file-name "AGENTS.md" root)))
    (should-not (file-exists-p
                 (expand-file-name "docker/harness/AGENT-LAW.md" root)))
    (should (file-exists-p sg))
    (should (file-exists-p oc))
    (should (file-exists-p (expand-file-name "docker/harness/Dockerfile" root)))
    ;; report is (FILE . ACTION) pairs naming what was written
    (should (>= (length report) 5))
    (delete-directory root t)))

(ert-deftest agent-team-scaffold-never-clobbers-project-files ()
  "The harness Dockerfile is per-project: setup writes it ONLY when
missing — an existing project's file is never clobbered.  And NO
AGENTS.md is ever created or rewritten: a repo's own repo-root AGENTS.md
stays untouched (Owner 2026-10-21 revert order — it IS the CI law bake
source), and no AGENT-LAW.md invention exists."
  (let* ((root (make-temp-file "at-scaf2-" t))
         (agents (expand-file-name "AGENTS.md" root))
         (df (expand-file-name "docker/harness/Dockerfile" root)))
    (make-directory (file-name-directory df) t)
    (write-region "# the project's own law — DO NOT TOUCH\n" nil agents)
    (write-region "FROM alpine\n" nil df)
    (agent-team--scaffold-ci root "khaalidrafi/testrepo")
    (should (string-match-p
             "the project's own law"
             (with-temp-buffer (insert-file-contents agents) (buffer-string))))
    (should (string-match-p
             "FROM alpine"
             (with-temp-buffer (insert-file-contents df) (buffer-string))))
    ;; but the workflow itself IS written when absent
    (should (file-exists-p (expand-file-name ".github/workflows/agent-team.yml" root)))
    (delete-directory root t))
  ;; a project with NO AGENTS.md and NO variable stays without one —
  ;; no AGENT-LAW.md invention either (Owner: "No need for a AGENT-LAW.md")
  (let* ((root (make-temp-file "at-scaf3-" t)))
    (agent-team--scaffold-ci root "khaalidrafi/testrepo")
    (should-not (file-exists-p (expand-file-name "AGENTS.md" root)))
    (should-not (file-exists-p
                 (expand-file-name "docker/harness/AGENT-LAW.md" root)))
    ;; the Dockerfile scaffold points the user at the variable instead
    (should (string-match-p
             "agent-team-global-agents-md"
             (with-temp-buffer
               (insert-file-contents
                (expand-file-name "docker/harness/Dockerfile" root))
               (buffer-string))))
    (delete-directory root t)))

(ert-deftest agent-team-scaffold-transports-user-global-law ()
  "With `agent-team-global-agents-md' pointed at the USER's global
AGENTS.md: a project without its own gets the file transported
byte-identical (docker/harness/AGENTS.md) and a Dockerfile that bakes
it into the verified global config paths; a project WITH its own
AGENTS.md keeps its own file as the bake source and nothing is
transported (Owner 2026-10-21: the user's global law via a variable)."
  (let* ((userlaw (make-temp-file "user-agents-md-"))
         (root (make-temp-file "at-scaf4-" t))
         (law-dst (expand-file-name "docker/harness/AGENTS.md" root))
         (df (expand-file-name "docker/harness/Dockerfile" root)))
    (write-region "# the USER's global law — byte-identical transport only\n"
                  nil userlaw)
    (let ((agent-team-global-agents-md userlaw))
      (agent-team--scaffold-ci root "khaalidrafi/testrepo"))
    (should (file-exists-p law-dst))
    (should (string-match-p
             "byte-identical transport only"
             (with-temp-buffer (insert-file-contents law-dst) (buffer-string))))
    (should (string-match-p
             "COPY docker/harness/AGENTS.md /home/agent/.config/opencode/AGENTS.md"
             (with-temp-buffer (insert-file-contents df) (buffer-string))))
    ;; byte-identical: same size, same content
    (should (= (nth 7 (file-attributes userlaw))
               (nth 7 (file-attributes law-dst))))
    (delete-directory root t))
  ;; a project WITH its own AGENTS.md wins: no transport, repo-root bake
  (let* ((userlaw (make-temp-file "user-agents-md-"))
         (root (make-temp-file "at-scaf5-" t))
         (df (expand-file-name "docker/harness/Dockerfile" root)))
    (write-region "# user global law (must NOT be transported here)\n" nil userlaw)
    (write-region "# the project's own AGENTS.md\n"
                  nil (expand-file-name "AGENTS.md" root))
    (let ((agent-team-global-agents-md userlaw))
      (agent-team--scaffold-ci root "khaalidrafi/testrepo"))
    (should-not (file-exists-p
                 (expand-file-name "docker/harness/AGENTS.md" root)))
    (should (string-match-p
             "COPY AGENTS.md /home/agent/.config/opencode/AGENTS.md"
             (with-temp-buffer (insert-file-contents df) (buffer-string))))
    (delete-directory root t)))

(ert-deftest agent-team-prompt-begins-with-global-law ()
  "The teamify prompt BEGINS with the user's global AGENTS.md when the
variable points at it (web chats start under the user's own global law,
Owner 2026-10-21); without the variable the prompt starts at the
TEAM-MAKING header as before."
  (let* ((userlaw (make-temp-file "user-agents-md-"))
         prompt)
    (write-region "# USER GLOBAL LAW\n- be excellent to each other\n"
                  nil userlaw)
    (let ((agent-team-global-agents-md userlaw))
      (agent-team-teamify-prompt
       "https://github.com/khaalidrafi/testrepo" "test"
       "none" "<<<FILL>>>" nil)
      (setq prompt (with-current-buffer "*agent-team prompt*"
                     (buffer-string))))
    (let ((case-fold-search nil))   ; the law header is UPPERCASE — match it
      (should (string-prefix-p "#+TITLE: TEAM-MAKING PROMPT" prompt))
      ;; the law block opens the CONTENT — it sits before HOW TO USE
      (should (< (string-match "\\* GLOBAL AGENTS.MD — the user's global law"
                              prompt)
                 (string-match
                  (regexp-quote "* HOW TO USE (Director)") prompt)))
      (should (string-match-p "be excellent to each other" prompt))
      (should (string-match-p "TEAM CI (how the chain runs" prompt)))
  ;; no variable → no law block, prompt starts at the header
  (let ((agent-team-global-agents-md nil)
        prompt)
    (agent-team-teamify-prompt
     "https://github.com/khaalidrafi/testrepo" "test"
     "none" "<<<FILL>>>" nil)
    (setq prompt (with-current-buffer "*agent-team prompt*"
                   (buffer-string)))
    (let ((case-fold-search nil))
      (should (string-prefix-p "#+TITLE: TEAM-MAKING PROMPT" prompt))
      (should-not (string-match-p "GLOBAL AGENTS\\.MD" prompt))))))

(ert-deftest agent-team-team-ci-brief-in-prompt ()
  "The teamify prompt carries the TEAM CI operating block (the Owner
gets the chain's manual with every prompt, not just the team laws)."
  (let ((prompt (progn
                  (agent-team-teamify-prompt
                   "https://github.com/khaalidrafi/testrepo" "test"
                   "none" "<<<FILL>>" nil)
                  (with-current-buffer "*agent-team prompt*"
                    (buffer-string)))))
    (should (string-match-p "TEAM CI (how the chain runs" prompt))
    (should (string-match-p "SELF-DISPATCH while the objective is" prompt))
    (should (string-match-p "khaalidrafi/testrepo" prompt))
    (should (string-match-p
             "PART 1 — TEAMIFY: the task (existing project, no team setup)"
             prompt))))

(ert-deftest agent-team-prompt-carries-candidates-seed ()
  "The teamify prompt carries the CANDIDATES.org inventory as the SEED
for agent-team/CANDIDATES.org (COMMON's MODELS + STAFFING laws point at
that file — a fresh teamify must not dangle), the FILE TARGETS define
it, and no raw {{SLOT}} token or wrong-repo path survives into the
prompt (Owner 2026-10-21: read the templates well, then make the
prompt)."
  (let ((prompt (progn
                  (agent-team-teamify-prompt
                   "https://github.com/khaalidrafi/testrepo" "test"
                   "none" "<<<FILL>>>" nil)
                  (with-current-buffer "*agent-team prompt*"
                    (buffer-string)))))
    ;; the candidates file is Fetched, never inlined: a prompt snapshot
    ;; goes stale, so PART 3 lands the canonical file by URL + sanity
    ;; greps (no-dup law)
    (should (string-match-p
             "PART 3 — CANDIDATES FILE: land agent-team/CANDIDATES.org" prompt))
    (should (string-match-p
             "raw.githubusercontent.com/khaalidrafi/agent-team.el/ai/main/"
             prompt))
    (should (string-match-p
             "grep -m1 '^#[+]TITLE: CANDIDATES\\.org'" prompt))
    ;; the FILE TARGETS define the seed file (and the chat file);
    ;; TEAMIFY's own sections are demoted one level under PART 1, so the
    ;; targets live at three stars
    (should (string-match-p "\\*\\*\\* agent-team/CANDIDATES.org" prompt))
    (should (string-match-p "\\*\\*\\* agent-team/TEAM-CHAT.org" prompt))
    ;; the state file lives in agent-team/, never agent-org/ (typo law)
    (should (string-match-p "\\*\\*\\* agent-team/STATE.org" prompt))
    (should-not (string-match-p "agent-org/STATE" prompt))
    ;; no raw slot tokens leak into a built prompt
    (should-not (string-match-p "{{PAT}}" prompt))
    (should-not (string-match-p "{{[A-Z_]+}}" prompt))))

(ert-deftest agent-team-prompt-outline-is-well-ordered ()
  "The assembled prompt is a well-ordered outline, not a raw
concatenation: level-1 headings are exactly the six parts in order,
the mode layer nests under PART 1 with no stray level-1 headings
outside src blocks, src blocks are balanced, no template-file metadata
header and no build timestamp survives into the prompt (Owner
2026-10-21: \"Does it look well-ordered?\")."
  (let* ((agent-team-global-agents-md nil)
         (prompt (progn
                   (agent-team-teamify-prompt
                    "https://github.com/khaalidrafi/testrepo" "test"
                    "none" "<<<FILL>>>" nil)
                   (with-current-buffer "*agent-team prompt*"
                     (buffer-string)))))
    (let ((in-src nil) (tops ()))
      (dolist (line (split-string prompt "\n"))
        (cond ((string-match-p "^#[+]BEGIN_SRC" line) (setq in-src t))
              ((string-match-p "^#[+]END_SRC" line) (setq in-src nil))
              ((and (not in-src) (string-match-p "^\\* " line))
               (push (substring line 0 (min 40 (length line))) tops))))
      (setq tops (nreverse tops))
      (should (equal (length tops) 6))
      (should (string-prefix-p "* HOW TO USE (Director)" (nth 0 tops)))
      (should (string-prefix-p "* FILL BLOCK (Director)" (nth 1 tops)))
      (should (string-prefix-p "* TEAM CI (how the chain runs" (nth 2 tops)))
      (should (string-prefix-p "* PART 1 — TEAMIFY: the task" (nth 3 tops)))
      (should (string-prefix-p "* PART 2 — COMMON: the master law" (nth 4 tops)))
      (should (string-prefix-p "* PART 3 — CANDIDATES FILE" (nth 5 tops))))
    (with-temp-buffer
      (insert prompt)
      ;; src blocks balanced
      (should (= (how-many "^#[+]BEGIN_SRC" (point-min) (point-max))
                 (how-many "^#[+]END_SRC" (point-min) (point-max))))
      ;; no template-file metadata headers outside src blocks
      (let ((case-fold-search nil))
        (should-not (string-match-p "^#\\+TITLE: TEAMIFY\\.org" prompt))
        (should-not (string-match-p "^#\\+TITLE: COMMON\\.org" prompt))
        (should-not (string-match-p "^#\\+HOME:" prompt))
        (should-not (string-match-p "^#\\+RULE:" prompt))
        ;; no build timestamp line — the old "# ... on 2026-10-21 13:36 UTC"
        (should-not (string-match-p "built by agent-team.el from templates/ ("
                                    prompt))))))

(ert-deftest agent-team-prompt-common-section-order ()
  "COMMON's sections appear in the canonical reading order under
PART 2 — the board first, then resources, people, collaboration,
messaging, execution, laws, and SETUP last as the session-boot coda."
  (let* ((agent-team-global-agents-md nil)
         (prompt (progn
                   (agent-team-teamify-prompt
                    "https://github.com/khaalidrafi/testrepo" "test"
                    "none" "<<<FILL>>>" nil)
                   (with-current-buffer "*agent-team prompt*"
                     (buffer-string))))
         (order '("** WORKFLOW ("
                  "** MODELS"
                  "** GATEWAY AUTH ("
                  "** BRAINS AND BODIES"
                  "** STAFFING ("
                  "** HIRING PROTOCOL"
                  "** ROLE ATTACHMENT ("
                  "** TEAM LOOP ("
                  "** JEV ("
                  "** MESSAGE FORMAT SPEC ("
                  "** MESSAGE STANDARD"
                  "** TEAM CHAT ENTRY FORMAT ("
                  "** LARK ("
                  "** DISPATCH RULES"
                  "** LAWS"
                  "** MEMBER LAWS"
                  "** OUTPUT RULE"
                  "** HARD RULES"
                  "** SETUP ("))
         (last-pos -1))
    (let ((case-fold-search nil))
      (dolist (head order)
        (let ((pos (string-match (regexp-quote head) prompt)))
          (should pos)
          (should (> pos last-pos))
          (setq last-pos pos))))))

(ert-deftest agent-team-prompt-sketches-stay-byte-level ()
  "File-target sketches inside PART 1 live inside #+BEGIN_SRC org
blocks: their own headings never leak into the prompt outline — inside
or outside a src block — and the sketch bytes are exactly what the
template carries.  Sketch headline lines are Org comma-escaped
(,* headline; org-syntax pass 2026-10-26: a bare star-line at column 0
breaks org's parse of the block); the guard note in each FILE TARGETS
section is the un-escape law the teamify applies when writing the file."
  (let* ((agent-team-global-agents-md nil)
         (prompt (progn
                   (agent-team-teamify-prompt
                    "https://github.com/khaalidrafi/testrepo" "test"
                    "none" "<<<FILL>>>" nil)
                   (with-current-buffer "*agent-team prompt*"
                     (buffer-string))))
         (p1a (string-match "^\\* PART 1 — " prompt))
         (p1 (1+ (string-match "\n" prompt p1a)))  ; skip the heading line
         (p2 (string-match "^\\* PART 2 — " prompt))
         (leaks ()))
    (dolist (line (split-string (substring prompt p1 p2) "\n"))
      (cond ((string-match-p "^\\* " line)
             ;; a bare star-line leaks whether the parser sees it as an
             ;; outline heading (outside src) or a block-breaker (inside)
             (push line leaks))))
    (should (null leaks))
    ;; the un-escape law travels with every PRODUCED sketch: the five
    ;; file targets (TODOS/MEMBERS/STATE/TEAM.md/TEAM-CHAT) each carry
    ;; the guard note - the teamify knows ,* is an escaped headline,
    ;; not literal bytes.  TEAM-UPDATE.org is exempt: DoE-supplied, the
    ;; teamify never creates it.  Count pinned as the tripwire: a new
    ;; produced target without its note fails here.
    (should (= 5 (how-many "^File sketch (produce EXACTLY this skeleton"
                           (string-match "^\\* PART 1 — " prompt)
                           p2)))
    ;; the TODOS.org sketch is byte-exact inside its src block,
    ;; comma-escaped exactly as the template carries it
    (should (string-match-p
             "#\\+BEGIN_SRC org\n#\\+TITLE: TODOS.org — team board (single source of truth)\n#\\+TODO: TODO ONGOING PROGRESS BLOCKED REVIEW | DONE CANCELLED DEFERRED\n\n,\\* Board\n"
             prompt))
    ;; the chat sketch ends with a bare #+END_SRC on its own line
    (should (string-match-p
             ",\\* MSG <from> -> @<to> :<kind>:\n#\\+END_SRC\n" prompt))))

;;; TIME LAW clock (agent-team-clock.el) — pure transformer tests

(defconst agent-team-clock-test--board-plain
  "#+TITLE: TODOS.org — team board\n\n* Board\n\n** TODO wire the export pass\n   Some body line.\n\n** REVIEW half-reviewed thing\n   Body.\n\n** DONE already closed\n   Body.\n")

(defconst agent-team-clock-test--board-logbook
  "#+TITLE: TODOS.org\n\n* Board\n\n** PENDING paint the graph\n   :LOGBOOK:\n   - Note taken on [2026-10-20 Tue 10:00] by lead: seeded\n   :END:\n")

(defconst agent-team-clock-test--board-clocked
  "#+TITLE: TODOS.org\n\n* Board\n\n** ONGOING paint the graph\n   :LOGBOOK:\n   CLOCK: [2026-10-25 Sat 09:00 UTC]\n   :END:\n")

(ert-deftest agent-team-clock-ts-format ()
  (should (string-match-p
           "^\\[2[0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] \\(Mon\\|Tue\\|Wed\\|Thu\\|Fri\\|Sat\\|Sun\\) [0-9][0-9]:[0-9][0-9] UTC\\]$"
           (agent-team-clock--ts))))

(ert-deftest agent-team-clock-apply-flips-todo-and-inserts-drawer ()
  (let* ((res (agent-team-clock--apply
               agent-team-clock-test--board-plain nil nil
               "[2026-10-26 Mon 10:42 UTC]"))
         (text (car res)))
    (should res)
    (should (cdr res))
    (should (string-match-p "^\\*\\* ONGOING wire the export pass$" text))
    (should (string-match-p
             ":LOGBOOK:\n   CLOCK: \\[2026-10-26 Mon 10:42 UTC\\]\n   :END:" text))
    (should (string-match-p "^\\*\\* REVIEW half-reviewed thing$" text))
    (should (string-match-p "^\\*\\* DONE already closed$" text))))

(ert-deftest agent-team-clock-apply-appends-into-existing-logbook ()
  (let* ((res (agent-team-clock--apply
               agent-team-clock-test--board-logbook nil nil
               "[2026-10-26 Mon 10:42 UTC]"))
         (text (car res)))
    (should (string-match-p "^\\*\\* ONGOING paint the graph$" text))
    (should (string-match-p
             ":LOGBOOK:\n   CLOCK: \\[2026-10-26 Mon 10:42 UTC\\]" text))))

(ert-deftest agent-team-clock-apply-idempotent-on-open-clock ()
  (should (equal (agent-team-clock--apply
                  agent-team-clock-test--board-clocked nil nil
                  "[2026-10-26 Mon 10:42 UTC]")
                 (cons agent-team-clock-test--board-clocked nil))))

(ert-deftest agent-team-clock-apply-task-marker-wins ()
  (let* ((res (agent-team-clock--apply
               agent-team-clock-test--board-plain nil "half-reviewed"
               "[2026-10-26 Mon 10:42 UTC]"))
         (text (car res)))
    (should (string-match-p "^\\*\\* ONGOING half-reviewed thing$" text))
    (should-not (string-match-p "ONGOING wire the export" text))))

(ert-deftest agent-team-clock-apply-role-match ()
  (let* ((board "#+TITLE: t\n\n* Board\n\n** TODO job one\n   :ASSIGNEE: builder\n\n** TODO job two\n   :ASSIGNEE: painter\n")
         (res (agent-team-clock--apply board "painter" nil
                                       "[2026-10-26 Mon 10:42 UTC]"))
         (text (car res)))
    (should (string-match-p "ONGOING job two" text))
    (should-not (string-match-p "ONGOING job one" text))))

(ert-deftest agent-team-clock-apply-no-match ()
  (should (null (agent-team-clock--apply
                 "#+TITLE: empty\n" nil nil
                 "[2026-10-26 Mon 10:42 UTC]"))))

(provide 'agent-team-test)

;;; agent-team-test.el ends here
