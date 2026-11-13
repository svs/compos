;;; minibuffer.scm --- the prompt: its buffer, its shapes, its lists.
;;;
;;; Everything a prompt does in Scheme: the rail and the tabs, the three
;;; shapes and the dock, candidate preview, completing-read, the one-key
;;; questions, minibuffer-mode and the history. This file owns the prompt:
;;; its handlers, what RET, TAB, DEL and C-n mean, and when its change
;;; handler runs. The frame keeps only the snapshot its render walk draws:
;;; the input, the candidate list and the matching (Candidates). editor.scm requires it at its end, so every name the
;;; forms below call at load is bound by then.

(domain! 'interaction)
(effects! '(unknown))

;;; --- the frame's prompt and popup snapshot -----------------------------------
;;; The frame keeps only what its render walk draws; prompt--do reads and
;;; writes it, one operation at a time, and #f is none open.

(effects! '(read))
(define (minibuffer--facts) (prompt--do 'facts))
(define (minibuffer--filtered) (or (prompt--do 'filtered) '()))
(define (completion--start) (prompt--do 'start))
(define (minibuffer-selected) (prompt--do 'selected))
(public! 'minibuffer-selected "(minibuffer-selected) — return the highlighted minibuffer candidate, or #f.")

(effects! '(write))
(define (minibuffer--show! prompt cands view) (prompt--do 'show prompt cands view))
(define (minibuffer--hide!) (prompt--do 'hide))
(define (minibuffer--sync!) (prompt--do 'sync))
(define (minibuffer--move! delta) (prompt--do 'move delta))
(define (completion--accept!) (prompt--do 'accept))
(define (minibuffer-set-candidates! cands) (prompt--do 'candidates cands))
(public! 'minibuffer-set-candidates! "(minibuffer-set-candidates! CANDIDATES) — replace the minibuffer's candidate list.")
(define (completion-query! text) (prompt--do 'query text))
(public! 'completion-query! "(completion-query! TEXT) — narrow the open popup to TEXT; no row left closes it.")
(define (completion-move! delta) (prompt--do 'cmove delta))
(public! 'completion-move! "(completion-move! DELTA) — move the popup selection by DELTA rows.")
(effects! '(unknown))

;;; --- minibuffer --------------------------------------------------------------
;;; The minibuffer is a real buffer (" *minibuf*"): point motion, kill/yank,
;;; undo and M-DEL all work in prompts for free via the global keymap. Only
;;; prompt-specific behavior is bound here, in its local keymap.

;;; --- the rail: the palette's second list -------------------------------------
;;; A modal prompt can carry a list on the right as well as the left. Only
;;; one of the two holds the keys: <right> steps into the rail, <left>
;;; steps back out, and up/down/RET always mean the list you are standing
;;; in. The prompt owns the rows and what RET does with one; this keeps
;;; the cursor and tells the frame, so the view infers nothing.

(define *mb-rail-rows* '())
(define *mb-rail-index* 0)
(define *mb-rail-focus* #f)
(define *mb-rail-pick* #f)

(define (mb-rail-reset!)
  (set! *mb-rail-rows* '())
  (set! *mb-rail-index* 0)
  (set! *mb-rail-focus* #f)
  (set! *mb-rail-pick* #f))

(define (mb-rail-push!)
  (minibuffer-rail! *mb-rail-rows* *mb-rail-index* *mb-rail-focus*))

;; ROWS is ((LABEL HINT . REST) ...) — the frame reads the first two and
;; carries the rest untouched, so PICK gets back the whole row and the
;; prompt can act on what it put there
(define (mb-rail! rows pick)
  (set! *mb-rail-rows* rows)
  (set! *mb-rail-pick* pick)
  (when (null? rows) (set! *mb-rail-focus* #f))
  (when (>= *mb-rail-index* (length rows)) (set! *mb-rail-index* 0))
  (mb-rail-push!))

(define (mb-rail-focused?) (and *mb-rail-focus* (pair? *mb-rail-rows*)))

(define (mb-rail-enter!)
  (cond ((mb-rail-focused?) #t)
        ((null? *mb-rail-rows*) #f)
        (else (set! *mb-rail-focus* #t) (set! *mb-rail-index* 0) (mb-rail-push!) #t)))

(define (mb-rail-exit!)
  (if (mb-rail-focused?)
      (begin (set! *mb-rail-focus* #f) (mb-rail-push!) #t)
      #f))

(define (mb-rail-move! delta)
  (if (mb-rail-focused?)
      (begin
        (set! *mb-rail-index*
              (max 0 (min (- (length *mb-rail-rows*) 1) (+ *mb-rail-index* delta))))
        (mb-rail-push!)
        #t)
      #f))

(define (mb-rail-confirm!)
  (if (and (mb-rail-focused?) *mb-rail-pick*)
      (begin (*mb-rail-pick* (list-ref *mb-rail-rows* *mb-rail-index*)) #t)
      #f))

;; a prompt with tabs takes the side arrows after the rail: the fn gets
;; STEP, -1 or 1, and answers #t when it moved the tab. The preview
;; prompt clears it, so a stale fn never steers the next prompt.
(define *mb-tab-fn* #f)
;; a prompt that gives SPC KEY a meaning of its own (jump to a tab) sets
;; this: the fn gets the key and answers #t when it took it
(define *mb-leader-fn* #f)

;; a prompt whose rows nest folds them with TAB: the fn gets the selected
;; candidate and answers #t when it took the key
(define *mb-fold-fn* #f)

;; a preview prompt that redraws its rows as the input changes: the fn gets the input
(define *mb-change-fn* #f)

(define (mb-tab-step! step)
  (and *mb-tab-fn* (minibuffer-active?) (*mb-tab-fn* step)))

;; a tabbed prompt opens on the tab it showed the last time: KEY names the
;; prompt, the tab is kept by label, so a prompt whose tabs change keeps
;; what still is there. RECALL answers the index of the remembered tab in
;; LABELS, else DEFAULT
(define *mb-tab-memory* '())

(define (mb-tab-recall key labels default)
  (let ((want (assoc key *mb-tab-memory*)))
    (let loop ((ls labels) (i 0))
      (cond ((or (not want) (null? ls)) default)
            ((equal? (car ls) (cadr want)) i)
            (else (loop (cdr ls) (+ i 1)))))))

(define (mb-tab-remember! key label)
  (set! *mb-tab-memory* (cons (list key label) (filter (lambda (e) (not (equal? (car e) key))) *mb-tab-memory*))))

;; One tab row for every prompt that has tabs, so C-x b, C-x c and the rest
;; read the same. TABS is ((ID LABEL) ...); an ID of 'sep is a gap, no tab.
(effects! '(pure))
(define (minibuffer-tab-keys tabs)
  ;; each tab's SPC key: the first free letter of its name, else of the
  ;; alphabet. ((ID KEY) ...); a gap gets none.
  (let loop ((ts tabs) (used '()) (out '()))
    (if (null? ts)
        (reverse out)
        (let* ((label (string-downcase (cadr (car ts))))
               (free (lambda (c) (and (string<=? "a" c) (string<=? c "z") (not (member c used)))))
               (pick (let try ((i 0))
                       (cond ((>= i (string-length label))
                              (let alpha ((cs (string-split "abcdefghijklmnopqrstuvwxyz" "")))
                                (cond ((null? cs) #f) ((free (car cs)) (car cs)) (else (alpha (cdr cs))))))
                             ((free (substring label i (+ i 1))) (substring label i (+ i 1)))
                             (else (try (+ i 1)))))))
          (if (or (equal? label "") (eq? (car (car ts)) 'sep) (not pick))
              (loop (cdr ts) used out)
              (loop (cdr ts) (cons pick used) (cons (list (car (car ts)) pick) out)))))))

(define (minibuffer-tab-step tab step tabs)
  ;; the tab STEP away from TAB, round the row, over the gaps
  (let* ((ids (map car (filter (lambda (t) (not (eq? (car t) 'sep))) tabs)))
         (n (length ids))
         (i (let loop ((ks ids) (i 0))
              (cond ((null? ks) 0) ((equal? (car ks) tab) i) (else (loop (cdr ks) (+ i 1)))))))
    (if (= n 0) tab (nth (modulo (+ i step n) n) ids))))

(define (minibuffer-tab-row tab tabs locked keys)
  ;; what minibuffer-tabs! draws: ((LABEL CURRENT? [KEY]) ...); a locked
  ;; prompt shows its own tab only
  (let ((row (map (lambda (t)
                    (let ((k (assoc (car t) keys)))
                      (if k
                          (list (cadr t) (equal? (car t) tab) (cadr k))
                          (list (cadr t) (equal? (car t) tab)))))
                  tabs)))
    (if locked (filter cadr row) row)))

(effects! '(write display))
(define (minibuffer-tabbed! tabs tab show)
  ;; Give the open prompt TABS, on TAB. SHOW gets the ID of each tab the
  ;; user goes to and redraws the rows. The side arrows step, SPC KEY jumps
  ;; to a tab, and TAB locks the prompt on its tab.
  (let* ((keys (minibuffer-tab-keys tabs))
         (locked #f)
         (draw! (lambda () (minibuffer-tabs! (minibuffer-tab-row tab tabs locked keys))))
         (go! (lambda (next) (set! tab next) (draw!) (show tab) #t)))
    (draw!)
    (set! *mb-leader-fn*
      (lambda (k)
        (let find-key ((ks keys))
          (cond ((null? ks) #f)
                ((equal? (cadr (car ks)) k) (set! locked #f) (go! (car (car ks))))
                (else (find-key (cdr ks)))))))
    (set! *mb-tab-fn*
      (lambda (step) (and (not locked) (go! (minibuffer-tab-step tab step tabs)))))
    (set! *mb-fold-fn*
      (lambda (sel)
        (set! locked (not locked))
        (draw!)
        (message (if locked
                     (string-append "in " (cadr (assoc tab tabs)) " -- TAB unlocks")
                     "all tabs -- the side arrows move"))
        #t))))
(public! 'minibuffer-tabbed! "(minibuffer-tabbed! TABS TAB SHOW) — give the open prompt a tab row: TABS is ((ID LABEL) ...), 'sep is a gap; it opens on TAB. SHOW gets the ID of each tab the user goes to and redraws the rows. The side arrows step, SPC KEY jumps (KEY is a letter of the tab's name), TAB locks the prompt on its tab.")
(effects! '(unknown))

(define-command "minibuffer-rail-enter"
  "Move the arrows into the list on the right of the palette, or to the next tab"
  (lambda () (cond ((mb-rail-enter!) #t) ((mb-tab-step! 1) #t) (else (run-command "forward-char"))))
  'modes '(minibuffer-mode))
(define-command "minibuffer-rail-exit"
  "Leave the list on the right and go back to the candidates, or to the previous tab"
  (lambda () (cond ((mb-rail-exit!) #t) ((mb-tab-step! -1) #t) (else (run-command "backward-char"))))
  'modes '(minibuffer-mode))

(define-command "minibuffer-confirm" "Accept the selected minibuffer candidate"
  (lambda () (if (mb-rail-confirm!) #t (minibuffer-confirm!)))
  'modes '(minibuffer-mode))
(define-command "minibuffer-confirm-input" "Accept the minibuffer input exactly as typed"
  (lambda () (minibuffer-confirm-input!))
  'modes '(minibuffer-mode))
(define-command "minibuffer-cancel" "Cancel the minibuffer prompt"
  (lambda () (minibuffer-cancel!))
  'modes '(minibuffer-mode))

;;; The shape is not a different prompt. What you opened as a modal can
;;; finish as the bottom bar and go back, carrying the same input, the same
;;; candidates and the same selection: only the geometry changes. A prompt
;;; that says what its row means (a question) keeps its shape.
;;;
;;; A prompt that stands in front of a LIST changes shape with it. The
;;; table is a window and the prompt is a line, and the two are one
;;; surface: the shape says where that surface is.
;;;
;;;   minibuffer  a DOCK: the bottom rows of the frame, in the flow. The
;;;               window tree shrinks by exactly that much, so the surface
;;;               covers no work and hides nothing. This is the default.
;;;   panel       the same rows, floating over the work. Nothing reflows
;;;               and the work underneath is hidden while you look.
;;;   modal       the centred palette.
;;;
;;; The panel and the modal are the float (window.scm): a shape a prompt
;;; wears for as long as it is open.

(define minibuffer-default-shape "minibuffer")

;;; --- the dock ------------------------------------------------------------
;;; A dock is a pane of the FRAME. split-root! splits the whole tree, so
;;; the pane spans the frame and every window above keeps its share of
;;; what is left: the surface takes rows rather than covering them. This
;;; is what makes the minibuffer shape a minibuffer and not a panel.
;;;
;;; Splitting the selected window instead gives a pane as wide as whatever
;;; window happened to be selected, which is a sub-pane, not a dock.

(define (window-docked buf)
  (and (buffer-known? buf) (buffer-local-value 'window-dock buf)))

;; A dock is not a work window. Every rule that keeps the float out of
;; the layout keeps a dock out too: the tiler must not count it, fill it,
;; or renumber it away, and a display must never land in it.
(define (window-dock? win buf) (and buf (equal? (window-docked buf) win)))

(define (window-dock! buf size)
  (let* ((past (window-prev-buffers (active-window)))
         (win (split-root! 'v (- 1 size))))
    (when win
      ;; the dock starts with the past of the window it split from
      (set-window-prev-buffers! win past)
      (window-float-class! buf #f)
      (buffer-set-local! buf 'window-dock win)
      (display-buffer-in-window! win buf)
      (select-window! win))
    win))

(define (window-undock! buf)
  (let ((win (window-docked buf)))
    (when (buffer-known? buf) (buffer-set-local! buf 'window-dock #f))
    (and win (window-exists? win) (delete-window-id! win))))

;; BUF's window wears SHAPE. The buffer remembers it, so a display of
;; this buffer takes the shape too, and a shape change moves the surface
;; and nothing else: no mode setup runs, so a table keeps its rows, its
;; filter and the row the reader is on.
(define (window-shape! buf shape)
  (buffer-set-local! buf 'window-shape shape)
  (if (equal? shape "minibuffer")
      (begin
        (when (equal? (float-buffer) buf) (float-close!))
        (window-float-class! buf #f)
        (unless (window-docked buf)
          (window-dock! buf (display-param buf 'size))))
      (begin
        (window-undock! buf)
        (window-float-class! buf
          (if (equal? shape "modal") 'center 'bottom)
          (display-param buf 'size))
        (unless (window-showing buf) (display-buffer buf)))))

;; the list standing behind the prompt takes the shape the prompt takes
(define (mb-list-shape! shape)
  (let ((buf *mb-list-buffer*))
    (when (and buf (buffer-known? buf)) (window-shape! buf shape))))

(define (minibuffer-shape)
  (let* ((st (minibuffer-state))
         (style (and st (plist-get st 'style))))
    (cond ((member style '("modal" "palette")) "modal")
          ((member style '("panel" "popup")) "panel")
          (else "minibuffer"))))

(define (minibuffer-shape-after here)
  (cond ((equal? here "minibuffer") "panel")
        ((equal? here "panel") "modal")
        (else "minibuffer")))

;; The shape of a prompt with a list behind it is the shape of the list:
;; the filter line is one row either way, and what moves is the table.
;; So a filter prompt cycles, and only a question keeps its shape.
(define (minibuffer-list-shape)
  (and *mb-list-buffer*
       (buffer-known? *mb-list-buffer*)
       (let ((side (float-side-of *mb-list-buffer*)))
         (cond ((equal? side 'center) "modal")
               (side "panel")
               (else "minibuffer")))))

(define-command "minibuffer-cycle-shape"
  "Show this prompt as the bottom bar, the panel, or the modal"
  (lambda ()
    (if (not (minibuffer-active?))
        (message "No prompt")
        (let ((style (plist-get (minibuffer-state) 'style))
              (list-shape (minibuffer-list-shape)))
          (cond
            ((equal? style "question") (message "This prompt keeps its shape"))
            (list-shape
              (let ((next (minibuffer-shape-after list-shape)))
                (mb-list-shape! next)
                (message next)))
            ((equal? style "filter") (message "This prompt keeps its shape"))
            (else
              (let ((next (minibuffer-shape-after (minibuffer-shape))))
                (minibuffer-style! next)
                (message next)))))))
  'modes '(minibuffer-mode))
(define-command "minibuffer-next-candidate" "Select the next minibuffer candidate"
  (lambda ()
    (cond ((mb-rail-move! 1) #t)
          ((mb-list-move! 1) #t)
          (else (minibuffer-next!) (mb-select-notify!))))
  'modes '(minibuffer-mode))
(define-command "minibuffer-previous-candidate" "Select the previous minibuffer candidate"
  (lambda ()
    (cond ((mb-rail-move! -1) #t)
          ((mb-list-move! -1) #t)
          (else (minibuffer-prev!) (mb-select-notify!))))
  'modes '(minibuffer-mode))
;; A prompt may let its rows be deleted: *mb-row-delete-fn* is a thunk that
;; deletes the highlighted row. <delete> runs it, and DEL does on an empty
;; input, where there is no character to delete.
(define *mb-row-delete-fn* #f)

(define-command "minibuffer-delete-backward" "Delete the character before point, or the highlighted row of an empty prompt that allows it"
  (lambda ()
    (if (and *mb-row-delete-fn* (equal? (minibuffer-input) ""))
        (*mb-row-delete-fn*)
        (minibuffer-del!)))
  'modes '(minibuffer-mode))

(define-command "minibuffer-delete-row" "Delete the highlighted row, in a prompt that allows it"
  (lambda ()
    (if *mb-row-delete-fn*
        (*mb-row-delete-fn*)
        (message "Nothing here deletes a row")))
  'modes '(minibuffer-mode))
(define-command "minibuffer-complete"
  "Fold the row or section at hand, else complete the input"
  (lambda ()
    (cond ((and *mb-fold-fn* (minibuffer-selected) (*mb-fold-fn* (minibuffer-selected))) #t)
          ((mb-list-call! 'fold) #t)
          (else (minibuffer-complete!))))
  'modes '(minibuffer-mode))
(define-command "minibuffer-regroup"
  "Cycle what a section is in the list behind the prompt"
  (lambda () (if (mb-list-call! 'regroup) #t (message "no list here")))
  'modes '(minibuffer-mode))
(define-command "minibuffer-next-section"
  "Move to the next section in the list behind the prompt, else the next history entry"
  (lambda ()
    (cond ((and *mb-history-key* (>= *mb-history-pos* 0))
           (run-command "next-history-element"))
          ((mb-list-section! 1) #t)
          (else (run-command "next-history-element"))))
  'modes '(minibuffer-mode))
(define-command "minibuffer-previous-section"
  "Move to the previous section in the list behind the prompt, else the previous history entry"
  ;; an empty prompt, or one already walking its history, walks the history
  (lambda ()
    (cond ((and *mb-history-key* (or (>= *mb-history-pos* 0) (equal? (minibuffer-input) "")))
           (run-command "previous-history-element"))
          ((mb-list-section! -1) #t)
          (else (run-command "previous-history-element"))))
  'modes '(minibuffer-mode))

;;; --- candidate preview (the consult mechanism) -------------------------------
;;; Emacs previews by hooking SELECTION, not windows: consult registers a
;;; state function that fires as the highlighted candidate changes, shows
;;; it in the window the prompt was invoked from (minibuffer-selected-
;;; window), and restores on quit. Same here: a prompt can register a
;;; select hook; it fires after C-n/C-p and after typing refilters. The
;;; preview itself uses window-preview-buffer!, which never touches the
;;; MRU ring — cancelling leaves history exactly as it was.

(define *mb-select-fn* #f)

(define (mb-select-notify!)
  (when *mb-select-fn*
    (let ((sel (minibuffer-selected)))
      (when sel (*mb-select-fn* sel)))))

;; current-buffer defaults to the minibuffer's OWN text while one is
;; active (the normal case: typing in the minibuffer should act on the
;; minibuffer). A preview callback is the opposite by definition — its
;; whole job is to act on what you're previewing, in the window you
;; invoked it from — so wrap it here, once, rather than trust every
;; future caller to remember set-mb-redirect! for themselves. Forgetting
;; it doesn't error; it just silently moves point in text nobody sees,
;; which is exactly the bug this replaced.
(define (with-invoking-buffer thunk)
  (set-mb-redirect! #f)
  (let ((result (thunk)))
    (set-mb-redirect! #t)
    result))

;; minibuffer-read with live candidate preview: ON-SELECT fires per
;; highlight move, ON-CONFIRM with the choice, ON-CANCEL on C-g (restore
;; whatever the preview displaced there). All three run against the
;; invoking buffer, not the minibuffer's — see with-invoking-buffer.
;; One prompt at a time, as in Emacs without enable-recursive-minibuffers.
;; A prompt that opens while another is up cancels the outer one first,
;; so its cancel handler restores what it displaced, instead of the
;; outer prompt vanishing with its closures.

;;; --- the prompt record --------------------------------------------------------
;;; What a prompt does lives here; what it shows lives in the frame. The
;;; record is the open prompt's handlers, a plist (confirm F cancel F
;;; complete F change F collect F), kept as a local of the frame's own
;;; prompt buffer: every frame has one, and a buffer-local keeps its
;;; closures alive for the collector. The frame's snapshot says whether a
;;; prompt is open; the record is read only then.

(define (minibuffer-active?) (if (minibuffer--facts) #t #f))

;; what the prompt holds now, "" without a prompt
(define (minibuffer-input)
  (let ((f (minibuffer--facts)))
    (if f (plist-get f 'input) "")))

(define (minibuffer--record)
  (let ((buf (minibuffer-buffer)))
    (or (and (buffer-exists? buf) (buffer-local-value 'minibuffer-prompt buf)) '())))

(define (minibuffer--handler key)
  (let ((h (plist-get (minibuffer--record) key)))
    (if (procedure? h) h #f)))

;; the handler alist's entry for KEY, the last one when it repeats; #f
;; when the alist has none, so a present #f is told from an absent key
(define (minibuffer--opt handlers key)
  (let loop ((hs handlers) (found #f))
    (cond ((null? hs) found)
          ((and (pair? (car hs))
                (let ((k (car (car hs)))) (equal? (if (symbol? k) (symbol->string k) k) key)))
           (loop (cdr hs) (car hs)))
          (else (loop (cdr hs) found)))))

(define (minibuffer--opt-value handlers key)
  (let ((e (minibuffer--opt handlers key)))
    (if (and e (pair? (cdr e))) (cadr e) #f)))

;; the frame's VIEW of a prompt: what its render walk draws and how its
;; list matches. A path prompt (one that completes) matches the segment
;; after the last "/"; a provider that ranks its own rows matches nothing.
;; One pass over HANDLERS answers (VIEW . RECORD); a later entry for a key
;; wins, as it always has.
(define (minibuffer--split handlers)
  (let loop ((hs handlers) (input "") (complete #f) (unfiltered #f) (view '())
             (confirm #f) (cancel #f) (change #f) (collect #f))
    (if (null? hs)
        (cons (cons (list 'input input)
                    (cons (list 'completing (if complete #t #f))
                          (cons (list 'query (cond (unfiltered 'none) (complete 'segment) (else 'input)))
                                (reverse view))))
              (list 'confirm confirm 'cancel cancel 'complete complete 'change change 'collect collect))
        (let* ((e (car hs))
               (k (and (pair? e) (pair? (cdr e)) (car e)))
               (k (if (symbol? k) (symbol->string k) k))
               (v (and k (cadr e)))
               (rest (cdr hs)))
          (cond ((not k) (loop rest input complete unfiltered view confirm cancel change collect))
                ((equal? k "initial") (loop rest (or v "") complete unfiltered view confirm cancel change collect))
                ((equal? k "complete") (loop rest input v unfiltered view confirm cancel change collect))
                ((equal? k "filter") (loop rest input complete (not v) view confirm cancel change collect))
                ((equal? k "confirm") (loop rest input complete unfiltered view v cancel change collect))
                ((equal? k "cancel") (loop rest input complete unfiltered view confirm v change collect))
                ((equal? k "change") (loop rest input complete unfiltered view confirm cancel v collect))
                ((equal? k "collect") (loop rest input complete unfiltered view confirm cancel change v))
                ((member k '("match-hint" "completion-style" "preselect" "style" "note" "legend" "selected" "html"))
                 (loop rest input complete unfiltered (cons (list (string->symbol k) v) view)
                       confirm cancel change collect))
                (else (loop rest input complete unfiltered view confirm cancel change collect)))))))

;; close the prompt: the record first, then the snapshot. Answer (RECORD
;; . FACTS), FACTS as minibuffer--hide! gives them, or #f with no prompt.
;; The record goes before any handler runs, because a handler may open the
;; next prompt.
(define (minibuffer--close!)
  (let* ((rec (minibuffer--record))
         (facts (minibuffer--hide!)))
    (when facts
      (let ((buf (minibuffer-buffer)))
        (when (buffer-exists? buf) (buffer-set-local! buf 'minibuffer-prompt #f))))
    (and facts (cons rec facts))))

(define (minibuffer-read* prompt cands handlers)
  (when (minibuffer-active?)
    (minibuffer-cancel!)
    (message "Quit the outer prompt"))
  ;; A deferred list draw belongs to this prompt only.
  (set! *mb-list-flush* #f)
  ;; a rail belongs to one prompt: the next one starts without it
  (mb-rail-reset!)
  (let ((split (minibuffer--split handlers)))
    (minibuffer--show! prompt cands (car split))
    ;; the frame's prompt buffer exists once a prompt has opened in it
    (let ((buf (minibuffer-mode-ensure!)))
      (buffer-set-local! buf 'minibuffer-prompt (cdr split))
      #t)))

;; No name starts with a space, so SPC on an empty prompt is a leader: the
;; next key runs as its Meta key, SPC SPC picks the row; after typed text
;; it is a space, a separator in the filter.
(define-command "minibuffer-space" "On an empty prompt, wait for a key and run it with Meta; else type a space"
  (lambda ()
    ;; no input starts with a space, so on an empty prompt SPC is a
    ;; leader: SPC b is M-b, SPC SPC picks the row
    (if (equal? (minibuffer-input) "")
        (begin (capture-key! "minibuffer-leader")
               (message "SPC-"))
        (run-command "self-insert-command")))
  'modes '(minibuffer-mode))

(define-command "minibuffer-leader" "Run the key typed after SPC as its Meta key"
  (lambda ()
    (let* ((ks (last-keys))
           (k (cond ((pair? ks) (car (reverse ks)))
                    ((string? ks) (car (reverse (string-split ks " "))))
                    (else "")))
           (meta (key-binding-dispatch (list (string-append "M-" k))))
           (own (key-binding-dispatch (list k))))
      (message "")
      (cond ((member k '("C-g" "ESC")) #f)
            ((equal? k "SPC") (run-command "minibuffer-confirm"))
            ((and *mb-leader-fn* (*mb-leader-fn* k)) #t)
            ((and (pair? meta) (equal? (car meta) "command")) (run-command (cadr meta)))
            ((and (pair? own) (equal? (car own) "command")) (run-command (cadr own)))
            (else #f))))
  'modes '(minibuffer-mode))

;; RET in a path prompt (find-file) means the HIGHLIGHTED candidate
;; whenever one exists (vertico), resolved through the completion handler.
;; The typed input wins when nothing matches (that is how a new file is
;; made), or when the prompt itself holds the selection (a directory input
;; nobody arrowed away from). M-RET always takes the input as typed.
(define (minibuffer--confirm-value rec facts)
  (let ((input (plist-get facts 'input))
        (selected (plist-get facts 'selected))
        (complete (plist-get rec 'complete)))
    (cond ((procedure? complete)
           (if (and selected (not (plist-get facts 'prompt-sel)))
               (let ((r (complete input selected)))
                 (if (and (pair? r) (string? (car r))) (car r) input))
               input))
          (else (or selected input)))))

(define (minibuffer-confirm!)
  (let ((c (minibuffer--close!)))
    (when c
      (let ((confirm (plist-get (car c) 'confirm)))
        (when (procedure? confirm)
          (confirm (minibuffer--confirm-value (car c) (cdr c))))))))

(define (minibuffer-confirm-input!)
  (let ((c (minibuffer--close!)))
    (when c
      (let ((confirm (plist-get (car c) 'confirm)))
        (when (procedure? confirm)
          (confirm (plist-get (cdr c) 'input)))))))

(define (minibuffer-cancel!)
  (let ((c (minibuffer--close!)))
    (when c
      (let ((cancel (plist-get (car c) 'cancel)))
        (when (procedure? cancel) (cancel)))))
  (set-echo! "Quit"))

;; close the prompt WITHOUT running any handler, and hand the caller all
;; the prompt was: the rows that survive the input, and the handlers
;; themselves. The caller adopts them, so the prompt goes on as a buffer
;; (embark-collect). The one way out that neither confirms nor cancels.
(define (minibuffer-detach!)
  (let* ((rows (minibuffer--filtered))
         (c (minibuffer--close!)))
    (and c
         (let ((rec (car c)) (facts (cdr c))
               (h (lambda (rec k) (or (plist-get rec k) #f))))
           (list (list 'prompt (plist-get facts 'prompt))
                 (list 'input (plist-get facts 'input))
                 (list 'candidates rows)
                 (list 'confirm (h rec 'confirm))
                 (list 'cancel (h rec 'cancel))
                 (list 'complete (h rec 'complete))
                 (list 'collect (h rec 'collect)))))))

;; TAB: the prompt's own completion, else the selection into the input
(define (minibuffer-complete!)
  (let ((facts (minibuffer--facts)))
    (when facts
      (let ((complete (minibuffer--handler 'complete)))
        (if complete
            (let* ((selected (and (plist-get facts 'touched) (plist-get facts 'selected)))
                   (r (complete (plist-get facts 'input) (or selected #f))))
              (when (and (pair? r) (string? (car r)) (pair? (cdr r)) (list? (cadr r)))
                (minibuffer-input! (car r))
                (minibuffer-set-candidates! (cadr r))))
            (let ((label (plist-get facts 'selected)))
              (when label (minibuffer-input! label))))))))

;; the prompt holds the selection (a directory input): the first move
;; down takes it to the first candidate, it does not skip one
(define (minibuffer--step! delta)
  (let ((facts (minibuffer--facts)))
    (when facts
      (minibuffer--move!
        (if (and (> delta 0) (plist-get facts 'prompt-sel)) (- delta 1) delta)))))

(define (minibuffer-next!) (minibuffer--step! 1))
(define (minibuffer-prev!) (minibuffer--step! -1))

;; DEL: in a path prompt at a directory boundary, kill the whole component
;; (vertico-directory); otherwise one char back at point
(define (minibuffer-del!)
  (let* ((buf (minibuffer-buffer))
         (input (buffer-text buf))
         (trimmed (re-replace "[^/]+/$" input "")))
    (if (and (minibuffer--handler 'complete)
             (not (equal? trimmed input))
             (string-suffix? "/" input))
        (minibuffer-input! trimmed)
        (with-current-buffer buf (lambda () (delete-char! -1))))))

;; a browser prompt does not pass through the key loop, whose edits fire
;; the change handler; this sets the input and fires it the same way
(define (minibuffer-change! input)
  (minibuffer-input! input)
  (let ((change (and (minibuffer--facts) (minibuffer--handler 'change))))
    (when change (change input))))

;; after a minibuffer key: the change handler runs when the input changed
(define (minibuffer-sync-input!)
  (let ((input (minibuffer--sync!)))
    (when input
      (let ((change (minibuffer--handler 'change)))
        (when change (change input))))))

;; a frame that goes takes its prompt with it, and the prompt's cancel
;; handler runs, so what the prompt displaced comes back
(define (delete-frame! &optional id)
  (let* ((fid (or id (selected-frame)))
         (cancel (ignore-errors
                   (lambda ()
                     (with-selected-frame fid
                       (lambda () (and (minibuffer--facts) (minibuffer--handler 'cancel)))))))
         (r (if id (raw-delete-frame! id) (raw-delete-frame!))))
    (when (and r (procedure? cancel)) (cancel))
    r))

;;; --- the completion popup -------------------------------------------------------
;;; The frame keeps the popup's rows and where its text starts; what a key
;;; does to it is here.

;; close the popup; (START END LABEL) of the selection, END as of now
(define (completion-accept!)
  (let ((r (completion--accept!)))
    (and r (list (car r) (+ (point) (cadr r)) (caddr r)))))

;; narrow the popup to the text between its start and point; at or before
;; the start there is nothing to complete
(define (completion-requery!)
  (let ((start (completion--start)))
    (when start
      (let ((pt (point)))
        (if (> pt start)
            (completion-query! (buffer-substring start pt))
            (completion-dismiss!))))))

;; one interaction model: a completion prompt is the BOTTOM bar, like
;; Emacs — the candidates sit above the input and the input sits on the
;; last row. Only a prompt that asks for "palette" by name floats: the
;; switcher, the command palette, and the LLM config menus.
;;
;; the builtin reads (prompt cands confirm) or (prompt cands complete
;; confirm); this wrapper keeps both shapes
(define (minibuffer-read prompt cands a &optional b)
  (minibuffer-read* prompt cands
    (append
      (list (list 'confirm (if b b a)))
      (if b (list (list 'complete a)) '())
      (list (list 'style #f)))))

;;; --- completing-read ----------------------------------------------------------
;;; Emacs's completing-read, asynchronous: K gets the choice. COLLECTION is
;;; a list of candidates (strings or (label hint) rows) or a procedure of
;;; the input that answers the rows. OPTS is a plist:
;;;   'predicate FN       keep the candidates FN accepts
;;;   'require-match #t   RET takes a candidate only; free text says [No match]
;;;   'initial TEXT       the input to start with
;;;   'default TEXT       the answer to an empty input, listed first
;;;   'history SYM        the history to read and to push the choice on
;;;   'category SYM       the marginalia annotator to use
;;;   'style SYM          how the input matches: flex, substring, prefix, regexp
;;;   'annotate? #f       the rows are annotated already

(define *mb-history-key* #f)          ; the history the active prompt walks
(define *mb-history-pos* -1)          ; -1 is the input, 0 the newest item
(define *mb-history-input* "")        ; what was typed before M-p

(define (completing-read--rows collection input)
  (if (procedure? collection) (collection input) collection))

(define (completing-read--label row) (if (pair? row) (car row) row))

(define (completing-read--prepare rows opts)
  (let* ((pred (plist-get opts 'predicate))
         (kept (if pred (filter (lambda (r) (pred (completing-read--label r))) rows) rows))
         (default (plist-get opts 'default))
         (led (if (and default (member default (map completing-read--label kept)))
                  (cons (let loop ((rs kept))
                          (if (equal? (completing-read--label (car rs)) default) (car rs) (loop (cdr rs))))
                        (filter (lambda (r) (not (equal? (completing-read--label r) default))) kept))
                  kept))
         (hist (plist-get opts 'history))
         (ordered (if (and hist (not (pair? (car (or (and (pair? led) led) '("")))))) (history-order hist led) led))
         (category (plist-get opts 'category)))
    (if (and category (not (equal? (plist-get opts 'annotate?) #f)))
        (annotate category ordered)
        ordered)))

(define (completing-read prompt collection k &rest opts)
  (let* ((hist (plist-get opts 'history))
         (default (plist-get opts 'default))
         (require? (plist-get opts 'require-match))
         (rows (completing-read--prepare (completing-read--rows collection "") opts))
         (labels (lambda () (map completing-read--label
                                (completing-read--prepare
                                  (completing-read--rows collection (minibuffer-input)) opts))))
         (confirm
           (lambda (v)
             (let ((v (if (and default (equal? v "")) default v)))
               (cond ((and require? (not (member v (labels))))
                      (message "[No match]")
                      (apply completing-read (append (list prompt collection k) opts)))
                     (else
                       (when hist (history-push! hist v))
                       (set! *mb-history-key* #f)
                       (k v)))))))
    (set! *mb-history-key* hist)
    (set! *mb-history-pos* -1)
    (minibuffer-read* prompt rows
      (append
        (list (list 'confirm confirm)
              (list 'cancel (lambda () (set! *mb-history-key* #f))))
        (if (procedure? collection)
            (list (list 'change
                        (lambda (input)
                          (minibuffer-set-candidates!
                            (completing-read--prepare (collection input) opts)))))
            '())
        (if (plist-get opts 'initial) (list (list 'initial (plist-get opts 'initial))) '())
        (if (plist-get opts 'style) (list (list 'completion-style (plist-get opts 'style))) '())
        (list (list 'style #f))))))

;; the Emacs readers, each a completing-read of one kind
(define (read-string prompt k &rest opts)
  (apply completing-read (append (list prompt '() k) opts)))

;; the history ring: M-p walks back through what this prompt was answered
;; with, M-n forward, and past the newest the input comes back
(define (minibuffer-history-step! delta)
  (let ((items (if *mb-history-key* (history-items *mb-history-key*) '())))
    (cond ((null? items) (message "End of history; no default available"))
          (else
            (when (= *mb-history-pos* -1) (set! *mb-history-input* (minibuffer-input)))
            (let ((next (+ *mb-history-pos* delta)))
              (cond ((< next -1) (message "End of history; no default available"))
                    ((>= next (length items)) (message "End of history; no default available"))
                    (else
                      (set! *mb-history-pos* next)
                      (minibuffer-input!
                        (if (= next -1) *mb-history-input* (nth next items))))))))))

(define-command "previous-history-element" "Put the previous history item in the minibuffer"
  (lambda () (minibuffer-history-step! 1)))
(define-command "next-history-element" "Put the next history item in the minibuffer"
  (lambda () (minibuffer-history-step! -1)))

;; y-or-n?: a question that takes ONE key. "y" runs YES, "n" and C-g
;; run NO, and any other key clears the input, so the question stands
;; until it gets an answer. A question is not a completion prompt: it
;; offers no candidates, so it stays on the bottom bar and it never
;; grows a palette of two words.
;; (read-char-choice PROMPT CHARS K): one key from CHARS, a list of
;; one-character strings; K gets the character. Any other key asks again.
;; C-g cancels and K gets #f.
;; (read-char PROMPT K): the next key, whatever it is; K gets the
;; character, or #f on C-g. A register name is read this way.
(define (read-char prompt k)
  (let ((answer (lambda (ch) (minibuffer-detach!) (k ch))))
    (minibuffer-read* prompt '()
      (list (list 'change
              (lambda (input)
                (when (> (string-length input) 0)
                  (answer (substring input (- (string-length input) 1)
                                     (string-length input))))))
            (list 'confirm (lambda (v) (answer (if (equal? v "") "RET" v))))
            (list 'cancel (lambda () (k #f)))
            (list 'style "question")))))

(define (read-char-choice prompt chars k)
  (let ((answer (lambda (ch) (minibuffer-detach!) (k ch))))
    (minibuffer-read* prompt '()
      (list (list 'change
              (lambda (input)
                (let ((ch (if (> (string-length input) 0)
                              (substring input (- (string-length input) 1) (string-length input))
                              "")))
                  (if (member ch chars)
                      (answer ch)
                      (minibuffer-input! "")))))
            (list 'confirm (lambda (v) (read-char-choice prompt chars k)))
            (list 'cancel (lambda () (k #f)))
            (list 'style "question")))))

;; the Emacs names: K gets #t or #f
(define (y-or-n? prompt k)
  (y-or-n prompt (lambda () (k #t)) (lambda () (k #f))))

;; a question that takes the word: "yes" or "no", RET after it
(define (yes-or-no? prompt k)
  (minibuffer-read* (string-append prompt " (yes or no) ") '()
    (list (list 'confirm
            (lambda (v)
              (cond ((equal? v "yes") (k #t))
                    ((equal? v "no") (k #f))
                    (else (message "Please answer yes or no.")
                          (yes-or-no? prompt k)))))
          (list 'cancel (lambda () (k #f)))
          (list 'style "question"))))

(define (y-or-n prompt yes &optional no)
  (let* ((no (if no no (lambda () #f)))
         ;; the prompt closes BEFORE the answer runs: an answer may ask
         ;; the next question, and two prompts cannot share the bar
         (answer (lambda (k) (lambda () (minibuffer-detach!) (k)))))
    (minibuffer-read* (string-append prompt " (y or n) ") '()
      (list (list 'change
              (lambda (input)
                (cond ((string-suffix? "y" input) ((answer yes)))
                      ((string-suffix? "n" input) ((answer no)))
                      (else (minibuffer-input! "")))))
            ;; RET is not an answer: a question takes y or n and nothing
            ;; else, so RET asks it again. C-g is the way out, and it
            ;; means no.
            (list 'confirm (lambda (v) (y-or-n prompt yes no)))
            (list 'cancel no)
            (list 'style "question")))))

;; MATCH-HINT also matches what you type against the marginalia beside
;; each candidate: #t means the first field, an integer N the first N.
;; STYLE picks the presentation; unset, the palette rule decides.
;; COMPLETE, when given, runs on TAB with (INPUT SELECTED) and can
;; answer (list NEW-INPUT CANDIDATES) to replace the pool.
;; COLLECT, when given, receives the candidate rows left after narrowing.
(define *mb-shortcuts* '())

(define (mb-candidate-name cand)
  (if (pair? cand) (car cand) cand))

(define (mb-shortcut-command key)
  (let ((name (string-append "minibuffer--shortcut-" key)))
    (define-command name (string-append "Choose minibuffer shortcut M-" key)
      (lambda ()
        (let ((hit (assoc key *mb-shortcuts*)))
          (cond (hit ((car (cdr hit))))
                ((equal? key "g") (run-command "minibuffer-regroup"))
                ((equal? key "p") (run-command "minibuffer-previous-section"))
                ((equal? key "n") (run-command "minibuffer-next-section"))
                (else #f)))))
    name))

(define (mb-preview-shortcut-rows cands declared)
  (if declared
    declared
    ;; a heading is not a choice, so it takes no number
    (let loop ((xs (filter (lambda (c) (not (and (pair? c) (> (length c) 2)
                                                 (equal? (nth 2 c) "separator"))))
                           cands))
               (n 1) (out '()))
      (if (or (null? xs) (> n 9))
        (reverse out)
        (loop (cdr xs) (+ n 1)
              (cons (list (number->string n)
                          (mb-candidate-name (car xs)))
                    out))))))

;; swap the open preview prompt's candidates; the M-1..M-9 shortcuts
;; follow them, and the preview follows the new selection
(define (minibuffer-preview-candidates! cands on-confirm &optional shortcuts)
  (let ((rows (mb-preview-shortcut-rows cands shortcuts)))
    (set! *mb-shortcuts* (mb-preview-shortcuts rows on-confirm))
    (minibuffer-set-candidates! (mb-preview-shortcut-hint cands rows))
    (mb-select-notify!)))

(define (mb-preview-shortcuts rows on-confirm)
  (map (lambda (row)
         (let ((key (car row)) (value (car (cdr row))))
           (list key
                 (lambda ()
                   (set! *mb-shortcuts* '())
                   (minibuffer-cancel!)
                   (with-invoking-buffer (lambda () (on-confirm value)))))))
       rows))

(define (mb-preview-shortcut-hint cands shortcuts)
  (map (lambda (cand)
         (let* ((name (mb-candidate-name cand))
                (hit (let loop ((xs shortcuts))
                       (cond ((null? xs) #f)
                             ((equal? name (car (cdr (car xs)))) (car (car xs)))
                             (else (loop (cdr xs)))))))
           ;; the key goes last: a prompt that matches on its annotation
           ;; reads the first fields as kinds, and the mode must stay first
           (if (and hit (pair? cand))
             ;; the rest of the candidate, its kind and facts, stays as it was
             (cons name (cons (string-append (if (pair? (cdr cand)) (car (cdr cand)) "") "  M-" hit)
                              (if (pair? (cdr cand)) (cdr (cdr cand)) '())))
             cand)))
       cands))

(define (minibuffer-read-preview prompt cands on-select on-confirm on-cancel
                                 &optional match-hint style complete collect shortcuts selected html)
  ;; the outer prompt's cancel handler clears *mb-select-fn*, so let it run
  ;; BEFORE this prompt installs its own. minibuffer-read* would quit the
  ;; outer prompt for us, but by then the new hook is already in place and
  ;; the old prompt's teardown takes it away: the new prompt opens with no
  ;; preview and no rail, which is the bug this line prevents.
  (when (minibuffer-active?)
    (minibuffer-cancel!)
    (message "Quit the outer prompt"))
  (let* ((rows (mb-preview-shortcut-rows cands shortcuts))
         (bindings (mb-preview-shortcuts rows on-confirm)))
    (set! *mb-shortcuts* bindings)
    (set! *mb-tab-fn* #f) (set! *mb-leader-fn* #f)
    (set! *mb-fold-fn* #f)
    (set! *mb-change-fn* #f)
    (set! *mb-select-fn* (lambda (sel) (with-invoking-buffer (lambda () (on-select sel)))))
    (minibuffer-read* prompt (mb-preview-shortcut-hint cands rows)
      (append
        (list (list 'confirm (lambda (v)
                                (set! *mb-shortcuts* '())
                                (set! *mb-select-fn* #f)
                                (set! *mb-tab-fn* #f) (set! *mb-leader-fn* #f)
                                (set! *mb-fold-fn* #f)
                                (set! *mb-change-fn* #f)
                                (with-invoking-buffer (lambda () (on-confirm v)))))
              (list 'cancel  (lambda ()
                                (set! *mb-shortcuts* '())
                                (set! *mb-select-fn* #f)
                                (set! *mb-tab-fn* #f) (set! *mb-leader-fn* #f)
                                (set! *mb-fold-fn* #f)
                                (set! *mb-change-fn* #f)
                                (with-invoking-buffer on-cancel)))
              (list 'change  (lambda (input) (when *mb-change-fn* (*mb-change-fn* input)) (mb-select-notify!)))
              (list 'match-hint (if match-hint match-hint #f))
              (list 'style style))
        (if complete (list (list 'complete complete)) '())
        (if collect (list (list 'collect collect)) '())
        ;; SELECTED is the label of the row the prompt opens on
        (if selected (list (list 'selected selected)) '())
        ;; HTML is drawn over the rows; see minibuffer-read*
        (if html (list (list 'html html)) '())))))

;;; --- minibuffer-mode ---------------------------------------------------------
;;; The prompt's input is a buffer, because typing, DEL, yank and undo are
;;; a buffer's own work. It is not a buffer of the buffer world: nothing
;;; reads it, dismisses it, or saves it. That difference is a major mode,
;;; so every rule about prompts asks the mode instead of matching the
;;; name — and the prompt's keys are the mode's map, so every frame's
;;; prompt has them, not only the frame that was up when this file loaded.
(define-mode "minibuffer-mode"
  (lambda ()
    ;; A prompt is input, never a reading surface. The read-only flag —
    ;; and the q dismissal and Reading bar that follow it — belongs to
    ;; the buffers you look at. A mode setup that runs while a prompt is
    ;; up sees the prompt as the current buffer, and that is how the flag
    ;; arrived there at all.
    (buffer-set-read-only! (current-buffer) #f)))

(mode-doc! "minibuffer-mode"
  "The buffer behind a prompt. It holds what you type and nothing else: no read-only flag, no dismissal, no reading surface.")

(mode-keys! "minibuffer-mode"
  '(("RET" "minibuffer-confirm")
    ("SPC" "minibuffer-space")
    ("M-RET" "minibuffer-confirm-input")
    ("C-g" "minibuffer-cancel")
    ("TAB" "minibuffer-complete")
    ("C-n" "minibuffer-next-candidate")
    ("<down>" "minibuffer-next-candidate")
    ("C-p" "minibuffer-previous-candidate")
    ("<up>" "minibuffer-previous-candidate")
    ;; the palette's two lists: <right> steps into the one on the right,
    ;; <left> steps back. With no rail they are point motion.
    ("<right>" "minibuffer-rail-enter")
    ("<left>" "minibuffer-rail-exit")
    ;; with no shortcut, these keep their section-navigation behavior
    ("M-p" "minibuffer-previous-section")
    ("M-n" "minibuffer-next-section")
    ("M-<up>" "minibuffer-previous-section")
    ("M-<down>" "minibuffer-next-section")
    ("M-g" "minibuffer-regroup")
    ;; a search repeats from inside its own prompt
    ("C-s" "isearch-repeat-forward")
    ("C-r" "isearch-repeat-backward")
    ;; the prompt continues as a buffer — see minibuffer-collect
    ("C-c C-o" "minibuffer-collect")
    ;; the same prompt as the bar, panel, or modal while it is up
    ("C-c C-t" "minibuffer-cycle-shape")
    ("DEL" "minibuffer-delete-backward")
    ("<delete>" "minibuffer-delete-row")))

(for-each
  (lambda (key)
    (define-key "minibuffer-mode-map" (string-append "M-" key)
      (mb-shortcut-command key)))
  '("0" "1" "2" "3" "4" "5" "6" "7" "8" "9"
    "a" "b" "c" "d" "e" "f" "g" "h" "i" "j"
    "k" "l" "m" "n" "o" "p" "q" "r" "s" "t"
    "u" "v" "w" "x" "y" "z"))

(define (minibuffer-buffer? buf)
  (if (and buf (buffer-known? buf) (buffer-derived-mode? buf "minibuffer-mode")) #t #f))

;; Every frame makes its own prompt buffer, on its first prompt. The mode
;; goes on there rather than at load: a frame opened later is a prompt too.
(define (minibuffer-mode-ensure! &optional buf)
  (let ((buf (or buf (minibuffer-buffer))))
    (when (and buf (buffer-exists? buf) (not (minibuffer-buffer? buf)))
      (with-current-buffer buf (lambda () (set-mode! "minibuffer-mode"))))
    buf))

;;; --- minibuffer history (vertico-style: last-used first) --------------------
;;; The candidate ranking in the core is a stable sort, so passing
;;; candidates history-first keeps them first among equal matches — the
;;; empty prompt shows pure recency, typing re-ranks fuzzily within it.

(defvar '*minibuffer-history* '() 'persist #t)  ; ((key (item ...)) ...), most recent first
(define *minibuffer-history-max* 50)

;; savehist: which commands, themes and searches you use is worth more
;; than one session. Every keyed history rides in this one variable, so
;; M-x, apropos, project, ripgrep and the theme prompt all persist here.
(define (history-items key)
  (let ((e (assoc key *minibuffer-history*)))
    (if e (cadr e) '())))

(define (history-push! key item)
  (let ((items (cons item (filter (lambda (x) (not (equal? x item)))
                                  (history-items key)))))
    (set! *minibuffer-history* (alist-put *minibuffer-history* key (take items *minibuffer-history-max*)))))

;; forget one entry, as if it had never been chosen
(define (history-remove! key item)
  (set! *minibuffer-history*
        (alist-put *minibuffer-history* key
                   (filter (lambda (x) (not (equal? x item))) (history-items key)))))

;; reorder candidates so remembered ones lead, in recency order
(define (history-order key candidates)
  (let ((hist (filter (lambda (h) (member h candidates)) (history-items key))))
    (append hist (filter (lambda (c) (not (member c hist))) candidates))))

;;; --- the public API ----------------------------------------------------------

(category! 'interaction)
(public! 'minibuffer-read "(minibuffer-read PROMPT CANDIDATES HANDLER) — async; HANDLER gets the choice")
(public! 'y-or-n "(y-or-n PROMPT YES &optional NO) — a one-key question; y runs YES, n and C-g run NO")
(catalog-meta! 'function "y-or-n" 'domain 'interaction 'effects '(read))
(public! 'minibuffer-read-preview "(minibuffer-read-preview PROMPT CANDIDATES ON-SELECT ON-CONFIRM ON-CANCEL &optional MATCH-HINT STYLE COMPLETE COLLECT SHORTCUTS SELECTED HTML) — preview candidates; SHORTCUTS maps keys to candidate names, otherwise M-1..M-9 choose by position; HTML is drawn over the rows")
(public! 'minibuffer-buffer? "(minibuffer-buffer? BUF) — whether BUF is a prompt's input buffer, i.e. in minibuffer-mode")
(public! 'minibuffer-mode-ensure! "(minibuffer-mode-ensure! &optional BUF) — put minibuffer-mode on this frame's prompt buffer; answers the buffer")

(category! 'commands)
(public! 'read-char "(read-char PROMPT K) — the next key; K gets the character, or #f on C-g")
(public! 'completing-read "(completing-read PROMPT COLLECTION K 'predicate FN 'require-match #t 'initial TEXT 'default TEXT 'history SYM 'category SYM 'style SYM) — Emacs's completing-read, asynchronous: K gets the choice. COLLECTION is rows or a procedure of the input")
(public! 'read-char-choice "(read-char-choice PROMPT CHARS K) — one key from CHARS; K gets it, or #f on C-g")
(public! 'y-or-n? "(y-or-n? PROMPT K) — one key; K gets #t for y, #f for n or C-g")
(public! 'yes-or-no? "(yes-or-no? PROMPT K) — the word yes or no; K gets #t or #f")
(public! 'minibuffer-active? "(minibuffer-active?) — #t while a prompt is up")
(public! 'minibuffer-read* "(minibuffer-read* PROMPT CANDIDATES HANDLERS) — activate the minibuffer with a handler alist: confirm, cancel, complete, change, collect, initial, filter, match-hint, completion-style, preselect, selected (the label of the row it opens on), style (\"palette\" floats), note (the palette rail's footer line), legend (((KEY LABEL) ...) for the palette head), html (markup drawn over the rows, as it is; an element with data-pick=LABEL picks that row on a click and wears .selected while the highlight is on it). A candidate is LABEL, (LABEL HINT), (LABEL HINT KIND), (LABEL HINT KIND CHIPS [FACE]), or (LABEL HINT KIND CHIPS FACE FACTS) where FACTS is ((KEY VALUE) ...) for the palette rail.")
(public! 'minibuffer-input "(minibuffer-input) — what the open prompt holds, \"\" without one")
(public! 'minibuffer-confirm! "(minibuffer-confirm!) — close the prompt; run its confirm handler with the value.")
;; a click on the prompt's own HTML: move the highlight to the row LABEL
;; and take it as RET would. #f when the open prompt shows no such row.
(define (minibuffer-pick! label)
  ;; the highlight skips separator rows, so walk it one row at a time
  ;; toward LABEL instead of counting rows
  (let* ((labels (map (lambda (r) (if (pair? r) (car r) r)) (or (prompt--do 'filtered) '())))
         (at (lambda (x) (let loop ((ls labels) (i 0))
                           (cond ((null? ls) #f) ((equal? (car ls) x) i) (else (loop (cdr ls) (+ i 1)))))))
         (want (at label))
         (now (at (minibuffer-selected))))
    (and want now
         (let ((step (if (< want now) -1 1)))
           (let walk ((n (length labels)))
             (cond ((equal? (minibuffer-selected) label) (minibuffer-confirm!) #t)
                   ((= n 0) #f)
                   (else (prompt--do 'move step) (walk (- n 1)))))))))
(public! 'minibuffer-pick! "(minibuffer-pick! LABEL) — highlight the row LABEL of the open prompt and take it as RET would; #f when it shows no such row")
(public! 'minibuffer-confirm-input! "(minibuffer-confirm-input!) — close the prompt; submit the input, not the candidate.")
(public! 'minibuffer-cancel! "(minibuffer-cancel!) — close the prompt; run its cancel handler; echo Quit.")
(public! 'minibuffer-detach! "(minibuffer-detach!) — close the prompt; return its state and closures, or #f.")
(public! 'minibuffer-complete! "(minibuffer-complete!) — run the prompt's completion, or copy the selection to the input.")
(public! 'minibuffer-next! "(minibuffer-next!) — move the candidate selection down one.")
(public! 'minibuffer-prev! "(minibuffer-prev!) — move the candidate selection up one.")
(public! 'minibuffer-del! "(minibuffer-del!) — delete one char back; at a directory boundary, delete the component.")
(public! 'minibuffer-change! "(minibuffer-change! INPUT) — set minibuffer input and run its live change handler.")
(public! 'minibuffer-sync-input! "(minibuffer-sync-input!) — after a minibuffer key, run the prompt's change handler when its input changed.")
(public! 'delete-frame! "(delete-frame! [ID]) — delete the frame and run its prompt's cancel handler.")
(public! 'completion-accept! "(completion-accept!) — close the popup; return (START END LABEL) of the selection, END as of now, or #f.")
(public! 'completion-requery! "(completion-requery!) — narrow the popup to the text between its start and point.")

;; effects stamps for the names declared above without one, so
;; eval-scheme-read takes or refuses them by what they do
(for-each (lambda (n) (catalog-meta! 'function (symbol->string n) 'effects '(read)))
  '(minibuffer-active? minibuffer-buffer? minibuffer-input))
(for-each (lambda (n) (catalog-meta! 'function (symbol->string n) 'effects '(destroy display)))
  '(delete-frame!))
(for-each (lambda (n) (catalog-meta! 'function (symbol->string n) 'effects '(write display)))
  '(completing-read yes-or-no? y-or-n? read-char read-char-choice
    minibuffer-read minibuffer-read* minibuffer-read-preview
    completion-accept! completion-requery! minibuffer-cancel!
    minibuffer-change! minibuffer-complete! minibuffer-confirm!
    minibuffer-confirm-input! minibuffer-del! minibuffer-detach!
    minibuffer-next! minibuffer-prev! minibuffer-sync-input!))
(for-each (lambda (n) (catalog-meta! 'function (symbol->string n) 'effects '(write)))
  '(minibuffer-mode-ensure!))
