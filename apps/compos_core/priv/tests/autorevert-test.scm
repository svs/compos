;;; autorevert-test.scm --- a file buffer follows its file.
;;;
;;; The watcher is debounced and asynchronous, so nothing here waits on
;;; it: the tests call the decision and the revert directly. What they
;;; hold is the contract. A buffer still holding the text it last agreed
;;; with its file on takes the file. A buffer with work of its own merges
;;; the file's change into that work and never loses it, and that holds
;;; when the modified flag says otherwise, which is the case this package
;;; exists for: inside compos code is edited in the buffer and saving is a
;;; separate decision, so a buffer carries live work for hours, and a write
;;; behind the editor's back is exactly what leaves the flag wrong. The
;;; mode is frame-local, and a frame that never spoke follows.

(domain! 'testing)
(effects! '(write))

(define t--autorevert-file "/tmp/compos-autorevert-test.txt")

(define (t--author-row rows line)
  (let ((hit (filter (lambda (r) (= (car r) line)) rows)))
    (if (null? hit) #f (car hit))))

(deftest 'auto-revert-is-on-until-a-frame-turns-it-off
  "frame-local, and the default is to follow"
  (lambda ()
    (let ((frame "f-zz-autorevert"))
      (check-true! (auto-revert-on? frame)
                   "a frame that never spoke follows its files")
      (auto-revert-set! frame #f)
      (check-false! (auto-revert-on? frame) "and it can stop")
      (auto-revert-set! frame #t)
      (check-true! (auto-revert-on? frame) "and start again"))))

(deftest 'an-unmodified-buffer-takes-the-file-and-a-modified-one-keeps-its-edits
  "the revert itself, without the watcher"
  (lambda ()
    (let ((p t--autorevert-file))
      ;; visited the way production visits, so the buffer carries the mark
      ;; the created hook takes
      (shell-command->string
        "printf 'one\\n' > /tmp/compos-autorevert-test.txt" "/tmp")
      (find-file p)

      ;; the file changes behind the editor's back
      (shell-command->string
        "printf 'two\\nthree\\n' > /tmp/compos-autorevert-test.txt" "/tmp")
      (check-true! (auto-revert-follow! p) "an unmodified buffer follows")
      (check-equal! (buffer-text p) "two\nthree\n"
                    "it holds what the file holds")
      (check-false! (buffer-modified? p)
                    "and says so: a buffer that just took its file is not modified")

      ;; now the buffer has work of its own, and the file moves elsewhere
      (buffer-append! p "mine\n")
      (shell-command->string
        "printf 'two\\nTHREE\\n' > /tmp/compos-autorevert-test.txt" "/tmp")
      (check-true! (auto-revert-follow! p) "the file's change is merged in")
      (check-equal! (buffer-text p) "two\nTHREE\nmine\n"
                    "the buffer keeps its line and gains the file's")

      ;; saved, so the two agree again and the buffer may follow again
      (with-current-buffer p (lambda () (buffer-save! p)))
      (auto-revert-follow! p)
      (shell-command->string
        "printf 'five\\n' > /tmp/compos-autorevert-test.txt" "/tmp")
      (check-true! (auto-revert-follow! p) "a saved buffer follows once more")
      (check-equal! (buffer-text p) "five\n" "and holds what the file holds")

      (buffer-mark-saved! p)
      (buffer-kill! p)
      (shell-command->string "unlink /tmp/compos-autorevert-test.txt" "/tmp"))))

(deftest 'live-buffer-work-survives-a-modified-flag-that-says-otherwise
  "the flag decides nothing; the text the buffer last agreed on does"
  (lambda ()
    (let ((p "/tmp/compos-autorevert-flag-test.txt"))
      (shell-command->string
        "printf 'one\\n' > /tmp/compos-autorevert-flag-test.txt" "/tmp")
      (find-file p)

      ;; code is written in the buffer and not saved, the ordinary state
      ;; of a compos buffer. Then the flag is cleared, which is what a
      ;; write behind the editor's back does to it.
      (buffer-append! p "live work\n")
      (buffer-mark-saved! p)
      (check-false! (buffer-modified? p) "the flag now says unmodified")

      (shell-command->string
        "printf 'ONE\\n' > /tmp/compos-autorevert-flag-test.txt" "/tmp")
      (auto-revert-follow! p)
      (check-equal! (buffer-text p) "ONE\nlive work\n"
                    "the work in the buffer is not written over")

      (buffer-mark-saved! p)
      (buffer-kill! p)
      (shell-command->string
        "unlink /tmp/compos-autorevert-flag-test.txt" "/tmp"))))

(deftest 'a-revert-writes-only-the-lines-the-file-changed
  "the file's change must not take the authorship of the whole file"
  (lambda ()
    (let ((p "/tmp/compos-autorevert-weave-test.txt"))
      (shell-command->string
        (string-append "printf 'alpha\\nbravo\\ncharlie\\ndelta\\necho\\nfoxtrot\\n' > " p)
        "/tmp")
      (find-file p)
      (buffer-replace! p "charlie\n" "charlie-typed-here\n")
      (with-current-buffer p (lambda () (buffer-save! p)))
      ;; the save's own file event, which is what moves the mark forward
      (auto-revert-follow! p)

      (let ((mine (t--author-row (buffer-author-lines p) 3)))
        (check-true! (and mine #t) "line 3 was typed here, so it has an author")

        ;; two lines change on disk, well apart, and the rest is untouched
        (shell-command->string
          (string-append
            "printf 'alpha\\nBRAVO\\ncharlie-typed-here\\ndelta\\nECHO\\nfoxtrot\\n' > " p)
          "/tmp")
        (check-true! (auto-revert-follow! p) "the buffer follows its file")
        (check-equal! (buffer-text p) (read-file p) "and holds the file exactly")

        (let ((rows (buffer-author-lines p)))
          (check-equal! (t--author-row rows 3) mine
                        "the line the file did not touch keeps its author")
          (check-equal! (cadr (t--author-row rows 2)) "disk"
                        "the line the file changed belongs to the disk")
          (check-equal! (cadr (t--author-row rows 5)) "disk"
                        "and so does the other one, hunks apart")))

      (buffer-mark-saved! p)
      (buffer-kill! p)
      (shell-command->string (string-append "unlink " p) "/tmp"))))

(deftest 'the-hunks-rebuild-the-file-whatever-the-change
  "the walk consumes both line lists once, so the script is exact"
  (lambda ()
    (check-equal! (auto-revert-hunks '("a" "b" "c" "") '("a" "B" "c" ""))
                  '((1 1 ("B")))
                  "one changed line is one hunk of one line")
    (check-equal! (auto-revert-hunks '("a" "b" "") '("a" "x" "y" "b" ""))
                  '((1 0 ("x" "y")))
                  "an insertion deletes nothing")
    (check-equal! (auto-revert-hunks '("a" "b" "c" "d" "") '("a" "d" ""))
                  '((1 2 ()))
                  "a deletion inserts nothing")
    (check-equal! (auto-revert-hunks '("a" "b" "c" "d" "e" "f" "g" "")
                                     '("a" "B" "c" "d" "e" "F" "g" ""))
                  '((1 1 ("B")) (5 1 ("F")))
                  "two changes stay two hunks; the lines between keep their author")
    (check-equal! (auto-revert-hunks '("a" "b" "") '("a" "b" ""))
                  '()
                  "an unchanged file is no work at all")))

(deftest 'a-file-that-moved-is-merged-into-the-work-in-the-buffer
  "the buffer is the text; a file is one more writer, not an authority"
  (lambda ()
    (let ((p "/tmp/compos-autorevert-merge-test.txt"))
      (shell-command->string
        (string-append "printf 'a\\nb\\nc\\nd\\ne\\nf\\n' > " p) "/tmp")
      (find-file p)

      ;; unsaved work in the buffer, the ordinary state of a compos buffer
      (buffer-replace! p "b\n" "b-MINE\n")
      ;; and the file moves somewhere else entirely
      (shell-command->string
        (string-append "printf 'a\\nb\\nc\\nd\\ne-THEIRS\\nf\\n' > " p) "/tmp")

      (check-true! (auto-revert-follow! p) "the file's change lands")
      (check-equal! (buffer-text p) "a\nb-MINE\nc\nd\ne-THEIRS\nf\n"
                    "both changes are in the buffer, neither overwrote the other")

      (let ((rows (buffer-author-lines p)))
        (check-equal! (cadr (t--author-row rows 5)) "disk"
                      "the file's line belongs to the disk")
        (check-false! (equal? (cadr (t--author-row rows 2)) "disk")
                      "and the buffer's line still belongs to whoever typed it"))

      (buffer-mark-saved! p)
      (buffer-kill! p)
      (shell-command->string (string-append "unlink " p) "/tmp"))))

(deftest 'a-line-both-sides-changed-is-left-to-the-buffer
  "only where the editor has no answer does it decline, and it says how many"
  (lambda ()
    (let ((p "/tmp/compos-autorevert-conflict-test.txt"))
      (shell-command->string
        (string-append "printf 'a\\nb\\nc\\nd\\ne\\nf\\n' > " p) "/tmp")
      (find-file p)
      (buffer-replace! p "c\n" "c-MINE\n")
      (buffer-replace! p "e\n" "e-MINE\n")
      (shell-command->string
        (string-append "printf 'a\\nb\\nc-THEIRS\\nd\\ne\\nF-THEIRS\\n' > " p) "/tmp")

      (let ((r (auto-revert-merge! p (auto-revert-base p) (read-file p))))
        (check-equal! (car r) 1 "the change that stands alone lands")
        (check-equal! (cadr r) 1 "the line both sides changed is left")
        (check-equal! (buffer-text p) "a\nb\nc-MINE\nd\ne-MINE\nF-THEIRS\n"
                      "the buffer keeps its version of the contested line"))

      (buffer-mark-saved! p)
      (buffer-kill! p)
      (shell-command->string (string-append "unlink " p) "/tmp"))))

(deftest 'a-save-cannot-write-over-a-file-that-moved
  "the clobber: a buffer holding text older than the file, saved"
  (lambda ()
    (let ((p "/tmp/compos-autorevert-save-test.txt"))
      (shell-command->string
        (string-append "printf 'a\\nb\\nc\\n' > " p) "/tmp")
      (find-file p)

      ;; the file moves while the buffer holds the old text, and the buffer
      ;; never hears about it: no event, no follow
      (shell-command->string
        (string-append "printf 'a\\nb-THEIRS\\nc\\n' > " p) "/tmp")
      (with-current-buffer p (lambda () (auto-revert-guard-save!)))
      (check-equal! (buffer-text p) "a\nb-THEIRS\nc\n"
                    "the save takes the file's change first, so it cannot lose it")

      (buffer-mark-saved! p)
      (buffer-kill! p)
      (shell-command->string (string-append "unlink " p) "/tmp"))))

(deftest 'a-serialized-buffer-never-follows-its-file
  "a chat's file is a serialization, so a follow is always a clobber"
  (lambda ()
    (let ((p "/tmp/compos-autorevert-chat-test.txt"))
      (shell-command->string
        (string-append "printf 'transcript\\n' > " p) "/tmp")
      (find-file p)
      (check-true! (auto-revert-follows? p)
                   "a plain file buffer follows")
      (buffer-set-local! p 'mode-name "chat-mode")
      (check-false! (auto-revert-follows? p)
                    "a chat buffer never follows")
      (buffer-set-local! p 'mode-name #f)
      (buffer-set-local! p 'auto-revert-exempt #t)
      (check-false! (auto-revert-follows? p)
                    "and neither does a buffer that opted out")
      (buffer-mark-saved! p)
      (buffer-kill! p)
      (shell-command->string (string-append "unlink " p) "/tmp"))))
