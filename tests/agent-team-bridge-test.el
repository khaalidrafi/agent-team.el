;;; agent-team-bridge-test.el --- U3 §11 bridge ERT suite (offline) -*- lexical-binding: t; -*-

;;; Commentary:

;; §9.9 fixture law: offline, deterministic, NO NETWORK.  Fixture files
;; are generated into a fresh temp dir per test (the registry grammar
;; needs absolute :PERSONA: paths, which a static file cannot carry);
;; the http/auth seams are stubbed, so no provider is ever contacted.
;; Assertions: registry parse, addressing + the §11.5 loop-law truth
;; table, queue stamping (tags + MEMBER/CHANNEL drawers), reply landing
;; through the append path, err lifecycle + retry, privacy refusal, hop
;; budget, transcript tail, endpoint resolution, and the §9.10 secret
;; law (the alias appears in the file, the secret value never does).

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent-team)
(require 'agent-team-chat)
(require 'agent-team-bridge)

(defvar agent-team-bridge-test--dir nil
  "Dynamic: the per-test fixture dir (bound by the with-env macro).")

(defvar agent-team-bridge-test--secret "SECRET-VALUE-XYZ-never-lands")

(defconst agent-team-bridge-test--members
  "#+TITLE: bridge test registry
* Senior Emacs Lisp Engineer — glm-5.3@chat.z.ai (seat)
:PROPERTIES:
:TRANSPORT: llm-api
:ENDPOINT: zai/glm-5.3
:AUTH: zai-api-alias
:PERSONA: %s
:END:
* Team Lead + DoE — z.ai-agent (relay seat)
:PROPERTIES:
:TRANSPORT: relay
:END:
* Ghost Seat — ghost-seat@nowhere (declared nothing)
* Training Lane — trainer@training-host (privacy law)
:PROPERTIES:
:TRANSPORT: llm-api
:ENDPOINT: train/model
:AUTH: train-alias
:PRIVACY: training
:END:
")

(defconst agent-team-bridge-test--chat
  "#+TITLE: CHAT.org bridge fixture

* MSG lead -> @glm-5.3@chat.z.ai :dispatch:      :msg:lead:glm-5.3@chat.z.ai:dispatch:
:PROPERTIES:
:FROM: lead
:TO: glm-5.3@chat.z.ai
:KIND: dispatch
:WHEN: [2026-11-05 Thu 03:00 UTC]
:END:
  Please review U3 now.
* MSG owner -> @all :note:      :msg:owner:all:note:
:PROPERTIES:
:FROM: owner
:TO: all
:KIND: note
:WHEN: [2026-11-05 Thu 03:05 UTC]
:END:
  Broadcast to every seat at once.
* MSG qa -> @ghost-seat@nowhere :request:      :msg:qa:ghost-seat@nowhere:request:
:PROPERTIES:
:FROM: qa
:TO: ghost-seat@nowhere
:KIND: request
:WHEN: [2026-11-05 Thu 03:10 UTC]
:END:
  This seat declared no transport.
* MSG lead -> @trainer@training-host :note:      :msg:lead:trainer@training-host:note:
:PROPERTIES:
:FROM: lead
:TO: trainer@training-host
:KIND: note
:WHEN: [2026-11-05 Thu 03:15 UTC]
:END:
  This lane trains on prompts.
* MSG lead -> @z.ai-agent :note:      :msg:lead:z.ai-agent:note:
:PROPERTIES:
:FROM: lead
:TO: z.ai-agent
:KIND: note
:WHEN: [2026-11-05 Thu 03:20 UTC]
:END:
  Relay lane, outside the bridge engine.
* MSG qa -> @lead :note:      :msg:qa:lead:note:
:PROPERTIES:
:FROM: qa
:TO: lead
:KIND: note
:WHEN: [2026-11-05 Thu 03:25 UTC]
:END:
  Body link addressing: [[chat-member:glm-5.3@chat.z.ai][@glm-5.3@chat.z.ai]] please ack.
")

(defconst agent-team-bridge-test--persona
  "You are the Senior Emacs Lisp Engineer seat.  Be terse, cite lines.")

(defun agent-team-bridge-test--setup ()
  "Fresh temp dir with CHAT.org, MEMBERS.org, persona.org; return it."
  (let ((dir (make-temp-file "bridge-test" 'dir)))
    (with-temp-file (expand-file-name "persona.org" dir)
      (insert agent-team-bridge-test--persona))
    (with-temp-file (expand-file-name "MEMBERS.org" dir)
      (insert (format agent-team-bridge-test--members
                      (expand-file-name "persona.org" dir))))
    (with-temp-file (expand-file-name "CHAT.org" dir)
      (insert agent-team-bridge-test--chat))
    dir))

(defmacro agent-team-bridge-test--with-env (calls &rest body)
  "Bind the full offline test env; CALLS is a symbol collecting
http-call records (url headers payload).  Use `_` when unused."
  (declare (indent 1))
  (let ((stub (if (eq calls '_)
                  `(lambda (_url _headers _payload)
                     "ack from the cloud member")
                `(lambda (url headers payload)
                   (push (list url headers payload) ,calls)
                   "ack from the cloud member")))
        (collector (if (eq calls '_) nil `((,calls nil)))))
    `(let ((agent-team-bridge-test--dir (agent-team-bridge-test--setup)))
       (let ,collector
         (let ((agent-team-chat-archive-file
                (expand-file-name "CHAT.org" agent-team-bridge-test--dir))
               (agent-team-chat-members-file
                (expand-file-name "MEMBERS.org" agent-team-bridge-test--dir))
               (agent-team-bridge-auth-lookup-function
                (lambda (alias)
                  (when (equal alias "zai-api-alias")
                    agent-team-bridge-test--secret)))
               (agent-team-bridge-http-post-function ,stub))
           ,@body)))))

(defun agent-team-bridge-test--file-text ()
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "CHAT.org" agent-team-bridge-test--dir))
    (buffer-string)))

;;; Registry (§11.1) ---------------------------------------------------

(ert-deftest agent-team-bridge-registry-parse ()
  (agent-team-bridge-test--with-env _
    (let ((reg (agent-team-bridge--registry)))
      (should (= (length reg) 4))
      (let ((senior (agent-team-bridge--member "glm-5.3@chat.z.ai" reg)))
        (should senior)
        (should (equal (plist-get senior :transport) "llm-api"))
        (should (equal (plist-get senior :endpoint) "zai/glm-5.3"))
        (should (equal (plist-get senior :auth) "zai-api-alias"))
        (should (equal (plist-get senior :persona)
                       (expand-file-name "persona.org"
                                         agent-team-bridge-test--dir)))
        (should (string-match-p "Senior Emacs Lisp Engineer"
                                (plist-get senior :role))))
      (should (equal (plist-get
                      (agent-team-bridge--member "z.ai-agent" reg)
                      :transport)
                     "relay"))
      (should (null (plist-get
                     (agent-team-bridge--member "ghost-seat@nowhere" reg)
                     :transport)))
      (should (equal (plist-get
                      (agent-team-bridge--member "trainer@training-host" reg)
                      :privacy)
                     "training")))))

;;; Addressing + loop law (§11.2 + §11.5) ------------------------------

(ert-deftest agent-team-bridge-addressing ()
  (agent-team-bridge-test--with-env _
    (let* ((reg (agent-team-bridge--registry))
           (msgs (agent-team-chat--parse-messages
                  (agent-team-bridge-test--file-text))))
      ;; TO drawer match
      (should (equal (plist-get (agent-team-bridge--addressed-member
                                 (nth 0 msgs) reg) :id)
                     "glm-5.3@chat.z.ai"))
      ;; TO = all never addresses a member (§11.2)
      (should (null (agent-team-bridge--addressed-member (nth 1 msgs) reg)))
      ;; body chat-member: link addresses (§11.2)
      (should (equal (plist-get (agent-team-bridge--addressed-member
                                 (nth 5 msgs) reg) :id)
                     "glm-5.3@chat.z.ai")))))

(ert-deftest agent-team-bridge-loop-law-truth-table ()
  (agent-team-bridge-test--with-env _
    (let* ((reg (agent-team-bridge--registry))
           (msgs (agent-team-chat--parse-messages
                  (agent-team-bridge-test--file-text))))
      ;; lead -> llm-api member: dispatchable
      (let ((v (agent-team-bridge--eligible-p (nth 0 msgs) reg nil t)))
        (should v) (should (null (cdr v))))
      ;; owner -> all: not bridge business
      (should (null (agent-team-bridge--eligible-p (nth 1 msgs) reg nil t)))
      ;; qa -> seat without :TRANSPORT:: refused, never silent (§11.6)
      (let ((v (agent-team-bridge--eligible-p (nth 2 msgs) reg nil t)))
        (should v)
        (should (string-match-p "no :TRANSPORT:" (cdr v))))
      ;; training lane: privacy refusal (§11.7)
      (let ((v (agent-team-bridge--eligible-p (nth 3 msgs) reg nil t)))
        (should v)
        (should (string-match-p "privacy law §11.7" (cdr v))))
      ;; relay seat: live-surface transport, outside the engine
      (should (null (agent-team-bridge--eligible-p
                     (nth 4 msgs) reg nil t)))
      ;; member reply with autopilot off: loop law stops it (§11.5)
      (let ((reply (list :heading "* MSG glm-5.3@chat.z.ai -> @ghost :note:"
                         :props '(("FROM" . "glm-5.3@chat.z.ai")
                                  ("TO" . "ghost-seat@nowhere"))
                         :body "  done")))
        (should (null (agent-team-bridge--eligible-p reply reg nil t)))
        ;; with autopilot on + a different target: allowed
        (should (agent-team-bridge--eligible-p reply reg t t))
        ;; but never to itself
        (let ((self (list :heading "* MSG glm-5.3@chat.z.ai -> @self :note:"
                          :props '(("FROM" . "glm-5.3@chat.z.ai")
                                   ("TO" . "glm-5.3@chat.z.ai"))
                          :body "  loop")))
          (should (null (agent-team-bridge--eligible-p
                         self reg t t))))))))

(ert-deftest agent-team-bridge-hop-budget ()
  (agent-team-bridge-test--with-env _
    (let* ((reg (agent-team-bridge--registry))
           (m1 (list :heading "* MSG m1"
                     :props '(("FROM" . "glm-5.3@chat.z.ai"))
                     :body "")))
      ;; five consecutive member replies: over the default budget of 4
      (should-not (agent-team-bridge--hop-budget-p
                   (list m1 m1 m1 m1 m1) 4
                   agent-team-bridge-max-hops reg))
      ;; four: within budget
      (should (agent-team-bridge--hop-budget-p
               (list m1 m1 m1 m1) 3 agent-team-bridge-max-hops reg)))))

;;; Lifecycle (§11.3 + §11.6) -------------------------------------------

(ert-deftest agent-team-bridge-tick-dispatches-and-lands-replies ()
  (agent-team-bridge-test--with-env calls
    (let ((n (agent-team-bridge-tick)))
      ;; four lifecycle events: msg0 + msg5 delivered (2 http calls),
      ;; msg2 (no transport) + msg3 (privacy) err-stamped loudly;
      ;; broadcast (msg1) and relay (msg4) untouched
      (should (= n 4))
      (should (= (length calls) 2))
      ;; the call carried the resolved secret in memory; the secret
      ;; value never enters the file (§9.10) — only the alias does
      (should (string-match-p "Bearer SECRET-VALUE-XYZ"
                              (prin1-to-string calls)))
      (should-not (string-match-p "SECRET-VALUE-XYZ"
                                  (agent-team-bridge-test--file-text)))
      ;; the alias (never the value) lives in the MEMBERS registry
      (should (string-match-p
               "zai-api-alias"
               (with-temp-buffer
                 (insert-file-contents
                  (expand-file-name "MEMBERS.org"
                                    agent-team-bridge-test--dir))
                 (buffer-string))))
      (let* ((text (agent-team-bridge-test--file-text))
             (msgs (agent-team-chat--parse-messages text)))
        ;; replies landed at EOF: FROM = member id, TO = sender, KIND note
        (should (= (length msgs) 8))
        (let ((r1 (nth 6 msgs)) (r2 (nth 7 msgs)))
          (should (equal (agent-team-chat--prop (plist-get r1 :props)
                                                "FROM")
                         "glm-5.3@chat.z.ai"))
          (should (equal (agent-team-chat--prop (plist-get r1 :props)
                                                "TO")
                         "lead"))
          (should (equal (agent-team-chat--prop (plist-get r1 :props)
                                                "KIND")
                         "note"))
          (should (string-match-p "ack from the cloud member"
                                  (plist-get r1 :body)))
          (should (equal (agent-team-chat--prop (plist-get r2 :props)
                                                "FROM")
                         "glm-5.3@chat.z.ai")))
        ;; queue stamping: MEMBER/CHANNEL drawers, tag dropped on
        ;; success (§9.11, §11.3)
        (should (equal (agent-team-chat--prop (plist-get (nth 0 msgs)
                                                         :props)
                                              "MEMBER")
                       "glm-5.3@chat.z.ai"))
        (should (equal (agent-team-chat--prop (plist-get (nth 0 msgs)
                                                         :props)
                                              "CHANNEL")
                       "bridge"))
        (should-not (string-match-p ":queued:"
                                    (plist-get (nth 0 msgs) :heading)))
        (should-not (string-match-p ":err:"
                                    (plist-get (nth 0 msgs) :heading)))
        ;; broadcast and relay carry no lifecycle stamps; ghost +
        ;; trainer carry :err: with their reasons (§11.6)
        (should (null (agent-team-chat--prop (plist-get (nth 1 msgs)
                                                        :props)
                                             "MEMBER")))
        (should (null (agent-team-chat--prop (plist-get (nth 4 msgs)
                                                        :props)
                                             "MEMBER")))
        (should (string-match-p ":err:"
                                (plist-get (nth 2 msgs) :heading)))
        (should (string-match-p "no :TRANSPORT:"
                                (plist-get (nth 2 msgs) :body)))
        (should (string-match-p "privacy law §11.7"
                                (plist-get (nth 3 msgs) :body)))
        ;; the prompt rode persona + team law + file transcript
        (let ((payload (nth 2 (car calls))))
          (should (string-match-p "lead -> @glm-5.3@chat.z.ai" payload))
          (should (string-match-p "Please review U3 now" payload))
          (should (string-match-p "You are a member of the agent-team"
                                  payload))
          (should (string-match-p "Senior Emacs Lisp Engineer seat"
                                  payload)))))))

(ert-deftest agent-team-bridge-failure-retags-err ()
  (agent-team-bridge-test--with-env _
    (let ((agent-team-bridge-http-post-function
           (lambda (&rest _) (error "simulated HTTP 500 from provider"))))
      (condition-case nil (agent-team-bridge-tick) (error nil)))
    (let* ((text (agent-team-bridge-test--file-text))
           (msgs (agent-team-chat--parse-messages text)))
      (should (= (length msgs) 6))          ; no reply appended
      (should (string-match-p ":err:"
                              (plist-get (nth 0 msgs) :heading)))
      (should (string-match-p "BRIDGE-ERR: simulated HTTP 500"
                              (plist-get (nth 0 msgs) :body)))
      ;; retry with the provider back: re-queue + deliver (§11.6)
      (let ((agent-team-bridge-http-post-function
             (lambda (&rest _) "back online")))
        (agent-team-bridge-retry))
      (let* ((text2 (agent-team-bridge-test--file-text))
             (msgs2 (agent-team-chat--parse-messages text2)))
        (should (= (length msgs2) 7))
        (should-not (string-match-p ":queued:"
                                    (plist-get (nth 0 msgs2) :heading)))
        ;; audit trail: the earlier BRIDGE-ERR line stays
        (should (string-match-p "BRIDGE-ERR: simulated HTTP 500"
                                (plist-get (nth 0 msgs2) :body)))
        (should (string-match-p "back online"
                                (plist-get (nth 6 msgs2) :body)))))))

(ert-deftest agent-team-bridge-privacy-refusal-makes-no-call ()
  (agent-team-bridge-test--with-env calls
    (condition-case nil (agent-team-bridge-tick) (error nil))
    (let* ((text (agent-team-bridge-test--file-text))
           (msgs (agent-team-chat--parse-messages text)))
      ;; the trainer message: err with the privacy reason, zero calls
      (should (string-match-p ":err:"
                              (plist-get (nth 3 msgs) :heading)))
      (should (string-match-p "privacy law §11.7"
                              (plist-get (nth 3 msgs) :body)))
      (dolist (c calls)
        (should-not (string-match-p "train/model" (car c)))))))

(ert-deftest agent-team-bridge-ghost-seat-err-no-silent-drop ()
  (agent-team-bridge-test--with-env _
    (condition-case nil (agent-team-bridge-tick) (error nil))
    (let* ((text (agent-team-bridge-test--file-text))
           (msgs (agent-team-chat--parse-messages text)))
      (should (string-match-p ":err:"
                              (plist-get (nth 2 msgs) :heading)))
      (should (string-match-p "no :TRANSPORT:"
                              (plist-get (nth 2 msgs) :body)))
      ;; the relay message stays completely untouched
      (should-not (string-match-p ":queued:\\|:err:"
                                  (plist-get (nth 4 msgs) :heading)))
      (should (null (agent-team-chat--prop (plist-get (nth 4 msgs)
                                                      :props)
                                           "MEMBER"))))))

;;; Transport details (§11.3) -------------------------------------------

(ert-deftest agent-team-bridge-transcript-tail ()
  (let* ((tail (agent-team-bridge--transcript-tail
                agent-team-bridge-test--chat 2)))
    (should (= (length (split-string tail "\n")) 2))
    (should (string-match-p "lead -> @z.ai-agent (note):" tail))
    (should (string-match-p "qa -> @lead (note):" tail))
    ;; author-labeled, oldest of the tail first, newest last
    (should (< (string-match-p "lead -> @z.ai-agent" tail)
               (string-match-p "qa -> @lead" tail)))))

(ert-deftest agent-team-bridge-endpoint-url ()
  (let ((member (list :id "x" :endpoint "zai/glm-5.3")))
    (should (equal (agent-team-bridge--endpoint-url member)
                   "https://api.z.ai/api/paas/v4/chat/completions"))
    (should (equal (agent-team-bridge--endpoint-model member) "glm-5.3")))
  (let ((member (list :id "x" :endpoint "https://api.example.com/v1/")))
    (should (equal (agent-team-bridge--endpoint-url member)
                   "https://api.example.com/v1/chat/completions"))))

(ert-deftest agent-team-bridge-persona-missing-fails-loud ()
  (agent-team-bridge-test--with-env _
    (let ((senior (agent-team-bridge--member
                   "glm-5.3@chat.z.ai"
                   (agent-team-bridge--registry))))
      ;; a declared persona that is gone is a config defect, not a
      ;; silent empty prompt
      (should-error (agent-team-bridge--system-prompt
                     (list :id "x" :persona "/nonexistent/persona.org")))
      ;; the fixture persona exists and rides the system prompt
      (should (string-match-p "Senior Emacs Lisp Engineer seat"
                              (agent-team-bridge--system-prompt senior)))
      (should (string-match-p "You are a member of the agent-team"
                              (agent-team-bridge--system-prompt senior))))))

(ert-deftest agent-team-bridge-autopilot-keyword ()
  (agent-team-bridge-test--with-env _
    (should-not (agent-team-bridge--autopilot-p
                 (expand-file-name "CHAT.org"
                                   agent-team-bridge-test--dir)))
    (let ((auto (expand-file-name "AUTO.org" agent-team-bridge-test--dir)))
      (with-temp-file auto
        (insert "#+AUTOPILOT: t\n"))
      (should (agent-team-bridge--autopilot-p auto)))))

(ert-deftest agent-team-bridge-retry-without-err-signals ()
  (agent-team-bridge-test--with-env _
    (should-error (agent-team-bridge-retry))))

(provide 'agent-team-bridge-test)
;;; agent-team-bridge-test.el ends here
