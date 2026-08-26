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
