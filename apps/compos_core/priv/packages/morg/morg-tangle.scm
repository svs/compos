;;; morg-tangle.scm --- write Morg code blocks to source files.
;;;
;;; Add `:tangle PATH` after a fence language. M-x morg-tangle writes all
;;; marked blocks. Blocks with one target join in document order. The
;;; written file is write-protected: the document is the source, and the
;;; file opens read-only. There is no way back from the file to the
;;; document.
;;;
;;; ```elixir :tangle lib/demo.ex
;;; IO.puts("hello")
;;; ```

(define morg-tangle-parent-package *loading-package*)
(define morg-tangle-parent-namespace *loading-namespace*)
(define morg-tangle-parent-domain *catalog-domain*)
(define morg-tangle-parent-effects *catalog-effects*)

(package! 'morg-tangle 'morg)
(domain! 'writing)
(effects! '(write))

(define (morg-tangle-target entry)
  (let ((g (re-groups ":[Tt][Aa][Nn][Gg][Ll][Ee][ \t]+([^ \t]+)"
                      (cadr entry) 0)))
    (and g
         (let ((r (nth 1 g)))
           (substring-bytes (cadr entry) (car r) (cadr r))))))

(define (morg-tangle-path buf target)
  (cond ((or (string-prefix? "/" target) (string-prefix? "~" target))
         (expand-path target))
        (else (expand-path (string-append (buffer-directory buf) target)))))

(define (morg-tangle-add specs path body)
  (if (assoc path specs)
      (map (lambda (row)
             (if (equal? (car row) path)
                 (list path (string-append (cadr row) body))
                 row))
           specs)
      (append specs (list (list path body)))))

;; Return ((absolute-path text) ...) for every :tangle block in BUF.
(define (morg-tangle-specs buf)
  (let* ((scan (morg-scan buf))
         (text (buffer-text buf)))
    (fold
      (lambda (specs block)
        (let* ((open (morg-entry-at scan (car block)))
               (target (morg-tangle-target open))
               (lang (cadr block)))
          (if (or (not target) (equal? (string-downcase target) "no")
                  (equal? lang "result"))
              specs
              (let* ((body (substring-bytes text (caddr block) (nth 3 block)))
                     (norm (if (string-suffix? "\n" body)
                               body (string-append body "\n"))))
                (morg-tangle-add specs (morg-tangle-path buf target) norm)))))
      '()
      (morg-blocks scan buf))))

;; The document is the source. The written file is write-protected on
;; disk, so it opens read-only in the editor and refuses other editors
;; too. A file from an earlier tangle is write-protected already; the
;; write lifts that for one moment. A buffer that shows the file turns
;; read-only at once, since a revert runs no find-file-hook.
(define (morg-tangle-write! path text)
  (when (file-exists? path) (set-file-mode! path "644"))
  (write-file! path text)
  (set-file-mode! path "444")
  (when (buffer-exists? path) (buffer-set-read-only! path #t)))

(define (morg-tangle-buffer! buf)
  (let ((specs (morg-tangle-specs buf)))
    (for-each (lambda (row) (morg-tangle-write! (car row) (cadr row))) specs)
    (map car specs)))

(define-command "morg-tangle" "Write all Morg blocks with :tangle PATH headers"
  (lambda ()
    (let ((paths (morg-tangle-buffer! (current-buffer))))
      (message
        (if (null? paths)
            "No blocks have :tangle PATH"
            (string-append "Tangled " (number->string (length paths))
                           (if (= (length paths) 1) " file" " files")))))))

(public! 'morg-tangle-specs
  "(morg-tangle-specs BUF) — return each output path and text for Morg :tangle blocks")
(public! 'morg-tangle-buffer!
  "(morg-tangle-buffer! BUF) — write all Morg :tangle blocks and return their paths")

;; Do not leak this extension's catalog context into user packages.
(package! morg-tangle-parent-package morg-tangle-parent-namespace)
(domain! morg-tangle-parent-domain)
(effects! morg-tangle-parent-effects)
