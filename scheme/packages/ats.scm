;;; ats.scm --- SVS recruiting as a live website app

(package! 'ats)
(origin! 'user)

(require 'site-app)

(define *ats-sheets* "/Users/svs/src/svs-recruiting/compos-recruiting/")
(define (ats-sheet file) (string-append *ats-sheets* file))

;; a plain section: its rows from one sheet, each item a plain page read in one fetch
(define (ats-section id label key path mode columns)
  (list 'id id 'label label 'key key 'path path
        'sheet (ats-sheet (string-append (symbol->string id) ".xsl"))
        'detail-sheet (ats-sheet "page-detail.xsl")
        'detail-fetch #t
        'detail-minor mode
        'columns columns))

(define (ats-candidate-row buf row)
  (let ((field (lambda (key) (or (site-app-field row key) "")))
        (confirmed? (lambda () (not (equal? (or (site-app-field row 'confirmed) "") "")))))
    (list 'tag "div" 'class "ats-card"
          'children
          (list (list 'tag "div" 'class "ats-card-face"
                      'children
                      (list (list 'tag "img" 'class "ats-card-avatar"
                                  'attrs (list (list "src" (site-app-avatar-url buf (field 'avatar))) (list "alt" "")
                                               (list "loading" "lazy") (list "referrerpolicy" "no-referrer")))
                            (list 'tag "span" 'class "sa-stars-cell"
                                  'attrs (list (list "title" (if (confirmed?) "rating · confirmed" "rating · unconfirmed")))
                                  'segs (site-app-stars-segs (field 'rating) (confirmed?)))))
                (list 'tag "div" 'class "ats-card-main"
                      'children
                      (list (list 'tag "div" 'class "ats-card-top"
                                  'segs (list (list "sa-name-cell" (field 'name))
                                              (list "c-dim" (string-append "   " (field 'experience) "   " (field 'ctc)))))
                            (list 'tag "div" 'class "ats-card-headline c-dim" 'text (field 'headline))))))))

(define-style! 'ats "
.semantic-item.ats-card { display: flex; gap: 12px; align-items: center; padding: 6px 0; font-family: var(--font-sans); font-size: 12.5px; }
.ats-card-face { display: flex; flex-direction: column; align-items: center; gap: 3px; flex: none; width: 56px; }
.ats-card-avatar { width: 32px; height: 32px; border-radius: 50%; object-fit: cover; background: var(--hl-line-bg); }
.ats-card-main { min-width: 0; display: flex; flex-direction: column; gap: 2px; }
.ats-card-top, .ats-card-headline { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
")

(define *ats-candidates-page*
  (list 'id 'candidates
        'label "Candidates"
        'key "2"
        'path "/staff/candidates"
        'sheet (ats-sheet "candidates.xsl")
        'detail-sheet (ats-sheet "candidate-detail.xsl")
        ;; the candidate's tabs, each one read from its ?tab= URL
        'detail-tab-param "tab"
        'detail-minor "ats-candidate-mode"
        'detail-tabs (map (lambda (id) (list 'id id))
                          '("profile" "suggested" "comms" "meetings" "notes"))
        ;; the page draws a card: the face over its stars, then the name and
        ;; facts over the headline. The columns are the plain-text view
        'row (lambda (buf row) (ats-candidate-row buf row))
        'columns (list (list 'label "★" 'width 5 'field 'rating 'face "dim")
                       (list 'label "candidate" 'width 24 'field 'name)
                       (list 'label "exp" 'width 6 'field 'experience 'face "dim")
                       (list 'label "ctc" 'width 12 'field 'ctc 'face "dim")
                       (list 'label "headline" 'width #f 'field 'headline))))

(define *ats-applications-page*
  (list 'id 'applications
        'label "Applications"
        'key "3"
        'path "/staff/applications"
        'wait "#job_applications"
        'sheet (ats-sheet "applications.xsl")
        'detail-sheet (ats-sheet "applications-detail.xsl")
        ;; the same tabs as an approval, each one read from its ?tab= URL
        'detail-tab-param "tab"
        'detail-minor "ats-application-mode"
        'detail-keys (list "a")
        'detail-tabs
        (map (lambda (tab) (list 'id (car tab) 'tag (cadr tab)))
             '(("history" "c-application-history")
               ("assessment" "c-assessment")
               ("candidate" "c-candidate")
               ("job" "c-job-details")))
        'columns (list (list 'label "candidate" 'width 24 'field 'candidate)
                      (list 'label "company" 'width 16 'field 'company 'face "dim")
                      (list 'label "job" 'width #f 'field 'job))))

(define *ats-approvals-page*
  (list 'id 'approvals
        'label "Approvals"
        'key "1"
        'path "/staff/approvals"
        'wait "main section ul > li"
        'sheet (ats-sheet "approvals.xsl")
        'detail-sheet (ats-sheet "approval-detail.xsl")
        ;; the tabs and the state, rating and fit chips, each a facet of the URL
        'tabs-sheet (ats-sheet "approvals-tabs.xsl")
        'detail-wait "#approvals-show-root"
        'detail-tab-param "tab"
        'detail-minor "ats-approval-mode"
        ;; only the happy path has a key: approve; o opens the site for the rest
        'detail-keys (list "a")
        'detail-tabs
        (map (lambda (tab)
               (let ((button (string-append "#approvals-show-root nav.brut-tabs button[phx-value-tab=\"" (car tab) "\"]")))
                 (list 'id (car tab) 'tag (cadr tab)
                       'click button
                       'wait (string-append button ".brut-tab--active"))))
             '(("history" "c-application-history")
               ("assessment" "c-assessment")
               ("candidate" "c-candidate")
               ("job" "c-job-details")))
        'columns
        (list (list 'label "★" 'width 6 'field 'rating 'kind 'stars)
              (list 'label "candidate" 'width 22 'field 'candidate 'kind 'name)
              (list 'label "proposal" 'width 14 'field 'proposal 'kind 'badge)
              (list 'label "fit" 'width 11 'field 'fit 'kind 'badge)
              (list 'label "company" 'width 16 'field 'company 'face "dim")
              (list 'label "job" 'width #f 'field 'job))))

(define *ats-jobs-page*
  (list 'id 'jobs
        'label "Jobs"
        'key "5"
        'path "/staff/jobs"
        'sheet (ats-sheet "jobs.xsl")
        'detail-sheet (ats-sheet "job-detail.xsl")
        ;; the job's tabs, each read from its ?tab= URL. The site's Applications tab
        ;; shows only its new ones; c opens every stage, and the suggestions, as a list
        'detail-tab-param "tab"
        'detail-minor "ats-job-mode"
        'detail-tabs (map (lambda (id) (list 'id id)) '("overview" "suggestions" "applications" "ai"))
        'detail-extra-keys (list (list "c" "ats-pipeline" "candidates"))
        'columns (list (list 'label "job" 'width 30 'field 'name)
                       (list 'label "company" 'width 16 'field 'company)
                       (list 'label "new" 'width 4 'field 'new 'face "dim")
                       (list 'label "rec" 'width 4 'field 'recommended 'face "dim")
                       (list 'label "acc" 'width 4 'field 'accepted 'face "dim")
                       (list 'label "app" 'width 4 'field 'applied 'face "dim")
                       (list 'label "posted" 'width #f 'field 'posted 'face "dim"))))

(define *ats-spec*
  (list 'name 'ats
        'title "ATS"
        'base-url "https://svsrecruiting.com"
        'home "/staff/approvals"
        'home-page 'approvals
        ;; the site is LiveView: it ignores a click until its socket joins, and this is the mark it sets
        'ready "[data-phx-main].phx-connected"
        ;; Devanagari labels and section numerals, drawn only for looks
        'ornament "^[^A-Za-z]*[\\x{0900}-\\x{097F}][^A-Za-z]*$"
        ;; a rating is a run of stars, ticked when a person confirmed it
        'rating "^★+✓?$"
        ;; the header: the job at the company, where the application stands, then the candidate.
        ;; The state line ("withdrawn → pending: withdrawn scheduled 2 Sep") gives its first word
        'detail-head (lambda (data)
                       (let* ((profile (site-app-real (plist-get data 'profile)))
                              (state-node (site-app-find (lambda (n) (re-match? " → " (or (plist-get n 'text) ""))) profile))
                              (job (or (plist-get data 'job) "")))
                         (list 'title (if (equal? job "") "" (string-append job " at " (or (plist-get data 'company) "")))
                               'title-href (plist-get data 'job_href)
                               'state (and state-node (car (string-split (string-trim (plist-get state-node 'text)) " ")))
                               'head (filter (lambda (n) (not (equal? n state-node))) profile))))
        ;; every detail is ats-detail-mode, so they all share a pane; the page it
        ;; came from is a minor mode (ats-approval-mode, ats-application-mode, ...)
        'detail-mode "ats-detail-mode"
        ;; the status, stage or scope tabs a section's page draws above its rows
        'tabs-sheet (ats-sheet "tabs.xsl")
        ;; a suggestion card on a job page: recommend the job to them, or open them against it
        'card-keys (list (list "sa-candidate" (list (list "r" "ats-suggestion-recommend" "recommend")
                                                    (list "RET" "ats-suggestion-open" "open"))))
        ;; an application card on a job page reads its assessment and history when it opens
        'card-details (list (list "sa-application"
                                  (lambda (card)
                                    (let ((path (string-append "/staff/applications/" (plist-get card 'aid))))
                                      (map (lambda (tab) (list (car tab) (string-append path "?tab=" (cadr tab))
                                                               (ats-sheet "applications-detail.xsl")))
                                           '(("Assessment" "assessment") ("History" "history")))))))
        ;; an application is who for what; anything else goes by its name
        'detail-name (lambda (row)
                       (if (equal? (site-app-field row 'candidate) "")
                           (site-app-field row 'name)
                           (string-append (site-app-field row 'candidate) " · " (site-app-field row 'job))))
        ;; sections a detail tab reads in another order: (TAB SECTION BEFORE)
        'detail-moves '(("candidate" "Notes" "Work Experience"))
        ;; words the site colours, wherever they appear on a page
        'tones '(("^★+✓?$" warn)
                 ("^(?i)(unfit|withdrawn|withdraw|reject|rejected|declined|dropped|delete)$" bad)
                 ("^(?i)(potential|pending|snoozed|scheduled|maybe)$" warn)
                 ("^(?i)(elite|strong|fit|advance|advanced|approve|approved|hired|shortlisted|offer)$" good)
                 ("^(?i)(new|applied|create|created)$" info))
        ;; the site's navbar, in its order; M-key switches to a section
        'pages
        (list
          *ats-approvals-page*
          *ats-candidates-page*
          *ats-applications-page*
          (append
      ;; a company has tabs of its own, each read from its ?tab= URL; the earlier
      ;; keys win over the plain page that ats-section reads
      (list 'detail-sheet (ats-sheet "company-detail.xsl")
            'detail-fetch #f
            'detail-tab-param "tab"
            'detail-tabs (map (lambda (id) (list 'id id)) '("overview" "subscriptions")))
      (ats-section 'companies "Companies" "4" "/staff/companies" "ats-company-mode"
                   (list (list 'label "company" 'width 24 'field 'name)
                         (list 'label "state" 'width 12 'field 'state)
                         (list 'label "jobs" 'width 10 'field 'active 'face "dim")
                         (list 'label "website" 'width #f 'field 'website 'face "dim"))))
          *ats-jobs-page*
          (ats-section 'comms "Comms" "6" "/staff/comms" "ats-message-mode"
            (list (list 'label "from" 'width 26 'field 'name)
                  (list 'label "when" 'width 8 'field 'when 'face "dim")
                  (list 'label "via" 'width 9 'field 'channel 'face "dim")
                  (list 'label "subject" 'width #f 'field 'subject))))))

;; the ATS's own words for what its pages hold. A page's sheet names the component
;; a record is ("component": "ats/work-experience"); each is a core component drawn
;; under the ATS's element, so the page source reads <work-experience>, not <c-card>
(define (ats-component-as! name base element doc)
  (define-element! element)
  (let ((e (component-entry base)))
    (defcomponent name doc (nth 1 e) (nth 2 e)
      (lambda (p) (plist-put (component base p) 'tag element)))))

(ats-component-as! 'ats/work-experiences 'ui/group "work-experiences" "A candidate's work history: its heading and one work-experience a job.")
(ats-component-as! 'ats/work-experience 'ui/card "work-experience" "One job in a work history: the employer's logo, name, tier and tags head it; the role, dates and bullets are its body.")
(ats-component-as! 'ats/applications 'ui/group "applications" "A candidate's applications, one application a job.")
(ats-component-as! 'ats/application 'ui/card "application" "One application: the job at the company, its state, fit and meeting; it reads its assessment and history when it opens.")
(ats-component-as! 'ats/assessment 'ui/callout "assessment" "A take on a candidate for a job, quick or deep: its verdict as the label, the reasoning as the body.")
(ats-component-as! 'ats/job-context 'ui/group "job-context" "The job a candidate page is opened against: the job, the assessment and the application.")

(define-style! 'ats-elements "
:where(work-experiences, work-experience, applications, application, assessment, job-context) { display: block; }
")

(define-site-app *ats-spec*)

(domain! 'web)
(effects! '(write external display))

;;;###autoload
(define-command "ats" "Open SVS recruiting as a live website app"
  (lambda () (site-app-open! 'ats)))

;; ---------------------------------------------------------------- the pipeline
;; One job's candidates in one list: its applications stage by stage, then the
;; suggestions not yet in it. The applications come from the ats-ash MCP, since
;; the site's Applications tab shows one status at a time and switches it by
;; button; the suggestions come from the site's board. A row opens as the pair it
;; is: an application's page, or a suggestion's candidate page read against the job.

(domain! 'web)
(effects! '(write external display))

(define *ats-pipeline-stages*
  '("new" "recommended" "accepted" "emailed" "applied" "shortlisted" "offered" "hired"
    "suggested"
    "unsuitable" "withdrawn" "unrecommended" "candidate_rejected" "offer_rescinded" "rejected" "closed"))

(define (ats-pipeline-buffer title) (string-append "*ats-pipeline: " title "*"))

;; the applications, each carrying what its suggestion card knows, then the cards
;; no application took; grouped by stage in pipeline order, the board's order within
(define (ats-pipeline-merge job title apps cards)
  (let* ((card-of (lambda (cid) (or (site-app-find (lambda (c) (equal? (plist-get c 'cid) cid)) cards) '())))
         (taken (map (lambda (a) (plist-get a 'candidate_id)) apps))
         (rows (append
                 (map (lambda (a)
                        (append (list 'key (plist-get a 'id)
                                      'kind "application"
                                      'stage (plist-get a 'state)
                                      'candidate (plist-get a 'candidate_name)
                                      'cid (plist-get a 'candidate_id)
                                      'job title
                                      'href (string-append "/staff/applications/" (plist-get a 'id)))
                                (card-of (plist-get a 'candidate_id))))
                      apps)
                 (map (lambda (c)
                        (append (list 'key (plist-get c 'cid)
                                      'stage "suggested"
                                      'job title
                                      'href (string-append "/staff/candidates/" (plist-get c 'slug) "?job=" job))
                                c))
                      (filter (lambda (c) (not (member (plist-get c 'cid) taken))) cards)))))
    (append
      (apply append (map (lambda (stage) (filter (lambda (r) (equal? (plist-get r 'stage) stage)) rows))
                         *ats-pipeline-stages*))
      (filter (lambda (r) (not (member (plist-get r 'stage) *ats-pipeline-stages*))) rows))))

;; both reads land in the buffer; the list draws once it holds the two
(define (ats-pipeline-read! buf)
  (let* ((job (buffer-local buf 'ats-pipeline-job))
         (title (buffer-local buf 'ats-pipeline-title))
         (land! (lambda (key value)
                  (buffer-set-local! buf key value)
                  (let ((apps (buffer-local buf 'ats-pipeline-apps))
                        (cards (buffer-local buf 'ats-pipeline-cards)))
                    (when (and apps cards)
                      (buffer-set-local! buf 'ats-pipeline-rows (ats-pipeline-merge job title apps cards))
                      (buffer-set-local! buf 'list-layout-cache #f)
                      (list-refresh! buf)
                      (message (string-append title ": " (number->string (length apps)) " applications, "
                                              (number->string (length cards)) " suggestions")))))))
    (buffer-set-local! buf 'ats-pipeline-apps #f)
    (buffer-set-local! buf 'ats-pipeline-cards #f)
    (message (string-append "Reading the candidates for " title "..."))
    (mcp-call! 'ats-ash "listApplications"
      (json-encode (list 'input (list 'job_id job) 'limit 200))
      (lambda (ok text)
        (let ((apps (and ok (string? text) (string-prefix? "[" text) (json-parse text))))
          (unless apps (message (string-append "ats pipeline: applications failed: " (if (string? text) text ""))))
          (land! 'ats-pipeline-apps (or apps '())))))
    (site-app-fetch-html! (site-app-url (site-app-spec 'ats) (string-append "/staff/jobs/" job "?tab=suggestions&fit=all"))
      (lambda (html)
        (let ((cards (and html (site-app-parse (ats-sheet "job-suggestions.xsl") html))))
          (unless (pair? cards) (message "ats pipeline: the suggestions board read nothing"))
          (land! 'ats-pipeline-cards (if (pair? cards) cards '())))))))

(define (ats-pipeline-rows buf) (or (buffer-local buf 'ats-pipeline-rows) '()))
(define (ats-pipeline-key buf row) (plist-get row 'key))
(define (ats-pipeline-title buf) (or (buffer-local buf 'ats-pipeline-title) "Pipeline"))

(define (ats-pipeline-columns buf)
  (list (list "stage" 12) (list "fit" 10) (list "rating" 7) (list "candidate" 24)
        (list "exp" 6) (list "ctc" 12) (list "headline" #f)))

(define (ats-pipeline-cells buf row)
  (let* ((f (lambda (key) (site-app-field row key)))
         ;; the rating as stars: its whole number filled, padded to five
         (n (let ((r (f 'rating))) (or (and (> (string-length r) 0) (string->number (substring r 0 1))) 0)))
         (stars (if (> n 0) (string-append (substring "★★★★★" 0 n) (substring "☆☆☆☆☆" 0 (- 5 n))) "")))
    (list (list (f 'stage) "dim") (f 'fit) stars (f 'candidate)
          (list (f 'experience) "dim") (list (f 'ctc) "dim") (f 'headline))))

;; an application opens as an application; a suggestion as its candidate, against the job
(define (ats-pipeline-open-row! buf row)
  (when row
    (site-app-show-detail! buf row
      (site-app-page (site-app-spec 'ats)
                     (if (equal? (plist-get row 'kind) "application") 'applications 'candidates)))))

(define (ats-pipeline-show! job title from)
  (let ((buf (ats-pipeline-buffer title)))
    (unless (buffer-exists? buf) (buffer-create buf))
    (site-app-join-group! buf)
    (buffer-set-local! buf 'site-app-spec (site-app-spec 'ats))
    (buffer-set-local! buf 'ats-pipeline-job job)
    (buffer-set-local! buf 'ats-pipeline-title title)
    (unless (buffer-derived-mode? buf "ats-pipeline-mode")
      (with-current-buffer buf (lambda () (set-mode! "ats-pipeline-mode"))))
    (if (and from (buffer-exists? from)) (display-buffer-detail! buf from) (switch-to-buffer! buf))
    (when (null? (ats-pipeline-rows buf)) (ats-pipeline-read! buf))
    buf))

;; the job at hand: the row of the jobs list, or the job page beside it
(define (ats-pipeline-job-at buf)
  (if (buffer-derived-mode? buf "ats-jobs-mode")
      (let ((row (list-current buf))) (and row (list row buf)))
      (let ((row (buffer-local buf 'site-app-row)))
        (and row (string-prefix? "/staff/jobs/" (or (plist-get row 'href) ""))
             (list row (buffer-local buf 'site-app-list))))))

(define-command "ats-pipeline" "Open the job's candidates: its applications by stage, then its suggestions"
  (lambda ()
    (let ((hit (ats-pipeline-job-at (current-buffer))))
      (if hit
          (ats-pipeline-show! (plist-get (car hit) 'key) (site-app-field (car hit) 'name) (cadr hit))
          (message "No job here")))))

(define-command "ats-pipeline-open" "Open the candidate on this row beside the list"
  (lambda ()
    (let ((buf (current-buffer))) (ats-pipeline-open-row! buf (list-current buf)))))

(define-command "ats-pipeline-refresh" "Read the job's applications and suggestions again"
  (lambda () (ats-pipeline-read! (current-buffer))))

(define-command "ats-pipeline-recommend" "Recommend the job to the suggested candidate on this row"
  (lambda ()
    (let* ((buf (current-buffer))
           (row (list-current buf))
           (name (and row (site-app-field row 'candidate))))
      (cond ((not row) (message "No candidate here"))
            ((not (equal? (plist-get row 'stage) "suggested"))
             (message (string-append name " is already " (site-app-field row 'stage))))
            (else
             (message (string-append "Recommending " (ats-pipeline-title buf) " to " name "..."))
             (mcp-call! 'ats-ash "recommendJobToCandidate"
               (json-encode (list 'input (list 'job_id (buffer-local buf 'ats-pipeline-job)
                                               'candidate_id (plist-get row 'cid))))
               (lambda (ok text)
                 (message (if ok
                              (string-append "Recommended to " name)
                              (string-append "Recommend failed for " name ": " (if (string? text) text ""))))
                 (when ok (ats-pipeline-read! buf)))))))))

(define-list-mode! "ats-pipeline-mode"
  (list 'doc "One job's candidates: its applications stage by stage, then the suggestions not yet in it. Moving or RET opens the candidate beside the list, an application as its application and a suggestion as its candidate page for this job. r recommends the job to a suggested candidate, / narrows (stage:applied keeps one stage, fit:strong one fit), g rereads, q quits."
        'transient #f
        'noun "candidate"
        'rows ats-pipeline-rows
        'key ats-pipeline-key
        'columns ats-pipeline-columns
        'cells ats-pipeline-cells
        'title ats-pipeline-title
        'preview ats-pipeline-open-row!
        'debounce #t
        'filters (list (list "stage:" (lambda (buf row) (site-app-field row 'stage)) "the stage: new, recommended, applied, suggested...")
                       (list "fit:" (lambda (buf row) (site-app-field row 'fit)) "the fit: strong, potential, unfit"))
        'footer (lambda (b) (list (list "RET" "open") (list "r" "recommend") (list "/" "narrow") (list "g" "refresh") (list "q" "quit")))
        'keys (list (list "RET" "ats-pipeline-open")
                    (list "r" "ats-pipeline-recommend")
                    (list "g" "ats-pipeline-refresh")
                    (list "q" "quit-window"))))

(when (boundp 'app-detail-keys!)
  (app-detail-keys! "ats-pipeline-mode" "site-app-detail-mode"))

;; c on the jobs list opens the row's candidates; the job page has it as an extra key
(define-key (mode-keymap "ats-jobs-mode") "c" "ats-pipeline")

;; ---------------------------------------------------------------- suggestion cards
;; The job page's Suggestions tab is one card a candidate; these are its keys.

(define (ats-suggestion-at buf)
  (let ((card (site-app-card-at buf)))
    (and card (equal? (plist-get card 'class) "sa-candidate") card)))

(define-command "ats-suggestion-open" "Open the suggested candidate against this job"
  (lambda ()
    (let* ((buf (current-buffer))
           (card (ats-suggestion-at buf))
           (job (buffer-local buf 'site-app-row)))
      (if (not card)
          (message "No suggestion here")
          (site-app-show-detail! (buffer-local buf 'site-app-list)
            (list 'key (plist-get card 'cid)
                  'candidate (plist-get card 'name)
                  'job (site-app-field job 'name)
                  'href (string-append "/staff/candidates/" (plist-get card 'slug) "?job=" (plist-get job 'key)))
            (site-app-page (site-app-spec 'ats) 'candidates))))))

(define-command "ats-suggestion-recommend" "Recommend this job to the suggested candidate"
  (lambda ()
    (let* ((buf (current-buffer))
           (card (ats-suggestion-at buf))
           (job (buffer-local buf 'site-app-row))
           (name (and card (plist-get card 'name))))
      (cond ((not card) (message "No suggestion here"))
            ((not (equal? (or (plist-get card 'state) "") ""))
             (message (string-append name " is already " (plist-get card 'state))))
            (else
             (message (string-append "Recommending " (site-app-field job 'name) " to " name "..."))
             (mcp-call! 'ats-ash "recommendJobToCandidate"
               (json-encode (list 'input (list 'job_id (plist-get job 'key) 'candidate_id (plist-get card 'cid))))
               (lambda (ok text)
                 (message (if ok
                              (string-append "Recommended to " name)
                              (string-append "Recommend failed for " name ": " (if (string? text) text ""))))
                 (when (and ok (buffer-exists? buf))
                   (with-current-buffer buf (lambda () (run-command "site-app-detail-reload")))))))))))
