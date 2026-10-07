;;; cron-test.scm --- cron times, the file form, and the core's clock.
(domain! 'testing)
(effects! '(read))

(deftest 'cron-every-becomes-a-cron-time
  "an @every period becomes the cron time that repeats it; the rest stays"
  (lambda ()
    (check-equal! (cron-spec "@every 15m") "*/15 * * * *" "minutes")
    (check-equal! (cron-spec "@every 2h") "0 */2 * * *" "hours")
    (check-equal! (cron-spec "@every 1d") "0 0 * * *" "a day")
    (check-equal! (cron-spec "0 9 * * 1-5") "0 9 * * 1-5" "a cron time")
    (check-equal! (cron-spec "@daily") "@daily" "a nickname")
    (check-false! (ignore-errors (lambda () (cron-spec "@every 7m"))) "7 does not divide an hour")
    (check-false! (ignore-errors (lambda () (cron-spec "@every soon"))) "not a period")))

(deftest 'cron-file-form-reads-back
  "a job is written to cron-file as the cron-define! form that makes it"
  (lambda ()
    (let ((form (cron--form "mail" (list 'spec "@every 15m"
                                           'opts (list 'command "notmuch-refresh" 'zone "UTC")))))
      (check-equal! form "(cron-define! \"mail\" \"@every 15m\" 'command \"notmuch-refresh\" 'zone \"UTC\")" "text")
      (check-equal! (cron--action-opts (list 'command "x" 'save #f 'zone "UTC"))
                    (list 'command "x" 'zone "UTC") "save stays out"))))

(deftest 'cron-next-and-previous-bracket-now
  "the core answers the next due time after now and the last one at or before it"
  (lambda ()
    (let ((now (current-time)))
      (check-true! (> (cron-next "* * * * *" "UTC") now) "next is later")
      (check-true! (<= (cron-previous "* * * * *" "UTC") now) "previous is not")
      (check-true! (<= (- (cron-next "@hourly" "UTC") now) 3600) "within the hour")
      (check-false! (ignore-errors (lambda () (cron-next "61 * * * *" "UTC"))) "a bad time raises"))))
