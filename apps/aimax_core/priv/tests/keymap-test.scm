;;; keymap-test.scm --- the keymap as data, and the seam under it.
;;;
;;; A key runs a command. Those are two facts, and a test that presses
;;; the key checks them as one: when it fails, the reader cannot tell
;;; whether the binding moved or the behaviour broke. Worse, it takes
;;; 300ms to say so, because it drives the whole UI to ask.
;;;
;;; So read the map, and run the command. The seam between them is the
;;; contract, and it is the thing worth naming:
;;;
;;;   (check-equal! (key-binding "C-x b") "group-switch-to-buffer" ...)
;;;   ... then run group-switch-to-buffer and check what it did.
;;;
;;; A binding that moves fails the first check and nothing else. Eleven
;;; switcher tests failed together tonight because C-x b changed hands,
;;; and not one of them said so.

(domain! 'testing)
(effects! '(read))

;; key-binding answers what a key means HERE: the local map wins, then
;; the read-only map, then the global one. A test that does not say where
;; it stands reads whatever buffer the editor happens to show — with a
;; prompt open, C-g answers minibuffer-cancel. So pin a plain buffer.
(define (with-plain-buffer thunk)
  (let ((buf "*zzkm-plain*"))
    (unless (buffer-exists? buf) (buffer-create buf))
    (let ((out (with-current-buffer buf thunk)))
      (buffer-kill! buf)
      out)))

;; Emacs is the reference, so these are the keys it puts where it puts
;; them. A rebinding here is a decision, and it should have to edit a
;; test that says so out loud.
(define *keymap-test-core*
  '(("C-x C-f" "find-file")
    ("C-x C-s" "save-buffer")
    ("C-x o"   "other-window")
    ("C-x 0"   "delete-window")
    ("C-x 1"   "delete-other-windows")
    ("C-x 2"   "split-window-below")
    ("C-x 3"   "split-window-right")
    ("C-s"     "isearch-forward")
    ("C-y"     "yank")
    ("M-x"     "execute-extended-command")
    ("M-:"     "eval-expression")))

(deftest 'the-core-keys-are-where-emacs-puts-them
  "the bindings a person arrives already knowing"
  (lambda ()
    (with-plain-buffer
      (lambda ()
        (for-each
          (lambda (row)
            (check-equal! (key-binding (car row)) (nth 1 row)
                          (string-append (car row) " runs the Emacs command")))
          *keymap-test-core*)))))

(deftest 'every-global-binding-names-a-live-command
  "a key bound to a command that does not exist is a dead key"
  (lambda ()
    (let ((names (command-names)))
      (for-each
        (lambda (row)
          (let ((keys (car row)) (cmd (nth 1 row)))
            (check-true! (member cmd names)
                         (string-append keys " runs \"" cmd "\", which no package defines"))))
        (global-keys)))))

(deftest 'a-prefix-reads-as-a-prefix
  "C-x holds a map, so it answers prefix and never a command"
  (lambda ()
    (with-plain-buffer
      (lambda ()
        (check-equal! (key-binding "C-x") 'prefix "C-x is a prefix")
        (check-equal! (key-binding "C-c") 'prefix "C-c is a prefix")
        (check-false! (key-binding "C-x zzqx") "an unbound sequence answers #f")))))

(deftest 'key-binding-takes-a-string-or-a-list
  "the introspection a keymap test leans on, in both shapes"
  (lambda ()
    (with-plain-buffer
      (lambda ()
        (check-equal! (key-binding "C-x b") (key-binding (list "C-x" "b"))
                      "a written sequence and a list agree")
        ;; a bad argument used to raise inside the Editor call, and an
        ;; Editor that dies loses every buffer's local keymap. An empty
        ;; sequence is a prefix of every key, so prefix is the answer —
        ;; what matters is that it answers at all.
        (check-equal! (key-binding "") 'prefix
                      "an empty sequence answers prefix, it does not raise")))))

;;; --- the seam: the map names a command, the command does the work ------------

(deftest 'C-x-b-names-the-group-aware-switcher
  "the binding half of the seam"
  (lambda ()
    (with-plain-buffer
      (lambda ()
        (check-equal! (key-binding "C-x b") "group-switch-to-buffer"
                      "C-x b runs the group-aware buffer prompt")
        (check-true! (member "group-switch-to-buffer" (command-names))
                     "and that command exists")))))

(deftest 'the-switcher-command-opens-a-prompt
  "the behaviour half of the seam, without pressing anything"
  (lambda ()
    (let ((buf "*zzkm-a*") (other "*zzkm-b*"))
      (buffer-create buf)
      (buffer-create other)
      (with-current-buffer buf
        (lambda ()
          (run-command "group-switch-to-buffer")
          ;; minibuffer-selected answers nil with no prompt open, and nil
          ;; is TRUE in this Scheme — ask whether it is a string, never
          ;; whether it is truthy
          (check-true! (string? (minibuffer-selected))
                       "the command offered a buffer to switch to")
          (run-command "minibuffer-cancel")
          (check-false! (string? (minibuffer-selected))
                        "and the cancel left nothing selected")))
      (buffer-kill! buf)
      (buffer-kill! other))))

(deftest 'the-modal-switcher-still-answers-its-own-command
  "C-x b moved, the switcher did not go away"
  (lambda ()
    (check-true! (member "switch-to-buffer" (command-names))
                 "the modal switcher keeps its command")
    (with-plain-buffer
      (lambda ()
        (check-equal! (key-binding "C-x G") "switch-groups"
                      "and the groups view keeps its key")))))
