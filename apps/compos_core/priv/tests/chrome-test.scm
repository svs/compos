;;; chrome-test.scm --- the browser side of C-x b, without a browser.
;;;
;;; A tab you can switch to belongs in the same list as the buffers. What
;;; the editor decides — which tabs are beside you, what a tab's label is,
;;; what order the list comes in — is Scheme, and needs no extension
;;; attached.
;;;
;;; The wire itself stays in ExUnit: those tests attach a stub socket
;;; process and assert on the frames the daemon pushes to it, which is
;;; message passing and not policy. So does the one that splits the frame
;;; and looks for the window showing a buffer — how a split lands differs
;;; between a live frame and a test one, the same reason notmuch's
;;; two-pane tests stayed.

(domain! 'testing)
(effects! '(read))

(define t--chrome-tabs
  '((id 7 title "Hacker News" url "https://news.ycombinator.com/" window 1)
    (id 8 title "Luma" url "https://luma.com/" window 2)))

(effects! '(write))

;; The frame locals are the person's own browser state. Put them back.
(define (t--chrome-with-frame thunk)
  (let ((win (frame-local 'chrome-window))
        (visit (frame-local 'chrome-tab-visit)))
    (let ((out (thunk)))
      (set-frame-local! 'chrome-window win)
      (set-frame-local! 'chrome-tab-visit visit)
      out)))

(deftest 'the-chord-handler-names-the-keys-it-would-dispatch
  "the formatting half, with no dispatcher involved"
  (lambda ()
    (check-equal! (chrome--get (chrome--chord '()) 'message) "" "no keys, nothing to say")))

(deftest 'a-buffer-that-is-not-on-screen-has-no-window-to-go-to
  "the answer is #f, so the caller opens one instead of guessing"
  (lambda ()
    (test-buffer! "*zz-off-screen*" "")
    (check-false! (chrome--window-showing "*zz-off-screen*") "nothing shows it")
    (buffer-kill! "*zz-off-screen*")))

(deftest 'tabs-in-this-window-become-candidates-marked-with-a-globe
  "C-x b offers what is beside you, not every tab in the browser"
  (lambda ()
    (t--chrome-with-frame
      (lambda ()
        (check-equal! (car (chrome--tab-candidate (car t--chrome-tabs)))
                      "🌐 Hacker News" "the label carries a globe")

        ;; only this browser window's tabs
        (set-frame-local! 'chrome-window 1)
        (check-equal! (length (chrome--here-tabs t--chrome-tabs)) 1 "one tab is beside us")

        ;; and the label round-trips back to the tab it names
        (check-equal! (chrome--get (chrome--tab-by-label "🌐 Luma" t--chrome-tabs) 'id) 8
                      "the label finds its tab")
        (check-false! (chrome--tab-by-label "*scratch*" t--chrome-tabs)
                      "and a buffer name finds none")))))

(deftest 'buffers-keep-the-editors-order-and-a-tab-leads-only-while-it-is-latest
  "the editor's own MRU ring is the truth; a second history here drifted"
  (lambda ()
    ;; Buffers are not tracked here at all — buffer-list-mru is the
    ;; editor's ring, updated wherever a buffer is displayed. The only
    ;; fact kept is the tab you were last in and the ring's head at that
    ;; moment; if the head has not moved, nothing has been displayed since
    ;; and the tab still leads.
    (t--chrome-with-frame
      (lambda ()
        (let ((bufs '(("*a*" "") ("*b*" "")))
              (tabs '(("🌐 News" ""))))
          (set-frame-local! 'chrome-tab-visit #f)
          (check-equal! (map car (chrome--order bufs tabs))
                        '("*a*" "*b*" "🌐 News") "with no tab visit, the buffers lead")

          ;; a keypress in the tab: it is now the most recent place
          (chrome--note-tab! "🌐 News")
          (check-true! (chrome--tab-is-latest?) "the tab is the latest place")
          (check-equal! (map car (chrome--order bufs tabs))
                        '("🌐 News" "*a*" "*b*") "so it leads the list")

          ;; display a buffer and the ring's head moves, so the tab is
          ;; stale — the editor's own ring invalidates it, with no
          ;; bookkeeping here
          (test-buffer! "*zz-ring-moved*" "")
          (switch-to-buffer! "*zz-ring-moved*")
          (check-false! (chrome--tab-is-latest?) "the tab is no longer latest")
          (check-equal! (map car (chrome--order bufs tabs))
                        '("*a*" "*b*" "🌐 News") "and the buffers lead again")
          (buffer-kill! "*zz-ring-moved*"))))))
