;;; code-structure-test.scm --- the structural code surface an agent reaches.
;;;
;;; code-outline / code-find / code-read / code-replace! address a definition
;;; by the LINE it starts on, so an agent never matches a string or counts a
;;; byte. Tree-sitter answers where the buffer has a grammar (the elixir
;;; grammar is compiled in), and indentation answers everywhere else.

(domain! 'testing)
(effects! '(read))

(define t--code-elixir
  (string-append
    "defmodule Zz do\n"
    "  def one(x) do\n"
    "    x + 1\n"
    "  end\n"
    "\n"
    "  def two(x) do\n"
    "    x + 2\n"
    "  end\n"
    "end\n"))

(define (t--code-names entries) (map (lambda (e) (plist-get e 'name)) entries))

(effects! '(write))

;; A buffer tree-sitter parses: the grammar comes from the ts-lang local,
;; so the name does not have to be a path.
(define (t--code-ts! name text)
  (test-buffer! name text)
  (buffer-set-local! name 'ts-lang "elixir")
  name)

(deftest 'code-outline-names-every-definition-with-its-line
  "the defmodule wraps the file, so the level that folds is its defs"
  (lambda ()
    (let ((buf (t--code-ts! "zz-code-outline" t--code-elixir)))
      ;; with no docstring the doc column repeats the first line
      (check-true! (member '(2 "call" "one" "def one(x) do") (code-outline buf))
                   "the first definition")
      (check-true! (member '(6 "call" "two" "def two(x) do") (code-outline buf))
                   "the second definition")
      (check-equal! (buffer-local buf 'code-backend) "ts" "tree-sitter answered")
      (buffer-kill! buf))))

(deftest 'code-find-selects-a-definition-by-its-name-or-doc
  "a miss is the empty list, not a guess"
  (lambda ()
    (let ((buf (t--code-ts! "zz-code-find" t--code-elixir)))
      (check-equal! (code-find buf "def two") '((6 "call" "two" "def two(x) do")) "a hit")
      (check-equal! (code-find buf "def zzz") '() "a miss")
      (buffer-kill! buf))))

(deftest 'the-doc-column-reads-the-comment-block-above-a-definition
  "the comment lines above a def are its doc"
  (lambda ()
    (let ((buf (t--code-ts! "zz-code-comment"
                 (string-append
                   "defmodule Zc do\n"
                   "  # adds one to x\n"
                   "  # and nothing else\n"
                   "  def one(x) do\n"
                   "    x + 1\n"
                   "  end\n"
                   "end\n"))))
      (check-equal! (code-find buf "adds one") '((4 "call" "one" "adds one to x")) "the doc")
      (buffer-kill! buf))))

(deftest 'the-doc-column-reads-an-at-doc-heredoc-above-a-definition
  "@doc is the doc too"
  (lambda ()
    (let ((buf (t--code-ts! "zz-code-heredoc"
                 (string-append
                   "defmodule Zd do\n"
                   "  @doc \"\"\"\n"
                   "  Adds two to x.\n"
                   "  \"\"\"\n"
                   "  def two(x) do\n"
                   "    x + 2\n"
                   "  end\n"
                   "end\n"))))
      (check-true! (member '(5 "call" "two" "Adds two to x.") (code-find buf "Adds two"))
                   "the heredoc doc")
      (buffer-kill! buf))))

(deftest 'code-read-returns-exactly-one-definition
  "the line names the definition, and nothing around it comes with it"
  (lambda ()
    (let* ((buf (t--code-ts! "zz-code-read" t--code-elixir))
           (text (code-read buf 6)))
      (check-contains! text "def two(x) do" "the definition line")
      (check-contains! text "x + 2" "its body")
      (check-false! (string-contains? text "def one") "and nothing else")
      (buffer-kill! buf))))

(deftest 'code-replace-swaps-a-whole-definition-and-leaves-the-rest-alone
  "the file is still parseable structure after the swap"
  (lambda ()
    (let ((buf (t--code-ts! "zz-code-replace" t--code-elixir)))
      (check-equal! (code-replace! buf 6 "def two(x) do\n    x * 2\n  end")
                    "replaced the call at line 6" "the report")
      (check-equal! (buffer-text buf)
                    (string-append
                      "defmodule Zz do\n"
                      "  def one(x) do\n"
                      "    x + 1\n"
                      "  end\n"
                      "\n"
                      "  def two(x) do\n"
                      "    x * 2\n"
                      "  end\n"
                      "end\n")
                    "one definition changed")
      (check-equal! (length (code-outline buf)) 2 "the outline still finds both")
      (buffer-kill! buf))))

(deftest 'a-line-outside-the-buffer-is-an-error-not-a-quiet-edit
  "the last definition is not the answer to every line"
  (lambda ()
    (let ((buf (t--code-ts! "zz-code-bounds" t--code-elixir)))
      (check-contains! (code-read buf 9999) "is outside the buffer — it has" "a line past the end")
      (check-contains! (code-replace! buf 0 "x") "is outside the buffer" "line zero")
      (check-contains! (code-outline "zz-no-such-buffer") "no such buffer" "a buffer that is not there")
      (check-equal! (buffer-text buf) t--code-elixir "the failed replace changed nothing")
      (buffer-kill! buf))))

(deftest 'a-buffer-with-no-grammar-still-has-an-outline
  "indentation answers where no grammar does"
  (lambda ()
    (let ((buf (test-buffer! "zz-code-plain" "first:\n  a\n  b\nsecond:\n  c\n")))
      (check-true! (member '(1 "block" "first" "first:") (code-outline buf)) "the first block")
      (check-true! (member '(4 "block" "second" "second:") (code-outline buf)) "the second block")
      (check-equal! (buffer-local buf 'code-backend) "indent" "indentation answered")
      (check-contains! (code-read buf 4) "second:" "and it reads one block")
      (buffer-kill! buf))))

(deftest 'code-sexp-selects-the-smallest-expression-around-a-unique-anchor
  "LEVELS parents widen the selection, expand-region style"
  (lambda ()
    (let ((buf (t--code-ts! "zz-code-sexp" t--code-elixir)))
      (check-equal! (code-sexp buf "x + 2") "x + 2" "the smallest expression")
      (let ((wider (code-sexp buf "x + 2" 2)))
        (check-contains! wider "def two" "one parent up")
        (check-false! (string-contains? wider "def one") "and no further"))
      (buffer-kill! buf))))

(deftest 'code-sexp-replace-replaces-one-expression-and-nothing-else
  "the rest of the buffer is untouched"
  (lambda ()
    (let ((buf (t--code-ts! "zz-code-sexp-replace" t--code-elixir)))
      (check-contains! (code-sexp-replace! buf "x + 2" "x * 2") "replaced the" "the report")
      (check-contains! (buffer-text buf) "x * 2" "the new expression")
      (check-contains! (buffer-text buf) "x + 1" "the other definition")
      (check-equal! (length (code-outline buf)) 2 "the outline still finds both")
      (buffer-kill! buf))))

(deftest 'an-ambiguous-or-missing-sexp-anchor-is-an-error-not-a-guess
  "two matches is a question, not a choice"
  (lambda ()
    (let ((buf (t--code-ts! "zz-code-sexp-bad" t--code-elixir)))
      (check-contains! (code-sexp buf "x + ") "occurs 2 times" "an ambiguous anchor")
      (check-contains! (code-sexp buf "zzz-nowhere") "not found" "a missing anchor")
      (check-contains! (code-sexp-replace! buf "x + " "y") "occurs 2 times" "the replace refuses too")
      (check-equal! (buffer-text buf) t--code-elixir "the failed replace changed nothing")
      (buffer-kill! buf))))

(deftest 'a-headless-find-file-still-parses-with-the-grammar
  "the mode a file opens in must reach tree-sitter with no window"
  (lambda ()
    (let ((path "/tmp/zz_headless_code.ex"))
      (write-file! path t--code-elixir)
      (find-file path)
      (check-true! (member '(2 "call" "one" "def one(x) do") (code-outline path))
                   "the outline parsed")
      (check-equal! (buffer-local path 'code-backend) "ts" "tree-sitter answered")
      (when (buffer-known? path) (buffer-kill! path))
      (delete-file! path))))

(deftest 'the-structural-api-is-public-so-apropos-finds-it
  "an agent reads the catalog to learn these exist"
  (lambda ()
    (check-true! (member "code-read" (t--code-names (apropos "definition line")))
                 "apropos names code-read")
    (check-equal! (plist-get (catalog-entry 'function "code-replace!") 'effects)
                  '("write") "code-replace! writes")
    (check-equal! (plist-get (catalog-entry 'function "code-outline") 'effects)
                  '("read") "code-outline reads")
    (check-equal! (plist-get (catalog-entry 'function "code-sexp") 'effects)
                  '("read") "code-sexp reads")
    (check-equal! (plist-get (catalog-entry 'function "code-sexp-replace!") 'effects)
                  '("write") "code-sexp-replace! writes")))
