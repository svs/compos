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
  (let ((w (active-window)))
    (let loop ((ws (window-list)))
      (cond ((null? ws) (current-buffer))
            ((equal? (car (car ws)) w) (car (cdr (car ws))))
            (else (loop (cdr ws)))))))

(define (chrome--window-showing buf)
  (let loop ((ws (window-list)))
    (cond ((null? ws) #f)
          ((equal? (car (cdr (car ws))) buf) (car (car ws)))
          (else (loop (cdr ws))))))

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

(define (chrome--here-tabs tabs)
  (let ((w (frame-local 'chrome-window)))
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

(define (chrome--without label cands)
  (filter (lambda (c) (not (equal? (car c) label))) cands))

;; Order matters twice over. RET with nothing typed takes the FIRST candidate,
;; not the prompt's advertised default — so the default has to lead the list or
;; the prompt lies about what RET will do. And tabs went last, which with a
;; real number of buffers put them past the end of the visible window: present
;; in the list, invisible unless you typed. Default first, then the handful of
;; tabs, then the buffers.
(define (chrome--prompt-switch here cands tabs from-page)
  (let* ((standing (chrome--standing-on from-page))
         ;; one pool, ordered by when you were last in each, minus where you
         ;; are now. RET takes the first candidate, so the top of that ordering
         ;; IS the default — there is nothing else to decide.
         (pool (chrome--order cands (map chrome--tab-candidate tabs)))
         (all (chrome--without standing pool))
         (fallback (if (null? all) here (car (car all)))))
    (minibuffer-read-preview
      (string-append "Switch to buffer (default " fallback "): ")
      all
      ;; a tab has no buffer to preview; leave the window alone
      (lambda (b) (when (buffer-exists? b) (window-preview-buffer! b)))
      (lambda (name)
        (let* ((picked (if (equal? name "") fallback name))
               (tab (chrome--tab-by-label picked tabs)))
          (cond
            ;; a tab: go there, and don't drag the editor in front of the thing
            ;; you just asked for
            (tab (set! *chrome-raise?* #f)
                 (chrome--note-tab! picked)
                 (tab-activate (chrome--get tab 'id)))
            ;; returning from a page: if it is already on screen, go to the
            ;; window showing it rather than rearranging the scene you are
            ;; trying to get back to
            (from-page
              (let ((win (chrome--window-showing picked)))
                (if win (select-window! win) (switch-to-buffer! picked))))
            (else (switch-to-buffer! picked)))))
      ;; C-g puts back whatever the preview displaced — without this the
      ;; invoking window keeps the last buffer you happened to highlight
      (lambda () (when (buffer-exists? here) (window-preview-buffer! here))))))

;; Redefined, not rebound: keeping the name means C-x b, which-key and every
;; other reference still point at it, and the editor's behaviour is unchanged
;; except that the browser's tabs are now in the list.
;; Last known tabs. C-x b must NOT wait on the browser: it is a core editor
;; command, and a sleeping MV3 service worker would stall it for as long as the
;; round-trip takes. So the prompt opens immediately from this cache and the
;; refresh lands behind it, updating the candidates in place if you are still
;; deciding.
(define *chrome-tab-cache* '())

;; Refreshes the cache and nothing else. It used to also rewrite an open
;; prompt's candidates, which re-sorted the list under your fingers — and did
;; it in the wrong order, putting the tabs back past the end of the visible
;; window. The cache is primed when the extension attaches and refreshed on
;; every command, so a prompt can just read it and be right.
(define (chrome--refresh-tabs)
  (when (browser-connected?)
    (tab-list (lambda (all) (set! *chrome-tab-cache* all)))))

(define-command "switch-to-buffer"
  "Switch to another buffer — or to a browser tab in this window"
  (lambda ()
    ;; captured before the prompt opens: while a minibuffer is active,
    ;; current-buffer answers with the minibuffer
    (let ((here (chrome--here))
          ;; the whole list, recency-ordered; buffer-candidates drops the
          ;; current buffer, which from a page is the very thing you came back
          ;; for. Internals (space-prefixed) stay hidden, as ibuffer does.
          (cands (map (lambda (b) (list b ""))
                      (filter (lambda (b) (not (string-prefix? " " b)))
                              (buffer-list-mru))))
          (from-page *chrome-from-page*))
      (chrome--prompt-switch here cands (chrome--here-tabs *chrome-tab-cache*) from-page)
      (chrome--refresh-tabs))))

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
  (let ((r *chrome-raise?*))
    (set! *chrome-raise?* #t)
    (append (chrome--with-mb '()) (list 'raise r))))

(define (chrome--mb-key spec)
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
        ((equal? spec "DEL") (minibuffer-del!) (chrome--with-mb '()))
        ;; anything one character wide is text
        ((= (string-length spec) 1)
         (minibuffer-input! (string-append (chrome--get (minibuffer-state) 'input) spec))
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

(define (chrome-call op args k)
  (browser-call op args
    (lambda (reply)
      (if (chrome--report reply) (k reply) #f))))

(define (tab-list k)
  (chrome-call "tabs" '() (lambda (r) (k (chrome--get r 'tabs)))))

(define (tab-eval tab code k)
  (chrome-call "eval" (list 'tab tab 'code code) (lambda (r) (k (chrome--get r 'value)))))

;; world "main" reaches the page's own globals; the default sees the DOM only
(define (tab-eval-main tab code k)
  (chrome-call "eval" (list 'tab tab 'code code 'world "main")
    (lambda (r) (k (chrome--get r 'value)))))

(define (tab-read tab k)
  (chrome-call "read" (list 'tab tab) k))

;; put a line on the tab's screen — this is how the editor talks to a page
(define (tab-say tab text)
  (chrome-call "overlay" (list 'tab tab 'text text) chrome-ignore))

(define (tab-warn tab text)
  (chrome-call "overlay" (list 'tab tab 'text text 'kind "error") chrome-ignore))

;; trusted input: CDP attaches for this and lets go when idle
(define (tab-type tab text)
  (chrome-call "type" (list 'tab tab 'text text) chrome-ignore))

(define (tab-click tab x y)
  (chrome-call "click" (list 'tab tab 'x x 'y y) chrome-ignore))

(define (tab-open url) (chrome-call "open" (list 'url url) chrome-ignore))
(define (tab-activate tab) (chrome-call "activate" (list 'tab tab) chrome-ignore))
(define (tab-close tab) (chrome-call "close" (list 'tab tab) chrome-ignore))
(define (tab-release tab) (chrome-call "release" (list 'tab tab) chrome-ignore))

;; the raw protocol, for anything the verbs above don't cover
(define (tab-cdp tab method params k)
  (chrome-call "cdp" (list 'tab tab 'method method 'params params) k))

;;; --- commands ----------------------------------------------------------------

(define (chrome--tab-label t)
  (string-append (number->string (chrome--get t 'id)) "  "
                 (or (chrome--get t 'title) "")))

(define-command "list-tabs" "Show the browser's open tabs in a buffer"
  (lambda ()
    (tab-list
      (lambda (tabs)
        (let ((buf "*tabs*"))
          (buffer-create buf)
          (buffer-delete-range! buf 0 (buffer-size buf))
          (for-each
            (lambda (t)
              (buffer-append! buf (string-append (chrome--tab-label t) "\n"
                                                 "    " (or (chrome--get t 'url) "") "\n")))
            tabs)
          (display-buffer buf)
          (message (string-append (number->string (length tabs)) " tabs")))))))

(define-command "switch-to-tab" "Pick a browser tab and bring it to the front"
  (lambda ()
    (tab-list
      (lambda (tabs)
        (minibuffer-read "Tab: "
          (map (lambda (t) (list (chrome--tab-label t) (or (chrome--get t 'url) ""))) tabs)
          (lambda (pick)
            (let ((id (string->number (car (string-split pick " ")))))
              (if id (tab-activate id) (message "No such tab")))))))))

(public! 'tab-list "(tab-list K) — K gets every open browser tab as plists: id, title, url, active")
(public! 'tab-eval "(tab-eval TAB CODE K) — run JS in a tab; K gets the value")
(public! 'tab-read "(tab-read TAB K) — K gets the tab's url, title and visible text")
(public! 'tab-say "(tab-say TAB TEXT) — put a line on that tab's screen")
(public! 'tab-type "(tab-type TAB TEXT) — type into the tab for real (trusted input, via CDP)")
(public! 'tab-click "(tab-click TAB X Y) — a real click at viewport coordinates")
(public! 'tab-open "(tab-open URL) — open a new tab")
(public! 'tab-activate "(tab-activate TAB) — bring a tab to the front")
(public! 'tab-close "(tab-close TAB) — close a tab")
(public! 'tab-cdp "(tab-cdp TAB METHOD PARAMS K) — raw Chrome DevTools Protocol")
(public! 'browser-connected? "(browser-connected?) — is the ai-max Chrome extension attached?")
