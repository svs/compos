;;; mermaid.scm --- draw ```mermaid fences as diagrams, in every view.
;;;
;;; One renderer for every page that shows Markdown: Linear issue pages,
;;; the preview painter (preview-mode, help pages, rendered morg) and chat
;;; replies. A diagram renders once with the Mermaid CLI (mmdc, through npx
;;; and the user's Chrome) into ~/.compos/mermaid/cache/HASH.svg. The hash
;;; covers the source and the theme, so a dark theme draws dark diagrams.
;;; A view asks (mermaid-state SRC): ready answers the SVG, a miss starts
;;; the render and answers pending. When a render ends, every function
;;; registered with mermaid-on-drawn! runs, and each view redraws itself.
;;; A failed render is remembered and shown with its error until
;;; (mermaid-forget-failures!).

(domain! 'writing)

(effects! '(pure))

(define mermaid-dir (string-append (expand-path "~/.compos/mermaid") "/"))
(define mermaid-chrome "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
(define mermaid--pending '())
(define mermaid--failed '())    ; ((KEY . ERROR) ...)
(define mermaid--drawn-fns '()) ; ((NAME . FN) ...)

;; dark when the editor's theme is dark; the hash keeps both looks apart
(define (mermaid-theme)
  (if (and (boundp 'theme-dark?) (ignore-errors (lambda () (theme-dark?)))) "dark" "default"))

(define (mermaid--key src) (content-hash (string-append (mermaid-theme) "\n" src)))
(define (mermaid--path key) (string-append mermaid-dir "cache/" key ".svg"))

(define (mermaid--setup-error)
  (and (not (file-exists? mermaid-chrome))
       (string-append "Chrome not found at " mermaid-chrome)))

(effects! '(write))

(define (mermaid-on-drawn! name fn)
  (set! mermaid--drawn-fns (cons (cons name fn) (filter (lambda (p) (not (equal? (car p) name))) mermaid--drawn-fns))))

(define (mermaid-forget-failures!) (set! mermaid--failed '()))

(define (mermaid--drawn!)
  (for-each (lambda (p) (ignore-errors (lambda () ((cdr p))))) mermaid--drawn-fns))

(effects! '(write external execute))

(define (mermaid--ensure-config!)
  (make-directory! (string-append mermaid-dir "cache"))
  (unless (file-exists? (string-append mermaid-dir "puppeteer.json"))
    (write-file! (string-append mermaid-dir "puppeteer.json")
                 (string-append "{\"executablePath\":\"" mermaid-chrome "\",\"headless\":true,\"args\":[\"--no-sandbox\",\"--disable-gpu\"]}")))
  ;; no htmlLabels: the SVG holds no foreignObject, so it draws in an img
  (unless (file-exists? (string-append mermaid-dir "config.json"))
    (write-file! (string-append mermaid-dir "config.json") "{\"flowchart\":{\"htmlLabels\":false},\"htmlLabels\":false}")))

(define (mermaid--render! key src k)
  (let ((in (string-append mermaid-dir "cache/" key ".mmd"))
        (out (mermaid--path key)))
    (if (member key mermaid--pending)
        #f
        (begin
          (set! mermaid--pending (cons key mermaid--pending))
          (mermaid--ensure-config!)
          (write-file! in src)
          (shell-command->string
            (string-append "cd '" mermaid-dir "' && command -v npx >/dev/null || { echo 'npx not found'; exit 0; }; "
                           "PUPPETEER_SKIP_DOWNLOAD=1 npx -y -p @mermaid-js/mermaid-cli@11 mmdc"
                           " -p puppeteer.json -c config.json -t " (mermaid-theme) " -b transparent"
                           " -i '" in "' -o '" out "' 2>&1"
                           " | grep -v '^    at ' | grep -v '^Generating' | grep -v '^$' | tail -2")
            mermaid-dir
            (lambda (log)
              (set! mermaid--pending (filter (lambda (x) (not (equal? x key))) mermaid--pending))
              (let ((ok (file-exists? out)))
                (unless ok
                  (set! mermaid--failed
                        (cons (cons key (let ((l (string-trim (if (string? log) log ""))))
                                          (if (equal? l "") "no SVG written" (car (string-split l "\n")))))
                              mermaid--failed)))
                (when k (k (and ok out)))
                (mermaid--drawn!))))
          #t))))

;; (ready PATH), (failed ERROR) or (pending); a miss starts the render
(define (mermaid-state src)
  (let* ((key (mermaid--key src)) (path (mermaid--path key))
         (failed (assoc key mermaid--failed)) (setup (mermaid--setup-error)))
    (cond ((file-exists? path) (list 'ready path))
          (setup (list 'failed setup))
          (failed (list 'failed (cdr failed)))
          (else (mermaid--render! key src #f) (list 'pending)))))

;; the SVG of SRC: K gets its path, or #f when it did not draw
(define (mermaid-svg src k)
  (let* ((key (mermaid--key src)) (path (mermaid--path key)))
    (cond ((file-exists? path) (k path))
          ((mermaid--setup-error) (k #f))
          ((not (mermaid--render! key src k))
           ;; already drawing: answer when the shared render ends
           (mermaid-on-drawn! (string-append "svg:" key)
             (lambda ()
               (unless (member key mermaid--pending)
                 (set! mermaid--drawn-fns (filter (lambda (p) (not (equal? (car p) (string-append "svg:" key)))) mermaid--drawn-fns))
                 (k (and (file-exists? path) path)))))))))

(effects! '(pure))

;; the block a component page draws for SRC
(define (mermaid-node src)
  (let ((st (mermaid-state src)))
    (cond
      ((equal? (car st) 'ready)
       (list 'tag "img" 'class "mermaid-diagram" 'file (cadr st)
             'attrs (list (list "alt" "diagram") (list "style" "max-width:100%;height:auto;display:block;margin:12px 0"))))
      ((equal? (car st) 'failed)
       (component 'ui/group
         (list 'title (string-append "diagram not drawn: " (cadr st))
               'body (list (component 'ui/quote (list 'text src))))))
      (else (component 'ui/empty (list 'text "drawing diagram…"))))))

;; The preview painter's spans for the mermaid blocks in BLOCKS, as
;; morg-blocks gives them: (OPEN LANG BODY-START BODY-END). A drawn diagram
;; stands on the fence's row; its source rows hide. Until then the source
;; shows as code under a one-line note.
(define (mermaid-paint-spans text blocks)
  (let ((size (string-byte-length text)))
    (apply append
      (map (lambda (b)
             (if (not (equal? (string-downcase (or (nth 1 b) "")) "mermaid"))
                 '()
                 (let* ((open (nth 0 b)) (bs (nth 2 b)) (be (nth 3 b))
                        (open-end (max open (- bs 1)))
                        (close-end (let ((nl (string-index text "\n" be))) (if nl nl size)))
                        (st (mermaid-state (substring-bytes text bs (max bs (- be 1))))))
                   (cond
                     ((equal? (car st) 'ready)
                      (list (list open open-end "md-marker")
                            (list open open-end "row-picture")
                            (chrome-before open (cadr st) "img-embed mermaid-diagram")
                            (list bs close-end "row-conceal")))
                     ((equal? (car st) 'failed)
                      (list (chrome-before open (string-append "diagram not drawn: " (cadr st) " ") "mermaid-note")))
                     (else (list (chrome-before open "drawing diagram… " "mermaid-note")))))))
           blocks))))

(public! 'mermaid-state "(mermaid-state SRC) — (ready PATH), (failed ERROR) or (pending) for a mermaid diagram; a miss starts its render")
(public! 'mermaid-svg "(mermaid-svg SRC K) — render SRC once to an SVG file; K gets its path, or #f when it did not draw")
(public! 'mermaid-node "(mermaid-node SRC) — the page block for a mermaid diagram: the picture, a note while it draws, or the source with its error")
(public! 'mermaid-paint-spans "(mermaid-paint-spans TEXT BLOCKS) — the preview painter's spans that draw each mermaid block of BLOCKS as its picture")
(public! 'mermaid-on-drawn! "(mermaid-on-drawn! NAME FN) — run FN, a thunk, after each render ends; NAME replaces an earlier FN")
(public! 'mermaid-forget-failures! "(mermaid-forget-failures!) — try failed diagrams again on the next draw")
(public! 'mermaid-theme "(mermaid-theme) — the mermaid theme diagrams draw in: dark under a dark editor theme, else default")

(provide 'mermaid)
