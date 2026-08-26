;;; web-browse-test.scm --- packages/web.scm, pages read as text, offline.
;;;
;;; The fetch seam is replaced, so no test reaches the network. Links
;;; render as labels, a page is its own tab in the browse group, and the
;;; wake serves the copy it holds.
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

;;; --- the page -----------------------------------------------------------------

(deftest 'a-page-renders-as-text-labels-stay-targets-hide-syntax-goes
  "the reader gets prose; the targets live in a buffer-local"
  (lambda ()
    (t--web-with-fetch
      (lambda (url want k) (k (list want (t--web-pages url) #f)))
      (lambda ()
        (let* ((buf (browse "https://site.test/index.html"))
               (text (buffer-text buf)))
          (check-contains! text "Front page" "the heading text")
          (check-false! (string-contains? text "# Front page") "and not its mark")
          (check-contains! text "second page" "the link label")
          (check-false! (string-contains? text "](/second.html") "and not its target")
          (check-false! (string-contains? text "(docs/intro.html") "nor a relative one")
          (check-false! (buffer-local buf 'render-mode) "the page is text, not blocks")

          ;; the reading look: centered writing measure, no line numbers
          (check-equal! (buffer-local buf 'window-class) "writing" "the writing measure")
          (check-equal! (buffer-local buf 'line-numbers) "off" "no line numbers")

          (let ((links (value->string (buffer-local buf 'web-links))))
            (check-contains! links "/second.html" "the first target")
            (check-contains! links "docs/intro.html" "the second")
            (check-contains! links "https://other.test/x" "and the one that leaves")))))
    (t--web-kill-tabs!)))

(deftest 'every-page-is-its-own-tab-in-the-browse-group
  "a url from outside returns to its tab; a url inside one navigates in place"
  (lambda ()
    (t--web-with-fetch
      (lambda (url want k) (k (list want (t--web-pages url) #f)))
      (lambda ()
        (let ((a (browse "https://site.test/index.html")))
          (switch-to-buffer! "*scratch*")
          (let ((b (browse "https://site.test/second.html")))
            (check-false! (equal? a b) "two pages, two tabs")
            (check-contains! a "*browse:" "the tab is named for the page")
            (check-equal! (buffer-local b 'group) "browse" "both sit in the browse group")

            ;; the same url from outside returns to its tab, not a new one
            (switch-to-buffer! "*scratch*")
            (check-equal! (browse "https://site.test/second.html") b "the same url returns")

            ;; inside a tab, a url navigates IN PLACE
            (switch-to-buffer! a)
            (check-equal! (browse "https://site.test/second.html") a "a tab navigates itself")))))
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
  "four shapes, one rule each"
  (lambda ()
    (check-equal! (web--resolve "/a/b.html" "https://h.test/x/y.html")
                  "https://h.test/a/b.html" "an absolute path")
    (check-equal! (web--resolve "b.html" "https://h.test/x/y.html")
                  "https://h.test/x/b.html" "a sibling")
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
  "a link wrapped around its own image is one thing, not two"
  (lambda ()
    (let ((out (web--tidy
                 "[](https://c.test/a.jpeg)\n![](https://c.test/a-big.jpeg)\n\n[](https://c.test/icon-anchor)\n\ntext\n")))
      (check-contains! out "[https://c.test/a.jpeg](https://c.test/a.jpeg)" "the image reads as a link")
      (check-false! (string-contains? out "a-big") "the wrapped pair is one image")
      (check-false! (string-contains? out "icon-anchor") "and the icon goes"))))

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
  "the label holds no ] and the target holds no ), so one index finds both"
  (lambda ()
    (check-equal! (web--link-parts "[label](https://x.test/a)")
                  (list "label" "https://x.test/a") "a plain link")
    (check-equal! (web--link-parts "![alt](https://x.test/a.png)")
                  (list "alt" "https://x.test/a.png") "an image")
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
