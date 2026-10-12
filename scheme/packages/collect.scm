;;; collect.scm --- the prompt continues as a buffer (embark-collect).
;;;
;;; A minibuffer prompt's candidates become a list buffer with the same
;;; verbs, so a selection outlives the prompt. Loaded from init.scm.

(domain! 'files)
(effects! '(read))

;;; --- collect: the prompt continues as a buffer (embark-collect) ------------
;;; C-c C-o closes the prompt and collects the candidates that survive its
;;; input. A prompt can route them to a reusable domain list such as ibuffer.
;;; Other prompts use *Collect*, which keeps preview, accept, and cancel.
;;; The handlers come from the prompt itself — minibuffer-detach! closes it
;;; without firing anything and hands them over.

(define *collect-buffer* "*Collect*")

;; the detached prompt lives in globals, not in buffer-locals: a closure
;; cannot survive a restart, and desktop.etf must not hold one. After a
;; restart the buffer is text — the keys say so and stop.
(define *collect-select* #f)     ; the preview hook, from minibuffer-read-preview
(define *collect-confirm* #f)
(define *collect-cancel* #f)
(define *collect-complete* #f)   ; path prompts resolve a label through it
(define *collect-input* "")

(define (collect-forget!)
  (set! *collect-select* #f)
  (set! *collect-confirm* #f)
  (set! *collect-cancel* #f)
  (set! *collect-complete* #f))

(define (collect-fill! prompt cands)
  (let ((buf *collect-buffer*))
    (buffer-delete-range! buf 0 (buffer-size buf))
    (buffer-append! buf
      (string-append ";; " (string-trim prompt) " "
                     (number->string (length cands))
                     " candidates · n/p previews · RET accepts · q quits\n"))
    (buffer-set-local! buf 'collect-labels (map car cands))
    (for-each
      (lambda (c)
        (buffer-append! buf
          (string-append (car c)
                         (if (equal? (cadr c) "") "" (string-append "  " (cadr c)))
                         "\n")))
      cands)))

;; the list opens in another window: the window the prompt ran in must keep
;; showing what the preview acts on, and the list's window names it as owner
(define (collect-open! prompt cands)
  (let ((prompt-window (active-window)))
    (buffer-create *collect-buffer*)
    (collect-fill! prompt cands)
    (let ((showing (window-showing *collect-buffer*)))
      (if showing
          (select-window! showing)
          (begin (split-window! 'v 0.6) (other-window!))))
    (set-window-owner! (active-window) prompt-window))
  (switch-to-buffer! *collect-buffer*)
  (set-mode! "collect-mode")
  (goto-char! 0)
  (next-line!)
  (beginning-of-line!)
  (collect-preview!))

;; the label on the current line — the header is line 0, entries follow
(define (collect-current)
  (if (not (buffer-exists? *collect-buffer*))
      #f
      (collect-label-at)))

(define (collect-label-at)
  (let* ((labels (or (buffer-local *collect-buffer* 'collect-labels) '()))
         (before (substring-bytes (buffer-text *collect-buffer*) 0 (point)))
         (ln (- (length (string-split before "\n")) 2)))
    (if (and (>= ln 0) (< ln (length labels))) (list-ref labels ln) #f)))

;; the preview goes where the prompt's preview went: the window the prompt
;; ran in, the list window's owner. If that window is gone, any other
;; window does. The preview must never land in the list itself, so a lone
;; *Collect* window previews nothing.
(define (collect-target-window)
  (let ((me (active-window)))
    (or (window-owner me) (other-window-id me))))

(define (collect-preview!)
  (let ((label (collect-current)) (w (collect-target-window)))
    (when (and *collect-select* label)
      (if w
          (let ((back (active-window)))
            (select-window! w)
            (*collect-select* label)
            (select-window! back))
          (message "No other window to preview in")))))

;; path prompts resolve a label through their completion fn — that is how
;; find-file turns "editor.scm" back into a full path (see mb_confirm_value)
(define (collect-resolve label)
  (if *collect-complete*
      (let ((r (*collect-complete* *collect-input* label)))
        (if (and (pair? r) (string? (car r))) (car r) label))
      label))

(define (collect-close!)
  (if (null? (cdr (window-list)))
      (run-command "quit-window")        ; kills *Collect* and goes back
      (begin (delete-window!) (buffer-kill! *collect-buffer*))))

(define-command "collect-next" "Move down; the preview follows"
  (lambda () (next-line!) (beginning-of-line!) (collect-preview!)))

(define-command "collect-prev" "Move up; the preview follows"
  (lambda ()
    (previous-line!) (beginning-of-line!)
    (unless (collect-current) (next-line!) (beginning-of-line!))
    (collect-preview!)))

(define-command "collect-accept" "Accept the candidate on this line"
  (lambda ()
    (let ((label (collect-current))
          (fn *collect-confirm*)
          (w (collect-target-window)))
      (cond ((not label) (message "No candidate on this line"))
            ((not fn) (message "This list is stale — run the command again"))
            (else
              (let ((value (collect-resolve label)))
                (collect-forget!)
                (collect-close!)
                (when (and w (window-exists? w)) (select-window! w))
                (fn value)))))))

(define-command "collect-quit" "Close the list; put back what the preview moved"
  (lambda ()
    (let ((fn *collect-cancel*) (w (collect-target-window)))
      (collect-forget!)
      (collect-close!)
      (when (and w (window-exists? w)) (select-window! w))
      (when fn (fn)))))

(define-command "minibuffer-collect" "Write the prompt's candidates into a buffer"
  (lambda ()
    (let ((d (minibuffer-detach!)))
      (if (not d)
          (message "No prompt to collect")
          (let* ((select *mb-select-fn*)
                 (cands (cadr (assoc 'candidates d)))
                 (collector-entry (assoc 'collect d))
                 (collector (and collector-entry (cadr collector-entry))))
            (set! *mb-select-fn* #f)
            ;; the prompt is gone, so the list behind it no longer owns the
            ;; minibuffer's arrows
            (set! *mb-list-buffer* #f)
            (if collector
                (begin
                  (collect-forget!)
                  (collector cands))
                (begin
                  (set! *collect-select* select)
                  (set! *collect-confirm* (cadr (assoc 'confirm d)))
                  (set! *collect-cancel* (cadr (assoc 'cancel d)))
                  (set! *collect-complete* (cadr (assoc 'complete d)))
                  (set! *collect-input* (cadr (assoc 'input d)))
                  (collect-open! (cadr (assoc 'prompt d)) cands))))))))

(define-mode "collect-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-local! buf 'mode-name "collect-mode")
      ;; line movement REMAPS, so arrows, C-n/C-p and any user binding of
      ;; next-line all move-and-preview identically
      (local-remap! "next-line" "collect-next")
      (local-remap! "previous-line" "collect-prev")
      (buffer-set-read-only! buf #t))))

(mode-keys! "collect-mode"
  '(("n" "collect-next") ("p" "collect-prev") ("RET" "collect-accept") ("q" "collect-quit")))

(mode-doc! "collect-mode"
  "The prompt's candidates, as a buffer you can move around in. Moving previews the candidate in the other window. `RET` confirms it in the prompt you came from.")

;; Emacs' C-x C-q. The way out of a read-only buffer, and the reason a mode
;; may open files read-only without trapping the reader.
(define-command "read-only-mode" "Toggle whether this buffer refuses edits"
  (lambda ()
    (let* ((buf (current-buffer))
           (ro? (buffer-read-only? buf)))
      (buffer-set-read-only! buf (not ro?))
      (message (if ro? "writable" "read-only")))))

(global-set-key "C-x C-q" "read-only-mode")

;; A file you reach from a browsing surface (diff-mode, code.scm) opens
;; READ-ONLY. You came to read it, and a stray keystroke in a file you are
;; only passing through is an edit you did not mean. C-x C-q makes it
;; writable. Set *browse-read-only* to #f in init.scm to opt out.
(define *browse-read-only* #t)

(define (browse-visit path)
  (visit path)
  (when *browse-read-only*
    (buffer-set-read-only! (current-buffer) #t)))

(public! 'browse-visit "(browse-visit PATH) — open a file the way the code browser does: read-only unless *browse-read-only* is #f. C-x C-q makes it writable")

;; A file the process cannot write opens READ-ONLY, as in Emacs. A
;; generated file (a Morg tangle) is write-protected on disk for this
;; reason: the document is the source, and the buffer says so before a
;; stray keystroke edits the copy. C-x C-q still makes the buffer
;; writable; the save then fails on the mode bits.
(define (write-protected--find-file-hook!)
  (let* ((buf (current-buffer))
         (path (buffer-path buf)))
    (when (and path (file-exists? path) (not (file-writable? path)))
      (buffer-set-read-only! buf #t)
      (message "File is write-protected"))))

(add-hook! 'find-file-hook 'write-protected--find-file-hook!)

;; DELTA in lines, positive forward. A preview window has no lines, so
;; scroll-window! turns the count into pixels for it — the caller says
;; "a screen" and every kind of window understands.
;; the window the other-window scroll moves: the float when it shows
;; and is not where you are (the card beside your work), else the next
;; window
(define (scroll-other-window-target)
  (let* ((me (active-window))
         (wins (window-list))
         ;; a list scrolls the page it opened beside it, wherever that sits
         (detail (detail-window (window-buffer me))))
    (or (and (float-open?) (not (equal? (float-window) me)) (float-window))
        detail
        (and (pair? (cdr wins))
             (let loop ((ws wins))
               (cond ((null? ws) (car (car wins)))
                     ((equal? (car (car ws)) me)
                      (car (if (null? (cdr ws)) (car wins) (car (cdr ws)))))
                     (else (loop (cdr ws)))))))))

;; A page belongs to the window that scrolls, never to the window the key
;; was pressed in: the two can differ in height and in line height.
;;
;; A page always overlaps and never gaps: the rows it keeps are the reader's
;; thread back to where they were, and a row scrolled past unseen is gone.
;; Every rounding on this path leans the same way. (Emacs
;; next-screen-context-lines; defcustom in layouts.scm, a plain define here
;; because editor.scm loads before custom.scm.)
(define next-screen-context-lines 2)

(define (window-page-rows win)
  (let ((context (max 1 (or next-screen-context-lines 2))))
    (max 1 (- (window-rows win) context))))

(define (scroll-other-window-page! sign)
  (let ((target (scroll-other-window-target)))
    (if target
        (scroll-window! target (* sign (window-page-rows target)))
        (message "No other window"))))

(define-command "scroll-other-window" "Scroll the next window up nearly a full screen"
  (lambda () (scroll-other-window-page! 1)))

(define-command "scroll-other-window-down"
  "Scroll the next window down nearly a full screen"
  (lambda () (scroll-other-window-page! -1)))

(domain! 'unknown)
(effects! '(unknown))
