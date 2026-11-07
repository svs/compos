;;; list-nest-test.scm --- a nested list puts each child under its parent, and the draw memo ends with the draw.

(domain! 'testing)
(effects! '(read write))

(define *zz-nest-buffer* "*zz-nest*")

;; rows are (KEY PARENT); "c" sits under "a", "d" under "c", and "x" names
;; a parent the list does not hold
(define-list-mode! "zz-nest-mode"
  (list
    'buffer *zz-nest-buffer*
    'rows (lambda (buf) '(("a" #f) ("b" #f) ("c" "a") ("d" "c") ("x" "gone")))
    'key (lambda (buf e) (car e))
    'parent (lambda (buf e) (cadr e))
    'nest-cell 0
    'columns (lambda (buf) (list (list "name" #f)))
    'cells (lambda (buf e) (list (car e)))
    'title (lambda (buf) "Nest")
    'no-marks #t))

(deftest 'a-nested-list-puts-each-child-under-its-parent
  "tree order and depths; a row whose parent is not listed stays a root"
  (lambda ()
    (list-mode-show! "zz-nest-mode")
    (let ((buf *zz-nest-buffer*))
      (check-equal! (map car (list-entries buf)) '("a" "c" "d" "b" "x") "children follow their parent")
      (check-equal! (map (lambda (e) (list-row-depth buf e)) (list-entries buf)) '(0 1 2 0 0) "the depths")
      (check-equal! (list-row-hidden buf (car (list-entries buf))) 0 "an open parent hides nothing"))
    (buffer-kill! *zz-nest-buffer*)))

(deftest 'the-list-draw-memo-ends-with-the-draw
  "a draw reads its options from the memo, and no memo is left after it"
  (lambda ()
    (list-mode-show! "zz-nest-mode")
    (let ((buf *zz-nest-buffer*))
      (list-redraw! buf)
      (check-false! (list-draw--entry buf) "no memo after the draw")
      (check-equal! (with-list-draw-memo buf (lambda () (list (list-mode-of buf) (and (list-draw--entry buf) #t))))
                    '("zz-nest-mode" #t)
                    "inside the draw the memo answers"))
    (buffer-kill! *zz-nest-buffer*)))
