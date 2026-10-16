;;; block.scm --- what every waiting block shares.
;;; ./docs/editor/blocks/diff-block.md
;;; A block is a fenced span of text that an action lands in a document
;;; and a person decides. This file holds the mechanics every such block
;;; uses: reading and replacing its text, landing it below a passage,
;;; stripping its fences by structure, finding it again through edits,
;;; binding its verb keys, and the line diff its renderings draw from.
;;; A concrete block (diff-block.scm) owns its record, its states, its
;;; paint, and its verbs.

;; the block vocabulary is the editor's
(namespace! 'editor)
(domain! 'editing)
(effects! '(write))

;;; --- text --------------------------------------------------------------------

(define (block-text-at buf start end)
  (let ((text (buffer-text buf)))
    (and (<= start end)
         (<= end (string-byte-length text))
         (substring-bytes text start end))))

;;; --- addressable blocks ----------------------------------------------------
;;; A parsed fence is geometry. An addressable block is durable editor state.
;;; It has an opaque buffer-scoped id and marker locals for both boundaries.
;;; Blocks may contain other blocks, but their ranges may never cross.

(define (block-records buf)
  (or (buffer-local buf 'addressable-blocks) '()))

(define (block--marker-name id edge)
  (string->symbol (string-append "block-" id "-" edge)))

(define (block--record buf id)
  (let loop ((records (block-records buf)))
    (cond ((null? records) #f)
          ((equal? (plist-get (car records) 'id) id) (car records))
          (else (loop (cdr records))))))

(define (block--replace-record! buf id next)
  (buffer-set-local! buf 'addressable-blocks
    (map (lambda (record)
           (if (equal? (plist-get record 'id) id) next record))
         (block-records buf)))
  next)

(define (block--put pl key value)
  (let loop ((rest pl) (out '()))
    (cond ((null? rest) (append (reverse out) (list key value)))
          ((equal? (car rest) key)
           (append (reverse out) (list key value) (cddr rest)))
          (else
            (loop (cddr rest)
                  (cons (cadr rest) (cons (car rest) out)))))))

(define (block--next-id! buf)
  (let ((n (+ 1 (or (buffer-local buf 'addressable-block-seq) 0))))
    (buffer-set-local! buf 'addressable-block-seq n)
    (string-append "b" (number->string n))))

(define (block--crosses? a-start a-end b-start b-end)
  (or (and (< a-start b-start) (< b-start a-end) (< a-end b-end))
      (and (< b-start a-start) (< a-start b-end) (< b-end a-end))))

(define (block--valid-range? buf start end parent)
  (and (number? start) (number? end)
       (<= 0 start) (<= start end) (<= end (buffer-size buf))
       (let ((container (and parent (block-resolve-id buf parent))))
         (or (not parent)
             (and container
                  (<= (plist-get container 'start) start)
                  (<= end (plist-get container 'end)))))
       (let loop ((records (block-records buf)))
         (if (null? records)
             #t
             (let ((live (block-resolve-id buf (plist-get (car records) 'id))))
               (if (and live
                        (not (equal? (plist-get live 'state) 'deleted))
                        (block--crosses?
                          start end
                          (plist-get live 'start) (plist-get live 'end)))
                   #f
                   (loop (cdr records))))))))

(define (block-create! buf kind start end &optional parent state metadata)
  (if (not (block--valid-range? buf start end parent))
      (error "block-create!: invalid or crossing range")
      (let* ((id (block--next-id! buf))
             (start-local (block--marker-name id "start"))
             (end-local (block--marker-name id "end"))
             (record (list 'id id 'kind kind 'parent (or parent #f)
                           'start-local start-local 'end-local end-local
                           'state (or state 'complete)
                           'metadata (or metadata '()))))
        (buffer-marker-local! buf start-local 'stay)
        (buffer-marker-local! buf end-local 'advance)
        (buffer-set-local! buf start-local start)
        (buffer-set-local! buf end-local end)
        (buffer-set-local! buf 'addressable-blocks
          (append (block-records buf) (list record)))
        id)))

(define (block-address buf id)
  (and (block--record buf id) (list 'buffer buf 'block id)))

(define (block-resolve address)
  (let* ((buf (plist-get address 'buffer))
         (id (plist-get address 'block))
         (record (and (string? buf) (string? id) (buffer-known? buf)
                      (block--record buf id))))
    (and record
         (let ((start (buffer-local buf (plist-get record 'start-local)))
               (end (buffer-local buf (plist-get record 'end-local))))
           (and (number? start) (number? end)
                (list 'buffer buf
                      'id id
                      'kind (plist-get record 'kind)
                      'parent (plist-get record 'parent)
                      'start start
                      'end end
                      'state (plist-get record 'state)
                      'metadata (plist-get record 'metadata)))))))

(define (block-resolve-id buf id)
  (block-resolve (list 'buffer buf 'block id)))

(define (block-children buf parent)
  (filter
    (lambda (record)
      (and record
           (equal? (plist-get record 'parent) parent)
           (not (equal? (plist-get record 'state) 'deleted))))
    (map (lambda (record)
           (block-resolve-id buf (plist-get record 'id)))
         (block-records buf))))

(define (block-set-state! buf id state)
  (let ((record (block--record buf id)))
    (and record
         (block--replace-record! buf id (block--put record 'state state)))))

(define (block-set-metadata! buf id metadata)
  (let ((record (block--record buf id)))
    (and record
         (block--replace-record! buf id (block--put record 'metadata metadata)))))

(define (block-close-end! buf id &optional position)
  (let ((record (block--record buf id)))
    (when record
      (let ((end-local (plist-get record 'end-local)))
        (buffer-marker-local! buf end-local 'advance)
        (when position (buffer-set-local! buf end-local position))))))

(define (block-retire-children! buf parent)
  (for-each
    (lambda (child)
      (block-set-state! buf (plist-get child 'id) 'deleted))
    (block-children buf parent)))

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

;; replace the block's text in place, as ONE undo step. -> the new BEND
(define (block-replace! buf bstart bend text)
  (undo-group! buf #t)
  (buffer-delete-range! buf bstart (- bend bstart))
  (buffer-insert! buf bstart text)
  (undo-group! buf #f)
  (+ bstart (string-byte-length text)))

;;; --- typing a block ----------------------------------------------------------
;;; A block is recognized the moment its opening exists: the grammar
;;; reads a fresh open fence as an unclosed block that swallows the rest
;;; of the document. RET at the end of that line closes the fence and
;;; stands point in the body. A MODE decides whether blocks are active:
;;; this is the mechanism, and morg-mode binds it.

(define (block--find-in blocks bol)
  (let loop ((bs blocks))
    (cond ((null? bs) #f)
          ((= (nth 0 (car bs)) bol) (car bs))
          (else (loop (cdr bs))))))

(define (block-electric-close!)
  (let* ((buf (current-buffer))
         (pos (point))
         (text (buffer-text buf))
         (size (string-byte-length text))
         (bol (line-start-position (line-number-at-pos pos)))
         (rest (substring-bytes text bol size))
         (nl (string-index rest "\n"))
         (eol (if nl (+ bol nl) size))
         (line (substring-bytes text bol eol)))
    (if (not (and (= pos eol) (morg-fence-info line)))
        #f
        ;; the fence just typed may not have its newline yet — the RET
        ;; being handled is that newline — so the grammar reads the text
        ;; as it is about to be
        (let* ((text2 (if (= eol size) (string-append text "\n") text))
               (blocks (if (member "markdown" (ts-langs))
                           (block--ts-list text2)
                           (block--scan-list buf)))
               (b (block--find-in blocks bol))
               (unclosed
                 (and b
                      (let* ((btext (substring-bytes text2 (nth 0 b)
                                      (min (nth 1 b) (string-byte-length text2))))
                             (last (car (reverse (string-split btext "\n")))))
                        (not (morg-fence-close? last))))))
          (if (not unclosed)
              #f
              ;; the close is the block's landing: a runnable kind takes
              ;; its instructions onto the fence line, keys from this
              ;; buffer's keymap, the way every block's fence line speaks
              (let* ((lang (morg-fence-info line))
                     (key (and (fence-kind-runnable? lang)
                               (fence-kind-run lang)
                               (key-for-command "morg-babel" buf)))
                     (hint (if (and (string? key) (not (equal? key "")))
                               (string-append " · " key " run")
                               ""))
                     (body-at (+ pos (string-byte-length hint) 1)))
                (buffer-insert! buf pos (string-append hint "\n\n```"))
                (goto-char! body-at)
                #t))))))

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

;; HITS are block--query's captures when the caller has them from a
;; parse it shares
(define (block--ts-list text &optional hits)
  (let loop ((hits (or hits (ts-query-string "markdown" text block--query)))
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
(for-each (lambda (n) (catalog-meta! 'function n 'effects '(read)))
  '("block-list" "block-at" "block-at-line" "block-text"))
(catalog-meta! 'function "block-body" 'effects '(pure))

(public! 'block-records
  "(block-records BUF) — the durable addressable block records in BUF")
(public! 'block-create!
  "(block-create! BUF KIND START END [PARENT STATE METADATA]) — create one addressable block and return its buffer-scoped id")
(public! 'block-address
  "(block-address BUF ID) — the stable address (buffer BUF block ID), or #f")
(public! 'block-resolve
  "(block-resolve ADDRESS) — resolve an address to its current range and metadata, or #f")
(public! 'block-resolve-id
  "(block-resolve-id BUF ID) — resolve one buffer-scoped block id, or #f")
(public! 'block-children
  "(block-children BUF PARENT) — the live direct children of PARENT")
(public! 'block-set-state!
  "(block-set-state! BUF ID STATE) — set an addressable block's state")
(public! 'block-set-metadata!
  "(block-set-metadata! BUF ID METADATA) — replace an addressable block's metadata")

(catalog-meta! 'function "block-records" 'domain 'editing 'effects '(read))
(catalog-meta! 'function "block-address" 'domain 'editing 'effects '(read))
(catalog-meta! 'function "block-resolve" 'domain 'editing 'effects '(read))
(catalog-meta! 'function "block-resolve-id" 'domain 'editing 'effects '(read))
(catalog-meta! 'function "block-children" 'domain 'editing 'effects '(read))
(for-each
  (lambda (name) (catalog-meta! 'function name 'domain 'editing 'effects '(write)))
  '("block-create!" "block-set-state!" "block-set-metadata!"))

(domain! 'unknown)
(effects! '(unknown))
