;;; edit-semantics-test.scm --- the edit surface an agent reaches.
;;;
;;; buffer-replace! was the only edit an agent could make without byte
;;; arithmetic. These are the rest of it, and the errors they answer
;;; with — the error text is the feature: a model that reads "occurs 3
;;; times" fixes its own next call.

(domain! 'testing)
(effects! '(write))

(define (t--edit-buffer text)
  (test-buffer! "*zzedit*" text))

(define (t--drop-edit!) (when (buffer-exists? "*zzedit*") (buffer-kill! "*zzedit*")))

(deftest 'replace-all-replaces-every-occurrence
  "buffer-replace-all! changes them all and says how many"
  (lambda ()
    (let ((buf (t--edit-buffer "a b a b a\n")))
      (check-equal! (buffer-replace-all! buf "a" "X") "replaced 3 occurrences"
                    "three hits are reported")
      (check-equal! (buffer-text buf) "X b X b X\n" "and all three changed")
      (check-equal! (buffer-replace-all! buf "b" "Y") "replaced 2 occurrences"
                    "two hits are reported")
      (check-equal! (buffer-text buf) "X Y X Y X\n" "and both changed")
      (t--drop-edit!))))

(deftest 'editor-replace-string-replaces-every-occurrence
  "the editor replacement pass searches the target buffer, not the minibuffer"
  (lambda ()
    (let ((buf (t--edit-buffer "one two one"))
          (count 0))
      (with-current-buffer buf
        (lambda () (set! count (replace--all! buf "one" "X" 0))))
      (check-equal! count 2 "two matches are replaced")
      (check-equal! (buffer-text buf) "X two X" "the target buffer changes")
      (t--drop-edit!))))

(deftest 'replace-all-is-one-pass
  "one atomic replacement, whatever the number of hits, so one undo
   puts the text back"
  (lambda ()
    (let ((buf (t--edit-buffer "a a a\n")))
      (buffer-replace-all! buf "a" "X")
      (check-equal! (buffer-text buf) "X X X\n" "the pass landed")
      (with-current-buffer buf
        (lambda () (run-command "undo")))
      (check-equal! (buffer-text buf) "a a a\n" "one undo restores the text")
      (t--drop-edit!))))

(deftest 'insert-before-and-after-place-text-around-an-anchor
  "the anchor stays; the text lands on the side you named"
  (lambda ()
    (let ((buf (t--edit-buffer "def two do\n  2\nend\n")))
      (check-equal! (buffer-insert-before! buf "def two" "@doc false\n") "inserted"
                    "before answers inserted")
      (check-equal! (buffer-text buf) "@doc false\ndef two do\n  2\nend\n"
                    "and the text is above the anchor")
      (check-equal! (buffer-insert-after! buf "end\n" "\ndef three do\n  3\nend\n")
                    "inserted" "after answers inserted")
      (check-contains! (buffer-text buf) "def three do" "and the text is below")
      (t--drop-edit!))))

(deftest 'delete-text-takes-exact-unique-text
  "no byte arithmetic: name the text, and it goes"
  (lambda ()
    (let ((buf (t--edit-buffer "keep\ndrop this line\nkeep\n")))
      (check-equal! (buffer-delete-text! buf "drop this line\n") "deleted"
                    "the delete is reported")
      (check-equal! (buffer-text buf) "keep\nkeep\n" "and only that line went")
      (t--drop-edit!))))

(deftest 'every-edit-helper-answers-the-same-errors
  "the error text is the feature, and a refused edit changes nothing"
  (lambda ()
    (let ((buf (t--edit-buffer "a b a\n"))
          (missing "error: old text not found — read the buffer and copy it exactly"))
      (check-equal! (buffer-replace! buf "zzz" "x") missing "replace! on missing text")
      (check-equal! (buffer-replace-all! buf "zzz" "x") missing
                    "replace-all! on missing text")
      (check-contains! (buffer-replace! buf "a" "x")
                       "old text occurs 2 times — include surrounding text"
                       "replace! names the count")
      (check-contains! (buffer-insert-after! buf "a" "x")
                       "anchor occurs 2 times — include surrounding text"
                       "insert-after! names the count")
      (check-contains! (buffer-delete-text! buf "a") "text occurs 2 times"
                       "delete-text! names the count")
      (check-contains! (buffer-insert-before! buf "" "x") "anchor must be non-empty"
                       "an empty anchor is refused")
      (check-contains! (buffer-replace! "zz-no-such-buffer" "a" "b") "no such buffer"
                       "a missing buffer is named")
      (check-equal! (buffer-text buf) "a b a\n" "not one refusal touched the buffer")
      (t--drop-edit!))))

(deftest 'the-edit-helpers-are-public-with-their-effects
  "an agent finds them through apropos, and the catalog carries the effect"
  (lambda ()
    (check-contains! (value->string (apropos "insert after anchor"))
                     "buffer-insert-after!" "apropos finds the helper")
    (check-contains! (value->string (catalog-entry 'function "buffer-delete-text!"))
                     "write" "and the catalog says it writes")))

(deftest 'narrowing-is-a-core-buffer-operation
  "every mode can narrow a region without changing the underlying text"
  (lambda ()
    (let ((buf (t--edit-buffer "zero\none\ntwo\n")))
      (with-current-buffer buf
        (lambda ()
          (buffer-goto! buf 5)
          (set-mark! 9)
          (run-command "narrow-to-region")))
      (check-equal! (buffer-narrow-range buf) '(5 9)
                    "the core command narrows to point and mark")
      (check-equal! (buffer-text buf) "zero\none\ntwo\n"
                    "narrowing never changes buffer access or text")
      (with-current-buffer buf (lambda () (run-command "widen")))
      (check-false! (buffer-narrow-range buf) "the core command widens")
      (t--drop-edit!))))
