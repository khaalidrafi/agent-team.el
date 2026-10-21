;;; agent-team-test.el --- tests for agent-team  -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'agent-team)

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
    (should (file-exists-p (expand-file-name "agent-team/AGENT-TEAM-TODOS.org" tmp)))
    (should (file-exists-p (expand-file-name "agent-team/AGENT-TEAM-MEMBERS.org" tmp)))
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
  (should (agent-team--env-shape-p "TELEGRAM_BOT_TOKEN"))
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

(provide 'agent-team-test)

;;; agent-team-test.el ends here
