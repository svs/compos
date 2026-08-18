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

;; Desktop restore re-arms the mode for a buffer that is not on screen,
;; and the node questions read the CURRENT buffer, so the backend cannot
;; be chosen then. The first motion is on screen by definition: choose it
;; there instead of browsing a source file by indentation for the rest of
;; the session.
(define (code--backend buf)
  (or (buffer-local buf 'code-backend)
      (begin (code--pick-backend! buf)
             (buffer-local buf 'code-backend))))

;; ONE node question, answered by the backend the mode picked. KIND names
;; which node the caller stands on, because nested nodes can cover the
;; same bytes; "" asks for the smallest node at the range.
;; OP is 'at, 'parent, 'child, 'next, 'prev or 'top.
(define (code--ask buf kind s e op)
  (if (equal? (code--backend buf) "ts")
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

(define (code--holds? n pos)
  (and (<= (code--start n) pos) (>= (code--end n) pos)))

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

;; The first node at or above N that HAS a body. A reader on a one-line
;; form means "fold what holds this", the way hs-toggle-hiding does; the
;; answer "nothing to fold here" is true of the node and useless to the
;; reader.
(define (code--foldable buf n)
  (let loop ((cur n) (depth 0))
    (cond ((not cur) #f)
          ((> depth 20) #f)
          ((code--body buf cur) cur)
          (else (loop (code--ask-node buf cur 'parent) (+ depth 1))))))

(define (code--toggle-fold!)
  (let* ((buf (current-buffer))
         (n (and (code--node buf) (code--foldable buf (code--node buf))))
         (r (and n (code--body buf n))))
    (if (not r)
        (message "code-browse: nothing to fold here")
        (begin
          ;; stand on what folded: point inside a hidden range is a point
          ;; the reader cannot see
          (code--goto! buf n)
          (fold-toggle! buf 'code r)
          (buffer-set-local! buf 'code-folds (fold-get buf 'code))))))

;; One level in ONE call. The fold pass reads whole levels, and a file
;; with 300 top-level forms costs 300 round trips the other way.
(define (code--children buf n)
  (if (equal? (buffer-local buf 'code-backend) "ts")
      (ts-children (code--kind n) (code--start n) (code--end n))
      (code--indent-children buf n)))

;; the children of the root: the range that covers the file names it
(define (code--top-nodes buf)
  (if (equal? (buffer-local buf 'code-backend) "ts")
      (ts-children "" 0 (string-byte-length (buffer-text buf)))
      ;; "file", not "block": this pseudo node has no header line, and
      ;; code--indent-children reads that from the kind
      (code--indent-children buf (list "file" 0 (string-byte-length (buffer-text buf))))))

;; a node that covers most of the file is the file, not a part of it
(define (code--wraps-file? buf n)
  (> (- (code--end n) (code--start n))
     (quotient (* (string-byte-length (buffer-text buf)) 4) 5)))

;; What to fold: the top-level nodes, unless one node wraps the whole file
;; — an Elixir defmodule does — and then the nodes inside it. The rule
;; needs no language table: it asks how much of the file a node covers.
;; This is also the level a reader lands on, so the two agree by
;; construction: what folds is what j and k walk.
(define (code--fold-nodes buf)
  (let loop ((nodes (code--top-nodes buf)) (depth 0))
    (if (and (= (length nodes) 1)
             (< depth 3)
             (code--wraps-file? buf (car nodes)))
        (let ((inner (code--descend buf (car nodes))))
          (if inner (loop (code--children buf inner) (+ depth 1)) nodes))
        nodes)))

;; the node of that level POINT sits in, or the first one
(define (code--level-node buf pos)
  (let ((nodes (code--fold-nodes buf)))
    (cond ((null? nodes) #f)
          (else
            (let loop ((ns nodes))
              (cond ((null? ns) (car nodes))
                    ((and (<= (code--start (car ns)) pos)
                          (>= (code--end (car ns)) pos))
                     (car ns))
                    (else (loop (cdr ns)))))))))

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

;; The line that holds POS, the lines BEFORE it nearest-first, and the
;; lines after it — in one pass. A list indexed by number costs a walk per
;; index, and a 3600-line file then costs a walk per line.
(define (code--split-at lines pos)
  (let loop ((ls lines) (before '()) (cur #f))
    (cond ((null? ls) (list cur before '()))
          ((<= (code--line-start (car ls)) pos)
           (loop (cdr ls) (if cur (cons cur before) before) (car ls)))
          (else (list cur before ls)))))

(define (code--first-solid ls)
  (cond ((null? ls) #f)
        ((code--line-indent (car ls)) (car ls))
        (else (code--first-solid (cdr ls)))))

;; the lines after L
(define (code--after lines l)
  (cond ((null? lines) '())
        ((= (code--line-start (car lines)) (code--line-start l)) (cdr lines))
        (else (code--after (cdr lines) l))))

;; a block: the line L, plus every line below it that is blank or deeper
(define (code--block-of l after)
  (let ((base (code--line-indent l)))
    (let loop ((ls after) (end (code--line-end l)))
      (cond ((null? ls) (list "block" (code--line-start l) end))
            ((not (code--line-indent (car ls))) (loop (cdr ls) end))
            ((> (code--line-indent (car ls)) base)
             (loop (cdr ls) (code--line-end (car ls))))
            (else (list "block" (code--line-start l) end))))))

;; the first line of LS (ordered by distance from the reader) that OK?
;; accepts, giving up when STOP? says the block ended
(define (code--scan ls ok? stop?)
  (cond ((null? ls) #f)
        ((not (code--line-indent (car ls))) (code--scan (cdr ls) ok? stop?))
        ((ok? (code--line-indent (car ls))) (car ls))
        ((stop? (code--line-indent (car ls))) #f)
        (else (code--scan (cdr ls) ok? stop?))))

(define (code--never ind) #f)

(define (code--indent-ask buf s e op)
  (let* ((lines (code--lines buf))
         (split (code--split-at lines s))
         (here (car split))
         (before (cadr split))
         (after (caddr split))
         ;; point sits on a blank line often — between two definitions —
         ;; and that is not a reason to answer nothing
         (cur (if (and here (code--line-indent here))
                  here
                  (or (code--first-solid before) (code--first-solid after)))))
    (if (not cur)
        #f
        (let* ((base (code--line-indent cur))
               (target
                 (cond ((equal? op 'at) cur)
                       ((equal? op 'top)
                        (if (= base 0)
                            cur
                            (code--scan before (lambda (i) (= i 0)) code--never)))
                       ((equal? op 'parent)
                        (code--scan before (lambda (i) (< i base)) code--never))
                       ((equal? op 'child)
                        (code--scan after (lambda (i) (> i base))
                                    (lambda (i) (<= i base))))
                       ((equal? op 'next)
                        (code--scan after (lambda (i) (= i base))
                                    (lambda (i) (< i base))))
                       ((equal? op 'prev)
                        (code--scan before (lambda (i) (= i base))
                                    (lambda (i) (< i base))))
                       (else #f))))
          (and target (code--block-of target (code--after lines target)))))))

;; One level of an indented block: the lines inside N at the shallowest
;; indent it holds. The fold pass asks for a whole level at once.
(define (code--indent-children buf n)
  (let* ((lines (code--lines buf))
         ;; A block's own first line is its header, not a child of it. The
         ;; FILE has no header line, so there its first line is a child like
         ;; any other — without this the first definition of a file with no
         ;; grammar is invisible to the outline and never folds.
         (file? (equal? (code--kind n) "file"))
         (inside (filter (lambda (l)
                           (and (code--line-indent l)
                                (if file?
                                    (>= (code--line-start l) (code--start n))
                                    (> (code--line-start l) (code--start n)))
                                (<= (code--line-end l) (code--end n))))
                         lines)))
    (if (null? inside)
        '()
        (let ((base (fold (lambda (acc l)
                            (let ((i (code--line-indent l)))
                              (if (or (not acc) (< i acc)) i acc)))
                          #f inside)))
          (map (lambda (l) (code--block-of l (code--after lines l)))
               (filter (lambda (l) (= (code--line-indent l) base)) inside))))))

;;; --- go to definition ----------------------------------------------------------
;;; The seam for LSP. With a language server attached, lsp-definition
;;; answers. Without one, the same file answers: the first line that
;;; defines the symbol under point.

;; the code alphabet: no `*` or `/`, so `M-.` reads `foo` out of `foo/2`
(define (code--symbol-at) (symbol-at-point))

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
    (cond ((and stored (code--holds? stored (point))) (code--show! buf stored))
          (here
            ;; land on the level that folds, not on the module that holds
            ;; it: a reader who must press l twice to reach a definition
            ;; reads two keys before reading any code
            (let* ((n (code--enclosing buf (point)))
                   (n (if (and n (code--wraps-file? buf n))
                          (or (code--level-node buf (point)) n)
                          n)))
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

;; A surface that already answers single keys must keep them. The diff
;; buffer reads n and TAB, dired reads d and m, the chat reads RET — and
;; this mode would take h j k l TAB RET q from all of them, in a buffer
;; that survives a restart. code-browse reads FILES; the rest already
;; have a reader. The shape follows evil--eligible? (evil.scm).
(define code--special-modes
  '("chat-mode" "dired-mode" "notmuch-mode" "diff-mode" "ibuffer-mode"
    "mcp-hub-mode" "agent-mode" "tabulated-list-mode"))

(define (code--eligible? buf)
  (and (not (string-prefix? " " buf))
       (not (process-running? buf))
       (or (buffer-path buf) (equal? buf "*scratch*"))
       (not (member (or (buffer-local buf 'mode-name) "") code--special-modes))))

(define-command "code-browse" "Toggle structural browsing in this buffer"
  (lambda ()
    (let ((buf (current-buffer)))
      (cond
        ((minor-mode-on? buf "code-browse-mode")
         (disable-minor-mode! buf "code-browse-mode")
         (message "code-browse off"))
        ((not (code--eligible? buf))
         (message "code-browse: this buffer has its own keys"))
        (else
          (enable-minor-mode! buf "code-browse-mode")
          (message
            "code-browse: h parent · l child · j/k siblings · TAB fold · RET exit"))))))

(define-command "code-browse-exit" "Leave code-browse in this buffer"
  (lambda ()
    (disable-minor-mode! (current-buffer) "code-browse-mode")
    (message "code-browse off")))

(public! 'code-browse "Toggle structural browsing of the current buffer")
(public! 'code-goto-definition "Go to the definition of the symbol at point")

;;; --- structure for an agent ---------------------------------------------------
;;; The same node backend the reader browses with, as four functions an
;;; agent calls through eval-scheme. A definition is addressed by the LINE
;;; it starts on, so nothing here needs a byte offset or an exact-string
;;; match: read the outline, pick a line, read or replace that definition.
;;; Tree-sitter answers where a grammar parses the buffer; indentation
;;; answers everywhere else, so every file has an outline.
;;;
;;; The node questions read the CURRENT buffer, so every entry point here
;;; scopes itself with with-current-buffer.

(category! 'syntax)
(domain! 'code)
(effects! '(read))

;; a definition's first line, trimmed — what the outline shows and what an
;; agent matches on when it looks for a name
(define (code--head buf n)
  (let* ((text (code--text buf n))
         (nl (string-index text "\n")))
    (string-trim (if nl (substring-bytes text 0 nl) text))))

(define (code--outline-rows buf)
  (map (lambda (n)
         (list (line-number-at-pos (code--start n))
               (code--kind n)
               (code--head buf n)))
       (code--fold-nodes buf)))

;; Every entry point runs through here. The node questions read the CURRENT
;; buffer, and code--top-nodes reads the chosen backend from a local — so the
;; backend must be picked while this buffer IS current, or a file with a
;; grammar gets browsed by indentation.
(define (code--structurally buf k)
  (if (not (buffer-exists? buf))
      (string-append "no such buffer: " buf)
      (with-current-buffer buf
        (lambda ()
          (code--backend buf)
          (k)))))

(define (code-outline buf)
  (code--structurally buf (lambda () (code--outline-rows buf))))

;; the outline rows whose first line contains TEXT — "select the definition
;; called X" without a language table for what a definition looks like
(define (code-find buf text)
  (let ((rows (code-outline buf)))
    (if (string? rows)
        rows
        (filter (lambda (r) (if (string-index (caddr r) text) #t #f)) rows))))

;; the definition that holds LINE. The fold level is the level a reader
;; lands on, so an agent and a reader address the same things.
(define (code--at-line buf line)
  (let* ((pos (line-start-position line))
         (hit (let loop ((ns (code--fold-nodes buf)))
                (cond ((null? ns) #f)
                      ((and (<= (code--start (car ns)) pos)
                            (>= (code--end (car ns)) pos))
                       (car ns))
                      (else (loop (cdr ns)))))))
    (or hit (code--enclosing buf pos))))

(define (code--with-node buf line k)
  (code--structurally buf
        (lambda ()
          (let ((lines (code--buffer-lines buf)))
            ;; line-start-position clamps, so an out-of-range line would
            ;; quietly edit the last definition in the file
            (cond
              ((or (< line 1) (> line lines))
               (string-append "line " (number->string line)
                              " is outside the buffer — it has "
                              (number->string lines) " lines"))
              (else
                (let ((n (code--at-line buf line)))
                  (if n
                      (k n)
                      (string-append "no definition holds line "
                                     (number->string line)
                                     " — call (code-outline BUF) for the lines that do")))))))))

(define (code-read buf line)
  (code--with-node buf line (lambda (n) (code--text buf n))))

(effects! '(write))

(define (code-replace! buf line new)
  (code--with-node buf line
    (lambda (n)
      (let ((start (code--start n))
            (kind (code--kind n)))
        ;; delete then insert at the same offset: one definition swapped
        ;; for another, with no exact-string match to get wrong
        (buffer-delete-range! buf start (- (code--end n) start))
        (buffer-insert! buf start new)
        (string-append "replaced the " kind " at line " (number->string line))))))

(effects! '(read))
(public! 'code-outline
  "(code-outline BUF) — every definition as (LINE KIND FIRST-LINE)")
(public! 'code-find
  "(code-find BUF TEXT) — the outline rows whose first line contains TEXT")
(public! 'code-read
  "(code-read BUF LINE) — the exact text of the definition that holds LINE")
(effects! '(write))
(public! 'code-replace!
  "(code-replace! BUF LINE NEW) — replace the whole definition that holds LINE")

;;; --- code-mode: the coding workspace -----------------------------------------
;;; code-browse READS a source file. code-mode WRITES one, with an agent.
;;; The mode joins the buffer to a group, loads the coding presets into the
;;; chat's tool surface, and turns on llm-mode. `C-c s` opens the buffer's
;;; scratch, which inherits the same model and presets: the user chats in the
;;; scratch, and the agent edits the source buffer with the editor's own
;;; tools. `C-c c` opens the group chat over the same surface.
;;;
;;; Everything the mode changes is saved on enable and restored on disable.
;;; The minor-mode local and the workspace locals survive a daemon reload,
;;; and the setup fn re-runs on restore.
;;;
;;; M-x code-mode toggles. Knobs live in the 'code customize group.

(domain! 'code)
(effects! '(write))

(defgroup 'code "Coding with an agent.")

;; re-apply to every live code-mode buffer so a customize change takes hold
(define (code-mode--refresh! _v)
  (for-each
    (lambda (buf)
      (when (minor-mode-on? buf "code-mode") (code-mode--apply! buf)))
    (buffer-list)))

(defcustom 'code-presets '(aimax)
  "Tool presets loaded whenever code-mode is active. `aimax` is the editor's own tool registry, which is what lets the agent read and write buffers. Set a symbol list such as '(aimax web) in ~/.aimax/ai-config.scm."
  'group 'code 'type 'list 'set code-mode--refresh!)

(defcustom 'code-model ""
  "Model for a code-mode buffer and its scratch chat. Empty means the editor's default model."
  'group 'code 'type 'string 'set code-mode--refresh!)

(defcustom 'code-instructions
  (string-append
    "You are working on code in this editor. Read the structure of a file "
    "first: (code-outline \"BUF\") gives one row per definition as "
    "(LINE KIND FIRST-LINE). (code-find \"BUF\" \"text\") gives the rows "
    "whose first line contains that text. Then read exactly one definition "
    "with (code-read \"BUF\" LINE), and replace exactly one with "
    "(code-replace! \"BUF\" LINE NEW). Use those four for whole "
    "definitions — they address code by structure, so no string has to "
    "match. Tree-sitter answers where the buffer has a grammar, and "
    "indentation answers everywhere else, so read the result back after a "
    "replace. For a smaller change use (buffer-replace! \"BUF\" OLD NEW), "
    "(buffer-replace-all! \"BUF\" OLD NEW), "
    "(buffer-insert-before! \"BUF\" ANCHOR TEXT), "
    "(buffer-insert-after! \"BUF\" ANCHOR TEXT) or "
    "(buffer-delete-text! \"BUF\" TEXT). Each of these takes text you have "
    "read, never a byte offset, and each one reports what it did. Every "
    "edit lands in the live buffer, never in the file — the user saves. "
    "Make the smallest edit that does the job, and keep the file's style.")
  "Standing instructions for a chat that works on a code-mode buffer. Empty means no code instructions."
  'group 'code 'type 'string 'set code-mode--refresh!)

;; The one seam the prompts read. editor.scm asks it from BOTH paths that
;; build a system prompt — M-o in a buffer and the chat lane — so a chat
;; about this code gets the same instructions whichever surface it rides.
;; DOCS is the group's buffers; a group with no code-mode buffer says
;; nothing, and the prompt is unchanged for every other kind of work.
(define (code-mode-instructions docs)
  (if (and (not (equal? code-instructions ""))
           (pair? (filter (lambda (b) (minor-mode-on? b "code-mode")) docs)))
      code-instructions
      ""))

(define (code-mode--saved buf key)
  (let ((hit (assoc key (or (buffer-local buf 'code-mode-saved) '()))))
    (and hit (cadr hit))))

(define (code-mode--presets buf)
  ;; Rebuild from the pre-code-mode value on every refresh. Removing a preset
  ;; from code-presets then takes effect at once, instead of leaving behind
  ;; the value the previous refresh installed.
  (let ((base (or (code-mode--saved buf 'chat-presets) '())))
    (append code-presets
            (filter (lambda (preset) (not (member preset code-presets))) base))))

(define (code-mode--workspace-buffers buf)
  (let ((g (buffer-group buf)))
    (if g (group-buffers g) (list buf))))

(define (code-mode--workspace? buf)
  (and buf
       (buffer-exists? buf)
       (pair? (filter (lambda (b) (minor-mode-on? b "code-mode"))
                      (code-mode--workspace-buffers buf)))))

;; A code workspace can reload Scheme and continue its interrupted turn.
(allow-command-when! "restart-daemon" code-mode--workspace?)

;; A code change touches more than one file, so the group is the PROJECT
;; when the buffer has one: the chat then names every project buffer, and
;; `C-x p s` opens the same conversation for the whole project. A file
;; outside a project founds a group of its own, the way writing-mode does.
;; A group the user chose already wins — this only fills an empty one.
(define (code-mode--group buf)
  (or (buffer-group buf)
      (let ((root (buffer-project-root buf)))
        (if (equal? root "")
            (group-ensure! buf)
            (begin (buffer-set-local! buf 'group root) root)))))

(define (code-mode--label buf)
  (let ((presets (or (buffer-local buf 'chat-presets) '())))
    (if (null? presets)
        "code"
        (string-append "code · "
                       (string-join (map symbol->string presets) " ")))))

(define (code-mode--apply! buf)
  ;; remember what we clobber, once — the saved alist persists, and the
  ;; restore path re-runs this fn, which must not re-save code-mode's own
  ;; values over the user's
  (unless (buffer-local buf 'code-mode-saved)
    (buffer-set-local! buf 'code-mode-saved
      (list (list 'group (or (buffer-local buf 'group) #f))
            (list 'chat-presets (or (buffer-local buf 'chat-presets) #f))
            (list 'llm-model (or (buffer-local buf 'llm-model) #f))
            (list 'modeline-info (or (buffer-local buf 'modeline-info) #f))
            (list 'llm-mode-on (minor-mode-on? buf "llm-mode")))))
  ;; the group is the agent's surface: it names these buffers in the chat's
  ;; system prompt, and `C-c g` adds any file the change touches from outside
  (buffer-set-local! buf 'group (code-mode--group buf))
  (buffer-set-local! buf 'chat-presets (code-mode--presets buf))
  ;; an empty setting means the editor's default, so clearing it must give the
  ;; buffer its own model back — the same rebuild-from-base rule as the presets
  (buffer-set-local! buf 'llm-model
    (if (equal? code-model "")
        (code-mode--saved buf 'llm-model)
        code-model))
  ;; "loads the presets" means the servers they name connect now, not on the
  ;; first question. The aimax tools are native to this process, so
  ;; chat-remote-servers leaves them out; mcp.scm loads after this file.
  (when (and (boundp (quote chat-remote-servers)) (boundp (quote mcp-ensure!)))
    (for-each mcp-ensure! (chat-remote-servers buf)))
  ;; llm-mode owns in-buffer prompting: M-o here sends the source file, and
  ;; M-o in the scratch sends the conversation.
  (enable-minor-mode! buf "llm-mode")
  ;; A scratch that is already open inherited the presets this buffer held
  ;; BEFORE the mode, so push the new ones to it.
  (when (boundp (quote scratch-refresh-llm!))
    (scratch-refresh-llm! buf))
  (buffer-set-local! buf 'modeline-info (code-mode--label buf)))

(define (code-mode--teardown! buf)
  (buffer-set-local! buf 'group (code-mode--saved buf 'group))
  (buffer-set-local! buf 'chat-presets (code-mode--saved buf 'chat-presets))
  (buffer-set-local! buf 'llm-model (code-mode--saved buf 'llm-model))
  (buffer-set-local! buf 'modeline-info (code-mode--saved buf 'modeline-info))
  (unless (code-mode--saved buf 'llm-mode-on)
    (disable-minor-mode! buf "llm-mode"))
  (when (boundp (quote scratch-refresh-llm!))
    (scratch-refresh-llm! buf))
  (buffer-set-local! buf 'code-mode-saved #f))

(register-minor-mode! "code-mode" code-mode--apply! code-mode--teardown!)

(define-command "code-mode" "Toggle the agent coding workspace in this buffer"
  (lambda ()
    (if (toggle-minor-mode! "code-mode")
        (message (string-append (code-mode--label (current-buffer))
                                " · C-c s scratch · M-o sends it"))
        (message "Code mode disabled"))))

(mode-doc! "code-mode"
  "An agent coding workspace. The buffer joins a group and loads the coding presets. `C-c s` opens its scratch chat, `M-o` sends that chat, and the agent edits the buffer with the editor's own tools. `C-c c` opens the group chat instead.")

(public! 'code-mode "Toggle the agent coding workspace in the current buffer")
(effects! '(pure))
(public! 'code-mode-instructions
  "(code-mode-instructions DOCS) — the code instructions a prompt adds for those buffers")
