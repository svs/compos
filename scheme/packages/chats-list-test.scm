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

(deftest 'the-chat-list-is-one-application
  "*chat-list* is the mode list of chat-mode: ibuffer over the chat scope"
  (lambda ()
    (chats-test-open! 'group 'name)
    (check-equal! (buffer-local *chat-list* 'mode-name) "chat-list-mode" "the mode")
    (check-equal! (buffer-local *chat-list* 'ibuffer-scope) 'chat-list "the scope by name")
    (check-true! (ibuffer-view? *chat-list*) "a registered view")
    (check-equal! (ibuffer-row-kind "*zz-chats-a*") 'chat "a chat row wears the chat kind")
    (check-contains! (buffer-text *chat-list*) "Chats" "the title")
    (check-contains! (buffer-text *chat-list*) "3 chats" "the noun is chat")
    (chats-test-reset!)))

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
      (buffer-set-local! *chat-list* 'listing-peek-dismissed-row row)
      (run-command "chat-list")
      (check-equal! (buffer-local *chat-list* 'listing-peek-dismissed-row) #f
                    "arriving looks again at the row you left on")
      (listing-preview! *chat-list* row)
      (check-equal! (buffer-local (float-buffer) 'listing-preview-source) row
                    "and the card is the row you left on"))
    (chats-test-reset!)))

(deftest 'the-two-surfaces-are-bound-apart
  "C-x c is the minibuffer form, C-x C-c the application; neither is the other"
  (lambda ()
    (check-equal! (key-binding "C-x c") "chat-prompt" "the minibuffer form")
    (check-equal! (key-binding "C-x C-c") "chat-list" "the application")
    (check-true! (not (equal? *chat-prompt-buffer* *chat-list-buffer*))
                 "the form keeps its own view, so neither state leaks into the other")
    (check-true! (ibuffer-view? *chat-prompt-buffer*) "the form's view is registered")))

(deftest 'the-row-at-point-previews-its-chat
  "the row under the cursor floats the same card ibuffer floats, over the
   list's own window. Nothing else on screen is touched: a card that took
   the neighbour's window would be disturbing a buffer nobody offered."
  (lambda ()
    (chats-test-open! 'none 'name)
    (delete-other-windows!)
    (test-buffer! "*zz-chats-side*" "work beside the list")
    (let ((home (active-window)))
      (split-window! 'h 0.5)
      (other-window!)
      (switch-to-buffer-here! "*zz-chats-side*")
      (select-window! home)
      (let ((side (other-window-id home))
            (row (list-current *chat-list*)))
        (check-true! (and (string? row) (buffer-known? row)) "the row names a chat")
        (listing-preview! *chat-list* row)
        (check-true! (float-open?) "a card is floated")
        (check-equal! (buffer-local (float-buffer) 'listing-preview-source) row
                      "and it reads the row at point")
        (check-true! (not (member (float-window) (list home side)))
                     "the card is its own window, neither the list's nor the neighbour's")
        (check-equal! (window-buffer side) "*zz-chats-side*"
                      "the window beside the list keeps what it was showing")
        (listing-preview-dismiss! *chat-list*)
        (check-equal! (float-open?) #f "dismissing takes the card down")
        (check-equal! (window-buffer side) "*zz-chats-side*"
                      "and gives the neighbour back untouched")))
    (buffer-kill! "*zz-chats-side*")
    (chats-test-reset!)))

(deftest 'previewing-another-group-holds-the-frame-still
  "the card reads a chat from some other group; the frame does not follow it there"
  (lambda ()
    (chats-test-open! 'none 'name)
    (let ((home (frame-group))
          (view *chat-list*))
      (let loop ((n 0))
        (when (and (< n 8) (not (equal? (list-current view) "*zz-chats-c*")))
          (list-move-in! view 1)
          (loop (+ n 1))))
      (check-equal! (list-current view) "*zz-chats-c*" "the cursor reached the other group's chat")
      (listing-preview! view "*zz-chats-c*")
      (check-equal! (buffer-local (float-buffer) 'listing-preview-source) "*zz-chats-c*"
                    "the card shows it")
      ;; a card is a copy, never the chat itself in a window of the
      ;; frame, so the frame has nothing new to derive a group from
      (check-equal! (frame-group) home "the frame stayed in the group the list opened in")
      (check-equal! (chat-list-buffer) view "so the list is still the one on screen"))
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

(deftest 'moving-again-keeps-the-card-where-it-stands
  "the second row fills the card the first one opened, and adds no window"
  (lambda ()
    (chats-test-reset!)
    (chats-test-chat! "*zz-chats-a*" #f)
    (chats-test-chat! "*zz-chats-b*" #f)
    (chats-test-chat! "*zz-chats-c*" #f)
    (delete-other-windows!)
    (switch-to-buffer-here! "*zz-chats-a*")
    (split-window! 'h 0.5)
    (run-command "chat-list")
    (let ((view (chat-list-buffer)))
      (listing-preview! view "*zz-chats-b*")
      (let ((windows (length (window-list))) (host (float-window)))
        (check-true! (float-open?) "the first row lays a card over the neighbour")
        (listing-preview! view "*zz-chats-c*")
        (check-equal! (length (window-list)) windows
                      "the second row adds no window")
        (check-equal! (float-window) host "and the card stands where it stood")))
    (run-command "ibuffer-quit")
    (chats-test-reset!)))

(deftest 'two-qs-leave-with-a-card-up
  "the card is the list's own preview: q takes it, and the next q leaves, as in ibuffer"
  (lambda ()
    (chats-test-reset!)
    (chats-test-chat! "*zz-chats-a*" #f)
    (chats-test-chat! "*zz-chats-b*" #f)
    (delete-other-windows!)
    (switch-to-buffer-here! "*zz-chats-a*")
    (split-window! 'h 0.5)
    (let ((before (length (window-list))))
      (run-command "chat-list")
      (listing-preview! (chat-list-buffer) "*zz-chats-b*")
      (check-true! (float-open?) "the row floats a card over the neighbour")
      (run-command "ibuffer-quit")
      (check-false! (float-open?) "one q takes the card")
      (check-true! (and (window-showing (chat-list-buffer)) #t) "and leaves the list")
      (run-command "ibuffer-quit")
      (check-false! (window-showing (chat-list-buffer)) "the next q leaves the list")
      (check-equal! (length (window-list)) before "the arrangement comes back whole"))
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

(deftest 'chats-sections-by-group
  "grouped by group, one heading per group, by name, each with its members"
  (lambda ()
    (let ((ids (chats-test-open! 'group 'name)))
      (check-equal! (chats-test-heading-labels) '("zz-chats-one" "zz-chats-two")
                    "one heading per group, by name")
      (let ((one (car (chats-test-headings))))
        (check-equal! (ibuffer-heading-key one) (string-append "group:" (car ids))
                      "the heading names its group")
        (check-equal! (ibuffer-heading-count one) 2 "group one holds two chats")
        (check-equal! (ibuffer-heading-members one) '("*zz-chats-a*" "*zz-chats-b*")
                      "its members, by name"))
      (check-equal! (chats-test-names) '("*zz-chats-a*" "*zz-chats-b*" "*zz-chats-c*")
                    "the rows follow their headings")
      (check-contains! (buffer-text *chat-list*) "3 chats" "the meta counts the table's chats")
      (check-contains! (buffer-text *chat-list*) "idle" "a chat with no runtime is idle")
      (chats-test-reset!))))

(deftest 'chats-size-is-the-transcript
  "sorted by size, the longer transcript comes first, and the heading adds the bytes up"
  (lambda ()
    (chats-test-open! 'group 'name)
    (chats-test-log! "*zz-chats-a*" "zz-chats-a" 100)
    (chats-test-log! "*zz-chats-b*" "zz-chats-b" 5000)
    (ibuffer-set-sort! 'size *chat-list*)
    (check-equal! (ibuffer-sort *chat-list*) 'size "the sort is on the list buffer")
    (check-equal! (ibuffer-row-size "*zz-chats-b*") 5000 "the row reads the file's own bytes")
    (check-equal! (ibuffer-size-label "*zz-chats-b*") "4.9k" "and writes them the way dired does")
    (check-equal! (ibuffer-heading-members (car (chats-test-headings)))
                  '("*zz-chats-b*" "*zz-chats-a*") "b's transcript is longer")
    (check-equal! (ibuffer-heading-bytes (car (chats-test-headings))) 5100 "the heading sums")
    (check-equal! (ibuffer-row-size "*zz-chats-c*") #f "no transcript yet is no size")
    (chats-test-reset!)))

(deftest 'chats-rest-is-mru-with-the-group-in-the-row
  "the flat list is in MRU order and every row wears its chat's group"
  (lambda ()
    (let ((ids (chats-test-open! 'none 'recent)))
      (check-equal! (ibuffer-view-default *chat-list* 'grouping) 'group
                    "the list rests in sections, as ibuffer does")
      (check-equal! (ibuffer-view-default *chat-list* 'sort) 'recent
                    "and in most recently used order")
      (check-equal! (chats-test-headings) '() "a flat list has no sections")
      (check-true! (member 'group (map ibuffer-field-tag
                                       (ibuffer-fields *chat-list* *ibuffer-wide-fields*)))
                   "the group is a column of the flat row")
      (check-equal! (ibuffer-row-group-label "*zz-chats-a*") (group-short-name (car ids))
                    "and the cell names the chat's own group")
      (ibuffer-set-grouping! 'group *chat-list*)
      (check-equal! (member 'group (map ibuffer-field-tag
                                        (ibuffer-fields *chat-list* *ibuffer-wide-fields*)))
                    #f "sectioning by group drops the column rather than say it twice")
      (chats-test-reset!))))

(deftest 'chats-fold-hides-a-section
  "a folded heading stands for its rows and stays a row of its own"
  (lambda ()
    (let ((ids (chats-test-open! 'group 'name)))
      (ibuffer-toggle-fold! (string-append "group:" (car ids)) *chat-list*)
      (check-equal! (chats-test-names) '("*zz-chats-c*") "group one's rows are gone")
      (let ((folded (car (chats-test-headings))))
        (check-true! (ibuffer-heading-folded? folded) "the heading is folded")
        (check-true! (list-selectable? *chat-list* folded) "and selectable")
        (check-equal! (ibuffer-heading-count folded) 2 "it still counts its members"))
      (ibuffer-toggle-fold! (string-append "group:" (car ids)) *chat-list*)
      (check-equal! (length (chats-test-names)) 3 "unfolded, the rows return")
      (chats-test-reset!))))

(deftest 'chats-group-row-stands-for-its-chats
  "a group row takes the highlight, and a verb on it reads every chat under it"
  (lambda ()
    (let* ((ids (chats-test-open! 'group 'name))
           (es (list-entries *chat-list*))
           (at (let loop ((k 0) (rest es))
                 (cond ((null? rest) #f)
                       ((ibuffer-heading? (car rest)) k)
                       (else (loop (+ k 1) (cdr rest)))))))
      (check-true! (string? (list-current *chat-list*))
                   "the list opens on a chat, not on the group over it")
      (check-true! (list-selectable? *chat-list* (nth at es))
                   "an open group row is a row like any other")
      (list-goto-index! *chat-list* at)
      (check-true! (ibuffer-heading? (list-current *chat-list*))
                   "and it takes the highlight")
      (check-equal! (agents-targets) '("*zz-chats-a*" "*zz-chats-b*")
                    "a verb on the group row acts on every chat under it")
      (check-false! (agents-current-buf)
                    "and no one chat answers as the chat at point")
      (chats-test-reset!))))

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

(deftest 'chats-sections-by-state
  "the grouping cycles none, group, state, model; a chat with no runtime sits under idle"
  (lambda ()
    (chats-test-open! 'none 'name)
    (define *chats-other-grouping* (ibuffer-grouping "*ibuffer*"))
    (run-command "list-cycle-grouping")
    (check-equal! (ibuffer-grouping *chat-list*) 'group "none then group")
    (run-command "list-cycle-grouping")
    (check-equal! (ibuffer-grouping *chat-list*) 'state "group then state")
    (check-equal! (chats-test-heading-labels) '("idle") "one section: idle")
    (check-equal! (length (chats-test-names)) 3 "every chat is idle")
    (run-command "list-cycle-grouping")
    (check-equal! (ibuffer-grouping *chat-list*) 'model "state then model")
    (check-equal! (chats-test-heading-labels) '("no model") "a chat with no model says so")
    (run-command "list-cycle-grouping")
    (check-equal! (ibuffer-grouping *chat-list*) 'none "model then none, and round again")
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

(deftest 'the-prompt-previews-in-a-card-like-the-window-form
  "C-x c: the row under the cursor floats an inert card over the rows. The
   pane the picker was invoked from is the user's and keeps what it held."
  (lambda ()
    (chats-test-reset!)
    (chats-test-chat! "*zz-chats-a*" (group-record-create! "zz-chats-one"))
    (chats-test-chat! "*zz-chats-b*" (group-record-id (group-record-by-name "zz-chats-one")))
    (run-command "chat-prompt")
    (let* ((view *chat-prompt-buffer*)
           (home (buffer-local view 'ibuffer-prompt-home-window))
           (was (and home (window-buffer home))))
      (list-set-filters! view (list (list "match" "zz-chats-")))
      (list-refresh! view)
      (ibuffer-goto-first-row! view)
      (let ((row (list-current view)))
        (check-true! (and (string? row) (buffer-known? row)) "the row names a chat")
        (listing-preview! view row)
        (check-equal! (float-open?) #t "the row floats a card")
        (check-equal! (buffer-local (float-buffer) 'listing-preview-source) row
                      "the card holds the row's chat")
        (check-equal! (window-buffer home) was
                      "the pane it was invoked from is untouched")))
    (run-command "minibuffer-cancel")
    (chats-test-reset!)))

;; the prompt view is asked for its row before it has been drawn, so it may
;; have no point yet. That used to raise out of the open, and C-x c did
;; nothing at all: no list, no card, no error the user could see.
(deftest 'a-list-with-no-point-yet-answers-instead-of-raising
  "asking an undrawn list buffer for its row answers, error-free"
  (lambda ()
    (let ((buf "*zz-chats-unpointed*"))
      (buffer-create buf)
      (check-equal! (ignore-errors (lambda () (list 'ok (line-index-at buf 0))))
                    (list 'ok 0)
                    "an empty buffer sits on the first entry line")
      (check-equal! (ignore-errors (lambda () (list 'ok (line-index-at buf 3))))
                    (list 'ok #f)
                    "and under a header it is above the entries")
      (check-equal! (ignore-errors (lambda () (list 'ok (ibuffer-current buf))))
                    (list 'ok #f)
                    "so it has no row, rather than raising")
      (buffer-kill! buf))))
