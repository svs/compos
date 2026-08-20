;;; annotate.scm --- the annotation layer: one model, many sources.
;;;
;;; docs/ANNOTATIONS.md is the design note. An annotation is data in the
;;; source buffer's 'annotations local. Overlays, the *annotations* list,
;;; and the echo line are projections of that one list.
;;;
;;; An annotation is a plist:
;;;   id        unique string, per buffer
;;;   source    "check" | "llm" | "reader"
;;;   severity  "error" | "warning" | "suggestion" | "question" | "note"
;;;   line      1-based line at the last locate; a paint refreshes it
;;;   match     the annotated text; "" annotates the whole line
;;;   title body who when   strings; "" is fine
;;;   fix-old fix-new       an optional suggested replacement
;;;   state     "open" | "resolved"
;;;
;;; The *annotations* buffer is a standard list. Its header shows one tab
;;; per source filter; <left> and <right> change the tab.

(domain! 'editing)
(effects! '(read))

;;; --- model ---------------------------------------------------------------

(define (annotate--get pl key def)
  (or (plist-get (or pl '()) key) def))

(define (buffer-annotations buf)
  (or (buffer-local buf 'annotations) '()))

(define (annotate--dismissed buf)
  (or (buffer-local buf 'ann-dismissed) '()))

;; the annotations a view shows: not dismissed, sorted by line then severity
(define *ann-severities* '("error" "warning" "suggestion" "question" "note"))

(define (annotate--priority sev)
  (let ((tail (member sev *ann-severities*)))
    (if tail (- 5 (length tail)) 5)))

(define (annotate-visible buf)
  (let ((gone (annotate--dismissed buf)))
    (map (lambda (k) (nth 2 k))
         (sort (map (lambda (a)
                      (list (annotate--get a 'line 0)
                            (annotate--priority (annotate--get a 'severity "note"))
                            a))
                    (filter (lambda (a) (not (member (annotate--get a 'id "") gone)))
                            (buffer-annotations buf)))))))

(define (annotate--find buf id)
  (let loop ((as (buffer-annotations buf)))
    (cond ((null? as) #f)
          ((equal? (annotate--get (car as) 'id "") id) (car as))
          (else (loop (cdr as))))))

;; plist update without plist-put: rebuild the pair list
(define (annotate--put pl key val)
  (let loop ((rest pl) (out '()) (seen #f))
    (cond ((null? rest)
           (if seen (reverse out) (append (reverse out) (list key val))))
          ((null? (cdr rest)) (reverse (cons (car rest) out)))
          ((equal? (car rest) key)
           (loop (cdr (cdr rest)) (cons val (cons key out)) #t))
          (else
           (loop (cdr (cdr rest)) (cons (cadr rest) (cons (car rest) out)) seen)))))

(define (annotate--update! buf id key val)
  (buffer-set-local! buf 'annotations
    (map (lambda (a)
          (if (equal? (annotate--get a 'id "") id) (annotate--put a key val) a))
         (buffer-annotations buf))))

;;; --- locate: an annotation names text, the paint finds its bytes ---------

(define (annotate--index hay needle)
  (let ((hl (string-byte-length hay))
        (nl (string-byte-length needle)))
    (and (> nl 0)
         (let loop ((i 0))
           (cond ((> (+ i nl) hl) #f)
                 ((equal? (substring-bytes hay i (+ i nl)) needle) i)
                 (else (loop (+ i 1))))))))

;; ((START END) ...) of every line's content, 0-based index = line - 1
(define (annotate--line-bounds text)
  (let loop ((lines (string-split text "\n")) (at 0) (out '()))
    (if (null? lines)
        (reverse out)
        (let ((len (string-byte-length (car lines))))
          (loop (cdr lines) (+ at len 1) (cons (list at (+ at len)) out))))))

(define (annotate--line-of text pos)
  (length (string-split (substring-bytes text 0 pos) "\n")))

;; -> (START END LINE), or #f when the annotated text left the buffer.
;; The stored line is the first place to look; the whole buffer is the
;; fallback, so an edit above the annotation does not orphan it.
(define (annotate--locate text bounds a)
  (let* ((line (annotate--get a 'line 1))
         (match (annotate--get a 'match ""))
         (lb (and (> line 0) (<= line (length bounds)) (nth (- line 1) bounds))))
    (if (equal? match "")
        (and lb (list (car lb) (cadr lb) line))
        (let ((here (and lb (annotate--index
                              (substring-bytes text (car lb) (cadr lb)) match))))
          (if here
              (list (+ (car lb) here)
                    (+ (car lb) here (string-byte-length match))
                    line)
              (let ((at (annotate--index text match)))
                (and at
                     (list at (+ at (string-byte-length match))
                           (annotate--line-of text at)))))))))

;;; --- paint: annotations become overlay ranges -----------------------------

(define (annotate--face a)
  (let ((source (annotate--get a 'source "check"))
        (sev (annotate--get a 'severity "note")))
    (cond ((equal? source "llm") "ann-llm")
          ((equal? source "reader") "ann-reader")
          (else (string-append "ann-" sev)))))

(define (annotate--paint! buf)
  (when (buffer-exists? buf)
    (let* ((text (buffer-text buf))
           (bounds (annotate--line-bounds text))
           (sel (buffer-local buf 'ann-selected))
           (spans
             (fold
               (lambda (acc a)
                 (let ((at (annotate--locate text bounds a)))
                   (if (or (not at)
                           (equal? (annotate--get a 'state "open") "resolved"))
                       acc
                       (let ((s (car at)) (e (cadr at)))
                         (append acc
                           (list (list s e (annotate--face a)))
                           (if (equal? sel (annotate--get a 'id ""))
                               (list (list s e "ann-selected"))
                               '()))))))
               '()
               (annotate-visible buf))))
      (overlay-set! buf 'annotate spans))))

(define-style! 'annotate "
.f-ann-error{text-decoration:underline wavy var(--alert-fg,#a83a2b);text-decoration-skip-ink:none}
.f-ann-warning{text-decoration:underline wavy var(--warn-fg,#7a5a1a);text-decoration-skip-ink:none}
.f-ann-suggestion{text-decoration:underline dotted var(--accent-fg,#26356b);text-decoration-skip-ink:none}
.f-ann-question{text-decoration:underline dotted var(--ok-fg,#2e6b45);text-decoration-skip-ink:none}
.f-ann-note{text-decoration:underline dotted var(--ok-fg,#2e6b45);text-decoration-skip-ink:none}
.f-ann-llm{text-decoration:underline dotted var(--accent-fg,#26356b);text-decoration-skip-ink:none}
.f-ann-reader{background:color-mix(in srgb,var(--ok-fg,#2e6b45) 14%,transparent);border-radius:2px}
.f-ann-selected{box-shadow:0 0 0 1.5px var(--accent-fg,#26356b);border-radius:2px}
")

;;; --- public data API -------------------------------------------------------

(effects! '(write))

(define (annotate--list-refresh buf)
  (let ((lb "*annotations*"))
    (when (and (buffer-exists? lb)
               (equal? (buffer-local lb 'ann-source) buf))
      (list-refresh! lb))))

(define (annotate--touch! buf)
  (annotate--paint! buf)
  (annotate--list-refresh buf))

(define (annotate! buf spec)
  (let* ((n (+ 1 (or (buffer-local buf 'ann-next-id) 0)))
         (id (string-append "a" (number->string n)))
         (a (annotate--put (annotate--put spec 'id id) 'state
                           (annotate--get spec 'state "open"))))
    (buffer-set-local! buf 'ann-next-id n)
    (buffer-set-local! buf 'annotations
      (append (buffer-annotations buf) (list a)))
    (annotate--touch! buf)
    id))

(define (annotate-clear! buf source)
  (buffer-set-local! buf 'annotations
    (if source
        (filter (lambda (a) (not (equal? (annotate--get a 'source "") source)))
                (buffer-annotations buf))
        '()))
  (annotate--touch! buf))

(public! 'annotate!
  "(annotate! BUF SPEC) — add one annotation plist (source severity line match title body who when fix-old fix-new); returns its id")
(public! 'annotate-clear!
  "(annotate-clear! BUF SOURCE) — drop SOURCE's annotations; SOURCE #f drops all")
(public! 'buffer-annotations
  "(buffer-annotations BUF) — the buffer's annotation plists")
(public! 'annotate-visible
  "(annotate-visible BUF) — annotations a view shows: not dismissed, sorted by line then severity")

;;; --- the check source: tree-sitter ERROR nodes ----------------------------

(define (annotate--check! buf)
  (let ((lang (buffer-local buf 'ts-lang)))
    (when (and lang (member lang (ts-langs)))
      (let* ((text (buffer-text buf))
             (bounds (annotate--line-bounds text))
             (errs (ts-query-string lang text "(ERROR) @err")))
        (buffer-set-local! buf 'annotations
          (append
            (filter (lambda (a) (not (equal? (annotate--get a 'source "") "check")))
                    (buffer-annotations buf))
            (map (lambda (e)
                   (let* ((s (cadr e))
                          (line (annotate--line-of text s))
                          (lb (nth (- line 1) bounds))
                          (stop (min (caddr e) (cadr lb)))
                          (n (or (buffer-local buf 'ann-next-id) 0)))
                     (buffer-set-local! buf 'ann-next-id (+ n 1))
                     (list 'id (string-append "a" (number->string (+ n 1)))
                           'source "check" 'severity "error"
                           'line line
                           'match (substring-bytes text s (max stop (+ s 1)))
                           'title "Syntax error"
                           'body "Tree-sitter cannot parse this range."
                           'who (string-append lang " · tree-sitter")
                           'when "live" 'state "open")))
                 errs)))))))

;;; --- change hook: relocate, recheck, repaint -------------------------------

;; keyed by buffer NAME in global state, so revert-buffer + mode re-entry
;; does not stack duplicate rules (the morg pattern)
(define *ann-hooks* '())

;; persist fresh line numbers after an edit, so the list shows where an
;; annotation IS, not where it was added
(define (annotate--relocate! buf)
  (let* ((text (buffer-text buf))
         (bounds (annotate--line-bounds text)))
    (buffer-set-local! buf 'annotations
      (map (lambda (a)
             (let ((at (annotate--locate text bounds a)))
               (if at (annotate--put a 'line (caddr at)) a)))
           (buffer-annotations buf)))))

(define (annotate--tick buf)
  (when (and (buffer-exists? buf) (minor-mode-on? buf "annotate-mode"))
    (annotate--check! buf)
    (annotate--relocate! buf)
    (annotate--touch! buf)))

(define (annotate--ensure-hook! buf)
  (unless (assoc buf *ann-hooks*)
    (set! *ann-hooks*
      (cons (list buf
                  (on-change! buf
                    (lambda (pos inserted deleted source)
                      (unless (equal? source "locals")
                        (debounce! (string-append "annotate:" buf) 300
                                   annotate--tick buf)))))
            *ann-hooks*))))

;;; --- echo + navigation ------------------------------------------------------

(define (annotate--label a)
  (let ((source (annotate--get a 'source "")))
    (cond ((equal? source "check") "flymake")
          ((equal? source "llm") "claude")
          (else "reader"))))

(define (annotate--echo a)
  (message (string-append (annotate--label a) " · "
                          (annotate--get a 'severity "") " · L"
                          (number->string (annotate--get a 'line 1)) " — "
                          (annotate--get a 'title ""))))

(define (annotate--goto! buf a select?)
  (let* ((text (buffer-text buf))
         (at (annotate--locate text (annotate--line-bounds text) a)))
    (when at
      (buffer-set-local! buf 'ann-selected (annotate--get a 'id ""))
      (if select?
          (goto-char! (car at))
          (buffer-goto! buf (car at)))
      (annotate--paint! buf)
      (annotate--echo a))))

(define (annotate--step d)
  (let* ((buf (current-buffer))
         (vis (annotate-visible buf)))
    (if (null? vis)
        (message "No annotations in this buffer")
        (let* ((ids (map (lambda (a) (annotate--get a 'id "")) vis))
               (sel (buffer-local buf 'ann-selected))
               (i (let loop ((xs ids) (n 0))
                    (cond ((null? xs) #f)
                          ((equal? (car xs) sel) n)
                          (else (loop (cdr xs) (+ n 1))))))
               (n (if i (modulo (+ i d (length vis)) (length vis))
                        (if (> d 0) 0 (- (length vis) 1)))))
          (annotate--goto! buf (nth n vis) #t)))))

(define-command "annotate-next" "Go to the next annotation"
  (lambda () (annotate--step 1)))

(define-command "annotate-prev" "Go to the previous annotation"
  (lambda () (annotate--step -1)))

;;; --- the *annotations* list: a standard list buffer -------------------------

(define *ann-buffer* "*annotations*")

;; the tabs: one source filter each. <left>/<right> change the tab.
(define *ann-tabs*
  (list
    (list "all" (lambda (a) #t))
    (list "errors" (lambda (a) (member (annotate--get a 'severity "")
                                       '("error" "warning"))))
    (list "claude" (lambda (a) (equal? (annotate--get a 'source "") "llm")))
    (list "readers" (lambda (a) (equal? (annotate--get a 'source "") "reader")))
    (list "flymake" (lambda (a) (equal? (annotate--get a 'source "") "check")))))

(define (annotate--tab buf)
  (min (or (buffer-local buf 'ann-tab) 0) (- (length *ann-tabs*) 1)))

(define (annotate--list-source buf)
  (or (buffer-local buf 'ann-source) ""))

(define (annotate--rows buf)
  (let* ((source (annotate--list-source buf))
         (tab (nth (annotate--tab buf) *ann-tabs*)))
    (if (buffer-exists? source)
        (filter (lambda (a) ((cadr tab) a)) (annotate-visible source))
        '())))

(define (annotate--tab-bar buf)
  (let* ((source (annotate--list-source buf))
         (all (if (buffer-exists? source) (annotate-visible source) '()))
         (at (annotate--tab buf)))
    (string-append
      (string-join
        (map (lambda (i)
               (let* ((tab (nth i *ann-tabs*))
                      (n (length (filter (cadr tab) all)))
                      (cell (string-append (car tab) " "
                                           (number->string n))))
                 (if (= i at)
                     (string-append "[" cell "]")
                     (string-append " " cell " "))))
             (list 0 1 2 3 4))
        " ")
      "   <left>/<right> switch tab")))

(define (annotate--state a)
  (cond ((equal? (annotate--get a 'state "open") "resolved") "resolved")
        ((not (equal? (annotate--get a 'fix-new "") "")) "fix ready")
        (else "open")))

(define (annotate--cells buf a)
  (let* ((source (annotate--get a 'source ""))
         (sev (annotate--get a 'severity ""))
         (resolved (equal? (annotate--get a 'state "open") "resolved"))
         (accent (cond (resolved "faint")
                       ((equal? source "llm") "accent")
                       ((equal? source "reader") "ok")
                       ((equal? sev "error") "alert")
                       (else "warn")))
         (glyph (cond ((equal? source "llm") "◆")
                      ((equal? source "reader") "●")
                      (else "!")))
         (state (annotate--state a)))
    (list (list glyph accent)
          (string-append "L" (number->string (annotate--get a 'line 1)))
          (list (annotate--label a) accent)
          sev
          (if resolved (list (annotate--get a 'title "") "faint")
              (annotate--get a 'title ""))
          (list (annotate--get a 'who "") "faint")
          (list state (cond ((equal? state "resolved") "ok")
                            ((equal? state "fix ready") "accent")
                            (else "faint"))))))

(define (annotate--current-pair)
  ;; -> (SOURCE-BUF ANNOTATION) for the list row at point, or #f
  (let* ((lb (current-buffer))
         (a (list-current lb))
         (source (annotate--list-source lb)))
    (and a (buffer-exists? source) (list source a))))

(define (annotate--show lb a select?)
  (let ((source (annotate--list-source lb)))
    (when (buffer-exists? source)
      (let ((win (display-buffer-other-window! source)))
        (annotate--goto! source a #f)
        (when (and select? win (window-exists? win))
          (select-window! win)
          (switch-to-buffer! source)
          (annotate--goto! source a #t))))))

(define-command "annotate-visit" "Visit the annotation on this row"
  (lambda ()
    (let* ((lb (current-buffer))
           (a (list-current lb)))
      (when a (annotate--show lb a #t)))))

(define-command "annotate-resolve" "Resolve or reopen the annotation on this row"
  (lambda ()
    (let ((pair (annotate--current-pair)))
      (when pair
        (let* ((source (car pair))
               (a (cadr pair))
               (id (annotate--get a 'id ""))
               (resolved (equal? (annotate--get a 'state "open") "resolved")))
          (annotate--update! source id 'state (if resolved "open" "resolved"))
          (annotate--touch! source)
          (message (string-append (if resolved "Reopened " "Resolved ")
                                  id " — " (annotate--get a 'title ""))))))))

(define-command "annotate-dismiss" "Dismiss the annotation on this row (this session)"
  (lambda ()
    (let ((pair (annotate--current-pair)))
      (when pair
        (let* ((source (car pair))
               (a (cadr pair))
               (id (annotate--get a 'id "")))
          (buffer-set-local! source 'ann-dismissed
            (cons id (annotate--dismissed source)))
          (desktop-skip! source 'ann-dismissed)
          (annotate--touch! source)
          (message (string-append "Dismissed " id " · this session only")))))))

(define-command "annotate-apply-fix" "Apply the suggested fix on this row"
  (lambda ()
    (let ((pair (annotate--current-pair)))
      (when pair
        (let* ((source (car pair))
               (a (cadr pair))
               (old (annotate--get a 'fix-old ""))
               (new (annotate--get a 'fix-new "")))
          (if (equal? new "")
              (message "No suggested fix on this annotation")
              (let* ((text (buffer-text source))
                     (bounds (annotate--line-bounds text))
                     (probe (annotate--put a 'match old))
                     (at (annotate--locate text bounds probe)))
                (if (not at)
                    (message "Fix no longer applies — text has changed")
                    (begin
                      (buffer-delete-range! source (car at)
                                            (- (cadr at) (car at)))
                      (buffer-insert! source (car at) new)
                      (annotate--update! source (annotate--get a 'id "")
                                         'match new)
                      (annotate--update! source (annotate--get a 'id "")
                                         'state "resolved")
                      (annotate--touch! source)
                      (message (string-append "Applied fix from "
                                              (annotate--get a 'who "")
                                              " · L" (number->string (caddr at)))))))))))))

(define (annotate--set-tab! d)
  (let* ((lb (current-buffer))
         (n (modulo (+ (annotate--tab lb) d (length *ann-tabs*))
                    (length *ann-tabs*))))
    (buffer-set-local! lb 'ann-tab n)
    (list-refresh! lb)
    (message (string-append "Filter: " (car (nth n *ann-tabs*))))))

(define-command "annotate-tab-next" "Show the next annotation tab"
  (lambda () (annotate--set-tab! 1)))

(define-command "annotate-tab-prev" "Show the previous annotation tab"
  (lambda () (annotate--set-tab! -1)))

(define-command "annotate-list-refresh" "Recompute this annotation list"
  (lambda () (list-refresh! (current-buffer))))

(define *annotations-doc*
  (string-append
    "This list shows the annotations of one buffer. "
    "The header tabs filter by source; <left> and <right> change the tab. "
    "Moving previews the annotation. RET visits it. "
    "`r` resolves, `y` applies the suggested fix, `d` dismisses."))

(define-list-mode! "annotations-mode"
  (list
    'doc *annotations-doc*
    'buffer *ann-buffer*
    'rows annotate--rows
    'key (lambda (buf a) (annotate--get a 'id ""))
    'columns (lambda (buf)
               (list (list "" 2)
                     (list "line" 5 'right)
                     (list "source" 8)
                     (list "sev" 10)
                     (list "title" #f)
                     (list "who" 18)
                     (list "state" 9)))
    'cells annotate--cells
    'title (lambda (buf)
             (string-append "Annotations — "
                            (buffer-short-label (annotate--list-source buf))))
    'meta annotate--tab-bar
    'total (lambda (buf)
             (let ((source (annotate--list-source buf)))
               (if (buffer-exists? source)
                   (length (annotate-visible source))
                   0)))
    'footer (lambda (buf)
              '(("RET" "visit") ("r" "resolve") ("y" "apply fix")
                ("d" "dismiss") ("<left>/<right>" "tab") ("q" "quit")))
    'noun "annotation"
    'preview (lambda (buf a) (annotate--show buf a #f))
    'keys '(("RET" "annotate-visit")
            ("r" "annotate-resolve")
            ("y" "annotate-apply-fix")
            ("d" "annotate-dismiss")
            ("f" "annotate-tab-next")
            ("<right>" "annotate-tab-next")
            ("<left>" "annotate-tab-prev")
            ("g" "annotate-list-refresh")
            ("q" "quit-window"))))

(mode-doc! "annotations-mode" *annotations-doc*)

;; the design's bottom sheet: the list floats against the bottom edge
(add-display-rule! *ann-buffer* 'popup '(side bottom size 0.32))

(define-command "annotate-list" "Show this buffer's annotations as a list"
  (lambda ()
    (let ((source (current-buffer)))
      (buffer-create *ann-buffer*)
      (buffer-set-local! *ann-buffer* 'ann-source source)
      (list-mode-show! "annotations-mode"))))

;;; --- annotate-mode: the minor mode on the source buffer ---------------------

(register-minor-mode! "annotate-mode"
  (lambda (buf)
    (local-set-key* buf "M-n" "annotate-next")
    (local-set-key* buf "M-p" "annotate-prev")
    (local-set-key* buf "C-c ! l" "annotate-list")
    (annotate--ensure-hook! buf)
    (annotate--check! buf)
    (annotate--paint! buf))
  (lambda (buf)
    (local-unset-key* buf "M-n")
    (local-unset-key* buf "M-p")
    (local-unset-key* buf "C-c ! l")
    (overlay-clear! buf 'annotate)))

(define-command "annotate-mode" "Toggle annotations in this buffer"
  (lambda ()
    (if (toggle-minor-mode! "annotate-mode")
        (message "annotate-mode on — M-n/M-p walk annotations, C-c ! l lists them")
        (message "annotate-mode off"))))

(public! 'annotate--paint!
  "(annotate--paint! BUF) — repaint BUF's annotation overlays from its 'annotations local")
