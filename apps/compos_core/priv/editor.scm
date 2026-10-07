;;; editor.scm --- the editor, in Scheme.
;;;
;;; The Elixir core knows nothing about what keys mean or what commands do.
;;; Everything here is userland: redefine any of it from init.scm or M-:.

;;; --- wrapping a function once -----------------------------------------------
;;; The editor wraps a function by defining a wrapper under the wrapped
;;; name, and calling the original under a second name. Scheme must capture
;;; the original ONE time. A whole-file reload evaluates the capturing form
;;; again, and the wrapped name then holds the wrapper: a second capture
;;; points the wrapper at itself, and the next call recurses until the heap
;;; bound stops it. On 2026-09-10 define-command--raw took that path, and
;;; the daemon could define no command again.
;;;
;;; So a capture keeps its first value, the way defvar keeps a variable.
;;;
;;; A wrapped PRIMITIVE needs no capture at all: `Compos.Core.SchemeRawNames`
;;; registers the raw name in Elixir, which also keeps it repairable with
;;; `M-x reload-scheme`. Use alias-once! to wrap a Scheme function, the way
;;; custom.scm wraps load-theme.

(define (alias-once! name target)
  (unless (boundp name) (set-symbol-value! name (symbol-value target)))
  name)

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

(define catalog--get plist-get)
(define catalog--put plist-put)

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
    (catalog--changed! entry)))

;; every write ends here: the generation moves and apropos hears about it
(define (catalog--changed! entry)
  (catalog--touch!)
  (when (boundp (quote apropos-catalog-changed!))
    (apropos-catalog-changed! entry))
  entry)

;; drop one entry, and its key; a name the catalog does not hold costs nothing
(define (catalog-forget! kind name)
  (let ((e (catalog-entry kind name)))
    (when e
      (let ((k (catalog--string kind)))
        (set! *catalog-keys*
          (remove (lambda (x) (equal? x (catalog--key k (catalog--get e 'name)
                                                        (catalog--get e 'qualified-name))))
                  *catalog-keys*))
        (set! *catalog*
          (remove (lambda (x) (and (equal? (catalog--get x 'kind) k)
                                   (equal? (catalog--get x 'qualified-name)
                                           (catalog--get e 'qualified-name))))
                  *catalog*))
        (catalog--changed! #f)))
    (and e #t)))

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
          (catalog--changed! updated)))))

;; Commands are an Elixir registry underneath, but this wrapper gives every
;; declaration the same package/domain/effect metadata as Scheme APIs.

;;; --- interactive: how a command gets its arguments ----------------------------
;;; Emacs's (interactive "p"). A command may take arguments; the spec says
;;; where they come from when a key runs it, and command-call passes them
;;; when Scheme does. Codes: 'p the numeric prefix argument; 'P the raw one;
;;; 'r the region start and end, two arguments; 'b the current buffer; 'd
;;; point; 'm the mark or point; a string "sPrompt: " reads a string from
;;; the minibuffer ("n" a number, "f" a file, "b" a buffer name).
;;;
;;;   (define-command "next-line" "Move point down" (interactive 'p)
;;;     (lambda (n) ...))

(define (interactive &rest codes) (cons 'interactive codes))

(define (interactive-spec? x) (and (pair? x) (equal? (car x) 'interactive)))

(define (interactive--arg code k)
  (cond ((equal? code 'p) (k (prefix-numeric-value (current-prefix-arg))))
        ((equal? code 'P) (k (current-prefix-arg)))
        ((equal? code 'r) (k (list (region-beginning) (region-end))))
        ((equal? code 'b) (k (current-buffer)))
        ((equal? code 'd) (k (point)))
        ((equal? code 'm) (k (or (mark) (point))))
        ((string? code)
         (let ((kind (substring code 0 1))
               (prompt (substring code 1 (string-length code))))
           (cond ((equal? kind "n")
                  (minibuffer-read prompt '()
                    (lambda (v) (k (let ((n (string->number v))) (if (number? n) n 0))))))
                 ((equal? kind "f") (read-file-name prompt k))
                 ((equal? kind "b") (minibuffer-read prompt (buffer-list) k))
                 (else (minibuffer-read prompt '() k)))))
        (else (k #f))))

;; the arguments collect left to right; a prompt is asynchronous, so the
;; rest of the collection is its continuation
(define (interactive--collect codes acc fn)
  (if (null? codes)
      (apply fn (reverse acc))
      (interactive--arg (car codes)
        (lambda (v)
          (interactive--collect (cdr codes)
                                (if (equal? (car codes) 'r)
                                    (append (reverse v) acc)
                                    (cons v acc))
                                fn)))))

(define (call-interactively--spec spec fn)
  (interactive--collect (cdr spec) '() fn))

;; (define-command NAME [DOC] [SPEC] FN)
;;
;; A command lives in two places and no more: the Elixir command table,
;; which run-command and the keys reach, and the catalog, which carries
;; its doc and its spec. The closure in the table takes the arguments
;; command-call passes; with none it collects them from the spec.
(define (define-command name &rest args)
  (let* ((doc (if (and (pair? args) (string? (car args))) (car args) ""))
         (rest (if (and (pair? args) (string? (car args))) (cdr args) args))
         (spec (and (pair? rest) (interactive-spec? (car rest)) (car rest)))
         (fn (if spec (cadr rest) (car rest)))
         ;; A command with no spec is its own function: run-command calls
         ;; it with no arguments and describe-function shows its body. A
         ;; command with a spec is wrapped: run-command's empty call
         ;; collects the arguments, and command-call passes 'direct first
         ;; so the function runs as given.
         (entry (if spec
                    (lambda (&rest args)
                      (cond ((and (pair? args) (equal? (car args) 'direct))
                             (apply fn (cdr args)))
                            ((null? args) (call-interactively--spec spec fn))
                            (else (apply fn args))))
                    fn)))
    (if (> (string-length doc) 0)
        (define-command--raw name doc entry)
        (define-command--raw name entry))
    (catalog-register! 'command name doc
      'use (string-append "(run-command \"" name "\")")
      'spec (or spec #f))
    name))

;; the closure behind a command, from the one table
(define (command-function name) (command-fn name))

;; (command-call NAME ARG ...): run the command with ARGS. A command with
;; no spec takes none; with none given, a spec collects them.
(define (command-call name &rest args)
  (let ((fn (command-function name))
        (spec (let ((e (catalog-entry 'command name))) (and e (plist-get e 'spec)))))
    (cond ((not fn) (run-command name))
          (spec (apply fn (cons 'direct args)))
          (else (fn)))))

;; Emacs call-interactively: run NAME as a key would
(define (call-interactively name) (run-command name))

(define (undefine-command name)
  (undefine-command--raw name)
  (catalog-forget! 'command name)
  name)

;;; --- public API registry -----------------------------------------------------
;;; The supported surface, curated: name + one-line doc. Everything else in
;;; the global namespace is implementation detail — callable, but private by
;;; convention. The LLM's apropos searches this registry by default, so
;;; the model discovers a documented API instead of hundreds of internals.
;;; Declare yours next to its definition: (public! 'my-fn "what it does").

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

;; A public function is a catalog entry of kind function, nothing more:
;; the doc, the signature split out of it, and the category it was
;; declared under. public-api and public-entry read the catalog back in
;; the shape their callers know: (NAME DOC SIG CATEGORY).
(define (public! name doc &optional category)
  (let* ((n (symbol->string name))
         (parts (public--split doc))
         (sig (or (car parts) (string-append "(" n ")")))
         (text (car (cdr parts)))
         (cat (or category *public-category*)))
    (catalog-register! 'function n text
      'domain cat 'category cat 'signature sig 'use sig)))

(define (public--tuple e)
  (list (catalog--get e 'name) (catalog--get e 'doc)
        (catalog--get e 'signature)
        (or (catalog--get e 'category) (string->symbol (catalog--get e 'domain)))))

(define (public-api)
  (map public--tuple
       (filter (lambda (e) (equal? (catalog--get e 'kind) "function")) (catalog))))

(define (public-entry name)
  (let ((e (catalog-entry 'function name)))
    (and e (public--tuple e))))

(define (public-categories)
  (let loop ((es (public-api)) (acc '()))
    (cond ((null? es) (reverse acc))
          ((member (nth 3 (car es)) acc) (loop (cdr es) acc))
          (else (loop (cdr es) (cons (nth 3 (car es)) acc))))))

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

;; a local the desktop must not save: derived state a wake rebuilds
(define (desktop-skip! buf key)
  (let ((cur (or (buffer-local buf 'desktop-skip-locals) '())))
    (unless (member key cur)
      (buffer-set-local! buf 'desktop-skip-locals (cons key cur)))))

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
             ;; a render may retire its own buffer — browse hands a PDF to
             ;; the file's own mode and kills the tab — so the stamp asks
             ;; again whether there is still a buffer to stamp
             (when (buffer-known? buf) (cache-stamp! buf)))))))))

;; the wake rule: show the cache, and fetch only past the TTL
(define (cache-wake! buf)
  (when (cache-stale? buf) (cache-refresh! buf)))

;;; --- plists ------------------------------------------------------------------
;;; Flat plists — (key value key value ...) with symbol keys — are the house
;;; record shape: events, configs, conversation turns. This dialect has no
;;; dotted pairs, so there are no alists to confuse them with.

;; plist-get is a builtin: the flat plist read is the hottest list read.

;; list-ref by its Emacs name; list-ref is a builtin
(define (nth n l) (list-ref l n))

;;; --- editing commands ------------------------------------------------------

;; (repeat-count N THUNK): THUNK N times; a negative N runs OPPOSITE -N times
(define (repeat-count n thunk &optional opposite)
  (cond ((and (< n 0) opposite) (repeat-count (- n) opposite))
        (else (let loop ((i 0)) (when (< i n) (thunk) (loop (+ i 1)))))))

(define-command "forward-char" "Move point one character forward" (interactive 'p)
  (lambda (n) (repeat-count n forward-char! backward-char!)))
(define-command "backward-char" "Move point one character backward" (interactive 'p)
  (lambda (n) (repeat-count n backward-char! forward-char!)))
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

(define (next-line-n! n)
  (repeat-count n
    (lambda () (or (preview-scroll! 3) (visual-next-line!)))
    (lambda () (or (preview-scroll! -3) (visual-previous-line!)))))

(define-command "next-line" "Move point down one line" (interactive 'p)
  (lambda (n) (next-line-n! n)))
(define-command "previous-line" "Move point up one line" (interactive 'p)
  (lambda (n) (next-line-n! (- n))))
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

(define-command "newline" "Insert a newline at point" (interactive 'p)
  (lambda (n) (repeat-count n (lambda () (insert! "\n")))))
(define (delete-active-region!)
  (if (and (mark) (< (region-beginning) (region-end)))
      (begin
        (delete-region!)
        (set-mark! #f)
        #t)
      #f))

(define-command "delete-backward-char" "Delete the character before point" (interactive 'p)
  (lambda (n)
    (unless (delete-active-region!) (delete-char! (- n)))))
(define-command "delete-char" "Delete the character after point" (interactive 'p)
  (lambda (n)
    (unless (delete-active-region!) (delete-char! n))))

;;; --- the kill ring: a kill after a kill appends -------------------------------
;;; Emacs: a kill command that follows a kill command grows the newest
;;; entry, so C-k C-k C-k yanks back as one piece. A kill that follows
;;; anything else starts an entry.

(define *kill-commands*
  '("kill-line" "kill-region" "kill-word" "backward-kill-word" "kill-whole-line"
    "kill-sexp" "backward-kill-sexp" "kill-paragraph"))

(define (kill-appends?)
  (and (member (last-command) *kill-commands*) #t))

;; put TEXT on the ring: onto the newest entry after a kill, else as a
;; new entry. BEFORE? puts it in front, for a backward kill.
(define (kill-text! text &optional before?)
  (if (kill-appends?)
      (kill-append! text (if before? #t #f))
      (kill-push! text))
  text)

;; the Emacs names
(define (kill-new text) (kill-push! text))
(define-command "kill-line" "Kill text from point to end of line" (interactive 'p)
  (lambda (n)
    (let loop ((i 0) (acc ""))
      (if (>= i n)
          (if (equal? acc "") #f (kill-text! acc))
          (let ((killed (kill-line!)))
            (if (equal? killed "")
                (if (equal? acc "") #f (kill-text! acc))
                (loop (+ i 1) (string-append acc killed))))))))

(define-command "undo" "Undo the last change" (interactive 'p)
  (lambda (n)
    (let loop ((i 0))
      (when (< i n)
        (if (undo!)
            (loop (+ i 1))
            (message "No further undo information"))))))

;;; --- minibuffer --------------------------------------------------------------
;;; The minibuffer is a real buffer (" *minibuf*"): point motion, kill/yank,
;;; undo and M-DEL all work in prompts for free via the global keymap. Only
;;; prompt-specific behavior is bound here, in its local keymap.

;;; --- the rail: the palette's second list -------------------------------------
;;; A modal prompt can carry a list on the right as well as the left. Only
;;; one of the two holds the keys: <right> steps into the rail, <left>
;;; steps back out, and up/down/RET always mean the list you are standing
;;; in. The prompt owns the rows and what RET does with one; this keeps
;;; the cursor and tells the frame, so the view infers nothing.

(define *mb-rail-rows* '())
(define *mb-rail-index* 0)
(define *mb-rail-focus* #f)
(define *mb-rail-pick* #f)

(define (mb-rail-reset!)
  (set! *mb-rail-rows* '())
  (set! *mb-rail-index* 0)
  (set! *mb-rail-focus* #f)
  (set! *mb-rail-pick* #f))

(define (mb-rail-push!)
  (minibuffer-rail! *mb-rail-rows* *mb-rail-index* *mb-rail-focus*))

;; ROWS is ((LABEL HINT . REST) ...) — the frame reads the first two and
;; carries the rest untouched, so PICK gets back the whole row and the
;; prompt can act on what it put there
(define (mb-rail! rows pick)
  (set! *mb-rail-rows* rows)
  (set! *mb-rail-pick* pick)
  (when (null? rows) (set! *mb-rail-focus* #f))
  (when (>= *mb-rail-index* (length rows)) (set! *mb-rail-index* 0))
  (mb-rail-push!))

(define (mb-rail-focused?) (and *mb-rail-focus* (pair? *mb-rail-rows*)))

(define (mb-rail-enter!)
  (cond ((mb-rail-focused?) #t)
        ((null? *mb-rail-rows*) #f)
        (else (set! *mb-rail-focus* #t) (set! *mb-rail-index* 0) (mb-rail-push!) #t)))

(define (mb-rail-exit!)
  (if (mb-rail-focused?)
      (begin (set! *mb-rail-focus* #f) (mb-rail-push!) #t)
      #f))

(define (mb-rail-move! delta)
  (if (mb-rail-focused?)
      (begin
        (set! *mb-rail-index*
              (max 0 (min (- (length *mb-rail-rows*) 1) (+ *mb-rail-index* delta))))
        (mb-rail-push!)
        #t)
      #f))

(define (mb-rail-confirm!)
  (if (and (mb-rail-focused?) *mb-rail-pick*)
      (begin (*mb-rail-pick* (list-ref *mb-rail-rows* *mb-rail-index*)) #t)
      #f))

(define-command "minibuffer-rail-enter"
  "Move the arrows into the list on the right of the palette"
  (lambda () (if (mb-rail-enter!) #t (run-command "forward-char"))))
(define-command "minibuffer-rail-exit"
  "Leave the list on the right and go back to the candidates"
  (lambda () (if (mb-rail-exit!) #t (run-command "backward-char"))))

(define-command "minibuffer-confirm" "Accept the selected minibuffer candidate"
  (lambda () (if (mb-rail-confirm!) #t (minibuffer-confirm!))))
;; RET takes the candidate. C-RET takes the same candidate with a
;; different verb, and the prompt that cares (the buffer switcher)
;; reads and resets the flag:
;;   RET    go there, move nothing else
;;   C-RET  enter the candidate's context, layout and all
(define *mb-confirm-context* #f)
(define-command "minibuffer-confirm-context"
  "Accept the selected candidate as a context (group) switch"
  (lambda () (set! *mb-confirm-context* #t) (minibuffer-confirm!)))
(define-command "minibuffer-confirm-input" "Accept the minibuffer input exactly as typed"
  (lambda () (minibuffer-confirm-input!)))
(define-command "minibuffer-cancel" "Cancel the minibuffer prompt"
  (lambda () (minibuffer-cancel!)))

;;; The shape is not a different prompt. What you opened as a modal can
;;; finish as the bottom bar and go back, carrying the same input, the same
;;; candidates and the same selection: only the geometry changes. A prompt
;;; that says what its row means (a question) keeps its shape.
;;;
;;; A prompt that stands in front of a LIST changes shape with it. The
;;; table is a window and the prompt is a line, and the two are one
;;; surface: the shape says where that surface is.
;;;
;;;   minibuffer  a DOCK: the bottom rows of the frame, in the flow. The
;;;               window tree shrinks by exactly that much, so the surface
;;;               covers no work and hides nothing. This is the default.
;;;   panel       the same rows, floating over the work. Nothing reflows
;;;               and the work underneath is hidden while you look.
;;;   modal       the centred palette.
;;;
;;; The panel and the modal are the float (window.scm): a shape a prompt
;;; wears for as long as it is open.

(define minibuffer-default-shape "minibuffer")

;;; --- the dock ------------------------------------------------------------
;;; A dock is a pane of the FRAME. split-root! splits the whole tree, so
;;; the pane spans the frame and every window above keeps its share of
;;; what is left: the surface takes rows rather than covering them. This
;;; is what makes the minibuffer shape a minibuffer and not a panel.
;;;
;;; Splitting the selected window instead gives a pane as wide as whatever
;;; window happened to be selected, which is a sub-pane, not a dock.

(define (window-docked buf)
  (and (buffer-known? buf) (buffer-local buf 'window-dock)))

;; A dock is not a work window. Every rule that keeps the float out of
;; the layout keeps a dock out too: the tiler must not count it, fill it,
;; or renumber it away, and a display must never land in it.
(define (window-dock? win buf) (and buf (equal? (window-docked buf) win)))

(define (window-dock! buf size)
  (let ((win (split-root! 'v (- 1 size))))
    (when win
      (window-float-class! buf #f)
      (buffer-set-local! buf 'window-dock win)
      (display-buffer-in-window! win buf)
      (select-window! win))
    win))

(define (window-undock! buf)
  (let ((win (window-docked buf)))
    (when (buffer-known? buf) (buffer-set-local! buf 'window-dock #f))
    (and win (window-exists? win) (delete-window-id! win))))

;; BUF's window wears SHAPE. The buffer remembers it, so a display of
;; this buffer takes the shape too, and a shape change moves the surface
;; and nothing else: no mode setup runs, so a table keeps its rows, its
;; filter and the row the reader is on.
(define (window-shape! buf shape)
  (buffer-set-local! buf 'window-shape shape)
  (if (equal? shape "minibuffer")
      (begin
        (when (equal? (float-buffer) buf) (float-close!))
        (window-float-class! buf #f)
        (unless (window-docked buf)
          (window-dock! buf (display-param buf 'size))))
      (begin
        (window-undock! buf)
        (window-float-class! buf
          (if (equal? shape "modal") 'center 'bottom)
          (display-param buf 'size))
        (unless (window-showing buf) (display-buffer buf)))))

;; the list standing behind the prompt takes the shape the prompt takes
(define (mb-list-shape! shape)
  (let ((buf *mb-list-buffer*))
    (when (and buf (buffer-known? buf)) (window-shape! buf shape))))

(define (minibuffer-shape)
  (let* ((st (minibuffer-state))
         (style (and st (plist-get st 'style))))
    (cond ((member style '("modal" "palette")) "modal")
          ((member style '("panel" "popup")) "panel")
          (else "minibuffer"))))

(define (minibuffer-shape-after here)
  (cond ((equal? here "minibuffer") "panel")
        ((equal? here "panel") "modal")
        (else "minibuffer")))

;; The shape of a prompt with a list behind it is the shape of the list:
;; the filter line is one row either way, and what moves is the table.
;; So a filter prompt cycles, and only a question keeps its shape.
(define (minibuffer-list-shape)
  (and *mb-list-buffer*
       (buffer-known? *mb-list-buffer*)
       (let ((side (float-side-of *mb-list-buffer*)))
         (cond ((equal? side 'center) "modal")
               (side "panel")
               (else "minibuffer")))))

(define-command "minibuffer-cycle-shape"
  "Show this prompt as the bottom bar, the panel, or the modal"
  (lambda ()
    (if (not (minibuffer-active?))
        (message "No prompt")
        (let ((style (plist-get (minibuffer-state) 'style))
              (list-shape (minibuffer-list-shape)))
          (cond
            ((equal? style "question") (message "This prompt keeps its shape"))
            (list-shape
              (let ((next (minibuffer-shape-after list-shape)))
                (mb-list-shape! next)
                (message next)))
            ((equal? style "filter") (message "This prompt keeps its shape"))
            (else
              (let ((next (minibuffer-shape-after (minibuffer-shape))))
                (minibuffer-style! next)
                (message next))))))))
(define-command "minibuffer-next-candidate" "Select the next minibuffer candidate"
  (lambda ()
    (cond ((mb-rail-move! 1) #t)
          ((mb-list-move! 1) #t)
          (else (minibuffer-next!) (mb-select-notify!)))))
(define-command "minibuffer-previous-candidate" "Select the previous minibuffer candidate"
  (lambda ()
    (cond ((mb-rail-move! -1) #t)
          ((mb-list-move! -1) #t)
          (else (minibuffer-prev!) (mb-select-notify!)))))
;; A prompt may let its rows be deleted: *mb-row-delete-fn* is a thunk that
;; deletes the highlighted row. <delete> runs it, and DEL does on an empty
;; input, where there is no character to delete.
(define *mb-row-delete-fn* #f)

(define-command "minibuffer-delete-backward" "Delete the character before point, or the highlighted row of an empty prompt that allows it"
  (lambda ()
    (if (and *mb-row-delete-fn* (equal? (minibuffer-input) ""))
        (*mb-row-delete-fn*)
        (minibuffer-del!))))

(define-command "minibuffer-delete-row" "Delete the highlighted row, in a prompt that allows it"
  (lambda ()
    (if *mb-row-delete-fn*
        (*mb-row-delete-fn*)
        (message "Nothing here deletes a row"))))
(define-command "minibuffer-complete"
  "Fold the section at hand in the list behind the prompt, else complete the input"
  (lambda () (if (mb-list-call! 'fold) #t (minibuffer-complete!))))
(define-command "minibuffer-regroup"
  "Cycle what a section is in the list behind the prompt"
  (lambda () (if (mb-list-call! 'regroup) #t (message "no list here"))))
(define-command "minibuffer-next-section"
  "Move to the next section in the list behind the prompt, else the next history entry"
  (lambda ()
    (cond ((and *mb-history-key* (>= *mb-history-pos* 0))
           (run-command "next-history-element"))
          ((mb-list-section! 1) #t)
          (else (run-command "next-history-element")))))
(define-command "minibuffer-previous-section"
  "Move to the previous section in the list behind the prompt, else the previous history entry"
  ;; an empty prompt, or one already walking its history, walks the history
  (lambda ()
    (cond ((and *mb-history-key* (or (>= *mb-history-pos* 0) (equal? (minibuffer-input) "")))
           (run-command "previous-history-element"))
          ((mb-list-section! -1) #t)
          (else (run-command "previous-history-element")))))

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
;; One prompt at a time, as in Emacs without enable-recursive-minibuffers.
;; A prompt that opens while another is up cancels the outer one first,
;; so its cancel handler restores what it displaced, instead of the
;; outer prompt vanishing with its closures.

(define (minibuffer-active?) (if (minibuffer-state) #t #f))

;; what the prompt holds now, "" without a prompt
(define (minibuffer-input)
  (let ((st (minibuffer-state)))
    (if st (plist-get st 'input) "")))

(define (minibuffer-read* prompt cands handlers)
  (when (minibuffer-active?)
    (minibuffer-cancel!)
    (message "Quit the outer prompt"))
  ;; A deferred list draw belongs to this prompt only.
  (set! *mb-list-flush* #f)
  ;; a rail belongs to one prompt: the next one starts without it
  (mb-rail-reset!)
  (let ((r (minibuffer-read*--raw prompt cands handlers)))
    ;; the frame's prompt buffer exists once a prompt has opened in it
    (minibuffer-mode-ensure!)
    r))

;; one interaction model: a completion prompt is the BOTTOM bar, like
;; Emacs — the candidates sit above the input and the input sits on the
;; last row. Only a prompt that asks for "palette" by name floats: the
;; switcher, the command palette, and the LLM config menus.
;;
;; the builtin reads (prompt cands confirm) or (prompt cands complete
;; confirm); this wrapper keeps both shapes
(define (minibuffer-read prompt cands a &optional b)
  (minibuffer-read* prompt cands
    (append
      (list (list 'confirm (if b b a)))
      (if b (list (list 'complete a)) '())
      (list (list 'style #f)))))

;;; --- completing-read ----------------------------------------------------------
;;; Emacs's completing-read, asynchronous: K gets the choice. COLLECTION is
;;; a list of candidates (strings or (label hint) rows) or a procedure of
;;; the input that answers the rows. OPTS is a plist:
;;;   'predicate FN       keep the candidates FN accepts
;;;   'require-match #t   RET takes a candidate only; free text says [No match]
;;;   'initial TEXT       the input to start with
;;;   'default TEXT       the answer to an empty input, listed first
;;;   'history SYM        the history to read and to push the choice on
;;;   'category SYM       the marginalia annotator to use
;;;   'style SYM          how the input matches: flex, substring, prefix, regexp
;;;   'annotate? #f       the rows are annotated already

(define *mb-history-key* #f)          ; the history the active prompt walks
(define *mb-history-pos* -1)          ; -1 is the input, 0 the newest item
(define *mb-history-input* "")        ; what was typed before M-p

(define (completing-read--rows collection input)
  (if (procedure? collection) (collection input) collection))

(define (completing-read--label row) (if (pair? row) (car row) row))

(define (completing-read--prepare rows opts)
  (let* ((pred (plist-get opts 'predicate))
         (kept (if pred (filter (lambda (r) (pred (completing-read--label r))) rows) rows))
         (default (plist-get opts 'default))
         (led (if (and default (member default (map completing-read--label kept)))
                  (cons (let loop ((rs kept))
                          (if (equal? (completing-read--label (car rs)) default) (car rs) (loop (cdr rs))))
                        (filter (lambda (r) (not (equal? (completing-read--label r) default))) kept))
                  kept))
         (hist (plist-get opts 'history))
         (ordered (if (and hist (not (pair? (car (or (and (pair? led) led) '("")))))) (history-order hist led) led))
         (category (plist-get opts 'category)))
    (if (and category (not (equal? (plist-get opts 'annotate?) #f)))
        (annotate category ordered)
        ordered)))

(define (completing-read prompt collection k &rest opts)
  (let* ((hist (plist-get opts 'history))
         (default (plist-get opts 'default))
         (require? (plist-get opts 'require-match))
         (rows (completing-read--prepare (completing-read--rows collection "") opts))
         (labels (lambda () (map completing-read--label
                                (completing-read--prepare
                                  (completing-read--rows collection (minibuffer-input)) opts))))
         (confirm
           (lambda (v)
             (let ((v (if (and default (equal? v "")) default v)))
               (cond ((and require? (not (member v (labels))))
                      (message "[No match]")
                      (apply completing-read (append (list prompt collection k) opts)))
                     (else
                       (when hist (history-push! hist v))
                       (set! *mb-history-key* #f)
                       (k v)))))))
    (set! *mb-history-key* hist)
    (set! *mb-history-pos* -1)
    (minibuffer-read* prompt rows
      (append
        (list (list 'confirm confirm)
              (list 'cancel (lambda () (set! *mb-history-key* #f))))
        (if (procedure? collection)
            (list (list 'change
                        (lambda (input)
                          (minibuffer-set-candidates!
                            (completing-read--prepare (collection input) opts)))))
            '())
        (if (plist-get opts 'initial) (list (list 'initial (plist-get opts 'initial))) '())
        (if (plist-get opts 'style) (list (list 'completion-style (plist-get opts 'style))) '())
        (list (list 'style #f))))))

;; the Emacs readers, each a completing-read of one kind
(define (read-string prompt k &rest opts)
  (apply completing-read (append (list prompt '() k) opts)))

;; the history ring: M-p walks back through what this prompt was answered
;; with, M-n forward, and past the newest the input comes back
(define (minibuffer-history-step! delta)
  (let ((items (if *mb-history-key* (history-items *mb-history-key*) '())))
    (cond ((null? items) (message "End of history; no default available"))
          (else
            (when (= *mb-history-pos* -1) (set! *mb-history-input* (minibuffer-input)))
            (let ((next (+ *mb-history-pos* delta)))
              (cond ((< next -1) (message "End of history; no default available"))
                    ((>= next (length items)) (message "End of history; no default available"))
                    (else
                      (set! *mb-history-pos* next)
                      (minibuffer-input!
                        (if (= next -1) *mb-history-input* (nth next items))))))))))

(define-command "previous-history-element" "Put the previous history item in the minibuffer"
  (lambda () (minibuffer-history-step! 1)))
(define-command "next-history-element" "Put the next history item in the minibuffer"
  (lambda () (minibuffer-history-step! -1)))

;; y-or-n?: a question that takes ONE key. "y" runs YES, "n" and C-g
;; run NO, and any other key clears the input, so the question stands
;; until it gets an answer. A question is not a completion prompt: it
;; offers no candidates, so it stays on the bottom bar and it never
;; grows a palette of two words.
;; (read-char-choice PROMPT CHARS K): one key from CHARS, a list of
;; one-character strings; K gets the character. Any other key asks again.
;; C-g cancels and K gets #f.
;; (read-char PROMPT K): the next key, whatever it is; K gets the
;; character, or #f on C-g. A register name is read this way.
(define (read-char prompt k)
  (let ((answer (lambda (ch) (minibuffer-detach!) (k ch))))
    (minibuffer-read* prompt '()
      (list (list 'change
              (lambda (input)
                (when (> (string-length input) 0)
                  (answer (substring input (- (string-length input) 1)
                                     (string-length input))))))
            (list 'confirm (lambda (v) (answer (if (equal? v "") "RET" v))))
            (list 'cancel (lambda () (k #f)))
            (list 'style "question")))))

(define (read-char-choice prompt chars k)
  (let ((answer (lambda (ch) (minibuffer-detach!) (k ch))))
    (minibuffer-read* prompt '()
      (list (list 'change
              (lambda (input)
                (let ((ch (if (> (string-length input) 0)
                              (substring input (- (string-length input) 1) (string-length input))
                              "")))
                  (if (member ch chars)
                      (answer ch)
                      (minibuffer-input! "")))))
            (list 'confirm (lambda (v) (read-char-choice prompt chars k)))
            (list 'cancel (lambda () (k #f)))
            (list 'style "question")))))

;; the Emacs names: K gets #t or #f
(define (y-or-n? prompt k)
  (y-or-n prompt (lambda () (k #t)) (lambda () (k #f))))

;; a question that takes the word: "yes" or "no", RET after it
(define (yes-or-no? prompt k)
  (minibuffer-read* (string-append prompt " (yes or no) ") '()
    (list (list 'confirm
            (lambda (v)
              (cond ((equal? v "yes") (k #t))
                    ((equal? v "no") (k #f))
                    (else (message "Please answer yes or no.")
                          (yes-or-no? prompt k)))))
          (list 'cancel (lambda () (k #f)))
          (list 'style "question"))))

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
(define *mb-shortcuts* '())

(define (mb-candidate-name cand)
  (if (pair? cand) (car cand) cand))

(define (mb-shortcut-command key)
  (let ((name (string-append "minibuffer-shortcut-" key)))
    (define-command name (string-append "Choose minibuffer shortcut M-" key)
      (lambda ()
        (let ((hit (assoc key *mb-shortcuts*)))
          (cond (hit ((car (cdr hit))))
                ((equal? key "g") (run-command "minibuffer-regroup"))
                ((equal? key "p") (run-command "minibuffer-previous-section"))
                ((equal? key "n") (run-command "minibuffer-next-section"))
                (else #f)))))
    name))

(define (mb-preview-shortcut-rows cands declared)
  (if declared
    declared
    (let loop ((xs cands) (n 1) (out '()))
      (if (or (null? xs) (> n 9))
        (reverse out)
        (loop (cdr xs) (+ n 1)
              (cons (list (number->string n)
                          (mb-candidate-name (car xs)))
                    out))))))

(define (mb-preview-shortcuts rows on-confirm)
  (map (lambda (row)
         (let ((key (car row)) (value (car (cdr row))))
           (list key
                 (lambda ()
                   (set! *mb-shortcuts* '())
                   (minibuffer-cancel!)
                   (with-invoking-buffer (lambda () (on-confirm value)))))))
       rows))

(define (mb-preview-shortcut-hint cands shortcuts)
  (map (lambda (cand)
         (let* ((name (mb-candidate-name cand))
                (hit (let loop ((xs shortcuts))
                       (cond ((null? xs) #f)
                             ((equal? name (car (cdr (car xs)))) (car (car xs)))
                             (else (loop (cdr xs)))))))
           (if (and hit (pair? cand))
             (list name (string-append "M-" hit "  " (car (cdr cand))))
             cand)))
       cands))

(define (minibuffer-read-preview prompt cands on-select on-confirm on-cancel
                                 &optional match-hint style complete collect shortcuts)
  ;; the outer prompt's cancel handler clears *mb-select-fn*, so let it run
  ;; BEFORE this prompt installs its own. minibuffer-read* would quit the
  ;; outer prompt for us, but by then the new hook is already in place and
  ;; the old prompt's teardown takes it away: the new prompt opens with no
  ;; preview and no rail, which is the bug this line prevents.
  (when (minibuffer-active?)
    (minibuffer-cancel!)
    (message "Quit the outer prompt"))
  (let* ((rows (mb-preview-shortcut-rows cands shortcuts))
         (bindings (mb-preview-shortcuts rows on-confirm)))
    (set! *mb-shortcuts* bindings)
    (set! *mb-select-fn* (lambda (sel) (with-invoking-buffer (lambda () (on-select sel)))))
    (minibuffer-read* prompt (mb-preview-shortcut-hint cands rows)
      (append
        (list (list 'confirm (lambda (v)
                                (set! *mb-shortcuts* '())
                                (set! *mb-select-fn* #f)
                                (with-invoking-buffer (lambda () (on-confirm v)))))
              (list 'cancel  (lambda ()
                                (set! *mb-shortcuts* '())
                                (set! *mb-select-fn* #f)
                                (with-invoking-buffer on-cancel)))
              (list 'change  (lambda (input) (mb-select-notify!)))
              (list 'match-hint (if match-hint match-hint #f))
              (list 'style style))
        (if complete (list (list 'complete complete)) '())
        (if collect (list (list 'collect collect)) '())))))

;;; --- hooks (Emacs-style, all Scheme) ----------------------------------------
;;; A hook is a name and a list of functions. add-hook! puts a function on
;;; the list once. Give it the NAME of a function, quoted: the name is
;;; looked up when the hook runs, so a reload that redefines the function
;;; changes what runs, and adding the name again is a no-op. A closure is
;;; a fresh value after every reload, so a closure is added again each
;;; time the file loads; prefer the name.
;;;
;;; A hook with LOCAL set lives on the current buffer, and runs before
;;; the global list. run-hooks calls with no arguments; the
;;; run-hook-with-args family carries arguments and stops on the first
;;; success or the first failure, as in Emacs.
;;;
;;; A KEYED hook holds one function per key: (add-hook! '(block-click
;;; diff) FN) puts FN under the key diff, and the same key replaces, so a
;;; package reload does not stack a second copy. (hook-functions
;;; 'block-click) is the plain list and then every keyed function, newest
;;; key first; (hook-functions '(block-click diff)) is that one function,
;;; so a dispatcher runs one key or all of them with the same run-hook
;;; call. (hook-keys 'block-click) names the keys.

(define *hooks* '())                    ; ((HOOK FN ...) ...)
(define *local-hooks* '())              ; ((BUFFER (HOOK FN ...) ...) ...)
(define *keyed-hooks* '())              ; ((HOOK ((KEY FN) ...)) ...)

(define (hook--alist-get alist key)
  (let ((e (assoc key alist))) (if e (cdr e) '())))

(define (hook--alist-put alist key value)
  (cons (cons key value)
        (filter (lambda (e) (not (equal? (car e) key))) alist)))

(define (hook--global hook) (hook--alist-get *hooks* hook))

(define (hook--set-global! hook fns)
  (set! *hooks* (hook--alist-put *hooks* hook fns)))

(define (hook--local buf hook)
  (hook--alist-get (hook--alist-get *local-hooks* buf) hook))

(define (hook--set-local! buf hook fns)
  (set! *local-hooks*
    (hook--alist-put *local-hooks* buf
      (hook--alist-put (hook--alist-get *local-hooks* buf) hook fns))))

;; a name resolves when the hook runs; an unbound name runs nothing
(define (hook--fn f)
  (cond ((procedure? f) f)
        ((symbol? f) (and (boundp f) (symbol-value f)))
        ((string? f) (hook--fn (string->symbol f)))
        (else #f)))

(define (hook--add fns fn at-end)
  (cond ((member fn fns) fns)
        (at-end (append fns (list fn)))
        (else (cons fn fns))))

(define (hook--remove fns fn)
  (filter (lambda (f) (not (equal? f fn))) fns))

(define (hook--keyed hook) (or (alist-get *keyed-hooks* hook) '()))

(define (hook--set-keyed! hook entries)
  (set! *keyed-hooks* (alist-put *keyed-hooks* hook entries)))

(define (hook-keys hook) (map car (hook--keyed hook)))

(define (add-hook! hook fn &optional at-end local)
  (cond ((pair? hook)
         (hook--set-keyed! (car hook) (alist-put (hook--keyed (car hook)) (cadr hook) fn)))
        (local
         (let ((buf (current-buffer)))
           (hook--set-local! buf hook (hook--add (hook--local buf hook) fn at-end))))
        (else (hook--set-global! hook (hook--add (hook--global hook) fn at-end))))
  fn)

;; a keyed hook needs no FN: the key names what goes
(define (remove-hook! hook &optional fn local)
  (cond ((pair? hook)
         (hook--set-keyed! (car hook) (alist-delete (hook--keyed (car hook)) (cadr hook))))
        (local
         (let ((buf (current-buffer)))
           (hook--set-local! buf hook (hook--remove (hook--local buf hook) fn))))
        (else (hook--set-global! hook (hook--remove (hook--global hook) fn))))
  fn)

;; the functions HOOK runs, in order: the current buffer's, the global,
;; then the keyed; a keyed name answers with its one function
(define (hook-functions hook)
  (if (pair? hook)
      (let ((fn (alist-get (hook--keyed (car hook)) (cadr hook))))
        (if fn (list fn) '()))
      (append (hook--local (current-buffer) hook) (hook--global hook)
              (map cadr (hook--keyed hook)))))

(define (run-hook-with-args hook &rest args)
  (for-each (lambda (f)
              (let ((p (hook--fn f)))
                (when p (apply p args))))
            (hook-functions hook))
  #f)

(define (run-hooks &rest hooks)
  (for-each (lambda (h) (run-hook-with-args h)) hooks))

;; the first function that answers a true value ends the run
(define (run-hook-with-args-until-success hook &rest args)
  (let loop ((fs (hook-functions hook)))
    (if (null? fs)
        #f
        (let* ((p (hook--fn (car fs)))
               (v (and p (apply p args))))
          (if v v (loop (cdr fs)))))))

;; the first function that answers #f ends the run
(define (run-hook-with-args-until-failure hook &rest args)
  (let loop ((fs (hook-functions hook)))
    (if (null? fs)
        #t
        (let* ((p (hook--fn (car fs)))
               (v (if p (apply p args) #t)))
          (if v (loop (cdr fs)) #f)))))

;; a client attached a frame: the Elixir side built it fresh, so anything
;; a frame CARRIES for display — the group it stands in, and whatever a
;; package adds later — has to be pushed out again. The client calls this
;; once per mount, inside that frame's input context.
(define (frame-attached!)
  (run-hooks 'frame-attach-hook))

;; a frame's client left and did not come back within the grace the
;; editor keeps: the browser tab is closed. Emacs deletes the frame of a
;; display that is gone; so does this. The sole frame stays. The hook
;; runs first, with the id, so a package can drop what it keeps per frame.
(define (frame-client-lost! id)
  (when (and (member id (frame-list)) (> (length (frame-list)) 1))
    (run-hook-with-args 'frame-delete-hook id)
    (delete-frame! id)))

;;; --- the older spellings -------------------------------------------------------
;;; A package outside the repo (the user's own, another checkout) may name a
;;; door by the name it had before the keyed hooks. Each old name is one
;;; line over the new one, so such a package boots; new code uses the new
;;; name, and the catalog lists only that one.

(define (on-block-click! name fn) (add-hook! (list 'block-click name) fn))
(define (on-preview-link! verb fn) (add-hook! (list 'preview-link verb) fn))
(define (on-endpoint-event! name fn) (add-hook! (list 'endpoint-event name) fn))
(define (on-lsp-event! name fn) (add-hook! (list 'lsp-event name) fn))
(define (on-agent-turn-end! name fn) (add-hook! (list 'agent-turn-end name) fn))
(define (on-input-intent! type fn) (add-hook! (list 'input-intent type) fn))
(define (on-fs-change! fn) (add-hook! 'fs-change-hook fn))
(define (on-buffer-created! fn) (add-hook! 'buffer-created-hook fn))
(define (on-buffer-woken! fn) (add-hook! 'buffer-woken-hook fn))
(define (on-buffer-shown! fn) (add-hook! 'buffer-shown-hook fn))
(define (on-buffer-renamed! fn) (add-hook! 'buffer-renamed-hook fn))
(define (take-n lst n) (take lst n))

;; The first element of LST that PRED holds for, or #f: SRFI-1 find.
(define (find pred lst)
  (cond ((null? lst) #f)
        ((pred (car lst)) (car lst))
        (else (find pred (cdr lst)))))

;; A whole number from 0 up to N, not N. A generator seeded from the clock:
;; enough to pick a file or a row at random, not for secrets. The editor had
;; no random at all, and a model asked to "open a random file" invented one.
(define *random-state* (+ (* 1000 (current-time)) (monotonic-ms)))
(define (random n)
  (set! *random-state*
        (modulo (+ (* *random-state* 6364136223846793005) 1442695040888963407)
                18446744073709551616))
  (modulo (quotient *random-state* 65536) n))

;;; --- variables: a default and a buffer-local value --------------------------
;;; Emacs gives a variable one default and, in a buffer that set it, a
;;; local value. Here a global is a Scheme binding and a buffer-local is a
;;; key in the buffer; these forms tie the two together. variable-value
;;; reads the buffer's value when it has one, else the default, and
;;; variable-set! writes locally when the variable is automatically
;;; buffer-local (defvar-local) and globally otherwise.

(define *automatically-local* '())
(define *variable-docs* '())

(define (variable-doc! name doc)
  (set! *variable-docs* (hook--alist-put *variable-docs* name (list doc)))
  name)

(define (variable-doc name)
  (let ((e (assoc name *variable-docs*))) (and e (cadr e))))

;; (defvar NAME DEFAULT [DOC] ['persist #t]): NAME takes DEFAULT unless it
;; is bound already, as in Emacs; a reload keeps the value a session set.
;; 'persist #t makes the value ride in the desktop under NAME without its
;; stars: a restore puts the saved value back, or DEFAULT when the file
;; holds none (see the savehist section).
(define (defvar name default &rest opts)
  (let ((doc (if (and (pair? opts) (string? (car opts))) (car opts) (plist-get opts 'doc)))
        (persist (plist-get opts 'persist)))
    (unless (boundp name) (set-symbol-value! name default))
    (when doc (variable-doc! name doc))
    (when persist
      (persist-global! (defvar--key name)
        (lambda () (symbol-value name))
        (lambda (v) (set-symbol-value! name (if (equal? v #f) default v)))))
    name))

;; the desktop key of a variable: *peek-recent* rides as peek-recent
(define (defvar--key name)
  (string->symbol
    (string-join (filter (lambda (s) (not (equal? s "")))
                         (string-split (symbol->string name) "*"))
                 "*")))

(define (make-variable-buffer-local! name)
  (unless (member name *automatically-local*)
    (set! *automatically-local* (cons name *automatically-local*)))
  name)

(define (automatically-local? name)
  (and (member name *automatically-local*) #t))

(define (defvar-local name default &optional doc)
  (defvar name default doc)
  (make-variable-buffer-local! name))

(define (default-value name)
  (and (boundp name) (symbol-value name)))

(define (set-default! name value)
  (set-symbol-value! name value)
  value)

;; #t when BUF holds its own value for NAME. A local set to #f reads as
;; absent, as buffer-local answers #f for both.
(define (local-variable-p name &optional buf)
  (let ((e (assoc name (buffer-locals (or buf (current-buffer))))))
    (and e (cadr e) #t)))

(define (buffer-local-value name &optional buf)
  (let* ((b (or buf (current-buffer)))
         (v (buffer-local b name)))
    (if v v (default-value name))))

(define (setq-local! name value)
  (buffer-set-local! (current-buffer) name value)
  value)

(define (kill-local-variable! name &optional buf)
  (buffer-set-local! (or buf (current-buffer)) name #f)
  name)

;; the Emacs variable reference and assignment
(define (variable-value name) (buffer-local-value name))

(define (variable-set! name value)
  (if (automatically-local? name)
      (setq-local! name value)
      (set-default! name value)))

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
;;; Elixir holds ONE handler (fs-on-change!) and this dispatcher fans it
;;; out over fs-change-hook, whose functions take the root. Keep the handlers small: they schedule a
;;; refresh, they do not do the work. Watch debounces, but a slow handler
;;; still runs once per burst per root.

;; fs-change-hook: (FN ROOT)
(fs-on-change!
  (lambda (root) (run-hook-with-args 'fs-change-hook root)))

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

;; Packages can attach a face to a candidate label through the keyed hook
;; (candidate-face KEY): the first answer wins, none means no face. The
;; candidate renderer carries the face without knowing why that name has
;; that color.
(define (candidate-face-for category name)
  (run-hook-with-args-until-success 'candidate-face category name))

;; the annotator of CATEGORY is the keyed hook (marginalia CATEGORY)
(define (marginalia! category fn) (add-hook! (list 'marginalia category) fn))

(define (marginalia-for category)
  (let ((fs (hook-functions (list 'marginalia category))))
    (and (pair? fs) (car fs))))

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

;;; --- connections --------------------------------------------------------------
;;; conn-list, conn-detail and conn-log answer for every connection kind
;;; (mcp, lsp, endpoint, web-server, db) with plists. The package of a kind
;;; picks the fields that its rows show.

(domain! 'system)
(effects! '(read))

(define (conn-rows kind fields)
  (map (lambda (c) (map (lambda (f) (plist-get c f)) fields))
       (conn-list kind)))

(public! 'conn-list
  "(conn-list KIND) — one plist per connection of KIND: 'mcp, 'lsp, 'endpoint, 'web-server or 'db")
(public! 'conn-detail
  "(conn-detail KIND NAME) — the status plist of one connection, or #f when it never started")
(public! 'conn-log
  "(conn-log KIND NAME) — the frames both ways as ((time dir text) ...), oldest first; read this when a connection will not start")
(public! 'conn-rows
  "(conn-rows KIND FIELDS) — return one list of the FIELDS values per connection of KIND")
(public! 'on-event!
  "(on-event! KIND HANDLER) — set the ONE handler for events of KIND; the package of KIND owns the slot")
(catalog-meta! 'function "on-event!" 'effects '(write))

;;; --- hot reload -------------------------------------------------------------
;;; A save reloads that file's changed top-level forms into this session.
;;; A new definition alone does not reach a buffer that is already open:
;;; the mode setup fn installed the old keys, overlays and folds, and
;;; nothing re-runs it. That is the one reason a mode change used to need
;;; a restart.
;;;
;;; Session.reload_files/1 brackets every reload with these two fns.
;;; reload-begin! opens a record. define-mode writes its name into it. reload-finish! re-runs setup on every live
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

(domain! 'unknown)
(effects! '(unknown))

;;; --- keymaps ------------------------------------------------------------------
;;; Keymaps are Scheme data. A keymap is a name, its own bindings and a
;;; parent. A binding maps a key sequence (a list of key strings) to a
;;; command name, or to (keymap NAME): a prefix key that leads to that
;;; keymap, as C-x leads to ctl-x-map in Emacs. A buffer's own map is the
;;; keymap named after the buffer; use-local-map! gives it the mode's map
;;; as its parent. A key resolves down this ladder:
;;;
;;;   the frame's overriding map (Transient, the prefix argument's map);
;;;     locked, an unbound key is undefined
;;;   the keymap of the thing at point (a block)
;;;   the buffer's minor-mode maps, first wins
;;;   the global minor-mode maps (cua-mode)
;;;   the buffer's own map, then its parents
;;;   the read-only map, when the buffer is read-only
;;;   the global map
;;;
;;; An exact hit anywhere wins over a prefix anywhere: Emacs's
;;; minor-mode-map-alist, local map and global map, in that order.
;;; Elixir keeps one call: the dispatcher asks key-binding-dispatch for a
;;; sequence and acts on the answer; the frame's overriding map and the
;;; pending prefix are dispatch state and stay with the frame.

(domain! 'keys)
(effects! '(write))

(define *keymaps* '())                 ; NAME -> (BINDINGS PARENT)
;; NAME -> (PREFIXES LEADS): every proper prefix of a bound key, and the
;; bindings whose value is a keymap, longest key first. Built on the
;; first lookup after a change, so a key resolves with builtins alone.
(define *keymap-index* '())
(define *global-minor-maps* '())
(define *buffer-key-facts* '())        ; BUF -> (minor-maps LIST at-point-map NAME remaps ALIST)
(define keymap--minibuf " *minibuf*")
(define keymap--read-only " *read-only*")

;; any frame's minibuffer buffer shares one local keymap
(define (keymap--key name)
  (let ((n (if (symbol? name) (symbol->string name) name)))
    (if (and (string? n) (string-prefix? " *minibuf" n)) keymap--minibuf n)))

(define (keymap--seq seq)
  (cond ((string? seq) (filter (lambda (k) (not (equal? k ""))) (string-split seq " ")))
        ((null? seq) '())
        ((pair? seq) (map (lambda (k) (if (symbol? k) (symbol->string k) k)) seq))
        ((symbol? seq) (list (symbol->string seq)))
        (else (list seq))))

;; a binding's value: a command name, or (keymap NAME)
(define (keymap--prefix-value? v) (and (pair? v) (equal? (car v) 'keymap)))
(define (keymap--value v)
  (if (keymap--prefix-value? v) (list 'keymap (keymap--key (cadr v))) v))

(define (keymap--entry name) (alist-get *keymaps* (keymap--key name)))

;; every write bumps the generation; a cached ladder is good while it holds
(define *keymap-generation* 0)
(define *keymap-memo* '())              ; (BUF OVER SEQ GENERATION) -> answer
(define *keymap-flat* '())              ; KEY -> (GENERATION ROWS INDEX)
(define *keymap-ladders* '())          ; BUF -> (GENERATION READ-ONLY? LADDER)
(define (keymap--changed!)
  (set! *keymap-generation* (+ *keymap-generation* 1))
  (set! *keymap-ladders* '())
  (set! *keymap-memo* '())
  (set! *keymap-flat* '()))

(define (keymap--put! name bindings parent)
  (keymap--changed!)
  (set! *keymap-index* (alist-delete *keymap-index* (keymap--key name)))
  (set! *keymaps* (alist-put *keymaps* (keymap--key name) (list bindings parent))))

;; the proper prefixes of KEYS: (C-x 4 f) has (C-x) and (C-x 4)
(define (keymap--prefixes-of keys)
  (let loop ((n 1) (out '()))
    (if (>= n (length keys)) out (loop (+ n 1) (cons (take keys n) out)))))

(define (keymap--index name)
  (let ((key (keymap--key name)))
    (or (alist-get *keymap-index* key)
        (let* ((bindings (keymap--bindings key))
               (prefixes (fold (lambda (acc e) (append (keymap--prefixes-of (car e)) acc)) '() bindings))
               (leads (keymap--by-length-desc
                        (filter (lambda (e) (keymap--prefix-value? (cadr e))) bindings)))
               (index (list prefixes leads)))
          (set! *keymap-index* (alist-put *keymap-index* key index))
          index))))

(define (keymap--bindings name)
  (let ((e (keymap--entry name))) (if e (car e) '())))

(define (keymap--update! name fn)
  (let* ((e (or (keymap--entry name) (list '() #f))))
    (keymap--put! name (fn (car e)) (cadr e))))

;; NAME's bindings and its parents', nearest first; a parent loop ends
(define (keymap--chain name)
  (let loop ((n (and name (keymap--key name))) (seen '()) (acc '()))
    (let ((e (and n (not (member n seen)) (keymap--entry n))))
      (if (not e)
          (reverse acc)
          (loop (cadr e) (cons n seen) (cons (list n (car e)) acc))))))

(define (keymap--facts buf) (or (alist-get *buffer-key-facts* (keymap--key buf)) '()))
(define (keymap--fact buf key)
  (let ((f (keymap--facts buf))) (and (pair? f) (plist-get f key))))
(define (keymap--fact! buf key val)
  (keymap--changed!)
  (set! *buffer-key-facts*
    (alist-put *buffer-key-facts* (keymap--key buf) (plist-put (keymap--facts buf) key val))))

;; the (NAME BINDINGS) that answer for BUF, in precedence order; the
;; ladder is kept per buffer until the next keymap write
(define (keymap--ladder buf read-only?)
  (let* ((key (keymap--key buf))
         (kept (alist-get *keymap-ladders* key)))
    (if (and kept (equal? (car kept) *keymap-generation*) (equal? (cadr kept) read-only?))
        (caddr kept)
        (let* ((minor (append (or (keymap--fact buf 'minor-maps) '()) *global-minor-maps*))
               (at (keymap--fact buf 'at-point-map))
               (ladder (append (if at (keymap--chain at) '())
                               (apply append (map keymap--chain minor))
                               (keymap--chain key)
                               (if read-only? (keymap--chain keymap--read-only) '())
                               (keymap--chain "global"))))
          (set! *keymap-ladders*
            (alist-put *keymap-ladders* key (list *keymap-generation* read-only? ladder)))
          ladder))))

;; SEQ is a proper prefix of KEYS
(define (keymap--proper-prefix? seq keys)
  (and (< (length seq) (length keys)) (equal? seq (take keys (length seq)))))

;; (NAME VALUE) of the exact binding for SEQ, nearest map first, or #f
(define (keymap--exact ladder seq)
  (let loop ((ms ladder))
    (if (null? ms)
        #f
        (let ((hit (assoc seq (cadr (car ms)))))
          (if hit (list (car (car ms)) (cadr hit)) (loop (cdr ms)))))))

;; longest key first
(define (keymap--by-length-desc entries)
  (let loop ((rest entries) (out '()))
    (if (null? rest)
        out
        (loop (cdr rest)
              (let ins ((ys out))
                (cond ((null? ys) (list (car rest)))
                      ((> (length (car (car rest))) (length (car (car ys)))) (cons (car rest) ys))
                      (else (cons (car ys) (ins (cdr ys))))))))))

;; (command NAME MAP), prefix, or none
(define (keymap--resolve ladder seq)
  (let ((exact (keymap--exact ladder seq)))
    (cond ((and exact (keymap--prefix-value? (cadr exact))) 'prefix)
          (exact (list 'command (cadr exact) (car exact)))
          (else (keymap--resolve-through ladder seq)))))

;; the keymap-valued bindings whose key is a proper prefix of SEQ, nearest
;; map first, longest key first; the rest of SEQ resolves in that keymap
(define (keymap--resolve-through ladder seq)
  (if (null? seq)
      ;; the empty sequence is a prefix of every binding
      (if (let loop ((ms ladder)) (and (pair? ms) (or (pair? (cadr (car ms))) (loop (cdr ms)))))
          'prefix
          'none)
      (keymap--resolve-through* ladder seq)))

(define (keymap--resolve-through* ladder seq)
  (let ((hit
          (let loop ((ms ladder))
            (if (null? ms)
                #f
                (let ((found
                        (let try ((ps (cadr (keymap--index (car (car ms))))))
                          (cond ((null? ps) #f)
                                ((not (keymap--proper-prefix? (car (car ps)) seq)) (try (cdr ps)))
                                (else
                                  (let ((r (keymap--resolve
                                             (keymap--chain (cadr (cadr (car ps))))
                                             (list-tail seq (length (car (car ps)))))))
                                    (if (equal? r 'none) (try (cdr ps)) r)))))))
                  (or found (loop (cdr ms))))))))
    (cond (hit hit)
          ((let loop ((ms ladder))
             (and (pair? ms)
                  (or (and (member seq (car (keymap--index (car (car ms))))) #t)
                      (loop (cdr ms)))))
           'prefix)
          (else 'none))))

;; every binding reachable from BINDINGS, the keys of a prefix keymap
;; joined under their prefix: what describe-bindings and where-is see.
;; Rows are (KEYS VALUE), KEYS a list; a prefix keymap's own row carries
;; "keymap:NAME".
(define (keymap--flatten bindings &optional prefix seen)
  (let ((prefix (or prefix '())) (seen (or seen '())))
    (apply append
      (map (lambda (e)
             (let ((keys (append prefix (car e))) (v (cadr e)))
               (if (keymap--prefix-value? v)
                   (let ((m (cadr v)))
                     (if (member m seen)
                         '()
                         (cons (list keys (string-append "keymap:" m))
                               (apply append
                                 (map (lambda (nb) (keymap--flatten (cadr nb) keys (cons m seen)))
                                      (keymap--chain m))))))
                   (list (list keys v)))))
           bindings))))

;; the buffer's command remaps applied to a resolved command (Emacs
;; [remap COMMAND]): every key bound to FROM runs TO in this buffer
(define (keymap--remap buf name)
  (let ((r (assoc name (or (keymap--fact buf 'remaps) '()))))
    (if r (cadr r) name)))

(define (keymap--read-only-hit? buf seq)
  (and (or (assoc seq (keymap--bindings keymap--read-only))
           (member seq (car (keymap--index keymap--read-only))))
       (buffer-exists? buf)
       (buffer-read-only? buf)))

;; the buffer a key acts on: the frame's minibuffer while a prompt is
;; up, else the buffer of the selected window. Not the current buffer:
;; an eval runs in a context buffer of its own, and a key never does.
;; key-context answers it with the overriding map in one editor call.
(define (keymap--frame-buffer) (car (key-context)))

;; the frame's ladder for SEQ: the overriding map OVER ((KEYMAP LOCK?) or
;; #f) first, and alone when it is locked
(define (keymap--frame-ladder buf over seq)
  (let ((base (lambda () (keymap--ladder buf (keymap--read-only-hit? buf seq)))))
    (cond ((not over) (base))
          ((cadr over) (keymap--chain (car over)))
          (else (append (keymap--chain (car over)) (base))))))

;; a resolved sequence is kept per buffer, overriding map and keymap
;; generation: the second press of a key is one table hit
(define (keymap--lookup-here seq)
  ;; a buffer whose mode setup never ran in this daemon run has none of
  ;; its keys: run the restore first, so the lookup reads its maps
  (let ((owed (car (key-context))))
    (when (runtime-owed? owed) (restore-buffer-runtime! owed)))
  (let* ((ctx (key-context))
         (buf (car ctx))
         (memo-key (list (keymap--key buf) (cadr ctx) seq *keymap-generation*))
         (kept (assoc memo-key *keymap-memo*)))
    (if kept
        (cadr kept)
        (let* ((r (keymap--resolve (keymap--frame-ladder buf (cadr ctx) seq) seq))
               (answer (if (and (pair? r) (equal? (car r) 'command))
                           (list 'command (keymap--remap buf (cadr r)) (caddr r))
                           r)))
          ;; a bounded memo: the newest 400 answers
          (set! *keymap-memo* (take (cons (list memo-key answer) *keymap-memo*) 400))
          answer))))

;; modifier order in a key spec: s- C- M- BASE
(define (keymap--add-meta key)
  (let* ((sup (if (string-prefix? "s-" key) "s-" ""))
         (k1 (if (equal? sup "") key (substring key 2 (string-length key))))
         (ctl (if (string-prefix? "C-" k1) "C-" ""))
         (k2 (if (equal? ctl "") k1 (substring k1 2 (string-length k1)))))
    (if (string-prefix? "M-" k2) key (string-append sup ctl "M-" k2))))

;; ESC is Meta when nothing binds it directly (Emacs: ESC x runs M-x): a
;; sequence ending in ESC k asks again for M-k
(define (keymap--esc-meta seq)
  (let ((r (reverse seq)))
    (and (pair? r) (pair? (cdr r)) (equal? (cadr r) "ESC")
         (not (equal? (car r) "ESC"))
         (reverse (cons (keymap--add-meta (car r)) (cddr r))))))

(effects! '(read))
(public! 'key-binding-dispatch
  "(key-binding-dispatch SEQ) — the dispatcher's one lookup: (\"command\" NAME), (\"prefix\") or (\"none\") for the key sequence SEQ in the frame's buffer, ESC read as Meta when nothing binds it")
(define (key-binding-dispatch seq)
  (let* ((seq (keymap--seq seq))
         (answer (lambda (r)
                   (cond ((equal? r 'prefix) (list "prefix"))
                         ((and (pair? r) (equal? (car r) 'command)) (list "command" (cadr r)))
                         (else (list "none")))))
         (r (keymap--lookup-here seq)))
    (cond ((not (equal? r 'none)) (answer r))
          ((and (pair? seq) (equal? (car (reverse seq)) "ESC")) (list "prefix"))
          ((keymap--esc-meta seq) (answer (keymap--lookup-here (keymap--esc-meta seq))))
          (else (list "none")))))

(public! 'key-binding
  "(key-binding SEQ) — the command SEQ runs in this buffer: a name, 'prefix, or #f. SEQ is a list of keys or a string.")
(define (key-binding seq)
  (let ((r (keymap--lookup-here (keymap--seq seq))))
    (cond ((equal? r 'prefix) 'prefix)
          ((and (pair? r) (equal? (car r) 'command)) (cadr r))
          (else #f))))

(public! 'key-binding-source
  "(key-binding-source SEQ) — (COMMAND KEYMAP-NAME) for the binding SEQ resolves to here, 'prefix, or #f.")
(define (key-binding-source seq)
  (let ((r (keymap--lookup-here (keymap--seq seq))))
    (cond ((equal? r 'prefix) 'prefix)
          ((and (pair? r) (equal? (car r) 'command)) (list (cadr r) (caddr r)))
          (else #f))))

(public! 'keymap-lookup
  "(keymap-lookup KEYMAP SEQ) — what SEQ means in the named keymap and its parents: a name, 'prefix, or #f.")
(define (keymap-lookup name seq)
  (let ((r (keymap--resolve (keymap--chain name) (keymap--seq seq))))
    (cond ((equal? r 'prefix) 'prefix)
          ((and (pair? r) (equal? (car r) 'command)) (cadr r))
          (else #f))))

;;; --- the which-key rows: what a pending prefix can still become ---------------

(define keymap--modifier-order '("C" "M" "S" "s"))
(define keymap--shifted-printable
  '("!" "@" "#" "$" "%" "^" "&" "*" "(" ")" "_" "+" "{" "}" "|" ":" "\"" "<" ">" "?" "~"))

;; (MODIFIERS BASE): the explicit X- modifiers of KEY, and Shift when the
;; base is a shifted printable or an upper-case letter
(define (keymap--modifiers key)
  (let loop ((k key) (found '()))
    (if (and (>= (string-length k) 2)
             (equal? (substring k 1 2) "-")
             (member (substring k 0 1) keymap--modifier-order))
        (loop (substring k 2 (string-length k)) (cons (substring k 0 1) found))
        (let* ((shifted (and (= (string-length k) 1)
                             (or (member k keymap--shifted-printable)
                                 (not (equal? (string-downcase k) k)))))
               (mods (if shifted (cons "S" found) found)))
          (list (filter (lambda (m) (member m mods)) keymap--modifier-order) k)))))

(define (keymap--modifier-label mods)
  (if (null? mods)
      "Unmodified"
      (string-join (map (lambda (m)
                          (cond ((equal? m "C") "Control")
                                ((equal? m "M") "Meta")
                                ((equal? m "S") "Shift")
                                (else "Super")))
                        mods)
                   " + ")))

(public! 'which-key-rows
  "(which-key-rows PENDING) — the keys the pending prefix PENDING can still complete to, as (KEY COMMAND MODIFIERS MODIFIER-LABEL) rows, unmodified keys first")
(define (which-key-rows pending)
  (let* ((pending (keymap--seq pending))
         (buf (keymap--frame-buffer))
         (rows (car (keymap--flat buf)))
         (under (filter (lambda (r) (keymap--proper-prefix? pending (car r))) rows))
         (items (map (lambda (r)
                       (let* ((keys (list-tail (car r) (length pending)))
                              (mb (keymap--modifiers (car keys)))
                              (mods (car mb)))
                         (list (string-join keys " ") (cadr r) mods (keymap--modifier-label mods)
                               ;; the sort key: unmodified first, then the label, then the base
                               (list (if (null? mods) 0 1) (keymap--modifier-label mods)
                                     (cons (string-downcase (cadr mb)) (cdr keys))
                                     (string-join keys " ")))))
                     under))
         (unique (let loop ((is items) (seen '()) (out '()))
                   (cond ((null? is) (reverse out))
                         ((member (car (car is)) seen) (loop (cdr is) seen out))
                         (else (loop (cdr is) (cons (car (car is)) seen) (cons (car is) out))))))
         (ordered (map cadr (sort (map (lambda (i) (list (list-ref i 4) i)) unique)))))
    (map (lambda (i) (take i 4)) ordered)))

;;; --- the API packages write keys with -----------------------------------------

(effects! '(write))
(public! 'define-keymap!
  "(define-keymap! NAME [PARENT]) — a named keymap; PARENT answers the keys NAME does not bind. A buffer's own map is the keymap named after the buffer.")
(define (define-keymap! name &optional parent)
  (let ((e (keymap--entry name)))
    (keymap--put! name (if e (car e) '())
                  (cond (parent (keymap--key parent))
                        (e (cadr e))
                        (else #f)))
    (keymap--key name)))

(public! 'define-key
  "(define-key KEYMAP SEQ COMMAND) — bind SEQ to COMMAND in the named keymap. COMMAND may be (keymap NAME): SEQ is then a prefix key that leads to that keymap.")
(define (define-key name seq command)
  (keymap--update! name (lambda (b) (alist-put b (keymap--seq seq) (keymap--value command)))))

(public! 'keymap-unset!
  "(keymap-unset! KEYMAP SEQ) — drop the named keymap's own binding for SEQ.")
(define (keymap-unset! name seq)
  (keymap--update! name (lambda (b) (alist-delete b (keymap--seq seq)))))

(public! 'keymap-parent!
  "(keymap-parent! KEYMAP PARENT) — PARENT (or #f) answers the keys KEYMAP does not bind.")
(define (keymap-parent! name parent)
  (let ((e (or (keymap--entry name) (list '() #f))))
    (keymap--put! name (car e) (and parent (keymap--key parent)))))

(effects! '(read))
(public! 'keymap-parent "(keymap-parent KEYMAP) — the parent's name, or #f.")
(define (keymap-parent name)
  (let ((e (keymap--entry name))) (and e (cadr e))))

(public! 'keymap-bindings
  "(keymap-bindings KEYMAP) — ((KEYS COMMAND) ...), the keymap's own bindings, KEYS as one string; a prefix key's COMMAND reads \"keymap:NAME\".")
(define (keymap-bindings name)
  (keymap--rows
    (map (lambda (e)
           (list (car e)
                 (if (keymap--prefix-value? (cadr e))
                     (string-append "keymap:" (cadr (cadr e)))
                     (cadr e))))
         (keymap--bindings name))))

(public! 'keymap-names "(keymap-names) — every keymap the editor holds.")
(define (keymap-names) (map car *keymaps*))

(effects! '(write))
(public! 'global-set-key "(global-set-key SEQ COMMAND) — bind the key sequence SEQ to COMMAND globally.")
(define (global-set-key seq command) (define-key "global" seq command))

(public! 'global-unset-key "(global-unset-key SEQ) — remove the global binding for the key sequence SEQ.")
(define (global-unset-key seq) (keymap-unset! "global" seq))

(public! 'use-local-map! "(use-local-map! BUF KEYMAP) — BUF's own map takes KEYMAP as its parent: the mode's map.")
(define (use-local-map! buf name) (keymap-parent! buf name))

(effects! '(read))
(public! 'buffer-local-map "(buffer-local-map BUF) — the parent of BUF's own map, or #f.")
(define (buffer-local-map buf) (keymap-parent buf))

(effects! '(write))
(public! 'clear-local-map! "(clear-local-map! BUF) — forget BUF's own bindings, parent, and remaps.")
(define (clear-local-map! buf)
  (keymap--changed!)
  (set! *keymaps* (alist-delete *keymaps* (keymap--key buf)))
  (keymap--fact! buf 'remaps '()))

(public! 'local-set-key "(local-set-key SEQ COMMAND) — bind SEQ to COMMAND in the current buffer.")
(define (local-set-key seq command) (define-key (current-buffer) seq command))

(public! 'local-set-key* "(local-set-key* BUF SEQ COMMAND) — bind SEQ to COMMAND in buffer BUF.")
(define (local-set-key* buf seq command) (define-key buf seq command))

(public! 'local-unset-key* "(local-unset-key* BUF SEQ) — drop BUF's own binding for SEQ.")
(define (local-unset-key* buf seq) (keymap-unset! buf seq))

(public! 'local-remap! "(local-remap! FROM TO) — in the current buffer, every key bound to FROM runs TO.")
(define (local-remap! from to) (local-remap*! (current-buffer) from to))

(public! 'local-remap*! "(local-remap*! BUF FROM TO) — in buffer BUF, every key bound to FROM runs TO.")
(define (local-remap*! buf from to)
  (keymap--fact! buf 'remaps (alist-put (or (keymap--fact buf 'remaps) '()) from to)))

(public! 'buffer-minor-maps!
  "(buffer-minor-maps! BUF NAMES) — the minor-mode keymaps in force in BUF, first wins, ahead of its own map.")
(define (buffer-minor-maps! buf names)
  (keymap--fact! buf 'minor-maps (map keymap--key names)))

(effects! '(read))
(public! 'buffer-minor-maps "(buffer-minor-maps BUF) — the minor-mode keymaps in force in BUF.")
(define (buffer-minor-maps buf) (or (keymap--fact buf 'minor-maps) '()))

(effects! '(write))
(public! 'global-minor-maps!
  "(global-minor-maps! NAMES) — the minor-mode keymaps in force in every buffer, after the buffer's own minor maps.")
(define (global-minor-maps! names)
  (keymap--changed!)
  (set! *global-minor-maps* (map keymap--key names)))

(effects! '(read))
(public! 'global-minor-maps "(global-minor-maps) — the keymaps in force in every buffer.")
(define (global-minor-maps) *global-minor-maps*)

(effects! '(write))
(public! 'buffer-at-point-map!
  "(buffer-at-point-map! BUF KEYMAP) — the keymap of the thing at point in BUF (a block), ahead of the minor maps; #f clears it. Emacs's overlay keymap.")
(define (buffer-at-point-map! buf name)
  (keymap--fact! buf 'at-point-map (and name (keymap--key name))))

(effects! '(read))
(public! 'buffer-at-point-map "(buffer-at-point-map BUF) — the keymap at point in BUF, or #f.")
(define (buffer-at-point-map buf) (keymap--fact buf 'at-point-map))

(public! 'buffer-keymaps
  "(buffer-keymaps BUF) — the keymap names that answer for BUF, in precedence order, \"global\" last.")
(define (buffer-keymaps buf)
  (map car (keymap--ladder buf (and (buffer-exists? buf) (buffer-read-only? buf)))))

;; the flattened ladder of BUF (or the global map alone for #f), and
;; its reverse index COMMAND -> ((KEYS) ...), kept until the next keymap
;; write: M-x asks key-for-command once per command, and a flatten per
;; ask is a heap of garbage
(define (keymap--flat buf)
  (let* ((key (if (string? buf) (keymap--key buf) "global"))
         (kept (alist-get *keymap-flat* key)))
    (if (and kept (equal? (car kept) *keymap-generation*))
        (cdr kept)
        (let* ((ladder (if (string? buf)
                           (keymap--ladder buf (and (buffer-exists? buf) (buffer-read-only? buf)))
                           (keymap--chain "global")))
               (rows (apply append (map (lambda (m) (keymap--flatten (cadr m))) ladder)))
               (index (fold (lambda (acc r)
                              (alist-put acc (cadr r) (cons (car r) (or (alist-get acc (cadr r)) '()))))
                            '() rows))
               (entry (list *keymap-generation* rows index)))
          (set! *keymap-flat* (alist-put *keymap-flat* key entry))
          (cdr entry)))))

;; every (KEYS COMMAND) of COMMAND across the ladder of BUF, or the global map alone
(define (keymap--keys-of command buf)
  (map (lambda (keys) (list keys command))
       (reverse (or (alist-get (cadr (keymap--flat buf)) command) '()))))

;; tersest first: the shortest spelling, then the alphabet
(define (keymap--tersest specs)
  (map cadr (sort (map (lambda (s) (list (list (string-length s) s) s)) specs))))

(public! 'where-is-internal
  "(where-is-internal COMMAND [BUF]) — every key sequence bound to COMMAND, tersest first.")
(define (where-is-internal command &optional buf)
  (let loop ((ks (keymap--tersest (map (lambda (r) (string-join (car r) " "))
                                       (keymap--keys-of command (or buf (current-buffer))))))
             (out '()))
    (cond ((null? ks) (reverse out))
          ((member (car ks) out) (loop (cdr ks) out))
          (else (loop (cdr ks) (cons (car ks) out))))))

(public! 'key-for-command
  "(key-for-command COMMAND [BUF]) — return the tersest key sequence bound to COMMAND, in BUF's keymap and the global one, or \"\".")
(define (key-for-command command &optional buf)
  (let ((ks (where-is-internal command (if buf buf #f))))
    (if (pair? ks) (car ks) "")))

;; ((KEYS COMMAND) ...) with the keys spelled as one string and a prefix
;; keymap as "keymap:NAME"
(define (keymap--rows rows)
  (map (lambda (r) (list (string-join (car r) " ") (cadr r))) rows))

(public! 'global-keys "(global-keys) — return ((KEYS COMMAND) ...) for every global key binding.")
(define (global-keys) (keymap--rows (keymap--flatten (keymap--bindings "global"))))

(public! 'local-keys
  "(local-keys BUF) — return ((KEYS COMMAND) ...) for every binding that answers in BUF besides the global ones; a nearer map wins.")
(define (local-keys buf)
  (let* ((ladder (filter (lambda (m) (not (equal? (car m) "global")))
                         (keymap--ladder buf (and (buffer-exists? buf) (buffer-read-only? buf)))))
         (merged (fold (lambda (acc m)
                         (fold (lambda (acc r) (alist-put acc (car r) (cadr r))) acc (keymap--flatten (cadr m))))
                       '()
                       (reverse ladder))))
    (keymap--rows merged)))

(define-keymap! "global")

;; a renamed buffer keeps its own map and its facts under the new name
(add-hook! 'buffer-renamed-hook
  (lambda (old new)
    (let ((e (keymap--entry old)))
      (when e
        (keymap--changed!)
        (set! *keymaps* (alist-delete *keymaps* (keymap--key old)))
        (keymap--put! new (car e) (cadr e))))
    (let ((f (alist-get *buffer-key-facts* old)))
      (when f
        (set! *buffer-key-facts*
          (alist-put (alist-delete *buffer-key-facts* old) new f))))))

;; a killed buffer leaves no map and no facts behind; every minibuffer
;; shares one key, so a minibuffer kill keeps that map
(define (keymap--forget-buffer! buf)
  (let ((k (keymap--key buf)))
    (unless (equal? k keymap--minibuf)
      (keymap--changed!)
      (set! *keymaps* (alist-delete *keymaps* k))
      (set! *buffer-key-facts* (alist-delete *buffer-key-facts* k)))))

;;; --- modes ------------------------------------------------------------------
;;; A major mode = mode-name buffer-local + a setup fn (local keys, vars).
;;; One table holds every fact about every mode, major and minor:
;;; ((NAME PLIST) ...). mode-put! writes one fact, mode-get reads the
;;; mode's own fact, and mode-inherited reads the nearest ancestor's.
;;; The facts: 'kind (major or minor), 'setup, 'teardown, 'keymap,
;;; 'parent, 'doc, 'icon, 'link-syntax, 'layout, 'headline, 'dismissible.
;;; A package may state a fact before the mode is defined; define-mode
;;; keeps it.

(define *modes* '())

(define (mode-entry name) (or (alist-get *modes* name) '()))
(define (mode-get name key) (and name (plist-get (mode-entry name) key)))

;; the mode's own fact, or the nearest ancestor's. The walk carries what
;; it has seen, so a parent loop ends instead of hanging the editor.
(define (mode-inherited name key)
  (let loop ((m name) (seen '()))
    (cond ((or (not m) (member m seen)) #f)
          (else (let ((v (mode-get m key)))
                  (if v v (loop (mode-get m 'parent) (cons m seen))))))))

;; the keymap a mode owns: MODE-map. set-mode! makes it the parent of
;; the buffer's own map, so a binding made once on the mode's map answers
;; in every buffer that wears the mode, and a buffer's own binding wins.
(define (mode-keymap name) (string-append name "-map"))

(define (mode-put! name key val)
  (set! *modes* (alist-put *modes* name (plist-put (mode-entry name) key val)))
  (cond ((equal? key 'parent)
         ;; the child's map falls back to the parent's
         (keymap-parent! (mode-keymap name) (mode-keymap val)))
        ((equal? key 'doc) (mode--catalog-doc! name val)))
  name)

(define (mode-forget! name)
  (set! *modes* (alist-delete *modes* name)))

;; (define-mode NAME SETUP 'parent P 'doc D 'icon I ...): every fact in
;; the same form. 'minor #t makes a minor mode: SETUP and 'teardown take
;; the buffer, and 'keymap names a map that answers while the mode is on,
;; as minor-mode-map-alist does in Emacs.
(define (define-mode name setup &rest opts)
  (let ((minor (plist-get opts 'minor)))
    (mode-put! name 'kind (if minor 'minor 'major))
    (mode-put! name 'setup setup)
    (let loop ((o opts))
      (when (and (pair? o) (pair? (cdr o)))
        (unless (or (equal? (car o) 'minor) (not (cadr o)))
          (mode-put! name (car o) (cadr o)))
        (loop (cddr o))))
    (cond (minor (let ((map (mode-get name 'keymap))) (when map (define-keymap! map))))
          (else
            (define-keymap! (mode-keymap name))
            ;; every mode is an M-x command, like Emacs, and like Emacs the
            ;; command puts the buffer in the mode; running it again keeps
            ;; it there. The modeline click is the toggle.
            (define-command name (lambda () (major-mode-set! name)))
            (unless (mode-get name 'doc)
              (catalog-register! 'mode name "Major mode"
                'use (string-append "(run-command \"" name "\")")))))
    (reload--touch! name)
    name))

;; (register-minor-mode! NAME SETUP TEARDOWN KEYMAP): define-mode's minor form
(define (register-minor-mode! name setup &optional teardown keymap)
  (define-mode name setup 'minor #t 'teardown teardown 'keymap keymap))

;; (define-derived-mode NAME PARENT SETUP): NAME is PARENT with SETUP on
;; top. Its keymap falls back to PARENT-map, its setup runs PARENT's
;; setup first, and set-mode! runs PARENT-hook before NAME-hook, as
;; Emacs's define-derived-mode does.
(define (define-derived-mode name parent setup)
  (define-mode name (lambda () (mode-setup! parent) (setup)) 'parent parent))

(define (mode-parent! name parent) (mode-put! name 'parent parent))
(define (mode-parent name) (mode-get name 'parent))

;; A mode declares dismissal independently of its parent or q command.
(define (mode-dismissible! mode) (mode-put! mode 'dismissible #t))

(public! 'mode-dismissible! "(mode-dismissible! MODE) — declare that MODE and its derived modes support dismissal; dismiss-mode supplies child-first q and window chrome")

;; the hooks a mode runs, the root's first: fundamental has none
(define (mode-hook-chain name)
  (let loop ((m name) (acc '()) (seen '()))
    (if (or (not m) (member m seen))
        (map (lambda (n) (string->symbol (string-append n "-hook"))) acc)
        (loop (mode-parent m) (cons m acc) (cons m seen)))))

;; #t when MODE is NAME, or descends from it
(define (derived-mode? mode name)
  (let loop ((m mode) (seen '()))
    (cond ((not m) #f)
          ((equal? m name) #t)
          ((member m seen) #f)
          (else (loop (mode-parent m) (cons m seen))))))

(define (buffer-derived-mode? buf name)
  (derived-mode? (buffer-local buf 'mode-name) name))

;; Run a major mode's setup. A derived mode inherits the behavior instead
;; of copying it, so the two cannot drift apart.
;; A mode whose package did not load is not a mode. The buffer used to
;; come back from it silently half-alive: set-mode! writes the mode-name
;; local and installs an EMPTY local map, mode-setup! finds no setup and
;; does nothing, and the buffer claims a mode it does not have -- no keys,
;; no overlays, no folds. A restored chat whose RET fell through to the
;; global map is this, and it reads as "the restart lost chat-mode".
;;
;; Boot no longer dies of one bad package (Session.load_stdlib!), which is
;; right, so this path is now reachable rather than theoretical. It must
;; never be quiet: say which mode is missing, in the buffer it happened to.
(define (mode-setup! name)
  (cond ((equal? (mode-get name 'kind) 'major)
         ((mode-get name 'setup)))
        ((not (mode-get name 'kind))
         (message (string-append "mode " name " is not defined, so "
                                 (current-buffer) " has none of its keys: "
                                 "its package did not load — see *Messages*")
                  "error"))
        (else #f)))

;; What a mode is for, in the mode's own words. describe-mode prints it
;; above the key table. A mode without one still gets its keys.
(define (mode-doc! name doc) (mode-put! name 'doc doc))
(define (mode-doc name) (mode-get name 'doc))

(define (mode--catalog-doc! name doc)
  (let ((e (catalog-entry 'mode name)))
    (if e
        (catalog-register! 'mode name doc
          'package (string->symbol (catalog--get e 'package))
          'namespace (string->symbol (catalog--get e 'namespace))
          'domain (string->symbol (catalog--get e 'domain))
          'effects (map string->symbol (catalog--get e 'effects))
          'use (string-append "(run-command \"" name "\")"))
        (catalog-register! 'mode name doc))))

;;; --- mode icons ---------------------------------------------------------------
;;; One glyph names a mode, and every list that shows a mode shows it:
;;; dired, ibuffer, the buffer prompt and the file prompt. A mode declares
;;; its own icon; a mode that declares none reads as a plain document. An
;;; icon is ONE character: a Nerd Font glyph, or a plain Unicode character
;;; where one says it better — λ names a Scheme file. Never an emoji, which
;;; draws two cells and colours a column that must stay quiet.

(define *default-mode-icon* "")

(define (mode-icon! name icon) (mode-put! name 'icon icon))

(define (mode-icon name)
  (let ((i (mode-get name 'icon)))
    (if i i *default-mode-icon*)))

;; The icon MODE registered for itself, or #f. A mode that never registered
;; one answers #f rather than the generic default, and a mode that registered
;; the empty string has said it wants no glyph. A caller that means to show
;; the icon INSTEAD of the name must ask this one: the default glyph says
;; nothing, so it can never stand in for a name.
(define (mode-own-icon name)
  (let ((i (mode-get name 'icon)))
    (and i (not (equal? i "")) i)))

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
(mode-icon! "term-mode" "")
(mode-icon! "comint-shell-mode" "")
(mode-icon! "tail-mode" "")
(mode-icon! "collect-mode" "")

;;; --- mode link syntax ---------------------------------------------------------
;;; How a mode writes a link to a file: Markdown writes [LABEL](PATH), Org
;;; writes [[file:PATH][LABEL]]. A mode declares its own syntax, and a child
;;; mode inherits its parent's. A mode that declares none writes the path
;;; alone, which is a link in every buffer (goto-address.scm).

(define (mode-link-syntax! name fn) (mode-put! name 'link-syntax fn))

;; the syntax of MODE or of its nearest ancestor: (lambda (PATH LABEL) TEXT),
;; or #f when the mode writes the path alone
(define (mode-link-syntax mode) (mode-inherited mode 'link-syntax))

;; The buffers whose mode setup ran in this daemon run. A buffer that
;; comes back from a checkpoint carries its mode-name but none of the
;; keys, overlays or folds its setup builds; restore-buffer-runtime! does
;; that work. A boot queues it without waiting, and a queued job that
;; fails is lost, so a key looked up in a buffer this set does not name
;; runs the restore first (keymap--lookup-here). The set lives in memory
;; only: a restart starts it empty.
(define *runtime-restored* '())

(define (runtime--mark! buf)
  (unless (member buf *runtime-restored*)
    (set! *runtime-restored* (cons buf *runtime-restored*))))

(define (runtime-owed? buf)
  (and (string? buf)
       (buffer-local buf 'mode-name)
       (not (member buf *runtime-restored*))))

(add-hook! 'buffer-renamed-hook
  (lambda (old new)
    (when (member old *runtime-restored*)
      (set! *runtime-restored*
        (cons new (filter (lambda (b) (not (equal? b old))) *runtime-restored*))))))

(define (set-mode! name)
  (let* ((buf (current-buffer))
         (old (buffer-local buf 'mode-name))
         (changed (and old (not (equal? old name)))))
    (runtime--mark! buf)
    (when changed (run-hooks 'change-major-mode-hook))
    ;; a change of major mode starts the buffer's own map afresh, as
    ;; use-local-map does in Emacs. The mode's setup puts its keys back,
    ;; and the minor modes put theirs back after it.
    (when changed
      (clear-local-map! buf)
      ;; Semantic projections belong to the old mode; the new setup rebuilds them.
      (for-each (lambda (key) (buffer-set-local! buf key #f))
                '(render-root render-text-root render-records footer-line-blocks)))
    (define-keymap! (mode-keymap name))
    (use-local-map! buf (mode-keymap name))
    (buffer-set-local! buf 'mode-name name)
    (mode-setup! name)
    (when changed (restore-minor-modes! buf))
    ;; a mode with font-lock keywords is painted from here on
    (when (pair? (font-lock-keywords name)) (font-lock-enable! buf))
    ;; the parent's hook runs before the child's, as in Emacs
    (apply run-hooks (mode-hook-chain name))
    (run-hooks 'after-change-major-mode-hook)
    ;; the mode is on: if it declares a layout, the engine arranges the frame
    (layout-enter! buf)))

;; the M-x form of a major mode: enter it, and say so. Running it in a
;; buffer that wears the mode already keeps the mode.
(define (major-mode-set! name)
  (set-mode! name)
  (message (string-append name " on")))

;;; --- kill-all-local-variables ---------------------------------------------------
;;; Emacs forgets a buffer's locals when the major mode changes, and keeps
;;; the ones marked permanent-local. Here a local can hold what a buffer
;;; IS (a chat's identity, its file), so set-mode! does not call this. It
;;; is the mechanism for a mode or a command that wants a clean buffer.

(define *permanent-locals* '(mode-name minor-modes))

(define (permanent-local! name)
  (unless (member name *permanent-locals*)
    (set! *permanent-locals* (cons name *permanent-locals*))))

(define (permanent-local? name)
  (or (member name *permanent-locals*)
      (member name chat-identity-locals)))

;; forget every local that is not permanent, and the buffer's own keys
(define (kill-all-local-variables! buf)
  (for-each
    (lambda (entry)
      (unless (permanent-local? (car entry))
        (buffer-set-local! buf (car entry) #f)))
    (buffer-locals buf))
  (clear-local-map! buf)
  buf)

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
;;;
;;; RULE: the variable behind a persisted global uses defvar, never define.
;;; A reload re-evaluates a top-level define and puts the literal back, so
;;; the live value becomes '() while the daemon runs. The next desktop save
;;; then writes that '() over the good file, and the state is gone for real.
;;; defvar binds only when the name is free, so a reload keeps the value.
;;; A state fn that derives its value from live frames or buffers, as
;;; layout-targets-state does, holds no such variable and needs nothing.

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
        (when hit (desktop-global! (car e) (cadr hit)))))
    *desktop-globals*))

;; One key on its own. A restore that raises takes every global after it
;; down with it, and the editor comes up with no groups and no layouts,
;; so the desktop puts them back one at a time when the whole set fails.
(define (desktop-global! key value)
  (let ((e (assoc key *desktop-globals*)))
    (when e ((car (cdr (cdr e))) value))))

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
      (let ((b (car dirty)))
        (read-char-choice
          (string-append "Save " b "? (y, n, A all, N none) ")
          '("y" "n" "A" "N")
          (lambda (ch)
            (cond ((equal? ch "y")
                   (save-buffer-named! b)
                   (desktop-clear--ask-save (cdr dirty) kept members))
                  ((equal? ch "n")
                   (desktop-clear--ask-save (cdr dirty) (cons b kept) members))
                  ((equal? ch "A") (desktop-clear--save-all dirty members))
                  ((equal? ch "N") (desktop-clear--finish '() members))
                  (else #f)))))))

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

;; The way back from a boot that brought the windows back and lost the
;; groups. It reads one desktop file and installs only the globals: the
;; group records, the graveyard, the histories. The windows do not move.
;; ~/.compos/desktop-backups holds a copy every ten minutes.
(define-command "desktop-read-globals"
  "Install the globals of a desktop file, leaving the windows alone"
  (lambda ()
    (read-file-name "Desktop file: "
      (lambda (file)
        (let ((globals (desktop-file-globals file)))
          (desktop-globals! globals)
          (desktop-dirty!)
          (message (string-append "Read " (number->string (length globals))
                                  " globals from " file)))))))

(catalog-meta! 'command "desktop-read-globals" 'domain 'desktop 'effects '(read write))

(domain! 'unknown)
(effects! '(unknown))

;;; --- minor modes --------------------------------------------------------------
;;; A minor mode = its name in the buffer-local 'minor-modes list + an
;;; idempotent setup fn taking the buffer. Desktop restore re-runs the
;;; setup (restore-minor-modes!) after locals come back, the same way
;;; set-mode! re-runs major-mode setup — so setup fns must rebuild
;;; presentation from the locals they find, never stack hooks twice.

(define (minor-mode-keymap name) (mode-get name 'keymap))

;; give a registered minor mode its keymap after the fact
(define (minor-mode-keymap! name map)
  (define-keymap! map)
  (mode-put! name 'keymap map))

;; (mode-keys! MODE ((KEYS COMMAND) ...)): bind once on MODE's map, at
;; load; every buffer that wears the mode answers, and a buffer's own
;; binding still wins
(define (mode-keys! mode pairs)
  (define-keymap! (mode-keymap mode))
  (for-each (lambda (p) (define-key (mode-keymap mode) (car p) (cadr p))) pairs)
  mode)

;; (minor-mode-keys! NAME ((KEYS COMMAND) ...)): the minor mode's map,
;; NAME-map, in force while the mode is on and gone when it is off
(define (minor-mode-keys! name pairs)
  (let ((map (string-append name "-map")))
    (minor-mode-keymap! name map)
    (for-each (lambda (p) (define-key map (car p) (cadr p))) pairs)
    map))

;; the mode's map joins the buffer's minor maps, first
(define (minor-mode--attach-map! buf name)
  (let ((map (minor-mode-keymap name)))
    (when map
      (buffer-minor-maps! buf
        (cons map (remove (lambda (m) (equal? m map)) (buffer-minor-maps buf)))))))

(define (minor-mode--detach-map! buf name)
  (let ((map (minor-mode-keymap name)))
    (when map
      (buffer-minor-maps! buf
        (remove (lambda (m) (equal? m map)) (buffer-minor-maps buf))))))

(define (minor-mode-on? buf name)
  (let ((ms (buffer-local buf 'minor-modes)))
    (if (and ms (member name ms)) #t #f)))

(define (enable-minor-mode! buf name)
  (let ((cur (or (buffer-local buf 'minor-modes) '())))
    (unless (member name cur)
      (buffer-set-local! buf 'minor-modes (cons name cur))))
  (minor-mode--attach-map! buf name)
  (let ((setup (mode-get name 'setup)))
    (when setup (setup buf)))
  ;; NAME-hook runs in the buffer, as a minor mode's hook does in Emacs
  (with-current-buffer buf
    (lambda () (run-hooks (string->symbol (string-append name "-hook")))))
  ;; the setup fn named the buffers its layout wants; now place them
  (layout-enter! buf))

(define (disable-minor-mode! buf name)
  (buffer-set-local! buf 'minor-modes
    (remove (lambda (n) (equal? n name))
            (or (buffer-local buf 'minor-modes) '())))
  (minor-mode--detach-map! buf name)
  (let ((teardown (mode-get name 'teardown)))
    (when teardown (teardown buf))))

(define (toggle-minor-mode! name)
  (let ((buf (current-buffer)))
    (if (minor-mode-on? buf name)
        (begin (disable-minor-mode! buf name) #f)
        (begin (enable-minor-mode! buf name) #t))))

;;; --- globalized minor modes ---------------------------------------------------
;;; (define-globalized-minor-mode! GLOBAL LOCAL ELIGIBLE?): the command
;;; GLOBAL turns LOCAL on in every buffer ELIGIBLE? accepts, now and as
;;; buffers appear, and off everywhere. Emacs's define-globalized-minor-mode.

(define *globalized-minor-modes* '())   ; ((global local eligible? on?) ...)

(define (globalized-minor-mode-on? global)
  (let ((e (assoc global *globalized-minor-modes*)))
    (and e (nth 3 e))))

(define (globalized-minor-mode--set! global on?)
  (let ((e (assoc global *globalized-minor-modes*)))
    (when e
      (set! *globalized-minor-modes*
        (cons (list global (nth 1 e) (nth 2 e) on?)
              (remove (lambda (x) (equal? (car x) global)) *globalized-minor-modes*))))))

(define (globalized-minor-mode--apply! e buf)
  (let ((local (nth 1 e)) (eligible? (nth 2 e)))
    (when (and (eligible? buf) (not (minor-mode-on? buf local)))
      (enable-minor-mode! buf local))))

(define (globalized-minor-mode-on! global)
  (globalized-minor-mode--set! global #t)
  (let ((e (assoc global *globalized-minor-modes*)))
    (when e (for-each (lambda (b) (globalized-minor-mode--apply! e b)) (buffer-list)))))

(define (globalized-minor-mode-off! global)
  (globalized-minor-mode--set! global #f)
  (let ((e (assoc global *globalized-minor-modes*)))
    (when e
      (for-each (lambda (b)
                  (when (minor-mode-on? b (nth 1 e))
                    (disable-minor-mode! b (nth 1 e))))
                (buffer-list)))))

;; a buffer that appears while a globalized mode is on gets the mode
(define (globalized-minor-mode--new-buffer! name)
  (for-each (lambda (e) (when (nth 3 e) (globalized-minor-mode--apply! e name)))
            *globalized-minor-modes*))

(define (globalized-minor-mode--find-file-hook!)
  (globalized-minor-mode--new-buffer! (current-buffer)))

(add-hook! 'buffer-created-hook 'globalized-minor-mode--new-buffer!)
(add-hook! 'find-file-hook 'globalized-minor-mode--find-file-hook!)

(define (define-globalized-minor-mode! global local eligible? &optional doc)
  (set! *globalized-minor-modes*
    (cons (list global local eligible? (globalized-minor-mode-on? global))
          (remove (lambda (x) (equal? (car x) global)) *globalized-minor-modes*)))
  (define-command global (or doc (string-append "Toggle " local " in every buffer"))
    (lambda ()
      (if (globalized-minor-mode-on? global)
          (begin (globalized-minor-mode-off! global)
                 (message (string-append global " disabled")))
          (begin (globalized-minor-mode-on! global)
                 (message (string-append global " enabled")))))))

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

;;; --- global-mode-string ------------------------------------------------------
;;; The segments at the right edge of the frame modeline, as Emacs's
;;; global-mode-string. A package owns one segment by key. A segment is a
;;; string, a (FACE-CLASS TEXT) pair, or a thunk that returns one of those;
;;; #f or "" removes it. The registry composes every segment into the
;;; frame's extra text; the client draws one span per segment.

(define *global-mode-string* '()) ; ((key value) ...) in insertion order

(define (global-mode-string--segment value)
  (let ((v (if (procedure? value) (value) value)))
    (cond ((and (string? v) (not (equal? v ""))) (list "ml-segment" v))
          ((and (pair? v) (string? (cadr v)) (not (equal? (cadr v) ""))) (list (car v) (cadr v)))
          (else #f))))

(define (global-mode-string-segments)
  (filter (lambda (x) x)
          (map (lambda (e) (global-mode-string--segment (cadr e))) *global-mode-string*)))

(define (global-mode-string-refresh!)
  (set-modeline-extra! (global-mode-string-segments)))

(define (global-mode-string-set! key value)
  (let ((rest (remove (lambda (e) (equal? (car e) key)) *global-mode-string*)))
    (set! *global-mode-string*
      (if (or (not value) (equal? value ""))
          rest
          (append rest (list (list key value)))))
    (global-mode-string-refresh!)))

(define (global-mode-string-remove! key)
  (global-mode-string-set! key #f))

(define (modeline-toggle-mode! name)
  (let* ((buf (current-buffer))
         (major (or (buffer-local buf 'mode-name) "Fundamental")))
    (cond
      ;; a minor mode toggles in place
      ((equal? (mode-get name 'kind) 'minor)
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

;; the minor maps live in the editor, not in the locals: put them back
;; with the setup
(define (restore-minor-modes! buf)
  (for-each
    (lambda (name)
      (minor-mode--attach-map! buf name)
      (let ((setup (mode-get name 'setup)))
        (when setup (setup buf))))
    (reverse (or (buffer-local buf 'minor-modes) '()))))

;; Every mode the editor knows, sorted: (mode-names) names them all,
;; (mode-names 'major) or (mode-names 'minor) one kind. A name with facts
;; but no definition yet is not a mode.
(define (mode-names &optional kind)
  (sort (map car (filter (lambda (e)
                           (let ((k (plist-get (cadr e) 'kind)))
                             (and k (or (not kind) (equal? k kind)))))
                         *modes*))))

;; Put the current buffer in the mode NAME. This is the same toggle the
;; modeline click and the mode's own M-x command run, so a major mode
;; enters and a minor mode flips.
(define (load-mode! name)
  (modeline-toggle-mode! name))

(domain! 'modes)
(effects! '(write))
(define-command "load-mode" "Choose a mode by name and put this buffer in it"
  (lambda ()
    (minibuffer-read "Mode: " (mode-names)
      (lambda (name)
        (if (member name (mode-names))
            (load-mode! name)
            (message (string-append "no mode named " name)))))))
(global-set-key "C-x m" "load-mode")
(domain! 'unknown)
(effects! '(unknown))

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
  (runtime--mark! buf)
  (with-layout-suppressed
    (lambda ()
      (with-current-buffer buf
        (lambda ()
          (with-buffer-waking
            (lambda ()
              ;; the one-shot migrations run first: a mode setup reads the
              ;; shape they write (migrations.scm)
              (run-hook-with-args 'buffer-restore-hook buf)
              (let ((mode (buffer-local buf 'mode-name)))
                (when mode (set-mode! mode)))
              (restore-minor-modes! buf)))))))
  ;; The modeline is derived state. Rebuild it here so a restored desktop
  ;; shows its top line and its short name before the first command runs.
  (when (boundp (quote dashboard--sync!))
    (dashboard--sync! buf))
  ;; The buffer is whole again, so an owner can act on it. Outside
  ;; with-buffer-waking on purpose: that flag is restored by hand, and a
  ;; hook that throws inside it would leave every later wake believing it
  ;; was still waking.
  (buffer-woken! buf))

;;; --- renaming a buffer ---------------------------------------------------------
;;; buffer-rename! is the mechanism: the buffer keeps its process, so text,
;;; point, locals, overlays and undo all survive. What does NOT survive is
;;; state OTHER things key by the old name — a change hook, a pointer from
;;; another buffer. Each owner fixes its own, here.

;; buffer-renamed-hook: (FN OLD NEW)
;; the rename the editor uses: mechanism, then every owner of name-keyed
;; state. Returns the new name, or #f when the name is taken.
(define (rename-buffer! old new)
  (let ((done (buffer-rename! old new)))
    (when done
      (run-hook-with-args 'buffer-renamed-hook old new))
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

;;; --- detaching a buffer from its file ------------------------------------------
;;; buffer-detach! is the mechanism (Emacs: set-visited-file-name with no
;;; name): the buffer keeps its text, point, locals and undo, and forgets
;;; its path. A buffer that adopted a file through (buffer-save! PATH) by
;;; mistake writes nothing there after this; a save asks for a path again.

(domain! 'buffers)
(effects! '(write))

;; Returns #t, or #f when no buffer has that name.
(define (detach-buffer! name)
  (and (buffer-known? name)
       (buffer-detach! name)))

(public! 'detach-buffer!
  "(detach-buffer! NAME) — forget NAME's file and keep its text; #t, or #f when no buffer has that name")

(define-command "buffer-detach" "Forget the current buffer's file; keep its text"
  (lambda ()
    (let ((name (current-buffer)))
      (if (buffer-path name)
          (begin
            (detach-buffer! name)
            (message (string-append "Buffer " name " no longer visits a file")))
          (message (string-append "Buffer " name " visits no file"))))))

(domain! 'unknown)
(effects! '(unknown))

;; Packages derive policy from the accepted window state through this seam.
;; Preview uses a different primitive and does not call it.

;; the window state changed: a package that derives state from the windows
;; (groups.scm recalculates the current group) listens on this hook
(define (window-state-changed!)
  (run-hooks 'window-state-change-hook)
  #t)

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
;; A switch to a buffer from outside the frame's group switches the group
;; (the owner's ruling, 2026-09-19): the frame enters the buffer's home
;; group, and the buffer opens there as a member. An ungrouped buffer
;; takes the selected window, and the frame leaves its group by the
;; derived rule. A list (ibuffer, ichat) may still float the row it
;; chose; a switch never floats. The same-window action calls
;; switch-to-buffer-here!; the window actions set a window's buffer by
;; id. Emacs: switch-to-buffer-obey-display-actions.
;; A mechanism that puts a buffer in a window it chose — a layout, a
;; swap, a restore, a borrowed window — calls switch-to-buffer-here!.
(define (switch-to-buffer! buf)
  ;; A user visit promotes quiet file loads before deciding target eligibility.
  ;; Logical and agent buffer switches remain headless.
  (when (and (not (buffer-context?)) (boundp 'buffer-promote!)
             (not (agent-edit-author? (current-edit-author))))
    (buffer-promote! buf))
  ;; A buffer opens in the current group: it joins the group it was launched
  ;; from on the way in, so the layout in front of you never changes under
  ;; you and the frame never follows a buffer home (docs/groups.md, "A buffer
  ;; opens in the current group").
  (when (and (not (buffer-context?)) (not *layout-busy*)
             (boundp 'buffer-join-here!))
    (buffer-join-here! buf))
  (cond ((buffer-context?) (switch-to-buffer-here! buf))
        ;; what cannot join is a chat, whose group is its identity. It still
        ;; opens in the pane you are in. The panes of its own group stay
        ;; sealed, saved as they stood.
        ((display-foreign? buf)
         (switch-to-buffer-here! buf)
         buf)
        ((and (not *layout-busy*) (layout-target)
              (not (float--class? (window-buffer (active-window))))
              (window-display! (lambda () (layout-target-open! buf #t #f)))) buf)
        ((and (not *layout-busy*) (not (layout-target))
              (not (float--class? (window-buffer (active-window))))
              (let ((win (or (window-showing buf)
                             (window-showing-mode (buffer-local buf 'mode-name)))))
                (and win
                     (begin
                       (window-display! (lambda () (display-buffer-in-window! win buf)))
                       (select-window! win)
                       #t)))) buf)
        (else
          (window-display!
            (lambda ()
              (switch-to-buffer-here! buf)
              (active-window)))
          buf)))

;; the switch itself: the selected window shows BUF, whatever its group
(define (switch-to-buffer-here! buf)
  (let ((restoring (not (buffer-exists? buf)))
        (float (float-window)))
    (window-switch-buffer! buf)
    (when restoring (restore-buffer-runtime! buf))
    ;; a buffer floats only in the float: shown anywhere else it is an
    ;; ordinary buffer again, whatever class it carried
    (when (and (float--class? buf) (not (equal? (active-window) float)))
      (window-float-class! buf #f))
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
;; an entry is a suffix (".scm") or a regexp ("\\.scm$", "^Makefile"), as
;; auto-mode-alist takes a regexp in Emacs. A pattern with a regexp
;; character is a regexp; a plain suffix compares case-insensitively.
(define (auto-mode--regexp? pattern)
  (or (string-contains? pattern "\\")
      (string-contains? pattern "^")
      (string-contains? pattern "$")
      (string-contains? pattern "[")
      (string-contains? pattern "(")
      (string-contains? pattern "*")
      (string-contains? pattern "?")))

(define (auto-mode--matches? pattern name)
  (if (auto-mode--regexp? pattern)
      (re-match? pattern name)
      (string-suffix? (string-downcase pattern) (string-downcase name))))

(define (auto-mode--lookup alist name)
  (let loop ((es alist))
    (cond ((null? es) #f)
          ((auto-mode--matches? (car (car es)) name) (car (cdr (car es))))
          (else (loop (cdr es))))))

(define (auto-mode-for name)
  (auto-mode--lookup *auto-mode-alist* name))

;; the mode for a script by the interpreter its first line names:
;; #!/usr/bin/env guile, #!/bin/sh. Emacs's interpreter-mode-alist.
(define *interpreter-mode-alist*
  '(("guile" "scheme-mode") ("scheme" "scheme-mode") ("chibi-scheme" "scheme-mode")
    ("elixir" "elixir-mode")))

;; the mode for a buffer by a regexp on its first line: Emacs's
;; magic-mode-alist. Empty by default; a package adds its own.
(define *magic-mode-alist* '())

(define (auto-mode--first-line buf)
  (let* ((size (buffer-size buf))
         (text (with-current-buffer buf
                 (lambda () (buffer-substring 0 (if (< size 256) size 256)))))
         (lines (string-split text "\n")))
    (if (pair? lines) (car lines) "")))

;; the program a shebang names: the last word of the line, after the
;; last slash. "#!/usr/bin/env guile" and "#!/usr/local/bin/guile" both
;; answer guile.
(define (auto-mode--interpreter line)
  (and (string-prefix? "#!" line)
       (let* ((words (filter (lambda (w) (> (string-length w) 0))
                             (string-split (substring line 2 (string-length line)) " ")))
              (last (if (pair? words) (car (reverse words)) ""))
              (prog (car (reverse (string-split last "/")))))
         (let loop ((es *interpreter-mode-alist*))
           (cond ((null? es) #f)
                 ((equal? (car (car es)) prog) (car (cdr (car es))))
                 (else (loop (cdr es))))))))

;; the mode a buffer would open in: its first line first (magic, then the
;; interpreter), then its name
(define (auto-mode-for-buffer buf &optional name)
  (let ((line (auto-mode--first-line buf)))
    (or (let loop ((es *magic-mode-alist*))
          (cond ((null? es) #f)
                ((re-match? (car (car es)) line) (car (cdr (car es))))
                (else (loop (cdr es)))))
        (auto-mode--interpreter line)
        (auto-mode-for (or name buf)))))

;; A buffer that already wears the mode its name implies is done: the
;; setup fn ran when the buffer opened. Re-running it re-parses the whole
;; buffer, and a preview calls auto-mode on every step. One 18 MB file
;; under the point cost 950 ms per keystroke before this guard.
;; A caller that WANTS the setup fn again (a reload, a desktop restore)
;; calls set-mode! by name; auto-mode only decides a new buffer's mode.
(define (auto-mode path)
  (let ((m (auto-mode-for-buffer (current-buffer) path)))
    (when (and m (not (equal? m (buffer-local (current-buffer) 'mode-name))))
      (set-mode! m))))

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

;;; The prompt's input is a buffer, because typing, DEL, yank and undo are
;;; a buffer's own work. It is not a buffer of the buffer world: nothing
;;; reads it, dismisses it, or saves it. That difference is a major mode,
;;; so every rule about prompts asks the mode instead of matching the
;;; name — and the prompt's keys are the mode's map, so every frame's
;;; prompt has them, not only the frame that was up when this file loaded.
(define-mode "minibuffer-mode"
  (lambda ()
    ;; A prompt is input, never a reading surface. The read-only flag —
    ;; and the q dismissal and Reading bar that follow it — belongs to
    ;; the buffers you look at. A mode setup that runs while a prompt is
    ;; up sees the prompt as the current buffer, and that is how the flag
    ;; arrived there at all.
    (buffer-set-read-only! (current-buffer) #f)))

(mode-doc! "minibuffer-mode"
  "The buffer behind a prompt. It holds what you type and nothing else: no read-only flag, no dismissal, no reading surface.")

(mode-keys! "minibuffer-mode"
  '(("RET" "minibuffer-confirm")
    ("M-RET" "minibuffer-confirm-input")
    ("C-RET" "minibuffer-confirm-context")
    ("C-g" "minibuffer-cancel")
    ("TAB" "minibuffer-complete")
    ("C-n" "minibuffer-next-candidate")
    ("<down>" "minibuffer-next-candidate")
    ("C-p" "minibuffer-previous-candidate")
    ("<up>" "minibuffer-previous-candidate")
    ;; the palette's two lists: <right> steps into the one on the right,
    ;; <left> steps back. With no rail they are point motion.
    ("<right>" "minibuffer-rail-enter")
    ("<left>" "minibuffer-rail-exit")
    ;; with no shortcut, these keep their section-navigation behavior
    ("M-p" "minibuffer-previous-section")
    ("M-n" "minibuffer-next-section")
    ("M-<up>" "minibuffer-previous-section")
    ("M-<down>" "minibuffer-next-section")
    ("M-g" "minibuffer-regroup")
    ;; a search repeats from inside its own prompt
    ("C-s" "isearch-repeat-forward")
    ("C-r" "isearch-repeat-backward")
    ;; the prompt continues as a buffer — see minibuffer-collect
    ("C-c C-o" "minibuffer-collect")
    ;; the same prompt as the bar, panel, or modal while it is up
    ("C-c C-t" "minibuffer-cycle-shape")
    ("DEL" "minibuffer-delete-backward")
    ("<delete>" "minibuffer-delete-row")))

(for-each
  (lambda (key)
    (define-key "minibuffer-mode-map" (string-append "M-" key)
      (mb-shortcut-command key)))
  '("1" "2" "3" "4" "5" "6" "7" "8" "9"
    "a" "b" "c" "d" "e" "f" "g" "h" "i" "j"
    "k" "l" "m" "n" "o" "p" "q" "r" "s" "t"
    "u" "v" "w" "x" "y" "z"))

(define (minibuffer-buffer? buf)
  (if (and buf (buffer-known? buf) (buffer-derived-mode? buf "minibuffer-mode")) #t #f))

;; Every frame makes its own prompt buffer, on its first prompt. The mode
;; goes on there rather than at load: a frame opened later is a prompt too.
(define (minibuffer-mode-ensure! &optional buf)
  (let ((buf (or buf (minibuffer-buffer))))
    (when (and buf (buffer-exists? buf) (not (minibuffer-buffer? buf)))
      (with-current-buffer buf (lambda () (set-mode! "minibuffer-mode"))))
    buf))

(define-mode "text-mode" (lambda () #t))

;; The base every language mode is built from, the way Emacs builds one.
;; It adds no keys and no setup of its own. What it gives is one ancestor
;; to ask about — (buffer-derived-mode? BUF "prog-mode") is "is this
;; buffer source code" — one map to hang a key every source buffer wants
;; on, and prog-mode-hook, which runs before the language's own hook.
(define-mode "prog-mode" (lambda () #t))
(define-derived-mode "scheme-mode" "prog-mode" (lambda () #t))   ; scheme grammar pending

(mode-doc! "prog-mode"
  "The base of every language mode. It adds no keys of its own: `prog-mode-map` and `prog-mode-hook` are where a key or a setting for every source buffer goes.")

(mode-doc! "text-mode"
  "Plain prose: `.txt`. The mode adds no keys. `C-c C-v` renders the file, because the renderer reads the extension.")

;;; --- the name at point --------------------------------------------------------
;;; Two callers read the name under the cursor and they disagree about the
;;; alphabet, on purpose. `M-.` must not read `foo/2` or `a+b` as one
;;; name, so it stops at the code alphabet. Help also reads Scheme globals
;;; like `*modes*`, so it adds `*`. One scanner, two alphabets.

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

;; the provider of a mode is the keyed hook (context-provider MODE)
(define (register-context-provider! mode fn)
  (add-hook! (list 'context-provider mode) fn))

(define (buffer-context buf)
  (run-hook-with-args-until-success
    (list 'context-provider (or (buffer-local buf 'mode-name) "")) buf))

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

;; the provider of a mode is the keyed hook (target-provider MODE);
;; FN: buf -> target or #f
(define (register-target-provider! mode fn)
  (add-hook! (list 'target-provider mode) fn))

(define (target-at buf)
  (run-hook-with-args-until-success
    (list 'target-provider (or (buffer-local buf 'mode-name) "")) buf))

(define *embark-actions* '())     ; ((type ((name fn) ...)) ...)

(define (register-actions! type actions)
  (set! *embark-actions* (alist-put *embark-actions* type actions)))

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
(define (kill-region-1 s e &optional before?)
  (if (> e s)
      (begin
        (kill-text! (buffer-substring s e) before?)
        (delete-between! s e)
        #t)
      #f))

;; A mode may let one visible region represent a larger source range. Keep
;; that policy here so keyboard copy, keyboard cut, and system copy agree.
(define *region-lifters* '())

(define (register-region-lifter! mode fn)
  (set! *region-lifters* (alist-put *region-lifters* mode fn)))

(define (region-action-bounds)
  (let* ((buf (current-buffer))
         (start (region-beginning))
         (end (region-end))
         (hit (assoc (buffer-local buf 'mode-name) *region-lifters*)))
    (if (and hit (procedure? (cadr hit)))
        ((cadr hit) buf start end)
        (list start end))))

(define-command "forward-word" "Move point forward one word" (interactive 'p)
  (lambda (n) (repeat-count n forward-word! backward-word!)))
(define-command "backward-word" "Move point backward one word" (interactive 'p)
  (lambda (n) (repeat-count n backward-word! forward-word!)))

;; N words forward from point, killed as one entry
(define (kill-words! n)
  (let ((s (point)))
    (repeat-count n forward-word!)
    (kill-region-1 s (point))))

(define (backward-kill-words! n)
  (let ((e (point)))
    (repeat-count n backward-word!)
    (kill-region-1 (point) e #t)))

(define-command "kill-word" "Kill characters forward to the end of a word" (interactive 'p)
  (lambda (n) (if (< n 0) (backward-kill-words! (- n)) (kill-words! n))))

(define-command "backward-kill-word" "Kill characters backward to the start of a word" (interactive 'p)
  (lambda (n) (if (< n 0) (kill-words! (- n)) (backward-kill-words! n))))

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

;; with an argument, scroll that many lines instead of a screen
(define-command "scroll-up-command" "Scroll text upward nearly a full screen" (interactive 'P)
  (lambda (arg)
    (if arg
        (scroll-window! (active-window) (prefix-numeric-value arg))
        (or (preview-scroll! (- (window-rows) 2))
            (visual-page! 1)))))

(define-command "scroll-down-command" "Scroll text downward nearly a full screen" (interactive 'P)
  (lambda (arg)
    (if arg
        (scroll-window! (active-window) (- (prefix-numeric-value arg)))
        (or (preview-scroll! (- 2 (window-rows)))
            (visual-page! -1)))))

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

(define (buffer-goto-line! buf line)
  "Move BUF's point to the start of LINE without selecting or displaying BUF."
  (let ((n (if (number? line) line (string->number line))))
    (if (and (buffer-known? buf) (number? n) (>= n 1))
        (with-current-buffer buf
          (lambda () (goto-char! (line-start-position n))))
        #f)))

(public! 'buffer-goto-line!
  "(buffer-goto-line! BUF LINE) — move a named buffer's point to LINE without changing focus or windows")
(catalog-meta! 'function "buffer-goto-line!" 'domain 'editing 'effects '(write))

;;; imenu lives in packages/code.scm now, on the outline contract: the
;;; index is (code-outline BUF), so it needs no per-language query table.

;;; --- mark & region ---------------------------------------------------------

;;; --- the mark ring ---------------------------------------------------------
;;; Emacs keeps the marks a buffer had: C-SPC pushes the old mark onto the
;;; buffer's ring and sets a new one, and C-u C-SPC goes back to the mark
;;; and pops the ring. The global mark ring remembers the buffer too, so
;;; C-x C-SPC walks back across buffers. Here a set mark is an active
;;; region, so a pop lands point on the old mark and leaves no region.

(define mark-ring-max 16)
(define *global-mark-ring* '())    ; ((BUF POS) ...), newest first

(define (mark-ring &optional buf)
  (or (buffer-local (or buf (current-buffer)) 'mark-ring) '()))

(define (global-mark-ring) *global-mark-ring*)

;; the old mark joins the ring, and the global ring when the buffer is
;; not the newest entry's
(define (push-mark! &optional pos nomsg)
  (let* ((buf (current-buffer))
         (old (mark))
         (at (or pos (point))))
    (when old
      (buffer-set-local! buf 'mark-ring (take (cons old (mark-ring buf)) mark-ring-max)))
    (unless (and (pair? *global-mark-ring*) (equal? (car (car *global-mark-ring*)) buf))
      (set! *global-mark-ring* (take (cons (list buf (or old at)) *global-mark-ring*) mark-ring-max)))
    (set-mark! at)
    (unless nomsg (message "Mark set"))
    at))

;; back to the mark, and the ring turns: the next pop reaches the one
;; before. With no mark the newest ring entry is the target.
(define (pop-to-mark!)
  (let* ((buf (current-buffer))
         (m (mark))
         (ring (mark-ring buf))
         (target (or m (and (pair? ring) (car ring)))))
    (cond ((not target) (message "No mark set in this buffer") #f)
          (else
            (goto-char! target)
            (set-mark! #f)
            (buffer-set-local! buf 'mark-ring
              (if m
                  (append ring (list m))
                  (append (cdr ring) (list target))))
            target))))

(define-command "set-mark-command" "Set the mark where point is; with a prefix, go back to the previous mark"
  (interactive 'P)
  (lambda (arg)
    (if arg (pop-to-mark!) (push-mark!))))

(define-command "pop-global-mark" "Go back to the last mark set in any buffer"
  (lambda ()
    (if (null? *global-mark-ring*)
        (message "No global mark set")
        (let* ((e (car *global-mark-ring*))
               (buf (car e)) (pos (cadr e)))
          (set! *global-mark-ring* (append (cdr *global-mark-ring*) (list e)))
          (if (buffer-known? buf)
              (begin (switch-to-buffer! buf) (goto-char! pos))
              (run-command "pop-global-mark"))))))

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

;; Visual narrowing and model context are separate choices. These marker locals
;; make an explicit context restriction follow edits without making ordinary
;; C-x n n change what the model sees.
(define (llm-context-range buf)
  (let ((start (buffer-local buf 'llm-context-start))
        (end (buffer-local buf 'llm-context-end)))
    (and (number? start) (number? end) (<= start end) (list start end))))

(define (llm-context-text buf text)
  (let ((range (llm-context-range buf)))
    (if range
        (substring-bytes text (car range) (cadr range))
        text)))

(define (llm-context-clear! buf)
  (let ((had (llm-context-range buf)))
    (buffer-set-local! buf 'llm-context-start #f)
    (buffer-set-local! buf 'llm-context-end #f)
    (when (and had (minor-mode-on? buf "llm-mode")
               (boundp (quote llm-mode-reset-runtime!)))
      (llm-mode-reset-runtime! buf #f))
    had))

(define (llm-context-use-narrowing! buf)
  (let ((range (buffer-narrow-range buf)))
    (when range
      (buffer-marker-local! buf 'llm-context-start 'stay)
      (buffer-marker-local! buf 'llm-context-end 'advance)
      (buffer-set-local! buf 'llm-context-start (car range))
      (buffer-set-local! buf 'llm-context-end (cadr range))
      (when (and (minor-mode-on? buf "llm-mode")
                 (boundp (quote llm-mode-reset-runtime!)))
        (llm-mode-reset-runtime! buf #f)))
    range))

(define-command "narrow-to-region" "Show only the text between point and mark"
  (lambda ()
    (if (and (mark) (< (region-beginning) (region-end)))
        (begin
          (buffer-narrow! (current-buffer) (region-beginning) (region-end))
          (message "Narrowed to region"))
        (message "No region — set the mark first (C-SPC)"))))

(define-command "narrow-context-also"
  "Narrow the view and the LLM context to the same region or Morg section"
  (lambda ()
    (let ((buf (current-buffer)))
      (run-command
        (if (buffer-derived-mode? buf "morg-mode") "morg-narrow" "narrow-to-region"))
      (let ((range (llm-context-use-narrowing! buf)))
        (when range
          (message (string-append "Narrowed view and LLM context to "
                                  (number->string (- (cadr range) (car range)))
                                  " bytes")))))))

(define-command "widen" "Show the complete current buffer"
  (lambda ()
    (llm-context-clear! (current-buffer))
    (buffer-widen! (current-buffer))
    (message "Widened buffer")))

(catalog-meta! 'command "narrow-to-region"
  'domain 'buffers 'effects '(write display))
(catalog-meta! 'command "narrow-context-also"
  'domain 'llm 'effects '(write display))

(catalog-meta! 'command "widen"
  'domain 'buffers 'effects '(write display))

;;; --- font-lock keywords -------------------------------------------------------
;;; Emacs's font-lock-keywords for a mode without a grammar: a list of
;;; (REGEXP FACE). Every match in the buffer wears the face, under the
;;; font-lock overlay tag, and the paint follows every change. A derived
;;; mode inherits its parent's keywords. A mode with keywords is painted
;;; from set-mode! on; a package may call font-lock-refontify! itself.

(define *font-lock-keywords* '())     ; ((MODE (REGEXP FACE) ...) ...)
(define *font-lock-hooks* '())        ; ((BUF HANDLE) ...)

(define (font-lock-set-keywords! mode keywords)
  (set! *font-lock-keywords* (hook--alist-put *font-lock-keywords* mode keywords))
  mode)

;; the keywords of MODE and its parents, the parent's first
(define (font-lock-keywords mode)
  (let loop ((m mode) (acc '()) (seen '()))
    (if (or (not m) (member m seen))
        acc
        (loop (mode-parent m) (append (hook--alist-get *font-lock-keywords* m) acc) (cons m seen)))))

(define (font-lock--spans text keywords)
  (apply append
    (map (lambda (k)
           (map (lambda (r) (list (car r) (cadr r) (cadr k)))
                (re-find* (car k) text)))
         keywords)))

(define (font-lock-refontify! buf)
  (when (buffer-exists? buf)
    (let ((kws (font-lock-keywords (buffer-local buf 'mode-name))))
      (overlay-set! buf 'font-lock
        (if (null? kws) '() (font-lock--spans (buffer-text buf) kws))))))

;; the reactor binds a rule to one buffer process, so setup replaces the
;; old rule, as markdown-mode does
(define (font-lock-enable! buf)
  (let ((old (assoc buf *font-lock-hooks*)))
    (when old (remove-on-change! (cadr old)))
    (set! *font-lock-hooks* (alist-put *font-lock-hooks* buf (on-change! buf
                    (lambda (pos inserted deleted source)
                      (unless (equal? source "locals") (font-lock-refontify! buf)))
                    'eager)))
    (font-lock-refontify! buf)))

(define (font-lock-disable! buf)
  (let ((old (assoc buf *font-lock-hooks*)))
    (when old
      (remove-on-change! (cadr old))
      (set! *font-lock-hooks* (remove (lambda (e) (equal? (car e) buf)) *font-lock-hooks*)))
    (overlay-set! buf 'font-lock '())))

(define-command "isearch-forward" "Do incremental search forward"
  (lambda () (isearch #f)))
(define-command "isearch-backward" "Do incremental search backward"
  (lambda () (isearch #t)))

;;; --- files & buffers -------------------------------------------------------

;; Every owner can apply policy to one truly new buffer. Waking a dormant
;; buffer does not run these hooks because that buffer already has state.
;; buffer-created-hook: (FN NAME)
(define (buffer-created! name)
  (when (string? name) (buffer-set-local! name 'created-at (current-time)))
  (run-hook-with-args 'buffer-created-hook name)
  name)

;; A buffer carries the two times that say whether anyone still wants it:
;; when it was made, and when the user last had it in front of them. Both
;; are locals, so a checkpoint keeps them, and a local reads out of a
;; dormant buffer without waking it. Nothing else can answer the question:
;; the MRU ring holds names with no times, and it pads its tail with every
;; other known buffer in alphabetical order.
(define buffer-seen-coarse-seconds 60)
(define *buffer-seen-stamps* '())

(define (buffer-seen-memo b)
  (let ((e (assoc b *buffer-seen-stamps*))) (and e (cadr e))))

(define (buffer-seen-memo! b t)
  (set! *buffer-seen-stamps* (alist-put *buffer-seen-stamps* b t)))

(define (buffer-note-seen! b)
  ;; one write a minute per buffer. The hook behind this runs on every
  ;; window configuration change, and a local write is a call into the
  ;; buffer's own process.
  (when (and (string? b) (buffer-known? b))
    (let ((now (current-time)) (was (buffer-seen-memo b)))
      (when (or (not (number? was)) (> (- now was) buffer-seen-coarse-seconds))
        (buffer-seen-memo! b now)
        (buffer-set-local! b 'last-seen now))))
  b)

(define (buffer-last-seen b)
  ;; the memo answers a drawn list without touching the buffer; a miss
  ;; reads the local once and keeps it, so a table pays this per boot.
  (let ((memo (buffer-seen-memo b)))
    (or memo
        (and (buffer-known? b)
             (let ((t (buffer-local b 'last-seen)))
               (when (number? t) (buffer-seen-memo! b t))
               (and (number? t) t))))))

;; The other half. A dormant buffer is absent from (buffer-list), so a
;; pass over the open buffers cannot reach it while it sleeps, and it
;; missed every seam that ran meanwhile. This is where an owner catches
;; that buffer up. It runs on a desktop restore too, which is the same
;; event: state came back from a checkpoint, not from nothing.
;; buffer-woken-hook: (FN NAME)
(define (buffer-woken! name)
  (run-hook-with-args 'buffer-woken-hook name)
  name)

;; A new buffer inherits the directory of the buffer that made it (Emacs:
;; default-directory is buffer-local and copied from the current buffer at
;; creation). Without this, every non-file buffer — chat, shell, agent
;; thread, listing — answers "~" and C-x C-f from it loses your place.

;; A buffer name that is a file on disk names that file. An empty buffer
;; under such a name holds a lie, and the first save turns the lie into
;; a clobber: an agent made ~/.compos/init.scm that way and wrote seven
;; lines over a hundred. A directory name is not a file: a Dired listing
;; is a plain buffer named by its directory.
(define (buffer-shadows-file? name)
  (and (string? name)
       (string-prefix? "/" name)
       (not (remote-path? name))
       (not (buffer-path name))
       (file-exists? name)
       (not (file-directory? name))))

(define (buffer-create name)
  (if (and (not (buffer-known? name)) (buffer-shadows-file? name))
      ;; the name is a file: load it, so the buffer starts as the file
      (find-file name)
      (let ((fresh (not (buffer-exists? name)))
            (new (not (buffer-known? name))))
        (raw-buffer-create name)
        (when (and fresh (boundp (quote default-directory)))
          (buffer-set-local! name 'default-directory (default-directory)))
        (when new (buffer-created! name))
        name)))

;;; --- write policy ----------------------------------------------------------
;; Two primitives put text on disk: write-file! and buffer-save!. Every write
;; this editor makes goes through one of them, so they are the one door, and
;; this is the one guard on it. Elixir supplies the raw write. The rules here
;; decide which writes happen.
;;
;; A rule is a record: a name, a reason, a confirmable flag, and a predicate.
;; The predicate reads the target PATH and the SOURCE buffer, and answers #t
;; to refuse. SOURCE is #f when a program writes a file it owns (a theme file,
;; a cache, a test fixture), and the rules that need a buffer pass on those.
;;
;; The list is data: write-rules reads it, a package appends to it. This is
;; why there is no policy language here. A rule needs buffer-path, the buffer
;; locals and the file system, and Scheme already reads all three. A language
;; that could express this rule would have to reach the same three things,
;; and then it would be Scheme with worse spelling.
;;
;; The rule that exists first: on 2026-09-09 layouts.ex, 3982 lines, became
;; the 730-line transcript of a chat buffer. The daemon then could not boot,
;; because a clobbered .ex fails the compile.

(domain! 'files)
(effects! '(pure))

(defvar '*write-rules* '())

;; a one-shot permit, and it names the file it permits. The door spends it,
;; so an error on the way cannot leave the rules off, and a permit for one
;; file can never carry a write to another.
(defvar '*write-permit* #f)

;; The raw primitives, kept under their own names before the shadows below
;; take the plain ones. The boundp guard matters: a hot reload of this file
;; re-evaluates these two forms, and without it the raw name would capture
;; the shadow and the door would call itself.
(define raw-write-file!
  (if (boundp 'raw-write-file!) raw-write-file! write-file!))
(define raw-buffer-save!
  (if (boundp 'raw-buffer-save!) raw-buffer-save! buffer-save!))

;; CONFIRMABLE? says whether a human answering a question can set this rule
;; aside. A rule about clobbering is confirmable, because overwriting a file
;; on purpose is a real gesture. A rule about where a kind of file may live
;; is not: no answer makes a .scm belong outside a Scheme root.
(define (defwrite-rule! name reason confirmable? pred)
  (set! *write-rules*
        (append (remove (lambda (r) (equal? (car r) name)) *write-rules*)
                (list (list name reason confirmable? pred))))
  name)

(define (write-rules) *write-rules*)

(define (write-rule-name r) (car r))
(define (write-rule-reason r) (cadr r))
(define (write-rule-confirmable? r) (caddr r))
(define (write-rule-pred r) (cadr (cddr r)))

;; #f when the write is allowed, else the reason it is not.
(define (write-refusal path source permitted?)
  (let loop ((rules *write-rules*))
    (cond ((null? rules) #f)
          ((and permitted? (write-rule-confirmable? (car rules)))
           (loop (cdr rules)))
          (((write-rule-pred (car rules)) path source)
           (string-append (write-rule-reason (car rules))
                          " [" (symbol->string (write-rule-name (car rules))) "]"))
          (else (loop (cdr rules))))))

;; Let the next write to PATH set the confirmable rules aside. Only a human
;; answer reaches this: the overwrite question in write-file. An agent never
;; sees that question, so an agent never gets the permit.
(define (allow-one-write! path)
  (set! *write-permit* path)
  path)

;; the door. Spend the permit whatever the verdict, so it never outlives the
;; write it was given for.
(define (write-check! path source)
  (let ((permitted? (equal? *write-permit* path)))
    (set! *write-permit* #f)
    (write-refusal path source permitted?)))

(define (write-refuse! path reason)
  (error (string-append "Refused to write " (abbreviate-file-name path)
                        ": " reason)))

(effects! '(write))

;; PATH is the file; TEXT is what goes in it; SOURCE is the buffer whose text
;; this is, or absent when a program writes a file it owns.
(define (write-file! path &optional text source)
  (let ((no (write-check! path (if source source #f))))
    (if no
        (write-refuse! path no)
        (raw-write-file! path text))))

(define (buffer-save! &optional path)
  (let* ((source (current-buffer))
         (target (if path path (buffer-path source))))
    (if (not target)
        (raw-buffer-save!)
        (let ((no (write-check! target source)))
          (cond (no (write-refuse! target no))
                (path (raw-buffer-save! path))
                (else (raw-buffer-save!)))))))

(effects! '(read))

;; #t when writing OLD to P replaces a file that OLD is not already the
;; buffer for. This is the question write-file asks a person.
(define (write-overwrites? old p)
  (and (file-exists? p)
       (not (file-directory? p))
       (not (equal? (buffer-path old) p))))

(define (write--under-root? path root)
  (and (string? root)
       (let ((r (file-realpath root)))
         (or (equal? path r)
             (string-prefix? (string-append r "/") path)))))

;;; --- load-path ----------------------------------------------------------------
;;; Where (load NAME) looks for a relative NAME, first match wins: the
;;; editor's own priv tree, the packages at the project root, the config
;;; home, and the user's packages. A release has no project root and
;;; carries the packages under priv instead. An absolute name loads as it is. The
;;; kernel sets the default; init.scm and the user init load by bare name
;;; and add a directory only for Scheme outside these four.

(defvar 'load-path
  (append (list (compos-priv-dir))
          (let ((root (compos-project-dir)))
            (if root (list (string-append root "/scheme/packages")) '()))
          ;; a release copies scheme/packages here; a checkout has nothing here
          (list (string-append (compos-priv-dir) "/packages")
                (compos-config-dir)
                (string-append (compos-config-dir) "/packages")))
  "Directories (load NAME) searches for a relative NAME, in order.")

;; Emacs add-to-list: VALUE goes to the front of the list VAR names, once.
(define (add-to-list! var value)
  (let ((cur (symbol-value var)))
    (unless (member value cur)
      (set-symbol-value! var (cons value cur)))
    (symbol-value var)))

;; the file (load NAME) reads, or #f. NAME may omit ".scm".
(define (locate-library name)
  (if (or (string-prefix? "/" name) (string-prefix? "~" name))
      (and (file-exists? name) name)
      (let loop ((dirs load-path))
        (if (null? dirs)
            #f
            (let* ((plain (string-append (car dirs) "/" name))
                   (scm (string-append plain ".scm")))
              (cond ((file-exists? scm) scm)
                    ((file-exists? plain) plain)
                    (else (loop (cdr dirs)))))))))

(define (load--library-name path)
  (car (string-split (car (reverse (string-split path "/"))) ".scm")))

;; the origin stamp a file gets from where it lives: the editor's own trees
;; are bundled, everything else is the user's
(define (load--origin path)
  (let ((root (compos-project-dir)))
    (if (or (write--under-root? path (compos-priv-dir))
            (and root (write--under-root? path root)))
        'bundled
        'user)))

;; (load NAME) finds NAME on load-path, stamps the catalog package and
;; origin from the file, evaluates it, and puts the stamps back. A nested
;; load therefore never changes the attribution of the file around it.
(define (load name)
  (let ((path (locate-library name)))
    (unless path
      (error (string-append "cannot load " name ": not on load-path")))
    (let ((pkg *loading-package*)
          (ns *loading-namespace*)
          (org *loading-origin*)
          (dom *catalog-domain*)
          (eff *catalog-effects*))
      (origin! (load--origin path))
      (package! (string->symbol (load--library-name path)))
      (let ((result (builtin-load path)))
        (set! *loading-package* pkg)
        (set! *loading-namespace* ns)
        (set! *loading-origin* org)
        (set! *catalog-domain* dom)
        (set! *catalog-effects* eff)
        result))))

;; Where a .scm file may live: every load-path directory, the home, and
;; whatever the user adds here to work on Scheme somewhere else.
(defvar '*scheme-write-roots* '())

(define (scheme-write-roots)
  (append load-path (list (compos-home)) *scheme-write-roots*))

(effects! '(pure))

;; 1. The disaster rule. A buffer writes the file it read, or a file that is
;;    not there yet. It never writes over a file whose text it never held:
;;    that text is not the file plus edits, it is a replacement.
(defwrite-rule! 'buffer-reads-what-it-writes
  "the file is there and this buffer never read it" #t
  (lambda (path source)
    (and source (write-overwrites? source path))))

;; A directory that already holds a .scm file is a Scheme directory. This is
;; what lets the rule below leave every worktree and every other project
;; alone, while a stray .scm still cannot appear in a directory that has
;; none. The scan runs only when the file is not there yet.
(define (scheme-directory? dir)
  (let loop ((names (list-dir dir)))
    (cond ((null? names) #f)
          ((string-suffix? ".scm" (car names)) #t)
          (else (loop (cdr names))))))

(define (under-scheme-root? path)
  (let ((real (file-realpath path)))
    (let loop ((roots (scheme-write-roots)))
      (cond ((null? roots) #f)
            ((write--under-root? real (car roots)) #t)
            (else (loop (cdr roots)))))))

;; 2. A Scheme file is source, and source belongs where the source is. A .scm
;;    may join a directory that already holds one, and it may start a new one
;;    under a Scheme root. It may not appear anywhere else. No answer to a
;;    question changes where a kind of file lives, so this rule is absolute:
;;    to work on Scheme somewhere new, name the directory in
;;    *scheme-write-roots*.
(defwrite-rule! 'scheme-files-in-scheme-roots
  "a .scm file belongs beside other Scheme, or under a Scheme root; see *scheme-write-roots*" #f
  (lambda (path source)
    (and source
         (string-suffix? ".scm" path)
         (not (file-exists? path))
         (not (under-scheme-root? path))
         (not (scheme-directory? (path-directory path))))))

;; 3. A chat buffer holds a rendering of a conversation. The only files it
;;    can become are the ones that read back as one. No answer to a question
;;    puts a transcript in a source file, so this rule is absolute too.
(defwrite-rule! 'chat-writes-chat-files
  "a chat buffer writes only a .chat or a .md file" #f
  (lambda (path source)
    (and source
         (buffer-local source 'agent-slug)
         (not (string-suffix? ".chat" path))
         (not (string-suffix? ".md" path)))))

(effects! '(read))

(define-command "write-rules" "List the rules that decide which writes happen"
  (lambda ()
    (for-each
      (lambda (r)
        (message (string-append (symbol->string (write-rule-name r))
                                (if (write-rule-confirmable? r)
                                    " (a person can confirm past it): "
                                    " (absolute): ")
                                (write-rule-reason r))))
      *write-rules*)
    (message (string-append (number->string (length *write-rules*))
                            " write rules; see *messages*"))))

;; The end of every save path: the buffer matches the file, the hooks
;; run, and the echo area names the file.
(define (save-done! path)
  (buffer-mark-saved! (current-buffer))
  (run-hooks 'after-save-hook)
  (message (string-append "Wrote " path)))

;; The client's own caret moved point, with no command to run
;; post-command-hook: point-motion-hook gets the buffer instead.
(define (client-point-moved! buf)
  (run-hook-with-args 'point-motion-hook buf))

;; remote buffers save over ssh, never through the local filesystem
(define (save-remote-buffer! bpath)
  (let ((hp (remote-parse bpath)))
    (let ((r (remote-write (car hp) (cadr hp) (buffer-text (current-buffer)))))
      (if (pair? r)   ; (error MSG)
          (message (string-append "Write failed: " (cadr r)))
          (save-done! bpath)))))

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
             (write-file! bpath (chat-file-text (current-buffer))
                          (current-buffer))
             (save-done! bpath))
            (else (save-local-buffer!))))))

(define (save-local-buffer!)
    (let* ((buf (current-buffer))
           (bpath (buffer-path buf))
           (named-path (and (string-prefix? "/" buf)
                            (not (remote-path? buf))
                            buf))
           (path (or bpath named-path)))
      (cond
        ;; Never overwrite a file-backed name that was opened without
        ;; reading it. That requires the explicit write-file gesture.
        ((buffer-shadows-file? buf)
         (error (string-append
                  (abbreviate-file-name buf)
                  " exists on disk and this buffer never read it."
                  " Use write-file to write over it.")))
        ;; Pass the known target explicitly. The raw save primitive requires
        ;; that target in this path and adopts it as the buffer's file path.
        (path
         (let ((p (buffer-save! path)))
           (unless (buffer-local buf 'mode-name)
             (auto-mode p))
           (save-done! p)))
        ;; no file name at all: C-x C-s falls through to write-file
        (else (run-command "write-file")))))

;; write-file makes the buffer BECOME the file buffer: visit reads the
;; file back and auto-mode applies — a chat saved as .chat opens as a
;; chat, forever after C-x C-s just saves.
;; An answer that names a directory writes the buffer's own name into
;; it, as Emacs does. A chat that a person writes somewhere on purpose
;; works there from then on: the directory is chat identity, and the
;; .chat header carries it across a restart.
(define (write-file-target old path0)
  (let ((p (expand-path (normalize-file-input (string-trim path0)))))
    (if (file-directory? p)
        (string-append p "/" (write-file-default-name old))
        p)))

;; C-x C-w over a file that is already there is a real gesture, so a person
;; may do it. The question is the only way past the confirmable write rules,
;; and the answer buys exactly one write, to exactly this file. An agent
;; never sees a question, so this door does not open for one.
(define (write-buffer-to-file! old path0)
  (unless (equal? (string-trim path0) "")
    (let ((p (write-file-target old path0)))
      (if (write-overwrites? old p)
          (y-or-n (string-append (abbreviate-file-name p) " is a file. Replace it with "
                                 old "?")
                  (lambda ()
                    (allow-one-write! p)
                    (write-buffer-to-file-now! old p)))
          (write-buffer-to-file-now! old p)))))

(define (write-buffer-to-file-now! old p)
  (if (equal? p old)
          ;; the buffer already carries this name: adopt, do not re-visit
          (begin
            (buffer-save! p)
            (save-done! p))
          (let ((g (buffer-group old))
                (record (buffer-local old 'chat-wire-turns))
                (chat? (buffer-local old 'agent-slug)))
            (when chat?
              (buffer-set-local! old 'chat-directory (path-directory p)))
            (write-file! p (or (chat-file-text old) (buffer-text old)) old)
            (visit p)
            (when g (buffer-set-local! (current-buffer) 'group g))
            (when record
              (buffer-set-local! (current-buffer) 'chat-wire-turns record))
            (when chat?
              (buffer-set-local! (current-buffer) 'chat-directory
                                 (path-directory p)))
            (buffer-kill! old)
            (save-done! p))))

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

(define (write-file-default-name buf)
  (let* ((stem (write-file-buffer-stem buf))
         (mode (buffer-local buf 'mode-name))
         (ext (if (auto-mode-for stem)
                  ""
                  (write-file-mode-extension mode))))
    (string-append stem ext)))

(define (write-file-default-path buf)
  (let ((path (buffer-path buf)))
    (if (and (string? path) (not (equal? path "")))
        path
        (string-append (default-directory) (write-file-default-name buf)))))

;;; --- delete-file ---------------------------------------------------------------
;;; Emacs delete-file, as a command. The prompt starts on this buffer's
;;; file, and a yes-or-no question stands between RET and the disk. The
;;; file goes to the trash (Emacs delete-by-moving-to-trash); a prefix
;;; argument deletes it for good. A buffer that visits the file stays:
;;; its text is still yours, as in Emacs.

;; what the prompt offers first: this buffer's file, else the directory
(define (delete-file-default buf)
  (or (buffer-path buf) (default-directory)))

;; trash or delete PATH. -> the path acted on, or #f when nothing is there
(define (delete-file-path! path permanent?)
  (let ((full (expand-path (normalize-file-input path))))
    (cond ((not (or (file-exists? full) (file-directory? full))) #f)
          (permanent? (delete-file! full) full)
          (else (trash-file! full) full))))

(define (delete-file--ask! path permanent?)
  (let ((full (expand-path (normalize-file-input path))))
    (if (not (or (file-exists? full) (file-directory? full)))
        (message (string-append "No such file: " (abbreviate-file-name full)))
        (yes-or-no?
          (string-append (if permanent? "Delete permanently " "Move to trash ")
                         (abbreviate-file-name full) "?")
          (lambda (yes)
            (if (not yes)
                (message "Cancelled")
                (begin
                  (delete-file-path! full permanent?)
                  (message (string-append (if permanent? "Deleted " "Trashed ")
                                          (abbreviate-file-name full))))))))))

(define-command "delete-file"
  "Delete a file, this buffer's by default: to the trash, or for good with a prefix argument"
  (interactive 'P)
  (lambda (arg)
    (read-file-name-initial "Delete file: " (delete-file-default (current-buffer))
      (lambda (input) (delete-file--ask! input (and arg #t))))))

(public! 'delete-file-path!
  "(delete-file-path! PATH PERMANENT?) — move PATH to the trash, or delete it when PERMANENT?; the path, or #f when nothing is there")

(define-command "write-file" "Write the buffer to a file; the buffer becomes that file's buffer"
  (lambda ()
    (let ((old (current-buffer)))
      ;; the answer names a NEW file: RET writes the typed text, and a
      ;; fuzzy match on a file already there does not take the write.
      ;; C-n and TAB still pick a candidate on purpose.
      (read-file-name-initial (string-append "Write " old " to file: ")
        (write-file-default-path old)
        (lambda (p) (write-buffer-to-file! old p))
        (list (list 'preselect 'prompt))))))

;; Save a buffer that is not the current one. save-buffer acts on the
;; current buffer, and it must: the remote, chat and no-file branches all
;; read it. So the save borrows the window and gives it back. A caller
;; that saves a whole set — save-some-buffers, project-kill-all — needs
;; exactly this and nothing more.
(define (save-buffer-named! b)
  (let ((here (current-buffer)))
    (switch-to-buffer-here! b)
    (run-command "save-buffer")
    (when (buffer-exists? here) (switch-to-buffer-here! here))))

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
;;
;; UNREAD? binds the buffer to the file without reading it. The file is
;; shown from disk by its own viewer, so the buffer holds no bytes: see
;; file-shown-from-disk? below and browser-file-mode.
(define (find-file path &optional session-only? unread?)
  (let* ((name (expand-path (normalize-file-input path)))
         (new (not (buffer-known? name)))
         (buf (raw-find-file name (not session-only?) (not unread?))))
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
;; exactly as typed. OPTS is an alist of extra prompt options, such as
;; (preselect prompt).
;; match-hint: the annotation names the mode the file opens in, so "dired"
;; narrows the listing to the directories and "elixir" to the .ex files.
(define (read-file-name-initial prompt initial k &optional opts)
  (let* ((dd (default-directory))
         (seed (if (and (string? initial) (not (equal? initial ""))) initial dd))
         (seed-dir (car (path-split (normalize-file-input seed))))
         (dir (if (equal? seed-dir "") dd seed-dir)))
    (set! *file-nav-dir* dir)
    (let ((cands (file-candidates dir (list-dir dir))))
      (minibuffer-read* prompt cands
        (append
          (list (list 'complete file-complete)
                (list 'change file-nav-change)
                (list 'initial seed)
                ;; the icon leads the annotation, so the mode is the second
                ;; field: both must be in reach for "dired" to find a directory
                (list 'match-hint 2)
                (list 'style #f)
                (list 'confirm k))
          (or opts '()))))))

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

;;; --- visiting a file --------------------------------------------------------
;;; visit is the one door: a path becomes a buffer, joins a group, and a
;;; path under /ssh: goes through tramp.scm. find-file is its prompt.

(define (agent-edit-author? author)
  (and (string? author) (string-prefix? "agent:" author)))

(define (visit-apply-group! buf group existing)
  (when (and buf group)
    (if existing
        (buffer-add-group! buf group)
        (buffer-move-to-group! buf group))))

;;; A file too big to open
;;;
;;; Emacs asks before it visits a large file (large-file-warning-threshold,
;;; 10 MB). Here the read is the small half of the cost. The text becomes a
;;; rope, the rope becomes a checkpoint on disk, the checkpoint restores at
;;; every boot, and the renderer builds segments for every line. A 189 MB
;;; screen recording opened by accident wrote a 361 MB checkpoint, pinned
;;; the Editor for seven seconds on each boot, and through that took the
;;; desktop's own globals down with it.
;;;
;;; So a visit REFUSES, and the reader who means it answers a question. The
;;; refusal is the mechanism, the question is the policy, and a caller that
;;; cannot ask one — an agent, a restore, a peek — gets the refusal.
;;;
;;; layouts.scm makes the variable customizable.

(define large-file-warning-threshold 10485760)

;; #t when PATH opens in a viewer that reads the file from disk itself: a
;; picture, a sound, a video. The buffer is bound to the path and holds no
;; bytes, so the size of the file costs the editor nothing and no cap here
;; applies to it. file-view.scm answers which files those are.
(define (file-shown-from-disk? path)
  (and (string? path)
       (boundp (quote browser-file-path?))
       (browser-file-path? (normalize-file-input path))
       #t))

;; #t when the buffer was bound to its file and never read it. Nothing in
;; it stands for the file: it must not be saved over it, and following the
;; file would read the bytes the viewer exists to avoid.
(define (buffer-unread-file? buf)
  (and (buffer-known? buf)
       (buffer-local buf 'unread-file)
       #t))

;; #t when opening PATH would cost more than a file should. A path with a
;; buffer already answers #f: the work is paid. A directory and a remote
;; path answer #f, because file-size reads local files only. A file shown
;; from disk answers #f whatever its size: it is never read.
(define (file-too-big? path)
  (and (> large-file-warning-threshold 0)
       (string? path)
       (not (file-shown-from-disk? path))
       (let ((p (normalize-file-input path)))
         (and (not (buffer-known? p))
              (not (remote-path? p))
              (not (file-directory? p))
              (> (file-size p) large-file-warning-threshold)))))

;; Say the size, and say the way in. The reader reaches the file through
;; the question, so the message names the command that asks it.
(define (file-too-big-message path)
  (let ((p (normalize-file-input path)))
    (string-append (cadr (path-split p)) " is " (cadr (file-stat p))
                   ", over large-file-warning-threshold. "
                   "M-x find-file asks before it opens it.")))

;; The way in. The buffer is not persistent: it holds the file for this
;; session, writes no checkpoint, and is not there at the next boot. That
;; is the whole point — one yes must not cost every later boot.
(define (visit-anyway path0 &optional group)
  (let* ((path (normalize-file-input path0))
         (existing (buffer-known? path))
         ;; session-only: no checkpoint, and no work at the next boot
         (file-buffer (find-file path #t)))
    (visit-apply-group! file-buffer group existing)
    (switch-to-buffer! file-buffer)
    (auto-mode path)
    (run-hooks 'find-file-hook)
    (message (string-append (cadr (path-split path))
                            " is open for this session only; it is not saved across a restart."))
    (current-buffer)))

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
             ((file-too-big? path) (message (file-too-big-message path)) #f)
             (else
               (let ((file-buffer (find-file path #f (file-shown-from-disk? path))))
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
;; its way to the look (find-file-noselect).
(define (visit-quietly path0 &optional group)
  (let* ((path (normalize-file-input path0))
         (existing (buffer-known? path)))
    (if (or (remote-path? path) (file-directory? path))
        (visit path group)
      (if (file-too-big? path)
          (begin (message (file-too-big-message path)) #f)
        (let ((file-buffer (find-file path #f (file-shown-from-disk? path))))
          (visit-apply-group! file-buffer group existing)
          (with-current-buffer file-buffer
            (lambda ()
              (auto-mode path)
              (run-hooks 'find-file-hook)))
          file-buffer)))))

;; Compatibility name for packages and user config.
(define (visit-in-group path group) (visit path group))

;; A package supplies the prefix reader through the keyed hook
;; (find-file-group-reader KEY). Its callback receives the chosen group.
;; Without one the frame's group is the answer. This keeps the prefix
;; mechanism separate from file completion.
(define (find-file-group-reader receive)
  (let ((fs (hook-functions 'find-file-group-reader)))
    (if (pair? fs) ((car fs) receive) (receive (frame-group)))))

(define (find-file-read &optional group)
  (read-file-name "Find file: "
    (lambda (path)
      (let* ((normalized (normalize-file-input path))
             (existing (buffer-known? normalized)))
        (if (file-too-big? normalized)
            ;; the reader is here, so the reader can answer
            (y-or-n?
              (string-append (cadr (path-split normalized)) " is "
                             (cadr (file-stat normalized))
                             ". Open it for this session only?")
              (lambda (yes)
                (when yes (visit-anyway normalized (if existing #f group)))))
            (visit normalized (if existing #f group)))))))

(define-command "find-file" "Visit a file, prompting with filename completion"
  (lambda ()
    (if (current-prefix-arg)
        (find-file-group-reader find-file-read)
        (find-file-read (frame-group)))))
(catalog-meta! 'command "find-file" 'domain 'buffers 'effects '(write display))

;; the project a buffer belongs to, as a short name for the prompt.
;; project.scm supplies the real answers through the keyed hooks
;; (buffer-project-label KEY) and (buffer-project-root KEY); without the
;; package every buffer is projectless. A workspace package adds one
;; concise identity column to C-x b through (buffer-workspace-label KEY).
(define (buffer-project-label b)
  (or (run-hook-with-args-until-success 'buffer-project-label b) ""))

(define (buffer-workspace-label b)
  (or (run-hook-with-args-until-success 'buffer-workspace-label b) ""))

;; ...and as the ROOT, for context switching (a project is also a group)
(define (buffer-project-root b)
  (or (run-hook-with-args-until-success 'buffer-project-root b) ""))

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
(define (switch-buffer-source cands)
  (let ((fs (hook-functions 'switch-buffer-source)))
    (if (pair? fs)
        ((car fs) cands)
        (list cands (current-buffer) (lambda (picked) #f)))))

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
        (map buffer-short-label (take (group-buffers-mru g) 4))))

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

;; Packages can repair windows after the core releases a killed buffer.
;; The callback returns a thunk because its policy must inspect the old buffer
;; before the core removes it, then repair the surviving windows afterwards.
(define buffer-kill-raw!
  (if (boundp 'buffer-kill-raw!) buffer-kill-raw! buffer-kill!))
;; the repair a kill runs after the buffer is gone: the keyed hook
;; (buffer-kill-repair KEY) answers with a thunk, none means nothing to do
(define (buffer-kill-repair name)
  (or (run-hook-with-args-until-success 'buffer-kill-repair name) (lambda () #f)))

(define (buffer-kill! name)
  (let ((repair (buffer-kill-repair name)))
    (buffer-kill-raw! name)
    (keymap--forget-buffer! name)
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

(domain! 'processes)
(effects! '(write execute))

;;; --- minibuffer history (vertico-style: last-used first) --------------------
;;; The candidate ranking in the core is a stable sort, so passing
;;; candidates history-first keeps them first among equal matches — the
;;; empty prompt shows pure recency, typing re-ranks fuzzily within it.

(defvar '*minibuffer-history* '() 'persist #t)  ; ((key (item ...)) ...), most recent first
(define *minibuffer-history-max* 50)

;; savehist: which commands, themes and searches you use is worth more
;; than one session. Every keyed history rides in this one variable, so
;; M-x, apropos, project, ripgrep and the theme prompt all persist here.
(define (history-items key)
  (let ((e (assoc key *minibuffer-history*)))
    (if e (cadr e) '())))

(define (history-push! key item)
  (let ((items (cons item (filter (lambda (x) (not (equal? x item)))
                                  (history-items key)))))
    (set! *minibuffer-history* (alist-put *minibuffer-history* key (take items *minibuffer-history-max*)))))

;; forget one entry, as if it had never been chosen
(define (history-remove! key item)
  (set! *minibuffer-history*
        (alist-put *minibuffer-history* key
                   (filter (lambda (x) (not (equal? x item))) (history-items key)))))

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
      (set! *mb-history-key* 'M-x)
      (set! *mb-history-pos* -1)
      (minibuffer-read* "M-x "
        (annotate 'command (history-order 'M-x (command-names)))
        (list (list 'confirm
                (lambda (cmd)
                  (set! *mb-history-key* #f)
                  (history-push! 'M-x cmd)
                  (when prefix (set-prefix-arg! prefix))
                  (run-command cmd)
                  (when prefix (set-prefix-arg! #f))))
              (list 'cancel (lambda () (set! *mb-history-key* #f)))
              (list 'style #f))))))

(domain! 'unknown)
(effects! '(unknown))

;; One form, run and forgotten, is still a form you ran: M-p in this prompt
;; walks it back. The ring is 'scheme-eval, which the *scheme* buffer walks
;; too (repl.scm), so the two surfaces have one past between them.
(define-command "eval-expression" "Evaluate a Scheme expression from the minibuffer"
  (lambda ()
    (completing-read "Eval: " '()
      (lambda (src) (message (value->string (eval-string src))))
      'history 'scheme-eval)))

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

(define-command "eval-last-sexp" "Evaluate the region, else the sexp before point, and echo the value"
  (lambda ()
    ;; A selection is an explicit statement of what to run, so it wins
    ;; over the sexp before point. With no selection this is the Emacs
    ;; command unchanged. region-action-bounds, not the raw mark, so a
    ;; mode's region lifter still says what its selection covers.
    (let* ((buf (current-buffer))
           (bounds (region-action-bounds))
           (rs (car bounds))
           (re (cadr bounds)))
      (if (< rs re)
          (echo-value (eval-region buf rs re))
          (let* ((p (eval-skip-ws-back (point)))
                 (s (last-sexp-start p)))
            (if (< s p)
                (echo-value (eval-region buf s p))
                (message "No sexp before point")))))))

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
    (run-hooks 'universal-argument-hook)
    (let ((raw (current-prefix-arg)))
      (set-prefix-arg!
        (cond ((number? raw) (list (* raw 4)))
              ((and (pair? raw) (number? (car raw))) (list (* (car raw) 4)))
              ((equal? raw '-) (list -4))
              (else (list 4)))))))

(define-command "digit-argument" "Add a digit to the next command's prefix argument"
  (lambda ()
    (run-hooks 'universal-argument-hook)
    (let* ((raw (current-prefix-arg))
           (key (car (reverse (last-keys))))
           ;; "1" after C-u, or "M-1" on its own: the digit is the last character
           (digit (string->number (substring key (- (string-length key) 1) (string-length key))))
           (negative? (or (equal? raw '-) (and (number? raw) (< raw 0))))
           (base (if (number? raw) (abs raw) 0))
           (value (+ (* base 10) digit)))
      (set-prefix-arg! (if negative? (- value) value)))))

(define-command "negative-argument" "Negate the next command's prefix argument"
  (lambda ()
    (run-hooks 'universal-argument-hook)
    (let ((raw (current-prefix-arg)))
      (set-prefix-arg!
        (cond ((number? raw) (- raw))
              ((equal? raw '-) 1)
              (else '-))))))

(undo-exempt! "universal-argument")
(undo-exempt! "digit-argument")
(undo-exempt! "negative-argument")

;; Emacs's universal-argument-map: while a prefix argument is pending, the
;; digits, - and C-u come from this map, the frame's overriding map until
;; the next command. Every prefix command arms it.
(define-keymap! "universal-argument-map")
(for-each (lambda (d) (define-key "universal-argument-map" d "digit-argument"))
          '("0" "1" "2" "3" "4" "5" "6" "7" "8" "9"))
(define-key "universal-argument-map" "-" "negative-argument")
(define-key "universal-argument-map" "C-u" "universal-argument")

(define (universal-argument--arm!)
  (overriding-map! "universal-argument-map" #f #t))

(add-hook! 'universal-argument-hook 'universal-argument--arm!)

;; M-1 .. M-9, M-0 and M-- are the digit arguments, as in Emacs
(for-each (lambda (d) (global-set-key (string-append "M-" d) "digit-argument"))
          '("0" "1" "2" "3" "4" "5" "6" "7" "8" "9"))
(global-set-key "M--" "negative-argument")

;;; --- the prefix keymaps -------------------------------------------------------
;;; A prefix key leads to a keymap, as C-x leads to ctl-x-map in Emacs: the
;;; binding's value is (keymap NAME), and the rest of the sequence resolves
;;; in that keymap. A package binds into the map its keys belong to and
;;; never writes the global map; the global map belongs to the user's
;;; init. The names are Emacs's where Emacs has them.

(define (define-prefix-command name)
  (define-keymap! name)
  name)

;; (bind-prefix! MAP KEYS NAME): in MAP, KEYS leads to the keymap NAME
(define (bind-prefix! map keys name)
  (define-prefix-command name)
  (if (equal? map "global")
      (global-set-key keys (list 'keymap name))
      (define-key map keys (list 'keymap name))))

(bind-prefix! "global" "C-x" "ctl-x-map")
(bind-prefix! "global" "C-c" "mode-specific-map")
(bind-prefix! "global" "C-h" "help-map")
(bind-prefix! "global" "M-g" "goto-map")
(bind-prefix! "global" "M-s" "search-map")
(bind-prefix! "ctl-x-map" "r" "ctl-x-r-map")
(bind-prefix! "ctl-x-map" "4" "ctl-x-4-map")
(bind-prefix! "ctl-x-map" "p" "project-prefix-map")
(bind-prefix! "ctl-x-map" "v" "vc-prefix-map")
(bind-prefix! "ctl-x-map" "C-g" "buffer-group-map")
(bind-prefix! "mode-specific-map" "a" "agent-map")
(bind-prefix! "mode-specific-map" "S" "spotify-map")
(bind-prefix! "mode-specific-map" "!" "annotate-map")

;;; --- self-insert-command --------------------------------------------------------
;;; Every printable key and SPC are bound to self-insert-command in the
;;; global map, as in Emacs, so a key that inserts itself reaches that
;;; command through a keymap like any other, and a mode can rebind a
;;; letter. The dispatcher inserts the key itself, with the count and
;;; the region rule; the command body below serves M-x and command-call.

(define self-insert--printables
  (string-append
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"))

(define (self-insert--keys)
  (let loop ((i 0) (acc (list "SPC")))
    (if (>= i (string-length self-insert--printables))
        (reverse acc)
        (loop (+ i 1) (cons (substring self-insert--printables i (+ i 1)) acc)))))

(define-command "self-insert-command" "Insert the character you typed" (interactive 'p)
  (lambda (n)
    (let* ((ks (last-keys))
           (k (if (pair? ks) (car (reverse ks)) ""))
           (ch (cond ((equal? k "SPC") " ")
                     ((= (string-length k) 1) k)
                     (else ""))))
      (repeat-count n (lambda () (insert! ch))))))

(for-each (lambda (k) (global-set-key k "self-insert-command")) (self-insert--keys))
;; and into the completion popup: typing narrows it in place
(for-each (lambda (k) (local-set-key* " *completion*" k "self-insert-command")) (self-insert--keys))

(public! 'interactive "(interactive CODE ...) — a command's argument spec: 'p numeric prefix, 'P raw prefix, 'r region start and end, 'b buffer, 'd point, 'm mark, \"sPrompt: \" a string, \"nPrompt: \" a number, \"fPrompt: \" a file")
(public! 'command-call "(command-call NAME ARG ...) — run a command's function with explicit arguments")
(public! 'command-function "(command-function NAME) — the function behind a command, or #f")
(public! 'call-interactively "(call-interactively NAME) — run NAME as a key would, collecting its arguments from the spec")
(public! 'kill-text! "(kill-text! TEXT [BEFORE?]) — TEXT onto the kill ring: appended to the newest entry after a kill command, else as a new entry")
(public! 'kill-new "(kill-new TEXT) — a new kill-ring entry")
(public! 'prefix-numeric-value
  "(prefix-numeric-value RAW) -> RAW as an integer; #f becomes 1")

(domain! 'unknown)
(effects! '(unknown))

(define-command "keyboard-quit" "Quit the current operation: cancel the prompt, close the dashboard, or clear the mark"
  (lambda ()
    (editing-quit!)
    (set-mark! #f)
    (cond
      ;; A prompt IS the current operation, and a modal prompt is the
      ;; whole screen. Escape runs this command, so a reader who answers
      ;; a dialog with the key every dialog answers to had the prompt
      ;; stay put: only C-g reached minibuffer-cancel. Quit the prompt
      ;; first, and both keys say the same thing.
      ((minibuffer-active?) (minibuffer-cancel!))
      ;; C-g closes the dashboard panel too, so the key that opened it
      ;; is not the only key that puts it away
      (else (dashboard-panel-close! (current-buffer))
            (message "Quit")))))
(catalog-meta! 'command "keyboard-quit" 'domain 'interaction 'effects '(write))

;;; --- the movement state and the editing state ------------------------------
;;; An editable buffer has two states, and neither is a mode. The user lands
;;; on a window in the movement state: the Cmd-arrows move the focus. The first
;;; command that is not keyboard-quit enters the editing state: the state's
;;; maps are in force, ahead of the buffer's maps, and the Cmd-arrows on
;;; editing-caret-map move point to the line and buffer ends. A mode may
;;; refuse a map of the state (editing-state-maps-off!): chat-mode refuses
;;; the caret map, so a chat answers the Cmd-arrows with the window motion
;;; whether it is armed or not. keyboard-quit (ESC,
;;; C-g) returns the buffer to the movement state. A change of the active
;;; window or of its buffer is a new landing. A read-only buffer stays in the
;;; movement state. The client keeps the same state for a contenteditable
;;; surface (layouts.ex editingAfterKey), where the Cmd-arrows are native in
;;; the editing state and never reach this map.
(define-keymap! "editing-state-map")

;; The Cmd-arrows the editing state hands to the caret sit on a map of
;; their own, so a mode can refuse that map and keep the chords for window
;; motion. A chat is such a mode: you type in it without pause, so it would
;; hold the Cmd-arrows for good. The unset drops the bindings a reload left
;; on editing-state-map, which is now the state's marker and nothing else.
(for-each (lambda (k) (keymap-unset! "editing-state-map" k))
          '("s-<left>" "s-<right>" "s-<up>" "s-<down>"))
(define-keymap! "editing-caret-map")
(define-key "editing-caret-map" "s-<left>" "beginning-of-line")
(define-key "editing-caret-map" "s-<right>" "end-of-line")
;; Cmd-up and Cmd-down always walk the group (groups.scm), in every state.
(for-each (lambda (k) (keymap-unset! "editing-caret-map" k)) '("s-<up>" "s-<down>"))

(define *editing-landing* '())  ; ((frame window buffer) ...) the last landing of each frame

(define (editing-state? buf)
  (if (member "editing-state-map" (buffer-minor-maps buf)) #t #f))

;; The maps the editing state puts in force in the buffer. editing-state-map
;; is the state's marker; editing-caret-map holds the Cmd-arrows; cua.scm
;; adds cua-mode-map, so the Shift selections answer in a buffer you are
;; editing and a buffer you have just landed on keeps the plain meaning of
;; those chords. The ladder reads a minor map's own bindings and not its
;; parents, so a map that must answer here is on this list and not a parent
;; of another.
(define *editing-state-maps* '("editing-state-map" "editing-caret-map"))

(define (editing-state-maps! names)
  (for-each (lambda (n)
              (unless (member n *editing-state-maps*)
                (set! *editing-state-maps* (append *editing-state-maps* (list n)))))
            names))

(define (editing-state-maps-drop! names)
  (set! *editing-state-maps*
    (remove (lambda (m) (member m names)) *editing-state-maps*)))

;; A mode can refuse one of those maps, by name, for its buffers. The
;; marker map is not refusable: it is what says the buffer is in the state.
(define *editing-state-maps-off* '())   ; ((MODE (MAP ...)) ...)

(define (editing-state-maps-off! mode names)
  (set! *editing-state-maps-off* (alist-put *editing-state-maps-off* mode (remove (lambda (m) (equal? m "editing-state-map")) names))))

(define (editing--maps-for buf)
  (let ((off '()))
    (for-each (lambda (e)
                (when (buffer-derived-mode? buf (car e))
                  (set! off (append off (cadr e)))))
              *editing-state-maps-off*)
    (if (null? off)
        *editing-state-maps*
        (remove (lambda (m) (member m off)) *editing-state-maps*))))

;; A chat keeps the Cmd-arrows on the window motion, armed or not: it is a
;; conversation you type in without pause, and a buffer that never returns
;; to the movement state would never answer the focus chords again.
(editing-state-maps-off! "chat-mode" '("editing-caret-map"))

;; The state is a fact the presentation carries: the header line's state
;; tag is what the window's ground reads -- a cua window sits, a focus
;; window floats -- and nothing else invalidates that line when the maps go
;; in or out. Without this the window keeps the ground it last drew, so a
;; buffer you had begun to edit went on floating until some unrelated event
;; refreshed its header. The hook carries the buffer.
(define (editing--state-changed! buf)
  (run-hook-with-args 'editing-state-hook buf))

(define (editing-state-on! buf)
  (let ((was (editing-state? buf)))
    (unless was
      (buffer-minor-maps! buf (append (editing--maps-for buf) (buffer-minor-maps buf))))
    (unless (equal? (buffer-local buf 'editing-state) #t)
      (buffer-set-local! buf 'editing-state #t)
      (desktop-skip! buf 'editing-state))
    (unless was (editing--state-changed! buf))))

(define (editing-state-off! buf)
  (let ((was (or (editing-state? buf) (and (buffer-local buf 'editing-state) #t))))
    (when (editing-state? buf)
      (buffer-minor-maps! buf
        (remove (lambda (m) (member m *editing-state-maps*)) (buffer-minor-maps buf))))
    (when (buffer-local buf 'editing-state)
      (buffer-set-local! buf 'editing-state #f))
    (when was (editing--state-changed! buf))))

(define (editing--landing)
  (let ((w (active-window)))
    (and w (list (selected-frame) w (window-buffer w)))))

;; a new landing starts in the movement state. Each frame keeps its own:
;; a window change in another frame is not a landing here, and with one
;; record for all of them it put the buffer you were typing in back in
;; the movement state at your next key.
(define (editing--check-landing!)
  (let ((here (editing--landing)))
    (when (and here (not (member here *editing-landing*)))
      (set! *editing-landing*
        (cons here (remove (lambda (l) (equal? (car l) (car here))) *editing-landing*)))
      (let ((buf (caddr here)))
        (when (and buf (buffer-exists? buf))
          (editing-state-off! buf))))))

;; after a command: CMD is the command that ran. A named command is still
;; this-command when post-command-hook runs; a self-insert has finished
;; and is last-command.
(define (editing--command-name)
  (let ((this (this-command)))
    (if (and (string? this) (not (equal? this "")))
        this
        (last-command))))

;; A quit returns the buffer to the movement state. keyboard-quit is one.
;; A command that runs keyboard-quit inside itself (chat-abort when no
;; reply runs) is one too: keyboard-quit sets this flag, and the hook
;; reads it after the outer command, whatever that command is named.
(define *editing-quit* #f)
(define (editing-quit!) (set! *editing-quit* #t))

;; A window command (split, delete, layout, an arrow move) changes what you
;; look at, not the text. It is a landing: the buffer returns to the
;; movement state, and the next Cmd-arrow moves the focus. The catalog's
;; domain says which commands those are. One lookup walks the whole
;; catalog (4ms), so the answer is kept per command name until the
;; catalog changes.
(define *editing--domain-cache* '())
(define *editing--domain-gen* -1)

;; The directional commands are window commands by name, so a
;; redefinition that loses their catalog domain still counts as a landing.
(define *direction-command-names*
  '("focus-left" "focus-right" "focus-up" "focus-down"
    "window-left" "window-right" "window-up" "window-down"
    "buffer-left" "buffer-right" "buffer-up" "buffer-down"))

(define (editing--window-command? cmd)
  (and (string? cmd)
       (or (and (member cmd *direction-command-names*) #t)
           (begin
             (unless (equal? *editing--domain-gen* (catalog-generation))
               (set! *editing--domain-cache* '())
               (set! *editing--domain-gen* (catalog-generation)))
             (let ((hit (assoc cmd *editing--domain-cache*)))
               (if hit
                   (cadr hit)
                   (let* ((e (catalog-entry 'command cmd))
                          (yes (if (and e (equal? (catalog--get e 'domain) "windows")) #t #f)))
                     (set! *editing--domain-cache* (cons (list cmd yes) *editing--domain-cache*))
                     yes)))))))

;; A Shift chord is the selection keys' own chord. Pressing one says
;; nothing about whether you are editing this buffer, so it leaves the
;; state as it found it: cua.scm and groups.scm name the commands those
;; chords run, and every other key still arms the editing state.
(define *editing-neutral-commands* '())

(define (editing-neutral-commands! names)
  (for-each (lambda (n)
              (unless (member n *editing-neutral-commands*)
                (set! *editing-neutral-commands* (cons n *editing-neutral-commands*))))
            names))

(define (editing-neutral-command? cmd)
  (if (and (string? cmd) (member cmd *editing-neutral-commands*)) #t #f))

(define (editing--after-command! &optional cmd)
  (let ((buf (current-buffer))
        (cmd (or cmd (editing--command-name)))
        (quit *editing-quit*))
    (set! *editing-quit* #f)
    (cond ((not (and buf (buffer-exists? buf))) #t)
          ;; a terminal is read-only text, yet it is a place you type: its
          ;; editing state hands the keyboard to the terminal itself
          ((and (buffer-read-only? buf) (not (buffer-local buf 'takes-keyboard)))
           (editing-state-off! buf))
          ((or quit (equal? cmd "keyboard-quit")) (editing-state-off! buf))
          ((editing-neutral-command? cmd) #t)
          ((equal? cmd "self-insert-command") (editing-state-on! buf))
          ((editing--window-command? cmd) (editing-state-off! buf))
          (else (editing-state-on! buf)))))

(add-hook! 'window-configuration-change-hook 'editing--check-landing!)
(add-hook! 'pre-command-hook 'editing--check-landing!)
(add-hook! 'post-command-hook 'editing--after-command!)

(catalog-meta! 'function "editing-state?" 'domain 'windows 'effects '(read))
(catalog-meta! 'function "editing-state-on!" 'domain 'windows 'effects '(write))
(catalog-meta! 'function "editing-state-off!" 'domain 'windows 'effects '(write))
(catalog-meta! 'function "editing-quit!" 'domain 'windows 'effects '(write))
(catalog-meta! 'function "editing-state-maps!" 'domain 'windows 'effects '(write))
(catalog-meta! 'function "editing-state-maps-drop!" 'domain 'windows 'effects '(write))
(catalog-meta! 'function "editing-state-maps-off!" 'domain 'windows 'effects '(write))
(catalog-meta! 'function "editing-neutral-commands!" 'domain 'windows 'effects '(write))
(catalog-meta! 'function "editing-neutral-command?" 'domain 'windows 'effects '(read))

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
                           ;; in a group, the ring cycles the group
                           (not (display-foreign? b))
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
;; Emacs bury-buffer: BUF goes to the end of the buffer list, and the
;; selected window, when it shows BUF, shows the buffer it had before
(define (bury-buffer! buf)
  (buffer-bury! buf)
  (when (equal? (window-buffer (active-window)) buf)
    (let* ((prev (filter (lambda (b) (and (not (equal? b buf)) (buffer-known? b)))
                         (window-prev-buffers)))
           (other (filter (lambda (b) (not (equal? b buf))) (buffer-list-mru)))
           (next (cond ((pair? prev) (car prev))
                       ((pair? other) (car other))
                       (else #f))))
      (when next (switch-to-buffer-here! next)))))

;; Emacs unbury-buffer: switch to the last buffer in the buffer list
(define (unbury-buffer!)
  (let ((bs (buffer-list-mru)))
    (if (null? bs)
        (message "No buffer to unbury")
        (switch-to-buffer! (car (reverse bs))))))

(define-command "bury-buffer" "Put this buffer at the end of the buffer list; its window shows the one before"
  (lambda () (bury-buffer! (current-buffer))))
(define-command "unbury-buffer" "Switch to the last buffer in the buffer list"
  (lambda () (unbury-buffer!)))
(catalog-meta! 'command "bury-buffer" 'domain 'buffers 'effects '(write display))
(catalog-meta! 'command "unbury-buffer" 'domain 'buffers 'effects '(write display))
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

;; (add-hook! (list 'input-intent TYPE) FN): FN takes (from to text) and
;; returns #t when it handled the intent. A mode registers "formatBold" here.

(define (input-intent--replace! from to text)
  (goto-char! from)
  (set-mark! to)
  (delete-region!)
  (set-mark! #f)
  (goto-char! from)
  (when (> (string-length text) 0) (insert! text))
  #t)

(define (input-intent! type from to text)
  (let ()
    (cond
      ((run-hook-with-args-until-success (list 'input-intent type) from to text) #t)
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
      ;; a soft line is the visual row when the wrap map can say
      ((and (= from to) (member type '("deleteSoftLineBackward" "deleteHardLineBackward")))
       (let* ((bol (line-start-position (line-number-at-pos (point))))
              (row (and (equal? type "deleteSoftLineBackward") (visual-row-start (point))))
              (start (if (and row (< row (point))) row bol)))
         (input-intent--replace! start (point) "")))
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
        ;; the header line's theme word opens the theme picker
        ((member cmd '("dismiss-buffer" "listing-peek-dismiss" "load-theme"))
         (run-command cmd))
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
  (or (buffer-derived-mode? buf mode)
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
    (set-mark! #f)
    ;; A prompt is an ordinary buffer, so the text went into it. Only the key
    ;; path tells the prompt what its buffer now says, and a paste arrives off
    ;; that path, so say it here and let the prompt's live filter run.
    (when (minibuffer-active?)
      (minibuffer-change! (buffer-text (minibuffer-buffer))))))

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
                  (permit? tool-buf "restart-daemon" "command" "")))
            (if (member verdict '(allow allow-always))
                (restart-daemon-now!)
                (error "restart-daemon requires user permission")))
          (y-or-n "Restart the daemon?" restart-daemon-now!)))))

(domain! 'unknown)
(effects! '(unknown))

;;; --- default keymap --------------------------------------------------------

;; Cmd-p is intent search; M-x remains literal command-name completion.
(global-set-key "s-p" "command-palette")
;; winner: any layout change is one keystroke from undone
(global-set-key "C-c <left>" "winner-previous")
(global-set-key "C-c <right>" "winner-next")
;; the modeline, expanded — also a click on the modeline's name
(global-set-key "C-x ?" "modeline-expand")

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
(global-set-key "C-x u" "undo")
(global-set-key "C-g" "keyboard-quit")
(global-set-key "C-u" "universal-argument")
;; ESC quits, like C-g. Emacs makes a lone ESC the Meta prefix; here it
;; echoed "ESC-" and waited, and the user presses ESC to leave the editing
;; state of a buffer (layouts.ex editingAfterKey). Meta is the Option key.
;; Dispatch still translates an unbound ESC k to M-k in a map that leaves
;; ESC unbound.
(global-set-key "ESC" "keyboard-quit")

(global-set-key "M-f" "forward-word")
(global-set-key "M-b" "backward-word")
(global-set-key "M-d" "kill-word")
(global-set-key "M-DEL" "backward-kill-word")
(global-set-key "M-y" "yank-pop")
(global-set-key "TAB" "indent-for-tab")
(global-set-key "M-g g" "goto-line")
(global-set-key "M-g M-g" "goto-line")
(global-set-key "M-m" "back-to-indentation")
(global-set-key "C-c l" "copy-buffer-link")
(global-set-key "C-c C-v" "preview-mode")
(global-set-key "C-c C-a" "app-preview")
(global-set-key "C-c C-r" "app-reload")
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
;; macOS gives C-SPC to the input-source switch, so the mark has a second
;; key. Emacs' own M-SPC (cycle-spacing) is not bound here.
(global-set-key "M-SPC" "set-mark-command")
(global-set-key "C-w" "kill-region")
(global-set-key "M-w" "copy-region-as-kill")
(global-set-key "C-x C-x" "exchange-point-and-mark")
(global-set-key "C-x C-SPC" "pop-global-mark")
(global-set-key "C-s" "isearch-forward")
(global-set-key "C-r" "isearch-backward")
(global-set-key "M-%" "query-replace")

(global-set-key "C-x C-f" "find-file")
(global-set-key "C-x C-s" "save-buffer")
(global-set-key "C-x C-w" "write-file")
(global-set-key "C-x k" "kill-buffer")
(global-set-key "C-x n n" "narrow-to-region")
(global-set-key "C-x n N" "narrow-context-also")
(global-set-key "C-x n w" "widen")

(global-set-key "M-x" "execute-extended-command")
(global-set-key "M-:" "eval-expression")
(global-set-key "C-x C-e" "eval-last-sexp")

(global-set-key "C-x 2" "split-window-below")
(global-set-key "C-x 3" "split-window-right")
(global-set-key "C-x 0" "delete-window")
(global-set-key "C-x 1" "delete-other-windows")
(global-set-key "C-x e" "window-eat")
(global-set-key "C-x o" "other-window")
;; Layout selection has its own prefix; l retains the preview chooser.
(define-key "ctl-x-map" "l" "window-layout")
(for-each
  (lambda (binding) (define-key "layout-map" (car binding) (cadr binding)))
  '(("l" "window-layout")
    ("1" "window-layout-single")
    ("2" "window-layout-two-pane")
    ("=" "window-layout-halves")
    ("c" "window-layout-columns")
    ("r" "window-layout-rows")
    ("f" "window-layout-free")
    ;; the layouts go on for ever: these move the panes along the strip
    ("<right>" "layout-forward")
    ("<left>" "layout-backward")))
;; Cmd-arrows move the focus; Cmd-Shift-arrows swap the two panes
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
(public! 'buffer-ref "(buffer-ref BUF) — immutable handle for buffer-local reads and writes across renames, or #f if unknown")
(public! 'buffer-known? "(buffer-known? NAME) -> bool: live OR dormant. A list shows dormant buffers, so a verb asks this one")
(catalog-meta! 'function "buffer-known?" 'domain 'buffers 'effects '(read))
(effects! '(write))
(public! 'buffer-sleep! "(buffer-sleep! NAME) — checkpoint NAME and stop its process; the buffer stays known. #f when NAME is on screen, busy, or pinned")
(catalog-meta! 'function "buffer-sleep!" 'domain 'buffers 'effects '(write))
(public! 'buffer-last-seen "(buffer-last-seen NAME) — unix seconds when NAME was last shown in the active window, or #f; reads without waking a dormant buffer")
(catalog-meta! 'function "buffer-last-seen" 'domain 'buffers 'effects '(read))
(public! 'buffer-note-seen! "(buffer-note-seen! NAME) — stamp NAME as seen now, at most one write a minute")
(catalog-meta! 'function "buffer-note-seen!" 'domain 'buffers 'effects '(write))
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
(public! 'switch-to-buffer! "(switch-to-buffer! NAME) — show in the active window; a buffer of another group switches the frame to that group first; an ungrouped buffer takes the window and the frame leaves its group")
(public! 'switch-to-buffer-here! "(switch-to-buffer-here! NAME) — show in the active window whatever the group: the mechanism a layout, a swap, or a restore uses")
(public! 'visit "(visit PATH [GROUP]) — open a file; GROUP joins it to that context; /ssh:HOST:/PATH opens over ssh")
(public! 'find-file-read "(find-file-read [GROUP]) — prompt for a file and join it to GROUP; no GROUP keeps it ungrouped")
(for-each
  (lambda (name) (catalog-meta! 'function name 'domain 'buffers 'effects '(write display)))
  '("switch-to-buffer!" "visit" "find-file-read"))
(domain! 'unknown)
(effects! '(read))
(public! 'buffer-link "(buffer-link [NAME] [LINE]) -> a URL that opens the buffer here; no NAME means this buffer at point")
(public! 'compos-link "(compos-link [NAME] [LINE]) -> an compos:// URL for the buffer and line; no NAME means this buffer at point")
(effects! '(write))
(public! 'open-buffer-link! "(open-buffer-link! NAME LINE) — show the buffer a link names; LINE may be #f")
(catalog-meta! 'function "open-buffer-link!" 'domain 'buffers 'effects '(write display))
(domain! 'files)
(effects! '(write))
(public! 'buffer-save! "(buffer-save! [PATH]) — save the current buffer to its path; with PATH, save there and adopt PATH")
(effects! '(read))
(public! 'write-rules "(write-rules) — the rules that decide which writes happen, as (NAME REASON CONFIRMABLE? PRED) records")
(effects! '(write))
(public! 'defwrite-rule! "(defwrite-rule! 'NAME REASON CONFIRMABLE? PRED) — add or replace a write rule; PRED reads (PATH SOURCE) and answers #t to refuse")
(effects! '(read))
(public! 'write-refusal "(write-refusal PATH SOURCE PERMITTED?) — #f when the write is allowed, else the reason it is not")
(effects! '(write))
(public! 'allow-one-write! "(allow-one-write! PATH) — let the next write to PATH set the confirmable rules aside; a person's answer buys this, and it is spent once")
(domain! 'unknown)
(effects! '(unknown))
(public! '*scheme-write-roots* "extra directories where a buffer may start a new .scm file")
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
(for-each
  (lambda (name) (catalog-meta! 'function name 'domain 'editing 'effects '(read)))
  '("point" "buffer-point" "editor-context" "line-start-position" "region-text"
    "buffer-substring" "line-text" "symbol-at-point" "symbol-at-point-in"))
(catalog-meta! 'function "json-parse" 'domain 'data 'effects '(pure))
(catalog-meta! 'function "register-context-provider!" 'domain 'chat 'effects '(write))

(category! 'windows)
(domain! 'windows)
(effects! '(read))
(public! 'window-list "((id buffer-name) ...) for every window")
(public! 'frame-cols "(frame-cols) — usable text columns across the selected frame")
(public! 'active-window "Id of the selected window")
(effects! '(write display))
(public! 'select-window! "(select-window! ID)")
(public! 'other-window! "Select the next window")
(catalog-meta! 'function 'window-preferred-mode 'domain 'windows 'effects '(read))
(catalog-meta! 'function 'window-prefers-buffer? 'domain 'windows 'effects '(read))
(for-each
  (lambda (name) (catalog-meta! 'function name 'domain 'windows 'effects '(write display)))
  '("select-window!" "split-window!" "delete-window-id!"
    "delete-other-windows!" "other-window!" "display-buffer" "pop-to-buffer"
    "define-display-action!" "split-window-sensibly" "window-quit-restore!"
    "display-buffer-other-window!" "apply-layout!"
    "tile-windows!" "tile-visible-windows!" "window-eat!"))
(effects! '(write))
(effects! '(read))
(effects! '(write))

(domain! 'unknown)
(effects! '(unknown))
(category! 'interaction)
(public! 'message "(message TEXT [LEVEL]) — log TEXT and show it in the echo area")
(public! 'minibuffer-read "(minibuffer-read PROMPT CANDIDATES HANDLER) — async; HANDLER gets the choice")
(public! 'debounce! "(debounce! KEY MS CALLBACK ARG) — after MS idle, call CALLBACK with ARG; rescheduling KEY cancels the older callback")
(catalog-meta! 'function "debounce!" 'domain 'interaction 'effects '(write execute))
(public! 'y-or-n "(y-or-n PROMPT YES &optional NO) — a one-key question; y runs YES, n and C-g run NO")
(catalog-meta! 'function "y-or-n" 'domain 'interaction 'effects '(read))
(public! 'read-file-name "(read-file-name PROMPT K) — prompt with filename completion from default-directory; K gets the typed path")
(public! 'abbreviate-file-name "(abbreviate-file-name PATH) — PATH with the home directory written as ~")
;; the buffer-name grammar: *strong* ~dim~ `mono` :icon:, and \x for a literal x
(public! 'minibuffer-read-preview "(minibuffer-read-preview PROMPT CANDIDATES ON-SELECT ON-CONFIRM ON-CANCEL &optional MATCH-HINT STYLE COMPLETE COLLECT SHORTCUTS) — preview candidates; SHORTCUTS maps keys to candidate names, otherwise M-1..M-9 choose by position")
(public! 'minibuffer-buffer? "(minibuffer-buffer? BUF) — whether BUF is a prompt's input buffer, i.e. in minibuffer-mode")
(public! 'minibuffer-mode-ensure! "(minibuffer-mode-ensure! &optional BUF) — put minibuffer-mode on this frame's prompt buffer; answers the buffer")
(public! 'window-preview-buffer! "(window-preview-buffer! NAME) — show NAME in the active window without touching the MRU ring")
(catalog-meta! 'function "window-preview-buffer!"
  'domain 'interaction 'effects '(write display))
(catalog-meta! 'function "message" 'domain 'interaction 'effects '(write))
(catalog-meta! 'function "abbreviate-file-name" 'domain 'files 'effects '(pure))

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
(public! 'editing-state? "(editing-state? BUF) — #t when BUF is in the editing state: the state's maps are in force, and the Cmd-arrows move point rather than the focus unless the mode refuses editing-caret-map")
(public! 'editing-state-on! "(editing-state-on! BUF) — enter the editing state in BUF; the first command after a landing does this")
(public! 'editing-state-off! "(editing-state-off! BUF) — return BUF to the movement state, where the Cmd-arrows move the focus; keyboard-quit, a window command, and a new landing do this")
(public! 'editing-state-maps-off! "(editing-state-maps-off! MODE MAPS) — MODE's buffers refuse those maps in the editing state; chat-mode refuses editing-caret-map, so the Cmd-arrows stay the window motion in a chat")
(public! 'editing-quit! "(editing-quit!) — mark the running command as a quit: after it the buffer is in the movement state; keyboard-quit calls this, and a command that aborts something calls it too")
(public! 'local-set-key "(local-set-key KEYS COMMAND-NAME) in the current buffer's own map")
(public! 'define-derived-mode "(define-derived-mode NAME PARENT SETUP) — NAME is PARENT with SETUP on top: PARENT's setup, keymap and hook come first")
(public! 'major-mode-set! "(major-mode-set! NAME) — enter the major mode NAME and say so; the M-x form of a mode")
(public! 'kill-all-local-variables! "(kill-all-local-variables! BUF) — forget every local that is not permanent, and the buffer's own keys")
(public! 'permanent-local! "(permanent-local! NAME) — kill-all-local-variables! keeps the local NAME")
(public! 'define-globalized-minor-mode! "(define-globalized-minor-mode! GLOBAL LOCAL ELIGIBLE? [DOC]) — the command GLOBAL turns LOCAL on in every buffer ELIGIBLE? accepts, now and as buffers appear")
(public! 'globalized-minor-mode-on? "(globalized-minor-mode-on? GLOBAL) — #t while the globalized mode is on")
(public! 'auto-mode-for-buffer "(auto-mode-for-buffer BUF [NAME]) — the mode BUF would open in: magic-mode-alist, then the interpreter line, then the name")
(public! 'define-prefix-command "(define-prefix-command NAME) — a keymap a prefix key leads to")
(public! 'bind-prefix! "(bind-prefix! MAP KEYS NAME) — in MAP (\"global\" for the global map), KEYS leads to the keymap NAME")
(public! 'mode-keys! "(mode-keys! MODE ((KEYS COMMAND) ...)) — bind once on MODE's map; every buffer in the mode answers")
(public! 'minor-mode-keys! "(minor-mode-keys! NAME ((KEYS COMMAND) ...)) — the minor mode's map, in force while the mode is on")
(public! 'minor-mode-keymap! "(minor-mode-keymap! NAME KEYMAP) — give a registered minor mode its keymap")
(public! 'mode-keymap "(mode-keymap MODE) — the name of the keymap MODE owns, MODE-map; bind there with define-key and every buffer in the mode answers")
(public! 'minor-mode-keymap "(minor-mode-keymap NAME) — the keymap a minor mode registered, or #f")
(public! 'local-remap! "(local-remap! FROM-COMMAND TO-COMMAND) — Emacs [remap]: every key bound to FROM runs TO in this buffer (arrows, C-n/C-p, user bindings alike)")
(public! 'local-remap*! "(local-remap*! BUF FROM-COMMAND TO-COMMAND) — remap in an explicit buffer")
(public! 'define-mode "(define-mode NAME SETUP) — major mode; SETUP must rebuild from locals")
(public! 'mode-parent! "(mode-parent! NAME PARENT) — record that NAME is built from PARENT")
(public! 'derived-mode? "(derived-mode? MODE NAME) — #t when MODE is NAME or descends from it")
(public! 'buffer-derived-mode? "(buffer-derived-mode? BUF NAME) — #t when the buffer's major mode is NAME or descends from it")
(public! 'mode-setup! "(mode-setup! NAME) — run NAME's setup in the current buffer, the way a derived mode inherits it")
(public! 'marginalia! "(marginalia! CATEGORY FN) — FN turns one candidate of CATEGORY ('file 'buffer 'command) into the text beside it; replaces the annotator for that category")
(public! 'annotate "(annotate CATEGORY NAMES) — NAMES as (LABEL HINT) candidates, through CATEGORY's annotator; NAMES unchanged when nothing registered one")
(public! 'set-mode! "(set-mode! NAME) on the current buffer")
(public! 'mode-icon! "(mode-icon! MODE ICON) — the one wide glyph that names MODE in every list")
(public! 'mode-icon "(mode-icon MODE) — MODE's icon, or the plain document icon")
(public! 'mode-link-syntax! "(mode-link-syntax! MODE FN) — FN of (PATH LABEL) writes a file link in MODE's syntax; a child mode inherits it")
(public! 'mode-link-syntax "(mode-link-syntax MODE) — the link syntax fn of MODE or its nearest ancestor; #f when the path alone is the link")
(public! 'mode-label "(mode-label MODE) — MODE's icon and name, for a column that shows the mode")
(public! 'buffer-icon "(buffer-icon NAME) — the icon of the mode NAME is in")
(public! 'file-icon "(file-icon NAME) — the icon of the mode the file NAME would open in; a name ending in / is a directory")
(catalog-meta! 'function "mode-icon!" 'domain 'interaction 'effects '(write))
(catalog-meta! 'function "mode-icon" 'domain 'interaction 'effects '(pure))
(catalog-meta! 'function "mode-label" 'domain 'interaction 'effects '(pure))
(catalog-meta! 'function "buffer-icon" 'domain 'interaction 'effects '(read))
(catalog-meta! 'function "file-icon" 'domain 'interaction 'effects '(pure))
(public! 'font-lock-set-keywords! "(font-lock-set-keywords! MODE KEYWORDS) — replace MODE's keywords")
(public! 'font-lock-keywords "(font-lock-keywords MODE) — the keywords of MODE and its parents")
(public! 'font-lock-refontify! "(font-lock-refontify! BUF) — paint BUF's font-lock keywords now")
(public! 'font-lock-enable! "(font-lock-enable! BUF) — paint BUF's keywords and repaint on every change")
(public! 'font-lock-disable! "(font-lock-disable! BUF) — stop painting BUF's keywords")
(public! 'overriding-map! "(overriding-map! KEYMAP [LOCK?] [UNTIL-COMMAND?]) — the frame's overriding keymap; #f clears it")
(public! 'buffer-at-point-map! "(buffer-at-point-map! BUF KEYMAP) — the keymap of the thing at point in BUF, ahead of the minor maps; #f clears it")
(public! 'defvar "(defvar NAME DEFAULT [DOC]) — NAME takes DEFAULT unless it is bound already")
(public! 'defvar-local "(defvar-local NAME DEFAULT [DOC]) — defvar, and variable-set! writes the current buffer's own value")
(public! 'default-value "(default-value NAME) — the global value, or #f")
(public! 'set-default! "(set-default! NAME VALUE) — the global value")
(public! 'buffer-local-value "(buffer-local-value NAME [BUF]) — BUF's own value, else the default")
(public! 'setq-local! "(setq-local! NAME VALUE) — the current buffer's own value")
(public! 'kill-local-variable! "(kill-local-variable! NAME [BUF]) — forget the buffer's own value")
(public! 'local-variable-p "(local-variable-p NAME [BUF]) — #t when the buffer holds its own value")
(public! 'variable-value "(variable-value NAME) — the current buffer's own value, else the default")
(public! 'variable-set! "(variable-set! NAME VALUE) — locally for a defvar-local, else globally")
(public! 'push-mark! "(push-mark! [POS] [NOMSG]) — the old mark goes on the ring, the mark is set at POS or point")
(public! 'pop-to-mark! "(pop-to-mark!) — point goes to the mark, the ring turns, no region stays")
(public! 'read-char "(read-char PROMPT K) — the next key; K gets the character, or #f on C-g")
(public! 'completing-read "(completing-read PROMPT COLLECTION K 'predicate FN 'require-match #t 'initial TEXT 'default TEXT 'history SYM 'category SYM 'style SYM) — Emacs's completing-read, asynchronous: K gets the choice. COLLECTION is rows or a procedure of the input")
(public! 'read-string "(read-string PROMPT K [OPTS ...]) — a line of text; K gets it")
(public! 'read-char-choice "(read-char-choice PROMPT CHARS K) — one key from CHARS; K gets it, or #f on C-g")
(public! 'y-or-n? "(y-or-n? PROMPT K) — one key; K gets #t for y, #f for n or C-g")
(public! 'yes-or-no? "(yes-or-no? PROMPT K) — the word yes or no; K gets #t or #f")
(public! 'minibuffer-active? "(minibuffer-active?) — #t while a prompt is up")
(public! 'add-hook! "(add-hook! 'name-hook FN [APPEND] [LOCAL]) — put FN on the hook once; FN is a quoted function name, resolved when the hook runs, or a closure. APPEND puts it last. LOCAL puts it on the current buffer's own list, which runs first")
(public! 'remove-hook! "(remove-hook! 'name-hook FN [LOCAL]) — take FN off the hook")
(public! 'run-hook-with-args "(run-hook-with-args 'name-hook ARG ...) — run every function of the hook with ARGS")
(public! 'run-hook-with-args-until-success "(run-hook-with-args-until-success 'name-hook ARG ...) — run until one answers a true value; that value")
(public! 'run-hook-with-args-until-failure "(run-hook-with-args-until-failure 'name-hook ARG ...) — run until one answers #f; #t when none did")
(public! 'hook-functions "(hook-functions 'name-hook) — the functions the hook runs here, local then global")
(public! 'add-paste-hook! "(add-paste-hook! MODE NAME FN) — for a major or minor MODE, register named FN(kind data mime); #t consumes the paste")
(public! 'remove-paste-hook! "(remove-paste-hook! MODE NAME) — remove a named paste handler")
(public! 'frame-attached! "(frame-attached!) — a client attached this frame; runs frame-attach-hook so per-frame display state is pushed again")
(public! 'overlay-set! "(overlay-set! NAME TAG ((START END FACE) ...)) — replaces TAG's ranges")
(public! 'overlay-clear! "(overlay-clear! NAME TAG)")
(for-each
  (lambda (name) (catalog-meta! 'function name 'domain 'commands 'effects '(write)))
  '("define-command" "domain!" "effects!" "namespace!" "catalog-meta!"
    "add-hook!" "remove-hook!"))
(for-each
  (lambda (name) (catalog-meta! 'function name 'domain 'commands 'effects '(read)))
  '("command-names" "command-doc" "key-for-command" "hook-functions"))

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
(for-each
  (lambda (name) (catalog-meta! 'function name 'domain 'files 'effects '(read)))
  '("git-root" "git-status" "git-diff" "git-log" "git-show"))

;; the file watcher
;; The event is content-free: it names the root, and the handler re-queries.
;; Watch coalesces a burst of writes into one event per root.
(public! 'watch-path! "(watch-path! DIR ['deep]) -> the watched root; refcounted, so two watchers of one directory share one subscription. A plain watch sees the direct children of DIR; 'deep sees the whole tree, for a repository")
(public! 'unwatch-path! "(unwatch-path! DIR ['deep]) — drop one reference, 'deep for a deep one; the subscription stops at zero")
(public! 'watched-paths "The watched roots")

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

(category! 'interaction)
(effects! '(write display))
(public! 'global-mode-string-set! "(global-mode-string-set! KEY VALUE) — own one segment at the right of the frame modeline; VALUE is a string, a (CLASS TEXT) pair, or a thunk; #f removes it")
(public! 'global-mode-string-remove! "(global-mode-string-remove! KEY) — drop a package's segment")
(public! 'global-mode-string-refresh! "(global-mode-string-refresh!) — recompose the segments; call after a thunk's answer changed")
(effects! '(read))
(public! 'global-mode-string-segments "(global-mode-string-segments) -> ((CLASS TEXT) ...) the frame modeline shows now")

(category! 'system)
(domain! 'system)
(effects! '(read))
(public! 'random "(random N) -> a whole number from 0 up to N, not N; clock-seeded, to pick at random, not for secrets")

;; the builtins every agent reaches for; their docs are the primitives' own
(category! 'system)
(domain! 'system)
(effects! '(pure))
(public! 'plist-get "(plist-get PLIST KEY) — the value after KEY in the flat PLIST; #f when KEY is absent")
(public! 'ignore-errors "(ignore-errors THUNK) — THUNK's value, or #f when it raises")
(public! 'with-current-buffer "(with-current-buffer BUF THUNK) — run THUNK with BUF current without displaying it or changing any window")
(effects! '(read))
(public! 'monotonic-ms "(monotonic-ms) — a monotonic millisecond count, for timing one span")
(public! 'task-await "(task-await TASK [MS]) — wait for a Scheme task and answer its value, or raise its error")
(public! 'task-alive? "(task-alive? TASK) — #t while TASK remains available")
(effects! '(write execute))
(public! 'task-spawn "(task-spawn THUNK) — run a zero-argument closure concurrently over the shared editor world")
(public! 'task-run! "(task-run! THUNK CALLBACK [MS]) — run THUNK concurrently; later call CALLBACK with OK? and its value or error")
(public! 'task-cancel! "(task-cancel! TASK) — stop a Scheme task")
(public! 'shell-command->string "(shell-command->string CMD [DIR] [CALLBACK]) — run CMD in a shell; stderr merges into the output. With CALLBACK, run in a task and call it with the output")
(domain! 'windows)
(effects! '(read))
(public! 'window-list-all "(window-list-all) — (WIN BUFFER FRAME) rows for every window in every frame")
(effects! '(write display))
(public! 'with-frame-windows "(with-frame-windows THUNK) — run THUNK on the frame's real windows: current-buffer and switch-to-buffer! act on them")
(public! 'window-set-buffer! "(window-set-buffer! WIN BUF) — show BUF in window WIN without selecting it")
(domain! 'commands)
(effects! '(write))
(public! 'public! "(public! 'NAME DOC [CATEGORY]) — put NAME in the catalog under the current domain! and effects! stamps")
;;; --- jit-lock ------------------------------------------------------------------
;; Emacs jit-lock. Display asks for faces on the lines it builds and on
;; no other lines. The buffer marks the text it handed out with the
;; `fontified` text property, and an edit takes the mark off only the
;; lines it touches. Each function on fontification-functions gets
;; (BUF START END), byte positions on whole lines, and paints that range
;; with overlay-set-range!. A buffer that no window shows costs nothing.
;;
;; The positions hold at one buffer version. An edit before the paint
;; moves the bytes, so a painter reads buffer-version before it reads the
;; text and passes it to overlay-set-range!. The buffer then drops a late
;; paint, takes the mark off that paint's text where it is now, and asks
;; for that text again. The runner drops a range that is late already.
;;
;; `fontified` is not sticky: text typed at the end of a marked span takes
;; no mark, so the next draw fontifies it.
(text-property-default-nonsticky! 'fontified #t)

(domain! 'faces)
(effects! '(write))

(define (jit-lock--fontify buf start end &optional version)
  (when (buffer-exists? buf)
    (if (and version (not (= version (buffer-version buf))))
        (jit-lock-refontify! buf)
        (with-current-buffer buf
          (lambda () (run-hook-with-args 'fontification-functions buf start end))))))

(define (jit-lock-register! fn)
  "(jit-lock-register! FN) - call FN with (BUF START END) for each range a window draws"
  (add-hook! 'fontification-functions fn #t)
  (jit-lock-enable! #t)
  fn)

(define (jit-lock-unregister! fn)
  "(jit-lock-unregister! FN) - stop calling FN; Display stops asking when no function is left"
  (remove-hook! 'fontification-functions fn)
  (jit-lock-enable! (pair? (hook--global 'fontification-functions)))
  fn)

(define (jit-lock-refontify-all!)
  "(jit-lock-refontify-all!) - make every buffer fontify its drawn lines again"
  (for-each jit-lock-refontify! (buffer-list)))

(public! 'jit-lock-register! "(jit-lock-register! FN) — call FN with (BUF START END) for each range a window draws, once per edit of that range")
(public! 'jit-lock-unregister! "(jit-lock-unregister! FN) — stop calling FN for drawn ranges")
(public! 'jit-lock-refontify! "(jit-lock-refontify! BUF) — forget what BUF fontified; the next draw fontifies its lines again")
(public! 'jit-lock-refontify-all! "(jit-lock-refontify-all!) — make every buffer fontify its drawn lines again")
(public! 'overlay-set-range! "(overlay-set-range! BUF TAG START END RANGES [VERSION]) — replace TAG's overlays that start in START..END with (START END FACE) RANGES; #f and no change when BUF is past VERSION")

;;; --- text properties -----------------------------------------------------------
;; Emacs text properties, BUF first as every buffer primitive here takes
;; it. A value sits on the text: every edit moves it, and text typed at
;; the end of a span takes the value unless the property is nonsticky.
(domain! 'buffers)
(effects! '(write))
(public! 'put-text-property! "(put-text-property! BUF START END PROP VALUE) — give the text START..END the property PROP with VALUE; #f removes it")
(public! 'remove-text-properties! "(remove-text-properties! BUF START END PROPS) — take the properties PROPS, a list of names, off START..END")
(public! 'text-property-default-nonsticky! "(text-property-default-nonsticky! PROP ON) — with ON, text typed at the end of a PROP span takes no PROP")
(effects! '(read))
(public! 'get-text-property "(get-text-property BUF POS PROP) — the value of PROP at POS, or #f")
(public! 'text-properties-at "(text-properties-at BUF POS) — every property at POS, as (PROP VALUE) pairs")
(public! 'next-single-property-change "(next-single-property-change BUF POS PROP [LIMIT]) — the first position after POS where PROP changes; #f when it does not, LIMIT when not before LIMIT")
(public! 'previous-single-property-change "(previous-single-property-change BUF POS PROP [LIMIT]) — the last position before POS where PROP changes; #f when it does not, LIMIT when not after LIMIT")
(public! 'text-property-any "(text-property-any BUF START END PROP VALUE) — the first position in START..END where PROP is VALUE, or #f")
(public! 'text-property-spans "(text-property-spans BUF PROP) — every span of PROP as (START END VALUE), in order")
(public! 'text-property-default-nonsticky "(text-property-default-nonsticky) — the property names that do not grow over text typed at their end")

(message "editor.scm loaded")
