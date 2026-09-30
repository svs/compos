;;; dismiss.scm --- child-first dismissal and reading surfaces.

(domain! 'windows)
(effects! '(read))

(define (buffer-parent buf)
  (let ((parent (buffer-local buf 'dismiss-parent)))
    (and parent (buffer-known? parent)
         (member buf (or (buffer-local parent 'dismiss-children) '()))
         parent)))

(define (buffer-children buf)
  (filter (lambda (child)
            (and (buffer-known? child) (equal? (buffer-parent child) buf)))
          (or (buffer-local buf 'dismiss-children) '())))

(define (dismiss--descendants buf)
  (fold (lambda (out child)
          (append out (dismiss--descendants child) (list child)))
        '() (buffer-children buf)))

;; Read the normal maps without our q wrapper. The actual fallback command
;; is resolved again with key-binding at dispatch, so remaps remain effective.
(define (dismiss--normal-command buf)
  (let loop ((maps (buffer-keymaps buf)))
    (cond ((null? maps) #f)
          ((equal? (car maps) "dismiss-mode-map") (loop (cdr maps)))
          (else
            (let ((cmd (keymap-lookup (car maps) "q")))
              (if cmd cmd (loop (cdr maps))))))))

;; The table a prompt stands in front of is part of the prompt, not a
;; thing to read: C-x b is the minibuffer's own form. It is read-only and
;; its mode gives it q, which is what a reading surface is made of, so
;; the test above lets it through and the reader gets a Reading bar and a
;; q that means nothing. The prompt takes the whole surface away.
(define (dismiss--prompt-surface? buf)
  (equal? buf *mb-list-buffer*))

(define (dismiss--declared-mode? buf)
  (and (mode-inherited (buffer-local buf 'mode-name) 'dismissible) #t))

(define (buffer-dismissible? buf)
  (and (buffer-known? buf) (buffer-read-only? buf)
       (not (minibuffer-buffer? buf))
       (not (dismiss--prompt-surface? buf))
       (let ((cmd (dismiss--normal-command buf)))
         (or (dismiss--declared-mode? buf)
             (buffer-parent buf) (pair? (buffer-children buf))
             (member cmd '("quit-window" "dired-quit" "collect-quit"
                           "switch-quit" "overview-quit" "notmuch-back"
                           "notmuch-quit" "peek-dismiss"))))
       #t))

(public! 'buffer-parent "(buffer-parent BUF) — BUF's live dismissal parent, or #f")
(public! 'buffer-children "(buffer-children BUF) — BUF's live children, newest first")
(public! 'buffer-dismissible? "(buffer-dismissible? BUF) — whether BUF offers child-first q dismissal")

(effects! '(write display))

(define (buffer-child! parent child)
  (unless (and (buffer-known? parent) (buffer-known? child))
    (error "A buffer relationship needs two known buffers"))
  (when (or (equal? parent child) (member parent (dismiss--descendants child)))
    (error "A buffer cannot be its own descendant"))
  (let ((old (buffer-parent child)))
    (when old
      (buffer-set-local! old 'dismiss-children
        (remove (lambda (b) (equal? b child)) (buffer-children old)))))
  (buffer-set-local! child 'dismiss-parent parent)
  (buffer-set-local! parent 'dismiss-children
    (cons child (remove (lambda (b) (equal? b child)) (buffer-children parent))))
  (dismiss--sync! parent)
  (dismiss--sync! child)
  child)

;; The other half of buffer-child!: CHILD is its own from here, so the
;; parent's q leaves it alone. A detail that was kept says this
;; (packages/detail.scm).
(define (buffer-unchild! child)
  (let ((parent (buffer-parent child)))
    (when parent
      (buffer-set-local! parent 'dismiss-children
        (remove (lambda (b) (equal? b child)) (buffer-children parent)))
      (dismiss--sync! parent))
    (buffer-set-local! child 'dismiss-parent #f)
    (dismiss--sync! child)
    child))

;; A reading surface hides its text cursor, but a mode that navigates by
;; point has to show where point stands: in browse-mode RET follows the
;; link at point, and n, p and TAB walk the links. Those modes get caret
;; browsing when they become dismissible, once per mode, so a later
;; M-x caret-browsing-mode is still the reader's answer.
(define *dismiss-caret-modes* '("browse-mode"))

(define (dismiss-keep-caret! mode)
  (unless (member mode *dismiss-caret-modes*)
    (set! *dismiss-caret-modes* (cons mode *dismiss-caret-modes*))))

(define (dismiss--caret-default! buf)
  (let ((mode (buffer-local buf 'mode-name)))
    (unless (equal? (buffer-local buf 'dismiss-caret-default) mode)
      (desktop-skip! buf 'dismiss-caret-default)
      (buffer-set-local! buf 'dismiss-caret-default mode)
      (when (and (member mode *dismiss-caret-modes*)
                 (not (minor-mode-on? buf "caret-browsing-mode")))
        (enable-minor-mode! buf "caret-browsing-mode")))))

(define (dismiss--sync! buf)
  (when (buffer-exists? buf)
    (let ((on (buffer-dismissible? buf)))
      (desktop-skip! buf 'dismissible)
      (unless (equal? (buffer-local buf 'dismissible) on)
        (buffer-set-local! buf 'dismissible on))
      (when on (dismiss--caret-default! buf))
      (cond ((and on (not (minor-mode-on? buf "dismiss-mode")))
             (enable-minor-mode! buf "dismiss-mode"))
            ((and (not on)
                  (or (minor-mode-on? buf "dismiss-mode")
                      (member "dismiss-mode-map" (buffer-minor-maps buf))))
             (disable-minor-mode! buf "dismiss-mode"))))))

(define (dismiss-sync-visible!)
  (for-each (lambda (row) (dismiss--sync! (cadr row))) (window-list)))

(register-minor-mode! "dismiss-mode" (lambda (buf) #t) (lambda (buf) #t))
(minor-mode-keys! "dismiss-mode" '(("q" "dismiss-buffer")))

(register-minor-mode! "caret-browsing-mode" (lambda (buf) #t) (lambda (buf) #t))
(define-command "caret-browsing-mode" "Toggle the text cursor while reading a dismissible buffer"
  (lambda () (toggle-minor-mode! "caret-browsing-mode")))

;; Only descendants owned by this buffer participate. Prefer a visible
;; descendant in this frame, deepest first, before touching hidden children.
(define (dismiss--child-target buf)
  (let* ((shown (map cadr (window-list)))
         (all-shown (map cadr (window-list-all)))
         (children (filter (lambda (child)
                             (and (buffer-dismissible? child)
                                  (or (member child shown) (not (member child all-shown)))))
                           (dismiss--descendants buf))))
    (or (let loop ((rest children))
          (cond ((null? rest) #f)
                ((member (car rest) shown) (car rest))
                (else (loop (cdr rest)))))
        (and (pair? children) (car children)))))

;; Ownership chooses the child. Each destination's history chooses what
;; replaces it. Transient lists and buffers visible elsewhere remain valid.
(define (dismiss--close-child! child)
  (let ((focus (active-window))
        (parent (buffer-parent child)))
    (if (and (equal? (window-buffer (active-window)) child)
             (= (length (window-list)) 1)
             (null? (window-eligible-history (active-window))))
        (begin (message "No previous buffer; this is the last window") #f)
    (if (and (buffer-path child) (buffer-modified? child))
        (begin (message "Buffer is modified — save it before dismissing") #f)
        (begin
          (for-each
            (lambda (row)
              (when (equal? (cadr row) child)
                (let* ((win (car row)) (rec (window-restore win))
                       (past (window-eligible-history win)))
                  (cond
                    ((equal? win (float-window)) (float-close!))
                    ((and rec (equal? (car rec) 'window) (> (length (window-list)) 1))
                     (delete-window-id! win))
                    ((pair? past)
                      (window-set-buffer! win (car past))
                      (set-window-prev-buffers! win (cdr past)))
                    ((> (length (window-list)) 1) (delete-window-id! win))
                    (else (message "No previous buffer; this is the last window")))
                  (set-window-restore! win #f))))
            (window-list))
          ;; A child displayed in another frame remains that frame's view.
          (unless (let loop ((rows (window-list-all)))
                    (and (pair? rows)
                         (or (equal? (cadr (car rows)) child) (loop (cdr rows)))))
            ;; Visible-first may close a child before its hidden descendants.
            ;; Keep those descendants reachable for the parent's next q.
            (when parent
              (for-each (lambda (grandchild) (buffer-child! parent grandchild))
                        (reverse (buffer-children child))))
            (buffer-kill! child))
          (when (window-exists? focus) (select-window! focus))
          (dismiss-sync-visible!)
          #t)))))

(define-command "dismiss-buffer" "Dismiss a child first, otherwise run this buffer's normal q action"
  (lambda ()
    (let* ((buf (current-buffer)) (child (dismiss--child-target buf)))
      (cond ((equal? (listing-preview-owner) buf) (listing-peek-dismiss!))
            (child (dismiss--close-child! child))
            ((and (buffer-parent buf) (buffer-dismissible? buf)) (dismiss--close-child! buf))
            (else
              ;; Resolve without our map, then put it back before calling.
              ;; The original command may kill BUF or replace its mode.
              (let ((maps (buffer-minor-maps buf)))
                (buffer-minor-maps! buf (remove (lambda (m) (equal? m "dismiss-mode-map")) maps))
                (let ((cmd (key-binding "q")))
                  (buffer-minor-maps! buf maps)
                  (when (and (string? cmd) (not (equal? cmd "dismiss-buffer")))
                    (run-command cmd)))))))))

;; Reciprocal links prevent a reused buffer name from inheriting ownership.
;; Clean both sides on kill and rewrite both sides on rename.
(define (dismiss--before-kill! buf)
  (let ((parent (buffer-parent buf)))
    (when parent
      (buffer-set-local! parent 'dismiss-children
        (remove (lambda (b) (equal? b buf)) (buffer-children parent)))))
  (for-each (lambda (child) (buffer-set-local! child 'dismiss-parent #f))
            (buffer-children buf)))

(define (dismiss--renamed! old new)
  (for-each
    (lambda (buf)
      (when (equal? (buffer-local buf 'dismiss-parent) old)
        (buffer-set-local! buf 'dismiss-parent new))
      (let ((children (buffer-local buf 'dismiss-children)))
        (when (and children (member old children))
          (buffer-set-local! buf 'dismiss-children
            (map (lambda (b) (if (equal? b old) new b)) children)))))
    (buffer-list)))

(define (dismiss--after-mode! &rest args) (dismiss-sync-visible!))
(advice-add! 'buffer-kill! 'before 'dismiss-unlink 'dismiss--before-kill!)
(advice-add! 'set-mode! 'after 'dismiss-presentation 'dismiss--after-mode!)
(advice-add! 'buffer-set-read-only! 'after 'dismiss-presentation 'dismiss--after-mode!)
;; A prompt is not a reading surface, so the flag that makes one never
;; lands there. A mode setup that runs while a prompt is up takes the
;; prompt for the current buffer, and list-mode, collect-mode and peek
;; all end in a read-only flag: that is how q and the Reading bar reached
;; a minibuffer. The mode is the whole test.
(advice-add! 'buffer-set-read-only! 'around 'minibuffer-never-read-only
  (lambda (next &rest args)
    (if (and (pair? args) (pair? (cdr args)) (cadr args)
             (minibuffer-buffer? (car args)))
        #f
        (apply next args))))
(add-hook! 'buffer-renamed-hook 'dismiss--renamed!)
;; Every cause of a change already says so: a window shows a different
;; buffer, a mode is set, a read-only flag is flipped, a child is claimed
;; or released, a buffer is renamed or dismissed. A keystroke is not one
;; of them, so this does not run per command: asking every visible buffer
;; whether it is dismissible cost 19ms of every key, and the answer never
;; changed.
(add-hook! 'window-configuration-change-hook 'dismiss-sync-visible!)

(public! 'dismiss-keep-caret! "(dismiss-keep-caret! MODE) — MODE's dismissible buffers show the text cursor, because they navigate by point")
(public! 'buffer-child! "(buffer-child! PARENT CHILD) — register a child for child-first dismissal; reject ownership cycles")
(public! 'buffer-unchild! "(buffer-unchild! CHILD) — release CHILD from its parent, so the parent's q leaves it alone")
(public! 'dismiss-sync-visible! "(dismiss-sync-visible!) — rebuild dismissal cues and maps for visible buffers")

(dismiss-sync-visible!)
