;;; howto-test.scm --- howto.scm: the task recipes and the generated manual.
;;;
;;; The stock howtos are documentation that the editor can check. A howto
;;; that names a command no one defined is a broken instruction, so the
;;; first tests read every howto. The key tests bind a dummy key under
;;; <f9> to a dummy command; no test here names a production binding.

(domain! 'testing)
(effects! '(write))

(define *howto-test-ran* #f)

(define-command "howto-test-dummy" "Test command: record that it ran"
  (lambda () (set! *howto-test-ran* #t)))

(define *howto-test-title* "zz run the howto test command")

(define (howto-test-setup!)
  (set! *howto-test-ran* #f)
  (global-set-key "<f9> h" "howto-test-dummy")
  (defhowto! "Zz testing" *howto-test-title*
    "Press {{howto-test-dummy}} once."))

(define (howto-test-done!)
  (global-unset-key "<f9> h")
  (set! *howtos* (filter (lambda (h) (not (equal? (cadr h) *howto-test-title*))) *howtos*))
  (catalog-forget! 'howto *howto-test-title*))

(deftest 'every-howto-names-a-live-command
  "a howto that names a missing command is a broken instruction"
  (lambda ()
    (check-true! (> (length (howtos)) 20) "the stock howtos are loaded")
    (check-equal! (howto-broken-refs) '() "every {{COMMAND}} names a command")))

(deftest 'every-mode-ref-names-a-key-of-that-mode
  "{{MODE:COMMAND}} says press a key there, so that mode must bind one"
  (lambda ()
    (check-equal! (howto-unbound-mode-refs) '() "each mode binds its command")))

(deftest 'a-howto-page-draws-the-live-key-and-a-run-link
  "the page reads the keymap when it draws, so a moved key moves the page"
  (lambda ()
    (howto-test-setup!)
    (let ((md (howto-page-markdown *howto-test-title*)))
      (check-contains! md "`<f9> h`" "the key the global map binds now")
      (check-contains! md "compos:run/howto-test-dummy" "a link that runs the command")
      (check-false! (string-contains? md "{{") "no ref is left unexpanded"))
    (global-unset-key "<f9> h")
    (check-contains! (howto-page-markdown *howto-test-title*)
                     "`M-x howto-test-dummy`" "no key: the page says M-x")
    (howto-test-done!)))

(deftest 'a-run-link-runs-only-from-a-help-page
  "a web page or a chat reply must not run a command by a click"
  (lambda ()
    (howto-test-setup!)
    (with-current-buffer "*scratch*"
      (lambda () (howto--follow-run "howto-test-dummy")))
    (check-false! *howto-test-ran* "a link outside *Help* runs nothing")
    (howto-show! *howto-test-title*)
    (with-current-buffer *help-buffer*
      (lambda () (howto--follow-run "howto-test-dummy")))
    (check-true! *howto-test-ran* "the same link on the help page runs it")
    (howto-test-done!)))

(deftest 'how-do-i-answers-a-title-a-word-and-nothing
  "a title opens its page, words narrow the index, empty lists every task"
  (lambda ()
    (howto-test-setup!)
    (howto-answer! *howto-test-title*)
    (check-contains! (buffer-text *help-buffer*) "How do I zz run the howto test command?"
                     "a title opens its page")
    (check-equal! (map cadr (howto-search "zz howto-test-dummy")) (list *howto-test-title*)
                  "the words match the title and the command it names")
    (howto-answer! "")
    (check-contains! (buffer-text *help-buffer*) "## Zz testing" "empty lists every topic")
    (howto-test-done!)))

(deftest 'help-for-help-links-every-topic
  "the help index names the help commands and every howto topic"
  (lambda ()
    (let ((md (help-for-help-markdown)))
      (check-contains! md "compos:run/how-do-i" "the how-do-i command")
      (check-contains! md "compos:run/describe-key" "the key help")
      (for-each (lambda (topic) (check-contains! md (string-append "**" topic "**") topic))
                (howto-topics)))))

(deftest 'write-manual-writes-every-file
  "the manual is text the editor writes from its registries"
  (lambda ()
    (let ((dir (string-append (compos-home) "/manual-test")))
      (write-manual! dir)
      (let ((howto (read-file (string-append dir "/HOW-DO-I.md")))
            (commands (read-file (string-append dir "/COMMANDS.md")))
            (keys (read-file (string-append dir "/KEYS.md"))))
        (for-each (lambda (title) (check-contains! howto (string-append "How do I " title "?") title))
                  (howto-titles))
        (check-false! (string-contains? howto "compos:") "a file has no editor links")
        (check-contains! commands "`how-do-i`" "the commands name how-do-i")
        (check-contains! keys "| Key | Command |" "the key table")
        (check-true! (read-file (string-append dir "/README.md")) "the index"))
      (for-each (lambda (f) (delete-file-path! (string-append dir "/" f) #t))
                '("README.md" "HOW-DO-I.md" "COMMANDS.md" "KEYS.md"))
      (delete-file-path! dir #t))))
