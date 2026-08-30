;;; markdown-caption-test.scm --- a picture's caption in the rows, and *emphasis*.

(domain! 'testing)
(effects! '(write))

(define t--cap-buf "*markdown-caption-test*")

(define (t--cap-fresh! text)
  (test-buffer! t--cap-buf text)
  (markdown-paint-on! t--cap-buf)
  t--cap-buf)

(define (t--cap-done!)
  (markdown-paint-off! t--cap-buf))

(define (t--cap-has? span)
  (if (member span (buffer-overlays t--cap-buf)) #t #f))

(deftest 'a-line-of-emphasis-under-a-picture-is-its-caption
  "the stars step back, the words wear md-caption, and the row is a caption row"
  (lambda ()
    (t--cap-fresh! "![alt](a.png)\n*Ok, now what? *\n")
    (check-true! (t--cap-has? '(14 15 "md-marker")) "the opening star steps back")
    (check-true! (t--cap-has? '(15 29 "md-caption")) "the words are the caption, space and all")
    (check-true! (t--cap-has? '(29 30 "md-marker")) "the closing star steps back")
    (check-true! (t--cap-has? '(14 30 "row-caption")) "the row is a caption row")
    (check-true! (t--cap-has? '(0 13 "row-picture")) "the picture's row is a picture row")
    (check-true! (t--cap-has? '(7 12 "img-embed")) "and still draws the picture")
    (t--cap-done!)))

(deftest 'emphasis-away-from-a-picture-is-emphasis-and-not-a-caption
  "*x* paints italic; a caption needs the picture on the line above"
  (lambda ()
    (t--cap-fresh! "words\n*not a caption*\n")
    (check-true! (t--cap-has? '(6 7 "md-marker")) "the opening star steps back")
    (check-true! (t--cap-has? '(7 20 "morg-italic")) "the words are italic")
    (check-true! (not (t--cap-has? '(6 21 "row-caption"))) "no picture, no caption")
    (t--cap-done!)))

(deftest 'a-bold-pair-is-not-two-emphases
  "the single-star rule leaves **bold** to the bold rule"
  (lambda ()
    (t--cap-fresh! "a **b** c\n")
    (check-true! (t--cap-has? '(4 5 "morg-bold")) "b is bold")
    (check-true! (not (t--cap-has? '(3 4 "md-marker"))) "no emphasis marker inside the pair")
    (t--cap-done!)))
