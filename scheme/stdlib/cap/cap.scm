;;; cap.scm --- a Cap recording as one page.
;;;
;;; Cap (cap.so) saves a recording as a NAME.cap folder: the screen, the
;;; camera and the mic each on their own track, per segment, with the
;;; cursor and the keys beside them. cap-mode shows that folder as a page
;;; instead of a listing: the screen and the camera as players, the mic
;;; with its cleaned copy, and the facts. Opening a .cap folder from Dired
;;; opens this page; Dired of the folder that holds them is the list.

(require 'audio-edit)

(domain! 'files)
(effects! '(pure))

(defgroup 'cap "Cap recordings.")

(defcustom 'cap-open-as-page #t
  "Open a Cap recording folder from Dired as its cap-mode page. Off, Dired lists the folder like any other."
  'group 'cap 'type 'boolean)

(defcustom 'cap-export-directory "~/Movies"
  "Where cap-export writes the finished video."
  'group 'cap 'type 'string)

(define (cap--strip dir)
  (if (and (> (string-length dir) 1) (string-suffix? "/" dir)) (cap--strip (substring dir 0 (- (string-length dir) 1))) dir))

(define (cap-project? dir)
  "(cap-project? DIR) -- #t when DIR is a Cap recording folder"
  (and (string? dir)
       (string-suffix? ".cap" (string-downcase (cap--strip dir)))
       (file-exists? (string-append (cap--strip dir) "/recording-meta.json"))))

(define (cap--meta dir)
  (or (ignore-errors (lambda () (json-parse (read-file (string-append dir "/recording-meta.json"))))) '()))

(define (cap--file dir rel)
  (and (string? rel) (let ((p (string-append dir "/" rel))) (and (file-exists? p) p))))

(define (cap-segments dir)
  "(cap-segments DIR) -- each segment of the recording as (display CAMERA mic SYSTEM) full paths, #f where a track is missing"
  (map (lambda (s)
         (list 'display (cap--file dir (plist-get (plist-get s 'display) 'path))
               'camera (cap--file dir (plist-get (plist-get s 'camera) 'path))
               'mic (cap--file dir (plist-get (plist-get s 'mic) 'path))
               'system (cap--file dir (plist-get (plist-get s 'system_audio) 'path))
               'device (plist-get (plist-get s 'mic) 'device_id)
               'fps (plist-get (plist-get s 'display) 'fps)))
       (let ((ss (plist-get (cap--meta dir) 'segments))) (if (list? ss) ss '()))))

(define (cap--name dir)
  (or (plist-get (cap--meta dir) 'pretty_name) (file-name-nondirectory dir)))

(define (cap--video-facts path)
  (let* ((i (ignore-errors (lambda () (media-info path))))
         (fm (and (pair? i) (plist-get i 'format)))
         (v (and (pair? i) (pair? (plist-get i 'streams)) (car (plist-get i 'streams))))
         (dur (and fm (string->number (or (plist-get fm 'duration) "")))))
    (if (not v) ""
        (string-append (number->string (plist-get v 'width)) "×" (number->string (plist-get v 'height))
                       (if dur (string-append " · " (cap--clock dur)) "")))))

(define (cap--clock secs)
  (let ((s (inexact->exact (round secs))))
    (string-append (number->string (quotient s 60)) ":" (if (< (remainder s 60) 10) "0" "") (number->string (remainder s 60)))))

(define (cap--out-path dir)
  (let ((safe (list->string (map (lambda (c) (if (member c '(#\/ #\:)) #\- c)) (string->list (cap--name dir))))))
    (string-append (expand-file-name cap-export-directory) "/" safe ".mp4")))

(define (cap--html buf)
  (let* ((dir (buffer-local-value 'cap-dir buf))
         (segs (cap-segments dir))
         (status (buffer-local-value 'cap-status buf))
         (shot (cap--file dir "screenshots/display.jpg"))
         (out (cap--out-path dir)))
    (string-append
      "<!doctype html><html><head><meta charset=\"utf-8\"><style>"
      "body{font:14px/1.45 system-ui,sans-serif;margin:0;padding:18px 22px;max-width:none!important}"
      "h1{font-size:17px;margin:0 0 2px}.m{opacity:.6;margin-bottom:14px}h2{font-size:14px;margin:18px 0 6px}"
      "video{display:block;width:100%;max-height:60vh;background:#000;border-radius:6px}audio{width:100%}"
      ".row{display:flex;gap:10px;align-items:center;margin:4px 0}.row b{min-width:90px}"
      "table{border-collapse:collapse;margin-top:14px}td{padding:3px 14px 3px 0}td.k{font-family:ui-monospace,monospace;font-weight:600}"
      ".s{margin-top:12px;opacity:.75}"
      "</style></head><body>"
      "<h1>" (html-escape (cap--name dir)) "</h1>"
      "<div class=\"m\">" (html-escape (file-name-nondirectory dir))
      " · " (number->string (length segs)) (if (= (length segs) 1) " segment" " segments")
      (if (file-exists? out) (string-append " · exported: " (html-escape (file-name-nondirectory out))) "")
      "</div>"
      (apply string-append
        (let loop ((ss segs) (i 1) (acc '()))
          (if (null? ss) (reverse acc)
              (let* ((s (car ss))
                     (d (plist-get s 'display)) (c (plist-get s 'camera)) (m (plist-get s 'mic)) (y (plist-get s 'system))
                     (clean (and m (audio-edit-clean-path m))))
                (loop (cdr ss) (+ i 1)
                  (cons
                    (string-append
                      (if (> (length segs) 1) (string-append "<h2>Segment " (number->string i) "</h2>") "")
                      (if d (string-append "<video controls preload=\"metadata\""
                                           (if (and shot (= i 1)) (string-append " poster=\"" (html-escape shot) "\"") "")
                                           " src=\"" (html-escape d) "\"></video><div class=\"m\">Screen · "
                                           (html-escape (cap--video-facts d))
                                           (let ((f (plist-get s 'fps))) (if (number? f) (string-append " · " (number->string f) " fps") ""))
                                           "</div>") "")
                      (if c (string-append "<h2>Camera</h2><video controls preload=\"metadata\" src=\"" (html-escape c) "\"></video>") "")
                      (if m (string-append "<div class=\"row\"><b>Mic</b><audio controls preload=\"none\" src=\"" (html-escape m) "\"></audio></div>"
                                           (if (plist-get s 'device) (string-append "<div class=\"m\">" (html-escape (plist-get s 'device)) "</div>") "")) "")
                      (if (and clean (file-exists? clean))
                          (string-append "<div class=\"row\"><b>Mic, cleaned</b><audio controls preload=\"none\" src=\"" (html-escape clean) "\"></audio></div>") "")
                      (if y (string-append "<div class=\"row\"><b>System</b><audio controls preload=\"none\" src=\"" (html-escape y) "\"></audio></div>") ""))
                    acc))))))
      "<table>"
      "<tr><td class=\"k\">a</td><td>Open the mic in audio-edit-mode, to tune the cleaning</td></tr>"
      "<tr><td class=\"k\">c</td><td>Clean the mic with audio-edit's settings</td></tr>"
      "<tr><td class=\"k\">e</td><td>Export the screen with the mic, cleaned when there is a clean, to " (html-escape (abbreviate-file-name out)) "</td></tr>"
      "<tr><td class=\"k\">o</td><td>Open the recording in Cap</td></tr>"
      "<tr><td class=\"k\">d</td><td>List the folder's files in Dired</td></tr>"
      "<tr><td class=\"k\">g</td><td>Draw again</td></tr></table>"
      (if (string? status) (string-append "<div class=\"s\">" (html-escape status) "</div>") "")
      "</body></html>")))

(defwrite-rule! 'cap-mode
  "cap-mode holds a page about a Cap recording, not a file"
  #f
  (lambda (path source)
    (and source (equal? (buffer-local-value 'mode-name source) "cap-mode"))))

(effects! '(write display))

(define (cap--render! buf)
  (when (buffer-known? buf)
    (buffer-set-local! buf 'preview-renderer "html")
    (buffer-set-local! buf 'preview-authored #t)
    (buffer-set-local! buf 'render-mode "html")
    (buffer-set-read-only! buf #f)
    (buffer-delete-range! buf 0 (buffer-size buf))
    (buffer-append! buf (cap--html buf))
    (buffer-mark-saved! buf)
    (buffer-set-read-only! buf #t)))

(define (cap-mode-setup)
  (cap--render! (current-buffer)))

(define-mode "cap-mode" cap-mode-setup)

(define (cap-open dir)
  "(cap-open DIR) -- the cap-mode page of the Cap recording DIR, shown here; answers the buffer"
  (let* ((dir (cap--strip (expand-file-name dir)))
         (name (string-append "*cap " (file-name-nondirectory dir) "*"))
         (group (or (frame-group) (buffer-group (current-buffer)))))
    (buffer-create name)
    (when (and group (not (equal? (buffer-group name) group))) (buffer-move-to-group! name group))
    (buffer-set-local! name 'cap-dir dir)
    (buffer-set-local! name 'default-directory (string-append dir "/"))
    (with-current-buffer name (lambda () (set-mode! "cap-mode")))
    (switch-to-buffer-here! name)
    name))

(define (cap--mics buf)
  (filter string? (map (lambda (s) (plist-get s 'mic)) (cap-segments (buffer-local-value 'cap-dir buf)))))

(define (cap--mic-buffer mic)
  (let ((b (visit mic (buffer-group (current-buffer)))))
    (with-current-buffer b (lambda () (unless (equal? (buffer-local-value 'mode-name b) "audio-edit-mode") (set-mode! "audio-edit-mode"))))
    b))

(define-command "cap-open-mic" "Open the mic track in audio-edit-mode, in the other window"
  (lambda ()
    (let ((mics (cap--mics (current-buffer))))
      (if (null? mics) (message "This recording has no mic track")
          (display-buffer-other-window! (cap--mic-buffer (car mics))))))
  'modes '(cap-mode))

(define-command "cap-clean-mic" "Clean every mic track with audio-edit's settings"
  (lambda ()
    (let* ((buf (current-buffer)) (mics (cap--mics buf)))
      (if (null? mics) (message "This recording has no mic track")
          (begin
            (buffer-set-local! buf 'cap-status "Cleaning the mic…")
            (cap--render! buf)
            (let loop ((ms mics))
              (if (null? ms)
                  (begin (buffer-set-local! buf 'cap-status "Mic cleaned") (cap--render! buf))
                  (audio-edit-clean-measured! (cap--mic-buffer (car ms)) (lambda () (loop (cdr ms))))))))))
  'modes '(cap-mode))

(define (cap-export-command dir)
  "(cap-export-command DIR) -- the ffmpeg command that joins DIR's segments, screen with mic, into one mp4 on stdout's last line OK"
  (let* ((segs (filter (lambda (s) (plist-get s 'display)) (cap-segments dir)))
         (n (length segs))
         (tmp (string-append (expand-file-name audio-edit-cache-directory) "/cap-export.mp4"))
         (inputs (apply string-append
                   (map (lambda (s)
                          (let* ((m (plist-get s 'mic)) (c (and m (audio-edit-clean-path m))) (a (if (and c (file-exists? c)) c m)))
                            (string-append " -i " (sh-quote (plist-get s 'display))
                                           (if a (string-append " -i " (sh-quote a))
                                               " -f lavfi -t 1 -i anullsrc=r=48000:cl=mono"))))
                        segs)))
         (labels (let loop ((i 0) (acc "")) (if (= i n) acc (loop (+ i 1) (string-append acc "[" (number->string (* 2 i)) ":v][" (number->string (+ 1 (* 2 i))) ":a]"))))))
    (string-append "mkdir -p " (sh-quote (expand-file-name audio-edit-cache-directory)) " && ffmpeg -y -v error" inputs
                   (if (= n 1)
                       " -map 0:v -map 1:a -c:v copy -c:a aac -b:a 192k -shortest"
                       (string-append " -filter_complex " (sh-quote (string-append labels "concat=n=" (number->string n) ":v=1:a=1[v][a]"))
                                      " -map [v] -map [a] -c:v h264_videotoolbox -b:v 12M -c:a aac -b:a 192k"))
                   " -movflags +faststart " (sh-quote tmp) " && echo OK")))

(define-command "cap-export" "Write the screen with the mic, cleaned when there is a clean, as one mp4"
  (lambda ()
    (let* ((buf (current-buffer)) (dir (buffer-local-value 'cap-dir buf))
           (out (cap--out-path dir))
           (tmp (string-append (expand-file-name audio-edit-cache-directory) "/cap-export.mp4")))
      (buffer-set-local! buf 'cap-status "Exporting…")
      (cap--render! buf)
      (shell-command->string (cap-export-command dir) "/tmp"
        (lambda (o)
          (if (and (string? o) (string-prefix? "OK" o)
                   (begin (when (file-exists? out) (delete-file! out)) (rename-file! tmp out)))
              (buffer-set-local! buf 'cap-status (string-append "Exported: " (abbreviate-file-name out)))
              (buffer-set-local! buf 'cap-status (string-append "Export failed: " (if (string? o) (string-trim o) ""))))
          (cap--render! buf)))))
  'modes '(cap-mode))

(define-command "cap-open-in-cap" "Open the recording in the Cap app"
  (lambda ()
    (shell-command->string (string-append "open -a Cap " (sh-quote (buffer-local-value 'cap-dir (current-buffer)))) "/tmp" (lambda (o) #t))
    (message "Opening in Cap"))
  'modes '(cap-mode))

(define-command "cap-dired" "List the recording folder's files in Dired"
  (lambda () (cap--dired (buffer-local-value 'cap-dir (current-buffer))))
  'modes '(cap-mode))

(define-command "cap-pages-toggle" "Turn on or off opening Cap recording folders as pages, and keep the choice"
  (lambda ()
    (customize-save! 'cap-open-as-page (not cap-open-as-page))
    (message (if cap-open-as-page "Cap folders open as pages" "Cap folders open in Dired"))))

(define-command "cap-refresh" "Read the recording again and draw the page"
  (lambda () (cap--render! (current-buffer)))
  'modes '(cap-mode))

(mode-keys! "cap-mode"
  '(("a" "cap-open-mic")
    ("c" "cap-clean-mic")
    ("e" "cap-export")
    ("o" "cap-open-in-cap")
    ("d" "cap-dired")
    ("g" "cap-refresh")))

(mode-doc! "cap-mode"
  "A Cap recording as a page: the screen and the camera as players, the mic and its cleaned copy, and the facts. `a` opens the mic in audio-edit-mode to tune the cleaning, `c` cleans the mic, `e` exports the screen with the mic, cleaned when there is a clean, as one mp4. `o` opens the recording in Cap, `d` lists its files in Dired, `g` draws the page again.")

;; A .cap folder opened from Dired opens as this page. cap-dired, and a
;; Dired already on the folder, still list its files.
(define cap--listing #f)

(define (cap--dired dir)
  (set! cap--listing dir)
  (let ((b (dired-open dir))) (set! cap--listing #f) b))

(advice-add! 'dired-open-directory 'around 'cap-project
  (lambda (next dir)
    (if (and cap-open-as-page (cap-project? dir) (not (equal? cap--listing dir)))
        (cap-open dir)
        (next dir))))

(effects! '(pure))
(public! 'cap-project? "(cap-project? DIR) — #t when DIR is a Cap recording folder")
(catalog-meta! 'function "cap-project?" 'domain 'files 'effects '(pure))
(effects! '(read))
(public! 'cap-segments "(cap-segments DIR) — each segment of a Cap recording as a plist of full paths: display, camera, mic, system, with device and fps")
(catalog-meta! 'function "cap-segments" 'domain 'files 'effects '(read))
(effects! '(write display))
(public! 'cap-open "(cap-open DIR) — show the Cap recording DIR as a cap-mode page here; answers the buffer")
(catalog-meta! 'function "cap-open" 'domain 'files 'effects '(write display))

(provide 'cap)
