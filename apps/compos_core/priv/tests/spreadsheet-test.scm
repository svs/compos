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
    (let ((backend-rows (apropos "spreadsheet-register-backend!"))
          (chart-rows (apropos "spreadsheet-add-chart!")))
      (check-true!
        (pair?
          (filter
            (lambda (row)
              (equal? (plist-get row 'name) "spreadsheet-register-backend!"))
            backend-rows))
        "apropos finds backend registration")
      (check-true!
        (pair?
          (filter
            (lambda (row)
              (equal? (plist-get row 'name) "spreadsheet-add-chart!"))
            chart-rows))
        "apropos finds chart creation"))))

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

(deftest 'spreadsheet-agent-api-manages-embedded-charts
  "agents can add, update, list, and delete persistent charts"
  (lambda ()
    (let ((backend 'zz-sheet-chart-memory)
          (buffer "*zz-sheet-chart-api*")
          (stored
            "{\"version\":1,\"sheets\":[{\"name\":\"Budget\",\"data\":[[\"Month\",\"Spend\"],[\"Jan\",10],[\"Feb\",12]]}]}"))
      (spreadsheet-register-backend!
        backend
        (lambda (source) stored)
        (lambda (source text) (set! stored text) #t))
      (buffer-create buffer)
      (buffer-set-local! buffer 'spreadsheet-backend backend)
      (buffer-set-local! buffer 'spreadsheet-source "memory:charts")
      (check-true!
        (spreadsheet-add-chart!
          buffer "Budget" "monthly-spend" "line" "A1:B3" "D2:K18" "Monthly spending")
        "one call adds a chart")
      (check-equal! (plist-get (spreadsheet-chart-status buffer) 'state) "not-reported"
                    "a saved descriptor does not claim that its chart is visible")
      (let ((charts (spreadsheet-charts buffer)))
        (check-equal! (length charts) 1 "the workbook has one chart")
        (check-equal! (plist-get (car charts) 'anchor) "D2:K18"
                      "the chart keeps its sheet anchor"))
      (check-true!
        (spreadsheet-add-chart!
          buffer 1 "monthly-spend" "column" "A1:B3" "E3:L19" "Spending by month")
        "the same ID updates the chart")
      (let ((charts (spreadsheet-charts buffer)))
        (check-equal! (length charts) 1 "an update does not duplicate the chart")
        (check-equal! (plist-get (car charts) 'type) "column"
                      "the updated chart has the new type")
        (check-equal! (plist-get (car charts) 'sheet) "Budget"
                      "a numbered sheet stores its stable name"))
      (check-true! (spreadsheet-set-cell! buffer "Budget" "B3" 14)
                   "a cell edit keeps the workbook writable")
      (check-equal! (length (spreadsheet-charts buffer)) 1
                    "a cell edit preserves chart descriptors")
      (check-true!
        (spreadsheet--error?
          (spreadsheet-add-chart!
            buffer "Budget" "bad" "radar" "A1:B3" "D2:K18" "Bad chart"))
        "an unsupported chart type returns an error")
      (check-true!
        (spreadsheet--error?
          (spreadsheet-add-chart!
            buffer "Budget" "bad" "line" "not-a-range" "D2:K18" "Bad range"))
        "an invalid source range returns an error")
      (check-true! (spreadsheet-delete-chart! buffer "monthly-spend")
                   "the chart can be deleted")
      (check-equal! (spreadsheet-charts buffer) '()
                    "deletion leaves no chart descriptors")
      (check-true! (spreadsheet--error? (spreadsheet-delete-chart! buffer "missing"))
                   "a missing chart returns an error")
      (buffer-kill! buffer)
      (set! *spreadsheet-backends*
        (remove (lambda (entry) (equal? (car entry) backend))
                *spreadsheet-backends*)))))

(deftest 'spreadsheet-agent-api-creates-a-chart-with-safe-defaults
  "agents can create and verify a chart without choosing drawing internals"
  (lambda ()
    (let ((backend 'zz-sheet-simple-chart-memory)
          (buffer "*zz-sheet-simple-chart-api*")
          (stored
            "{\"version\":1,\"sheets\":[{\"name\":\"Rain\",\"data\":[[\"Month\",\"Rainfall\"],[\"Jan\",2]]}]}"))
      (spreadsheet-register-backend!
        backend
        (lambda (source) stored)
        (lambda (source text) (set! stored text) #t))
      (buffer-create buffer)
      (buffer-set-local! buffer 'mode-name "spreadsheet-mode")
      (buffer-set-local! buffer 'spreadsheet-backend backend)
      (buffer-set-local! buffer 'spreadsheet-source "memory:simple-chart")
      (check-true!
        (spreadsheet-chart! buffer "Rain" "A1:B2" "column" "Rainfall")
        "the simple API creates a chart")
      (let* ((chart (car (spreadsheet-charts buffer)))
             (status (spreadsheet-chart-status buffer)))
        (check-equal! (plist-get chart 'id) "chart-1" "the API creates an ID")
        (check-equal! (plist-get chart 'anchor) "D1:K16"
                      "the API puts the chart beside its data")
        (check-equal! (plist-get status 'configured) '("chart-1")
                      "status lists configured charts")
        (check-equal! (plist-get status 'mounted) '()
                      "status does not infer browser success")
        (check-equal! (plist-get status 'drawn) '()
                      "status does not infer ECharts success"))
      (check-equal!
        (car
          (spreadsheet-app-request
            buffer "chart-status"
            "{\"state\":\"ready\",\"mounted\":[\"chart-1\"],\"drawn\":[\"chart-1\"],\"failed\":[]}"))
        200 "the grid can report rendering status")
      (check-equal! (plist-get (spreadsheet-chart-status buffer) 'mounted)
                    '("chart-1") "the agent reads the grid report")
      (check-equal! (plist-get (spreadsheet-chart-status buffer) 'drawn)
                    '("chart-1") "the agent verifies that ECharts drew the chart")
      (buffer-kill! buffer)
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
