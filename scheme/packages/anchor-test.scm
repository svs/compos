;;; anchor-test.scm --- the walk, the ring, and the keymap at point.

(domain! 'testing)
(effects! '(write))

(define *t-anchor-buf* "*zz-anchor*")

;; four parts, the last one with keys of its own
(define (t--anchor-with thunk)
  (buffer-create *t-anchor-buf*)
  (buffer-set-text! *t-anchor-buf*
    "HEADER line\nTABS line\nAssessment body\nCandidate body\n")
  (define-keymap! "zz-anchor-map")
  (define-key "zz-anchor-map" "o" "anchor-next")
  (anchor-set! *t-anchor-buf*
    (list (list "header" 1 13)
          (list "tabs" 13 23)
          (list "assessment" 23 39)
          (list "candidate" 39 54 "zz-anchor-map" '(id "cand-1"))))
  (enable-minor-mode! *t-anchor-buf* "anchor-mode")
  (let ((out (with-current-buffer *t-anchor-buf* thunk)))
    (buffer-kill! *t-anchor-buf*)
    out))

(deftest 'anchors-sort-and-fill-in
  "a declaration is ordered by start and short forms take #f"
  (lambda ()
    (t--anchor-with
      (lambda ()
        (let ((as (anchor-list *t-anchor-buf*)))
          (check-equal! (map anchor-name as)
                        '("header" "tabs" "assessment" "candidate")
                        "in the order they appear")
          (check-false! (anchor-keymap (car as)) "an anchor may carry no map")
          (check-equal! (anchor-data (car (reverse as))) '(id "cand-1")
                        "and the page's own data comes back"))))))

(deftest 'anchor-at-is-the-innermost
  "a position answers with the anchor that starts last among those holding it"
  (lambda ()
    (t--anchor-with
      (lambda ()
        (check-equal! (anchor-name (anchor-at *t-anchor-buf* 1)) "header" "the first byte")
        (check-equal! (anchor-name (anchor-at *t-anchor-buf* 12)) "header" "its last byte")
        (check-equal! (anchor-name (anchor-at *t-anchor-buf* 13)) "tabs" "end is exclusive")
        (anchor-add! *t-anchor-buf* "title" 1 7)
        (check-equal! (anchor-name (anchor-at *t-anchor-buf* 3)) "title"
                      "a nested anchor wins inside its range")
        (check-equal! (anchor-name (anchor-at *t-anchor-buf* 9)) "header"
                      "and the outer one answers outside it")))))

(deftest 'anchor-walk-is-a-ring
  "TAB goes down the anchors and comes back to the first"
  (lambda ()
    (t--anchor-with
      (lambda ()
        (goto-char! 1)
        (check-equal! (run-command "anchor-next") 13 "header to tabs")
        (check-equal! (run-command "anchor-next") 23 "tabs to assessment")
        (check-equal! (run-command "anchor-next") 39 "assessment to candidate")
        (check-equal! (run-command "anchor-next") 1 "the last one wraps")
        (check-equal! (run-command "anchor-previous") 39 "and back the other way")))))

(deftest 'anchor-walk-stops-without-wrap
  "anchor-wrap #f leaves point where it is at the end"
  (lambda ()
    (let ((saved anchor-wrap))
      (set! anchor-wrap #f)
      (t--anchor-with
        (lambda ()
          (goto-char! 39)
          (check-false! (run-command "anchor-next") "no next anchor")
          (check-equal! (buffer-point *t-anchor-buf*) 39 "and point did not move")))
      (set! anchor-wrap saved))))

(deftest 'the-anchor-at-point-owns-the-keys
  "the anchor's keymap is in force inside it and gone outside it"
  (lambda ()
    (t--anchor-with
      (lambda ()
        (goto-char! 40)
        (anchor-sync! *t-anchor-buf*)
        (check-equal! (buffer-at-point-map *t-anchor-buf*) "zz-anchor-map"
                      "the candidate anchor's map")
        (check-equal! (car (buffer-keymaps *t-anchor-buf*)) "zz-anchor-map"
                      "ahead of the buffer's own maps")
        (goto-char! 2)
        (anchor-sync! *t-anchor-buf*)
        (check-false! (buffer-at-point-map *t-anchor-buf*)
                      "an anchor with no map of its own clears it")))))

(deftest 'the-current-anchor-is-highlighted
  "the overlay follows point and goes when the mode does"
  (lambda ()
    (t--anchor-with
      (lambda ()
        (goto-char! 40)
        (anchor-sync! *t-anchor-buf*)
        (check-equal! (buffer-overlays *t-anchor-buf* 'anchor)
                      '((39 54 "anchor-current")) "the candidate range")
        (disable-minor-mode! *t-anchor-buf* "anchor-mode")
        (check-equal! (buffer-overlays *t-anchor-buf* 'anchor) '()
                      "turning the mode off takes it away")
        (check-false! (buffer-at-point-map *t-anchor-buf*) "and the keymap with it")))))

(deftest 'a-redraw-redeclares
  "anchor-set! replaces the old offsets outright, and a name comes back"
  (lambda ()
    (t--anchor-with
      (lambda ()
        (anchor-set! *t-anchor-buf*
          (list (list "header" 1 20) (list "candidate" 20 54 "zz-anchor-map")))
        (check-equal! (map anchor-name (anchor-list *t-anchor-buf*))
                      '("header" "candidate") "only the new anchors")
        (check-equal! (anchor-goto! *t-anchor-buf* "candidate") 20
                      "and a name still finds its part")
        (check-false! (anchor-goto! *t-anchor-buf* "tabs")
                      "a name that is gone lands nowhere")))))

(deftest 'a-block-page-marks-the-block-of-the-anchor
  "on a page drawn as blocks, the outermost block spanning the anchor carries anchor-current"
  (lambda ()
    (let ((buf "*zz-anchor-blocks*"))
      (buffer-create buf)
      (buffer-set-text! buf "one\ntwo\nthree" #t)
      (buffer-set-locals! buf
        (list 'render-mode "blocks"
              'render-blocks (list (list 'tag "div" 'class "a" 'lines '(1 1))
                                   (list 'tag "div" 'class "b" 'lines '(2 3)
                                         'children (list (list 'tag "div" 'class "c" 'lines '(2 3)))))))
      (anchor-set! buf (list (list "b" 4 13)))
      (buffer-goto! buf 5)
      (anchor-sync! buf)
      (let ((blocks (buffer-local buf 'render-blocks)))
        (check-equal! (plist-get (car blocks) 'class) "a" "the other block")
        (check-equal! (plist-get (cadr blocks) 'class) "b anchor-current anchor-top" "the outermost, and the page's top part")
        (check-equal! (plist-get (car (plist-get (cadr blocks) 'children)) 'class) "c" "not the inner one"))
      (buffer-goto! buf 0)
      (anchor-sync! buf)
      (check-equal! (plist-get (cadr (buffer-local buf 'render-blocks)) 'class) "b" "off when point leaves")
      (buffer-kill! buf))))

(deftest 'anchor-mode-gives-imenu-its-parts
  "with anchor-mode on, imenu lists the anchors; off, the buffer's own index again"
  (lambda ()
    (let ((buf "*zz-anchor-imenu*"))
      (buffer-create buf)
      (buffer-set-text! buf "one\ntwo\nthree" #t)
      (enable-minor-mode! buf "anchor-mode")
      (anchor-set! buf (list (list "two" 4 7) (list "three" 8 13)))
      (check-equal! (imenu-rows buf) '((2 "" "two" "") (3 "" "three" "")) "the parts")
      (disable-minor-mode! buf "anchor-mode")
      (check-equal! (buffer-local buf 'imenu-index-function) #f "off again")
      (buffer-kill! buf))))
