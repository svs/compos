(domain! 'testing)
(effects! '(write))

(deftest 'buffer-request-refresh-keeps-the-latest-hidden-request
  "A hidden view reads nothing until refreshed, then uses its latest request."
  (lambda ()
    (let ((buf (buffer-create " *reactive-refresh-hidden*")) (seen '()))
      (unwind-protect
        (lambda ()
          (buffer-request-refresh! buf 'view (lambda () (set! seen (cons 'old seen))))
          (buffer-request-refresh! buf 'view (lambda () (set! seen (cons 'new seen))))
          (check-equal! seen '() "hidden views do no work")
          (buffer-refresh-pending! buf)
          (check-equal! seen '(new) "only the latest request runs")
          (buffer-refresh-pending! buf)
          (check-equal! seen '(new) "the request is consumed once"))
        (lambda () (buffer-kill! buf))))))

(deftest 'buffer-request-refresh-keeps-independent-keys
  "Independent consumers each reload once."
  (lambda ()
    (let ((buf (buffer-create " *reactive-refresh-keys*")) (seen '()))
      (unwind-protect
        (lambda ()
          (buffer-request-refresh! buf 'rows (lambda () (set! seen (cons 'rows seen))))
          (buffer-request-refresh! buf 'header (lambda () (set! seen (cons 'header seen))))
          (buffer-refresh-pending! buf)
          (check-equal! (length seen) 2 "both consumers run")
          (check-true! (member 'rows seen) "rows reload")
          (check-true! (member 'header seen) "header reloads"))
        (lambda () (buffer-kill! buf))))))

(deftest 'buffer-request-refresh-retains-a-request-made-during-refresh
  "A refresh can request another pass without losing it."
  (lambda ()
    (let ((buf (buffer-create " *reactive-refresh-again*")) (seen '()))
      (unwind-protect
        (lambda ()
          (buffer-request-refresh! buf 'view
            (lambda ()
              (set! seen (cons 'first seen))
              (buffer-request-refresh! buf 'view (lambda () (set! seen (cons 'second seen))))))
          (buffer-refresh-pending! buf)
          (check-equal! seen '(first) "one pass does not recurse")
          (buffer-refresh-pending! buf)
          (check-equal! seen '(second first) "the next pass retains the new request"))
        (lambda () (buffer-kill! buf))))))

(deftest 'buffer-request-refresh-ignores-a-killed-view
  "A late notification does not recreate a killed buffer."
  (lambda ()
    (let ((buf (buffer-create " *reactive-refresh-killed*")) (called #f))
      (buffer-kill! buf)
      (buffer-request-refresh! buf 'view (lambda () (set! called #t)))
      (check-equal! called #f "the callback did not run")
      (check-equal! (buffer-exists? buf) #f "the buffer stays killed"))))

(deftest 'buffer-request-refresh-coalesces-visible-work-and-rechecks-visibility
  "A visible burst schedules once; hiding before dispatch defers the reload."
  (lambda ()
    (let ((buf (buffer-create " *reactive-refresh-visible*"))
          (before (current-buffer)) (schedule debounce!) (callback #f) (jobs 0) (seen '()))
      (unwind-protect
        (lambda ()
          (switch-to-buffer! buf)
          (set! debounce! (lambda (key ms fn arg)
                           (check-equal! ms 500 "refreshes use a 500 ms tick")
                           (set! jobs (+ jobs 1))
                           (set! callback (lambda () (fn arg)))))
          (buffer-request-refresh! buf 'view (lambda () (set! seen (cons 'old seen))))
          (buffer-request-refresh! buf 'view (lambda () (set! seen (cons 'new seen))))
          (check-equal! jobs 1 "a burst schedules once without postponing its callback")
          (check-equal! seen '() "source notifications do not render synchronously")
          (switch-to-buffer! before)
          (callback)
          (check-equal! seen '() "dispatch rechecks visibility")
          (switch-to-buffer! buf)
          (buffer-refresh-visible!)
          (check-equal! seen '(new) "show consumes the latest reload once"))
        (lambda ()
          (set! debounce! schedule)
          (switch-to-buffer! before)
          (buffer-kill! buf))))))
