;;; chrome.scm --- ai-max's keys and commands in every tab, and the wire back.
;;;
;;; Two directions, and both are policy.
;;;
;;; Inbound: a tab asks this daemon what commands exist (M-x), asks it to run
;;; one, or hands it a chord (C-x ...). The list it gets is the editor's real
;;; command table — not a copy — so anything you can run in ai-max you can run
;;; from a page.
;;;
;;; Outbound: Scheme addresses any tab. Run JS in it, read it, put a line on
;;; its screen, type into it for real. The last one goes through CDP, which the
;;; extension attaches only for that and drops when idle: trusted input is the
;;; one thing a content script cannot fake.
;;;
;;; Elixir supplies (browser-call OP ARGS CB), (browser-serve! HANDLER) and
;;; (dispatch-keys SPECS). Everything below is decided here.

;;; --- plists ------------------------------------------------------------------
;;; packages/custom.scm loads after this file, so we can't lean on its getter

(define (chrome--get pl key)
  (cond ((null? pl) #f)
        ((null? (cdr pl)) #f)
        ((equal? (car pl) key) (car (cdr pl)))
        (else (chrome--get (cdr (cdr pl)) key))))

;;; --- what a tab may ask us ---------------------------------------------------

;; M-x in a page is the editor's own execute-extended-command — the extension
;; asks for it by name and renders the minibuffer it opens. There is no second
;; command list and no second matcher.

;; Half the interesting commands ask a question — C-x b, C-x C-f, M-x itself.
;; The answer has to be given where the question was asked, so every reply
;; carries the minibuffer's state and the tab draws it. Without this, C-x b
;; from a page opens a prompt in the editor window that nobody is looking at.
;; 'open is always present so the reply is an object even when nothing is being
;; asked — an empty plist would serialise as [] and the tab would have to guess
(define (chrome--with-mb reply)
  (let ((mb (minibuffer-state)))
    (if mb
        (append reply (list 'open #t 'minibuffer mb))
        (append reply (list 'open #f)))))

;; The command runs here, in the daemon. A page is an input device; the editor
;; is still the thing doing the work.
(define (chrome--run name)
  (history-push! 'M-x name)
  ;; the command captures this while it runs; a prompt it opens keeps the
  ;; answer in its own closure, so clearing it afterwards is safe
  (set! *chrome-from-page* #t)
  (run-command name)
  (set! *chrome-from-page* #f)
  (chrome--with-mb (list 'message (string-append "ran " name))))

;;; --- coming back to the editor -----------------------------------------------
;;;
;;; Inside ai-max, C-x b pulls a buffer into the selected window — Emacs.
;;; Arriving from a web page it has to mean something slightly different: you
;;; are not switching, you are RETURNING. If the buffer you name is already on
;;; screen (notmuch's index/show/chat scene, say) then pulling it somewhere
;;; else would destroy the layout you are trying to get back to. So: visible
;;; means go to it, invisible means pull it in. That is pop-to-buffer, and it
;;; is why this is its own command rather than a raw C-x b.

;; The buffer you are actually looking at in this frame.
;;
;; NOT (current-buffer): while a minibuffer is active that answers with the
;; minibuffer, and a prompt left open in the editor is enough to make "the
;; buffer I was on" come back as " *minibuf-f-xxxx*". Asking the selected
;; WINDOW is immune to that, which matters most here — the whole point of
;; C-x b RET from a page is to land back where you were.
(define (chrome--here)
  (or (window-buffer (active-window)) (current-buffer)))

(define (chrome--window-showing buf) (window-showing buf))

;; A tab in this window is a place you can switch to, so it belongs in the same
;; list as the buffers. The globe marks which is which, and doubles as the key
;; we match on when the choice comes back.
(define *chrome-tab-mark* "🌐 ")

(define (chrome--tab-candidate t)
  (list (string-append *chrome-tab-mark* (or (chrome--get t 'title) "(untitled)"))
        (or (chrome--get t 'url) "")))

(define (chrome--tab-by-label label tabs)
  (let loop ((ts tabs))
    (cond ((null? ts) #f)
          ((equal? (car (chrome--tab-candidate (car ts))) label) (car ts))
          (else (loop (cdr ts))))))

;; The browser window this frame is displayed in, as the extension last said.
;; A frame learns it two ways: the editor page registers when it loads, and
;; every key pressed in a page in that window carries it. #f means the
;; extension has not told us yet — then Chrome chooses.
(define (chrome-window) (frame-local 'chrome-window))

(define (chrome--here-tabs tabs)
  (let ((w (chrome-window)))
    (if w
        (filter (lambda (t) (equal? (chrome--get t 'window) w)) tabs)
        tabs)))

(define (chrome--tab-by-id id tabs)
  (let loop ((ts tabs))
    (cond ((null? ts) #f)
          ((equal? (chrome--get (car ts) 'id) id) (car ts))
          (else (loop (cdr ts))))))

;;; --- one list, most recently used first --------------------------------------
;;;
;;; The editor already keeps this. buffer-list-mru is its ring, updated
;;; wherever a buffer gets displayed — the same single choke point Emacs uses
;;; in record_buffer, rather than each command remembering to mark. Keeping a
;;; second history here was the mistake: it only saw switches that went through
;;; this one command, so it drifted from the truth and then outranked it.
;;;
;;; So buffers are not tracked at all. The only thing missing from the ring is
;;; tabs, and for those one fact is enough: the tab you were last in, plus the
;;; buffer that was at the head of the ring at that moment. If the head has not
;;; moved since, nothing has been displayed after that tab and it is still the
;;; most recent place. If it has moved, a buffer is. That is the whole
;;; interleave, and it invalidates itself.

(define (chrome--note-tab! label)
  (when label
    (set-frame-local! 'chrome-tab-visit (list label (car (buffer-list-mru))))))

(define (chrome--tab-is-latest?)
  (let ((v (frame-local 'chrome-tab-visit)))
    (if v (equal? (car (cdr v)) (car (buffer-list-mru))) #f)))

(define (chrome--last-tab-label)
  (let ((v (frame-local 'chrome-tab-visit)))
    (if v (car v) #f)))

(define (chrome--without label cands)
  (filter (lambda (c) (not (equal? (car c) label))) cands))

(define (chrome--find label cands)
  (let loop ((cs cands))
    (cond ((null? cs) #f)
          ((equal? (car (car cs)) label) (car cs))
          (else (loop (cdr cs))))))

;; buffers in the editor's own order, tabs behind them — unless the last place
;; you were was a tab, in which case it leads.
(define (chrome--order buffers tabs)
  (let* ((label (chrome--last-tab-label))
         (hit (if (and label (chrome--tab-is-latest?)) (chrome--find label tabs) #f)))
    (if hit
        (cons hit (append buffers (chrome--without label tabs)))
        (append buffers tabs))))

;; Set while a browser request is being served, so the command below can tell
;; where the keystroke came from. The candidate LIST is the same either way —
;; what differs is what selecting does.
(define *chrome-from-page* #f)

;; Where you are standing right now, and therefore the one place RET should
;; never mean. In the editor that's the selected window's buffer; in a page
;; it's the tab you pressed the key in.
(define (chrome--standing-on from-page)
  (if from-page
      (let* ((id (frame-local 'chrome-tab))
             (t (if id (chrome--tab-by-id id *chrome-tab-cache*) #f)))
        (if t (car (chrome--tab-candidate t)) #f))
      (chrome--here)))

;; Last known tabs. C-x b must NOT wait on the browser: it is a core editor
;; command, and a sleeping MV3 service worker would stall it for as long as the
;; round-trip takes. So the prompt opens immediately from this cache and the
;; refresh lands behind it, in time for the next command.
(define *chrome-tab-cache* '())

;; Refreshes the cache and nothing else. It used to also rewrite an open
;; prompt's candidates, which re-sorted the list under your fingers — and did
;; it in the wrong order, putting the tabs back past the end of the visible
;; window. The cache is primed when the extension attaches and refreshed on
;; every command, so a prompt can just read it and be right.
(define (chrome--refresh-tabs)
  (when (browser-connected?)
    (tab-list (lambda (all) (set! *chrome-tab-cache* all)))))

;; ONE way to go to a tab (dup #7): record the visit, activate it, and do
;; not drag the editor window in front of the thing you just asked for.
(define (chrome--goto-tab! tab label)
  (set! *chrome-raise?* #f)
  (chrome--note-tab! label)
  (tab-activate tab))

;; C-x b keeps the editor's own command; this source adds the browser's
;; tabs through the seam instead of redefining it (dup #6). Tabs used to
;; go last, which with a real number of buffers put them past the end of
;; the visible window — chrome--order interleaves by recency instead.
;; The candidate pool is the same from either side; what differs is what
;; standing means (from a page it is the tab you pressed the key in) and
;; what picking does.
(set! switch-buffer-source
  (lambda (cands)
    (let* ((from-page *chrome-from-page*)
           (tabs (chrome--here-tabs *chrome-tab-cache*))
           (pool (chrome--order cands (map chrome--tab-candidate tabs))))
      (chrome--refresh-tabs)
      (list pool
            (chrome--standing-on from-page)
            (lambda (picked)
              (let ((tab (chrome--tab-by-label picked tabs)))
                (cond
                  (tab (chrome--goto-tab! tab picked) #t)
                  ;; returning from a page: if it is already on screen, go
                  ;; to the window showing it rather than rearranging the
                  ;; scene you are trying to get back to
                  (from-page
                   (let ((win (chrome--window-showing picked)))
                     (if win (begin (select-window! win) #t) #f)))
                  (else #f))))))))

;; Chords a page should not send through raw dispatch, because returning from
;; outside wants different semantics than moving around inside.
(define *chrome-chord-commands*
  '(("C-x b" "switch-to-buffer")))

(define (chrome--chord-command keys)
  (let ((entry (assoc (string-join keys " ") *chrome-chord-commands*)))
    (if entry (car (cdr entry)) #f)))

;; A chord goes through the same dispatcher the GUI uses, one key at a time, so
;; C-x b from a page means what C-x b means everywhere else.
(define (chrome--chord keys)
  (let ((cmd (chrome--chord-command keys)))
    (if cmd
        (chrome--run cmd)
        (begin
          ;; one call, not one per key: the prefix and its suffix must reach
          ;; the dispatcher in order, or C-x b arrives as two unrelated keys
          ;; and does nothing at all
          (dispatch-keys keys)
          ;; dispatch runs off-process to avoid deadlocking the interpreter, so
          ;; the prompt may not be up yet — the tab asks again a moment later
          (chrome--with-mb (list 'message (string-join keys " ")))))))

;; A key aimed at an open prompt. The editor's own minibuffer keymap is the
;; reference: same keys, same meanings, just arriving from a page.
;; Answering a question means you want to see the answer: confirming raises the
;; editor's tab. Cancelling doesn't — you changed your mind, stay where you are.
;; A confirm handler that sends you somewhere else (picking a TAB rather than a
;; buffer) clears this, so we don't yank the editor in front of the tab you
;; just asked for.
(define *chrome-raise?* #t)

(define (chrome--confirmed)
  (append (chrome--with-mb '()) (list 'raise *chrome-raise?*)))

(define (chrome--mb-key spec)
  ;; Fresh for every key. This used to be reset only when a from-page confirm
  ;; read it, so picking a tab with ai-max's OWN C-x b left it #f with nothing
  ;; to clear it — and the next time you came back from a page the editor
  ;; silently refused to come forward.
  (set! *chrome-raise?* #t)
  (cond ((not (minibuffer-state)) (list 'message "no prompt"))
        ((equal? spec "RET") (minibuffer-confirm!) (chrome--confirmed))
        ((equal? spec "M-RET") (minibuffer-confirm-input!) (chrome--confirmed))
        ((equal? spec "C-g") (minibuffer-cancel!) (chrome--with-mb '()))
        ((equal? spec "ESC") (minibuffer-cancel!) (chrome--with-mb '()))
        ((equal? spec "TAB") (minibuffer-complete!) (chrome--with-mb '()))
        ((equal? spec "C-n") (minibuffer-next!) (chrome--with-mb '()))
        ((equal? spec "C-p") (minibuffer-prev!) (chrome--with-mb '()))
        ((equal? spec "<down>") (minibuffer-next!) (chrome--with-mb '()))
        ((equal? spec "<up>") (minibuffer-prev!) (chrome--with-mb '()))
        ((equal? spec "DEL")
         (minibuffer-del!)
         (minibuffer-change! (chrome--get (minibuffer-state) 'input))
         (chrome--with-mb '()))
        ;; anything one character wide is text
        ((= (string-length spec) 1)
         (minibuffer-change!
           (string-append (chrome--get (minibuffer-state) 'input) spec))
         (chrome--with-mb '()))
        (else (chrome--with-mb '()))))

;; the tab asking "is a prompt up?" — after a chord, or on reconnect
(define (chrome--mb-state) (chrome--with-mb '()))

(define (chrome--serve op args)
  (let ((w (chrome--get args 'window)))
    (when w (set-frame-local! 'chrome-window w)))
  ;; the overlay is disabled on the editor's own page, so any request that
  ;; names a tab came from a real web page — that is the place to come back to
  (let ((tb (chrome--get args 'tab)))
    (when tb
      (set-frame-local! 'chrome-tab tb)
      (let ((t (chrome--tab-by-id tb *chrome-tab-cache*)))
        (when t (chrome--note-tab! (car (chrome--tab-candidate t)))))))
  ;; Keep the tab cache warm on the ops a person actually initiates, so the
  ;; FIRST C-x b already has tabs in it. Not on mb-key/mb-state: those are the
  ;; overlay polling while a prompt is open, and a round-trip per keystroke is
  ;; both pointless and slow.
  (when (or (equal? op "chord") (equal? op "run"))
    (chrome--refresh-tabs))
  (cond ((equal? op "attached") (chrome--refresh-tabs) (list 'ok #t))
        ;; the editor's own page, naming the browser window it sits in. The
        ;; prologue above stores it; this frame now knows where its tabs go.
        ((equal? op "register") (list 'ok #t))
        ((equal? op "run") (chrome--run (chrome--get args 'name)))
        ((equal? op "chord") (chrome--chord (or (chrome--get args 'keys) '())))
        ((equal? op "mb-key") (chrome--mb-key (chrome--get args 'spec)))
        ((equal? op "mb-state") (chrome--mb-state))
        (else (list 'error (string-append "unknown op: " op)))))

(browser-serve! chrome--serve)

;;; --- what we may ask of a tab ------------------------------------------------

;; Every call is async — a page operation is slow and keystrokes must not queue
;; behind it. Without a handler, failures land in the echo area.
;; Must return #f on failure, explicitly. (message ...) answers with something
;; truthy, so returning it directly made every failed call fall through to its
;; continuation with a reply that has no result in it — a failed tab refresh
;; then wrote #f over the tab cache, and every filter after that died on a
;; value that was no longer a list.
(define (chrome--report reply)
  (if (chrome--get reply 'ok)
      #t
      (begin
        (message (string-append "browser: " (or (chrome--get reply 'error) "failed")))
        #f)))

;; this Scheme has no rest arguments, so every call takes an explicit handler
;; and the fire-and-forget verbs pass this one
(define (chrome-ignore reply) #t)

;; Agent access is policy, not browser mechanism. Packages may replace this
;; Scheme hook. It is consulted only while eval-scheme is running, so ordinary
;; editor commands such as C-x b keep their browser integration.
(define *browser-tool-policy* (lambda (buf) 'allow))

(define (chrome--tool-buffer)
  (and (boundp (quote *llm-tool-buffer*)) *llm-tool-buffer*))

(define (chrome--tool-allowed?)
  (let ((buf (chrome--tool-buffer)))
    (or (not buf) (equal? (*browser-tool-policy* buf) 'allow))))

;; Take either a tab id or a whole tab plist. The assistant reaches these
;; through apropos's one-line docs, and "TAB" reads like the thing
;; tab-list just handed it — passing the plist made the extension fail with
;; "no ai-max in tab [object Object]", once per retry, until the tool loop hit
;; its turn limit. Being liberal here is cheaper than being right about it.
(define (chrome--tab-id t)
  (if (number? t) t (chrome--get t 'id)))

(define (chrome-call op args k)
  (if (chrome--tool-allowed?)
      (browser-call op args
        (lambda (reply)
          (if (chrome--report reply) (k reply) #f)))
      (error
        "browser category denied in code-mode; use ai-max state, or ask the user to enable M-x browser-mode as a last resort")))

(define (tab-list k)
  (chrome-call "tabs" '() (lambda (r) (k (chrome--get r 'tabs)))))

(define (tab-eval tab code k)
  (chrome-call "eval" (list 'tab (chrome--tab-id tab) 'code code)
    (lambda (r) (k (chrome--get r 'value)))))

;; world "main" reaches the page's own globals; the default sees the DOM only
(define (tab-eval-main tab code k)
  (chrome-call "eval" (list 'tab (chrome--tab-id tab) 'code code 'world "main")
    (lambda (r) (k (chrome--get r 'value)))))

(define (tab-read tab k)
  (chrome-call "read" (list 'tab (chrome--tab-id tab)) k))

;; put a line on the tab's screen — this is how the editor talks to a page
(define (tab-say tab text)
  (chrome-call "overlay" (list 'tab (chrome--tab-id tab) 'text text) chrome-ignore))

(define (tab-warn tab text)
  (chrome-call "overlay" (list 'tab (chrome--tab-id tab) 'text text 'kind "error") chrome-ignore))

;; trusted input: CDP attaches for this and lets go when idle
(define (tab-type tab text)
  (chrome-call "type" (list 'tab (chrome--tab-id tab) 'text text) chrome-ignore))

(define (tab-click tab x y)
  (chrome-call "click" (list 'tab (chrome--tab-id tab) 'x x 'y y) chrome-ignore))

;; A tab opens beside the frame that asked for it. A chat on one screen must
;; not answer by opening a tab on another: the frame knows its browser window,
;; so the open op names it. WINDOW overrides that for the rare cross-window
;; case; with neither, Chrome picks the window it focused last.
(define (tab-open url &optional window)
  (let ((w (or window (chrome-window))))
    (chrome-call "open"
      (if w (list 'url url 'window w) (list 'url url))
      chrome-ignore)))
(define (tab-activate tab) (chrome-call "activate" (list 'tab (chrome--tab-id tab)) chrome-ignore))
(define (tab-close tab) (chrome-call "close" (list 'tab (chrome--tab-id tab)) chrome-ignore))
(define (tab-release tab) (chrome-call "release" (list 'tab (chrome--tab-id tab)) chrome-ignore))

;; the raw protocol, for anything the verbs above don't cover
(define (tab-cdp tab method params k)
  (chrome-call "cdp" (list 'tab (chrome--tab-id tab) 'method method 'params params) k))

;; K gets one plist per ai-max tab the browser holds: window, tab, frame.
;; The extension probes every localhost tab, so a background editor tab
;; still reports its frame.
(define (browser-frames k)
  (chrome-call "frames" '() (lambda (r) (k (chrome--get r 'frames)))))

;;; --- commands ----------------------------------------------------------------

;; every surface names a tab the same way (dup #7): the label from
;; chrome--tab-candidate, resolved back with chrome--tab-by-label
(define-command "list-tabs" "Show the browser's open tabs in a buffer"
  (lambda ()
    (tab-list
      (lambda (tabs)
        (let ((buf "*tabs*"))
          (buffer-create buf)
          (buffer-delete-range! buf 0 (buffer-size buf))
          (for-each
            (lambda (t)
              (buffer-append! buf (string-append (car (chrome--tab-candidate t)) "\n"
                                                 "    " (or (chrome--get t 'url) "") "\n")))
            tabs)
          (display-buffer buf)
          (message (string-append (number->string (length tabs)) " tabs")))))))

;; Frames are only ever deleted by hand, so closed tabs pile them up and
;; the desktop restores the pile. The sweep keeps every frame a browser
;; tab answers for, plus the frame this command runs in. A client without
;; the extension is not seen — do not sweep while one is open.
(domain! 'chrome)
(effects! '(read))

(public! 'browser-frames
  "(browser-frames K) — K gets one plist per ai-max browser tab: window, tab, frame")

(effects! '(destroy))

(define-command "refresh-frames" "Delete frames no browser tab shows"
  (lambda ()
    (let ((here (selected-frame)))
      (browser-frames
        (lambda (bound)
          (let* ((live (cons here (map (lambda (e) (chrome--get e 'frame)) bound)))
                 (dead (filter (lambda (f) (not (member f live))) (frame-list))))
            (for-each (lambda (f) (delete-frame! f)) dead)
            (message (string-append "frames: dropped "
                                    (number->string (length dead))
                                    ", kept "
                                    (number->string (length (frame-list)))))))))))

(domain! 'unknown)
(effects! '(unknown))

(define-command "switch-to-tab" "Pick a browser tab and bring it to the front"
  (lambda ()
    (tab-list
      (lambda (tabs)
        (minibuffer-read "Tab: "
          (map chrome--tab-candidate tabs)
          (lambda (pick)
            (let ((tab (chrome--tab-by-label pick tabs)))
              (if tab (chrome--goto-tab! tab pick) (message "No such tab")))))))))

(category! 'chrome)
(public! 'tab-list "(tab-list K) — K gets every open browser tab as plists: id, title, url, active")
(public! 'tab-eval "(tab-eval TAB CODE K) — run JS in a tab; TAB is an id or a tab from tab-list")
(public! 'tab-read "(tab-read TAB K) — K gets the tab's url, title and visible text; TAB is an id or a tab from tab-list")
(public! 'tab-say "(tab-say TAB TEXT) — put a line on that tab's screen")
(public! 'tab-type "(tab-type TAB TEXT) — type into the tab for real (trusted input, via CDP)")
(public! 'tab-click "(tab-click TAB X Y) — a real click at viewport coordinates")
(public! 'tab-open "(tab-open URL &optional WINDOW) — open a new tab, in this frame's browser window unless WINDOW says otherwise")
(public! 'tab-activate "(tab-activate TAB) — bring a tab to the front")
(public! 'tab-close "(tab-close TAB) — close a tab")
(public! 'tab-cdp "(tab-cdp TAB METHOD PARAMS K) — raw Chrome DevTools Protocol")
(public! 'browser-connected? "(browser-connected?) — is the ai-max Chrome extension attached?")

;; the rest of this section predates the metadata declarations and takes the
;; reviewed backfill; a new name stamps itself
(domain! 'chrome)
(effects! '(read))
(public! 'chrome-window "(chrome-window) — the browser window this frame is displayed in, or #f")
