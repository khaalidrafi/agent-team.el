;;; agent-team-live-test.el --- U4 live team chat ERT suite (offline) -*- lexical-binding: t; -*-

;;; Commentary:

;; §9.9 fixture law: offline, deterministic, NO NETWORK.  Fixture files
;; are generated into a fresh temp dir per test; the bridge's http/auth
;; seams and the acp dispatch seam are stubbed, so no provider is ever
;; contacted.  Assertions: the §4 kit render of the live buffer, the U1
;; live-seam resolution, the unread overlay + j law, the send path (the
;; auto-save append), the §11 dispatch truth table (llm-api via the
;; engine, acp via the seam with no stamp, relay no-op, broadcast/
;; undeclared/bridge-unloaded user-errors), and the §8 hygiene law
;; (property-free render string, read-only, undo disabled, q/kill never
;; touch the file).

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent-team)
(require 'agent-team-chat)
(require 'agent-team-bridge)
(require 'agent-team-live)

(defvar agent-team-live-test--dir nil
  "Dynamic: the per-test fixture dir (bound by the with-env macro).")

(defvar agent-team-live-test--secret "SECRET-VALUE-XYZ-never-lands")

(defconst agent-team-live-test--members
  "#+TITLE: live test registry
* Senior Emacs Lisp Engineer — glm-5.3@chat.z.ai (seat)
:PROPERTIES:
:TRANSPORT: llm-api
:ENDPOINT: zai/glm-5.3
:AUTH: zai-api-alias
:END:
* Ghost ACP — ghost-acp@acp-host (live session)
:PROPERTIES:
:TRANSPORT: acp
:END:
* Team Lead + DoE — z.ai-agent (relay seat)
:PROPERTIES:
:TRANSPORT: relay
:END:
* Ghost Seat — ghost-seat@nowhere (declared nothing)
")

(defconst agent-team-live-test--chat
  "#+TITLE: CHAT.org live fixture

* MSG lead -> @glm-5.3@chat.z.ai :dispatch:      :msg:lead:glm-5.3@chat.z.ai:dispatch:
:PROPERTIES:
:FROM: lead
:TO: glm-5.3@chat.z.ai
:KIND: dispatch
:WHEN: [2026-11-05 Thu 03:00 UTC]
:END:
  Please review U4 now.
* MSG owner -> @all :note:      :msg:owner:all:note:
:PROPERTIES:
:FROM: owner
:TO: all
:KIND: note
:WHEN: [2026-11-05 Thu 03:05 UTC]
:END:
  Broadcast to every seat at once.
* MSG lead -> @z.ai-agent :note:      :msg:lead:z.ai-agent:note:
:PROPERTIES:
:FROM: lead
:TO: z.ai-agent
:KIND: note
:WHEN: [2026-11-05 Thu 03:10 UTC]
:END:
  Relay lane, outside the bridge engine.
")

(defun agent-team-live-test--setup ()
  "Fresh temp dir with CHAT.org + MEMBERS.org; return it."
  (let ((dir (make-temp-file "live-test" 'dir)))
    (with-temp-file (expand-file-name "MEMBERS.org" dir)
      (insert agent-team-live-test--members))
    (with-temp-file (expand-file-name "CHAT.org" dir)
      (insert agent-team-live-test--chat))
    dir))

(defmacro agent-team-live-test--with-env (acp-seen &rest body)
  "Bind the offline test env; ACP-SEEN is a symbol collecting acp
dispatch records ((id body) ...).  Use `_` when unused."
  (declare (indent 1))
  (let ((stub (if (eq acp-seen '_)
                  `(lambda (_id _body) "acp delivered")
                `(lambda (id body)
                   (push (list id body) ,acp-seen)
                   "acp delivered")))
        (collector (if (eq acp-seen '_) nil `((,acp-seen nil)))))
    `(let ((agent-team-live-test--dir (agent-team-live-test--setup)))
       (let ,collector
         (let ((agent-team-chat-archive-file
                (expand-file-name "CHAT.org" agent-team-live-test--dir))
               (agent-team-chat-members-file
                (expand-file-name "MEMBERS.org" agent-team-live-test--dir))
               (agent-team-bridge-auth-lookup-function
                (lambda (alias)
                  (when (equal alias "zai-api-alias")
                    agent-team-live-test--secret)))
               (agent-team-bridge-http-post-function
                (lambda (_url _headers _payload)
                  "ack from the cloud member"))
               (agent-team-live-acp-dispatch-function ,stub)
               (agent-team-live-interval 3600)
               ;; the send path resolves agent-team--file from the
               ;; current buffer's default-directory — pin it to the
               ;; fixture dir so the ONE sender appends to the fixture
               (agent-team-dir "."))
           (when (get-buffer "*agent-team Live*")
             (kill-buffer "*agent-team Live*"))
           ,@body)))))

(defun agent-team-live-test--open ()
  "Open the live surface on the fixture (no timer wait)."
  (agent-team-live-open)
  (with-current-buffer "*agent-team Live*"
    (setq default-directory
          (file-name-as-directory agent-team-live-test--dir))
    (cancel-timer agent-team-live--timer)
    (setq agent-team-live--timer nil))
  (get-buffer "*agent-team Live*"))

(defun agent-team-live-test--file-text ()
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "CHAT.org" agent-team-live-test--dir))
    (buffer-string)))

(defun agent-team-live-test--append-own ()
  "Append one own message via the ONE sender (the real send law)."
  (agent-team--chat-append-1 "em" "ghost-acp@acp-host" "request"
                             "Dispatch the acp seat please" "unset"
                             "P1" "reads"
                             (expand-file-name "CHAT.org"
                                               agent-team-live-test--dir)))

;;; Build + §4 grammar (design §8.1) ------------------------------------

(ert-deftest agent-team-live-build-grammar ()
  (agent-team-live-test--with-env _
    (let ((buf (agent-team-live-test--open)))
      (unwind-protect
          (with-current-buffer buf
            (should agent-team-live-mode)
            (should buffer-read-only)
            (should (eq buffer-undo-list t))
            (should (string-match-p "^\\* Team chat$" (buffer-string)))
            ;; the kit render's §4 mapping: inactive stamp + author +
            ;; KIND tag; @TO maps through MEMBERS.org (§10.3 link form)
            (should (string-match-p
                     (concat "^\\*\\* \\[2026-11-05 Thu 03:00\\] lead -> "
                             "\\[\\[chat-member:glm-5.3@chat.z.ai\\]"
                             "\\[@glm-5.3@chat.z.ai\\]\\] :dispatch:$")
                     (buffer-string)))
            (should (string-match-p "^:AUTHOR: lead$" (buffer-string)))
            (should (string-match-p "^:MSG-ID: msg-[0-9a-f]\\{8\\}$"
                                    (buffer-string)))
            ;; status panel rides the header line
            (should header-line-format)
            (should (string-match-p "agent-team live:" header-line-format))
            (should (equal agent-team-live--status "ok"))
            (should (= agent-team-live--count 3)))
        (kill-buffer buf)))))

;;; The U1 seam (design §8.2) -------------------------------------------

(ert-deftest agent-team-live-seam-resolves-live-buffer ()
  (agent-team-live-test--with-env _
    (should (null (funcall agent-team-chat-live-buffer-function)))
    (let ((buf (agent-team-live-test--open)))
      (unwind-protect
          (progn
            (should (eq (funcall agent-team-chat-live-buffer-function) buf))
            ;; open resolves to the live surface, never forks the archive
            (agent-team-chat-open)
            (should (eq (current-buffer) buf))
            (should (null (get-buffer "*agent-team Chat*"))))
        (kill-buffer buf)))))

;;; Poll + unread (design §8.3) ------------------------------------------

(ert-deftest agent-team-live-poll-unread-overlay ()
  (agent-team-live-test--with-env _
    (let ((buf (agent-team-live-test--open)))
      (unwind-protect
          (with-current-buffer buf
            (should (null (agent-team-live--unread-overlay)))
            ;; a reader scrolled UP from the tail: arrivals accumulate
            (goto-char (point-min))
            (agent-team-live-test--append-own)
            (should (agent-team-live--render)) ; the tick body, no timer
            (let ((ov (agent-team-live--unread-overlay)))
              (should ov)
              (should (eq (overlay-get ov 'face)
                          'agent-team-chat-unread-face))
              (goto-char (overlay-start ov))
              (should (looking-at "^\\*\\* "))
              (should (string-match-p "ghost-acp@acp-host"
                                      (buffer-substring
                                       (point) (point-max)))))
            ;; reaching the tail marks everything read
            (goto-char (point-max))
            (agent-team-live--mark-read)
            (should (null (agent-team-live--unread-overlay)))
            (should (= agent-team-live--count 4))
            ;; a reader pinned to the tail never accumulates unread
            (goto-char (point-max))
            (agent-team-live-test--append-own)
            (should (agent-team-live--render))
            (should (null (agent-team-live--unread-overlay))))
        (kill-buffer buf)))))

(ert-deftest agent-team-live-jump-unread-lands-first-unread ()
  (agent-team-live-test--with-env _
    (let ((buf (agent-team-live-test--open)))
      (unwind-protect
          (with-current-buffer buf
            (goto-char (point-min))
            (agent-team-live-test--append-own)
            (agent-team-live--render)
            ;; two new messages: j lands on the FIRST unread heading
            (agent-team--chat-append-1 "em" "all" "note" "second new"
                                       "unset" "P1" "reads"
                                       (expand-file-name "CHAT.org"
                                                         agent-team-live-test--dir))
            (agent-team-live--render)
            (agent-team-live-jump-unread)
            ;; the landing point sits ON a message heading start
            (should (looking-at-p "^\\*\\* "))
            (should (string-match-p "ghost-acp@acp-host"
                                    (buffer-substring
                                     (line-beginning-position)
                                     (line-end-position)))))
        (kill-buffer buf)))))

;;; Send = the auto-save append (design §8.4, v1.3) ----------------------

(ert-deftest agent-team-live-send-appends-and-renders ()
  (agent-team-live-test--with-env _
    (let ((buf (agent-team-live-test--open)))
      (unwind-protect
          (with-current-buffer buf
            (agent-team-live-send "em" "z.ai-agent" "note" "hello relay"
                                  "P1" "reads")
            (should (= agent-team-live--count 4))
            (let ((text (agent-team-live-test--file-text)))
              (should (string-match-p "^\\* MSG em -> @z.ai-agent :note:" text))
              (should (string-match-p "hello relay" text))
              ;; the kit render shows it too
              (should (string-match-p "hello relay" (buffer-string)))))
        (kill-buffer buf)))))

;;; Dispatch truth table (design §8.5-8.8, §11) --------------------------

(ert-deftest agent-team-live-dispatch-llm-api-via-engine ()
  (agent-team-live-test--with-env _
    (let ((buf (agent-team-live-test--open)))
      (unwind-protect
          (with-current-buffer buf
            (agent-team-live-send "em" "glm-5.3@chat.z.ai" "dispatch"
                                  "run the gates" "P1" "reads")
            (let* ((result (agent-team-live-dispatch))
                   (text (agent-team-live-test--file-text)))
              ;; the engine ran: reply landed, :queued: dropped
              (should (eq (car result) 'delivered))
              (should (string-match-p "ack from the cloud member" text))
              (should (not (string-match-p ":queued:" text))
                      ))
            ;; the reply is on screen
            (should (string-match-p "ack from the cloud member"
                                    (buffer-string))))
        (kill-buffer buf)))))

(ert-deftest agent-team-live-dispatch-acp-via-seam-no-stamp ()
  (agent-team-live-test--with-env seen
    (let ((buf (agent-team-live-test--open)))
      (unwind-protect
          (with-current-buffer buf
            (agent-team-live-test--append-own)
            (agent-team-live--render t)
            (let* ((result (agent-team-live-dispatch))
                   (text (agent-team-live-test--file-text)))
              (should (eq (car result) 'acp))
              ;; the seam got (ID BODY)
              (should (equal (car seen) '("ghost-acp@acp-host"
                                          "Dispatch the acp seat please")))
              ;; the truth-table law: NO lifecycle stamp on acp
              (should (not (string-match-p ":queued:" text)))
              (should (not (string-match-p ":MEMBER:" text))))
            (should (string-match-p "Dispatch the acp seat please"
                                    (buffer-string))))
        (kill-buffer buf)))))

(ert-deftest agent-team-live-dispatch-relay-is-explicit-noop ()
  (agent-team-live-test--with-env _
    (let ((buf (agent-team-live-test--open)))
      (unwind-protect
          (with-current-buffer buf
            (agent-team-live-send "em" "z.ai-agent" "note" "via the relay"
                                  "P1" "reads")
            (let ((before (agent-team-live-test--file-text))
                  (result (agent-team-live-dispatch)))
              (should (eq (car result) 'relay))
              (should (string-match-p "relay" (cdr result)))
              ;; dispatch never mutated the file on the relay path
              (should (equal (agent-team-live-test--file-text) before))))
        (kill-buffer buf)))))

(ert-deftest agent-team-live-dispatch-broadcast-errors ()
  (agent-team-live-test--with-env _
    (let ((buf (agent-team-live-test--open)))
      (unwind-protect
          (with-current-buffer buf
            (agent-team-live-send "em" "all" "note" "to every seat"
                                  "P1" "reads")
            (should-error (agent-team-live-dispatch) :type 'user-error))
        (kill-buffer buf)))))

(ert-deftest agent-team-live-dispatch-undeclared-errors ()
  (agent-team-live-test--with-env _
    (let ((buf (agent-team-live-test--open)))
      (unwind-protect
          (with-current-buffer buf
            (agent-team-live-send "em" "ghost-seat@nowhere" "request" "?"
                                  "P1" "reads")
            (should-error (agent-team-live-dispatch) :type 'user-error))
        (kill-buffer buf)))))

(ert-deftest agent-team-live-dispatch-needs-the-bridge ()
  (agent-team-live-test--with-env _
    (let ((buf (agent-team-live-test--open)))
      (unwind-protect
          (cl-letf (((symbol-function 'agent-team-live--bridge-p)
                     (lambda () nil)))
            (with-current-buffer buf
              (should-error (agent-team-live-dispatch)
                            :type 'user-error)))
        (kill-buffer buf)))))

(ert-deftest agent-team-live-dispatch-no-acp-seam-errors ()
  (agent-team-live-test--with-env _
    (let ((buf (agent-team-live-test--open))
          (agent-team-live-acp-dispatch-function nil))
      (unwind-protect
          (with-current-buffer buf
            (agent-team-live-test--append-own)
            (agent-team-live--render t)
            (should-error (agent-team-live-dispatch) :type 'user-error))
        (kill-buffer buf)))))

;;; Hygiene (§8, design §8.9) --------------------------------------------

(ert-deftest agent-team-live-render-string-property-free ()
  (agent-team-live-test--with-env _
    (with-temp-buffer
      (insert (agent-team-chat--render-string
               (agent-team-live-test--file-text)))
      (should (null (text-properties-at (point-min))))
      (goto-char (point-min))
      (while (not (eobp))
        (should (null (text-properties-at (point))))
        (forward-char 1)))))

(ert-deftest agent-team-live-bury-and-kill-never-touch-the-file ()
  (agent-team-live-test--with-env _
    (let* ((file (expand-file-name "CHAT.org" agent-team-live-test--dir))
           (before (with-temp-buffer
                     (insert-file-contents file)
                     (buffer-string)))
           (buf (agent-team-live-test--open)))
      (unwind-protect
          (with-current-buffer buf (agent-team-live-bury))
        (should (equal (agent-team-live-test--file-text) before))
        (kill-buffer buf)
        (should (equal (agent-team-live-test--file-text) before))))))

(ert-deftest agent-team-live-missing-file-renders-waiting ()
  (agent-team-live-test--with-env _
    (let* ((agent-team-chat-archive-file
            (expand-file-name "absent.org" agent-team-live-test--dir))
           (buf (agent-team-live-test--open)))
      (unwind-protect
          (with-current-buffer buf
            (should (string-match-p "waiting" agent-team-live--status))
            (should (string-match-p "^\\* Team chat$" (buffer-string))))
        (kill-buffer buf)))))

(provide 'agent-team-live-test)
;;; agent-team-live-test.el ends here
