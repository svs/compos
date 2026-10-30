;;; llm-rewrite.scm --- region -> LLM -> a diff block that waits.
;;;
;;; gptel's other half, as an action over the diff block: the model
;;; rewrites a passage, and its version lands as a diff block below the
;;; passage (diff-block.scm owns the block: its states, its fence, its
;;; verbs). This file owns only the LLM policy — the directives, the
;;; prompt, the reply cleaning, and the review loop C-c e opens.

;; the block vocabulary is the editor's
(namespace! 'editor)
(domain! 'llm)
(effects! '(write external spend))

(define *llm-rewrite-prose-modes*
  '("text-mode" "markdown-mode" "morg-mode" "org-mode" "chat-mode"))

;; The instructions the prompt offers. Prose and code want opposite things
;; from a model, so the buffer's mode decides which set leads.
(define *llm-rewrite-prose-directives*
  '("Rewrite this passage to be clearer and more direct. Keep the author's voice."
    "Say this in fewer words, and lose nothing."
    "Correct the grammar and the spelling. Change nothing else."
    "Say this in plain language."))

(define *llm-rewrite-code-directives*
  '("Refactor this code. Keep its behaviour, its interface, and the file's style."
    "Name these things for what they are."
    "Handle the cases this code misses."
    "Document this: a docstring for what it is, comments only for what the code cannot say."))

(define (llm-rewrite--prose? buf)
  (let ((mode (buffer-local buf 'mode-name)))
    (or (not mode) (member mode *llm-rewrite-prose-modes*))))

(define (llm-rewrite-directives buf)
  (if (llm-rewrite--prose? buf)
      (append *llm-rewrite-prose-directives* *llm-rewrite-code-directives*)
      (append *llm-rewrite-code-directives* *llm-rewrite-prose-directives*)))

(define (llm-rewrite-prompt buf directive passage)
  (string-append
    "You rewrite one passage of a document open in a text editor"
    (let ((mode (buffer-local buf 'mode-name)))
      (if mode (string-append " (" mode ")") ""))
    ".\n\nInstruction: " directive
    "\n\nPassage:\n" passage
    "\n\nReply with ONLY the rewritten passage. No commentary, no quotes and "
    "no code fences. Keep the indentation of every line, and add no heading, "
    "preface or trailing blank line."))

(define (llm-rewrite--drop-blank-front lines)
  (if (and (pair? lines) (equal? (string-trim (car lines)) ""))
      (llm-rewrite--drop-blank-front (cdr lines))
      lines))

(define (llm-rewrite--trim-blank-edges lines)
  (reverse (llm-rewrite--drop-blank-front
             (reverse (llm-rewrite--drop-blank-front lines)))))

;; The passage it answers has no fence, so the rewrite gains none; blank
;; edges go, and the first line's own indentation stays.
(define (llm-rewrite-clean reply)
  (let* ((lines (llm-rewrite--trim-blank-edges (string-split reply "\n")))
         (fenced (and (>= (length lines) 2)
                      (string-prefix? "```" (car lines))
                      (string-prefix? "```" (car (reverse lines))))))
    (string-join
      (if fenced
          (llm-rewrite--trim-blank-edges (reverse (cdr (reverse (cdr lines)))))
          lines)
      "\n")))

;;; --- ask and land ------------------------------------------------------------

;; Each passage owns its options and conversation. These document locals
;; survive checkpoints; tracking overlays follow edits above the passage.
(define (llm-rewrite--session buf)
  (let ((id (buffer-local buf 'rewrite-active)))
    (find (lambda (s) (equal? (plist-get s 'id) id))
          (or (buffer-local buf 'rewrite-sessions) '()))))

(define (llm-rewrite--save-session! buf s)
  (let* ((source (block-overlay-span buf (llm-rewrite--face s "source")))
         (block (block-overlay-span buf (llm-rewrite--face s "block")))
         (s (if source (plist-put s 'source source) s))
         (s (if block (plist-put s 'block block) s)))
    (buffer-set-local! buf 'rewrite-sessions
      (cons s (filter (lambda (old)
                        (not (equal? (plist-get old 'id) (plist-get s 'id))))
                      (or (buffer-local buf 'rewrite-sessions) '()))))
    s))

(define (llm-rewrite--face s part)
  (string-append "rewrite-" (plist-get s 'id) "-" part))

(define (llm-rewrite--range buf s part)
  (or (block-overlay-span buf (llm-rewrite--face s part))
      (plist-get s (string->symbol part))))

(define (llm-rewrite--track! buf s part span)
  (let ((face (llm-rewrite--face s part)))
    (overlay-set! buf face (list (append span (list face)))))
  (llm-rewrite--save-session! buf
    (plist-put s (string->symbol part) span)))

(define (llm-rewrite--new-session! buf start end original)
  (let* ((id (string-append (number->string (monotonic-ms)) "-"
                            (number->string (length (or (buffer-local buf 'rewrite-sessions) '())))))
         (s (list 'id id 'source (list start end) 'current original
                  'options (list (list "Original" original))
                  'history "" 'chat (string-append "*rewrite-chat:" id "*"))))
    (buffer-set-local! buf 'rewrite-active id)
    (llm-rewrite--track! buf s "source" (list start end))
    (llm-rewrite--restore! buf)
    (llm-rewrite--session buf)))

(define (llm-rewrite--chat! buf s)
  (let ((chat (plist-get s 'chat)))
    (unless (buffer-known? chat)
      (buffer-create chat)
      (buffer-set-local! chat 'default-directory (buffer-directory buf))
      (when (buffer-group buf) (chat-set-group! chat (buffer-group buf)))
      (buffer-append! chat (plist-get s 'history))
      (with-current-buffer chat (lambda () (set-mode! "chat-mode")))
      (buffer-context-only! chat))
    chat))

(define (llm-rewrite--record! buf role text)
  (let* ((s (llm-rewrite--session buf))
         (part (string-append "\n### " role "\n" text "\n"))
         (chat (llm-rewrite--chat! buf s)))
    (buffer-append! chat part)
    (llm-rewrite--save-session! buf
      (plist-put s 'history (string-append (plist-get s 'history) part)))))

(define (llm-rewrite--options-text s)
  (let* ((rows (plist-get s 'options))
         (body (string-join
                 (map (lambda (i)
                        (let ((row (nth i rows)))
                          (string-append "Option " (number->string i) ": "
                                         (car row) "\n\n" (cadr row))))
                      (iota (length rows))) "\n\n"))
         (fence (let loop ((f "```"))
                  (if (string-index body f) (loop (string-append f "`")) f))))
    (string-append fence "options\n" body "\n" fence)))

(define (llm-rewrite--options-valid? buf s)
  (let ((span (llm-rewrite--range buf s "block")))
    (or (not span)
        (equal? (block-text-at buf (car span) (cadr span))
                (plist-get s 'rendered)))))

(define (llm-rewrite--paint-options! buf &optional given)
  (let* ((s (or given (llm-rewrite--session buf)))
         (span (llm-rewrite--range buf s "block")))
    (when span
      (fold-set! buf (llm-rewrite--face s "fold")
        (if (plist-get s 'hidden)
            (list (list (+ (car span)
                           (string-byte-length
                             (car (string-split (plist-get s 'rendered) "\n"))))
                        (cadr span)))
            '())))))

(define (llm-rewrite--write-options! buf)
  (let* ((s (llm-rewrite--session buf))
         (span (llm-rewrite--range buf s "block"))
         (text (llm-rewrite--options-text s)))
    (if (not (llm-rewrite--options-valid? buf s))
        (begin (message "Options were edited; they stay unchanged") #f)
        (let ((bounds
                (if span
                    (begin
                      (buffer-delete-range! buf (car span) (- (cadr span) (car span)))
                      (buffer-insert! buf (car span) text)
                      (list (car span) (+ (car span) (string-byte-length text))))
                    (let* ((p (diff-block-pending buf))
                           (ds (and p (diff-block--spans buf)))
                           (source (llm-rewrite--range buf s "source"))
                           (at (if ds
                                   (+ (nth 3 ds) (string-byte-length (diff-block--tail p)))
                                   (cadr source))))
                      (block-land! buf at text (block-tail-for buf at))))))
          (llm-rewrite--track! buf
            (plist-put (llm-rewrite--session buf) 'rendered text) "block" bounds)
          (llm-rewrite--paint-options! buf)
          #t))))

(define (llm-rewrite--keep-option! buf)
  (let* ((p (diff-block-pending buf))
         (spans (and p (diff-block--spans buf)))
         (s (llm-rewrite--session buf))
         (block (and spans (block-text-at buf (nth 2 spans) (nth 3 spans)))))
    (cond ((not (and s block)) (message "No rewrite is waiting"))
          ((not (llm-rewrite--options-valid? buf s))
           (message "Options were edited; they stay unchanged"))
          (else
            (let* ((text (diff-block--accept-text p block))
                   (rows (plist-get s 'options)))
              (unless (find (lambda (r) (equal? (cadr r) text)) rows)
                (llm-rewrite--save-session! buf
                  (plist-put s 'options
                    (append rows (list (list (diff-block-note p) text))))))
              (when (llm-rewrite--write-options! buf)
                (message "Kept as an option; the passage is unchanged")))))))

(define (llm-rewrite--toggle-options! buf)
  (let ((s (llm-rewrite--session buf)))
    (if (and s (llm-rewrite--range buf s "block"))
        (begin
          (llm-rewrite--save-session! buf (plist-put s 'hidden (not (plist-get s 'hidden))))
          (llm-rewrite--paint-options! buf))
        (message "No saved options for this passage"))))

(define (llm-rewrite--choose-option! buf n)
  (let* ((s (llm-rewrite--session buf))
         (rows (and s (plist-get s 'options)))
         (source (and s (llm-rewrite--range buf s "source"))))
    (cond
      ((not (and rows (integer? n) (>= n 0) (< n (length rows))))
       (message "No such option"))
      ((not (equal? (block-text-at buf (car source) (cadr source)) (plist-get s 'current)))
       (message "The passage changed; no option was applied"))
      ((diff-block-pending buf)
       (diff-block-reject! buf)
       (unless (diff-block-pending buf) (llm-rewrite--choose-option! buf n)))
      (else
        (let ((text (cadr (nth n rows))))
          (buffer-delete-range! buf (car source) (- (cadr source) (car source)))
          (buffer-insert! buf (car source) text)
          (llm-rewrite--track! buf
            (plist-put s 'current text) "source"
            (list (car source) (+ (car source) (string-byte-length text))))
          (message (string-append "Chose option " (number->string n))))))))

(define (llm-rewrite--locate! buf)
  (let ((pt (with-current-buffer buf (lambda () (point)))))
    (let ((s (find
               (lambda (s)
                 (let ((src (llm-rewrite--range buf s "source"))
                       (block (llm-rewrite--range buf s "block")))
                   (or (and src (<= (car src) pt) (<= pt (cadr src)))
                       (and block (<= (car block) pt) (<= pt (cadr block))))))
               (or (buffer-local buf 'rewrite-sessions) '()))))
      (when s (buffer-set-local! buf 'rewrite-active (plist-get s 'id)))
      s)))

(define (llm-rewrite--options-menu! buf)
  (let* ((s (llm-rewrite--session buf))
         (rows (plist-get s 'options))
         (choices (map (lambda (i) (string-append "choose option " (number->string i)))
                       (iota (length rows)))))
    (minibuffer-read "Options (choose / show options / hide options / instruction): "
      (append choices '("show options" "hide options" "show chat") (llm-rewrite-directives buf))
      (lambda (input)
        (let* ((answer (string-trim input))
               (n (and (string-prefix? "choose option " answer)
                       (string->number (substring-bytes answer 14 (string-byte-length answer))))))
          (cond ((equal? answer "") #f)
                (n (llm-rewrite--choose-option! buf n))
                ((member answer '("show options" "hide options"))
                 (llm-rewrite--save-session! buf
                   (plist-put (llm-rewrite--session buf) 'hidden (equal? answer "hide options")))
                 (llm-rewrite--paint-options! buf))
                ((equal? answer "show chat")
                 (display-buffer-other-window! (llm-rewrite--chat! buf (llm-rewrite--session buf))))
                (else
                  (let* ((s (llm-rewrite--session buf))
                         (span (llm-rewrite--range buf s "source"))
                         (old (plist-get s 'current)))
                    (llm-rewrite--ask! buf old answer
                      (lambda (new)
                        (llm-rewrite--propose! buf (car span) (cadr span) old new answer)))))))))))

(define (llm-rewrite--ask! buf passage directive land)
  (let* ((s (or (llm-rewrite--session buf)
                (llm-rewrite--new-session! buf 0 0 passage)))
         (id (plist-get s 'id))
         (token (list (monotonic-ms) (string-byte-length (plist-get s 'history)))))
    (llm-rewrite--record! buf "You" (llm-rewrite-prompt buf directive passage))
    (llm-rewrite--save-session! buf
      (plist-put (llm-rewrite--session buf) 'request token))
    (message "LLM rewriting...")
    (llm (string-append
           "Continue this rewrite conversation. Earlier instructions and replies are context.\n"
           (plist-get (llm-rewrite--session buf) 'history))
      (lambda (reply)
        (let* ((live (and (buffer-exists? buf) (llm-rewrite--session buf)))
               (new (llm-rewrite-clean reply)))
          (cond
            ((not (and live (equal? (plist-get live 'id) id)
                       (equal? (plist-get live 'request) token)))
             (message "Discarded a superseded rewrite"))
            ((equal? new "") (message "The model returned nothing"))
            (else
              (llm-rewrite--record! buf "Assistant" new)
              (land new))))))))

(define (llm-rewrite--propose! buf start end original new directive)
  (unless (llm-rewrite--session buf)
    (llm-rewrite--new-session! buf start end original))
  (if (equal? (diff-block-propose! buf start end original new directive) 'ok)
      (message "Rewrite waiting: C-c e to decide, keep as option, or iterate")
      (message "Rewrite dropped - that passage has changed")))

(define (llm-rewrite--refine! buf new directive)
  (let ((r (diff-block-update! buf new directive)))
    (cond ((equal? r 'gone) (message "The waiting rewrite is gone"))
          ((equal? r 'edited)
           (message "The rewrite has been edited — the new version was dropped"))
          (else (message (string-append "Rewrite refined · "
                                        (key-for-command "llm-rewrite")
                                        " decides"))))))

;; An empty answer at the prompt takes the instruction the mode leads with.
(define (llm-rewrite--directive buf input)
  (let ((typed (string-trim input)))
    (if (equal? typed "") (car (llm-rewrite-directives buf)) typed)))

(define (llm-rewrite--start! buf)
  (let* ((start (and (mark) (region-beginning)))
         (end (and start (region-end)))
         (old (and start (block-text-at buf start end))))
    (if (or (not old) (equal? old ""))
        (message "No region - set the mark first (C-SPC)")
        (begin
          (set-mark! #f)
          (minibuffer-read "Rewrite region: " (llm-rewrite-directives buf)
            (lambda (input)
              (let ((directive (llm-rewrite--directive buf input)))
                (llm-rewrite--new-session! buf start end old)
                (llm-rewrite--ask! buf old directive
                  (lambda (new)
                    (llm-rewrite--propose! buf start end old new directive))))))))))

;;; --- the review loop ---------------------------------------------------------
;; One key decides. The block's own keys live only in the buffer that
;; holds it, and a key nobody can reach from the window they are looking
;; at is no key at all — so the same C-c e that made the rewrite also
;; ends it. The verbs are exact answers, which leaves an instruction that
;; happens to start with "keep" an instruction.

(define *llm-rewrite-keep-answer* "keep it")
(define *llm-rewrite-back-answer* "put it back")

(define (llm-rewrite--review! buf p answer)
  (let ((state (diff-block-answer-state answer)))
    (cond
      ((equal? answer "") (message "Rewrite still waiting"))
      ((string-prefix? "choose option " answer)
       (llm-rewrite--choose-option! buf (string->number (substring-bytes answer 14 (string-byte-length answer)))))
      ((equal? answer "keep as option") (llm-rewrite--keep-option! buf))
      ((member answer '("show options" "hide options"))
       (let ((s (llm-rewrite--session buf)))
         (when s
           (llm-rewrite--save-session! buf (plist-put s 'hidden (equal? answer "hide options")))
           (llm-rewrite--paint-options! buf))))
      ((equal? answer "show chat")
       (let ((s (llm-rewrite--session buf)))
         (when s (display-buffer-other-window! (llm-rewrite--chat! buf s)))))
      ((equal? answer *llm-rewrite-keep-answer*) (diff-block-accept! buf))
      ((equal? answer *llm-rewrite-back-answer*) (diff-block-reject! buf))
      (state (diff-block-set-state! buf state))
      (else
        (llm-rewrite--ask! buf (diff-block-theirs p) answer
          (lambda (new) (llm-rewrite--refine! buf new answer)))))))

(define (llm-rewrite--again! buf p)
  (if (not (diff-block--spans buf))
      (begin (diff-block-release! buf) (message "The waiting rewrite is gone"))
      (minibuffer-read
        "Rewrite (keep it / keep as option / put it back / show options / instruction): "
        (append (let ((s (llm-rewrite--session buf)))
                  (if s (map (lambda (i) (string-append "choose option " (number->string i)))
                             (iota (length (plist-get s 'options)))) '()))
                (list *llm-rewrite-keep-answer* "keep as option"
                      *llm-rewrite-back-answer* "show options" "hide options" "show chat")
                (diff-block-state-answers (diff-block-state p))
                (llm-rewrite-directives buf))
        (lambda (input) (llm-rewrite--review! buf p (string-trim input))))))

;; Rebuild presentation after mode setup or desktop restore. The watch keeps
;; checkpoint offsets current, including edits made above a saved passage.
(define (llm-rewrite--checkpoint! buf)
  (when (buffer-exists? buf)
    (for-each
      (lambda (s)
        (let ((saved (llm-rewrite--save-session! buf s)))
          (llm-rewrite--paint-options! buf saved)))
      (or (buffer-local buf 'rewrite-sessions) '()))))

(define (llm-rewrite--restore! &optional named)
  (let* ((buf (or named (current-buffer)))
         (sessions (or (buffer-local buf 'rewrite-sessions) '())))
    (when (pair? sessions)
      (for-each
        (lambda (s)
          (for-each
            (lambda (part)
              (let* ((span (plist-get s (string->symbol part)))
                     (expected (if (equal? part "source") (plist-get s 'current)
                                   (plist-get s 'rendered))))
                (when (and span expected
                           (equal? (block-text-at buf (car span) (cadr span)) expected))
                  (let ((face (llm-rewrite--face s part)))
                    (overlay-set! buf face (list (append span (list face))))))))
            '("source" "block"))
          (llm-rewrite--paint-options! buf s))
        sessions)
      (let ((old (buffer-local buf 'rewrite-change-handler)))
        (when old (remove-on-change! old)))
      (buffer-set-local! buf 'rewrite-change-handler
        (on-change! buf (lambda (pos inserted deleted source)
                          (llm-rewrite--checkpoint! buf)) 'eager))
      (let ((p (diff-block-pending buf)))
        (when p
          (diff-block--bind-keys! buf)
          (diff-block--paint! buf (diff-block--spans buf) (diff-block-state p)))))))

(add-hook! 'after-change-major-mode-hook 'llm-rewrite--restore!)

;; The diff owns accept/reject keys. Its decision hook keeps options attached
;; when the user decides through those keys rather than the review prompt.
(define (llm-rewrite--decided! buf decision start old new)
  (let ((s (llm-rewrite--session buf)))
    (when (and s (equal? (plist-get s 'current) old))
      (let* ((span (llm-rewrite--range buf s "block"))
             (s (if span (plist-put s 'block span) s)))
        (llm-rewrite--track! buf (plist-put s 'current new) "source"
          (list start (+ start (string-byte-length new))))
        (llm-rewrite--paint-options! buf)))))

(add-hook! 'diff-block-decision-hook 'llm-rewrite--decided!)

(domain! 'llm)
(effects! '(write))
(define-command "llm-rewrite-keep-option"
  "Save the waiting rewrite into the passage's options block"
  (lambda () (llm-rewrite--keep-option! (current-buffer))))
(define-command "llm-rewrite-toggle-options"
  "Show or hide the saved options for this passage"
  (lambda ()
    (let ((buf (current-buffer)))
      (llm-rewrite--locate! buf)
      (llm-rewrite--toggle-options! buf))))
(define-command "llm-rewrite-choose-option"
  "Choose a saved rewrite or restore the original"
  (lambda ()
    (let ((buf (current-buffer)))
      (llm-rewrite--locate! buf)
      (if (llm-rewrite--session buf)
          (llm-rewrite--options-menu! buf)
          (message "No options for this passage")))))
(effects! '(write external spend))

(define-command "llm-rewrite"
  "Rewrite the region; keep drafts as options and iterate with the passage's conversation"
  (lambda ()
    (let* ((buf (current-buffer)) (p (diff-block-pending buf)))
      (cond (p (llm-rewrite--again! buf p))
            ((and (not (mark)) (llm-rewrite--locate! buf))
             (llm-rewrite--options-menu! buf))
            (else (llm-rewrite--start! buf))))))

(define-key "mode-specific-map" "e" "llm-rewrite")
(catalog-meta! 'command "llm-rewrite"
  'domain "llm" 'effects '("write" "external" "spend"))

;; Do not leak this action's catalog context into the loader.
(domain! 'unknown)
(effects! '(unknown))
