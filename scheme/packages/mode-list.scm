;;; mode-list.scm -- the buffers of one major mode, listed by ibuffer
;;;
;;; (mode-list MODE) opens ibuffer over the buffers whose major mode is
;;; MODE. What a list does -- sections, sort, the filter line, the row
;;; preview, RET and q, the frame given back on the way out -- is
;;; ibuffer's. A mode registers only what is its own, with
;;; (mode-list-define! MODE SPEC). SPEC is a plist; every key is optional:
;;;
;;;   'member-locals  buffer-locals the snapshot reads beside mode-name
;;;   'member?        (ROW) whether a snapshot row (NAME MODE-NAME
;;;                   LOCALS...) is listed; the default is its mode
;;;   'recent-limit   (THUNK) how many rows the list shows at rest;
;;;                   a filter reads every one
;;;   'defaults       the resting sort and grouping, as ibuffer-view! takes
;;;   'groupings      ((SYMBOL KEY-OF) ...): sections beyond none, group
;;;                   and directory; KEY-OF names the section of a row
;;;   'extra-rows     (BUF) rows after the buffers, such as saved files
;;;   'text           (NAME) the text a filter also reads, in a task
;;;   'visit-row      (ROW) RET on a row that is no live buffer
;;;   'after-visit    (NAME) after RET showed a buffer
;;;   'opts           ibuffer-mode-opts overrides: doc, title, noun, keys
;;;
;;; chat-list is (mode-list "chat-mode").

(domain! 'buffers)
(effects! '(read))

(define *mode-lists* (if (boundp '*mode-lists*) *mode-lists* '()))

(define (mode-list-spec mode)
  (let ((e (assoc mode *mode-lists*))) (if e (cadr e) '())))

(define (mode-list-opt mode key &optional default)
  (let loop ((ps (mode-list-spec mode)))
    (cond ((or (null? ps) (null? (cdr ps))) default)
          ((equal? (car ps) key) (cadr ps))
          (else (loop (cddr ps))))))

(define (mode-list-base mode)
  (if (string-suffix? "-mode" mode)
      (substring mode 0 (- (string-length mode) 5))
      mode))

(define (mode-list-mode-name mode) (string-append (mode-list-base mode) "-list-mode"))
(define (mode-list-scope-name mode) (string->symbol (string-append (mode-list-base mode) "-list")))
(define (mode-list-buffer-base mode) (string-append "*" (mode-list-base mode) "-list*"))

(define (mode-list-of buf)
  ;; the view says which mode it lists; a prompt over the same list mode
  ;; says it through its list mode
  (or (buffer-local buf 'mode-list-of)
      (let ((lm (list-mode-of buf)))
        (let loop ((ms *mode-lists*))
          (cond ((null? ms) #f)
                ((equal? (mode-list-mode-name (car (car ms))) lm) (car (car ms)))
                (else (loop (cdr ms))))))))

;; ---------------------------------------------------------------------------
;; The buffers

(define (mode-list-buffers mode)
  ;; one snapshot of every buffer, not a buffer-local read per buffer. It
  ;; is read again each time: a buffer can change its mode, or become an
  ;; agent, without the buffer list changing.
  (let* ((names (dedupe-names (append (buffer-list-mru) (buffer-list))))
         (member? (mode-list-opt mode 'member?
                    (lambda (row) (equal? (cadr row) mode))))
         (rows (buffer-read-many names '()
                 (cons "mode-name" (mode-list-opt mode 'member-locals '())))))
    (map car (filter (lambda (row)
                       (and (not (string-prefix? " " (car row)))
                            (member? row)))
                     rows))))

(define (mode-list--blank? q) (equal? (string-trim q) ""))

(define (mode-list-scope mode buf)
  (let ((all (mode-list-buffers mode))
        (limit (mode-list-opt mode 'recent-limit)))
    (if (and limit (mode-list--blank? (list-query buf)))
        (take all (limit))
        all)))

;; ---------------------------------------------------------------------------
;; The rows

(define (mode-list-groupings mode)
  (append '(none group) (map car (mode-list-opt mode 'groupings '()))))

(define (mode-list-rows buf)
  (let* ((mode (mode-list-of buf))
         (keyed (assoc (ibuffer-grouping buf) (mode-list-opt mode 'groupings '())))
         (extra (mode-list-opt mode 'extra-rows))
         (rows (if keyed
                   (let ((source (ibuffer-source buf)))
                     (ibuffer-columns-clear!)
                     (ibuffer-note-kinds! source)
                     (ibuffer-keyed-sections buf source (cadr keyed) (lambda (k) "faint") #f))
                   (ibuffer-rows buf))))
    (if extra (append rows (extra buf)) rows)))

(define (mode-list-regroup! buf)
  (let ((next (ibuffer-cycle-after (ibuffer-grouping buf)
                                   (mode-list-groupings (mode-list-of buf)))))
    (ibuffer-set-grouping! next buf)
    (message (string-append "grouped by " (symbol->string next)))))

;; ---------------------------------------------------------------------------
;; The text a filter reads
;;
;; A word nobody put in a name is looked for in the text of every listed
;; buffer, in a task; the rows it finds join the list when it answers.

(define *mode-list-search* #f)   ; (MODE QUERY ((NAME SNIPPET) ...))
(define *mode-list-texts* '())   ; ((NAME TEXT) ...), read once an open
(define *mode-list-task* #f)
(define *mode-list-generation* 0)

(define (mode-list-hit mode b)
  (and *mode-list-search*
       (equal? (car *mode-list-search*) mode)
       (let ((e (assoc b (list-ref *mode-list-search* 2)))) (and e (cadr e)))))

(define (mode-list--cancel-search!)
  (set! *mode-list-generation* (+ 1 *mode-list-generation*))
  (debounce-cancel! "mode-list-search")
  (when *mode-list-task* (task-cancel! *mode-list-task*))
  (set! *mode-list-task* #f))

(define (mode-list-search-reset!)
  (mode-list--cancel-search!)
  (set! *mode-list-search* #f)
  (set! *mode-list-texts* '()))

(define (mode-list-snippet text at)
  ;; string-index answers in bytes, so the window is in bytes as well
  (let* ((from (max 0 (- at 40)))
         (to (min (string-byte-length text) (+ at 80))))
    (string-join (string-split (substring-bytes text from to) "\n") " ")))

(define (mode-list--scan names text-of q cache)
  (let loop ((rows names) (texts cache) (hits '()))
    (if (null? rows) (list (reverse hits) texts)
        (let* ((b (car rows))
               (memo (assoc b texts))
               (text (if memo (cadr memo) (string-downcase (or (text-of b) ""))))
               (at (string-index text q)))
          (loop (cdr rows)
                (if memo texts (cons (list b text) texts))
                (if at (cons (list b (mode-list-snippet text at)) hits) hits))))))

(define (mode-list-search! buf mode q)
  (let ((text-of (mode-list-opt mode 'text))
        (last *mode-list-search*))
    (when (and text-of
               (not (and last (equal? (car last) mode) (equal? (cadr last) q))))
      (mode-list--cancel-search!)
      ;; old snippets must not stay in cached cells after their query
      (when (and last (pair? (list-ref last 2))) (list-filter-row-forget! buf))
      (set! *mode-list-search* (list mode q '()))
      (when (>= (string-length q) 3)
        (debounce! "mode-list-search" (+ ibuffer-filter-delay-ms 100)
          (lambda (ticket)
            (when (= ticket *mode-list-generation*)
              (let ((names (mode-list-buffers mode)) (cache *mode-list-texts*))
                (set! *mode-list-task*
                  (task-run! (lambda () (mode-list--scan names text-of q cache))
                    (lambda (ok result)
                      (when (and ok (= ticket *mode-list-generation*) (buffer-known? buf))
                        (set! *mode-list-task* #f)
                        (set! *mode-list-texts* (cadr result))
                        (set! *mode-list-search* (list mode q (car result)))
                        ;; text matches add rows the name filter rejected
                        (list-filter-forget! buf)
                        (list-redraw! buf)
                        (ibuffer-preview! buf))))))))
          *mode-list-generation*)))))

(define (mode-list-match? buf row input)
  (if (ibuffer-heading? row)
      (let loop ((members (ibuffer-heading-members row)))
        (and (pair? members)
             (or (mode-list-match? buf (car members) input) (loop (cdr members)))))
      (or (ibuffer-match? buf row input)
          (let ((hit (mode-list-hit (mode-list-of buf) row)))
            (and hit (completion-match? hit input 'substring))))))

(define (mode-list-match-section label key rows)
  (if (null? rows) '()
      (cons (list label "" "match" key (length rows) 0 0 "faint" rows) rows)))

(define (mode-list-rank buf rows)
  ;; a filtered list says why each row is there: its name, what else the
  ;; row says, or its text
  (let* ((mode (mode-list-of buf))
         (q (string-downcase (string-trim (list-query buf)))))
    (mode-list-search! buf mode q)
    ;; a list in sections keeps them; the flat list sorts by the reason
    (if (or (equal? q "") (not (mode-list-opt mode 'text))
            (not (equal? (ibuffer-grouping buf) 'none)))
        rows
        (let split ((rest (filter string? rows)) (names '()) (other '()) (texts '()))
          (cond ((and (null? rest) (null? texts)) rows)
                ;; the reasons are worth a heading once the text found a row
                ((null? rest)
                 (append
                   (mode-list-match-section "Name matches" "match:name" (reverse names))
                   (mode-list-match-section "Other matches" "match:other" (reverse other))
                   (mode-list-match-section "Text matches" "match:text" (reverse texts))))
                (else
                 (let ((b (car rest)))
                   (cond ((completion-match? (ibuffer-row-title b) q 'substring)
                          (split (cdr rest) (cons b names) other texts))
                         ((ibuffer-match? buf b q)
                          (split (cdr rest) names (cons b other) texts))
                         (else (split (cdr rest) names other (cons b texts)))))))))))

;; ---------------------------------------------------------------------------
;; The list mode

(define (mode-list-opts mode)
  (ibuffer-mode-opts
    (append
      (list
        'transient #f
        'doc (string-append
               "Every buffer in " mode ", as ibuffer lists buffers. "
               "< cycles what a section is (none, group, and what the mode adds), > the order inside one, and t turns "
               "the sections off and on. f filters; a word in no name is looked "
               "for in the text. RET shows the buffer at point, g reads the "
               "buffers again, and q gives the frame back.")
        'title (lambda (buf) (mode-label mode))
        'rows (lambda (buf) (mode-list-rows buf))
        'match (lambda (buf row input) (mode-list-match? buf row input))
        'order-filtered (lambda (buf rows) (mode-list-rank buf rows))
        ;; at rest the list holds the recent rows and a filter reads them
        ;; all, so crossing between the two reads the source again
        'incremental-query?
          (lambda (old new)
            (and (equal? (mode-list--blank? old) (mode-list--blank? new))
                 (or (equal? old new)
                     (not (string-suffix? "-mode" (string-downcase (string-trim old)))))))
        'regroup (lambda (buf) (mode-list-regroup! buf))
        'keys '(("RET" "mode-list-visit") ("t" "mode-list-toggle-groups")))
      (mode-list-opt mode 'opts '()))))

(define (mode-list-define! mode spec)
  (set! *mode-lists* (alist-put *mode-lists* mode spec))
  (let ((lm (mode-list-mode-name mode)))
    (ibuffer-scope-for! (mode-list-scope-name mode) (lambda (buf) (mode-list-scope mode buf)))
    (define-list-mode! lm (mode-list-opts mode))
    (ibuffer-view-mode! lm))
  mode)

;; ---------------------------------------------------------------------------
;; The view

(define (mode-list-views mode)
  (let ((lm (mode-list-mode-name mode)))
    (map car (filter (lambda (r) (equal? (cadr r) lm))
                     (buffer-read-many (buffer-list-mru) '() '("mode-name"))))))

(define (mode-list-buffer mode)
  ;; the list of this group: the one on screen, else the group's own
  (let* ((here (window-buffer (active-window)))
         (views (mode-list-views mode))
         (group (frame-group))
         (mine (filter (lambda (b) (equal? (buffer-group b) group)) views)))
    (cond ((member here views) here)
          ((pair? mine) (car mine))
          ((pair? views) (car views))
          (else (mode-list-buffer-base mode)))))

(define (mode-list-view! mode)
  ;; one view per group, the way ibuffer keeps one table per group
  (let* ((group (frame-group))
         (here (window-buffer (active-window)))
         (views (mode-list-views mode))
         (mine (filter (lambda (b) (equal? (buffer-group b) group)) views))
         (base (mode-list-buffer-base mode)))
    (cond ((member here views) here)
          ((pair? mine) (car mine))
          (else
            (let loop ((n 1))
              (let ((name (if (= n 1) base
                              (string-append base "<" (number->string n) ">"))))
                (if (buffer-known? name)
                    (loop (+ n 1))
                    (begin
                      (buffer-create name)
                      (when group (buffer-move-to-group! name group))
                      name))))))))

(define (mode-list mode &optional query)
  (unless (assoc mode *mode-lists*) (mode-list-define! mode '()))
  (mode-list-search-reset!)
  (let ((view (mode-list-view! mode)))
    (buffer-set-local! view 'mode-list-of mode)
    (apply ibuffer-view! (cons view (mode-list-opt mode 'defaults '(sort recent grouping none))))
    (ibuffer-open! (mode-list-scope-name mode) view (mode-list-mode-name mode))
    (when (and (string? query) (not (mode-list--blank? query)))
      (list-set-query! view (string-trim query) #t)
      (ibuffer-goto-first-row! view))
    (ibuffer-preview! view)
    ;; the list has the focus, whatever the opening did to the windows
    (let ((w (window-showing view)))
      (when (and w (not (equal? w (active-window)))) (select-window! w)))
    view))

(define (mode-list-modes)
  ;; the major modes that have a buffer, the current buffer's first
  (let* ((here (buffer-local (current-buffer) 'mode-name))
         (modes (dedupe-names
                  (filter (lambda (m) (and (string? m) (not (string-suffix? "-list-mode" m))))
                          (map cadr (buffer-read-many (buffer-list-mru) '() '("mode-name")))))))
    (if (and (string? here) (member here modes))
        (cons here (remove (lambda (m) (equal? m here)) modes))
        modes)))

;; ---------------------------------------------------------------------------
;; Commands

(effects! '(read write display))

(define-command "mode-list" "List every buffer of one major mode"
  (lambda ()
    (minibuffer-read "Mode list: " (mode-list-modes)
      (lambda (mode) (mode-list (string-trim mode))))))

(define-command "mode-list-visit"
  "Show the buffer at point in its group; on a heading, open the section"
  (lambda ()
    (let* ((view (ibuffer-view))
           (row (ibuffer-current))
           (mode (mode-list-of view))
           (open-row (mode-list-opt mode 'visit-row))
           (after (mode-list-opt mode 'after-visit)))
      (cond ((and (string? row) (not (buffer-known? row)) open-row)
             (listing-preview-dismiss! view)
             (transient-frame-exit! 'ibuffer)
             (open-row row))
            (else
             (run-command "ibuffer-visit")
             (when (and after (string? row) (equal? (window-buffer (active-window)) row))
               (after row)))))))

(define-command "mode-list-toggle-groups"
  "Turn the sections off and on; off is one list, most recent first"
  (lambda ()
    (let* ((buf (ibuffer-view))
           (grouping (ibuffer-grouping buf)))
      (if (equal? grouping 'none)
          ;; back to the sections you last had, not to a fixed default
          (let ((back (or (buffer-local buf 'mode-list-grouping-was) 'group)))
            (ibuffer-set-grouping! back buf)
            (message (string-append "grouped by " (symbol->string back))))
          (begin
            (buffer-set-local! buf 'mode-list-grouping-was grouping)
            (ibuffer-set-sort! 'recent buf)
            (ibuffer-set-grouping! 'none buf)
            (message "ungrouped -- most recent first"))))))

(effects! '(read))

(public! 'mode-list "(mode-list MODE [QUERY]) -- list every buffer of MODE, as ibuffer lists buffers")
(public! 'mode-list-define! "(mode-list-define! MODE SPEC) -- what a mode adds to its list; see mode-list.scm")
(public! 'mode-list-buffers "(mode-list-buffers MODE) -- the buffers a mode list shows, most recent first")
(public! 'mode-list-buffer "(mode-list-buffer MODE) -- the list view of MODE for this group")
(public! 'mode-list-hit "(mode-list-hit MODE NAME) -- the words around the filter's match in NAME's text, or #f")
