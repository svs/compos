;;; xslt.scm --- a site parser the editor writes for itself.
;;;
;;; browse-mode reads a page through a stylesheet when the site has one, and
;;; through Readability when it does not. A hand-written stylesheet is better
;;; and costs an afternoon. This package writes one.
;;;
;;; Three steps, and each one is a stylesheet or a question:
;;;
;;;   DISCOVER  web/discover.xsl walks the page and answers a table: one row
;;;             per structural element, with its text volume, link density,
;;;             class tokens and how to address it.
;;;   JUDGE     JEV scores each row. Is this navigation, a masthead, an ad
;;;             slot, an upsell, a consent notice -- or the content?
;;;   EMIT      each flagged row becomes an empty template. The sheet copies
;;;             the document and deletes those nodes.
;;;
;;; The walk is top down, and the whole walk arrives before the first
;;; question. So the questions about a deeper level are asked speculatively
;;; beside the questions about the level above it, in one call, and code
;;; throws away every answer that sits inside a box that turned out to be
;;; furniture. Parallel questions in one call cost no more time than one
;;; question, and a page's chrome sits near its top, so a page costs one
;;; JEV call, not one per level and not one per node.
;;;
;;; Discovery and the finished parser run in the same engine, so a pattern
;;; that selects a node during discovery selects it in production.
;;;
;;; xslt-score asks JEV, so that step needs the jev package loaded. Every
;;; other step is a stylesheet or string work.
;;;
;;; The sheet is also the cache. JEV judges a site once; every later visit
;;; reads web/parsers/HOST.xsl and spends nothing.

(domain! 'web)
(effects! '(read external execute))

(defcustom 'xslt-discover-depth 6
  "How many levels below body discovery reports."
  'group 'web 'type 'integer)

(defcustom 'xslt-chrome-threshold 0.7
  "How sure JEV must be before a rule deletes the element. Half is a coin
toss, and a sheet built on coin tosses eats the article."
  'group 'web 'type 'float)

(defcustom 'xslt-token-max 40
  "A class token on more elements than this is a layout utility, not a name. Below it, a shared token is a rule for the whole family: news18 carries one token on fourteen ad slots, and one line deletes all of them. Each rule's note says how many elements it reaches, so a sheet that deletes too much says so before anyone saves it."
  'group 'web 'type 'integer)

(defcustom 'xslt-content-min 400
  "The walk descends into an element with this many characters."
  'group 'web 'type 'integer)

(defcustom 'xslt-links-min 12
  "The walk also descends into an element with this many links, whatever
its text volume. Text alone is the wrong gate: Wikipedia hangs its
language menu inside the article's own header, 42 links in 393
characters, seven under the text bound. A box of many links and little
text is a menu, and a menu is what a reading wants gone."
  'group 'web 'type 'integer)

(defcustom 'xslt-level-max 24
  "How many elements one JEV call judges. The largest go first."
  'group 'web 'type 'integer)

(defcustom 'xslt-fanout-max 64
  "How many speculative elements one call judges below the first level.
These are questions about boxes that may turn out to sit inside deleted
furniture, and the answer is then thrown away. They are free in time and
cheap in tokens, so the bound is loose."
  'group 'web 'type 'integer)

(defcustom 'xslt-learn-levels 6
  "How deep a learn walks. A site that wraps its page in framework boxes
puts real furniture well below the top: Wikipedia hangs its language menu
inside the article's own header, five levels down. Since every level goes
in one call, depth no longer costs a round trip, and xslt-question-max is
the bound that matters."
  'group 'web 'type 'integer)

(defcustom 'xslt-question-max 96
  "How many elements one learn judges in all. This is the real bound on a
learn, because depth is free and width is not: a news front page is a
grid of cards and its third level alone holds sixty boxes, while an
article's whole tree holds forty. Shallow levels are asked first, so the
budget runs out at the bottom, where the furniture is not."
  'group 'web 'type 'integer)

;;; --- the table ----------------------------------------------------------------
;;; discover.xsl answers text, so everything in this section is string work.
;;; It runs without a browser, a network or an API key.

(domain! 'web)
(effects! '(pure))

(define *xslt-fields*
  '(path d tag id cls role aria len a img tags toks sample))

(define (xslt--num s)
  (let ((n (string->number (or s "0"))))
    (if (number? n) n 0)))

;; ascending by KEY, a number. A level holds tens of rows, not thousands.
(define (xslt--insert x acc key)
  (cond ((null? acc) (list x))
        ((<= (key x) (key (car acc))) (cons x acc))
        (else (cons (car acc) (xslt--insert x (cdr acc) key)))))

(define (xslt--sort-by rows key)
  (let loop ((rs rows) (acc '()))
    (if (null? rs) acc (loop (cdr rs) (xslt--insert (car rs) acc key)))))

;; "tok:4 other:1" becomes (("tok" 4) ("other" 1))
(define (xslt--toks s)
  (let loop ((parts (string-split (or s "") " ")) (acc '()))
    (if (null? parts)
        (reverse acc)
        (let* ((p (car parts))
               (cut (string-index p ":")))
          (loop (cdr parts)
                (if cut
                    (cons (list (substring p 0 cut)
                                (xslt--num (substring p (+ cut 1) (string-length p))))
                          acc)
                    acc))))))

(define (xslt--row line)
  (let loop ((fs *xslt-fields*) (vs (string-split line "|")) (acc '()))
    (if (null? fs)
        (reverse acc)
        (let ((v (if (null? vs) "" (car vs))))
          (loop (cdr fs)
                (if (null? vs) '() (cdr vs))
                (cons (cond ((member (car fs) '(d len a img tags)) (xslt--num v))
                            ((equal? (car fs) 'toks) (xslt--toks v))
                            (else v))
                      (cons (car fs) acc)))))))

;; a row has every field. xsltproc writes its errors to the same stream, and
;; an error line holds no separators, so it never becomes a row.
(define (xslt-rows text)
  (filter (lambda (r) (not (equal? (plist-get r 'path) "")))
          (map xslt--row
               (filter (lambda (l)
                         (= (length (string-split l "|")) (length *xslt-fields*)))
                       (string-split (or text "") "\n")))))

;; the rows one level below PARENT, largest first. PARENT #f means body.
(define (xslt-children rows parent)
  (let* ((d (if parent (+ 1 (plist-get parent 'd)) 0))
         (under (if parent (string-append (plist-get parent 'path) "/") ""))
         (kids (filter (lambda (r)
                         (and (= (plist-get r 'd) d)
                              (or (not parent)
                                  (string-prefix? under (plist-get r 'path)))))
                       rows)))
    (xslt--sort-by kids (lambda (r) (- 0 (plist-get r 'len))))))

;;; --- a match pattern ----------------------------------------------------------
;;; A rule has to address the node in libxml2's parse of the raw bytes. An id
;;; or a rare class token does that. A positional path is the last resort: a
;;; page that changes moves every position.

;; XPath 1.0 has no escape inside a string literal, so a value that holds a
;; quote is not addressable this way.
(define (xslt--plain? s)
  (and (string? s)
       (not (equal? s ""))
       (not (re-match? "['\"<>&]" s))))

;; class is a token list, so the rule tests the token. Without this, 'ad'
;; matches 'header-loaded'.
(define (xslt--class-test tok)
  (string-append "contains(concat(' ', normalize-space(@class), ' '), ' " tok " ')"))

;; the rarest addressable token; the longest name breaks a tie
;; A class token earns a rule only when it is a word: lowercase letters
;; and hyphens. "content-footer" and "ad-slot" are names a person chose
;; and a deploy keeps. "dcr-1uu0ds5", "sc-bdVaJa" and "css-1x2y3z" are
;; what a CSS compiler emitted this build, and a sheet built on one of
;; them is dead the next time the site ships.
(define (xslt--word? s)
  (and (string? s) (not (equal? s "")) (re-match? "^[a-z][a-z-]*$" s)))

(define (xslt--token row)
  (let ((ok (filter (lambda (t)
                      (and (<= (cadr t) xslt-token-max) (xslt--word? (car t))))
                    (plist-get row 'toks))))
    (if (null? ok)
        #f
        (car (car (xslt--sort-by
                    ok
                    (lambda (t) (- (* 1000 (cadr t)) (string-length (car t))))))))))

(define *xslt-semantic* '("nav" "header" "footer" "aside" "main" "form" "dialog"))

(define (xslt-pattern row)
  (let ((tag (plist-get row 'tag))
        (id (plist-get row 'id))
        (aria (plist-get row 'aria))
        (tok (xslt--token row)))
    (cond ((xslt--plain? id) (string-append tag "[@id='" id "']"))
          (tok (string-append tag "[" (xslt--class-test tok) "]"))
          ((xslt--plain? aria) (string-append tag "[@aria-label='" aria "']"))
          ((and (= (plist-get row 'tags) 1) (member tag *xslt-semantic*)) tag)
          (else (plist-get row 'path)))))

;;; --- the sheet ----------------------------------------------------------------
;;; Copy everything, then delete. The identity template is the whole reason
;;; this is cheap: a new rule is one line and affects nothing else.

(define (xslt--comment s)
  (string-replace (or s "") "--" "-"))

;; Framework markup wraps the part that has a name in parts that have none.
;; news18 puts its footer inside a bare div, and its ad slots two bare divs
;; deep. Dropping the wrapper needs a positional path, which the next deploy
;; moves; dropping the named descendant needs one token. The wrapper survives
;; empty, and an empty div reads as nothing.
(define (xslt--positional? row)
  (string-prefix? "/" (xslt-pattern row)))

;; a part small enough to stand for the whole is not the whole
(define (xslt--stands-for? row kid)
  (let ((len (plist-get row 'len)))
    (or (= len 0) (>= (* 10 (plist-get kid 'len)) (* 9 len)))))

;; ROW itself when it has a name, else the named part inside it. news18 puts
;; its ad slots two bare divs deep, so the search goes two levels.
(define (xslt--target rows row depth)
  (if (or (not (xslt--positional? row)) (>= depth 2))
      row
      (let loop ((kids (filter (lambda (k) (xslt--stands-for? row k))
                               (xslt-children rows row))))
        (if (null? kids)
            row
            (let ((t (xslt--target rows (car kids) (+ depth 1))))
              (if (xslt--positional? t) (loop (cdr kids)) t))))))

;; how many elements the rule deletes, when the walk can tell
(define (xslt--reach row)
  (let ((tok (xslt--token row)))
    (if (and tok (not (xslt--plain? (plist-get row 'id))))
        (cadr (car (filter (lambda (t) (equal? (car t) tok))
                           (plist-get row 'toks))))
        1)))

(define (xslt--note row target)
  (string-append
    (plist-get row 'tag)
    (if (equal? (plist-get row 'id) "")
        "" (string-append " #" (plist-get row 'id)))
    (if (equal? (plist-get row 'aria) "")
        "" (string-append " " (plist-get row 'aria)))
    ", " (number->string (plist-get row 'len)) " chars, p="
    (number->string (plist-get row 'p))
    (if (equal? (plist-get target 'path) (plist-get row 'path))
        ""
        (string-append "; named by its " (plist-get target 'tag)))
    (let ((n (xslt--reach target)))
      (if (> n 1)
          (string-append "; deletes " (number->string n) " elements")
          ""))))

(define (xslt--drop rows row)
  (let ((target (xslt--target rows row 0)))
    (list (xslt-pattern target) (xslt--note row target))))

(define (xslt--rule d)
  (string-append "\n  <!-- " (xslt--comment (cadr d)) " -->\n"
                 "  <xsl:template match=\"" (car d) "\" mode=\"copy\"/>\n"))

(define (xslt-stylesheet keep drops)
  (string-append
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    "<xsl:stylesheet version=\"1.0\" xmlns:xsl=\"http://www.w3.org/1999/XSL/Transform\">\n"
    ;; What to do with what is left is the same for every site, so it is
    ;; one sheet beside this one. Fixing a rule there fixes every site
    ;; learned so far, and nothing is learned again.
    "  <xsl:import href=\"common.xsl\"/>\n\n"
    "  <xsl:template match=\"/\">\n"
    "    <html><body>\n"
    "      <xsl:apply-templates select=\"" keep "\" mode=\"copy\"/>\n"
    "    </body></html>\n"
    "  </xsl:template>\n"
    (apply string-append (map xslt--rule drops))
    "</xsl:stylesheet>\n"))

;;; --- the question -------------------------------------------------------------

(define (xslt-row-text row)
  (string-append
    "<" (plist-get row 'tag)
    " class=\"" (plist-get row 'cls) "\""
    " id=\"" (plist-get row 'id) "\""
    " role=\"" (plist-get row 'role) "\""
    " aria-label=\"" (plist-get row 'aria) "\">"
    "  text-chars=" (number->string (plist-get row 'len))
    " links=" (number->string (plist-get row 'a))
    " images=" (number->string (plist-get row 'img))
    "  text-starts: " (plist-get row 'sample)))

(define *xslt-question*
  (string-append
    "\n\nIs this element page furniture that a reader does not want -- "
    "navigation, masthead, footer, advertising, sponsored promotion, "
    "subscription or premium upsell, cookie or consent notice, social share "
    "widget, fixed overlay, skip link -- rather than the content the reader "
    "came for?"))

(define (xslt--key i)
  (string->symbol (string-append "c" (number->string i))))

(define (xslt-questions rows)
  (let loop ((rs rows) (i 0) (acc '()))
    (if (null? rs)
        (reverse acc)
        (loop (cdr rs) (+ i 1)
              (cons (jev-noul (string-append "Element " (number->string i)
                                             " of the page is:\n"
                                             (xslt-row-text (car rs))
                                             *xslt-question*))
                    (cons (xslt--key i) acc))))))

;;; --- the judgement ------------------------------------------------------------

(domain! 'web)
(effects! '(read external execute spend))

;; every row comes back with 'p: how sure JEV is that it is furniture
(define (xslt-score rows state)
  (let ((reply (jev-systemone state (xslt-questions rows))))
    (let loop ((rs rows) (i 0) (acc '()))
      (if (null? rs)
          (reverse acc)
          (loop (cdr rs) (+ i 1)
                (cons (append (car rs)
                              (list 'p (or (and reply
                                                (jev-answer-noul reply (xslt--key i)))
                                           0)))
                      acc))))))

(define (xslt--state url)
  (string-append
    "The page is " url ". Judge each element by its tag, class, id, role, "
    "aria-label, text volume, link density and opening text. An element with "
    "no text and an ad-serving class or id is an ad slot."))

;; the XSLT processor. web.scm names the same one for the reading pipeline.
(define (xslt--tool) "xsltproc")

;; discovery is one process: the walk stylesheet over the fetched bytes.
;; web.scm already writes the body to a file for its own pipeline.
(define (xslt--discover-command file)
  (string-append (xslt--tool) " --html --stringparam depth "
                 (number->string xslt-discover-depth) " "
                 (sh-quote (locate-library "web/discover.xsl")) " "
                 (sh-quote file)))

(define (xslt-discover html)
  (xslt-rows (shell-command->string (xslt--discover-command (web--write-html! html)))))

;; Run any stylesheet over a page and answer what it prints. discover.xsl
;; is one such sheet and the learner's own use of it is the first caller;
;; an app whose listing comes from an extractive sheet is the second, and
;; it needs no wrapper of its own to get there. SHEET is a load-path name
;; the way locate-library reads one.
(define (xslt-apply sheet html)
  (let ((path (locate-library sheet)))
    (and path
         (shell-command->string
           (string-append (xslt--tool) " --html " (sh-quote path) " "
                          (sh-quote (web--write-html! html)) " 2>/dev/null")))))

;; A direct child of body keeps its place: the header, the footer and the
;; rails are where the document starts and ends, and /html/body/footer[1]
;; still names the footer after a redesign. Deeper down a position is the
;; shape of one fetch and nothing more.
(define (xslt--shallow-path? p)
  (<= (length (filter (lambda (s) (not (equal? s ""))) (string-split p "/"))) 3))

;; A rule the sheet can trust addresses its element by a name — an id, a
;; class token that is a word, an aria-label, a lone semantic tag — or by
;; a place at the top of the document, and says something no earlier rule
;; said. A rule that can only point deep into this one fetch is left out:
;; a page read with one rule missing beats a page a drifted rule deleted.
(define (xslt--keep-drops rows furniture drops)
  (let loop ((rs furniture) (acc drops))
    (if (null? rs)
        acc
        (let ((d (xslt--drop rows (car rs))))
          (loop (cdr rs)
                (if (or (and (string-prefix? "/" (car d))
                             (not (xslt--shallow-path? (car d))))
                        (assoc (car d) acc))
                    acc
                    (cons d acc)))))))

;; the sheet for URL, learned from HTML. Answers a plist: the text to save,
;; what it deletes, and what the learning cost.
;; A page with one root div is not a page with one section. A level that
;; is a single box holding the rest is the framework's wrapper, and a
;; wrapper is not a decision: step through it without spending a level.
;; Without this a single-root page answers two questions and learns
;; nothing, because both levels went on boxes with one child each.
(define (xslt--unwrap rows level)
  (if (and (= (length level) 1) (pair? (xslt-children rows (car level))))
      (xslt--unwrap rows (xslt-children rows (car level)))
      level))

;; every level one learn asks about, outermost first, chosen from the walk
;; and nothing else. The walk already holds the whole tree, so which boxes a
;; deeper level could reach is known before any answer comes back. Descent
;; here is bounded by text volume alone: whether a box is content is the
;; question, and waiting for it is the round trip this deletes.
(define (xslt--levels rows)
  (let loop ((level (xslt--unwrap rows (xslt-children rows #f)))
             (depth 0) (spent 0) (acc '()))
    (if (or (null? level) (>= depth xslt-learn-levels) (>= spent xslt-question-max))
        (reverse acc)
        (let* ((room (min (if (= depth 0) xslt-level-max xslt-fanout-max)
                          (- xslt-question-max spent)))
               (ask (take-n level room))
               (over (- (length level) (length ask))))
          ;; a bounded level is a bounded reading: say what went unjudged
          (if (> over 0)
              (message (string-append "xslt-learn: " (number->string over)
                                      " smaller elements not judged at level "
                                      (number->string depth)))
              #f)
          (loop (xslt--unwrap rows
                  (xslt--sort-by
                    (apply append
                           (map (lambda (r) (xslt-children rows r))
                                (filter (lambda (r)
                                          (or (>= (plist-get r 'len) xslt-content-min)
                                              (>= (plist-get r 'a) xslt-links-min)))
                                        ask)))
                    (lambda (r) (- 0 (plist-get r 'len)))))
                (+ depth 1)
                (+ spent (length ask))
                (cons ask acc))))))

(define (xslt--under? parent row)
  (string-prefix? (string-append (plist-get parent 'path) "/")
                  (plist-get row 'path)))

;; one flat list of answers split back into the levels it was asked in
(define (xslt--regroup rows lens)
  (if (null? lens)
      '()
      (cons (take-n rows (car lens))
            (xslt--regroup (list-tail rows (car lens)) (cdr lens)))))

;; A box the model called furniture, whose text is mostly one part it called
;; content, is a wrapper around the article and not furniture. Deleting it
;; deletes the page. Only a fan-out learn can doubt a box this way: the
;; answer for the part arrives in the same call as the answer for the whole,
;; so the second opinion costs nothing and is already in hand.
;; libxml2 reads a `<` before a letter as the start of a tag, and a page
;; that inlines JavaScript has plenty: amazon.in writes `i<linkKeys.length`
;; and the parse grows elements named "length" and "linkkeys.length" that
;; no browser has. One of them swallowed 546,736 of the shop's 1,058,311
;; characters, the learn judged it furniture at p=0.73, and the sheet it
;; wrote deleted half of amazon.in. A name no browser knows is a parse
;; artefact and not a thing on the page: judge what is inside it, and never
;; write a rule against it.
(define *xslt-elements*
  '("a" "abbr" "address" "area" "article" "aside" "audio" "b" "base" "bdi" "bdo"
    "blockquote" "body" "br" "button" "canvas" "caption" "cite" "code" "col"
    "colgroup" "data" "datalist" "dd" "del" "details" "dfn" "dialog" "div" "dl"
    "dt" "em" "embed" "fieldset" "figcaption" "figure" "footer" "form" "h1" "h2"
    "h3" "h4" "h5" "h6" "head" "header" "hgroup" "hr" "html" "i" "iframe" "img"
    "input" "ins" "kbd" "label" "legend" "li" "link" "main" "map" "mark" "menu"
    "meta" "meter" "nav" "noscript" "object" "ol" "optgroup" "option" "output"
    "p" "param" "picture" "pre" "progress" "q" "rp" "rt" "ruby" "s" "samp"
    "script" "search" "section" "select" "slot" "small" "source" "span" "strong"
    "style" "sub" "summary" "sup" "svg" "table" "tbody" "td" "template"
    "textarea" "tfoot" "th" "thead" "time" "title" "tr" "track" "u" "ul" "var"
    "video" "wbr"
    ;; still shipped, still parsed
    "acronym" "big" "center" "dir" "font" "frame" "frameset" "marquee"
    "noframes" "strike" "tt"))

(define (xslt--element? tag) (and (member tag *xslt-elements*) #t))

;; The page's title is not furniture, and a box is not furniture for
;; holding it. Wikipedia hangs its language menu in the same header as the
;; h1, so the one rule that deletes the menu deletes the title with it.
;; Leave that box alone and the level below it takes the menu by name.
(define (xslt--holds-the-title? rows row)
  (let ((h1s (filter (lambda (r) (equal? (plist-get r 'tag) "h1")) rows)))
    (and (= (length h1s) 1) (xslt--under? row (car h1s)))))

(define (xslt--vetoed? row deeper cut)
  (let ((len (plist-get row 'len)))
    (and (> len 0)
         (pair? (filter (lambda (k)
                          (and (xslt--under? row k)
                               (<= (plist-get k 'p) (- 1 cut))
                               (>= (plist-get k 'len) xslt-content-min)
                               (>= (* 2 (plist-get k 'len)) len)))
                        deeper)))))

(define (xslt-learn url html)
  (let* ((rows (xslt-discover html))
         (levels (xslt--levels rows))
         (ask (apply append levels))
         (scored (if (null? ask) '() (xslt-score ask (xslt--state url))))
         (graded (xslt--regroup scored (map length levels)))
         (cut xslt-chrome-threshold))
    (let loop ((ls graded) (deleted '()) (drops '()))
      (if (null? ls)
          (list 'sheet (xslt-stylesheet "//body" (reverse drops))
                'drops (reverse drops)
                'rows (length rows)
                'calls (if (null? ask) 0 1)
                'asked (length ask))
          (let* ((deeper (apply append (cdr ls)))
                 ;; a speculative answer counts only when every box above it
                 ;; was content. An answer about a box inside one already
                 ;; deleted says nothing: the rule above it removed both.
                 (live (filter (lambda (r)
                                 (null? (filter (lambda (d) (xslt--under? d r))
                                                deleted)))
                               (car ls)))
                 (furniture (filter (lambda (r)
                                      (and (>= (plist-get r 'p) cut)
                                           (xslt--element? (plist-get r 'tag))
                                           (not (xslt--vetoed? r deeper cut))
                                           (not (xslt--holds-the-title? rows r))))
                                    live)))
            (loop (cdr ls)
                  (append deleted furniture)
                  (xslt--keep-drops rows furniture drops)))))))

;;; --- keeping it ---------------------------------------------------------------

(domain! 'web)
(effects! '(write))

(define (xslt--parsers-dir)
  (let ((dir (string-append (compos-home) "/packages/web/parsers/")))
    (make-directory! dir)
    dir))

(define (xslt--host url) (web--parser-host url))

;; A learned sheet is the reader's, not the editor's: it lives under
;; ~/.compos/packages/web/parsers, which is on the load path after the
;; bundled parsers, so a stylesheet a person wrote still wins.
;;
;; save SHEET as web/parsers/HOST.xsl. The file is the registration:
;; web--host-parser finds it by name, so the next visit reads the page
;; through it and asks JEV nothing, this session and every later one.
(define (xslt-save! url sheet)
  (let* ((dir (xslt--parsers-dir))
         (path (string-append dir (xslt--host url) ".xsl")))
    ;; the sheet imports common.xsl by a relative name, so the common
    ;; rules travel with it. Copied on every save: a learned sheet reads
    ;; through the rules this editor has now, not the ones it had then.
    (write-file! (string-append dir "common.xsl")
                 (read-file (locate-library "web/parsers/common.xsl")))
    (write-file! path sheet)
    path))

;;; --- learning on the way past --------------------------------------------------

(domain! 'web)
(effects! '(read external execute spend write))

;; the hosts this session has already spent a learn on, whether it
;; worked or not. A site that teaches nothing must not be asked twice.
(define *xslt-tried* '())

(defcustom 'xslt-learn-timeout 60000
  "How long a learn may take before the page gives up on it, in milliseconds."
  'group 'web 'type 'number)

;; learn URL's sheet off the lane and save it, then call (K PATH) — or
;; (K #f) when there is nothing to learn, nothing was learnt, or the
;; host has been asked already. A learn is one walk and one model
;; call; the page waits for it once and never again.
(define (xslt-learn-site! url html k)
  (let ((host (xslt--host url)))
    (if (member host *xslt-tried*)
        (k #f)
        (begin
          (set! *xslt-tried* (cons host *xslt-tried*))
          (task-run!
            (lambda () (xslt-learn url html))
            (lambda (ok result)
              (let ((drops (and ok (pair? result) (plist-get result 'drops))))
                (if (and drops (pair? drops))
                    (let ((path (xslt-save! url (plist-get result 'sheet))))
                      (message (string-append "learned " host ".xsl: "
                                              (number->string (length drops))
                                              " rules"))
                      (k path))
                    (k #f))))
            xslt-learn-timeout)))))

;; The sheet a site already has may be the wrong one: a redesign moves
;; the furniture, and a first learn can miss. This forgets both and
;; learns the page on screen again.
(define-command "browse-learn-parser" "Learn this page's site parser again, replacing the one on disk"
  (lambda ()
    (let* ((buf (current-buffer))
           (url (buffer-local-value 'browse-url buf))
           (html (buffer-local-value 'browse-html buf)))
      (cond ((not url) (message "no page here"))
            ((not (string? html)) (message "no source held for this page; g refetches it"))
            (else
              (let ((host (xslt--host url)))
                (set! *xslt-tried* (filter (lambda (h) (not (equal? h host))) *xslt-tried*))
                (message (string-append "learning " host " …"))
                (xslt-learn-site! url html
                  (lambda (path)
                    (if path
                        (web--reread! buf)
                        (message "learned nothing from this page"))))))))))

;;; --- the catalog --------------------------------------------------------------

(domain! 'web)
(effects! '(read external execute spend))

(public! 'xslt-learn
  "(xslt-learn URL HTML) - learn a site parser: walk the page, ask JEV what is furniture, answer (sheet TEXT drops ((PATTERN NOTE) ...) rows N calls N asked N)")
(public! 'xslt-discover
  "(xslt-discover HTML) - the page's structure as rows: path, depth, tag, id, class, role, aria, chars, links, images, tag count, class tokens, sample")
(public! 'xslt-apply
  "(xslt-apply SHEET HTML) - run the stylesheet named on the load path over HTML and answer what it prints")
(public! 'xslt-score
  "(xslt-score ROWS STATE) - every row back with 'p, how sure JEV is that it is page furniture")

(domain! 'web)
(effects! '(pure))

(public! 'xslt-pattern
  "(xslt-pattern ROW) - the XSLT match pattern that addresses ROW: an id, a rare class token, an aria-label, a lone semantic tag, else its position")
(public! 'xslt-stylesheet
  "(xslt-stylesheet KEEP DROPS) - a stylesheet that copies KEEP and deletes each (PATTERN NOTE) in DROPS")
(public! 'xslt-rows
  "(xslt-rows TEXT) - the walk stylesheet's table as plists")
(public! 'xslt-children
  "(xslt-children ROWS PARENT) - the rows one level below PARENT, largest first; PARENT #f means body")
(public! 'xslt-row-text
  "(xslt-row-text ROW) - one row as the line a classifier reads")

(domain! 'web)
(effects! '(write))

(public! 'xslt-save!
  "(xslt-save! URL SHEET) - write SHEET as web/parsers/HOST.xsl, which is how a site registers a learned parser; answers the path")

(domain! 'web)
(effects! '(read external execute spend write))

(public! 'xslt-learn-site!
  "(xslt-learn-site! URL HTML K) - learn and save URL's site parser off the lane, once per host; K gets the path, or #f")
