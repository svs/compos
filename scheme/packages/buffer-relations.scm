;;; buffer-relations.scm --- one local for every parent/child link.
;;;
;;; A buffer points at its parent under a KIND, and the parent keeps the
;;; index of its children under the same KIND. Both halves live in one
;;; local, 'relations: ((KIND PARENT CHILDREN) ...).
;;;
;;;   owner      the buffer whose q dismisses this one (dismiss.scm)
;;;   detail     the list this page was opened from (detail.scm)
;;;   companion  the document a chat works (chat-follow, the chat header)
;;;   inline     the document a chat renders its replies into; the
;;;              document's inline child is its hidden chat
;;;   linked     the buffer a chat last named in its transcript
;;;
;;; The child's pointer is the truth and the parent's list is its index.
;;; A pointer can name a buffer that is not open, as an archived chat
;;; names its page; buffer-relation reads it, and buffer-parent answers
;;; only a live parent. A kill drops the buffer from its parents' indices
;;; and, for an owner, frees its children, so a buffer that reuses the
;;; name owns nothing. A rename rewrites both halves.

(require 'advice)

(domain! 'buffers)
(effects! '(read))

;; kinds whose children are let go when their parent dies
(define *relations-unlink-on-kill* '(owner))

(define (relations--of buf)
  (or (and (string? buf) (buffer-known? buf) (buffer-local buf 'relations)) '()))

(define (relations--entry buf kind)
  (or (assoc kind (relations--of buf)) (list kind #f '())))

(define (buffer-relation buf kind)
  (car (cdr (relations--entry buf kind))))

(define (relations--index buf kind)
  (car (cdr (cdr (relations--entry buf kind)))))

(define (buffer-parent buf &optional kind)
  (let ((p (buffer-relation buf (or kind 'owner))))
    (and (string? p) (buffer-known? p) p)))

(define (buffer-children buf &optional kind)
  (let ((k (or kind 'owner)))
    (filter (lambda (child)
              (and (buffer-known? child) (equal? (buffer-relation child k) buf)))
            (relations--index buf k))))

(public! 'buffer-relation "(buffer-relation BUF KIND) - the buffer BUF names as its KIND parent, open or not, or #f")
(public! 'buffer-parent "(buffer-parent BUF [KIND]) - BUF's live KIND parent, or #f; KIND defaults to owner, the dismissal parent")
(public! 'buffer-children "(buffer-children BUF [KIND]) - BUF's live KIND children, newest first; KIND defaults to owner")

(effects! '(write))

(define (relations--put! buf kind parent children)
  (when (buffer-known? buf)
    (let* ((rest (filter (lambda (e) (not (equal? (car e) kind))) (relations--of buf)))
           (all (if (or parent (pair? children))
                    (cons (list kind parent children) rest)
                    rest)))
      (unless (equal? all (relations--of buf))
        (buffer-set-local! buf 'relations (if (null? all) #f all))))))

(define (relations--unindex! parent kind child)
  (when (and (string? parent) (buffer-known? parent))
    (relations--put! parent kind (buffer-relation parent kind)
      (remove (lambda (b) (equal? b child)) (relations--index parent kind)))))

;; CHILD's KIND parent becomes PARENT, or nothing when PARENT is #f. A
;; parent that is not open yet keeps no index; the pointer still names it.
(define (buffer-relate! child kind parent)
  (let ((old (buffer-relation child kind)))
    (unless (equal? old parent) (relations--unindex! old kind child))
    (relations--put! child kind parent (relations--index child kind))
    (when (and (string? parent) (buffer-known? parent))
      (relations--put! parent kind (buffer-relation parent kind)
        (cons child (remove (lambda (b) (equal? b child)) (relations--index parent kind)))))
    child))

(define (relations--before-kill! buf)
  (for-each
    (lambda (e)
      (let ((kind (car e)))
        (relations--unindex! (car (cdr e)) kind buf)
        (when (member kind *relations-unlink-on-kill*)
          (for-each (lambda (child)
                      (when (equal? (buffer-relation child kind) buf)
                        (relations--put! child kind #f (relations--index child kind))))
                    (car (cdr (cdr e)))))))
    (relations--of buf)))

(define (relations--renamed! old new)
  (let ((swap (lambda (b) (if (equal? b old) new b))))
    (for-each
      (lambda (buf)
        (let* ((rs (relations--of buf))
               (next (map (lambda (e) (list (car e) (swap (car (cdr e))) (map swap (car (cdr (cdr e))))))
                          rs)))
          (unless (equal? rs next) (buffer-set-local! buf 'relations next))))
      (buffer-list))))

(advice-add! 'buffer-kill! 'before 'buffer-relations 'relations--before-kill!)
(add-hook! 'buffer-renamed-hook 'relations--renamed!)

(public! 'buffer-relate! "(buffer-relate! CHILD KIND PARENT) - make PARENT CHILD's KIND parent, both halves; #f unlinks")
