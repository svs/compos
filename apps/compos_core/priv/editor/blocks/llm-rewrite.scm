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
    "\n\nWords in single square brackets or angle brackets, such as [a word for X] "
    "or <make this punchier>, are the author's instruction: carry it out in that "
    "place and drop the brackets. A [[link]], [text](url), <https://...> or an "
    "HTML tag such as <br> is not an instruction."
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

;; An options span counts only while it still holds an options block: a span
;; left over from text that went away must not stand for the block.
(define (llm-rewrite--options-at? buf span)
  (and (<= 0 (car span)) (< (car span) (cadr span)) (<= (cadr span) (buffer-size buf))
       (let ((head (car (string-split (block-text-at buf (car span) (cadr span)) "\n"))))
         (and (string-prefix? "```" head) (string-index head "options") #t))))

(define (llm-rewrite--range buf s part)
  (let ((span (or (block-overlay-span buf (llm-rewrite--face s part))
                  (plist-get s (string->symbol part)))))
    (if (and span (equal? part "block") (not (llm-rewrite--options-at? buf span)))
        #f
        span)))

;; The passage stays selected for the whole session, across prompts,
;; iterations and choices, until the rewrite is cancelled.
(defface! 'rewrite-selection 'bg "var(--region-bg)")

;; Saved drafts are reference, not prose: smaller and dimmer than the text.
(defface! 'rewrite-options 'size "0.8em" 'fg "var(--dim-fg)")

(define (llm-rewrite--paint-options-face! buf)
  (overlay-set! buf 'rewrite-options
    (filter (lambda (x) x)
      (map (lambda (s)
             (let ((span (llm-rewrite--range buf s "block")))
               (and span (list (car span) (cadr span) "rewrite-options"))))
           (or (buffer-local buf 'rewrite-sessions) '())))))

(define (llm-rewrite--paint-selection! buf)
  (let* ((s (llm-rewrite--session buf))
         (span (and s (not (plist-get s 'released)) (llm-rewrite--range buf s "source"))))
    (overlay-set! buf 'rewrite-selection
      (if span (list (list (car span) (cadr span) "rewrite-selection")) '()))))

;; Setting the mark again lets the lasting selection go: the highlight
;; clears, while the rewrite, its blocks and its keys stay.
(define (llm-rewrite--release-on-mark!)
  (let ((buf (current-buffer)))
    (when (and (buffer-local buf 'rewrite-active) (mark))
      (let ((s (llm-rewrite--session buf)))
        (when (and s (not (plist-get s 'released)))
          (llm-rewrite--save-session! buf (plist-put s 'released #t))
          (overlay-clear! buf 'rewrite-selection))))))

(add-hook! 'post-command-hook 'llm-rewrite--release-on-mark!)

(define (llm-rewrite--track! buf s part span)
  (let ((face (llm-rewrite--face s part)))
    (overlay-set! buf face (list (append span (list face)))))
  (when (and (equal? part "source") (not (plist-get s 'released)))
    (overlay-set! buf 'rewrite-selection
      (list (list (car span) (cadr span) "rewrite-selection"))))
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
      (buffer-append! chat (plist-get s 'history)))
    (buffer-set-local! chat 'context-only #f)
    (llm-mode--companion! buf (buffer-llm-model buf) (buffer-group buf) chat)))

(define (llm-rewrite--record! buf role text)
  (let* ((s (llm-rewrite--session buf))
         (part (string-append "\n### " role "\n" text "\n"))
         (chat (llm-rewrite--chat! buf s)))
    (chat-render! chat part)
    (llm-rewrite--save-session! buf
      (plist-put s 'history (string-append (plist-get s 'history) part)))))

(define *llm-rewrite-option-keys*
  '(("C-c p" "llm-rewrite-promote-option" "promote")
    ("C-c r" "llm-rewrite-iterate" "again")
    ("C-c t" "llm-rewrite-toggle-options" "fold")
    ("C-c h" "llm-rewrite-show-chat" "chat")
    ("C-c x" "llm-rewrite-cancel" "cancel")))

;; The block's fence line names its keys, the way a diff block's does.
;; Folded, it says only how many drafts it holds: a quiet line in the prose.
(define (llm-rewrite--options-head s)
  (if (plist-get s 'hidden)
      (let ((n (- (length (plist-get s 'options)) 1)))
        (string-append "options · " (number->string n) (if (= n 1) " draft" " drafts")))
      (string-append "options "
        (string-join (map (lambda (k) (string-append (car k) " " (caddr k)))
                          *llm-rewrite-option-keys*) " · "))))

(define (llm-rewrite--option-row-text rows i)
  (let ((row (nth i rows)))
    (string-append "Option " (number->string i) ": " (car row) "\n\n" (cadr row))))

(define (llm-rewrite--options-prompt-edits s text)
  (let* ((drop (lambda (s n) (substring-bytes s n (string-byte-length s))))
         (rows (plist-get s 'options))
         (rendered (plist-get s 'rendered))
         (lines (string-split rendered "\n"))
         (head (car lines))
         (fence (nth (- (length lines) 1) lines))
         (header (string-append head "\n")))
    (and (equal? (string-index text header) 0)
         (let loop ((i 1)
                    (rest (drop text (string-byte-length header)))
                    (out (list (car rows))))
           (if (= i (length rows))
               (and (equal? rest (string-append "\n" fence)) out)
               (let* ((row (nth i rows))
                      (prefix (string-append "Option " (number->string i) ": "))
                      (draft (cadr row)))
                 (and (equal? (string-index rest prefix) 0)
                      (let* ((after-prefix (drop rest (string-byte-length prefix)))
                             (sep (string-index after-prefix "\n\n")))
                        (and sep
                             (let* ((prompt (substring-bytes after-prefix 0 sep))
                                    (after-prompt (drop after-prefix (+ sep 2))))
                               (and (equal? (string-index after-prompt draft) 0)
                                    (let ((after-draft (drop after-prompt (string-byte-length draft))))
                                      (if (= (+ i 1) (length rows))
                                          (and (equal? after-draft (string-append "\n" fence))
                                               (append out (list (list prompt draft))))
                                          (and (equal? (string-index after-draft "\n\n") 0)
                                               (loop (+ i 1)
                                                     (drop after-draft 2)
                                                     (append out (list (list prompt draft))))))))))))))))))

(define (llm-rewrite--options-text s)
  (let* ((rows (plist-get s 'options))
         (body (string-join
                 ;; Only saved drafts are shown.
                 (map (lambda (i) (llm-rewrite--option-row-text rows i))
                      (cdr (iota (length rows)))) "\n\n"))
         (fence (let loop ((f "```"))
                  (if (string-index body f) (loop (string-append f "`")) f))))
    (string-append fence (llm-rewrite--options-head s) "\n" body "\n" fence)))

;; Which saved row holds byte POS of the block, or #f on its fence lines.
(define (llm-rewrite--option-at buf s pos)
  (let* ((span (llm-rewrite--range buf s "block"))
         (rows (plist-get s 'options))
         (rendered (plist-get s 'rendered)))
    (and span rendered (<= (car span) pos) (<= pos (cadr span))
         (let loop ((i 1)
                    (at (+ (car span) 1 (string-byte-length
                                          (car (string-split rendered "\n"))))))
           (and (< i (length rows))
                (let ((end (+ at (string-byte-length (llm-rewrite--option-row-text rows i)))))
                  (if (< pos (+ end 2)) (and (<= at pos) i) (loop (+ i 1) (+ end 2)))))))))

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
            '())))
    (llm-rewrite--paint-options-face! buf)))

(define (llm-rewrite--option-key-pairs)
  (map (lambda (k) (list (car k) (cadr k))) *llm-rewrite-option-keys*))

(define (llm-rewrite--bind-option-keys! buf)
  (block-bind-keys! buf (llm-rewrite--option-key-pairs)))

(define (llm-rewrite--write-options! buf)
  (let* ((s (llm-rewrite--session buf))
         (span (llm-rewrite--range buf s "block"))
         (text (llm-rewrite--options-text s)))
    (if (not (llm-rewrite--options-valid? buf s))
        (begin (message "Options were edited; they stay unchanged") #f)
        (let ((bounds
                (if span
                    (begin
                      (buffer-set-local! buf 'rewrite-writing #t)
                      (diff-block-replace-span! buf (car span) (cadr span) text)
                      (buffer-set-local! buf 'rewrite-writing #f)
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
          (llm-rewrite--bind-option-keys! buf)
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
                    (append rows (list (list (let ((note (diff-block-note p)))
                                               (if (member note (list "" *llm-rewrite-self-directive*))
                                                   "following the passage's notes"
                                                   note))
                                             text))))))
              (when (llm-rewrite--write-options! buf)
                (message "Kept as an option; the passage is unchanged")))))))

(define (llm-rewrite--toggle-options! buf)
  (let* ((s (llm-rewrite--session buf))
         (span (and s (llm-rewrite--range buf s "block"))))
    (if span
        (let ((hide (not (plist-get s 'hidden)))
              (pt (buffer-point buf)))
          (llm-rewrite--save-session! buf (plist-put s 'hidden hide))
          ;; the fence line changes with the fold, so the block is redrawn
          (llm-rewrite--write-options! buf)
          ;; folding keeps the cursor on the block's fence line, not past it
          (when (and hide (<= (car span) pt) (<= pt (cadr span)))
            (buffer-goto! buf (car span))))
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
          (diff-block-replace-span! buf (car source) (cadr source) text)
          (llm-rewrite--track! buf
            (plist-put s 'current text) "source"
            (list (car source) (+ (car source) (string-byte-length text))))
          (message (if (= n 0) "Put the original back"
                       (string-append "Promoted option " (number->string n)))))))))

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
  (minibuffer-read "Rewrite instruction (blank: the selection is the instruction): "
    (llm-rewrite-directives buf)
    (lambda (input)
      (let* ((s (llm-rewrite--session buf))
             (span (llm-rewrite--range buf s "source"))
             (old (plist-get s 'current))
             (directive (llm-rewrite--directive buf input)))
        (llm-rewrite--ask! buf old directive
          (lambda (new)
            (llm-rewrite--propose! buf (car span) (cadr span) old new directive)))))))

;; Notes are the author's instructions in place: [a word for X] or
;; <make this punchier>. A [[link]], [text](url), <https://...> or an HTML
;; tag is not one. Each note is (START END INNER), as bytes of TEXT.
(define *llm-rewrite-html-tags*
  '("a" "b" "i" "u" "s" "p" "br" "hr" "em" "strong" "div" "span" "img"
    "ul" "ol" "li" "code" "pre" "sub" "sup" "small" "table" "tr" "td" "th"
    "kbd" "mark" "details" "summary" "blockquote" "h1" "h2" "h3" "h4"))

(define (llm-rewrite--angle-note? inner)
  (let* ((t (string-trim inner))
         (bare (string-trim (if (string-suffix? "/" t) (substring-bytes t 0 (- (string-byte-length t) 1)) t))))
    (not (or (equal? t "")
             (string-prefix? "http" t) (string-prefix? "mailto:" t)
             (string-prefix? "/" t) (string-prefix? "!" t)
             (string-index t "=")
             (member (string-downcase bare) *llm-rewrite-html-tags*)))))

(define (llm-rewrite--notes text)
  (let ((n (string-byte-length text)))
    (let loop ((i 0) (out '()))
      (let* ((sq (string-index text "[" i))
             (an (string-index text "<" i))
             (at (cond ((and sq an) (min sq an)) (sq sq) (an an) (else #f))))
        (if (not at)
            (reverse out)
            (if (equal? at sq)
                (cond
                  ((equal? (string-index text "[[" at) at)
                   (let ((close (string-index text "]]" at)))
                     (if close (loop (+ close 2) out) (reverse out))))
                  (else
                    (let ((close (string-index text "]" (+ at 1))))
                      (cond ((not close) (reverse out))
                            ((and (< (+ close 1) n) (equal? (string-index text "(" (+ close 1)) (+ close 1)))
                             (loop (+ close 1) out))
                            (else
                              (loop (+ close 1)
                                    (cons (list at (+ close 1) (substring-bytes text (+ at 1) close)) out)))))))
                (let ((close (string-index text ">" (+ at 1))))
                  (cond ((not close) (reverse out))
                        ((llm-rewrite--angle-note? (substring-bytes text (+ at 1) close))
                         (loop (+ close 1)
                               (cons (list at (+ close 1) (substring-bytes text (+ at 1) close)) out)))
                        (else (loop (+ close 1) out))))))))))

(define (llm-rewrite--notes-prompt buf passage notes)
  (string-append
    "You fill the author's notes in one passage of a document open in a text editor"
    (let ((mode (buffer-local buf 'mode-name)))
      (if mode (string-append " (" mode ")") ""))
    ". Each note, in [square] or <angle> brackets, asks for the words that go in its place."
    "\n\nPassage:\n" passage
    "\n\nNotes:\n"
    (string-join (map (lambda (i) (string-append (number->string (+ i 1)) ". "
                                                 (substring-bytes passage (car (nth i notes)) (cadr (nth i notes)))))
                      (iota (length notes))) "\n")
    "\n\nReply with one line per note, as N: WORDS, where WORDS replace the note "
    "and its brackets and read naturally in the sentence. Write nothing else."))

;; N: WORDS lines -> the passage with each note filled, or #f when one is missing.
(define (llm-rewrite--fill-notes passage notes reply)
  (let* ((lines (map string-trim (string-split reply "\n")))
         (word-for
           (lambda (k)
             (let* ((tag (number->string k))
                    (line (find (lambda (l)
                                  (and (string-prefix? tag l)
                                       (> (string-byte-length l) (string-byte-length tag))
                                       (member (substring-bytes l (string-byte-length tag) (+ 1 (string-byte-length tag)))
                                               '(":" "." ")"))))
                                lines)))
               (and line
                    (let ((w (string-trim (substring-bytes line (+ 1 (string-byte-length tag)) (string-byte-length line)))))
                      (if (equal? w "") #f w))))))
         (words (map (lambda (k) (word-for (+ k 1))) (iota (length notes)))))
    (and (not (member #f words))
         (let loop ((i (- (length notes) 1)) (text passage))
           (if (< i 0)
               text
               (let ((note (nth i notes)))
                 (loop (- i 1)
                       (string-append (substring-bytes text 0 (car note))
                                      (nth i words)
                                      (substring-bytes text (cadr note) (string-byte-length text))))))))))

(define (llm-rewrite--ask! buf passage directive land)
  (let* ((s (or (llm-rewrite--session buf)
                (llm-rewrite--new-session! buf 0 0 passage)))
         (id (plist-get s 'id))
         (token (list (monotonic-ms) (string-byte-length (plist-get s 'history))))
         ;; following the notes, only the notes change: the model names the
         ;; words and the passage around them is never in its hands
         (notes (and (equal? directive *llm-rewrite-self-directive*) (llm-rewrite--notes passage)))
         (notes (and (pair? notes) notes)))
    (llm-rewrite--record! buf "You"
      (if notes (llm-rewrite--notes-prompt buf passage notes)
          (llm-rewrite-prompt buf directive passage)))
    (llm-rewrite--save-session! buf
      (plist-put (llm-rewrite--session buf) 'request token))
    (message "LLM rewriting...")
    (llm-with-model (string-append
           "Continue this rewrite conversation. Earlier instructions and replies are context.\n"
           (if (string-index (plist-get (llm-rewrite--session buf) 'history) "### Assistant")
               "This is another try: your reply must differ from every earlier reply.\n"
               "")
           (plist-get (llm-rewrite--session buf) 'history))
      (buffer-llm-model buf)
      (lambda (reply)
        (let* ((live (and (buffer-exists? buf) (llm-rewrite--session buf)))
               (new (llm-rewrite-clean reply))
               (filled (and notes (not (equal? new "")) (llm-rewrite--fill-notes passage notes new))))
          (cond
            ((not (and live (equal? (plist-get live 'id) id)
                       (equal? (plist-get live 'request) token)))
             (message "Discarded a superseded rewrite"))
            ((equal? new "") (message "The model returned nothing"))
            ((and notes (not filled))
             (llm-rewrite--record! buf "Assistant" new)
             (message "The model did not fill every note; nothing changed"))
            (else
              (llm-rewrite--record! buf "Assistant" new)
              (land (or filled new)))))))))

;; The rewrite's own verbs ride the diff block's fence line.
(define *llm-rewrite-verbs*
  '(("C-c o" "llm-rewrite-keep-option" "option")
    ("C-c r" "llm-rewrite-iterate" "again")
    ("C-c h" "llm-rewrite-show-chat" "chat")
    ("C-c x" "llm-rewrite-cancel" "cancel")))

(define (llm-rewrite--propose! buf start end original new directive)
  (unless (llm-rewrite--session buf)
    (llm-rewrite--new-session! buf start end original))
  (buffer-set-local! buf 'diff-block-verbs *llm-rewrite-verbs*)
  (if (equal? (diff-block-propose! buf start end original new directive) 'ok)
      (message "Rewrite waiting: its keys are on the block's fence line")
      (message "Rewrite dropped - that passage has changed")))

(define (llm-rewrite--refine! buf new directive)
  (let ((r (diff-block-update! buf new directive)))
    (cond ((equal? r 'gone) (message "The waiting rewrite is gone"))
          ((equal? r 'edited)
           (message "The rewrite has been edited — the new version was dropped"))
          (else (message (string-append "Rewrite refined · "
                                        (key-for-command "llm-rewrite")
                                        " decides"))))))

;; An empty answer makes the passage its own instruction: its notes say
;; what to change.
(define *llm-rewrite-self-directive*
  "The passage is its own instruction. If it has notes in [square] or <angle> brackets, carry out every note and leave every other word as the author wrote it. If it has no notes, the passage itself says what is wanted: write what it asks for.")

(define (llm-rewrite--directive buf input)
  (let ((typed (string-trim input)))
    (if (member typed (list "" *llm-rewrite-try-again*)) *llm-rewrite-self-directive* typed)))

;; Iterating, the common ask leads the list: another go at the passage's notes.
(define *llm-rewrite-try-again* "try again")

(define (llm-rewrite--iterate-choices buf)
  (cons *llm-rewrite-try-again* (llm-rewrite-directives buf)))

;; Iterate: another version through the same conversation. Blank asks the
;; passage's own notes again, from the passage as you wrote it.
(define (llm-rewrite--iterate! buf)
  (let* ((s (or (llm-rewrite--session buf) (llm-rewrite--locate! buf)))
         (n (and s (llm-rewrite--option-at buf s (point))))
         (row (and n (nth n (plist-get s 'options))))
         (option (and row (cadr row))))
    (if (not s)
        (message "No rewrite here")
        (let ((run
                (lambda (input)
                  (let* ((directive (llm-rewrite--directive buf input))
                         (s (llm-rewrite--session buf))
                         (p (diff-block-pending buf))
                         (old (plist-get s 'current))
                         (passage (cond (option option)
                                        ((and p (not (equal? directive *llm-rewrite-self-directive*))) (diff-block-theirs p))
                                        (else old))))
                    (llm-rewrite--ask! buf passage directive
                      (lambda (new)
                        (if (diff-block-pending buf)
                            (llm-rewrite--refine! buf new directive)
                            (let ((span (llm-rewrite--range buf (llm-rewrite--session buf) "source")))
                              (llm-rewrite--propose! buf (car span) (cadr span) old new directive)))))))))
          (if row
              (run (car row))
              (minibuffer-read "Iterate (blank: the selection is the instruction): "
                               (llm-rewrite--iterate-choices buf) run))))))

;; Cancel ends the session: the waiting diff goes, the selection lets go,
;; and the text, options block included, stays as it is.
(define (llm-rewrite--cancel! buf)
  (let ((s (or (llm-rewrite--session buf) (llm-rewrite--locate! buf))))
    (when (diff-block-pending buf) (diff-block-reject! buf))
    (when (diff-block-pending buf) (diff-block-release! buf))
    (overlay-clear! buf 'rewrite-selection)
    (when s
      (overlay-clear! buf (llm-rewrite--face s "source"))
      (overlay-clear! buf (llm-rewrite--face s "block"))
      (fold-set! buf (llm-rewrite--face s "fold") '())
      (buffer-set-local! buf 'rewrite-sessions
        (filter (lambda (o) (not (equal? (plist-get o 'id) (plist-get s 'id))))
                (or (buffer-local buf 'rewrite-sessions) '()))))
    (buffer-set-local! buf 'rewrite-active #f)
    (llm-rewrite--paint-options-face! buf)
    (when (null? (or (buffer-local buf 'rewrite-sessions) '()))
      (block-unbind-keys! buf (llm-rewrite--option-key-pairs)))
    (message "Rewrite cancelled; the text stays")))

(define (llm-rewrite--start-at! buf start end old)
  (minibuffer-read "Rewrite region (blank: the selection is the instruction): " (llm-rewrite-directives buf)
    (lambda (input)
      (let ((directive (llm-rewrite--directive buf input)))
        (llm-rewrite--new-session! buf start end old)
        (llm-rewrite--ask! buf old directive
          (lambda (new)
            (llm-rewrite--propose! buf start end old new directive)))))))

(define (llm-rewrite--start! buf)
  (let* ((start (and (mark) (region-beginning)))
         (end (and start (region-end)))
         (old (and start (block-text-at buf start end))))
    (if (or (not old) (equal? old ""))
        (message "No region - set the mark first (C-SPC)")
        (begin
          (set-mark! #f)
          (llm-rewrite--start-at! buf start end old)))))

;; A buffer holds one waiting diff. A new selection elsewhere parks the
;; waiting draft in its options block and takes the diff back out, then
;; starts its own rewrite; edits above the selection shift it by their size.
(define (llm-rewrite--start-elsewhere! buf start end spans)
  (let ((old (block-text-at buf start end))
        (before (buffer-size buf)))
    (set-mark! #f)
    (when (llm-rewrite--session buf) (llm-rewrite--keep-option! buf))
    (when (diff-block-pending buf) (diff-block-reject! buf))
    (if (diff-block-pending buf)
        (message "The waiting rewrite was edited; decide it first")
        (let ((shift (if (>= start (nth 3 spans)) (- (buffer-size buf) before) 0)))
          (llm-rewrite--start-at! buf (+ start shift) (+ end shift) old)))))

;;; --- the review loop ---------------------------------------------------------
;; One key decides. The block's own keys live only in the buffer that
;; holds it, and a key nobody can reach from the window they are looking
;; at is no key at all — so the same C-c e that made the rewrite also
;; ends it. The verbs are exact answers, which leaves an instruction that
;; happens to start with "keep" an instruction.


;; The prompt takes instructions only; every action is a key on the blocks.
(define (llm-rewrite--review! buf p answer)
  (cond
    ((member answer (list "" *llm-rewrite-try-again*))
     (let ((s (llm-rewrite--session buf)))
       (if (not s)
           (message "Rewrite still waiting")
           (llm-rewrite--ask! buf (plist-get s 'current) *llm-rewrite-self-directive*
             (lambda (new) (llm-rewrite--refine! buf new *llm-rewrite-self-directive*))))))
    (else
      (llm-rewrite--ask! buf (diff-block-theirs p) answer
        (lambda (new) (llm-rewrite--refine! buf new answer))))))

(define (llm-rewrite--again! buf p)
  (if (not (diff-block--spans buf))
      (begin (diff-block-release! buf) (message "The waiting rewrite is gone"))
      (minibuffer-read "Rewrite instruction (blank: the selection is the instruction): "
        (llm-rewrite--iterate-choices buf)
        (lambda (input) (llm-rewrite--review! buf p (string-trim input))))))

;; Rebuild presentation after mode setup or desktop restore. The watch keeps
;; checkpoint offsets current, including edits made above a saved passage.
;; The options block takes its keys, not typing: an edit inside it is put
;; back at once. Deleting the whole block lets it go.
(define (llm-rewrite--guard-options! buf s)
  (let* ((span (llm-rewrite--range buf s "block"))
         (rendered (plist-get s 'rendered))
         (actual (and span (block-text-at buf (car span) (cadr span))))
         (edited (and actual rendered (llm-rewrite--options-prompt-edits s actual))))
    (when (and span rendered (not (buffer-local buf 'rewrite-writing))
               (not (equal? actual rendered)))
      (if edited
          (let ((next (llm-rewrite--save-session! buf
                        (plist-put (plist-put s 'options edited) 'rendered actual))))
            (llm-rewrite--track! buf next "block" span)
            (message "Option prompt updated · C-c r reruns it"))
          (begin
            (buffer-set-local! buf 'rewrite-writing #t)
            (diff-block-replace-span! buf (car span) (cadr span) rendered)
            (buffer-set-local! buf 'rewrite-writing #f)
            (llm-rewrite--track! buf s "block"
              (list (car span) (+ (car span) (string-byte-length rendered))))
            (message "Only option prompts are editable"))))))

(define (llm-rewrite--checkpoint! buf)
  (when (buffer-exists? buf)
    (for-each
      (lambda (s)
        (llm-rewrite--guard-options! buf s)
        (let ((saved (llm-rewrite--save-session! buf
                       (or (find (lambda (o) (equal? (plist-get o 'id) (plist-get s 'id)))
                                 (or (buffer-local buf 'rewrite-sessions) '()))
                           s))))
          (llm-rewrite--paint-options! buf saved)))
      (or (buffer-local buf 'rewrite-sessions) '()))
    (llm-rewrite--paint-selection! buf)))

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
          (llm-rewrite--paint-options! buf s)
          (when (plist-get s 'block) (llm-rewrite--bind-option-keys! buf)))
        sessions)
      (llm-rewrite--paint-selection! buf)
      (let ((old (buffer-local buf 'rewrite-change-handler)))
        (when old (remove-on-change! old)))
      (buffer-set-local! buf 'rewrite-change-handler
        (on-change! buf (lambda (pos inserted deleted source)
                          (llm-rewrite--checkpoint! buf)) 'eager))
      (let ((p (diff-block-pending buf)))
        (when p
          ;; the verbs a block was proposed with may be older than these
          (buffer-set-local! buf 'diff-block-verbs *llm-rewrite-verbs*)
          (diff-block--bind-keys! buf)
          (diff-block--paint! buf (diff-block--spans buf) (diff-block-state p)))))))

(add-hook! 'after-change-major-mode-hook 'llm-rewrite--restore!)

;; The diff owns accept/reject keys. Its decision hook keeps options attached
;; when the user decides through those keys rather than the review prompt.
(define (llm-rewrite--decided! buf decision start old new)
  (let ((s (llm-rewrite--session buf)))
    (when (and s (plist-get s 'block)) (llm-rewrite--bind-option-keys! buf))
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
(define-command "llm-rewrite-promote-option"
  "Put the saved option at point in the passage's place"
  (lambda ()
    (let* ((buf (current-buffer))
           (s (llm-rewrite--locate! buf))
           (n (and s (llm-rewrite--option-at buf s (point)))))
      (cond ((not s) (message "No options for this passage"))
            ((not n) (message "Put point on an option in the options block"))
            (else (llm-rewrite--choose-option! buf n))))))





(define-command "llm-rewrite-show-chat"
  "Show the conversation behind this passage's rewrites"
  (lambda ()
    (let* ((buf (current-buffer))
           (s (or (llm-rewrite--session buf) (llm-rewrite--locate! buf))))
      (if s
          (display-buffer-other-window! (llm-rewrite--chat! buf s))
          (message "No rewrite here")))))
(define-command "llm-rewrite-cancel"
  "End this passage's rewrite: drop the waiting diff and the selection, keep the text"
  (lambda () (llm-rewrite--cancel! (current-buffer))))
(effects! '(write external spend))

(define-command "llm-rewrite-iterate"
  "Ask for another version through the passage's conversation; blank follows its notes"
  (lambda () (llm-rewrite--iterate! (current-buffer))))

(define-command "llm-rewrite"
  "Rewrite the region; keep drafts as options and iterate with the passage's conversation"
  (lambda ()
    (let* ((buf (current-buffer))
           (p (diff-block-pending buf))
           (spans (and p (diff-block--spans buf)))
           (here (and (mark) (list (region-beginning) (region-end))))
           (elsewhere (and here spans (< (car here) (cadr here))
                           (or (>= (car here) (nth 3 spans)) (<= (cadr here) (nth 0 spans))))))
      (cond (elsewhere (llm-rewrite--start-elsewhere! buf (car here) (cadr here) spans))
            (p (llm-rewrite--again! buf p))
            ((and (not (mark)) (llm-rewrite--locate! buf))
             (llm-rewrite--options-menu! buf))
            (else (llm-rewrite--start! buf))))))

(define-key "mode-specific-map" "e" "llm-rewrite")
(catalog-meta! 'command "llm-rewrite"
  'domain "llm" 'effects '("write" "external" "spend"))

;; Do not leak this action's catalog context into the loader.
(domain! 'unknown)
(effects! '(unknown))
