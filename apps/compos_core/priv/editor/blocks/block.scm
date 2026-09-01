;;; block.scm --- what every waiting block shares.
;;;
;;; A block is a fenced span of text that an action lands in a document
;;; and a person decides. This file holds the mechanics every such block
;;; uses: reading and replacing its text, landing it below a passage,
;;; stripping its fences by structure, finding it again through edits,
;;; binding its verb keys, and the line diff its renderings draw from.
;;; A concrete block (diff-block.scm) owns its record, its states, its
;;; paint, and its verbs.

(define block-parent-package *loading-package*)
(define block-parent-namespace *loading-namespace*)
(define block-parent-domain *catalog-domain*)
(define block-parent-effects *catalog-effects*)

(package! 'block 'editor)
(domain! 'editing)
(effects! '(write))

;;; --- text --------------------------------------------------------------------

(define (block-text-at buf start end)
  (let ((text (buffer-text buf)))
    (and (<= start end)
         (<= end (string-byte-length text))
         (substring-bytes text start end))))

;; What the block needs after it. A document that already has a blank line
;; there needs nothing; a line that runs straight on needs one.
(define (block-tail-for buf end)
  (let* ((text (buffer-text buf))
         (size (string-byte-length text))
         (rest (substring-bytes text (min end size) (min (+ end 2) size))))
    (cond ((equal? rest "") "")
          ((equal? rest "\n") "")
          ((string-prefix? "\n\n" rest) "")
          ((string-prefix? "\n" rest) "\n")
          (else "\n\n"))))

;;; --- the fence ---------------------------------------------------------------

(define (block-fence kind args body)
  (string-append "```" kind " " args "\n" body "\n```"))

;; the text between the fences; a block whose fences were edited away is
;; your text, and stays whole
(define (block-body block)
  (let ((lines (string-split block "\n")))
    (if (and (>= (length lines) 2)
             (string-prefix? "```" (car lines))
             (string-prefix? "```" (car (reverse lines))))
        (string-join (reverse (cdr (reverse (cdr lines)))) "\n")
        block)))

;;; --- finding and moving the block --------------------------------------------

;; the span of the first overlay wearing FACE, or #f. An overlay follows
;; the rope, so an edit above the block moves the answer with it.
(define (block-overlay-span buf face)
  (let ((hits (filter (lambda (ov) (equal? (caddr ov) face))
                      (buffer-overlays buf))))
    (and (pair? hits) (list (car (car hits)) (cadr (car hits))))))

;; land BLOCK below END: a blank line, the block, and TAIL. -> (BSTART BEND)
(define (block-land! buf end block tail)
  (let* ((bstart (+ end 2))
         (bend (+ bstart (string-byte-length block))))
    (buffer-insert! buf end (string-append "\n\n" block tail))
    (list bstart bend)))

;; replace the block's text in place. -> the new BEND
(define (block-replace! buf bstart bend text)
  (buffer-delete-range! buf bstart (- bend bstart))
  (buffer-insert! buf bstart text)
  (+ bstart (string-byte-length text)))

;;; --- the verb keys -----------------------------------------------------------

(define (block-bind-keys! buf pairs)
  (for-each (lambda (kv) (local-set-key* buf (car kv) (cadr kv))) pairs))

(define (block-unbind-keys! buf pairs)
  (for-each (lambda (kv) (local-unset-key* buf (car kv))) pairs))

;;; --- the line diff -----------------------------------------------------------
;;; Two texts as head context, one hunk, tail context. A waiting block
;;; holds one change by construction, so nothing matches line by line in
;;; the middle: there is no second change in there to find.

(define (block--common-head a b)
  (let loop ((a a) (b b) (n 0))
    (if (and (pair? a) (pair? b) (equal? (car a) (car b)))
        (loop (cdr a) (cdr b) (+ n 1))
        n)))

(define (block--common-tail a b limit)
  (let loop ((a (reverse a)) (b (reverse b)) (n 0))
    (if (and (pair? a) (pair? b) (< n limit) (equal? (car a) (car b)))
        (loop (cdr a) (cdr b) (+ n 1))
        n)))

(define (block--slice lines from to)
  (let loop ((ls lines) (i 0) (acc '()))
    (cond ((or (null? ls) (>= i to)) (reverse acc))
          ((>= i from) (loop (cdr ls) (+ i 1) (cons (car ls) acc)))
          (else (loop (cdr ls) (+ i 1) acc)))))

(define (block-marked prefix lines)
  (map (lambda (l) (string-append prefix l)) lines))

;; -> (HEAD-CONTEXT OURS-HUNK THEIRS-HUNK TAIL-CONTEXT), as line lists
(define (block-diff-parts ours theirs)
  (let* ((a (string-split ours "\n"))
         (b (string-split theirs "\n"))
         (head (block--common-head a b))
         (tail (block--common-tail a b
                 (- (min (length a) (length b)) head))))
    (list (block--slice a 0 head)
          (block--slice a head (- (length a) tail))
          (block--slice b head (- (length b) tail))
          (block--slice a (- (length a) tail) (length a)))))

(public! 'block-body
  "(block-body BLOCK) — the text between BLOCK's fences; a block without both fences is returned whole")
(public! 'block-diff-parts
  "(block-diff-parts OURS THEIRS) — (HEAD OURS-HUNK THEIRS-HUNK TAIL) as line lists")

;; Do not leak this layer's catalog context into the loader.
(package! block-parent-package block-parent-namespace)
(domain! block-parent-domain)
(effects! block-parent-effects)
