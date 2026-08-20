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
.ann-mhead{display:flex;justify-content:space-between;gap:8px;font-family:var(--font-mono);font-size:10px;letter-spacing:.13em;text-transform:uppercase;color:var(--dim-fg);padding:8px 2px 6px}
.ann-card{border:1px solid var(--border-bg);border-radius:9px;padding:8px 10px 9px;margin:0 0 8px;cursor:pointer}
.ann-card.open{border-color:var(--accent-fg,#26356b);background:var(--hl-line-bg)}
.ann-card.resolved{opacity:.55}
.ann-chead{display:flex;align-items:center;gap:7px;padding-bottom:5px;font-family:var(--font-mono);font-size:9.5px;letter-spacing:.12em;text-transform:uppercase;font-weight:600}
.ann-dot{width:6px;height:6px;border-radius:50%;background:currentColor;flex:0 0 auto}
.ann-acc-accent{color:var(--accent-fg,#26356b)}
.ann-acc-ok{color:var(--ok-fg,#2e6b45)}
.ann-acc-alert{color:var(--alert-fg,#a83a2b)}
.ann-acc-warn{color:var(--warn-fg,#7a5a1a)}
.ann-spacer{flex:1}
.ann-cmeta{color:var(--dim-fg);letter-spacing:0;font-weight:400}
.ann-ctitle{font-size:12.5px;font-weight:600}
.ann-cwho{font-family:var(--font-mono);font-size:10.5px;color:var(--dim-fg);padding-top:3px}
.ann-cbody{font-size:13px;line-height:1.55;padding-top:5px}
.ann-snip{font-size:12.5px;color:var(--dim-fg);padding-top:5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ann-quote{border-left:2px solid var(--border-bg);padding:2px 0 2px 8px;font-family:var(--font-mono);font-size:11px;color:var(--dim-fg);margin-top:6px}
.ann-fix{border:1px solid var(--border-bg);border-radius:7px;overflow:hidden;margin-top:6px}
.ann-fix-head{display:flex;justify-content:space-between;gap:8px;padding:3px 8px;border-bottom:1px solid var(--border-bg);font-family:var(--font-mono);font-size:9.5px;letter-spacing:.12em;text-transform:uppercase;color:var(--dim-fg)}
.ann-fix-key{color:var(--accent-fg,#26356b)}
.ann-fix-del{display:flex;gap:6px;padding:2px 8px;background:color-mix(in srgb,var(--alert-fg,#a83a2b) 9%,transparent);font-family:var(--font-mono);font-size:11px}
.ann-fix-add{display:flex;gap:6px;padding:2px 8px;background:color-mix(in srgb,var(--ok-fg,#2e6b45) 10%,transparent);font-family:var(--font-mono);font-size:11px}
.ann-fix-sign-del{color:var(--alert-fg,#a83a2b);font-weight:600}
.ann-fix-sign-add{color:var(--ok-fg,#2e6b45);font-weight:600}
.ann-th{border-top:1px solid var(--border-bg);margin-top:7px;padding-top:7px}
.ann-th-who{font-family:var(--font-mono);font-size:10px;color:var(--dim-fg)}
.ann-th-text{font-size:12.5px}
")

;;; --- public data API -------------------------------------------------------

(effects! '(write))

(define (annotate--list-refresh buf)
  (let ((lb "*annotations*"))
    (when (and (buffer-exists? lb)
               (equal? (buffer-local lb 'ann-source) buf))
      (list-refresh! lb))))

(define (annotate--touch! buf)
  (annotate--store-save! buf)
  (annotate--paint! buf)
  (annotate--list-refresh buf)
  (annotate--margin-refresh buf))

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

;; an annotation can carry annotations: 'thread is a list of reply
;; plists (who when text), and a reply is the same shape again
(define (annotate-reply! buf id text)
  (let ((a (annotate--find buf id)))
    (when a
      (annotate--update! buf id 'thread
        (append (or (plist-get a 'thread) '())
                (list (list 'who "you" 'when "now" 'text text))))
      (annotate--touch! buf)
      (message (string-append "Reply added to " id)))))

(public! 'annotate-reply!
  "(annotate-reply! BUF ID TEXT) — append one reply plist to the annotation's thread")

;;; --- the store: annotations are a file on disk --------------------------------
;;; One file per source file, under <aimax-home>/annotations/. The file
;;; is a printed list of annotation plists — readable, greppable, and
;;; writable by an agent outside the editor. The buffer-local is the
;;; working copy: every change writes the file, and enabling the mode
;;; on a fresh visit reads it.

(define (annotate--encode rel)
  (string-join (string-split rel "/") "%2F"))

(define (annotate--home-store-file buf)
  (and (string-prefix? "/" buf)
       (string-append
         (aimax-home) "/annotations/"
         (annotate--encode (substring-bytes buf 1 (string-byte-length buf)))
         ".scm")))

;; a file inside a project keeps its annotations IN the project, so they
;; travel with the repo — commits, worktrees, and pulls carry them. A
;; file outside any project uses the home store.
(define (annotate--store-file buf)
  (and (string-prefix? "/" buf)
       (let ((root (and (boundp 'project-root-cached)
                        (project-root-cached (parent-dir buf)))))
         (if root
             (string-append
               root "/.aimax/annotations/"
               (annotate--encode
                 (substring-bytes buf (+ (string-byte-length root) 1)
                                  (string-byte-length buf)))
               ".scm")
             (annotate--home-store-file buf)))))

(define (annotate-store-file buf) (annotate--store-file buf))

;; the file keeps what people and agents said — reader and llm
;; annotations. Checker diagnostics are live state: the checker
;; recomputes them, so the store never carries them.
(define (annotate--store-save! buf)
  (let ((path (annotate--store-file buf)))
    (when path
      (write-file! path
        (value->string
          (filter (lambda (a)
                    (not (equal? (annotate--get a 'source "") "check")))
                  (buffer-annotations buf)))))))

(define (annotate--id-number id)
  (let ((n (string->number
             (substring-bytes id 1 (string-byte-length id)))))
    (if (number? n) n 0)))

(define (annotate--store-load! buf)
  ;; a store saved before the project move still loads; the next save
  ;; writes the project location
  (let* ((primary (annotate--store-file buf))
         (path (if (and primary (file-exists? primary))
                   primary
                   (annotate--home-store-file buf))))
    (when (and path (file-exists? path) (null? (buffer-annotations buf)))
      ;; scheme-read returns the list of top-level forms; the file holds
      ;; ONE form, the annotation list
      (let* ((forms (scheme-read (or (read-file path) "()")))
             (v (if (pair? forms) (car forms) '())))
        (when (pair? v)
          (buffer-set-local! buf 'annotations v)
          (buffer-set-local! buf 'ann-next-id
            (fold (lambda (acc a)
                    (max acc (annotate--id-number (annotate--get a 'id "a0"))))
                  0 v)))))))

;; a file that carries annotations opens with them showing
(add-hook! 'find-file-hook
  (lambda ()
    (let* ((buf (current-buffer))
           (path (annotate--store-file buf))
           (legacy (annotate--home-store-file buf)))
      (when (and (or (and path (file-exists? path))
                     (and legacy (file-exists? legacy)))
                 (not (minor-mode-on? buf "annotate-mode")))
        (enable-minor-mode! buf "annotate-mode")))))

(define-command "annotate-store-visit" "Visit this buffer's annotations file"
  (lambda ()
    (let* ((buf (current-buffer))
           (src (or (buffer-local buf 'ann-source) buf))
           (path (annotate--store-file src)))
      (if path
          (visit path)
          (message "No annotations file — this buffer is not a file on disk")))))

(public! 'annotate-store-file
  "(annotate-store-file BUF) — the on-disk annotations file for a file buffer, or #f")

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
      (annotate--margin-refresh buf)
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

;; the verbs, shared by the list keys and the margin's action chips
(define (annotate--toggle-resolve! source a)
  (let* ((id (annotate--get a 'id ""))
         (resolved (equal? (annotate--get a 'state "open") "resolved")))
    (annotate--update! source id 'state (if resolved "open" "resolved"))
    (annotate--touch! source)
    (message (string-append (if resolved "Reopened " "Resolved ")
                            id " — " (annotate--get a 'title "")))))

(define (annotate--do-dismiss! source a)
  (let ((id (annotate--get a 'id "")))
    (buffer-set-local! source 'ann-dismissed
      (cons id (annotate--dismissed source)))
    (desktop-skip! source 'ann-dismissed)
    (annotate--touch! source)
    (message (string-append "Dismissed " id " · this session only"))))

(define (annotate--do-fix! source a)
  (let ((old (annotate--get a 'fix-old ""))
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
                (annotate--update! source (annotate--get a 'id "") 'match new)
                (annotate--update! source (annotate--get a 'id "")
                                   'state "resolved")
                (annotate--touch! source)
                (message (string-append "Applied fix from "
                                        (annotate--get a 'who "")
                                        " · L" (number->string (caddr at))))))))))

;;; --- agent suggestions: an LLM proposes the fix ------------------------------

;; pure: the prompt for one annotation, from the located span and its
;; surrounding lines
(define (annotate--suggest-prompt source a at)
  (let* ((text (buffer-text source))
         (bounds (annotate--line-bounds text))
         (line (caddr at))
         (lo (max 1 (- line 3)))
         (hi (min (length bounds) (+ line 3)))
         (ctx (substring-bytes text
                               (car (nth (- lo 1) bounds))
                               (cadr (nth (- hi 1) bounds))))
         (span (substring-bytes text (car at) (cadr at))))
    (string-append
      "You resolve one review annotation in a text buffer.\n\n"
      "Context, lines " (number->string lo) "-" (number->string hi) ":\n"
      ctx "\n\n"
      "Annotated span on line " (number->string line) ":\n" span "\n\n"
      "Annotation (" (annotate--label a) " · "
      (annotate--get a 'severity "") "): "
      (annotate--get a 'title "")
      (let ((b (annotate--get a 'body "")))
        (if (equal? b "") "" (string-append " — " b)))
      "\n\nReply with ONLY the replacement text for the annotated span. "
      "No quotes, no markup, no explanation.")))

;; the reply becomes the annotation's suggested fix; `y` applies it
(define (annotate--suggest-apply! source id span reply)
  (let ((fix (string-trim reply)))
    (if (or (equal? fix "") (not (annotate--find source id)))
        (message "The agent returned no suggestion")
        (begin
          (annotate--update! source id 'fix-old span)
          (annotate--update! source id 'fix-new fix)
          (annotate--touch! source)
          (message (string-append "Suggestion ready on " id " — y applies"))))))

(effects! '(write external spend))

(define (annotate--suggest! source a)
  (let* ((text (buffer-text source))
         (at (annotate--locate text (annotate--line-bounds text) a)))
    (if (not at)
        (message "Cannot locate this annotation in the buffer")
        (let ((id (annotate--get a 'id ""))
              (span (substring-bytes text (car at) (cadr at))))
          (message (string-append "Asking for a suggestion on " id " ..."))
          (llm (annotate--suggest-prompt source a at)
               (lambda (reply)
                 (annotate--suggest-apply! source id span reply)))))))

(define-command "annotate-suggest" "Ask an agent to suggest a fix for this row"
  (lambda () (annotate--row-verb annotate--suggest!)))

(effects! '(write))

(define (annotate--read-reply source a)
  (minibuffer-read
    (string-append "Reply to " (annotate--get a 'who "") ": ") '()
    (lambda (text)
      (unless (equal? (string-trim text) "")
        (annotate-reply! source (annotate--get a 'id "") text)))))

(define (annotate--row-verb f)
  (let ((pair (annotate--current-pair)))
    (when pair (f (car pair) (cadr pair)))))

(define-command "annotate-resolve" "Resolve or reopen the annotation on this row"
  (lambda () (annotate--row-verb annotate--toggle-resolve!)))

(define-command "annotate-dismiss" "Dismiss the annotation on this row (this session)"
  (lambda () (annotate--row-verb annotate--do-dismiss!)))

(define-command "annotate-apply-fix" "Apply the suggested fix on this row"
  (lambda () (annotate--row-verb annotate--do-fix!)))

(define-command "annotate-reply" "Reply to the annotation on this row"
  (lambda () (annotate--row-verb annotate--read-reply)))

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
                ("s" "suggest") ("R" "reply") ("d" "dismiss")
                ("<left>/<right>" "tab") ("q" "quit")))
    'noun "annotation"
    'preview (lambda (buf a) (annotate--show buf a #f))
    'keys '(("RET" "annotate-visit")
            ("r" "annotate-resolve")
            ("y" "annotate-apply-fix")
            ("s" "annotate-suggest")
            ("R" "annotate-reply")
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

;;; --- the margin: annotation cards beside the document ------------------------
;;; A blocks buffer, the diff-mode pattern. One card per visible
;;; annotation; the selected card is open and shows the body, the
;;; suggested fix, the thread, and the action chips.

(define *ann-margin* "*margin*")

(define (annotate--accent a)
  (let ((source (annotate--get a 'source "")))
    (cond ((equal? source "llm") "ann-acc-accent")
          ((equal? source "reader") "ann-acc-ok")
          ((equal? (annotate--get a 'severity "") "error") "ann-acc-alert")
          (else "ann-acc-warn"))))

(define (annotate--card src a n open?)
  (let* ((acc (annotate--accent a))
         (resolved (equal? (annotate--get a 'state "open") "resolved"))
         (id (annotate--get a 'id ""))
         (fix (not (equal? (annotate--get a 'fix-new "") "")))
         (thread (or (plist-get a 'thread) '())))
    (list 'tag "div"
          'class (string-append "ann-card" (if open? " open" "")
                                (if resolved " resolved" ""))
          'click (string-append "ann:pick:" id)
          'children
          (append
            (list (list 'tag "div" 'class (string-append "ann-chead " acc)
                        'children
                        (list (list 'tag "span" 'class "ann-dot")
                              (list 'tag "span" 'class "ann-clabel"
                                    'text (string-append
                                            (number->string n) " · "
                                            (annotate--label a) " "
                                            (annotate--get a 'severity "")))
                              (list 'tag "span" 'class "ann-spacer")
                              (list 'tag "span" 'class "ann-cmeta"
                                    'text (if resolved "resolved" ""))
                              (list 'tag "span" 'class "ann-cmeta"
                                    'text (string-append
                                            "L" (number->string
                                                  (annotate--get a 'line 1)))))))
            (list (list 'tag "div" 'class "ann-ctitle"
                        'text (annotate--get a 'title "")))
            (list (list 'tag "div" 'class "ann-cwho"
                        'text (string-append (annotate--get a 'who "") " · "
                                             (annotate--get a 'when ""))))
            (if open?
                (append
                  (list (list 'tag "div" 'class "ann-cbody"
                              'text (annotate--get a 'body "")))
                  (if (equal? (annotate--get a 'quote "") "")
                      '()
                      (list (list 'tag "div" 'class "ann-quote"
                                  'text (annotate--get a 'quote ""))))
                  (if fix
                      (list (list 'tag "div" 'class "ann-fix" 'children
                              (list (list 'tag "div" 'class "ann-fix-head"
                                          'segs (list (list "" "suggested fix")
                                                      (list "ann-fix-key" "y applies")))
                                    (list 'tag "div" 'class "ann-fix-del"
                                          'segs (list (list "ann-fix-sign-del" "-")
                                                      (list "" (annotate--get a 'fix-old ""))))
                                    (list 'tag "div" 'class "ann-fix-add"
                                          'segs (list (list "ann-fix-sign-add" "+")
                                                      (list "" (annotate--get a 'fix-new "")))))))
                      '())
                  (map (lambda (r)
                         (list 'tag "div" 'class "ann-th" 'children
                               (list (list 'tag "div" 'class "ann-th-who"
                                           'text (string-append
                                                   (annotate--get r 'who "") " · "
                                                   (annotate--get r 'when "")))
                                     (list 'tag "div" 'class "ann-th-text"
                                           'text (annotate--get r 'text "")))))
                       thread)
                  (list (component 'ui/actions
                          (list 'actions
                            (append
                              (list (list (string-append "ann:resolve:" id)
                                          (if resolved "reopen" "resolve") "r"))
                              (if fix
                                  (list (list (string-append "ann:fix:" id)
                                              "apply fix" "y"))
                                  (list (list (string-append "ann:suggest:" id)
                                              "suggest" "s")))
                              (list (list (string-append "ann:reply:" id)
                                          "reply" "R")
                                    (list (string-append "ann:dismiss:" id)
                                          "dismiss" "d")))))))
                (list (list 'tag "div" 'class "ann-snip"
                            'text (annotate--get a 'body ""))))))))

(define (annotate--margin-blocks mbuf)
  (let* ((src (buffer-local mbuf 'ann-source))
         (vis (if (and src (buffer-exists? src)) (annotate-visible src) '()))
         (sel (and src (buffer-local src 'ann-selected))))
    (append
      (list (list 'tag "div" 'class "ann-mhead"
                  'segs (list (list "" (string-append
                                         "margin · "
                                         (number->string (length vis))
                                         (if (= (length vis) 1)
                                             " annotation" " annotations")))
                              (list "ann-mkeys" "M-n / M-p"))))
      (if (null? vis)
          (list (component 'ui/empty '(text "no annotations")))
          (let loop ((as vis) (n 1) (out '()))
            (if (null? as)
                (reverse out)
                (loop (cdr as) (+ n 1)
                      (cons (annotate--card src (car as) n
                              (equal? sel (annotate--get (car as) 'id "")))
                            out))))))))

(define (annotate--margin-render! mbuf)
  (when (buffer-exists? mbuf)
    (buffer-set-local! mbuf 'render-blocks (annotate--margin-blocks mbuf))
    (buffer-set-local! mbuf 'render-mode "blocks")))

(define (annotate--margin-refresh src)
  (when (and (buffer-exists? *ann-margin*)
             (equal? (buffer-local *ann-margin* 'ann-source) src))
    (annotate--margin-render! *ann-margin*)))

;; ONE init for the margin, fresh or restored: cards are a view, so the
;; buffer refuses typing from its first frame, not only after a restore
(define (annotate--margin-init! buf)
  (buffer-set-read-only! buf #t)
  (local-set-key* buf "C-c C-v" "annotate-store-visit")
  (annotate--margin-render! buf))

(define (annotate--margin-ensure! src)
  (buffer-create *ann-margin*)
  (buffer-set-local! *ann-margin* 'ann-source src)
  (buffer-set-local! *ann-margin* 'mode-name "annotate-margin-mode")
  (annotate--margin-init! *ann-margin*))

;; the margin buffer's own mode — it exists so a desktop restore can
;; rebuild the cards. Invoked by hand on any other buffer it only
;; points at the real switch.
(define-mode "annotate-margin-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (buffer-local buf 'ann-source)
          (annotate--margin-init! buf)
          (message "annotate-margin-mode is the margin's internal mode — C-c ! m (annotate-margin) toggles the margin")))))

;; annotate-mode owns a frame arrangement: the document and its margin
(define-mode-layout! "annotate-mode" '(h 0.7 self "*margin*"))

;; The margin's clicks: ann:VERB:ID on cards and action chips. The click
;; itself made the margin the active window, and the margin is read-only —
;; so every verb first hands the focus back to the document. Without this
;; the next keystroke hits the margin and the editor answers "Buffer is
;; read-only", which reads as annotate-mode freezing the document.
(define (annotate--click! src verb a)
  (let ((win (window-showing src)))
    (when win (select-window! win))
    (cond ((equal? verb "pick") (annotate--goto! src a (and win #t)))
          ((equal? verb "resolve") (annotate--toggle-resolve! src a))
          ((equal? verb "fix") (annotate--do-fix! src a))
          ((equal? verb "suggest") (annotate--suggest! src a))
          ((equal? verb "dismiss") (annotate--do-dismiss! src a))
          ((equal? verb "reply") (annotate--read-reply src a)))))

(on-block-click! "annotate"
  (lambda (mbuf id)
    (and (string? id)
         (string-prefix? "ann:" id)
         (let* ((rest (substring-bytes id 4 (string-byte-length id)))
                (colon (annotate--index rest ":"))
                (verb (and colon (substring-bytes rest 0 colon)))
                (aid (and colon (substring-bytes rest (+ colon 1)
                                                 (string-byte-length rest))))
                (src (buffer-local mbuf 'ann-source)))
           (when (and verb src (buffer-exists? src))
             (let ((a (annotate--find src aid)))
               (when a (annotate--click! src verb a))))
           #t))))

(define-command "annotate-margin" "Toggle the annotation margin"
  (lambda ()
    (let ((buf (current-buffer))
          (win (window-showing *ann-margin*)))
      (if win
          (delete-window-id! win)
          (begin
            (annotate--margin-ensure! buf)
            (display-buffer-other-window! *ann-margin*))))))

;;; --- adding an annotation by hand --------------------------------------------

(define-command "annotate-add" "Annotate the region or this line"
  (lambda ()
    (let* ((buf (current-buffer))
           (match (if (and (mark) (< (region-beginning) (region-end)))
                      (substring-bytes (buffer-text buf)
                                       (region-beginning) (region-end))
                      ""))
           (line (line-number-at-pos (point))))
      (minibuffer-read "Annotation: " '()
        (lambda (text)
          (unless (equal? (string-trim text) "")
            (unless (minor-mode-on? buf "annotate-mode")
              (enable-minor-mode! buf "annotate-mode"))
            (annotate! buf (list 'source "reader" 'severity "note"
                                 'line line 'match match
                                 'title text 'who "you" 'when "now"))
            (message (string-append "Annotated L" (number->string line)))))))))

(global-set-key "C-c ! a" "annotate-add")

(mode-doc! "annotate-mode"
  (string-append
    "Margin notes on this document. `C-c ! a` adds a note on the region "
    "or the line. `M-n` / `M-p` walk the notes. `C-c ! m` toggles the "
    "margin, `C-c ! l` lists the notes. A note anchors to its matched "
    "text and follows it through edits."))

(mode-doc! "annotate-margin-mode"
  (string-append
    "The annotation cards beside the document. Click a card to go to "
    "its note in the document. The chips resolve, fix, or dismiss the "
    "note. `C-c C-v` visits the annotations file."))

;;; --- annotate-mode: the minor mode on the source buffer ---------------------

(register-minor-mode! "annotate-mode"
  (lambda (buf)
    (local-set-key* buf "M-n" "annotate-next")
    (local-set-key* buf "M-p" "annotate-prev")
    ;; also global — bound here so describe-mode's key table shows it
    (local-set-key* buf "C-c ! a" "annotate-add")
    (local-set-key* buf "C-c ! l" "annotate-list")
    (local-set-key* buf "C-c ! m" "annotate-margin")
    (annotate--store-load! buf)
    (annotate--ensure-hook! buf)
    (annotate--check! buf)
    (annotate--margin-ensure! buf)
    (annotate--paint! buf))
  (lambda (buf)
    (local-unset-key* buf "M-n")
    (local-unset-key* buf "M-p")
    (local-unset-key* buf "C-c ! a")
    (local-unset-key* buf "C-c ! l")
    (local-unset-key* buf "C-c ! m")
    (overlay-clear! buf 'annotate)
    ;; the margin belongs to the mode: turning the mode off takes the
    ;; margin window with it
    (when (and (buffer-exists? *ann-margin*)
               (equal? (buffer-local *ann-margin* 'ann-source) buf))
      (let ((win (window-showing *ann-margin*)))
        (when win (delete-window-id! win))))))

(define-command "annotate-mode" "Toggle annotations in this buffer"
  (lambda ()
    (if (toggle-minor-mode! "annotate-mode")
        (message "annotate-mode on — M-n/M-p walk annotations, C-c ! l lists them")
        (message "annotate-mode off"))))

(public! 'annotate--paint!
  "(annotate--paint! BUF) — repaint BUF's annotation overlays from its 'annotations local")
