;;; theme-test.scm --- faces and themes: what a theme owns, what a default owns.

(domain! 'testing)
(effects! '(write))

(define (theme-test-face-attr face attr)
  (face-attribute face attr))

(define (theme-test-restore!)
  (load-theme "compos-dark"))

;; two small themes that name the same face with different attribute sets
(define-theme "tt-theme-a" (list (list 'tt-face 'fg "#111111" 'bg "#eeeeee")))
(define-theme "tt-theme-b" (list (list 'tt-face 'fg "#222222")))

(deftest 'load-theme-clears-an-attribute-the-next-theme-does-not-set
  "theme A sets fg and bg; theme B sets fg only; after B the bg is gone"
  (lambda ()
    (load-theme "tt-theme-a")
    (check-equal! (theme-test-face-attr 'tt-face 'bg) "#eeeeee" "A set the background")
    (load-theme "tt-theme-b")
    (check-equal! (theme-test-face-attr 'tt-face 'fg) "#222222" "B set the foreground")
    (check-false! (theme-test-face-attr 'tt-face 'bg) "B does not name bg, so it is unset")
    (theme-test-restore!)))

(deftest 'defface-applies-the-attributes-the-theme-does-not-name
  "the theme names the colour, the package names the weight, and both hold"
  (lambda ()
    (load-theme "tt-theme-b")
    (defface! 'tt-face 'fg "#999999" 'weight "700")
    (check-equal! (theme-test-face-attr 'tt-face 'fg) "#222222" "the theme keeps its colour")
    (check-equal! (theme-test-face-attr 'tt-face 'weight) "700" "the default supplies the weight")
    ;; and the next load keeps the default under the theme
    (load-theme "tt-theme-a")
    (check-equal! (theme-test-face-attr 'tt-face 'weight) "700" "load-theme reapplies the default")
    (check-equal! (theme-test-face-attr 'tt-face 'fg) "#111111" "and the theme wins the colour")
    (theme-test-restore!)))

(deftest 'inherit-and-priority-reach-the-face-table
  "a default may name a parent face and a priority"
  (lambda ()
    (defface! 'tt-child 'inherit 'tt-face 'priority 7)
    (check-equal! (theme-test-face-attr 'tt-child 'inherit) "tt-face" "inherit is stored as the parent's name")
    (check-equal! (theme-test-face-attr 'tt-child 'priority) 7 "priority is stored")
    (face-clear! 'tt-child)
    (check-false! (member "tt-child" (face-list)) "face-clear! forgets the face")))

(deftest 'the-emacs-face-names-inherit-the-compos-faces
  "font-lock-keyword-face draws with ts-keyword, and success with ok"
  (lambda ()
    (check-equal! (theme-test-face-attr 'font-lock-keyword-face 'inherit) "ts-keyword" "keyword")
    (check-equal! (theme-test-face-attr 'success 'inherit) "ok" "success")
    (check-equal! (theme-test-face-attr 'mode-line 'inherit) "modeline" "mode-line")))
