;;; marginalia-test.scm --- one annotator per category, read by every prompt.
;;;
;;; A candidate is a name. The annotation beside it is what a person needs
;;; to choose between two names that look alike. The fields become columns
;;; padded across the whole set, so the eye reads down a column.
;;;
;;; A prompt is opened with its command and read with minibuffer-state,
;;; so the hint columns are testable without pressing anything.
;;;
;;; One test stays in ExUnit: the MODAL switcher narrowing by annotation.
;;; It narrows through switch-self-insert, which reads the key that ran
;;; it, and it is red in ExUnit today and in every baseline — so there is
;;; nothing working to port.

(domain! 'testing)
(effects! '(write))

;; The registry is global and one entry per category. Every test takes its
;; own category out again.
(define (t--marg-forget! &rest categories)
  (for-each
    (lambda (c)
      (set! *marginalia* (remove (lambda (e) (equal? (car e) c)) *marginalia*)))
    categories))

(deftest 'annotate-pairs-names-with-their-categorys-annotator
  "a category nobody annotates hands its candidates back untouched"
  (lambda ()
    (marginalia! 'zzmarg-one (lambda (n) (string-append "<" n ">")))
    (check-equal! (annotate 'zzmarg-one (list "a" "bb"))
                  '(("a" "<a>") ("bb" "<bb>")) "each name with its annotation")
    (check-equal! (annotate 'zzmarg-nobody (list "x" "y"))
                  '("x" "y") "an unannotated category is untouched")
    (t--marg-forget! 'zzmarg-one)))

(deftest 'several-fields-become-columns-padded-across-the-whole-set
  "the second field starts in the same place on every row"
  (lambda ()
    (marginalia! 'zzmarg-cols (lambda (n) (list n "z")))
    ;; "a" pads to the width of "bbb"
    (check-equal! (annotate 'zzmarg-cols (list "a" "bbb"))
                  '(("a" "a    z") ("bbb" "bbb  z")) "one width for the set")
    (t--marg-forget! 'zzmarg-cols)))

(deftest 'a-row-whose-last-fields-say-nothing-ends-early
  "padding to a column nobody filled is trailing space"
  (lambda ()
    (marginalia! 'zzmarg-trim
      (lambda (n) (if (equal? n "a") (list "" "") (list "x" "yy"))))
    (check-equal! (annotate 'zzmarg-trim (list "a" "b"))
                  '(("a" "") ("b" "x  yy")) "the empty row ends")
    (t--marg-forget! 'zzmarg-trim)))

(deftest 'marginalia-registers-an-annotator-and-replaces-one
  "one annotator per category: the second registration wins"
  (lambda ()
    (marginalia! 'zzmarg-cat (lambda (n) (string-append "<" n ">")))
    (check-equal! (annotate 'zzmarg-cat (list "q")) '(("q" "<q>")) "the first")
    (marginalia! 'zzmarg-cat (lambda (n) "second"))
    (check-equal! (annotate 'zzmarg-cat (list "q")) '(("q" "second")) "the second replaces it")
    (t--marg-forget! 'zzmarg-cat)))

(deftest 'define-command-stores-a-docstring-that-command-doc-reads-back
  "the doc is what the M-x list shows beside the name"
  (lambda ()
    (define-command "zzmarg-frob" "Frob the marginalia test" (lambda () #t))
    (check-equal! (command-doc "zzmarg-frob") "Frob the marginalia test" "the doc")
    ;; the 2-arity form still works, and reads as an empty doc
    (define-command "zzmarg-plain" (lambda () #t))
    (check-equal! (command-doc "zzmarg-plain") "" "no doc is the empty string")
    (test-forget-catalog! "command" "zzmarg-frob")
    (test-forget-catalog! "command" "zzmarg-plain")))


;;; --- the prompts -----------------------------------------------------------------

(define (t--marg-hint label)
  (let loop ((cs (plist-get (minibuffer-state) 'candidates)))
    (cond ((null? cs) #f)
          ((equal? (plist-get (car cs) 'label) label) (plist-get (car cs) 'hint))
          (else (loop (cdr cs))))))

(deftest 'find-file-candidates-carry-mode-size-and-date
  "the icon, the mode a name would open in, its size, then its date"
  (lambda ()
    (let ((root (string-append (compos-home) "/zz-marg-files")))
      (shell-command->string (string-append "rm -rf " root))
      (make-directory! (string-append root "/sub"))
      (write-file! (string-append root "/a.exs") "12345")
      (write-file! (string-append root "/Makefile") "x")

      (dired-open root)
      (run-command "find-file")

      (check-contains! (t--marg-hint "a.exs") "elixir-mode" "the mode a name would open in")
      (check-contains! (t--marg-hint "a.exs") "5" "and its size in bytes")
      (check-contains! (t--marg-hint "sub/") "Dired" "a directory opens in Dired")
      ;; nothing in auto-mode-alist claims it, and Fundamental is still a mode
      (check-contains! (t--marg-hint "Makefile") "Fundamental" "and an unclaimed name")

      ;; the columns are one width for the whole set, so the date lands at
      ;; the same offset on every row however wide the mode and size are
      (check-equal! (length (dedupe-names
                              (map (lambda (h) (number->string (string-length h)))
                                   (list (t--marg-hint "a.exs") (t--marg-hint "sub/")
                                         (t--marg-hint "Makefile")))))
                    1 "every hint is one width")

      (minibuffer-cancel!)
      (when (buffer-known? root) (buffer-kill! root))
      (shell-command->string (string-append "rm -rf " root)))))

(deftest 'the-command-prompt-hints-show-the-keybinding-and-the-doc
  "a doc-only command keeps the binding column blank, so the docs line up"
  (lambda ()
    (run-command "execute-extended-command")
    (minibuffer-change! "next-line")
    (check-contains! (t--marg-hint "next-line") "C-n" "a bound command shows its key")
    (minibuffer-cancel!)

    (define-command "zzmarg-docful" "Do the docful thing" (lambda () #t))
    (run-command "execute-extended-command")
    (minibuffer-change! "zzmarg-docful")
    (let ((hint (t--marg-hint "zzmarg-docful")))
      (check-contains! hint "Do the docful thing" "an unbound one shows its doc")
      (check-true! (string-prefix? " " hint) "after a blank binding column"))
    (minibuffer-cancel!)
    (test-forget-catalog! "command" "zzmarg-docful")))

;;; --- projects --------------------------------------------------------------------

(define (t--marg-project!)
  (let ((root (string-append (compos-home) "/zz-marg-proj")))
    (shell-command->string (string-append "rm -rf " root))
    (make-directory! (string-append root "/lib/deep"))
    (write-file! (string-append root "/lib/deep/a.txt") "a")
    (write-file! (string-append root "/top.txt") "t")
    (shell-command->string (string-append "cd " root " && git init -q ."))
    (string-trim (shell-command->string (string-append "cd " root " && pwd -P")))))

(define (t--marg-project-done! root)
  (for-each (lambda (b) (when (string-prefix? root b) (buffer-kill! b))) (buffer-list))
  (shell-command->string (string-append "rm -rf " root)))

(deftest 'project-root-from-walks-up-to-the-git-marker
  "and answers #f where there is none"
  (lambda ()
    (let ((root (t--marg-project!)))
      (check-equal! (project-root-from (string-append root "/lib/deep")) root
                    "it walks up to the marker")
      (check-false! (project-root-from "/tmp") "and a directory outside a project has none")
      (t--marg-project-done! root))))

(deftest 'project-files-lists-tracked-and-untracked-but-not-ignored
  "git decides, so .gitignore is honoured without parsing it"
  (lambda ()
    (let ((root (t--marg-project!)))
      (write-file! (string-append root "/.gitignore") "top.txt\n")
      (let ((files (value->string (project-files root))))
        (check-contains! files "lib/deep/a.txt" "an untracked file is listed")
        (check-false! (string-contains? files "top.txt") "and an ignored one is not"))
      (t--marg-project-done! root))))

(deftest 'visiting-a-file-remembers-its-project
  "the known projects are what a prompt offers"
  (lambda ()
    (let ((root (t--marg-project!)))
      (let ((buf (visit (string-append root "/top.txt"))))
        (check-equal! (buffer-local buf 'modeline-file) "top.txt"
                      "the modeline uses the project-relative filename")
        (check-equal! (buffer-local buf 'modeline-project) "zz-marg-proj"
                      "the modeline names the project"))
      (check-contains! (value->string (known-projects)) root "the project is remembered")
      (t--marg-project-done! root))))
