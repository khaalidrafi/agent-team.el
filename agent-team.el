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

(defcustom agent-team-gateway-url "http://localhost:8080"
  "Base URL of the Owner's GoModel gateway.  Resolution law (Owner order
2026-10-22): CI resolves per job — vars.GOMODEL_GATEWAY_URL override,
then https://ai.khalidrafi.tech (the deployment), then localhost:8080
(an already-running listener), and ONLY when nothing answers does the
runner boot its own gomodel (nothing answering = no deployment active).
Ping contract: GET / -> 404/200 = up.  On the box keep the default
(localhost:8080); set this to the tunnel when calling from outside."
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
#+TODO: TODO ONGOING PROGRESS BLOCKED REVIEW | DONE CANCELLED DEFERRED
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

(defun agent-team--chat-repo ()
  "owner/slug of the current project's git origin — the chat entry's
:REPO: protocol field. \"unset\" when it cannot be derived."
  (condition-case nil
      (let* ((root (agent-team--root))
             (remote (string-trim
                      (shell-command-to-string
                       "git -C . remote get-url origin 2>/dev/null"))))
        (if (string-match "[:/]\([^/]+/[^/]+\)\(\.git\)?/?$" remote)
            (replace-regexp-in-string "\.git$" "" (match-string 1 remote))
          "unset"))
    (error "unset")))

(defun agent-team--chat-format (from to kind body when
                                &optional repo priority risk)
  "Render one chat message per the UNIQUE COMMS PROTOCOL (Owner order
2026-10-27 #hq: \"TEAM-UPDATE EVERYWHERE! We MUST have a unique protocol
for comms\" — chat entries carry the same MESSAGE STANDARD fields as a
TEAM-UPDATE). Headline carries FROM; routing rides Org tags + a
:PROPERTIES: drawer with FROM/TO/KIND/REPO/PRIORITY/RISK/WHEN; WHEN is
an Org inactive timestamp string like \"[2026-10-21 Wed 09:00 UTC]\".
BODY lines are indented two spaces (Org list-friendly). REPO defaults
to \"unset\", PRIORITY to P1, RISK to reads."
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
     (format ":REPO: %s\n" (or repo "unset"))
     (format ":PRIORITY: %s\n" (or priority "P1"))
     (format ":RISK: %s\n" (or risk "reads"))
     (format ":WHEN: %s\n" when)
     ":END:\n"
     indented)))

(defun agent-team--chat-append-1 (from to kind body repo priority risk file)
  "Append one protocol chat message to FILE (append-only: existing
entries are never edited — the guard is Org motion + EOF insert).
The one implementation every sender shares; the interactive command is
`agent-team-chat-send'."
  (let ((msg (agent-team--chat-format
              from to kind body
              (format-time-string "[%Y-%m-%d %a %H:%M UTC]" nil t)
              repo priority risk)))
    (make-directory (file-name-directory file) t)
    (with-current-buffer (find-file-noselect file)
      (save-excursion
        (goto-char (point-max))
        (insert "\n" msg))
      (save-buffer))
    (kill-new msg)
    (message "agent-team: chat message appended (%s -> %s)" from to)))

(defvar agent-team-chat-kinds
  '("dispatch" "report" "request" "escalation" "review" "note")
  "The one KIND vocabulary for chat entries (the unique comms
protocol — same list everywhere, enforced by the sender commands).")

(defun agent-team-chat-send (&optional from to kind body priority risk)
  "Send one chat message to the team (THE command agents call — Owner
order 2026-10-27 #hq: TEAM-CHAT.org is auto-maintained by agent-team.el,
never hand-written). Composes the unique comms protocol entry (FROM/TO/
KIND/REPO/PRIORITY/RISK drawer, like a TEAM-UPDATE) and appends it to
agent-team/TEAM-CHAT.org. FROM defaults to `agent-team-em-id'; REPO is
derived from the project's git origin. Interactively prompts for every
field; called from Lisp, all arguments optional."
  (interactive
   (let ((to (completing-read "TO (@handle): "
                              '("@lead" "@owner" "@all") nil nil))
          (kind (completing-read "KIND: " agent-team-chat-kinds
                                 nil t nil nil "note"))
          (priority (completing-read "PRIORITY: " '("P0" "P1" "P2")
                                     nil t nil nil "P1"))
          (risk (completing-read "RISK: " '("reads" "writes" "both")
                                 nil t nil nil "reads"))
          (body (read-string "Body: ")))
     (list nil to kind body priority risk)))
  (agent-team--chat-append-1
   (or from agent-team-em-id) to kind body
   (agent-team--chat-repo) priority risk
   (agent-team--chat-file)))

(defun agent-team-chat-send-batch ()
  "Non-interactive chat send for CI seats (Owner order 2026-10-27 #hq:
TEAM-CHAT.org is maintained by commands, never hand-written). Reads the
message from env — AGENT_CHAT_FROM, AGENT_CHAT_TO, AGENT_CHAT_KIND,
AGENT_CHAT_BODY (or AGENT_CHAT_BODY_FILE), optional AGENT_CHAT_REPO,
AGENT_CHAT_PRIORITY, AGENT_CHAT_RISK, and AGENT_CHAT_FILE (override the
chat file path; default: the project's agent-team/TEAM-CHAT.org). The
harness bakes this as the `team-chat' command. Fails loudly when a
required field is missing; prints a confirmation line on success."
  (let* ((env (lambda (v)
                (let ((x (getenv v))) (and x (not (string-empty-p x)) x))))
         (from (or (funcall env "AGENT_CHAT_FROM") "ci-seat"))
         (to (or (funcall env "AGENT_CHAT_TO")
                 (error "agent-team-chat-send-batch: AGENT_CHAT_TO is required")))
         (kind (or (funcall env "AGENT_CHAT_KIND") "note"))
         (body-file (funcall env "AGENT_CHAT_BODY_FILE"))
         (body (or (funcall env "AGENT_CHAT_BODY")
                   (and body-file
                        (with-temp-buffer
                          (insert-file-contents body-file)
                          (buffer-string)))
                   (error (concat "agent-team-chat-send-batch: "
                                  "AGENT_CHAT_BODY or AGENT_CHAT_BODY_FILE"
                                  " is required"))))
         (repo (or (funcall env "AGENT_CHAT_REPO") (agent-team--chat-repo)))
         (priority (funcall env "AGENT_CHAT_PRIORITY"))
         (risk (funcall env "AGENT_CHAT_RISK"))
         (file (or (funcall env "AGENT_CHAT_FILE")
                   (condition-case nil
                       (agent-team--chat-file)
                     (error "agent-team/TEAM-CHAT.org")))))
    (agent-team--chat-append-1 from to kind body repo priority risk file)
    (princ (format "team-chat: appended (%s -> %s :%s:)\n" from to kind))))

(defun agent-team-chat-open ()
  "Open the team chat session buffer (Owner order 2026-10-27 #hq: like
an agent-org session — an Org buffer backed by an Org file, here
agent-team/TEAM-CHAT.org). Auto-revert-tail keeps new peer entries
flowing in at the live tail; the remote view is
`agent-team-chat-live-mode' (the GitHub-polling viewer)."
  (interactive)
  (find-file (agent-team--chat-file))
  (auto-revert-tail-mode 1)
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
                  "\\|CLOUDFLARE\\|GEMINI\\|OPCODE\\|OPENCODE\\)[A-Z_]*"
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

(defun agent-team--strip-template-header (text)
  "Drop a template body's own file-metadata header: the leading
#+KEY: value lines plus the blank line after them.  Those lines
describe the template FILE (TITLE/HOME/RULE...), not the law — the
assembled prompt carries part headings instead.  Body text is returned
byte-identical."
  (let ((lines (split-string text "\n")))
    (while (and lines (string-prefix-p "#+" (car lines)))
      (setq lines (cdr lines)))
    (while (and lines (string-empty-p (car lines)))
      (setq lines (cdr lines)))
    (mapconcat #'identity lines "\n")))

(defun agent-team--demote-headings (text)
  "Demote every Org heading in TEXT by one level (prepend one star).
Lines inside #+BEGIN_SRC/#+END_SRC blocks are never touched — the
file-target sketches must stay byte-level."
  (let ((in-src nil))
    (mapconcat
     (lambda (line)
       (cond
        ((string-match-p "\\`#[+]BEGIN_SRC" line) (setq in-src t) line)
        ((string-match-p "\\`#[+]END_SRC" line) (setq in-src nil) line)
        ((and (not in-src) (string-match-p "\\`\\*+ " line))
         (concat "*" line))
        (t line)))
     (split-string text "\n") "\n")))

(defun agent-team--candidates-part ()
  "The CANDIDATES section of the teamify prompt: land agent-team/CANDIDATES.org in the
repo by FETCHING the canonical file (khaalidrafi/agent-team.el
templates/CANDIDATES.org @ ai/main). Never inline a snapshot in chat —
a prompt copy goes stale; the fetched file is current. Mirrored by
scripts/build_teamify_prompt.py candidates_part()."
  (concat
   "  COMMON's MODELS + STAFFING laws point at agent-team/CANDIDATES.org —\n"
   "  a fresh teamify must not dangle.\n\n"
   "#+BEGIN_SRC bash\n"
   "mkdir -p agent-team\n"
   "curl -fsSL https://raw.githubusercontent.com/khaalidrafi/agent-team.el/ai/main/templates/CANDIDATES.org \\\n"
   "  -o agent-team/CANDIDATES.org\n"
   "grep -m1 '^#+TITLE: CANDIDATES.org' agent-team/CANDIDATES.org\n"
   "grep -m1 '^#+EXPIRY-LAW:' agent-team/CANDIDATES.org\n"
   "wc -l agent-team/CANDIDATES.org   # hundreds of lines expected\n"
   "#+END_SRC\n\n"
   "  Fetch fallback, in order:\n"
   "  1. sanity greps fail, or curl is unavailable — WebFetch the GitHub\n"
   "     blob page (khaalidrafi/agent-team.el @ ai/main,\n"
   "     templates/CANDIDATES.org) and write the file from that view\n"
   "  2. still failing — STOP, name it, ask the Owner. NEVER proceed with\n"
   "     a dangling pointer (COMMON would point at nothing)\n\n"
   "  The file is inventory, not endorsement: staffing filters per\n"
   "  COMMON; commit the file in the teamify commit (ai/teamify)\n"))

;;;###autoload
(defun agent-team-teamify-prompt (&optional repo project not-touch pat fresh)
  "Build the ONE team-making prompt from templates/ for REPO.
Assembles: the USER's global AGENTS.md (when `agent-team-global-agents-md'
points at a real file — the chat BEGINS under the user's global law,
Owner order 2026-10-21) + FILL BLOCK (REPO / PROJECT / NOT-TOUCH / PAT)
+ templates/COMMON.org (the master law, FIRST — Owner 2026-10-26 #hq:
common MUST go at first, everywhere; section headings are FUNCTIONAL
descriptions, never template names — Owner 2026-10-27 #hq: "Remove
COMMON... and similar template name headings from prompts"; the
canonical manual, inlined at build time from its canonical home — no
per-repo copies drift) + the mode layer (templates/BOOTSTRAP.org for a
FRESH project, templates/TEAMIFY.org for an existing one) + the
CANDIDATES fetch law (agent-team/CANDIDATES.org is landed by FETCHING
the canonical file — COMMON's MODELS + STAFFING laws point at it, so a
teamify must not dangle). Puts
the result in the *agent-team prompt* buffer AND the kill-ring, ready
to paste into a fresh chat with the team's Lead. The PAT travels in
the prompt only — never stored in files/commits/board (Owner order
2026-10-21)."
  (interactive)
  (unless repo
    (setq repo (read-string "REPO (url; team-truth branch is ai/main): "))
    (setq project (read-string "PROJECT (2-4 lines: what/state/done-today): "))
    (setq not-touch (read-string "NOT-TOUCH (paths/ops; RET = none): "))
    (setq pat (read-passwd "PAT (github_pat_, no rotation): "))
    (setq fresh (y-or-n-p "FRESH project? (yes = BOOTSTRAP layer, no = TEAMIFY) ")))
  (let* ((layer (agent-team--template (if fresh "BOOTSTRAP.org" "TEAMIFY.org")))
         (manual (agent-team--template "COMMON.org"))
         (law (and agent-team-global-agents-md
                   (file-exists-p agent-team-global-agents-md)
                   (with-temp-buffer
                     (insert-file-contents agent-team-global-agents-md)
                     (buffer-string))))
         (prompt (concat
                  "#+TITLE: TEAM-MAKING PROMPT — " repo "\n"
                  "# Built by M-x agent-team-teamify-prompt from agent-team.el\n"
                  "# templates/ — regenerate there, never hand-edit a built prompt.\n\n"
                  (if law
                      (concat
                       "* GLOBAL AGENTS.MD — the user's global law (pkg variable"
                       " `agent-team-global-agents-md'); this chat BEGINS under"
                       " it, and the same file bakes into every agent's global"
                       " config in CI\n\n"
                       law "\n\n")
                    "")
                  "* HOW TO USE (Director)\n"
                  "- ONE prompt for ONE fresh chat with the team's Lead — paste\n"
                  "  it whole, in order; every section is load-bearing.\n"
                  "- The only fill is the PAT in the FILL BLOCK below — fill it\n"
                  "  before pasting; the prompt is then self-contained.\n"
                  "- Mode: " (if fresh "BOOTSTRAP (fresh project)"
                               "TEAMIFY (existing project, no team setup)") "\n"
                  "- Regenerate with M-x agent-team-teamify-prompt; never hand-edit.\n\n"
                  "* FILL BLOCK (Director)\n"
                  "- REPO: " repo " — team-truth branch: ai/main\n"
                  "- PROJECT: " project "\n"
                  "- NOT-TOUCH: " (if (or (null not-touch) (string-empty-p not-touch))
                                      "none declared" not-touch) "\n"
                  "- PAT: " pat "\n"
                  "  (reuse the same token, no rotation; use immediately; NEVER\n"
                  "  store in files/commits/board/logs)\n\n"
                  agent-team--team-ci-brief "\n"
                  "* MASTER LAW (single source of truth;"
                  " canonical copy: khaalidrafi/agent-team.el"
                  " templates/COMMON.org; changes land there first, teams"
                  " receive them via TEAM UPDATE)\n\n"
                  (agent-team--strip-template-header manual) "\n"
                  "* THE TASK — "
                  (if fresh "bootstrap a fresh project"
                    "teamify an existing project (no team setup)")
                  "\n\n"
                  (agent-team--demote-headings
                   (agent-team--strip-template-header layer)) "\n"
                  "* HIRING POOL — land agent-team/CANDIDATES.org"
                  " in the repo (never inline it in chat — one canonical copy"
                  " lives in khaalidrafi/agent-team.el templates/CANDIDATES.org"
                  " @ ai/main; a snapshot inside a prompt goes stale, so fetch"
                  " the file CURRENT at teamify time)\n\n"
                  (agent-team--candidates-part)))
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

;;; One-command project setup (CI chain + teamify prompt) ---------------------
;;;
;;; Owner order 2026-10-21 10:12Z (#hq): "The CI based agent team setup
;;; should be reusable in the Emacs pkg agent-team.el. With one command,
;;; the setup will be made in a project and the prompt will be provided to
;;; the user."  ONE command = `agent-team-setup-project': it scaffolds the
;;; CI chain (.github/workflows/agent-team.yml from templates/agent-team.yml,
;;; harness agent configs, the secret guard, the harness Dockerfile) and
;;; then builds the teamify prompt (mode layer + templates/COMMON.org)
;;; with the project's REPO prefilled.  Existing files are never clobbered
;;; silently — adoption is the EM's call, same law as `agent-team-init'.
;;;
;;; GLOBAL AGENTS.MD LAW (Owner order 2026-10-21 ~12:44Z, superseding the
;;; AGENT-LAW.md invention): the setup NEVER creates or generates any
;;; AGENTS.md — a project's own repo-root AGENTS.md is left untouched and
;;; is what the harness bakes.  When the project has none, the USER points
;;; `agent-team-global-agents-md' at THEIR global AGENTS.md path: the
;;; setup transports that file byte-identical (docker/harness/AGENTS.md)
;;; for the CI bake, and the teamify prompt BEGINS with its content so a
;;; fresh web chat starts under the user's own global law.

(defcustom agent-team-global-agents-md nil
  "Path to YOUR global AGENTS.md — used in CI and at web-chat beginning
(Owner order 2026-10-21 ~12:44Z).  When the target project has no
repo-root AGENTS.md of its own, the setup transports THIS file
byte-identical into the harness bake (docker/harness/AGENTS.md; the
canonical kit Dockerfile ci/docker/harness/Dockerfile COPYs it into
each agent's verified global config path: OpenCode
~/.config/opencode/AGENTS.md, Goose ~/.config/goose/.goosehints, Qoder
~/.qoder/AGENTS.md, CodeBuddy ~/.codebuddy/CODEBUDDY.md, OMP
~/.omp/agent/AGENTS.md + ~/.omp/agent/RULES.md, pi
~/.pi/agent/AGENTS.md; dsh, Cursor, Copilot and mcode have no verified
global slot — their law rides the composed brief) and embeds its
content at the TOP of every teamify prompt, so fresh web chats begin
under your global law.
The file is NEVER generated, rewritten or invented by the setup — you
own it; the setup only copies it.  nil = no law transport (the Dockerfile
scaffold then omits the bake COPY lines)."
  :type '(choice (const :tag "none" nil)
                 (file :tag "global AGENTS.md path"))
  :group 'agent-team)

(defconst agent-team--slot-rx "{{\\([A-Z_]+\\)}}"
  "Slot token shape in templates/agent-team.yml: {{NAME}}, caps + underscore.")

(defun agent-team--fill-slots (template slots)
  "Fill {{NAME}} slot tokens in TEMPLATE from the SLOT alist.
Plain string replacement, every token exactly once per occurrence;
unknown/missing tokens stay visible for `agent-team--unfilled-slots'."
  (let ((out template))
    (dolist (pair slots out)
      (setq out (string-replace (concat "{{" (car pair) "}}")
                                (or (cdr pair) "") out)))))

(defun agent-team--unfilled-slots (text)
  "List leftover {{NAME}} tokens in TEXT (empty list = fully filled)."
  (let ((pos 0) out)
    (while (string-match agent-team--slot-rx text pos)
      (push (match-string 1 text) out)
      (setq pos (match-end 0)))
    (nreverse out)))

(defun agent-team--pkg-file (relpath)
  "Absolute path of a file packaged with this library (RELPATH from the
pkg root), or nil when the file is not installed (single-file installs
carry only the .el + templates/)."
  (let* ((lib (or (locate-library "agent-team") load-file-name))
         (dir (and lib (file-name-directory (expand-file-name lib)))))
    (when dir
      (let ((f (expand-file-name relpath dir)))
        (and (file-exists-p f) f)))))

(defun agent-team--repo-slug (&optional root)
  "OWNER/REPO from the origin remote of the git repo at ROOT (nil if none)."
  (let* ((default-directory (file-name-as-directory
                             (or root (agent-team--root))))
         (url (string-trim
               (or (car (ignore-errors
                          (process-lines "git" "remote" "get-url" "origin")))
                   ""))))
    (when (string-match "\\([^/:]+\\)/\\([^/]+?\\)\\(?:\\.git\\)?\\'" url)
      (concat (match-string 1 url) "/" (match-string 2 url)))))

(defun agent-team--detect-gate (&optional root)
  "Detect the project's landing gate at ROOT.
Returns a plist (:name :setup :run :install :cmd): the gate NAME, the
extra TEST-JOB steps (:setup, step blocks), the gate run body (:run, for
the test job), dependency install lines (:install, for the finalize
gate), and the single gate command (:cmd, called by finalize's
race-proof loop).  Detection order: pytest -> npm -> make -> Elisp (this
package's own shape) -> loud placeholder the Lead must fill."
  (let* ((root (file-name-as-directory (or root (agent-team--root))))
         (has (lambda (f) (file-exists-p (expand-file-name f root)))))
    (cond
     ((or (funcall has "pytest.ini") (funcall has "pyproject.toml")
          (funcall has "setup.cfg"))
      (list :name "pytest"
            :setup (concat
                    "      - uses: actions/setup-python@v5\n"
                    "        with:\n"
                    "          python-version: '3.12'\n"
                    "          cache: pip\n"
                    (when (funcall has "requirements.txt")
                      "      - name: Install project deps\n        run: pip install -r requirements.txt pytest\n")
                    (when (or (funcall has "pyproject.toml") (funcall has "setup.py"))
                      "      - name: Install project\n        run: pip install -e .\n"))
            :run "          python -m pytest -q"
            :install (concat
                      (when (funcall has "requirements.txt")
                        "          pip install -r requirements.txt pytest\n")
                      (when (or (funcall has "pyproject.toml") (funcall has "setup.py"))
                        "          pip install -e .\n"))
            :cmd "python -m pytest -q"))
     ((funcall has "package.json")
      (list :name "npm test"
            :setup ""
            :run "          npm ci --silent\n          npm test --silent"
            :install "          npm ci --silent\n"
            :cmd "npm test --silent"))
     ((funcall has "Makefile")
      (list :name "make test"
            :setup ""
            :run "          make test"
            :install ""
            :cmd "make test"))
     ((funcall has "agent-team.el")
      (list :name "byte-compile + ert"
            :setup (concat
                    "      - name: Install Emacs\n"
                    "        run: sudo apt-get update -qq && sudo apt-get install -y -qq emacs-nox\n")
            :run (concat
                  "          emacs -Q --batch -L . --eval \"(unless (byte-compile-file \\\"agent-team.el\\\") (kill-emacs 1))\"\n"
                  "          emacs -Q --batch -L . -L tests -l tests/agent-team-test.el --eval '(ert-run-tests-batch-and-exit \\\"agent-team\\\")'")
            :install "          sudo apt-get update -qq && sudo apt-get install -y -qq emacs-nox\n"
            :cmd "emacs -Q --batch -L . --eval \"(unless (byte-compile-file \\\"agent-team.el\\\") (kill-emacs 1))\""))
     (t
      (list :name "PLACEHOLDER — the Lead defines this project's gate"
            :setup ""
            :run "          echo \"agent-team setup: no gate detected — define the landing gate (tests) for this project\" && exit 1"
            :install ""
            :cmd "echo \"agent-team setup: no gate detected — define the landing gate for this project\" && exit 1")))))

(defconst agent-team--seat-env-default
  "      GROQ_API_KEY: ${{ secrets.GROQ_API_KEY }}
      OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_API_KEY }}
      ZAI_API_KEY: ${{ secrets.ZAI_API_KEY }}
      QODER_PERSONAL_ACCESS_TOKEN: ${{ secrets.QODER_PERSONAL_ACCESS_TOKEN }}
      CODEBUDDY_AUTH_TOKEN: ${{ secrets.CODEBUDDY_AUTH_TOKEN }}
      GOMODEL_MASTER_KEY: ${{ secrets.GOMODEL_MASTER_KEY }}
      LARK_WEBHOOK_PRINCIPAL_ENGINEER: ${{ secrets.LARK_WEBHOOK_PRINCIPAL_ENGINEER }}
      LARK_WEBHOOK_SOFTWARE_ENGINEER: ${{ secrets.LARK_WEBHOOK_SOFTWARE_ENGINEER }}
      LARK_WEBHOOK_QUALITY_ASSURANCE_ENGINEER: ${{ secrets.LARK_WEBHOOK_QUALITY_ASSURANCE_ENGINEER }}
      LARK_WEBHOOK_RELEASE_ENGINEER: ${{ secrets.LARK_WEBHOOK_RELEASE_ENGINEER }}"
  "Turn-job env block ({{SEAT_ENV}} default): repo secrets ride as env-var
NAMES only — values live in each repo's secret store, never copied.
No static GOMODEL_GATEWAY_URL since the 2026-10-22 resolution law:
a static job-level env would OVERRIDE the resolve step's GITHUB_ENV
value — the chain's resolve step is the single source of truth.")

(defconst agent-team--rotation-default
  "            openrouter/poolside/laguna-s-2.1:free@opencode*) NEXT_SEAT=principal-engineer ;;
            groq/qwen3.8-27b@goose*Software*)                NEXT_SEAT=software-engineer ;;
            zai/glm-4.7-flash@opencode*)                     NEXT_SEAT=quality-assurance-engineer ;;
            groq/qwen3.8-27b@goose*Release*)                 NEXT_SEAT=release-engineer ;;
            qwen3.8-flash@qoder*)                            NEXT_SEAT=platform-engineer ;;
            *)                                               NEXT_SEAT=unknown-rotation-pointer ;;"
  "Rotation case ({{ROTATION_CASE}} default): the engine's proven five-seat
round.  Re-run setup with overrides when this team's MEMBERS.org differs.
ATOMIC RENAME + UNKNOWN-REFUSAL laws: an
unknown pointer REFUSES — the segment runner hits its `*)' arm and
returns BLOCKED (rotation case gap) instead of silently running a wrong
lane; when renaming a member id, change the #+TURN pointer, the
turn-control arm and the advance arm in ONE commit; keep legacy ids as
alias arms during migration.")

(defconst agent-team--next-map-default
  "            principal-engineer)          NEXT=\"groq/qwen3.8-27b@goose (Software Engineer)\" ;;
            software-engineer)           NEXT=\"zai/glm-4.7-flash@opencode (Quality Assurance Engineer)\" ;;
            quality-assurance-engineer)  NEXT=\"groq/qwen3.8-27b@goose (Release Engineer)\" ;;
            release-engineer)            NEXT=\"openrouter/poolside/laguna-s-2.1:free@opencode (Principal Engineer)\" ;;
            platform-engineer)           NEXT=\"openrouter/poolside/laguna-s-2.1:free@opencode (Principal Engineer)\" ;;
            *)                           NEXT=\"${TURN}\" ;;"
  "Rotation advance map ({{NEXT_MAP}} default): seat -> next #+TURN pointer.
UNKNOWN-REFUSAL law: the `*)' arm keeps #+TURN
unchanged for an unknown seat (NEXT=${TURN}) — never advance to a
guessed pointer; the run reports BLOCKED so the Lead repairs the map;
a silently wrong advance was the no-op-pointer bug.")

(defconst agent-team--segment-runner-default
  "            principal-engineer)
              # OpenCode body + poolside: OpenCode cannot host the model
              # (absent from its models.dev catalog — demo/01 evidence) and
              # OpenRouter's free quota is exhausted. Attempt order:
              # 1. opencode (in case the catalog/defect is repaired);
              # 2. goose via OpenRouter poolside — SELF-HEALS the moment the
              #    Owner adds ~10 credits (harness/01 item 1/2); OpenRouter
              #    normalizes Goose's developer role server-side (demo/01
              #    evidence: qwen3.8-27b worked via OpenRouter, Groq didn't).
              if opencode run --print-logs --model \"openrouter/poolside/laguna-s-2.1:free\" \"$BRIEF\"; then
                echo \"TURN_RESULT=opencode run OK\"
              elif env GOOSE_PROVIDER=openai GOOSE_MODEL=\"poolside/laguna-s-2.1:free\" \\
                   OPENAI_API_KEY=\"$OPENROUTER_API_KEY\" \\
                   OPENAI_HOST=\"https://openrouter.ai/api/v1\" \\
                   goose run --no-session -t \"$BRIEF\"; then
                echo \"TURN_RESULT=goose run OK (lane: openrouter/poolside@goose — credits landed)\"
              elif env GOOSE_PROVIDER=openai GOOSE_MODEL=minimax/minimax-m3.1-flash:free \\
                   OPENAI_API_KEY=\"$OPENROUTER_API_KEY\" \\
                   OPENAI_HOST=\"https://openrouter.ai/api/v1\" \\
                   goose run --no-session -t \"$BRIEF\"; then
                echo \"TURN_RESULT=goose run OK (lane: minimax-m3.1-flash:free@goose — promo hire 05:33Z)\"
              elif codebuddy -p \"$BRIEF\"; then
                echo \"TURN_RESULT=codebuddy run OK (lane: fallback codebuddy@cli — poolside dead)\"
              elif env HOME=/usr/local/lib/qoder-home \\
                   qoder -p \"$BRIEF\" --output-format json \\
                   --permission-mode accept_edits --max-turns 100; then
                echo \"TURN_RESULT=qoder run OK (lane: fallback qwen3.8@qoder — poolside dead)\"
              else
                echo \"TURN_RESULT=BLOCKED (poolside dead on opencode+goose, fallbacks codebuddy+qoder dead too — harness/01)\"
              fi
              ;;
            quality-assurance-engineer|software-engineer|release-engineer)
              # LANE (mesh/01 repair, Lead, 2026-10-20 15:45Z): every lane on
              # the hired/fallback brains is dead — Groq rejects the
              # `developer` role Goose sends (400, req_01m5cqbghke9),
              # OpenRouter free-models-per-day exhausted, OpenCode body
              # headless-defective. The ONE live lane with its own quota:
              # ZAI glm-4.7-flash — same OpenAI-compatible schema. Goose goes
              # through its openai provider with OPENAI_HOST pointed at ZAI.
              # Fallback: the rostered nemotron lane (in case OpenRouter
              # quota resets).
              if env GOOSE_PROVIDER=openai GOOSE_MODEL=glm-4.7-flash \\
                   OPENAI_API_KEY=\"$ZAI_API_KEY\" \\
                   OPENAI_HOST=\"https://api.z.ai\" \\
                   OPENAI_BASE_PATH=\"/api/paas/v4/chat/completions\" \\
                   goose run --no-session -t \"$BRIEF\"; then
                echo \"TURN_RESULT=goose run OK (lane: zai/glm-4.7-flash@goose)\"
              elif env GOOSE_PROVIDER=openai GOOSE_MODEL=minimax/minimax-m3.1-flash:free \\
                   OPENAI_API_KEY=\"$OPENROUTER_API_KEY\" \\
                   OPENAI_HOST=\"https://openrouter.ai/api/v1\" \\
                   goose run --no-session -t \"$BRIEF\"; then
                echo \"TURN_RESULT=goose run OK (lane: minimax-m3.1-flash:free@goose — OpenRouter promo hire 05:33Z)\"
              elif goose run --no-session -t \"$BRIEF\"; then
                echo \"TURN_RESULT=goose run OK (lane: ${GOOSE_MODEL} — OpenRouter quota recovered)\"
              elif codebuddy -p \"$BRIEF\"; then
                echo \"TURN_RESULT=codebuddy run OK (lane: fallback codebuddy@cli — zai+openrouter dead)\"
              elif env HOME=/usr/local/lib/qoder-home \\
                   qoder -p \"$BRIEF\" --output-format json \\
                   --permission-mode accept_edits --max-turns 100; then
                echo \"TURN_RESULT=qoder run OK (lane: fallback qwen3.8@qoder — zai+openrouter dead)\"
              else
                echo \"TURN_RESULT=BLOCKED (all rostered lanes dead: zai+openrouter+codebuddy+qoder — harness/01)\"
              fi
              ;;
            platform-engineer)
              # Acting Platform Engineer qwen3.8-flash@qoder — Qoder-on-CI
              # PROOF lane (AUTH-READY 2026-10-21: PAT -> repo secret
              # QODER_PERSONAL_ACCESS_TOKEN; the CLI auto-detects CI, no
              # browser). HOME is pinned to the install dir: the `qoder`
              # launcher resolves its CLI under ITS HOME (proof run
              # 39467719908 failed with the default /home/agent).
              # Fallback lane per roster: zai/glm-4.7-flash@goose (acting).
              if env HOME=/usr/local/lib/qoder-home \\
                   qoder -p \"$BRIEF\" --output-format json \\
                   --permission-mode accept_edits --max-turns 100; then
                echo \"TURN_RESULT=qoder run OK (lane: qwen3.8-flash@qoder — body PROVEN on CI)\"
              elif env GOOSE_PROVIDER=openai GOOSE_MODEL=glm-4.7-flash \\
                   OPENAI_API_KEY=\"$ZAI_API_KEY\" \\
                   OPENAI_HOST=\"https://api.z.ai\" \\
                   OPENAI_BASE_PATH=\"/api/paas/v4/chat/completions\" \\
                   goose run --no-session -t \"$BRIEF\"; then
                echo \"TURN_RESULT=goose run OK (acting lane: zai/glm-4.7-flash@goose — qoder CLI failed)\"
              elif env GOOSE_PROVIDER=openai GOOSE_MODEL=minimax/minimax-m3.1-flash:free \\
                   OPENAI_API_KEY=\"$OPENROUTER_API_KEY\" \\
                   OPENAI_HOST=\"https://openrouter.ai/api/v1\" \\
                   goose run --no-session -t \"$BRIEF\"; then
                echo \"TURN_RESULT=goose run OK (lane: minimax-m3.1-flash:free@goose — promo hire 05:33Z)\"
              elif codebuddy -p \"$BRIEF\"; then
                echo \"TURN_RESULT=codebuddy run OK (lane: fallback codebuddy@cli — qoder+zai dead)\"
              else
                echo \"TURN_RESULT=BLOCKED (qoder+zai+codebuddy all failed — harness/01)\"
              fi
              ;;"
  "Seat -> body lane map ({{SEGMENT_RUNNER}} default): the engine's proven
attempt-order lanes incl. the minimax-m3.1-flash:free relief lane.
Override when this team's harness bakes different bodies.")

(defconst agent-team--team-ci-brief
  "* TEAM CI (how the chain runs — read before the first dispatch)

This section explains the automation that runs the team, in plain words.

- The two files that matter:
  - .github/workflows/agent-team.yml — the automation. Only the Lead
    edits it.
  - agent-team/TEAM-CONTROL.org — a small settings file. Each line
    sets one thing:
    - #+OBJECTIVE — the goal the team is working on right now.
    - #+OBJECTIVE-STATE — OPEN (still working) or COMPLETE (finished).
    - #+TURN — the name of the member who does the NEXT piece of work.
    - #+KILL-SWITCH — ON means stop everything.
    - #+STALL-COUNT — how many runs in a row ended with no new work.
    - #+PAUSE-AFTER-TODO — ON or OFF (ON by default; see below).
    - #+CHAIN-PAUSE — ON means the automation takes a break.

- What happens in one cycle, in order:
  1. test — the project's tests run. Work only counts when they pass.
  2. probe — a tiny check that the next member's tool is reachable.
     It never judges the quality of anyone's work.
  3. turn — the named member does ONE piece of work:
     1. their session is restored (they remember earlier work),
     2. they work once, inside the prepared container,
     3. their session is cleaned and saved,
     4. their branch is uploaded, and #+TURN names the next member.
  4. finalize — the results are collected:
     1. finished work is merged automatically — but only when the
        tests passed,
     2. the after-delivery pause check runs,
     3. Jev (the automatic review step) gives its opinion,
     4. runs with no new work are counted,
     5. the automation starts the next cycle by itself — as long as
        the goal is OPEN and the kill switch is OFF.

- When does the automation stop?
  - Only for: kill switch ON, goal marked COMPLETE, failed tests, or
    a #+CHAIN-PAUSE break.
  - A run that produces nothing is NOT a failure. It waits 5 minutes
    and tries again.
  - The team decides how many cycles the goal needs.

- Safety rules (follow them exactly):
  - If #+TURN names a member nobody knows, the run STOPS and reports
    BLOCKED. It never guesses and runs someone else.
  - A run that ends \"successfully\" but produced ZERO new commits is
    NOT progress. The number of new commits is checked after every run.
  - After a member delivers a TODO, the automation PAUSES. This is the
    default (pause-after-todo):
    - the run stops cleanly, nothing is spent,
    - the Lead reviews the work, then clears #+CHAIN-PAUSE,
    - if the setting is missing, it still pauses — safe by default,
    - only the Owner can order it OFF, for one long multi-task run.
  - Always name the tool that ACTUALLY did the work.
  - If a paid tool failed, say so: \"PAID LANE FAILED — no credits were
    spent\". Never pretend a paid run happened.

- How every AI tool gets both rule files:
  - Each team repo carries the shared kit in a folder named ci/.
  - Global rules = ci/AGENTS.md. Project rules = the repo's own
    AGENTS.md at its root.
  - When the tool image is built, the global rules are copied into
    each tool's own settings file (7 of the 10 tools have one:
    OpenCode, Goose, Qoder, CodeBuddy, OMP, pi, Copilot).
  - The other 3 tools (dsh, Cursor, mcode) have no settings file —
    for those ONLY, the run pastes the global rules in front of the
    prompt (ci/bin/law_brief.sh).
  - The tool image comes from ci/docker/harness/Dockerfile and
    carries all 10 tools: OpenCode, Goose, Qoder, CodeBuddy, OMP, pi,
    dsh, Cursor, Copilot, mcode.
  - The tests job also checks every commit message against the rules
    (ci/bin/commit_msg_guard.sh).

- CI work goes through agent-org (the same program you use by hand):
  - agent-org is the tool that starts a coding agent, sends it your
    prompt, and keeps the conversation. It already does all of that.
  - In CI, agent-org simply runs without a window. Nothing new — no
    separate machinery.
  - One CI run = one prompt sent, the same way a normal send works.
    The work clock starts at the exact moment the prompt goes out.
  - If agent-org cannot run there, the run calls the agent's own
    command directly instead. The old way is never removed.
  - Web/chat tools stay hands-on — the one thing CI does not automate.

- The GoModel gateway (khaalidrafi/llmfisher):
  - The single door to ALL the Owner's models. Jev's review step is
    just one of the things that uses it.
  - Normal member work still talks to the model companies DIRECTLY
    (the 2026-10-20 law): a model behind the gateway counts as
    unreachable until a check proves otherwise.
  - The gateway is health-checked every run and at review time. Its
    address is found by trying, in order:
    1. the vars.GOMODEL_GATEWAY_URL setting, if set,
    2. https://ai.khalidrafi.tech,
    3. localhost:8080,
    4. only if nothing answered: start the enterpilot/gomodel
       container right there in the runner.
  - Review: gateway up = Jev decides; gateway down = simple local
    rules decide. Either way the run stays green.

- The team chat lives IN the repo (no Telegram, no Discord):
  - The chat file is agent-team/TEAM-CHAT.org. Every message sits
    under the name of who sent it.
  - The Lead reads the file and copies messages addressed to the
    Owner into #hq, word for word.
  - Every message is sent by a command — never typed into the file:
    - Emacs members: M-x agent-team-chat-send.
    - CI members: the team-chat command (it reads AGENT_CHAT_FROM,
      AGENT_CHAT_TO, AGENT_CHAT_KIND, AGENT_CHAT_BODY).
  - The command checks the message shape and adds it at the end of
    the file. Writing a chat entry by hand breaks the rules.

- Tools that cost money per prompt (ask the Owner FIRST):
  - Cursor (`agent -p'), Copilot CLI (`copilot -p'), mcode
    (`mcode exec').
  - Use one only when the Owner ordered it for this task (or a
    standing OK the Lead wrote into TEAM-CONTROL.org).
  - Otherwise use a free tool, or one the Owner's keys already pay for.
  - They stay installed in the tool image, so an approved run needs
    no rebuild.

- The two rule files, handled with care:
  - Never invent a root AGENTS.md while setting up the team.
  - The project's own AGENTS.md is its law — keep it correct, never
    delete or overwrite it carelessly.
  - Team rules inside the repo live in agent-team/TEAM-CONTROL.org
    and agent-team/TEAM.md.

- Branches and protected files:
  - Members work on ai/turn-* branches; finished work merges only
    after the tests pass.
  - agent-team/TEAM-CHAT.org merges by union (both sides kept), so
    two members appending at once never conflict.
  - Only the Lead edits: .github/workflows/*, .github/scripts/*,
    agent-team/TEAM-CONTROL.org, .gitattributes, and which ci/
    commit the repo points at.

- Repo secrets (write-only; never copy secret VALUES anywhere; only
  their NAMES travel — that is the ENV-VAR LAW):
  - In use: QODER_PERSONAL_ACCESS_TOKEN, ZAI_API_KEY,
    OPENROUTER_API_KEY, GROQ_API_KEY, CODEBUDDY_AUTH_TOKEN,
    GOMODEL_MASTER_KEY, LARK_WEBHOOK_<ROLE> (one Lark bot per role —
    the live reporting channel), CLINE_AUTH_JSON, MCODE_AUTH_JSON.
  - Old ones you may delete: TELEGRAM_BOT_TOKEN, TELEGRAM_OWNER_ID,
    every DISCORD_WEBHOOK_*.
  - One missing key: that tool is skipped, everything else goes on.
  - A member's own key missing: that member sits out, the next member
    takes the turn, the run stays green."
  "The TEAM CI block added to every teamify prompt the pkg builds — the
prompt carries the chain's operating manual, not just the team laws.")

(defun agent-team--default-slots (&optional root repo)
  "Slot values for templates/agent-team.yml at ROOT (slug REPO).
Every template token MUST be covered here — this function is the single
place a token is allowed to be defined.  Gate blocks come from
`agent-team--detect-gate'; rotation/segment blocks come from the engine
default constants."
  (let* ((slug (or repo (agent-team--repo-slug root) "OWNER/REPO"))
         (project (or (nth 1 (split-string slug "/")) slug))
         (gate (agent-team--detect-gate root)))
    (list
     (cons "PROJECT" project)
     (cons "REPO" slug)
     (cons "WORKFLOW_FILE" "agent-team.yml")
     (cons "CRON" "17 1,5,9,13,17,21 * * *")   ; engine default: 6 turns/day; the self-chain owns pacing
     (cons "GATE_NAME" (plist-get gate :name))
     (cons "GATE_SETUP" (plist-get gate :setup))
     (cons "GATE_CMD" (plist-get gate :run))
     (cons "GATE_INSTALL" (plist-get gate :install))
     (cons "GATE_SH" (plist-get gate :cmd))
     (cons "SEAT_ENV" agent-team--seat-env-default)
     (cons "DOCKER_RUN_ENV"
           "-e OPENROUTER_API_KEY -e ZAI_API_KEY -e GROQ_API_KEY -e CODEBUDDY_AUTH_TOKEN -e QODER_PERSONAL_ACCESS_TOKEN")
     (cons "HARNESS_TAG" "agent-team-harness")
     (cons "FROM_ID" (concat "team-lead (glm-5.3-flash, Agent Team @" slug ")"))
     (cons "ROTATION_CASE" agent-team--rotation-default)
     (cons "NEXT_MAP" agent-team--next-map-default)
     (cons "SEGMENT_RUNNER" agent-team--segment-runner-default)
     (cons "SEGMENT_PRE"
           "          # (no project prep — add this project's pre-segment setup here)")
     (cons "TOP_GREP" "'^\\*+ (TODO|PROGRESS|BLOCKED|ONGOING|PENDING|WAIT)'")
     (cons "HANDLES"
           "@principal-engineer @software-engineer @quality-assurance-engineer @release-engineer @lead @owner")
     (cons "REPO_CONTEXT" "README*, STATE.org")
     (cons "WORK_ORDER"
           "          WORK ORDER: none pinned — the TEAM OBJECTIVE and the oldest-open-board-item rule decide; a pinned Owner order would appear here."))))

(defun agent-team--harness-dockerfile-scaffold (law-src)
  "The fresh-project harness Dockerfile scaffold text; LAW-SRC names the
global-law bake source for the COPY lines: \"AGENTS.md\" (the project's
own repo-root file, present and untouched), \"docker/harness/AGENTS.md\"
(the USER's global AGENTS.md transported via `agent-team-global-agents-md'),
or nil (no law bake yet — the scaffold points the user at the variable)."
  (let ((law-copy
         (pcase law-src
           ("AGENTS.md"
            "#     Global agent law = the PROJECT's own repo-root AGENTS.md
#     (present — the setup never touches it): baked into each agent's
#     VERIFIED global config path (docs checked 2026-10-21: OpenCode
#     ~/.config/opencode/AGENTS.md, Goose ~/.config/goose/.goosehints,
#     CodeBuddy ~/.codebuddy/CODEBUDDY.md; Qoder reads the repo root).
COPY AGENTS.md /home/agent/.config/opencode/AGENTS.md
COPY AGENTS.md /home/agent/.config/goose/.goosehints
COPY AGENTS.md /home/agent/.codebuddy/CODEBUDDY.md")
           ("docker/harness/AGENTS.md"
            "#     Global agent law = the USER's global AGENTS.md, pointed at
#     by the pkg variable `agent-team-global-agents-md' and transported
#     here byte-identical (a COPY of the user's file — never generated).
#     Baked into each agent's VERIFIED global config path (docs checked
#     2026-10-21: OpenCode ~/.config/opencode/AGENTS.md, Goose
#     ~/.config/goose/.goosehints, CodeBuddy ~/.codebuddy/CODEBUDDY.md).
COPY docker/harness/AGENTS.md /home/agent/.config/opencode/AGENTS.md
COPY docker/harness/AGENTS.md /home/agent/.config/goose/.goosehints
COPY docker/harness/AGENTS.md /home/agent/.codebuddy/CODEBUDDY.md")
           (_
            "#     Global agent law: NONE baked yet — point the pkg variable
#     `agent-team-global-agents-md' at your global AGENTS.md and re-run
#     M-x agent-team-setup-project; the setup will transport your file
#     here (docker/harness/AGENTS.md) and the bake COPY lines appear at
#     the verified global paths (OpenCode/Goose/CodeBuddy)."))))
    (concat "# agent-team-harness — CI turn container with agent bodies PREINSTALLED
# (Owner order 2026-10-20 #hq: \"Use Docker containers with agents
# preinstalled. Don't install in CI. That's a waste of time. You'll have
# to make agent configs, too, and reuse them.\").  Secrets are NEVER
# baked: provider keys are injected per run as env vars from repo secrets.
# The PROJECT DEPS block below is this project's to fill — everything
# else is the pkg's proven recipe (re-scaffold with M-x
# agent-team-setup-project to adopt recipe updates).

FROM debian:stable-slim

RUN apt-get update -qq \\
 && apt-get install -y -qq --no-install-recommends \\
      git curl ca-certificates bzip2 jq procps nodejs npm \\
 && rm -rf /var/lib/apt/lists/*

# --- OpenCode body (preinstalled once, reused every turn) -------------------
RUN export HOME=/usr/local/lib/opencode-home \\
 && curl -fsSL https://opencode.ai/install | bash \\
 && chmod -R a+rX /usr/local/lib/opencode-home \\
 && ln -sf /usr/local/lib/opencode-home/.opencode/bin/opencode /usr/local/bin/opencode

# --- Goose body (direct tarball: the download_cli.sh installer opens
#     /dev/tty and dies on headless runners — demo/01 turn 2 evidence) ------
RUN mkdir -p /tmp/goose-dl \\
 && curl -fsSL -o /tmp/goose-dl/goose.tar.bz2 \\
      https://github.com/block/goose/releases/download/stable/goose-x86_64-unknown-linux-gnu.tar.bz2 \\
 && tar -xjf /tmp/goose-dl/goose.tar.bz2 -C /tmp/goose-dl \\
 && install -m 0755 /tmp/goose-dl/goose /usr/local/bin/goose \\
 && rm -rf /tmp/goose-dl

# --- CodeBuddy body (baked and DORMANT until an account credential
#     exists; headless needs -y in -p mode for tool use) --------------------
RUN npm install -g @tencent-ai/codebuddy-code \\
 && timeout 60 codebuddy --version

### PROJECT DEPS (fill: this project's runtime deps for the landing gate)
# RUN pip install --no-cache-dir pytest
# RUN npm --prefix app ci

# --- Non-root run user (matches the Actions runner uid 1001) ---------------
RUN useradd -m -u 1001 agent

# --- Baked agent configs (Owner: \"make agent configs, too, and reuse them\").
#     Keys are env-interpolated at run time; nothing secret is baked.
"
            law-copy "
COPY docker/harness/opencode.json     /home/agent/.config/opencode/opencode.json
COPY docker/harness/goose-config.yaml /home/agent/.config/goose/config.yaml
RUN chown -R agent:agent /home/agent

ENV HOME=/home/agent \\
    GOOSE_PROVIDER=openrouter \\
    GOOSE_MODEL=nvidia/nemotron-3.5-lightning:free
")))

;; agent-team--agent-law-md REMOVED 2026-10-21 (Owner: "No need for a
;; AGENT-LAW.md.") — no law file is ever invented; the CI bake source is
;; the project's own repo-root AGENTS.md, or the USER's global AGENTS.md
;; transported byte-identical via `agent-team-global-agents-md'.

(defun agent-team--scaffold-ci (root repo &optional force)
  "Scaffold the agent-team CI chain into the git repo at ROOT (slug REPO).
Writes/refreshes .github/workflows/agent-team.yml (from the pkg template
with `agent-team--default-slots'), copies the packaged harness agent
configs + secret guard, and writes a harness Dockerfile ONLY when
missing (per-project files are never clobbered).  NO AGENTS.md is ever
created or generated (Owner 2026-10-21): the CI global-law bake source
is the project's own repo-root AGENTS.md when it exists; otherwise the
USER's global AGENTS.md (`agent-team-global-agents-md') is transported
byte-identical to docker/harness/AGENTS.md.  FORCE refreshes the
workflow and the pkg-owned configs even when present.  Returns the list
of (FILE . ACTION) pairs."
  (let* ((root (file-name-as-directory (expand-file-name root)))
         (slots (agent-team--default-slots root repo))
         (tpl (agent-team--template "agent-team.yml"))
         (filled (agent-team--fill-slots tpl slots))
         (left (agent-team--unfilled-slots filled))
         (wf-dir (expand-file-name ".github/workflows/" root))
         (wf (expand-file-name "agent-team.yml" wf-dir))
         (sg-src (agent-team--pkg-file ".github/scripts/secret-guard.sh"))
         (sg-dir (expand-file-name ".github/scripts/" root))
         (sg (expand-file-name "secret-guard.sh" sg-dir))
         (hdir (expand-file-name "docker/harness/" root))
         (law-src (cond
                   ((file-exists-p (expand-file-name "AGENTS.md" root))
                    "AGENTS.md")
                   ((and agent-team-global-agents-md
                         (file-exists-p agent-team-global-agents-md))
                    "docker/harness/AGENTS.md")
                   (t nil)))
         (out '()))
    (when left
      (error "agent-team: template slots unfilled: %s" (string-join left ", ")))
    (make-directory wf-dir t)
    (make-directory hdir t)
    (when sg-src (make-directory sg-dir t))
    (dolist (spec (list
                   (cons wf (lambda ()
                              (when (and (file-exists-p wf) (not force))
                                (unless (y-or-n-p
                                         (format "agent-team: %s exists — refresh it? "
                                                 (file-relative-name wf root)))
                                  (user-error "agent-team: setup aborted — %s kept" wf)))
                              (write-region filled nil wf)
                              (list wf "filled from templates/agent-team.yml")))
                   (cons (expand-file-name "opencode.json" hdir)
                         (lambda ()
                          (let ((src (agent-team--pkg-file "docker/harness/opencode.json")))
                            (when (and src (or force (not (file-exists-p
                                                          (expand-file-name "opencode.json" hdir)))))
                              (copy-file src (expand-file-name "opencode.json" hdir) t)
                              (list (expand-file-name "opencode.json" hdir) "copied from pkg")))))
                   (cons (expand-file-name "goose-config.yaml" hdir)
                         (lambda ()
                          (let ((src (agent-team--pkg-file "docker/harness/goose-config.yaml")))
                            (when (and src (or force (not (file-exists-p
                                                          (expand-file-name "goose-config.yaml" hdir)))))
                              (copy-file src (expand-file-name "goose-config.yaml" hdir) t)
                              (list (expand-file-name "goose-config.yaml" hdir) "copied from pkg")))))
                   (cons (expand-file-name "Dockerfile" hdir)
                         (lambda ()
                          (let ((dst (expand-file-name "Dockerfile" hdir)))
                            (when (not (file-exists-p dst))
                              (write-region
                               (agent-team--harness-dockerfile-scaffold law-src)
                               nil dst)
                              (list dst
                                    (concat "scaffolded (PROJECT DEPS region to fill; law bake: "
                                            (or law-src "none yet — point agent-team-global-agents-md")
                                            ")"))))))
                   (cons (expand-file-name "AGENTS.md" hdir)
                         (lambda ()
                          ;; law TRANSPORT (never generation): the user's
                          ;; global AGENTS.md copied byte-identical — and
                          ;; re-copied on every setup so it stays in sync
                          (when (equal law-src "docker/harness/AGENTS.md")
                            (copy-file agent-team-global-agents-md
                                       (expand-file-name "AGENTS.md" hdir) t)
                            (list (expand-file-name "AGENTS.md" hdir)
                                  (concat "your global AGENTS.md transported byte-identical ("
                                          agent-team-global-agents-md ")")))))
                   (cons sg
                         (lambda ()
                          (when (and sg-src (or force (not (file-exists-p sg))))
                            (copy-file sg-src sg t)
                            (list sg "copied from pkg"))))))
      (pcase-let* ((`(,target . ,thunk) spec)
                   (res (funcall thunk)))
        (when res (push res out))))
    (nreverse out)))

;;;###autoload
(defun agent-team-setup-project (&optional root repo not-touch pat)
  "ONE command: make the agent-team CI setup in a project and provide
the teamify prompt (Owner order 2026-10-21 10:12Z).

In the git repo at ROOT this scaffolds the CI chain
(.github/workflows/agent-team.yml from templates/agent-team.yml —
landing gate auto-detected, engine rotation + lane defaults, GoModel
gateway lane (health-gated; used for Jev judgment at finalize; no
chat mirror since 2026-10-26),
the harness agent configs (opencode.json, goose-config.yaml),
the secret guard, and a harness Dockerfile when it has none (NO
AGENTS.md is ever created — the CI law bake uses the project's own
repo-root AGENTS.md when present, else your global AGENTS.md from
`agent-team-global-agents-md', Owner 2026-10-21).  Then it builds the
teamify prompt from templates/ (your global AGENTS.md at the top +
TEAMIFY layer + COMMON.org manual + the TEAM CI block) into *agent-team
prompt* + kill-ring, ready to paste into the team Lead's fresh chat.
Existing files are never clobbered silently; the workflow refresh is
asked for by name (adoption is the EM's call)."
  (interactive)
  (unless root
    (setq root (read-directory-name "Project root: " (agent-team--root))))
  (setq root (directory-file-name (expand-file-name root)))
  (unless repo
    (setq repo (read-string
                (format "Repo slug (%s): "
                        (or (agent-team--repo-slug root) "owner/repo"))))
    (when (string-empty-p repo)
      (setq repo (or (agent-team--repo-slug root)
                     (user-error "agent-team: no origin remote and no slug given")))))
  (unless not-touch
    (setq not-touch
          (read-string
           "NOT-TOUCH (paths/ops the team must never touch; RET = lead-owned defaults): "))
    (when (string-empty-p not-touch)
      (setq not-touch
            ".github/workflows/*, .github/scripts/*, agent-team/TEAM-CONTROL.org (lead-owned)")))
  (unless pat
    (setq pat (read-passwd "PAT (github_pat_ scoped to this repo; RET = leave a FILL slot): "))
    (when (string-empty-p pat) (setq pat nil)))
  (let* ((project (or (nth 1 (split-string repo "/")) repo))
         (report (agent-team--scaffold-ci root repo))
         (lines (mapcar (lambda (r)
                          (format "- %s: %s"
                                  (file-relative-name (car r) root)
                                  (cadr r)))
                        report)))
    (agent-team-teamify-prompt
     (concat "https://github.com/" repo)
     (concat project " — CI agent-team chain scaffolded by
agent-team.el (agent-team.yml + harness configs + secret guard are in
place; the team files under agent-team/ are to be (re)generated per
FILE TARGETS below). Re-scaffold command: M-x agent-team-setup-project.")
     not-touch
     (or pat "<<<FILL — paste the fine-grained PAT scoped to this repo>>>")
     nil)
    (with-current-buffer "*agent-team prompt*"
      (goto-char (point-max)))
    (message "agent-team setup: %d file(s) in %s — prompt built; paste into the Lead's fresh chat"
             (length lines) (abbreviate-file-name root))
    lines))
