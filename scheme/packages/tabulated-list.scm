;;; tabulated-list.scm --- the one list buffer: rows, marks, flags, filters, pages.
;;;
;;; Emacs calls this tabulated-list-mode. Every list buffer in compos (dired,
;;; ibuffer, *chats*, mcp-hub, notmuch, the app tables) is this mode with a
;;; view: a title, columns, rows and a key bar, declared once with
;;; define-list-mode!. This file loads first from init.scm, before any
;;; package that declares a list.

;;; --- tabulated lists -----------------------------------------------------------
;;; Five buffers are the same buffer: dired, ibuffer, *chats*, mcp-hub and
;;; notmuch. Each had its own marks, its own filter stack, its own
;;; point-preserving refresh, its own n/p remap, and its own copy of
;;; "which entry is on the current line" — six copies of that one, with
;;; three different header-offset conventions between them.
;;;
;;; define-list-mode! owns all of it. A caller says where the rows come
;;; from and how one renders; everything else is the same list behaviour it
;;; was always going to need. It registers a real mode, so a restored list
;;; buffer comes back with its keys and its read-only flag instead of inert
;;; (S8), and the setup fn rebuilds from the buffer-locals like every other
;;; mode.
;;;
;;; A mode can have MANY buffers (dired: one per directory): every
;;; callback gets the buffer first, so rows and header can read the
;;; buffer's own locals. State — entries, marks, filters — is
;;; buffer-local already.
;;;
;;; OPTS is a plist:
;;;   buffer  the fixed buffer name, for one-buffer modes (list-mode-show!)
;;;   rows    (buf) -> entries. Any value; render turns one into a line.
;;;   render  (buf entry) -> one line, no trailing newline
;;;   key     (buf entry) -> a string identity, for marks. Default: the entry.
;;;   header  (buf) -> the header line, no trailing newline
;;;   keys    ((KEY COMMAND) ...)
;;;   remap   ((FROM-COMMAND TO-COMMAND) ...)
;;;   doc     what the list is for — "?" shows it above the key table
;;;   category  the marginalia category the entries belong to, so `/`
;;;             matches the annotation too — see list-match?
;;;   match   (buf entry input) -> #t to keep. What `/` means here.
;;;   filter  (buf entry filter) -> #t to keep. The mode's own filter kinds.
;;;   separator? (buf entry) -> #t for a section heading. Headings are not
;;;              choices. Filtering drops a heading when its section is empty.
;;;   section? (buf entry) -> #t for a row that starts a section. Default:
;;;            separator?. A selectable start (a folded section) stays
;;;            when its section is empty and it matches by itself.
;;;   selection-face  face name for the row at point. Omit it for no highlight.
;;;   fold    (buf) -> fold or unfold the section at point. TAB in a
;;;           prompt standing in front of this list calls it.
;;;   regroup (buf) -> cycle what a section is. M-g in that prompt calls it.

;; survives a reload of this file: every mode registered its options once
(define *list-modes* (if (boundp '*list-modes*) *list-modes* '()))

(define (list-mode-opts name)
  (let ((e (assoc name *list-modes*)))
    (if e (car (cdr e)) '())))

(define (list-mode-of buf) (buffer-local buf 'list-mode))

(define (list-plist-key? pl key)
  (let loop ((rest pl))
    (cond ((or (null? rest) (null? (cdr rest))) #f)
          ((equal? (car rest) key) #t)
          (else (loop (cdr (cdr rest)))))))

(define (list-layout-bound buf profile key)
  (let ((value (plist-get profile key)))
    (if (procedure? value) (value buf) value)))

;; Where narrow starts is the system's answer, not each view's: every
;; list turns at the same width, so a profile that calls itself narrow or
;; compact declares only WHICH columns survive. An explicit min-cols or
;; max-cols still wins. The headline at the top of a window turns at the
;; same two widths, and a mode there declares only WHICH segments survive.
(define narrow-cols 64)
(define compact-cols 100)

(define (list-layout-named-max profile)
  (let ((name (plist-get profile 'name)))
    (cond ((equal? name 'narrow) (- narrow-cols 1))
          ((equal? name 'compact) (- compact-cols 1))
          (else #f))))

(define (list-layout-match? buf profile width)
  (let ((minimum (list-layout-bound buf profile 'min-cols))
        (maximum (or (list-layout-bound buf profile 'max-cols)
                     (list-layout-named-max profile))))
    (or (plist-get profile 'default)
        (and (or minimum maximum)
             (or (not minimum) (>= width minimum))
             (or (not maximum) (<= width maximum))))))

(define (list-select-layout buf layouts width)
  (let loop ((rest layouts))
    (cond ((null? rest) '())
          ((list-layout-match? buf (car rest) width) (car rest))
          (else (loop (cdr rest))))))

;; Select one responsive profile per draw. Every option read then uses it.
(define (list-active-layout buf)
  ;; the cache answers first: working the profile out again means reading
  ;; the mode table and its layouts before finding out nothing changed
  (let ((width (list-view-width buf))
        (cache (buffer-local buf 'list-layout-cache)))
    (if (and (pair? cache) (equal? (car cache) width))
        (cadr cache)
        (let* ((opts (list-mode-opts (list-mode-of buf)))
               (layouts (or (plist-get opts 'layouts) '()))
               (profile (list-select-layout buf layouts width)))
          (when (buffer-exists? buf)
            (buffer-set-local! buf 'list-layout-cache (list width profile)))
          profile))))

(define (list-opt buf key)
  (let* ((opts (list-mode-opts (list-mode-of buf)))
         (profile (list-active-layout buf)))
    (if (list-plist-key? profile key)
        (plist-get profile key)
        (plist-get opts key))))

;; how many lines of header sit above the first entry — a header may be
;; several lines, and every one of the five had hardcoded its own count
(define (list-header-lines buf)
  (length (list-head-lines buf)))

(define (list-header-text buf)
  (string-join (map car (list-head-lines buf)) "\n"))

;; the 0-based index of the entry line BUF's point is on, or #f above the
;; entries. BUF's own point, not (point): a context provider asks about a
;; list buffer while another buffer is current.
;; A buffer that has never been displayed has no point yet, and a list
;; built for a minibuffer prompt is asked about before it ever is. No
;; point is above the entries, the same answer as point 0.
(define (line-index-at buf header-lines)
  (let ((at (buffer-point buf)))
    (and (number? at)
         (let* ((before (substring-bytes (buffer-text buf) 0 at))
                (ln (- (length (string-split before "\n")) 1 header-lines)))
           (and (>= ln 0) ln)))))

(define (list-entries buf) (or (buffer-local buf 'list-entries) '()))

(define (list-key buf e)
  (let ((f (list-opt buf 'key)))
    (if f (f buf e) e)))

;; The entry on the current line, or #f when the list has no rows. Point
;; can sit off the rows — a click lands on the header or the key bar, and
;; a mouse click runs no command — so the row at point is the NEAREST
;; row. Every verb reads this one answer, so RET, `k` and a mark all act
;; on the row the highlight then rests on (post-command! moves it there).
(define (list-separator? buf e)
  (let ((f (list-opt buf 'separator?)))
    (and f (f buf e))))

(define (list-selectable? buf e) (not (list-separator? buf e)))

(define (list-current buf)
  (let ((i (list-clamped-index buf))
        (es (list-entries buf)))
    (and i (< i (length es))
         (let ((e (nth i es))) (and (list-selectable? buf e) e)))))

;;; marks — a list of (KEY CHAR), on the list buffer

(define (list-marks buf) (or (buffer-local buf 'list-marks) '()))

(define (list-mark-of buf e &optional ctx)
  (let* ((key (if ctx
                  (let ((f (list-ctx-key ctx))) (if f (f buf e) e))
                  (list-key buf e)))
         (m (assoc key (if ctx (list-ctx-marks ctx) (list-marks buf)))))
    (if m (car (cdr m)) " ")))

(define (list-mark! buf e ch)
  (let* ((k (list-key buf e))
         (rest (filter (lambda (m) (not (equal? (car m) k))) (list-marks buf))))
    (buffer-set-local! buf 'list-marks (if ch (cons (list k ch) rest) rest))))

(define (list-marked buf ch)
  (map car (filter (lambda (m) (equal? (car (cdr m)) ch)) (list-marks buf))))

(define (list-clear-marks! buf) (buffer-set-local! buf 'list-marks '()))

;; unmark by the stored KEY — the execute loop holds keys, not entries,
;; and list-mark! would run the mode's 'key fn on one
(define (list-unmark-key! buf k)
  (buffer-set-local! buf 'list-marks
    (filter (lambda (m) (not (equal? (car m) k))) (list-marks buf))))

;;; --- flag, then execute ------------------------------------------------------
;;; The dired paradigm, in the mechanism. A list declares what its flags DO:
;;;
;;;   'flags ((KEY CHAR VERB ACTION CONFIRM?) ...)
;;;
;;; KEY flags the entry at point with CHAR. `x` runs every flagged entry
;;; through (ACTION LIST-BUFFER KEY) — the entry's 'key identity, which IS
;;; the entry for a list without a 'key fn. The action answers #t when it
;;; acted and #f when it found nothing to do; `x` reports "VERB N NOUN". CONFIRM?
;;; asks first. The mechanism supplies the rest: SPC marks, `u` unmarks,
;;; `U` drops every mark, and the mark column goes in front of every row.
;;;
;;; Three lists had written their own copy of this and the copies had
;;; drifted: one asked before it acted, one moved point after marking, one
;;; killed a runtime the moment you pressed the key. A list now says only
;;; what its flags mean.

(define *list-mark-char* "*")

(define (list-flags buf) (or (list-opt buf 'flags) '()))

;; a list may refuse to mark some rows (dired: "..")
(define (list-markable? buf e)
  (let ((f (list-opt buf 'markable?)))
    (and (list-selectable? buf e) (if f (f buf e) #t))))

;; a mark needs a column to show in. A list with flags has always had
;; one; a list with columns gets one too, because marking is what every
;; one of them does.
(define (list-marks-column? buf)
  (or (pair? (list-flags buf)) (list-table? buf)))

(define (list-mark-at-point! ch)
  (let* ((buf (current-buffer))
         (e (list-current buf))
         (i (list-index buf)))
    (if (not (and e (list-markable? buf e)))
        (message "no entry on this line")
        ;; a mark changes no row — redraw what the list has; a refresh
        ;; would call the source (the network, for sentry) per keypress
        (begin (list-mark! buf e ch)
               (list-redraw! buf)
               (list-goto-index! buf (+ (or i 0) 1))))))

;; a mark is only as real as the row it sits on. Marks persist with the
;; buffer (durable lifecycle), so after a restart they can name rows the
;; list no longer shows — a verb must act on what the reader SEES.
(define (list-live-marked buf ch)
  ;; A local filter hides source rows; it does not delete them. Keep marks
  ;; valid against the full source so narrowing can build one transaction.
  (let* ((entries (if (list-opt buf 'local-filter)
                      (list-source-entries buf)
                      (list-entries buf)))
         (keys (map (lambda (e) (list-key buf e)) entries)))
    (filter (lambda (k) (member k keys)) (list-marked buf ch))))

(define (list-targets buf)
  ;; Marked actions in a local-filter list use the full source. This lets
  ;; the user mark one row, narrow to another, and act on both together.
  (let* ((m (list-live-marked buf *list-mark-char*))
         (entries (if (list-opt buf 'local-filter)
                      (list-source-entries buf)
                      (list-entries buf))))
    (if (pair? m)
        (filter (lambda (e) (member (list-key buf e) m)) entries)
        (let ((e (list-current buf))) (if e (list e) '())))))
;; This is what makes one key work on one chat and on twelve. ENTRIES,
;; not keys, in both cases: a list whose rows are plists (sentry) marks
;; by key but acts on the row itself.

(define-command "list-mark" "Mark the entry at point"
  (lambda () (list-mark-at-point! *list-mark-char*)))

(define-command "list-unmark" "Unmark the entry at point"
  (lambda () (list-mark-at-point! #f)))

;; one key that marks and unmarks: a marked or flagged row loses its
;; mark, any other row gets one
(define-command "list-toggle-mark" "Mark the entry at point, or unmark a marked one"
  (lambda ()
    (let* ((buf (current-buffer))
           (e (list-current buf)))
      (list-mark-at-point!
        (if (and e (not (equal? (list-mark-of buf e) " "))) #f *list-mark-char*)))))

(define-command "list-unmark-all" "Drop every mark and flag in this list"
  (lambda ()
    (let ((buf (current-buffer)))
      (list-clear-marks! buf)
      (list-redraw! buf))))

;; `*` marks the whole list — the rows you narrowed to, because a filter
;; and a mark say the same thing: these ones
(domain! 'interaction)
(effects! '(write))

(define-command "list-mark-all" "Mark every row this list shows; again unmarks them"
  (lambda ()
    (let* ((buf (current-buffer))
           (i (list-index buf))
           (markable (filter (lambda (e) (list-markable? buf e))
                             (list-entries buf)))
           ;; a second `*` reads as "never mind": every shown row already
           ;; marked means unmark them all
           (all-marked?
             (and (pair? markable)
                  (let loop ((es markable))
                    (cond ((null? es) #t)
                          ((equal? (list-mark-of buf (car es)) *list-mark-char*)
                           (loop (cdr es)))
                          (else #f))))))
      (for-each (lambda (e)
                  (list-mark! buf e (if all-marked? #f *list-mark-char*)))
                markable)
      (list-redraw! buf)
      (when i (list-goto-index! buf i)))))

(domain! 'unknown)
(effects! '(unknown))

;; a keymap binds a command NAME, so each flag char needs a command of its
;; own. The body is the same in every list, so one command per char serves
;; all of them.
(define (list-flag-command ch)
  (let ((name (string-append "list-flag-" ch)))
    (define-command name (string-append "Flag the entry at point with " ch)
      (lambda () (list-mark-at-point! ch)))
    name))

;; Every flag that has something flagged, in the order the list declared
;; — and the marked rows go with the FIRST flag. `*` and `m` say WHICH
;; rows; the flag says WHAT to do. A list with one flag needs no second
;; key for it: mark the rows and press `x`. A flagged row keeps its own
;; flag, because a row carries one mark and the two sets cannot overlap.
(define (list-execute-plan buf)
  (let loop ((fs (list-flags buf))
             (marked (list-live-marked buf *list-mark-char*))
             (out '()))
    (if (null? fs)
        (reverse out)
        (let ((rows (append (list-live-marked buf (car (cdr (car fs)))) marked)))
          (loop (cdr fs) '()
                (if (null? rows) out (cons (list (car fs) rows) out)))))))

;; what one row IS, for the prompts: "delete 2 files" reads like a question
;; a person asks. A list that declares no noun gets "row".
(define (list-noun buf n)
  (let ((w (or (list-opt buf 'noun) "row")))
    (if (= n 1) w (string-append w "s"))))

(define (list-plan-label buf plan)
  (string-join (map (lambda (p)
                      (let ((n (length (car (cdr p)))))
                        (string-append (nth 2 (car p)) " "
                                       (number->string n) " "
                                       (list-noun buf n))))
                    plan)
               " · "))

(define (list-plan-asks? plan)
  (let loop ((ps plan))
    (cond ((null? ps) #f)
          ((and (> (length (car (car ps))) 4) (nth 4 (car (car ps)))) #t)
          (else (loop (cdr ps))))))

;; Clear the flag BEFORE the action runs: an action may kill the entry, and
;; a mark on a row that no longer exists outlives every refresh. The report
;; counts what the actions DID — an action answers #f when it found nothing
;; to do, so "kill runtime 0 chats" is a sentence this can say.
(define (list-plan-run! buf plan)
  (let loop ((ps plan) (parts '()))
    (if (null? ps)
        (begin (list-refresh! buf)
               (message (string-join (reverse parts) " · ")))
        (let* ((spec (car (car ps)))
               (action (nth 3 spec))
               (n (let inner ((es (car (cdr (car ps)))) (k 0))
                    (cond ((null? es) k)
                          (else (list-unmark-key! buf (car es))
                                (inner (cdr es)
                                       (if (action buf (car es)) (+ k 1) k)))))))
          (loop (cdr ps)
                (cons (string-append (nth 2 spec) " " (number->string n) " "
                                     (list-noun buf n))
                      parts))))))

(define-command "list-execute" "Run the flags in this list"
  (lambda ()
    (let* ((buf (current-buffer))
           (plan (list-execute-plan buf)))
      (cond ((null? plan) (message "nothing marked"))
            ((list-plan-asks? plan)
             (minibuffer-read (string-append (list-plan-label buf plan) "? ")
                              (list "yes" "no")
                              (lambda (ans)
                                (if (equal? ans "yes")
                                    (list-plan-run! buf plan)
                                    (message "Cancelled")))))
            (else (list-plan-run! buf plan))))))

;; the marking keys. Every list that shows a mark column marks the same
;; way — SPC marks (m as well), `u`, `U` and `*` — and a list that declares flags also gets
;; the flag chars and `x`. They go in before the list's own keys, so a
;; list can still claim any of them for something else.
;; Every list answers the same keys, from one map every list mode's map
;; falls back to: help, the filter, the row motion, the marks, and
;; execute. A list mode's own keys shadow them, because its map is the
;; child. The flag keys a list declares go on its own map when it is
;; defined (define-list-mode!); a layout profile that brings flags of
;; its own binds them on the buffer, since the profile is buffer state.
(define-keymap! "list-mode-map")
(for-each (lambda (p) (define-key "list-mode-map" (car p) (cadr p)))
  '(("?" "list-keys-toggle")
    ("/" "list-filter") ("f" "list-filter") ("\\" "list-filter-pop")
    ("<" "list-cycle-grouping") (">" "list-cycle-sorting")
    ("n" "list-next") ("p" "list-prev")
    ("SPC" "list-toggle-mark") ("m" "list-mark")
    ("u" "list-unmark") ("U" "list-unmark-all") ("*" "list-mark-all")
    ("x" "list-execute") ("g" "list-revert")))

;; These keys are the grammar of every markable list, not suggestions inherited from
;; the parent map. Install them on each child too, so a mode cannot keep an
;; older local meaning. SPC always marks the row at point.
;;
;; / is the search key everywhere in this editor, so it is the search key
;; in every list: it narrows the rows to what you type. Grouping and
;; sorting are a pair and read as one, on < and >. A list mode that
;; declares / in its own keys does not get it -- these go on last.
(define (list-mode-standard-keys! name)
  (let ((opts (list-mode-opts name)))
    (define-key (mode-keymap name) "/" "list-filter")
    (define-key (mode-keymap name) "<" "list-cycle-grouping")
    (define-key (mode-keymap name) ">" "list-cycle-sorting")
    ;; SPC toggles: a marked row loses its mark, any other row gets one,
    ;; and point moves down. m marks only. A mode's mark-command replaces
    ;; the toggle.
    (unless (plist-get opts 'no-marks)
      (define-key (mode-keymap name) "SPC"
        (or (plist-get opts 'mark-command) "list-toggle-mark")))))

;; A hot reload does not re-run the packages that registered their modes.
(for-each (lambda (entry) (list-mode-standard-keys! (car entry))) *list-modes*)

;; the flag keys of one list: (KEY FLAG-CHAR ...) rows become bindings
;; on MAP, buffer or mode
(define (list-flag-keys! bind fs)
  (for-each (lambda (f) (bind (car f) (list-flag-command (car (cdr f))))) fs))

;; a profile's own flags, beyond the mode's, go on the buffer
(define (list-install-mark-keys! buf)
  (let ((fs (or (list-opt buf 'flags) '()))
        (declared (or (plist-get (list-mode-opts (list-mode-of buf)) 'flags) '())))
    (unless (equal? fs declared)
      (list-flag-keys! (lambda (k c) (local-set-key* buf k c)) fs))))

;;; filters — a stack of (LABEL ARG), newest first

(define (list-filters buf) (or (buffer-local buf 'list-filters) '()))

(define (list-filter-push! buf f)
  (buffer-set-local! buf 'list-filters (cons f (list-filters buf)))
  (list-redraw! buf))

;; The query is ONE filter, not a stack of them: the text you type IS
;; the narrowing, so deleting it widens and emptying it removes it.
;; A mode's own filter (dired's dotfiles) is a different kind and keeps
;; its place in the stack.
(define (list-query buf)
  (let ((f (assoc "match" (list-filters buf))))
    (if f (car (cdr f)) "")))

(define (list-set-query! buf q &optional fetch)
  ;; A source whose scope depends on the query can fetch and draw once.
  ;; Repeating the same local query has no work to do.
  (when (or fetch (not (equal? q (list-query buf))))
    (let ((rest (filter (lambda (f) (not (equal? (car f) "match")))
                        (list-filters buf))))
      (buffer-set-local! buf 'list-filters
        (if (equal? q "") rest (cons (list "match" q) rest)))
      (list-render! buf fetch))))

;; drop the typed query and keep the mode's own kinds (dired's dotfiles).
;; No refresh: the caller is opening the list and draws it next.
(define (list-clear-query! buf)
  (let* ((before (list-filters buf))
         (rest (filter (lambda (f) (not (equal? (car f) "match"))) before)))
    (buffer-set-local! buf 'list-filters rest)
    ;; #t when it dropped a query, so the caller knows the rows in the
    ;; buffer are narrower than the list now holds
    (not (= (length before) (length rest)))))

(define (list-filter-pop! buf)
  (let ((fs (list-filters buf)))
    (unless (null? fs) (buffer-set-local! buf 'list-filters (cdr fs)))
    (list-redraw! buf)))

(define (list-filter-clear! buf)
  (buffer-set-local! buf 'list-filters '())
  (list-redraw! buf))

;;; --- `/` narrows --------------------------------------------------------------
;;; One filter, for every list. You press `/` and type; the list narrows
;;; on every keystroke to the rows that match. The arrows move the rows
;;; while you type, so you type and then you select. RET keeps the
;;; narrowing and the row you chose, C-g closes the entry, `/` again
;;; narrows the narrowing — the filters stack, and the stack persists with
;;; the buffer. `\` widens by one.
;;;
;;; A row matches on everything you can SEE: its line, and the marginalia
;;; the prompts show beside the same thing (the mode names the category).
;;; So dired finds `elixir-mode` and ibuffer finds a group, and neither
;;; needs a filter of its own. The zoo this replaces — one command and one
;;; chord per field, name, extension, type, mode — asked you to say which
;;; field before you said what you wanted.
;;;
;;; A mode that knows better declares 'match (buf entry input) -> #t.

(define (list-annotation-fields buf e)
  (let* ((cat (list-opt buf 'category))
         (f (and cat (marginalia-for cat))))
    (if f (map string-trim (marginalia-row f e)) '())))

(define (list-annotation buf e)
  (string-join (list-annotation-fields buf e) " "))

;; the whole row as text: the lines you see, and what they mean. A table
;; row matches on its columns, because its columns are what it shows, and
;; a row of two lines matches on both of them.
(define (list-row-text buf e &optional ctx)
  (string-append (string-join (map car (list-row-lines buf e ctx)) " ")
                 " " (list-annotation buf e)))

;; a list narrows the way a prompt does: one matcher, case-insensitive,
;; every term a substring of the row, and a "(" in the input is a
;; character, not half of a regexp
(define (list-match? buf e input &optional ctx)
  (let ((m (if ctx (nth 7 ctx) (list-opt buf 'match))))
    (if m (m buf e input) (completion-match? (list-row-text buf e ctx) input 'substring))))

;; every list gets the "match" kind; the mode's own 'filter fn reads the
;; kinds it invented. A list with neither keeps every row.
(define (list-filter-match? buf e f &optional ctx)
  (if (equal? (car f) "match")
      (list-match? buf e (car (cdr f)) ctx)
      (let ((m (if ctx (nth 8 ctx) (list-opt buf 'filter))))
        (if m (m buf e f) #t))))

;; the rows that survive the stack — the loop each list wrote by hand.
;; The filters and the row context are read once, not once per row.
(define (list-entry-kept? buf e filters ctx)
  (let loop ((fs filters))
    (cond ((null? fs) #t)
          ((list-filter-match? buf e (car fs) ctx) (loop (cdr fs)))
          (else #f))))

;; Split at heading rows before filtering. A heading owns every row up to the
;; next heading. It stays only when at least one row in its section stays.
(define (list-keep-section-emit buf heading rows filters ctx)
  (let ((kept (filter (lambda (e) (list-entry-kept? buf e filters ctx))
                      (reverse rows))))
    (cond ((pair? kept)
           (let ((project (list-opt buf 'filtered-heading)))
             (if heading
                 (cons (if project (project buf heading kept) heading) kept)
                 kept)))
          ;; a heading that is a row of its own (a folded section) stays
          ;; when it matches by itself
          ((and heading
                (list-selectable? buf heading)
                (list-entry-kept? buf heading filters ctx))
           (let ((project (list-opt buf 'filtered-heading)))
             (list (if project (project buf heading #f) heading))))
          (else '()))))

;; a row that starts a section: a heading, or a folded section standing
;; as one selectable row. The mode's 'section? says which; without it,
;; the separators are the only starts.
(define (list-section-start? buf e)
  (let ((f (list-opt buf 'section?)))
    (if f (f buf e) (list-separator? buf e))))

(define (list-keep-sections buf entries filters ctx)
  ;; Each section answers with its own kept rows and the whole is joined
  ;; once. Threading the result so far through append copied every section
  ;; already kept onto the next one, so a table of 41 sections paid for its
  ;; own length again and again -- docs/LISTS.md rule 1.
  ;;
  ;; The section test is one option read, and an option read walks the
  ;; mode table and the layout profile. Asking for it once per entry cost
  ;; 90ms of every keystroke in the filter line of a 277-row table, so it
  ;; is read once, here.
  (let ((start? (or (list-opt buf 'section?) list-separator?)))
    (let walk ((rest entries) (heading #f) (rows '()) (out '()))
      (cond ((null? rest)
             (apply append
               (reverse (cons (list-keep-section-emit buf heading rows filters ctx) out))))
            ((start? buf (car rest))
             (walk (cdr rest) (car rest) '()
                   (cons (list-keep-section-emit buf heading rows filters ctx) out)))
            (else (walk (cdr rest) heading (cons (car rest) rows) out))))))

(define (list-keep buf entries)
  (let ((filters (list-filters buf)))
    (let ((ctx (list-row-ctx buf)))
      (if (list-opt buf 'separator?)
          (list-keep-sections buf entries filters ctx)
          (if (null? filters)
              entries
              (filter (lambda (e) (list-entry-kept? buf e filters ctx))
                      entries))))))

;; A list that declares 'local-filter fetches its source once and runs
;; the filters on the cache: a keystroke in `/` must not call the source
;; again. A plain list computes its rows on every draw.
(define (list-source-entries buf)
  (or (buffer-local buf 'list-source-entries) '()))

;; A substring filter can only lose matches as the query grows. Keep the
;; previous candidate set outside display state; backspace starts from source.
(define *list-filter-history* '())

(define (list-filter-forget! buf)
  (set! *list-filter-history*
    (filter (lambda (entry) (not (equal? (car entry) buf))) *list-filter-history*)))

(define (list-filter-cached! buf source fetch)
  (let* ((filters (list-filters buf))
         (previous (assoc buf *list-filter-history*))
         (query (assoc "match" filters))
         (old-query (and previous (assoc "match" (cadr previous))))
         (can-extend (list-opt buf 'incremental-query?))
         (extend? (and (not fetch) previous query old-query
                       (or (not can-extend) (can-extend (cadr old-query) (cadr query)))
                       (equal? source (caddr previous))
                       (not (equal? (cadr old-query) ""))
                       (string-prefix? (string-downcase (cadr old-query))
                                       (string-downcase (cadr query)))
                       (equal? (remove (lambda (f) (equal? (car f) "match")) filters)
                               (remove (lambda (f) (equal? (car f) "match")) (cadr previous)))))
         (rows (list-keep buf (if extend? (nth 3 previous) source))))
    (list-filter-forget! buf)
    (set! *list-filter-history*
      (take (cons (list buf filters source rows) *list-filter-history*) 32))
    rows))

(define (list-filter-source buf)
  (let ((f (list-opt buf 'source-filter)) (source (list-source-entries buf)))
    (if f (f buf source) source)))

(define (list-render-rows! buf fetch)
  (if (list-opt buf 'local-filter)
      (begin
        (when (or (equal? fetch #t)
                  (not (buffer-local buf 'list-source-entries)))
          (buffer-set-local! buf 'list-source-entries
                             ((list-opt buf 'rows) buf))
          (let ((updated (list-opt buf 'source-refreshed)))
            (when updated (updated buf))))
        (if (list-opt buf 'incremental-filter)
            (list-filter-cached! buf (list-filter-source buf) fetch)
            (list-keep buf (list-filter-source buf))))
      ;; 'cached is the wake path: the rows already in 'list-entries ARE
      ;; the view, and calling the source again would pay its cost (the
      ;; network, for sentry) inside a switcher preview. A filter redraw
      ;; still passes #f and reaches the source, which reads the query.
      (if (and (equal? fetch 'cached)
               (pair? (buffer-local buf 'list-entries)))
          (list-entries buf)
          ((list-opt buf 'rows) buf))))

;;; --- the view: a title, columns, rows, a key bar ------------------------------
;;; Every list draws the same shape. A mode says what its columns are and
;;; what one row puts in them; the mechanism pads the cells, colours them,
;;; writes the column labels, shows the narrowing you typed and prints the
;;; key bar. Three lists had each written their own padding and their own
;;; header string, and the three had drifted apart.
;;;
;;;   'title    (buf) -> string             what this list shows
;;;   'meta     (buf) -> string             the counts under the title,
;;;                      or (TEXT SPANS) with its own (OFFSET LENGTH FACE) spans
;;;   'total    (buf) -> number             rows before the filters, for the chip
;;;   'columns  (buf) -> ((LABEL WIDTH ALIGN TRIM) ...)
;;;                      WIDTH #f means the rest of the line.
;;;                      ALIGN is 'left or 'right.
;;;                      TRIM is 'middle (the default), 'end, or a
;;;                      (TEXT WIDTH) -> TEXT fn of the mode's own.
;;;   'cells    (buf entry) -> (CELL ...)   CELL is a string, or (TEXT FACE)
;;;
;;; A row may take more than one line. Such a mode declares the two in
;;; the plural — one column list and one cell list per line of a row:
;;;
;;;   'row-columns (buf) -> (COLUMNS ...)
;;;   'row-cells   (buf entry) -> (CELLS ...)
;;;   'collection semantic collection tag; 'composml (buf entry) -> block
;;;              Optional semantic row projection; keys must be strings.
;;;   'composml-head (buf head) -> (BLOCK ...)
;;;              Optional head of that projection. The default draws the
;;;              head's own lines as text; a mode answering this draws it
;;;              as blocks, so a tab bar can be tabs.
;;;
;;; The mark goes on the first line and the lines under it start where it
;;; does. A two-line row has no single label row, so the head shows none.
;;;   'footer   (buf) -> ((KEY WORD) ...)   the key bar under the rows
;;;                                       it renders through the shared ui/keymap
;;;                                       component by default
;;;   'preview  (buf entry)                 what moving the highlight shows
;;;   'compact  #t                          merge title and meta; omit rules
;;;   'layouts  ordered profile plists. A profile can override view options.
;;;             min-cols and max-cols select by measured text width.
;;;             A final (default #t ...) profile supplies the fallback.
;;;
;;; A list whose rows come from a slow source (the network) declares the
;;; source through the buffer cache instead of 'rows doing the fetch:
;;;   'cache-fetch (buf k)                  fetch off the UI lane, call (k ROWS);
;;;                                         (k #f) on failure keeps the old rows
;;;   'cache-ttl   SECONDS                  wake refreshes only past this age;
;;;                                         #f fetches only on explicit refresh
;;; 'rows then serves (list-entries buf) — the cache IS the source of the
;;; view — and the mode's `g` calls cache-refresh! instead of list-refresh!.
;;;
;;; A mode that declares 'columns gets the mark column, the m/u/U/* keys
;;; and the clamped n/p for free. A mode that declares 'header and 'render
;;; keeps the plain lines it always had.

(define *list-gap* "  ")

;; the window the list is in, in characters. The client measures its own
;; font and reports it; a list nobody is showing lays out for the active
;; window, and one nobody has measured gets the default. The last column
;; keeps one character clear of the edge, so nothing wraps.
(define (list-view-width buf)
  ;; A dormant list's saved text and semantic ranges share its last width.
  (or (and (not (buffer-exists? buf)) (buffer-local buf 'list-width))
      (max 40 (- (buffer-cols buf) 1))))

;; the column that declares no width takes whatever the others leave, so
;; the table fills the window instead of stopping short of it
(define (list-fit-columns cols w)
  (let* ((fixed (fold (lambda (acc c) (+ acc 2 (or (list-col-width c) 0))) 2 cols))
         (rest (max 8 (- w fixed))))
    (map (lambda (c)
           (if (list-col-width c)
               c
               (list (car c) rest (list-col-align c) (list-col-trim c))))
         cols)))

;; a mode says its columns once per line of a row. A one-line list says
;; 'columns and means one line; a two-line list says 'row-columns.
(define (list-declared-columns buf)
  (let ((g (list-opt buf 'row-columns))
        (f (list-opt buf 'columns)))
    (cond (g (g buf))
          (f (list (f buf)))
          (else '()))))

;; The mode's columns fn runs once per draw: every later call in the
;; same draw reads the cache. The cache keys on the width, so a resize
;; recomputes. A draw clears the cache first.
;;; The column layout is a cache, not state the frame shows. A buffer
;;; local is a change, and a change is a frame refresh and a render, so
;;; a draw that laid its columns out again refreshed every frame twice
;;; for a table nobody could see change. The cache lives here instead,
;;; one entry per list buffer, keyed by the width it was laid out for.
(define *list-columns-cache* '())

(define (list-columns-forget! buf)
  (set! *list-columns-cache*
        (filter (lambda (e) (not (equal? (car e) buf))) *list-columns-cache*)))

(define (list-column-lines buf)
  (let* ((w (list-view-width buf))
         (cache (assoc buf *list-columns-cache*)))
    (if (and cache (equal? (cadr cache) w))
        (nth 2 cache)
        (let ((cols (map (lambda (cs) (list-fit-columns cs w))
                         (list-declared-columns buf))))
          (list-columns-forget! buf)
          (set! *list-columns-cache*
                (cons (list buf w cols) *list-columns-cache*))
          cols))))

;; the first line's columns — the label row and every caller that means
;; "the columns" reads these
(define (list-columns buf)
  (let ((ls (list-column-lines buf)))
    (if (pair? ls) (car ls) '())))

;; how many lines one row takes. A render reads the mode; motion reads
;; what the last render wrote, so a mode that changed under a stale
;; buffer never moves point to a line that is not there.
(define (list-row-height buf) (max 1 (length (list-column-lines buf))))

(define (list-drawn-row-height buf)
  (or (buffer-local buf 'list-row-height) 1))

(define (list-table? buf) (pair? (list-columns buf)))

;; a mode answers with a string, or does not answer at all
(define (list-say buf key)
  (let ((f (list-opt buf key)))
    (if f (or (f buf) "") "")))

(define (list-cell-text c) (if (pair? c) (car c) c))
(define (list-cell-face c) (if (pair? c) (car (cdr c)) #f))

;; a name too long for its column loses its MIDDLE: the head says what
;; the thing is and the tail says which one, and a path or a suffix lives
;; in the tail. The columns after it stay where the labels say they are.
;;
;; A column whose tail says nothing declares 'end instead, and loses the
;; end: a subject and a tag list both read from the left, and a middle
;; cut through a list of words invents a word that is not there.
(define (list-fit s w trim)
  (cond ((not w) s)
        ((<= (string-length s) w) s)
        ((<= w 3) (substring s 0 w))
        ;; a column that knows what its text IS shortens it itself: the
        ;; tags of a mail thread are words, and every word can lose its
        ;; end and still say which tag it is. The mechanism holds the
        ;; column to its width after the mode had its say.
        ((procedure? trim)
         (let ((out (trim s w)))
           (if (> (string-length out) w) (substring out 0 w) out)))
        ((equal? trim 'end) (string-append (substring s 0 (- w 1)) "…"))
        (else
          (let* ((keep (- w 1))
                 (head (quotient (+ keep 1) 2))
                 (tail (- keep head))
                 (n (string-length s)))
            (string-append (substring s 0 head) "…" (substring s (- n tail) n))))))

;; the padding of the last column is only blank space at the end of a line
(define (string-trim-right s)
  (let loop ((n (string-length s)))
    (if (and (> n 0) (equal? (substring s (- n 1) n) " "))
        (loop (- n 1))
        (substring s 0 n))))

(define (list-pad s w align)
  (cond ((not w) s)
        ((equal? align 'right) (string-pad-left s w))
        (else (string-pad-right s w))))

(define (list-col-width c) (car (cdr c)))
(define (list-col-align c) (if (> (length c) 2) (nth 2 c) 'left))

;; how the column gives up space: 'middle (the default), 'end, or a fn
;; the mode wrote
(define (list-col-trim c) (if (> (length c) 3) (nth 3 c) 'middle))

;; how wide the table is: the rule and the right-hand chip measure
;; themselves against it, so nothing has to ask the window
;; one row of cells as text plus the faces on it. A span is (OFFSET
;; LENGTH FACE) inside the line, in bytes, so the writer below is the
;; only place that counts absolute offsets.
(define (list-lay-out cells cols &optional fields?)
  (let loop ((cs cells) (ks cols) (text "") (spans '()) (fields '()))
    (if (or (null? cs) (null? ks))
        (if fields? (list text (reverse spans) (reverse fields))
                    (list text (reverse spans)))
        (let* ((k (car ks))
               (fitted (list-fit (list-cell-text (car cs)) (list-col-width k)
                                 (list-col-trim k)))
               ;; the last column is not padded, so the line ends where
               ;; its text ends; a right-aligned last column pads on the
               ;; left, so its text ends at the column's edge
               (align (list-col-align k))
               (padded (if (and (null? (cdr ks)) (not (equal? align 'right)))
                           fitted
                           (list-pad fitted (list-col-width k) align)))
               (face (list-cell-face (car cs)))
               ;; a right-aligned cell's text sits after its padding
               (start (+ (string-byte-length text)
                         (if (equal? align 'right)
                             (- (string-byte-length padded) (string-byte-length fitted))
                             0))))
          (loop (cdr cs) (cdr ks)
                (string-append text padded
                               (if (null? (cdr ks)) "" *list-gap*))
                (if face
                    (cons (list start (string-byte-length fitted) face) spans)
                    spans)
                (if fields? (cons (list start (string-byte-length fitted)) fields) fields))))))

(define (list-shift-spans spans n)
  (map (lambda (s) (list (+ (car s) n) (car (cdr s)) (nth 2 s))) spans))

(define (list-rule-line w) (list (string-repeat "─" w) (list (list 0 (* 3 w) "faint"))))

;; the narrowing, on the right of the title: what you typed and how many
;; rows it left. It shows only while the list is narrowed.
;; how many things this list is showing. A row you cannot mark is not a
;; thing the list holds — dired's ".." is a way out of the directory.
(define (list-count buf)
  (let ((f (list-opt buf 'markable?))
        (separator? (list-opt buf 'separator?))
        (es (list-entries buf)))
    (if (or f separator?)
        (length (filter (lambda (e) (list-markable? buf e)) es))
        (length es))))

;; the chip counts only while the list is narrowed: the count asks the
;; mode about every row, and a wide list of 400 rows paid 200ms per draw
;; to show nothing
(define (list-chip buf)
  (let ((fs (list-filters buf)))
    (if (null? fs)
        ""
        (let* ((n (list-count buf))
               (tf (list-opt buf 'total))
               (total (if tf (tf buf) n)))
          (string-append (list-filters-text buf) "   "
                         (number->string n) " of " (number->string total))))))

;; what you typed reads back as you typed it; a kind the mode invented
;; says its name
(define (list-filters-text buf)
  (string-join (map (lambda (f)
                      (if (equal? (car f) "match")
                          (string-append "/" (car (cdr f)))
                          (string-append (car f) ":" (car (cdr f)))))
                    (reverse (list-filters buf)))
               " "))

(define (list-title-line buf w)
  (let* ((title (list-say buf 'title))
         (chip (list-chip buf)))
    (if (equal? chip "")
        (list title '())
        (let* ((gap (max 1 (- w (string-length title) (string-length chip))))
               (text (string-append title (string-repeat " " gap) chip)))
          ;; the chip shows only while the list is narrowed, and it wears
          ;; the same colour as the note under it: one colour says "you
          ;; are not seeing everything"
          (list text
                (list (list (- (string-byte-length text) (string-byte-length chip))
                            (string-byte-length chip) "warn")))))))

(define (list-label-line buf cols)
  (let* ((labels (map (lambda (c) (list (string-upcase (car c)) "faint")) cols))
         (laid (list-lay-out labels cols)))
    (list (string-trim-right (string-append "  " (car laid)))
          (list-shift-spans (car (cdr laid)) 2))))

;; A narrowed list looks exactly like a short list, and the mode's own
;; meta counts the rows it can see — "2 buffers" when the editor holds
;; fourteen. So the narrowing says itself here, in the sentence under the
;; title, and it says how to leave.
(define (list-meta-line buf)
  (let* ((said (list-say buf 'meta))
         ;; a mode's meta is a string, or the text and its own spans
         (meta (if (pair? said) (car said) said))
         (own-spans (if (pair? said) (cadr said) #f))
         (meta (if (list-more? buf)
                   (string-append meta (if (equal? meta "") "" " · ")
                                  (number->string (list-shown-count buf)) " of "
                                  (number->string (length (list-entries buf)))
                                  " shown, PgDn draws more")
                   meta))
         (note (if (null? (list-filters buf))
                   ""
                   (string-append "narrowed to " (list-filters-text buf)
                                  " — \\ widens")))
         (text (cond ((equal? note "") meta)
                     ((equal? meta "") note)
                     (else (string-append meta "   ·   " note)))))
    (list text
          (append (cond ((equal? meta "") '())
                        (own-spans own-spans)
                        (else (list (list 0 (string-byte-length meta) "dim"))))
                  (if (equal? note "")
                      '()
                      (list (list (- (string-byte-length text)
                                     (string-byte-length note))
                                  (string-byte-length note) "warn")))))))

;; one label per column says nothing about a row of two lines: the row
;; itself is the only place the two meet, so a two-line list shows none
;; A list that names none of its columns shows no label row: the row
;; itself says what it is, and a bar of blanks is one more line of chrome
;; over the rows.
(define (list-labelled? cols)
  (pair? (filter (lambda (c) (not (equal? (car c) ""))) cols)))

(define (list-label-lines buf cols)
  (if (or (> (list-row-height buf) 1) (not (list-labelled? cols)))
      '()
      (list (list-label-line buf cols))))

(define (list-table-head buf)
  (let* ((cols (list-columns buf))
         (w (list-view-width buf))
         (meta (list-meta-line buf)))
    (if (list-opt buf 'compact)
        (if (and (null? (list-filters buf))
                 (not (equal? (car meta) "")))
            ;; the meta's spans ride along, shifted past the title;
            ;; a line the width trimmed loses them, as the offsets moved
            (append (let* ((title (list-say buf 'title))
                           (text (string-append title "  " (car meta)))
                           (fitted (list-fit text w 'middle)))
                      (list (list fitted
                                  (if (equal? fitted text)
                                      (list-shift-spans (cadr meta)
                                                        (+ (string-byte-length title) 2))
                                      '()))))
                    (list-label-lines buf cols))
            (append (list (list-title-line buf w))
                    (if (equal? (car meta) "") '() (list meta))
                    (list-label-lines buf cols)))
        (append (list (list-title-line buf w))
                (if (equal? (car meta) "") '() (list meta))
                (list (list-rule-line w))
                (list-label-lines buf cols)))))

;; the header as lines. A mode's own 'header is text it wrote itself, so
;; its lines carry no faces, and it replaces the table's head. A 'panel is
;; text too, but it goes above the table's head and keeps it.
(define (list-head-lines buf)
  (let ((f (list-opt buf 'header)))
    (cond (f (list-text-lines (f buf)))
          ((list-table? buf) (append (list-panel-lines buf) (list-table-head buf)))
          (else (list (list "" '()))))))

(define (list-text-lines text) (map (lambda (l) (list l '())) (string-split text "\n")))

(define (list-panel-lines buf)
  (let ((f (list-opt buf 'panel)))
    (if f (list-text-lines (f buf)) '())))

;;; --- the keys card -------------------------------------------------------
;;; The keymap every list-mode buffer carries (docs/DESIGN-PORT.md, stage
;;; 4): a small card floating inside the window at its bottom corner, over
;;; the rows. One line: the main keys the mode declared as its footer, and
;;; `? all N`. `?` grows the card into the whole map, a grid per keymap,
;;; key then verb, read down the columns like describe-keymap; the rows
;;; underneath keep the point. The ui/keys-bar component (components.scm)
;;; draws it; this decides what it holds.

;; the whole map of a list buffer, a grid per keymap: the mode's own map
;; first, then every list's map, a key the mode shadows shown once. Each
;; grid is (TITLE ((KEY COMMAND) ...)).
(define (list-keys-grids buf)
  (if (not (boundp 'keys--expand))
      '()
      (let* ((mode (list-mode-of buf))
             (own (if mode (keys--expand (mode-keymap mode) "" '()) '()))
             (shared (keys--expand "list-mode-map" "" '()))
             (seen (map car own))
             (rest (filter (lambda (e) (not (member (car e) seen))) shared))
             (row (lambda (e) (list (car e) (cadr e)))))
        (append
          (if (pair? own) (list (list (dashboard--mode-name mode) (map row own))) '())
          (if (pair? rest) (list (list "list" (map row rest))) '())))))

;; the card as blocks: #f when the mode declared no footer
(define (list-keys-bar-blocks buf)
  (let ((footer (list-opt buf 'footer)))
    (and footer
         (boundp 'component)
         (list (component 'ui/keys-bar
                 ;; the bar owns ?: a mode that lists it says it twice
                 (list 'main (filter (lambda (k) (not (equal? (car k) "?"))) (footer buf))
                       'grids (list-keys-grids buf)
                       'expanded (if (buffer-local buf 'list-keys-expanded) #t #f)))))))

(define-command "list-keys-toggle"
  "Grow this list's keys card into the whole keymap, or fold it back"
  (lambda ()
    (let* ((buf (current-buffer))
           (now (not (buffer-local buf 'list-keys-expanded))))
      (desktop-skip! buf 'list-keys-expanded)
      (buffer-set-local! buf 'list-keys-expanded now)
      (let ((blocks (list-keys-bar-blocks buf)))
        (when blocks (buffer-set-local! buf 'footer-line-blocks blocks)))
      (message (if now "all keys — ? folds them" "main keys")))))

;; one entry's cells, one list per line of the row
(define (list-row-cells buf e &optional ctx)
  (let ((g (if ctx (list-ctx-row-cells ctx) (list-opt buf 'row-cells)))
        (f (if ctx (list-ctx-cells ctx) (list-opt buf 'cells))))
    (cond (g (g buf e))
          (f (list (f buf e)))
          (else '()))))

;; CTX is the answers every row of one draw shares: the mark column,
;; the column lines, the mode's cells, row-cells, render, and key fns,
;; and the marks. One draw computes it once. Each answer reads the
;; buffer or resolves the layout profile, and a buffer read is a call
;; into the buffer's process: a row that asked ten times cost 6ms, and
;; a draw of 400 rows took seconds.
(define (list-row-ctx buf)
  (list (list-marks-column? buf) (list-column-lines buf)
        (list-opt buf 'cells) (list-opt buf 'row-cells) (list-opt buf 'render)
        (list-marks buf) (list-opt buf 'key)
        (list-opt buf 'match) (list-opt buf 'filter)))

(define (list-ctx-marks? ctx) (car ctx))
(define (list-ctx-column-lines ctx) (nth 1 ctx))
(define (list-ctx-cells ctx) (nth 2 ctx))
(define (list-ctx-row-cells ctx) (nth 3 ctx))
(define (list-ctx-render ctx) (nth 4 ctx))
(define (list-ctx-marks ctx) (nth 5 ctx))
(define (list-ctx-key ctx) (nth 6 ctx))

;; one entry as its lines. The mark column belongs to the mechanism:
;; three renders were each prepending their own. The mark goes on the
;; first line, and the lines under it start where it does.

(define (list-row-lines buf e &optional ctx cells laid)
  ;; LAID is the first line's layout, already worked out by the caller.
  ;; The composml pass needs the same layout to place its field ranges, so
  ;; a draw that did not share it laid every row out twice.
  (let* ((ctx (or ctx (list-row-ctx buf)))
         (marks? (list-ctx-marks? ctx))
         (column-lines (list-ctx-column-lines ctx))
         (mark (if marks? (list-mark-of buf e ctx) "")))
    (if (pair? column-lines)
        (let* ((head (string-append mark " "))
               (blank (string-repeat " " (string-length head))))
          (let loop ((cs (or cells (list-row-cells buf e ctx)))
                     (ks column-lines)
                     (first? #t)
                     (out '()))
            (if (or (null? cs) (null? ks))
                (reverse out)
                (let* ((laid (if (and first? laid) laid (list-lay-out (car cs) (car ks))))
                       (pre (if first? head blank))
                       (n (string-byte-length pre)))
                  (loop (cdr cs) (cdr ks) #f
                        (cons (list (string-trim-right (string-append pre (car laid)))
                                    (append (if (or (not first?) (equal? mark " ") (equal? mark ""))
                                                '()
                                                (list (list 0 (string-byte-length mark) "alert")))
                                            (list-shift-spans (car (cdr laid)) n)))
                              out))))))
        (let ((template (list-text-template buf)))
          (list (list (string-append mark
            (if template
                (car (list-format-template (template buf e) (list-pretty? buf)))
                ((list-ctx-render ctx) buf e))) '()))))))

;; the whole view, top to bottom
;; the view: the header, then the rows. The key bar is in the header,
;; under the counts, where the eye lands on an open: at the foot of the
;; text it scrolled away with the rows.
(define (list-view-lines buf rows &optional head prepared)
  (let ((ctx (list-row-ctx buf)))
    (append (or head (list-head-lines buf))
            (apply append
              (if prepared (map cadr prepared)
                  (map (lambda (e) (list-row-lines buf e ctx)) rows))))))

;; write the lines, answer their overlays, and leave every row's byte
;; offset on the buffer — motion and the mode's own overlays then read
;; the same numbers the text has. The text goes in as ONE replace of the
;; whole buffer: a delete and then an append let a render in between
;; see an empty buffer, reset the window's top, and write it back, and
;; the view jumped. The offsets, the head count, and the row height go
;; in as one change too, with the locals the caller adds: every change
;; is a frame refresh and a render, and a draw of twelve changes was
;; twelve of each.
;;; A draw writes only what changed. Every buffer change is a frame
;;; refresh and a render, and a whole-text rewrite is a delete and an
;;; insert: the render between the two sees an empty table. A live list
;;; redraws while its rows hold still -- an age column ticks over, a
;;; token count grows -- so the lines that differ are two of thirty.
;;; Write that run. When the line count itself moves, one whole write
;;; still answers.
(define (list-lines-shared a b)
  (let loop ((x a) (y b) (n 0))
    (if (and (pair? x) (pair? y) (equal? (car x) (car y)))
        (loop (cdr x) (cdr y) (+ n 1))
        n)))

;; the bytes the lines [FROM, TO) hold, each with its newline
(define (list-lines-bytes lines from to)
  (let loop ((ls lines) (i 0) (n 0))
    (cond ((null? ls) n)
          ((and (>= i from) (< i to))
           (loop (cdr ls) (+ i 1) (+ n (string-byte-length (car ls)) 1)))
          (else (loop (cdr ls) (+ i 1) n)))))

(define (list-lines-join lines from to)
  (let loop ((ls lines) (i 0) (acc '()))
    (cond ((null? ls) (string-join (reverse acc) "\n"))
          ((and (>= i from) (< i to))
           (loop (cdr ls) (+ i 1) (cons (car ls) acc)))
          (else (loop (cdr ls) (+ i 1) acc)))))

(define (list-write-text! buf text)
  (let ((old (buffer-text buf)))
    (unless (equal? old text)
      (let* ((a (string-split old "\n"))
             (b (string-split text "\n"))
             (n (length a)))
        (if (= n (length b))
            (let* ((p (list-lines-shared a b))
                   (s (min (- n p) (list-lines-shared (reverse a) (reverse b))))
                   (start (list-lines-bytes a 0 p))
                   (stop (- (buffer-size buf) (list-lines-bytes a (- n s) n))))
              (buffer-replace-range! buf start (- stop start)
                                     (list-lines-join b p (- n s))))
            (buffer-replace-range! buf 0 (buffer-size buf) text))))))

;;; A local that holds its value is not a change: writing it again is a
;;; refresh and a render for nothing.
(define (list-set-locals! buf plist)
  (let loop ((p plist) (fresh '()))
    (cond ((or (null? p) (null? (cdr p)))
           (unless (null? fresh) (buffer-set-locals! buf fresh)))
          ((equal? (buffer-local buf (car p)) (cadr p)) (loop (cddr p) fresh))
          (else (loop (cddr p) (cons (car p) (cons (cadr p) fresh)))))))

(define (list-write! buf lines first-row n-rows per &optional extra-locals)
  (let loop ((ls lines) (i 0) (off 0) (ovs '()) (offsets '()) (texts '()))
    (if (null? ls)
        (begin (list-write-text! buf (string-join (reverse texts) ""))
               (list-set-locals! buf
                 (append (list 'list-offsets (reverse offsets)
                               'list-head-count first-row
                               'list-row-height per)
                         (or extra-locals '())))
               (reverse ovs))
        (let ((text (car (car ls)))
              (spans (car (cdr (car ls)))))
          (loop (cdr ls) (+ i 1)
                (+ off (string-byte-length text) 1)
                (fold (lambda (acc s)
                        (cons (list (+ off (car s))
                                    (+ off (car s) (car (cdr s)))
                                    (nth 2 s))
                              acc))
                      ovs spans)
                ;; one offset per row: a row of two lines answers with
                ;; the line the reader lands on
                (if (and (>= i first-row) (< i (+ first-row (* n-rows per)))
                         (= 0 (modulo (- i first-row) per)))
                    (cons off offsets)
                    offsets)
                (cons (string-append text "\n") texts))))))

;;; --- where point is, in rows ---------------------------------------------------

(define (list-offsets buf) (or (buffer-local buf 'list-offsets) '()))

;; the header count comes off the buffer, not out of a fresh header: the
;; header names the row count, and asking it to count rows that a refresh
;; is halfway through replacing reads the rows that went
(define (list-index buf)
  (let ((ln (line-index-at buf (or (buffer-local buf 'list-head-count)
                                   (list-header-lines buf)))))
    (and ln (quotient ln (list-drawn-row-height buf)))))

(define (list-goto-index! buf i)
  (let ((offs (list-offsets buf)))
    (when (and (>= i 0) (< i (length offs)))
      (let ((p (nth i offs))
            (shown (filter (lambda (w) (equal? (cadr w) buf)) (window-list-all))))
        (if (equal? (current-buffer) buf)
            (goto-char! p)
            (begin
              (buffer-goto! buf p)
              ;; a prompt can move the list from outside: the windows
              ;; showing it keep their own point, and the client keeps each
              ;; window's point line in view, so the row follows on screen
              (for-each (lambda (w) (window-set-point! (car w) p)) shown)))
        ;; the client's own follow scroll reports back and pins the window,
        ;; and only a key IN that window unpins it. Under a prompt the keys
        ;; go to the minibuffer, so a move unpins the windows here.
        (when (pair? shown) (buffer-windows-follow-point! buf))
        (list-update-selection! buf)))))

(define (list-first-selectable-index buf)
  (let loop ((es (list-entries buf)) (i 0))
    (cond ((null? es) #f)
          ((list-selectable? buf (car es)) i)
          (else (loop (cdr es) (+ i 1))))))

(define (list-nearest-selectable-index buf from)
  (let* ((es (list-entries buf))
         (n (length es)))
    (if (= n 0)
        #f
        (let ((start (max 0 (min (- n 1) from))))
          (let forward ((i start))
            (cond ((>= i n)
                   (let backward ((j (- start 1)))
                     (cond ((< j 0) #f)
                           ((list-selectable? buf (nth j es)) j)
                           (else (backward (- j 1))))))
                  ((list-selectable? buf (nth i es)) i)
                  (else (forward (+ i 1)))))))))

(define (list-step-selectable-index buf from step)
  (let* ((es (list-entries buf))
         (n (length es)))
    (let loop ((i (+ from step)))
      (cond ((or (< i 0) (>= i n)) from)
            ((list-selectable? buf (nth i es)) i)
            (else (loop (+ i step)))))))

;; Point is the live selection. Keep its row key as durable state, and paint
;; the complete row when the mode asks for a selection face. A row can use
;; more than one line, so the overlay follows the rendered row height.
(define (list-update-selection! buf)
  (let* ((i (list-clamped-index buf))
         (entries (list-entries buf))
         (offsets (list-offsets buf))
         (face (list-opt buf 'selection-face)))
    (if (and i (< i (length entries)) (< i (length offsets)))
        (let* ((entry (nth i entries))
               (start (nth i offsets))
               ;; Selection uses the geometry already written. Re-rendering
               ;; a row here did expensive cell work on every cursor move.
               ;; 'selection-trim leaves a row's trailing spacer bytes unlit
               (end (- (if (< (+ i 1) (length offsets))
                           (nth (+ i 1) offsets) (buffer-size buf))
                       (or (list-opt buf 'selection-trim) 0))))
          ;; the key is a change, and a change is a refresh: write it
          ;; only when the selection moved
          (let ((key (list-key buf entry)))
            (unless (equal? key (buffer-local buf 'list-selection-key))
              (buffer-set-local! buf 'list-selection-key key)))
          (if face
              (overlay-set! buf 'list-selection
                (list (list start end face)))
              (overlay-clear! buf 'list-selection)))
        ;; Keep the saved key when rows are temporarily empty. An async reload
        ;; can use it when the rows arrive again.
        (overlay-clear! buf 'list-selection))))

;; the row point sits on, clamped into the rows: below the last one is
;; the key bar, and a list where point can leave the rows has no row at
;; point to act on
(define (list-clamped-index buf)
  (let ((n (length (list-entries buf)))
        (i (list-index buf)))
    (cond ((= n 0) #f)
          ((not i) 0)
          ((>= i n) (- n 1))
          (else i))))

;; the client re-measures its windows after every patch. When one of them
;; changes width, the tables ON SCREEN lay themselves out again — this is
;; the window-configuration change hook, and a visible list is what
;; listens. A hidden list has no width of its own (it would lay out for
;; the active window), and the width check in list-post-command! re-lays
;; it the moment a window shows it.
(define (window-config-changed!)
  (for-each (lambda (w) (list-post-command! (cadr w))) (window-list)))

;; Point never rests in the chrome. A header line and a key bar are not
;; rows, and a verb acts on the row at point — so a click on the key bar
;; made `k` say "killed 0 buffers" and RET say "no buffer here", again
;; and again, because nothing moved point back. The nearest row takes
;; point, and the reader SEES what the next key acts on.
(define (list-snap-point! buf)
  (let ((n (length (list-entries buf))))
    (when (> n 0)
      (let ((i (list-index buf)))
        (let ((target (list-nearest-selectable-index
                        buf (cond ((not i) 0)
                                  ((>= i n) (- n 1))
                                  (else i)))))
          (when target (list-goto-index! buf target)))))))

(define (list-restamp! buf)
  (let ((f (list-opt buf 'stamp)))
    (when f
      (unless (equal? (f buf) (buffer-local buf 'list-stamp))
        (list-refresh! buf)))))

;; a table lays out in characters, so a window that changed width means a
;; re-render — of the rows the list already has. A resize never needs new
;; data, so it must not call the source (the network, for sentry); only
;; `g` and the mode's own verbs fetch. After a command is the other
;; moment the width can have moved.
(define (list-post-command! buf)
  (when (list-mode-of buf)
    (when (list-table? buf)
      (let ((w (list-view-width buf)))
        (unless (equal? w (buffer-local buf 'list-width))
          (buffer-set-local! buf 'list-width w)
          (list-render! buf 'cached))))
    (list-restamp! buf)
    (list-snap-point! buf)
    (list-update-selection! buf)))

(define (list-preview! buf)
  (let ((f (list-opt buf 'preview))
        (e (list-current buf)))
    (when (and f e) (f buf e))))

;; the mover may not be in the list: the filter prompt is the current
;; buffer while its arrows move the rows of the list behind it
(define (list-move-in! buf step)
  (let ((i (list-clamped-index buf)))
    (when i
      (let ((target (list-step-selectable-index buf i step)))
        ;; A skipped heading can put the target on the next page.
        (when (> step 0) (list-ensure-shown! buf target))
        (list-goto-index! buf target)
        (list-preview! buf)))))

(define (list-move! step) (list-move-in! (current-buffer) step))

(domain! 'interaction)
(effects! '(read))

(define-command "list-next" "Move to the next row of this list"
  (lambda () (list-move! 1)))

(define-command "list-prev" "Move to the previous row of this list"
  (lambda () (list-move! -1)))

;; a screen down in a paged list: the rows the screen lands on are drawn
;; first, so the page never ends in the key bar with more rows to come
(define-command "list-page-down" "Move a screen down this list; a paged list draws its next page"
  (lambda ()
    (let* ((buf (current-buffer))
           (i (or (list-clamped-index buf) 0)))
      (list-ensure-shown! buf (+ i (window-rows)))
      (move-lines (- (window-rows) 2) next-line!)
      (list-snap-point! buf))))

(domain! 'unknown)
(effects! '(unknown))

;; the first entry's byte offset — the header may be several lines
(define (list-first-entry-pos buf)
  (+ (string-byte-length (list-header-text buf)) 1))

;; a narrow makes the old line meaningless: land on the first row. The
;; filter prompt calls this while the minibuffer is current, so it moves
;; the list's own point rather than the current buffer's.
(define (list-goto-first-entry buf)
  (if (pair? (list-offsets buf))
      (let ((i (list-first-selectable-index buf)))
        (when i (list-goto-index! buf i)))
      (let ((p (min (list-first-entry-pos buf) (buffer-size buf))))
        (if (equal? (current-buffer) buf)
            (goto-char! p)
            (buffer-goto! buf p)))))

(define (list-set-filters! buf fs)
  (buffer-set-local! buf 'list-filters fs)
  (list-refresh! buf)
  (list-goto-first-entry buf))

(domain! 'interaction)
(effects! '(write))

;;; The filter prompt has no candidates of its own: the ROWS are the
;;; candidates, and they live in the list behind the prompt. So the
;;; arrows move the highlight in that list while you type, and RET closes
;;; the prompt on the row you chose. You type, and then you select.
(define *mb-list-buffer* #f)
(define *list-filter-prompt* "Filter: ")
;; the label of the prompt that stands in front of *mb-list-buffer*: the
;; filter's own, or the one a table's prompt form chose
(define *mb-list-prompt* #f)
(define *mb-list-flush* #f)

;; #t means the arrows moved a list. #f means no list stands behind this
;; prompt, so the minibuffer keeps its own arrows. The prompt line is the
;; proof: a prompt can also close behind Scheme's back, and a stale list
;; must never steal the arrows from the next palette.
(define (mb-list-target)
  (let ((buf *mb-list-buffer*)
        (mb (minibuffer-state)))
    (and buf mb (buffer-exists? buf)
         (equal? (plist-get mb 'prompt) (or *mb-list-prompt* *list-filter-prompt*))
         buf)))

(define (mb-list-move! step)
  (let ((buf (mb-list-target)))
    (if buf
        (begin
          (when *mb-list-flush* (*mb-list-flush*))
          (with-invoking-buffer (lambda () (list-move-in! buf step))) #t)
        #f)))

;; The prompt in front of a list drives that list. Each of these answers
;; #t when a list stood behind the prompt and took the key, so the
;; minibuffer's own meaning for the key stays the fallback. What the key
;; MEANS is the list mode's: 'fold and 'regroup are fns of the buffer.
(define (mb-list-call! key)
  (let ((buf (mb-list-target)))
    (and buf
         (let ((f (list-opt buf key)))
           (and f (begin (with-invoking-buffer (lambda () (f buf))) #t))))))

;; the index of the next row that starts a section, walking STEP from
;; the row at point; #f when there is none that way
(define (list-section-index buf from step)
  (let* ((es (list-entries buf))
         (n (length es)))
    (let loop ((i (+ from step)))
      (cond ((or (< i 0) (>= i n)) #f)
            ((list-section-start? buf (nth i es)) i)
            (else (loop (+ i step)))))))

;; the index of the section the row at FROM belongs to: the nearest
;; section start at or above it, or #f above the first one
(define (list-section-here buf from)
  (let ((es (list-entries buf)))
    (let loop ((i from))
      (cond ((< i 0) #f)
            ((list-section-start? buf (nth i es)) i)
            (else (loop (- i 1)))))))

;; A section jump lands on the section's first ROW, not on its heading:
;; the jump is how you reach the rows over there, and RET must visit one.
;; A folded heading stands for its rows, so the jump rests on it.
;; Backwards means the section BEFORE this one, so the walk starts at
;; this section's own heading and not at the row you are on.
;;
;; The key belongs to the list whenever a list stands behind the prompt.
;; At the first section, backwards does nothing — it must not fall
;; through to the history and type a past answer into the filter.
(define (list-move-section! buf step)
  (let* ((i (list-clamped-index buf))
         (from (if (and i (< step 0)) (or (list-section-here buf i) i) i))
         (head (and from (list-section-index buf from step))))
    (when head
      (let* ((entries (list-entries buf))
             (target (if (list-selectable? buf (nth head entries))
                         head
                         (list-step-selectable-index buf head 1))))
        (list-ensure-shown! buf target)
        (list-goto-index! buf target)
        (list-preview! buf)))
    #t))

(define (mb-list-section! step)
  (let ((buf (mb-list-target)))
    (and buf (with-invoking-buffer (lambda () (list-move-section! buf step))))))

;; The narrowing is live, and the input IS it. The prompt opens holding
;; the query the list already has, so `/` edits the narrowing instead of
;; stacking a second one on top of it. Every keystroke narrows, every
;; DEL widens, and an empty input means no query at all. C-g closes
;; the entry while keeping its query; the filter-pop command removes it.
(define-command "list-filter"
  "Narrow this list to the rows that match what you type"
  (lambda ()
    (let* ((buf (current-buffer))
           (input (list-query buf))
           (delay (or (list-opt buf 'filter-delay-ms) 0))
           (key (string-append "list-filter:" (selected-frame)))
           (generation 0)
           (apply-query (lambda ()
                          (with-buffer-display-update buf
                            (lambda ()
                              (unless (equal? input (list-query buf))
                                (list-set-query! buf input)
                                (list-goto-first-entry buf))))))
           (flush (lambda ()
                    (set! generation (+ generation 1))
                    (debounce-cancel! key)
                    (apply-query)))
           (narrow (lambda (q)
                     (set! input q)
                     (set! generation (+ generation 1))
                     (if (= delay 0) (apply-query)
                         (let ((ticket generation))
                           (debounce! key delay
                             (lambda (ignored)
                               (when (and (= ticket generation)
                                          (equal? (mb-list-target) buf))
                                 (apply-query))) #f)))))
           (done (lambda ()
                   (flush)
                   (set! *mb-list-flush* #f)
                   (set! *mb-list-buffer* #f)
                   (set! *mb-list-prompt* #f))))
      (set! *mb-list-buffer* buf)
      (set! *mb-list-prompt* *list-filter-prompt*)
      (minibuffer-read* *list-filter-prompt* '()
        (list (list 'change narrow)
              (list 'confirm (lambda (q) (set! input q) (done)))
              (list 'cancel done)
              (list 'style "filter")))
      (set! *mb-list-flush* flush)
      (unless (equal? input "") (minibuffer-input! input)))))

(define (list-cycle-declared! option absent)
  (let* ((buf (current-buffer))
         (cycle (list-opt buf option)))
    (if cycle (cycle buf) (message absent))))

(define-command "list-cycle-grouping"
  "Cycle through the grouping mechanisms declared by this list"
  (lambda () (list-cycle-declared! 'regroup "this list has no grouping")))

(define-command "list-cycle-sorting"
  "Cycle through the sorting mechanisms declared by this list"
  (lambda () (list-cycle-declared! 'resort "this list has no sorting")))

(define-command "list-filter-pop" "Drop the most recent filter on this list"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (null? (list-filters buf))
          (message "no filter")
          (begin (list-filter-pop! buf)
                 (list-goto-first-entry buf))))))

(domain! 'unknown)
(effects! '(unknown))

;;; the refresh every one of them wrote by hand

;; a row may want colour, and colour is byte ranges — so the list tells
;; the row where its line landed rather than making the caller keep its
;; own running offset
(define (list-row-overlays buf rows)
  ;; The row context is what a draw already worked out once: the key
  ;; function and the marks. Asking a row whether it is marked without it
  ;; read the mode option and the marks local again, per row, so a page of
  ;; 60 paid 120 reads to answer "no" 60 times. The context is built here
  ;; and handed down.
  (let ((ovf (list-opt buf 'overlays))
        (ctx (list-row-ctx buf)))
    (if (not ovf)
        '()
        (let loop ((es rows) (offs (list-offsets buf)) (out '()))
          (if (or (null? es) (null? offs))
              (reverse out)
              (loop (cdr es) (cdr offs)
                    (append (reverse (ovf buf (car es) (car offs) ctx)) out)))))))

;; where a row went: a refresh may reorder the rows, and the reader stays
;; on the row rather than on its number
(define (list-index-of buf rows key)
  (let loop ((es rows) (i 0))
    (cond ((null? es) #f)
          ((equal? (list-key buf (car es)) key) i)
          (else (loop (cdr es) (+ i 1))))))

;;; --- pages -------------------------------------------------------------------
;;; A mode with many rows declares 'page-size N. The draw writes the first
;;; page; the reader who moves past its end gets the next page, and the
;;; header says how many rows the page holds of the whole. The entries
;;; keep every row, so the counts, the filters, and the marks see them
;;; all, and the drawn rows are a prefix of the entries, so an index means
;;; the same row in both.

(define (list-page-size buf) (list-opt buf 'page-size))

;; how many rows the next draw writes: the pages opened so far, or one
(define (list-page-limit buf)
  (let ((size (list-page-size buf)))
    (and size (max size (or (buffer-local buf 'list-page-limit) 0)))))

(define (list-page-rows buf rows)
  (let ((limit (list-page-limit buf)))
    (if (and limit (> (length rows) limit))
        (let loop ((rs rows) (k limit) (acc '()))
          (if (or (null? rs) (= k 0))
              (reverse acc)
              (loop (cdr rs) (- k 1) (cons (car rs) acc))))
        rows)))

(define (list-shown-count buf)
  (or (buffer-local buf 'list-shown-count) (length (list-entries buf))))

;; only a paged list has more: a mode without pages may set its own
;; entries after a draw, and the count of the last draw is not a page
(define (list-more? buf)
  (and (list-page-size buf)
       (< (list-shown-count buf) (length (list-entries buf)))))

;; draw enough pages to show row WANT (an index); nothing when it shows
(define (list-ensure-shown! buf want)
  (let ((size (list-page-size buf)))
    (when (and size (list-more? buf) (>= want (list-shown-count buf)))
      (let* ((total (length (list-entries buf)))
             (pages (+ 1 (quotient want size)))
             (limit (min total (* pages size))))
        (buffer-set-local! buf 'list-page-limit limit)
        (list-redraw! buf)))))

(define (list-more! buf)
  (list-ensure-shown! buf (list-shown-count buf)))

;; the row index at byte POS: the last row whose start is at or before it
(define (list-index-at-pos buf pos)
  (let loop ((offs (list-offsets buf)) (i 0) (best #f))
    (cond ((null? offs) best)
          ((<= (car offs) pos) (loop (cdr offs) (+ i 1) i))
          (else best))))

;; the row key at byte POS, or #f in the header
(define (list-key-at-pos buf pos)
  (let ((i (list-index-at-pos buf pos))
        (es (list-entries buf)))
    (and i (< i (length es)) (list-key buf (nth i es)))))

;; Every window showing BUF and the row its own point is on (Emacs
;; dired-save-positions). A window keeps its own point; the buffer's
;; point is only the selected window's. -> ((WIN KEY) ...)
(define (list-window-places buf)
  (fold (lambda (acc w)
          (if (equal? (cadr w) buf)
              (let ((p (window-point (car w))))
                (cons (list (car w) (and (number? p) (list-key-at-pos buf p))) acc))
              acc))
        '()
        (window-list-all)))

;; put each window back on its row after a rewrite (Emacs
;; dired-restore-positions). The rewrite clamped every stored window
;; point to 0; the buffer point alone reaches only the selected window.
(define (list-restore-window-places! buf places rows)
  (let ((offs (list-offsets buf))
        (last (- (list-shown-count buf) 1)))
    (for-each
      (lambda (place)
        (let ((i (and (cadr place) (list-index-of buf rows (cadr place)))))
          (when (and i (>= last 0))
            (let ((at (min i last)))
              (when (< at (length offs))
                (let ((p (nth at offs)))
                  ;; A refresh that left this row at the same byte left the
                  ;; window alone too. Re-setting it still makes the client
                  ;; follow point and repaint the window.
                  (unless (equal? (window-point (car place)) p)
                    (window-set-point! (car place) p))))))))
      places)))

;; Optional semantic projection of the same selectable rows. Text offsets stay
;; authoritative for commands, search, marks, and per-window selection.
;; Field boundaries come from the same layout operation that wrote the text.
(define (list-composml-fields buf row start &optional ctx fields cells laid)
  (let ((fields (or fields (list-opt buf 'composml-fields))))
    (if (not fields) '()
      (let* ((ctx (or ctx (list-row-ctx buf)))
             (prefix (+ (string-byte-length (if (list-ctx-marks? ctx) (list-mark-of buf row ctx) "")) 1))
             ;; the row was laid out once, when its lines were made
             (laid (or laid
                       (list-lay-out (car (or cells (list-row-cells buf row ctx)))
                                     (car (list-ctx-column-lines ctx)) #t))))
        (let loop ((ranges (nth 2 laid)) (descs (fields buf row)) (out '()))
          (if (or (null? ranges) (null? descs)) (reverse out)
            (let* ((r (car ranges)) (a (+ start prefix (car r))))
              (loop (cdr ranges) (cdr descs)
                (if (> (cadr r) 0) (cons (list a (+ a (cadr r)) (car descs)) out) out)))))))))

;; Template layout and semantic columns are shared by all list modes.
(define-style! 'list-template "
.semantic-direct.line {
  display: grid; grid-template-columns: none; grid-auto-columns: 1ch;
  column-gap: 0; align-items: baseline; white-space: nowrap;
}
.semantic-direct > [data-col] {
  grid-row: 1; grid-column: var(--field-column) / span var(--field-width);
  min-width: 0; white-space: pre; overflow: hidden;
}
")

(public! 'list-format-template
  "(list-format-template FIELDS PRETTY?) — format (TEXT CLASS WIDTH TRIM PREFIX) fields as text and relative UTF-8 ranges; WIDTH #f leaves text natural")
(define (list-format-template fields pretty?)
  (let loop ((rest fields) (at 0) (texts '()) (ranges '()))
    (if (null? rest) (list (string-join (reverse texts) "") (reverse ranges))
        (let* ((f (car rest)) (width (nth 2 f))
               (text (string-append (or (nth 4 f) "")
                       (if (and pretty? width)
                           (string-pad-right (list-fit (car f) width (or (nth 3 f) 'end)) width)
                           (car f))))
               (end (+ at (string-byte-length text))))
          (loop (cdr rest) end (cons text texts)
            (if (= at end) ranges
                (cons (list at end (list 'tag "span" 'class (cadr f))) ranges)))))))

(define (list-text-template buf)
  (let ((prepare (list-opt buf 'prepare-template)))
    (if prepare (prepare buf) (list-opt buf 'text-template))))

(define (list-pretty? buf)
  (let ((option (list-opt buf 'pretty)))
    (if (procedure? option) (option buf) option)))

(define (list-relative-fields buf row start ctx block)
  (let ((fields (plist-get block 'relative-fields)))
    (if (not fields) '()
        (let* ((prefix (if (list-ctx-marks? ctx)
                           (string-byte-length (list-mark-of buf row ctx)) 0))
               (base (+ start prefix)))
          (append
            (if (> prefix 0)
                (list (list start base (list 'tag "span" 'class "list-mark"))) '())
            (map (lambda (field)
                   (list (+ base (car field)) (+ base (cadr field)) (nth 2 field))) fields))))))

;; Semantic text records keep the existing text, faces and line geometry.
(define (list-composml-text! buf rows &optional prepared destination)
  (let ((record (or (list-opt buf 'composml-record)
                    (lambda (b row) (list 'tag "c-item"))))
        (root (or (list-opt buf 'composml-root)
                  (lambda (b) (list 'tag "c-list" 'attrs
                    (list (list "mode" (list-mode-of b))))))))
    (unless (list-opt buf 'composml)
      (desktop-skip! (or destination buf) 'render-text-root)
      (desktop-skip! (or destination buf) 'render-records)
      ;; the draw's own context and field fn, read once: a row that asked
      ;; for them itself cost this pass twice its time (docs/LISTS.md).
      (let* ((ctx (list-row-ctx buf))
             (fields (list-opt buf 'composml-fields))
             (key-of (list-ctx-key ctx)))
        (list-set-locals! (or destination buf)
          (list 'render-text-root (root buf)
                'render-records
                (let loop ((rs rows) (offsets (list-offsets buf)) (ps prepared) (out '()))
                  (if (or (null? rs) (null? offsets)) (reverse out)
                    (let* ((row (car rs)) (start (car offsets))
                           (size (fold (lambda (n ln) (+ n (string-byte-length (car ln)) 1))
                                       0 (if (pair? ps) (cadr (car ps)) (list-row-lines buf row ctx))))
                           (block (append
                                    (if (and (pair? ps) (> (length (car ps)) 3))
                                        (list 'relative-fields (nth 3 (car ps))
                                              'layout (if (nth 4 (car ps)) "columns" #f)) '())
                                    (record buf row))))
                      (loop (cdr rs) (cdr offsets) (and (pair? ps) (cdr ps))
                        (cons (list start (+ start size)
                                (append (list 'fields (if fields (list-composml-fields buf row start ctx fields
                                                                (and (pair? ps) (car (car ps)))
                                                                (and (pair? ps) (nth 2 (car ps))))
                                                (list-relative-fields buf row start ctx block))
                                              'attrs (append
                                (list (list "record-id" (let ((key (if key-of (key-of buf row) row)))
                                  (if (string? key) key (value->string key)))))
                                (or (plist-get block 'attrs) '()))) block)) out)))))))))))

(define (list-composml! buf rows head &optional destination)
  (let ((render (list-opt buf 'composml))
        (collection (list-opt buf 'collection)))
    (when (and render collection)
      (desktop-skip! (or destination buf) 'render-blocks)
      (desktop-skip! (or destination buf) 'render-root)
      (let ((per (list-row-height buf)) (first (length head)))
        (list-set-locals! (or destination buf)
          (list 'render-mode "blocks"
                'render-root (let ((root (list-opt buf 'composml-root)))
                               (if root (root buf) (list 'tag "c-buffer")))
                'render-blocks
                (list
                  (list 'tag "c-headerline" 'class "semantic-list-header"
                        ;; the head is text and its faces. A mode that wants
                        ;; its own head -- tabs as tabs, a title as a title --
                        ;; answers 'composml-head with blocks instead.
                        'children (let ((f (list-opt buf 'composml-head)))
                                    (if f
                                        (f buf head)
                                        (map (lambda (ln) (list 'tag "pre" 'text (car ln))) head))))
                  (list 'tag collection 'class "semantic-list"
                        'attrs '(("role" "list"))
                        'children
                        (let loop ((rest rows) (i 0) (out '()))
                          (if (null? rest) (reverse out)
                            (let* ((row (car rest))
                                   (key (list-key buf row))
                                   (block (render buf row))
                                   (start (+ first (* i per) 1)))
                              (loop (cdr rest) (+ i 1)
                                (cons
                                  (append
                                    (list 'class (string-append "semantic-item " (or (plist-get block 'class) ""))
                                          'anchor (string-append "list:" (url-encode key))
                                          'click (string-append "list:" key)
                                          'lines (list start (+ start per -1))
                                          'mark "selected"
                                          'attrs (append (list (list "record-id" key) (list "role" "listitem"))
                                                         (or (plist-get block 'attrs) '())))
                                    block)
                                  out)))))))))))))

(define (list-zip-prepared rows prepared)
  (if (null? rows) '()
      (cons (list (car rows) (car prepared))
            (list-zip-prepared (cdr rows) (cdr prepared)))))

(define *list-filter-row-cache* '())

(define (list-filter-row-forget! buf)
  (set! *list-filter-row-cache*
    (remove (lambda (entry) (equal? (car entry) buf)) *list-filter-row-cache*)))

;; During a narrowing burst the source is a snapshot. Reuse the previous
;; draw's rows when their layout/marks agree; widening computes missing rows.
;; Same-query redraws (such as fresh transcript hits) recompute their cells.
(define (list-prepare-rows! buf rows ctx fetch)
  (let* ((cache? (list-opt buf 'incremental-filter))
         (previous (and cache? (assoc buf *list-filter-row-cache*)))
         (q (list-query buf))
         (reuse? (and previous
                      (or (equal? fetch 'view)
                          (and (not fetch) (not (equal? q ""))
                               (not (equal? q (cadr previous)))))
                      (equal? ctx (caddr previous))))
         (old (if reuse? (nth 3 previous) '()))
         (template (list-text-template buf))
         (pretty? (and template (list-pretty? buf)))
         (ks (let ((cl (list-ctx-column-lines ctx))) (and (pair? cl) (car cl))))
         (prepared
           (map (lambda (row)
                  (let ((hit (assoc row old)))
                    (if (and hit (not template)) (cadr hit)
                        (if template
                            (let* ((spec (template buf row))
                                   (formatted (list-format-template spec pretty?))
                                   (mark (if (list-ctx-marks? ctx) (list-mark-of buf row ctx) "")))
                              (list '() (list (list (string-append mark (car formatted)) '()))
                                    #f (cadr formatted)
                                    #t))
                        ;; one layout per row, kept: the lines and the
                        ;; composml field ranges are two readings of it
                        (let* ((cells (list-row-cells buf row ctx))
                               (laid (and ks (list-lay-out (car cells) ks #t))))
                          (list cells (list-row-lines buf row ctx cells laid) laid))))))
                rows)))
    (when cache?
      (set! *list-filter-row-cache*
        (take
          (cons (list buf q ctx (list-zip-prepared rows prepared))
                (remove (lambda (entry) (equal? (car entry) buf)) *list-filter-row-cache*))
          32)))
    prepared))

(define (list-render! buf fetch)
  (let* ((before (list-current buf))
         (key (and before (list-key buf before))))
    (with-buffer-display-update buf (lambda () (list-render-content! buf fetch)))
    ;; Source changes and filtering can move the highlight without an arrow.
    ;; Preview the settled selection, using the same callback as row motion.
    (when (and (buffer-exists? buf)
               (or (equal? (window-buffer (active-window)) buf)
                   (equal? (mb-list-target) buf))
               (let ((after (list-current buf)))
                 (and after (not (equal? key (list-key buf after))))))
      (list-preview! buf))))

(define (list-render-content! buf fetch)
  (when (buffer-exists? buf)
    ;; the layout cache needs no reset here: it names the width it was
    ;; laid out for, and a new width misses it
    ;; a rewrite dumps point to 0 — keep the reader's place. The place is
    ;; the ROW the reader is on, not the byte and not the number: a
    ;; reflowed table moves every byte, and a most-recently-used list
    ;; reorders the rows under the cursor.
    (let* ((here (list-current buf))
           (selected-key (or (and here (list-key buf here))
                             (buffer-local buf 'list-selection-key)))
           (was (list-index buf))
           ;; each window's own row, before the rows move under it
           (places (list-window-places buf))
           ;; a 'follow-head list: the row on top before this draw, which a
           ;; reader who stays there follows to the new top
           (top-key (let ((es (list-entries buf)))
                      (and (list-opt buf 'follow-head) (pair? es) (list-key buf (car es)))))
           (following? (and (list-opt buf 'follow-head) (or (not was) (= was 0))))
           (filtered (list-render-rows! buf fetch))
           (order (list-opt buf 'order-filtered))
           (rows (if order (order buf filtered) filtered))
           (cur? (equal? (current-buffer) buf))
           ;; the buffer's own point: a refresh runs while another buffer
           ;; is current (a hook, a prompt), and that list keeps its place
           (p (buffer-point buf)))
      ;; The rewrite is a programmatic write: buffer-replace-range! bypasses
      ;; read-only on its own. The flag stays where it is. A flip off and
      ;; on reached the browser as two patches when a hook redrew the list
      ;; outside a command, and for the patch between them the read-only
      ;; buffer was editable: the client took the caret, lost its text
      ;; node on the second patch, and reported end-of-buffer as point.
      ;; a paged list draws the first page of its rows; the entries keep
      ;; every row, so the counts and the filters see them all
      (let* ((shown (list-page-rows buf rows)))
        ;; entries first: the header states the row count. The columns
        ;; lay out against the rows this draw writes: the cache clears
        ;; HERE, not before the fetch. Reading point asks the header how
        ;; many lines it has, and that laid the columns out while the
        ;; rows they must fit were still the last draw's. Every later
        ;; call in this draw reads the cache, so the mode's columns fn
        ;; still runs once. One change for the two, and none when the
        ;; rows this draw found are the rows the last one drew.
        (list-columns-forget! buf)
        (list-set-locals! buf
          (list 'list-entries rows
                'list-shown-count (length shown)))
        (let* (;; the header once: its lines and their count are one answer
               (head (list-head-lines buf))
               (stamp-fn (list-opt buf 'stamp))
               ;; the width and the stamp ride the write's own change: the
               ;; rows are now the rows this render shows, and the stamp
               ;; says so
               (extra (append
                        (if (list-table? buf)
                            (list 'list-width (list-view-width buf))
                            '())
                        (if stamp-fn (list 'list-stamp (stamp-fn buf)) '())))
               ;; Cells and laid-out lines belong to this draw. The semantic
               ;; projection reuses them instead of calling the row again.
               (ctx (list-row-ctx buf))
               (prepared (list-prepare-rows! buf shown ctx fetch))
               (base (list-write! buf (list-view-lines buf shown head prepared)
                                  (length head) (length shown)
                                  (list-row-height buf) extra)))
          ;; the tag's old ranges go with this set: one change, not a
          ;; clear and then a set
          (overlay-set! buf 'list (append base (list-row-overlays buf shown)))
          (list-composml! buf shown head)
          (list-composml-text! buf shown prepared)
          ;; the keys bar at the window's foot is the list's one keymap
          (desktop-skip! buf 'footer-line-blocks)
          (let ((blocks (list-keys-bar-blocks buf)))
            (unless (equal? blocks (buffer-local buf 'footer-line-blocks))
              (buffer-set-local! buf 'footer-line-blocks blocks)))))
      (let ((i (and selected-key (list-index-of buf rows selected-key)))
            (last (- (list-shown-count buf) 1)))
        ;; Restore the buffer's point without moving every window that
        ;; shows it. list-goto-index! deliberately propagates interactive
        ;; motion to those windows; a background refresh must preserve each
        ;; window's independent place instead.
        (let* ((at (cond ((and following? (pair? rows)) 0)
                         ((and i (pair? rows)) (min i last))
                         ((and was (pair? rows)) (min was last))
                         (else #f)))
               (q (if at
                      (nth at (list-offsets buf))
                      (min p (buffer-size buf)))))
          (unless (equal? (buffer-point buf) q)
            (if cur? (goto-char! q) (buffer-goto! buf q)))))
      (list-snap-point! buf)
      (list-update-selection! buf)
      ;; the windows that show this list, each on its own row again
      (list-restore-window-places! buf places rows)
      (when top-key (list-follow-head! buf places top-key)))))

;; A 'follow-head list is a stream, newest first, like tail -f turned
;; over. A window on the top row, or in the head, stays on top as rows
;; arrive: its point goes to the start, so the panel and the column titles
;; stay in sight. Any other window keeps its row, which the restore above
;; already did.
(define (list-follow-head! buf places top-key)
  (let ((following (filter (lambda (place) (or (not (cadr place)) (equal? (cadr place) top-key)))
                           places))
        (active (active-window)))
    (for-each (lambda (place)
                (unless (equal? (window-point (car place)) 0)
                  (window-set-point! (car place) 0)))
              following)
    ;; the buffer's point is the selected window's: it follows too, unless
    ;; the reader is in this list on a row of their own. Left behind, it
    ;; reaches the other windows on the next redraw.
    (when (or (not (equal? (window-buffer active) buf))
              (pair? (filter (lambda (place) (equal? (car place) active)) following)))
      (unless (equal? (buffer-point buf) 0) (buffer-goto! buf 0)))))

;; `g` and every source change fetch again; a filter keystroke only
;; redraws, and a 'local-filter list then reuses its cached source.
(define (list-refresh! buf) (list-render! buf #t))
(define (list-redraw! buf) (list-render! buf #f))

;; the `g` every list answers: a cached list fetches its source again,
;; a plain one re-reads its rows; a mode's own `g` shadows this one
(define-command "list-revert" "Fetch this list's rows again and redraw"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (buffer-local buf 'cache-spec)
          (cache-refresh! buf)
          (list-refresh! buf)))))

;;; --- a list mode: declared once, rebuilt from its locals ------------------------
;; a caller that refreshes right after entering the mode (ibuffer-open!)
;; must not have list-mode-init! draw first: that draw is thrown away
;; unread, and on a table of hundreds of rows it is not cheap to throw away
(define *list-mode-skip-render* #f)

(define (with-list-mode-skip-render thunk)
  (let ((was *list-mode-skip-render*))
    (set! *list-mode-skip-render* #t)
    (let ((r (thunk)))
      (set! *list-mode-skip-render* was)
      r)))

;; Everything a list buffer needs to BE one, applied to an explicit
;; buffer. The mode setup calls it with (current-buffer); opening a list
;; calls it with the buffer it just made, so neither has to select first.
(define (list-mode-init! buf name)
  (let ((opts (list-mode-opts name))
        (widened #f))
    (buffer-set-local! buf 'list-mode name)
    (desktop-skip! buf 'list-layout-cache)
    (buffer-set-local! buf 'list-layout-cache #f)
    ;; whether this list is a view is the MODE's answer now (its parent is
    ;; special-mode unless the list declared 'special #f), so nothing is
    ;; written here. What the desktop keeps is a separate question,
    ;; answered by desktop-skip! above.
    ;; the stamp names the rows of one render — a restart draws new ones
    (desktop-skip! buf 'list-stamp)
    ;; A list opens WIDE. The typed narrowing answers a question you asked
    ;; THIS time; a local persists, so C-x C-b days later opened on a
    ;; three-row list narrowed by a word you no longer remember typing.
    ;; The mode's own kinds (dired's dotfiles) are a setting, and stay.
    ;; ...but a WAKE is not an open. Clearing the query there would leave
    ;; the buffer holding the rows a narrowing kept with no query to
    ;; explain them, and redrawing them from the source is the fetch a
    ;; preview must not pay.
    (unless *buffer-waking*
      (set! widened (list-clear-query! buf))
      ;; an open shows the first page; the pages you drew were for the
      ;; question you asked last time
      (buffer-set-local! buf 'list-page-limit #f))
    (desktop-skip! buf 'list-shown-count)
    ;; a list buffer's text IS its view. A buffer keeps the locals of the
    ;; mode before it, so dired on a directory that once held a diff kept
    ;; 'render-mode "blocks" and the window drew no rows at all.
    (buffer-set-local! buf 'render-mode #f)
    (buffer-set-local! buf 'render-text-root #f)
    (buffer-set-local! buf 'render-records #f)
    ;; the keys are the mode's map, under list-mode-map (define-list-mode!);
    ;; a layout profile's own flags are buffer state and bind here
    (list-install-mark-keys! buf)
    ;; a table moves the same way in every list: the line-motion keys
    ;; REMAP, so the arrows and C-n/C-p walk the rows and stop at the ends
    (when (list-table? buf)
      (local-remap*! buf "next-line" "list-next")
      (local-remap*! buf "previous-line" "list-prev")
      (local-remap*! buf "scroll-up-command" "list-page-down"))
    (for-each (lambda (r) (local-remap*! buf (car r) (car (cdr r))))
              (or (plist-get opts 'remap) '()))
    (buffer-set-read-only! buf #t)
    ;; A wake must not pay the source fetch: the buffer switcher previews
    ;; dormant buffers by re-running this setup, and a list whose rows come
    ;; from the network (sentry) froze the UI for the round trip — then
    ;; went back to sleep. 'cached renders the rows already in the buffer
    ;; and reaches the source only when there are none; `g` refetches.
    ;; ...unless the clear above just widened the list. The rows in the
    ;; buffer are the ones a narrowing kept, so drawing them back would
    ;; open the list on a query it no longer holds: the filters read
    ;; empty and the rows stay narrow, for good. A dired listing that
    ;; matched one file kept showing that file every time it re-opened.
    (unless *list-mode-skip-render*
      (list-render! buf (if widened #t 'cached)))
    ;; list-render! restores the selected row by key. It moves a new list to
    ;; its first row, but it does not reset an existing list during reload.
    ;; a list that declares an off-lane source refreshes through the
    ;; buffer cache: the wake above drew what it had, and new rows land
    ;; when the fetch answers. 'rows keeps serving the cached entries.
    (let ((cf (plist-get opts 'cache-fetch)))
      (when cf
        (cache-declare! buf cf
          (lambda (b rows)
            (buffer-set-local! b 'list-entries rows)
            (list-render! b 'cached))
          (plist-get opts 'cache-ttl))
        (cache-wake! buf)))))

(define (define-list-mode! name opts)
  (set! *list-modes* (alist-put *list-modes* name opts))
  ;; the list says what it is once, here — describe-mode reads it back
  (let ((d (plist-get opts 'doc)))
    (when d (mode-doc! name d)))
  ;; a real mode: a restored list buffer gets its keys and its read-only
  ;; flag back from here, not from whatever command first opened it
  (define-mode name (lambda () (list-mode-init! (current-buffer) name)))
  ;; Emacs derives tabulated-list-mode from special-mode. A generated list
  ;; is a view unless it says otherwise, and it says so once, here, as its
  ;; parent -- not as a local on every buffer the mode makes.
  (mode-parent! name (if (if (member 'special opts) (plist-get opts 'special) #t)
                         "special-mode"
                         "list-mode"))
  ;; the list's keys: its own on its map, every list's under it
  (keymap-parent! (mode-keymap name) "list-mode-map")
  (mode-keys! name (or (plist-get opts 'keys) '()))
  (list-flag-keys! (lambda (k c) (define-key (mode-keymap name) k c))
                   (or (plist-get opts 'flags) '()))
  (list-mode-standard-keys! name)
  name)

;; open (or re-open) a list buffer in its mode
(define (list-mode-show! name)
  (let ((buf (plist-get (list-mode-opts name) 'buffer)))
    (buffer-create buf)
    ;; an explicit open asks for current rows; a wake does not. The init
    ;; below redraws cached entries when there are any, so fetch here in
    ;; that case — the one place the user chose to look.
    (let ((cached? (pair? (buffer-local buf 'list-entries))))
      ;; enter the mode through set-mode!: it attaches the mode's keymap
      ;; (use-local-map!) and runs the setup above. A bare mode-name
      ;; local leaves the list's keys unreachable (S8).
      (with-current-buffer buf (lambda () (set-mode! name)))
      ;; current rows; the row stays where the reader left it. The point
      ;; belongs to the reader, and the draw restores the row by its key.
      (when cached?
        (list-refresh! buf)))
    ;; a listing is opened to work in: the window it takes is selected
    (pop-to-buffer buf)
    buf))

;;; --- the public API of this file ----------------------------------------------
;;; The catalog scope of each entry is the one it had in editor.scm.

(domain! 'unknown)
(effects! '(unknown))
(category! 'commands)
(public! 'define-list-mode!
  "(define-list-mode! NAME OPTS) — create a selectable text-table mode. Read the app-creator skill before writing one: it owns what a list already does for you and what is yours to declare. Set transient to #f for persistent app buffers (default #t). KEYS. Four are TAKEN -- bound on your map after your own keys, so a mode that declares one silently does not get it: / narrows the rows (list-filter), < and > call the optional regroup and resort callbacks, SPC calls the optional mark-command or list-mark. / is the search key everywhere in this editor and it is the search key here. Another nine are INHERITED from list-mode-map and yours to shadow: f also filters, \\ pops the filter, ? describes the mode, n/p walk, m marks, u/U/* unmark and mark-all, x executes the marks, g reverts (most apps shadow g with their own refetch). Give your own verbs the letters none of these use. Responsive layouts are ordered profiles selected by min-cols, max-cols, or default, first match wins; profiles may override columns, cells, footer, and compact, and the chosen profile is cached per width in the list-layout-cache buffer local. A column width of #f takes the rest of the line, so put the widest text last and budget the fixed widths against the narrow, compact and wide turns. Rows are records, not text: keep the parsed value and let cells render it. Every text list exposes c-list/c-item semantic records. Optional composml-root and composml-record callbacks supply domain tags without changing text layout. Optional collection tag and composml (buf entry) callback project string-keyed rows as semantic blocks; the shared list styles field roles and owns navigation."
  'ui)

;; A list's filters, for a caller that narrows without the prompt: a
;; command written for you, or fast-code writing one.
(domain! 'interaction)
(effects! '(write display))
(public! 'list-filter-push!
  "(list-filter-push! BUF FILTER) — show only some rows of a list buffer (Dired, ibuffer, any list mode) and hide the rest: only the files of a type, only the names with a word. FILTER is (list \"match\" TEXT), e.g. (list \"match\" \".pdf\"); filters stack"
  'ui)
(public! 'list-filter-pop!
  "(list-filter-pop! BUF) — drop the most recent filter on a list buffer"
  'ui)
(public! 'list-filter-clear!
  "(list-filter-clear! BUF) — drop every filter on a list buffer"
  'ui)
(effects! '(read))
(public! 'list-filters
  "(list-filters BUF) — the filters narrowing a list buffer, newest first"
  'ui)
(catalog-meta! 'function "define-list-mode!" 'domain 'ui 'effects '(write))

(domain! 'unknown)
(effects! '(unknown))
