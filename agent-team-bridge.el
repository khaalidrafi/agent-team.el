;;; agent-team-bridge.el --- §11 cloud-member chat bridge -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Khalid Rafi
;; Author: Khalid Rafi <khaalidrafi@gmail.com>
;; Keywords: tools, ai, org, comm
;; Package-Requires: ((emacs "28.1"))
;; URL: https://github.com/khaalidrafi/agent-team.el
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; U3 of the standard v1.1 adoption (binding design:
;; docs/CLOUD-BRIDGE-DESIGN.org in this repo): the dispatch engine that
;; lets the team group chat talk to cloud and web-model members
;; (ORG-CHAT-STANDARD.org v1.1 section 11; checklist item 9.11).
;;
;; REGISTRY.  A chat member is a MEMBERS.org level-1 seat.  Its entry
;; may declare a :PROPERTIES: drawer: :TRANSPORT: (relay / acp /
;; llm-api), and for llm-api :ENDPOINT: (PROVIDER/MODEL), :AUTH: (a
;; vault/authinfo ALIAS ONLY — a secret VALUE in an Org file is a
;; checklist 9.10 violation; values resolve in memory at call time),
;; :PERSONA: (system-prompt file path).  Seats without :TRANSPORT: are
;; not dispatchable — an addressed message goes queued → err, never a
;; silent drop (§11.6).
;;
;; LOOP LAW (§11.5).  Dispatch only messages addressed to exactly one
;; llm-api member (:TO: drawer match or a [[chat-member:ID][...]] link
;; in the body).  TO = all is a broadcast, never auto-dispatched.  A
;; message FROM an llm-api member is never relayed on (member→member
;; reflexive relay is barred) unless the chat's file-level
;; #+AUTOPILOT: keyword is non-nil, and even then only within
;; `agent-team-bridge-max-hops' consecutive member replies.  Loop-law
;; bars are by-design non-delivery — they are not failures and carry no
;; err stamp; failures are addressed-but-undeliverable messages.
;;
;; LIFECYCLE (§11.3 + §11.6).  Dispatch stamps :queued: on the message
;; heading plus :MEMBER:/:CHANNEL: drawers (checklist 9.11).  Success
;; appends the member's reply through `agent-team--chat-append-1' (the
;; one §4-rule-6 append path: FROM = member id, TO = original sender,
;; KIND = note) and drops the :queued: tag.  Failure retags
;; :queued: → :err: and appends one `BRIDGE-ERR: <reason>' line to the
;; entry body; `agent-team-bridge-retry' re-queues.  EDIT EXCEPTION:
;; the bridge edits only the lifecycle tag of a message it stamped and
;; appends only its own reason line or reply — it never rewrites or
;; deletes an entry it did not stamp.
;;
;; TRANSPORT.  system = the persona file + `agent-team-bridge-team-law-
;; summary'; conversation = the transcript tail rendered from the chat
;; file itself (last `agent-team-bridge-context-messages' messages,
;; author-labeled) — the Org file is the single source of truth, no
;; parallel chat state.  HTTP is an OpenAI-compatible chat/completions
;; POST behind `agent-team-bridge-http-post-function'; provider base
;; URLs ride `agent-team-bridge-provider-base-urls'; an :ENDPOINT: that
;; is already a full URL is used verbatim.
;;
;; PRIVACY (§11.7).  A seat marked :PRIVACY: training is refused
;; outright (deterministic reading of "training lanes never receive
;; private code": chat bodies are not classified, so the lane stays
;; closed until the Owner re-marks it).
;;
;; TESTS.  Every side effect rides a seam
;; (`agent-team-bridge-http-post-function',
;; `agent-team-bridge-auth-lookup-function',
;; `agent-team-bridge-autopilot-function') — the ERT suite is offline
;; and deterministic (§9.9).

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'org)
(require 'url)
(require 'auth-source)
(require 'agent-team)
(require 'agent-team-chat)

(defgroup agent-team-bridge nil
  "Dispatch bridge for cloud/web-model chat members (§11)."
  :group 'agent-team)

(defcustom agent-team-bridge-context-messages 20
  "Transcript-tail size for llm-api dispatch (§11.3): the last N
messages of the chat file, author-labeled, ride every call."
  :type 'natnum
  :group 'agent-team-bridge)

(defcustom agent-team-bridge-scan-window 50
  "How many tail messages `agent-team-bridge-tick' scans for
eligible undispatched messages."
  :type 'natnum
  :group 'agent-team-bridge)

(defcustom agent-team-bridge-max-hops 4
  "Reply-chain hop budget (§11.5): the bridge never dispatches past
this many consecutive member replies, even under #+AUTOPILOT: t."
  :type 'natnum
  :group 'agent-team-bridge)

(defcustom agent-team-bridge-team-law-summary
  "You are a member of the agent-team group chat, talking inside the \
team's single Org chat file.  Team law: reply to the point asked; no \
secret, token, or credential value ever enters your reply; your reply \
is appended verbatim to the shared transcript every member reads, so \
write for the whole team; do not invent team facts you were not \
given; when a task is yours, answer with the concrete next step."
  "The one-paragraph team-law summary appended to every llm-api
system prompt (§11.3)."
  :type 'string
  :group 'agent-team-bridge)

(defcustom agent-team-bridge-provider-base-urls
  '(("zai" . "https://api.z.ai/api/paas/v4")
    ("openai" . "https://api.openai.com/v1"))
  "PROVIDER → OpenAI-compatible base URL for :ENDPOINT: values.
An :ENDPOINT: that is already a full URL is used verbatim.  Entries
here are configuration, never credentials."
  :type '(alist :key-type (string :tag "provider")
                :value-type (string :tag "base URL"))
  :group 'agent-team-bridge)

(defun agent-team-bridge--autopilot-p (file)
  "Read the chat's file-level #+AUTOPILOT: keyword (§11.5).
Anything non-blank after the keyword turns autopilot on; the default
chat has no keyword, so reply chains stop after one hop."
  (when (and file (file-exists-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (when (re-search-forward "^#\\+AUTOPILOT:[ \t]*\\(.*\\)$" nil t)
        (let ((v (string-trim (match-string 1))))
          (and (not (string-empty-p v))
               (not (equal (downcase v) "nil"))))))))

(defvar agent-team-bridge-http-post-function
  #'agent-team-bridge--http-post
  "Seam: (FN URL HEADERS PAYLOAD) → response-body string, or signals.
Tests stub this; the default does a synchronous OpenAI-compatible
chat/completions POST.  No test, CI run, or gate may hit the network.")

(defvar agent-team-bridge-auth-lookup-function
  #'agent-team-bridge--auth-lookup
  "Seam: (FN ALIAS) → secret string or nil.  Resolved in memory at
call time; never logged, never written to any file.")

(defvar agent-team-bridge-autopilot-function
  #'agent-team-bridge--autopilot-p
  "Seam: (FN FILE) → non-nil when the chat's :AUTOPILOT: is on
(§11.5).  Default reads the file-level #+AUTOPILOT: keyword; nil
(default chat) means reply chains stop after one hop.")

;;; Registry (§11.1) ---------------------------------------------------

(defun agent-team-bridge--registry (&optional file)
  "Parse MEMBERS.org FILE into member plists.
Each level-1 `* <Role> — <id> (note)' heading yields
(:id :role :transport :endpoint :auth :persona :privacy) from its
:PROPERTIES: drawer when present.  Deterministic regex walk (the U1
parser style); seats without :TRANSPORT: carry nil transport."
  (let ((file (or file (agent-team-chat--members-file)))
        members)
    (when (and file (file-exists-p file))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (re-search-forward "^\\* .+?—[ \t]+\\([^ \t(]+\\)" nil t)
          (let ((id (match-string 1))
                (role (string-trim
                       (replace-regexp-in-string
                        "—[ \\t]*\\'" ""
                        (substring-no-properties
                         (buffer-substring
                          (+ (line-beginning-position) 2)
                          (match-beginning 1))))))
                props)
            ;; one :PROPERTIES: drawer right after the heading
            (save-excursion
              (forward-line 1)
              (while (and (not (eobp)) (not (looking-at "^\\* "))
                          (not (looking-at "^[ \t]*:END:[ \t]*$")))
                (when (looking-at "^[ \t]*:\\([A-Z-]+\\):[ \t]*\\(.*\\)$")
                  (push (cons (match-string 1)
                              (substring-no-properties (match-string 2)))
                        props))
                (forward-line 1)))
            (setq props (nreverse props))
            (push (list :id id
                        :role role
                        :transport (cdr (assoc "TRANSPORT" props))
                        :endpoint (cdr (assoc "ENDPOINT" props))
                        :auth (cdr (assoc "AUTH" props))
                        :persona (cdr (assoc "PERSONA" props))
                        :privacy (cdr (assoc "PRIVACY" props)))
                  members)))))
    (nreverse members)))

(defun agent-team-bridge--member (id members)
  "The member plist with :ID ID from MEMBERS, or nil."
  (cl-find id members :key (lambda (m) (plist-get m :id))
           :test #'equal))

;;; Addressing + eligibility (§11.2 + §11.5) ---------------------------

(defun agent-team-bridge--addressed-member (msg members)
  "The member the message MSG addresses, or nil.
Deliverable addressing (§11.2): the :TO: drawer names the member's id
exactly (with or without the @ prefix), or the body carries a
[[chat-member:ID][...]] link.  TO = all is a broadcast and never
matches."
  (let* ((props (plist-get msg :props))
         (to (string-remove-prefix
             "@" (string-trim (or (agent-team-chat--prop props "TO") ""))))
         (body (or (plist-get msg :body) ""))
         (ids (mapcar (lambda (m) (plist-get m :id)) members))
         hit)
    (setq hit (car (member to ids)))
    (unless hit
      (catch 'found
        (dolist (id ids)
          (when (string-match-p
                 (concat "\\[\\[chat-member:" (regexp-quote id)
                         "\\]\\(\\]\\|\\[\\)") body)
            (setq hit id)
            (throw 'found id)))))
    (and hit (agent-team-bridge--member hit members))))

(defun agent-team-bridge--llm-api-member-p (member)
  "Non-nil when MEMBER's transport is llm-api."
  (and member (equal (plist-get member :transport) "llm-api")))

(defun agent-team-bridge--hop-budget-p (msgs index max-hops members)
  "Non-nil when the reply chain ending at message INDEX (0-based)
stays within MAX-HOPS consecutive member replies (§11.5).  Bounded
backward walk of the parsed message list — no parallel chat state."
  (let ((depth 0) (j index) (over nil))
    (while (and (>= j 0) (not over))
      (let* ((m (nth j msgs))
             (from (or (agent-team-chat--prop (plist-get m :props) "FROM")
                       "")))
        (if (agent-team-bridge--llm-api-member-p
             (agent-team-bridge--member from members))
            (setq depth (1+ depth)
                  over (> depth max-hops))
          (setq j -1)))
      (setq j (1- j)))
    (<= depth max-hops)))

(defun agent-team-bridge--eligible-p (msg members autopilot hops-ok)
  "Classify message MSG against MEMBERS.
Returns (TARGET . REASON) where REASON nil means dispatchable, a
string means addressed-but-refused (stamp queued then err), and the
whole cons is nil when the message is not bridge business at all
(unaddressed, broadcast, or loop-law barred — by-design
non-delivery, no stamp)."
  (let* ((target (agent-team-bridge--addressed-member msg members))
         (from (string-trim
                (or (agent-team-chat--prop (plist-get msg :props) "FROM")
                    "")))
         (from-member (agent-team-bridge--member from members)))
    (cond
     ((null target) nil)
     (from-member
      (cond
       ((not autopilot) nil)
       ((equal (plist-get from-member :id) (plist-get target :id)) nil)
       ((not hops-ok) (cons target "hop budget exhausted (§11.5)"))
       (t (cons target nil))))
     ((null (plist-get target :transport))
      ;; registered seat, no transport declared: undeliverable,
      ;; never a silent drop (§11.6)
      (cons target "no :TRANSPORT: declared in the member entry"))
     ((equal (plist-get target :privacy) "training")
      (cons target "training-host lane; privacy law §11.7"))
     ((not (agent-team-bridge--llm-api-member-p target))
      ;; relay/acp are live-surface transports outside this engine
      ;; (the Discord relay / U4 live sessions): by-design
      ;; non-delivery here, no lifecycle stamp
      nil)
     (t (cons target nil)))))

;;; Lifecycle helpers (file-buffer surgical ops) -----------------------

(defun agent-team-bridge--goto-msg (index)
  "In the current file buffer move point to the INDEXth (0-based)
`* MSG' heading.  Error when the file has fewer entries."
  (goto-char (point-min))
  (let ((n -1))
    (while (and (re-search-forward "^\\* MSG " nil t)
                (< (setq n (1+ n)) index)))
    (or (= n index)
        (error "agent-team-bridge: chat entry %d not found" index))
    (goto-char (match-beginning 0))))

(defun agent-team-bridge--stamp-queued (file index member-id)
  "Stamp :queued: plus :MEMBER:/:CHANNEL: drawers on entry INDEX."
  (with-current-buffer (find-file-noselect file)
    (save-excursion
      (agent-team-bridge--goto-msg index)
      (let ((line (buffer-substring (line-beginning-position)
                                    (line-end-position))))
        (unless (string-match-p ":queued:" line)
          (save-excursion (end-of-line) (insert " :queued:"))))
      (save-excursion
        (forward-line 1)
        (org-entry-put (point) "MEMBER" member-id)
        (org-entry-put (point) "CHANNEL" "bridge")))
    (save-buffer)))

(defun agent-team-bridge--retag-err (file index reason)
  "Retag entry INDEX :queued: → :err: and append the reason line.
The reason line is the only body text the bridge ever writes into an
entry it did not author (§11.6; design edit exception).  The reason
is one line (newlines flattened); a retried entry keeps its earlier
BRIDGE-ERR lines as the audit trail."
  (with-current-buffer (find-file-noselect file)
    (save-excursion
      (agent-team-bridge--goto-msg index)
      (when (re-search-forward ":queued:" (line-end-position) t)
        (replace-match ":err:"))
      ;; the end of THIS entry: the next `* MSG' heading or point-max
      (forward-line 1)
      (if (re-search-forward "^\\* MSG " nil 'move)
          (goto-char (match-beginning 0))
        (goto-char (point-max)))
      (unless (bolp) (insert "\n"))
      (insert (format "  BRIDGE-ERR: %s\n"
                      (replace-regexp-in-string
                       "[\r\n]+" " "
                       (substring-no-properties reason)))))
    (save-buffer)))

(defun agent-team-bridge--drop-queued (file index)
  "Drop the :queued: tag from entry INDEX (delivered; the reply
in-thread is the receipt)."
  (with-current-buffer (find-file-noselect file)
    (save-excursion
      (agent-team-bridge--goto-msg index)
      (beginning-of-line)
      (when (re-search-forward "[ \t]:queued:" (line-end-position) t)
        (replace-match "")))
    (save-buffer)))

;;; Transport (§11.3) ---------------------------------------------------

(defun agent-team-bridge--persona-text (member)
  "The persona file text for MEMBER, or signal when declared but
missing (a silent empty persona would drop the member's voice)."
  (let ((path (plist-get member :persona)))
    (if (or (null path) (string-empty-p (string-trim path)))
        ""
      (if (and (file-exists-p path) (file-readable-p path))
          (with-temp-buffer
            (insert-file-contents path)
            (string-trim (substring-no-properties (buffer-string))))
        (error "agent-team-bridge: persona file not found: %s" path)))))

(defun agent-team-bridge--strip-bridge-err (body)
  "Drop BRIDGE-ERR lines from BODY — the bridge's own audit trail
never rides back into a persona prompt or transcript tail."
  (mapconcat #'identity
             (cl-remove-if
              (lambda (l) (string-match-p "^[ \\t]*BRIDGE-ERR:" l))
              (split-string (or body "") "\n"))
             "\n"))

(defun agent-team-bridge--system-prompt (member)
  "Persona text plus the one-paragraph team-law summary (§11.3)."
  (let ((persona (agent-team-bridge--persona-text member)))
    (if (string-empty-p persona)
        agent-team-bridge-team-law-summary
      (concat persona "\n\n" agent-team-bridge-team-law-summary))))

(defun agent-team-bridge--transcript-tail (text n)
  "The last N messages of chat TEXT, author-labeled, newest last.
Rendered from the Org document itself — the single source of truth
(§11.3); no parallel chat state exists anywhere."
  (let* ((msgs (agent-team-chat--parse-messages text))
         (tail (last msgs (min n (length msgs))))
         lines)
    (dolist (m tail)
      (let* ((props (plist-get m :props))
             (from (or (agent-team-chat--prop props "FROM")
                       (agent-team-chat--heading-part
                        (plist-get m :heading) "^\\* MSG \\(.+?\\) -> @" "?")))
             (to (or (agent-team-chat--prop props "TO") "?"))
             (kind (or (agent-team-chat--prop props "KIND") "note"))
             (body (string-trim
                    (mapconcat #'identity
                               (agent-team-chat--strip-indent
                                (split-string
                                 (agent-team-bridge--strip-bridge-err
                                  (or (plist-get m :body) ""))
                                 "\n"))
                               " "))))
        (setq body (replace-regexp-in-string "[\n\t]+" " " body))
        (when (> (length body) 400)
          (setq body (substring body 0 400)))
        (push (format "%s -> @%s (%s): %s" from to kind body) lines)))
    (mapconcat #'identity (nreverse lines) "\n")))

(defun agent-team-bridge--endpoint-url (member)
  "Absolute chat/completions URL for MEMBER's :ENDPOINT:.
PROVIDER/MODEL resolves through
`agent-team-bridge-provider-base-urls'; a full-URL endpoint is used
verbatim."
  (let ((endpoint (string-trim (or (plist-get member :endpoint) ""))))
    (when (string-empty-p endpoint)
      (error "agent-team-bridge: member %s has no :ENDPOINT:"
             (plist-get member :id)))
    (if (string-match-p "\\`https?://" endpoint)
        (concat (string-remove-suffix "/" endpoint) "/chat/completions")
      (string-match "\\`\\([^/]+\\)/\\(.+\\)\\'" endpoint)
      (let* ((provider (match-string 1 endpoint))
             (base (cdr (assoc provider
                               agent-team-bridge-provider-base-urls))))
        (unless base
          (error "agent-team-bridge: no base URL for provider %s"
                 provider))
        (concat (string-remove-suffix "/" base)
                "/chat/completions")))))

(defun agent-team-bridge--endpoint-model (member)
  "The MODEL half of MEMBER's PROVIDER/MODEL :ENDPOINT:."
  (let ((endpoint (string-trim (plist-get member :endpoint))))
    (if (string-match "\\`[^/]+/\\(.+\\)\\'" endpoint)
        (match-string 1 endpoint)
      endpoint)))

(defun agent-team-bridge--payload (member system tail prompt)
  "OpenAI-compatible JSON payload string for MEMBER."
  (let ((json-encoding-pretty-print nil)
        (sys `((role . "system") (content . ,system)))
        (usr `((role . "user")
               (content . ,(concat tail "\n\n" prompt)))))
    (json-encode
     `((model . ,(agent-team-bridge--endpoint-model member))
       (messages . (,sys ,usr))))))

(defun agent-team-bridge--extract-content (buffer url)
  "Parse BUFFER's HTTP response: require 2xx + choices[0].message.content."
  (with-current-buffer buffer
    (goto-char (point-min))
    (let ((status-line (buffer-substring (line-beginning-position)
                                         (line-end-position))))
      (unless (string-match-p "HTTP/1\\.[01] 2[0-9][0-9]" status-line)
        (error "agent-team-bridge: %s" status-line))
      (unless (re-search-forward "\r?\n\r?\n" nil t)
        (error "agent-team-bridge: malformed response from %s" url))
      (let* ((resp (json-read))
             (choices (cdr (assoc 'choices resp)))
             (content (and choices
                           (cdr (assoc 'content
                                       (cdr (assoc 'message
                                                   (nth 0 choices))))))))
        (unless (stringp content)
          (error "agent-team-bridge: empty assistant content"))
        content))))

(defun agent-team-bridge--http-post (url headers payload)
  "Synchronous OpenAI-compatible POST (the default seam impl).
Returns the assistant content string; signals on any non-2xx."
  (let ((url-request-method "POST")
        (url-request-extra-headers headers)
        (url-request-data (encode-coding-string payload 'utf-8))
        (json-object-type 'alist)
        (json-array-type 'list)
        (buffer (url-retrieve-synchronously url)))
    (unless buffer
      (error "agent-team-bridge: no response from %s" url))
    (unwind-protect
        (agent-team-bridge--extract-content buffer url)
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun agent-team-bridge--auth-lookup (alias)
  "Resolve the :AUTH: ALIAS in memory: auth-source, then the
AGENT_TEAM_BRIDGE_AUTH_<ALIAS> env var.  The alias never stands for a
secret VALUE in any Org file (§9.10)."
  (or (ignore-errors
        (let* ((entry (car (auth-source-search :host alias :max 1)))
               (secret (and entry (plist-get entry :secret))))
          (when secret
            (if (functionp secret) (funcall secret) secret))))
      (getenv (concat "AGENT_TEAM_BRIDGE_AUTH_"
                      (upcase
                       (replace-regexp-in-string "[^A-Za-z0-9]" "_"
                                                 alias))))))

;;; Dispatch cycle ------------------------------------------------------

(defun agent-team-bridge--dispatch-index (file index members autopilot)
  "Run one dispatch cycle for chat entry INDEX (0-based) in FILE.
Returns (STATUS . DETAIL): delivered / err / skipped."
  (let* ((text (with-temp-buffer
                 (insert-file-contents file)
                 (substring-no-properties (buffer-string))))
         (msgs (agent-team-chat--parse-messages text))
         (msg (nth index msgs))
         (hops-ok (agent-team-bridge--hop-budget-p
                   msgs index agent-team-bridge-max-hops members))
         (verdict (agent-team-bridge--eligible-p
                   msg members autopilot hops-ok)))
    (cond
     ((null verdict) (cons 'skipped "not bridge business (loop law §11.5)"))
     (t
      (let* ((member (car verdict))
             (pre-reason (cdr verdict)))
        (agent-team-bridge--stamp-queued
         file index (plist-get member :id))
        (if pre-reason
            (progn (agent-team-bridge--retag-err file index pre-reason)
                   (cons 'err pre-reason))
          (condition-case err
              (let* ((system (agent-team-bridge--system-prompt member))
                     (tail (agent-team-bridge--transcript-tail
                            text agent-team-bridge-context-messages))
                     (prompt (string-trim
                              (agent-team-bridge--strip-bridge-err
                               (or (plist-get msg :body) ""))))
                     (payload (agent-team-bridge--payload
                               member system tail prompt))
                     (alias (plist-get member :auth))
                     (key (and alias
                               (funcall agent-team-bridge-auth-lookup-function
                                        (string-trim alias)))))
                (unless key
                  (error "agent-team-bridge: no secret for :AUTH: %s"
                         (or alias "undeclared")))
                (let* ((reply (funcall agent-team-bridge-http-post-function
                                       (agent-team-bridge--endpoint-url member)
                                       (list (cons "Content-Type"
                                                   "application/json")
                                             (cons "Authorization"
                                                   (concat "Bearer " key)))
                                       payload))
                       (from (string-trim
                              (or (agent-team-chat--prop
                                   (plist-get msg :props) "FROM")
                                  "owner"))))
                  (agent-team--chat-append-1
                   (plist-get member :id) from "note"
                   (string-trim reply) nil nil nil file)
                  (agent-team-bridge--drop-queued file index)
                  (cons 'delivered (plist-get member :id))))
            (error
             (agent-team-bridge--retag-err
              file index (error-message-string err))
             (cons 'err (error-message-string err))))))))))

(defun agent-team-bridge--dispatchable-p (msg)
  "Non-nil when MSG has no lifecycle stamp yet (no MEMBER drawer,
no :queued:/:err: tag on its heading)."
  (let* ((props (plist-get msg :props))
         (heading (or (plist-get msg :heading) "")))
    (and (null (agent-team-chat--prop props "MEMBER"))
         (not (string-match-p ":queued:" heading))
         (not (string-match-p ":err:" heading)))))

(defun agent-team-bridge-tick ()
  "Scan the chat tail and dispatch every eligible undispatched
message, oldest first (the bridge's queue law).  Returns the count
dispatched.  Never touches broadcast or loop-law-barred messages."
  (interactive)
  (let* ((file (agent-team-chat--chat-file))
         (members (agent-team-bridge--registry))
         (autopilot (funcall agent-team-bridge-autopilot-function file))
         (text (with-temp-buffer
                 (insert-file-contents file)
                 (substring-no-properties (buffer-string))))
         (msgs (agent-team-chat--parse-messages text))
         (start (max 0 (- (length msgs) agent-team-bridge-scan-window)))
         (done 0))
    (when (zerop (length msgs))
      (user-error "agent-team-bridge: no chat entries in %s" file))
    (dolist (i (number-sequence start (1- (length msgs))))
      (let ((msg (nth i msgs)))
        (when (agent-team-bridge--dispatchable-p msg)
          (let ((verdict (agent-team-bridge--eligible-p
                          msg members autopilot
                          (agent-team-bridge--hop-budget-p
                           msgs i agent-team-bridge-max-hops members))))
            (when verdict
              (let ((result (agent-team-bridge--dispatch-index
                             file i members autopilot)))
                (unless (eq (car result) 'skipped) (setq done (1+ done)))))))))
    (message "agent-team-bridge: dispatched %d message(s)" done)
    done))

(defun agent-team-bridge-dispatch ()
  "Dispatch one message now: the entry at point when the current
buffer visits the chat file and point is on a `* MSG' heading,
otherwise the newest eligible tail entry.  Stamps the §11 lifecycle
(:queued: → reply | :err:) and reports the outcome."
  (interactive)
  (let* ((file (agent-team-chat--chat-file))
         (members (agent-team-bridge--registry))
         (autopilot (funcall agent-team-bridge-autopilot-function file))
         (text (with-temp-buffer
                 (insert-file-contents file)
                 (substring-no-properties (buffer-string))))
         (msgs (agent-team-chat--parse-messages text))
         (index
          (cond
           ((and buffer-file-name
                 (file-equal-p buffer-file-name file)
                 (save-excursion (beginning-of-line)
                                 (looking-at "^\\* MSG ")))
            (save-excursion
              (goto-char (point-min))
              (let ((n 0))
                (while (re-search-forward "^\\* MSG " (line-beginning-position 2) t)
                  (setq n (1+ n)))
                (1- n))))
           (t (let ((found nil) (i (1- (length msgs))))
                (while (and (>= i 0) (not found))
                  (when (and (agent-team-bridge--dispatchable-p (nth i msgs))
                             (agent-team-bridge--eligible-p
                              (nth i msgs) members autopilot
                              (agent-team-bridge--hop-budget-p
                               msgs i agent-team-bridge-max-hops members)))
                    (setq found i))
                  (setq i (1- i)))
                (or found
                    (user-error
                     "agent-team-bridge: no eligible message in the tail")))))))
    (let ((result (agent-team-bridge--dispatch-index
                   file index members autopilot)))
      (message "agent-team-bridge: %s (%s)" (car result) (cdr result))
      result)))

(defun agent-team-bridge-retry ()
  "Re-queue the newest :err: entry and re-dispatch it (§11.6:
retries re-queue).  Returns the dispatch result."
  (interactive)
  (let* ((file (agent-team-chat--chat-file))
         (text (with-temp-buffer
                 (insert-file-contents file)
                 (substring-no-properties (buffer-string))))
         (msgs (agent-team-chat--parse-messages text))
         (members (agent-team-bridge--registry))
         (autopilot (funcall agent-team-bridge-autopilot-function file))
         (i (1- (length msgs)))
         (found nil))
    (while (and (>= i 0) (not found))
      (when (string-match-p ":err:" (or (plist-get (nth i msgs) :heading) ""))
        (setq found i))
      (setq i (1- i)))
    (unless found
      (user-error "agent-team-bridge: no :err: entry to retry"))
    (with-current-buffer (find-file-noselect file)
      (save-excursion
        (agent-team-bridge--goto-msg found)
        (beginning-of-line)
        (when (re-search-forward ":err:" (line-end-position) t)
          (replace-match ":queued:")))
      (save-buffer))
    (let ((result (agent-team-bridge--dispatch-index
                   file found members autopilot)))
      (message "agent-team-bridge retry: %s (%s)"
               (car result) (cdr result))
      result)))

(provide 'agent-team-bridge)
;;; agent-team-bridge.el ends here
