;;; lsp-test.scm --- the LSP client, against a server the editor ships with.
;;;
;;; No fake server and no temp project: the registry already names real
;;; servers, and one of them starts here. What a real server proves is the
;;; plumbing — the registry, the attach rule, the connection list, the
;;; detail, and the teardown.
;;;
;;; Starting a real server is NOT tested here. Two reasons, both learned
;;; the hard way: lsp.scm delivers its events on the :ui lane, and
;;; wait-until holds the lane it runs on — so waiting for "ready" blocks
;;; the transition it waits for and times out every time, while the same
;;; server polled from outside an eval is ready in two seconds. And a
;;; connection left registered on a dead process makes the next ensure
;;; hand back the id without starting anything. lsp_conn_test drives the
;;; lifecycle against the fake server, deterministically, and should.
;;;
;;; The diagnostics tests stay in ExUnit too. They assert an exact payload
;;; ("WARNME" answers "warn me not", at these byte offsets), and only a
;;; fake server answers the same thing twice.

(domain! 'testing)
(effects! '(read))

(define (t--lsp-spec name) (cadr (assoc name *lsp-registry*)))

;; the server this file starts: registered, installed, and it indexes
;; nothing under compos-home, so it reaches ready in about a second
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

(deftest 'elixir-ls-registers-with-dialyzer-off
  "a dialyzer default of on grew one server here to a 38 GB footprint"
  (lambda ()
    (check-equal! (plist-get (t--lsp-spec "elixir-ls") 'settings)
                  (list 'dialyzerEnabled #f)
                  "elixir-ls turns dialyzer off")))
