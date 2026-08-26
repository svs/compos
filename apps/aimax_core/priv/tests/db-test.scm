;;; db-test.scm --- reading and rendering a database result.
;;;
;;; These use a literal result plist, so they need no server: the shape is
;;; the contract between the mechanism and every caller.

(define db--fixture
  '(columns ("id" "name" "note")
    rows ((1 "ada" #f) (22 "linus" ""))
    count 2
    command "select"))

(deftest 'a-result-answers-by-column-name
  "a caller names a column instead of counting positions"
  (lambda ()
    (check-equal! (db-columns db--fixture) '("id" "name" "note") "the columns")
    (check-equal! (db-count db--fixture) 2 "the count")
    (check-equal! (db-command db--fixture) "select" "the command")
    (check-equal! (db-value db--fixture) 1 "the scalar")
    (check-equal! (cadr (assoc "name" (car (db-alists db--fixture)))) "ada" "a named cell")))

(deftest 'rendering-separates-sql-null-from-an-empty-string
  "the two look the same in a table and mean different things"
  (lambda ()
    (let ((text (db-render-table db--fixture)))
      (check-true! (string-contains? text "NULL") "the null prints as NULL")
      (check-true! (string-contains? text "ada") "a value prints")
      (check-true! (string-contains? text "(2 rows)") "the footer counts")
      ;; the empty string is not the word NULL
      (check-equal!
        (length (filter (lambda (l) (string-contains? l "NULL")) (string-split text "\n")))
        1 "only the real null says NULL"))))

(deftest 'the-footer-says-what-the-command-did
  "a select counts rows; a command that changed them names itself"
  (lambda ()
    (check-true!
      (string-contains? (db-render-table '(columns ("a") rows ((1)) count 1 command "select"))
                        "(1 row)")
      "one row is not one rows")
    (check-true!
      (string-contains? (db-render-table '(columns () rows () count 12 command "update"))
                        "UPDATE 12")
      "a command footer names the command")))

(deftest 'a-rendered-table-lines-up-under-its-headings
  "a column is as wide as its widest cell, heading included"
  (lambda ()
    (let* ((lines (string-split (db-render-table db--fixture) "\n"))
           (header (car lines))
           (rule (cadr lines)))
      (check-equal! (string-length header) (string-length rule) "the rule matches the header"))))

(deftest 'a-query-never-renders-by-itself
  "execution returns data; text is a separate request"
  (lambda ()
    ;; the result a caller holds is a plist, not a string
    (check-true! (pair? db--fixture) "the result is data")
    (check-true! (string? (db-render-table db--fixture)) "rendering is asked for")))

(deftest 'a-database-spec-survives-under-its-name
  "a caller names a database once and reconnects from the name"
  (lambda ()
    (db-register! "t-db-reg" '(adapter "postgres" database "app"))
    (check-equal! (plist-get (db-spec "t-db-reg") 'database) "app" "the spec")
    (check-equal! (db-spec "t-db-nothing") #f "an unregistered name")))

(deftest 'apropos-finds-the-database-api-by-what-it-is-for
  "somebody writing a connector searches for the job"
  (lambda ()
    (for-each
      (lambda (q)
        (check-true!
          (pair? (filter (lambda (e)
                           (string-contains? (or (plist-get e 'qualified-name) "") "db"))
                         (apropos q)))
          (string-append "apropos finds the database api for: " q)))
      '("postgres" "sql query"))))
