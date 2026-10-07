;;; recruiting.scm -- one job from the ATS, its tabs, and the people under them.
;;;
;;; The app holds ONE job in one listing. The tab bar is the job's own
;;; tabs: the suggestions board in the order the client sees it, the
;;; applications standing against the job, and the job itself. A row on
;;; the first two tabs is a person and opens as a page beside the list.
;;; A row on the job tab is one fact about the job, and its page is the
;;; whole description.

(domain! 'web) 
(effects! '(read))

(defcustom 'recruiting-server "ats-ash"
  "The MCP server the app reads jobs, suggestions and applications from.")

(defcustom 'recruiting-narrow-cols 96
  "Under this width the listing drops the tagline and gives the room to the name.")

(define *recruiting-buffer* "*recruiting*")
(define *recruiting-log* "*recruiting-log*")
(define *recruiting-app-id* "recruiting")
(define *recruiting-tabs* (list 'suggestions 'applications 'job 'jd 'config))

;; the listing last opened, for a command run from somewhere else
(define *recruiting-last* #f)

;;; ------------------------------------------------------------- small words

(define (rec-str v)
  (cond ((string? v) v)
        ((number? v) (number->string v))
        ((symbol? v) (symbol->string v))
        ((equal? v #t) "yes")
        ((not v) "")
        (else (format "~s" v))))

(define (rec-join xs)
  (if (and xs (pair? xs)) (string-join (map rec-str xs) ", ") ""))

;; an ISO stamp is a day here: the listing has no room for the clock
(define (rec-day s)
  (if (and (string? s) (> (string-length s) 10)) (substring s 0 10) (rec-str s)))

(define (rec-clip s n)
  (if (> (string-length s) n) (string-trim (substring s 0 n)) s))

;; there is no round in this Scheme, so a score is cut, not rounded:
;; two places is all the board ever distinguishes.
(define (rec-num2 x)
  (if (number? x)
      (let ((t (number->string x)))
        (if (> (string-length t) 4) (substring t 0 4) t))
      ""))

;;; ----------------------------------------------------------------- reading

(effects! '(read external))

(define (rec-log! line)
  (unless (buffer-exists? *recruiting-log*) (buffer-create *recruiting-log*))
  (buffer-append! *recruiting-log* (string-append line "\n")))

;; Every ATS answer arrives as JSON text under an ok flag. A failure is
;; a line in the app's own log and #f to the caller, never a half-drawn
;; list. The call returns at once; the callback does the drawing.
(define (rec-call! tool args k)
  (mcp-call! (string->symbol recruiting-server) tool args
    (lambda (ok text)
      (if ok
          (k (json-parse text))
          (begin (rec-log! (string-append tool ": " (format "~s" text)))
                 (k #f))))))

(define (rec-job-args id) (string-append "{\"input\":{\"job_id\":\"" id "\"}}"))

(define (rec-fetch-jobs! k) (rec-call! "listJobs" "{\"input\":{}}" k))

(define (rec-fetch-suggestions! id k) (rec-call! "getJobSuggestions" (rec-job-args id) k))

(define (rec-fetch-applications! id k)
  (rec-call! "listApplications"
             (string-append "{\"input\":{\"job_id\":\"" id "\"},\"limit\":100}")
             k))

;;; ------------------------------------------------------------------- rows

(effects! '(pure))

;; A row is a record, never a printed line: the kind it is, the key the
;; buttons route by, and the plist the ATS answered with. cells render
;; it, so an action on a row holds the whole record.
(define (rec-row kind key rec) (list 'kind kind 'key key 'rec rec))
(define (rec-kind row) (plist-get row 'kind))
(define (rec-key row) (plist-get row 'key))
(define (rec-rec row) (plist-get row 'rec))
(define (rec-person? row) (equal? (rec-kind row) 'person))

(define (rec--suggestion-rows recs)
  (map (lambda (r) (rec-row 'person (rec-str (plist-get r 'candidate_id)) r))
       (or recs '())))

(define (rec--application-rows recs)
  (map (lambda (r) (rec-row 'person (rec-str (plist-get r 'candidate_id)) r))
       (or recs '())))

(define (rec--field label value)
  (and value (not (equal? (rec-str value) ""))
       (rec-row 'field label (list 'label label 'value (rec-str value)))))

;; the job tab: one row per fact the job states about itself
(define (rec--job-rows job)
  (if (not job)
      '()
      (let ((co (plist-get job 'company)))
        (filter (lambda (r) r)
          (list (rec--field "title" (plist-get job 'title))
                (rec--field "company" (and co (plist-get co 'name)))
                (rec--field "location" (rec-join (plist-get job 'location)))
                (rec--field "mode" (plist-get job 'mode))
                (rec--field "status" (plist-get job 'status))
                (rec--field "min yoe" (plist-get job 'min_yoe))
                (rec--field "specialisations" (rec-join (plist-get job 'specialisations)))
                (rec--field "published" (rec-day (plist-get job 'published_at)))
                (rec--field "summary" (plist-get job 'summary)))))))

(define (rec--jd-rows job)
  (if (not job)
      '()
      (filter (lambda (r) r)
        (list (rec--field "JD" (or (plist-get job 'extracted_text) (plist-get job 'description)))))))

(define (rec--config-rows job)
  (if (not job)
      '()
      (let* ((sp (or (plist-get job 'search_params) '()))
             (shapes (plist-get sp 'role_shapes)))
        (filter (lambda (r) r)
          (list (rec--field "min yoe" (plist-get job 'min_yoe))
                (rec--field "location" (rec-join (plist-get job 'location)))
                (rec--field "specialisations" (rec-join (plist-get job 'specialisations)))
                (rec--field "role require" (rec-join (and shapes (plist-get shapes 'require))))
                (rec--field "role exclude" (rec-join (and shapes (plist-get shapes 'exclude))))
                (rec--field "fv1 weights" (plist-get sp 'fv1_weights))
                (rec--field "experience" (plist-get job 'experience))
                (rec--field "ideal experience" (plist-get job 'ideal_experience))
                (rec--field "custom prompt" (plist-get job 'custom_prompt)))))))

(define (rec-tab buf) (or (buffer-local buf 'recruiting-tab) 'suggestions))
(define (rec-job buf) (buffer-local buf 'recruiting-job))
(define (rec-job-id buf) (rec-str (plist-get (or (rec-job buf) '()) 'id)))

(define (rec--rows buf)
  (let ((tab (rec-tab buf)))
    (cond ((equal? tab 'suggestions) (or (buffer-local buf 'recruiting-suggestions) '()))
          ((equal? tab 'applications) (or (buffer-local buf 'recruiting-applications) '()))
          ((equal? tab 'jd) (rec--jd-rows (rec-job buf)))
          ((equal? tab 'config) (rec--config-rows (rec-job buf)))
          (else (rec--job-rows (rec-job buf))))))

;;; ------------------------------------------------------- columns and cells

;; A heading is a claim. score is the board's own F-v1 number and rank
;; is where the client actually sees the row, so they stay two columns.
(define (rec--columns buf)
  (let ((tab (rec-tab buf)))
    (cond ((equal? tab 'suggestions)
           (list (list "#" 3) (list "candidate" 24) (list "yoe" 5)
                 (list "score" 6) (list "source" 7) (list "tagline" #f)))
          ((equal? tab 'applications)
           (list (list "candidate" 24) (list "state" 15) (list "last event" 11)
                 (list "tagline" #f)))
          (else (list (list "field" 16) (list "value" #f))))))

(define (rec--narrow-columns buf)
  (let ((tab (rec-tab buf)))
    (cond ((equal? tab 'suggestions)
           (list (list "#" 3) (list "candidate" 24) (list "yoe" 5) (list "score" #f)))
          ((equal? tab 'applications)
           (list (list "candidate" 24) (list "state" #f)))
          (else (list (list "field" 16) (list "value" #f))))))

(define (rec--rank buf row)
  (let loop ((rs (rec--rows buf)) (n 1))
    (cond ((null? rs) "")
          ((equal? (rec-key (car rs)) (rec-key row)) (number->string n))
          (else (loop (cdr rs) (+ n 1))))))

(define (rec--cells buf row)
  (let ((tab (rec-tab buf)) (r (rec-rec row)))
    (cond ((equal? tab 'suggestions)
           (list (rec--rank buf row)
                 (rec-str (plist-get r 'candidate_name))
                 (rec-str (plist-get r 'candidate_yoe))
                 (rec-num2 (plist-get r 'score))
                 (rec-str (plist-get r 'source))
                 (rec-clip (rec-str (plist-get r 'candidate_tagline)) 110)))
          ((equal? tab 'applications)
           (list (rec-str (plist-get r 'candidate_name))
                 (rec-str (plist-get r 'state))
                 (rec-day (plist-get r 'last_event_at))
                 (rec-clip (rec-str (plist-get r 'job_title)) 110)))
          (else (list (rec-str (plist-get r 'label))
                      (rec-clip (rec-str (plist-get r 'value)) 200))))))

(define (rec--narrow-cells buf row)
  (let ((cs (rec--cells buf row)) (tab (rec-tab buf)))
    (cond ((equal? tab 'suggestions)
           (list (car cs) (car (cdr cs)) (car (cdr (cdr cs))) (car (cdr (cdr (cdr cs))))))
          ((equal? tab 'applications) (list (car cs) (car (cdr cs))))
          (else cs))))

;;; --------------------------------------------------------------- the tabs

(define (rec--tab-count buf tab)
  (cond ((equal? tab 'suggestions) (length (or (buffer-local buf 'recruiting-suggestions) '())))
        ((equal? tab 'applications) (length (or (buffer-local buf 'recruiting-applications) '())))
        ((equal? tab 'jd) (length (rec--jd-rows (rec-job buf))))
        ((equal? tab 'config) (length (rec--config-rows (rec-job buf))))
        (else (length (rec--job-rows (rec-job buf))))))

;; a tab, as ui/tabs wants one: the id a click comes back under, the
;; word with its count, and whether it is the tab standing.
(define (rec--tab-entry buf tab at)
  (let* ((name (symbol->string tab))
         (n (rec--tab-count buf tab))
         (label (if (equal? n 0) name (string-append name " " (number->string n)))))
    (list (string-append "recruiting-tab-" name) label (equal? tab at))))

(define (rec--tab-bar buf)
  (let ((at (rec-tab buf)))
    (string-append
      (string-join
        (map (lambda (tab)
               (let* ((n (rec--tab-count buf tab))
                      (cell (string-append (symbol->string tab)
                                           (if (equal? n 0) ""
                                               (string-append " " (number->string n))))))
                 (if (equal? tab at)
                     (string-append "[" cell "]")
                     (string-append " " cell " "))))
             *recruiting-tabs*)
        " ")
      "   <left>/<right> switch tab")))

(define rec-css-title "padding:.7em .9em .1em;font-weight:700;font-size:1.06em;letter-spacing:-.01em")
(define rec-css-note "padding:0 .9em .55em;color:var(--dim-fg,#8a857a);font-size:.78em")
(define rec-css-rule "border-bottom:1px solid var(--border-bg,#e2ded4);margin:0 .5em")

(define (rec--block tag text field css)
  (list 'tag tag
        'attrs (append (if field (list (list "field" field)) '())
                       (if css (list (list "style" css)) '()))
        'text (if (number? text) (number->string text) (or text ""))))

(define (rec-title buf)
  (let* ((job (rec-job buf))
         (co (and job (plist-get job 'company))))
    (if (not job)
        "Recruiting"
        (string-append (rec-str (plist-get job 'title))
                       (if co (string-append " - " (rec-str (plist-get co 'name))) "")))))

(define (rec--composml-head buf head)
  (let* ((at (rec-tab buf))
         (q (list-query buf))
         (note (if (equal? q "")
                   "RET page - <left>/<right> tab - g refresh - q quit"
                   (string-append "matching " q))))
    (list
      (rec--block "div" (rec-title buf) #f rec-css-title)
      (component 'ui/tabs
        (list 'class "recruiting-tabs"
              'tabs (map (lambda (t) (rec--tab-entry buf t at)) *recruiting-tabs*)))
      (rec--block "div" note #f rec-css-note)
      (rec--block "div" "" #f rec-css-rule))))

;;; ------------------------------------------------------------- the detail

(effects! '(write display))

;; The listing is named after the JOB, not after the app: two jobs are
;; two places, and a switcher full of *recruiting* tells you nothing.
;; The tab is a view over that one job, so it stays out of the name --
;; a buffer that renamed itself on every tab would lose its pane in the
;; group's saved layout, and the detail pages opened from it would be
;; owned by a buffer that no longer exists.
(define (rec-job-label job)
  (let ((co (plist-get job 'company)))
    (string-append (rec-str (plist-get job 'title))
                   (if co (string-append " at " (rec-str (plist-get co 'name))) ""))))

(define (rec-buffer-name job)
  (string-append "*" (rec-job-label job) "*"))

;; the one listing the reader is in, else the last one opened
(define (rec-listing)
  (let ((b (current-buffer)))
    (if (and b (buffer-exists? b) (buffer-derived-mode? b "recruiting-mode"))
        b
        (or *recruiting-last* *recruiting-buffer*))))

(define (rec-join-group! buf &optional role)
  (when (and buf (buffer-exists? buf))
    (when (boundp 'app-claim!) (app-claim! buf *recruiting-app-id* (or role 'aux)))
    (when (boundp 'buffer-join-here!) (buffer-join-here! buf)))
  buf)

;; the page is built from ATS text, so every value is escaped: a JD is
;; prose someone else wrote and it may hold markup of its own.
(define (rec--esc s)
  (let* ((s (rec-str s))
         (s (re-replace-all "&" s "&amp;"))
         (s (re-replace-all "<" s "&lt;")))
    (re-replace-all ">" s "&gt;")))

(define rec-detail-css
  (string-append
    "<style>:root{font-size:1.15vw}"
    "body{margin:0;padding:1.2rem 1.4rem;font-family:ui-sans-serif,system-ui,sans-serif;line-height:1.5}"
    "h1{margin:0 0 .2rem;font-size:1.5rem;letter-spacing:-.01em}"
    ".sub{color:#8a857a;font-size:.95rem;margin-bottom:1rem}"
    ".chips{margin:.5rem 0 1rem}"
    ".chip{display:inline-block;border:1px solid #d8d4cb;border-radius:999px;padding:.1rem .7rem;margin:0 .3rem .3rem 0;font-size:.85rem}"
    "dl{margin:0}dt{color:#8a857a;font-size:.85rem;margin-top:.8rem}dd{margin:.1rem 0 0;font-size:1rem}"
    ".body{margin-top:1rem;white-space:pre-wrap;font-size:.95rem}</style>"))

(define (rec--dd label value)
  (if (equal? (rec-str value) "")
      ""
      (string-append "<dt>" (rec--esc label) "</dt><dd>" (rec--esc value) "</dd>")))

(define (rec-person-html row)
  (let* ((r (rec-rec row))
         (specs (or (plist-get r 'candidate_specialisations) '()))
         (sub (let ((tag (rec-str (plist-get r 'candidate_tagline))))
                (if (equal? tag "")
                    (let ((co (rec-str (plist-get r 'company_name)))
                          (jt (rec-str (plist-get r 'job_title))))
                      (if (equal? co "") "" (string-append co " - " jt)))
                    tag)))
         (body (let ((why (rec-str (plist-get r 'rationale)))
                     (cl (rec-str (plist-get r 'cover_letter))))
                 (cond ((not (equal? why "")) why)
                       ((not (equal? cl "")) cl)
                       (else "")))))
    (string-append
      rec-detail-css
      "<h1>" (rec--esc (plist-get r 'candidate_name)) "</h1>"
      (if (equal? sub "") "" (string-append "<div class='sub'>" (rec--esc sub) "</div>"))
      (if (null? specs)
          ""
          (string-append "<div class='chips'>"
            (string-join (map (lambda (s)
                                (string-append "<span class='chip'>" (rec--esc s) "</span>"))
                              specs)
                         "")
            "</div>"))
      "<dl>"
      (rec--dd "years" (plist-get r 'candidate_yoe))
      (rec--dd "state" (plist-get r 'state))
      (rec--dd "score" (rec-num2 (plist-get r 'score)))
      (rec--dd "rerank" (rec-num2 (plist-get r 'rerank_score)))
      (rec--dd "source" (plist-get r 'source))
      (rec--dd "applied by" (plist-get r 'applied_by_role))
      (rec--dd "last event" (rec-day (plist-get r 'last_event_at)))
      (rec--dd "last email from" (plist-get r 'last_email_from))
      (rec--dd "manages" (plist-get r 'candidate_management))
      (rec--dd "leads" (plist-get r 'candidate_leadership))
      "</dl>"
      (if (equal? body "") "" (string-append "<div class='body'>" (rec--esc body) "</div>")))))

;; the summary row carries the whole description under it, so the job
;; tab has one page that is the JD itself and not a field of it.
(define (rec-field-html buf row)
  (let* ((r (rec-rec row))
         (label (rec-str (plist-get r 'label)))
         (job (rec-job buf)))
    (string-append
      rec-detail-css
      "<h1>" (rec--esc label) "</h1>"
      "<div class='body'>" (rec--esc (plist-get r 'value)) "</div>"
      (if (and (equal? label "summary") job)
          (string-append "<div class='body'>" (rec--esc (plist-get job 'description)) "</div>")
          ""))))

(define (rec-detail-html buf row)
  (if (rec-person? row) (rec-person-html row) (rec-field-html buf row)))

;; A page is named for the job it was opened from as well as the row:
;; the same candidate scores differently under two jobs, so one page
;; must not stand for both. The name is who it is about, never the
;; uuid the row is keyed by -- the key routes, the name is read.
(define (rec-company buf)
  (let* ((job (rec-job buf))
         (co (and job (plist-get job 'company))))
    (if co (rec-str (plist-get co 'name)) "")))

(define (rec-detail-buffer buf row)
  (let* ((r (rec-rec row))
         (co (rec-company buf))
         (at (if (equal? co "") "" (string-append " (" co ")")))
         (who (if (rec-person? row)
                  (string-append "candidate: " (rec-str (plist-get r 'candidate_name)))
                  (string-append "job: " (rec-str (plist-get r 'label))))))
    (string-append "*" who at "*")))

(define (rec-render-detail! dbuf buf row)
  (unless (buffer-exists? dbuf) (buffer-create dbuf))
  (buffer-set-read-only! dbuf #f)
  (let ((old (buffer-text dbuf)) (new (rec-detail-html buf row)))
    (if (> (string-length old) 0)
        (buffer-replace! dbuf old new)
        (buffer-append! dbuf new)))
  (buffer-set-local! dbuf 'recruiting-row row)
  ;; a page kept with M-RET takes the same read name, not the uuid
  (buffer-set-local! dbuf 'recruiting-title
                     (let ((n (rec-detail-buffer buf row)))
                       (substring n 1 (- (string-length n) 1))))
  (unless (buffer-derived-mode? dbuf "recruiting-detail-mode")
    (with-current-buffer dbuf (lambda () (set-mode! "recruiting-detail-mode"))))
  (buffer-set-local! dbuf 'preview-renderer "html")
  (enable-minor-mode! dbuf "preview-mode")
  (preview-heal! dbuf)
  (buffer-set-read-only! dbuf #t)
  dbuf)

(define (rec-show-detail! buf row)
  (when (and buf row)
    (let ((dbuf (rec-render-detail! (rec-detail-buffer buf row) buf row)))
      (rec-join-group! dbuf 'detail)
      (display-buffer-detail! dbuf buf)
      dbuf)))

;;; ---------------------------------------------------------------- the list

(define *recruiting-doc*
  (string-append ;; force reload
    "One job from the ATS, in three tabs over one listing. The buffer is "
    "named for the job, so two jobs are two places in the switcher. "
    "suggestions is the board in the order the client sees it, numbered "
    "by that order, with the F-v1 score and whether the row came from "
    "the search, an agent, or a person. applications is what stands "
    "against the job and the state each one is in. job is the posting "
    "itself, one row per fact it states, and the summary row opens the "
    "whole description. Moving shows that row as a page beside the "
    "listing, and the detail walk flips through the pages you have "
    "opened. RET shows it again, <left> and <right> change the tab and "
    "so does clicking one in the tab bar, a tab reads the ATS the first "
    "time you enter it, g reads this tab again, J opens another job, "
    "q quits. / narrows the rows already drawn."))

(define-list-mode! "recruiting-mode"
  (list 'doc *recruiting-doc*
        'buffer *recruiting-buffer*
        'transient #f
        'noun "row"
        'rows rec--rows
        'key (lambda (buf row) (rec-key row))
        'columns rec--columns
        'cells rec--cells
        'layouts (list (list 'name 'narrow
                             'max-cols (lambda (buf) (- recruiting-narrow-cols 1))
                             'columns rec--narrow-columns
                             'cells rec--narrow-cells)
                       (list 'name 'wide
                             'default #t
                             'columns rec--columns
                             'cells rec--cells))
        'title rec-title
        'meta rec--tab-bar
        'collection "c-list"
        'composml-head rec--composml-head
        'total (lambda (buf) (length (rec--rows buf)))
        'footer (lambda (buf) (list (list "RET" "page") (list "<left>/<right>" "tab")
                                    (list "J" "job") (list "g" "refresh")
                                    (list "q" "quit")))
        'preview (lambda (buf row) (rec-show-detail! buf row))
        'keys (list (list "RET" "recruiting-detail")
                    (list "<right>" "recruiting-tab-next")
                    (list "<left>" "recruiting-tab-prev")
                    (list "J" "recruiting-job")
                    (list "g" "recruiting-refresh")
                    (list "q" "bury-buffer"))))

(define-mode "recruiting-detail-mode"
  (lambda () (buffer-set-read-only! (current-buffer) #t)))
(mode-parent! "recruiting-detail-mode" "special-mode")
(mode-doc! "recruiting-detail-mode"
  "One person from the board, or one fact about the job. q quits.")
(mode-keys! "recruiting-detail-mode" (list (list "q" "bury-buffer")))

;; a kept page takes the name of who it is about, not a number
(detail-name! "recruiting-detail-mode"
  (lambda (buf) (string-append "*" (or (buffer-local buf 'recruiting-title) buf) "*")))

;;; --------------------------------------------------------------- the panes

(define (rec-current-detail buf)
  (and (boundp 'detail-window)
       (let ((w (detail-window buf)))
         (and w (window-buffer w)))))

(define (rec--chat-pane)
  (let ((id (frame-group))) (and id (group-chat id))))

(define (rec-layout! buf)
  (let ((panes (filter (lambda (b) (and b (buffer-exists? b)))
                       (list buf (rec-current-detail buf) (rec--chat-pane)))))
    (when (pair? (cdr panes)) (tile-windows! 'columns panes))
    panes))

;;; -------------------------------------------------------------- the moves

(effects! '(read write external display))

(define (rec--ready! buf first?)
  (unless (buffer-derived-mode? buf "recruiting-mode")
    (with-current-buffer buf (lambda () (set-mode! "recruiting-mode"))))
  (buffer-set-local! buf 'list-layout-cache #f)
  (list-refresh! buf)
  (switch-to-buffer! buf)
  (rec-show-detail! buf (list-current buf))
  (rec-layout! buf)
  (when first?
    (let ((id (frame-group))) (when id (group-layout-save! id)))))

;; a tab reads the ATS once and keeps what it got; g is how you ask again
(define (rec-load-tab! buf tab first?)
  (let ((id (rec-job-id buf)))
    (cond
      ((member tab (list 'job 'jd 'config)) (rec--ready! buf first?))
      ((equal? tab 'suggestions)
       (if (buffer-local buf 'recruiting-suggestions)
           (rec--ready! buf first?)
           (begin
             (message "Recruiting: reading the suggestions board...")
             (rec-fetch-suggestions! id
               (lambda (recs)
                 (buffer-set-local! buf 'recruiting-suggestions (rec--suggestion-rows recs))
                 (rec--ready! buf first?)
                 (message (string-append (number->string (length (or recs '())))
                                         " suggestions")))))))
      (else
       (if (buffer-local buf 'recruiting-applications)
           (rec--ready! buf first?)
           (begin
             (message "Recruiting: reading the applications...")
             (rec-fetch-applications! id
               (lambda (recs)
                 (buffer-set-local! buf 'recruiting-applications (rec--application-rows recs))
                 (rec--ready! buf first?)
                 (message (string-append (number->string (length (or recs '())))
                                         " applications"))))))))))

(define (rec-set-tab! buf tab)
  (buffer-set-local! buf 'recruiting-tab tab)
  (rec-load-tab! buf tab #f)
  tab)

(define (rec--tab-index buf)
  (let loop ((ts *recruiting-tabs*) (n 0))
    (cond ((null? ts) 0)
          ((equal? (car ts) (rec-tab buf)) n)
          (else (loop (cdr ts) (+ n 1))))))

(define (rec--nth xs n)
  (if (or (null? xs) (equal? n 0)) (car xs) (rec--nth (cdr xs) (- n 1))))

(define (rec--step-tab! buf d)
  (let* ((n (length *recruiting-tabs*))
         (i (rec--tab-index buf))
         (j (modulo (+ (+ i d) n) n)))
    (rec-set-tab! buf (rec--nth *recruiting-tabs* j))))

;; a tab in the bar is clickable, and a click is the same move as the key
(add-hook! (list 'block-click 'recruiting)
  (lambda (buf id)
    (and (buffer-exists? buf)
         (buffer-derived-mode? buf "recruiting-mode")
         (string-prefix? "recruiting-tab-" id)
         (let ((tab (string->symbol (substring id 15 (string-length id)))))
           (and (member tab *recruiting-tabs*)
                (begin (rec-set-tab! buf tab) #t))))))

;; opening a job gives it its own buffer, named for the job. Re-opening
;; the same job returns to the one already standing rather than a second.
(define (rec-open! job first?)
  (let ((buf (rec-buffer-name job)))
    (unless (buffer-exists? buf) (buffer-create buf))
    (set! *recruiting-last* buf)
    (rec-join-group! buf 'home)
    (buffer-set-local! buf 'recruiting-job job)
    (buffer-set-local! buf 'recruiting-suggestions #f)
    (buffer-set-local! buf 'recruiting-applications #f)
    (buffer-set-local! buf 'recruiting-tab 'suggestions)
    (rec-load-tab! buf 'suggestions first?)
    buf))

(define (rec-pick-job! first?)
  (message "Recruiting: reading the open jobs...")
  (rec-fetch-jobs!
    (lambda (jobs)
      (if (not (and jobs (pair? jobs)))
          (message "The ATS answered with no open jobs")
          (completing-read "Job: " (map rec-job-label jobs)
            (lambda (choice)
              (let loop ((js jobs))
                (cond ((null? js) (message "No such job"))
                      ((equal? (rec-job-label (car js)) choice)
                       (switch-to-buffer! (rec-open! (car js) first?)))
                      (else (loop (cdr js)))))))))))

;;; -------------------------------------------------------------- the verbs

(define-command "recruiting-detail" "Show the row at point as a page beside the listing"
  (lambda () (let ((buf (rec-listing))) (rec-show-detail! buf (list-current buf)))))

(define-command "recruiting-tab-next" "Show the next job tab"
  (lambda () (rec--step-tab! (rec-listing) 1)))

(define-command "recruiting-tab-prev" "Show the previous job tab"
  (lambda () (rec--step-tab! (rec-listing) -1)))

(define-command "recruiting-refresh" "Read this tab from the ATS again"
  (lambda ()
    (let* ((buf (rec-listing)) (tab (rec-tab buf)))
      (cond ((equal? tab 'suggestions) (buffer-set-local! buf 'recruiting-suggestions #f))
            ((equal? tab 'applications) (buffer-set-local! buf 'recruiting-applications #f)))
      (rec-load-tab! buf tab #f))))

;;;###autoload
(define-command "recruiting-job" "Open another job in its own listing"
  (lambda () (rec-pick-job! #f)))

;;;###autoload
(define-command "recruiting" "Open a job from the ATS with its tabs"
  (lambda () (rec-pick-job! #t)))

;;; ------------------------------------------------------------ the catalog

(public! 'rec-open! "open JOB in a listing named for it")
(public! 'rec-set-tab! "show one of the job's tabs in BUF")
(public! 'rec-show-detail! "show a row as a page beside its listing")
(public! 'rec-pick-job! "ask which job to open")
(public! 'rec-job-label "the job as one line: its title, at its company")
(public! 'rec-buffer-name "the listing buffer a job is shown in")

(catalog-meta! 'function "rec-open!" 'domain 'web 'effects '(read write external display))
(catalog-meta! 'function "rec-set-tab!" 'domain 'web 'effects '(read write external display))
(catalog-meta! 'function "rec-show-detail!" 'domain 'web 'effects '(write display))
(catalog-meta! 'function "rec-pick-job!" 'domain 'web 'effects '(read write external display))
(catalog-meta! 'function "rec-job-label" 'domain 'web 'effects '(pure))
(catalog-meta! 'function "rec-buffer-name" 'domain 'web 'effects '(pure))
