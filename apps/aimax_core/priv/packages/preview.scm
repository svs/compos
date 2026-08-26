;;; preview.scm — a buffer rendered instead of shown as source.
;;;
;;; `C-c C-v` toggles the rendered page. The renderer comes from the file
;;; extension, or from a buffer-local a generated buffer sets. `C-c C-a`
;;; runs an HTML buffer as an app instead: its own scripts, its own
;;; storage, and the files beside it.
;;;
;;; The frontend draws the page and reports where a click or a visual-line
;;; key landed. This file decides what that means for point.

(domain! 'interaction)
(effects! '(write))

;; preview-mode: render the buffer instead of showing its source.
;; Renderer picked by *preview-renderers* (extension -> renderer); the
;; frontend knows "html" and "markdown". Add your own:
;;   (set! *preview-renderers* (cons '(".rst" "markdown") *preview-renderers*))
(define *preview-renderers*
  '((".html" "html") (".htm" "html") (".svg" "html")
    (".md" "markdown") (".markdown" "markdown") (".org" "markdown")
    (".txt" "markdown")))

;; A generated buffer has no extension to read a renderer from, so it says
;; which renderer it wants in a buffer-local. Help docs are the case: the
;; text is markdown, the buffer is "*Help*", and C-c C-v must still toggle
;; between the source and the rendered page.
(define (preview-renderer-for name)
  (or (buffer-local name 'preview-renderer)
      (let loop ((rs *preview-renderers*))
        (if (null? rs)
            #f
            (if (string-suffix? (car (car rs)) name)
                (cadr (car rs))
                (loop (cdr rs)))))))

(define-command "preview-mode" "Toggle rendered preview of the current buffer"
  (lambda ()
    (if (equal? (buffer-local (current-buffer) 'mode-name) "chat-mode")
        ;; a chat's rendered view is the rich transcript, not a markdown
        ;; preview. A markdown render-mode here lost the chat UI with no
        ;; way back — the chat's own toggle owns this buffer-local.
        (run-command "chat-toggle-view")
        (if (buffer-local (current-buffer) 'render-mode)
            (begin
              (buffer-set-local! (current-buffer) 'render-mode #f)
              (message "Preview off"))
            (let ((r (preview-renderer-for (current-buffer))))
              (if r
                  (begin
                    (buffer-set-local! (current-buffer) 'render-mode r)
                    (message (string-append "Preview on (" r ") — C-c C-v toggles")))
                  (message "No preview renderer for this buffer")))))))

(define (preview--positions text needle)
  (let loop ((from 0) (acc (list)))
    (let ((i (string-index text needle from)))
      (if i
          (loop (+ i 1) (cons i acc))
          (reverse acc)))))

;; The nearest position strictly on DIR's side of FROM. DIR is 1 for a key
;; that moves down, -1 for a key that moves up.
(define (preview--toward positions from dir)
  (let ((side (filter (lambda (p) (if (> dir 0) (> p from) (< p from)))
                      positions)))
    (cond ((null? side) #f)
          ((> dir 0) (car side))
          (else (car (reverse side))))))

;; The position nearest FROM, on either side.
(define (preview--nearest positions from)
  (let loop ((ps positions) (best #f))
    (cond ((null? ps) best)
          ((or (not best) (< (abs (- (car ps) from)) (abs (- best from))))
           (loop (cdr ps) (car ps)))
          (else (loop (cdr ps) best)))))

(define (preview--nth lst n)
  (cond ((null? lst) #f)
        ((<= n 0) (car lst))
        (else (preview--nth (cdr lst) (- n 1)))))

;; One rendered fragment names many source positions. A two-character code
;; span such as `-b` sits in the file ten times, so the first hit is almost
;; never the one the reader points at: the cursor jumps to the top of the
;; file, and the next key matches the same first hit again. The cursor then
;; stops moving.
;;
;; So the client also counts, on the page, how many times the fragment
;; comes before the one it means (NTH), and names the direction the key
;; moves (DIR: 1 down, -1 up, 0 for a click). Take the NTH source hit.
;; Rendered text and source text differ, so that count can miss; when it
;; misses, or when DIR says the cursor must move and the NTH hit does not
;; move it, take the nearest hit on DIR's side. A down key then always
;; moves down.
;;
;; string-index rejects an empty pattern, so an empty needle answers #f.
(define (preview--hit text before after nth dir from)
  (let ((needle (string-append before after)))
    (if (equal? needle "")
        #f
        (let* ((starts (preview--positions text needle))
               (b (string-byte-length before))
               (hits (map (lambda (i) (+ i b)) starts))
               (want (preview--nth hits nth))
               (ok (and want (or (= dir 0) (if (> dir 0) (> want from) (< want from))))))
          (cond (ok want)
                ((= dir 0) (preview--nearest hits from))
                (else (or (preview--toward hits from dir)
                          (preview--nearest hits from))))))))

;; A click or a visual-line key in a rendered markdown page. The client
;; sends the text node split at the caret, plus the word run around the
;; caret. Rendered text and source differ (markup is stripped, punctuation
;; is smartened), so try the exact node first and the plain word run
;; second; NTH counts the node, WN counts the word run.

;; How far a visual-line key may carry point. The key moves one rendered
;; row, so the source line changes by one, or not at all while the row is
;; part of a wrapped paragraph. A hit further away is a wrong hit: a name
;; sits in a link label and again in the link target, so the count the page
;; makes can name the wrong occurrence.
(define preview--near-lines 4)

(define (preview--near? from hit)
  (<= (abs (- (line-number-at-pos hit) (line-number-at-pos from)))
      preview--near-lines))

(define (preview-goto! win before after wb wa nth wn dir)
  (mouse-select-window! win)
  (set-mark! #f)
  (let* ((text (buffer-text (current-buffer)))
         (from (point))
         ;; A one-character word run matches almost anywhere in the file, and a
         ;; wrong hit throws point into a far paragraph. No move is better.
         (hit (or (preview--hit text before after nth dir from)
                  (and (>= (string-byte-length (string-append wb wa)) 2)
                       (preview--hit text wb wa wn dir from)))))
    (cond
      ;; a click names one place on the page. Go there, however far it is.
      ((and hit (= dir 0)) (goto-char! hit))
      ((and hit (preview--near? from hit)) (goto-char! hit))
      ;; The page named no row, or it named a row too far away. The key must
      ;; still move point, so walk one source line: that keeps the column.
      ((> dir 0) (next-line!))
      ((< dir 0) (previous-line!))
      (else #f))))
(public! 'preview-goto!
  "(preview-goto! WIN BEFORE AFTER WB WA NTH WN DIR) — put point where a preview click or visual-line key landed"
  'interaction)

;; The page knows which source line each rendered row belongs to: every
;; line that draws text carries its byte offset. A key that moves a row
;; sends that offset plus the count of rendered characters between the
;; line's mark and the caret. Point stays on that line, so a move can
;; never land in another block.
(define (preview--line-end pos)
  (let ((next (line-start-position (+ 1 (line-number-at-pos pos)))))
    (if (and next (> next pos)) (- next 1) (buffer-size (current-buffer)))))

(define (preview-goto-src! win pos off extend)
  (mouse-select-window! win)
  (if extend
      (unless (mark) (set-mark! (point)))
      (set-mark! #f))
  (let ((at (max 0 (min pos (buffer-size (current-buffer))))))
    (goto-char! (min (+ at off) (preview--line-end at)))))
(public! 'preview-goto-src!
  "(preview-goto-src! WIN POS OFF EXTEND) — put point OFF rendered characters along the source line that starts at POS"
  'interaction)

(define (preview-select! win before after wb wa nth wn dir)
  (let ((anchor (or (mark) (point))))
    (preview-goto! win before after wb wa nth wn dir)
    (set-mark! anchor)))
(public! 'preview-select!
  "(preview-select! WIN BEFORE AFTER WB WA NTH WN DIR) — extend the region to a rendered position"
  'interaction)

;; Render-only widgets know their exact source ranges. Unlike preview-goto!,
;; these do not need to reverse-map rendered prose into Markdown.
(define (preview-goto-pos! win pos extend)
  (mouse-select-window! win)
  (when extend (unless (mark) (set-mark! (point))))
  (unless extend (set-mark! #f))
  (goto-char! (max 0 (min pos (buffer-size (current-buffer))))))
(public! 'preview-goto-pos!
  "(preview-goto-pos! WIN POS EXTEND) — move to an exact preview source position"
  'interaction)

;; A click on a link in a rendered page. The client never follows the link
;; itself — it sends the href here, and Scheme says what the link means.
;; A link the editor owns reads "aimax:VERB/ARGUMENT": a package claims a
;; verb with on-preview-link!, the way it claims a display rule. help.scm
;; claims "def", which opens the source of a name. An ordinary URL opens
;; in the reader.
(define *preview-link-verbs* '())

(define (on-preview-link! verb fn)
  (set! *preview-link-verbs*
    (cons (list verb fn)
          (filter (lambda (e) (not (equal? (car e) verb))) *preview-link-verbs*))))

;; "aimax:def/find-file" -> ("def" "find-file"). The argument keeps its own
;; slashes, so a qualified name survives the split.
(define (preview--link-parts href)
  (let* ((body (string-join (cdr (string-split href ":")) ":"))
         (parts (string-split body "/")))
    (list (car parts) (url-decode (string-join (cdr parts) "/")))))

;; A Markdown file link is a URL, so remove its query and fragment before
;; decoding it. Resolve a relative target beside the source buffer's file.
(define (preview--file-href href)
  (let* ((without-fragment (car (string-split href "#")))
         (without-query (car (string-split without-fragment "?")))
         (decoded (url-decode without-query)))
    (if (string-prefix? "file://" decoded)
        (substring decoded 7 (string-length decoded))
        decoded)))

(define (preview--file-target source href)
  (let ((target (preview--file-href href)))
    (cond ((or (string-prefix? "/" target)
               (string-prefix? "~" target))
           (expand-path target))
          ((and (string? source) (buffer-path source))
           (let ((joined (string-append (car (path-split (buffer-path source)))
                                        target)))
             (if (remote-path? joined) joined (expand-path joined))))
          (else (expand-path target)))))

(define (preview-follow-link! win href)
  (mouse-select-window! win)
  (let ((source (current-buffer)))
    (cond
      ((string-prefix? "aimax:" href)
       (let* ((parts (preview--link-parts href))
              (hit (assoc (car parts) *preview-link-verbs*)))
         (if hit
             ((cadr hit) (cadr parts))
             (message (string-append "No handler for " href)))))
      ((and (or (string-prefix? "http://" href) (string-prefix? "https://" href))
            (boundp 'browse))
       (browse href))
      ((re-match "^[A-Za-z][A-Za-z0-9+.-]*:" href)
       (message (string-append "No handler for " href)))
      (else
        (visit (preview--file-target source href) (frame-group))))))

(public! 'on-preview-link!
  "(on-preview-link! VERB FN) — claim the aimax:VERB/ARG links in a rendered page; FN gets ARG"
  'interaction)
(public! 'preview-follow-link!
  "(preview-follow-link! WIN HREF) — follow a link a reader clicked in a rendered page"
  'interaction)
(catalog-meta! 'function "on-preview-link!" 'domain 'interaction 'effects '(write))
(catalog-meta! 'function "preview-follow-link!" 'domain 'interaction 'effects '(write))

;;; --- apps --------------------------------------------------------------
;;; preview-mode renders a page the way eww does: themed, and inert. An app
;;; needs the opposite. It keeps the colours the author wrote, it runs its
;;; own JavaScript, it keeps its own storage, and it loads the files beside
;;; it. So an app window draws a frame on the app origin — a different port,
;;; which the browser reads as a different origin — and that origin serves
;;; this buffer's live text plus the directory its file lives in.
;;;
;;; The two are separate commands on purpose. A downloaded .html that you
;;; open to read must not run anything; `C-c C-v` reads it, `C-c C-a` runs
;;; it, and the difference is a key you press.

(define (app-buffer? buf) (equal? (buffer-local buf 'render-mode) "app"))

;; the client reloads an app when this number changes, and at no other time:
;; a keystroke must not restart the app you are typing at
(define (app-reload! buf)
  (buffer-set-local! buf 'app-generation
                     (+ 1 (or (buffer-local buf 'app-generation) 0))))

(define (app-buffers)
  (let loop ((bs (buffer-list)) (acc '()))
    (cond ((null? bs) (reverse acc))
          ((app-buffer? (car bs)) (loop (cdr bs) (cons (car bs) acc)))
          (else (loop (cdr bs) acc)))))

(define-command "app-preview" "Run the current buffer as an HTML app"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (app-buffer? buf)
          (begin
            (buffer-set-local! buf 'render-mode #f)
            (message "App off"))
          (begin
            (app-reload! buf)
            (buffer-set-local! buf 'render-mode "app")
            (message "App on — C-g gives the keyboard back, C-c C-a stops it"))))))

(define-command "app-reload" "Reload every running app"
  (lambda ()
    (let ((bs (app-buffers)))
      (for-each app-reload! bs)
      (message (string-append "Reloaded " (number->string (length bs)) " app(s)")))))

;; a save is the reload signal: you save the buffer, the app runs the new
;; code. The app server reads buffers, not files, so an unsaved edit in a
;; sibling file shows on the next reload too.
(add-hook! 'after-save-hook (lambda () (for-each app-reload! (app-buffers))))

(global-set-key "C-c C-v" "preview-mode")
(global-set-key "C-c C-a" "app-preview")
(global-set-key "C-c C-r" "app-reload")
