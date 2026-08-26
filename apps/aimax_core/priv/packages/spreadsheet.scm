;;; spreadsheet.scm --- Editable workbooks with pluggable data backends.
;;;
;;; Scheme owns workbook identity, storage, commands, and mode state.
;;; Univer 0.25.1 supplies the isolated browser workbook.
;;; Univer uses the Apache-2.0 license.

(package! 'spreadsheet)
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
    "<link rel=\"stylesheet\" href=\"https://unpkg.com/@univerjs/preset-sheets-core@0.25.1/lib/index.css\">"
    "<style>"
    "*,*::before,*::after{box-sizing:border-box}html,body,#app{width:100%;height:100%;margin:0;padding:0}"
    "html,body{overflow:hidden;background:#fff;font:13px system-ui,sans-serif}"
    "#app{position:relative;outline:none}"
    "#status{position:fixed;z-index:10000;right:12px;bottom:8px;max-width:50vw;padding:4px 9px;"
    "border:1px solid rgba(120,120,120,.24);border-radius:999px;background:rgba(255,255,255,.9);"
    "color:#686868;font:12px system-ui,sans-serif;box-shadow:0 1px 5px rgba(0,0,0,.08);pointer-events:none}"
    "#status[data-state=error]{color:#b42318;border-color:#f3b7b2;background:#fff3f2}"
    "#status[data-state=saved]{opacity:0;transition:opacity .8s 1.2s}"
    "@media(prefers-color-scheme:dark){html,body{background:#1f201f}#status{background:rgba(31,32,31,.9);color:#c9c6be}}"
    "</style></head><body>"
    "<div id=\"app\" tabindex=\"0\"></div><div id=\"status\" data-state=\"loading\">Loading workbook…</div>"
    "<script src=\"https://unpkg.com/react@18.3.1/umd/react.production.min.js\"></script>"
    "<script src=\"https://unpkg.com/react-dom@18.3.1/umd/react-dom.production.min.js\"></script>"
    "<script src=\"https://unpkg.com/rxjs@7.8.1/dist/bundles/rxjs.umd.min.js\"></script>"
    "<script src=\"https://unpkg.com/echarts@5.6.0/dist/echarts.min.js\"></script>"
    "<script src=\"https://unpkg.com/@univerjs/presets@0.25.1/lib/umd/index.js\"></script>"
    "<script src=\"https://unpkg.com/@univerjs/preset-sheets-core@0.25.1/lib/umd/index.js\"></script>"
    "<script src=\"https://unpkg.com/@univerjs/preset-sheets-core@0.25.1/lib/umd/locales/en-US.js\"></script>"
    "<script>(function(){'use strict';"
    "var endpoint='_aimax/spreadsheet',api=null,book=null,model=null,timer=null,saving=false,again=false,loading=true;"
    "var status=document.getElementById('status'),app=document.getElementById('app');"
    "function state(kind,text){status.dataset.state=kind;status.textContent=text}"
    "function object(value){return value&&typeof value==='object'&&!Array.isArray(value)?value:{}}"
    "function cell(value,prior){var out=prior&&typeof prior==='object'?Object.assign({},prior):{};delete out.v;delete out.f;delete out.si;delete out.t;"
    "if(typeof value==='string'&&value.charAt(0)==='=')out.f=value;else if(typeof value==='boolean'){out.v=value?1:0;out.t=3}else out.v=value;return out}"
    "function mergeData(oldData,data){oldData=object(oldData);var next={};Object.keys(oldData).forEach(function(r){var row={};Object.keys(object(oldData[r])).forEach(function(c){var prior=oldData[r][c]||{};var clean=Object.assign({},prior);delete clean.v;delete clean.f;delete clean.si;delete clean.t;if(Object.keys(clean).length)row[c]=clean});if(Object.keys(row).length)next[r]=row});"
    "(Array.isArray(data)?data:[]).forEach(function(row,r){(Array.isArray(row)?row:[]).forEach(function(value,c){if(!next[r])next[r]={};next[r][c]=cell(value,(oldData&&oldData[r]&&oldData[r][c])||next[r][c])})});return next}"
    "function snapshotOf(m){var prior=object(m.univerSnapshot);prior=JSON.parse(JSON.stringify(prior));"
    "var oldOrder=Array.isArray(prior.sheetOrder)?prior.sheetOrder:[],oldSheets=object(prior.sheets),order=[],sheets={};"
    "(Array.isArray(m.sheets)?m.sheets:[]).forEach(function(source,i){var id=oldOrder[i]||('aimax-sheet-'+(i+1)),old=oldSheets[id]||{};order.push(id);"
    "var rows=Array.isArray(source.data)?source.data:[],cols=rows.reduce(function(n,row){return Math.max(n,Array.isArray(row)?row.length:0)},0);"
    "sheets[id]=Object.assign({},old,{id:id,name:source.name||('Sheet'+(i+1)),rowCount:Math.max(old.rowCount||0,100,rows.length+20),columnCount:Math.max(old.columnCount||0,20,cols+5),cellData:mergeData(old.cellData,rows)})});"
    "if(!order.length){order=['aimax-sheet-1'];sheets[order[0]]={id:order[0],name:'Sheet1',rowCount:100,columnCount:20,cellData:{}}}"
    "return Object.assign({},prior,{id:prior.id||'aimax-workbook',name:prior.name||'ai-max Spreadsheet',appVersion:'0.25.1',locale:'enUS',styles:object(prior.styles),sheetOrder:order,sheets:sheets})}"
    "function compact(snapshot){var order=snapshot.sheetOrder||[],nativeSheets=object(snapshot.sheets),sheets=order.map(function(id){var sheet=nativeSheets[id]||{},cells=object(sheet.cellData),maxR=-1,maxC=-1;"
    "Object.keys(cells).forEach(function(r){Object.keys(cells[r]||{}).forEach(function(c){var x=cells[r][c]||{};if(x.f!=null||x.v!=null){maxR=Math.max(maxR,+r);maxC=Math.max(maxC,+c)}})});"
    "var data=[];for(var r=0;r<=maxR;r++){var row=[];for(var c=0;c<=maxC;c++){var x=cells[r]&&cells[r][c]||{};row.push(x.f!=null?x.f:(x.t===3?!!x.v:(x.v==null?'':x.v)))}while(row.length&&row[row.length-1]==='')row.pop();data.push(row)}"
    "return {name:sheet.name||'Sheet',data:data}});var active=book&&book.getActiveSheet?book.getActiveSheet():null;var activeId=active&&active.getSheetId?active.getSheetId():order[0];"
    "return {version:2,activeSheet:Math.max(0,order.indexOf(activeId)),sheets:sheets,univerSnapshot:snapshot}}"
    "function schedule(){if(loading)return;clearTimeout(timer);timer=setTimeout(save,500)}"
    "async function save(){if(!book)return;if(saving){again=true;return}saving=true;again=false;state('saving','Saving…');"
    "try{var snapshot=await Promise.resolve(book.save());var payload=compact(snapshot);var r=await fetch(endpoint,{method:'PUT',headers:{'content-type':'application/json'},body:JSON.stringify(payload)});"
    "var answer=await r.json();if(!r.ok)throw new Error(answer.error||('Save failed: '+r.status));state('saved','Saved')}"
    "catch(e){state('error',e.message||String(e))}finally{saving=false;if(again)save()}}"
    "function focusGrid(){window.focus();app.focus({preventScroll:true});if(book){var sheet=book.getActiveSheet();if(sheet&&!sheet.getActiveRange())sheet.getRange('A1').activate()}}"
    "addEventListener('message',function(e){if(e.data&&e.data.aimax==='focus-granted')focusGrid()});"
    "async function load(){try{var r=await fetch(endpoint,{cache:'no-store'});model=await r.json();"
    "if(!r.ok||model.error)throw new Error(model.error||('Load failed: '+r.status));"
    "var create=UniverPresets.createUniver,core=UniverCore,preset=UniverPresetSheetsCore;var made=create({locale:core.LocaleType.EN_US,locales:{enUS:core.mergeLocales(UniverPresetSheetsCoreEnUS)},presets:[preset.UniverSheetsCorePreset({container:'app'})]});api=made.univerAPI;"
    "book=api.createWorkbook(snapshotOf(model));var wanted=Number.isInteger(model.activeSheet)?model.activeSheet:0,sheets=book.getSheets();if(sheets[wanted])book.setActiveSheet(sheets[wanted]);"
    "if(matchMedia('(prefers-color-scheme: dark)').matches&&api.toggleDarkMode)api.toggleDarkMode();"
    "api.onCommandExecuted(schedule);loading=false;state('saved','Saved');setTimeout(function(){parent.postMessage({aimax:'request-focus'},'*')},80)}catch(e){state('error',e.message||String(e));console.error(e)}}"
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
    (when (and (equal? spreadsheet-default-backend 'text-file)
               (not (file-exists? source)))
      (spreadsheet--text-write source
        (json-encode (spreadsheet--default-workbook))))
    (spreadsheet-open-with-backend! spreadsheet-default-backend source)))

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
(catalog-meta! 'function "spreadsheet-read" 'domain 'data 'effects '(read))
(catalog-meta! 'function "spreadsheet-write!" 'domain 'data 'effects '(write))
(catalog-meta! 'function "spreadsheet-app-request" 'domain 'data 'effects '(read write))
