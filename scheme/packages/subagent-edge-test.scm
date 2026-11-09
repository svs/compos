;;; subagent-edge-test.scm --- the parent/child relation between chats.
;;;
;;; execute* spawns a chat. The edge from the spawning chat to the spawned
;;; one is recorded where group parentage already lives: the group record
;;; of the parent chat, in the record's extension slot. That is why the
;;; edge outlives both buffers.
;;;
;;; The backend is stubbed. These tests are about the edge, not about a
;;; connector: chat-attach-agent! hands the child a slug and dials nothing.

(domain! 'testing)
(effects! '(write))

(define (t--sub-parent! name slug group)
  (let ((buf (test-buffer! name "")))
    (buffer-set-local! buf 'mode-name "chat-mode")
    (buffer-set-local! buf 'agent-slug slug)
    (chat-set-group! buf group)
    buf))

;; execute* with the backend replaced. AUTHOR is the edit author in scope:
;; a slug string spawns as that chat, #f spawns with no parent at all.
;;
;; chat-mode's setup sweeps the runtime locals of a chat whose runtime is
;; gone, and 'agent-slug is one of them. The real chat-attach-agent! leaves
;; a registered session behind, so the sweep spares the slug; a stub that
;; only writes the local would lose it the moment execute* sets the mode.
;; So the stub also answers for its own chats that the runtime is live.
(define (t--sub-spawn author)
  (let ((old-attach chat-attach-agent!)
        (old-live? chat-live-runtime?))
    (set-symbol-value! 'chat-attach-agent!
      (lambda (buf connector &optional model opts)
        (let ((slug (string-append "zz-sub:" buf)))
          (buffer-set-local! buf 'agent-slug slug)
          slug)))
    (set-symbol-value! 'chat-live-runtime?
      (lambda (buf)
        (let ((slug (buffer-local-value 'agent-slug buf)))
          (and (string? slug) (string-prefix? "zz-sub:" slug) #t))))
    (let ((slug (with-edit-author (and author (string-append "agent:" author))
                  (lambda () (execute* "" '())))))
      (set-symbol-value! 'chat-attach-agent! old-attach)
      (set-symbol-value! 'chat-live-runtime? old-live?)
      slug)))

(define (t--sub-buf slug)
  (let ((b (agent-buf slug))) (and b (buffer-exists? b) b)))

(define (t--sub-clean! group &rest bufs)
  (for-each (lambda (b) (when (and b (buffer-known? b)) (buffer-kill! b))) bufs)
  (when (and group (group-record-by-id group)) (group-record-delete! group)))

;;; --- the edge -----------------------------------------------------------------

(deftest 'a-spawn-with-a-parent-in-scope-links-both-ways
  "the spawning chat and the spawned one name each other"
  (lambda ()
    (let* ((group (group-record-create! "zz-sub-both-ways"))
           (parent (t--sub-parent! "*zz-sub-parent-a*" "zz-sub-parent-a" group))
           (child (t--sub-spawn "zz-sub-parent-a"))
           (cbuf (t--sub-buf child)))
      (check-equal! (subagent-parent child) "zz-sub-parent-a"
                    "the child names its parent")
      (check-equal! (subagent-children "zz-sub-parent-a") (list child)
                    "and the parent names the child")
      (check-equal! (subagent-parent cbuf) "zz-sub-parent-a"
                    "a buffer name reads the same as a slug")
      (check-equal! (subagent-children parent) (list child)
                    "and so does the parent's buffer name")
      (check-equal! (group-setting group 'subagents)
                    (list (list "zz-sub-parent-a" "live" child))
                    "the edge is one slot in the parent's group record")
      (check-equal! (buffer-local-value 'subagent-parent cbuf) "zz-sub-parent-a"
                    "the buffer-local cache follows the store")
      (t--sub-clean! group parent cbuf))))

(deftest 'a-spawn-with-no-parent-in-scope-records-nothing
  "it still answers its slug, and founds nothing to hold an edge"
  (lambda ()
    (let* ((before (length (group-ids)))
           (slug (t--sub-spawn #f)))
      (check-true! (string? slug) "the spawn answers a slug")
      (check-false! (subagent-parent slug) "it names no parent")
      (check-equal! (subagent-children slug) '() "and it has no children")
      (check-equal! (length (group-ids)) before
                    "no group record was founded to hold an edge")
      (t--sub-clean! #f (t--sub-buf slug)))))

(deftest 'two-children-of-one-parent-come-back-newest-last
  "the order of the slot is the order of the spawns"
  (lambda ()
    (let* ((group (group-record-create! "zz-sub-two"))
           (parent (t--sub-parent! "*zz-sub-parent-b*" "zz-sub-parent-b" group))
           (first (t--sub-spawn "zz-sub-parent-b"))
           (second (t--sub-spawn "zz-sub-parent-b")))
      (check-false! (equal? first second) "two spawns are two chats")
      (check-equal! (subagent-children "zz-sub-parent-b") (list first second)
                    "the newest child is last")
      (check-equal! (subagent-parent first) "zz-sub-parent-b"
                    "the first names the parent")
      (check-equal! (subagent-parent second) "zz-sub-parent-b"
                    "and so does the second")
      (t--sub-clean! group parent (t--sub-buf first) (t--sub-buf second)))))

;;; --- what a kill leaves -------------------------------------------------------

(deftest 'killing-the-child-leaves-the-edge-readable
  "the store is keyed by the slug, so a dead child is still findable"
  (lambda ()
    (let* ((group (group-record-create! "zz-sub-dead-child"))
           (parent (t--sub-parent! "*zz-sub-parent-c*" "zz-sub-parent-c" group))
           (child (t--sub-spawn "zz-sub-parent-c"))
           (cbuf (t--sub-buf child)))
      (buffer-kill! cbuf)
      (check-false! (buffer-known? cbuf) "the child buffer is gone")
      (check-equal! (subagent-parent child) "zz-sub-parent-c"
                    "the killed child still names its parent")
      (check-equal! (subagent-children "zz-sub-parent-c") (list child)
                    "and the parent still names it")
      (t--sub-clean! group parent))))

(deftest 'killing-the-parent-leaves-the-child-running-and-answering
  "a kill orphans nobody: the child lives on and the slot says the parent is gone"
  (lambda ()
    (let* ((group (group-record-create! "zz-sub-dead-parent"))
           (parent (t--sub-parent! "*zz-sub-parent-d*" "zz-sub-parent-d" group))
           (child (t--sub-spawn "zz-sub-parent-d"))
           (cbuf (t--sub-buf child)))
      (buffer-kill! parent)
      (check-false! (buffer-known? parent) "the parent chat is gone")
      (check-true! (buffer-known? cbuf) "the child was not killed with it")
      (check-equal! (subagent-parent child) "zz-sub-parent-d"
                    "and the child still names the parent that spawned it")
      (check-true! (subagent-gone? "zz-sub-parent-d")
                   "the parent's slot records that the parent is gone")
      (check-equal! (subagent-children "zz-sub-parent-d") (list child)
                    "the children are still listed")
      (t--sub-clean! group cbuf))))

;;; --- one source of truth ------------------------------------------------------

(deftest 'the-subagent-buffer-locals-are-only-a-cache
  "clearing them changes no answer, and a rebuild puts them back"
  (lambda ()
    (let* ((group (group-record-create! "zz-sub-cache"))
           (parent (t--sub-parent! "*zz-sub-parent-e*" "zz-sub-parent-e" group))
           (child (t--sub-spawn "zz-sub-parent-e"))
           (cbuf (t--sub-buf child)))
      (buffer-set-local! cbuf 'subagent-parent #f)
      (buffer-set-local! parent 'subagent-children '())
      (check-equal! (subagent-parent child) "zz-sub-parent-e"
                    "the store answers with no cache at all")
      (check-equal! (subagent-children parent) (list child)
                    "and so does the other direction")
      (subagent-cache-rebuild! cbuf)
      (subagent-cache-rebuild! parent)
      (check-equal! (buffer-local-value 'subagent-parent cbuf) "zz-sub-parent-e"
                    "the rebuild puts the child's cache back")
      (check-equal! (buffer-local-value 'subagent-children parent) (list child)
                    "and the parent's")
      (t--sub-clean! group parent cbuf))))
