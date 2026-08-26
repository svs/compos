;;; spreadsheet.scm --- Editable workbooks with pluggable data backends.
;;;
;;; Scheme owns workbook identity, storage, commands, and mode state.
;;; Jspreadsheet CE 5.0.4 supplies the isolated browser grid.

(package! 'spreadsheet)
(namespace! 'spreadsheet)
(domain! 'data)
(effects! '(read write))

(defgroup 'spreadsheet "Editable spreadsheet workbooks.")

(defcustom 'spreadsheet-default-backend 'text-file
  "The backend used by spreadsheet-open."
  'group 'spreadsheet 'type 'symbol)

(define *spreadsheet-backends* '())

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
      ((spreadsheet--workbook? value) (json-encode value #t))
      (else (spreadsheet--error
              (string-append "The text backend cannot read " path
                             ". The file is not a spreadsheet workbook."))))))

(define (spreadsheet--text-write path text)
  (let ((value (json-parse text)))
    (if (not (spreadsheet--workbook? value))
        (spreadsheet--error "The workbook data is not valid JSON spreadsheet data.")
        (let* ((normalized (string-append (json-encode value #t) "\n"))
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

(define (spreadsheet-read buffer)
  (let ((backend (buffer-local buffer 'spreadsheet-backend))
        (source (buffer-local buffer 'spreadsheet-source)))
    (if (and backend source)
        (let ((result (spreadsheet--read-json backend source)))
          (if (spreadsheet--error? result) result (json-parse result)))
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
        (spreadsheet--write-json backend source (json-encode workbook))))))

;; The app server calls this function with data arguments. It does not
;; interpolate request text into Scheme source.
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
          (else
            (list 405 (json-encode (list 'error "Unsupported spreadsheet request."))))))))

(define spreadsheet--app-html
  (string-append
    "<!doctype html><html><head><meta charset=\"utf-8\">"
    "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
    "<title>Spreadsheet</title>"
    "<link rel=\"stylesheet\" href=\"https://cdn.jsdelivr.net/npm/jsuites@5.13.5/dist/jsuites.css\">"
    "<link rel=\"stylesheet\" href=\"https://cdn.jsdelivr.net/npm/jspreadsheet-ce@5.0.4/dist/jspreadsheet.css\">"
    "<style>"
    ":root{color-scheme:light dark;--bg:#fbfaf7;--fg:#242320;--muted:#77736b;--line:#d8d4cc}"
    "@media(prefers-color-scheme:dark){:root{--bg:#1f201f;--fg:#e7e4dc;--muted:#aaa69d;--line:#454640}}"
    "html,body{height:100%;margin:0;background:var(--bg);color:var(--fg);font:13px system-ui,sans-serif}"
    "body{display:flex;flex-direction:column;overflow:hidden}"
    "#status{height:30px;display:flex;align-items:center;gap:8px;padding:0 12px;border-bottom:1px solid var(--line);color:var(--muted)}"
    "#status[data-state=error]{color:#c0392b}#sheet{flex:1;min-height:0;overflow:auto}"
    ".jss_container,.jexcel_container{min-height:100%;background:var(--bg)}"
    "</style></head><body>"
    "<div id=\"status\" data-state=\"loading\">Loading workbook…</div><div id=\"sheet\"></div>"
    "<script src=\"https://cdn.jsdelivr.net/npm/jsuites@5.13.5/dist/jsuites.js\"></script>"
    "<script src=\"https://cdn.jsdelivr.net/npm/jspreadsheet-ce@5.0.4/dist/index.js\"></script>"
    "<script>(function(){'use strict';"
    "var endpoint='_aimax/spreadsheet',worksheets=[],timer=null,saving=false,again=false;"
    "var status=document.getElementById('status');"
    "function state(kind,text){status.dataset.state=kind;status.textContent=text}"
    "function workbook(){return {version:1,sheets:worksheets.map(function(ws,i){return {name:(ws.options&&ws.options.worksheetName)||('Sheet'+(i+1)),data:ws.getData(false,false)}})}}"
    "async function save(){if(saving){again=true;return}saving=true;again=false;state('saving','Saving…');"
    "try{var r=await fetch(endpoint,{method:'PUT',headers:{'content-type':'application/json'},body:JSON.stringify(workbook())});"
    "var answer=await r.json();if(!r.ok)throw new Error(answer.error||('Save failed: '+r.status));state('saved','Saved')}"
    "catch(e){state('error',e.message||String(e))}finally{saving=false;if(again)save()}}"
    "function changed(event){if(event!=='onload'&&event!=='onopenworksheet'&&event!=='onselection'){clearTimeout(timer);timer=setTimeout(save,350)}}"
    "async function load(){try{var r=await fetch(endpoint,{cache:'no-store'});var model=await r.json();"
    "if(!r.ok||model.error)throw new Error(model.error||('Load failed: '+r.status));"
    "var sheets=Array.isArray(model.sheets)&&model.sheets.length?model.sheets:[{name:'Sheet1',data:[['']]}];"
    "worksheets=jspreadsheet(document.getElementById('sheet'),{tabs:true,toolbar:true,onevent:changed,worksheets:sheets.map(function(s,i){return {worksheetName:s.name||('Sheet'+(i+1)),data:Array.isArray(s.data)?s.data:[['']],minDimensions:[12,30],tableOverflow:true,tableWidth:'100%',tableHeight:'calc(100vh - 72px)'}})});"
    "state('saved','Saved · changes write to the workbook backend')}catch(e){state('error',e.message||String(e))}}"
    "addEventListener('beforeunload',function(){if(timer){clearTimeout(timer);save()}});load();"
    "})();</script></body></html>"))

(define (spreadsheet--render! buffer)
  (buffer-replace-range! buffer 0 (buffer-size buffer) spreadsheet--app-html)
  (buffer-set-local! buffer 'preview-renderer "html")
  (buffer-set-local! buffer 'render-mode "app")
  (buffer-set-read-only! buffer #t)
  (app-reload! buffer))

(define-command "spreadsheet-reload" "Reload the workbook from its backend"
  (lambda ()
    (app-reload! (current-buffer))
    (message "Reloaded the spreadsheet")))

(define-command "spreadsheet-visit-source" "Visit the current workbook data source"
  (lambda ()
    (let ((source (buffer-local (current-buffer) 'spreadsheet-source)))
      (if source
          (visit source (buffer-group (current-buffer)))
          (message "This spreadsheet has no file data source")))))

(define (spreadsheet--setup! buffer)
  (local-set-key* buffer "g" "spreadsheet-reload")
  (local-set-key* buffer "v" "spreadsheet-visit-source")
  (local-set-key* buffer "q" "quit-window")
  (spreadsheet--render! buffer))

(mode-icon! "spreadsheet-mode" "󰈛")

(define-mode "spreadsheet-mode"
  (lambda () (spreadsheet--setup! (current-buffer))))

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
    (unless (file-exists? source)
      (spreadsheet--text-write source
        (json-encode (spreadsheet--default-workbook))))
    (spreadsheet-open-with-backend! spreadsheet-default-backend source)))

(define-command "spreadsheet-open" "Open a text-backed spreadsheet workbook"
  (lambda ()
    (read-file-name "Spreadsheet file: " spreadsheet-open!)))

(public! 'spreadsheet-register-backend!
  "(spreadsheet-register-backend! NAME READ WRITE) — register workbook JSON reader and writer functions")
(public! 'spreadsheet-open-with-backend!
  "(spreadsheet-open-with-backend! BACKEND SOURCE) — open SOURCE with a registered workbook backend")
(public! 'spreadsheet-open!
  "(spreadsheet-open! PATH) — open or create a JSON text workbook")
(public! 'spreadsheet-read
  "(spreadsheet-read BUFFER) — read the workbook as a Scheme value")
(public! 'spreadsheet-write!
  "(spreadsheet-write! BUFFER WORKBOOK) — replace the workbook through its backend")
(public! 'spreadsheet-app-request
  "(spreadsheet-app-request BUFFER METHOD BODY) — the isolated grid backend bridge")

(catalog-meta! 'function "spreadsheet-register-backend!" 'domain 'data 'effects '(write))
(catalog-meta! 'function "spreadsheet-open-with-backend!" 'domain 'data 'effects '(read write))
(catalog-meta! 'function "spreadsheet-open!" 'domain 'data 'effects '(read write))
(catalog-meta! 'function "spreadsheet-read" 'domain 'data 'effects '(read))
(catalog-meta! 'function "spreadsheet-write!" 'domain 'data 'effects '(write))
(catalog-meta! 'function "spreadsheet-app-request" 'domain 'data 'effects '(read write))
