;;; google.scm --- native Google Workspace, with account-owned buffers.
;;; OAuth and HTTP are mechanisms. Scopes, operations, and views live here.
(domain! 'google)
(effects! '(write))
(defgroup 'google "Google Workspace accounts and applications.")
(defcustom 'google-client-file "~/.compos/google-client.json"
  "Downloaded Google Desktop OAuth client JSON." 'group 'google)
(defcustom 'google-default-account ""
  "Google account subject used when opening a new workspace." 'group 'google)
;; Rows per Google list page.
(define google-page-size 25)
(defcustom 'google-scopes
  '("https://www.googleapis.com/auth/gmail.modify"
    "https://www.googleapis.com/auth/calendar"
    "https://www.googleapis.com/auth/drive"
    "https://www.googleapis.com/auth/documents"
    "https://www.googleapis.com/auth/spreadsheets"
    "https://www.googleapis.com/auth/presentations"
    "https://www.googleapis.com/auth/contacts"
    "https://www.googleapis.com/auth/tasks")
  "Scopes requested at connect. Reconnect to change granted access." 'group 'google)

(define google--services
  '((id "gmail" title "Gmail" description "Search mail, read threads, draft and send" base "https://gmail.googleapis.com/gmail/v1")
    (id "calendar" title "Calendar" description "Calendars, events, attendees and meetings" base "https://www.googleapis.com/calendar/v3")
    (id "drive" title "Drive" description "Files, shared drives, search and permissions" base "https://www.googleapis.com/drive/v3")
    (id "docs" title "Docs" description "Documents, text and batch edits" base "https://docs.googleapis.com/v1" mime "application/vnd.google-apps.document")
    (id "sheets" title "Sheets" description "Spreadsheets, ranges, formulas and batch edits" base "https://sheets.googleapis.com/v4" mime "application/vnd.google-apps.spreadsheet")
    (id "slides" title "Slides" description "Presentations, slides, text and batch edits" base "https://slides.googleapis.com/v1" mime "application/vnd.google-apps.presentation")
    (id "contacts" title "Contacts" description "People and contact management" base "https://people.googleapis.com/v1")
    (id "tasks" title "Tasks" description "Task lists, due dates and completion" base "https://tasks.googleapis.com/tasks/v1")
    (id "chat" title "Chat" description "Spaces and messages; requires Chat scopes" base "https://chat.googleapis.com/v1")
    (id "forms" title "Forms" description "Forms and responses; requires Forms scopes" base "https://forms.googleapis.com/v1" mime "application/vnd.google-apps.form")
    (id "meet" title "Meet" description "Meeting spaces; requires Meet scopes" base "https://meet.googleapis.com/v2")
    (id "script" title "Apps Script" description "Projects and source; requires Script scopes" base "https://script.googleapis.com/v1" mime "application/vnd.google-apps.script")))

(define (google--service id)
  (let ((hits (filter (lambda (s) (equal? (plist-get s 'id) id)) google--services)))
    (and (pair? hits) (car hits))))
(define (google--account id)
  (let ((hits (filter (lambda (a) (equal? (plist-get a 'id) id)) (google-accounts))))
    (and (pair? hits) (car hits))))
(define (google--email id) (or (plist-get (google--account id) 'email) id))
(define (google--text v) (if (string? v) v ""))
(define (google--line v) (re-replace-all "[\r\n\t]" (google--text v) " "))
(define (google--query-escape s) (string-replace (string-replace s "\\" "\\\\") "'" "\\'"))
(define (google--id s) (url-encode s))
(define (google--transport account method url params body k)
  (google-http! account method url params body k))
(define *google-transport* google--transport)
(define (google--submit-transport account request raw k)
  (let ((service (google--service (plist-get request 'service)))
        (path (plist-get request 'path)))
    (if (and service (string? path) (string-prefix? "/" path))
        (google-http! account (string-append (plist-get service 'base) path) raw k)
        (k '(ok #f error "Unknown service or invalid API path.")))))
(define *google-submit-transport* google--submit-transport)
(define (google--set-text! buf text)
  (buffer-set-read-only! buf #f)
  (buffer-delete-range! buf 0 (buffer-size buf))
  (buffer-append! buf text))

(define (google--client)
  (if (file-exists? google-client-file) google-client-file
      (let ((json (key-get "GOOGLE_OAUTH_CLIENT_JSON")))
        (if json (or (json-parse json) google-client-file) google-client-file))))

(effects! '(write external))
(define (google-request account service method path params body k)
  (let ((spec (google--service service)))
    (cond ((not spec) (k '(ok #f error "Unknown Google service.")))
          ((not (and (string? account) (not (equal? account ""))))
           (k '(ok #f error "Select a Google account first.")))
          ((not (and (string? path) (string-prefix? "/" path)))
           (k '(ok #f error "Use a service-relative API path beginning with /.")))
          (else (*google-transport* account method
                  (string-append (plist-get spec 'base) path) params body k)))))

(define (google--choose-account k)
  (let ((accounts (google-accounts)))
    (cond ((null? accounts) (message "No Google accounts. Run M-x google-connect."))
          ((google--account google-default-account) (k google-default-account))
          ((null? (cdr accounts)) (k (plist-get (car accounts) 'id)))
          (else (google--account-prompt k)))))
(define (google--account-prompt k)
  (let* ((accounts (google-accounts))
         (labels (map (lambda (a) (string-append (plist-get a 'email) " [" (plist-get a 'id) "]")) accounts)))
    (if (null? accounts)
        (message "No Google accounts. Run M-x google-connect.")
        (completing-read "Google account: " labels
          (lambda (answer)
            (let loop ((as accounts) (ls labels))
              (when (pair? as)
                (if (equal? answer (car ls)) (k (plist-get (car as) 'id))
                    (loop (cdr as) (cdr ls))))))))))

(define-command "google-connect" "Connect another Google account with native OAuth"
  (lambda ()
    (let ((reply (google-oauth-start! (google--client) google-scopes)))
      (if (plist-get reply 'ok)
          (begin (tab-open (plist-get reply 'url))
                 (message "Complete Google consent, then open M-x google. Existing accounts stay connected."))
          (message (plist-get reply 'error))))))
(define-command "google-account" "Choose the default account for new Google buffers"
  (lambda () (google--account-prompt
    (lambda (id) (customize-save! 'google-default-account id)
      (message (string-append "Google: " (google--email id))) (run-command "google")))))
(define-command "google-disconnect" "Revoke a Google account connection"
  (lambda () (google--account-prompt
    (lambda (id)
      (y-or-n? (string-append "Revoke Google access for " (google--email id) "? ")
        (lambda (yes)
          (when yes (google-revoke! id
            (lambda (r) (message (if (plist-get r 'ok) "Google access revoked." (plist-get r 'error))))))))))))

;;; A local workspace opens instantly. Its rows never fetch remote data.
(define-list-mode! "google-mode"
  (list 'buffer "*Google*" 'special #f
    'doc "Google Workspace. RET opens a service. a selects an account. c connects another account."
    'rows (lambda (buf) google--services)
    'columns (lambda (buf) '(("Application" 16) ("Work" #f)))
    'cells (lambda (buf s) (list (plist-get s 'title) (plist-get s 'description)))
    'key (lambda (buf s) (plist-get s 'id))
    'title (lambda (buf) "Google Workspace")
    'meta (lambda (buf)
      (let ((id (buffer-local buf 'google-account)))
        (if id (google--email id) "Connect your first account with c")))
    'keys '(("RET" "google-service-open") ("a" "google-account") ("c" "google-connect") ("x" "google-operation"))
    'footer (lambda (buf) '(("RET" "open") ("a" "account") ("c" "connect") ("x" "operation") ("q" "quit")))))
(define-command "google" "Open Google Workspace"
  (lambda ()
    (list-mode-show! "google-mode")
    (google--choose-account (lambda (id)
      (buffer-set-local! "*Google*" 'google-account id) (list-refresh! "*Google*")))))
(define-command "google-service-open" "Open the selected Google application"
  (lambda ()
    (let ((s (list-current (current-buffer))) (id (buffer-local (current-buffer) 'google-account)))
      (when (and s id) (google-open id (plist-get s 'id))))))

;;; Lists keep their account, query, parent, and page. Each fetch has a generation.
(define (google--list-spec buf)
  (let* ((service (buffer-local buf 'google-service))
         (spec (google--service service))
         (query (or (buffer-local buf 'google-query) ""))
         (parent (buffer-local buf 'google-parent))
         (mime (plist-get spec 'mime))
         (limit (max 1 (min 100 google-page-size))))
    (cond
      ((equal? service "gmail")
       (list 'service service 'path "/users/me/messages" 'key 'messages
             'params (list 'q (if (equal? query "") "in:inbox" query) 'maxResults limit)))
      ((equal? service "calendar")
       (if parent
         (list 'service service 'path (string-append "/calendars/" (google--id parent) "/events") 'key 'items
               'params (list 'maxResults limit 'singleEvents #t 'orderBy "startTime" 'q query
                             'timeMin (string-trim (shell-command->string "date -u +%Y-%m-%dT%H:%M:%SZ"))))
         (list 'service service 'path "/users/me/calendarList" 'key 'items 'params (list 'maxResults limit))))
      ((or mime (equal? service "drive"))
       (list 'service "drive" 'path "/files" 'key 'files
         'params (list 'pageSize limit 'fields "nextPageToken,files(id,name,mimeType,size,modifiedTime,parents,webViewLink)"
           'supportsAllDrives #t 'includeItemsFromAllDrives #t 'orderBy (or (buffer-local buf 'google-drive-sort) "folder,name")
           'q (string-append "trashed = false"
                (if mime (string-append " and mimeType = '" mime "'") "")
                (if (or parent (equal? service "drive")) (string-append " and '" (google--query-escape (or parent "root")) "' in parents") "")
                (if (equal? query "") "" (string-append " and fullText contains '" (google--query-escape query) "'"))))))
      ((equal? service "contacts")
       (list 'service service 'path "/people/me/connections" 'key 'connections
             'params (list 'pageSize limit 'personFields "names,emailAddresses,phoneNumbers")))
      ((equal? service "tasks")
       (list 'service service 'path (if parent (string-append "/lists/" (google--id parent) "/tasks") "/users/@me/lists")
             'key 'items 'params (list 'maxResults limit)))
      ((equal? service "chat") (list 'service service 'path "/spaces" 'key 'spaces 'params (list 'pageSize limit)))
      (else #f))))

(define (google--row-id row)
  (or (plist-get row 'id) (plist-get row 'resourceName) (plist-get row 'name) ""))
(define (google--row-title row)
  (or (plist-get row 'subject) (plist-get row 'title) (plist-get row 'summary)
      (plist-get row 'displayName)
      (let ((names (plist-get row 'names))) (and (pair? names) (plist-get (car names) 'displayName)))
      (plist-get row 'name) (google--row-id row)))
(define (google--row-detail row)
  (or (plist-get row 'from) (plist-get row 'modifiedTime) (plist-get row 'status)
      (plist-get (plist-get row 'start) 'dateTime) (plist-get (plist-get row 'start) 'date)
      (plist-get row 'description) (plist-get row 'mimeType) ""))
(define (google--header payload name)
  (let ((hits (filter (lambda (h) (equal? (string-downcase (or (plist-get h 'name) "")) (string-downcase name)))
                      (or (plist-get payload 'headers) '()))))
    (and (pair? hits) (plist-get (car hits) 'value))))
(define (google--mail-rows account rows k)
  (if (null? rows) (k '())
      (let ((pending (length rows)) (out '()))
        (for-each (lambda (row)
          (google-request account "gmail" "GET"
            (string-append "/users/me/messages/" (google--id (plist-get row 'id)))
            '(format "metadata") #f
            (lambda (r)
              (let* ((data (plist-get r 'data)) (payload (plist-get data 'payload)))
                (set! out (cons (append row
                  (list 'subject (or (google--header payload "Subject") "(No subject)")
                        'from (or (google--header payload "From") (plist-get r 'error) ""))) out))
                (set! pending (- pending 1))
                (when (= pending 0)
                  (k (map (lambda (original)
                       (car (filter (lambda (x) (equal? (plist-get x 'id) (plist-get original 'id))) out))) rows))))))) rows))))

(define *google-request-sequence* 0)
(define (google--fetch buf k)
  (set! *google-request-sequence* (+ 1 *google-request-sequence*))
  (let* ((spec (google--list-spec buf))
         (account (buffer-local buf 'google-account))
         (generation *google-request-sequence*)
         (page (buffer-local buf 'google-page)))
    (buffer-set-local! buf 'google-generation generation)
    (if (not spec)
        (begin (buffer-set-local! buf 'google-status "Use x to choose an API operation for this service.") (k '()))
        (begin
          (buffer-set-local! buf 'google-status "Loading…")
          (google-request account (plist-get spec 'service) "GET" (plist-get spec 'path)
            (append (plist-get spec 'params) (if page (list 'pageToken page) '())) #f
            (lambda (r)
              (when (and (buffer-exists? buf) (= generation (buffer-local buf 'google-generation)))
                (if (not (plist-get r 'ok))
                    (begin (buffer-set-local! buf 'google-status (plist-get r 'error))
                           (message (plist-get r 'error)) (k #f) (list-render! buf #f))
                    (let* ((data (plist-get r 'data))
                           (rows (or (plist-get data (plist-get spec 'key)) '()))
                           (finish (lambda (rows)
                             (when (and (buffer-exists? buf) (= generation (buffer-local buf 'google-generation)))
                               (buffer-set-local! buf 'google-next-page (plist-get data 'nextPageToken))
                               (buffer-set-local! buf 'google-status (if (null? rows) "No results" ""))
                               (k (if (google--file-service? (buffer-local buf 'google-service))
                                      (cons google--up-row rows) rows))))))
                      (if (equal? (buffer-local buf 'google-service) "gmail")
                          (google--mail-rows account rows finish) (finish rows)))))))))))

(define-list-mode! "google-service-mode"
  (list 'special #f
    'doc "Account-owned Google list. RET reads an item. s searches. ] requests the next page. x creates an operation draft."
    'rows (lambda (buf) (list-entries buf)) 'cache-fetch google--fetch 'cache-ttl 120
    'columns (lambda (buf) '(("Name" #f) ("Details" 40)))
    'cells (lambda (buf row) (list (google--line (google--row-title row)) (google--line (google--row-detail row))))
    'key (lambda (buf row) (google--row-id row))
    'title (lambda (buf) (string-append "Google " (or (buffer-local buf 'google-service) "")))
    'meta (lambda (buf) (string-append (google--email (or (buffer-local buf 'google-account) "")) "  "
                        (or (buffer-local buf 'google-query) "") "  " (or (buffer-local buf 'google-status) "")))
    'keys '(("RET" "google-read") ("s" "google-search") ("]" "google-next-page") ("[" "google-first-page")
            ("g" "google-refresh") ("x" "google-operation") ("c" "google-compose"))
    'footer (lambda (buf) '(("RET" "read") ("s" "search") ("]" "next page") ("g" "refresh") ("x" "operation") ("c" "compose")))))

(define (google--file-service? service)
  (or (equal? service "drive") (and (google--service service) (plist-get (google--service service) 'mime))))

(define google--up-row '(id ".." name ".." google-up #t))
(define (google--file-targets buf)
  (filter (lambda (row) (not (plist-get row 'google-up))) (list-targets buf)))
(define-list-mode! "google-drive-mode"
  (list 'special #f
    'doc "Google file index. RET opens, ^ goes up, C copies, R renames or moves, + creates a folder. SPC marks, u unmarks, d flags, x trashes. s sorts and / filters."
    'rows (lambda (buf) (cons google--up-row (filter (lambda (row) (not (plist-get row 'google-up))) (list-entries buf))))
    'markable? (lambda (buf row) (not (plist-get row 'google-up))) 'cache-fetch google--fetch 'cache-ttl 120
    'columns (lambda (buf) '(("Name" #f) ("Size" 12 right) ("Modified" 20) ("Type" 24)))
    'cells (lambda (buf row)
      (list (string-append (google--line (google--row-title row))
              (if (equal? (plist-get row 'mimeType) "application/vnd.google-apps.folder") "/" ""))
            (or (plist-get row 'size) "—") (or (plist-get row 'modifiedTime) "")
            (string-replace (or (plist-get row 'mimeType) "") "application/vnd.google-apps." "")))
    'key (lambda (buf row) (google--row-id row))
    'title (lambda (buf) (string-append (plist-get (google--service (buffer-local buf 'google-service)) 'title) " / " (or (buffer-local buf 'google-drive-path) (if (equal? (buffer-local buf 'google-service) "drive") "My Drive" "All files"))))
    'meta (lambda (buf) (string-append (google--email (buffer-local buf 'google-account)) "  "
                         (or (buffer-local buf 'google-status) "")))
    'keys '(("RET" "dired-visit") ("^" "dired-up") ("R" "dired-rename")
            ("C" "dired-copy") ("d" "google-drive-flag") ("+" "dired-mkdir") ("SPC" "list-mark") ("x" "google-drive-trash")
            ("g" "dired-revert") ("]" "google-next-page") ("[" "google-first-page")
            ("s" "dired-sort-cycle") ("f" "google-search") ("o" "google-operation"))
    'footer (lambda (buf) '(("RET" "open") ("^" "up") ("SPC" "mark") ("u" "unmark")
       ("d" "flag") ("x" "trash") ("C" "copy") ("R" "rename/move") ("+" "new folder") ("/" "filter") ("s" "sort") ("g" "refresh") ("]" "next page")))))

(define-command "google-drive-sort" "Toggle Google file sorting between name and modification time"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-local! buf 'google-drive-sort
        (if (equal? (buffer-local buf 'google-drive-sort) "folder,modifiedTime desc")
            "folder,name" "folder,modifiedTime desc"))
      (buffer-set-local! buf 'google-page #f)
      (google--refresh buf))))

(define-command "google-drive-up" "Open the parent Google Drive directory"
  (lambda ()
    (let* ((buf (current-buffer)) (account (buffer-local buf 'google-account))
           (folder (buffer-local buf 'google-parent)) (up (buffer-local buf 'google-drive-up)))
      (cond ((or (not folder) (equal? folder "root"))
             (if (equal? (buffer-local buf 'google-service) "drive") (message "Already at My Drive.")
                 (google-open account "drive")))
            (up (google-open account "drive" (if (equal? up "root") #f up)))
            (else (google-request account "drive" "GET" (string-append "/files/" (google--id folder))
              '(fields "parents" supportsAllDrives #t) #f
              (lambda (r)
                (if (plist-get r 'ok)
                  (let ((parents (plist-get (plist-get r 'data) 'parents)))
                    (google-open account "drive" (and (pair? parents) (car parents))))
                  (message (plist-get r 'error))))))))))

(define (google--file-op row method suffix params body)
  (list 'id (google--row-id row) 'name (google--row-title row)
    'method method 'path (string-append "/files/" (google--id (google--row-id row)) suffix)
    'params (append '(supportsAllDrives #t) params) 'body body))

;; Capture account and targets before prompting. Batch mutations run once, in order;
;; only successful rows lose their marks, so failed files remain easy to retry.
(define (google--file-apply buf label ops)
  (let ((account (buffer-local buf 'google-account)))
    (if (buffer-local buf 'google-file-busy) (message "A file operation is already running.")
      (when (pair? ops)
        (y-or-n? (string-append label " " (number->string (length ops)) " file(s) as "
                      (google--email account) ": " (string-join (map (lambda (op) (plist-get op 'name)) ops) ", ") "? ")
          (lambda (yes)
            (when (and yes (buffer-exists? buf) (not (buffer-local buf 'google-file-busy)))
              (buffer-set-local! buf 'google-file-busy #t)
              (desktop-skip! buf 'google-file-busy)
              (let loop ((remaining ops) (failed '()))
                (if (null? remaining)
                    (begin
                      (when (buffer-exists? buf)
                        (buffer-set-local! buf 'google-file-busy #f)
                        (google--refresh buf))
                      (message (if (null? failed) (string-append label " completed.")
                                   (string-append "Some files failed: " (string-join (reverse failed) "; ")))))
                    (let ((op (car remaining)))
                      (google-request account "drive" (plist-get op 'method) (plist-get op 'path)
                        (plist-get op 'params) (plist-get op 'body)
                        (lambda (r)
                          (when (and (plist-get r 'ok) (buffer-exists? buf))
                            (list-unmark-key! buf (plist-get op 'id)))
                          (loop (cdr remaining)
                            (if (plist-get r 'ok) failed
                                (cons (string-append (plist-get op 'name) ": " (plist-get r 'error)) failed)))))))))))))))

;; Walk folders by name, keeping the selected folder's ID separate from its label.
;; Each page remains reachable, without requiring users to know Drive IDs.
(define (google--folder-pick account k)
  (let browse ((folder "root") (path "My Drive") (trail '()) (page #f))
    (google-request account "drive" "GET" "/files"
      (append (list 'q (string-append "trashed = false and mimeType = 'application/vnd.google-apps.folder' and '"
                               (google--query-escape folder) "' in parents")
                    'pageSize 100 'orderBy "name" 'fields "nextPageToken,files(id,name)"
                    'supportsAllDrives #t 'includeItemsFromAllDrives #t)
              (if page (list 'pageToken page) '())) #f
      (lambda (r)
        (if (not (plist-get r 'ok)) (message (plist-get r 'error))
          (let* ((data (plist-get r 'data)) (rows (or (plist-get data 'files) '()))
                 (next (plist-get data 'nextPageToken))
                 (labels (map (lambda (row) (string-append (google--row-title row) " [" (google--row-id row) "]/")) rows)))
            (completing-read (string-append "Destination / " path ": ")
              (append '("Use this folder") (if (pair? trail) '("..") '()) labels (if next '("Next page") '()))
              (lambda (answer)
                (cond ((equal? answer "Use this folder") (k folder path))
                      ((and (equal? answer "..") (pair? trail))
                       (browse (caar trail) (cadar trail) (cdr trail) #f))
                      ((and next (equal? answer "Next page")) (browse folder path trail next))
                      (else (let choose ((rs rows) (ls labels))
                        (when (pair? rs)
                          (if (equal? answer (car ls))
                              (browse (google--row-id (car rs)) (string-append path "/" (google--row-title (car rs)))
                                (cons (list folder path) trail) #f)
                              (choose (cdr rs) (cdr ls)))))))))))))))

(define (google--file-transfer buf rows copy?)
  (let ((account (buffer-local buf 'google-account)))
    (if (and copy? (pair? (filter (lambda (row) (equal? (plist-get row 'mimeType) "application/vnd.google-apps.folder")) rows)))
        (message "Folder copying is not supported yet. Select files to copy, or R to move folders.")
        (google--folder-pick account
          (lambda (destination label)
            (google--file-apply buf (string-append (if copy? "Copy to " "Move to ") label)
              (map (lambda (row)
                (if copy?
                    (google--file-op row "POST" "/copy" '() (list 'name (google--row-title row) 'parents (list destination)))
                    (google--file-op row "PATCH" ""
                      (append (list 'addParents destination)
                        (let ((parents (plist-get row 'parents)))
                          (if (pair? parents) (list 'removeParents (string-join parents ",")) '())))
                      (list 'name (google--row-title row))))) rows)))))))

(define-command "google-drive-copy" "Copy marked files, or the current file, to a Drive folder"
  (lambda () (let ((buf (current-buffer))) (google--file-transfer buf (google--file-targets buf) #t))))
(define-command "google-drive-rename" "Rename the current file or move selected files to a folder"
  (lambda ()
    (let* ((buf (current-buffer)) (rows (google--file-targets buf)))
      (when (pair? rows)
        (if (> (length rows) 1) (google--file-transfer buf rows #f)
          (completing-read "Rename or move: " '("Rename" "Move to folder")
            (lambda (action)
              (cond ((equal? action "Move to folder") (google--file-transfer buf rows #f))
                    ((equal? action "Rename")
                     (read-string "New name: "
                       (lambda (name) (unless (equal? (string-trim name) "")
                         (google--file-apply buf "Rename"
                           (list (google--file-op (car rows) "PATCH" "" '() (list 'name name))))))))))))))))

(define-command "google-drive-mkdir" "Create a folder in this Drive directory"
  (lambda ()
    (let* ((buf (current-buffer)) (parent (or (buffer-local buf 'google-parent) "root")))
      (read-string "Folder name: "
        (lambda (name) (unless (equal? (string-trim name) "")
          (google--file-apply buf "Create folder"
            (list (list 'id "" 'name name 'method "POST" 'path "/files" 'params '(supportsAllDrives #t)
              'body (list 'name name 'mimeType "application/vnd.google-apps.folder" 'parents (list parent)))))))))))

(define-command "google-drive-flag" "Flag this Google file for trash"
  (lambda () (list-mark-at-point! "D")))
(define-command "google-drive-trash" "Trash flagged files, otherwise marked files or the current file"
  (lambda ()
    (let* ((buf (current-buffer))
           (flagged (filter (lambda (row) (equal? (list-mark-of buf row) "D")) (list-entries buf)))
           (rows (if (pair? flagged) flagged (google--file-targets buf))))
      (google--file-apply buf "Trash" (map (lambda (row) (google--file-op row "PATCH" "" '() '(trashed #t))) rows)))))

(define (google-open account service &optional parent)
  (let ((buf (string-append "*Google " (google--email account) " [" account "] / " service
                (if parent (string-append " / " parent) "") "*")))
    (buffer-create buf)
    (buffer-set-local! buf 'google-account account)
    (buffer-set-local! buf 'google-service service)
    (buffer-set-local! buf 'google-parent (or parent #f))
    (when (google--file-service? service) (buffer-set-local! buf 'dired-provider "google"))
    (with-current-buffer buf (lambda () (set-mode! (if (google--file-service? service) "Dired" "google-service-mode"))))
    (if (google--file-service? service) (switch-to-buffer-here! buf) (pop-to-buffer buf))
    (when (google--file-service? service) (list-goto-index! buf (if (> (length (list-entries buf)) 1) 1 0))) buf))
(define (google--refresh buf)
  ;; A new user query supersedes an older request. Its callback is discarded.
  (buffer-set-local! buf 'cache-inflight #f)
  (cache-refresh! buf))
(define-command "google-refresh" "Refresh the current Google page"
  (lambda () (google--refresh (current-buffer))))
(define-command "google-first-page" "Return to the first Google page"
  (lambda () (buffer-set-local! (current-buffer) 'google-page #f) (google--refresh (current-buffer))))
(define-command "google-next-page" "Fetch the next Google page"
  (lambda ()
    (let* ((buf (current-buffer)) (page (buffer-local buf 'google-next-page)))
      (if page (begin (buffer-set-local! buf 'google-page page) (google--refresh buf))
          (message "No next page.")))))
(define-command "google-search" "Search mail, events, or Drive files"
  (lambda ()
    (let* ((buf (current-buffer)) (service (buffer-local buf 'google-service)))
      (if (or (member service '("gmail" "drive" "docs" "sheets" "slides" "forms" "script"))
              (and (equal? service "calendar") (buffer-local buf 'google-parent)))
          (minibuffer-read "Google search: " '()
            (lambda (q) (buffer-set-local! buf 'google-query q)
                        (buffer-set-local! buf 'google-page #f) (google--refresh buf)))
          (message "Use / to filter these rows. Open a calendar before searching events.")))))

;;; Item buffers expose readable text and complete structured API data.
(define (google--base64url-decode text)
  (let* ((s (string-replace (string-replace text "-" "+") "_" "/"))
         (padding (modulo (- 4 (modulo (string-length s) 4)) 4)))
    (base64-decode (string-append s (make-string padding #\=)))))
(define (google--mail-text payload)
  (let ((data (plist-get (plist-get payload 'body) 'data)))
    (string-append
      (if (and data (equal? (plist-get payload 'mimeType) "text/plain")) (google--base64url-decode data) "")
      (string-join (map google--mail-text (or (plist-get payload 'parts) '())) "\n"))))
(define (google--document-text tree)
  (if (not (pair? tree)) ""
      (if (symbol? (car tree))
          (let ((text (plist-get (plist-get tree 'textRun) 'content)))
            (if text text (string-join (map google--document-text tree) "")))
          (string-join (map google--document-text tree) ""))))
(define (google--show-result account service title data)
  (let* ((identity (or (plist-get data 'id) (plist-get data 'documentId)
                      (plist-get data 'presentationId) (plist-get data 'spreadsheetId)
                      (plist-get data 'resourceName) (number->string (current-time))))
         (buf (string-append "*Google " account " / " (google--line title) " [" identity "]*"))
         (payload (plist-get data 'payload))
         (plain (if payload (google--mail-text payload) (google--document-text data))))
    (buffer-create buf)
    (buffer-set-local! buf 'google-account account)
    (buffer-set-local! buf 'google-service service)
    (buffer-set-local! buf 'google-data data)
    (with-current-buffer buf (lambda ()
      (buffer-set-read-only! buf #f)
      (google--set-text! buf (string-append title "\n" (google--email account) "\n\n"
        (if payload (string-append "From: " (or (google--header payload "From") "") "\nSubject: "
          (or (google--header payload "Subject") "") "\n\n") "")
        plain "\n\nAPI data\n" (json-encode data #t)))
      (set-mode! "google-detail-mode")))
    (pop-to-buffer buf) buf))
(define-mode "google-detail-mode"
  (lambda () (buffer-set-read-only! (current-buffer) #t)))
(mode-keys! "google-detail-mode" '(("x" "google-operation") ("c" "google-compose") ("q" "quit-window")))

(define (google--item-path service id parent)
  (cond ((equal? service "gmail") (string-append "/users/me/messages/" (google--id id)))
        ((equal? service "calendar") (string-append "/calendars/" (google--id parent) "/events/" (google--id id)))
        ((equal? service "docs") (string-append "/documents/" (google--id id)))
        ((equal? service "sheets") (string-append "/spreadsheets/" (google--id id)))
        ((equal? service "slides") (string-append "/presentations/" (google--id id)))
        ((equal? service "contacts") (string-append "/" id))
        ((equal? service "tasks") (string-append "/lists/" (google--id parent) "/tasks/" (google--id id)))
        ((equal? service "forms") (string-append "/forms/" (google--id id)))
        ((equal? service "script") (string-append "/projects/" (google--id id) "/content"))
        ((equal? service "chat") (string-append "/" id "/messages"))
        (else (string-append "/files/" (google--id id)))))
(define-command "google-read" "Read the selected Google item in compos"
  (lambda ()
    (let* ((buf (current-buffer)) (row (list-current buf))
           (account (buffer-local buf 'google-account)) (service (buffer-local buf 'google-service))
           (parent (buffer-local buf 'google-parent)))
      (when row
        (if (plist-get row 'google-up) (run-command "google-drive-up")
        (let* ((id (google--row-id row))
               (matches (filter (lambda (s) (and (plist-get s 'mime)
                          (equal? (plist-get s 'mime) (plist-get row 'mimeType)))) google--services))
               (target (if (and (equal? service "drive") (pair? matches)) (plist-get (car matches) 'id) service)))
          (if (or (and (not parent) (member service '("calendar" "tasks")))
                  (equal? (plist-get row 'mimeType) "application/vnd.google-apps.folder"))
              (let ((child (google-open account service id)))
                (when (equal? service "drive")
                  (buffer-set-local! child 'google-drive-up (or parent "root"))
                  (buffer-set-local! child 'google-drive-path
                    (string-append (or (buffer-local buf 'google-drive-path) "My Drive") "/" (google--row-title row)))
                  (list-redraw! child)))
              (google-request account target "GET" (google--item-path target id parent)
                (if (equal? service "contacts") '(personFields "names,emailAddresses,phoneNumbers") '()) #f
                (lambda (r)
                  (if (plist-get r 'ok)
                      (google--show-result account target (google--row-title row) (plist-get r 'data))
                      (message (plist-get r 'error))))))))))))

;;; Reviewable API drafts cover the full REST surface of each service.
;;; Templates are data. Nothing runs when a draft opens or is restored.
(define google--operations
  '((name "Docs: create" service "docs" method "POST" path "/documents" body (title "Untitled"))
    (name "Docs: edit" service "docs" method "POST" path "/documents/DOCUMENT_ID:batchUpdate"
      body (requests ((insertText (location (index 1) text "Text to append\n")))) )
    (name "Slides: create" service "slides" method "POST" path "/presentations" body (title "Untitled"))
    (name "Slides: edit" service "slides" method "POST" path "/presentations/PRESENTATION_ID:batchUpdate"
      body (requests ((createSlide (objectId "new_slide" slideLayoutReference (predefinedLayout "TITLE_AND_BODY"))))))
    (name "Sheets: create" service "sheets" method "POST" path "/spreadsheets" body (properties (title "Untitled")))
    (name "Sheets: read cells" service "sheets" method "GET" path "/spreadsheets/SPREADSHEET_ID/values/Sheet1!A1:Z100")
    (name "Sheets: write cells" service "sheets" method "PUT" path "/spreadsheets/SPREADSHEET_ID/values/Sheet1!A1"
      params (valueInputOption "USER_ENTERED") body (values (("Name" "Value") ("Example" 1))))
    (name "Sheets: batch edit" service "sheets" method "POST" path "/spreadsheets/SPREADSHEET_ID:batchUpdate"
      body (requests ((addSheet (properties (title "New sheet"))))))
    (name "Calendar: create event" service "calendar" method "POST" path "/calendars/primary/events"
      params (sendUpdates "none") body (summary "New event" start (date "YYYY-MM-DD") end (date "YYYY-MM-DD")))
    (name "Calendar: update event" service "calendar" method "PATCH" path "/calendars/primary/events/EVENT_ID" body (summary "Updated event"))
    (name "Drive: create folder" service "drive" method "POST" path "/files" body (name "New folder" mimeType "application/vnd.google-apps.folder"))
    (name "Drive: rename" service "drive" method "PATCH" path "/files/FILE_ID" body (name "New name"))
    (name "Drive: move to trash" service "drive" method "PATCH" path "/files/FILE_ID" body (trashed #t))
    (name "Drive: share" service "drive" method "POST" path "/files/FILE_ID/permissions" body (type "user" role "reader" emailAddress "RECIPIENT"))
    (name "Gmail: archive" service "gmail" method "POST" path "/users/me/messages/MESSAGE_ID/modify" body (removeLabelIds ("INBOX")))
    (name "Gmail: mark read" service "gmail" method "POST" path "/users/me/messages/MESSAGE_ID/modify" body (removeLabelIds ("UNREAD")))
    (name "Gmail: trash" service "gmail" method "POST" path "/users/me/messages/MESSAGE_ID/trash")
    (name "Contacts: create" service "contacts" method "POST" path "/people:createContact" body (names ((givenName "First" familyName "Last"))))
    (name "Tasks: create list" service "tasks" method "POST" path "/users/@me/lists" body (title "New list"))
    (name "Tasks: create task" service "tasks" method "POST" path "/lists/TASKLIST_ID/tasks" body (title "New task"))
    (name "Tasks: complete" service "tasks" method "PATCH" path "/lists/TASKLIST_ID/tasks/TASK_ID" body (status "completed"))
    (name "Chat: send message" service "chat" method "POST" path "/spaces/SPACE_ID/messages" body (text "Message"))
    (name "Forms: create" service "forms" method "POST" path "/forms" body (info (title "New form")))
    (name "Forms: responses" service "forms" method "GET" path "/forms/FORM_ID/responses")
    (name "Meet: create space" service "meet" method "POST" path "/spaces")
    (name "Apps Script: create" service "script" method "POST" path "/projects" body (title "New project"))))
(define (google--context-operation op buf)
  (let* ((row (if (member (buffer-local buf 'mode-name) '("google-service-mode" "google-drive-mode" "Dired")) (list-current buf)
                 (buffer-local buf 'google-data)))
         (id (or (plist-get row 'documentId) (plist-get row 'spreadsheetId)
                 (plist-get row 'presentationId) (and row (google--row-id row))))
         (parent (buffer-local buf 'google-parent))
         (path (plist-get op 'path)))
    (when (and id (equal? (plist-get op 'service) (buffer-local buf 'google-service)))
      (for-each (lambda (placeholder) (set! path (string-replace path placeholder (google--id id))))
                '("DOCUMENT_ID" "PRESENTATION_ID" "SPREADSHEET_ID" "MESSAGE_ID" "EVENT_ID" "FILE_ID" "TASK_ID" "FORM_ID"))
      (when parent (set! path (string-replace path "TASKLIST_ID" (google--id parent))))
      (when (and parent (equal? (plist-get op 'service) "calendar"))
        (set! path (string-replace path "/calendars/primary/" (string-append "/calendars/" (google--id parent) "/")))))
    (let ((body (plist-get op 'body)) (revision (plist-get row 'revisionId)))
      (when (equal? (plist-get op 'name) "Calendar: create event")
        (set! body (list 'summary "New event"
          'start (list 'date (format-time (+ (current-time) 86400) "%Y-%m-%d"))
          'end (list 'date (format-time (+ (current-time) 172800) "%Y-%m-%d")))))
      (when (and revision (string-contains? path ":batchUpdate")
                 (member (plist-get op 'service) '("docs" "slides")))
        (set! body (append (list 'writeControl (list 'requiredRevisionId revision)) body)))
      (append (list 'path path 'body body) op))))
(define *google-draft-sequence* 0)
(define (google-draft account operation)
  (set! *google-draft-sequence* (+ 1 *google-draft-sequence*))
  (let ((buf (string-append "*Google request " account " " (number->string (current-time)) "-"
                            (number->string *google-draft-sequence*) "*")))
    (buffer-create buf)
    (buffer-set-local! buf 'google-account account)
    (buffer-set-local! buf 'google-service (plist-get operation 'service))
    (google--set-text! buf (or (plist-get operation 'raw-request) (json-encode
      (list 'service (plist-get operation 'service) 'method (plist-get operation 'method)
            'path (plist-get operation 'path) 'params (or (plist-get operation 'params) '())
            'body (or (plist-get operation 'body) #f)) #t)))
    (with-current-buffer buf (lambda () (set-mode! "google-request-mode")))
    (pop-to-buffer buf)
    (message (string-append "Edit the request for " (google--email account) "; C-c C-c submits it.")) buf))
(define-mode "google-request-mode"
  (lambda () (buffer-set-read-only! (current-buffer) #f)
    (desktop-skip! (current-buffer) 'google-submitting)))
(mode-keys! "google-request-mode" '(("C-c C-c" "google-submit") ("C-c C-k" "quit-window")))
(define-command "google-operation" "Choose a Google API operation and prepare an editable request"
  (lambda ()
    (let ((account (buffer-local (current-buffer) 'google-account)) (source (current-buffer)))
      (if (not account) (message "Open a Google account workspace first.")
          (completing-read "Google operation: " (map (lambda (op) (plist-get op 'name)) google--operations)
            (lambda (name)
              (let ((hits (filter (lambda (op) (equal? name (plist-get op 'name))) google--operations)))
                (when (pair? hits) (google-draft account (google--context-operation (car hits) source))))))))))
(define-command "google-submit" "Submit the reviewed Google request for its original account"
  (lambda ()
    (let* ((buf (current-buffer)) (account (buffer-local buf 'google-account))
           (request-text (buffer-text buf))
           (request (json-parse request-text)))
      (cond ((buffer-local buf 'google-submitting) (message "This request is already running."))
            ((equal? (buffer-local buf 'google-submitted-request) (buffer-text buf))
             (message "This exact request already succeeded. Edit it or prepare a new request."))
            ((not (and request (plist-get request 'service) (plist-get request 'method) (plist-get request 'path)))
             (message "A request needs service, method, path, params, and body JSON fields."))
            (else
              (y-or-n? (string-append (plist-get request 'method) " " (plist-get request 'path)
                        " as " (google--email account) "? ")
                (lambda (yes)
                  (when (and yes (not (buffer-local buf 'google-submitting)))
                    (buffer-set-local! buf 'google-submitting #t)
                    (*google-submit-transport* account request request-text
                      (lambda (r)
                        (when (buffer-exists? buf) (buffer-set-local! buf 'google-submitting #f))
                        (if (plist-get r 'ok)
                            (begin (when (buffer-exists? buf) (buffer-set-local! buf 'google-last-result r)
                                  (buffer-set-local! buf 'google-submitted-request request-text))
                              (google--show-result account (plist-get request 'service) "Request result" (plist-get r 'data)))
                            (message (plist-get r 'error)))))))))))))

;;; Mail starts as a readable local draft. Sending remains an explicit operation.
(define (google--mime-lines encoded)
  (if (<= (string-length encoded) 76) encoded
      (string-append (substring encoded 0 76) "\r\n" (google--mime-lines (substring encoded 76)))))
(define (google-mail-draft account to subject body)
  (let* ((safe-to (google--line to)) (safe-subject (google--line subject))
         (raw (string-append "To: " safe-to "\r\nSubject: =?UTF-8?B?" (base64-encode safe-subject)
           "?=\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
           (google--mime-lines (base64-encode body))))
         (encoded (string-replace (string-replace (string-replace (base64-encode raw) "+" "-") "/" "_") "=" "")))
    (list 'service "gmail" 'method "POST" 'path "/users/me/drafts"
          'body (list 'message (list 'raw encoded)))))
(define-command "google-compose" "Compose a mail draft for this Google account"
  (lambda ()
    (set! *google-draft-sequence* (+ 1 *google-draft-sequence*))
    (let ((account (buffer-local (current-buffer) 'google-account)))
      (if (not account) (message "Open a Google account workspace first.")
          (let ((buf (string-append "*Google compose " account " " (number->string (current-time)) "-" (number->string *google-draft-sequence*) "*")))
            (buffer-create buf) (buffer-set-local! buf 'google-account account)
            (google--set-text! buf "To: \nSubject: \n\n")
            (with-current-buffer buf (lambda () (set-mode! "google-compose-mode")))
            (pop-to-buffer buf))))))
(define-mode "google-compose-mode" (lambda () (buffer-set-read-only! (current-buffer) #f)))
(mode-keys! "google-compose-mode" '(("C-c C-d" "google-save-mail-draft") ("C-c C-c" "google-send-mail")))
(define (google--compose-operation send?)
  (let* ((buf (current-buffer)) (lines (string-split (buffer-text buf) "\n"))
         (account (buffer-local buf 'google-account)))
    (if (not (and (>= (length lines) 3) (string-prefix? "To: " (car lines))
                  (string-prefix? "Subject: " (cadr lines)) (equal? (nth 2 lines) "")))
        (message "Use To: and Subject: headers, then a blank line and the message.")
        (let* ((op (google-mail-draft account (substring (car lines) 4) (substring (cadr lines) 9)
                     (string-join (list-tail lines 3) "\n")))
               (message-data (plist-get (plist-get op 'body) 'message)))
          (if send?
              (google-draft account (list 'service "gmail" 'method "POST" 'path "/users/me/messages/send" 'body message-data))
              (google-draft account op))))))
(define-command "google-save-mail-draft" "Prepare saving this message to Gmail drafts" (lambda () (google--compose-operation #f)))
(define-command "google-send-mail" "Prepare sending this message through Gmail" (lambda () (google--compose-operation #t)))

(category! 'google)
(effects! '(read))
(public! 'google-accounts "(google-accounts) — connected account subjects, emails, and granted scopes; never tokens.")
(public! 'google-oauth-status "(google-oauth-status) — current connection progress without credentials.")
(effects! '(write external))
(public! 'google-request "(google-request ACCOUNT SERVICE METHOD PATH PARAMS BODY CALLBACK) — direct Google REST request; account is explicit.")
(public! 'google-open "(google-open ACCOUNT SERVICE [PARENT]) — open an account-owned Google list.")
(public! 'google-draft "(google-draft ACCOUNT OPERATION) — prepare a reviewable API request without submitting it.")
(public! 'google-mail-draft "(google-mail-draft ACCOUNT TO SUBJECT BODY) — build a Gmail draft operation without sending it.")
(public! 'google-oauth-start! "(google-oauth-start! CLIENT-FILE SCOPES) — start native desktop OAuth and return the consent URL.")
(public! 'google-http! "(google-http! ACCOUNT METHOD URL PARAMS BODY CALLBACK) — authenticated Google HTTP transport.")
(effects! '(destroy external))
(public! 'google-revoke! "(google-revoke! ACCOUNT CALLBACK) — revoke and remove an account connection.")


;;; Agents can inspect APIs and prepare writes without changing account context.
(category! 'google)
(effects! '(read external))
(define (google-read-api account service path params)
  (let ((spec (google--service service)))
    (if (and spec (string? path) (string-prefix? "/" path))
        (google-http! account "GET" (string-append (plist-get spec 'base) path) params #f)
        '(ok #f error "Unknown service or invalid relative path."))))
(define (google-discover account api version)
  (google-http! account "GET"
    (string-append "https://www.googleapis.com/discovery/v1/apis/"
                   (google--id api) "/" (google--id version) "/rest") '() #f))
(public! 'google-read-api "(google-read-api ACCOUNT SERVICE PATH PARAMS) — read a Google REST resource synchronously for agent workflows.")
(public! 'google-discover "(google-discover ACCOUNT API VERSION) — inspect a Google Discovery document, including resources, methods, and scopes.")
(effects! '(write))
(define (google-register-service! id title base)
  (set! google--services
    (cons (list 'id id 'title title 'base base 'description "Google API request interface")
          (filter (lambda (s) (not (equal? (plist-get s 'id) id))) google--services))))
(public! 'google-register-service! "(google-register-service! ID TITLE BASE) — register another Google API; put persistent registrations in init.scm.")
(catalog-meta! 'function "google-request" 'effects '(unknown external))
(catalog-meta! 'function "google-http!" 'effects '(unknown external))
(catalog-meta! 'function "google-mail-draft" 'effects '(pure))
(catalog-meta! 'function "google-draft" 'effects '(write))
(catalog-meta! 'command "google-submit" 'effects '(unknown external))
(catalog-meta! 'command "google-disconnect" 'effects '(destroy external))

;;; Headless file functions: explicit account, structured result, no UI or prompts.
(domain! 'google)
(category! 'google)
(effects! '(read external))
(define (google-files account folder &optional query page service)
  (let ((mime (and service (plist-get (google--service service) 'mime))))
    (if (and service (not (google--file-service? service)))
      '(ok #f error "Choose drive, docs, sheets, slides, forms, or script.")
      (google-read-api account "drive" "/files"
        (append (list 'pageSize 100 'orderBy "folder,name" 'supportsAllDrives #t 'includeItemsFromAllDrives #t
          'fields "nextPageToken,files(id,name,mimeType,size,modifiedTime,parents,webViewLink)"
          'q (string-append "trashed = false"
             (if (and folder (not (equal? folder ""))) (string-append " and '" (google--query-escape folder) "' in parents") "")
             (if mime (string-append " and mimeType = '" mime "'") "")
             (if (and query (not (equal? query ""))) (string-append " and fullText contains '" (google--query-escape query) "'") "")))
          (if (and page (not (equal? page ""))) (list 'pageToken page) '()))))))
(define (google-file account id)
  (google-read-api account "drive" (string-append "/files/" (google--id id))
    '(supportsAllDrives #t fields "id,name,mimeType,size,modifiedTime,parents,webViewLink,capabilities")))
(public! 'google-files "(google-files ACCOUNT FOLDER [QUERY PAGE SERVICE]) — list files; root is My Drive, empty FOLDER searches all accessible files. SERVICE filters docs/sheets/slides/forms/script. Returns data.files and nextPageToken.")
(public! 'google-file "(google-file ACCOUNT ID) — read one file's metadata and capabilities, including its current parents.")

(effects! '(write external))
(define (google--file-write account method path params body)
  (google-http! account method (string-append "https://www.googleapis.com/drive/v3" path)
    (append '(supportsAllDrives #t) params) body))
(define (google-file-rename! account id name)
  (if (equal? (string-trim name) "") '(ok #f error "File name must not be empty.")
    (google--file-write account "PATCH" (string-append "/files/" (google--id id)) '() (list 'name name))))
(define (google-folder-create! account parent name)
  (if (or (equal? (string-trim name) "") (equal? parent ""))
    '(ok #f error "Provide a parent folder and a nonempty name.")
    (google--file-write account "POST" "/files" '()
      (list 'name name 'mimeType "application/vnd.google-apps.folder" 'parents (list parent)))))
(define (google-file-copy! account id destination &optional name)
  (let ((file (google-file account id)))
    (cond ((not (plist-get file 'ok)) file)
          ((equal? (plist-get (plist-get file 'data) 'mimeType) "application/vnd.google-apps.folder")
           '(ok #f error "Folder copying is not supported."))
          ((equal? destination "") '(ok #f error "Provide a destination folder."))
          (else (google--file-write account "POST" (string-append "/files/" (google--id id) "/copy") '()
            (list 'name (if (and name (not (equal? name ""))) name (plist-get (plist-get file 'data) 'name))
                  'parents (list destination)))))))
(define (google-file-move! account id destination)
  (let ((file (google-file account id)))
    (if (not (plist-get file 'ok)) file
      (let ((parents (or (plist-get (plist-get file 'data) 'parents) '())))
        (cond ((equal? destination "") '(ok #f error "Provide a destination folder."))
              ((member destination parents) file)
              (else (google--file-write account "PATCH" (string-append "/files/" (google--id id))
                (append (list 'addParents destination)
                  (if (pair? parents) (list 'removeParents (string-join parents ",")) '()))
                (list 'name (plist-get (plist-get file 'data) 'name)))))))))
(public! 'google-file-rename! "(google-file-rename! ACCOUNT ID NAME) — rename a file immediately; returns the Google result, without opening a buffer.")
(public! 'google-folder-create! "(google-folder-create! ACCOUNT PARENT NAME) — create a folder; PARENT may be root. Executes immediately.")
(public! 'google-file-copy! "(google-file-copy! ACCOUNT ID DESTINATION [NAME]) — copy a file into a folder, optionally renaming the copy. Executes immediately; folders are unsupported.")
(public! 'google-file-move! "(google-file-move! ACCOUNT ID DESTINATION) — move a file or folder using freshly fetched parents. Executes immediately; same-parent moves do nothing.")
(effects! '(destroy external))
(define (google-file-trash! account id)
  (google--file-write account "PATCH" (string-append "/files/" (google--id id)) '() '(trashed #t)))
(public! 'google-file-trash! "(google-file-trash! ACCOUNT ID) — move a file or folder to trash immediately. Does not permanently delete it.")

(dired-register-provider! "google" "google-drive-mode"
  '(("dired-visit" "google-read") ("dired-open" "google-read") ("dired-visit-in-group" "google-read")
    ("dired-up" "google-drive-up") ("dired-revert" "google-refresh")
    ("dired-copy" "google-drive-copy") ("dired-rename" "google-drive-rename")
    ("dired-mkdir" "google-drive-mkdir") ("dired-sort-cycle" "google-drive-sort")))
;; Restore older Google directory desktops through the same provider entry point.
(define-mode "google-drive-mode"
  (lambda () (buffer-set-local! (current-buffer) 'dired-provider "google") (set-mode! "Dired")))
