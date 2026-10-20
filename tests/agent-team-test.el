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

(provide 'agent-team-test)

;;; agent-team-test.el ends here
