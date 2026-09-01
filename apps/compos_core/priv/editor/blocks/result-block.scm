;;; result-block.scm --- the result fence below a block that ran.
;;;
;;; A run's output lands in a result fence directly below the block that
;;; made it, and a later run replaces that fence. The result kinds
;;; (result, result-scheme, result-csv) are registered in morg-kinds.scm
;;; like every kind; this file owns the landing. It leans on block.scm
;;; for the fence shape and on morg-scan for where blocks stand.

(define result-block-parent-package *loading-package*)
(define result-block-parent-namespace *loading-namespace*)
(define result-block-parent-domain *catalog-domain*)
(define result-block-parent-effects *catalog-effects*)

(package! 'result-block 'editor)
(domain! 'writing)
(effects! '(write))


;; Return the result block after CLOSE-END, or #f.
(define (result-block--find scan buf close-end)
  (let loop ((es scan))
    (cond ((null? es) #f)
          ((<= (car (car es)) close-end) (loop (cdr es)))
          (else
            (let* ((e (car es)) (k (morg-kind e)))
              (cond ((and (equal? k 'text) (equal? (string-trim (cadr e)) ""))
                     (loop (cdr es)))
                    ((and (equal? k 'open)
                          (member (morg-info e) '("result" "result-scheme" "result-csv")))
                     (list (car e) (morg-block-close-end scan buf (car e))))
                    (else #f)))))))

;; The scan is read here, not passed in: a result written when a command
;; ends describes a document that moved since the command started.
(define (result-block-insert! buf fstart out &optional result-lang)
  (let* ((scan (morg-scan buf))
         (close-end (morg-block-close-end scan buf fstart))
         (existing (result-block--find scan buf close-end))
         (norm (if (or (equal? out "") (string-suffix? "\n" out))
                   out
                   (string-append out "\n")))
         (res (string-append "```" (or result-lang "result") "\n" norm "```\n")))
    (if existing
        (let* ((rs (car existing))
               (re (min (buffer-size buf) (+ (cadr existing) 1))))
          (buffer-delete-range! buf rs (- re rs))
          (buffer-insert! buf rs res))
        (let* ((size (buffer-size buf))
               (at (min (+ close-end 1) size)))
          (buffer-insert! buf at
            (string-append (if (>= close-end size) "\n" "") res))))))

;;; --- running -----------------------------------------------------------------


(public! 'result-block-insert!
  "(result-block-insert! BUF FSTART OUT [KIND]) — land OUT in the result fence below the block at FSTART, replacing the one that stands there")

;; Do not leak this block's catalog context into the loader.
(package! result-block-parent-package result-block-parent-namespace)
(domain! result-block-parent-domain)
(effects! result-block-parent-effects)
