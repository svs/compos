;;; subagents-test.scm --- the *subagents* table: one row per spawn edge.
;;;
;;; The edges are written straight into a test group's record, the way
;;; agent-session.scm writes them, so no test spawns a real agent. No test
;;; names a key: RET is the command the mode binds to it.

(domain! 'testing)
(effects! '(write))



(define (zz-sub-scene thunk)
  (with-frame
    (lambda (frame)
      (with-fresh-group "zz-subagents-test"
        (lambda (gid)
          (unwind-protect
            (lambda ()
              (zz-sub-clear!)
              (thunk gid))
            zz-sub-clear!))))))

(define (zz-sub-chat! name slug text)
  (test-buffer! name text)
  (buffer-set-local! name 'agent-slug slug)
  (buffer-set-local! name 'mode-name "chat-mode")
  name)

(define (zz-sub-clear!)
  ;; the list arms the ibuffer transient frame; give it back before the list dies
  (transient-frame-exit! 'ibuffer)
  (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
            '("zz-sub-parent" "zz-sub-kid-a" "zz-sub-kid-b" "*subagents*" "zz-sub-plan"
            "*subagent-log:zz-sub-kid-a-slug*" "*subagent-log:zz-sub-kid-b-slug*"))
  (delete-other-windows!))

;; one parent, two children, in that spawn order. PARENT? makes the
;; parent's own chat buffer; a killed parent has none.
(define (zz-sub-setup! gid state parent?)
  (group-setting-set! gid 'subagents
    (list (list "zz-sub-parent-slug" state
                "zz-sub-kid-a-slug" "zz-sub-kid-b-slug")))
  (when parent?
    (zz-sub-chat! "zz-sub-parent" "zz-sub-parent-slug" "parent says nothing"))
  (zz-sub-chat! "zz-sub-kid-a" "zz-sub-kid-a-slug"
                "first line\nthe last line a reads\n\n")
  (zz-sub-chat! "zz-sub-kid-b" "zz-sub-kid-b-slug" "b said this\n")
  (subagents-index-rebuild!))

(define (zz-sub-edges)
  (filter (lambda (e) (string-prefix? "zz-sub-" (car e))) (subagents-edges)))

(deftest 'subagents-reads-one-edge-per-child-from-the-relation
  "an edge names the child, its parent, and the state of the parent slot"
  (lambda ()
    (zz-sub-scene
      (lambda (gid)
        (zz-sub-setup! gid "live" #t)
        (check-equal! (zz-sub-edges)
                      '(("zz-sub-kid-a-slug" "zz-sub-parent-slug" "live")
                        ("zz-sub-kid-b-slug" "zz-sub-parent-slug" "live"))
                      "both children, in spawn order, with their parent")
        (check-equal! (subagents-parent-of "zz-sub-kid-b-slug") "zz-sub-parent-slug"
                      "the child names its parent")
        (check-equal! (subagents-parent-label "zz-sub-kid-a-slug") "zz-sub-parent"
                      "a live parent wears its chat name and nothing else")))))

(deftest 'subagents-lists-the-children-of-a-killed-parent
  "subagent-gone? is why: the rows come from the relation, not the buffers"
  (lambda ()
    (zz-sub-scene
      (lambda (gid)
        (zz-sub-setup! gid "gone" #f)
        (check-true! (subagent-gone? "zz-sub-parent-slug")
                     "the store says the parent is gone")
        (check-equal! (map car (zz-sub-edges))
                      '("zz-sub-kid-a-slug" "zz-sub-kid-b-slug")
                      "a killed parent still lists both children")
        (check-true! (subagents-parent-lost? "zz-sub-kid-a-slug") "the row knows")
        (check-equal! (subagents-parent-label "zz-sub-kid-a-slug")
                      "zz-sub-parent-slug (killed)"
                      "and says so beside the parent")))))

(deftest 'subagents-says-the-last-line-the-child-said
  "the last line of the child's buffer that says anything, clipped"
  (lambda ()
    (zz-sub-scene
      (lambda (gid)
        (zz-sub-setup! gid "live" #t)
        (check-equal! (subagents-last-line "zz-sub-kid-a-slug")
                      "the last line a reads"
                      "trailing blank lines say nothing")
        (check-equal! (subagents-last-line "zz-sub-kid-b-slug") "b said this"
                      "one line is the last line")
        (buffer-kill! "zz-sub-kid-b")
        (subagents-index-rebuild!)
        (check-equal! (subagents-last-line "zz-sub-kid-b-slug") ""
                      "a child whose buffer is gone says nothing")
        (let ((long (string-join (map (lambda (i) "word") '(1 2 3 4 5 6 7 8 9 10
                                                             11 12 13 14 15 16 17
                                                             18 19 20 21 22 23 24))
                                 " ")))
          (zz-sub-chat! "zz-sub-kid-a" "zz-sub-kid-a-slug" long)
          (subagents-index-rebuild!)
          (check-true! (< (string-length (subagents-last-line "zz-sub-kid-a-slug"))
                          (string-length long))
                       "a long line is clipped"))))))

(deftest 'subagents-table-draws-one-row-per-edge
  "the table is the ibuffer template: the edge, the state, the last line"
  (lambda ()
    (zz-sub-scene
      (lambda (gid)
        (zz-sub-setup! gid "live" #t)
        (run-command "subagents")
        (check-equal! (filter (lambda (e) (string-prefix? "zz-sub-" e))
                              (list-entries "*subagents*"))
                      '("zz-sub-kid-a-slug" "zz-sub-kid-b-slug")
                      "one row per edge, in spawn order")
        (check-equal! (ibuffer-row-kind "zz-sub-kid-a-slug") 'subagent
                      "the row is a spawn edge, not a buffer")
        (check-equal! (ibuffer-row-title "zz-sub-kid-a-slug")
                      "zz-sub-parent > zz-sub-kid-a"
                      "the name column is the edge: parent, then child")
        (check-equal! (ibuffer-row-label "zz-sub-kid-a-slug") "idle"
                      "the state column is the child's runtime state")
        (check-equal! (ibuffer-row-last "zz-sub-kid-a-slug")
                      "the last line a reads"
                      "the last column is the child's last line")
        (check-true! (string-contains? (buffer-text "*subagents*") "kid-a")
                     (string-append "and the table draws the row: " (buffer-text "*subagents*")))))))

(deftest 'subagents-a-row-is-never-another-table-s-row
  "the kind claims a slug the relation names, and nothing else"
  (lambda ()
    (zz-sub-scene
      (lambda (gid)
        (zz-sub-setup! gid "live" #t)
        (check-true! (subagents-row? "zz-sub-kid-a-slug") "a child slug is a row")
        (check-true! (not (subagents-row? "zz-sub-kid-a"))
                     "the child's buffer is not")
        (check-true! (not (subagents-row? "*scratch*")) "nor any other buffer")))))

(deftest 'subagents-ret-shows-the-child-in-the-other-window
  "RET displays the chat and leaves the point in the table"
  (lambda ()
    (zz-sub-scene
      (lambda (gid)
        (zz-sub-setup! gid "live" #t)
        (run-command "subagents")
        (list-goto-index! "*subagents*" 0)
        (check-equal! (list-current "*subagents*") "zz-sub-kid-a-slug"
                      "the point is on the first edge")
        (run-command "subagents-visit")
        (check-true! (window-showing "zz-sub-kid-a")
                     "the child shows in a window")
        (check-equal! (window-buffer (active-window)) "*subagents*"
                      "and the table keeps the focus")))))

(deftest 'subagents-ret-prefers-the-chat-mode-window
  "RET shows the child in the window that prefers chat-mode, never the table's"
  (lambda ()
    (zz-sub-scene
      (lambda (gid)
        (zz-sub-setup! gid "live" #t)
        (run-command "subagents")
        (split-window! 'h 0.5)
        (let ((chat-win (get-other-window)))
          (window-set-buffer! chat-win "zz-sub-parent")
          (list-goto-index! "*subagents*" 0)
          (run-command "subagents-visit")
          (check-equal! (window-showing "zz-sub-kid-a") chat-win
                        "the child takes the chat-mode window")
          (check-equal! (window-buffer (active-window)) "*subagents*"
                        "and the table keeps the focus"))))))

(deftest 'subagents-log-outlives-the-child-buffer
  "the edge log is in the group record, so a killed child keeps its verdict"
  (lambda ()
    (zz-sub-scene
      (lambda (gid)
        (zz-sub-setup! gid "live" #t)
        (subagent-verdict! "zz-sub-kid-a-slug" 'done "finished A")
        (buffer-kill! "zz-sub-kid-a")
        (subagents-index-rebuild!)
        (check-equal! (map cadr (subagent-log "zz-sub-kid-a-slug")) '(verdict)
                      "the verdict is logged on the edge")
        (check-equal! (subagent-verdict-of "zz-sub-kid-a-slug") '("done" "finished A")
                      "and it still reads as done")
        (check-equal! (subagent-status-of "zz-sub-kid-a-slug") 'gone
                      "with the buffer gone, the status says so")))))

(deftest 'subagents-verdict-done-writes-the-plan-line
  "a done verdict with 'todo writes the result under the heading and sets DONE"
  (lambda ()
    (zz-sub-scene
      (lambda (gid)
        (zz-sub-setup! gid "live" #t)
        (test-buffer! "zz-sub-plan" "# Plan\n\n## Task A\n\nbody\n")
        (with-current-buffer "zz-sub-plan" (lambda () (run-command "morg-mode")))
        (check-equal! (subagent-verdict! "zz-sub-kid-a-slug" 'done "finished A"
                                         (list 'todo (list "zz-sub-plan" "Task A")))
                      'done "the status after a done verdict")
        (check-true! (string-contains? (buffer-text "zz-sub-plan")
                                       "Result: finished A [zz-sub-kid-a-slug]")
                     "the result line is written")
        (check-true! (string-contains? (buffer-text "zz-sub-plan") "## DONE Task A")
                     (string-append "and the heading is DONE: " (buffer-text "zz-sub-plan")))))))

(deftest 'subagents-verdict-wait-asks-the-parent-for-a-turn
  "wait is a state the parent reads, and the log keeps the question"
  (lambda ()
    (zz-sub-scene
      (lambda (gid)
        (zz-sub-setup! gid "live" #t)
        (check-equal! (subagent-verdict! "zz-sub-kid-b-slug" 'wait "which one?") 'wait
                      "the status is wait")
        (run-command "subagents")
        (check-equal! (ibuffer-row-label "zz-sub-kid-b-slug") "your turn"
                      "the state column asks for the parent's turn")
        (check-equal! (subagents-last-line "zz-sub-kid-b-slug") "wait: which one?"
                      "the last column is the latest log entry")))))

(deftest 'subagents-verdict-refuses-what-it-cannot-do
  "a bad verdict, a missing message, or a missing heading logs nothing"
  (lambda ()
    (zz-sub-scene
      (lambda (gid)
        (zz-sub-setup! gid "live" #t)
        (test-buffer! "zz-sub-plan" "## Task A\n")
        (check-true! (not (ignore-errors (lambda () (subagent-verdict! "zz-sub-kid-a-slug" 'maybe "x"))))
                     "VERDICT is checked")
        (check-true! (not (ignore-errors (lambda () (subagent-verdict! "zz-sub-kid-a-slug" 'again "x"))))
                     "again needs a message")
        (check-true! (not (ignore-errors (lambda ()
                             (subagent-verdict! "zz-sub-kid-a-slug" 'done "x"
                                                (list 'todo (list "zz-sub-plan" "Task Z"))))))
                     "a heading that is not there is an error")
        (check-equal! (subagent-log "zz-sub-kid-a-slug") '() "and none of them was logged")))))

(deftest 'subagents-show-log-shows-one-child
  "the log command shows the chosen child's entries in a plain buffer"
  (lambda ()
    (zz-sub-scene
      (lambda (gid)
        (zz-sub-setup! gid "live" #t)
        (subagent-verdict! "zz-sub-kid-b-slug" 'wait "which one?")
        (run-command "subagents")
        (list-goto-index! "*subagents*" 1)
        (run-command "subagents-show-log")
        (check-true! (string-contains? (buffer-text "*subagent-log:zz-sub-kid-b-slug*") "which one?")
                     "the entry is in the log buffer")))))
