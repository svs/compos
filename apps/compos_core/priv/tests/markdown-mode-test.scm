;;; markdown-mode-test.scm --- what markdown-mode paints on the source.
;;;
;;; The faces are policy: a marker steps back, a heading takes its level, an
;;; image URL draws as the picture, an X post URL draws as the card. The
;;; test turns the paint on, then reads the overlays it painted.

(domain! 'testing)
(effects! '(write))

(define t--md-buf "*markdown-mode-test*")

(define (t--md-fresh! text)
  (test-buffer! t--md-buf text)
  (markdown-paint-on! t--md-buf)
  t--md-buf)

(define (t--md-done!)
  (markdown-paint-off! t--md-buf))

(define (t--md-has? span)
  (if (member span (buffer-overlays t--md-buf)) #t #f))

(deftest 'a-heading-marker-steps-back-and-the-text-takes-its-level
  "the # and the space wear md-marker; the words wear md-h1"
  (lambda ()
    (t--md-fresh! "# Title\n")
    (check-true! (t--md-has? '(0 2 "md-marker")) "the marker steps back")
    (check-true! (t--md-has? '(2 7 "md-h1")) "the text is the heading")
    (t--md-done!)))

(deftest 'every-atx-heading-level-conceals-its-complete-prefix
  "preview hides all heading hashes and the space after them"
  (lambda ()
    (t--md-fresh! "# One\n## Two\n### Three\n#### Four\n###### Six\n")
    (check-true! (t--md-has? '(0 2 "md-marker")) "level one")
    (check-true! (t--md-has? '(6 9 "md-marker")) "level two")
    (check-true! (t--md-has? '(13 17 "md-marker")) "level three")
    (check-true! (t--md-has? '(23 28 "md-marker")) "level four")
    (check-true! (t--md-has? '(33 40 "md-marker")) "level six")
    (t--md-done!)))

(deftest 'fence-markers-step-back-with-other-preview-markup
  "the opening and closing backticks use the concealed marker face"
  (lambda ()
    (t--md-fresh! "```elixir\n:ok\n```\n")
    (check-true! (t--md-has? '(0 9 "md-marker")) "the opening fence")
    (check-true! (t--md-has? '(14 17 "md-marker")) "the closing fence")
    (t--md-done!)))

(deftest 'emphasis-markers-step-back-around-the-emphasized-text
  "**b** paints two markers and one bold run"
  (lambda ()
    (t--md-fresh! "a **b** c\n")
    (check-true! (t--md-has? '(2 4 "md-marker")) "the opening ** is a marker")
    (check-true! (t--md-has? '(4 5 "morg-bold")) "b is bold")
    (check-true! (t--md-has? '(5 7 "md-marker")) "the closing ** is a marker")
    (t--md-done!)))

(deftest 'an-image-url-draws-as-the-picture
  "![alt](pic.png): the URL wears img-embed, the rest steps back"
  (lambda ()
    (t--md-fresh! "see ![alt](pic.png) here\n")
    ;; "see " = 4, "![alt](" = 7 -> the URL starts at 11 and is 7 bytes
    (check-true! (t--md-has? '(4 11 "md-marker")) "the head steps back")
    (check-true! (t--md-has? '(11 18 "img-embed")) "the URL is the picture")
    (check-true! (t--md-has? '(18 19 "md-marker")) "the tail steps back")
    (check-false! (t--md-has? '(5 10 "link")) "an image's link is not a link")
    (t--md-done!)))

(deftest 'a-link-keeps-its-text-and-hides-its-target
  "[text](url): the text is the link, the brackets and the target step back"
  (lambda ()
    (t--md-fresh! "go [home](https://x.y) now\n")
    (check-true! (t--md-has? '(3 4 "md-marker")) "the bracket steps back")
    (check-true! (t--md-has? '(4 8 "link")) "the text is the link")
    (check-true! (t--md-has? '(8 22 "md-marker")) "the target steps back")
    (t--md-done!)))

(deftest 'a-line-that-is-one-x-post-url-draws-as-the-card
  "the whole line wears x-embed and nothing else"
  (lambda ()
    (t--md-fresh! "https://x.com/svs/status/1234567890\n")
    (check-true! (t--md-has? '(0 35 "x-embed")) "the URL is the card")
    (t--md-done!)))

(deftest 'a-youtube-embed-directive-draws-as-the-card
  "the directive steps back and its URL wears youtube-embed"
  (lambda ()
    (t--md-fresh! "#+embed: https://youtu.be/dQw4w9WgXcQ?t=43\n")
    (check-true! (t--md-has? '(0 9 "md-marker")) "the directive steps back")
    (check-true! (t--md-has? '(9 42 "youtube-embed")) "the URL is the card")
    (t--md-done!)))

(deftest 'a-standalone-bare-youtube-url-draws-as-a-card
  "a pasted URL embeds when it occupies the complete line"
  (lambda ()
    (t--md-fresh! "https://youtu.be/dQw4w9WgXcQ?t=43\n")
    (check-true! (t--md-has? '(0 33 "youtube-embed")) "the URL is the card")
    (t--md-done!)))

(deftest 'an-inline-youtube-url-does-not-draw-as-a-card
  "a URL inside prose stays a link"
  (lambda ()
    (t--md-fresh! "watch https://youtu.be/dQw4w9WgXcQ now\n")
    (check-false! (t--md-has? '(6 34 "youtube-embed")) "the URL stays text")
    (t--md-done!)))

(deftest 'cutting-and-yanking-a-youtube-card-repaints-the-url
  "cut and yank edit plain source; preview mode derives the card"
  (lambda ()
    (let ((url "https://youtu.be/dQw4w9WgXcQ"))
      (t--md-fresh! (string-append url "\n"))
      (with-current-buffer t--md-buf
        (lambda ()
          (set-mark! 0)
          (goto-char! (string-byte-length url))
          (run-command "kill-region")))
      (check-equal! (buffer-text t--md-buf) "\n" "cut removes the source URL")
      (with-current-buffer t--md-buf (lambda () (run-command "yank")))
      (check-equal! (buffer-text t--md-buf) (string-append url "\n")
                    "yank restores only the source URL")
      (check-true!
        (wait-until (lambda () (t--md-has? '(0 28 "youtube-embed"))) 2000 20)
        "preview mode repaints the restored URL")
      (t--md-done!))))

(deftest 'a-table-takes-its-columns-from-the-bars
  "the head, the rule and the body rows each take their row face; every bar
   is a column boundary and the space that pads a cell steps back"
  (lambda ()
    (t--md-fresh! "| Path | Use |\n| --- | --- |\n| a | b |\n\n| lonely |\n")
    (check-true! (t--md-has? '(0 14 "row-table")) "the head row is a table row")
    (check-true! (t--md-has? '(0 14 "row-table-head")) "and it is the head")
    (check-true! (t--md-has? '(0 1 "md-table-bar")) "the opening bar is a column")
    (check-true! (t--md-has? '(7 8 "md-table-bar")) "so is the bar between cells")
    (check-true! (t--md-has? '(1 2 "md-marker")) "the space before a cell steps back")
    (check-true! (t--md-has? '(6 7 "md-marker")) "and the space after it")
    (check-true! (t--md-has? '(15 28 "row-table-rule")) "the rule row draws the line")
    (check-true! (t--md-has? '(15 28 "md-marker")) "and its dashes step back")
    (check-true! (t--md-has? '(29 38 "row-table")) "a body row is a table row")
    (check-false! (t--md-has? '(40 50 "row-table"))
                  "a line of bars with no rule row under it stays text")
    (t--md-done!)))

(deftest 'turning-the-mode-off-takes-the-paint-with-it
  "teardown clears the markdown overlays"
  (lambda ()
    (t--md-fresh! "# Title\n")
    (t--md-done!)
    (check-false! (t--md-has? '(2 7 "md-h1")) "no heading face is left")))

(deftest 'a-bullet-and-a-quote-step-back-and-shape-the-row
  "the marker wears md-marker and the whole row wears its row face"
  (lambda ()
    (t--md-fresh! "- item\n> said\n---\n1. one\n")
    (check-true! (t--md-has? '(0 2 "md-marker")) "the bullet steps back")
    (check-true! (t--md-has? '(0 6 "row-li")) "the row is a list item")
    (check-true! (t--md-has? '(7 9 "md-marker")) "the quote marker steps back")
    (check-true! (t--md-has? '(7 13 "row-quote")) "the row is a quote")
    (check-true! (t--md-has? '(14 17 "row-hr")) "the rule row")
    (check-true! (t--md-has? '(18 24 "row-oli")) "an ordered item keeps its number")
    (t--md-done!)))

(deftest 'a-fence-line-wears-its-kind-as-a-chip
  "the backticks step back and a chrome chip names the block"
  (lambda ()
    (t--md-fresh! "```diff\n+x\n```\n")
    ;; the open fence is hidden and its chip stands behind its last byte
    (check-true! (t--md-has? '(0 7 "md-marker")) "the open fence steps back")
    (check-true! (t--md-has? (chrome-after 7 "diff" "md-fence-chip"))
                 "the chip stands at the fence line's end")
    ;; a bare fence (the close) draws no chip of its own
    (check-equal!
      (length (filter (lambda (o) (and (= (car o) (cadr o)))) 
                      (buffer-overlays t--md-buf)))
      1 "one chip: the close fence draws none")
    (t--md-done!)))

(deftest 'a-rewrite-chip-carries-its-instruction
  "a kind with chip-args says what the block was asked, in the preview"
  (lambda ()
    (t--md-fresh! "```rewrite use sentence case\nbody\n```\n")
    (check-true!
      (member (chrome-after 28 "rewrite · use sentence case" "md-fence-chip")
              (buffer-overlays t--md-buf))
      "the chip holds the kind and the instruction")
    (t--md-done!)))
