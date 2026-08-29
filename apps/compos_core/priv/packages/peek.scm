;;; peek.scm --- look at a definition without going there.
;;;
;;; Emacs has three verbs for showing a buffer. switch-to-buffer shows it
;;; in the selected window. display-buffer shows it in another window and
;;; leaves point where it is. pop-to-buffer shows it and selects it. `M-.`
;;; in a code buffer is pop-to-buffer at the definition.
;;;
;;; A prose buffer names many definitions. The reader wants to check each
;;; one and go to few. That is display-buffer plus one rule: the window
;;; lives until the next command, unless that command goes there. The
;;; peek command run again on the same name goes there. Any other
;;; command discards the window, and the buffer with it when the peek
;;; opened it.
;;;
;;; The post-command hook runs before the editor records last-command, so
;;; the peek arms a flag for the command that made or kept it. The hook
;;; clears the flag, or discards the peek when no flag is set.

(domain! 'code)
(effects! '(read))

;; (name window origin prev split? opened? buffer) or #f
(define *peek* #f)
(define *peek-armed* #f)

(define (peek--chars)
  (if (boundp '*scheme-ide-chars*) *scheme-ide-chars* *symbol-chars*))

(define (peek--name) (symbol-at-point-in (peek--chars)))

;; -> (SOURCE-KIND TARGET BYTE-POS) or #f. One chain for every buffer:
;; the Scheme catalog sources. A file target is a path; a file buffer is
;; named by its path, so the target is also the buffer name.
(define (definition-locate name &optional kind)
  (and (boundp 'scheme-ide--find-def) (scheme-ide--find-def name kind)))

(define (peek--window-live? win) (assoc win (window-list)))

(define (peek--show! name hit)
  (let* ((me (active-window))
         (kind (car hit))
         (target (cadr hit))
         (pos (caddr hit))
         (opened? (not (buffer-exists? target)))
         (other (other-window-id me))
         (prev (and other (window-buffer other))))
    (if other
        (select-window! other)
        (begin (split-window! 'h 0.5) (other-window!)))
    (if (equal? kind 'buffer) (switch-to-buffer! target) (visit target))
    (goto-char! pos)
    (let ((win (active-window)))
      (select-window! me)
      (set! *peek* (list name win me prev (not other) opened? (if (equal? kind 'buffer) target (peek--buffer-of win))))
      win)))

(define (peek--buffer-of win)
  (let ((hit (assoc win (window-list))))
    (and hit (cadr hit))))

(define (peek-discard!)
  (when *peek*
    (let* ((p *peek*)
           (win (list-ref p 1))
           (origin (list-ref p 2))
           (prev (list-ref p 3))
           (split? (list-ref p 4))
           (opened? (list-ref p 5))
           (buf (list-ref p 6)))
      (set! *peek* #f)
      (when (peek--window-live? win)
        (cond (split? (delete-window-id! win))
              (prev
                (let ((me (active-window)))
                  (select-window! win)
                  (switch-to-buffer! prev)
                  (when (peek--window-live? me) (select-window! me))))))
      (when (peek--window-live? origin) (select-window! origin))
      (when (and opened? buf (buffer-exists? buf)
                 (not (window-showing buf))
                 (not (buffer-modified? buf)))
        (buffer-kill! buf)))))

(define (peek-go!)
  (let ((p *peek*))
    (set! *peek* #f)
    (when (boundp 'lsp--push-marker!) (lsp--push-marker!))
    (select-window! (list-ref p 1))
    (message (string-append "Definition of " (car p)))))

(define (peek--post-command!)
  (cond (*peek-armed* (set! *peek-armed* #f))
        ((and *peek* (equal? (active-window) (list-ref *peek* 1)))
         ;; the reader moved into the window by another road: it is theirs
         (set! *peek* #f))
        (*peek* (peek-discard!))))

(add-hook! 'post-command-hook peek--post-command!)


(define-command "definition-peek"
  "Show the definition of the name at point in the other window; run again to go there"
  (lambda ()
    (let ((name (peek--name)))
      (cond
        ((not name) (message "No name at point"))
        ((and *peek* (equal? name (car *peek*)) (peek--window-live? (list-ref *peek* 1)))
         (set! *peek-armed* #t)
         (peek-go!))
        (else
          (peek-discard!)
          (let ((hit (definition-locate name)))
            (cond
              (hit
                (set! *peek-armed* #t)
                (peek--show! name hit)
                (message (string-append "Definition of " name " in the other window; press again to go there, any other key closes it")))
              ((and (boundp 'primitive-doc) (primitive-doc name))
               (message (string-append name " is a primitive: " (primitive-doc name))))
              (else (message (string-append "No definition of " name))))))))))

(define-command "definition-peek-go"
  "Go to the definition the peek window shows"
  (lambda ()
    (if (and *peek* (peek--window-live? (list-ref *peek* 1)))
        (begin (set! *peek-armed* #t) (peek-go!))
        (message "No peek to go to"))))

(define-command "definition-peek-discard"
  "Close the peek window"
  (lambda () (peek-discard!)))

(for-each (lambda (name) (undo-exempt! name))
          '("definition-peek" "definition-peek-go" "definition-peek-discard"))

(public! 'definition-locate
  "(definition-locate NAME [KIND]) -- (SOURCE-KIND TARGET BYTE-POS) of NAME's definition, or #f")
(public! 'peek-discard!
  "(peek-discard!) -- close the peek window; kill its buffer when the peek opened it")
