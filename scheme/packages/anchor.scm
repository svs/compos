;;; anchor.scm --- go from anchor to anchor, and each anchor carries its keys.
;;;
;;; A page that is not a table still has parts. An application has a
;;; header, a tab row, an assessment, a candidate, a job. Point moving a
;;; character at a time says nothing about which part it is in, and a list
;;; mode is the wrong shape for a page whose parts are not rows.
;;;
;;; An anchor is a named byte range in a buffer. A page declares its
;;; anchors with anchor-set!, TAB and S-TAB walk them, and the anchor at
;;; point puts its OWN keymap in front of the buffer's maps. That is
;;; buffer-at-point-map!, the same mechanism a morg block already uses to
;;; give a fence its language's keys. So `o` can mean open the candidate
;;; inside the candidate anchor and open the job inside the job anchor,
;;; with no dispatch written by hand: the keymap is the dispatch.
;;;
;;; An anchor is declared against the text as it stands, not against a
;;; marker. A page that redraws declares them again, and anchor-set! is
;;; the whole of that update. anchor-goto! by name is how a redraw puts
;;; point back where it was.
;;;
;;;   (define-keymap! "app-candidate-map")
;;;   (define-key "app-candidate-map" "RET" "app-open-candidate")
;;;   (anchor-set! buf `(("header" 1 ,tabs-at)
;;;                      ("candidate" ,tabs-at ,end "app-candidate-map")))
;;;   (enable-minor-mode! buf "anchor-mode")

(domain! 'navigation)
(effects! '(read))

;;; --- the record ------------------------------------------------------------

;; (NAME START END KEYMAP DATA). NAME is the handle a redraw comes back
;; to, START and END are byte offsets with END exclusive, KEYMAP is the
;; map in force while point is inside, and DATA is the page's own.
(define (anchor--norm a)
  (let ((n (length a)))
    (list (list-ref a 0)
          (list-ref a 1)
          (list-ref a 2)
          (and (> n 3) (list-ref a 3))
          (and (> n 4) (list-ref a 4)))))

(define (anchor-name a) (list-ref a 0))
(define (anchor-start a) (list-ref a 1))
(define (anchor-end a) (list-ref a 2))
(define (anchor-keymap a) (list-ref a 3))
(define (anchor-data a) (list-ref a 4))

(define (anchor-list buf)
  (or (and (buffer-known? buf) (buffer-local buf 'anchors)) '()))

;; The innermost anchor holding POS: of the ones that contain it, the one
;; that starts last. Nesting is allowed and the inner keymap wins.
(define (anchor-at buf pos)
  (fold (lambda (best a)
          (if (and (<= (anchor-start a) pos)
                   (< pos (anchor-end a))
                   (or (not best) (>= (anchor-start a) (anchor-start best))))
              a
              best))
        #f
        (anchor-list buf)))

(define (anchor-find buf name)
  (let loop ((as (anchor-list buf)))
    (cond ((null? as) #f)
          ((equal? (anchor-name (car as)) name) (car as))
          (else (loop (cdr as))))))

(define (anchor--after buf pos)
  (let loop ((as (anchor-list buf)))
    (cond ((null? as) #f)
          ((> (anchor-start (car as)) pos) (car as))
          (else (loop (cdr as))))))

;; the list is sorted, so the last one that starts before POS is the one
(define (anchor--before buf pos)
  (fold (lambda (best a) (if (< (anchor-start a) pos) a best))
        #f
        (anchor-list buf)))

(effects! '(write))

;;; --- declaring -------------------------------------------------------------

(define (anchor--sorted as)
  (map cadr
       (sort (map (lambda (a) (list (anchor-start a) a))
                  (map anchor--norm as)))))

;; The whole update. A page that redraws calls this again with the new
;; offsets; nothing else has to be undone.
(define (anchor-set! buf as)
  (buffer-set-local! buf 'anchors (anchor--sorted as))
  (anchor-sync! buf)
  (anchor-list buf))

(define (anchor-add! buf name start end &optional keymap data)
  (anchor-set! buf (cons (list name start end keymap data) (anchor-list buf))))

(define (anchor-clear! buf)
  (buffer-set-local! buf 'anchors '())
  (anchor-sync! buf)
  '())

;;; --- the keymap at point ---------------------------------------------------

;; The anchor at point owns the keys, and the highlight says which anchor
;; that is. Both are set after every command, so they follow point; a
;; position in no anchor has neither.
(define (anchor-sync! buf)
  (and (buffer-exists? buf)
       (let* ((a (anchor-at buf (buffer-point buf)))
              (map (and a (anchor-keymap a))))
         (unless (equal? map (buffer-at-point-map buf))
           (buffer-at-point-map! buf map))
         (overlay-set! buf 'anchor
           (if a (list (list (anchor-start a) (anchor-end a) "anchor-current")) '()))
         a)))

(define (anchor--post-command!)
  (let ((buf (current-buffer)))
    (when (and (buffer-exists? buf) (minor-mode-on? buf "anchor-mode"))
      (anchor-sync! buf))))

(add-hook! 'post-command-hook 'anchor--post-command!)

(defcustom 'anchor-wrap #t
  "Whether TAB past the last anchor comes back to the first one."
  'group 'anchor 'type 'boolean)

;;; --- walking ---------------------------------------------------------------

(define (anchor--land! buf a what)
  (cond ((not a) (message (string-append "No " what)) #f)
        (else
          (goto-char! (anchor-start a))
          (anchor-sync! buf)
          (message (anchor-name a))
          (anchor-start a))))

(define (anchor-goto! buf name)
  (anchor--land! buf (anchor-find buf name) (string-append "anchor " name)))

(define (anchor--step! dir)
  (let* ((buf (current-buffer))
         (as (anchor-list buf))
         (pos (buffer-point buf))
         (hit (if (> dir 0) (anchor--after buf pos) (anchor--before buf pos)))
         ;; the walk is a ring: the last anchor's TAB is the first one
         (target (or hit
                     (and anchor-wrap (pair? as)
                          (if (> dir 0) (car as) (car (reverse as)))))))
    (anchor--land! buf target (if (> dir 0) "next anchor" "previous anchor"))))

(define-command "anchor-next" "Move point to the next anchor"
  (lambda () (anchor--step! 1)))

(define-command "anchor-previous" "Move point to the previous anchor"
  (lambda () (anchor--step! -1)))

;; The arrows' walk: a page whose parts are anchors moves from part to part,
;; and past the last one (or in a buffer with none) the arrow is a line again.
;; It does not wrap; a ring is TAB's, an arrow stops at the end.
(define (anchor--arrow! dir)
  (let* ((buf (current-buffer))
         (pos (buffer-point buf))
         (hit (if (> dir 0) (anchor--after buf pos) (anchor--before buf pos))))
    (cond (hit (goto-char! (anchor-start hit)) (anchor-sync! buf))
          ((> dir 0) (next-line!))
          (else (previous-line!)))))

(define-command "anchor-down" "Move point to the next anchor, or down a line when there is none"
  (lambda () (anchor--arrow! 1)))
(define-command "anchor-up" "Move point to the previous anchor, or up a line when there is none"
  (lambda () (anchor--arrow! -1)))

;; The reading walk, M-<up> and M-<down>. An anchor always comes first,
;; however far: the page chose its stops. Past the last one the key pages,
;; so the rest of a long part still reads. A page is counted in rows as
;; drawn: a line wraps at the window's width, so one paragraph can be many.
(define (anchor--lines buf)
  ;; (START ROWS) for each line of BUF
  (let ((cols (max 20 (or (buffer-cols buf) 80))))
    (let loop ((ls (string-split (buffer-text buf) "\n")) (at 0) (acc '()))
      (if (null? ls) (reverse acc)
          (let ((n (string-length (car ls))))
            (loop (cdr ls) (+ at (string-byte-length (car ls)) 1)
                  (cons (list at (max 1 (quotient (+ n cols -1) cols))) acc)))))))

(define (anchor--rows lines from to)
  ;; rows drawn from the line holding FROM up to the line holding TO
  (let ((lo (min from to)) (hi (max from to)))
    (fold (lambda (sum l)
            (if (and (>= (car l) (anchor--line-start lines lo)) (< (car l) (anchor--line-start lines hi)))
                (+ sum (cadr l)) sum))
          0 lines)))

(define (anchor--line-start lines pos)
  (fold (lambda (best l) (if (<= (car l) pos) (car l) best)) 0 lines))

(define (anchor--page-from lines pos dir page)
  ;; the line start one page of rows from POS
  (let walk ((ls (if (> dir 0)
                     (filter (lambda (l) (> (car l) pos)) lines)
                     (reverse (filter (lambda (l) (< (car l) (anchor--line-start lines pos))) lines))))
             (rows 0) (last #f))
    (cond ((null? ls) last)
          ((>= rows page) (car (car ls)))
          (else (walk (cdr ls) (+ rows (cadr (car ls))) (car (car ls)))))))

(define (anchor--read! dir)
  (let* ((buf (current-buffer))
         (pos (buffer-point buf))
         (hit (if (> dir 0) (anchor--after buf pos) (anchor--before buf pos)))
         (lines (anchor--lines buf))
         (page (max 1 (- (window-rows) 3)))
         (edge (if (> dir 0) (car (car (reverse lines))) 0)))
    (cond (hit (goto-char! (anchor-start hit)) (anchor-sync! buf) (message (anchor-name hit)))
          ((> (anchor--rows lines pos edge) 0)
           (let ((to (anchor--page-from lines pos dir page)))
             (when to (goto-char! to) (anchor-sync! buf))))
          (else (message (if (> dir 0) "No next anchor" "No previous anchor"))))))

(define-command "anchor-read-next" "Move to the next anchor, or one page down past the last"
  (lambda () (anchor--read! 1)))
(define-command "anchor-read-previous" "Move to the previous anchor, or one page up before the first"
  (lambda () (anchor--read! -1)))

(define-command "anchor-jump" "Go to an anchor of this buffer by name"
  (lambda ()
    (let* ((buf (current-buffer))
           (names (map anchor-name (anchor-list buf))))
      (if (null? names)
          (message "This buffer declares no anchors")
          (completing-read "Anchor: " names
            (lambda (name)
              (when (and (string? name) (not (equal? name "")))
                (anchor-goto! buf name))))))))

;;; --- the mode --------------------------------------------------------------

;; Subtle on purpose: an anchor is a section, not a match, so its whole
;; range wears this. A theme that names the face wins.
(defface! 'anchor-current 'inherit 'lazy-highlight)

(define (anchor--apply! buf)
  ;; Anchor navigation must win over generic scrolling in other minor maps.
  (let ((maps (buffer-minor-maps buf)))
    (buffer-minor-maps! buf
      (cons "anchor-mode-map"
            (filter (lambda (name) (not (equal? name "anchor-mode-map"))) maps))))
  (anchor-sync! buf)
  #t)

(define (anchor--teardown! buf)
  (when (buffer-exists? buf)
    (buffer-at-point-map! buf #f)
    (overlay-set! buf 'anchor '()))
  #t)

;; TAB and S-TAB are the page's walk, the way they are a browser's. A mode
;; that turns anchor-mode on in an editable buffer is saying TAB means
;; this here; the anchors' own keymaps come in front of these.
(register-minor-mode! "anchor-mode" anchor--apply! anchor--teardown!)
(minor-mode-keys! "anchor-mode"
  '(("TAB" "anchor-next")
    ("S-TAB" "anchor-previous")
    ("M-<down>" "anchor-read-next")
    ("M-<up>" "anchor-read-previous")
    ("M-down" "anchor-read-next")
    ("M-up" "anchor-read-previous")
    ("M-g a" "anchor-jump")))

(mode-doc! "anchor-mode"
  "The page's parts, one key apart. `TAB` goes to the next anchor and `S-TAB` to the previous one. `M-<down>` and `M-<up>` do too, and page past the last anchor. `M-g a` goes to one by name. The anchor point stands in puts its own keys in front of the buffer's, so the same letter can mean a different thing in each part of the page.")

(define-command "anchor-mode" "Walk this buffer's anchors, each with its own keys"
  (lambda () (toggle-minor-mode! "anchor-mode")))

;;; --- reading a buffer by its parts -----------------------------------------

;; What an agent asks first of any buffer: its parts, the way a reader walks
;; them. A page that declares anchors answers with them; a file answers with
;; its headings or its definitions.
(define (buffer-outline buf)
  (let ((as (anchor-list buf)))
    (cond ((pair? as)
           (with-current-buffer buf
             (lambda ()
               (map (lambda (a) (list (anchor-name a)
                                      (line-number-at-pos (anchor-start a))
                                      (line-number-at-pos (max (anchor-start a) (- (anchor-end a) 1)))))
                    as))))
          ((or (buffer-derived-mode? buf "markdown-mode") (buffer-derived-mode? buf "morg-mode"))
           (markdown-outline buf))
          (else (code-outline buf)))))

(define (buffer-section buf name)
  ;; the text of one anchor, by the name buffer-outline gave
  (let ((a (anchor-find buf name)))
    (and a (with-current-buffer buf (lambda () (buffer-substring (anchor-start a) (anchor-end a)))))))

;;; --- the surface -----------------------------------------------------------

(public! 'anchor-set!
  "(anchor-set! BUF ((NAME START END [KEYMAP [DATA]]) ...)) — declare BUF's anchors, replacing the old ones; a page that redraws calls this again")
(public! 'anchor-add!
  "(anchor-add! BUF NAME START END [KEYMAP [DATA]]) — add one anchor to BUF")
(public! 'anchor-clear! "(anchor-clear! BUF) — BUF has no anchors")
(public! 'anchor-list "(anchor-list BUF) — BUF's anchors, in the order they appear")
(public! 'anchor-at "(anchor-at BUF POS) — the innermost anchor holding byte POS, or #f")
(public! 'anchor-find "(anchor-find BUF NAME) — BUF's anchor called NAME, or #f")
(public! 'anchor-goto! "(anchor-goto! BUF NAME) — put point at the start of that anchor")
(public! 'anchor-sync! "(anchor-sync! BUF) — put the anchor at point's keymap and highlight in force now; the post-command hook already does this")
(public! 'anchor-name "(anchor-name ANCHOR) — its name")
(public! 'anchor-start "(anchor-start ANCHOR) — its first byte")
(public! 'anchor-end "(anchor-end ANCHOR) — the byte after its last")
(public! 'anchor-keymap "(anchor-keymap ANCHOR) — the keymap in force inside it, or #f")
(public! 'anchor-data "(anchor-data ANCHOR) — whatever the page hung on it")
(public! 'buffer-outline
  "(buffer-outline BUF) — BUF's parts, read first: its anchors as (NAME FIRST-LINE LAST-LINE); with none, its markdown headings or code definitions")
(public! 'buffer-section "(buffer-section BUF NAME) — the text of the anchor buffer-outline named NAME, or #f")
