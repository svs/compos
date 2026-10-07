;;; spreadsheet.scm --- Editable workbooks with pluggable data backends.
;;;
;;; Scheme owns workbook identity, storage, commands, and mode state.
;;; Univer 0.25.1 supplies the isolated browser workbook.
;;; Univer uses the Apache-2.0 license.

(namespace! 'spreadsheet)
(domain! 'data)
(effects! '(read write))

(defgroup 'spreadsheet "Editable spreadsheet workbooks.")

(defcustom 'spreadsheet-default-backend 'text-file
  "The backend used by spreadsheet-open."
  'group 'spreadsheet 'type 'symbol)

;; Keep user-registered backends when this package reloads.
(unless (boundp '*spreadsheet-backends*)
  (define *spreadsheet-backends* '()))

(define (spreadsheet-register-backend! name read write)
  (set! *spreadsheet-backends*
    (cons (list name read write)
          (remove (lambda (entry) (equal? (car entry) name))
                  *spreadsheet-backends*)))
  name)

(define (spreadsheet--backend name)
  (assoc name *spreadsheet-backends*))

(define (spreadsheet--default-workbook)
  (list 'version 1
        'sheets
        (list
          (list 'name "Sheet1"
                'data
                (list (list ""))))))

(define (spreadsheet--workbook? value)
  (and (pair? value)
       (number? (plist-get value 'version))
       (pair? (plist-get value 'sheets))))

(define (spreadsheet--error message)
  (list 'error message))

(define (spreadsheet--error? value)
  (and (pair? value) (equal? (car value) 'error)))

(define (spreadsheet--visiting-buffer path)
  (let ((full (expand-path path)))
    (let loop ((buffers (buffer-list)))
      (cond
        ((null? buffers) #f)
        ((and (buffer-path (car buffers))
              (equal? (expand-path (buffer-path (car buffers))) full))
         (car buffers))
        (else (loop (cdr buffers)))))))

(define (spreadsheet--text-read path)
  (let* ((buffer (spreadsheet--visiting-buffer path))
         (text (if buffer
                   (buffer-text buffer)
                   (and (file-exists? path) (read-file path))))
         (value (and (string? text) (json-parse text))))
    (cond
      ((or (not text) (equal? (string-trim text) ""))
       (json-encode (spreadsheet--default-workbook) #t))
      ;; Return valid JSON unchanged. Empty JSON objects and arrays both map to
      ;; the empty Scheme list, so a decode/encode pass can change `{}` to `[]`.
      ((spreadsheet--workbook? value) text)
      (else (spreadsheet--error
              (string-append "The text backend cannot read " path
                             ". The file is not a spreadsheet workbook."))))))

(define (spreadsheet--text-write path text)
  (let ((value (json-parse text)))
    (if (not (spreadsheet--workbook? value))
        (spreadsheet--error "The workbook data is not valid JSON spreadsheet data.")
        (let* ((normalized (string-append (string-trim text) "\n"))
               (buffer (spreadsheet--visiting-buffer path)))
          (write-file! path normalized)
          (when buffer
            (buffer-replace-range! buffer 0 (buffer-size buffer) normalized)
            (buffer-mark-saved! buffer))
          #t))))

(spreadsheet-register-backend!
  'text-file spreadsheet--text-read spreadsheet--text-write)

(define (spreadsheet--read-json backend source)
  (let ((entry (spreadsheet--backend backend)))
    (if entry
        ((cadr entry) source)
        (spreadsheet--error
          (string-append "No spreadsheet backend named "
                         (symbol->string backend))))))

(define (spreadsheet--write-json backend source text)
  (let ((entry (spreadsheet--backend backend)))
    (if entry
        ((caddr entry) source text)
        (spreadsheet--error
          (string-append "No spreadsheet backend named "
                         (symbol->string backend))))))

(define (spreadsheet-read-source backend source)
  (let ((result (spreadsheet--read-json backend source)))
    (if (spreadsheet--error? result) result (json-parse result))))

(define (spreadsheet--reload-source! backend source)
  (for-each
    (lambda (buffer)
      (when (and (equal? (buffer-local buffer 'mode-name) "spreadsheet-mode")
                 (equal? (buffer-local buffer 'spreadsheet-backend) backend)
                 (equal? (buffer-local buffer 'spreadsheet-source) source))
        (buffer-set-local! buffer 'spreadsheet-chart-runtime
          (list 'state "loading" 'mounted '() 'drawn '() 'failed '()))
        (app-reload! buffer)))
    (buffer-list)))

(define (spreadsheet-write-source! backend source workbook)
  (if (not (spreadsheet--workbook? workbook))
      (spreadsheet--error "The workbook value is not valid.")
      (let ((result (spreadsheet--write-json backend source (json-encode workbook))))
        (unless (spreadsheet--error? result)
          (spreadsheet--reload-source! backend source))
        result)))

(define spreadsheet--column-letters
  '("A" "B" "C" "D" "E" "F" "G" "H" "I" "J" "K" "L" "M"
    "N" "O" "P" "Q" "R" "S" "T" "U" "V" "W" "X" "Y" "Z"))

(define (spreadsheet--letter-number letter)
  (let loop ((letters spreadsheet--column-letters) (number 1))
    (cond
      ((null? letters) #f)
      ((equal? (car letters) letter) number)
      (else (loop (cdr letters) (+ number 1))))))

(define (spreadsheet--column-number letters)
  (let ((text (string-upcase letters)))
    (let loop ((at 0) (number 0))
      (if (= at (string-byte-length text))
          (- number 1)
          (let ((digit (spreadsheet--letter-number
                         (substring-bytes text at (+ at 1)))))
            (and digit (loop (+ at 1) (+ (* number 26) digit))))))))

(define (spreadsheet--cell-coordinates cell)
  (let ((match (and (string? cell)
                    (re-match "^([A-Za-z]+)([1-9][0-9]*)$" cell))))
    (and match
         (let ((column (spreadsheet--column-number (cadr match)))
               (row (string->number (caddr match))))
           (and column (list column (- row 1)))))))

(define (spreadsheet--safe-nth values index)
  (cond
    ((or (< index 0) (null? values)) #f)
    ((= index 0) (car values))
    (else (spreadsheet--safe-nth (cdr values) (- index 1)))))

(define (spreadsheet--nth-or values index fallback)
  (cond
    ((or (< index 0) (null? values)) fallback)
    ((= index 0) (car values))
    (else (spreadsheet--nth-or (cdr values) (- index 1) fallback))))

(define (spreadsheet--replace-nth values index value fill)
  (cond
    ((= index 0) (cons value (if (null? values) '() (cdr values))))
    ((null? values)
     (cons fill (spreadsheet--replace-nth '() (- index 1) value fill)))
    (else
      (cons (car values)
            (spreadsheet--replace-nth (cdr values) (- index 1) value fill)))))

(define (spreadsheet--plist-put values key value)
  (let loop ((rest values) (result '()) (found #f))
    (cond
      ((null? rest)
       (if found (reverse result) (append (reverse result) (list key value))))
      ((null? (cdr rest)) (reverse (cons (car rest) result)))
      ((equal? (car rest) key)
       (loop (cddr rest) (cons value (cons key result)) #t))
      (else
       (loop (cddr rest) (cons (cadr rest) (cons (car rest) result)) found)))))

(define (spreadsheet--sheet-index sheets wanted)
  (if (number? wanted)
      (and (> wanted 0) (<= wanted (length sheets)) (- wanted 1))
      (let loop ((rest sheets) (index 0))
        (cond
          ((null? rest) #f)
          ((equal? (plist-get (car rest) 'name) wanted) index)
          (else (loop (cdr rest) (+ index 1)))))))

(define (spreadsheet--sheet workbook wanted)
  (let* ((sheets (plist-get workbook 'sheets))
         (index (and sheets (spreadsheet--sheet-index sheets wanted))))
    (and index (spreadsheet--safe-nth sheets index))))

(define (spreadsheet--trim-empty-tail values empty?)
  (let loop ((rest (reverse values)))
    (if (and (pair? rest) (empty? (car rest)))
        (loop (cdr rest))
        (reverse rest))))

(define (spreadsheet--compact-data data)
  (map
    (lambda (row)
      (spreadsheet--trim-empty-tail row (lambda (value) (equal? value ""))))
    (spreadsheet--trim-empty-tail
      data
      (lambda (row)
        (null? (filter (lambda (value) (not (equal? value ""))) row))))))

(define (spreadsheet-sheet-names buffer)
  (let ((workbook (spreadsheet-read buffer)))
    (if (spreadsheet--error? workbook)
        workbook
        (map (lambda (sheet) (plist-get sheet 'name))
             (plist-get workbook 'sheets)))))

(define (spreadsheet-read-sheet buffer sheet)
  (let* ((workbook (spreadsheet-read buffer))
         (record (and (not (spreadsheet--error? workbook))
                      (spreadsheet--sheet workbook sheet))))
    (cond
      ((spreadsheet--error? workbook) workbook)
      ((not record) (spreadsheet--error "No spreadsheet sheet matches that name or number."))
      (else
        (spreadsheet--plist-put
          record 'data (spreadsheet--compact-data (plist-get record 'data)))))))

(define (spreadsheet-read-cell buffer sheet cell)
  (let* ((workbook (spreadsheet-read buffer))
         (record (and (not (spreadsheet--error? workbook))
                      (spreadsheet--sheet workbook sheet)))
         (coords (spreadsheet--cell-coordinates cell)))
    (cond
      ((spreadsheet--error? workbook) workbook)
      ((not record) (spreadsheet--error "No spreadsheet sheet matches that name or number."))
      ((not coords) (spreadsheet--error "The cell must use A1 notation, for example B4."))
      (else
        (let ((row (spreadsheet--safe-nth (plist-get record 'data) (cadr coords))))
          (if row (spreadsheet--nth-or row (car coords) "") ""))))))

(define (spreadsheet-set-cell! buffer sheet cell value)
  (let* ((workbook (spreadsheet-read buffer))
         (sheets (and (not (spreadsheet--error? workbook))
                      (plist-get workbook 'sheets)))
         (sheet-index (and sheets (spreadsheet--sheet-index sheets sheet)))
         (coords (spreadsheet--cell-coordinates cell)))
    (cond
      ((spreadsheet--error? workbook) workbook)
      ((not sheet-index) (spreadsheet--error "No spreadsheet sheet matches that name or number."))
      ((not coords) (spreadsheet--error "The cell must use A1 notation, for example B4."))
      (else
        (let* ((record (spreadsheet--safe-nth sheets sheet-index))
               (data (plist-get record 'data))
               (row-index (cadr coords))
               (column-index (car coords))
               (row (or (spreadsheet--safe-nth data row-index) '()))
               (new-row (spreadsheet--replace-nth row column-index value ""))
               (new-data (spreadsheet--replace-nth data row-index new-row '()))
               (new-record (spreadsheet--plist-put record 'data new-data))
               (new-sheets (spreadsheet--replace-nth sheets sheet-index new-record '())))
          (spreadsheet-write! buffer
            (spreadsheet--plist-put workbook 'sheets new-sheets)))))))

(define spreadsheet--chart-types
  '("line" "column" "bar" "area" "pie" "doughnut" "scatter"))

(define (spreadsheet--range? value)
  (and (string? value)
       (re-match "^[A-Za-z]+[1-9][0-9]*(:[A-Za-z]+[1-9][0-9]*)?$" value)))

(define (spreadsheet--chart-id? value)
  (and (string? value)
       (re-match "^[A-Za-z0-9][A-Za-z0-9._-]*$" value)))

(define (spreadsheet--column-name index)
  (let loop ((number (+ index 1)) (letters '()))
    (if (= number 0)
        (string-join letters "")
        (let* ((adjusted (- number 1))
               (digit (modulo adjusted 26)))
          (loop (quotient adjusted 26)
                (cons (spreadsheet--safe-nth spreadsheet--column-letters digit)
                      letters))))))

(define (spreadsheet--default-chart-anchor source)
  (let* ((parts (string-split source ":"))
         (first (spreadsheet--cell-coordinates (car parts)))
         (last (spreadsheet--cell-coordinates
                 (if (pair? (cdr parts)) (cadr parts) (car parts))))
         (start-column (+ (car last) 2))
         (start-row (cadr first)))
    (string-append
      (spreadsheet--column-name start-column) (number->string (+ start-row 1))
      ":"
      (spreadsheet--column-name (+ start-column 7))
      (number->string (+ start-row 16)))))

(define (spreadsheet--next-chart-id workbook)
  (let loop ((number (+ (length (spreadsheet--charts workbook)) 1)))
    (let ((id (string-append "chart-" (number->string number))))
      (if (pair?
            (filter
              (lambda (chart) (equal? (plist-get chart 'id) id))
              (spreadsheet--charts workbook)))
          (loop (+ number 1))
          id))))

(define (spreadsheet--charts workbook)
  (let* ((extensions (plist-get workbook 'extensions))
         (compos (plist-get extensions 'compos))
         (charts (plist-get compos 'charts)))
    (if (pair? charts) charts '())))

(define (spreadsheet--put-charts workbook charts)
  (let* ((extensions (or (plist-get workbook 'extensions) '()))
         (compos (or (plist-get extensions 'compos) '()))
         (new-compos (spreadsheet--plist-put compos 'charts charts))
         (new-extensions (spreadsheet--plist-put extensions 'compos new-compos)))
    (spreadsheet--plist-put workbook 'extensions new-extensions)))

(define (spreadsheet-charts buffer)
  (let ((workbook (spreadsheet-read buffer)))
    (if (spreadsheet--error? workbook)
        workbook
        (spreadsheet--charts workbook))))

(define (spreadsheet-chart-status buffer)
  (let ((charts (spreadsheet-charts buffer)))
    (if (spreadsheet--error? charts)
        charts
        (let ((runtime (buffer-local buffer 'spreadsheet-chart-runtime)))
          (append
            (list 'configured
                  (map (lambda (chart) (plist-get chart 'id)) charts))
            (if (pair? runtime)
                runtime
                (list 'state "not-reported" 'mounted '() 'drawn '() 'failed '())))))))

(define (spreadsheet-add-chart! buffer sheet id type source anchor title)
  (let* ((workbook (spreadsheet-read buffer))
         (record (and (not (spreadsheet--error? workbook))
                      (spreadsheet--sheet workbook sheet))))
    (cond
      ((spreadsheet--error? workbook) workbook)
      ((not record) (spreadsheet--error "No spreadsheet sheet matches that name or number."))
      ((not (spreadsheet--chart-id? id))
       (spreadsheet--error "The chart ID can contain letters, numbers, dots, dashes, and underscores."))
      ((not (member type spreadsheet--chart-types))
       (spreadsheet--error "The chart type must be line, column, bar, area, pie, doughnut, or scatter."))
      ((not (spreadsheet--range? source))
       (spreadsheet--error "The chart source must be one A1 cell or range."))
      ((not (spreadsheet--range? anchor))
       (spreadsheet--error "The chart anchor must be one A1 cell or range."))
      (else
        (let* ((chart (list 'id id
                            'sheet (plist-get record 'name)
                            'type type
                            'source source
                            'anchor anchor
                            'title (if (string? title) title "")))
               (others
                 (remove
                   (lambda (old) (equal? (plist-get old 'id) id))
                   (spreadsheet--charts workbook))))
          (spreadsheet-write! buffer
            (spreadsheet--put-charts workbook (append others (list chart)))))))))

(define (spreadsheet-chart! buffer sheet source type title)
  (let ((workbook (spreadsheet-read buffer)))
    (if (spreadsheet--error? workbook)
        workbook
        (spreadsheet-add-chart!
          buffer sheet (spreadsheet--next-chart-id workbook) type source
          (if (spreadsheet--range? source)
              (spreadsheet--default-chart-anchor source)
              source)
          title))))

(define (spreadsheet-delete-chart! buffer id)
  (let ((workbook (spreadsheet-read buffer)))
    (if (spreadsheet--error? workbook)
        workbook
        (let* ((charts (spreadsheet--charts workbook))
               (remaining
                 (remove (lambda (chart) (equal? (plist-get chart 'id) id)) charts)))
          (if (= (length charts) (length remaining))
              (spreadsheet--error "No spreadsheet chart has that ID.")
              (spreadsheet-write! buffer
                (spreadsheet--put-charts workbook remaining)))))))

(define (spreadsheet-read buffer)
  (let ((backend (buffer-local buffer 'spreadsheet-backend))
        (source (buffer-local buffer 'spreadsheet-source)))
    (if (and backend source)
        (spreadsheet-read-source backend source)
        (spreadsheet--error "The buffer is not connected to a workbook backend."))))

(define (spreadsheet-write! buffer workbook)
  (let ((backend (buffer-local buffer 'spreadsheet-backend))
        (source (buffer-local buffer 'spreadsheet-source)))
    (cond
      ((not (spreadsheet--workbook? workbook))
       (spreadsheet--error "The workbook value is not valid."))
      ((not (and backend source))
       (spreadsheet--error "The buffer is not connected to a workbook backend."))
      (else
        (spreadsheet-write-source! backend source workbook)))))

;; The grid page's requests reach Scheme through the app bridge: the app
;; server hands GET, PUT and POST on _compos/app to app-request
;; (preview.scm), which asks each package's 'app-request handler. This one
;; answers for a spreadsheet buffer only.
(define (spreadsheet--app-request buffer method body)
  (and (buffer-exists? buffer)
       (equal? (buffer-local buffer 'mode-name) "spreadsheet-mode")
       (spreadsheet-app-request buffer
         (cond ((equal? method "GET") "read")
               ((equal? method "PUT") "write")
               ((equal? method "POST") "chart-status")
               (else method))
         body)))

(add-hook! '(app-request spreadsheet) 'spreadsheet--app-request)

;; The app request, as data arguments. It does not interpolate request
;; text into Scheme source.
(define (spreadsheet-app-request buffer method body)
  (if (not (and (buffer-exists? buffer)
                (equal? (buffer-local buffer 'mode-name) "spreadsheet-mode")))
      (list 404 (json-encode (list 'error "No spreadsheet uses this buffer.")))
      (let ((backend (buffer-local buffer 'spreadsheet-backend))
            (source (buffer-local buffer 'spreadsheet-source)))
        (cond
          ((equal? method "read")
           (let ((result (spreadsheet--read-json backend source)))
             (if (spreadsheet--error? result)
                 (list 400 (json-encode result))
                 (list 200 result))))
          ((equal? method "write")
           (let ((result (spreadsheet--write-json backend source body)))
             (if (spreadsheet--error? result)
                 (list 400 (json-encode result))
                 (list 200 (json-encode (list 'ok #t))))))
          ((equal? method "chart-status")
           (let ((report (json-parse body)))
             (if (and (pair? report)
                      (string? (plist-get report 'state)))
                 (begin
                   (buffer-set-local! buffer 'spreadsheet-chart-runtime report)
                   (list 200 (json-encode (list 'ok #t))))
                 (list 400 (json-encode (list 'error "The chart status is not valid."))))))
          (else
            (list 405 (json-encode (list 'error "Unsupported spreadsheet request."))))))))

(define (spreadsheet--app-html)
  (let ((dark? (theme-dark?)))
    (string-append
    ;; the script (spreadsheet/spreadsheet.js) reads the theme from here
    (if dark?
        "<!doctype html><html data-theme=\"dark\"><head><meta charset=\"utf-8\">"
        "<!doctype html><html data-theme=\"light\"><head><meta charset=\"utf-8\">")
    "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
    (if dark?
        "<meta name=\"color-scheme\" content=\"dark\">"
        "<meta name=\"color-scheme\" content=\"light\">")
    "<title>Spreadsheet</title>"
    "<link rel=\"stylesheet\" href=\"https://unpkg.com/@univerjs/preset-sheets-core@0.25.1/lib/index.css\">"
    "<link rel=\"stylesheet\" href=\"https://unpkg.com/@univerjs/preset-sheets-drawing@0.25.1/lib/index.css\">"
    "<style>"
    "*,*::before,*::after{box-sizing:border-box}html,body,#app{width:100%;height:100%;margin:0;padding:0}"
    (if dark?
        "html,body{overflow:hidden;background:#1f201f;color-scheme:dark;font:13px system-ui,sans-serif}"
        "html,body{overflow:hidden;background:#fff;color-scheme:light;font:13px system-ui,sans-serif}")
    "#app{position:relative;outline:none}"
    "#status{position:fixed;z-index:10000;right:12px;bottom:8px;max-width:50vw;padding:4px 9px;"
    (if dark?
        "border:1px solid rgba(201,198,190,.22);border-radius:999px;background:rgba(31,32,31,.9);color:#c9c6be;font:12px system-ui,sans-serif;box-shadow:0 1px 5px rgba(0,0,0,.28);pointer-events:none}"
        "border:1px solid rgba(120,120,120,.24);border-radius:999px;background:rgba(255,255,255,.9);color:#686868;font:12px system-ui,sans-serif;box-shadow:0 1px 5px rgba(0,0,0,.08);pointer-events:none}")
    (if dark?
        "#status[data-state=error]{color:#ffb4ab;border-color:#8c4a45;background:#321d1b}"
        "#status[data-state=error]{color:#b42318;border-color:#f3b7b2;background:#fff3f2}")
    "#status[data-state=saved]{opacity:0;transition:opacity 0s 2s}"
    ".compos-chart{width:100%;height:100%;min-width:1px;min-height:1px;overflow:hidden;"
    (if dark?
        "border:1px solid rgba(201,198,190,.22);border-radius:8px;background:#252625;box-shadow:0 2px 10px rgba(0,0,0,.32)}"
        "border:1px solid rgba(120,120,120,.28);border-radius:8px;background:#fff;box-shadow:0 2px 10px rgba(0,0,0,.12)}")
    ".compos-chart>*{pointer-events:none}"
    "</style></head><body>"
    "<div id=\"app\" tabindex=\"0\"></div><div id=\"status\" data-state=\"loading\">Loading workbook…</div>"
    "<script src=\"https://unpkg.com/react@18.3.1/umd/react.production.min.js\"></script>"
    "<script src=\"https://unpkg.com/react-dom@18.3.1/umd/react-dom.production.min.js\"></script>"
    "<script src=\"https://unpkg.com/rxjs@7.8.1/dist/bundles/rxjs.umd.min.js\"></script>"
    "<script src=\"https://unpkg.com/echarts@5.6.0/dist/echarts.min.js\"></script>"
    "<script src=\"https://unpkg.com/@univerjs/presets@0.25.1/lib/umd/index.js\"></script>"
    "<script src=\"https://unpkg.com/@univerjs/preset-sheets-core@0.25.1/lib/umd/index.js\"></script>"
    "<script src=\"https://unpkg.com/@univerjs/preset-sheets-core@0.25.1/lib/umd/locales/en-US.js\"></script>"
    "<script src=\"https://unpkg.com/@univerjs/preset-sheets-drawing@0.25.1/lib/umd/index.js\"></script>"
    "<script src=\"https://unpkg.com/@univerjs/preset-sheets-drawing@0.25.1/lib/umd/locales/en-US.js\"></script>"
    "<script src=\"spreadsheet.js\"></script></body></html>")))

;; The grid page loads its script as a relative file, and the app server
;; answers a relative file of a pathless buffer from its 'app-directory.
(define (spreadsheet--app-directory)
  (let ((js (locate-library "spreadsheet/spreadsheet.js")))
    (and js (substring js 0 (- (string-length js) (string-length "/spreadsheet.js"))))))

(define (spreadsheet--render! buffer)
  (buffer-set-local! buffer 'spreadsheet-chart-runtime
    (list 'state "loading" 'mounted '() 'drawn '() 'failed '()))
  (buffer-set-local! buffer 'app-directory (spreadsheet--app-directory))
  (buffer-replace-range! buffer 0 (buffer-size buffer) (spreadsheet--app-html))
  (buffer-set-local! buffer 'preview-renderer "html")
  (buffer-set-local! buffer 'render-mode "app")
  (buffer-set-read-only! buffer #t)
  (app-reload! buffer))

(define-command "spreadsheet-reload" "Reload the workbook from its backend"
  (lambda ()
    (app-reload! (current-buffer))
    (message "Reloaded the spreadsheet")))

(define-command "spreadsheet-save" "Confirm that the workbook app saves automatically"
  (lambda ()
    (message "Spreadsheet changes save automatically")))

(define-command "spreadsheet-visit-source" "Visit the current workbook data source"
  (lambda ()
    (let ((source (buffer-local (current-buffer) 'spreadsheet-source)))
      (if source
          (visit source (buffer-group (current-buffer)))
          (message "This spreadsheet has no file data source")))))

(define (spreadsheet--setup! buffer)
  (if (buffer-path buffer)
      (begin
        ;; The grid HTML belongs in its app buffer. Keep the JSON file buffer
        ;; intact when a user invokes this mode on the data source itself.
        (buffer-set-local! buffer 'render-mode #f)
        (buffer-set-local! buffer 'preview-renderer #f)
        (set-mode! "json-mode")
        (message "Use spreadsheet-open to open this workbook as a grid"))
      (begin
        
        (spreadsheet--render! buffer))))

(define (spreadsheet--refresh-theme!)
  (for-each
    (lambda (buffer)
      (when (and (equal? (buffer-local buffer 'mode-name) "spreadsheet-mode")
                 (buffer-local buffer 'spreadsheet-backend)
                 (buffer-local buffer 'spreadsheet-source))
        (spreadsheet--render! buffer)))
    (buffer-list)))

(add-hook! 'theme-change-hook 'spreadsheet--refresh-theme!)

;; A stale app renderer once put its HTML into a file-backed workbook buffer.
;; Refuse that payload at the final save boundary, even if locals are corrupt.
(define (spreadsheet--guard-html-save!)
  (let ((path (buffer-path (current-buffer)))
        (text (buffer-text (current-buffer))))
    (when (and path
               (string-suffix? ".sheet.json" (string-downcase path))
               (or (string-prefix? "<!doctype html" (string-downcase text))
                   (string-prefix? "<html" (string-downcase text))))
      (error "Refusing to save spreadsheet app HTML as workbook JSON"))))

(add-hook! 'before-save-hook 'spreadsheet--guard-html-save!)

(mode-icon! "spreadsheet-mode" "󰈛")

(define-mode "spreadsheet-mode"
  (lambda () (spreadsheet--setup! (current-buffer))))

(mode-keys! "spreadsheet-mode"
  '(
    ("C-x C-s" "spreadsheet-save")
    ("g" "spreadsheet-reload")
    ("v" "spreadsheet-visit-source")
    ("q" "quit-window")))

(mode-doc! "spreadsheet-mode"
  "Edit a workbook grid. Changes save to its backend. Press `C-g`, then `g`, to reload. Press `v` to visit the data file.")

(define (spreadsheet-open-with-backend! backend source)
  (let ((entry (spreadsheet--backend backend)))
    (if (not entry)
        (begin
          (message (string-append "No spreadsheet backend named "
                                  (symbol->string backend)))
          #f)
        (let* ((name (string-append "*Spreadsheet: " source "*"))
               (buffer (buffer-create name)))
          (buffer-set-local! buffer 'spreadsheet-backend backend)
          (buffer-set-local! buffer 'spreadsheet-source source)
          (switch-to-buffer! buffer)
          (set-mode! "spreadsheet-mode")
          buffer))))

(define (spreadsheet-open! path)
  (let ((source (expand-path path)))
    (when (and (equal? spreadsheet-default-backend 'text-file)
               (not (file-exists? source)))
      (spreadsheet--text-write source
        (json-encode (spreadsheet--default-workbook))))
    (spreadsheet-open-with-backend! spreadsheet-default-backend source)))

;;;###autoload
(define-command "spreadsheet-open" "Open a text-backed spreadsheet workbook"
  (lambda ()
    (read-file-name "Spreadsheet file: " spreadsheet-open!)))

(public! 'spreadsheet-register-backend!
  "(spreadsheet-register-backend! NAME READ WRITE) — READ returns workbook JSON; WRITE receives source and JSON")
(public! 'spreadsheet-open-with-backend!
  "(spreadsheet-open-with-backend! BACKEND SOURCE) — open SOURCE with a registered workbook backend")
(public! 'spreadsheet-open!
  "(spreadsheet-open! PATH) — open or create a JSON text workbook")
(public! 'spreadsheet-read-source
  "(spreadsheet-read-source BACKEND SOURCE) — read a workbook without displaying it")
(public! 'spreadsheet-write-source!
  "(spreadsheet-write-source! BACKEND SOURCE WORKBOOK) — replace a workbook and refresh open grids")
(public! 'spreadsheet-sheet-names
  "(spreadsheet-sheet-names BUFFER) — list sheet names without displaying the workbook")
(public! 'spreadsheet-read-sheet
  "(spreadsheet-read-sheet BUFFER SHEET) — read compact used data; SHEET is a name or a 1-based number")
(public! 'spreadsheet-read-cell
  "(spreadsheet-read-cell BUFFER SHEET CELL) — read one A1 cell from a named or numbered sheet")
(public! 'spreadsheet-set-cell!
  "(spreadsheet-set-cell! BUFFER SHEET CELL VALUE) — set one A1 cell and refresh the open grid")
(public! 'spreadsheet-charts
  "(spreadsheet-charts BUFFER) — list persistent embedded chart descriptors")
(public! 'spreadsheet-chart-status
  "(spreadsheet-chart-status BUFFER) — report configured, mounted, drawn, and failed chart IDs from the live grid")
(public! 'spreadsheet-chart!
  "(spreadsheet-chart! BUFFER SHEET SOURCE TYPE TITLE) — create a chart with an automatic ID and safe anchor")
(public! 'spreadsheet-add-chart!
  "(spreadsheet-add-chart! BUFFER SHEET ID TYPE SOURCE ANCHOR TITLE) — configure a precise chart; verify it with spreadsheet-chart-status")
(public! 'spreadsheet-delete-chart!
  "(spreadsheet-delete-chart! BUFFER ID) — delete one embedded chart")
(public! 'spreadsheet-read
  "(spreadsheet-read BUFFER) — read a workbook by buffer name without displaying it")
(public! 'spreadsheet-write!
  "(spreadsheet-write! BUFFER WORKBOOK) — replace a workbook by buffer name and refresh its grid")
(public! 'spreadsheet-app-request
  "(spreadsheet-app-request BUFFER METHOD BODY) — the isolated grid backend bridge")

(catalog-meta! 'function "spreadsheet-register-backend!" 'domain 'data 'effects '(write))
(catalog-meta! 'function "spreadsheet-open-with-backend!" 'domain 'data 'effects '(read write))
(catalog-meta! 'function "spreadsheet-open!" 'domain 'data 'effects '(read write))
(catalog-meta! 'function "spreadsheet-read-source" 'domain 'data 'effects '(read))
(catalog-meta! 'function "spreadsheet-write-source!" 'domain 'data 'effects '(write))
(catalog-meta! 'function "spreadsheet-sheet-names" 'domain 'data 'effects '(read))
(catalog-meta! 'function "spreadsheet-read-sheet" 'domain 'data 'effects '(read))
(catalog-meta! 'function "spreadsheet-read-cell" 'domain 'data 'effects '(read))
(catalog-meta! 'function "spreadsheet-set-cell!" 'domain 'data 'effects '(write))
(catalog-meta! 'function "spreadsheet-charts" 'domain 'data 'effects '(read))
(catalog-meta! 'function "spreadsheet-chart-status" 'domain 'data 'effects '(read))
(catalog-meta! 'function "spreadsheet-chart!" 'domain 'data 'effects '(write))
(catalog-meta! 'function "spreadsheet-add-chart!" 'domain 'data 'effects '(write))
(catalog-meta! 'function "spreadsheet-delete-chart!" 'domain 'data 'effects '(write))
(catalog-meta! 'function "spreadsheet-read" 'domain 'data 'effects '(read))
(catalog-meta! 'function "spreadsheet-write!" 'domain 'data 'effects '(write))
(catalog-meta! 'function "spreadsheet-app-request" 'domain 'data 'effects '(read write))
