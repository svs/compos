;;; workspace-mode.scm --- a minor mode that borrows buffer locals.
;;;
;;; code-mode, code-agent-mode and writing-mode each change a set of
;;; locals on the buffer they enter, and each owes that buffer the same
;;; four things: remember what it found, the first time only; give it
;;; back on exit; push the model and presets it set to the buffer's open
;;; scratch; and run its setup again on a desktop restore without
;;; remembering its own values a second time. define-workspace-mode!
;;; owns those four. A mode declares the locals it sets and the setup
;;; that sets them.
;;;
;;;   (define-workspace-mode! "code-mode"
;;;     'locals '(group chat-presets llm-model modeline-info)
;;;     'modes '("llm-mode")
;;;     'scratch #t
;;;     'setup code-mode--setup!)
;;;
;;; Options, each one optional:
;;;
;;;   'saved KEY        the local that holds the saved alist; NAME-saved
;;;                     when not given
;;;   'locals (L ...)   L is KEY or (KEY DEFAULT). Each is read with
;;;                     buffer-local, saved once, and set back on exit. An
;;;                     absent local reads as DEFAULT, #f when none is given
;;;   'modes (M ...)    minor modes whose state is saved under the symbol
;;;                     of M. Exit turns off one that was off; one that was
;;;                     on is left as the user has it
;;;   'remember (R ...) R is KEY or (KEY READER): saved for the hooks and
;;;                     never set back. KEY alone reads with buffer-local;
;;;                     (READER BUF) answers the value
;;;   'accepts? PROC    (PROC BUF) is #f for a buffer the mode refuses. A
;;;                     refused buffer gets back what a past enable took
;;;                     and loses the mode from its minor-modes, so a stale
;;;                     desktop entry heals on the next restore
;;;   'setup PROC       (PROC BUF ENTERING?) sets the locals. ENTERING? is
;;;                     #t on the first enable and #f on every re-run
;;;   'teardown PROC    (PROC BUF SAVED) runs before the locals go back
;;;   'after PROC       (PROC BUF SAVED) runs after they are back
;;;   'scratch #t       the buffer's open scratch takes its model and
;;;                     presets after setup and after exit
;;;
;;; SAVED in the hooks is a procedure: (SAVED KEY) is what the mode found
;;; under KEY. The saved alist itself is in the buffer local named by
;;; 'saved while the mode is on, and #f once it is off.

(domain! 'buffers)
(effects! '(write))

(define (workspace-mode--opt opts key default)
  (let loop ((o opts))
    (cond ((or (null? o) (null? (cdr o))) default)
          ((equal? (car o) key) (cadr o))
          (else (loop (cddr o))))))

;; a locals or remember entry: KEY, (KEY DEFAULT) or (KEY READER)
(define (workspace-mode--key entry)
  (if (pair? entry) (car entry) entry))

(define (workspace-mode--default entry)
  (if (and (pair? entry) (not (procedure? (cadr entry))))
      (cadr entry)
      #f))

(define (workspace-mode--read buf entry)
  (cond ((not (pair? entry)) (or (buffer-local buf entry) #f))
        ((procedure? (cadr entry)) ((cadr entry) buf))
        (else (or (buffer-local buf (car entry)) (cadr entry)))))

(define (workspace-mode--snapshot spec buf)
  (append
    (map (lambda (e) (list (workspace-mode--key e) (workspace-mode--read buf e)))
         (plist-get spec 'locals))
    (map (lambda (m) (list (string->symbol m) (minor-mode-on? buf m)))
         (plist-get spec 'modes))
    (map (lambda (e) (list (workspace-mode--key e) (workspace-mode--read buf e)))
         (plist-get spec 'remember))))

(define (workspace-mode--lookup alist)
  (lambda (key)
    (let ((hit (assoc key alist)))
      (and hit (cadr hit)))))

(define (workspace-mode--spec name)
  (or (mode-get name 'workspace)
      (error (string-append name " is not a workspace mode"))))

(define (workspace-mode-saved name buf key)
  (let ((spec (workspace-mode--spec name)))
    ((workspace-mode--lookup (or (buffer-local buf (plist-get spec 'saved)) '()))
     key)))

(define (workspace-mode--scratch! spec buf)
  (when (and (plist-get spec 'scratch) (boundp 'scratch-refresh-llm!))
    (scratch-refresh-llm! buf)))

(define (workspace-mode--restore! name buf)
  (let* ((spec (workspace-mode--spec name))
         (key (plist-get spec 'saved))
         (alist (or (buffer-local buf key) '()))
         (saved (workspace-mode--lookup alist)))
    ((plist-get spec 'teardown) buf saved)
    (for-each
      (lambda (e)
        (let ((k (workspace-mode--key e)))
          (buffer-set-local! buf k
            (if (assoc k alist) (saved k) (workspace-mode--default e)))))
      (plist-get spec 'locals))
    (for-each
      (lambda (m)
        (unless (saved (string->symbol m))
          (when (minor-mode-on? buf m) (disable-minor-mode! buf m))))
      (plist-get spec 'modes))
    (buffer-set-local! buf key #f)
    ((plist-get spec 'after) buf saved)
    (workspace-mode--scratch! spec buf)))

(define (workspace-mode--refuse! name buf)
  (let ((spec (workspace-mode--spec name)))
    (when (buffer-local buf (plist-get spec 'saved))
      (workspace-mode--restore! name buf))
    (buffer-set-local! buf 'minor-modes
      (remove (lambda (n) (equal? n name))
              (or (buffer-local buf 'minor-modes) '())))))

;; The one funnel for enable, refresh and desktop restore. The snapshot is
;; taken once: a re-run finds it in place and must not save the mode's own
;; values over the user's.
(define (workspace-mode-apply! name buf)
  (let ((spec (workspace-mode--spec name)))
    (if (not ((plist-get spec 'accepts?) buf))
        (workspace-mode--refuse! name buf)
        (let* ((key (plist-get spec 'saved))
               (entering? (not (buffer-local buf key))))
          (when entering?
            (buffer-set-local! buf key (workspace-mode--snapshot spec buf)))
          ((plist-get spec 'setup) buf entering?)
          (workspace-mode--scratch! spec buf)))))

(define (define-workspace-mode! name &rest opts)
  (let ((spec
          (list 'saved (workspace-mode--opt opts 'saved
                         (string->symbol (string-append name "-saved")))
                'locals (workspace-mode--opt opts 'locals '())
                'modes (workspace-mode--opt opts 'modes '())
                'remember (workspace-mode--opt opts 'remember '())
                'accepts? (workspace-mode--opt opts 'accepts? (lambda (buf) #t))
                'setup (workspace-mode--opt opts 'setup (lambda (buf entering?) #t))
                'teardown (workspace-mode--opt opts 'teardown (lambda (buf saved) #t))
                'after (workspace-mode--opt opts 'after (lambda (buf saved) #t))
                'scratch (workspace-mode--opt opts 'scratch #f))))
    (register-minor-mode! name
      (lambda (buf) (workspace-mode-apply! name buf))
      (lambda (buf) (workspace-mode--restore! name buf)))
    (mode-put! name 'workspace spec)
    name))

(category! 'buffers)
(public! 'define-workspace-mode!
  "(define-workspace-mode! NAME OPTS...) - register a minor mode that saves the locals it declares, gives them back on exit, pushes its presets to the scratch, and re-runs its setup on restore without saving twice")
(public! 'workspace-mode-apply!
  "(workspace-mode-apply! NAME BUF) - run workspace mode NAME's setup on BUF again, keeping what the first enable saved")
(public! 'workspace-mode-saved
  "(workspace-mode-saved NAME BUF KEY) - what workspace mode NAME found in BUF under KEY before it changed it, or #f")
