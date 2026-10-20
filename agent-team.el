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
;; The board (agent-team/AGENT-TEAM-TODOS.org) stays the single source of
;; truth; chat handoffs never count (see the master prompt in
;; agent-team/AGENT-TEAM.md).

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
  "Parse FILE (AGENT-TEAM-MEMBERS.org) into an alist of (ROLE . MODEL@PLATFORM).
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
  (agent-team--file "AGENT-TEAM-TODOS.org"))

(defun agent-team--members ()
  "The members file."
  (agent-team--file "AGENT-TEAM-MEMBERS.org"))


;;; Scaffolding

(defvar agent-team--board-template
  "#+TITLE: AGENT-TEAM-TODOS.org — team board (single source of truth)
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
  "#+TITLE: AGENT-TEAM-MEMBERS.org — ranked members, ordered by roles
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
         (files (list (cons (expand-file-name "AGENT-TEAM-TODOS.org" dir)
                            agent-team--board-template)
                      (cons (expand-file-name "AGENT-TEAM-MEMBERS.org" dir)
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
         (to-tok   (replace-regexp-in-string "[ \t]+" "-" (downcase to)))
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
