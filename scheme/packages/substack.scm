;;; substack.scm --- subscriptions, publication pages, and post readers.

(domain! 'web)
(effects! '(read))

;; How many recent posts each publication page lists.
(define substack-post-limit 20)

(define *substack-buffer* "*substack*")
(define *substack-log* "*substack-log*")

(define (substack--text value)
  (if (string? value) value (if value (value->string value) "")))
(define (substack--contains? text needle)
  (pair? (cdr (string-split (substack--text text) needle))))
(define (substack--date value)
  (let ((s (substack--text value)))
    (if (>= (string-length s) 10) (substring s 0 10) s)))
(define (substack--base-url publication)
  (let ((custom (plist-get publication 'custom_domain))
        (subdomain (plist-get publication 'subdomain)))
    (cond ((and (string? custom) (not (equal? custom "")))
           (string-append "https://" custom))
          ((and (string? subdomain) (not (equal? subdomain "")))
           (string-append "https://" subdomain ".substack.com"))
          (else ""))))
(define (substack--subscription payload publication-id)
  (let loop ((rows (or (plist-get payload 'subscriptions) '())))
    (cond ((null? rows) #f)
          ((equal? (plist-get (car rows) 'publication_id) publication-id) (car rows))
          (else (loop (cdr rows))))))
(define (substack--own-ids payload)
  (map (lambda (entry) (plist-get entry 'publication_id))
       (or (plist-get payload 'publicationUsers) '())))
(define (substack--publication-row payload publication)
  (let* ((id (plist-get publication 'id))
         (subscription (substack--subscription payload id)))
    (list 'id id
          'name (substack--text (plist-get publication 'name))
          'author (substack--text
                    (or (plist-get publication 'author_name)
                        (plist-get publication 'primary_profile_name)))
          'url (substack--base-url publication)
          'membership (substack--text
                        (and subscription (plist-get subscription 'membership_state)))
          'last-post "")))
(define (substack-parse-subscriptions payload)
  "Return subscription rows and exclude publications owned by the account."
  (let ((own (substack--own-ids payload)))
    (filter (lambda (row)
              (and (plist-get row 'id)
                   (not (member (plist-get row 'id) own))))
            (map (lambda (publication)
                   (substack--publication-row payload publication))
                 (or (plist-get payload 'publications) '())))))

(effects! '(write display))
;; The listing, the publication pages and the readers are one app. The app
;; id says so; they own no group of their own and open in the group the
;; frame stands in, like every other buffer.
(define *substack-app-id* "substack")
(define (substack-join-group! buf &optional role)
  (when (buffer-exists? buf)
    (when (boundp 'app-claim!) (app-claim! buf *substack-app-id* (or role 'aux)))
    (when (boundp 'buffer-join-here!) (buffer-join-here! buf)))
  buf)
(define (substack-log! text)
  (unless (buffer-exists? *substack-log*) (buffer-create *substack-log*))
  (buffer-append! *substack-log* (string-append text "\n")))

(effects! '(write external))
(define (substack--tab k)
  (tab-list
    (lambda (tabs)
      (let loop ((rest tabs))
        (cond ((null? rest) (k #f))
              ((substack--contains? (plist-get (car rest) 'url)
                                    "substack.com/settings")
               (k (plist-get (car rest) 'id)))
              (else (loop (cdr rest))))))))
(define (substack--fetch-authenticated! k)
  (substack--tab
    (lambda (tab)
      (if (not tab)
          (begin (substack-log! "No substack.com/settings tab is open")
                 (message "Open substack.com/settings, then press g")
                 (k #f))
          (tab-eval tab
            "(()=>{const x=new XMLHttpRequest();x.open('GET','/api/v1/subscriptions/page_v2?cb='+Date.now(),false);x.send();return x.status===200?x.responseText:'ERROR '+x.status})()"
            (lambda (text)
              (let ((payload (and (string? text) (json-parse text))))
                (if payload (k payload)
                    (begin
                      (substack-log! (string-append "Subscription fetch failed: "
                                                   (substack--text text)))
                      (message (string-append "Substack fetch failed. See "
                                              *substack-log*))
                      (k #f))))))))))
(define *substack-browser-fetch* substack--fetch-authenticated!)
(define *substack-json-fetch* (lambda (url k) (http-get-json url '() k)))

;;; --- listing state and authenticated actions -----------------------------

(define (substack--rows buf)
  (or (buffer-local buf 'substack-rows) (list-entries buf) '()))
(define (substack--set-rows! rows)
  (buffer-set-local! *substack-buffer* 'substack-rows rows)
  (buffer-set-local! *substack-buffer* 'list-source-entries rows)
  (list-refresh! *substack-buffer*)
  rows)
(define (substack--fetch-subscriptions! buf k)
  (substack-join-group! buf)
  (*substack-browser-fetch*
    (lambda (payload) (k (and payload (substack-parse-subscriptions payload))))))
(define (substack--row-by-id id)
  (let loop ((rows (substack--rows *substack-buffer*)))
    (cond ((null? rows) #f)
          ((equal? (plist-get (car rows) 'id) id) (car rows))
          (else (loop (cdr rows))))))
(define (substack--remove-row! id)
  (substack--set-rows!
    (filter (lambda (row) (not (equal? (plist-get row 'id) id)))
            (substack--rows *substack-buffer*))))
(define (substack--unsubscribe-key! buf id)
  (let* ((row (substack--row-by-id id))
         (name (if row (plist-get row 'name) (number->string id))))
    (substack--tab
      (lambda (tab)
        (if (not tab)
            (message "Open substack.com/settings, then try x again")
            (tab-eval tab
              (string-append
                "(()=>{const x=new XMLHttpRequest();x.open('DELETE','/api/v1/free',false);"
                "x.setRequestHeader('content-type','application/json');"
                "x.send(JSON.stringify({publication_id:" (number->string id)
                ",source:'account'}));return String(x.status)})()")
              (lambda (status)
                (if (or (equal? status "200") (equal? status "404"))
                    (begin (substack--remove-row! id)
                           (message (string-append "Unsubscribed: " name)))
                    (begin
                      (substack-log! (string-append name ": DELETE " (substack--text status)))
                      (message (string-append "Unsubscribe failed. See "
                                              *substack-log*)))))))))
    #t))

;;; --- publication pages ---------------------------------------------------

(effects! '(read write external display))
(define (substack--detail-buffer row)
  (string-append "*substack:" (number->string (plist-get row 'id)) "*"))
(define (substack--archive-url row)
  (string-append (plist-get row 'url)
                 "/api/v1/archive?sort=new&search=&offset=0&limit="
                 (number->string substack-post-limit)))
(define (substack--post-author post)
  (let ((bylines (or (plist-get post 'publishedBylines) '())))
    (if (pair? bylines)
        (substack--text (plist-get (car bylines) 'name))
        "")))
(define (substack--plist-set plist key value)
  (cond ((null? plist) (list key value))
        ((equal? (car plist) key) (cons key (cons value (cdr (cdr plist)))))
        (else (cons (car plist)
                    (cons (car (cdr plist))
                          (substack--plist-set (cdr (cdr plist)) key value))))))
(define (substack--enrich! row posts)
  (if (null? posts) row
      (let* ((first (car posts))
             (author (substack--post-author first))
             (row1 (substack--plist-set
                     row 'author
                     (if (equal? author "") (plist-get row 'author) author)))
             (row2 (substack--plist-set
                     row1 'last-post
                     (substack--date (plist-get first 'post_date))))
             (id (plist-get row 'id)))
        (substack--set-rows!
          (map (lambda (old)
                 (if (equal? (plist-get old 'id) id) row2 old))
               (substack--rows *substack-buffer*)))
        row2)))
(define (substack--fetch-posts! buf)
  (let ((row (buffer-local buf 'substack-publication)))
    (when row
      (message (string-append "Reading " (plist-get row 'name) "..."))
      (*substack-json-fetch* (substack--archive-url row)
        (lambda (posts)
          (if (not (list? posts))
              (begin
                (substack-log! (string-append "Archive failed: "
                                             (plist-get row 'name)))
                (message "Could not read this publication"))
              (begin
                (buffer-set-local! buf 'substack-posts posts)
                (buffer-set-local! buf 'list-source-entries posts)
                (buffer-set-local! buf 'substack-publication
                                   (substack--enrich! row posts))
                (list-refresh! buf)
                (message (string-append (number->string (length posts))
                                        " posts · "
                                        (plist-get row 'name))))))))))
(define (substack-show-detail! row)
  "Show ROW in one publication buffer beside the listing."
  (when row
    (let ((buf (substack--detail-buffer row)))
      (unless (buffer-exists? buf) (buffer-create buf))
      (buffer-set-local! buf 'substack-publication row)
      (substack-join-group! buf 'detail)
      (unless (buffer-derived-mode? buf "substack-detail-mode")
        (with-current-buffer buf
          (lambda () (set-mode! "substack-detail-mode"))))
      (when (null? (or (buffer-local buf 'substack-posts) '()))
        (substack--fetch-posts! buf))
      (buffer-set-local! *substack-buffer* 'substack-current-detail buf)
      (display-buffer-detail! buf *substack-buffer*)
      buf)))

;;; --- post readers --------------------------------------------------------

(define substack-reader-css
  "<style>:root{color-scheme:light dark}html{font-size:clamp(14px,.72vw,32px)}body{margin:0 auto;padding:2rem;max-width:46rem;font:1rem/1.65 Georgia,serif}h1{font:700 2rem/1.15 system-ui,sans-serif}.meta{color:#777;font:.86rem/1.4 system-ui,sans-serif;margin-bottom:2rem}img{max-width:100%;height:auto}pre{overflow:auto}a{color:#2f7d62}</style>")
(define (substack--reader-buffer post)
  (string-append "*substack-read:" (number->string (plist-get post 'id)) "*"))
(define (substack--post-url publication post)
  (or (plist-get post 'canonical_url)
      (string-append (plist-get publication 'url) "/p/"
                     (plist-get post 'slug))))
(define (substack--post-api-url publication post)
  (string-append (plist-get publication 'url) "/api/v1/posts/"
                 (plist-get post 'slug)))
(define (substack--reader-html publication post)
  (let ((body (or (plist-get post 'body_html)
                  (plist-get post 'truncated_body_text)
                  "<p>This post did not return a readable body.</p>"))
        (author (substack--post-author post)))
    (string-append
      substack-reader-css "<article><h1>"
      (html-escape (plist-get post 'title))
      "</h1><div class='meta'>"
      (html-escape
        (string-append
          (if (equal? author "") (plist-get publication 'author) author)
          " · " (substack--date (plist-get post 'post_date))
          " · " (plist-get publication 'name)))
      "</div>" body "</article>")))
(define (substack--apply-reader! buf publication post)
  (buffer-set-text! buf (substack--reader-html publication post) #t)
  (buffer-set-local! buf 'substack-publication publication)
  (buffer-set-local! buf 'substack-post post)
  (buffer-set-local! buf 'preview-renderer "html")
  (enable-minor-mode! buf "preview-mode")
  (preview-heal! buf)
  buf)
(define (substack--fetch-reader! buf)
  (let ((publication (buffer-local buf 'substack-publication))
        (post (buffer-local buf 'substack-post)))
    (when (and publication post)
      (*substack-json-fetch* (substack--post-api-url publication post)
        (lambda (full)
          (if full
              (begin
                (substack--apply-reader! buf publication full)
                (message (plist-get full 'title)))
              (begin
                (substack-log! (string-append "Post failed: "
                                             (plist-get post 'title)))
                (message "Could not read this post"))))))))
(define (substack-show-reader! owner post)
  "Show POST in one reader buffer beside publication OWNER."
  (when post
    (let* ((publication (buffer-local owner 'substack-publication))
           (buf (substack--reader-buffer post)))
      (unless (buffer-exists? buf) (buffer-create buf))
      (buffer-set-local! buf 'substack-publication publication)
      (buffer-set-local! buf 'substack-post post)
      (substack-join-group! buf 'aux)
      (unless (buffer-derived-mode? buf "substack-reader-mode")
        (with-current-buffer buf
          (lambda () (set-mode! "substack-reader-mode"))))
      (when (= (buffer-size buf) 0)
        (buffer-set-text! buf
          (string-append (plist-get post 'title) "\n\nLoading...\n") #t)
        (substack--fetch-reader! buf))
      (buffer-set-local! *substack-buffer* 'substack-current-reader buf)
      (display-buffer-detail! buf owner)
      (substack-layout!)
      buf)))

;;; --- shared commands -----------------------------------------------------

(effects! '(write external display))
(define (substack--mode) (buffer-local (current-buffer) 'mode-name))
;;;###autoload
(define-command "substack-open" "Open the next Substack view"
  (lambda ()
    (cond ((equal? (substack--mode) "substack-mode")
           (substack-show-detail! (list-current *substack-buffer*)))
          ((equal? (substack--mode) "substack-detail-mode")
           (substack-show-reader! (current-buffer)
                                  (list-current (current-buffer))))
          (else (message "There is no deeper Substack view")))))
(define-command "substack-refresh" "Refresh the current Substack view"
  (lambda ()
    (cond ((equal? (substack--mode) "substack-mode") (substack-sync!))
          ((equal? (substack--mode) "substack-detail-mode")
           (substack--fetch-posts! (current-buffer)))
          ((equal? (substack--mode) "substack-reader-mode")
           (substack--fetch-reader! (current-buffer)))
          (else (message "This is not a Substack buffer")))))
(define-command "substack-open-browser"
  "Open this publication or post in the browser"
  (lambda ()
    (let* ((buf (current-buffer))
           (publication
             (if (equal? (substack--mode) "substack-mode")
                 (list-current *substack-buffer*)
                 (buffer-local buf 'substack-publication)))
           (post (buffer-local buf 'substack-post))
           (url (and publication
                     (if post
                         (substack--post-url publication post)
                         (plist-get publication 'url)))))
      (if url (tab-open url) (message "No Substack URL on this row")))))

;;; --- modes ---------------------------------------------------------------

(define (substack--publication-cells buf row)
  (list (plist-get row 'name)
        (list (plist-get row 'author) "dim")
        (list (plist-get row 'last-post) "dim")
        (list (plist-get row 'membership) "dim")))
(define (substack--post-cells buf post)
  (list (list (substack--date (plist-get post 'post_date)) "dim")
        (plist-get post 'title)
        (list (substack--text (plist-get post 'audience)) "dim")))

(define-list-mode! "substack-mode"
  (list
    'doc
      "Your Substack subscriptions. Moving previews a publication. RET opens it. d flags unsubscribe and x executes. g syncs. o opens the site. q quits."
    'buffer *substack-buffer*
    'transient #f
    'local-filter #t
    'noun "subscription"
    'rows substack--rows
    'cache-fetch substack--fetch-subscriptions!
    'cache-ttl 60
    'key (lambda (buf row) (plist-get row 'id))
    'columns (lambda (buf)
      (list (list "publication" #f) (list "author" 28)
            (list "last post" 10) (list "membership" 12)))
    'cells substack--publication-cells
    'title (lambda (buf) "Substack")
    'meta (lambda (buf)
      (string-append (number->string (length (substack--rows buf)))
                     " subscriptions"))
    'total (lambda (buf) (length (substack--rows buf)))
    'footer (lambda (buf)
      '(("RET" "publication") ("SPC" "mark") ("d" "unsubscribe")
        ("x" "execute") ("o" "browser") ("g" "sync")
        ("/" "filter") ("q" "quit")))
    'preview (lambda (buf row) (substack-show-detail! row))
    'flags (list (list "d" "D" "unsubscribe" substack--unsubscribe-key! #t))
    'keys '(("RET" "substack-open") ("o" "substack-open-browser")
            ("g" "substack-refresh") ("q" "quit-window"))))

(define-list-mode! "substack-detail-mode"
  (list
    'doc
      "One publication and its recent posts. Moving previews a post. RET reads it. g refreshes. o opens the publication. q quits."
    'transient #f
    'rows (lambda (buf) (or (buffer-local buf 'substack-posts) '()))
    'key (lambda (buf post) (plist-get post 'id))
    'columns (lambda (buf)
      (list (list "date" 10) (list "post" #f) (list "audience" 12)))
    'cells substack--post-cells
    'title (lambda (buf)
      (let ((row (buffer-local buf 'substack-publication)))
        (if row (plist-get row 'name) "Substack")))
    'meta (lambda (buf)
      (let ((row (buffer-local buf 'substack-publication)))
        (if row
            (string-append (plist-get row 'author) " · "
                           (plist-get row 'url))
            "")))
    'total (lambda (buf)
      (length (or (buffer-local buf 'substack-posts) '())))
    'footer (lambda (buf)
      '(("RET" "read") ("o" "browser") ("g" "refresh") ("q" "quit")))
    'preview (lambda (buf post) (substack-show-reader! buf post))
    'keys '(("RET" "substack-open") ("o" "substack-open-browser")
            ("g" "substack-refresh") ("q" "quit-window"))))

(define-mode "substack-reader-mode"
  (lambda ()
    (substack-join-group! (current-buffer))
    (buffer-set-read-only! (current-buffer) #t)))
(mode-parent! "substack-reader-mode" "special-mode")
(mode-doc! "substack-reader-mode"
  "One Substack post. o opens it in the browser, g refreshes it, q quits. The detail keys walk sibling readers.")
(mode-keys! "substack-reader-mode"
  '(("o" "substack-open-browser") ("g" "substack-refresh")
    ("q" "quit-window")))

(detail-name! "substack-detail-mode"
  (lambda (buf)
    (let ((row (buffer-local buf 'substack-publication)))
      (string-append "*" (if row (plist-get row 'name) "Substack") "*"))))
(detail-name! "substack-reader-mode"
  (lambda (buf)
    (let ((post (buffer-local buf 'substack-post)))
      (string-append "*" (if post (plist-get post 'title) "Substack post") "*"))))

(mode-icon! "substack-mode" "")
(mode-icon! "substack-detail-mode" "")
(mode-icon! "substack-reader-mode" "")

;;; --- app entry and layout ------------------------------------------------

(define (substack-current-detail)
  (buffer-local *substack-buffer* 'substack-current-detail))
(define (substack-current-reader)
  (buffer-local *substack-buffer* 'substack-current-reader))
(define (substack-layout!)
  (let* ((id (frame-group))
         (chat (and id (group-chat id)))
         (panes (filter buffer-exists?
                        (list *substack-buffer*
                              (substack-current-detail)
                              (substack-current-reader)
                              chat))))
    (when (pair? (cdr panes)) (tile-default-windows! panes))
    panes))
(define (substack-sync!)
  "Fetch subscriptions and redraw the app."
  (unless (buffer-exists? *substack-buffer*) (buffer-create *substack-buffer*))
  (substack-join-group! *substack-buffer* 'home)
  (unless (buffer-derived-mode? *substack-buffer* "substack-mode")
    (with-current-buffer *substack-buffer*
      (lambda () (set-mode! "substack-mode"))))
  (message "Syncing Substack subscriptions...")
  (substack--fetch-subscriptions! *substack-buffer*
    (lambda (rows)
      (when rows
        (substack--set-rows! rows)
        (let ((row (list-current *substack-buffer*)))
          (when row (substack-show-detail! row)))
        (substack-layout!)
        (let ((id (frame-group)))
          (when id (group-layout-save! id)))
        (message (string-append (number->string (length rows))
                                " Substack subscriptions"))))))
;;;###autoload
(define-command "substack" "Open the Substack app"
  (lambda ()
    (unless (buffer-exists? *substack-buffer*) (buffer-create *substack-buffer*))
    (substack-join-group! *substack-buffer* 'home)
    (unless (buffer-derived-mode? *substack-buffer* "substack-mode")
      (with-current-buffer *substack-buffer*
        (lambda () (set-mode! "substack-mode"))))
    (switch-to-buffer! *substack-buffer*)
    (if (pair? (substack--rows *substack-buffer*))
        (begin
          (list-refresh! *substack-buffer*)
          (substack-show-detail! (list-current *substack-buffer*))
          (substack-layout!))
        (substack-sync!))))

(public! 'substack-parse-subscriptions
  "(substack-parse-subscriptions PAYLOAD) — rows from page_v2, excluding owned publications")
(public! 'substack-show-detail!
  "(substack-show-detail! ROW) — show ROW in its publication buffer")
(public! 'substack-show-reader!
  "(substack-show-reader! OWNER POST) — show POST in its reader buffer")
(public! 'substack-sync!
  "(substack-sync!) — fetch subscriptions and redraw the app")
(public! 'substack
  "(substack) — open the Substack app")
