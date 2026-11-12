;;; table-block.scm --- a table fence: a table whose cells take font colors.
;;;
;;; A table block holds a Markdown pipe table or space-aligned columns. The
;;; page draws each body line as a table row. The fence arguments are color
;;; rules, tried in order; the first rule that matches a cell colors it:
;;;
;;;   ```table green=strong yellow=potential red=unfit
;;;   ```table green>=.7 yellow>=.4 red<.4
;;;
;;; COLOR=A,B matches a cell whose text is A or B. COLOR<N, COLOR<=N,
;;; COLOR>N and COLOR>=N match a cell that is a number. A cell that no rule
;;; matches tries each of its words, so "potential .60" colors both words.
;;; The colors are theme faces: table-red, table-green, table-yellow,
;;; table-blue, table-purple, table-cyan, and table-gray. Both the source
;;; view and the page draw them.

;; the block vocabulary is the editor's
(require 'morg-kinds "morg/morg-kinds.scm")

(namespace! 'editor)
(domain! 'files)
(effects! '(pure))

(define table-block-colors
  '(("red" ansi-color-red) ("green" ansi-color-green)
    ("yellow" ansi-color-yellow) ("blue" ansi-color-blue)
    ("purple" ansi-color-magenta) ("cyan" ansi-color-cyan)
    ("gray" dim)))

(for-each (lambda (c)
            (defface! (string->symbol (string-append "table-" (car c))) 'inherit (cadr c)))
          table-block-colors)

;; the number a cell holds, or #f. ".6" and "-.6" are numbers too.
(define (table-block-number s)
  (let ((t (cond ((string-prefix? "." s) (string-append "0" s))
                 ((string-prefix? "-." s)
                  (string-append "-0" (substring-bytes s 1 (string-byte-length s))))
                 (else s))))
    (and (re-match "^-?[0-9]+(\\.[0-9]+)?$" t)
         (let ((n (string->number t))) (and (number? n) n)))))

(define (table-block--words s)
  (map (lambda (r) (substring-bytes s (car r) (cadr r))) (re-find* "[^ \t]+" s)))

;; ARGS, the fence's arguments -> the rules, each (COLOR OP VALUE). OP is
;; "=" with a list of strings, or a comparison with a number. A token that
;; names no known color, or no number, is not a rule.
(define (table-block-rules args)
  (fold
    (lambda (acc tok)
      (let ((g (re-groups "^([a-z]+)(<=|>=|<|>|=)(.+)$" tok 0)))
        (if (not g)
            acc
            (let* ((part (lambda (i) (substring-bytes tok (car (nth i g)) (cadr (nth i g)))))
                   (color (part 1)) (op (part 2)) (v (part 3)))
              (cond ((not (assoc color table-block-colors)) acc)
                    ((equal? op "=")
                     (append acc (list (list color op
                                             (filter (lambda (x) (not (equal? x "")))
                                                     (string-split v ","))))))
                    ((table-block-number v)
                     (append acc (list (list color op (table-block-number v)))))
                    (else acc))))))
    '()
    (table-block--words (or args ""))))

;; the color of TEXT under RULES, or #f
(define (table-block-color rules text)
  (let ((n (table-block-number text)))
    (let loop ((rs rules))
      (if (null? rs)
          #f
          (let* ((r (car rs)) (op (nth 1 r)) (v (nth 2 r)))
            (if (cond ((equal? op "=") (member text v))
                      ((not n) #f)
                      ((equal? op "<") (< n v))
                      ((equal? op "<=") (<= n v))
                      ((equal? op ">") (> n v))
                      (else (>= n v)))
                (car r)
                (loop (cdr rs))))))))

;; the cells of one body line, (START END) in bytes around the text: the
;; bars divide a pipe row, and two spaces divide an aligned row
(define (table-block-cells line)
  (if (md--table-row? line)
      (fold (lambda (acc c)
              (let* ((s (car c))
                     (text (substring-bytes line s (cadr c)))
                     (m (re-find* "[^ \t](.*[^ \t])?" text)))
                (if (null? m) acc
                    (append acc (list (list (+ s (car (car m))) (+ s (cadr (car m)))))))))
            '()
            (md--table-cells line))
      (re-find* "[^ \t|]+( [^ \t|]+)*" line)))

;; the color spans of one body line at byte START
(define (table-block-line-spans rules start line)
  (if (md--table-rule? line)
      '()
      (apply append
        (map (lambda (c)
               (let* ((text (substring-bytes line (car c) (cadr c)))
                      (color (table-block-color rules text)))
                 (if color
                     (list (list (+ start (car c)) (+ start (cadr c))
                                 (string-append "table-" color)))
                     (fold (lambda (acc w)
                             (let* ((ws (+ (car c) (car w)))
                                    (wc (table-block-color rules
                                          (substring-bytes line ws (+ (car c) (cadr w))))))
                               (if wc
                                   (append acc (list (list (+ start ws) (+ start (car c) (cadr w))
                                                           (string-append "table-" wc))))
                                   acc)))
                           '()
                           (re-find* "[^ \t]+" text)))))
             (table-block-cells line)))))

;; the registry's body-spans: BLOCK is (START LANG BODY-START BODY-END ...)
(define (table-block-body-spans text block)
  (let* ((start (nth 0 block)) (bs (nth 2 block)) (be (nth 3 block))
         (open (substring-bytes text start (max start (- bs 1))))
         (rules (table-block-rules (morg-fence-args open))))
    (if (null? rules)
        '()
        (let loop ((ls (split-lines (substring-bytes text bs be))) (pos bs) (acc '()))
          (if (null? ls)
              acc
              (loop (cdr ls) (+ pos (string-byte-length (car ls)) 1)
                    (append acc (table-block-line-spans rules pos (car ls)))))))))

;; the registry's row-spans: one body line as a table row in the page
(define (table-block-row-spans start line len head?)
  (cond ((= len 0) '())
        ;; the rule row is markup: the page hides it, and the row borders
        ;; draw the line under the head
        ((md--table-rule? line)
         (list (list start (+ start len) "md-marker")
               (list start (+ start len) "row-conceal")))
        ((md--table-row? line)
         (md--table-row-spans start line
           (if head? '("row-table" "row-table-head") '("row-table"))))
        (else
         (append (list (list start (+ start len) "row-code")
                       (list start (+ start len) "row-table-aligned"))
                 (if head? (list (list start (+ start len) "row-table-aligned-head")) '())))))

(define-fence-kind! "table"
  "A table whose cells take font colors. Rules on the fence: COLOR=A,B, COLOR<N, COLOR>=N. Colors: red green yellow blue purple cyan gray."
  'runnable #f
  'row-spans table-block-row-spans
  'body-spans table-block-body-spans)

(public! 'table-block-rules
  "(table-block-rules ARGS) — the color rules in a table fence's ARGS, each (COLOR OP VALUE)")
(public! 'table-block-color
  "(table-block-color RULES TEXT) — the color the first matching rule gives TEXT, or #f")
