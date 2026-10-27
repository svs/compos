;;; definition.scm --- show a definition without going there.
;;;
;;; Emacs has three verbs for showing a buffer. switch-to-buffer shows it
;;; in the selected window. display-buffer shows it in another window and
;;; leaves point where it is. pop-to-buffer shows it and selects it. `M-.`
;;; in a code buffer is pop-to-buffer at the definition.
;;;
;;; A prose buffer names many definitions. The reader wants to check each
;;; one and go to few. That is display-buffer: the definition opens
;;; normally in another window by the display chain and the focus stays.
;;; The command run again on the same name goes there.

(domain! 'code)
(effects! '(read))

;; the last definition shown: (NAME WINDOW), or #f
(define definition--last #f)

(define (definition--name) (symbol-at-point-in *scheme-ide-chars*))

;; -> (SOURCE-KIND TARGET BYTE-POS) or #f. One chain for every buffer:
;; the Scheme catalog sources. A file target is a path; a file buffer is
;; named by its path, so the target is also the buffer name.
(define (definition-locate name &optional kind)
  (scheme-ide--find-def name kind))

;; the window of the last definition shown, while it still shows it
(define (definition--window)
  (and definition--last
       (window-exists? (cadr definition--last))
       (cadr definition--last)))

(define (definition--show! name hit)
  (let* ((target (cadr hit))
         (buf (if (equal? (car hit) 'buffer) target (visit-quietly target)))
         (win (display-buffer-other-window! buf)))
    (when (window-exists? win) (window-set-point! win (caddr hit)))
    (set! definition--last (list name win))
    win))

(define (definition--go!)
  (let ((name (car definition--last)) (win (definition--window)))
    (set! definition--last #f)
    (lsp--push-marker!)
    (select-window! win)
    (message (string-append "Definition of " name))))

(define-command "definition-show"
  "Show the definition of the name at point in the other window; run again to go there; a link there is followed"
  (lambda ()
    (unless (goto-address-follow-at-point!)
      (definition-show!))))

(define (definition-show!)
    (let ((name (definition--name)))
      (cond
        ((not name) (message "No name at point"))
        ((and (definition--window) (equal? name (car definition--last)))
         (definition--go!))
        (else
          (set! definition--last #f)
          (let ((hit (definition-locate name)))
            (cond
              (hit
                (definition--show! name hit)
                (message (string-append "Definition of " name " in the other window; press again to go there")))
              ((and (boundp 'primitive-doc) (primitive-doc name))
               (message (string-append name " is a primitive: " (primitive-doc name))))
              (else (message (string-append "No definition of " name)))))))))

(define-command "definition-go"
  "Go to the definition the other window shows"
  (lambda ()
    (if (definition--window)
        (definition--go!)
        (message "No definition shown"))))

(for-each (lambda (name) (undo-exempt! name))
          '("definition-show" "definition-go"))

(public! 'definition-locate
  "(definition-locate NAME [KIND]) -- (SOURCE-KIND TARGET BYTE-POS) of NAME's definition, or #f")
