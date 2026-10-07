;;; subagents.scm --- the spawn edges as a table: parent, child, status, last line.
;;;
;;; One row is one spawn edge. A child chat has exactly one parent, so the
;;; child slug names the edge. The rows come from the relation
;;; agent-session.scm keeps in the group record, never from the live
;;; buffers, so a parent that has been killed still lists the children it
;;; spawned: subagent-gone? says so and the row says killed.
;;;
;;; This is the ibuffer template with one view over it, the way *chats* is
;;; in agent-fleet.scm. No second list engine.

;; the spawn edges are the chats table's other view
(require 'agent-fleet)

(domain! 'chat)
(effects! '(read))
(category! 'chat)

(define *subagents-buffer* "*subagents*")

;; How much of a child chat's last line a row shows.
(define subagents-last-line-width 72)

;; How many bytes at the end of a child chat the last line is read from.
(define subagents-tail-bytes 2000)

;;; --- the edges ---------------------------------------------------------
;;;
;;; agent-session.scm owns the store: a slot is (PARENT STATE CHILD ...) in
;;; a group record. This file only reads it, and reads it whole, because a
;;; per-chat reader cannot answer for a parent whose buffer is gone.

(define (subagents-slot-rows)
  (fold (lambda (acc g)
          (append acc
                  (map (lambda (slot)
                         (list (subagent-slot-parent slot)
                               (subagent-slot-state slot)
                               (subagent-slot-children slot)))
                       (subagent-slots g))))
        '()
        (group-ids)))

;; (CHILD PARENT STATE) for every spawn edge: parents in store order,
;; children in spawn order, a child named twice kept once
(define (subagents-edges)
  (let loop ((slots (subagents-slot-rows)) (out '()))
    (if (null? slots)
        (reverse out)
        (let ((parent (nth 0 (car slots)))
              (state (nth 1 (car slots))))
          (loop (cdr slots)
                (fold (lambda (acc c)
                        (if (assoc c acc) acc (cons (list c parent state) acc)))
                      out
                      (nth 2 (car slots))))))))

;; the edges the last draw read: every cell of every row asks this, so the
;; store is scanned once per refresh and not once per cell
(define *subagents-index* '())

(define (subagents-index-rebuild!)
  (set! *subagents-index* (subagents-edges))
  (set! *subagents-last-memo* (list #f ""))
  *subagents-index*)

(define (subagents-edge child)
  (and (string? child) (assoc child *subagents-index*)))

(define (subagents-parent-of child)
  (let ((e (subagents-edge child))) (and e (nth 1 e))))

;; a row belongs to this table when the index names it. A slug is never a
;; buffer name, so this kind can never claim another table's row.
(define (subagents-row? b)
  (and (string? b) (not (buffer-known? b)) (pair? (subagents-edge b))))

;;; --- what a row says ---------------------------------------------------

(define (subagents-chat-buffer slug)
  (let ((b (and (string? slug) (agent-buf slug))))
    (and b (buffer-known? b) b)))

(define (subagents-label slug)
  (let ((b (subagents-chat-buffer slug)))
    (cond (b (chats-title b))
          ((string? slug) slug)
          (else "?"))))

;; the parent is lost when the store says so, or when its chat buffer has
;; gone without the store hearing about it
(define (subagents-parent-lost? child)
  (let ((p (subagents-parent-of child)))
    (and p (or (not (subagents-chat-buffer p)) (subagent-gone? p)) #t)))

(define (subagents-parent-label child)
  (let ((p (subagents-parent-of child)))
    (string-append (subagents-label p)
                   (if (subagents-parent-lost? child) " (killed)" ""))))

(define (subagents-status child) (agent-status child))

;; the name column is the edge itself: the parent, dim, then the child
(define (subagents-name child)
  (list (string-append (subagents-parent-label child) " > ")
        (subagents-label child)))

;; the child's last line is the last line its buffer holds that says
;; anything. A child whose buffer is gone says nothing.
(define *subagents-last-memo* (list #f ""))

(define (subagents-last-line--read child)
  (let ((b (subagents-chat-buffer child)))
    (if (not b)
        ""
        (let* ((size (buffer-size b))
               (from (max 0 (- size subagents-tail-bytes)))
               (tail (with-current-buffer b
                       (lambda () (buffer-substring from size))))
               ;; a tail that starts mid-line starts mid-character too:
               ;; drop that first piece, it is never the last line
               (pieces (let ((ps (string-split tail "\n")))
                         (if (and (> from 0) (pair? ps)) (cdr ps) ps)))
               (said (filter (lambda (l) (not (equal? (string-trim l) "")))
                             pieces)))
          (if (null? said)
              ""
              (list-fit (string-trim (car (reverse said)))
                        subagents-last-line-width 'end))))))

(define (subagents-last-line child)
  (if (equal? (car *subagents-last-memo*) child)
      (nth 1 *subagents-last-memo*)
      (let ((line (subagents-last-line--read child)))
        (set! *subagents-last-memo* (list child line))
        line)))

(ibuffer-kind! 'subagent
  (list 'when? (lambda (b) (subagents-row? b))
        'dot (lambda (c)
               (let ((s (subagents-status c)))
                 (list (agent-status-glyph s) (chats-state-face s))))
        'name (lambda (c) (subagents-name c))
        'size (lambda (c) #f)
        'label (lambda (c) (chats-state-label (subagents-status c)))
        'last (lambda (c) (subagents-last-line c))
        'match (lambda (c)
                 (string-append (subagents-parent-label c) " "
                                (chats-state-label (subagents-status c)) " "
                                (subagents-last-line c)))
        'face (lambda (c)
                (if (equal? (subagents-status c) 'needs_attention)
                    "alert"
                    "accent"))
        'modified? (lambda (c) #f)))

(define (subagents-rows buf)
  (let ((rows (map car (subagents-index-rebuild!))))
    (ibuffer-note-kinds! rows)
    rows))

;;; --- the view ----------------------------------------------------------

;; the rows are the edges, not buffers, so the template's scope says
;; nothing here: the mode's own rows fn reads the store
(ibuffer-scope! 'subagents (lambda () '()))
(ibuffer-view! *subagents-buffer* 'sort 'recent)

;; status in one column, the child's last line in the other. The tag
;; names what the cell asks the row kind for: mode asks label, last asks
;; last.
(define *subagents-fields* '((mode 9 left end) (last 24 left end)))
(define *subagents-narrow-fields* '((mode 9 left end)))

(define (subagents-meta buf)
  (let ((n (length (list-entries buf))))
    (ibuffer-join-parts
      (list (list (string-append (number->string n)
                                 (if (= n 1) " spawn" " spawns"))
                  "faint")))))

(define (subagents-layout name fields default?)
  (append (list 'name name)
          (if default? (list 'default #t) '())
          (list 'columns (lambda (buf) (ibuffer-columns-for buf fields))
                'cells (lambda (buf b) (ibuffer-cells-for buf b fields))
                'meta (lambda (buf) (subagents-meta buf))
                'footer (lambda (buf) '()))))

(define-list-mode! "isubagents-mode"
  (ibuffer-mode-opts
    (list
      'doc (string-append
             "Every spawn edge, one row each: the parent chat, the child "
             "it spawned, what the child is doing now, and the last line "
             "the child said. The rows come from the relation itself, so "
             "a parent that has been killed still lists its children and "
             "wears (killed) beside its name. RET shows the chat of the "
             "row in the other window and leaves the point where it is. "
             "g reads the edges again, / narrows, and q quits.")
      'buffer *subagents-buffer*
      'category 'chat
      'title (lambda (buf) "Subagents")
      'noun "spawn"
      'rows (lambda (buf) (subagents-rows buf))
      'total (lambda (buf) (length *subagents-index*))
      'stamp (lambda (buf) (length *subagents-index*))
      ;; nothing here acts on a selection, and no row is a buffer
      'markable? (lambda (buf e) #f)
      'flags '()
      ;; a look never moves another window: the row at point is an edge,
      ;; and RET is the only thing that shows a chat
      'preview (lambda (buf b) #f)
      'meta (lambda (buf) (subagents-meta buf))
      'layouts (list (subagents-layout 'narrow *subagents-narrow-fields* #f)
                     (subagents-layout 'wide *subagents-fields* #t))
      'keys '(("RET" "subagents-visit") ("g" "subagents-refresh")
              ("," "subagents-one-shape") (";" "subagents-one-shape")))))

;;; --- the commands ------------------------------------------------------

(category! 'chat)
(domain! 'chat)
(effects! '(read display))

(define (subagents-open!)
  (ibuffer-open! 'subagents *subagents-buffer* "isubagents-mode"))

(define-command "subagents"
  "List every spawned chat: parent, child, status, and the child's last line"
  (lambda () (subagents-open!)))

;; RET shows the child in the other window. It never takes the point and
;; never opens a popup: the table stays where it is.
(define-command "subagents-visit"
  "Show the chat of the row at point in the other window"
  (lambda ()
    (let ((row (list-current *subagents-buffer*)))
      (if (not (subagents-row? row))
          (message "no spawned chat here")
          (let ((b (subagents-chat-buffer row)))
            (if b
                (begin (display-buffer-other-window! b)
                       (message (string-append "showing " b)))
                (message (string-append (subagents-label row)
                                        " has no buffer any more"))))))))

(effects! '(read))

(define-command "subagents-refresh" "Read the spawn edges again"
  (lambda ()
    (ibuffer-refresh! *subagents-buffer*)
    (message "subagents: read the spawn edges again")))

(define-command "subagents-one-shape"
  "Say that this table has one shape"
  (lambda ()
    (message "the subagents table has one shape: one row per spawn edge")))

;;; --- the catalog -------------------------------------------------------

(category! 'chat)
(domain! 'chat)
(effects! '(read))
(public! 'subagents-edges
  "(subagents-edges) - (CHILD PARENT STATE) for every spawn edge, read from the relation, so a killed parent still lists its children")
(public! 'subagents-last-line
  "(subagents-last-line CHILD) - the last line the child chat says, clipped; empty when its buffer is gone")
(public! 'subagents-open!
  "(subagents-open!) - open the *subagents* table: one row per spawn edge")
(catalog-meta! 'function "subagents-open!" 'domain 'chat 'effects '(read display))
(catalog-meta! 'command "subagents" 'domain 'chat 'effects '(read display))
(catalog-meta! 'command "subagents-visit" 'domain 'chat 'effects '(read display))
(catalog-meta! 'command "subagents-refresh" 'domain 'chat 'effects '(read))
