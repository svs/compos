;;; keymaps.scm --- the keymap editor: every key in force, and the edits.
;;;
;;; M-x keys opens the list. It holds every binding the buffer you came
;;; from answers to, in ladder order, with the map each one comes from
;;; and a mark on the ones a nearer map shadows. RET describes the row,
;;; b gives the command on the row another key, d takes its key away,
;;; + binds a command that has no key, u takes back an edit of yours,
;;; and s widens the list to every keymap in the editor.
;;;
;;; An edit is one row of user-key-bindings: (MAP KEYS COMMAND WAS).
;;; COMMAND #f means the key is unbound, and WAS is what the key ran
;;; before, so u can put it back. customize writes that variable to
;;; custom.scm, which loads last at boot: the edits land after every
;;; package has made its maps, and the keys you chose come back.
;;;
;;; The editor never guesses a map. A rebind writes the map the row came
;;; from; an unbind writes the map that owns the binding, which for a
;;; key behind a prefix is the map the prefix leads to.

(domain! 'commands)
(effects! '(read))

(define *keys-buffer* "*keys*")

(defgroup 'keymaps "Keymaps: read every binding in force, and change one.")

;;; --- the bindings, read ----------------------------------------------

(define (keys--concat lists)
  (let loop ((ls (reverse lists)) (out '()))
    (if (null? ls) out (loop (cdr ls) (append (car ls) out)))))

(define (keys--own-bindings km)
  (if (equal? km "global") (global-keys) (keymap-bindings km)))

(define (keys--lookup km seq)
  ;; what the keymap itself answers for SEQ, never a parent and never a
  ;; prefix map: it is what an edit of this keymap replaces.
  (let loop ((bs (keys--own-bindings km)))
    (cond ((null? bs) #f)
          ((equal? (car (car bs)) seq) (cadr (car bs)))
          (else (loop (cdr bs))))))

(define (keys--prefix-map cmd)
  (and (string? cmd)
       (string-prefix? "keymap:" cmd)
       (substring cmd 7 (string-length cmd))))

(define (keys--doc cmd)
  (let ((d (and (string? cmd) (command-doc cmd))))
    (if (string? d) (car (string-split d "\n")) "")))

(define (keys--cmd-name cmd)
  ;; a map can hold a key that names no command at all: it reads as one
  ;; row like any other, and d takes it away.
  (if (string? cmd) cmd "(none)"))

(define (keys--dedupe rows)
  ;; one row per key sequence, the first one. The global map answers for
  ;; whole sequences as well as for the prefixes they run through, so a
  ;; key behind a prefix reads twice; the walked one comes first and it
  ;; is the one that names the keymap the binding really lives in.
  (let loop ((rs rows) (seen '()) (out '()))
    (cond ((null? rs) (reverse out))
          ((member (nth 0 (car rs)) seen) (loop (cdr rs) seen out))
          (else (loop (cdr rs) (cons (nth 0 (car rs)) seen) (cons (car rs) out))))))

(define (keys--expand km prefix seen)
  ;; ((SEQ COMMAND OWNER-MAP OWNER-SEQ) ...): the keymap's own bindings
  ;; as whole key sequences, the prefix maps walked through, the keys
  ;; that insert themselves left out.
  (if (member km seen)
      '()
      (let* ((bs (keys--own-bindings km))
             (seq-of (lambda (k) (if (equal? prefix "") k (string-append prefix " " k))))
             (walked (keys--concat
                       (map (lambda (b)
                              (let ((child (keys--prefix-map (cadr b))))
                                (if child
                                    (keys--expand child (seq-of (car b)) (cons km seen))
                                    '())))
                            bs)))
             (own (keys--concat
                    (map (lambda (b)
                           (let ((cmd (cadr b)))
                             (if (or (keys--prefix-map cmd)
                                     (equal? cmd "self-insert-command"))
                                 '()
                                 (list (list (seq-of (car b)) (keys--cmd-name cmd)
                                             km (car b))))))
                         bs))))
        (keys--dedupe (append walked own)))))

(define (keys--seq e) (nth 0 e))
(define (keys--cmd e) (nth 1 e))
(define (keys--map e) (nth 2 e))
(define (keys--owner e) (nth 3 e))
(define (keys--owner-seq e) (nth 4 e))
(define (keys--state e) (nth 5 e))

(define (keys--ladder-rows buf)
  ;; the ladder of BUF, nearest map first; a sequence a nearer map
  ;; already answered is shadowed here.
  (let loop ((maps (buffer-keymaps buf)) (seen '()) (out '()))
    (if (null? maps)
        (reverse out)
        (let inner ((rows (keys--expand (car maps) "" '()))
                    (seen seen)
                    (out out))
          (if (null? rows)
              (loop (cdr maps) seen out)
              (let* ((r (car rows))
                     (seq (nth 0 r))
                     (shadowed? (pair? (member seq seen))))
                (inner (cdr rows)
                       (if shadowed? seen (cons seq seen))
                       (cons (list seq (nth 1 r) (car maps) (nth 2 r) (nth 3 r)
                                   (if shadowed? "shadowed" ""))
                             out))))))))

(define (keys--map-names)
  (sort (filter (lambda (n) (string-suffix? "-map" n)) (keymap-names))))

(define (keys--all-rows)
  ;; every keymap in the editor, each with its own bindings only: a
  ;; prefix key reads as the map it leads to.
  (keys--concat
    (map (lambda (m)
           (keys--concat
             (map (lambda (b)
                    (if (equal? (cadr b) "self-insert-command")
                        '()
                        (list (list (car b) (keys--cmd-name (cadr b))
                                    m m (car b) ""))))
                  (keys--own-bindings m))))
         (cons "global" (keys--map-names)))))

;;; --- the edits -------------------------------------------------------

(define (keys--override km seq)
  (let loop ((es user-key-bindings))
    (cond ((null? es) #f)
          ((and (equal? (nth 0 (car es)) km) (equal? (nth 1 (car es)) seq))
           (car es))
          (else (loop (cdr es))))))

(define (keys--yours? e)
  (or (keys--override (keys--map e) (keys--seq e))
      (keys--override (keys--owner e) (keys--owner-seq e))))

(define (keys--bind! km seq cmd)
  (if (equal? km "global")
      (global-set-key seq cmd)
      (define-key km seq cmd)))

(define (keys--unbind! km seq)
  (if (equal? km "global")
      (global-unset-key seq)
      (keymap-unset! km seq)))

(define (keys--apply! entries)
  ;; a map a package no longer makes is skipped, not an error: the edit
  ;; stays on file and lands again the day the map comes back.
  (for-each
    (lambda (e)
      (let ((m (nth 0 e)) (s (nth 1 e)) (c (nth 2 e)))
        (when (or (equal? m "global") (member m (keymap-names)))
          (if (and (string? c) (not (equal? c "")))
              (keys--bind! m s c)
              (keys--unbind! m s)))))
    entries))

(define (keys--record! edits)
  ;; EDITS are (MAP SEQ COMMAND WAS) rows: one save, one custom.scm
  ;; write, and the setter applies every edit again.
  (let ((kept (filter (lambda (e)
                        (not (let loop ((new edits))
                               (cond ((null? new) #f)
                                     ((and (equal? (nth 0 (car new)) (nth 0 e))
                                           (equal? (nth 1 (car new)) (nth 1 e))) #t)
                                     (else (loop (cdr new)))))))
                      user-key-bindings)))
    (customize-save! 'user-key-bindings (append kept edits))))

(define (keys--forget! km seq)
  (customize-save! 'user-key-bindings
    (filter (lambda (e) (not (and (equal? (nth 0 e) km) (equal? (nth 1 e) seq))))
            user-key-bindings)))

(defcustom 'user-key-bindings '()
  "Your own key edits, as (KEYMAP KEYS COMMAND WAS) rows; COMMAND #f unbinds the key. The keymap editor writes this."
  'group 'keymaps
  'type 'list
  'set (lambda (v) (keys--apply! v)))

;;; --- the list --------------------------------------------------------

(define (keys--other-buffer)
  (let loop ((bs (buffer-list-mru)))
    (cond ((null? bs) "*scratch*")
          ((equal? (car bs) *keys-buffer*) (loop (cdr bs)))
          (else (car bs)))))

(define (keys--target buf)
  (let ((t (buffer-local buf 'keys--target)))
    (if (and (string? t) (buffer-known? t)) t (keys--other-buffer))))

(define (keys--scope buf)
  (or (buffer-local buf 'keys--scope) "all"))

(define (keys--unbound-rows maps)
  ;; a key you took away has no binding left to read, so the edit itself
  ;; is the row: u on it puts the old command back.
  (keys--concat
    (map (lambda (e)
           (if (and (not (string? (nth 2 e))) (member (nth 0 e) maps))
               (list (list (nth 1 e) "(unbound)" (nth 0 e) (nth 0 e) (nth 1 e) ""))
               '()))
         user-key-bindings)))

(define (keys--map-rows map)
  (map (lambda (row)
         (list (nth 0 row) (nth 1 row) map
               (nth 2 row) (nth 3 row) ""))
       (keys--expand map "" '())))

(define (keys--rows buf)
  (let ((scope (keys--scope buf)))
    (cond
      ((equal? scope "all") (keys--all-rows))
      ((equal? scope "buffer")
       (let ((target (keys--target buf)))
         (append (keys--ladder-rows target)
                 (keys--unbound-rows (buffer-keymaps target)))))
      (else
       (filter (lambda (row) (equal? (keys--map row) scope))
               (keys--all-rows))))))

(define (keys--cells buf e)
  (list (keys--seq e)
        (keys--cmd e)
        (keys--map e)
        (cond ((keys--yours? e) "yours")
              ((equal? (keys--state e) "shadowed") "shadowed")
              (else (keys--doc (keys--cmd e))))))

(define (keys--match? buf e input)
  (completion-match?
    (string-append (keys--seq e) " " (keys--cmd e) " "
                   (keys--map e) " " (keys--doc (keys--cmd e)))
    input
    'substring))

(define (keys--meta buf)
  (string-append
    (number->string (length (list-entries buf))) " keys · "
    (cond
      ((equal? (keys--scope buf) "all") "every keymap")
      ((equal? (keys--scope buf) "buffer")
       (string-append "in " (keys--target buf)))
      (else (string-append "in " (keys--scope buf))))
    " · " (number->string (length user-key-bindings)) " yours"))

(define (keys--current)
  (list-current *keys-buffer*))

(define (keys--redraw!)
  (when (buffer-known? *keys-buffer*) (list-refresh! *keys-buffer*)))

;;; --- the commands ----------------------------------------------------

(effects! '(write))

(define-command "keys" "Every key in force here, and the edits"
  (lambda ()
    (let ((from (current-buffer)))
      (buffer-create *keys-buffer*)
      (unless (equal? from *keys-buffer*)
        (buffer-set-local! *keys-buffer* 'keys--target from))
      (list-mode-show! "keys-mode"))))

(define-command "keys-refresh" "Read the keymaps again"
  (lambda () (keys--redraw!)))

(define-command "keys-scope" "Filter all bindings by keymap"
  (lambda ()
    (completing-read "Keymap scope: "
      (cons "all" (sort (keymap-names)))
      (lambda (scope)
        (when (and (string? scope) (not (equal? scope "")))
          (buffer-set-local! *keys-buffer* 'keys--scope scope)
          (list-filter-clear! *keys-buffer*)
          (keys--redraw!)
          (message (string-append "keys: " scope))))
      'require-match #t)))

(define-command "keys-describe" "Describe the key on this row"
  (lambda ()
    (let ((e (keys--current)))
      (if (not e)
          (message "no key here")
          (help-doc! (keys--seq e)
            (string-append
              "# " (keys--seq e) "\n\n"
              "Runs `" (keys--cmd e) "`.\n\n"
              (let ((d (keys--doc (keys--cmd e))))
                (if (equal? d "") "" (string-append d "\n\n")))
              "From the keymap `" (keys--map e) "`"
              (if (equal? (keys--owner e) (keys--map e))
                  ""
                  (string-append ", which leads to `" (keys--owner e)
                                 "`, where the binding is `" (keys--owner-seq e) "`"))
              ".\n\n"
              (if (equal? (keys--state e) "shadowed")
                  "A nearer keymap answers this key first, so it never runs here.\n\n"
                  "")
              (if (keys--yours? e) "This binding is your own edit.\n\n" "")
              "---\n\n`b` rebinds it · `d` unbinds it · `q` closes this page\n"))))))

(define-command "keys-rebind" "Give the command on this row another key"
  (lambda ()
    (let ((e (keys--current)))
      (if (not e)
          (message "no key here")
          (read-string (string-append "Run " (keys--cmd e) " on key (now "
                                      (keys--seq e) "): ")
            (lambda (typed)
              (let ((seq (string-trim (or typed ""))))
                (cond
                  ((equal? seq "") (message "no key, no change"))
                  ((equal? seq (keys--seq e)) (message "that is the key it has"))
                  (else
                    (keys--record!
                      (list (list (keys--owner e) (keys--owner-seq e) #f (keys--cmd e))
                            (list (keys--map e) seq (keys--cmd e)
                                  (keys--lookup (keys--map e) seq))))
                    (keys--redraw!)
                    (message (string-append seq " runs " (keys--cmd e)
                                            " · " (keys--seq e) " is free")))))))))))

(define-command "keys-unbind" "Take the key on this row away"
  (lambda ()
    (let ((e (keys--current)))
      (cond
        ((not e) (message "no key here"))
        ((equal? (keys--cmd e) "(unbound)") (message "already unbound"))
        (else
          (keys--record! (list (list (keys--owner e) (keys--owner-seq e) #f (keys--cmd e))))
          (keys--redraw!)
          (message (string-append (keys--seq e) " runs nothing now")))))))

(define-command "keys-bind" "Bind a command to a key, everywhere"
  (lambda ()
    (completing-read "Command: "
      (map (lambda (c) (list c (keys--doc c))) (sort (command-names)))
      (lambda (cmd)
        (when (and (string? cmd) (not (equal? cmd "")))
          (read-string (string-append "Run " cmd " on key: ")
            (lambda (typed)
              (let ((seq (string-trim (or typed ""))))
                (if (equal? seq "")
                    (message "no key, no change")
                    (begin
                      (keys--record!
                        (list (list "global" seq cmd (keys--lookup "global" seq))))
                      (keys--redraw!)
                      (message (string-append seq " runs " cmd " everywhere")))))))))
      'require-match #t)))

(define-command "keys-revert" "Take back your edit on this row"
  (lambda ()
    (let* ((e (keys--current))
           (o (and e (keys--yours? e))))
      (if (not o)
          (message "this key is not an edit of yours")
          (let ((km (nth 0 o)) (seq (nth 1 o)) (was (nth 3 o)))
            (keys--forget! km seq)
            (if (string? was)
                (keys--bind! km seq was)
                (keys--unbind! km seq))
            (keys--redraw!)
            (message (string-append seq " is "
                                    (if (string? was)
                                        (string-append "back on " was)
                                        "unbound again"))))))))

;;; --- the mode --------------------------------------------------------

(define-list-mode! "keys-mode"
  (list
    'doc (string-append
           "Every key in force in the buffer you came from, nearest keymap "
           "first, with the map each one comes from. A key a nearer map "
           "answers first reads as shadowed, and your own edits read as "
           "yours. RET describes the key, `b` gives its command another "
           "key, `d` takes the key away, `+` binds a command that has no "
           "key, `u` takes back an edit of yours, `k` filters the list by "
           "keymap, `/` searches and `g` reads the "
           "keymaps again. An edit lasts: customize keeps it in "
           "custom.scm, and the next session binds it again.")
    'buffer *keys-buffer*
    'rows keys--rows
    'local-filter #t
    'match keys--match?
    'page-size 60
    'columns (lambda (buf)
               (list (list "key" 18) (list "command" 30)
                     (list "keymap" 22) (list "note" #f)))
    'cells keys--cells
    'title (lambda (buf) "Keys")
    'meta keys--meta
    'total (lambda (buf) (length (list-entries buf)))
    'footer (lambda (buf)
              '(("RET" "describe") ("b" "rebind") ("d" "unbind")
                ("+" "bind") ("u" "revert") ("k" "keymap filter")
                ("/" "filter") ("g" "refresh") ("q" "quit")))
    'key (lambda (buf e) (string-append (keys--map e) " " (keys--seq e)))
    'keys '(("RET" "keys-describe") ("b" "keys-rebind")
            ("d" "keys-unbind") ("+" "keys-bind")
            ("u" "keys-revert") ("k" "keys-scope")
            ("g" "keys-refresh") ("q" "quit-window"))))

;; Remove the old scope key when hotload rebuilds this mode.
(keymap-unset! (mode-keymap "keys-mode") "s")

;; C-h b describes the bindings as a page; C-h B is the same keys as a
;; list you can edit.
(define-key "help-map" "B" "keys")

(category! 'commands)
(effects! '(write))

;; A palette sentence "bind C-x C-g k to group-kill" lands here: one
;; record, one custom.scm write, and the setter applies it at once.
(define (keys-bind-intent keys command)
  (if (command-fn command)
      (begin
        (keys--record!
          (list (list "global" keys command (keys--lookup "global" keys))))
        (keys--redraw!)
        (message (string-append keys " runs " command " everywhere"))
        #t)
      (begin
        (message (string-append "No command named " command))
        #f)))

(public! 'keys-bind-intent
  "(keys-bind-intent KEYS COMMAND) — bind COMMAND to KEYS everywhere and persist; #f when the command does not exist")

;; Keys as the keyboard prints them: C-x C-s is ⌃X ⌃S and s-<right> is ⌘→,
;; for the palette's key column and the tutorial's slides. The modifiers
;; come in the order macOS prints them: ⌃⌥⇧⌘.
(domain! 'commands)
(effects! '(pure))

(define *key-symbol-modifiers* '(("C-" "⌃") ("M-" "⌥") ("S-" "⇧") ("s-" "⌘")))

(define *key-symbol-names*
  '(("RET" "⏎") ("<return>" "⏎") ("SPC" "Space") ("TAB" "⇥") ("<tab>" "⇥")
    ("DEL" "⌫") ("<backspace>" "⌫") ("<delete>" "⌦") ("ESC" "esc")
    ("<left>" "←") ("<right>" "→") ("<up>" "↑") ("<down>" "↓")
    ;; a laptop keyboard has no Home, End, PageUp or PageDown: fn and an arrow
    ("<home>" "fn ←") ("<end>" "fn →") ("<prior>" "fn ↑") ("<next>" "fn ↓")))

(define (key-symbol token)
  ;; one key as symbols, or #f when TOKEN is not a key
  (let loop ((t token) (mods '()))
    (let ((m (find (lambda (p) (and (string-prefix? (car p) t) (> (string-length t) 1))) *key-symbol-modifiers*)))
      (if m
          (loop (substring t 2 (string-length t)) (cons (car m) mods))
          (let* ((mods (if (and (pair? mods) (= (string-length t) 1)
                                (not (equal? t (string-downcase t))))
                           ;; s-P is Shift-Cmd-P: the capital is the Shift
                           (cons "S-" mods)
                           mods))
                 (fkey (and (> (string-length t) 3) (string-prefix? "<f" t) (string-suffix? ">" t)
                            (string->number (substring t 2 (- (string-length t) 1)))
                            (string-append "F" (substring t 2 (- (string-length t) 1)))))
                 (sym (apply string-append
                             (map cadr (filter (lambda (p) (member (car p) mods)) *key-symbol-modifiers*))))
                 (named (assoc t *key-symbol-names*))
                 (base (cond ((equal? t "") (and (pair? mods) ""))
                             (named (cadr named))
                             (fkey fkey)
                             ;; a chord names its letter as the keycap does; a
                             ;; lone letter stays as typed, since N is Shift-n
                             ((= (string-length t) 1) (if (pair? mods) (string-upcase t) t))
                             (else #f))))
            (and base (or (pair? mods) named fkey (= (string-length t) 1))
                 (string-append sym base)))))))

(define (key-symbols keys)
  ;; KEYS that start with a key: each key as symbols, the rest as it is
  (let ((tokens (string-split keys " ")))
    (if (and (pair? tokens) (key-symbol (car tokens)))
        (string-join (map (lambda (t) (or (key-symbol t) t)) tokens) " ")
        keys)))

(public! 'key-symbol "(key-symbol KEY) — one key as the keyboard prints it: \"C-x\" is \"⌃X\"; #f when KEY is not a key")
(public! 'key-symbols "(key-symbols KEYS) — a key sequence as the keyboard prints it: \"C-x C-s\" is \"⌃X ⌃S\"")
