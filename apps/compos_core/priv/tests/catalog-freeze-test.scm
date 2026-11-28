;;; catalog-freeze-test.scm --- the catalog read in place once frozen.

(domain! 'system)
(effects! '(write))

(deftest 'a-frozen-catalog-still-answers-every-reader
  "freezing empties *catalog* and every reader still sees every entry"
  (lambda ()
    (let ((before (length (catalog))))
      (check-true! (> before 0) "the boot catalog has entries")
      (catalog-freeze!)
      (check-equal! *catalog* '() "the environment table no longer holds the catalog")
      (check-equal! (length (catalog)) before "catalog lists every entry")
      (check-true! (pair? (catalog-entry 'function "catalog-entry")) "catalog-entry finds by name")
      (when (boundp 'eval-read--effects)
        (check-true! (pair? (eval-read--effects '("buffer-text")))
                     "eval-scheme-read finds the effects of what it runs")))))

(deftest 'a-write-to-a-frozen-catalog-thaws-it-first
  "register, meta and forget work on a frozen catalog and lose nothing"
  (lambda ()
    (catalog-freeze!)
    (let ((before (length (catalog))))
      (catalog-register! 'function "zz-frozen-probe" "a probe" 'domain 'system 'effects '(pure))
      (check-equal! (length (catalog)) (+ before 1) "the new entry joins the old ones")
      (check-true! (pair? (catalog-entry 'function "catalog-entry")) "the old entries are still there")
      (catalog-freeze!)
      (catalog-meta! 'function "zz-frozen-probe" 'effects '(read))
      (check-equal! (plist-get (catalog-entry 'function "zz-frozen-probe") 'effects) '("read")
                    "meta updates a frozen entry")
      (catalog-freeze!)
      (catalog-forget! 'function "zz-frozen-probe")
      (check-false! (catalog-entry 'function "zz-frozen-probe") "forget removes it")
      (check-equal! (length (catalog)) before "and only it"))))
