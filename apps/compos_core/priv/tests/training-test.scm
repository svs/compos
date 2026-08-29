;;; training-test.scm --- training.scm: curriculum and tour launcher.

(domain! 'testing)
(effects! '(write))

(tests-need-a-disposable-editor!
  "replaces the frame layout to verify the companion window")

(deftest 'training-points-at-the-real-curriculum
  "the bot opens the repository document instead of generated prose"
  (lambda ()
    (check-true! (string-suffix? "/docs/training.md" (training-document-path))
                 "the curriculum path")
    (check-true! (file-exists? (training-document-path)) "the curriculum exists")))

;; the visible text of every "- [Title](#anchor)" row. An action link
;; points at a command, not at a heading, so it is not one of these.
(define (t--contents-titles guide)
  (filter (lambda (x) x)
    (map (lambda (line)
           (and (string-prefix? "- [" line)
                (let ((i (string-index line "](#")))
                  (and i (substring-bytes line 3 i)))))
         (string-split guide "\n"))))

(deftest 'training-curriculum-has-working-tour-anchors
  "every lesson the contents lists is a heading, and the action link works"
  (lambda ()
    ;; Naming three anchors sent this test red the day a heading was
    ;; reworded, which is an edit to the guide and not a broken guide.
    ;; The contents must reach the lessons: that is the fact to hold.
    (let* ((guide (read-file (training-document-path)))
           (titles (t--contents-titles guide)))
      (check-true! (>= (length titles) 5) "the contents lists the lessons")
      (for-each
        (lambda (title)
          (check-contains! guide (string-append "## " title)
                           (string-append "a heading for " title)))
        titles)
      (check-contains! guide "compos:training/summarize-mode" "the action link"))))

(deftest 'training-tour-starts-with-m-x-and-waits
  "the first chat turn begins an interactive lesson instead of dumping the guide"
  (lambda ()
    (let ((prompt (training-tour-prompt)))
      (check-contains! prompt "Begin with M-x" "the first lesson")
      (check-contains! prompt "one short step per turn" "the pace")
      (check-contains! prompt "wait for the user" "the interaction"))))

(deftest 'training-summary-names-the-current-major-mode
  "the companion receives a concrete mode lesson request"
  (lambda ()
    (test-buffer! "*zz-training-mode*" "hello")
    (with-current-buffer "*zz-training-mode*"
      (lambda () (set-mode! "text-mode")))
    (let ((prompt (training-mode-summary-prompt "*zz-training-mode*")))
      (check-contains! prompt "text-mode" "the mode name")
      (check-contains! prompt "shortcut keys" "the lesson scope")
      (check-contains! prompt "M-x" "the command model"))
    (buffer-kill! "*zz-training-mode*")))

(deftest 'training-registers-its-launcher-and-links
  "the direct launcher is discoverable through M-x and rendered links"
  (lambda ()
    (check-true! (member "training-bot" (command-names)) "the bot command")
    (check-true! (member "training-companion-summarize-mode" (command-names))
                 "the summary command")
    (check-true! (assoc "training" *preview-link-verbs*) "the link handler")))

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
