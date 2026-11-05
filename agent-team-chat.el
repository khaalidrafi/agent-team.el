;;; agent-team-chat.el --- CHAT.org reopen/resume reader (standard v1.1 §10 kit) -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Khalid Rafi
;; Author: Khalid Rafi <khaalidrafi@gmail.com>
;; Keywords: tools, ai, org, comm
;; Package-Requires: ((emacs "28.1"))
;; URL: https://github.com/khaalidrafi/agent-team.el
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; U1 of the standard v1.1 §10 adoption (docs/CHAT-KIT-ADAPTATION.org in
;; khaalidrafi/agent-org, design sections "U1 design" + "Data-flow
;; correction v1.3" — both binding): the CHAT.org reopen/resume READER.
;;
;; DATA-FLOW LAW (v1.3, Owner 2026-11-04 20:06 Asia/Dhaka #hq): the live
;; team chat surface is the only interactive surface and its auto-save
;; APPENDS to CHAT.org — the file is the log, never a second UI.  This
;; reader exists only for the moments the live surface does not exist:
;; after a restart or crash, to see entries other seats appended from CI
;; or other machines while this Emacs was closed, and for history
;; inspection.  It never runs while a live session exists, and it never
;; writes the file (the file stays the single source of truth, §11.3).
;;
;; `agent-team-chat-open' therefore resolves BEFORE rendering:
;;
;;   1. a live team chat session buffer supplied by
;;      `agent-team-chat-live-buffer-function' (the U4 seam), or
;;   2. any buffer already visiting the chat file (the raw session view
;;      of `agent-team.el's chat commands — auto-revert-tail keeps it
;;      live),
;;
;; and only when neither exists builds the render buffer `*agent-team
;; Chat*' from the file.  This command supersedes agent-team.el's raw
;; `find-file' version of the same name: that view remains reachable —
;; it is honored as the live session in step 2 whenever it exists —
;; while a closed Emacs now gets the §4 view grammar instead of a bare
;; file.  The old behavior is a strict subset; nothing is lost.
;;
;; RENDER LAW (§10.2 mapping — the file format does NOT change; the kit
;; renders it):
;;
;;   CHAT.org source                             rendered
;;   * MSG <from> -> @<to> :<kind>:   ** [<WHEN>] <from> -> @<to> :<kind>:
;;   :FROM:                           :AUTHOR: property
;;   :TO:                             :TO: property
;;   :KIND:                           tag on the message heading
;;   :WHEN: [.. HH:MM UTC]            inactive stamp [.. HH:MM]; zone
;;                                    kept in :WHEN-ZONE:
;;   :CHANNEL:                        :CHANNEL: property (§5 addition)
;;   indented body                    paragraphs (blank-line split);
;;                                    URLs -> [[url]]; @mentions ->
;;                                    chat-member: links where MEMBERS.org
;;                                    knows the handle, plain text where
;;                                    it does not (never break the render)
;;
;; Derived :MSG-ID: law: CHAT.org is append-only and union-merged, so
;; ids are derived WITHOUT mutating the file: MSG-ID =
;; msg-<first 8 hex of sha1(FROM "\0" WHEN "\0" first 80 body chars)>.
;; Entries missing :WHEN: degrade to positional ids msg-legacy-NNN
;; (documented; chat-msg: links to them are best-effort).
;;
;; Faces are the U2 half (the §6 role table under the agent-team-chat-*
;; prefix); this file deliberately renders with zero text properties
;; (asserted by the ERT suite).  Verbs here are the reader's own `g'
;; (re-render from file) and `q' (bury — never lock the file, other
;; seats append from CI); the full §7 kit table rides U2.
;;
;; Hygiene (§8): undo disabled, read-only, all inserted file strings
;; pass through `substring-no-properties', `q' buries, killing the
;; buffer never touches the file.
;;
;; §7 deviations (C-c C-c N-A; unread face defined, unapplied) are
;; DESIGN — state them in Commentary, one line each.

;;; Code:

(require 'agent-team)
(require 'org)

(defgroup agent-team-chat nil
  "Configuration for the CHAT.org archive reader."
  :group 'agent-team)

(defcustom agent-team-chat-archive-file nil
  "Absolute path of the CHAT.org archive to render.
Nil means resolve through `agent-team--chat-file' (the repo layout
law).  Set this only for tests or out-of-tree archives."
  :type '(choice (const :tag "auto (agent-team-dir/CHAT.org)" nil)
                 (file :tag "path"))
  :group 'agent-team-chat)

(defcustom agent-team-chat-live-buffer-function nil
  "Function returning the live team chat buffer, or nil.
The U4 seam: when the team buffer's chat region (§10.4) exists, this
returns its buffer and `agent-team-chat-open' switches to it instead
of building the archive render — the live surface is the only
interactive surface (data-flow law v1.3)."
  :type '(choice (const :tag "no live seam yet" nil) function)
  :group 'agent-team-chat)

(defcustom agent-team-chat-members-file nil
  "Absolute path of MEMBERS.org for chat-member: link resolution.
Nil means resolve through `agent-team--file' (\"MEMBERS.org\").
Unknown handles degrade to plain text either way."
  :type '(choice (const :tag "auto (agent-team-dir/MEMBERS.org)" nil)
                 (file :tag "path"))
  :group 'agent-team-chat)

(defcustom agent-team-chat-adapt-for-touch t
  "Enable touch adaptation for the archive reader.
When non-nil and on a touch device, `agent-team-chat-touch-mode' is
activated, setting `scroll-conservatively' to 101 and `truncate-lines'
to t, and binding [down-mouse-1] to a tap handler that acts like RET.
See `agent-team-chat--touch-device-p' for device detection."
  :type 'boolean
  :group 'agent-team-chat)

(defgroup agent-team-chat-faces nil
  "Faces for the CHAT.org archive reader."
  :group 'agent-team-chat)

(defface agent-team-chat-unread-face
  '((t :inherit org-warning))
  "Unread role (section 6).  No archive anchor: the append-only log
has no read state; the U4 live region applies it."
  :group 'agent-team-chat-faces)

(defface agent-team-chat-mention-face
  '((t :inherit bold))
  "Face for mentions (@handle) in the archive."
  :group 'agent-team-chat-faces)

(defface agent-team-chat-preview-face
  '((t :inherit shadow))
  "Preview role (section 6): message body lines, via font-lock."
  :group 'agent-team-chat-faces)

(defface agent-team-chat-time-face
  '((t :inherit org-date))
  "Time role (section 6): delivered by Org's native timestamp
fontification (this face inherits org-date)."
  :group 'agent-team-chat-faces)

(defface agent-team-chat-current-face
  '((t :inherit highlight))
  "Current-chat name role (section 6): the * Team chat title, via
font-lock."
  :group 'agent-team-chat-faces)

(defvar-local agent-team-chat-archive--file nil
  "File this render buffer was built from.")

(defvar agent-team-chat-archive-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "g" 'agent-team-chat-archive-refresh)
    (define-key map "q" 'agent-team-chat-archive-bury)
    (define-key map "j" 'agent-team-chat-jump-latest)
    map)
  "Keys for the archive reader: g re-render from file, q bury, j jump to latest.
The file is never locked (other seats append from CI).")

(defvar agent-team-chat-touch-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [down-mouse-1] #'agent-team-chat-touch-ret)
    map)
  "Keymap for touch mode: single tap acts like RET.")

(defconst agent-team-chat--font-lock-keywords
  '(("@\\([a-zA-Z0-9][a-zA-Z0-9.-]*\\)" 0 'agent-team-chat-mention-face t)
    ("^\\(?:[^*#:\\n][^\\n]*\\)$" 0 'agent-team-chat-preview-face t)
    ("^\\* Team chat$" 0 'agent-team-chat-current-face t))
  "The kit's §6 font-lock keywords (one list, both chat surfaces:
the archive reader mode and the live team chat mode — the U4 design's
shared-faces law).")

(defun agent-team-chat--install-font-lock ()
  "Install font-lock keywords for the archive mode faces.
Applies mention, preview, and current faces according to design A1.
Time and unread faces remain unapplied (Org-native)."
  (font-lock-add-keywords
   'agent-team-chat-archive-mode
   agent-team-chat--font-lock-keywords
   t))

;;;###autoload
(define-minor-mode agent-team-chat-archive-mode
  "Archive reader keys on the *agent-team Chat* render buffer."
  :lighter " chat-archive"
  :keymap agent-team-chat-archive-mode-map
  (when agent-team-chat-archive-mode
    (agent-team-chat--install-font-lock)))

;;;###autoload
(define-minor-mode agent-team-chat-touch-mode
  "Minor mode for touch devices: tap acts like RET.
Enabling sets `scroll-conservatively' to 101 and `truncate-lines' to t
locally (the kit's touch law); only ever turned on when
`agent-team-chat--touch-device-p' is true."
  :lighter " touch"
  :keymap agent-team-chat-touch-mode-map
  (when agent-team-chat-touch-mode
    (setq-local scroll-conservatively 101)
    (setq-local truncate-lines t)))

(defun agent-team-chat--touch-device-p ()
  "Predicate for touch devices (U2).
Checks system-type, TERMUX_VERSION env, and terminal-parameter touch-screen."
  (or (eq system-type 'android)
      (getenv "TERMUX_VERSION")
      (terminal-parameter nil 'touch-screen)))

(defun agent-team-chat-touch-ret (event)
  "Handle a touch tap (U2).
Moves point to the click position and invokes RET behavior:
org-open-at-point on links, else org-return."
  (interactive "e")
  (let ((pos (posn-point (event-start event))))
    (when pos
      (goto-char pos)
      (if (org-in-regexp org-link-any-re)
          (org-open-at-point)
        (org-return)))))

(defun agent-team-chat--install-links ()
  "Install Org link type handlers for `chat-member' and `chat-msg'.

Idempotent: each type is registered only when absent, so re-eval
never duplicates.  `chat-member' follows to
`agent-team-chat-visit-member', `chat-msg' to
`agent-team-chat-goto-msg' (design A2)."
  (unless (assoc "chat-member" org-link-parameters)
    (org-link-set-parameters
     "chat-member"
     :follow #'agent-team-chat-visit-member))
  (unless (assoc "chat-msg" org-link-parameters)
    (org-link-set-parameters
     "chat-msg"
     :follow #'agent-team-chat-goto-msg)))

(agent-team-chat--install-links)

(defun agent-team-chat--chat-file ()
  "The CHAT.org archive file (defcustom override, then layout law)."
  (or agent-team-chat-archive-file
      (condition-case nil (agent-team--chat-file) (error nil))
      (expand-file-name "CHAT.org"
                        (expand-file-name agent-team-dir default-directory))))

(defun agent-team-chat--members-file ()
  "The MEMBERS.org registry file (defcustom override, then layout law)."
  (or agent-team-chat-members-file
      (condition-case nil (agent-team--file "MEMBERS.org") (error nil))))

(defconst agent-team-chat--member-broadcasts '("all")
  "TO values that are broadcasts, never members (§11.2: @all is never
auto-linked because it is not addressable as one member).")

(defun agent-team-chat--member-ids ()
  "Known member ids from MEMBERS.org level-1 headings.
Each `* <Role> — <id> (note)' heading yields the id between the
em-dash and the parenthetical (the MEMBERS ID-FORM law:
PROVIDER/MODEL@PLATFORM, or PROVIDER/ ONLY for API-served models;
single-token relay handles like z.ai-agent qualify too).  Nil when the
file is absent — callers degrade to plain text, never break the
render."
  (let ((file (agent-team-chat--members-file)) ids)
    (when (and file (file-exists-p file))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (re-search-forward "^\\* .+?—[ \t]+\\([^ \t(]+\\)" nil t)
          (let ((id (match-string 1)))
            (when id
              (push (substring-no-properties id) ids))))))
    (nreverse ids)))

(defun agent-team-chat--member-link (handle ids)
  "Render HANDLE as a chat-member: link when known, else plain text.
IDS is the known-id list (resolve via `agent-team-chat--member-ids')."
  (if (and handle
           (not (member handle agent-team-chat--member-broadcasts))
           (member handle ids))
      (format "[[chat-member:%s][@%s]]" handle handle)
    (concat "@" handle)))

(defun agent-team-chat--strip-indent (lines)
  "Drop the common two-space chat indent from LINES."
  (mapcar (lambda (l) (if (string-match "\\`  \\(.*\\)$" l)
                          (match-string 1 l)
                        l))
          lines))

(defun agent-team-chat--linkify (text ids)
  "Linkify URLs and @mentions in TEXT (message body law).
URLs become Org links; @mentions become chat-member: links only when
the handle is known in IDS.  All input was property-stripped upstream."
  (let ((case-fold-search nil))
    ;; URLs first so a mention-like token inside a URL stays intact.
    (setq text (replace-regexp-in-string
                "https?://[^[:space:]]+"
                (lambda (u) (format "[[%s]]" u))
                text))
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (while (re-search-forward "@\\([a-zA-Z0-9][a-zA-Z0-9.-]*\\)" nil t)
        (let* ((handle (match-string 1))
               (repl (agent-team-chat--member-link handle ids)))
          (unless (equal repl (match-string 0))
            (replace-match repl t t))))
      (buffer-string))))

(defun agent-team-chat--body-80 (body)
  "First 80 body chars of BODY for the derived-id law."
  (let ((s (replace-regexp-in-string "[\n\t]" " " (string-trim body))))
    (substring s 0 (min 80 (length s)))))

(defun agent-team-chat--msg-id (from when body n)
  "Derived :MSG-ID: per the design law.
FROM and WHEN are the raw property values, BODY the unindented body,
N the message position in the render.  Missing :WHEN: degrades to the
documented positional id msg-legacy-NNN."
  (setq when (string-trim (or when "")))
  (if (string-empty-p when)
      (format "msg-legacy-%03d" n)
    (concat "msg-"
            (substring (secure-hash 'sha1
                                    (concat from "\0" when "\0"
                                            (agent-team-chat--body-80 body)))
                       0 8))))

(defun agent-team-chat--heading-part (heading regex fallback)
  "Extract the first capture of REGEX in HEADING, else FALLBACK."
  (save-match-data
    (if (string-match regex heading)
        (substring-no-properties (match-string 1 heading))
      fallback)))

(defun agent-team-chat--parse-messages (text)
  "Parse CHAT.org TEXT into message plists (deterministic regex walk).
Each plist carries :heading :props (alist) :body.  Org syntax law:
structured fields ride the :PROPERTIES: drawer; the heading text is
display only.  Comment (\"# \") and \"#+\" lines never become body."
  (let ((lines (split-string text "\n"))
        msgs cur-props body cur-heading)
    (dolist (line lines)
      (cond
       ((string-prefix-p "* MSG " line)
        (when cur-heading
          (push (list :heading cur-heading
                      :props (nreverse cur-props)
                      :body (string-join (nreverse body) "\n"))
                msgs))
        (setq cur-heading (substring-no-properties line)
              cur-props nil body nil))
       ((and cur-heading
             (string-prefix-p ":" line)
             (string-match "^:\\([A-Z-]+\\):[ \t]*\\(.*\\)$" line))
        (push (cons (match-string 1 line)
                    (substring-no-properties (match-string 2 line)))
              cur-props))
       ((and cur-heading (string-prefix-p ":END:" line)))
       ((and cur-heading
             (not (string-prefix-p "# " line))
             (not (string-prefix-p "#+" line))
             (not (string-prefix-p "* " line)))
        (push (substring-no-properties line) body))))
    (when cur-heading
      (push (list :heading cur-heading
                  :props (nreverse cur-props)
                  :body (string-join (nreverse body) "\n"))
            msgs))
    (nreverse msgs)))

(defun agent-team-chat--prop (props key)
  "Property KEY (string) from the parsed drawer alist PROPS."
  (cdr (assoc key props)))

(defun agent-team-chat--stamp (when)
  "Inactive stamp from the raw :WHEN: value, zone suffix removed.
Agenda must never fire (§4 rule 2) — the value already is Org-inactive
bracket syntax; only the trailing zone word moves to :WHEN-ZONE:."
  (setq when (string-trim (or when "")))
  (save-match-data
    (if (string-match "\\`\\[\\(.*\\)\\]\\'" when)
        (format "[%s]"
                (string-trim (replace-regexp-in-string
                              "[ \t]+\\(?:[A-Z][A-Z]+\\|[-+][0-9]+\\)\\'" ""
                              (match-string 1 when))))
      when)))

(defun agent-team-chat--render-message (m n ids)
  "Render one parsed message M (position N) to Org §4 grammar.
IDS is the known-member list for chat-member: resolution."
  (let* ((props (plist-get m :props))
         (heading (plist-get m :heading))
         (from (or (agent-team-chat--prop props "FROM")
                   (agent-team-chat--heading-part
                    heading "^\\* MSG \\(.+?\\) -> @" "unknown")))
         (to (or (agent-team-chat--prop props "TO")
                 (agent-team-chat--heading-part
                  heading "-> @\\([^ \t]+\\)" "unknown")))
         (kind (or (agent-team-chat--prop props "KIND")
                   (agent-team-chat--heading-part
                    heading ":\\([a-z-]+\\):" "")))
         (when (or (agent-team-chat--prop props "WHEN") ""))
         (stamp (agent-team-chat--stamp when))
         (body (string-join
                (agent-team-chat--strip-indent
                 (split-string (or (plist-get m :body) "") "\n"))
                "\n"))
         (msg-id (agent-team-chat--msg-id from when body n))
         (rendered-body (if (string-empty-p (string-trim body)) ""
                          (concat (agent-team-chat--linkify body ids) "\n"))))
    (concat
     "** "
     (if (string-empty-p stamp) "" (concat stamp " "))
     from " -> " (agent-team-chat--member-link to ids)
     (if (string-empty-p kind) "" (concat " :" kind ":"))
     "\n"
     ":PROPERTIES:\n"
     (format ":AUTHOR: %s\n" from)
     (format ":TO: %s\n" to)
     (unless (string-empty-p (agent-team-chat--prop props "CHANNEL"))
       (format ":CHANNEL: %s\n" (agent-team-chat--prop props "CHANNEL")))
     (save-match-data
       (unless (string-empty-p (agent-team-chat--prop props "WHEN"))
         (when (string-match "[ \t]\\([A-Z][A-Z]+\\|[-+][0-9]+\\)\\]" when)
           (format ":WHEN-ZONE: %s\n" (match-string 1 when)))))
     (format ":MSG-ID: %s\n" msg-id)
     ":END:\n"
     rendered-body)))

(defun agent-team-chat--render-string (text &optional ids)
  "Render CHAT.org TEXT to the §4 view grammar.
Optional IDS is the known-member list; nil resolves from MEMBERS.org.
The render is a string with zero text properties (org-mode
fontification belongs to the buffer, not the render law), so the same
file always yields byte-identical output — the ERT suite asserts that
idempotence.  Rebuilding the buffer (not patching it) keeps Org's
element cache and fold registry fresh — same decision as emacs-purple
0882373."
  (let ((ids (or ids (agent-team-chat--member-ids)))
        (msgs (agent-team-chat--parse-messages text))
        (n 0))
    (concat
     "#+STARTUP: overview\n"
     "* Team chat\n"
     ":PROPERTIES:\n"
     ":CHAT-ID: agent-team/CHAT.org\n"
     ":KIND: group\n"
     ":END:\n"
     (mapconcat
      (lambda (m) (setq n (1+ n))
        (agent-team-chat--render-message m n ids))
      msgs ""))))

(defun agent-team-chat--file-buffer (file)
  "A live buffer visiting FILE, or nil (no forking the live view)."
  (let (found)
    (dolist (b (buffer-list))
      (when (and (buffer-live-p b)
                 (buffer-file-name b)
                 (file-equal-p (buffer-file-name b) file)
                 (null found))
        (setq found b)))
    found))

(defun agent-team-chat--build-buffer (file)
  "Kill-rebuild the *agent-team Chat* render buffer from FILE.
Fresh buffer = fresh Org state; the file is only READ (§11.3)."
  (let* ((text (with-temp-buffer
                 (insert-file-contents file)
                 (substring-no-properties (buffer-string))))
         (rendered (agent-team-chat--render-string text))
         (buf (get-buffer-create "*agent-team Chat*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (buffer-disable-undo)
        (erase-buffer)
        (insert rendered)
        (org-mode)
        (unless agent-team-chat-archive-mode
          (agent-team-chat-archive-mode 1))
        (when (and agent-team-chat-adapt-for-touch
                   (agent-team-chat--touch-device-p))
          (agent-team-chat-touch-mode 1))
        (setq agent-team-chat-archive--file file
              buffer-read-only t
              header-line-format
              (format "agent-team chat archive — %s (g re-render, q bury; file is read-only here, the live session owns writes)"
                      (file-name-nondirectory file)))))
    buf))

;;;###autoload
(defun agent-team-chat-open ()
  "Open the team chat per the data-flow law (design v1.3).
Resolve first: the live session supplied by
`agent-team-chat-live-buffer-function', then any buffer already
visiting the chat file (the raw session view) — switching, never
forking state.  Only when neither exists build *agent-team Chat* from
the file: the reopen/resume reader for restart/crash survival, entries
that landed from CI while this Emacs was closed, and history.  This
definition supersedes agent-team.el's raw `find-file' version (see
this file's Commentary); the file stays the single source of truth."
  (interactive)
  (let* ((file (agent-team-chat--chat-file))
         (live (and agent-team-chat-live-buffer-function
                    (funcall agent-team-chat-live-buffer-function))))
    (cond
     (live (pop-to-buffer live))
     ((not (file-exists-p file))
      (user-error "No chat archive at %s (and no live session)" file))
     ((agent-team-chat--file-buffer file)
      (pop-to-buffer (agent-team-chat--file-buffer file)))
     (t
      (pop-to-buffer (agent-team-chat--build-buffer file))
      (with-current-buffer "*agent-team Chat*"
        (goto-char (point-max)))
      (message "agent-team chat: archive render of %s (g re-render, q bury; live session absent)"
               (abbreviate-file-name file))))))

(defun agent-team-chat-archive-refresh ()
  "Re-render the archive from the file (verb `g').
Other seats append from CI — the file may have moved since this
buffer was built.  Never writes the file."
  (interactive)
  (let ((file agent-team-chat-archive--file))
    (unless (and file (file-exists-p file))
      (user-error "Archive file %s is gone" (or file "<unset>")))
    (agent-team-chat--build-buffer file)
    (when (get-buffer-window "*agent-team Chat*")
      (set-window-point (get-buffer-window "*agent-team Chat*")
                        (with-current-buffer "*agent-team Chat*"
                          (point-max))))
    (message "agent-team chat: re-rendered from %s"
             (abbreviate-file-name file))))

(defun agent-team-chat-archive-bury ()
  "Bury the archive buffer (verb `q').  Killing is not needed: the
buffer never locks the file and killing it would never touch the file
either (§8)."
  (interactive)
  (bury-buffer))

(defun agent-team-chat-visit-member (id)
  "Follow a chat-member: link (design A2).
Visit MEMBERS.org and move point to the `* <Role> -- <id>' heading —
the member's registry entry, agent-team.el's own member path today
(transport-aware dispatch waits for the U3 registry).  Unknown ID
raises a user-error naming the handle."
  (interactive "sMember ID: ")
  (let ((file (agent-team-chat--members-file)))
    (unless (and file (file-exists-p file))
      (user-error "MEMBERS.org not found at %s" file))
    (pop-to-buffer-same-window (find-file-noselect file))
    (goto-char (point-min))
    (if (re-search-forward (concat "^\\* .*— " (regexp-quote id)) nil t)
        (goto-char (match-beginning 0))
      (user-error "Member ID `%s' not found in MEMBERS.org" id))))

(defun agent-team-chat-goto-msg (id)
  "Follow a chat-msg: link (design A2).
Resolve the derived :MSG-ID: drawer to its message heading and jump
there.  From any other buffer the archive render is opened first;
an unknown id raises a user-error naming it."
  (interactive "sMessage ID: ")
  (unless (derived-mode-p 'agent-team-chat-archive-mode)
    (let ((file (agent-team-chat--chat-file)))
      (unless (and file (file-exists-p file))
        (user-error "No chat archive at %s" (or file "<unset>")))
      (pop-to-buffer (agent-team-chat--build-buffer file))))
  (goto-char (point-min))
  (if (re-search-forward (format "^:MSG-ID: %s$" (regexp-quote id)) nil t)
      (org-back-to-heading t)
    (user-error "Message ID `%s' not found in the archive" id)))

(defun agent-team-chat-jump-latest ()
  "Jump to the newest message heading (verb `j').
The archive degradation of jump-to-first-unread (no read state; every
chat client resumes at the tail)."
  (interactive)
  (if (derived-mode-p 'agent-team-chat-archive-mode)
      (goto-char (point-max))
    (let ((file (agent-team-chat--chat-file)))
      (unless (and file (file-exists-p file))
        (user-error "No chat archive at %s" (or file "<unset>")))
      (pop-to-buffer (agent-team-chat--build-buffer file))
      (with-current-buffer "*agent-team Chat*"
        (goto-char (point-max))))))

(provide 'agent-team-chat)
;;; agent-team-chat.el ends here
