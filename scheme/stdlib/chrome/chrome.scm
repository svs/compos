;;; chrome.scm --- compos's keys and commands in every tab.
;;;
;;; A tab asks this daemon what commands exist (M-x), asks it to run one,
;;; or hands it a chord (C-x ...). The list it gets is the editor's real
;;; command table — not a copy — so anything you can run in compos you can run
;;; from a page. This is policy.
;;;
;;; The connection itself — the tab verbs, browser-fetch, browser-snapshot,
;;; window routing and dom-* — is core: packages/browser.scm.
;;;
;;; Elixir supplies (browser-serve! HANDLER) and (dispatch-keys SPECS).

(require 'browser)

;;; --- plists ------------------------------------------------------------------
;;; packages/custom.scm loads after this file, so we can't lean on its getter

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
;;; Inside compos, C-x b pulls a buffer into the selected window — Emacs.
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
  (list (string-append *chrome-tab-mark* (or (plist-get t 'title) "(untitled)"))
        (or (plist-get t 'url) "")))

(define (chrome--tab-by-label label tabs)
  (let loop ((ts tabs))
    (cond ((null? ts) #f)
          ((equal? (car (chrome--tab-candidate (car ts))) label) (car ts))
          (else (loop (cdr ts))))))


(define (chrome--here-tabs tabs)
  (let ((w (chrome-window)))
    (if w
        (filter (lambda (t) (equal? (plist-get t 'window) w)) tabs)
        tabs)))

(define (chrome--tab-by-id id tabs)
  (let loop ((ts tabs))
    (cond ((null? ts) #f)
          ((equal? (plist-get (car ts) 'id) id) (car ts))
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
(add-hook! '(switch-buffer-source chrome)
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
;; A page draws prompts, not editor windows. C-x b opens the buffer
;; prompt: the same rows the editor's modal shows (switch.scm).
(define *chrome-chord-commands*
  '(("C-x b" "ibuffer-prompt")))

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
  ;; read it, so picking a tab with compos's OWN C-x b left it #f with nothing
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
         (minibuffer-change! (plist-get (minibuffer-state) 'input))
         (chrome--with-mb '()))
        ;; anything one character wide is text
        ((= (string-length spec) 1)
         (minibuffer-change!
           (string-append (plist-get (minibuffer-state) 'input) spec))
         (chrome--with-mb '()))
        (else (chrome--with-mb '()))))

;; the tab asking "is a prompt up?" — after a chord, or on reconnect
(define (chrome--mb-state) (chrome--with-mb '()))

(defcustom 'site-chat-group "*browse*"
  "Group the site chat of a browser tab opens in, the chat the extension's
   side panel shows. A chat made before a change stays in its group."
  'group 'web 'type 'string)

;; One chat per browser tab, all in the *browse* group. The tab keeps its
;; chat wherever it goes; a new tab starts a new one. The name only starts
;; out as the host: a chat renames itself after its first turn.
(define (chrome--site-chat-name host tab)
  (let ((base (string-append "*chat:browse:" host "*")))
    (if (and tab (buffer-known? base))
        (string-append "*chat:browse:" host "<" (number->string tab) ">*")
        base)))

(define *companion-prompt*
  (string-append
   "## Companion tab\n\n"
   "You are the chat in the side panel of one browser tab. "
   "`(chat-context)` names it as `companion-tab`: its id and URL, current each turn.\n\n"
   "- \"This\", \"here\" and \"the page\" mean that tab. Read it with "
   "`(tab-read ID K)` or `(tab-selection ID K)`, not `get-visible-buffers`.\n"
   "- To open, show or go to a web page, navigate that tab: `(tab-navigate ID URL K)`. "
   "Never `browse`, `tab-open` or another window for a web page.\n"
   "- Files and editor buffers are unaffected.\n"))

;; what chat-context shows a site chat: the tab it sits beside, read live
(define (companion-tab chat)
  (let ((tab (buffer-local-value 'browse-tab chat)))
    (and tab
         (list 'id tab
               'url (buffer-local-value 'browse-url chat)
               'note "\"this\" is this tab; open web pages in it with (tab-navigate ID URL K)"))))

;; the chat already beside TAB, whatever it is called by now
(define (chrome--site-chat-find id tab)
  (let loop ((bs (group-buffers id)))
    (cond ((null? bs) #f)
          ((equal? (buffer-local-value 'browse-tab (car bs)) tab) (car bs))
          (else (loop (cdr bs))))))

(define (site-chat host &optional tab url)
  (let* ((id (group-ensure-record! site-chat-group))
         (name (or (and tab (chrome--site-chat-find id tab))
                   (chrome--site-chat-name host tab))))
    (unless (buffer-known? name)
      (buffer-create name)
      (group-chat-init! name id)
      (chat-set-group! name id)
      (when (boundp (quote llm-default-bundle-apply!))
        (llm-default-bundle-apply! name))
      (when (boundp (quote workspace-chat-inherit!))
        (workspace-chat-inherit! name (group-name id))))
    ;; its tab, and where that tab is now: the way back to the page
    (buffer-set-local! name 'browse-site host)
    (when tab (buffer-set-local! name 'browse-tab tab))
    (when url (buffer-set-local! name 'browse-url url))
    (prompt-part-set! name "companion-tab" *companion-prompt*)
    name))

(define-command "site-chat-tab" "Go back to the browser tab this site chat was opened from"
  (lambda ()
    (let ((tab (buffer-local-value 'browse-tab (current-buffer)))
          (url (buffer-local-value 'browse-url (current-buffer))))
      ;; ask the browser, not the tab cache: a closed tab answers an error,
      ;; and only then does the page open again
      (cond (tab (browser-call "activate" (list 'tab tab)
                   (lambda (reply)
                     (unless (plist-get reply 'ok)
                       (if url (tab-open url) (browser--report reply))))))
            (url (tab-open url))
            (else (message "No tab for this chat"))))))

(define (chrome--serve op args)
  ;; Only the editor's own page says which window this frame sits in. Any
  ;; other request may come from a page in another window, and taking its
  ;; window here sent this frame's tabs there, out of sight.
  (let ((w (plist-get args 'window)))
    (when (and w (equal? op "register")
               (let ((f (plist-get args 'frame))) (or (not f) (equal? f (selected-frame)))))
      (set-frame-local! 'chrome-window w)))
  ;; the overlay is disabled on the editor's own page, so any request that
  ;; names a tab came from a real web page — that is the place to come back to,
  ;; when it is in this frame's window
  (let ((tb (plist-get args 'tab))
        (w (plist-get args 'window))
        (mine (chrome-window)))
    (when (and tb (or (not w) (not mine) (equal? w mine)))
      (set-frame-local! 'chrome-tab tb)
      (let ((t (chrome--tab-by-id tb *chrome-tab-cache*)))
        (when t (chrome--note-tab! (car (chrome--tab-candidate t)))))))
  ;; Keep the tab cache warm on the ops a person actually initiates, so the
  ;; FIRST C-x b already has tabs in it. Not on mb-key/mb-state: those are the
  ;; overlay polling while a prompt is open, and a round-trip per keystroke is
  ;; both pointless and slow.
  (when (or (equal? op "chord") (equal? op "run"))
    (chrome--refresh-tabs))
  (cond ((equal? op "attached")
         (chrome--refresh-tabs)
         ;; anything that waits for the extension hears it here
         (run-hook-with-args 'browser-attached-hook)
         (list 'ok #t))
        ;; the editor's own page, naming the browser window it sits in. The
        ;; prologue above stores it; this frame now knows where its tabs go.
        ((equal? op "register") (list 'ok #t))
        ((equal? op "run") (chrome--run (plist-get args 'name)))
        ((equal? op "chord") (chrome--chord (or (plist-get args 'keys) '())))
        ((equal? op "mb-key") (chrome--mb-key (plist-get args 'spec)))
        ((equal? op "mb-state") (chrome--mb-state))
        ((equal? op "site-chat") (list 'buffer (site-chat (plist-get args 'host) (plist-get args 'tab) (plist-get args 'url))))
        (else (list 'error (string-append "unknown op: " op)))))

(browser-serve! chrome--serve)

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
                                                 "    " (or (plist-get t 'url) "") "\n")))
            tabs)
          (display-buffer buf)
          (message (string-append (number->string (length tabs)) " tabs")))))))

;; Frames are only ever deleted by hand, so closed tabs pile them up and
;; the desktop restores the pile. The sweep keeps every frame a browser
;; tab answers for, plus the frame this command runs in. A client without
;; the extension is not seen — do not sweep while one is open.
(domain! 'chrome)

(effects! '(destroy))

(define-command "refresh-frames" "Delete frames no browser tab shows"
  (lambda ()
    (let ((here (selected-frame)))
      (browser-frames
        (lambda (bound)
          (let* ((live (cons here (map (lambda (e) (plist-get e 'frame)) bound)))
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

