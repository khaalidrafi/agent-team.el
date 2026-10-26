;;; agent-team-clock.el --- TIME LAW: automated Org clock-in at prompt-send -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Khalid Rafi
;; Author: Khalid Rafi <khaalidrafi@gmail.com>
;; Keywords: tools, ai, org
;; Package-Requires: ((emacs "28.1"))
;; URL: https://github.com/khaalidrafi/agent-team.el
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Owner law (Discord #hq, 2026-10-26 10:42 #hq): strict time discipline,
;; powered by Org.  The BEGINNING of a task is the EXACT time its prompt
;; is sent to the delegated member; clocking is AUTOMATION, never the
;; member's job:
;;
;;   - at the moment a prompt goes on the wire to a member's ACP agent,
;;     this module flips the dispatched board item's TODO keyword to
;;     ONGOING and adds the send instant to the item's :LOGBOOK: as an
;;     OPEN Org clock (`CLOCK: [2026-10-26 Mon 10:42 UTC]'); a later
;;     clock-out turns it into `[in]--[out] =>  duration',
;;   - the automation hangs off `agent-org-prompt-send-hook', which
;;     agent-org fires in BOTH transmit paths (typed + programmatic
;;     sends, and queue drains),
;;   - web/cloud models never pass through agent-org (a human pastes
;;     their prompts), so they are the ONE manual exception: whoever
;;     dispatches pastes the ONGOING flip + :LOGBOOK: clock with the
;;     send time.
;;
;; ACP DEPENDENCY LAW (same order): agent-team.el depends on agent-org
;; for ALL tasks related to ACP agents.  Every entry point of this
;; module errors when agent-org is absent.  The repo still byte-compiles
;; and tests standalone (its CI has no agent-org) — the dependency bites
;; exactly where ACP work happens.
;;
;; The pure transformer `agent-team-clock--apply' is unit-tested in
;; tests/agent-team-test.el; the CI twin lives in
;; agent-team/tools/clock_in.py (canonical, single copy, no duplication).

;;; Code:

(require 'agent-team)
(require 'seq)
(require 'agent-org nil t)

(defgroup agent-team-clock nil
  "Automated Org clock-in at the moment a prompt is sent."
  :group 'agent-team)

(defcustom agent-team-clock-board "agent-team/TODOS.org"
  "Board file the clock automation edits, relative to the project root."
  :type 'string
  :group 'agent-team)

(defcustom agent-team-clock-open-states '("TODO" "PENDING" "WAIT" "PROGRESS")
  "Board keywords an open item may carry when the clock adopts it.
ONGOING items are adopted too (a stale item without an open clock gets
one).  REVIEW is adopted ONLY by an explicit TASK pin (a review
dispatch clocking its own review child, R-2-78) — the role and
oldest-open fallbacks never touch a REVIEW item, because work clocks
and review clocks are separate clocks.  DONE/CANCELLED/DEFERRED are
never touched."
  :type '(repeat string)
  :group 'agent-team)

(defvar agent-team-clock--current-role nil
  "Role the prompt currently going out is dispatched to.
Dynamically bound by `agent-team-send-to-role' around the wire call;
`agent-team-clock--on-prompt-send' reads it to find the board item.")

(defvar agent-team-clock--current-task nil
  "Optional headline substring pinning the exact board item for this send.
Dynamically bound by a dispatcher that knows the item; when nil the hook
falls back to a `TASK:' marker line in the prompt, then to the role,
then to the oldest open item.")

;;; Timestamp

(defun agent-team-clock--ts (&optional time)
  "Org inactive timestamp for TIME (default now): [YYYY-MM-DD Eee HH:MM UTC].
Locale pinned to C so the weekday abbrev is always English, matching the
board law (`[YYYY-MM-DD Eee HH:MM UTC]')."
  (let ((system-time-locale "C"))
    (concat (format-time-string "[%Y-%m-%d %a %H:%M" time) " UTC]")))

;;; Pure transformer (unit-tested, no file access)

(defun agent-team-clock--match-headline (line)
  "KEYWORD of the board headline LINE, or nil."
  (save-match-data
    (when (string-match "^\\*+ \\([A-Z][A-Z-]*\\)\\(?:[ \t].*\\)?$" line)
      (match-string 1 line))))

(defun agent-team-clock--section-end (lines idx)
  "End index (exclusive) of the headline section starting at LINES' IDX."
  (let ((n (length lines)) (j (1+ idx)))
    (while (and (< j n) (not (string-match-p "^[*]" (nth j lines))))
      (setq j (1+ j)))
    j))

(defun agent-team-clock--pick (lines role task)
  "Index of the board item to clock in LINES, or nil.
TASK (a headline substring) wins — an explicit dispatcher pin may adopt
any live keyword INCLUDING REVIEW (a review dispatch clocks its own
review child), but never DONE/CANCELLED/DEFERRED.  Without a task hit:
the first open item whose section mentions ROLE, else the first open
item; those fallbacks never pick a REVIEW item, because work clocks and
review clocks are separate clocks (R-2-78)."
  (let ((first-open nil) (role-hit nil) (task-hit nil) (i 0))
    (dolist (line lines)
      (let ((kw (agent-team-clock--match-headline line)))
        (cond
         ((null kw))                   ; not a headline
         ((member kw '("DONE" "CANCELLED" "DEFERRED")))
         ;; explicit TASK pin: any live keyword, REVIEW included —
         ;; the dispatcher pinned this exact item on purpose
         ((and task (null task-hit)
               (string-match-p (regexp-quote task) line))
          (setq task-hit i))
         ((member kw (append agent-team-clock-open-states '("ONGOING")))
          (unless first-open (setq first-open i))
          (when (and role (null role-hit)
                     (string-match-p
                      (regexp-quote role)
                      (mapconcat #'identity
                                 (seq-subseq
                                  lines i (agent-team-clock--section-end lines i))
                                 "\n")))
            (setq role-hit i)))))
      (setq i (1+ i)))
    (cond (task-hit task-hit)
          (role-hit role-hit)
          (first-open first-open)
          (t nil))))

(defun agent-team-clock--apply (text role task ts)
  "Pure TIME LAW transform of board TEXT.
ROLE and TASK select the item (see `agent-team-clock--pick'); TS is the
send instant as an Org timestamp.  Returns (NEW-TEXT . HEADLINE-LINE)
when an item was clocked, (TEXT . nil) when it already carried an open
clock (idempotent), or nil when nothing matched."
  (let* ((lines (split-string text "\n"))
         (idx (agent-team-clock--pick lines role task)))
    (when idx
      (let* ((head (nth idx lines))
             (kw (agent-team-clock--match-headline head)))
        (unless (string= kw "ONGOING")
          (setq head (replace-regexp-in-string
                      (concat "^\\*+ " (regexp-quote kw))
                      (concat (car (split-string head " ")) " ONGOING")
                      head)
                lines (append (seq-subseq lines 0 idx)
                              (list head)
                              (seq-subseq lines (1+ idx)))))
        (let* ((end (agent-team-clock--section-end lines idx))
               (level (length (car (split-string head "[^*]" t))))
               (indent (make-string (1+ level) ?\s))
               (clock (concat indent "CLOCK: " ts))
               (logbook nil) (open-clock nil) (j (1+ idx)))
          (while (< j end)
            (let ((s (nth j lines)))
              (cond
               ((and (null logbook)
                     (string-match-p "^[ \t]*:LOGBOOK:[ \t]*$" s))
                (setq logbook j))
               ((and logbook (null open-clock)
                     (string-match-p
                      "^[ \t]*CLOCK:[ \t]*\\[[^]]+\\][ \t]*$" s))
                (setq open-clock t))))
            (setq j (1+ j)))
          (if open-clock
              (cons (mapconcat #'identity lines "\n") nil)
            (if logbook
                (setq lines (append (seq-subseq lines 0 (1+ logbook))
                                    (list clock)
                                    (seq-subseq lines (1+ logbook))))
              (let ((at (1+ idx)))
                ;; skip planning lines, then an existing :PROPERTIES: drawer
                (while (and (< at end)
                            (string-match-p
                             "^[ \t]*\\(SCHEDULED\\|DEADLINE\\|CLOSED\\):"
                             (nth at lines)))
                  (setq at (1+ at)))
                (when (and (< at end)
                           (string-match-p "^[ \t]*:PROPERTIES:[ \t]*$"
                                           (nth at lines)))
                  (while (and (< at end)
                              (not (string-match-p "^[ \t]*:END:[ \t]*$"
                                                   (nth at lines))))
                    (setq at (1+ at)))
                  (setq at (1+ at)))
                (setq lines (append (seq-subseq lines 0 at)
                                    (list (concat indent ":LOGBOOK:")
                                          clock
                                          (concat indent ":END:"))
                                    (seq-subseq lines at)))))
            (cons (mapconcat #'identity lines "\n") (nth idx lines))))))))

;;; File-side entry point

(defun agent-team-clock-in (&optional role task)
  "Automated clock-in on the board (TIME LAW).
Picks the item via ROLE and the TASK marker, flips it to ONGOING and
adds the open clock at NOW in `agent-team-clock-board' (under
`agent-team--root'), then saves.  Returns the headline line, the symbol
`already' when an open clock existed, or nil when nothing matched."
  (unless (fboundp 'agent-org-start)
    (user-error "agent-org is not installed (ACP dependency law: agent-team.el depends on agent-org for ACP tasks)"))
  (let* ((file (expand-file-name agent-team-clock-board (agent-team--root)))
         (buf (find-file-noselect file))
         (res (with-current-buffer buf
                (let ((out (agent-team-clock--apply (buffer-string) role task
                                                    (agent-team-clock--ts))))
                  (when out
                    (erase-buffer)
                    (insert (car out))
                    (save-buffer))
                  out))))
    (cond ((null res) nil)
          ((null (cdr res)) 'already)
          (t (cdr res)))))

;;; Hook consumer + install

(defun agent-team-clock--on-prompt-send (prompt session)
  "TIME LAW automation at the exact send moment.
Bound to `agent-org-prompt-send-hook' by `agent-team-clock-install'.
PROMPT and SESSION come from agent-org; the role rides the dynamic
binding from `agent-team-send-to-role'.  Errors are demoted upstream —
a broken clock can never block a send."
  (ignore-errors
    (let ((task (or agent-team-clock--current-task
                    (and (string-match "^TASK:[ \t]*\\(.+?\\)[ \t]*$" prompt)
                         (match-string 1 prompt)))))
      (let ((head (agent-team-clock-in agent-team-clock--current-role task)))
        (cond ((stringp head)
               (message "agent-team-clock: ONGOING + clocked — %s" head))
              ((eq head 'already)
               (message "agent-team-clock: item already clocked")))))))

;;;###autoload
(defun agent-team-clock-install ()
  "Hang the TIME LAW clock-in on `agent-org-prompt-send-hook'."
  (interactive)
  (if (boundp 'agent-org-prompt-send-hook)
      (progn
        (add-hook 'agent-org-prompt-send-hook
                  #'agent-team-clock--on-prompt-send)
        (message "agent-team-clock: clock-in hooked at the prompt-send moment"))
    (user-error "agent-org is not loaded (ACP dependency law: install/upgrade agent-org)")))

(provide 'agent-team-clock)
;;; agent-team-clock.el ends here
