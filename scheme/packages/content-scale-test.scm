;;; content-scale-test.scm --- levels, folds and views, and the cache under them.
;;;
;;; No test here calls a model: summaries are put in the cache first.

(domain! 'testing)
(effects! '(write))

(define t--cs-buf "zz-content-scale")
(define t--cs-text "Alpha one\nalpha two\nalpha three\n\nBeta one\nbeta two\n\nGamma\n")

(define (t--cs!) (buffer-set-text! t--cs-buf t--cs-text) t--cs-buf)

(deftest 'content-cache-reads-through-and-copies-up
  "a disk hit lands in memory; a delete clears every sink"
  (lambda ()
    (let ((k (content-key "t--cs" 'copy-up)))
      (cache-put! 'zz-test k "v")
      (cache--call 'memory 'del 'zz-test k)
      (check-equal! (cache-get 'zz-test k) "v" "the disk sink answers")
      (check-equal! (cache--call 'memory 'get 'zz-test k) "v" "and memory holds it again")
      (cache-del! 'zz-test k)
      (check-false! (cache-get 'zz-test k) "gone from every sink"))))

(deftest 'content-cache-fetch-produces-once
  "two asks while the value is made share one producer"
  (lambda ()
    (let ((k (content-key "t--cs" 'once)) (calls 0) (got '()) (finish #f))
      (cache-fetch 'zz-test k (lambda (done) (set! calls (+ calls 1)) (set! finish done))
                   (lambda (v) (set! got (cons v got))))
      (cache-fetch 'zz-test k (lambda (done) (set! calls (+ calls 1)))
                   (lambda (v) (set! got (cons v got))))
      (finish "made")
      (check-equal! calls 1 "one producer")
      (check-equal! got '("made" "made") "both callers answered")
      (cache-del! 'zz-test k))))

(deftest 'content-scale-folds-paragraphs-to-their-first-line
  "level 1 hides every line after a paragraph's first, and level 0 shows them again"
  (lambda ()
    (t--cs!)
    (check-equal! (content-scale-paragraphs t--cs-buf) '((0 32) (33 51) (52 58)) "three paragraphs")
    (check-equal! (content-scale-set! t--cs-buf 'outline) 1 "a level by name")
    (check-equal! (fold-get t--cs-buf 'content-scale) '((9 31) (41 50)) "the one-line paragraph stays")
    (check-equal! (buffer-text t--cs-buf) t--cs-text "the bytes never change")
    (content-scale-set! t--cs-buf 0)
    (check-equal! (fold-get t--cs-buf 'content-scale) '() "level 0 is the text")
    (buffer-kill! t--cs-buf)))

(deftest 'content-scale-gists-come-from-the-cache
  "a cached gist draws as chrome on the paragraph's first line"
  (lambda ()
    (t--cs!)
    (let ((alpha (content-scale-part-text t--cs-buf '(0 32)))
          (beta (content-scale-part-text t--cs-buf '(33 51))))
      (cache-put! 'summarize (summarize--key alpha 'gist) "about alpha")
      (cache-put! 'summarize (summarize--key beta 'gist) "about beta")
      (content-scale-set! t--cs-buf 'gists)
      (check-equal! (map car (buffer-overlays t--cs-buf 'content-scale)) '(9 41) "one per folded paragraph")
      (check-true! (string-contains? (caddr (car (buffer-overlays t--cs-buf 'content-scale))) "about%20alpha")
                   "the gist is the chrome")
      (content-scale-set! t--cs-buf 0)
      (cache-del! 'summarize (summarize--key alpha 'gist))
      (cache-del! 'summarize (summarize--key beta 'gist))
      (buffer-kill! t--cs-buf))))

(deftest 'content-scale-view-is-hidden-and-goes-at-level-0
  "a summary level fills a space-named special view that no list shows"
  (lambda ()
    (t--cs!)
    (cache-put! 'summarize (summarize--key t--cs-text 'summary) "the summary")
    (content-scale-set! t--cs-buf 'summary)
    (let ((view (content-scale-view-name t--cs-buf)))
      (check-true! (string-contains? (buffer-text view) "the summary") "the view holds it")
      (check-equal! (content-scale-source view) t--cs-buf "the view knows its source")
      (check-equal! (map car (cadr (buffer-rows (list 'names (list view))))) '() "no list shows it")
      (content-scale-set! t--cs-buf 0)
      (check-false! (buffer-known? view) "level 0 kills it"))
    (cache-del! 'summarize (summarize--key t--cs-text 'summary))
    (buffer-kill! t--cs-buf)))

(deftest 'content-scale-steps-stop-at-the-edges
  "out and in walk the declared levels and stop at both ends"
  (lambda ()
    (t--cs!)
    (check-equal! (content-scale-step! t--cs-buf -1) #f "plain text declares nothing below 0")
    (check-equal! (content-scale-step! t--cs-buf 1) 1 "one out")
    (check-equal! (content-scale-set! t--cs-buf 'nonsense) #f "an unknown level is refused")
    (check-equal! (content-scale-level t--cs-buf) 1 "and changes nothing")
    (content-scale-set! t--cs-buf 0)
    (buffer-kill! t--cs-buf)))

(define t--as-buf "zz-anchor-scale")

(define (t--as!)
  (buffer-set-text! t--as-buf "Header line\nmore header\n\nSkills\nC++ Go Python\nRust\n\nEvidence\nline one\nline two\n" #t)
  (anchor-set! t--as-buf '(("Header" 0 24) ("Skills" 25 51 #f #f ((1 fold) (2 elide))) ("Evidence" 52 79)))
  (enable-minor-mode! t--as-buf "anchor-mode")
  t--as-buf)

(deftest 'anchor-scale-zooms-one-part
  "a part steps through the levels it declares and no further"
  (lambda ()
    (t--as!)
    (check-equal! (anchor-scale-set! t--as-buf "Skills" 1) 1 "folded")
    (check-equal! (fold-get t--as-buf 'anchor-scale) '((31 50)) "only Skills folds")
    (check-equal! (anchor-scale-set! t--as-buf "Skills" 9) 2 "clamped to its last level")
    (check-equal! (fold-get t--as-buf 'anchor-scale) '((24 50)) "elided")
    (check-equal! (anchor-scale-set! t--as-buf "Header" 2) 1 "no declaration folds at 1 only")
    (anchor-set! t--as-buf (anchor-list t--as-buf))
    (check-equal! (anchor-scale-of t--as-buf "Skills") 2 "a redraw keeps the zoom")
    (disable-minor-mode! t--as-buf "anchor-mode")
    (buffer-kill! t--as-buf)))

(deftest 'anchor-scale-page-levels-and-presets
  "the page level zooms every part, level 0 opens them, a saved level comes back by name"
  (lambda ()
    (t--as!)
    (let ((kept anchor-scale-presets))
      (check-equal! (map cadr (content-scale-levels t--as-buf)) '(card summary parts-2 outline) "levels from the parts")
      (content-scale-set! t--as-buf 'outline)
      (check-equal! (fold-get t--as-buf 'anchor-scale) '((11 23) (31 50) (60 78)) "every part folds")
      (content-scale-set! t--as-buf 0)
      (check-equal! (fold-get t--as-buf 'anchor-scale) '() "level 0 opens them")
      (anchor-scale-set! t--as-buf "Skills" 2)
      (check-equal! (anchor-scale-save! t--as-buf "zz-triage") 3 "saved above the part levels")
      (content-scale-set! t--as-buf 0)
      (content-scale-set! t--as-buf 'zz-triage)
      (check-equal! (anchor-scale-of t--as-buf "Skills") 2 "the saved level restores it")
      (customize-save! 'anchor-scale-presets kept))
    (disable-minor-mode! t--as-buf "anchor-mode")
    (buffer-kill! t--as-buf)))

(deftest 'anchor-scale-folds-blocks
  "on a block page a folded part keeps its first child and a gloss"
  (lambda ()
    (t--as!)
    (buffer-set-local! t--as-buf 'anchor-scale '(("Skills" 1)))
    (let* ((blk (list 'class "c-group" 'lines '(4 6)
                      'children (list (list 'lines '(4 4) 'text "Skills") (list 'lines '(5 5) 'text "C++"))))
           (out (car (anchor-scale-blocks t--as-buf (list blk)))))
      (check-equal! (length (plist-get out 'children)) 2 "heading and gloss")
      (check-equal! (plist-get (cadr (plist-get out 'children)) 'text) "…" "the gloss"))
    (buffer-set-local! t--as-buf 'anchor-scale '(("Skills" 2)))
    (check-equal! (anchor-scale-blocks t--as-buf (list (list 'lines '(4 6)))) '() "elide drops the block")
    (disable-minor-mode! t--as-buf "anchor-mode")
    (buffer-kill! t--as-buf)))
