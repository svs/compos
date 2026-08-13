;;; custom.scm --- Emacs-style customization, entirely in userland Scheme.
;;;
;;; defgroup/defcustom registry, describe/apropos (data out — the agent's
;;; discovery surface), the custom file (<home>/custom.scm, loaded last at
;;; boot so saved customizations win over themes and init), and per-buffer
;;; face remapping (buffer-face! — CSS variable overrides scoped to the
;;; buffer's window).
;;;
;;; No macros yet, so defcustom takes a quoted symbol:
;;;   (defcustom 'org-font-family "Spectral" "Font for org buffers."
;;;     'group 'org 'type 'string)
;;; Optional opts: 'group SYM  'type SYM  'set FN (called with the new value
;;; after the variable is set — for customizations needing a side effect).

;; one plist-get, in editor.scm. This name stays — 27 call sites use it —
;; but the implementation does not: the copy here crashed on an
;; odd-length plist where the original returns #f.
(define (custom--plist-get pl key) (plist-get pl key))

(define (custom--alist-put alist key val)
  (cons (list key val)
        (remove (lambda (e) (equal? (car e) key)) alist)))

;;; --- registries --------------------------------------------------------------

(define *custom-groups* '())    ; (name doc)
(define *custom-vars* '())      ; (name (default V doc S group G type T set F))
(define *custom-set-vars* '())  ; saved (name value) — mirrors the custom file
(define *custom-set-faces* '()) ; saved (face (attr val ...))

(define (defgroup name doc)
  (set! *custom-groups* (custom--alist-put *custom-groups* name doc))
  name)

(define (defcustom name default doc &rest opts)
  (set! *custom-vars*
    (custom--alist-put *custom-vars* name
                       (append (list 'default default 'doc doc) opts)))
  ;; a saved value wins; otherwise the default — unless init.scm already
  ;; defined the variable itself (user set!s beat defaults, like setq)
  (let ((saved (assoc name *custom-set-vars*)))
    (cond (saved (set-symbol-value! name (cadr saved)))
          ((not (boundp name)) (set-symbol-value! name default))))
  name)

;;; --- describe / apropos: data for humans and agents alike --------------------

(define (describe-variable-data name)
  (let ((rec (assoc name *custom-vars*)))
    (append (list 'name name
                  'value (if (boundp name) (symbol-value name) 'unbound))
            (if rec (cadr rec) '()))))

(define (customize-apropos pattern)
  (map (lambda (v) (describe-variable-data (car v)))
       (filter (lambda (v)
                 (or (re-match? pattern (symbol->string (car v)))
                     (re-match? pattern (custom--plist-get (cadr v) 'doc))))
               *custom-vars*)))

(define (custom-group-variables group)
  (filter (lambda (v) (equal? (custom--plist-get (cadr (assoc v *custom-vars*)) 'group) group))
          (map car *custom-vars*)))

;;; --- setting and saving ------------------------------------------------------

(define (customize-set! name value)
  (set-symbol-value! name value)
  (let* ((rec (assoc name *custom-vars*))
         (setter (and rec (custom--plist-get (cadr rec) 'set))))
    (when setter (setter value)))
  value)

;; the forms the custom file contains — applying them records them, so the
;; file round-trips
(define (custom-set-variables! &rest entries)
  (for-each (lambda (e)
              (set! *custom-set-vars* (custom--alist-put *custom-set-vars* (car e) (cadr e)))
              (customize-set! (car e) (cadr e)))
            entries))

(define (custom-set-faces! &rest entries)
  (for-each (lambda (e)
              (set! *custom-set-faces* (custom--alist-put *custom-set-faces* (car e) (cadr e)))
              (apply set-face-attribute! (cons (car e) (cadr e))))
            entries))

(define (customize-save! name value)
  (customize-set! name value)
  (set! *custom-set-vars* (custom--alist-put *custom-set-vars* name value))
  (custom-write!))

(define (customize-save-face! face &rest attrs)
  (custom-set-faces! (list face attrs))
  (custom-write!))

;; saved face customizations re-apply on top of any theme (Emacs precedence:
;; customize beats themes) — load-theme is wrapped below
(define (custom-reapply-faces!)
  (for-each (lambda (e) (apply set-face-attribute! (cons (car e) (cadr e))))
            *custom-set-faces*))

(define custom--load-theme load-theme)
(define (load-theme name)
  (custom--load-theme name)
  (custom-reapply-faces!))

;;; --- the custom file ---------------------------------------------------------

(define (custom-file) (string-append (aimax-home) "/custom.scm"))

(define (custom--entry e)
  (string-append "  '(" (symbol->string (car e)) " " (value->string (cadr e)) ")"))

(define (custom-write!)
  (write-file! (custom-file)
    (string-append
      ";;; custom.scm --- written by customize; loaded last at boot.\n"
      ";;; Hand-edits survive until the next customize-save.\n"
      "(custom-set-variables!\n"
      (string-join (map custom--entry (reverse *custom-set-vars*)) "\n")
      ")\n"
      "(custom-set-faces!\n"
      (string-join (map custom--entry (reverse *custom-set-faces*)) "\n")
      ")\n")))

;;; --- per-buffer face remapping ----------------------------------------------
;;; A remap is CSS variable overrides on the buffer's window div: any face
;;; var (--FACE-ATTR) redefined there wins inside that window only. The
;;; remap alist persists in a buffer local; the derived CSS rides the
;;; existing 'style local the renderer already applies.

(define (face-remap--css remap)
  (fold (lambda (acc e)
          (let ((face (symbol->string (car e))))
            (let loop ((kvs (cadr e)) (s acc))
              (if (null? kvs) s
                  (loop (cdr (cdr kvs))
                        (string-append s "--" face "-" (symbol->string (car kvs)) ":"
                                       (let ((v (cadr kvs)))
                                         (if (string? v) v (value->string v)))
                                       ";"))))))
        "" remap))

(define (face-remap-in! buf face attrs)
  (let* ((old (or (buffer-local buf 'face-remap) '()))
         (remap (custom--alist-put old face attrs)))
    (buffer-set-local! buf 'face-remap remap)
    (buffer-set-local! buf 'style (face-remap--css remap))
    remap))

(define (face-remap! face &rest attrs)
  (face-remap-in! (current-buffer) face attrs))

;; (buffer-face! 'family "Spectral" 'size "17px") — remap the default face,
;; i.e. this buffer's text font. Emacs: buffer-face-mode.
(define (buffer-face! &rest attrs)
  (apply face-remap! (cons 'default attrs)))

;;; --- interactive layer -------------------------------------------------------

(define (custom--var-candidates)
  (map (lambda (v)
         (list (symbol->string (car v))
               (let ((doc (custom--plist-get (cadr v) 'doc))) (or doc ""))))
       (reverse *custom-vars*)))

(define (custom--read-value name save)
  (minibuffer-read
    (string-append "Set " (symbol->string name) " (Scheme expression): ")
    '()
    (lambda (src)
      (let ((value (eval-string src)))
        (if save (customize-save! name value) (customize-set! name value))
        (message (string-append (symbol->string name) " = " (value->string value)
                                (if save "  (saved)" "")))))))

(define (custom--pick-variable k)
  (minibuffer-read "Customize variable: " (custom--var-candidates)
    (lambda (name) (k (string->symbol name)))))

(define-command "customize-set-variable" "Set a variable for this session only"
  (lambda () (custom--pick-variable (lambda (name) (custom--read-value name #f)))))

(define-command "customize-save-variable" "Set a variable and save it for future sessions"
  (lambda () (custom--pick-variable (lambda (name) (custom--read-value name #t)))))

;; M-x customize — pick, set, save. The friendly path.
(define-command "customize" "Pick a customizable variable, set it, and save"
  (lambda () (custom--pick-variable (lambda (name) (custom--read-value name #t)))))

(define-command "describe-variable" "Display a variable's value and documentation"
  (lambda ()
    (custom--pick-variable
      (lambda (name)
        (let ((d (describe-variable-data name)))
          (message (string-append
                     (symbol->string name) " = "
                     (value->string (custom--plist-get d 'value))
                     " — " (or (custom--plist-get d 'doc) "undocumented"))))))))

;; the supported customize surface
(category! 'customize)
(public! 'defcustom "(defcustom 'name DEFAULT DOC 'group G 'type T) — declare a customizable variable")
(public! 'customize-save! "(customize-save! 'name VALUE) — set + persist to custom.scm")
(public! 'customize-apropos "(customize-apropos PATTERN) — search customizables by name/doc")
(public! 'customize-save-face! "(customize-save-face! 'face 'attr VALUE) — persist one face attribute")
