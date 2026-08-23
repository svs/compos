;;; occur-ts-test.scm --- packages/occur.scm: a tree-sitter query as a list.
;;;
;;; ts-filter answers capture plists, occur-ts-mode renders them, and the
;;; row commands preview and visit. One test stays in ExUnit: that M-s t
;;; reaches the command through the prefix and reads the query in the
;;; minibuffer, which is the key path and not the command path.

(domain! 'testing)
(effects! '(read))

(define t--occur-src "*zz-occur-src*")
(define t--occur-json "{\n  \"one\": 1,\n  \"two\": 2\n}\n")
(define t--occur-query "(pair key: (string) @key)")

(effects! '(write))

(define (t--occur-source!)
  (test-buffer! t--occur-src t--occur-json)
  (buffer-set-local! t--occur-src 'ts-lang "json")
  (switch-to-buffer! t--occur-src)
  (goto-char! 0))

(define (t--occur-clean!)
  (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
            (list "*occur-ts*" t--occur-src)))

(deftest 'ts-filter-answers-structured-captures-for-an-explicit-grammar
  "one capture is a plist: the name, the byte range, the line and its text"
  (lambda ()
    (t--occur-source!)
    (let ((rows (ts-filter t--occur-src "json" t--occur-query)))
      (check-equal! (length rows) 2 "the query captures both keys")
      (let ((one (car rows)) (two (nth 1 rows)))
        (check-equal! (plist-get one 'capture) "key" "the capture is named")
        (check-true! (number? (plist-get one 'start)) "and carries a byte offset")
        (check-equal! (plist-get one 'line) 2 "the first is on line 2")
        (check-equal! (plist-get one 'match) "\"one\"" "the matched text")
        (check-equal! (plist-get one 'text) "  \"one\": 1," "and the whole line")
        (check-equal! (plist-get two 'line) 3 "the second is on line 3")
        (check-equal! (plist-get two 'match) "\"two\"" "its matched text")
        (check-equal! (plist-get two 'text) "  \"two\": 2" "and its line")))
    (t--occur-clean!)))

(deftest 'the-list-renders-every-capture-under-a-title-that-counts-them
  "the rows are the captures, and the meta line names the grammar"
  (lambda ()
    (t--occur-source!)
    (occur-ts-open t--occur-src "json" t--occur-query)
    (check-equal! (buffer-local "*occur-ts*" 'mode-name) "occur-ts-mode" "the mode")
    (check-true! (buffer-local "*occur-ts*" 'transient) "the list is transient")
    (check-equal! (buffer-local "*occur-ts*" 'occur-ts-source) t--occur-src "it names its source")
    (let ((text (buffer-text "*occur-ts*")))
      (check-contains! text "Tree-sitter matches" "the title")
      (check-contains! text "2 captures · json" "the count and the grammar")
      (check-contains! text "2  key" "the line and the capture name")
      (check-contains! text "\"one\": 1" "the first line of source")
      (check-contains! text "\"two\": 2" "and the second"))
    (t--occur-clean!)))

(deftest 'moving-previews-the-capture-and-the-row-command-visits-it
  "a move previews in the source; RET names occur-ts-visit, which lands there"
  (lambda ()
    (t--occur-source!)
    (occur-ts-open t--occur-src "json" t--occur-query)
    (list-goto-first-entry "*occur-ts*")
    (let ((second (string-index t--occur-json "\"two\"")))
      (run-command "list-next")
      (check-equal! (buffer-point t--occur-src) second "the move previews the second capture")
      (check-equal! (current-buffer) "*occur-ts*" "and the list keeps the point")

      (check-equal! (cadr (assoc "RET" (plist-get (list-mode-opts "occur-ts-mode") 'keys)))
                    "occur-ts-visit" "RET names the visit command")
      (run-command "occur-ts-visit")
      (check-equal! (current-buffer) t--occur-src "the visit lands in the source")
      (check-equal! (buffer-point t--occur-src) second "on the capture it named"))
    (t--occur-clean!)))

(deftest 'restoring-the-mode-rebuilds-the-rows-from-its-source-locals
  "the rule: a restored buffer rebuilds from locals, and never from its text"
  (lambda ()
    (t--occur-source!)
    (occur-ts-open t--occur-src "json" t--occur-query)
    (buffer-set-read-only! "*occur-ts*" #f)
    (buffer-replace-range! "*occur-ts*" 0 (buffer-size "*occur-ts*") "stale")
    (with-current-buffer "*occur-ts*" (lambda () (set-mode! "occur-ts-mode")))
    (let ((text (buffer-text "*occur-ts*")))
      (check-contains! text "\"one\": 1" "the first row is back")
      (check-contains! text "\"two\": 2" "and the second"))
    (check-true! (buffer-read-only? "*occur-ts*") "and the list is read only again")
    (t--occur-clean!)))

(deftest 'the-public-api-and-the-command-are-discoverable
  "a name nobody can find is a name nobody calls"
  (lambda ()
    (check-true! (pair? (filter (lambda (e) (equal? (plist-get e 'name) "ts-filter"))
                                (apropos "capture plists")))
                 "the doc string finds the function")
    (check-equal! (plist-get (catalog-entry 'command "occur-ts") 'effects) '("write")
                  "the command declares what it does")
    (check-equal! (key-for-command "occur-ts") "M-s t" "and it names its key")))
