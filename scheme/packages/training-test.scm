;;; training-test.scm --- training.scm: curriculum and tour launcher.

(domain! 'testing)
(effects! '(write))

(tests-need-a-disposable-editor!
  "replaces the frame layout to verify the companion window")

(define (t--training-clean!)
  (when (minibuffer-state) (minibuffer-cancel!))
  (when (buffer-known? "TUTORIAL") (buffer-kill! "TUTORIAL"))
  (when (file-exists? (training-state-path))
    (delete-file-path! (training-state-path) #t)))

(define (t--training-answer! key)
  (minibuffer-change! key)
  (not (minibuffer-state)))

(deftest 'training-opens-an-editable-copy-not-the-master
  "the tutorial is a writable non-file buffer copied from the master"
  (lambda ()
    (t--training-clean!)
    (let ((buf (training-fresh-tutorial!)))
      (check-equal! buf "TUTORIAL" "the Emacs buffer name")
      (check-false! (buffer-path buf) "the master is not visited")
      (check-false! (buffer-read-only? buf) "the exercise is editable")
      (check-equal! (buffer-text buf) (read-file (training-document-path))
                    "the fresh copy"))
    (t--training-clean!)))

(deftest 'training-reopens-the-live-copy-without-a-question
  "C-h t selects the live personal copy without interrupting the reader"
  (lambda ()
    (t--training-clean!)
    (training--load-tutorial! "my live copy\n" 3)
    (buffer-insert! "TUTORIAL" (buffer-size "TUTORIAL") "one edit")
    (training--open-tutorial!)
    (check-equal! (current-buffer) "TUTORIAL" "the live copy is selected")
    (check-equal! (buffer-text "TUTORIAL") "my live copy\none edit"
                  "its edits stay intact")
    (check-false! (minibuffer-state) "no resume or revert question")
    (t--training-clean!)))

(deftest 'training-resumes-saved-progress-without-a-question
  "C-h t restores saved text and point directly when no live copy exists"
  (lambda ()
    (t--training-clean!)
    (let ((buf (training--load-tutorial! "saved copy\n" 6)))
      (training-save-state! buf)
      (buffer-kill! buf))
    (training--open-tutorial!)
    (check-equal! (buffer-text "TUTORIAL") "saved copy\n" "the saved text")
    (check-equal! (buffer-point "TUTORIAL") 6 "the saved point")
    (check-false! (minibuffer-state) "no resume question")
    (t--training-clean!)))

(deftest 'only-the-C-x-k-policy-asks-about-tutorial-progress
  "C-x k owns retention; shared kill callers neither ask nor keep a stale save"
  (lambda ()
    (t--training-clean!)
    (let ((buf (training--load-tutorial! "older saved copy\n" 5)))
      (training-save-state! buf)
      (buffer-insert! buf (buffer-size buf) "new work"))
    (switch-to-buffer! "TUTORIAL")
    (run-command "training-kill-buffer")
    (run-command "minibuffer-confirm")
    (check-true! (t--training-answer! "n") "the question closes")
    (check-false! (buffer-known? "TUTORIAL") "C-x k kills the tutorial")
    (check-false! (file-exists? (training-state-path)) "the old save is removed")

    (training--load-tutorial! "ordinary kill\n" 4)
    (buffer-goto! "TUTORIAL" 5)
    (kill-buffer-confirm! "TUTORIAL" (lambda (killed?) #t))
    (check-false! (buffer-known? "TUTORIAL") "the ordinary kill completes")
    (check-false! (minibuffer-state) "the shared helper did not ask")
    (t--training-clean!)))

(deftest 'training-tour-selects-the-companion-window
  "the companion pops up as the active window beside the curriculum"
  (lambda ()
    (let ((document (test-buffer! "*zz-training-document*" "lesson"))
          (chat (test-buffer! "*zz-training-chat*" "hello")))
      (delete-other-windows!)
      (switch-to-buffer! "*scratch*")
      (display-buffer-other-window! document)
      (training--show-chat-beside! document chat)
      (check-true! (window-showing document) "the curriculum stays visible")
      (check-true! (window-showing chat) "the companion is visible")
      (check-equal! (window-buffer (active-window)) chat
                    "the companion receives focus")
      (switch-to-buffer! "*scratch*")
      (delete-other-windows!)
      (buffer-kill! document)
      (buffer-kill! chat))))
