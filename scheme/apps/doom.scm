;;; doom.scm --- DOOM, the real one, in a compos window.
;;;
;;; M-x doom opens the shareware DOOM as a compos app. The engine is
;;; Chocolate Doom compiled to WebAssembly. The app document, the engine,
;;; and the IWAD all live in one directory under the config home, and the
;;; app origin serves them: the buffer is the page, and the files beside
;;; the page's file are its assets.
;;;
;;; Nothing here emulates Doom. Elixir already supplies the mechanism --
;;; an app buffer runs its own JavaScript on its own origin -- so this
;;; package only says where the files are, fetches them once, and puts
;;; the buffer in app render-mode.
;;;
;;; The keyboard goes to the game while the app window holds it. C-g
;;; gives it back to compos; the app bridge in the page does that.
;;;
;;; M-x doom-install fetches the engine and the IWAD. M-x doom runs the
;;; install first when the directory is not complete yet.

(domain! 'games)
(effects! '(read write display external))

(defgroup 'doom "DOOM, running as a compos app.")

(defcustom 'doom-source "https://silentspacemarine.com"
  "Where doom-install fetches the WebAssembly engine and the shareware IWAD from."
  'group 'doom 'type 'string)

(defcustom 'doom-home ""
  "The directory that holds the engine, the IWAD and the app page. Empty means apps/doom under the config home."
  'group 'doom 'type 'string)

;;; --- where the game lives -----------------------------------------------------

(define (doom--dir)
  (if (equal? doom-home "")
      (string-append (compos-config-dir) "/apps/doom")
      doom-home))

(define (doom--file name) (string-append (doom--dir) "/" name))

;; the engine glue, the engine itself, the IWAD, and the config the
;; engine reads at startup. The page is ours; the rest is the upstream
;; build.
(define *doom-assets*
  '("websockets-doom.js" "websockets-doom.wasm" "doom1.wad" "default.cfg"))

(define (doom--missing)
  (filter (lambda (f) (not (file-exists? (doom--file f)))) *doom-assets*))

(define (doom--installed?) (and (null? (doom--missing))
                                (file-exists? (doom--file "doom.html"))
                                (file-exists? (doom--file "doom.js"))))

;;; --- the page -----------------------------------------------------------------

;; The app document. It is written from here, so a compos that has never
;; run doom before still gets a page, and a page somebody edited can be
;; put back with M-x doom-install.
(define *doom-page* "<!doctype html>
<html lang=\"en\">
<head>
<meta charset=\"utf-8\" />
<title>DOOM</title>
<style>
  html, body { margin: 0; padding: 0; height: 100%; background: #000; overflow: hidden; }
  #wrap { position: fixed; inset: 0; display: flex; align-items: center;
          justify-content: center; background: #000; }
  /* SDL writes width/height into the style attribute, so the fit rules
     have to outrank it. With both sizes auto and both maxima set, the
     canvas scales to the pane and keeps its own ratio. */
  canvas#canvas {
    display: block; background: #000; outline: none;
    image-rendering: pixelated; image-rendering: crisp-edges;
    width: auto !important; height: auto !important;
    max-width: 100% !important; max-height: 100% !important;
  }
  #status {
    position: fixed; inset: 0; display: flex; flex-direction: column;
    align-items: center; justify-content: center; gap: 10px;
    color: #b8b0a0; background: #000; font: 600 13px/1.6 ui-monospace, Menlo, monospace;
    letter-spacing: .22em; text-transform: uppercase; text-align: center; padding: 20px;
  }
  #status .sub { font-size: 10px; letter-spacing: .16em; color: #6a6458;
                 text-transform: none; font-weight: 400; }
  #status.gone { display: none; }
</style>
</head>
<body>
<div id=\"wrap\"><canvas id=\"canvas\" tabindex=\"1\"></canvas></div>
<div id=\"status\">loading doom<div class=\"sub\">arrows or W A S D move, Ctrl fires, SPC opens, Ctrl-G gives the keyboard back to compos</div></div>

<script src=\"doom.js\"></script>
<script src=\"websockets-doom.js\"></script>
</body>
</html>
")

;;; --- the install --------------------------------------------------------------

;; One asset. The fetch is a shell run because the file is binary and
;; large: the IWAD is four megabytes and the engine is two. curl writes a
;; part file and the move only happens on success, so a failed fetch
;; leaves no half file behind.
(define (doom--fetch! name k)
  (let* ((url (string-append doom-source "/" name))
         (out (doom--file name))
         (part (string-append out ".part"))
         (cmd (string-append "curl -fsSL --max-time 600 -o " (sh-quote part)
                             " " (sh-quote url)
                             " && mv -f " (sh-quote part) " " (sh-quote out))))
    (shell-command->string cmd (doom--dir)
      (lambda (output) (k (file-exists? out))))))

;; The assets in order, one at a time, so the echo area names the file
;; that is arriving and a failure names the file that failed.
(define (doom--fetch-each! names k)
  (if (null? names)
      (k #t)
      (let ((name (car names)))
        (message (string-append "doom: fetching " name " ..."))
        (doom--fetch! name
          (lambda (ok)
            (if ok
                (doom--fetch-each! (cdr names) k)
                (k (string-append "doom: could not fetch " name " from " doom-source))))))))

(define (doom--install! k)
  (make-directory! (doom--dir))
  (doom--sync-page!)
  (let ((want (doom--missing)))
    (if (null? want)
        (k #t)
        (doom--fetch-each! want k))))

;;; --- opening the game ---------------------------------------------------------

;; The page and its script are code, and this package owns them. A copy
;; that does not match the package is stale, so put the current one back
;; before the app runs. The script lives beside this file as doom/doom.js.
(define (doom--sync-file! name text)
  (let ((file (doom--file name)))
    (unless (and (file-exists? file) (equal? (read-file file) text))
      (write-file! file text))))

(define (doom--sync-page!)
  (doom--sync-file! "doom.html" *doom-page*)
  (doom--sync-file! "doom.js" (read-file (locate-library "doom/doom.js"))))

(define (doom--open!)
  (let ((page (doom--file "doom.html")))
    (doom--sync-page!)
    ;; visit, never find-file: find-file is the quiet loading boundary the
    ;; agent tools use. It makes a context-only buffer and shows nothing,
    ;; so M-x doom looked like it did nothing at all. visit is the user
    ;; facing open: it joins the group, takes a pane, and promotes the
    ;; buffer out of the dormant list.
    (visit page (and (boundp (quote group-here)) (group-here)))
    ;; the file buffer is named by its path. Never read it back from
    ;; (current-buffer): a caller off the key lane has no frame, and the
    ;; locals would land on the wrong buffer.
    (let ((buf (if (buffer-exists? page) page (current-buffer))))
      (app-reload! buf)
      (buffer-set-local! buf 'render-mode "app")
      (message "doom: click the frame for the keyboard; C-g gives it back"))))

;;; --- the commands -------------------------------------------------------------

;;;###autoload
(define-command "doom" "Play DOOM"
  (lambda ()
    (if (doom--installed?)
        (doom--open!)
        (begin
          (message "doom: fetching the engine and the IWAD, about 7 MB ...")
          (doom--install!
            (lambda (ok)
              (if (equal? ok #t)
                  (doom--open!)
                  (message (if (string? ok) ok "doom: install failed")))))))))

;;;###autoload
(define-command "doom-install"
  "Fetch the DOOM engine and the shareware IWAD, and write the app page"
  (lambda ()
    (message "doom: fetching ...")
    (doom--install!
      (lambda (ok)
        (message (cond ((equal? ok #t) (string-append "doom: ready in " (doom--dir)))
                       ((string? ok) ok)
                       (else "doom: install failed")))))))

(define-command "doom-directory" "Show where the DOOM files live"
  (lambda () (message (doom--dir))))
