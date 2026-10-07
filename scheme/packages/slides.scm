;;; slides.scm --- a Markdown buffer presented as animated slides.
;;;
;;; The deck is a Markdown buffer. A line of --- ends a slide. Front matter
;;; between two --- lines at the top sets the deck: theme (dark, light,
;;; paper, neon, ocean, compos), transition, duration, step, accent, font, title.
;;; <!-- key: value; key: value --> sets one slide: transition, duration,
;;; bg, color, class (title center top big accent cols), build, step, focus.
;;; A + list item, or a block that ends in {step ANIM}, waits for a key.
;;; A block that ends in {ANIM} animates in when its slide arrives.
;;; A line of ??? starts the slide's speaker notes; s shows them.
;;;
;;; The presenter is an app buffer, *slides: NAME*. Its page carries the
;;; deck as JSON, and slides/slides.js draws it (preview.scm runs the page).
;;; Saving the deck redraws the presenter at the slide being edited.
;;;
;;; slides/starter.md is the reference deck: every directive, transition,
;;; animation, background image, image row and layout at work. Read it
;;; before writing a deck, and start from it with slides-new!.

(namespace! 'slides)
(domain! 'writing)
(effects! '(write))

(defgroup 'slides "Markdown slide decks.")

(defcustom 'slides-live-delay-ms 300
  "Idle milliseconds after an edit to a deck before its presenter redraws."
  'group 'slides)

(define (slides--directory)
  (let ((js (locate-library "slides/slides.js")))
    (and js (substring js 0 (- (string-length js) (string-length "/slides.js"))))))

(define (slides--short-name source)
  (let ((path (buffer-path source)))
    (if path (car (reverse (string-split path "/"))) source)))

(define (slides-app-name source)
  (string-append "*slides: " (slides--short-name source) "*"))

;; the 0-based line of the deck's point: the presenter opens at its slide
(define (slides--line source)
  (with-current-buffer source (lambda () (- (line-number-at-pos (point)) 1))))

;; The deck travels as JSON inside the page. Every < is escaped, so the
;; source can never close the script element that holds it.
(define (slides--page source live? stamp)
  (string-append
    "<!doctype html><html><head><meta charset='utf-8'>"
    "<meta name='viewport' content='width=device-width,initial-scale=1'>"
    "<title>" (html-escape (slides--short-name source)) "</title>"
    "<link rel='stylesheet' href='slides.css'></head><body>"
    "<script type='application/json' id='deck'>"
    (re-replace-all "<"
      (json-encode (list 'source (buffer-text source)
                         'line (slides--line source)
                         'live live?
                         'stamp stamp))
      "\\u003c")
    "</script><script src='slides.js'></script></body></html>"))

;; The folders the page reads its relative files from: slides.js and
;; slides.css first, then the deck's own folder, so an image path in a
;; deck reads as it does in any Markdown file.
(define (slides--directories source)
  (let ((deck (buffer-path source)))
    (if deck
        (list (slides--directory) (re-replace "[^/]*$" deck ""))
        (slides--directory))))

;; The page loads slides.js and slides.css as relative files; the app
;; server answers those from the pathless buffer's 'app-directory,
;; with the deck's images beside the deck. The stamp names this
;; rendering: a page that loads again with the same stamp (a relayout
;; remounts the frame) resumes where it was.
(define (slides--render! app source live?)
  (let ((stamp (+ 1 (or (buffer-local app 'app-generation) 0))))
    (buffer-set-local! app 'app-directory (slides--directories source))
    (buffer-set-read-only! app #f)
    (buffer-replace-range! app 0 (buffer-size app) (slides--page source live? stamp))
    (buffer-set-read-only! app #t)
    (buffer-set-local! app 'preview-renderer "html")
    (buffer-set-local! app 'render-mode "app")
    (app-reload! app)))

;;; --- the live link ----------------------------------------------------------

(define (slides--unwatch! source)
  (let ((id (and (buffer-exists? source) (buffer-local source 'slides-watch))))
    (when id
      (remove-on-change! id)
      (buffer-set-local! source 'slides-watch #f))))

;; A live edit reaches the running page as a message, with no reload: the
;; page redraws in place, so nothing flashes and no focus moves. The buffer
;; takes the same deck, so a page loaded later draws it too.
(define (slides--send! app source)
  (let ((line (slides--line source))
        (text (buffer-text source)))
    (buffer-set-local! source 'slides-sent-line line)
    (buffer-set-local! source 'slides-sent-source text)
    (app-post! app (list 'source text
                         'line line
                         'live #t
                         'stamp (or (buffer-local app 'app-generation) 0)))))

(define (slides--post! app source)
  (let ((stamp (or (buffer-local app 'app-generation) 0)))
    (buffer-set-read-only! app #f)
    (buffer-replace-range! app 0 (buffer-size app) (slides--page source #f stamp))
    (buffer-set-read-only! app #t)
    (buffer-set-local! source 'slides-edited #f)
    (slides--send! app source)))

(define (slides--refresh! source)
  (let ((app (and (buffer-exists? source) (buffer-local source 'slides-app))))
    (if (and app (buffer-exists? app))
        (slides--post! app source)
        (slides--unwatch! source))))

;; an edit marks the deck; the save redraws it at the edited slide
(define (slides--watch! source)
  (unless (buffer-local source 'slides-watch)
    (desktop-skip! source 'slides-watch)
    (buffer-set-local! source 'slides-watch
      (on-change! source
        (lambda (pos inserted deleted origin)
          (buffer-set-local! source 'slides-edited #t))))))

;; Until the in-place redraw stops flashing, the presenter redraws when the
;; deck is saved, not on every change.
(define (slides--after-save!)
  (let ((source (current-buffer)))
    (when (buffer-local source 'slides-watch)
      (slides--refresh! source))))

(add-hook! 'after-save-hook 'slides--after-save!)

;; Moving point in a deck moves the presenter line by line: the slide that
;; holds point, with the steps up to point's line shown (slides--at).
(define (slides--follow-point! &optional buf)
  (let* ((source (or buf (current-buffer)))
         (app (buffer-local source 'slides-app))
         (line (and app (slides--line source))))
    (when (and app
               (buffer-local source 'slides-watch)
               (buffer-exists? app)
               (not (equal? line (buffer-local source 'slides-sent-line))))
      (buffer-set-local! source 'slides-sent-line line)
      (let ((at (slides--at source)))
        (app-post! app (list 'goto (list 'slide (car at) 'step (cadr at))))))))

(add-hook! 'post-command-hook 'slides--follow-point!)
;; the editing state moves point with the client's caret, not a command
(add-hook! 'point-motion-hook 'slides--follow-point!)

;; slides-deck-mode marks a deck linked to its presenter. Point moves the
;; presenter (slides--follow-point!), a save redraws it, and the keys step
;; it from the deck, with its transitions, while point stays put.
(define (slides--step! dir)
  (let ((app (buffer-local (current-buffer) 'slides-app)))
    (if (and app (buffer-exists? app))
        (app-post! app (list 'step dir))
        (message "This deck is not presented: C-c C-s presents it"))))

(define-command "slides-next" "Step the presented slides forward from the deck"
  (lambda () (slides--step! "next")))

(define-command "slides-previous" "Step the presented slides back from the deck"
  (lambda () (slides--step! "prev")))

(register-minor-mode! "slides-deck-mode"
  (lambda (buf) (when (buffer-local buf 'slides-app) (slides--watch! buf)))
  (lambda (buf)
    (slides--unwatch! buf)
    (buffer-set-local! buf 'slides-app #f)))

(minor-mode-keys! "slides-deck-mode"
  '(("C-c C-s" "slides-present")
    ("C-c C-n" "slides-next")
    ("C-c C-p" "slides-previous")
    ("M-<down>" "slides-next-slide")
    ("M-<up>" "slides-previous-slide")
    ("M-S-<down>" "slides-select-next")
    ("M-S-<up>" "slides-select-previous")))

(mode-doc! "slides-deck-mode"
  "A slide deck. `M-<up>` and `M-<down>` move by slide, and `M-S-<up>` and `M-S-<down>` select a slide and grow the selection by one slide each time. Once presented, moving point shows the slide at point, and a save redraws the slides. `C-c C-n` and `C-c C-p` step the slides forward and back, with their transitions. `C-c C-s` presents the deck again. `M-x slides-deck-mode` unlinks it.")

;; a .slides file is a deck from the moment it opens
(define (slides--on-visit!)
  (let* ((buf (current-buffer)) (path (buffer-path buf)))
    (when (and path (string-suffix? ".slides" path))
      (enable-minor-mode! buf "slides-deck-mode"))))

(add-hook! 'find-file-hook 'slides--on-visit!)

;;;###autoload
(define-command "slides-deck-mode" "Link or unlink this deck and its slides"
  (lambda ()
    (if (toggle-minor-mode! "slides-deck-mode")
        (run-command "slides-present")
        (message "Deck unlinked from its slides"))))

;; Slides as tree-sitter sees them: the markdown grammar parses the deck
;; text (the buffer keeps morg's own drawing) and each thematic break of
;; dashes ends a slide, so a --- inside a code fence or the front matter
;; is not one. A slide is (START END CONTENT): END is where its break
;; begins, CONTENT the first non-blank byte, where the motion lands.
(define (slides--char buf pos)
  (with-current-buffer buf (lambda () (buffer-substring pos (+ pos 1)))))

;; two lists of (NAME START END) in start order, as one in start order
(define (slides--merge ab)
  (let loop ((a (car ab)) (b (cadr ab)) (acc '()))
    (cond ((null? a) (append (reverse acc) b))
          ((null? b) (append (reverse acc) a))
          ((< (cadr (car a)) (cadr (car b))) (loop (cdr a) b (cons (car a) acc)))
          (else (loop a (cdr b) (cons (car b) acc))))))

(define (slides--spans buf)
  (let* ((text (buffer-text buf))
         (size (buffer-size buf))
         (meta (ts-query-string "markdown" text "(minus_metadata) @m"))
         ;; a --- right under a line of text underlines a heading to the
         ;; grammar, but the page ends a slide there too
         (breaks (slides--merge
                   (list
                     (filter (lambda (r) (equal? (slides--char buf (cadr r)) "-"))
                             (ts-query-string "markdown" text "(thematic_break) @b"))
                     (ts-query-string "markdown" text "(setext_h2_underline) @u"))))
         (content (lambda (pos)
                    (let loop ((p pos))
                      (if (and (< p size) (member (slides--char buf p) '(" " "\n" "\t")))
                          (loop (+ p 1))
                          p)))))
    (let loop ((start (if (pair? meta) (caddr (car meta)) 0)) (bs breaks) (acc '()))
      (let ((end (if (pair? bs) (cadr (car bs)) size)))
        (let ((acc (cons (list start end (content start)) acc)))
          (if (pair? bs) (loop (caddr (car bs)) (cdr bs) acc) (reverse acc)))))))

;; The steps of a deck, from the same grammar: a + item, or a block whose
;; last line ends in {... step ...}, as the page reads them (slides.js). A
;; list item's first line is its own paragraph, so that paragraph is the
;; item's and not a second step. A ??? paragraph starts a slide's notes.
;; Answers (STEPS NOTES): the byte where each step starts, and each ??? .
(define (slides--steps buf)
  (let* ((text (buffer-text buf))
         (q (lambda (query) (ts-query-string "markdown" text query)))
         (sub (lambda (r) (with-current-buffer buf (lambda () (buffer-substring (cadr r) (caddr r))))))
         (first-line (lambda (s) (let ((i (string-index s "\n"))) (if i (substring s 0 i) s))))
         (step? (lambda (s)
                  (let ((m (re-match "\\{([^{}`]*)\\}\\s*$" (string-trim s))))
                    (and m (member "step" (string-split (string-trim (cadr m)) " "))))))
         (items (q "(list_item) @i"))
         (pluses (map cadr (q "(list_marker_plus) @m")))
         (item-heads (map (lambda (r) (list (cadr r) (+ (cadr r) (string-length (first-line (sub r)))))) items))
         (in-item-head? (lambda (pos) (let loop ((h item-heads)) (cond ((null? h) #f) ((and (>= pos (car (car h))) (<= pos (cadr (car h)))) #t) (else (loop (cdr h)))))))
         (paras (q "(paragraph) @p"))
         ;; a paragraph's range can open on the blank line above it
         (lead (lambda (r) (+ (cadr r) (string-length (car (re-match "^\\s*" (sub r)))))))
         (notes (map lead (filter (lambda (r) (equal? (string-trim (sub r)) "???")) paras)))
         (steps (append
                  (map cadr (filter (lambda (r) (or (member (cadr r) pluses) (step? (first-line (sub r))))) items))
                  (map lead (filter (lambda (r) (and (not (in-item-head? (lead r))) (step? (sub r)))) paras))
                  (map cadr (filter (lambda (r) (step? (first-line (sub r)))) (q "(atx_heading) @h")))
                  (map cadr (filter (lambda (r) (step? (sub r))) (q "(info_string) @s"))))))
    (list (sort steps) notes)))

;; (SLIDE STEP) at point: the slide that holds it, as the page counts them
;; (a slide with nothing in it is none), and how many of its steps start
;; on or above point's line.
(define (slides--at buf)
  (let* ((p (buffer-point buf))
         (eol (with-current-buffer buf (lambda () (line-start-position (+ 1 (line-number-at-pos (point)))))))
         (spans (filter (lambda (s) (< (caddr s) (cadr s))) (slides--spans buf)))
         (sn (let loop ((s spans) (n 0))
               (cond ((null? s) (list (max 0 (- n 1)) (and (pair? spans) (car (reverse spans)))))
                     ((< p (cadr (car s))) (list n (car s)))
                     (else (loop (cdr s) (+ n 1))))))
         (span (cadr sn)))
    (if (not span)
        (list 0 0)
        (let* ((st (slides--steps buf))
               (in (lambda (x) (and (>= x (car span)) (< x (cadr span)))))
               (notes (filter in (cadr st)))
               (stop (if (pair? notes) (min eol (car notes)) eol)))
          (list (car sn) (length (filter (lambda (x) (and (in x) (< x stop))) (car st))))))))

(define (slides--goto-slide! dir)
  (let* ((p (point))
         (starts (map caddr (slides--spans (current-buffer))))
         (to (if (equal? dir 'next)
                 (let loop ((s starts)) (cond ((null? s) #f) ((> (car s) p) (car s)) (else (loop (cdr s)))))
                 (let loop ((s starts) (best #f)) (if (or (null? s) (>= (car s) p)) best (loop (cdr s) (car s)))))))
    (if to (goto-char! to) (message (if (equal? dir 'next) "Last slide" "First slide")))))

(define-command "slides-next-slide" "Move to the next slide of the deck"
  (lambda () (slides--goto-slide! 'next)))

(define-command "slides-previous-slide" "Move to the previous slide of the deck"
  (lambda () (slides--goto-slide! 'prev)))

;; The region grows a whole slide at a time. With no region the mark goes
;; to the far side of the slide at point, so the first press takes it all.
(define (slides--select-slide! dir)
  (let* ((p (point))
         (spans (slides--spans (current-buffer)))
         (here (let loop ((s spans)) (cond ((null? s) (car (reverse spans))) ((< p (cadr (car s))) (car s)) (else (loop (cdr s))))))
         (edges (if (equal? dir 'next) (map cadr spans) (map car spans)))
         (to (if (equal? dir 'next)
                 (let loop ((e edges)) (cond ((null? e) #f) ((> (car e) p) (car e)) (else (loop (cdr e)))))
                 (let loop ((e edges) (best #f)) (if (or (null? e) (>= (car e) p)) best (loop (cdr e) (car e)))))))
    (unless (mark) (set-mark! (if (equal? dir 'next) (car here) (cadr here))))
    (if to (goto-char! to) (message (if (equal? dir 'next) "Last slide" "First slide")))))

(define-command "slides-select-next" "Select the slide at point, then one more slide forward each time"
  (lambda () (slides--select-slide! 'next)))

(define-command "slides-select-previous" "Select the slide at point, then one more slide back each time"
  (lambda () (slides--select-slide! 'prev)))

;; f in the page gives the slides the whole frame, and f again puts the
;; frame back. The saved layout counts only while the slides still fill the
;; frame; after a C-x 1 or a split, f maximizes afresh.
(define (slides--window-of app)
  (let loop ((ws (window-list-all)))
    (cond ((null? ws) #f)
          ((equal? (cadr (car ws)) app) (car (car ws)))
          (else (loop (cdr ws))))))

(define (slides--maximize! app)
  (let ((win (slides--window-of app)))
    (if (not win)
        "hidden"
        (let ((prev (selected-frame))
              (frame (frame-of-window win)))
          (select-frame! frame)
          (let ((state
                 (with-frame-windows
                   (lambda ()
                     (let ((saved (buffer-local app 'slides-layout)))
                       (if (and saved (equal? (window-tree-buffers (window-tree)) (list app)))
                           (begin
                             (window-tree-set! saved)
                             (buffer-set-local! app 'slides-layout #f)
                             "restored")
                           (begin
                             (buffer-set-local! app 'slides-layout (window-tree))
                             (window-arrange-line! 'h 1.0 (list win))
                             "maximized")))))))
            (select-frame! prev)
            state)))))

;; The page reports the slide it shows, so e can open that slide's source
;; and a remounted page can resume; it asks for f through the same door.
(define (slides--slug text)
  (re-replace-all "^-+|-+$" (re-replace-all "[^a-z0-9]+" (string-downcase text) "-") ""))

;; the section of Markdown TEXT under the heading ANCHOR names, down to the
;; next heading of its level or above; #f when no heading has that name.
;; In a deck, a slide break ends it too.
(define (slides--section text anchor deck?)
  (let ((want (slides--slug anchor)))
    (let loop ((ls (string-split text "\n")) (level #f) (acc '()))
      (let ((h (and (pair? ls) (re-match "^(#+)\\s+(.*?)\\s*#*\\s*$" (car ls)))))
        (cond
          ((null? ls) (and level (string-join (reverse acc) "\n")))
          ((and level (or (and h (<= (string-length (cadr h)) level))
                          (and deck? (re-match? "^---+\\s*$" (car ls)))))
           (string-join (reverse acc) "\n"))
          (level (loop (cdr ls) level (cons (car ls) acc)))
          ((and h (equal? (slides--slug (caddr h)) want))
           (loop (cdr ls) (string-length (cadr h)) (list (car ls))))
          (else (loop (cdr ls) #f '())))))))

;; A slide's notes may be a link: PATH, PATH#ANCHOR or #ANCHOR. A path is
;; read beside the deck; #ANCHOR alone is a heading in the deck itself.
(define (slides--notes source ref)
  (let* ((parts (string-split ref "#"))
         (file (car parts))
         (anchor (and (pair? (cdr parts)) (string-join (cdr parts) "#")))
         (deck (buffer-path source))
         (path (cond ((equal? file "") deck)
                     ((or (string-prefix? "/" file) (string-prefix? "~" file)) (expand-path file))
                     (deck (expand-path (string-append (re-replace "[^/]*$" deck "") file)))
                     (else #f)))
         (text (cond ((not path) #f)
                     ((buffer-exists? path) (buffer-text path))
                     ((equal? path deck) (buffer-text source))
                     ((file-exists? path) (read-file path))
                     (else #f)))
         (section (and text (if anchor (slides--section text anchor (equal? path deck)) text))))
    (cond (section (list 'text section))
          (text (list 'error (string-append "No heading #" anchor " in " (if (equal? file "") "this deck" file))))
          (else (list 'error (string-append "No file " (if path path file)))))))

(define (slides--app-request buf method body)
  (and (buffer-exists? buf)
       (buffer-local buf 'slides-source)
       (cond
         ((equal? method "GET")
          (let ((at (buffer-local buf 'slides-at)))
            (list 200 (if (pair? at) (json-encode at) "{}"))))
         ((equal? method "POST")
          (let* ((msg (json-parse body))
                 (action (and (pair? msg) (plist-get msg 'action))))
            (cond
              ((equal? action "maximize")
               (list 200 (json-encode (list 'state (slides--maximize! buf)))))
              ((equal? action "notes")
               (let ((source (slides--deck buf)))
                 (list 200 (json-encode (if source
                                            (slides--notes source (or (plist-get msg 'ref) ""))
                                            (list 'error "The deck of these slides is gone"))))))
              (else
               (when (pair? msg) (buffer-set-local! buf 'slides-at msg))
               (list 200 "{}")))))
         (else (list 405 (json-encode (list 'error "The slides page answers GET and POST.")))))))

(add-hook! '(app-request slides) 'slides--app-request)

;;; --- presenting -------------------------------------------------------------

(define (slides-present! source)
  (let ((app (slides-app-name source)))
    (unless (buffer-exists? app)
      (buffer-create app)
      (when (boundp 'buffer-join-here!) (buffer-join-here! app)))
    (buffer-set-local! app 'slides-source source)
    (buffer-set-local! source 'slides-app app)
    (unless (equal? (buffer-local app 'mode-name) "slides-mode")
      (with-current-buffer app (lambda () (set-mode! "slides-mode"))))
    (slides--render! app source #f)
    (slides--watch! source)
    (enable-minor-mode! source "slides-deck-mode")
    app))

(define (slides--source-of buf)
  (or (buffer-local buf 'slides-source) buf))

;;;###autoload
(define-command "slides-present" "Present this Markdown buffer as slides in the other window"
  (lambda ()
    (let ((app (slides-present! (slides--source-of (current-buffer)))))
      (unless (window-showing app) (display-buffer-other-window! app))
      (message "Slides: → next, ← back, o overview, f maximize, ? keys. C-g gives the keyboard back."))))

(define-command "slides-reload" "Redraw the slides from their deck, from the slide at its point"
  (lambda ()
    (let ((source (slides--deck (current-buffer))))
      (if source
          (begin (slides-present! source) (message "Slides redrawn"))
          (message "The deck of these slides is gone")))))

;;;###autoload
(define-command "slides-edit" "Show the deck at the slide the presenter shows"
  (lambda ()
    (let* ((app (current-buffer))
           (source (slides--deck app))
           (at (buffer-local app 'slides-at))
           (line (+ 1 (or (and (pair? at) (plist-get at 'line)) 0))))
      (if source
          (begin
            (display-buffer-other-window! source)
            (with-current-buffer source
              (lambda () (goto-char! (line-start-position line)))))
          (message "The deck of these slides is gone")))))

(define (slides--starter)
  (read-file (string-append (slides--directory) "/starter.md")))

(define (slides-new! path)
  (let ((full (expand-path path)))
    (unless (file-exists? full) (write-file! full (slides--starter)))
    (switch-to-buffer! (visit full (buffer-group (current-buffer))))
    (run-command "slides-present")))

;;;###autoload
(define-command "slides-new" "Start a deck from the starter deck and present it"
  (lambda () (read-file-name "New deck: " slides-new!)))

;; The starter deck is the documentation too: every feature on a slide
;; that shows it. The demo presents the bundled deck itself.
(define (slides-demo!)
  (let* ((deck (visit (string-append (slides--directory) "/starter.md")
                      (buffer-group (current-buffer))))
         (app (slides-present! deck)))
    (unless (window-showing app) (display-buffer-other-window! app))
    app))

;;;###autoload
(define-command "slides-demo" "Present the slides demo: every feature of a deck, each on its own slide"
  (lambda () (slides-demo!)))

;;; --- the presenter buffer ---------------------------------------------------

;; the deck of a presenter, or #f
(define (slides--deck app)
  (let ((source (buffer-local app 'slides-source)))
    (cond ((not source) #f)
          ((buffer-exists? source) source)
          ((file-exists? source) (visit source (buffer-group app)))
          (else #f))))

;; A restored presenter has its page but lost its link to the deck; a deck
;; file that did not come back with it is opened again, unshown.
(define (slides--setup! app)
  (let ((source (slides--deck app)))
    (when source
      (buffer-set-local! app 'slides-source source)
      (buffer-set-local! source 'slides-app app)
      (slides--watch! source)
      (enable-minor-mode! source "slides-deck-mode"))))

(define-mode "slides-mode" (lambda () (slides--setup! (current-buffer))))

;; The page's own keys, for when the editor holds the keyboard: each one is
;; passed to the page as the key it would have read.
(define slides--page-keys
  '(("SPC" " ") ("RET" "Enter") ("DEL" "Backspace")
    ("<right>" "ArrowRight") ("<left>" "ArrowLeft")
    ("<down>" "ArrowDown") ("<up>" "ArrowUp")
    ("n" "n") ("p" "p") ("o" "o") ("f" "f") ("b" "b")
    ("d" "d") ("s" "s") ("?" "?")))

(define-command "slides-page-key" "Pass this key to the slides page"
  (lambda ()
    (let* ((keys (last-keys))
           (entry (and (pair? keys) (assoc (car keys) slides--page-keys))))
      (when entry
        (app-post! (current-buffer) (list 'key (cadr entry)))))))

(mode-keys! "slides-mode"
  (append '(("g" "slides-reload")
            ("e" "slides-edit")
            ("q" "quit-window"))
          (map (lambda (entry) (list (car entry) "slides-page-key"))
               slides--page-keys)))

(mode-doc! "slides-mode"
  "A deck presented. The page has the keyboard: `→` or `SPC` steps on, `←` steps back, `o` shows every slide, `f` gives the slides the whole frame and `f` again restores the layout, `b` blacks out, and `?` lists the keys. `C-g` gives the keyboard back; then `e` shows the deck at this slide, `g` redraws, and `C-c C-a` stops the page.")

;; A deck is a Morg document: a .slides file opens in morg-mode, so it
;; folds, links and pastes images like any other Markdown file.
(set! *auto-mode-alist*
  (cons '(".slides" "morg-mode")
        (filter (lambda (entry) (not (equal? (car entry) ".slides")))
                *auto-mode-alist*)))

(define-key (mode-keymap "morg-mode") "C-c C-s" "slides-present")

(public! 'slides-present!
  "(slides-present! BUF) — present Markdown buffer BUF as slides in its app buffer, without showing it; the app buffer's name. (slides--starter) reads the reference deck, slides/starter.md, which shows every directive")
(public! 'slides-app-name
  "(slides-app-name BUF) — the name of BUF's presenter buffer")
(public! 'slides-demo! "(slides-demo!) — present the demo deck, the tour of every slides feature; answers the presenter buffer")
(catalog-meta! 'function "slides-demo!" 'domain 'writing 'effects '(write display))
(public! 'slides-new!
  "(slides-new! PATH) — create PATH from the starter deck when missing, visit it and present it")
(catalog-meta! 'function "slides-present!" 'domain 'writing 'effects '(write))
(catalog-meta! 'function "slides-app-name" 'domain 'writing 'effects '(pure))
(catalog-meta! 'function "slides-new!" 'domain 'writing 'effects '(write display))
