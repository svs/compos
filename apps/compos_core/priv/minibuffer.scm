;;; minibuffer.scm --- the prompt: its buffer, its shapes, its lists.
;;;
;;; Everything a prompt does in Scheme: the rail and the tabs, the three
;;; shapes and the dock, candidate preview, completing-read, the one-key
;;; questions, minibuffer-mode and the history. The core keeps the input,
;;; the candidate list and the matching (Candidates); this file says what
;;; the keys mean. editor.scm requires it at its end, so every name the
;;; forms below call at load is bound by then.

(domain! 'interaction)
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

;; a prompt whose rows nest folds them with TAB: the fn gets the selected
;; candidate and answers #t when it took the key
(define *mb-fold-fn* #f)

;; a preview prompt that redraws its rows as the input changes: the fn gets the input
(define *mb-change-fn* #f)

(define (mb-tab-step! step)
  (and *mb-tab-fn* (minibuffer-active?) (*mb-tab-fn* step)))

(define-command "minibuffer-rail-enter"
  "Move the arrows into the list on the right of the palette, or to the next tab"
  (lambda () (cond ((mb-rail-enter!) #t) ((mb-tab-step! 1) #t) (else (run-command "forward-char")))))
(define-command "minibuffer-rail-exit"
  "Leave the list on the right and go back to the candidates, or to the previous tab"
  (lambda () (cond ((mb-rail-exit!) #t) ((mb-tab-step! -1) #t) (else (run-command "backward-char")))))

(define-command "minibuffer-confirm" "Accept the selected minibuffer candidate"
  (lambda () (if (mb-rail-confirm!) #t (minibuffer-confirm!))))
;; RET takes the candidate. C-RET takes the same candidate with a
;; different verb, and the prompt that cares (the buffer switcher)
;; reads and resets the flag:
;;   RET    go there, move nothing else
;;   C-RET  enter the candidate's context, layout and all
(define *mb-confirm-context* #f)
(define-command "minibuffer-confirm-context"
  "Accept the selected candidate as a context (group) switch"
  (lambda () (set! *mb-confirm-context* #t) (minibuffer-confirm!)))
(define-command "minibuffer-confirm-input" "Accept the minibuffer input exactly as typed"
  (lambda () (minibuffer-confirm-input!)))
(define-command "minibuffer-cancel" "Cancel the minibuffer prompt"
  (lambda () (minibuffer-cancel!)))

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
  (and (buffer-known? buf) (buffer-local buf 'window-dock)))

;; A dock is not a work window. Every rule that keeps the float out of
;; the layout keeps a dock out too: the tiler must not count it, fill it,
;; or renumber it away, and a display must never land in it.
(define (window-dock? win buf) (and buf (equal? (window-docked buf) win)))

(define (window-dock! buf size)
  (let ((win (split-root! 'v (- 1 size))))
    (when win
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
                (message next))))))))
(define-command "minibuffer-next-candidate" "Select the next minibuffer candidate"
  (lambda ()
    (cond ((mb-rail-move! 1) #t)
          ((mb-list-move! 1) #t)
          (else (minibuffer-next!) (mb-select-notify!)))))
(define-command "minibuffer-previous-candidate" "Select the previous minibuffer candidate"
  (lambda ()
    (cond ((mb-rail-move! -1) #t)
          ((mb-list-move! -1) #t)
          (else (minibuffer-prev!) (mb-select-notify!)))))
;; A prompt may let its rows be deleted: *mb-row-delete-fn* is a thunk that
;; deletes the highlighted row. <delete> runs it, and DEL does on an empty
;; input, where there is no character to delete.
(define *mb-row-delete-fn* #f)

(define-command "minibuffer-delete-backward" "Delete the character before point, or the highlighted row of an empty prompt that allows it"
  (lambda ()
    (if (and *mb-row-delete-fn* (equal? (minibuffer-input) ""))
        (*mb-row-delete-fn*)
        (minibuffer-del!))))

(define-command "minibuffer-delete-row" "Delete the highlighted row, in a prompt that allows it"
  (lambda ()
    (if *mb-row-delete-fn*
        (*mb-row-delete-fn*)
        (message "Nothing here deletes a row"))))
(define-command "minibuffer-complete"
  "Fold the row or section at hand, else complete the input"
  (lambda ()
    (cond ((and *mb-fold-fn* (minibuffer-selected) (*mb-fold-fn* (minibuffer-selected))) #t)
          ((mb-list-call! 'fold) #t)
          (else (minibuffer-complete!)))))
(define-command "minibuffer-regroup"
  "Cycle what a section is in the list behind the prompt"
  (lambda () (if (mb-list-call! 'regroup) #t (message "no list here"))))
(define-command "minibuffer-next-section"
  "Move to the next section in the list behind the prompt, else the next history entry"
  (lambda ()
    (cond ((and *mb-history-key* (>= *mb-history-pos* 0))
           (run-command "next-history-element"))
          ((mb-list-section! 1) #t)
          (else (run-command "next-history-element")))))
(define-command "minibuffer-previous-section"
  "Move to the previous section in the list behind the prompt, else the previous history entry"
  ;; an empty prompt, or one already walking its history, walks the history
  (lambda ()
    (cond ((and *mb-history-key* (or (>= *mb-history-pos* 0) (equal? (minibuffer-input) "")))
           (run-command "previous-history-element"))
          ((mb-list-section! -1) #t)
          (else (run-command "previous-history-element")))))

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

(define (minibuffer-active?) (if (minibuffer-state) #t #f))

;; what the prompt holds now, "" without a prompt
(define (minibuffer-input)
  (let ((st (minibuffer-state)))
    (if st (plist-get st 'input) "")))

(define (minibuffer-read* prompt cands handlers)
  (when (minibuffer-active?)
    (minibuffer-cancel!)
    (message "Quit the outer prompt"))
  ;; A deferred list draw belongs to this prompt only.
  (set! *mb-list-flush* #f)
  ;; a rail belongs to one prompt: the next one starts without it
  (mb-rail-reset!)
  (let ((r (minibuffer-read*--raw prompt cands handlers)))
    ;; the frame's prompt buffer exists once a prompt has opened in it
    (minibuffer-mode-ensure!)
    r))

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
  (let ((name (string-append "minibuffer-shortcut-" key)))
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
                                 &optional match-hint style complete collect shortcuts selected)
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
    (set! *mb-tab-fn* #f)
    (set! *mb-fold-fn* #f)
    (set! *mb-change-fn* #f)
    (set! *mb-select-fn* (lambda (sel) (with-invoking-buffer (lambda () (on-select sel)))))
    (minibuffer-read* prompt (mb-preview-shortcut-hint cands rows)
      (append
        (list (list 'confirm (lambda (v)
                                (set! *mb-shortcuts* '())
                                (set! *mb-select-fn* #f)
                                (set! *mb-tab-fn* #f)
                                (set! *mb-fold-fn* #f)
                                (set! *mb-change-fn* #f)
                                (with-invoking-buffer (lambda () (on-confirm v)))))
              (list 'cancel  (lambda ()
                                (set! *mb-shortcuts* '())
                                (set! *mb-select-fn* #f)
                                (set! *mb-tab-fn* #f)
                                (set! *mb-fold-fn* #f)
                                (set! *mb-change-fn* #f)
                                (with-invoking-buffer on-cancel)))
              (list 'change  (lambda (input) (when *mb-change-fn* (*mb-change-fn* input)) (mb-select-notify!)))
              (list 'match-hint (if match-hint match-hint #f))
              (list 'style style))
        (if complete (list (list 'complete complete)) '())
        (if collect (list (list 'collect collect)) '())
        ;; SELECTED is the label of the row the prompt opens on
        (if selected (list (list 'selected selected)) '())))))

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
    ("M-RET" "minibuffer-confirm-input")
    ("C-RET" "minibuffer-confirm-context")
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
(public! 'minibuffer-read-preview "(minibuffer-read-preview PROMPT CANDIDATES ON-SELECT ON-CONFIRM ON-CANCEL &optional MATCH-HINT STYLE COMPLETE COLLECT SHORTCUTS) — preview candidates; SHORTCUTS maps keys to candidate names, otherwise M-1..M-9 choose by position")
(public! 'minibuffer-buffer? "(minibuffer-buffer? BUF) — whether BUF is a prompt's input buffer, i.e. in minibuffer-mode")
(public! 'minibuffer-mode-ensure! "(minibuffer-mode-ensure! &optional BUF) — put minibuffer-mode on this frame's prompt buffer; answers the buffer")

(category! 'commands)
(public! 'read-char "(read-char PROMPT K) — the next key; K gets the character, or #f on C-g")
(public! 'completing-read "(completing-read PROMPT COLLECTION K 'predicate FN 'require-match #t 'initial TEXT 'default TEXT 'history SYM 'category SYM 'style SYM) — Emacs's completing-read, asynchronous: K gets the choice. COLLECTION is rows or a procedure of the input")
(public! 'read-char-choice "(read-char-choice PROMPT CHARS K) — one key from CHARS; K gets it, or #f on C-g")
(public! 'y-or-n? "(y-or-n? PROMPT K) — one key; K gets #t for y, #f for n or C-g")
(public! 'yes-or-no? "(yes-or-no? PROMPT K) — the word yes or no; K gets #t or #f")
(public! 'minibuffer-active? "(minibuffer-active?) — #t while a prompt is up")
