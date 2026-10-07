;;; linkedin.scm --- LinkedIn Recruiter as an app: projects and messages.
;;;
;;; Recruiter is a console. It draws its projects inside a frame holding a
;;; global nav, a filter rail, two message menus and a star button per row,
;;; and it answers a plain fetch with a script shell that says none of it.
;;; So the reading is taken from a real background tab, and the stylesheet
;;; web/parsers/linkedin-recruiter.xsl cuts it down to what a project is:
;;; its name, its page, the day it was created, and its pipeline.
;;;
;;; Nothing here parses HTML. The site is registered in *web--sites* with
;;; RENDER? #t, so (browse URL) runs the stylesheet and hands this app
;;; markdown -- one link line per project, one meta line under it. That is
;;; the whole contract between the page and the listing.
;;;
;;; The listing has two tabs over the one buffer, projects and messages,
;;; and each tab reads its own page the first time it is entered. The
;;; messages reading cannot come from (browse): a snapshot answers as
;;; soon as the document is there, and the inbox is still drawing ghost
;;; loaders then, so the threads would read as an empty page every time.
;;; So the inbox is captured from a tab this app drives itself -- open,
;;; wait for the cards, take the thread column, close -- and only then
;;; handed to web/parsers/linkedin-inbox.xsl, the same xsltproc-then-pandoc
;;; reading the registry would have run. The stylesheet is still where the
;;; page is read; only the waiting is ours.
;;;
;;; The listing and every project page are one app, named by one app id.
;;; They own no group: they open in the group you were in, and that group
;;; saves the three-column layout and gives it back. Opening a project in the real browser is the reader
;;; pressing a button, never a render.

(domain! 'web)
(effects! '(read))


(defcustom 'linkedin-projects-url "https://www.linkedin.com/talent/projects"
  "The Recruiter page the listing is read from."
  'group 'linkedin)

(defcustom 'linkedin-inbox-url "https://www.linkedin.com/talent/inbox"
  "The Recruiter page the messages tab is read from."
  'group 'linkedin)

;; Under this width the listing drops the message snippet and the project id, and gives the room to the name. The app's own layout puts the listing in one of three columns, which is always under it.
(define linkedin-narrow-cols 90)

(defcustom 'linkedin-fetch-tries 40
  "How many times the app looks for the projects page before giving up. Each look is 500ms, and a rendered reading costs a real background tab."
  'group 'linkedin 'type 'number)

(define *linkedin-buffer* "*linkedin*")
(define *linkedin-log* "*linkedin-log*")

;;; --- reading the page ----------------------------------------------------
;;; The stylesheet already chose what a project is, so the parser is two
;;; lines: the link, and the line of meta under it.
;;;
;;;   - [Anthriq Compiler Expert](https://www.linkedin.com/talent/hire/1923656034/overview)
;;;     *Created 1/27/2026, Pipeline: 3 candidates*

(define (li-after s sub) (let ((p (string-split s sub))) (if (pair? (cdr p)) (car (cdr p)) #f)))
(define (li-before s sub) (car (string-split s sub)))
(define (li-has? s sub) (and (string? s) (pair? (cdr (string-split s sub)))))

;; the project id Recruiter puts in its own URL, which is the only stable
;; name a row has: two projects may share a title, never an id
(define (li-id url)
  (let ((a (li-after url "/talent/hire/")))
    (and a (li-before a "/"))))

(define (li--project line)
  (and (string-prefix? "- [" line)
       (let* ((name (li-before (or (li-after line "[") "") "]("))
              (url (li-before (or (li-after line "](") "") ")"))
              (id (and url (li-id url))))
         (and id (not (equal? name ""))
              (list 'id id 'name name 'url url)))))

;; "*Created 1/27/2026, Pipeline: 3 candidates*" -- absent on a project the
;; page drew without it, and the row stands without it
(define (li--with-meta row meta)
  (if (not (li-has? meta "*Created"))
      row
      (let* ((created (li-before (or (li-after meta "*Created ") "") ","))
             (rest (li-after meta "Pipeline: "))
             (count (and rest (string->number (li-before rest " ")))))
        (append row (list 'created created
                          'count (or count 0)
                          'pipeline (if rest (li-before rest "*") ""))))))

(define (li-parse text)
  (let loop ((ls (string-split text "\n")) (acc '()))
    (if (null? ls)
        (reverse acc)
        (let ((row (li--project (car ls))))
          (if row
              (loop (cdr ls)
                    (cons (li--with-meta row (if (null? (cdr ls)) "" (car (cdr ls)))) acc))
              (loop (cdr ls) acc))))))

;;; --- reading the inbox ---------------------------------------------------
;;; A conversation, in the same two lines and a quoted third. The card
;;; carries the WHOLE last message, not a truncation, so a thread is never
;;; opened to fill its page in.
;;;
;;;   - [Arnab chaudhuri](https://www.linkedin.com/talent/inbox/0/main/id/2-ZThk...)
;;;     *Sep 12, Accepted, unread*
;;;
;;;     > Hi Siddharth, Thank you for reaching out ...

;; the conversation urn Recruiter puts in its own URL, which is the only
;; stable name a thread has: two people may share a name, never an urn
(define (li-msg-id url)
  (li-after url "/id/"))

;; the page a thread opens is named after the head of its urn. The tail is
;; the same on every conversation ("_100"); the head is what differs, and
;; twelve characters of it read in a modeline where the whole urn does not.
(define (li-msg-slug id)
  (let ((s (or (li-after id "2-") id)))
    (substring s 0 (min 12 (string-length s)))))

(define (li--conversation line)
  (and (string-prefix? "- [" line)
       (let* ((name (li-before (or (li-after line "[") "") "]("))
              (url (li-before (or (li-after line "](") "") ")"))
              (id (and url (li-msg-id url))))
         (and id (not (equal? name ""))
              (list 'kind 'thread 'id id 'name name 'url url)))))

;; "*Sep 12, Accepted, unread*" -- the day it last moved, then the InMail's
;; reply status when it has one, then the unread badge when it carries one.
;; Only the day is always there.
(define (li--meta-fields meta)
  (map string-trim (string-split (li-before (or (li-after meta "*") "") "*") ",")))

(define (li--thread head meta body)
  (let* ((fs (li--meta-fields meta))
         (unread (if (member "unread" fs) #t #f))
         (rest (filter (lambda (f) (not (equal? f "unread"))) fs))
         (moved (if (pair? rest) (car rest) ""))
         (status (if (and (pair? rest) (pair? (cdr rest))) (car (cdr rest)) "")))
    (append head (list 'moved moved 'status status 'unread unread 'body body))))

(define (li--flush head meta body acc)
  (if head (cons (li--thread head meta body) acc) acc))

(define (li-parse-threads text)
  (let loop ((ls (string-split text "\n")) (acc '())
             (head #f) (meta "") (body ""))
    (if (null? ls)
        (reverse (li--flush head meta body acc))
        (let* ((line (car ls))
               (t (string-trim line))
               (h (li--conversation line)))
          (cond
            (h (loop (cdr ls) (li--flush head meta body acc) h "" ""))
            ((not head) (loop (cdr ls) acc head meta body))
            ((and (equal? meta "") (string-prefix? "*" t))
             (loop (cdr ls) acc head t body))
            ((and (equal? body "") (string-prefix? "> " t))
             (loop (cdr ls) acc head meta (substring t 2 (string-length t))))
            (else (loop (cdr ls) acc head meta body)))))))

;;; --- the app's buffers ---------------------------------------------------

(effects! '(write display))

(define *linkedin-app-id* "linkedin")

(define (linkedin-join-group! buf &optional role)
  (when (and buf (buffer-exists? buf))
    (when (boundp 'app-claim!) (app-claim! buf *linkedin-app-id* (or role 'aux)))
    (when (boundp 'buffer-join-here!) (buffer-join-here! buf)))
  buf)



(define (linkedin-log! line)
  (unless (buffer-exists? *linkedin-log*) (buffer-create *linkedin-log*))
  (buffer-append! *linkedin-log* (string-append line "\n")))

;;; --- fetching ------------------------------------------------------------
;;; (browse URL) fills its buffer off the lane, so the answer is not here
;;; when the call returns. A rendered reading waits for a background tab to
;;; draw the console, which is slow and worth saying so.

(effects! '(read write external))

(define (linkedin--land! buf tries k)
  (let ((text (if (buffer-exists? buf) (buffer-text buf) "")))
    (cond ((li-has? text "# Projects")
           (let ((rows (li-parse text)))
             (buffer-kill! buf)
             (k rows)))
          ((<= tries 0)
           (when (buffer-exists? buf) (buffer-kill! buf))
           (k #f))
          (else
           (debounce! 'linkedin-fetch 500
                      (lambda (_) (linkedin--land! buf (- tries 1) k))
                      #f)))))

(define (linkedin-fetch! k)
  (linkedin--land! (browse linkedin-projects-url) linkedin-fetch-tries k))

;;; --- capturing the inbox -------------------------------------------------
;;; A snapshot answers as soon as the document is there, and the inbox is
;;; still drawing ghost loaders then, so (browse) would read an empty page
;;; every time. This reading drives a tab of its own instead: note the tabs
;;; that were already open, open one more, and ask it every half second
;;; whether the conversation cards have landed.
;;;
;;; That tab is then KEPT. A tab opened and closed on every reading is a
;;; pattern no person makes, and this is the reader's own Recruiter seat
;;; answering; one tab left standing on the inbox is what a recruiter with
;;; Recruiter open looks like. So the id is remembered, every later reading
;;; sends that same tab to the inbox again -- a reload where it still
;;; stands there, the inbox where it has wandered off -- and the tab is
;;; closed only when the reader asks for it, by M-x linkedin-inbox-tab-close.
;;; ONLY a tab the reader closed is forgotten, and only then is a second
;;; one opened: Recruiter walks its own url about while it signs in and
;;; while the reader reads, and a tab forgotten on one of those steps is a
;;; tab too many.
;;;
;;; The capture wraps the column in a document that declares utf-8. The
;;; column does not declare it, and without the declaration xsltproc reads
;;; every em dash in a message as mojibake.

(define *linkedin-capture-js*
  (string-append
    "(function(){"
    "var c=document.querySelector('[data-test-thread-list-column]');"
    "if(!c)return '';"
    "if(!c.querySelector('[data-test-conversation-card-container]'))return '';"
    "return '<html><head><meta charset=utf-8></head><body>'+c.outerHTML+'</body></html>';})()"))

(define (linkedin--tab-ids ts)
  (map (lambda (t) (plist-get t 'id)) ts))

(define (linkedin--inbox-tab? t)
  (string-contains? (or (plist-get t 'url) "") "/talent/inbox"))

;; the tab this app keeps on the inbox, across readings and across tabs
(define *linkedin-inbox-tab* #f)

;; The kept tab, if the reader still has it open at all. Only a CLOSED tab
;; is forgotten. Where it has wandered to is a separate question and not
;; grounds for opening another: Recruiter walks its own url about while it
;; signs in and while the reader reads, and a tab forgotten on one of those
;; steps is a second tab opened -- the churn this whole design avoids.
;; K gets (TAB ON-INBOX?), or #f when the tab is gone.
(define (linkedin--kept-tab! k)
  (tab-list
    (lambda (ts)
      (let ((mine (and *linkedin-inbox-tab*
                       (filter (lambda (t) (equal? (plist-get t 'id) *linkedin-inbox-tab*)) ts))))
        (cond
          ((and mine (pair? mine))
           (k (list *linkedin-inbox-tab* (linkedin--inbox-tab? (car mine)))))
          (else
           ;; the id is only in memory, and the reader outlives it: a
           ;; reload of this package, a restart, a session. A Recruiter
           ;; inbox tab already standing there is the tab this app would
           ;; have opened, so it is adopted rather than doubled.
           (set! *linkedin-inbox-tab* #f)
           (let ((open (filter linkedin--inbox-tab? ts)))
             (cond ((pair? open)
                    (set! *linkedin-inbox-tab* (plist-get (car open) 'id))
                    (k (list *linkedin-inbox-tab* #t)))
                   (else (k #f))))))))))

;; the tab is ours only if it was not there before the open
(define (linkedin--await-tab! known tries k)
  (tab-list
    (lambda (ts)
      (let ((fresh (filter (lambda (t) (and (not (member (plist-get t 'id) known))
                                            (linkedin--inbox-tab? t)))
                           ts)))
        (cond ((pair? fresh)
               (set! *linkedin-inbox-tab* (plist-get (car fresh) 'id))
               (linkedin--settle! *linkedin-inbox-tab* tries k))
              ((<= tries 0) (k #f))
              (else (debounce! 'linkedin-inbox 500
                               (lambda (_) (linkedin--await-tab! known (- tries 1) k))
                               #f)))))))

;; the tab stays open whether the cards land or not: giving up on a reading
;; is not a reason to make the browser churn
(define (linkedin--settle! tab tries k)
  (tab-eval tab *linkedin-capture-js*
    (lambda (html)
      (cond ((and (string? html) (not (equal? html ""))) (k html))
            ((<= tries 0) (k #f))
            (else (debounce! 'linkedin-inbox 500
                             (lambda (_) (linkedin--settle! tab (- tries 1) k))
                             #f))))))

(define (linkedin--open-tab! k)
  (tab-list
    (lambda (before)
      (let ((known (linkedin--tab-ids before)))
        (tab-open linkedin-inbox-url)
        (debounce! 'linkedin-inbox 1200
                   (lambda (_) (linkedin--await-tab! known linkedin-fetch-tries k))
                   #f)))))

;; A reload where the tab still stands on the inbox, and the inbox again
;; where it has wandered off: either way it is one tab going somewhere, the
;; thing a person does, and never a second tab.
(define (linkedin--revisit-tab! tab on-inbox? k)
  (tab-eval tab
    (if on-inbox?
        "location.reload();''"
        (string-append "location.assign('" linkedin-inbox-url "');''"))
    (lambda (_)
      (debounce! 'linkedin-inbox 1200
                 (lambda (_) (linkedin--settle! tab linkedin-fetch-tries k))
                 #f))))

(define (linkedin--capture! k)
  (if (not (browser-connected?))
      (k #f)
      (linkedin--kept-tab!
        (lambda (kept)
          (if kept
              (linkedin--revisit-tab! (car kept) (car (cdr kept)) k)
              (linkedin--open-tab! k))))))

;; the same reading the site registry would have run: the stylesheet, then
;; pandoc. Only the waiting above is ours.
(define (linkedin--inbox-markdown html)
  (let ((file (string-append (compos-home) "/linkedin-inbox.html"))
        (sheet (locate-library "web/parsers/linkedin-inbox.xsl")))
    (write-file! file html)
    (shell-command->string
      (string-append "xsltproc --html " (sh-quote sheet)
                     " " (sh-quote file) " 2>/dev/null"
                     " | pandoc --wrap=none -f html-native_divs-native_spans -t gfm-raw_html")
      (compos-home))))

(define (linkedin-threads-fetch! k)
  (linkedin--capture!
    (lambda (html)
      (k (and html (li-parse-threads (linkedin--inbox-markdown html)))))))

;; the one way the kept tab goes away, and it is the reader's hand
(define-command "linkedin-inbox-tab-close" "Close the browser tab this app keeps on the Recruiter inbox"
  (lambda ()
    (linkedin--kept-tab!
      (lambda (kept)
        (cond (kept (tab-close (car kept))
                    (set! *linkedin-inbox-tab* #f)
                    (message "Closed the Recruiter inbox tab"))
              (else (message "No Recruiter inbox tab is open")))))))

;;; --- the project page ----------------------------------------------------
;;; One buffer per project, named after its id, so the pages opened from
;;; one listing are siblings and the detail walk flips between them. It
;;; renders as HTML: the preview iframe runs no scripts, so every button is
;;; a compos: link the editor hands back to Scheme.

(define linkedin-detail-css "<style>
:root{--bg:#f7f9fb;--fg:#17202a;--dim:#5d6b7a;--line:#dde4ec;--accent:#0a66c2;--chip:#e9eef5}
@media (prefers-color-scheme:dark){:root{--bg:#14181d;--fg:#e8edf3;--dim:#93a1b0;--line:#2c333b;--accent:#6cb0f5;--chip:#222930}}
*{box-sizing:border-box}
html{font-size:clamp(13px,0.62vw,40px)}
body{margin:0;background:var(--bg);color:var(--fg);font:1rem/1.5 -apple-system,BlinkMacSystemFont,Inter,system-ui,sans-serif}
.wrap{padding:1.2rem;max-width:48rem}
h1{font-size:1.5rem;line-height:1.25;margin:0 0 .5rem;letter-spacing:-.01em}
.count{font-size:2.1rem;font-weight:650;letter-spacing:-.02em;font-variant-numeric:tabular-nums}
.count small{font-size:.85rem;font-weight:400;color:var(--dim);margin-left:.5rem}
.chips{display:flex;gap:.4rem;flex-wrap:wrap;margin:.8rem 0 0}
.chip{background:var(--chip);border-radius:999px;padding:.2rem .7rem;font-size:.8rem;color:var(--dim);white-space:nowrap}
.act{margin:1.1rem 0 0;display:flex;gap:.6rem;flex-wrap:wrap}
.btn{display:inline-block;background:var(--accent);color:var(--bg);font-size:.9rem;font-weight:600;padding:.5rem 1.15rem;border-radius:999px;text-decoration:none;border:1px solid var(--accent)}
.btn.ghost{background:transparent;color:var(--accent)}
table{border-collapse:collapse;margin:1.2rem 0 0;width:100%;font-size:.87rem}
td{padding:.42rem 0;border-top:1px solid var(--line);vertical-align:top}
td:first-child{color:var(--dim);width:40%;white-space:nowrap}
a{color:var(--accent);text-decoration:none}
.msg{margin:1.2rem 0 0;padding:.9rem 1.1rem;background:var(--chip);border-radius:.6rem;border-left:3px solid var(--accent);font-size:.95rem;line-height:1.6;white-space:pre-wrap}
.msg h2{font-size:.78rem;font-weight:600;letter-spacing:.06em;text-transform:uppercase;color:var(--dim);margin:0 0 .5rem}
.chip.alert{background:var(--accent);color:var(--bg)}
</style>")

(define (li--esc s)
  (string-replace (string-replace (string-replace (or s "") "&" "&amp;") "<" "&lt;") ">" "&gt;"))

(define (li-thread? row) (equal? (plist-get row 'kind) 'thread))

(define (li-clip s n) (if (> (string-length s) n) (string-trim (substring s 0 n)) s))

;; the page is named after what it shows, so the buffer reads as its title
(define (li-page-title row)
  (let ((name (li-clip (string-trim (string-replace (or (plist-get row 'name) "") "*" "")) 48)))
    (if (equal? name "") (string-append "linkedin:" (li-key row)) name)))

;; two rows can carry the same title; the second one keeps its key, so no
;; page is ever shown under another row's name
(define (linkedin-detail-buffer row)
  (let* ((base (string-append "*" (li-page-title row) "*"))
         (mine (li-key row))
         (held (let ((r (and (buffer-exists? base) (buffer-local base 'linkedin-row))))
                 (and r (li-key r)))))
    (if (or (not held) (equal? held mine))
        base
        (string-append "*" (li-page-title row) " " mine "*"))))

;; the buttons route by the row's KEY, never its id: a conversation urn is
;; base64, and a preview link splits on the slash base64 may contain
(define (li-key row)
  (if (li-thread? row) (li-msg-slug (plist-get row 'id)) (plist-get row 'id)))

(define (linkedin--buttons row)
  (string-append
   "<div class='act'>"
   "<a class='btn' href='compos:linkedin-open/" (li-key row) "'>Open in Recruiter</a>"
   "<a class='btn ghost' href='compos:linkedin-copy/" (li-key row) "'>Copy link</a>"
   "</div>"))

(define (linkedin-project-html row)
  (let ((name (li--esc (plist-get row 'name)))
        (id (plist-get row 'id))
        (url (plist-get row 'url))
        (created (plist-get row 'created))
        (count (or (plist-get row 'count) 0)))
    (string-append
     "<div class='wrap'><h1>" name "</h1>"
     "<div class='count'>" (number->string count)
     "<small>" (if (= count 1) "candidate in the pipeline" "candidates in the pipeline") "</small></div>"
     "<div class='chips'>"
     (if created (string-append "<span class='chip'>created " created "</span>") "")
     "<span class='chip'>project " id "</span>"
     "</div>"
     (linkedin--buttons row)
     "<table>"
     "<tr><td>Pipeline</td><td>" (number->string count) "</td></tr>"
     (if created (string-append "<tr><td>Created</td><td>" created "</td></tr>") "")
     "<tr><td>Project id</td><td>" id "</td></tr>"
     "<tr><td>Link</td><td><a href='" url "'>" url "</a></td></tr>"
     "</table></div>")))

;; The card gave the whole last message, so the page is the message: who
;; it is with, where the InMail stands, and what they actually wrote.
(define (linkedin-thread-html row)
  (let ((name (li--esc (plist-get row 'name)))
        (url (plist-get row 'url))
        (moved (or (plist-get row 'moved) ""))
        (status (or (plist-get row 'status) ""))
        (body (plist-get row 'body)))
    (string-append
     "<div class='wrap'><h1>" name "</h1>"
     "<div class='chips'>"
     (if (equal? moved "") "" (string-append "<span class='chip'>" moved "</span>"))
     (if (equal? status "") "" (string-append "<span class='chip'>" (li--esc status) "</span>"))
     (if (plist-get row 'unread) "<span class='chip alert'>unread</span>" "")
     "</div>"
     (linkedin--buttons row)
     (if (or (not body) (equal? body ""))
         ""
         (string-append "<div class='msg'><h2>Last message</h2>" (li--esc body) "</div>"))
     "<table>"
     (if (equal? moved "") "" (string-append "<tr><td>Last activity</td><td>" moved "</td></tr>"))
     (if (equal? status "") "" (string-append "<tr><td>InMail</td><td>" (li--esc status) "</td></tr>"))
     "<tr><td>Read</td><td>" (if (plist-get row 'unread) "unread" "read") "</td></tr>"
     "<tr><td>Link</td><td><a href='" url "'>the thread in Recruiter</a></td></tr>"
     "</table></div>")))

(define (linkedin-detail-html row)
  (string-append linkedin-detail-css
                 (if (li-thread? row) (linkedin-thread-html row) (linkedin-project-html row))))

(define (linkedin-render-detail! buf row)
  (unless (buffer-exists? buf) (buffer-create buf))
  (buffer-set-read-only! buf #f)
  (let ((old (buffer-text buf)) (new (linkedin-detail-html row)))
    (if (> (string-length old) 0)
        (buffer-replace! buf old new)
        (buffer-append! buf new)))
  (buffer-set-local! buf 'linkedin-row row)
  (buffer-set-local! buf 'linkedin-title (li-page-title row))
  (unless (buffer-derived-mode? buf "linkedin-detail-mode")
    (with-current-buffer buf (lambda () (set-mode! "linkedin-detail-mode"))))
  (buffer-set-local! buf 'preview-renderer "html")
  (enable-minor-mode! buf "preview-mode")
  (preview-heal! buf)
  (buffer-set-read-only! buf #t)
  buf)

(define (linkedin-show-detail! row)
  (when row
    (let ((buf (linkedin-render-detail! (linkedin-detail-buffer row) row)))
      (linkedin-join-group! buf 'detail)
      (display-buffer-detail! buf *linkedin-buffer*)
      buf)))

;;; --- actions, on the listing and on the page -----------------------------
;;; The same verb under the same key in both places: the listing reads the
;;; row at point, the page keeps its own.

;; a key, from a row or from a button, over both tabs: a page opened from
;; the projects tab still answers o and w after the reader moves to messages
(define (linkedin-row-by-id id)
  (let loop ((rs (append (or (buffer-local *linkedin-buffer* 'linkedin-rows) '())
                         (or (buffer-local *linkedin-buffer* 'linkedin-threads) '()))))
    (cond ((null? rs) #f)
          ((equal? (li-key (car rs)) id) (car rs))
          ((equal? (plist-get (car rs) 'id) id) (car rs))
          (else (loop (cdr rs))))))

(define (linkedin-row-here)
  (or (buffer-local (current-buffer) 'linkedin-row)
      (list-current *linkedin-buffer*)))

(define (linkedin-open-external! id)
  (let ((row (linkedin-row-by-id id)))
    (cond ((not row) (message "No such project"))
          ((not (boundp 'tab-open)) (message "No browser is connected"))
          (else (tab-open (plist-get row 'url))
                (message (string-append "Opened " (plist-get row 'name) " in the browser"))))))

(define (linkedin-copy-link! id)
  (let ((row (linkedin-row-by-id id)))
    (when row
      (kill-new (plist-get row 'url))
      (message (string-append "Copied " (plist-get row 'url))))))

(add-hook! (list 'preview-link "linkedin-open") (lambda (id) (linkedin-open-external! id)))
(add-hook! (list 'preview-link "linkedin-copy") (lambda (id) (linkedin-copy-link! id)))

(define-command "linkedin-detail" "Show the project on this row beside the listing"
  (lambda () (linkedin-show-detail! (linkedin-row-here))))

(define-command "linkedin-open" "Open this project in the real Recruiter"
  (lambda () (let ((r (linkedin-row-here))) (when r (linkedin-open-external! (plist-get r 'id))))))

(define-command "linkedin-copy-link" "Copy this project's link"
  (lambda () (let ((r (linkedin-row-here))) (when r (linkedin-copy-link! (plist-get r 'id))))))

;;; --- the listing ---------------------------------------------------------

;;; --- the two tabs --------------------------------------------------------
;;; One listing buffer, two readings over it. Each tab owns its rows, its
;;; columns and its page, and each reads its page the first time it is
;;; entered -- a reader who only wants projects never pays for the inbox.

(define *linkedin-tabs* (list 'projects 'messages))

(define (linkedin-tab buf)
  (or (buffer-local buf 'linkedin-tab) 'projects))

(define (linkedin-messages? buf) (equal? (linkedin-tab buf) 'messages))

(define (linkedin--rows buf)
  (or (buffer-local buf (if (linkedin-messages? buf) 'linkedin-threads 'linkedin-rows))
      '()))

;; the tab bar, drawn in the listing's meta line: the reading each tab
;; holds, and the keys that move between them
(define (linkedin--tab-bar buf)
  (let ((at (linkedin-tab buf)))
    (string-append
      (string-join
        (map (lambda (tab)
               (let* ((rs (or (buffer-local buf (if (equal? tab 'messages)
                                                    'linkedin-threads
                                                    'linkedin-rows))
                              '()))
                      (cell (string-append (symbol->string tab)
                                           (if (null? rs)
                                               ""
                                               (string-append " " (number->string (length rs)))))))
                 (if (equal? tab at)
                     (string-append "[" cell "]")
                     (string-append " " cell " "))))
             *linkedin-tabs*)
        " ")
      "   <left>/<right> switch tab")))

(define (linkedin--project-cells buf row)
  (list (plist-get row 'name)
        (list (or (plist-get row 'created) "") "dim")
        (number->string (or (plist-get row 'count) 0))
        (list (plist-get row 'id) "dim")))

;; the snippet is the whole last message on one line, and the column shows
;; as much of it as the width leaves
(define (linkedin--thread-cells buf row)
  (list (list (plist-get row 'name) (if (plist-get row 'unread) "bold" ""))
        (list (or (plist-get row 'moved) "") "dim")
        (list (or (plist-get row 'status) "") "dim")
        (if (plist-get row 'unread) "new" "")
        (list (or (plist-get row 'body) "") "dim")))

(define (linkedin--cells buf row)
  (if (li-thread? row)
      (linkedin--thread-cells buf row)
      (linkedin--project-cells buf row)))

;; The app's own layout gives the listing a third of the frame, and a
;; message elided to "Hi S...ian" says nothing. Under the width that can
;; hold it, the snippet and the id come off and the name takes the room:
;; the page beside the listing is already showing the whole message.
(define (linkedin--columns buf)
  (if (linkedin-messages? buf)
      (list (list "who" 26) (list "when" 8) (list "inmail" 10)
            (list "" 4) (list "last message" #f))
      (list (list "project" 44) (list "created" 12)
            (list "pipeline" 9) (list "id" 12))))

(define (linkedin--narrow-columns buf)
  (if (linkedin-messages? buf)
      (list (list "who" #f) (list "when" 8) (list "" 4))
      (list (list "project" #f) (list "created" 12) (list "pipeline" 9))))

(define (linkedin--narrow-cells buf row)
  (if (li-thread? row)
      (list (list (plist-get row 'name) (if (plist-get row 'unread) "bold" ""))
            (list (or (plist-get row 'moved) "") "dim")
            (if (plist-get row 'unread) "new" ""))
      (list (plist-get row 'name)
            (list (or (plist-get row 'created) "") "dim")
            (number->string (or (plist-get row 'count) 0)))))

;;; --- the index, as cards -------------------------------------------------
;;; The listing also projects itself semantically: one record per row with
;;; field roles, which the shared list CSS lays out as a card -- a name,
;;; the count on its right, the detail under it. The app's own polish
;;; rides on the blocks as inline style, so nothing outside this file
;;; changes colour, and every value is a theme variable so the cards
;;; follow the theme rather than fighting it.

(define li-css-title "padding:.7em .9em .1em;font-weight:700;font-size:1.06em;letter-spacing:-.01em")
(define li-css-note "padding:0 .9em .55em;color:var(--dim-fg,#8a857a);font-size:.78em")
(define li-css-rule "border-bottom:1px solid var(--border-bg,#e2ded4);margin:0 .5em")
(define li-css-name "font-weight:600")
(define li-css-count "color:var(--accent-fg,#0a66c2);font-weight:600;font-variant-numeric:tabular-nums")
(define li-css-sub "font-size:.84em")
(define li-css-chip "border-radius:999px;padding:.05em .6em;border:1px solid var(--border-bg,#d8d4cb);font-size:.76em")
(define li-css-snippet "font-size:.85em;opacity:.85;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden")

;; one block: a tag, the field role the list lays it out by, and the style
(define (li--block tag text field css)
  (list 'tag tag
        'attrs (append (if field (list (list "field" field)) '())
                       (if css (list (list "style" css)) '()))
        'text (if (number? text) (number->string text) (or text ""))))

;; a tab, as ui/tabs wants one: the id a click comes back under, the
;; label with what that reading holds, and whether you are on it. The
;; pill shape and its colours are the component's, so the tab bar here
;; looks like every other tab bar in the editor.
(define (li--tab-entry buf tab at)
  (let* ((rs (or (buffer-local buf (if (equal? tab 'messages) 'linkedin-threads 'linkedin-rows))
                 '()))
         (name (symbol->string tab))
         (label (if (null? rs)
                    name
                    (string-append name " " (number->string (length rs))))))
    (list (string-append "linkedin-tab-" name) label (equal? tab at))))

;; The head the cards stand under: the app, its tabs, and the keys. The
;; text head says the same thing in one line of chips; this one says it in
;; the shape a reader already knows a tab bar by.
(define (linkedin--composml-head buf head)
  (let* ((at (linkedin-tab buf))
         (q (list-query buf))
         (note (if (equal? q "")
                   "RET page · o recruiter · w copy · ←/→ tab · g refresh · q quit"
                   (string-append "matching \"" q "\" · \\ widens"))))
    (list
      (li--block "div" "LinkedIn Recruiter" #f li-css-title)
      (component 'ui/tabs
        (list 'class "linkedin-tabs"
              'tabs (map (lambda (t) (li--tab-entry buf t at)) *linkedin-tabs*)))
      (li--block "div" note #f li-css-note)
      (li--block "div" "" #f li-css-rule))))

;; a project card: the name, the pipeline count on its right, and the day
;; it was created with its id under both
(define (linkedin--project-block buf row)
  (list 'tag "div"
        'children
        (list (li--block "span" (plist-get row 'name) "primary" li-css-name)
              (li--block "span" (or (plist-get row 'count) 0) "count" li-css-count)
              (li--block "span"
                         (string-append "created " (or (plist-get row 'created) "—")
                                        "   ·   " (plist-get row 'id))
                         "secondary" li-css-sub))))

;; a conversation card: who, when, the InMail status as a chip, and the
;; last message clamped to two lines. The unread attribute is the shared
;; list's own: it lights the left edge and thickens the name.
(define (linkedin--thread-block buf row)
  (let ((status (or (plist-get row 'status) "")))
    (list 'tag "div"
          'attrs (list (list "unread" (if (plist-get row 'unread) "true" "false")))
          'children
          (append
            (list (li--block "span" (plist-get row 'name) "primary" li-css-name)
                  (li--block "span" (or (plist-get row 'moved) "") "trailing" li-css-sub))
            (if (equal? status "")
                '()
                (list (list 'tag "span" 'attrs '(("field" "tags"))
                            'children (list (li--block "span" status #f li-css-chip)))))
            (list (li--block "span" (or (plist-get row 'body) "") "detail" li-css-snippet))))))

(define (linkedin--composml buf row)
  (if (li-thread? row)
      (linkedin--thread-block buf row)
      (linkedin--project-block buf row)))

(define *linkedin-doc*
  (string-append
    "LinkedIn Recruiter, in two tabs over one listing: the open projects, "
    "and the inbox. Both are read from a rendered background tab and cut "
    "down by an XSLT stylesheet. Each row is a card: the name, its count "
    "or its day on the right, and under both what it is -- when it was "
    "created, or the whole last message. An unread thread lights its "
    "left edge. <left> and "
    "<right> change the tab, and so does clicking one in the tab bar, and "
    "a tab reads its page the first time you "
    "enter it. Moving shows that row as a page beside the listing, and the "
    "detail walk flips through the pages you have opened. RET shows it "
    "again, o opens it in the real Recruiter, w copies its link, g reads "
    "this tab's page again, q quits. The messages tab keeps one browser "
    "tab standing on the inbox and reloads it rather than opening a new "
    "one each time; M-x linkedin-inbox-tab-close puts it away."))

(define-list-mode! "linkedin-mode"
  (list 'doc *linkedin-doc*
        'buffer *linkedin-buffer*
        'transient #f
        'noun "row"
        'rows linkedin--rows
        'key (lambda (buf row) (li-key row))
        'columns linkedin--columns
        'cells linkedin--cells
        'layouts (list (list 'name 'narrow
                             'max-cols (lambda (buf) (- linkedin-narrow-cols 1))
                             'columns linkedin--narrow-columns
                             'cells linkedin--narrow-cells)
                       (list 'name 'wide
                             'default #t
                             'columns linkedin--columns
                             'cells linkedin--cells))
        'title (lambda (buf) "LinkedIn Recruiter")
        'meta linkedin--tab-bar
        'collection "c-list"
        'composml linkedin--composml
        'composml-head linkedin--composml-head
        'total (lambda (buf) (length (linkedin--rows buf)))
        'footer (lambda (buf) (list (list "RET" "page") (list "o" "recruiter")
                                    (list "w" "copy") (list "<left>/<right>" "tab")
                                    (list "g" "refresh") (list "q" "quit")))
        'preview (lambda (buf row) (linkedin-show-detail! row))
        'keys (list (list "RET" "linkedin-detail")
                    (list "o" "linkedin-open")
                    (list "w" "linkedin-copy-link")
                    (list "<right>" "linkedin-tab-next")
                    (list "<left>" "linkedin-tab-prev")
                    (list "g" "linkedin-refresh")
                    (list "q" "quit-window"))))

;;; --- the page's mode -----------------------------------------------------
;;; detail-mode arrives with the buffer (display-buffer-detail!) and brings
;;; the walk keys. This mode adds the app's own verbs, so the page answers
;;; the same keys as the row it came from.

(define-mode "linkedin-detail-mode"
  (lambda () (buffer-set-read-only! (current-buffer) #t)))
(mode-parent! "linkedin-detail-mode" "special-mode")
(mode-doc! "linkedin-detail-mode"
  "One row of the LinkedIn listing as its own page: a Recruiter project, or a conversation and the whole last message in it. o opens it in the real Recruiter, w copies its link, g reads the listing again, q puts it away. The detail walk reaches the other pages opened from this listing, and M-RET keeps this one so the next row opens a fresh page.")
(mode-keys! "linkedin-detail-mode"
  (list (list "o" "linkedin-open")
        (list "w" "linkedin-copy-link")
        (list "g" "linkedin-refresh")
        (list "q" "quit-window")))

;; a kept page takes the project's or the person's name, not a number
(detail-name! "linkedin-detail-mode"
  (lambda (buf) (string-append "*" (or (buffer-local buf 'linkedin-title) "linkedin") "*")))

;; the listing and every page it opens wear the LinkedIn mark
(mode-icon! "linkedin-mode" "")
(mode-icon! "linkedin-detail-mode" "")


;;; --- the layout ----------------------------------------------------------
;;; Three panes -- the group's chat, the listing, the page -- handed to the
;;; tiler as columns, so the app is chat | listing | detail.

(define (linkedin-current-detail)
  (let ((row (list-current *linkedin-buffer*)))
    (and row (linkedin-detail-buffer row))))

;; The chat pane is whichever of the group's chats the reader already has
;; open, and only failing that the group's own. Laying the layout again on
;; every tab switch must not swap the chat someone is typing in.
(define (linkedin--chat-pane)
  (let* ((id (frame-group))
         (members (if (and id (boundp 'group-buffers)) (group-buffers id) '()))
         (shown (filter (lambda (b) (and (chat-buffer? b) (window-showing b))) members)))
    (if (pair? shown)
        (car shown)
        (and id (boundp 'group-chat) (group-chat id)))))

(define (linkedin-layout!)
  (let* ((chat (linkedin--chat-pane))
         ;; the index is the app: it stands leftmost, the page it opened
         ;; beside it, and the group's chat last. Three panes, always in
         ;; that order, whatever order they were displayed in.
         (panes (filter (lambda (b) (and b (buffer-exists? b)))
                        (list *linkedin-buffer* (linkedin-current-detail) chat))))
    (when (pair? (cdr panes)) (tile-windows! 'columns panes))
    panes))

;;; --- opening it ----------------------------------------------------------

;; Every reading ends the same way: the mode, the rows, the page beside
;; them, and the three columns with the listing leftmost. A tab that opens
;; a page under a new name would otherwise push the listing out of the
;; frame, so the layout is laid again here and not only on the first open.
(define (linkedin--ready! first?)
  (unless (buffer-derived-mode? *linkedin-buffer* "linkedin-mode")
    (with-current-buffer *linkedin-buffer* (lambda () (set-mode! "linkedin-mode"))))
  (list-refresh! *linkedin-buffer*)
  (when first? (switch-to-buffer! *linkedin-buffer*))
  (linkedin-show-detail! (list-current *linkedin-buffer*))
  (linkedin-layout!)
  (when first?
    (let ((id (frame-group))) (when id (group-layout-save! id)))))

(define (linkedin-open! first?)
  (unless (buffer-exists? *linkedin-buffer*) (buffer-create *linkedin-buffer*))
  (linkedin-join-group! *linkedin-buffer* 'home)
  (buffer-set-local! *linkedin-buffer* 'linkedin-tab 'projects)
  (message "LinkedIn Recruiter: reading your projects...")
  (linkedin-fetch!
    (lambda (rows)
      (cond
        ((not rows)
         (linkedin-log! "the projects page did not answer")
         (message "Recruiter did not answer -- try again"))
        ((null? rows)
         (linkedin-log! "the projects page answered with no projects")
         (message "No projects on the Recruiter page -- are you signed in?"))
        (else
         (buffer-set-local! *linkedin-buffer* 'linkedin-rows rows)
         (linkedin--ready! first?)
         (message (string-append (number->string (length rows)) " projects")))))))

;; The inbox costs a tab of its own, so it is read when the reader asks
;; for it -- entering the tab the first time, or g on the tab after that.
(define (linkedin-threads-open!)
  (unless (buffer-exists? *linkedin-buffer*) (buffer-create *linkedin-buffer*))
  (linkedin-join-group! *linkedin-buffer* 'home)
  (message "LinkedIn Recruiter: reading your inbox, this needs a tab...")
  (linkedin-threads-fetch!
    (lambda (rows)
      (cond
        ((not rows)
         (linkedin-log! "the inbox did not answer")
         (message "The Recruiter inbox did not answer -- try again"))
        ((null? rows)
         (linkedin-log! "the inbox answered with no conversations")
         (message "No conversations in the Recruiter inbox"))
        (else
         (buffer-set-local! *linkedin-buffer* 'linkedin-threads rows)
         (linkedin--ready! #f)
         (message (string-append (number->string (length rows))
                                 (if (= (length rows) 1) " conversation" " conversations"))))))))

;;; --- moving between the tabs ---------------------------------------------

(define (linkedin--tab-index buf)
  (let loop ((i 0) (ts *linkedin-tabs*))
    (cond ((null? ts) 0)
          ((equal? (car ts) (linkedin-tab buf)) i)
          (else (loop (+ i 1) (cdr ts))))))

(define (linkedin-set-tab! tab)
  (let ((buf *linkedin-buffer*))
    (buffer-set-local! buf 'linkedin-tab tab)
    (list-refresh! buf)
    (if (and (equal? tab 'messages)
             (null? (or (buffer-local buf 'linkedin-threads) '())))
        (linkedin-threads-open!)
        (begin (linkedin-show-detail! (list-current buf))
               (linkedin-layout!)))
    tab))

(define (linkedin--step-tab! d)
  (let ((n (length *linkedin-tabs*)))
    (linkedin-set-tab! (nth (modulo (+ (linkedin--tab-index *linkedin-buffer*) d n) n)
                            *linkedin-tabs*))))

;; A tab in the bar is clickable, and a click is the same move as
;; <left>/<right>: the component hands back the id li--tab-entry gave it,
;; and that id is the tab's own name. Anything else on the listing --
;; a row -- is not ours, so it falls through to the list's own handler.
(add-hook! (list 'block-click 'linkedin)
  (lambda (buf id)
    (and (equal? buf *linkedin-buffer*)
         (string-prefix? "linkedin-tab-" id)
         (let ((tab (string->symbol (substring id 13 (string-length id)))))
           (and (member tab *linkedin-tabs*)
                (begin (linkedin-set-tab! tab) #t))))))

(define-command "linkedin-tab-next" "Show the next LinkedIn tab"
  (lambda () (linkedin--step-tab! 1)))

(define-command "linkedin-tab-prev" "Show the previous LinkedIn tab"
  (lambda () (linkedin--step-tab! -1)))

;;;###autoload
(define-command "linkedin-messages" "Show the Recruiter inbox in the listing"
  (lambda ()
    (if (buffer-exists? *linkedin-buffer*)
        (linkedin-set-tab! 'messages)
        (begin (buffer-create *linkedin-buffer*)
               (buffer-set-local! *linkedin-buffer* 'linkedin-tab 'messages)
               (linkedin-threads-open!)))))

;;;###autoload
(define-command "linkedin" "Open the LinkedIn Recruiter app"
  (lambda () (linkedin-open! #t)))

(define-command "linkedin-refresh" "Read this tab's page again"
  (lambda ()
    (if (and (buffer-exists? *linkedin-buffer*) (linkedin-messages? *linkedin-buffer*))
        (linkedin-threads-open!)
        (linkedin-open! #f))))

;;; --- the catalog ---------------------------------------------------------

(public! 'linkedin-open!
  "(linkedin-open! FIRST?) — read the Recruiter projects page and fill the listing; FIRST? also lays out the panes")
(public! 'li-parse
  "(li-parse TEXT) — the projects reading, as project rows")
(public! 'li-parse-threads
  "(li-parse-threads TEXT) — the inbox reading, as conversation rows")
(public! 'linkedin-threads-open!
  "(linkedin-threads-open!) — capture the Recruiter inbox from the kept tab and fill the messages tab")
(public! 'linkedin-set-tab!
  "(linkedin-set-tab! TAB) — show 'projects or 'messages in the listing, reading the page if that tab has none")
(public! 'li-id
  "(li-id URL) — the project id in a Recruiter project URL, or #f")
(public! 'linkedin-show-detail!
  "(linkedin-show-detail! ROW) — render ROW as its own page beside the listing")
(public! 'linkedin-open-external!
  "(linkedin-open-external! ID) — open the project in the reader's real browser")

(catalog-meta! 'function "linkedin-open!" 'domain 'web 'effects '(read write external display))
(catalog-meta! 'function "li-parse" 'domain 'web 'effects '(pure))
(catalog-meta! 'function "li-parse-threads" 'domain 'web 'effects '(pure))
(catalog-meta! 'function "linkedin-threads-open!" 'domain 'web 'effects '(read write external display))
(catalog-meta! 'function "linkedin-set-tab!" 'domain 'web 'effects '(read write external display))
(catalog-meta! 'function "li-id" 'domain 'web 'effects '(pure))
(catalog-meta! 'function "linkedin-show-detail!" 'domain 'web 'effects '(write display))
(catalog-meta! 'function "linkedin-open-external!" 'domain 'web 'effects '(write external))
