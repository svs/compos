;; gallery.scm --- Dired as a grid of thumbnails
;;
;; gallery-mode is a minor mode of Dired. It draws the same rows as tiles:
;; an image shows its picture, a directory or another file its name and
;; kind. Nothing else changes: the rows, the marks, the filters, the
;; sorting and every Dired key stay Dired's, because the mode only lays
;; the buffer's 'list-view-opts over the list's own options.

(require 'tabulated-list)

(domain! 'files)
(effects! '(pure))

(defgroup 'gallery "Dired as a grid of thumbnails.")

(defcustom 'gallery-extensions
  '(".png" ".apng" ".jpg" ".jpeg" ".jfif" ".gif" ".webp" ".avif" ".bmp" ".ico" ".svg")
  "File suffixes gallery-mode draws as pictures."
  'group 'gallery 'type 'list)

(define (gallery-image? name)
  "(gallery-image? NAME) -- #t when NAME ends in one of gallery-extensions"
  (let ((n (string-downcase name)))
    (let loop ((es gallery-extensions))
      (cond ((null? es) #f)
            ((string-suffix? (car es) n) #t)
            (else (loop (cdr es)))))))

(define (gallery--kind name)
  "what a tile without a picture says it is: folder, up, or the extension"
  (cond ((equal? name "..") "up")
        ((string-suffix? "/" name) "folder")
        (else (let ((parts (string-split name ".")))
                (if (> (length parts) 1) (string-downcase (car (reverse parts))) "file")))))

(define (gallery--icon name)
  "the type icon Dired's table shows for NAME"
  (if (or (equal? name "..") (string-suffix? "/" name)) (mode-icon "Dired") (file-icon name)))

(effects! '(read))

(define (gallery--tile buf entry)
  (let* ((dir (dired-dir buf))
         (path (string-append dir "/" entry))
         (mark (assoc entry (list-marks buf)))
         (image? (and (not (string-suffix? "/" entry)) (gallery-image? entry)))
         (label (if (string-suffix? "/" entry) (substring entry 0 (- (string-length entry) 1)) entry)))
    (list 'tag "file" 'class (string-append "gallery-tile" (if image? "" " gallery-other"))
          'attrs (append (list (list "path" path) (list "name" entry))
                         (if mark (list (list "marked" "true")) '()))
          'children
          (append
            (if mark (list (list 'tag "span" 'class "gallery-mark" 'text (cadr mark))) '())
            (list (if image?
                      (list 'tag "img" 'class "gallery-thumb" 'file path
                            'attrs (list (list "alt" entry) (list "loading" "lazy") (list "decoding" "async")))
                      (list 'tag "div" 'class (string-append "gallery-thumb gallery-kind"
                                                         (if (or (equal? entry "..") (string-suffix? "/" entry)) " gallery-dir" ""))
                            'children (list (list 'tag "span" 'class "gallery-icon" 'text (gallery--icon entry))
                                            (list 'tag "span" 'class "gallery-kind-label" 'text (gallery--kind entry)))))
                  (list 'tag "div" 'class "gallery-name" 'text label))))))

(define (gallery--head buf head)
  "Dired's title and counts, without the column labels a grid has no use for"
  (list (list 'tag "div" 'class "gallery-head"
              'children (map (lambda (ln) (list 'tag "div" 'class "gallery-head-line" 'text (car ln)))
                             (filter (lambda (ln) (let ((t (string-trim (car ln))))
                                                    (and (not (equal? t ""))
                                                         (not (string-prefix? "─" t))
                                                         (not (string-prefix? "NAME" (string-upcase t))))))
                                     (list-head head (min 2 (length head))))))))

(define-style! 'gallery "
.semantic-list:has(> .gallery-tile) { display: grid; grid-template-columns: repeat(auto-fill, minmax(9.5rem, 1fr)); gap: .75rem; padding: .25rem .9rem 1rem; }
.semantic-list > .semantic-item.gallery-tile { display: flex; flex-direction: column; gap: .3rem; padding: .4rem .4rem .5rem; border: 0; border-radius: 10px; background: transparent; position: relative; }
.semantic-list > .semantic-item.gallery-tile:hover { background: color-mix(in srgb, var(--hl-line-bg) 60%, transparent); }
.semantic-list > .semantic-item.gallery-tile.selected { background: var(--hl-line-bg); }
.semantic-list > .semantic-item.gallery-tile.selected .gallery-thumb { box-shadow: 0 0 0 2px var(--accent-fg); }
.semantic-list > .semantic-item.gallery-tile[marked=true] { background: color-mix(in srgb, var(--accent-fg) 14%, transparent); }
.semantic-list > .semantic-item.gallery-tile[marked=true] .gallery-thumb { box-shadow: 0 0 0 2px var(--accent-fg); }
.gallery-mark { position: absolute; top: .7rem; left: .7rem; z-index: 1; min-width: 1.3rem; height: 1.3rem; line-height: 1.3rem; text-align: center; border-radius: 999px; font: 600 .72rem var(--font-sans); color: var(--default-bg, #fff); background: var(--accent-fg); }
.gallery-thumb { display: block; width: 100%; aspect-ratio: 4 / 3; object-fit: cover; border-radius: 7px; background: color-mix(in srgb, var(--dim-fg) 10%, transparent); }
.gallery-kind { display: flex; flex-direction: column; align-items: center; justify-content: center; gap: .35rem; color: var(--dim-fg); }
.gallery-icon { font-family: var(--font-icons); font-size: 2.6rem; line-height: 1; }
.gallery-dir .gallery-icon { color: var(--accent-fg); }
.gallery-kind-label { font: 600 .66rem var(--font-sans); letter-spacing: .08em; text-transform: uppercase; }
.gallery-name { display: block; font-family: var(--font-sans); font-size: .78rem; line-height: 1.3; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; padding: 0 .15rem; }
.gallery-head { display: block; padding: .7rem .9rem .3rem; font-family: var(--font-sans); }
.gallery-head-line { display: block; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.gallery-head-line:first-child { font-size: 1.05rem; font-weight: 600; }
.gallery-head-line + .gallery-head-line { font-size: .75rem; color: var(--dim-fg); margin-top: .1rem; }
")

(define *gallery-view-opts*
  (list 'composml gallery--tile 'composml-head gallery--head))

(effects! '(write display))

(define (gallery--on! buf)
  (buffer-set-local! buf 'list-view-opts *gallery-view-opts*)
  (list-refresh! buf))

(define (gallery--off! buf)
  ;; the grid drew its own blocks; a table is its text and records, as
  ;; list-mode setup leaves it, so the blocks go or the tiles would stay
  (buffer-set-local! buf 'list-view-opts #f)
  (buffer-set-local! buf 'render-mode #f)
  (buffer-set-local! buf 'render-blocks #f)
  (buffer-set-local! buf 'render-root #f)
  (list-refresh! buf))

(register-minor-mode! "gallery-mode"
  gallery--on!
  gallery--off!)

(mode-doc! "gallery-mode"
  "Dired as a grid of thumbnails. An image shows its picture; a directory or another file shows its name and kind. Every Dired key works as before: SPC and m mark, / narrows, s sorts, RET opens, x trashes the marked files. v, or M-x gallery-mode, switches between the grid and the table.")

(define-command "gallery-mode" "Show this Dired as a grid of thumbnails, or as the table again"
  (lambda ()
    (if (equal? (list-mode-of (current-buffer)) "Dired")
        (toggle-minor-mode! "gallery-mode")
        (message "gallery-mode works in Dired")))
  'aliases "image viewer thumbnails pictures photos grid")

;; v in Dired switches between the table and the grid
(define-key (mode-keymap "Dired") "v" "gallery-mode")

(effects! '(pure))
(public! 'gallery-image? "(gallery-image? NAME) — #t when NAME ends in one of gallery-extensions")

(provide 'gallery)
