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
  "Go to the definition of the scheme name at point, or follow the link there"
  (lambda ()
    (unless (goto-address-follow-at-point!)
      (scheme-ide--goto-definition!))))

(define (scheme-ide--goto-definition!)
    (let ((sym (scheme-ide--symbol-at)))
      (if (not sym)
          (message "No name at point")
          (let ((hit (scheme-ide--find-def sym)))
            (cond
              (hit
               (lsp--push-marker!)
               (if (equal? (car hit) 'buffer)
                   (switch-to-buffer! (cadr hit))
                   (visit (cadr hit)))
               (goto-char! (caddr hit))
               (message (string-append "Definition of " sym)))
              ((primitive-doc sym)
               (message (string-append sym " is a primitive — " (primitive-doc sym))))
              (else (message (string-append "No definition of " sym))))))))

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

;; The special forms. The interpreter handles them, so they are in no
;; primitive table and in no catalog: without this list "defi" offered
;; every define-* there is and not `define' itself.
(define *scheme-ide-syntax*
  '("define" "define-syntax" "lambda" "let" "let*" "letrec" "named-lambda"
    "if" "cond" "case" "when" "unless" "and" "or" "not"
    "begin" "do" "quote" "quasiquote" "unquote" "set!"
    "else" "delay" "force" "apply" "error"))

(define (scheme-ide--completion-row name kind doc)
  (list name kind "symbol" '() ""
        (if (and (string? doc) (not (equal? doc "")))
            (list (list "Documentation" doc)) '())))

(define (scheme-ide--syntax-doc name)
  (cond
    ((equal? name "define") "(define NAME VALUE)\n(define (NAME ARG ...) BODY ...)\n\nBind a value or define a named function.")
    ((equal? name "lambda") "(lambda (ARG ...) BODY ...)\n\nCreate an anonymous function.")
    ((equal? name "if") "(if TEST THEN ELSE)\n\nEvaluate THEN when TEST is true, otherwise ELSE.")
    ((equal? name "let") "(let ((NAME VALUE) ...) BODY ...)\n\nEvaluate BODY with local bindings.")
    ((equal? name "let*") "(let* ((NAME VALUE) ...) BODY ...)\n\nBind names in order; later values can use earlier bindings.")
    ((equal? name "begin") "(begin EXPR ...)\n\nEvaluate expressions in order and return the last value.")
    ((equal? name "set!") "(set! NAME VALUE)\n\nChange the value of an existing binding.")
    (else #f)))

;; Orderless, the way every other list in this editor narrows. The text
;; before point is terms split on '-', and a name matches when it holds
;; every term, in any order and in any case: "buf-text" finds
;; buffer-text, and so does "text-buf". A prefix match is still what you
;; meant when you typed a prefix, so prefixes lead the list.
(define (scheme-ide--terms text)
  (filter (lambda (t) (not (equal? t "")))
          (string-split (string-downcase text) "-")))

(define (scheme-ide--orderless? terms name)
  (let ((lower (string-downcase name)))
    (null? (filter (lambda (t) (not (string-contains? lower t))) terms))))

(define (scheme-ide--rows match?)
  (let* ((syn (filter match? *scheme-ide-syntax*))
         (prims (filter (lambda (e) (match? (car e))) (scheme-ide--prims)))
         (cat (filter (lambda (e) (match? (catalog--get e 'name))) (catalog)))
         (prim-names (map car prims)))
    (append
      (map (lambda (s) (scheme-ide--completion-row s "syntax" (scheme-ide--syntax-doc s)))
           syn)
      (map (lambda (e) (scheme-ide--completion-row (car e) "primitive" (cadr e)))
           (filter (lambda (e) (not (member (car e) syn))) prims))
      (map (lambda (e)
             (let ((sig (catalog--get e 'sig))
                   (doc (catalog--get e 'doc)))
               (scheme-ide--completion-row
                 (catalog--get e 'name)
                 (catalog--get e 'kind)
                 (string-append (if (string? sig) (string-append sig "\n\n") "")
                                (if (string? doc) doc "")))))
           (filter (lambda (e) (not (member (catalog--get e 'name) prim-names))) cat)))))

(define (scheme-ide--complete text)
  (let* ((lead (scheme-ide--rows (lambda (n) (string-prefix? text n))))
         (led (map car lead))
         (terms (scheme-ide--terms text))
         (rest (filter (lambda (r) (not (member (car r) led)))
                       (scheme-ide--rows
                         (lambda (n) (scheme-ide--orderless? terms n))))))
    ;; the prefix band keeps the catalog's own order. The orderless band is
    ;; ranked shortest name first: a short name holding every term is nearly
    ;; always the one meant, and buffer-context? is not buffer-text.
    (append lead
            (map caddr
                 (sort (map (lambda (r) (list (string-byte-length (car r)) (car r) r))
                            rest))))))

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

(define (scheme-ide--mode-hook!)
    (let ((buf (current-buffer)))
      (let ((cur (or (buffer-local buf 'capf-sources) '())))
        (unless (member scheme-ide--capf cur)
          (buffer-set-local! buf 'capf-sources (cons scheme-ide--capf cur))))
      (desktop-skip! buf 'capf-sources)
      (capf-auto-watch! buf)
      ;; squiggles follow edits, debounced like annotate's checker; a mode
      ;; that runs again keeps the one watch
      (buffer-watch-change! buf 'scheme-ide
        (lambda (pos inserted deleted source)
          (debounce! (string-append "scheme-ide:" buf) 400
                     scheme-ide--check! buf)))
      (scheme-ide--check! buf)))

(mode-keys! "scheme-mode"
  '(
    ("M-." "scheme-goto-definition")
    ("C-c C-d" "scheme-doc")))

(add-hook! 'scheme-mode-hook 'scheme-ide--mode-hook!)

(public! 'scheme-ide--find-def
  "(scheme-ide--find-def SYM) — (SOURCE NAME BYTE-POS) of a scheme definition, or #f")

;;; --- a definition in prose: show it, then go there -------------------------
;;; Emacs has three verbs for showing a buffer. switch-to-buffer shows it
;;; in the selected window. display-buffer shows it in another window and
;;; leaves point where it is. pop-to-buffer shows it and selects it. `M-.`
;;; in a code buffer is pop-to-buffer at the definition.
;;;
;;; A prose buffer names many definitions. The reader wants to check each
;;; one and go to few. That is display-buffer: the definition opens
;;; normally in another window by the display chain and the focus stays.
;;; The command run again on the same name goes there.

(domain! 'code)
(effects! '(read))

;; the last definition shown: (NAME WINDOW), or #f
(define definition--last #f)

(define (definition--name) (symbol-at-point-in *scheme-ide-chars*))

;; -> (SOURCE-KIND TARGET BYTE-POS) or #f. One chain for every buffer:
;; the Scheme catalog sources. A file target is a path; a file buffer is
;; named by its path, so the target is also the buffer name.
(define (definition-locate name &optional kind)
  (scheme-ide--find-def name kind))

;; the window of the last definition shown, while it still shows it
(define (definition--window)
  (and definition--last
       (window-exists? (cadr definition--last))
       (cadr definition--last)))

(define (definition--show! name hit)
  (let* ((target (cadr hit))
         (buf (if (equal? (car hit) 'buffer) target (visit-quietly target)))
         (win (display-buffer-other-window! buf)))
    (when (window-exists? win) (window-set-point! win (caddr hit)))
    (set! definition--last (list name win))
    win))

(define (definition--go!)
  (let ((name (car definition--last)) (win (definition--window)))
    (set! definition--last #f)
    (lsp--push-marker!)
    (select-window! win)
    (message (string-append "Definition of " name))))

(define-command "definition-show"
  "Show the definition of the name at point in the other window; run again to go there; a link there is followed"
  (lambda ()
    (unless (goto-address-follow-at-point!)
      (definition-show!))))

(define (definition-show!)
    (let ((name (definition--name)))
      (cond
        ((not name) (message "No name at point"))
        ((and (definition--window) (equal? name (car definition--last)))
         (definition--go!))
        (else
          (set! definition--last #f)
          (let ((hit (definition-locate name)))
            (cond
              (hit
                (definition--show! name hit)
                (message (string-append "Definition of " name " in the other window; press again to go there")))
              ((and (boundp 'primitive-doc) (primitive-doc name))
               (message (string-append name " is a primitive: " (primitive-doc name))))
              (else (message (string-append "No definition of " name)))))))))

(define-command "definition-go"
  "Go to the definition the other window shows"
  (lambda ()
    (if (definition--window)
        (definition--go!)
        (message "No definition shown"))))

(for-each (lambda (name) (undo-exempt! name))
          '("definition-show" "definition-go"))

(public! 'definition-locate
  "(definition-locate NAME [KIND]) -- (SOURCE-KIND TARGET BYTE-POS) of NAME's definition, or #f")
