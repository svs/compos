;;; full-browser.scm --- an interactive web page inside an ai-max window.
;;;
;;; `browse` remains the reading view. `full-browser` gives the page its own
;;; browser frame, so scripts, forms, media, and links work normally. The
;;; frame uses the host browser's profile. Signed-in sessions therefore work
;;; when the site's cookie policy permits it. The Chrome extension removes
;;; standard framing headers only inside the ai-max tab.

(domain! 'web)
(effects! '(write external))

(defcustom 'full-browser-home-page "https://example.com/"
  "The URL that `full-browser-home` opens."
  'string 'web)

(define (full-browser--url? url)
  (and (string? url)
       (or (string-prefix? "https://" url)
           (string-prefix? "http://" url))))

(define (full-browser--host-port? text)
  (or (re-find "^[A-Za-z0-9.-]+:[0-9]+(/|$)" text 0)
      (re-find "^\\[::1\\]:[0-9]+(/|$)" text 0)))

(define (full-browser--normalize url)
  (let ((text (string-trim url)))
    (cond ((full-browser--url? text) text)
          ((full-browser--host-port? text) (string-append "http://" text))
          ((re-find "^[A-Za-z][A-Za-z0-9+.-]*:" text 0)
           (error "full-browser accepts only http and https URLs"))
          (else (string-append "https://" text)))))

(define (full-browser--buffer? buf)
  (equal? (buffer-local buf 'mode-name) "full-browser-mode"))

(define (full-browser--buffer-for url)
  (let loop ((buffers (buffer-list-mru)))
    (cond ((null? buffers) #f)
          ((and (full-browser--buffer? (car buffers))
                (equal? (buffer-local (car buffers) 'browser-url) url))
           (car buffers))
          (else (loop (cdr buffers))))))

(define (full-browser--slug url)
  (let* ((tail (car (reverse (string-split url "://"))))
         (parts (filter (lambda (part) (not (equal? part "")))
                        (string-split tail "/")))
         (host (if (pair? parts) (car parts) tail)))
    (if (> (length parts) 1)
        (string-append host "/" (car (reverse parts)))
        host)))

(define (full-browser--generation buf)
  (or (buffer-local buf 'browser-generation) 0))

(define (full-browser--page-mode buf)
  (or (buffer-local buf 'browser-page-mode) "raw-mode"))

(define (full-browser--set-page-mode! buf mode)
  (buffer-set-local! buf 'browser-page-mode mode)
  (buffer-set-local! buf 'modeline-info mode)
  (message mode)
  mode)

(define (full-browser--show! buf url)
  (buffer-set-local! buf 'browser-url url)
  (buffer-set-local! buf 'browser-src-url url)
  (unless (buffer-local buf 'browser-page-mode)
    (buffer-set-local! buf 'browser-page-mode "raw-mode"))
  (buffer-set-local! buf 'browser-generation
    (+ 1 (full-browser--generation buf)))
  (message url)
  buf)

(define (full-browser--install-keys! buf)
  (local-set-key* buf "g" "full-browser-go")
  (local-set-key* buf "r" "full-browser-reload")
  (local-set-key* buf "o" "full-browser-open-external")
  (local-set-key* buf "C-c C-r" "full-browser-reader")
  (local-set-key* buf "m" "page-mode-cycle")
  (local-set-key* buf "q" "quit-window"))

(define-mode "full-browser-mode"
  (lambda ()
    (let ((buf (current-buffer))
          (url (buffer-local (current-buffer) 'browser-url)))
      (buffer-set-read-only! buf #t)
      (buffer-set-local! buf 'render-mode "browser")
      (unless (buffer-local buf 'browser-src-url)
        (buffer-set-local! buf 'browser-src-url url))
      (buffer-set-local! buf 'line-numbers "off")
      (buffer-set-local! buf 'header-line #f)
      (full-browser--set-page-mode! buf (full-browser--page-mode buf))
      (buffer-set-local! buf 'footer-line
        "m raw → theme → readable · g address · r reload · o browser tab · q close")
      (full-browser--install-keys! buf))))

;; The Chrome extension reports navigation from inside the cross-origin
;; frame. Do not change browser-src-url here. Changing src would reload the
;; page that just finished its own navigation.
(define (full-browser-location! win url title)
  (let ((buf (window-buffer win)))
    (when (and buf (full-browser--buffer? buf) (full-browser--url? url))
      (buffer-set-local! buf 'browser-url url)
      url)))

(mode-doc! "full-browser-mode"
  "An interactive web page inside ai-max. The page can run scripts, submit
forms, play media, and use the host browser's signed-in session. The Chrome
extension lets sites load when they normally reject iframes. Without it, use o
to open a normal browser tab. Press g to enter an address, r to reload,
C-c C-r for the reading view, and q to close.")

(define (full-browser--current-url)
  (let ((buf (current-buffer)))
    (cond ((full-browser--buffer? buf) (buffer-local buf 'browser-url))
          ((equal? (buffer-local buf 'mode-name) "browse-mode")
           (buffer-local buf 'browse-url))
          (else #f))))

(define (full-browser--enter-live-mode! mode)
  (let ((url (full-browser--current-url)))
    (unless url (error "this buffer has no web page"))
    (let ((buf (if (full-browser--buffer? (current-buffer))
                   (current-buffer)
                   (full-browser url))))
      (full-browser--set-page-mode! buf mode)
      buf)))

(define (full-browser--raw-mode!)
  (full-browser--enter-live-mode! "raw-mode"))

(define (full-browser--theme-mode!)
  (full-browser--enter-live-mode! "theme-mode"))

(define (full-browser--readable-mode!)
  (let ((url (full-browser--current-url)))
    (unless url (error "this buffer has no web page"))
    (let ((buf (browse url)))
      (buffer-set-local! buf 'browser-page-mode "readable-mode")
      buf)))

(define (raw-mode) (full-browser--raw-mode!))
(define (theme-mode) (full-browser--theme-mode!))
(define (readable-mode) (full-browser--readable-mode!))

(define-command "raw-mode" "Show the live page with its original colors"
  (lambda () (raw-mode)))

(define-command "theme-mode" "Show the live page with ai-max colors only"
  (lambda () (theme-mode)))

(define-command "readable-mode" "Read the page through XSLT and Mozilla Readability"
  (lambda () (readable-mode)))

(define-command "page-mode-cycle" "Cycle raw, theme, and readable page handling"
  (lambda ()
    (let ((buf (current-buffer)))
      (cond ((equal? (buffer-local buf 'mode-name) "browse-mode")
             (full-browser--raw-mode!))
            ((equal? (full-browser--page-mode buf) "raw-mode")
             (full-browser--theme-mode!))
            (else (full-browser--readable-mode!))))))

(define (full-browser url)
  (let* ((full (full-browser--normalize url))
         (inside? (full-browser--buffer? (current-buffer)))
         (existing (and (not inside?) (full-browser--buffer-for full)))
         (buf (or existing
                  (and inside? (current-buffer))
                  (string-append "*web:" (full-browser--slug full) "*"))))
    (if existing
        (switch-to-buffer! existing)
        (begin
          (buffer-create buf)
          (buffer-set-local! buf 'group "browser")
          (switch-to-buffer! buf)
          (set-mode! "full-browser-mode")
          (full-browser--show! buf full)))
    buf))

(define-command "full-browser" "Open an interactive web page inside ai-max"
  (lambda ()
    (minibuffer-read* "Web address: " '()
      (list (list 'confirm
                  (lambda (url)
                    (unless (equal? (string-trim url) "")
                      (full-browser url))))))))

(define-command "full-browser-home" "Open the full browser home page"
  (lambda () (full-browser full-browser-home-page)))

(define-command "full-browser-go" "Enter a new address in this browser buffer"
  (lambda ()
    (let ((buf (current-buffer)))
      (minibuffer-read* "Web address: " '()
        (list (list 'confirm
                    (lambda (url)
                      (unless (equal? (string-trim url) "")
                        (with-current-buffer buf
                          (lambda () (full-browser url)))))))))))

(define-command "full-browser-reload" "Reload this interactive web page"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-local! buf 'browser-generation
        (+ 1 (full-browser--generation buf)))
      (message "reloaded"))))

(define-command "full-browser-open-external" "Open this page as a normal browser tab"
  (lambda ()
    (let ((url (buffer-local (current-buffer) 'browser-url)))
      (when url (tab-open url)))))

(define-command "full-browser-reader" "Open this page in the reading-focused browser"
  (lambda () (full-browser--readable-mode!)))

(category! 'web)
(public! 'full-browser
  "(full-browser URL) — open an interactive web page inside ai-max; the host browser profile supplies its session")
(public! 'full-browser-location!
  "(full-browser-location! WIN URL TITLE) — update a browser buffer after its embedded page navigates")
(public! 'raw-mode "(raw-mode) — show the current live page with its original colors")
(public! 'theme-mode "(theme-mode) — show the current live page with ai-max colors only")
(public! 'readable-mode "(readable-mode) — read the current page through XSLT and Mozilla Readability")
