;;; display-buffer-test.scm --- where a buffer goes: the action chain.
;;;
;;; display-buffer tries the rule for the name, the base action, then the
;;; fallback: reuse-window, pop-up-window, use-some-window, same-window.
;;; The thresholds decide a split; the tests set them, so the frame's
;;; size does not.

(domain! 'testing)
(effects! '(write display))

(define t--db-dir (string-append (compos-home) "/display-test"))

(define (t--db-file name text)
  (let ((p (string-append t--db-dir "/" name)))
    (write-file! p text)
    p))

;; one window on *scratch*, the stock rules, the thresholds of the test;
;; everything put back after
(define (t--db-with thresholds thunk)
  (make-directory! t--db-dir)
  (let ((rules *display-buffer-alist*)
        (base *display-buffer-base-action*)
        (h split-height-threshold)
        (w split-width-threshold))
    (set! split-height-threshold (car thresholds))
    (set! split-width-threshold (cadr thresholds))
    (set! *display-buffer-base-action* '())
    (switch-to-buffer! "*scratch*")
    (run-command "delete-other-windows")
    (when (popup-open?) (popup-close!))
    (let ((out (thunk)))
      (for-each (lambda (b)
                  (when (or (string-prefix? "*zz-db" b) (string-prefix? t--db-dir b))
                    (buffer-kill! b)))
                (buffer-list))
      (set! *display-buffer-alist* rules)
      (set! *display-buffer-base-action* base)
      (set! split-height-threshold h)
      (set! split-width-threshold w)
      (set! *peek-recent* '())
      (switch-to-buffer! "*scratch*")
      (run-command "delete-other-windows")
      out)))

(define t--db-wide '(1000 1))     ; beside always, below never
(define t--db-tall '(1 1000))     ; below always
(define t--db-never '(1000 1000)) ; no split by size

(define (t--db-rect win) (assoc win (window-rects)))

(deftest 'a-buffer-with-no-rule-takes-the-fallback-chain
  "the chain is reuse, pop-up, use-some, same; a rule's action goes first"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (check-equal! (display-buffer-actions-for "*zz-db-none*")
                      '(reuse-window pop-up-window use-some-window same-window)
                      "the fallback")
        (check-equal! (car (display-buffer-actions-for "*Messages*")) 'popup
                      "a name rule first")
        (check-equal! (car (display-buffer-actions-for "*zz-db-none*" '(category preview)))
                      'popup "the preview category first")
        (set! *display-buffer-base-action* '(same-window))
        (check-equal! (car (display-buffer-actions-for "*zz-db-none*")) 'same-window
                      "with no rule the base action comes first")
        (check-equal! (cadr (display-buffer-actions-for "*zz-db-none*")) 'reuse-window
                      "and the fallback after it")
        (check-equal! (car (display-buffer-actions-for "*Messages*")) 'popup
                      "a rule still comes before the base action")))))

(deftest 'pop-up-window-splits-beside-and-selects-nothing
  "one wide window: the buffer takes a new window beside it; point stays"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (let ((me (active-window)))
          (buffer-create "*zz-db-a*")
          (let ((win (display-buffer "*zz-db-a*")))
            (check-equal! (length (window-list)) 2 "two windows")
            (check-equal! (active-window) me "the selected window did not change")
            (check-equal! (current-buffer) "*scratch*" "nor the current buffer")
            (check-equal! (window-buffer win) "*zz-db-a*" "the new window shows it")
            (check-true! (not (equal? win me)) "and it is not the selected one")
            (check-equal! (nth 3 (t--db-rect win)) (nth 3 (t--db-rect me)) "beside: the same top")
            (check-true! (> (nth 2 (t--db-rect win)) (nth 2 (t--db-rect me))) "to the right")
            (check-equal! (cadr (window-quit-restore win)) 'window "noted as a window the display made")))))))

(deftest 'pop-up-window-splits-below-when-the-window-is-tall
  "the height threshold wins over the width one, as in Emacs"
  (lambda ()
    (t--db-with t--db-tall
      (lambda ()
        (let ((me (active-window)))
          (buffer-create "*zz-db-a*")
          (let ((win (display-buffer "*zz-db-a*")))
            (check-equal! (length (window-list)) 2 "two windows")
            (check-equal! (nth 2 (t--db-rect win)) (nth 2 (t--db-rect me)) "below: the same left")
            (check-true! (> (nth 3 (t--db-rect win)) (nth 3 (t--db-rect me))) "under it")))))))

(deftest 'the-sole-window-splits-below-whatever-its-size
  "no threshold is met, but a frame with one window still gets a second"
  (lambda ()
    (t--db-with t--db-never
      (lambda ()
        (let ((me (active-window)))
          (buffer-create "*zz-db-a*")
          (let ((win (display-buffer "*zz-db-a*")))
            (check-equal! (length (window-list)) 2 "two windows")
            (check-true! (> (nth 3 (t--db-rect win)) (nth 3 (t--db-rect me))) "the new one below")))))))

(deftest 'reuse-window-finds-the-window-that-shows-it
  "a second display of the same buffer makes no window"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (buffer-create "*zz-db-a*")
        (let ((first (display-buffer "*zz-db-a*")))
          (check-equal! (display-buffer "*zz-db-a*") first "the same window")
          (check-equal! (length (window-list)) 2 "still two"))))))

(deftest 'use-some-window-takes-another-window-when-no-split-fits
  "two windows, no room to split: the other window shows it, and quit puts back what it showed"
  (lambda ()
    (t--db-with t--db-never
      (lambda ()
        (let ((me (active-window)))
          (buffer-create "*zz-db-a*")
          (buffer-create "*zz-db-b*")
          (let ((other (display-buffer "*zz-db-a*")))
            (check-equal! (length (window-list)) 2 "the sole window split once")
            (let ((win (display-buffer "*zz-db-b*")))
              (check-equal! win other "the other window is used")
              (check-equal! (length (window-list)) 2 "no third window")
              (check-equal! (window-buffer other) "*zz-db-b*" "and shows the second buffer")
              (check-equal! (active-window) me "point stays")
              (check-equal! (cadr (window-quit-restore win)) 'other "noted as a window the display took")
              (check-equal! (caddr (window-quit-restore win)) "*zz-db-a*" "with what it showed")
              (window-quit-restore! win)
              (check-equal! (window-buffer other) "*zz-db-a*" "quit puts the first buffer back"))))))))

(deftest 'same-window-is-the-last-resort-and-inhibit-keeps-it-out
  "with the same window inhibited and nothing else, the display fails rather than covers"
  (lambda ()
    (t--db-with t--db-never
      (lambda ()
        (set! *display-buffer-alist* (list (list "*zz-db" 'same-window '())))
        (buffer-create "*zz-db-a*")
        (let ((me (active-window)))
          (check-equal! (display-buffer "*zz-db-a*") me "a same-window rule shows it here")
          (check-equal! (current-buffer) "*zz-db-a*" "and it is current")
          (check-equal! (length (window-list)) 1 "no split"))
        (set! *display-buffer-alist* (list (list "*zz-db" '(same-window) '())))
        (set! *display-buffer-fallback-action* '())
        (buffer-create "*zz-db-b*")
        (check-false! (display-buffer "*zz-db-b*" '(inhibit-same-window #t))
                      "inhibited, with no other action, there is no window")
        (set! *display-buffer-fallback-action*
              '(reuse-window pop-up-window use-some-window same-window))))))

(deftest 'pop-to-buffer-shows-and-selects
  "display-buffer selects nothing; pop-to-buffer selects the window it used"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (let ((me (active-window)))
          (buffer-create "*zz-db-a*")
          (let ((win (pop-to-buffer "*zz-db-a*")))
            (check-equal! (active-window) win "the new window is selected")
            (check-true! (not (equal? win me)) "and it is another window")
            (check-equal! (current-buffer) "*zz-db-a*" "the buffer is current")))))))

(deftest 'quit-window-deletes-the-window-the-display-made
  "q in a popped-up listing closes its window and kills it; the layout is what it was"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (let ((me (active-window)))
          (buffer-create "*zz-db-a*")
          (pop-to-buffer "*zz-db-a*")
          (run-command "quit-window")
          (check-equal! (length (window-list)) 1 "one window again")
          (check-equal! (active-window) me "the one the reader had")
          (check-false! (buffer-exists? "*zz-db-a*") "the listing is killed"))))))

(deftest 'display-buffer-other-window-never-covers-the-selected-window
  "with two windows and no room, the other window is used, never this one"
  (lambda ()
    (t--db-with t--db-never
      (lambda ()
        (let ((me (active-window)))
          (buffer-create "*zz-db-a*")
          (buffer-create "*zz-db-b*")
          (display-buffer "*zz-db-a*")
          (let ((win (display-buffer-other-window! "*zz-db-b*")))
            (check-true! (not (equal? win me)) "another window")
            (check-equal! (window-buffer me) "*scratch*" "this one still shows scratch")
            (check-equal! (active-window) me "and is still selected")))))))

(deftest 'a-name-rule-for-the-popup-still-wins
  "the side window rule is a rule like any other, first in the chain"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (buffer-create "*zz-db-side*")
        (add-display-rule! "*zz-db-side*" 'popup)
        (display-buffer "*zz-db-side*")
        (check-true! (popup-open?) "the popup opened")
        (check-equal! (popup-buffer) "*zz-db-side*" "with the buffer")
        (popup-close!)))))

(deftest 'a-peek-follows-the-preview-rule
  "by the stock rule a peek is in the popup; a rule of your own sends it through the chain"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (let ((a (t--db-file "a.txt" "alpha\n"))
              (b (t--db-file "b.txt" "beta\n"))
              (me (active-window)))
          (peek-file! a)
          (check-true! (popup-open?) "stock: the peek is in the popup")
          (check-equal! (popup-buffer) a "showing the file")
          (peek-dismiss!)
          (check-false! (popup-open?) "dismissed")
          (add-display-rule! '(category preview) 'pop-up-window)
          (peek-file! a)
          (check-false! (popup-open?) "the rule: no popup")
          (check-equal! (length (window-list)) 2 "a window beside")
          (check-equal! (active-window) me "point stays")
          (check-true! (peek-buffer? a) "it is a peek")
          (let ((win (window-showing a)))
            (check-true! (and win (not (equal? win me))) "in the other window")
            (peek-file! b)
            (check-equal! (length (window-list)) 2 "the next peek takes the same window")
            (check-equal! (window-buffer win) b "and shows the second file")
            (check-false! (buffer-exists? a) "the first peek is gone")
            (check-equal! (active-window) me "point still stays"))
          (peek-dismiss!)
          (check-equal! (length (window-list)) 1 "dismissed: the window the peek made is gone")
          (check-false! (buffer-exists? b) "and the peek with it"))))))
