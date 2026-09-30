;;; agent-transcript.scm --- Agent transcript state and rendering.
;;;
;;; This module owns transcript blocks, overlays, folds, tool cards, waiting
;;; state, queued rows, and paragraph reveal. All offsets are buffer bytes.

(domain! 'chat)
(effects! '(write))
(category! 'chat)

(defface! 'agent-tool 'fg "#7aa2f7")

(defface! 'agent-thought 'fg "#787c99")

(defface! 'agent-permission 'fg "#e0af68")

(defface! 'agent-question 'fg "#7aa2f7")

(defface! 'agent-meta 'fg "#787c99")

(defface! 'agent-queued 'fg "#565a6e")

(define (agent-buffer slug) (string-append "*agent: " slug "*"))

(define (agent-buf slug)
  ;; the runtime is the authority on its own buffer. Slugs restart at a1
  ;; on every boot, so a restored buffer can carry a stale local that
  ;; claims a live slug; the scan alone then routes events to the wrong
  ;; chat. The scan stays as the fallback for a slug with no live runtime.
  (or (and (member slug (agent-list))
           (let ((b (plist-get (agent-info slug) 'buffer)))
             (and b (buffer-exists? b) b)))
      (let loop ((bs (buffer-list)))
        (cond ((null? bs) (agent-buffer slug))
              ((equal? (buffer-local (car bs) 'agent-slug) slug) (car bs))
              (else (loop (cdr bs)))))))

(define (agent-slug-of buf) (buffer-local buf 'agent-slug))

(define (agent-status slug)
  (let ((info (agent-info slug)))
    (if info (plist-get info 'status) 'dead)))

;; A streamed block arrives as many deltas with one face. A range that
;; starts where the newest range ends, with the same face, extends that
;; range. Before this, each delta added its own range: one thinking
;; stream left 41,000 ranges in 'agent-overlays, and every later read of
;; any local copied them all.
(define (agent--overlay-join r ovs)
  (if (and (pair? ovs)
           (equal? (nth 2 (car ovs)) (nth 2 r))
           (= (nth 1 (car ovs)) (nth 0 r)))
      (cons (list (nth 0 (car ovs)) (nth 1 r) (nth 2 r)) (cdr ovs))
      (cons r ovs)))

;; OVS with every adjacent same-face pair joined. OVS is newest first, and
;; so is the result. A chat saved before the join above holds one range
;; per delta; restore runs this once over it.
(define (agent-overlays-coalesce ovs)
  (let loop ((rest (reverse ovs)) (acc '()))
    (if (null? rest)
        acc
        (loop (cdr rest) (agent--overlay-join (car rest) acc)))))

(define (agent-add-overlay! buf s e face)
  (let ((ranges (agent--overlay-join (list s e face)
                                     (or (buffer-local buf 'agent-overlays) '()))))
    (buffer-set-local! buf 'agent-overlays ranges)
    (overlay-set! buf 'agent ranges)))

(define (agent-apply-folds! buf)
  (fold-set! buf 'agent
    (let loop ((fs (or (buffer-local buf 'agent-folds) '())) (acc '()))
      (cond ((null? fs) acc)
            ((car (cdr (cdr (car fs)))) (loop (cdr fs) acc)) ; open — not hidden
            (else (loop (cdr fs)
                        (cons (list (car (car fs)) (car (cdr (car fs)))) acc)))))))

(define (agent-add-fold! buf s e)
  (buffer-set-local! buf 'agent-folds
    (cons (list s e #f) (or (buffer-local buf 'agent-folds) '())))
  (agent-apply-folds! buf))

(define (agent-open-cards buf) (or (buffer-local buf 'agent-open-cards) '()))

(define (agent-card-open? buf id) (and (member id (agent-open-cards buf)) #t))

(define (agent-card-set-open! buf id open?)
  (let ((cards (agent-open-cards buf)))
    (buffer-set-local! buf 'agent-open-cards
      (if open?
          (if (member id cards) cards (cons id cards))
          (filter (lambda (c) (not (equal? c id))) cards))))
  ;; the plain view's fold over the tool body follows, when one exists
  (let ((entry (assoc id (or (buffer-local buf 'agent-tool-bodies) '()))))
    (when entry
      (let ((s (car (cdr entry))))
        (buffer-set-local! buf 'agent-folds
          (map (lambda (f)
                 (if (= (car f) s) (list (car f) (car (cdr f)) open?) f))
               (or (buffer-local buf 'agent-folds) '())))
        (agent-apply-folds! buf)))))

(define (agent-card-toggle! buf id)
  (agent-card-set-open! buf id (not (agent-card-open? buf id))))

(define (agent-set-verbosity! level)
  (let ((buf (current-buffer)))
    (buffer-set-local! buf 'agent-verbosity level)
    ;; the header line's switch says the level: redraw it
    (dashboard--sync! buf)))

(define-command "agent-verbosity-info" "Show summaries and only the latest tool title in each burst"
  (lambda () (agent-set-verbosity! "info")))

(define-command "agent-verbosity-log" "Show summaries and every compact tool call"
  (lambda () (agent-set-verbosity! "log")))

(define-command "agent-verbosity-debug" "Show summaries and full tool-call details"
  (lambda () (agent-set-verbosity! "debug")))

(define (agent-card-at-fold buf s)
  (let loop ((es (or (buffer-local buf 'agent-tool-bodies) '())))
    (cond ((null? es) #f)
          ((= (car (cdr (car es))) s) (car (car es)))
          (else (loop (cdr es))))))

(define-command "agent-toggle-fold" "Toggle the transcript fold at or around point"
  (lambda ()
    (let* ((buf (current-buffer))
           (p (point))
           ;; the fold point is on: header line just above, or inside
           (hit (let loop ((fs (or (buffer-local buf 'agent-folds) '())))
                  (cond ((null? fs) #f)
                        ((and (>= p (- (car (car fs)) 120))
                              (< p (car (cdr (car fs)))))
                         (car fs))
                        (else (loop (cdr fs))))))
           (id (and hit (agent-card-at-fold buf (car hit)))))
      (cond ((not hit) (message "no fold here"))
            ;; a tool body: the card open-state owns both views
            (id (agent-card-toggle! buf id))
            (else
             (buffer-set-local! buf 'agent-folds
               (map (lambda (f)
                      (if (= (car f) (car hit))
                          (list (car f) (car (cdr f)) (not (car (cdr (cdr f)))))
                          f))
                    (buffer-local buf 'agent-folds)))
             (agent-apply-folds! buf))))))

(define (agent-blocks buf) (or (buffer-local buf 'agent-blocks) '()))

(define (agent-block-push! buf start end kind meta)
  (buffer-set-local! buf 'agent-blocks
    (cons (append (list start end kind) meta) (agent-blocks buf))))

(define (agent-block-extend-or-push! buf start end kind)
  (let ((bs (agent-blocks buf)))
    (if (and (not (null? bs))
             (equal? (car (cdr (cdr (car bs)))) kind)
             (= (car (cdr (car bs))) start))
        (buffer-set-local! buf 'agent-blocks
          (cons (append (list (car (car bs)) end kind)
                        (cdr (cdr (cdr (car bs)))))
                (cdr bs)))
        (agent-block-push! buf start end kind '()))))

;; DURATION is the call's duration-ms from the backend, or #f. A #f
;; keeps the value the block already holds, so an argument-only close
;; never erases the timing a completion wrote.
(define (agent-block-close-tool! buf id end status duration)
  (buffer-set-local! buf 'agent-blocks
    (let loop ((bs (agent-blocks buf)) (acc '()))
      (cond ((null? bs) (reverse acc))
            ((and (equal? (nth 2 (car bs)) "tool")
                  (equal? (nth 3 (car bs)) id))
             (let ((b (car bs)))
               (append (reverse acc)
                       (cons (list (nth 0 b) end "tool" id
                                   (nth 4 b) (nth 5 b) status (nth 7 b)
                                   (or duration
                                       (and (> (length b) 8) (nth 8 b))))
                             (cdr bs)))))
            (else (loop (cdr bs) (cons (car bs) acc)))))))

(define (agent--tool-block buf id)
  (let loop ((bs (agent-blocks buf)))
    (cond ((null? bs) #f)
          ((and (equal? (nth 2 (car bs)) "tool")
                (equal? (nth 3 (car bs)) id))
           (car bs))
          (else (loop (cdr bs))))))

(define (agent-block-retitle! buf id title)
  (buffer-set-local! buf 'agent-blocks
    (map (lambda (b)
           (if (and (equal? (nth 2 b) "tool") (equal? (nth 3 b) id))
               (list (nth 0 b) (nth 1 b) "tool" id title
                     (nth 5 b) (nth 6 b) (nth 7 b))
               b))
         (agent-blocks buf))))

(define (agent-block-drop-kind! buf kind)
  (buffer-set-local! buf 'agent-blocks
    (let loop ((bs (agent-blocks buf)) (acc '()))
      (cond ((null? bs) (reverse acc))
            ((equal? (car (cdr (cdr (car bs)))) kind) (loop (cdr bs) acc))
            (else (loop (cdr bs) (cons (car bs) acc)))))))

(define (agent-excise-range! buf start end)
  (let ((len (- end start)))
    (when (> len 0)
      (buffer-delete-range! buf start len)
      (buffer-set-local! buf 'agent-blocks
        (agent--excise-blocks (agent-blocks buf) start end))
      (let ((ovs (agent--excise-ranges
                   (or (buffer-local buf 'agent-overlays) '()) start end)))
        (buffer-set-local! buf 'agent-overlays ovs)
        (overlay-set! buf 'agent ovs))
      (buffer-set-local! buf 'agent-folds
        (agent--excise-ranges (or (buffer-local buf 'agent-folds) '()) start end))
      (agent-apply-folds! buf)
      (let ((w (buffer-local buf 'agent-waiting)))
        (when w
          (cond ((>= (car w) end)
                 (buffer-set-local! buf 'agent-waiting
                   (list (- (car w) len) (- (nth 1 w) len))))
                ((and (>= (car w) start) (<= (nth 1 w) end))
                 (buffer-set-local! buf 'agent-waiting #f)))))
      (let ((p (buffer-local buf 'agent-prose-from)))
        (when p
          (cond ((>= p end) (buffer-set-local! buf 'agent-prose-from (- p len)))
                ((> p start) (buffer-set-local! buf 'agent-prose-from start)))))
      ;; 'agent-saved-mark is a marker local now — the buffer moved it
      ;; with the delete itself. A shift written here reads a value the
      ;; buffer already adjusted and moves it twice.
      )))

(define (agent--excise-pos p start end len)
  (cond ((<= p start) p)
        ((>= p end) (- p len))
        (else start)))

(define (agent--excise-ranges ranges start end)
  (let ((len (- end start)))
    (let loop ((rs ranges) (acc '()))
      (if (null? rs)
          (reverse acc)
          (let* ((r (car rs))
                 (s (agent--excise-pos (nth 0 r) start end len))
                 (e (agent--excise-pos (nth 1 r) start end len)))
            (loop (cdr rs)
                  (if (>= s e)
                      acc
                      (cons (cons s (cons e (cdr (cdr r)))) acc))))))))

(define (agent--excise-blocks blocks start end)
  (let ((len (- end start)))
    (map (lambda (b)
           (if (and (equal? (nth 2 b) "tool") (number? (nth 7 b)))
               (append
                 (list (nth 0 b) (nth 1 b) "tool" (nth 3 b) (nth 4 b)
                       (nth 5 b) (nth 6 b)
                       (agent--excise-pos (nth 7 b) start end len))
                 ;; keep the duration field an excise does not touch
                 (if (> (length b) 8) (list (nth 8 b)) '()))
               b))
         (agent--excise-ranges blocks start end))))

(define (agent-finalize-running-tools! buf status)
  (let ((ids
          (map (lambda (b) (nth 3 b))
               (filter (lambda (b)
                         (and (equal? (nth 2 b) "tool")
                              (equal? (nth 6 b) "running")))
                       (agent-blocks buf)))))
    (unless (null? ids)
      (buffer-set-local! buf 'agent-blocks
        (map (lambda (b)
               (if (and (equal? (nth 2 b) "tool")
                        (member (nth 3 b) ids))
                   (list (nth 0 b) (nth 1 b) "tool" (nth 3 b)
                         (nth 4 b) (nth 5 b) status (nth 7 b))
                   b))
             (agent-blocks buf)))
      (buffer-set-local! buf 'agent-open-cards
        (filter (lambda (id) (not (member id ids)))
                (agent-open-cards buf))))))

(defcustom 'agent-tool-body-limit 2000
  "How many bytes of a tool result a card body shows. The model still gets all of it."
  'group 'chat 'type 'integer)

(defcustom 'agent-tool-title-limit 72
  "How many bytes of a tool call's main argument the card's title shows."
  'group 'chat 'type 'integer)

(define (agent-first-line s)
  (let ((i (string-index s "\n")))
    (if i (substring-bytes s 0 i) s)))

(define (agent-clip s n)
  (if (> (string-byte-length s) n) (substring-bytes s 0 n) s))

(define (agent-tool-primary args)
  (cond ((string? args) args)
        ((pair? args)
         (or (plist-get args 'code) (plist-get args 'query)
             (plist-get args 'path) (plist-get args 'name)
             (plist-get args 'command) (plist-get args 'file_path)
             (plist-get args 'url) (plist-get args 'pattern)
             (plist-get args 'prompt)
             (agent-tool--first-string args)))
        (else #f)))

(define (agent-tool--first-string args)
  (let loop ((ps args))
    (cond ((null? ps) #f)
          ((null? (cdr ps)) #f)
          ((and (string? (nth 1 ps))
                (not (equal? (string-trim (nth 1 ps)) "")))
           (nth 1 ps))
          (else (loop (cdr (cdr ps)))))))

(define (agent-tool-name-display name)
  (if (string-prefix? "mcp__" name)
      (let* ((rest (substring-bytes name 5 (string-byte-length name)))
             (i (string-index rest "__")))
        (if i
            (string-append (substring-bytes rest 0 i) ":"
                           (substring-bytes rest (+ i 2) (string-byte-length rest)))
            name))
      name))

(define (agent-tool-args e)
  (let ((json (plist-get e 'input)))
    (and (string? json) (json-parse json))))

;; Every eval call in a session names the same tool. The code argument
;; names the call better: its head symbol is the verb, the rest is the
;; argument. So "compos/eval-scheme: (code-read X)" titles as
;; "code-read: X".
(define (agent-eval-tool? name)
  (and (string? name) (string-suffix? "eval-scheme" name)))

;; "(head rest...)" -> (head "rest...") when head is a plain symbol; #f
;; when the text is not a call form. The outer closer leaves the rest.
(define (agent-sexp-head-split v)
  (let ((t (string-trim v)))
    (and (string-prefix? "(" t)
         (let* ((n (string-byte-length t))
                (inner (substring-bytes t 1 n))
                (isp (string-index inner " "))
                (inl (string-index inner "\n"))
                (i (cond ((and isp inl) (min isp inl))
                         (isp isp)
                         (else inl))))
           (let* ((head (if i (substring-bytes inner 0 i) inner))
                  (head (if (string-suffix? ")" head)
                            (substring-bytes head 0 (- (string-byte-length head) 1))
                            head))
                  (rest (if i (string-trim (substring-bytes inner (+ i 1)
                                             (string-byte-length inner)))
                            ""))
                  (rest (if (string-suffix? ")" rest)
                            (substring-bytes rest 0 (- (string-byte-length rest) 1))
                            rest)))
             (and (> (string-byte-length head) 0)
                  (not (string-index head "("))
                  (not (string-index head "\""))
                  (list head rest)))))))

;; A full path in a card title is mostly noise: show it relative to its
;; repository root, or with ~ for home, and leave every non-path alone.
(define (agent--dir-of p)
  (let loop ((parts (string-split p "/")) (acc '()))
    (if (or (null? parts) (null? (cdr parts)))
        (string-join (reverse acc) "/")
        (loop (cdr parts) (cons (car parts) acc)))))

(define (agent-path-abbrev p)
  (if (and (string? p) (string-prefix? "/" p))
      (let ((root (git-root (agent--dir-of p))))
        (if (and (string? root)
                 (string-prefix? (string-append root "/") p))
            (substring p (+ (string-length root) 1) (string-length p))
            (abbreviate-file-name p)))
      p))

(define (agent-tool-title e)
  (let ((name (plist-get e 'name))
        (args (agent-tool-args e)))
    ;; a refining update carries no name, and the wire's nil is true
    (if (not (string? name))
        (or (plist-get e 'title) "tool")     ; an adapter's own title
        (let ((v (agent-path-abbrev (and args (agent-tool-primary args))))
              (shown (agent-tool-name-display name)))
          (if (and v (string? v) (not (equal? (string-trim v) "")))
              (let ((sx (and (agent-eval-tool? name) (agent-sexp-head-split v))))
                (if sx
                    (if (equal? (car (cdr sx)) "")
                        (car sx)
                        (string-append (car sx) ": "
                          (agent-clip (string-trim (agent-first-line (car (cdr sx))))
                                      agent-tool-title-limit)))
                    (string-append shown ": "
                      (agent-clip (string-trim (agent-first-line v)) agent-tool-title-limit))))
              shown)))))

(define (agent-tool-input-text e)
  (let* ((args (agent-tool-args e))
         (v (and args (agent-tool-primary args))))
    (cond ((not args) "")
          ((null? args) "")
          ((and v (string? v)) (string-append (string-trim v) "\n\n"))
          (else (string-append (string-trim (plist-get e 'input)) "\n\n")))))

(define (agent-tool-refine! slug buf e)
  (let ((input (plist-get e 'input)))
    (when (and (string? input) (not (equal? input "")))
      (let ((entry (agent--tool-block buf (plist-get e 'id))))
        (when (and entry
                   (number? (nth 7 entry))
                   (<= (nth 1 entry) (nth 7 entry)))
          ;; the update names no tool: the call that opened it did
          (let* ((known (assoc (plist-get e 'id)
                               (or (buffer-local buf 'chat-tool-pending) '())))
                 (e (if (and (not (string? (plist-get e 'name)))
                             known (string? (nth 1 known)))
                        (append (list 'name (nth 1 known)) e)
                        e))
                 (title (agent-tool-title e))
                 (kind (nth 5 entry))
                 (args (agent-tool-input-text e)))
            (unless (equal? title (nth 4 entry))
              (agent-block-retitle! buf (plist-get e 'id) title)
              (when (equal? (nth 6 entry) "running")
                (chat-activity! buf (string-append "tool · " title))))
            ;; the tool-call path saw no input, so code.scm could not see
            ;; a code edit either — report the call again, now complete
            (when (boundp (quote code-agent-note-tool!))
              (code-agent-note-tool! buf title kind args))
            (unless (equal? args "")
              (agent-render! slug args #f)
              (agent-block-close-tool! buf (plist-get e 'id)
                (agent-mark slug)
                (nth 6 entry)
                #f))))))))

(define (agent-tool-update-text e)
  (let ((out (plist-get e 'output)))
    (if (not (string? out))
        (or (plist-get e 'text) "")          ; an adapter's own rendering
        (let ((s (string-trim out)))
          (cond ((equal? s "") "")
                ((> (string-byte-length s) agent-tool-body-limit)
                 (string-append (substring-bytes s 0 agent-tool-body-limit) "\n[…]\n"))
                (else (string-append s "\n")))))))

(define (agent-render! slug text face)
  (let ((buf (agent-buf slug))
        (start (agent-mark slug)))
    (agent-append! slug text)
    (when face
      (agent-add-overlay! buf start (+ start (string-byte-length text)) face))
    ;; agent-append! moves 'agent-saved-mark itself, in the same buffer
    ;; message as the insert. Setting it here as well is a second frame in
    ;; which the mark is stale, and the input row shows the marker.
    start))

(define (chat-activity! buf label)
  (when (and buf (buffer-exists? buf))
    (unless (equal? (buffer-local buf 'chat-activity) label)
      ;; Tool activity lives in the chat UI alone. It never overwrites the
      ;; user's echo area and never adds a line to *Messages*.
      (buffer-set-local! buf 'chat-activity label))))

;; A thought run streams as many deltas; only the label on the activity
;; row shows the reasoning while it runs. The transcript gets the whole
;; run as ONE thought block, written when the first non-thought event
;; follows the run (agent-thought-reveal!). Before this, every delta
;; appended its own text: one long reasoning stream made one buffer
;; write, one re-decorate, and one transcript diff per token, and the
;; input row starved behind them.
(define *agent-thought-tails* '())

;; A new label only every N deltas. The tail still accumulates on every
;; token; the chat-activity buffer-local — and the repaint it broadcasts —
;; is spared most of them.
(define *agent-thought-label-every* 4)

;; An entry is (SLUG TAIL COUNT CHUNKS-REV). TAIL is the newest 240
;; bytes, for the label. CHUNKS-REV is the whole run as a reversed delta
;; list: one delta costs one cons, and the reveal joins the list once.
(define (agent-thought-note! slug delta)
  (let* ((entry (assoc slug *agent-thought-tails*))
         (prev (if entry (cadr entry) ""))
         (count (if entry (caddr entry) 0))
         (chunks (if entry (car (cdr (cdr (cdr entry)))) '()))
         (grown (string-append prev delta))
         (n (string-byte-length grown))
         (tail (if (> n 240)
                   (substring-bytes grown (- n 240) n)
                   grown)))
    (set! *agent-thought-tails*
      (cons (list slug tail (+ count 1) (cons delta chunks))
            (remove (lambda (x) (equal? (car x) slug)) *agent-thought-tails*)))
    (and (= 0 (modulo count *agent-thought-label-every*)) tail)))

;; The whole buffered run as one string, or #f when none is buffered.
(define (agent-thought-full slug)
  (let ((entry (assoc slug *agent-thought-tails*)))
    (and entry
         (let ((chunks (car (cdr (cdr (cdr entry))))))
           (and (pair? chunks) (string-join (reverse chunks) ""))))))

(define (agent-thought-forget! slug)
  (set! *agent-thought-tails*
    (remove (lambda (x) (equal? (car x) slug)) *agent-thought-tails*)))

;; Write the buffered run to the transcript as one thought block. The
;; caller runs this before the first non-thought event of the run and at
;; turn-end. A dead agent has no transcript left to write into; discard
;; its buffered text instead.
(define (agent-thought-reveal! slug)
  (let ((full (agent-thought-full slug)))
    (when (and full (member slug (agent-list)))
      (let ((buf (agent-buf slug)))
        (agent-clear-waiting! buf)
        (let ((start (agent-render! slug full "agent-thought")))
          (agent-block-extend-or-push! buf start (agent-mark slug) "thought"))))
    (agent-thought-forget! slug)))

;; the byte where the current (in-progress) sentence begins in S. A
;; sentence terminator that is the final character means that sentence
;; just completed, so it stays visible whole until the next word begins.
(define (agent--tail-sentence s)
  (let ((n (string-byte-length s)))
    (let loop ((marks '("." "!" "?" "\n")) (best 0))
      (if (null? marks)
          best
          (let ((i (string-rindex s (car marks))))
            (loop (cdr marks)
                  (if (and i (< i (- n 1)))
                      (max best (+ i 1))
                      best)))))))

(define (agent-activity-preview tail)
  (let* ((text (string-trim (or tail "")))
         (n (string-byte-length text)))
    (if (equal? text "")
        "thinking…"
        (let* ((start (agent--tail-sentence text))
               (line (string-trim (substring-bytes text start n)))
               (shown (if (equal? line "") "thinking…"
                          (string-append "thinking · " line))))
          (if (> (string-byte-length shown) 160)
              (string-append (substring-bytes shown 0 159) "…")
              shown)))))

(define (agent-show-waiting! slug)
  (let ((buf (agent-buf slug)))
    ;; idempotent: a queued echo re-shows it, and the turn start shows it
    ;; again — one line, not two
    (unless (buffer-local buf 'agent-waiting)
      (let* ((text "⋯ thinking\n")
             (start (agent-render! slug text "agent-thought"))
             (end (+ start (string-byte-length text))))
        (buffer-set-local! buf 'agent-waiting (list start end))
        ;; the rich transcript renders blocks only — without this block
        ;; the waiting line is invisible text in the buffer
        (agent-block-push! buf start end "waiting" '())))))

(define (agent-clear-waiting! buf)
  (let ((w (buffer-local buf 'agent-waiting)))
    (when w
      (let* ((start (car w))
             (end (car (cdr w)))
             (size (buffer-size buf)))
        ;; An obsolete range is harmless runtime metadata. It must never
        ;; take the chat buffer process down or delete text that replaced the
        ;; waiting line while events crossed.
        (when (and (>= start 0) (>= end start) (<= end size)
                   (equal? (substring-bytes (buffer-text buf) start end)
                           "⋯ thinking\n"))
          ;; excise, not a bare delete: the line's own overlay must leave
          ;; 'agent-overlays, or the next overlay-set! re-applies its face
          ;; over the text that replaces the line
          (agent-excise-range! buf start end)))
      (agent-block-drop-kind! buf "waiting")
      ;; the excise above already moved 'agent-saved-mark. Do not set it
      ;; again from the runtime: the runtime's copy of the mark is gone,
      ;; and a value written from anywhere but the excise put the mark
      ;; outside the marker, which fed transcript text into the input row.
      (buffer-set-local! buf 'agent-waiting #f))))

(defcustom 'chat-stream-paragraphs #t
  "Reveal the reply one paragraph at a time. Set #f to reveal every chunk as it arrives."
  'group 'chat 'type 'boolean)

;; A reply reads as prose, so it took the serif slot. A reply is also
;; mostly code, paths, and names, so the serif slot is wrong as often as
;; it is right. The type is a setting, not a constant: the 'chat face's
;; family attribute publishes --chat-family, and .ag-prose reads it with
;; the serif slot as its fallback. Empty writes no variable, so empty
;; means serif and nothing in the stylesheet has to change.
(defcustom 'chat-font-family ""
  "The font of a chat reply, as a CSS font stack. Empty means the serif slot."
  'group 'chat
  'set (lambda (stack) (defface! 'chat 'family stack)))

(defface! 'chat 'family chat-font-family)

(define (agent-prose-note! buf start)
  (unless (buffer-local buf 'agent-prose-from)
    (buffer-set-local! buf 'agent-prose-from start)))

(define (agent-flush-prose! slug partial?)
  (let* ((buf (agent-buf slug))
         (raw (buffer-local buf 'agent-prose-from))
         ;; a stale local — restored from an older, longer incarnation of
         ;; the buffer — can point past the text. It can only throw below,
         ;; and the throw kills the event that carried it: drop it instead.
         (from0 (and raw
                     (if (and (<= raw (agent-mark slug))
                              (<= (agent-mark slug) (buffer-size buf)))
                         raw
                         (begin (buffer-set-local! buf 'agent-prose-from #f)
                                #f)))))
    (when from0
      (let* ((tail (substring-bytes (buffer-text buf) from0 (agent-mark slug)))
             (keep (if partial?
                       (let ((brk (string-rindex tail "\n\n")))
                         (if brk (+ brk 2) #f))
                       (string-byte-length tail))))
        (when (and keep (> keep 0))
          (agent-clear-waiting! buf)
          (let* ((from (buffer-local buf 'agent-prose-from))
                 (cut (+ from keep)))
            (agent-block-extend-or-push! buf from cut "prose")
            (buffer-set-local! buf 'agent-prose-from
              (if (< cut (agent-mark slug)) cut #f))))))))

(define (agent-sweep-waiting! buf)
  (for-each
    (lambda (b)
      (let ((start (nth 0 b)) (end (nth 1 b)))
        (when (and (>= start 0) (>= end start) (<= end (buffer-size buf))
                   (equal? (substring-bytes (buffer-text buf) start end)
                           "⋯ thinking\n"))
          (agent-excise-range! buf start end))))
    (filter (lambda (b) (equal? (nth 2 b) "waiting")) (agent-blocks buf)))
  (agent-block-drop-kind! buf "waiting"))

(define (agent-adopt-prose-tail! buf)
  (let ((from (buffer-local buf 'agent-prose-from)))
    (when from
      (let ((m (min (or (buffer-local buf 'agent-saved-mark) 0)
                    (buffer-size buf))))
        (when (< from m)
          (agent-block-extend-or-push! buf from m "prose")))
      (buffer-set-local! buf 'agent-prose-from #f))))

(define (agent-echo-queued! slug text)
  (let ((buf (agent-buf slug)))
    (buffer-set-local! buf 'chat-queued
      (append (or (buffer-local buf 'chat-queued) '()) (list text)))))

(define (agent-pop-queued! buf text)
  (let ((texts (or (buffer-local buf 'chat-queued) '())))
    (when (and (not (null? texts)) (equal? (car texts) text))
      (buffer-set-local! buf 'chat-queued
        (if (null? (cdr texts)) #f (cdr texts))))))

(define (agent-discard-queued! buf)
  (buffer-set-local! buf 'chat-queued #f)
  (for-each (lambda (b) (agent-excise-range! buf (nth 0 b) (nth 1 b)))
            (filter (lambda (b) (equal? (nth 2 b) "queued"))
                    (agent-blocks buf))))

(define (agent-unqueue-renders-to-input! buf)
  (let* ((qs (filter (lambda (b) (equal? (nth 2 b) "queued")) (agent-blocks buf)))
         (texts (append (map (lambda (b) (nth 3 b)) (reverse qs))
                        (or (buffer-local buf 'chat-queued) '()))))
    (buffer-set-local! buf 'chat-queued #f)
    (unless (null? texts)
      (let ((draft (chat-input-text buf)))
        (for-each (lambda (b) (agent-excise-range! buf (nth 0 b) (nth 1 b))) qs)
        (chat-replace-input! buf
          (fold (lambda (acc t)
                  (if (equal? acc "") t (string-append acc "\n" t)))
                ""
                (if (equal? (string-trim draft) "")
                    texts
                    (append texts (list draft)))))))))

;;; --- the rich view: the chat as a block tree ----------------------------------
;;; A rich chat renders through the generic "blocks" mode. This section maps
;;; the block model ('agent-blocks, the open cards, the verbosity, the queue
;;; and the activity word) to the tree in 'render-blocks. The tree holds byte
;;; ranges, not text: the view draws the buffer's own bytes. A memo keeps the
;;; view of each transcript block, so a streamed event costs the views of the
;;; blocks it changed. chat-view-sync! runs after each event batch, after
;;; each command in a chat, and in the mode hook.

(effects! '(pure))

;; a rich chat: a transcript with a mark, and a view that is not plain
(define (chat-rich-view? buf)
  (and (number? (buffer-local buf 'agent-saved-mark))
       (equal? (buffer-local buf 'render-mode) "blocks")))

(define (chat-view--label text) (list 'tag "c-label" 'class "ag-label" 'text text))

(define (chat-view--text tag class text) (list 'tag tag 'class class 'text text))

;; the bytes S..E of BUF, clamped to the buffer
(define (chat-view--slice buf s e)
  (let* ((size (buffer-size buf))
         (a (max 0 (min s size)))
         (b (max a (min e size))))
    (if (= a b) "" (with-current-buffer buf (lambda () (buffer-substring a b))))))

(define (chat-view--tenths n)
  (string-append (number->string (quotient n 10)) "." (number->string (remainder n 10))))

;; "340ms", "1.4s", "2m 05s"; #f when the block has no duration
(define (chat-view-duration-label ms)
  (cond ((not (and (number? ms) (>= ms 0))) #f)
        ((< ms 1000) (string-append (number->string ms) "ms"))
        ((< ms 60000) (string-append (chat-view--tenths (quotient (+ ms 50) 100)) "s"))
        (else (string-append (number->string (quotient ms 60000)) "m "
                             (let ((sec (remainder (quotient ms 1000) 60)))
                               (string-append (if (< sec 10) "0" "") (number->string sec)))
                             "s"))))

;; what a call added to the context, from its byte count; #f below 4 bytes
(define (chat-view-token-label bytes)
  (let ((tokens (quotient bytes 4)))
    (cond ((< bytes 4) #f)
          ((< tokens 1000) (string-append "~" (number->string tokens) " tok"))
          (else (string-append "~" (chat-view--tenths (quotient (+ tokens 50) 100)) "k tok")))))

(define (chat-view--user kind class text)
  (list 'tag "c-user" 'class class
        'attrs (list (list "author" "user") (list "kind" kind))
        'children (list (chat-view--label "YOU")
                        (list 'tag "c-message-body" 'class "ag-user-text" 'text text))))

(define (chat-view--user-text buf b)
  (if (and (> (length b) 3) (string? (nth 3 b)))
      (nth 3 b)
      (let ((t (string-trim (chat-view--slice buf (nth 0 b) (nth 1 b)))))
        (if (string-prefix? ">>> you: " t) (substring-bytes t 9 (string-byte-length t)) t))))

(define (chat-view--button class click label)
  (list 'tag "button" 'class class 'click click 'text label))

;; the tool card: a controlled disclosure. The summary names the call; the
;; body is the call's own bytes, drawn with the tool result unwrapped.
(define (chat-view--tool buf b open-cards)
  (let* ((e (nth 1 b)) (id (nth 3 b)) (title (or (nth 4 b) "")) (verb (nth 5 b))
         (status (or (nth 6 b) "")) (bs (nth 7 b))
         (duration (chat-view-duration-label (and (> (length b) 8) (nth 8 b))))
         (open (if (member id open-cards) #t #f))
         (split (string-index title ": "))
         (name (if split (substring-bytes title 0 split) title))
         (arg (if split (substring-bytes title (+ split 2) (string-byte-length title)) ""))
         (body (string-trim (chat-view--slice buf bs e)))
         (tokens (chat-view-token-label (+ (string-byte-length title) (string-byte-length body))))
         (verb-shown (and (string? verb) (not (member verb '("" "tool" "mcp" "other"))))))
    (list 'tag "c-toolcall"
          'attrs (list (list "call" id) (list "name" name) (list "state" status))
          'children
          (list
            (list 'tag "details" 'class (string-append "ag-tool " status) 'open open
                  'children
                  (append
                    (list
                      (list 'tag "summary" 'click (string-append "chat-card:" id)
                            'attrs (list (list "aria-label"
                                               (string-append (if (string? verb) verb "") " " title
                                                              ", " status ". Toggle call details")))
                            'children
                            (append
                              (list (list 'tag "c-text" 'class "ag-chevron"
                                          'attrs '(("aria-hidden" "true")) 'text "›")
                                    (list 'tag "c-text" 'class (string-append "ag-dot " status)))
                              (if verb-shown (list (chat-view--text "c-text" "ag-verb ag-kind" verb)) '())
                              (list (list 'tag "c-text" 'class "ag-summary-copy"
                                          'children
                                          (append
                                            (list (list 'tag "c-text" 'class "ag-title"
                                                        'attrs (list (list "title" title))
                                                        'children
                                                        (append
                                                          (list (chat-view--text "c-text" "ag-tool-name" name))
                                                          (if (equal? arg "") '()
                                                              (list (chat-view--text "c-arguments" "ag-arg" arg))))))
                                            (if open '()
                                                (list (list 'tag "c-text" 'class "ag-preview"
                                                            'range (list bs e) 'format "mcp-result-line"))))))
                              (if (equal? status "done") '()
                                  (list (list 'tag "c-status" 'class (string-append "ag-tstatus " status)
                                              'attrs (list (list "state" status)) 'text status)))
                              (if duration (list (chat-view--text "c-text" "ag-duration" duration)) '())
                              (if tokens (list (chat-view--text "c-text" "ag-duration ag-tokens" tokens)) '()))))
                    ;; a closed card draws no body: a closed details
                    ;; still holds its body in the page, and one 1.28 MB
                    ;; tool result was 116k nodes behind a one-line summary
                    (if (or (not open) (equal? body "")) '()
                        (list (list 'tag "c-result"
                                    'children (list (list 'tag "pre" 'class "ag-body"
                                                          'range (list bs e) 'format "mcp-result")))))))))))

;; the view of one transcript block, or #f for a block the rich view does
;; not draw (the waiting line: the activity row says it)
(define (chat-view-block buf b open-cards)
  (let ((s (nth 0 b)) (e (nth 1 b)) (kind (nth 2 b)))
    (cond
      ((equal? kind "user") (chat-view--user "user" "ag-user" (chat-view--user-text buf b)))
      ((equal? kind "queued") (chat-view--user "queued" "ag-user ag-queued" (chat-view--user-text buf b)))
      ((equal? kind "prose")
       (list 'tag "c-agent" 'class "ag-prose"
             'attrs '(("author" "assistant") ("kind" "prose"))
             'range (list s e) 'format "markdown"))
      ((equal? kind "thought")
       (list 'tag "details" 'class "ag-thought"
             'children (list (list 'tag "summary" 'text "thought")
                             (list 'tag "c-group" 'class "ag-thought-text" 'range (list s e)))))
      ((equal? kind "tool") (chat-view--tool buf b open-cards))
      ((equal? kind "plan")
       (list 'tag "c-plan" 'children (list (list 'tag "pre" 'class "ag-plan" 'range (list s e)))))
      ((equal? kind "permission")
       (list 'tag "c-permission" 'class "ag-perm" 'attrs '(("kind" "permission"))
             'children
             (list (chat-view--text "c-text" "ag-perm-title" (string-append "needs permission — " (nth 3 b)))
                   (list 'tag "c-toolbar" 'class "ag-perm-actions"
                         'children
                         (list (chat-view--button "ag-btn allow" "chat-cmd:agent-permission-allow" "Allow")
                               (chat-view--button "ag-btn session" "chat-cmd:agent-permission-always" "Always")
                               (chat-view--button "ag-btn deny" "chat-cmd:agent-permission-deny" "Deny"))))))
      ((equal? kind "question")
       (let ((qid (nth 3 b)) (answers (or (nth 6 b) '())))
         (list 'tag "c-question" 'class "ag-question"
               'children
               (list (chat-view--text "c-headline" "ag-question-title" (nth 5 b))
                     (list 'tag "c-answers" 'class "ag-question-answers"
                           'children
                           (map (lambda (i)
                                  (chat-view--button "ag-btn answer"
                                    (string-append "chat-answer:" (value->string qid) ":" (number->string i))
                                    (nth i answers)))
                                (iota (length answers))))
                     (chat-view--text "c-hint" "ag-question-hint"
                                      "Choose an answer or type another reply below.")))))
      ((equal? kind "status")
       (list 'tag "c-summary" 'class "ag-status" 'attrs '(("kind" "status"))
             'children (list (chat-view--label "SUMMARY")
                             (list 'tag "c-group" 'class "ag-status-text" 'range (list s e)))))
      ((equal? kind "image")
       (let ((path (nth 3 b)))
         (list 'tag "c-user" 'class "ag-user ag-image"
               'attrs '(("author" "user") ("kind" "image"))
               'children (list (chat-view--label "YOU")
                               (list 'tag "img" 'class "ag-image-img" 'file path
                                     'attrs (list (list "alt" (file-name-nondirectory path))
                                                  (list "title" (file-name-nondirectory path))))))))
      ((equal? kind "eval")
       (list 'tag "c-eval" 'class "ag-eval" 'attrs '(("kind" "eval"))
             'children (list (list 'tag "pre" 'class "ag-eval-text" 'range (list s e)))))
      ((equal? kind "meta")
       (list 'tag "c-info" 'class "ag-meta" 'attrs '(("kind" "meta")) 'range (list s e)))
      (else #f))))

;; The memo per buffer: (RAW OPEN VIEWS SIG). RAW is 'agent-blocks as last
;; built (newest first), VIEWS their views in the same order.
(define *chat-view-memo* '())

(define (chat-view--memo buf)
  (let ((m (assoc buf *chat-view-memo*))) (and m (cadr m))))

(define (chat-view--memo-set! buf entry)
  (set! *chat-view-memo*
    (cons (list buf entry)
          (filter (lambda (m) (and (not (equal? (car m) buf)) (buffer-exists? (car m))))
                  *chat-view-memo*))))

(define (chat-view--zip a b)
  (if (or (null? a) (null? b))
      '()
      (cons (list (car a) (car b)) (chat-view--zip (cdr a) (cdr b)))))

;; --- the transcript window ---------------------------------------------------
;; The browser walks every node of the transcript on each patch to it, and a
;; streamed chunk patches it. A 3 MB chat was 128k nodes and 200 ms a key. So
;; the tree draws only the newest blocks, up to a byte budget of the text
;; they hold. A row above them reveals one more budget of earlier blocks.
;; The buffer keeps all of its text; only the drawing is windowed.

(defcustom 'chat-view-window-bytes 262144
  "How many bytes of transcript text a rich chat draws. Earlier blocks wait behind a row that reveals them. 0 draws all."
  'group 'chat 'type 'integer)

;; how many blocks of RAW (newest first) PAGES budgets draw. Each page
;; takes blocks up to PER bytes and at least one block, so a block larger
;; than the budget cannot stop a reveal.
(define (chat-view--window-count raw per pages)
  (let loop ((r raw) (bytes 0) (in-page 0) (page 0) (n 0))
    (cond
      ((null? r) n)
      ((> page pages) n)
      (else
       (let ((next (+ bytes (max 0 (- (nth 1 (car r)) (nth 0 (car r)))))))
         (if (and (> in-page 0) (> next per))
             (loop r 0 0 (+ page 1) n)
             (loop (cdr r) next (+ in-page 1) page (+ n 1))))))))

;; the drawn views and the count of hidden views, both from newest-first lists
(define (chat-view--window buf raw views)
  (let* ((per (or chat-view-window-bytes 0))
         (reveal (or (buffer-local buf 'chat-view-reveal) 0)))
    (if (<= per 0)
        (list views 0)
        (let ((n (chat-view--window-count raw per reveal)))
          (list (take views n)
                (length (filter (lambda (v) v) (list-tail views (min n (length views))))))))))

(define (chat-view--earlier n)
  (list 'tag "c-group" 'class "ag-earlier"
        'children (list (chat-view--button "ag-btn earlier" "chat-earlier"
                                           (string-append "Show earlier blocks ("
                                                          (number->string n) " hidden)")))))

;; the views of RAW, newest first. The common events push a block or change
;; the newest one; both reuse every older view without a walk.
(define (chat-view--views buf raw open m)
  (let ((old-raw (and m (nth 0 m))) (old-views (and m (nth 2 m))))
    (cond
      ((not (and m (equal? (nth 1 m) open)))
       (map (lambda (b) (chat-view-block buf b open)) raw))
      ((equal? raw old-raw) old-views)
      ((and (pair? raw) (equal? (cdr raw) old-raw))
       (cons (chat-view-block buf (car raw) open) old-views))
      ((and (pair? raw) (pair? old-raw) (equal? (cdr raw) (cdr old-raw)))
       (cons (chat-view-block buf (car raw) open) (cdr old-views)))
      (else
       (let ((pairs (chat-view--zip old-raw old-views)))
         (map (lambda (b)
                (let ((hit (assoc b pairs)))
                  (if hit (cadr hit) (chat-view-block buf b open))))
              raw))))))

(define (chat-view-tree buf children verbosity queued activity hidden)
  (append
    (list (list 'tag "c-transcript" 'class (string-append "ag-scroll ag-verbosity-" verbosity)
                'isolate #t 'follow #t 'anchor "transcript"
                'attrs (list (list "verbosity" verbosity) (list "buffer" buf))
                ;; the first drawn block keeps its index in the whole
                ;; transcript; the earlier row takes the index before it
                'index-base (max 0 (- hidden 1))
                'children (if (> hidden 0)
                              (cons (chat-view--earlier hidden) children)
                              children)))
    (map (lambda (q)
           (list 'tag "c-user" 'class "ag-user ag-queued ag-queued-row"
                 'attrs '(("state" "queued"))
                 'children (list (chat-view--label "YOU")
                                 (list 'tag "c-group" 'class "ag-user-text" 'text q))))
         queued)
    (if (and (string? activity) (not (equal? activity "disconnected")))
        (list (list 'tag "c-activity" 'class "ag-wait ag-activity"
                    'children (list (chat-view--text "c-text" "ag-activity-text"
                                                     (string-append "⋯ " activity)))))
        '())
    (list (list 'tag "c-prompt" 'class "ag-inputrow"
                'children (list (chat-view--label "YOU")
                                (list 'tag "c-input" 'class "ag-input" 'input #t
                                      'hint "RET sends · C-RET interrupts"))))))

(effects! '(write))

;; The activity label is the last event's word. agent-status is what is true
;; NOW. A label standing over an idle runtime is a turn-end that never
;; arrived, and the row must not go on advertising work nobody is doing. So
;; the row reads both, and the runtime wins: no lost event can leave the
;; chat saying "streaming" at a model that stopped.
;; Only a runtime that is working, or about to, may caption itself. Naming
;; those three is safer than excluding idle: a DEAD runtime is not working
;; either, and excluding one status let "streaming" stand over a backend that
;; had exited. #f is a chat whose runtime has not started yet -- it owns its
;; label, because nothing else knows about it.
(define *chat-activity-statuses* '(running needs_attention starting))

;; the decision alone: one label, one status, no buffer and no runtime
(define (chat-activity-shown label status)
  (and (string? label)
       (or (not status) (member status *chat-activity-statuses*))
       label))

(define (chat-activity-live buf)
  (chat-activity-shown
    (buffer-local buf 'chat-activity)
    (let ((slug (buffer-local buf 'agent-slug)))
      (and (string? slug) (agent-status slug)))))

;; Write BUF's block tree when its model changed. Cheap when it did not:
;; one comparison of the model with the one the last build read.
(define (chat-view-sync! buf)
  (when (and (buffer-exists? buf) (chat-rich-view? buf))
    (let* ((raw (agent-blocks buf))
           (open (agent-open-cards buf))
           (verbosity (or (buffer-local buf 'agent-verbosity) "info"))
           (queued (or (buffer-local buf 'chat-queued) '()))
           (activity (chat-activity-live buf))
           (sig (list raw open verbosity queued activity
                      (buffer-local buf 'chat-view-reveal)
                      chat-view-window-bytes))
           (m (chat-view--memo buf)))
      (unless (and m (equal? (nth 3 m) sig)
                   (buffer-local buf 'render-blocks))
        (let* ((views (chat-view--views buf raw open m))
               (win (chat-view--window buf raw views)))
          (chat-view--memo-set! buf (list raw open views sig))
          (buffer-set-locals! buf
            (list 'render-root '(tag "c-buffer" class "agent-view")
                  'render-input "agent-saved-mark"
                  'render-blocks (chat-view-tree buf (reverse (filter (lambda (v) v) (car win)))
                                                 verbosity queued activity (cadr win)))))))))

;; the clicks the tree carries: a tool card, a permission verb, an answer
(add-hook! (list 'block-click 'chat)
  (lambda (buf id)
    (cond
      ((string-prefix? "chat-card:" id)
       (agent-card-toggle! buf (substring-bytes id 10 (string-byte-length id)))
       (chat-view-sync! buf)
       #t)
      ((equal? id "chat-earlier")
       (buffer-set-local! buf 'chat-view-reveal
         (+ 1 (or (buffer-local buf 'chat-view-reveal) 0)))
       (chat-view-sync! buf)
       #t)
      ((string-prefix? "chat-cmd:" id)
       (run-command (substring-bytes id 9 (string-byte-length id)))
       (chat-view-sync! buf)
       #t)
      ((string-prefix? "chat-answer:" id)
       (let* ((parts (string-split (substring-bytes id 12 (string-byte-length id)) ":"))
              (q (let loop ((bs (agent-blocks buf)))
                   (cond ((null? bs) #f)
                         ((and (equal? (nth 2 (car bs)) "question")
                               (equal? (value->string (nth 3 (car bs))) (car parts)))
                          (car bs))
                         (else (loop (cdr bs)))))))
         (when q
           (agent-answer-question! (nth 4 q) (nth 3 q)
                                   (nth (string->number (cadr parts)) (or (nth 6 q) '()))))
         (chat-view-sync! buf)
         #t))
      (else #f))))

(define (chat-view--mode-hook!) (chat-view-sync! (current-buffer)))

(add-hook! 'chat-mode-hook 'chat-view--mode-hook!)
