;;; tab-bars.scm --- an index and its detail: every tab bar by hand and by name.
;;;
;;; An app shows two panes, an index and the detail beside it, and each draws
;;; its tab bars: the index its sections and status tabs, the detail its own
;;; tabs and stages. The two hands split them. The left hand's keys, 1 to 5,
;;; take the tabs of the index's first bar; the right hand's, 6 to 0, take the
;;; tabs of the detail's first bar. The keys work from either pane and never
;;; collide, so no modifier and no change of focus is needed.
;;;
;;; / reaches every tab by name: one minibuffer whose tabs are the bars on
;;; screen, the index's first. Typing filters the tabs of every bar at once; a
;;; minibuffer tab only brings its bar's tabs to the top.
;;;
;;; A mode declares its bars with (tab-bars-declare! MODE FN). FN, given a
;;; buffer, answers ((LABEL TABS) ...), one entry per bar in the order drawn,
;;; and TABS are as ui/tabs takes them: (CLICK LABEL [CURRENT? [KEY]]). A
;;; tab is taken the way the mouse takes it, through the buffer's block-click
;;; hook, so an app hands over the tabs it already draws and nothing else.

(domain! 'ui)
(effects! '(pure))

(define tab-bars-left-keys '("1" "2" "3" "4" "5"))
(define tab-bars-right-keys '("6" "7" "8" "9" "0"))

;; the key of the Nth tab (from 0) of a bar on SIDE, 'index or 'detail, or #f
(define (tab-bars-key side n)
  (let ((keys (if (eq? side 'detail) tab-bars-right-keys tab-bars-left-keys)))
    (and (>= n 0) (< n (length keys)) (list-ref keys n))))

;; TABS with each one's hand key in the KEY slot, past the fifth without one
(define (tab-bars-keyed side tabs)
  (let loop ((ts tabs) (i 0) (acc '()))
    (if (null? ts)
        (reverse acc)
        (let* ((t (car ts))
               (key (tab-bars-key side i))
               (current? (and (> (length t) 2) (list-ref t 2))))
          (loop (cdr ts) (+ i 1)
                (cons (append (list (car t) (cadr t) current?) (if key (list key) '())) acc))))))

(public! 'tab-bars-key "(tab-bars-key SIDE N) — the hand key of tab N (from 0) of a bar on SIDE, 'index (1-5) or 'detail (6-0), or #f")
(public! 'tab-bars-keyed "(tab-bars-keyed SIDE TABS) — ui/tabs TABS with each one's hand key for SIDE as its KEY")

(effects! '(read))

;; the bars function of BUF: its own, else its mode's or a parent mode's
(define (tab-bars-provider buf)
  (and buf (buffer-known? buf)
       (or (buffer-local buf 'tab-bars)
           (let ((mode (buffer-local buf 'mode-name)))
             (and mode (mode-inherited mode 'tab-bars))))))

(define (tab-bars buf)
  (let ((fn (tab-bars-provider buf)))
    (if fn
        (filter (lambda (bar) (pair? (cadr bar))) (or (fn buf) '()))
        '())))

;; (INDEX DETAIL) for BUF: a detail pairs with the index it came from, an
;; index with the detail on screen beside it. Either may be #f.
(define (tab-bars-pair buf)
  (let ((owner (and (boundp 'detail-owner) (detail-owner buf))))
    (if (and owner (tab-bars-provider owner) (tab-bars-provider buf))
        (list owner buf)
        (list (and (tab-bars-provider buf) buf)
              (find (lambda (b)
                      (and (not (equal? b buf))
                           (boundp 'detail-owner)
                           (equal? (detail-owner b) buf)
                           (tab-bars-provider b)))
                    (get-visible-buffers))))))

(public! 'tab-bars "(tab-bars BUF) — BUF's tab bars as ((LABEL TABS) ...), TABS as ui/tabs takes them")
(public! 'tab-bars-provider "(tab-bars-provider BUF) — the function that answers BUF's tab bars, its own or its mode's, or #f")
(public! 'tab-bars-pair "(tab-bars-pair BUF) — (INDEX DETAIL): BUF and the detail beside it, or the index BUF came from and BUF")

(effects! '(write))

(define (tab-bars-keys! mode)
  (for-each (lambda (k i) (define-key (mode-keymap mode) k (string-append "tab-bars-index-" (number->string i))))
            tab-bars-left-keys '(1 2 3 4 5))
  (for-each (lambda (k i) (define-key (mode-keymap mode) k (string-append "tab-bars-detail-" (number->string i))))
            tab-bars-right-keys '(1 2 3 4 5))
  (define-key (mode-keymap mode) "/" "tab-bars-pick")
  mode)

(define (tab-bars-declare! mode fn)
  (mode-put! mode 'tab-bars fn)
  (tab-bars-keys! mode)
  mode)

;; take TAB of BUF as a click on it would
(define (tab-bars-take! buf tab)
  (with-current-buffer buf
    (lambda () (run-hook-with-args-until-success 'block-click buf (car tab)))))

;; the Nth tab (from 1) of the first bar on SIDE of the pair at BUF
(define (tab-bars-nth! buf side n)
  (let* ((pair (tab-bars-pair buf))
         (target (if (eq? side 'detail) (cadr pair) (car pair)))
         (bars (if target (tab-bars target) '()))
         (tabs (if (pair? bars) (cadr (car bars)) '())))
    (cond ((not target) (message (if (eq? side 'detail) "No page with tabs beside this list" "No list with tabs here")))
          ((> n (length tabs)) (message (string-append "No tab " (number->string n) " here")))
          (else (tab-bars-take! target (list-ref tabs (- n 1)))))))

(public! 'tab-bars-declare! "(tab-bars-declare! MODE FN) — MODE's buffers have tab bars: FN (buf) answers ((LABEL TABS) ...); binds 1-5, 6-0 and / on MODE")
(public! 'tab-bars-keys! "(tab-bars-keys! MODE) — bind the hand keys on MODE: 1-5 the index's tabs, 6-0 the detail's, / any tab by name")
(public! 'tab-bars-take! "(tab-bars-take! BUF TAB) — take TAB of BUF as a click on it does")
(public! 'tab-bars-nth! "(tab-bars-nth! BUF SIDE N) — take tab N (from 1) of the first bar on SIDE, 'index or 'detail, of the pair at BUF")

(for-each
  (lambda (i)
    (let ((n (number->string i)))
      (define-command (string-append "tab-bars-index-" n)
        (string-append "Show tab " n " of the list's tab bar")
        (lambda () (tab-bars-nth! (current-buffer) 'index i)))
      (define-command (string-append "tab-bars-detail-" n)
        (string-append "Show tab " n " of the page's tab bar")
        (lambda () (tab-bars-nth! (current-buffer) 'detail i)))))
  '(1 2 3 4 5))

;; every tab on screen as (BUF BAR TAB), the index's bars first
(define (tab-bars--entries buf)
  (apply append
         (map (lambda (b)
                (if b
                    (apply append (map (lambda (bar) (map (lambda (t) (list b (car bar) t)) (cadr bar)))
                                       (tab-bars b)))
                    '()))
              (tab-bars-pair buf))))

;; a tab's name in the prompt: its label, and its bar's when two bars share it
(define (tab-bars--name entry entries)
  (let ((label (cadr (caddr entry))))
    (if (> (length (filter (lambda (e) (equal? (cadr (caddr e)) label)) entries)) 1)
        (string-append label " · " (cadr entry))
        label)))

(define (tab-bars-pick! buf)
  (let* ((entries (tab-bars--entries buf))
         (bars (let loop ((es entries) (acc '()))
                 (cond ((null? es) (reverse acc))
                       ((member (cadr (car es)) acc) (loop (cdr es) acc))
                       (else (loop (cdr es) (cons (cadr (car es)) acc))))))
         ;; the prompt opens on the bar of the pane it was asked from
         (own (tab-bars buf))
         (here (if (pair? own) (car (car own)) (and (pair? bars) (car bars))))
         (tab (let loop ((bs bars) (i 0)) (cond ((null? bs) 0) ((equal? (car bs) here) i) (else (loop (cdr bs) (+ i 1))))))
         ;; every tab stays a candidate; the minibuffer tab's bar comes first
         (ordered (lambda ()
                    (let ((bar (list-ref bars tab)))
                      (append (filter (lambda (e) (equal? (cadr e) bar)) entries)
                              (filter (lambda (e) (not (equal? (cadr e) bar))) entries)))))
         (cands (lambda ()
                  (map (lambda (e)
                         (let ((t (caddr e)))
                           (list (tab-bars--name e entries)
                                 (string-append (cadr e) (if (and (> (length t) 2) (list-ref t 2)) "  ●" "")))))
                       (ordered))))
         (row (lambda () (let loop ((bs bars) (i 0) (out '()))
                           (if (null? bs) (reverse out)
                               (loop (cdr bs) (+ i 1) (cons (list (car bs) (= i tab)) out))))))
         (on-confirm (lambda (name)
                       (let ((hit (find (lambda (e) (equal? (tab-bars--name e entries) name)) entries)))
                         (if hit
                             (tab-bars-take! (car hit) (caddr hit))
                             (message (string-append "No tab " name)))))))
    (if (null? entries)
        (message "No tab bars here")
        (begin
          (minibuffer-read-preview "Tab: " (cands) (lambda (name) #f) on-confirm (lambda () #f) #f "minibuffer")
          (minibuffer-tabs! (row))
          (set! *mb-tab-fn* (lambda (step)
                              (set! tab (modulo (+ tab step) (length bars)))
                              (minibuffer-tabs! (row))
                              (minibuffer-preview-candidates! (cands) on-confirm)
                              #t))))))

(public! 'tab-bars-pick! "(tab-bars-pick! BUF) — one minibuffer over every tab bar of BUF and the pane paired with it; typing filters them all")

(define-command "tab-bars-pick"
  "Show any tab of the list or the page beside it by name: the minibuffer's tabs are the tab bars, and typing filters across all of them"
  (lambda () (tab-bars-pick! (current-buffer))))

(provide 'tab-bars)
