;;; index.scm --- a buffer whose items open beside it, one at a time.
;;;
;;; Knowledge work is mostly an index and its details: a job's candidates,
;;; an inbox, a contents page. An index is any buffer whose items open as
;;; its children (detail.scm): every item takes the one detail window, and
;;; q on the index takes the detail with it (dismiss.scm).
;;;
;;; A mode declares itself an index with three commands, each run in the
;;; index: next and prev move point to the neighbouring item, and open shows
;;; the item at point through display-buffer-detail!. index-mode turns on in
;;; every buffer of such a mode, or of a mode derived from one.
;;;
;;; A detail walks its index without going back to it: N and P open the next
;;; and previous item in the detail's own window, and ^ goes up to the index.
;;; A buffer can be both: a job's pipeline is a detail of the jobs list and
;;; the index of its candidates.

(domain! 'windows)
(effects! '(read))

(define (index-spec &optional buf)
  ;; a buffer's own declaration wins over its mode's: one browse page is an
  ;; index, the next is an article. 'none refuses the mode's.
  (let* ((b (or buf (current-buffer)))
         (own (and (buffer-known? b) (buffer-local b 'index-spec)))
         (mode (and (buffer-known? b) (buffer-local b 'mode-name))))
    (cond ((eq? own 'none) #f)
          ((pair? own) own)
          (else (and mode (mode-inherited mode 'index))))))

(public! 'index-spec
  "(index-spec [BUF]) — BUF's index declaration, a plist of its next, prev and open commands, or #f")

(effects! '(write display))

(define (index-declare! mode &rest spec)
  (mode-put! mode 'index spec)
  mode)

(define (index-set! buf spec)
  (buffer-set-local! buf 'index-spec spec)
  (index--sync! buf)
  buf)

(register-minor-mode! "index-mode" (lambda (buf) #t) (lambda (buf) #t))

(define (index--sync! buf)
  (when (buffer-exists? buf)
    (let ((on (and (index-spec buf) #t)))
      (cond ((and on (not (minor-mode-on? buf "index-mode")))
             (enable-minor-mode! buf "index-mode"))
            ((and (not on) (minor-mode-on? buf "index-mode"))
             (disable-minor-mode! buf "index-mode"))))))

(define (index--after-mode! &rest args) (index--sync! (current-buffer)))
(advice-add! 'set-mode! 'after 'index-mode 'index--after-mode!)

;; step the index one item and open it. From a detail the item lands in the
;; detail's own window: display-buffer-detail! keeps a list's children in the
;; window you stand in when it already shows one of them.
(define (index-step! ix dir)
  (let ((spec (index-spec ix)))
    (if (not spec)
        (begin (message "This list cannot step its items") #f)
        (with-current-buffer ix
          (lambda ()
            (run-command (plist-get spec (if (> dir 0) 'next 'prev)))
            (run-command (plist-get spec 'open)))))))

;; the walk keys are plain letters, so a writable detail (a chat) types them
(define (index--walk! dir)
  (if (not (buffer-read-only? (current-buffer)))
      (run-command "self-insert-command")
      (let ((ix (detail-owner)))
        (if ix (index-step! ix dir) (message "This page has no list to walk")))))

(define-command "index-next-item" "Open the next item of the list this page came from, here"
  (lambda () (index--walk! 1)))

(define-command "index-previous-item" "Open the previous item of the list this page came from, here"
  (lambda () (index--walk! -1)))

(define-command "index-up" "Go to the list this page came from"
  (lambda ()
    (if (not (buffer-read-only? (current-buffer)))
        (run-command "self-insert-command")
        (let ((ix (detail-owner)))
          (if (not ix)
              (message "This page has no list")
              (let ((w (find (lambda (w) (equal? (window-buffer w) ix)) (display--work-windows))))
                (if w (select-window! w) (switch-to-buffer! ix))))))))

(for-each index--sync! (buffer-list))

(public! 'index-declare!
  "(index-declare! MODE 'next CMD 'prev CMD 'open CMD) — MODE's buffers are indexes: NEXT and PREV move to an item, OPEN shows it as a detail")
(public! 'index-set!
  "(index-set! BUF SPEC) — BUF's own index declaration: a plist as index-declare! takes, 'none for not an index, #f for its mode's")
(public! 'index-step!
  "(index-step! INDEX DIR) — move INDEX one item, forward for DIR 1 and back for -1, and open it")
