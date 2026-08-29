;;; canary-test.scm --- one test that must always fail.
;;;
;;; A suite that cannot go red is worse than no suite. test-self-check
;;; proves the check functions record, but it calls them directly: it
;;; never loads a file, never registers a test, and never goes through
;;; run-test. A file that fails to load takes its tests with it silently,
;;; and the bridge sees a shorter green run.
;;;
;;; So one test here fails on purpose, every time. The bridge asserts
;;; that it loaded, that it ran, and that it reported a failure — and it
;;; excludes this name from the pass/fail tally. If this test ever goes
;;; green, the reporting path is broken and nothing below it can be
;;; believed.

(domain! 'testing)
(effects! '(read))

(deftest 'zz-canary-always-fails
  "must fail: proves a registered test can load, run, and report red"
  (lambda ()
    (check-equal! "canary" "the canary must report this failure"
                  "canary")))
