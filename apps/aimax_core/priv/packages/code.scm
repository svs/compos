;;; code.scm — code-browse: read a source file with structural keys.
;;;
;;; A minor mode (the buffer keeps its major mode). It makes the buffer
;;; read-only, binds single keys to tree motion, tints the enclosing node,
;;; and folds the definitions of a long file. h/l walk the tree up and
;;; down, j/k walk the siblings, TAB folds the node, RET leaves the mode.
;;;
;;; Two backends, one node shape. A node is (KIND START END) in BYTE
;;; offsets. Tree-sitter answers when the buffer has a grammar; indentation
;;; answers when it does not, so every file browses. The ts backend is the
;;; ts-node primitive; the indent backend is the second half of this file.
;;;
;;; OFFSET RULE: every index here is a byte offset — use
;;; string-byte-length and substring-bytes, never string-length.
;;;
;;; State lives in buffer-locals, so a daemon restart rebuilds the mode:
;;;   'code-node   the node the reader stands on, (KIND START END)
;;;   'code-saved  what the mode clobbered, restored on exit
;;;   'code-folds  the fold ranges the mode owns, tag 'code

(defgroup 'code-browse "Structural browsing of source files.")

(defcustom 'code-browse-fold-lines 80
  "Files with more lines than this fold their definitions on entry."
  'group 'code-browse 'type 'number)

;;; --- the node shape -----------------------------------------------------------

(define (code--kind n) (car n))
(define (code--start n) (cadr n))
(define (code--end n) (caddr n))

(define (code--text buf n)
  (substring-bytes (buffer-text buf) (code--start n) (code--end n)))

;; a node worth stopping on covers more than one line
(define (code--multiline? buf n)
  (if (string-index (code--text buf n) "\n") #t #f))

;; Which backend answers. The mode decides once, on entry: a grammar that
;; parses this buffer wins, and everything else browses by indentation.
;; Asking per keypress would reparse the file to learn what does not
;; change while the reader reads.
(define (code--pick-backend! buf)
  (buffer-set-local! buf 'code-backend
    (if (and (buffer-local buf 'ts-lang) (ts-node "" 0 0 'at)) "ts" "indent")))

;; ONE node question, answered by the backend the mode picked. KIND names
;; which node the caller stands on, because nested nodes can cover the
;; same bytes; "" asks for the smallest node at the range.
;; OP is 'at, 'parent, 'child, 'next, 'prev or 'top.
(define (code--ask buf kind s e op)
  (if (equal? (buffer-local buf 'code-backend) "ts")
      (ts-node kind s e op)
      (code--indent-ask buf s e op)))

;; the same question, asked about a node the caller holds
(define (code--ask-node buf n op)
  (code--ask buf (code--kind n) (code--start n) (code--end n) op))

;;; --- motion policy ------------------------------------------------------------

;; Browsing starts on the code of a line, not on the indentation before
;; it: point at the start of "  def a do" means the def, not the block
;; that holds it.
(define (code--anchor buf pos)
  (let* ((text (buffer-text buf))
         (size (string-byte-length text))
         (bol (let loop ((i pos))
                (if (or (= i 0) (equal? (substring-bytes text (- i 1) i) "\n"))
                    i
                    (loop (- i 1)))))
         (code (let loop ((i bol))
                 (cond ((>= i size) i)
                       ((member (substring-bytes text i (+ i 1)) '(" " "\t")) (loop (+ i 1)))
                       (else i)))))
    (if (< pos code) code pos)))

;; The smallest node around POS that spans more than one line. A reader
;; browses blocks; the identifier under point is not a place to stand.
(define (code--enclosing buf pos0)
  (let ((pos (code--anchor buf pos0)))
    (code--enclosing-at buf pos)))

(define (code--enclosing-at buf pos)
  (let loop ((n (code--ask buf "" pos pos 'at)) (depth 0))
    (cond ((not n) #f)
          ((> depth 30) n)
          ;; an outline line is a node in its own right; a tree-sitter
          ;; identifier is not — it is a word inside one
          ((equal? (buffer-local buf 'code-backend) "indent") n)
          ((code--multiline? buf n) n)
          (else
            (let ((up (code--ask-node buf n 'parent)))
              (if up (loop up (+ depth 1)) n))))))

;; Descend to the first child that spans more than one line — the block,
;; not the keyword before it. With no such child, take the first child.
(define (code--descend buf n)
  (let ((first (code--ask-node buf n 'child)))
    (if (or (not first) (equal? (buffer-local buf 'code-backend) "indent"))
        first
        (let loop ((cur first) (steps 0))
          (cond ((code--multiline? buf cur) cur)
                ((> steps 50) first)
                (else
                  (let ((nx (code--ask-node buf cur 'next)))
                    (if nx (loop nx (+ steps 1)) first))))))))

;; The node the reader stands on. Point at the node start means the stored
;; node still holds; any other point means the reader moved another way,
;; so the node comes from point again.
(define (code--node buf)
  (let ((n (buffer-local buf 'code-node)))
    (if (and n (= (point) (code--start n)))
        n
        (code--enclosing buf (point)))))

;; the tint and the modeline for a node — no point motion, so the restore
;; path can rebuild the look of a buffer that is not the current one
(define (code--show! buf n)
  (buffer-set-local! buf 'code-node n)
  ;; a tint over the whole file says nothing about where the reader is
  (if (code--whole-buffer? buf n)
      (overlay-clear! buf 'code-scope)
      (overlay-set! buf 'code-scope
        (list (list (code--start n) (code--end n) "code-scope"))))
  (buffer-set-local! buf 'modeline-info (string-append "browse " (code--kind n))))

(define (code--whole-buffer? buf n)
  (and (= (code--start n) 0)
       (>= (code--end n) (- (string-byte-length (buffer-text buf)) 1))))

(define (code--goto! buf n)
  (code--show! buf n)
  (goto-char! (code--start n)))

(define (code--move! op)
  (let* ((buf (current-buffer))
         (cur (code--node buf)))
    (if (not cur)
        (message "code-browse: no structure here")
        (let ((target (if (equal? op 'child)
                          (code--descend buf cur)
                          (code--ask-node buf cur op))))
          (if target
              (code--goto! buf target)
              (message (string-append "code-browse: no " (symbol->string op))))))))

;;; --- folds --------------------------------------------------------------------

;; A node folds its body: from the end of its first line to its end. The
;; first line stays on screen, so the reader keeps the signature.
(define (code--body buf n)
  (let ((nl (string-index (code--text buf n) "\n")))
    (and nl (list (+ (code--start n) nl) (code--end n)))))

(define (code--toggle-fold!)
  (let* ((buf (current-buffer))
         (n (code--node buf))
         (r (and n (code--body buf n))))
    (if (not r)
        (message "code-browse: nothing to fold here")
        (begin
          (fold-toggle! buf 'code r)
          (buffer-set-local! buf 'code-folds (fold-get buf 'code))))))

;; Every node under the root, in buffer order.
(define (code--children buf n)
  (let loop ((c (code--ask-node buf n 'child)) (acc '()))
    (if (not c)
        (reverse acc)
        (loop (code--ask-node buf c 'next) (cons c acc)))))

(define (code--top-nodes buf)
  (let ((first (code--ask buf "" 0 0 'top)))
    (if (not first)
        '()
        (let loop ((n first) (acc (list first)))
          (let ((nx (code--ask-node buf n 'next)))
            (if nx (loop nx (cons nx acc)) (reverse acc)))))))

;; What to fold: the top-level nodes, unless one node wraps the whole file
;; — an Elixir defmodule does — and then the nodes inside it. The rule
;; needs no language table: it asks how much of the file a node covers.
(define (code--fold-nodes buf)
  (let ((size (string-byte-length (buffer-text buf))))
    (let loop ((nodes (code--top-nodes buf)) (depth 0))
      (if (and (= (length nodes) 1)
               (< depth 3)
               (> (- (code--end (car nodes)) (code--start (car nodes)))
                  (quotient (* size 4) 5)))
          (let ((inner (code--descend buf (car nodes))))
            (if inner (loop (code--children buf inner) (+ depth 1)) nodes))
          nodes))))

(define (code--buffer-lines buf)
  (length (string-split (buffer-text buf) "\n")))

(define (code--fold-defaults! buf)
  (when (> (code--buffer-lines buf) code-browse-fold-lines)
    (let ((ranges (filter (lambda (r) r)
                          (map (lambda (n) (code--body buf n))
                               (filter (lambda (n) (code--multiline? buf n))
                                       (code--fold-nodes buf))))))
      (fold-set! buf 'code ranges)
      (buffer-set-local! buf 'code-folds ranges))))

;;; --- the indentation backend ---------------------------------------------------
;;; No grammar, so indentation carries the structure. One line plus the
;;; deeper lines below it is a block, and a block answers the same six
;;; questions a tree-sitter node answers. Computed per keypress; a
;;; keypress reads the buffer once, and no cache can go stale.

(define (code--indent-of line)
  (let loop ((i 0))
    (if (>= i (string-length line))
        i
        (let ((c (substring line i (+ i 1))))
          (if (or (equal? c " ") (equal? c "\t")) (loop (+ i 1)) i)))))

;; (START END INDENT) per line; INDENT is #f on a blank line
(define (code--lines buf)
  (let loop ((parts (string-split (buffer-text buf) "\n")) (pos 0) (acc '()))
    (if (null? parts)
        (reverse acc)
        (let* ((line (car parts))
               (len (string-byte-length line))
               (blank (equal? (string-trim line) "")))
          (loop (cdr parts) (+ pos len 1)
                (cons (list pos (+ pos len) (if blank #f (code--indent-of line)))
                      acc))))))

(define (code--line-start l) (car l))
(define (code--line-end l) (cadr l))
(define (code--line-indent l) (caddr l))

;; the index of the line that holds POS
(define (code--line-at lines pos)
  (let loop ((i 0) (hit 0))
    (if (>= i (length lines))
        hit
        (loop (+ i 1) (if (<= (code--line-start (nth i lines)) pos) i hit)))))

;; the first line at or before I that is not blank
(define (code--solid-line lines i)
  (let loop ((j i))
    (cond ((< j 0) #f)
          ((code--line-indent (nth j lines)) j)
          (else (loop (- j 1))))))

;; a block: the line I, plus every line below it that is blank or deeper
(define (code--block lines i)
  (let ((base (code--line-indent (nth i lines))))
    (let loop ((j (+ i 1)) (last i))
      (if (>= j (length lines))
          (list "block" (code--line-start (nth i lines)) (code--line-end (nth last lines)))
          (let ((ind (code--line-indent (nth j lines))))
            (cond ((not ind) (loop (+ j 1) last))          ; blank: keep looking
                  ((> ind base) (loop (+ j 1) j))
                  (else (list "block"
                              (code--line-start (nth i lines))
                              (code--line-end (nth last lines))))))))))

;; the next line index that satisfies OK?, walking STEP, stopping when
;; STOP? says the block ended
(define (code--scan lines i step ok? stop?)
  (let loop ((j (+ i step)))
    (cond ((or (< j 0) (>= j (length lines))) #f)
          ((not (code--line-indent (nth j lines))) (loop (+ j step)))
          ((ok? (code--line-indent (nth j lines))) j)
          ((stop? (code--line-indent (nth j lines))) #f)
          (else (loop (+ j step))))))

(define (code--indent-ask buf s e op)
  (let* ((lines (code--lines buf))
         (i0 (code--line-at lines s))
         (i (code--solid-line lines i0)))
    (if (not i)
        #f
        (let ((base (code--line-indent (nth i lines))))
          (let ((j (cond ((equal? op 'at) i)
                         ((equal? op 'top)
                          (code--scan lines (+ i 1) -1
                                      (lambda (ind) (= ind 0))
                                      (lambda (ind) #f)))
                         ((equal? op 'parent)
                          (code--scan lines i -1
                                      (lambda (ind) (< ind base))
                                      (lambda (ind) #f)))
                         ((equal? op 'child)
                          (code--scan lines i 1
                                      (lambda (ind) (> ind base))
                                      (lambda (ind) (<= ind base))))
                         ((equal? op 'next)
                          (code--scan lines i 1
                                      (lambda (ind) (= ind base))
                                      (lambda (ind) (< ind base))))
                         ((equal? op 'prev)
                          (code--scan lines i -1
                                      (lambda (ind) (= ind base))
                                      (lambda (ind) (< ind base))))
                         (else #f))))
            (and j (code--block lines j)))))))

;;; --- go to definition ----------------------------------------------------------
;;; The seam for LSP. With a language server attached, lsp-definition
;;; answers. Without one, the same file answers: the first line that
;;; defines the symbol under point.

(define (code--symbol-at)
  (let* ((text (buffer-text (current-buffer)))
         (p (point))
         (word? (lambda (c)
                  (or (string-index "abcdefghijklmnopqrstuvwxyz" c)
                      (string-index "ABCDEFGHIJKLMNOPQRSTUVWXYZ" c)
                      (string-index "0123456789_?!-" c))))
         (size (string-byte-length text)))
    (let ((s (let loop ((i p))
               (if (and (> i 0) (word? (substring-bytes text (- i 1) i)))
                   (loop (- i 1))
                   i)))
          (e (let loop ((i p))
               (if (and (< i size) (word? (substring-bytes text i (+ i 1))))
                   (loop (+ i 1))
                   i))))
      (and (> e s) (substring-bytes text s e)))))

;; A definition line names the symbol after a defining word. The list is
;; short on purpose: it covers the languages the editor parses today.
(define code--define-words '("def" "defp" "defmodule" "defmacro" "define"
                             "fn" "func" "function" "class" "struct" "type"
                             "let" "const" "var" "impl" "trait" "module"))

(define (code--defines? line sym)
  (let ((words (filter (lambda (w) (not (equal? w "")))
                       (string-split (string-trim line) " "))))
    (let loop ((ws words))
      (cond ((null? ws) #f)
            ((null? (cdr ws)) #f)
            ((and (member (car ws) code--define-words)
                  (string-prefix? sym (cadr ws))) #t)
            (else (loop (cdr ws)))))))

(define (code--goto-definition)
  (let ((sym (code--symbol-at)))
    (cond
      ((not sym) (message "No symbol at point"))
      ((boundp 'lsp-definition) (lsp-definition sym))
      (else
        (let* ((buf (current-buffer))
               (hit (let loop ((ls (code--lines buf)))
                      (cond ((null? ls) #f)
                            ((code--defines?
                               (substring-bytes (buffer-text buf)
                                                (code--line-start (car ls))
                                                (code--line-end (car ls)))
                               sym)
                             (car ls))
                            (else (loop (cdr ls)))))))
          (if hit
              (begin
                (goto-char! (code--line-start hit))
                (when (minor-mode-on? buf "code-browse-mode")
                  (let ((n (code--enclosing buf (point))))
                    (when n (code--goto! buf n))))
                (message (string-append "Definition of " sym)))
              (message (string-append "No definition of " sym " in this buffer"))))))))

;;; --- the mode ------------------------------------------------------------------

(define code--keys
  (list (list "h" "code-browse-parent")
        (list "l" "code-browse-child")
        (list "j" "code-browse-next")
        (list "k" "code-browse-prev")
        (list "TAB" "code-browse-toggle-fold")
        (list "RET" "code-browse-exit")
        (list "q" "code-browse-exit")
        (list "M-." "code-goto-definition")))

(define-command "code-browse-parent" "Move to the node that encloses this one"
  (lambda () (code--move! 'parent)))
(define-command "code-browse-child" "Move into the first block inside this node"
  (lambda () (code--move! 'child)))
(define-command "code-browse-next" "Move to the next node at this level"
  (lambda () (code--move! 'next)))
(define-command "code-browse-prev" "Move to the previous node at this level"
  (lambda () (code--move! 'prev)))
(define-command "code-browse-toggle-fold" "Fold or unfold the node at point"
  (lambda () (code--toggle-fold!)))
(define-command "code-goto-definition" "Go to the definition of the symbol at point"
  (lambda () (code--goto-definition)))

(for-each (lambda (name) (undo-exempt! name))
          '("code-browse-parent" "code-browse-child" "code-browse-next"
            "code-browse-prev" "code-browse-toggle-fold" "code-goto-definition"))

;; The setup fn runs on enable AND on desktop restore, so it rebuilds
;; everything it needs from the locals it finds, and saves what it
;; clobbers exactly once.
(define (code--setup! buf)
  (unless (buffer-local buf 'code-saved)
    (buffer-set-local! buf 'code-saved
      (list (list 'read-only (buffer-read-only? buf))
            (list 'modeline-info (buffer-local buf 'modeline-info))
            (list 'keys (map (lambda (k)
                               (let ((hit (assoc (car k) (local-keys buf))))
                                 (list (car k) (if hit (cadr hit) #f))))
                             code--keys)))))
  (for-each (lambda (k) (local-set-key* buf (car k) (cadr k))) code--keys)
  (buffer-set-read-only! buf #t)
  ;; the node questions read the CURRENT buffer, so a restore of a buffer
  ;; that is not on screen rebuilds from the locals alone
  (let ((here (equal? buf (current-buffer)))
        (stored (buffer-local buf 'code-node))
        (folds (buffer-local buf 'code-folds)))
    (when here (code--pick-backend! buf))
    (cond (folds (fold-set! buf 'code folds))
          (here (code--fold-defaults! buf)))
    (cond (stored (code--show! buf stored))
          (here
            (let ((n (code--enclosing buf (point))))
              (if n
                  (code--goto! buf n)
                  (buffer-set-local! buf 'modeline-info "browse"))))
          (else (buffer-set-local! buf 'modeline-info "browse")))))

(define (code--saved buf key)
  (let ((hit (assoc key (or (buffer-local buf 'code-saved) '()))))
    (and hit (cadr hit))))

(define (code--teardown! buf)
  (for-each
    (lambda (k)
      (if (cadr k)
          (local-set-key* buf (car k) (cadr k))
          (local-unset-key* buf (car k))))
    (or (code--saved buf 'keys) '()))
  (buffer-set-read-only! buf (code--saved buf 'read-only))
  (buffer-set-local! buf 'modeline-info (code--saved buf 'modeline-info))
  (overlay-clear! buf 'code-scope)
  (fold-clear! buf 'code)
  (buffer-set-local! buf 'code-folds #f)
  (buffer-set-local! buf 'code-node #f)
  (buffer-set-local! buf 'code-backend #f)
  (buffer-set-local! buf 'code-saved #f))

(register-minor-mode! "code-browse-mode" code--setup! code--teardown!)

(define-command "code-browse" "Toggle structural browsing in this buffer"
  (lambda ()
    (if (toggle-minor-mode! "code-browse-mode")
        (message "code-browse: h parent · l child · j/k siblings · TAB fold · RET exit")
        (message "code-browse off"))))

(define-command "code-browse-exit" "Leave code-browse in this buffer"
  (lambda ()
    (disable-minor-mode! (current-buffer) "code-browse-mode")
    (message "code-browse off")))

(public! 'code-browse "Toggle structural browsing of the current buffer")
(public! 'code-goto-definition "Go to the definition of the symbol at point")
