;;; agent-team-sessions.el --- Live team buffer over per-role agent-org sessions -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Khalid Rafi
;; Author: Khalid Rafi <khaalidrafi@gmail.com>
;; Keywords: tools, ai, org
;; Package-Requires: ((emacs "28.1"))
;; URL: https://github.com/khaalidrafi/agent-team.el
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The Owner's law (Discord #hq, 2026-10-20 15:56): every team role gets its
;; own `agent-org' session, and ONE team buffer shows the live cross-agent
;; chat plus the current state of the work — which agents are running, which
;; tasks are running — powered by Org TODOs.
;;
;; Phase 1 ("the obvious cross agent-org chat", all here):
;;
;;  - a registry mapping role slugs to live agent-org chat buffers
;;    (`agent-team-session-register', `agent-team-session-start-role',
;;    `agent-team-sessions-adopt'),
;;  - `agent-team-team-buffer' — one read-only view of TEAM-CONTROL.org's
;;    switches, the board's active Org TODOs, every role's session status
;;    and mailbox UNREAD count, and the latest exchanges of each live chat
;;    (the cross-agent chat, merged in one place),
;;  - `agent-team-send-to-role' — type a dispatch straight into a role's
;;    agent-org session,
;;  - a refresh timer that runs ONLY while the team buffer is displayed
;;    (the same economy as `agent-org-resource-monitor'), plus a hook into
;;    `agent-org-response-finished-hook' so a finished turn refreshes the
;;    view immediately (`agent-team-sessions-install').
;;
;; agent-org is a SOFT dependency: without it the team buffer still renders
;; from TEAM-CONTROL.org, the board, the mailboxes and the registry, so CI
;; byte-compiles and tests this file with no agent-org and no live agents.

;;; Code:

(require 'agent-team)
(require 'subr-x)

;; agent-org is optional at runtime; declare what we call so the
;; byte-compiler stays silent when it is not installed.
(require 'agent-org nil t)
(declare-function agent-org-send-prompt-with-session "agent-org" (prompt session))
(declare-function agent-org--session-for-buffer "agent-org" (buffer))
(declare-function agent-org-start "agent-org" (provider))
(defvar agent-org-session-strategy)
(defvar agent-org-response-finished-hook)
;; TIME LAW clock automation (agent-team-clock.el) — the role binding var;
;; defined there, declared here so this file still compiles without it.
(defvar agent-team-clock--current-role)

(defgroup agent-team-sessions nil
  "Team session buffer over per-role agent-org sessions."
  :group 'agent-team)

(defcustom agent-team-sessions-refresh-interval 5.0
  "Seconds between team-buffer refreshes while the buffer is displayed."
  :type 'number)

(defcustom agent-team-sessions-headlines 3
  "How many recent exchanges to show per role session, newest last."
  :type 'natnum)

(defcustom agent-team-sessions-transcript-dir ".agent-org"
  "Where agent-org transcript mirrors live, relative to the project root."
  :type 'string)

(defconst agent-team-sessions-buffer-name "*agent-team: team*"
  "The team session buffer.")

;;; Registry: role slug -> live agent-org chat buffer

(defvar agent-team-sessions-registry nil
  "Alist (ROLE-SLUG-STRING . LIVE-CHAT-BUFFER) of role sessions.")

(defun agent-team-sessions--roles ()
  "Role slugs: every mailbox inbox, the Lead included."
  (let ((dir (expand-file-name "mailbox" (agent-team--file "")))
        roles)
    (when (file-directory-p dir)
      (dolist (f (directory-files dir nil "^[^.].*\\.org$"))
        (unless (string= f "PROTOCOL.org")
          (push (file-name-sans-extension f) roles))))
    (nreverse roles)))

(defun agent-team-sessions-register (role buffer)
  "Associate ROLE with the live agent-org chat BUFFER in the registry."
  (interactive
   (list (completing-read "Role: "
                          (or (agent-team-sessions--roles)
                              (mapcar #'car agent-team-sessions-registry)))
         (read-buffer "agent-org chat buffer: ")))
  (setq agent-team-sessions-registry
        (cons (cons role (get-buffer buffer))
              (delq (assoc-string role agent-team-sessions-registry)
                    agent-team-sessions-registry)))
  (message "agent-team: %s -> %s" role buffer))

(defun agent-team-sessions-forget (role)
  "Remove ROLE's session from the registry (the chat itself is untouched)."
  (interactive
   (list (completing-read "Forget session of role: "
                          (mapcar #'car agent-team-sessions-registry))))
  (setq agent-team-sessions-registry
        (delq (assoc-string role agent-team-sessions-registry)
              agent-team-sessions-registry)))

(defun agent-team-sessions--session-buffer (role)
  "The live chat buffer registered for ROLE, or nil."
  (let ((cell (assoc-string role agent-team-sessions-registry)))
    (when (and cell (buffer-live-p (cdr cell))) (cdr cell))))

(defun agent-team-sessions-adopt ()
  "Register every open agent-org chat buffer (name starts with \"=\").
Prompts for the role of each chat; empty input skips that chat."
  (interactive)
  (let ((chats (seq-filter (lambda (b) (string-prefix-p "=" (buffer-name b)))
                           (buffer-list)))
        (adopted 0))
    (unless chats (user-error "No open agent-org chats (buffers named =Agent:proj …)"))
    (dolist (b chats)
      (let ((role (completing-read (format "Role for %s (empty skips): " (buffer-name b))
                                   (agent-team-sessions--roles) nil nil)))
        (unless (string-empty-p role)
          (agent-team-sessions-register role b)
          (setq adopted (1+ adopted)))))
    (message "agent-team: adopted %d session(s)" adopted)))

;;; Pure parsers (unit-tested in tests/agent-team-test.el)

(defun agent-team-sessions--kw (text key)
  "Value of the first ^#+KEY: line in TEXT, or nil."
  (save-match-data
    (let ((case-fold-search t))
      (when (string-match (concat "^#\\+" (regexp-quote key) ":[ \t]*\\(.*\\)$") text)
        (string-trim (match-string 1 text))))))

(defun agent-team-sessions--control (text)
  "Parse TEAM-CONTROL.org TEXT into a plist of the Owner's switches."
  (list :objective (agent-team-sessions--kw text "OBJECTIVE")
        :state     (agent-team-sessions--kw text "OBJECTIVE-STATE")
        :kill      (agent-team-sessions--kw text "KILL-SWITCH")
        :turn      (agent-team-sessions--kw text "TURN")
        :stall     (agent-team-sessions--kw text "STALL-COUNT")))

(defconst agent-team-sessions--queue-headings
  '("NEXT" "WAIT" "TODO" "PROMPT")
  "Level-1 headings of the queue region, not the conversation.")

(defun agent-team-sessions--exchanges (text &optional limit)
  "Recent exchanges of an agent-org chat TEXT as (PROMPT . AUTHOR) pairs.
Oldest first, at most LIMIT pairs (all when LIMIT is nil); AUTHOR is the
model named by the reply's attribution line, or nil.  The metadata block
carries no headings, and the queue region (\\* NEXT / \\* WAIT / \\* TODO /
\\* PROMPT) terminates the scan."
  (save-match-data
    (let ((cases '()) prompt author)
      (dolist (line (split-string text "\n"))
        (cond
         ((string-match "^\\* \\(.*?\\)[ \t]*$" line)
          (when (and prompt (not (eq prompt 'stop)))
            (push (cons prompt author) cases))
          (let ((head (match-string 1 line)))
            (if (member head agent-team-sessions--queue-headings)
                (setq prompt 'stop)
              (setq prompt head author nil))))
         ((and prompt (not (eq prompt 'stop)) (null author)
               (string-match "^[ \t]*#[+]ATTR_TEXINFO:[ \t]*:author[ \t]+\\(.*?\\)[ \t]*$" line))
          (setq author (string-trim (match-string 1 line))))))
      (when (and prompt (not (eq prompt 'stop)))
        (push (cons prompt author) cases))
      (setq cases (nreverse cases))
      (if (and limit (> (length cases) limit)) (last cases limit) cases))))

(defconst agent-team-sessions--msg-re
  "^\\* MSG \\[[^]]+\\][ \t]+\\([^ \t]+\\)[ \t]+->[ \t]+\\([^ \t:]+\\)[ \t]*\\(:[a-z-]+\\)?:?[ \t]*$"
  "One mailbox message headline (PROTOCOL.org grammar).
The optional org tag `:type:' carries a TRAILING colon — `:?` eats it
(Lead repair, mesh/01: without it every typed headline failed to match
and every inbox parsed as empty — ert agent-team-sessions-mailbox).")

(defun agent-team-sessions--summary (body)
  "First prose line of a message BODY (below its properties drawer)."
  (let ((after-end nil) sum)
    (dolist (l (split-string body "\n"))
      (cond ((string-match-p "^[ \t]*:END:[ \t]*$" l) (setq after-end t))
            ((and after-end (null sum) (string-match-p "^[ \t]*[^ \t:*#+]" l))
             (setq sum (string-trim l)))))
    sum))

(defun agent-team-sessions--mailbox (text)
  "Parse mailbox inbox TEXT.
Returns (UNREAD TOTAL LAST); LAST is (FROM TO SUMMARY) of the newest
message, or nil when the inbox is empty."
  (save-match-data
    (let ((pos 0) (unread 0) (total 0) last)
      (while (string-match agent-team-sessions--msg-re text pos)
        (let* ((from (match-string 1 text))
               (to (match-string 2 text))
               (b0 (match-end 0))
               (b1 (or (and (string-match agent-team-sessions--msg-re text b0)
                            (match-beginning 0))
                       (length text)))
               (body (substring text b0 b1)))
          (setq pos b1 total (1+ total))
          (when (and (string-match ":STATUS:[ \t]*\\([A-Za-z]+\\)" body)
                     (equal (upcase (match-string 1 body)) "UNREAD"))
            (setq unread (1+ unread)))
          (setq last (list from to (agent-team-sessions--summary body)))))
      (list unread total last))))

(defconst agent-team-sessions--task-re
  "^\\*+ \\([A-Z][A-Z-]*\\)\\(?:[ \t]+\\(.*\\)\\)?[ \t]*$"
  "A board task headline: keyword plus title.")

(defun agent-team-sessions--board-tasks (text)
  "Active board tasks in TEXT as (STATE . TITLE), newest last.
DONE/REPORT/MSG-style headlines are not active and are dropped."
  (save-match-data
    (let ((tasks nil) (pos 0))
      (while (string-match agent-team-sessions--task-re text pos)
        (let ((state (match-string 1 text)) (title (match-string 2 text)))
          (setq pos (match-end 0))
          (when (member state '("TODO" "IN-PROGRESS" "PROGRESS" "BLOCKED"
                                "REVIEW" "OPEN" "OPEN-RISKS" "WAITING"))
            (push (cons state (or title "")) tasks))))
      (nreverse tasks))))

(defun agent-team-sessions--read-file (file)
  "Contents of FILE, or nil when it does not exist."
  (when (and file (file-exists-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (buffer-string))))

;;; Session status

(defun agent-team-sessions--status-word (buffer)
  "The status word of live agent-org chat BUFFER (its header line), or nil.
The header line reads provider ➤ model ➤ mode ➤ project ➤ context ➤ status,
so the status is the last segment; nil when BUFFER has no header line."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (ignore-errors
        (let ((s (and header-line-format (format-mode-line header-line-format))))
          (when (and s (string-match "➤[ \t]*\\([^➤]+\\)[ \t]*$" s))
            (string-trim (match-string 1 s))))))))

;;; Rendering

(defun agent-team-sessions--insert-role (role)
  "Insert ROLE's status line and, for a live session, its latest exchanges."
  (let* ((buf (agent-team-sessions--session-buffer role))
         (status (or (agent-team-sessions--status-word buf) "no session"))
         (mail-text (agent-team-sessions--read-file
                     (expand-file-name (concat role ".org")
                                       (expand-file-name "mailbox" (agent-team--file "")))))
         (mail (and mail-text (agent-team-sessions--mailbox mail-text))))
    (insert (propertize (format "  %-28s %s" role status)
                        'face 'bold)
            (if mail (format "  · mail %d/%d unread" (nth 0 mail) (nth 1 mail)) "  · no inbox")
            (when (and mail (nth 2 mail))
              (format " · last: %s -> %s: %s"
                      (nth 0 (nth 2 mail)) (nth 1 (nth 2 mail))
                      (or (nth 2 (nth 2 mail)) "")))
            "\n")
    (when buf
      (let ((exchanges (agent-team-sessions--exchanges
                        (with-current-buffer buf (buffer-string))
                        agent-team-sessions-headlines)))
        (if (null exchanges)
            (insert "    (no exchanges yet)\n")
          (dolist (ex exchanges)
            (insert (format "    * %s\n" (car ex)))
            (insert (format "      — %s\n" (or (cdr ex) "pending reply")))))))))

(defun agent-team-sessions--render ()
  "Rebuild the whole team session buffer."
  (with-current-buffer (get-buffer-create agent-team-sessions-buffer-name)
    (unless (derived-mode-p 'agent-team-sessions-mode)
      (agent-team-sessions-mode))
    (let ((inhibit-read-only t)
          (root (agent-team--root)))
      (setq default-directory root)
      (erase-buffer)
      (insert (propertize "AGENT-TEAM — live sessions\n" 'face 'bold))
      (insert (format "%s\n\n" (format-time-string "%Y-%m-%d %H:%M")))
      (let ((ctl-text (agent-team-sessions--read-file (agent-team--file "TEAM-CONTROL.org"))))
        (if ctl-text
            (let ((ctl (agent-team-sessions--control ctl-text)))
              (insert (propertize "Control\n" 'face 'bold))
              (insert (format "  objective: %s\n" (or (plist-get ctl :objective) "—")))
              (insert (format "  state %s · kill %s · stall %s · turn %s\n\n"
                              (or (plist-get ctl :state) "—") (or (plist-get ctl :kill) "—")
                              (or (plist-get ctl :stall) "—") (or (plist-get ctl :turn) "—"))))
          (insert "  (no TEAM-CONTROL.org under agent-team/)\n\n")))
      (let ((tasks (agent-team-sessions--board-tasks
                    (or (agent-team-sessions--read-file (agent-team--board)) ""))))
        (insert (propertize "Board — active tasks\n" 'face 'bold))
        (if tasks
            (dolist (task tasks) (insert (format "  %-12s %s\n" (car task) (cdr task))))
          (insert "  (none)\n"))
        (insert "\n"))
      (let ((roles (delete-dups
                    (append (agent-team-sessions--roles)
                            (mapcar #'car agent-team-sessions-registry)))))
        (insert (propertize "Roles\n" 'face 'bold))
        (if roles
            (dolist (role roles) (agent-team-sessions--insert-role role))
          (insert "  (no mailboxes yet — run agent-team-init)\n"))
        (insert "\n"))
      (insert (propertize "Keys\n" 'face 'bold))
      (insert "  g refresh · s send to role · r register session · q quit\n")
      (goto-char (point-min)))))

;;; Mode, refresh timer, commands

(defvar agent-team-sessions-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map "g" #'agent-team-team-buffer-refresh)
    (define-key map "s" #'agent-team-send-to-role)
    (define-key map "r" #'agent-team-sessions-adopt)
    map))

(define-derived-mode agent-team-sessions-mode special-mode "agent-team"
  "Read-only live view of the team's agent-org sessions, mailboxes and board.")

(defvar agent-team-sessions--timer nil)

(defun agent-team-sessions--tick ()
  "Refresh the team buffer while it is on display; stop the timer otherwise."
  (let ((buf (get-buffer agent-team-sessions-buffer-name)))
    (if (and buf (get-buffer-window buf t))
        (ignore-errors (agent-team-sessions--render))
      (when agent-team-sessions--timer
        (cancel-timer agent-team-sessions--timer)
        (setq agent-team-sessions--timer nil)))))

(defun agent-team-team-buffer-refresh ()
  "Rebuild the team session buffer now."
  (interactive)
  (agent-team-sessions--render))

;;;###autoload
(defun agent-team-team-buffer ()
  "Show the team session buffer: live cross-agent chat + Org-powered status.
Refreshes itself only while displayed, and on every agent-org turn end
when `agent-team-sessions-install' has hooked it in."
  (interactive)
  (agent-team-sessions--render)
  (pop-to-buffer (get-buffer agent-team-sessions-buffer-name))
  (when (and (> agent-team-sessions-refresh-interval 0)
             (null agent-team-sessions--timer))
    (setq agent-team-sessions--timer
          (run-with-timer agent-team-sessions-refresh-interval
                          agent-team-sessions-refresh-interval
                          #'agent-team-sessions--tick))))

;;;###autoload
(defun agent-team-session-start-role (role provider)
  "Start a NEW agent-org session for ROLE with PROVIDER and register it.
The session opens in the project root, so its transcript joins this repo."
  (interactive
   (list (completing-read "Role: "
                          (or (agent-team-sessions--roles)
                              (mapcar #'car agent-team-sessions-registry)))
         (completing-read "Provider: " '("goose" "qoder" "opencode" "slave"
                                         "minimax" "copilot" "cursor"
                                         "codebuddy" "cline"))))
  (unless (fboundp 'agent-org-start)
    (user-error "agent-org is not installed (soft dependency)"))
  (let ((default-directory (agent-team--root))
        (agent-org-session-strategy 'new)
        buf)
    (setq buf (agent-org-start provider))
    (agent-team-sessions-register role buf)
    (message "agent-team: %s session starting (%s) — registered when ready" role provider)
    buf))

;;;###autoload
(defun agent-team-send-to-role (role text)
  "Send TEXT as a prompt into ROLE's registered agent-org session.
Queues automatically when that session is still streaming (agent-org's
own type-ahead model)."
  (interactive
   (list (completing-read "Role: "
                          (or (agent-team-sessions--roles)
                              (mapcar #'car agent-team-sessions-registry)))
         (read-string "Prompt: ")))
  (unless (fboundp 'agent-org-send-prompt-with-session)
    (user-error "agent-org is not installed (soft dependency)"))
  (let ((buf (agent-team-sessions--session-buffer role)))
    (unless buf
      (user-error "No live session for %s (M-x agent-team-session-start-role)" role))
    (let ((session (with-current-buffer buf
                     (and (fboundp 'agent-org--session-for-buffer)
                          (agent-org--session-for-buffer buf)))))
      (unless session
        (user-error "Session for %s is not ready (still starting?)" role))
      ;; TIME LAW (Owner 2026-10-26 10:42 #hq): the prompt-send hook
      ;; clock-in needs to know which role the wire carries — bind it
      ;; around the send so the automation (never the member) clocks the
      ;; item in at the exact send moment.
      (let ((agent-team-clock--current-role role))
        (agent-org-send-prompt-with-session text session))
      (message "agent-team: dispatched to %s" role))))

;;;###autoload
(defun agent-team-sessions-install ()
  "Hook the team buffer into agent-org: every finished turn refreshes it."
  (interactive)
  (if (boundp 'agent-org-response-finished-hook)
      (progn
        (add-hook 'agent-org-response-finished-hook
                  #'agent-team-sessions--response-finished)
        ;; TIME LAW: also hang the automated clock-in when the clock
        ;; module is loaded (agent-team-clock-install guards itself).
        (when (fboundp 'agent-team-clock-install)
          (agent-team-clock-install))
        (message "agent-team: live refresh hooked into agent-org"))
    (user-error "agent-org is not loaded")))

(defun agent-team-sessions--response-finished (_buffer _session)
  "Refresh the team buffer when any agent-org turn ends."
  (ignore-errors (agent-team-team-buffer-refresh)))

(provide 'agent-team-sessions)
;;; agent-team-sessions.el ends here
