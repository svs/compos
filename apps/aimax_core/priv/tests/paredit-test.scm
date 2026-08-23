;;; paredit-test.scm --- structural editing, by the commands that do it.
;;;
;;; Every paredit behaviour is a named command. A test sets a buffer and a
;;; point, runs the command, and reads the text back — the key that
;;; happens to run it is a separate fact, asserted once from the table
;;; below.
;;;
;;; Where a fact really belongs to the KEY path — self-insert interleaved
;;; with paredit, the fallback when the mode is off, show-paren — the test
;;; uses dispatch-keys, which is the queue a keystroke arrives on. That is
;;; still Scheme; it is not a keymap assertion in disguise.

(domain! 'testing)
(effects! '(write))

(define t--par-buf "zz-paredit")

(define (t--par! text point)
  (test-buffer! t--par-buf text)
  (enable-minor-mode! t--par-buf "paredit-mode")
  (buffer-goto! t--par-buf point)
  t--par-buf)

;; Run one command in the buffer and answer what it said. The echo area
;; is half of paredit's contract: a refusal has to say why.
(define (t--par-run! cmd)
  (let ((mark (string-length (buffer-text "*messages*"))))
    (with-current-buffer t--par-buf (lambda () (run-command cmd)))
    (let ((said (buffer-text "*messages*")))
      (substring said mark (string-length said)))))

(define (t--par-text) (buffer-text t--par-buf))
(define (t--par-point) (buffer-point t--par-buf))

(define (t--par-done!)
  (when (buffer-known? t--par-buf)
    (disable-minor-mode! t--par-buf "paredit-mode")
    (buffer-kill! t--par-buf)))

;;; --- the scanner --------------------------------------------------------------
;;; par-scan-forward, par-scan-backward, par-up and par-close take text
;;; and an offset and answer an offset. No buffer, no point, no mode.

(effects! '(read))

(deftest 'par-scan-forward-walks-lists-atoms-strings-and-char-literals
  "one datum forward, whatever kind it is"
  (lambda ()
    (check-equal! (par-scan-forward "(foo bar) baz" 0) 9 "over a list")
    (check-equal! (par-scan-forward "(foo bar) baz" 9) 13 "over an atom")
    (check-equal! (par-scan-forward "'(a b) c" 0) 6 "a quote goes with its datum")
    (check-equal! (par-scan-forward "\"a\\\"b\" c" 0) 6 "an escape does not end the string")
    (check-equal! (par-scan-forward "#\\( x" 0) 3 "a char literal is not an opener")
    (check-equal! (par-scan-forward "; c\nfoo" 0) 7 "a comment is skipped, not scanned")
    (check-equal! (par-scan-forward "#|x (|# foo" 0) 11 "and so is a block comment")))

(deftest 'par-scan-forward-answers-false-at-a-closer-or-at-end-of-text
  "there is no next datum, and saying so is the answer"
  (lambda ()
    (check-false! (par-scan-forward "(a) " 3) "at the end of the text")
    (check-false! (par-scan-forward "(a b)" 4) "at a closer")))

(deftest 'par-scan-backward-finds-the-previous-sibling-start
  "backward is not forward run in reverse: it answers a start"
  (lambda ()
    (check-equal! (par-scan-backward "(a bb)" 5) 3 "the previous atom")
    (check-equal! (par-scan-backward "(a bb)" 3) 1 "and the one before it")
    (check-false! (par-scan-backward "(a bb)" 1) "the first has none")
    (check-equal! (par-scan-backward "(a) (b) x" 8) 4 "over a whole list")))

(deftest 'par-up-and-par-close-see-the-enclosing-list
  "through strings and comments, which hold delimiters that are not"
  (lambda ()
    (check-equal! (par-up "(a (b c) d)" 5) 3 "the inner opener")
    (check-equal! (par-up "(a (b c) d)" 2) 0 "the outer one")
    (check-false! (par-up "x y" 2) "no enclosing list")
    (check-equal! (par-close "(a (b c) d)" 5) 7 "the matching closer")
    (check-equal! (par-up "(a \"))\" b)" 8) 0 "closers in a string do not count")
    (check-equal! (par-close "(a ;)\n b)" 3) 8 "nor one in a comment")))



(effects! '(write))

;;; --- the key table is data ----------------------------------------------------

(deftest 'a-buffer-without-the-mode-binds-none-of-the-keys
  "the dispatcher commands are global; only a local map reaches them"
  (lambda ()
    (let ((buf (test-buffer! "zz-paredit-plain" "(a)\n")))
      (check-equal! (local-keys buf) '() "the buffer's own map is empty")
      (buffer-kill! buf))))

(deftest 'every-paredit-key-names-a-live-command-and-a-live-fallback
  "the table is the map; a name that moved would break silently"
  (lambda ()
    (for-each
      (lambda (entry)
        (let ((key (car entry)) (cmd (cadr entry)) (fallback (caddr entry)))
          (check-true! (member cmd (command-names))
                       (string-append key " runs a live command"))
          (check-true! (or (not fallback)
                           (equal? fallback 'insert)
                           (member fallback (command-names)))
                       (string-append key " falls back to something real"))))
      *paredit-keys*)))

;;; --- motion -------------------------------------------------------------------

(deftest 'paredit-forward-and-backward-step-over-expressions-and-out-of-lists
  "one datum at a time, and out past the closer at the end of a list"
  (lambda ()
    (t--par! "(foo bar) baz\n" 0)
    (t--par-run! "paredit-forward")
    (check-equal! (t--par-point) 9 "over the list")
    (t--par-run! "paredit-forward")
    (check-equal! (t--par-point) 13 "over the atom")

    (t--par-run! "paredit-backward")
    (check-equal! (t--par-point) 10 "back to the atom start")
    (t--par-run! "paredit-backward")
    (check-equal! (t--par-point) 0 "back to the list start")

    ;; inside a list, at its end, forward exits past the closer
    (buffer-goto! t--par-buf 8)
    (t--par-run! "paredit-forward")
    (check-equal! (t--par-point) 9 "out of the list")
    (t--par-done!)))

(deftest 'paredit-backward-up-climbs-and-paredit-down-dives
  "the two vertical moves, each one level at a time"
  (lambda ()
    (t--par! "(a (b c) d)\n" 5)
    (t--par-run! "paredit-backward-up")
    (check-equal! (t--par-point) 3 "the inner opener")
    (t--par-run! "paredit-backward-up")
    (check-equal! (t--par-point) 0 "the outer one")

    (t--par-run! "paredit-down")
    (check-equal! (t--par-point) 1 "into the outer list")
    (t--par-run! "paredit-down")
    (check-equal! (t--par-point) 4 "into the inner one")
    (t--par-done!)))

(deftest 'paredit-kill-sexp-kills-one-expression-onto-the-kill-ring
  "the whole datum, and it is yankable"
  (lambda ()
    (t--par! "(foo) bar\n" 0)
    (t--par-run! "paredit-kill-sexp")
    (check-equal! (t--par-text) " bar\n" "the list is gone")
    (check-equal! (kill-top) "(foo)" "and it is on the kill ring")
    (t--par-done!)))

(deftest 'paredit-mark-sexp-marks-the-expression-after-point
  "the mark moves, the point does not"
  (lambda ()
    (t--par! "(a b) c\n" 0)
    (t--par-run! "paredit-mark-sexp")
    ;; mark reads the CURRENT buffer, so ask inside the buffer, not after
    (check-equal! (with-current-buffer t--par-buf (lambda () (mark))) 5
                  "the mark is past the list")
    (check-equal! (t--par-point) 0 "and point stayed")
    (t--par-done!)))

(deftest 'paredit-motion-works-inside-a-string
  "out to the quote ends, because a string is one datum from outside"
  (lambda ()
    (t--par! "(a \"x y\" b)\n" 5)
    (t--par-run! "paredit-forward")
    (check-equal! (t--par-point) 8 "forward to the closing quote")
    (buffer-goto! t--par-buf 5)
    (t--par-run! "paredit-backward")
    (check-equal! (t--par-point) 3 "and back to the opening one")
    (t--par-done!)))

;;; --- pair insertion -----------------------------------------------------------

(deftest 'paredit-open-round-inserts-a-separating-space-after-an-atom
  "(foo)(bar) is two datums with nothing between them"
  (lambda ()
    (t--par! "ab\n" 2)
    (t--par-run! "paredit-open-round")
    (check-equal! (t--par-text) "ab ()\n" "a space, then the pair")
    (check-equal! (t--par-point) 4 "point is inside it")
    (t--par-done!)))

(deftest 'paredit-close-round-with-no-enclosing-list-inserts-nothing
  "there is nothing to close, and it says so"
  (lambda ()
    (t--par! "x\n" 1)
    (let ((said (t--par-run! "paredit-close-round")))
      (check-equal! (t--par-text) "x\n" "the text is untouched")
      (check-contains! said "No enclosing list" "and it says why"))
    (t--par-done!)))

(deftest 'paredit-close-round-removes-blank-space-before-the-closer
  "moving past a closer tidies the space it leaves behind"
  (lambda ()
    (t--par! "(a  )\n" 2)
    (t--par-run! "paredit-close-round")
    (check-equal! (t--par-text) "(a)\n" "the blank is gone")
    (check-equal! (t--par-point) 3 "and point is past the closer")
    (t--par-done!)))

(deftest 'paredit-close-round-does-not-pull-the-closer-into-a-comment
  "a closer on its own line stays there when a comment precedes it"
  (lambda ()
    (t--par! "(a ;x\n)\n" 2)
    (t--par-run! "paredit-close-round")
    (check-equal! (t--par-text) "(a ;x\n)\n" "the text is untouched")
    (check-equal! (t--par-point) 7 "and point is past the closer")
    (t--par-done!)))

(deftest 'paredit-doublequote-pairs-escapes-inside-and-exits-at-the-closer
  "the same key opens, escapes and closes, by where point is"
  (lambda ()
    (t--par! "" 0)
    (t--par-run! "paredit-doublequote")
    (check-equal! (t--par-text) "\"\"" "a balanced pair")
    (check-equal! (t--par-point) 1 "point inside it")

    (t--par-run! "paredit-doublequote")
    (check-equal! (t--par-text) "\"\"" "the second one adds nothing")
    (check-equal! (t--par-point) 2 "it exits instead")

    ;; inside a string a quote arrives escaped
    (t--par! "\"ab\"\n" 2)
    (t--par-run! "paredit-doublequote")
    (check-equal! (t--par-text) "\"a\\\"b\"\n" "escaped, not closed")
    (t--par-done!)))

;;; --- balanced deletion --------------------------------------------------------

(deftest 'paredit-backward-delete-takes-an-empty-pair-whole
  "and refuses to break a full one"
  (lambda ()
    (t--par! "()\n" 2)
    (t--par-run! "paredit-backward-delete")
    (check-equal! (t--par-text) "\n" "the empty pair went whole")

    (t--par! "(a)\n" 3)
    (t--par-run! "paredit-backward-delete")
    (check-equal! (t--par-text) "(a)\n" "a full pair is not broken")
    (check-equal! (t--par-point) 2 "point moves inside instead")

    (buffer-goto! t--par-buf 1)
    (t--par-run! "paredit-backward-delete")
    (check-equal! (t--par-text) "(a)\n" "nor from the other side")
    (check-equal! (t--par-point) 0 "point moves outside instead")
    (t--par-done!)))

(deftest 'paredit-backward-delete-between-a-pair-takes-both-delimiters
  "an empty pair is one thing to delete, whichever kind it is"
  (lambda ()
    (t--par! "()\n" 1)
    (t--par-run! "paredit-backward-delete")
    (check-equal! (t--par-text) "\n" "the round pair")

    (t--par! "\"\"\n" 1)
    (t--par-run! "paredit-backward-delete")
    (check-equal! (t--par-text) "\n" "and the string pair")
    (t--par-done!)))

(deftest 'paredit-backward-delete-inside-a-string-guards-the-opening-quote
  "the text goes, the delimiter does not"
  (lambda ()
    (t--par! "\"ab\"\n" 2)
    (t--par-run! "paredit-backward-delete")
    (check-equal! (t--par-text) "\"b\"\n" "the character went")
    (t--par-run! "paredit-backward-delete")
    (check-equal! (t--par-text) "\"b\"\n" "the quote did not")
    (check-equal! (t--par-point) 0 "point moved out instead")
    (t--par-done!)))

(deftest 'paredit-forward-delete-mirrors-backward-delete
  "an empty pair goes whole, a full one is entered"
  (lambda ()
    (t--par! "()\n" 0)
    (t--par-run! "paredit-forward-delete")
    (check-equal! (t--par-text) "\n" "the empty pair went whole")

    (t--par! "(a)\n" 0)
    (t--par-run! "paredit-forward-delete")
    (check-equal! (t--par-text) "(a)\n" "a full pair is not broken")
    (check-equal! (t--par-point) 1 "point moves inside")
    (t--par-run! "paredit-forward-delete")
    (check-equal! (t--par-text) "()\n" "and then the datum goes")
    (t--par-done!)))

;;; --- balanced kill-line -------------------------------------------------------

(deftest 'paredit-kill-kills-to-the-end-of-line-but-never-a-closer
  "the line ends where the list does"
  (lambda ()
    (t--par! "(a b) c\n" 1)
    (t--par-run! "paredit-kill")
    (check-equal! (t--par-text) "() c\n" "the contents went")
    (check-equal! (kill-top) "a b" "and they are on the kill ring")
    (t--par-done!)))

(deftest 'paredit-kill-reaches-past-eol-to-finish-a-datum
  "a datum that starts on this line is killed whole"
  (lambda ()
    (t--par! "(a (b\n c) d)\n" 1)
    (t--par-run! "paredit-kill")
    (check-equal! (t--par-text) "( d)\n" "the multi-line datum went with it")
    (t--par-done!)))

(deftest 'paredit-kill-in-a-string-stops-at-the-closing-quote
  "a string is a datum, and its closer is not text"
  (lambda ()
    (t--par! "\"ab cd\" x\n" 1)
    (t--par-run! "paredit-kill")
    (check-equal! (t--par-text) "\"\" x\n" "the contents went, the quotes stayed")
    (t--par-done!)))

(deftest 'paredit-kill-at-eol-kills-the-newline
  "and before a lone closer it kills nothing"
  (lambda ()
    (t--par! "a\nb\n" 1)
    (t--par-run! "paredit-kill")
    (check-equal! (t--par-text) "ab\n" "the lines joined")

    (t--par! "(a)\n" 2)
    (t--par-run! "paredit-kill")
    (check-equal! (t--par-text) "(a)\n" "a lone closer is not killed")
    (t--par-done!)))

(deftest 'paredit-kill-takes-a-trailing-comment-with-the-datums
  "the comment belongs to the line being killed"
  (lambda ()
    (t--par! "(a b ;x\n)\n" 1)
    (t--par-run! "paredit-kill")
    (check-equal! (t--par-text) "(\n)\n" "the datums and the comment went")
    (t--par-done!)))

;;; --- structure ----------------------------------------------------------------

(deftest 'slurp-forward-pulls-the-next-datum-in
  "and one undo restores it"
  (lambda ()
    (t--par! "(foo) bar\n" 4)
    (t--par-run! "paredit-slurp-forward")
    (check-equal! (t--par-text) "(foo bar)\n" "the datum came in")
    (check-equal! (t--par-point) 4 "point held its place")

    (with-current-buffer t--par-buf (lambda () (undo!)))
    (check-equal! (t--par-text) "(foo) bar\n" "one undo restored it")
    (t--par-done!)))

(deftest 'barf-forward-pushes-the-last-datum-out
  "and one undo restores it"
  (lambda ()
    (t--par! "(foo bar)\n" 8)
    (t--par-run! "paredit-barf-forward")
    (check-equal! (t--par-text) "(foo) bar\n" "the datum went out")
    (check-equal! (t--par-point) 4 "point held its place")

    (with-current-buffer t--par-buf (lambda () (undo!)))
    (check-equal! (t--par-text) "(foo bar)\n" "one undo restored it")
    (t--par-done!)))

(deftest 'slurp-and-barf-backward-mirror-the-forward-pair
  "the same two moves, at the other end of the list"
  (lambda ()
    (t--par! "a (b)\n" 3)
    (t--par-run! "paredit-slurp-backward")
    (check-equal! (t--par-text) "(a b)\n" "the datum came in from the left")

    (t--par! "(a b)\n" 3)
    (t--par-run! "paredit-barf-backward")
    (check-equal! (t--par-text) "a (b)\n" "and went back out")
    (check-equal! (t--par-point) 3 "point held its place")
    (t--par-done!)))

(deftest 'splice-removes-the-enclosing-delimiters
  "the contents stay where they were"
  (lambda ()
    (t--par! "(a (b c) d)\n" 5)
    (t--par-run! "paredit-splice")
    (check-equal! (t--par-text) "(a b c d)\n" "the inner pair is gone")
    (check-equal! (t--par-point) 4 "point followed the text")
    (t--par-done!)))

(deftest 'raise-replaces-the-list-with-the-datum-at-point
  "everything else in the list goes"
  (lambda ()
    (t--par! "(a (b c) d)\n" 4)
    (t--par-run! "paredit-raise")
    (check-equal! (t--par-text) "(a b d)\n" "the datum replaced its list")
    (check-equal! (t--par-point) 3 "point followed it")
    (t--par-done!)))

(deftest 'wrap-puts-the-next-datum-in-a-fresh-pair
  "and leaves point inside the new pair"
  (lambda ()
    (t--par! "foo bar\n" 0)
    (t--par-run! "paredit-wrap-round")
    (check-equal! (t--par-text) "(foo) bar\n" "one datum wrapped")
    (check-equal! (t--par-point) 1 "point is inside")
    (t--par-done!)))

(deftest 'structure-ops-touch-nothing-without-a-target
  "and each refusal says which one it was"
  (lambda ()
    (t--par! "x\n" 1)
    (let ((said (t--par-run! "paredit-slurp-forward")))
      (check-equal! (t--par-text) "x\n" "no list, no edit")
      (check-contains! said "No enclosing list" "and it says so"))

    (t--par! "(a) \n" 1)
    (let ((said (t--par-run! "paredit-slurp-forward")))
      (check-equal! (t--par-text) "(a) \n" "nothing to pull in, no edit")
      (check-contains! said "Nothing to slurp" "and it says so"))
    (t--par-done!)))

(deftest 'structure-ops-refuse-a-read-only-buffer
  "the guard is the buffer's, and paredit honours it"
  (lambda ()
    (t--par! "(a) b\n" 1)
    (buffer-set-read-only! t--par-buf #t)
    (let ((said (t--par-run! "paredit-slurp-forward")))
      (check-equal! (t--par-text) "(a) b\n" "the text is untouched")
      (check-contains! said "read-only" "and it says why"))
    (buffer-set-read-only! t--par-buf #f)
    (t--par-done!)))

(deftest 'slurp-keeps-byte-offsets-straight-around-multibyte-text
  "a character is not a byte, and the closer moves by bytes"
  (lambda ()
    (t--par! "(é) x\n" 1)
    (t--par-run! "paredit-slurp-forward")
    (check-equal! (t--par-text) "(é x)\n" "the datum came in cleanly")
    (t--par-done!)))


;;; --- the key path ----------------------------------------------------------------
;;; dispatch-keys puts a key on the same queue a keystroke arrives on. It
;;; answers at once and the keys land after, so what follows is waited for.

(define (t--par-keys! keys)
  ;; a key goes to the WINDOW's buffer, so the buffer must be on screen
  (switch-to-buffer! t--par-buf)
  (dispatch-keys keys))

(define (t--par-wait-text! expected)
  (wait-until (lambda () (equal? (t--par-text) expected)) 3000 20))

(deftest 'typing-a-form-end-to-end-keeps-the-text-balanced
  "the pair closes itself, and the closer walks past it"
  (lambda ()
    (t--par! "" 0)
    (t--par-keys! (list "(" "f" "o" "o" ")"))
    (check-true! (t--par-wait-text! "(foo)") "the form is balanced")
    (check-equal! (t--par-point) 5 "and point is past the closer")
    (t--par-done!)))

(deftest 'an-opener-inside-a-string-or-comment-self-inserts
  "a delimiter in text is text"
  (lambda ()
    (t--par! "\"a\" ;c\n" 2)
    (t--par-run! "paredit-open-round")
    (check-equal! (t--par-text) "\"a(\" ;c\n" "inside the string it is a character")

    (buffer-goto! t--par-buf 7)
    (t--par-run! "paredit-open-round")
    (check-equal! (t--par-text) "\"a(\" ;c(\n" "and inside the comment too")
    (t--par-done!)))

(deftest 'one-delete-of-a-pair-is-one-undo-step
  "the pair went as one thing, so it comes back as one"
  (lambda ()
    (t--par! "()\n" 2)
    (t--par-run! "paredit-backward-delete")
    (check-equal! (t--par-text) "\n" "the pair went")
    (with-current-buffer t--par-buf (lambda () (undo!)))
    (check-equal! (t--par-text) "()\n" "and one undo brought it back")
    (t--par-done!)))

(deftest 'without-the-mode-the-keys-keep-their-default-behaviour
  "each key runs a dispatcher that falls through"
  (lambda ()
    (let ((buf (test-buffer! "zz-paredit-plain" "(foo) bar\n")))
      (switch-to-buffer! buf)
      (buffer-goto! buf 0)

      ;; C-M-k has no fallback command: a quiet no-op
      (run-command "paredit--key-C-M-k")
      (check-equal! (buffer-text buf) "(foo) bar\n" "nothing was killed")

      ;; C-M-f falls through to forward-sexp, which has no grammar here
      (let ((mark (string-length (buffer-text "*messages*"))))
        (run-command "paredit--key-C-M-f")
        (check-equal! (buffer-point buf) 0 "point did not move")
        (let ((said (buffer-text "*messages*")))
          (check-contains! (substring said mark (string-length said))
                           "No structural navigation" "and it said why")))
      (buffer-kill! buf))))

(deftest 'the-arrow-chords-move-by-word-and-paredit-keeps-the-c-arrows
  "M-arrows pass through in both; C-arrows are paredit's when the mode is on"
  (lambda ()
    (let ((plain (test-buffer! "zz-paredit-words" "foo bar\n")))
      (switch-to-buffer! plain)
      (buffer-goto! plain 0)
      (run-command "paredit--key-C-<right>")
      (check-equal! (buffer-point plain) 3 "C-<right> moves by word without the mode")
      (run-command "forward-word")
      (check-equal! (buffer-point plain) 7 "and M-<right>, which paredit never claims")
      (buffer-kill! plain))

    ;; paredit does not bind the M-arrows at all — that is what "pass
    ;; through" means, and the table is where it is said
    (check-false! (assoc "M-<right>" *paredit-keys*) "paredit claims no M-<right>")
    (check-false! (assoc "M-<left>" *paredit-keys*) "nor M-<left>")
    (check-equal! (global-key-command "M-<right>") "forward-word"
                  "so it stays the word motion")
    (t--par! "(foo bar)\n" 1)
    (with-current-buffer t--par-buf (lambda () (run-command "forward-word")))
    (check-equal! (t--par-point) 4 "which still works inside the mode")
    (t--par-done!)))

;;; --- show-paren ------------------------------------------------------------------
;;; This runs after a KEY, not after a command, so these two dispatch.

(deftest 'point-beside-a-delimiter-lights-the-pair
  "and elsewhere it goes dark"
  (lambda ()
    (t--par! "(ab)x\n" 0)
    (t--par-keys! (list "<right>" "<right>" "<right>" "<right>"))
    (check-true! (wait-until (lambda () (member '(0 1 "paren-match") (buffer-overlays t--par-buf)))
                             3000 20)
                 "the opener lights")
    (check-true! (member '(3 4 "paren-match") (buffer-overlays t--par-buf)) "and the closer")
    (check-equal! (t--par-point) 4 "with point beside the pair")

    (t--par-keys! (list "<right>"))
    (check-true! (wait-until
                   (lambda ()
                     (not (member "paren-match" (map caddr (buffer-overlays t--par-buf)))))
                   3000 20)
                 "and a step away puts it out")
    (t--par-done!)))

(deftest 'a-delimiter-inside-a-string-does-not-light
  "a closer in text has no pair to name"
  (lambda ()
    (t--par! "\"a)\" b\n" 2)
    (t--par-keys! (list "<right>"))
    (wait-until (lambda () (equal? (t--par-point) 3)) 3000 20)
    (check-false! (member "paren-match" (map caddr (buffer-overlays t--par-buf)))
                  "nothing lights")
    (t--par-done!)))

;;; --- enablement ------------------------------------------------------------------

(deftest 'scheme-mode-enables-paredit-and-the-defcustom-turns-it-off
  "the mode rides the major mode, and the setting is the user's"
  (lambda ()
    (let ((buf (test-buffer! "zz-paredit-scheme" "")))
      (with-current-buffer buf (lambda () (set-mode! "scheme-mode")))
      (check-true! (minor-mode-on? buf "paredit-mode") "scheme-mode brings it")
      (switch-to-buffer! buf)
      (run-command "paredit-open-round")
      (check-equal! (buffer-text buf) "()" "and it is really on")
      (disable-minor-mode! buf "paredit-mode")
      (buffer-kill! buf))

    (let ((saved paredit-in-scheme-mode))
      (set! paredit-in-scheme-mode #f)
      (let ((buf (test-buffer! "zz-paredit-scheme2" "")))
        (with-current-buffer buf (lambda () (set-mode! "scheme-mode")))
        (check-false! (minor-mode-on? buf "paredit-mode") "the setting turns it off")
        (buffer-kill! buf))
      (set! paredit-in-scheme-mode saved))))
