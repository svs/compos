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
  "the # and the space wear md-marker; the words wear org-level-1"
  (lambda ()
    (t--md-fresh! "# Title\n")
    (check-true! (t--md-has? '(0 2 "md-marker")) "the marker is a marker")
    (check-true! (t--md-has? '(2 7 "md-h1")) "the text is the heading")
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

(deftest 'turning-the-mode-off-takes-the-paint-with-it
  "teardown clears the markdown overlays"
  (lambda ()
    (t--md-fresh! "# Title\n")
    (t--md-done!)
    (check-false! (t--md-has? '(2 7 "md-h1")) "no heading face is left")))
