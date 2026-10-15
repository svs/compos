;;; anon.scm --- anon-mode: redact proper nouns for a screencast.
;;;
;;; Every capitalized word on the lines a window draws is painted as a
;;; bar. jit-lock hands anon only those lines, so a hidden buffer and the
;;; off-screen part of a large buffer cost nothing. decide says which
;;; words name a person, and the others come back into view.
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

(defcustom 'anon-cache-size 2000
  "The words each cache keeps. A cache drops the words it used least recently."
  'group 'anon 'type 'integer)

(defcustom 'anon-batch-size 40
  "The words one decide call judges."
  'group 'anon 'type 'integer)

(defcustom 'anon-max-bytes 2000000
  "A buffer past this size is redacted but never sent to decide."
  'group 'anon 'type 'integer)

(defface! 'anon-redacted 'fg "var(--default-fg)" 'bg "var(--default-fg)" 'priority 100)

;; a capitalized word: an uppercase letter, then letters. It stands alone:
;; capitals inside an identifier or an id, as in toolu_01DyVkHSu4g, are no word.
;; One space joins the words of a name; more is layout, as in a tab strip
(define anon--word-pattern "(?<![\\p{L}\\p{N}_])\\p{Lu}[\\p{L}\\p{M}]*(?: \\p{Lu}[\\p{L}\\p{M}]*)*(?![\\p{L}\\p{M}\\p{N}_])")

;; one capitalized word of a run
(define anon--one-word-pattern "\\p{Lu}[\\p{L}\\p{M}]*")

;; words sent to decide and not yet answered
(define *anon-pending* '())

;; anon works only on a buffer a window of a frame with a client shows
(define (anon--shown? buf) (and (member buf (anon--visible)) #t))

;; #t from an answer of decide until the next refresh redacts each view again
(define *anon-stale* #f)

;; cached words a paint used since the last prune, most recent first
(define *anon-touched* '())

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

(define (anon--merge rs)
  "sorted (START END) ranges with each overlap joined: a handle inside a run is one bar"
  (let loop ((rs rs) (acc '()))
    (cond ((null? rs) (reverse acc))
          ((and (pair? acc) (<= (car (car rs)) (cadr (car acc))))
           (loop (cdr rs) (cons (list (car (car acc)) (max (cadr (car acc)) (cadr (car rs)))) (cdr acc))))
          (else (loop (cdr rs) (cons (list (car (car rs)) (cadr (car rs))) acc))))))

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
    (string-append "Is '" word "' a person's name here, or does it contain one? "
                   "The name of a company, product, service, technology, place or project is not: OpenAI, AWS, GitHub, Kubernetes and Postgres are not. "
                   "Words capitalized only because they start a sentence or a heading are not. "
                   "Context: "
                   context)))

(effects! '(write))

;; The spans to paint. The spans sort by word, so each distinct word asks
;; the native member one time. A sort-merge against the caches walked
;; every cached word in Scheme on each paint, and the caches grow without
;; bound.
(define (anon--redacted spans common)
  (let loop ((rows (sort (map (lambda (s) (list (caddr s) (car s) (cadr s))) spans)))
             (word #f) (skip #f) (acc '()))
    (cond ((null? rows) acc)
          ((not (equal? (car (car rows)) word))
           (let ((hit (and (member (car (car rows)) common) #t)))
             (when hit (anon--touch! (car (car rows))))
             (loop rows (car (car rows)) hit acc)))
          (skip (loop (cdr rows) word skip acc))
          (else (loop (cdr rows) word skip
                      (cons (list (cadr (car rows)) (caddr (car rows)) "anon-redacted") acc))))))

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
               (not (member h anon--generic-handles)))
      (if (member h anon-handles)
          (anon--touch! h)
          (begin
            (customize-set! 'anon-handles (cons h anon-handles))
            (debounce! "anon:prune" 2000 anon--prune! #f))))))

(define (anon--name-parts)
  "the words of the known names, four letters or more, lowercased"
  (filter (lambda (w) (>= (string-length w) 4))
          (map string-downcase (apply append (map (lambda (n) (string-split n " ")) anon-proper-nouns)))))

(define (anon--learn-name-handles! text)
  "learn as a handle each lowercase token with a digit, dot or underscore that holds a known name"
  (let ((parts (anon--name-parts)))
    (when (pair? parts)
      (for-each (lambda (r)
                  (let ((tok (substring-bytes text (car r) (cadr r))))
                    (when (and (pair? (re-find* "[0-9._]" tok))
                               (pair? (filter (lambda (p) (string-contains? tok p)) parts)))
                      (anon--learn-handle! tok))))
                (re-find* "(?<![\\p{L}\\p{N}_@.])[a-z0-9][a-z0-9._-]*[a-z0-9](?![\\p{L}\\p{N}_@])" text)))))

(define (anon--handle-pattern)
  (and (pair? anon-handles)
       (string-append "(?i)(?<![\\p{L}\\p{N}_])(?:"
                      (string-join (map regexp-quote anon-handles) "|")
                      ")(?![\\p{L}\\p{N}_])")))

;; a name the decide called proper bars in any case: a page may print it lowercased
(define *anon-name-pattern* (list #f #f #f))

(define (anon--name-pattern)
  "one case-blind pattern for every known name and each word of a name of two or more"
  ;; a one-word guess such as Jobs stays case-bound: lowercased it is a common word
  ;; a part that is a known common word bars nothing alone: History of a misjudged run
  (if (and (eq? (car *anon-name-pattern*) anon-proper-nouns)
           (eq? (caddr *anon-name-pattern*) anon-common-words))
      (cadr *anon-name-pattern*)
      (let* ((parts (apply append (map (lambda (n) (let ((ps (string-split n " "))) (if (pair? (cdr ps)) ps '())))
                                       anon-proper-nouns)))
             (full (filter (lambda (n) (pair? (cdr (string-split n " ")))) anon-proper-nouns))
             (ws (append full (filter (lambda (w) (and (>= (string-length w) 3) (not (member w anon-common-words))))
                                      parts)))
             (p (and (pair? ws)
                     (string-append "(?i)(?<![\\p{L}\\p{N}_])(?:"
                                    (string-join (map regexp-quote ws) "|")
                                    ")(?![\\p{L}\\p{N}_])"))))
        (set! *anon-name-pattern* (list anon-proper-nouns p anon-common-words))
        p)))

(define (anon--hard-spans text)
  "(START END \"\") for each email in TEXT and each known handle outside one"
  (let ((emails (anon--emails text)))
    (anon--learn-name-handles! text)
    (for-each (lambda (e) (anon--learn-handle! (car (string-split (substring-bytes text (car e) (cadr e)) "@"))))
              emails)
    (let ((p (anon--handle-pattern)))
      (if p
          (let ((hits (anon--outside emails (map (lambda (r) (list (car r) (cadr r) "")) (re-find* p text)))))
            (for-each (lambda (r) (anon--touch! (string-downcase (substring-bytes text (car r) (cadr r))))) hits)
            (append emails hits (anon--name-hits text emails)))
          (append emails (anon--name-hits text emails))))))

(define (anon--name-hits text emails)
  (let ((p (anon--name-pattern)))
    (if p
        (anon--outside emails (map (lambda (r) (list (car r) (cadr r) "")) (re-find* p text)))
        '())))

(define (anon--redact-string s hide)
  "S with a bar of the same width over each email and each word in HIDE"
  (let* ((emails (anon--hard-spans s))
         (words (anon--outside emails (filter (lambda (sp) (member (caddr sp) hide)) (anon--spans s)))))
    (let loop ((rs (reverse (anon--merge (sort (map (lambda (r) (list (car r) (cadr r))) (append emails words)))))) (acc s))
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

(define (anon--tree-map-until done? f tree)
  "anon--tree-map, which returns the rest of TREE as it is once DONE? answers #t"
  (cond ((done?) tree)
        ((string? tree) (f tree))
        ((pair? tree)
         (if (and (symbol? (car tree)) (member (car tree) anon--tree-keys) (pair? (cdr tree)))
             (cons (car tree) (cons (cadr tree) (anon--tree-map-until done? f (cddr tree))))
             (let ((a (anon--tree-map-until done? f (car tree))))
               (cons a (anon--tree-map-until done? f (cdr tree))))))
        (else tree)))

(define (anon--tree-strings tree)
  "every text string of TREE, last first, in the order anon--tree-map visits them"
  (let walk ((t tree) (acc '()))
    (cond ((string? t) (cons t acc))
          ((pair? t)
           (if (and (symbol? (car t)) (member (car t) anon--tree-keys) (pair? (cdr t)))
               (walk (cddr t) acc)
               (walk (cdr t) (walk (car t) acc))))
          (else acc))))

(define (anon--tree-text tree)
  "every text string of TREE, one to a line"
  (string-join (reverse (anon--tree-strings tree)) "\n"))

(define (anon--bar-ranges s ranges)
  "S with a bar of the same width over each (START END) of RANGES, sorted, in byte offsets"
  ;; ranges can overlap (two spans that start at one byte): a range bars only
  ;; what the one before it left
  (let loop ((rs ranges) (at 0) (acc '()))
    (if (null? rs)
        (apply string-append (reverse (cons (substring-bytes s at (string-byte-length s)) acc)))
        (let ((a (max at (car (car rs)))) (b (cadr (car rs))))
          (if (<= b a)
              (loop (cdr rs) at acc)
              (loop (cdr rs) b
                    (cons (string-repeat "█" (string-length (substring-bytes s a b)))
                          (cons (substring-bytes s at a) acc))))))))

;; One scan of the tree's text finds every email, handle and capitalized
;; run. Each string then takes only the ranges that fall in it, and a
;; string with none comes back as it was. A scan per string cost 0.9 s
;; on a chat of 2700 strings.
(define (anon--redact-tree tree)
  "TREE with every email, known handle and capitalized run that is not common barred"
  (let* ((text (anon--tree-text tree))
         (emails (anon--hard-spans text))
         (words (anon--outside emails (anon--redacted (anon--spans text) anon-common-words)))
         (rs (anon--merge (sort (append (map (lambda (e) (list (car e) (cadr e))) emails)
                                         (map (lambda (w) (list (car w) (cadr w))) words)))))
         (pos 0))
    (if (null? rs)
        tree
        (anon--tree-map-until (lambda () (null? rs))
      (lambda (s)
        (let ((start pos) (end (+ pos (string-byte-length s))))
          (set! pos (+ end 1))
          (let loop ((mine '()))
            (if (and (pair? rs) (< (car (car rs)) end))
                (let ((r (car rs)))
                  (set! rs (cdr rs))
                  (loop (if (>= (car r) start)
                            (cons (list (- (car r) start) (- (min (cadr r) end) start)) mine)
                            mine)))
                (if (null? mine) s (anon--bar-ranges s (reverse mine)))))))
      tree))))

(define (anon--view-original buf)
  "the tree the mode wrote last, or #f"
  (let ((cur (buffer-local buf 'render-blocks))
        (saved (buffer-local buf 'anon-render-blocks)))
    (cond ((not (and (pair? cur) (equal? (buffer-local buf 'render-mode) "blocks"))) #f)
          ((and (pair? saved) (equal? cur (cadr saved))) (car saved))
          ((pair? saved) (anon--unredact cur (cadr saved) (car saved)))
          (else cur))))

;; a mode may build its next tree from the one it shows, the redacted one: each
;; part of that tree that is still as anon wrote it goes back to the original,
;; or the bars become the original and never lift
(define (anon--unredact new red orig)
  "NEW with each part it shares with RED, the redaction of ORIG, as ORIG has it"
  (cond ((equal? new red) orig)
        ((and (pair? new) (pair? red) (pair? orig))
         (cons (anon--unredact (car new) (car red) (car orig))
               (anon--unredact (cdr new) (cdr red) (cdr orig))))
        (else new)))

(define *anon-writing* #f)

(define (anon--write-view! buf plist)
  "set PLIST past anon's own advice"
  (set! *anon-writing* #t)
  (ignore-errors (lambda () (buffer-set-locals! buf plist)))
  (set! *anon-writing* #f))

;; A mode writes its whole view again for each change: a chat for each
;; streamed line, a player for each tick. Most of the tree is the tree it
;; wrote last time. The walk below takes the saved redaction of each part
;; that is equal to the part it replaces, and redacts only the parts that
;; changed: a chat of 70 KB cost 1 s a write when anon redacted it whole.
;; The text of the changed parts is the text decide has not seen.

;; the text of each part redacted in this walk, last first
(define *anon-new-text* '())

(define (anon--redact-part tree)
  (let ((text (anon--tree-text tree)))
    (unless (equal? text "")
      (set! *anon-new-text* (cons text *anon-new-text*))))
  (anon--redact-tree tree))

(define (anon--redact-like new old red)
  "NEW redacted, with RED, the redaction of OLD, for each part NEW shares with OLD"
  (cond ((equal? new old) red)
        ((and (pair? new) (pair? old) (pair? red)) (anon--redact-list new old red))
        (else (anon--redact-part new))))

;; the elements of NEW beside those of OLD and RED; only elements are
;; compared, never a whole tail, so a long list costs one pass
(define (anon--redact-list new old red)
  (cond ((not (pair? new)) (anon--redact-like new old red))
        ((not (and (pair? old) (pair? red))) (anon--redact-part new))
        ((and (symbol? (car new)) (member (car new) anon--tree-keys) (pair? (cdr new)))
         (if (and (equal? (car old) (car new)) (pair? (cdr old)) (pair? (cdr red)))
             (cons (car new) (cons (cadr new) (anon--redact-list (cddr new) (cddr old) (cddr red))))
             (anon--redact-part new)))
        (else (cons (anon--redact-like (car new) (car old) (car red))
                    (anon--redact-list (cdr new) (cdr old) (cdr red))))))

;; text decide is to judge, per buffer: ((BUF TEXT ...) ...)
(define *anon-asks* '())

(define (anon--note-ask! buf texts)
  (when (pair? texts)
    (let ((had (assoc buf *anon-asks*)))
      (set! *anon-asks*
            (cons (cons buf (append texts (if had (cdr had) '())))
                  (filter (lambda (e) (not (equal? (car e) buf))) *anon-asks*))))
    (debounce! (string-append "anon-ask:" buf) 500 anon--ask-noted! buf)))

(define (anon--ask-noted! buf)
  (let ((e (assoc buf *anon-asks*)))
    (set! *anon-asks* (filter (lambda (x) (not (equal? (car x) buf))) *anon-asks*))
    (when (and e (buffer-exists? buf) (anon--shown? buf))
      (let ((text (string-join (cdr e) "\n")))
        (when (<= (string-byte-length text) anon-max-bytes)
          (anon--ask-text! text (anon--spans text)))))))

(define (anon--view-plist buf tree)
  (let* ((saved (buffer-local buf 'anon-render-blocks))
         (tree (if (pair? saved) (anon--unredact tree (cadr saved) (car saved)) tree)))
    (set! *anon-new-text* '())
    ;; an answer of decide changes what is barred: then the whole tree again
    (let ((red (if (and (pair? saved) (not *anon-stale*))
                   (anon--redact-like tree (car saved) (cadr saved))
                   (anon--redact-part tree))))
      (anon--note-ask! buf *anon-new-text*)
      (set! *anon-new-text* '())
      (list 'anon-render-blocks (list tree red) 'render-blocks red))))

(define (anon--title-redraw! buf)
  "rebuild BUF's mode line; its title passes through anon on the way"
  (ignore-errors (lambda () (dashboard--render! buf))))

(define (anon--view-catchup! buf)
  "redact BUF's block view from what its mode wrote, while a window shows BUF"
  ;; a hidden view stays as its mode wrote it: buffer-shown-hook redacts it when it is shown
  (when (and (buffer-exists? buf) (anon--shown? buf))
    (let ((tree (anon--view-original buf)))
      (when tree
        (anon--write-view! buf (anon--view-plist buf tree))))))

(define (anon-view-redact! buf)
  "(anon-view-redact! BUF) - redact BUF's block view and title again from what its mode wrote"
  (when (buffer-exists? buf)
    (anon--view-catchup! buf)
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
            ((and (anon--render-key? (car xs)) (pair? (cadr xs)) (anon--shown? buf))
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
  (anon--write-view! buf (anon--rewrite buf plist)))

(define (anon--set-local next buf key val)
  (cond
    ;; anchor keeps the page it marks as anchor-drawn and marks from it ever
    ;; after: it gets the original, so its marks reach anon unredacted
    ((and (eq? key 'anchor-drawn) (pair? val) (minor-mode-on? buf "anon-local-mode")
          (pair? (buffer-local buf 'anon-render-blocks)))
     (let ((saved (buffer-local buf 'anon-render-blocks)))
       (next buf key (anon--unredact val (cadr saved) (car saved)))))
    (else (anon--set-local-1 next buf key val))))

(define (anon--set-local-1 next buf key val)
  (if (and (not *anon-writing*) (anon--watched? (list key val)) (minor-mode-on? buf "anon-local-mode"))
      (anon--intercept! buf (list key val))
      (next buf key val)))

(define (anon--set-locals next buf plist)
  (if (and (not *anon-writing*) (anon--watched? plist) (minor-mode-on? buf "anon-local-mode"))
      (anon--intercept! buf plist)
      (next buf plist)))

;; The title painter names a buffer with buffer-modeline-name, and so does
;; every other place that shows a buffer as its title, such as the rail of a
;; walk. While anon-mode is on, the name comes back with its words barred.
(define (anon--modeline-name next buf)
  (let ((name (next buf)))
    (if (and (string? name)
             (or *anon-global* (minor-mode-on? buf "anon-local-mode"))
             (pair? (anon--title-hide buf)))
        (anon--redact-string name (anon--title-hide buf))
        name)))

(define (anon--advise!)
  (advice-add! 'buffer-set-local! 'around 'anon anon--set-local)
  (advice-add! 'buffer-set-locals! 'around 'anon anon--set-locals)
  (advice-add! 'buffer-modeline-name 'around 'anon anon--modeline-name))

(define (anon--unadvise!)
  (advice-remove! 'buffer-set-local! 'anon)
  (advice-remove! 'buffer-set-locals! 'anon)
  (advice-remove! 'buffer-modeline-name 'anon))

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
;; Only a shown buffer repaints: a hidden one is marked stale, and
;; anon--catchup! repaints it whole when a window shows it again. Given
;; WORDS, the words an answer unbarred, a shown buffer whose text and view
;; hold none of them stays as it is.
(define (anon--holds-any? buf words)
  (let ((view (anon--view-original buf)))
    (let ((texts (list buf (buffer-text buf) (if view (anon--tree-text view) ""))))
      (let loop ((ws words))
        (and (pair? ws)
             (or (let any ((ts texts))
                   (and (pair? ts) (or (string-contains? (car ts) (car ws)) (any (cdr ts)))))
                 (loop (cdr ws))))))))

(define (anon--refresh! &optional words)
  (let ((shown (anon--visible)))
    (set! *anon-stale* #t)
    (for-each (lambda (b)
                (cond ((not (member b shown)) (buffer-set-local! b 'anon-stale #t))
                      ((or (not words) (anon--holds-any? b words))
                       (jit-lock-refontify! b) (anon-view-redact! b))))
              (anon--buffers))
    (set! *anon-stale* #f)))

;; The caches are LRU. A word a paint uses goes to the front, a new word
;; goes in at the front, and a cache keeps its first anon-cache-size words.
;; A paint only notes the word: the prune reorders once the paints settle.
(define (anon--touch! w)
  (unless (member w *anon-touched*)
    ;; the first touch since a prune sets the timer: a debounce that each
    ;; touch reset never ran while windows painted
    (when (null? *anon-touched*)
      (debounce! "anon:prune" 10000 anon--prune! #f))
    (set! *anon-touched* (cons w *anon-touched*))))

(define (anon--lru cache touched)
  "CACHE with its words in TOUCHED first, cut to anon-cache-size"
  (let ((front (filter (lambda (w) (member w cache)) touched)))
    (take (append front (filter (lambda (w) (not (member w front))) cache)) anon-cache-size)))

(define (anon--prune! _)
  (let ((touched *anon-touched*))
    (set! *anon-touched* '())
    (customize-set! 'anon-proper-nouns (anon--lru anon-proper-nouns touched))
    (customize-set! 'anon-common-words (anon--lru anon-common-words touched))
    (customize-set! 'anon-handles (anon--lru anon-handles touched))))

;; the caches reach custom.scm when anon turns off. A write of custom.scm is a
;; hot reload, and a reload rebuilds every visible buffer: the screen flashes
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
            (anon--refresh! common))
          (when (or (pair? proper) (pair? common))
            (debounce! "anon:prune" 2000 anon--prune! #f))))))

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
      (decide-async "Decide which capitalized words name a person." questions
        (lambda (reply)
          (anon--learn! (or (plist-get reply 'answers) '())
                        (map (lambda (a) (list (car a) (cadr a))) asked))
          (anon--ask-chunks! (cdr chunks)))
        'purpose 'fast))))

;; The first span of each word that no cache and no open question knows.
;; The spans sort by word, so each distinct word asks the native member one time.
(define (anon--known? w)
  (cond ((member w *anon-pending*) #t)
        ((or (member w anon-proper-nouns) (member w anon-common-words)) (anon--touch! w) #t)
        (else #f)))

(define (anon--fresh spans)
  (let loop ((rows (sort (map (lambda (s) (list (caddr s) (car s) (cadr s))) spans)))
             (seen #f) (acc '()))
    (cond ((null? rows) (reverse acc))
          ((equal? (car (car rows)) seen) (loop (cdr rows) seen acc))
          ((anon--known? (car (car rows))) (loop (cdr rows) (car (car rows)) acc))
          (else (loop (cdr rows) (car (car rows))
                      (cons (list (cadr (car rows)) (caddr (car rows)) (car (car rows))) acc))))))

(define (anon--ask-text! text spans)
  "send the words of SPANS in TEXT that no cache and no open question knows to decide"
  (let ((fresh (map (lambda (s) (list (caddr s) (anon--context text (car s) (cadr s))))
                    (anon--fresh spans))))
    (when (pair? fresh)
      (set! *anon-pending* (append (map car fresh) *anon-pending*))
      (anon--ask-chunks! (anon--chunks (reverse fresh) anon-batch-size)))))

(define (anon-ask! buf)
  "(anon-ask! BUF) - send the new words of BUF's name and block view to decide; jit-lock asks for drawn text"
  (when (and (buffer-exists? buf) (anon--shown? buf) (minor-mode-on? buf "anon-local-mode"))
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

;; anon works only on the buffers a window shows, and catches a buffer up
;; when a window shows it, as diff-mode and the mode line do. A buffer new
;; to anon-mode gets the mode. A buffer with the mode redacts the view its
;; mode wrote while it was hidden; an unchanged view reuses its last
;; redaction. Text needs no hook: jit-lock asks for each drawn line.
(define (anon--catchup! buf)
  (cond ((not (anon--shown? buf)) #f)
        ((and (minor-mode-on? buf "anon-local-mode") (buffer-local buf 'anon-stale))
         (buffer-set-local! buf 'anon-stale #f)
         (set! *anon-stale* #t)
         (jit-lock-refontify! buf)
         (anon--view-catchup! buf)
         (set! *anon-stale* #f))
        ((minor-mode-on? buf "anon-local-mode")
         (anon--view-catchup! buf))
        ((and *anon-global* (anon--eligible? buf))
         (enable-minor-mode! buf "anon-local-mode"))))

;; every shown buffer, after any change of the windows
(define (anon--on-display!)
  (for-each anon--catchup! (anon--visible)))

(add-hook! 'buffer-shown-hook 'anon--catchup!)
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
  (anon--unadvise!)
  (anon--prune! #f)
  (anon--save! #f))

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
          (anon--advise!)
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
