;;; scheme-ide.scm --- the editor is its own scheme language server.
;;;
;;; No external server can know this dialect: the vocabulary lives in
;;; the catalog, the primitive doc tables, and the source on disk. So
;;; scheme-mode buffers get definition, docs, completion, and syntax
;;; squiggles from the editor itself — no protocol, no subprocess.
;;;
;;;   M-.      scheme-goto-definition — open buffers, then the bundled
;;;            source, then ~/.compos; a primitive echoes its doc
;;;   M-,      the lsp marker stack takes the jump back
;;;   C-c C-d  scheme-doc — one line in the echo area
;;;   C-M-i    completion over primitives and the catalog
;;;   squiggles: tree-sitter ERROR nodes, when the scheme grammar is
;;;   installed (M-x ts-install-grammar scheme)

(package! 'scheme-ide)
(category! 'code)
(domain! 'code)
(effects! '(read))

;; scheme names use more bytes than the word alphabet
(define *scheme-ide-chars* (string-append *symbol-chars* "*<>=+/"))

(define (scheme-ide--symbol-at) (symbol-at-point-in *scheme-ide-chars*))

;;; --- definition --------------------------------------------------------------

;; One name can be a function and a command at once: find-file is both.
;; KIND says which definition the caller asked for, so a help page about a
;; command reaches the command. Every other pattern still follows, so a
;; link whose kind no longer holds finds the name anyway.
(define (scheme-ide--command-patterns s)
  (list (string-append "(define-command \"" s "\"")))

(define (scheme-ide--mode-patterns s)
  (list (string-append "(define-mode \"" s "\"")
        (string-append "(define-list-mode! \"" s "\"")))

(define (scheme-ide--value-patterns s)
  (list (string-append "(define (" s " ")
        (string-append "(define (" s ")")
        (string-append "(define (" s "\n")
        (string-append "(define " s " ")
        (string-append "(define " s "\n")
        (string-append "(defcustom '" s " ")
        (string-append "(defgroup '" s " ")))

(define (scheme-ide--def-patterns s &optional kind)
  (let ((command (scheme-ide--command-patterns s))
        (mode (scheme-ide--mode-patterns s))
        (value (scheme-ide--value-patterns s)))
    (cond ((equal? kind 'command) (append command value mode))
          ((equal? kind 'mode) (append mode value command))
          (else (append value command mode)))))

(define (scheme-ide--scm? name) (string-suffix? ".scm" name))

(define (scheme-ide--dir-files dir)
  (map (lambda (n) (string-append dir "/" n))
       (filter scheme-ide--scm? (or (list-dir dir) '()))))

;; where a name can be defined, in answer order: what is open wins,
;; then the editor's own source, then the user's config
(define (scheme-ide--sources)
  (let ((open (filter (lambda (b)
                        (equal? (buffer-local b 'mode-name) "scheme-mode"))
                      (buffer-list))))
    (append
      (map (lambda (b) (list 'buffer b)) open)
      (map (lambda (f) (list 'file f))
           (filter (lambda (f) (not (member f open)))
                   (append (scheme-ide--dir-files (priv-path ""))
                           (scheme-ide--dir-files (priv-path "packages"))
                           (scheme-ide--dir-files (compos-config-dir))))))))

(define (scheme-ide--search-text text pats)
  (let loop ((ps pats))
    (cond ((null? ps) #f)
          ((string-index text (car ps)))
          (else (loop (cdr ps))))))

;; -> (SOURCE-KIND NAME BYTE-POS) or #f
(define (scheme-ide--find-def sym &optional kind)
  (let ((pats (scheme-ide--def-patterns sym kind)))
    (let loop ((ss (scheme-ide--sources)))
      (if (null? ss)
          #f
          (let* ((src (car ss))
                 (text (if (equal? (car src) 'buffer)
                           (buffer-text (cadr src))
                           (read-file (cadr src))))
                 (hit (and text (scheme-ide--search-text text pats))))
            (if hit
                (list (car src) (cadr src) hit)
                (loop (cdr ss))))))))

(define-command "scheme-goto-definition"
  "Go to the definition of the scheme name at point"
  (lambda ()
    (let ((sym (scheme-ide--symbol-at)))
      (if (not sym)
          (message "No name at point")
          (let ((hit (scheme-ide--find-def sym)))
            (cond
              (hit
               (when (boundp 'lsp--push-marker!) (lsp--push-marker!))
               (if (equal? (car hit) 'buffer)
                   (switch-to-buffer! (cadr hit))
                   (visit (cadr hit)))
               (goto-char! (caddr hit))
               (message (string-append "Definition of " sym)))
              ((primitive-doc sym)
               (message (string-append sym " is a primitive — " (primitive-doc sym))))
              (else (message (string-append "No definition of " sym)))))))))

;;; --- one-line docs -----------------------------------------------------------

(define (scheme-ide--catalog-doc sym)
  (let loop ((es (catalog)))
    (cond ((null? es) #f)
          ((equal? (catalog--get (car es) 'name) sym)
           (let ((d (catalog--get (car es) 'doc)))
             (and d (string-append "[" (catalog--get (car es) 'kind) "] " d))))
          (else (loop (cdr es))))))

(define (scheme-ide--doc sym)
  (or (primitive-doc sym) (scheme-ide--catalog-doc sym)))

(define-command "scheme-doc" "Echo the doc of the scheme name at point"
  (lambda ()
    (let ((sym (scheme-ide--symbol-at)))
      (if (not sym)
          (message "No name at point")
          (message (or (scheme-ide--doc sym)
                       (string-append "No doc for " sym)))))))

;;; --- completion --------------------------------------------------------------

;; the primitive table is per-session-stable; fetch it once
(define *scheme-ide-prims* #f)

(define (scheme-ide--prims)
  (unless *scheme-ide-prims* (set! *scheme-ide-prims* (primitive-docs)))
  *scheme-ide-prims*)

(define (scheme-ide--complete prefix)
  (let ((prims (filter (lambda (e) (string-prefix? prefix (car e)))
                       (scheme-ide--prims)))
        (cat (filter (lambda (e)
                       (string-prefix? prefix (catalog--get e 'name)))
                     (catalog))))
    (let ((prim-names (map car prims)))
      (append
        (map (lambda (e) (list (car e) "primitive")) prims)
        (map (lambda (e) (list (catalog--get e 'name) (catalog--get e 'kind)))
             (filter (lambda (e) (not (member (catalog--get e 'name) prim-names)))
                     cat))))))

(define (scheme-ide--capf)
  (let* ((buf (current-buffer))
         (text (buffer-text buf))
         (e (point))
         (s (let loop ((i e))
              (if (and (> i 0)
                       (let ((c (substring-bytes text (- i 1) i)))
                         (and (not (equal? c ""))
                              (string-index *scheme-ide-chars* c))))
                  (loop (- i 1))
                  i))))
    (if (>= s e)
        #f
        (let ((cands (scheme-ide--complete (substring-bytes text s e))))
          (if (null? cands) #f (list s e cands))))))

;;; --- squiggles: tree-sitter ERROR nodes --------------------------------------

(define (scheme-ide--check! buf)
  (when (and (buffer-exists? buf)
             (equal? (buffer-local buf 'mode-name) "scheme-mode")
             (member "scheme" (ts-langs)))
    (overlay-set! buf 'scheme-ide
      (map (lambda (cap) (list (cadr cap) (caddr cap) "scheme-err"))
           (ts-query-string "scheme" (buffer-text buf) "(ERROR) @err")))))

(define-style! 'scheme-ide "
.f-scheme-err{text-decoration:underline wavy var(--alert-fg,#a83a2b);text-decoration-skip-ink:none}
")

;;; --- wiring ------------------------------------------------------------------

(add-hook! 'scheme-mode-hook
  (lambda ()
    (let ((buf (current-buffer)))
      (local-set-key "M-." "scheme-goto-definition")
      (local-set-key "C-c C-d" "scheme-doc")
      (let ((cur (or (buffer-local buf 'capf-sources) '())))
        (unless (member scheme-ide--capf cur)
          (buffer-set-local! buf 'capf-sources (cons scheme-ide--capf cur))))
      (desktop-skip! buf 'capf-sources)
      ;; squiggles follow edits, debounced like annotate's checker; the
      ;; watch survives mode re-entry because on-change! ids are per call
      (unless (buffer-local buf 'scheme-ide-watch)
        (desktop-skip! buf 'scheme-ide-watch)
        (buffer-set-local! buf 'scheme-ide-watch
          (on-change! buf
            (lambda (pos inserted deleted source)
              (debounce! (string-append "scheme-ide:" buf) 400
                         scheme-ide--check! buf)))))
      (scheme-ide--check! buf))))

(public! 'scheme-ide--find-def
  "(scheme-ide--find-def SYM) — (SOURCE NAME BYTE-POS) of a scheme definition, or #f")
