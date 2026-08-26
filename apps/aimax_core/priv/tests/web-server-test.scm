;;; web-server-test.scm --- discovery tests for programmable HTTP servers.

(deftest 'web-server-api-is-discoverable
  "an agent searches for the job before it knows the API name"
  (lambda ()
    (let ((rows (apropos "webhook")))
      (check-true!
        (pair? (filter
                 (lambda (row)
                   (string-contains?
                     (or (plist-get row 'qualified-name) "")
                     "web-server-start!"))
                 rows))
        "apropos finds the programmable inbound server"))))
