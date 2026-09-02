;;; morg-show-source.scm --- a block that shows definitions from source files.
;;;
;;; Add `:show-source PATH::NAME,NAME...` after a fence language. The body
;;; is a view of the file, not a copy you keep: `C-c C-c` fills it from
;;; the file, and M-x morg-show-source fills every such block in the
;;; document. An edit in the body never reaches the file, and the next
;;; fill replaces it. Nothing is ever written to PATH.
;;;
;;; One block shows many definitions, from one file or several. Each
;;; target is PATH::WHAT, and WHAT is a comma list. The snippets follow
;;; the order named, with a blank line between them.
;;;   ::NAME    the definition called NAME
;;;   ::12      the definition that holds line 12
;;;   ::12-30   lines 12 to 30
;;;   (none)    the whole file
;;;
;;; ```scheme :show-source editor.scm::visit,visit-quietly code.scm::code-read
;;; ```
;;;
;;; A relative PATH starts at the document's directory, as `:tangle` does.

(define morg-show-source-parent-package *loading-package*)
(define morg-show-source-parent-namespace *loading-namespace*)
(define morg-show-source-parent-domain *catalog-domain*)
(define morg-show-source-parent-effects *catalog-effects*)

(package! 'morg-show-source 'morg)
(domain! 'writing)
(effects! '(read))

;; the PATH::WHAT tokens after :show-source in INFO, up to the next
;; :argument; '() when the fence carries no :show-source
(define (morg-show-source-targets info)
  (let ((g (re-groups ":show-source[ \t]+(.*)$" info 0)))
    (if (not g)
        '()
        (let* ((r (nth 1 g))
               (rest (substring-bytes info (car r) (cadr r))))
          (let loop ((ws (string-split rest " ")) (acc '()))
            (cond ((null? ws) (reverse acc))
                  ((equal? (car ws) "") (loop (cdr ws) acc))
                  ((string-prefix? ":" (car ws)) (reverse acc))
                  (else (loop (cdr ws) (cons (car ws) acc)))))))))

;; "PATH::WHAT" -> (PATH WHAT); WHAT is "" without the marker
(define (show-source--split target)
  (let ((i (string-index target "::")))
    (if i
        (list (substring-bytes target 0 i)
              (substring-bytes target (+ i 2) (string-byte-length target)))
        (list target ""))))

;; lines FROM to TO of TEXT, 1-based and inclusive, with a final newline
(define (show-source--lines text from to)
  (let ((lines (string-split text "\n")))
    (let loop ((n 1) (ls lines) (acc '()))
      (cond ((or (null? ls) (> n to))
             (string-append (string-join (reverse acc) "\n") "\n"))
            ((< n from) (loop (+ n 1) (cdr ls) acc))
            (else (loop (+ n 1) (cdr ls) (cons (car ls) acc)))))))

;; the outline row whose name is NAME, else the first row that mentions
;; it, or #f
(define (show-source--row rows name)
  (or (let loop ((rs rows))
        (cond ((null? rs) #f)
              ((equal? (nth 2 (car rs)) name) (car rs))
              (else (loop (cdr rs)))))
      (let ((hits (filter (lambda (r) (if (string-index (nth 2 r) name) #t #f)) rows)))
        (and (pair? hits) (car hits)))))

;; The definition API reads a live buffer. A file that is not open is
;; opened without a window and closed again after the read.
(define (show-source--in-buffer path k)
  (let* ((known (buffer-known? path))
         (buf (visit-quietly path))
         (r (k buf)))
    (unless known (buffer-kill! buf))
    r))

(define (show-source--range what)
  (let ((g (re-groups "^([0-9]+)-([0-9]+)$" what 0)))
    (and g
         (list (string->number (substring-bytes what (car (nth 1 g)) (cadr (nth 1 g))))
               (string->number (substring-bytes what (car (nth 2 g)) (cadr (nth 2 g))))))))

;; one WHAT of PATH, given the file TEXT and the outline ROWS of the open
;; buffer BUF: text, or (error MSG)
(define (show-source--one path buf rows text what)
  (let ((range (show-source--range what)))
    (cond
      ((equal? what "") text)
      (range (show-source--lines text (car range) (cadr range)))
      ((string? rows) (list 'error rows))
      ((re-match "^[0-9]+$" what) (code-read buf (string->number what)))
      (else
        (let ((row (show-source--row rows what)))
          (if row
              (code-read buf (car row))
              (list 'error (string-append "no definition called " what " in " path))))))))

;; a WHAT that needs the outline: a name or a line, not a range or the file
(define (show-source--needs-outline? what)
  (and (not (equal? what "")) (not (show-source--range what))))

;; every snippet a comma list names, in order; the first error stops it.
;; The outline is read once, and only when a WHAT asks for a definition:
;; an outline replaces the anchors an agent holds on an open buffer.
(define (show-source--many path buf whats)
  (let ((text (buffer-text buf))
        (rows (if (pair? (filter show-source--needs-outline? whats))
                  (code-outline buf)
                  '())))
    (let loop ((ws whats) (acc '()))
      (if (null? ws)
          (reverse acc)
          (let ((r (show-source--one path buf rows text (car ws))))
            (if (string? r)
                (loop (cdr ws) (cons r acc))
                r))))))

(define (show-source--newline s)
  (if (string-suffix? "\n" s) s (string-append s "\n")))

;; the snippets TARGET names, joined with a blank line, or (error MSG)
(define (show-source-snippet buf target)
  (let* ((parts (show-source--split target))
         (path (morg-tangle-path buf (car parts)))
         (whats (filter (lambda (w) (not (equal? w "")))
                        (string-split (cadr parts) ","))))
    (if (not (file-exists? path))
        (list 'error (string-append "no such file: " path))
        (let ((r (show-source--in-buffer path
                   (lambda (b) (show-source--many path b (if (null? whats) '("") whats))))))
          (if (pair? r)
              (if (equal? (car r) 'error)
                  r
                  (string-join (map show-source--newline r) "\n"))
              r)))))

;; every target of INFO, in order, as one text, or (error MSG)
(define (show-source-text buf targets)
  (let loop ((ts targets) (acc '()))
    (if (null? ts)
        (string-join (reverse acc) "\n")
        (let ((r (show-source-snippet buf (car ts))))
          (if (string? r)
              (loop (cdr ts) (cons (show-source--newline r) acc))
              r)))))

;; The body's bytes: after the open fence's newline, up to the close
;; fence's line. An empty body is one point, where the two meet.
(define (show-source--body-span buf block)
  (let* ((start (nth 0 block)) (end (nth 1 block))
         (lines (string-split (block-text-at buf start end) "\n"))
         (bs (+ start (string-byte-length (car lines)) 1))
         (close-start (- end (string-byte-length (car (reverse lines))))))
    (list (min bs close-start) close-start)))

(effects! '(write))

;; fill BLOCK's body from its targets; -> (ok LANG) or (error MSG)
(define (morg-show-source-fill! buf block lang)
  (let ((targets (morg-show-source-targets (nth 2 block))))
    (if (null? targets)
        (list 'error "The block names no :show-source PATH")
        (let ((text (show-source-text buf targets)))
          (if (string? text)
              (let ((span (show-source--body-span buf block)))
                (block-replace! buf (car span) (cadr span) text)
                (list 'ok lang))
              text)))))

;; C-c C-c on the block fills it: the argument owns the run
(fence-arg-run! ":show-source"
  (lambda (buf block lang body) (morg-show-source-fill! buf block lang)))

;; every :show-source block in BUF, last first, so an earlier fill does
;; not move a later block's bytes. -> the count filled
(define (morg-show-source-buffer! buf)
  (let ((blocks (filter (lambda (b) (pair? (morg-show-source-targets (nth 2 b))))
                        (block-list buf))))
    (for-each
      (lambda (b)
        (let ((r (morg-show-source-fill! buf b (block-lang b))))
          (when (equal? (car r) 'error) (message (cadr r)))))
      (reverse blocks))
    (length blocks)))

(define-command "morg-show-source" "Fill every :show-source block from its files"
  (lambda ()
    (let ((n (morg-show-source-buffer! (current-buffer))))
      (message
        (if (= n 0)
            "No blocks have :show-source PATH"
            (string-append "Filled " (number->string n)
                           (if (= n 1) " block" " blocks")))))))

(public! 'show-source-snippet
  "(show-source-snippet BUF TARGET) — the text PATH::WHAT,WHAT... names, relative to BUF's directory: definitions by name, the definition at a line, a line range, or the file; or (error MSG)")
(public! 'show-source-text
  "(show-source-text BUF TARGETS) — the snippets of every PATH::WHAT target, in order, with a blank line between; or (error MSG)")
(public! 'morg-show-source-fill!
  "(morg-show-source-fill! BUF BLOCK LANG) — replace BLOCK's body with the definitions its :show-source names")
(public! 'morg-show-source-buffer!
  "(morg-show-source-buffer! BUF) — fill every :show-source block in BUF; returns the count")

;; Do not leak this extension's catalog context into user packages.
(package! morg-show-source-parent-package morg-show-source-parent-namespace)
(domain! morg-show-source-parent-domain)
(effects! morg-show-source-parent-effects)
