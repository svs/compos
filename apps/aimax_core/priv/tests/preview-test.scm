;;; preview-test.scm --- RET in a rendered page.
;;;
;;; A reader of a rendered page sees blocks, so RET makes a block. Every
;;; assertion here calls the command's own function and reads the buffer.
;;; Nothing presses a key: the binding is a preference, the behaviour is
;;; what these tests are for.

(domain! 'testing)
(effects! '(read))

(define (t--preview-ret name text at)
  (let ((buf (test-buffer! name text)))
    (with-current-buffer buf
      (lambda ()
        (goto-char! at)
        (preview-newline!)
        (let ((r (list (buffer-text buf) (point))))
          (buffer-kill! buf)
          r)))))

(deftest 'ret-at-a-line-end-opens-an-empty-block
  "RET below a paragraph leaves point in a block of its own"
  (lambda ()
    (let ((r (t--preview-ret "zz-preview-end.md" "para1\npara2\n" 5)))
      (check-equal! (car r) "para1\n\n\n\npara2\n"
                    "the paragraphs stand apart, with an empty one between")
      (check-equal! (cadr r) 7 "point stands on the empty block"))))

(deftest 'ret-at-the-end-of-the-document-opens-a-block
  "RET on the last line still opens a block"
  (lambda ()
    (let ((r (t--preview-ret "zz-preview-eof.md" "para1\n" 5)))
      (check-equal! (car r) "para1\n\n" "one blank line ends the paragraph")
      (check-equal! (cadr r) 7 "point stands after it"))))

(deftest 'ret-inside-a-paragraph-splits-it-in-two
  "RET in the middle of a paragraph makes two paragraphs"
  (lambda ()
    (let ((r (t--preview-ret "zz-preview-split.md" "hello world\n" 5)))
      (check-equal! (car r) "hello\n\n world\n" "the split is a block break")
      (check-equal! (cadr r) 7 "point starts the second paragraph"))))

(deftest 'ret-on-a-blank-line-keeps-exactly-one-empty-block
  "a run of blank lines collapses to the one block point stands in"
  (lambda ()
    (let ((r (t--preview-ret "zz-preview-run.md" "a\n\n\n\n\nb\n" 3)))
      (check-equal! (car r) "a\n\n\n\nb\n" "five newlines become four")
      (check-equal! (cadr r) 3 "point keeps its empty block"))))

(deftest 'ret-inside-a-fence-stays-a-plain-newline
  "every character inside a fence is literal, RET included"
  (lambda ()
    (let ((r (t--preview-ret "zz-preview-fence.md" "```\ncode\n```\n" 8)))
      (check-equal! (car r) "```\ncode\n\n```\n" "the code gains one line")
      (check-equal! (cadr r) 9 "point moves one character"))))

(deftest 'ret-on-a-table-row-stays-a-plain-newline
  "a table row means nothing once a block break splits it"
  (lambda ()
    (let ((r (t--preview-ret "zz-preview-table.md" "| a | b |\n" 9)))
      (check-equal! (car r) "| a | b |\n\n" "the row gains one newline")
      (check-equal! (cadr r) 10 "point moves one character"))))

(deftest 'ret-in-a-list-writes-the-next-marker
  "a bullet repeats, so the list continues"
  (lambda ()
    (let ((r (t--preview-ret "zz-preview-bullet.md" "- one\n" 5)))
      (check-equal! (car r) "- one\n- \n" "the next item carries the bullet")
      (check-equal! (cadr r) 8 "point stands after the marker"))))

(deftest 'ret-in-an-ordered-list-counts-on
  "an ordered item names the next number"
  (lambda ()
    (let ((r (t--preview-ret "zz-preview-ordered.md" "1. one\n" 6)))
      (check-equal! (car r) "1. one\n2. \n" "the next item is number two")
      (check-equal! (cadr r) 10 "point stands after the marker"))))

(deftest 'ret-on-an-empty-item-ends-the-list
  "RET on an item with no text drops the marker and opens a block"
  (lambda ()
    (let ((r (t--preview-ret "zz-preview-list-end.md" "- one\n- \n" 8)))
      (check-equal! (car r) "- one\n\n" "the empty item is gone")
      (check-equal! (cadr r) 7 "point stands in the new block"))))

(deftest 'a-list-marker-names-the-item-that-follows-it
  "the marker reader answers the indent, the next marker, and its width"
  (lambda ()
    (check-equal! (preview--next-marker "  - text") '("  " "-" 4)
                  "a bullet repeats at its own indent")
    (check-equal! (preview--next-marker "3) text") '("" "4)" 3)
                  "an ordered item keeps its delimiter and counts on")
    (check-equal! (preview--next-marker "plain text") #f
                  "a paragraph is not a list item")))

(deftest 'only-an-editable-markdown-page-changes-what-ret-means
  "a source buffer and a read-only page keep the plain newline"
  (lambda ()
    (let ((buf (test-buffer! "zz-preview-gate.md" "text\n")))
      (with-current-buffer buf
        (lambda ()
          (check-equal! (preview--markdown-edit?) #f
                        "a buffer showing its source is not a rendered page")
          (buffer-set-local! buf 'render-mode "markdown")
          (check-equal! (preview--markdown-edit?) #t
                        "a rendered Markdown page takes the block break")
          (buffer-set-read-only! buf #t)
          (check-equal! (preview--markdown-edit?) #f
                        "a read-only page keeps the plain newline")
          (buffer-set-read-only! buf #f)))
      (buffer-kill! buf))))
