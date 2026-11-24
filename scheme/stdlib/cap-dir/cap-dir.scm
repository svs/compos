;;; cap-dir.scm --- browse the Cap recordings as an app: a list, and each recording's own page beside it.
;;;
;;; cap-watch gives a recording its transcript, its title and its
;;; description; this is what lets you actually find one again. The
;;; listing shows every recording under cap-watch-directory, titled and
;;; with its progress when cap-watch is still working on it. Moving the
;;; point, or RET, opens the recording's own cap-mode page beside the
;;; list -- the same page Dired opens directly on a .cap folder, so
;;; nothing here duplicates its rendering or its keys.

(require 'cap)
(require 'cap-watch)
(require 'tabulated-list)

(domain! 'files)
(effects! '(pure))

(defgroup 'cap-dir "Browse Cap recordings as an app.")

(defcustom 'cap-dir-open-as-app #t
  "Open cap-watch-directory from Dired as the Cap recordings app, instead of listing it."
  'group 'cap-dir 'type 'boolean)

(define *cap-dir-buffer* "*Cap Recordings*")

(define (cap-dir--buffer-name dir)
  (string-append "*cap " (file-name-nondirectory (cap--strip dir)) "*"))

(define (cap-dir--rows)
  (let ((root (expand-file-name cap-watch-directory)))
    (filter (lambda (r) r)
      (map (lambda (name)
             (let ((dir (cap--strip (string-append root "/" name))))
               (and (cap-project? dir)
                    (let ((b (cap-dir--buffer-name dir)))
                      (list 'dir dir 'name (file-name-nondirectory dir)
                            'title (and (buffer-known? b) (buffer-local-value 'cap-title b))
                            'status (and (buffer-known? b) (buffer-local-value 'cap-status b))
                            'segments (length (cap-segments dir)))))))
           (list-dir root)))))

(effects! '(write display))

(define (cap-dir--show! buf row)
  (let* ((dir (plist-get row 'dir)) (name (cap-dir--buffer-name dir)))
    (buffer-create name)
    (buffer-set-local! name 'cap-dir dir)
    (buffer-set-local! name 'default-directory (string-append dir "/"))
    (unless (equal? (buffer-local-value 'mode-name name) "cap-mode")
      (with-current-buffer name (lambda () (set-mode! "cap-mode"))))
    (cap--render! name)
    (display-buffer-detail! name buf)))

(define (cap-dir--listing!)
  (unless (buffer-known? *cap-dir-buffer*) (buffer-create *cap-dir-buffer*))
  (let ((group (or (frame-group) (buffer-group (current-buffer)))))
    (when (and group (not (equal? (buffer-group *cap-dir-buffer*) group)))
      (buffer-move-to-group! *cap-dir-buffer* group)))
  (unless (equal? (buffer-local-value 'mode-name *cap-dir-buffer*) "cap-dir-mode")
    (with-current-buffer *cap-dir-buffer* (lambda () (set-mode! "cap-dir-mode"))))
  *cap-dir-buffer*)

(define-list-mode! "cap-dir-mode"
  (list
    'doc (string-append
           "Cap recordings under cap-watch-directory, titled once cap-watch has transcribed and described each one. "
           "Moving the point, or RET, opens the recording's own page beside the list. g refreshes, / filters, q quits.")
    'rows (lambda (buf) (cap-dir--rows))
    'columns (lambda (buf) (list (list "title" #f) (list "status" 22) (list "segments" 8 'right)))
    'cells (lambda (buf row)
             (list (or (plist-get row 'title) (plist-get row 'name))
                   (or (plist-get row 'status) "")
                   (number->string (plist-get row 'segments))))
    'key (lambda (buf row) (plist-get row 'dir))
    'local-filter #t
    'title (lambda (buf) "Cap recordings")
    'meta (lambda (buf) (string-append (number->string (length (list-source-entries buf))) " recordings"))
    'preview (lambda (buf row) (cap-dir--show! buf row))
    'footer (lambda (buf) '(("RET" "open") ("/" "filter") ("g" "refresh") ("q" "quit")))
    'keys (list (list "RET" "cap-dir-open") (list "d" "cap-dir-dired") (list "q" "quit-window"))))

(define-command "cap-dir-open" "Open the recording on this row"
  (lambda ()
    (let ((row (list-current *cap-dir-buffer*)))
      (if row (cap-dir--show! *cap-dir-buffer* row) (message "No recording selected"))))
  'modes '(cap-dir-mode))

(define (cap-dir--open-app!)
  (let ((buf (cap-dir--listing!)))
    (app-open! buf)
    (let ((row (list-current buf))) (when row (cap-dir--show! buf row)))
    buf))

(define-command "cap-dir" "Open the Cap recordings app"
  (lambda () (cap-dir--open-app!)))

(define-command "cap-dir-pages-toggle" "Turn on or off opening the Cap folder from Dired as the app, and keep the choice"
  (lambda ()
    (customize-save! 'cap-dir-open-as-app (not cap-dir-open-as-app))
    (message (if cap-dir-open-as-app "The Cap folder opens as the app" "The Cap folder opens in Dired"))))

;; the Cap folder opened from Dired opens as the app. cap-dir-dired, and a
;; Dired already on the folder, still list its files.
(define cap-dir--listing #f)

(define (cap-dir--dired dir)
  (set! cap-dir--listing dir)
  (let ((b (dired-open dir))) (set! cap-dir--listing #f) b))

(define-command "cap-dir-dired" "List the Cap folder's files in Dired, instead of the app"
  (lambda () (cap-dir--dired (expand-file-name cap-watch-directory)))
  'modes '(cap-dir-mode))

(advice-add! 'dired-open-directory 'around 'cap-dir
  (lambda (next dir)
    (if (and cap-dir-open-as-app
             (equal? (cap--strip (expand-file-name dir)) (expand-file-name cap-watch-directory))
             (not (equal? cap-dir--listing dir)))
        (cap-dir--open-app!)
        (next dir))))

(provide 'cap-dir)
