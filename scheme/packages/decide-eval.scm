;;; decide-eval.scm --- score JEV and laya on the decisions compos asks.
;;;
;;; (decide-eval) puts every case through decide once a backend, JEV and
;;; laya by default, one call after another in a task. A case is a real
;;; question compos asks, built with the same function its package uses:
;;; the shell gate's kind, the anonymizer's person names, the browser's
;;; shell judge and article test, fast-code's compound test, and the
;;; palette's command pick. It writes the table to *decide-eval*, says the
;;; score in the echo area, and sends the first line as the event
;;; decide-eval done.
;;;
;;; A case is (KIND LABEL STATE EXTRA EXPECT). EXPECT is ((KEY WANT) ...):
;;; WANT is #t or #f for a yes/no question, read at 0.5 as every caller
;;; reads it, and a symbol for a pick.

(domain! 'decide)
(effects! '(read external spend))

(define (decide-eval--sh cmd)
  (string-append "(shell-command->string \"" cmd "\" (default-directory))"))

(define *decide-eval-palette-commands*
  (list 'find-file "Open a file by its path"
        'save-buffer "Save the current buffer to its file"
        'split-window-right "Split the window side by side"
        'delete-other-windows "Make the current window the only one"
        'laya-server "Start the on-device decision model"
        'kill-buffer "Kill a buffer and close it"
        'none "None of these does what the request asks."))

(define *decide-eval-cases*
  (list
    ;; the shell gate: which kind of shell command an agent's payload runs
    (list 'shell "cat a file" (decide-eval--sh "cat mix.exs") #f '((kind read)))
    (list 'shell "rg a tree" (decide-eval--sh "rg -n defmodule apps/") #f '((kind read)))
    (list 'shell "ls" (decide-eval--sh "ls -la apps") #f '((kind read)))
    (list 'shell "find | wc" (decide-eval--sh "find . -name '*.scm' | wc -l") #f '((kind read)))
    (list 'shell "sed -i" (decide-eval--sh "sed -i 's/foo/bar/' lib/x.ex") #f '((kind edit)))
    (list 'shell "redirect" (decide-eval--sh "echo hi > notes.txt") #f '((kind edit)))
    (list 'shell "rm -rf" (decide-eval--sh "rm -rf _build/tmp") #f '((kind edit)))
    (list 'shell "mkdir && cp" (decide-eval--sh "mkdir -p tmp/a && cp a.txt tmp/a/") #f '((kind edit)))
    (list 'shell "mix test | tail" (decide-eval--sh "mix test apps/compos_core/test/foo_test.exs 2>&1 | tail -20") #f '((kind build)))
    (list 'shell "mix compile" (decide-eval--sh "mix compile --warnings-as-errors") #f '((kind build)))
    (list 'shell "cargo test" (decide-eval--sh "cargo test") #f '((kind build)))
    (list 'shell "git status" (decide-eval--sh "git status") #f '((kind git)))
    (list 'shell "git log" (decide-eval--sh "git log --oneline -5") #f '((kind git)))
    (list 'shell "date" (decide-eval--sh "date") #f '((kind other)))
    (list 'shell "curl" (decide-eval--sh "curl -s https://example.com/api") #f '((kind other)))
    (list 'shell "uname" (decide-eval--sh "uname -a") #f '((kind other)))
    ;; the anonymizer: which capitalized words name a person, in one batch
    (list 'anon "ten words" "Decide which capitalized words name a person."
          '((w0 "Priya" "Interview with Priya tomorrow at 3.")
            (w1 "Kubernetes" "We deploy everything on Kubernetes.")
            (w2 "Siddharth" "Siddharth reviewed the patch last night.")
            (w3 "Postgres" "Move the sessions table to Postgres.")
            (w4 "The" "The build failed again.")
            (w5 "Marcus" "Ask Marcus about the invoice.")
            (w6 "GitHub" "Open an issue on GitHub.")
            (w7 "Tokyo" "Flight to Tokyo on Monday.")
            (w8 "Chen" "Dr. Chen signed the form.")
            (w9 "Phoenix" "The Phoenix LiveView socket closed."))
          '((w0 #t) (w1 #f) (w2 #t) (w3 #f) (w4 #f) (w5 #t) (w6 #f) (w7 #f) (w8 #t) (w9 #f)))
