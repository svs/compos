;;; morg-show-source.scm --- a block that shows a snippet of a source file.
;;;
;;; Add `:show-source PATH::WHAT` after a fence language. The body is a
;;; view of the file, not a copy you keep: `C-c C-c` fills it from the
;;; file, and M-x morg-show-source fills every such block in the
;;; document. An edit in the body never reaches the file, and the next
;;; fill replaces it. Nothing is ever written to PATH.
;;;
;;; WHAT names the snippet. A file is too big to show; a snippet is small.
;;;   ::NAME    the definition called NAME
;;;   ::12      the definition that holds line 12
;;;   ::12-30   lines 12 to 30
;;;   (none)    the whole file
;;;
;;; ```scheme :show-source ../priv/editor.scm::mouse-select-window!
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

;; the PATH::WHAT token after :show-source in INFO, or #f
(define (morg-show-source-target info)
  (let ((g (re-groups ":show-source[ \t]+([^ \t]+)" info 0)))
    (and g
         (let ((r (nth 1 g)))
           (substring-bytes info (car r) (cadr r))))))

;; "PATH::WHAT" -> (PATH WHAT); WHAT is "" without the marker
(define (show-source--split target)
  (let ((i (string-index target "::")))
    (if i
        (list (substring-bytes target 0 i)
              (substring-bytes target (+ i 2) (string-byte-length target)))
        (list target ""))))

;; lines FROM to TO of TEXT, 1-based and inclusive, with a final newline
(define (show-source--lines text from to)
  (let* ((lines (string-split text "\n"))
         (count (length lines)))
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

(define (show-source--definition path what)
  (show-source--in-buffer path
    (lambda (buf)
      (let ((rows (code-outline buf)))
        (cond
          ((string? rows) (list 'error rows))
          ((re-match "^[0-9]+$" what)
           (code-read buf (string->number what)))
          (else
            (let ((row (show-source--row rows what)))
              (if row
                  (code-read buf (car row))
                  (list 'error (string-append "no definition called " what
                                              " in " path))))))))))

;; the snippet TARGET names, as text, or (error MSG)
(define (show-source-snippet buf target)
  (let* ((parts (show-source--split target))
         (path (morg-tangle-path buf (car parts)))
         (what (cadr parts))
         (range (re-groups "^([0-9]+)-([0-9]+)$" what 0)))
    (cond
      ((not (file-exists? path)) (list 'error (string-append "no such file: " path)))
      ((equal? what "") (read-file path))
      (range
       (show-source--lines (read-file path)
                           (string->number (substring-bytes what (car (nth 1 range)) (cadr (nth 1 range))))
                           (string->number (substring-bytes what (car (nth 2 range)) (cadr (nth 2 range))))))
      (else (show-source--definition path what)))))

;; The body's bytes: after the open fence's newline, up to the close
;; fence's line. An empty body is one point, where the two meet.
(define (show-source--body-span buf block)
  (let* ((start (nth 0 block)) (end (nth 1 block))
         (lines (string-split (block-text-at buf start end) "\n"))
         (bs (+ start (string-byte-length (car lines)) 1))
         (close-start (- end (string-byte-length (car (reverse lines))))))
    (list (min bs close-start) close-start)))

(effects! '(write))

;; fill BLOCK's body from its target; -> (ok LANG) or (error MSG)
(define (morg-show-source-fill! buf block lang)
  (let ((target (morg-show-source-target (nth 2 block))))
    (if (not target)
        (list 'error "The block names no :show-source PATH")
        (let ((text (show-source-snippet buf target)))
          (if (string? text)
              (let* ((span (show-source--body-span buf block))
                     (norm (if (string-suffix? "\n" text) text (string-append text "\n"))))
                (block-replace! buf (car span) (cadr span) norm)
                (list 'ok lang))
              text)))))

;; C-c C-c on the block fills it: the argument owns the run
(fence-arg-run! ":show-source"
  (lambda (buf block lang body) (morg-show-source-fill! buf block lang)))

;; every :show-source block in BUF, last first, so an earlier fill does
;; not move a later block's bytes. -> the count filled
(define (morg-show-source-buffer! buf)
  (let ((blocks (filter (lambda (b) (morg-show-source-target (nth 2 b)))
                        (block-list buf))))
    (for-each
      (lambda (b)
        (let ((r (morg-show-source-fill! buf b (block-lang b))))
          (when (equal? (car r) 'error) (message (cadr r)))))
      (reverse blocks))
    (length blocks)))

(define-command "morg-show-source" "Fill every :show-source block from its file"
  (lambda ()
    (let ((n (morg-show-source-buffer! (current-buffer))))
      (message
        (if (= n 0)
            "No blocks have :show-source PATH"
            (string-append "Filled " (number->string n)
                           (if (= n 1) " block" " blocks")))))))

(public! 'show-source-snippet
  "(show-source-snippet BUF TARGET) — the text PATH::WHAT names, relative to BUF's directory: a definition by name, the definition at a line, a line range, or the file; or (error MSG)")
(public! 'morg-show-source-fill!
  "(morg-show-source-fill! BUF BLOCK LANG) — replace BLOCK's body with the snippet its :show-source names")
(public! 'morg-show-source-buffer!
  "(morg-show-source-buffer! BUF) — fill every :show-source block in BUF; returns the count")

;; Do not leak this extension's catalog context into user packages.
(package! morg-show-source-parent-package morg-show-source-parent-namespace)
(domain! morg-show-source-parent-domain)
(effects! morg-show-source-parent-effects)
