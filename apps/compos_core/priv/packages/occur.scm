;;; occur.scm --- structural search with tree-sitter queries.
;;;
;;; ts-filter is the reusable data API. occur-ts presents those captures as
;;; a normal list, so preview, narrowing, restore, and keyboard motion use the
;;; same contracts as ibuffer and the other result modes.

(package! 'occur)
(category! 'search)
(effects! '(read))

(define (occur-ts--source-text source)
  (cond ((buffer-exists? source) (buffer-text source))
        ((file-exists? source) (read-file source))
        (else (error "ts-filter: no buffer or file" source))))

(define (occur-ts--line-text text line)
  (let ((lines (string-split text "\n")))
    (if (and (> line 0) (<= line (length lines)))
        (nth (- line 1) lines)
        "")))

;; One capture becomes a plist. Byte ranges remain the source of truth, and
;; the line fields make the result useful to readers and agents.
(define (occur-ts--entry text cap)
  (let* ((capture (car cap))
         (start (cadr cap))
         (end (caddr cap))
         (line (length (string-split (substring-bytes text 0 start) "\n"))))
    (list 'capture capture
          'start start
          'end end
          'line line
          'match (substring-bytes text start end)
          'text (occur-ts--line-text text line))))

(define (ts-filter source language query)
  (let ((text (occur-ts--source-text source)))
    (map (lambda (cap) (occur-ts--entry text cap))
         (ts-query-string language text query))))

(public! 'ts-filter
  "(ts-filter SOURCE LANGUAGE QUERY) -> capture plists with byte ranges, line numbers, matches, and source lines")
(public! 'ts-query-string
  "(ts-query-string LANGUAGE TEXT QUERY) -> (CAPTURE START END) ranges for detached text")

(define *occur-ts-buffer* "*occur-ts*")
(define *occur-ts-doc*
  (string-append
    "This list shows every capture from one tree-sitter query. "
    "Each row shows the source line, capture name, and source text. "
    "Moving previews the capture. RET visits it. "
    "Use `/` to narrow the rows and `g` to run the query again."))

(define (occur-ts--value entry key) (plist-get entry key))

(define (occur-ts--rows buf)
  (let ((rows (ts-filter (buffer-local buf 'occur-ts-source)
                         (buffer-local buf 'occur-ts-language)
                         (buffer-local buf 'occur-ts-query))))
    (desktop-skip! buf 'occur-ts-total)
    (buffer-set-local! buf 'occur-ts-total (length rows))
    rows))

(define (occur-ts--key buf entry)
  (string-append (occur-ts--value entry 'capture) ":"
                 (number->string (occur-ts--value entry 'start)) ":"
                 (number->string (occur-ts--value entry 'end))))

(define (occur-ts--cells buf entry)
  (list (number->string (occur-ts--value entry 'line))
        (list (occur-ts--value entry 'capture) "accent")
        (string-trim (occur-ts--value entry 'text))))

(define (occur-ts--meta buf)
  (string-append
    (number->string (or (buffer-local buf 'occur-ts-total) 0)) " captures · "
    (buffer-local buf 'occur-ts-language) " · "
    (buffer-short-label (buffer-local buf 'occur-ts-source))))

(define (occur-ts--show entry select?)
  (let* ((results (current-buffer))
         (source (buffer-local results 'occur-ts-source))
         (start (occur-ts--value entry 'start)))
    (when (buffer-exists? source)
      ;; a peek of the searched buffer: it exists, so it is only shown
      (peek! source (lambda () source))
      (let ((win (window-showing source)))
        (buffer-goto! source start)
        (when (and select? win (window-exists? win))
          (select-window! win)
          (switch-to-buffer! source)
          (goto-char! start))))))

(effects! '(write))

(define-command "occur-ts-visit" "Visit the tree-sitter capture on this row"
  (lambda ()
    (let ((entry (list-current (current-buffer))))
      (when entry (occur-ts--show entry #t)))))

(define-command "occur-ts-refresh" "Run this tree-sitter query again"
  (lambda () (list-refresh! (current-buffer))))

(when (boundp (quote mode-icon!))
  (mode-icon! "occur-ts-mode" ""))

(define-list-mode! "occur-ts-mode"
  (list
    'doc *occur-ts-doc*
    'buffer *occur-ts-buffer*
    'rows occur-ts--rows
    'key occur-ts--key
    'columns (lambda (buf)
               (list (list "line" 6 'right)
                     (list "capture" 16)
                     (list "text" #f)))
    'cells occur-ts--cells
    'title (lambda (buf) "Tree-sitter matches")
    'meta occur-ts--meta
    'total (lambda (buf) (or (buffer-local buf 'occur-ts-total) 0))
    'footer (lambda (buf)
              '(("RET" "visit") ("/" "filter") ("\\" "widen")
                ("g" "refresh") ("q" "quit")))
    'noun "capture"
    'preview (lambda (buf entry) (occur-ts--show entry #f))
    'keys '(("RET" "occur-ts-visit")
            ("g" "occur-ts-refresh")
            ("q" "quit-window"))))

;; define-list-mode! records the prose before define-mode registers its default
;; catalog row. Restamp the catalog row after both registrations exist.
(mode-doc! "occur-ts-mode" *occur-ts-doc*)

(define (occur-ts-open source language query)
  (unless (member language (ts-langs))
    (error "occur-ts: grammar is not loaded" language))
  (occur-ts--source-text source)
  (buffer-create *occur-ts-buffer*)
  (buffer-set-local! *occur-ts-buffer* 'occur-ts-source source)
  (buffer-set-local! *occur-ts-buffer* 'occur-ts-language language)
  (buffer-set-local! *occur-ts-buffer* 'occur-ts-query query)
  (list-mode-show! "occur-ts-mode"))

(define (occur-ts--read-query source language)
  (minibuffer-read "Tree-sitter query: " (history-items 'occur-ts-query)
    (lambda (query)
      (if (equal? (string-trim query) "")
          (message "occur-ts needs a query")
          (begin
            (history-push! 'occur-ts-query query)
            (occur-ts-open source language query))))))

(define-command "occur-ts" "Show tree-sitter query captures for this buffer"
  (lambda ()
    (let* ((source (current-buffer))
           (language (buffer-local source 'ts-lang)))
      (if language
          (occur-ts--read-query source language)
          (minibuffer-read "Grammar: "
            (map (lambda (lang) (list lang lang)) (ts-langs))
            (lambda (lang)
              (if (equal? (string-trim lang) "")
                  (message "occur-ts needs a grammar")
                  (occur-ts--read-query source lang))))))))

(define-key "search-map" "t" "occur-ts")

(public! 'occur-ts-open
  "(occur-ts-open SOURCE LANGUAGE QUERY) -> show a selectable structural-search result list")
