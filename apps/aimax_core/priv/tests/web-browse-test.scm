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
      (lambda (url k) (k (t--web-pages url)))
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
      (lambda (url k) (k (t--web-pages url)))
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
        (lambda (url k)
          (set! fetches (+ fetches 1))
          (k "hello [x](https://a.test/)\n"))
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
        (lambda (url k)
          (if (> left 0)
              (begin (set! left (- left 1))
                     (k "# alive\n\nstill [here](https://site.test/x)\n"))
              (k #f)))
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
      (check-contains! hits "*web--xslt-sites*" "the registry")
      (check-contains! hits "xsltproc --html" "the command")
      (check-contains! hits "example.xsl" "the example"))))
