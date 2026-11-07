;;;; tool-results.scm -- a long tool result goes to a file, and the model
;;;; gets a reference to it
;;;;
;;;; The model reads every tool result again on every later turn. In 794
;;;; saved chats, tool results were 78% of all the bytes, and most of them
;;;; came from asks the chat had finished. So a result longer than
;;;; tool-result-max-bytes does not go to the model. The editor writes it
;;;; to a file beside the chat's log, and the model gets the path, the
;;;; size, the shape of the content and one call that reads a part of it.
;;;;
;;;; The cut happens where the result leaves the editor: the MCP proxy
;;;; (tools.scm) for the ACP lanes and chat-tool-dispatch (chat.scm) for
;;;; the api lane. A cut in the chat record only would come too late: an
;;;; ACP backend keeps its own copy of what the tool returned.
;;;;
;;;; The cut happens once. A result already sent never changes, because a
;;;; changed result breaks the provider's prompt cache.

(domain! 'chat)
(effects! '(write))

(defcustom 'tool-result-max-bytes 4000
  "A tool result longer than this goes to a file, and the model gets the path, the shape of the content and a call that reads a part. 0 sends every result whole."
  'group 'chat 'type 'integer)

;; How many lines of a text result the reference shows at the start and at
;; the end. Errors are usually at the end of a log.
(define tool-result-preview-lines 15)

;; How long one preview line may be.
(define tool-result-preview-line-chars 160)

;; How many items or keys the shape of a list or an object names.
(define tool-result-shape-items 25)

;;; --- the format ---------------------------------------------------------------

;; a parsed JSON object is a plist whose keys are symbols. A JSON array of
;; strings parses to strings, never to symbols, so the test is safe.
(define (tool-result--object? v)
  (and (pair? v)
       (let loop ((v v))
         (cond ((null? v) #t)
               ((and (symbol? (car v)) (pair? (cdr v))) (loop (cddr v)))
               (else #f)))))

(define (tool-result--json text)
  (let ((t (string-trim text)))
    (and (or (string-prefix? "{" t) (string-prefix? "[" t))
         (let ((v (ignore-errors (lambda () (json-parse t)))))
           (and v (list v))))))

;; the separator of a CSV or TSV text, or #f. The first three lines must
;; split into the same number of fields, two or more.
(define (tool-result--csv-separator lines)
  (and (pair? lines) (pair? (cdr lines)) (pair? (cddr lines))
       (let try ((seps (list "\t" ",")))
         (cond ((null? seps) #f)
               ((let ((n (length (string-split (car lines) (car seps)))))
                  (and (>= n 2)
                       (= n (length (string-split (cadr lines) (car seps))))
                       (= n (length (string-split (caddr lines) (car seps))))))
                (car seps))
               (else (try (cdr seps)))))))

(define (tool-result--sexp text)
  (let ((t (string-trim text)))
    (and (string-prefix? "(" t)
         (let ((forms (ignore-errors (lambda () (scheme-read t)))))
           (and (pair? forms) (null? (cdr forms)) (pair? (car forms))
                (list (car forms)))))))

;; (FORMAT VALUE): json with the parsed value, sexp with the read list,
;; csv with the separator, or text
(define (tool-result-format text)
  (let ((json (tool-result--json text)))
    (if json
        (list 'json (car json))
        (let ((sexp (tool-result--sexp text)))
          (if sexp
              (list 'sexp (car sexp))
              (let ((sep (tool-result--csv-separator (string-split text "\n"))))
                (if sep (list 'csv sep) (list 'text #f))))))))

(define (tool-result--extension format sep)
  (cond ((equal? format 'json) "json")
        ((equal? format 'sexp) "scm")
        ((equal? format 'csv) (if (equal? sep "\t") "tsv" "csv"))
        (else "txt")))

;;; --- the shape ------------------------------------------------------------------

(define (tool-result--clip-chars s n)
  (if (> (string-length s) n) (string-append (substring s 0 n) "...") s))

;; one JSON value as a short sketch: an object names its keys, an array its
;; length and the shape of its first element, a long string its length
(define (tool-result-json-shape v depth)
  (cond ((tool-result--object? v)
         (if (<= depth 0)
             (string-append "{" (number->string (quotient (length v) 2)) " keys}")
             (let loop ((v v) (n 0) (parts '()))
               (cond ((null? v)
                      (string-append "{" (string-join (reverse parts) ", ") "}"))
                     ((>= n tool-result-shape-items)
                      (string-append "{" (string-join (reverse parts) ", ")
                                     ", ... " (number->string (quotient (length v) 2))
                                     " more keys}"))
                     (else
                      (loop (cddr v) (+ n 1)
                            (cons (string-append (symbol->string (car v)) ": "
                                                 (tool-result-json-shape (cadr v) (- depth 1)))
                                  parts)))))))
        ((pair? v)
         (string-append "[" (number->string (length v)) " x "
                        (tool-result-json-shape (car v) depth) "]"))
        ((null? v) "[]")
        ((string? v)
         (if (<= (string-length v) 40)
             (json-encode v)
             (string-append "string(" (number->string (string-length v)) ")")))
        ((number? v) (number->string v))
        ((equal? v #t) "true")
        ((equal? v #f) "null")
        (else (value->string v))))

;; the first key path into the value that ends at a list or a scalar, as
;; the example in the read call
(define (tool-result--json-example v)
  (cond ((and (tool-result--object? v) (pair? v))
         ;; the first key that holds an array, else the first key
         (let loop ((kv v))
           (cond ((null? kv) (list (car v)))
                 ((and (pair? (cadr kv)) (not (tool-result--object? (cadr kv))))
                  (list (car kv) 0))
                 (else (loop (cddr kv))))))
        ((pair? v) (list 0))
        (else '())))

(define (tool-result--lines-preview lines)
  (string-join
    (map (lambda (l) (tool-result--clip-chars l tool-result-preview-line-chars)) lines)
    "\n"))

(define (tool-result--head-tail lines)
  (let ((n (length lines))
        (k tool-result-preview-lines))
    (if (<= n (* 2 k))
        (tool-result--lines-preview lines)
        (string-append
          (tool-result--lines-preview (take lines k))
          "\n... " (number->string (- n (* 2 k))) " lines ...\n"
          (tool-result--lines-preview (tool-result--drop lines (- n k)))))))

(define (tool-result--drop xs n)
  (if (or (null? xs) (<= n 0)) xs (tool-result--drop (cdr xs) (- n 1))))

(define (tool-result--printed-items items budget)
  (let loop ((xs items) (left budget) (acc '()))
    (if (or (null? xs) (<= left 0))
        (reverse acc)
        (let ((s (tool-result--clip-chars (value->string (car xs)) 300)))
          (loop (cdr xs) (- left (string-length s)) (cons s acc))))))

;;; --- the reference --------------------------------------------------------------

(define (tool-result--call path selector)
  (string-append "(tool-result-read " (json-encode path) " '" selector ")"))

(define (tool-result-reference path text format value)
  (let* ((bytes (number->string (string-byte-length text)))
         (lines (string-split text "\n"))
         (nlines (number->string (length lines)))
         (head (lambda (kind)
                 (string-append "[The tool result is " bytes " bytes of " kind
                                ". It is not in this message: the editor saved it to "
                                path ". Read a part with eval-scheme-read.]\n"))))
    (cond
      ((equal? format 'json)
       (string-append
         (head "JSON")
         "shape: " (tool-result-json-shape value 3) "\n"
         "read one value: "
         (tool-result--call path
           (value->string (cons 'path (tool-result--json-example value))))
         "\nThe path names object keys and array indexes from 0."))
      ((equal? format 'sexp)
       (let* ((n (length value))
              (shown (tool-result--printed-items value 1500)))
         (string-append
           (head "an s-expression")
           "a list of " (number->string n) " items. The first "
           (number->string (length shown)) ":\n"
           (string-join shown "\n") "\n"
           "read items: " (tool-result--call path "(items 1 20)")
           " (from 1, both ends included)\n"
           "find items: " (tool-result--call path "(match \"TEXT\")"))))
      ((equal? format 'csv)
       (string-append
         (head (if (equal? value "\t") "TSV" "CSV"))
         (number->string (- (length lines) 1)) " rows after the header line.\n"
         (tool-result--lines-preview (take lines (min 4 (length lines)))) "\n"
         "read rows: " (tool-result--call path "(rows 1 50)")
         " (the header, then rows 1 to 50)\n"
         "find rows: " (tool-result--call path "(match \"TEXT\")")))
      (else
       (string-append
         (head "text")
         nlines " lines. The start and the end:\n"
         (tool-result--head-tail lines) "\n"
         "read lines: " (tool-result--call path "(lines 1 100)")
         " (from 1, both ends included)\n"
         "find lines: " (tool-result--call path "(match \"TEXT\")")
         (if (and (< (length lines) 4) (> (string-length text) 2000))
             (string-append "\nread characters: " (tool-result--call path "(chars 0 4000)"))
             ""))))))

;;; --- the store ------------------------------------------------------------------

(define *tool-result-seq* 0)

(define (tool-result--safe-name name)
  (let ((s (re-replace-all "[^A-Za-z0-9_-]+" (or name "tool") "-")))
    (tool-result--clip-chars s 40)))

;; the folder for BUF's results: beside its chat log, one folder per
;; conversation, so a reset starts a new one and the archive keeps the old
(define (tool-result-dir buf)
  (if (and buf (buffer-exists? buf)
           (boundp (quote chat-log-dir-for)) (boundp (quote chat-log-id!)))
      (string-append (chat-log-dir-for buf) "/" (chat-log-id! buf) ".results")
      (string-append (compos-home) "/tool-results")))

(define (tool-result--path buf name ext)
  (set! *tool-result-seq* (+ *tool-result-seq* 1))
  (string-append (tool-result-dir buf) "/"
                 (number->string (current-time)) "-"
                 (number->string *tool-result-seq*) "-"
                 (tool-result--safe-name name) "." ext))

;; MCP content blocks (an image) start with a NUL and pass as they are
(define (tool-result--content? text)
  (string-prefix? "\x00;" text))

;; TEXT itself when it is short, else the reference to the file that holds
;; it. BUF is the chat the result belongs to, or #f. A write that fails
;; sends TEXT whole: a long result is a cost, a lost one is a bug.
(define (tool-result-store buf name text)
  (let ((cap tool-result-max-bytes))
    (if (or (not (string? text))
            (<= cap 0)
            (<= (string-byte-length text) cap)
            (tool-result--content? text))
        text
        (let* ((f (tool-result-format text))
               (format (car f))
               (value (cadr f))
               (path (tool-result--path buf name
                       (tool-result--extension format value)))
               (ok (ignore-errors
                     (lambda ()
                       (make-directory! (tool-result-dir buf))
                       (write-file! path text)
                       (file-exists? path)))))
          (if ok
              (tool-result-reference path text format value)
              text)))))

;;; --- the reader -----------------------------------------------------------------

(define (tool-result--range xs from to)
  ;; FROM and TO count from 1 and both are included
  (let* ((from (max 1 from))
         (dropped (tool-result--drop xs (- from 1))))
    (take dropped (max 0 (min (length dropped) (+ 1 (- to from)))))))

(define (tool-result--json-at v path)
  (cond ((null? path) v)
        ((not (pair? v)) #f)
        ((number? (car path))
         (and (< (car path) (length v)) (>= (car path) 0)
              (tool-result--json-at (nth (car path) v) (cdr path))))
        (else
         (let ((k (if (string? (car path)) (string->symbol (car path)) (car path))))
           (and (tool-result--object? v)
                (tool-result--json-at (plist-get v k) (cdr path)))))))

(define (tool-result--numbered lines start)
  (let loop ((ls lines) (n start) (acc '()))
    (if (null? ls)
        (string-join (reverse acc) "\n")
        (loop (cdr ls) (+ n 1)
              (cons (string-append (number->string n) ": " (car ls)) acc)))))

(define (tool-result--matching lines needle)
  (let loop ((ls lines) (n 1) (acc '()) (k 0))
    (cond ((or (null? ls) (>= k 200))
           (if (null? acc)
               (string-append "no line holds " (json-encode needle))
               (string-join (reverse acc) "\n")))
          ((string-contains? (car ls) needle)
           (loop (cdr ls) (+ n 1)
                 (cons (string-append (number->string n) ": " (car ls)) acc)
                 (+ k 1)))
          (else (loop (cdr ls) (+ n 1) acc k)))))

(define (tool-result-read path &optional selector)
  (let ((text (and (file-exists? path) (read-file path))))
    (cond
      ((not (string? text)) (string-append "no tool result at " path))
      ((not (pair? selector))
       (let ((f (tool-result-format text)))
         (tool-result-reference path text (car f) (cadr f))))
      (else
       (let ((kind (car selector))
             (args (cdr selector)))
         (cond
           ((equal? kind 'lines)
            (tool-result--numbered
              (tool-result--range (string-split text "\n") (car args) (cadr args))
              (max 1 (car args))))
           ((equal? kind 'rows)
            (let ((lines (string-split text "\n")))
              (string-join
                (cons (car lines)
                      (tool-result--range (cdr lines) (car args) (cadr args)))
                "\n")))
           ;; an s-expression result is often one line, so its match
           ;; searches the items, numbered from 1 as (items FROM TO) counts
           ((equal? kind 'match)
            (let ((v (tool-result--sexp text)))
              (tool-result--matching
                (if v (map value->string (car v)) (string-split text "\n"))
                (car args))))
           ((equal? kind 'chars)
            (let* ((n (string-length text))
                   (from (max 0 (min n (car args))))
                   (to (max from (min n (cadr args)))))
              (substring text from to)))
           ((equal? kind 'items)
            (let ((v (tool-result--sexp text)))
              (if v
                  (string-join
                    (map value->string (tool-result--range (car v) (car args) (cadr args)))
                    "\n")
                  "this result is not one s-expression list")))
           ((equal? kind 'path)
            (let ((v (tool-result--json text)))
              (if v
                  (json-encode (tool-result--json-at (car v) args))
                  "this result is not JSON")))
           (else
            (string-append "unknown selector " (value->string kind)
                           ": use lines, rows, match, chars, items or path"))))))))

(effects! '(read))
(public! 'tool-result-read
  "(tool-result-read PATH [SELECTOR]) -- read a part of a saved tool result. SELECTOR is (lines FROM TO), (rows FROM TO), (match TEXT), (chars FROM TO), (items FROM TO) or (path KEY-OR-INDEX ...)")
(public! 'tool-result-format
  "(tool-result-format TEXT) -- (FORMAT VALUE): json, sexp, csv or text, with the parsed value or the separator")
(effects! '(write))
(public! 'tool-result-store
  "(tool-result-store BUF NAME TEXT) -- TEXT when it is short, else save it beside BUF's chat log and answer a reference with its shape")

(provide 'tool-results)
