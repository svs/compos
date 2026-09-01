;;; movie.scm --- play a buffer's Provenance inside compos.

(package! 'movie)
(domain! 'buffers)
(effects! '(read write display execute))

(defgroup 'movie "Provenance playback inside an editor frame.")

(defcustom 'movie-speed 20
  "Playback speed relative to the recorded Provenance timeline."
  'group 'movie 'type 'number)

(define *movie-stream-buffer* "*movie-stream*")

(define (movie-get value key)
  (and (pair? value) (plist-get value key)))

(define (movie-clamp n low high) (max low (min n high)))

(define (movie-splice text pos deleted inserted)
  (let* ((size (string-length text))
         (start (if (< deleted 0) (+ pos deleted) pos))
         (start (movie-clamp start 0 size))
         (stop (movie-clamp (+ start (abs deleted)) start size))
         (at (movie-clamp pos 0 (- size (- stop start))))
         (without (string-append (substring text 0 start)
                                 (substring text stop size))))
    (string-append (substring without 0 at)
                   inserted
                   (substring without at (string-length without)))))

(define (movie-apply-ops text ops)
  (fold (lambda (value op)
          (movie-splice value
                        (or (movie-get op 'pos) 0)
                        (or (movie-get op 'deleted) 0)
                        (or (movie-get op 'inserted) "")))
        text ops))

(define (movie-change-ops change)
  (or (movie-get (movie-get change 'operation) 'ops) '()))

(define (movie-change-focus change)
  (let ((ops (movie-change-ops change)))
    (if (null? ops) 0 (or (movie-get (car (reverse ops)) 'pos) 0))))

(define (movie-frames history)
  (let loop ((changes history) (text "") (index 0) (out '()))
    (if (null? changes)
        (reverse out)
        (let* ((change (car changes))
               (next (movie-apply-ops text (movie-change-ops change))))
          (loop (cdr changes) next (+ index 1)
                (cons (list 'index index 'text next 'change change
                            'focus (movie-change-focus change))
                      out))))))

(define (movie-frame movie index)
  (let ((frames (or (buffer-local movie 'movie-frames) '())))
    (and (>= index 0) (< index (length frames)) (nth index frames))))

(define (movie-current-buffer)
  (let ((movie (frame-local 'movie-buffer)))
    (and movie (buffer-known? movie) movie)))

(define (movie-stream-open?)
  (and (popup-open?) (equal? (popup-buffer) *movie-stream-buffer*)))

(define (movie-select-stream-row! index)
  (when (buffer-known? *movie-stream-buffer*)
    (list-goto-index! *movie-stream-buffer* index)))

(define (movie-show! movie index)
  (let ((frame (movie-frame movie index)))
    (when frame
      (buffer-set-read-only! movie #f)
      (buffer-replace-range! movie 0 (buffer-size movie) (movie-get frame 'text))
      (buffer-set-local! movie 'movie-index index)
      (buffer-set-local! movie 'modeline-name
        (string-append "MOVIE " (number->string (+ index 1)) "/"
                       (number->string (length (buffer-local movie 'movie-frames)))
                       " · " (buffer-local movie 'movie-source)))
      (buffer-set-read-only! movie #t)
      (movie-select-stream-row! index)
      frame)))

(define (movie-delay movie index)
  (let ((here (movie-frame movie index))
        (next (movie-frame movie (+ index 1))))
    (if (and here next)
        (movie-clamp
          (quotient
            (- (or (movie-get (movie-get next 'change) 'created_at) 0)
               (or (movie-get (movie-get here 'change) 'created_at) 0))
            (max 1 movie-speed))
          80 2000)
        80)))

(define (movie-schedule! movie)
  (when (and (buffer-known? movie) (buffer-local movie 'movie-playing))
    (let ((index (or (buffer-local movie 'movie-index) 0)))
      (debounce! (string-append "movie:" movie) (movie-delay movie index)
        movie-tick! movie))))

(define (movie-tick! movie)
  (when (and (buffer-known? movie) (buffer-local movie 'movie-playing))
    (let* ((index (or (buffer-local movie 'movie-index) 0))
           (next (+ index 1)))
      (if (movie-frame movie next)
          (begin (movie-show! movie next) (movie-schedule! movie))
          (buffer-set-local! movie 'movie-playing #f)))))

(define (movie-pause! movie)
  (when movie (buffer-set-local! movie 'movie-playing #f)))

(define-command "movie-toggle-play" "Play or pause the active Provenance movie"
  (lambda ()
    (let ((movie (movie-current-buffer)))
      (when movie
        (let ((playing (not (buffer-local movie 'movie-playing))))
          (buffer-set-local! movie 'movie-playing playing)
          (when playing (movie-schedule! movie)))))))

(define (movie-step! amount)
  (let ((movie (movie-current-buffer)))
    (when movie
      (movie-pause! movie)
      (movie-show! movie
        (movie-clamp (+ (or (buffer-local movie 'movie-index) 0) amount)
                     0 (- (length (buffer-local movie 'movie-frames)) 1))))))

(define-command "movie-next" "Pause and show the next Provenance state"
  (lambda () (movie-step! 1)))

(define-command "movie-previous" "Pause and show the previous Provenance state"
  (lambda () (movie-step! -1)))

(define (movie-stream-rows buf)
  (let ((movie (movie-current-buffer)))
    (if (not movie) '()
        (let loop ((frames (buffer-local movie 'movie-frames)) (index 0) (out '()))
          (if (null? frames) (reverse out)
              (loop (cdr frames) (+ index 1) (cons index out)))))))

(define (movie-stream-frame index)
  (let ((movie (movie-current-buffer)))
    (and movie (movie-frame movie index))))

(define (movie-stream-actor frame)
  (let* ((change (movie-get frame 'change))
         (actor (movie-get change 'actor)))
    (or (movie-get actor 'display_name) (movie-get actor 'id) "unknown")))

(define (movie-stream-change frame)
  (let loop ((ops (movie-change-ops (movie-get frame 'change))) (ins 0) (del 0))
    (if (null? ops)
        (string-append "+" (number->string ins) " -" (number->string del))
        (loop (cdr ops)
              (+ ins (string-length (or (movie-get (car ops) 'inserted) "")))
              (+ del (abs (or (movie-get (car ops) 'deleted) 0)))))))

(define (movie-stream-time frame)
  (let ((stamp (movie-get (movie-get frame 'change) 'created_at)))
    (if stamp (format-time (quotient stamp 1000) "%H:%M:%S") "")))

(define (movie-stream-cells buf index)
  (let ((frame (movie-stream-frame index)))
    (if frame
        (list (list (number->string (+ index 1)) "faint")
              (list (movie-stream-actor frame) "prov-actor")
              (list (movie-stream-change frame) "dim")
              (list (movie-stream-time frame) "faint"))
        '())))

(define (movie-stream-preview! buf index)
  (let ((movie (movie-current-buffer)))
    (when movie
      (movie-pause! movie)
      (movie-show! movie index))))

(define-command "movie-quit" "Stop the movie and restore the frame"
  (lambda ()
    (let ((movie (movie-current-buffer))
          (layout (frame-local 'movie-return-layout)))
      (when movie (movie-pause! movie))
      (when (popup-open?) (popup-close!))
      (set-frame-local! 'movie-buffer #f)
      (set-frame-local! 'movie-return-layout #f)
      (when layout (window-tree-set! layout))
      (when (and movie (buffer-known? movie)) (buffer-kill! movie))
      (when (buffer-known? *movie-stream-buffer*)
        (buffer-kill! *movie-stream-buffer*)))))

(define-list-mode! "movie-stream-mode"
  (list
    'doc "The Provenance stream for the active movie. Move to seek. Press Space to play or pause."
    'buffer *movie-stream-buffer*
    'rows movie-stream-rows
    'columns (lambda (buf)
               (list (list "#" 5) (list "actor" 16)
                     (list "change" 12) (list "time" #f)))
    'cells movie-stream-cells
    'key (lambda (buf index) index)
    'preview movie-stream-preview!
    'no-marks #t
    'keys '(("SPC" "movie-toggle-play")
            ("q" "movie-quit"))))

(define (movie-copy-presentation! source movie)
  (for-each
    (lambda (key)
      (buffer-set-local! movie key (buffer-local source key)))
    '(default-directory render-mode preview-renderer ts-lang text-scale)))

;; the playback keys are a minor mode's map over the source's own mode:
;; the movie buffer wears the source mode for its look, and this map for
;; its keys
(register-minor-mode! "movie-mode" (lambda (buf) #t) (lambda (buf) #t))
(minor-mode-keys! "movie-mode"
  '(("SPC" "movie-toggle-play")
    ("n" "movie-next") ("<right>" "movie-next")
    ("p" "movie-previous") ("<left>" "movie-previous")
    ("q" "movie-quit")))

(define (movie-install-keys! movie)
  (enable-minor-mode! movie "movie-mode"))

(define (movie-open-stream! movie index)
  (buffer-create *movie-stream-buffer*)
  (buffer-set-local! *movie-stream-buffer* 'mode-name "movie-stream-mode")
  (list-mode-init! *movie-stream-buffer* "movie-stream-mode")
  (display-buffer-popup! *movie-stream-buffer* 'right 0.34)
  (movie-select-stream-row! index))

(define-command "buffer-movie" "Play this buffer's Provenance as a frame-wide movie"
  (lambda ()
    (let* ((source (current-buffer))
           (history (buffer-history source))
           (frames (movie-frames history)))
      (if (null? frames)
          (message "This buffer has no Provenance states")
          (let ((movie (string-append "*movie: " source "*"))
                (source-mode (buffer-local source 'mode-name)))
            (set-frame-local! 'movie-return-layout (window-tree))
            (buffer-create movie)
            (buffer-provenance-stop! movie "mode:movie" "derived playback" "mode")
            (buffer-set-locals! movie
              (list 'movie-source source 'movie-frames frames
                    'movie-index 0 'movie-playing #f 'transient #t))
            (with-current-buffer movie
              (lambda ()
                (when source-mode (set-mode! source-mode))
                (movie-copy-presentation! source movie)
                (movie-install-keys! movie)))
            (set-frame-local! 'movie-buffer movie)
            (switch-to-buffer! movie)
            (delete-other-windows!)
            (movie-show! movie 0)
            (movie-open-stream! movie 0))))))

(mode-doc! "movie-stream-mode"
  "The stream overlay for a frame-wide Provenance movie.")

(category! 'buffers)
(public! 'movie-frames
  "(movie-frames HISTORY) — reconstruct the accepted text after each Provenance change")
(public! 'movie-show!
  "(movie-show! MOVIE INDEX) — show one state and move the stream selection")
