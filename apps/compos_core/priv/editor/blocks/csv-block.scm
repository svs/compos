;;; csv-block.scm --- a CSV body draws as a table.
;;;
;;; A csv block, and the result-csv block a run lands below it, are rows
;;; of comma-separated cells. In the page each body line is a table row:
;;; a comma outside quotes is a column bar, as a pipe is in a Markdown
;;; table, and a comma inside a quoted field is text. The first row after
;;; the fence is the head. The row wears row-csv as well as row-table, so
;;; the page lets it grow to its columns and scroll right instead of
;;; folding a wide sheet into the window.
;;;
;;; The kinds are registered elsewhere (run-block.scm runs csv,
;;; morg-kinds.scm paints result-csv); this file adds the one aspect they
;;; share, through the registry's row-spans key.

(package! 'csv-block 'editor)
(domain! 'files)
(effects! '(pure))

;; the byte offsets of the commas that divide the row's cells
(define (csv-block-bars line)
  (let ((len (string-byte-length line)))
    (let loop ((i 0) (quoted #f) (acc '()))
      (if (>= i len)
          (reverse acc)
          (let ((ch (substring-bytes line i (+ i 1))))
            (cond ((equal? ch "\"") (loop (+ i 1) (not quoted) acc))
                  ((and (equal? ch ",") (not quoted)) (loop (+ i 1) quoted (cons i acc)))
                  (else (loop (+ i 1) quoted acc))))))))

;; the spans of one body line: the row faces, and a bar per comma
(define (csv-block-row-spans start line len head?)
  (append
    (list (list start (+ start len) "row-table")
          (list start (+ start len) "row-csv"))
    (if head? (list (list start (+ start len) "row-table-head")) '())
    (map (lambda (b) (list (+ start b) (+ start b 1) "md-table-bar"))
         (csv-block-bars line))))

(fence-kind-merge! "csv" 'row-spans csv-block-row-spans)
(fence-kind-merge! "result-csv" 'row-spans csv-block-row-spans)

(public! 'csv-block-bars
  "(csv-block-bars LINE) — the byte offsets of the commas that divide LINE's cells; a comma inside quotes is not one")
(public! 'csv-block-row-spans
  "(csv-block-row-spans START LINE LEN HEAD?) — the spans that draw one CSV body line as a table row")
