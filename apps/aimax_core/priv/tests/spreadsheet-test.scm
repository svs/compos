;;; spreadsheet-test.scm --- Spreadsheet backend and discovery tests.

(deftest 'spreadsheet-backend-is-pluggable
  "a registered backend serves the grid without file assumptions"
  (lambda ()
    (let ((buffer "*zz-sheet-backend*")
          (backend 'zz-sheet-memory)
          (stored "{\"version\":1,\"sheets\":[{\"name\":\"Memory\",\"data\":[[1]]}]}")
          (replacement "{\"version\":1,\"sheets\":[{\"name\":\"Changed\",\"data\":[[2]]}]}"))
      (spreadsheet-register-backend!
        backend
        (lambda (source) stored)
        (lambda (source text) (set! stored text) #t))
      (buffer-create buffer)
      (buffer-set-local! buffer 'mode-name "spreadsheet-mode")
      (buffer-set-local! buffer 'spreadsheet-backend backend)
      (buffer-set-local! buffer 'spreadsheet-source "memory:one")
      (check-contains! (cadr (spreadsheet-app-request buffer "read" ""))
                       "Memory" "the reader supplies workbook JSON")
      (check-equal! (car (spreadsheet-app-request buffer "write" replacement))
                    200 "the writer accepts workbook JSON")
      (check-contains! stored "Changed" "the registered writer owns storage")
      (buffer-kill! buffer)
      (set! *spreadsheet-backends*
        (remove (lambda (entry) (equal? (car entry) backend))
                *spreadsheet-backends*)))))

(deftest 'spreadsheet-api-is-discoverable
  "an agent can find workbook storage before it knows function names"
  (lambda ()
    (let ((rows (apropos "spreadsheet workbook backend")))
      (check-true!
        (pair?
          (filter
            (lambda (row)
              (equal? (plist-get row 'name) "spreadsheet-register-backend!"))
            rows))
        "apropos finds backend registration"))))

(deftest 'spreadsheet-agent-api-reads-and-writes-without-display
  "agents can change backend data by source without selecting a grid"
  (lambda ()
    (let ((backend 'zz-sheet-agent-memory)
          (stored "{\"version\":1,\"sheets\":[{\"name\":\"Before\",\"data\":[[1]]}]}"))
      (spreadsheet-register-backend!
        backend
        (lambda (source) stored)
        (lambda (source text) (set! stored text) #t))
      (check-equal!
        (plist-get (car (plist-get (spreadsheet-read-source backend "memory:agent") 'sheets)) 'name)
        "Before" "the source API reads without a buffer")
      (check-true!
        (spreadsheet-write-source!
          backend "memory:agent"
          (json-parse "{\"version\":1,\"sheets\":[{\"name\":\"Agent wrote this\",\"data\":[[2]]}]}"))
        "the source API writes through the registered backend")
      (check-contains! stored "Agent wrote this" "the agent write reached storage")
      (set! *spreadsheet-backends*
        (remove (lambda (entry) (equal? (car entry) backend))
                *spreadsheet-backends*)))))

(deftest 'spreadsheet-agent-api-edits-one-cell
  "agents can inspect sheets and change one A1 cell without rebuilding lists"
  (lambda ()
    (let ((backend 'zz-sheet-cell-memory)
          (buffer "*zz-sheet-cell-api*")
          (stored
            "{\"version\":1,\"activeSheet\":1,\"sheets\":[{\"name\":\"One\",\"data\":[[\"x\"]]},{\"name\":\"Two\",\"data\":[[\"\",\"\"],[\"\",\"1\"],[\"\",\"2\"],[\"\",\"w\"]]}]}"))
      (spreadsheet-register-backend!
        backend
        (lambda (source) stored)
        (lambda (source text) (set! stored text) #t))
      (buffer-create buffer)
      (buffer-set-local! buffer 'spreadsheet-backend backend)
      (buffer-set-local! buffer 'spreadsheet-source "memory:cells")
      (check-equal! (spreadsheet-sheet-names buffer) '("One" "Two")
                    "the agent sees sheet names")
      (check-equal! (spreadsheet-read-cell buffer 2 "B4") "w"
                    "a 1-based sheet number and A1 cell read directly")
      (check-equal! (length (plist-get (spreadsheet-read-sheet buffer "Two") 'data)) 4
                    "compact sheet reads omit unused trailing rows")
      (check-true! (spreadsheet-set-cell! buffer 2 "B4" "=SUM(B2:B3)")
                   "one call replaces the cell")
      (check-equal! (spreadsheet-read-cell buffer "Two" "B4") "=SUM(B2:B3)"
                    "the formula reached the named sheet")
      (check-equal! (plist-get (spreadsheet-read buffer) 'activeSheet) 1
                    "a cell edit preserves the selected sheet")
      (check-true! (spreadsheet--error? (spreadsheet-read-cell buffer 2 "B0"))
                   "invalid A1 notation returns a useful error")
      (buffer-kill! buffer)
      (set! *spreadsheet-backends*
        (remove (lambda (entry) (equal? (car entry) backend))
                *spreadsheet-backends*)))))
