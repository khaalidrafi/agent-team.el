;;; agent-team.el --- Board, dispatches, and gateway bridge for AI agent teams  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Khalid Rafi
;; Author: Khalid Rafi <khaalidrafi@gmail.com>
;; Keywords: tools, ai, org
;; Package-Requires: ((emacs "28.1"))
;; URL: https://github.com/khaalidrafi/agent-team.el
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Emacs interface for the multi-model agent team system.  It scaffolds the
;; agent-team/ file layout, composes dispatches per the MESSAGE FORMAT SPEC,
;; flips board statuses, and talks to the Owner's gateway (chat models + Jev
;; typed judgments) with plain curl — no external Elisp dependencies.
;;
;; The board (agent-team/TODOS.org) stays the single source of
;; truth; chat handoffs never count (see the master prompt in
;; agent-team/TEAM.md).

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup agent-team nil
  "Tools for running a multi-model AI agent team."
  :group 'tools)

(defcustom agent-team-gateway-url "https://ai.khalidrafi.tech"
  "Base URL of the Owner's OpenAI-compatible gateway."
  :type 'string)

(defcustom agent-team-gateway-key
  (getenv "GOMODEL_MASTER_KEY")
  "Gateway key.  MUST come from the GOMODEL_MASTER_KEY env var — never
store keys in files or in git.  Commands refuse to run when unset."
  :type 'string)

(defcustom agent-team-dir "agent-team"
  "Directory (relative to the project root) holding the team files."
  :type 'string)

(defcustom agent-team-em-id "EM — Kimi-K2.6 @ kimi.ai"
  "This operator's identity in FROM: headers, as <role> — <model@platform>."
  :type 'string)


;;; Pure helpers (unit-tested in tests/agent-team-test.el)

(defun agent-team--format-header (msg-type n project task-id title from to priority order)
  "Format a message header per the MESSAGE FORMAT SPEC.
MSG-TYPE is DISPATCH, REPORT, HANDOFF, TEAM-UPDATE or STATUS.  N is the
message number.  PROJECT and TASK-ID scope the task.  FROM and TO are
\"<full role> — <model@platform>\" strings."
  (format "%s #%d — %s/%s: %s\nFROM: %s\nTO: %s\nPRIORITY: %s · ORDER: %s"
          msg-type n project task-id title from to priority order))

(defun agent-team--bump-counter (line)
  "Return LINE with its dispatch counter incremented, or nil if not a counter."
  (when (string-match "^\\(# DISPATCH counter: \\([0-9]+\\)\\)$" line)
    (replace-match (number-to-string (1+ (string-to-number (match-string 2 line))))
                   nil nil line 2)))

(defun agent-team--next-status (kw)
  "Return the next board status after KW, or nil if KW is not a known keyword.
PROGRESS -> BLOCKED -> REVIEW -> DONE.  DONE is terminal: only the EM re-opens
a task by resetting it to TODO."
  (pcase kw
    ("PROGRESS" "BLOCKED")
    ("BLOCKED" "REVIEW")
    ("REVIEW" "DONE")
    ("DONE" "DONE")
    (_ nil)))

(defun agent-team--normalize-member-id (tail)
  "Return the canonical compact member id from a heading's TAIL, or nil.
TAIL is everything after \"ROLE — \" on a members heading.  Accepts both
grammars the board has actually used — spaced \"<model> @ <platform>\" prose
and compact \"model@platform\" — drops a trailing \"(annotation)\" such as
\"qwen3.8-flash@qoder (ACTING)\", and collapses the id to one space-free
token so every consumer sees a single grammar (Owner rule: MODEL@PLATFORM,
no \"/\" after \"@\").  A tail with no \"@\" is not a member id at all, which
is how plain section headings like \"WEB MODE ... — who survives\" are
rejected instead of being parsed as a seat."
  (when (string-match "\\`[^(:]+" tail)
    (let ((id (replace-regexp-in-string "[ \t]+" "" (match-string 0 tail))))
      (when (string-match "\\`[^@]+@[^@]+\\'" id) id))))

(defun agent-team--parse-members (file)
  "Parse FILE (MEMBERS.org) into an alist of (ROLE . MODEL@PLATFORM).
Reverses file order so top-listed roles complete first.  Headings whose tail
carries no parsable id are skipped, so a role never gets a blank brain."
  (let (out)
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (re-search-forward "^\\* \\(.+?\\) — \\(.*\\)$"
                                  nil t)
          (let ((role (match-string-no-properties 1))
                (id (agent-team--normalize-member-id
                     (match-string-no-properties 2))))
            (when id
              (push (cons role id) out)))))
    out)))


;;; File locations

(defun agent-team--root ()
  "Project root: the git toplevel of the current buffer's file, or `default-directory'."
  (or (when buffer-file-name
        (locate-dominating-file buffer-file-name ".git"))
      default-directory))

(defun agent-team--file (name)
  "Absolute path of team file NAME inside `agent-team-dir' under the project root."
  (expand-file-name name (expand-file-name agent-team-dir (agent-team--root))))

(defun agent-team--board ()
  "The board file."
  (agent-team--file "TODOS.org"))

(defun agent-team--members ()
  "The members file."
  (agent-team--file "MEMBERS.org"))


;;; Scaffolding

(defvar agent-team--board-template
  "#+TITLE: TODOS.org — team board (single source of truth)
#+TODO: TODO PROGRESS BLOCKED REVIEW | DONE CANCELLED DEFERRED
# DISPATCH counter: 0

* Board

  (empty — work lands here as DISPATCH #n items)

* Org cheat sheet

  - ONGOING work: PROGRESS + CLOCK start line
  - progress notes go into the :LOGBOOK: drawer
  - blocked on anyone: BLOCKED; owner must rule: add :OWN:
  - finished: close CLOCK, completion note in :LOGBOOK: (facts, evidence,
    UNVERIFIED labels), flip REVIEW — REVIEW without a note is invalid
  - BLOCKED is never terminal; only the EM flips DONE
")

(defvar agent-team--members-template
  "#+TITLE: MEMBERS.org — ranked members, ordered by roles
#+ROSTER: authoritative roster = GET %s/v1/models

* <ROLE> — <model@platform>
  - owns: <area>
  - rank: (to be established by ROSTER DUTY)
")

(defvar agent-team--state-template
  "#+TITLE: STATE.org — cross-session state (Owner pastes back at session start)

* DONE
* IN-FLIGHT
* READY-FOR-HUMAN-REVIEW
* DEFERRED
* BLOCKED
* TEAM-STAFFING
* HIRING-LOG
* AUTONOMY
  AUTO
")

;;;###autoload
(defun agent-team-init (root)
  "Scaffold the team files under ROOT: agent-team/ board + members, STATE.org.
Refuses to overwrite existing files — adoption of new templates is the EM's
call, not this command's."
  (interactive "DProject root: ")
  (let* ((dir (expand-file-name agent-team-dir root))
         (files (list (cons (expand-file-name "TODOS.org" dir)
                            agent-team--board-template)
                      (cons (expand-file-name "MEMBERS.org" dir)
                            (format agent-team--members-template agent-team-gateway-url))
                      (cons (expand-file-name "STATE.org" root)
                            agent-team--state-template))))
    (when (cl-some (lambda (f) (file-exists-p (car f))) files)
      (error "Team files already exist under %s — refusing to overwrite" root))
    (make-directory dir t)
    (dolist (f files)
      (write-region (cdr f) nil (car f)))
    (message "agent-team: scaffolded board, members, STATE in %s" root)))


;;; Dispatch composer

(defun agent-team--read-counter ()
  "Read the dispatch counter from the board, defaulting to 0."
  (if (file-exists-p (agent-team--board))
      (with-temp-buffer
        (insert-file-contents (agent-team--board))
        (goto-char (point-min))
        (if (re-search-forward "^# DISPATCH counter: \\([0-9]+\\)" nil t)
            (string-to-number (match-string 1))
          0))
    0))

(defun agent-team--bump-counter-in-file ()
  "Increment the counter line in the board file."
  (when (file-exists-p (agent-team--board))
    (with-current-buffer (find-file-noselect (agent-team--board))
      (save-excursion
        (goto-char (point-min))
        (when (re-search-forward "^# DISPATCH counter: [0-9]+" nil t)
          (beginning-of-line)
          (let ((new (agent-team--bump-counter
                      (buffer-substring (line-beginning-position)
                                        (line-end-position)))))
            (when new
              (delete-region (line-beginning-position) (line-end-position))
              (insert new)
              (save-buffer))))))))

(defvar agent-team-dispatch-skeleton
  "BLUF: \nCONTEXT: \nTASK:\n1. \n2. \nDEFINITION OF DONE: \nSCOPE: yours: · NOT yours: \nENV: \nFINAL INSTRUCTION: \n"
  "Body skeleton inserted under every dispatch header.")

;;;###autoload
(defun agent-team-insert-dispatch (to title priority)
  "Compose a DISPATCH to member TO about TITLE with PRIORITY (P0/P1/P2).
Inserts a board entry under * Board and copies the full dispatch text to the
kill-ring for pasting into the member's chat.  Increments the dispatch counter."
  (interactive
   (list (completing-read "TO (member): "
                          (agent-team--parse-members (agent-team--members))
                          nil nil nil nil agent-team-em-id)
         (read-string "Title: ")
         (completing-read "Priority: " '("P0" "P1" "P2") nil t nil nil "P1")))
  (let* ((board (agent-team--board))
         (n (1+ (agent-team--read-counter)))
         (task-id (format "%03d" n))
         (header (agent-team--format-header
                  "DISPATCH" n "proj" task-id title agent-team-em-id to priority 1))
         (text (concat header "\n\n" agent-team-dispatch-skeleton)))
    (if (file-exists-p board)
        (with-current-buffer (find-file-noselect board)
          (goto-char (point-min))
          (re-search-forward "^\\* Board" nil t)
          (end-of-line)
          (insert (format "\n** TODO [#%s] %s: %s\n%s"
                          (substring priority 1) task-id title text))
          (save-buffer))
      (with-temp-file board
        (insert (format "%s\n* Board\n\n** TODO [#%s] %s: %s\n%s"
                        agent-team--board-template (substring priority 1)
                        task-id title text))))
    (agent-team--bump-counter-in-file)
    (kill-new text)
    (message "agent-team: DISPATCH #%d on board and in kill-ring" n)))


;;; Status flips

;;;###autoload
(defun agent-team-flip-status ()
  "Cycle the Org TODO keyword on the current heading: PROGRESS->BLOCKED->REVIEW->DONE.
DONE is terminal (EM-only by convention; this command does not enforce roles)."
  (interactive)
  (unless (org-at-heading-p)
    (user-error "Not on a heading"))
  (let* ((kw (substring-no-properties (or (org-get-todo-state) "")))
         (next (agent-team--next-status kw)))
    (unless next (user-error "Unknown keyword %s — use Org's built-in cycling" kw))
    (org-todo next)
    (when (equal next "PROGRESS") (org-clock-in))
    (when (member next '("REVIEW" "DONE")) (org-clock-out nil t))
    (message "agent-team: %s -> %s" kw next)))


;;; Team mesh: TEAM-CHAT.org (one chat buffer, mailbox deprecated)

(defun agent-team--chat-file ()
  "The team chat file (ONE append-only Org buffer, Owner law 16:55)."
  (agent-team--file "TEAM-CHAT.org"))

(defun agent-team--control-file ()
  "The control file (turn pointer, objective, kill switch, stall count)."
  (agent-team--file "TEAM-CONTROL.org"))

(defun agent-team--chat-format (from to kind body when)
  "Render one chat message per the FORMAT LAW (Owner 17:55Z).
Headline carries FROM; routing rides Org tags + a :PROPERTIES: drawer;
WHEN is an Org inactive timestamp string like \"[2026-10-21 Wed 09:00 UTC]\".
BODY lines are indented two spaces (Org list-friendly)."
  (let* ((from-tok (replace-regexp-in-string "[ \t]+" "-" (downcase from)))
         (to-tok   (string-remove-prefix
                    "@" (replace-regexp-in-string "[ \t]+" "-" (downcase to))))
         (to-tag   (string-remove-prefix "@" to-tok))
         (indented (mapconcat (lambda (l)
                                (if (string-empty-p (string-trim l))
                                    ""
                                  (concat "  " (string-trim-right l))))
                              (split-string body "\n") "\n")))
    (concat
     (format "* MSG %s -> @%s :%s:                    :msg:%s:%s:%s:\n"
             from to-tag kind from-tok to-tag kind)
     ":PROPERTIES:\n"
     (format ":FROM: %s\n" from)
     (format ":TO: %s\n" to-tag)
     (format ":KIND: %s\n" kind)
     (format ":WHEN: %s\n" when)
     ":END:\n"
     indented)))

(defun agent-team-chat-append (from to kind body)
  "Append one chat message to agent-team/TEAM-CHAT.org (append-only:
existing entries are never edited — the guard is Org motion + EOF insert).
FROM defaults to `agent-team-em-id'.  Returns the inserted headline."
  (interactive
   (let ((from (read-string "FROM: " agent-team-em-id))
         (to (completing-read "TO (@handle): "
                              '("@lead" "@owner" "@all") nil nil))
         (kind (completing-read "KIND: "
                                '("dispatch" "report" "request"
                                  "escalation" "review" "note")
                                nil t nil nil "note"))
         (body (read-string "Body: ")))
     (list from to kind body)))
  (let* ((file (agent-team--chat-file))
         (msg (agent-team--chat-format
               from to kind body
               (format-time-string "[%Y-%m-%d %a %H:%M UTC]" nil t))))
    (make-directory (file-name-directory file) t)
    (with-current-buffer (find-file-noselect file)
      (save-excursion
        (goto-char (point-max))
        (insert "\n" msg))
      (save-buffer))
    (kill-new msg)
    (message "agent-team: chat message appended (%s -> %s)" from to)))

(defun agent-team-chat-open ()
  "Open the team chat at the end (the live tail is where work is)."
  (interactive)
  (find-file (agent-team--chat-file))
  (goto-char (point-max)))

(defun agent-team-chat-tail (&optional n)
  "Echo the last N chat headlines (default 5) — the read-first law."
  (interactive)
  (let* ((file (agent-team--chat-file))
         (count (or n 5))
         (heads))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-max))
        (while (and (> count 0)
                    (re-search-backward "^\\* MSG " nil t))
          (push (buffer-substring (line-beginning-position)
                                  (line-end-position))
                heads)
          (setq count (1- count)))))
    (if heads
        (message "chat tail:\n%s" (mapconcat #'identity heads "\n"))
      (message "chat: empty (no MSG headlines yet)"))))

(defun agent-team-chat-pings-to (handle)
  "Echo unanswered-style pings to HANDLE (the brief's scan-first law:
scan the tail for @handle pings before picking work)."
  (interactive "sHandle (e.g. platform-engineer): ")
  (let* ((file (agent-team--chat-file))
         (rx (concat "^\\* MSG .*@.*\\b" (regexp-quote handle) "\\b"))
         (hits))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (re-search-forward rx nil t)
          (push (buffer-substring (line-beginning-position)
                                  (line-end-position))
                hits))))
    (if hits
        (message "pings to @%s:\n%s" handle
                 (mapconcat #'identity (nreverse hits) "\n"))
      (message "no pings to @%s in the chat" handle))))

;;; Secret law: env-var names travel, values never do

(defun agent-team--env-shape-p (name)
  "Non-nil when NAME looks like a credential env var (names only —
the value never appears anywhere in this package)."
  (and (stringp name)
       (let ((case-fold-search nil)) ; regex matching is case-insensitive by default — a lowercase "qoder_token" would otherwise match
         (string-match-p
          (concat "\\`\\(?:GROQ\\|ZAI\\|ZHIPU\\|OPENROUTER\\|OPENAI\\|ANTHROPIC"
                  "\\|QODER\\|TELEGRAM\\|CODEBUDDY\\|GOMODEL\\|LARK\\|GITHUB"
                  "\\|DISCORD\\|CLOUDFLARE\\|GEMINI\\|OPCODE\\|OPENCODE\\)[A-Z_]*"
                  "\\(?:API_KEY\\|TOKEN\\|PAT\\|WEBHOOK[A-Z_]*\\|MASTER_KEY"
                  "\\|OWNER_ID\\|ACCOUNT_ID\\)\\'") name))))

(defun agent-team-env-names ()
  "List the credential-shaped ENV VAR NAMES in this environment.
Secret law (Owner 18:27Z): members share credentials as env var NAMES —
a peer confirms the NAME and has-it/absent; the asker reads the value
from their OWN environment.  Values are never printed by this command."
  (interactive)
  (let ((names (sort
                (delete-dups
                 (delq nil (mapcar (lambda (e)
                                     (when (stringp e)
                                       (let ((n (car (split-string e "="))))
                                         (and (agent-team--env-shape-p n) n))))
                                   process-environment)))
                #'string<)))
    (if (called-interactively-p 'any)
        (with-help-window "*agent-team env names*"
          (princ "Credential env var NAMES in this environment:\n\n")
          (princ (mapconcat #'identity names "\n"))
          (princ "\n\nLaw: ask a peer for the NAME, read the value from
your own env with (getenv \"NAME\").  Never echo values."))
      names)))

(defun agent-team-env-look (name)
  "Look into the env for credential NAME — the Owner's law in action:
\"members will simply ask another agent to look into the PAT env\".
Answers presence + shape only; the value is never displayed.  Returns
`set' / `unset' / `nonstandard' for scripting."
  (interactive "sENV VAR NAME (e.g. QODER_PERSONAL_ACCESS_TOKEN): ")
  (let* ((val (getenv name))
         (status (cond ((not val) "unset")
                       ((and (agent-team--env-shape-p name)
                             (>= (length val) 12)) "set")
                       (t "nonstandard"))))
    (message "%s: %s%s" name status
             (if (equal status "set")
                 (format " (%d chars) — read it from your own env; never echo"
                         (length val))
               ""))
    status))

(defun agent-team-env-require (name)
  "Error unless NAME is set in the environment (gateway law extended:
every credential-consuming command can demand its key up front)."
  (unless (getenv name)
    (user-error "agent-team: env var %s is NOT set — ask the Lead/peer for the NAME, then export it" name))
  t)

;;; Control plane: TEAM-CONTROL.org (turn pointer / objective / kill switch)

(defun agent-team--control-apply (content key value)
  "Return CONTENT with its #+KEY: line replaced by VALUE (or the line
inserted into the header block when absent).  Pure — unit-tested."
  (let ((line (concat "#+" key ": " value))
        (lines (split-string content "\n"))
        replaced)
    (setq lines (mapcar (lambda (l)
                          (if (and (not replaced)
                                   (string-match-p
                                    (concat "^\\#\\+" (regexp-quote key) ":") l))
                              (progn (setq replaced t) line)
                            l))
                        lines))
    (unless replaced
      (let ((pos (cl-position-if (lambda (l) (string-prefix-p "* " l)) lines)))
        (if pos
            (setq lines (append (cl-subseq lines 0 pos)
                                (list line)
                                (cl-subseq lines pos)))
          (setq lines (append lines (list line))))))
    (string-join lines "\n")))

(defun agent-team-control-get (key)
  "Read the #+KEY: value from TEAM-CONTROL.org (nil when absent)."
  (let ((file (agent-team--control-file)))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (when (re-search-forward (concat "^\\#\\+" (regexp-quote key) ":[ \t]*\\(.*\\)$") nil t)
          (string-trim (match-string 1)))))))

(defun agent-team-control-set (key value)
  "Set #+KEY: to VALUE in TEAM-CONTROL.org (TURN / KILL-SWITCH /
OBJECTIVE / OBJECTIVE-STATE / STALL-COUNT).  The CI chain reads these
verbatim each run — this is how the Lead paces the rotation from Emacs."
  (interactive "sKey (TURN|KILL-SWITCH|OBJECTIVE|OBJECTIVE-STATE|STALL-COUNT): \nsValue: ")
  (let* ((file (agent-team--control-file))
         (content (if (file-exists-p file)
                      (with-temp-buffer
                        (insert-file-contents file)
                        (buffer-string))
                    (progn
                      (make-directory (file-name-directory file) t)
                      "#+TITLE: TEAM-CONTROL.org — chain control\n"))))
    (with-temp-file file
      (insert (agent-team--control-apply content key value)))
    (message "agent-team: %s -> %s" key value)))

(defun agent-team-kill-switch (on)
  "Flip the chain kill switch (ON stops every future turn; the Owner
keeps the final authority — this is the Lead's hand on the same lever)."
  (interactive (list (y-or-n-p "KILL-SWITCH ON (stops the chain)? ")))
  (agent-team-control-set "KILL-SWITCH" (if on "ON" "OFF"))
  (message "agent-team: KILL-SWITCH %s" (if on "ON — chain halts" "OFF — chain runs")))

;;; Gateway: Jev + health

(defun agent-team--curl (args)
  "Run curl with ARGS (list), returning stdout string or nil on failure."
  (with-temp-buffer
    (when (equal 0 (apply #'call-process "curl" nil t nil args))
      (string-trim (buffer-string)))))

(defun agent-team--jev-payload (state question)
  "Build a Jev request body: one batched noul question over STATE."
  (json-encode
   (list :state state
         :model "jev-1.13.0"
         :questions (list :q (list :type "noul" :instructions question)))))

;;;###autoload
(defun agent-team-jev-ask (question &optional state)
  "Ask Jev a yes/no QUESTION over STATE (defaults to the active region).
Echoes the calibrated probability; ≥0.5 reads yes.  One question per call —
batch questions upstream per the batching law."
  (interactive "sQuestion: \nr")
  (let* ((state (or state (buffer-substring-no-properties (region-beginning) (region-end))))
         (body (agent-team--jev-payload state question))
         (resp (agent-team--curl
                (list "-s" "-m" "90" "-X" "POST"
                      (concat agent-team-gateway-url "/v1/systemone")
                      "-H" (format "Authorization: Bearer %s" agent-team-gateway-key)
                      "-H" "Content-Type: application/json"
                      "-d" body))))
    (unless resp (user-error "agent-team: gateway unreachable"))
    (let* ((json (json-parse-string resp :object-type 'alist))
           (ans (alist-get 'noul (alist-get 'q (alist-get 'answers json)))))
      (message "Jev: %.2f -> %s" ans (if (>= ans 0.5) "yes" "no"))
      (kill-new (number-to-string ans)))))

;;;###autoload
(defun agent-team-gateway-ping ()
  "Check the gateway is alive.  Expects a 404 from GET / (origin answering)."
  (interactive)
  (let ((resp (agent-team--curl
               (list "-s" "-o" "/dev/null" "-w" "%{http_code}"
                     "-m" "30" (concat agent-team-gateway-url "/")))))
    (message "agent-team: gateway %s"
             (pcase resp
               ("404" "up (origin answering)")
               ("000" "unreachable")
               (_ (format "HTTP %s" resp))))))


(provide 'agent-team)

;;; agent-team.el ends here

;;; Team-making prompt builder — Emacs assembles the prompt from templates/
;;; (Owner 2026-10-21 08:22Z: "Emacs is supposed to build the prompt with
;;; templates/*"). No PROMPT.org file: THIS command is the generator.

(defvar agent-team--templates-dir
  (file-name-as-directory
   (expand-file-name
    "templates"
    (file-name-directory (or (locate-library "agent-team")
                             load-file-name
                             (buffer-file-name)))))
  "Directory of the pkg-owned templates the team-making prompt is built
from: TEAMIFY.org / BOOTSTRAP.org (mode layer) + COMMON.org (canonical
manual, inlined at build time) + CANDIDATES.org (candidate seed).")

(defun agent-team--template (name)
  "Return the contents of templates/NAME, or an error marker if missing."
  (let ((file (expand-file-name name agent-team--templates-dir)))
    (if (file-exists-p file)
        (with-temp-buffer (insert-file-contents file) (buffer-string))
      (format "<<<MISSING TEMPLATE: %s>>>" file))))

;;;###autoload
(defun agent-team-teamify-prompt (&optional repo project not-touch pat fresh)
  "Build the ONE team-making prompt from templates/ for REPO.
Assembles: FILL BLOCK (REPO / PROJECT / NOT-TOUCH / PAT) + the mode layer
(templates/BOOTSTRAP.org for a FRESH project, templates/TEAMIFY.org for an
existing one) + templates/COMMON.org (the canonical manual, inlined at
build time from its canonical home — no per-repo copies drift). Puts the
result in the *agent-team prompt* buffer AND the kill-ring, ready to paste
into a fresh chat with the team's Lead. The PAT travels in the prompt only
— never stored in files/commits/board (Owner order 2026-10-21)."
  (interactive)
  (unless repo
    (setq repo (read-string "REPO (url; team-truth branch is ai/main): "))
    (setq project (read-string "PROJECT (2-4 lines: what/state/done-today): "))
    (setq not-touch (read-string "NOT-TOUCH (paths/ops; RET = none): "))
    (setq pat (read-passwd "PAT (github_pat_, no rotation): "))
    (setq fresh (y-or-n-p "FRESH project? (yes = BOOTSTRAP layer, no = TEAMIFY) ")))
  (let* ((layer (agent-team--template (if fresh "BOOTSTRAP.org" "TEAMIFY.org")))
         (manual (agent-team--template "COMMON.org"))
         (prompt (concat
                  "# TEAM-MAKING PROMPT — built by agent-team.el from templates/"
                  " (" (if fresh "BOOTSTRAP" "TEAMIFY") " + COMMON) on "
                  (format-time-string "%Y-%m-%d %H:%M UTC") "\n\n"
                  "* FILL BLOCK (Director)\n"
                  "- REPO: " repo " — team-truth branch: ai/main\n"
                  "- PROJECT: " project "\n"
                  "- NOT-TOUCH: " (if (or (null not-touch) (string-empty-p not-touch))
                                      "none declared" not-touch) "\n"
                  "- PAT: " pat "\n"
                  "  (reuse the same token, no rotation; use immediately; NEVER\n"
                  "  store in files/commits/board/logs)\n\n"
                  layer "\n\n" manual "\n"))
         (buffer (get-buffer-create "*agent-team prompt*")))
    (with-current-buffer buffer
      (erase-buffer)
      (insert prompt)
      (org-mode)
      (goto-char (point-min)))
    (kill-new prompt)
    (pop-to-buffer buffer)
    (message "agent-team: prompt built (%d chars) — *agent-team prompt* + kill-ring; paste into the Lead's fresh chat"
             (length prompt))))

;;; Live team chat (TEAM-CHAT.org) --------------------------------------------
;;;
;;; Owner order 2026-10-21 09:16Z (#hq): "add a feature to view team chat
;;; live on my Emacs on Android."  Zero dependencies — url.el + timers, no
;;; git/curl/gh — so it runs on an Emacs 28+ on Android (Termux or the
;;; native Android port) where a git binary may not exist.  It polls the
;;; chat file over HTTPS and re-renders it as a read-only Org buffer that
;;; follows the tail: the CI seats append `* MSG <from> -> @<to> :<kind>:'
;;; headlines at EOF (union-merged), and this viewer shows them as they
;;; land.  Public teamified repos need no credentials; a private repo is
;;; served through the Contents API with `agent-team-chat-token'.

(defcustom agent-team-chat-default-repo "khaalidrafi/agent-team.el"
  "Default teamified repo whose chat `agent-team-watch-chat' shows."
  :type 'string
  :group 'agent-team)

(defcustom agent-team-chat-default-branch "ai/main"
  "Team-truth branch to read the chat from."
  :type 'string
  :group 'agent-team)

(defcustom agent-team-chat-default-path "agent-team/TEAM-CHAT.org"
  "Path of the chat file inside the repo (any board file works)."
  :type 'string
  :group 'agent-team)

(defcustom agent-team-chat-interval 15
  "Seconds between chat polls.  Android battery: raise it, the viewer
still catches up on the next tick."
  :type 'integer
  :group 'agent-team)

(defcustom agent-team-chat-token nil
  "Optional PAT for PRIVATE teamified repos.  Public repos (the publish
law: flipped public after the secret-leak audit) need no token — the raw
file is anonymous-readable.  The token lives only in this variable at
runtime; never write it into any file, board or commit."
  :type '(choice (const :tag "anonymous (public repos)" nil)
                 (string :tag "PAT"))
  :group 'agent-team)

(defface agent-team-chat-new-face
  '((t :weight bold))
  "Face for messages that arrived in the last chat update."
  :group 'agent-team)

(defvar-local agent-team-chat--repo nil
  "Repo this chat buffer watches.")
(defvar-local agent-team-chat--branch nil)
(defvar-local agent-team-chat--path nil)
(defvar-local agent-team-chat--timer nil
  "The polling timer; cancelled by `agent-team-chat--teardown'.")
(defvar-local agent-team-chat--busy nil
  "Non-nil while a fetch is in flight (no overlapping polls).")
(defvar-local agent-team-chat--content nil
  "Previously rendered chat text — the append-only diff base.")
(defvar-local agent-team-chat--last-fetch nil
  "Time of the last successful render, as a float.")
(defvar-local agent-team-chat--status "connecting"
  "Human-readable fetch state shown in the header line.")
(defvar-local agent-team-chat--errs 0
  "Consecutive failed fetches.")

(defvar agent-team-chat-minor-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "g" 'agent-team-chat-refresh)
    (define-key map "q" 'agent-team-chat-quit)
    map)
  "Keys for the live chat viewer: g refresh, q stop and close.")

;;;###autoload
(define-minor-mode agent-team-chat-live-mode
  "Live team-chat viewer mode (on an org-mode buffer)."
  :lighter " team-chat"
  :keymap agent-team-chat-minor-mode-map)

(defun agent-team-chat--url (repo branch path token)
  "Return the fetch URL for REPO@BRANCH:PATH.
Without TOKEN: raw.githubusercontent.com (anonymous, public repos).
With TOKEN: the Contents API, which serves raw bytes for private repos
via the Accept header set in `agent-team-chat--headers'."
  (if token
      (format "https://api.github.com/repos/%s/contents/%s?ref=%s"
              repo path branch)
    (format "https://raw.githubusercontent.com/%s/%s/%s"
            repo branch path)))

(defun agent-team-chat--headers (token)
  "Headers for the chat fetch: only a UA, plus auth when TOKEN is set."
  (append '(("User-Agent" . "agent-team.el (live team chat)"))
          (when token
            `(("Authorization" . ,(concat "Bearer " token))
              ("Accept" . "application/vnd.github.raw+json")))))

(defun agent-team-chat--msg-count (text)
  "Count `* MSG' headlines in TEXT — the chat's message standard."
  (let ((n 0) (pos 0))
    (while (string-match "^\\* MSG " text pos)
      (setq n (1+ n) pos (match-end 0)))
    n))

(defun agent-team-chat--render (buf text)
  "Render TEXT (the chat file) into BUF, following the tail."
  (with-current-buffer buf
    (let* ((inhibit-read-only t)
           (old agent-team-chat--content)
           (was-empty (null old))
           (follow (or was-empty (>= (point) (point-max))))
           (grown (and old (> (length text) (length old))
                       (string-prefix-p old text)))
           (new-start (if grown (1+ (length old)) 1)))
      (erase-buffer)
      (insert text)
      (org-mode)
      (unless agent-team-chat-live-mode (agent-team-chat-live-mode 1))
      (remove-overlays (point-min) (point-max) 'agent-team-chat-new t)
      (when grown
        (let ((ov (make-overlay new-start (point-max) nil t nil)))
          (overlay-put ov 'agent-team-chat-new t)
          (overlay-put ov 'face 'agent-team-chat-new-face)))
      (setq buffer-read-only t
            agent-team-chat--content text
            agent-team-chat--last-fetch (float-time)
            agent-team-chat--status "ok"
            agent-team-chat--errs 0)
      (setq header-line-format
            (format " agent-team chat: %s@%s · %s every %ds · %d msgs · last %s · %s"
                    agent-team-chat--repo agent-team-chat--branch
                    (propertize "LIVE" 'face 'success)
                    agent-team-chat-interval
                    (agent-team-chat--msg-count text)
                    (format-time-string "%H:%M:%S" agent-team-chat--last-fetch)
                    agent-team-chat--status))
      (if follow (goto-char (point-max)) (goto-char (point-min))))))

(defun agent-team-chat--failed (buf why)
  "Record a failed fetch for BUF; the view keeps the last good content."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq agent-team-chat--busy nil
            agent-team-chat--errs (1+ agent-team-chat--errs)
            agent-team-chat--status
            (if (> agent-team-chat--errs 1)
                (format "%s (retry %d)" why agent-team-chat--errs)
              why)))))

(defun agent-team-chat--callback (status buf)
  "url-retrieve callback: hand the raw file bytes to the renderer."
  (let ((err (plist-get status :error)))
    (if err
        (agent-team-chat--failed buf "connection failed")
      (goto-char (point-min))
      (let ((code (and (boundp 'url-http-response-status)
                       url-http-response-status)))
        (cond
         ((and code (/= code 200))
          (agent-team-chat--failed
           buf (if (eq code 404)
                   "HTTP 404 — no chat at this repo@branch yet"
                 (format "HTTP %s" code))))
         (t
          (re-search-forward "\r?\n\r?\n" nil t)
          (agent-team-chat--render
           buf (decode-coding-string
                (buffer-substring-no-properties (point) (point-max))
                'utf-8 t))))))
    (kill-buffer (current-buffer))))

(defun agent-team-chat--fetch (buf)
  "Poll the chat file for BUF once (skipped while a fetch runs)."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (unless agent-team-chat--busy
        (setq agent-team-chat--busy t)
        (condition-case err
            (let ((url-request-extra-headers
                   (agent-team-chat--headers agent-team-chat-token)))
              (url-retrieve
               (agent-team-chat--url agent-team-chat--repo
                                     agent-team-chat--branch
                                     agent-team-chat--path
                                     agent-team-chat-token)
               #'agent-team-chat--callback (list buf) t))
          (error
           (setq agent-team-chat--busy nil)
           (agent-team-chat--failed
            buf (format "fetch error: %s" (error-message-string err)))))))))

(defun agent-team-chat--teardown ()
  "Cancel the polling timer (runs from `kill-buffer-hook')."
  (when agent-team-chat--timer
    (cancel-timer agent-team-chat--timer)
    (setq agent-team-chat--timer nil)))

(defun agent-team-chat--tick (buf)
  "Timer body: one poll while BUF lives and the mode is on."
  (when (and (buffer-live-p buf)
             (buffer-local-value 'agent-team-chat-live-mode buf))
    (agent-team-chat--fetch buf)))

;;;###autoload
(defun agent-team-watch-chat (&optional repo branch path)
  "View the team chat (TEAM-CHAT.org) LIVE in an Org buffer.
Polls REPO@BRANCH:PATH every `agent-team-chat-interval' seconds and
follows the tail so new `* MSG' headlines arrive as the seats append
them.  Works on Android (Emacs 28+, no git needed).  Keys: `g' refresh,
`q' stop and close.  Public repos need no PAT; private ones use
`agent-team-chat-token'."
  (interactive)
  (unless repo
    (setq repo (read-string (format "Repo (%s): "
                                    agent-team-chat-default-repo)))
    (when (string-empty-p repo) (setq repo agent-team-chat-default-repo)))
  (unless branch
    (setq branch (read-string (format "Branch (%s): "
                                      agent-team-chat-default-branch)))
    (when (string-empty-p branch)
      (setq branch agent-team-chat-default-branch)))
  (unless path
    (setq path (read-string (format "Path (%s): "
                                    agent-team-chat-default-path)))
    (when (string-empty-p path) (setq path agent-team-chat-default-path)))
  (let ((buf (get-buffer-create (format "*agent-team chat: %s*" repo))))
    (with-current-buffer buf
      (setq agent-team-chat--repo repo
            agent-team-chat--branch branch
            agent-team-chat--path path)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "watching %s@%s:%s every %ds …\n"
                        repo branch path agent-team-chat-interval)))
      (org-mode)
      (unless agent-team-chat-live-mode (agent-team-chat-live-mode 1))
      (add-hook 'kill-buffer-hook #'agent-team-chat--teardown nil t)
      (agent-team-chat--fetch buf)
      (unless agent-team-chat--timer
        (setq agent-team-chat--timer
              (run-at-time agent-team-chat-interval
                           agent-team-chat-interval
                           #'agent-team-chat--tick buf))))
    (pop-to-buffer buf)
    (message "agent-team chat: LIVE %s@%s:%s — g refresh, q stop"
             repo branch path)))

;;;###autoload
(defun agent-team-chat-refresh ()
  "Refresh the live chat buffer under point right now."
  (interactive)
  (agent-team-chat--fetch (current-buffer))
  (message "agent-team chat: refresh requested"))

;;;###autoload
(defun agent-team-chat-quit ()
  "Stop polling and close the live chat buffer."
  (interactive)
  (agent-team-chat--teardown)
  (let ((buf (current-buffer)))
    (quit-window nil (selected-window))
    (kill-buffer buf)))
