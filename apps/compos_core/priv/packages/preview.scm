;;; preview.scm — a buffer rendered instead of shown as source.
;;;
;;; `C-c C-v` toggles the rendered page. The renderer comes from the file
;;; extension, or from a buffer-local a generated buffer sets. `C-c C-a`
;;; runs an HTML buffer as an app instead: its own scripts, its own
;;; storage, and the files beside it.
;;;
;;; The frontend draws the page and reports the source byte a click landed
;;; on. This file decides what that means for point. Row motion is not
;;; here: the client measures where the rows begin (the wrap map), and the
;;; line commands in editor.scm read it.

(domain! 'interaction)
(effects! '(write))

(domain! 'ui)
(effects! '(write))

;;; --- rendered page typography -----------------------------------------------

(define *preview-serif* "Spectral,Georgia,serif")
(define *preview-mono* "'IBM Plex Mono',ui-monospace,Menlo,monospace")

(defcustom 'preview-font-family *preview-serif*
  "Font family for rendered preview pages."
  'group 'preview
  'set (lambda (v) (set-face-attribute! 'preview 'family v)))

(defcustom 'preview-font-size "16.5px"
  "Font size for rendered preview pages."
  'group 'preview
  'set (lambda (v) (set-face-attribute! 'preview 'size v)))

(defcustom 'preview-measure "33em"
  "Maximum line length for rendered preview pages."
  'group 'preview
  'set (lambda (v) (set-face-attribute! 'preview 'measure v)))

(set-face-attribute! 'preview
  'family preview-font-family
  'size preview-font-size
  'measure preview-measure)

;; The type of a rendered page is one choice, "mono" or "serif", and every
;; rendered page takes it: the renderer bakes the preview face into the page,
;; so a buffer cannot hold a type of its own. Each choice carries its own size
;; and measure, because a monospace character is wider and the same character
;; count needs more em.
(define (preview-typography)
  (if (string-contains? preview-font-family "Mono") "mono" "serif"))

(define (preview-typography! view)
  (let ((mono? (equal? view "mono")))
    (customize-set! 'preview-font-family (if mono? *preview-mono* *preview-serif*))
    (customize-set! 'preview-font-size (if mono? "14.5px" "16.5px"))
    (customize-set! 'preview-measure (if mono? "42em" "33em"))
    ;; Rows draw on the text surface, so they read the setting themselves.
    (for-each
      (lambda (buf)
        (when (buffer-local buf 'preview-rows)
          (preview--rows-look! buf)))
      (buffer-list))
    view))

(define-command "preview-font-toggle"
  "Switch rendered preview pages between serif and monospace"
  (lambda ()
    (let ((view (if (equal? (preview-typography) "mono") "serif" "mono")))
      (preview-typography! view)
      (message (string-append "rendered pages: "
                             (if (equal? view "mono") "monospace" "serif"))))))

(public! 'preview-font-toggle
  "(run-command \"preview-font-toggle\") — flip rendered pages between serif and monospace")
(public! 'preview-typography
  "(preview-typography) — the type rendered pages use now: \"mono\" or \"serif\"")
(public! 'preview-typography!
  "(preview-typography! VIEW) — set the type of every rendered page: \"mono\" or \"serif\"")

;; preview-mode: render the buffer instead of showing its source.
;; Renderer picked by *preview-renderers* (extension -> renderer); the
;; frontend knows "html" and "markdown". Add your own:
;;   (set! *preview-renderers* (cons '(".rst" "markdown") *preview-renderers*))
(define *preview-renderers*
  '((".html" "html") (".htm" "html") (".svg" "html")
    (".md" "rows") (".markdown" "rows") (".org" "markdown")
    (".txt" "markdown")))

;; "rows": Markdown drawn in place on the editable surface. The page is the
;; buffer's own rows with the markup stepped back, the preview typography,
;; inline pictures and cards, and the browser's caret. "markdown" is the
;; older page in an iframe, which cannot hold a native caret; a saved
;; buffer that still names it gets the rows.
(define (preview--markdown-file? name)
  (or (string-suffix? ".md" name) (string-suffix? ".markdown" name)))

(define (preview--rows-on! buf)
  ;; runtime state of the rows: never saved with the desktop. The mode
  ;; list is what persists, and setup rebuilds the paint from it. The saved
  ;; source look must persist because face-remap contains the drawn look.
  (desktop-skip! buf 'preview-rows)
  (desktop-skip! buf 'markdown-paint)
  ;; Migrate buffers that marked the source look as runtime state.
  (buffer-set-local! buf 'desktop-skip-locals
    (remove (lambda (key) (equal? key 'preview-rows-saved))
            (or (buffer-local buf 'desktop-skip-locals) '())))
  (buffer-set-local! buf 'render-mode #f)
  ;; the look the rows replace comes back exactly when they go
  (unless (buffer-local buf 'preview-rows-saved)
    (buffer-set-local! buf 'preview-rows-saved
      (list (or (buffer-local buf 'face-remap) '())
            (or (buffer-local buf 'style) #f))))
  (buffer-set-local! buf 'preview-rows #t)
  (when (boundp 'markdown-paint-on!) (markdown-paint-on! buf))
  (preview--rows-look! buf))

;; the page's typography on the rows. writing-mode calls this too after its
;; own setup, so the page's look wins while the rows are on.
(define (preview--rows-look! buf)
  ;; the type is the page's; the width stays writing-mode's
  (face-remap-in! buf 'default
    (list 'family preview-font-family 'size preview-font-size 'line-height "1.7")))

;; Old desktops did not save preview-rows-saved. Restore then captured the
;; rendered font as the source font. That exact remap belongs to preview, so
;; teardown removes it and lets the source font below it show again.
(define (preview--own-default? entry)
  (and (equal? (car entry) 'default)
       (let ((attrs (cadr entry)))
         (and (equal? (plist-get attrs 'family) preview-font-family)
              (equal? (plist-get attrs 'size) preview-font-size)
              (equal? (plist-get attrs 'line-height) "1.7")))))

(define (preview--source-remap saved)
  (filter (lambda (entry) (not (preview--own-default? entry))) saved))

(define (preview--rows-off! buf)
  (buffer-set-local! buf 'preview-rows #f)
  (when (boundp 'markdown-paint-off!) (markdown-paint-off! buf))
  ;; the plain faces come back: morg skipped its paint while the rows drew
  (when (and (boundp 'morg-refontify!) (buffer-mode-is? buf "morg-mode"))
    (morg-refontify! buf))
  (let ((saved (buffer-local buf 'preview-rows-saved)))
    (when saved
      (let ((source (preview--source-remap (car saved))))
        (buffer-set-local! buf 'face-remap source)
        (buffer-set-local! buf 'style (face-remap--css source)))
      (buffer-set-local! buf 'preview-rows-saved #f)
      ;; the saved remap predates a scale set while the rows were on
      (when (boundp 'text-scale-sync!) (text-scale-sync! buf)))))

;; One renderer draws a Markdown page: the tree-sitter engine. It draws
;; from the grammar's own tree, so it knows where every byte was drawn:
;; the caret lands on the byte it belongs to, and a click maps back to the
;; source. Elixir falls back to Earmark only where the markdown grammar is
;; not installed, and that fallback is mechanism, not a choice.
(defgroup 'preview "Rendered pages.")

;; A generated buffer has no extension to read a renderer from, so it says
;; which renderer it wants in a buffer-local. Help docs are the case: the
;; text is markdown, the buffer is "*Help*", and C-c C-v must still toggle
;; between the source and the rendered page.
(define (preview-renderer-for name)
  (let ((r (or (buffer-local name 'preview-renderer)
               (let loop ((rs *preview-renderers*))
                 (if (null? rs)
                     #f
                     (if (string-suffix? (car (car rs)) name)
                         (cadr (car rs))
                         (loop (cdr rs))))))))
    (cond ((and (equal? r "markdown") (preview--markdown-file? name)) "rows")
          (r r)
          ;; the mode is the truth, not the name: a scratch or any other
          ;; unnamed morg buffer previews as rows like a .md file does
          ((buffer-mode-is? name "morg-mode") "rows")
          (else #f))))

;; A buffer whose rows disagree with its mode list heals: rows without the
;; mode go, the mode without rows draws. A restored desktop from before
;; the rows were runtime-only is the case.
(define (preview-heal! buf)
  ;; "rows" is a renderer, never a render mode
  (when (equal? (buffer-local buf 'render-mode) "rows")
    (buffer-set-local! buf 'render-mode #f))
  (let ((on (minor-mode-on? buf "preview-mode"))
        (rows (equal? (buffer-local buf 'preview-rows) #t)))
    (cond ((and rows (not on)) (preview--rows-off! buf))
          ((and on (not rows) (equal? (preview-renderer-for buf) "rows"))
           (preview--rows-on! buf))
          ((and (not rows) (equal? (buffer-local buf 'markdown-paint) #t))
           (when (boundp 'markdown-paint-off!) (markdown-paint-off! buf))
           (when (and (boundp 'morg-refontify!) (buffer-mode-is? buf "morg-mode"))
             (morg-refontify! buf)))
          (else #f))))
(public! 'preview-heal! "(preview-heal! BUF) — make BUF's drawn rows agree with its preview-mode")

(define (preview-mode--apply! buf)
  (let ((renderer (preview-renderer-for buf)))
    (if renderer
        (if (equal? renderer "rows")
            (preview--rows-on! buf)
            (begin
              (when (buffer-local buf 'preview-rows) (preview--rows-off! buf))
              (buffer-set-local! buf 'render-mode renderer)))
        ;; A renamed or restored buffer can lose its renderer. Remove the
        ;; stale mode entry instead of leaving an enabled mode that draws
        ;; nothing.
        (begin
          (buffer-set-local! buf 'minor-modes
            (remove (lambda (name) (equal? name "preview-mode"))
                    (or (buffer-local buf 'minor-modes) '())))
          (buffer-set-local! buf 'render-mode #f)))))

(define (preview-mode--teardown! buf)
  (when (buffer-local buf 'preview-rows) (preview--rows-off! buf))
  (buffer-set-local! buf 'render-mode #f))

(register-minor-mode! "preview-mode" preview-mode--apply! preview-mode--teardown!)

(define-command "preview-mode" "Toggle rendered preview of the current buffer"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (equal? (buffer-local buf 'mode-name) "chat-mode")
          ;; A chat's rendered view is the rich transcript. Its own command
          ;; owns that view and its durable state.
          (run-command "chat-toggle-view")
          (if (minor-mode-on? buf "preview-mode")
              (begin
                (disable-minor-mode! buf "preview-mode")
                (message "Preview off"))
              (let ((renderer (preview-renderer-for buf)))
                (if renderer
                    (begin
                      (enable-minor-mode! buf "preview-mode")
                      (preview-heal! buf)
                      (message
                        (string-append "Preview on (" renderer ") — C-c C-v toggles")))
                    (message "No preview renderer for this buffer"))))))))

;;; --- RET in a rendered page --------------------------------------------------
;;; RET edits source text. One press inserts one newline. The renderer decides
;;; whether Markdown shows that byte as a soft break or a block gap. Lists keep
;;; their editor behavior: a non-empty item continues, and an empty item ends.

;; A list item continues the list. An ordered item counts on; a bullet
;; repeats. The third value is the length of the marker, which says where
;; the item's own text starts.
(define (preview--next-marker line)
  (let ((bullet (re-match "^([ \t]*)([-*+])[ \t]+" line)))
    (if bullet
        (list (cadr bullet) (caddr bullet) (string-length (car bullet)))
        (let ((ordered (re-match "^([ \t]*)([0-9]+)([.)])[ \t]+" line)))
          (if ordered
              (list (cadr ordered)
                    (string-append
                      (number->string (+ 1 (string->number (caddr ordered))))
                      (list-ref ordered 3))
                    (string-length (car ordered)))
              #f)))))

;; RET on an item that has no text ends the list, the way every list editor
;; does: the marker goes, and the empty line becomes a block of its own.
(define (preview--list-newline! line item)
  (let* ((buf (current-buffer))
         (ls (line-start-position (line-number-at-pos (point))))
         (width (caddr item)))
    (if (equal? (string-trim (substring line width (string-length line))) "")
        (begin
          (buffer-replace-range! buf ls width "")
          (goto-char! ls))
        (insert! (string-append "\n" (car item) (cadr item) " ")))))

;; Every character inside a fence is literal, and a table row means nothing
;; once it is split, so RET keeps its plain meaning on those lines.
(define (preview--fence-line? line) (re-match "^[ \t]*```" line))

(define (preview--in-fence? ls)
  (let loop ((lines (string-split (buffer-substring 0 ls) "\n")) (n 0))
    (if (null? lines)
        (= (remainder n 2) 1)
        (loop (cdr lines)
              (if (preview--fence-line? (car lines)) (+ n 1) n)))))

(define (preview--literal-line? ls line)
  (or (preview--fence-line? line)
      (re-match "^[ \t]*[|]" line)
      (preview--in-fence? ls)))

;; A rendered page the reader can type into. A read-only page — help, a
;; diff, a bookmark note — keeps the plain newline, and so does every
;; renderer that is not Markdown.
(define (preview--markdown-edit?)
  (let ((buf (current-buffer)))
    (and (equal? (buffer-local buf 'render-mode) "markdown")
         (not (buffer-read-only? buf)))))

(define (preview-newline!)
  (let* ((p (point))
         (ls (line-start-position (line-number-at-pos p)))
         (line (line-text)))
    (if (preview--literal-line? ls line)
        (insert! "\n")
        (let ((item (preview--next-marker line)))
          (if item
              (preview--list-newline! line item)
              (insert! "\n"))))))
(public! 'preview-newline!
  "(preview-newline!) — insert one newline in a rendered Markdown page"
  'interaction)

(define-command "preview-newline"
  "Insert one newline in a rendered page"
  (lambda ()
    (if (preview--markdown-edit?)
        (preview-newline!)
        (run-command "newline-or-send"))))

;; preview.scm loads after editor.scm, so this takes RET from the plain
;; newline and hands back to it for every buffer that is not a Markdown
;; preview. S-RET stays the soft line break.
(global-set-key "RET" "preview-newline")
(global-set-key "S-RET" "newline")

;; The page names the source byte of what the reader clicked or dragged:
;; every run of drawn text carries the byte it began at.
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
;; A link the editor owns reads "compos:VERB/ARGUMENT": a package claims a
;; verb with on-preview-link!, the way it claims a display rule. help.scm
;; claims "def", which opens the source of a name. An ordinary URL opens
;; in the reader.
(define *preview-link-verbs* '())

(define (on-preview-link! verb fn)
  (set! *preview-link-verbs*
    (cons (list verb fn)
          (filter (lambda (e) (not (equal? (car e) verb))) *preview-link-verbs*))))

;; "compos:def/find-file" -> ("def" "find-file"). The argument keeps its own
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

;;; --- insert document links --------------------------------------------------

(domain! 'documents)
(effects! '(write display))

(define (document-link--parts path)
  (filter (lambda (part) (not (equal? part ""))) (string-split path "/")))

(define (document-link--drop-common left right)
  (if (and (pair? left) (pair? right) (equal? (car left) (car right)))
      (document-link--drop-common (cdr left) (cdr right))
      (list left right)))

(define (document-link--absolute-target base input)
  (let ((target (normalize-file-input input)))
    (cond ((remote-path? target) target)
          ((or (string-prefix? "/" target) (string-prefix? "~" target))
           (expand-path target))
          (else (expand-path (string-append base target))))))

(define (document-link--relative-target base target)
  (if (or (remote-path? base) (remote-path? target))
      target
      (let* ((rest (document-link--drop-common
                     (document-link--parts (expand-path base))
                     (document-link--parts (expand-path target))))
             (up (string-repeat "../" (length (car rest))))
             (down (string-join (cadr rest) "/"))
             (relative (string-append up down)))
        (if (equal? relative "") "." relative))))

(define (document-link--encode-target target)
  (re-replace-all "%2F" (url-encode target) "/"))

(define (document-link--insert! buf start end label target)
  (if (not (buffer-known? buf))
      (message "The source document is gone")
      (with-current-buffer buf
        (lambda ()
          (when (> end start) (buffer-delete-range! buf start (- end start)))
          (goto-char! start)
          (insert! (string-append "[" label "](" target ")"))
          (set-mark! #f)))))

(define-command "insert-document-link"
  "Choose a document and insert its Markdown link at point"
  (lambda ()
    (let* ((buf (current-buffer))
           (selected? (and (mark) (< (region-beginning) (region-end))))
           (start (if selected? (region-beginning) (point)))
           (end (if selected? (region-end) (point)))
           (label (and selected? (region-text)))
           (path (buffer-path buf))
           (base (if path (car (path-split path)) (default-directory))))
      (read-file-name-initial "Link target: " base
        (lambda (input)
          (let* ((absolute (document-link--absolute-target base input))
                 (relative (document-link--relative-target base absolute))
                 (target (document-link--encode-target relative)))
            (if label
                (document-link--insert! buf start end label target)
                (minibuffer-read "Link text: " '()
                  (lambda (text)
                    (if (equal? (string-trim text) "")
                        (message "Link text is required")
                        (document-link--insert! buf start end text target)))))))))))

(domain! 'interaction)
(effects! '(write))

;; A document follows the receiving frame by default. The explicit form
;; enters its chosen group first, then gives the document that membership.
(define (preview--follow-document! source href group)
  (visit (preview--file-target source href) group))

(define (link-follow-to-group win href)
  (mouse-select-window! win)
  (let ((source (current-buffer)))
    (if (re-match "^[A-Za-z][A-Za-z0-9+.-]*:" href)
        (message "Only document links can follow to a group")
        (if (not (boundp 'group-read-or-create!))
            (message "Groups are not available")
            (group-read-or-create! "Follow document to group: "
              (lambda (group)
                (switch-to-group! group)
                (preview--follow-document! source href group)))))))

(define (preview-follow-link! win href)
  (mouse-select-window! win)
  (let ((source (current-buffer)))
    (cond
      ((string-prefix? "compos:" href)
       (let* ((parts (preview--link-parts href))
              (hit (assoc (car parts) *preview-link-verbs*)))
         (if hit
             ((cadr hit) (cadr parts))
             (message (string-append "No handler for " href)))))
      ;; A rendered browse page keeps web navigation in its own tab.
      ;; Relative targets resolve against the current page, not local files.
      ((and (equal? (buffer-local source 'mode-name) "browse-mode")
            (boundp 'browse)
            (boundp 'url-resolve)
            (buffer-local source 'browse-url)
            (or (string-prefix? "http://" href)
                (string-prefix? "https://" href)
                (not (re-match "^[A-Za-z][A-Za-z0-9+.-]*:" href))))
       (browse (url-resolve href (buffer-local source 'browse-url))))
      ((and (or (string-prefix? "http://" href)
                (string-prefix? "https://" href))
            (boundp 'browse))
       (browse href))
      ((re-match "^[A-Za-z][A-Za-z0-9+.-]*:" href)
       (message (string-append "No handler for " href)))
      (else
        (preview--follow-document! source href (frame-group))))))

(public! 'on-preview-link!
  "(on-preview-link! VERB FN) — claim the compos:VERB/ARG links in a rendered page; FN gets ARG"
  'interaction)
(public! 'preview-follow-link!
  "(preview-follow-link! WIN HREF) — follow a link a reader clicked in a rendered page"
  'interaction)
(public! 'link-follow-to-group
  "(link-follow-to-group WIN HREF) — choose or name a group, then follow the document link there"
  'interaction)
(catalog-meta! 'function "on-preview-link!" 'domain 'interaction 'effects '(write))
(catalog-meta! 'function "preview-follow-link!" 'domain 'interaction 'effects '(write))
(catalog-meta! 'function "link-follow-to-group" 'domain 'interaction 'effects '(write display))

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

;;; --- whitespace-mode ---------------------------------------------------------
;;; A rendered page hides the newline the author typed, so a reader cannot
;;; see where a line ends, and a caret that moves across one looks like it
;;; jumped. Draw the newline, muted, where it is. Emacs answers the same
;;; question with the same mode name.

(define (whitespace--apply! buf)
  (buffer-set-local! buf 'whitespace-mode #t))

(define (whitespace--teardown! buf)
  (buffer-set-local! buf 'whitespace-mode #f))

(register-minor-mode! "whitespace-mode" whitespace--apply! whitespace--teardown!)

(define-command "whitespace-mode" "Toggle the newline and space marks"
  (lambda ()
    (if (toggle-minor-mode! "whitespace-mode")
        (message "whitespace-mode enabled")
        (message "whitespace-mode disabled"))))

(global-set-key "C-c C-v" "preview-mode")
(global-set-key "C-c C-a" "app-preview")
(global-set-key "C-c C-r" "app-reload")
