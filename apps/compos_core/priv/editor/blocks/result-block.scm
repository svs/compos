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


;; the kinds a result fence wears
(define result-block--kinds '("result" "result-scheme" "result-csv"))

;; the result block after CLOSE-END with only blank text between, as
;; (START END), or #f
(define (result-block--find buf blocks close-end)
  (let loop ((bs blocks))
    (cond ((null? bs) #f)
          ((<= (nth 0 (car bs)) close-end) (loop (cdr bs)))
          (else
            (let* ((b (car bs))
                   (between (or (block-text-at buf (min (+ close-end 1) (nth 0 b))
                                              (nth 0 b))
                                "x")))
              (if (and (equal? (string-trim between) "")
                       (member (block-lang b) result-block--kinds))
                  (list (nth 0 b) (nth 1 b))
                  #f))))))

;; The blocks are read here, not passed in: a result written when a
;; command ends describes a document that moved since the command started.
(define (result-block-insert! buf fstart out &optional result-lang)
  (let* ((blocks (block-list buf))
         (here (assoc fstart blocks))
         (close-end (if here (nth 1 here) fstart))
         (existing (result-block--find buf blocks close-end))
         (norm (if (or (equal? out "") (string-suffix? "\n" out))
                   out
                   (string-append out "\n")))
         (res (string-append "```" (or result-lang "result") "\n" norm "```\n")))
    (if existing
        (let* ((rs (car existing))
               (re (min (buffer-size buf) (+ (cadr existing) 1))))
          (block-replace! buf rs re res))
        (let* ((size (buffer-size buf))
               (at (min (+ close-end 1) size)))
          (buffer-insert! buf at
            (string-append (if (>= close-end size) "\n" "") res))))))

(public! 'result-block-insert!
  "(result-block-insert! BUF FSTART OUT [KIND]) — land OUT in the result fence below the block at FSTART, replacing the one that stands there")

;; Do not leak this block's catalog context into the loader.
(package! result-block-parent-package result-block-parent-namespace)
(domain! result-block-parent-domain)
(effects! result-block-parent-effects)
