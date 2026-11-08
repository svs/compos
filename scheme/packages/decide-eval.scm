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
    ;; the browser: is a fetched page a shell, and is it an article
    (list 'web-shell "needs javascript" "Loading... You need to enable JavaScript to run this app." #f '((shell #t)))
    (list 'web-shell "bot challenge" "Just a moment... Checking if the site connection is secure. example.com needs to review the security of your connection before proceeding. Ray ID: 8a1b2c3d" #f '((shell #t)))
    (list 'web-shell "login wall" "Sign in to continue. Email Password Forgot password? Create an account Sign in with Google" #f '((shell #t)))
    (list 'web-shell "404" "404 Not Found. The page you requested could not be found. Go back home." #f '((shell #t)))
    (list 'web-shell "article" "The city council voted on Tuesday to expand the bike lane network by forty kilometres. The plan, which has been debated for two years, moves money from road resurfacing to protected lanes on six major streets. Supporters said the change would cut injuries; opponents said it would slow deliveries." #f '((shell #f)))
    (list 'web-shell "recipe" "Lemon tart. Serves 8. For the pastry, rub the butter into the flour until it looks like breadcrumbs, then add the egg yolk and a little cold water. Chill for thirty minutes. For the filling, whisk eggs, sugar, lemon juice and cream." #f '((shell #f)))
    (list 'web-article "news story" "Rail strike ends after talks | City News. Train drivers returned to work on Friday after union leaders accepted a revised pay offer. The dispute, which began in March, cancelled more than four thousand services. The rail operator said full timetables would resume by Monday." #f '((article #t)))
    (list 'web-article "blog post" "Why I moved my notes to plain text - a personal blog. For ten years I kept my notes in a proprietary app. Last month the export broke, and I lost a week of work. Here is what I learned moving everything to markdown files and a sync folder." #f '((article #t)))
    (list 'web-article "docs page" "Configuring the cache - Docs. The cache keeps rendered pages for the time you set in cache_ttl. Set cache_ttl to 0 to turn it off. Entries are keyed by the request path and the Accept header. To clear the cache, run cache clear." #f '((article #t)))
    (list 'web-article "link aggregator" "Hacker News new | past | comments | ask | show | jobs | submit 1. Show HN: A tiny database in 500 lines (github.com) 312 points 2. The history of the floppy disk (example.org) 201 points 3. Ask HN: How do you back up? 188 points 4. Rust 2.0 released (rust-lang.org) 150 points" #f '((article #f)))
    (list 'web-article "search results" "Search results for lemon tart: Classic lemon tart - 4.8 stars, 1 hr. Easy lemon tart with shortcrust - 4.5 stars, 45 min. Vegan lemon tart - 4.2 stars. Lemon meringue pie - 4.7 stars. Page 1 of 12. Next" #f '((article #f)))
    (list 'web-article "shop listing" "Shop - Running shoes. Sort by: price. Trail Runner X $120 Add to cart. Road Glide 3 $95 Add to cart. Kids Sprint $45 Add to cart. Filter: size, colour, brand. Showing 24 of 310 products." #f '((article #f)))
    ;; fast-code: is a request compound
    (list 'compound "one rename" "The request: rename foo to bar" #f '((compound #f)))
    (list 'compound "typo" "The request: fix the typo in README" #f '((compound #f)))
    (list 'compound "one binding" "The request: bind C-c C-k to kill-buffer" #f '((compound #f)))
    (list 'compound "rename then test" "The request: rename foo to bar and then run the tests" #f '((compound #t)))
    (list 'compound "three steps" "The request: open the file, add a docstring to every function, then commit" #f '((compound #t)))
    (list 'compound "mode + tests" "The request: create a mode for csv files, bind it to .csv and write tests for it" #f '((compound #t)))
    ;; the palette: which command the words ask for
    (list 'palette "open a file" "open init.scm" #f '((which find-file)))
    (list 'palette "save" "write this to disk" #f '((which save-buffer)))
    (list 'palette "side by side" "two panes next to each other" #f '((which split-window-right)))
    (list 'palette "one window" "just one window please" #f '((which delete-other-windows)))
    (list 'palette "local model" "start the local classifier" #f '((which laya-server)))
    (list 'palette "close buffer" "close this buffer" #f '((which kill-buffer)))
    (list 'palette "weather" "what is the weather in Paris" #f '((which none)))
    (list 'palette "font" "make the font bigger" #f '((which none)))))

;; the questions a case asks, built by the function its package uses
(define (decide-eval--questions kind extra)
  (cond ((eq? kind 'shell) (decide--shell-questions))
        ((eq? kind 'anon)
         (apply append (map (lambda (w) (list (car w) (anon--question (cadr w) (caddr w)))) extra)))
        ((eq? kind 'web-shell) (list 'shell (web--judge-question)))
        ((eq? kind 'web-article) (list 'article (web--article-question)))
        ((eq? kind 'compound) fast-compound-question)
        ((eq? kind 'palette)
         (list 'which (decide-choice "Which of these is the right command for this request?"
                                     *decide-eval-palette-commands*)))
        (else (error (string-append "decide-eval: unknown kind " (symbol->string kind))))))

;; what one answer row says: #t or #f for a yes/no, a symbol for a pick
(define (decide-eval--got want answers key)
  (let* ((row (assoc key answers))
         (a (and row (cadr row))))
    (cond ((not (pair? a)) 'no-answer)
          ((or (eq? want #t) (eq? want #f))
           (let ((p (plist-get a 'noul))) (if (number? p) (>= p 0.5) 'no-answer)))
          (else (or (decide--choice-symbol (plist-get a 'choice)) 'no-answer)))))

;; one case on one backend: a row (KIND LABEL BACKEND KEY WANT GOT MS) a question
(define (decide-eval--run-case c backend)
  (let* ((kind (list-ref c 0))
         (t0 (monotonic-ms))
         (reply (ignore-errors
                  (lambda () (decide (list-ref c 2) (decide-eval--questions kind (list-ref c 3))
                                     'backend backend))))
         (ms (- (monotonic-ms) t0))
         (answers (or (and (pair? reply) (plist-get reply 'answers)) '())))
    (map (lambda (e)
           (list kind (list-ref c 1) backend (car e) (cadr e)
                 (decide-eval--got (cadr e) answers (car e)) ms))
         (list-ref c 4))))

(define (decide-eval--ok? r) (equal? (list-ref r 4) (list-ref r 5)))

(define (decide-eval--dedupe xs)
  (let loop ((xs xs) (out '()))
    (cond ((null? xs) (reverse out))
          ((member (car xs) out) (loop (cdr xs) out))
          (else (loop (cdr xs) (cons (car xs) out))))))

;; RIGHT/QUESTIONS, the unanswered, and the mean time of one call
(define (decide-eval--score rows)
  (let* ((ok (length (filter decide-eval--ok? rows)))
         (none (length (filter (lambda (r) (eq? (list-ref r 5) 'no-answer)) rows)))
         (calls (decide-eval--dedupe (map (lambda (r) (list (list-ref r 0) (list-ref r 1) (list-ref r 6))) rows)))
         (ms (map caddr calls)))
    (string-append (number->string ok) "/" (number->string (length rows))
                   (if (> none 0) (string-append " (" (number->string none) " unanswered)") "")
                   ", " (number->string (if (null? ms) 0 (quotient (apply + ms) (length ms))))
                   " ms a call")))

(define (decide-eval--of rows backend &optional kind)
  (filter (lambda (r) (and (eq? (list-ref r 2) backend) (or (not kind) (eq? (list-ref r 0) kind))))
          rows))

(define (decide-eval--text rows backends)
  (let* ((kinds (decide-eval--dedupe (map car rows)))
         (wrong (filter (lambda (r) (not (decide-eval--ok? r))) rows))
         (misses (decide-eval--dedupe (map (lambda (r) (list (list-ref r 0) (list-ref r 1) (list-ref r 3))) wrong))))
    (string-append
      "decide-eval: "
      (string-join (map (lambda (b) (string-append (symbol->string b) " "
                                                   (decide-eval--score (decide-eval--of rows b))))
                        backends)
                   "; ")
      "\n\n"
      (string-join
        (map (lambda (k)
               (string-append (string-pad-right (symbol->string k) 12)
                 (string-join (map (lambda (b) (string-append (string-pad-right (symbol->string b) 5)
                                                              (string-pad-right (decide-eval--score (decide-eval--of rows b k)) 28)))
                                   backends) " ")))
             kinds)
        "\n")
      "\n\nMisses\n"
      (if (null? misses) "none\n"
        (string-join
          (map (lambda (m)
                 (let ((rs (filter (lambda (r) (equal? (list (list-ref r 0) (list-ref r 1) (list-ref r 3)) m)) rows)))
                   (string-append (string-pad-right (symbol->string (car m)) 12)
                     (string-pad-right (string-append (cadr m) " " (symbol->string (caddr m))) 28)
                     " want " (string-pad-right (value->string (list-ref (car rs) 4)) 22)
                     (string-join (map (lambda (r) (string-append (symbol->string (list-ref r 2)) " "
                                                                  (string-pad-right (value->string (list-ref r 5)) 22)))
                                       rs) " "))))
               misses)
          "\n"))
      "\n")))

;; Run the cases one after another, in a task, so each call's time is its
;; own. The table goes to *decide-eval*; the score goes to the echo area
;; and the event decide-eval done. BACKENDS defaults to (jev laya).
(define (decide-eval &optional backends cases)
  (let ((bs (or backends '(jev laya))))
    (task-run!
      (lambda ()
        (apply append
               (map (lambda (c) (apply append (map (lambda (b) (decide-eval--run-case c b)) bs)))
                    (or cases *decide-eval-cases*))))
      (lambda (ok? rows)
        (if (not ok?)
            (message (string-append "decide-eval failed: " (value->string rows)))
            (let ((text (decide-eval--text rows bs)))
              (unless (buffer-known? "*decide-eval*") (buffer-create "*decide-eval*"))
              (buffer-set-text! "*decide-eval*" text)
              (message (car (string-split text "\n")))
              (event-publish! "decide-eval" 'done (car (string-split text "\n")))))))))

(public! 'decide-eval
  "(decide-eval [BACKENDS CASES]) -- score each decide backend, JEV and laya by default, on the questions compos asks; the table goes to *decide-eval*")
