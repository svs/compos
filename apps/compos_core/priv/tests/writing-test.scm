;;; writing-test.scm --- the writing workspace.
;;;
;;; writing-mode is a look and a set of buffer-locals; write is the
;;; workspace that opens around a document. Both are Scheme, and every
;;; assertion here reads a Scheme value.
;;;
;;; Nothing here presses a key. Every behaviour is a named command, and a
;;; binding is a fact about a keymap — asserted as data, once, from the
;;; map itself.

(domain! 'testing)
(effects! '(read))

(deftest 'pasted-image-markdown-uses-angle-brackets-for-spaces
  "Markdown image destinations with spaces use angle brackets"
  (lambda ()
    (check-equal! (clipboard-image-destination "images/my sketch.png")
                  "<images/my sketch.png>"
                  "the destination is valid Markdown")))

(deftest 'pasted-image-extension-follows-the-clipboard-mime-type
  "The default image name follows the clipboard type"
  (lambda ()
    (check-equal! (clipboard-image-extension "image/jpeg") ".jpg"
                  "JPEG uses a JPG suffix")
    (check-equal! (clipboard-image-extension "image/png") ".png"
                  "PNG uses a PNG suffix")))

(deftest 'user-paste-hooks-run-before-writing-defaults-and-can-consume
  "a named userland handler can replace writing-mode paste policy"
  (lambda ()
    (let ((buf (test-buffer! "zz-writing-paste-hook.md" "")))
      (enable-minor-mode! buf "writing-mode")
      (add-paste-hook! "writing-mode" 'zz-user-paste
        (lambda (kind data mime)
          (if (equal? kind "image")
              (begin
                (insert! (string-append "[" mime ":" data "]"))
                #t)
              #f)))
      (with-current-buffer buf
        (lambda () (clipboard-image-paste! "bytes" "image/png")))
      (check-equal! (buffer-text buf) "[image/png:bytes]"
                    "the user handler consumed the image without prompting")
      ;; Re-evaluating the same init entry replaces it instead of stacking it.
      (add-paste-hook! 'writing-mode 'zz-user-paste
        (lambda (kind data mime) #f))
      (check-equal!
        (length
          (filter
            (lambda (entry)
              (and (equal? (car entry) "writing-mode")
                   (equal? (cadr entry) 'zz-user-paste)))
            *paste-hooks*))
        1
        "named registration is idempotent")
      (remove-paste-hook! "writing-mode" 'zz-user-paste)
      (disable-minor-mode! buf "writing-mode")
      (buffer-kill! buf))))

(deftest 'writing-paste-hooks-may-pass-text-through
  "returning #f preserves ordinary clipboard paste"
  (lambda ()
    (let ((buf (test-buffer! "zz-writing-text-paste.md" "")))
      (enable-minor-mode! buf "writing-mode")
      (add-paste-hook! "writing-mode" 'zz-observe-text
        (lambda (kind data mime) #f))
      (with-current-buffer buf
        (lambda () (clipboard-paste! "ordinary text")))
      (check-equal! (buffer-text buf) "ordinary text"
                    "unconsumed text uses the normal paste path")
      (remove-paste-hook! "writing-mode" 'zz-observe-text)
      (disable-minor-mode! buf "writing-mode")
      (buffer-kill! buf))))

(define (t--wr-locals buf)
  (map (lambda (k) (list k (buffer-local buf k)))
       '(window-class modeline-info line-numbers render-mode preview-renderer
         visual-line-mode writing-saved)))

(effects! '(write))

(deftest 'count-words-counts-whitespace-separated-words
  "runs of whitespace are one separator, and a newline is whitespace"
  (lambda ()
    (let ((buf (test-buffer! "zz-writing-count" "a b  c\nd\n")))
      (check-equal! (count-words buf) 4 "four words")
      (buffer-kill! buf))))

(deftest 'a-modes-layout-declaration-is-what-the-engine-applies
  "the layout is data, so the engine has nothing to interpret"
  (lambda ()
    (check-equal! (mode-layout "writing-layout")
                  (list 'h *window-third* 'self 'scratch-buffer 'writing-chat-buffer)
                  "the document, its scratch, and its chat")))

;;; --- a chat is not a document ---------------------------------------------------

(deftest 'a-chat-buffer-refuses-writing-mode-and-keeps-its-transcript-view
  "the transcript is a rendering, not prose to centre"
  (lambda ()
    (let ((buf (test-buffer! "*zz-wr-chat*" "")))
      (with-current-buffer buf (lambda () (set-mode! "chat-mode")))
      (buffer-set-local! buf 'render-mode "agent")
      (with-current-buffer buf (lambda () (run-command "writing-mode")))
      (check-false! (member "writing-mode" (or (buffer-local buf 'minor-modes) '()))
                    "the mode is refused")
      (check-equal! (buffer-local buf 'render-mode) "agent" "and the view is untouched")
      (buffer-kill! buf))))

(deftest 'restore-heals-a-chat-that-carries-a-stale-writing-mode-entry
  "a desktop written before the guard has writing-mode already applied"
  (lambda ()
    (let ((buf (test-buffer! "*zz-wr-chat-stale*" "")))
      (with-current-buffer buf (lambda () (set-mode! "chat-mode")))
      (buffer-set-local! buf 'minor-modes '("writing-mode"))
      (buffer-set-local! buf 'render-mode "markdown")
      (buffer-set-local! buf 'writing-saved
        '((face-remap ()) (style #f) (line-numbers #f)
          (render-mode "agent") (preview-renderer #f) (visual-line-mode #f)))

      (restore-minor-modes! buf)
      (check-false! (member "writing-mode" (or (buffer-local buf 'minor-modes) '()))
                    "the stale entry is gone")
      (check-equal! (buffer-local buf 'render-mode) "agent" "the saved view came back")
      (check-false! (buffer-local buf 'writing-saved) "and nothing is left to restore")
      (buffer-kill! buf))))

(deftest 'write-from-a-chat-without-a-group-document-stops-with-a-message
  "there is nothing to write, and it says so rather than opening an empty workspace"
  (lambda ()
    (let ((buf (test-buffer! "*zz-wr-chat-nodoc*" "")))
      (with-current-buffer buf (lambda () (set-mode! "chat-mode")))
      (buffer-set-local! buf 'render-mode "agent")
      (let ((mark (string-length (buffer-text "*Messages*"))))
        (with-current-buffer buf (lambda () (run-command "write")))
        (let ((said (buffer-text "*Messages*")))
          (check-contains! (substring said mark (string-length said)) "no document"
                           "it says why")))
      (check-false! (member "writing-mode" (or (buffer-local buf 'minor-modes) '()))
                    "and enters nothing")
      (check-equal! (buffer-local buf 'render-mode) "agent" "leaving the view alone")
      (buffer-kill! buf))))

;;; --- from here down, the tests enter the workspace -------------------------------
;;; write applies the writing layout, which splits a live frame into three
;;; panes and opens a chat in one of them.

(tests-need-a-disposable-editor!
  "runs M-x write, which splits the frame into the writing layout and opens a chat")

(define (t--wr-write! name text)
  (let ((buf (test-buffer! name text)))
    ;; one window, showing this buffer: write reads the frame, and
    ;; on-change! only fires while a buffer is visible
    (delete-other-windows!)
    (switch-to-buffer! buf)
    (run-command "write")
    buf))

(define (t--wr-done! &rest bufs)
  (for-each
    (lambda (b)
      (when (minor-mode-on? b "writing-mode") (disable-minor-mode! b "writing-mode")))
    (buffer-list))
  ;; write founds a group for the document; take the record with it
  (for-each
    (lambda (b)
      (when (buffer-known? b)
        (let ((id (buffer-group b)))
          (when (and id (group-record-by-id id)) (group-record-delete! id)))
        (buffer-kill! b)))
    bufs))

(deftest 'disabling-writing-mode-restores-the-previous-look
  "it composes with a major mode: org's look comes back exactly"
  (lambda ()
    (let ((buf (test-buffer! "zz-writing.org" "* head\nbody\n")))
      (with-current-buffer buf (lambda () (set-mode! "org-mode")))
      (let ((org-style (buffer-local buf 'style)))
        (check-contains! org-style "--default-size:14.5px;" "org's own size")

        ;; writing-mode toggles the look; write only ever enters the workspace
        (with-current-buffer buf (lambda () (run-command "writing-mode")))
        (check-contains! (buffer-local buf 'style) "--default-size:17px;" "the prose size")

        (with-current-buffer buf (lambda () (run-command "writing-mode")))
        (check-equal! (buffer-local buf 'style) org-style "org's look is back")
        (check-equal! (buffer-local buf 'minor-modes) '() "and no minor mode is left")
        (check-equal! (t--wr-locals buf)
                      '((window-class #f) (modeline-info #f) (line-numbers #f)
                        (render-mode #f) (preview-renderer #f)
                        (visual-line-mode #f) (writing-saved #f))
                      "nor any local it set"))
      (t--wr-done! buf))))

(deftest 'writing-llm-configuration-lands-on-the-scratch-only
  "the document is prose; the scratch is where a model is asked"
  (lambda ()
    (let* ((saved writing-model)
           (buf (begin (customize-set! 'writing-model "openai:test-writer")
                       (t--wr-write! "zz-writing-config.md" "Draft.\n")))
           (scratch (string-append "*scratch:" buf "*")))
      (check-equal! (buffer-local buf 'writing-model) "openai:test-writer"
                    "the document carries the setting")
      (check-contains! (buffer-local buf 'writing-instructions) "Preserve their voice"
                       "and the instructions")
      (check-false! (member "llm-mode" (or (buffer-local buf 'minor-modes) '()))
                    "but llm-mode is not on the document")

      (check-equal! (buffer-local scratch 'llm-model) "openai:test-writer"
                    "the scratch holds the model")
      (check-contains! (buffer-local scratch 'writing-instructions) "Preserve their voice"
                       "and the instructions")
      (check-equal! (buffer-local scratch 'minor-modes) '("llm-mode")
                    "and llm-mode is on it")

      (customize-set! 'writing-model saved)
      (t--wr-done! buf scratch))))

(deftest 'writing-presets-are-applied-and-existing-presets-are-restored
  "a preset removed from the setting must not linger on the scratch"
  (lambda ()
    (let ((saved writing-presets)
          (buf "zz-writing-presets.md"))
      (test-buffer! buf "Draft.\n")
      (buffer-set-local! buf 'chat-presets '(project compos))
      (set! writing-presets '(compos web))
      (switch-to-buffer! buf)
      (run-command "write")

      (let ((scratch (string-append "*scratch:" buf "*")))
        (check-equal! (buffer-local scratch 'chat-presets) '(compos web project)
                      "the writing presets ride over the document's own")

        ;; a live customization is rebuilt from the ORIGINAL document value,
        ;; so a preset removed from the setting does not linger
        (customize-set! 'writing-presets '(research))
        (check-equal! (buffer-local scratch 'chat-presets) '(compos research project)
                      "the removed preset is gone")

        (run-command "write")
        (check-equal! (buffer-local buf 'chat-presets) '(project compos)
                      "and the document keeps its own")
        (set! writing-presets saved)
        (t--wr-done! buf scratch)))))

(deftest 'customizing-the-measure-repaints-live-writing-buffers
  "the setting is not read once at entry"
  (lambda ()
    (let ((buf (t--wr-write! "zz-writing-measure" "words here\n")))
      (check-contains! (buffer-local buf 'style) "--writing-measure:62ch;" "the default measure")
      (customize-set! 'writing-measure "44ch")
      (check-contains! (buffer-local buf 'style) "--writing-measure:44ch;" "the new one, live")
      (customize-set! 'writing-measure "62ch")
      (t--wr-done! buf))))

(deftest 'restore-minor-modes-re-runs-the-writing-setup-once
  "the reload path: setup runs again and adds no second hook"
  (lambda ()
    (let ((buf (t--wr-write! "zz-writing-restore" "some prose\n")))
      (restore-minor-modes! buf)
      (check-equal! (length (filter (lambda (h) (equal? (car h) buf)) *writing-hooks*)) 1
                    "one hook, not two")
      (check-equal! (buffer-local buf 'window-class) "writing" "the look is back")
      (check-equal! (buffer-local buf 'modeline-info) "2 words · 1 min" "and the count")
      (t--wr-done! buf))))

(deftest 'the-word-count-is-recomputed-from-the-buffer
  "the counter and its label are Scheme; the delivery is the one exception"
  (lambda ()
    (let ((buf (t--wr-write! "zz-writing-live.md" "")))
      (check-equal! (buffer-local buf 'modeline-info) "0 words" "an empty document")

      ;; the hook that will call it is registered
      (check-equal! (length (filter (lambda (h) (equal? (car h) buf)) *writing-hooks*)) 1
                    "one change hook watches the document")

      ;; and the counter it calls. This test cannot watch the hook FIRE:
      ;; write registered that closure during THIS eval, and a closure only
      ;; reaches shared state when the eval exits (see Env's two-tier
      ;; store), so a cross-process call to it now sees an unflushed frame.
      ;; One eval per test means one eval cannot both register a hook and
      ;; wait for it. writing_test.exs holds that one delivery test.
      (buffer-insert! buf 0 "hello brave new world")
      (writing--update-count! buf)
      (check-equal! (buffer-local buf 'modeline-info) "4 words · 1 min"
                    "the count and the read time")
      (t--wr-done! buf))))

(deftest 'visual-line-mode-toggles-visual-row-motion-for-any-buffer
  "it is a minor mode like any other, on any buffer"
  (lambda ()
    (let ((buf (test-buffer! "zz-writing-visual" "one long line\n")))
      (delete-other-windows!)
      (switch-to-buffer! buf)
      (run-command "visual-line-mode")
      (check-true! (buffer-local buf 'visual-line-mode) "the local is on")
      (check-true! (member "visual-line-mode" (buffer-local buf 'minor-modes)) "and the mode")

      (run-command "visual-line-mode")
      (check-false! (buffer-local buf 'visual-line-mode) "off again")
      (check-false! (member "visual-line-mode" (or (buffer-local buf 'minor-modes) '()))
                    "and the mode is gone")
      (t--wr-done! buf))))

(deftest 'writing-mode-enables-the-centered-prose-look
  "presentation only: the panes and the group belong to write"
  (lambda ()
    (let ((buf (test-buffer! "zz-writing-look" "one two three\n")))
      (delete-other-windows!)
      (switch-to-buffer! buf)
      (run-command "writing-mode")
      (check-true! (member "writing-mode" (buffer-local buf 'minor-modes))
                   "the writing mode is on")
      (check-true! (member "preview-mode" (buffer-local buf 'minor-modes))
                   "the preview mode owns the writing surface")
      (check-equal! (buffer-local buf 'line-numbers) "off" "no line numbers")
      (check-equal! (buffer-local buf 'window-class) "writing" "the writing measure")
      (check-equal! (buffer-local buf 'render-mode) "markdown" "rendered as markdown")
      (check-equal! (buffer-local buf 'preview-renderer) "markdown" "by the markdown renderer")
      (check-true! (buffer-local buf 'visual-line-mode) "with visual lines")
      (check-false! (buffer-local buf 'group) "and no group: that is write's job")
      (t--wr-done! buf))))

(deftest 'writing-mode-reapply-keeps-a-disabled-preview-off
  "writing setup respects the preview mode state after first entry"
  (lambda ()
    (let ((buf (test-buffer! "zz-writing-source.md" "one two three\n")))
      (with-current-buffer buf
        (lambda ()
          (run-command "writing-mode")
          (run-command "preview-mode")
          (check-false! (minor-mode-on? buf "preview-mode")
                        "the user chose source view")
          (restore-minor-modes! buf)
          (check-false! (buffer-local buf 'render-mode)
                        "mode reapply preserves source view")))
      (t--wr-done! buf))))

(deftest 'the-writing-selection-commands-extend-the-region
  "point moves and the mark stays where the selection started"
  (lambda ()
    (let ((buf (t--wr-write! "zz-writing-select.md" "one two three")))
      (with-current-buffer buf
        (lambda ()
          (end-of-buffer!)
          (run-command "writing-select-backward")
          (run-command "writing-select-backward")
          (check-equal! (buffer-point buf) 11 "two characters back")
          (check-equal! (mark) 13 "and the mark held")

          (run-command "writing-select-forward")
          (check-equal! (buffer-point buf) 12 "forward again")
          (check-equal! (mark) 13 "with the same mark")))
      (t--wr-done! buf))))

(deftest 'the-writing-word-and-line-selections-reach-their-boundaries
  "a word, a line and the whole document, each from one command"
  (lambda ()
    (let ((buf (t--wr-write! "zz-writing-select2.md" "one two three")))
      (with-current-buffer buf
        (lambda ()
          (end-of-buffer!)
          (run-command "writing-select-backward-word")
          (check-equal! (buffer-point buf) 8 "back one word")

          (goto-char! 4)
          (run-command "writing-select-line-end")
          (check-equal! (buffer-point buf) 13 "to the end of the line")

          (goto-char! 4)
          (run-command "writing-select-buffer-start")
          (check-equal! (buffer-point buf) 0 "and to the start of the document")))
      (t--wr-done! buf))))

(deftest 'write-opens-a-grouped-plain-scratch-beside-the-document
  "three panes: the document, its scratch, its chat"
  (lambda ()
    (let* ((buf (t--wr-write! "zz-writing-scratch.md" "# Draft\n\nMain text.\n"))
           (scratch (string-append "*scratch:" buf "*"))
           (names (map cadr (window-list))))
      (check-equal! (current-buffer) buf "the document has the focus")
      (check-equal! (length names) 3 "three panes")
      (check-true! (member buf names) "the document is one")
      (check-true! (member scratch names) "and its scratch another")

      (check-equal! (buffer-local buf 'scratch-buffer) scratch "the document names its scratch")
      (check-false! (buffer-local scratch 'scratch-owner) "the document does not own it")
      (check-equal! (buffer-group-role scratch (buffer-group buf)) "scratch"
                    "the group membership owns the scratch")
      (check-equal! (buffer-local scratch 'scratch-from) buf
                    "navigation still returns to the document")
      ;; the ExUnit original read the LEGACY 'group local, which a group id
      ;; replaced; it has been asserting #f == buf ever since. What the
      ;; workspace means is that both sit in one group.
      (check-true! (buffer-group buf) "the document founds a group")
      (check-equal! (buffer-group scratch) (buffer-group buf) "and the scratch joins it")
      (check-equal! (buffer-group-summary buf) buf "which is named for the document")
      (t--wr-done! buf scratch))))

(deftest 'write-reduces-a-three-window-frame-to-the-writing-layout
  "whatever was on screen, the workspace is the same three panes"
  (lambda ()
    (let ((buf "zz-writing-layout.md")
          (other "zz-writing-other"))
      (test-buffer! buf "# Draft\n\nMain text.\n")
      (test-buffer! other "")
      ;; three windows: the document, and two of other work
      (delete-other-windows!)
      (switch-to-buffer! buf)
      (split-window! 'h 0.5)
      (split-window! 'v 0.5)
      (other-window!)
      (switch-to-buffer! other)
      (select-window! (window-showing buf))
      (check-equal! (length (window-list)) 3 "three windows before")

      (run-command "write")
      (let ((names (map cadr (window-list))))
        (check-equal! (length names) 3 "three panes after")
        (check-true! (member buf names) "the document")
        (check-true! (member (string-append "*scratch:" buf "*") names) "and its scratch"))
      (t--wr-done! buf other (string-append "*scratch:" buf "*")))))

(deftest 'the-companion-chat-opens-into-the-documents-group
  "an optional third voice, in the same group as the document"
  (lambda ()
    (let* ((buf (t--wr-write! "zz-writing-companion.md" "Draft.\n"))
           (companion (string-append "*chat:" buf "*")))
      (switch-to-buffer! buf)
      (run-command "chat-companion")
      (check-equal! (current-buffer) companion "the companion has the focus")
      (check-equal! (buffer-local companion 'mode-name) "chat-mode" "it is a chat")
      (check-equal! (buffer-group companion) (buffer-group buf) "in the document's group")
      (check-contains! (buffer-text companion) (string-append "companion · " buf)
                       "and it says whose it is")
      (t--wr-done! buf companion))))
