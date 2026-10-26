;;; panes-test.scm --- the window model is pure data: a row of panes, each a
;;; stack of windows, each a stack of buffers. These tests drive the model
;;; and the two policies with no frame, no buffer and no group: the cases
;;; are docs/WINDOWS-SPEC.md sections 3, 4 and 7 at the level of the value.

(domain! 'testing)
(effects! '(pure))

;; open BUF of MODE as a visit from window SEL: (LAYOUT KEY)
(define (pt-visit layout buf mode &optional sel)
  (panes-show-buffer layout buf mode (and sel (panes-pane-of layout sel))))

(define (pt-display layout buf mode sel recent)
  (pt-visit layout buf mode sel))

(deftest 'a-new-mode-takes-a-pane-while-there-is-room
  "W01, O05: the first buffer of a mode makes a pane and is that mode's preferred window; the shares stay equal"
  (lambda ()
    (let* ((o1 (pt-visit (panes-empty 3) "a.scm" "scheme-mode"))
           (o2 (pt-visit (car o1) "*chat*" "chat-mode" (cadr o1)))
           (o3 (pt-visit (car o2) "notes.md" "morg-mode" (cadr o2)))
           (l (car o3)))
      (check-equal! (panes-pane-ids l) '("p1" "p2" "p3") "three modes, three panes")
      (check-equal! (map caddr (panes-visible l)) '("a.scm" "*chat*" "notes.md") "each pane shows its mode's buffer")
      (check-equal! (panes-shares l) (list (/ 1 3) (/ 1 3) (/ 1 3)) "equal shares")
      (check-equal! (panes-mode-window l "scheme-mode") (cadr o1) "the first scheme window is preferred"))))

(deftest 'a-buffer-opens-in-the-window-of-its-mode
  "W02, O01, O04: another buffer of a mode goes to that mode's window even when another window is selected, and spare capacity makes no duplicate"
  (lambda ()
    (let* ((o1 (pt-visit (panes-empty 3) "a.scm" "scheme-mode"))
           (o2 (pt-visit (car o1) "*chat*" "chat-mode" (cadr o1)))
           (o3 (pt-visit (car o2) "b.scm" "scheme-mode" (cadr o2))))
      (check-equal! (cadr o3) (cadr o1) "b.scm went to the scheme window")
      (check-equal! (panes-window-buffers (car o3) (cadr o1)) '("b.scm" "a.scm") "on top of its stack")
      (check-equal! (panes-pane-count (car o3)) 2 "no third pane for it"))))

(deftest 'at-capacity-a-new-mode-stacks-in-the-selected-pane
  "O06: with every pane taken, a visit of a new mode makes a window in the selected pane; the displaced window waits behind it with its stack"
  (lambda ()
    (let* ((o1 (pt-visit (panes-empty 2) "a.scm" "scheme-mode"))
           (o2 (pt-visit (car o1) "*chat*" "chat-mode" (cadr o1)))
           (o3 (pt-visit (car o2) "*dired*" "dired-mode" (cadr o2)))
           (l (car o3)))
      (check-equal! (panes-pane-count l) 2 "still two panes")
      (check-equal! (panes-pane-of l (cadr o3)) (panes-pane-of l (cadr o2)) "the new window is in the selected pane")
      (check-equal! (panes-top-windows l) (list (cadr o1) (cadr o3)) "it is on screen")
      (check-equal! (panes-window-buffers l (cadr o2)) '("*chat*") "the chat window keeps its stack behind"))))

(deftest 'a-display-at-capacity-takes-the-least-recent-other-pane
  "O09: a result shows in the least recently used other pane; the selected one keeps what it shows"
  (lambda ()
    (let* ((o1 (pt-visit (panes-empty 2) "a.scm" "scheme-mode"))
           (o2 (pt-visit (car o1) "*chat*" "chat-mode" (cadr o1)))
           (o3 (pt-display (car o2) "*help*" "help-mode" (cadr o2) (list (cadr o2) (cadr o1))))
           (l (car o3)))
      (check-equal! (panes-pane-of l (cadr o3)) (panes-pane-of l (cadr o1)) "help took the scheme pane")
      (check-equal! (panes-window-buffer l (cadr o2)) "*chat*" "the selected pane still shows the chat"))))

(deftest 'a-split-gives-a-mode-a-second-window-beside-the-first
  "the split buffers leave their window for a new one of the same mode in the next pane; the first window keeps the rest and still takes new buffers of the mode"
  (lambda ()
    (let* ((o1 (pt-visit (panes-empty 3) "a.scm" "scheme-mode"))
           (o2 (pt-visit (car o1) "b.scm" "scheme-mode" (cadr o1)))
           (o3 (pt-visit (car o2) "c.scm" "scheme-mode" (cadr o2)))
           (ka (cadr o1))
           (split (panes-split-off (car o3) '("c.scm" "b.scm") ka))
           (l (car split)) (kb (cadr split))
           (o4 (pt-visit l "d.scm" "scheme-mode" kb)))
      (check-equal! (panes-pane-count l) 2 "a second pane")
      (check-equal! (map caddr (panes-visible l)) '("a.scm" "c.scm") "side by side")
      (check-equal! (panes-window-buffers l kb) '("c.scm" "b.scm") "the new window holds the split buffers")
      (check-equal! (panes-window-buffers l ka) '("a.scm") "the first keeps the rest")
      (check-equal! (panes-window-mode l kb) "scheme-mode" "of the same mode")
      (check-equal! (cadr o4) ka "a new scheme buffer still opens in the first window")
      (check-equal! (panes-split-off l '("a.scm") ka) #f "a split never empties its window"))))

(deftest 'an-explicit-move-is-kept-and-does-not-retarget-opens
  "W04 to W06: a buffer moved out of its mode window stays there, a new buffer of the mode still goes to the preferred window, and revisiting the moved buffer brings it forward where it is"
  (lambda ()
    (let* ((o1 (pt-visit (panes-empty 3) "a.scm" "scheme-mode"))
           (o2 (pt-visit (car o1) "*chat*" "chat-mode" (cadr o1)))
           (o3 (pt-visit (car o2) "b.scm" "scheme-mode" (cadr o2)))
           (ka (cadr o1)) (kc (cadr o2))
           (moved (panes-move-buffer (car o3) "b.scm" kc))
           (o4 (pt-visit moved "c.scm" "scheme-mode" kc))
           (o5 (pt-visit (car o4) "b.scm" "scheme-mode" ka)))
      (check-equal! (panes-window-buffers moved kc) '("b.scm" "*chat*") "b.scm sits on the chat window")
      (check-equal! (cadr o4) ka "a new scheme buffer still goes to the preferred window")
      (check-equal! (cadr o5) kc "revisiting b.scm uses the window that holds it")
      (check-equal! (panes-window-buffer (car o5) kc) "b.scm" "and brings it forward there"))))

(deftest 'consolidation-gives-every-mode-one-window
  "M01, M03, M15: the preferred window of a mode gathers the mode's buffers from every other window; a window emptied closes; the operation is idempotent"
  (lambda ()
    (let* ((o1 (pt-visit (panes-empty 3) "a.scm" "scheme-mode"))
           (o2 (pt-visit (car o1) "*chat*" "chat-mode" (cadr o1)))
           (o3 (pt-visit (car o2) "b.scm" "scheme-mode" (cadr o2)))
           (ka (cadr o1)) (kc (cadr o2))
           ;; b.scm moved onto the chat window, then a dired visit stacks on the chat window too
           (l (panes-move-buffer (car o3) "b.scm" kc))
           (o4 (pt-visit (panes-set-capacity l 2) "*dired*" "dired-mode" kc))
           (l (car o4))
           (mode-of (lambda (b) (cond ((string-suffix? ".scm" b) "scheme-mode")
                                      ((equal? b "*chat*") "chat-mode")
                                      (else "dired-mode"))))
           (c1 (panes-consolidate l mode-of))
           (c2 (panes-consolidate c1 mode-of)))
      (check-equal! (panes-window-buffers c1 ka) '("a.scm" "b.scm") "the scheme window holds every scheme buffer")
      (check-equal! (panes-window-buffers c1 kc) '("*chat*") "the chat window keeps only the chat")
      (check-equal! (panes-window-buffer c1 (cadr o4)) "*dired*" "dired stays in its own window")
      (check-equal! c2 c1 "a second consolidation changes nothing"))))

(deftest 'consolidation-sends-stray-buffers-home-from-a-window-on-screen
  "A window on screen of another mode keeps only the buffer it shows; an empty second window of a mode closes"
  (lambda ()
    (let* ((o1 (pt-visit (panes-empty 2) "*todos*" "todo-mode"))
           (kt (cadr o1))
           (o2 (pt-visit (car o1) "*list*" "list-mode" kt))
           (kl (cadr o2))
           ;; the chat shows in the todo window; the other chats and a dired sit behind the list
           (l (panes-move-buffer (car o2) "*chat*" kt))
           (l (panes-move-buffer l "*chat2*" kl))
           (l (panes-move-buffer l "*dired*" kl))
           (l (panes-move-buffer l "*list*" kl))
           (mode-of (lambda (b) (cond ((string-prefix? "*chat" b) "chat-mode")
                                      ((equal? b "*todos*") "todo-mode")
                                      ((equal? b "*dired*") "dired-mode")
                                      (else "list-mode"))))
           (c1 (panes-consolidate l mode-of))
           (c2 (panes-consolidate c1 mode-of))
           (where (lambda (b) (filter (lambda (k) (member b (panes-window-buffers c1 k))) (panes-window-keys c1))))
           (windows (lambda (l) (map (lambda (k) (list k (panes-window-mode l k) (panes-window-buffers l k))) (panes-window-keys l)))))
      (check-equal! (panes-window-buffers c1 kl) '("*list*") "the list window keeps only the list")
      (check-equal! (where "*chat*") (where "*chat2*") "the chats share one window")
      (check-equal! (length (filter (lambda (k) (equal? (panes-window-mode c1 k) "chat-mode")) (panes-window-keys c1))) 1 "one chat window")
      (check-false! (member "*todos*" (panes-window-buffers c1 (car (where "*chat*")))) "the todos leave the chat window")
      (check-equal! (windows c2) (windows c1) "a second consolidation changes nothing"))))

(deftest 'a-kill-consults-only-each-windows-own-stack
  "Q13, Q14, rule 10 and 11: the killed buffer leaves every stack; a window falls to its own next buffer; an emptied window closes and its pane goes"
  (lambda ()
    (let* ((o1 (pt-visit (panes-empty 3) "a.scm" "scheme-mode"))
           (o2 (pt-visit (car o1) "b.scm" "scheme-mode" (cadr o1)))
           (o3 (pt-visit (car o2) "*chat*" "chat-mode" (cadr o1)))
           (ka (cadr o1)) (kc (cadr o3))
           (k1 (panes-drop-buffer (car o3) "b.scm"))
           (k2 (panes-drop-buffer k1 "*chat*")))
      (check-equal! (panes-window-buffer k1 ka) "a.scm" "the scheme window shows its own previous buffer")
      (check-equal! (panes-window k2 kc) #f "the emptied chat window is gone")
      (check-equal! (panes-pane-count k2) 1 "and its pane with it")
      (check-equal! (panes-pane-count (panes-drop-buffer k2 "a.scm")) 1 "the last pane stays"))))

(deftest 'quit-reveals-the-windows-own-predecessor
  "Q01, Q02, Q05: a pop shows the next buffer of that window only; an exhausted window closes"
  (lambda ()
    (let* ((o1 (pt-visit (panes-empty 3) "a" "m"))
           (o2 (pt-visit (car o1) "b" "m" (cadr o1)))
           (o3 (pt-visit (car o2) "c" "m" (cadr o1)))
           (o4 (pt-visit (car o3) "x" "other" (cadr o1)))
           (k (cadr o1))
           (q1 (panes-pop (car o4) k))
           (q2 (panes-pop (car q1) k))
           (q3 (panes-pop (car q2) k)))
      (check-equal! (cadr q1) "b" "c goes, b shows")
      (check-equal! (cadr q2) "a" "b goes, a shows")
      (check-equal! (cadr q3) #f "nothing left")
      (check-equal! (panes-window (car q3) k) #f "the window closed")
      (check-equal! (panes-pane-count (car q3)) 1 "the other pane remains"))))

(deftest 'windows-move-between-panes-with-their-stacks
  "I01, L09: a window moves whole; a pane left empty stays; a pane can be widened and the shares still sum to one"
  (lambda ()
    (let* ((o1 (pt-visit (panes-empty 3) "a" "m1"))
           (o2 (pt-visit (car o1) "b" "m2" (cadr o1)))
           (o3 (pt-visit (car o2) "a2" "m1" (cadr o2)))
           (ka (cadr o1)) (kb (cadr o2))
           (pb (panes-pane-of (car o3) kb))
           (m (panes-move-window (car o3) ka pb)))
      (check-equal! (panes-pane-count m) (panes-pane-count (car o3)) "a pane left empty stays")
      (check-equal! (panes-pane-keys m pb) (list ka kb) "the moved window is at the front of its new pane")
      (check-equal! (panes-window-buffers m ka) '("a2" "a") "with its stack")
      (let ((w (panes-set-share (car o3) pb 3)))
        (check-equal! (apply + (panes-shares w)) 1 "shares sum to one")
        (check-equal! (car (panes-shares w)) (/ 1 4) "the other pane shrank")))))

(deftest 'a-key-is-the-frame-window-id
  "H05: a window's key is its frame window id; a frame that gives another id rekeys it, and a dead buffer leaves on validation"
  (lambda ()
    (let* ((o1 (pt-visit (panes-empty 3) "old" "m"))
           (o2 (pt-visit (car o1) "other" "m" (cadr o1)))
           (k (cadr o1))
           (r (car o2))
           (h (panes-set-handle r k 42)))
      (check-equal! (panes-handle r k) k "the handle is the key")
      (check-equal! (panes-handle h 42) 42 "another id rekeys the window")
      (check-equal! (panes-key-of-handle h 42) 42 "and answers its key")
      (check-equal! (panes-handle h k) #f "the old key is gone")
      (check-equal! (panes-window-buffers (panes-validate h (lambda (b) (equal? b "other"))) 42) '("other") "a dead buffer leaves"))))


(deftest 'a-stray-in-another-modes-stack-opens-in-its-mode-window
  "a buffer another mode's window kept in its stack, from a stray display, opens in the window of its own mode and leaves that window as it was"
  (lambda ()
    (let* ((o1 (pt-visit (panes-empty 3) "*list*" "ats-mode"))
           (o2 (pt-display (car o1) "*d1*" "ats-approval-mode" (cadr o1) '()))
           (o3 (pt-visit (car o2) "*chat*" "chat-mode" (cadr o1)))
           (l (panes-show (panes-show (car o3) (cadr o3) "*d2*") (cadr o3) "*chat*"))
           (o4 (pt-display l "*d2*" "ats-approval-mode" (cadr o1) '())))
      (check-equal! (cadr o4) (cadr o2) "d2 went to the approval window")
      (check-equal! (panes-window-buffer (car o4) (cadr o3)) "*chat*" "the chat window still shows the chat"))))
