;;; canvas-overview-test.scm --- spatial overview snapshot, hidden panes,
;;; pane swap/shift commands, and bridge tests.

(require 'canvas-overview)

(domain! 'testing)
(effects! '(read))

(deftest 'canvas-overview-snapshot-encodes-cleanly
  "canvas-overview-snapshot produces a valid JSON snapshot with theme, panes, and hiddenPanes"
  (lambda ()
    (let* ((snap (canvas-overview-snapshot))
           (json (json-encode snap))
           (back (json-parse json)))
      (check-true! (number? (plist-get back 'rev)) "rev is numeric")
      (check-true! (list? (plist-get back 'groups)) "groups is a list")
      (check-true! (string? (plist-get (plist-get back 'theme) 'bg)) "theme includes bg")
      (check-true! (and (command-function "overview") #t) "M-x overview command exists"))))

(deftest 'canvas-overview-hidden-pane-data-resolves-windows-and-buffers
  "hidden panes serialize with their window keys, buffer names, and previews"
  (lambda ()
    (let* ((b1 (test-buffer! "*zz-ov-p1*" "pane one text\n"))
           (b2 (test-buffer! "*zz-ov-p2*" "pane two hidden text\n"))
           (l0 (panes-empty 3))
           (a1 (panes-add-pane l0)) (l1 (car a1)) (p1 (cadr a1))
           (a2 (panes-add-pane l1)) (l2 (car a2)) (p2 (cadr a2))
           (w1 (panes-add-window l2 p1 b1 "fundamental-mode"))
           (w2 (panes-add-window (car w1) p2 b2 "fundamental-mode"))
           (hl (panes-hide-pane (car w2) p2))
           (hdata (map canvas-overview--hidden-pane-data (panes-hidden hl)))
           (hp (car hdata))
           (hw (car (plist-get hp 'windows))))
      (check-equal! (length hdata) 1 "one hidden pane")
      (check-true! (plist-get hp 'hidden) "marked hidden")
      (check-equal! (plist-get hw 'buffer) b2 "hidden window buffer resolved")
      (check-true! (string-contains? (plist-get (plist-get hw 'preview) 'text) "pane two hidden") "hidden window preview populated")
      (buffer-kill! b1)
      (buffer-kill! b2))))

(deftest 'canvas-overview-preview-reads-lines-and-metadata
  "canvas-overview--buffer-preview reads lines around point and reports metadata"
  (lambda ()
    (let ((buf (test-buffer! "*zz-canvas-preview*" "line one\nline two\nline three\n")))
      (let ((p (canvas-overview--buffer-preview buf 10)))
        (check-equal! (plist-get p 'name) buf "name matches")
        (check-true! (string-contains? (plist-get p 'text) "line two") "preview includes text")
        (check-equal! (plist-get p 'pointLine) 2 "pointLine matches byte offset"))
      (buffer-kill! buf))))

(deftest 'canvas-overview-app-request-serves-snapshot-and-watches
  "app-request answers GET snapshot and POST watch and cleans up watches"
  (lambda ()
    (let ((buf (test-buffer! "*zz-canvas-watch*" "hello world\n")))
      (let* ((get-res (canvas-overview--app-request *canvas-overview-buffer* "GET" ""))
             (watch-body (json-encode (list 'op "watch" 'buffers (list buf))))
             (watch-res (canvas-overview--app-request *canvas-overview-buffer* "POST" watch-body))
             (parsed (json-parse (cadr watch-res))))
        (check-equal! (car get-res) 200 "GET returns 200")
        (check-equal! (car watch-res) 200 "POST watch returns 200")
        (check-true! (plist-get parsed 'ok) "watch reports ok")
        (check-true! (pair? (plist-get parsed 'buffers)) "watch returns buffer preview")
        (check-true! (and (assoc buf *canvas-overview-watches*) #t) "watch registered on buffer"))
      (canvas-overview--unwatch-all!)
      (check-equal! *canvas-overview-watches* '() "unwatch releases every watch")
      (buffer-kill! buf))))

(deftest 'canvas-overview-mode-configures-app-render-mode
  "canvas-overview-mode sets app render-mode and links external JS and CSS"
  (lambda ()
    (let ((buf (test-buffer! "*zz-canvas-mode*" "")))
      (with-current-buffer buf (lambda () (set-mode! "canvas-overview-mode")))
      (check-equal! (buffer-local-value 'render-mode buf) "app" "render-mode is app")
      (check-true! (string-contains? (buffer-text buf) "canvas-overview.js") "links external JS")
      (check-true! (string-contains? (buffer-text buf) "canvas-overview.css") "links external CSS")
      (check-true! (pair? (buffer-local-value 'app-directory buf)) "sets app-directory")
      (buffer-kill! buf))))

(deftest 'canvas-overview-pane-commands-work-on-model-while-active
  "pane swap, window shift, focus, hide, restore, and hidden swap edit the layout while overview is active"
  (lambda ()
    (let* ((b1 (test-buffer! "*zz-ov-m1*" "one\n"))
           (b2 (test-buffer! "*zz-ov-m2*" "two\n"))
           (b3 (test-buffer! "*zz-ov-m3*" "three\n"))
           (saved-layout (panes-layout))
           (saved-open *canvas-overview-open?*))
      (unwind-protect
        (lambda ()
          ;; Build a 3-pane model and open overview fullscreen over it.
          (let* ((l0 (panes-empty 3))
                 (a1 (panes-add-pane l0)) (l1 (car a1)) (p1 (cadr a1))
                 (a2 (panes-add-pane l1)) (l2 (car a2)) (p2 (cadr a2))
                 (a3 (panes-add-pane l2)) (l3 (car a3)) (p3 (cadr a3))
                 (w1 (panes-add-window l3 p1 b1 "fundamental-mode"))
                 (w2 (panes-add-window (car w1) p2 b2 "fundamental-mode"))
                 (w3 (panes-add-window (car w2) p3 b3 "fundamental-mode"))
                 (l (panes-set-focus (car w3) p1)))
            (panes-layout-set! l)
            (overview!)
            (check-true! (canvas-overview--active?) "overview is active fullscreen")
            (check-equal! (length (window-list)) 1 "frame shows one fullscreen canvas window")
            ;; Focus right -> p2
            (run-command "focus-right")
            (check-equal! (panes-focus (panes-layout)) p2 "focus-right selects p2")
            ;; Swap pane left -> p2 trades windows with p1, focus follows to p1
            (run-command "pane-move-left")
            (check-equal! (panes-focus (panes-layout)) p1 "pane-move-left moves focus to p1")
            (let* ((l-after (panes-layout))
                   (k1 (car (panes-pane-keys l-after p1)))
                   (k2 (car (panes-pane-keys l-after p2))))
              (check-equal! (panes-window-buffer l-after k1) b2 "p1 now holds b2")
              (check-equal! (panes-window-buffer l-after k2) b1 "p2 now holds b1"))
            ;; Shift window right -> b2 moves into p2's stack ahead of b1
            (run-command "window-next-pane")
            (let ((l-shift (panes-layout)))
              (check-equal! (panes-focus l-shift) p2 "window-next-pane moves focus to p2")
              (check-equal! (length (panes-pane-keys l-shift p2)) 2 "p2 now holds 2 stacked windows"))
            ;; Hide p2 -> appears in panes-hidden
            (run-command "pane-remove")
            (check-equal! (length (panes-hidden (panes-layout))) 1 "pane-remove hides p2")
            ;; Restore hidden pane -> back in visible panes
            (run-command "pane-restore")
            (check-equal! (length (panes-hidden (panes-layout))) 0 "pane-restore brings p2 back")
            ;; Quit overview -> restores frame from edited model
            (canvas-overview-quit!)
            (check-false! (canvas-overview--active?) "overview exited cleanly")))
        (lambda ()
          (set! *canvas-overview-open?* saved-open)
          (when (buffer-known? *canvas-overview-buffer*)
            (ignore-errors (lambda () (buffer-kill! *canvas-overview-buffer*))))
          (when saved-layout (ignore-errors (lambda () (panes-apply! saved-layout))))
          (buffer-kill! b1)
          (buffer-kill! b2)
          (buffer-kill! b3))))))
