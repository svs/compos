;;; pdf.scm --- Read and structurally edit local PDF documents.
;;;
;;; Poppler turns one page into a PNG and extracts its text. Scheme owns the
;;; reader/editor state, commands, keys, HTML projection, and desktop rebuild.

(package! 'pdf)
(domain! 'documents)
(effects! '(read write execute))

(defgroup 'pdf "PDF document reading.")

(defcustom 'pdf-render-width 1200
  "The page width in pixels at 100 percent zoom."
  'group 'pdf 'type 'number)

(defcustom 'pdf-zoom-step 25
  "The percentage added or removed by one zoom command."
  'group 'pdf 'type 'number)

(define pdf-min-zoom 50)
(define pdf-max-zoom 250)

;; Tests replace these seams. Production keeps parsing and process work
;; outside the mode policy below.
(define *pdf-page-count*
  (lambda (path)
    (or
      (string->number
        (string-trim
          (shell-command->string
            (string-append
              "pdfinfo " (sh-quote path)
              " 2>/dev/null | awk '/^Pages:/ {print $2; exit}'"))))
      0)))

(define (pdf--path-key path)
  (string-trim
    (shell-command->string
      (string-append
        "printf '%s' " (sh-quote path)
        " | cksum | awk '{print $1}'"))))

(define (pdf--cache-dir path)
  (let ((stamp (number->string (file-mtime path))))
    (string-append (aimax-home) "/pdf-cache/"
                   (pdf--path-key (string-append path ":" stamp)))))

(define (pdf--clear-render-cache-real path)
  ;; Stable working-copy paths can change more than once per second. Clear the
  ;; current version's cache so a same-second edit cannot show an old page.
  (shell-command->string
    (string-append "rm -rf -- " (sh-quote (pdf--cache-dir path))))
  #t)

(define *pdf-clear-render-cache!* pdf--clear-render-cache-real)

(define (pdf--page-file path page zoom)
  (let ((width (quotient (* pdf-render-width zoom) 100)))
    (string-append (pdf--cache-dir path) "/page-"
                   (number->string page) "-" (number->string width) ".png")))

(define (pdf--render-page-real path page zoom)
  (let* ((file (pdf--page-file path page zoom))
         (prefix (substring file 0 (- (string-length file) 4)))
         (width (quotient (* pdf-render-width zoom) 100)))
    (unless (file-exists? file)
      (shell-command->string
        (string-append
          "mkdir -p -- " (sh-quote (pdf--cache-dir path))
          " && pdftoppm -f " (number->string page)
          " -l " (number->string page)
          " -singlefile -png -scale-to " (number->string width)
          " " (sh-quote path) " " (sh-quote prefix) " 2>/dev/null")))
    (and (file-exists? file)
         (string-trim
           (shell-command->string
             (string-append "base64 < " (sh-quote file) " | tr -d '\\n'"))))))

(define *pdf-render-page* pdf--render-page-real)

(define *pdf-page-text*
  (lambda (path page)
    (shell-command->string
      (string-append
        "pdftotext -f " (number->string page)
        " -l " (number->string page)
        " -layout " (sh-quote path) " - 2>/dev/null"))))

(define *pdf-file-exists?* file-exists?)
(define *pdf-working-copy-exists?* file-exists?)

(define (pdf--command-succeeded? output)
  (and output (string-contains? output "AIMAX_PDF_OK")))

(define (pdf--copy-file-real source destination)
  (pdf--command-succeeded?
    (shell-command->string
      (string-append
        "cp -p -- " (sh-quote source) " " (sh-quote destination)
        " && printf '\\nAIMAX_PDF_OK\\n'"))))

(define *pdf-copy-file!* pdf--copy-file-real)

(define pdf--edit-sequence 0)

(define (pdf--next-edit-temp-dir)
  (set! pdf--edit-sequence (+ pdf--edit-sequence 1))
  (string-append (aimax-home) "/tmp/pdf-edit-"
                 (number->string (current-time)) "-"
                 (number->string pdf--edit-sequence)))

(define (pdf--page-path dir page)
  (string-append dir "/page-" (number->string page) ".pdf"))

(define (pdf--ordered-page-path dir position)
  (string-append dir "/ordered-" (number->string position) ".pdf"))

(define (pdf--ordered-copy-command path dir order)
  (let loop ((pages order) (position 1) (seen '()) (command ""))
    (if (null? pages)
        command
        (let* ((page (car pages))
               (target (pdf--ordered-page-path dir position))
               ;; Reusing one extracted page object twice produces a PDF that
               ;; different renderers disagree about. Materialize later copies
               ;; as independent image-backed pages instead.
               (next-command
                 (if (member page seen)
                     (let ((image (string-append dir "/duplicate-"
                                                  (number->string position))))
                       (string-append command
                         " && pdftoppm -f " (number->string page)
                         " -l " (number->string page)
                         " -singlefile -png -r 150 " (sh-quote path)
                         " " (sh-quote image)
                         " && magick " (sh-quote (string-append image ".png"))
                         " -units PixelsPerInch -density 150 " (sh-quote target)))
                     (string-append command
                       " && cp -p -- " (sh-quote (pdf--page-path dir page))
                       " " (sh-quote target)))))
          (loop (cdr pages) (+ position 1) (cons page seen) next-command)))))

(define (pdf--quoted-paths paths)
  (fold (lambda (text path)
          (string-append text " " (sh-quote path)))
        "" paths))

(define (pdf--edit-pages-real path order undo-path)
  (let* ((dir (pdf--next-edit-temp-dir))
         (output (string-append dir "/edited.pdf"))
         (cleaned (string-append dir "/cleaned.pdf"))
         (undo-dir (car (path-split undo-path)))
         (inputs
           (let loop ((pages order) (position 1))
             (if (null? pages) '()
                 (cons (pdf--ordered-page-path dir position)
                       (loop (cdr pages) (+ position 1))))))
         (command
           (string-append
             "mkdir -p -- " (sh-quote dir) " " (sh-quote undo-dir)
             " && pdfseparate " (sh-quote path) " "
             (sh-quote (string-append dir "/page-%d.pdf"))
             (pdf--ordered-copy-command path dir order)
             " && cp -p -- " (sh-quote path) " " (sh-quote undo-path)
             " && pdfunite" (pdf--quoted-paths inputs) " " (sh-quote output)
             " && mutool clean -gg -d " (sh-quote output) " " (sh-quote cleaned)
             " && mv -f -- " (sh-quote cleaned) " " (sh-quote output)
             " && mv -f -- " (sh-quote output) " " (sh-quote path)
             " && printf '\\nAIMAX_PDF_OK\\n'"
             "; aimax_pdf_status=$?; rm -rf -- " (sh-quote dir)
             "; exit $aimax_pdf_status")))
    (pdf--command-succeeded? (shell-command->string command))))

(define *pdf-edit-pages!* pdf--edit-pages-real)

(define (pdf--undo-edit-real path undo-path)
  (let ((swap (string-append undo-path ".swap-"
                             (number->string (current-time)) "-"
                             (number->string pdf--edit-sequence))))
    (pdf--command-succeeded?
      (shell-command->string
        (string-append
          "test -f " (sh-quote undo-path)
          " && cp -p -- " (sh-quote path) " " (sh-quote swap)
          " && cp -p -- " (sh-quote undo-path) " " (sh-quote path)
          " && mv -f -- " (sh-quote swap) " " (sh-quote undo-path)
          " && printf '\\nAIMAX_PDF_OK\\n'")))))

(define *pdf-undo-edit!* pdf--undo-edit-real)

(define (pdf--reset-edit-real original path undo-path)
  (pdf--command-succeeded?
    (shell-command->string
      (string-append
        "mkdir -p -- " (sh-quote (car (path-split undo-path)))
        " && cp -p -- " (sh-quote path) " " (sh-quote undo-path)
        " && cp -p -- " (sh-quote original) " " (sh-quote path)
        " && printf '\\nAIMAX_PDF_OK\\n'"))))

(define *pdf-reset-edit!* pdf--reset-edit-real)

;;; --- document geometry and positioned text ---------------------------------

(define pdf--base-fonts
  '("Courier" "Courier-Bold" "Courier-Oblique" "Courier-BoldOblique"
    "Helvetica" "Helvetica-Bold" "Helvetica-Oblique" "Helvetica-BoldOblique"
    "Times-Roman" "Times-Bold" "Times-Italic" "Times-BoldItalic"
    "Symbol" "ZapfDingbats"))

(define (pdf--numbers output)
  (map string->number
    (filter (lambda (part) (not (equal? part "")))
            (string-split (string-trim (or output "")) " "))))

(define (pdf--page-geometry-real path page)
  (let ((values
          (pdf--numbers
            (shell-command->string
              (string-append
                "pdfinfo -f " (number->string page)
                " -l " (number->string page) " " (sh-quote path)
                " 2>/dev/null | awk '"
                "/^Page.* size:/ {for (i=1;i<=NF;i++) if ($i==\"size:\") "
                "{w=$(i+1); h=$(i+3)}} "
                "/^Page.* rot:/ {for (i=1;i<=NF;i++) if ($i==\"rot:\") r=$(i+1)} "
                "END {print w, h, r+0}'")))))
    (and (= (length values) 3) values)))

(define *pdf-page-geometry* pdf--page-geometry-real)

(define *pdf-layout-json*
  (lambda (path)
    (shell-command->string
      (string-append
        "mutool draw -q -F stext.json -o - " (sh-quote path)
        " 2>/dev/null"))))

(define (pdf--latin1-hex text)
  (string-trim
    (shell-command->string
      (string-append
        "printf '%s' " (sh-quote text)
        " | iconv -f UTF-8 -t ISO-8859-1//TRANSLIT 2>/dev/null"
        " | xxd -p | tr -d '\\n'"))))

(define (pdf--font-program font size hex body)
  (string-append
    "/" font " findfont dup length dict begin "
    "{1 index /FID ne {def} {pop pop} ifelse} forall "
    "/Encoding ISOLatin1Encoding def currentdict end "
    "/AimaxFont exch definefont " (number->string size) " scalefont setfont "
    body))

(define (pdf--font-metrics-real font size text)
  (if (equal? text "")
      '(0 0 0 0 0)
      (let* ((hex (pdf--latin1-hex text))
             (program
               (pdf--font-program font size hex
                 (string-append
                   "0 0 moveto <" hex "> stringwidth pop /advance exch def "
                   "newpath 0 0 moveto <" hex "> true charpath flattenpath pathbbox "
                   "/top exch def /right exch def /bottom exch def /left exch def "
                   "advance == left == bottom == right == top == quit"))))
        (pdf--numbers
          (shell-command->string
            (string-append
              "gs -q -dSAFER -dNODISPLAY -c " (sh-quote program)
              " 2>/dev/null | tr '\\n' ' '"))))))

(define *pdf-font-metrics* pdf--font-metrics-real)

(define (pdf--page-inputs dir total replacement-page replacement-path)
  (let loop ((page 1))
    (if (> page total)
        '()
        (cons (if (= page replacement-page)
                  replacement-path
                  (pdf--page-path dir page))
              (loop (+ page 1))))))

(define (pdf--write-text-real source destination page x baseline-y text font size)
  (let* ((geometry (*pdf-page-geometry* source page))
         (total (*pdf-page-count* source)))
    (if (or (not geometry) (< total page))
        #f
        (let* ((width (car geometry))
               (height (cadr geometry))
               (dir (pdf--next-edit-temp-dir))
               (overlay (string-append dir "/overlay.pdf"))
               (stamped (string-append dir "/stamped.pdf"))
               (joined (string-append dir "/joined.pdf"))
               (cleaned (string-append dir "/cleaned.pdf"))
               (hex (pdf--latin1-hex text))
               (postscript
                 (string-append
                   "%!PS\n<< /PageSize [" (number->string width) " "
                   (number->string height) "] >> setpagedevice\n"
                   (pdf--font-program font size hex
                     (string-append
                       (number->string x) " "
                       (number->string (- height baseline-y))
                       " moveto <" hex "> show showpage"))))
               (inputs (pdf--page-inputs dir total page stamped))
               (command
                 (string-append
                   "mkdir -p -- " (sh-quote dir)
                   " && pdfseparate " (sh-quote source) " "
                   (sh-quote (string-append dir "/page-%d.pdf"))
                   " && printf '%s' " (sh-quote postscript)
                   " | gs -q -dSAFER -dBATCH -dNOPAUSE -sDEVICE=pdfwrite "
                   "-sOutputFile=" (sh-quote overlay) " -"
                   " && pdftk " (sh-quote (pdf--page-path dir page))
                   " stamp " (sh-quote overlay) " output " (sh-quote stamped)
                   " && pdfunite" (pdf--quoted-paths inputs) " " (sh-quote joined)
                   " && mutool clean -gg -d " (sh-quote joined) " " (sh-quote cleaned)
                   " && mv -f -- " (sh-quote cleaned) " " (sh-quote destination)
                   " && printf '\\nAIMAX_PDF_OK\\n'"
                   "; aimax_pdf_status=$?; rm -rf -- " (sh-quote dir)
                   "; exit $aimax_pdf_status")))
          (pdf--command-succeeded? (shell-command->string command))))))

(define *pdf-write-text!* pdf--write-text-real)

(define (pdf-page-geometry path0 page)
  "Return (WIDTH HEIGHT ROTATION) for PAGE, in PDF points."
  (let ((path (expand-path path0)))
    (cond ((not (*pdf-file-exists?* path))
           (list 'error (string-append "No PDF at " path)))
          ((or (not (number? page)) (< page 1))
           (list 'error "PDF page must be a positive number"))
          (else
            (or (*pdf-page-geometry* path page)
                (list 'error "Could not measure the PDF page"))))))

(define (pdf--line-result path page line)
  (let* ((bbox (plist-get line 'bbox))
         (font (plist-get line 'font))
         (geometry (*pdf-page-geometry* path page)))
    (list 'page page
          'page-width (and geometry (car geometry))
          'page-height (and geometry (cadr geometry))
          'rotation (and geometry (caddr geometry))
          'text (plist-get line 'text)
          'x (plist-get bbox 'x)
          'top (plist-get bbox 'y)
          'width (plist-get bbox 'w)
          'height (plist-get bbox 'h)
          'baseline-x (plist-get line 'x)
          'baseline-y (plist-get line 'y)
          'font (plist-get font 'name)
          'font-family (plist-get font 'family)
          'font-weight (plist-get font 'weight)
          'font-style (plist-get font 'style)
          'font-size (plist-get font 'size)
          'coordinate-system "PDF points; origin top-left"
          'bounds "whole matching text line")))

(define (pdf--matching-lines path query pages)
  (let page-loop ((rest pages) (page 1))
    (if (null? rest)
        '()
        (let* ((blocks (or (plist-get (car rest) 'blocks) '()))
               (lines
                 (fold
                   (lambda (found block)
                     (if (equal? (plist-get block 'type) "text")
                         (append found (or (plist-get block 'lines) '()))
                         found))
                   '() blocks))
               (matches
                 (map (lambda (line) (pdf--line-result path page line))
                   (filter
                     (lambda (line)
                       (string-contains?
                         (string-downcase (or (plist-get line 'text) "")) query))
                     lines))))
          (append matches (page-loop (cdr rest) (+ page 1)))))))

(define (pdf-find-text path0 query0)
  "Find QUERY and return line bounds, baselines, page geometry, and font data."
  (let* ((path (expand-path path0))
         (query (string-downcase (or query0 ""))))
    (cond ((not (*pdf-file-exists?* path))
           (list 'error (string-append "No PDF at " path)))
          ((equal? query "") (list 'error "PDF text query cannot be empty"))
          (else
            (let ((layout (json-parse (*pdf-layout-json* path))))
              (if (not layout)
                  (list 'error "Could not extract PDF text geometry")
                  (pdf--matching-lines path query (or (plist-get layout 'pages) '()))))))))

(define (pdf-measure-font font0 size text)
  "Measure TEXT in a PDF base font. Values are in points."
  (let ((font (or font0 "Helvetica")))
    (cond ((not (member font pdf--base-fonts))
           (list 'error (string-append "Unsupported PDF base font: " font)))
          ((or (not (number? size)) (<= size 0))
           (list 'error "PDF font size must be positive"))
          (else
            (let ((values (*pdf-font-metrics* font size (or text ""))))
              (if (not (= (length values) 5))
                  (list 'error "Could not measure the PDF font")
                  (let ((advance (car values))
                        (left (cadr values))
                        (bottom (caddr values))
                        (right (car (cdr (cdr (cdr values)))))
                        (top (car (cdr (cdr (cdr (cdr values)))))))
                    (list 'font font 'size size 'text (or text "")
                          'width advance 'left left 'bottom bottom
                          'right right 'top top 'height (- top bottom)
                          'ascent top 'descent (max 0 (- bottom)) 'unit "pt"))))))))

(define (pdf-insert-text path0 page x baseline-y text &optional font0 size0)
  "Insert text into one generated working PDF."
  (let* ((requested (expand-path path0))
         (font (or font0 "Helvetica"))
         (size (or size0 12))
         (destination (pdf--working-path requested))
         (source
           (if (and (not (equal? requested destination))
                    (*pdf-working-copy-exists?* destination))
               destination
               requested)))
    (cond ((not (*pdf-file-exists?* requested))
           (list 'error (string-append "No PDF at " requested)))
          ((or (not (number? page)) (< page 1))
           (list 'error "PDF page must be a positive number"))
          ((or (not (number? x)) (not (number? baseline-y)))
           (list 'error "PDF text coordinates must be numbers"))
          ((not (member font pdf--base-fonts))
           (list 'error (string-append "Unsupported PDF base font: " font)))
          ((or (not (number? size)) (<= size 0))
           (list 'error "PDF font size must be positive"))
          ((*pdf-write-text!* source destination page x baseline-y
                             (or text "") font size)
           (begin
             (pdf--revert-open-buffers! destination)
             destination))
          (else (list 'error "Could not write the generated PDF copy")))))

(define (pdf-insert-text-after path query text &optional gap0 font0 size0)
  "Insert TEXT after the first matching text line in a new sibling PDF."
  (let ((matches (pdf-find-text path query)))
    (if (and (pair? matches) (equal? (car matches) 'error))
        matches
        (if (null? matches)
            (list 'error (string-append "Text not found in PDF: " query))
            (let* ((match (car matches))
                   (gap (or gap0 8))
                   (size (or size0 (plist-get match 'font-size) 12)))
              (pdf-insert-text path
                (plist-get match 'page)
                (+ (plist-get match 'x) (plist-get match 'width) gap)
                (plist-get match 'baseline-y)
                text (or font0 "Helvetica") size))))))

(define (pdf--html-escape value)
  (let* ((text (or value ""))
         (text (re-replace-all "&" text "&amp;"))
         (text (re-replace-all "<" text "&lt;"))
         (text (re-replace-all ">" text "&gt;")))
    (re-replace-all "\"" text "&quot;")))

(define (pdf--basename path)
  (car (reverse (string-split path "/"))))

(define (pdf--pdf-stem filename)
  (if (and (>= (string-length filename) 4)
           (string-suffix? ".pdf" (string-downcase filename)))
      (substring filename 0 (- (string-length filename) 4))
      filename))

(define (pdf--generated-path source)
  (let* ((parts (path-split source))
         (dir (car parts))
         (stem (pdf--pdf-stem (cadr parts))))
    (string-append dir stem "-edited.pdf")))

(define (pdf--generated-copy? path)
  (re-match?
    "-edited(\\.pdf|-[0-9]{8}-[0-9]{6}(-[0-9]+)?\\.pdf)$"
    (pdf--basename path)))

(define (pdf--working-path source)
  ;; The first edit protects the original with a generated sibling. Later
  ;; edits replace that sibling atomically instead of creating name chains.
  (if (pdf--generated-copy? source) source (pdf--generated-path source)))

(define (pdf--undo-path path)
  (string-append (aimax-home) "/pdf-edit-undo/"
                 (pdf--path-key path) ".pdf"))

(define (pdf--buffer-name path)
  (string-append "*PDF: " (pdf--basename path) " · " (pdf--path-key path) "*"))

(define (pdf--edit-buffer-name path)
  (string-append "*PDF Edit: " (pdf--basename path) " · "
                 (pdf--path-key path) "*"))

(define (pdf--page buf)
  (max 1 (or (buffer-local buf 'pdf-page) 1)))

(define (pdf--total buf)
  (max 0 (or (buffer-local buf 'pdf-total) 0)))

(define (pdf--zoom buf)
  (max pdf-min-zoom
       (min pdf-max-zoom (or (buffer-local buf 'pdf-zoom) 100))))

(define (pdf--dark? buf)
  (if (buffer-local buf 'pdf-dark?) #t #f))

(define (pdf--buffer-path buf)
  ;; A normal file buffer owns one canonical path. Synthetic PDF buffers store
  ;; pdf-path because they do not have a file association.
  (or (buffer-path buf) (buffer-local buf 'pdf-path)))

(define (pdf--revert-open-buffers! path)
  "Clear cached pages and rerender each open buffer for PATH."
  (*pdf-clear-render-cache!* path)
  (for-each
    (lambda (buf)
      (when (and (equal? (pdf--buffer-path buf) path)
                 (member (buffer-local buf 'mode-name)
                         '("pdf-reader-mode" "pdf-edit-mode")))
        (pdf--render! buf #t)))
    (buffer-list))
  path)

(define (pdf--action verb label key)
  (string-append
    "<a class=\"action\" role=\"button\" href=\"aimax:pdf/" verb "\">"
    "<span>" label "</span><kbd>" key "</kbd></a>"))

(define (pdf--disabled-action label key)
  (string-append
    "<span class=\"action disabled\" aria-disabled=\"true\">"
    "<span>" label "</span><kbd>" key "</kbd></span>"))

(define (pdf--page-width zoom)
  (quotient (* 960 zoom) 100))

(define (pdf--document-html path page total zoom image text &optional original dark?)
  (let ((title (pdf--html-escape (pdf--basename path))))
    (string-append
      "<!doctype html><html><head><meta charset=\"utf-8\"><title>" title
      "</title><style>"
      ":root{color-scheme:light dark}*{box-sizing:border-box}"
      "body{margin:0;background:Canvas;color:CanvasText;font:14px/1.45 system-ui,-apple-system,sans-serif}"
      ".toolbar{position:sticky;top:0;z-index:2;display:flex;align-items:center;gap:12px;"
      "padding:10px 14px;border-bottom:1px solid;background:Canvas;white-space:nowrap;overflow-x:auto;"
      "box-shadow:0 1px 10px rgba(0,0,0,.08)}"
      ".title{flex:1 1 auto;min-width:12ch;overflow:hidden;text-overflow:ellipsis;"
      "font-weight:650;letter-spacing:.01em}"
      ".status{display:flex;flex:0 0 auto;gap:8px;font-size:12px;opacity:.72}"
      ".controls{display:flex;flex:0 0 auto;align-items:center;gap:8px;flex-wrap:nowrap}"
      ".control-group{display:inline-flex;align-items:center;gap:2px;padding:2px;border:1px solid;border-radius:8px}"
      ".action{display:inline-flex;align-items:center;gap:7px;min-height:29px;padding:4px 8px;border:0;"
      "border-radius:5px;color:inherit;text-decoration:none;white-space:nowrap;font-size:12px;font-weight:560}"
      ".action:hover{background:color-mix(in srgb,currentColor 9%,transparent)}"
      ".action:focus-visible{outline:2px solid currentColor;outline-offset:1px}"
      ".action.disabled{opacity:.28;cursor:default}.action kbd{font:10px/1 ui-monospace,monospace;opacity:.58}"
      ".viewer{min-height:calc(100vh - 108px);padding:clamp(20px,4vw,52px);overflow:auto}"
      ".page{width:max(100%,var(--page-width));}.page img{display:block;width:var(--page-width);max-width:none;"
      "height:auto;margin:0 auto;background:white;box-shadow:0 2px 5px rgba(0,0,0,.18),0 16px 48px rgba(0,0,0,.16)}"
      ".dark-page .page img{filter:invert(1) hue-rotate(180deg);background:black}"
      ".extract{max-width:76ch;margin:0 auto 36px;padding:0 18px 18px;border:1px solid;border-radius:8px}"
      ".extract summary{cursor:pointer;padding:13px 0;font-weight:600;font-size:12px}"
      ".extract pre{white-space:pre-wrap;overflow-wrap:anywhere;font:12px/1.55 ui-monospace,monospace}"
      ".error{max-width:64ch;margin:60px auto;padding:18px;border:1px solid;border-radius:8px}"
      ".edit{max-width:960px;margin:18px auto 0;padding:12px 14px;border:1px solid;border-radius:9px}"
      ".edit strong{display:block}.edit small{display:block;overflow-wrap:anywhere;opacity:.65}"
      ".edit-actions{display:flex;gap:4px;flex-wrap:wrap;margin-top:9px}"
      "@media(max-width:640px){.toolbar{gap:8px;padding:8px 10px}.title{min-width:10ch}.viewer{padding:14px}}"
      "</style></head><body" (if dark? " class=\"dark-page\"" "") "><header class=\"toolbar\">"
      "<span class=\"title\" title=\"" title "\">" title "</span>"
      "<span class=\"status\"><span>Page " (number->string page) " of "
      (number->string total) "</span><span>" (number->string zoom) "%</span>"
      (if dark? "<span>Dark page</span>" "") "</span>"
      "<nav class=\"controls\" aria-label=\"PDF controls\">"
      (if (> total 1)
          (string-append
            "<span class=\"control-group\" aria-label=\"Page navigation\">"
            (if (> page 1) (pdf--action "first" "First" "Home")
                (pdf--disabled-action "First" "Home"))
            (if (> page 1) (pdf--action "previous" "Previous" "p")
                (pdf--disabled-action "Previous" "p"))
            (if (< page total) (pdf--action "next" "Next" "n")
                (pdf--disabled-action "Next" "n"))
            (if (< page total) (pdf--action "last" "Last" "End")
                (pdf--disabled-action "Last" "End"))
            "</span>")
          "")
      "<span class=\"control-group\" aria-label=\"Zoom\">"
      (if (> zoom pdf-min-zoom) (pdf--action "zoom-out" "Smaller" "-")
          (pdf--disabled-action "Smaller" "-"))
      (if (< zoom pdf-max-zoom) (pdf--action "zoom-in" "Larger" "+")
          (pdf--disabled-action "Larger" "+"))
      "</span><span class=\"control-group\">"
      (pdf--action "toggle-dark" (if dark? "Light page" "Dark page") "i")
      (pdf--action "refresh" "Refresh" "g")
      "</span></nav></header>"
      (if original
          (string-append
            "<section class=\"edit\"><strong>Editing generated copy: " title "</strong>"
            "<small>Original remains unchanged: " (pdf--html-escape original) "</small>"
            "<div class=\"edit-actions\">"
            (pdf--action "move-backward" "Move earlier" "[")
            (pdf--action "move-forward" "Move later" "]")
            (pdf--action "duplicate" "Duplicate page" "D")
            (pdf--action "delete" "Delete page" "d")
            (pdf--action "undo" "Undo / redo" "u")
            (pdf--action "reset" "Reset from original" "R")
            "</div></section>")
          "")
      (if image
          (string-append
            "<main class=\"viewer\"><div class=\"page\" style=\"--page-width:"
            (number->string (pdf--page-width zoom)) "px\"><img alt=\"Page "
            (number->string page) "\" src=\"data:image/png;base64," image
            "\"></div></main><details class=\"extract\"><summary>Page text</summary><pre>"
            (pdf--html-escape text) "</pre></details>")
          (string-append
            "<main class=\"error\"><h1>Cannot render this PDF</h1>"
            "<p>Install Poppler so <code>pdfinfo</code>, <code>pdftoppm</code>, "
            "and <code>pdftotext</code> are available.</p></main>"))
      "</body></html>")))

(define (pdf--replace! buf html)
  (buffer-set-read-only! buf #f)
  (buffer-delete-range! buf 0 (buffer-size buf))
  (buffer-append! buf html)
  (buffer-mark-saved! buf)
  (buffer-set-read-only! buf #t)
  (with-current-buffer buf (lambda () (goto-char! 0))))

(define (pdf--render! buf recount?)
  (let ((path (pdf--buffer-path buf))
        (original (buffer-local buf 'pdf-original-path))
        (dark? (pdf--dark? buf)))
    (if (not (and path (*pdf-file-exists?* path)))
        (pdf--replace! buf
          (pdf--document-html (or path "Missing PDF") 1 0 100 #f "" original dark?))
        (let* ((total (if recount? (*pdf-page-count* path) (pdf--total buf)))
               (total (max 0 total))
               (page (max 1 (min (max 1 total) (pdf--page buf))))
               (zoom (pdf--zoom buf))
               (image (and (> total 0) (*pdf-render-page* path page zoom)))
               (text (if image (*pdf-page-text* path page) "")))
          (buffer-set-local! buf 'pdf-total total)
          (buffer-set-local! buf 'pdf-page page)
          (buffer-set-local! buf 'pdf-zoom zoom)
          (buffer-set-local! buf 'modeline-info
            (string-append "page " (number->string page) "/"
                           (number->string total) " · "
                           (number->string zoom) "%"
                           (if dark? " · dark" "")))
          (pdf--replace! buf
            (pdf--document-html path page total zoom image text original dark?))))))

(define (pdf--go! page)
  (let* ((buf (current-buffer))
         (total (pdf--total buf))
         (target (max 1 (min (max 1 total) page))))
    (if (= target (pdf--page buf))
        (message (if (= target 1) "First PDF page" "Last PDF page"))
        (begin
          (buffer-set-local! buf 'pdf-page target)
          (pdf--render! buf #f)))))

(define-command "pdf-next-page" "Show the next PDF page"
  (lambda () (pdf--go! (+ (pdf--page (current-buffer)) 1))))

(define-command "pdf-previous-page" "Show the previous PDF page"
  (lambda () (pdf--go! (- (pdf--page (current-buffer)) 1))))

(define-command "pdf-first-page" "Show the first PDF page"
  (lambda () (pdf--go! 1)))

(define-command "pdf-last-page" "Show the last PDF page"
  (lambda () (pdf--go! (pdf--total (current-buffer)))))

(define (pdf--set-zoom! zoom)
  (let ((buf (current-buffer)))
    (buffer-set-local! buf 'pdf-zoom
      (max pdf-min-zoom (min pdf-max-zoom zoom)))
    (pdf--render! buf #f)))

(define-command "pdf-zoom-in" "Increase the PDF page size"
  (lambda () (pdf--set-zoom! (+ (pdf--zoom (current-buffer)) pdf-zoom-step))))

(define-command "pdf-zoom-out" "Decrease the PDF page size"
  (lambda () (pdf--set-zoom! (- (pdf--zoom (current-buffer)) pdf-zoom-step))))

(define-command "pdf-zoom-reset" "Reset the PDF page size"
  (lambda () (pdf--set-zoom! 100)))

(define-command "pdf-toggle-dark" "Change between the normal and dark PDF page"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-local! buf 'pdf-dark? (not (pdf--dark? buf)))
      (pdf--render! buf #f)
      (message (if (pdf--dark? buf) "Dark PDF page" "Light PDF page")))))

(define-command "pdf-refresh" "Reload PDF metadata and the current page"
  (lambda ()
    (let ((path (pdf--buffer-path (current-buffer))))
      (if path
          (pdf--revert-open-buffers! path)
          (message "This buffer has no PDF file")))))

(define (pdf--page-order total)
  (let loop ((page 1))
    (if (> page total) '()
        (cons page (loop (+ page 1))))))

(define (pdf--without-page pages target)
  (let loop ((rest pages) (position 1))
    (cond ((null? rest) '())
          ((= position target) (loop (cdr rest) (+ position 1)))
          (else (cons (car rest) (loop (cdr rest) (+ position 1)))))))

(define (pdf--with-duplicate-page pages target)
  (let loop ((rest pages) (position 1))
    (cond ((null? rest) '())
          ((= position target)
           (cons (car rest)
                 (cons (car rest) (loop (cdr rest) (+ position 1)))))
          (else (cons (car rest) (loop (cdr rest) (+ position 1)))))))

(define (pdf--swap-page-positions pages first second)
  (let loop ((rest pages) (position 1))
    (cond ((null? rest) '())
          ((= position first)
           (cons (nth (- second 1) pages)
                 (loop (cdr rest) (+ position 1))))
          ((= position second)
           (cons (nth (- first 1) pages)
                 (loop (cdr rest) (+ position 1))))
          (else (cons (car rest) (loop (cdr rest) (+ position 1)))))))

(define (pdf--edit-buffer-ready? buf)
  (and (buffer-local buf 'pdf-original-path)
       (buffer-local buf 'pdf-path)))

(define (pdf--apply-page-order! order new-page success-message)
  (let* ((buf (current-buffer))
         (path (buffer-local buf 'pdf-path))
         (undo-path (buffer-local buf 'pdf-undo-path)))
    (if (not (pdf--edit-buffer-ready? buf))
        (message "This command requires pdf-edit-mode")
        (if (*pdf-edit-pages!* path order undo-path)
            (begin
              (buffer-set-local! buf 'pdf-total (length order))
              (buffer-set-local! buf 'pdf-page
                (max 1 (min (length order) new-page)))
              (pdf--revert-open-buffers! path)
              (message (string-append success-message " · " path)))
            (message
              "Could not edit the generated PDF copy; Poppler, MuPDF, and ImageMagick are required")))))

(define-command "pdf-edit-delete-page" "Delete the current page from the generated copy"
  (lambda ()
    (let* ((buf (current-buffer))
           (total (pdf--total buf))
           (page (pdf--page buf)))
      (if (<= total 1)
          (message "A PDF must keep at least one page")
          (pdf--apply-page-order!
            (pdf--without-page (pdf--page-order total) page)
            (min page (- total 1))
            "Deleted page from generated copy")))))

(define-command "pdf-edit-duplicate-page" "Duplicate the current page in the generated copy"
  (lambda ()
    (let* ((buf (current-buffer))
           (total (pdf--total buf))
           (page (pdf--page buf)))
      (pdf--apply-page-order!
        (pdf--with-duplicate-page (pdf--page-order total) page)
        page
        "Duplicated page in generated copy"))))

(define-command "pdf-edit-move-page-backward" "Move the current page earlier in the generated copy"
  (lambda ()
    (let* ((buf (current-buffer))
           (total (pdf--total buf))
           (page (pdf--page buf)))
      (if (= page 1)
          (message "This is already the first page")
          (pdf--apply-page-order!
            (pdf--swap-page-positions (pdf--page-order total) (- page 1) page)
            (- page 1)
            "Moved page earlier in generated copy")))))

(define-command "pdf-edit-move-page-forward" "Move the current page later in the generated copy"
  (lambda ()
    (let* ((buf (current-buffer))
           (total (pdf--total buf))
           (page (pdf--page buf)))
      (if (= page total)
          (message "This is already the last page")
          (pdf--apply-page-order!
            (pdf--swap-page-positions (pdf--page-order total) page (+ page 1))
            (+ page 1)
            "Moved page later in generated copy")))))

(define-command "pdf-edit-undo" "Swap the generated copy with its one-step undo PDF"
  (lambda ()
    (let* ((buf (current-buffer))
           (path (buffer-local buf 'pdf-path))
           (undo-path (buffer-local buf 'pdf-undo-path)))
      (if (not (pdf--edit-buffer-ready? buf))
          (message "This command requires pdf-edit-mode")
          (if (*pdf-undo-edit!* path undo-path)
              (begin
                (pdf--revert-open-buffers! path)
                (message (string-append "Swapped undo state · " path)))
              (message "Nothing to undo yet"))))))

(define-command "pdf-edit-reset" "Reset the generated copy from the unchanged original"
  (lambda ()
    (let* ((buf (current-buffer))
           (path (buffer-local buf 'pdf-path))
           (original (buffer-local buf 'pdf-original-path))
           (undo-path (buffer-local buf 'pdf-undo-path)))
      (if (not (pdf--edit-buffer-ready? buf))
          (message "This command requires pdf-edit-mode")
          (if (*pdf-reset-edit!* original path undo-path)
              (begin
                (buffer-set-local! buf 'pdf-page 1)
                (pdf--revert-open-buffers! path)
                (message (string-append "Reset generated copy from original · " path)))
              (message "Could not reset the generated PDF copy"))))))

(define (pdf-reader-setup! buf)
  ;; Old reader versions copied a file buffer's path into pdf-path. Keep the
  ;; file association as the single source for ordinary PDF buffers.
  (when (buffer-path buf) (buffer-set-local! buf 'pdf-path #f))
  ;; A buffer can carry the document's path as its name and still hold no
  ;; file association. Adopt the name so the reader renders the document
  ;; instead of an empty page.
  (when (and (not (buffer-path buf))
             (not (buffer-local buf 'pdf-path))
             (*pdf-file-exists?* buf))
    (buffer-set-local! buf 'pdf-path buf))
  (buffer-set-local! buf 'transient #t)
  (buffer-set-local! buf 'preview-renderer "html")
  (buffer-set-local! buf 'render-mode "html")
  ;; Let the preview layer apply the active editor palette. The PDF page is
  ;; still its own rendered image and can use pdf-toggle-dark independently.
  (buffer-set-local! buf 'preview-authored #f)
  (buffer-set-read-only! buf #t)
  (local-set-key* buf "n" "pdf-next-page")
  (local-set-key* buf "p" "pdf-previous-page")
  (local-set-key* buf "<right>" "pdf-next-page")
  (local-set-key* buf "<left>" "pdf-previous-page")
  (local-set-key* buf "SPC" "pdf-next-page")
  (local-set-key* buf "DEL" "pdf-previous-page")
  (local-set-key* buf "<next>" "pdf-next-page")
  (local-set-key* buf "<prior>" "pdf-previous-page")
  (local-set-key* buf "<home>" "pdf-first-page")
  (local-set-key* buf "<end>" "pdf-last-page")
  (local-set-key* buf "+" "pdf-zoom-in")
  (local-set-key* buf "=" "pdf-zoom-in")
  (local-set-key* buf "-" "pdf-zoom-out")
  (local-set-key* buf "0" "pdf-zoom-reset")
  (local-set-key* buf "i" "pdf-toggle-dark")
  (local-set-key* buf "g" "pdf-refresh")
  (local-set-key* buf "q" "quit-window")
  (pdf--render! buf (not (> (pdf--total buf) 0))))

(mode-icon! "pdf-reader-mode" "")

(define-mode "pdf-reader-mode"
  (lambda () (pdf-reader-setup! (current-buffer))))

(mode-doc! "pdf-reader-mode"
  "A rendered PDF document. `n` and `p` change pages. `+` and `-` change size. `i` changes the page theme.")

(define (pdf-edit-setup! buf)
  (pdf-reader-setup! buf)
  (local-set-key* buf "[" "pdf-edit-move-page-backward")
  (local-set-key* buf "]" "pdf-edit-move-page-forward")
  (local-set-key* buf "D" "pdf-edit-duplicate-page")
  (local-set-key* buf "d" "pdf-edit-delete-page")
  (local-set-key* buf "u" "pdf-edit-undo")
  (local-set-key* buf "R" "pdf-edit-reset"))

(mode-icon! "pdf-edit-mode" "")

(define-mode "pdf-edit-mode"
  (lambda () (pdf-edit-setup! (current-buffer))))

(mode-doc! "pdf-edit-mode"
  "Edit a generated PDF copy without overwriting its original. `[` and `]` reorder the page; `D` duplicates it; `d` deletes it; `u` swaps undo/redo; `R` resets from the original.")

(define (pdf-edit-open source0)
  (let* ((source (expand-path source0))
         (destination (pdf--working-path source))
         (zoom (pdf--zoom (current-buffer)))
         (dark? (pdf--dark? (current-buffer))))
    (if (not (*pdf-file-exists?* source))
        (begin (message (string-append "No PDF at " source)) #f)
        (if (not (or (equal? source destination)
                     (*pdf-working-copy-exists?* destination)
                     (*pdf-copy-file!* source destination)))
            (begin (message "Could not create a generated PDF copy") #f)
            (let ((buf (pdf--edit-buffer-name destination)))
              (buffer-create buf)
              (buffer-set-local! buf 'pdf-original-path source)
              (buffer-set-local! buf 'pdf-path destination)
              (buffer-set-local! buf 'pdf-undo-path (pdf--undo-path destination))
              (buffer-set-local! buf 'pdf-page 1)
              (buffer-set-local! buf 'pdf-total 0)
              (buffer-set-local! buf 'pdf-zoom zoom)
              (buffer-set-local! buf 'pdf-dark? dark?)
              (switch-to-buffer! buf)
              (set-mode! "pdf-edit-mode")
              (message (string-append "Editing generated copy · " destination))
              buf)))))

(define (pdf-open path0)
  (let ((path (expand-path path0)))
    (if (not (*pdf-file-exists?* path))
        (begin (message (string-append "No PDF at " path)) #f)
        (let ((buf (pdf--buffer-name path)))
          (buffer-create buf)
          (buffer-set-local! buf 'pdf-path path)
          (switch-to-buffer! buf)
          (set-mode! "pdf-reader-mode")
          buf))))

(define-command "pdf-open" "Open a local PDF document"
  (lambda () (read-file-name "PDF file: " pdf-open)))

;; define-mode registers a default toggle command. Replace it with the safe
;; entry point: entering edit mode always creates a sibling copy first.
(define-command "pdf-edit-mode" "Create a generated PDF copy and edit that copy"
  (lambda ()
    (let* ((buf (current-buffer))
           (already (buffer-local buf 'pdf-original-path))
           (source (pdf--buffer-path buf)))
      (cond (already
              (message (string-append "Already editing generated copy · " source)))
            (source (pdf-edit-open source))
            (else (read-file-name "PDF file to edit: " pdf-edit-open))))))

(define (pdf--register-auto-mode!)
  (set! *auto-mode-alist*
    (cons '(".pdf" "pdf-reader-mode")
          (filter
            (lambda (entry)
              (not (equal? (string-downcase (car entry)) ".pdf")))
            *auto-mode-alist*)))
  ;; A package reload can happen after find-file creates a PDF buffer. Apply
  ;; the new default now instead of waiting for that buffer to reopen.
  (for-each
    (lambda (buf)
      (let ((path (buffer-path buf)))
        (when (and path
                   (string-suffix? ".pdf" (string-downcase path))
                   (*pdf-file-exists?* path))
          (with-current-buffer buf
            (lambda () (set-mode! "pdf-reader-mode"))))))
    (buffer-list)))

(pdf--register-auto-mode!)

(on-preview-link! "pdf"
  (lambda (verb)
    (cond ((equal? verb "first") (run-command "pdf-first-page"))
          ((equal? verb "previous") (run-command "pdf-previous-page"))
          ((equal? verb "next") (run-command "pdf-next-page"))
          ((equal? verb "last") (run-command "pdf-last-page"))
          ((equal? verb "zoom-out") (run-command "pdf-zoom-out"))
          ((equal? verb "zoom-in") (run-command "pdf-zoom-in"))
          ((equal? verb "toggle-dark") (run-command "pdf-toggle-dark"))
          ((equal? verb "refresh") (run-command "pdf-refresh"))
          ((equal? verb "move-backward") (run-command "pdf-edit-move-page-backward"))
          ((equal? verb "move-forward") (run-command "pdf-edit-move-page-forward"))
          ((equal? verb "duplicate") (run-command "pdf-edit-duplicate-page"))
          ((equal? verb "delete") (run-command "pdf-edit-delete-page"))
          ((equal? verb "undo") (run-command "pdf-edit-undo"))
          ((equal? verb "reset") (run-command "pdf-edit-reset"))
          (else (message "Unknown PDF action")))))

(public! 'pdf-open "(pdf-open PATH) — open a local PDF in pdf-reader-mode")
(catalog-meta! 'function "pdf-open" 'domain 'documents 'effects '(read write execute))
(public! 'pdf-edit-open "(pdf-edit-open PATH) — create a generated sibling and open it in pdf-edit-mode")
(catalog-meta! 'function "pdf-edit-open" 'domain 'documents 'effects '(read write execute))
(public! 'pdf-page-geometry
  "(pdf-page-geometry PATH PAGE) -> (WIDTH HEIGHT ROTATION), in PDF points")
(catalog-meta! 'function "pdf-page-geometry" 'domain 'documents 'effects '(read execute))
(public! 'pdf-find-text
  "(pdf-find-text PATH QUERY) -> matching line plists with page, bounds, baseline, and font; coordinates are PDF points from top-left")
(catalog-meta! 'function "pdf-find-text" 'domain 'documents 'effects '(read execute))
(public! 'pdf-measure-font
  "(pdf-measure-font FONT SIZE TEXT) -> width and ink metrics in points; FONT is a PDF base-font name")
(catalog-meta! 'function "pdf-measure-font" 'domain 'documents 'effects '(execute))
(public! 'pdf-insert-text
  "(pdf-insert-text PATH PAGE X BASELINE-Y TEXT [FONT] [SIZE]) -> one working-copy path; the first edit creates it and later edits update it")
(catalog-meta! 'function "pdf-insert-text" 'domain 'documents 'effects '(read write execute))
(public! 'pdf-insert-text-after
  "(pdf-insert-text-after PATH QUERY TEXT [GAP] [FONT] [SIZE]) -> one working-copy path after the first matching line")
(catalog-meta! 'function "pdf-insert-text-after" 'domain 'documents 'effects '(read write execute))
