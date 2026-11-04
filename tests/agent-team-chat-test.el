;;; agent-team-chat-test.el --- U1 archive-reader ERT suite (offline) -*- lexical-binding: t; -*-

;;; Commentary:

;; §9.9 fixture law (docs/CHAT-KIT-ADAPTATION.org, binding): offline,
;; deterministic, no network.  Fixtures: tests/fixtures/chat-fixture.org
;; (4 synthetic messages: dispatch, escalation with mention + URL,
;; telegram note with +03 zone, legacy entry without :WHEN:) and
;; tests/fixtures/members-fixture.org (two-seat subset).  Assertions:
;; the §10.2 mapping per row, KIND tags, AUTHOR/TO/CHANNEL/MSG-ID
;; drawer fields, inactive-stamp grammar (agenda never fires), URL
;; linkification, zero text-property intervals in the render, re-render
;; idempotence, q bury leaves the file untouched.

;;; Code:

(require 'ert)
(require 'agent-team)
(require 'agent-team-chat)

(defvar agent-team-chat-test--dir
  (file-name-as-directory
   (expand-file-name "fixtures"
                     (file-name-directory
                      (or load-file-name default-directory))))
  "Directory of the §9.9 fixtures (resolved from this file's location).")

(defconst agent-team-chat-test--chat
  (expand-file-name "chat-fixture.org" agent-team-chat-test--dir))
(defconst agent-team-chat-test--members
  (expand-file-name "members-fixture.org" agent-team-chat-test--dir))

(defmacro agent-team-chat-test--with-render (&rest body)
  "Run BODY with the fixture render in `rendered' (no faces, no file writes)."
  `(let ((agent-team-chat-members-file agent-team-chat-test--members)
         (rendered (agent-team-chat--render-string
                    (with-temp-buffer
                      (insert-file-contents agent-team-chat-test--chat)
                      (buffer-string)))))
     ,@body))

(ert-deftest agent-team-chat-test/render-header-and-drawer ()
  (agent-team-chat-test--with-render
   (should (string-prefix-p "#+STARTUP: overview\n" rendered))
   (should (string-match "^\\* Team chat$" rendered))
   (should (string-match ":CHAT-ID: agent-team/CHAT\\.org" rendered))
   (should (string-match "^:KIND: group$" rendered))))

(ert-deftest agent-team-chat-test/mapping-level2-headings ()
  (agent-team-chat-test--with-render
   ;; Row 1: WHEN → inactive stamp; FROM → author; KIND → tag.
   (should (string-match
            "^\\*\\* \\[2026-11-04 Tue 09:15\\] lead -> .* :dispatch:$"
            rendered))
   ;; Row 2: escalation with its kind tag.
   (should (string-match
            "^\\*\\* \\[2026-11-04 Tue 11:42\\] qa -> .* :escalation:$"
            rendered))
   ;; Row 3: telegram note, zone suffix stripped from the stamp.
   (should (string-match
            "^\\*\\* \\[2026-11-04 Tue 12:07\\] owner -> .* :note:$"
            rendered))))

(ert-deftest agent-team-chat-test/mapping-to-member-link ()
  (agent-team-chat-test--with-render
   ;; TO = glm-5.3@chat.z.ai is a known MEMBERS id → chat-member: link.
   (should (string-match
            "lead -> \\[\\[chat-member:glm-5\\.3@chat\\.z\\.ai\\]\\[@glm-5\\.3@chat\\.z\\.ai\\]\\] :dispatch:"
            rendered))
   ;; TO = lead is an informal handle, not a MEMBERS id → plain text.
   (should (string-match "qa -> @lead :escalation:" rendered))
   ;; TO = all is a broadcast (§11.2) → never a member link.
   (should (string-match "lead -> @all :note:$" rendered))))

(ert-deftest agent-team-chat-test/drawer-fields ()
  (agent-team-chat-test--with-render
   (should (string-match ":AUTHOR: lead\n" rendered))
   (should (string-match ":TO: glm-5\\.3@chat\\.z\.ai\n" rendered))
   ;; CHANNEL property (§5 addition) survives for the telegram entry.
   (should (string-match ":CHANNEL: telegram\n" rendered))
   ;; Zone moves to WHEN-ZONE: (named zone and numeric offset both).
   (should (string-match ":WHEN-ZONE: UTC\n" rendered))
   (should (string-match ":WHEN-ZONE: \\+03\n" rendered))))

(ert-deftest agent-team-chat-test/derived-msg-id-law ()
  (agent-team-chat-test--with-render
   ;; Deterministic derived id for a stamped entry: recompute expected.
   (let* ((expected-1 (concat "msg-"
                              (substring
                               (secure-hash
                                'sha1
                                (concat "lead" "\0"
                                        "[2026-11-04 Tue 09:15 UTC]" "\0"
                                        (agent-team-chat--body-80
                                         "Unit U1 is yours: CHAT.org reader, standard v1.1 section 10 kit.\nDesign is binding — docs/CHAT-KIT-ADAPTATION.org in agent-org.")))
                               0 8)))
          (expected-4 "msg-legacy-004"))
     (should (string-match (regexp-quote
                            (format ":MSG-ID: %s" expected-1))
                           rendered))
     ;; Legacy entry (no :WHEN:) degrades to the positional id.
     (should (string-match (regexp-quote
                            (format ":MSG-ID: %s" expected-4))
                           rendered))
     ;; ids differ per message (no cross-message bleed).
     (should-not (string-match
                  (concat ":MSG-ID: " expected-1 "\n\\(?:.+\n\\)*?:MSG-ID: "
                          expected-1 "\n")
                  rendered)))))

(ert-deftest agent-team-chat-test/inactive-stamp-agenda-safe ()
  (agent-team-chat-test--with-render
   ;; §4 rule 2: agenda must never fire — inactive brackets only, and
   ;; the zone suffix never rides the stamp.
   (should-not (string-match "<2026-" rendered))
   (should-not (string-match "\\[2026-11-04 Tue 09:15 UTC\\]" rendered))
   (should (string-match "\\[2026-11-04 Tue 09:15\\]" rendered))))

(ert-deftest agent-team-chat-test/url-linkification ()
  (agent-team-chat-test--with-render
   (should (string-match
            "\\[\\[https://example\\.invalid/runs/42\\]\\]" rendered))
   ;; the URL is not double-bracketed
   (should-not (string-match "\\[\\[\\[https://" rendered))))

(ert-deftest agent-team-chat-test/mention-linkification ()
  (agent-team-chat-test--with-render
   ;; @unknown-seat is not a MEMBERS id → plain text (never break).
   (should (string-match "cc @unknown-seat" rendered))))

(ert-deftest agent-team-chat-test/body-paragraphs-kept ()
  (agent-team-chat-test--with-render
   ;; two body lines of msg 1 survive as a two-line paragraph
   (should (string-match
            "Unit U1 is yours: CHAT\\.org reader, standard v1\\.1 section 10 kit\.\nDesign is binding"
            rendered))
   ;; the two-space chat indent is gone
   (should-not (string-match "\n  Unit U1" rendered))))

(ert-deftest agent-team-chat-test/zero-text-properties ()
  (agent-team-chat-test--with-render
   (should (equal (text-properties-at 0 rendered) nil))
   (let ((props nil))
     (dotimes (i (length rendered))
       (when (text-properties-at i rendered)
         (setq props t)))
     (should-not props))))

(ert-deftest agent-team-chat-test/re-render-idempotence ()
  (let ((agent-team-chat-members-file agent-team-chat-test--members)
        (text (with-temp-buffer
                (insert-file-contents agent-team-chat-test--chat)
                (buffer-string))))
    (should (equal (agent-team-chat--render-string text)
                   (agent-team-chat--render-string text)))))

(ert-deftest agent-team-chat-test/open-builds-and-never-writes ()
  (let* ((agent-team-chat-members-file agent-team-chat-test--members)
         (agent-team-chat-archive-file agent-team-chat-test--chat)
         (agent-team-chat-live-buffer-function nil)
         (sum-before (with-temp-buffer
                       (insert-file-contents agent-team-chat-test--chat)
                       (secure-hash 'sha1 (buffer-string))))
         (buf (progn (agent-team-chat-open)
                     (get-buffer "*agent-team Chat*")))
         (sum-after (with-temp-buffer
                      (insert-file-contents agent-team-chat-test--chat)
                      (secure-hash 'sha1 (buffer-string)))))
    (unwind-protect
        (progn
          (should (buffer-live-p buf))
          (with-current-buffer buf
            (should buffer-read-only)
            (should agent-team-chat-archive-mode)
            (should (string-match "^\\* Team chat$" (buffer-string)))
            ;; §8: undo disabled on the render buffer
            (should (eq buffer-undo-list t))))
      ;; §8: q buries; the file is byte-identical after open + bury.
      (with-current-buffer buf (agent-team-chat-archive-bury))
      (should (equal sum-before sum-after))
      (let ((kill-buffer-query-functions nil))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest agent-team-chat-test/open-prefers-live-session ()
  ;; Data-flow law v1.3: when the live seam supplies a buffer, open
  ;; switches to it and NEVER builds the render.
  (let* ((agent-team-chat-archive-file "/nonexistent/CHAT.org")
         (live (get-buffer-create "*live session stub*"))
         (agent-team-chat-live-buffer-function (lambda () live)))
    (unwind-protect
        (progn
          (agent-team-chat-open)
          (should (eq (current-buffer) live))
          (should-not (get-buffer "*agent-team Chat*")))
      (and (buffer-live-p live) (kill-buffer live)))))

(ert-deftest agent-team-chat-test/open-switches-to-file-visitor ()
  ;; Step 2 of the resolve law: a buffer already visiting the file is
  ;; the live raw session — switch to it, do not fork state.
  (let* ((agent-team-chat-live-buffer-function nil)
         (agent-team-chat-archive-file agent-team-chat-test--chat)
         (visitor (progn
                    (find-file-noselect agent-team-chat-test--chat))))
    (unwind-protect
        (progn
          (agent-team-chat-open)
          (should (eq (current-buffer) visitor))
          (should-not (get-buffer "*agent-team Chat*")))
      (and (buffer-live-p visitor) (kill-buffer visitor)))))

(ert-deftest agent-team-chat-test/refresh-rebuilds-and-keeps-file ()
  (let* ((agent-team-chat-members-file agent-team-chat-test--members)
         (agent-team-chat-archive-file agent-team-chat-test--chat)
         (agent-team-chat-live-buffer-function nil)
         (sum-before (with-temp-buffer
                       (insert-file-contents agent-team-chat-test--chat)
                       (secure-hash 'sha1 (buffer-string)))))
    (unwind-protect
        (progn
          (agent-team-chat-open)
          (with-current-buffer "*agent-team Chat*"
            (let ((inhibit-read-only t)) (erase-buffer))
            (agent-team-chat-archive-refresh)
            (should (string-match "^\\* Team chat$" (buffer-string))))
          (should (equal sum-before
                         (with-temp-buffer
                           (insert-file-contents agent-team-chat-test--chat)
                           (secure-hash 'sha1 (buffer-string))))))
      (let ((kill-buffer-query-functions nil))
        (when (get-buffer "*agent-team Chat*")
          (kill-buffer "*agent-team Chat*"))))))

(ert-deftest agent-team-chat-test/member-ids-scan ()
  (let ((agent-team-chat-members-file agent-team-chat-test--members))
    (let ((ids (agent-team-chat--member-ids)))
      (should (member "glm-5.3@chat.z.ai" ids))
      (should (member "z.ai-agent" ids))
      (should (member "nvidia/nemotron-3.5-lightning:free@cline" ids)))))

(provide 'agent-team-chat-test)
;;; agent-team-chat-test.el ends here

;; ---- U2 additions (A5): verbs, follows, touch ----

;; ---- U2 additions (A5): verbs, follows, touch ----

(ert-deftest agent-team-chat-test/jump-latest ()
  "U2 A5: verb j lands point on the newest message heading."
  (let ((agent-team-chat-archive-file agent-team-chat-test--chat)
        (agent-team-chat-live-buffer-function nil))
    (unwind-protect
        (progn
          (agent-team-chat-open)
          (with-current-buffer "*agent-team Chat*"
            (goto-char (point-min))
            (agent-team-chat-jump-latest)
            (org-back-to-heading t)
            ;; last fixture entry is the legacy one: no stamp
            (should (looking-at "^\\*\\* lead -> @all :note:"))
            (should (lookup-key agent-team-chat-archive-mode-map "j"))))
      (when (get-buffer "*agent-team Chat*")
        (let ((kill-buffer-query-functions nil))
          (kill-buffer "*agent-team Chat*"))))))

(ert-deftest agent-team-chat-test/chat-member-follow ()
  "U2 A5: chat-member follow errors on unknown, resolves a known id."
  (let ((agent-team-chat-members-file agent-team-chat-test--members))
    (should-error (agent-team-chat-visit-member "unknown-id")
                  :type 'user-error)
    (unwind-protect
        (progn
          (agent-team-chat-visit-member "z.ai-agent")
          (with-current-buffer
              (find-buffer-visiting agent-team-chat-test--members)
            (should (save-excursion
                      (beginning-of-line)
                      (looking-at-p "^\\* .*z\\.ai-agent")))))
      (when (get-buffer "*MEMBERS.org*")
        (let ((kill-buffer-query-functions nil))
          (kill-buffer "*MEMBERS.org*"))))))

(ert-deftest agent-team-chat-test/chat-msg-follow ()
  "U2 A5: chat-msg follow jumps to the heading carrying the MSG-ID."
  (let ((agent-team-chat-archive-file agent-team-chat-test--chat)
        (agent-team-chat-live-buffer-function nil))
    (unwind-protect
        (progn
          (agent-team-chat-open)
          (with-current-buffer "*agent-team Chat*"
            (goto-char (point-min))
            (should (re-search-forward "^:MSG-ID: \\(msg-.+\\)$" nil t))
            (let ((id (match-string 1)))
              (goto-char (point-min))
              (agent-team-chat-goto-msg id)
              (org-back-to-heading t)
              (should (string-prefix-p
                       "** " (buffer-substring
                              (point) (line-end-position)))))
            (should-error (agent-team-chat-goto-msg "msg-nope")
                          :type 'user-error)))
      (when (get-buffer "*agent-team Chat*")
        (let ((kill-buffer-query-functions nil))
          (kill-buffer "*agent-team Chat*"))))))

(ert-deftest agent-team-chat-test/touch-device-predicate ()
  "U2 A5: touch predicate responds to the terminal touch-screen parameter."
  (let ((original-param (terminal-parameter nil 'touch-screen)))
    (unwind-protect
        (progn
          (set-terminal-parameter nil 'touch-screen t)
          (should (agent-team-chat--touch-device-p)))
      (set-terminal-parameter nil 'touch-screen original-param))))

(provide 'agent-team-chat-test)
;;; agent-team-chat-test.el ends here
