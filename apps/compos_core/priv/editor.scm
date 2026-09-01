;;; editor.scm --- the editor, in Scheme.
;;;
;;; The Elixir core knows nothing about what keys mean or what commands do.
;;; Everything here is userland: redefine any of it from init.scm or M-:.

;;; --- package context and the shared catalog ---------------------------------
;;; Scheme's callable globals deliberately stay flat.  These two stamps are
;;; metadata: the loader changes them while evaluating a file so every public
;;; thing can say who owns it and which vocabulary it belongs to.

(define *loading-package* 'editor)
(define *loading-namespace* 'core)
(define *loading-origin* 'bundled)
(define *catalog-domain* 'unknown)
(define *catalog-effects* '(unknown))

(define (package! name &optional namespace)
  (set! *loading-package* name)
  (set! *loading-namespace* (or namespace name))
  (set! *catalog-domain* 'unknown)
  (set! *catalog-effects* '(unknown))
  name)

(define (namespace! name) (set! *loading-namespace* name))
(define (origin! name) (set! *loading-origin* name))
(define (domain! name) (set! *catalog-domain* name))
(define (effects! effects) (set! *catalog-effects* effects))

;; Catalog entries are plists.  KIND says how to use an entry; PACKAGE says
;; who may replace it on reload; NAMESPACE is its stable display vocabulary;
;; DOMAIN is the subject area; EFFECTS say what invoking it may do.
(define *catalog* '())

;; Deriving an index from the catalog costs more than reading it, so a
;; reader caches what it built and checks this counter to know the cache
;; still answers. Every write to *catalog* moves it.
(define *catalog-gen* 0)

(define (catalog-generation) *catalog-gen*)

(define (catalog--touch!) (set! *catalog-gen* (+ *catalog-gen* 1)))

;; One key string per live entry, for the registration fast path. The
;; `member` builtin runs in Elixir, so a fresh load asks "seen before?"
;; without an interpreted scan; only a re-registration pays the rebuild.
;; Load-time registration was O(n^2) in interpreted frames without this —
;; the whole 15s boot.
(define *catalog-keys* '())

(define (catalog--key k n qualified)
  (string-append k ":" (if (equal? k "component") qualified n)))

(define (catalog--get pl key)
  (cond ((null? pl) #f)
        ((null? (cdr pl)) #f)
        ((equal? (car pl) key) (cadr pl))
        (else (catalog--get (cdr (cdr pl)) key))))

(define (catalog--put pl key value)
  (append (list key value)
          (let loop ((xs pl))
            (cond ((null? xs) '())
                  ((null? (cdr xs)) '())
                  ((equal? (car xs) key) (loop (cdr (cdr xs))))
                  (else (cons (car xs) (cons (cadr xs) (loop (cdr (cdr xs))))))))))

(define (catalog--string x)
  (cond ((string? x) x)
        ((symbol? x) (symbol->string x))
        (else (value->string x))))

;; The entry computes these keys, so a copy in meta made the same key
;; appear twice. plist-get reads the first, so the duplicate was invisible
;; to a reader and visible to anything that walks the entry.
(define catalog--computed-keys
  '(kind name qualified-name package namespace origin domain effects
    metadata-source doc))

(define (catalog--strip-computed pl)
  (cond ((or (null? pl) (null? (cdr pl))) '())
        ((member (car pl) catalog--computed-keys)
         (catalog--strip-computed (cdr (cdr pl))))
        (else (cons (car pl)
                    (cons (cadr pl) (catalog--strip-computed (cdr (cdr pl))))))))

(define (catalog-register! kind name doc &rest meta)
  (let* ((n (catalog--string name))
         (k (catalog--string kind))
         (ns (or (catalog--get meta 'namespace) *loading-namespace*))
         (pkg (or (catalog--get meta 'package) *loading-package*))
         (qualified (or (catalog--get meta 'qualified-name)
                        (string-append (catalog--string ns) "/" n)))
         (domain (or (catalog--get meta 'domain) *catalog-domain*))
         (effects (or (catalog--get meta 'effects) *catalog-effects*))
         ;; The source declares the metadata, or the entry says it does not
         ;; know. A guess here becomes a permission input, so there is none.
         (declared? (and (not (equal? domain 'unknown))
                         (not (member 'unknown effects))))
         (entry (append
                  (list 'kind k 'name n
                        'qualified-name qualified 'package (catalog--string pkg)
                        'namespace (catalog--string ns)
                        'origin (catalog--string *loading-origin*)
                        'domain (catalog--string domain)
                        'effects (map catalog--string effects)
                        'metadata-source (if declared? "declared" "unknown")
                        'doc doc)
                  (catalog--strip-computed meta))))
    (let ((key (catalog--key k n qualified)))
      (if (member key *catalog-keys*)
          (set! *catalog*
            (cons entry
                  (remove (lambda (e)
                            (and (equal? (catalog--get e 'kind) k)
                                 (if (equal? k "component")
                                     (equal? (catalog--get e 'qualified-name) qualified)
                                     (equal? (catalog--get e 'name) n))))
                          *catalog*)))
          (begin
            (set! *catalog* (cons entry *catalog*))
            (set! *catalog-keys* (cons key *catalog-keys*)))))
    (catalog--touch!)
    (when (boundp (quote apropos-catalog-changed!))
      (apropos-catalog-changed! entry))
    entry))

(define (catalog) (reverse *catalog*))

(define (catalog-entry kind name)
  (let ((k (catalog--string kind)) (n (catalog--string name)))
    (let loop ((es *catalog*))
    (cond ((null? es) #f)
          ((and (equal? (catalog--get (car es) 'kind) k)
                (if (and (equal? k "component") (string-contains? n "/"))
                    (equal? (catalog--get (car es) 'qualified-name) n)
                    (equal? (catalog--get (car es) 'name) n)))
           (car es))
          (else (loop (cdr es)))))))

(define (catalog--merge entry meta)
  (if (or (null? meta) (null? (cdr meta)))
      entry
      (catalog--merge (catalog--put entry (car meta) (cadr meta))
                      (cdr (cdr meta)))))

;; domain and effects reach an entry as strings, whichever door they come
;; through. A symbol here made the same domain appear twice in a facet list.
(define (catalog--normalise-meta meta)
  (cond ((or (null? meta) (null? (cdr meta))) meta)
        ((equal? (car meta) 'domain)
         (cons 'domain (cons (catalog--string (cadr meta))
                             (catalog--normalise-meta (cdr (cdr meta))))))
        ((equal? (car meta) 'effects)
         (cons 'effects (cons (map catalog--string (cadr meta))
                              (catalog--normalise-meta (cdr (cdr meta))))))
        (else (cons (car meta) (cons (cadr meta)
                                     (catalog--normalise-meta (cdr (cdr meta))))))))

;; An explicit declaration wins over the scope in force. Packages use this for
;; one entry in a mixed section, and the entry then counts as declared.
(define (catalog-meta! kind name &rest meta)
  (let ((old (catalog-entry kind name)))
    (if (not old)
        #f
        (let* ((merged (catalog--merge old (catalog--normalise-meta meta)))
               (updated (catalog--put merged 'metadata-source
                          (if (and (not (equal? (catalog--get merged 'domain) "unknown"))
                                   (not (member "unknown" (catalog--get merged 'effects))))
                              "declared" "unknown"))))
          (set! *catalog*
            (cons updated
                  (remove (lambda (e)
                            (and (equal? (catalog--get e 'kind) (catalog--get old 'kind))
                                 (equal? (catalog--get e 'qualified-name)
                                         (catalog--get old 'qualified-name))))
                          *catalog*)))
          (catalog--touch!)
          (when (boundp (quote apropos-catalog-changed!))
            (apropos-catalog-changed! updated))
          updated))))

;; Commands are an Elixir registry underneath, but this wrapper gives every
;; declaration the same package/domain/effect metadata as Scheme APIs.
(define define-command--raw define-command)
(define (define-command name &rest args)
  (let* ((documented? (= (length args) 2))
         (doc (if documented? (car args) ""))
         (fn (if documented? (cadr args) (car args))))
    (if documented?
        (define-command--raw name doc fn)
        (define-command--raw name fn))
    (catalog-register! 'command name doc
      'use (string-append "(run-command \"" name "\")"))
    name))

(define undefine-command--raw undefine-command)
(define (undefine-command name)
  (undefine-command--raw name)
  (set! *catalog*
    (remove (lambda (entry)
              (and (equal? (catalog--get entry 'kind) "command")
                   (equal? (catalog--get entry 'name) name)))
            *catalog*))
  (catalog--touch!)
  (when (boundp (quote apropos-catalog-changed!))
    (apropos-catalog-changed! #f))
  name)

;;; --- public API registry -----------------------------------------------------
;;; The supported surface, curated: name + one-line doc. Everything else in
;;; the global namespace is implementation detail — callable, but private by
;;; convention. The LLM's apropos searches this registry by default, so
;;; the model discovers a documented API instead of hundreds of internals.
;;; Declare yours next to its definition: (public! 'my-fn "what it does").

(define *public-api* '())
(define *public-keys* '())   ; the fast path, as for *catalog-keys*

;;; Every entry is (NAME DOC SIG CATEGORY).
;;;
;;; The signature comes out of the doc, because the house convention
;;; already writes one: "(fn ARGS) — what it does". Ninety-five of these
;;; were written that way before anything parsed them, so public! splits
;;; the string rather than making every caller say it twice. A doc with no
;;; leading form gets "(name)".
;;;
;;; The category comes from (category! 'name), which holds until the next
;;; one — declared once per section instead of once per entry. An agent
;;; asking "what can I do with windows" wants the category, not a regex.

(define *public-category* 'unknown)

(define (category! name)
  (set! *public-category* name)
  (domain! name))

;; the balanced leading form of DOC, and the rest with its dash removed
(define (public--split doc)
  (if (not (string-prefix? "(" doc))
      (list #f doc)
      (let loop ((i 0) (depth 0))
        (cond
          ((>= i (string-byte-length doc)) (list #f doc))
          ((equal? (substring-bytes doc i (+ i 1)) "(") (loop (+ i 1) (+ depth 1)))
          ((equal? (substring-bytes doc i (+ i 1)) ")")
           (if (= depth 1)
               (list (substring-bytes doc 0 (+ i 1))
                     (public--undash
                       (substring-bytes doc (+ i 1) (string-byte-length doc))))
               (loop (+ i 1) (- depth 1))))
          (else (loop (+ i 1) depth))))))

(define (public--undash rest)
  (let ((s (string-trim rest)))
    (cond ((string-prefix? "— " s) (string-trim (substring-bytes s 4 (string-byte-length s))))
          ((string-prefix? "-> " s) (string-trim (substring-bytes s 3 (string-byte-length s))))
          ((string-prefix? "-- " s) (string-trim (substring-bytes s 3 (string-byte-length s))))
          (else s))))

(define (public! name doc &optional category)
  (let* ((n (symbol->string name))
         (parts (public--split doc))
         (sig (or (car parts) (string-append "(" n ")")))
         (text (car (cdr parts))))
    (set! *public-api*
      (if (member n *public-keys*)
          (cons (list n text sig (or category *public-category*))
                (remove (lambda (e) (equal? (car e) n)) *public-api*))
          (begin
            (set! *public-keys* (cons n *public-keys*))
            (cons (list n text sig (or category *public-category*))
                  *public-api*))))
    (catalog-register! 'function n text
      'domain (or category *public-category*) 'signature sig 'use sig)))

(define (public-api) (reverse *public-api*))

(define (public-entry name)
  (let loop ((es *public-api*))
    (cond ((null? es) #f)
          ((equal? (car (car es)) name) (car es))
          (else (loop (cdr es))))))

(define (public-categories)
  (let loop ((es (public-api)) (acc '()))
    (cond ((null? es) (reverse acc))
          ((member (nth 3 (car es)) acc) (loop (cdr es) acc))
          (else (loop (cdr es) (cons (nth 3 (car es)) acc))))))

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
;;;   selection-face  face name for the row at point. Omit it for no highlight.

(define *list-modes* '())

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

(define (list-layout-match? buf profile width)
  (let ((minimum (list-layout-bound buf profile 'min-cols))
        (maximum (list-layout-bound buf profile 'max-cols)))
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
  (let* ((opts (list-mode-opts (list-mode-of buf)))
         (layouts (or (plist-get opts 'layouts) '()))
         (width (list-view-width buf))
         (cache (buffer-local buf 'list-layout-cache)))
    (if (and (pair? cache) (equal? (car cache) width))
        (cadr cache)
        (let ((profile (list-select-layout buf layouts width)))
          (buffer-set-local! buf 'list-layout-cache (list width profile))
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
(define (line-index-at buf header-lines)
  (let* ((before (substring-bytes (buffer-text buf) 0 (buffer-point buf)))
         (ln (- (length (string-split before "\n")) 1 header-lines)))
    (and (>= ln 0) ln)))

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
;;; asks first. The mechanism supplies the rest: `m` marks, `u` unmarks,
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
;; way — `m`, `u`, `U` and `*` — and a list that declares flags also gets
;; the flag chars and `x`. They go in before the list's own keys, so a
;; list can still claim any of them for something else.
(define (list-install-mark-keys! buf)
  (let ((fs (or (list-opt buf 'flags) '())))
    (when (or (pair? fs) (list-table? buf))
      (local-set-key* buf "m" "list-mark")
      (local-set-key* buf "u" "list-unmark")
      (local-set-key* buf "U" "list-unmark-all")
      (local-set-key* buf "*" "list-mark-all"))
    (unless (null? fs)
      (local-set-key* buf "x" "list-execute")
      (for-each (lambda (f)
                  (local-set-key* buf (car f) (list-flag-command (car (cdr f)))))
                fs))))

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

(define (list-set-query! buf q)
  (let ((rest (filter (lambda (f) (not (equal? (car f) "match")))
                      (list-filters buf))))
    (buffer-set-local! buf 'list-filters
      (if (equal? q "") rest (cons (list "match" q) rest)))
    (list-redraw! buf)))

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

;; what you typed reads back as you typed it; a kind the mode invented
;; says its name
(define (list-filters-label buf)
  (if (null? (list-filters buf))
      ""
      (string-append "   ·  " (list-filters-text buf))))

;;; --- `/` narrows --------------------------------------------------------------
;;; One filter, for every list. You press `/` and type; the list narrows
;;; on every keystroke to the rows that match. The arrows move the rows
;;; while you type, so you type and then you select. RET keeps the
;;; narrowing and the row you chose, C-g drops the narrowing, `/` again
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

(define (list-match? buf e input &optional ctx)
  (let ((m (list-opt buf 'match)))
    (if m (m buf e input) (re-match? input (list-row-text buf e ctx)))))

;; every list gets the "match" kind; the mode's own 'filter fn reads the
;; kinds it invented. A list with neither keeps every row.
(define (list-filter-match? buf e f &optional ctx)
  (if (equal? (car f) "match")
      (list-match? buf e (car (cdr f)) ctx)
      (let ((m (list-opt buf 'filter)))
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
(define (list-keep-section-emit buf heading rows filters ctx out)
  (let ((kept (filter (lambda (e) (list-entry-kept? buf e filters ctx))
                      (reverse rows))))
    (if (null? kept)
        out
        (append out (if heading (cons heading kept) kept)))))

(define (list-keep-sections buf entries filters ctx)
  (let walk ((rest entries) (heading #f) (rows '()) (out '()))
    (cond ((null? rest)
           (list-keep-section-emit buf heading rows filters ctx out))
          ((list-separator? buf (car rest))
           (walk (cdr rest) (car rest) '()
                 (list-keep-section-emit buf heading rows filters ctx out)))
          (else (walk (cdr rest) heading (cons (car rest) rows) out)))))

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

(define (list-render-rows! buf fetch)
  (if (list-opt buf 'local-filter)
      (begin
        (when (or (equal? fetch #t)
                  (not (buffer-local buf 'list-source-entries)))
          (buffer-set-local! buf 'list-source-entries
                             ((list-opt buf 'rows) buf)))
        (list-keep buf (list-source-entries buf)))
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
;;;   'meta     (buf) -> string             the counts under the title
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
;;;
;;; The mark goes on the first line and the lines under it start where it
;;; does. A two-line row has no single label row, so the head shows none.
;;;   'footer   (buf) -> ((KEY WORD) ...)   the key bar under the rows
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
  (max 40 (- (buffer-cols buf) 1)))

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
(define (list-column-lines buf)
  (let ((w (list-view-width buf))
        (cache (buffer-local buf 'list-columns-cache)))
    (if (and (pair? cache) (equal? (car cache) w))
        (cadr cache)
        (let ((cols (map (lambda (cs) (list-fit-columns cs w))
                         (list-declared-columns buf))))
          (buffer-set-local! buf 'list-columns-cache (list w cols))
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
(define (list-lay-out cells cols)
  (let loop ((cs cells) (ks cols) (text "") (spans '()))
    (if (or (null? cs) (null? ks))
        (list text (reverse spans))
        (let* ((k (car ks))
               (fitted (list-fit (list-cell-text (car cs)) (list-col-width k)
                                 (list-col-trim k)))
               (padded (if (null? (cdr ks))
                           fitted
                           (list-pad fitted (list-col-width k) (list-col-align k))))
               (face (list-cell-face (car cs)))
               (start (string-byte-length text)))
          (loop (cdr cs) (cdr ks)
                (string-append text padded
                               (if (null? (cdr ks)) "" *list-gap*))
                (if face
                    (cons (list start (string-byte-length fitted) face) spans)
                    spans))))))

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
  (let* ((meta (list-say buf 'meta))
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
          (append (if (equal? meta "")
                      '()
                      (list (list 0 (string-byte-length meta) "dim")))
                  (if (equal? note "")
                      '()
                      (list (list (- (string-byte-length text)
                                     (string-byte-length note))
                                  (string-byte-length note) "warn")))))))

;; one label per column says nothing about a row of two lines: the row
;; itself is the only place the two meet, so a two-line list shows none
(define (list-label-lines buf cols)
  (if (> (list-row-height buf) 1)
      '()
      (list (list-label-line buf cols))))

;; the key bar, as header lines: the mode's 'footer keys, under the counts
(define (list-key-lines buf)
  (let* ((f (list-opt buf 'footer))
         (keys (if f (f buf) '())))
    (if (null? keys) '() (list (list-key-bar buf keys)))))

(define (list-table-head buf)
  (let* ((cols (list-columns buf))
         (w (list-view-width buf))
         (meta (list-meta-line buf)))
    (if (list-opt buf 'compact)
        (if (and (null? (list-filters buf))
                 (not (equal? (car meta) "")))
            (append (list (list (list-fit
                                  (string-append (list-say buf 'title) "  "
                                                 (car meta))
                                  w 'middle)
                                '()))
                    (list-key-lines buf)
                    (list-label-lines buf cols))
            (append (list (list-title-line buf w))
                    (if (equal? (car meta) "") '() (list meta))
                    (list-key-lines buf)
                    (list-label-lines buf cols)))
        (append (list (list-title-line buf w))
                (if (equal? (car meta) "") '() (list meta))
                (list-key-lines buf)
                (list (list-rule-line w))
                (list-label-lines buf cols)))))

;; the header as lines. A mode's own 'header is text it wrote itself, so
;; its lines carry no faces.
(define (list-head-lines buf)
  (let ((f (list-opt buf 'header)))
    (cond (f (map (lambda (l) (list l '())) (string-split (f buf) "\n")))
          ((list-table? buf) (list-table-head buf))
          (else (list (list "" '()))))))

;; the key bar: what this list does, in the words the mode chose
(define (list-key-bar buf keys)
  (let loop ((ks keys) (text " ") (spans '()))
    (if (null? ks)
        (list text (reverse spans))
        (let* ((key (car (car ks)))
               (word (car (cdr (car ks))))
               (at (string-byte-length text))
               (piece (string-append key " " word)))
          (loop (cdr ks)
                (string-append text piece (if (null? (cdr ks)) "" " · "))
                (cons (list (+ at (string-byte-length key) 1)
                            (string-byte-length word) "dim")
                      (cons (list at (string-byte-length key) "accent") spans)))))))

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
        (list-marks buf) (list-opt buf 'key)))

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

(define (list-row-lines buf e &optional ctx)
  (let* ((ctx (or ctx (list-row-ctx buf)))
         (marks? (list-ctx-marks? ctx))
         (column-lines (list-ctx-column-lines ctx))
         (mark (if marks? (list-mark-of buf e ctx) "")))
    (if (pair? column-lines)
        (let* ((head (string-append mark " "))
               (blank (string-repeat " " (string-length head))))
          (let loop ((cs (list-row-cells buf e ctx))
                     (ks column-lines)
                     (first? #t)
                     (out '()))
            (if (or (null? cs) (null? ks))
                (reverse out)
                (let* ((laid (list-lay-out (car cs) (car ks)))
                       (pre (if first? head blank))
                       (n (string-byte-length pre)))
                  (loop (cdr cs) (cdr ks) #f
                        (cons (list (string-trim-right
                                      (string-append pre (car laid)))
                                    (append (if (or (not first?)
                                                    (equal? mark " ")
                                                    (equal? mark ""))
                                                '()
                                                (list (list 0 (string-byte-length mark)
                                                            "alert")))
                                            (list-shift-spans (car (cdr laid)) n)))
                              out))))))
        (list (list (string-append mark ((list-ctx-render ctx) buf e)) '())))))

;; the whole view, top to bottom
;; the view: the header, then the rows. The key bar is in the header,
;; under the counts, where the eye lands on an open: at the foot of the
;; text it scrolled away with the rows.
(define (list-view-lines buf rows &optional head)
  (let ((ctx (list-row-ctx buf)))
    (append (or head (list-head-lines buf))
            (fold (lambda (acc e) (append acc (list-row-lines buf e ctx))) '() rows))))

;; write the lines, answer their overlays, and leave every row's byte
;; offset on the buffer — motion and the mode's own overlays then read
;; the same numbers the text has. The text goes in as ONE replace of the
;; whole buffer: a delete and then an append let a render in between
;; see an empty buffer, reset the window's top, and write it back, and
;; the view jumped. The offsets, the head count, and the row height go
;; in as one change too, with the locals the caller adds: every change
;; is a frame refresh and a render, and a draw of twelve changes was
;; twelve of each.
(define (list-write! buf lines first-row n-rows per &optional extra-locals)
  (let loop ((ls lines) (i 0) (off 0) (ovs '()) (offsets '()) (texts '()))
    (if (null? ls)
        (begin (buffer-replace-range! buf 0 (buffer-size buf)
                                      (string-join (reverse texts) ""))
               (buffer-set-locals! buf
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
      (let ((p (nth i offs)))
        (if (equal? (current-buffer) buf) (goto-char! p) (buffer-goto! buf p))
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
               (size (fold (lambda (n line)
                             (+ n (string-byte-length (car line)) 1))
                           0 (list-row-lines buf entry))))
          ;; the key is a change, and a change is a refresh: write it
          ;; only when the selection moved
          (let ((key (list-key buf entry)))
            (unless (equal? key (buffer-local buf 'list-selection-key))
              (buffer-set-local! buf 'list-selection-key key)))
          (if face
              (overlay-set! buf 'list-selection
                (list (list start (+ start size) face)))
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

;; Some lists show state that other commands change: ibuffer shows the
;; buffers, and C-x k kills one from anywhere. Such a mode gives a
;; 'stamp fn — a cheap value that moves when the rows move. The list
;; compares the stamp after every command and re-renders when it
;; differs, so a verb never acts on a row that is gone.
(define (list-stamp! buf)
  (let ((f (list-opt buf 'stamp)))
    (when f (buffer-set-local! buf 'list-stamp (f buf)))))

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

(define-command "list-more" "Draw the next page of this list"
  (lambda ()
    (if (list-more? (current-buffer))
        (list-more! (current-buffer))
        (message "Every row is shown"))))

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

;; #t means the arrows moved a list. #f means no list stands behind this
;; prompt, so the minibuffer keeps its own arrows. The prompt line is the
;; proof: a prompt can also close behind Scheme's back, and a stale list
;; must never steal the arrows from the next palette.
(define (mb-list-move! step)
  (let ((buf *mb-list-buffer*)
        (mb (minibuffer-state)))
    (if (and buf mb (buffer-exists? buf)
             (equal? (plist-get mb 'prompt) *list-filter-prompt*))
        (begin (with-invoking-buffer (lambda () (list-move-in! buf step))) #t)
        #f)))

;; The narrowing is live, and the input IS it. The prompt opens holding
;; the query the list already has, so `/` edits the narrowing instead of
;; stacking a second one on top of it. Every keystroke narrows, every
;; DEL widens, and an empty input means no query at all — that is how
;; you remove one. C-g puts back the query you came in with.
(define-command "list-filter"
  "Narrow this list to the rows that match what you type"
  (lambda ()
    (let* ((buf (current-buffer))
           (before (list-query buf))
           (narrow (lambda (q)
                     (list-set-query! buf q)
                     (list-goto-first-entry buf)))
           (done (lambda () (set! *mb-list-buffer* #f))))
      (set! *mb-list-buffer* buf)
      (minibuffer-read* *list-filter-prompt* '()
        (list (list 'change narrow)
              ;; RET keeps the narrowing AND the row: the arrows moved the
              ;; highlight to the row you want, so confirm must not send it
              ;; back to the first one. A query the change handler did not
              ;; apply yet still narrows here.
              (list 'confirm (lambda (q)
                               (done)
                               (if (equal? q (list-query buf)) #t (narrow q))))
              (list 'cancel (lambda () (done) (narrow before)))
              (list 'style "filter")))
      ;; the prompt starts where the list is: editing beats retyping
      (unless (equal? before "") (minibuffer-input! before)))))

(define-command "list-filter-pop" "Drop the most recent filter on this list"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (null? (list-filters buf))
          (message "no filter")
          (begin (list-filter-pop! buf)
                 (list-goto-first-entry buf))))))

(define-command "list-filter-clear" "Drop every filter on this list"
  (lambda ()
    (let ((buf (current-buffer)))
      (list-filter-clear! buf)
      (list-goto-first-entry buf))))

(domain! 'unknown)
(effects! '(unknown))

;;; the refresh every one of them wrote by hand

;; a row may want colour, and colour is byte ranges — so the list tells
;; the row where its line landed rather than making the caller keep its
;; own running offset
(define (list-row-overlays buf rows)
  (let ((ovf (list-opt buf 'overlays)))
    (if (not ovf)
        '()
        (let loop ((es rows) (offs (list-offsets buf)) (out '()))
          (if (or (null? es) (null? offs))
              (reverse out)
              (loop (cdr es) (cdr offs)
                    (append (reverse (ovf buf (car es) (car offs))) out)))))))

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

(define (list-render! buf fetch)
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
           (rows (list-render-rows! buf fetch))
           (cur? (equal? (current-buffer) buf))
           ;; the buffer's own point: a refresh runs while another buffer
           ;; is current (a hook, a prompt), and that list keeps its place
           (p (buffer-point buf))
           (ro (buffer-read-only? buf)))
      ;; our own rewrite is not a user edit, and the buffer is read-only.
      (buffer-set-read-only! buf #f)
      ;; a paged list draws the first page of its rows; the entries keep
      ;; every row, so the counts and the filters see them all
      (let* ((shown (list-page-rows buf rows)))
        ;; entries first: the header states the row count. The columns
        ;; lay out against the rows this draw writes: the cache clears
        ;; HERE, not before the fetch. Reading point asks the header how
        ;; many lines it has, and that laid the columns out while the
        ;; rows they must fit were still the last draw's. Every later
        ;; call in this draw reads the cache, so the mode's columns fn
        ;; still runs once. One change for the three.
        (buffer-set-locals! buf
          (list 'list-entries rows
                'list-columns-cache #f
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
               (base (list-write! buf (list-view-lines buf shown head)
                                  (length head) (length shown)
                                  (list-row-height buf) extra)))
          ;; the tag's old ranges go with this set: one change, not a
          ;; clear and then a set
          (overlay-set! buf 'list (append base (list-row-overlays buf shown)))))
      (buffer-set-read-only! buf ro)
      (let ((i (and selected-key (list-index-of buf rows selected-key)))
            (last (- (list-shown-count buf) 1)))
        (cond ((and i (pair? rows)) (list-goto-index! buf (min i last)))
              ;; the rows may have shrunk under point — the key bar is
              ;; not a row
              ((and was (pair? rows))
               (list-goto-index! buf (min was last)))
              (else
               (let ((q (min p (buffer-size buf))))
                 (if cur? (goto-char! q) (buffer-goto! buf q))))))
      (list-snap-point! buf)
      (list-update-selection! buf))))

;; `g` and every source change fetch again; a filter keystroke only
;; redraws, and a 'local-filter list then reuses its cached source.
(define (list-refresh! buf) (list-render! buf #t))
(define (list-redraw! buf) (list-render! buf #f))

;;; --- the buffer cache: content fetched from a slow source ---------------------
;;; A buffer that shows external data (an HTTP API, a slow command) keeps
;;; what it fetched — rendered text, list entries — and these helpers keep
;;; the bookkeeping: when the data arrived, whether it is stale, and one
;;; refresh in flight at a time. The fetch must leave the UI lane: FETCH
;;; receives a continuation and calls it with the data when it has it, so
;;; a shell fetch uses the callback form of shell-command->string and the
;;; lane moves on. A wake draws the cache it has and refreshes only when
;;; the declared TTL has passed.
;;;
;;;   'cache-time      seconds at the last successful render — persists,
;;;                    so a restart knows the age of what it restored
;;;   'cache-spec      (fetch FN render FN ttl SECONDS) — holds closures,
;;;                    so the mode setup re-declares it on every wake
;;;   'cache-inflight  one refresh at a time — runtime state

(define (cache-declare! buf fetch render ttl)
  (desktop-skip! buf 'cache-spec)
  (desktop-skip! buf 'cache-inflight)
  (buffer-set-local! buf 'cache-inflight #f)
  (buffer-set-local! buf 'cache-spec
    (list 'fetch fetch 'render render 'ttl ttl)))

(define (cache-stamp! buf)
  (buffer-set-local! buf 'cache-time (current-time)))

;; seconds since the last successful render, or #f before the first
(define (cache-age buf)
  (let ((t (buffer-local buf 'cache-time)))
    (and t (- (current-time) t))))

;; #t when the buffer never rendered, or its TTL has passed. A declared
;; TTL of #f means the data never goes stale by age: only an explicit
;; cache-refresh! fetches again.
(define (cache-stale? buf)
  (let ((spec (buffer-local buf 'cache-spec)))
    (and spec
         (let ((age (cache-age buf))
               (ttl (plist-get spec 'ttl)))
           (cond ((not age) #t)
                 ((not ttl) #f)
                 (else (> age ttl)))))))

;; "just now", "40s ago", "5m ago", "2h ago" — for a header or modeline
(define (cache-age-label buf)
  (let ((age (cache-age buf)))
    (cond ((not age) #f)
          ((< age 10) "just now")
          ((< age 60) (string-append (number->string age) "s ago"))
          ((< age 3600) (string-append (number->string (quotient age 60)) "m ago"))
          (else (string-append (number->string (quotient age 3600)) "h ago")))))

;; Fetch and re-render. The buffer shows what it has until the data
;; lands; a fetch already in flight is not doubled. A #f from the fetch
;; leaves the cache as it was — the stale rows beat an empty view.
(define (cache-refresh! buf)
  (let ((spec (buffer-local buf 'cache-spec)))
    (when (and spec (not (buffer-local buf 'cache-inflight)))
      (buffer-set-local! buf 'cache-inflight #t)
      ((plist-get spec 'fetch) buf
       (lambda (data)
         (when (buffer-known? buf)
           (buffer-set-local! buf 'cache-inflight #f)
           (when data
             ((plist-get spec 'render) buf data)
             (cache-stamp! buf))))))))

;; the wake rule: show the cache, and fetch only past the TTL
(define (cache-wake! buf)
  (when (cache-stale? buf) (cache-refresh! buf)))

;; Everything a list buffer needs to BE one, applied to an explicit
;; buffer. The mode setup calls it with (current-buffer); opening a list
;; calls it with the buffer it just made, so neither has to select first.
(define (list-mode-init! buf name)
  (let ((opts (list-mode-opts name))
        (widened #f))
    (buffer-set-local! buf 'list-mode name)
    (desktop-skip! buf 'list-layout-cache)
    (buffer-set-local! buf 'list-layout-cache #f)
    ;; derived content (S15): the refresh below re-renders it from
    ;; rows-fn, so the desktop saves mode + locals, not the rows
    (buffer-set-local! buf 'transient #t)
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
    ;; every list is read-only, so "?" can be help in all of them — bound
    ;; before the mode's own keys, which may claim it for something else
    (local-set-key* buf "?" "describe-mode")
    ;; m/u/U/* and the flag keys — also before the mode's own keys, for
    ;; the same reason
    (list-install-mark-keys! buf)
    ;; a table moves the same way in every list: n and p walk the rows and
    ;; stop at the ends, and the line-motion keys REMAP, so the arrows and
    ;; C-n/C-p walk them too
    (when (list-table? buf)
      (local-set-key* buf "n" "list-next")
      (local-set-key* buf "p" "list-prev")
      (local-remap*! buf "next-line" "list-next")
      (local-remap*! buf "previous-line" "list-prev")
      (local-remap*! buf "scroll-up-command" "list-page-down"))
    ;; every list narrows the same way — `/` to type, `\` to widen. Both
    ;; go in before the mode's own keys, which may claim them for
    ;; something else.
    (local-set-key* buf "/" "list-filter")
    (local-set-key* buf "\\" "list-filter-pop")
    (for-each (lambda (k) (local-set-key* buf (car k) (car (cdr k))))
              (or (plist-get opts 'keys) '()))
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
    (list-render! buf (if widened #t 'cached))
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
  (set! *list-modes*
    (cons (list name opts)
          (remove (lambda (e) (equal? (car e) name)) *list-modes*)))
  ;; the list says what it is once, here — describe-mode reads it back
  (let ((d (plist-get opts 'doc)))
    (when d (mode-doc! name d)))
  ;; a real mode: a restored list buffer gets its keys and its read-only
  ;; flag back from here, not from whatever command first opened it
  (define-mode name (lambda () (list-mode-init! (current-buffer) name)))
  name)

;; open (or re-open) a list buffer in its mode
(define (list-mode-show! name)
  (let ((buf (plist-get (list-mode-opts name) 'buffer)))
    (buffer-create buf)
    ;; an explicit open asks for current rows; a wake does not. The init
    ;; below redraws cached entries when there are any, so fetch here in
    ;; that case — the one place the user chose to look.
    (let ((cached? (pair? (buffer-local buf 'list-entries))))
      ;; mode-name so a desktop restore re-runs the setup above
      (buffer-set-local! buf 'mode-name name)
      (list-mode-init! buf name)
      ;; current rows; the row stays where the reader left it. The point
      ;; belongs to the reader, and the draw restores the row by its key.
      (when cached?
        (list-refresh! buf)))
    (display-buffer buf)
    buf))

;;; --- plists ------------------------------------------------------------------
;;; Flat plists — (key value key value ...) with symbol keys — are the house
;;; record shape: events, configs, conversation turns. This dialect has no
;;; dotted pairs, so there are no alists to confuse them with.

(define (plist-get pl key)
  (let loop ((pl pl))
    (cond ((null? pl) #f)
          ((null? (cdr pl)) #f)
          ((equal? (car pl) key) (car (cdr pl)))
          (else (loop (cdr (cdr pl)))))))

;; list-ref by its Emacs name — this dialect has no builtin for it, and it
;; was living as a private helper inside packages/agent.scm
(define (nth n l) (if (= n 0) (car l) (nth (- n 1) (cdr l))))

;;; --- editing commands ------------------------------------------------------

(define-command "forward-char" "Move point one character forward"
  (lambda () (forward-char!)))
(define-command "backward-char" "Move point one character backward"
  (lambda () (backward-char!)))
;; An app owns its input, and a read-only HTML page is a reader. Scroll those
;; pages instead of moving an invisible source point. A writable HTML preview
;; takes edits, so its motion keys must move through the source.
(define (preview-buffer? buf)
  (let ((rm (buffer-local buf 'render-mode)))
    (or (equal? rm "app")
        (and (equal? rm "html") (buffer-read-only? buf)))))

;; #t when it scrolled, so a command can fall through to the point motion
(define (preview-scroll! lines)
  (and (preview-buffer? (current-buffer))
       (begin (scroll-window! (active-window) lines) #t)))

(define-command "next-line" "Move point down one line"
  (lambda () (or (preview-scroll! 3) (visual-next-line!))))
(define-command "previous-line" "Move point up one line"
  (lambda () (or (preview-scroll! -3) (visual-previous-line!))))
(define-command "beginning-of-line" "Move point to the beginning of the line"
  (lambda () (visual-beginning-of-line!)))
(define-command "end-of-line" "Move point to the end of the line"
  (lambda () (visual-end-of-line!)))
(define-command "beginning-of-buffer" "Move point to the beginning of the buffer"
  (lambda () (or (preview-scroll! -1000000) (beginning-of-buffer!))))
(define-command "end-of-buffer" "Move point to the end of the buffer"
  (lambda () (or (preview-scroll! 1000000) (end-of-buffer!))))
(catalog-meta! 'command "beginning-of-buffer" 'domain 'editing 'effects '(write display))
(catalog-meta! 'command "end-of-buffer" 'domain 'editing 'effects '(write display))

(define (preview--positions text needle)
  (let loop ((from 0) (acc (list)))
    (let ((i (string-index text needle from)))
      (if i
          (loop (+ i 1) (cons i acc))
          (reverse acc)))))

;; The nearest position strictly on DIR's side of FROM. DIR is 1 for a key
;; that moves down, -1 for a key that moves up.
(define (preview--toward positions from dir)
  (let ((side (filter (lambda (p) (if (> dir 0) (> p from) (< p from)))
                      positions)))
    (cond ((null? side) #f)
          ((> dir 0) (car side))
          (else (car (reverse side))))))

;; The position nearest FROM, on either side.
(define (preview--nearest positions from)
  (let loop ((ps positions) (best #f))
    (cond ((null? ps) best)
          ((or (not best) (< (abs (- (car ps) from)) (abs (- best from))))
           (loop (cdr ps) (car ps)))
          (else (loop (cdr ps) best)))))

(define (preview--nth lst n)
  (cond ((null? lst) #f)
        ((<= n 0) (car lst))
        (else (preview--nth (cdr lst) (- n 1)))))

;; One rendered fragment names many source positions. A two-character code
;; span such as `-b` sits in the file ten times, so the first hit is almost
;; never the one the reader points at: the cursor jumps to the top of the
;; file, and the next key matches the same first hit again. The cursor then
;; stops moving.
;;
;; So the client also counts, on the page, how many times the fragment
;; comes before the one it means (NTH), and names the direction the key
;; moves (DIR: 1 down, -1 up, 0 for a click). Take the NTH source hit.
;; Rendered text and source text differ, so that count can miss; when it
;; misses, or when DIR says the cursor must move and the NTH hit does not
;; move it, take the nearest hit on DIR's side. A down key then always
;; moves down.
;;
;; string-index rejects an empty pattern, so an empty needle answers #f.
(define (preview--hit text before after nth dir from)
  (let ((needle (string-append before after)))
    (if (equal? needle "")
        #f
        (let* ((starts (preview--positions text needle))
               (b (string-byte-length before))
               (hits (map (lambda (i) (+ i b)) starts))
               (want (preview--nth hits nth))
               (ok (and want (or (= dir 0) (if (> dir 0) (> want from) (< want from))))))
          (cond (ok want)
                ((= dir 0) (preview--nearest hits from))
                (else (or (preview--toward hits from dir)
                          (preview--nearest hits from))))))))

;; A click or a visual-line key in a rendered markdown page. The client
;; sends the text node split at the caret, plus the word run around the
;; caret. Rendered text and source differ (markup is stripped, punctuation
;; is smartened), so try the exact node first and the plain word run
;; second; NTH counts the node, WN counts the word run.
(define (preview-goto! win before after wb wa nth wn dir)
  (mouse-select-window! win)
  (set-mark! #f)
  (let* ((text (buffer-text (current-buffer)))
         (from (point))
         (hit (or (preview--hit text before after nth dir from)
                  (preview--hit text wb wa wn dir from))))
    (when hit (goto-char! hit))))
(public! 'preview-goto!
  "(preview-goto! WIN BEFORE AFTER WB WA NTH WN DIR) — put point where a preview click or visual-line key landed"
  'interaction)

(define (preview-select! win before after wb wa nth wn dir)
  (let ((anchor (or (mark) (point))))
    (preview-goto! win before after wb wa nth wn dir)
    (set-mark! anchor)))
(public! 'preview-select!
  "(preview-select! WIN BEFORE AFTER WB WA NTH WN DIR) — extend the region to a rendered position"
  'interaction)

;; Render-only widgets know their exact source ranges. Unlike preview-goto!,
;; these do not need to reverse-map rendered prose into Markdown.
(define (preview-goto-pos! win pos extend)
  (mouse-select-window! win)
  (when extend (unless (mark) (set-mark! (point))))
  (unless extend (set-mark! #f))
  (goto-char! (max 0 (min pos (buffer-size (current-buffer))))))
(public! 'preview-goto-pos!
  "(preview-goto-pos! WIN POS EXTEND) — move to an exact preview source position"
  'interaction)

;; A click on a link in a rendered page. The client never follows the link
;; itself — it sends the href here, and Scheme says what the link means.
;; A link the editor owns reads "compos:VERB/ARGUMENT": a package claims a
;; verb with on-preview-link!, the way it claims a display rule. help.scm
;; claims "def", which opens the source of a name. An ordinary URL opens
;; in the reader.
(define *preview-link-verbs* '())

(define (on-preview-link! verb fn)
  (set! *preview-link-verbs*
    (cons (list verb fn)
          (filter (lambda (e) (not (equal? (car e) verb))) *preview-link-verbs*))))

;; "compos:def/find-file" -> ("def" "find-file"). The argument keeps its own
;; slashes, so a qualified name survives the split.
(define (preview--link-parts href)
  (let* ((body (string-join (cdr (string-split href ":")) ":"))
         (parts (string-split body "/")))
    (list (car parts) (string-join (cdr parts) "/"))))

(define (preview-follow-link! win href)
  (mouse-select-window! win)
  (cond
    ((string-prefix? "compos:" href)
     (let* ((parts (preview--link-parts href))
            (hit (assoc (car parts) *preview-link-verbs*)))
       (if hit
           ((cadr hit) (cadr parts))
           (message (string-append "No handler for " href)))))
    ((and (or (string-prefix? "http://" href) (string-prefix? "https://" href))
          (boundp 'browse))
     (browse href))
    (else (message href))))

(public! 'on-preview-link!
  "(on-preview-link! VERB FN) — claim the compos:VERB/ARG links in a rendered page; FN gets ARG"
  'interaction)
(public! 'preview-follow-link!
  "(preview-follow-link! WIN HREF) — follow a link a reader clicked in a rendered page"
  'interaction)
(catalog-meta! 'function "on-preview-link!" 'domain 'interaction 'effects '(write))
(catalog-meta! 'function "preview-follow-link!" 'domain 'interaction 'effects '(write))

(define-command "newline" "Insert a newline at point" (lambda () (insert! "\n")))
(define (delete-active-region!)
  (if (and (mark) (< (region-beginning) (region-end)))
      (begin
        (delete-region!)
        (set-mark! #f)
        #t)
      #f))

(define-command "delete-backward-char" "Delete the character before point"
  (lambda ()
    (unless (delete-active-region!) (delete-char! -1))))
(define-command "delete-char" "Delete the character after point"
  (lambda ()
    (unless (delete-active-region!) (delete-char! 1))))

(define-command "kill-line" "Kill text from point to end of line"
  (lambda ()
    (let ((killed (kill-line!)))
      (if (equal? killed "") #f (kill-push! killed)))))

(define-command "undo" "Undo the last change"
  (lambda ()
    (if (not (undo!)) (message "No further undo information"))))

;;; --- minibuffer --------------------------------------------------------------
;;; The minibuffer is a real buffer (" *minibuf*"): point motion, kill/yank,
;;; undo and M-DEL all work in prompts for free via the global keymap. Only
;;; prompt-specific behavior is bound here, in its local keymap.

(define-command "minibuffer-confirm" "Accept the selected minibuffer candidate"
  (lambda () (minibuffer-confirm!)))
;; RET takes the candidate. C-RET and S-RET take the same candidate with
;; a different verb, and the prompt that cares (the buffer switcher)
;; reads and resets the flag:
;;   RET    go there, move nothing else
;;   C-RET  enter the candidate's context, layout and all
;;   S-RET  bring the candidate HERE, into the current context
(define *mb-confirm-context* #f)
(define *mb-confirm-adopt* #f)
(define-command "minibuffer-confirm-context"
  "Accept the selected candidate as a context (group) switch"
  (lambda () (set! *mb-confirm-context* #t) (minibuffer-confirm!)))
(define-command "minibuffer-confirm-adopt"
  "Accept the selected candidate into the current context"
  (lambda () (set! *mb-confirm-adopt* #t) (minibuffer-confirm!)))
(catalog-meta! 'command "minibuffer-confirm-adopt"
               'domain 'interaction 'effects '(write))
(define-command "minibuffer-confirm-input" "Accept the minibuffer input exactly as typed"
  (lambda () (minibuffer-confirm-input!)))
(define-command "minibuffer-cancel" "Cancel the minibuffer prompt"
  (lambda () (minibuffer-cancel!)))
(define-command "minibuffer-complete" "Complete the minibuffer input"
  (lambda () (minibuffer-complete!)))
(define-command "minibuffer-next-candidate" "Select the next minibuffer candidate"
  (lambda ()
    (if (mb-list-move! 1) #t (begin (minibuffer-next!) (mb-select-notify!)))))
(define-command "minibuffer-previous-candidate" "Select the previous minibuffer candidate"
  (lambda ()
    (if (mb-list-move! -1) #t (begin (minibuffer-prev!) (mb-select-notify!)))))
(define-command "minibuffer-delete-backward" "Delete the character before point"
  (lambda () (minibuffer-del!)))

;;; --- candidate preview (the consult mechanism) -------------------------------
;;; Emacs previews by hooking SELECTION, not windows: consult registers a
;;; state function that fires as the highlighted candidate changes, shows
;;; it in the window the prompt was invoked from (minibuffer-selected-
;;; window), and restores on quit. Same here: a prompt can register a
;;; select hook; it fires after C-n/C-p and after typing refilters. The
;;; preview itself uses window-preview-buffer!, which never touches the
;;; MRU ring — cancelling leaves history exactly as it was.

(define *mb-select-fn* #f)

(define (mb-select-notify!)
  (when *mb-select-fn*
    (let ((sel (minibuffer-selected)))
      (when sel (*mb-select-fn* sel)))))

;; current-buffer defaults to the minibuffer's OWN text while one is
;; active (the normal case: typing in the minibuffer should act on the
;; minibuffer). A preview callback is the opposite by definition — its
;; whole job is to act on what you're previewing, in the window you
;; invoked it from — so wrap it here, once, rather than trust every
;; future caller to remember set-mb-redirect! for themselves. Forgetting
;; it doesn't error; it just silently moves point in text nobody sees,
;; which is exactly the bug this replaced.
(define (with-invoking-buffer thunk)
  (set-mb-redirect! #f)
  (let ((result (thunk)))
    (set-mb-redirect! #t)
    result))

;; minibuffer-read with live candidate preview: ON-SELECT fires per
;; highlight move, ON-CONFIRM with the choice, ON-CANCEL on C-g (restore
;; whatever the preview displaced there). All three run against the
;; invoking buffer, not the minibuffer's — see with-invoking-buffer.
;; one interaction model: a completion prompt is the BOTTOM bar, like
;; Emacs — the candidates sit above the input and the input sits on the
;; last row. Only a prompt that asks for "palette" by name floats: the
;; switcher, the command palette, and the LLM config menus. Candidates
;; alone never promote a prompt to the centered card.
(define (prompt-style cands style)
  style)

;; the builtin reads (prompt cands confirm) or (prompt cands complete
;; confirm); this wrapper keeps both shapes and adds the palette rule
(define (minibuffer-read prompt cands a &optional b)
  (minibuffer-read* prompt cands
    (append
      (list (list 'confirm (if b b a)))
      (if b (list (list 'complete a)) '())
      (list (list 'style (prompt-style cands #f))))))

;; y-or-n-p: a question that takes ONE key. "y" runs YES, "n" and C-g
;; run NO, and any other key clears the input, so the question stands
;; until it gets an answer. A question is not a completion prompt: it
;; offers no candidates, so it stays on the bottom bar and it never
;; grows a palette of two words.
(define (y-or-n prompt yes &optional no)
  (let* ((no (if no no (lambda () #f)))
         ;; the prompt closes BEFORE the answer runs: an answer may ask
         ;; the next question, and two prompts cannot share the bar
         (answer (lambda (k) (lambda () (minibuffer-detach!) (k)))))
    (minibuffer-read* (string-append prompt " (y or n) ") '()
      (list (list 'change
              (lambda (input)
                (cond ((string-suffix? "y" input) ((answer yes)))
                      ((string-suffix? "n" input) ((answer no)))
                      (else (minibuffer-input! "")))))
            ;; RET is not an answer: a question takes y or n and nothing
            ;; else, so RET asks it again. C-g is the way out, and it
            ;; means no.
            (list 'confirm (lambda (v) (y-or-n prompt yes no)))
            (list 'cancel no)
            (list 'style "question")))))

;; MATCH-HINT also matches what you type against the marginalia beside
;; each candidate: #t means the first field, an integer N the first N.
;; STYLE picks the presentation; unset, the palette rule decides.
;; COMPLETE, when given, runs on TAB with (INPUT SELECTED) and can
;; answer (list NEW-INPUT CANDIDATES) to replace the pool.
;; COLLECT, when given, receives the candidate rows left after narrowing.
(define (minibuffer-read-preview prompt cands on-select on-confirm on-cancel
                                 &optional match-hint style complete collect)
  (set! *mb-select-fn* (lambda (sel) (with-invoking-buffer (lambda () (on-select sel)))))
  (minibuffer-read* prompt cands
    (append
      (list (list 'confirm (lambda (v)
                              (set! *mb-select-fn* #f)
                              (with-invoking-buffer (lambda () (on-confirm v)))))
            (list 'cancel  (lambda ()
                              (set! *mb-select-fn* #f)
                              (with-invoking-buffer on-cancel)))
            (list 'change  (lambda (input) (mb-select-notify!)))
            (list 'match-hint (if match-hint match-hint #f))
            (list 'style (prompt-style cands style)))
      (if complete (list (list 'complete complete)) '())
      (if collect (list (list 'collect collect)) '()))))

(let ((mb (minibuffer-buffer)))
  (local-set-key* mb "RET" "minibuffer-confirm")
  (local-set-key* mb "M-RET" "minibuffer-confirm-input")
  (local-set-key* mb "C-RET" "minibuffer-confirm-context")
  (local-set-key* mb "S-RET" "minibuffer-confirm-adopt")
  (local-set-key* mb "C-g" "minibuffer-cancel")
  (local-set-key* mb "TAB" "minibuffer-complete")
  (local-set-key* mb "C-n" "minibuffer-next-candidate")
  (local-set-key* mb "<down>" "minibuffer-next-candidate")
  (local-set-key* mb "C-p" "minibuffer-previous-candidate")
  (local-set-key* mb "<up>" "minibuffer-previous-candidate")
  ;; a search repeats from inside its own prompt
  (local-set-key* mb "C-s" "isearch-repeat-forward")
  (local-set-key* mb "C-r" "isearch-repeat-backward")
  ;; the prompt continues as a buffer — see minibuffer-collect below
  (local-set-key* mb "C-c C-o" "minibuffer-collect")
  (local-set-key* mb "DEL" "minibuffer-delete-backward"))

;;; --- hooks (Emacs-style, all Scheme) ----------------------------------------

(define *hooks* '())

(define (add-hook! hook fn) (set! *hooks* (cons (list hook fn) *hooks*)))

;; a client attached a frame: the Elixir side built it fresh, so anything
;; a frame CARRIES for display — the group it stands in, and whatever a
;; package adds later — has to be pushed out again. The client calls this
;; once per mount, inside that frame's input context.
(define (frame-attached!)
  (run-hooks 'frame-attach-hook))

(define (run-hooks hook)
  (for-each (lambda (h) (if (equal? (car h) hook) ((cadr h)))) *hooks*))

;;; --- folds --------------------------------------------------------------------
;;; Folds are tagged, because a buffer has several fold owners: org folds
;;; headlines, the agent transcript folds tool output, diff-mode folds hunks.
;;; Each owner replaces only its own tag. The display hides the union.
;;;
;;; fold-toggle! is for an owner whose state IS the hidden-range list. An
;;; owner that derives its ranges from something else — org from headline
;;; offsets, agent from (start end open?) triples — toggles its own model
;;; and calls fold-set! with the result.

(define (fold-toggle! buf tag range)
  (let ((cur (fold-get buf tag)))
    (fold-set! buf tag
      (if (member range cur)
          (filter (lambda (r) (not (equal? r range))) cur)
          (cons range cur)))))

;;; --- overlay chrome ----------------------------------------------------------
;;; A chrome attachment draws text the buffer does not hold: a badge, a key
;;; hint, a chip. It stands at one byte, holds zero bytes, and the caret
;;; walks over it. Build one here and put it in an overlay-set! range list
;;; beside the face spans; the renderer draws it as a zero-length island
;;; with the class "chrome-seg CLASS". A before attachment draws ahead of
;;; its byte, an after attachment behind it.

(define (chrome--spec side pos text class click)
  (list pos pos
        (string-append "chrome-" side ":" class ":" (url-encode text)
                       (if click (string-append ":" click) ""))))

(define (chrome-before pos text class &optional click)
  (chrome--spec "b" pos text class click))

(define (chrome-after pos text class &optional click)
  (chrome--spec "a" pos text class click))

(public! 'chrome-before
  "(chrome-before POS TEXT CLASS [CLICK]) — an overlay range that draws TEXT ahead of byte POS as zero-length chrome with the class CLASS; a CLICK id routes through the block-click registry")
(public! 'chrome-after
  "(chrome-after POS TEXT CLASS [CLICK]) — an overlay range that draws TEXT behind byte POS as zero-length chrome with the class CLASS; a CLICK id routes through the block-click registry")

;;; --- the filesystem-change hook ----------------------------------------------
;;; run-hooks calls its handlers with no arguments, and this one carries the
;;; root, so it keeps its own list. Elixir holds ONE handler (fs-on-change!)
;;; and this dispatcher fans it out. Keep the handlers small: they schedule a
;;; refresh, they do not do the work. Watch debounces, but a slow handler
;;; still runs once per burst per root.

(define *fs-change-hooks* '())

(define (on-fs-change! fn)
  (set! *fs-change-hooks* (cons fn *fs-change-hooks*)))

(fs-on-change!
  (lambda (root)
    (for-each (lambda (fn) (fn root)) *fs-change-hooks*)))

;;; --- marginalia ---------------------------------------------------------------
;;; What a candidate MEANS, beside the candidate. A prompt names the
;;; CATEGORY its candidates belong to; an annotator turns one candidate
;;; into the text next to it. The prompt does not know the annotation and
;;; the annotator does not know the prompt, so a package can annotate a
;;; category it did not write, and every prompt over that category gains
;;; the annotation at once.
;;;
;;;   (marginalia! 'file (lambda (name) (or (auto-mode-for name) "")))
;;;   (annotate 'file (list-dir dir))   ->   ((NAME HINT) ...)
;;;
;;; Three prompts each built their own (LABEL HINT) pairs inline, so a new
;;; prompt over the same things showed nothing. They all call `annotate`
;;; now. The core matches, ranks and confirms on the LABEL alone, so an
;;; annotation changes what you read and never what you get.
;;;
;;; An annotator answers with one string, or with a LIST of fields:
;;;
;;;   (marginalia! 'file (lambda (n) (list (mode n) (size n) (date n))))
;;;
;;; `annotate` measures each field over the whole candidate set and pads
;;; it, so field N lines up with field N on every other row and the
;;; annotation reads as a table. A field that wants its text on the right
;;; (a size) pads itself — the mechanism only makes the columns.

(define *marginalia* '())    ; ((CATEGORY FN) ...)

;; Packages can attach a face to a candidate label. The candidate renderer
;; carries the face without knowing why that name has that color.
(define candidate-face-for (lambda (category name) #f))

(define (marginalia! category fn)
  (set! *marginalia*
    (cons (list category fn)
          (remove (lambda (e) (equal? (car e) category)) *marginalia*))))

(define (marginalia-for category)
  (let ((e (assoc category *marginalia*)))
    (and e (car (cdr e)))))

;; one candidate's fields — a single string is a list of one
(define (marginalia-row f n)
  (let ((v (f n)))
    (cond ((string? v) (list v))
          ((pair? v) v)
          (else '()))))

;; the width of every column, over the whole set. A row with fewer fields
;; than the widest keeps the columns it does not reach.
(define (marginalia-widths rows)
  (fold (lambda (ws r)
          (let loop ((fs r) (old ws) (out '()))
            (if (null? fs)
                (append (reverse out) old)
                (loop (cdr fs)
                      (if (null? old) '() (cdr old))
                      (cons (max (string-length (car fs))
                                 (if (null? old) 0 (car old)))
                            out)))))
        '() rows))

;; a row whose last fields say nothing ends early — padding a column that
;; is empty to the end only makes an annotation out of blanks
(define (marginalia-trim fields)
  (let loop ((fs (reverse fields)))
    (cond ((null? fs) '())
          ((equal? (car fs) "") (loop (cdr fs)))
          (else (reverse fs)))))

;; the fields as the one string the core carries. The last field goes in
;; unpadded: trailing blanks would only pad the end of the line.
(define (marginalia-join fields widths)
  (let loop ((fs fields) (ws widths) (out ""))
    (if (null? fs)
        out
        (let ((txt (if (null? (cdr fs))
                       (car fs)
                       (string-pad-right (car fs) (if (null? ws) 0 (car ws))))))
          (loop (cdr fs)
                (if (null? ws) '() (cdr ws))
                (if (equal? out "") txt (string-append out "  " txt)))))))

;; a category with no annotator hands its candidates back as plain labels
(define (annotate category names)
  (let ((f (marginalia-for category)))
    (if (not f)
        names
        (let* ((rows (map (lambda (n) (marginalia-row f n)) names))
               (ws (marginalia-widths rows)))
          (let loop ((ns names) (rs rows) (out '()))
            (if (null? ns)
                (reverse out)
                (let* ((name (car ns))
                       (hint (marginalia-join (marginalia-trim (car rs)) ws))
                       (face (candidate-face-for category name)))
                  (loop (cdr ns) (cdr rs)
                        (cons (if face
                                  (list name hint "candidate" '() face)
                                  (list name hint))
                              out)))))))))

;;; --- hot reload -------------------------------------------------------------
;;; A save reloads that file's changed top-level forms into this session.
;;; A new definition alone does not reach a buffer that is already open:
;;; the mode setup fn installed the old keys, overlays and folds, and
;;; nothing re-runs it. That is the one reason a mode change used to need
;;; a restart.
;;;
;;; Session.reload_files/1 brackets every reload with these two fns.
;;; reload-begin! opens a record. define-mode and register-minor-mode!
;;; write their name into it. reload-finish! re-runs setup on every live
;;; buffer that wears one of those modes, and on nothing else — a save in
;;; markdown.scm must not rebuild a shell buffer.
;;;
;;; The work is the work desktop restore does, so the same rule holds: a
;;; setup fn rebuilds presentation from the buffer's locals, and stacks
;;; nothing twice.

(domain! 'system)
(effects! '(write))

(define *reloading?* #f)
(define *reload-touched* '())

;; Name a mode this reload defined. Outside a reload this records nothing,
;; so boot pays nothing for it.
(define (reload--touch! name)
  (when *reloading?*
    (set! *reload-touched* (cons name *reload-touched*))))

(define (reload-begin!)
  (set! *reloading?* #t)
  (set! *reload-touched* '())
  #t)

(define (reload-finish!)
  (set! *reloading?* #f)
  (when (boundp (quote apropos-reload-finished!))
    (apropos-reload-finished!))
  (let* ((modes *reload-touched*)
         (bufs (reload--buffers-to-rebuild modes)))
    (set! *reload-touched* '())
    (for-each restore-buffer-runtime! bufs)
    ;; A reload changes what a render would produce, but nothing asks for
    ;; one: a client repaints on an editor event, and evaluating a
    ;; definition is not an event. Without this a new modeline, face, or
    ;; fringe stays on screen exactly as it was until the next keystroke,
    ;; which reads as "the reload did nothing".
    (redraw!)
    (length bufs)))

;; Every buffer in a window, on every frame. A reload names only the modes
;; whose define-mode form changed, and a setup fn calls helpers that the
;; same save can change without touching that form. So rebuild what the
;; person is looking at as well: that is two to five buffers, never the
;; whole buffer list, and it is the difference between a save you can see
;; and a save you cannot. Set this to #f for a session where a mode setup
;; is expensive.
(define *reload-refresh-visible* #t)

(define (reload--visible-buffers)
  (if *reload-refresh-visible*
      (map (lambda (w) (car (cdr w))) (window-list-all))
      '()))

;; The buffers one reload must rebuild: every buffer wearing a mode the
;; reload redefined, plus every visible buffer. Once each, live only.
(define (reload--buffers-to-rebuild modes)
  (let loop ((bs (append (reload--mode-buffers modes) (reload--visible-buffers)))
             (acc '()))
    (cond ((null? bs) (reverse acc))
          ((or (member (car bs) acc) (not (buffer-exists? (car bs))))
           (loop (cdr bs) acc))
          (else (loop (cdr bs) (cons (car bs) acc))))))

;; Does B wear one of MODES, as its major mode or as a minor mode?
(define (buffer-wears-mode? b modes)
  (let loop ((names (cons (buffer-local b 'mode-name)
                          (or (buffer-local b 'minor-modes) '()))))
    (cond ((null? names) #f)
          ((and (car names) (member (car names) modes)) #t)
          (else (loop (cdr names))))))

(define (reload--mode-buffers modes)
  (if (null? modes)
      '()
      (filter (lambda (b)
                (and (buffer-exists? b) (buffer-wears-mode? b modes)))
              (buffer-list))))

;; Re-run mode setup wherever one of MODES is worn. Returns the number of
;; buffers rebuilt. restore-buffer-runtime! is desktop restore's entry: it
;; re-runs the major setup and every minor setup with the buffer current,
;; the layout engine suppressed, and the buffer neither displayed nor
;; selected. So the frame does not move and the point does not jump.
(define (reload-refresh-modes! modes)
  (let ((bs (reload--mode-buffers modes)))
    (for-each restore-buffer-runtime! bs)
    (length bs)))

(domain! 'unknown)
(effects! '(unknown))

;;; --- modes ------------------------------------------------------------------
;;; A major mode = mode-name buffer-local + a setup fn (local keys, vars).
;;; The registry, auto-mode-alist, everything: userland.

(define *mode-setups* '())

;; Replace the entry by name. assoc reads the newest first either way, but
;; a reloader that runs on every save must not grow this list without end.
(define (define-mode name setup)
  (set! *mode-setups*
    (cons (list name setup)
          (remove (lambda (e) (equal? (car e) name)) *mode-setups*)))
  (reload--touch! name)
  ;; every mode is an M-x command, like Emacs. The command toggles: the
  ;; command that puts you in a mode takes you out of it again.
  (define-command name (lambda () (modeline-toggle-mode! name)))
  (catalog-register! 'mode name "Major mode"
    'use (string-append "(run-command \"" name "\")")))

;; A mode can say which mode it is built from. Emacs writes that into
;; define-derived-mode; here the parent is a fact about the name, so a test
;; asks mode-is? instead of comparing one string and missing every child.
(define *mode-parents* '())

(define (mode-parent! name parent)
  (set! *mode-parents*
    (cons (list name parent)
          (remove (lambda (e) (equal? (car e) name)) *mode-parents*))))

(define (mode-parent name)
  (let ((e (assoc name *mode-parents*))) (and e (cadr e))))

;; #t when MODE is NAME, or descends from it. The walk carries what it has
;; seen, so a parent loop ends instead of hanging the editor.
(define (mode-is? mode name)
  (let loop ((m mode) (seen '()))
    (cond ((not m) #f)
          ((equal? m name) #t)
          ((member m seen) #f)
          (else (loop (mode-parent m) (cons m seen))))))

(define (buffer-mode-is? buf name)
  (mode-is? (buffer-local buf 'mode-name) name))

;; Run another mode's setup. A derived mode inherits the behavior instead
;; of copying it, so the two cannot drift apart.
(define (mode-setup! name)
  (let ((e (assoc name *mode-setups*)))
    (when e ((cadr e)))))

;; What a mode is for, in the mode's own words. describe-mode prints it
;; above the key table. A mode without one still gets its keys.
(define *mode-docs* '())

(define (mode-doc! name doc)
  (set! *mode-docs*
    (cons (list name doc)
          (remove (lambda (e) (equal? (car e) name)) *mode-docs*)))
  (let ((e (catalog-entry 'mode name)))
    (if e
        (catalog-register! 'mode name doc
          'package (string->symbol (catalog--get e 'package))
          'namespace (string->symbol (catalog--get e 'namespace))
          'domain (string->symbol (catalog--get e 'domain))
          'effects (map string->symbol (catalog--get e 'effects))
          'use (string-append "(run-command \"" name "\")"))
        (catalog-register! 'mode name doc))))

(define (mode-doc name)
  (let ((e (assoc name *mode-docs*)))
    (and e (car (cdr e)))))

;;; --- mode icons ---------------------------------------------------------------
;;; One glyph names a mode, and every list that shows a mode shows it:
;;; dired, ibuffer, the buffer prompt and the file prompt. A mode declares
;;; its own icon; a mode that declares none reads as a plain document. An
;;; icon is ONE character: a Nerd Font glyph, or a plain Unicode character
;;; where one says it better — λ names a Scheme file. Never an emoji, which
;;; draws two cells and colours a column that must stay quiet.

(define *mode-icons* '())
(define *default-mode-icon* "")

(define (mode-icon! name icon)
  (set! *mode-icons*
    (cons (list name icon)
          (remove (lambda (e) (equal? (car e) name)) *mode-icons*))))

(define (mode-icon name)
  (let ((e (and name (assoc name *mode-icons*))))
    (if e (car (cdr e)) *default-mode-icon*)))

;; the icon a buffer wears is its mode's
(define (buffer-icon b)
  (mode-icon (buffer-local b 'mode-name)))

;; the icon a file NAME wears is the icon of the mode it would open in. A
;; directory opens in Dired, and a listing marks one with a trailing "/".
(define (file-icon name)
  (if (string-suffix? "/" name)
      (mode-icon "Dired")
      (mode-icon (auto-mode-for name))))

;; a mode name with its icon in front, for a column that shows the mode
(define (mode-label name)
  (string-append (mode-icon name) " " (or name "Fundamental")))

;; the modes this file defines. A package stamps its own icons.
(mode-icon! "Dired" "")
(mode-icon! "text-mode" "")
(mode-icon! "scheme-mode" "λ")
(mode-icon! "elixir-mode" "")
(mode-icon! "json-mode" "")
(mode-icon! "rust-mode" "")
(mode-icon! "html-mode" "")
(mode-icon! "chat-mode" "")
(mode-icon! "shell-mode" "")
(mode-icon! "term-mode" "")
(mode-icon! "comint-shell-mode" "")
(mode-icon! "tail-mode" "")
(mode-icon! "collect-mode" "")


(define (set-mode! name)
  (buffer-set-local! (current-buffer) 'mode-name name)
  (let ((m (assoc name *mode-setups*)))
    (if m ((cadr m))))
  (run-hooks (string->symbol (string-append name "-hook")))
  ;; the mode is on: if it declares a layout, the engine arranges the frame
  (layout-enter! (current-buffer)))

;; desktop restore's entry: set BUF's mode with BUF current, so the setup
;; fn rebuilds presentation from the locals restore already laid down.
;; The desktop restores its own saved windows, so the layout engine stands
;; down for the whole call.
(define (desktop-apply-mode! buf mode)
  (with-layout-suppressed
    (lambda ()
      (with-current-buffer buf (lambda () (set-mode! mode)))
      ;; The compact dashboard is derived state. Rebuild it during restore so
      ;; a saved desktop shows it before the first command runs.
      (when (boundp (quote dashboard--sync!))
        (dashboard--sync! buf)))))

;;; --- globals that outlive a restart (savehist) ---------------------------------
;;; The desktop saves buffers, windows and buffer-locals. A global was
;;; simply lost: the minibuffer history is a global, so every restart
;;; threw away which commands you use and M-x fell back to alphabetical.
;;;
;;; A variable joins by naming itself once. GET answers with the value to
;;; write; PUT receives it back after a restore. Only the VALUE travels,
;;; so the two closures stay here — a closure in the desktop file restores
;;; as a dangling frame and cannot be called.
;;;
;;;   (persist-global! 'my-thing (lambda () *my-thing*)
;;;                              (lambda (v) (set! *my-thing* v)))

(define *desktop-globals* '())   ; ((KEY GET PUT CLEAR) ...)

(define (persist-global! key get put)
  (let* ((old (assoc key *desktop-globals*))
         (initial (get))
         ;; A package reload re-registers the variable after it changed.
         ;; Keep the first reset closure instead of adopting that live value.
         (reset (if old
                    (car (cdr (cdr (cdr old))))
                    (lambda () (put initial)))))
    (set! *desktop-globals*
      (cons (list key get put reset)
            (remove (lambda (e) (equal? (car e) key)) *desktop-globals*)))))

;; what the desktop writes
(define (desktop-globals)
  (map (lambda (e) (list (car e) ((cadr e)))) *desktop-globals*))

;; what the desktop hands back. A key nobody claims any more is dropped,
;; so a desktop file written by an older editor still boots.
(define (desktop-globals! saved)
  (for-each
    (lambda (e)
      (let ((hit (assoc (car e) saved)))
        (when hit ((car (cdr (cdr e))) (cadr hit)))))
    *desktop-globals*))

(define (desktop-globals-clear!)
  (for-each
    (lambda (e) ((car (cdr (cdr (cdr e))))))
    *desktop-globals*))

;; desktop-clear follows Emacs: remove every non-internal buffer and reset
;; the globals that ride in the desktop. Each modified file gets one question.
;; A saves all remaining files. N explicitly discards all remaining edits.
(define (desktop-clear--finish kept members)
  (let ((doomed (filter (lambda (b) (not (member b kept))) members)))
    (desktop-globals-clear!)
    (for-each
      (lambda (b)
        (when (process-running? b) (process-kill! b))
        (buffer-kill! b))
      doomed)
    (message
      (string-append "Cleared desktop: "
                     (number->string (length doomed)) " buffers"
                     (if (pair? kept)
                         (string-append "; kept "
                                        (number->string (length kept))
                                        " unsaved")
                         "")))))

(define (desktop-clear--save-all dirty members)
  (for-each save-buffer-named! dirty)
  (desktop-clear--finish '() members))

(define (desktop-clear--ask-save dirty kept members)
  (if (null? dirty)
      (desktop-clear--finish kept members)
      (let* ((b (car dirty))
             (answer (lambda (k) (lambda () (minibuffer-detach!) (k)))))
        (minibuffer-read*
          (string-append "Save " b "? (y, n, A all, N none) ") '()
          (list
            (list 'change
              (lambda (input)
                (cond
                  ((string-suffix? "y" input)
                   ((answer
                      (lambda ()
                        (save-buffer-named! b)
                        (desktop-clear--ask-save (cdr dirty) kept members)))))
                  ((string-suffix? "n" input)
                   ((answer
                      (lambda ()
                        (desktop-clear--ask-save
                          (cdr dirty) (cons b kept) members)))))
                  ((string-suffix? "A" input)
                   ((answer (lambda () (desktop-clear--save-all dirty members)))))
                  ((string-suffix? "N" input)
                   ((answer (lambda () (desktop-clear--finish '() members)))))
                  (else (minibuffer-input! "")))))
            (list 'confirm
              (lambda (v) (desktop-clear--ask-save dirty kept members)))
            (list 'cancel (lambda () #f))
            (list 'style "question"))))))

(domain! 'desktop)
(effects! '(destroy))

(define-command "desktop-clear"
  "Empty the desktop, asking whether to save each modified file"
  (lambda ()
    (let* ((members (buffer-list-mru))
           (dirty (filter
                    (lambda (b)
                      (and (buffer-path b) (buffer-modified? b)))
                    members)))
      (desktop-clear--ask-save dirty '() members))))

(domain! 'unknown)
(effects! '(unknown))

;;; --- minor modes --------------------------------------------------------------
;;; A minor mode = its name in the buffer-local 'minor-modes list + an
;;; idempotent setup fn taking the buffer. Desktop restore re-runs the
;;; setup (restore-minor-modes!) after locals come back, the same way
;;; set-mode! re-runs major-mode setup — so setup fns must rebuild
;;; presentation from the locals they find, never stack hooks twice.

(define *minor-mode-setups* '())   ; (name setup teardown)

(define (register-minor-mode! name setup &optional teardown)
  (set! *minor-mode-setups*
    (cons (list name setup teardown)
          (remove (lambda (e) (equal? (car e) name)) *minor-mode-setups*)))
  (reload--touch! name))

(define (minor-mode-on? buf name)
  (let ((ms (buffer-local buf 'minor-modes)))
    (if (and ms (member name ms)) #t #f)))

(define (enable-minor-mode! buf name)
  (let ((cur (or (buffer-local buf 'minor-modes) '())))
    (unless (member name cur)
      (buffer-set-local! buf 'minor-modes (cons name cur))))
  (let ((m (assoc name *minor-mode-setups*)))
    (if m ((cadr m) buf)))
  ;; the setup fn named the buffers its layout wants; now place them
  (layout-enter! buf))

(define (disable-minor-mode! buf name)
  (buffer-set-local! buf 'minor-modes
    (remove (lambda (n) (equal? n name))
            (or (buffer-local buf 'minor-modes) '())))
  (let ((m (assoc name *minor-mode-setups*)))
    (if (and m (caddr m)) ((caddr m) buf))))

(define (toggle-minor-mode! name)
  (let ((buf (current-buffer)))
    (if (minor-mode-on? buf name)
        (begin (disable-minor-mode! buf name) #f)
        (begin (enable-minor-mode! buf name) #t))))

;; Fundamental, the state a buffer has before any mode claims it. Nothing
;; remembers the mode you left, as in Emacs. normal-mode reads the file
;; name again and the mode comes back. The echo area states each result.

(define (major-mode-off! buf name)
  (buffer-set-local! buf 'render-mode #f)
  (buffer-set-local! buf 'preview-renderer #f)
  ;; the grammar is the mode's: no mode, no colours
  (buffer-set-local! buf 'ts-lang #f)
  (buffer-set-read-only! buf #f)
  (buffer-set-local! buf 'mode-name #f))

;; Emacs's normal-mode: the mode the file name asks for, applied again.
(define-command "normal-mode"
  "Set the major mode the buffer's file name asks for"
  (lambda ()
    (let* ((buf (current-buffer))
           (path (buffer-path buf))
           (m (and path (auto-mode-for path))))
      (if m
          (begin (set-mode! m) (message (string-append m " on")))
          (message "no mode for this buffer")))))

(define (modeline-toggle-mode! name)
  (let* ((buf (current-buffer))
         (major (or (buffer-local buf 'mode-name) "Fundamental")))
    (cond
      ;; a minor mode toggles in place. A name that is both is a major
      ;; mode here, because its own command would call this back forever.
      ((and (assoc name *minor-mode-setups*) (not (assoc name *mode-setups*)))
       (if (member name (command-names))
           (run-command name)
           (toggle-minor-mode! name))
       (message (string-append name
                               (if (minor-mode-on? buf name)
                                   " enabled"
                                   " disabled"))))
      ;; the buffer is in another mode: enter this one
      ((not (equal? name major))
       (set-mode! name)
       (message (string-append name " on")))
      ;; Fundamental is no mode: there is nothing to leave, so read the
      ;; file name again. This is the way back for a file buffer.
      ((equal? major "Fundamental")
       (run-command "normal-mode"))
      (else
        (major-mode-off! buf name)
        (message (string-append name " off"))))))

(define (restore-minor-modes! buf)
  (for-each
    (lambda (name)
      (let ((m (assoc name *minor-mode-setups*)))
        (if m ((cadr m) buf))))
    (or (buffer-local buf 'minor-modes) '())))

;; #t while a wake rebuilds a buffer's runtime. A wake is not an open:
;; the switcher previews a dormant buffer by re-running its mode setup,
;; and a list whose rows come from the network must not pay that fetch
;; inside a preview. list-mode-init! reads this.
(define *buffer-waking* #f)

(define (with-buffer-waking thunk)
  (let ((was *buffer-waking*))
    (set! *buffer-waking* #t)
    (let ((r (thunk)))
      (set! *buffer-waking* was)
      r)))

;; A dormant buffer wakes with literal persisted locals but none of the
;; runtime machinery those locals describe. Re-run both setup layers with a
;; logical current buffer: restoration must not display or select BUF.
(define (restore-buffer-runtime! buf)
  (with-layout-suppressed
    (lambda ()
      (with-current-buffer buf
        (lambda ()
          (with-buffer-waking
            (lambda ()
              (let ((mode (buffer-local buf 'mode-name)))
                (when mode (set-mode! mode)))
              (restore-minor-modes! buf)
              ;; a restored popup floats still, so its move keys come back
              (when (popup--class? buf) (popup-keys! buf #t))))))))
  ;; The modeline is derived state. Rebuild it here so a restored desktop
  ;; shows its top line and its short name before the first command runs.
  (when (boundp (quote dashboard--sync!))
    (dashboard--sync! buf))
  ;; The buffer is whole again, so an owner can act on it. Outside
  ;; with-buffer-waking on purpose: that flag is restored by hand, and a
  ;; hook that throws inside it would leave every later wake believing it
  ;; was still waking.
  (buffer-woken! buf))

;;; Visual lines are a buffer capability, independent of the major mode.
;;; This minor mode owns the durable flag. The client measures where the
;;; rendered rows begin and reports the byte offsets per window, tagged
;;; with the buffer version it measured: the wrap map. The client cannot
;;; know what a key means on those rows; that is decided here.

(domain! 'interaction)
(effects! '(write))

(define (visual-line-mode--apply! buf)
  (buffer-set-local! buf 'visual-line-mode #t))

(define (visual-line-mode--teardown! buf)
  (buffer-set-local! buf 'visual-line-mode #f)
  (buffer-set-local! buf 'visual-goal #f))

(register-minor-mode!
  "visual-line-mode"
  visual-line-mode--apply!
  visual-line-mode--teardown!)

(define-command "visual-line-mode" "Toggle visual-row motion in the current buffer"
  (lambda ()
    (if (toggle-minor-mode! "visual-line-mode")
        (message "Visual line mode enabled")
        (message "Visual line mode disabled"))))

(mode-doc! "visual-line-mode"
  "Wrap long logical lines and make vertical motion follow rendered rows.")

;; The rows the client measured for the active window, when the mode is
;; on and the map is as new as the buffer. A map from an older version
;; names rows that moved, so the caller moves by source line instead, and
;; the measure after the next paint repairs it. A key never waits.
(define (visual-rows buf)
  (and (equal? (buffer-local buf 'visual-line-mode) #t)
       (let ((m (window-wrap-map (active-window))))
         (and m
              (equal? (car m) (buffer-version buf))
              (cadr m)))))

;; the end of the source line holding POS: the byte before its newline
(define (visual--line-end pos)
  (let* ((n (line-number-at-pos pos))
         (next (line-start-position (+ n 1))))
    (if (> next pos) (- next 1) (buffer-size (current-buffer)))))

;; The row holding POS: (START NEXT), NEXT being where the row below
;; begins, or #f for the last measured row. #f when POS is above every
;; measured row, or below the last one's source line.
(define (visual-row-bounds rows pos)
  (let loop ((rs rows) (start #f))
    (cond ((null? rs)
           (and start (<= pos (visual--line-end start)) (list start #f)))
          ((> (car rs) pos)
           (and start (list start (car rs))))
          (else (loop (cdr rs) (car rs))))))

;; the byte before POS, as a one-byte string; "" at the buffer start
(define (visual--byte-before pos)
  (if (> pos 0) (buffer-substring (- pos 1) pos) ""))

;; Where the row that begins at START ends. The row below begins at NEXT,
;; and the byte before NEXT is what the browser wrapped at. A space or a
;; newline there is not something the reader sees on this row, so the row
;; ends before it; a paragraph break is two newlines, and both stay off.
;; A row with nothing measured below it runs to the end of its source line.
(define (visual-row-end-from start next)
  (if (not next)
      (visual--line-end start)
      (let* ((b (visual--byte-before next))
             (q (if (and (> next start) (or (equal? b " ") (equal? b "\n")))
                    (- next 1)
                    next)))
        (let loop ((q q))
          (if (and (> q start) (equal? (visual--byte-before q) "\n"))
              (loop (- q 1))
              q)))))

(define (visual--row-before rows start)
  (let loop ((rs rows) (prev #f))
    (cond ((null? rs) #f)
          ((= (car rs) start) prev)
          (else (loop (cdr rs) (car rs))))))

(define (visual-row-start pos)
  (let ((rows (visual-rows (current-buffer))))
    (and rows
         (let ((b (visual-row-bounds rows pos)))
           (and b (car b))))))
(public! 'visual-row-start
  "(visual-row-start POS) — the byte offset the visual row holding POS begins at; #f when the wrap map cannot say")

(define (visual-row-end pos)
  (let ((rows (visual-rows (current-buffer))))
    (and rows
         (let ((b (visual-row-bounds rows pos)))
           (and b (visual-row-end-from (car b) (cadr b)))))))
(public! 'visual-row-end
  "(visual-row-end POS) — the byte offset the visual row holding POS ends at; #f when the wrap map cannot say")

;; The column a run of vertical moves holds, in characters from the row
;; start. It lives while point stands where the last move left it: any
;; other move, horizontal or a click, starts the column afresh.
(define (visual--goal buf start pos)
  (let ((g (buffer-local buf 'visual-goal)))
    (if (and g (equal? (car g) pos))
        (cadr g)
        (string-length (buffer-substring start pos)))))

(define (visual--land! buf start end goal)
  (let* ((text (buffer-substring start end))
         (n (min goal (string-length text)))
         (pos (+ start (string-byte-length (substring text 0 n)))))
    (goto-char! pos)
    (buffer-set-local! buf 'visual-goal (list pos goal))
    pos))

;; extending keeps the anchor, or starts a region at point; a plain move
;; clears the mark, as a click does
(define (visual--mark! extend)
  (if extend
      (unless (mark) (set-mark! (point)))
      (set-mark! #f)))

;; An editable surface asks the browser's own layout to move: it knows
;; where every row wraps, so no map is measured or kept for it. A
;; rendered page and a read-only buffer keep the wrap map.
(define (visual--client? buf)
  (and (equal? (buffer-local buf 'visual-line-mode) #t)
       (not (buffer-read-only? buf))
       ;; a client that has reported its caret is there to answer; a
       ;; headless buffer keeps the server's own motion
       (equal? (buffer-local buf 'client-caret) #t)
       ;; a window that measured a map, fresh or stale, draws a page that
       ;; measures; an editable surface never sends one
       (not (window-wrap-map (active-window)))
       ;; only the plain text view is an editable surface; a rendered page,
       ;; a block view, a transcript, and a terminal draw something else
       (not (member (buffer-local buf 'render-mode)
                    '("markdown" "html" "app" "blocks" "agent" "terminal")))))

(define (visual--client-move! alter dir granularity &optional count)
  (client-select! alter (if (< dir 0) "backward" "forward") granularity (or count 1))
  #t)

;; one measured row, from wherever point is now
(define (visual--row-step! buf rows dir extend)
  (let* ((pos (point))
         (here (visual-row-bounds rows pos)))
    (and here
         (let* ((start (car here))
                (goal (visual--goal buf start pos))
                (target (if (> dir 0) (cadr here) (visual--row-before rows start))))
           (and target
                (let ((there (visual-row-bounds rows target)))
                  (visual--mark! extend)
                  (visual--land! buf (car there)
                                 (visual-row-end-from (car there) (cadr there))
                                 goal)
                  #t))))))

;; COUNT rows up or down, holding the goal column; one row by default.
;; #f when the map cannot answer: the mode is off, the map is stale, or
;; no measured row lies that way. The caller then moves by source line.
;;
;; COUNT is one call, never a loop of calls. The browser answers a whole
;; page in one request; asking it COUNT times does not work, because a
;; frame keeps ONE pending request and each ask overwrites the last, so a
;; page moved one row.
(define (visual-row-move! dir extend &optional count)
  (let* ((buf (current-buffer))
         (n (max 1 (or count 1)))
         (rows (visual-rows buf)))
    ;; a fresh map answers first (a rendered page measures one; so does a
    ;; test); an editable surface measures none and asks the browser
    (if (and (not rows) (visual--client? buf))
        (visual--client-move! (if extend "extend" "move") dir "line" n)
        (and rows
             (let loop ((i 0) (moved #f))
               (if (>= i n)
                   moved
                   (if (visual--row-step! buf rows dir extend)
                       (loop (+ i 1) #t)
                       moved)))))))

;; the edge of the row point is on; #f when the map cannot answer
(define (visual-row-edge! dir extend)
  (let* ((buf (current-buffer))
         (rows (visual-rows buf)))
    (if (and (not rows) (visual--client? buf))
        (visual--client-move! (if extend "extend" "move") dir "lineboundary")
    (and rows
         (let ((here (visual-row-bounds rows (point))))
           (and here
                (begin
                  (visual--mark! extend)
                  (goto-char! (if (< dir 0)
                                  (car here)
                                  (visual-row-end-from (car here) (cadr here))))
                  #t)))))))

;; The motions the commands run. Each moves by visual row when the wrap
;; map can answer, and by source line otherwise, so a plain buffer moves
;; as it always did. EXTEND grows the region instead of clearing it.
(define (visual-next-line! &optional extend)
  (or (visual-row-move! 1 extend) (next-line!)))
(define (visual-previous-line! &optional extend)
  (or (visual-row-move! -1 extend) (previous-line!)))
(define (visual-beginning-of-line! &optional extend)
  (or (visual-row-edge! -1 extend) (beginning-of-line!)))
(define (visual-end-of-line! &optional extend)
  (or (visual-row-edge! 1 extend) (end-of-line!)))
(public! 'visual-next-line!
  "(visual-next-line! [EXTEND]) — move point one visual row down when the wrap map can say, else one source line")
(public! 'visual-previous-line!
  "(visual-previous-line! [EXTEND]) — move point one visual row up when the wrap map can say, else one source line")
(public! 'visual-beginning-of-line!
  "(visual-beginning-of-line! [EXTEND]) — move point to the start of its visual row when the wrap map can say, else of its line")
(public! 'visual-end-of-line!
  "(visual-end-of-line! [EXTEND]) — move point to the end of its visual row when the wrap map can say, else of its line")

(domain! 'unknown)
(effects! '(unknown))

;;; --- renaming a buffer ---------------------------------------------------------
;;; buffer-rename! is the mechanism: the buffer keeps its process, so text,
;;; point, locals, overlays and undo all survive. What does NOT survive is
;;; state OTHER things key by the old name — a change hook, a pointer from
;;; another buffer. Each owner fixes its own, here.

(define *buffer-renamed-hooks* '())

(define (on-buffer-renamed! fn)
  (set! *buffer-renamed-hooks* (cons fn *buffer-renamed-hooks*))
  #t)

;; the rename the editor uses: mechanism, then every owner of name-keyed
;; state. Returns the new name, or #f when the name is taken.
(define (rename-buffer! old new)
  (let ((done (buffer-rename! old new)))
    (when done
      (for-each (lambda (fn) (fn old new)) *buffer-renamed-hooks*))
    done))

(define-command "buffer-rename" "Rename the current buffer without changing its file"
  (lambda ()
    (let ((old (current-buffer)))
      (minibuffer-read (string-append "Rename buffer " old " to: ") '()
        (lambda (input)
          (let ((new (string-trim input)))
            (cond
              ((equal? new "") (message "Buffer needs a name"))
              ((equal? new old) (message (string-append "Buffer is already named " old)))
              ((buffer-known? new)
               (message (string-append "Buffer " new " already exists")))
              ((rename-buffer! old new)
               (message (string-append "Renamed buffer " old " to " new)))
              (else
               (message (string-append "Could not rename buffer " old))))))))))

;; Packages derive policy from the accepted window state through this seam.
;; Preview uses a different primitive and does not call it.
(define window-state-changed! (lambda () #t))

;; Emacs window-configuration-change-hook. The editor calls this once for
;; each change of a frame's windows or their buffers, whoever made it: a
;; command, a kill that dropped a window onto its next buffer, an agent.
;; The window commands below call window-state-changed! themselves too,
;; so their own modeline is right before they return; this is the answer
;; for every other path.
(define (window-configuration-changed!)
  (window-state-changed!)
  (run-hooks 'window-configuration-change-hook))

;; The primitive changes the window and wakes the process; Scheme owns the
;; mode closures, so it also completes runtime restoration in this same
;; interpreter turn. A caller never sees the buffer between those two steps.
(define (switch-to-buffer! buf)
  (let ((restoring (not (buffer-exists? buf))))
    (window-switch-buffer! buf)
    (when restoring (restore-buffer-runtime! buf))
    ;; a buffer floats only in the popup window: shown anywhere else it
    ;; is an ordinary buffer again, whatever class it carried
    (when (and (popup--class? buf)
               (not (equal? (active-window) (frame-local 'popup-window))))
      (popup-float! buf #f))
    (window-state-changed!)
    buf))

(define *auto-mode-alist*
  '((".scm" "scheme-mode") (".el" "scheme-mode")
    (".ex" "elixir-mode") (".exs" "elixir-mode")
    (".json" "json-mode") (".rs" "rust-mode")
    (".html" "html-mode") (".htm" "html-mode")
    (".md" "morg-mode") (".markdown" "morg-mode")
    (".txt" "text-mode") (".org" "org-mode")
    (".chat" "chat-mode")))

;; the mode a file name would open in, without switching anything —
;; dired filters by it, and (auto-mode) applies it
(define (auto-mode-for name)
  (let loop ((es *auto-mode-alist*))
    (cond ((null? es) #f)
          ((string-suffix? (string-downcase (car (car es)))
                           (string-downcase name))
           (car (cdr (car es))))
          (else (loop (cdr es))))))

(define (auto-mode path)
  (let ((m (auto-mode-for path)))
    (when m (set-mode! m))))

;; The directory the file candidates come from. A candidate is a bare
;; name, so the annotator cannot stat it on its own; the file prompt sets
;; this as it lists, through file-candidates below.
(define *marginalia-file-dir* "")

;; what a file name means in a prompt: the mode it would OPEN in, then its
;; size and its date, the same three dired shows. A directory opens in
;; Dired, and the stat says which entries are directories — a listing
;; marks them with a trailing "/", dired's ".." carries no mark, and both
;; read the same. A name no entry above claims opens in Fundamental, which
;; is a mode like any other — so the column stays full and says something
;; true. The size pads itself: a size reads right-aligned, and only the
;; field knows that.
;; This lambda is the file prompt's hot loop: it runs once for every entry
;; in the directory. Read the stat once, and scan auto-mode-alist once —
;; the icon column and the mode column both want the mode, and file-icon
;; would scan the alist a second time to find it.
(marginalia! 'file
  (lambda (name)
    (let* ((st (file-stat (string-append *marginalia-file-dir* name)))
           (dir? (string-prefix? "d" (car st)))
           (mode (and (not dir?) (auto-mode-for name))))
      (list (if dir? (mode-icon "Dired") (mode-icon mode))
            (if dir? "Dired" (or mode "Fundamental"))
            (string-pad-left (car (cdr st)) 6)
            (car (cdr (cdr st)))))))

(define-mode "text-mode" (lambda () #t))
(define-mode "scheme-mode" (lambda () #t))   ; scheme grammar pending

(mode-doc! "text-mode"
  "Plain prose: `.txt`. The mode adds no keys. `C-c C-v` renders the file, because the renderer reads the extension.")

;;; --- the name at point --------------------------------------------------------
;;; Two callers read the name under the cursor and they disagree about the
;;; alphabet, on purpose. `M-.` must not read `foo/2` or `a+b` as one
;;; name, so it stops at the code alphabet. Help also reads Scheme globals
;;; like `*mode-docs*`, so it adds `*`. One scanner, two alphabets.

(define *symbol-chars* "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_?!-")

;; Scan out from point over CHARS and return the name, or #f. Point sits
;; before the character it is on, so a point just after the last character
;; of a name still reads that name — the left scan finds it and the right
;; scan stops at once, the way Emacs answers.
;;
;; The scan reads one byte at a time, and substring-bytes floors both ends
;; to a character boundary. So a one-byte slice of a multi-byte character
;; comes back empty, and an empty slice is not a name character — the scan
;; stops there, which is the correct answer. The guard also matters
;; because string-index rejects an empty pattern.
(define (symbol-at-point-in chars)
  (let* ((text (buffer-text (current-buffer)))
         (size (string-byte-length text))
         (p (point))
         (word? (lambda (c) (and (not (equal? c "")) (string-index chars c)))))
    (let ((s (let loop ((i p))
               (if (and (> i 0) (word? (substring-bytes text (- i 1) i)))
                   (loop (- i 1))
                   i)))
          (e (let loop ((i p))
               (if (and (< i size) (word? (substring-bytes text i (+ i 1))))
                   (loop (+ i 1))
                   i))))
      (and (> e s) (substring-bytes text s e)))))

(define (symbol-at-point) (symbol-at-point-in *symbol-chars*))

;;; --- context providers --------------------------------------------------------
;;; A mode can explain what the user is looking at: (register-context-provider!
;;; "notmuch-mode" fn) where fn takes the buffer name and returns a short
;;; description or #f. agent-send prepends the visible windows'
;;; contexts, so "this" in a chat means the thing selected in the other window.

(define *context-providers* '())   ; ((mode-name fn) ...)

(define (register-context-provider! mode fn)
  (set! *context-providers*
    (cons (list mode fn)
          (filter (lambda (e) (not (equal? (car e) mode))) *context-providers*))))

(define (buffer-context buf)
  (let ((p (assoc (or (buffer-local buf 'mode-name) "") *context-providers*)))
    (and p ((cadr p) buf))))

;; contexts of every visible buffer except EXCLUDE (the chat itself),
;; deduped; "" when no provider speaks up
(define (editor-context exclude)
  (let loop ((ws (window-list)) (seen '()) (acc '()))
    (if (null? ws)
        (string-join (reverse acc) "\n")
        (let ((buf (cadr (car ws))))
          (if (or (equal? buf exclude) (member buf seen))
              (loop (cdr ws) seen acc)
              (let ((ctx (buffer-context buf)))
                (loop (cdr ws) (cons buf seen)
                      (if ctx (cons ctx acc) acc))))))))

;;; --- targets & actions (embark) -----------------------------------------------
;;; The thing at point is a typed TARGET: (type id label). Modes register
;;; a provider; types register ACTIONS ((name fn) ...). One table serves
;;; every consumer: C-. pops the action menu, and the act tool lets the
;;; model drive the same verbs the keyboard does.

(define *target-providers* '())   ; ((mode-name fn) ...), fn: buf -> target|#f

(define (register-target-provider! mode fn)
  (set! *target-providers*
    (cons (list mode fn)
          (filter (lambda (e) (not (equal? (car e) mode))) *target-providers*))))

(define (target-at buf)
  (let ((p (assoc (or (buffer-local buf 'mode-name) "") *target-providers*)))
    (and p ((cadr p) buf))))

(define *embark-actions* '())     ; ((type ((name fn) ...)) ...)

(define (register-actions! type actions)
  (set! *embark-actions*
    (cons (list type actions)
          (filter (lambda (e) (not (equal? (car e) type))) *embark-actions*))))

(define (actions-for type)
  (let ((e (assoc type *embark-actions*)))
    (if e (cadr e) '())))

(define-command "embark-act" "Act on the thing at point"
  (lambda ()
    (let ((t (target-at (current-buffer))))
      (if (not t)
          (message "nothing at point to act on")
          (let* ((type (car t)) (id (cadr t)) (label (caddr t))
                 (acts (actions-for type)))
            (if (null? acts)
                (message (string-append "no actions for "
                                        (symbol->string type)))
                (minibuffer-read
                  (string-append (symbol->string type) " · " label " → ")
                  (map (lambda (a) (list (car a) "")) acts)
                  (lambda (name)
                    (let ((a (assoc name acts)))
                      (when a ((cadr a) id)))))))))))

(global-set-key "C-." "embark-act")

(category! 'targets)
(public! 'register-target-provider! "(register-target-provider! MODE FN) — FN buf -> (type id label) target at point, or #f")
(public! 'register-actions! "(register-actions! 'type '((name fn)...)) — verbs for a target type; C-. and the act tool use them")
(public! 'target-at "(target-at BUF) — the typed target at BUF's point, or #f")

;; the paragraph chat/agent sends prepend when a context provider fires
(define (editor-context-preamble exclude)
  (let ((ctx (editor-context exclude)))
    (if (equal? ctx "")
        ""
        (string-append
          "[Editor context — what the user is looking at right now:\n" ctx
          "\nWhen the user says \"this\" they mean the item above.]\n\n"))))

(define (ts-mode lang)
  (lambda () (buffer-set-local! (current-buffer) 'ts-lang lang)))

(define-mode "html-mode" (ts-mode "html"))

(mode-doc! "html-mode"
  "HTML, parsed. You get the colours, and `C-M-f` and `C-M-b` step over whole elements. `C-c C-v` shows the rendered page, because the renderer reads the extension. `C-c C-a` runs the page as an app: its own scripts, its own storage, and the files beside it. A save reloads it, and `C-g` gives the keyboard back.")

;; revert-buffer: re-read the file from disk (discards buffer edits).
;; Kill + re-visit so modes, hooks and fontification re-apply cleanly.
(define-command "revert-buffer" "Re-read the current buffer's file from disk"
  (lambda ()
    (let* ((buf (current-buffer))
           (path (buffer-path buf))
           (p (point)))
      (if (not path)
          (message "Buffer is not visiting a file")
          (begin
            (buffer-kill! buf)
            (visit path)
            (goto-char! (min p (buffer-size (current-buffer))))
            (message "Reverted"))))))

;;; --- apps --------------------------------------------------------------
;;; preview-mode renders a page the way eww does: themed, and inert. An app
;;; needs the opposite. It keeps the colours the author wrote, it runs its
;;; own JavaScript, it keeps its own storage, and it loads the files beside
;;; it. So an app window draws a frame on the app origin — a different port,
;;; which the browser reads as a different origin — and that origin serves
;;; this buffer's live text plus the directory its file lives in.
;;;
;;; The two are separate commands on purpose. A downloaded .html that you
;;; open to read must not run anything; `C-c C-v` reads it, `C-c C-a` runs
;;; it, and the difference is a key you press.

;; The app itself lives in packages/preview.scm, which defines every one
;; of these and hooks the save. Both copies loaded and both hooks ran, so
;; one save reloaded every app twice. A package owns the app; this file
;; keeps the keys, and preview.scm binds the same three.

(define-mode "elixir-mode" (ts-mode "elixir"))
(define-mode "json-mode" (ts-mode "json"))
(define-mode "rust-mode" (ts-mode "rust"))

;; A language mode sets one buffer-local: `ts-lang`. That local starts the
;; incremental parser, and the parser supplies the colours, the sexp
;; motion and imenu. The mode adds no keys of its own — the global keys do
;; the work, and they need the parser to answer.
(mode-doc! "elixir-mode"
  "Elixir, parsed. You get the colours, `C-M-f` and `C-M-b` over forms, and `M-g i` for the definitions in the file.")
(mode-doc! "json-mode"
  "JSON, parsed. You get the colours, and `C-M-f` and `C-M-b` step over whole objects and arrays.")
(mode-doc! "rust-mode"
  "Rust, parsed. You get the colours, `C-M-f` and `C-M-b` over forms, and `M-g i` for the definitions in the file.")

;;; --- sexp / structural navigation (tree-sitter) ------------------------------

(define (ts-goto op)
  (let ((p (ts-nav op)))
    (if p (goto-char! p) (message "No structural navigation here"))))

(define-command "forward-sexp" "Move forward across one balanced expression"
  (lambda () (ts-goto 'forward)))
(define-command "backward-sexp" "Move backward across one balanced expression"
  (lambda () (ts-goto 'backward)))
(define-command "backward-up-list" "Move backward out of one level of parentheses"
  (lambda () (ts-goto 'up)))
(define-command "down-list" "Move forward down one level of parentheses"
  (lambda () (ts-goto 'down)))

;;; --- word motion & editing ---------------------------------------------------

(define (delete-between! s e)
  (set-mark! e)
  (goto-char! s)
  (delete-region!)
  (set-mark! #f))

;; ONE kill: push S..E to the kill ring, then delete it (dup #30).
;; Returns #t when the range was non-empty.
(define (kill-region-1 s e)
  (if (> e s)
      (begin
        (kill-push! (buffer-substring s e))
        (delete-between! s e)
        #t)
      #f))

;; A mode may let one visible region represent a larger source range. Keep
;; that policy here so keyboard copy, keyboard cut, and system copy agree.
(define *region-lifters* '())

(define (register-region-lifter! mode fn)
  (set! *region-lifters*
    (cons (list mode fn)
          (filter (lambda (entry) (not (equal? (car entry) mode)))
                  *region-lifters*))))

(define (region-action-bounds)
  (let* ((buf (current-buffer))
         (start (region-beginning))
         (end (region-end))
         (hit (assoc (buffer-local buf 'mode-name) *region-lifters*)))
    (if (and hit (procedure? (cadr hit)))
        ((cadr hit) buf start end)
        (list start end))))

(define-command "forward-word" "Move point forward one word" (lambda () (forward-word!)))
(define-command "backward-word" "Move point backward one word"
  (lambda () (backward-word!)))

(define-command "kill-word" "Kill characters forward to the end of a word"
  (lambda ()
    (let ((s (point)))
      (kill-region-1 s (forward-word!)))))

(define-command "backward-kill-word" "Kill characters backward to the start of a word"
  (lambda ()
    (let ((e (point)))
      (kill-region-1 (backward-word!) e))))

(define-command "transpose-chars" "Interchange characters around point"
  (lambda ()
    (if (= (point) (buffer-size (current-buffer))) (backward-char!))
    (if (> (point) 0)
        (let ((p (point)))
          (let ((s (backward-char!)))
            (goto-char! p)
            (let ((e (forward-char!)))
              (let ((a (buffer-substring s p))
                    (b (buffer-substring p e)))
                (delete-between! s e)
                (insert! (string-append b a)))))))))

;;; --- yank / yank-pop ----------------------------------------------------------

(define *yank-start* 0)
(define *yank-index* 0)

(define-command "yank" "Reinsert the last killed text at point"
  (lambda ()
    (set! *yank-index* 0)
    (set! *yank-start* (point))
    (insert! (kill-top))))

(define-command "yank-pop" "Replace just-yanked text with an earlier kill"
  (lambda ()
    (if (or (equal? (last-command) "yank") (equal? (last-command) "yank-pop"))
        (let ((n (kill-ring-size)))
          (if (> n 0)
              (begin
                (delete-between! *yank-start* (point))
                (set! *yank-index* (if (= (+ *yank-index* 1) n) 0 (+ *yank-index* 1)))
                (insert! (kill-nth *yank-index*)))))
        (message "Previous command was not a yank"))))

;;; --- completion framework (capf) ---------------------------------------------
;;; A completion source is a closure of no arguments returning either
;;;   #f                                — source has nothing here
;;;   (list start end candidates)      — region to replace + candidates,
;;;                                       each a string or (label hint) pair
;;; Sources are tried in order; first non-#f wins (Emacs capf semantics).
;;; An LSP client is just another source returning the same shape.
;;; Buffer-local sources: (buffer-set-local! buf 'capf-sources (list fn ...))

(define *capf-sources* '())

(define (add-capf! fn)
  (set! *capf-sources* (cons fn *capf-sources*)))

(define (capf-sources)
  (let ((local (buffer-local (current-buffer) 'capf-sources)))
    (if local (append local *capf-sources*) *capf-sources*)))

(define-command "completion-at-point" "Perform completion on the text around point"
  (lambda ()
    (let loop ((sources (capf-sources)))
      (if (null? sources)
          (begin
            (completion-dismiss!)
            (message "No completions here"))
          (let ((r ((car sources))))
            (if r
                (completion-show! (car r) (cadr r) (caddr r))
                (loop (cdr sources))))))))

;; The popup's keys are policy (dup #22): while it shows, KeyDispatch
;; consults this map first. Unbound printables narrow; anything else
;; unbound dismisses the popup and acts normally.
(define-command "completion-next" "Select the next completion candidate"
  (lambda () (completion-move! 1)))
(define-command "completion-prev" "Select the previous completion candidate"
  (lambda () (completion-move! -1)))
(define-command "completion-accept" "Insert the selected completion at point"
  (lambda ()
    (let ((a (completion-accept!)))
      (when a
        (let ((start (car a)) (label (car (cdr a))))
          (when (> (point) start)
            (buffer-delete-range! (current-buffer) start (- (point) start)))
          (insert! label))))))
(define-command "completion-quit" "Dismiss the completion popup"
  (lambda () (completion-dismiss!) (message "")))

(local-set-key* " *completion*" "C-n" "completion-next")
(local-set-key* " *completion*" "<down>" "completion-next")
(local-set-key* " *completion*" "C-p" "completion-prev")
(local-set-key* " *completion*" "<up>" "completion-prev")
(local-set-key* " *completion*" "RET" "completion-accept")
(local-set-key* " *completion*" "TAB" "completion-accept")
(local-set-key* " *completion*" "C-g" "completion-quit")
(local-set-key* " *completion*" "ESC" "completion-quit")

;; dabbrev: complete the word before point from words in this buffer
(define (capf-dabbrev)
  (let ((e (point)))
    (let ((s (backward-word!)))
      (goto-char! e)
      (if (and (< s e) (> e s))
          (let ((prefix (buffer-substring s e)))
            (let ((words (buffer-words prefix)))
              (if (null? words)
                  #f
                  (list s e (map (lambda (w) (list w "dabbrev")) words)))))
          #f))))

(add-capf! capf-dabbrev)

;;; --- misc editing --------------------------------------------------------------

(define-command "indent-for-tab" "Indent by inserting two spaces"
  (lambda () (insert! "  ")))

;;; --- scrolling (viewport) ------------------------------------------------------

(define (move-lines n mover)
  (let loop ((i 0))
    (if (< i n)
        (begin (mover) (loop (+ i 1))))))

;; A page is a screenful of what the reader sees, so it steps by visual
;; rows: a rendered page and a wrapped paragraph draw many rows for one
;; source line, and paging by source lines there jumps several screens.
;; One counted move, not a loop of single moves — see visual-row-move!.
;; With no wrap map to read, the page is source lines again.
(define (visual-page! dir)
  (let ((n (- (window-rows) 2)))
    (or (visual-row-move! dir #f n)
        (move-lines n (if (> dir 0) next-line! previous-line!)))))

(define-command "scroll-up-command" "Scroll text upward nearly a full screen"
  (lambda ()
    (or (preview-scroll! (- (window-rows) 2))
        (visual-page! 1))))

(define-command "scroll-down-command" "Scroll text downward nearly a full screen"
  (lambda ()
    (or (preview-scroll! (- 2 (window-rows)))
        (visual-page! -1))))

(define-command "recenter-top-bottom" "Recenter point in the window"
  (lambda () (recenter!)))

(define-command "display-line-numbers-mode" "Toggle line numbers in the current buffer"
  (lambda ()
    (let ((cur (buffer-local (current-buffer) 'line-numbers)))
      (if (equal? cur "off")
          (begin
            (buffer-set-local! (current-buffer) 'line-numbers "on")
            (message "Line numbers enabled"))
          (begin
            (buffer-set-local! (current-buffer) 'line-numbers "off")
            (message "Line numbers disabled"))))))

;; window split/resize animations — CSS falls back to 140ms when the
;; chrome face doesn't say otherwise; this flips it to 0ms and back
(define *window-animations* #t)

(define-command "toggle-window-animations" "Toggle window split and resize animations"
  (lambda ()
    (set! *window-animations* (not *window-animations*))
    (set-face-attribute! 'chrome 'anim (if *window-animations* "140ms" "0ms"))
    (message (if *window-animations*
                 "Window animations on"
                 "Window animations off"))))

(define-command "back-to-indentation" "Move point to the first non-space on this line"
  (lambda ()
    (beginning-of-line!)
    (let loop ()
      (let ((p (point)))
        (if (and (< p (buffer-size (current-buffer)))
                 (equal? (buffer-substring p (+ p 1)) " "))
            (begin (forward-char!) (loop)))))))

(define-command "goto-line" "Go to a line number read from the minibuffer"
  (lambda ()
    (minibuffer-read "Goto line: " '()
      (lambda (s)
        (let ((n (string->number s)))
          (if (number? n)
              ;; direct rope lookup — O(log n), not a next-line! walk from
              ;; line 1 (which made jumping deep into a large file cost
              ;; proportional to how far you jumped)
              (goto-char! (line-start-position n))
              (message "Not a number")))))))

;;; imenu lives in packages/code.scm now, on the outline contract: the
;;; index is (code-outline BUF), so it needs no per-language query table.

;;; --- mark & region ---------------------------------------------------------

(define-command "set-mark-command" "Set the mark where point is"
  (lambda ()
    (set-mark! (point))
    (message "Mark set")))

(define-command "kill-region" "Kill the text between point and mark"
  (lambda ()
    (let ((bounds (region-action-bounds)))
      (unless (kill-region-1 (car bounds) (cadr bounds))
        (message "The region is empty")))))

(define-command "copy-region-as-kill" "Save the region as if killed, but don't kill it"
  (lambda ()
    (let* ((bounds (region-action-bounds))
           (text (buffer-substring (car bounds) (cadr bounds))))
      (if (equal? text "")
          (message "The region is empty")
          (begin
            (kill-push! text)
            (set-mark! #f)
            (message "Copied"))))))

(define-command "exchange-point-and-mark" "Exchange positions of point and mark"
  (lambda ()
    (if (not (exchange-point-and-mark!))
        (message "No mark set in this buffer"))))

(define-command "narrow-to-region" "Show only the text between point and mark"
  (lambda ()
    (if (and (mark) (< (region-beginning) (region-end)))
        (begin
          (buffer-narrow! (current-buffer) (region-beginning) (region-end))
          (message "Narrowed to region"))
        (message "No region — set the mark first (C-SPC)"))))

(define-command "widen" "Show the complete current buffer"
  (lambda ()
    (buffer-widen! (current-buffer))
    (message "Widened buffer")))

(catalog-meta! 'command "narrow-to-region"
  'domain 'buffers 'effects '(write display))
(catalog-meta! 'command "widen"
  'domain 'buffers 'effects '(write display))

;;; --- isearch ---------------------------------------------------------------
;;; ONE search engine (dup #13), two surfaces: C-s/C-r here, evil's
;;; / ? n N in evil.scm. The engine owns the directional find, the wrap
;;; retry, and the incremental loop — capture the origin, re-search from
;;; it on every keystroke, restore it on cancel. The surface owns what a
;;; hit shows, what a miss says, and what RET keeps.
;;;
;;; One search runs at a time, so one variable holds it. The state says
;;; where the next find starts, which way it runs, and how to draw a hit.
;;; C-s and C-r in the minibuffer map move that start past the current
;;; match — the prompt stays open, the way Emacs repeats a search.

;; (search-find q backward from) -> (start end) or #f
(define (search-find q backward from)
  (if backward (buffer-search-backward q from) (buffer-search q from)))

;; miss -> one retry from the far end, and the echo area says so
(define (search-find-wrap q backward from)
  (or (search-find q backward from)
      (let ((m (search-find q backward
                            (if backward (buffer-size (current-buffer)) 0))))
        (when m (message "Search wrapped"))
        m)))

;; the live search, or #f between searches
(define *isearch* #f)
;; the last string searched for. An empty C-s repeats it, as Emacs does.
(define *isearch-last* "")

(define (isearch--set! origin start backward show query match)
  (set! *isearch*
    (list 'origin origin 'start start 'backward backward
          'show show 'query query 'match match)))

(define (isearch--field key) (and *isearch* (plist-get *isearch* key)))

;; one find, drawn by the surface. Call it inside with-window-buffer: the
;; search reads the window's buffer, not the prompt.
(define (isearch--step! q backward from wrap)
  (let ((m (and (not (equal? q ""))
                (if wrap
                    (search-find-wrap q backward from)
                    (search-find q backward from))))
        (origin (isearch--field 'origin))
        (show (isearch--field 'show)))
    (isearch--set! origin from backward show q m)
    (show m q origin)
    m))

;; The loop. SHOW gets (match q origin) on every keystroke — match is #f
;; on a miss and on an empty query. ACCEPT gets (q origin) on RET.
;; CANCEL gets (origin) on C-g, after the point returns to it.
(define (isearch-loop prompt backward show accept cancel)
  (let ((origin (point)))
    (isearch--set! origin origin backward show "" #f)
    (minibuffer-read* prompt '()
      (list (list 'change
              (lambda (q)
                (unless (equal? q "") (set! *isearch-last* q))
                (with-window-buffer
                  (lambda ()
                    (isearch--step! q backward (isearch--field 'start) #f)))))
            (list 'confirm (lambda (q)
                             (set! *isearch* #f)
                             (accept q origin)))
            (list 'cancel (lambda ()
                            (set! *isearch* #f)
                            (goto-char! origin)
                            (cancel origin)))))))

;; C-s again: find the match after this one. The repeat wraps at the end of
;; the buffer, and it can turn the search around — C-r inside a forward
;; search walks back through the same hits.
(define (isearch--repeat! backward)
  (when *isearch*
    (with-window-buffer
      (lambda ()
        (let* ((typed (isearch--field 'query))
               (q (if (equal? typed "") *isearch-last* typed))
               (m (isearch--field 'match))
               (turn (not (equal? backward (isearch--field 'backward))))
               (from (cond ((not m) (if backward (buffer-size (current-buffer)) 0))
                           ;; a turn reads THIS match again from the other side
                           (turn (if backward (cadr m) (car m)))
                           (backward (car m))
                           (else (+ (car m) 1)))))
          (if (equal? q "")
              (message "No previous search")
              (begin
                ;; the prompt shows the string it repeats
                (when (equal? typed "") (minibuffer-input! q))
                ;; the surface says what a hit and a miss look like
                (isearch--step! q backward from #t))))))))

(define-command "isearch-repeat-forward" "During a search, move to the next match"
  (lambda () (isearch--repeat! #f)))
(define-command "isearch-repeat-backward"
  "During a search, move to the previous match"
  (lambda () (isearch--repeat! #t)))

(catalog-meta! 'command "isearch-repeat-forward" 'domain 'targets 'effects '(write))
(catalog-meta! 'command "isearch-repeat-backward" 'domain 'targets 'effects '(write))

;; Emacs surface: the current match is the region (mark at one end, point
;; at the other), a miss says so, RET keeps the point and drops the region.
(define (isearch backward)
  (isearch-loop (if backward "I-search backward: " "I-search: ") backward
    (lambda (m q origin)
      ;; the LIVE direction, not the one this search started with: C-r
      ;; inside a forward search turns it around, and the point must land
      ;; at the end the reader now moves toward
      (let ((back (isearch--field 'backward)))
        (cond ((equal? q "") (set-mark! #f) (goto-char! origin))
              (m (if back
                     (begin (set-mark! (cadr m)) (goto-char! (car m)))
                     (begin (set-mark! (car m)) (goto-char! (cadr m)))))
              (else (message (string-append "Failing I-search: " q))))))
    (lambda (q origin) (set-mark! #f))
    (lambda (origin) (set-mark! #f))))

(define-command "isearch-forward" "Do incremental search forward"
  (lambda () (isearch #f)))
(define-command "isearch-backward" "Do incremental search backward"
  (lambda () (isearch #t)))

;;; --- replace ---------------------------------------------------------------
;;; Replacement uses the same literal search primitive as isearch. Collect
;;; matches before editing, then apply them from right to left so byte
;;; positions stay valid when the replacement has a different length.

(define (replace--matches buf old from acc)
  (let ((m #f))
    (with-current-buffer buf (lambda () (set! m (buffer-search old from))))
    (if m
        (replace--matches buf old (cadr m) (cons m acc))
        (reverse acc))))

(define (replace--all! buf old new from)
  (if (equal? old "")
      0
      (let ((matches (replace--matches buf old from '())))
        (for-each
          (lambda (m)
            (buffer-replace-range! buf (car m)
                                   (- (cadr m) (car m)) new))
          (reverse matches))
        (length matches))))

(define (replace--prompt prompt k)
  (minibuffer-read* prompt '()
    (list (list 'confirm k)
          (list 'cancel (lambda () (message "Quit"))))))

(define (replace--read-new buf old prompt k)
  (replace--prompt prompt k))

(define-command "replace-string" "Replace every literal occurrence of text"
  (lambda ()
    (let ((buf (current-buffer)))
      (replace--prompt "Replace string: "
        (lambda (old)
          (if (equal? old "")
              (message "Replace string cannot be empty")
              (replace--read-new buf old "Replace string with: "
                (lambda (new)
                  (let ((n 0))
                    (with-invoking-buffer
                      (lambda () (set! n (replace--all! buf old new 0))))
                    (message (string-append "Replaced "
                      (number->string n)
                      (if (= n 1) " occurrence" " occurrences"))))))))))))

(define-command "query-replace" "Replace literal text with confirmation"
  (lambda ()
    (let ((buf (current-buffer)) (origin (point)))
      (replace--prompt "Query replace: "
        (lambda (old)
          (if (equal? old "")
              (message "Query replace cannot search for an empty string")
              (replace--read-new buf old "Query replace with: "
                (lambda (new)
                  (let loop ((from origin) (n 0))
                    (let ((m #f))
                      (with-invoking-buffer
                        (lambda () (set! m (buffer-search old from))))
                      (if (not m)
                          (message (string-append "Replaced "
                            (number->string n)
                            (if (= n 1) " occurrence" " occurrences")))
                          (begin
                            (with-invoking-buffer
                              (lambda () (goto-char! (car m))))
                            (y-or-n
                              (string-append "Replace " old " with " new "? ")
                              (lambda ()
                                (buffer-replace-range! buf (car m)
                                  (- (cadr m) (car m)) new)
                                (loop (+ (car m) (string-byte-length new))
                                      (+ n 1)))
                              (lambda () (loop (cadr m) n)))))))))))))))

(catalog-meta! 'command "replace-string" 'domain 'editing 'effects '(write))
(catalog-meta! 'command "query-replace" 'domain 'editing 'effects '(write))

;;; --- files & buffers -------------------------------------------------------

;; Every owner can apply policy to one truly new buffer. Waking a dormant
;; buffer does not run these hooks because that buffer already has state.
(define *buffer-created-hooks* '())

(define (on-buffer-created! fn)
  (set! *buffer-created-hooks* (cons fn *buffer-created-hooks*))
  #t)

(define (buffer-created! name)
  (for-each (lambda (fn) (fn name)) *buffer-created-hooks*)
  name)

;; The other half. A dormant buffer is absent from (buffer-list), so a
;; pass over the open buffers cannot reach it while it sleeps, and it
;; missed every seam that ran meanwhile. This is where an owner catches
;; that buffer up. It runs on a desktop restore too, which is the same
;; event: state came back from a checkpoint, not from nothing.
(define *buffer-woken-hooks* '())

(define (on-buffer-woken! fn)
  (set! *buffer-woken-hooks* (cons fn *buffer-woken-hooks*))
  #t)

(define (buffer-woken! name)
  (for-each (lambda (fn) (fn name)) *buffer-woken-hooks*)
  name)

;; A new buffer inherits the directory of the buffer that made it (Emacs:
;; default-directory is buffer-local and copied from the current buffer at
;; creation). Without this, every non-file buffer — chat, shell, agent
;; thread, listing — answers "~" and C-x C-f from it loses your place.
(define raw-buffer-create buffer-create)
(define (buffer-create name)
  (let ((fresh (not (buffer-exists? name)))
        (new (not (buffer-known? name))))
    (raw-buffer-create name)
    (when (and fresh (boundp (quote default-directory)))
      (buffer-set-local! name 'default-directory (default-directory)))
    (when new (buffer-created! name))
    name))

;; remote buffers save over ssh, never through the local filesystem
(define (save-remote-buffer! bpath)
  (let ((hp (remote-parse bpath)))
    (let ((r (remote-write (car hp) (cadr hp) (buffer-text (current-buffer)))))
      (if (pair? r)   ; (error MSG)
          (message (string-append "Write failed: " (cadr r)))
          (begin
            (buffer-mark-saved! (current-buffer))
            (run-hooks 'after-save-hook)
            (message (string-append "Wrote " bpath)))))))

(define-command "save-buffer" "Save the current buffer to its file"
  (lambda ()
    (run-hooks 'before-save-hook)
    (let ((bpath (buffer-path (current-buffer))))
      (cond ((and bpath (remote-path? bpath)) (save-remote-buffer! bpath))
            ;; a rich chat's buffer text is a rendering (cards, folds, the
            ;; input marker); what belongs in the FILE is its identity plus
            ;; the portable transcript, which is what an opened .chat reads
            ((and bpath (boundp (quote chat-file-text))
                  (chat-file-text (current-buffer)))
             (write-file! bpath (chat-file-text (current-buffer)))
             (buffer-mark-saved! (current-buffer))
             (run-hooks 'after-save-hook)
             (message (string-append "Wrote " bpath)))
            (else (save-local-buffer!))))))

(define (save-local-buffer!)
    (let ((path (buffer-save!)))
      (cond
        (path
         (run-hooks 'after-save-hook)
         (message (string-append "Wrote " path)))
        ;; the buffer name IS an absolute path: the file name is known,
        ;; so save there and adopt the path — no prompt. C-x C-w is the
        ;; gesture that picks a different file.
        ((and (string-prefix? "/" (current-buffer))
              (not (remote-path? (current-buffer))))
         (let ((p (buffer-save! (current-buffer))))
           (unless (buffer-local (current-buffer) 'mode-name)
             (auto-mode p))
           (run-hooks 'after-save-hook)
           (message (string-append "Wrote " p))))
        ;; no file name at all: C-x C-s falls through to write-file
        (else (run-command "write-file")))))

;; write-file makes the buffer BECOME the file buffer: visit reads the
;; file back and auto-mode applies — a chat saved as .chat opens as a
;; chat, forever after C-x C-s just saves.
(define (write-buffer-to-file! old path0)
  (unless (equal? (string-trim path0) "")
    (let ((p (expand-path (normalize-file-input (string-trim path0)))))
      (if (equal? p old)
          ;; the buffer already carries this name: adopt, do not re-visit
          (begin
            (buffer-save! p)
            (run-hooks 'after-save-hook)
            (message (string-append "Wrote " p)))
          (let ((g (buffer-group old))
                (record (buffer-local old 'chat-wire-turns)))
            (write-file! p (or (chat-file-text old) (buffer-text old)))
            (visit p)
            (when g (buffer-set-local! (current-buffer) 'group g))
            (when record
              (buffer-set-local! (current-buffer) 'chat-wire-turns record))
            (buffer-kill! old)
            (run-hooks 'after-save-hook)
            (message (string-append "Wrote " p)))))))

;; A pathless buffer still has a useful name and mode. Use both when C-x C-w
;; asks for a destination. Outer stars are editor notation, not filename
;; characters. The mode supplies an extension only when the name has none
;; that the editor already recognizes.
(define (write-file-buffer-stem name)
  (let ((n (string-length name)))
    (let ((stem (if (and (> n 1)
                         (string-prefix? "*" name)
                         (string-suffix? "*" name))
                    (substring name 1 (- n 1))
                    name)))
      (if (equal? (string-trim stem) "") "untitled" stem))))

(define (write-file-mode-extension mode)
  (let loop ((entries *auto-mode-alist*))
    (cond ((or (not mode) (null? entries)) "")
          ((equal? mode (cadr (car entries))) (car (car entries)))
          (else (loop (cdr entries))))))

(define (write-file-default-path buf)
  (let ((path (buffer-path buf)))
    (if (and (string? path) (not (equal? path "")))
        path
        (let* ((stem (write-file-buffer-stem buf))
               (mode (buffer-local buf 'mode-name))
               (ext (if (auto-mode-for stem)
                        ""
                        (write-file-mode-extension mode))))
          (string-append (default-directory) stem ext)))))

(define-command "write-file" "Write the buffer to a file; the buffer becomes that file's buffer"
  (lambda ()
    (let ((old (current-buffer)))
      (read-file-name-initial (string-append "Write " old " to file: ")
        (write-file-default-path old)
        (lambda (p) (write-buffer-to-file! old p))))))

;; Save a buffer that is not the current one. save-buffer acts on the
;; current buffer, and it must: the remote, chat and no-file branches all
;; read it. So the save borrows the window and gives it back. A caller
;; that saves a whole set — save-some-buffers, project-kill-all — needs
;; exactly this and nothing more.
(define (save-buffer-named! b)
  (let ((here (current-buffer)))
    (switch-to-buffer! b)
    (run-command "save-buffer")
    (when (buffer-exists? here) (switch-to-buffer! here))))

;; Filename completion — pure Scheme over list-dir/string primitives.
;; A completion fn maps input -> (list new-input candidates).
;; Emacs' double-slash rule: "~/foo//etc" means "/etc" — typing an absolute
;; path over the default-directory prefill just works.
(define (normalize-file-input input)
  (let ((i (string-rindex input "//")))
    (if i
        (substring input (+ i 1) (string-length input))
        input)))

;; The host file primitive creates a buffer below the Scheme buffer-create
;; wrapper. Wrap it here so file buffers use the same creation event.
(define raw-find-file find-file)
(define (find-file path)
  (let* ((name (expand-path (normalize-file-input path)))
         (new (not (buffer-known? name)))
         (buf (raw-find-file name)))
    (when new
      (buffer-created! buf)
      ;; find-file is the quiet loading boundary used by agent read/edit
      ;; tools. A real user visit below promotes this canonical buffer.
      (when (boundp (quote buffer-context-only!))
        (buffer-context-only! buf)))
    buf))

(define (path-split input)
  (let ((idx (string-rindex input "/")))
    (if idx
        (list (substring input 0 (+ idx 1))
              (substring input (+ idx 1) (string-length input)))
        (list "" input))))

;; A candidate is a bare name and the annotator stats a path, so the
;; listing says which directory it listed. Every file prompt goes through
;; here, and nothing else has to know the annotator needs it.
;; A prompt shows eight rows at a time. Annotating every entry to show
;; eight is the file prompt's worst case: the annotator stats the file and
;; reads auto-mode-alist for each one, so 5000 entries cost 1.8s on the
;; :ui lane and the editor stops between keystrokes. Past this many
;; entries a person does not read the listing, they type to narrow it, so
;; hand over bare names and let the typing do the work. The core takes
;; plain strings wherever it takes (NAME HINT) pairs.
(define *file-annotate-limit* 500)

(define (file-candidates dir names)
  (set! *marginalia-file-dir* dir)
  (if (> (length names) *file-annotate-limit*)
      names
      (annotate 'file names)))

;; (file-complete input selected) -> (list new-input candidates)
;; selected: a candidate the user arrowed onto — inserted into the path,
;; directories auto-descend and list their contents.
(define (file-complete input0 selected)
  (if selected
      ;; insert the arrowed-onto candidate verbatim: directories descend to
      ;; their listing, files complete to themselves — no further chaining
      (let ((parts (path-split (normalize-file-input input0))))
        (let ((ni (string-append (car parts) selected)))
          (if (string-suffix? "/" selected)
              (list ni (file-candidates ni (list-dir ni)))
              (list ni (file-candidates (car parts) (list selected))))))
      (let ((input (normalize-file-input input0)))
        (let ((parts (path-split input)))
          (let ((dir (car parts))
                (base (cadr parts)))
            (let ((entries (list-dir dir)))
              (let ((matches (filter (lambda (e) (string-prefix? base e)) entries)))
                (if (null? matches)
                    (list input (file-candidates dir entries))
                    (let ((ni (string-append dir (common-prefix matches))))
                      (if (and (null? (cdr matches))
                               (string-suffix? "/" (car matches)))
                          ;; unique directory: descend and list (stop there —
                          ;; don't chain-complete into a lone file)
                          (list ni (file-candidates ni (list-dir ni)))
                          (list ni (file-candidates dir matches))))))))))))

;; live listing while typing (vertico-style) — but only re-list when the
;; DIRECTORY part changes; basename narrowing is the core's display filter.
;; Re-listing big directories on every keystroke stats thousands of files.
(define *file-nav-dir* #f)

(define (file-nav-change inp)
  (let ((dir (car (path-split (normalize-file-input inp)))))
    (if (equal? dir *file-nav-dir*)
        #t
        (begin
          (set! *file-nav-dir* dir)
          (minibuffer-set-candidates! (file-candidates dir (list-dir dir)))))))

;; ONE file prompt (dup #17): minibuffer with filename completion. INITIAL
;; chooses its starting directory and text. K receives the confirmed text
;; exactly as typed.
;; match-hint: the annotation names the mode the file opens in, so "dired"
;; narrows the listing to the directories and "elixir" to the .ex files.
(define (read-file-name-initial prompt initial k)
  (let* ((dd (default-directory))
         (seed (if (and (string? initial) (not (equal? initial ""))) initial dd))
         (seed-dir (car (path-split (normalize-file-input seed))))
         (dir (if (equal? seed-dir "") dd seed-dir)))
    (set! *file-nav-dir* dir)
    (let ((cands (file-candidates dir (list-dir dir))))
      (minibuffer-read* prompt cands
        (list (list 'complete file-complete)
              (list 'change file-nav-change)
              (list 'initial seed)
              ;; the icon leads the annotation, so the mode is the second
              ;; field: both must be in reach for "dired" to find a directory
              (list 'match-hint 2)
              (list 'style (prompt-style cands #f))
              (list 'confirm k))))))

(define (read-file-name prompt k)
  (read-file-name-initial prompt (default-directory) k))

;; Emacs' abbreviate-file-name: the home directory is "~". A modeline or a
;; prompt says the short form; the buffer keeps the absolute path.
(define (abbreviate-file-name path)
  (let ((home (getenv "HOME")))
    (cond ((not (string? path)) path)
          ((not (and (string? home) (> (string-length home) 1))) path)
          ((equal? path home) "~")
          ((string-prefix? (string-append home "/") path)
           (string-append "~" (substring path (string-length home)
                                         (string-length path))))
          (else path))))

;;; --- remote files (/ssh:host:/path — TRAMP-lite) ---------------------------
;;; Transport is two primitives (remote-read / remote-write; ssh underneath,
;;; so ~/.ssh/config aliases, agent and ControlMaster all apply). Everything
;;; else is policy here: a remote buffer is an ordinary file buffer whose
;;; path starts with /ssh: — modes, undo, revert (kill + re-visit) and
;;; desktop restore (re-fetch via visit) just work; only visit and
;;; save-buffer branch on the prefix.

(define (remote-path? p) (string-prefix? "/ssh:" p))

;; "/ssh:user@host:/path" -> (host path), #f if malformed
(define (remote-parse p)
  (let ((rest (substring p 5 (string-length p))))
    (let ((i (string-index rest ":")))
      (and i (> i 0)
           (list (substring rest 0 i)
                 (substring rest (+ i 1) (string-length rest)))))))

;; One ls -lA round-trip per directory feeds both list-dir and file-stat:
;; listing a dir re-fetches and caches, stat lookups ride the cache — so a
;; dired refresh costs one ssh call, not one per file.
(define *remote-ls-cache* '())   ; ((dir ((name (perms size date)) ...)) ...)
(define *remote-ls-errors* '())  ; ((dir message) ...)

(define (remote-dir-key d)       ; ".../log/" -> ".../log", but keep ":/" roots
  (if (and (string-suffix? "/" d) (not (string-suffix? ":/" d)))
      (substring d 0 (- (string-length d) 1))
      d))

(define (remote-ls! dir0)
  (let ((dir (remote-dir-key dir0)))
    (let ((hp (remote-parse dir)))
      (if (not hp)
          '()
          (let ((r (remote-list-dir (car hp) (cadr hp))))
            (if (and (pair? r) (symbol? (car r)))   ; (error MSG)
                (begin
                  (set! *remote-ls-errors*
                    (cons (list dir (cadr r))
                          (filter (lambda (e) (not (equal? (car e) dir)))
                                  *remote-ls-errors*)))
                  (message (cadr r))
                  '())
                (begin
                  (set! *remote-ls-errors*
                    (filter (lambda (e) (not (equal? (car e) dir)))
                            *remote-ls-errors*))
                  (set! *remote-ls-cache*
                    (cons (list dir r)
                          (filter (lambda (c) (not (equal? (car c) dir)))
                                  *remote-ls-cache*)))
                  r)))))))

(define (remote-ls-cached dir0)
  (let ((c (assoc (remote-dir-key dir0) *remote-ls-cache*)))
    (if c (cadr c) (remote-ls! dir0))))

(define (remote-sh! host cmd)
  (let ((r (remote-sh host cmd)))
    (if (pair? r) (begin (message (cadr r)) #f) #t)))

;; list-dir / file-stat / delete-file! / make-directory! grow a remote
;; branch under the same names and contracts — dired, file completion and
;; friends work on /ssh: paths without knowing it.
(define local-list-dir list-dir)
(define (list-dir dir)
  (if (remote-path? dir)
      (map car (remote-ls! dir))
      (local-list-dir dir)))

(define local-directory-entries directory-entries)

(define (remote-entry-type perms)
  (cond ((string-prefix? "d" perms) "directory")
        ((string-prefix? "l" perms) "symlink")
        ((string-prefix? "-" perms) "regular")
        (else "other")))

(define (remote-entry-info entry)
  (let* ((name (car entry))
         (st (cadr entry))
         (n (string->number (cadr st))))
    (list 'name name
          'type (remote-entry-type (car st))
          'bytes (if (number? n) n 0)
          'mtime 0
          'size (cadr st)
          'date (caddr st)
          'perms (car st))))

(define (directory-entries dir)
  (if (remote-path? dir)
      (let ((entries (remote-ls! dir))
            (failure (assoc (remote-dir-key dir) *remote-ls-errors*)))
        (if failure
            (list 'error (cadr failure))
            (map remote-entry-info entries)))
      (local-directory-entries dir)))

(define local-file-stat file-stat)
(define (file-stat p0)
  (if (remote-path? p0)
      (let ((parts (path-split (remote-dir-key p0))))
        (let ((entries (remote-ls-cached (car parts)))
              (base (cadr parts)))
          (let ((e (or (assoc base entries)
                       (assoc (string-append base "/") entries))))
            (if e (cadr e) (list "----------" "?" "?")))))
      (local-file-stat p0)))

(define local-delete-file! delete-file!)
(define (delete-file! p)
  (if (remote-path? p)
      (let ((hp (remote-parse p)))
        (let ((q (sh-quote (cadr hp))))
          ;; parity with the local primitive: files rm, dirs rmdir (empty only)
          (remote-sh! (car hp)
            (string-append "if [ -L " q " ]; then rm -- " q
                           "; elif [ -d " q " ]; then rmdir -- " q
                           "; else rm -- " q "; fi"))))
      (local-delete-file! p)))

(define local-make-directory! make-directory!)
(define (make-directory! p)
  (if (remote-path? p)
      (let ((hp (remote-parse p)))
        (remote-sh! (car hp) (string-append "mkdir -p -- " (sh-quote (cadr hp)))))
      (local-make-directory! p)))

(define local-rename-file! rename-file!)
(define (rename-file! source destination)
  (cond
    ((and (remote-path? source) (remote-path? destination))
     (let ((from (remote-parse source)) (to (remote-parse destination)))
       (if (not (equal? (car from) (car to)))
           (begin (message "Remote rename requires one host") #f)
           (and (remote-sh! (car from)
                  (string-append "mkdir -p -- "
                                 (sh-quote (path-directory (cadr to)))
                                 " && test ! -e " (sh-quote (cadr to))
                                 " && mv -- " (sh-quote (cadr from))
                                 " " (sh-quote (cadr to))))
                destination))))
    ((or (remote-path? source) (remote-path? destination))
     (message "Copy between local and remote paths first")
     #f)
    (else (local-rename-file! source destination))))

(define local-copy-file! copy-file!)
(define (copy-file! source destination)
  (cond
    ((and (remote-path? source) (remote-path? destination))
     (let ((from (remote-parse source)) (to (remote-parse destination)))
       (if (not (equal? (car from) (car to)))
           (begin (message "Remote copy requires one host") #f)
           (and (remote-sh! (car from)
                  (string-append "mkdir -p -- "
                                 (sh-quote (path-directory (cadr to)))
                                 " && test ! -e " (sh-quote (cadr to))
                                 " && cp -R -- " (sh-quote (cadr from))
                                 " " (sh-quote (cadr to))))
                destination))))
    ((or (remote-path? source) (remote-path? destination))
     (message "Local and remote copy is not available")
     #f)
    (else (local-copy-file! source destination))))

(define local-trash-file! trash-file!)
(define (trash-file! p)
  (if (remote-path? p)
      (let* ((hp (remote-parse p))
             (q (sh-quote (cadr hp))))
        (remote-sh! (car hp)
          (string-append
            "trash=\"$HOME/.local/share/Trash/files\"; mkdir -p -- \"$trash\"; "
            "base=$(basename -- " q "); target=\"$trash/$base\"; n=1; "
            "while [ -e \"$target\" ]; do target=\"$trash/$base.$n\"; n=$((n+1)); done; "
            "mv -- " q " \"$target\"")))
      (local-trash-file! p)))

(define local-set-file-mode! set-file-mode!)
(define (set-file-mode! p mode)
  (if (remote-path? p)
      (let ((hp (remote-parse p)))
        (remote-sh! (car hp)
          (string-append "chmod -- " (sh-quote mode) " " (sh-quote (cadr hp)))))
      (local-set-file-mode! p mode)))

(define local-touch-file! touch-file!)
(define (touch-file! p)
  (if (remote-path? p)
      (let ((hp (remote-parse p)))
        (remote-sh! (car hp) (string-append "touch -- " (sh-quote (cadr hp)))))
      (local-touch-file! p)))

(define local-make-symlink! make-symlink!)
(define (make-symlink! target link)
  (cond
    ((and (remote-path? target) (remote-path? link))
     (let ((from (remote-parse target)) (to (remote-parse link)))
       (if (not (equal? (car from) (car to)))
           (begin (message "Remote link requires one host") #f)
           (remote-sh! (car from)
             (string-append "ln -s -- " (sh-quote (cadr from))
                            " " (sh-quote (cadr to)))))))
    ((remote-path? link)
     (let ((to (remote-parse link)))
       (remote-sh! (car to)
         (string-append "ln -s -- " (sh-quote target)
                        " " (sh-quote (cadr to))))))
    ((remote-path? target)
     (message "A local link cannot target a remote path")
     #f)
    (else (local-make-symlink! target link))))

(define (remote-visit path)
  (if (buffer-exists? path)
      (begin
        (switch-to-buffer! path)
        (current-buffer))
      (let ((hp (remote-parse path)))
        (if (not hp)
            (begin
              (message "Remote path is /ssh:HOST:/PATH")
              #f)
            (let ((r (remote-read (car hp) (cadr hp))))
              (cond
                ((equal? r 'directory) (dired-open path))
                ((pair? r)   ; (error MSG) — unreachable host, unreadable file
                 (message (string-append path ": " (cadr r)))
                 #f)
                (else
                  (begin
                    ;; find-file names the buffer after the path and records
                    ;; it as the buffer's file (no such local file — empty)
                    (find-file path)
                    (when (string? r)
                      (buffer-insert! path 0 r)
                      (buffer-mark-saved! path))
                    (switch-to-buffer! path)
                    (goto-char! 0)
                    (auto-mode path)
                    (run-hooks 'find-file-hook)
                    (if (equal? r 'absent) (message "(New remote file)"))
                    (current-buffer)))))))))

(define (agent-edit-author? author)
  (and (string? author) (string-prefix? "agent:" author)))

(define (visit-apply-group! buf group existing)
  (when (and buf group)
    (if existing
        (buffer-add-group! buf group)
        (buffer-move-to-group! buf group))))

(define (visit path0 &optional group)
  (let* ((path (normalize-file-input path0))
         ;; A directory answers to one buffer name whatever the prompt
         ;; spelled: file completion offers "/dir/" and Dired names the
         ;; buffer "/dir". Reading existence from the raw path calls a
         ;; live buffer new, and a new buffer MOVES to the destination
         ;; group instead of joining it, which silently drops the
         ;; memberships it already had.
         (existing (or (buffer-known? path)
                       (and (boundp (quote dired-normalize-dir))
                            (file-directory? path)
                            (buffer-known? (dired-normalize-dir path)))))
         (buf
           (cond
             ((remote-path? path) (remote-visit path))
             ((file-directory? path) (dired-open path))
             (else
               (let ((file-buffer (find-file path)))
                 ;; An explicit destination joins before display. The derived
                 ;; current group therefore never sees a half-placed buffer.
                 (visit-apply-group! file-buffer group existing)
                 (switch-to-buffer! file-buffer)
                 (auto-mode path)
                 (run-hooks 'find-file-hook)
                 (current-buffer))))))
    ;; A user visit reveals the canonical buffer with all unsaved state.
    ;; Agent visits keep context-only buffers out of user-facing lists.
    (when (and buf
               (boundp (quote buffer-promote!))
               (not (agent-edit-author? (current-edit-author))))
      (buffer-promote! buf))
    ;; A named destination overrides the inherited frame group for new work.
    ;; Existing work adds the destination without losing its memberships.
    (visit-apply-group! buf group existing)
    buf))

;; The same open, without a window: the buffer is made, joins the
;; group, and takes its mode with the buffer current but not shown. A
;; peek opens this way, so the selected window never shows the file on
;; its way to the popup (find-file-noselect).
(define (visit-quietly path0 &optional group)
  (let* ((path (normalize-file-input path0))
         (existing (buffer-known? path)))
    (if (or (remote-path? path) (file-directory? path))
        (visit path group)
        (let ((file-buffer (find-file path)))
          (visit-apply-group! file-buffer group existing)
          (with-current-buffer file-buffer
            (lambda ()
              (auto-mode path)
              (run-hooks 'find-file-hook)))
          file-buffer))))

;; Compatibility name for packages and user config.
(define (visit-in-group path group) (visit path group))

;; A package supplies the prefix reader. Its callback receives the chosen
;; group. This keeps the prefix mechanism separate from file completion.
(define find-file-group-reader (lambda (receive) (receive (frame-group))))

(define (find-file-read &optional group)
  (read-file-name "Find file: "
    (lambda (path)
      (let* ((normalized (normalize-file-input path))
             (existing (buffer-known? normalized)))
        (visit normalized (if existing #f group))))))

(define-command "find-file" "Visit a file, prompting with filename completion"
  (lambda ()
    (if (current-prefix-arg)
        (find-file-group-reader find-file-read)
        (find-file-read (frame-group)))))
(catalog-meta! 'command "find-file" 'domain 'buffers 'effects '(write display))

;; the project a buffer belongs to, as a short name for the prompt.
;; project.scm supplies the real answer through this seam (dup #6);
;; without the package every buffer is projectless.
(define buffer-project-label (lambda (b) ""))

;; Optional workspace packages add one concise identity column to C-x b.
(define buffer-workspace-label (lambda (b) ""))

;; ...and as the ROOT, for context switching (a project is also a group)
(define buffer-project-root (lambda (b) ""))

;; what a buffer name means in a prompt: its mode, its group, its
;; project, then the file it is visiting. The group and project columns
;; show which buffers belong together, and the prompt matches on them
;; (match-hint), so a group or project name finds every member.
(marginalia! 'buffer
  (lambda (b)
    (list (buffer-icon b)
          (or (buffer-local b 'mode-name) "Fundamental")
          (buffer-group-summary b)
          (buffer-project-label b)
          (buffer-workspace-label b)
          ;; a chat has no file: its last column is the group's
          ;; metadata, so the group says what it is for
          (or (buffer-path b)
              (and (chat-buffer? b) (buffer-group b)
                   (group-meta (buffer-group b)))
              ""))))

;; ONE candidate shape for every buffer prompt (dup #6): the name, the
;; marginalia annotator supplies the rest, MRU-ordered — the recency
;; stream, whatever context each buffer lives in. Containers (groups)
;; ride ABOVE this stream in the switcher; see switch-to-buffer.
;; Internals (space-prefixed) stay hidden, as ibuffer hides them.
(define (buffer-candidates-all)
  (annotate 'buffer
    (filter (lambda (b)
              (and (not (string-prefix? " " b))
                   (not (buffer-context-only? b))))
            (buffer-list-mru))))

;; current excluded: first candidate = the buffer you just left, so
;; C-x b RET toggles between two buffers (Emacs buffer ring)
(define (buffer-candidates)
  (filter (lambda (c) (not (equal? (car c) (current-buffer))))
          (buffer-candidates-all)))

;; the buffer prompt's extension seam (dup #6). The command calls this
;; at prompt open with the base candidates; it returns (pool standing
;; pick). POOL is the full candidate list. STANDING is where you are
;; now, and therefore the one place RET must never mean. PICK sees the
;; choice first and returns #t when it handled it. chrome adds browser
;; tabs through this seam instead of redefining the command.
(define switch-buffer-source
  (lambda (cands)
    (list cands (current-buffer) (lambda (picked) #f))))

;; RET with nothing typed takes the FIRST candidate, so the top of the
;; pool IS the default — the prompt must advertise exactly that.
;; containers: every group answers as ONE candidate above the recency
;; stream — the container first, its buffers after. The label is
;; [name]; RET on it switches to the group and restores its layout.
(define (group-container-label g) (string-append "[" (group-label g) "]"))

;; a buffer's short name for a chip: the last path segment. A starred
;; name wrapping a path (*writing:/long/path.md*) shortens the same
;; way and keeps its closing star, so the chip still reads as special.
(define (buffer-short-label b)
  (if (string-contains? b "/")
      (car (reverse (string-split b "/")))
      b))

;; a container renders as its own row shape: kind "container", the
;; group's members as chips, the metadata as the annotation
(define (group-container-candidate g)
  (list (group-container-label g)
        (string-append "group  "
          (number->string (length (group-buffers g))) " buffers"
          (let ((m (group-meta g))) (if m (string-append "  ·  " m) "")))
        "container"
        (map buffer-short-label (take-n (group-buffers-mru g) 4))))

;; the pool locked to one group: its container row, then its buffers
(define (group-locked-pool g)
  (cons (group-container-candidate g)
        (annotate 'buffer
          (filter (lambda (b) (not (string-prefix? " " b)))
                  (group-user-buffers-mru g)))))

;; C-RET: the picked buffer's CONTEXT comes up — its group, or its
;; project materialized as one. A project is also a group: the first
;; context switch tags the project's open buffers and founds it.
(define (buffer-context-switch! b)
  (let ((focus (lambda ()
                 (let ((w (window-showing b)))
                   (if w (select-window! w) (switch-to-buffer! b)))))
        (bg (buffer-group b)))
    (cond
      (bg (switch-to-group! bg) (focus))
      (else
        (let ((root (buffer-project-root b)))
          (if (equal? root "")
              (begin
                ;; no context to enter — say so instead of a silent
                ;; plain switch that reads as "C-RET did nothing"
                (switch-to-buffer! b)
                (message (string-append b " has no group and no project — plain switch")))
              (begin
                (for-each (lambda (x)
                            (when (and (not (buffer-group x))
                                       (equal? (buffer-project-root x) root))
                              (buffer-set-local! x 'group root)))
                          (buffer-list))
                (switch-to-group! root)
                (focus))))))))

;; ONE history: buffers and groups woven by recency. A group switch
;; was itself an entry (mru-note-group!), so its card sits exactly
;; where history puts it — above the members its restore bumped. The
;; group's card and its buffers all match the group's name, so one
;; search shows the context and its contents together.
(define (switch-history-pool my-group)
  (let* ((bufs (filter (lambda (b)
                              (and (not (string-prefix? " " b))
                                   (not (buffer-context-only? b))))
                            (buffer-list-mru)))
         (annotated (annotate 'buffer bufs)))
    (let loop ((rows (mru-list)) (out '()))
      (if (null? rows)
          ;; buffers never woven (unvisited, or visited but filtered)
          ;; trail behind in their annotated order
          (let ((woven (reverse out)))
            (append woven
                    (filter (lambda (c) (not (member c woven))) annotated)))
          (let* ((r (car rows))
                 (kind (car r))
                 (name (car (cdr r))))
            (cond
              ((and (equal? kind "group")
                    (not (equal? name my-group))
                    (pair? (group-buffers name)))
               (loop (cdr rows) (cons (group-container-candidate name) out)))
              ((equal? kind "buffer")
               (let ((c (assoc name annotated)))
                 (loop (cdr rows) (if c (cons c out) out))))
              (else (loop (cdr rows) out))))))))

;; The minibuffer switcher. The editor's C-x b opens the modal switcher
;; (switch.scm); this prompt serves the surfaces that can only draw a
;; minibuffer — a browser page under the chrome extension.
(define-command "switch-to-buffer-prompt"
  "Switch to a buffer from a prompt; C-RET enters the buffer's group instead"
  (lambda ()
    (set! *mb-confirm-context* #f)
    (let* ((here (or (window-buffer (active-window)) (current-buffer)))
           (my-group (or (buffer-group here) (frame-local 'current-group)))
           ;; opening the switcher snapshots this group's arrangement:
           ;; wherever you go next, the way back is exact
           (_ (group-layout-save-if-shown! my-group))
           (groups (filter (lambda (g) (not (equal? g my-group))) (group-names)))
           (container-of (lambda (label)
                           (let loop ((gs groups))
                             (cond ((null? gs) #f)
                                   ((equal? (group-container-label (car gs)) label)
                                    (car gs))
                                   (else (loop (cdr gs)))))))
           (source (switch-buffer-source (switch-history-pool my-group)))
           (pool (car source))
           (standing (car (cdr source)))
           (pick (car (cdr (cdr source))))
           ;; history first: the pool is the one MRU stream — buffers
           ;; and group cards woven by recency. RET on a buffer row
           ;; switches the buffer; RET on a group card switches the
           ;; context. TAB still locks; C-x G still lists.
           (all (filter (lambda (c) (not (equal? (car c) standing))) pool))
           (fallback (if (null? all) here (car (car all))))
           ;; buffers the preview wakes. The prompt's close puts every one
           ;; nobody picked back to sleep — scrolling the list must not
           ;; leave forty live processes behind (the consult contract).
           (woken '())
           (sleep-woken! (lambda (keep)
                           (for-each (lambda (b)
                                       (unless (equal? b keep)
                                         (buffer-sleep! b)))
                                     woken)
                           (set! woken '()))))
      (minibuffer-read-preview
        (string-append "Switch to (default " fallback "): ")
        all
        ;; the invoking window live-previews the highlighted buffer; a
        ;; container or a tab leaves the window alone. known?, not exists?:
        ;; most of the pool is dormant — the primitive wakes a sleeper, and
        ;; the mode setup must follow here, because switch-to-buffer! later
        ;; sees the buffer live and skips its own restore
        (lambda (b)
          (when (buffer-known? b)
            (let ((sleeping (not (buffer-exists? b))))
              (window-preview-buffer! b)
              (when (and sleeping (buffer-exists? b))
                (restore-buffer-runtime! b)
                (set! woken (cons b woken))))))
        (lambda (name)
          (let* ((picked (if (equal? name "") fallback name))
                 (explicit (let ((x *mb-confirm-context*))
                             (set! *mb-confirm-context* #f)
                             x))
                 (g (container-of picked)))
            (cond (g (switch-to-group! g))
                  ((pick picked) #t)
                  ;; known?, not exists?: the pool is buffer-list-mru,
                  ;; and most of that list is dormant. exists? here sent
                  ;; every dormant pick to the found-a-group branch.
                  ((buffer-known? picked)
                   ;; RET is a BUFFER switch: one window changes and
                   ;; nothing else moves. The context switch — layout
                   ;; and all — is C-RET's job, and only C-RET's.
                   (if explicit
                       (buffer-context-switch! picked)
                       (switch-to-buffer! picked)))
                  (else
                   ;; nothing matches: RET founds a group named PICKED
                   ;; from the current windows. The preview may still
                   ;; occupy the invoking window — put back what stood
                   ;; there, so the group forms from the real windows.
                   (when (buffer-exists? here) (window-preview-buffer! here))
                   (group-found-from-windows! picked)))
            ;; the pick is on screen now; the sleep guard keeps awake
            ;; anything a group restore also put on screen
            (sleep-woken! picked)))
        ;; C-g: put back what you were looking at; sleep the rest
        (lambda ()
          (when (buffer-exists? here) (window-preview-buffer! here))
          (sleep-woken! #f))
        ;; you also know a buffer by its mode, its group, or its project:
        ;; those three fields all match what you type. The icon leads them,
        ;; so the count is four.
        4
        ;; the switcher is the power organiser: it opens as a centered
        ;; palette, not the bottom minibuffer line
        "palette"
        ;; this handler serves TAB and RET both (the complete contract):
        ;; RET hands it the highlighted candidate — answer it back as the
        ;; confirm value. TAB with no selection and an input that names
        ;; exactly one group locks the pool to that group's buffers.
        (lambda (input selected)
          (let ((lock (and (not (equal? input ""))
                           (let ((hits (filter (lambda (x)
                                                 (string-contains? (group-label x)
                                                                   input))
                                               groups)))
                             (and (pair? hits) (null? (cdr hits)) (car hits))))))
            (cond
              (selected (list selected all))
              ;; an input that names ONE group locks to it — the more
              ;; deliberate act wins over plain completion
              (lock (list "" (group-locked-pool lock)))
              ;; one candidate left: TAB takes it (Emacs completion)
              ((let ((st (minibuffer-state)))
                 (and st (= 1 (plist-get st 'total)) (minibuffer-selected)))
               (list (minibuffer-selected) all))
              (else #f))))))))

;; Packages can repair windows after the core releases a killed buffer.
;; The callback returns a thunk because its policy must inspect the old buffer
;; before the core removes it, then repair the surviving windows afterwards.
(define buffer-kill-raw!
  (if (boundp 'buffer-kill-raw!) buffer-kill-raw! buffer-kill!))
(define buffer-kill-repair (lambda (name) (lambda () #f)))

(define (buffer-kill! name)
  (let ((repair (buffer-kill-repair name)))
    (buffer-kill-raw! name)
    (when repair (repair))))

(define (kill-buffer-confirm! target done)
  ;; The high-level named-buffer kill: process policy, modified-file
  ;; confirmation, user feedback, and completion all live here.
  (let* ((finish (lambda (killed?)
                   (when done (done killed?))))
         (kill! (lambda ()
                  (if (process-running? target) (process-kill! target))
                  (buffer-kill! target)
                  (message (string-append "Killed " target))
                  (finish #t))))
    (cond
      ((not (buffer-known? target))
       (message (string-append "Buffer already gone: " target))
       (finish #f))
      ((and (buffer-path target) (buffer-modified? target))
       (y-or-n (string-append "Buffer " target " modified; kill anyway?")
               kill!
               (lambda ()
                 (message "Not killed")
                 (finish #f))))
      (else (kill!)))))

(define-command "kill-buffer" "Kill a buffer, defaulting to the current one"
  (lambda ()
    (let ((cur (current-buffer)))
      ;; current buffer is the default: first candidate, RET kills it
      (minibuffer-read (string-append "Kill buffer (default " cur "): ")
        (cons (list cur "current") (buffer-candidates))
        (lambda (name)
          (kill-buffer-confirm! (if (equal? name "") cur name)
                                (lambda (killed?) #t)))))))

;;; --- display-buffer & popups (popper) ----------------------------------------
;;; *display-buffer-alist* says WHERE a buffer goes. It is Emacs' alist of
;;; the same name, in the shape this editor needs: a list of
;;;
;;;   (PATTERN ACTION PARAMS)
;;;
;;; read in order, first match wins. PATTERN is a substring of the buffer
;;; name. ACTION is one of
;;;
;;;   'same    show it in the selected window
;;;   'popup   a side window: one per frame, reused, and it floats
;;;
;;; PARAMS is a plist, and every key has a default, so a rule says only
;;; what it wants to change:
;;;
;;;   'side   'right | 'left | 'top | 'bottom | 'center
;;;           default right, or bottom on compact frames
;;;           'center floats a fixed modal in the middle of the frame
;;;   'size   the share of the frame it takes     default one third
;;;
;;; A popup floats over the frame — see popup-float! for what that means
;;; and what it deliberately does not change. `C-\`` toggles it and
;;; `C-M-\`` settles it into the layout, on the side it already floats on.

(define *window-third* (/ 1 3))

(define *display-buffer-defaults* (list 'side 'right 'size *window-third*))

;; Packages can make the default responsive without changing explicit display
;; rules. layouts.scm chooses bottom on compact frames and right otherwise.
(define popup-default-side (lambda () 'right))

(define *display-buffer-alist*
  (list (list "*shell*" 'popup '())
        (list "*opencode" 'popup '())
        (list "*Messages*" 'popup '())
        (list "*llm*" 'popup '())))

;; PARAMS is optional, so every rule written before the params existed
;; still reads the same and takes the defaults
(define (add-display-rule! pattern action &optional params)
  (set! *display-buffer-alist*
    (cons (list pattern action (if params params '()))
          *display-buffer-alist*)))

(define (display-rule-for name)
  (let loop ((rules *display-buffer-alist*))
    (cond ((null? rules) (list name 'same '()))
          ((string-contains? name (car (car rules))) (car rules))
          (else (loop (cdr rules))))))

(define (display-action-for name) (cadr (display-rule-for name)))

;; a rule's own value, else the default for that key
(define (display-rule-param name key)
  (let* ((rule (display-rule-for name))
         (rest (cdr (cdr rule)))
         (params (if (null? rest) '() (car rest)))
         (v (plist-get params key)))
    v))

(define (display-param name key)
  (or (display-rule-param name key)
      (plist-get *display-buffer-defaults* key)))

;; frame-local policy state: values keyed by the selected frame — each
;; browser gets its own popup, its own ibuffer home window. Pruned when a
;; frame is deleted.
(define *frame-locals* '())   ; ((frame ((key val) ...)) ...)

(define (frame-local-in frame key)
  (let ((fr (assoc frame *frame-locals*)))
    (if fr
        (let ((kv (assoc key (cadr fr))))
          (if kv (cadr kv) #f))
        #f)))

(define (frame-local key)
  (frame-local-in (selected-frame) key))

(define (set-frame-local! key val)
  (let* ((frame (selected-frame))
         (fr (assoc frame *frame-locals*))
         (locals (if fr (cadr fr) '()))
         (rest (filter (lambda (e) (not (equal? (car e) frame))) *frame-locals*))
         (others (filter (lambda (e) (not (equal? (car e) key))) locals)))
    (set! *frame-locals* (cons (list frame (cons (list key val) others)) rest))))

(define (prune-frame-locals!)
  (let ((live (frame-list)))
    (set! *frame-locals*
      (filter (lambda (e) (member (car e) live)) *frame-locals*))))

;; The window that floats. The frame local lives in memory and dies with
;; the daemon, but the floating class is a buffer-local and comes back
;; with the desktop — so a restored popup is still a popup, and `C-\`` and
;; `C-M-\`` still reach it. Read the class when the local has nothing
;; live to say.
;; the class carries the side too — "popup popup-right" — so read it as
;; the prefix it is. Read for equality, this never matched, the frame
;; local was the only answer, and a restored popup split the frame a
;; second time every time you opened it.
(define (popup--class? buf)
  (let ((c (buffer-local buf 'window-class)))
    (and c (string-prefix? "popup" c))))

(define (popup--by-class)
  (let loop ((ws (window-list)))
    (cond ((null? ws) #f)
          ((popup--class? (cadr (car ws))) (car (car ws)))
          (else (loop (cdr ws))))))

(define (popup-window)
  (let ((w (frame-local 'popup-window)))
    (if (and w (window-exists? w) (popup--class? (window-buffer w)))
        w
        (popup--by-class))))

(define (popup-buffer)
  (or (frame-local 'popup-buffer)
      (let ((w (popup--by-class)))
        (and w (cadr (assoc w (window-list)))))))

(define (window-exists? id)
  (assoc id (window-list)))

;; a leftover popup that became the sole window (C-x 1 from inside it)
;; is not a popup anymore — treat it as closed so display-buffer splits
(define (popup-open?)
  (and (popup-window)
       (window-exists? (popup-window))
       (not (null? (cdr (window-list))))))

;; Where the popup came from. A popup is a visit, not a move. Closing it
;; restores work windows changed by a preview. The return record is
;; (WINDOW BUFFER POINT). The work record is ((WINDOW BUFFER) ...).
;;
;; Read the buffer from the window, never from (current-buffer): a popup
;; can open from inside a prompt, and (current-buffer) answers with the
;; minibuffer while one is open.
;;
;; The record lives in memory and dies with the daemon. A popup restored
;; from the desktop has nothing to go back to, so its close only closes.
(define (popup-remember!)
  (let ((w (active-window)))
    (unless (popup-open?)
      (set-frame-local! 'popup-work (window-list))
      (set-frame-local! 'popup-layout (window-tree)))
    ;; a popup that shows the next popup does not move you: the window
    ;; you came from is still the one the first popup remembered
    (when (not (equal? w (popup-window)))
      (set-frame-local! 'popup-return
        (list w (window-buffer w) (buffer-point (window-buffer w)))))))

(define (popup-saved-layout)
  (or (frame-local 'popup-layout)
      (let ((buf (popup-buffer)))
        (and buf (buffer-local buf 'popup-return-layout)))))

(define (popup-forget!)
  (let ((buf (popup-buffer)))
    (when (and buf (buffer-known? buf))
      (buffer-set-local! buf 'popup-return-layout #f)))
  (set-frame-local! 'popup-return #f)
  (set-frame-local! 'popup-work #f)
  (set-frame-local! 'popup-layout #f))

;; Restore only live buffers into surviving work windows. This preserves window
;; ids and ratios. It also does not recreate a buffer that ibuffer killed.
(define (popup-work-restore!)
  (for-each
    (lambda (row)
      (let ((w (car row)) (buf (cadr row)))
        (when (and (window-exists? w) (buffer-exists? buf)
                   (not (equal? (window-buffer w) buf)))
          (select-window! w)
          (switch-to-buffer! buf))))
    (or (frame-local 'popup-work) '())))

(define (popup-layout-live? layout)
  (and layout
       (null? (filter (lambda (buf) (not (buffer-exists? buf)))
                      (window-tree-buffers layout)))))

;; Go back. The window can be gone (you split or closed it from inside
;; the popup) and the buffer can be dead (ibuffer killed it) — each step
;; asks before it acts, and a step that cannot run leaves the rest alone.
(define (popup-return!)
  (let ((r (frame-local 'popup-return)))
    (popup-forget!)
    (when (and r (window-exists? (car r)))
      (select-window! (car r))
      (let ((buf (cadr r)))
        (when (and buf (buffer-exists? buf))
          (when (not (equal? (window-buffer (car r)) buf))
            (switch-to-buffer! buf))
          (goto-char! (caddr r)))))))

;; Closing the popup is three things, every time and in this order: the
;; buffer stops floating, the window goes, and you come back. You come
;; back only if you were IN the popup — `C-\`` from another window
;; dismisses it and leaves your focus alone.
;; The window is read ONCE. popup-window can answer from the class, and
;; the first step clears the class — read again after it, the answer is
;; #f and the window never goes.
;; Dismiss the popup's buffer: the one under it comes back, or the popup
;; closes when nothing waits. `q` in a listing and the toggles use this;
;; the popup toggle closes the whole popup.
(define (popup-dismiss!)
  (let loop ((stack (popup-stack)))
    (cond ((null? stack)
           (set-frame-local! 'popup-stack '())
           (popup-close!))
          ((buffer-known? (car stack))
           (set-frame-local! 'popup-stack (cdr stack))
           (set! *popup-dismissing* #t)
           (popup-show (car stack))
           (set! *popup-dismissing* #f))
          (else (loop (cdr stack))))))

(define (popup-close!)
  (set-frame-local! 'popup-stack '())
  (let* ((w (popup-window))
         (mine? (equal? (active-window) w))
         (buf (and w (window-buffer w)))
         (focus (active-window))
         (work (frame-local 'popup-work))
         (layout (popup-saved-layout)))
    ;; the buffer stops floating the moment it stops being the popup, or
    ;; it would float again in an ordinary window
    (when buf (popup-float! buf #f))
    (set-frame-local! 'popup-window #f)
    (cond
      ((pair? work)
       (when w (delete-window-id! w))
       (popup-work-restore!)
       (if mine?
           (popup-return!)
           (begin
             (when (window-exists? focus) (select-window! focus))
             (popup-forget!))))
      ((popup-layout-live? layout)
       (popup-forget!)
       (window-tree-set! layout))
      (else
       (when w (delete-window-id! w))
       (if mine? (popup-return!) (popup-forget!))))))

;; A popup FLOATS, and only visibly: it stays an ordinary window in the
;; tree, so every window command still reaches it. The class takes its
;; split out of the flow, so the window it covers keeps the whole frame
;; underneath. SIDE is the edge it floats against, or #f to stop
;; floating — `C-M-\`` passes #f and the popup becomes an ordinary split,
;; which is popper's toggle-type under popper's key.
;; In the popup, M-<left>, M-<right>, M-<up>, and M-<down> move it to
;; that edge. The keys are the popup's, not the buffer's: they go in
;; when the buffer floats and out when it stops, and the mode setup then
;; gives the buffer its own keys back.
(define *popup-move-keys*
  '(("M-<left>" "popup-move-left") ("M-<right>" "popup-move-right")
    ("M-<up>" "popup-move-up") ("M-<down>" "popup-move-down")))

(define (popup-keys! name floating?)
  (for-each (lambda (k)
              (if floating?
                  (local-set-key* name (car k) (cadr k))
                  (local-unset-key* name (car k))))
            *popup-move-keys*)
  (buffer-set-local! name 'popup-keys (and floating? #t)))

(define (popup-float! name side &optional size)
  (let ((had-keys (buffer-local name 'popup-keys)))
    (buffer-set-local! name 'window-class
      (and side (string-append "popup popup-" (symbol->string side))))
    ;; the share is a number, and CSS cannot read a Scheme list — hand it
    ;; over as a custom property the stylesheet already reads
    (buffer-set-local! name 'window-style
      (and side size
           (string-append "--popup-size:" (number->string (* 100 size)) "%")))
    (cond (side (popup-keys! name #t))
          (had-keys
           (popup-keys! name #f)
           ;; the buffer's own M-arrows come back with its mode. Not for a
           ;; peek: it is read-only, it dies when replaced, and a mode
           ;; setup is the one thing here that could move anything.
           (when (and (buffer-exists? name)
                      (not (and (boundp 'peek-buffer?) (peek-buffer? name))))
             (restore-buffer-runtime! name))))))

(define (popup-move! side)
  (let ((buf (current-buffer)))
    (if (not (and (popup-open?) (equal? (active-window) (popup-window))))
        (message "Not in the popup")
        (begin
          ;; the side a buffer was moved to is the side it opens on next
          (buffer-set-local! buf 'popup-side side)
          (popup-float! buf side (display-param buf 'size))
          (message (string-append "Popup on the " (symbol->string side)))))))

(define-command "popup-move-left" "Float the popup against the left edge"
  (lambda () (popup-move! 'left)))
(define-command "popup-move-right" "Float the popup against the right edge"
  (lambda () (popup-move! 'right)))
(define-command "popup-move-up" "Float the popup against the top edge"
  (lambda () (popup-move! 'top)))
(define-command "popup-move-down" "Float the popup against the bottom edge"
  (lambda () (popup-move! 'bottom)))

;; The popup FLOATS: its class says which edge, and its place in the
;; tree does not show. So the new window is always SECOND, whatever the
;; side, and the window it covers keeps its id and its place. A swap
;; into first place for the left and the top moved the covered window
;; to the other side of its half and carried the ids with the buffers.
;; popup-bufferize swaps when the popup becomes a real window.
(define (popup--split-for side size)
  (split-window! (if (or (equal? side 'top) (equal? side 'bottom)) 'v 'h)
                 (- 1 size))
  (other-window!))

;; the side a floating buffer wears, from its class, or #f
(define (popup-side-of buf)
  (let ((c (and buf (buffer-local buf 'window-class))))
    (and c (string-prefix? "popup popup-" c)
         (string->symbol (substring c (string-length "popup popup-") (string-length c))))))

;; The popup shows one buffer at a time. A buffer shown over another
;; keeps it underneath (popper's stack): dismiss the top one and the one
;; under it comes back; close the popup and the stack empties.
(define *popup-dismissing* #f)

(define (popup-stack) (or (frame-local 'popup-stack) '()))

;; a peek is a look: replaced, it is killed, so it never waits on the
;; stack. Dead names are pruned as the stack is written, so it holds
;; live buffers only and cannot grow past them.
(define (popup-stack-push! name)
  (unless (and (boundp 'peek-buffer?) (peek-buffer? name))
    (set-frame-local! 'popup-stack
      (cons name (filter (lambda (b) (and (not (equal? b name)) (buffer-known? b)))
                         (popup-stack))))))

(define (popup-stack-drop! name)
  (set-frame-local! 'popup-stack
    (remove (lambda (b) (equal? b name)) (popup-stack))))

(define (popup-show-on name side size)
    ;; before the focus moves: this is the place you come back to
    (popup-remember!)
    (let ((old (popup-buffer))
          (layout (popup-saved-layout)))
      (when (and old (not (equal? old name)) (buffer-known? old))
        (buffer-set-local! old 'popup-return-layout #f)
        ;; the buffer this one covers waits underneath
        (when (and (popup-open?) (not *popup-dismissing*))
          (popup-stack-push! old)))
      (popup-stack-drop! name)
      (set-frame-local! 'popup-buffer name)
      (when layout (buffer-set-local! name 'popup-return-layout layout)))
    (popup-float! name side size)
    (if (popup-open?)
        (let ((was (window-buffer (popup-window))))
          (select-window! (popup-window))
          (switch-to-buffer! name)
          ;; the buffer this one replaces stops floating: the class is a
          ;; buffer-local, and a buffer that kept it floated in every
          ;; window it was shown in after
          (when (and was (not (equal? was name)) (buffer-exists? was))
            (popup-float! was #f)))
        (begin
          (popup--split-for side size)
          (set-frame-local! 'popup-window (active-window))
          (switch-to-buffer! name))))

;; where the popup floats: the rule's side, else the side the buffer was
;; last moved to, else the default, which is the right edge
;; Show NAME in the popup without moving the selection: a preview takes
;; no focus. The popup window's buffer is set in place; a new popup is
;; split, filled, and the selection goes back where it was, in one
;; step. A quiet popup records no return place, no work windows, and no
;; layout: nothing is restored when it closes, because nothing moved.
;; The restores are for a popup you entered, and they carried every
;; window's point back to the moment the popup opened.
(define (popup-show-quietly name side size)
  (let ((me (active-window)))
    (let ((old (popup-buffer)))
      (when (and old (not (equal? old name)) (buffer-known? old))
        (when (and (popup-open?) (not *popup-dismissing*))
          (popup-stack-push! old)))
      (popup-stack-drop! name)
      (set-frame-local! 'popup-buffer name))
    (popup-float! name side size)
    (if (popup-open?)
        (let* ((w (popup-window))
               (was (window-buffer w)))
          (window-set-buffer! w name)
          (when (and was (not (equal? was name)) (buffer-exists? was))
            (popup-float! was #f)))
        (begin
          (popup--split-for side size)
          (let ((w (active-window)))
            (set-frame-local! 'popup-window w)
            (window-set-buffer! w name)
            (select-window! me))))
    (window-state-changed!)
    (popup-window)))

(define (popup-show name)
  (popup-show-on name
    (or (display-rule-param name 'side)
        (buffer-local name 'popup-side)
        (popup-default-side))
    (display-param name 'size)))

;; Force any buffer into the popup without adding a durable display rule.
;; Agents use this when a result is temporary. The popup toggle dismisses it.
(define (display-buffer-popup! name &optional side size)
  (group-layout-save-before-cover! name)
  (popup-show-on name
    (or side (popup-default-side))
    (or size (plist-get *display-buffer-defaults* 'size))))

(define (display-buffer name)
  ;; a board, a listing, any surface from outside the group takes its
  ;; pane through here. Record the group's arrangement BEFORE the
  ;; cover, or a switch made FROM the board has no way back — the
  ;; capture rule below only fires from a member buffer, and the board
  ;; is not one.
  (group-layout-save-before-cover! name)
  (if (equal? (display-action-for name) 'popup)
      (popup-show name)
      (switch-to-buffer! name)))

;; show NAME in a window other than the selected one, point staying put —
;; the display-buffer contract behind Emacs previews (occur/grep/consult):
;; windows are never remembered, they are chosen HERE, at display time —
;; reuse a window already showing NAME, else the first other window, else
;; split. Returns the window used.
(define (display-buffer-other-window! name)
  ;; window-set-buffer! takes a window id. switch-to-buffer! cannot do this
  ;; job: it answers a frame buffer-context before it looks at a window, so
  ;; an agent asked to show a file moved only its own context and the window
  ;; never changed. Nothing here selects a window, so point stays put.
  (let* ((me (active-window))
         (showing (window-showing name))
         (reuse (if (and showing (not (equal? showing me))) showing #f))
         (target (or reuse
                     (other-window-id me)
                     (begin (split-window! 'h 0.5) (other-window-id me)))))
    (when target
      ;; a buffer the user can see must be a buffer the user can switch to
      (when (boundp 'buffer-promote!) (buffer-promote! name))
      (window-set-buffer! target name))
    target))

;;; --- peek -----------------------------------------------------------------------
;;; A peek shows a buffer to look at it, without adopting it into the
;;; workspace. RET on a row peeks; RET again keeps. The rules:
;;;
;;;   ONE peek at a time. The next peek replaces the last one. A buffer
;;;     that a peek MADE is killed when it is replaced. A buffer that
;;;     existed before the peek is only shown, never killed.
;;;   THE PEEK WINDOW is the popup. A peek is a look, and the popup is
;;;     where a look goes; the windows stay as they are. A popup buffer
;;;     of its own waits under the peek and comes back when it goes.
;;;   A PEEK IS READ-ONLY (peek-mode, a minor mode): a stray key changes
;;;     nothing, and q dismisses it.
;;;   OPEN is M-RET on the row (peek-open!): the mark goes, the popup
;;;     gives the buffer up, and the selected window shows it as a visit
;;;     would. KEEP alone is M-x keep-buffer, or a change from outside
;;;     the keyboard.
;;;   A replaced peek leaves a row in RECENT. The switcher lists recent
;;;     below the live buffers, and RET there peeks it again.
;;;
;;; The mark is the minor mode, and it is saved with the buffer: a peek
;;; on screen at a restart comes back as a peek, in the popup, read-only.

;; The mode. A peek is read-only: a look changes nothing, and the
;; read-only keymap gives it q. The setup runs on enable and again on a
;; restore, so it records the buffer's own state once; keep puts that
;; state back.
(register-minor-mode! "peek-mode"
  (lambda (buf)
    (unless (buffer-local buf 'peek-own-read-only)
      (buffer-set-local! buf 'peek-own-read-only
        (if (buffer-read-only? buf) 'yes 'no)))
    (buffer-set-read-only! buf #t))
  (lambda (buf)
    (buffer-set-read-only! buf (equal? (buffer-local buf 'peek-own-read-only) 'yes))
    (buffer-set-local! buf 'peek-own-read-only #f)))

(mode-doc! "peek-mode"
  "A look at a buffer without keeping it: read-only, in the popup. q dismisses it; M-RET on the row opens it as your own.")

(define (peek-buffer? name)
  (and (string? name) (buffer-exists? name) (minor-mode-on? name "peek-mode")))

(define (peek-buffers) (filter peek-buffer? (buffer-list)))

;;; recent: what a peek showed and let go. An entry is
;;; (LABEL KIND KEY TIME): KIND names the reviver, KEY is what it needs.

(define *peek-recent* '())
(define *peek-recent-max* 50)

(persist-global! 'peek-recent
  (lambda () *peek-recent*)
  (lambda (v) (set! *peek-recent* (if (or (pair? v) (null? v)) v '()))))

(define (peek-recent-find key)
  (let ((hits (filter (lambda (x) (equal? (nth 2 x) key)) *peek-recent*)))
    (and (pair? hits) (car hits))))

;; how NAME comes back: a file by its path, a page by its URL, a
;; directory by its dir. #f for a buffer nothing can rebuild.
(define (peek-recent-entry name)
  (let ((path (buffer-path name))
        (url (buffer-local name 'browse-url))
        (dir (buffer-local name 'dired-dir)))
    (cond ((and (string? url) (not (equal? url "")))
           (list name 'browse url (current-time)))
          ((and (string? dir) (not (equal? dir "")))
           (list name 'dired dir (current-time)))
          ((and (string? path) (not (equal? path "")))
           (list name 'file path (current-time)))
          (else #f))))

(define (peek-remember! name)
  (let ((e (peek-recent-entry name)))
    (when e
      (set! *peek-recent*
        (take-n (cons e (filter (lambda (x) (not (equal? (nth 2 x) (nth 2 e))))
                                *peek-recent*))
                *peek-recent-max*)))))

(define (peek-forget-recent! key)
  (set! *peek-recent*
    (filter (lambda (x) (not (equal? (nth 2 x) key))) *peek-recent*)))

;; a recent row comes back as a peek: the same look, the same choice
(define (peek-revive! entry)
  (let ((kind (nth 1 entry))
        (key (nth 2 entry)))
    (cond ((and (equal? kind 'browse) (boundp 'web--tab-for!))
           (peek! (web--buffer-for key) (lambda () (web--tab-for! key))))
          ((equal? kind 'dired)
           (peek! key (lambda () (dired-open key))))
          ((equal? kind 'file)
           (peek-file! key))
          (else #f))))

;; let NAME go: remember it, kill it. A buffer with a live process is
;; never a peek, so nothing here stops one.
(define (peek-drop! name)
  (when (peek-buffer? name)
    (peek-remember! name)
    (buffer-kill! name)))

;; every peek but KEEP-ONE and the buffer the reader is in goes
(define (peek-drop-others! keep-one)
  (let ((here (current-buffer)))
    (for-each (lambda (b)
                (unless (or (equal? b keep-one) (equal? b here)
                            ;; a peek the reader put in a second window
                            ;; is theirs to look at
                            (window-showing b))
                  (peek-drop! b)))
              (peek-buffers))))

;; The peek slot is the window the last peek used, per frame. It is
;; remembered, not derived: a peek of a buffer that already existed
;; leaves no mark behind, and the next peek must still land in the
;; same window instead of splitting again. Keeping the buffer in the
;; slot releases the window (peek-keep!).
;; show NAME as the peek: in the popup, always. A peek is a look, and
;; the popup is where a look goes; the windows stay as they are, and the
;; selected window and its point stay. The buffer the popup showed
;; stops floating; a popup buffer of its own (the messages) waits under
;; the peek and comes back when the peek is dismissed. Returns the popup
;; window.
;; the side away from the window the peek was asked from: the popup
;; never covers the listing. A window on the right half of the frame
;; gets the popup on the left; any other, the right.
(define (peek-side-away-from win)
  (let ((r (assoc win (window-rects))))
    (if (and r (> (+ (nth 2 r) (* 0.5 (nth 4 r))) 0.5)) 'left 'right)))

;; the side is chosen once, when the popup opens; a peek that replaces
;; another keeps the side the popup has, so the popup never flips
;; A peek is a preview: it takes no focus. The popup shows it without
;; a selection change, and the focus commands pass it by.
(define (peek-show! name)
  (let* ((me (active-window))
         (old (and (popup-open?) (popup-buffer)))
         (side (or (and old (popup-side-of old)) (peek-side-away-from me)))
         (win (popup-show-quietly name side (plist-get *display-buffer-defaults* 'size))))
    (set-frame-local! 'peek-window win)
    ;; what the look put in the popup, by name: a buffer that existed
    ;; before wears no mode, and q must still take it away
    (set-frame-local! 'peek-shown name)
    (peek-drop-others! name)
    win))

;; a window the focus commands may land on: not a peek's
(define (window-focusable? w)
  (let ((b (window-buffer w)))
    (not (and b (peek-buffer? b)))))

;; the peek verb. OPEN makes or finds the buffer and returns its name.
;; KNOWN is the name it will have, so "did the peek make it" is answered
;; before OPEN runs: a buffer that was known stays a real buffer. OPEN
;; may move the selected window (visit does); the window is put back.
;; A quiet popup is transparent to the point: nothing in this path
;; selects a window. OPEN opens the buffer, best without a window
;; (visit-quietly); an opener that showed it in the selected window has
;; the listing put back there, in place, with no selection change.
(define (peek! known open)
  (let* ((existed? (and (string? known) (buffer-known? known) #t))
         (me (active-window))
         (here (current-buffer))
         (buf (open)))
    (when (and (string? buf) (not (equal? buf here)))
      (unless (equal? (window-buffer me) here)
        (window-preview-buffer! here me))
      (unless existed? (enable-minor-mode! buf "peek-mode"))
      (peek-show! buf))
    buf))

;; a file, peeked: the one opener every listing of files shares
(define (peek-file! path)
  (peek! path (lambda () (visit-quietly path))))

;; RET twice: the first press peeks KNOWN, the second keeps it and goes
;; there. Returns 'peek or 'keep.
(define (peek-or-keep! known open)
  (if (and (string? known) (peek-buffer? known) (window-showing known))
      (begin
        (peek-keep! known)
        (select-window! (window-showing known))
        'keep)
      (begin (peek! known open) 'peek)))

;; RET on a row: peek KNOWN, or open it when it is the peek on screen
(define (peek-or-open! known open)
  (if (and (string? known) (peek-buffer? known) (window-showing known))
      (peek-open! known open)
      (begin (peek! known open) 'peek)))

;; the buffer the last look put in the popup, while the popup still
;; shows it: a peek, or a buffer that existed before and only shows
(define (peek-shown)
  (let ((b (frame-local 'peek-shown)))
    (and b (popup-open?) (equal? (popup-buffer) b) b)))

;; dismiss the look on screen: the popup gives the buffer up, and a
;; buffer the peek made goes to recent. #t when there was one.
(define (peek-dismiss!)
  (let ((shown (dedupe-names
                 (append (let ((b (peek-shown))) (if b (list b) '()))
                         (filter window-showing (peek-buffers))))))
    (for-each (lambda (p)
                (when (and (popup-open?) (equal? (popup-buffer) p))
                  (popup-dismiss!))
                (when (peek-buffer? p) (peek-drop! p)))
              shown)
    (set-frame-local! 'peek-shown #f)
    (pair? shown)))

;; any work window that is not ME: the popup is not one
(define (other-work-window-id me)
  (let ((popup (and (popup-open?) (popup-window))))
    (let loop ((ws (window-list)))
      (cond ((null? ws) #f)
            ((and (not (equal? (car (car ws)) me))
                  (not (equal? (car (car ws)) popup)))
             (car (car ws)))
            (else (loop (cdr ws)))))))

;; show NAME as your own beside the listing, never on top of it: the
;; other work window when there is one, else a split beside this one
;; (Emacs find-file-other-window). Selects the window it used.
(define (show-in-other-work-window! name)
  (let* ((me (active-window))
         (w (other-work-window-id me)))
    (if w
        (begin (select-window! w) (switch-to-buffer! name))
        (begin (split-window! 'h 0.5) (other-window!) (switch-to-buffer! name)))
    (active-window)))

;; open KNOWN as a buffer of your own, beside the listing: the popup
;; gives it up, the mark goes, and the other work window shows it. Not a
;; peek yet, it opens the same way.
(define (peek-open! known open)
  (let ((me (active-window)))
    (when (and (string? known) (peek-buffer? known))
      (peek-keep! known)
      (when (and (popup-open?) (equal? (popup-buffer) known))
        (popup-dismiss!))
      (when (window-exists? me) (select-window! me)))
    (let ((buf (if (and (string? known) (buffer-known? known)) known (open))))
      (when (string? buf)
        ;; an opener may have shown it here; the listing takes its window back
        (when (and (window-exists? me) (not (equal? (window-buffer me) (current-buffer))))
          #t)
        (show-in-other-work-window! buf)))
    'open))

(define (peek-keep! name)
  (when (peek-buffer? name)
    (disable-minor-mode! name "peek-mode")
    ;; a kept buffer keeps its window: the slot moves on
    (let ((w (frame-local 'peek-window)))
      (when (and w (equal? (window-buffer w) name))
        (set-frame-local! 'peek-window #f)))
    (peek-forget-recent! (or (buffer-path name)
                             (buffer-local name 'browse-url)
                             (buffer-local name 'dired-dir)
                             name))
    (message (string-append "kept " name))))

;; an edit keeps: a file you typed in is yours. A listing reports itself
;; as modified and has no path, so only a file answers here.
(define (peek-keep-if-edited! b)
  (when (and (peek-buffer? b) (buffer-path b) (buffer-modified? b))
    (peek-keep! b)))

(add-hook! 'post-command-hook
  (lambda () (peek-keep-if-edited! (current-buffer))))

(define-command "keep-buffer" "Keep this peek: it becomes an ordinary buffer"
  (lambda ()
    (let ((b (current-buffer)))
      (if (peek-buffer? b)
          (peek-keep! b)
          (message "not a peek")))))

(define-command "peek-recent" "Peek a buffer you looked at and let go"
  (lambda ()
    (if (null? *peek-recent*)
        (message "nothing recent")
        (minibuffer-read* "Recent: "
          (map (lambda (e) (list (nth 2 e) (car e))) *peek-recent*)
          (list (list 'match-hint 1)
                (list 'confirm
                      (lambda (key)
                        (let ((e (peek-recent-find key)))
                          (when e (peek-revive! e))))))))))

(public! 'window-fill-buffers
  "(window-fill-buffers) — the buffers a window in this frame may be filled with, most recent first: the frame's context, never the raw MRU ring")
(public! 'window-fill-blank
  "(window-fill-blank) — the blank pane a layout shows when the pool runs out, or #f; scratch.scm answers the group's scratch")
(public! 'fill-candidate?
  "(fill-candidate? NAME) — #t when a window may be filled with NAME: known, not hidden, not the popup, not a peek")
(public! 'peek!
  "(peek! KNOWN OPEN) — show the buffer OPEN returns beside the selected window as a peek; KNOWN is its name, so a buffer that already existed is only shown and never killed; the next peek replaces it")
(public! 'peek-or-keep!
  "(peek-or-keep! KNOWN OPEN) — peek KNOWN, or keep it and go there when it is the peek on screen (browse's M-RET twice)")
(public! 'peek-or-open!
  "(peek-or-open! KNOWN OPEN) — RET on a row: peek KNOWN, or open it as your own when it is the peek on screen")
(public! 'peek-dismiss!
  "(peek-dismiss!) — dismiss every peek on screen; #t when there was one")
(public! 'peek-open!
  "(peek-open! KNOWN OPEN) — open KNOWN as your own in the selected window: a peek is kept and the popup gives it up; not a peek yet, OPEN runs")
(public! 'peek-file!
  "(peek-file! PATH) — peek the file at PATH")
(public! 'peek-keep!
  "(peek-keep! NAME) — keep a peek: clear the mark; the buffer and its window stay")
(public! 'peek-buffer?
  "(peek-buffer? NAME) — #t when NAME is a peek: shown to look at, killed when the next peek replaces it")

;;; --- mode layouts -------------------------------------------------------------
;;; A display rule says where ONE buffer goes. A mode that owns the frame needs
;;; more: writing mode is a document and its scratch, side by side, and nothing
;;; else. The mode declares that arrangement as data, and this engine puts the
;;; windows there:
;;;
;;;   (define-mode-layout! "writing-mode" '(h 0.62 self scratch-buffer))
;;;
;;; The spec is (DIR RATIO PANE PANE ...), or one PANE alone for a full frame.
;;; DIR is 'h (side by side) or 'v (one above the other). RATIO is the share the
;;; first pane takes. A PANE names a buffer in one of three ways:
;;;
;;;   self       the buffer the mode is on
;;;   SYMBOL     the buffer named by that buffer-local of the anchor
;;;   "NAME"     that buffer, by name
;;;
;;; The engine drops a pane whose buffer does not exist, so a document with no
;;; scratch yet fills the frame alone. It arranges the frame when a mode turns
;;; on in the selected window, and stays out of the way everywhere else: the
;;; desktop rebuilds its own saved windows, a background buffer never replaces
;;; the windows in front of somebody, and the ordinary split and delete commands
;;; still work while the mode is on.

(define *mode-layouts* '())        ; ((mode spec) ...)

(define (define-mode-layout! mode spec)
  (set! *mode-layouts*
    (cons (list mode spec)
          (remove (lambda (e) (equal? (car e) mode)) *mode-layouts*)))
  mode)

(define (mode-layout mode)
  (let ((e (assoc mode *mode-layouts*)))
    (and e (cadr e))))

;; the layout BUF declares. A minor mode answers before the major mode: it is
;; the more specific statement about the same buffer.
(define (buffer-layout buf)
  (let loop ((names (append (or (buffer-local buf 'minor-modes) '())
                            (let ((m (buffer-local buf 'mode-name)))
                              (if m (list m) '())))))
    (if (null? names)
        #f
        (let ((spec (mode-layout (car names))))
          (if spec spec (loop (cdr names)))))))

;; A pane that may not exist yet: (ensure "NAME" "COMMAND") runs COMMAND
;; when NAME is absent, then uses NAME. This is what lets a declared
;; layout be the whole truth — kill a pane's buffer, ask for the layout
;; again, and the command builds it back. A plain "NAME" pane still
;; drops when it is missing, because a document with no scratch yet must
;; fill the frame alone.
(define (layout--ensure name maker)
  (unless (buffer-known? name)
    (when (string? maker) (run-command maker)))
  (and (buffer-known? name) name))

(define (layout--pane anchor pane)
  (cond ((equal? pane 'self) anchor)
        ((string? pane) (and (buffer-known? pane) pane))
        ((and (pair? pane) (equal? (car pane) 'ensure))
         (layout--ensure (car (cdr pane))
                         (and (pair? (cdr (cdr pane))) (car (cdr (cdr pane))))))
        ((symbol? pane)
         (let ((v (buffer-local anchor pane)))
           (and (string? v) (buffer-known? v) v)))
        (else #f)))

;; the buffers the spec names, in order, without repeats
(define (layout--panes anchor spec)
  (let loop ((rest (if (pair? spec) (cdr (cdr spec)) (list spec))) (acc '()))
    (if (null? rest)
        (reverse acc)
        (let ((b (layout--pane anchor (car rest))))
          (loop (cdr rest) (if (and b (not (member b acc))) (cons b acc) acc))))))

(define (layout--dir spec) (if (pair? spec) (car spec) 'h))
(define (layout--ratio spec) (if (pair? spec) (cadr spec) 0.5))

;; Return the window made by one split. Window ids are stable, so the new id
;; is the only id that was not present before the split.
(define (layout--new-window before)
  (let loop ((windows (window-list)))
    (cond ((null? windows) #f)
          ((not (member (car (car windows)) before)) (car (car windows)))
          (else (loop (cdr windows))))))

(define (layout--valid-ratio ratio fallback)
  (if (and (number? ratio) (> ratio 0) (< ratio 1)) ratio fallback))

;; Fill the selected leaf with BUFFERS along DIR. FIRST-RATIO controls the
;; first pane. Each later split divides the remaining space evenly. Three
;; panes therefore use 1/3, then 1/2, and finish as equal thirds.
(define (layout--fill-line! buffers dir first-ratio)
  (when (pair? buffers)
    (switch-to-buffer! (car buffers))
    (let loop ((rest (cdr buffers)) (first? #t))
      (when (pair? rest)
        (let* ((count (+ 1 (length rest)))
               (ratio (if first?
                          (layout--valid-ratio first-ratio (/ 1 count))
                          (/ 1 count)))
               (before (map car (window-list))))
          (split-window! dir ratio)
          (let ((new (layout--new-window before)))
            (when new
              (select-window! new)
              (switch-to-buffer! (car rest))
              (loop (cdr rest) #f)))))))
  buffers)

;; The engine runs one arrangement at a time. switch-to-buffer! wakes a dormant
;; buffer, which re-runs its mode setups; without this flag that wake would ask
;; for another layout in the middle of this one.
(define *layout-busy* #f)

;; Winner records one entry for a complete layout change. The wrapped split
;; functions consult this flag, including during mode layouts and tiling.
(define *winner-inhibit* #f)

;; Run THUNK with the engine standing down. Desktop restore uses this: it
;; rebuilds the exact windows it saved, and a mode setup that runs inside it
;; must not arrange the frame a second way.
;; Is the engine arranging the frame right now? A package that moves
;; windows of its own — a preview that opens beside its index, say — must
;; ask this and stand down: the engine is mid-build, it will place every
;; declared pane itself, and a split landing inside that build leaves the
;; frame neither arrangement.
(define (layout-arranging?) *layout-busy*)

;; This Scheme has no unwind form, so a throw inside a build leaves the
;; flag raised and every later arrangement returns early — the frame
;; quietly stops obeying its layouts. A top-level, user-initiated build
;; clears it first: nothing can legitimately be arranging the frame at
;; the moment somebody asks for an arrangement.
(define (layout-abort!) (set! *layout-busy* #f))

(define (with-layout-suppressed thunk)
  (let ((was *layout-busy*))
    (set! *layout-busy* #t)
    (let ((r (thunk)))
      (set! *layout-busy* was)
      r)))

;; Put the frame where SPEC says. The anchor keeps focus: a mode that arranges
;; the frame must not move the user out of the buffer they are in.
(define (apply-layout! anchor spec)
  (if *layout-busy*
      (layout--panes anchor spec)
      (begin
        ;; the flag goes up BEFORE the panes resolve: an ensure pane runs a
        ;; command, that command switches buffers and sets a mode, and a
        ;; mode setup asks the engine for a layout of its own. One
        ;; arrangement at a time, materialising included.
        (set! *layout-busy* #t)
        (winner-save!)
        (set! *winner-inhibit* #t)
        (let ((panes (layout--panes anchor spec)))
          (when (pair? panes)
            (delete-other-windows!)
            (layout--fill-line! panes (layout--dir spec) (layout--ratio spec))
            (let ((w (window-showing anchor)))
              (when w (select-window! w))))
          (set! *winner-inhibit* #f)
          (set! *layout-busy* #f)
          panes))))

;; Return one buffer for each visible work window. Put the selected window first.
;; Keep duplicate buffers because two windows can show different points in one buffer.
;; Floating buffers cover a layout and do not become members of it.
(define (layout-visible-buffers)
  (let* ((selected-window (active-window))
         (selected (window-buffer selected-window)))
    (let loop ((windows (window-list))
               (acc (if (popup--class? selected) '() (list selected))))
      (if (null? windows)
          acc
          (let ((win (car (car windows)))
                (buf (car (cdr (car windows)))))
            (loop (cdr windows)
              (if (or (equal? win selected-window) (popup--class? buf))
                  acc
                  (append acc (list buf)))))))))

;;; --- the pool: which buffers belong in this frame's windows -------------
;;; One source, the way a completion source answers a prompt. The buffers
;;; a window in this frame may be filled with, most recent first, are the
;;; frame's context: editor.scm knows no groups, so the base answer is the
;;; MRU ring, and groups.scm sets the source to the group's members when
;;; the frame stands in one. Every site that fills a window reads this
;;; and never the ring itself: the columns of a layout, the window a kill
;;; empties, the buffer q falls to. A layout that read the ring pulled
;;; buffers in from other groups.

;; a buffer a window may be filled with: known, not hidden, not floating
;; as the popup, not a peek (a look, not a place)
(define (fill-candidate? b)
  (and (string? b) (buffer-known? b)
       (not (string-prefix? " " b))
       (not (popup--class? b))
       (not (and (boundp 'peek-buffer?) (peek-buffer? b)))))

(define window-fill-source (lambda () (buffer-list-mru)))

(define (window-fill-buffers)
  (filter fill-candidate? (window-fill-source)))

;; The blank pane: the buffer a layout shows in a pane the pool cannot
;; fill. editor.scm knows no groups, so the base answer is none, and a
;; layout stays short; scratch.scm sets the source to the group's scratch
;; when the frame stands in a group, so a sealed group's layout keeps its
;; shape without a buffer from outside.
(define window-fill-blank (lambda () #f))

;; The three-column command is useful as a quick workspace view. If fewer
;; than three work buffers are visible, the remaining columns come from
;; the pool, and only the pool; when the pool runs out, one blank pane.
(define (layout--three-columns buffers)
  (let loop ((rest (window-fill-buffers))
             (result buffers))
    (cond ((>= (length result) 3) result)
          ((null? rest)
           (let ((blank (window-fill-blank)))
             (if (and blank (not (member blank result)))
                 (append result (list blank))
                 result)))
          ((member (car rest) result) (loop (cdr rest) result))
          (else (loop (cdr rest) (append result (list (car rest))))))))

;; Validate each requested pane without removing duplicate buffer names.
(define (layout--known-buffers buffers)
  (let loop ((rest buffers) (acc '()))
    (if (null? rest)
        (reverse acc)
        (let ((buf (car rest)))
          (loop (cdr rest)
            (if (and (string? buf) (buffer-known? buf))
                (cons buf acc)
                acc))))))

(define (layout--drop-n values n)
  (if (or (= n 0) (null? values)) values (layout--drop-n (cdr values) (- n 1))))

;; A balanced binary tiler. Alternating split directions produces a grid.
;; Ratios follow the leaf counts, so odd grids give the larger half more room.
(define (layout--grid! buffers dir)
  (if (null? (cdr buffers))
      (switch-to-buffer! (car buffers))
      (let* ((count (length buffers))
             (left-count (quotient (+ count 1) 2))
             (left (take-n buffers left-count))
             (right (layout--drop-n buffers left-count))
             (before (map car (window-list)))
             (left-window (active-window)))
        (split-window! dir (/ left-count count))
        (let ((right-window (layout--new-window before))
              (next-dir (if (equal? dir 'h) 'v 'h)))
          (select-window! left-window)
          (layout--grid! left next-dir)
          (select-window! right-window)
          (layout--grid! right next-dir)))))

;; Build a two-zone layout. The main pane takes two thirds. The other buffers
;; share a one-third stack on SIDE.
(define (layout--main-stack! buffers side)
  (let* ((main (car buffers))
         (stack (cdr buffers))
         (horizontal? (or (equal? side 'left) (equal? side 'right)))
         (split-dir (if horizontal? 'h 'v))
         (stack-dir (if horizontal? 'v 'h))
         (stack-first? (or (equal? side 'left) (equal? side 'top)))
         (before (map car (window-list)))
         (first-window (active-window)))
    (switch-to-buffer! (if stack-first? (car stack) main))
    (split-window! split-dir (if stack-first? *window-third* (- 1 *window-third*)))
    (let ((second-window (layout--new-window before)))
      (if stack-first?
          (begin
            (select-window! first-window)
            (layout--fill-line! stack stack-dir (/ 1 (length stack)))
            (select-window! second-window)
            (switch-to-buffer! main))
          (begin
            (select-window! second-window)
            (layout--fill-line! stack stack-dir (/ 1 (length stack))))))))

(define *window-layout-algorithms*
  '(columns rows grid main-right main-left main-bottom main-top))

;; Arrange explicit buffers with a named tiling algorithm. The first buffer is
;; the main buffer and keeps focus. This is the stable agent-facing entry point.
(define (tile-windows! algorithm buffers)
  (let ((panes (layout--known-buffers buffers)))
    (cond
      ((not (member algorithm *window-layout-algorithms*))
       (message "Unknown window layout") #f)
      ((null? panes) (message "No live buffers to arrange") #f)
      (*layout-busy* panes)
      (else
        (when (popup-open?) (popup-close!))
        (set! *layout-busy* #t)
        (winner-save!)
        (set! *winner-inhibit* #t)
        (delete-other-windows!)
        (cond
          ((equal? algorithm 'columns)
           (layout--fill-line! panes 'h (/ 1 (length panes))))
          ((equal? algorithm 'rows)
           (layout--fill-line! panes 'v (/ 1 (length panes))))
          ((equal? algorithm 'grid)
           (layout--grid! panes 'h))
          ((equal? algorithm 'main-right)
           (if (null? (cdr panes)) (switch-to-buffer! (car panes))
               (layout--main-stack! panes 'right)))
          ((equal? algorithm 'main-left)
           (if (null? (cdr panes)) (switch-to-buffer! (car panes))
               (layout--main-stack! panes 'left)))
          ((equal? algorithm 'main-bottom)
           (if (null? (cdr panes)) (switch-to-buffer! (car panes))
               (layout--main-stack! panes 'bottom)))
          (else
           (if (null? (cdr panes)) (switch-to-buffer! (car panes))
               (layout--main-stack! panes 'top))))
        (let ((home (window-showing (car panes))))
          (when home (select-window! home)))
        (set! *winner-inhibit* #f)
        (set! *layout-busy* #f)
        panes))))

(define (tile-visible-windows! algorithm)
  (let* ((visible (layout-visible-buffers))
         (panes (if (equal? algorithm 'columns)
                    (layout--three-columns visible)
                    visible)))
    (if (< (length panes) 2)
        (begin (message "Open at least two work buffers") #f)
        (tile-windows! algorithm panes))))

(define (window-layout-command algorithm)
  (lambda () (tile-visible-windows! algorithm)))

;; Layout selection is a live preview. Keep the complete frame arrangement so
;; cancelling the prompt returns both the windows and the selected window.
(define (window-layout-preview! name)
  ;; A failed earlier arrangement must not disable a later interactive
  ;; preview. This command is a new top-level layout request.
  (layout-abort!)
  (if (equal? name "adaptive")
      (tile-visible-adaptive!)
      (tile-visible-windows! (string->symbol name))))

(define (window-layout-preview-without-history! name)
  (let ((was *winner-inhibit*))
    (set! *winner-inhibit* #t)
    (let ((result (window-layout-preview! name)))
      (set! *winner-inhibit* was)
      result)))

(define-command "window-layout-columns" "Tile visible buffers in equal columns"
  (window-layout-command 'columns))
(define-command "window-layout-rows" "Tile visible buffers in equal rows"
  (window-layout-command 'rows))
(define-command "window-layout-grid" "Tile visible buffers in a balanced grid"
  (window-layout-command 'grid))
(define-command "window-layout-main-right" "Show a two-thirds main pane and a companion on the right"
  (window-layout-command 'main-right))
(define-command "window-layout-main-bottom" "Show a two-thirds main pane and a one-third bottom pane"
  (window-layout-command 'main-bottom))

(define-command "window-layout" "Choose a tiling layout for visible buffers"
  (lambda ()
    (let ((saved (window-tree)))
      (minibuffer-read-preview "Window layout: "
        '( ("adaptive" "choose from usable monitor width")
           ("columns" "3 columns")
           ("rows" "equal rows")
           ("grid" "balanced grid")
           ("main-right" "companion view (companion on the right)")
           ("main-left" "2/3 + 1/3 (companion on the left)")
           ("main-bottom" "2/3 + 1/3 (companion below)")
           ("main-top" "2/3 + 1/3 (companion above)"))
        window-layout-preview-without-history!
        (lambda (name)
          ;; Commit from the original arrangement so winner records one real
          ;; layout change, not an intermediate preview arrangement.
          (window-tree-set! saved)
          (window-layout-preview! name))
        (lambda () (window-tree-set! saved))))))

(for-each
  (lambda (name) (catalog-meta! 'command name 'domain 'windows 'effects '(write display)))
  '("window-layout" "window-layout-columns" "window-layout-rows"
    "window-layout-grid" "window-layout-main-right" "window-layout-main-bottom"))

;; The engine's entry point: a mode turned on in BUF. Arrange the frame only
;; when BUF is the buffer the user is looking at.
(define (layout-enter! buf)
  (let ((spec (buffer-layout buf)))
    (if (and spec
             (not *layout-busy*)
             (equal? (window-buffer (active-window)) buf))
        (apply-layout! buf spec)
        #f)))

(define-command "reset-layout" "Arrange the frame the way this buffer's mode asks"
  (lambda ()
    (layout-abort!)
    (let ((spec (buffer-layout (current-buffer))))
      (if spec
          ;; also the way back from an arrangement that failed part way: the
          ;; flag never outlives the command the user runs to fix the frame
          (begin (set! *layout-busy* #f)
                 (apply-layout! (current-buffer) spec))
          (message "This buffer's modes declare no layout")))))

(define-command "popup-toggle" "Toggle the floating popup window"
  (lambda ()
    (if (popup-open?)
        (popup-close!)
        (if (popup-buffer)
            (popup-show (popup-buffer))
            (message "No popup buffer yet")))))

(define-command "popup-buffer" "Show any buffer in the floating popup"
  (lambda ()
    (minibuffer-read "Popup buffer: " (buffer-candidates)
      (lambda (name) (display-buffer-popup! name)))))
(catalog-meta! 'command "popup-buffer" 'domain 'windows 'effects '(write display))

;; popper-toggle-type: the popup you want to keep stops floating and
;; becomes an ordinary window, in the place it already occupies.
(define-command "popup-bufferize"
  "Turn the floating popup into an ordinary window"
  (lambda ()
    (if (not (popup-open?))
        (message "No popup window")
        (let* ((buf (current-buffer))
               (side (popup-side-of buf)))
          (popup-float! buf #f)
          ;; a window on the left or the top takes that place in the tree
          ;; now: floating, it sat second and the class placed it
          (cond ((equal? side 'left) (window-swap! 'left))
                ((equal? side 'top) (window-swap! 'up)))
          (set-frame-local! 'popup-window #f)
          ;; it is a window now, not a visit — there is nothing to go back from
          (popup-forget!)
          (message (string-append buf " is an ordinary window now"))))))

;; q in special buffers: close the popup, or kill this buffer and go back.
;; Every buffer that binds q is a listing you can make again — dired,
;; ibuffer, help, diff, notmuch, agents, mcp-hub. The kill is what stops q
;; from flipping between two listings: a buffer that only moves down the
;; MRU ring is still the candidate the next q picks. buffer-kill! puts the
;; most recent buffer that is not on screen in the window.
(define-command "quit-window" "Close the popup, or kill this buffer and go back"
  (lambda ()
    (cond
      ;; a peek goes with its window: the look is over, and the layout
      ;; is what it was. In the popup the popup is dismissed; in a split
      ;; the split closes; alone, the window falls to the next buffer.
      ((peek-buffer? (current-buffer))
        (let ((cur (current-buffer)))
          (cond ((and (popup-open?) (equal? (active-window) (popup-window)))
                 (popup-dismiss!))
                ((other-window-id (active-window))
                 (delete-window!))
                (else
                 (let loop ((bs (window-fill-buffers)))
                   (cond ((null? bs) #t)
                         ((and (not (equal? (car bs) cur)) (buffer-exists? (car bs)))
                          (switch-to-buffer! (car bs)))
                         (else (loop (cdr bs)))))))
          (peek-drop! cur)))
      ;; from any other buffer, a peek on screen goes first: q in the
      ;; listing that peeked takes the look, then the listing
      ((peek-dismiss!) #t)
      ((and (popup-open?) (equal? (active-window) (popup-window)))
        (popup-dismiss!))
      (else
        (let ((cur (current-buffer)))
          ;; a file with edits you did not save is not a listing: say so and
          ;; stay. A listing reports itself as modified — it has no path.
          (if (and (buffer-path cur) (buffer-modified? cur))
              (message "Buffer is modified — save it, or C-x k to kill it")
              (begin
                ;; put the window on a LIVE buffer before the kill. The
                ;; kill-side fallback can land on a dormant checkpoint
                ;; that has no process, and the next write is a noproc.
                (let loop ((bs (window-fill-buffers)))
                  (cond ((null? bs) #t)
                        ((and (not (equal? (car bs) cur))
                              (buffer-exists? (car bs)))
                         (switch-to-buffer! (car bs)))
                        (else (loop (cdr bs)))))
                ;; a live process (tail, shell) dies with its buffer
                (if (process-running? cur) (process-kill! cur))
                (buffer-kill! cur))))))))

;; q quits every buffer you cannot type in. The read-only keymap sits
;; between the buffer's own map and the global one, so a mode that wants q
;; for something else — code-mode's exit, notmuch's search — still wins.
(local-set-key* " *read-only*" "q" "quit-window")

;;; --- collect: the prompt continues as a buffer (embark-collect) ------------
;;; C-c C-o closes the prompt and collects the candidates that survive its
;;; input. A prompt can route them to a reusable domain list such as ibuffer.
;;; Other prompts use *Collect*, which keeps preview, accept, and cancel.
;;; The handlers come from the prompt itself — minibuffer-detach! closes it
;;; without firing anything and hands them over.

(define *collect-buffer* "*Collect*")

;; the detached prompt lives in globals, not in buffer-locals: a closure
;; cannot survive a restart, and desktop.etf must not hold one. After a
;; restart the buffer is text — the keys say so and stop.
(define *collect-select* #f)     ; the preview hook, from minibuffer-read-preview
(define *collect-confirm* #f)
(define *collect-cancel* #f)
(define *collect-complete* #f)   ; path prompts resolve a label through it
(define *collect-input* "")
(define *collect-window* #f)     ; the window the prompt ran in

(define (collect-forget!)
  (set! *collect-select* #f)
  (set! *collect-confirm* #f)
  (set! *collect-cancel* #f)
  (set! *collect-complete* #f))

(define (collect-fill! prompt cands)
  (let ((buf *collect-buffer*))
    (buffer-delete-range! buf 0 (buffer-size buf))
    (buffer-append! buf
      (string-append ";; " (string-trim prompt) " "
                     (number->string (length cands))
                     " candidates · n/p previews · RET accepts · q quits\n"))
    (buffer-set-local! buf 'collect-labels (map car cands))
    (for-each
      (lambda (c)
        (buffer-append! buf
          (string-append (car c)
                         (if (equal? (cadr c) "") "" (string-append "  " (cadr c)))
                         "\n")))
      cands)))

;; the list opens in another window: the window the prompt ran in must keep
;; showing what the preview acts on
(define (collect-open! prompt cands)
  (buffer-create *collect-buffer*)
  (collect-fill! prompt cands)
  (let ((showing (window-showing *collect-buffer*)))
    (if showing
        (select-window! showing)
        (begin (split-window! 'v 0.6) (other-window!))))
  (switch-to-buffer! *collect-buffer*)
  (set-mode! "collect-mode")
  (goto-char! 0)
  (next-line!)
  (beginning-of-line!)
  (collect-preview!))

;; the label on the current line — the header is line 0, entries follow
(define (collect-current)
  (if (not (buffer-exists? *collect-buffer*))
      #f
      (collect-label-at)))

(define (collect-label-at)
  (let* ((labels (or (buffer-local *collect-buffer* 'collect-labels) '()))
         (before (substring-bytes (buffer-text *collect-buffer*) 0 (point)))
         (ln (- (length (string-split before "\n")) 2)))
    (if (and (>= ln 0) (< ln (length labels))) (list-ref labels ln) #f)))

;; the preview goes where the prompt's preview went: the window the prompt
;; ran in. If that window is gone, any other window does. The preview must
;; never land in the list itself, so a lone *Collect* window previews
;; nothing.
(define (collect-target-window)
  (let ((me (active-window)))
    (if (and *collect-window* (window-exists? *collect-window*)
             (not (equal? *collect-window* me)))
        *collect-window*
        (other-window-id me))))

(define (collect-preview!)
  (let ((label (collect-current)) (w (collect-target-window)))
    (when (and *collect-select* label)
      (if w
          (let ((back (active-window)))
            (select-window! w)
            (*collect-select* label)
            (set! *collect-window* w)
            (select-window! back))
          (message "No other window to preview in")))))

;; path prompts resolve a label through their completion fn — that is how
;; find-file turns "editor.scm" back into a full path (see mb_confirm_value)
(define (collect-resolve label)
  (if *collect-complete*
      (let ((r (*collect-complete* *collect-input* label)))
        (if (and (pair? r) (string? (car r))) (car r) label))
      label))

(define (collect-close!)
  (if (null? (cdr (window-list)))
      (run-command "quit-window")        ; kills *Collect* and goes back
      (begin (delete-window!) (buffer-kill! *collect-buffer*))))

(define-command "collect-next" "Move down; the preview follows"
  (lambda () (next-line!) (beginning-of-line!) (collect-preview!)))

(define-command "collect-prev" "Move up; the preview follows"
  (lambda ()
    (previous-line!) (beginning-of-line!)
    (unless (collect-current) (next-line!) (beginning-of-line!))
    (collect-preview!)))

(define-command "collect-accept" "Accept the candidate on this line"
  (lambda ()
    (let ((label (collect-current))
          (fn *collect-confirm*)
          (w (collect-target-window)))
      (cond ((not label) (message "No candidate on this line"))
            ((not fn) (message "This list is stale — run the command again"))
            (else
              (let ((value (collect-resolve label)))
                (collect-forget!)
                (collect-close!)
                (when (and w (window-exists? w)) (select-window! w))
                (fn value)))))))

(define-command "collect-quit" "Close the list; put back what the preview moved"
  (lambda ()
    (let ((fn *collect-cancel*) (w (collect-target-window)))
      (collect-forget!)
      (collect-close!)
      (when (and w (window-exists? w)) (select-window! w))
      (when fn (fn)))))

(define-command "minibuffer-collect" "Write the prompt's candidates into a buffer"
  (lambda ()
    (let ((d (minibuffer-detach!)))
      (if (not d)
          (message "No prompt to collect")
          (let* ((select *mb-select-fn*)
                 (cands (cadr (assoc 'candidates d)))
                 (collector-entry (assoc 'collect d))
                 (collector (and collector-entry (cadr collector-entry))))
            (set! *mb-select-fn* #f)
            ;; the prompt is gone, so the list behind it no longer owns the
            ;; minibuffer's arrows
            (set! *mb-list-buffer* #f)
            (if collector
                (begin
                  (collect-forget!)
                  (collector cands))
                (begin
                  (set! *collect-select* select)
                  (set! *collect-confirm* (cadr (assoc 'confirm d)))
                  (set! *collect-cancel* (cadr (assoc 'cancel d)))
                  (set! *collect-complete* (cadr (assoc 'complete d)))
                  (set! *collect-input* (cadr (assoc 'input d)))
                  (set! *collect-window* (active-window))
                  (collect-open! (cadr (assoc 'prompt d)) cands))))))))

(define-mode "collect-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-local! buf 'mode-name "collect-mode")
      (local-set-key "n" "collect-next")
      (local-set-key "p" "collect-prev")
      ;; line movement REMAPS, so arrows, C-n/C-p and any user binding of
      ;; next-line all move-and-preview identically
      (local-remap! "next-line" "collect-next")
      (local-remap! "previous-line" "collect-prev")
      (local-set-key "RET" "collect-accept")
      (local-set-key "q" "collect-quit")
      (buffer-set-read-only! buf #t))))

(mode-doc! "collect-mode"
  "The prompt's candidates, as a buffer you can move around in. Moving previews the candidate in the other window. `RET` confirms it in the prompt you came from.")

;; Emacs' C-x C-q. The way out of a read-only buffer, and the reason a mode
;; may open files read-only without trapping the reader.
(define-command "read-only-mode" "Toggle whether this buffer refuses edits"
  (lambda ()
    (let* ((buf (current-buffer))
           (ro? (buffer-read-only? buf)))
      (buffer-set-read-only! buf (not ro?))
      (message (if ro? "writable" "read-only")))))

(global-set-key "C-x C-q" "read-only-mode")

;; A file you reach from a browsing surface (diff-mode, code.scm) opens
;; READ-ONLY. You came to read it, and a stray keystroke in a file you are
;; only passing through is an edit you did not mean. C-x C-q makes it
;; writable. Set *browse-read-only* to #f in init.scm to opt out.
(define *browse-read-only* #t)

(define (browse-visit path)
  (visit path)
  (when *browse-read-only*
    (buffer-set-read-only! (current-buffer) #t)))

(public! 'browse-visit "(browse-visit PATH) — open a file the way the code browser does: read-only unless *browse-read-only* is #f. C-x C-q makes it writable")

;; DELTA in lines, positive forward. A preview window has no lines, so
;; scroll-window! turns the count into pixels for it — the caller says
;; "a screen" and every kind of window understands.
;; the window the other-window scroll moves: the popup when it shows
;; and is not where you are (a peek, the messages, the telemetry: the
;; look beside your work), else the next window
(define (scroll-other-window-target)
  (let ((me (active-window)))
    (or (and (popup-open?) (not (equal? (popup-window) me)) (popup-window))
        (let ((wins (window-list)))
          (and (pair? (cdr wins))
               (let loop ((ws wins))
                 (cond ((null? ws) (car (car wins)))
                       ((equal? (car (car ws)) me)
                        (car (if (null? (cdr ws)) (car wins) (car (cdr ws)))))
                       (else (loop (cdr ws))))))))))

(define (scroll-other-window-by! delta)
  (let ((target (scroll-other-window-target)))
    (if target
        (scroll-window! target delta)
        (message "No other window"))))

;; the popup by name, for a binding of your own; nothing else scrolls
(define-command "scroll-popup" "Scroll the popup up nearly a full screen"
  (lambda ()
    (if (popup-open?)
        (scroll-window! (popup-window) (- (window-rows) 2))
        (message "No popup"))))

(define-command "scroll-popup-down" "Scroll the popup down nearly a full screen"
  (lambda ()
    (if (popup-open?)
        (scroll-window! (popup-window) (- 2 (window-rows)))
        (message "No popup"))))

(define-command "scroll-other-window" "Scroll the next window up nearly a full screen"
  (lambda () (scroll-other-window-by! (- (window-rows) 2))))

(define-command "scroll-other-window-down"
  "Scroll the next window down nearly a full screen"
  (lambda () (scroll-other-window-by! (- 2 (window-rows)))))

;;; --- terminal and comint ---------------------------------------------------

(domain! 'processes)
(effects! '(write execute))

;; The terminal receives raw PTY bytes outside the editor render loop. Its
;; bounded plain transcript stays in the buffer for search, agents, and /raw.
;; The login flag works for zsh, bash, and fish. Override this in init.scm.
(define *terminal-command* "exec \"${SHELL:-/bin/zsh}\" -l")

(define (terminal-mode-init! buf)
  (buffer-set-local! buf 'render-mode "terminal")
  (buffer-set-local! buf 'line-numbers "off")
  (buffer-set-read-only! buf #t)
  (unless (process-running? buf)
    ;; A terminal app records its own launch command in the buffer.  That
    ;; local rides the desktop, so waking *opencode* starts OpenCode again
    ;; instead of silently turning the buffer into a login shell.
    (start-terminal! buf
      (or (buffer-local buf 'terminal-command) *terminal-command*))))

;; shell-mode remains a terminal mode so old desktop snapshots migrate on
;; their next wake. term-mode is the explicit name for new terminal buffers.
(define-mode "shell-mode"
  (lambda () (terminal-mode-init! (current-buffer))))
(define-mode "term-mode"
  (lambda () (terminal-mode-init! (current-buffer))))

(mode-doc! "shell-mode"
  "A raw PTY terminal. Full-screen programs and app servers render outside the editor document loop. The bounded transcript stays readable as buffer text.")
(mode-doc! "term-mode"
  "A raw PTY terminal. Full-screen programs and app servers render outside the editor document loop. The bounded transcript stays readable as buffer text.")

(define-command "shell" "Open a raw PTY shell in the *shell* buffer"
  (lambda ()
    (buffer-create "*shell*")
    (buffer-set-local! "*shell*" 'mode-name "term-mode")
    (with-current-buffer "*shell*"
      (lambda () (terminal-mode-init! "*shell*")))
    (display-buffer "*shell*")))

;; OpenCode is a terminal application, not an editor mode: it gets the same
;; fast raw PTY, ANSI colour, keyboard routing, and readable transcript as
;; *shell*.  One semantic `opencode` role per group makes renamed groups keep
;; finding their session without encoding durable identity in the buffer name.
(define *opencode-command* "exec opencode")

(define (opencode-buffer-name group)
  (if group
      (string-append "*opencode:" (group-name group) "*")
      "*opencode*"))

(define (opencode-open! group)
  (let* ((dir (default-directory))
         (known (and group (group-buffer-as group 'opencode)))
         (buf (or known (opencode-buffer-name group))))
    (buffer-create buf)
    ;; A stopped or restored app keeps the directory and exact command it was
    ;; born with.  Re-running M-x opencode therefore resumes the same session.
    (unless (buffer-local buf 'terminal-command)
      (buffer-set-local! buf 'default-directory dir)
      (buffer-set-local! buf 'terminal-command
        (string-append "cd -- " (sh-quote dir) " && " *opencode-command*)))
    (buffer-set-local! buf 'mode-name "term-mode")
    (when group (buffer-add-group-as! buf group 'opencode))
    (with-current-buffer buf (lambda () (terminal-mode-init! buf)))
    (display-buffer buf)))

;; groups.scm replaces this seam with its native reader.  Keeping the reader
;; out of terminal code also lets compos boot without the optional workspace
;; package loaded.
(define opencode-group-reader
  (lambda (receive) (receive (frame-group))))

(define-command "opencode"
  "Open OpenCode for this group; with C-u, choose a group"
  (lambda ()
    (if (current-prefix-arg)
        (opencode-group-reader opencode-open!)
        (opencode-open! (frame-group)))))

;;; RET in a comint process sends the current line to the process. RET
;;; elsewhere inserts a newline.

;; Comint contract: processes run with TERM=dumb and are expected to degrade
;; (bash does automatically; zsh needs zle/prompt padding off — the flags
;; below, or the classic `[[ $TERM == dumb ]] && unsetopt zle prompt_cr
;; prompt_sp` in your zshrc). fish refuses dumb terminals — it belongs in
;; term-mode (real terminal emulator pane), not comint.
;; Override *shell-command* in your init.scm.
(define *shell-command* "exec /bin/zsh -f -i +o zle +o prompt_cr +o prompt_sp")

;; The text-buffer shell remains available for tools that want comint.
(define-mode "comint-shell-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (unless (process-running? buf)
        (start-process! buf *shell-command*)))))

(mode-doc! "comint-shell-mode"
  "A shell under the editor. `RET` sends the text after the process mark to the shell. A restart keeps the transcript and starts a new shell.")

(define-command "comint-shell" "Open a text-buffer shell in *comint-shell*"
  (lambda ()
    (if (not (process-running? "*comint-shell*"))
        (start-process! "*comint-shell*" *shell-command*))
    (display-buffer "*comint-shell*")
    (buffer-set-local! "*comint-shell*" 'mode-name "comint-shell-mode")
    (end-of-buffer!)))

(define-command "newline-or-send" "Send input to the process, or insert a newline"
  (lambda ()
    (if (process-running? (current-buffer))
        ;; comint: input = text after the process mark. Typed input STAYS in
        ;; the buffer (pty echo is off) — nothing flickers or disappears.
        (let ((pm (process-mark (current-buffer)))
              (eob (end-of-buffer!)))
          (let ((input (buffer-substring pm eob)))
            (insert! "\n")
            (process-send! (current-buffer) (string-append input "\n"))))
        (insert! "\n"))))

;;; --- tail (follow a growing file) ------------------------------------------
;;; tail -F under the comint layer — local or /ssh: remote. The buffer is
;;; 'transient: the desktop saves its mode + tail-path but not content, and
;;; tail-mode's setup restarts the tail on restore. end-of-buffer! puts
;;; point at the end, where process appends keep pushing it — follow for free.

(define (sh-quote s)
  (string-append "'" (string-join (string-split s "'") "'\\''") "'"))

(define (tail-command path)
  (if (remote-path? path)
      (let ((hp (remote-parse path)))
        ;; double-quoted: the inner quoting survives to the remote shell
        (string-append "exec " (sh-quote (ssh-command)) " " (sh-quote (car hp)) " "
                       (sh-quote (string-append "tail -n 200 -F " (sh-quote (cadr hp))))))
      (string-append "exec tail -n 200 -F " (sh-quote path))))

(define-mode "tail-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (let ((path (buffer-local buf 'tail-path)))
        (buffer-set-read-only! buf #t)
        (buffer-set-local! buf 'transient #t)
        (local-set-key "q" "quit-window")
        (when (and path (not (process-running? buf)))
          (start-process! buf (tail-command path)))))))

(mode-doc! "tail-mode"
  "A file that follows itself, local or over `ssh`. New lines append at the end. The buffer is read-only, and `q` closes it.")

(define (tail-open path)
  (if (and (remote-path? path) (not (remote-parse path)))
      (message "Remote path is /ssh:HOST:/PATH")
      (let ((buf (string-append "*tail: " path "*")))
        (buffer-create buf)
        (buffer-set-local! buf 'tail-path path)
        (switch-to-buffer! buf)
        (set-mode! "tail-mode")
        (end-of-buffer!))))

(define-command "tail-file" "Follow a file as it grows (local or /ssh: remote)"
  (lambda ()
    (read-file-name "Tail file: "
      (lambda (input) (tail-open (normalize-file-input input))))))

;;; --- LLM pipes (gptel) -----------------------------------------------------
;;; (llm prompt handler) is the async primitive; everything here is
;;; composition. Handlers are ordinary closures — build your own pipelines.

(define (llm-on-region instruction handler)
  (let ((text (region-text)))
    (if (equal? text "")
        (message "No region — set the mark first (C-SPC)")
        (begin
          (message "LLM thinking...")
          (llm (string-append instruction
                              "\n\nReturn ONLY the result, no commentary.\n\n"
                              text)
               handler)))))

;; M-| : region -> LLM -> *llm* buffer
(define-command "llm-pipe-region" "Pipe the region through the LLM into *llm*"
  (lambda ()
    (minibuffer-read "LLM instruction: " '()
      (lambda (instr)
        (llm-on-region instr
          (lambda (result)
            (buffer-create "*llm*")
            (buffer-append! "*llm*" (string-append "\n;; " instr "\n" result "\n"))
            (message "LLM done -> *llm*")))))))

;; region -> LLM -> a rewrite that waits in the document
;;
;; gptel's other half. The model rewrites a passage and you read its version
;; where the old one stood, before you decide anything: the rewrite lands in
;; the buffer wearing the rewrite face, and the text it replaced waits beside
;; it until `C-c y` keeps it or `C-c k` puts it back. Asking again while one
;; waits refines that same span, and a reject after any number of rounds
;; still restores the words the passage started with.

(define *llm-rewrite-prose-modes*
  '("text-mode" "markdown-mode" "morg-mode" "org-mode" "chat-mode"))

;; The instructions the prompt offers. Prose and code want opposite things
;; from a model, so the buffer's mode decides which set leads.
(define *llm-rewrite-prose-directives*
  '("Rewrite this passage to be clearer and more direct. Keep the author's voice."
    "Say this in fewer words, and lose nothing."
    "Correct the grammar and the spelling. Change nothing else."
    "Say this in plain language."))

(define *llm-rewrite-code-directives*
  '("Refactor this code. Keep its behaviour, its interface, and the file's style."
    "Name these things for what they are."
    "Handle the cases this code misses."
    "Document this: a docstring for what it is, comments only for what the code cannot say."))

(define (llm-rewrite--prose? buf)
  (let ((mode (buffer-local buf 'mode-name)))
    (or (not mode) (member mode *llm-rewrite-prose-modes*))))

(define (llm-rewrite-directives buf)
  (if (llm-rewrite--prose? buf)
      (append *llm-rewrite-prose-directives* *llm-rewrite-code-directives*)
      (append *llm-rewrite-code-directives* *llm-rewrite-prose-directives*)))

(define (llm-rewrite-prompt buf directive passage)
  (string-append
    "You rewrite one passage of a document open in a text editor"
    (let ((mode (buffer-local buf 'mode-name)))
      (if mode (string-append " (" mode ")") ""))
    ".\n\nInstruction: " directive
    "\n\nPassage:\n" passage
    "\n\nReply with ONLY the rewritten passage. No commentary, no quotes and "
    "no code fences. Keep the indentation of every line, and add no heading, "
    "preface or trailing blank line."))

(define (llm-rewrite--drop-blank-front lines)
  (if (and (pair? lines) (equal? (string-trim (car lines)) ""))
      (llm-rewrite--drop-blank-front (cdr lines))
      lines))

(define (llm-rewrite--trim-blank-edges lines)
  (reverse (llm-rewrite--drop-blank-front
             (reverse (llm-rewrite--drop-blank-front lines)))))

;; A model asked for code answers in a fence often enough, and the passage it
;; replaces has none. Blank edges go the same way: a rewrite must sit exactly
;; where the old text sat, and the first line keeps its own indentation.
(define (llm-rewrite-clean reply)
  (let* ((lines (llm-rewrite--trim-blank-edges (string-split reply "\n")))
         (fenced (and (> (length lines) 1)
                      (string-prefix? "```" (string-trim (car lines)))
                      (string-prefix? "```"
                        (string-trim (nth (- (length lines) 1) lines))))))
    (string-join
      (if fenced
          (llm-rewrite--trim-blank-edges (reverse (cdr (reverse (cdr lines)))))
          lines)
      "\n")))

;; (OSTART OEND BSTART BEND TAIL OLD NEW DIRECTIVE VIEW) — one rewrite
;; waits per buffer. The passage stays where it is and the model's version
;; sits in a block below it, so nothing is lost while you decide. VIEW is
;; how that block reads: 'theirs (the rewrite alone, the default), 'ours
;; (the passage alone), or 'all (the unified diff of the two). A view is a
;; rendering of OLD and NEW, so changing view costs nothing and loses
;; nothing. The decision does not outlive the session: a restart leaves
;; both texts in the document, which is where doing nothing leaves them
;; too.
;;
;; A record written by an older build of this file is not this build's to
;; read. A hot reload can land between the proposal and the decision, and a
;; verb that reads the wrong field of the wrong shape edits the document by
;; arithmetic. A record of the wrong length is no record.
;; The record ends with a format tag. A record without it comes from a
;; build whose block wore another shape; a verb reading it would edit by
;; arithmetic that no longer holds, so it is no record.
(define llm-rewrite--format 'fenced)

(define (llm-rewrite-pending buf)
  (let ((p (buffer-local buf 'llm-rewrite)))
    (and (pair? p) (= (length p) 10)
         (equal? (nth 9 p) llm-rewrite--format)
         p)))

(define (llm-rewrite--tail p) (nth 4 p))
(define (llm-rewrite--old p) (nth 5 p))
(define (llm-rewrite--new p) (nth 6 p))
(define (llm-rewrite--instruction p) (nth 7 p))
(define (llm-rewrite--view p) (nth 8 p))

;; The three views of a live diff: theirs is the rewrite alone (the
;; default), ours is the passage alone, all is the unified diff of the
;; two. A record from before the renaming reads as theirs.
(define (llm-rewrite--render p view buf)
  (cond ((equal? view 'all)
         (llm-rewrite-diff-block (llm-rewrite--old p) (llm-rewrite--new p) buf))
        ((equal? view 'ours)
         (llm-rewrite-ours-block (llm-rewrite--old p) buf))
        (else (llm-rewrite-theirs-block (llm-rewrite--new p) buf))))

;; what the block should hold right now
(define (llm-rewrite--rendered p buf)
  (llm-rewrite--render p (llm-rewrite--view p) buf))

;; Where the two texts are now. Both overlays follow the rope, so an edit
;; above them moves both; the record answers before they exist.
(define (llm-rewrite--overlay buf face)
  (let ((hits (filter (lambda (ov) (equal? (caddr ov) face))
                      (buffer-overlays buf))))
    (and (pair? hits) (list (car (car hits)) (cadr (car hits))))))

(define (llm-rewrite--spans buf)
  (let ((p (llm-rewrite-pending buf)))
    (and p
         (append (or (llm-rewrite--overlay buf "llm-rewrite-source")
                     (list (nth 0 p) (nth 1 p)))
                 (or (llm-rewrite--overlay buf "llm-rewrite-block")
                     (list (nth 2 p) (nth 3 p)))))))

;; The all view wears the add and delete faces by line prefix, so the two
;; sides read apart at a glance. The one-sided views are prose and take
;; none: a dash there is a dash. In a morg buffer the diff kind paints
;; the same faces through the registry; this overlay is for the buffers
;; no painter covers.
(define (llm-rewrite--row-faces at line view)
  (cond
    ((not (equal? view 'all)) '())
    ((string-prefix? "-" line)
     (list (list at (+ at (string-byte-length line)) 'diff-del)))
    ((string-prefix? "+" line)
     (list (list at (+ at (string-byte-length line)) 'diff-add)))
    (else '())))

(define (llm-rewrite--block-faces start text view)
  (let loop ((ls (string-split text "\n")) (at start) (acc '()))
    (if (null? ls)
        acc
        (let ((end (+ at (string-byte-length (car ls)))))
          (loop (cdr ls) (+ end 1)
                (append acc (llm-rewrite--row-faces at (car ls) view)))))))

;; the block face covers the BODY alone: the fence lines keep the diff
;; kind's own header color
(define (llm-rewrite--body-span buf spans)
  (let* ((bs (nth 2 spans)) (be (nth 3 spans))
         (text (or (llm-rewrite--text-at buf bs be) ""))
         (lines (string-split text "\n")))
    (if (< (length lines) 2)
        (list bs be)
        (let* ((first-len (string-byte-length (car lines)))
               (last-len (string-byte-length (car (reverse lines))))
               (body-start (min be (+ bs first-len 1)))
               (body-end (max body-start (- be (+ last-len 1)))))
          (list body-start body-end)))))

(define (llm-rewrite--paint! buf spans view)
  (overlay-set! buf 'llm-rewrite-source
    (list (list (nth 0 spans) (nth 1 spans) 'llm-rewrite-source)))
  ;; the block's bounds ride a tracking face no theme colors, so the
  ;; fence lines keep the diff kind's own header color; the visible face
  ;; covers the body alone
  (overlay-set! buf 'llm-rewrite
    (list (list (nth 2 spans) (nth 3 spans) 'llm-rewrite-block)
          (append (llm-rewrite--body-span buf spans) (list 'llm-rewrite))))
  (overlay-set! buf 'llm-rewrite-diff
    (llm-rewrite--block-faces (nth 2 spans)
      (or (llm-rewrite--text-at buf (nth 2 spans) (nth 3 spans)) "")
      view)))

(define (llm-rewrite--bind-keys! buf)
  (local-set-key* buf "C-c y" "llm-rewrite-accept")
  (local-set-key* buf "C-c k" "llm-rewrite-reject")
  (local-set-key* buf "C-c d" "llm-rewrite-diff"))

(define (llm-rewrite--hold! buf spans tail old new directive view)
  (buffer-set-local! buf 'llm-rewrite
    (append spans (list tail old new directive view llm-rewrite--format)))
  (desktop-skip! buf 'llm-rewrite)
  (llm-rewrite--bind-keys! buf)
  (llm-rewrite--paint! buf spans view))

(define (llm-rewrite--release! buf)
  (buffer-set-local! buf 'llm-rewrite #f)
  (overlay-clear! buf 'llm-rewrite)
  (overlay-clear! buf 'llm-rewrite-source)
  (overlay-clear! buf 'llm-rewrite-diff)
  (local-unset-key* buf "C-c y")
  (local-unset-key* buf "C-c k")
  (local-unset-key* buf "C-c d"))

(define (llm-rewrite--text-at buf start end)
  (let ((text (buffer-text buf)))
    (and (<= start end)
         (<= end (string-byte-length text))
         (substring-bytes text start end))))

;; What the block needs after it. A document that already has a blank line
;; there needs nothing; a line that runs straight on needs one.
(define (llm-rewrite--tail-for buf end)
  (let* ((text (buffer-text buf))
         (size (string-byte-length text))
         (rest (substring-bytes text (min end size) (min (+ end 2) size))))
    (cond ((equal? rest "") "")
          ((equal? rest "\n") "")
          ((string-prefix? "\n\n" rest) "")
          ((string-prefix? "\n" rest) "\n")
          (else "\n\n"))))

;; Replacing what the block holds: one delete, one insert, and the record
;; follows the new length. Every verb that changes the block goes through
;; here.
(define (llm-rewrite--put-block! buf p spans text new directive view)
  (buffer-delete-range! buf (nth 2 spans) (- (nth 3 spans) (nth 2 spans)))
  (buffer-insert! buf (nth 2 spans) text)
  (llm-rewrite--hold! buf
    (list (nth 0 spans) (nth 1 spans) (nth 2 spans)
          (+ (nth 2 spans) (string-byte-length text)))
    (llm-rewrite--tail p) (llm-rewrite--old p) new directive view))

;;; --- the two diff blocks ----------------------------------------------------
;;; A rewrite is one change by construction: the passage went out whole and
;;; the block came back whole. So a diff of the two is the lines they still
;;; share at each end and one hunk between them. Nothing matches line by
;;; line in the middle, because there is no second change in there to find.
;;; Every view is one fenced block whose info string names the kind and the
;;; instruction, because a block you meet an hour later has to say what it
;;; was asked for — in bare text, with no renderer's help.

(define (llm-rewrite--common-head a b)
  (let loop ((a a) (b b) (n 0))
    (if (and (pair? a) (pair? b) (equal? (car a) (car b)))
        (loop (cdr a) (cdr b) (+ n 1))
        n)))

(define (llm-rewrite--common-tail a b limit)
  (let loop ((a (reverse a)) (b (reverse b)) (n 0))
    (if (and (pair? a) (pair? b) (< n limit) (equal? (car a) (car b)))
        (loop (cdr a) (cdr b) (+ n 1))
        n)))

(define (llm-rewrite--slice lines from to)
  (let loop ((ls lines) (i 0) (acc '()))
    (cond ((or (null? ls) (>= i to)) (reverse acc))
          ((>= i from) (loop (cdr ls) (+ i 1) (cons (car ls) acc)))
          (else (loop (cdr ls) (+ i 1) acc)))))

(define (llm-rewrite--marked prefix lines)
  (map (lambda (l) (string-append prefix l)) lines))

;; The block is a fenced block, and its kind follows its view: a diff
;; view lands a ```diff fence the diff kind paints, and the whole view
;; lands ```rewrite, so diff paint never touches plain prose. The
;; delimiters are real text: the bare buffer says what the block is and
;; what it was asked, morg folds and lifts it like any fence, and the
;; preview paints it through the fence-kind registry. Accepting strips
;; the fences by structure.
(define (llm-rewrite--fence kind directive body)
  (string-append "```" kind " " directive "\n" body "\n```"))

;; the text between the fences; a block whose fences were edited away is
;; your text, and stays whole
(define (llm-rewrite--body block)
  (let ((lines (string-split block "\n")))
    (if (and (>= (length lines) 2)
             (string-prefix? "```" (car lines))
             (string-prefix? "```" (car (reverse lines))))
        (string-join (reverse (cdr (reverse (cdr lines)))) "\n")
        block)))

;; The fence line is the diff, its view, and the keys that decide it:
;; ```diff theirs · C-c y keeps it · ... The keys come from BUF's own
;; keymap at land time, so a text-only view is complete; a verb with no
;; key there says nothing. The instruction stays off the line: it lives
;; in the record and the preview draws it.
(define (llm-rewrite--fence-args buf view)
  (let* ((verb (lambda (cmd label)
                 (let ((k (key-for-command cmd buf)))
                   (if (equal? k "") #f (string-append k " " label)))))
         (parts (filter (lambda (x) x)
                        (list (llm-rewrite--view-name view)
                              (verb "llm-rewrite-accept" "keeps it")
                              (verb "llm-rewrite-reject" "puts it back")
                              (verb "llm-rewrite-diff" "changes the view")))))
    (string-join parts " · ")))

(define (llm-rewrite-theirs-block new buf)
  (llm-rewrite--fence "diff" (llm-rewrite--fence-args buf 'theirs) new))

(define (llm-rewrite-ours-block old buf)
  (llm-rewrite--fence "diff" (llm-rewrite--fence-args buf 'ours) old))

;; the passage and the rewrite as head context, one hunk, tail context
(define (llm-rewrite--parts old new)
  (let* ((a (string-split old "\n"))
         (b (string-split new "\n"))
         (head (llm-rewrite--common-head a b))
         (tail (llm-rewrite--common-tail a b
                 (- (min (length a) (length b)) head))))
    (list (llm-rewrite--slice a 0 head)
          (llm-rewrite--slice a head (- (length a) tail))
          (llm-rewrite--slice b head (- (length b) tail))
          (llm-rewrite--slice a (- (length a) tail) (length a)))))

(define (llm-rewrite-diff-block old new buf)
  (let ((parts (llm-rewrite--parts old new)))
    (llm-rewrite--fence "diff" (llm-rewrite--fence-args buf 'all)
      (string-join
        (append
          (llm-rewrite--marked " " (nth 0 parts))
          (llm-rewrite--marked "-" (nth 1 parts))
          (llm-rewrite--marked "+" (nth 2 parts))
          (llm-rewrite--marked " " (nth 3 parts)))
        "\n"))))


;; The reply arrives whenever it arrives, so it may only land under the
;; passage it was asked about. It never touches that passage: a blank line
;; and the block go in below it, and both texts stand until you decide.
(define (llm-rewrite--propose! buf start end original new directive)
  (let ((here (llm-rewrite--text-at buf start end)))
    (if (not (equal? here original))
        (message "Rewrite dropped — that passage has changed")
        (let* ((tail (llm-rewrite--tail-for buf end))
               ;; the keys bind first: the fence line names them
               (_ (llm-rewrite--bind-keys! buf))
               (block (llm-rewrite-theirs-block new buf))
               (bstart (+ end 2))
               (bend (+ bstart (string-byte-length block))))
          (buffer-insert! buf end (string-append "\n\n" block tail))
          (llm-rewrite--hold! buf (list start end bstart bend)
                              tail original new directive 'theirs)
          (message (string-append
                     "Rewrite waiting below the passage in "
                     (buffer-modeline-name buf)
                     " · there " (key-for-command "llm-rewrite") " decides and "
                     (key-for-command "llm-rewrite-diff" buf)
                     " shows the diff"))))))

;; Asking again rewrites the block, never the passage: the reject that comes
;; after any number of rounds still has the original to put back. The new
;; instruction becomes the block's header, because that is what the block
;; now answers.
(define (llm-rewrite--refine! buf new directive)
  (let* ((p (llm-rewrite-pending buf))
         (spans (and p (llm-rewrite--spans buf)))
         (block (and spans (llm-rewrite--text-at buf (nth 2 spans) (nth 3 spans)))))
    (cond
      ((not block) (message "The waiting rewrite is gone"))
      ((not (equal? block (llm-rewrite--rendered p buf)))
       (message "The rewrite has been edited — the new version was dropped"))
      (else
        (let* ((view (llm-rewrite--view p))
               (next (append (llm-rewrite--slice p 0 6)
                             (list new directive view))))
          (llm-rewrite--put-block! buf p spans
            (llm-rewrite--render next view buf) new directive view)
          (message (string-append "Rewrite refined · "
                                  (key-for-command "llm-rewrite") " decides")))))))

;; Every view is a rendering of the same two strings, so changing view is a
;; redraw, not a decision.
(define (llm-rewrite-set-view! buf view)
  (let* ((p (llm-rewrite-pending buf))
         (spans (and p (llm-rewrite--spans buf)))
         (block (and spans (llm-rewrite--text-at buf (nth 2 spans) (nth 3 spans)))))
    (cond
      ((not p) (message "No rewrite is waiting"))
      ((not block)
       (llm-rewrite--release! buf)
       (message "The waiting rewrite is gone"))
      ((not (equal? block (llm-rewrite--rendered p buf)))
       (message "The rewrite has been edited — it stays as it is"))
      (else
        (llm-rewrite--put-block! buf p spans
          (llm-rewrite--render p view buf)
          (llm-rewrite--new p) (llm-rewrite--instruction p) view)
        (message (string-append "Rewrite " (llm-rewrite--view-name view) " · "
                                (key-for-command "llm-rewrite-diff" buf)
                                " changes the view"))))))

(define (llm-rewrite-cycle-view! buf)
  (let ((p (llm-rewrite-pending buf)))
    (if (not p)
        (message "No rewrite is waiting")
        (llm-rewrite-set-view! buf (llm-rewrite--next-view (llm-rewrite--view p))))))

(define (llm-rewrite--ask! buf passage directive land)
  (message "LLM rewriting...")
  (llm (llm-rewrite-prompt buf directive passage)
    (lambda (reply)
      (let ((new (llm-rewrite-clean reply)))
        (cond ((not (buffer-exists? buf))
               (message "Rewrite discarded — its buffer was killed"))
              ((equal? new "") (message "The model returned nothing"))
              (else (land new)))))))

;; An empty answer at the prompt takes the instruction the mode leads with.
(define (llm-rewrite--directive buf input)
  (let ((typed (string-trim input)))
    (if (equal? typed "") (car (llm-rewrite-directives buf)) typed)))

(define (llm-rewrite--start! buf)
  (let* ((start (and (mark) (region-beginning)))
         (end (and start (region-end)))
         (old (and start (llm-rewrite--text-at buf start end))))
    (if (or (not old) (equal? old ""))
        (message "No region — set the mark first (C-SPC)")
        (begin
          ;; the region is consumed: the command has it, so the selection
          ;; does not linger under the caret
          (set-mark! #f)
          (minibuffer-read "Rewrite region: " (llm-rewrite-directives buf)
          (lambda (input)
            (let ((directive (llm-rewrite--directive buf input)))
              (llm-rewrite--ask! buf old directive
                (lambda (new)
                  (llm-rewrite--propose! buf start end old new directive))))))))))

;; One key decides. `C-c y`, `C-c k` and `C-c d` live only in the buffer
;; that holds the rewrite, and a key nobody can reach from the window they
;; are looking at is no key at all — so the same `C-c e` that made the
;; rewrite also ends it. The verbs are exact answers, which leaves an
;; instruction that happens to start with "keep" an instruction.
(define *llm-rewrite-keep-answer* "keep it")
(define *llm-rewrite-back-answer* "put it back")

(define (llm-rewrite--view-name view)
  (cond ((equal? view 'all) "all")
        ((equal? view 'ours) "ours")
        (else "theirs")))

(define (llm-rewrite--view-answer view)
  (string-append "show " (llm-rewrite--view-name view)))

(define (llm-rewrite--next-view view)
  (cond ((equal? view 'theirs) 'all)
        ((equal? view 'all) 'ours)
        (else 'theirs)))

;; the two views the block is not in, as answers
(define (llm-rewrite--view-answers view)
  (map llm-rewrite--view-answer
       (filter (lambda (v) (not (equal? v view))) '(all ours theirs))))

(define (llm-rewrite--answer-view answer)
  (let loop ((vs '(all ours theirs)))
    (cond ((null? vs) #f)
          ((equal? answer (llm-rewrite--view-answer (car vs))) (car vs))
          (else (loop (cdr vs))))))

(define (llm-rewrite--review! buf p spans answer)
  (let ((view (llm-rewrite--answer-view answer)))
    (cond
      ((equal? answer "") (message "Rewrite still waiting"))
      ((equal? answer *llm-rewrite-keep-answer*) (llm-rewrite-accept! buf))
      ((equal? answer *llm-rewrite-back-answer*) (llm-rewrite-reject! buf))
      (view (llm-rewrite-set-view! buf view))
      (else
        (llm-rewrite--ask! buf (llm-rewrite--new p) answer
          (lambda (new) (llm-rewrite--refine! buf new answer)))))))

(define (llm-rewrite--again! buf p)
  (let ((spans (llm-rewrite--spans buf)))
    (if (not spans)
        (begin (llm-rewrite--release! buf)
               (message "The waiting rewrite is gone"))
        (minibuffer-read
          "Rewrite waiting (keep it / put it back / show it … / a new instruction): "
          (append (list *llm-rewrite-keep-answer* *llm-rewrite-back-answer*)
                  (llm-rewrite--view-answers (llm-rewrite--view p))
                  (llm-rewrite-directives buf))
          (lambda (input)
            (llm-rewrite--review! buf p spans (string-trim input)))))))

;; A theirs block is the text you see between the fences, edits and all.
;; The all and ours views are renderings of two strings, so what lands
;; from them is the rewrite the block describes.
(define (llm-rewrite--accept-text p block)
  (if (equal? (llm-rewrite--view p) 'theirs)
      (llm-rewrite--body block)
      (llm-rewrite--new p)))

;; Keeping it: the block takes the passage's place, and the passage and the
;; blank line that introduced the block go with it.
(define (llm-rewrite-accept! buf)
  (let* ((p (llm-rewrite-pending buf))
         (spans (and p (llm-rewrite--spans buf)))
         (block (and spans (llm-rewrite--text-at buf (nth 2 spans) (nth 3 spans)))))
    (cond
      ((not p) (message "No rewrite is waiting"))
      ((not block)
       (llm-rewrite--release! buf)
       (message "The waiting rewrite is gone"))
      (else
        (let ((from (nth 0 spans))
              (to (min (buffer-size buf)
                       (+ (nth 3 spans)
                          (string-byte-length (llm-rewrite--tail p)))))
              (text (llm-rewrite--accept-text p block)))
          (buffer-delete-range! buf from (- to from))
          (buffer-insert! buf from text)
          (llm-rewrite--release! buf)
          ;; the decision ends the selection too: nothing lingers
          (with-current-buffer buf (lambda () (set-mark! #f)))
          (message "Rewrite kept"))))))

;; Putting it back: only the block and its blank line go. A block you have
;; since edited is your text, so that one stays.
(define (llm-rewrite-reject! buf)
  (let* ((p (llm-rewrite-pending buf))
         (spans (and p (llm-rewrite--spans buf)))
         (block (and spans (llm-rewrite--text-at buf (nth 2 spans) (nth 3 spans)))))
    (cond
      ((not p) (message "No rewrite is waiting"))
      ((not block)
       (llm-rewrite--release! buf)
       (message "The waiting rewrite is gone"))
      ((not (equal? block (llm-rewrite--rendered p buf)))
       (message "The rewrite has been edited — it stays"))
      (else
        (let ((from (nth 1 spans))
              (to (min (buffer-size buf)
                       (+ (nth 3 spans)
                          (string-byte-length (llm-rewrite--tail p))))))
          (buffer-delete-range! buf from (- to from))
          (llm-rewrite--release! buf)
          (with-current-buffer buf (lambda () (set-mark! #f)))
          (message "Rewrite put back"))))))

(define-command "llm-rewrite"
  "Rewrite the region with the LLM into a block below it; with one waiting, decide it or ask again"
  (lambda ()
    (let* ((buf (current-buffer))
           (p (llm-rewrite-pending buf)))
      (if p (llm-rewrite--again! buf p) (llm-rewrite--start! buf)))))

(define-command "llm-rewrite-accept" "Keep the waiting rewrite in place of the passage"
  (lambda () (llm-rewrite-accept! (current-buffer))))

(define-command "llm-rewrite-reject" "Remove the waiting rewrite and keep the passage"
  (lambda () (llm-rewrite-reject! (current-buffer))))

(define-command "llm-rewrite-diff"
  "Show the waiting rewrite as theirs, all, or ours"
  (lambda () (llm-rewrite-cycle-view! (current-buffer))))

(global-set-key "M-|" "llm-pipe-region")
(global-set-key "C-c e" "llm-rewrite")
(catalog-meta! 'command "llm-rewrite"
  'domain "llm" 'effects '("write" "external" "spend"))
(catalog-meta! 'command "llm-rewrite-accept" 'domain "llm" 'effects '("write"))
(catalog-meta! 'command "llm-rewrite-reject" 'domain "llm" 'effects '("write"))
(catalog-meta! 'command "llm-rewrite-diff" 'domain "llm" 'effects '("write"))

;; gptel's most Emacs-shaped operation: the buffer is both the prompt and
;; the transcript. M-o puts the answer where point was when it was sent. A
;; stateful backend gets one durable session per buffer and only the new tail;
;; the stateless API lane still receives the immutable whole-buffer snapshot.
;; The overlay makes authorship visible without writing chat markers into the
;; document itself.
(define *llm-mode-hooks* '())

(define (llm-mode--paint! buf)
  (overlay-set! buf 'llm-mode-responses
    (map (lambda (range)
           (list (car range) (cadr range) 'llm-response))
         (or (buffer-local buf 'llm-responses) '()))))

(define (llm-mode--sync-ranges! buf)
  ;; Overlays follow edits in the rope. Mirror their adjusted positions into
  ;; a serializable local so desktop restore can repaint the response blocks.
  (when (minor-mode-on? buf "llm-mode")
    (let ((tracked
            (filter (lambda (ov) (equal? (caddr ov) "llm-response"))
                    (buffer-overlays buf))))
      ;; Mode/desktop restoration has a short interval where locals are back
      ;; but derived overlays are not. An unrelated setup edit during that
      ;; interval must not erase the only durable copy of the ranges.
      (when (or (pair? tracked)
                (not (buffer-local buf 'llm-responses))
                (null? (buffer-local buf 'llm-responses)))
        (buffer-set-local! buf 'llm-responses
          (map (lambda (ov) (list (car ov) (cadr ov))) tracked))))))

(define (llm-mode--ensure-hook! buf)
  (unless (assoc buf *llm-mode-hooks*)
    (set! *llm-mode-hooks*
      (cons (list buf
                  (on-change! buf
                    (lambda (pos inserted deleted source)
                      (llm-mode--sync-ranges! buf)
                      ;; Text after the last answer is the next user turn.
                      ;; Editing anything earlier rewrites conversation
                      ;; history, so the next send deliberately starts a new
                      ;; native thread from the edited whole buffer.
                      (let ((end (llm-mode--last-response-end buf))
                            (inline (buffer-local buf 'llm-session-id)))
                        (when (and end
                                   ;; Responses and mode-managed rewrites use
                                   ;; the named-buffer :editor primitives;
                                   ;; streamed replies use this buffer's agent.
                                   (not (equal? source "editor"))
                                   (not (and inline
                                             (equal? source
                                               (string-append "agent:" inline))))
                                   (< pos end))
                          (buffer-set-local! buf 'llm-session-dirty #t))))))
            *llm-mode-hooks*))))

(define (llm-mode--remove-hook! buf)
  (let ((hit (assoc buf *llm-mode-hooks*)))
    (when hit
      (remove-on-change! (cadr hit))
      (set! *llm-mode-hooks*
        (remove (lambda (entry) (equal? (car entry) buf))
                *llm-mode-hooks*)))))

(define (llm-mode--apply! buf)
  (local-set-key* buf "M-o" "llm-send-buffer")
  (local-set-key* buf "C-c m" "llm-set-model")
  (local-set-key* buf "C-c b" "llm-configure")
  (llm-mode--paint! buf)
  (llm-mode--ensure-hook! buf))

(define (llm-mode--teardown! buf)
  (llm-mode-reset-runtime! buf #f)
  (llm-mode--remove-hook! buf)
  (overlay-clear! buf 'llm-mode-responses)
  (local-unset-key* buf "M-o")
  (local-unset-key* buf "C-c m")
  (local-unset-key* buf "C-c b"))

;; the change rule behind M-o's response ranges is registered under the name
;; the buffer had. A renamed chat needs the rule again, under the new one.
(on-buffer-renamed!
  (lambda (old new)
    (when (assoc old *llm-mode-hooks*)
      (llm-mode--remove-hook! old)
      (when (minor-mode-on? new "llm-mode")
        (llm-mode--ensure-hook! new)
        ;; Session callbacks close over the buffer name. Reattach them under
        ;; the new name while preserving the native Codex thread itself.
        (llm-mode-reset-runtime! new #t)))))

(register-minor-mode! "llm-mode" llm-mode--apply! llm-mode--teardown!)

(define-command "llm-mode" "Toggle in-buffer LLM interaction and response formatting"
  (lambda ()
    (if (toggle-minor-mode! "llm-mode")
        (message "LLM mode enabled")
        (message "LLM mode disabled"))))

(mode-doc! "llm-mode"
  "In-buffer LLM interaction. `M-o` sends the document and streams the response at point with a distinct response face; `C-c b` chooses backend, model, effort, and tool presets.")

;; Inline sessions are durable agent conversations by default, matching
;; Codex's editor integrations: one native thread stays attached to the
;; buffer and M-o sends only the next turn.  The direct API lane remains an
;; explicit choice in C-c b for users who want a stateless replay.
(define *llm-mode-connector* "codex-app-server")

;; One model wears two names: the API lane spells it "openai:gpt-5.6-luna" and
;; a subscription connector spells the same model "gpt-5.6-luna".
(define (llm--model-bare m)
  (let ((parts (string-split m ":")))
    (if (> (length parts) 1) (car (cdr parts)) #f)))

;; The name CNAME lists for this model, or #f when that connector does not
;; have the model at all.
(define (connector-model-id cname m)
  (let ((models (if (boundp (quote connector-models)) (connector-models cname) '())))
    (cond ((not m) #f)
          ((member m models) m)
          (else (let ((bare (llm--model-bare m)))
                  (and bare (member bare models) bare))))))

;; the connector that has this model, or #f. Hidden connectors are
;; compatibility names for saved chats; a new session never picks one. The
;; metered lane answers last: it serves nearly every model, and a
;; subscription connector that has the model is the cheaper lane.
(define (llm--connector-owning m)
  (let* ((names (if (boundp (quote connector-names)) (connector-names) '()))
         (ordered
           (append (filter (lambda (c) (not (connector-can? c 'metered))) names)
                   (filter (lambda (c) (connector-can? c 'metered)) names))))
    (let loop ((cs ordered))
      (cond ((null? cs) #f)
            ((connector-model-id (car cs) m) (car cs))
            (else (loop (cdr cs)))))))

;; The model names the lane. A model the default connector does not have must
;; reach the connector that does: Codex answers a model id it does not know
;; with a 400 on the first send, so a buffer holding an API model id — the
;; editor's own default model is one — got no answer and no reason for it.
(define (llm-connector-for-model m)
  (cond ((not (boundp (quote connector-models))) *llm-mode-connector*)
        ((not m) *llm-mode-connector*)
        ((connector-model-id *llm-mode-connector* m) *llm-mode-connector*)
        ((llm--connector-owning m))
        (else "api")))

(define (buffer-llm-connector buf)
  (or (buffer-local buf 'llm-connector)
      (llm-connector-for-model (buffer-llm-model buf))))

(define (buffer-llm-model buf)
  (or (buffer-local buf 'llm-model) (llm-model)))

;; Runtime ids are buffer identities, not turn identities. The local survives
;; desktop restore and buffer rename; the persisted counter prevents a new
;; buffer from colliding with an old renamed one.
(define *llm-inline-next* 0)

(persist-global! 'llm-inline-next
  (lambda () *llm-inline-next*)
  (lambda (v) (set! *llm-inline-next* v)))

(define (llm-mode--session-id buf)
  (or (buffer-local buf 'llm-session-id)
      (begin
        (set! *llm-inline-next* (+ *llm-inline-next* 1))
        (let ((id (string-append "inline-" (number->string *llm-inline-next*))))
          (buffer-set-local! buf 'llm-session-id id)
          id))))

(define (llm-mode--runtime-live? buf)
  (let ((id (buffer-local buf 'llm-session-id)))
    (and id (member id (agent-list)) (not (equal? (agent-status id) 'dead)) #t)))

;; KEEP-THREAD preserves Codex's durable thread identity while dropping only
;; this editor process. A changed history or connector passes #f and starts a
;; genuinely new conversation on the next send.
(define (llm-mode-reset-runtime! buf keep-thread)
  (let ((id (buffer-local buf 'llm-session-id)))
    (when (and id (member id (agent-list))) (llm-session-close! id)))
  (unless keep-thread (buffer-set-local! buf 'llm-thread-id #f))
  (buffer-set-local! buf 'llm-session-dirty #f)
  #t)

(define-command "llm-set-model" "Choose the model for M-o in this buffer"
  (lambda ()
    (let ((buf (current-buffer)))
      (minibuffer-read
        (string-append "Model for this buffer (now " (buffer-llm-model buf) "): ")
        *llm-models*
        (lambda (model)
          (unless (equal? (string-trim model) "")
            (buffer-set-local! buf 'llm-model model)
            ;; Codex fixes model identity in the thread instructions. Resume
            ;; the same thread through a fresh runtime with the new override.
            (llm-mode-reset-runtime! buf #t)
            (message (string-append "M-o · " model))))))))

;; Which buffers is an M-o question about? A grouped buffer answers: a
;; writing document, a code-mode source file, or the scratch beside either.
;; The tools then read and edit those buffers by name, instead of guessing
;; from (buffer-list). The names are sorted, so the note changes only when
;; the membership changes — a plain buffer switch must not rewrite the
;; cached prefix (see chat-preamble-body).
(define (llm-mode--group-note buf)
  (let* ((g (buffer-group buf))
         ;; group-buffers reads the LIVE buffer list, and this walks the
         ;; members. group-docs takes the MRU path, which still names
         ;; buffers the user killed — one of those kills the send.
         (docs (if g
                   (remove (lambda (b)
                             (or (chat-buffer? b) (equal? b (group-chat-name g))))
                           (group-buffers g))
                   '())))
    (if (null? docs)
        ""
        (string-append
          "\n\nThe user works in the editor buffer group \""
          (group-display-name g) "\":\n"
          (fold (lambda (acc d)
                  (string-append acc "- \"" d "\""
                    (let ((m (buffer-local d 'mode-name)))
                      (if m (string-append " (" m ")") ""))
                    "\n"))
                "" (sort docs))
          *chat-edit-protocol*
          (chat-code-note docs)))))

;; A group that holds a code-mode buffer adds that mode's own instructions.
;; The mode owns the words (code-instructions, packages/code.scm); the two
;; prompt paths ask for them here so both surfaces say the same thing. The
;; package loads after this file, so a build without it changes nothing.
(define (chat-code-note docs)
  (if (boundp (quote code-mode-instructions))
      (let ((note (code-mode-instructions docs)))
        (if (equal? note "") "" (string-append "\n\n" note)))
      ""))

;; The prompt names ambient buffers but never copies their changing content.
;; The agent pulls the structure it needs through the live outline APIs.
(define (chat-ambient-context-note docs)
  (if (null? docs)
      ""
      (string-append
        "\n\nEach group member named above is ambient context for this chat. "
        "The editor does not attach its outline or text. Pull each relevant "
        "outline before you answer or edit. Use (code-outline \"NAME\") for "
        "source and (markdown-outline \"NAME\") for Markdown.\n\n")))

;; ...and the voice that goes with them: a chat over one code-mode buffer is
;; not a writing companion, and telling it to match the document's voice
;; asks a coding session to imitate prose.
(define (chat-code-companion? docs)
  (not (equal? (chat-code-note docs) "")))

;; Inline/document requests use the same session facade, connector resolution,
;; normalized event stream and tool loop as chat; only their presentation
;; differs. One entry exists while the buffer's durable session is running a
;; turn; completion removes the entry, not the session.
(define *llm-inline-sends* '())

(define (llm-inline-put! entry)
  (let ((id (car entry)))
    (set! *llm-inline-sends*
      (cons entry
            (remove (lambda (e) (equal? (car e) id)) *llm-inline-sends*)))))

(define (llm-inline-add-chunk! id text)
  (let ((e (assoc id *llm-inline-sends*)))
    (when (and e (not (equal? text "")))
      ;; (id buffer completion accumulated error chunk-handler)
      (llm-inline-put!
        (list id (car (cdr e)) (car (cdr (cdr e)))
              (string-append (car (cdr (cdr (cdr e)))) text)
              (car (cdr (cdr (cdr (cdr e)))))
              (car (cdr (cdr (cdr (cdr (cdr e))))))))
      ;; The response belongs in its document as it arrives. Waiting for
      ;; turn-end hid useful prose when a later tool call stalled or failed.
      ((car (cdr (cdr (cdr (cdr (cdr e)))))) text))))

(define (llm-inline-error! id text)
  (let ((e (assoc id *llm-inline-sends*)))
    (when e
      (llm-inline-put!
        (list id (car (cdr e)) (car (cdr (cdr e)))
              (car (cdr (cdr (cdr e)))) text)))))

(define (llm-inline-finish! id)
  (let ((e (assoc id *llm-inline-sends*)))
    (when e
      ;; Remove before invoking user presentation code: completion may start
      ;; another turn on this same session.
      (set! *llm-inline-sends*
        (remove (lambda (x) (equal? (car x) id)) *llm-inline-sends*))
      (let ((result (car (cdr (cdr (cdr e)))))
            (error (car (cdr (cdr (cdr (cdr e))))))
            (completion (car (cdr (cdr e)))))
        ;; Completion closes a streamed range. It also keeps a partial reply
        ;; readable when the backend reports an error after one or more chunks.
        (completion result error)
        (when error (message (string-append "LLM failed · " error)))))))

(define (llm-inline-events! id events)
  (for-each
    (lambda (event)
      (let ((type (plist-get event 'type)))
        (cond ((equal? type 'chunk)
               (llm-inline-add-chunk! id (or (plist-get event 'text) "")))
              ((equal? type 'thread-id)
               (let ((e (assoc id *llm-inline-sends*)))
                 (when e
                   (buffer-set-local! (cadr e) 'llm-thread-id
                     (plist-get event 'id)))))
              ((equal? type 'error)
               ;; A failed turn ends in turn-failed, which the status machine
               ;; consumes: no turn-end ever reaches this buffer. Finish the
               ;; send here, or the reason stays invisible and the entry
               ;; leaks. Finishing removes the entry, so a turn-end that does
               ;; arrive after an error is a no-op.
               (llm-inline-error! id (or (plist-get event 'text) "request failed"))
               (llm-inline-finish! id))
              ;; Codex asks before every MCP tool call (an elicitation
              ;; becomes this event). A chat draws a permission block and
              ;; waits for the user; an inline send has no such surface, so
              ;; an unanswered ask parked the session in needs_attention and
              ;; the turn died there — the tools looked absent. Inline sends
              ;; already declare their policy as allow, so answer here.
              ((equal? type 'permission)
               (llm-inline-allow! id event))
              ;; Codex represents an MCP server's own approval prompt as an
              ;; elicitation question. Inline mode has no question surface,
              ;; and its declared tool policy is already allow.
              ((equal? type 'question)
               (llm-inline-answer! id event))
              ((equal? type 'turn-end)
               (llm-inline-finish! id)))))
    events))

;; the option that says yes for the rest of the session, else the plain yes
(define (llm-inline--allow-option event)
  (let loop ((os (or (plist-get event 'options) '())) (once #f))
    (cond ((null? os) (or once "allow_once"))
          ((equal? (car (car os)) "allow_always") "allow_always")
          (else (loop (cdr os) (or once (car (car os))))))))

(define (llm-inline-allow! id event)
  (let ((rpc (plist-get event 'rpc-id)))
    (when rpc
      (agent-permission-respond! id rpc (llm-inline--allow-option event)))))

(define (llm-inline-answer! id event)
  (let ((qid (plist-get event 'id))
        (answers (or (plist-get event 'answers) '())))
    (when qid
      ;; An enum question chooses its first allowed answer. A question with
      ;; no choices is the boolean approval emitted by the compos MCP bridge.
      (agent-question-respond! id qid
        (if (pair? answers) (car answers) "true")))))

;; Presets supply the complete tool surface. The runtime opens lazily on the
;; first send, stays attached to BUF, and (for Codex) records a native thread
;; id that a restored buffer resumes.
(define (llm-mode--complete buf wire display model mark handler chunk-handler)
  (let* ((id (llm-mode--session-id buf))
         (connector (buffer-llm-connector buf))
         ;; the name this connector knows the model by: the API lane says
         ;; "openai:gpt-5.6-luna" and Codex says "gpt-5.6-luna"
         (model (or (connector-model-id connector model) model))
         (effort (buffer-local buf 'llm-effort))
         (config (agent-resolve-config
                   (append
                     (list 'connector connector 'model model
                           'buffer buf 'mark mark
                           ;; ReqLLM consumes SPECS above directly. ACP
                           ;; sessions instead mount the MCP servers named by
                           ;; these same presets at session/new, exactly as a
                           ;; chat buffer does. Without this, an ACP-backed
                           ;; llm-mode buffer advertises the companion by name
                           ;; but has no editor tool with which to read it.
                           'presets (if (boundp (quote chat-presets-of))
                                        (chat-presets-of buf)
                                        '())
                           'persist-thread #t)
                     (let ((thread (buffer-local buf 'llm-thread-id)))
                       (if thread (list 'thread-id thread) '()))
                     (if effort (list 'effort effort) '())))))
    (when (and (member id (agent-list)) (equal? (agent-status id) 'dead))
      (llm-session-close! id))
    (llm-inline-put! (list id buf handler "" #f chunk-handler))
    (unless (llm-mode--runtime-live? buf)
      (llm-session-open! id config
        (lambda (_id _display)
          (list 'turns '()
                'system (string-append
                          (if (boundp (quote chat-tool-system))
                              (chat-tool-system buf)
                              "")
                          (llm-mode--group-note buf))
                'tools (if (boundp (quote chat-extra-tool-specs))
                           (chat-extra-tool-specs buf)
                           '())
                'dispatcher llm-tool-call))
        (lambda (_id events) (llm-inline-events! id events))
        (lambda (_id _role _blocks _wire) #t)
        ;; Inline M-o historically executed its selected tools directly; chat
        ;; sessions continue to use the shared permission policy and UI.
        (lambda (_id _name _kind _raw) 'allow)))
    (llm-session-send! id wire display)))

(define (llm-mode--last-response-end buf)
  (let loop ((ranges (or (buffer-local buf 'llm-responses) '())) (end #f))
    (if (null? ranges) end (loop (cdr ranges) (cadr (car ranges))))))

;; Record the newest response while it streams. Existing response ranges stay
;; intact, and their overlays continue to follow edits elsewhere in the buffer.
(define (llm-mode--stream-range! buf start end replace-last)
  (let* ((ranges (or (buffer-local buf 'llm-responses) '()))
         (before (if (and replace-last (pair? ranges))
                     (reverse (cdr (reverse ranges)))
                     ranges)))
    (buffer-set-local! buf 'llm-responses
      (append before (list (list start end))))
    (llm-mode--paint! buf)))

(define (llm-mode--last-response-start buf)
  (let ((ranges (or (buffer-local buf 'llm-responses) '())))
    (and (pair? ranges) (car (car (reverse ranges))))))

(define (llm-mode--stateful? buf)
  (not (connector-can? (buffer-llm-connector buf) 'stateless)))

(define (llm-mode--wire-text buf snapshot)
  (let ((end (llm-mode--last-response-end buf)))
    (if (and (llm-mode--stateful? buf)
             end
             ;; A legacy/restored transcript without a native thread has
             ;; nothing server-side to continue. Seed its first thread with
             ;; the whole buffer; only a live or resumable session gets a
             ;; delta turn.
             (or (llm-mode--runtime-live? buf)
                 (buffer-local buf 'llm-thread-id))
             (not (buffer-local buf 'llm-session-dirty)))
        (let ((tail (substring-bytes snapshot end (string-byte-length snapshot))))
          (if (equal? (string-trim tail) "") "" tail))
        snapshot)))

;; Where a reply goes. A reply is a block of its own, so it belongs after the
;; block point sits in — never inside it, and never above the prompt just
;; typed. The scan is morg-scan, the one fence-aware line scanner, so an
;; answer cannot land between two backtick lines, and the landing agrees
;; with every Morg view of the same bytes.
(define (llm-mode--blocks buf)
  ;; The document as (START END) blocks. A fenced block runs from its opening
  ;; fence to the end of its closing fence; any other run of non-blank lines
  ;; is a paragraph; a blank line separates two of them.
  (let loop ((es (morg-scan buf)) (open #f) (last 0) (acc '()))
    (if (null? es)
        (reverse (if open (cons (list open last) acc) acc))
        (let* ((e (car es))
               (start (car e))
               (k (morg-kind e))
               (end (+ start (string-byte-length (cadr e))))
               (flushed (if open (cons (list open last) acc) acc)))
          (cond
            ((equal? k 'open) (loop (cdr es) start end flushed))
            ((equal? k 'code) (loop (cdr es) open end acc))
            ((equal? k 'close)
             (loop (cdr es) #f end (cons (list (or open start) end) acc)))
            ((and (equal? k 'text) (equal? (string-trim (cadr e)) ""))
             (loop (cdr es) #f end flushed))
            (else (loop (cdr es) (or open start) end acc)))))))

(define (llm-mode--insert-at buf pos)
  ;; Between two blocks POS is already the right place.
  (let* ((size (buffer-size buf))
         (at (max 0 (min pos size))))
    (let loop ((bs (llm-mode--blocks buf)))
      (cond ((null? bs) at)
            ((and (<= (car (car bs)) at) (<= at (cadr (car bs))))
             (cadr (car bs)))
            (else (loop (cdr bs)))))))

(define (llm-mode--aim! buf at)
  ;; The reply streams at the buffer's agent mark, and that mark otherwise
  ;; only remembers where the last reply ended — above anything written
  ;; since. A document aims it at this send. A chat's mark owns the input
  ;; region and is never ours to move.
  (unless (chat-buffer? buf)
    (buffer-set-local! buf 'agent-saved-mark at)))

(define-command "llm-send-buffer" "Send this document to the LLM and stream its reply below the block at point"
  (lambda ()
    (let* ((buf (current-buffer))
           (at (point))
           (context (buffer-text (current-buffer)))
           ;; Where the answer belongs: after the block point sits in. The
           ;; agent mark on its own only remembers where the last reply
           ;; ended, so a prompt typed below it would be answered above.
           (insert-at (llm-mode--insert-at buf at))
           (model (buffer-llm-model (current-buffer))))
      ;; Like gptel-send, the first invocation turns on the buffer-local
      ;; interaction mode. writing-mode enables it eagerly.
      (unless (minor-mode-on? buf "llm-mode")
        (enable-minor-mode! buf "llm-mode"))
      ;; A rewritten earlier turn cannot be reconciled with a native thread.
      ;; Close it and send the edited whole transcript as a new conversation.
      (let ((resync (buffer-local buf 'llm-session-dirty)))
        (when resync (llm-mode-reset-runtime! buf #f))
        (let ((wire (if resync context (llm-mode--wire-text buf context))))
          (cond
            ((and (llm-mode--runtime-live? buf)
                  (not (equal? (agent-status (llm-mode--session-id buf)) 'idle)))
             (message "LLM is still working"))
            ((and (llm-mode--stateful? buf) (equal? wire ""))
             (message "Nothing new to send"))
            (else
              (message (string-append "LLM thinking · " model))
              (llm-mode--aim! buf insert-at)
              (let ((streamed #f))
                (llm-mode--complete buf wire context model insert-at
                  (lambda (result error)
                    (if (not (buffer-exists? buf))
                        (message "LLM reply discarded — its buffer was killed")
                        (let ((id (llm-mode--session-id buf)))
                          ;; A non-streaming backend can still return one final
                          ;; result. The normal path only appends the newline.
                          (when (and (not streamed) (not (equal? result "")))
                            (let* ((end (agent-append! id
                                          (string-append "\n\n" result)))
                                   (start (- end
                                             (string-byte-length result))))
                              (llm-mode--stream-range! buf start end #f)
                              (set! streamed #t)))
                          (when streamed
                            (when (not error)
                              ;; The streaming path has not written its final
                              ;; line break yet. Keep it outside the response.
                              (let* ((start (llm-mode--last-response-start buf))
                                     (end (- (agent-append! id "\n") 1)))
                                (llm-mode--stream-range! buf start end #t)))
                            ;; The untouched suffix was part of the sent
                            ;; snapshot when insertion happened in the middle.
                            (buffer-set-local! buf 'llm-session-dirty
                              (< insert-at (string-byte-length context))))
                          (when (not error) (message "LLM response inserted")))))
                  (lambda (chunk)
                    (when (buffer-exists? buf)
                      (let* ((id (llm-mode--session-id buf))
                             (first (not streamed))
                             (end (agent-append! id
                                    (if first (string-append "\n\n" chunk) chunk)))
                             (start (if first
                                        (- end (string-byte-length chunk))
                                        (llm-mode--last-response-start buf))))
                        (llm-mode--stream-range! buf start end (not first))
                        (set! streamed #t)))))))))))))

(global-set-key "M-o" "llm-send-buffer")
(global-set-key "C-c m" "llm-set-model")
(global-set-key "C-c b" "llm-configure")
(catalog-meta! 'command "llm-send-buffer"
  'domain "llm" 'effects '("write" "external" "spend"))
(catalog-meta! 'command "llm-mode" 'domain "llm" 'effects '("write"))
(catalog-meta! 'mode "llm-mode" 'domain "llm" 'effects '("write"))

;;; --- chat buffer (gptel-style) -------------------------------------------------
;;; *chat* is an ordinary editable buffer. Type after the "### You" marker,
;;; press C-c RET, and the whole buffer becomes the conversation context.


(define (chat-prompt-marker) "\n### You\n")
(define (chat-reply-marker) "\n### Assistant\n")

;; a real mode so desktop restore can rebuild the local keys. A chat that
;; carries the block model ('agent-saved-mark) is a rich companion surface:
;; it opts into the same native renderer as agent threads, RET sends, and
;; a stale "⋯ thinking" from before a restart is swept away.
(mode-doc! "chat-mode"
  "A conversation with a model. `RET` sends what you typed and `S-RET` starts a new line. `C-g` stops the answer. `C-c C-k` clears the conversation but keeps the model.")

(define *chat-restart-message*
  "Continue the work interrupted by the editor restart. Recheck the current workspace state before acting.")

;; Code-mode can grant a chat permission to continue after a daemon restart.
;; Other chats restore their transcript but do not start external work.
(define (chat-recover-interrupted! buf)
  (when (and (buffer-exists? buf)
             (buffer-local buf 'chat-turn-active)
             (not (chat-live-runtime? buf)))
    (if (boundp (quote agent-send-msg!))
        (begin
          (chat-finalize-hung-tools! buf)
          (let ((slug (chat-attach! buf)))
            (agent-send-msg! slug *chat-restart-message*)
            (message (string-append "agent " slug ": continuing after restart"))))
        (debounce! (string-append "chat-recover:" buf) 100
                   chat-recover-interrupted! buf))))

;; the transcript half of a lost turn: tool cards still "running", and
;; permission or question blocks that nobody can answer any more.
;; agent-transcript.scm owns these fns and loads later, so guard each call.
(define (chat-finalize-hung-tools! buf)
  (when (boundp (quote agent-finalize-running-tools!))
    (agent-finalize-running-tools! buf "failed"))
  (when (boundp (quote agent-block-drop-kind!))
    (agent-block-drop-kind! buf "permission")
    (agent-block-drop-kind! buf "question"))
  (when (boundp (quote chat-activity!))
    (chat-activity! buf #f)))

;; #t when the buffer says a turn runs and its live runtime says none does.
;; A real turn holds the agent in 'running or 'needs_attention, so 'idle
;; under the flag means the turn-end event was lost — a reload mid-turn,
;; or a crashed event handler. A restart cannot clear this state: the flag
;; is a conversation local, and the dead-runtime recovery does not fire
;; because the runtime is alive.
(define (chat-turn-stale? buf)
  (and (buffer-local buf 'chat-turn-active)
       (chat-live-runtime? buf)
       (equal? (agent-status (buffer-local buf 'agent-slug)) 'idle)))

;; land what the lost turn-end would have landed. Never invents a reply.
(define (chat-drop-stale-turn! buf)
  (buffer-set-local! buf 'chat-turn-active #f)
  (buffer-set-local! buf 'agent-cancelling #f)
  (buffer-set-local! buf 'agent-turn-text #f)
  (buffer-set-local! buf 'agent-turn-any #f)
  (chat-finalize-hung-tools! buf)
  (message "chat unstuck: the hung turn is cleared, RET sends again"))

(define-mode "chat-mode"
  (lambda ()
    (let ((buf (current-buffer))
          (interrupted? (buffer-local (current-buffer) 'chat-turn-active)))
      (buffer-provenance-stop! buf "mode:chat-mode" "mode-policy" "mode")
      (local-set-key "C-c m" "chat-set-model")
      (local-set-key "C-c $" "chat-cost")
      (local-set-key "C-c b" "llm-configure")
      (local-set-key "C-c C-k" "chat-reset")
      ;; On desktop restore EVERY runtime local is a lie: the process it
      ;; described died with the daemon. Clear the whole class — not just
      ;; the 'agent-queued that once deadlocked RET — so that bug cannot
      ;; grow a new head. Guarded on the runtime being gone, because this
      ;; same setup fn also runs via set-mode! on LIVE chats, where the
      ;; slug is the only handle on a running thread.
      (chat-sweep-runtime-locals! buf)
      (when interrupted?
        (if (chat-live-runtime? buf)
            ;; the runtime survived but its turn did not: land the lost
            ;; turn-end so the chat does not stay hung on a tool call
            (when (chat-turn-stale? buf) (chat-drop-stale-turn! buf))
            (debounce! (string-append "chat-recover:" buf) 100
                       chat-recover-interrupted! buf)))
      ;; a chat saved before the conversation of record existed carries the
      ;; old (role text) pairs — read them once, here, so a restored chat
      ;; has a record like any other
      (chat-record-migrate! buf)
      ;; a .chat file just opened from disk: if we wrote it, its header
      ;; restores the identity and its transcript becomes the record, so
      ;; the conversation continues instead of restarting. Headerless files
      ;; (hand-written, or saved before this) are left exactly as they are.
      (when (and (buffer-path buf)
                 (not (buffer-local buf 'agent-saved-mark))
                 (boundp (quote chat-file-init!)))
        (chat-file-init! buf))
      ;; legacy: pre-group companions carried a 'companion-of pointer —
      ;; upgrade both ends to the 'group tag (idempotent, so desktop
      ;; restore migrates old sessions by itself)
      (let ((doc (buffer-local buf 'companion-of)))
        (when (and doc (not (buffer-local buf 'group)))
          (let ((g (or (and (buffer-exists? doc) (buffer-local doc 'group))
                       doc)))
            (buffer-set-local! buf 'group g)
            (when (and (buffer-exists? doc)
                       (not (buffer-local doc 'group)))
              (buffer-set-local! doc 'group g)))))
      (when (buffer-local buf 'agent-saved-mark)
        ;; the view is identity: default it only when never chosen (S11)
        (unless (buffer-local buf 'render-mode)
          (buffer-set-local! buf 'render-mode "agent"))
        (buffer-set-local! buf 'agent-marker-bytes
          (string-byte-length *chat-input-marker*))
        ;; self-heal a mangled marker: edits from before the DEL guard
        ;; existed could eat marker bytes, and the display clamp hid the
        ;; damage. A tail that does not start with the marker is rewritten
        ;; (any draft in a corrupt input region is not recoverable).
        (let* ((size (buffer-size buf))
               (m (min (chat-mark buf) size))
               (mb (string-byte-length *chat-input-marker*))
               (tail-end (min size (+ m mb))))
          (unless (equal? (substring-bytes (buffer-text buf) m tail-end)
                          *chat-input-marker*)
            (buffer-delete-range! buf m (- size m))
            (buffer-append! buf *chat-input-marker*)
            (buffer-set-local! buf 'agent-saved-mark m)))
        ;; Rebuild presentation from the CONVERSATION locals — overlays and
        ;; folds come back, and chrome belonging to a runtime that didn't
        ;; survive the restart is dropped. None of this depends on there
        ;; being a live thread (the sweep above may just have removed the
        ;; slug), so it is not gated on one.
        (when (boundp (quote agent-block-drop-kind!))
          (agent-block-drop-kind! buf "permission")
          ;; a LIVE runtime owns its waiting line, its queue, and its
          ;; pending prose tail; a dead one leaves stale chrome to sweep
          (unless (chat-live-runtime? buf)
            ;; the waiting line and its block leave together
            (agent-sweep-waiting! buf)
            ;; a queued message the dead runtime never read returns to
            ;; the input
            (agent-unqueue-renders-to-input! buf)
            ;; prose the dead runtime streamed but never revealed joins
            ;; the prose block
            (agent-adopt-prose-tail! buf))
          (let ((ovs (buffer-local buf 'agent-overlays)))
            (when ovs (overlay-set! buf 'agent ovs)))
          (agent-apply-folds! buf))
        ;; the modeline states the chat's identity — its connector, which
        ;; survives everything. A chat that has never attached one will
        ;; get "api" on its first send, so that is what it advertises.
        (if (and (buffer-local buf 'agent-connector)
                 (boundp (quote agent-update-modeline!)))
            (agent-update-modeline! buf)
            (buffer-set-local! buf 'modeline-info
              (string-append "api · " (llm-model))))
        (chat-clear-waiting! buf)
        ;; ONE key set for every chat: RET is agent-send everywhere — a
        ;; chat without a runtime attaches the api backend on first send
        (when (boundp (quote agent-install-keys!))
          (agent-install-keys! buf))
        (local-set-key "S-RET" "newline")
        (local-set-key "C-c C-v" "chat-toggle-view")
        ;; a restored point can land inside the marker — typing/pasting
        ;; there corrupts the input boundary (bytes end up pre-marker)
        (chat-snap-to-input!)))))

;; there is only one chat interface: the rich group-chat surface. C-c c
;; opens the current buffer's group chat (founding a group if needed);
;; from inside a chat it is a no-op.
(define-command "chat" "Open the group chat for this buffer"
  (lambda ()
    (let ((cur (current-buffer)))
      (unless (chat-buffer? cur)
        (group-chat-show! (group-ensure! cur))))))

;;; The system prompt is the cache prefix. Every byte of it is resent on
;;; every turn and on every tool round, so nothing that CHANGES may live
;;; here: one edit to a watched buffer used to invalidate the whole cached
;;; prefix, and the chat paid the cache-write surcharge again from turn
;;; one. So the system prompt names the group's buffers and states the
;;; edit protocol. Both stay stable for the life of the chat. The agent reads
;;; live context with tools on every turn. Chat never attaches document text.

;; how to read and change a live buffer. One string: the two copies of
;; this paragraph had drifted apart. Prompt composition adds it as the stable
;; chat preamble after the shared guidance and MCP note.
(define *chat-edit-protocol*
  (string-append
    "Never guess a buffer's contents. For a source buffer, read the "
    "structure first with eval-scheme: (code-outline \"NAME\") lists every "
    "definition as (LINE KIND NAME DOC), (code-read \"NAME\" LINE) returns "
    "the one definition that holds LINE, and (code-replace! \"NAME\" LINE "
    "NEW) swaps it. (code-sexp \"NAME\" ANCHOR) selects the smallest "
    "expression around unique ANCHOR text; (code-sexp-replace! \"NAME\" "
    "ANCHOR NEW) replaces it. Do not call (buffer-text) on a whole source "
    "buffer when the outline answers. Read a prose buffer with "
    "(buffer-text \"NAME\"), and change any buffer with "
    "(buffer-replace! \"NAME\" OLD NEW) — exact unique old string -> new; "
    "it edits the live buffer, never the file. Make the smallest edit "
    "that does the job. Treat \"buffer\" and \"window\" precisely. When the "
    "user says \"open it in the other buffer\" or \"show it in the other "
    "buffer\", show the named target with (display-buffer-other-window! NAME). "
    "This call preserves the selected window. When the user says \"switch to "
    "the other buffer\", run (run-command \"previous-buffer\"). Do not ask a "
    "question when the target is clear."))

(define (chat-preamble buf)
  (let* ((g (buffer-group buf))
         (docs (if g (group-docs g) '())))
    (chat-preamble-body g docs)))

(define (chat-preamble-body g docs)
  (cond
      ((null? docs)
       (string-append
         "You are the assistant in an editor chat buffer. The transcript "
         "follows; reply to the last user turn only, in markdown.\n\n"))
      ((null? (cdr docs))
       ;; one document: the writing-companion voice, or the coding one
       (let* ((doc (car docs))
              (code? (chat-code-companion? docs)))
         (string-append
           (if code?
               "You are the user's coding companion in a side chat. They are "
               "You are the user's writing companion in a side chat. They are ")
           (if code? "working in " "writing in ")
           "the editor buffer named \"" doc "\". "
           (let ((role (and g (buffer-group-role doc g))))
             (if role
                 (string-append "This is the group's \"" role "\" buffer. ")
                 ""))
           (chat-ambient-context-note docs)
           *chat-edit-protocol*
           (if code? "" " Match the document's voice.")
           (chat-code-note docs)
           "\n\nThe chat transcript follows; reply to the last user turn "
           "only, in markdown.\n\n")))
      (else
       ;; several buffers: enumerate the group in a fixed order. group-docs is
       ;; MRU-ordered, so a plain switch between two members would reorder this
       ;; list and rewrite the system prompt, and the prompt cache pays for the
       ;; whole prefix again. sort by name: the order changes only when
       ;; membership changes, not when the user switches buffers.
       (string-append
         "You are the user's companion in a side chat for their buffer "
         "group \"" (group-display-name g) "\". The group's buffers:\n"
         (fold (lambda (acc d)
                 (string-append acc "- \"" d "\""
                   (let ((role (buffer-group-role d g)))
                     (if role (string-append " as " role) ""))
                   (let ((m (buffer-local d 'mode-name)))
                     (if m (string-append " (" m ")") ""))
                   "\n"))
               "" (sort docs))
         (chat-ambient-context-note docs)
         *chat-edit-protocol*
         (chat-code-note docs)
         "\n\nThe chat transcript follows; reply to the last user turn "
         "only, in markdown.\n\n"))))

;;; --- chat backends -------------------------------------------------------------
;;; A chat can ride an ACP agent (claude-code, codex — subscription billing)
;;; instead of the metered API: the buffer stays the same conversation, a
;;; thread binds to it by slug, and the agent's MCP servers come from the
;;; chat's presets plus the editor's own tool proxy. C-c b switches.

;; opts (a config plist) rides in front, so per-call keys — cmd, model,
;; cwd — win over the connector's declared config, first-wins
;; the slug IS the chat's durable id ('chat-id), made git-ref safe for
;; the agent/<slug> worktree branch. A per-boot counter collides across
;; restarts — a restored buffer can claim a live slug and take its
;; events — and a stale 'agent-slug local from an old boot is just as
;; wrong, so neither is consulted: the chat's runtime belongs to the chat.
(define (chat-runtime-slug buf)
  (string-join (string-split (chat-stable-id! buf) ":") "-"))

(define (chat-attach-agent! buf connector &optional model opts)
  (let ((slug (chat-runtime-slug buf))
        ;; a model pinned on the buffer (C-c m before the first send, or a
        ;; .chat header) is part of the chat's identity — carry it in, but
        ;; only if it actually belongs to THIS connector: a bare id left
        ;; over from an earlier ACP session (its own "default" sentinel,
        ;; say) must not ride into the api lane's wire unmodified
        (model (if (and model (not (equal? model "")))
                   model
                   (agent-model-for-connector buf connector))))
    (buffer-set-local! buf 'agent-slug slug)
    (buffer-set-local! buf 'agent-connector connector)
    (when (and model (not (equal? model "")))
      (buffer-set-local! buf 'agent-model model))
    (let ((mark (or (buffer-local buf 'agent-saved-mark)
                    ;; plain chat: give it the marker structure threads use
                    (let ((m (buffer-size buf)))
                      (buffer-append! buf *chat-input-marker*)
                      (buffer-set-local! buf 'agent-marker-bytes
                        (string-byte-length *chat-input-marker*))
                      (buffer-set-local! buf 'render-mode "agent")
                      m))))
      (buffer-set-local! buf 'agent-saved-mark mark)
      (agent-install-keys! buf)
      (agent-update-modeline! buf)
      ;; the previous incarnation of this chat's session can still be
      ;; registered — a dead backend keeps its process. Free the id so the
      ;; same chat can open it again.
      (when (member slug (agent-list))
        (llm-session-close! slug))
      (llm-session-open! slug
        (append (list 'buffer buf 'mark mark)
                (agent-resolve-config
                  (append
                    ;; isolation (packages/worktrees.scm): an isolated
                    ;; thread gets its own worktree as cwd
                    (if (boundp (quote agent-worktree-opts))
                        (agent-worktree-opts buf slug opts)
                        (or opts '()))
                    (list 'connector connector 'buffer buf
                          'presets (if (boundp (quote chat-presets-of))
                                       (chat-presets-of buf)
                                       '()))
                    (let ((effort (buffer-local buf 'agent-effort)))
                      (if effort (list 'effort effort) '()))
                    (if (and model (not (equal? model "")))
                        (list 'model model)
                        '())))))
      slug)))

;; Every chat surface is built the same way: one meta card of help, then
;; the >>> you: input region. Only the card's words differ, so only the
;; words are a parameter — the two builders had drifted into setting
;; different locals for the same layout.
(define (chat-surface-init! buf title lines)
  (let ((help (string-append title "\n" lines)))
    (buffer-append! buf help)
    (chat-blocks-push! buf 0 (string-byte-length help) "meta" '())
    (buffer-set-local! buf 'agent-saved-mark (string-byte-length help))
    (buffer-set-local! buf 'agent-marker-bytes
      (string-byte-length *chat-input-marker*))
    (buffer-append! buf *chat-input-marker*)
    buf))

;; a task chat's surface, used by (execute ...)
(define (chat-task-init! buf label)
  (chat-surface-init! buf (string-append "chat · " label)
    (string-append
      "RET sends · C-g aborts · C-RET interrupts · TAB folds tool output · "
      "C-c b LLM and tools · C-c m model\n")))

;; a chat saved as a file IS a revivable conversation: the transcript
;; format is ### You / ### Assistant (whole buffer = context) and .chat
;; files open straight into chat-mode. One save gesture — C-x C-s — does
;; the right thing: block chats flatten to that portable form via this
;; helper; everything else saves its text.
(define (chat-flatten buf)
  (and (buffer-local buf 'agent-saved-mark)
       (pair? (chat-turns buf))
       (let loop ((ts (reverse (chat-turns buf))) (acc ""))
         (if (null? ts)
             (string-append acc (chat-prompt-marker))
             (loop (cdr ts)
                   (string-append acc
                     (if (equal? (car (car ts)) "user")
                         (chat-prompt-marker)
                         (chat-reply-marker))
                     (cadr (car ts)) "\n"))))))

;;; --- .chat files carry their identity ------------------------------------------
;;; A flattened transcript is text; a chat is text PLUS who was running it.
;;; One optional header line closes that gap, so an opened .chat continues
;;; where it ran instead of starting over on the default backend:
;;;
;;;   #+chat: (connector "codex" model "gpt-5.5" presets (dev) permission-mode approve)
;;;
;;; The header is written by us and read on visit. It never reaches a
;;; model: chat-flatten (the seed) does not include it. Headerless files —
;;; anything written before this, or by hand — behave exactly as before.

(define *chat-file-header* "#+chat:")

(define (chat-header-line buf)
  (string-append *chat-file-header* " (connector "
    (value->string (or (buffer-local buf 'agent-connector) "api"))
    (let ((m (buffer-local buf 'agent-model)))
      (if m (string-append " model " (value->string m)) ""))
    (let ((effort (buffer-local buf 'agent-effort)))
      (if effort (string-append " effort " (value->string effort)) ""))
    (let ((ps (buffer-local buf 'chat-presets)))
      (if (pair? ps) (string-append " presets " (value->string ps)) ""))
    " permission-mode "
    (symbol->string (if (boundp (quote chat-permission-mode))
                        (chat-permission-mode buf)
                        'approve))
    ")\n"))

;;; The v2 section carries what the transcript cannot: the conversation of
;;; record, tool calls and tool results included, as one JSON line below
;;; the transcript. Everything above it is exactly what v1 wrote, so a v2
;;; file still reads as a v1 file, and a v1 file (or a hand-written one)
;;; still opens — it simply has no blocks to replay.

(define *chat-record-marker* "#+chat-record: ")

;; what C-x C-s writes: identity, the portable transcript, then the record
(define (chat-file-text buf)
  (let ((body (chat-flatten buf)))
    (and body
         (string-append (chat-header-line buf) body
           (let ((r (chat-record buf)))
             (if (null? r)
                 ""
                 (string-append "\n" *chat-record-marker*
                                (json-encode (reverse r)) "\n")))))))

;; where the record section starts, in bytes, or #f
(define (chat-file-record-at text)
  (string-index text (string-append "\n" *chat-record-marker*)))

;; the recorded turns, oldest first, or #f
(define (chat-file-record text)
  (let ((i (chat-file-record-at text)))
    (and i
         (let* ((start (+ i 1 (string-byte-length *chat-record-marker*)))
                (rest (substring-bytes text start (string-byte-length text)))
                (nl (string-index rest "\n"))
                (v (json-parse (if nl (substring-bytes rest 0 nl) rest))))
           (and (pair? v) v)))))

;; the header's plist, or #f. Read INSIDE a quote so a hand-edited file can
;; never execute anything: the reader sees one quoted datum, and a failed
;; read just means "no header".
(define (chat-parse-header line)
  (and (string-prefix? *chat-file-header* line)
       (let ((r (eval-string-safe
                  (string-append "(quote "
                                 (substring line (string-length *chat-file-header*)
                                            (string-length line))
                                 ")"))))
         (and (equal? (car r) 'ok) (pair? (cadr r)) (cadr r)))))

;; "### You\nhi\n\n### Assistant\nhello\n" -> (("user" "hi") ("assistant" "hello"))
(define (chat-parse-transcript text)
  (let loop ((parts (cdr (string-split text "\n### "))) (acc '()))
    (if (null? parts)
        (reverse acc)
        (let* ((p (car parts))
               (role (cond ((string-prefix? "You\n" p) "user")
                           ((string-prefix? "Assistant\n" p) "assistant")
                           (else #f)))
               ;; string-index counts bytes, so the cut must too — a
               ;; transcript is arbitrary prose, not ASCII
               (body (and role
                          (string-trim
                            (substring-bytes p (string-index p "\n")
                                             (string-byte-length p))))))
          (loop (cdr parts)
                (if (and role (not (equal? body "")))
                    (cons (list role body) acc)
                    acc))))))

;; a headered .chat opened from disk becomes a live chat again: its
;; identity comes back, its turns become the conversation of record (the
;; truth every backend runs against), and the rich surface is rebuilt from
;; those turns so RET continues the conversation.
(define (chat-file-init! buf)
  (let* ((text (buffer-text buf))
         (nl (string-index text "\n"))
         (line (if nl (substring-bytes text 0 nl) text))
         (header (chat-parse-header line)))
    (when header
      (for-each
        (lambda (pair)
          (let ((v (plist-get header (car pair))))
            (when v (buffer-set-local! buf (cadr pair) v))))
        '((connector agent-connector) (model agent-model) (effort agent-effort)
          (presets chat-presets) (permission-mode chat-permission-mode)))
      (let* ((end (or (chat-file-record-at text) (string-byte-length text)))
             (recorded (chat-file-record text))
             (turns (chat-parse-transcript (substring-bytes text (or nl 0) end))))
        ;; v2 replays the record whole — tool calls and tool results come
        ;; back, so the next request repeats the prefix the file recorded.
        ;; v1 has only the transcript: its turns become text turns.
        (buffer-set-local! buf 'chat-wire-turns
          (if recorded
              (reverse recorded)
              (map (lambda (t) (list 'role (car t)
                                     'blocks (list (list "text" (car (cdr t))))))
                   (reverse turns))))
        ;; rebuild the surface from the turns, exactly as a live chat
        ;; renders them — the header and the ### markers are file format,
        ;; not transcript
        (buffer-delete-range! buf 0 (buffer-size buf))
        (buffer-set-local! buf 'agent-blocks '())
        (buffer-set-local! buf 'agent-saved-mark 0)
        (for-each
          (lambda (t)
            (let ((start (chat-render! buf
                           (if (equal? (car t) "user")
                               (string-append "\n>>> you: " (cadr t) "\n\n")
                               (string-append (cadr t) "\n")))))
              (chat-blocks-push! buf start (chat-mark buf)
                (if (equal? (car t) "user") "user" "prose")
                (if (equal? (car t) "user") (list (cadr t)) '()))))
          turns)
        (buffer-append! buf *chat-input-marker*)
        (buffer-set-local! buf 'agent-marker-bytes
          (string-byte-length *chat-input-marker*))
        (buffer-set-local! buf 'render-mode "agent")
        ;; a fresh ACP session has to be told what was already said; the
        ;; api lane replays the record on every request anyway
        (buffer-set-local! buf 'agent-seed-context
          (and (pair? turns)
               (boundp (quote connector-can?))
               (not (chat-stateless? buf))))
        ;; the rewrite is presentation, not an edit the user made
        (buffer-mark-saved! buf))
      #t)))

;;; --- what a chat is made of -----------------------------------------------------
;;; The reset/restore bug class (a stale 'agent-queued deadlocking RET, a
;;; banner from a runtime that no longer exists, a help card fed back to a
;;; model as context) had ONE cause: which local means what was implicit,
;;; and reset, restore, and save each kept their own partial list. So the
;;; partition is defined once, here, and everything else consults it.
;;;
;;; STANDING RULE: any new chat buffer-local goes into exactly one of these
;;; three lists, in the same commit that introduces it.

;; who the chat IS — survives reset, restart, and save
;; ('default-directory is on every buffer, chats included: where it was
;; opened from, which is identity, not conversation or runtime)
;; 'render-mode is the chat's chosen VIEW ("agent" rich, "plain" text) —
;; a choice about the chat, so identity (S11)
(define chat-identity-locals
  '(group group-id modeline-groups chat-id group-meta group-layout group-noise
    ;; the last name the chat DERIVED from its group: a name the person
    ;; typed does not match it, and that is what makes a manual rename stick
    chat-derived-name
    agent-connector agent-model agent-effort
    chat-presets chat-permission-mode render-mode default-directory
    ;; the directory the spawner chose; group companions never override it
    chat-directory
    agent-permission-profile window-class header-line
    ;; which locals are markers is a fact about how the buffer works, so
    ;; it survives a reset with the rest of the identity
    marker-locals
    code-agent-saved
    workspace-id workspace-name workspace-root workspace-project-root
    workspace-backend workspace-daemon workspace-llm-defaults
    workspace-isolation-choice project-defaults-inherited))

;; what was SAID — survives restart and save; reset clears it
;; ('chat-turns is the pre-record shape: chat-record-migrate! reads it once
;; on setup and clears it, and it stays listed so a reset cannot leave one
;; behind for the migration to read again)
(define chat-conversation-locals
  '(chat-wire-turns chat-turns agent-blocks agent-overlays agent-folds
    agent-open-cards
    chat-turn-active
    ;; where the unrevealed prose tail starts: text the model said that
    ;; the prose block does not cover yet — restore adopts it, reset
    ;; clears it with the transcript
    agent-prose-from
    chat-tool-specs
    ;; The exact named system fragments this conversation sends. The first
    ;; turn sets them. Prompt refresh replaces them. Reset clears them.
    chat-prompt-snapshot
    chat-cost chat-last-usage chat-usage-total
    ;; a one-shot note for the next send (a skill body a mode pushed):
    ;; undelivered it must survive a restart, and a reset drops it
    chat-note-once
    ;; the file this conversation logs itself to under <compos-home>/chats:
    ;; a reset starts a new conversation, which gets a new file, and the
    ;; old file stays as the archive
    chat-log-id
    agent-saved-mark agent-marker-bytes))

;; PROCESS state — mirrors a live runtime, so it is always stale after a
;; restart and meaningless after a reset: both clear it wholesale
;; ('agent-queued is retired — queued messages live in the transcript as
;; "queued" blocks now — but stays listed so old sessions' stale values
;; are still swept)
(define chat-runtime-locals
  '(agent-slug agent-queued agent-waiting chat-waiting chat-activity
    agent-cancelling agent-seed-context agent-tool-bodies
    agent-turn-text agent-turn-any chat-compacting
    agent-models agent-mode agent-modes chat-mcp-dirty
    chat-history-pos chat-history-draft
    agent-unstick agent-scroll-top
    code-agent-switch-pending prompt-parts))

(define (chat-clear-locals! buf keys)
  (for-each (lambda (k) (buffer-set-local! buf k #f)) keys))

;; a chat whose runtime is gone (restored from desktop, or crashed) is
;; carrying a description of a process that no longer exists — drop it.
;; A LIVE runtime's locals are the handle on it and must never be swept.
(define (chat-live-runtime? buf)
  (let ((slug (buffer-local buf 'agent-slug)))
    (and slug
         (boundp (quote agent-list))
         (member slug (agent-list))
         ;; slugs restart at a1 on every boot: a live slug bound to a
         ;; DIFFERENT buffer is another chat's runtime, not this one's.
         ;; Say #f so the sweep clears the stale local.
         (let ((owner (plist-get (agent-info slug) 'buffer)))
           (or (not owner) (equal? owner buf)))
         #t)))

(define (chat-sweep-runtime-locals! buf)
  (unless (chat-live-runtime? buf)
    (chat-clear-locals! buf chat-runtime-locals)))

;; wipe the conversation, keep the identity: group, backend, model,
;; presets and permission mode survive; every chat comes back as the one
;; rich surface (a legacy plain chat upgrades on reset). Idempotent.
(define-command "chat-reset" "Reset this chat: clear the transcript, start fresh"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (not (or (chat-buffer? buf) (buffer-local buf 'agent-saved-mark)))
          (message "not a chat buffer")
          (let ((g (buffer-group buf)))
            ;; FIRST: resolve anything the runtime is waiting on. A pending
            ;; permission answered after its blocks are gone is the
            ;; blind-banner race; killing the thread resolves it cancelled.
            (let ((slug (buffer-local buf 'agent-slug)))
              (when (and slug (boundp (quote llm-session-close!)))
                (unless (equal? (agent-status slug) 'dead)
                  (llm-session-close! slug))))
            (overlay-clear! buf "all")
            ;; every tag: a reset empties the buffer, so no owner's ranges
            ;; still mean anything
            (fold-clear! buf 'all)
            (chat-clear-locals! buf chat-conversation-locals)
            (chat-clear-locals! buf chat-runtime-locals)
            (buffer-delete-range! buf 0 (buffer-size buf))
            (group-chat-init! buf (or g buf))
            (set-mode! "chat-mode")
            (end-of-buffer!)
            (message "Chat reset"))))))

;; the manual door for the same repair the mode setup runs on restore. A
;; turn that shows as running while the runtime is idle or gone stays hung
;; forever without it, because no event will ever clear the flag.
(define-command "chat-unstick" "Clear a turn this chat shows as running when no runtime runs one"
  (lambda ()
    (let ((buf (current-buffer)))
      (cond
        ((not (or (chat-buffer? buf) (buffer-local buf 'agent-saved-mark)))
         (message "not a chat buffer"))
        ((not (buffer-local buf 'chat-turn-active))
         (message "no turn is stuck in this chat"))
        ((and (chat-live-runtime? buf) (not (chat-turn-stale? buf)))
         (message "this turn is live: C-g cancels it"))
        (else (chat-drop-stale-turn! buf))))))

;;; --- switching, transparently ---------------------------------------------------
;;; "Transparent" means testable: the buffer, its group, the record,
;;; presets, permission mode, cost history, and keybindings survive EVERY
;;; switch — the user just keeps typing. Keys are free (RET is agent-send
;;; on every lane), so one function with two mechanisms covers it:
;;;
;;;   live session + backend takes the model + target is offered
;;;       -> set_model in place; server-side context survives
;;;   anything else (lane change, dead session, model not takeable)
;;;       -> close the handle, attach the new backend, seed the transcript

;; can this chat's RUNNING backend take this model without a new session?
(define (chat-model-takeable? buf slug model)
  (and slug
       (not (equal? (agent-status slug) 'dead))
       (let ((cname (or (buffer-local buf 'agent-connector) *default-connector*)))
         (or (connector-can? cname 'stateless)   ; no session to lose
             (let ((offered (map car (or (buffer-local buf 'agent-models) '()))))
               (and (pair? offered) (member model offered)))))))

;; a transcript from before the mark was a buffer-local: it sits at the
;; marker's last occurrence
(define (chat-legacy-mark buf)
  (let loop ((ms (re-find* *chat-input-marker* (buffer-text buf)))
             (last (buffer-size buf)))
    (if (null? ms) last (loop (cdr ms) (car (car ms))))))

;; ONE attach. A chat that never had a runtime and a chat whose runtime
;; died are the same situation: put a fresh thread on the chat's OWN
;; connector — identity survives resets, restarts, and the runtime sweep,
;; so a restored claude-code chat comes back as claude-code — and tell it
;; what was already said. The two functions that did this had drifted:
;; one reset 'agent-queued and rescued a legacy mark, the other decided
;; seeding from a different test.
(define (chat-attach! buf)
  (let* ((cname (or (buffer-local buf 'agent-connector) "api"))
         (mark (or (buffer-local buf 'agent-saved-mark) (chat-legacy-mark buf)))
         (said (string-trim (agent-seed-transcript buf))))
    (buffer-set-local! buf 'agent-saved-mark mark)
    ;; a fresh ACP session starts empty and has to be seeded; the api lane
    ;; replays the record on every request anyway
    (buffer-set-local! buf 'agent-seed-context
      (and (not (connector-can? cname 'stateless)) (> mark 0) (not (equal? said ""))))
    (let ((slug (chat-attach-agent! buf cname)))
      (unless (equal? said "")
        (message (string-append "agent " slug ": revived (fresh session)")))
      slug)))

(define (chat-ensure-runtime! buf)
  (or (buffer-local buf 'agent-slug) (chat-attach! buf)))

;; the one switch. connector #f keeps the current one; model "" means the
;; connector's own default. An omitted effort preserves it on the same lane;
;; "default" asks the backend to use the selected model's default.
(define (chat-switch! buf connector model &optional effort)
  (let* ((slug (buffer-local buf 'agent-slug))
         (cur (or (buffer-local buf 'agent-connector) *default-connector*))
         (cname (or connector cur))
         (same-lane? (equal? cname cur)))
    (cond
      ;; in place: nothing restarts, so nothing can be lost
      ((and same-lane? slug (not (equal? (agent-status slug) 'dead))
            (or (equal? model "")
                (and (chat-model-takeable? buf slug model)
                     (llm-session-set-model! slug model)))
            (or (not effort) (llm-session-set-effort! slug effort)))
       (unless (equal? model "") (buffer-set-local! buf 'agent-model model))
       (when effort
         (buffer-set-local! buf 'agent-effort
           (if (equal? effort "default") #f effort)))
       (agent-update-modeline! buf)
       'in-place)
      (else
        ;; identity that belongs to the OLD backend must not follow the
        ;; conversation across (a foreign model id is silently ignored by
        ;; an adapter while the modeline keeps repeating it)
        (unless same-lane?
          (buffer-set-local! buf 'agent-models #f)
          (buffer-set-local! buf 'agent-modes #f)
          (buffer-set-local! buf 'agent-mode #f)
          (buffer-set-local! buf 'agent-effort #f))
        (when effort
          (buffer-set-local! buf 'agent-effort
            (if (equal? effort "default") #f effort)))
        (buffer-set-local! buf 'chat-mcp-dirty #f)
        ;; the restart itself is agent-reconnect!'s job — the same one
        ;; C-RET and a preset change use. Reimplementing it here is how
        ;; the two paths drifted.
        (if slug
            (agent-reconnect! slug cname model)
            (begin
              (buffer-set-local! buf 'agent-connector cname)
              (buffer-set-local! buf 'agent-model (if (equal? model "") #f model))
              (chat-attach! buf)))
        'reattached))))

(define (chat-llm-apply! buf connector model effort)
  (chat-switch! buf connector (if (equal? model "default") "" model) effort)
  (message
    (string-append "chat LLM: " connector
      (if (equal? model "default") "" (string-append " · " model))
      (if (equal? effort "default") "" (string-append " · " effort))
      " — the conversation carries over")))

;; The configuration menu keeps recent complete choices, not three unrelated
;; input histories. The transient records one final choice when it closes.
(define *llm-config-history* '())
(define llm-config-history-limit 10)

(persist-global! 'llm-config-history
  (lambda () *llm-config-history*)
  (lambda (v) (set! *llm-config-history* v)))

(define (llm-config-combination buf)
  (let ((chat? (equal? (buffer-local buf 'mode-name) "chat-mode")))
    (list
      (or (buffer-local buf (if chat? 'agent-connector 'llm-connector))
          (if chat? *default-connector* "codex-app-server"))
      (or (buffer-local buf (if chat? 'agent-model 'llm-model)) "default")
      (or (buffer-local buf (if chat? 'agent-effort 'llm-effort)) "default"))))

(define (llm-config-remember! combination)
  (set! *llm-config-history*
    (take-n
      (cons combination
        (remove (lambda (old) (equal? old combination)) *llm-config-history*))
      llm-config-history-limit))
  combination)

;; One configuration surface for every LLM frontend. Chat buffers apply the
;; choice to their durable session; ordinary buffers persist it as llm-mode
;; locals, and their next turn resumes or starts the matching session.
(define (llm-config-apply! buf connector model effort)
  (if (equal? (buffer-local buf 'mode-name) "chat-mode")
      (chat-llm-apply! buf connector model effort)
      (begin
        (let ((same-connector
                (equal? connector (buffer-llm-connector buf))))
          ;; A model/effort change can resume the same Codex thread with new
          ;; overrides. A connector change cannot carry a foreign thread id.
          (llm-mode-reset-runtime! buf same-connector))
        (buffer-set-local! buf 'llm-connector connector)
        (buffer-set-local! buf 'llm-model
          (if (equal? model "default") #f model))
        (buffer-set-local! buf 'llm-effort
          (if (equal? effort "default") #f effort))
        (unless (minor-mode-on? buf "llm-mode")
          (enable-minor-mode! buf "llm-mode"))
        (message
          (string-append "LLM: " connector
            (if (equal? model "default") "" (string-append " · " model))
            (if (equal? effort "default") "" (string-append " · " effort))))))
  (when (boundp (quote workspace-llm-defaults-note!))
    (workspace-llm-defaults-note! buf)))

;; Transient uses these catalog helpers to show the live model choices.
(define (chat-live-model-entry buf connector model)
  (and (equal? connector (buffer-local buf 'agent-connector))
       (let loop ((entries (or (buffer-local buf 'agent-models) '())))
         (cond ((null? entries) #f)
               ((and (pair? (car entries))
                     (equal? (car (car entries)) model))
                (car entries))
               (else (loop (cdr entries)))))))

;; A live backend model/list wins. Its compact entry is
;; (id display-name effort-values default-effort). Before that arrives (or
;; while choosing another connector), use the same normalized LLMDB catalog
;; that req_llm uses. Unknown is deliberately empty: never offer a
;; connector-wide superset that the selected model may reject.
(define (chat-model-effort-info buf connector model)
  (let* ((actual (if (equal? model "default")
                     (or (and (equal? connector (buffer-local buf 'agent-connector))
                              (buffer-local buf 'agent-model))
                         (and (connector-can? connector 'stateless) (llm-model)))
                     model))
         (live (and actual (chat-live-model-entry buf connector actual))))
    (if live
        (list (if (pair? (cddr live)) (caddr live) '())
              (if (pair? (cdr (cdr (cdr live))))
                  (car (cdr (cdr (cdr live)))) ""))
        (let* ((r (and actual (llm-model-reasoning actual)))
               (effort (and r (plist-get r 'effort))))
          (list (or (and effort (plist-get effort 'values)) '())
                (or (and effort (plist-get effort 'default)) ""))))))

(define (chat-model-options buf connector)
  (let ((live (and (equal? connector (buffer-local buf 'agent-connector))
                   (buffer-local buf 'agent-models))))
    (if (pair? live)
        (map (lambda (entry) (list (car entry) (cadr entry))) live)
        (map (lambda (m) (list m "")) (connector-models connector)))))

(define (llm-config-read! prompt candidates confirm cancel)
  (minibuffer-read* prompt candidates
    (list (list 'confirm confirm)
          (list 'cancel cancel)
          (list 'style "palette"))))

;; Candidate palettes select their first row. Put CURRENT there and label it
;; explicitly; unlike pre-filling the minibuffer, this keeps every alternative
;; visible while still showing which value is active.
(define (llm-config-current-first candidates current)
  (let ((selected
          (map (lambda (c)
                 (list (car c)
                       (string-append "current"
                         (if (equal? (cadr c) "") ""
                             (string-append " · " (cadr c))))))
               (filter (lambda (c) (equal? (car c) current)) candidates)))
        (others (filter (lambda (c) (not (equal? (car c) current))) candidates)))
    (append selected others)))

;; Compatibility command for saved bindings and existing callers.
(define-command "chat-set-backend" "Choose this chat's LLM backend, model, and effort"
  (lambda () (run-command "llm-configure")))

;;; --- rich chat transcript (the agent thread design) ---------------------------
;;; A companion chat maintains the exact locals the native agent renderer
;;; reads — render-mode "agent", 'agent-blocks byte ranges, 'agent-saved-mark
;;; + 'agent-marker-bytes for the >>> you: input region — so it inherits the
;;; serif prose, user cards, and tool cards wholesale. No runtime behind it:
;;; the mark lives in 'agent-saved-mark, the conversation in 'chat-wire-turns.
;;; Buffer layout: [help][transcript … mark][>>> you: ][input].

(define *chat-input-marker* "\n>>> you: ")

(define (chat-mark buf) (or (buffer-local buf 'agent-saved-mark) 0))

(define (chat-blocks-push! buf start end kind meta)
  (buffer-set-local! buf 'agent-blocks
    (cons (append (list start end kind) meta)
          (or (buffer-local buf 'agent-blocks) '()))))

(define (chat-blocks-drop! buf kind)
  (buffer-set-local! buf 'agent-blocks
    (filter (lambda (b) (not (equal? (car (cdr (cdr b))) kind)))
            (or (buffer-local buf 'agent-blocks) '()))))

;; append at the mark — after every recorded range, so stored offsets
;; never shift; the input region past the marker slides along
(define (chat-render! buf text)
  (- (buffer-insert-at-local! buf 'agent-saved-mark text)
     (string-byte-length text)))

;;; --- the input region ------------------------------------------------------------
;;; Layout: [transcript … mark][marker][live input]
;;;
;;; ONE function says where it starts. "Where does the input begin" used to
;;; be computed five ways — twice in Scheme off the runtime mark, once off
;;; the buffer-local, once in the payload builder, once in the renderer —
;;; and only one of them knew about 'agent-marker-bytes. Every reader takes
;;; it from here now, and the payload ships the same number to the client.
;;;
;;; It reads buffer-locals, never a runtime: a restored chat has no thread
;;; until its first send, and up-arrow has to work before then.

;; just past the marker: where the live input begins. A message queued
;; mid-turn does not live here — RET echoes it into the transcript as a
;; muted "queued" block (agent-echo-queued!), and the input clears.
(define (chat-input-start buf)
  (+ (chat-mark buf)
     (or (buffer-local buf 'agent-marker-bytes)
         (string-byte-length *chat-input-marker*))))

;; (START END) of the LIVE input — what RET sends
(define (chat-input-region buf)
  (list (chat-input-start buf) (buffer-size buf)))

(define (chat-input-text buf)
  (let ((r (chat-input-region buf)))
    (substring-bytes (buffer-text buf) (car r) (car (cdr r)))))

(define (chat-clear-input! buf)
  (let ((r (chat-input-region buf)))
    (buffer-delete-range! buf (car r) (- (car (cdr r)) (car r)))))

(define (chat-replace-input! buf text)
  (chat-clear-input! buf)
  (end-of-buffer!)
  (unless (equal? text "") (insert! text)))

;;; --- the conversation of record ------------------------------------------------
;;; ...moved to packages/chat.scm: the record, compaction, healing, the
;;; tool surface, the usage ledger, and the direct lane's turn context.
;;; Policy about a conversation is not the editor's business.



;; a mode whose buffer went stale OFF screen registers a catch-up
;; here; the switcher runs it for every window it just (re)filled.
;; diff-mode uses it: hidden diffs skip the expensive re-render and
;; catch up the moment they show.
(define *buffer-shown-hooks* '())
(define (on-buffer-shown! fn)
  (set! *buffer-shown-hooks* (cons fn *buffer-shown-hooks*)))

(define (windows-shown-catchup!)
  (for-each (lambda (w)
              (let ((b (car (cdr w))))
                (for-each (lambda (fn) (fn b)) *buffer-shown-hooks*)))
            (window-list)))

;;; --- winner: layout undo ------------------------------------------------------
;;; Every arrangement about to be destroyed goes onto a per-frame ring;
;;; C-c <left> walks back through them, C-c <right> walks forward. The
;;; wrapped window mutators and the group switch push; the walk itself
;;; does not, so undo cannot pollute its own history.

(define *winner-depth* 12)

;; a compound operation (a group switch builds its layout in steps)
;; saves ONCE and inhibits the wrapped mutators' pushes underneath

(define (winner-save!)
  (unless *winner-inhibit*
    (let ((ring (or (frame-local 'winner-ring) '()))
          (now (window-tree)))
      (unless (and (pair? ring) (equal? (car ring) now))
        (set-frame-local! 'winner-ring (take-n (cons now ring) *winner-depth*)))
      (set-frame-local! 'winner-pos #f))))

(define (winner--restore idx)
  (let ((ring (or (frame-local 'winner-ring) '())))
    (if (or (< idx 0) (>= idx (length ring)))
        (message (if (< idx 0) "at the latest layout" "no earlier layout"))
        (begin
          (set-frame-local! 'winner-pos idx)
          (window-tree-set! (nth idx ring))
          (message (string-append "layout "
                     (number->string (+ idx 1)) "/"
                     (number->string (length ring))))))))

(define (winner-previous!)
  (set! *winner-inhibit* #f)
  (let ((pos (frame-local 'winner-pos)))
    (if pos
        (winner--restore (+ pos 1))
        ;; entering the walk: the CURRENT arrangement joins the ring
        ;; first, so next can return to it.
        (begin
          (winner-save!)
          (winner--restore 1)))))

(define (winner-next!)
  (let ((pos (frame-local 'winner-pos)))
    (if (and pos (> pos 0))
        (winner--restore (- pos 1))
        (message "at the latest layout"))))

;; The ring holds layouts, and a layout names its buffers. A rename that
;; does not reach the ring makes winner-undo restore a window on a dead
;; name. Every frame keeps its own ring, so the sweep walks them all.
(on-buffer-renamed!
  (lambda (old new)
    (set! *frame-locals*
      (map (lambda (frame-entry)
             (list (car frame-entry)
                   (map (lambda (item)
                          (if (equal? (car item) 'winner-ring)
                              (list 'winner-ring
                                    (map (lambda (tree)
                                           (window-tree-rename tree old new))
                                         (car (cdr item))))
                              item))
                        (car (cdr frame-entry)))))
           *frame-locals*))))

;; These names describe the operation as a desktop switch: the saved tree
;; contains both the window arrangement and the buffer shown in each window.
(define-command "winner-previous" "Switch to the previous window and buffer arrangement"
  (lambda () (winner-previous!)))
(define-command "winner-next" "Switch to the next window and buffer arrangement"
  (lambda () (winner-next!)))
(define-command "winner-undo" "Restore the previous window and buffer arrangement"
  (lambda () (winner-previous!)))
(define-command "winner-redo" "Walk forward to a later window and buffer arrangement"
  (lambda () (winner-next!)))

(for-each
  (lambda (name) (catalog-meta! 'command name 'domain 'windows 'effects '(write display)))
  '("winner-previous" "winner-next" "winner-undo" "winner-redo"))

;; the window mutators the keyboard reaches (C-x 1/2/3/0, popups) push
;; the arrangement they are about to destroy
(define builtin-window-tree-set! window-tree-set!)
(define (window-tree-set! tree)
  (builtin-window-tree-set! tree)
  (window-state-changed!))

(define builtin-delete-other-windows! delete-other-windows!)
(define (delete-other-windows!)
  (winner-save!)
  (builtin-delete-other-windows!)
  (window-state-changed!))

(define builtin-split-window! split-window!)
(define (split-window! dir &optional ratio)
  (winner-save!)
  (let ((result (if ratio
                    (builtin-split-window! dir ratio)
                    (builtin-split-window! dir))))
    (window-state-changed!)
    result))

(define builtin-delete-window! delete-window!)
(define (delete-window!)
  (winner-save!)
  (let ((result (builtin-delete-window!)))
    (window-state-changed!)
    result))

(define builtin-delete-window-id! delete-window-id!)
(define (delete-window-id! id)
  (let ((result (builtin-delete-window-id! id)))
    (window-state-changed!)
    result))

;;; --- the modeline dashboard -----------------------------------------------------
;;; modeline-expand toggles a popup that says everything about HERE: the
;;; buffer, its modes, its group — and the LLM ledger with a spend
;;; sparkline. The modeline is the summary; this is the expansion.
;;; Clicking the modeline's name opens it too.


(define-style! 'dashboard "
.dash { font-family: var(--font-sans); padding: 2px 6px 8px; }
.dash-head { display: flex; align-items: flex-end; gap: 16px;
             padding: 10px 16px 12px; border-bottom: 1px solid var(--border, #e2dbc9); }
.dash-name { font-family: var(--font-serif); font-size: 24px; letter-spacing: -0.4px; }
.dash-file { font-family: var(--font-mono); font-size: 11px; color: var(--dim-fg, #8a857a);
             padding-top: 4px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.dash-headmain { min-width: 0; }
.dash-sp { flex: 1; }
.dash-pills { display: flex; flex-wrap: wrap; justify-content: flex-end; gap: 6px; }
.dash-pill { padding: 2px 9px; border-radius: 999px; border: 1px solid var(--border, #cbc4b1);
             color: var(--dim-fg, #57534a); font-family: var(--font-mono); font-size: 10.5px;
             white-space: nowrap; }
.dash-pill.warn { border-color: var(--diff-hunk-fg, #7a5a1a); color: var(--diff-hunk-fg, #7a5a1a); }
.dash-pill.good { border-color: var(--diff-add-fg, #2e6b45); color: var(--diff-add-fg, #2e6b45); }
.dash-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); }
.dash-cell { padding: 12px 18px 14px; display: flex; flex-direction: column; gap: 8px;
             border-right: 1px solid var(--border, #e2dbc9); min-width: 0; }
.dash-cell:last-child { border-right: none; }
.dash-title { font-family: var(--font-mono); font-size: 9.5px; letter-spacing: 0.18em;
              text-transform: uppercase; color: var(--dim-fg, #8a857a); }
.dash-big { font-family: var(--font-mono); font-size: 13px; font-weight: 600;
            color: var(--accent-fg, #26356b); }
.dash-row { display: flex; align-items: baseline; gap: 8px;
            font-family: var(--font-mono); font-size: 11.5px; }
.dash-k { color: var(--dim-fg, #8a857a); flex: 0 0 auto; }
.dash-row .dash-sp { border-bottom: 1px dotted var(--border, #cfc8b6);
                     transform: translateY(-3px); }
.dash-v { color: var(--default-fg, #1b1a17); text-align: right; min-width: 0;
          overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.dash-v.dim { color: var(--dim-fg, #b3ac9c); }
.dash-v.good { color: var(--diff-add-fg, #2e6b45); }
.dash-v.warn { color: var(--diff-hunk-fg, #7a5a1a); }
.dash-chips { display: flex; flex-wrap: wrap; gap: 5px; }
.dash-chip { padding: 2px 8px; border-radius: 6px; background: var(--window-bg, #fdfcf8);
             border: 1px solid var(--border, #e2dbc9); font-family: var(--font-mono);
             font-size: 10.5px; color: var(--dim-fg, #57534a); }
.dash-spark { display: flex; align-items: flex-end; gap: 2px; height: 44px; }
.dash-bar { flex: 1; border-radius: 1px; background: var(--accent-fg, #26356b);
            min-width: 3px; }
.dash-bar.hot { background: var(--diff-hunk-fg, #7a5a1a); }
.dash-bar.h1 { height: 4px; } .dash-bar.h2 { height: 9px; } .dash-bar.h3 { height: 14px; }
.dash-bar.h4 { height: 19px; } .dash-bar.h5 { height: 24px; } .dash-bar.h6 { height: 29px; }
.dash-bar.h7 { height: 34px; } .dash-bar.h8 { height: 39px; } .dash-bar.h9 { height: 44px; }
.dash-persistent { display: flex; align-items: center; gap: 20px; min-width: 0;
                   padding: 7px 18px 8px; border-bottom: 2px solid var(--buffer-group-color, var(--accent-fg, #26356b));
                   background: var(--window-bg, #fdfcf8); cursor: pointer; }
.dseg { display: flex; flex-direction: column; gap: 1px; min-width: 0;
        font-family: var(--font-mono); }
.dseg-r { align-items: flex-end; }
.dseg-inline { flex-direction: row; align-items: baseline; gap: 7px; }
.dseg-k { font-size: 9px; letter-spacing: .16em; text-transform: uppercase;
          color: var(--faint-fg, #b3ac9c); white-space: nowrap; }
.dseg-v { font-size: 12.5px; color: var(--default-fg, #1b1a17);
          white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.dseg-strong { font-weight: 600; }
.dseg-group-current { color: var(--buffer-group-color, var(--default-fg, #1b1a17)); }
.dseg-rule { width: 1px; height: 24px; flex: 0 0 auto;
             background: var(--border-bg, #cbc4b1); opacity: .5; }
.dseg-gap { flex: 1 1 auto; }
.dseg-stack { display: flex; flex-direction: column; gap: 3px; min-width: 0; }
")

(define (dash--row k v &optional cls)
  (list 'tag "div" 'class "dash-row"
        'segs (list (list "dash-k" k) (list "dash-sp" "")
                    (list (string-append "dash-v" (if cls (string-append " " cls) "")) v))))

(define (dash--chip m) (list 'tag "span" 'class "dash-chip" 'text m))

(define (dash--pill text cls)
  (list 'tag "span" 'class (string-append "dash-pill" (if cls (string-append " " cls) ""))
        'text text))

(define (dash--section title children)
  (list 'tag "div" 'class "dash-cell"
        'children (cons (list 'tag "div" 'class "dash-title" 'text title) children)))

(define (dash--head buf)
  (list 'tag "div" 'class "dash-head"
        'children
        (list
          (list 'tag "div" 'class "dash-headmain"
                'children
                (append
                  (list (list 'tag "div" 'class "dash-name" 'text (buffer-short-label buf)))
                  (let ((p (buffer-path buf)))
                    (if p (list (list 'tag "div" 'class "dash-file" 'text p)) '()))))
          (list 'tag "span" 'class "dash-sp" 'text "")
          (list 'tag "div" 'class "dash-pills"
                'children
                (append
                  (list (dash--pill (if (buffer-modified? buf) "modified" "saved")
                                    (if (buffer-modified? buf) "warn" "good")))
                  (if (buffer-read-only? buf) (list (dash--pill "read-only" #f)) '())
                  (list (dash--pill
                          (string-append (number->string (buffer-size buf)) " B") #f)))))))

(define (dash--group buf)
  (let* ((ids (if (chat-buffer? buf)
                  (let ((g (chat-group-id buf))) (if g (list g) '()))
                  (buffer-group-ids buf)))
         (current (frame-local 'current-group))
         (primary (cond ((and current (member current ids)) current)
                        ((pair? ids) (car ids))
                        (else #f))))
    (if (null? ids)
        (dash--section "group"
          (list (dash--row "group" "none" "dim")
                (dash--row "join" "C-c g" "dim")))
        (dash--section (if (null? (cdr ids)) "group" "groups")
          (append
            ;; C-x ? is the unabridged counterpart to the compact modeline:
            ;; every membership is named, with the frame's current one first.
            (list (list 'tag "div" 'class "dash-chips"
                        'children
                        (map (lambda (g) (dash--chip (group-label g)))
                             (if (and current (member current ids))
                                 (cons current
                                       (remove (lambda (g) (equal? g current)) ids))
                                 ids))))
            ;; every member shows, as wrapping chips — one truncating
            ;; row hid the companion chat behind an ellipsis
            (list (list 'tag "div" 'class "dash-chips"
                        'children
                        (map (lambda (m) (dash--chip (buffer-short-label m)))
                             (group-buffers-mru primary)))
                  (dash--row "companion" (group-noise primary))
                  (dash--row "layout" (if (group-layout primary) "saved" "default")))
            (let ((m (group-meta primary)))
              (if m (list (dash--row "about" m)) '())))))))

;; the ledger, folded two ways: cost per day (the sparkline) and the
;; model that took the most of it
(define (dash--day-costs rows)
  (let loop ((rs rows) (acc '()))
    (if (null? rs)
        acc
        (let* ((r (car rs))
               (day (plist-get r 'day))
               (cost (or (plist-get r 'cost) 0))
               (hit (assoc day acc)))
          (loop (cdr rs)
                (if hit
                    (cons (list day (+ (cadr hit) cost))
                          (remove (lambda (e) (equal? (car e) day)) acc))
                    (cons (list day cost) acc)))))))

;; a share of the biggest day maps to one of nine bar heights — a
;; cond ladder, because this dialect has no floor
(define (dash--lvl share)
  (cond ((> share 0.875) 9) ((> share 0.75) 8) ((> share 0.625) 7)
        ((> share 0.5) 6) ((> share 0.375) 5) ((> share 0.25) 4)
        ((> share 0.125) 3) ((> share 0.05) 2) (else 1)))

(define (dash--spark days)
  (let* ((mx (fold (lambda (m d) (if (> (cadr d) m) (cadr d) m)) 0 days))
         (mxi (if (> mx 0) mx 1)))
    (list 'tag "div" 'class "dash-spark"
          'children
          (map (lambda (d)
                 (let ((lvl (dash--lvl (/ (cadr d) mxi)))
                       (hot (>= (cadr d) mx)))
                   (list 'tag "span"
                         'class (string-append "dash-bar h" (number->string lvl)
                                               (if hot " hot" "")))))
               days))))

;; The chat that speaks for HERE: this buffer when it is one, else its
;; group's chat. The cost, the presets and the tool surface all live on
;; that buffer, so every card asks this one question.
(define (dash--here-chat buf)
  (if (chat-buffer? buf)
      buf
      (let ((g (buffer-group buf)))
        (and g (group-primary-chat g)))))

;; what HERE cost: the buffer's own chat, or its group's chat
(define (dash--here-cost buf)
  (or (buffer-local buf 'chat-cost)
      (let ((c (dash--here-chat buf)))
        (and c (buffer-local c 'chat-cost)))))

;; the model HERE would talk to, and through which lane: a chat's own
;; agent-model, a writing buffer's llm-model, else the global default.
;; The lane is acp when a connector is attached, api otherwise.
(define (dash--model buf)
  (or (buffer-local buf 'agent-model)
      (buffer-local buf 'llm-model)
      (llm-model)))

(define (dash--lane buf)
  (let ((c (buffer-local buf 'agent-connector)))
    (if (and c (not (equal? c "api")))
        (string-append "acp · " c)
        "api")))

;; the tool presets in force here: the buffer's own, or its group chat's
(define (dash--presets buf)
  (let ((p (or (buffer-local buf 'chat-presets)
               (let ((c (dash--here-chat buf)))
                 (and c (buffer-local c 'chat-presets))))))
    (and (pair? p)
         (string-join (map (lambda (x) (value->string x)) p) " · "))))

;;; The tools HERE can call. A chat freezes its tool list at its first
;;; send, so the frozen list is what the model sees; before that, the
;;; live surface is what the next send will freeze. The card names the
;;; state, so a stale list is visible where the chat is, not only in the
;;; modeline.
;;;
;;; This asks the live surface, which starts a preset's MCP servers. The
;;; panel builds only when it opens and when its fingerprint moves, so
;;; the question costs the same as the modeline already costs per turn.

(define (dash--tool-state chat)
  (cond ((pair? (buffer-local chat 'chat-tool-specs))
         (list (if (and (boundp (quote chat-tools-stale?))
                        (chat-tools-stale? chat))
                   "stale"
                   "frozen")
               (buffer-local chat 'chat-tool-specs)))
        ((boundp (quote chat-live-tool-specs))
         (list "live" (chat-live-tool-specs chat)))
        (else (list "none" '()))))

;; A preset whose server is not ready serves no tools yet. Name those
;; servers: "0 tools" with a preset set is otherwise unexplainable.
(define (dash--pending-servers chat)
  (if (not (and (boundp (quote chat-active-servers))
                (boundp (quote mcp-server-detail))))
      '()
      (let ((remote (filter (lambda (s) (not (equal? s 'compos)))
                            (chat-active-servers chat))))
        (map (lambda (s) (value->string s))
             (filter (lambda (s)
                       (let ((d (mcp-server-detail (value->string s))))
                         (not (and (pair? d)
                                   (equal? (plist-get d 'status) "ready")))))
                     remote)))))

;; twenty names, then a count: a server with fifty tools must not push
;; the ledger off the panel
(define (dash--tool-chips names)
  (let ((n (length names)))
    (list 'tag "div" 'class "dash-chips"
          'children
          (append
            (map dash--chip (if (> n 20) (take-n names 20) names))
            (if (> n 20)
                (list (dash--chip (string-append "+" (number->string (- n 20))
                                                 " more")))
                '())))))

(define (dash--tools buf)
  (let ((chat (dash--here-chat buf)))
    (if (not chat)
        (dash--section "tools"
          (list (dash--row "chat" "none" "dim")
                (dash--row "open" "C-c c" "dim")))
        (let* ((st (dash--tool-state chat))
               (state (car st))
               (names (map car (car (cdr st))))
               (n (length names))
               (ps (dash--presets buf)))
          (dash--section "tools"
            (append
              (list (list 'tag "div" 'class "dash-big"
                          'text (string-append (number->string n)
                                               (if (= n 1) " tool" " tools")))
                    (dash--row "presets" (or ps "none") (if ps #f "dim"))
                    (dash--row "list" state
                               (cond ((equal? state "stale") "warn")
                                     ((equal? state "frozen") "good")
                                     (else "dim"))))
              (if (equal? state "stale")
                  (list (dash--row "adopt" "C-c t"))
                  '())
              ;; a server that is not ready serves nothing, and the count
              ;; above says so without saying why. Name it at any count:
              ;; a surface missing one server still looks complete.
              (let ((pending (dash--pending-servers chat)))
                (if (pair? pending)
                    (list (dash--row "waiting on"
                                     (string-join pending " · ") "warn"))
                    '()))
              (if (pair? names) (list (dash--tool-chips names)) '())
              (list (dash--row "servers" "M-x mcp-hub" "dim"))))))))

(define (dash--llm buf)
  (let* ((rows (llm-cost-report))
         (days (sort-by-car (dash--day-costs rows)))
         (last14 (last-n days 14))
         (total (fold (lambda (a d) (+ a (cadr d))) 0 days))
         (today (if (pair? days) (car (reverse days)) #f))
         (here (dash--here-cost buf)))
    (dash--section "llm"
      (append
        (list (list 'tag "div" 'class "dash-big" 'text (dash--model buf))
              (dash--row "lane" (dash--lane buf)))
        (if (pair? last14) (list (dash--spark last14)) '())
        (if here (list (dash--row "this chat" (format-usd here))) '())
        (list (dash--row "today, all" (if today (format-usd (cadr today)) "$0") #f)
              (dash--row "total, all" (format-usd total))
              (dash--row "ledger" "M-x llm-costs" "dim"))))))

;; an ISO day as one integer (20260816): the dialect has no string<?
(define (dash--day-int d)
  (or (string->number (string-join (string-split d "-") "")) 0))

(define (sort-by-car xs)
  (let loop ((rest xs) (out '()))
    (if (null? rest)
        out
        (loop (cdr rest)
              (let ins ((ys out))
                (cond ((null? ys) (list (car rest)))
                      ((< (dash--day-int (car (car rest)))
                          (dash--day-int (car (car ys))))
                       (cons (car rest) ys))
                      (else (cons (car ys) (ins (cdr ys))))))))))

(define (last-n xs n)
  (let ((k (length xs)))
    (if (<= k n) xs (list-tail-n xs (- k n)))))

(define (list-tail-n xs n)
  (if (= n 0) xs (list-tail-n (cdr xs) (- n 1))))

;; the expansion is a panel INSIDE the buffer's window, pinned above
;; the text — the buffer stays editable beneath it. The state is one
;; buffer-local; the blocks are derived and never saved.
(define (desktop-skip! buf key)
  (let ((cur (or (buffer-local buf 'desktop-skip-locals) '())))
    (unless (member key cur)
      (buffer-set-local! buf 'desktop-skip-locals (cons key cur)))))

;; the panel PULLS like the bar: everything per-buffer (position,
;; modes, read-only) renders in the view from live state. Only the
;; cross-buffer cards ship as blocks: the group's detail and the
;; ledger. post-command! keeps those honest.
(define (dashboard-blocks buf)
  (list (dash--head buf)
        (dash--group buf)
        (dash--tools buf)
        (dash--llm buf)))

(define (dashboard--group-ids buf)
  (if (chat-buffer? buf)
      (let ((g (chat-group-id buf))) (if g (list g) '()))
      (buffer-group-ids buf)))

(define (dashboard--mode-name name)
  (let ((s (if (symbol? name) (symbol->string name) name)))
    (if (and (string? s) (string-suffix? "-mode" s))
        (substring s 0 (- (string-length s) 5))
        (or s "Fundamental"))))

;; The compact dashboard stays at the top of the window. It keeps the LLM
;; context and every group visible in one line, then opens the full panel.
(define (dashboard-one-line buf)
  (let* ((ids (dashboard--group-ids buf))
         (modes (cons (or (buffer-local buf 'mode-name) "Fundamental")
                      (or (buffer-local buf 'minor-modes) '())))
         (mode-text (string-join (map dashboard--mode-name modes) " · "))
         (groups (if (pair? ids)
                     (string-join (map group-label ids) " · ")
                     "none")))
    (string-append
      "mode " mode-text
      "   groups " groups
      "   llm " (dash--model buf)
      "   lane " (dash--lane buf))))

;;; The same facts, keyed. A flat run of tokens spends one weight on
;;; every word, so nothing reads first. Each segment puts a whisper-sized
;;; key over its value, and the value carries the line. Place goes left,
;;; machine state goes right, and a hairline rule separates them.

(define (dash--seg key segs align &optional extra-class)
  (list 'tag "div"
        'class (string-append
                (if (equal? align 'right) "dseg dseg-r" "dseg")
                (if extra-class (string-append " " extra-class) ""))
        'children
        (list (list 'tag "div" 'class "dseg-k" 'text key)
              (list 'tag "div" 'class "dseg-v" 'segs segs))))

(define (dash--seg-rule)
  (list 'tag "span" 'class "dseg-rule"))

(define (dash--seg-gap)
  (list 'tag "span" 'class "dseg-gap"))

;; the major mode carries the weight; the minor modes trail it
(define (dash--mode-segs buf)
  (let* ((major (dashboard--mode-name (or (buffer-local buf 'mode-name) "Fundamental")))
         (minors (or (buffer-local buf 'minor-modes) '()))
         ;; a rendered preview is a mode the reader can see. It rides
         ;; 'render-mode, not the minor-mode list, so read it here.
         (render (buffer-local buf 'render-mode))
         ;; preview-mode already names itself when it is on; the render
         ;; mode fills in only for a page some other route rendered
         (extra (if (and (string? render)
                         (member render '("html" "markdown"))
                         (not (member "preview-mode" minors)))
                    (list "preview")
                    '())))
    (cons (list "dseg-strong" major)
          (map (lambda (m)
                 (list "f-dim" (string-append " · " (dashboard--mode-name m))))
               (append minors extra)))))

;; the last group is where you are; the ones before it are the path
(define (dash--group-segs buf)
  (let ((labels (map group-label (dashboard--group-ids buf))))
    (if (null? labels)
        (list (list "f-faint" "none"))
        (let loop ((rest labels) (out '()))
          (if (null? (cdr rest))
              (reverse (cons (list "dseg-strong dseg-group-current" (car rest)) out))
              (loop (cdr rest)
                    (cons (list "f-faint" " / ")
                          (cons (list "f-dim" (car rest)) out))))))))

;; "openrouter:sonnet" reads as one word until the provider steps back
(define (dash--model-segs buf)
  (let* ((model (dash--model buf))
         (parts (string-split model ":")))
    (if (> (length parts) 1)
        (list (list "f-dim" (string-append (car parts) ":"))
              (list "dseg-strong" (string-join (cdr parts) ":")))
        (list (list "dseg-strong" model)))))

(define (dashboard-line-blocks buf)
  (list (dash--seg "mode" (dash--mode-segs buf) 'left)
        (dash--seg-rule)
        (dash--seg "group" (dash--group-segs buf) 'left)
        (dash--seg-rule)
        (list 'tag "div" 'class "dseg-stack"
              'children
              (list (dash--seg "llm" (dash--model-segs buf) 'right "dseg-inline")
                    (dash--seg "lane"
                      (list (list "f-ok dseg-strong" (dash--lane buf)))
                      'right "dseg-inline")))))

;; The modeline names the buffer the short way: project coordinates inside
;; a project, "~" for the home directory outside one. The buffer name keeps
;; the absolute path, and the modeline's tooltip still says it.
;; A buffer with no file can still name one: "*chat:/Users/me/notes.md*".
;; Write the home directory as ~ wherever it appears in the name.
(define (abbreviate-home-in text)
  (let ((home (getenv "HOME")))
    (if (and (string? text) (string? home) (> (string-length home) 1))
        (string-join (string-split text home) "~")
        text)))

(define (buffer-modeline-name buf)
  (let* ((path (buffer-path buf))
         (root (buffer-project-root buf))
         (name (cond ((not (string? path)) (abbreviate-home-in buf))
                     ((and (string? root) (not (equal? root ""))
                           (string-prefix? (string-append root "/") path))
                      (substring path (+ 1 (string-length root)) (string-length path)))
                     (else (abbreviate-file-name path)))))
    ;; a peek says so where the name is: the one mark the feature has
    (if (peek-buffer? buf)
        (string-append "peek · " name)
        name)))

(define (dashboard--sync! buf)
  (desktop-skip! buf 'dashboard-line)
  (desktop-skip! buf 'dashboard-line-blocks)
  (desktop-skip! buf 'modeline-name)
  (desktop-skip! buf 'modeline-project)
  (buffer-set-local! buf 'dashboard-line (dashboard-one-line buf))
  (buffer-set-local! buf 'dashboard-line-blocks (dashboard-line-blocks buf))
  (buffer-set-local! buf 'modeline-name (buffer-modeline-name buf))
  ;; the project stands beside the name: the name says where in the
  ;; project, the project says which one
  (buffer-set-local! buf 'modeline-project (buffer-project-label buf)))

;; The fingerprint reads locals only — never the live tool surface. It
;; runs after every command, and asking the surface there would start
;; MCP servers on a cursor move. The frozen list and the presets are the
;; state that moves the tools card, and both are locals.
(define (dash--fingerprint buf)
  (let ((chat (dash--here-chat buf)))
    (list (buffer-local buf 'mode-name)
          (buffer-local buf 'minor-modes)
          (dashboard--group-ids buf)
          (frame-local 'current-group)
          (buffer-local buf 'agent-model)
          (buffer-local buf 'agent-connector)
          (buffer-local buf 'llm-model)
          (and chat (buffer-local chat 'chat-presets))
          (and chat (map car (or (buffer-local chat 'chat-tool-specs) '()))))))

(define-command "modeline-expand"
  "Toggle this buffer's expanded modeline panel"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (buffer-local buf 'modeline-expanded)
          (begin
            (buffer-set-local! buf 'modeline-expanded #f)
            (buffer-set-local! buf 'modeline-dash-blocks #f))
          (begin
            (desktop-skip! buf 'modeline-expanded)
            (desktop-skip! buf 'modeline-dash-blocks)
            (desktop-skip! buf 'modeline-dash-fp)
            (buffer-set-local! buf 'modeline-dash-fp (dash--fingerprint buf))
            (buffer-set-local! buf 'modeline-dash-blocks (dashboard-blocks buf))
            (buffer-set-local! buf 'modeline-expanded #t))))))

;; after every command: an expanded panel that no longer matches its
;; buffer rebuilds itself — modes, group, model all change under it
(define (post-command!)
  (let ((buf (current-buffer)))
    (dashboard--sync! buf)
    (list-post-command! buf)
    ;; a list on screen shows what is, not what was: the command may have
    ;; killed a buffer the list beside it still names. Every visible
    ;; buffer keeps its own modeline, so an inactive window says the truth
    ;; without waiting for you to visit it.
    (for-each (lambda (w)
                (unless (equal? (cadr w) buf)
                  (list-post-command! (cadr w))
                  (dashboard--sync! (cadr w))))
              (window-list))
    (when (buffer-local buf 'modeline-expanded)
      (let ((fp (dash--fingerprint buf)))
        (unless (equal? fp (buffer-local buf 'modeline-dash-fp))
          (buffer-set-local! buf 'modeline-dash-fp fp)
          (buffer-set-local! buf 'modeline-dash-blocks (dashboard-blocks buf)))))
    ;; the extension seam: packages react to the command that just ran
    ;; (paredit paints the matching delimiter here)
    (run-hooks 'post-command-hook)))

;; members in MRU order; buffers never visited this session trail
;; behind. A group is a SET: the list dedupes by name, whatever the
;; sources produce.
(define (dedupe-names xs)
  (let loop ((xs xs) (seen '()) (out '()))
    (cond ((null? xs) (reverse out))
          ((member (car xs) seen) (loop (cdr xs) seen out))
          (else (loop (cdr xs) (cons (car xs) seen) (cons (car xs) out))))))

(define (chat-buffer? b)
  (equal? (buffer-local b 'mode-name) "chat-mode"))

;;; --- asking about windows -------------------------------------------------------
;;; (window-list) is ((id buffer) ...) and five places walked it by hand,
;;; each with its own loop and its own idea of what to return when nothing
;;; matched. These are the four questions that were being asked.

;; the window showing NAME, or #f
(define (window-showing name)
  (let ((ws (filter (lambda (w) (equal? (cadr w) name)) (window-list))))
    (if (null? ws) #f (car (car ws)))))

;; ...that is not EXCEPT — for "put it somewhere other than here"
(define (window-showing-other name except)
  (let ((ws (filter (lambda (w) (and (equal? (cadr w) name)
                                     (not (equal? (car w) except))))
                    (window-list))))
    (if (null? ws) #f (car (car ws)))))

;; the buffer a window is showing, or #f
(define (window-buffer id)
  (let ((w (assoc id (window-list))))
    (and w (cadr w))))

;; any window that is not ME, or #f when ME is the only one
(define (other-window-id me)
  (let loop ((ws (window-list)))
    (cond ((null? ws) #f)
          ((not (equal? (car (car ws)) me)) (car (car ws)))
          (else (loop (cdr ws))))))

;; C-c q : ask from anywhere. In a grouped buffer (its chat included) the
;; prompt becomes a turn in the group's one chat; ungrouped, it goes to
;; the global *chat* popup — follow-ups with C-c RET, C-` dismisses.
(add-display-rule! "*chat*" 'popup)
(add-display-rule! "*llm:" 'popup)
(add-display-rule! "*llm-costs*" 'popup)

;;; --- llm cost inspection -----------------------------------------------------
;;; Every request is priced (models.dev catalog, cached in ~/.compos/llmdb.json,
;;; refreshed daily) and recorded in ~/.compos/llm-usage.jsonl; each chat also
;;; sums its own spend in the 'chat-cost buffer-local.

;; What a chat cost, and — the number that decides whether it was worth it
;; — how much of its input the provider served from cache. A conversation
;; resends its whole history every turn. At a healthy hit rate that history
;; bills at about a tenth of the price; at 0% it bills at full price twice
;; over, because a cache WRITE costs more than a plain read.
(define-command "chat-cost" "Show what this chat has cost, and its cache hit rate"
  (lambda ()
    (let* ((buf (current-buffer))
           (c (buffer-local buf 'chat-cost))
           (u (buffer-local buf 'chat-last-usage))
           (ctx (chat-context-tokens buf))
           (total (chat-usage-total buf))
           (rate (chat-hit-rate total)))
      (if (not (or c u ctx))
          (message "No usage reported in this chat yet")
          (message
            (string-append
              "This chat: " (if c (format-usd c) "unpriced")
              ;; what it occupies right now, which is the number a reader
              ;; asks for when a conversation feels long
              (if ctx
                  (string-append " · context "
                    (number->string (plist-get ctx 'used))
                    (let ((size (plist-get ctx 'size)))
                      (if size (string-append " of " (number->string size)) ""))
                    " tokens")
                  "")
              " · cache " (number->string (or (plist-get total 'cache-read) 0)) " read / "
              (number->string (or (plist-get total 'cache-write) 0)) " written"
              (if rate (string-append " · " rate " of input cached") "")
              (if u
                  (string-append " · last turn "
                    (number->string (or (custom--plist-get u 'input) 0)) "→"
                    (number->string (or (custom--plist-get u 'output) 0)) " tokens"
                    (let ((tc (custom--plist-get u 'cost)))
                      (if tc (string-append " (" (format-usd tc) ")") "")))
                  "")))))))

(define-command "llm-costs" "Show LLM spend by day and model (the usage ledger)"
  (lambda ()
    (let ((rows (llm-cost-report))
          (buf "*llm-costs*"))
      (buffer-create buf)
      (buffer-delete-range! buf 0 (string-byte-length (buffer-text buf)))
      (buffer-append! buf
        (fold (lambda (acc r)
                (string-append acc
                  (custom--plist-get r 'day) "  "
                  (format-usd (custom--plist-get r 'cost)) "  "
                  (number->string (custom--plist-get r 'requests)) " reqs  "
                  (number->string (custom--plist-get r 'input)) "→"
                  (number->string (custom--plist-get r 'output)) "  "
                  ;; the cache columns: read is what the prefix cost a tenth
                  ;; of, written is what it cost a quarter more than usual
                  "cache " (number->string (custom--plist-get r 'cache-read)) "r/"
                  (number->string (custom--plist-get r 'cache-write)) "w  "
                  (let ((h (custom--plist-get r 'hit-rate)))
                    (string-pad-right
                      (if h (string-append (number->string h) "% cached") "") 12))
                  "  " (custom--plist-get r 'model) "\n"))
              (string-append
                "LLM spend · ledger ~/.compos/llm-usage.jsonl · per-chat: C-c $\n"
                "hit rate is cached input over billed input: low means the "
                "prefix is being rewritten every turn\n\n")
              rows))
      (switch-to-buffer! buf))))

;; a new chat buffer in the current group; the old conversation stays.
;; The frame's group wins; a buffer outside any group founds one only
;; when the frame stands in none.
(define-command "chat-new" "Start a new chat buffer in the current group"
  (lambda ()
    (let ((g (or (frame-group) (group-ensure! (current-buffer)))))
      (if (not g)
          (message "No group for a chat")
          (group-chat-new! g)))))

;; C-c q from anywhere: the prompt becomes a turn in this buffer's group
;; chat (founding the group first if needed) — one chat interface, always
(define-command "llm-ask" "Ask the LLM from anywhere via the minibuffer"
  (lambda ()
    (group-ask! (group-ensure! (current-buffer)))))

(global-set-key "C-c c" "chat")
(global-set-key "C-c n" "chat-new")
(global-set-key "C-c r" "chat-send-region")
(global-set-key "C-c q" "llm-ask")
(global-set-key "C-c w" "chat-companion")




;; Cmd-p is intent search; M-x remains literal command-name completion.
(global-set-key "s-p" "command-palette")
;; winner: any layout change is one keystroke from undone
(global-set-key "C-c <left>" "winner-previous")
(global-set-key "C-c <right>" "winner-next")
;; the modeline, expanded — also a click on the modeline's name
(global-set-key "C-x ?" "modeline-expand")
(global-set-key "C-c RET" "chat-companion-ask")

;;; --- minibuffer history (vertico-style: last-used first) --------------------
;;; The candidate ranking in the core is a stable sort, so passing
;;; candidates history-first keeps them first among equal matches — the
;;; empty prompt shows pure recency, typing re-ranks fuzzily within it.

(define *minibuffer-history* '())   ; ((key (item ...)) ...), most recent first
(define *minibuffer-history-max* 50)

;; savehist: which commands, themes and searches you use is worth more
;; than one session. Every keyed history rides in this one variable, so
;; M-x, apropos, project, ripgrep and the theme prompt all persist here.
(persist-global! 'minibuffer-history
  (lambda () *minibuffer-history*)
  (lambda (v) (set! *minibuffer-history* v)))

(define (history-items key)
  (let ((e (assoc key *minibuffer-history*)))
    (if e (cadr e) '())))

(define (take-n lst n)
  (if (or (null? lst) (= n 0))
      '()
      (cons (car lst) (take-n (cdr lst) (- n 1)))))

(define (history-push! key item)
  (let ((items (cons item (filter (lambda (x) (not (equal? x item)))
                                  (history-items key)))))
    (set! *minibuffer-history*
      (cons (list key (take-n items *minibuffer-history-max*))
            (filter (lambda (e) (not (equal? (car e) key)))
                    *minibuffer-history*)))))

;; reorder candidates so remembered ones lead, in recency order
(define (history-order key candidates)
  (let ((hist (filter (lambda (h) (member h candidates)) (history-items key))))
    (append hist (filter (lambda (c) (not (member c hist))) candidates))))

;;; --- M-x and eval ----------------------------------------------------------

;; what a command name means in a prompt: how to reach it, and what it
;; does. Two fields, so the docs line up under each other whether or not
;; the command above them has a binding.
(define (command-annotation c)
  (list (key-for-command c) (command-doc c)))

(marginalia! 'command command-annotation)

(define-command "execute-extended-command"
  "Run a command by name, with its keybinding and doc alongside"
  (lambda ()
    ;; M-x itself finishes before its minibuffer callback runs. Preserve the
    ;; raw prefix across that boundary, then consume it after the selected
    ;; command has had the same view it would get from a direct keybinding.
    (let ((prefix (current-prefix-arg)))
      (minibuffer-read "M-x "
        (annotate 'command (history-order 'M-x (command-names)))
        (lambda (cmd)
          (history-push! 'M-x cmd)
          (when prefix (set-prefix-arg! prefix))
          (run-command cmd)
          (when prefix (set-prefix-arg! #f)))))))

;;; Cmd-p answers "how do I do this?" while M-x answers "what is the
;;; command called?". Apropos supplies task-language matches from command
;;; docs and recipes; the palette projects that broad catalog down to things
;;; a reader can act on here.
(define (command-palette--candidate hit)
  (let ((kind (plist-get hit 'kind))
        (name (or (plist-get hit 'name) (plist-get hit 'task))))
    (cond
      ((equal? kind "command")
       (list name
             (string-append "command  "
                            (let ((key (plist-get hit 'key))) (if key key ""))
                            "  " (or (plist-get hit 'doc) ""))))
      ((equal? kind "recipe")
       (let ((inputs (or (plist-get hit 'inputs) '())))
         (list name
               (if (null? inputs)
                   "recipe  runs immediately"
                   (string-append "recipe  asks for "
                                  (number->string (length inputs))
                                  (if (= (length inputs) 1) " input" " inputs"))))))
      (else #f))))

;; A command the palette can draw: name, key and doc, in apropos hit shape.
(define (command-palette--command-hit name)
  (list 'kind "command" 'name name 'doc (command-doc name)
        'key (let ((k (key-for-command name))) (if (equal? k "") #f k))))

;; The palette draws commands and recipes, so it searches those two alone.
;; The whole catalog costs an index rebuild after every package load, and
;; the semantic pass costs a network call. The palette searches again on
;; every keystroke burst and can pay neither.
(define (command-palette--search query)
  (let ((words (apropos-query-words query)))
    (append
      (if (boundp (quote recipe-search)) (recipe-search query) '())
      (map command-palette--command-hit
           (filter (lambda (name)
                     (apropos-text-hit?
                       (string-append name " " (command-doc name)) words))
                   (command-names))))))

(define (command-palette-candidates query)
  (if (equal? (string-trim query) "")
      ;; The resting palette is familiar and cheap: the same MRU command
      ;; table as M-x. The search takes over as soon as the user states intent.
      (annotate 'command (history-order 'M-x (command-names)))
      (filter (lambda (candidate) candidate)
              (map command-palette--candidate (command-palette--search query)))))

(define *command-palette-debounce-ms* 80)

(define (command-palette--refresh input)
  ;; A timer can outlive the prompt that scheduled it. Never put Cmd-p's
  ;; results into a later prompt, and never let an old query replace a newer
  ;; one after the user has kept typing.
  (let ((state (minibuffer-state)))
    (when (and state
               (equal? (plist-get state 'prompt) "Command: ")
               (equal? (plist-get state 'input) input))
      (minibuffer-set-candidates! (command-palette-candidates input)))))

(define (command-palette--render-recipe expr bindings)
  ;; Every input becomes a printed Scheme string, not source. Quotes,
  ;; backslashes and newlines are escaped by value->string before the token is
  ;; replaced, so a path or prompt value cannot turn into executable code.
  (if (null? bindings)
      expr
      (let* ((binding (car bindings))
             (token (string-append "{{" (symbol->string (car binding)) "}}"))
             (rendered (string-join (string-split expr token)
                                    (value->string (cadr binding)))))
        (command-palette--render-recipe rendered (cdr bindings)))))

(define (command-palette--eval-recipe recipe bindings)
  (let ((result
          (eval-string-safe
            (command-palette--render-recipe (cadr recipe) bindings))))
    (if (equal? (car result) 'ok)
        (message (value->string (cadr result)))
        (message (string-append "Recipe error: " (cadr result))))))

(define (command-palette--collect-recipe recipe inputs bindings)
  (if (null? inputs)
      (command-palette--eval-recipe recipe bindings)
      (let ((input (car inputs)))
        (minibuffer-read (cadr input) '()
          (lambda (value)
            (command-palette--collect-recipe
              recipe (cdr inputs) (append bindings (list (list (car input) value)))))))))

(define (command-palette--run-recipe recipe)
  (command-palette--collect-recipe recipe (caddr recipe) '()))

(define (command-palette--run choice)
  (cond
    ((command-fn choice)
     (history-push! 'M-x choice)
     (run-command choice))
    ((and (boundp (quote *recipes*)) (assoc choice *recipes*))
     (command-palette--run-recipe (assoc choice *recipes*)))
    (else (message (string-append "No command or recipe named " choice)))))

(domain! 'interaction)
(effects! '(write execute))

(define-command "command-palette"
  "Find an action by intent across command docs and recipes"
  (lambda ()
    (minibuffer-read* "Command: " (command-palette-candidates "")
      (list (list 'confirm command-palette--run)
            (list 'change
              (lambda (input)
                (debounce!
                  (string-append "command-palette:" (selected-frame))
                  *command-palette-debounce-ms*
                  command-palette--refresh
                  input)))
            ;; Apropos already matched and ranked these results. In
            ;; particular, a doc match need not contain INPUT in its label.
            (list 'filter #f)
            (list 'style "palette")))))

(domain! 'unknown)
(effects! '(unknown))

(define-command "eval-expression" "Evaluate a Scheme expression from the minibuffer"
  (lambda ()
    (minibuffer-read "Eval: " '()
      (lambda (src) (message (value->string (eval-string src)))))))

;;; --- live eval: the editor is its own REPL -----------------------------------

(define (echo-value v) (message (string-append "=> " (value->string v))))

(define (char-before i)
  (if (> i 0) (buffer-substring (- i 1) i) #f))

(define (eval-skip-ws-back i)
  (if (member (char-before i) '(" " "\n" "\t"))
      (eval-skip-ws-back (- i 1))
      i))

;; matching opener for the closer just before i (naive about escaped quotes)
(define (sexp-open-before i depth in-str)
  (if (= i 0) 0
      (let ((c (char-before i)))
        (cond
          (in-str (sexp-open-before (- i 1) depth (not (equal? c "\""))))
          ((equal? c "\"") (sexp-open-before (- i 1) depth #t))
          ((equal? c ")") (sexp-open-before (- i 1) (+ depth 1) #f))
          ((equal? c "(") (if (= depth 1) (- i 1)
                              (sexp-open-before (- i 1) (- depth 1) #f)))
          (else (sexp-open-before (- i 1) depth #f))))))

(define (atom-start i)
  (if (or (= i 0) (member (char-before i) '(" " "\n" "\t" "(" ")")))
      i
      (atom-start (- i 1))))

(define (last-sexp-start p)
  (if (equal? (char-before p) ")")
      (sexp-open-before p 0 #f)
      (atom-start p)))

(define-command "eval-last-sexp" "Evaluate sexp before point and echo the value"
  (lambda ()
    (let* ((p (eval-skip-ws-back (point)))
           (s (last-sexp-start p)))
      (if (< s p)
          (echo-value (eval-region (current-buffer) s p))
          (message "No sexp before point")))))

(define-command "eval-buffer" "Evaluate the current buffer as Scheme"
  (lambda () (echo-value (eval-buffer (current-buffer)))))
(catalog-meta! 'command "eval-buffer" 'domain 'commands 'effects '(write execute))

(define-command "eval-region" "Evaluate the region as Scheme"
  (lambda ()
    (if (mark)
        (echo-value (eval-region (current-buffer) (region-beginning) (region-end)))
        (message "No region — set the mark first (C-SPC)"))))

;; hot-reload a Scheme file into the live session (stdlib included)
(define-command "load-file" "Load a Scheme file into the live session"
  (lambda ()
    (read-file-name "Load file: "
      (lambda (path)
        (load path)
        (message (string-append "Loaded " path))))))

(domain! 'interaction)
(effects! '(write))

(define (prefix-numeric-value raw)
  (cond ((number? raw) raw)
        ((and (pair? raw) (number? (car raw))) (car raw))
        ((equal? raw '-) -1)
        (else 1)))

(define-command "universal-argument" "Start or multiply the next command's prefix argument"
  (lambda ()
    (let ((raw (current-prefix-arg)))
      (set-prefix-arg!
        (cond ((number? raw) (list (* raw 4)))
              ((and (pair? raw) (number? (car raw))) (list (* (car raw) 4)))
              ((equal? raw '-) (list -4))
              (else (list 4)))))))

(define-command "digit-argument" "Add a digit to the next command's prefix argument"
  (lambda ()
    (let* ((raw (current-prefix-arg))
           (digit (string->number (car (reverse (last-keys)))))
           (negative? (or (equal? raw '-) (and (number? raw) (< raw 0))))
           (base (if (number? raw) (abs raw) 0))
           (value (+ (* base 10) digit)))
      (set-prefix-arg! (if negative? (- value) value)))))

(define-command "negative-argument" "Negate the next command's prefix argument"
  (lambda ()
    (let ((raw (current-prefix-arg)))
      (set-prefix-arg!
        (cond ((number? raw) (- raw))
              ((equal? raw '-) 1)
              (else '-))))))

(undo-exempt! "universal-argument")
(undo-exempt! "digit-argument")
(undo-exempt! "negative-argument")

(public! 'prefix-numeric-value
  "(prefix-numeric-value RAW) -> RAW as an integer; #f becomes 1")

(domain! 'unknown)
(effects! '(unknown))

(define-command "keyboard-quit" "Quit the current operation; close the active popup or clear the mark"
  (lambda ()
    (set-mark! #f)
    (if (and (popup-open?) (equal? (active-window) (popup-window)))
        (popup-close!)
        (message "Quit"))))
(catalog-meta! 'command "keyboard-quit" 'domain 'interaction 'effects '(write))

;;; --- tiling windows --------------------------------------------------------

(define-command "split-window-below" "Split the window in two, one above the other"
  (lambda () (split-window! 'v)))
(define-command "split-window-right" "Split the window in two, side by side"
  (lambda () (split-window! 'h)))
;; `C-x 0` in the popup closes the popup: same window, same close, so the
;; same return. Winner still records the arrangement — popup-close! calls
;; delete-window-id!, which winner does not save, so save it here.
(define-command "delete-window" "Delete the selected window"
  (lambda ()
    (if (and (popup-open?) (equal? (active-window) (popup-window)))
        (begin (winner-save!) (popup-close!))
        (if (not (delete-window!)) (message "Attempt to delete sole window")))))
;; `C-x 1` from anywhere makes one window, and the popup is not one of
;; them: it stops being a popup rather than leaving a return nobody can use
(define-command "delete-other-windows" "Make the selected window the only one"
  (lambda ()
    (when (popup-open?)
      (let ((buf (window-buffer (popup-window))))
        (when buf (popup-float! buf #f)))
      (set-frame-local! 'popup-window #f)
      (popup-forget!))
    (delete-other-windows!)))

;; frames: one per attached browser. Deleting the selected frame while its
;; browser is still connected resets it to a fresh single window (the client
;; immediately re-attaches under the same id); deleting a disconnected
;; frame removes it for good.
(define-command "delete-frame" "Delete the selected frame"
  (lambda ()
    (delete-frame!)
    (prune-frame-locals!)))

;; landing in a rich chat/agent window puts point in its input region —
;; the transcript is for reading, the prompt is where typing goes
(define (chat-snap-to-input!)
  (let ((buf (current-buffer)))
    (when (equal? (buffer-local buf 'render-mode) "agent")
      (when (< (point) (chat-input-start buf))
        (end-of-buffer!)))))

(define-command "other-window" "Select another window in cyclic order"
  (lambda ()
    ;; a peek's window is passed by: a preview takes no focus
    (let ((start (active-window)))
      (other-window!)
      (let loop ((n (length (window-list))))
        (when (and (> n 0) (not (window-focusable? (active-window)))
                   (not (equal? (active-window) start)))
          (other-window!)
          (loop (- n 1)))))
    (chat-snap-to-input!)))
(for-each
  (lambda (name) (catalog-meta! 'command name 'domain 'windows 'effects '(write display)))
  '("split-window-below" "split-window-right" "delete-window"
    "delete-other-windows" "other-window"))

;; Cmd-arrows (s- = super) are geometric windmove: window-rects gives each
;; leaf's normalized frame rectangle, and the neighbor in DIR is the nearest
;; window past the active edge whose span contains the active center — so
;; motion follows what's on screen, not the split tree's shape.
(define (window-in-direction dir)
  (let* ((rs (window-rects))
         (me (let find ((l rs))
               (cond ((null? l) #f)
                     ((equal? (car (car l)) (active-window)) (car l))
                     (else (find (cdr l)))))))
    (and me
         (let* ((mx (list-ref me 2)) (my (list-ref me 3))
                (cx (+ mx (/ (list-ref me 4) 2)))
                (cy (+ my (/ (list-ref me 5) 2)))
                (eps 0.000001))
           (let loop ((l rs) (best #f) (bestd 999))
             (if (null? l)
                 best
                 (let* ((r (car l))
                        (x (list-ref r 2)) (y (list-ref r 3))
                        (w (list-ref r 4)) (h (list-ref r 5))
                        (d (cond ((equal? dir 'left)
                                  (and (<= (+ x w) (+ mx eps)) (<= y cy) (< cy (+ y h))
                                       (- mx (+ x w))))
                                 ((equal? dir 'right)
                                  (and (>= (+ x eps) (+ mx (list-ref me 4))) (<= y cy) (< cy (+ y h))
                                       (- x (+ mx (list-ref me 4)))))
                                 ((equal? dir 'up)
                                  (and (<= (+ y h) (+ my eps)) (<= x cx) (< cx (+ x w))
                                       (- my (+ y h))))
                                 (else
                                  (and (>= (+ y eps) (+ my (list-ref me 5))) (<= x cx) (< cx (+ x w))
                                       (- y (+ my (list-ref me 5))))))))
                   (if (and d (< d bestd))
                       (loop (cdr l) r d)
                       (loop (cdr l) best bestd)))))))))

(define (windmove! dir)
  (let ((w (window-in-direction dir)))
    (if w
        (begin (select-window! (car w))
               (chat-snap-to-input!))
        (message (string-append "No window " (symbol->string dir))))))

;; a move that lands on a peek's window goes back: a preview takes no
;; focus. M-<down> scrolls it; RET on its row opens it.
(define (windmove-focusable! dir)
  (let ((from (active-window)))
    (windmove! dir)
    (unless (window-focusable? (active-window))
      (select-window! from)
      (message "A peek: RET on its row opens it, M-<down> scrolls it"))))

(define-command "windmove-left" "Select the window to the left"
  (lambda () (windmove-focusable! 'left)))
(define-command "windmove-right" "Select the window to the right"
  (lambda () (windmove-focusable! 'right)))
(define-command "windmove-up" "Select the window above"
  (lambda () (windmove-focusable! 'up)))
(define-command "windmove-down" "Select the window below"
  (lambda () (windmove-focusable! 'down)))

;; Swap this pane's buffer with the directional neighbor's and follow it
;; (Emacs windmove-swap-states-*)
(define (window-swap! dir)
  (let ((nb (window-in-direction dir)))
    (if nb
        (let ((mine (current-buffer)))
          (switch-to-buffer! (cadr nb))
          (select-window! (car nb))
          (switch-to-buffer! mine)
          (chat-snap-to-input!))
        (message (string-append "No window " (symbol->string dir))))))

(define-command "windmove-swap-states-left" "Swap this window's buffer leftward and follow it"
  (lambda () (window-swap! 'left)))
(define-command "windmove-swap-states-right" "Swap this window's buffer rightward and follow it"
  (lambda () (window-swap! 'right)))
(define-command "windmove-swap-states-up" "Swap this window's buffer upward and follow it"
  (lambda () (window-swap! 'up)))
(define-command "windmove-swap-states-down" "Swap this window's buffer downward and follow it"
  (lambda () (window-swap! 'down)))
(for-each
  (lambda (name) (catalog-meta! 'command name 'domain 'windows 'effects '(write display)))
  '("windmove-left" "windmove-right" "windmove-up" "windmove-down"
    "windmove-swap-states-left" "windmove-swap-states-right"
    "windmove-swap-states-up" "windmove-swap-states-down"))

;; Emacs windmove has no default keys. A keymap installs them:
;; (windmove-default-keybindings MODIFIERS) binds the four arrows with
;; MODIFIERS to windmove-*. MODIFIERS is one symbol or a list of symbols
;; from shift, control, meta, super; no argument means shift. A writing
;; buffer gives Cmd-Left/Right to the line, so a user picks the chord that
;; leaves it for the window beside it.
(define *windmove-directions* '("left" "right" "up" "down"))

(define (windmove-chord modifiers key)
  (let* ((mods (cond ((or (not modifiers) (null? modifiers)) '(shift))
                     ((symbol? modifiers) (list modifiers))
                     (else modifiers)))
         (has? (lambda (m) (member m mods))))
    (string-append (if (has? 'super) "s-" "")
                   (if (has? 'control) "C-" "")
                   (if (has? 'meta) "M-" "")
                   (if (has? 'shift) "S-" "")
                   key)))

(define (windmove-install-keybindings! modifiers prefix)
  (for-each
    (lambda (dir)
      (global-set-key (windmove-chord modifiers (string-append "<" dir ">"))
                      (string-append prefix dir)))
    *windmove-directions*))

(define (windmove-default-keybindings &optional modifiers)
  (windmove-install-keybindings! modifiers "windmove-"))

;; Emacs default for the swap: shift and super
(define (windmove-swap-states-default-keybindings &optional modifiers)
  (windmove-install-keybindings! (or modifiers '(shift super))
                                 "windmove-swap-states-"))

;; S-<left>/<right>: walk buffer history — S-<left> goes to the buffer you
;; just left (MRU), pressing again goes deeper; S-<right> walks back. The
;; list freezes for the duration of a run (yank-pop's last-command trick),
;; else each switch would reorder MRU and the walk would toggle forever.
(define *buffer-cycle-ring* '())
(define *buffer-cycle-pos* 0)

(define (buffer-cycle! dir)
  (unless (member (last-command) '("next-buffer" "previous-buffer"))
    (set! *buffer-cycle-ring*
      (cons (current-buffer)
            (filter (lambda (b)
                      (and (not (string-prefix? " " b))
                           (not (buffer-context-only? b))
                           (not (equal? b (current-buffer)))))
                    (buffer-list-mru))))
    (set! *buffer-cycle-pos* 0))
  (let ((n (length *buffer-cycle-ring*)))
    (if (< n 2)
        (message "No other buffer")
        (begin
          (set! *buffer-cycle-pos* (modulo (+ *buffer-cycle-pos* dir) n))
          (switch-to-buffer! (list-ref *buffer-cycle-ring* *buffer-cycle-pos*))))))

(define-command "previous-buffer" "Switch to the previously used buffer (again = deeper)"
  (lambda () (buffer-cycle! 1)))
(define-command "next-buffer" "Walk back toward the most recently used buffer"
  (lambda () (buffer-cycle! -1)))
(catalog-meta! 'command "previous-buffer" 'domain 'buffers 'effects '(write display))
(catalog-meta! 'command "next-buffer" 'domain 'buffers 'effects '(write display))

(define-command "buffer-select" "Toggle selection on the active buffer"
  (lambda ()
    (let* ((buf (current-buffer))
           (selected (not (buffer-local buf 'buffer-selected))))
      (buffer-set-local! buf 'buffer-selected selected)
      (message (string-append buf (if selected " selected" " deselected"))))))

(define-command "buffer-unselect" "Clear selection on the active buffer"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-local! buf 'buffer-selected #f)
      (message (string-append buf " unselected")))))

(define-command "buffer-unselect-all" "Clear selection on every buffer"
  (lambda ()
    (let ((cleared 0))
      (for-each
        (lambda (buf)
          (when (buffer-local buf 'buffer-selected)
            (buffer-set-local! buf 'buffer-selected #f)
            (set! cleared (+ cleared 1))))
        (buffer-list))
      (message (string-append "Unselected " (number->string cleared)
                             " buffer" (if (= cleared 1) "" "s"))))))

;; the UI reports clicks; which window gets focus and what that means
;; (chat focuses its input) is policy
(define (mouse-select-window! id)
  (select-window! id)
  (chat-snap-to-input!))

;;; --- Input intents ---------------------------------------------------------
;;; The browser's own text pipeline (input methods, dead keys, dictation,
;;; autocorrect, spellcheck, native selection) reports what the user meant
;;; through `beforeinput`. The client sends each intent as a type, a byte
;;; range, and text. A collapsed intent at point is a key, and KeyDispatch
;;; routes it as one. A ranged intent comes here: what the range means is
;;; policy.

(define *input-intent-handlers* '())

;; (on-input-intent! TYPE FN): FN takes (from to text) and returns #t when
;; it handled the intent. A mode registers "formatBold" here.
(define (on-input-intent! type fn)
  (set! *input-intent-handlers*
    (cons (list type fn)
          (remove (lambda (entry) (equal? (car entry) type))
                  *input-intent-handlers*))))

(define (input-intent--replace! from to text)
  (goto-char! from)
  (set-mark! to)
  (delete-region!)
  (set-mark! #f)
  (goto-char! from)
  (when (> (string-length text) 0) (insert! text))
  #t)

(define (input-intent! type from to text)
  (let ((handler (assoc type *input-intent-handlers*)))
    (cond
      ((and handler ((cadr handler) from to text)) #t)
      ((member type '("insertText" "insertReplacementText" "insertCompositionText"
                      "insertFromPaste" "insertFromDrop" "insertFromYank"
                      "insertTranspose"))
       (input-intent--replace! from to text))
      ((member type '("insertParagraph" "insertLineBreak"))
       (input-intent--replace! from to "\n"))
      ;; a collapsed delete acts at point through the command it stands for
      ((and (= from to) (equal? type "deleteWordBackward"))
       (run-command "backward-kill-word") #t)
      ((and (= from to) (equal? type "deleteWordForward"))
       (run-command "kill-word") #t)
      ((and (= from to) (member type '("deleteSoftLineForward" "deleteHardLineForward")))
       (run-command "kill-line") #t)
      ((and (= from to) (member type '("deleteSoftLineBackward" "deleteHardLineBackward")))
       (let ((bol (line-start-position (line-number-at-pos (point)))))
         (input-intent--replace! bol (point) "")))
      ((string-prefix? "delete" type)
       (input-intent--replace! from to ""))
      ((equal? type "historyUndo") (run-command "undo") #t)
      (else
        (message (string-append "Unhandled input intent: " type))
        #f))))

;; one gate for clicks that run a command (dup #24). A transcript button
;; sends a command name; the modeline-info segment sends its buffer. The
;; whitelist lives here: a button runs agent-* commands only, a modeline
;; click runs the buffer's own modeline-info-command.
(define (ui-command! cmd buf)
  (cond ((and (string? cmd) (string-prefix? "agent-" cmd))
         (run-command cmd))
        ;; the modeline's name is the dashboard's click target
        ((equal? cmd "modeline-expand") (run-command cmd))
        ;; a mode name in the modeline toggles that mode
        ((and (string? cmd) (string-prefix? "mode:" cmd))
         (modeline-toggle-mode! (string-join (cdr (string-split cmd ":")) ":")))
        ((string? buf)
         (let ((c (buffer-local buf 'modeline-info-command)))
           (when (string? c) (run-command c))))
        (else #f)))

;; System clipboard delivery stops here. Paste policy belongs to Scheme: a
;; major or minor mode can register a named handler, and user config loaded
;; after the stock packages therefore gets first refusal. A handler receives
;; KIND, DATA, and MIME and returns #t only when it consumed the paste.
;; Replacing a named entry in place is important: reloading a package updates
;; its closure without moving it ahead of later user registrations.
(unless (boundp '*paste-hooks*)
  (set-symbol-value! '*paste-hooks* '()))

(define (paste-mode-name mode)
  (if (symbol? mode) (symbol->string mode) mode))

(define (paste-hook-replace hooks mode name fn)
  (cond ((null? hooks) #f)
        ((and (equal? (car (car hooks)) mode)
              (equal? (cadr (car hooks)) name))
         (cons (list mode name fn) (cdr hooks)))
        (else
          (let ((rest (paste-hook-replace (cdr hooks) mode name fn)))
            (and rest (cons (car hooks) rest))))))

(define (add-paste-hook! mode name fn)
  (let* ((mode-name (paste-mode-name mode))
         (replaced (paste-hook-replace *paste-hooks* mode-name name fn)))
    (set! *paste-hooks*
      (if replaced replaced (cons (list mode-name name fn) *paste-hooks*))))
  name)

(define (remove-paste-hook! mode name)
  (let ((mode-name (paste-mode-name mode)))
    (set! *paste-hooks*
      (remove
        (lambda (entry)
          (and (equal? (car entry) mode-name)
               (equal? (cadr entry) name)))
        *paste-hooks*)))
  name)

(define (paste-mode-active? buf mode)
  ;; a derived major mode keeps the hooks of the mode it is built from
  (or (buffer-mode-is? buf mode)
      (minor-mode-on? buf mode)))

(define (run-paste-hooks! kind data mime)
  (let ((buf (current-buffer)))
    (let loop ((hooks *paste-hooks*))
      (cond ((null? hooks) #f)
            ((and (paste-mode-active? buf (car (car hooks)))
                  ((car (cdr (cdr (car hooks)))) kind data mime))
             #t)
            (else (loop (cdr hooks)))))))

(define (clipboard-paste! text)
  (unless (run-paste-hooks! "text" text "text/plain")
    (kill-push! text)
    ;; System paste follows the ordinary editor rule: replace the active
    ;; region, then leave point active rather than continuing selection mode.
    (when (mark) (delete-region!))
    (insert! text)
    (set-mark! #f)))

(define (clipboard-image-paste! data mime)
  (unless (run-paste-hooks! "image" data mime)
    (message "No paste hook handled this image")))

;; Cmd-C with no native selection (S12, dup #26): the region when one
;; exists — pushed to the kill ring, Emacs interprogram-cut — else the
;; newest kill
(define (clipboard-copy)
  (let* ((bounds (region-action-bounds))
         (text (buffer-substring (car bounds) (cadr bounds))))
    (if (equal? text "")
        (kill-top)
        (begin (kill-push! text) text))))

;;; --- buffer links ----------------------------------------------------------
;;; A link is one string that points at a buffer, and two readers follow it.
;;; A person opens BASE/b/NAME and this editor shows the buffer at the line.
;;; A terminal or an agent reads BASE/raw/NAME and gets the text. The name is
;;; one percent-encoded segment, so a file buffer keeps the slashes in its
;;; path. The line rides in the query string, because a fragment never
;;; reaches this daemon.

(domain! 'buffers)
(effects! '(read))

(define (buffer-link &optional buf line)
  (let ((name (or buf (current-buffer)))
        (n (or line (if buf #f (line-number-at-pos (point))))))
    (string-append (editor-url) "/b/" (url-encode name)
                   (if n (string-append "?line=" (number->string n)) ""))))

(define (compos-link &optional buf line)
  (let ((name (or buf (current-buffer)))
        (n (or line (if buf #f (line-number-at-pos (point))))))
    (string-append "compos://open?path=" (url-encode name)
                   "&socket=" (url-encode (compos-socket-path))
                   (if n (string-append "&line=" (number->string n)) ""))))

(define (buffer-raw-link &optional buf)
  (string-append (editor-url) "/raw/" (url-encode (or buf (current-buffer)))))

(effects! '(write))

(define-command "copy-buffer-link"
  "Copy an compos:// link to this buffer and line to the clipboard"
  (lambda ()
    (let ((link (compos-link)))
      ;; the kill ring too: a client with no clipboard permission still
      ;; pastes it with C-y
      (kill-push! link)
      (clipboard-put! link)
      (message link))))

;; What a link means when a browser opens it. An open buffer wins, because
;; the link names a buffer. A name that is also a file path opens that file
;; — a link outlives the buffer it came from.
(define (open-buffer-link! name line)
  (cond ((buffer-known? name) (switch-to-buffer! name))
        ((file-exists? name) (visit name))
        (else (message (string-append "Dead link: no buffer " name))))
  (when (and line (buffer-exists? name))
    (goto-char! (line-start-position line))
    (recenter!)))

(domain! 'unknown)
(effects! '(unknown))

;;; --- daemon control ----------------------------------------------------------

(domain! 'system)
(effects! '(destroy execute))

;; A restart saves the desktop first, so every buffer and window comes back.
;; Interactive use asks once. An agent tool uses the shared permission policy:
;; modes can grant this command with allow-command-when!.
(define (restart-daemon-now!)
  (if (daemon-restart!)
      (message "Restarting…")
      (message "Restart refused")))

(define-command "restart-daemon" "Save the desktop and restart the daemon"
  (lambda ()
    (let ((tool-buf (and (boundp (quote *llm-tool-buffer*)) *llm-tool-buffer*)))
      (if tool-buf
          (let ((verdict
                  (if (boundp (quote *permission-policy*))
                      (*permission-policy* tool-buf "restart-daemon" "command" "")
                      'ask)))
            (if (member verdict '(allow allow-always))
                (restart-daemon-now!)
                (error "restart-daemon requires user permission")))
          (y-or-n "Restart the daemon?" restart-daemon-now!)))))

(domain! 'unknown)
(effects! '(unknown))

;;; --- default keymap --------------------------------------------------------

(global-set-key "C-f" "forward-char")
(global-set-key "C-b" "backward-char")
(global-set-key "C-n" "next-line")
(global-set-key "C-p" "previous-line")
(global-set-key "C-a" "beginning-of-line")
(global-set-key "C-e" "end-of-line")
(global-set-key "M-<" "beginning-of-buffer")
(global-set-key "M->" "end-of-buffer")
(global-set-key "<left>" "backward-char")
(global-set-key "<right>" "forward-char")
(global-set-key "<up>" "previous-line")
(global-set-key "<down>" "next-line")
(global-set-key "<home>" "beginning-of-line")
(global-set-key "<end>" "end-of-line")
;; word motion on the arrow chords, the Emacs default; a mode map may
;; take C-<right>/C-<left> for itself (paredit slurps with them)
(global-set-key "C-<right>" "forward-word")
(global-set-key "C-<left>" "backward-word")
(global-set-key "M-<right>" "forward-word")
(global-set-key "M-<left>" "backward-word")

(global-set-key "RET" "newline-or-send")
(global-set-key "DEL" "delete-backward-char")
(global-set-key "<delete>" "delete-char")
(global-set-key "C-d" "delete-char")
(global-set-key "C-k" "kill-line")
(global-set-key "C-y" "yank")
(global-set-key "C-/" "undo")
(global-set-key "C-_" "undo")
(global-set-key "C-x u" "undo")
(global-set-key "C-g" "keyboard-quit")
(global-set-key "C-u" "universal-argument")
;; ESC is Meta (dispatch translates unbound ESC k to M-k); a doubled ESC
;; quits, the Emacs way
(global-set-key "ESC ESC" "keyboard-quit")

(global-set-key "M-f" "forward-word")
(global-set-key "M-b" "backward-word")
(global-set-key "M-d" "kill-word")
(global-set-key "M-DEL" "backward-kill-word")
(global-set-key "C-t" "transpose-chars")
(global-set-key "M-y" "yank-pop")
(global-set-key "TAB" "indent-for-tab")
(global-set-key "M-g g" "goto-line")
(global-set-key "M-g M-g" "goto-line")
(global-set-key "M-m" "back-to-indentation")
(global-set-key "C-c l" "copy-buffer-link")
(global-set-key "C-c C-v" "preview-mode")
(global-set-key "C-c C-a" "app-preview")
(global-set-key "C-c C-r" "app-reload")
(global-set-key "C-`" "popup-toggle")
(global-set-key "C-M-`" "popup-bufferize")
(global-set-key "C-M-v" "scroll-other-window")
;; the other window, without leaving this one — the reference page beside
;; the work is the case this exists for. org-mode keeps M-<up>/M-<down>
;; for its subtrees: a buffer-local key wins over a global one.
(global-set-key "M-<down>" "scroll-other-window")
(global-set-key "M-<up>" "scroll-other-window-down")
(global-set-key "C-v" "scroll-up-command")
(global-set-key "M-v" "scroll-down-command")
(global-set-key "<next>" "scroll-up-command")
(global-set-key "<prior>" "scroll-down-command")
(global-set-key "C-l" "recenter-top-bottom")
(global-set-key "C-M-i" "completion-at-point")
(global-set-key "M-/" "completion-at-point")
(global-set-key "C-M-f" "forward-sexp")
(global-set-key "C-M-b" "backward-sexp")
(global-set-key "C-M-u" "backward-up-list")
(global-set-key "C-M-d" "down-list")

(global-set-key "C-SPC" "set-mark-command")
(global-set-key "C-w" "kill-region")
(global-set-key "M-w" "copy-region-as-kill")
(global-set-key "C-x C-x" "exchange-point-and-mark")
(global-set-key "C-s" "isearch-forward")
(global-set-key "C-r" "isearch-backward")
(global-set-key "M-%" "query-replace")

(global-set-key "C-x C-f" "find-file")
(global-set-key "C-x C-s" "save-buffer")
(global-set-key "C-x C-w" "write-file")
(global-set-key "C-x b" "switch-to-buffer")
(global-set-key "C-x k" "kill-buffer")
(global-set-key "C-x n n" "narrow-to-region")
(global-set-key "C-x n w" "widen")

(global-set-key "M-x" "execute-extended-command")
(global-set-key "M-<" "beginning-of-buffer")
(global-set-key "M->" "end-of-buffer")
(global-set-key "M-:" "eval-expression")
(global-set-key "C-x C-e" "eval-last-sexp")

(global-set-key "C-x 2" "split-window-below")
(global-set-key "C-x 3" "split-window-right")
(global-set-key "C-x 0" "delete-window")
(global-set-key "C-x 1" "delete-other-windows")
(global-set-key "C-x o" "other-window")
(global-set-key "C-x l" "window-layout")
(global-set-key "C-c p" "popup-buffer")
;; Cmd-arrows move between windows; Cmd-Shift-arrows carry the buffer over
(windmove-default-keybindings 'super)
(windmove-swap-states-default-keybindings '(shift super))
(global-set-key "S-<left>" "previous-buffer")
(global-set-key "S-<right>" "next-buffer")
(global-set-key "C-x <left>" "previous-buffer")
(global-set-key "C-x <right>" "next-buffer")

;;; --- the public API ----------------------------------------------------------
;;; The supported, documented surface — what apropos shows the LLM (and
;;; anyone) by default. One line each; keep it curated, not exhaustive.
;;; Each section opens with (category! 'name): the category is how an agent
;;; asks for the shape of an area instead of guessing at a search.

(category! 'buffers)
;; The scope declares what each name costs. It was a guess in a generated
;; artifact before, and a guess must not reach the permission policy.
(domain! 'buffers)
(effects! '(read))
(public! 'buffer-list "All buffer names")
(public! 'buffer-list-mru "Buffer names, most recently used first")
(public! 'buffer-exists? "(buffer-exists? NAME) -> bool")
(public! 'buffer-known? "(buffer-known? NAME) -> bool: live OR dormant. A list shows dormant buffers, so a verb asks this one")
(catalog-meta! 'function "buffer-known?" 'domain 'buffers 'effects '(read))
(effects! '(write))
(public! 'buffer-sleep! "(buffer-sleep! NAME) — checkpoint NAME and stop its process; the buffer stays known. #f when NAME is on screen, busy, or pinned")
(catalog-meta! 'function "buffer-sleep!" 'domain 'buffers 'effects '(write))
(effects! '(read))
(public! 'buffer-text "(buffer-text NAME) -> the buffer's full text")
(public! 'buffer-size "(buffer-size NAME) -> size in bytes")
(effects! '(write))
(public! 'buffer-create "(buffer-create NAME) — create if missing")
(effects! '(destroy))
(public! 'buffer-kill! "(buffer-kill! NAME) — kill a buffer; repoint its windows first")
(public! 'kill-buffer-confirm! "(kill-buffer-confirm! NAME DONE) — confirm before discarding modified file text, then call DONE with #t when killed")
(catalog-meta! 'function "kill-buffer-confirm!" 'domain 'buffers 'effects '(destroy))
(effects! '(write))
(public! 'buffer-append! "(buffer-append! NAME TEXT) — append; the usual way to add text")
(public! 'buffer-insert! "(buffer-insert! NAME BYTE-POS TEXT)")
(public! 'buffer-delete-range! "(buffer-delete-range! NAME BYTE-POS BYTE-LEN)")
(effects! '(read))
(public! 'buffer-authors "(buffer-authors NAME) -> (START END AUTHOR) spans: who wrote each byte range")
(public! 'buffer-author-lines "(buffer-author-lines NAME) -> (LINE AUTHOR BYTES) rows: who wrote each line, and how much of it")
(public! 'buffer-edit-log "(buffer-edit-log NAME) -> (VERSION AUTHOR POS INS DEL) records, newest first")
(public! 'buffer-provenance-status "(buffer-provenance-status NAME) -> the durable recording state and accepted head")
(public! 'buffer-history "(buffer-history NAME) -> every change to the buffer, oldest first, with its actor")
(effects! '(write))
(public! 'buffer-provenance-start! "(buffer-provenance-start! NAME [ACTOR REASON POLICY]) -> start or resume recording")
(public! 'buffer-provenance-stop! "(buffer-provenance-stop! NAME [ACTOR REASON POLICY]) -> stop without deleting history")
(public! 'buffer-provenance-checkpoint! "(buffer-provenance-checkpoint! NAME) -> close the current changeset")
(public! 'with-edit-author "(with-edit-author AUTHOR THUNK) — attribute THUNK's buffer edits to AUTHOR")
(public! 'current-edit-author "(current-edit-author) — the caller process's edit author string, or #f")
(catalog-meta! 'function "current-edit-author" 'domain 'buffers 'effects '(read))
(effects! '(read))
(public! 'buffer-path "(buffer-path NAME) -> file path or #f")
(public! 'buffer-modified? "(buffer-modified? NAME) -> unsaved changes?")
(public! 'buffer-local "(buffer-local NAME KEY) -> buffer-local value or #f")
(effects! '(write))
(public! 'buffer-set-local! "(buffer-set-local! NAME KEY VALUE) — locals persist with the desktop")
(effects! '(read))
(public! 'current-buffer "Name of the buffer point is in")
(effects! '(write display))
(public! 'switch-to-buffer! "(switch-to-buffer! NAME) — show in the active window")
(public! 'visit "(visit PATH [GROUP]) — open a file; GROUP joins it to that context; /ssh:HOST:/PATH opens over ssh")
(public! 'find-file-read "(find-file-read [GROUP]) — prompt for a file and join it to GROUP; no GROUP keeps it ungrouped")
(for-each
  (lambda (name) (catalog-meta! 'function name 'domain 'buffers 'effects '(write display)))
  '("switch-to-buffer!" "visit" "find-file-read"))
(domain! 'unknown)
(effects! '(read))
(public! 'buffer-link "(buffer-link [NAME] [LINE]) -> a URL that opens the buffer here; no NAME means this buffer at point")
(public! 'compos-link "(compos-link [NAME] [LINE]) -> an compos:// URL for the buffer and line; no NAME means this buffer at point")
(public! 'buffer-raw-link "(buffer-raw-link [NAME]) -> a URL that serves the buffer text as plain text")
(effects! '(write))
(public! 'open-buffer-link! "(open-buffer-link! NAME LINE) — show the buffer a link names; LINE may be #f")
(catalog-meta! 'function "open-buffer-link!" 'domain 'buffers 'effects '(write display))
(effects! '(unknown))
(public! 'tail-open "(tail-open PATH) — follow a file with tail -F, local or /ssh: remote")
(public! 'sh-quote "(sh-quote S) — S as one safe single-quoted word for a shell command")
(public! 'buffer-save! "(buffer-save! [PATH]) — save the current buffer to its path; with PATH, save there and adopt PATH")
(public! 'save-buffer-named! "(save-buffer-named! NAME) — save another buffer; the window goes back where it was")
(catalog-meta! 'function "save-buffer-named!" 'domain 'files 'effects '(write))
(catalog-meta! 'command "write-file" 'domain 'files 'effects '(write))

(category! 'editing)
(public! 'point "Point as a byte offset")
(public! 'buffer-point "(buffer-point NAME) — a named buffer's point as a byte offset")
(public! 'buffer-line-at-point
         "(buffer-line-at-point NAME) — (LINE TEXT) at the named buffer's point")
(catalog-meta! 'function "buffer-line-at-point" 'domain 'editing 'effects '(read))
(public! 'json-parse "(json-parse STR) — JSON to Scheme: objects become plists with symbol keys, null becomes #f; #f on bad input")
(public! 'register-context-provider! "(register-context-provider! MODE FN) — FN buf -> description of what the user is looking at, or #f; chat/agent sends prepend it")
(public! 'editor-context "(editor-context EXCLUDE-BUF) — visible-window contexts from registered providers, \"\" if none")
(public! 'goto-char! "(goto-char! BYTE-POS)")
(public! 'set-mb-redirect! "(set-mb-redirect! BOOL) — #f makes current-buffer ignore an active minibuffer, so a preview hook can act on the invoking buffer; restore to #t after")
(public! 'line-start-position "(line-start-position LINE) — 1-based line's start byte offset, O(log n)")
(public! 'insert! "(insert! TEXT) at point")
(public! 'delete-char! "(delete-char! N) — negative deletes backward")
(public! 'region-text "Text between mark and point (\"\" when no mark)")
(public! 'set-mark! "(set-mark! BYTE-POS or #f)")
(public! 'buffer-substring "(buffer-substring START END) of the current buffer")
(public! 'line-text "Text of the current line")
(public! 'symbol-at-point "(symbol-at-point) — the name around point, or #f")
(public! 'symbol-at-point-in "(symbol-at-point-in CHARS) — the name around point over the alphabet CHARS, or #f")
(public! 'end-of-buffer! "Move point to the end")
(public! 'beginning-of-buffer! "Move point to the start")
(for-each
  (lambda (name) (catalog-meta! 'function name 'domain 'editing 'effects '(write display)))
  '("goto-char!" "set-mb-redirect!" "insert!" "delete-char!" "set-mark!"
    "end-of-buffer!" "beginning-of-buffer!"))

(category! 'windows)
(domain! 'windows)
(effects! '(read))
(public! 'window-list "((id buffer-name) ...) for every window")
(public! 'frame-cols "(frame-cols) — usable text columns across the selected frame")
(public! 'window-showing "(window-showing NAME) — the window showing NAME, or #f")
(public! 'window-buffer "(window-buffer ID) — the buffer that window shows, or #f")
(public! 'other-window-id "(other-window-id ME) — any window that is not ME, or #f")
(public! 'active-window "Id of the selected window")
(effects! '(write display))
(public! 'select-window! "(select-window! ID)")
(public! 'split-window! "(split-window! 'h|'v [RATIO]) — ratio = first pane's share")
(public! 'delete-window-id! "(delete-window-id! ID)")
(public! 'delete-other-windows! "Make the active window the only one")
(public! 'other-window! "Select the next window")
(public! 'display-buffer "(display-buffer NAME) — honors display rules (popups)")
(public! 'display-buffer-popup!
  "(display-buffer-popup! NAME [SIDE SIZE]) — force NAME into a temporary one-third popup; compact frames use the bottom")
(public! 'display-buffer-other-window! "(display-buffer-other-window! NAME) — show NAME without leaving this window; picks the window at display time (reuse → other → split)")
(public! 'apply-layout! "(apply-layout! ANCHOR SPEC) — arrange the frame by SPEC, ANCHOR keeping focus")
(public! 'tile-windows!
  "(tile-windows! ALGORITHM BUFFERS) — arrange names with columns, rows, grid, main-right, main-left, main-bottom, or main-top")
(public! 'tile-visible-windows!
  "(tile-visible-windows! ALGORITHM) — rearrange visible work windows with a named tiler")
(for-each
  (lambda (name) (catalog-meta! 'function name 'domain 'windows 'effects '(write display)))
  '("select-window!" "split-window!" "delete-window-id!"
    "delete-other-windows!" "other-window!" "display-buffer"
    "display-buffer-popup!" "display-buffer-other-window!" "apply-layout!"
    "tile-windows!" "tile-visible-windows!"))
(effects! '(write))
(public! 'add-display-rule!
  "(add-display-rule! SUBSTRING 'popup|'same) — set display policy without showing a buffer")
(public! 'define-mode-layout!
  "(define-mode-layout! MODE '(h|v RATIO PANE ...)) — set a mode layout without applying it")
(effects! '(read))
(public! 'buffer-layout "(buffer-layout NAME) — the layout NAME's modes declare, or #f")
(effects! '(write))
(public! 'with-layout-suppressed "(with-layout-suppressed THUNK) — run THUNK without the layout engine arranging the frame")

(domain! 'unknown)
(effects! '(unknown))
(category! 'interaction)
(public! 'message "(message TEXT [LEVEL]) — log TEXT and show it in the echo area")
(public! 'minibuffer-read "(minibuffer-read PROMPT CANDIDATES HANDLER) — async; HANDLER gets the choice")
(public! 'debounce! "(debounce! KEY MS CALLBACK ARG) — after MS idle, call CALLBACK with ARG; rescheduling KEY cancels the older callback")
(catalog-meta! 'function "debounce!" 'domain 'interaction 'effects '(write execute))
(public! 'y-or-n "(y-or-n PROMPT YES &optional NO) — a one-key question; y runs YES, n and C-g run NO")
(catalog-meta! 'function "y-or-n" 'domain 'interaction 'effects '(read))
(catalog-meta! 'command "reset-layout" 'domain 'windows 'effects '(write display))
(catalog-meta! 'function "define-mode-layout!" 'domain 'windows 'effects '(write))
(public! 'read-file-name "(read-file-name PROMPT K) — prompt with filename completion from default-directory; K gets the typed path")
(public! 'abbreviate-file-name "(abbreviate-file-name PATH) — PATH with the home directory written as ~")
(public! 'buffer-modeline-name "(buffer-modeline-name BUF) — BUF's name for the modeline: project-relative, or ~ for home")
(public! 'minibuffer-read-preview "(minibuffer-read-preview PROMPT CANDIDATES ON-SELECT ON-CONFIRM ON-CANCEL &optional MATCH-HINT STYLE COMPLETE COLLECT) — preview candidates and optionally route collected rows")
(public! 'window-preview-buffer! "(window-preview-buffer! NAME) — show NAME in the active window without touching the MRU ring")
(catalog-meta! 'function "window-preview-buffer!"
  'domain 'interaction 'effects '(write display))

(category! 'commands)
(public! 'define-command "(define-command NAME [DOC] THUNK) — register an M-x command; DOC shows in M-x")
(public! 'domain! "(domain! 'NAME) — stamp following catalog declarations with their subject area")
(public! 'effects! "(effects! '(LEVEL MODIFIERS...)) — LEVEL is pure/read/write/destroy/unknown; modifiers include external/execute/spend/display")
(public! 'namespace! "(namespace! 'NAME) — set the public vocabulary for following declarations")
(public! 'catalog-meta! "(catalog-meta! KIND NAME 'domain D 'effects '(E ...)) — override catalog discovery metadata")
(public! 'run-command "(run-command NAME) — invoke any M-x command")
(public! 'command-names "All M-x command names")
(public! 'command-doc "(command-doc NAME) -> the command's docstring (\"\" if none)")
(public! 'key-for-command "(key-for-command NAME [BUF]) -> the tersest key bound to NAME, in BUF's keymap and the global one (\"\" if none)")
(public! 'global-set-key "(global-set-key KEYS COMMAND-NAME), e.g. \"C-c x\"")
(public! 'global-unset-key "(global-unset-key KEYS) — remove one global binding")
(public! 'windmove-default-keybindings "(windmove-default-keybindings &optional MODIFIERS) — bind the arrows with MODIFIERS (shift control meta super; default shift) to windmove-left/right/up/down")
(public! 'windmove-swap-states-default-keybindings "(windmove-swap-states-default-keybindings &optional MODIFIERS) — bind the arrows with MODIFIERS (default shift super) to windmove-swap-states-*")
(public! 'windmove-chord "(windmove-chord MODIFIERS KEY) — the key spec for KEY under MODIFIERS, e.g. (windmove-chord '(meta shift) \"<left>\") is \"M-S-<left>\"")
(public! 'local-set-key "(local-set-key KEYS COMMAND-NAME) in the current buffer")
(public! 'local-remap! "(local-remap! FROM-COMMAND TO-COMMAND) — Emacs [remap]: every key bound to FROM runs TO in this buffer (arrows, C-n/C-p, user bindings alike)")
(public! 'local-remap*! "(local-remap*! BUF FROM-COMMAND TO-COMMAND) — remap in an explicit buffer")
(public! 'define-mode "(define-mode NAME SETUP) — major mode; SETUP must rebuild from locals")
(public! 'mode-parent! "(mode-parent! NAME PARENT) — record that NAME is built from PARENT")
(public! 'mode-is? "(mode-is? MODE NAME) — #t when MODE is NAME or descends from it")
(public! 'buffer-mode-is? "(buffer-mode-is? BUF NAME) — #t when the buffer's major mode is NAME or descends from it")
(public! 'mode-setup! "(mode-setup! NAME) — run NAME's setup in the current buffer, the way a derived mode inherits it")
(public! 'define-list-mode!
  "(define-list-mode! NAME OPTS) — create a selectable text-table mode. Responsive layouts are ordered profiles selected by min-cols, max-cols, or default; profiles may override columns, cells, footer, and compact."
  'ui)
(catalog-meta! 'function "define-list-mode!" 'domain 'ui 'effects '(write))
(public! 'marginalia! "(marginalia! CATEGORY FN) — FN turns one candidate of CATEGORY ('file 'buffer 'command) into the text beside it; replaces the annotator for that category")
(public! 'annotate "(annotate CATEGORY NAMES) — NAMES as (LABEL HINT) candidates, through CATEGORY's annotator; NAMES unchanged when nothing registered one")
(public! 'set-mode! "(set-mode! NAME) on the current buffer")
(public! 'mode-icon! "(mode-icon! MODE ICON) — the one wide glyph that names MODE in every list")
(public! 'mode-icon "(mode-icon MODE) — MODE's icon, or the plain document icon")
(public! 'mode-label "(mode-label MODE) — MODE's icon and name, for a column that shows the mode")
(public! 'buffer-icon "(buffer-icon NAME) — the icon of the mode NAME is in")
(public! 'file-icon "(file-icon NAME) — the icon of the mode the file NAME would open in; a name ending in / is a directory")
(catalog-meta! 'function "mode-icon!" 'domain 'interaction 'effects '(write))
(catalog-meta! 'function "mode-icon" 'domain 'interaction 'effects '(pure))
(catalog-meta! 'function "mode-label" 'domain 'interaction 'effects '(pure))
(catalog-meta! 'function "buffer-icon" 'domain 'interaction 'effects '(read))
(catalog-meta! 'function "file-icon" 'domain 'interaction 'effects '(pure))
(public! 'add-hook! "(add-hook! 'name-hook FN)")
(public! 'add-paste-hook! "(add-paste-hook! MODE NAME FN) — for a major or minor MODE, register named FN(kind data mime); #t consumes the paste")
(public! 'remove-paste-hook! "(remove-paste-hook! MODE NAME) — remove a named paste handler")
(public! 'layout-arranging? "(layout-arranging?) — #t while the layout engine is building the frame; a package that moves windows must stand down")
(public! 'layout-abort! "(layout-abort!) — clear a layout build left in progress by a failure; a top-level build calls this first")
(public! 'frame-attached! "(frame-attached!) — a client attached this frame; runs frame-attach-hook so per-frame display state is pushed again")
(public! 'overlay-set! "(overlay-set! NAME TAG ((START END FACE) ...)) — replaces TAG's ranges")
(public! 'overlay-clear! "(overlay-clear! NAME TAG)")

;; the buffer cache — external data drawn from what the buffer already
;; holds; the fetch runs off the UI lane through a continuation
(category! 'buffers)
(public! 'cache-declare! "(cache-declare! BUF FETCH RENDER TTL) — FETCH is (buf k): do the work off the UI lane and call (k DATA), (k #f) on failure; RENDER is (buf data); TTL seconds, #f = manual refresh only")
(public! 'cache-refresh! "(cache-refresh! BUF) — fetch and re-render; one flight at a time; the buffer shows what it has until the data lands")
(public! 'cache-wake! "(cache-wake! BUF) — refresh only when the cache is stale; the wake rule for restored and previewed buffers")
(public! 'cache-stale? "(cache-stale? BUF) — no stamp yet, or older than the declared TTL")
(public! 'cache-age "(cache-age BUF) — seconds since the last successful render, or #f")
(public! 'cache-age-label "(cache-age-label BUF) — \"just now\", \"40s ago\", \"5m ago\", for a header or modeline")
(public! 'cache-stamp! "(cache-stamp! BUF) — mark the buffer's content as fetched now")

(category! 'chat)
(public! 'llm "(llm PROMPT HANDLER) — async completion; HANDLER gets the text")
(catalog-meta! 'function "llm" 'domain 'llm 'effects '(read external execute spend))
(public! 'llm-with-model "(llm-with-model PROMPT MODEL HANDLER) — async completion with an explicit model")
(public! 'llm-model "Current model id")
(public! 'set-llm-model! "(set-llm-model! ID) — a \"provider:model\" prefix routes to that provider; a bare id is Anthropic")





;; git
;; Every one takes an optional trailing CALLBACK. With one the call returns
;; at once and the callback gets the value; without one the caller waits.
;; An error comes back as the plist (error "message").
(public! 'git-root "(git-root DIR [CB]) -> absolute work-tree root; resolves from a subdirectory")
(public! 'git-status "(git-status DIR [CB]) -> list of (path P orig-path P2|#f index X worktree Y); X/Y are the git status columns, ? is untracked")
(public! 'git-diff "(git-diff DIR [OPTS] [CB]) -> list of (file-a A file-b B binary? BOOL hunks (...)); each hunk is (header H old-start N old-count N new-start N new-count N lines ((ctx|add|del TEXT) ...)). OPTS: (base \"HEAD\" path P staged #t); a #f base diffs the work tree against the index")
(public! 'git-log "(git-log DIR N [CB]) -> last N commits as (sha S short-sha S author A date ISO subject S)")
(public! 'git-show "(git-show DIR REF [CB]) -> the raw text of one commit")

;; the file watcher
;; The event is content-free: it names the root, and the handler re-queries.
;; Watch coalesces a burst of writes into one event per root.
(public! 'watch-path! "(watch-path! DIR ['deep]) -> the watched root; refcounted, so two watchers of one directory share one subscription. A plain watch sees the direct children of DIR; 'deep sees the whole tree, for a repository")
(public! 'unwatch-path! "(unwatch-path! DIR ['deep]) — drop one reference, 'deep for a deep one; the subscription stops at zero")
(public! 'watched-paths "The watched roots")
(public! 'on-fs-change! "(on-fs-change! FN) — FN gets the root string when a watched tree changes; keep it small, it schedules a refresh")

;; folds
;; Tagged, because a buffer has several fold owners. Each owner replaces
;; only its own tag; the display hides the union of every tag.
(public! 'fold-set! "(fold-set! BUF TAG RANGES) — replace TAG's hidden byte ranges, a list of (START END)")
(public! 'fold-get "(fold-get BUF [TAG]) -> TAG's hidden ranges; no TAG, or 'all, gives the union")
(public! 'fold-clear! "(fold-clear! BUF [TAG]) — drop TAG's folds; no TAG, or 'all, drops every owner's")
(public! 'fold-toggle! "(fold-toggle! BUF TAG RANGE) — add or remove one (START END) in TAG; for owners whose state is the range list itself")
(namespace! 'core)
(effects! '(write display))
(public! 'buffer-narrow! "(buffer-narrow! BUF START END) — narrow visible text to the exclusive byte range without changing buffer access" 'buffers)
(effects! '(read))
(public! 'buffer-narrow-range "(buffer-narrow-range BUF) -> active (START END) narrowing, or #f" 'buffers)
(effects! '(write display))
(public! 'buffer-widen! "(buffer-widen! BUF) — make the complete buffer visible" 'buffers)
(catalog-meta! 'function "buffer-narrow!"
  'namespace 'core 'qualified-name "core/buffer-narrow!"
  'domain 'buffers 'effects '(write display))
(catalog-meta! 'function "buffer-narrow-range"
  'namespace 'core 'qualified-name "core/buffer-narrow-range"
  'domain 'buffers 'effects '(read))
(catalog-meta! 'function "buffer-widen!"
  'namespace 'core 'qualified-name "core/buffer-widen!"
  'domain 'buffers 'effects '(write display))

(message "editor.scm loaded")
