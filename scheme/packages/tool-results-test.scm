;;; tool-results-test.scm --- a long tool result goes to a file, and the
;;; model gets a reference that says the shape and how to read a part.

(domain! 'testing)
(effects! '(write))

(define (tr--with-cap cap thunk)
  (let ((old tool-result-max-bytes))
    (set! tool-result-max-bytes cap)
    (let ((r (ignore-errors thunk)))
      (set! tool-result-max-bytes old)
      r)))

;; the saved path a reference names
(define (tr--path ref)
  (let* ((key "the editor saved it to ")
         (i (string-index ref key))
         (rest (substring-bytes ref (+ i (string-byte-length key)) (string-byte-length ref)))
         (j (string-index rest ". Read")))
    (substring-bytes rest 0 j)))

(define (tr--xs n)
  (string-join (map (lambda (i) "x") (iota n)) ""))

(define (tr--lines n)
  (string-join (map (lambda (i) (string-append "row " (number->string i))) (iota n)) "\n"))

(deftest 'tool-result-store-passes-a-short-result
  "a result under the cap, and every result with the cap at 0, reach the model whole"
  (lambda ()
    (tr--with-cap 100
      (lambda ()
        (check-equal! (tool-result-store #f "t" "short") "short" "a short result is unchanged")))
    (let ((long (tr--xs 500)))
      (check-equal! (tr--with-cap 0 (lambda () (tool-result-store #f "t" long))) long
                    "cap 0 sends every result whole"))
    (let ((content (string-append "\x00;compos-content\n" (tr--xs 500))))
      (check-equal! (tr--with-cap 100 (lambda () (tool-result-store #f "t" content))) content
                    "MCP content blocks pass as they are"))))

(deftest 'tool-result-store-saves-a-long-result
  "a long text result becomes a reference, and the file holds all of it"
  (lambda ()
    (let* ((text (tr--lines 400))
           (ref (tr--with-cap 1000 (lambda () (tool-result-store #f "eval-scheme" text))))
           (path (tr--path ref)))
      (check-true! (< (string-byte-length ref) (string-byte-length text)) "the reference is shorter")
      (check-true! (string-suffix? ".txt" path) "a text result is a .txt file")
      (check-equal! (read-file path) text "the file holds the whole result")
      (check-true! (string-contains? ref "row 0") "the reference shows the start")
      (check-true! (string-contains? ref "row 399") "the reference shows the end")
      (check-true! (string-contains? ref "(tool-result-read ") "the reference says how to read it")
      (check-equal! (tool-result-read path '(lines 2 3)) "2: row 1\n3: row 2" "lines count from 1")
      (check-equal! (tool-result-read path '(match "row 250")) "251: row 250" "match answers numbered lines")
      (delete-file! path))))

(deftest 'tool-result-json-reference-and-path
  "a JSON result names its shape, and a path reads one value"
  (lambda ()
    (let* ((text (json-encode
                   (list 'items (map (lambda (i) (list 'id i 'name (string-append "n" (number->string i))))
                                     (iota 50))
                         'next "abc")))
           (ref (tr--with-cap 200 (lambda () (tool-result-store #f "list" text))))
           (path (tr--path ref)))
      (check-true! (string-suffix? ".json" path) "a JSON result is a .json file")
      (check-true! (string-contains? ref "items: [50 x {id: 0, name: \"n0\"}]") "the shape names the array and its length")
      (check-true! (string-contains? ref "'(path items 0)") "the example path opens the array")
      (check-equal! (tool-result-read path '(path items 3 name)) "\"n3\"" "a path reads one value")
      (check-equal! (tool-result-read path '(path "next")) "\"abc\"" "a key can be a string")
      (delete-file! path))))

(deftest 'tool-result-csv-and-sexp-readers
  "a CSV result reads rows under its header; an s-expression reads items"
  (lambda ()
    (let* ((csv (string-append "id,name\n"
                  (string-join (map (lambda (i) (string-append (number->string i) ",x")) (iota 100)) "\n")))
           (ref (tr--with-cap 200 (lambda () (tool-result-store #f "q" csv))))
           (path (tr--path ref)))
      (check-true! (string-suffix? ".csv" path) "a CSV result is a .csv file")
      (check-true! (string-contains? ref "100 rows after the header line") "the reference counts the rows")
      (check-equal! (tool-result-read path '(rows 2 3)) "id,name\n1,x\n2,x" "rows come under the header")
      (delete-file! path))
    (let* ((sexp (value->string (map (lambda (i) (list 'n i)) (iota 200))))
           (ref (tr--with-cap 200 (lambda () (tool-result-store #f "q" sexp))))
           (path (tr--path ref)))
      (check-true! (string-suffix? ".scm" path) "an s-expression result is a .scm file")
      (check-true! (string-contains? ref "a list of 200 items") "the reference counts the items")
      (check-equal! (tool-result-read path '(items 2 3)) "(n 1)\n(n 2)" "items count from 1")
      (check-equal! (tool-result-read path '(match "(n 150)")) "151: (n 150)"
                    "match searches the items of a one-line list")
      (delete-file! path))))

(deftest 'mcp-proxy-answer-sends-the-reference
  "the proxy answer for a long result is the reference, base64 for the socket"
  (lambda ()
    (let* ((text (tr--lines 400))
           (sent (base64-decode
                   (tr--with-cap 1000 (lambda () (mcp-proxy--answer "eval-scheme" #f text))))))
      (check-true! (string-prefix? "[The tool result is " sent) "the agent gets the reference")
      (delete-file! (tr--path sent)))
    (check-equal! (base64-decode (mcp-proxy--answer "eval-scheme" #f "ok")) "ok"
                  "a short answer is unchanged")))
