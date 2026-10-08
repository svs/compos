;;; features-test.scm --- provide, require, autoload, and the cookie harvest.
;;;
;;; Emacs's load-order mechanisms, on files this test writes itself under
;;; the test home. Nothing here names a bundled package's commands.

(domain! 'testing)
(effects! '(write))

(define t--ft-dir (string-append (compos-home) "/zz-features"))

(define (t--ft-path name) (string-append t--ft-dir "/" name))

(define (t--ft-write! name text) (write-file! (t--ft-path name) text))

(define (t--ft-make!)
  (shell-command->string (string-append "rm -rf " (sh-quote t--ft-dir)))
  (shell-command->string (string-append "mkdir -p " (sh-quote t--ft-dir)))
  (add-to-list! 'load-path t--ft-dir))

(define (t--ft-remove!)
  (set! load-path (remove (lambda (d) (equal? d t--ft-dir)) load-path))
  (shell-command->string (string-append "rm -rf " (sh-quote t--ft-dir))))

;; a feature this test provided in an earlier run is forgotten first
(define (t--ft-forget! &rest fs)
  (set! *features* (remove (lambda (f) (member f fs)) *features*)))

(define zz-ft-count 0)
(define zz-ft-verbatim #f)
(define zz-ft-cmd-ran #f)
(define zz-ft-after '())

(deftest 'provide-and-featurep
  "provide records a feature once; featurep reads it"
  (lambda ()
    (t--ft-forget! 'zz-ft-plain)
    (check-false! (featurep 'zz-ft-plain) "not provided yet")
    (provide 'zz-ft-plain)
    (provide 'zz-ft-plain)
    (check-true! (featurep 'zz-ft-plain) "provided")
    (check-equal! (length (filter (lambda (f) (equal? f 'zz-ft-plain)) *features*)) 1
                  "recorded once")
    (t--ft-forget! 'zz-ft-plain)))

(deftest 'the-boot-provides-its-files
  "the bootstrap files and the packages init.scm loads are features"
  (lambda ()
    (check-true! (featurep 'editor) "editor.scm")
    (check-true! (featurep 'init) "init.scm")
    (check-true! (featurep 'dired) "dired.scm, loaded by init.scm")
    (check-true! (featurep 'custom) "custom.scm, loaded by init.scm")))

(deftest 'require-loads-a-file-once
  "the first require loads; the second is free; load provides the library name"
  (lambda ()
    (t--ft-make!)
    (t--ft-forget! 'zz-ft-once)
    (set! zz-ft-count 0)
    (t--ft-write! "zz-ft-once.scm" "(set! zz-ft-count (+ zz-ft-count 1))\n")
    (check-equal! (require 'zz-ft-once) 'zz-ft-once "require answers the feature")
    (require 'zz-ft-once)
    (check-equal! zz-ft-count 1 "the file ran once")
    (check-true! (featurep 'zz-ft-once) "load provided the library name")
    (t--ft-forget! 'zz-ft-once)
    (t--ft-remove!)))

(deftest 'require-takes-a-filename
  "a feature whose file is not F.scm names the file; a file that does not provide it is an error"
  (lambda ()
    (t--ft-make!)
    (t--ft-forget! 'zz-ft-named 'zz-ft-other)
    (t--ft-write! "zz-ft-other.scm" "(provide 'zz-ft-named)\n")
    (check-equal! (require 'zz-ft-named "zz-ft-other.scm") 'zz-ft-named "loaded by filename")
    (check-true! (featurep 'zz-ft-other) "the library name is provided too")
    (t--ft-write! "zz-ft-silent.scm" "(define zz-ft-silent-mark 1)\n")
    (check-false! (ignore-errors (lambda () (require 'zz-ft-wanted "zz-ft-silent.scm")))
                  "a file that does not provide the feature is an error")
    (t--ft-forget! 'zz-ft-named 'zz-ft-other 'zz-ft-silent)
    (t--ft-remove!)))

(deftest 'require-of-a-missing-file-is-an-error
  "a feature with no file on load-path raises; nothing is provided"
  (lambda ()
    (check-false! (ignore-errors (lambda () (require 'zz-ft-no-such-feature))) "raised")
    (check-false! (featurep 'zz-ft-no-such-feature) "not provided")))

(deftest 'a-require-whose-file-failed-at-boot-answers-false-and-goes-on
  "the boot loader records the file's own error; the manifest line after it still runs"
  (lambda ()
    (t--ft-make!)
    (t--ft-forget! 'zz-broken)
    (t--ft-write! "zz-broken.scm" "(define zz-broken-loaded #t)\n")
    (let ((saved builtin-load))
      ;; what the boot loader answers for a file that raised
      (set! builtin-load (lambda (path) 'load-failed))
      (check-equal! (require 'zz-broken) #f "no feature, and no second error")
      (set! builtin-load saved))
    (check-false! (featurep 'zz-broken) "nothing provided")
    (check-equal! (require 'zz-broken) 'zz-broken "the same require after a fix loads it")
    (t--ft-forget! 'zz-broken)
    (t--ft-remove!)))

(deftest 'recursive-require-is-an-error
  "a requires b requires a: an error, and the loader is clean after it"
  (lambda ()
    (t--ft-make!)
    (t--ft-forget! 'zz-ft-cyc-a 'zz-ft-cyc-b)
    (t--ft-write! "zz-ft-cyc-a.scm" "(require 'zz-ft-cyc-b)\n")
    (t--ft-write! "zz-ft-cyc-b.scm" "(require 'zz-ft-cyc-a)\n")
    (let ((chain *features-loading*)
          (pkg *loading-package*))
      (check-false! (ignore-errors (lambda () (require 'zz-ft-cyc-a))) "the cycle raised")
      (check-equal! *features-loading* chain "the require chain is back")
      (check-equal! *loading-package* pkg "the package stamp is back")
      (check-false! (featurep 'zz-ft-cyc-a) "a is not provided")
      (check-false! (featurep 'zz-ft-cyc-b) "b is not provided"))
    (t--ft-remove!)))

(deftest 'a-load-that-raises-provides-nothing
  "the file's error goes to the caller; the stamps and the feature list are as before"
  (lambda ()
    (t--ft-make!)
    (t--ft-forget! 'zz-ft-boom)
    (t--ft-write! "zz-ft-boom.scm" "(define zz-ft-boom-mark 1)\n(error \"boom\")\n")
    (let ((pkg *loading-package*)
          (org *loading-origin*))
      (check-false! (ignore-errors (lambda () (load "zz-ft-boom.scm"))) "the error raised")
      (check-false! (featurep 'zz-ft-boom) "not provided")
      (check-equal! *loading-package* pkg "the package stamp is back")
      (check-equal! *loading-origin* org "the origin stamp is back"))
    (t--ft-remove!)))

(deftest 'with-eval-after-load-runs-now-or-later
  "a provided feature runs the thunk at once; an unprovided one runs it on provide, once"
  (lambda ()
    (t--ft-forget! 'zz-ft-now 'zz-ft-later)
    (set! zz-ft-after '())
    (provide 'zz-ft-now)
    (with-eval-after-load 'zz-ft-now (lambda () (set! zz-ft-after (cons 'now zz-ft-after))))
    (check-equal! zz-ft-after '(now) "ran at once")
    (with-eval-after-load 'zz-ft-later (lambda () (set! zz-ft-after (cons 'later-1 zz-ft-after))))
    (with-eval-after-load 'zz-ft-later (lambda () (set! zz-ft-after (cons 'later-2 zz-ft-after))))
    (check-equal! zz-ft-after '(now) "waits")
    (provide 'zz-ft-later)
    (check-equal! zz-ft-after '(later-2 later-1 now) "ran in order on provide")
    (provide 'zz-ft-later)
    (check-equal! zz-ft-after '(later-2 later-1 now) "ran once")
    (t--ft-forget! 'zz-ft-now 'zz-ft-later)))

(deftest 'autoload-loads-the-file-on-the-first-call
  "the stub is a procedure; the call loads the file and applies the real definition"
  (lambda ()
    (t--ft-make!)
    (t--ft-forget! 'zz-ft-auto)
    (unbind-global! 'zz-ft-fn)
    (t--ft-write! "zz-ft-auto.scm" "(define (zz-ft-fn x) (* x 2))\n")
    (autoload 'zz-ft-fn "zz-ft-auto.scm")
    (check-true! (procedure? zz-ft-fn) "the stub is bound")
    (check-equal! (autoload-file 'zz-ft-fn) "zz-ft-auto.scm" "the stub names its file")
    (check-equal! (zz-ft-fn 21) 42 "the call loads and answers")
    (check-true! (featurep 'zz-ft-auto) "the file is provided")
    (check-false! (autoload-file 'zz-ft-fn) "the stub is gone")
    (check-equal! (zz-ft-fn 2) 4 "the real definition stays")
    (t--ft-forget! 'zz-ft-auto)
    (t--ft-remove!)))

(deftest 'autoload-does-not-replace-a-definition
  "autoload of a bound name is a no-op"
  (lambda ()
    (set-symbol-value! 'zz-ft-bound (lambda () 'mine))
    (autoload 'zz-ft-bound "zz-ft-no-such-file.scm")
    (check-equal! (zz-ft-bound) 'mine "the definition stayed")
    (check-false! (autoload-file 'zz-ft-bound) "no stub")))

(deftest 'autoload-of-a-name-the-file-leaves-out-is-an-error
  "a file that does not define the name raises instead of looping"
  (lambda ()
    (t--ft-make!)
    (t--ft-forget! 'zz-ft-auto)
    (unbind-global! 'zz-ft-absent)
    (t--ft-write! "zz-ft-auto.scm" "(define (zz-ft-fn x) (* x 2))\n")
    (autoload 'zz-ft-absent "zz-ft-auto.scm")
    (check-false! (ignore-errors (lambda () (zz-ft-absent))) "raised")
    (t--ft-forget! 'zz-ft-auto)
    (t--ft-remove!)))

(deftest 'autoload-command-exists-before-its-file-loads
  "M-x sees the command; its first run loads the file and runs the real command"
  (lambda ()
    (t--ft-make!)
    (t--ft-forget! 'zz-ft-auto-cmd)
    (undefine-command "zz-ft-cmd")
    (set! zz-ft-cmd-ran #f)
    (t--ft-write! "zz-ft-auto-cmd.scm"
      "(define-command \"zz-ft-cmd\" \"Set the mark\" (lambda () (set! zz-ft-cmd-ran #t)))\n")
    (autoload-command "zz-ft-cmd" "zz-ft-auto-cmd.scm" "Set the mark (autoload)")
    (check-true! (command-fn "zz-ft-cmd") "the command is in the table")
    (check-equal! (plist-get (catalog-entry 'command "zz-ft-cmd") 'autoload) "zz-ft-auto-cmd.scm"
                  "the catalog names the file")
    (check-equal! (command-doc "zz-ft-cmd") "Set the mark (autoload)" "the stub carries the doc")
    (run-command "zz-ft-cmd")
    (check-true! zz-ft-cmd-ran "the real command ran")
    (check-false! (autoload-file "zz-ft-cmd") "the stub is gone")
    (check-equal! (command-doc "zz-ft-cmd") "Set the mark" "the file's doc replaced the stub's")
    (set! zz-ft-cmd-ran #f)
    (run-command "zz-ft-cmd")
    (check-true! zz-ft-cmd-ran "the second run is the real command")
    (undefine-command "zz-ft-cmd")
    (t--ft-forget! 'zz-ft-auto-cmd)
    (t--ft-remove!)))

(deftest 'autoload-harvest-reads-the-cookies
  "a define-command cookie makes a command, a define cookie a stub, another form runs; tests and provided files are skipped"
  (lambda ()
    (t--ft-make!)
    (t--ft-forget! 'zz-ft-cookie 'zz-ft-cookie-provided)
    (undefine-command "zz-ft-cookie-cmd")
    (undefine-command "zz-ft-cookie-test-cmd")
    (undefine-command "zz-ft-cookie-provided-cmd")
    (unbind-global! 'zz-ft-cookie-fn)
    (set! zz-ft-verbatim #f)
    (t--ft-write! "zz-ft-cookie.scm"
      (string-append
        ";;; a package the stock boot leaves out\n"
        ";;;###autoload\n"
        "(define-command \"zz-ft-cookie-cmd\" \"From the cookie\" (lambda () 'ran))\n"
        "(define-command \"zz-ft-cookie-quiet\" \"No cookie\" (lambda () 'ran))\n"
        ";;;###autoload\n"
        "(define (zz-ft-cookie-fn x) (+ x 1))\n"
        ";;;###autoload\n"
        "(set! zz-ft-verbatim 'ran)\n"))
    (t--ft-write! "zz-ft-cookie-test.scm"
      ";;;###autoload\n(define-command \"zz-ft-cookie-test-cmd\" \"Never\" (lambda () 'no))\n")
    (t--ft-write! "zz-ft-cookie-provided.scm"
      ";;;###autoload\n(define-command \"zz-ft-cookie-provided-cmd\" \"Never\" (lambda () 'no))\n")
    (provide 'zz-ft-cookie-provided)
    (let ((read (autoload-harvest! (list t--ft-dir))))
      (check-equal! read (list (t--ft-path "zz-ft-cookie.scm")) "one file had cookies to install")
      (check-true! (command-fn "zz-ft-cookie-cmd") "the cookie command exists")
      (check-equal! (command-doc "zz-ft-cookie-cmd") "From the cookie" "with the file's doc")
      (check-false! (command-fn "zz-ft-cookie-quiet") "a form without a cookie is not installed")
      (check-equal! (autoload-file 'zz-ft-cookie-fn) (t--ft-path "zz-ft-cookie.scm")
                    "the define cookie is a stub")
      (check-equal! zz-ft-verbatim 'ran "the other form ran as it is")
      (check-false! (command-fn "zz-ft-cookie-test-cmd") "a test file is skipped")
      (check-false! (command-fn "zz-ft-cookie-provided-cmd") "a provided file is skipped")
      (check-false! (featurep 'zz-ft-cookie) "the harvest loads nothing")
      (check-equal! (zz-ft-cookie-fn 1) 2 "the stub loads the file")
      (check-true! (featurep 'zz-ft-cookie) "now the file is loaded")
      (check-true! (command-fn "zz-ft-cookie-quiet") "and every command in it exists"))
    (undefine-command "zz-ft-cookie-cmd")
    (undefine-command "zz-ft-cookie-quiet")
    (t--ft-forget! 'zz-ft-cookie 'zz-ft-cookie-provided)
    (t--ft-remove!)))
