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
  (run-command name)
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

(define (chrome--window-showing buf)
  (let loop ((ws (window-list)))
    (cond ((null? ws) #f)
          ((equal? (car (cdr (car ws))) buf) (car (car ws)))
          (else (loop (cdr ws))))))

(define-command "chrome-switch-to-buffer"
  "Return to ai-max showing a buffer, keeping the scene if it is already up"
  (lambda ()
    ;; captured before the prompt opens — while a minibuffer is active,
    ;; current-buffer answers with the minibuffer
    (let ((here (current-buffer))
          (cands (buffer-candidates)))
      (minibuffer-read
        (string-append "Buffer (default " here "): ")
        ;; the default is where you already were: from a page, C-x b RET means
        ;; "put me back", not Emacs's "switch me away to the other buffer"
        (cons (list here "here") cands)
        (lambda (name)
          (let* ((target (if (equal? name "") here name))
                 (win (chrome--window-showing target)))
            (if win
                (select-window! win)
                (switch-to-buffer! target))))))))

;; Chords a page should not send through raw dispatch, because returning from
;; outside wants different semantics than moving around inside.
(define *chrome-chord-commands*
  '(("C-x b" "chrome-switch-to-buffer")))

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
(define (chrome--confirmed)
  (append (chrome--with-mb '()) (list 'raise #t)))

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
  (cond ((equal? op "commands") (list 'commands (chrome--commands)))
        ((equal? op "run") (chrome--run (chrome--get args 'name)))
        ((equal? op "chord") (chrome--chord (or (chrome--get args 'keys) '())))
        ((equal? op "mb-key") (chrome--mb-key (chrome--get args 'spec)))
        ((equal? op "mb-state") (chrome--mb-state))
        (else (list 'error (string-append "unknown op: " op)))))

(browser-serve! chrome--serve)

;;; --- what we may ask of a tab ------------------------------------------------

;; Every call is async — a page operation is slow and keystrokes must not queue
;; behind it. Without a handler, failures land in the echo area.
(define (chrome--report reply)
  (if (chrome--get reply 'ok)
      #t
      (message (string-append "browser: " (or (chrome--get reply 'error) "failed")))))

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
