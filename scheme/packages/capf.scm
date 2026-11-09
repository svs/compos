;;; capf.scm --- completion at point.
;;;
;;; Emacs's completion-at-point-functions: a buffer names its completion
;;; sources, and one command completes the symbol under point. Loaded
;;; from init.scm.

(domain! 'unknown)
(effects! '(unknown))

;;; --- completion framework (capf) ---------------------------------------------
;;; A completion source is a closure of no arguments returning either
;;;   #f                                — source has nothing here
;;;   (list start end candidates)      — region to replace + candidates,
;;;                                       each a string or (label hint) pair
;;;   (list start end candidates 'exclusive 'no)
;;;                                    — the same, and when CANDIDATES is
;;;                                       empty the next source is tried
;;; Sources are tried in order; the first that answers wins (Emacs capf).
;;; END may lie past point: accept replaces START..END, so a source that
;;; completes over a suffix names the whole word. An LSP client is just
;;; another source returning the same shape.
;;; Buffer-local sources: (buffer-set-local! buf 'capf-sources (list fn ...))

(define *capf-sources* '())

(define (add-capf! fn)
  (set! *capf-sources* (cons fn *capf-sources*)))

(define (capf-sources)
  (let ((local (buffer-local-value 'capf-sources (current-buffer))))
    (if local (append local *capf-sources*) *capf-sources*)))

;; a source that says 'exclusive 'no yields to the next when it has nothing
(define (capf-result-yields? r)
  (let ((props (cdr (cdr (cdr r)))))
    (and (null? (caddr r))
         (pair? props)
         (equal? (plist-get props 'exclusive) 'no))))

;; the first answer among SOURCES, or #f
(define (capf-collect sources)
  (let loop ((sources sources))
    (if (null? sources)
        #f
        (let ((r ((car sources))))
          (if (and r (not (capf-result-yields? r)))
              r
              (loop (cdr sources)))))))

(define-command "completion-at-point" "Perform completion on the text around point"
  (lambda ()
    (let ((r (capf-collect (capf-sources))))
      (if r
          (completion-show! (car r) (cadr r) (caddr r))
          (begin
            (completion-dismiss!)
            (message "No completions here"))))))

;; The popup's keys are policy (dup #22): while it shows, KeyDispatch
;; consults this map first. Unbound printables narrow; anything else
;; unbound dismisses the popup and acts normally.
(define-command "completion-next" "Select the next completion candidate"
  (lambda () (completion-move! 1)))
(define-command "completion-prev" "Select the previous completion candidate"
  (lambda () (completion-move! -1)))
(define-command "completion-accept" "Insert the selected completion at point"
  (lambda ()
    (let ((a (completion-accept!)))
      (when a
        (let ((start (car a)) (end (cadr a)) (label (caddr a)))
          (when (> end start)
            (buffer-delete-range! (current-buffer) start (- end start)))
          (goto-char! start)
          (insert! label))))))
(define-command "completion-quit" "Dismiss the completion popup"
  (lambda () (completion-dismiss!) (message "")))

(local-set-key* " *completion*" "C-n" "completion-next")
(local-set-key* " *completion*" "<down>" "completion-next")
(local-set-key* " *completion*" "C-p" "completion-prev")
(local-set-key* " *completion*" "<up>" "completion-prev")
(local-set-key* " *completion*" "RET" "completion-accept")
(local-set-key* " *completion*" "TAB" "completion-accept")
(local-set-key* " *completion*" "C-g" "completion-quit")
(local-set-key* " *completion*" "ESC" "completion-quit")
;; a printable inserts and the popup narrows; DEL widens it. Both are
;; bindings, so a package can change what typing into the popup does.
(define-command "completion-delete-backward" "Delete the character before point and narrow the popup"
  (lambda ()
    (delete-char! -1)
    (completion-requery!)))
(local-set-key* " *completion*" "DEL" "completion-delete-backward")

;; The word before point, found by reading the text. A source must never
;; move point, not even to put it back: completion runs on a timer while
;; the user types, and backward-word! followed by goto-char! restores a
;; point the next keystroke has already moved on from. The caret jumps
;; back and the characters land out of order.
(define *capf-word-chars*
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")

(define (capf-word-start e)
  (let* ((lo (max 0 (- e 128)))
         (chunk (buffer-substring lo e)))
    (let loop ((i (- e lo)))
      (if (and (> i 0)
               (let ((c (substring-bytes chunk (- i 1) i)))
                 (and (not (equal? c "")) (string-index *capf-word-chars* c))))
          (loop (- i 1))
          (+ lo i)))))

;; dabbrev: complete the word before point from words in this buffer
(define (capf-dabbrev)
  (let* ((e (point))
         (s (capf-word-start e)))
    (if (>= s e)
        #f
        (let ((words (buffer-words (buffer-substring s e))))
          (if (null? words)
              #f
              (list s e (map (lambda (w) (list w "dabbrev")) words)))))))

;; by name, not by value: a reload must reach the source the popup uses
(add-capf! (lambda () (capf-dabbrev)))

(domain! 'unknown)
(effects! '(unknown))

;;; --- the public API of this file ----------------------------------------------
;;; The catalog scope of each entry is the one it had in editor.scm.

(domain! 'unknown)
(effects! '(unknown))
(category! 'commands)
(public! 'capf-collect "(capf-collect SOURCES) — the first capf answer among SOURCES, honouring 'exclusive 'no, or #f")

(domain! 'unknown)
(effects! '(unknown))

;; effects stamps for the names declared above without one, so
;; eval-scheme-read takes or refuses them by what they do
(for-each (lambda (n) (catalog-meta! 'function (symbol->string n) 'effects '(read)))
  '(capf-collect))
