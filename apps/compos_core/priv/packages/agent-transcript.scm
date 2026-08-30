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
  (let loop ((bs (buffer-list)))
    (cond ((null? bs) (agent-buffer slug))
          ((equal? (buffer-local (car bs) 'agent-slug) slug) (car bs))
          (else (loop (cdr bs))))))

(define (agent-slug-of buf) (buffer-local buf 'agent-slug))

(define (agent-status slug)
  (let ((info (agent-info slug)))
    (if info (plist-get info 'status) 'dead)))

(define (agent-add-overlay! buf s e face)
  (let ((ranges (cons (list s e face) (or (buffer-local buf 'agent-overlays) '()))))
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

(define (agent-block-close-tool! buf id end status)
  (buffer-set-local! buf 'agent-blocks
    (let loop ((bs (agent-blocks buf)) (acc '()))
      (cond ((null? bs) (reverse acc))
            ((and (equal? (nth 2 (car bs)) "tool")
                  (equal? (nth 3 (car bs)) id))
             (let ((b (car bs)))
               (append (reverse acc)
                       (cons (list (nth 0 b) end "tool" id
                                   (nth 4 b) (nth 5 b) status (nth 7 b))
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
      (let ((m (buffer-local buf 'agent-saved-mark)))
        (when m
          (cond ((>= m end) (buffer-set-local! buf 'agent-saved-mark (- m len)))
                ((> m start) (buffer-set-local! buf 'agent-saved-mark start))))))))

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
               (list (nth 0 b) (nth 1 b) "tool" (nth 3 b) (nth 4 b)
                     (nth 5 b) (nth 6 b)
                     (agent--excise-pos (nth 7 b) start end len))
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

(define (agent-tool-title e)
  (let ((name (plist-get e 'name))
        (args (agent-tool-args e)))
    (if (not name)
        (or (plist-get e 'title) "tool")     ; an adapter's own title
        (let ((v (and args (agent-tool-primary args)))
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
          (let ((title (agent-tool-title e))
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
                (nth 6 entry)))))))))

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
      (buffer-set-local! buf 'chat-activity label)
      (when (and (string? label) (string-prefix? "tool · " label))
        (message label)))))

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

(define (agent-clear-waiting! slug)
  (let* ((buf (agent-buf slug))
         (w (buffer-local buf 'agent-waiting)))
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
      (buffer-set-local! buf 'agent-waiting #f)
      (buffer-set-local! buf 'agent-saved-mark
        (min (agent-mark slug) (buffer-size buf))))))

(defcustom 'chat-stream-paragraphs #t
  "Reveal the reply one paragraph at a time. Set #f to reveal every chunk as it arrives."
  'group 'chat 'type 'boolean)

(define (agent-prose-note! buf start)
  (unless (buffer-local buf 'agent-prose-from)
    (buffer-set-local! buf 'agent-prose-from start)))

(define (agent-flush-prose! slug partial?)
  (let* ((buf (agent-buf slug))
         (from0 (buffer-local buf 'agent-prose-from)))
    (when from0
      (let* ((tail (substring-bytes (buffer-text buf) from0 (agent-mark slug)))
             (keep (if partial?
                       (let ((brk (string-rindex tail "\n\n")))
                         (if brk (+ brk 2) #f))
                       (string-byte-length tail))))
        (when (and keep (> keep 0))
          (agent-clear-waiting! slug)
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
