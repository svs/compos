;;; mode-lifecycle-test.scm --- every mode rebuilds its view from its locals.
;;;
;;; define-mode says it: SETUP must rebuild from locals. A desktop restore
;;; and a reload both run the setup fn again on a buffer whose text,
;;; overlays and folds may be gone while its locals survived. One sweep
;;; walks every registered mode and holds each to the same contract:
;;; enter; a second entry changes nothing; a wipe and a re-setup draw the
;;; same view; leaving takes the keys and the mode's own state with it.
;;; A seed table puts real locals under the modes whose view is worth
;;; more than an empty buffer. A mode without a seed is still swept, so
;;; a new mode is covered without a new test.

(domain! 'testing)
(effects! '(write))

;;; --- the view a mode draws ------------------------------------------------

(define (ml--overlays buf) (sort (map value->string (buffer-overlays buf))))

;; what the eye and the keys see: the text, the paint, the folds, the
;; minor modes worn, and the maps that answer. The maps compare as sets:
;; their precedence is keymap-test's business.
(define (ml--view buf)
  (list (buffer-text buf)
        (ml--overlays buf)
        (buffer-hidden buf)
        (sort (or (buffer-local buf 'minor-modes) '()))
        (sort (buffer-minor-maps buf))
        (sort (buffer-keymaps buf))))

;; the locals set-mode! resets on a change of major mode
(define ml--render-locals
  '(render-root render-text-root render-records header-line-blocks footer-line-blocks))

(define (ml--subset? small big)
  (let loop ((xs small))
    (cond ((null? xs) #t)
          ((member (car xs) big) (loop (cdr xs)))
          (else #f))))

;; a walk must leave the frame as it found it: the windows, the group,
;; and the buffer in the active window; else the files after this one
;; start from a frame some mode arranged
(define (ml--frame-kept thunk)
  (let ((tree (window-tree)) (group (frame-group)) (here (current-buffer))
        (target (layout-target)))
    (let ((r (thunk)))
      (cond ((and group (not (equal? (frame-group) group))) (frame-tab! group))
            ((and (not group) (frame-group) (buffer-known? "*scratch*"))
             (switch-to-buffer! "*scratch*")))
      ;; a mode that chose a target layout would arrange every later frame
      (unless (equal? (layout-target) target) (layout-target-set! target))
      (ignore-errors (lambda () (window-tree-set! tree)))
      (when (and (buffer-known? here) (not (equal? (current-buffer) here)))
        (switch-to-buffer! here))
      r)))

;;; --- every major mode -----------------------------------------------------

;; modes whose setup needs a file, a process, a connection, a mailbox,
;; or the locals the command that opens them writes first (the first
;; eleven are keys-sweep-test's list); perf-mode draws a live sample of
;; the VM, so no two draws agree
(define ml--skip-modes
  '("Dired" "dired-mode" "pdf-reader-mode" "pdf-edit-mode" "browser-file-mode"
    "chat-mode" "spreadsheet-mode" "term-mode" "comint-shell-mode"
    "occur-ts-mode" "telemetry-detail-mode"
    "notmuch-mode" "notmuch-hello-mode" "perf-mode"))

;; a list that fetches its rows from a host on entry: the host answers
;; later and the list redraws, so the view is the host's, not the locals'
(define (ml--fetches? mode)
  (let ((opts (ignore-errors (lambda () (list-mode-opts mode)))))
    (and (pair? opts) (plist-get opts 'cache-fetch) #t)))

(define (ml--swept? mode)
  (not (or (member mode ml--skip-modes) (string-prefix? "zz-" mode) (ml--fetches? mode))))

;; ML_SKIP=major,minor,seeds,MODE,... leaves parts of the sweep out, to
;; attribute a failure in a later file to one walk or one seed
(define ml--skip-set (string-split (or (getenv "ML_SKIP") "") ","))
(define (ml--skipped? part) (and (member part ml--skip-set) #t))

(define (ml--major-faults mode)
  (let* ((buf (test-buffer! (string-append "zz-ml-" mode) "line one\nline two\n"))
         (bad '())
         (fault! (lambda (what) (set! bad (cons (list mode what) bad))))
         (enter! (lambda (name) (with-current-buffer buf (lambda () (set-mode! name))))))
    (if (not (ignore-errors (lambda () (enter! mode) #t)))
        (fault! "setup raised")
        (let ((once (ml--view buf)))
          (unless (equal? (buffer-local buf 'mode-name) mode)
            (fault! "the buffer does not wear the mode"))
          ;; re-enter: the door a restore uses, and it changes nothing
          (enter! mode)
          (unless (equal? (ml--view buf) once)
            (fault! "a second entry changed the view"))
          ;; re-setup after a wipe: the paint and the folds go, the locals stay
          (overlay-clear! buf 'all)
          (fold-clear! buf 'all)
          (enter! mode)
          (unless (equal? (ml--view buf) once)
            (fault! "a re-setup after a wipe did not draw the same view"))
          ;; leave: the keys and the view locals go with the mode
          (enter! "text-mode")
          (unless (or (derived-mode? "text-mode" mode)
                      (not (member (mode-keymap mode) (buffer-keymaps buf))))
            (fault! "its map still answers after leaving"))
          (for-each (lambda (k)
                      (when (buffer-local buf k)
                        (fault! (string-append (symbol->string k) " survived leaving"))))
                    ml--render-locals)))
    (buffer-kill! buf)
    (reverse bad)))

(deftest 'every-major-mode-enters-re-enters-rebuilds-and-leaves-cleanly
  "enter each mode in a fresh buffer: a second entry changes nothing, a wipe and a re-setup draw the same view, and leaving takes the keys and the view locals"
  (lambda ()
    (let ((bad '()) (entered 0))
      (for-each
        (lambda (mode)
          (when (and (not (ml--skipped? "major")) (ml--swept? mode))
            (set! entered (+ entered 1))
            ;; one task per mode: every frame an eval makes lives until
            ;; the eval ends, and a hundred setups in one eval pass the
            ;; heap bound
            (set! bad (append bad
                              (or (ignore-errors
                                    (lambda () (ml--frame-kept (lambda () (task-await (task-spawn (lambda () (ml--major-faults mode))))))))
                                  (list (list mode "the walk raised")))))))
        (mode-names 'major))
      (check-true! (> entered 20) "the sweep entered the modes")
      (check-equal! bad '() "every major mode keeps the lifecycle contract"))))

;;; --- every minor mode -----------------------------------------------------

(define (ml--minor-faults mode)
  (let* ((buf (test-buffer! (string-append "zz-ml-minor-" mode) "some text\n"))
         (bad '())
         (fault! (lambda (what) (set! bad (cons (list mode what) bad))))
         (worn (lambda () (length (filter (lambda (m) (equal? m mode))
                                          (or (buffer-local buf 'minor-modes) '()))))))
    (let ((before (ml--overlays buf)))
      (cond
        ((not (ignore-errors (lambda () (enable-minor-mode! buf mode) #t)))
         (fault! "setup raised"))
        ;; a mode may decline a buffer it cannot serve, as preview-mode
        ;; declines text with no renderer: it takes itself off again, and
        ;; the seeds below cover it on a buffer it accepts
        ((equal? (worn) 0) #t)
        (else
         (let ((once (ml--view buf)))
           (unless (equal? (worn) 1) (fault! "worn more than once after enable"))
           ;; enable again: worn once, drawn once
           (enable-minor-mode! buf mode)
           (unless (equal? (ml--view buf) once)
             (fault! "a second enable changed the view"))
           ;; the restore path: the setup runs again over the wiped paint
           (overlay-clear! buf 'all)
           (restore-minor-modes! buf)
           (unless (equal? (ml--view buf) once)
             (fault! "a restore after a wipe did not draw the same view"))
           ;; teardown: the mode, its map and its paint go
           (if (not (ignore-errors (lambda () (disable-minor-mode! buf mode) #t)))
               (fault! "teardown raised")
               (begin
                 (unless (equal? (worn) 0) (fault! "still worn after disable"))
                 (let ((map (minor-mode-keymap mode)))
                   (when (and map (member map (buffer-minor-maps buf)))
                     (fault! "its map still answers after disable")))
                 (unless (ml--subset? (ml--overlays buf) before)
                   (fault! "its paint stayed after disable"))))))))
    (buffer-kill! buf)
    (reverse bad)))

(deftest 'every-minor-mode-enables-once-restores-and-disables-cleanly
  "turn each minor mode on in a text buffer: a second enable changes nothing, a restore after a wipe draws the same view, and disable takes the mode, its map and its paint"
  (lambda ()
    (let ((bad '()))
      (for-each
        (lambda (mode)
          (unless (or (ml--skipped? "minor") (string-prefix? "zz-" mode))
            (set! bad (append bad (ml--frame-kept (lambda () (ml--minor-faults mode)))))))
        (mode-names 'minor))
      (check-equal! bad '() "every minor mode keeps the lifecycle contract"))))

;;; --- the seeded modes -----------------------------------------------------
;;;
;;; A seed is a thunk that puts real locals under a mode and answers a
;;; plist: 'buf, 'probe (the facts the view shows, a list with no #f in
;;; it), 'wipe (what a restart loses), 'again (the re-setup door that
;;; mode uses), an optional 'after (more (LABEL OK?) facts once the view
;;; is back), and 'done (undo everything).

(define (ml--seed-faults name seed)
  (let* ((bad '())
         (fault! (lambda (what) (set! bad (cons (list name what) bad))))
         (s (ignore-errors seed)))
    (if (not s)
        (fault! "the seed raised")
        (let ((probe (plist-get s 'probe)) (wipe (plist-get s 'wipe))
              (again (plist-get s 'again)) (after (plist-get s 'after))
              (done (plist-get s 'done)))
          (unless (ignore-errors
                    (lambda ()
                      (let ((v1 (probe)))
                        (unless (and (pair? v1) (not (member #f v1)))
                          (fault! (string-append "the seed drew nothing: " (value->string v1))))
                        (wipe)
                        (again)
                        (let ((v2 (probe)))
                          (unless (equal? v2 v1)
                            (fault! (string-append "the re-setup drew " (value->string v2)
                                                   " where the seed drew " (value->string v1)))))
                        (when after
                          (for-each (lambda (f) (unless (cadr f) (fault! (car f)))) (after))))
                      #t))
            (fault! "a step raised"))
          (ignore-errors done)))
    (reverse bad)))

;; occur-ts: a list rebuilds its rows from its source locals, never from
;; its text, and is read only again
(define ml--occur-src "*zz-ml-occur-src*")

(define (ml--seed-occur-ts)
  (test-buffer! ml--occur-src "{\n  \"one\": 1,\n  \"two\": 2\n}\n")
  (buffer-set-local! ml--occur-src 'ts-lang "json")
  (switch-to-buffer! ml--occur-src)
  (occur-ts-open ml--occur-src "json" "(pair key: (string) @key)")
  (let ((buf "*occur-ts*"))
    (list 'buf buf
          'probe (lambda ()
                   (let ((text (buffer-text buf)))
                     (list (string-contains? text "\"one\": 1")
                           (string-contains? text "\"two\": 2")
                           (buffer-read-only? buf))))
          'wipe (lambda () (buffer-set-text! buf "stale" #f))
          'again (lambda () (with-current-buffer buf (lambda () (set-mode! "occur-ts-mode"))))
          'done (lambda ()
                  (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
                            (list buf ml--occur-src))))))

;; notmuch: the search list rebuilds its rows from the query local, and
;; the verbs still answer
(define ml--nm-threads
  (list (list 'thread "0001" 'subject "Hello world" 'authors "Alice"
              'tags '("inbox" "unread") 'date_relative "Today 06:50")))

(define (ml--seed-notmuch)
  (let ((saved-json nm--json) (saved-count nm--count-for)
        (saved-host notmuch-host) (saved-profile notmuch-profile)
        (saved-preview notmuch-auto-preview))
    (set! nm--json (lambda (args) (if (string-prefix? "search" args) ml--nm-threads #f)))
    (set! nm--count-for (lambda (buf query) "1"))
    ;; an unset mailbox raises; the stub above is this machine's store
    (set! notmuch-host "")
    (set! notmuch-profile "")
    (set! notmuch-auto-preview #f)
    (switch-to-buffer! "*scratch*")
    (delete-other-windows!)
    (run-command "notmuch-inbox")
    (let ((buf "*notmuch*"))
      (list 'buf buf
            'probe (lambda ()
                     (list (string-contains? (buffer-text buf) "Hello world")
                           (with-current-buffer buf (lambda () (key-binding "RET")))))
            'wipe (lambda () (buffer-set-text! buf "stale" #t))
            'again (lambda () (with-current-buffer buf (lambda () (set-mode! "notmuch-mode"))))
            'done (lambda ()
                    (set! nm--json saved-json)
                    (set! nm--count-for saved-count)
                    (set! notmuch-host saved-host)
                    (set! notmuch-profile saved-profile)
                    (set! notmuch-auto-preview saved-preview)
                    (for-each (lambda (b)
                                (when (or (equal? b "*notmuch*") (equal? b "*mailboxes*")
                                          (string-prefix? "*mail" b))
                                  (buffer-kill! b)))
                              (buffer-list)))))))

;; irc: the transcript's paint comes back from the 'irc-paint local
(define (ml--seed-irc)
  (irc-conn-set! "zz-ml" (list 'endpoint (irc-endpoint "zz-ml") 'host "h" 'port "6667"
                                'nick "composguest" 'status "ready" 'registered #t))
  (let ((buf (irc-buffer! "zz-ml" "#x")))
    (irc-display buf (irc-said "oskarw" "one"))
    (let ((paint (ml--overlays buf)))
      (list 'buf buf
            'probe (lambda () (list (pair? paint) (equal? (ml--overlays buf) paint)))
            'wipe (lambda () (overlay-clear! buf 'all))
            'again (lambda () (with-current-buffer buf (lambda () (set-mode! "irc-mode"))))
            'done (lambda ()
                    (for-each buffer-kill! (irc-buffers "zz-ml"))
                    (set! *irc-conns* (remove (lambda (e) (equal? (car e) "zz-ml")) *irc-conns*)))))))

;; morg: a restart drops the hidden ranges and keeps the 'morg-folds local
(define ml--morg-buf "zz-ml-morg.md")

(define (ml--seed-morg)
  (test-buffer! ml--morg-buf "# a\nbody\n## child\ncbody\n# b\ntail\n")
  (with-current-buffer ml--morg-buf (lambda () (set-mode! "morg-mode")))
  (when (minor-mode-on? ml--morg-buf "preview-mode")
    (disable-minor-mode! ml--morg-buf "preview-mode"))
  (buffer-goto! ml--morg-buf 0)
  (with-current-buffer ml--morg-buf (lambda () (run-command "morg-cycle")))
  (list 'buf ml--morg-buf
        'probe (lambda ()
                 (let ((hidden (buffer-hidden ml--morg-buf)))
                   (list (pair? hidden) hidden)))
        'wipe (lambda () (fold-set! ml--morg-buf 'morg '()))
        'again (lambda () (with-current-buffer ml--morg-buf (lambda () (set-mode! "morg-mode"))))
        'done (lambda () (buffer-kill! ml--morg-buf))))

;; doom-lite: a game in progress survives the setup, which must not start
;; a new one
(define ml--doom-buf "*zz-ml-doom*")

(define (ml--seed-doom-lite)
  (test-buffer! ml--doom-buf "")
  (delete-other-windows!)
  (switch-to-buffer! ml--doom-buf)
  (set-mode! "doom-lite-mode")
  (buffer-set-locals! ml--doom-buf
    (list 'doom-lite-px (doom-lite--cell->fp 10) 'doom-lite-py (doom-lite--cell->fp 6)
          'doom-lite-health 42 'doom-lite-ammo 7 'doom-lite-kills 3))
  (list 'buf ml--doom-buf
        'probe (lambda () (list (buffer-local ml--doom-buf 'doom-lite-health)
                                (buffer-local ml--doom-buf 'doom-lite-ammo)))
        'wipe (lambda () (buffer-set-text! ml--doom-buf "" #t))
        'again (lambda () (with-current-buffer ml--doom-buf (lambda () (set-mode! "doom-lite-mode"))))
        'after (lambda ()
                 (list (list "the drawn text shows the health it held"
                             (string-contains? (buffer-text ml--doom-buf) "health 42"))))
        'done (lambda () (buffer-kill! ml--doom-buf))))

;; browse: a wake redraws the saved page without a fetch; past the TTL
;; it fetches again
(define (ml--seed-browse)
  (let ((saved-fetch *web-fetch*)
        (saved-visited (or (read-file *web-visited-file*) ""))
        (here (current-buffer))
        (fetches 0))
    (set! *web-fetch*
      (lambda (url want k)
        (set! fetches (+ fetches 1))
        (k (list want "hello [x](https://a.test/)\n" #f))))
    (let ((buf (browse "https://site.test/")))
      (list 'buf buf
            'probe (lambda () (list fetches (string-contains? (buffer-text buf) "hello")))
            'wipe (lambda () #t)
            'again (lambda () (with-current-buffer buf (lambda () (set-mode! "browse-mode"))))
            'after (lambda ()
                     (buffer-set-local! buf 'cache-time (- (current-time) 999999))
                     (with-current-buffer buf (lambda () (set-mode! "browse-mode")))
                     (list (list "a stale page fetches again" (equal? fetches 2))))
            'done (lambda ()
                    (set! *web-fetch* saved-fetch)
                    (write-file! *web-visited-file* saved-visited)
                    (when (buffer-known? buf) (buffer-kill! buf))
                    (when (buffer-known? here) (switch-to-buffer! here)))))))

;; setup wizard: the step is a local, and the setup draws from it. The
;; buffer is made by hand: setup-wizard! would also choose the columns
;; layout for every frame after this one.
(define (ml--seed-setup-wizard)
  (let ((buf *setup-wizard-buffer*))
    (unless (buffer-exists? buf) (buffer-create buf) (buffer-append! buf "Setup\n"))
    (buffer-set-local! buf 'setup-wizard-step "model")
    (with-current-buffer buf (lambda () (set-mode! "setup-wizard-mode")))
    (setup-wizard-click buf "wizard:next")
    (list 'buf buf
          'probe (lambda ()
                   (list (setup-wizard-step buf)
                         (string-contains? (value->string (buffer-local buf 'render-blocks))
                                           "Start learning")))
          'wipe (lambda () (buffer-set-local! buf 'render-blocks #f))
          'again (lambda () (with-current-buffer buf (lambda () (set-mode! "setup-wizard-mode"))))
          'after (lambda ()
                   (setup-wizard-click buf "wizard:back")
                   (list (list "back still moves the step" (equal? (setup-wizard-step buf) "model"))))
          'done (lambda () (buffer-kill! buf)))))

;; preview: a restore rebuilds an enabled preview and leaves a disabled
;; one off
(define (ml--seed-preview)
  (let ((buf (test-buffer! "zz-ml-preview.html" "<p>hi</p>\n")))
    (with-current-buffer buf (lambda () (run-command "preview-mode")))
    (list 'buf buf
          'probe (lambda () (list (buffer-local buf 'render-mode)))
          'wipe (lambda () (buffer-set-local! buf 'render-mode #f))
          'again (lambda () (restore-minor-modes! buf))
          'after (lambda ()
                   (with-current-buffer buf (lambda () (run-command "preview-mode")))
                   (restore-minor-modes! buf)
                   (list (list "a disabled preview stays off through a restore"
                               (not (buffer-local buf 'render-mode)))))
          'done (lambda () (buffer-kill! buf)))))

;; writing: a restore runs the setup again, adds no second hook, and
;; keeps a preview the user turned off
(define (ml--writing-hooks buf)
  (length (filter (lambda (h) (equal? (car h) buf)) *writing-hooks*)))

(define (ml--seed-writing)
  (let ((buf (test-buffer! "zz-ml-writing.md" "some prose\n")))
    (delete-other-windows!)
    (switch-to-buffer! buf)
    (enable-minor-mode! buf "writing-mode")
    (list 'buf buf
          'probe (lambda ()
                   (list (equal? (ml--writing-hooks buf) 1)
                         (buffer-local buf 'window-class)
                         (buffer-local buf 'modeline-info)))
          'wipe (lambda ()
                  (buffer-set-local! buf 'window-class #f)
                  (buffer-set-local! buf 'modeline-info #f))
          'again (lambda () (restore-minor-modes! buf))
          'after (lambda ()
                   (let ((look (list (list "the look is back"
                                           (equal? (buffer-local buf 'window-class) "writing"))
                                     (list "and the count"
                                           (string-contains? (or (buffer-local buf 'modeline-info) "")
                                                             "2 words")))))
                     ;; the user turns the preview off; a restore keeps it off
                     (with-current-buffer buf (lambda () (run-command "preview-mode")))
                     (restore-minor-modes! buf)
                     (append look
                             (list (list "a disabled preview stays off through a restore"
                                         (not (buffer-local buf 'render-mode)))))))
          'done (lambda ()
                  (when (minor-mode-on? buf "writing-mode") (disable-minor-mode! buf "writing-mode"))
                  (buffer-kill! buf)))))

;; code-mode: a restore rebuilds the workspace from the surviving locals,
;; with llm-mode beside it and nothing else
(define ml--code-buf "zz-ml-code-mode.ex")

(define (ml--seed-code-mode)
  (when (buffer-known? ml--code-buf) (buffer-kill! ml--code-buf))
  (test-buffer! ml--code-buf "code\n")
  (switch-to-buffer! ml--code-buf)
  (run-command "code-mode")
  (buffer-set-local! ml--code-buf 'chat-presets '(compos project))
  (list 'buf ml--code-buf
        'probe (lambda ()
                 (list (sort (or (buffer-local ml--code-buf 'minor-modes) '()))
                       (and (buffer-group ml--code-buf) #t)
                       (buffer-local ml--code-buf 'modeline-info)))
        'wipe (lambda () (buffer-set-local! ml--code-buf 'modeline-info #f))
        'again (lambda () (restore-minor-modes! ml--code-buf))
        'after (lambda ()
                 (let ((modes (or (buffer-local ml--code-buf 'minor-modes) '()))
                       (info (or (buffer-local ml--code-buf 'modeline-info) "")))
                   (list (list "code-mode and llm-mode are back, and nothing else"
                               (and (member "code-mode" modes) (member "llm-mode" modes)
                                    (equal? (length modes) 2) #t))
                         (list "and the modeline"
                               (and (string-prefix? "code" info) (string-contains? info "compos"))))))
        'done (lambda ()
                (for-each
                  (lambda (b)
                    (when (minor-mode-on? b "code-mode") (disable-minor-mode! b "code-mode"))
                    (when (minor-mode-on? b "browser-mode") (disable-minor-mode! b "browser-mode"))
                    (when (string-prefix? "*scratch:" b) (buffer-kill! b)))
                  (buffer-list))
                (customize-set! 'code-presets '(compos))
                (customize-set! 'code-model "")
                (when (buffer-known? ml--code-buf)
                  (let ((id (buffer-group ml--code-buf)))
                    (when (and id (group-record-by-id id)) (group-record-delete! id)))
                  (buffer-kill! ml--code-buf)))))

(define ml--seeds
  (list (list "occur-ts-mode" ml--seed-occur-ts)
        (list "notmuch-mode" ml--seed-notmuch)
        (list "irc-mode" ml--seed-irc)
        (list "morg-mode" ml--seed-morg)
        (list "doom-lite-mode" ml--seed-doom-lite)
        (list "browse-mode" ml--seed-browse)
        (list "setup-wizard-mode" ml--seed-setup-wizard)
        (list "preview-mode" ml--seed-preview)
        (list "writing-mode" ml--seed-writing)
        (list "code-mode" ml--seed-code-mode)))

(deftest 'every-seeded-mode-rebuilds-its-view-from-the-locals
  "with real locals under it, a wipe and a re-setup draw the same view, and the verbs still answer"
  (lambda ()
    (let ((bad '()))
      (for-each
        (lambda (e)
          (unless (or (ml--skipped? "seeds") (ml--skipped? (car e)))
            (set! bad (append bad (ml--frame-kept (lambda () (ml--seed-faults (car e) (cadr e))))))))
        ml--seeds)
      (check-equal! bad '() "every seeded mode rebuilds from its locals"))))

;;; --- a reload is a re-setup -----------------------------------------------
;;;
;;; Session.reload_files/1 brackets every reload with reload-begin! and
;;; reload-finish!. Between them, the policy: the buffers wearing a mode
;;; the reload redefined are set up again, the visible ones too, and no
;;; other. The ExUnit side covers the watcher and the form diff.

(define ml--hr-a "zz-ml-reload-a")
(define ml--hr-b "zz-ml-reload-b")

;; a mode whose setup fn stamps the buffer: a new stamp in an open buffer
;; means the setup fn ran again
(define (ml--major! mode stamp)
  (define-mode mode
    (lambda () (buffer-set-local! (current-buffer) 'zz-ml-stamp stamp))))

(define (ml--minor! mode stamp)
  (register-minor-mode! mode
    (lambda (b) (buffer-set-local! b 'zz-ml-minor-stamp stamp))))

;; a reload also rebuilds every visible buffer, and the test frame has
;; windows of its own: take that half out to count the mode half alone
(define (ml--modes-only thunk)
  (let ((was *reload-refresh-visible*))
    (set! *reload-refresh-visible* #f)
    (let ((r (thunk)))
      (set! *reload-refresh-visible* was)
      r)))

(deftest 'a-reload-re-runs-the-setup-where-the-mode-it-named-is-worn
  "a major or minor mode redefined inside the bracket rebuilds its wearers alone; a definition outside it, or no mode at all, rebuilds nothing"
  (lambda ()
    (ml--major! "zz-ml-hr-mode" 1)
    (ml--major! "zz-ml-hr-other" 1)
    (ml--minor! "zz-ml-hr-minor" 1)
    (test-buffer! ml--hr-a "alpha\n")
    (test-buffer! ml--hr-b "beta\n")
    (with-current-buffer ml--hr-a (lambda () (set-mode! "zz-ml-hr-mode")))
    (with-current-buffer ml--hr-b (lambda () (set-mode! "zz-ml-hr-other")))
    (enable-minor-mode! ml--hr-b "zz-ml-hr-minor")
    (check-equal! (buffer-local ml--hr-a 'zz-ml-stamp) 1 "the mode set the buffer up once")
    (check-equal! (buffer-local ml--hr-b 'zz-ml-minor-stamp) 1 "the minor setup ran once")

    ;; the definitions above came before the bracket: not a reload
    (reload-begin!)
    (check-equal! (ml--modes-only reload-finish!) 0 "no mode named, no buffer touched")

    ;; one reload, redefining one of the two major modes
    (reload-begin!)
    (ml--major! "zz-ml-hr-mode" 2)
    (check-equal! (ml--modes-only reload-finish!) 1 "one buffer wore the mode the reload named")
    (check-equal! (buffer-local ml--hr-a 'zz-ml-stamp) 2 "it took the new setup")
    (check-equal! (buffer-local ml--hr-b 'zz-ml-stamp) 1 "the other mode was left alone")

    ;; a minor mode is worn in a buffer-local list, and counts the same way
    (reload-begin!)
    (ml--minor! "zz-ml-hr-minor" 2)
    (check-equal! (ml--modes-only reload-finish!) 1 "the buffer wearing the minor mode was rebuilt")
    (check-equal! (buffer-local ml--hr-b 'zz-ml-minor-stamp) 2 "with the new setup")

    (disable-minor-mode! ml--hr-b "zz-ml-hr-minor")
    (buffer-kill! ml--hr-a)
    (buffer-kill! ml--hr-b)))

(deftest 'a-reload-rebuilds-the-buffers-you-can-see-unless-the-refresh-is-off
  "a setup fn calls helpers the same save can change without touching define-mode; a session whose setup is expensive opts out"
  (lambda ()
   (ml--frame-kept (lambda ()
    (ml--major! "zz-ml-hr-visible" 1)
    (test-buffer! ml--hr-a "alpha\n")
    (with-current-buffer ml--hr-a (lambda () (set-mode! "zz-ml-hr-visible")))
    ;; the visible half rebuilds every window's buffer, hidden ones too:
    ;; show this one alone, and give the frame back after
    (delete-other-windows!)
    (window-hidden-clear!)
    (switch-to-buffer! ml--hr-a)
    (check-equal! (buffer-local ml--hr-a 'zz-ml-stamp) 1 "the mode set the buffer up once")

    ;; the reload redefines no mode at all: only a helper changed
    (ml--major! "zz-ml-hr-visible" 2)
    (reload-begin!)
    (reload-finish!)
    (check-equal! (buffer-local ml--hr-a 'zz-ml-stamp) 2 "the visible buffer was rebuilt")

    ;; with the switch off, the visible half does not run
    (ml--major! "zz-ml-hr-visible" 3)
    (reload-begin!)
    (ml--modes-only reload-finish!)
    (check-equal! (buffer-local ml--hr-a 'zz-ml-stamp) 2 "the refresh ran with the switch off")
    (buffer-kill! ml--hr-a)))))
