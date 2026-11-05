;;; agent-team-live.el --- Live team chat surface (standard v1.1 §10.4 + §11) -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Khalid Rafi
;; Author: Khalid Rafi <khaalidrafi@gmail.com>
;; Keywords: tools, ai, org, comm
;; Package-Requires: ((emacs "28.1"))
;; URL: https://github.com/khaalidrafi/agent-team.el
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; U4 of the standard v1.1 §10 adoption (docs/LIVE-TEAM-CHAT-DESIGN.org
;; in this repo — binding): the LIVE team chat buffer, §10.4's team
;; buffer with its status panel, and the §11 dispatch consumption the
;; bridge design deliberately left OUT (its §1: "the U4 live team-buffer
;; chat region that will call this engine from the interactive surface").
;;
;; DATA-FLOW LAW (v1.3): this buffer is THE interactive chat surface.
;; It renders the local CHAT.org through `agent-team-chat--render-string'
;; (the ONE kit renderer, §4 grammar — no second render law exists) and
;; its send path IS the auto-save: `c'/`C-c C-c' compose via prompts and
;; append through `agent-team-chat-send' (the ONE sender; the protocol
;; fields REPO/PRIORITY/RISK stay the comms-protocol law).  The buffer
;; itself NEVER writes the file — it is a derived view, kill-rebuilt on
;; every refresh (fresh Org element cache + fold registry, the
;; 0882373/95b876c decision).
;;
;; §7 DEVIATION (documented per the kit law): there is no draft state on
;; this surface — "send draft" composes via prompts and appends directly,
;; so C-c C-c never retags an in-buffer draft (the render buffer is
;; read-only by construction).
;;
;; UNREAD (§6 unread role — the application U2 deferred to this live
;; region): messages that arrived since the previous render carry ONE
;; overlay with `agent-team-chat-unread-face' (overlays, never text
;; properties — the render string stays property-free).  `j' jumps to the
;; first unread heading, else the tail; reaching the tail marks all read.
;;
;; STATUS PANEL (§10.4 "keeps its status panels"): the header line shows
;; file · LIVE interval · message count · last render · status.
;;
;; DISPATCH (§11): `d' calls the engine — llm-api members ride
;; `agent-team-bridge-dispatch' (the U3 lifecycle law, untouched); acp
;; members ride `agent-team-live-acp-dispatch-function' with NO stamp
;; (the §11 truth table's live-surface transports are exactly this);
;; relay members are an explicit no-op (the relay lane reads CHAT.org —
;; visibility §11.4 is the delivery).  Broadcasts and undeclared members
;; user-error: never a silent drop (§11.6).  The bridge is optional at
;; load time (fboundp guards) — view+compose work without it.
;;
;; THE U1 SEAM: loading this file sets `agent-team-chat-live-buffer-function',
;; so `agent-team-chat-open' switches to this buffer when a live session
;; exists and only builds the archive render when none does.
;;
;; Hygiene (§8): undo disabled, read-only, substring-no-properties on
;; every file string, `q' buries, killing the buffer never touches the
;; file, no secret value ever enters a buffer (MEMBERS.org carries
;; aliases only, §11.1).

;;; Code:

(require 'agent-team)
(require 'agent-team-chat)
(require 'timer)

;; The bridge is an OPTIONAL dependency (design §6): view+compose work
;; without it; dispatch errors loudly when it is absent.  These declares
;; only silence the unresolved-function compile warning — nothing is
;; loaded at compile or run time here.
(declare-function agent-team-bridge-dispatch "agent-team-bridge" nil t)
(declare-function agent-team-bridge--registry "agent-team-bridge"
                  (&optional file))
(declare-function agent-team-bridge--addressed-member "agent-team-bridge"
                  (msg members))

(defgroup agent-team-live nil
  "The live team chat surface (standard v1.1 §10.4 + §11)."
  :group 'agent-team)

(defcustom agent-team-live-interval 15
  "Seconds between local CHAT.org polls.
Cheap mtime check, no network.  Android battery: raise it, the surface
still catches up on the next tick."
  :type 'integer
  :group 'agent-team-live)

(defcustom agent-team-live-acp-dispatch-function nil
  "Seam: (FN MEMBER-ID BODY) → result string, for :TRANSPORT: acp.
The Owner's setup wires this to the member's live ACP session
dispatcher (agent-org session).  Nil = acp dispatch user-errors naming
the member — never a silent drop (§11.6).  No stamp ever rides an acp
message: the §11 truth table keeps live-surface transports unstamped."
  :type '(choice (const :tag "no acp dispatcher wired" nil) function)
  :group 'agent-team-live)

(defvar-local agent-team-live--file nil
  "The CHAT.org file this live buffer renders.")

(defvar-local agent-team-live--timer nil
  "The poll timer; cancelled by `agent-team-live--teardown'.")

(defvar-local agent-team-live--mtime nil
  "Modification time at the last render (the poll's change detector).")

(defvar-local agent-team-live--count 0
  "Message count at the last render — the unread overlay base.")

(defvar-local agent-team-live--status "waiting"
  "Human-readable state shown in the status panel.")

;; Session state survives the (org-mode) call inside every rebuild —
;; a major-mode change resets non-permanent buffer-locals, and the
;; render is kill-rebuilt by law.
(dolist (var '(agent-team-live--file agent-team-live--timer
               agent-team-live--mtime agent-team-live--count
               agent-team-live--status))
  (put var 'permanent-local t))

;;; Mode + keys (§7) -----------------------------------------------------

(defvar agent-team-live-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "g" 'agent-team-live-refresh)
    (define-key map "q" 'agent-team-live-bury)
    (define-key map "j" 'agent-team-live-jump-unread)
    (define-key map "c" 'agent-team-live-send)
    (define-key map "d" 'agent-team-live-dispatch)
    (define-key map (kbd "C-c C-c") 'agent-team-live-send)
    map)
  "Keys for the live team chat surface: g re-render, q bury, j first
unread (else tail), c / C-c C-c compose+send (the auto-save), d
dispatch through the §11 engine + acp seam.")

;;;###autoload
(define-minor-mode agent-team-live-mode
  "Live team chat keys on the *agent-team Live* render buffer."
  :lighter " team-live"
  :keymap agent-team-live-mode-map
  (when agent-team-live-mode
    (font-lock-add-keywords
     'agent-team-live-mode agent-team-chat--font-lock-keywords t)))

;;; The U1 seam (closes on load) -----------------------------------------

(defun agent-team-live--live-buffer ()
  "The live team chat buffer when a session exists, else nil.
The U1 seam body: `agent-team-chat-open' switches to this buffer and
never forks a second interactive state (data-flow law v1.3)."
  (let ((buf (get-buffer "*agent-team Live*")))
    (and buf (buffer-local-value 'agent-team-live-mode buf) buf)))

(setq agent-team-chat-live-buffer-function #'agent-team-live--live-buffer)

;;; Render (§4 kit grammar via the ONE renderer) -------------------------

(defun agent-team-live--unread-start (rendered seen)
  "0-based position of message SEEN+1's heading in RENDERED, or nil.
Skips SEEN `** ' message headings; the next one is the first unread
(and nil when the render holds no message beyond SEEN)."
  (let ((pos 0) (skip seen) found)
    (while (and (not found) (string-match "^\\*\\* " rendered pos))
      (if (zerop skip)
          (setq found (match-beginning 0))
        (setq skip (1- skip)
              pos (match-end 0))))
    found))

(defun agent-team-live--render (&optional force)
  "Rebuild the live render from `agent-team-live--file'.
FORCE rebuilds even when the file mtime is unchanged.  The follow rule:
point at the tail (or a first render) follows the tail after the
rebuild; otherwise point goes to point-min under the overview startup."
  (let* ((file agent-team-live--file)
         (exists (and file (file-exists-p file)))
         (first-p (null agent-team-live--mtime)) ; no previous render:
         (existing-unread (agent-team-live--unread-start-pos))
         (existing-sane (and existing-unread
                             (<= existing-unread (point-max))
                             (save-excursion
                               (goto-char existing-unread)
                               (looking-at-p "^\\*\\* "))))
         (text (when exists            ; the session starts caught-up
                 (with-temp-buffer
                   (insert-file-contents file)
                   (substring-no-properties (buffer-string)))))
         (msgs (when exists (agent-team-chat--parse-messages text)))
         (count (length msgs))
         (changed (or force
                      (not exists)
                      (null agent-team-live--mtime)
                      (not (equal
                            agent-team-live--mtime
                            (file-attribute-modification-time
                             (file-attributes file))))))
         (prev-count agent-team-live--count)
         (at-tail (or (null agent-team-live--mtime)
                      (= (point) (point-max)))))
    (when changed
      (let* ((rendered (agent-team-chat--render-string
                        (or text "#+TITLE: (no chat file yet)\n")))
             (unread-from (cond
                           ;; unread accumulates until the reader reaches
                           ;; the tail: keep the old start when it still
                           ;; sits on a message heading (the append-only
                           ;; law keeps the render prefix byte-identical)
                           (existing-sane (- existing-unread (point-min)))
                           ((and (not first-p)
                                 (> count prev-count))
                            (agent-team-live--unread-start
                             rendered prev-count))))
             (inhibit-read-only t))
        (erase-buffer)
        (insert rendered)
        (org-mode)
        (unless agent-team-live-mode (agent-team-live-mode 1))
        (when (and agent-team-chat-adapt-for-touch
                   (agent-team-chat--touch-device-p))
          (unless agent-team-chat-touch-mode
            (agent-team-chat-touch-mode 1)))
        (remove-overlays (point-min) (point-max) 'agent-team-live-unread t)
        (when unread-from
          (let ((ov (make-overlay (+ (point-min) unread-from)
                                  (point-max) nil t nil)))
            (overlay-put ov 'agent-team-live-unread t)
            (overlay-put ov 'face 'agent-team-chat-unread-face)))
        (setq buffer-read-only t
              agent-team-live--mtime
              (when exists
                (file-attribute-modification-time
                 (file-attributes file)))
              agent-team-live--count count
              agent-team-live--status
              (if exists "ok" (format "waiting for %s"
                                      (file-name-nondirectory file))))
        (setq header-line-format
              (format " agent-team live: %s · %s every %ds · %d msgs · last %s · %s"
                      (if file (file-name-nondirectory file) "<unset>")
                      (propertize "LIVE" 'face 'success)
                      agent-team-live-interval
                      count
                      (format-time-string "%H:%M:%S")
                      agent-team-live--status))
        (if at-tail
            (progn (goto-char (point-max))
                   ;; sitting at the tail = caught up: the chat-client
                   ;; law — a reader pinned to the bottom has read the
                   ;; arrivals (design §4 "reaching the tail marks all
                   ;; read"), so the fresh overlay clears immediately
                   (agent-team-live--mark-read))
          (goto-char (point-min))))
      t)))

;;; Poll (local file only — no network) ----------------------------------

(defun agent-team-live--tick (buf)
  "Timer body: one mtime check + conditional re-render while BUF lives."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when agent-team-live-mode
        (condition-case err
            (agent-team-live--render)
          (error
           (setq agent-team-live--status
                 (format "stale: %s" (error-message-string err)))))))))

(defun agent-team-live--teardown ()
  "Cancel the poll timer (runs from `kill-buffer-hook')."
  (when agent-team-live--timer
    (cancel-timer agent-team-live--timer)
    (setq agent-team-live--timer nil)))

;;; Unread verbs (§7) ----------------------------------------------------

(defun agent-team-live--unread-overlay ()
  "The unread overlay of this buffer, or nil.
Filter by OUR property — Org's fold system puts its own overlays on
the same buffer, so `overlays-in' alone would return those."
  (let (found)
    (dolist (ov (overlays-in (point-min) (point-max)) found)
      (when (and (null found)
                 (overlay-get ov 'agent-team-live-unread))
        (setq found ov)))))

(defun agent-team-live--unread-start-pos ()
  "Absolute start position of the unread overlay, or nil."
  (let ((ov (agent-team-live--unread-overlay)))
    (and ov (overlay-start ov))))

(defun agent-team-live-jump-unread ()
  "Jump to the first unread message heading, else the tail (verb `j').
Reaching the tail marks everything read: the overlay goes, the seen
count syncs — the live form of jump-to-first-unread."
  (interactive)
  (let ((ov (agent-team-live--unread-overlay)))
    (if ov
        (goto-char (overlay-start ov))
      (goto-char (point-max))))
  (agent-team-live--mark-read))

(defun agent-team-live--mark-read ()
  "Clear the unread overlay when point sits at the tail."
  (when (= (point) (point-max))
    (let ((ov (agent-team-live--unread-overlay)))
      (when ov (delete-overlay ov)))))

;;; Send (the auto-save path, v1.3) --------------------------------------

(defun agent-team-live-send (&optional from to kind body priority risk)
  "Compose and send one chat message from the live surface.
Interactive calls prompt through `agent-team-chat-send' (the ONE
sender — the comms protocol law); the append IS the auto-save
(data-flow law v1.3).  Re-renders so the new entry is on screen."
  (interactive)
  (if (called-interactively-p 'any)
      (call-interactively #'agent-team-chat-send)
    (agent-team-chat-send from to kind body priority risk))
  (agent-team-live--render t))

;;; Dispatch (§11 consumption — the U3 OUT clause) -----------------------

(defun agent-team-live--bridge-p ()
  "Non-nil when the §11 engine (agent-team-bridge.el) is loaded."
  (and (fboundp 'agent-team-bridge-dispatch)
       (fboundp 'agent-team-bridge--registry)
       (fboundp 'agent-team-bridge--addressed-member)))

(defun agent-team-live-dispatch ()
  "Dispatch the newest chat entry through the §11 engine.
Resolution per the addressed member's :TRANSPORT: (the §11 truth
table): llm-api → `agent-team-bridge-dispatch' runs the engine's
lifecycle law (stamp, transport, reply landing); acp →
`agent-team-live-acp-dispatch-function' with NO stamp (live-surface
transport); relay → explicit no-op (the relay lane reads CHAT.org,
visibility §11.4).  Broadcasts, unknown targets and undeclared
transports user-error — never a silent drop (§11.6).  Re-renders after
(a reply may have landed)."
  (interactive)
  (unless (agent-team-live--bridge-p)
    (user-error "agent-team-live: the bridge (agent-team-bridge.el) is not loaded — view and compose work without it; dispatch needs it"))
  (let* ((file (agent-team-chat--chat-file)))
    (unless (and file (file-exists-p file))
      (user-error "agent-team-live: no chat file at %s" (or file "<unset>"))))
  (let* ((file (agent-team-chat--chat-file))
         (text (with-temp-buffer
                 (insert-file-contents file)
                 (substring-no-properties (buffer-string))))
         (last (car (last (agent-team-chat--parse-messages text))))
         (members (agent-team-bridge--registry))
         (member (agent-team-bridge--addressed-member last members))
         (transport (and member (plist-get member :transport)))
         (result
          (cond
           ((null member)
            (user-error "agent-team-live: the newest entry addresses no registry member (TO=all is a broadcast — never auto-dispatched, §11.2)"))
           ((equal transport "llm-api")
            (let ((r (agent-team-bridge-dispatch)))
              (cons (car r) (cdr r))))
           ((equal transport "acp")
            (unless agent-team-live-acp-dispatch-function
              (user-error "agent-team-live: no ACP dispatcher for member %s (set agent-team-live-acp-dispatch-function)"
                          (plist-get member :id)))
            (cons 'acp
                  (funcall agent-team-live-acp-dispatch-function
                           (plist-get member :id)
                           (string-trim (or (plist-get last :body) "")))))
           ((equal transport "relay")
            (cons 'relay
                  (format "%s is a relay member — the relay lane reads CHAT.org; no dispatch (§11 truth table)"
                          (plist-get member :id))))
           (t
            (user-error "agent-team-live: member %s declares no :TRANSPORT: (§11.1)"
                        (plist-get member :id))))))
    (agent-team-live--render t)
    (message "agent-team-live: dispatch %s" (or (cdr result) (car result)))
    result))

;;; Open / refresh / quit -------------------------------------------------

;;;###autoload
(defun agent-team-live-open ()
  "Open the live team chat buffer (§10.4 team buffer).
Renders the local CHAT.org in the §4 kit grammar with the status panel,
starts the poll, and IS the interactive surface the data-flow law v1.3
names: c/C-c C-c send (the auto-save append), d dispatches through the
§11 engine.  Keys: g re-render, q bury, j first unread."
  (interactive)
  (let* ((file (agent-team-chat--chat-file))
         (buf (get-buffer-create "*agent-team Live*")))
    (with-current-buffer buf
      (setq agent-team-live--file file)
      (buffer-disable-undo)
      (agent-team-live--render t)
      (add-hook 'kill-buffer-hook #'agent-team-live--teardown nil t)
      (unless agent-team-live--timer
        (setq agent-team-live--timer
              (run-at-time agent-team-live-interval
                           agent-team-live-interval
                           #'agent-team-live--tick buf))))
    (pop-to-buffer buf)
    (message "agent-team live: %s — c/C-c C-c send, d dispatch, g re-render, q bury"
             (abbreviate-file-name file))))

(defun agent-team-live-refresh ()
  "Force a re-render from the file (verb `g').  Never writes the file."
  (interactive)
  (agent-team-live--render t)
  (message "agent-team live: re-rendered (%d msgs)" agent-team-live--count))

(defun agent-team-live-bury ()
  "Bury the live buffer (verb `q').  The poll keeps the session alive;
the file is never locked — CI seats append from other machines."
  (interactive)
  (bury-buffer))

(provide 'agent-team-live)
;;; agent-team-live.el ends here
