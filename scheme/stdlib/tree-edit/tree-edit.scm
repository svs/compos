;;; tree-edit.scm --- select and move whole tree-sitter nodes.
;;;
;;; tree-edit-mode is a minor mode for any buffer with a grammar: HTML,
;;; Scheme, Elixir, Morg (through the markdown grammar) and the rest. The
;;; selection is always one whole node, the region from its start to its
;;; end, so every move keeps the text balanced.
;;;
;;;   <left> <right>        the previous / next sibling
;;;   M-<left> M-<right>    out to the parent / into the first child
;;;   s-<left> s-<right>    swap the node with its previous / next sibling
;;;   s-<up>                lift the node out of its parent, before it
;;;   s-<down>              move the node into its next sibling, first
;;;   C-x n s               narrow to the node; C-x n w widens
;;;
;;; Nothing moves outside a narrowing: a sibling, parent or swap past the
;;; narrowed edges is refused. Each edit is one buffer-replace-range!, so
;;; it is one undo step. Positions are byte offsets, as ts-node gives them.

(category! 'edit)
(domain! 'edit)
(effects! '(write))

;;; --- which nodes count -----------------------------------------------------

;; the node kinds that are never a selection: a tag's halves, the name
;; inside a tag, markdown's markers. A buffer adds its own in the local
;; tree-edit-skip-kinds.
(define tree-edit--skip
  '("start_tag" "end_tag" "tag_name" "block_continuation" "inline"))

;; the part of a container a moved node goes after, not before: an
;; element's start tag, a section's heading
(define tree-edit--heads
  '("start_tag" "atx_heading" "setext_heading"))

(define (tree-edit--skip? n)
  (let ((k (car n)))
    (if (or (member k tree-edit--skip)
            (string-suffix? "_marker" k)
            (member k (or (buffer-local-value 'tree-edit-skip-kinds (current-buffer)) '())))
        #t #f)))

(define (tree-edit--rel n op) (ts-node (car n) (cadr n) (caddr n) op))
(define (tree-edit--kids n) (ts-children (car n) (cadr n) (caddr n)))
(define (tree-edit--same? a b) (and (= (cadr a) (cadr b)) (= (caddr a) (caddr b))))
(define (tree-edit--blank? s) (string=? (string-trim s) ""))

;;; --- the narrowing ---------------------------------------------------------

(define (tree-edit--bounds)
  (or (buffer-narrow-range (current-buffer))
      (list 0 (buffer-size (current-buffer)))))

(define (tree-edit--inside? n)
  (let ((b (tree-edit--bounds)))
    (and (>= (cadr n) (car b)) (<= (caddr n) (cadr b)))))

;;; --- the node --------------------------------------------------------------

;; the smallest node that counts around POS
(define (tree-edit--unit-at pos)
  (let loop ((n (ts-node "" pos pos 'at)))
    (cond ((not n) #f)
          ((or (tree-edit--skip? n) (= (cadr n) (caddr n)))
           (let ((up (tree-edit--rel n 'parent))) (if up (loop up) n)))
          (else n))))

;; the node selected now: the stored one while point and mark still
;; bound it, else the one at point
(define (tree-edit--node)
  (let ((n (buffer-local-value 'tree-edit-node (current-buffer))))
    (if (and n (= (point) (cadr n)) (equal? (mark) (caddr n)))
        n
        (tree-edit--unit-at (point)))))

(define (tree-edit--select! n)
  (let ((buf (current-buffer)))
    (buffer-set-local! buf 'tree-edit-node n)
    (overlay-set! buf 'tree-edit (list (list (cadr n) (caddr n) "code-scope")))
    (buffer-set-local! buf 'modeline-info (string-append "tree " (car n)))
    (set-mark! (caddr n))
    (goto-char! (cadr n))))

(define (tree-edit--sibling n op)
  (let loop ((m (tree-edit--rel n op)))
    (cond ((not m) #f)
          ((tree-edit--skip? m) (loop (tree-edit--rel m op)))
          (else m))))

(define (tree-edit--parent n)
  (let loop ((m (tree-edit--rel n 'parent)))
    (cond ((not m) #f)
          ((or (tree-edit--skip? m) (tree-edit--same? m n)) (loop (tree-edit--rel m 'parent)))
          (else m))))

;; the first child that counts; a child as wide as N is N again, so look
;; inside it
(define (tree-edit--child n)
  (let loop ((ks (tree-edit--kids n)))
    (cond ((null? ks) #f)
          ((tree-edit--skip? (car ks)) (loop (cdr ks)))
          ((tree-edit--same? (car ks) n) (tree-edit--child (car ks)))
          (else (car ks)))))

(define (tree-edit--with fn)
  (let ((n (tree-edit--node)))
    (if n (fn n) (message "tree-edit: no node here"))))

(define (tree-edit--go! target what)
  (cond ((not target) (message (string-append "tree-edit: no " what)))
        ((not (tree-edit--inside? target)) (message "tree-edit: that is outside the narrowing"))
        (else (tree-edit--select! target))))

;;; --- the edits -------------------------------------------------------------

(define (tree-edit--text n) (buffer-substring (cadr n) (caddr n)))

(define (tree-edit--replace! s e text)
  (buffer-replace-range! (current-buffer) s (- e s) text))

;; the node that holds TEXT at byte START, as the tree has it after an edit
(define (tree-edit--found kind start text)
  (let ((end (+ start (string-byte-length text))))
    (or (let loop ((m (ts-node "" start start 'at)))
          (cond ((not m) #f)
                ((and (= (cadr m) start) (= (caddr m) end)) m)
                ((> (- (caddr m) (cadr m)) (- end start)) #f)
                (else (loop (tree-edit--rel m 'parent)))))
        (list kind start end))))

(define (tree-edit--swap! op)
  (tree-edit--with
    (lambda (n)
      (let ((m (tree-edit--sibling n op)))
        (cond ((not m) (message (if (eq? op 'prev) "tree-edit: already the first" "tree-edit: already the last")))
              ((not (tree-edit--inside? m)) (message "tree-edit: that is outside the narrowing"))
              (else
                ;; a node's trailing blank lines (a markdown section has
                ;; them) stay in its slot, so the spacing does not move
                (let* ((a (if (eq? op 'prev) m n))
                       (b (if (eq? op 'prev) n m))
                       (ra (tree-edit--text a)) (rb (tree-edit--text b))
                       (wa (tree-edit--trail ra)) (wb (tree-edit--trail rb))
                       (ta (substring ra 0 (- (string-length ra) (string-length wa))))
                       (tb (substring rb 0 (- (string-length rb) (string-length wb))))
                       (between (buffer-substring (caddr a) (cadr b)))
                       (at (if (eq? op 'prev)
                               (cadr a)
                               (+ (cadr a) (string-byte-length tb) (string-byte-length wa)
                                  (string-byte-length between)))))
                  (tree-edit--replace! (cadr a) (caddr b) (string-append tb wa between ta wb))
                  (tree-edit--select! (tree-edit--found (car n) at (if (eq? n a) ta tb))))))))))

;; the whitespace at the start of S, and at its end
(define (tree-edit--lead s)
  (let loop ((i 0))
    (if (and (< i (string-length s)) (char-whitespace? (string-ref s i)))
        (loop (+ i 1))
        (substring s 0 i))))

(define (tree-edit--trail s)
  (let loop ((i (string-length s)))
    (if (and (> i 0) (char-whitespace? (string-ref s (- i 1))))
        (loop (- i 1))
        (substring s i (string-length s)))))

;; N out of its parent P, placed just before P. The gap after N closes,
;; or the gap before it when N is last; a newline and P's indent, or a
;; space when P shares its line, separate N from P.
(define (tree-edit--lift!)
  (tree-edit--with
    (lambda (n)
      (let ((p (tree-edit--parent n)))
        (cond ((not p) (message "tree-edit: already at the top"))
              ((not (tree-edit--inside? p)) (message "tree-edit: that is outside the narrowing"))
              (else
                (let* ((ps (cadr p)) (pe (caddr p))
                       (text (tree-edit--text n))
                       (before (buffer-substring ps (cadr n)))
                       (after (buffer-substring (caddr n) pe))
                       (gap-b (tree-edit--trail before))
                       (gap-a (tree-edit--lead after))
                       (close-after? (> (string-length gap-a) 0))
                       (before2 (if close-after?
                                    before
                                    (substring before 0 (- (string-length before) (string-length gap-b)))))
                       (after2 (if close-after?
                                   (substring after (string-length gap-a) (string-length after))
                                   after))
                       (bol (let loop ((i ps))
                              (if (or (= i 0) (equal? (buffer-substring (- i 1) i) "\n")) i (loop (- i 1)))))
                       (indent (buffer-substring bol ps))
                       (sep (if (tree-edit--blank? indent) (string-append "\n" indent) " ")))
                  (tree-edit--replace! ps pe (string-append text sep before2 after2))
                  (tree-edit--select! (tree-edit--found (car n) ps text)))))))))

;; N into its next sibling M, as M's first part: after M's head (a start
;; tag, a heading), else before M's first child. The whitespace that
;; follows that place separates N from its new neighbour.
(define (tree-edit--first-unit ks)
  (cond ((null? ks) #f)
        ((tree-edit--skip? (car ks)) (tree-edit--first-unit (cdr ks)))
        (else (car ks))))

(define (tree-edit--sink!)
  (tree-edit--with
    (lambda (n)
      (let* ((m (tree-edit--sibling n 'next))
             (ks (if m (tree-edit--kids m) '()))
             (head (and (pair? ks) (member (car (car ks)) tree-edit--heads) (car ks)))
             (first (tree-edit--first-unit ks))
             (at (cond (head (caddr head)) (first (cadr first)) (else #f))))
        (cond ((not m) (message "tree-edit: nothing after this to move into"))
              ((not at) (message "tree-edit: the next node holds nothing to move into"))
              ((not (tree-edit--inside? m)) (message "tree-edit: that is outside the narrowing"))
              (else
                (let* ((text (tree-edit--text n))
                       (mtext (tree-edit--text m))
                       (off (- at (cadr m)))
                       (head-part (substring-bytes mtext 0 off))
                       (rest (substring-bytes mtext off (string-byte-length mtext)))
                       (ws (tree-edit--lead rest))
                       (new (if head
                                (string-append head-part ws text rest)
                                (string-append head-part text (if (string=? ws "") " " ws) rest)))
                       (pos (+ (cadr n) (string-byte-length head-part)
                               (if head (string-byte-length ws) 0))))
                  (tree-edit--replace! (cadr n) (caddr m) new)
                  (tree-edit--select! (tree-edit--found (car n) pos text)))))))))

;;; --- commands --------------------------------------------------------------

(define-command "tree-edit-next" "Select the next node at this level"
  (lambda () (tree-edit--with (lambda (n) (tree-edit--go! (tree-edit--sibling n 'next) "next node"))))
  'modes '(tree-edit-mode))

(define-command "tree-edit-prev" "Select the previous node at this level"
  (lambda () (tree-edit--with (lambda (n) (tree-edit--go! (tree-edit--sibling n 'prev) "previous node"))))
  'modes '(tree-edit-mode))

(define-command "tree-edit-parent" "Select the node around this one"
  (lambda () (tree-edit--with (lambda (n) (tree-edit--go! (tree-edit--parent n) "parent"))))
  'modes '(tree-edit-mode))

(define-command "tree-edit-child" "Select the first node inside this one"
  (lambda () (tree-edit--with (lambda (n) (tree-edit--go! (tree-edit--child n) "child"))))
  'modes '(tree-edit-mode))

(define-command "tree-edit-swap-prev" "Swap this node with the one before it"
  (lambda () (tree-edit--swap! 'prev))
  'modes '(tree-edit-mode))

(define-command "tree-edit-swap-next" "Swap this node with the one after it"
  (lambda () (tree-edit--swap! 'next))
  'modes '(tree-edit-mode))

(define-command "tree-edit-lift" "Move this node out of its parent, before it"
  (lambda () (tree-edit--lift!))
  'modes '(tree-edit-mode))

(define-command "tree-edit-sink" "Move this node into the next one, as its first part"
  (lambda () (tree-edit--sink!))
  'modes '(tree-edit-mode))

(define-command "tree-edit-narrow" "Show only the selected node; C-x n w widens"
  (lambda ()
    (tree-edit--with
      (lambda (n)
        (buffer-narrow! (current-buffer) (cadr n) (caddr n))
        (tree-edit--select! n)
        (message "Narrowed to the node; C-x n w widens"))))
  'modes '(tree-edit-mode))

(define tree-edit--keys
  (list (list "<left>" "tree-edit-prev")
        (list "<right>" "tree-edit-next")
        (list "M-<left>" "tree-edit-parent")
        (list "M-<right>" "tree-edit-child")
        (list "s-<left>" "tree-edit-swap-prev")
        (list "s-<right>" "tree-edit-swap-next")
        (list "s-<up>" "tree-edit-lift")
        (list "s-<down>" "tree-edit-sink")
        (list "C-x n s" "tree-edit-narrow")))

(for-each undo-exempt! '("tree-edit-next" "tree-edit-prev" "tree-edit-parent" "tree-edit-child" "tree-edit-narrow"))

;;; --- the mode --------------------------------------------------------------

;; Morg has no grammar of its own; the markdown one gives it sections,
;; lists and paragraphs. Its faces stay Morg's: ts-faces #f keeps the
;; markdown colours off the page while the mode lends the grammar.
(define (tree-edit--setup! buf)
  (when (and (not (buffer-local-value 'ts-lang buf))
             (buffer-derived-mode? buf "morg-mode"))
    (buffer-set-local! buf 'tree-edit-lent-grammar #t)
    (buffer-set-local! buf 'ts-faces #f)
    (buffer-set-local! buf 'ts-lang "markdown"))
  (buffer-set-local! buf 'tree-edit-saved-info (buffer-local-value 'modeline-info buf))
  (when (equal? buf (current-buffer))
    (let ((n (tree-edit--unit-at (point))))
      (if n (tree-edit--select! n) (buffer-set-local! buf 'modeline-info "tree")))))

(define (tree-edit--teardown! buf)
  (when (buffer-local-value 'tree-edit-lent-grammar buf)
    (buffer-set-local! buf 'ts-lang #f)
    (buffer-set-local! buf 'ts-faces #t)
    (buffer-set-local! buf 'tree-edit-lent-grammar #f))
  (overlay-clear! buf 'tree-edit)
  (buffer-set-local! buf 'modeline-info (buffer-local-value 'tree-edit-saved-info buf))
  (buffer-set-local! buf 'tree-edit-node #f))

(register-minor-mode! "tree-edit-mode" tree-edit--setup! tree-edit--teardown!)
(minor-mode-keys! "tree-edit-mode" tree-edit--keys)

(define-command "tree-edit-mode" "Toggle selecting and moving whole tree-sitter nodes"
  (lambda ()
    (let ((buf (current-buffer)))
      (cond ((minor-mode-on? buf "tree-edit-mode")
             (disable-minor-mode! buf "tree-edit-mode")
             (message "tree-edit off"))
            (else
              (enable-minor-mode! buf "tree-edit-mode")
              (if (buffer-local-value 'ts-lang buf)
                  (message "tree-edit: ←/→ siblings · M-←/→ out/in · s-arrows move · C-x n s narrow")
                  (begin (disable-minor-mode! buf "tree-edit-mode")
                         (message "tree-edit: this buffer has no grammar"))))))))

(mode-doc! "tree-edit-mode"
  "Select and move whole tree-sitter nodes. `<left>`/`<right>` select the previous or next sibling, `M-<left>` the parent and `M-<right>` the first child. `s-<left>`/`s-<right>` swap the node with its sibling, `s-<up>` lifts it out of its parent and `s-<down>` moves it into the next node. `C-x n s` narrows to the node and `C-x n w` widens; nothing moves outside a narrowing. Morg buffers borrow the markdown grammar.")

(effects! '(read))
(public! 'tree-edit-mode "Toggle selecting and moving whole tree-sitter nodes in the current buffer")

(provide 'tree-edit)
