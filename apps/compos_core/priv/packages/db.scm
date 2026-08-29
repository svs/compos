;;; db.scm --- databases: named connections, results, and rendering.
;;;
;;; Policy over the Compos.Core.DB mechanism. The driver owns the wire
;;; protocol, authentication, and type decoding, because Scheme cannot
;;; supply those. This package owns what a caller sees: a named
;;; connection, a result a program can read, and a table a person can.
;;;
;;; A query never renders by itself. `db-query` answers with data, and
;;; `db-render-table` turns that data into text only when somebody asks.

(package! 'db)
(category! 'system)
(domain! 'data)
(effects! '(write external))

;;; --- registry ----------------------------------------------------------------

(define *db-registry* '())        ; ((name spec) ...)

(define (db-register! name spec)
  (set! *db-registry*
    (cons (list name spec)
          (remove (lambda (e) (equal? (car e) name)) *db-registry*)))
  name)

(define (db-spec name)
  (let ((e (assoc name *db-registry*)))
    (and e (cadr e))))

;; Which fields of a database spec may carry a "@VAR" reference. A
;; password belongs in the key chain, never in a config file.
(define db-secret-fields
  '(password value user value username value host value
    database value socket value socket_dir value))

(define (db-resolve-spec spec) (spec-resolve spec db-secret-fields))

;; Open a registered database once and reuse it. The connection stays
;; open, so a query pays no connect or authentication cost. The spec
;; resolves here, one step before it leaves for Elixir, so the driver
;; never sees a reference and the config file never holds a secret.
(define (db-ensure! name)
  (let ((spec (db-spec name)))
    (cond ((not spec) (error (string-append "db: no spec registered for " name)))
          ((db-connected? name) name)
          (else (db-connect! name (db-resolve-spec spec)) name))))

;;; --- reading a result --------------------------------------------------------

(define (db-columns result) (plist-get result 'columns))
(define (db-rows result) (plist-get result 'rows))
(define (db-count result) (plist-get result 'count))
(define (db-command result) (plist-get result 'command))

;; The first column of the first row: what a `select count(*)` is for.
(define (db-value result)
  (let ((rows (db-rows result)))
    (and (pair? rows) (pair? (car rows)) (car (car rows)))))

;; ((COLUMN VALUE) ...) per row, for a caller that would rather name a
;; column than count positions. `assoc` reads one out by name.
(define (db-alists result)
  (let ((cols (db-columns result)))
    (map (lambda (row)
           (let loop ((i 0) (out '()))
             (if (>= i (length cols))
                 (reverse out)
                 (loop (+ i 1) (cons (list (nth i cols) (nth i row)) out)))))
         (db-rows result))))

;;; --- rendering ---------------------------------------------------------------

(define (db--cell v)
  (cond ((equal? v #f) "NULL")        ; SQL NULL, which is not the empty string
        ((equal? v #t) "t")
        ((string? v) v)
        ((number? v) (number->string v))
        ;; an array or a jsonb column is a composite value; JSON is the
        ;; one text form that keeps its shape
        (else (json-encode v))))

(define (db--widths cols rows)
  (let loop ((i 0) (out '()))
    (if (>= i (length cols))
        (reverse out)
        (loop (+ i 1)
              (cons (fold (lambda (w row)
                            (max w (string-length (db--cell (nth i row)))))
                          (string-length (nth i cols))
                          rows)
                    out)))))

(define (db--pad s w) (string-pad-right s w))

;; What psql shows under a result: a row count for a query that returned
;; rows, and the command with its count for one that changed them.
(define (db--footer result)
  (let ((n (db-count result))
        (cmd (db-command result)))
    (if (equal? cmd "select")
        (string-append "(" (number->string n) (if (equal? n 1) " row)" " rows)"))
        (string-append (string-upcase cmd) " " (number->string n)))))

;; A plain text table: header, rule, rows, then a count footer.
(define (db-render-table result)
  (let* ((cols (db-columns result))
         (rows (db-rows result))
         (ws (db--widths cols rows))
         (line (lambda (cells)
                 (string-join
                   (let loop ((cs cells) (w ws) (out '()))
                     (if (null? cs)
                         (reverse out)
                         (loop (cdr cs) (cdr w)
                               (cons (db--pad (db--cell (car cs)) (car w)) out))))
                   " | "))))
    (string-join
      (append
        (list (line cols)
              (string-join (map (lambda (w) (string-repeat "-" w)) ws) "-+-"))
        (map line rows)
        (list (db--footer result)))
      "\n")))

;;; --- catalog -----------------------------------------------------------------

(public! 'db-register!
  "(db-register! NAME SPEC) — name a database; SPEC has 'adapter 'database 'user 'password 'host or 'socket_dir 'port 'ssl")
(public! 'db-ensure!
  "(db-ensure! NAME) — open the registered database once and reuse the live connection")
(public! 'db-spec "(db-spec NAME) — the spec registered for NAME, or #f")
(public! 'db-resolve-spec
  "(db-resolve-spec SPEC) — resolve the \"@VAR\" references in a database spec; a password belongs in the key chain")
(public! 'db-columns "(db-columns RESULT) — the column names of a query result")
(public! 'db-rows "(db-rows RESULT) — the rows of a query result, each a list of values")
(public! 'db-count "(db-count RESULT) — how many rows the query returned or changed")
(public! 'db-command "(db-command RESULT) — the SQL command that ran: select, insert, update")
(public! 'db-value "(db-value RESULT) — the first column of the first row, for a scalar query")
(public! 'db-alists
  "(db-alists RESULT) — the rows as ((COLUMN VALUE) ...), to read a column by name with assoc")
(public! 'db-render-table
  "(db-render-table RESULT) — the result as a plain text table; SQL NULL prints as NULL")

;; The primitives underneath, which are Elixir builtins: without these
;; lines the catalog cannot answer somebody searching for a database.
(public! 'db-connect!
  "(db-connect! NAME SPEC) — open a long-lived sql database connection and keep it open")
(public! 'db-disconnect! "(db-disconnect! NAME) — close the database connection NAME")
(public! 'db-connected? "(db-connected? NAME) — #t when the database connection is open")
(public! 'db-query
  "(db-query NAME-OR-TRANSACTION SQL [PARAMS] [CB]) — return RESULT on the calling lane; with CB, answer asynchronously with (OK RESULT)")
(public! 'db-with-transaction
  "(db-with-transaction NAME PROC) — call PROC with a scoped transaction handle; commit and return its value, or roll back on error")
(public! 'db-list "(db-list) — every open database as (name adapter database)")
(public! 'db-adapters "(db-adapters) — the database adapters this build can open")

(effects! '(read external))
(defrecipe! "query a postgres database"
  "(db-render-table (db-query {{name}} {{sql}}))"
  (list (list 'name "Database name: ") (list 'sql "SQL: ")))
(defrecipe! "connect to a postgres database"
  "(db-register! {{name}} (list 'adapter \"postgres\" 'database {{database}}))"
  (list (list 'name "Connection name: ") (list 'database "Database: ")))
(defrecipe! "see the open databases"
  "(db-list)" '())
