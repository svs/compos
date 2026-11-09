;;; diff-mode-test.scm --- the rich diff view draws each side in its language.

(domain! 'testing)
(effects! '(write))

(define t--diff-text
  (string-append
    "commit 0123456789abcdef\n"
    "Author: A <a@b>\n\n"
    "    a message\n\n"
    "diff --git a/lib/a.ex b/lib/a.ex\n"
    "--- a/lib/a.ex\n"
    "+++ b/lib/a.ex\n"
    "@@ -1,3 +1,3 @@\n"
    " defmodule A do\n"
    "-  def f, do: 1\n"
    "+  def f, do: 2\n"
    " end\n"))

;; any string in the block tree that names a ts face
(define (t--diff-ts-class? x)
  (cond ((string? x) (string-prefix? "f-ts-" x))
        ((pair? x) (or (t--diff-ts-class? (car x)) (t--diff-ts-class? (cdr x))))
        (else #f)))

(deftest 'a-file-name-names-its-grammar
  "the extension picks the mode, and the mode names the loaded language"
  (lambda ()
    (check-equal! (diff--file-ts-lang "lib/a.ex") "elixir" "an Elixir file")
    (check-equal! (diff--file-ts-lang "notes.zzz") #f "no grammar, no language")))

(deftest 'a-side-highlights-as-one-text
  "each side of a hunk gets one list of runs per line"
  (lambda ()
    (let ((syn (diff--hunk-syntax "lib/a.ex"
                 '(lines ((ctx "defmodule A do") (del "  def f, do: 1")
                          (add "  def f, do: 2") (ctx "end"))
                   old-start 1 new-start 1))))
      (check-equal! (length (car syn)) 3 "the old side has three lines")
      (check-true! (member '(2 5 "keyword") (diff--line-runs syn #t 2))
                   "def is a keyword on the old side")
      (check-true! (member '(2 5 "keyword") (diff--line-runs syn #f 2))
                   "and on the new side"))))

(deftest 'syntax-and-changed-words-share-the-segs
  "a run wears its ts face and the changed words add hl"
  (lambda ()
    (check-equal! (diff--text-segs "def f" #f '((0 3 "keyword")))
                  '(("f-ts-keyword" "def") ("" " f")) "the syntax alone")
    (check-equal! (diff--text-segs "def f" '(4 5) '((0 3 "keyword")))
                  '(("f-ts-keyword" "def") ("" " ") ("hl" "f")) "and the changed word")
    (check-equal! (diff--text-segs "ab" '(0 1))
                  '(("hl" "a") ("" "b")) "no grammar keeps the old segs")))

(deftest 'a-shown-revision-draws-its-code-in-the-ts-faces
  "diff-show! renders the hunk rows with f-ts-* classes and the message on top"
  (lambda ()
    (let ((buf (diff-show! "*zz-diff-show*" t--diff-text)))
      (check-true! (t--diff-ts-class? (buffer-local-value 'render-blocks buf)) "a row wears a ts face")
      (check-true! (string-contains? (diff--preamble buf) "a message") "the message is the preamble")
      (check-false! (string-contains? (diff--preamble buf) "diff --git") "and stops at the first file")
      (buffer-kill! buf))))
