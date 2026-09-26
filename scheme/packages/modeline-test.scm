;;; modeline-test.scm — buffer modelines keep compact names.

(domain! 'testing)
(effects! '(write execute))

(define t--modeline-root
  (string-append (compos-home) "/zz-modeline-project"))

(define (t--modeline-reset!)
  (shell-command->string (string-append "rm -rf " t--modeline-root)))

(deftest 'a-project-file-keeps-a-project-relative-buffer-modeline-name
  "the buffer modeline stays compact while the frame bar owns the full path"
  (lambda ()
    (t--modeline-reset!)
    (make-directory! (string-append t--modeline-root "/.git"))
    (let ((path (string-append t--modeline-root "/lib/example.scm")))
      (make-directory! (string-append t--modeline-root "/lib"))
      (write-file! path "(display \"example\")\n")
      (visit path)
      (dashboard--sync! path)
      (check-equal! (buffer-modeline-name path) "lib/example.scm"
                    "the buffer modeline policy returns project coordinates")
      (check-equal! (buffer-local path 'modeline-name) "lib/example.scm"
                    "the rendered buffer modeline stores the compact name")
      (buffer-kill! path))
    (t--modeline-reset!)))

(deftest 'a-non-file-buffer-keeps-its-buffer-name-in-the-modeline
  "the file path policy does not rename a non-file buffer"
  (lambda ()
    (let ((buf "*zz-modeline-non-file*"))
      (test-buffer! buf "")
      (check-equal! (buffer-modeline-name buf) buf
                    "the non-file buffer keeps its name")
      (buffer-kill! buf))))

(deftest 'a-chat-shows-its-working-directory-in-the-modeline
  "the chat modeline shows the directory where its tools run"
  (lambda ()
    (let ((buf "*chat:zz-modeline-directory*")
          (dir (string-append (compos-home) "/")))
      (test-buffer! buf "")
      (buffer-set-local! buf 'mode-name "chat-mode")
      (buffer-set-local! buf 'default-directory dir)
      (switch-to-buffer! buf)
      (dashboard--sync! buf)
      (check-equal! (buffer-directory buf) dir
                    "the chat has its own working directory")
      (check-equal! (buffer-local buf 'modeline-project)
                    (abbreviate-file-name dir)
                    "the compact modeline shows that directory")
      (buffer-kill! buf))))

;; the dashboard line pulls the summary and the jj line from state, so a
;; buffer with no file shows both when it has them
(define (t--dseg-value blocks key)
  (let loop ((bs blocks))
    (cond ((null? bs) #f)
          ((and (pair? (car bs))
                (member (plist-get (car bs) 'tag) '("c-field" "c-action"))
                (let ((kids (plist-get (car bs) 'children)))
                  (and (pair? kids)
                       (equal? (plist-get (car kids) 'text) key))))
           (cadr (car (plist-get (cadr (plist-get (car bs) 'children)) 'segs))))
          (else (loop (cdr bs))))))

;; the class of the segment a key names, so a test can read the hook the
;; headline's own CSS keys off
(define (t--dseg-class blocks key)
  (let loop ((bs blocks))
    (cond ((null? bs) #f)
          ((and (pair? (car bs))
                (member (plist-get (car bs) 'tag) '("c-field" "c-action"))
                (let ((kids (plist-get (car bs) 'children)))
                  (and (pair? kids)
                       (equal? (plist-get (car kids) 'text) key))))
           (plist-get (car bs) 'class))
          (else (loop (cdr bs))))))

;; The group badge leads the headline, so the wide block is no longer the
;; first one. Find it by its class instead of by its position.
(define (t--dash-wide blocks)
  (let loop ((bs blocks))
    (cond ((null? bs) #f)
          ((and (pair? (car bs))
                (string-contains? (or (plist-get (car bs) 'class) "") "dseg-wide"))
           (car bs))
          (else (loop (cdr bs))))))

(deftest 'a-chat-shows-its-running-summary-in-the-dashboard-line
  "the summary segment carries the chat-summary local; a chat without one shows no segment"
  (lambda ()
    (let ((buf "*chat:zz-modeline-summary*"))
      (test-buffer! buf "")
      (buffer-set-local! buf 'mode-name "chat-mode")
      (check-equal! (t--dseg-value (dashboard-line-blocks buf) "summary") #f
                    "no summary yet, no segment")
      (buffer-set-local! buf 'chat-summary "The user is testing the bar.")
      (let* ((blocks (dashboard-line-blocks buf))
             (wide (t--dash-wide blocks))
             (kids (plist-get wide 'children)))
        (check-equal! (length kids) 1
                      "the summary has no redundant label")
        (check-equal! (cadr (car (plist-get (car kids) 'segs)))
                      "The user is testing the bar."
                      "the segment shows the paragraph"))
      ;; the summary takes the one wide slot; the jj line steps back
      (let ((dir "/zz-modeline-sum-repo/") (root "/zz-modeline-sum-repo")
            (lines *jj-lines*) (roots *jj-dir-roots*))
        (buffer-set-local! buf 'default-directory dir)
        (set! *jj-dir-roots* (cons (list dir root) *jj-dir-roots*))
        (set! *jj-lines* (cons (list root "jj: open") *jj-lines*))
        (check-equal! (t--dseg-value (dashboard-line-blocks buf) "jj") #f
                      "no jj segment beside a summary")
        (set! *jj-lines* lines)
        (set! *jj-dir-roots* roots))
      (buffer-kill! buf))))

(deftest 'a-chat-without-a-file-shows-the-jj-line-of-its-directory
  "the jj segment comes from the per-root cache through the buffer's directory; a plain list does not live in a repo"
  (lambda ()
    (let ((buf "*chat:zz-modeline-jj*")
          (dir "/zz-modeline-jj-repo/sub/")
          (root "/zz-modeline-jj-repo")
          (lines *jj-lines*)
          (roots *jj-dir-roots*))
      (test-buffer! buf "")
      (buffer-set-local! buf 'default-directory dir)
      (set! *jj-dir-roots* (cons (list dir root) *jj-dir-roots*))
      (set! *jj-lines* (cons (list root "jj: the open change") *jj-lines*))
      (check-equal! (jj-modeline-line buf) #f
                    "a buffer that is not a file, a listing, or a chat shows no jj line")
      (buffer-set-local! buf 'mode-name "chat-mode")
      (check-equal! (jj-modeline-line buf) "jj: the open change"
                    "the line comes from the cache, not from a shell call")
      (check-equal! (t--dseg-value (dashboard-line-blocks buf) "jj") "jj: the open change"
                    "the dashboard line shows it")
      (set! *jj-lines* lines)
      (set! *jj-dir-roots* roots)
      (buffer-kill! buf))))

(deftest 'a-narrow-window-keeps-the-headline-segments-its-mode-declared
  "narrow-cols is where narrow starts for the headline as for every list"
  (lambda ()
    (let ((buf "*chat:zz-modeline-narrow*"))
      (test-buffer! buf "")
      (buffer-set-local! buf 'mode-name "chat-mode")
      (check-equal! (dash--headline-keep buf (+ narrow-cols 1)) #f
                    "a wide window keeps every segment")
      (check-equal! (dash--headline-keep buf (- narrow-cols 1)) #f
                    "chat title and metadata stay visible at every width")
      (buffer-set-local! buf 'mode-name "text-mode")
      (check-equal! (dash--headline-keep buf (- narrow-cols 1)) #f
                    "a mode that declares nothing keeps every segment")
      (buffer-kill! buf))))

(deftest 'chat-header-always-starts-with-a-prominent-title
  "a chat without a generated title still names itself before the metadata"
  (lambda ()
    (let ((buf "*chat:zz-header-untitled*"))
      (test-buffer! buf "")
      (buffer-set-local! buf 'mode-name "chat-mode")
      (let* ((blocks (dashboard-line-blocks buf))
             (title (t--dash-wide blocks))
             (value (car (plist-get title 'children))))
        ;; this buffer belongs to no group, so it wears no badge and says
        ;; nothing in its place: the title takes the corner itself
        (check-equal! (dash--group-badge buf) #f
                      "no group, no badge")
        (check-true! (string-contains? (plist-get (car blocks) 'class)
                                       "dseg-chat-title")
                     "so the title leads the headline")
        (check-equal! (cadr (car (plist-get value 'segs))) buf
                      "an untitled chat uses its buffer name")
        (check-equal! (car (car (plist-get value 'segs))) "dseg-strong"
                      "the title is emphasized"))
      (buffer-kill! buf))))

(deftest 'a-dropped-headline-segment-takes-no-rule-with-it
  "the rules separate whatever survives, so none is ever left dangling"
  (lambda ()
    (check-equal! (dash--ruled '()) '() "nothing to separate")
    (check-equal! (length (dash--ruled '(a))) 1 "one segment, no rule")
    (let ((two (dash--ruled '(a b))))
      (check-equal! (length two) 3 "two segments, one rule")
      (check-equal! (plist-get (cadr two) 'class) "dseg-rule"
                    "and the rule stands between them"))))

(define (t--dash-meta? blocks)
  (let loop ((bs blocks))
    (cond ((null? bs) #f)
          ((and (pair? (car bs))
                (equal? (plist-get (car bs) 'class) "dseg-meta")) #t)
          (else (loop (cdr bs))))))

(deftest 'a-wide-window-keeps-the-headline-on-one-row
  "a narrow window stacks metadata beneath the title; a wide one keeps every segment inline"
  (lambda ()
    (let ((buf (test-buffer! "*zz-modeline-headline-layout*" ""))
          (top (list (list 'group 'badge) (list 'wide 'title)))
          (meta (list (list 'mode 'mode-block) (list 'llm 'llm-block))))
      (check-false! (t--dash-meta? (dash--assemble-headline top meta #f buf))
                    "a wide window wraps no metadata row")
      (check-true! (t--dash-meta? (dash--assemble-headline top meta #t buf))
                   "a narrow window stacks the metadata beneath the title")
      (buffer-kill! buf))))

(deftest 'an-llm-config-change-refreshes-the-dashboard-line
  "llm-config-changed! runs the hook the dashboard subscribes to, so the headline re-reads the model"
  (lambda ()
    (let ((buf "*zz-modeline-llm-changed*")
          (was (current-buffer)))
      (test-buffer! buf "")
      (switch-to-buffer! buf)
      (window-configuration-changed!)
      (buffer-set-local! buf 'llm-model "m-before")
      (dashboard--sync! buf)
      (check-contains! (or (buffer-local buf 'dashboard-line) "") "m-before"
                       "the headline shows the model before the change")
      (buffer-set-local! buf 'llm-model "m-after")
      (llm-config-changed! buf)
      (check-contains! (or (buffer-local buf 'dashboard-line) "") "m-after"
                       "the hook re-reads the model after the change")
      (switch-to-buffer! was)
      (buffer-kill! buf))))

(deftest 'a-chats-title-is-the-first-summary-and-does-not-move
  "the first label the running summary writes becomes the title; later paragraphs move the summary only, and the bar and the list rows show the title"
  (lambda ()
    (let ((buf "*chat:zz-modeline-title*"))
      (test-buffer! buf "")
      (buffer-set-local! buf 'mode-name "chat-mode")
      (buffer-set-local! buf 'chat-turn-active #t)   ; no archive write here
      (buffer-set-local! buf 'agent-saved-mark 0)
      (buffer-set-local! buf 'agent-blocks '())
      (chat-summary-land! buf "Adding titles to chats.")
      (chat-summary-land! buf "Rewriting the dashboard segment.")
      (check-equal! (buffer-local buf 'dashboard-dirty) #t
                    "background summaries leave one pending dashboard update")
      (check-equal! (buffer-local buf 'dashboard-line-blocks) #f
                    "background summaries build no dashboard blocks")
      (check-equal! (buffer-local buf 'chat-title) "Adding titles to chats."
                    "the title is the label the chat wrote first")
      (check-equal! (chat-title-of buf) "Adding titles to chats."
                    "and a second paragraph does not move it")
      (check-equal! (buffer-local buf 'chat-summary) "Rewriting the dashboard segment."
                    "the running summary is still the latest")
      (let* ((blocks (dashboard-line-blocks buf))
             (wide (t--dash-wide blocks))
             (kids (plist-get wide 'children)))
        (check-equal! (cadr (car (plist-get (car kids) 'segs)))
                      "Adding titles to chats."
                      "the bar names the chat, not what it is doing now"))
      (check-equal! (chat-prompt-label buf) "Adding titles to chats."
                    "and every list row leads with the same name")
      (buffer-kill! buf))))

(deftest 'a-chat-title-holds-at-most-six-words
  "the card writer answers with a longer factual title; the chat clips it to a label"
  (lambda ()
    (let ((buf "*chat:zz-modeline-title-words*"))
      (test-buffer! buf "")
      (buffer-set-local! buf 'mode-name "chat-mode")
      (buffer-set-local! buf 'chat-turn-active #t)
      (buffer-set-local! buf 'agent-saved-mark 0)
      (buffer-set-local! buf 'agent-blocks '())
      (chat-summary-land! buf "Finding where the chat title is set in code")
      (check-equal! (buffer-local buf 'chat-title)
                    "Finding where the chat title is"
                    "the first label keeps only its first six words")
      (check-equal! (buffer-local buf 'chat-summary)
                    "Finding where the chat title is set in code"
                    "the running summary keeps the whole sentence")
      (check-equal! (chat-title--short "one two three four five six seven")
                    "one two three four five six"
                    "a seven-word title clips to six")
      (check-equal! (chat-title--short "a short label")
                    "a short label"
                    "a label under the cap keeps every word")
      (buffer-kill! buf))))

(deftest 'the-summary-falls-back-to-the-cheap-model-when-the-card-writer-answers-nothing
  "ready but empty is the same case as not installed: the chat still gets a label"
  (lambda ()
    (let ((buf "*chat:zz-modeline-fallback*")
          (old-ready title-ready?)
          (old-card title-card)
          (old-llm llm-with-model)
          (seen-model #f))
      (test-buffer! buf "")
      (buffer-set-local! buf 'mode-name "chat-mode")
      (buffer-set-local! buf 'chat-turn-active #t)
      (buffer-set-local! buf 'agent-saved-mark 0)
      (buffer-set-local! buf 'agent-blocks '())

      ;; the on-device model claims to be ready, then hands back nothing --
      ;; a drifted-off-format answer, a crashed server, a timed-out call
      (set! title-ready? (lambda () #t))
      (set! title-card (lambda (text k) (k #f)))
      (set! llm-with-model
        (lambda (prompt model k)
          (set! seen-model model)
          (k "Falling back when the card writer answers nothing.")))

      (chat-summary-refresh! buf)

      (check-equal! seen-model chat-summary-model
                    "the fallback call names the cheap hosted model")
      (check-equal! (buffer-local buf 'chat-summary)
                    "Falling back when the card writer answers nothing."
                    "the fallback text still lands as the summary")

      (set! title-ready? old-ready)
      (set! title-card old-card)
      (set! llm-with-model old-llm)
      (buffer-kill! buf))))

(deftest 'the-summary-log-interleaves-summaries-and-jj-lines-by-time
  "every paragraph lands in chat-summary-log; the entries merge with the repo's line history in time order"
  (lambda ()
    (let ((buf "*chat:zz-modeline-log*")
          (dir "/zz-modeline-log-repo/") (root "/zz-modeline-log-repo")
          (lines *jj-lines*) (roots *jj-dir-roots*) (hist *jj-history*))
      (test-buffer! buf "")
      (buffer-set-local! buf 'mode-name "chat-mode")
      (buffer-set-local! buf 'chat-turn-active #t)   ; no archive write here
      (buffer-set-local! buf 'agent-saved-mark 0)
      (buffer-set-local! buf 'agent-blocks '())
      (buffer-set-local! buf 'default-directory dir)
      (set! *jj-dir-roots* (cons (list dir root) *jj-dir-roots*))
      (set! *jj-lines* (cons (list root "jj: second") *jj-lines*))
      (set! *jj-history* (list (list root 2000 "jj: second") (list root 1000 "jj: first")))
      (buffer-set-local! buf 'chat-summary "from before the log")
      (check-equal! (map caddr (buffer-summary-log-entries buf))
                    '("from before the log" "jj: first" "jj: second")
                    "a chat from before the log shows its one paragraph, undated")
      (chat-turn-push! buf "user" "the request")
      (chat-summary-land! buf "first paragraph")
      (chat-turn-push! buf "assistant" "the answer")
      (chat-summary-land! buf "second paragraph")
      (check-equal! (buffer-local buf 'chat-summary) "second paragraph"
                    "the bar's local is the latest")
      (check-equal! (map cadr (buffer-local buf 'chat-summary-log))
                    '("second paragraph" "first paragraph")
                    "the log keeps every paragraph, newest first")
      (check-equal! (map (lambda (turn) (plist-get turn 'role)) (chat-record buf))
                    '("status" "assistant" "status" "user")
                    "summary statuses keep their transcript position")
      (check-equal! (map (lambda (turn) (plist-get turn 'role)) (chat-model-record buf))
                    '("assistant" "user")
                    "status turns are absent from model-facing history")
      (check-equal!
        (map (lambda (turn) (plist-get turn 'role))
             (chat-drop-oldest-conversation-turns (chat-record buf) 1))
        '("status" "assistant" "status")
        "compaction drops conversation turns without consuming statuses")
      (check-equal!
        (map car (chat-parse-transcript
                   (string-append "\n"
                     (chat-turns-text (reverse (chat-record buf))))))
        '("user" "status" "assistant" "status")
        "the archive transcript preserves status ordering")
      (check-false! (string-contains? (chat-model-flatten buf) "first paragraph")
                    "ACP seed text excludes status turns too")
      (check-equal! (map caddr (buffer-local buf 'agent-blocks))
                    '("status" "status")
                    "each summary is a distinct rendered status block")
      (check-false! (string-contains? (chat-summary--tail buf) "first paragraph")
                    "the next running summary does not summarize old statuses")
      (let ((entries (buffer-summary-log-entries buf)))
        (check-equal! (map cadr entries) '(jj jj summary summary)
                      "old jj lines come first, today's summaries after")
        (check-equal! (caddr (car entries)) "jj: first" "oldest first"))
      (let ((markdown (buffer-summary-log--markdown buf)))
        (check-false! (string-contains? markdown "** summary")
                      "summary rows do not repeat the summary label")
        (check-true! (string-contains? markdown "** jj")
                     "jj rows keep their distinguishing label"))
      (check-equal! (plist-get (t--dash-wide (dashboard-line-blocks buf)) 'click)
                    "summary-log"
                    "the wide segment opens the log")
      (set! *jj-lines* lines)
      (set! *jj-dir-roots* roots)
      (set! *jj-history* hist)
      (buffer-kill! buf))))

;; The companion directory is chat identity: the chat-mode setup stamps it
;; once from the directory the chat was born in, and no later change to the
;; group or the born directory moves it.
(deftest 'a-chat-stamps-its-companion-directory-once-at-birth
  "the chat's directory is the git root of the spawner's directory, fixed at birth"
  (lambda ()
    (t--modeline-reset!)
    (make-directory! (string-append t--modeline-root "/lib"))
    (shell-command->string "git init -q" t--modeline-root)
    (let ((buf "*chat:zz-modeline-stamp*")
          (born (string-append t--modeline-root "/lib/")))
      (test-buffer! buf "")
      (buffer-set-local! buf 'default-directory born)
      (with-current-buffer buf (lambda () (set-mode! "chat-mode")))
      (check-equal! (buffer-local buf 'chat-directory)
                    (string-append (git-root born) "/")
                    "the setup stamps the git root of the born directory")
      (check-equal! (buffer-directory buf) (buffer-local buf 'chat-directory)
                    "the chat works in that directory")
      ;; the born directory moves; the companion does not
      (buffer-set-local! buf 'default-directory (string-append (compos-home) "/"))
      (with-current-buffer buf (lambda () (set-mode! "chat-mode")))
      (check-equal! (buffer-directory buf) (string-append (git-root born) "/")
                    "a second setup keeps the stamp")
      (buffer-kill! buf))
    (t--modeline-reset!)))

(deftest 'a-chat-outside-a-repo-stamps-its-born-directory
  "with no git root the born directory itself is the companion directory"
  (lambda ()
    (let ((buf "*chat:zz-modeline-stamp-plain*")
          (born (string-append (compos-home) "/zz-modeline-plain/")))
      (make-directory! born)
      (test-buffer! buf "")
      (buffer-set-local! buf 'default-directory born)
      (with-current-buffer buf (lambda () (set-mode! "chat-mode")))
      (check-equal! (buffer-local buf 'chat-directory) born
                    "the born directory is the stamp")
      (buffer-kill! buf))))

;; Commands do not rebuild dashboard presentation.
(deftest 'a-command-builds-no-dashboard-line
  "the line is built when a window is filled with the buffer and by the events that change it, never once per command"
  (lambda ()
    (let ((here "*zz-modeline-here*")
          (other "*zz-modeline-other*"))
      (test-buffer! here "")
      (test-buffer! other "")
      (switch-to-buffer! other)
      (dashboard--sync! other)
      (let ((before (buffer-local other 'dashboard-line))
            (before-here (buffer-local here 'dashboard-line)))
        (buffer-set-local! other 'minor-modes '("zz-silent-mode"))
        (with-current-buffer here (lambda () (post-command!)))
        (check-equal! (buffer-local other 'dashboard-line) before
                      "the other buffer's line did not rebuild")
        (check-equal! (buffer-local here 'dashboard-line) before-here
                      "a command built no line, not even in the buffer it ran in")
        (switch-to-buffer! here)
        (dashboard--sync! here)
        (check-true! (string? (buffer-local here 'dashboard-line))
                     "a sync builds it")
        (switch-to-buffer! other)
        (dashboard--sync! other)
        (check-true! (string-contains? (buffer-local other 'dashboard-line) "zz-silent")
                     "a sync asked for by name rebuilds it"))
      (buffer-kill! here)
      (buffer-kill! other))))

;;; --- the buffer-name grammar -------------------------------------------------
;;; A name renders: *strong* ~dim~ `mono` :icon:, and \\x for a literal x.

(deftest 'the-name-grammar-draws-emphasis-icons-and-plain-text
  "each delimiter makes one segment, and the text between them is its own"
  (lambda ()
    (check-equal! (name-segments "*Messages*")
                  '(("bn-strong" "Messages"))
                  "a special buffer is bold and shows no asterisk")
    (check-equal! (name-segments "~lib/~example.scm")
                  '(("bn-dim" "lib/") ("bn-text" "example.scm"))
                  "a dim head stands beside plain text")
    (check-equal! (name-segments "`M-x`")
                  '(("bn-code" "M-x"))
                  "backticks make one mono segment")
    (check-equal! (name-segments ":zz: notes" '(("zz" "@")))
                  '(("bn-icon" "@") ("bn-text" " notes"))
                  "the caller's icon leads the name")
    (check-equal! (name-segments "\\*not bold\\*")
                  '(("bn-text" "*not bold*"))
                  "a backslash makes the next character literal")))

(deftest 'a-delimiter-a-name-carries-by-accident-stays-text
  "only a delimiter that closes marks anything, and an unregistered icon marks nothing"
  (lambda ()
    (check-equal! (name-segments "editor_live.ex")
                  '(("bn-text" "editor_live.ex"))
                  "underscore is not a delimiter: a file name keeps its word")
    (check-equal! (name-segments "notmuch:thread:0005")
                  '(("bn-text" "notmuch:thread:0005"))
                  "an icon nobody registered leaves the name whole")
    (check-equal! (name-segments "a*b")
                  '(("bn-text" "a*b"))
                  "a delimiter with no partner is text")
    (check-equal! (name-segments "**")
                  '(("bn-text" "**"))
                  "an empty body marks nothing")
    (check-equal! (name-segments "") '() "an empty name draws nothing")))

(deftest 'an-icon-a-mode-never-declared-leaves-no-gap
  "the space beside a missing icon goes with it"
  (lambda ()
    (check-equal! (name-segments ":mode: *X*" '(("mode" "")))
                  '(("bn-strong" "X"))
                  "no glyph, no leading space")
    (check-equal! (name-segments ":mode: x " '(("mode" "@")))
                  '(("bn-icon" "@") ("bn-text" " x"))
                  "a name never ends on a space")))

(deftest 'a-name-format-fills-its-own-directives
  "the format is what a mode changes, and an unknown directive survives it"
  (lambda ()
    (check-equal! (name-format-expand "%m: %n %%"
                    '(("n" "example.scm") ("m" "scheme-mode")))
                  "scheme-mode: example.scm %"
                  "every directive the caller named is filled")
    (check-equal! (name-format-expand "%z %n" '(("n" "x")))
                  "%z x"
                  "a directive nobody named stays as it was written")
    (check-equal! (name-text (name-segments "*Messages*")) "Messages"
                  "the rendered name reads back as one plain string")))

(deftest 'a-buffer-draws-its-name-through-the-grammar
  "the mode icon leads, the buffer's own asterisks make it bold, and the sync stores the spans"
  (lambda ()
    (let ((buf "*zz-name-render*"))
      (test-buffer! buf "")
      (buffer-set-local! buf 'mode-name "scheme-mode")
      (check-equal! (buffer-name-segments buf)
                    (list (list "bn-icon" (mode-icon "scheme-mode"))
                          (list "bn-text" " ")
                          (list "bn-strong" "zz-name-render"))
                    "the default format is the mode icon and the compact name")
      ;; a mode with something else to say owns its own format
      (buffer-set-local! buf 'name-format "%m")
      (check-equal! (buffer-name-segments buf)
                    '(("bn-text" "scheme-mode"))
                    "the buffer-local format wins over buffer-name-format")
      (buffer-set-local! buf 'name-format #f)
      (switch-to-buffer! buf)
      (dashboard--sync! buf)
      (check-equal! (buffer-local buf 'modeline-name-segments)
                    (buffer-name-segments buf)
                    "the sync stores the spans beside the plain name")
      (check-equal! (name-text (buffer-local buf 'modeline-name-segments))
                    (string-append (mode-icon "scheme-mode") " zz-name-render")
                    "and the plain reading of them keeps no asterisk")
      (buffer-kill! buf))))

;;; The modes card of the C-x ? panel. The chips of one labelled row, as
;;; texts, and the value of one keyed row.
(define (t--dash-chiprow card key)
  (let loop ((kids (plist-get card 'children)))
    (cond ((null? kids) #f)
          ((and (equal? (plist-get (car kids) 'class) "dash-chiprow")
                (equal? (plist-get (car (plist-get (car kids) 'children)) 'text) key))
           (map (lambda (c) (plist-get c 'text))
                (cdr (plist-get (car kids) 'children))))
          (else (loop (cdr kids))))))

(define (t--dash-row-value card key)
  (let loop ((kids (plist-get card 'children)))
    (cond ((null? kids) #f)
          ((and (equal? (plist-get (car kids) 'class) "dash-row")
                (equal? (cadr (car (plist-get (car kids) 'segs))) key))
           (cadr (nth 2 (plist-get (car kids) 'segs))))
          (else (loop (cdr kids))))))

(deftest 'the-modes-card-names-the-maps-that-answer-and-not-only-the-shown-modes
  "cua-mode and the editing state answer in a buffer you are editing, and the modeline names neither"
  (lambda ()
    (let ((buf "*zz-modeline-modes*"))
      (test-buffer! buf "")
      (buffer-set-local! buf 'mode-name "text-mode")
      (editing-state-off! buf)
      (check-equal! (t--dash-chiprow (dash--modes buf) "hidden") #f
                    "a buffer you have just landed on hides nothing")
      (check-equal! (t--dash-row-value (dash--modes buf) "state") "focus"
                    "and it answers the arrows with the window focus")
      (editing-state-on! buf)
      (let ((hidden (t--dash-chiprow (dash--modes buf) "hidden")))
        (check-true! (if (member "editing-state" hidden) #t #f)
                     "the editing state's own map shows as a hidden mode")
        (check-true! (if (member "cua" hidden) #t #f)
                     "and so does cua-mode, which no modeline names"))
      (check-equal! (t--dash-row-value (dash--modes buf) "state") "editing"
                    "and the state says so")
      (editing-state-off! buf)
      (buffer-kill! buf))))

;; The class of the headline's state marker, which draws nothing.
(define (t--dash-state-class blocks)
  (let loop ((rest blocks))
    (cond ((null? rest) #f)
          ((let ((c (plist-get (car rest) 'class)))
             (and (string? c) (string-contains? c "dash-state-mark") c)))
          (else (loop (cdr rest))))))

(deftest 'the-headline-marks-which-state-the-buffer-is-in-without-saying-it
  "focus gives the Cmd-arrows to the window, editing gives them to the caret"
  (lambda ()
    (let ((buf "*zz-modeline-state*"))
      (test-buffer! buf "")
      (buffer-set-local! buf 'mode-name "text-mode")
      (editing-state-off! buf)
      (check-false! (t--dseg-value (dashboard-line-blocks buf) "state")
                    "the headline spends no segment on the word")
      ;; the window border wears the colour of the state, so the marker only
      ;; has to carry the name as a class for the border rule to read
      (check-equal! (t--dash-state-class (dashboard-line-blocks buf))
                    "dash-state-mark dash-state-focus"
                    "a landing answers the arrows with the window focus")
      (editing-state-on! buf)
      (check-equal! (t--dash-state-class (dashboard-line-blocks buf))
                    "dash-state-mark dash-state-editing"
                    "a buffer you are editing keeps them for the caret")
      (editing-state-off! buf)
      (buffer-kill! buf))))

(deftest 'the-state-marker-survives-a-window-too-narrow-for-the-metadata
  "a window with no room for segments still has to say whether the arrows move it"
  (lambda ()
    (let ((buf "*zz-modeline-narrow*"))
      (test-buffer! buf "")
      (with-current-buffer buf (lambda () (set-mode! "chat-mode")))
      (buffer-set-local! buf 'cols 20)
      (editing-state-off! buf)
      (check-equal! (t--dash-state-class (dashboard-line-blocks buf))
                    "dash-state-mark dash-state-focus"
                    "the marker rides outside the keep list")
      (buffer-kill! buf))))

(deftest 'a-mode-with-its-own-glyph-shows-the-glyph-instead-of-its-name
  "the key above already says MODE; the word under it was saying it twice"
  (lambda ()
    (let ((buf "*zz-modeline-glyph*"))
      (test-buffer! buf "")
      (buffer-set-local! buf 'mode-name "text-mode")
      (let ((seg (car (dash--mode-segs buf))))
        (check-equal! (car seg) "dseg-strong dseg-glyph" "the glyph names itself")
        (check-equal! (string-length (cadr seg)) 1 "and it is one glyph wide"))
      ;; a mode that registered the empty string has asked for no glyph, and a
      ;; mode that registered nothing would only get the generic default, which
      ;; says less than the name it would replace
      (buffer-set-local! buf 'mode-name "chat-perf-mode")
      (check-equal! (dash--mode-segs buf) '(("dseg-strong" "chat-perf"))
                    "an empty registration keeps the name")
      (buffer-set-local! buf 'mode-name "zz-no-such-mode")
      (check-equal! (dash--mode-segs buf) '(("dseg-strong" "zz-no-such"))
                    "and so does no registration at all")
      (buffer-kill! buf))))

;; A chat refuses the caret map, so the Cmd-arrows stay on the window
;; there however much you type. The word follows the map and not the flag.
(deftest 'a-chat-headline-says-focus-while-you-type-in-it
  "chat-mode refuses editing-caret-map, so a chat never loses the window chords"
  (lambda ()
    (let ((buf "*chat:zz-modeline-state*"))
      (test-buffer! buf "")
      (with-current-buffer buf (lambda () (set-mode! "chat-mode")))
      (editing-state-on! buf)
      (check-true! (editing-state? buf) "the chat is in the editing state")
      (check-equal! (t--dash-state-class (dashboard-line-blocks buf))
                    "dash-state-mark dash-state-focus"
                    "and its window border still says focus")
      (editing-state-off! buf)
      (buffer-kill! buf))))

(deftest 'dashboard-fields-preserve-composml-semantics
  "Dashboard metadata and summary actions declare their semantic structure."
  (lambda ()
    (let* ((field (dash--seg "mode" '(("f-dim" "Scheme")) 'left))
           (children (plist-get field 'children))
           (action (dash--wide-seg #f "Summary")))
      (check-equal! (plist-get field 'tag) "c-field" "metadata is a field")
      (check-equal! (plist-get (car children) 'tag) "c-label" "the key has a label")
      (check-equal! (plist-get (cadr children) 'tag) "c-value" "the value is explicit")
      (check-equal! (plist-get action 'tag) "c-action" "summary is an action")
      (check-equal! (plist-get action 'click) "summary-log" "the original action target survives")
      (check-true! (member '("title" "open the summary log") (plist-get action 'attrs))
              "the summary retains its hint"))))

(deftest 'hidden-dashboard-updates-wait-for-display
  "hidden updates retain presentation until a window shows the latest state"
  (lambda ()
    (let ((buf "*zz-dashboard-hidden*") (other "*zz-dashboard-visible*"))
      (test-buffer! buf "")
      (test-buffer! other "")
      (switch-to-buffer! buf)
      (window-configuration-changed!)
      (dashboard--sync! buf)
      (switch-to-buffer! other)
      (let ((before (buffer-local buf 'dashboard-line-blocks)))
        (buffer-set-local! buf 'minor-modes '("zz-first-mode"))
        (dashboard--sync! buf)
        (buffer-set-local! buf 'minor-modes '("zz-latest-mode"))
        (dashboard--sync! buf)
        (check-equal! (buffer-local buf 'dashboard-line-blocks) before
                      "hidden sync does not materialize blocks")
        (check-equal! (buffer-local buf 'dashboard-dirty) #t "updates remain pending")
        (check-true! (member 'dashboard-dirty (buffer-local buf 'desktop-skip-locals))
                     "the pending flag is transient")
        (switch-to-buffer! buf)
      (window-configuration-changed!)
        (check-equal! (buffer-local buf 'dashboard-dirty) #f "showing consumes pending work")
        (check-contains! (buffer-local buf 'dashboard-line) "zz-latest"
                         "showing renders the latest state")
        (buffer-set-local! buf 'minor-modes '("zz-visible-mode"))
        (dashboard--sync! buf)
        (check-contains! (buffer-local buf 'dashboard-line) "zz-visible"
                         "visible events update immediately"))
      (buffer-kill! buf)
      (buffer-kill! other))))

(deftest 'hidden-dashboard-without-presentation-catches-up
  "restore can request presentation before any window shows the buffer"
  (lambda ()
    (let ((buf "*zz-dashboard-unseen*"))
      (test-buffer! buf "")
      (dashboard--sync! buf)
      (check-equal! (buffer-local buf 'dashboard-line-blocks) #f
                    "hidden restore builds no blocks")
      (switch-to-buffer! buf)
      (window-configuration-changed!)
      (check-true! (pair? (buffer-local buf 'dashboard-line-blocks))
                   "the first display supplies presentation")
      (buffer-kill! buf))))

;;; --- the two bars (docs/DESIGN-PORT.md, stage 2) ----------------------------
;;; The header line is identity: pin, title, the open change, the state tag
;;; and one switcher. The mode line is state: mode, llm, lane, ranked.

(deftest 'the-header-line-carries-identity-and-the-mode-line-carries-state
  "mode, llm and lane are mode-line facts; the header line keeps the title, the tag and one switcher"
  (lambda ()
    (let ((buf "*chat:zz-modeline-identity*"))
      (test-buffer! buf "")
      (buffer-set-local! buf 'mode-name "chat-mode")
      (let* ((blocks (dashboard-line-blocks buf))
             (last (car (reverse blocks)))
             (tag (cadr (reverse blocks))))
        (check-false! (t--dseg-value blocks "mode") "the header line names no mode")
        (check-false! (t--dseg-value blocks "llm") "and no model")
        (check-equal! (plist-get last 'click) "buffer-switcher"
                      "one switcher closes the header line")
        (check-equal! (plist-get tag 'text) "focus"
                      "the state tag says the design's word"))
      (let ((facts (dash--modeline-facts buf #f)))
        (check-equal! (map car facts) '("mode" "llm" "lane")
                      "the mode line carries the state")
        (check-equal! (list-ref (caddr facts) 3) 2 "the lane sheds first"))
      (check-equal! (map car (dash--modeline-facts buf (list "review")))
                    '("mode" "preset")
                    "a preset names the whole setup and stands alone")
      (buffer-kill! buf))))

(deftest 'tool-presets-show-on-the-mode-line-as-icons
  "each preset is one glyph; compos is drawn as the logo by its class"
  (lambda ()
    (let ((buf "*chat:zz-modeline-presets*"))
      (test-buffer! buf "")
      (buffer-set-local! buf 'mode-name "chat-mode")
      (check-false! (assoc "tools" (dash--modeline-facts buf #f)) "no presets, no fact")
      (preset-icon! 'zz-web "W")
      (buffer-set-local! buf 'chat-presets '(zz-web compos zz-other))
      (let ((f (assoc "tools" (dash--modeline-facts buf #f))))
        (check-equal! (cadr f) "W Z" "a registered glyph, else the first letter")
        (check-equal! (caddr f) "preset-compos" "compos wears the logo"))
      (buffer-kill! buf))))

(deftest 'the-api-lane-adds-a-usage-fact-once-a-turn-has-billed
  "tokens, cost and cache hit rate join the mode line, ranked to shed first"
  (lambda ()
    (let ((buf "*chat:zz-modeline-usage*"))
      (test-buffer! buf "")
      (buffer-set-local! buf 'mode-name "chat-mode")
      (check-false! (dash--usage buf) "nothing billed yet")
      (chat-usage-note! buf '(input 100 output 20 cache-read 900 cache-write 50 cost 0.01))
      (chat-usage-note! buf '(input 10 output 5 cache-read 1000 cache-write 0 cost 0.02))
      (let* ((facts (dash--modeline-facts buf #f))
             (usage (assoc "usage" facts)))
        (check-equal! (map car facts) '("mode" "llm" "lane" "usage")
                      "usage sheds before mode, llm and lane")
        (check-equal! (list-ref usage 3) 3 "usage sheds first")
        (check-equal! (cadr usage) "135 tok · $0.0300 · 94% hit"
                      "tokens, cost and cache hit rate, in one value"))
      (buffer-kill! buf))))

(deftest 'the-acp-lane-reports-no-usage-fact
  "an ACP connector counts tokens on a subscription and prices nothing here"
  (lambda ()
    (let ((buf "*chat:zz-modeline-usage-acp*"))
      (test-buffer! buf "")
      (buffer-set-local! buf 'mode-name "chat-mode")
      (buffer-set-local! buf 'agent-connector "claude-code")
      (chat-usage-note! buf '(input 100 output 20 cache-read 900 cache-write 50))
      (check-false! (dash--usage buf) "the acp lane shows no usage fact")
      (check-equal! (map car (dash--modeline-facts buf #f)) '("mode" "llm" "lane")
                    "the mode line stays the same three facts")
      (buffer-kill! buf))))

(deftest 'a-preset-still-carries-its-usage-fact
  "a tool preset names the setup, and the usage fact joins it, not replaces it"
  (lambda ()
    (let ((buf "*chat:zz-modeline-usage-preset*"))
      (test-buffer! buf "")
      (buffer-set-local! buf 'mode-name "chat-mode")
      (chat-usage-note! buf '(input 100 output 20 cache-read 900 cache-write 50))
      (check-equal! (map car (dash--modeline-facts buf (list "review")))
                    '("mode" "preset" "usage")
                    "the preset still stands alone; usage still ships")
      (buffer-kill! buf))))

(deftest 'usage-never-borrows-a-groups-other-buffers-spend
  "unlike the cost card, the usage fact answers only for a chat buffer itself"
  (lambda ()
    (let ((chat "*chat:zz-modeline-usage-owner*")
          (sibling "*zz-modeline-usage-sibling*"))
      (test-buffer! chat "")
      (buffer-set-local! chat 'mode-name "chat-mode")
      (chat-usage-note! chat '(input 100 output 20 cache-read 900 cache-write 50))
      (test-buffer! sibling "")
      (check-false! (dash--usage sibling)
                    "a non-chat buffer names no usage, even beside a spending chat")
      (buffer-kill! chat)
      (buffer-kill! sibling))))

(deftest 'an-editing-buffer-wears-the-cua-tag
  "the design's word for a buffer that stays put"
  (lambda ()
    (let ((buf "*zz-modeline-cua*"))
      (test-buffer! buf "")
      (buffer-set-local! buf 'mode-name "text-mode")
      (editing-state-on! buf)
      (check-equal! (plist-get (dash--state-mark buf) 'text) "cua" "editing is cua")
      (editing-state-off! buf)
      (check-equal! (plist-get (dash--state-mark buf) 'text) "focus" "a landing is focus")
      (buffer-kill! buf))))

(deftest 'the-switcher-offers-what-the-buffer-can-say-about-itself
  "every buffer has info; a chat adds its log; an agent transcript adds how much to show"
  (lambda ()
    (let ((buf "*zz-modeline-switcher*"))
      (test-buffer! buf "")
      (buffer-set-local! buf 'mode-name "text-mode")
      (check-equal! (map car (buffer-switcher-rows buf)) '("buffer info")
                    "a plain buffer offers its info")
      (buffer-kill! buf))
    (let ((buf "*chat:zz-modeline-switcher*"))
      (test-buffer! buf "")
      (buffer-set-local! buf 'mode-name "chat-mode")
      (buffer-set-local! buf 'render-mode "blocks")
      (buffer-set-local! buf 'agent-saved-mark 0)
      (check-equal! (map car (buffer-switcher-rows buf))
                    '("buffer info" "summary log"
                      "transcript: info" "transcript: log" "transcript: debug")
                    "a chat transcript offers its log and its verbosity")
      (buffer-kill! buf))))
