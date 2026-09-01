;;; diff-block.scm --- a live diff block: two texts, three states, one fence.
;;;
;;; A diff block holds ours and theirs and waits in the document for a
;;; decision. It is indicated by text alone:
;;;
;;;   ```diff <state> <keys from the keymap>
;;;   ...the state's rendering...
;;;   ```
;;;
;;; The renderer renders it; every affordance is on that fence line. The
;;; states are theirs (their text alone), all (the unified diff), and
;;; ours (our text alone). Changing state is a redraw of the same two
;;; texts. Accepting lands theirs where ours stood; rejecting removes the
;;; block. An action (llm-rewrite, a merge, an agent) creates the block
;;; and owns nothing below it but its note.

(define diff-block-parent-package *loading-package*)
(define diff-block-parent-namespace *loading-namespace*)
(define diff-block-parent-domain *catalog-domain*)
(define diff-block-parent-effects *catalog-effects*)

(package! 'diff-block 'editor)
(domain! 'editing)
(effects! '(write))

;;; --- the record --------------------------------------------------------------
;; (OSTART OEND BSTART BEND TAIL OURS THEIRS NOTE STATE TAG) — one block
;; waits per buffer. Ours stays where it is and theirs sits in the block
;; below it, so nothing is lost while you decide. The record ends with a
;; format tag: a record from another build is no record, because a verb
;; reading it would edit by arithmetic that no longer holds.

(define diff-block--format 'diff-block-1)

(define (diff-block-pending buf)
  (let ((p (buffer-local buf 'diff-block)))
    (and (pair? p) (= (length p) 10)
         (equal? (nth 9 p) diff-block--format)
         p)))

(define (diff-block--tail p) (nth 4 p))
(define (diff-block-ours p) (nth 5 p))
(define (diff-block-theirs p) (nth 6 p))
(define (diff-block-note p) (nth 7 p))
(define (diff-block-state p) (nth 8 p))

;;; --- the states --------------------------------------------------------------

(define (diff-block--state-name state)
  (cond ((equal? state 'all) "all")
        ((equal? state 'ours) "ours")
        (else "theirs")))

(define (diff-block--next-state state)
  (cond ((equal? state 'theirs) 'all)
        ((equal? state 'all) 'ours)
        (else 'theirs)))

(define (diff-block-state-answer state)
  (string-append "show " (diff-block--state-name state)))

;; the two states the block is not in, as answers for a review prompt
(define (diff-block-state-answers state)
  (map diff-block-state-answer
       (filter (lambda (s) (not (equal? s state))) '(all ours theirs))))

(define (diff-block-answer-state answer)
  (let loop ((ss '(all ours theirs)))
    (cond ((null? ss) #f)
          ((equal? answer (diff-block-state-answer (car ss))) (car ss))
          (else (loop (cdr ss))))))

;;; --- the fence ---------------------------------------------------------------

;; The fence line is the diff, its state, and the keys that decide it:
;; ```diff theirs · C-c y keeps it · ... The keys come from BUF's own
;; keymap at land time, so a text-only view is complete; a verb with no
;; key there says nothing.
(define (diff-block--fence-args buf state)
  (let* ((verb (lambda (cmd label)
                 (let ((k (key-for-command cmd buf)))
                   (if (equal? k "") #f (string-append k " " label)))))
         (parts (filter (lambda (x) x)
                        (list (diff-block--state-name state)
                              (verb "diff-block-accept" "keeps it")
                              (verb "diff-block-reject" "puts it back")
                              (verb "diff-block-cycle" "changes the view")))))
    (string-join parts " · ")))

;;; --- rendering the states ----------------------------------------------------

;;; --- the line diff -----------------------------------------------------------
;;; Ours and theirs as head context, one hunk, tail context. A diff block
;;; holds one change by construction, so nothing matches line by line in
;;; the middle: there is no second change in there to find.

(define (diff-block--common-head a b)
  (let loop ((a a) (b b) (n 0))
    (if (and (pair? a) (pair? b) (equal? (car a) (car b)))
        (loop (cdr a) (cdr b) (+ n 1))
        n)))

(define (diff-block--common-tail a b limit)
  (let loop ((a (reverse a)) (b (reverse b)) (n 0))
    (if (and (pair? a) (pair? b) (< n limit) (equal? (car a) (car b)))
        (loop (cdr a) (cdr b) (+ n 1))
        n)))

(define (diff-block--slice lines from to)
  (let loop ((ls lines) (i 0) (acc '()))
    (cond ((or (null? ls) (>= i to)) (reverse acc))
          ((>= i from) (loop (cdr ls) (+ i 1) (cons (car ls) acc)))
          (else (loop (cdr ls) (+ i 1) acc)))))

(define (diff-block--marked prefix lines)
  (map (lambda (l) (string-append prefix l)) lines))

;; -> (HEAD-CONTEXT OURS-HUNK THEIRS-HUNK TAIL-CONTEXT), as line lists
(define (diff-block--parts ours theirs)
  (let* ((a (string-split ours "\n"))
         (b (string-split theirs "\n"))
         (head (diff-block--common-head a b))
         (tail (diff-block--common-tail a b
                 (- (min (length a) (length b)) head))))
    (list (diff-block--slice a 0 head)
          (diff-block--slice a head (- (length a) tail))
          (diff-block--slice b head (- (length b) tail))
          (diff-block--slice a (- (length a) tail) (length a)))))

(define (diff-block-theirs-text theirs buf)
  (block-fence "diff" (diff-block--fence-args buf 'theirs) theirs))

(define (diff-block-ours-text ours buf)
  (block-fence "diff" (diff-block--fence-args buf 'ours) ours))

(define (diff-block-all-text ours theirs buf)
  (let ((parts (diff-block--parts ours theirs)))
    (block-fence "diff" (diff-block--fence-args buf 'all)
      (string-join
        (append
          (diff-block--marked " " (nth 0 parts))
          (diff-block--marked "-" (nth 1 parts))
          (diff-block--marked "+" (nth 2 parts))
          (diff-block--marked " " (nth 3 parts)))
        "\n"))))

(define (diff-block--render p state buf)
  (cond ((equal? state 'all)
         (diff-block-all-text (diff-block-ours p) (diff-block-theirs p) buf))
        ((equal? state 'ours)
         (diff-block-ours-text (diff-block-ours p) buf))
        (else (diff-block-theirs-text (diff-block-theirs p) buf))))

(define (diff-block--rendered p buf)
  (diff-block--render p (diff-block-state p) buf))

;;; --- paint -------------------------------------------------------------------

;; The all state wears the add and delete faces by line prefix, so the
;; two sides read apart at a glance. The one-sided states are prose and
;; take none: a dash there is a dash. In a morg buffer the diff kind
;; paints the same faces through the registry; this overlay is for the
;; buffers no painter covers.
(define (diff-block--row-faces at line state)
  (cond
    ((not (equal? state 'all)) '())
    ((string-prefix? "-" line)
     (list (list at (+ at (string-byte-length line)) 'diff-del)))
    ((string-prefix? "+" line)
     (list (list at (+ at (string-byte-length line)) 'diff-add)))
    (else '())))

(define (diff-block--block-faces start text state)
  (let loop ((ls (string-split text "\n")) (at start) (acc '()))
    (if (null? ls)
        acc
        (let ((end (+ at (string-byte-length (car ls)))))
          (loop (cdr ls) (+ end 1)
                (append acc (diff-block--row-faces at (car ls) state)))))))

;; the visible face covers the body alone: the fence lines keep the diff
;; kind's own header color
(define (diff-block--body-span buf spans)
  (let* ((bs (nth 2 spans)) (be (nth 3 spans))
         (text (or (block-text-at buf bs be) ""))
         (lines (string-split text "\n")))
    (if (< (length lines) 2)
        (list bs be)
        (let* ((first-len (string-byte-length (car lines)))
               (last-len (string-byte-length (car (reverse lines))))
               (body-start (min be (+ bs first-len 1)))
               (body-end (max body-start (- be (+ last-len 1)))))
          (list body-start body-end)))))

(define (diff-block--paint! buf spans state)
  (overlay-set! buf 'diff-block-source
    (list (list (nth 0 spans) (nth 1 spans) 'diff-block-source)))
  ;; the block's bounds ride a tracking face no theme colors
  (overlay-set! buf 'diff-block
    (list (list (nth 2 spans) (nth 3 spans) 'diff-block-span)
          (append (diff-block--body-span buf spans) (list 'diff-block))))
  (overlay-set! buf 'diff-block-faces
    (diff-block--block-faces (nth 2 spans)
      (or (block-text-at buf (nth 2 spans) (nth 3 spans)) "")
      state)))

;;; --- hold and release --------------------------------------------------------

(define diff-block--keys
  '(("C-c y" "diff-block-accept")
    ("C-c k" "diff-block-reject")
    ("C-c d" "diff-block-cycle")))

(define (diff-block--bind-keys! buf)
  (block-bind-keys! buf diff-block--keys))


(define (diff-block--hold! buf spans tail ours theirs note state)
  ;; the record rides the buffer's checkpoint: text and locals snapshot
  ;; together, so its byte offsets stay true across a restart
  (buffer-set-local! buf 'diff-block
    (append spans (list tail ours theirs note state diff-block--format)))
  (diff-block--bind-keys! buf)
  (diff-block--paint! buf spans state))

(define (diff-block-release! buf)
  (buffer-set-local! buf 'diff-block #f)
  (overlay-clear! buf 'diff-block)
  (overlay-clear! buf 'diff-block-source)
  (overlay-clear! buf 'diff-block-faces)
  (block-unbind-keys! buf diff-block--keys))

;; Both overlays follow the rope, so an edit above them moves both; the
;; record answers before they exist.
(define (diff-block--spans buf)
  (let ((p (diff-block-pending buf)))
    (and p
         (append (or (block-overlay-span buf "diff-block-source")
                     (list (nth 0 p) (nth 1 p)))
                 (or (block-overlay-span buf "diff-block-span")
                     (list (nth 2 p) (nth 3 p)))))))

;; Replacing what the block holds: one delete, one insert, and the record
;; follows the new length. Every verb that changes the block goes through
;; here.
(define (diff-block--put! buf p spans text theirs note state)
  (buffer-delete-range! buf (nth 2 spans) (- (nth 3 spans) (nth 2 spans)))
  (buffer-insert! buf (nth 2 spans) text)
  (diff-block--hold! buf
    (list (nth 0 spans) (nth 1 spans) (nth 2 spans)
          (+ (nth 2 spans) (string-byte-length text)))
    (diff-block--tail p) (diff-block-ours p) theirs note state))

;;; --- the creator's API -------------------------------------------------------

;; Land a block below OURS at START..END. Theirs arrives whenever it
;; arrives, so it may only land if ours still reads as it did: the answer
;; is 'ok or 'changed, and the creator says what happened.
(define (diff-block-propose! buf start end ours theirs note)
  (let ((here (block-text-at buf start end)))
    (if (not (equal? here ours))
        'changed
        (let* ((tail (block-tail-for buf end))
               ;; the keys bind first: the fence line names them
               (_ (diff-block--bind-keys! buf))
               (block (diff-block-theirs-text theirs buf))
               (bounds (block-land! buf end block tail)))
          (diff-block--hold! buf (append (list start end) bounds)
                             tail ours theirs note 'theirs)
          'ok))))

;; Replace theirs (a refinement): the block redraws, ours stays, and a
;; reject after any number of rounds still has ours to put back. The
;; answer is 'ok, 'gone, or 'edited.
(define (diff-block-update! buf theirs note)
  (let* ((p (diff-block-pending buf))
         (spans (and p (diff-block--spans buf)))
         (block (and spans (block-text-at buf (nth 2 spans) (nth 3 spans)))))
    (cond
      ((not block) 'gone)
      ((not (equal? block (diff-block--rendered p buf))) 'edited)
      (else
        (let ((state (diff-block-state p)))
          (diff-block--put! buf p spans
            (diff-block--render (append (diff-block--slice p 0 6)
                                        (list theirs note state
                                              diff-block--format))
                                state buf)
            theirs note state)
          'ok)))))

;;; --- the verbs ---------------------------------------------------------------

;; Every state is a rendering of the same two texts, so changing state is
;; a redraw, not a decision.
(define (diff-block-set-state! buf state)
  (let* ((p (diff-block-pending buf))
         (spans (and p (diff-block--spans buf)))
         (block (and spans (block-text-at buf (nth 2 spans) (nth 3 spans)))))
    (cond
      ((not p) (message "No block is waiting"))
      ((not block)
       (diff-block-release! buf)
       (message "The waiting block is gone"))
      ((not (equal? block (diff-block--rendered p buf)))
       (message "The block has been edited — it stays as it is"))
      (else
        (diff-block--put! buf p spans
          (diff-block--render p state buf)
          (diff-block-theirs p) (diff-block-note p) state)
        (message (string-append (diff-block--state-name state) " · "
                                (key-for-command "diff-block-cycle" buf)
                                " changes the view"))))))

(define (diff-block-cycle! buf)
  (let ((p (diff-block-pending buf)))
    (if (not p)
        (message "No block is waiting")
        (diff-block-set-state! buf (diff-block--next-state (diff-block-state p))))))

;; A theirs block is the text you see between the fences, edits and all.
;; The all and ours states are renderings of two texts, so what lands
;; from them is theirs as the record holds it.
(define (diff-block--accept-text p block)
  (if (equal? (diff-block-state p) 'theirs)
      (block-body block)
      (diff-block-theirs p)))

;; Keeping it: theirs takes ours's place, and ours and the blank line
;; that introduced the block go with it.
(define (diff-block-accept! buf)
  (let* ((p (diff-block-pending buf))
         (spans (and p (diff-block--spans buf)))
         (block (and spans (block-text-at buf (nth 2 spans) (nth 3 spans)))))
    (cond
      ((not p) (message "No block is waiting"))
      ((not block)
       (diff-block-release! buf)
       (message "The waiting block is gone"))
      (else
        (let ((from (nth 0 spans))
              (to (min (buffer-size buf)
                       (+ (nth 3 spans)
                          (string-byte-length (diff-block--tail p)))))
              (text (diff-block--accept-text p block)))
          (buffer-delete-range! buf from (- to from))
          (buffer-insert! buf from text)
          (diff-block-release! buf)
          ;; the decision ends the selection too: nothing lingers
          (with-current-buffer buf (lambda () (set-mark! #f)))
          (message "Kept"))))))

;; Putting it back: only the block and its blank line go. A block you
;; have since edited is your text, so that one stays.
(define (diff-block-reject! buf)
  (let* ((p (diff-block-pending buf))
         (spans (and p (diff-block--spans buf)))
         (block (and spans (block-text-at buf (nth 2 spans) (nth 3 spans)))))
    (cond
      ((not p) (message "No block is waiting"))
      ((not block)
       (diff-block-release! buf)
       (message "The waiting block is gone"))
      ((not (equal? block (diff-block--rendered p buf)))
       (message "The block has been edited — it stays"))
      (else
        (let ((from (nth 1 spans))
              (to (min (buffer-size buf)
                       (+ (nth 3 spans)
                          (string-byte-length (diff-block--tail p))))))
          (buffer-delete-range! buf from (- to from))
          (diff-block-release! buf)
          (with-current-buffer buf (lambda () (set-mark! #f)))
          (message "Put back"))))))

(define-command "diff-block-accept" "Keep the waiting diff block: theirs stands where ours did"
  (lambda () (diff-block-accept! (current-buffer))))

(define-command "diff-block-reject" "Remove the waiting diff block and keep ours"
  (lambda () (diff-block-reject! (current-buffer))))

(define-command "diff-block-cycle"
  "Show the waiting diff block as theirs, all, or ours"
  (lambda () (diff-block-cycle! (current-buffer))))

(catalog-meta! 'command "diff-block-accept" 'domain "editing" 'effects '("write"))
(catalog-meta! 'command "diff-block-reject" 'domain "editing" 'effects '("write"))
(catalog-meta! 'command "diff-block-cycle" 'domain "editing" 'effects '("write"))

(public! 'diff-block-propose!
  "(diff-block-propose! BUF START END OURS THEIRS NOTE) — land a diff block below OURS; 'ok, or 'changed when OURS no longer reads there")
(public! 'diff-block-pending
  "(diff-block-pending BUF) — the waiting diff block's record, or #f")

;; Do not leak this block's catalog context into the loader.
(package! diff-block-parent-package diff-block-parent-namespace)
(domain! diff-block-parent-domain)
(effects! diff-block-parent-effects)
