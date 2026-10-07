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
        'detail-mode mode
        'columns columns))

(define *ats-candidates-page*
  (list 'id 'candidates
        'label "Candidates"
        'key "2"
        'path "/staff/candidates"
        'sheet (ats-sheet "candidates.xsl")
        'detail-sheet (ats-sheet "candidate-detail.xsl")
        ;; the candidate's tabs, each one read from its ?tab= URL
        'detail-tab-param "tab"
        'detail-mode "ats-candidate-mode"
        'detail-tabs (map (lambda (id) (list 'id id))
                          '("profile" "suggested" "comms" "meetings" "notes"))
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
        'detail-mode "ats-application-mode"
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
        'detail-wait "#approvals-show-root"
        'detail-tab-param "tab"
        'detail-mode "ats-approval-mode"
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
        (list (list 'label "★" 'width 5 'field 'rating 'face "dim")
              (list 'label "candidate" 'width 22 'field 'candidate)
              (list 'label "proposal" 'width 20 'field 'proposal)
              (list 'label "fit" 'width 11 'field 'fit 'face "dim")
              (list 'label "company" 'width 16 'field 'company 'face "dim")
              (list 'label "job" 'width #f 'field 'job))))

(define *ats-spec*
  (list 'name 'ats
        'title "ATS"
        'base-url "https://svsrecruiting.com"
        'home "/staff/approvals"
        'home-page 'approvals
        ;; the status, stage or scope tabs a section's page draws above its rows
        'tabs-sheet (ats-sheet "tabs.xsl")
        ;; an application is who for what; anything else goes by its name
        'detail-name (lambda (row)
                       (if (equal? (site-app-field row 'candidate) "")
                           (site-app-field row 'name)
                           (string-append (site-app-field row 'candidate) " · " (site-app-field row 'job))))
        ;; words the site colours, wherever they appear on a page
        'tones '(("^(?i)(unfit|withdrawn|withdraw|reject|rejected|declined|dropped)$" bad)
                 ("^(?i)(potential|pending|snoozed|scheduled|maybe)$" warn)
                 ("^(?i)(elite|strong|fit|advance|advanced|approved|hired|shortlisted|offer)$" good)
                 ("^(?i)(new|applied|create|created)$" info))
        ;; the site's navbar, in its order; M-key switches to a section
        'pages
        (list
          *ats-approvals-page*
          *ats-candidates-page*
          *ats-applications-page*
          (ats-section 'companies "Companies" "4" "/staff/companies" "ats-company-mode"
            (list (list 'label "company" 'width 24 'field 'name)
                  (list 'label "state" 'width 12 'field 'state)
                  (list 'label "jobs" 'width 10 'field 'active 'face "dim")
                  (list 'label "website" 'width #f 'field 'website 'face "dim")))
          (ats-section 'jobs "Jobs" "5" "/staff/jobs" "ats-job-mode"
            (list (list 'label "job" 'width 30 'field 'name)
                  (list 'label "company" 'width 16 'field 'company)
                  (list 'label "new" 'width 4 'field 'new 'face "dim")
                  (list 'label "rec" 'width 4 'field 'recommended 'face "dim")
                  (list 'label "acc" 'width 4 'field 'accepted 'face "dim")
                  (list 'label "app" 'width 4 'field 'applied 'face "dim")
                  (list 'label "posted" 'width #f 'field 'posted 'face "dim")))
          (ats-section 'comms "Comms" "6" "/staff/comms" "ats-message-mode"
            (list (list 'label "from" 'width 26 'field 'name)
                  (list 'label "when" 'width 8 'field 'when 'face "dim")
                  (list 'label "via" 'width 9 'field 'channel 'face "dim")
                  (list 'label "subject" 'width #f 'field 'subject))))))

(define-site-app *ats-spec*)

(domain! 'web)
(effects! '(write external display))

;;;###autoload
(define-command "ats" "Open SVS recruiting as a live website app"
  (lambda () (site-app-open! 'ats)))
