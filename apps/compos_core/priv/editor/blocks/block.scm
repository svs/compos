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

;;; --- typing a block ----------------------------------------------------------
;;; A block is recognized the moment its opening exists: the grammar
;;; reads a fresh open fence as an unclosed block that swallows the rest
;;; of the document. RET at the end of that line closes the fence, stands
;;; point in the body, and makes sure the run key answers here.

(define (block-electric-close!)
  (let* ((buf (current-buffer))
         (pos (point))
         (text (buffer-text buf))
         (size (string-byte-length text))
         (bol (line-start-position (line-number-at-pos pos)))
         (rest (substring-bytes text bol size))
         (nl (string-index rest "\n"))
         (eol (if nl (+ bol nl) size))
         (line (substring-bytes text bol eol))
         (b (and (= pos eol)
                 (morg-fence-info line)
                 (block-at buf pos))))
    (if (not (and b (= (nth 0 b) bol)
                  (let* ((btext (or (block-text-at buf (nth 0 b) (nth 1 b)) ""))
                         (last (car (reverse (string-split btext "\n")))))
                    (not (morg-fence-close? last)))))
        #f
        (begin
          (buffer-insert! buf pos "\n\n```")
          (goto-char! (+ pos 1))
          ;; the block's key answers here even off morg-mode
          (unless (buffer-mode-is? buf "morg-mode")
            (local-set-key* buf "C-c C-c" "morg-babel"))
          #t))))

;;; --- the verb keys -----------------------------------------------------------

(define (block-bind-keys! buf pairs)
  (for-each (lambda (kv) (local-set-key* buf (car kv) (cadr kv))) pairs))

(define (block-unbind-keys! buf pairs)
  (for-each (lambda (kv) (local-unset-key* buf (car kv))) pairs))

;;; --- finding blocks by the grammar -------------------------------------------
;;; The markdown grammar parses a fenced block as one node, so a block is
;;; found by tree-sitter where the reader's grammar is loaded: one
;;; (START END INFO BODY-START BODY-END) per block, END at the closing
;;; fence's last byte, INFO the whole info string (language and args).
;;; Where no grammar is installed, the morg scan answers with the same
;;; shape, line-walked.

(define block--query
  "(fenced_code_block (info_string)? @info (code_fence_content)? @body) @block")

(define (block--ts-list text)
  (let loop ((hits (ts-query-string "markdown" text block--query))
             (cur #f) (acc '()))
    (if (null? hits)
        (reverse (if cur (cons cur acc) acc))
        (let* ((h (car hits)) (cap (car h)) (s (cadr h)) (e (caddr h)))
          (cond
            ((equal? cap "block")
             (let ((e2 (if (and (> e s)
                                (equal? (substring-bytes text (- e 1) e) "\n"))
                           (- e 1)
                           e)))
               (loop (cdr hits) (list s e2 "" e2 e2)
                     (if cur (cons cur acc) acc))))
            ((and cur (equal? cap "info"))
             (loop (cdr hits)
                   (list (nth 0 cur) (nth 1 cur)
                         (substring-bytes text s e)
                         (nth 3 cur) (nth 4 cur))
                   acc))
            ((and cur (equal? cap "body"))
             (loop (cdr hits)
                   (list (nth 0 cur) (nth 1 cur) (nth 2 cur) s e)
                   acc))
            (else (loop (cdr hits) cur acc)))))))

(define (block--scan-list buf)
  (let ((scan (morg-scan buf)))
    (map (lambda (b)
           (let* ((start (nth 0 b))
                  (open-line (cadr (morg-entry-at scan start)))
                  (close-end (morg-block-close-end scan buf start))
                  (info (string-trim
                          (string-append (nth 1 b) " "
                                         (morg-fence-args open-line)))))
             (list start close-end info (nth 2 b) (nth 3 b))))
         (morg-blocks scan buf))))

(define (block-list buf)
  (if (member "markdown" (ts-langs))
      (block--ts-list (buffer-text buf))
      (block--scan-list buf)))

;; the block containing POS, or #f. A pos on either fence belongs to it.
(define (block-at buf pos)
  (let loop ((bs (block-list buf)))
    (cond ((null? bs) #f)
          ((and (<= (nth 0 (car bs)) pos) (<= pos (nth 1 (car bs))))
           (car bs))
          (else (loop (cdr bs))))))

;; the block's language: the first word of its info string
(define (block-lang b)
  (let ((info (string-trim (nth 2 b))))
    (car (append (string-split info " ") (list "")))))


;; the block on LINE, addressed the way an outline addresses a section —
;; by line number, never by byte
(define (block-at-line buf line)
  (with-current-buffer buf
    (lambda () (block-at buf (line-start-position line)))))

;; the block's whole text, by line. The finder knows the extent; no
;; caller passes an end.
(define (block-text buf line)
  (let ((b (block-at-line buf line)))
    (and b (block-text-at buf (nth 0 b) (nth 1 b)))))

(public! 'block-list
  "(block-list BUF) — every fenced block as (START END INFO BODY-START BODY-END), found by the markdown grammar, or by the scan where no grammar is loaded")
(public! 'block-at
  "(block-at BUF POS) — the fenced block containing byte POS, or #f")
(public! 'block-at-line
  "(block-at-line BUF LINE) — the fenced block on LINE, or #f")
(public! 'block-text
  "(block-text BUF LINE) — the whole text of the fenced block on LINE, or #f")

(public! 'block-body
  "(block-body BLOCK) — the text between BLOCK's fences; a block without both fences is returned whole")

;; Do not leak this layer's catalog context into the loader.
(package! block-parent-package block-parent-namespace)
(domain! block-parent-domain)
(effects! block-parent-effects)
