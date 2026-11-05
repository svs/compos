;;; transient.scm --- temporary command menus, after Emacs Transient.
;;;
;;; A transient keeps the source buffer selected. The command palette shows
;;; its menu, and a frame-local Scheme keymap owns input until exit.

(package! 'transient 'transient)
(domain! 'interaction)
(effects! '(write))

(define *transient-prefixes* '())
(define *transient-defaults* '())
(define *transient-history* '())
(define transient-default-level 4)
(define transient-history-limit 20)

(define (transient--alist-get al key fallback)
  (let ((e (assoc key al))) (if e (cadr e) fallback)))

(define (transient-prefix name) (assoc name *transient-prefixes*))

(define (transient--prefix-option prefix key)
  (plist-get (car (cdr (cdr (cdr prefix)))) key))

(define (transient--run-hook prefix key state)
  (let ((fn (and prefix (transient--prefix-option prefix key))))
    (when fn (fn (plist-get state 'scope)))))

(define (transient-suffix key description command &rest properties)
  (append (list 'kind 'suffix 'key key 'description description 'command command)
          properties))

(define (transient-infix key description command value-fn &rest properties)
  (append (list 'kind 'infix 'key key 'description description
                'command command 'value-fn value-fn 'transient 'stay)
          properties))

(define (transient-switch key description argument &rest properties)
  (append (list 'kind 'switch 'key key 'description description
                'argument argument 'transient 'stay)
          properties))

(define (transient-choice key description argument choices &rest properties)
  (append (list 'kind 'choice 'key key 'description description
                'argument argument 'choices choices 'transient 'stay)
          properties))

;; A row with no key is named by its description: rows share one prefix,
;; and two keyless rows under one name would run the same command.
(define (transient--item-wrapper prefix item)
  (let ((key (plist-get item 'key)))
    (if (equal? key "")
        (string-append "transient--" prefix ":row:" (plist-get item 'description))
        (string-append "transient--" prefix ":" key))))

(define (transient--install-item prefix item)
  (let ((name (transient--item-wrapper prefix item))
        (kind (plist-get item 'kind)))
    (define-command--raw name
      (lambda ()
        (if (or (equal? kind 'switch) (equal? kind 'choice))
            (transient--invoke-value prefix item)
            (transient--invoke-command prefix item))))
    (plist-put item 'wrapper name)))

(define (transient--prefix-put prefix)
  (set! *transient-prefixes*
    (cons prefix
      (filter (lambda (e) (not (equal? (car e) (car prefix))))
              *transient-prefixes*))))

(define (transient-define-prefix name doc groups &rest options)
  (transient--prefix-put (list name doc groups options))
  (define-command name doc
    (lambda () (transient-setup name (current-buffer))))
  name)

(define (transient--active) (frame-local 'transient-active))
(define (transient--set-active! state) (set-frame-local! 'transient-active state))

(define (transient-scope)
  (let ((state (transient--active))) (and state (plist-get state 'scope))))

(define (transient-value argument)
  (let ((state (transient--active)))
    (and state
         (transient--alist-get (plist-get state 'values) argument #f))))

(define (transient--set-value! argument value)
  (let* ((state (transient--active))
         (values (alist-put (plist-get state 'values) argument value)))
    (transient--set-active! (plist-put state 'values values))))

(define (transient--raw-groups prefix state)
  (let ((groups (caddr prefix)))
    (if (procedure? groups) (groups (plist-get state 'scope)) groups)))

(define (transient--groups prefix state)
  (map (lambda (group)
         (cons (car group)
           (map (lambda (item) (transient--install-item (car prefix) item))
                (cdr group))))
       (transient--raw-groups prefix state)))

(define (transient--item-visible? item state)
  (let ((level (or (plist-get item 'level) 4))
        (pred (plist-get item 'if)))
    (and (<= level (or (plist-get state 'level) transient-default-level))
         (or (not pred) (pred (plist-get state 'scope))))))

(define (transient--visible-groups prefix state)
  (map (lambda (group)
         (cons (car group)
           (filter (lambda (item) (transient--item-visible? item state))
                   (cdr group))))
       (transient--groups prefix state)))

(define (transient--visible-items groups)
  (let loop ((gs groups) (out '()))
    (if (null? gs)
        (reverse out)
        (loop (cdr gs) (append (reverse (cdr (car gs))) out)))))

(define (transient--item-default item)
  (let ((kind (plist-get item 'kind)))
    (cond ((equal? kind 'switch) (or (plist-get item 'default) #f))
          ((equal? kind 'choice)
           (or (plist-get item 'default)
               (let ((choices (plist-get item 'choices)))
                 (and (pair? choices)
                      (if (pair? (car choices)) (car (car choices)) (car choices))))))
          (else #f))))

(define (transient--initial-values prefix groups)
  (let ((saved (assoc (car prefix) *transient-defaults*)))
    (if saved
        (cadr saved)
        (let loop ((items (transient--visible-items groups)) (values '()))
          (if (null? items)
              values
              (let* ((item (car items))
                     (argument (plist-get item 'argument)))
                (loop (cdr items)
                  (if argument
                      (alist-put values argument
                        (transient--item-default item))
                      values))))))))

;; The menu's keys are one keymap, transient-map, in force as the frame's
;; overriding map and locked: the ladder answers the menu's keys and
;; nothing else, and an unbound key says so. Emacs's Transient does the
;; same through overriding-terminal-local-map.
(define-keymap! "transient-map")

(define (transient-keymap-install! bindings)
  (for-each (lambda (row) (keymap-unset! "transient-map" (car row)))
            (keymap-bindings "transient-map"))
  (for-each (lambda (row) (define-key "transient-map" (car row) (cadr row))) bindings)
  (set-frame-local! 'transient-keymap bindings)
  (overriding-map! "transient-map" #t))

(define (transient-keymap-clear!)
  (set-frame-local! 'transient-keymap #f)
  (overriding-map! #f))

(define (transient--close-menu!)
  (transient-keymap-clear!)
  (transient-show! #f))

(define (transient--choice-pair choice)
  (if (pair? choice) choice (list choice choice)))

(define (transient--choice-next choices value)
  (if (null? choices)
      #f
      (let loop ((rest choices))
        (cond ((null? rest) (car (transient--choice-pair (car choices))))
              ((equal? (car (transient--choice-pair (car rest))) value)
               (if (pair? (cdr rest))
                   (car (transient--choice-pair (cadr rest)))
                   (car (transient--choice-pair (car choices)))))
              (else (loop (cdr rest)))))))

;; An infix always carries a value-fn. A suffix may carry one too: a row
;; that opens a view still says what the view holds.
(define (transient--item-value item)
  (let ((kind (plist-get item 'kind))
        (fn (plist-get item 'value-fn)))
    (cond ((equal? kind 'switch)
           (if (transient-value (plist-get item 'argument)) "on" "off"))
          ((equal? kind 'choice)
           (let* ((value (transient-value (plist-get item 'argument)))
                  (choice (assoc value (map transient--choice-pair
                                            (plist-get item 'choices)))))
             (if choice (cadr choice) (value->string value))))
          (fn
           (let ((value (fn (transient-scope))))
             (if (string? value) value (value->string value))))
          (else ""))))

;; The rows' keys, then EXTRA (a prefix's 'keys-fn, which wins over a row
;; with the same key), then the menu's own keys. A row with the key ""
;; takes no key: RET on it is the only way to invoke it.
(define (transient--bindings groups &optional extra)
  (append
    (map (lambda (item) (list (plist-get item 'key) (plist-get item 'wrapper)))
         (filter (lambda (item) (not (equal? (plist-get item 'key) "")))
                 (transient--visible-items groups)))
    (or extra '())
    (list (list "C-g" "transient-quit-one")
          (list "C-q" "transient-quit-all")
          (list "ESC" "transient-quit-one")
          (list "C-z" "transient-suspend")
          (list "?" "transient-toggle-help")
          (list "C-h" "transient-toggle-help")
          (list "<up>" "transient-previous")
          (list "<down>" "transient-next")
          (list "C-p" "transient-previous")
          (list "C-n" "transient-next")
          (list "<left>" "transient-column-left")
          (list "<right>" "transient-column-right")
          (list "RET" "transient-invoke-selected")
          (list "M-RET" "transient-invoke-selected")
          (list "C-M-p" "transient-history-prev")
          (list "C-M-n" "transient-history-next")
          (list "C-x s" "transient-set")
          (list "C-x C-s" "transient-save")
          (list "C-x C-k" "transient-reset"))))

;; what SEQUENCE means in the menu, read off the keymap
(define (transient-dispatch-key sequence)
  (let ((hit (keymap-lookup "transient-map" sequence)))
    (cond ((string? hit) (list "command" hit))
          ((equal? hit 'prefix) (list "prefix"))
          (else (list "none")))))

;;; A row can say it holds the setting in force — the bundle the session
;;; is on, the mode it is in. That is not the cursor: the cursor moves
;;; with the keys and this stays put, so the frame reads them as two
;;; marks and colours them apart. A row carries 'active as a flag, or
;;; 'active-fn to answer it per scope the way 'value-fn does.
(define (transient--item-active? item state)
  (let ((fn (plist-get item 'active-fn)))
    (if fn
        (and (fn (plist-get state 'scope)) #t)
        (and (plist-get item 'active) #t))))

;;; a row's display flags as one class list: what invoking it does to
;;; the menu, then active when it is the one in force
(define (transient--item-flags item state)
  (let* ((behavior (value->string (or (plist-get item 'transient) 'exit)))
         (flags (if (transient--item-active? item state)
                    (string-append behavior " active")
                    behavior))
         (fn (plist-get item 'flags-fn))
         (extra (and fn (fn (plist-get state 'scope)))))
    (if (and (string? extra) (not (equal? extra "")))
        (string-append flags " " extra)
        flags)))

;;; A row with 'cursor 'skip takes its key and never the cursor: the arrows
;;; skip it, and the menu never opens on it. A menu whose rows are
;;; sources for a key, and not places to stand, uses this. (A #f value
;;; would not do: plist-put drops it when the menu installs the row.)
(define (transient--item-selectable? item)
  (not (equal? (plist-get item 'cursor) 'skip)))

;; the first selectable index from INDEX, stepping by DELTA with wrap;
;; INDEX itself when no row is selectable
(define (transient--selectable-index items index delta)
  (let ((count (length items)))
    (let loop ((i index) (n 0))
      (cond ((or (= count 0) (>= n count)) index)
            ((transient--item-selectable? (nth (modulo i count) items))
             (modulo i count))
            (else (loop (+ i delta) (+ n 1)))))))

(define (transient--menu-groups groups state)
  (let ((selected (or (plist-get state 'selected) 0))
        (index 0)
        (help? (plist-get state 'help)))
    (map
      (lambda (group)
        (list (car group)
          (map
            (lambda (item)
              (let ((selected? (= index selected)))
                (set! index (+ index 1))
                (list (plist-get item 'key)
                      (if help?
                          (let ((command (plist-get item 'command)))
                            (if (string? command) (command-doc command)
                                (plist-get item 'description)))
                          (plist-get item 'description))
                      (transient--item-value item)
                      (plist-get item 'kind)
                      (transient--item-flags item state)
                      selected?)))
            (cdr group))))
      groups)))

(define (transient--option-text prefix key scope)
  (let ((fn (transient--prefix-option prefix key)))
    (cond ((procedure? fn) (let ((v (fn scope))) (if (string? v) v "")))
          ((string? fn) fn)
          (else ""))))

(define (transient--option-list prefix key scope)
  (let ((fn (transient--prefix-option prefix key)))
    (cond ((procedure? fn) (or (fn scope) '()))
          ((pair? fn) fn)
          (else '()))))

;; The footer of a menu that names no legend of its own.
(define transient-default-legend
  '(("RET" "invoke") ("C-g" "quit") ("↑↓" "select") ("?" "help")))

;; The parts of the menu beyond its rows, each from a prefix option:
;;   'subtitle-fn (SCOPE) -> text      under the title: the state in one line
;;   'context-fn  (SCOPE) -> text      right of the title: what the menu acts on
;;   'chips-fn    (SCOPE) -> ((LABEL ACTIVE?) ...)
;;   'detail-fn   (SCOPE ITEM) -> (TITLE ((KEY VALUE TONE) ...) NOTE) or #f
;;                                     the facts rail; ITEM is the selected row
;;   'legend-fn   (SCOPE) -> ((KEY LABEL) ...)   the footer, or 'legend a list
;; TONE is "" or "drift" (the value differs from what the rail compares to)
;; or "dim". A prefix with none of these renders as before.
(define (transient--menu-meta prefix state items)
  (let* ((scope (plist-get state 'scope))
         (index (or (plist-get state 'selected) 0))
         (item (and (< index (length items)) (nth index items)))
         (detail-fn (transient--prefix-option prefix 'detail-fn))
         (detail (and (procedure? detail-fn) (detail-fn scope item))))
    (list (list "subtitle" (transient--option-text prefix 'subtitle-fn scope))
          ;; 'layout NAME: the frame draws the menu with that layout's class
          (list "layout" (transient--option-text prefix 'layout scope))
          (list "context" (transient--option-text prefix 'context-fn scope))
          (list "chips" (transient--option-list prefix 'chips-fn scope))
          (list "detail" (or detail #f))
          (list "legend"
                (let* ((rows (transient--option-list prefix 'legend-fn scope))
                       (rows (if (null? rows) (transient--option-list prefix 'legend scope) rows)))
                  (if (null? rows) transient-default-legend rows))))))

;;; --- columns ----------------------------------------------------------------
;;; The frame draws the groups in columns, and the keyboard moves between
;;; them, so Scheme decides the columns. The prefix option 'columns names
;;; the groups that share one: (("Bundles" "Setup") ("Recent")). Every
;;; visible group it does not name stands in a column of its own, in menu
;;; order. Left and right move to the same row of the next column.

(define (transient--column-of title declared)
  (let loop ((cs declared))
    (cond ((null? cs) #f)
          ((member title (car cs)) (car cs))
          (else (loop (cdr cs))))))

;; ((TITLE ...) ...) for the visible GROUPS: declared columns keep only
;; their visible members and sit where their first member sits
(define (transient--columns prefix state groups)
  (let* ((declared (transient--option-list prefix 'columns (plist-get state 'scope)))
         (titles (map car groups)))
    (let loop ((ts titles) (out '()))
      (if (null? ts)
          (reverse out)
          (let* ((declared-col (transient--column-of (car ts) declared))
                 (col (if declared-col
                          (filter (lambda (t) (member t titles)) declared-col)
                          (list (car ts)))))
            (loop (cdr ts) (if (member col out) out (cons col out))))))))

;; the global item indexes one column holds, top to bottom
(define (transient--column-indexes groups column)
  (let loop ((gs groups) (index 0) (out '()))
    (if (null? gs)
        (reverse out)
        (let* ((n (length (cdr (car gs))))
               (mine? (member (car (car gs)) column)))
          (loop (cdr gs) (+ index n)
                ;; OUT is built newest-first and reversed at the end, so
                ;; the indexes go on ascending
                (if mine?
                    (let add ((i index) (acc out))
                      (if (>= i (+ index n)) acc (add (+ i 1) (cons i acc))))
                    out))))))

(define (transient--position x lst)
  (let loop ((l lst) (i 0))
    (cond ((null? l) 0)
          ((equal? (car l) x) i)
          (else (loop (cdr l) (+ i 1))))))

;; the index DELTA columns away from SELECTED, on the same row or the
;; last row that column has; the edge columns do not wrap
(define (transient--column-target groups columns selected delta)
  (let ((cols (filter pair? (map (lambda (c) (transient--column-indexes groups c))
                                 columns))))
    (let find ((cs cols) (ci 0))
      (cond ((null? cs) selected)
            ((member selected (car cs))
             (let* ((offset (transient--position selected (car cs)))
                    (target-ci (max 0 (min (- (length cols) 1) (+ ci delta))))
                    (target (nth target-ci cols)))
               (nth (min offset (- (length target) 1)) target)))
            (else (find (cdr cs) (+ ci 1)))))))

(define (transient--column-move delta)
  (let* ((state (transient--active))
         (prefix (and state (transient-prefix (plist-get state 'prefix)))))
    (when prefix
      (let* ((groups (transient--visible-groups prefix state))
             (columns (transient--columns prefix state groups))
             (target (transient--column-target
                       groups columns (or (plist-get state 'selected) 0) delta))
             (target (transient--selectable-index
                       (transient--visible-items groups) target 1)))
        (transient--select! state target)
        (transient--render!)))))

(define-command "transient-column-left" "Select the same row in the column to the left"
  (lambda () (transient--column-move -1)))
(define-command "transient-column-right" "Select the same row in the column to the right"
  (lambda () (transient--column-move 1)))

(define (transient--render!)
  (let* ((state (transient--active))
         (prefix (and state (transient-prefix (plist-get state 'prefix)))))
    (when prefix
      (let* ((groups (transient--visible-groups prefix state))
             (items (transient--visible-items groups))
             (selected (min (or (plist-get state 'selected) 0)
                            (max 0 (- (length items) 1))))
             (state (plist-put state 'selected selected)))
        (transient--set-active! state)
        ;; 'keys-fn (SCOPE) -> ((KEY COMMAND) ...): keys the menu answers
        ;; that are no row; the legend is where they are named
        (transient-keymap-install!
          (transient--bindings groups
            (transient--option-list prefix 'keys-fn (plist-get state 'scope))))
        (transient-show!
          (list (cadr prefix) (transient--menu-groups groups state)
                (cons (list "columns" (transient--columns prefix state groups))
                      (transient--menu-meta prefix state items))))))))

;;; the row a menu opens on: the one holding the setting in force, else
;;; the first. Opening on the live choice means the menu answers "what
;;; am I on?" before a key is pressed.
(define (transient--initial-selection prefix state)
  (let ((all (transient--visible-items (transient--visible-groups prefix state))))
    (let loop ((items all) (i 0))
      (cond ((null? items) (transient--selectable-index all 0 1))
            ((and (transient--item-active? (car items) state)
                  (transient--item-selectable? (car items)))
             i)
            (else (loop (cdr items) (+ i 1)))))))

(define (transient-setup name &optional scope)
  (let ((prefix (transient-prefix name)))
    (if (not prefix)
        (message (string-append "No such transient: " name))
        (let* ((parent (transient--active))
               (seed (list 'prefix name 'scope (or scope (current-buffer))
                           'values '() 'stack (if parent (cons parent (plist-get parent 'stack)) '())
                           'selected 0 'history-index -1 'level transient-default-level
                           'help #f))
               (groups (transient--visible-groups prefix seed))
               (state (plist-put seed 'values
                        (transient--initial-values prefix groups))))
          (transient--set-active! state)
          (transient--run-hook prefix 'on-setup state)
          ;; the setup hook decides what is in force, so the opening row
          ;; is read after it, not from the seed
          (let ((settled (transient--active)))
            (transient--select! settled
              (transient--initial-selection prefix settled)))
          (transient--render!)))))

(define (transient--remember! state)
  (let* ((name (plist-get state 'prefix))
         (values (plist-get state 'values))
         (old (transient--alist-get *transient-history* name '()))
         (history (take (cons values (remove (lambda (v) (equal? v values)) old))
                          transient-history-limit)))
    (set! *transient-history* (alist-put *transient-history* name history))))

(define (transient--export! state)
  (set-frame-local! 'transient-current-prefix (plist-get state 'prefix))
  (set-frame-local! 'transient-current-values (plist-get state 'values)))

(define (transient--exit! state)
  (transient--run-hook
    (transient-prefix (plist-get state 'prefix)) 'on-quit state)
  (transient--remember! state)
  (transient--export! state)
  (transient--close-menu!)
  (transient--set-active! #f))

(define (transient--call command)
  (cond ((string? command) (run-command command))
        ((procedure? command) (command))
        (else #f)))

(define (transient--invoke-command prefix item)
  (let ((state (transient--active)))
    (when (and state (equal? prefix (plist-get state 'prefix)))
      (let ((command (plist-get item 'command)))
        (cond
          ((and (string? command) (transient-prefix command))
           (transient-setup command (plist-get state 'scope)))
          ((equal? (plist-get item 'transient) 'stay)
           (transient--export! state)
           (transient--call command)
           (when (transient--active) (transient--render!)))
          (else
           (transient--exit! state)
           (transient--call command)))))))

(define (transient--invoke-value prefix item)
  (let ((state (transient--active)))
    (when (and state (equal? prefix (plist-get state 'prefix)))
      (let* ((kind (plist-get item 'kind))
             (argument (plist-get item 'argument))
             (old (transient-value argument))
             (value (if (equal? kind 'switch)
                        (not old)
                        (transient--choice-next (plist-get item 'choices) old))))
        (transient--set-value! argument value)
        (transient--render!)))))

(define (transient-args &optional prefix-name)
  (let* ((state (transient--active))
         (name (or prefix-name
                   (and state (plist-get state 'prefix))
                   (frame-local 'transient-current-prefix)))
         (values (if state (plist-get state 'values)
                     (or (frame-local 'transient-current-values) '())))
         (prefix (transient-prefix name)))
    (if (not prefix) '()
        (let loop ((items (transient--visible-items
                            (transient--groups prefix
                              (or state (list 'scope #f 'values values 'level 7)))))
                   (out '()))
          (if (null? items)
              (reverse out)
              (let* ((item (car items))
                     (kind (plist-get item 'kind))
                     (argument (plist-get item 'argument))
                     (value (and argument (transient--alist-get values argument #f))))
                (cond
                  ((and (equal? kind 'switch) value)
                   (loop (cdr items) (cons argument out)))
                  ((and (equal? kind 'choice) value)
                   (loop (cdr items) (cons (string-append argument (value->string value)) out)))
                  (else (loop (cdr items) out)))))))))

(define-command "transient-quit-one" "Exit this transient and return to its parent"
  (lambda ()
    (let* ((state (transient--active))
           (stack (and state (plist-get state 'stack))))
      (if (and stack (pair? stack))
          (begin
            (transient--run-hook
              (transient-prefix (plist-get state 'prefix)) 'on-quit state)
            (transient--set-active! (car stack))
            (transient--render!))
          (when state
            (transient--run-hook
              (transient-prefix (plist-get state 'prefix)) 'on-quit state)
            (transient--close-menu!)
            (transient--set-active! #f)
            (message "Quit"))))))

;;; C-g and ESC both leave one level. C-g also says "change nothing": an
;;; on-quit hook that applies a draft reads (transient-cancelled?) and
;;; drops the draft instead. A menu with no draft sees no difference.
(define (transient-cancelled?) (and (frame-local 'transient-cancelled) #t))

(define-command "transient-cancel-one" "Exit this transient, and tell it to change nothing"
  (lambda ()
    (set-frame-local! 'transient-cancelled #t)
    (run-command "transient-quit-one")
    (set-frame-local! 'transient-cancelled #f)))

(define-command "transient-quit-all" "Exit this transient and every parent"
  (lambda ()
    (let ((state (transient--active)))
      (when state
        (transient--run-hook
          (transient-prefix (plist-get state 'prefix)) 'on-quit state)
        (transient--close-menu!)
        (transient--set-active! #f)
        (message "Quit")))))

(define-command "transient-suspend" "Suspend this transient for later resumption"
  (lambda ()
    (let ((state (transient--active)))
      (when state
        (set-frame-local! 'transient-suspended state)
        (transient--close-menu!)
        (transient--set-active! #f)
        (message "Transient suspended; use M-x transient-resume")))))

(define-command "transient-resume" "Resume the transient suspended in this frame"
  (lambda ()
    (let ((state (frame-local 'transient-suspended)))
      (if (not state)
          (message "No suspended transient")
          (begin
            (set-frame-local! 'transient-suspended #f)
            (transient--set-active! state)
            (transient--render!))))))

(define-command "transient-toggle-help" "Toggle suffix command documentation"
  (lambda ()
    (let ((state (transient--active)))
      (when state
        (transient--set-active! (plist-put state 'help (not (plist-get state 'help))))
        (transient--render!)))))

;;; Every change of the cursor goes through here, so a prefix can follow
;;; the cursor: 'on-select (SCOPE ITEM) runs with the row it lands on.
(define (transient--select! state index)
  (let* ((prefix (transient-prefix (plist-get state 'prefix)))
         (items (if prefix
                    (transient--visible-items (transient--visible-groups prefix state))
                    '()))
         (fn (and prefix (transient--prefix-option prefix 'on-select))))
    (transient--set-active! (plist-put state 'selected index))
    (when (and (procedure? fn) (< index (length items)))
      (fn (plist-get state 'scope) (nth index items)))))

;;; Up and down stay in the cursor's column and wrap inside it: in a menu
;;; whose columns mean different things, the last preset is not one row
;;; above the first field.
(define (transient--move-selection delta)
  (let* ((state (transient--active))
         (prefix (and state (transient-prefix (plist-get state 'prefix))))
         (groups (if prefix (transient--visible-groups prefix state) '()))
         (items (transient--visible-items groups))
         (selected (or (and state (plist-get state 'selected)) 0))
         ;; only a menu that declares its columns: without the option every
         ;; group is a column, and down still walks from group to group
         (column (let loop ((cs (if (and prefix (transient--prefix-option prefix 'columns))
                                    (transient--columns prefix state groups)
                                    '())))
                   (cond ((null? cs) #f)
                         ((member selected (transient--column-indexes groups (car cs)))
                          (transient--column-indexes groups (car cs)))
                         (else (loop (cdr cs))))))
         (ring (filter (lambda (i) (transient--item-selectable? (nth i items)))
                       (or column
                           (let loop ((i (- (length items) 1)) (acc '()))
                             (if (< i 0) acc (loop (- i 1) (cons i acc))))))))
    (when (pair? ring)
      (let* ((n (length ring))
             (at (transient--position selected ring)))
        (transient--select! state (nth (modulo (+ at delta n) n) ring)))
      (transient--render!))))

(define-command "transient-next" "Select the next suffix in the menu"
  (lambda () (transient--move-selection 1)))
(define-command "transient-previous" "Select the previous suffix in the menu"
  (lambda () (transient--move-selection -1)))

(define-command "transient-invoke-selected" "Invoke the selected menu suffix"
  (lambda ()
    (let* ((state (transient--active))
           (prefix (and state (transient-prefix (plist-get state 'prefix))))
           (items (if prefix
                      (transient--visible-items (transient--visible-groups prefix state)) '()))
           (index (or (and state (plist-get state 'selected)) 0)))
      (when (< index (length items))
        (run-command (plist-get (nth index items) 'wrapper))))))

(define (transient--history-use! delta)
  (let* ((state (transient--active))
         (name (and state (plist-get state 'prefix)))
         (history (transient--alist-get *transient-history* name '()))
         (index (and state (or (plist-get state 'history-index) -1)))
         (next (+ index delta)))
    (if (or (not state) (< next 0) (>= next (length history)))
        (message "No more transient history")
        (begin
          (transient--set-active!
            (plist-put
              (plist-put state 'history-index next)
              'values (nth next history)))
          (transient--render!)))))

(define-command "transient-history-prev" "Use the previous infix value set"
  (lambda () (transient--history-use! 1)))
(define-command "transient-history-next" "Use the next infix value set"
  (lambda () (transient--history-use! -1)))

(define-command "transient-set" "Use this infix value set as the session default"
  (lambda ()
    (let ((state (transient--active)))
      (when state
        (set! *transient-defaults*
          (alist-put *transient-defaults*
            (plist-get state 'prefix) (plist-get state 'values)))
        (message "Set transient values")))))

(define (transient--values-file)
  (string-append (compos-home) "/transient-values.scm"))

(define-command "transient-save" "Save this infix value set for future sessions"
  (lambda ()
    (run-command "transient-set")
    (write-file! (transient--values-file)
      (string-append "(set! *transient-defaults* '"
                     (value->string *transient-defaults*) ")\n"))
    (message "Saved transient values")))

(define-command "transient-reset" "Reset this transient's infix values"
  (lambda ()
    (let* ((state (transient--active))
           (name (and state (plist-get state 'prefix)))
           (prefix (and name (transient-prefix name))))
      (when state
        (set! *transient-defaults*
          (filter (lambda (e) (not (equal? (car e) name))) *transient-defaults*))
        (transient--set-active!
          (plist-put state 'values
            (transient--initial-values prefix (transient--visible-groups prefix state))))
        (transient--render!)))))

(when (file-exists? (transient--values-file))
  (load (transient--values-file)))

(public! 'transient-define-prefix
  "(transient-define-prefix NAME DOC GROUPS [OPTIONS]) — define a temporary grouped command menu. OPTIONS: 'on-setup 'on-quit (SCOPE), 'columns ((TITLE ...) ...) the groups that share a column (left/right move between columns), 'subtitle-fn 'context-fn (SCOPE) -> text, 'chips-fn (SCOPE) -> ((LABEL ACTIVE?) ...), 'detail-fn (SCOPE ITEM) -> (TITLE ((KEY VALUE TONE) ...) NOTE) the facts rail, 'legend-fn (SCOPE) -> ((KEY LABEL) ...) the footer, 'on-select (SCOPE ITEM) runs when the cursor lands on a row, 'keys-fn (SCOPE) -> ((KEY COMMAND) ...) keys that are no row and win over a row's key; a row whose key is the empty string takes no key, 'layout NAME the frame's layout class (split: a narrow first column and a wide second one)")
(public! 'transient-suffix
  "(transient-suffix KEY DESCRIPTION COMMAND [PROPERTIES]) — define a menu command")
(public! 'transient-infix
  "(transient-infix KEY DESCRIPTION COMMAND VALUE-FN [PROPERTIES]) — define a custom infix command")
(public! 'transient-switch
  "(transient-switch KEY DESCRIPTION ARGUMENT [PROPERTIES]) — define a boolean infix argument")
(public! 'transient-choice
  "(transient-choice KEY DESCRIPTION ARGUMENT CHOICES [PROPERTIES]) — define a cycling infix argument")
(public! 'transient-setup "(transient-setup NAME [SCOPE]) — activate a transient in this frame")
(public! 'transient-args "(transient-args [NAME]) — return the active or most recently exported arguments")
(public! 'transient-value "(transient-value ARGUMENT) — return one active infix value")
