;;; morg-kinds.scm --- the fence-kind registry.
;;;
;;; A fenced block's info string names its kind. One registration gives a
;;; kind its paint, its runner, and its help. The fence itself supplies the
;;; scan, the folds, the region lift, and the result landing, so a kind
;;; declares only what differs.
;;;
;;; Keys a kind can declare:
;;;   ts-lang     STRING  the tree-sitter language for the body, or #f for none
;;;   body-face   STRING  one face for every body line
;;;   line-face   FN      (FN LINE) -> a face for that body line, or #f
;;;   header-face STRING  a face for the first body line
;;;   runnable    #f      the kind refuses to run (a kind runs by default)
;;;   run         FN      (FN BUF SCAN FSTART ENTRY LANG BODY) -> (ok LANG),
;;;                       (pending LANG), or (error MSG)
;;;   interpreter STRING  the shell interpreter the shared shell runner uses
;;;
;;; morg.scm and markdown-mode.scm read the paint keys. morg-babel.scm reads
;;; the run keys and registers the bundled runners.

(define morg-kinds-parent-package *loading-package*)
(define morg-kinds-parent-namespace *loading-namespace*)
(define morg-kinds-parent-domain *catalog-domain*)
(define morg-kinds-parent-effects *catalog-effects*)

(package! 'morg-kinds 'morg)
(domain! 'writing)
(effects! '(pure))

;;; --- the registry ------------------------------------------------------------

;; (NAME . PLIST), one entry per kind. Registration by name replaces the
;; old entry, so a package reload does not stack duplicates.
(define *fence-kinds* '())

(define (fence-kind--put! name plist)
  (set! *fence-kinds*
    (cons (cons name plist)
          (remove (lambda (e) (equal? (car e) name)) *fence-kinds*)))
  (fence-kind--push-run-langs!))

;; The rendered page offers the run key by language. The registry owns
;; that list, so every write pushes it to the renderer.
(define (fence-kind--push-run-langs!)
  (preview-run-langs!
    (fold (lambda (acc e)
            (if (and (fence-kind--value (cdr e) 'run #f)
                     (not (equal? (fence-kind--value (cdr e) 'runnable 'yes) #f)))
                (cons (car e) acc)
                acc))
          '()
          *fence-kinds*)))

(define (fence-kind name)
  (let ((e (assoc (string-downcase name) *fence-kinds*)))
    (and e (cdr e))))

(define (fence-kind--value plist key default)
  (cond ((or (null? plist) (null? (cdr plist))) default)
        ((equal? (car plist) key) (cadr plist))
        (else (fence-kind--value (cdr (cdr plist)) key default))))

(define (fence-kind--keys plist)
  (if (or (null? plist) (null? (cdr plist)))
      '()
      (cons (car plist) (fence-kind--keys (cdr (cdr plist))))))

(define (fence-kind--strip plist keys)
  (cond ((or (null? plist) (null? (cdr plist))) '())
        ((member (car plist) keys) (fence-kind--strip (cdr (cdr plist)) keys))
        (else (cons (car plist)
                    (cons (cadr plist)
                          (fence-kind--strip (cdr (cdr plist)) keys))))))

(define (define-fence-kind! name doc &rest opts)
  (let ((n (string-downcase name)))
    (fence-kind--put! n (append (list 'doc doc) opts))
    (catalog-register! 'fence-kind n doc
      'use (string-append "```" n " ... ``` in a Morg buffer"))
    n))

;; Add or replace KEY VALUE pairs on NAME. The kind is created when absent.
;; A package that owns one aspect of a kind merges; it does not replace.
(define (fence-kind-merge! name &rest opts)
  (let ((n (string-downcase name)))
    (fence-kind--put! n
      (append opts
        (fence-kind--strip (or (fence-kind n) '())
                           (fence-kind--keys opts))))
    n))

(define (fence-kind-get lang key default)
  (let ((k (fence-kind lang)))
    (if k (fence-kind--value k key default) default)))

;;; --- what the painters ask ---------------------------------------------------

;; The tree-sitter language for a fence's body, or #f. An info string with
;; no registration names its own grammar when that grammar is loaded.
(define (fence-kind-ts-lang lang)
  (let* ((l (string-downcase lang))
         (t (fence-kind-get l 'ts-lang l)))
    (and (string? t) (member t (ts-langs)) t)))

;; The face for one body line, or #f. A line-face function sees the line
;; text and the fence's arguments; a body-face is one face for every line.
(define (fence-kind-line-face lang line &optional args)
  (let ((f (fence-kind-get lang 'line-face #f)))
    (if (procedure? f)
        (f line args)
        (fence-kind-get lang 'body-face #f))))

(define (fence-kind-runnable? lang)
  (not (equal? (fence-kind-get lang 'runnable 'yes) #f)))

(define (fence-kind-run lang)
  (fence-kind-get lang 'run #f))

;; The block-level spans every painter shares: tree-sitter spans for a body
;; with a language, and the header face of a kind that declares one.
;; BLOCKS is (morg-blocks scan buf); TEXT is the buffer text.
(define (fence-kind-body-spans text blocks)
  (fold
    (lambda (acc b)
      (let* ((lang (nth 1 b)) (bs (nth 2 b)) (be (nth 3 b))
             (tsl (fence-kind-ts-lang lang))
             (hf (fence-kind-get lang 'header-face #f)))
        (append acc
          (if (and tsl (> be bs))
              (map (lambda (sp)
                     (list (+ bs (car sp)) (+ bs (cadr sp))
                           (string-append "ts-" (caddr sp))))
                   (ts-highlight-string tsl (substring-bytes text bs be)))
              '())
          (if (and hf (> be bs))
              (let ((header (car (split-lines (substring-bytes text bs be)))))
                (list (list bs (+ bs (string-byte-length header)) hf)))
              '()))))
    '()
    blocks))

;; The chip the preview draws on a block's fence line: the declared 'chip,
;; else the info string itself. A fence with no language draws no chip.
;; The run hint and the verbs are their own clickable chips beside it.
(define (fence-kind-chip lang &optional run-key)
  (and (string? lang)
       (not (equal? lang ""))
       (or (fence-kind-get lang 'chip #f) (string-downcase lang))))

;; The verbs a kind offers on its block, one (COMMAND TEXT) per verb whose
;; command has a key in BUF's keymap — so the chips stand exactly where
;; the verbs work, and each one is a click away.
(define (fence-kind-verb-chips lang buf)
  (let ((vs (fence-kind-get lang 'verbs #f)))
    (if (not (pair? vs))
        '()
        (reverse
          (fold (lambda (acc v)
                  (let ((k (key-for-command (car v) buf)))
                    (if (equal? k "")
                        acc
                        (cons (list (car v) (string-append k " " (cadr v)))
                              acc))))
                '() vs)))))

;; extra chips a kind draws on its open fence at START, from its own
;; state: ((TEXT CLASS [CLICK]) ...). Chrome is preview display only:
;; the system works whole in a text-only view, and the preview is a
;; fancy rendering of the same block.
(define (fence-kind-head-chrome lang buf start)
  (let ((f (fence-kind-get lang 'head-chrome #f)))
    (if (procedure? f) (f buf start) '())))

(define (describe-fence-kind name)
  (let ((k (fence-kind name)))
    (and k
         (list 'name (string-downcase name)
               'doc (fence-kind--value k 'doc "")
               'runs (and (fence-kind-runnable? name)
                          (if (fence-kind-run name) #t #f))
               'ts-lang (fence-kind-ts-lang name)
               'keys (fence-kind--keys k)))))

;;; --- the bundled paint kinds -------------------------------------------------

(define-fence-kind! "result"
  "Plain output below the block that made it. It does not run."
  'runnable #f 'body-face "morg-result")

(define-fence-kind! "result-scheme"
  "A Scheme value below the block that made it. It does not run."
  'runnable #f 'ts-lang "scheme")

(define-fence-kind! "result-csv"
  "A CSV preview below the block that made it. It does not run."
  'runnable #f 'body-face "morg-result" 'header-face "morg-bold")

;; A live diff's one-sided views (the fence args lead with the view:
;; theirs or ours) are prose: a dash there is a dash, and no line wears
;; a diff face.
(define (fence-kind--diff-line-face line &optional args)
  (cond ((and (string? args)
              (let ((a (string-trim args)))
                (or (string-prefix? "theirs" a) (string-prefix? "ours" a))))
         #f)
        ((string-prefix? "+++" line) "diff-file")
        ((string-prefix? "---" line) "diff-file")
        ((string-prefix? "@@" line) "diff-hunk")
        ((string-prefix? "+" line) "diff-add")
        ((string-prefix? "-" line) "diff-del")
        ((string-prefix? "diff " line) "diff-file")
        ((string-prefix? "index " line) "diff-file")
        (else #f)))

;; The rewrite verbs, drawn as preview chrome on the one block a live
;; record owns — never on a plain pasted diff.
(define fence-kind--rewrite-verbs
  '(("llm-rewrite-accept" "keeps it")
    ("llm-rewrite-reject" "puts it back")
    ("llm-rewrite-diff" "changes the view")))

;; The chips a live diff wears: the instruction that made it (preview
;; only), and one clickable chip per verb whose command has a key here —
;; the keys stand in every view. They stand only on the block the record
;; owns.
(define (fence-kind--diff-head-chrome buf start)
  (let ((p (and (boundp 'llm-rewrite-pending) (llm-rewrite-pending buf))))
    (if (not p)
        '()
        (let ((spans (llm-rewrite--spans buf)))
          (if (not (and spans (= start (nth 2 spans))))
              '()
              (append
                (list (list (llm-rewrite--view-name (llm-rewrite--view p))
                            "md-fence-chip f-diff-file")
                      (list (llm-rewrite--instruction p) "md-fence-note"))
                (fold (lambda (acc v)
                        (let ((k (key-for-command (car v) buf)))
                          (if (equal? k "")
                              acc
                              (append acc
                                (list (list (string-append k " " (cadr v))
                                            "md-fence-verb"
                                            (string-append "fence-cmd:" (car v))))))))
                      '() fence-kind--rewrite-verbs)))))))

(define-fence-kind! "diff"
  "A unified diff. Its lines wear the diff faces. It does not run."
  'runnable #f 'ts-lang #f 'line-face fence-kind--diff-line-face
  'fence-face "diff-file"
  'head-chrome fence-kind--diff-head-chrome)

(define-fence-kind! "patch"
  "A unified diff. The same paint as the diff kind."
  'runnable #f 'ts-lang #f 'line-face fence-kind--diff-line-face)

(define-fence-kind! "rewrite"
  "A rewrite waiting for a decision. llm-rewrite lands one below the passage; its own keys decide it. It does not run."
  'runnable #f 'ts-lang #f 'chip-args #t
  'verbs fence-kind--rewrite-verbs)

;; Info strings whose tree-sitter grammar wears another name and that
;; morg-babel gives no runner.
(for-each
  (lambda (row) (fence-kind-merge! (car row) 'ts-lang (cadr row)))
  '(("jsx" "javascript") ("ts" "typescript") ("ex" "elixir")))

;;; --- preview actions ---------------------------------------------------------
;;; A chip click is the verb it names. A verb chip carries its command; a
;;; run chip carries the block's own position, so nothing moves point.

(on-block-click! 'fence-kinds
  (lambda (buf id)
    (cond
      ((string-prefix? "fence-cmd:" id)
       (with-current-buffer buf
         (lambda ()
           (run-command (substring-bytes id 10 (string-byte-length id)))))
       #t)
      ((string-prefix? "fence-run:" id)
       (let ((pos (string->number
                    (substring-bytes id 10 (string-byte-length id)))))
         (when (number? pos) (morg-babel-execute buf pos)))
       #t)
      (else #f))))

;;; --- the public vocabulary ---------------------------------------------------

(public! 'define-fence-kind!
  "(define-fence-kind! NAME DOC KEY VALUE ...) — register a fenced-block kind: its paint, its runner, and its help in one form")
(public! 'fence-kind-merge!
  "(fence-kind-merge! NAME KEY VALUE ...) — add or replace keys on the kind NAME; the kind is created when absent")
(public! 'describe-fence-kind
  "(describe-fence-kind NAME) — the kind's doc, runnability, tree-sitter language, and declared keys, or #f")
(public! 'fence-kind-ts-lang
  "(fence-kind-ts-lang LANG) — the loaded tree-sitter language for a fence body, or #f")
(public! 'fence-kind-chip
  "(fence-kind-chip LANG) — the chip the preview draws on the fence line, or #f for a bare fence")

;; Do not leak this extension's catalog context into the next package.
(package! morg-kinds-parent-package morg-kinds-parent-namespace)
(domain! morg-kinds-parent-domain)
(effects! morg-kinds-parent-effects)
