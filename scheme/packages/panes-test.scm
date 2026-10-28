;;; panes-test.scm --- the spec of the window model.
;;;
;;; A layout is a row of panes, each a stack of windows, each a stack of
;;; buffers. Every test here is one rule the user can see, said as its
;;; name, and checks it on the value alone: a layout goes in, a layout
;;; comes out, with no frame, no buffer and no draw. That the screen shows
;;; the model is panes-mode-test.scm's business.

(domain! 'testing)
(effects! '(pure))

;; the mode of each test buffer
(define (pt-mode b)
  (cond ((string-suffix? ".scm" b) "scheme-mode")
        ((string-prefix? "*chat" b) "chat-mode")
        ((string-prefix? "*dired" b) "dired-mode")
        (else "text-mode")))

;; a row of panes, one per buffer, as a new group lays it out
(define (pt-row &rest bufs) (panes-default-layout bufs pt-mode))

;; open BUF from pane PANE: (LAYOUT KEY)
(define (pt-open layout buf &optional pane)
  (panes-show-buffer layout buf (pt-mode buf) pane))

(define (pt-window l mode) (panes-mode-window l mode))

;;; --- opening a buffer -------------------------------------------------------

(deftest 'the-first-buffer-makes-the-first-pane
  "an empty layout opens a buffer in a new pane of its own"
  (lambda ()
    (let ((l (car (pt-open (panes-empty) "a.scm"))))
      (check-equal! (panes-pane-count l) 1 "one pane")
      (check-equal! (map caddr (panes-visible l)) '("a.scm") "showing the buffer"))))

(deftest 'a-buffer-opens-in-the-window-of-its-mode
  "another buffer of a mode goes to that mode's window, wherever you are, and that window comes to the front of its pane"
  (lambda ()
    (let* ((l (pt-row "a.scm" "*chat*"))
           (o (pt-open l "b.scm" "p2")))
      (check-equal! (cadr o) (pt-window l "scheme-mode") "the scheme window took it")
      (check-equal! (panes-window-buffers (car o) (cadr o)) '("b.scm" "a.scm") "on top of its stack")
      (check-equal! (panes-pane-count (car o)) 2 "no pane was made"))))

(deftest 'a-new-mode-opens-a-window-in-the-pane-you-are-in
  "a buffer of a mode that has no window gets a new window at the front of your pane; the window it covers waits behind; no pane is made"
  (lambda ()
    (let* ((l (pt-row "a.scm" "*chat*"))
           (kc (pt-window l "chat-mode"))
           (o (pt-open l "*dired*" "p2")))
      (check-equal! (panes-pane-of (car o) (cadr o)) "p2" "in your pane")
      (check-equal! (panes-pane-keys (car o) "p2") (list (cadr o) kc) "in front, the chat behind")
      (check-equal! (panes-pane-count (car o)) 2 "still two panes"))))

(deftest 'a-buffer-in-another-modes-window-opens-in-its-own-modes-window
  "a buffer that sits in another mode's stack opens in the window of its own mode, and the other window keeps what it shows"
  (lambda ()
    (let* ((l (pt-row "a.scm" "*chat*"))
           (ka (pt-window l "scheme-mode")) (kc (pt-window l "chat-mode"))
           (l (panes-show (panes-show l kc "b.scm") kc "*chat*"))
           (o (pt-open l "b.scm" "p2")))
      (check-equal! (cadr o) ka "b.scm went to the scheme window")
      (check-equal! (panes-window-buffer (car o) kc) "*chat*" "the chat window still shows the chat"))))

(deftest 'quit-shows-the-windows-own-previous-buffer
  "quit takes the shown buffer out of its window and shows that window's previous one; a window with nothing left closes, and its pane stays"
  (lambda ()
    (let* ((l (car (pt-open (car (pt-open (car (pt-open (pt-row "*chat*") "a.scm" "p1")) "b.scm")) "c.scm")))
           (k (pt-window l "scheme-mode"))
           (q1 (panes-pop l k)) (q2 (panes-pop (car q1) k)) (q3 (panes-pop (car q2) k)))
      (check-equal! (cadr q1) "b.scm" "c goes, b shows")
      (check-equal! (cadr q2) "a.scm" "b goes, a shows")
      (check-equal! (cadr q3) #f "nothing left")
      (check-equal! (panes-window (car q3) k) #f "the window closed")
      (check-equal! (panes-pane-count (car q3)) 1 "its pane stays"))))

(deftest 'a-split-gives-a-mode-a-second-window-beside-the-first
  "the split buffers leave their window for a new one of the same mode in the next pane; the first window keeps the rest and still takes new buffers of the mode; a split never empties its window"
  (lambda ()
    (let* ((o1 (pt-open (panes-empty 3) "a.scm"))
           (o2 (pt-open (car o1) "b.scm"))
           (o3 (pt-open (car o2) "c.scm"))
           (ka (cadr o1))
           (split (panes-split-off (car o3) '("c.scm" "b.scm") ka))
           (l (car split)) (kb (cadr split))
           (o4 (pt-open l "d.scm" (panes-pane-of l kb))))
      (check-equal! (panes-pane-count l) 2 "a second pane")
      (check-equal! (map caddr (panes-visible l)) '("a.scm" "c.scm") "side by side")
      (check-equal! (panes-window-buffers l kb) '("c.scm" "b.scm") "the new window holds the split buffers")
      (check-equal! (panes-window-buffers l ka) '("a.scm") "the first keeps the rest")
      (check-equal! (panes-window-mode l kb) "scheme-mode" "of the same mode")
      (check-equal! (cadr o4) ka "a new scheme buffer still opens in the first window")
      (check-equal! (panes-split-off l '("a.scm") ka) #f "a split never empties its window"))))

;;; --- panes and windows ------------------------------------------------------

(deftest 'an-emptied-window-closes-and-its-pane-stays
  "when the last buffer leaves a window, the window closes; its pane stays, empty"
  (lambda ()
    (let ((l (panes-drop-buffer (pt-row "a.scm" "*chat*") "*chat*")))
      (check-false! (member "*chat*" (panes-buffers l)) "the chat is gone")
      (check-equal! (panes-pane-count l) 2 "both panes stay")
      (check-equal! (panes-pane-keys l "p2") '() "the second pane is empty"))))

(deftest 'removing-a-pane-removes-its-windows-and-the-last-pane-stays
  "a pane goes with every window in it; the focus passes to the pane that takes its place; the last pane never goes"
  (lambda ()
    (let* ((l (panes-set-focus (pt-row "a.scm" "*chat*") "p1"))
           (r (panes-remove-pane l "p1")))
      (check-equal! (panes-pane-ids r) '("p2") "one pane left")
      (check-false! (member "a.scm" (panes-buffers r)) "its window went with it")
      (check-equal! (panes-focus r) "p2" "the focus moved to the pane that took its place")
      (check-equal! (panes-pane-ids (panes-remove-pane r "p2")) '("p2") "the last pane stays"))))

(deftest 'a-window-moves-between-panes-with-its-stack
  "a window moves whole, to the front of the other pane; the pane it leaves stays"
  (lambda ()
    (let* ((l (car (pt-open (pt-row "a.scm" "*chat*") "a2.scm")))
           (ka (pt-window l "scheme-mode")) (kc (pt-window l "chat-mode"))
           (m (panes-move-window l ka "p2")))
      (check-equal! (panes-pane-count m) 2 "the pane it left stays")
      (check-equal! (panes-pane-keys m "p2") (list ka kc) "the moved window is at the front of its new pane")
      (check-equal! (panes-window-buffers m ka) '("a2.scm" "a.scm") "with its stack"))))

(deftest 'widening-a-pane-keeps-the-shares-summing-to-one
  "a pane's width is a share of the row; widening one narrows the others"
  (lambda ()
    (let ((w (panes-set-share (pt-row "a.scm" "*chat*") "p2" 3)))
      (check-equal! (panes-shares w) (list (/ 1 4) (/ 3 4)) "one quarter and three quarters")
      (check-equal! (apply + (panes-shares w)) 1 "the shares sum to one")
      (check-equal! (panes-layout-shares w #t) (list (/ 1 4) (/ 3 4)) "and those are the widths the screen is given"))))

(deftest 'splitting-a-pane-below-halves-its-height
  "a split below puts a new empty pane under the pane, in its column, and the two share its height"
  (lambda ()
    (let* ((s (panes-split-below (pt-row "a.scm" "*chat*") "p1"))
           (cols (panes-columns (car s))))
      (check-equal! (length cols) 2 "still two columns")
      (check-equal! (map (lambda (p) (plist-get p 'id)) (car cols)) (list "p1" (cadr s)) "the new pane is under the first")
      (check-equal! (panes-vshares (car cols)) (list (/ 1 2) (/ 1 2)) "they halve the height")
      (check-equal! (panes-pane-keys (car s) (cadr s)) '() "the new pane is empty"))))

(deftest 'two-panes-swap-windows-and-keep-their-place-and-size
  "a swap trades the windows of two panes; each pane keeps its place and its width"
  (lambda ()
    (let* ((l (panes-set-share (pt-row "a.scm" "*chat*") "p1" 2))
           (ka (pt-window l "scheme-mode")) (kc (pt-window l "chat-mode"))
           (s (panes-swap-panes l "p1" "p2")))
      (check-equal! (panes-pane-of s kc) "p1" "the chat is on the left")
      (check-equal! (panes-pane-of s ka) "p2" "the scheme window on the right")
      (check-equal! (panes-shares s) (panes-shares l) "the widths stay"))))

;;; --- focus ------------------------------------------------------------------

(deftest 'the-focused-window-is-the-front-window-of-the-focused-pane
  "the focus is a pane, the first one until a pane takes it; its front window is the window you are in"
  (lambda ()
    (let* ((l (pt-row "a.scm" "*chat*"))
           (f (panes-set-focus l "p2")))
      (check-equal! (panes-focus l) "p1" "the first pane until one takes the focus")
      (check-equal! (panes-focus f) "p2" "the second pane took it")
      (check-equal! (car (panes-pane-keys f (panes-focus f))) (pt-window l "chat-mode") "its front window is the chat")
      (check-equal! (panes-set-focus f "p9") f "an unknown pane changes nothing"))))

(deftest 'focusing-a-window-brings-it-to-the-front-of-its-pane
  "a window behind others comes to the front of its pane when you go to it, and its pane takes the focus"
  (lambda ()
    (let* ((l (car (pt-open (pt-row "a.scm" "*chat*") "*dired*" "p1")))
           (ka (pt-window l "scheme-mode"))
           (f (panes-focus-window (panes-set-focus l "p2") ka)))
      (check-equal! (car (panes-pane-keys f "p1")) ka "the scheme window is in front again")
      (check-equal! (panes-focus f) "p1" "and its pane has the focus"))))

;;; --- killing a buffer -------------------------------------------------------

(deftest 'a-kill-removes-the-buffer-from-every-stack
  "a killed buffer leaves every window; each window falls back to its own previous buffer; an emptied window closes and its pane stays"
  (lambda ()
    (let* ((l (car (pt-open (pt-row "a.scm" "*chat*") "b.scm")))
           (ka (pt-window l "scheme-mode")) (kc (pt-window l "chat-mode"))
           (l (panes-show l kc "b.scm"))
           (k1 (panes-drop-buffer l "b.scm"))
           (k2 (panes-drop-buffer k1 "*chat*")))
      (check-false! (member "b.scm" (panes-buffers k1)) "b.scm left both windows")
      (check-equal! (panes-window-buffer k1 ka) "a.scm" "the scheme window shows its own previous buffer")
      (check-equal! (panes-window-buffer k1 kc) "*chat*" "the chat window shows its own previous buffer")
      (check-equal! (panes-window k2 kc) #f "the emptied chat window closed")
      (check-equal! (panes-pane-count k2) 2 "its pane stays"))))

;;; --- groups -----------------------------------------------------------------

(deftest 'a-new-group-lays-out-one-pane-per-buffer
  "a group's first layout is a row of panes, one per buffer, left to right, equal widths, each a window of its buffer's mode"
  (lambda ()
    (let ((l (pt-row "a.scm" "*chat*" "notes.md")))
      (check-equal! (map caddr (panes-visible l)) '("a.scm" "*chat*" "notes.md") "one pane per buffer")
      (check-equal! (panes-shares l) (list (/ 1 3) (/ 1 3) (/ 1 3)) "equal widths")
      (check-equal! (map (lambda (k) (panes-window-mode l k)) (panes-top-windows l))
                    '("scheme-mode" "chat-mode" "text-mode") "each window of its buffer's mode"))))

(deftest 'a-layout-keeps-only-the-buffers-its-group-holds
  "a buffer the group does not hold leaves the layout, whatever window showed it; its emptied window closes and the pane stays"
  (lambda ()
    (let* ((l (pt-row "a.scm" "*chat*" "other.md"))
           (v (panes-validate l (lambda (b) (member b '("a.scm" "*chat*"))))))
      (check-equal! (panes-buffers v) '("a.scm" "*chat*") "only the group's buffers")
      (check-equal! (panes-pane-count v) 3 "every pane stays"))))

(deftest 'a-saved-layout-reads-back-with-its-windows-and-focus
  "a layout is plain data: what is saved is the layout itself, its windows, keys and focus with it"
  (lambda ()
    (let ((l (panes-set-focus (car (pt-open (pt-row "a.scm" "*chat*") "b.scm")) "p2")))
      (check-equal! (panes-strip-handles l) l "nothing is lost when it is saved")
      (check-equal! (panes-focus (panes-strip-handles l)) "p2" "the focus comes back")
      (check-true! (panes-layout? (panes-strip-handles l)) "and it reads as a layout"))))

(deftest 'a-window-key-is-its-frame-window-id
  "a window's key is the frame's id for it; a frame that gives another id rekeys it; a dead buffer leaves when the layout is checked"
  (lambda ()
    (let* ((o1 (pt-open (panes-empty 3) "old"))
           (o2 (pt-open (car o1) "other"))
           (k (cadr o1))
           (r (car o2))
           (h (panes-set-handle r k 42)))
      (check-equal! (panes-handle r k) k "the handle is the key")
      (check-equal! (panes-handle h 42) 42 "another id rekeys the window")
      (check-equal! (panes-handle h k) #f "the old key is gone")
      (check-equal! (panes-window-buffers (panes-validate h (lambda (b) (equal? b "other"))) 42) '("other") "a dead buffer leaves"))))

;;; --- consolidating ----------------------------------------------------------

(deftest 'consolidating-gives-every-mode-one-window
  "after a consolidate, each mode's window holds every buffer of that mode, a window of another mode keeps only its own, and a second consolidate changes nothing"
  (lambda ()
    (let* ((l (car (pt-open (pt-row "a.scm" "*chat*") "b.scm")))
           (ka (pt-window l "scheme-mode")) (kc (pt-window l "chat-mode"))
           (l (panes-move-buffer l "b.scm" kc))
           (c1 (panes-consolidate l pt-mode))
           (c2 (panes-consolidate c1 pt-mode)))
      (check-true! (and (member "a.scm" (panes-window-buffers c1 ka)) (member "b.scm" (panes-window-buffers c1 ka)) #t) "the scheme window holds every scheme buffer")
      (check-equal! (panes-window-buffers c1 kc) '("*chat*") "the chat window keeps only the chat")
      (check-equal! c2 c1 "a second consolidate changes nothing"))))

(deftest 'consolidating-sends-stray-buffers-home-from-a-window-on-screen
  "a window on screen of another mode keeps only the buffer it shows; a second window of a mode that is left empty closes"
  (lambda ()
    (let* ((l (pt-row "*todos*" "*list*"))
           (kt (car (panes-pane-keys l "p1"))) (kl (car (panes-pane-keys l "p2")))
           (l (panes-move-buffer l "*chat*" kt))
           (l (panes-move-buffer l "*chat2*" kl))
           (l (panes-move-buffer l "*dired*" kl))
           (l (panes-move-buffer l "*list*" kl))
           (mode-of (lambda (b) (cond ((string-prefix? "*chat" b) "chat-mode")
                                      ((equal? b "*todos*") "todo-mode")
                                      ((equal? b "*dired*") "dired-mode")
                                      (else "list-mode"))))
           (c1 (panes-consolidate l mode-of))
           (where (lambda (b) (filter (lambda (k) (member b (panes-window-buffers c1 k))) (panes-window-keys c1)))))
      (check-equal! (panes-window-buffers c1 kl) '("*list*") "the list window keeps only the list")
      (check-equal! (where "*chat*") (where "*chat2*") "the chats share one window")
      (check-equal! (length (filter (lambda (k) (equal? (panes-window-mode c1 k) "chat-mode")) (panes-window-keys c1))) 1 "one chat window"))))
