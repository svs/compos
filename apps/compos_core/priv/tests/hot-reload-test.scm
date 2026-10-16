;;; hot-reload-test.scm --- a reload reaches the buffers already open.
;;;
;;; Session.reload_files/1 brackets every reload with reload-begin! and
;;; reload-finish!. What happens between them is policy. The rebuild
;;; half, which modes the reload named and which buffers it set up
;;; again, is proven with every other mode re-setup in
;;; scheme/packages/mode-lifecycle-test.scm. This file keeps the registry,
;;; the mode query, and what a reload must not reset or rewrap.
;;; The ExUnit side covers the watcher and the form diff.

(domain! 'testing)
(effects! '(write))

(define t--hr-a "zz-hot-reload-a")
(define t--hr-b "zz-hot-reload-b")

;; A mode whose setup fn stamps the buffer. The stamp is the evidence:
;; a new stamp in an open buffer means the setup fn ran again.
(define (t--hr-major! mode stamp)
  (define-mode mode
    (lambda () (buffer-set-local! (current-buffer) 'zz-hr-stamp stamp))))

(define (t--hr-minor! mode stamp)
  (register-minor-mode! mode
    (lambda (b) (buffer-set-local! b 'zz-hr-minor-stamp stamp))))

(deftest 'buffer-wears-mode-sees-both-halves-of-a-buffers-mode
  "the major mode and every minor mode name the buffer"
  (lambda ()
    (t--hr-major! "zz-hr-mode" 1)
    (t--hr-minor! "zz-hr-minor" 1)
    (test-buffer! t--hr-a "alpha\n")
    (with-current-buffer t--hr-a (lambda () (set-mode! "zz-hr-mode")))
    (enable-minor-mode! t--hr-a "zz-hr-minor")

    (check-true! (buffer-wears-mode? t--hr-a '("zz-hr-mode")) "the major mode")
    (check-true! (buffer-wears-mode? t--hr-a '("zz-hr-minor")) "the minor mode")
    (check-false! (buffer-wears-mode? t--hr-a '("zz-hr-absent")) "and nothing else")

    (disable-minor-mode! t--hr-a "zz-hr-minor")
    (buffer-kill! t--hr-a)))

;; M-x reload-scheme is the manual door for a purged primitive. The rebind
;; must leave the stdlib alone: editor.scm aliases define-command and then
;; wraps the same name in Scheme, and a rebind that writes the primitive map
;; straight in puts the raw primitive back over the wrapper.
(deftest 'reload-scheme-rebinds-the-primitives-and-keeps-the-stdlib
  "the alias still calls, and the Scheme wrapper is still the wrapper"
  (lambda ()
    (run-command "reload-scheme")

    ;; the wrapper answers with the name; the raw primitive answers void
    (check-equal! (define-command "zz-reload-scheme-a" "probe" (lambda () 1))
      "zz-reload-scheme-a" "the rebind put the raw primitive over the wrapper")
    (check-equal! (procedure? define-command--raw) #t
      "the alias of a Session primitive lost its fun")
    (define-command--raw "zz-reload-scheme-b" (lambda () 1))
    (check-equal! (command-doc "zz-reload-scheme-b") ""
      "the alias did not register the command")))

;;; --- a reload must not empty the state the desktop saves -----------------
;;;
;;; A top-level (define *x* '()) puts the literal back every time a reload
;;; re-evaluates it. The live value became '() while the daemon ran, and
;;; the next desktop save wrote that '() over the good file: groups, LLM
;;; bundles, connector models, registers and minibuffer history all went
;;; at once. defvar binds only a free name, so a reload keeps the value.

(deftest 'defvar-keeps-the-value-a-session-set
  "re-evaluating the definition of a defvar variable leaves the value alone"
  (lambda ()
    (defvar 'zz-reload-state '())
    (set-symbol-value! 'zz-reload-state '(one two))
    ;; this is what the reload does to the top-level form
    (defvar 'zz-reload-state '())
    (check-equal! (symbol-value 'zz-reload-state) '(one two)
      "the reload kept the live value")
    (unbind-global! 'zz-reload-state)
    (defvar 'zz-reload-state 'fresh)
    (check-equal! (symbol-value 'zz-reload-state) 'fresh
      "a free name still takes the default")
    (unbind-global! 'zz-reload-state)))

;; ((FILE VAR) ...) — every variable a persist-global! entry reads.
;; layout-targets is absent on purpose: its state fn derives the value
;; from the live frames and holds no variable a reload can reset.
(define t--reload-persisted
  '(("window.scm" "*peek-recent*")
    ("chat-mode.scm" "*llm-config-history*")
    ("chat-mode.scm" "*llm-bundles*")
    ("chat-mode.scm" "*llm-connector-models*")
    ("minibuffer.scm" "*minibuffer-history*")
    ("groups.scm" "*group-records*")
    ("groups.scm" "*group-next-id*")
    ("groups.scm" "*group-graveyard*")
    ("register.scm" "*registers*")))

(deftest 'every-persisted-global-uses-defvar
  "no persisted variable is initialized with define, which a reload resets"
  (lambda ()
    (for-each
      (lambda (entry)
        (let* ((file (car entry))
               (var (cadr entry))
               (src (read-file (locate-library file))))
          (check-equal! (string? src) #t (string-append "read " file))
          (check-equal! (string-contains? src (string-append "(defvar '" var " ")) #t
            (string-append var " uses defvar"))
          (check-equal! (string-contains? src (string-append "(define " var " ")) #f
            (string-append var " is not a bare define"))))
      t--reload-persisted)))

;; The desktop asks each global for its value on save and hands the same
;; value back on boot. Nothing checked that the two halves agree: on
;; 2026-09-16 a restore read (list? saved), a name this Scheme does not
;; have, and the one call that installs the set died on the first entry.
;; A round trip proves every restore can read what its own save wrote.
(deftest 'every-persisted-global-takes-back-what-it-gave
  "each restore accepts the value its own state fn produced"
  (lambda ()
    (let ((n 0))
      (for-each
        (lambda (e)
          (desktop-global! (car e) ((cadr e)))
          (set! n (+ n 1)))
        *desktop-globals*)
      (check-equal! n (length *desktop-globals*)
        "every global made the round trip"))))

;;; --- a reload must not point a wrapper at itself --------------------------
;;;
;;; The editor wraps a function by capturing it under a second name and then
;;; shadowing the first name. A whole-file reload evaluates the capturing
;;; form again, and the first name then holds the wrapper: a second capture
;;; makes the wrapper call itself, and the next call recurses until the heap
;;; bound stops it. On 2026-09-10 define-command--raw took that path, and
;;; the daemon could define no command again. alias-once! keeps the first
;;; capture, so a reload leaves the wrapper wrapping.

(define (t--alias-target) 'wrapped)

(deftest 'alias-once-keeps-the-first-capture
  "a second capture does not point the wrapper at itself"
  (lambda ()
    (alias-once! 't--alias-raw 't--alias-target)
    ;; the wrapper takes the name, the way editor.scm wraps a primitive
    (set-symbol-value! 't--alias-target (lambda () (t--alias-raw)))
    ;; this is what the reload does to the capturing form
    (alias-once! 't--alias-raw 't--alias-target)
    (check-equal! (t--alias-raw) 'wrapped
      "the capture still names the wrapped function")
    (unbind-global! 't--alias-raw)
    (alias-once! 't--alias-raw 't--alias-target)
    (check-equal! (procedure? t--alias-raw) #t
      "a free name still takes the capture")
    (unbind-global! 't--alias-raw)))

(deftest 'elixir-owns-the-raw-command-primitive
  "editor.scm captures no primitive, so no reload can point one at itself"
  (lambda ()
    ;; Compos.Core.SchemeRawNames registers this name, so it has a
    ;; primitive doc; a Scheme capture would have none.
    (check-equal! (string? (primitive-doc "define-command--raw")) #t
      "define-command--raw is not an Elixir primitive")
    ;; the raw name skips the Scheme wrapper, so it registers no doc
    (define-command--raw "zz-raw-probe" (lambda () 1))
    (check-equal! (command-doc "zz-raw-probe") ""
      "the raw name went through the Scheme wrapper")
    (undefine-command--raw "zz-raw-probe")
    ;; and the wrapper still wraps: it registers the doc and the catalog
    (define-command "zz-wrapped-probe" "probe" (lambda () 42))
    (check-equal! (command-doc "zz-wrapped-probe") "probe"
      "the wrapper lost its doc")
    (check-equal! (command-call "zz-wrapped-probe") 42
      "the command registry does not answer")
    (undefine-command "zz-wrapped-probe")))
