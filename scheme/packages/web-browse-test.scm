;;; web-browse-test.scm --- packages/web.scm, pages read as text, offline.
;;;
;;; The fetch seam is replaced, so no test reaches the network. Links
;;; render as labels, a fresh page joins the group of the window that opened it,
;;; and the wake serves the copy it holds.
;;;
;;; Five tests stay in ExUnit. Three press TAB, RET and the M-arrows,
;;; which is the path the GUI uses. One reads the minibuffer the prompt
;;; opened. One waits for an xsltproc conversion to answer, and Scheme has
;;; no way to poll.

(domain! 'testing)
(effects! '(read))

(define (t--web-pages url)
  (if (string-contains? url "second")
      "# Second page\n\nback home: [home](https://site.test/)\n"
      (string-append
        "# Front page\n\n"
        "Read the [second page](/second.html) or the "
        "[docs](docs/intro.html) or leave via "
        "[elsewhere](https://other.test/x).\n")))

(effects! '(write))

;; The fetch seam and the visited file are both global, and the visited
;; file is the person's own reading history. Every test puts back what it
;; found.
(define (t--web-with-fetch fetch thunk)
  (let ((saved-fetch *web-fetch*)
        (saved-visited (or (read-file *web-visited-file*) ""))
        ;; browse displays its tab, so the window moves. In the live
        ;; editor that is the person's own window.
        (here (current-buffer)))
    (set! *web-fetch* fetch)
    (let ((out (thunk)))
      (set! *web-fetch* saved-fetch)
      (write-file! *web-visited-file* saved-visited)
      (when (buffer-known? here) (switch-to-buffer! here))
      out)))

(define (t--web-kill-tabs!)
  (for-each (lambda (b)
              (when (equal? (buffer-local b 'mode-name) "browse-mode")
                (buffer-kill! b)))
            (buffer-list)))

;; A fresh tab's group is decided when it opens: the group the frame
;; stands in, and the opening buffer's group only when the frame has none.
;; Stand the frame in GROUP for the thunk and give the frame its
;; own group back after; a throwaway group created here is removed when
;; the test ends. The frame is PINNED to GROUP too: a window change
;; recalculates the frame's group from what it shows, and only a pin
;; survives a visit to a buffer outside the group.
;; GROUP is a name, or #f for a groupless frame.
(define (t--web-pin-group! group thunk)
  (let* ((saved-current (frame-local 'current-group))
         (saved-pinned (frame-local 'pinned-group))
         (existing (and group (group-resolve-id group)))
         (id (or existing (and group (group-record-create! group)))))
    (set-frame-local! 'current-group id)
    (set-frame-local! 'pinned-group id)
    (let ((out (thunk)))
      (set-frame-local! 'current-group saved-current)
      (set-frame-local! 'pinned-group saved-pinned)
      (when (and id (not existing)) (group-record-delete! id))
      out)))

(deftest 'a-page-opens-in-the-frame-group-when-the-window-has-none-and-cycles-views
  "a page from an ungrouped window falls back to the frame group and cycles the views"
  (lambda ()
    ;; the type of a rendered page is a setting, so give it back
    (let ((before (preview-typography)))
      (preview-typography! "mono")
      (t--web-with-fetch
        (lambda (url want k) (k (list want (t--web-pages url) #f)))
        (lambda ()
          (t--web-pin-group! "zzweb-home"
            (lambda ()
              (let ((buf (browse "https://site.test/index.html")))
                (check-equal! (group-name (buffer-group buf)) "zzweb-home"
                              "the page belongs to the current group")
                (check-equal! (group-name (frame-group)) "zzweb-home"
                              "the frame stays in the current group")
                (check-equal! (buffer-local buf 'browse-view) "mono"
                              "browse opens in the type rendered pages use")
                (check-true! (minor-mode-on? buf "preview-mode")
                             "the default renders the Markdown")
                (with-current-buffer buf (lambda () (run-command "browse-cycle-view")))
                (check-equal! (buffer-local buf 'browse-view) "serif"
                              "the first cycle selects serif")
                (check-equal! (preview-typography) "serif"
                              "the cycle changes the type of every rendered page")
                (check-true! (minor-mode-on? buf "preview-mode")
                             "serif still renders the Markdown")
                (check-equal! (buffer-local buf 'render-mode) "markdown"
                              "a type change never leaves the rendered page")
                (with-current-buffer buf (lambda () (run-command "browse-cycle-view")))
                (check-equal! (buffer-local buf 'browse-view) "source"
                              "the second cycle selects source")
                (check-false! (minor-mode-on? buf "preview-mode")
                              "source is the only step that leaves the rendered page")
                (with-current-buffer buf (lambda () (run-command "browse-cycle-view")))
                (check-equal! (buffer-local buf 'browse-view) "mono"
                              "the third cycle returns to monospace")
                (check-true! (minor-mode-on? buf "preview-mode")
                             "rendering returns without changing the Markdown"))))))
      (t--web-kill-tabs!)
      (preview-typography! before))))

(deftest 'a-page-joins-the-group-of-the-window-that-opened-it
  "the group of the window that opened the page wins over the frame's group"
  (lambda ()
    (let ((saved-current (frame-local 'current-group))
          (saved-pinned (frame-local 'pinned-group))
          (back (current-buffer)))
      (t--web-with-fetch
        (lambda (url want k) (k (list want (t--web-pages url) #f)))
        (lambda ()
          (let ((mine (or (group-resolve-id "zzweb-mine")
                          (group-record-create! "zzweb-mine")))
                (spawner "*zz-web-spawn*"))
            (unless (buffer-known? spawner) (buffer-create spawner))
            (buffer-add-group! spawner mine)
            (set-frame-local! 'current-group mine)
            (set-frame-local! 'pinned-group mine)
            (switch-to-buffer! spawner)
            (t--web-pin-group! "zzweb-other"
              (lambda ()
                (let ((buf (browse "https://site.test/index.html")))
                  (check-equal! (group-name (buffer-group buf)) "zzweb-mine"
                                "the page joins the window that opened it")
                  (check-equal! (group-name (frame-group)) "zzweb-other"
                                "and the frame keeps its own group"))))
            (switch-to-buffer! back)
            (buffer-kill! spawner)
            (group-record-delete! mine))))
      (set-frame-local! 'current-group saved-current)
      (set-frame-local! 'pinned-group saved-pinned)
      (t--web-kill-tabs!))))

;;; --- the page -----------------------------------------------------------------

(deftest 'a-page-keeps-markdown-and-preview-owns-the-rendering
  "the canonical page is Markdown; preview-mode draws it in the same tab"
  (lambda ()
    (t--web-with-fetch
      (lambda (url want k) (k (list want (t--web-pages url) #f)))
      (lambda ()
        (let* ((buf (browse "https://site.test/index.html"))
               (text (buffer-text buf)))
          (check-contains! text "# Front page" "the heading marker stays")
          (check-contains! text "[second page](/second.html)"
                           "the link target stays")
          (check-equal! (buffer-local buf 'preview-renderer) "markdown"
                        "the generated buffer declares Markdown")
          (check-true! (minor-mode-on? buf "preview-mode")
                       "preview is the default view")
          (check-equal! (buffer-local buf 'render-mode) "markdown"
                        "preview owns the rendered view")
          (check-false! (buffer-local buf 'preview-rows)
                        "the page renders as a page, never as painted rows")

          ;; the reading look: centered writing measure, no line numbers
          (check-equal! (buffer-local buf 'window-class) "writing"
                        "the writing measure")
          (check-equal! (buffer-local buf 'line-numbers) "off"
                        "no line numbers")

          ;; Keyboard navigation still uses positions in the same Markdown.
          (let ((links (value->string (buffer-local buf 'web-links))))
            (check-contains! links "/second.html" "the first target")
            (check-contains! links "docs/intro.html" "the second")
            (check-contains! links "https://other.test/x"
                             "and the one that leaves")))))
    (t--web-kill-tabs!)))

(deftest 'every-page-is-its-own-tab-in-the-current-group
  "outside returns to a tab; preview links navigate that tab in place"
  (lambda ()
    (t--web-with-fetch
      (lambda (url want k) (k (list want (t--web-pages url) #f)))
      (lambda ()
        (t--web-pin-group! "zzweb-home"
          (lambda ()
            (let ((a (browse "https://site.test/index.html")))
              (check-contains! (buffer-local a 'modeline-name) "site.test/index.html"
                               "the visible title names the first page")
              (switch-to-buffer! "*scratch*")
              (let ((b (browse "https://site.test/second.html")))
                (check-false! (equal? a b) "two pages, two tabs")
                (check-contains! a "*browse:" "the tab is named for the page")
                (check-equal! (group-name (buffer-group b)) "zzweb-home"
                              "both tabs sit in the current group")
                (switch-to-buffer! "*scratch*")
                (check-equal! (browse "https://site.test/second.html") b
                              "the same url returns"))

              ;; The rendered preview sends relative links back through browse.
              (switch-to-buffer! a)
              (buffer-goto! a 12)
              (preview-follow-link! (active-window) "second.html")
              (check-equal! (current-buffer) a "preview navigation stays in tab")
              (check-equal! (buffer-local a 'browse-url)
                            "https://site.test/second.html"
                            "the relative target resolves against the page")
              (check-equal! (buffer-point a) 0
                            "new navigation starts at the top")
              (check-contains! (buffer-local a 'modeline-name)
                               "site.test/second.html"
                               "the visible title follows navigation"))))))
    (t--web-kill-tabs!)))

;;; --- the cache ----------------------------------------------------------------

(deftest 'a-wake-redraws-the-saved-page-without-fetching
  "the mode setup re-runs on restore and on preview"
  (lambda ()
    (let ((fetches 0))
      (t--web-with-fetch
        (lambda (url want k)
          (set! fetches (+ fetches 1))
          (k (list want "hello [x](https://a.test/)\n" #f)))
        (lambda ()
          (let ((buf (browse "https://site.test/")))
            (check-equal! fetches 1 "the first open fetches")

            (with-current-buffer buf (lambda () (set-mode! "browse-mode")))
            (check-equal! fetches 1 "a fresh page wakes without a fetch")
            (check-contains! (buffer-text buf) "hello" "and still reads")

            ;; past the TTL the wake refetches
            (buffer-set-local! buf 'cache-time (- (current-time) 999999))
            (with-current-buffer buf (lambda () (set-mode! "browse-mode")))
            (check-equal! fetches 2 "a stale page fetches again")))))
    (t--web-kill-tabs!)))

(deftest 'a-failed-refetch-keeps-the-page
  "the copy we hold serves; an empty view is worse than an old one"
  (lambda ()
    (let ((left 1))
      (t--web-with-fetch
        (lambda (url want k)
          (if (> left 0)
              (begin (set! left (- left 1))
                     (k (list want "# alive\n\nstill [here](https://site.test/x)\n" #f)))
              (k (list #f #f #f))))
        (lambda ()
          (let ((buf (browse "https://site.test/index.html")))
            (check-contains! (buffer-text buf) "alive" "the page arrived")
            ;; a refresh whose fetch fails: the copy serves again
            (buffer-set-local! buf 'cache-time #f)
            (cache-refresh! buf)
            (check-contains! (buffer-text buf) "alive" "and the page is still there")))))
    (t--web-kill-tabs!)))

;;; --- the pure passes ----------------------------------------------------------

(deftest 'relative-links-resolve-against-the-page-directory-and-the-origin
  "five shapes, one rule each"
  (lambda ()
    (check-equal! (web--resolve "/a/b.html" "https://h.test/x/y.html")
                  "https://h.test/a/b.html" "an absolute path")
    (check-equal! (web--resolve "b.html" "https://h.test/x/y.html")
                  "https://h.test/x/b.html" "a sibling")
    (check-equal! (web--resolve "#part" "https://h.test/x/y.html")
                  "https://h.test/x/y.html#part" "a heading on this page")
    (check-equal! (web--resolve "//cdn.test/z" "https://h.test/x")
                  "https://cdn.test/z" "a protocol-relative host")
    (check-equal! (web--resolve "https://abs.test/" "https://h.test/")
                  "https://abs.test/" "an absolute url is its own answer")))

(deftest 'adjacent-distinct-images-survive-empty-link-normalization
  "two images in a row are two links, the same image twice is still two"
  (lambda ()
    (check-equal! (web--fix-empty-links "![](https://img.test/a.png)![](https://img.test/b.png)")
                  "[https://img.test/a.png](https://img.test/a.png)[https://img.test/b.png](https://img.test/b.png)"
                  "two distinct images")
    (check-equal! (web--fix-empty-links "![](https://img.test/a.png)![](https://img.test/a.png)")
                  "[https://img.test/a.png](https://img.test/a.png)[https://img.test/a.png](https://img.test/a.png)"
                  "the same image twice")))

(deftest 'the-tidy-pass-drops-heading-marks-and-rules-and-unescapes-pandoc
  "what pandoc writes for a renderer is noise to a reader"
  (lambda ()
    (check-equal! (web--tidy "## A title\n\n----\n\nsee \\| this \\[here\\]\n")
                  "A title\n\nsee | this [here]\n" "the tidied text")))

(deftest 'an-image-stays-as-a-link-a-wrapped-pair-is-one-image-icons-go
  "an image keeps its source; a link wrapped around its image is one thing"
  (lambda ()
    (let ((out (web--tidy
                 "[](https://c.test/a.jpeg)\n![](https://c.test/a-big.jpeg)\n\n[](https://c.test/icon-anchor)\n\ntext\n")))
      (check-contains! out "[https://c.test/a.jpeg](https://c.test/a.jpeg)" "the image reads as a link")
      (check-false! (string-contains? out "a-big") "the wrapped pair is one image")
      (check-false! (string-contains? out "icon-anchor") "and the icon goes"))
    (let* ((parsed (web--parse
                     "![Diagram](https://c.test/diagram.png \"Diagram title\")"))
           (text (car parsed))
           (links (value->string (car (cdr parsed)))))
      (check-equal! text "https://c.test/diagram.png"
                    "the overlaid text is the image source")
      (check-contains! links "https://c.test/diagram.png"
                       "the image source stays attached"))
    (check-true! (web--image-url? "https://c.test/logo.svg")
                 "SVG images draw too")))

(deftest 'a-base64-picture-is-an-image-and-is-its-own-source
  "a data URI carries the picture: it stays, and no page resolves it"
  (lambda ()
    (let ((u "data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMTYiLz4="))
      (check-true! (web--image-url? u) "a data URI is an image")
      (check-equal! (web--resolve u "https://h.test/x/y.html") u
                    "and it resolves to itself")
      (check-equal! (web--fix-empty-links (string-append "![](" u ")"))
                    (string-append "[" u "](" u ")")
                    "the label-less image keeps its source instead of going"))))

(deftest 'apropos-documents-the-xslt-custom-site-parsers
  "the next person adds a parser without reading the package"
  (lambda ()
    (let ((hits (value->string (apropos "custom parser"))))
      (check-contains! hits "do not add a Scheme wrapper" "the rule")
      (check-contains! hits "*web--sites*" "the registry")
      (check-contains! hits "xsltproc --html" "the command")
      (check-contains! hits "example.xsl" "the example")
      ;; a row says both things, and the costly one carries its warning
      (check-contains! hits "RENDER?" "the second column")
      (check-contains! hits "costs a real browser tab" "and what it costs"))))

;;; --- the two readings -----------------------------------------------------------

(effects! '(pure))

(deftest 'a-reading-is-calm-or-full-and-nothing-else
  "one name in, one of two names out"
  (lambda ()
    (check-equal! (web--reading "calm") "calm" "calm stays calm")
    (check-equal! (web--reading "full") "full" "full stays full")
    (check-equal! (web--reading "article") "calm" "an old name reads as calm")
    (check-equal! (web--reading #f) "calm" "and so does nothing")))

(deftest 'the-site-registry-says-which-parser-and-whether-to-render
  "one row answers both questions; an unlisted site answers neither"
  (lambda ()
    (check-equal! (web--site-parser "https://substack.com/inbox") "substack.xsl"
                  "the parser for a listed site")
    (check-true! (web--site-render? "https://substack.com/inbox")
                 "substack sends a script shell, so it needs a tab")
    (check-false! (web--site-parser "https://example.com") "no parser for the rest")
    (check-false! (web--site-render? "https://news.ycombinator.com")
                  "and no tab: a plain fetch is the whole page")
    ;; a prefix must be a path boundary, not a string prefix
    (check-false! (web--site-parser "https://substack.com.evil.test/x")
                  "a lookalike host is not the site")))

(deftest 'a-link-is-split-without-a-second-regex
  "the label and target are split once; an optional title is not the URL"
  (lambda ()
    (check-equal! (web--link-parts "[label](https://x.test/a)")
                  (list "label" "https://x.test/a") "a plain link")
    (check-equal! (web--link-parts "![alt](https://x.test/a.png)")
                  (list "alt" "https://x.test/a.png") "an image")
    (check-equal! (web--link-parts "![alt](https://x.test/a.png \"A title\")")
                  (list "alt" "https://x.test/a.png") "an image with a title")
    (check-equal! (web--link-parts "[](https://x.test/a)")
                  (list "" "https://x.test/a") "an empty label")))

(deftest 'a-search-result-follows-past-the-engines-redirect
  "RET lands on the page, not on the hop"
  (lambda ()
    (check-equal!
      (web--resolve "//duckduckgo.com/l/?uddg=https%3A%2F%2Fgnu.org%2Fa.html&rut=x"
                    "https://html.duckduckgo.com/html/")
      "https://gnu.org/a.html" "the wrapper gives up its target")
    ;; a target that does not decode to a URL is left alone
    (check-equal! (web--unwrap "https://plain.test/x?uddg=notaurl")
                  "https://plain.test/x?uddg=notaurl" "nothing to unwrap")
    (check-equal! (web--unwrap "https://plain.test/x") "https://plain.test/x"
                  "an ordinary link is untouched")))

(deftest 'a-host-is-a-page-and-anything-else-is-a-search
  "one prompt takes both, the way an address bar does"
  (lambda ()
    (check-true! (web--url? "gnu.org") "a bare host")
    (check-true! (web--url? "gnu.org/software/emacs") "a host with a path")
    (check-true! (web--url? "localhost:4004") "the one host with no dot")
    (check-false! (web--url? "emacs lisp manual") "a question has spaces")
    (check-false! (web--url? "readable") "and one word is not a host")

    (check-equal! (web--target "gnu.org") "https://gnu.org" "a host gets a scheme")
    (check-equal! (web--target "https://gnu.org/x") "https://gnu.org/x"
                  "a full URL goes as typed")
    (check-contains! (web--target "emacs lisp manual") "q=emacs%20lisp%20manual"
                     "a question becomes a search")
    (check-equal! (web--slug (web--target "emacs lisp manual"))
                  "search: emacs lisp manual"
                  "and the tab names the question, not the engine")))

(effects! '(write))

(deftest 'calm-without-an-article-shows-the-page-whole-and-says-so
  "an index page IS its links; the modeline explains the reading"
  (lambda ()
    (t--web-with-fetch
      ;; the pipeline answers with the reading it FOUND, which is not
      ;; always the one that was asked for
      (lambda (url want k) (k (list "full" "# index\n\ngo [on](https://site.test/x)\n" #f)))
      (lambda ()
        (let ((buf (browse "https://site.test/index.html")))
          (check-equal! (buffer-local buf 'browse-reading) "full" "the reading on screen")
          (check-equal! (web--want buf) "calm" "the reading that was asked for")
          (check-contains! (buffer-local buf 'modeline-info) "full (no article)"
                           "the modeline says why the two differ"))))
    (t--web-kill-tabs!)))

(deftest 'the-reading-that-was-found-is-what-the-modeline-names
  "asked for calm, given calm: no note"
  (lambda ()
    (t--web-with-fetch
      (lambda (url want k) (k (list want "# story\n\nthe [text](https://site.test/x)\n" #f)))
      (lambda ()
        (let ((buf (browse "https://site.test/story.html")))
          (check-equal! (buffer-local buf 'browse-reading) "calm" "calm was found")
          (check-contains! (buffer-local buf 'modeline-info) "calm · " "and named plainly")
          (check-false! (string-contains? (buffer-local buf 'modeline-info) "no article")
                        "with no note"))))
    (t--web-kill-tabs!)))

(deftest 'the-switch-re-reads-the-held-html-and-never-fetches
  "R costs one conversion, not a page load"
  (lambda ()
    (let ((fetches 0)
          (saved-read web--read))
      (t--web-with-fetch
        (lambda (url want k)
          (set! fetches (+ fetches 1))
          ;; the pipeline hands back the html it read, so R can re-read it
          (k (list want "# calm\n\nthe [article](https://site.test/x)\n" "<html>page</html>")))
        (lambda ()
          (let ((buf (browse "https://site.test/story.html")))
            (check-equal! fetches 1 "the open fetched once")
            (check-equal! (buffer-local buf 'browse-html) "<html>page</html>"
                          "and the html stayed for the switch")

            ;; the reading step, stubbed: no shell, no readable, no pandoc
            (set! web--read
              (lambda (url file reading k)
                (k (string-append "# " reading "\n\nthe [whole](https://site.test/y) page\n"))))

            (with-current-buffer buf
              (lambda () (run-command "browse-toggle-reading")))

            (check-equal! fetches 1 "the switch did NOT fetch")
            (check-equal! (web--want buf) "full" "the ask flipped")
            (check-equal! (buffer-local buf 'browse-reading) "full" "and so did the reading")
            (check-contains! (buffer-text buf) "whole" "the buffer holds the new reading")

            (with-current-buffer buf
              (lambda () (run-command "browse-toggle-reading")))
            (check-equal! (web--want buf) "calm" "and it switches back")
            (check-equal! fetches 1 "still no fetch"))))
      (set! web--read saved-read))
    (t--web-kill-tabs!)))

;;; --- history with point ---------------------------------------------------------

(deftest 'back-and-forward-return-to-the-line-the-reader-left
  "a history entry is (URL POINT); a bare URL from an old desktop still reads"
  (lambda ()
    (t--web-with-fetch
      (lambda (url want k) (k (list want (t--web-pages url) #f)))
      (lambda ()
        (let ((buf (browse "https://site.test/index.html")))
          (with-current-buffer buf
            (lambda ()
              (let ((l (web--link-after buf 0)))
                (goto-char! (car l))
                (run-command "browse-follow")
                (check-equal! (buffer-local buf 'browse-url)
                              "https://site.test/second.html" "the link was followed")
                (check-equal! (car (buffer-local buf 'browse-history))
                              (list "https://site.test/index.html" (car l))
                              "the entry names the page and the point")
                (run-command "browse-back")
                (check-equal! (buffer-point buf) (car l) "back lands on the link")
                (goto-char! 0)
                (run-command "browse-forward")
                (check-contains! (buffer-text buf) "Second page" "forward returns")
                (run-command "browse-back")
                (check-equal! (buffer-point buf) 0 "and back keeps the newer point"))))
          ;; an entry from before this shape: a bare URL
          (buffer-set-local! buf 'browse-history '("https://site.test/index.html"))
          (buffer-set-local! buf 'browse-url "https://site.test/second.html")
          (with-current-buffer buf (lambda () (run-command "browse-back")))
          (check-equal! (buffer-local buf 'browse-url) "https://site.test/index.html"
                        "a bare URL still goes back")
          (check-equal! (buffer-point buf) 0 "and opens at the top"))))
    (t--web-kill-tabs!)))

(deftest 'a-refetch-of-the-same-page-keeps-the-point
  "g on this page is a refresh, not a new page"
  (lambda ()
    (t--web-with-fetch
      (lambda (url want k) (k (list want (t--web-pages url) #f)))
      (lambda ()
        (let ((buf (browse "https://site.test/index.html")))
          (buffer-goto! buf 12)
          (buffer-set-local! buf 'browse-restore-point (buffer-point buf))
          (buffer-set-local! buf 'cache-time #f)
          (cache-refresh! buf)
          (check-equal! (buffer-point buf) 12 "point stayed"))))
    (t--web-kill-tabs!)))

;;; --- the other window -----------------------------------------------------------

(deftest 'a-link-opens-beside-this-window-and-point-stays-here
  "M-RET: the tab shows in another window; the selected window keeps its page"
  (lambda ()
    (run-command "delete-other-windows")
    (t--web-with-fetch
      (lambda (url want k) (k (list want (t--web-pages url) #f)))
      (lambda ()
        ;; browse selects the tab's window, so the command runs the way a
        ;; key press runs it: in the selected window, not under a
        ;; with-current-buffer, which binds the buffer and not the window
        (let* ((a (browse "https://site.test/index.html"))
               (l (web--link-after a 0)))
          (goto-char! (car l))
          (run-command "browse-follow-other-window")
          (check-equal! (current-buffer) a "the reader stays in the page")
          (check-equal! (buffer-point a) (car l) "at the link")
          (let ((b (web--buffer-for "https://site.test/second.html")))
            (check-true! (and b #t) "the link's tab exists")
            (check-contains! (buffer-text b) "Second page" "and holds the page")
            (check-true! (and (window-showing b) #t) "in a window of its own")
            (check-false! (equal? (window-showing b) (active-window))
                          "which is not the selected one")))))
    (t--web-kill-tabs!)
    (run-command "delete-other-windows")))

(deftest 'browse-other-window-shows-the-page-and-leaves-the-window-alone
  "the C-x 4 shape from any buffer"
  (lambda ()
    (run-command "delete-other-windows")
    (t--web-with-fetch
      (lambda (url want k) (k (list want (t--web-pages url) #f)))
      (lambda ()
        (switch-to-buffer! "*scratch*")
        (let ((b (browse-other-window "https://site.test/index.html")))
          (check-equal! (current-buffer) "*scratch*" "the selected window is untouched")
          (check-contains! b "*browse:" "the page has its tab")
          (check-true! (and (window-showing b) #t) "shown in another window"))))
    (t--web-kill-tabs!)
    (run-command "delete-other-windows")))

;;; --- the history file -----------------------------------------------------------

(deftest 'the-history-file-keeps-url-title-and-time-newest-first
  "one line per page; a forgotten page is gone; the old shape still reads"
  (lambda ()
    (t--web-with-fetch
      (lambda (url want k) (k (list want (t--web-pages url) #f)))
      (lambda ()
        (write-file! *web-visited-file* "https://old.test/a Old page\n")
        (browse "https://site.test/index.html")
        (let ((rows (web--history)))
          (check-equal! (car (car rows)) "https://site.test/index.html" "newest first")
          (check-equal! (nth 1 (car rows)) "Front page" "with its title")
          (check-true! (> (nth 2 (car rows)) 0) "and its time")
          (check-equal! (nth 1 rows) (list "https://old.test/a" "Old page" 0)
                        "an old line reads with no time"))
        (check-contains! (read-file *web-visited-file*) "\t" "the file rewrites in the new shape")
        (web--forget-visit! "https://site.test/index.html")
        (check-false! (assoc "https://site.test/index.html" (web--history))
                      "the page is forgotten")
        (check-equal! (web--visited) '(("https://old.test/a" "Old page"))
                      "and the prompt sees (URL TITLE)")))
    (t--web-kill-tabs!)))

(deftest 'the-history-list-shows-the-pages-and-forgets-one
  "H opens the list; d takes a row out"
  (lambda ()
    (run-command "delete-other-windows")
    (t--web-with-fetch
      (lambda (url want k) (k (list want (t--web-pages url) #f)))
      (lambda ()
        (write-file! *web-visited-file* "")
        (browse "https://site.test/index.html")
        (run-command "browse-history")
        (check-true! (buffer-exists? *web-history-buffer*) "the list buffer exists")
        (check-contains! (buffer-text *web-history-buffer*) "Front page" "with the page's title")
        (check-contains! (buffer-text *web-history-buffer*) "site.test" "and its URL")
        (with-current-buffer *web-history-buffer*
          (lambda ()
            (check-equal! (car (list-current *web-history-buffer*))
                          "https://site.test/index.html" "the row is the page")
            (run-command "browse-history-forget")))
        (check-false! (string-contains? (buffer-text *web-history-buffer*) "site.test")
                      "the row is gone")
        (check-equal! (web--history) '() "and so is the line")))
    (when (buffer-exists? *web-history-buffer*) (buffer-kill! *web-history-buffer*))
    (t--web-kill-tabs!)
    (run-command "delete-other-windows")))

;;; --- the small verbs ------------------------------------------------------------

(effects! '(pure))

(deftest 'up-goes-to-the-parent-path-and-top-to-the-site-root
  "u and t are URL arithmetic"
  (lambda ()
    (check-equal! (web--parent-url "https://h.test/a/b/c.html") "https://h.test/a/b/" "a page's directory")
    (check-equal! (web--parent-url "https://h.test/a/b/") "https://h.test/a/" "a directory's parent")
    (check-equal! (web--parent-url "https://h.test/a/b?x=1") "https://h.test/a/" "the query goes")
    (check-equal! (web--parent-url "https://h.test/") "https://h.test/" "the root is its own parent")
    (check-equal! (web--parent-url "https://h.test") "https://h.test/" "and so is a bare host")
    (check-equal! (web--origin "https://h.test/a/b") "https://h.test" "the origin")
    (check-equal! (web--download-name "https://h.test/files/paper.pdf?dl=1") "paper.pdf"
                  "a download takes the last segment")
    (check-equal! (web--download-name "https://h.test/") "h.test.html"
                  "and a host names a page")))

(deftest 'the-age-label-reads-in-minutes-hours-and-days
  "the history column"
  (lambda ()
    (check-equal! (web--age-label 0) "" "no time, no label")
    (check-equal! (web--age-label (current-time)) "just now" "now")
    (check-equal! (web--age-label (- (current-time) 300)) "5m ago" "minutes")
    (check-equal! (web--age-label (- (current-time) 7200)) "2h ago" "hours")
    (check-equal! (web--age-label (- (current-time) 172800)) "2d ago" "days")))

(effects! '(write))

(deftest 'w-copies-the-link-at-point-else-the-page
  "eww's w, both halves"
  (lambda ()
    (t--web-with-fetch
      (lambda (url want k) (k (list want (t--web-pages url) #f)))
      (lambda ()
        (let ((buf (browse "https://site.test/index.html")))
          (with-current-buffer buf
            (lambda ()
              (goto-char! (car (web--link-after buf 0)))
              (run-command "browse-copy-url")
              (check-equal! (kill-top) "https://site.test/second.html" "the link, resolved")
              (goto-char! 0)
              (run-command "browse-copy-url")
              (check-equal! (kill-top) "https://site.test/index.html" "the page"))))))
    (t--web-kill-tabs!)))

(deftest 'm-n-and-m-p-walk-the-tabs-in-a-ring
  "two tabs, both directions"
  (lambda ()
    (t--web-with-fetch
      (lambda (url want k) (k (list want (t--web-pages url) #f)))
      (lambda ()
        (let ((a (browse "https://site.test/index.html")))
          (switch-to-buffer! "*scratch*")
          (let ((b (browse "https://site.test/second.html")))
            (check-equal! (web--tab-step a 1) b "next from a is b")
            (check-equal! (web--tab-step b 1) a "and next from b wraps to a")
            (check-equal! (web--tab-step a -1) b "previous wraps the other way")
            (switch-to-buffer! b)
            (run-command "browse-next-tab")
            (check-equal! (current-buffer) a "the command switches")))))
    (t--web-kill-tabs!)))

(deftest 'a-bookmark-records-the-url-and-point-and-jumps-back-to-them
  "the tab may be gone; the page comes back from the URL"
  (lambda ()
    (when (boundp 'bookmark-register-handler!)
      (t--web-with-fetch
        (lambda (url want k) (k (list want (t--web-pages url) #f)))
        (lambda ()
          (check-equal! (bookmark--mode-handler "browse-mode") "browse"
                        "browse-mode has its handler")
          (let ((buf (browse "https://site.test/index.html")))
            (buffer-goto! buf 7)
            (let ((record (web--bookmark-record buf)))
              (check-equal! (plist-get record 'url) "https://site.test/index.html" "the URL")
              (check-equal! (plist-get record 'title) "Front page" "the title")
              (check-equal! (plist-get record 'position) 7 "the point")
              (buffer-kill! buf)
              (switch-to-buffer! "*scratch*")
              (let ((tab (web--bookmark-jump! record "current")))
                (check-equal! (current-buffer) tab "the jump opens the page")
                (check-contains! (buffer-text tab) "Front page" "fetched again")
                (check-equal! (buffer-point tab) 7 "at the saved point")))))))
    (t--web-kill-tabs!)))

;;; --- content types --------------------------------------------------------------

(effects! '(pure))

(deftest 'a-content-type-picks-the-reader
  "the type decides the reading; html and its neighbours stay on the html path"
  (lambda ()
    (check-equal! (web--content-type "Application/PDF; charset=binary") "application/pdf"
                  "the type drops its parameters")
    (check-true! (web--markup-type? "text/html") "html reads as markup")
    (check-true! (web--markup-type? "application/rss+xml") "and so does xml")
    (check-false! (web--markup-type? "application/pdf") "a PDF does not")
    (check-true! (web--vague-type? "application/octet-stream")
                 "a server that says bytes has said nothing")
    (check-contains! ((web--mime-reader "application/pdf") "/tmp/zz.pdf" "https://h.test/a.pdf")
                     "pdftotext" "a PDF reads through pdftotext")
    (check-contains! ((web--mime-reader "text/plain") "/tmp/zz.txt" "https://h.test/a.txt")
                     "cat" "plain text reads as it is")
    (check-false! (web--mime-reader "application/zip") "and nothing reads an archive")))

(deftest 'a-bot-wall-is-not-a-page
  "DuckDuckGo's challenge reads as nothing, so the reader retries instead of showing it"
  (lambda ()
    (check-true! (web--blocked? "Unfortunately, bots use DuckDuckGo too.")
                 "the challenge is a wall")
    (check-false! (web--blocked? "# opencode\n\n## [OpenCode](https://opencode.ai)")
                  "a results page is not")
    (check-false! (web--blocked? #f) "and neither is a failed read")))

;; A page x.com answers a bare fetch with is 300kb of "Something went
;; wrong" — too big for the thin test to catch, so the reader used to
;; show the error page AS the page. The tab goes first now, and the
;; fetch is the fallback that can still answer bytes.
(deftest 'the-reader-tries-the-tab-and-the-fetch-once-each
  "whichever way it starts, the other way gets one try and the flag ends it"
  (lambda ()
    (let ((saved *web-fetch-html*))
      (define (ways-tried from)
        (let ((seen '()) (answer 'none))
          (set! *web-fetch-html*
                (lambda (url k &optional revalidate? render?)
                  (set! seen (append seen (list (and render? #t))))
                  (k #f)))
          (web--attempt "https://site.test/" "calm" from
                        (lambda (found) (set! answer found)))
          (list seen answer)))
      (let ((tab-first (ways-tried #t))
            (fetch-first (ways-tried #f)))
        (set! *web-fetch-html* saved)
        (check-equal! (nth 0 tab-first) (list #t #f)
                      "from the tab: the tab, then the fetch")
        (check-equal! (nth 0 fetch-first) (list #f #t)
                      "from the fetch: the fetch, then the tab")
        (check-equal! (nth 1 tab-first) (list #f #f #f)
                      "two ways tried is the end of it")
        (check-equal! (nth 1 fetch-first) (list #f #f #f)
                      "and the same from the other side")))))

(deftest 'text-that-lost-its-bytes-is-not-a-document
  "a PDF decoded as text is not markup, whatever the browser called it"
  (lambda ()
    (check-true! (web--markup? "<html><body>hi</body></html>") "markup is markup")
    (check-false! (web--markup? "plain words, no tags") "prose is not")
    (check-false! (web--markup? (string-append "<html>" *web--replacement-char* "junk"))
                  "and neither is a lossy decode")))

(effects! '(write))

(deftest 'a-body-that-is-not-markup-reads-through-its-own-reader
  "text reads as text, and a type with no reader says what it is"
  (lambda ()
    (let ((answer #f))
      (web--read-mime "https://h.test/notes.txt" "calm"
                      (web--document "text/plain" "plain words here\n" #f)
                      (lambda (found) (set! answer found)))
      (check-true! (wait-until (lambda () (and answer #t)) 5000 20) "the reading answered")
      (check-contains! (nth 1 answer) "# notes.txt" "the page is titled by its name")
      (check-contains! (nth 1 answer) "plain words here" "and holds the text")
      (check-false! (nth 2 answer) "a body that is not html has no source to show"))
    (let* ((file (web--write-body! "zzzz"))
           (found (web--mime-note "https://h.test/bundle.zip" "application/zip" file)))
      (delete-file! file)
      (check-contains! found "# bundle.zip" "the note names the file")
      (check-contains! found "application/zip" "and its type")
      (check-contains! found "4 B" "and its size"))))

(deftest 'browser-bytes-land-in-a-file-byte-for-byte
  "the fetch op hands bytes back base64; nothing decodes them as text"
  (lambda ()
    (let* ((doc (web--browser-document (list "application/pdf" #f "JVBERi0xLjQK")))
           (file (web--doc-file doc)))
      (check-equal! (web--doc-type doc) "application/pdf" "the type the browser named")
      (check-false! (web--doc-text doc) "no text, because bytes are not text")
      (check-equal! (read-file file) "%PDF-1.4\n" "and the bytes are whole")
      (delete-file! file))
    (check-false! (web--browser-document (list "text/html" "" #f))
                  "an empty answer is no document")))

(deftest 'a-viewer-type-is-kept-as-a-file-and-not-read-as-text
  "the type decides: a PDF is saved and opened, not flattened into text"
  (lambda ()
    (check-equal! (web--mime-file-extension "application/pdf") "pdf" "a PDF has a viewer")
    (check-false! (web--mime-file-extension "text/csv") "a table does not")
    (let ((answer #f))
      (web--read-mime "https://h.test/papers/report.pdf" "calm"
                      (web--document "application/pdf" #f (web--write-body! "%PDF-1.4\n"))
                      (lambda (found) (set! answer found)))
      (check-true! (wait-until (lambda () (and answer #t)) 5000 20) "the reading answered")
      (check-equal! (nth 0 answer) "file" "the answer is a file, not a reading")
      (check-equal! (nth 1 answer) (string-append (compos-home) "/browse-files/report.pdf")
                    "kept under the name the URL gave it")
      (check-equal! (read-file (nth 1 answer)) "%PDF-1.4\n" "with its bytes")
      (delete-file! (nth 1 answer)))))

(deftest 'a-document-the-editor-opens-itself-takes-the-tabs-window
  "a PDF is not a reading: the file buffer replaces the browse tab"
  (lambda ()
    (run-command "delete-other-windows")
    (let ((path (string-append (compos-home) "/browse-files/zz-web-viewer.pdf")))
      (make-directory! (string-append (compos-home) "/browse-files"))
      (write-file! path "%PDF-1.4\n")
      (t--web-with-fetch
        ;; the real pipeline always answers on a callback, and the tab is
        ;; retired there: a stub that answers inline would be killing the
        ;; buffer under the caller that just asked for it
        (lambda (url want k)
          (shell-command->string "true" (lambda (out) (k (list "file" path #f)))))
        (lambda ()
          (let ((tab (browse "https://site.test/zz-web-viewer.pdf")))
            (check-true! (wait-until (lambda () (not (buffer-known? tab))) 5000 25)
                         "the tab is gone")
            (check-true! (and (window-showing path) #t) "and the file has its window"))))
      (when (buffer-known? path) (buffer-kill! path))
      (delete-file! path))
    (t--web-kill-tabs!)
    (run-command "delete-other-windows")))

;;; --- the order of the ways, and what a host teaches ------------------------------

(effects! '(read))

(deftest 'the-fetch-goes-first-and-a-site-that-needs-a-tab-starts-there
  "a tab costs a page load; only a site known to answer a shell pays it first"
  (lambda ()
    (let ((saved *web-fetch-html*)
          (saved-tabs *web--tab-hosts*))
      (define (first-way url)
        (let ((seen '()))
          (set! *web-fetch-html*
                (lambda (url k &optional revalidate? render?)
                  (set! seen (append seen (list (and render? #t))))
                  (k #f)))
          (web--pipeline url "calm" (lambda (found) #f))
          (car seen)))
      (set! *web--tab-hosts* '())
      (check-false! (first-way "https://plain.test/page") "an unknown site: the fetch")
      (check-true! (first-way "https://www.linkedin.com/talent/home")
                   "a site the table marks: the tab")
      (check-true! (first-way "https://x.com/someone")
                   "x.com answers a fetch with an error page: the tab")
      (web--tab-host! "https://plain.test/other")
      (check-true! (first-way "https://plain.test/page") "a host that taught the reader: the tab")
      (set! *web--tab-hosts* saved-tabs)
      (set! *web-fetch-html* saved))))

(deftest 'a-host-whose-calm-found-nothing-reads-full-at-once
  "Readability costs a process; a host with no article does not pay it on every page"
  (lambda ()
    (let ((saved-full *web--full-hosts*))
      (set! *web--full-hosts* '())
      (check-false! (web--calm-skip? "https://shop.test/a" "calm") "nothing learned yet")
      (web--full-host! "https://shop.test/a")
      (check-true! (web--calm-skip? "https://shop.test/b" "calm") "the host reads full now")
      (check-false! (web--calm-skip? "https://shop.test/b" "full") "full was the ask anyway")
      (web--full-host! "https://news.ycombinator.com/")
      (check-false! (web--calm-skip? "https://news.ycombinator.com/item?id=1" "calm")
                    "a site with a stylesheet keeps calm: xsltproc is one process")
      (web--full-host-forget! "https://shop.test/c")
      (check-false! (web--calm-skip? "https://shop.test/b" "calm") "forgotten")
      (set! *web--full-hosts* saved-full))))

(deftest 'calm-that-found-nothing-teaches-the-host
  "the first page pays for calm and full; the next page from the host pays for full alone"
  (lambda ()
    (let ((saved-fetch *web-fetch-html*)
          (saved-read web--read)
          (saved-judge *web--judge*)
          (saved-full *web--full-hosts*)
          (saved-learn browse-learn-parsers)
          (asked '())
          (answers '()))
      (set! *web--full-hosts* '())
      (set! browse-learn-parsers #f)
      (set! *web--judge* (lambda (url md k) (k #f)))
      (set! *web-fetch-html*
            (lambda (url k &optional revalidate? render?)
              (k "<html><body>index</body></html>")))
      (set! web--read
            (lambda (url file reading k)
              (set! asked (append asked (list reading)))
              (k (if (equal? reading "full")
                     "# whole\n\nthe page [a](https://shop.test/a)\n"
                     #f))))
      (web--attempt "https://shop.test/" "calm" #f
                    (lambda (found) (set! answers (append answers (list (car found))))))
      (web--attempt "https://shop.test/b" "calm" #f
                    (lambda (found) (set! answers (append answers (list (car found))))))
      (check-equal! asked '("calm" "full" "full") "calm once, then full alone")
      (check-equal! answers '("full" "full") "both pages read full")
      (set! browse-learn-parsers saved-learn)
      (set! *web--full-hosts* saved-full)
      (set! *web--judge* saved-judge)
      (set! web--read saved-read)
      (set! *web-fetch-html* saved-fetch))))

(effects! '(write))

(deftest 'a-shell-marks-the-host-and-the-page-fetches-again-in-a-tab
  "the fetched page shows at once; the judge's verdict starts the tab"
  (lambda ()
    (let ((saved-fetch *web-fetch-html*)
          (saved-read web--read)
          (saved-judge *web--judge*)
          (saved-tabs *web--tab-hosts*)
          (saved-judged *web--judged-hosts*)
          (saved-learn browse-learn-parsers)
          (ways '())
          (verdicts 0))
      (set! browse-learn-parsers #f)
      (set! *web--tab-hosts* '())
      (set! *web--judged-hosts* '())
      (set! *web-fetch-html*
            (lambda (url k &optional revalidate? render?)
              (set! ways (append ways (list (and render? #t))))
              (k (if render?
                     "<html><body>the page</body></html>"
                     "<html><body>Something went wrong</body></html>"))))
      (set! web--read
            (lambda (url file reading k)
              (k (if (string-contains? (read-file file) "went wrong")
                     "# x\n\nSomething went wrong. Try reloading. [home](https://shell.test/)\n"
                     "# x\n\nthe page [a](https://shell.test/a)\n"))))
      ;; the judge answers on a callback, as decide does: the page is on
      ;; screen and its fetch is over before the verdict lands
      (set! *web--judge*
            (lambda (url md k)
              (set! verdicts (+ verdicts 1))
              (shell-command->string "true"
                (lambda (out) (k (string-contains? md "went wrong"))))))
      (t--web-with-fetch *web-fetch*
        (lambda ()
          (let ((buf (browse "https://shell.test/home")))
            (check-contains! (buffer-text buf) "went wrong" "the fetched page shows at once")
            (check-true! (wait-until (lambda () (string-contains? (buffer-text buf) "the page")) 5000 20)
                         "the tab's reading replaced the shell")
            (check-equal! ways '(#f #t) "the fetch, then the tab")
            (check-true! (web--tab-host? "https://shell.test/x") "the host starts in a tab now")
            (let ((next (browse "https://shell.test/next")))
              (check-contains! (buffer-text next) "the page" "the next page read in a tab")
              (check-equal! verdicts 1 "one question per host")))))
      (t--web-kill-tabs!)
      (set! browse-learn-parsers saved-learn)
      (set! *web--judged-hosts* saved-judged)
      (set! *web--tab-hosts* saved-tabs)
      (set! *web--judge* saved-judge)
      (set! web--read saved-read)
      (set! *web-fetch-html* saved-fetch))))

(deftest 'the-judge-reads-a-yes-from-a-decide-reply
  "a noul at or above a half is a shell; a missing answer is not"
  (lambda ()
    (check-true! (web--judge-yes? '(answers ((shell (type noul noul 0.9 confidence 1.0))) usage (0 0 laya))
                                  'shell)
                 "a yes")
    (check-false! (web--judge-yes? '(answers ((shell (type noul noul 0.1))) usage (0 0 laya)) 'shell)
                  "a no")
    (check-true! (web--judge-yes? '(answers (("shell" (type noul noul 1.0)))) 'shell)
                 "a key that came back as a string")
    (check-false! (web--judge-yes? '(answers () usage (0 0 jev 0)) 'shell) "no answer is a no")))

(deftest 'a-nested-table-layout-reads-as-rows-and-a-plain-table-stays-one
  "both passes start at once; the flat one is the reading only when pandoc gave up"
  (lambda ()
    (let ((nested (web--write-html!
                    (string-append
                      "<html><body><table><tr><td><table><tr><td><p>first cell with enough "
                      "words in it to pass the thin test of two hundred bytes, which the reading "
                      "applies to every answer before it shows one, and a few more words so the "
                      "flattened reading is long enough on its own.</p><ul><li>one item</li>"
                      "<li>two items</li></ul></td></tr></table></td></tr></table></body></html>")))
          (plain (web--write-html!
                   (string-append
                     "<html><body><p>intro paragraph of enough words to pass the thin test of "
                     "two hundred bytes, which the reading applies to every answer before it "
                     "shows one, so this line goes on a while longer still.</p><table><tr>"
                     "<th>name</th><th>age</th></tr><tr><td>ann</td><td>3</td></tr></table>"
                     "</body></html>")))
          (a 'none)
          (b 'none))
      (web--read "https://t.test/" nested "full" (lambda (md) (set! a md)))
      (web--read "https://t.test/" plain "full" (lambda (md) (set! b md)))
      (check-true! (wait-until (lambda () (and (not (eq? a 'none)) (not (eq? b 'none)))) 15000 25)
                   "both readings answered")
      (check-true! (and (string? a) (string-contains? a "first cell") #t)
                   "the nested layout reads as its text")
      (check-false! (and (string? a) (string-contains? a "[TABLE]"))
                    "and not as a placeholder")
      (check-true! (and (string? b) (string-contains? b "| ann") #t)
                   "a real table stays a table")
      (delete-file! nested)
      (delete-file! plain))))
