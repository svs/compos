;;; anon.scm --- anon-mode: redact proper nouns for a screencast.
;;;
;;; Every capitalized word on the lines a window draws is painted as a
;;; bar. jit-lock hands anon only those lines, so a hidden buffer and the
;;; off-screen part of a large buffer cost nothing. decide says which
;;; words name a person or a company, and the others come back into view.
;;; Both answers are cached, so a word asks the model one time. The text is untouched:
;;; this keeps names out of a recording, it is not a security boundary.
;;;
;;;   M-x anon-mode        every buffer, as a window shows it
;;;   M-x anon-local-mode  this buffer only

(package! "anon")
(category! 'writing)
(domain! 'anon)
(effects! '(write))

(defcustom 'anon-proper-nouns '()
  "Words decide called proper nouns. They are always redacted."
  'group 'anon 'type 'sexp)

(defcustom 'anon-common-words '()
  "Capitalized words decide called common. They are never redacted."
  'group 'anon 'type 'sexp)

(defcustom 'anon-handles '()
  "The part before the @ of each email anon barred. It is barred wherever it shows."
  'group 'anon 'type 'sexp)

(defcustom 'anon-batch-size 40
  "The words one decide call judges."
  'group 'anon 'type 'integer)

(defcustom 'anon-max-bytes 2000000
  "A buffer past this size is redacted but never sent to decide."
  'group 'anon 'type 'integer)

(defface! 'anon-redacted 'fg "var(--default-fg)" 'bg "var(--default-fg)" 'priority 100)

;; a capitalized word: an uppercase letter, then letters
(define anon--word-pattern "\\p{Lu}[\\p{L}\\p{M}]*(?:[ \\t]+\\p{Lu}[\\p{L}\\p{M}]*)*")

;; one capitalized word of a run
(define anon--one-word-pattern "\\p{Lu}[\\p{L}\\p{M}]*")

;; words sent to decide and not yet answered
(define *anon-pending* '())

(effects! '(pure))

(define (anon--run-common? run)
  "#t for a run of two or more capitalized words that are each a known common word"
  (let ((ws (map (lambda (r) (substring-bytes run (car r) (cadr r))) (re-find* anon--one-word-pattern run))))
    (and (pair? ws) (pair? (cdr ws))
         (null? (filter (lambda (w) (not (member w anon-common-words))) ws)))))

(define (anon--spans text)
  "(anon--spans TEXT) - (START END RUN) for every run of consecutive capitalized words in TEXT"
  (filter (lambda (s) (not (anon--run-common? (caddr s))))
          (map (lambda (r) (list (car r) (cadr r) (substring-bytes text (car r) (cadr r))))
               (re-find* anon--word-pattern text))))

(define anon--email-pattern "[\\p{L}\\p{N}._%+-]+@[\\p{L}\\p{N}-]+(?:\\.[\\p{L}\\p{N}-]+)+")

(define (anon--emails text)
  "(START END \"\") for every email address in TEXT"
  (map (lambda (r) (list (car r) (cadr r) "")) (re-find* anon--email-pattern text)))

(define (anon--outside emails spans)
  "the SPANS that no email span holds"
  (filter (lambda (s) (null? (filter (lambda (e) (and (<= (car e) (car s)) (<= (cadr s) (cadr e)))) emails)))
          spans))

(define (anon--context text start end)
  "the text around one word: 100 bytes on each side"
  (substring-bytes text (max 0 (- start 100)) (min (string-byte-length text) (+ end 100))))

(define (anon--chunks xs n)
  (if (null? xs) '()
      (let loop ((xs xs) (i 0) (acc '()))
        (if (or (null? xs) (= i n))
            (cons (reverse acc) (anon--chunks xs n))
            (loop (cdr xs) (+ i 1) (cons (car xs) acc))))))

(define (anon--question word context)
  (decide-noul
    (string-append "Is '" word "' a person's name or a company's name here, or does it "
                   "contain one? The name of a product, service, technology, place or project is not, even when a company makes it: AWS, GitHub, Kubernetes and Postgres are not. "
                   "Words capitalized only because they start a sentence or a heading are not. "
                   "Context: "
                   context)))

(effects! '(write))

;; The spans to paint. A common word sorts as (WORD 0), just before its
;; spans (WORD 1 START END), so one pass over one sort drops them. The
;; dialect has no string<?, and a member per span is quadratic.
(define (anon--redacted spans common)
  (let loop ((rows (sort (append (map (lambda (w) (list w 0)) common)
                                 (map (lambda (s) (list (caddr s) 1 (car s) (cadr s))) spans))))
             (skip #f) (acc '()))
    (cond ((null? rows) acc)
          ((equal? (cadr (car rows)) 0) (loop (cdr rows) (car (car rows)) acc))
          ((equal? (car (car rows)) skip) (loop (cdr rows) skip acc))
          (else (loop (cdr rows) skip
                      (cons (list (caddr (car rows)) (list-ref (car rows) 3) "anon-redacted") acc))))))

;; A block view draws its own tree, not the buffer text, so no overlay
;; reaches it. While a buffer has anon-local-mode, the tree a mode writes to
;; 'render-blocks is redacted on its way in: the last step before the page,
;; over only the rows the view holds. The original stays in
;; 'anon-render-blocks as (ORIGINAL REDACTED).

(define anon--tree-keys '(tag class click mark lines style id key))

;; A handle is the part before the @ of an email. It shows alone too: in a
;; URL, a username, a path. Every email anon bars teaches its handle.
(define anon--generic-handles
  '("info" "admin" "hello" "support" "noreply" "no-reply" "contact" "careers"
    "jobs" "team" "sales" "mail" "office" "help" "billing" "notifications"))

(define (anon--learn-handle! h)
  (let ((h (string-downcase h)))
    (when (and (>= (string-length h) 4)
               (not (member h anon--generic-handles))
               (not (member h anon-handles)))
      (customize-set! 'anon-handles (cons h anon-handles))
      (debounce! "anon:save" 2000 anon--save! #f))))

(define (anon--handle-pattern)
  (and (pair? anon-handles)
       (string-append "(?i)(?<![\\p{L}\\p{N}_])(?:"
                      (string-join (map regexp-quote anon-handles) "|")
                      ")(?![\\p{L}\\p{N}_])")))

(define (anon--hard-spans text)
  "(START END \"\") for each email in TEXT and each known handle outside one"
  (let ((emails (anon--emails text)))
    (for-each (lambda (e) (anon--learn-handle! (car (string-split (substring-bytes text (car e) (cadr e)) "@"))))
              emails)
    (let ((p (anon--handle-pattern)))
      (if p
          (append emails (anon--outside emails (map (lambda (r) (list (car r) (cadr r) "")) (re-find* p text))))
          emails))))

(define (anon--redact-string s hide)
  "S with a bar of the same width over each email and each word in HIDE"
  (let* ((emails (anon--hard-spans s))
         (words (anon--outside emails (filter (lambda (sp) (member (caddr sp) hide)) (anon--spans s)))))
    (let loop ((rs (reverse (sort (append emails words)))) (acc s))
      (if (null? rs)
          acc
          (let ((a (car (car rs))) (b (cadr (car rs))))
            (loop (cdr rs)
                  (string-append (substring-bytes acc 0 a)
                                 (string-repeat "█" (string-length (substring-bytes acc a b)))
                                 (substring-bytes acc b (string-byte-length acc)))))))))

(define (anon--tree-map f tree)
  "TREE with F applied to each text string; the value of a key in anon--tree-keys stays"
  (cond ((string? tree) (f tree))
        ((pair? tree)
         (if (and (symbol? (car tree)) (member (car tree) anon--tree-keys) (pair? (cdr tree)))
             (cons (car tree) (cons (cadr tree) (anon--tree-map f (cddr tree))))
             (cons (anon--tree-map f (car tree)) (anon--tree-map f (cdr tree)))))
        (else tree)))

(define (anon--tree-text tree)
  "every text string of TREE, one to a line"
  (let ((acc '()))
    (anon--tree-map (lambda (s) (set! acc (cons s acc)) s) tree)
    (string-join (reverse acc) "\n")))

(define (anon--redact-tree tree)
  "TREE with every capitalized word that is not a known common word barred; the
common words are sorted once per tree, not once per string"
  (let* ((text (anon--tree-text tree))
         (hide (let loop ((rs (anon--redacted (anon--spans text) anon-common-words)) (acc '()))
                 (if (null? rs) acc
                     (let ((w (substring-bytes text (car (car rs)) (cadr (car rs)))))
                       (loop (cdr rs) (if (member w acc) acc (cons w acc))))))))
    (anon--tree-map (lambda (s) (anon--redact-string s hide)) tree)))

(define (anon--view-original buf)
  "the tree the mode wrote last, or #f"
  (let ((cur (buffer-local buf 'render-blocks))
        (saved (buffer-local buf 'anon-render-blocks)))
    (cond ((not (and (pair? cur) (equal? (buffer-local buf 'render-mode) "blocks"))) #f)
          ((and (pair? saved) (equal? cur (cadr saved))) (car saved))
          (else cur))))

(define *anon-writing* #f)

(define (anon--write-view! buf plist)
  "set PLIST past anon's own advice"
  (set! *anon-writing* #t)
  (ignore-errors (lambda () (buffer-set-locals! buf plist)))
  (set! *anon-writing* #f))

(define (anon--view-plist buf tree)
  (let ((red (anon--redact-tree tree)))
    (list 'anon-render-blocks (list tree red) 'render-blocks red)))

(define (anon--title-redraw! buf)
  "rebuild BUF's mode line; its title passes through anon on the way"
  (ignore-errors (lambda () (dashboard--render! buf))))

(define (anon-view-redact! buf)
  "(anon-view-redact! BUF) - redact BUF's block view and title again from what its mode wrote"
  (when (buffer-exists? buf)
    (let ((tree (anon--view-original buf)))
      (when tree
        (anon--write-view! buf (anon--view-plist buf tree))))
    ;; the mode counts as on only after its setup returns: redraw after
    (debounce! (string-append "anon-title:" buf) 0 anon--title-redraw! buf)))

(define (anon--view-restore! buf)
  (when (buffer-exists? buf)
    (let ((tree (anon--view-original buf)))
      (when tree
        (anon--write-view! buf (list 'render-blocks tree 'anon-render-blocks #f))))
    ;; the mode still counts as on while its teardown runs: redraw after
    (debounce! (string-append "anon-title:" buf) 0 anon--title-redraw! buf)))

(define (anon--render-key? key)
  (or (equal? key 'render-blocks) (equal? key "render-blocks")))

;; A buffer's title reaches the mode line as these locals. Only the words of
;; the buffer's own name are barred in them, so the mode, group and preset
;; around the name stay readable.
(define anon--title-keys '(modeline-name modeline-name-segments dashboard-line-blocks))

(define (anon--key key)
  (if (string? key) (string->symbol key) key))

(define (anon--title-hide buf)
  "the words of BUF's name to bar"
  (map (lambda (r) (substring-bytes buf (car r) (cadr r)))
       (anon--redacted (anon--spans buf) anon-common-words)))

(define (anon--rewrite buf plist)
  "PLIST with the view and the title redacted, and the view's original kept"
  (let ((hide (anon--title-hide buf)))
    (let loop ((xs plist) (acc '()))
      (cond ((or (null? xs) (null? (cdr xs))) (reverse acc))
            ((and (anon--render-key? (car xs)) (pair? (cadr xs)))
             (loop (cddr xs) (append (reverse (anon--view-plist buf (cadr xs))) acc)))
            ((and (member (anon--key (car xs)) anon--title-keys) (pair? hide))
             (loop (cddr xs)
                   (cons (anon--tree-map (lambda (s) (anon--redact-string s hide)) (cadr xs))
                         (cons (car xs) acc))))
            (else (loop (cddr xs) (cons (cadr xs) (cons (car xs) acc))))))))

(define (anon--watched? plist)
  (let loop ((xs plist))
    (and (pair? xs) (pair? (cdr xs))
         (or (anon--render-key? (car xs))
             (member (anon--key (car xs)) anon--title-keys)
             (loop (cddr xs))))))

(define (anon--intercept! buf plist)
  (anon--write-view! buf (anon--rewrite buf plist))
  (when (anon--render-key? (car plist))
    (debounce! (string-append "anon:" buf) 500 anon-ask! buf)))

(define (anon--set-local next buf key val)
  (if (and (not *anon-writing*) (anon--watched? (list key val)) (minor-mode-on? buf "anon-local-mode"))
      (anon--intercept! buf (list key val))
      (next buf key val)))

(define (anon--set-locals next buf plist)
  (if (and (not *anon-writing*) (anon--watched? plist) (minor-mode-on? buf "anon-local-mode"))
      (begin
        (anon--intercept! buf plist)
        (when (plist-get plist 'render-blocks)
          (debounce! (string-append "anon:" buf) 500 anon-ask! buf)))
      (next buf plist)))

(define (anon--advise!)
  (advice-add! 'buffer-set-local! 'around 'anon anon--set-local)
  (advice-add! 'buffer-set-locals! 'around 'anon anon--set-locals))

(define (anon--unadvise!)
  (advice-remove! 'buffer-set-local! 'anon)
  (advice-remove! 'buffer-set-locals! 'anon))

;; jit-lock calls this with whole lines START..END that a window draws. It
;; paints those lines and asks decide about their new words. A block view
;; draws no lines, so it never comes here.
(define (anon--fontify buf start end)
  (when (or *anon-global* (minor-mode-on? buf "anon-local-mode"))
    ;; the version first: an edit after it makes the paint below go nowhere
    (let* ((version (buffer-version buf))
           (text (buffer-substring start end))
           (emails (anon--hard-spans text))
           (spans (anon--spans text))
           (shift (lambda (r) (list (+ start (car r)) (+ start (cadr r)) "anon-redacted"))))
      (overlay-set-range! buf 'anon start end
        (map shift (append (map (lambda (e) (list (car e) (cadr e))) emails)
                           (anon--outside emails (anon--redacted spans anon-common-words))))
        version)
      (anon--ask-text! text spans))))

;; Only a buffer in a window of a frame with a client gets the mode from
;; anon-mode. A frame with no client keeps its windows, and nobody sees them.
(define (anon--visible)
  (let loop ((rows (window-list-all)) (acc '()))
    (cond ((null? rows) (reverse acc))
          ((member (cadr (car rows)) acc) (loop (cdr rows) acc))
          ((= (frame-clients (caddr (car rows))) 0) (loop (cdr rows) acc))
          (else (loop (cdr rows) (cons (cadr (car rows)) acc))))))

(define (anon--buffers)
  (filter (lambda (b) (minor-mode-on? b "anon-local-mode")) (buffer-list)))

;; New answers change what is barred: every drawn line paints again, and
;; every block view redacts again. jit-lock repaints only drawn lines.
(define (anon--refresh!)
  (for-each (lambda (b) (jit-lock-refontify! b) (anon-view-redact! b)) (anon--buffers)))

;; the caches reach custom.scm once a burst of answers settles
(define (anon--save! _)
  (customize-save! 'anon-proper-nouns anon-proper-nouns)
  (customize-save! 'anon-common-words anon-common-words)
  (customize-save! 'anon-handles anon-handles))

(define (anon--learn! answers asked)
  "record decide's ANSWERS for ASKED, a list of (KEY WORD), and repaint"
  (let loop ((rows asked) (proper '()) (common '()))
    (if (pair? rows)
        (let* ((hit (assoc (car (car rows)) answers))
               (word (cadr (car rows)))
               (p (and hit (plist-get (cadr hit) 'noul))))
          (cond ((not (number? p)) (loop (cdr rows) proper common))
                ((>= p 0.5) (loop (cdr rows) (cons word proper) common))
                (else (loop (cdr rows) proper (cons word common)))))
        (let ((words (map cadr asked)))
          (set! *anon-pending* (filter (lambda (w) (not (member w words))) *anon-pending*))
          (when (pair? proper)
            (customize-set! 'anon-proper-nouns (append proper anon-proper-nouns)))
          (when (pair? common)
            (customize-set! 'anon-common-words (append common anon-common-words))
            (anon--refresh!))
          (when (or (pair? proper) (pair? common))
            (debounce! "anon:save" 2000 anon--save! #f))))))

(define (anon--asked chunk)
  (let loop ((xs chunk) (i 0) (acc '()))
    (if (null? xs) (reverse acc)
        (loop (cdr xs) (+ i 1)
              (cons (list (string->symbol (string-append "w" (number->string i)))
                          (car (car xs)) (cadr (car xs)))
                    acc)))))

;; one decide call at a time: the next chunk goes when the last answers
(define (anon--ask-chunks! chunks)
  (when (pair? chunks)
    (let* ((asked (anon--asked (car chunks)))
           (questions (apply append (map (lambda (a) (list (car a) (anon--question (cadr a) (caddr a))))
                                         asked))))
      (decide-async "Decide which capitalized words name a person or a company." questions
        (lambda (reply)
          (anon--learn! (or (plist-get reply 'answers) '())
                        (map (lambda (a) (list (car a) (cadr a))) asked))
          (anon--ask-chunks! (cdr chunks)))
        'purpose 'fast))))

;; The first span of each word that no cache and no open question knows.
;; A known word sorts as (WORD 0), before its spans (WORD 1 START END).
(define (anon--fresh spans)
  (let loop ((rows (sort (append (map (lambda (w) (list w 0))
                                      (append anon-proper-nouns anon-common-words *anon-pending*))
                                 (map (lambda (s) (list (caddr s) 1 (car s) (cadr s))) spans))))
             (seen #f) (acc '()))
    (cond ((null? rows) (reverse acc))
          ((equal? (car (car rows)) seen) (loop (cdr rows) seen acc))
          ((equal? (cadr (car rows)) 0) (loop (cdr rows) (car (car rows)) acc))
          (else (loop (cdr rows) (car (car rows))
                      (cons (list (caddr (car rows)) (list-ref (car rows) 3) (car (car rows))) acc))))))

(define (anon--ask-text! text spans)
  "send the words of SPANS in TEXT that no cache and no open question knows to decide"
  (let ((fresh (map (lambda (s) (list (caddr s) (anon--context text (car s) (cadr s))))
                    (anon--fresh spans))))
    (when (pair? fresh)
      (set! *anon-pending* (append (map car fresh) *anon-pending*))
      (anon--ask-chunks! (anon--chunks (reverse fresh) anon-batch-size)))))

(define (anon-ask! buf)
  "(anon-ask! BUF) - send the new words of BUF's name and block view to decide; jit-lock asks for drawn text"
  (when (and (buffer-exists? buf) (minor-mode-on? buf "anon-local-mode"))
    (let* ((view (anon--view-original buf))
           (text (string-append buf "\n" (if view (anon--tree-text view) ""))))
      (when (<= (string-byte-length text) anon-max-bytes)
        (anon--ask-text! text (anon--spans text))))))

(define (anon--setup! buf)
  (jit-lock-register! 'anon--fontify)
  (anon--advise!)
  (anon-view-redact! buf)
  (jit-lock-refontify! buf)
  (debounce! (string-append "anon:" buf) 500 anon-ask! buf))

(define (anon--teardown! buf)
  (when (buffer-exists? buf) (overlay-clear! buf 'anon))
  (anon--view-restore! buf)
  (when (and (not *anon-global*) (null? (remove (lambda (b) (equal? b buf)) (anon--buffers))))
    (jit-lock-unregister! 'anon--fontify)
    (anon--unadvise!)))

(define (anon--eligible? buf)
  (and (string? buf) (not (string-prefix? " " buf))))

;; by name, so a reload of either reaches the registered mode
(register-minor-mode! "anon-local-mode"
  (lambda (buf) (anon--setup! buf))
  (lambda (buf) (anon--teardown! buf)))

(define-command "anon-local-mode" "Toggle proper-noun redaction in this buffer"
  (lambda ()
    (message (if (toggle-minor-mode! "anon-local-mode")
                 "anon-local-mode enabled"
                 "anon-local-mode disabled"))))

;; anon-mode is on: a buffer gets anon-local-mode when a window shows it
(define *anon-global* #f)

;; A window that shows a buffer for the first time gives it the mode, so its
;; name and its block view are redacted too. Text needs no hook: jit-lock
;; asks for each drawn line.
(define (anon--on-display!)
  (when *anon-global*
    (for-each (lambda (b)
                (when (and (anon--eligible? b) (not (minor-mode-on? b "anon-local-mode")))
                  (enable-minor-mode! b "anon-local-mode")))
              (anon--visible))))

(add-hook! 'window-configuration-change-hook 'anon--on-display!)

(define (anon-off!)
  "(anon-off!) - turn redaction off in every buffer and put back what it hid"
  (set! *anon-global* #f)
  (for-each (lambda (b)
              (ignore-errors
                (lambda ()
                  (if (buffer-exists? b)
                      (disable-minor-mode! b "anon-local-mode")
                      (anon--teardown! b)))))
            (anon--buffers))
  ;; anon-mode paints drawn lines of a buffer before the buffer gets the mode
  (for-each (lambda (b) (overlay-clear! b 'anon)) (buffer-list))
  (jit-lock-unregister! 'anon--fontify)
  (anon--unadvise!))

;; One command, and it answers what the user sees: anon on anywhere means
;; this turns it off everywhere. The flag alone could say off while a
;; buffer still redacts, and the toggle then turned it on.
(define-command "anon-mode" "Turn proper-noun redaction on in every buffer a window shows, or off everywhere"
  (lambda ()
    (if (or *anon-global* (pair? (anon--buffers)))
        (begin (anon-off!) (message "anon-mode disabled"))
        (begin
          (set! *anon-global* #t)
          (jit-lock-register! 'anon--fontify)
          (jit-lock-refontify-all!)
          (anon--on-display!)
          (message "anon-mode enabled")))))

(define-command "anon-forget" "Forget every cached name, common word and email handle"
  (lambda ()
    (customize-save! 'anon-proper-nouns '())
    (customize-save! 'anon-common-words '())
    (customize-save! 'anon-handles '())
    (anon--refresh!)
    (for-each anon-ask! (anon--buffers))
    (message "anon: cache cleared")))

(catalog-meta! 'command "anon-mode" 'domain "anon" 'effects '("write" "external"))
(catalog-meta! 'command "anon-local-mode" 'domain "anon" 'effects '("write" "external"))
(catalog-meta! 'command "anon-forget" 'domain "anon" 'effects '("write"))

(public! 'anon-ask!
  "(anon-ask! BUF) - send the new words of BUF's name and block view to decide; jit-lock asks for drawn text")
