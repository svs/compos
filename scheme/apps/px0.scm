;;; px0 --- the code navigator, running as a compos app.
;;;
;;; px0 is a Go server with its own index and its own web UI. compos does
;;; not redraw that UI and does not rebuild it. One px0 runs per project
;;; root, and a window frames it. The app origin gives the frame its own
;;; scripts and its own storage, so the palette, the tree, the references
;;; and the call trail all work the way their author built them.
;;;
;;; The server is found, never remembered. The port a root holds is read
;;; back from the server itself: a port is reused only when the px0 that
;;; answers there reports this root. A package reload or a daemon restart
;;; therefore loses nothing and starts nothing twice.

(domain! 'code)
(effects! '(read write display external execute))

(defgroup 'px0 "px0, the code navigator, running as a compos app.")

(defcustom 'px0-command "px0"
  "The px0 program. One server runs per project root."
  'string 'px0)

(defcustom 'px0-first-port 7777
  "The first port a root is offered. A root that finds it held takes the next free one."
  'integer 'px0)

;; How many ports past px0-first-port a root may try before it gives up.
(define px0-port-span 20)

;;; --- where a root's files live -------------------------------------------

(define (px0--dir)
  (let ((d (string-append (compos-home) "/apps/px0")))
    (make-directory! d)
    d))

;; one flat name per root: the path with its separators folded away
(define (px0--slug root)
  (string-join (string-split root "/") "_"))

(define (px0--page-file root)
  (string-append (px0--dir) "/" (px0--slug root) ".html"))

(define (px0--log-file root)
  (string-append (px0--dir) "/" (px0--slug root) ".log"))

(define (px0--root)
  (let ((d (default-directory)))
    (or (git-root d) d)))

;;; --- finding a server ----------------------------------------------------

;; what holds PORT: 'free when nothing answers, 'busy when something that
;; is not px0 does, else the root that px0 serves there
(define (px0--probe port)
  (let ((r (http-get (string-append "http://127.0.0.1:"
                                    (number->string port) "/api/meta"))))
    (if (not (plist-get r 'ok))
        'free
        (let ((m (json-parse (plist-get r 'body))))
          (if (not (pair? m))
              'busy
              (let ((root (plist-get m 'root)))
                (if (string? root) root 'busy)))))))

;; (PORT FOUND?) for ROOT: its running server, else the first free port
(define (px0--port-for root)
  (let loop ((p px0-first-port) (n 0) (free #f))
    (if (>= n px0-port-span)
        (list free #f)
        (let ((at (px0--probe p)))
          (cond ((equal? at root) (list p #t))
                ((equal? at 'free) (loop (+ p 1) (+ n 1) (or free p)))
                (else (loop (+ p 1) (+ n 1) free)))))))

;;; --- starting one --------------------------------------------------------

;; The wait is the shell's, not ours. px0 binds its port before it
;; indexes, so the frame must never be drawn at a port that is still
;; closed. Ten tries at a tenth of a second: an index of 3000 files takes
;; tens of milliseconds, so this is slack, not a budget.
(define (px0--start! root port)
  (let ((p (number->string port)))
    (shell-command->string
     (string-append
      "nohup " px0-command " " (sh-quote root)
      " -port " p " -no-open -quiet"
      " >> " (sh-quote (px0--log-file root)) " 2>&1 &"
      " for i in 1 2 3 4 5 6 7 8 9 10; do"
      " curl -sf -o /dev/null http://127.0.0.1:" p "/api/meta && break;"
      " sleep 0.1;"
      " done")
     root)
    (equal? (px0--probe port) root)))

;; the port ROOT's px0 answers on, starting one when none does; #f when no
;; port in the span is free or the program never came up
(define (px0-ensure! root)
  (let* ((found (px0--port-for root))
         (port (car found)))
    (cond ((not port) #f)
          ((cadr found) port)
          ((px0--start! root port) port)
          (else #f))))

;;; --- the app page --------------------------------------------------------

;; The page is one frame and nothing else. px0 answers on its own origin,
;; so everything inside the frame -- its fetches, its storage, its palette
;; keys -- belongs to px0 and never reaches back into compos.
(define (px0--page-text port)
  (string-append
   "<!doctype html>\n"
   "<html><head><meta charset='utf-8'><title>px0</title>\n"
   "<style>\n"
   "  html, body { margin: 0; height: 100%; overflow: hidden; background: #0d1117; }\n"
   "  iframe { border: 0; display: block; width: 100%; height: 100%; }\n"
   "</style></head>\n"
   "<body><iframe src='http://127.0.0.1:" (number->string port) "/'\n"
   "        allow='clipboard-read; clipboard-write'></iframe></body></html>\n"))

;; ROOT's app buffer, drawn and ready; #f when no server could be had
(define (px0-open! root)
  (let ((port (px0-ensure! root)))
    (and port
         (let ((page (px0--page-file root)))
           (write-file! page (px0--page-text port))
           ;; visit, never find-file: find-file is the quiet loading
           ;; boundary the agent tools use, and M-x px0 would then look
           ;; like it did nothing at all
           (visit page (group-here))
           ;; the buffer is named by its path. Never read it back from
           ;; (current-buffer): a caller off the key lane has no frame,
           ;; and the locals would land on the wrong buffer
           (let ((buf (if (buffer-exists? page) page (current-buffer))))
             (buffer-set-local! buf 'render-mode "app")
             (app-reload! buf)
             buf)))))

;;; --- commands ------------------------------------------------------------

(define (px0--kill! root)
  (shell-command->string
   (string-append "pkill -f " (sh-quote (string-append "px0 " root " -port")) " || true")
   root))

;;;###autoload
(define-command "px0" "Browse this project in px0"
  (lambda ()
    (let* ((root (px0--root))
           (buf (px0-open! root)))
      (if buf
          (message (string-append "px0: " root
                                  " -- click the frame for the keyboard; C-g gives it back"))
          (message "px0: no server. Check that px0 is installed and a port is free.")))))

(define-command "px0-restart" "Stop this project's px0 and draw it again"
  (lambda ()
    (px0--kill! (px0--root))
    (run-command "px0")))

(define-command "px0-stop" "Stop this project's px0"
  (lambda ()
    (let* ((root (px0--root))
           (found (px0--port-for root)))
      (if (not (cadr found))
          (message "px0: nothing running for this project")
          (begin
            (px0--kill! root)
            (message (string-append "px0: stopped on :"
                                    (number->string (car found)))))))))
