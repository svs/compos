;;; lsp-test.scm --- the LSP client, against a server the editor ships with.
;;;
;;; No fake server and no temp project: the registry already names real
;;; servers, and one of them starts here. What a real server proves is the
;;; plumbing — the registry, the attach rule, the connection list, the
;;; detail, and the teardown.
;;;
;;; The diagnostics tests stay in ExUnit. They assert an exact payload
;;; ("WARNME" answers "warn me not", at these byte offsets), and only a
;;; fake server answers the same thing twice.

(domain! 'testing)
(effects! '(read))

(define (t--lsp-spec name) (cadr (assoc name *lsp-registry*)))

;; the server this file starts: registered, installed, and it indexes
;; nothing under aimax-home, so it reaches ready in about a second
(define t--lsp-name "ruby-lsp")

(effects! '(write))

(deftest 'every-registered-server-names-a-command-and-the-modes-it-serves
  "the registry is what lsp--maybe-attach! reads; a gap there attaches nothing"
  (lambda ()
    (check-true! (> (length *lsp-registry*) 0) "the registry is not empty")
    (for-each
      (lambda (entry)
        (let ((name (car entry)) (spec (cadr entry)))
          (check-true! (string? (plist-get spec 'command))
                       (string-append name " names a command"))
          (check-true! (pair? (plist-get spec 'modes))
                       (string-append name " names the modes it serves"))
          (check-true! (string? (plist-get spec 'language))
                       (string-append name " names its language"))))
      *lsp-registry*)))

(deftest 'a-mode-resolves-to-the-server-registered-for-it
  "lsp-server-for-mode is the whole attach decision"
  (lambda ()
    (let ((modes (plist-get (t--lsp-spec t--lsp-name) 'modes)))
      (check-equal! (car (lsp-server-for-mode (car modes))) t--lsp-name
                    "the mode finds its server"))
    (check-false! (lsp-server-for-mode "zz-no-such-mode") "and an unknown mode finds none")))

(deftest 'lsp-auto-start-off-attaches-nothing
  "the setting is read before a server is reached, not after"
  (lambda ()
    (customize-set! 'lsp-auto-start #f)
    (let ((before (length (lsp-connections))))
      (with-current-buffer (test-buffer! "zz-lsp-gate.rb" "puts 1\n")
        (lambda () (lsp--maybe-attach!)))
      (check-equal! (length (lsp-connections)) before "no server was started")
      (check-false! (minor-mode-on? "zz-lsp-gate.rb" "lsp-mode") "and nothing attached"))
    (customize-set! 'lsp-auto-start #t)
    (buffer-kill! "zz-lsp-gate.rb")))

(deftest 'a-registered-server-starts-reaches-ready-and-stops
  "the one test that pays for a real process, so it covers the whole round trip"
  (lambda ()
    ;; its own empty directory, never (aimax-home): in a live editor that
    ;; is the person's real state, and a server told to index it can take
    ;; minutes or fall over. An empty root reaches ready in about a second.
    (let* ((root (string-append (aimax-home) "/zz-lsp-root"))
           (id (begin (make-directory! root) (lsp-ensure! t--lsp-name root))))
      (check-true! (string? id) "ensure answers a connection id")
      (check-contains! id t--lsp-name "named for the server")
      (check-contains! id root "and rooted where we asked")

      ;; the handshake is a subprocess round trip: it answers on its own
      ;; schedule, and wait-until is what a Scheme test has for that.
      ;; Wait on THIS row: the editor running the suite may already hold
      ;; other connections, and "is anything ready" is true before ours is.
      (check-true! (wait-until (lambda ()
                                 (let ((row (assoc id (lsp-connections))))
                                   (and row (equal? (nth 1 row) "ready"))))
                               15000 100)
                   "it reaches ready")

      (let ((row (assoc id (lsp-connections))))
        (check-true! row "the connection is listed")
        (when row
          (check-equal! (nth 1 row) "ready" "as ready")
          (check-equal! (nth 2 row) t--lsp-name "under its own name")
          (check-equal! (nth 3 row) root "and its root")))

      (check-true! (string? (plist-get (lsp-server-detail id) 'server-name))
                   "the detail names what answered the handshake")
      (check-false! (lsp-server-detail "zz-nope@/x") "and an unknown id has none")

      (lsp-stop! id)
      (check-true! (wait-until (lambda () (not (assoc id (lsp-connections)))) 5000 50)
                   "and it stops")
      (shell-command->string (string-append "rm -rf " root)))))
