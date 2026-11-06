;;; isearch.scm --- incremental search, lazy highlight, hl-line, and replace.
;;;
;;; Emacs's isearch.el and replace.el: C-s searches as you type, the other
;;; matches light up lazily, hl-line marks the current line, and
;;; query-replace walks the matches. Loaded from init.scm.

(domain! 'unknown)
(effects! '(unknown))

;;; --- isearch ---------------------------------------------------------------
;;; ONE search engine (dup #13), two surfaces: C-s/C-r here, evil's
;;; / ? n N in evil.scm. The engine owns the directional find, the wrap
;;; retry, and the incremental loop — capture the origin, re-search from
;;; it on every keystroke, restore it on cancel. The surface owns what a
;;; hit shows, what a miss says, and what RET keeps.
;;;
;;; One search runs at a time, so one variable holds it. The state says
;;; where the next find starts, which way it runs, and how to draw a hit.
;;; C-s and C-r in the minibuffer map move that start past the current
;;; match — the prompt stays open, the way Emacs repeats a search.

;; (search-find q backward from) -> (start end) or #f
(define (search-fold? q)
  ;; case does not count, unless the search text has a capital (Emacs
  ;; search-upper-case)
  (equal? q (string-downcase q)))

(define (search-find q backward from)
  (if backward
      (buffer-search-backward q from (search-fold? q))
      (buffer-search q from (search-fold? q))))

;; miss -> one retry from the far end, and the echo area says so
(define (search-find-wrap q backward from)
  (or (search-find q backward from)
      (let ((m (search-find q backward
                            (if backward (buffer-size (current-buffer)) 0))))
        (when m (message "Search wrapped"))
        m)))

;; the live search, or #f between searches
(define *isearch* #f)
;; the last string searched for. An empty C-s repeats it, as Emacs does.
(define *isearch-last* "")

(define (isearch--set! origin start backward show query match)
  (set! *isearch*
    (list 'origin origin 'start start 'backward backward
          'show show 'query query 'match match)))

(define (isearch--field key) (and *isearch* (plist-get *isearch* key)))

;; one find, drawn by the surface. Call it inside with-window-buffer: the
;; search reads the window's buffer, not the prompt.
(define (isearch--step! q backward from wrap)
  (let ((m (and (not (equal? q ""))
                (if wrap
                    (search-find-wrap q backward from)
                    (search-find q backward from))))
        (origin (isearch--field 'origin))
        (show (isearch--field 'show)))
    (isearch--set! origin from backward show q m)
    (show m q origin)
    m))

;; The loop. SHOW gets (match q origin) on every keystroke — match is #f
;; on a miss and on an empty query. ACCEPT gets (q origin) on RET.
;; CANCEL gets (origin) on C-g, after the point returns to it.
(define (isearch-loop prompt backward show accept cancel)
  (let ((origin (point)))
    (isearch--set! origin origin backward show "" #f)
    (minibuffer-read* prompt '()
      (list (list 'change
              (lambda (q)
                (unless (equal? q "") (set! *isearch-last* q))
                (with-window-buffer
                  (lambda ()
                    (isearch--step! q backward (isearch--field 'start) #f)))))
            (list 'confirm (lambda (q)
                             (set! *isearch* #f)
                             (accept q origin)))
            (list 'cancel (lambda ()
                            (set! *isearch* #f)
                            (goto-char! origin)
                            (cancel origin)))))))

;; C-s again: find the match after this one. The repeat wraps at the end of
;; the buffer, and it can turn the search around — C-r inside a forward
;; search walks back through the same hits.
(define (isearch--repeat! backward)
  (when *isearch*
    (with-window-buffer
      (lambda ()
        (let* ((typed (isearch--field 'query))
               (q (if (equal? typed "") *isearch-last* typed))
               (m (isearch--field 'match))
               (turn (not (equal? backward (isearch--field 'backward))))
               (from (cond ((not m) (if backward (buffer-size (current-buffer)) 0))
                           ;; a turn reads THIS match again from the other side
                           (turn (if backward (cadr m) (car m)))
                           (backward (car m))
                           (else (+ (car m) 1)))))
          (if (equal? q "")
              (message "No previous search")
              (begin
                ;; the prompt shows the string it repeats
                (when (equal? typed "") (minibuffer-input! q))
                ;; the surface says what a hit and a miss look like
                (isearch--step! q backward from #t))))))))

(define-command "isearch-repeat-forward" "During a search, move to the next match"
  (lambda () (isearch--repeat! #f)))
(define-command "isearch-repeat-backward"
  "During a search, move to the previous match"
  (lambda () (isearch--repeat! #t)))

(catalog-meta! 'command "isearch-repeat-forward" 'domain 'targets 'effects '(write))
(catalog-meta! 'command "isearch-repeat-backward" 'domain 'targets 'effects '(write))
(domain! 'unknown)
(effects! '(unknown))

;;; --- lazy highlight -------------------------------------------------------
;;; Emacs paints every other match of the search in lazy-highlight and the
;;; current one in isearch, so the reader sees where C-s will go next.
;;; The paint is an overlay tag of its own, cleared when the search ends.

(define isearch-lazy-highlight-max 300)

;; every (START END) of Q in the buffer, at most the limit, in order
(define (isearch-matches q)
  (if (equal? q "")
      '()
      (let loop ((from 0) (acc '()) (n 0))
        (let ((m (and (< n isearch-lazy-highlight-max) (buffer-search q from (search-fold? q)))))
          (if (or (not m) (<= (cadr m) (car m)))
              (reverse acc)
              (loop (cadr m) (cons m acc) (+ n 1)))))))

(define (isearch--paint! q m)
  (overlay-set! (current-buffer) 'isearch
    (map (lambda (r)
           (list (car r) (cadr r)
                 (if (and m (equal? r m)) "isearch" "lazy-highlight")))
         (isearch-matches q))))

(define (isearch--unpaint!)
  (overlay-set! (current-buffer) 'isearch '()))

;; Emacs surface: the current match is the region (mark at one end, point
;; at the other), the other matches wear lazy-highlight, a miss says so,
;; RET keeps the point and drops the region.
(define (isearch backward)
  (isearch-loop (if backward "I-search backward: " "I-search: ") backward
    (lambda (m q origin)
      ;; the LIVE direction, not the one this search started with: C-r
      ;; inside a forward search turns it around, and the point must land
      ;; at the end the reader now moves toward
      (let ((back (isearch--field 'backward)))
        (isearch--paint! q m)
        (cond ((equal? q "") (set-mark! #f) (goto-char! origin))
              (m (if back
                     (begin (set-mark! (cadr m)) (goto-char! (car m)))
                     (begin (set-mark! (car m)) (goto-char! (cadr m)))))
              (else (message (string-append "Failing I-search: " q))))))
    (lambda (q origin) (with-window-buffer isearch--unpaint!) (set-mark! #f))
    (lambda (origin) (with-window-buffer isearch--unpaint!) (set-mark! #f))))
(domain! 'unknown)
(effects! '(unknown))

;;; --- hl-line-mode ------------------------------------------------------------
;;; The page highlights the line point is on. Emacs makes that a minor
;;; mode; here it is on by default, and the mode turns it off and on for
;;; one buffer. The local reads "off" when it is off: a local holding #f
;;; reads as absent.

(define (hl-line-on? buf)
  (not (equal? (buffer-local buf 'hl-line-mode) "off")))

(define-command "hl-line-mode" "Toggle the highlight of the current line in this buffer"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (hl-line-on? buf)
          (begin (buffer-set-local! buf 'hl-line-mode "off") (message "hl-line-mode off"))
          (begin (buffer-set-local! buf 'hl-line-mode "on") (message "hl-line-mode on"))))))
(domain! 'unknown)
(effects! '(unknown))

;;; --- replace ---------------------------------------------------------------
;;; Replacement uses the same literal search primitive as isearch. Collect
;;; matches before editing, then apply them from right to left so byte
;;; positions stay valid when the replacement has a different length.

(define (replace--matches buf old from acc)
  (let ((m #f))
    (with-current-buffer buf (lambda () (set! m (buffer-search old from))))
    (if m
        (replace--matches buf old (cadr m) (cons m acc))
        (reverse acc))))

(define (replace--all! buf old new from)
  (if (equal? old "")
      0
      (let ((matches (replace--matches buf old from '())))
        (for-each
          (lambda (m)
            (buffer-replace-range! buf (car m)
                                   (- (cadr m) (car m)) new))
          (reverse matches))
        (length matches))))

(define (replace--prompt prompt k)
  (minibuffer-read* prompt '()
    (list (list 'confirm k)
          (list 'cancel (lambda () (message "Quit"))))))

(define (replace--read-new buf old prompt k)
  (replace--prompt prompt k))

(define-command "replace-string" "Replace every literal occurrence of text"
  (lambda ()
    (let ((buf (current-buffer)))
      (replace--prompt "Replace string: "
        (lambda (old)
          (if (equal? old "")
              (message "Replace string cannot be empty")
              (replace--read-new buf old "Replace string with: "
                (lambda (new)
                  (let ((n 0))
                    (with-invoking-buffer
                      (lambda () (set! n (replace--all! buf old new 0))))
                    (message (string-append "Replaced "
                      (number->string n)
                      (if (= n 1) " occurrence" " occurrences"))))))))))))

;; The match at hand wears isearch, the matches still ahead lazy-highlight,
;; as Emacs draws them.
(define (replace--show! buf old m)
  (overlay-set! buf 'query-replace
    (cons (list (car m) (cadr m) "isearch")
          (map (lambda (r) (list (car r) (cadr r) "lazy-highlight"))
               (replace--matches buf old (cadr m) '())))))

;; While the search text is typed, its matches from point on light up, so
;; they are in view before the replacement is asked for.
(define (replace--preview! buf old from)
  (let ((ms (if (equal? old "") '() (replace--matches buf old from '()))))
    (if (null? ms)
        (overlay-clear! buf 'query-replace)
        (replace--show! buf old (car ms)))))

(define (replace--goto! buf pos)
  (buffer-goto! buf pos)
  (let ((w (window-showing buf)))
    (when w (window-set-point! w pos))))

;; The answers Emacs gives a match: y replaces it, n skips it, ! replaces it
;; and every one after, and q, RET or C-g stops.
(define (replace--ask prompt yes no all quit)
  (let ((answer (lambda (k) (lambda () (minibuffer-detach!) (k)))))
    (minibuffer-read* (string-append prompt "(y, n, ! all, q stop) ") '()
      (list (list 'change (lambda (input)
                            (cond ((string-suffix? "y" input) ((answer yes)))
                                  ((string-suffix? "n" input) ((answer no)))
                                  ((string-suffix? "!" input) ((answer all)))
                                  ((string-suffix? "q" input) ((answer quit)))
                                  (else (minibuffer-input! "")))))
            (list 'confirm (lambda (v) (quit)))
            (list 'cancel quit)
            (list 'style "question")))))

(define-command "query-replace" "Replace literal text with confirmation"
  (lambda ()
    ;; every search, move and replace is in BUF, the buffer the command
    ;; started in: the minibuffer's invoking buffer can be another one
    (let* ((buf (current-buffer)) (origin (point))
           (quit (lambda () (overlay-clear! buf 'query-replace) (message "Quit"))))
      (minibuffer-read* "Query replace: " '()
        (list
          (list 'change (lambda (input) (replace--preview! buf input origin)))
          (list 'cancel quit)
          (list 'confirm
        (lambda (old)
          (if (equal? old "")
              (begin (overlay-clear! buf 'query-replace)
                     (message "Query replace cannot search for an empty string"))
              (minibuffer-read* "Query replace with: " '()
                (list
                  (list 'cancel quit)
                  (list 'confirm
                (lambda (new)
                  (let* ((done (lambda (n)
                                 (overlay-clear! buf 'query-replace)
                                 (message (string-append "Replaced " (number->string n)
                                                         (if (= n 1) " occurrence" " occurrences"))))))
                    (let loop ((from origin) (n 0))
                      (let ((m (with-current-buffer buf (lambda () (buffer-search old from)))))
                        (if (not m)
                            (done n)
                            (begin
                              (replace--show! buf old m)
                              (replace--goto! buf (car m))
                              (replace--ask
                                (string-append "Replace " old " with " new "? ")
                                (lambda ()
                                  (buffer-replace-range! buf (car m) (- (cadr m) (car m)) new)
                                  (loop (+ (car m) (string-byte-length new)) (+ n 1)))
                                (lambda () (loop (cadr m) n))
                                (lambda ()
                                  (buffer-replace-range! buf (car m) (- (cadr m) (car m)) new)
                                  (done (+ n 1 (replace--all! buf old new (+ (car m) (string-byte-length new))))))
                                (lambda () (done n))))))))))))))))))))

(catalog-meta! 'command "replace-string" 'domain 'editing 'effects '(write))
(catalog-meta! 'command "query-replace" 'domain 'editing 'effects '(write))

(domain! 'unknown)
(effects! '(unknown))

;;; --- the public API of this file ----------------------------------------------
;;; The catalog scope of each entry is the one it had in editor.scm.

(domain! 'unknown)
(effects! '(unknown))
(category! 'commands)
(public! 'isearch-matches "(isearch-matches Q) — every (START END) of Q in the current buffer, up to isearch-lazy-highlight-max")
(public! 'hl-line-on? "(hl-line-on? BUF) — #t unless hl-line-mode turned the line highlight off in BUF")

(domain! 'unknown)
(effects! '(unknown))
