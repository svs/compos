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
    (check-true! (t--md-has? '(4 8 "link link-to:https%3A%2F%2Fx.y"))
                 "the text is the link, and it names its target")
    (check-true! (t--md-has? '(8 22 "md-marker")) "the target steps back")
    (t--md-done!)))

(deftest 'a-line-that-is-one-x-post-url-draws-as-the-card
  "the whole line wears x-embed and nothing else"
  (lambda ()
    (t--md-fresh! "https://x.com/svs/status/1234567890\n")
    (check-true! (t--md-has? '(0 35 "x-embed")) "the URL is the card")
    (t--md-done!)))

(deftest 'an-x-post-url-with-a-share-suffix-still-draws-as-the-card
  "the share sheet's ?s=20 names the same post"
  (lambda ()
    (t--md-fresh! "https://x.com/svs/status/1234567890?s=20\n")
    (check-true! (t--md-has? '(0 40 "x-embed")) "the URL is the card")
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

(deftest 'an-indented-block-is-code-and-aligned-columns-are-a-table
  "the indent steps back; words in shared columns make a table, a head row
   without digits is bold, and prose-shaped code stays code"
  (lambda ()
    (t--md-fresh! (string-append "para\n\n"
                                 "    name   score  rank\n"
                                 "    alpha  1.00   1\n"
                                 "    beta   0.50   2\n\n"
                                 "text\n\n"
                                 "    select a from b\n"))
    (check-true! (t--md-has? '(6 28 "row-code")) "an indented line is code")
    (check-true! (t--md-has? '(6 10 "md-marker")) "and its indent steps back")
    (check-true! (t--md-has? '(6 28 "row-table-aligned")) "the columns make a table")
    (check-true! (t--md-has? '(6 28 "row-table-aligned-head")) "the first row is the head")
    (check-true! (t--md-has? '(29 48 "row-table-aligned")) "a body row is a table row")
    (check-false! (t--md-has? '(29 48 "row-table-aligned-head")) "and not the head")
    (check-true! (t--md-has? '(76 95 "row-code")) "the second block is code")
    (check-false! (t--md-has? '(76 95 "row-table-aligned")) "one line of code is no table")
    (check-false! (t--md-has? '(0 4 "row-code")) "a paragraph is not code")
    (t--md-done!)))

(deftest 'a-table-fence-colors-cells-by-its-rules
  "a value rule and a number threshold each color the cell they match"
  (lambda ()
    ;; offsets count from the buffer start; the body starts at 42
    (t--md-fresh! "```table green=strong red=unfit green>=.5\n| unfit | .64 |\n| strong | .2 |\n```\n")
    (check-true! (t--md-has? '(44 49 "table-red")) "unfit takes red")
    (check-true! (t--md-has? '(52 55 "table-green")) ".64 passes the threshold")
    (check-true! (t--md-has? '(60 66 "table-green")) "strong takes green")
    (check-false! (t--md-has? '(69 71 "table-green")) ".2 is under the threshold")
    (t--md-done!)))

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
    (check-true! (t--md-has? '(15 28 "row-conceal")) "the page hides the rule row")
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

(deftest 'a-fence-with-a-fence-face-shows-its-own-line
  "the backticks step back; the kind, state and keys stay, in the face"
  (lambda ()
    (t--md-fresh! "```diff theirs\n+x\n```\n")
    (check-true! (t--md-has? '(0 3 "md-marker")) "the backticks step back")
    (check-true! (t--md-has? '(3 14 "diff-file"))
                 "the info string stays visible in the kind's face")
    (t--md-done!)))

(deftest 'a-csv-block-draws-as-a-table
  "commas are column bars, the first row is the head, the rows wear row-csv"
  (lambda ()
    (t--md-fresh! "```result-csv\nname,\"a,b\",n\nx,y,1\n```\n")
    ;; the head row is bytes 14..26: name,"a,b",n; the body row is 27..32
    (check-true! (t--md-has? '(14 26 "row-table")) "the head row is a table row")
    (check-true! (t--md-has? '(14 26 "row-table-head")) "and it is the head")
    (check-true! (t--md-has? '(14 26 "row-csv")) "and a csv row")
    (check-true! (t--md-has? '(18 19 "md-table-bar")) "the first comma is a bar")
    (check-false! (t--md-has? '(21 22 "md-table-bar")) "a comma inside quotes is text")
    (check-true! (t--md-has? '(24 25 "md-table-bar")) "the comma after the quoted field is a bar")
    (check-true! (t--md-has? '(27 32 "row-table")) "the body row is a table row")
    (check-false! (t--md-has? '(27 32 "row-table-head")) "and not a head")
    (t--md-done!)))

(deftest 'a-named-fence-shows-its-info
  "the backticks step back; the language stays, dim, and labels the block"
  (lambda ()
    (t--md-fresh! "```scheme\n(+ 1 1)\n```\n\n```result-scheme\n2\n```\n")
    (check-true! (t--md-has? '(0 3 "md-marker")) "the backticks step back")
    (check-true! (t--md-has? '(3 9 "md-fence")) "the language labels the block")
    (check-true! (t--md-has? '(18 21 "md-marker")) "a bare close fence conceals whole")
    (check-true! (t--md-has? '(26 39 "md-fence")) "and the result names itself")
    (t--md-done!)))


;;; --- markers and inline markup from the grammar ------------------------------

(deftest 'list-and-quote-markers-come-from-the-grammar
  "a bullet steps back, a number stays, and each quoted line is a quote row"
  (lambda ()
    (t--md-fresh! "- one\n1. two\n> three\n> four\n")
    (check-true! (t--md-has? '(0 2 "md-marker")) "the bullet steps back")
    (check-true! (t--md-has? '(0 5 "row-li")) "the bullet row")
    (check-true! (t--md-has? '(6 12 "row-oli")) "the numbered row")
    (check-true! (t--md-has? '(13 15 "md-marker")) "the quote marker")
    (check-true! (t--md-has? '(13 20 "row-quote")) "the quote row")
    (check-true! (t--md-has? '(21 23 "md-marker")) "the continued quote marker")
    (check-true! (t--md-has? '(21 27 "row-quote")) "the continued quote row")
    (t--md-done!)))

(deftest 'a-dash-line-in-a-fence-is-code-and-not-a-bullet
  "the grammar knows the fence: no list row inside it"
  (lambda ()
    (t--md-fresh! "```\n- x\n```\n")
    (check-false! (t--md-has? '(4 7 "row-li")) "no bullet row")
    (check-true! (t--md-has? '(4 7 "row-code")) "a code row")
    (t--md-done!)))

(deftest 'inline-code-and-emphasis-step-their-markers-back
  "a code span and both emphases paint the words and hide the delimiters"
  (lambda ()
    (t--md-fresh! "`x` *i* _u_ ``a`b``\n")
    (check-true! (t--md-has? '(0 1 "md-marker")) "the opening tick")
    (check-true! (t--md-has? '(1 2 "morg-code")) "the code")
    (check-true! (t--md-has? '(5 6 "morg-italic")) "star emphasis")
    (check-true! (t--md-has? '(9 10 "morg-italic")) "underscore emphasis")
    (check-true! (t--md-has? '(12 14 "md-marker")) "a double tick opens")
    (check-true! (t--md-has? '(14 17 "morg-code")) "and holds a tick")
    (t--md-done!)))

(deftest 'a-heading-keyword-keeps-its-face-in-the-preview
  "# TODO x: the marker steps back, TODO wears org-todo, the rest the level"
  (lambda ()
    (t--md-fresh! "# TODO fix it\n")
    (check-true! (t--md-has? '(0 2 "md-marker")) "the marker")
    (check-true! (t--md-has? '(2 6 "org-todo")) "the keyword")
    (check-true! (t--md-has? '(6 13 "md-h1")) "the words")
    (t--md-done!)))
