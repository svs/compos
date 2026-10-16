;;; group-cycle-test.scm --- one key walks a group's buffers, most recently
;;; used first, and flips between the last two the way Alt-Tab flips between
;;; two windows. A window walks its preferred mode automatically.
;;; The walk never leaves the group and never leaves the window.
;;;
;;; No test presses a key. The commands drive the walk, and no test names a
;;; binding: a binding is a preference.

(domain! 'testing)
(effects! '(write))

(define *group-cycle-test-bufs*
  (list "*zz-cyc-one*" "*zz-cyc-two*" "*zz-cyc-three*" "*zz-cyc-hidden*"
        "*zz-cyc-other*" "*zz-cyc-work-a*" "*zz-cyc-work-b*" "*zz-cyc-work-there*"
        "*zz-cyc-mate*"))

(define (group-cycle-test-reset!)
  (window-mode-preference! (active-window) #f)
  (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
            *group-cycle-test-bufs*)
  (for-each (lambda (name)
              (when (group-record-by-name name) (group-record-delete! name)))
            (list "zz-cyc-here" "zz-cyc-there")))

(define (group-cycle-test-chat! name group-id)
  (test-buffer! name "")
  (buffer-set-local! name 'mode-name "chat-mode")
  (buffer-set-local! name 'group-id group-id)
  name)

(define (group-cycle-test-work! name group-id mode)
  (test-buffer! name "")
  (when mode (buffer-set-local! name 'mode-name mode))
  (group-add-buffers-to! (list name) group-id)
  name)

;; one group of three chats and two work buffers, another holding one of
;; each, touched oldest first, so the walk starts on three
(define (group-cycle-test-open!)
  (group-cycle-test-reset!)
  (let ((here (group-record-create! "zz-cyc-here"))
        (there (group-record-create! "zz-cyc-there")))
    (group-cycle-test-chat! "*zz-cyc-one*" here)
    (group-cycle-test-chat! "*zz-cyc-two*" here)
    (group-cycle-test-chat! "*zz-cyc-three*" here)
    (group-cycle-test-chat! "*zz-cyc-other*" there)
    (group-cycle-test-work! "*zz-cyc-work-a*" here "text-mode")
    (group-cycle-test-work! "*zz-cyc-work-b*" here #f)
    (group-cycle-test-work! "*zz-cyc-work-there*" there #f)
    (switch-to-buffer! "*zz-cyc-other*")
    (switch-to-buffer! "*zz-cyc-work-there*")
    (switch-to-buffer! "*zz-cyc-work-b*")
    (switch-to-buffer! "*zz-cyc-work-a*")
    (switch-to-buffer! "*zz-cyc-one*")
    (switch-to-buffer! "*zz-cyc-two*")
    (switch-to-buffer! "*zz-cyc-three*")
    (list here there)))

(define (group-cycle-test-mine)
  (filter (lambda (b) (string-prefix? "*zz-cyc-" b)) (group-cycle-ring)))

;; A chat and a work buffer in ONE group, both verified to be in it: the
;; walk's whole point is that it crosses the kinds, so the scene has to
;; prove the two are group-mates before it asks the ring about them.
(define (group-cycle-pair!)
  (let ((gid (buffer-group "*zz-cyc-three*")))
    (test-buffer! "*zz-cyc-mate*" "")
    (buffer-add-group! "*zz-cyc-mate*" gid)
    (check-true! (buffer-in-group? "*zz-cyc-mate*" gid) "the work buffer joined the chat's group")
    (check-true! (buffer-in-group? "*zz-cyc-one*" gid) "and the other chat is in it")
    gid))

(deftest 'group-cycle-walks-every-buffer-of-the-group
  "the walk is the escape hatch: a chat and a work buffer are on the same ring"
  (lambda ()
    (group-cycle-test-open!)
    (group-cycle-pair!)
    (switch-to-buffer! "*zz-cyc-three*")
    (check-equal! (car (group-cycle-ring)) "*zz-cyc-three*"
                  "the buffer you stand in leads the ring")
    (check-true! (and (member "*zz-cyc-mate*" (group-cycle-ring)) #t)
                 "a work buffer is on a chat pane's ring")
    (check-true! (and (member "*zz-cyc-one*" (group-cycle-ring)) #t)
                 "and so is the group's other chat")
    (when (buffer-known? "*zz-cyc-mate*") (buffer-kill! "*zz-cyc-mate*"))
    (group-cycle-test-reset!)))

(deftest 'group-mode-cycle-walks-only-this-mode
  "the mode walk keeps this buffer's mode in this group and drops the rest"
  (lambda ()
    (group-cycle-test-open!)
    (group-cycle-pair!)
    (switch-to-buffer! "*zz-cyc-three*")
    (let ((ring (group-cycle-ring #t)))
      (check-equal! (car ring) "*zz-cyc-three*" "the buffer you stand in leads")
      (check-true! (and (member "*zz-cyc-one*" ring) #t) "a chat of the group is on it")
      (check-false! (member "*zz-cyc-mate*" ring) "a buffer of another mode is not")
      (check-false! (member "*zz-cyc-work-a*" ring) "nor a text-mode buffer")
      (check-false! (member "*zz-cyc-other*" ring) "nor a chat of another group"))
    (group-cycle! 1 #t)
    (check-true! (buffer-derived-mode? (current-buffer) "chat-mode")
                 "one step lands on another chat")
    (when (buffer-known? "*zz-cyc-mate*") (buffer-kill! "*zz-cyc-mate*"))
    (group-cycle-test-reset!)))

(deftest 'group-cycle-keeps-a-dormant-buffer-and-drops-an-agent-context-buffer
  "a sleeping buffer of the group is on the ring; a buffer only an agent opened is not"
  (lambda ()
    (group-cycle-test-open!)
    (group-cycle-pair!)
    (switch-to-buffer! "*zz-cyc-three*")
    (check-true! (buffer-sleep! "*zz-cyc-mate*") "the work buffer sleeps")
    (check-true! (and (member "*zz-cyc-mate*" (group-cycle-ring)) #t)
                 "the sleeping buffer is still on the ring")
    (buffer-context-only! "*zz-cyc-one*")
    (check-false! (member "*zz-cyc-one*" (group-cycle-ring))
                  "an agent's context buffer is not on the ring")
    (when (buffer-known? "*zz-cyc-mate*") (buffer-kill! "*zz-cyc-mate*"))
    (group-cycle-test-reset!)))

(deftest 'group-cycle-walks-the-same-ring-from-a-work-window
  "the ring does not change with the kind of pane you stand in; only its head does"
  (lambda ()
    (group-cycle-test-open!)
    (group-cycle-pair!)
    (switch-to-buffer! "*zz-cyc-mate*")
    (check-equal! (car (group-cycle-ring)) "*zz-cyc-mate*" "the work buffer leads now")
    (check-true! (and (member "*zz-cyc-three*" (group-cycle-ring)) #t)
                 "a chat is reachable from a work pane")
    (when (buffer-known? "*zz-cyc-mate*") (buffer-kill! "*zz-cyc-mate*"))
    (group-cycle-test-reset!)))

(deftest 'a-pane-mode-preference-does-not-narrow-the-walk
  "the pane's preferred mode steers routing, never the walk"
  (lambda ()
    (group-cycle-test-open!)
    (group-cycle-pair!)
    (switch-to-buffer! "*zz-cyc-mate*")
    (window-mode-preference! (active-window) "text-mode")
    (check-equal! (window-preferred-mode (active-window)) "text-mode" "the pane names it")
    (check-true! (and (member "*zz-cyc-three*" (group-cycle-ring)) #t)
                 "the chat is still on the ring")
    (window-mode-preference! (active-window) #f)
    (check-true! (and (member "*zz-cyc-three*" (group-cycle-ring)) #t)
                 "and still there when the override goes")
    (when (buffer-known? "*zz-cyc-mate*") (buffer-kill! "*zz-cyc-mate*"))
    (group-cycle-test-reset!)))

(deftest 'group-cycle-never-leaves-the-group
  "another group's buffers are not in the ring, however recently used"
  (lambda ()
    (group-cycle-test-open!)
    (check-false! (member "*zz-cyc-other*" (group-cycle-ring))
                  "the chat of the other group stays out")
    (switch-to-buffer! "*zz-cyc-work-a*")
    (check-false! (member "*zz-cyc-work-there*" (group-cycle-ring))
                  "and so does its work buffer")
    (switch-to-buffer! "*zz-cyc-other*")
    ;; the ring there is that group's own buffers, and no way across
    (check-false! (member "*zz-cyc-three*" (group-cycle-ring))
                  "the first group's chat is not reachable from here")
    (check-false! (member "*zz-cyc-one*" (group-cycle-ring))
                  "nor its other chat")
    (group-cycle-test-reset!)))

(deftest 'group-cycle-flips-between-the-last-two
  "one step lands on the buffer you came from; a fresh walk brings you back"
  (lambda ()
    (group-cycle-test-open!)
    (group-cycle! 1)
    (check-equal! (current-buffer) "*zz-cyc-two*" "the most recently used other chat")
    (group-cycle! 1)
    (check-equal! (current-buffer) "*zz-cyc-three*" "and back, the way Alt-Tab flips")
    (group-cycle-test-reset!)))

(deftest 'group-cycle-repeat-goes-one-deeper
  "pressing again without another command between walks past the last buffer"
  (lambda ()
    (group-cycle-test-open!)
    (group-cycle! 1)
    (check-equal! (current-buffer) "*zz-cyc-two*" "one deep")
    ;; the editor marks a repeat by last-command, which only a key press
    ;; sets; the walk's own state is what the repeat reads
    (set! *group-cycle-pos* (modulo (+ *group-cycle-pos* 1) (length *group-cycle-ring*)))
    (switch-to-buffer! (list-ref *group-cycle-ring* *group-cycle-pos*))
    (check-equal! (current-buffer) "*zz-cyc-one*" "two deep, down the same ring")
    (group-cycle-test-reset!)))

(deftest 'group-cycle-same-mode-stays-in-its-window
  "cycling text buffers preserves the selected window and its neighbor"
  (lambda ()
    (group-cycle-test-open!)
    (buffer-set-local! "*zz-cyc-work-b*" 'mode-name "text-mode")
    (tile-windows! 'two-pane '("*zz-cyc-work-a*" "*zz-cyc-three*"))
    (select-window! (window-showing "*zz-cyc-work-a*"))
    (let ((win (active-window)) (neighbor (window-showing "*zz-cyc-three*")))
      (run-command "group-next-buffer")
      (check-equal! (current-buffer) "*zz-cyc-work-b*" "the other text buffer opens")
      (check-equal! (active-window) win "cycling stays in this window")
      (check-equal! (window-buffer neighbor) "*zz-cyc-three*" "the neighbor stays")
      (run-command "group-next-buffer")
      (check-equal! (current-buffer) "*zz-cyc-work-a*" "cycling returns to the first buffer"))
    (group-cycle-test-reset!)))

(define (group-consolidate-test-open!)
  (group-cycle-test-open!)
  (layout-target-set! #f)
  (buffer-set-local! "*zz-cyc-work-b*" 'mode-name "text-mode")
  (buffer-set-local! "*zz-cyc-work-there*" 'mode-name "text-mode")
  (tile-windows! 'columns '("*zz-cyc-work-a*" "*zz-cyc-work-b*"
                         "*zz-cyc-three*" "*zz-cyc-work-b*"))
  (let ((windows (map car (window-list))))
    (set-window-prev-buffers! (nth 0 windows) '("*zz-cyc-work-there*"))
    (set-window-prev-buffers! (nth 1 windows) '("*zz-cyc-one*"))
    (set-window-prev-buffers! (nth 2 windows) '("*zz-cyc-work-b*" "*zz-cyc-two*"))
    (set-window-prev-buffers! (nth 3 windows) '())
    (select-window! (car windows))
    windows))

(deftest 'mode-consolidate-gathers-history-and-preserves-unrelated-work
  "matching buffers move to one window; unrelated histories and foreign groups stay"
  (lambda ()
    (let* ((windows (group-consolidate-test-open!))
           (destination (car windows))
           (geometry (map (lambda (r) (cons (car r) (cddr r))) (window-rects))))
      (run-command "mode-consolidate")
      (check-equal! (length (window-list)) 3 "the exhausted window is removed")
      (check-equal! (active-window) destination "the destination stays selected")
      (check-equal! (current-buffer) "*zz-cyc-work-a*" "the current buffer stays visible")
      (check-equal! (window-prev-buffers destination)
                    '("*zz-cyc-work-b*")
                    "the destination contains only matching buffers")
      (check-false! (window-showing "*zz-cyc-work-there*") "other destination buffers stay invisible")
      (check-equal! (window-buffer (nth 1 windows)) "*zz-cyc-one*" "the source reveals unrelated work")
      (check-equal! (window-prev-buffers (nth 1 windows)) '() "the source drops matching history")
      (check-equal! (window-buffer (nth 2 windows)) "*zz-cyc-three*" "unrelated work stays visible")
      (check-equal! (window-prev-buffers (nth 2 windows)) '("*zz-cyc-two*") "hidden matches move too")
      (check-false! (window-exists? (nth 3 windows)) "the exhausted window closes")
      (check-true! (buffer-known? "*zz-cyc-work-b*") "the gathered buffer stays alive")
      (let ((before (window-tree)))
        (run-command "mode-consolidate")
        (check-equal! (window-tree) before "a second consolidation changes nothing")))
    (group-cycle-test-reset!)))

(deftest 'mode-consolidate-includes-hidden-mode-buffers
  "a buffer need not be displayed or in a window history to join the stack"
  (lambda ()
    (group-cycle-test-open!)
    (layout-target-set! #f)
    (buffer-set-local! "*zz-cyc-work-b*" 'mode-name "text-mode")
    (switch-to-buffer-here! "*zz-cyc-work-a*")
    (delete-other-windows!)
    (set-window-prev-buffers! (active-window) '())
    (run-command "mode-consolidate")
    (check-equal! (window-prev-buffers (active-window)) '("*zz-cyc-work-b*") "the hidden buffer joins")
    (group-cycle-test-reset!)))

(deftest 'mode-consolidate-keeps-the-other-stack-invisible-at-target-capacity
  "an invisible window keeps the other stack without changing the visible target"
  (lambda ()
    (group-cycle-test-open!)
    (buffer-set-local! "*zz-cyc-work-b*" 'mode-name "text-mode")
    (tile-windows! 'two-pane '("*zz-cyc-work-a*" "*zz-cyc-three*"))
    (layout-target-set! 'two-pane)
    (let ((destination (window-showing "*zz-cyc-work-a*"))
          (neighbor (window-showing "*zz-cyc-three*")))
      (set-window-prev-buffers! destination '("*zz-cyc-one*" "*zz-cyc-two*"))
      (set-window-prev-buffers! neighbor '())
      (select-window! destination)
      (run-command "mode-consolidate")
      (check-equal! (window-prev-buffers destination) '("*zz-cyc-work-b*") "only matching history remains")
      (check-false! (window-showing "*zz-cyc-one*") "the other stack is invisible")
      (check-equal! (window-buffer neighbor) "*zz-cyc-three*" "the existing other window stays")
      (check-equal! (length (window-list)) 2 "no visible window is created")
      (check-equal! (layout-target) 'two-pane "the target stays unchanged"))
    (group-cycle-test-reset!)))
