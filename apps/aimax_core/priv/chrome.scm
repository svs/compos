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

;; M-x in a page offers exactly what M-x offers in the editor, most-recently
;; used first, each with the annotation the minibuffer would show.
(define (chrome--commands)
  (map (lambda (c) (list 'name c 'doc (command-annotation c)))
       (history-order 'M-x (command-names))))

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
;;; Buffers and tabs are not two kinds of thing that need reconciling. They are
;;; one list of places, ordered by when you were last in them, and the default
;;; is whatever is at the top that isn't where you are standing. Everything
;;; else — the toggle, coming back from a page, tabs being reachable — falls
;;; out of that ordering rather than needing a rule of its own.
;;;
;;; Kept per frame: one ai-max per browser window, so each frame has its own
;;; history. Same home the popup window and ibuffer use.

(define (chrome--mru) (or (frame-local 'chrome-mru) '()))

(define (chrome--touch! label)
  (when label
    (set-frame-local! 'chrome-mru
      (cons label (filter (lambda (l) (not (equal? l label))) (chrome--mru))))))

;; A place we have never seen, remembered at the BOTTOM of the history rather
;; than the top. You got to it somehow — the editor has its own buffer MRU and
;; plenty of ways to move that this list never sees — so it belongs in the
;; ordering, but it must not leapfrog somewhere you actually just came from.
(define (chrome--seed! label)
  (when (and label (not (chrome--seen? label)))
    (set-frame-local! 'chrome-mru (append (chrome--mru) (list label)))))

(define (chrome--find label cands)
  (let loop ((cs cands))
    (cond ((null? cs) #f)
          ((equal? (car (car cs)) label) (car cs))
          (else (loop (cdr cs))))))

(define (chrome--seen? label)
  (let loop ((ls (chrome--mru)))
    (cond ((null? ls) #f)
          ((equal? (car ls) label) #t)
          (else (loop (cdr ls))))))

;; the ones we have a history for, in that order, then everything else in
;; whatever order it arrived (buffer-list-mru is already recency-ordered)
(define (chrome--by-mru cands)
  (let loop ((ls (chrome--mru)) (acc '()))
    (if (null? ls)
        (append (reverse acc)
                (filter (lambda (c) (not (chrome--seen? (car c)))) cands))
        (let ((hit (chrome--find (car ls) cands)))
          (loop (cdr ls) (if hit (cons hit acc) acc))))))

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

(define (chrome--entry label cands)
  (let loop ((cs cands))
    (cond ((null? cs) (list label ""))
          ((equal? (car (car cs)) label) (car cs))
          (else (loop (cdr cs))))))

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
         ;; where the editor is sitting counts as somewhere you have been,
         ;; however you got there
         (_ (chrome--seed! here))
         ;; one pool, ordered by when you were last in each, minus where you
         ;; are now. RET takes the first candidate, so the top of that ordering
         ;; IS the default — there is nothing else to decide.
         ;; tabs lead the raw pool so that AFTER the MRU sort the ones you
         ;; have never visited still sit above buffers you have never visited
         ;; — an open tab is a live thing, a cold buffer isn't more recent
         ;; than it. Anything you have actually been in outranks both.
         (pool (chrome--by-mru (append (map chrome--tab-candidate tabs) cands)))
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
                 (chrome--touch! picked)
                 (tab-activate (chrome--get tab 'id)))
            ;; returning from a page: if it is already on screen, go to the
            ;; window showing it rather than rearranging the scene you are
            ;; trying to get back to
            (from-page
              (chrome--touch! picked)
              (let ((win (chrome--window-showing picked)))
                (if win (select-window! win) (switch-to-buffer! picked))))
            (else (chrome--touch! picked)
                  (switch-to-buffer! picked)))))
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
        (when t (chrome--touch! (car (chrome--tab-candidate t)))))))
  ;; Keep the tab cache warm on the ops a person actually initiates, so the
  ;; FIRST C-x b already has tabs in it. Not on mb-key/mb-state: those are the
  ;; overlay polling while a prompt is open, and a round-trip per keystroke is
  ;; both pointless and slow.
  (when (or (equal? op "commands") (equal? op "chord") (equal? op "run"))
    (chrome--refresh-tabs))
  (cond ((equal? op "attached") (chrome--refresh-tabs) (list 'ok #t))
        ((equal? op "commands") (list 'commands (chrome--commands)))
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
