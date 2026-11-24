;;; browser.scm --- the connection to the user's browser: a core feature.
;;;
;;; Every call the editor makes of a browser tab goes through here: the tab
;;; verbs (tab-list, tab-eval, tab-read, tab-open ...), the reads through
;;; the browser (browser-fetch, browser-snapshot), which window and profile a
;;; call lands in (chrome-here, chrome-window-resolve!), and the editor page's
;;; own DOM (dom-eval, dom-measure). What a tab may ask of the editor -- keys,
;;; M-x, the minibuffer, site chats -- is policy, and lives in the chrome
;;; package, which requires this one.
;;;
;;; Elixir supplies (browser-call OP ARGS CB), (browser-call-sync OP ARGS MS),
;;; (browser-connected?) and (browser-serve! HANDLER).

;; The browser window this frame is displayed in, as the extension last said.
;; A frame learns it two ways: the editor page registers when it loads, and
;; every key pressed in a page in that window carries it. #f means the
;; extension has not told us yet — then Chrome chooses.
(define (chrome-window) (frame-local 'chrome-window))

;;; --- what we may ask of a tab ------------------------------------------------

;; Every call is async — a page operation is slow and keystrokes must not queue
;; behind it. Without a handler, failures land in the echo area.
;; Must return #f on failure, explicitly. (message ...) answers with something
;; truthy, so returning it directly made every failed call fall through to its
;; continuation with a reply that has no result in it — a failed tab refresh
;; then wrote #f over the tab cache, and every filter after that died on a
;; value that was no longer a list.
(define (browser--report reply)
  (if (plist-get reply 'ok)
      #t
      (begin
        (message (string-append "browser: " (or (plist-get reply 'error) "failed")))
        #f)))

;; this Scheme has no rest arguments, so every call takes an explicit handler
;; and the fire-and-forget verbs pass this one
(define (chrome-ignore reply) #t)

;; Agent access is policy, not browser mechanism. Packages may replace this
;; Scheme hook. It is consulted only while eval-scheme is running, so ordinary
;; editor commands such as C-x b keep their browser integration.
(define *browser-tool-policy* (lambda (buf) 'allow))

(define (browser--tool-buffer)
  (and (boundp (quote llm-tool-buffer)) (llm-tool-buffer)))

(define (browser--tool-allowed?)
  (let ((buf (browser--tool-buffer)))
    (or (not buf) (equal? (*browser-tool-policy* buf) 'allow))))

;; Take either a tab id or a whole tab plist. The assistant reaches these
;; through apropos's one-line docs, and "TAB" reads like the thing
;; tab-list just handed it — passing the plist made the extension fail with
;; "no compos in tab [object Object]", once per retry, until the tool loop hit
;; its turn limit. Being liberal here is cheaper than being right about it.
(define (browser--tab-id t)
  (if (number? t) t (plist-get t 'id)))

(define (chrome-call op args k)
  ;; a refusal still answers K, with the error reply: a caller waiting on K
  ;; must hear the no rather than sit out its timeout
  (if (browser--tool-allowed?)
      (browser-call op args
        (lambda (reply)
          (browser--report reply)
          (k reply)))
      (error
        "browser category denied in code-mode; use compos state, or ask the user to enable M-x browser-mode as a last resort")))

(define (tab-list k)
  ;; only this frame's window: another window's tabs belong to another frame,
  ;; often another profile with other logins. A frame no browser window shows
  ;; (the desktop app's) has no window to keep to, so it takes every tab of the
  ;; extension the bridge routes it to: the profile it is connected to.
  (let ((w (chrome-window-resolve!)))
    (chrome-call "tabs" (if w (list 'window w) '())
      (lambda (r)
        (let ((ts (or (plist-get r 'tabs) '())))
          (k (if w (filter (lambda (t) (equal? (plist-get t 'window) w)) ts) ts)))))))

;; the reader's fetch, THROUGH the browser: the user's cookies and
;; Chrome's http cache ride along, so a page that knows them logged in
;; reads logged in. K gets (TYPE TEXT BASE64) — a text body as text, a
;; body of bytes base64 encoded, never both — or #f for no browser and
;; no page. Bytes that came back as text would be bytes no longer: a PDF
;; read as text loses every byte that is not UTF-8.
;; browser-call directly: this is a user surface, not an agent tool,
;; and its caller falls back to curl instead of erroring.
(define (browser-fetch url k)
  (if (browser-connected?)
      (browser-call "fetch" (chrome-here (list 'url url))
        (lambda (reply)
          (k (let ((type (plist-get reply 'type))
                   (html (plist-get reply 'html))
                   (body (plist-get reply 'body)))
               (cond ((and (string? html) (not (equal? html ""))) (list type html #f))
                     ((and (string? body) (not (equal? body ""))) (list type #f body))
                     (else #f))))))
      (k #f)))

;; the AUTHENTICATED read: a real background tab loads the page — the
;; site's own sessions, SSO redirects and scripts run — and the
;; RENDERED document comes back. Slower than browser-fetch; right when
;; logged-in content matters. K gets the html, or #f.
;; WAIT names a CSS selector the caller knows the content by. A page that
;; renders itself is not finished when the load is, and without a selector
;; there is nothing to watch for but the clock.
(define (browser-snapshot url k &optional wait)
  (if (browser-connected?)
      (browser-call "snapshot"
        ;; the window routes the load to this frame's own profile and its logins
        (chrome-here (append (list 'url url)
                             (if wait (list 'wait wait) '())))
        (lambda (reply)
          (k (let ((h (plist-get reply 'html)))
               (and (string? h) (not (equal? h "")) h)))))
      (k #f)))


(domain! 'chrome)
(effects! '(read external))

(define (tab-navigate tab url k &optional wait)
  (chrome-call "navigate"
    (append (list 'tab (browser--tab-id tab) 'url url)
            (if wait (list 'wait wait) '()))
    (lambda (reply)
      (let ((html (plist-get reply 'html)))
        (k (and (string? html)
                (not (equal? html ""))
                (list 'tab (plist-get reply 'tab)
                      'url (plist-get reply 'url)
                      'title (plist-get reply 'title)
                      'html html)))))))

(public! 'tab-navigate
  "(tab-navigate TAB URL K [WAIT]) — navigate the persistent background TAB, wait for rendered WAIT, and give K its url, title and html")

;; Press a button on the live page the way the user would, through the
;; extension (no debugger). K gets the rendered html once the page settled,
;; or #f when the button is missing or the page never answered.
(define (tab-press tab selector k &optional wait)
  ;; browser-call, not chrome-call: a failed press must answer #f at once.
  ;; chrome-call drops errors, and a caller waiting on K would hang.
  (browser-call "press"
    (append (list 'tab (browser--tab-id tab) 'selector selector)
            (if wait (list 'wait wait) '()))
    (lambda (reply)
      (let ((html (and (plist-get reply 'ok) (plist-get reply 'html))))
        (unless (plist-get reply 'ok)
          (message (string-append "tab-press: " (or (plist-get reply 'error) "failed"))))
        (k (and (string? html)
                (not (equal? html ""))
                (not (plist-get reply 'timedOut))
                html))))))

(public! 'tab-press
  "(tab-press TAB SELECTOR K [WAIT]) — click SELECTOR in the background TAB through the extension; K gets the html once LiveView patched and WAIT matches")
(define (tab-eval tab code k)
  (chrome-call "eval" (list 'tab (browser--tab-id tab) 'code code)
    (lambda (r) (k (plist-get r 'value)))))

;; world "main" reaches the page's own globals; the default sees the DOM only
(define (tab-eval-main tab code k)
  (chrome-call "eval" (list 'tab (browser--tab-id tab) 'code code 'world "main")
    (lambda (r) (k (plist-get r 'value)))))

(define (tab-read tab k)
  (chrome-call "read" (list 'tab (browser--tab-id tab)) k))

;; put a line on the tab's screen — this is how the editor talks to a page
(define (tab-say tab text)
  (chrome-call "overlay" (list 'tab (browser--tab-id tab) 'text text) chrome-ignore))

(define (tab-warn tab text)
  (chrome-call "overlay" (list 'tab (browser--tab-id tab) 'text text 'kind "error") chrome-ignore))

;; trusted input: CDP attaches for this and lets go when idle
(define (tab-type tab text)
  (chrome-call "type" (list 'tab (browser--tab-id tab) 'text text) chrome-ignore))

(define (tab-click tab x y)
  (chrome-call "click" (list 'tab (browser--tab-id tab) 'x x 'y y) chrome-ignore))

;; A tab opens beside the frame that asked for it. A chat on one screen must
;; not answer by opening a tab on another: the frame knows its browser window,
;; so the open op names it. WINDOW overrides that for the rare cross-window
;; case; with neither, Chrome picks the window it focused last.
;; A tab opens beside the frame that asked for it. A chat on one screen must
;; not answer by opening a tab on another: the frame knows its browser window,
;; so the open op names it. WINDOW overrides that for the rare cross-window
;; case.
;;
;; The extension tells a frame its window when the editor page registers, but
;; a frame shown by a client that never registered (or one that registered
;; before this Session booted) has no local to read. Chrome then chose for
;; itself and the tab landed in whatever window it focused last -- usually
;; not the one the reader is in. So ask the browser instead: the frames op
;; names the window each compos tab sits in. This frame's own tab is the
;; answer; any compos tab is a better guess than none.
(define (browser--frames-sync)
  (if (and (browser-connected?) (browser--tool-allowed?))
      (or (plist-get (browser-call-sync "frames" '() 3000) 'frames) '())
      '()))

;; Which browser window this frame belongs to. Every tab carries its own, so
;; this is what tells a tab in front of the reader from a tab on another
;; screen.
;; Every browser thing happens in the active frame's window. A call that
;; names neither a tab nor a window goes to whichever profile registered last,
;; so each op that picks a place passes its ARGS through this.
(define (chrome-here args)
  (if (or (plist-get args 'tab) (plist-get args 'window))
      args
      (let ((w (chrome-window-resolve!)))
        (if w (append args (list 'window w)) args))))

(define (tab-window)
  (chrome-window-resolve!))

;; The tabs in THIS frame's browser window. tab-list answers the whole
;; browser, and a browser is not one place: 55 tabs across 7 windows on the
;; machine this was written on, 10 of them here. A tab in another window is
;; another screen and another piece of work, so an app looking for a tab it
;; may drive wants this list, not that one. Answers every tab when the frame
;; has no window of its own to speak of.
(define (tabs-here k)
  (let ((here (tab-window)))
    (tab-list
      (lambda (ts)
        (k (if here
               (filter (lambda (t) (equal? (plist-get t 'window) here)) ts)
               ts))))))

(define (chrome-group-window &optional g)
  "the browser window group G works in, chosen in M-x browsers with d; G
   defaults to the group of the buffer at hand, else the frame's. A chat
   with no frame of its own works there too, so a group's background tabs
   (a site app's live tab) land in the profile that holds its logins."
  (let ((g (or g (buffer-group (current-buffer)) (frame-group))))
    (and g (group-setting g 'browser-window))))

(define (chrome-group-profile &optional g)
  "the Chrome profile id group G is pinned to, chosen in M-x browsers with
   browsers-pin-profile, or #f; G defaults as in chrome-group-window"
  (let ((g (or g (buffer-group (current-buffer)) (frame-group))))
    (and g (group-setting g 'browser-profile))))

(define (chrome-window-resolve!)
  (or (chrome-group-window)
      (chrome-window)
      (let* ((rows (browser--frames-sync))
             (here (selected-frame))
             (mine (filter (lambda (e) (equal? (plist-get e 'frame) here)) rows)))
        (cond ((pair? mine)
               ;; this frame's own tab: worth remembering
               (let ((w (plist-get (car mine) 'window)))
                 (when w (set-frame-local! 'chrome-window w))
                 w))
              ;; no tab answers for this frame. Another frame's window is the
              ;; wrong answer: a tab opened there lands out of sight, in a
              ;; profile that may not share this one's logins. #f lets the
              ;; bridge route by this frame instead.
              (else #f)))))

;; BACKGROUND opens the tab without taking the reader there. The default is
;; the front, because a tab opened by a key the reader pressed is usually one
;; they want to look at; a tab opened so the editor can work in it is not.
;; The tab this frame is drawn in. Two frames can share one browser window,
;; one per daemon or per chat, so the window alone does not name this frame.
(define (chrome-tab-resolve!)
  (or (frame-local 'chrome-tab)
      (let* ((here (selected-frame))
             (mine (filter (lambda (e) (equal? (plist-get e 'frame) here))
                           (browser--frames-sync))))
        (and (pair? mine)
             (let ((t (plist-get (car mine) 'tab)))
               (when t (set-frame-local! 'chrome-tab t))
               t)))))

(define (tab-open url &optional window background)
  (let ((w (or window (chrome-window-resolve!)))
        (after (and (not window) (chrome-tab-resolve!))))
    (chrome-call "open"
      (append (list 'url url)
              (if w (list 'window w) '())
              ;; beside this frame's own tab: two frames can share a window
              (if after (list 'after after) '())
              ;; its own flag: a #f crosses the wire as null, and the
              ;; extension read `active: null` as active
              (if background (list 'background #t) '()))
      chrome-ignore)))
(define (tab-activate tab) (chrome-call "activate" (list 'tab (browser--tab-id tab)) chrome-ignore))
(define (tab-close tab) (chrome-call "close" (list 'tab (browser--tab-id tab)) chrome-ignore))
(define (tab-release tab) (chrome-call "release" (list 'tab (browser--tab-id tab)) chrome-ignore))

;; the raw protocol, for anything the verbs above don't cover
(define (tab-cdp tab method params k)
  (chrome-call "cdp" (list 'tab (browser--tab-id tab) 'method method 'params params) k))

;; K gets one plist per compos tab the browser holds: window, tab, frame.
;; The extension probes every localhost tab, so a background editor tab
;; still reports its frame.
(define (browser-frames k)
  (chrome-call "frames" '() (lambda (r) (k (plist-get r 'frames)))))

(domain! 'chrome)
(effects! '(read))
(public! 'browser-frames
  "(browser-frames K) — K gets one plist per compos browser tab: window, tab, frame")

(category! 'chrome)
(domain! 'chrome)
(effects! '(read external))
(public! 'tab-list "(tab-list K) — K gets every open browser tab, in every window, as plists: id, title, url, active, window")
(public! 'tab-window "(tab-window) — the browser window this frame belongs to, or #f")
(public! 'tabs-here "(tabs-here K) — K gets only the tabs in this frame's browser window")
(public! 'tab-read "(tab-read TAB K) — K gets the tab's url, title and visible text; TAB is an id or a tab from tab-list")
(public! 'browser-fetch "(browser-fetch URL K) — fetch URL through the browser, cookies and cache included; K gets (TYPE TEXT BASE64) — TEXT for a text body, BASE64 for bytes, never both — or #f")
(public! 'browser-snapshot "(browser-snapshot URL K &optional WAIT) — load URL in a background tab and answer the RENDERED html; sessions and scripts run; WAIT is a CSS selector to wait for before reading; K gets html or #f")
(public! 'browser-connected? "(browser-connected?) — is the compos Chrome extension attached?")
(effects! '(write external execute))
(public! 'tab-eval "(tab-eval TAB CODE K) — run JS in a tab; TAB is an id or a tab from tab-list")
(public! 'tab-cdp "(tab-cdp TAB METHOD PARAMS K) — raw Chrome DevTools Protocol")
(effects! '(write external display))
(public! 'tab-say "(tab-say TAB TEXT) — put a line on that tab's screen")
(public! 'tab-type "(tab-type TAB TEXT) — type into the tab for real (trusted input, via CDP)")
(public! 'tab-click "(tab-click TAB X Y) — a real click at viewport coordinates")
(public! 'tab-open "(tab-open URL &optional WINDOW BACKGROUND) — open a new tab, in this frame's browser window unless WINDOW says otherwise; BACKGROUND opens it without going there")
(public! 'tab-activate "(tab-activate TAB) — bring a tab to the front")
(effects! '(destroy external display))
(public! 'tab-close "(tab-close TAB) — close a tab")

;; every name below stamps itself
(domain! 'chrome)
(effects! '(read))
(public! 'chrome-window "(chrome-window) — the browser window this frame is displayed in, or #f")
(public! 'chrome-here "(chrome-here ARGS) — ARGS routed to the active frame's browser window, unless they already name a tab or window")
(public! 'chrome-window-resolve!
  "(chrome-window-resolve!) — the browser window to work in: the group's own (chrome-group-window), else this frame's, asking the browser when the extension has not said; remembers its own frame's answer")
(public! 'chrome-group-window
  "(chrome-group-window [GROUP]) — the browser window GROUP works in, or #f; GROUP defaults to the group at hand")
(public! 'chrome-group-profile
  "(chrome-group-profile [GROUP]) — the Chrome profile id GROUP is pinned to, or #f; GROUP defaults to the group at hand")

;;; --- the editor page's own DOM ------------------------------------------------
;;; A UI change is verified on the page the user looks at, not on a mock.
;;; These fns address THIS frame's editor tab and answer synchronously, so
;;; an agent reads the value instead of polling a buffer for a callback.

(domain! 'chrome)
(effects! '(read external))

(define (dom--call op args ms)
  (if (browser--tool-allowed?)
      (browser-call-sync op args ms)
      (error
        "browser category denied in code-mode; use compos state, or ask the user to enable M-x browser-mode as a last resort")))

;; the tab that shows this frame; any editor tab when no row names it
(define (dom--editor-tab)
  (let* ((r (dom--call "frames" '() 3000))
         (rows (or (plist-get r 'frames) '()))
         (here (selected-frame))
         (mine (filter (lambda (e) (equal? (plist-get e 'frame) here)) rows)))
    (cond ((pair? mine) (plist-get (car mine) 'tab))
          ((pair? rows) (plist-get (car rows) 'tab))
          (else (error "no editor tab: is the compos extension attached?")))))

(define (dom-eval js)
  (plist-get (dom--call "eval" (list 'tab (dom--editor-tab) 'code js) 5000)
               'value))

;; the probe is pure policy: one string, tested without a browser
(define (dom-measure-js selector limit)
  (string-append
    "(() => { const out = [];"
    " for (const el of document.querySelectorAll(" (json-encode selector) ")) {"
    " if (out.length >= " (number->string limit) ") break;"
    " const r = el.getBoundingClientRect(); const cs = getComputedStyle(el);"
    " out.push({x: Math.round(r.x), y: Math.round(r.y),"
    " w: Math.round(r.width), h: Math.round(r.height),"
    " display: cs.display, font: cs.fontWeight + ' ' + cs.fontSize,"
    " visible: !!(r.width || r.height)}); }"
    " return JSON.stringify(out); })()"))

(define (dom-measure selector &optional limit)
  (let ((v (dom-eval (dom-measure-js selector (or limit 40)))))
    (if (string? v) (json-parse v) '())))

(public! 'dom-measure
  "(dom-measure SELECTOR [LIMIT]) — measure matching elements in this frame's editor tab: rect, display, font, visible; synchronous")
(public! 'dom-eval
  "(dom-eval JS) — run JS in this frame's editor tab and return the value; synchronous")

;; what the user has highlighted: the page selection, or a selection inside a
;; focused input or textarea, which window.getSelection() does not report.
(define dom-selection-js
  (string-append
    "(() => { const s = window.getSelection();"
    " const t = s ? s.toString() : '';"
    " let html = '';"
    " if (s && s.rangeCount && t) { const d = document.createElement('div');"
    " d.appendChild(s.getRangeAt(0).cloneContents()); html = d.innerHTML; }"
    " let field = ''; const a = document.activeElement;"
    " if (a && (a.tagName === 'TEXTAREA' || a.tagName === 'INPUT')"
    " && typeof a.selectionStart === 'number' && a.selectionStart !== a.selectionEnd)"
    " field = String(a.value).slice(a.selectionStart, a.selectionEnd);"
    " const text = t || field;"
    " return JSON.stringify({text: text, html: html, url: location.href,"
    " title: document.title, chars: text.length, empty: !text}); })()"))

(define (dom--selection-parse v)
  (if (string? v)
      (json-parse v)
      (list 'text "" 'html "" 'url "" 'title "" 'chars 0 'empty #t)))

(define (dom-selection)
  (dom--selection-parse (dom-eval dom-selection-js)))

(define (dom-selection-text)
  (plist-get (dom-selection) 'text))

(define (tab-selection tab k)
  (tab-eval tab dom-selection-js (lambda (v) (k (dom--selection-parse v)))))

(public! 'dom-selection
  "(dom-selection) — what the user has highlighted in this frame's editor tab: text, html, url, title, chars, empty; synchronous")
(public! 'dom-selection-text
  "(dom-selection-text) — just the highlighted text in this frame's editor tab, \"\" when nothing is selected")
(public! 'tab-selection
  "(tab-selection TAB K) — what the user has highlighted in TAB; K gets text, html, url, title, chars, empty")
