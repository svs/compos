;;; llm-rewrite.scm --- region -> LLM -> a live diff block that waits.
;;;
;;; Loaded from editor.scm. The block subsystems live under
;;; priv/editor/blocks/, one file per block, each loaded here in boot
;;; order before the packages.

(define llm-rewrite-parent-package *loading-package*)
(define llm-rewrite-parent-namespace *loading-namespace*)
(define llm-rewrite-parent-domain *catalog-domain*)
(define llm-rewrite-parent-effects *catalog-effects*)

(package! 'llm-rewrite 'editor)
(domain! 'llm)
(effects! '(write))

;; region -> LLM -> a rewrite that waits in the document
;;
;; gptel's other half. The model rewrites a passage and you read its version
;; where the old one stood, before you decide anything: the rewrite lands in
;; the buffer wearing the rewrite face, and the text it replaced waits beside
;; it until `C-c y` keeps it or `C-c k` puts it back. Asking again while one
;; waits refines that same span, and a reject after any number of rounds
;; still restores the words the passage started with.

(define *llm-rewrite-prose-modes*
  '("text-mode" "markdown-mode" "morg-mode" "org-mode" "chat-mode"))

;; The instructions the prompt offers. Prose and code want opposite things
;; from a model, so the buffer's mode decides which set leads.
(define *llm-rewrite-prose-directives*
  '("Rewrite this passage to be clearer and more direct. Keep the author's voice."
    "Say this in fewer words, and lose nothing."
    "Correct the grammar and the spelling. Change nothing else."
    "Say this in plain language."))

(define *llm-rewrite-code-directives*
  '("Refactor this code. Keep its behaviour, its interface, and the file's style."
    "Name these things for what they are."
    "Handle the cases this code misses."
    "Document this: a docstring for what it is, comments only for what the code cannot say."))

(define (llm-rewrite--prose? buf)
  (let ((mode (buffer-local buf 'mode-name)))
    (or (not mode) (member mode *llm-rewrite-prose-modes*))))

(define (llm-rewrite-directives buf)
  (if (llm-rewrite--prose? buf)
      (append *llm-rewrite-prose-directives* *llm-rewrite-code-directives*)
      (append *llm-rewrite-code-directives* *llm-rewrite-prose-directives*)))

(define (llm-rewrite-prompt buf directive passage)
  (string-append
    "You rewrite one passage of a document open in a text editor"
    (let ((mode (buffer-local buf 'mode-name)))
      (if mode (string-append " (" mode ")") ""))
    ".\n\nInstruction: " directive
    "\n\nPassage:\n" passage
    "\n\nReply with ONLY the rewritten passage. No commentary, no quotes and "
    "no code fences. Keep the indentation of every line, and add no heading, "
    "preface or trailing blank line."))

(define (llm-rewrite--drop-blank-front lines)
  (if (and (pair? lines) (equal? (string-trim (car lines)) ""))
      (llm-rewrite--drop-blank-front (cdr lines))
      lines))

(define (llm-rewrite--trim-blank-edges lines)
  (reverse (llm-rewrite--drop-blank-front
             (reverse (llm-rewrite--drop-blank-front lines)))))

;; A model asked for code answers in a fence often enough, and the passage it
;; replaces has none. Blank edges go the same way: a rewrite must sit exactly
;; where the old text sat, and the first line keeps its own indentation.
(define (llm-rewrite-clean reply)
  (let* ((lines (llm-rewrite--trim-blank-edges (string-split reply "\n")))
         (fenced (and (> (length lines) 1)
                      (string-prefix? "```" (string-trim (car lines)))
                      (string-prefix? "```"
                        (string-trim (nth (- (length lines) 1) lines))))))
    (string-join
      (if fenced
          (llm-rewrite--trim-blank-edges (reverse (cdr (reverse (cdr lines)))))
          lines)
      "\n")))

;; (OSTART OEND BSTART BEND TAIL OLD NEW DIRECTIVE VIEW) — one rewrite
;; waits per buffer. The passage stays where it is and the model's version
;; sits in a block below it, so nothing is lost while you decide. VIEW is
;; how that block reads: 'theirs (the rewrite alone, the default), 'ours
;; (the passage alone), or 'all (the unified diff of the two). A view is a
;; rendering of OLD and NEW, so changing view costs nothing and loses
;; nothing. The decision does not outlive the session: a restart leaves
;; both texts in the document, which is where doing nothing leaves them
;; too.
;;
;; A record written by an older build of this file is not this build's to
;; read. A hot reload can land between the proposal and the decision, and a
;; verb that reads the wrong field of the wrong shape edits the document by
;; arithmetic. A record of the wrong length is no record.
;; The record ends with a format tag. A record without it comes from a
;; build whose block wore another shape; a verb reading it would edit by
;; arithmetic that no longer holds, so it is no record.
(define llm-rewrite--format 'fenced)

(define (llm-rewrite-pending buf)
  (let ((p (buffer-local buf 'llm-rewrite)))
    (and (pair? p) (= (length p) 10)
         (equal? (nth 9 p) llm-rewrite--format)
         p)))

(define (llm-rewrite--tail p) (nth 4 p))
(define (llm-rewrite--old p) (nth 5 p))
(define (llm-rewrite--new p) (nth 6 p))
(define (llm-rewrite--instruction p) (nth 7 p))
(define (llm-rewrite--view p) (nth 8 p))

;; The three views of a live diff: theirs is the rewrite alone (the
;; default), ours is the passage alone, all is the unified diff of the
;; two. A record from before the renaming reads as theirs.
(define (llm-rewrite--render p view buf)
  (cond ((equal? view 'all)
         (llm-rewrite-diff-block (llm-rewrite--old p) (llm-rewrite--new p) buf))
        ((equal? view 'ours)
         (llm-rewrite-ours-block (llm-rewrite--old p) buf))
        (else (llm-rewrite-theirs-block (llm-rewrite--new p) buf))))

;; what the block should hold right now
(define (llm-rewrite--rendered p buf)
  (llm-rewrite--render p (llm-rewrite--view p) buf))

;; Where the two texts are now. Both overlays follow the rope, so an edit
;; above them moves both; the record answers before they exist.
(define (llm-rewrite--overlay buf face)
  (let ((hits (filter (lambda (ov) (equal? (caddr ov) face))
                      (buffer-overlays buf))))
    (and (pair? hits) (list (car (car hits)) (cadr (car hits))))))

(define (llm-rewrite--spans buf)
  (let ((p (llm-rewrite-pending buf)))
    (and p
         (append (or (llm-rewrite--overlay buf "llm-rewrite-source")
                     (list (nth 0 p) (nth 1 p)))
                 (or (llm-rewrite--overlay buf "llm-rewrite-block")
                     (list (nth 2 p) (nth 3 p)))))))

;; The all view wears the add and delete faces by line prefix, so the two
;; sides read apart at a glance. The one-sided views are prose and take
;; none: a dash there is a dash. In a morg buffer the diff kind paints
;; the same faces through the registry; this overlay is for the buffers
;; no painter covers.
(define (llm-rewrite--row-faces at line view)
  (cond
    ((not (equal? view 'all)) '())
    ((string-prefix? "-" line)
     (list (list at (+ at (string-byte-length line)) 'diff-del)))
    ((string-prefix? "+" line)
     (list (list at (+ at (string-byte-length line)) 'diff-add)))
    (else '())))

(define (llm-rewrite--block-faces start text view)
  (let loop ((ls (string-split text "\n")) (at start) (acc '()))
    (if (null? ls)
        acc
        (let ((end (+ at (string-byte-length (car ls)))))
          (loop (cdr ls) (+ end 1)
                (append acc (llm-rewrite--row-faces at (car ls) view)))))))

;; the block face covers the BODY alone: the fence lines keep the diff
;; kind's own header color
(define (llm-rewrite--body-span buf spans)
  (let* ((bs (nth 2 spans)) (be (nth 3 spans))
         (text (or (llm-rewrite--text-at buf bs be) ""))
         (lines (string-split text "\n")))
    (if (< (length lines) 2)
        (list bs be)
        (let* ((first-len (string-byte-length (car lines)))
               (last-len (string-byte-length (car (reverse lines))))
               (body-start (min be (+ bs first-len 1)))
               (body-end (max body-start (- be (+ last-len 1)))))
          (list body-start body-end)))))

(define (llm-rewrite--paint! buf spans view)
  (overlay-set! buf 'llm-rewrite-source
    (list (list (nth 0 spans) (nth 1 spans) 'llm-rewrite-source)))
  ;; the block's bounds ride a tracking face no theme colors, so the
  ;; fence lines keep the diff kind's own header color; the visible face
  ;; covers the body alone
  (overlay-set! buf 'llm-rewrite
    (list (list (nth 2 spans) (nth 3 spans) 'llm-rewrite-block)
          (append (llm-rewrite--body-span buf spans) (list 'llm-rewrite))))
  (overlay-set! buf 'llm-rewrite-diff
    (llm-rewrite--block-faces (nth 2 spans)
      (or (llm-rewrite--text-at buf (nth 2 spans) (nth 3 spans)) "")
      view)))

(define (llm-rewrite--bind-keys! buf)
  (local-set-key* buf "C-c y" "llm-rewrite-accept")
  (local-set-key* buf "C-c k" "llm-rewrite-reject")
  (local-set-key* buf "C-c d" "llm-rewrite-diff"))

(define (llm-rewrite--hold! buf spans tail old new directive view)
  (buffer-set-local! buf 'llm-rewrite
    (append spans (list tail old new directive view llm-rewrite--format)))
  (desktop-skip! buf 'llm-rewrite)
  (llm-rewrite--bind-keys! buf)
  (llm-rewrite--paint! buf spans view))

(define (llm-rewrite--release! buf)
  (buffer-set-local! buf 'llm-rewrite #f)
  (overlay-clear! buf 'llm-rewrite)
  (overlay-clear! buf 'llm-rewrite-source)
  (overlay-clear! buf 'llm-rewrite-diff)
  (local-unset-key* buf "C-c y")
  (local-unset-key* buf "C-c k")
  (local-unset-key* buf "C-c d"))

(define (llm-rewrite--text-at buf start end)
  (let ((text (buffer-text buf)))
    (and (<= start end)
         (<= end (string-byte-length text))
         (substring-bytes text start end))))

;; What the block needs after it. A document that already has a blank line
;; there needs nothing; a line that runs straight on needs one.
(define (llm-rewrite--tail-for buf end)
  (let* ((text (buffer-text buf))
         (size (string-byte-length text))
         (rest (substring-bytes text (min end size) (min (+ end 2) size))))
    (cond ((equal? rest "") "")
          ((equal? rest "\n") "")
          ((string-prefix? "\n\n" rest) "")
          ((string-prefix? "\n" rest) "\n")
          (else "\n\n"))))

;; Replacing what the block holds: one delete, one insert, and the record
;; follows the new length. Every verb that changes the block goes through
;; here.
(define (llm-rewrite--put-block! buf p spans text new directive view)
  (buffer-delete-range! buf (nth 2 spans) (- (nth 3 spans) (nth 2 spans)))
  (buffer-insert! buf (nth 2 spans) text)
  (llm-rewrite--hold! buf
    (list (nth 0 spans) (nth 1 spans) (nth 2 spans)
          (+ (nth 2 spans) (string-byte-length text)))
    (llm-rewrite--tail p) (llm-rewrite--old p) new directive view))

;;; --- the two diff blocks ----------------------------------------------------
;;; A rewrite is one change by construction: the passage went out whole and
;;; the block came back whole. So a diff of the two is the lines they still
;;; share at each end and one hunk between them. Nothing matches line by
;;; line in the middle, because there is no second change in there to find.
;;; Every view is one fenced block whose info string names the kind and the
;;; instruction, because a block you meet an hour later has to say what it
;;; was asked for — in bare text, with no renderer's help.

(define (llm-rewrite--common-head a b)
  (let loop ((a a) (b b) (n 0))
    (if (and (pair? a) (pair? b) (equal? (car a) (car b)))
        (loop (cdr a) (cdr b) (+ n 1))
        n)))

(define (llm-rewrite--common-tail a b limit)
  (let loop ((a (reverse a)) (b (reverse b)) (n 0))
    (if (and (pair? a) (pair? b) (< n limit) (equal? (car a) (car b)))
        (loop (cdr a) (cdr b) (+ n 1))
        n)))

(define (llm-rewrite--slice lines from to)
  (let loop ((ls lines) (i 0) (acc '()))
    (cond ((or (null? ls) (>= i to)) (reverse acc))
          ((>= i from) (loop (cdr ls) (+ i 1) (cons (car ls) acc)))
          (else (loop (cdr ls) (+ i 1) acc)))))

(define (llm-rewrite--marked prefix lines)
  (map (lambda (l) (string-append prefix l)) lines))

;; The block is a fenced block, and its kind follows its view: a diff
;; view lands a ```diff fence the diff kind paints, and the whole view
;; lands ```rewrite, so diff paint never touches plain prose. The
;; delimiters are real text: the bare buffer says what the block is and
;; what it was asked, morg folds and lifts it like any fence, and the
;; preview paints it through the fence-kind registry. Accepting strips
;; the fences by structure.
(define (llm-rewrite--fence kind directive body)
  (string-append "```" kind " " directive "\n" body "\n```"))

;; the text between the fences; a block whose fences were edited away is
;; your text, and stays whole
(define (llm-rewrite--body block)
  (let ((lines (string-split block "\n")))
    (if (and (>= (length lines) 2)
             (string-prefix? "```" (car lines))
             (string-prefix? "```" (car (reverse lines))))
        (string-join (reverse (cdr (reverse (cdr lines)))) "\n")
        block)))

;; The fence line is the diff, its view, and the keys that decide it:
;; ```diff theirs · C-c y keeps it · ... The keys come from BUF's own
;; keymap at land time, so a text-only view is complete; a verb with no
;; key there says nothing. The instruction stays off the line: it lives
;; in the record and the preview draws it.
(define (llm-rewrite--fence-args buf view)
  (let* ((verb (lambda (cmd label)
                 (let ((k (key-for-command cmd buf)))
                   (if (equal? k "") #f (string-append k " " label)))))
         (parts (filter (lambda (x) x)
                        (list (llm-rewrite--view-name view)
                              (verb "llm-rewrite-accept" "keeps it")
                              (verb "llm-rewrite-reject" "puts it back")
                              (verb "llm-rewrite-diff" "changes the view")))))
    (string-join parts " · ")))

(define (llm-rewrite-theirs-block new buf)
  (llm-rewrite--fence "diff" (llm-rewrite--fence-args buf 'theirs) new))

(define (llm-rewrite-ours-block old buf)
  (llm-rewrite--fence "diff" (llm-rewrite--fence-args buf 'ours) old))

;; the passage and the rewrite as head context, one hunk, tail context
(define (llm-rewrite--parts old new)
  (let* ((a (string-split old "\n"))
         (b (string-split new "\n"))
         (head (llm-rewrite--common-head a b))
         (tail (llm-rewrite--common-tail a b
                 (- (min (length a) (length b)) head))))
    (list (llm-rewrite--slice a 0 head)
          (llm-rewrite--slice a head (- (length a) tail))
          (llm-rewrite--slice b head (- (length b) tail))
          (llm-rewrite--slice a (- (length a) tail) (length a)))))

(define (llm-rewrite-diff-block old new buf)
  (let ((parts (llm-rewrite--parts old new)))
    (llm-rewrite--fence "diff" (llm-rewrite--fence-args buf 'all)
      (string-join
        (append
          (llm-rewrite--marked " " (nth 0 parts))
          (llm-rewrite--marked "-" (nth 1 parts))
          (llm-rewrite--marked "+" (nth 2 parts))
          (llm-rewrite--marked " " (nth 3 parts)))
        "\n"))))


;; The reply arrives whenever it arrives, so it may only land under the
;; passage it was asked about. It never touches that passage: a blank line
;; and the block go in below it, and both texts stand until you decide.
(define (llm-rewrite--propose! buf start end original new directive)
  (let ((here (llm-rewrite--text-at buf start end)))
    (if (not (equal? here original))
        (message "Rewrite dropped — that passage has changed")
        (let* ((tail (llm-rewrite--tail-for buf end))
               ;; the keys bind first: the fence line names them
               (_ (llm-rewrite--bind-keys! buf))
               (block (llm-rewrite-theirs-block new buf))
               (bstart (+ end 2))
               (bend (+ bstart (string-byte-length block))))
          (buffer-insert! buf end (string-append "\n\n" block tail))
          (llm-rewrite--hold! buf (list start end bstart bend)
                              tail original new directive 'theirs)
          (message (string-append
                     "Rewrite waiting below the passage in "
                     (buffer-modeline-name buf)
                     " · there " (key-for-command "llm-rewrite") " decides and "
                     (key-for-command "llm-rewrite-diff" buf)
                     " shows the diff"))))))

;; Asking again rewrites the block, never the passage: the reject that comes
;; after any number of rounds still has the original to put back. The new
;; instruction becomes the block's header, because that is what the block
;; now answers.
(define (llm-rewrite--refine! buf new directive)
  (let* ((p (llm-rewrite-pending buf))
         (spans (and p (llm-rewrite--spans buf)))
         (block (and spans (llm-rewrite--text-at buf (nth 2 spans) (nth 3 spans)))))
    (cond
      ((not block) (message "The waiting rewrite is gone"))
      ((not (equal? block (llm-rewrite--rendered p buf)))
       (message "The rewrite has been edited — the new version was dropped"))
      (else
        (let* ((view (llm-rewrite--view p))
               (next (append (llm-rewrite--slice p 0 6)
                             (list new directive view))))
          (llm-rewrite--put-block! buf p spans
            (llm-rewrite--render next view buf) new directive view)
          (message (string-append "Rewrite refined · "
                                  (key-for-command "llm-rewrite") " decides")))))))

;; Every view is a rendering of the same two strings, so changing view is a
;; redraw, not a decision.
(define (llm-rewrite-set-view! buf view)
  (let* ((p (llm-rewrite-pending buf))
         (spans (and p (llm-rewrite--spans buf)))
         (block (and spans (llm-rewrite--text-at buf (nth 2 spans) (nth 3 spans)))))
    (cond
      ((not p) (message "No rewrite is waiting"))
      ((not block)
       (llm-rewrite--release! buf)
       (message "The waiting rewrite is gone"))
      ((not (equal? block (llm-rewrite--rendered p buf)))
       (message "The rewrite has been edited — it stays as it is"))
      (else
        (llm-rewrite--put-block! buf p spans
          (llm-rewrite--render p view buf)
          (llm-rewrite--new p) (llm-rewrite--instruction p) view)
        (message (string-append "Rewrite " (llm-rewrite--view-name view) " · "
                                (key-for-command "llm-rewrite-diff" buf)
                                " changes the view"))))))

(define (llm-rewrite-cycle-view! buf)
  (let ((p (llm-rewrite-pending buf)))
    (if (not p)
        (message "No rewrite is waiting")
        (llm-rewrite-set-view! buf (llm-rewrite--next-view (llm-rewrite--view p))))))

(define (llm-rewrite--ask! buf passage directive land)
  (message "LLM rewriting...")
  (llm (llm-rewrite-prompt buf directive passage)
    (lambda (reply)
      (let ((new (llm-rewrite-clean reply)))
        (cond ((not (buffer-exists? buf))
               (message "Rewrite discarded — its buffer was killed"))
              ((equal? new "") (message "The model returned nothing"))
              (else (land new)))))))

;; An empty answer at the prompt takes the instruction the mode leads with.
(define (llm-rewrite--directive buf input)
  (let ((typed (string-trim input)))
    (if (equal? typed "") (car (llm-rewrite-directives buf)) typed)))

(define (llm-rewrite--start! buf)
  (let* ((start (and (mark) (region-beginning)))
         (end (and start (region-end)))
         (old (and start (llm-rewrite--text-at buf start end))))
    (if (or (not old) (equal? old ""))
        (message "No region — set the mark first (C-SPC)")
        (begin
          ;; the region is consumed: the command has it, so the selection
          ;; does not linger under the caret
          (set-mark! #f)
          (minibuffer-read "Rewrite region: " (llm-rewrite-directives buf)
          (lambda (input)
            (let ((directive (llm-rewrite--directive buf input)))
              (llm-rewrite--ask! buf old directive
                (lambda (new)
                  (llm-rewrite--propose! buf start end old new directive))))))))))

;; One key decides. `C-c y`, `C-c k` and `C-c d` live only in the buffer
;; that holds the rewrite, and a key nobody can reach from the window they
;; are looking at is no key at all — so the same `C-c e` that made the
;; rewrite also ends it. The verbs are exact answers, which leaves an
;; instruction that happens to start with "keep" an instruction.
(define *llm-rewrite-keep-answer* "keep it")
(define *llm-rewrite-back-answer* "put it back")

(define (llm-rewrite--view-name view)
  (cond ((equal? view 'all) "all")
        ((equal? view 'ours) "ours")
        (else "theirs")))

(define (llm-rewrite--view-answer view)
  (string-append "show " (llm-rewrite--view-name view)))

(define (llm-rewrite--next-view view)
  (cond ((equal? view 'theirs) 'all)
        ((equal? view 'all) 'ours)
        (else 'theirs)))

;; the two views the block is not in, as answers
(define (llm-rewrite--view-answers view)
  (map llm-rewrite--view-answer
       (filter (lambda (v) (not (equal? v view))) '(all ours theirs))))

(define (llm-rewrite--answer-view answer)
  (let loop ((vs '(all ours theirs)))
    (cond ((null? vs) #f)
          ((equal? answer (llm-rewrite--view-answer (car vs))) (car vs))
          (else (loop (cdr vs))))))

(define (llm-rewrite--review! buf p spans answer)
  (let ((view (llm-rewrite--answer-view answer)))
    (cond
      ((equal? answer "") (message "Rewrite still waiting"))
      ((equal? answer *llm-rewrite-keep-answer*) (llm-rewrite-accept! buf))
      ((equal? answer *llm-rewrite-back-answer*) (llm-rewrite-reject! buf))
      (view (llm-rewrite-set-view! buf view))
      (else
        (llm-rewrite--ask! buf (llm-rewrite--new p) answer
          (lambda (new) (llm-rewrite--refine! buf new answer)))))))

(define (llm-rewrite--again! buf p)
  (let ((spans (llm-rewrite--spans buf)))
    (if (not spans)
        (begin (llm-rewrite--release! buf)
               (message "The waiting rewrite is gone"))
        (minibuffer-read
          "Rewrite waiting (keep it / put it back / show it … / a new instruction): "
          (append (list *llm-rewrite-keep-answer* *llm-rewrite-back-answer*)
                  (llm-rewrite--view-answers (llm-rewrite--view p))
                  (llm-rewrite-directives buf))
          (lambda (input)
            (llm-rewrite--review! buf p spans (string-trim input)))))))

;; A theirs block is the text you see between the fences, edits and all.
;; The all and ours views are renderings of two strings, so what lands
;; from them is the rewrite the block describes.
(define (llm-rewrite--accept-text p block)
  (if (equal? (llm-rewrite--view p) 'theirs)
      (llm-rewrite--body block)
      (llm-rewrite--new p)))

;; Keeping it: the block takes the passage's place, and the passage and the
;; blank line that introduced the block go with it.
(define (llm-rewrite-accept! buf)
  (let* ((p (llm-rewrite-pending buf))
         (spans (and p (llm-rewrite--spans buf)))
         (block (and spans (llm-rewrite--text-at buf (nth 2 spans) (nth 3 spans)))))
    (cond
      ((not p) (message "No rewrite is waiting"))
      ((not block)
       (llm-rewrite--release! buf)
       (message "The waiting rewrite is gone"))
      (else
        (let ((from (nth 0 spans))
              (to (min (buffer-size buf)
                       (+ (nth 3 spans)
                          (string-byte-length (llm-rewrite--tail p)))))
              (text (llm-rewrite--accept-text p block)))
          (buffer-delete-range! buf from (- to from))
          (buffer-insert! buf from text)
          (llm-rewrite--release! buf)
          ;; the decision ends the selection too: nothing lingers
          (with-current-buffer buf (lambda () (set-mark! #f)))
          (message "Rewrite kept"))))))

;; Putting it back: only the block and its blank line go. A block you have
;; since edited is your text, so that one stays.
(define (llm-rewrite-reject! buf)
  (let* ((p (llm-rewrite-pending buf))
         (spans (and p (llm-rewrite--spans buf)))
         (block (and spans (llm-rewrite--text-at buf (nth 2 spans) (nth 3 spans)))))
    (cond
      ((not p) (message "No rewrite is waiting"))
      ((not block)
       (llm-rewrite--release! buf)
       (message "The waiting rewrite is gone"))
      ((not (equal? block (llm-rewrite--rendered p buf)))
       (message "The rewrite has been edited — it stays"))
      (else
        (let ((from (nth 1 spans))
              (to (min (buffer-size buf)
                       (+ (nth 3 spans)
                          (string-byte-length (llm-rewrite--tail p))))))
          (buffer-delete-range! buf from (- to from))
          (llm-rewrite--release! buf)
          (with-current-buffer buf (lambda () (set-mark! #f)))
          (message "Rewrite put back"))))))

(define-command "llm-rewrite"
  "Rewrite the region with the LLM into a block below it; with one waiting, decide it or ask again"
  (lambda ()
    (let* ((buf (current-buffer))
           (p (llm-rewrite-pending buf)))
      (if p (llm-rewrite--again! buf p) (llm-rewrite--start! buf)))))

(define-command "llm-rewrite-accept" "Keep the waiting rewrite in place of the passage"
  (lambda () (llm-rewrite-accept! (current-buffer))))

(define-command "llm-rewrite-reject" "Remove the waiting rewrite and keep the passage"
  (lambda () (llm-rewrite-reject! (current-buffer))))

(define-command "llm-rewrite-diff"
  "Show the waiting rewrite as theirs, all, or ours"
  (lambda () (llm-rewrite-cycle-view! (current-buffer))))

(global-set-key "M-|" "llm-pipe-region")
(global-set-key "C-c e" "llm-rewrite")
(catalog-meta! 'command "llm-rewrite"
  'domain "llm" 'effects '("write" "external" "spend"))
(catalog-meta! 'command "llm-rewrite-accept" 'domain "llm" 'effects '("write"))
(catalog-meta! 'command "llm-rewrite-reject" 'domain "llm" 'effects '("write"))
(catalog-meta! 'command "llm-rewrite-diff" 'domain "llm" 'effects '("write"))

;; Do not leak this block's catalog context into the loader.
(package! llm-rewrite-parent-package llm-rewrite-parent-namespace)
(domain! llm-rewrite-parent-domain)
(effects! llm-rewrite-parent-effects)
