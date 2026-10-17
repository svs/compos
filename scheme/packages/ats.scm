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
        'detail-kind mode
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
                            (list 'tag "div" 'class "ats-card-headline" 'text (field 'headline))))))))

(define-style! 'ats "
.semantic-item.ats-card { display: flex; gap: 12px; align-items: center; padding: 6px 0; font-family: var(--font-sans); font-size: 12.5px; }
.ats-card-face { display: flex; flex-direction: column; align-items: center; gap: 3px; flex: none; width: 56px; }
.ats-card-avatar { width: 32px; height: 32px; border-radius: 50%; object-fit: cover; background: var(--hl-line-bg); }
.ats-card-main { min-width: 0; display: flex; flex-direction: column; gap: 2px; }
.ats-card-top, .ats-card-headline { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
")

;; the Brief tab of an application: the newest internal assessment note from its
;; history, then the work experience from its candidate tab
(define (ats-brief-note nodes)
  (let loop ((ns (site-app-real nodes)))
    (and (pair? ns)
         (or (and (equal? (plist-get (car ns) 'class) "sa-note") (car ns))
             (ats-brief-note (plist-get (car ns) 'children))
             (loop (cdr ns))))))

(define (ats-brief-work nodes)
  (let ((from (let skip ((ns (site-app-real nodes)))
                (cond ((null? ns) '())
                      ((and (equal? (plist-get (car ns) 'tag) "c-heading")
                            (equal? (plist-get (car ns) 'text) "Work Experience")) ns)
                      (else (skip (cdr ns)))))))
    (if (null? from)
        '()
        (cons (car from) (let take ((ns (cdr from)))
                           (if (and (pair? ns) (equal? (plist-get (car ns) 'tag) "c-item"))
                               (cons (car ns) (take (cdr ns)))
                               '()))))))

(define *ats-brief-tab*
  (list 'id "brief" 'label "brief" 'from '("history" "candidate")
        'build (lambda (section)
                 (let ((note (ats-brief-note (section "history"))))
                   (append (if note (list note) '()) (ats-brief-work (section "candidate")))))))

(define *ats-candidates-page*
  (list 'id 'candidates
        'label "Candidates"
        'key "2"
        'path "/staff/candidates"
        'sheet (ats-sheet "candidates.xsl")
        'detail-sheet (ats-sheet "candidate-detail.xsl")
        ;; the candidate's tabs, each one read from its ?tab= URL
        'detail-tab-param "tab"
        'detail-kind "ats-candidate-mode"
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
        'detail-kind "ats-application-mode"
        'detail-keys (list "a")
        'detail-composed (list *ats-brief-tab*)
        'detail-default "brief"
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
        'detail-kind "ats-approval-mode"
        ;; only the happy path has a key: approve; o opens the site for the rest
        'detail-keys (list "a")
        'detail-composed (list *ats-brief-tab*)
        'detail-default "brief"
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
        'detail-kind "ats-job-mode"
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
        ;; every detail derives from ats-detail-mode and they share a pane; each
        ;; page's kind is a mode derived from it (ats-approval-mode, ats-application-mode, ...)
        'detail-mode "ats-detail-mode"
        ;; M-o on a row: the chat of that case, as on its page; a falls through to the page and approves
        'list-keys (list (list "M-o" "site-app-agent" "agent"))
        ;; the status, stage or scope tabs a section's page draws above its rows
        'tabs-sheet (ats-sheet "tabs.xsl")
        ;; a suggestion card on a job page: recommend the job to them, or open them against it
        'card-keys (list (list "sa-candidate" (list (list "r" "ats-suggestion-recommend" "recommend")
                                                    (list "RET" "ats-suggestion-open" "open")))
                         ;; an application is a row: RET opens it as its own page beside the list
                         (list "sa-application" (list (list "RET" "ats-application-open" "open"))))
        ;; an application is who for what; anything else goes by its name
        'detail-name (lambda (row)
                       (if (equal? (site-app-field row 'candidate) "")
                           (site-app-field row 'name)
                           (string-append (site-app-field row 'candidate) " · " (site-app-field row 'job))))
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
(define-element! "application")
(let ((e (component-entry 'ui/card)))
  (defcomponent 'ats/application
    "One application as a card: who (the candidate's photo and name, or the job at the company on a candidate's own page), its state as a badge toned by outcome, the fit, stars and meeting as tags; the body is when it came in and where processing stands, then its buttons. It reads its assessment and history when it opens."
    (nth 1 e) (nth 2 e)
    (lambda (p) (ats-application-card p))))

;; the head of an application: a photo, the name large with its stars, and under it
;; the state and fit as pills, the meeting and when it came in. The sheet hands the
;; facts over as the card's face (icon, badge, tags); this lays them out as a row
(define (ats-application-tone-fit fit)
  (cond ((re-match? "^(?i)strong" fit) "good") ((re-match? "^(?i)potential" fit) "warn")
        ((re-match? "^(?i)unfit" fit) "bad") (else "")))

(define (ats-application-card p)
  (let* ((card (component 'ui/card p))
         (open? (component--get p 'open? #t))
         (tags (component--get p 'tags '()))
         (has (lambda (re) (site-app-find (lambda (t) (re-match? re t)) tags)))
         (fit (has " fit$"))
         (stars (has "^★+✓?$"))
         (rest (filter (lambda (t) (not (or (equal? t fit) (equal? t stars)))) tags))
         (pill (lambda (text tone) (list 'tag "span" 'class (string-append "ats-pill " tone) 'text text)))
         (photo (cond ((component--has? p 'icon)
                       (list 'tag "img" 'class "ats-app-photo"
                             'attrs (list (list "src" (component--get p 'icon)) (list "alt" ""))))
                      ((component--has? p 'letter)
                       (list 'tag "span" 'class "ats-app-photo ats-app-letter" 'text (component--get p 'letter)))
                      (else #f)))
         (head (list 'tag "c-headline" 'class "c-fold-head ats-app-head"
                     'attrs (list (list "folded" (if open? "false" "true")))
                     'children
                     (append
                       (if photo (list photo) '())
                       (list (list 'tag "c-group" 'class "ats-app-main"
                                   'children
                                   (list (list 'tag "c-group" 'class "ats-app-line"
                                               'children (append (list (list 'tag "span" 'class "ats-app-name" 'text (component--get p 'title "")))
                                                                 (if stars (list (list 'tag "span" 'class "ats-app-stars" 'segs (site-app-stars-segs stars))) '())))
                                         (list 'tag "c-group" 'class "ats-app-meta"
                                               'children (append (if (component--has? p 'badge)
                                                                     (list (pill (component--get p 'badge) (component--get p 'badge-class "")))
                                                                     '())
                                                                 (if fit (list (pill fit (ats-application-tone-fit fit))) '())
                                                                 (map (lambda (t) (list 'tag "span" 'class "ats-app-fact" 'text t)) rest)))))
                             ;; a row with nothing under it opens beside the list, not in place
                             (if (null? (component--get p 'body '()))
                                 (list 'tag "span" 'class "ats-app-caret" 'text "↗")
                                 (list 'tag "span" 'class "ats-app-caret" 'text (if open? "▾" "▸")))))))
         (body (if open? (list (list 'tag "c-group" 'class "ats-app-body" 'children (component--get p 'body '()))) '())))
    (plist-put (plist-put (plist-put card 'tag "application")
                          'class (string-append "c-card ats-application " (component--get p 'class "")))
               'children (cons head body))))
(ats-component-as! 'ats/assessment 'ui/callout "assessment" "A take on a candidate for a job, quick or deep: its verdict as the label, the reasoning as the body.")
(ats-component-as! 'ats/job-context 'ui/group "job-context" "The job a candidate page is opened against: the job, the assessment and the application.")

(define-style! 'ats-elements "
:where(work-experiences, work-experience, applications, application, assessment, job-context) { display: block; }
/* an application: a row, not a grey bar */
.c-card.ats-application { border: 1px solid var(--border-bg); margin: 0 0 8px; background: transparent; }
.ats-application > .ats-app-head { display: flex; align-items: center; gap: 14px; padding: 10px 14px; background: transparent; font-family: var(--font-sans); cursor: pointer; }
.ats-application > .ats-app-head:hover, .ats-application.current > .ats-app-head { background: var(--hl-line-bg); }
.ats-app-photo { width: 40px; height: 40px; flex: none; border-radius: 50%; object-fit: cover; background: var(--hl-line-bg); }
.ats-app-letter { display: inline-grid; place-items: center; font-weight: 700; color: var(--default-bg); background: var(--accent-fg); }
.ats-app-main { display: flex; flex-direction: column; gap: 5px; min-width: 0; flex: 1; margin: 0; }
.ats-app-line { display: flex; align-items: baseline; gap: 10px; margin: 0; }
.ats-app-name { font-size: 1.05em; font-weight: 600; color: var(--default-fg); }
.ats-app-stars { font-size: .8em; }
.ats-app-meta { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; margin: 0; font-size: .82em; color: var(--dim-fg); }
.ats-pill { font-family: var(--font-mono); font-size: .85em; font-weight: 600; text-transform: uppercase; letter-spacing: .05em; padding: 0 7px; line-height: 1.6; border: 1px solid var(--border-bg); color: var(--dim-fg); }
.ats-pill.good { color: var(--ok-fg); border-color: var(--ok-fg); }
.ats-pill.info { color: var(--accent-fg); border-color: var(--accent-fg); }
.ats-pill.warn { color: var(--warn-fg); border-color: var(--warn-fg); }
.ats-pill.bad { color: var(--alert-fg); border-color: var(--alert-fg); }
.ats-app-fact + .ats-app-fact::before, .ats-pill + .ats-app-fact::before { content: '·'; margin-right: 8px; color: var(--border-bg); }
.ats-app-caret { flex: none; color: var(--dim-fg); }
.ats-app-body { margin: 0; padding: 4px 14px 12px 68px; }
")

(define-site-app *ats-spec*)

;; M-O in the approvals list: the top approvals go to one orchestrator chat,
;; which spawns a subagent per approval and compiles their answers in one table
(define (ats-approval-review-ask id)
  (string-append
    "Review pending approval " id " in the ATS. Its page is already open in the buffer " (or (ats-case-buffer id) "?")
    ": read it with (ats-approval-text \"" id "\"). Do not list or search the approvals queue, and do not use the ats-ash tools to read it.\n\n"
    "An approval is a move Vidura proposes for an application, such as new → withdrawn or accepted → applied, usually with an email to the candidate or the client. "
    "Judge whether SVS should approve it: is the move right for this candidate against the job's must-haves, and is the email accurate about the candidate, without overclaiming and without facts from an old CV?\n\n"
    "Do not approve, reject, edit, send or schedule anything. Answer in at most five lines. The first says approve, reject, edit or unsure; then what's proposed and why; "
    "the last is this link: https://svsrecruiting.com/staff/approvals/" id))

(define (ats-approvals-review-prompt ids)
  (let ((n (number->string (length ids)))
        (q "\""))
    (string-append
      "You orchestrate the review of " n " pending approvals in the ATS. Their ids: " (string-join ids ", ") ".\n\n"
      "1. Now spawn one subagent per approval with this single eval, then end your turn. You review none yourself.\n"
      "(for-each (lambda (id) (execute* (ats-approval-review-ask id) (list 'title (ats-case-buffer id) 'notify #t))) (list "
      (string-join (map (lambda (id) (string-append q id q)) ids) " ") "))\n"
      "(execute* PROMPT OPTS) starts a subagent chat and returns at once; 'notify #t wakes you when it answers. "
      "(ats-approval-review-ask ID) is that approval's prompt: it points the subagent at the page already open in a buffer.\n\n"
      "2. Each answer wakes you. Until all " n " have answered, end your turn without a reply.\n\n"
      "3. When all have answered, mark every one that answered in one eval: (subagent-verdict! SLUG 'done ONE-LINE). "
      "That stops it and archives its chat with its history. Leave one that is stuck or asks something.\n\n"
      "4. Then reply once: a table of candidate and job, what's proposed, the subagent's call, why in one line, and the link it gave. "
      "After it, list the subagents you left open.")))

(define-command "ats-approvals-review" "Hand the top approvals to one orchestrator chat, which spawns a subagent per approval"
  (lambda ()
    (let* ((buf (current-buffer))
           (rows (let loop ((es (filter (lambda (e) (list-selectable? buf e)) (list-entries buf))) (acc '()))
                   (if (or (null? es) (>= (length acc) 10))
                       (reverse acc)
                       (loop (cdr es) (cons (car es) acc)))))
           ;; each approval's page opens without showing, so its subagent reads the buffer
           (ids (filter (lambda (id) id)
                        (map (lambda (row) (let ((p (site-app-show-detail! buf row #f #t))) (and p (ats-case-id p)))) rows))))
      (if (null? ids)
          (message "no approvals here")
          (let ((orch (subagent-live-buffer
                        (execute* (ats-approvals-review-prompt ids)
                                  (list 'title (string-append "Review: " (number->string (length ids)) " approvals")
                                        'model "claude-sonnet-5-5")))))
            (with-frame-windows (lambda () (display-buffer-other-window! orch))))))))
(catalog-meta! 'command "ats-approvals-review" 'domain 'chat 'effects '(write spend display))
(define-key (mode-keymap "ats-approvals-mode") "M-O" "ats-approvals-review")

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
         ;; the rating as the one star component draws it: filled once met, hollow until then
         (stars (list (site-app-stars-string (f 'rating)) "warn")))
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
;; a candidate's page walks the pipeline: N and P open the next and previous candidate
(when (boundp 'index-declare!)
  (index-declare! "ats-pipeline-mode" 'next "list-next" 'prev "list-prev" 'open "ats-pipeline-open"))

;; c on the jobs list opens the row's candidates; the job page has it as an extra key
(define-key (mode-keymap "ats-jobs-mode") "c" "ats-pipeline")

;; ---------------------------------------------------------------- suggestion cards
;; The job page's Suggestions tab is one card a candidate; these are its keys.

(define (ats-suggestion-at buf)
  (let ((card (site-app-card-at buf)))
    (and card (equal? (plist-get card 'class) "sa-candidate") card)))

(define (ats-application-at buf)
  (let ((card (site-app-card-at buf)))
    (and card (equal? (plist-get card 'class) "sa-application") card)))

(define-command "ats-application-open" "Open the application on this row as its own page beside the list"
  (lambda ()
    (let* ((buf (current-buffer))
           (card (ats-application-at buf))
           (here (buffer-local buf 'site-app-row)))
      (if (not card)
          (message "No application here")
          (site-app-show-detail! (buffer-local buf 'site-app-list)
            (list 'key (plist-get card 'aid)
                  'candidate (or (plist-get card 'name) (site-app-field here 'name))
                  'job (or (plist-get card 'job) (site-app-field here 'name))
                  'href (string-append "/staff/applications/" (plist-get card 'aid)))
            (site-app-page (site-app-spec 'ats) 'applications))))))

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

;; A chat made for an ATS page works the case on it, as svs would
(mode-chat-setup! "ats-detail-mode"
  (lambda (chat src)
    (prompt-part-set! chat "ats-case"
      (string-append
        "This chat works one case in svs's recruiting ATS (svsrecruiting.com). "
        "Its page is a companion buffer (ats-case-text ID reads it); use the ats-ash MCP tools (mcp-find \"ats-ash ...\") only to change it or for what the page lacks; "
        "the page's buttons are the same actions. Show a message to a candidate or client before it goes out."))))

;; what a new chat for an ATS page asks first; the page's own kind wins
;; a case chat says whose case it is: "Approval: Diya Solanki (Backend Engineer @ Cardboard, Inc.)"
(define (ats-case-label src) (ats-row-label (or (buffer-local src 'site-app-row) '()) src))
(define (ats-case-id src) (plist-get (or (buffer-local src 'site-app-row) '()) 'key))
(define (ats-case-buffer id)
  (let ((hit (filter (lambda (b) (equal? (ats-case-id b) id)) (buffer-list))))
    (and (pair? hit) (car hit))))
(define (ats-case-text id)
  (let ((b (ats-case-buffer id))) (and b (buffer-text b))))
(define (ats-approval-buffer id) (ats-case-buffer id))
(define (ats-approval-text id) (ats-case-text id))
(define (ats-case-handle src noun reader)
  (string-append " " noun " id " (or (ats-case-id src) "?") ": its page is already open in the buffer " src
    ", so read it with (" reader " \"" (or (ats-case-id src) "") "\") and do not list or search the lists."))
(define (ats-row-label row fallback)
  (let* ((src fallback)
         (who (or (plist-get row 'candidate) ""))
         (job (or (plist-get row 'job) ""))
         (co (or (plist-get row 'company) "")))
    (cond ((equal? who "") src)
          ((equal? job "") who)
          ((equal? co "") (string-append who " (" job ")"))
          (else (string-append who " (" job " @ " co ")")))))
(mode-chat-title! "ats-detail-mode" ats-case-label)
(mode-chat-title! "ats-approval-mode" (lambda (src) (string-append "Approval: " (ats-case-label src))))
(mode-chat-opening! "ats-detail-mode"
  (lambda (src) (string-append "Brief me on " (ats-case-label src) ": where it stands, what's open, and the next step you'd take." (ats-case-handle src "Page" "ats-case-text"))))
(mode-chat-opening! "ats-approval-mode"
  (lambda (src) (string-append "The approval for " (ats-case-label src) " is waiting on me. What's proposed, would you approve it, and why?" (ats-case-handle src "Approval" "ats-approval-text"))))

