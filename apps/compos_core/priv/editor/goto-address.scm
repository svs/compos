;;; goto-address.scm --- every URL and every file path is a link.
;;;
;;; Core editor behaviour, not a mode: in every buffer that shows text, a
;;; URL and a path that names a file on disk wear the link face and carry
;;; their target, so a click follows them and C-c RET follows the one at
;;; point. A path may end in :LINE or :LINE:COL, and the visit lands on
;;; that line. The text is never changed: the link is an overlay, rebuilt
;;; on every change, when a buffer appears, and when it is restored.
;;; (Emacs: goto-address-mode plus ffap, always on.)

(domain! 'interaction)
(effects! '(read display))

;; a URL: a scheme, a colon, and everything up to a space or a bracket.
;; Sentence punctuation after it is prose, not URL.
(define goto-address--url-pattern
  "\\b(https?|ftp|file|mailto|compos):[^ \\t\\n<>\"'`()\\[\\]]+")

;; a path: an optional ~ or . or .. prefix, then at least one slash between
;; path words, then an optional :LINE or :LINE:COL. The trailing range of
;; punctuation is prose.
(define goto-address--path-pattern
  "(?<![A-Za-z0-9_/.:-])(?:~|\\.\\.?)?/?[A-Za-z0-9_.@%+-]+(?:/[A-Za-z0-9_.@%+-]+)+/?(?::[0-9]+(?::[0-9]+)?)?")

;; a bare file name: a word with an extension and no slash, such as
;; init.scm or README.md, with the same optional :LINE. It is a link only
;; when a file by that name stands beside the buffer's file or at the
;; project root, so a method name like String.split costs one stat and
;; paints nothing.
(define goto-address--file-pattern
  "(?<![A-Za-z0-9_/.:@-])[A-Za-z0-9_-][A-Za-z0-9_.-]*\\.[A-Za-z0-9]{1,6}(?::[0-9]+(?::[0-9]+)?)?(?![A-Za-z0-9_/.@-])")

(define goto-address--trailing-prose ".,;:!?")

;; a byte range shrunk past trailing punctuation
(define (goto-address--trim line s e)
  (let loop ((e e))
    (if (and (> e s)
             (string-index goto-address--trailing-prose
                           (substring-bytes line (- e 1) e)))
        (loop (- e 1))
        e)))

;; "path:12:3" -> ("path" 12) ; "path" -> ("path" #f)
(define (goto-address-path-parts text)
  (let ((g (re-groups "^(.*?)(?::([0-9]+))?(?::[0-9]+)?$" text 0)))
    (if (not g)
        (list text #f)
        (let* ((p (nth 1 g))
               (l (and (> (length g) 2) (nth 2 g)))
               (path (substring-bytes text (car p) (cadr p)))
               (line (and l (>= (car l) 0)
                          (string->number (substring-bytes text (car l) (cadr l))))))
          (list path (and (number? line) line))))))

(define (goto-address--on-disk? full)
  (or (file-exists? full) (file-directory? full)))

;; the git root above DIR, when project.scm is loaded and there is one
(define (goto-address--project-root dir)
  (and (boundp 'project-root-cached)
       (project-root-cached (strip-trailing-slash dir))))

;; the file PATH names, or #f. A relative path is read beside the buffer's
;; file first, then from the project root: a document names its files
;; the way its repository does.
(define (goto-address--resolve buf path)
  (if (or (string-prefix? "/" path) (string-prefix? "~" path))
      (let ((full (expand-path path)))
        (and (goto-address--on-disk? full) full))
      (let* ((dir (buffer-directory buf))
             (beside (expand-path (string-append dir path)))
             (root (goto-address--project-root dir))
             (at-root (and root (expand-path (string-append root "/" path)))))
        (cond ((goto-address--on-disk? beside) beside)
              ((and at-root (goto-address--on-disk? at-root)) at-root)
              (else #f)))))

;; the names one paint has already asked the disk about: a source file
;; names the same few files many times, and a stat per mention adds up
(define *goto-address--memo* '())

(define (goto-address--resolve-memo buf path)
  ;; rows are two-element lists: a value here is a BEAM list, not a pair
  (let ((hit (assoc path *goto-address--memo*)))
    (if hit
        (cadr hit)
        (let ((full (goto-address--resolve buf path)))
          (set! *goto-address--memo* (cons (list path full) *goto-address--memo*))
          full))))

(define (goto-address--path-target buf text)
  (let* ((parts (goto-address-path-parts text))
         (full (goto-address--resolve-memo buf (car parts))))
    (and full
         (if (cadr parts)
             (string-append full "?line=" (number->string (cadr parts)))
             full))))

;; the class names the face, this painter, and the target. The painter's
;; own token tells its overlays from a Markdown link's on repaint.
(define (goto-address--class target)
  (string-append "link goto-address link-to:" (url-encode target)))


;; a range inside one of RANGES
(define (goto-address--covered? ranges s e)
  (let loop ((rs ranges))
    (cond ((null? rs) #f)
          ((and (<= (car (car rs)) s) (<= e (cadr (car rs)))) #t)
          (else (loop (cdr rs))))))

;; the link spans of one line: (START END CLASS), byte offsets from START
(define (goto-address-line-spans buf start line)
  (let* ((urls (map (lambda (r)
                      (list (car r) (goto-address--trim line (car r) (cadr r))))
                    (re-find* goto-address--url-pattern line)))
         (url-spans
           (map (lambda (r)
                  (list (+ start (car r)) (+ start (cadr r))
                        (goto-address--class
                          (substring-bytes line (car r) (cadr r)))))
                urls))
         (paths (if (string-index line "/")
                    (re-find* goto-address--path-pattern line)
                    '()))
         (files (if (string-index line ".")
                    (re-find* goto-address--file-pattern line)
                    '()))
         ;; a bare file name inside a path or a URL is that path's word
         (own-files (filter (lambda (r)
                              (not (goto-address--covered? paths (car r) (cadr r))))
                            files))
         (path-spans
           (fold (lambda (acc r)
                   (let* ((s (car r))
                          (e (goto-address--trim line s (cadr r)))
                          (target (and (not (goto-address--covered? urls s e))
                                       (goto-address--path-target
                                         buf (substring-bytes line s e)))))
                     (if target
                         (cons (list (+ start s) (+ start e)
                                     (goto-address--class target))
                               acc)
                         acc)))
                 '()
                 (append paths own-files))))
    (append url-spans (reverse path-spans))))

;; a buffer past this size paints no links: a dump is read, not clicked
(define goto-address-max-bytes 8000000)

;; a buffer up to this size paints on the spot when it is first watched;
;; a larger one paints a moment later, off the caller's call, up to the
;; first-paint size (about half a second per 500 KB); past that its lines
;; paint as they change
(define goto-address-small-bytes 65536)
(define goto-address-first-paint-bytes 1000000)

;; the spans of TEXT, whose first byte stands at AT in the buffer
(define (goto-address--text-spans buf at text)
  (set! *goto-address--memo* '())
  (let loop ((lines (split-lines text)) (at at) (acc '()))
    (if (null? lines)
        acc
        (let ((line (car lines)))
          (loop (cdr lines)
                (+ at (string-byte-length line) 1)
                (append acc (goto-address-line-spans buf at line)))))))

(define (goto-address-spans buf)
  (let ((text (buffer-text buf)))
    (if (> (string-byte-length text) goto-address-max-bytes)
        '()
        (goto-address--text-spans buf 0 text))))

;; the whole buffer: once, when it is first watched
(define (goto-address-paint! buf)
  (when (buffer-exists? buf)
    (overlay-set! buf 'goto-address (goto-address-spans buf))))

;; the end of the line holding POS: the byte after its newline, or the
;; buffer's end. Read in chunks, so a long line costs its own length and
;; a large buffer costs nothing.
(define (goto-address--line-end buf pos)
  (let ((size (buffer-size buf)))
    (let loop ((at pos))
      (if (>= at size)
          size
          (let* ((chunk-end (min size (+ at 4096)))
                 (chunk (buffer-substring at chunk-end))
                 (nl (string-index chunk "\n")))
            (if nl (+ at nl 1) (loop chunk-end)))))))

;; A change touched [POS, POS+INSERTED): only the lines it touched are
;; read again. The overlays outside them followed the rope already, so
;; they stay as they are. This is what a keystroke costs.
(define (goto-address-repaint! buf pos inserted)
  (when (buffer-exists? buf)
    (with-current-buffer buf
      (lambda ()
        (let* ((size (buffer-size buf))
               (from (max 0 (min pos size)))
               (to (min size (+ from (string-byte-length inserted))))
               (ls (line-start-position (line-number-at-pos from)))
               (le (goto-address--line-end buf to))
               ;; this painter's own ranges alone, rope-adjusted: a
               ;; keystroke never reads the syntax highlight's thousands
               (kept (filter (lambda (o)
                               (and (< (car o) (cadr o))
                                    (or (<= (cadr o) ls) (>= (car o) le))))
                             (buffer-overlays buf 'goto-address)))
               (fresh (goto-address--text-spans buf ls (buffer-substring ls le))))
          (overlay-set! buf 'goto-address (append kept fresh)))))))

;;; --- every buffer ------------------------------------------------------------

;; the reactor binds a rule to one buffer process, so a second watch of
;; the same name replaces the first, as font-lock does
(define *goto-address-hooks* '())

;; a listing draws rows, and the row is the action: Dired and every
;; list mode take no link paint (docs/LISTS.md, quiet popups)
(define (goto-address--listing? buf)
  (let ((mode (buffer-local buf 'mode-name)))
    (and (string? mode)
         (or (equal? mode "Dired")
             (equal? mode "dired-mode")
             (and (boundp '*list-modes*) (assoc mode *list-modes*) #t)))))

;; text a reader sees: not a hidden buffer, not a process transcript,
;; not a listing
(define (goto-address--eligible? buf)
  (and (not (string-prefix? " " buf))
       (not (process-running? buf))
       (not (goto-address--listing? buf))))

;; a rule whose buffer died removes with an error; the entry is stale
;; either way, so the error says nothing a caller can use
(define (goto-address--drop-rule! id)
  (ignore-errors (lambda () (remove-on-change! id))))

(define (goto-address-watch! buf)
  (let ((old (assoc buf *goto-address-hooks*)))
    ;; a rule on a buffer that is gone would never fire again
    (when old (goto-address--drop-rule! (cadr old)))
    (set! *goto-address-hooks*
      (cons (list buf
                  (on-change! buf
                    (lambda (pos inserted deleted source)
                      (unless (equal? source "locals")
                        (goto-address-repaint! buf pos inserted)))))
            (remove (lambda (e) (equal? (car e) buf)) *goto-address-hooks*)))
    ;; the first paint reads the whole buffer once. A small buffer paints
    ;; now. A large one paints a moment later through debounce!, a timer
    ;; that lands on the UI lane after this call returns: a task here
    ;; would call the Session back, and at boot the Session is the caller
    ;; (the await_boot self-call). A buffer past the first-paint size gets
    ;; its links as its lines change instead.
    (let ((size (buffer-size buf)))
      (cond ((<= size goto-address-small-bytes) (goto-address-paint! buf))
            ((<= size goto-address-first-paint-bytes)
             (debounce! (string-append "goto-address:" buf) 50
                        (lambda (b) (goto-address-paint! b)) buf))
            (else #f)))))

(define (goto-address-unwatch! buf)
  (let ((old (assoc buf *goto-address-hooks*)))
    (when old
      (goto-address--drop-rule! (cadr old))
      (set! *goto-address-hooks*
        (remove (lambda (e) (equal? (car e) buf)) *goto-address-hooks*))))
  (when (buffer-exists? buf) (overlay-clear! buf 'goto-address)))

;; a buffer that appears, wakes, reaches a window, or takes a mode gets
;; its links. A buffer already watched is left alone: the rule it has
;; follows the rope on its own.
(define (goto-address--new-buffer! buf)
  (when (and (string? buf)
             (goto-address--eligible? buf)
             (not (assoc buf *goto-address-hooks*))
             (buffer-exists? buf))
    (goto-address-watch! buf)))

;; a buffer that takes a mode is judged again: a plain buffer that
;; becomes a listing loses its links, a listing that becomes text gains them
(define (goto-address--mode-hook!)
  (let ((buf (current-buffer)))
    (if (and (assoc buf *goto-address-hooks*) (not (goto-address--eligible? buf)))
        (goto-address-unwatch! buf)
        (goto-address--new-buffer! buf))))

(add-hook! 'buffer-created-hook 'goto-address--new-buffer!)
(add-hook! 'buffer-shown-hook 'goto-address--new-buffer!)
(add-hook! 'buffer-woken-hook 'goto-address--new-buffer!)
(add-hook! 'after-change-major-mode-hook 'goto-address--mode-hook!)

;;; --- following ---------------------------------------------------------------

;; the link overlay under POS, as its href, or #f
(define (goto-address-href-at buf pos)
  (let loop ((ovs (buffer-overlays buf)))
    (cond ((null? ovs) #f)
          ((and (<= (car (car ovs)) pos) (< pos (cadr (car ovs)))
                (string-index (caddr (car ovs)) "link-to:"))
           (let* ((cls (caddr (car ovs)))
                  (at (+ 8 (string-index cls "link-to:"))))
             (url-decode (substring cls at (string-length cls)))))
          (else (loop (cdr ovs))))))

;; follow the link under point; #t when there was one. M-. asks this
;; first in every mode: a link is the definition of what it names.
(define (goto-address-follow-at-point!)
  (let ((href (goto-address-href-at (current-buffer) (point))))
    (and href
         (begin (preview-follow-link! (active-window) href) #t))))

;; One verb: go to what point names. A link is followed. Anything else
;; goes to the finder this buffer binds on M-. (a mode's definition
;; command), so C-c RET and M-. answer the same way everywhere.
(define (goto-address--finder)
  (let ((cmd (key-binding (list "M-."))))
    (and (string? cmd) (not (equal? cmd "goto-address-at-point")) cmd)))

(define-command "goto-address-at-point"
  "Follow the URL or file path at point, else find the definition of the name there"
  (lambda ()
    (unless (goto-address-follow-at-point!)
      (let ((finder (goto-address--finder)))
        (if finder
            (run-command finder)
            (message "No URL or file path at point"))))))

(global-set-key "C-c RET" "goto-address-at-point")

(catalog-meta! 'command "goto-address-at-point" 'domain "interaction" 'effects '("display"))

(public! 'goto-address-paint!
  "(goto-address-paint! BUF) — paint every URL and existing file path in BUF as a link overlay")
(public! 'goto-address-repaint!
  "(goto-address-repaint! BUF POS INSERTED) — repaint the lines a change at POS touched, and no other")
(public! 'goto-address-path-parts
  "(goto-address-path-parts TEXT) — split \"path:LINE[:COL]\" into (PATH LINE), LINE #f when absent")
(public! 'goto-address-follow-at-point!
  "(goto-address-follow-at-point!) — follow the URL or file path under point; #t when there was one")
(public! 'goto-address-href-at
  "(goto-address-href-at BUF POS) — the link target under byte POS, or #f")

;; the buffers that exist already, at boot and on a reload
(for-each goto-address--new-buffer! (buffer-list))
