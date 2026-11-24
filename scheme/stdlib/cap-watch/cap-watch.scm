;;; cap-watch.scm --- give every new Cap recording a transcript, a title and a description.
;;;
;;; A fresh NAME.cap folder carries nothing but its segments and a
;;; timestamp. This watches cap-watch-directory, and once a recording has
;;; sat quiet for cap-watch-quiet-seconds -- Cap keeps writing segments
;;; while the capture runs -- it transcribes the first segment's mic (or
;;; its screen, lacking one), asks the on-device card writer for a title
;;; and a description, and keeps all three as locals on the recording's
;;; own *cap NAME* buffer: cap-mode's own page, so opening it shows them.
;;; Nothing is written to recording-meta.json or any sidecar file; the
;;; buffer is the record, and it persists with the desktop like any other.

(require 'cap)
(require 'video-transcript)
(require 'title)

(domain! 'files)
(effects! '(pure))

(defgroup 'cap-watch "Transcribe, describe and title new Cap recordings.")

(defcustom 'cap-watch-directory "~/Movies/Cap"
  "The folder cap-watch watches for new Cap recordings."
  'group 'cap-watch 'type 'string)

(defcustom 'cap-watch-quiet-seconds 20
  "How long a recording's folder must sit unchanged before cap-watch processes it. Cap keeps writing segments until the capture ends."
  'group 'cap-watch 'type 'integer)

(defcustom 'cap-watch-enabled #f
  "Watch cap-watch-directory and give each new Cap recording a transcript, a title and a description. Set by cap-watch-start and cap-watch-stop."
  'group 'cap-watch 'type 'boolean)

;; dirs with a job in flight this session; cap-watch--done? is what makes a finished one stay finished
(define *cap-watch-busy* '())

(define (cap-watch--root) (expand-file-name cap-watch-directory))

(define (cap-watch--buffer-name dir)
  (string-append "*cap " (file-name-nondirectory (cap--strip dir)) "*"))

(define (cap-watch--source dir)
  "the first segment's mic, else its display, else #f"
  (let loop ((ss (cap-segments dir)))
    (cond ((null? ss) #f)
          ((plist-get (car ss) 'mic))
          ((plist-get (car ss) 'display))
          (else (loop (cdr ss))))))

(define (cap-watch--done? dir)
  (let ((b (cap-watch--buffer-name dir)))
    (and (buffer-known? b) (buffer-local-value 'cap-title b))))

(define (cap-watch--finish! dir)
  (set! *cap-watch-busy* (filter (lambda (d) (not (equal? d dir))) *cap-watch-busy*)))

(define (cap-watch--safe-name title)
  (list->string (map (lambda (c) (if (member c '(#\/ #\: #\\)) #\- c)) (string->list (string-trim title)))))

(define (cap-watch--unique-path parent safe)
  (let loop ((n 1))
    (let ((candidate (string-append parent (if (= n 1) safe (string-append safe " " (number->string n))) ".cap")))
      (if (file-exists? candidate) (loop (+ n 1)) candidate))))

(define (cap-watch--rename! dir title)
  "rename DIR to match TITLE, keeping the .cap suffix; answers the new path, or DIR itself when the title gives no usable name or the move fails"
  (let ((safe (cap-watch--safe-name title)))
    (if (equal? safe "") dir
        (let* ((new-dir (cap-watch--unique-path (path-directory dir) safe)))
          (if (rename-file! dir new-dir) (cap--strip new-dir) dir)))))

(define (cap-watch--process! dir)
  (let* ((b (cap-watch--buffer-name dir)) (src (cap-watch--source dir)))
    (buffer-create b)
    (buffer-set-local! b 'cap-dir dir)
    (if (not src)
        (begin (buffer-set-local! b 'cap-status "No audio or screen to transcribe") (cap-watch--finish! dir))
        (begin
          (buffer-set-local! b 'cap-status "Transcribing…")
          (video-transcript-ensure! src
            (lambda (words)
              (if (not words)
                  (begin (buffer-set-local! b 'cap-status "No speech found") (cap-watch--finish! dir))
                  (let ((text (string-join (map caddr words) " ")))
                    (buffer-set-local! b 'cap-transcript text)
                    (buffer-set-local! b 'cap-status "Writing a title…")
                    (title-card text
                      (lambda (card)
                        (if (not card)
                            (buffer-set-local! b 'cap-status #f)
                            (let* ((new-dir (cap-watch--rename! dir (car card)))
                                   (new-b (cap-watch--buffer-name new-dir)))
                              (unless (equal? new-b b) (buffer-rename! b new-b))
                              (buffer-set-locals! new-b (list 'cap-dir new-dir 'cap-title (car card) 'cap-description (cadr card) 'cap-status #f))
                              (when (buffer-known? new-b) (cap--render! new-b))))
                        (cap-watch--finish! dir)))))))))))

(define (cap-watch--scan!)
  (let ((root (cap-watch--root)))
    (for-each
      (lambda (name)
        (let ((dir (cap--strip (string-append root "/" name))))
          (when (and (cap-project? dir) (not (cap-watch--done? dir)) (not (member dir *cap-watch-busy*)))
            (set! *cap-watch-busy* (cons dir *cap-watch-busy*))
            (cap-watch--process! dir))))
      (list-dir root))))

(define (cap-watch--on-root-change! root)
  (when (and cap-watch-enabled (equal? (expand-file-name root) (cap-watch--root)))
    (debounce! 'cap-watch (* cap-watch-quiet-seconds 1000) 'cap-watch--scan! #f)))

(add-hook! 'fs-change-hook 'cap-watch--on-root-change!)

(define (cap-watch--init!)
  (when cap-watch-enabled
    (watch-path! (cap-watch--root) 'deep)
    (cap-watch--scan!)))

(after-init 'cap-watch--init!)

(define-command "cap-watch-start" "Watch cap-watch-directory for new Cap recordings, transcribing, describing and titling each one"
  (lambda ()
    (customize-save! 'cap-watch-enabled #t)
    (watch-path! (cap-watch--root) 'deep)
    (cap-watch--scan!)
    (message (string-append "cap-watch: watching " cap-watch-directory))))

(define-command "cap-watch-stop" "Stop watching for new Cap recordings"
  (lambda ()
    (customize-save! 'cap-watch-enabled #f)
    (unwatch-path! (cap-watch--root) 'deep)
    (message "cap-watch: stopped")))

(provide 'cap-watch)
