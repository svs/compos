;;; audio-edit.scm --- hear a recording, see its waveform, clean the voice.
;;;
;;; audio-edit-mode opens a sound file as a page: its waveform, a player,
;;; and the cleaning chain as settings you step with a key. `c` writes the
;;; cleaned copy beside the file, NAME-clean.wav, and the page shows it
;;; under the original, with its own waveform and player, to compare.
;;; ffmpeg does the work in a task; the page draws again when it is done.

(require 'file-view)

(domain! 'files)
(effects! '(pure))

(defgroup 'audio-edit "Hearing and cleaning sound files.")

(defcustom 'audio-edit-extensions
  '(".wav" ".mp3" ".m4a" ".aac" ".flac" ".ogg" ".oga" ".opus" ".weba")
  "File suffixes that open in audio-edit-mode."
  'group 'audio-edit 'type 'list)

(defcustom 'audio-edit-cache-directory "~/Library/Caches/compos-audio"
  "Where audio-edit-mode keeps waveform pictures and unfinished cleans."
  'group 'audio-edit 'type 'string)

;; each setting: its key, its label, its steps, and the step it starts on
(define audio-edit--settings
  '((highpass "h" "Rumble cut" (0 60 80 120) 80)
    (declick "p" "Pop and snap tamer" (off on strong) on)
    (noise "n" "Noise reduction" (off light medium strong) medium)
    (gate "x" "Hiss gate between words" (off on) on)
    (mud "m" "Mid cut (boxy, honky sound)" (off light strong) light)
    (deess "s" "De-esser" (off on) on)
    (compress "k" "Compression" (off light strong) light)
    (loudness "l" "Loudness target" (off -14 -16 -19 -23) -19)))

(define (audio-edit-path? path)
  "(audio-edit-path? PATH) -- #t when PATH opens in audio-edit-mode"
  (and (string? path)
       (let ((down (string-downcase path)))
         (any (lambda (e) (string-suffix? e down)) audio-edit-extensions))))

(define (audio-edit--value buf name)
  (let ((v (buffer-local-value (string->symbol (string-append "audio-edit-" (symbol->string name))) buf))
        (row (assoc name audio-edit--settings)))
    (if (or (not v) (null? v)) (list-ref row 4) v)))

(define (audio-edit--int x) (inexact->exact (round x)))

(define (audio-edit--show v)
  (cond ((equal? v 0) "off")
        ((symbol? v) (symbol->string v))
        (else (number->string v))))

(define (audio-edit-chain buf)
  "(audio-edit-chain BUF) -- the ffmpeg filter chain BUF's settings give"
  (let* ((hp (audio-edit--value buf 'highpass))
         (nz (audio-edit--value buf 'noise))
         (dc (audio-edit--value buf 'declick))
         (ga (audio-edit--value buf 'gate))
         (lv (buffer-local-value 'audio-edit-levels buf))
         (floor (if (pair? lv) (max -80 (min -20 (car lv))) -50))
         (nf (number->string (audio-edit--int floor)))
         (de (audio-edit--value buf 'deess))
         (md (audio-edit--value buf 'mud))
         (co (audio-edit--value buf 'compress))
         (lo (audio-edit--value buf 'loudness))
         (parts
           (filter string?
             (list
               (and (number? hp) (> hp 0) (string-append "highpass=f=" (number->string hp)))
               ;; snaps and pops: a mouth pop or a tap is a burst some 20 dB over the
               ;; sound around it; a fast limiter takes it down before the rest
               (cond ((equal? dc 'on) "acompressor=threshold=-26dB:ratio=10:attack=0.05:release=40:knee=2")
                     ((equal? dc 'strong) "highpass=f=120,acompressor=threshold=-28dB:ratio=20:attack=0.03:release=30:knee=2,adeclick")
                     (else #f))
               (cond ((equal? nz 'light) (string-append "afftdn=nr=12:nf=" nf ":tn=1"))
                     ((equal? nz 'medium) (string-append "afftdn=nr=20:nf=" nf ":tn=1"))
                     ((equal? nz 'strong) (string-append "afftdn=nr=30:nf=" nf ":tn=1"))
                     (else #f))
               (and (equal? ga 'on)
                    (string-append "agate=threshold=" (number->string (audio-edit--int (+ floor 9))) "dB:ratio=4:range=0.1:attack=5:release=250"))
               (cond ((equal? md 'light) "equalizer=f=350:t=q:w=1:g=-3,equalizer=f=900:t=q:w=1.2:g=-2")
                     ((equal? md 'strong) "equalizer=f=350:t=q:w=1:g=-6,equalizer=f=900:t=q:w=1.2:g=-4")
                     (else #f))
               (and (equal? de 'on) "deesser=i=0.4")
               (cond ((equal? co 'light) "acompressor=threshold=-20dB:ratio=2:attack=10:release=150")
                     ((equal? co 'strong) "acompressor=threshold=-24dB:ratio=4:attack=5:release=120")
                     (else #f))
               (and (number? lo) (string-append "loudnorm=I=" (number->string lo) ":TP=-1.5:LRA=11"))))))
    (if (null? parts) "anull" (string-join parts ","))))

(define (audio-edit-clean-path path)
  "(audio-edit-clean-path PATH) -- where the cleaned copy of PATH goes: NAME-clean.wav beside it"
  (let* ((dir (path-directory path))
         (name (file-name-nondirectory path))
         (dot (string-rindex name "."))
         (stem (if dot (substring name 0 dot) name)))
    (expand-file-name (string-append stem "-clean.wav") dir)))

(define (audio-edit--cache)
  (expand-file-name audio-edit-cache-directory))

(define (audio-edit--wave-path path)
  "the waveform picture of PATH as it is now: a new file draws a new picture"
  (let* ((st (file-stat path))
         (key (string-append path " " (if (pair? st) (string-append (cadr st) " " (caddr st)) "")))
         (safe (list->string (map (lambda (c) (if (or (char-alphabetic? c) (char-numeric? c)) c #\-))
                                  (string->list key)))))
    (string-append (audio-edit--cache) "/" safe ".png")))

(define (audio-edit--wave-command path out)
  (string-append "mkdir -p " (sh-quote (audio-edit--cache))
                 " && ffmpeg -y -v error -i " (sh-quote path)
                 " -filter_complex 'aformat=channel_layouts=mono,showwavespic=s=1600x200:colors=#5b8def' -frames:v 1 "
                 (sh-quote out) " && echo OK"))
;; The loudness of every 50 ms, quietest first: the tenth percentile is the
;; hiss under the speech, the ninety-fifth the speech itself. The denoiser
;; and the gate take their levels from these, so each file gets its own.
(define (audio-edit--levels-command path)
  (string-append "ffmpeg -nostats -v error -i " (sh-quote path)
                 " -af asetnsamples=2400,astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level:file=- -f null - 2>&1"))

(define (audio-edit--parse-levels out)
  (let* ((key "lavfi.astats.Overall.RMS_level=")
         (vals (filter number?
                 (map (lambda (l) (and (string-prefix? key l)
                                       (string->number (substring l (string-length key) (string-length l)))))
                      (string-split (if (string? out) out "") "\n"))))
         (s (sort vals))
         (n (length s)))
    (and (> n 4) (list (list-ref s (quotient n 10)) (list-ref s (quotient (* n 95) 100))))))

(define (audio-edit--info-line path)
  (let* ((i (ignore-errors (lambda () (media-info path))))
         (fm (and (pair? i) (plist-get i 'format)))
         (st (and (pair? i) (pair? (plist-get i 'streams)) (car (plist-get i 'streams))))
         (dur (and fm (string->number (or (plist-get fm 'duration) "")))))
    (if (not st) ""
        (string-append
          (if dur (let ((s (inexact->exact (round dur)))) (string-append (number->string (quotient s 60)) ":" (if (< (remainder s 60) 10) "0" "") (number->string (remainder s 60)))) "")
          " · " (or (plist-get st 'codec_name) "")
          " · " (let ((sr (plist-get st 'sample_rate))) (if sr (string-append sr " Hz") ""))
          " · " (let ((ch (plist-get st 'channels))) (cond ((equal? ch 1) "mono") ((equal? ch 2) "stereo") (ch (number->string ch)) (else "")))))))

(define (audio-edit--track title path)
  (let ((wave (audio-edit--wave-path path)))
    (string-append
      "<section><div class=\"t\">" (html-escape title) " <span>" (html-escape (file-name-nondirectory path)) "</span></div>"
      (if (file-exists? wave)
          (string-append "<img class=\"w\" src=\"" (html-escape wave) "\" alt=\"\">")
          "<div class=\"w wait\">drawing the waveform…</div>")
      "<audio controls preload=\"metadata\" src=\"" (html-escape path) "\"></audio></section>")))

(define (audio-edit--html buf)
  (let* ((path (buffer-path buf))
         (clean (audio-edit-clean-path path))
         (status (buffer-local-value 'audio-edit-status buf))
         (info (buffer-local-value 'audio-edit-info buf)))
    (string-append
      "<!doctype html><html><head><meta charset=\"utf-8\"><style>"
      "body{font:14px/1.45 system-ui,sans-serif;margin:0;padding:18px 22px;max-width:none!important}"
      "h1{font-size:17px;margin:0 0 2px}.m{opacity:.6;margin-bottom:14px}"
      "section{margin:0 0 18px}.t{font-weight:600;margin-bottom:6px}.t span{font-weight:400;opacity:.6;margin-left:6px}"
      ".w{display:block;width:100%;height:110px;object-fit:fill;border-radius:6px;background:rgba(127,127,127,.08)}"
      ".wait{display:flex;align-items:center;justify-content:center;opacity:.6}"
      "audio{width:100%;margin-top:6px}table{border-collapse:collapse;margin-top:4px}"
      "td{padding:3px 14px 3px 0}td.k{font-family:ui-monospace,monospace;font-weight:600}td.v{font-weight:600}"
      ".s{margin-top:12px;opacity:.75}"
      "</style></head><body>"
      "<h1>" (html-escape (file-name-nondirectory path)) "</h1>"
      "<div class=\"m\">" (html-escape (if (string? info) info ""))
      (let ((lv (buffer-local-value 'audio-edit-levels buf)))
        (if (pair? lv)
            (string-append " · hiss " (number->string (audio-edit--int (car lv))) " dB · speech " (number->string (audio-edit--int (cadr lv))) " dB")
            ""))
      "</div>"
      (audio-edit--track "Original" path)
      (if (file-exists? clean) (audio-edit--track "Cleaned" clean) "")
      "<table>"
      (apply string-append
        (map (lambda (row)
               (string-append "<tr><td class=\"k\">" (cadr row) "</td><td>" (caddr row)
                              "</td><td class=\"v\">" (audio-edit--show (audio-edit--value buf (car row))) "</td></tr>"))
             audio-edit--settings))
      "<tr><td class=\"k\">c</td><td>Clean: write " (html-escape (file-name-nondirectory clean)) "</td><td></td></tr>"
      "<tr><td class=\"k\">g</td><td>Draw again</td><td></td></tr></table>"
      (if (string? status) (string-append "<div class=\"s\">" (html-escape status) "</div>") "")
      "</body></html>")))

(defwrite-rule! 'audio-edit-mode
  "audio-edit-mode holds a player page, not the sound file"
  #f
  (lambda (path source)
    (and source (equal? (buffer-local-value 'mode-name source) "audio-edit-mode"))))

(effects! '(write display))

(define (audio-edit--render! buf)
  (when (and (buffer-known? buf) (buffer-path buf))
    (buffer-set-local! buf 'preview-renderer "html")
    (buffer-set-local! buf 'preview-authored #t)
    (buffer-set-local! buf 'render-mode "html")
    (buffer-set-read-only! buf #f)
    (buffer-delete-range! buf 0 (buffer-size buf))
    (buffer-append! buf (audio-edit--html buf))
    (buffer-mark-saved! buf)
    (buffer-set-read-only! buf #t)))

(define (audio-edit--draw-waves! buf)
  "draw the missing waveform pictures in a task, then the page again"
  (let* ((path (buffer-path buf))
         (clean (audio-edit-clean-path path))
         (todo (filter (lambda (p) (and (file-exists? p) (not (file-exists? (audio-edit--wave-path p)))))
                       (list path clean))))
    (for-each
      (lambda (p)
        (shell-command->string (audio-edit--wave-command p (audio-edit--wave-path p)) "/tmp"
          (lambda (out) (audio-edit--render! buf))))
      todo)))

(define (audio-edit--measure! buf k)
  "measure the hiss and the speech of BUF's file in a task, then call K"
  (shell-command->string (audio-edit--levels-command (buffer-path buf)) "/tmp"
    (lambda (out)
      (buffer-set-local! buf 'audio-edit-levels (audio-edit--parse-levels out))
      (k))))

(define (audio-edit--refresh! buf)
  (buffer-set-local! buf 'audio-edit-info (audio-edit--info-line (buffer-path buf)))
  (buffer-set-local! buf 'audio-edit-levels #f)
  (audio-edit--render! buf)
  (audio-edit--draw-waves! buf)
  (audio-edit--measure! buf (lambda () (audio-edit--render! buf))))

(define (audio-edit-mode-setup)
  (audio-edit--refresh! (current-buffer)))

(define-mode "audio-edit-mode" audio-edit-mode-setup)

(define (audio-edit--step! buf name)
  (let* ((row (assoc name audio-edit--settings))
         (steps (list-ref row 3))
         (now (audio-edit--value buf name))
         (tail (member now steps))
         (next (if (and tail (pair? (cdr tail))) (cadr tail) (car steps))))
    (buffer-set-local! buf (string->symbol (string-append "audio-edit-" (symbol->string name))) next)
    (buffer-set-local! buf 'audio-edit-status #f)
    (audio-edit--render! buf)
    (message (string-append (caddr row) ": " (audio-edit--show next)))))

(define-command "audio-edit-step-highpass" "Step the rumble cut: off, 60, 80 or 120 Hz"
  (lambda () (audio-edit--step! (current-buffer) 'highpass)) 'modes '(audio-edit-mode))
(define-command "audio-edit-step-noise" "Step the noise reduction: off, light, medium or strong"
  (lambda () (audio-edit--step! (current-buffer) 'noise)) 'modes '(audio-edit-mode))
(define-command "audio-edit-step-declick" "Step the pop and click remover: off, on or strong"
  (lambda () (audio-edit--step! (current-buffer) 'declick)) 'modes '(audio-edit-mode))
(define-command "audio-edit-step-gate" "Turn the hiss gate between words on or off"
  (lambda () (audio-edit--step! (current-buffer) 'gate)) 'modes '(audio-edit-mode))
(define-command "audio-edit-step-mud" "Step the mid cut for a boxy sound: off, light or strong"
  (lambda () (audio-edit--step! (current-buffer) 'mud)) 'modes '(audio-edit-mode))
(define-command "audio-edit-step-deess" "Turn the de-esser on or off"
  (lambda () (audio-edit--step! (current-buffer) 'deess)) 'modes '(audio-edit-mode))
(define-command "audio-edit-step-compress" "Step the compression: off, light or strong"
  (lambda () (audio-edit--step! (current-buffer) 'compress)) 'modes '(audio-edit-mode))
(define-command "audio-edit-step-loudness" "Step the loudness target: off, -14, -16, -19 or -23 LUFS"
  (lambda () (audio-edit--step! (current-buffer) 'loudness)) 'modes '(audio-edit-mode))

(define (audio-edit-clean! buf &optional k)
  "(audio-edit-clean! BUF) -- write BUF's file through its cleaning chain to NAME-clean.wav, in a task"
  (let* ((path (buffer-path buf))
         (clean (audio-edit-clean-path path))
         (tmp (string-append (audio-edit--cache) "/" (file-name-nondirectory clean)))
         (cmd (string-append "mkdir -p " (sh-quote (audio-edit--cache))
                             " && ffmpeg -y -v error -i " (sh-quote path)
                             " -af " (sh-quote (audio-edit-chain buf))
                             " -ar 48000 -c:a pcm_s24le " (sh-quote tmp) " && echo OK")))
    (buffer-set-local! buf 'audio-edit-status "Cleaning…")
    (audio-edit--render! buf)
    (shell-command->string cmd "/tmp"
      (lambda (out)
        (if (and (string? out) (string-prefix? "OK" out)
                 (begin (when (file-exists? clean) (delete-file! clean)) (rename-file! tmp clean)))
            (buffer-set-local! buf 'audio-edit-status (string-append "Cleaned: " (file-name-nondirectory clean)))
            (buffer-set-local! buf 'audio-edit-status (string-append "Clean failed: " (if (string? out) (string-trim out) ""))))
        (audio-edit--render! buf)
        (audio-edit--draw-waves! buf)
        (when k (k))))))

(define (audio-edit-clean-measured! buf &optional k)
  "(audio-edit-clean-measured! BUF [K]) -- measure BUF's hiss when it is not known yet, clean, then call K"
  (if (pair? (buffer-local-value 'audio-edit-levels buf))
      (audio-edit-clean! buf k)
      (audio-edit--measure! buf (lambda () (audio-edit-clean! buf k)))))

(define-command "audio-edit-clean" "Write the cleaned copy, NAME-clean.wav, beside the file"
  (lambda () (audio-edit-clean-measured! (current-buffer)))
  'modes '(audio-edit-mode))

(define-command "audio-edit-refresh" "Read the file again and draw the page"
  (lambda () (audio-edit--refresh! (current-buffer))) 'modes '(audio-edit-mode))

(mode-keys! "audio-edit-mode"
  '(("h" "audio-edit-step-highpass")
    ("n" "audio-edit-step-noise")
    ("p" "audio-edit-step-declick")
    ("x" "audio-edit-step-gate")
    ("m" "audio-edit-step-mud")
    ("s" "audio-edit-step-deess")
    ("k" "audio-edit-step-compress")
    ("l" "audio-edit-step-loudness")
    ("c" "audio-edit-clean")
    ("g" "audio-edit-refresh")))

(mode-doc! "audio-edit-mode"
  "A sound file as a page: its waveform and a player. `h` steps the rumble cut, `p` the pop and click remover, `n` the noise reduction, `x` the hiss gate between words, `m` the mid cut, `s` the de-esser, `k` the compression and `l` the loudness target. `c` writes the cleaned copy, NAME-clean.wav, beside the file, and the page shows it under the original to compare. `g` draws the page again.")

(define (audio-edit-register-auto-modes!)
  (for-each
    (lambda (ext)
      (set! *auto-mode-alist*
        (cons (list ext "audio-edit-mode")
              (filter (lambda (entry) (not (equal? (string-downcase (car entry)) ext)))
                      *auto-mode-alist*))))
    audio-edit-extensions))

(audio-edit-register-auto-modes!)

(effects! '(pure))
(public! 'audio-edit-path? "(audio-edit-path? PATH) — #t when PATH opens in audio-edit-mode")
(catalog-meta! 'function "audio-edit-path?" 'domain 'files 'effects '(pure))
(public! 'audio-edit-chain "(audio-edit-chain BUF) — the ffmpeg filter chain BUF's cleaning settings give")
(catalog-meta! 'function "audio-edit-chain" 'domain 'files 'effects '(pure))
(public! 'audio-edit-clean-path "(audio-edit-clean-path PATH) — where the cleaned copy of PATH goes: NAME-clean.wav beside it")
(catalog-meta! 'function "audio-edit-clean-path" 'domain 'files 'effects '(pure))
(effects! '(write execute))
(public! 'audio-edit-clean! "(audio-edit-clean! BUF [K]) — write BUF's file through its cleaning chain to NAME-clean.wav in a task, then call K")
(catalog-meta! 'function "audio-edit-clean-measured!" 'domain 'files 'effects '(write execute))
(public! 'audio-edit-clean-measured! "(audio-edit-clean-measured! BUF [K]) — measure BUF's hiss when it is not known, clean, then call K")
(catalog-meta! 'function "audio-edit-clean!" 'domain 'files 'effects '(write execute))

(provide 'audio-edit)
