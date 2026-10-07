;;; fast-code.scm --- prose -> one Scheme expression, and functions learned.
;;; Entry points: the command palette, for input it cannot resolve to a
;;; command, bind or recipe, and a ! at the chat prompt.
;;;
;;; A fast model on the API lane writes the expression, from the functions
;;; learned before, the catalog entries the intent's words recall, and the
;;; names of the buffers and themes. When a job takes more than one existing
;;; call, it writes a function first, with every value the request supplies
;;; as a parameter, and calls it. That function is what is learned: it joins
;;; the API, and the next request of its kind is one call to it.

(domain! 'fast-code)
(effects! '(read write external execute spend))

(defcustom 'fast-code-model "claude-haiku-5-5"
  "The model that writes the expression, and any function it needs. Measured on the API lane, Haiku 4.5 answered in 0.8 to 1 second, the fastest of seven."
  'group 'fast-code)

(defcustom 'fast-code-vocabulary 30
  "How many catalog entries the model is shown. It may use these names and core Scheme, and nothing else."
  'group 'fast-code)

(defcustom 'fast-code-steps 5
  "The most steps a request is broken into."
  'group 'fast-code)

(defcustom 'fast-code-step-entries 10
  "How many catalog entries each step shows the model: the precise apropos hits first, then the wide ones."
  'group 'fast-code)

(define (fast-now-ms) (monotonic-ms))

;;; --- Learned functions -------------------------------------------------
;;; What fast-code learns is Scheme: a named function with parameters and a
;;; docstring, written when an intent needs more than one existing call. It
;;; lives in <compos-home>/packages/learned.scm as ordinary code, one block
;;; to a function, and joins the catalog like any public API, so the model,
;;; apropos and the palette all find it. "filter it for md files" and
;;; "filter it for pdf files" are one function and two calls, not two
;;; saved strings.

;; a test points this elsewhere; #f is the real file
(define *fast-learned-path* #f)
(define (fast-learned-path)
  (or *fast-learned-path* (string-append (compos-home) "/packages/learned.scm")))

;; ((NAME BLOCK) ...): BLOCK is the function's whole text, public! included
(define *fast-learned* '())

(define fast-block-marker ";;; learned: ")

(define fast-learned-header
  (string-append
    ";;; learned.scm --- functions fast-code learned. Edit or delete freely:\n"
    ";;; each block is ordinary Scheme, loaded when fast-code loads.\n\n"
    "(domain! 'fast-code)\n(effects! '(unknown))\n"))

(define (fast-learned-names) (map car *fast-learned*))

(define (fast-learned-save!)
  (write-file! (fast-learned-path)
    (fold (lambda (acc row) (string-append acc "\n" (car (cdr row))))
          fast-learned-header *fast-learned*)))

;; Blocks split on their marker line, so an edit inside one survives.
(define (fast-learned-load!)
  (let* ((path (fast-learned-path))
         (text (and (file-exists? path) (read-file path))))
    (set! *fast-learned*
          (if (string? text)
              (filter (lambda (row) (not (equal? (car row) "")))
                      (map (lambda (chunk)
                             (let ((nl (string-index chunk "\n")))
                               (list (if nl (string-trim (substring-bytes chunk 0 nl)) "")
                                     (string-append fast-block-marker (string-trim chunk) "\n"))))
                           (cdr (string-split text fast-block-marker))))
              '()))
    (when (string? text) (load path))
    (length *fast-learned*)))

;; (define (NAME PARAM ...) DOC BODY ...) as a block: the function, then the
;; public! that puts it in the catalog with a signature built from its
;; parameters.
(define (fast-block form)
  (let* ((head (car (cdr form)))
         (name (symbol->string (car head)))
         (params (cdr head))
         (doc (car (cdr (cdr form))))
         (body (cdr (cdr (cdr form))))
         (sig (string-append "(" name
                (apply string-append
                       (map (lambda (p) (string-append " " (string-upcase (symbol->string p))))
                            params))
                ")")))
    (list name
          (string-append fast-block-marker name "\n"
            "(define " (format "~s" head) "\n  " (format "~s" doc)
            (apply string-append (map (lambda (b) (string-append "\n  " (format "~s" b))) body))
            ")\n"
            (format "(public! '~a ~s)\n" name (string-append sig " — " doc))))))

;; A function is written into the session the moment it is accepted, so its
;; call can run, and kept on disk only once that call has run cleanly. One
;; never kept may be written again under its name; nothing else may.
(define *fast-pending* #f)
;; kept across a reload: the functions stay defined in the session
(define *fast-provisional* (if (boundp '*fast-provisional*) *fast-provisional* '()))

(define (fast-keep-pending! intent)
  (when (and *fast-pending* (equal? (car *fast-pending*) intent))
    (let ((row (car (cdr *fast-pending*))))
      (set! *fast-provisional* (remove (lambda (n) (equal? n (car row))) *fast-provisional*))
      (set! *fast-learned*
            (append (remove (lambda (r) (equal? (car r) (car row))) *fast-learned*)
                    (list row)))
      (eval-string-safe (car (cdr row)))
      (fast-learned-save!)
      (apropos-warm!)))
  (set! *fast-pending* #f))

(define (fast-forget! name)
  (when (assoc name *fast-learned*)
    (set! *fast-learned* (remove (lambda (r) (equal? (car r) name)) *fast-learned*))
    (catalog-forget! 'function name)
    ;; still defined in this session, but no longer the API: free to write again
    (set! *fast-provisional* (cons name *fast-provisional*))
    (fast-learned-save!)
    (apropos-warm!))
  name)

;; A recipe someone wrote, asked for by its title and with no slot to fill,
;; is that recipe: ! completion writes titles.
(define (fast-recipe intent)
  (let ((row (assoc (string-trim intent) *recipes*)))
    (and row (not (string-contains? (cadr row) "{{")) (cadr row))))

;;; --- The prompt ------------------------------------------------------
;;; Theme and buffer names are values, not definitions, so no catalog
;;; entry holds them. The prompt carries them, and a theme says whether it
;;; is light or dark by its own default background.

(define (fast-theme-dark? name)
  (let* ((entry (assoc name *themes*))
         (spec (and entry (cadr entry)))
         (def (and spec (assoc 'default spec)))
         (bg (and def (plist-get (cdr def) 'bg))))
    (and (string? bg) (re-match "^#[0-9A-Fa-f]{6}$" bg)
         (< (+ (* (theme--hex-byte bg 1) 299)
               (* (theme--hex-byte bg 3) 587)
               (* (theme--hex-byte bg 5) 114))
            128000))))

(define (fast-learned-entries)
  (filter (lambda (e) e)
          (map (lambda (n) (catalog-entry "function" n)) (fast-learned-names))))

;;; --- One operation or several ---------------------------------------------
;;; decide asks the on-device model whether a request joins more than one
;;; action, in about 15ms. Only a confident no skips the step split: calling
;;; a single request compound costs one short model call, and calling a
;;; compound one single loses the search for its steps. Measured on nine
;;; requests, "is this compound" read 0.18 to 0.30 for single ones and
;;; 0.74 and up for all but one compound one.

(defcustom 'fast-code-one-shot-below 0.3
  "A request decide rates less compound than this goes to the model in one shot, without being split into steps."
  'group 'fast-code)

(define fast-compound-question
  (list 'compound (list 'type "noul"
                        'instructions "Is this a compound request that joins more than one action?")))

;; K gets the probability the request is compound, or #f when decide
;; cannot say. The on-device model answers in about 15ms.
(define (fast-compound intent k)
  (if (and (boundp 'decide-async) (boundp 'laya-available?) (laya-available?))
      (decide-async (string-append "The request: " intent) fast-compound-question
        (lambda (r)
          (let* ((row (and (pair? r) (assoc 'compound (plist-get r 'answers))))
                 (p (and row (plist-get (car (cdr row)) 'noul))))
            (k (and (number? p) p))))
        'backend 'laya 'timeout 3)
      (k #f)))

;;; --- Steps ---------------------------------------------------------------
;;; A request is broken into the operations it needs before anything is
;;; searched: "open my downloads showing only pdfs" is opening a directory
;;; listing and narrowing a list, and neither phrase shares a word with the
;;; request as typed. Each step gets its own apropos, precise and wide, and
;;; the model stitches the steps from what those found.

(define (fast-decompose-prompt intent)
  (string-append
    "Break this editor request into the operations the editor must perform, "
    "in order. Write one per line, as a short plain phrase in the words an "
    "API reference would use: a verb and what it acts on, each step once. "
    "For \"save this and mail it to Ann\" the steps are:\n"
    "save the buffer to its file\nsend an email with an attachment\n"
    "Keep the request's own nouns for what is acted "
    "on: a thing the request names by name stays named so. Leave the values out: "
    "no names, paths or file types. One line when one operation does it. No "
    "numbers, no prose.\n\n"
    "It and this are " (fast-buffer-desc (fast-this-buffer)) ".\n"
    "The request: " intent))

;; one step a line; list markers and numbering the model adds anyway go
(define (fast-steps text)
  (fast-distinct
   (take-n
    (filter (lambda (s) (> (string-length s) 2))
            (map (lambda (line)
                   (let loop ((s (string-trim line)))
                     (if (and (> (string-length s) 0)
                              (member (substring s 0 1) '("-" "*" "1" "2" "3" "4" "5" "6" "." ")" " ")))
                         (loop (substring s 1 (string-length s)))
                         s)))
                 (if (string? text) (string-split (fast-unfence text) "\n") '())))
    fast-code-steps)))

(define (fast-distinct xs)
  (let loop ((xs xs) (acc '()))
    (cond ((null? xs) (reverse acc))
          ((member (car xs) acc) (loop (cdr xs) acc))
          (else (loop (cdr xs) (cons (car xs) acc))))))

;; precise first (every word), then wide (most words), one list per step
(define (fast-step-entries step)
  (let loop ((es (append (or (ignore-errors (lambda () (apropos-quick step 6))) '())
                         (apropos-recall step fast-code-step-entries)))
             (seen (fast-learned-names))
             (acc '()))
    (cond ((or (null? es) (>= (length acc) fast-code-step-entries)) (reverse acc))
          ((member (plist-get (car es) 'name) seen) (loop (cdr es) seen acc))
          (else (loop (cdr es) (cons (plist-get (car es) 'name) seen) (cons (car es) acc))))))

;; The functions learned come first, all of them: they are few, and they are
;; the operations this user has asked for before. Then each step with what
;; apropos found for it; with no steps, what the whole request recalls.
(define (fast-vocabulary-text intent steps &optional found-out)
  ;; the searches run at once, one task each: a step's apropos is a pass over
  ;; every catalog row, and five in a row took seconds
  (let* ((queries (cons intent (if (pair? steps) steps '())))
         (found (map (lambda (t) (task-await t 5000))
                     (map (lambda (q) (task-spawn (lambda () (fast-step-entries q)))) queries)))
         (lines (lambda (es) (string-join (map fast-entry-line es) "\n"))))
    ;; what each search found, by name, for the trace
    (when found-out
      (found-out (let loop ((qs queries) (fs found) (acc '()))
                   (if (null? qs)
                       (reverse acc)
                       (loop (cdr qs) (cdr fs)
                             (cons (list (car qs) (map (lambda (e) (plist-get e 'name)) (car fs))) acc))))))
    (string-append
      (let ((learned (fast-learned-entries)))
        (if (null? learned) ""
            (string-append "Learned before:\n" (lines learned) "\n\n")))
      (string-join
        (let loop ((qs (cdr queries)) (fs (cdr found)) (acc '()))
          (if (null? qs)
              (reverse acc)
              (loop (cdr qs) (cdr fs)
                    (cons (string-append "For \"" (car qs) "\":\n" (lines (car fs))) acc))))
        "\n\n")
      ;; the request as typed as well: a step that went astray loses nothing
      ;; the words themselves would find
      (if (pair? steps) "\n\nFor the request as typed:\n" "")
      (lines (car found)))))

;; A variable is shown by its name: some carry a signature written as a
;; call, and the model called (*themes*).
(define (fast-variable? e)
  (let ((sym (string->symbol (plist-get e 'name))))
    (and (boundp sym) (not (procedure? (symbol-value sym))))))

(define (fast-entry-line e)
  (string-append "  "
    (or (and (fast-variable? e) (string-append "variable " (plist-get e 'name)))
        (plist-get e 'sig)
        (plist-get e 'signature)
        (and (plist-get e 'use)
             (string-append (plist-get e 'kind) " " (plist-get e 'name) ": " (plist-get e 'use)))
        (plist-get e 'name))
    "  " (or (plist-get e 'doc) "")))

;; "It" and "this" are what the user is looking at. From a ! in the chat
;; the current buffer is the chat, so "filter it" filtered the chat.
(define (fast-this-buffer)
  (let ((seen (filter (lambda (b) (not (equal? (buffer-local b 'mode-name) "chat-mode")))
                      (get-visible-buffers))))
    (if (pair? seen) (car seen) (current-buffer))))

;; A buffer is named with its mode, so "the dired" finds one, and the
;; buffers on screen come first: "this" is one of them.
(define (fast-buffer-desc b)
  (let ((mode (buffer-local b 'mode-name)))
    (string-append (format "~s" b) (if (string? mode) (string-append " (" mode ")") ""))))

(define (fast-prompt intent &optional steps found-out)
  (string-append
    "You turn an editor user's request into one expression in compos Scheme, "
    "the language the editor is scripted in. It is not Emacs Lisp.\n\n"
    "Use only the names below and core Scheme (let, lambda, if, cond, begin, "
    "list, string-append and the like). An M-x command runs as "
    "(run-command \"name\"). A recipe is a ready expression: fill each "
    "{{slot}} with a quoted string. Buffers and themes are named by the "
    "strings below, and a BUF is one of those buffer names exactly. An argument that names one is that string, never a "
    "quoted symbol.\n\n"
    "Home is \"~\". It, this, and the one I am looking at are "
    "(fast-this-buffer); here is (default-directory): write those calls, not "
    "their values, so the answer holds wherever it runs. An M-x command that "
    "asks for a value (a directory, a file, a name) is wrong when the request "
    "already gives it: call the function the command wraps, with the value.\n\n"
    (fast-vocabulary-text intent steps found-out)
    "\n\nOn screen, the one used last first: "
    (string-join (map fast-buffer-desc (get-visible-buffers)) ", ")
    "\nOther buffers: "
    (string-join (map fast-buffer-desc
                      (take-n (filter (lambda (b) (not (member b (get-visible-buffers))))
                                      (buffer-list))
                              40))
                 ", ")
    "\nThemes: "
    (string-join (map (lambda (n) (string-append (format "~s" n) (if (fast-theme-dark? n) " (dark)" " (light)")))
                      (map car *themes*))
                 ", ")
    "\n\nWhen one call does the job, answer that call. When the job takes "
    "more than one call, or is an operation worth a name, write a function "
    "first and then one call to it:\n"
    "  (define (NAME PARAM ...) \"what it does, in a phrase\" BODY ...)\n"
    "  (NAME ARG ...)\n"
    "Every value the request supplies (a buffer, a file type, a path, a name, "
    "a number, a word to match) is a parameter: the body never holds it, and "
    "the call passes it. The function then does the same job for any value. "
    "NAME is new: lowercase, hyphenated, ending in ! when it changes "
    "something, and it and the docstring describe the job for any value "
    "(dired-open-filtered!, not open-downloads-pdfs). Answer with Scheme alone: no prose, no code fence. "
    "Answer NONE if nothing listed can do what was asked.\n\nThe request: " intent))

;;; --- Accepting an answer ---------------------------------------------
;;; An answer must read as one form and call nothing unbound. A name the
;;; model invented is refused, not run: running it to find out would run
;;; whatever came before the invented call first. A run-command must name a
;;; command that exists.

(define fast-special-forms
  '(begin let let* letrec lambda if cond case when unless and or not else
    quote quasiquote set! define do))

(define (fast-local-names form)
  (let ((walk (lambda (xs) (fold (lambda (acc x) (append acc (fast-local-names x))) '() xs)))
        (bound (lambda (bs) (map (lambda (b) (if (pair? b) (car b) b)) bs)))
        (values (lambda (bs) (map (lambda (b) (if (pair? b) (cdr b) '())) bs))))
    (cond
      ((not (pair? form)) '())
      ;; named let: (let loop ((x 1)) ...) binds loop as well as x
      ((and (member (car form) '(let let* letrec letrec*)) (pair? (cdr form))
            (symbol? (car (cdr form))) (pair? (cdr (cdr form))))
       (let ((bs (car (cdr (cdr form)))))
         (append (list (car (cdr form))) (bound bs) (walk (values bs))
                 (walk (cdr (cdr (cdr form)))))))
      ;; a binding's value holds lambdas of its own: (let ((f (lambda (x) ...))) ...)
      ((and (member (car form) '(let let* letrec letrec* do)) (pair? (cdr form))
            (pair? (car (cdr form))))
       (let ((bs (car (cdr form))))
         (append (bound bs) (walk (values bs)) (walk (cdr (cdr form))))))
      ((and (equal? (car form) 'lambda) (pair? (cdr form)))
       (let ((ps (car (cdr form))))
         (append (if (symbol? ps) (list ps) (if (pair? ps) (filter symbol? ps) '()))
                 (walk (cdr (cdr form))))))
      ;; an inner define: (define (f x) ...) or (define y ...)
      ((and (equal? (car form) 'define) (pair? (cdr form)))
       (let ((head (car (cdr form))))
         (append (if (pair? head) (filter symbol? head) (list head))
                 (walk (cdr (cdr form))))))
      (else (walk form)))))

(define (fast-unknown-names form locals)
  (cond
    ((not (pair? form)) '())
    ((equal? (car form) 'quote) '())
    ((and (equal? (car form) 'run-command) (pair? (cdr form)) (string? (car (cdr form))))
     (if (command-fn (car (cdr form))) '() (list (string->symbol (car (cdr form))))))
    (else
      (let ((head (car form)))
;; a variable in call position is as wrong as an unbound name: (*themes*)
        (append (if (and (symbol? head)
                         (not (member head fast-special-forms))
                         (not (member head locals))
                         (not (and (boundp head) (procedure? (symbol-value head)))))
                    (list head)
                    '())
                ;; a list in call position, a let binding or a cond clause,
                ;; holds calls of its own
                (fold (lambda (acc x) (append acc (fast-unknown-names x locals)))
                      '() (if (pair? head) form (cdr form))))))))

(define (fast-unfence s)
  (let ((t (string-trim s)))
    (if (string-prefix? "```" t)
        (string-trim (string-join (filter (lambda (l) (not (string-prefix? "```" l)))
                                          (string-split t "\n"))
                                  "\n"))
        t)))

;; (ok CODE) or (no REASON)
(define (fast-accept text &optional intent)
  (let* ((s (if (string? text) (fast-unfence text) ""))
         (forms (and (> (string-length s) 0) (not (equal? s "NONE"))
                     (ignore-errors (lambda () (scheme-read s))))))
    (cond
      ((not (string? text)) (list 'no "the model did not answer"))
      ((not (pair? forms)) (list 'no "nothing does that"))
      ;; several calls are steps, and run in order; prose read as forms
      ;; names nothing bound, so the check below still refuses it
      ((fast-define? (car forms)) (fast-accept-define (car forms) (cdr forms) intent))
      ((and (not (null? (cdr forms))) (not (null? (filter (lambda (x) (not (pair? x))) forms))))
       (list 'no "the model answered prose, not calls"))
      ((not (null? (cdr forms)))
       (fast-accept-form (cons 'begin forms) (string-append "(begin " s ")")))
      ((not (pair? (car forms))) (list 'no "the model answered no call"))
      (else (fast-accept-form (car forms) s)))))

;; A literal in a BUF slot must name a buffer that exists: the model wrote
;; (list-filter-push! "Dired" ...) with the dired's real name in front of it.
(define (fast-buf-slots name)
  (let* ((e (catalog-entry "function" name))
         (sig (and e (plist-get e 'signature)))
         (args (and (string? sig) (> (string-length sig) 2)
                   (cdr (string-split (substring sig 1 (- (string-length sig) 1)) " ")))))
    (let loop ((as (or args '())) (i 1) (acc '()))
      (cond ((null? as) acc)
            ((member (car as) '("BUF" "BUFFER")) (loop (cdr as) (+ i 1) (cons i acc)))
            (else (loop (cdr as) (+ i 1) acc))))))

(define (fast-bad-buffers form)
  (cond
    ((not (pair? form)) '())
    ((equal? (car form) 'quote) '())
    (else
      (append
        (if (symbol? (car form))
            (filter (lambda (s) (not (buffer-known? s)))
                    (filter string?
                            (map (lambda (i) (and (< i (length form)) (nth i form)))
                                 (fast-buf-slots (symbol->string (car form))))))
            '())
        (fold (lambda (acc x) (append acc (fast-bad-buffers x))) '()
              form)))))

;; A command that reads its value from you stops to ask, and an intent
;; carries the value: "open a dired here" ran M-x dired and waited for a
;; directory. The command's own source says whether it asks.
(define fast-reader-calls
  '("read-file-name" "minibuffer-read" "completing-read" "read-string" "read-buffer" "read-directory"))

(define (fast-asking-commands form)
  (cond
    ((not (pair? form)) '())
    ((equal? (car form) 'quote) '())
    ((and (equal? (car form) 'run-command) (pair? (cdr form)) (string? (car (cdr form)))
          (command-fn (car (cdr form))))
     (let ((src (or (ignore-errors (lambda () (describe-function (string->symbol (car (cdr form)))))) "")))
       (if (pair? (filter (lambda (r) (string-contains? src r)) fast-reader-calls))
           (list (car (cdr form)))
           '())))
    (else (fold (lambda (acc x) (append acc (fast-asking-commands x))) '() form))))

(define (fast-command-source cmd)
  (let ((src (or (ignore-errors (lambda () (describe-function (string->symbol cmd)))) "")))
    (string-append "Its source is "
                   (if (> (string-length src) 400) (substring src 0 400) src))))

;;; --- Accepting a function -------------------------------------------------
;;; A definition must earn its name: a docstring, parameters for the values
;;; the request supplied, a body that names nothing unbound, and one call to
;;; it after. A body holding a value its call also passes is a function for
;;; one request, which is the string-per-intent store over again.

(define (fast-define? form)
  (and (pair? form) (equal? (car form) 'define)
       (pair? (cdr form)) (pair? (car (cdr form)))))

(define (fast-strings form)
  (cond ((string? form) (list form))
        ((not (pair? form)) '())
        ((equal? (car form) 'quote) '())
        (else (fold (lambda (acc x) (append acc (fast-strings x))) '() form))))

;; a literal's word: ".md" -> "md", "*.PDF" -> "pdf"
(define (fast-core s)
  (let loop ((t (string-downcase (string-trim s))))
    (if (and (> (string-length t) 0) (member (substring t 0 1) '("." "*" "-")))
        (loop (substring t 1 (string-length t)))
        t)))

;; the words inside string values: "/Users/x/Downloads" -> users x downloads
(define (append-map-words strings)
  (fold (lambda (acc s)
          (append acc (filter (lambda (w) (not (equal? w "")))
                              (apropos-query-words (string-join (string-split s ".") " ")))))
        '() strings))

;; "*scratch*" -> "scratch"; a path's buffer has no word
(define (fast-buffer-word b)
  (if (string-prefix? "/" b)
      ""
      (string-downcase (string-trim (string-join (string-split b "*") "")))))

(define (fast-accept-define form rest &optional intent)
  (let* ((head (car (cdr form)))
         (name (car head))
         (params (cdr head))
         (doc (and (pair? (cdr (cdr form))) (car (cdr (cdr form)))))
         (body (if (string? doc) (cdr (cdr (cdr form))) '()))
         (call (and (pair? rest) (null? (cdr rest)) (car rest)))
         (locals (append (list name) (if (pair? params) params '())
                         (fast-local-names (cons 'begin body))))
         (words (if (string? intent) (apropos-query-words intent) '()))
         (literals (fast-strings (cons 'begin body)))
         ;; held: a literal the call also passes, or one the request's own
         ;; words spelled (".md" for "md files")
         (held (filter (lambda (s)
                         (or (and call (member s (fast-strings (cdr call))))
                             (member (fast-core s) words)))
                       literals))
         ;; a path of this moment, not a bare "/" joining two parts
         (placed (filter (lambda (s) (or (and (> (string-length s) 1) (string-prefix? "/" s))
                                         (buffer-known? s)))
                         literals))
         ;; the name and doc speak for every value: "open-downloads-pdf-filter"
         ;; is named after the one request it was written for
         (passed (filter (lambda (w) (> (string-length w) 1))
                         (map fast-core (append-map-words (if (pair? call) (fast-strings (cdr call)) '())))))
         (named (filter (lambda (w) (and (symbol? name)
                                         (member w (string-split (symbol->string name) "-"))))
                        passed))
         (described (filter (lambda (w) (and (string? doc) (member w (apropos-query-words doc))))
                            passed))
         ;; a buffer the request names by its word ("the scratch buffer")
         ;; is a value, even when the body reaches it through a command
         (named-buffers (filter (lambda (b) (member (fast-buffer-word b) words)) (buffer-list)))
         (doc-words (if (string? doc) (apropos-query-words doc) '()))
         ;; a docstring that adds nothing to the request's own words
         (echoed (and (pair? words) (pair? doc-words)
                      (< (length (filter (lambda (w) (not (member w words))) doc-words)) 2)))
         (checked (fast-accept-form (cons 'begin (append body (if (pair? call) (list call) '())))
                                    "" locals))
         ;; every problem at once: the one retry fixes what it is told
         (problems
           (filter string?
             (list
               (and (not (symbol? name)) "a function is named by a symbol")
               (and (pair? (filter (lambda (p) (not (symbol? p))) params))
                    "every parameter is a symbol")
               (and (not (string? doc)) "a function opens with a docstring saying what it does")
               (and (string? doc) (null? body) "a function needs a body")
               (and (symbol? name) (boundp name)
                    (not (member (symbol->string name) *fast-provisional*))
                    (string-append (symbol->string name)
                      " already exists: call it, or give the new function another name"))
               (and (not (and (pair? call) (equal? (car call) name)))
                    "a function must be followed by exactly one call to it")
               (and (pair? held)
                    (string-append "the body holds " (string-join (map (lambda (s) (format "~s" s)) held) ", ")
                      ", which the request supplied: make each a parameter and pass it"))
               (and (pair? placed)
                    (string-append "the body names " (string-join (map (lambda (s) (format "~s" s)) placed) ", ")
                      ", a buffer or path of this moment: make it a parameter"))
               (and (pair? named)
                    (string-append "the name holds " (string-join named ", ")
                      ", a value this call passes: name it for what it does with any value"))
               (and (pair? described)
                    (string-append "the docstring holds " (string-join described ", ")
                      ", a value this call passes: describe it for any value, naming the parameters"))
               (and (null? params) (pair? named-buffers)
                    (string-append "the request names the buffer " (format "~s" (car named-buffers))
                      ": take the buffer as a parameter, so the function serves any buffer"))
               (and echoed
                    "the docstring repeats the request: say what the function does for any value")
               (and (not (equal? (car checked) 'ok)) (car (cdr checked)))))))
    (if (null? problems)
        (list 'ok (format "~s" call) form)
        (list 'no (string-join problems "; ")))))

;; An invented name is usually a real one misremembered: set-buffer-local!
;; for buffer-set-local!. Its words find the real ones.
(define (fast-near name)
  (let* ((words (string-join (filter (lambda (w) (not (equal? w "")))
                                     (string-split (string-join (string-split name "!") "") "-"))
                             " "))
         (hits (ignore-errors (lambda () (apropos words 'lexical #t))))
         (names (if (pair? hits) (map (lambda (e) (plist-get e 'name)) (take-n hits 5)) '())))
    (if (null? names) "" (string-append " (real names near it: " (string-join names ", ") ")"))))

(define (fast-accept-form form s &optional extra)
  (let ((unknown (fast-unknown-names form (append (or extra '()) (fast-local-names form))))
        (bufs (fast-bad-buffers form)))
    (cond
      ;; the model called a command as a function, (dired DIR): its source
      ;; names the function to call instead
      ((and (pair? unknown) (command-fn (symbol->string (car unknown))))
       (list 'no (string-append (symbol->string (car unknown))
                   " is an M-x command, not a function. "
                   (fast-command-source (symbol->string (car unknown)))
                   " -- call the function it wraps.")))
      ((pair? unknown)
       (list 'no (string-append "no such name: "
                   (string-join (map symbol->string unknown) ", ")
                   (fast-near (symbol->string (car unknown))))))
      ((pair? bufs)
       (list 'no (string-append "no such buffer: " (string-join bufs ", "))))
      ((pair? (fast-asking-commands form))
       (let ((cmd (car (fast-asking-commands form))))
         (list 'no (string-append "M-x " cmd " stops to ask the user. "
                     (fast-command-source cmd)
                     " -- call the function it wraps with the value"
                     " (here is (default-directory))"))))
      (else (list 'ok s)))))

;;; --- Trace -----------------------------------------------------------------
;;; Every resolution leaves a record: what decide said and which path it
;;; took, the steps, the names each apropos found, the model's raw answers and
;;; what was said of them, the code, what it gave and how long each stage
;;; took. From the palette and from ! alike. The last hundred stay in memory
;;; and in fast-code-trace.jsonl; M-x fast-trace reads them.

(define (fast-trace-path) (string-append (compos-home) "/fast-code-trace.jsonl"))

;; the file holds the oldest first; a restart reads it back, so the next
;; record adds to the history instead of writing over it
(define (fast-trace-load)
  (ignore-errors
    (lambda ()
      (if (file-exists? (fast-trace-path))
          (reverse (filter (lambda (r) r)
                           (map json-parse
                                (filter (lambda (l) (not (equal? (string-trim l) "")))
                                        (string-split (read-file (fast-trace-path)) "\n")))))
          '()))))

(define *fast-trace* (or (fast-trace-load) '()))
(define *fast-trace-last* #f)

(define (fast-trace-add! rec)
  (set! *fast-trace* (take-n (cons rec *fast-trace*) 100))
  (ignore-errors
    (lambda ()
      (write-file! (fast-trace-path)
        (fold (lambda (acc r) (string-append (json-encode r #f) "\n" acc)) "" *fast-trace*)))))

;; the resolution's record, finished with where it came from and what it gave
(define (fast-trace-done! via intent r gave)
  (fast-trace-add!
    (append (list 'at (current-time) 'via via 'intent intent
                  'code (plist-get r 'code) 'defined (plist-get r 'defined)
                  'reason (plist-get r 'reason) 'gave gave
                  'source (value->string (plist-get r 'source))
                  'timing (plist-get r 'timing))
            (or (plist-get r 'trace) '()))))

(define (fast-trace-entry r)
  (let ((g (lambda (k) (plist-get r k)))
        (line (lambda (label v) (if v (string-append "  " label " " (if (string? v) v (value->string v)) "\n") ""))))
    (string-append
      "● " (value->string (g 'intent)) "   (" (value->string (g 'via)) ", " (value->string (g 'source)) ")\n"
      (line "decide  " (and (g 'compound) (string-append "compound " (value->string (g 'compound)) " -> " (value->string (g 'path)))))
      (line "split   " (g 'split-raw))
      (apply string-append
             (map (lambda (row) (line "search  " (string-append "\"" (car row) "\": " (string-join (car (cdr row)) ", "))))
                  (or (g 'searched) '())))
      (line "answer  " (g 'answer))
      (line "verdict " (g 'verdict))
      (line "retry   " (g 'retry))
      (line "verdict " (g 'retry-verdict))
      (line "defined " (g 'defined))
      (line "ran     " (g 'code))
      (line "gave    " (g 'gave))
      (line "timing  " (g 'timing))
      "\n")))

(define (fast-trace-text n)
  (apply string-append (map fast-trace-entry (take-n *fast-trace* n))))

(define-command "fast-trace" "Show the last fast-code resolutions, stage by stage"
  (lambda ()
    (with-frame-windows
      (lambda ()
        (buffer-create "*fast-trace*")
        (buffer-set-text! "*fast-trace*" (fast-trace-text 20))
        (display-buffer-other-window! "*fast-trace*")))))

;;; --- Resolving ---------------------------------------------------------
;;; K gets a plist: 'code, or #f with a 'reason; 'defined names a function
;;; the answer wrote; then 'source (recipe or the model's id) and 'ms. A
;;; recipe calls K before this returns; the model calls it later, so
;;; nothing here waits on the lane.



(define (fast-resolve intent k &optional model0)
  (let* ((model (or model0 fast-code-model))
         (t0 (fast-now-ms))
         (authored (fast-recipe intent))
         (remembered (and (not authored) (fast-remembered intent)))
         (templated (and (not authored) (not remembered) (fast-template intent)))
         (steps '())
         (timing '())
         ;; the record M-x fast-trace reads: each stage adds what it saw
         (trace '())
         (note (lambda (key v) (set! trace (append trace (list key v)))))
         (done (lambda (r)
                 (let ((ms (- (fast-now-ms) t0)))
                   (cond
                     ((not (equal? (car r) 'ok))
                      (k (list 'code #f 'reason (car (cdr r)) 'steps steps 'timing timing
                               'trace trace 'source model 'ms ms)))
                     ;; a function and its call: the function is defined now,
                     ;; so the call can run, and kept once the call has
                     ((pair? (cdr (cdr r)))
                      (let ((row (fast-block (car (cdr (cdr r))))))
                        (eval-string-safe (format "~s" (car (cdr (cdr r)))))
                        (set! *fast-provisional* (cons (car row) *fast-provisional*))
                        (set! *fast-pending* (list intent row))
                        (k (list 'code (car (cdr r)) 'defined (car row) 'steps steps 'timing timing
                                 'trace trace 'source model 'ms ms))))
                     (else
                       (set! *fast-pending* #f)
                       (k (list 'code (car (cdr r)) 'steps steps 'timing timing
                                'trace trace 'source model 'ms ms))))))))
    (cond
      (authored
        (k (list 'code authored 'source 'recipe 'ms (- (fast-now-ms) t0)
                 'trace (list 'path "recipe title"))))
      (remembered
        (k (list 'code remembered 'source 'remembered 'ms (- (fast-now-ms) t0)
                 'trace (list 'path "remembered"))))
      (templated
        (k (list 'code templated 'source 'template 'ms (- (fast-now-ms) t0)
                 'trace (list 'path "template"))))
      (else
        ;; decide first: one operation goes straight to the stitch; several,
        ;; or a doubt, are broken into steps, one apropos each
        (let ((finish (lambda (r) (set! timing (append timing (list 'total (- (fast-now-ms) t0))))
                                  (done r)))
              (searched (lambda (ms) (set! timing (append timing (list 'search ms))))))
          (fast-compound intent
            (lambda (p)
              (set! timing (list 'decide (- (fast-now-ms) t0)))
              (note 'compound p)
              (if (and (number? p) (< p fast-code-one-shot-below))
                  (begin
                    (note 'path "one shot")
                    (fast-stitch! intent '() finish searched model note))
                  (begin
                    (note 'path "steps")
                    (llm-with-model (fast-decompose-prompt intent) model
                      (lambda (steps-text)
                        (set! steps (fast-steps steps-text))
                        (note 'split-raw steps-text)
                        (set! timing (append timing (list 'split (- (fast-now-ms) t0))))
                        (fast-stitch! intent steps finish searched model note))
                      (fast-llm-failed finish)))))))))))

;; The code the same words got last time, when it ran clean. The newest
;; record of the words decides: one that failed sends them to the model.
(define (fast-remembered intent)
  (let ((rec (find (lambda (r) (equal? (plist-get r 'intent) (string-trim intent)))
                   *fast-trace*)))
    (and rec
         (string? (plist-get rec 'code))
         (string? (plist-get rec 'gave))
         (not (string-prefix? "error:" (plist-get rec 'gave)))
         (plist-get rec 'code))))

;; The same words with one changed: "ascii theme" gave (load-theme "ascii"),
;; so "paper theme" gives (load-theme "paper"). The changed word is the slot
;; when the old answer holds it as a string literal; the rest must match.
(define (fast-words s)
  (filter (lambda (w) (not (equal? w ""))) (string-split (string-trim s) " ")))

(define (fast-slot-fill old new code)
  (let ((ow (fast-words old)) (nw (fast-words new)))
    (and (> (length ow) 1)
         (= (length ow) (length nw))
         (let loop ((a ow) (b nw) (slot #f))
           (cond
             ((null? a)
              (and slot
                   (string-replace code (format "~s" (car slot)) (format "~s" (cadr slot)))))
             ((equal? (string-downcase (car a)) (string-downcase (car b)))
              (loop (cdr a) (cdr b) slot))
             ((and (not slot) (string-contains? code (format "~s" (car a))))
              (loop (cdr a) (cdr b) (list (car a) (car b))))
             (else #f))))))

(define (fast-template intent)
  (let loop ((rs *fast-trace*))
    (and (pair? rs)
         (let* ((r (car rs))
                (code (plist-get r 'code))
                (filled (and (string? code)
                             (string? (plist-get r 'gave))
                             (not (string-prefix? "error:" (plist-get r 'gave)))
                             (string? (plist-get r 'intent))
                             (fast-slot-fill (plist-get r 'intent) intent code))))
           (if (and filled (equal? (car (fast-accept filled)) 'ok))
               filled
               (loop (cdr rs)))))))

;; the error side of llm-with-model: the ask ends, and its record says why
(define (fast-llm-failed done)
  (lambda (msg) (done (list 'no (string-append "llm error: " msg)))))

(define (fast-stitch! intent steps done &optional searched model0 note0)
  (let ((model (or model0 fast-code-model))
        (note (or note0 (lambda (key v) #f)))
        (t0 (fast-now-ms)))
    ;; the prompt is built off the lane: its searches are the slow part
    (task-run!
      (lambda ()
        (let* ((found '())
               (prompt (fast-prompt intent steps (lambda (x) (set! found x)))))
          (list prompt found)))
      (lambda (ok? built)
        (when searched (searched (- (fast-now-ms) t0)))
        (if (not ok?)
            (done (list 'no (string-append "the search failed: " (value->string built))))
            (let ((prompt (car built)))
              (note 'searched (car (cdr built)))
              (llm-with-model prompt model
                (lambda (text)
                  (let ((r (fast-accept text intent)))
                    (note 'answer text)
                    (note 'verdict (if (equal? (car r) 'ok) "ok" (car (cdr r))))
                    ;; A refused answer is asked for once more, with the
                    ;; reason: told what was wrong, the model mostly puts it
                    ;; right. NONE is an answer, not a mistake.
                    (if (or (equal? (car r) 'ok) (not (string? text))
                            (equal? (car (cdr r)) "nothing does that"))
                        (done r)
                        (llm-with-model
                          (string-append prompt "\n\nYou answered: " (string-trim text)
                                         "\nThat was refused: " (car (cdr r))
                                         ". Answer again.")
                          model
                          (lambda (text2)
                            (let ((r2 (fast-accept text2 intent)))
                              (note 'retry text2)
                              (note 'retry-verdict (if (equal? (car r2) 'ok) "ok" (car (cdr r2))))
                              (done r2)))
                          (fast-llm-failed done)))))
                (fast-llm-failed done))))))))

;; A refusal lists every problem for the model's retry. The person gets one
;; sentence: what went wrong first, without the model's names near it.
(define (fast-short-reason reason)
  (let* ((first (car (string-split (or reason "no answer") ";")))
         (cut (string-index first " (real names")))
    (string-trim (if cut (substring-bytes first 0 cut) first))))

(define (fast-failure intent r)
  (string-append "fast: could not write \"" intent "\" -- "
                 (fast-short-reason (plist-get r 'reason))))

(define (fast-run! intent)
  (unless (or (fast-recipe intent) (fast-remembered intent) (fast-template intent))
    (message (string-append "fast: asking " fast-code-model "...")))
  (fast-resolve intent
    (lambda (r)
      (let ((code (plist-get r 'code)))
        (if (not code)
            (begin (fast-trace-done! "palette" intent r #f)
                   (message (fast-failure intent r)))
            (let ((res (with-frame-windows (lambda () (eval-string-safe code)))))
              (if (equal? (car res) 'ok)
                  (fast-keep-pending! intent)
                  (set! *fast-pending* #f))
              (fast-trace-done! "palette" intent r
                                (if (equal? (car res) 'ok)
                                    (value->string (car (cdr res)))
                                    (string-append "error: " (value->string (car (cdr res))))))
              (message (format "~a  ~a ms ~a -- ~a" code (plist-get r 'ms) (plist-get r 'source)
                               (if (equal? (car res) 'ok) "ok" (car (cdr res)))))))))))

;;; --- The chat prompt ---------------------------------------------------
;;; A chat input that opens with ! is prose for fast-code. It resolves here
;;; and runs through the same REPL path a parenthesised input takes, so it
;;; spends no turn and the agent never sees it. A window call runs against
;;; the frame, not the chat. A miss runs an expression that says so, so the
;;; transcript reports it the way it reports any failed form.

(define fast-enabled? #t)

(define (fast-chat-input? text)
  (and fast-enabled? (string-prefix? "!" text)))

(define (fast-bare-intent text)
  (string-trim (substring text 1 (string-length text))))

(define (fast-chat-resolve text k)
  (let ((intent (fast-bare-intent text)))
    (fast-resolve intent
      (lambda (r)
        (set! *fast-trace-last* (list intent r))
        (let ((code (plist-get r 'code)))
          (k (if code
                 (string-append "(with-frame-windows (lambda () " code "))")
                 (format "~s" (list 'error (fast-failure intent r))))))))))

;; The chat runs the call and prints what it gave; a clean run keeps the
;; function the answer wrote.
(define (fast-chat-ran! text printed)
  (let ((intent (fast-bare-intent text)))
    (when (and *fast-trace-last* (equal? (car *fast-trace-last*) intent))
      (fast-trace-done! "chat !" intent (car (cdr *fast-trace-last*)) printed)
      (set! *fast-trace-last* #f))
    (if (string-contains? printed "\nerror:")
        (set! *fast-pending* #f)
        (fast-keep-pending! intent))))

;;; --- The palette -------------------------------------------------------
;;; What the palette already resolves runs as before, and a learned recipe
;;; is one of those. Everything else is natural language for fast-code.

;; The originals live under symbols this file never re-defines, so a reload
;; of fast-code cannot wrap the wrapper.
(define (fast-palette-installed?)
  (and (boundp 'fast--palette-orig-run) (symbol-value 'fast--palette-orig-run) #t))

(define (fast-palette-known? choice)
  (or (command-fn choice)
      (command-palette--bind-parse choice)
      (assoc choice *recipes*)))

;; What you typed is a row. A sentence (three words or more) leads, so RET
;; hands your words to fast-code, the way ! completion does; a short query
;; keeps the palette's own ranking, and your words close the list.
;; A past ask with a remembered answer says so, and how to drop it.
(define (fast-palette-mark row)
  (if (and (pair? row) (pair? (cdr row)) (equal? (cadr row) "past  ask")
           (fast-remembered (car row)))
      (list (car row) "past  ask  remembered")
      row))

(define (fast-palette-rows query base0)
  (let ((q (string-trim query))
        (base (map fast-palette-mark base0)))
    (cond
      ((equal? q "") base)
      ((pair? (filter (lambda (c) (equal? (car c) q)) base)) base)
      (else
        (let ((mine (list q "fast  your words -> scheme")))
          (if (>= (length (filter (lambda (w) (not (equal? w ""))) (string-split q " "))) 3)
              (cons mine base)
              (append base (list mine))))))))

(define (fast-palette-install!)
  (if (fast-palette-installed?)
      "palette -> fast-code already installed"
      (let ((orig-run command-palette--run)
            (orig-cands command-palette-candidates))
        (set-symbol-value! 'fast--palette-orig-run orig-run)
        (set-symbol-value! 'fast--palette-orig-candidates orig-cands)
        ;; a palette action acts on the frame the user is looking at, not on
        ;; whatever context happens to be evaluating
        (set! command-palette--run
              (lambda (choice)
                (if (fast-palette-known? choice)
                    (with-frame-windows (lambda () (orig-run choice)))
                    (fast-run! choice))))
        ;; free text is always selectable, so RET on an unmatched query lands here
        (set! command-palette-candidates
              (lambda (query) (fast-palette-rows query (orig-cands query))))
        "palette -> fast-code installed")))

(define (fast-palette-remove!)
  (if (not (fast-palette-installed?))
      "palette -> fast-code not installed"
      (begin
        (set! command-palette--run (symbol-value 'fast--palette-orig-run))
        (set! command-palette-candidates (symbol-value 'fast--palette-orig-candidates))
        (set-symbol-value! 'fast--palette-orig-run #f)
        "palette -> fast-code removed")))

(define-command "fast-code" "Turn an intent into Scheme and run it"
  (lambda () (minibuffer-read "Fast intent: " '() fast-run!)))

;; The learned functions are a file of Scheme you can read and edit.
(define (fast-show-learned)
  (fast-learned-save!)
  (display-buffer-other-window!
    (visit (fast-learned-path) (buffer-group (current-buffer)))))

(define-command "fast-recipes" "Show the functions fast-code learned"
  (lambda () (with-frame-windows fast-show-learned)))

;; A wrong answer is forgotten: every record of the words goes, so the next
;; time they reach the model again. The words stay in the palette history.
(define (fast-forget-answer! intent)
  (let ((words (string-trim intent)))
    (set! *fast-trace* (remove (lambda (r) (equal? (plist-get r 'intent) words)) *fast-trace*))
    (ignore-errors
      (lambda ()
        (write-file! (fast-trace-path)
          (fold (lambda (acc r) (string-append (json-encode r #f) "\n" acc)) "" *fast-trace*))))
    words))

(define (fast-remembered-intents)
  (fast-distinct (filter fast-remembered
                         (filter string? (map (lambda (r) (plist-get r 'intent)) *fast-trace*)))))

(define-command "fast-forget-answer" "Forget the answer fast-code remembers for some words"
  (lambda ()
    (completing-read "Forget the answer to: " (fast-remembered-intents)
      (lambda (intent) (message (string-append "fast: forgot the answer to " (fast-forget-answer! intent))))
      'require-match #t)))

(define-command "fast-forget" "Forget a function fast-code learned"
  (lambda ()
    (completing-read "Forget: " (fast-learned-names)
      (lambda (name) (message (string-append "fast: forgot " (fast-forget! name)))))))

(define-command "fast-palette-install" "Send unmatched palette input to fast-code" (lambda () (message (fast-palette-install!))))
(define-command "fast-palette-remove" "Restore the plain command palette" (lambda () (message (fast-palette-remove!))))
(define-command "fast-toggle" "Toggle fast" (lambda () (set! fast-enabled? (not fast-enabled?)) (message (if fast-enabled? "fast: on" "fast: off"))))

;;; --- Completion -----------------------------------------------------
;;; ! is ( with a wider namespace. ( completes over bound Scheme names;
;;; ! completes over every recipe in the catalog, so the phrase is chosen
;;; from what exists instead of guessed at from what was typed.

(define (fast-capf-terms text)
  (filter (lambda (t) (not (equal? t "")))
          (string-split (string-downcase text) " ")))

(define (fast-capf-match? terms hay)
  (let ((lower (string-downcase hay)))
    (null? (filter (lambda (t) (not (string-contains? lower t))) terms))))

(define (fast-recipe-entries)
  (filter (lambda (e) (equal? (catalog--get e 'kind) "recipe")) (catalog)))

;;; The popup shows the expression as the doc: what RET will run is the
;;; only thing that separates two recipes with similar words.
(define (fast-capf-row e)
  (let ((name (catalog--get e 'name))
        (use (catalog--get e 'use)))
    (list name "recipe" "symbol" '() ""
          (if (string? use) (list (list "Documentation" use)) '()))))

;;; Aliases match but never display: accepting writes the title, so the
;;; input line ends up naming a recipe that exists.
(define (fast-capf-candidates query)
  (let* ((es (fast-recipe-entries))
         (terms (fast-capf-terms query))
         (lower (string-downcase query))
         (lead (filter (lambda (e)
                         (string-prefix? lower (string-downcase (catalog--get e 'name))))
                       es))
         (led (map (lambda (e) (catalog--get e 'name)) lead))
         (rest (filter (lambda (e)
                         (and (not (member (catalog--get e 'name) led))
                              (fast-capf-match?
                                terms
                                (string-append (catalog--get e 'name) " "
                                               (or (catalog--get e 'aliases) "")))))
                       es)))
    (map fast-capf-row
         (append lead
                 (map caddr
                      (sort (map (lambda (e)
                                   (list (string-byte-length (catalog--get e 'name))
                                         (catalog--get e 'name) e))
                                 rest)))))))

;;; The byte just past the leading !, skipping any space the input carries
;;; before it. #f when this input is not a bang input at all.
(define (fast-capf-start buf)
  (let ((text (buffer-text buf))
        (lim (buffer-size buf)))
    (let loop ((i (chat-input-start buf)))
      (cond ((>= i lim) #f)
            ((equal? (substring-bytes text i (+ i 1)) "!") (+ i 1))
            ((member (substring-bytes text i (+ i 1)) '(" " "\t")) (loop (+ i 1)))
            (else #f)))))

;;; What you typed is the first row, so RET keeps your own words and the
;;; arrows reach a recipe. fast-code resolves any phrase, not only a title.
(define (fast-capf-with-typed typed cands)
  (let ((t (string-trim typed)))
    (if (or (equal? t "")
            (pair? (filter (lambda (c) (equal? (car c) t)) cands)))
        cands
        (cons (list t "as typed" "symbol" '() ""
                    (list (list "Documentation" "your words; fast-code writes the Scheme")))
              cands))))

;;; Replaces the whole phrase after the !, not the word before point: a
;;; recipe title is several words, and completing only the last would
;;; leave the line saying something no recipe is called.
(define (fast-chat-capf)
  (let* ((buf (current-buffer))
         (s (and fast-enabled? (fast-capf-start buf)))
         (e (point)))
    (and s (>= e s)
         (let* ((typed (substring-bytes (buffer-text buf) s e))
                (cands (fast-capf-candidates typed)))
           (and (pair? cands) (list s e (fast-capf-with-typed typed cands)))))))

(category! 'fast-code)
(public! 'fast-resolve "(fast-resolve INTENT K) -- K gets (code CODE [defined NAME] source SOURCE ms MS), or code #f with a reason; the model writes a function when a job needs one")
(public! 'fast-run! "(fast-run! INTENT) -- resolve INTENT and run it against the frame")
(public! 'fast-this-buffer "(fast-this-buffer) -- the buffer 'it' and 'this' mean: the first one on screen that is not a chat")
(public! 'fast-show-learned "(fast-show-learned) -- show the functions fast-code learned, a Scheme file, in the other window")
(public! 'fast-trace-text "(fast-trace-text N) -- the last N fast-code resolutions, stage by stage; M-x fast-trace shows them")
(public! 'fast-learned-names "(fast-learned-names) -- the names of the functions fast-code learned")
(public! 'fast-forget! "(fast-forget! NAME) -- drop a learned function")
(public! 'fast-chat-ran! "(fast-chat-ran! TEXT PRINTED) -- a ! run printed PRINTED; a clean one keeps the function it wrote")
(public! 'fast-chat-input? "(fast-chat-input? TEXT) -- #t when a chat input opens with !")
(public! 'fast-chat-resolve "(fast-chat-resolve TEXT K) -- K gets the Scheme a !-input resolves to")
(public! 'fast-chat-capf "(fast-chat-capf) -- completion over every recipe for a !-input")
(public! 'fast-palette-install! "(fast-palette-install!) -- palette input falls through to fast-code")
(public! 'fast-palette-remove! "(fast-palette-remove!) -- restore the plain palette")

;; learned functions come back first; both are safe to re-run after a reload
(fast-learned-load!)
(fast-palette-install!)
(set! *command-palette-row-delete* (lambda (name) (fast-forget-answer! name)))
