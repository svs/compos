;;; list-page-test.scm --- a paged list draws a page, and motion past its end draws the next.

(domain! 'testing)
(effects! '(read write))

(define *zz-page-buffer* "*zz-page*")

(define-list-mode! "zz-page-mode"
  (list
    'buffer *zz-page-buffer*
    'rows (lambda (buf) (let loop ((i 0) (acc '()))
                          (if (= i 130) (reverse acc) (loop (+ i 1) (cons (list i) acc)))))
    'columns (lambda (buf) (list (list "n" 6) (list "name" #f)))
    'cells (lambda (buf e) (list (number->string (car e))
                                 (string-append "row " (number->string (car e)))))
    'title (lambda (buf) "Pages")
    'meta (lambda (buf) (string-append (number->string (length (list-entries buf))) " rows"))
    'no-marks #t
    'page-size 50))

(deftest 'a-paged-list-draws-one-page-and-keeps-every-row
  "the entries hold every row; the buffer draws the first page and says so"
  (lambda ()
    (list-mode-show! "zz-page-mode")
    (let ((buf *zz-page-buffer*))
      (check-equal! (length (list-entries buf)) 130 "every row is an entry")
      (check-equal! (list-shown-count buf) 50 "the first page is drawn")
      (check-equal! (length (list-offsets buf)) 50 "one offset per drawn row")
      (check-true! (string-contains? (buffer-text buf) "50 of 130 shown") "the header says so")
      (check-true! (not (string-contains? (buffer-text buf) "row 50")) "the second page is not drawn")
      (list-more! buf)
      (check-equal! (list-shown-count buf) 100 "the next page")
      (check-true! (string-contains? (buffer-text buf) "row 99") "and its rows")
      (list-more! buf)
      (check-equal! (list-shown-count buf) 130 "the last page is short")
      (check-true! (not (string-contains? (buffer-text buf) "shown")) "no note when every row shows")
      (list-more! buf)
      (check-equal! (list-shown-count buf) 130 "nothing past the end"))
    (buffer-kill! *zz-page-buffer*)))

(deftest 'motion-past-the-page-end-draws-the-next-page
  "n on the last drawn row and PgDn near it draw the page they land on"
  (lambda ()
    (list-mode-show! "zz-page-mode")
    (let ((buf *zz-page-buffer*))
      (with-current-buffer buf
        (lambda ()
          (list-goto-index! buf 49)
          (run-command "list-next")
          (check-equal! (list-shown-count buf) 100 "n at the end draws the next page")
          (check-equal! (list-index buf) 50 "and lands on its first row")
          (list-goto-index! buf 98)
          (run-command "list-page-down")
          (check-equal! (list-shown-count buf) 130 "a screen down draws the page it lands on")
          (check-true! (> (list-index buf) 98) "and moves"))))
    (buffer-kill! *zz-page-buffer*)))

(deftest 'an-open-shows-the-first-page-again
  "the pages you drew were for the last visit; a fresh open starts at one"
  (lambda ()
    (list-mode-show! "zz-page-mode")
    (list-more! *zz-page-buffer*)
    (check-equal! (list-shown-count *zz-page-buffer*) 100 "two pages")
    (list-mode-show! "zz-page-mode")
    (check-equal! (list-shown-count *zz-page-buffer*) 50 "one page on the open")
    (buffer-kill! *zz-page-buffer*)))
