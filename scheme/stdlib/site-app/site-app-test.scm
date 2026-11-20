;;; site-app-test.scm --- the index a tabbed page gives imenu.

(domain! 'testing)
(effects! '(write))

(require 'site-app)

(define *t-site-app-buf* "*zz-site-app*")

;; a page with two tabs, the first one open, with two parts drawn
(define (t--site-app-page thunk)
  (buffer-create *t-site-app-buf*)
  (buffer-set-text! *t-site-app-buf* "Head\nTabs\nSkills\nbody\nNotes\nbody\n")
  (buffer-set-local! *t-site-app-buf* 'site-app
    (list 'name "zz-site-app"
          'active "candidate"
          'data (list 'tabs (list (list 'id "candidate" 'label "candidate")
                                  (list 'id "job" 'label "job"))
                      'section '())
          ;; the page keeps the section of the tab that is not open
          'sections (list (cons "job" (list (list 'tag "c-heading" 'text "Pay")
                                            (list 'tag "c-field" 'text "A number"))))
          'index-head '()
          'index-body (list (list 'imenu-name "Skills" 'lines (list 3 4))
                            (list 'imenu-name "Notes" 'lines (list 5 6)))
          'tab-line 2))
  (let ((out (thunk)))
    (buffer-kill! *t-site-app-buf*)
    out))

(deftest 'a-tabbed-page-lists-the-parts-of-the-open-tab-only
  "imenu gives one entry for each tab, and parts for the open tab only"
  (lambda ()
    (t--site-app-page
      (lambda ()
        (check-equal! (map (lambda (r) (list (car r) (cadr r) (caddr r)))
                           (site-app-imenu-rows *t-site-app-buf*))
                      '((2 "tab" "Candidate") (3 "part" "   Skills") (5 "part" "   Notes") (2 "tab" "Job"))
                      "the tab that is not open has no parts")))))
