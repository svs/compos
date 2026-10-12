;;; content-scale.scm --- Content zoom: a mode declares its levels of detail.
;;;
;;; text-scale changes how big the text looks; content-scale changes how
;;; much of it you see. Level 0 is the buffer as it is. A positive level
;;; reduces it, a negative one expands it into what made it:
;;;
;;;    4  card       a few facts, for a dashboard
;;;    3  summary    the whole buffer as one paragraph
;;;    1  outline    each part folded to its first line
;;;    0  text       the buffer itself
;;;   -1  log        the events behind it
;;;
;;; A mode declares its levels with define-content-scale!. Each level
;;; names one or more reductions:
;;;
;;;   (fold PARTS [MARK])           keep each part's first line, hide the rest
;;;   (elide PARTS)                 hide the parts outright
;;;   (summarize-parts PARTS STYLE) fold each part behind a model summary
;;;   (summarize SOURCE STYLE)      the whole buffer as a summary
;;;   (aggregate FN)                facts about the buffer
;;;   (expand FN)                   what lies under the buffer
;;;
;;; fold, elide and summarize-parts draw in place: folds hide lines and
;;; chrome draws the replacement text, so the bytes never change. The
;;; others fill a companion view buffer, " *scale: NAME*", which takes the
;;; window while the level holds. Its leading space keeps it out of every
;;; buffer list. Only the summaries cost a model call, and every one goes
;;; through the content cache, keyed by the text it summarized.

(domain! 'content-scale)
(effects! '(write display))

(require 'content-cache)

(defgroup 'content-scale "Content zoom: levels of detail a mode declares.")

(defcustom 'content-scale-summary-role 'summarize
  "The llm-models! job that writes content-scale summaries."
  'group 'content-scale 'type 'symbol)

(defcustom 'content-scale-prompt-version 1
  "Bump to make every cached summary stale after a prompt change."
  'group 'content-scale 'type 'number)

(define *content-scale-specs* '())

;;; Declarations

;; LEVELS is a list of (N NAME REDUCTION ...); level 0 needs no entry.
(define (define-content-scale! mode levels)
  (set! *content-scale-specs*
        (cons (list mode (reverse (sort levels)))
              (filter (lambda (s) (not (equal? (car s) mode))) *content-scale-specs*)))
  mode)

;; A mode without its own levels takes its parent's, and "*" ends the walk.
(define (content-scale--spec-for mode)
  (let loop ((m mode) (seen '()))
    (cond ((or (not m) (member m seen))
           (let ((d (assoc "*" *content-scale-specs*))) (if d (cadr d) '())))
          ((assoc m *content-scale-specs*) (cadr (assoc m *content-scale-specs*)))
          (else (loop (mode-parent m) (cons m seen))))))

(define (content-scale-levels buf)
  (content-scale--spec-for (buffer-local buf 'mode-name)))

(define (content-scale--entry buf n)
  (let ((hit (filter (lambda (l) (= (car l) n)) (content-scale-levels buf))))
    (and (pair? hit) (car hit))))

(define (content-scale--level-names buf)
  (cons (list 0 'text) (map (lambda (l) (list (car l) (cadr l))) (content-scale-levels buf))))

(define (content-scale--number buf level)
  (cond ((number? level) level)
        ((string? level) (content-scale--number buf (string->symbol level)))
        (else (let ((hit (filter (lambda (l) (eq? (cadr l) level))
                                 (content-scale--level-names buf))))
                (and (pair? hit) (car (car hit)))))))

;;; Parts: byte ranges (START END) a reduction works on

;; The paragraphs of BUF: runs of non-blank lines, each with its newline.
(define (content-scale-paragraphs buf)
  (let loop ((lines (string-split (buffer-text buf) "\n")) (at 0) (start #f) (acc '()))
    (if (null? lines)
        (reverse (if start (cons (list start at) acc) acc))
        (let* ((line (car lines))
               (next (+ at (string-byte-length line) 1))
               (blank (equal? (string-trim line) "")))
          (cond ((and blank start) (loop (cdr lines) next #f (cons (list start at) acc)))
                (blank (loop (cdr lines) next #f acc))
                (start (loop (cdr lines) next start acc))
                (else (loop (cdr lines) next at acc)))))))

;; A level names its procedures by symbol, so a redefinition takes effect
;; without declaring the levels again.
(define (content-scale--proc x)
  (if (and (symbol? x) (boundp x)) (symbol-value x) x))

(define (content-scale--parts buf parts)
  (if (eq? parts 'paragraphs)
      (content-scale-paragraphs buf)
      (let ((f (content-scale--proc parts)))
        (if (procedure? f) (f buf) '()))))

(define (content-scale-part-text buf part)
  (substring-bytes (buffer-text buf) (car part) (cadr part)))

;; The byte of the newline that ends the line POS is on.
(define (content-scale--line-end buf pos)
  (with-current-buffer buf
    (lambda () (- (line-start-position (+ 1 (line-number-at-pos pos))) 1))))

;;; In-place plans: (FOLDS CHROME), hidden ranges and chrome attachments

;; Keep the part's first line and hide the rest. A line hides when its
;; start falls in (S E], so the range runs from the first newline to the
;; last byte before the part ends.
(define (content-scale--fold-range buf part)
  (let ((fe (content-scale--line-end buf (car part)))
        (last (- (cadr part) 1)))
    (and (< fe last) (list fe last))))

;; Hide the whole part. Line 0 can never hide, so a part there folds.
(define (content-scale--elide-range buf part)
  (if (> (car part) 0)
      (list (- (car part) 1) (- (cadr part) 1))
      (content-scale--fold-range buf part)))

(define (content-scale--mark-text buf mark part)
  (cond ((string? mark) mark)
        ((procedure? (content-scale--proc mark)) ((content-scale--proc mark) buf part))
        (else " …")))

(define (content-scale--fold-plan buf parts mark)
  (let loop ((ps parts) (folds '()) (chrome '()))
    (if (null? ps)
        (list (reverse folds) (reverse chrome))
        (let* ((p (car ps))
               (r (content-scale--fold-range buf p))
               (text (and r (content-scale--mark-text buf mark p))))
          (loop (cdr ps)
                (if r (cons r folds) folds)
                (if (and r (string? text) (not (equal? text "")))
                    (cons (chrome-after (car r) text "dim") chrome)
                    chrome))))))

(define (content-scale--elide-plan buf parts)
  (list (filter (lambda (r) r) (map (lambda (p) (content-scale--elide-range buf p)) parts)) '()))

;;; The summarizer: callable from anywhere, cached by what it summarized

(define *summarize-styles*
  (list (list 'gist "Write one line of at most 15 words that says what this passage is about. No preamble, no quotes.")
        (list 'summary "Summarize this in one short paragraph. Keep names, numbers and decisions. No preamble.")
        (list 'themes "List the broad themes of this, one per line, each as a short title, a colon, and one sentence. Most important first. No preamble.")
        (list 'abstract "Write a two-sentence abstract of this. No preamble.")))

(define (summarize-style! style instruction)
  (set! *summarize-styles*
        (cons (list style instruction)
              (filter (lambda (s) (not (eq? (car s) style))) *summarize-styles*)))
  style)

(define (summarize--instruction style)
  (let ((hit (assq style *summarize-styles*)))
    (cadr (or hit (assq 'summary *summarize-styles*)))))

(define (summarize--key text style)
  (content-key text style (llm-model-for content-scale-summary-role)
               (summarize--instruction style) content-scale-prompt-version))

(define (summary-cached text &optional style)
  (cache-get 'summarize (summarize--key text (or style 'summary))))

;; K gets the summary, or #f when the model failed. The answer is the
;; summary itself when the cache has it, else #f and K runs on arrival.
(define (summarize text &optional style k)
  (let* ((style (or style 'summary))
         (model (llm-model-for content-scale-summary-role)))
    (cache-fetch 'summarize (summarize--key text style)
      (lambda (done)
        (llm-with-model
         (string-append (summarize--instruction style) "\n\n<text>\n" text "\n</text>")
         model
         (lambda (reply) (done (string-trim reply)))
         (lambda (err) (message (format "summarize: ~a" err)) (done #f))))
      (or k (lambda (v) v)))))

(define-command "summarize-selection" "Summarize the selected text into *Summary*"
  (lambda ()
    (let ((text (or (ignore-errors (lambda () (region-text))) "")))
      (if (equal? (string-trim text) "")
          (message "summarize-selection: select some text first")
          (begin
            (message "Summarizing…")
            (summarize text 'summary
                       (lambda (s)
                         (when s
                           (buffer-set-text! "*Summary*" s #t)
                           (display-buffer-other-window! "*Summary*")
                           (message "Summarized")))))))))

;;; Plans: what one level draws. (FOLDS CHROME VIEWS), where VIEWS is a
;;; list of (TEXT LINKS) for the companion buffer and LINKS is a list of
;;; (VIEW-LINE SOURCE-POS) that RET follows back into the source.

(define (content-scale-level buf) (or (buffer-local buf 'content-scale) 0))

(define (content-scale--arrived! buf n)
  (when (and (buffer-known? buf) (= (content-scale-level buf) n))
    (content-scale--apply! buf n)
    (run-hook-with-args 'content-scale-ready-hook buf n)))

(define (content-scale--summary-mark style n)
  (lambda (buf part)
    (let ((text (content-scale-part-text buf part)))
      (or (let ((s (summary-cached text style))) (and s (string-append "  ⟶ " s)))
          (begin (summarize text style (lambda (s) (content-scale--arrived! buf n)))
                 "  ⟶ summarizing…")))))

(define (content-scale--source-text buf source)
  (if (eq? source 'text) (buffer-text buf) ((content-scale--proc source) buf)))

(define (content-scale--summary-view buf source style n)
  (let* ((text (content-scale--source-text buf source))
         (hit (summary-cached text style)))
    (list (or hit
              (begin (summarize text style (lambda (s) (content-scale--arrived! buf n)))
                     "Summarizing…"))
          '())))

(define (content-scale--view-result r)
  (if (string? r) (list r '()) r))

(define (content-scale--reduce buf n red)
  (let ((kind (car red)) (args (cdr red)))
    (cond
     ((eq? kind 'fold)
      (append (content-scale--fold-plan buf (content-scale--parts buf (car args))
                                        (and (pair? (cdr args)) (cadr args)))
              (list '())))
     ((eq? kind 'elide)
      (append (content-scale--elide-plan buf (content-scale--parts buf (car args))) (list '())))
     ((eq? kind 'summarize-parts)
      (append (content-scale--fold-plan buf (content-scale--parts buf (car args))
                                        (content-scale--summary-mark (cadr args) n))
              (list '())))
     ((eq? kind 'summarize)
      (list '() '() (list (content-scale--summary-view buf (car args) (cadr args) n))))
     ((or (eq? kind 'aggregate) (eq? kind 'expand))
      (list '() '() (list (content-scale--view-result ((content-scale--proc (car args)) buf)))))
     (else (list '() '() '())))))

(define (content-scale--plan buf n)
  (let ((entry (and (not (= n 0)) (content-scale--entry buf n))))
    (let loop ((reds (if entry (cddr entry) '())) (folds '()) (chrome '()) (views '()))
      (if (null? reds)
          (list folds chrome views)
          (let ((p (content-scale--reduce buf n (car reds))))
            (loop (cdr reds) (append folds (car p)) (append chrome (cadr p))
                  (append views (caddr p))))))))

(define (content-scale--line-count text) (length (string-split text "\n")))

;; Join the view parts; each part's links move down by the lines above it.
(define (content-scale--join-views views)
  (let loop ((vs views) (text "") (links '()) (offset 0))
    (if (null? vs)
        (list text links)
        (let* ((sep (if (equal? text "") "" "\n\n"))
               (body (car (car vs)))
               (shift (+ offset (if (equal? sep "") 0 2))))
          (loop (cdr vs) (string-append text sep body)
                (append links (map (lambda (l) (list (+ (car l) shift) (cadr l))) (cadr (car vs))))
                (+ shift (- (content-scale--line-count body) 1)))))))

;;; The companion view buffer

(define (content-scale-view-name buf) (string-append " *scale: " buf "*"))

(define (content-scale-source buf) (or (buffer-local buf 'content-scale-of) buf))

;; The window this buffer, or its view, stands in: the active one first.
(define (content-scale--window buf)
  (let* ((view (content-scale-view-name buf))
         (mine? (lambda (b) (or (equal? b buf) (equal? b view))))
         (active (active-window)))
    (if (and active (mine? (window-buffer active)))
        active
        (let ((hit (filter (lambda (row) (mine? (cadr row))) (window-list))))
          (and (pair? hit) (car (car hit)))))))

(define (content-scale--level-title buf n)
  (let ((entry (content-scale--entry buf n)))
    (string-append (or (buffer-local buf 'chat-title) buf)
                   " · " (if entry (symbol->string (cadr entry)) "text")
                   " (" (number->string n) ")")))

(define (content-scale--show-view! buf n text links)
  (let* ((view (content-scale-view-name buf))
         (fresh (not (buffer-known? view)))
         (body (string-append (content-scale--level-title buf n) "\n\n" text "\n")))
    (buffer-set-text! view body #t)
    (when fresh
      (with-current-buffer view (lambda () (set-mode! "content-scale-view-mode"))))
    (buffer-set-locals! view
      (list 'content-scale-of buf
            'content-scale-links (map (lambda (l) (list (+ (car l) 2) (cadr l))) links)))
    (let ((win (content-scale--window buf)))
      (when (and win (equal? (window-buffer win) buf))
        (buffer-set-local! buf 'content-scale-point (window-point win))
        (window-set-buffer! win view)
        (buffer-goto! view 0)))
    view))

(define (content-scale--hide-view! buf)
  (let ((view (content-scale-view-name buf)))
    (when (buffer-known? view)
      (let ((win (content-scale--window buf))
            (pos (buffer-local buf 'content-scale-point)))
        (when (and win (equal? (window-buffer win) view))
          (window-set-buffer! win buf)
          (when (number? pos) (buffer-goto! buf pos))))
      (buffer-kill! view))))

;;; Applying a level

(define (content-scale--apply! buf n)
  (let ((plan (content-scale--plan buf n)))
    (fold-set! buf 'content-scale (car plan))
    (overlay-set! buf 'content-scale (cadr plan))
    (if (pair? (caddr plan))
        (let ((joined (content-scale--join-views (caddr plan))))
          (content-scale--show-view! buf n (car joined) (cadr joined)))
        (content-scale--hide-view! buf))
    n))

;; LEVEL is a number or a level name. #f when BUF's mode has no such level.
(define (content-scale-set! buf level)
  (let* ((buf (content-scale-source buf))
         (n (content-scale--number buf level))
         (old (content-scale-level buf)))
    (cond
     ((not n) #f)
     ((and (not (= n 0)) (not (content-scale--entry buf n))) #f)
     (else
      (buffer-set-local! buf 'content-scale n)
      (content-scale--apply! buf n)
      (run-hook-with-args 'content-scale-change-hook buf old n)
      n))))

(define (content-scale--numbers buf)
  (sort (map car (content-scale--level-names buf))))

;; One step: DIR -1 is more detail, +1 is less.
(define (content-scale-step! buf dir)
  (let* ((buf (content-scale-source buf))
         (now (content-scale-level buf))
         (ns (content-scale--numbers buf))
         (next (if (> dir 0)
                   (filter (lambda (x) (> x now)) ns)
                   (reverse (filter (lambda (x) (< x now)) ns)))))
    (and (pair? next) (content-scale-set! buf (car next)))))

(define (content-scale--say buf)
  (let ((buf (content-scale-source buf)))
    (message (string-append "Content scale: "
                            (content-scale--level-title buf (content-scale-level buf))))))

;;; Commands

(define (content-scale--command-step! dir edge)
  (let ((buf (content-scale-source (current-buffer))))
    (if (content-scale-step! buf dir)
        (content-scale--say buf)
        (message edge))))

(define-command "content-scale-decrease" "Show less of this buffer: one content level out"
  (lambda () (content-scale--command-step! 1 "Content scale: no level further out")))

(define-command "content-scale-increase" "Show more of this buffer: one content level in"
  (lambda () (content-scale--command-step! -1 "Content scale: no level further in")))

(define-command "content-scale-reset" "Show this buffer as it is: content level 0"
  (lambda ()
    (let ((buf (content-scale-source (current-buffer))))
      (content-scale-set! buf 0)
      (content-scale--say buf))))

(define-command "content-scale-set" "Choose a content level for this buffer by name"
  (lambda ()
    (let* ((buf (content-scale-source (current-buffer)))
           (names (map (lambda (l) (symbol->string (cadr l))) (content-scale--level-names buf))))
      (completing-read "Content level: " names
                       (lambda (choice)
                         (when (content-scale-set! buf choice) (content-scale--say buf)))
                       'require-match #t))))

;; RET in a view: back to the text, at the source of the line.
(define-command "content-scale-visit" "Return to the text at the place this line came from"
  (lambda ()
    (let* ((view (current-buffer))
           (buf (buffer-local view 'content-scale-of))
           (line (with-current-buffer view (lambda () (line-number-at-pos (buffer-point view)))))
           (hits (filter (lambda (l) (<= (car l) line)) (or (buffer-local view 'content-scale-links) '())))
           (pos (and (pair? hits) (cadr (car (reverse hits))))))
      (when buf
        (when pos (buffer-set-local! buf 'content-scale-point pos))
        (content-scale-set! buf 0)
        (content-scale--say buf)))))

(define-command "content-scale-refresh" "Draw this content level again"
  (lambda ()
    (let ((buf (content-scale-source (current-buffer))))
      (content-scale--apply! buf (content-scale-level buf)))))

(define-derived-mode "content-scale-view-mode" "special-mode" (lambda () #t))

(define-key "content-scale-view-mode-map" "RET" "content-scale-visit")
(define-key "content-scale-view-mode-map" "g" "content-scale-refresh")
(define-key "content-scale-view-mode-map" "q" "content-scale-reset")
(define-key "content-scale-view-mode-map" "-" "content-scale-decrease")
(define-key "content-scale-view-mode-map" "+" "content-scale-increase")
(define-key "content-scale-view-mode-map" "=" "content-scale-increase")

;; The text-scale keys are C-+ and C--; content-scale adds Meta.
(global-set-key "C-M--" "content-scale-decrease")
(global-set-key "C-M-=" "content-scale-increase")
(global-set-key "C-M-+" "content-scale-increase")
(global-set-key "C-M-0" "content-scale-reset")

;;; Every buffer: paragraphs, their gists, a summary, a card

(define (content-scale--card buf)
  (let* ((text (buffer-text buf))
         (lines (content-scale--line-count text))
         (words (apply + (map (lambda (line)
                                 (length (filter (lambda (w) (not (equal? w "")))
                                                 (string-split line " "))))
                               (string-split text "\n"))))
         (abstract (summary-cached text 'abstract)))
    (unless abstract
      (summarize text 'abstract (lambda (s) (content-scale--arrived! buf 4))))
    (string-append buf "\n"
                   (or (buffer-local buf 'mode-name) "fundamental") " · "
                   (number->string lines) " lines · ~" (number->string words) " words\n\n"
                   (or abstract "Summarizing…"))))

(define-content-scale! "*"
  (list (list 4 'card (list 'aggregate 'content-scale--card))
        (list 3 'summary (list 'summarize 'text 'summary))
        (list 2 'gists (list 'summarize-parts 'paragraphs 'gist))
        (list 1 'outline (list 'fold 'paragraphs))))

;;; Chats: the transcript already knows its blocks and its turn summaries

(define (chat-scale--blocks buf) (sort (agent-blocks buf)))

(define (chat-scale--kind b) (list-ref b 2))

(define (chat-scale--parts-of buf kinds)
  (map (lambda (b) (list (car b) (cadr b)))
       (filter (lambda (b) (member (chat-scale--kind b) kinds)) (chat-scale--blocks buf))))

;; The blocks grouped by turn: each turn starts at a user block.
(define (chat-scale--turns buf)
  (let loop ((bs (chat-scale--blocks buf)) (turn '()) (acc '()))
    (cond ((null? bs) (reverse (if (pair? turn) (cons (reverse turn) acc) acc)))
          ((and (equal? (chat-scale--kind (car bs)) "user") (pair? turn))
           (loop (cdr bs) (list (car bs)) (cons (reverse turn) acc)))
          (else (loop (cdr bs) (cons (car bs) turn) acc)))))

(define (chat-scale--has-status? turn)
  (pair? (filter (lambda (b) (equal? (chat-scale--kind b) "status")) turn)))

;; A turn with a summary hides its reply; a turn without keeps the
;; reply's first line, so every turn still says something.
(define (chat-scale--reply-parts summarized?)
  (lambda (buf)
    (apply append
           (map (lambda (turn)
                  (if (eq? (chat-scale--has-status? turn) summarized?)
                      (map (lambda (b) (list (car b) (cadr b)))
                           (filter (lambda (b) (equal? (chat-scale--kind b) "prose")) turn))
                      '()))
                (chat-scale--turns buf)))))

(define (chat-scale--block-text buf b)
  (string-trim (substring-bytes (buffer-text buf) (car b) (cadr b))))

(define (chat-scale--first-line s)
  (let ((line (car (string-split s "\n"))))
    (if (> (string-length line) 100) (string-append (substring line 0 100) "…") line)))

;; The turn still streaming changes with every block, so a summary of it
;; would never be found again; summaries read the finished turns.
(define (chat-scale--settled-turns buf)
  (let ((turns (chat-scale--turns buf)))
    (if (and (buffer-local buf 'chat-turn-active) (pair? turns))
        (reverse (cdr (reverse turns)))
        turns)))

;; What the summaries read: each prompt and its turn summary, never the
;; tool output, so a long chat stays a short input.
(define (chat-scale--digest buf)
  (string-join
   (map (lambda (turn)
          (string-join
           (map (lambda (b)
                  (let ((k (chat-scale--kind b)) (t (chat-scale--block-text buf b)))
                    (cond ((equal? k "user") t)
                          ((equal? k "status") (string-append "Outcome: " t))
                          ((and (equal? k "prose") (not (chat-scale--has-status? turn)))
                           (string-append "Reply: " (chat-scale--first-line t)))
                          (else ""))))
                (filter (lambda (b) (member (chat-scale--kind b) '("user" "status" "prose"))) turn))
           "\n"))
        (chat-scale--settled-turns buf))
   "\n\n"))

(define (chat-scale--card buf)
  (let* ((turns (chat-scale--turns buf))
         (tools (length (chat-scale--parts-of buf '("tool"))))
         (summary (buffer-local buf 'chat-summary)))
    (string-append (or (buffer-local buf 'chat-title) buf) "\n"
                   (number->string (length turns)) " turns · "
                   (number->string tools) " tool calls"
                   (let ((m (buffer-local buf 'llm-model))) (if (string? m) (string-append " · " m) ""))
                   "\n\n"
                   (if (string? summary) (string-append "Last: " summary) ""))))

(define (chat-scale--log-line buf b)
  (let ((k (chat-scale--kind b)))
    (string-append
     (string-pad-right k 8)
     (if (and (equal? k "tool") (> (length b) 4))
         (string-append (format "~a" (list-ref b 4))
                        (if (> (length b) 6) (format "  [~a]" (list-ref b 6)) "")
                        (if (and (> (length b) 8) (number? (list-ref b 8)))
                            (string-append "  " (number->string (list-ref b 8)) "ms") ""))
         (chat-scale--first-line (chat-scale--block-text buf b))))))

;; One line per block, oldest first; RET on a line opens the transcript there.
(define (chat-scale--log buf)
  (let ((bs (chat-scale--blocks buf)))
    (let loop ((bs bs) (i 1) (lines '()) (links '()))
      (if (null? bs)
          (list (string-join (reverse lines) "\n") (reverse links))
          (loop (cdr bs) (+ i 1)
                (cons (chat-scale--log-line buf (car bs)) lines)
                (cons (list i (car (car bs))) links))))))

;; The record the chat archives: every turn as the backend saw it.
(define (chat-scale--debug buf)
  (let* ((path (chat-log-path buf))
         (log (and path (file-exists? path) (chat-log-read path))))
    (if (not log)
        "This chat has no archived record yet."
        (string-append
         "record " path "\n\n"
         (string-join (map (lambda (e) (format "~s" e)) (plist-get log 'record)) "\n\n")))))

(define-content-scale! "chat-mode"
  (list (list 5 'card (list 'aggregate 'chat-scale--card))
        (list 4 'themes (list 'summarize 'chat-scale--digest 'themes))
        (list 3 'summary (list 'summarize 'chat-scale--digest 'summary))
        (list 2 'turns
              (list 'elide (lambda (buf) (chat-scale--parts-of buf '("tool" "thought"))))
              (list 'elide (chat-scale--reply-parts #t))
              (list 'fold (chat-scale--reply-parts #f)))
        (list 1 'dialogue (list 'elide (lambda (buf) (chat-scale--parts-of buf '("tool" "thought")))))
        (list -1 'log (list 'expand 'chat-scale--log))
        (list -2 'debug (list 'expand 'chat-scale--debug))))

;; A chat grows while it is zoomed; each finished turn redraws its level.
(define (content-scale--chat-turned! buf kind text)
  (unless (= (content-scale-level buf) 0)
    (content-scale--apply! buf (content-scale-level buf))))

(add-hook! 'chat-summary-hook 'content-scale--chat-turned!)

(effects! '(read))
(public! 'content-scale-level "(content-scale-level BUF) — BUF's content level; 0 is the text as it is")
(public! 'content-scale-levels
  "(content-scale-levels BUF) — the levels BUF's mode declares, as (N NAME REDUCTION ...), most reduced first")
(public! 'content-scale-source "(content-scale-source BUF) — the buffer a content-scale view shows, or BUF itself")
(public! 'content-scale-paragraphs "(content-scale-paragraphs BUF) — BUF's paragraphs as (START END) byte ranges")
(public! 'summary-cached "(summary-cached TEXT [STYLE]) — the cached summary of TEXT, or #f; never calls a model")
(effects! '(write))
(public! 'define-content-scale!
  "(define-content-scale! MODE LEVELS) — declare MODE's content levels; LEVELS is a list of (N NAME REDUCTION ...), N > 0 reduces and N < 0 expands; a REDUCTION is (fold PARTS [MARK]), (elide PARTS), (summarize-parts PARTS STYLE), (summarize SOURCE STYLE), (aggregate FN) or (expand FN); PARTS is 'paragraphs or a procedure, or its name, (BUF) -> ((START END) ...); MODE \"*\" is every mode without its own")
(public! 'content-scale-set! "(content-scale-set! BUF LEVEL) — show BUF at LEVEL, a number or a level name; #f when its mode has no such level")
(public! 'content-scale-step! "(content-scale-step! BUF DIR) — one level out for DIR 1, one level in for DIR -1; #f at the edge")
(public! 'summarize-style! "(summarize-style! STYLE INSTRUCTION) — add or replace a summary style")
(effects! '(read external spend))
(public! 'summarize
  "(summarize TEXT [STYLE] [K]) — summarize TEXT in STYLE (gist, summary, themes, abstract) with the summarize job's model; cached by content; K gets the text or #f; the answer is the summary on a cache hit, else #f")
