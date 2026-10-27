;;; chats-list-test.scm --- *chat-list* is the chat list application:
;;; one arrival, sections by group, the chat row kind, and the words a
;;; row shows.
;;;
;;; Every test opens the application by command and narrows it to its own
;;; chats, then reads the entries and the text. No test names a key.

(domain! 'testing)
(effects! '(write))

(tests-need-a-disposable-editor!
  "the chat list is an application: it takes the frame, enters its own group, and holds the focus")

(define *chats-test-bufs* '("*zz-chats-a*" "*zz-chats-b*" "*zz-chats-c*"))

(define (chats-test-drop-group! name)
  ;; standing in a group gives it a group chat, and a group chat is a row
  ;; in this very list: leave one behind and the next test counts it
  (let ((chat (string-append "*chat:" name "*")))
    (when (buffer-known? chat) (buffer-kill! chat)))
  (when (group-record-by-name name) (group-record-delete! name)))

(define *chat-list* "*chat-list*")

(define (chats-test-reset!)
  (when (buffer-known? *chat-list*)
    (run-command "ibuffer-quit")
    (buffer-set-locals! *chat-list*
      (list 'ibuffer-sort #f 'ibuffer-grouping #f 'ibuffer-collapsed '()))
    (list-filter-clear! *chat-list*)
    (buffer-kill! *chat-list*))
  ;; the transcripts go before the buffers do: the path is read off the
  ;; chat's own group, which a killed buffer no longer has
  (for-each (lambda (b)
              (let ((id (and (buffer-known? b) (buffer-local b 'chat-log-id))))
                (when (string? id)
                  (delete-file-path! (string-append (chat-log-dir-for b) "/" id ".chat") #t))))
            *chats-test-bufs*)
  (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b))) *chats-test-bufs*)
  (chats-test-drop-group! "zz-chats-one")
  (chats-test-drop-group! "zz-chats-two")
  (delete-other-windows!))

;; a chat with no runtime: the api state, which the row calls idle
(define (chats-test-chat! name group-id)
  (test-buffer! name "")
  (buffer-set-local! name 'mode-name "chat-mode")
  (when group-id (buffer-set-local! name 'group-id group-id))
  name)

;; a chat's size is its transcript on disk, so a chat that needs a size
;; needs a file: BYTES of one, under the group's own chats directory
(define (chats-test-log! name id bytes)
  (buffer-set-local! name 'chat-log-id id)
  (write-file! (string-append (chat-log-dir-for name) "/" id ".chat")
               (string-repeat "x" bytes))
  name)

;; a and b in group one, c in group two; answers (ONE TWO)
(define (chats-test-open! grouping sort)
  (chats-test-reset!)
  (let ((one (group-record-create! "zz-chats-one"))
        (two (group-record-create! "zz-chats-two")))
    (chats-test-chat! "*zz-chats-a*" one)
    (chats-test-chat! "*zz-chats-b*" one)
    (chats-test-chat! "*zz-chats-c*" two)
    (run-command "chat-list")
    (set! *chat-list* (chat-list-buffer))
    (buffer-set-locals! *chat-list*
      (list 'ibuffer-grouping grouping 'ibuffer-sort sort 'ibuffer-collapsed '()))
    (list-set-filters! *chat-list* (list (list "match" "zz-chats-")))
    (list-refresh! *chat-list*)
    (ibuffer-goto-first-row! *chat-list*)
    (list one two)))

(define (chats-test-names)
  (filter string? (list-entries *chat-list*)))

(define (chats-test-headings)
  (filter ibuffer-heading? (list-entries *chat-list*)))

(define (chats-test-heading-labels)
  (map ibuffer-heading-label (chats-test-headings)))

(deftest 'chats-state-words
  "a runtime status reads as what the chat waits for"
  (lambda ()
    (check-equal! (chats-state-label 'needs_attention) "your turn" "attention")
    (check-equal! (chats-state-label 'running) "streaming" "running")
    (check-equal! (chats-state-label 'idle) "idle" "idle")
    (check-equal! (chats-state-label 'api) "idle" "a chat with no runtime is idle")
    (check-equal! (chats-state-label 'dead) "stopped" "dead")
    (check-equal! (chats-state-face 'needs_attention) "alert" "attention is lit")))

(deftest 'chats-note-activity
  "the event batch stamps the chat, and the row reads the age back"
  (lambda ()
    (chats-note-activity! "*zz-chats-stamped*")
    (check-equal! (chats-age-label (chats-activity-at "*zz-chats-stamped*")) "now" "just stamped")
    (check-equal! (chats-age-label (chats-activity-at "*zz-chats-never*")) "" "never stamped")))

(deftest 'the-state-change-draws-the-list
  "the row's state is read at draw time, so a change has to draw it once"
  (lambda ()
    ;; the first sight of a slug is a change: nothing drew it before
    (set! *agents-state-last* '())
    (check-true! (agents-state-moved? "zz-no-such-agent")
                 "an unseen chat has moved")
    (check-false! (agents-state-moved? "zz-no-such-agent")
                  "the same state again is not a change")
    (check-equal! (alist-get *agents-state-last* "zz-no-such-agent") 'dead
                  "the state it settled on is kept")
    ;; a state the list has not drawn yet moves again
    (set! *agents-state-last*
          (alist-put *agents-state-last* "zz-no-such-agent" 'running))
    (check-true! (agents-state-moved? "zz-no-such-agent")
                 "streaming to stopped is a change")
    (set! *agents-state-last* '())))

(deftest 'the-list-arrives-in-the-invoking-group
  "one arrival: the invoking group, one window, the list holding the focus"
  (lambda ()
    (let ((groups (chats-test-open! 'group 'name)))
      ;; a frame with no group yet cannot say where the list belongs, so
      ;; stand in a real group before asking
      (switch-to-group! (car groups))
      (delete-other-windows!)
      (run-command "chat-list")
      (set! *chat-list* (chat-list-buffer))
      (check-equal! (buffer-group *chat-list*) (frame-group)
                    "the listing belongs to the group it opened in"))
    (check-equal! (window-buffer (active-window)) *chat-list* "the list has focus")
    (check-equal! (buffer-local *chat-list* 'ibuffer-prompt-home-window) #f
                  "the application form previews with a card, not into a home window")
    (chats-test-reset!)))

(deftest 'arriving-is-a-request-to-look
  "a preview dismissed before you left does not keep the pane shut when you come back"
  (lambda ()
    (chats-test-open! 'none 'name)
    (let ((row (list-current *chat-list*)))
      (buffer-set-local! *chat-list* 'listing-preview-dismissed-row row)
      (run-command "chat-list")
      (check-equal! (buffer-local *chat-list* 'listing-preview-dismissed-row) #f
                    "arriving looks again at the row you left on")
      (listing-preview! *chat-list* row)
      (check-equal! (buffer-local (float-buffer) 'listing-preview-source) row
                    "and the card is the row you left on"))
    (chats-test-reset!)))



(deftest 'the-list-does-not-pin-the-frames-group
  "the list takes a window beside your work, so it has no claim on the frame's group"
  (lambda ()
    (chats-test-reset!)
    (let ((before (frame-local 'pinned-group)))
      (chats-test-open! 'none 'name)
      (check-equal! (frame-local 'pinned-group) before
                    "standing pins nothing: previewing is a card, and a card moves no group")
      (run-command "ibuffer-quit")
      (check-equal! (frame-local 'pinned-group) before "and leaving changes nothing either"))
    (chats-test-reset!)))

(deftest 'leaving-hands-the-frame-back
  "the list took a window, so q gives that window back what it held"
  (lambda ()
    (chats-test-reset!)
    (chats-test-chat! "*zz-chats-a*" #f)
    (delete-other-windows!)
    (switch-to-buffer-here! "*zz-chats-a*")
    (let ((before (length (window-list))))
      (run-command "chat-list")
      (check-equal! (window-buffer (active-window)) (chat-list-buffer)
                    "the list stands in the window it took")
      (run-command "ibuffer-quit")
      (check-equal! (length (window-list)) before "and gave the arrangement back")
      (check-equal! (window-buffer (active-window)) "*zz-chats-a*"
                    "showing what it displaced"))
    (chats-test-reset!)))

(deftest 'the-resting-list-is-flat-and-most-recent-first
  "at rest the list stands in sections, one per group, most recently used first inside each"
  (lambda ()
    (chats-test-reset!)
    (chats-test-chat! "*zz-chats-a*" #f)
    (chats-test-chat! "*zz-chats-b*" #f)
    (chats-test-chat! "*zz-chats-c*" #f)
    (run-command "chat-list")
    (set! *chat-list* (chat-list-buffer))
    (check-equal! (ibuffer-grouping *chat-list*) 'group "a chat belongs to the work it was opened for")
    (check-equal! (ibuffer-sort *chat-list*) 'recent "most recently used first")
    (list-set-filters! *chat-list* (list (list "match" "zz-chats-")))
    (list-refresh! *chat-list*)
    (check-equal! (chats-test-heading-labels) '("ungrouped")
                  "a chat in no group sits under the one section that says so")
    (check-equal! (length (chats-test-names)) 3 "every chat is a row of its own")
    (chats-test-reset!)))

(deftest 'the-application-leaves-the-way-it-arrived
  "q puts the frame back where it stood and leaves the pin behind"
  (lambda ()
    (let ((from (frame-group)))
      (chats-test-open! 'none 'name)
      (run-command "ibuffer-quit")
      (check-equal! (frame-group) from "the frame is back in the group you came from")
      (check-false! (group-pinned) "the application's pin is gone")
      (check-false! (window-showing *chat-list*) "and the list is not left standing"))
    (chats-test-reset!)))

(deftest 'chats-rows-sit-under-their-group-and-say-their-state
  "sectioned by group, a chat sits under its group's name; the meta counts chats, and a chat with no runtime reads idle"
  (lambda ()
    (chats-test-open! 'group 'name)
    (check-equal! (chats-test-heading-labels) '("zz-chats-one" "zz-chats-two")
                  "one heading per group, by name")
    (check-contains! (buffer-text *chat-list*) "3 chats" "the meta counts the table's chats")
    (check-contains! (buffer-text *chat-list*) "idle" "a chat with no runtime is idle")
    (chats-test-reset!)))

(deftest 'chats-size-is-the-transcript
  "a chat's size is its transcript on disk, written the way dired writes bytes; no transcript is no size"
  (lambda ()
    (chats-test-open! 'group 'name)
    (chats-test-log! "*zz-chats-a*" "zz-chats-a" 100)
    (chats-test-log! "*zz-chats-b*" "zz-chats-b" 5000)
    (check-equal! (ibuffer-row-size "*zz-chats-b*") 5000 "the row reads the file's own bytes")
    (check-equal! (ibuffer-size-label "*zz-chats-b*") "4.9k" "and writes them the way dired does")
    (check-equal! (ibuffer-row-size "*zz-chats-c*") #f "no transcript yet is no size")
    (chats-test-reset!)))



;; the list shows sleeping chats, so a verb has to act on one. The
;; targets asked buffer-exists?, which answers #f for every dormant row,
;; and that left nearly every verb saying there was no chat here.
(deftest 'a-verb-acts-on-a-sleeping-chat
  "a chat the editor put to sleep is still the chat the row at point names"
  (lambda ()
    (chats-test-open! 'none 'name)
    (let ((row (list-current *chat-list*)))
      (check-equal! row "*zz-chats-a*" "the first row by name")
      (buffer-sleep! row)
      (check-true! (wait-until (lambda () (not (buffer-exists? row))) 3000 20)
                   "the chat sleeps")
      (check-true! (buffer-known? row) "and the editor still knows it")
      (check-equal! (agents-targets) (list row)
                    "the verb acts on the sleeping chat, not on nothing")
      (check-false! (agents-runtime-slug row)
                    "and it has no runtime to answer with"))
    (chats-test-reset!)))

(deftest 'a-verb-in-a-chat-acts-on-that-chat
  "in a chat, a verb acts on that chat, not on the row at point in the list"
  (lambda ()
    (chats-test-open! 'none 'name)
    (check-equal! (list-current *chat-list*) "*zz-chats-a*" "the list is on a")
    (check-equal! (with-current-buffer "*zz-chats-c*" agents-targets)
                  '("*zz-chats-c*")
                  "the verb acts on the chat you are in")
    (chats-test-reset!)))

(deftest 'chats-sections-by-group-or-none
  "the grouping cycles none and group only: state and model are no sections"
  (lambda ()
    (chats-test-open! 'none 'name)
    (define *chats-other-grouping* (ibuffer-grouping "*ibuffer*"))
    (run-command "list-cycle-grouping")
    (check-equal! (ibuffer-grouping *chat-list*) 'group "none then group")
    (run-command "list-cycle-grouping")
    (check-equal! (ibuffer-grouping *chat-list*) 'none "group then none, and round again")
    (check-equal! (ibuffer-grouping "*ibuffer*") *chats-other-grouping* "the *ibuffer* view keeps its own")
    (chats-test-reset!)))

(deftest 'a-word-nobody-titled-schedules-a-search
  "the filter schedules transcript work instead of scanning on the key lane"
  (lambda ()
    (chats-test-open! 'none 'name)
    (buffer-append! "*zz-chats-c*" "we settled on the zzhaystack budget in the end")
    (run-command "list-filter")
    (minibuffer-change! "zzhaystack")
    (check-equal! (plist-get (minibuffer-state) 'input) "zzhaystack" "input is immediate")
    (check-false! (chat-list-hit "*zz-chats-c*") "no synchronous transcript scan")
    (minibuffer-cancel!)
    (check-equal! (cadr *mode-list-search*) "zzhaystack" "closing keeps the search")
    (check-equal! (list-query *chat-list*) "zzhaystack" "closing preserves narrowing")
    (chats-test-reset!)))

(deftest 'chats-narrowing-reads-the-summary
  "the narrowing matches the running summary, and the row leads with it"
  (lambda ()
    (chats-test-open! 'group 'name)
    (buffer-set-local! "*zz-chats-c*" 'chat-summary "Narrowed the retry budget to one lane.")
    (list-set-filters! *chat-list* (list (list "match" "retry budget")))
    (list-refresh! *chat-list*)
    (check-equal! (chats-test-names) '("*zz-chats-c*") "only the chat whose summary matches")
    (check-equal! (chats-test-heading-labels) '("zz-chats-two") "under its group")
    (check-contains! (buffer-text *chat-list*) "Narrowed the retry budget" "the row leads with the sentence")
    (chats-test-reset!)))

(deftest 'chat-prompt-splits-by-group
  "C-x c: the rows come in sections by group, each heading before its chats"
  (lambda ()
    (chats-test-open! 'group 'name)
    (let* ((rows (chat-prompt-rows))
           (mine (filter (lambda (r)
                           (or (member (car r) '("zz-chats-one" "zz-chats-two"))
                               (and (not (chat-prompt-separator? r))
                                    (string-prefix? "*zz-chats-" (nth 3 r)))))
                         rows)))
      (check-equal! (map car mine)
                    '("zz-chats-one" "*zz-chats-a*" "*zz-chats-b*" "zz-chats-two" "*zz-chats-c*")
                    "one heading per group, its chats under it")
      (check-true! (chat-prompt-separator? (car mine)) "the heading is a separator row")
      (check-equal! (length (car mine)) 3 "a heading has label, annotation, kind"))
    (chats-test-reset!)))


(deftest 'dot-shows-the-hidden-chats-and-puts-them-away
  "a context-only chat, an agent's own, is out of the list until . asks for it"
  (lambda ()
    (chats-test-open! 'none 'name)
    (buffer-context-only! "*zz-chats-b*")
    (list-refresh! *chat-list*)
    (check-false! (member "*zz-chats-b*" (chats-test-names))
                  "at rest the hidden chat is not listed")
    (with-current-buffer *chat-list* (lambda () (run-command "ibuffer-toggle-hidden")))
    (check-true! (and (member "*zz-chats-b*" (chats-test-names)) #t)
                 "after . the hidden chat is listed")
    (check-true! (and (assoc "hidden" (list-filters *chat-list*)) #t)
                 "the switch is a filter, as dired's dot filter is")
    (with-current-buffer *chat-list* (lambda () (run-command "ibuffer-toggle-hidden")))
    (check-false! (member "*zz-chats-b*" (chats-test-names))
                  "and . again puts it away")
    (chats-test-reset!)))

(deftest 'a-spawned-chat-sits-under-its-spawner
  "a chat that another chat spawned follows it in the list, indented"
  (lambda ()
    (with-stub 'subagent-live-buffer (lambda (p) (and (buffer-known? p) p))
      (lambda ()
        (chats-test-open! 'none 'name)
        (buffer-set-local! "*zz-chats-c*" 'subagent-parent "*zz-chats-a*")
        (list-refresh! *chat-list*)
        (check-equal! (chats-test-names) '("*zz-chats-a*" "*zz-chats-c*" "*zz-chats-b*")
                      "the child follows its parent, ahead of the name order")
        (check-equal! (list-nest-prefix *chat-list* "*zz-chats-c*") "└ "
                      "and its name is indented")
        (check-equal! (list-nest-prefix *chat-list* "*zz-chats-b*") ""
                      "a chat with no spawner is not")
        (list-fold-toggle! *chat-list* "*zz-chats-a*")
        (list-redraw! *chat-list*)
        (check-equal! (chats-test-names) '("*zz-chats-a*" "*zz-chats-b*")
                      "a folded spawner hides the chat it spawned")
        (check-equal! (list-row-hidden *chat-list* "*zz-chats-a*") 1
                      "and says how many it hides")
        (list-fold-toggle! *chat-list* "*zz-chats-a*")))
    (chats-test-reset!)))
