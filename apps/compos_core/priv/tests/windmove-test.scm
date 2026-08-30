;;; windmove-test.scm --- geometric window motion, and the swap that carries a buffer.
;;;
;;; windmove! selects the neighbor in a direction; window-swap! trades
;;; buffers with that neighbor and follows the buffer. Both read
;;; window-rects, so the tests read the same rects to name the two panes.
;;; No test here names a key: the commands are the behaviour.

(domain! 'testing)
(effects! '(write))

(define t--wm-left "*zz-wm-left*")
(define t--wm-right "*zz-wm-right*")

;; Two panes side by side: t--wm-left in the left pane, t--wm-right in the
;; right pane, the left pane active. Returns (LEFT-ID RIGHT-ID).
(define (t--wm-setup!)
  (delete-other-windows!)
  (test-buffer! t--wm-left "left")
  (test-buffer! t--wm-right "right")
  (switch-to-buffer! t--wm-left)
  (split-window! 'h 0.5)
  (let* ((rs (window-rects))
         (a (car rs)) (b (cadr rs))
         (left (if (< (list-ref a 2) (list-ref b 2)) a b))
         (right (if (equal? left a) b a)))
    (select-window! (car right))
    (switch-to-buffer! t--wm-right)
    (select-window! (car left))
    (switch-to-buffer! t--wm-left)
    (list (car left) (car right))))

(define (t--wm-done!)
  (delete-other-windows!)
  (buffer-kill! t--wm-left)
  (buffer-kill! t--wm-right))

(deftest 'windmove-selects-the-neighbor-and-comes-back
  "windmove! right selects the right pane; windmove! left returns to the left pane"
  (lambda ()
    (let ((panes (t--wm-setup!)))
      (windmove! 'right)
      (check-equal! (active-window) (cadr panes) "the right pane is active")
      (check-equal! (current-buffer) t--wm-right "the right pane's buffer is current")
      (windmove! 'left)
      (check-equal! (active-window) (car panes) "the left pane is active again")
      (check-equal! (current-buffer) t--wm-left "the left pane's buffer is current")
      (t--wm-done!))))

(deftest 'windmove-commands-are-the-motion-by-name
  "run-command windmove-right and windmove-left move between the panes, with no key"
  (lambda ()
    (let ((panes (t--wm-setup!)))
      (run-command "windmove-right")
      (check-equal! (active-window) (cadr panes) "windmove-right selects the right pane")
      (run-command "windmove-left")
      (check-equal! (active-window) (car panes) "windmove-left selects the left pane")
      (t--wm-done!))))

(deftest 'windmove-chord-spells-emacs-modifiers-as-key-specs
  "windmove-chord turns Emacs modifier symbols into this keymap's spelling"
  (lambda ()
    (check-equal! (windmove-chord #f "<left>") "S-<left>" "no modifier means shift")
    (check-equal! (windmove-chord 'super "<up>") "s-<up>" "one symbol")
    (check-equal! (windmove-chord '(shift super) "<right>") "s-S-<right>" "a list, in the keymap's order")
    (check-equal! (windmove-chord '(control meta) "<down>") "C-M-<down>" "control before meta")))

;; The installer is tested on a chord no production keymap uses, and the
;; test removes what it installs.
(define t--wm-test-mods '(control meta super shift))

(deftest 'windmove-default-keybindings-installs-the-four-arrows
  "windmove-default-keybindings binds each arrow under MODIFIERS to its windmove command"
  (lambda ()
    (windmove-default-keybindings t--wm-test-mods)
    (check-equal! (key-binding (windmove-chord t--wm-test-mods "<left>")) "windmove-left" "left")
    (check-equal! (key-binding (windmove-chord t--wm-test-mods "<down>")) "windmove-down" "down")
    (windmove-swap-states-default-keybindings t--wm-test-mods)
    (check-equal! (key-binding (windmove-chord t--wm-test-mods "<right>"))
                  "windmove-swap-states-right" "the swap installer replaces the same chord")
    (for-each (lambda (dir) (global-unset-key (windmove-chord t--wm-test-mods (string-append "<" dir ">"))))
              '("left" "right" "up" "down"))
    (check-false! (key-binding (windmove-chord t--wm-test-mods "<left>")) "the test chord is free again")))

(deftest 'windmove-stays-put-at-the-edge
  "windmove! toward no neighbor leaves the active window as it is"
  (lambda ()
    (let ((panes (t--wm-setup!)))
      (check-false! (window-in-direction 'left) "nothing is left of the left pane")
      (windmove! 'left)
      (check-equal! (active-window) (car panes) "the left pane stays active")
      (check-equal! (current-buffer) t--wm-left "its buffer stays current")
      (t--wm-done!))))

(deftest 'window-swap-carries-the-buffer-and-follows-it
  "window-swap! right moves this buffer into the right pane, brings the right pane's buffer here, and selects the right pane"
  (lambda ()
    (let ((panes (t--wm-setup!)))
      (window-swap! 'right)
      (check-equal! (active-window) (cadr panes) "the right pane is active")
      (check-equal! (current-buffer) t--wm-left "the buffer came along")
      (check-equal! (window-buffer (car panes)) t--wm-right "the left pane holds the other buffer")
      (t--wm-done!))))
