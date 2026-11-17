;;; tree-edit-test.scm --- the selection, the moves and the narrowing.

(define (te-test--buffer name mode text)
  (when (buffer-known? name) (buffer-kill! name))
  (buffer-create name)
  (buffer-append! name text)
  (with-current-buffer name (lambda () (set-mode! mode)))
  name)

(define (te-test--at name pos fn)
  (with-current-buffer name
    (lambda ()
      (enable-minor-mode! name "tree-edit-mode")
      (tree-edit--select! (tree-edit--unit-at pos))
      (fn))))

(define (te-test--node name) (buffer-local-value 'tree-edit-node name))

(deftest 'tree-edit-moves-html-elements
  "siblings, parent and child select whole elements; swap, lift and sink move them"
  (lambda ()
    (let ((b (te-test--buffer "*tree-edit-test-html*" "html-mode"
               "<div>\n  <p>one</p>\n  <p>two <b>x</b></p>\n</div>\n")))
      (te-test--at b 9
        (lambda ()
          (check-equal! (te-test--node b) '("element" 8 18) "the element at point")
          (check-equal! (list (point) (mark)) '(8 18) "the region is the element")
          (run-command "tree-edit-next")
          (check-equal! (te-test--node b) '("element" 21 40) "the next element, not its tags")
          (run-command "tree-edit-parent")
          (check-equal! (te-test--node b) '("element" 0 47) "the parent")
          (run-command "tree-edit-child")
          (check-equal! (te-test--node b) '("element" 8 18) "the first child skips the start tag")
          (run-command "tree-edit-swap-next")
          (check-equal! (buffer-text b) "<div>\n  <p>two <b>x</b></p>\n  <p>one</p>\n</div>\n" "swapped")
          (check-equal! (te-test--node b) '("element" 30 40) "the moved element stays selected")
          (undo!)
          (tree-edit--select! (tree-edit--unit-at 29))
          (run-command "tree-edit-lift")
          (check-equal! (buffer-text b) "<div>\n  <p>one</p>\n  <b>x</b>\n  <p>two</p>\n</div>\n" "lifted before its parent")
          (undo!)
          (tree-edit--select! (tree-edit--unit-at 9))
          (run-command "tree-edit-sink")
          (check-equal! (buffer-text b) "<div>\n  <p><p>one</p>two <b>x</b></p>\n</div>\n" "moved into the next element")))
      (buffer-kill! b))))

(deftest 'tree-edit-stays-inside-the-narrowing
  "a narrowed node is the edge: no sibling or parent outside it"
  (lambda ()
    (let ((b (te-test--buffer "*tree-edit-test-narrow*" "html-mode"
               "<div>\n  <p>one</p>\n  <p>two <b>x</b></p>\n</div>\n")))
      (te-test--at b 22
        (lambda ()
          (run-command "tree-edit-narrow")
          (check-equal! (buffer-narrow-range b) '(21 40) "narrowed to the element")
          (run-command "tree-edit-prev")
          (check-equal! (te-test--node b) '("element" 21 40) "no sibling outside")
          (run-command "tree-edit-parent")
          (check-equal! (te-test--node b) '("element" 21 40) "no parent outside")
          (run-command "tree-edit-child")
          (run-command "tree-edit-next")
          (check-equal! (te-test--node b) '("element" 28 36) "inside moves still work")
          (buffer-widen! b)))
      (buffer-kill! b))))

(deftest 'tree-edit-lends-morg-the-markdown-grammar
  "a Morg buffer moves by sections, keeps its blank lines and its own faces"
  (lambda ()
    (let ((b (te-test--buffer "*tree-edit-test-morg*" "morg-mode"
               "# A\n\ntext a\n\n# C\n\nmore\n")))
      (te-test--at b 0
        (lambda ()
          (check-equal! (buffer-local-value 'ts-lang b) "markdown" "the grammar is lent")
          (check-equal! (buffer-local-value 'ts-faces b) #f "without its colours")
          (run-command "tree-edit-parent")
          (check-equal! (car (te-test--node b)) "section" "the section")
          (run-command "tree-edit-swap-next")
          (check-equal! (buffer-text b) "# C\n\nmore\n\n# A\n\ntext a\n" "the blank lines stay put")
          (disable-minor-mode! b "tree-edit-mode")
          (check-equal! (buffer-local-value 'ts-lang b) #f "the grammar goes back")))
      (buffer-kill! b))))
