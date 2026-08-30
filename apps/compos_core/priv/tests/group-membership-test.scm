;;; group-membership-test.scm --- membership survives a transient record loss.
;;;
;;; A buffer's group locals are the membership storage. The record table
;;; can be transiently wrong: a reload window, a stale lane view, a
;;; restore in progress. A read during such a moment used to clear the
;;; local, which turned every transient falsehood into a permanent loss.
;;; These tests take the table away, read, put it back, and expect the
;;; membership to still be there.

(domain! 'testing)
(effects! '(write))

(define (t--gm-with-empty-records thunk)
  (let ((saved *group-records*))
    (set! *group-records* '())
    (let ((out (thunk)))
      (set! *group-records* saved)
      out)))

(deftest 'a-work-buffer-keeps-its-group-through-a-record-outage
  "reads during the outage answer nothing; after it, the group is back"
  (lambda ()
    (let ((stale (group-resolve-id "gm-outage-group")))
      (when stale (group-record-delete! stale)))
    (let ((id (group-record-create! "gm-outage-group"))
          (buf "*gm-work*"))
      (test-buffer! buf "work")
      (buffer-add-group! buf id)
      (check-equal! (buffer-group buf) id "the buffer is in the group")
      (t--gm-with-empty-records
        (lambda ()
          (check-equal! (buffer-group buf) #f
                        "during the outage the read answers no group")))
      (check-equal! (buffer-group buf) id
                    "after the outage the membership is intact")
      (buffer-kill! buf)
      (group-record-delete! id))))

(deftest 'a-chat-keeps-its-group-through-a-record-outage
  "the chat's one group survives a read while the table is away"
  (lambda ()
    (let ((stale (group-resolve-id "gm-chat-group")))
      (when stale (group-record-delete! stale)))
    (let ((id (group-record-create! "gm-chat-group"))
          (buf "*chat:gm-outage*"))
      (test-buffer! buf "")
      (buffer-set-local! buf 'mode-name "chat-mode")
      (buffer-set-local! buf 'group-id id)
      (check-equal! (buffer-group buf) id "the chat names its group")
      (t--gm-with-empty-records
        (lambda ()
          (check-equal! (buffer-group buf) #f
                        "during the outage the read answers no group")))
      (check-equal! (buffer-group buf) id
                    "after the outage the chat still names its group")
      (buffer-kill! buf)
      (group-record-delete! id))))

(deftest 'dissolve-still-clears-its-members
  "the explicit sweep is the one place membership ends"
  (lambda ()
    (let ((stale (group-resolve-id "gm-dissolve-group")))
      (when stale (group-record-delete! stale)))
    (let ((id (group-record-create! "gm-dissolve-group"))
          (buf "*gm-dissolve*"))
      (test-buffer! buf "work")
      (buffer-add-group! buf id)
      (group-dissolve! id)
      (check-equal! (buffer-group buf) #f "dissolve removed the membership")
      (check-equal! (group-resolve-id "gm-dissolve-group") #f "and the record")
      (buffer-kill! buf))))
