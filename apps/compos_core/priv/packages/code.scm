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
  ;; A buffer loaded headlessly — (find-file) with no display — has no
  ;; mode and so no ts-lang. Apply the mode its file name says, the same
  ;; mode a visit applies, or a file with a grammar parses by indentation.
  (when (and (not (buffer-local buf 'ts-lang))
             (not (buffer-local buf 'mode-name))
             (buffer-path buf))
    (auto-mode (buffer-path buf)))
  (buffer-set-local! buf 'code-backend
    (if (and (buffer-local buf 'ts-lang) (ts-node "" 0 0 'at)) "ts" "indent")))

;; Desktop restore re-arms the mode for a buffer that is not on screen,
;; and the node questions read the CURRENT buffer, so the backend cannot
;; be chosen then. The first motion is on screen by definition: choose it
;; there instead of browsing a source file by indentation for the rest of
;; the session.
;;
;; An "indent" verdict on a file buffer that never got its mode is not a
;; decision — it is a restored checkpoint or a headless load from before
;; the mode ran. Re-pick, so the grammar gets its chance.
(define (code--backend buf)
  (let ((cached (buffer-local buf 'code-backend)))
    (if (or (not cached)
            (and (equal? cached "indent")
                 (not (buffer-local buf 'mode-name))
                 (buffer-path buf)))
        (begin (code--pick-backend! buf)
               (buffer-local buf 'code-backend))
        cached)))

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
      ;; only a buffer with an attached server asks LSP; the fallback
      ;; below keeps answering everywhere else
      ((and (boundp 'lsp-definition)
            (buffer-local (current-buffer) 'lsp-server))
       (lsp-definition sym))
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
(define-command "code-goto-definition" "Go to the definition of the symbol at point, or follow the link there"
  (lambda ()
    (unless (goto-address-follow-at-point!)
      (code--goto-definition))))

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
            (list 'modeline-info (buffer-local buf 'modeline-info)))))
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
  ;; the keys are the mode's map, and it leaves with the mode
  (buffer-set-read-only! buf (code--saved buf 'read-only))
  (buffer-set-local! buf 'modeline-info (code--saved buf 'modeline-info))
  (overlay-clear! buf 'code-scope)
  (fold-clear! buf 'code)
  (buffer-set-local! buf 'code-folds #f)
  (buffer-set-local! buf 'code-node #f)
  (buffer-set-local! buf 'code-backend #f)
  (buffer-set-local! buf 'code-saved #f))

(register-minor-mode! "code-browse-mode" code--setup! code--teardown!)
(minor-mode-keys! "code-browse-mode" code--keys)

;; A surface that already answers single keys must keep them. The diff
;; buffer reads n and TAB, dired reads d and m, the chat reads RET — and
;; this mode would take h j k l TAB RET q from all of them, in a buffer
;; that survives a restart. code-browse reads FILES; the rest already
;; have a reader. The shape follows evil--eligible? (evil.scm).
(define code--special-modes
  '("chat-mode" "dired-mode" "notmuch-mode" "diff-mode" "switch-mode"
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
(effects! '(pure))

;; a definition's first line, trimmed — the name and doc fall back to it
(define (code--head buf n)
  (let* ((text (code--text buf n))
         (nl (string-index text "\n")))
    (string-trim (if nl (substring-bytes text 0 nl) text))))

;; The words a first line spends before it says the name. A keyword list,
;; not a language table: strip leading punctuation, drop these, and the
;; next token is the name.
(define code--name-keywords
  '("define-command" "define-mode" "define-tool!" "define-record" "define"
    "defmodule" "defmacrop" "defmacro" "defprotocol" "defimpl" "defcustom"
    "defgroup" "defrecipe!" "defcomponent" "defp" "def" "defn-" "defn"
    "class" "interface" "trait" "struct" "enum" "impl" "type" "module"
    "function" "func" "fn" "sub" "proc" "method" "object"
    "public" "private" "protected" "static" "async" "export" "extern"
    "pub" "const" "let" "var" "final" "abstract" "override" "inline"
    "test" "describe" "it"))

(define (code--group-text line g i)
  (substring-bytes line (car (nth i g)) (cadr (nth i g))))

;; the identifier a definition's first line declares — "two" from
;; "def two(x) do", "morg-lines" from "(define (morg-lines buf)"
(define (code--name head)
  (let ((h (re-groups "^#{1,6}[ \\t]+(.+)$" head 0)))
    (if h
        ;; a markdown heading's name is the heading text
        (string-trim (code--group-text head h 1))
        (let loop ((line head) (steps 0))
          (let ((q (re-groups "^\"([^\"]+)\"" line 0)))
            (if q
                ;; a quoted name — (define-command "code-browse" …
                (code--group-text line q 1)
                (let ((g (re-groups
                           "^[('\\[{#@ \\t]*([^ \\t()'\"\\[\\]{},:;=<]+)[ \\t]*(.*)$"
                           line 0)))
                  (cond ((not g) (string-trim head))
                        (else
                          (let ((tok (code--group-text line g 1))
                                (rest (code--group-text line g 2)))
                            (if (and (< steps 6)
                                     (member tok code--name-keywords))
                                (loop (string-trim rest) (+ steps 1))
                                tok)))))))))))

;;; --- the doc column ------------------------------------------------------------
;;; A definition's doc is the comment block right above it, an @doc above
;;; it, or the doc string just inside it. With none of those, the doc
;;; column repeats the first line, so a row always says something.

(define (code--line-at lines count i)
  (and (>= i 0) (< i count) (list-ref lines i)))

;; "text" from a comment line — ";; text", "# text", "// text", "-- text"
(define (code--comment-doc line)
  (let ((g (re-groups "^[ \\t]*(;+|#+|//+|--+)[ \\t]?(.*)$" line 0)))
    (and g (string-trim (code--group-text line g 2)))))

;; "text" from a one-line attribute doc — @doc "text"
(define (code--attr-doc line)
  (let ((g (re-groups "^[ \\t]*@(module)?doc[ \\t]+\"([^\"]*)\"[ \\t]*$" line 0)))
    (and g (code--group-text line g 2))))

;; a contiguous comment block reads top-down: its first line is the summary
(define (code--comment-block-top lines count idx)
  (let loop ((i idx) (top #f))
    (let ((d (let ((l (code--line-at lines count i)))
               (and l (code--comment-doc l)))))
      (if d (loop (- i 1) d) top))))

;; the line right under an @doc \"\"\" opener, found by walking up from
;; the closing \"\"\" that sits directly above the definition
(define (code--heredoc-doc lines count idx)
  (let loop ((i idx) (below #f) (steps 0))
    (let ((l (code--line-at lines count i)))
      (cond ((or (not l) (> steps 20)) #f)
            ((re-match? "^[ \\t]*@(module)?doc[ \\t]+\"\"\"" l)
             (and below (string-trim below)))
            (else (loop (- i 1) l (+ steps 1)))))))

;; IDX is the 0-based line right above the definition
(define (code--doc-above lines count idx)
  (let ((l (code--line-at lines count idx)))
    (and l
         (or (and (code--comment-doc l)
                  (code--comment-block-top lines count idx))
             (code--attr-doc l)
             (and (re-match? "^[ \\t]*\"\"\"[ \\t]*$" l)
                  (code--heredoc-doc lines count (- idx 1)))))))

;; the doc string just inside the node — python style
(define (code--doc-inside buf n)
  (let loop ((ls (cdr (string-split (code--text buf n) "\n"))))
    (cond ((null? ls) #f)
          ((equal? (string-trim (car ls)) "") (loop (cdr ls)))
          (else
            (let ((g (re-groups "^[ \\t]*(\"\"\"|''')[ \\t]*(.*)$" (car ls) 0)))
              (and g
                   (let ((rest (string-trim (code--group-text (car ls) g 2))))
                     (cond ((equal? rest "")
                            (and (pair? (cdr ls)) (string-trim (cadr ls))))
                           ;; strip a closing quote on a one-line doc
                           ((re-groups "^(.+)(\"\"\"|''')$" rest 0)
                            (let ((c (re-groups "^(.+)(\"\"\"|''')$" rest 0)))
                              (string-trim (code--group-text rest c 1))))
                           (else rest)))))))))

;; A line number read now is wrong later. An agent calls code-outline, thinks
;; for a few seconds, then calls code-replace! with a line from that outline —
;; and if a person added a line above meanwhile, that number now names a
;; different definition. So the outline also anchors every line it reports, and
;; code--with-node follows the anchor instead of the number.
;;
;; The name rides along as a second check: an anchor still resolves after its
;; definition is deleted, and the name is what proves it is the same one. It
;; also catches a subtler case. Two comments at the top level change which
;; level folds, so the outline collapses to the module, and a line that used to
;; name a function now names the whole file. The check refuses; without it the
;; replacement would silently swallow everything.
;;
;; One outline at a time. Each call replaces the map, because the lines an
;; agent holds come from the outline it last read.
(define (code--remember-anchors! buf nodes)
  (buffer-set-local! buf 'code-anchors
    (map (lambda (n)
           (list (line-number-at-pos (code--start n))
                 (buffer-anchor buf (code--start n))
                 (code--name (code--head buf n))))
         nodes)))

;; buffer-local answers #f when the outline has never run here.
(define (code--anchor-row buf line)
  (let ((anchors (buffer-local buf 'code-anchors)))
    (and anchors (assoc line anchors))))

(define (code--outline-rows buf)
  (let* ((lines (string-split (buffer-text buf) "\n"))
         (count (length lines))
         ;; a comment is context for a definition, not a definition: it
         ;; feeds the doc column and stays out of the outline
         (nodes (filter (lambda (n) (not (string-index (code--kind n) "comment")))
                        (code--fold-nodes buf)))
         (rows (map (lambda (n)
                      (let ((line (line-number-at-pos (code--start n)))
                            (head (code--head buf n)))
                        (list line
                              (code--kind n)
                              (code--name head)
                              (or (code--doc-above lines count (- line 2))
                                  (code--doc-inside buf n)
                                  head))))
                    nodes)))
    (code--remember-anchors! buf nodes)
    rows))

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

;; the outline rows whose name or doc contains TEXT — "select the definition
;; called X" without a language table for what a definition looks like
(define (code-find buf text)
  (let ((rows (code-outline buf)))
    (if (string? rows)
        rows
        (filter (lambda (r)
                  (if (string-index (string-append (nth 2 r) " " (nth 3 r)) text)
                      #t #f))
                rows))))

;; the definition that holds LINE. The fold level is the level a reader
;; lands on, so an agent and a reader address the same things.
(define (code--at-line buf line)
  (let* ((row (code--anchor-row buf line))
         (anchored (and row (nth 1 row) (buffer-anchor-pos buf (nth 1 row))))
         (pos (or anchored (line-start-position line)))
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
                  (cond
                    ((not n)
                     (string-append "no definition holds line "
                                    (number->string line)
                                    " — call (code-outline BUF) for the lines that do"))
                    ((code--moved-on? buf line n)
                     (string-append "line " (number->string line)
                                    " no longer holds " (code--anchor-name buf line)
                                    " — the buffer changed since the outline;"
                                    " call (code-outline BUF) again"))
                    (else (k n))))))))))

;; The anchor found a definition; this asks whether it is still the one the
;; outline named. A definition deleted since then leaves an anchor that
;; resolves onto its neighbour, and only the name catches that.
(define (code--anchor-name buf line)
  (let ((row (code--anchor-row buf line)))
    (if (and row (nth 2 row)) (nth 2 row) "that definition")))

(define (code--moved-on? buf line n)
  (let ((row (code--anchor-row buf line)))
    (and row
         (nth 2 row)
         (not (equal? (nth 2 row) (code--name (code--head buf n)))))))

(define (code-read buf line)
  (code--with-node buf line (lambda (n) (code--text buf n))))

(effects! '(write))

(define (code-replace! buf line new)
  (code--with-node buf line
    (lambda (n)
      (let ((start (code--start n))
            (kind (code--kind n)))
        ;; One buffer message: parallel readers see the old definition or
        ;; the new one, never the empty interval between delete and insert.
        (buffer-replace-range! buf start (- (code--end n) start) new)
        (string-append "replaced the " kind " at line " (number->string line))))))

;;; --- sexp selection: the smallest expression around a text anchor -------------
;;; The definition API addresses whole definitions. These two address any
;;; expression, the way a lisper marks a sexp: name a unique piece of its
;;; text, and the tree names the expression that spans it. LEVELS parents
;;; widen the selection, like pressing expand-region again.

(effects! '(read))

;; the smallest node that spans the one occurrence of ANCHOR, widened by
;; LEVELS parents. A string result is the error to show the caller.
(define (code--sexp-node buf anchor levels)
  (let ((pos (buffer--one-hit buf anchor "anchor")))
    (if (string? pos)
        pos
        (let ((n (code--ask buf "" pos (+ pos (string-byte-length anchor)) 'at)))
          (if (not n)
              "error: no expression spans the anchor"
              (let loop ((n n) (k (or levels 0)))
                (if (<= k 0)
                    n
                    (let ((up (code--ask-node buf n 'parent)))
                      (if up (loop up (- k 1)) n)))))))))

(define (code-sexp buf anchor &optional levels)
  (code--structurally buf
    (lambda ()
      (let ((n (code--sexp-node buf anchor levels)))
        (if (string? n) n (code--text buf n))))))

(effects! '(write))

(define (code-sexp-replace! buf anchor new &optional levels)
  (code--structurally buf
    (lambda ()
      (let ((n (code--sexp-node buf anchor levels)))
        (if (string? n)
            n
            (let ((start (code--start n)))
              (buffer-replace-range! buf start (- (code--end n) start) new)
              (string-append "replaced the " (code--kind n))))))))

(effects! '(read))
(public! 'code-outline
  "(code-outline BUF) — every definition as (LINE KIND NAME DOC); DOC is the docstring or the first line")
(public! 'code-find
  "(code-find BUF TEXT) — the outline rows whose name or doc contains TEXT")
(public! 'code-read
  "(code-read BUF LINE) — the exact text of the definition that holds LINE")
(public! 'code-sexp
  "(code-sexp BUF ANCHOR [LEVELS]) — the smallest expression that spans the unique ANCHOR text; LEVELS parents widen it")

(define-tool! 'code-outline
  "List every definition in a live source buffer as (LINE KIND NAME DOC). Use this before code-read; independent read tools can run concurrently."
  (list (list 'buffer "string" "live source buffer name"))
  (lambda (args)
    (value->string (code-outline (custom--plist-get args 'buffer))))
  '(read))

(define-tool! 'code-read
  "Read the complete definition holding LINE in a live source buffer. Obtain LINE from code-outline."
  (list (list 'buffer "string" "live source buffer name")
        (list 'line "number" "1-based line from code-outline"))
  (lambda (args)
    (code-read (custom--plist-get args 'buffer)
               (custom--plist-get args 'line)))
  '(read))

(effects! '(write))
(public! 'code-replace!
  "(code-replace! BUF LINE NEW) — replace the whole definition that holds LINE")
(public! 'code-sexp-replace!
  "(code-sexp-replace! BUF ANCHOR NEW [LEVELS]) — replace the smallest expression that spans the unique ANCHOR text")

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

(defcustom 'code-presets '(compos)
  "Tool presets loaded whenever code-mode is active. `compos` is the editor's own tool registry, which is what lets the agent read and write buffers. Set a symbol list such as '(compos web) in ~/.compos/ai-config.scm."
  'group 'code 'type 'list 'set code-mode--refresh!)

(defcustom 'code-model ""
  "Model for a code-mode buffer and its scratch chat. Empty means the editor's default model."
  'group 'code 'type 'string 'set code-mode--refresh!)

(defcustom 'code-instructions
  (string-append
    "You are working on code in this editor. Read the structure of a file "
    "first: (code-outline \"BUF\") gives one row per definition as "
    "(LINE KIND NAME DOC) — DOC is the docstring, or the first line when "
    "there is none. (code-find \"BUF\" \"text\") gives the rows "
    "whose name or doc contains that text. Then read exactly one definition "
    "with (code-read \"BUF\" LINE), and replace exactly one with "
    "(code-replace! \"BUF\" LINE NEW). Use those four for whole "
    "definitions — they address code by structure, so no string has to "
    "match. Tree-sitter answers where the buffer has a grammar, and "
    "indentation answers everywhere else, so read the result back after a "
    "replace. Below a definition, select and edit by expression: "
    "(code-sexp \"BUF\" \"anchor\") returns the smallest expression that "
    "spans that unique text, an optional LEVELS argument widens it by "
    "parents, and (code-sexp-replace! \"BUF\" \"anchor\" NEW) replaces it. "
    "For a smaller change use (buffer-replace! \"BUF\" OLD NEW), "
    "(buffer-replace-all! \"BUF\" OLD NEW), "
    "(buffer-insert-before! \"BUF\" ANCHOR TEXT), "
    "(buffer-insert-after! \"BUF\" ANCHOR TEXT) or "
    "(buffer-delete-text! \"BUF\" TEXT). Each of these takes text you have "
    "read, never a byte offset, and each one reports what it did. Every "
    "edit lands in the live buffer, so the change is attributed and the "
    "open buffer stays true. Then save it: code you replaced in a file is "
    "not done until the file holds it, and compiled source only reaches "
    "the running editor through a save. "
    "Make the smallest edit that does the job, and keep the file's style. "
    "Keep file and shell changes under (default-directory). A workspace-id "
    "means worktree-init isolated this task from the primary checkout. "
    "Code-mode creates the task worktree before the agent starts. "
    "The browser category is denied in code-mode by default. Verify editor "
    "UI through compos buffers, overlays, render state, components, and the "
    "real key dispatcher. Do not use Chrome or tab-* calls. If every "
    "editor-native approach fails and browser access is essential, explain "
    "why and ask the user to enable M-x browser-mode. Do not ask before then.")
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

;; Browser access is an explicit user escalation for a coding workspace. The
;; agent can ask for it after editor-native checks fail, but cannot use it first.
;; This is a convenience guardrail, and the user can override the Scheme hook.
(define (code-mode--workspace-buffers buf)
  (let ((g (buffer-group buf)))
    (if g (group-buffers g) (list buf))))

(define (code-mode--workspace? buf)
  (and buf
       (buffer-exists? buf)
       (pair? (filter (lambda (b) (minor-mode-on? b "code-mode"))
                      (code-mode--workspace-buffers buf)))))

;; A code workspace can reload Scheme and then continue its interrupted turn.
(allow-command-when! "restart-daemon" code-mode--workspace?)

(define (code-mode--browser-enabled? buf)
  (pair? (filter (lambda (b) (minor-mode-on? b "browser-mode"))
                 (code-mode--workspace-buffers buf))))

(set! *browser-tool-policy*
  (lambda (buf)
    (if (and (code-mode--workspace? buf)
             (not (code-mode--browser-enabled? buf)))
        'deny
        'allow)))

(define (browser-mode--apply! buf) #t)
(define (browser-mode--teardown! buf) #t)
(register-minor-mode! "browser-mode" browser-mode--apply! browser-mode--teardown!)

(define-command "browser-mode" "Toggle agent browser access for this workspace"
  (lambda ()
    (if (toggle-minor-mode! "browser-mode")
        (message "Browser mode enabled for this workspace")
        (message "Browser mode disabled for this workspace"))))

(mode-doc! "browser-mode"
  "An explicit last-resort browser grant for a code-mode workspace. Code agents must exhaust compos-native verification before asking for it.")

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
  (let ((presets (or (buffer-local buf 'chat-presets) '()))
        (workspace (or (buffer-local buf 'workspace-name)
                       (buffer-local buf 'workspace-id))))
    (string-append
      "code"
      (if workspace (string-append " · " workspace) "")
      (if (null? presets)
          ""
          (string-append " · "
                         (string-join (map symbol->string presets) " "))))))

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
  ;; first question. The compos tools are native to this process, so
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
  (buffer-set-local! buf 'modeline-info (code-mode--label buf))
  (when (boundp (quote workspace-llm-defaults-note!))
    (workspace-llm-defaults-note! buf)))

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

(define (code-mode--enable! buf use-worktree)
  (buffer-set-local! buf 'workspace-isolation-choice
    (if use-worktree "worktree" "current"))
  (let ((target (if (and use-worktree
                         (boundp (quote worktree-init-buffer!)))
                    (worktree-init-buffer! buf)
                    buf)))
    (buffer-set-local! target 'workspace-isolation-choice
      (if use-worktree "worktree" "current"))
    (enable-minor-mode! target "code-mode")
    (message (string-append (code-mode--label target)
                            " · C-c s scratch · M-o sends it"))))

(define-command "code-mode" "Toggle the agent coding workspace in this buffer"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (minor-mode-on? buf "code-mode")
          (begin
            (disable-minor-mode! buf "code-mode")
            (message "Code mode disabled"))
          (if (and (boundp (quote worktree-init-needs-new?))
                   (worktree-init-needs-new? buf))
              (y-or-n "Create a new worktree for code mode?"
                (lambda () (code-mode--enable! buf #t))
                (lambda () (code-mode--enable! buf #f)))
              (code-mode--enable! buf #t))))))

(mode-doc! "code-mode"
  "The agent coding surface. Enabling it asks before it creates a task worktree. Existing worktrees open directly.")

(public! 'code-mode "Toggle the agent coding workspace in the current buffer")
(effects! '(pure))
(public! 'code-mode-instructions
  "(code-mode-instructions DOCS) — the code instructions a prompt adds for those buffers")

;;; --- code-agent-mode: the chat that writes code -------------------------------
;;; code-mode starts from a source buffer. code-agent-mode starts from the
;;; CHAT. Every chat wears it: chat-mode setup turns it on. The mode prompts
;;; the chat to load code-editing once, and it adds the coding tool presets.
;;;
;;; The mode keeps the chat on the backend the chat already has. It changes
;;; the connector only when code-agent-connector names one. That knob is
;;; empty by default, so a chat stays on the current default connector.
;;; A connector change restarts the session, so the switch waits until the
;;; turn ends. It does not kill work.
;;;
;;; agent.scm reports every tool call to code-agent-note-tool!. The first
;;; call that edits code turns the mode on for a chat that does not wear it.
;;;
;;; M-x code-agent-mode toggles it by hand. Knobs live in the 'code group.

(domain! 'code)
(effects! '(write))

(defcustom 'code-agent-auto #t
  "Turn on code-agent-mode when a chat's agent edits code. Every chat already wears the mode; this covers a chat that does not."
  'group 'code 'type 'boolean)

(defcustom 'code-agent-connector ""
  "Connector for a chat in code-agent-mode. Empty, the default, keeps the chat on its own connector."
  'group 'code 'type 'string)

(defcustom 'code-agent-model ""
  "Model for a chat in code-agent-mode. Empty means the connector's default model. Read only when code-agent-connector names a connector."
  'group 'code 'type 'string)

(defcustom 'code-agent-effort ""
  "Reasoning effort for a chat in code-agent-mode. Empty means the connector's default. Read only when code-agent-connector names a connector."
  'group 'code 'type 'string)

;;; Which tool calls mean "this agent edits code"?
;;;   - an ACP tool call of kind "edit" (a file edit by an ACP adapter)
;;;   - a structural code edit through eval-scheme
;;;   - a text edit whose payload names a live buffer with a tree-sitter
;;;     grammar

(define *code-agent-edit-calls*
  '("code-replace!" "code-sexp-replace!"))

(define *code-agent-text-edit-calls*
  '("buffer-replace!" "buffer-replace-all!" "buffer-insert-before!"
    "buffer-insert-after!" "buffer-delete-text!"))

(define (code-agent--contains-any? text names)
  (pair? (filter (lambda (n) (if (string-index text n) #t #f)) names)))

;; the quoted strings in a tool payload are the candidate buffer names
(define (code-agent--quoted-names input)
  (map (lambda (r)
         (substring-bytes input (+ (car r) 1) (- (cadr r) 1)))
       (re-find* "\"[^\"\n]+\"" input)))

(define (code-agent--code-buffer? name)
  (and (buffer-exists? name)
       (equal? (code--backend name) "ts")))

(define (code-agent--edits-code? kind title input)
  (or (equal? kind "edit")
      (let ((text (string-append title " " input)))
        (or (code-agent--contains-any? text *code-agent-edit-calls*)
            (and (code-agent--contains-any? text *code-agent-text-edit-calls*)
                 (pair? (filter code-agent--code-buffer?
                                (code-agent--quoted-names input))))))))

;; A code-mode workspace already sets its own model, and a writing
;; workspace edits prose. Neither chat takes the mode from a tool call.
;; The mode does not need a connector of its own to be worth turning on:
;; it carries the code-editing instruction and the coding tool presets.
(define (code-agent--eligible? buf)
  (and code-agent-auto
       (not (minor-mode-on? buf "code-agent-mode"))
       (not (code-mode--workspace? buf))
       (null? (filter (lambda (b) (minor-mode-on? b "writing-mode"))
                      (code-mode--workspace-buffers buf)))))

;; is the chat already on the coding preset?
(define (code-agent--on-target? buf)
  (and (equal? (or (buffer-local buf 'agent-connector) "") code-agent-connector)
       (or (equal? code-agent-model "")
           (equal? (or (buffer-local buf 'agent-model) "") code-agent-model))
       (or (equal? code-agent-effort "")
           (equal? (or (buffer-local buf 'agent-effort) "") code-agent-effort))))

;; Does the mode name a backend of its own? Empty means no: the chat keeps
;; the connector it already has, which is the current default.
(define (code-agent--pins?)
  (not (equal? code-agent-connector "")))

;; The switch itself. A live session goes through chat-switch! — the one
;; switch function. A chat with no live runtime only changes its identity
;; locals: the next send attaches on them, and a desktop restore must not
;; spawn a backend.
(define (code-agent--switch-now! buf)
  (unless (or (not (code-agent--pins?)) (code-agent--on-target? buf))
    (let ((slug (buffer-local buf 'agent-slug)))
      (if (and slug (not (equal? (agent-status slug) 'dead)))
          (chat-switch! buf code-agent-connector code-agent-model
                        (if (equal? code-agent-effort "") #f code-agent-effort))
          (begin
            (buffer-set-local! buf 'agent-connector code-agent-connector)
            (buffer-set-local! buf 'agent-model
              (if (equal? code-agent-model "") #f code-agent-model))
            (unless (equal? code-agent-effort "")
              (buffer-set-local! buf 'agent-effort code-agent-effort))))
      (message (string-append "code-agent: " code-agent-connector
                              (if (equal? code-agent-model "")
                                  ""
                                  (string-append " · " code-agent-model))
                              (if (equal? code-agent-effort "")
                                  ""
                                  (string-append " · " code-agent-effort)))))))

;; What tool presets does this chat already receive? chat-presets-of adds the
;; intrinsic compos bridge, so the raw local understates the surface. mcp.scm
;; loads after this file, so ask only when the function is there.
(define (code-agent--effective-presets buf)
  (if (boundp (quote chat-presets-of))
      (chat-presets-of buf)
      (or (buffer-local buf 'chat-presets) '())))

;; Only the FIRST enable saves state and moves the chat. The setup re-runs
;; on desktop restore, and a re-run must not undo a model the user chose
;; while the mode was on.
(define (code-agent--apply! buf)
  (when (boundp (quote prompt-part-set!))
    (prompt-part-set! buf "code-agent" (code-agent-system-note buf)))
  (unless (buffer-local buf 'code-agent-saved)
    ;; 'pinned records whether this enable took the chat's LLM identity. The
    ;; teardown restores that identity only when the enable took it, so a
    ;; mode that changed nothing never restarts a session on the way out.
    (buffer-set-local! buf 'code-agent-saved
      (list (list 'pinned (code-agent--pins?))
            (list 'agent-connector (or (buffer-local buf 'agent-connector) #f))
            (list 'agent-model (or (buffer-local buf 'agent-model) #f))
            (list 'agent-effort (or (buffer-local buf 'agent-effort) #f))
            (list 'chat-presets (or (buffer-local buf 'chat-presets) #f))))
    ;; the chat gains the coding tool presets, like a code-mode buffer does.
    ;; Only a preset the chat does not already receive is a change: every
    ;; chat receives compos, and marking a fresh chat dirty for it makes the
    ;; first send reconnect a session that already holds those servers.
    (let ((missing (filter (lambda (p)
                             (not (member p (code-agent--effective-presets buf))))
                           code-presets)))
      (when (pair? missing)
        (buffer-set-local! buf 'chat-presets
          (append missing (or (buffer-local buf 'chat-presets) '())))
        ;; only a live session can hold a stale tool list
        (when (buffer-local buf 'agent-slug)
          (buffer-set-local! buf 'chat-mcp-dirty #t))))
    (if (buffer-local buf 'chat-turn-active)
        (buffer-set-local! buf 'code-agent-switch-pending #t)
        (code-agent--switch-now! buf))))

;; mcp.scm calls this at each turn start. skills.scm loads after this file.
(define (code-agent-system-note buf)
  (if (minor-mode-on? buf "code-agent-mode")
      (string-append
        "CODE-EDITING SKILL\n"
        "Use it to edit live compos buffers instead of the filesystem sandbox.\n"
        "Before the first code edit, load it once with eval-scheme: "
        "(skill \"code-editing\").\n"
        "If this conversation already contains that tool result, do not load it again.\n"
        "DISCOVERY\n"
        "Before guessing an editor API name, call (apropos \"intent\"). "
        "Exact and literal hits rank first; vector hits say semantic match.\n"
        "PROMPT CHANGES\n"
        "Read docs/PROMPTS.md. Prompt fragments, their order and lifecycle, "
        "and direct-API/ACP parity are one contract.")
      ""))

(effects! '(read))
(public! 'code-agent-system-note
  "(code-agent-system-note BUF) — the standing code-editing instructions for a code-agent-mode chat")
(effects! '(write))

(define (code-agent--saved buf key)
  (let ((hit (assoc key (or (buffer-local buf 'code-agent-saved) '()))))
    (and hit (cadr hit))))

(define (code-agent--teardown! buf)
  (when (boundp (quote prompt-part-remove!))
    (prompt-part-remove! buf "code-agent"))
  (let ((conn (code-agent--saved buf 'agent-connector))
        (model (code-agent--saved buf 'agent-model))
        (effort (code-agent--saved buf 'agent-effort))
        (presets (code-agent--saved buf 'chat-presets))
        (pinned (code-agent--saved buf 'pinned)))
    (buffer-set-local! buf 'code-agent-switch-pending #f)
    (buffer-set-local! buf 'code-agent-saved #f)
    (buffer-set-local! buf 'chat-presets presets)
    (when pinned
      (let ((slug (buffer-local buf 'agent-slug)))
        (if (and slug (not (equal? (agent-status slug) 'dead)))
            (chat-switch! buf (or conn *default-connector*) (or model "")
                          (or effort "default"))
            (begin
              (buffer-set-local! buf 'agent-connector conn)
              (buffer-set-local! buf 'agent-model model)
              (buffer-set-local! buf 'agent-effort effort)))))))

(register-minor-mode!
  "code-agent-mode"
  (lambda (buf) (code-agent--apply! buf))
  (lambda (buf) (code-agent--teardown! buf)))

;; Every chat is an agent surface. Its mode setup installs the matching prompt
;; fragment and connector policy before the first turn.
(define (code-agent--chat-mode-hook!)
    (enable-minor-mode! (current-buffer) "code-agent-mode"))

(add-hook! 'chat-mode-hook 'code-agent--chat-mode-hook!)

;; agent.scm reports every tool call here (boundp-guarded: this package
;; loads after it). The first call that edits code turns the mode on.
(define (code-agent-note-tool! buf title kind input)
  (when (and (code-agent--eligible? buf)
             (code-agent--edits-code? kind title input))
    (enable-minor-mode! buf "code-agent-mode")
    (message (string-append
               "This chat writes code — code-agent-mode is on. "
               code-agent-connector
               (if (equal? code-agent-model "")
                   ""
                   (string-append " · " code-agent-model))
               " takes the next turn."))))

;; agent.scm calls this at turn-end: a switch requested mid-turn applies
;; between turns.
(define (code-agent-apply-pending! buf)
  (when (buffer-local buf 'code-agent-switch-pending)
    (buffer-set-local! buf 'code-agent-switch-pending #f)
    (code-agent--switch-now! buf)))

(define-command "code-agent-mode" "Toggle the coding preset and prompts for this chat"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (not (or (chat-buffer? buf) (buffer-local buf 'agent-saved-mark)))
          (message "not a chat buffer")
          (if (toggle-minor-mode! "code-agent-mode")
              (message "code-agent-mode enabled")
              (message "code-agent-mode disabled"))))))

(mode-doc! "code-agent-mode"
  "The coding chat surface. The mode turns on when the agent edits code. It prompts one code-editing load and moves to the coding preset.")

(public! 'code-agent-mode
  "Toggle the coding preset and prompts for the current chat")
(public! 'code-agent-note-tool!
  "(code-agent-note-tool! BUF TITLE KIND INPUT) — turn on code-agent-mode when a tool call edits code")
(public! 'code-agent-apply-pending!
  "(code-agent-apply-pending! BUF) — apply a coding-preset switch that waited for the turn to end")

;;; --- imenu: jump to a definition, on the outline contract ---------------------
;;; The index IS (code-outline BUF): tree-sitter where a grammar exists,
;;; indentation structure where none does, so every buffer has an index
;;; and no per-language query table exists. A morg buffer indexes its
;;; headings instead.

(domain! 'code)
(effects! '(read))

;; -> (LINE KIND NAME DOC) rows, the outline contract
(define (imenu-rows buf)
  (if (and (boundp 'morg-scan)
           (buffer-mode-is? buf "morg-mode"))
      (map (lambda (e)
             (list (line-number-at-pos (car e)) "heading"
                   (string-trim (cadr e)) ""))
           (filter (lambda (e) (equal? (morg-kind e) 'heading))
                   (morg-scan buf)))
      (let ((rows (code-outline buf)))
        (if (string? rows) '() rows))))

(define (imenu--snip s)
  (let ((s (string-trim s)))
    (if (> (string-length s) 60)
        (string-append (substring s 0 60) "…")
        s)))

;; -> (LABEL LINE HINT); a repeated name carries its line in the label,
;; so every row stays reachable
(define (imenu--candidates rows)
  (let loop ((rs rows) (seen '()) (out '()))
    (if (null? rs)
        (reverse out)
        (let* ((r (car rs))
               (line (car r))
               (kind (cadr r))
               (name (caddr r))
               (doc (car (cdr (cdr (cdr r)))))
               (label (if (member name seen)
                          (string-append name " (L" (number->string line) ")")
                          name))
               (hint (string-append
                       kind " · L" (number->string line)
                       (if (or (not doc) (equal? doc ""))
                           ""
                           (string-append " — " (imenu--snip doc))))))
          (loop (cdr rs) (cons name seen)
                (cons (list label line hint) out))))))

(public! 'imenu-rows
  "(imenu-rows BUF) — the imenu index as outline rows (LINE KIND NAME DOC)")

(effects! '(write))

(define-command "imenu" "Jump to a definition in this buffer"
  (lambda ()
    (let ((rows (imenu-rows (current-buffer)))
          (orig (point)))
      (if (null? rows)
          (message "imenu: no definitions in this buffer")
          (let ((cands (imenu--candidates rows)))
            (minibuffer-read-preview "Imenu: "
              (map (lambda (c) (list (car c) (caddr c))) cands)
              (lambda (label)
                (let ((c (assoc label cands)))
                  (when c (goto-char! (line-start-position (cadr c))))))
              (lambda (label)
                (let ((c (assoc label cands)))
                  (goto-char! (if c (line-start-position (cadr c)) orig))))
              (lambda () (goto-char! orig))
              #t))))))

(define-key "goto-map" "i" "imenu")
