;;; imenu-test.scm --- imenu on the outline contract.
;;;
;;; The index is (code-outline BUF) — or the morg headings — never a
;;; per-language query table.

(domain! 'testing)
(effects! '(write))

(define t--imenu-buf "zzimenu-test.py")

(define (t--imenu-py!)
  (test-buffer! t--imenu-buf
    "def alpha():\n    return 1\n\ndef beta():\n    return 2\n"))

(effects! '(read))

(define (t--imenu-names rows) (map (lambda (r) (caddr r)) rows))
(define (t--imenu-kinds rows) (map (lambda (r) (cadr r)) rows))
(define (t--imenu-labels cands) (map car cands))
(define (t--imenu-hints cands) (map caddr cands))

(effects! '(write))

(deftest 'the-imenu-index-is-the-outline
  "every buffer answers, because every buffer has an outline"
  (lambda ()
    (t--imenu-py!)
    (let ((rows (imenu-rows t--imenu-buf)))
      (check-true! (member "alpha" (t--imenu-names rows)) "the first definition")
      (check-true! (member "beta" (t--imenu-names rows)) "the second definition")
      (check-true! (member "block" (t--imenu-kinds rows)) "the outline kind"))
    (buffer-kill! t--imenu-buf)))

(deftest 'imenu-candidates-carry-kind-and-line
  "a repeated name carries its line, so every row stays reachable"
  (lambda ()
    (let ((cands (imenu--candidates
                   '((1 "block" "bar" "def bar") (5 "block" "bar" "def bar")
                     (9 "block" "baz" "")))))
      (check-true! (member "bar (L5)" (t--imenu-labels cands)) "the repeat carries its line")
      (check-true! (member "bar" (t--imenu-labels cands)) "the first keeps the plain name")
      (check-true! (member "baz" (t--imenu-labels cands)) "a name seen once stays plain")
      (check-contains! (car (t--imenu-hints cands)) "block · L1"
                       "the hint names kind and line"))))

(deftest 'a-morg-buffer-indexes-its-headings
  "the headings are the index, and the body is not"
  (lambda ()
    (test-buffer! t--imenu-buf "# One\nbody\n## Two\n")
    (buffer-set-local! t--imenu-buf 'mode-name "morg-mode")
    (let ((names (t--imenu-names (imenu-rows t--imenu-buf))))
      (check-true! (member "# One" names) "the first heading")
      (check-true! (member "## Two" names) "the second heading")
      (check-false! (member "body" names) "the body is not a heading"))
    (buffer-kill! t--imenu-buf)))

(deftest 'an-empty-buffer-reports-instead-of-prompting
  "no definitions means a message, not a minibuffer"
  (lambda ()
    (test-buffer! t--imenu-buf "")
    (check-equal! (imenu-rows t--imenu-buf) '() "no rows")
    (let ((mark (string-length (buffer-text "*Messages*"))))
      (with-current-buffer t--imenu-buf (lambda () (run-command "imenu")))
      (let ((said (buffer-text "*Messages*")))
        (check-contains! (substring said mark (string-length said))
                         "no definitions" "the command reports instead of prompting")))
    (buffer-kill! t--imenu-buf)))
