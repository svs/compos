;;; tts-training.scm --- record voice samples, clone them, and hear the takes.
;;
;; M-x tts-training lists the voice samples. A sample's page plays it and every
;; take made from it, newest first. r records a new sample on the recorder page
;; (recorder.js), i imports a sound file, t speaks a line in the sample's voice
;; with Pocket TTS or Chatterbox, e picks the engine and x the expression.
;;
;; On disk, under tts-training-directory:
;;   samples/ID.wav  samples/ID.json   (name mood source created)
;;   takes/ID/TAKE.wav  takes/ID/TAKE.json   (text engine exaggeration created)
;; The models, uv and Hugging Face caches live under tts-training-home.

(require 'audio-edit)

(domain! 'files)
(effects! '(pure))

(defgroup 'tts-training "Recording voice samples and testing cloned speech.")

(defcustom 'tts-training-directory "~/Music/tts-training"
  "Where the samples and takes are kept."
  'type 'string 'group 'tts-training)

(defcustom 'tts-training-home "~/.cache/compos-tts"
  "Where the TTS programs keep their models and caches."
  'type 'string 'group 'tts-training)

(defcustom 'tts-training-engine "pocket"
  "The engine t speaks with: pocket, chatterbox or both."
  'type 'string 'group 'tts-training)

(defcustom 'tts-training-exaggeration 0.5
  "Chatterbox's expression: 0.25 is flat, 0.5 normal, 0.8 and up dramatic."
  'type 'number 'group 'tts-training)

(defcustom 'tts-training-token-command ""
  "A command prefix that puts HF_TOKEN in the environment of Pocket TTS, such as doppler run -- . Empty when the token is already there."
  'type 'string 'group 'tts-training)

(defcustom 'tts-training-eq
  "highpass=f=70,equalizer=f=350:t=q:w=1.0:g=-5,equalizer=f=900:t=q:w=1.2:g=-3,equalizer=f=3500:t=q:w=1.0:g=2.5,highshelf=f=8000:g=3,acompressor=threshold=-20dB:ratio=2.5:attack=10:release=120,loudnorm=I=-16:TP=-1.5:LRA=7,aresample=48000"
  "The ffmpeg filter chain every take goes through: less mud, more presence and air, then loudness."
  'type 'string 'group 'tts-training)

(defcustom 'tts-training-sample-clean "highpass=f=80,afftdn=nf=-25"
  "The ffmpeg filter chain a new sample goes through before it is kept."
  'type 'string 'group 'tts-training)

(defcustom 'tts-training-text
  "So here is the thing. I built this editor because every tool I used got in my way! And honestly? I wanted one place where it all lives together."
  "The line t offers to speak."
  'type 'string 'group 'tts-training)

(define *tts-training-buffer* "*tts-training*")
(define *tts-training-recorder* "*tts-training-recorder*")

(define tts-training-moods '("calm" "warm" "excited" "serious" "story"))

(define tts-training-scripts
  '(("calm" "Take a slow breath. Nothing here needs to happen quickly. We will read the plan once, check each step, and only then begin. If something looks wrong, we stop, we look, and we fix it.")
    ("warm" "Thanks so much for coming along today. I really mean that. I know your time is precious, so I am going to show you the one thing I am most proud of, and I think you are going to like it.")
    ("excited" "Okay, look at this! It just worked, first time! I typed one line and the whole thing rebuilt itself in front of me. Honestly, I did not think we would get here this week. This is huge!")
    ("serious" "Here is the problem. Every team we spoke to loses hours each week to tools that do not talk to each other. That cost is real, it compounds, and nobody is measuring it. We should.")
    ("story" "It was late, and the office was empty. The only light came from a single screen in the corner. She leaned closer, read the message twice, and then, very slowly, she began to smile.")))

(define (tts-training--dir . parts)
  (apply string-append (expand-file-name tts-training-directory) "/" parts))

(define (tts-training--home . parts)
  (apply string-append (expand-file-name tts-training-home) "/" parts))

(define (tts-training--own-dir)
  (let ((ds (filter (lambda (d) (string-suffix? "/tts-training" d)) (stdlib-dirs)))) (and (pair? ds) (car ds))))

(define (tts-training--read-json path)
  (and (file-exists? path) (or (json-parse (read-file path)) '())))

(define (tts-training--stem path)
  (let ((n (file-name-nondirectory path)))
    (if (string-suffix? ".wav" n) (substring n 0 (- (string-length n) 4)) n)))

(define (tts-training--duration path)
  (let* ((i (ignore-errors (lambda () (media-info path))))
         (fm (and (pair? i) (plist-get i 'format))))
    (and fm (string->number (or (plist-get fm 'duration) "")))))

(define (tts-training--clock secs)
  (if (not secs) ""
      (let ((s (inexact->exact (round secs))))
        (string-append (number->string (quotient s 60)) ":" (if (< (remainder s 60) 10) "0" "") (number->string (remainder s 60))))))

(define (tts-training--snippet text n)
  (if (> (string-length text) n) (string-append (substring text 0 (- n 1)) "…") text))

(effects! '(read))

(define (tts-training-samples)
  "(tts-training-samples) -- every sample as a plist: id path name mood source created secs, newest first"
  (let ((dir (tts-training--dir "samples")))
    (if (not (file-exists? dir)) '()
        (reverse
          (map (lambda (p)
                 (let* ((id (tts-training--stem p))
                        (meta (or (tts-training--read-json (tts-training--dir "samples/" id ".json")) '())))
                   (list 'id id 'path p
                         'name (or (plist-get meta 'name) id)
                         'mood (or (plist-get meta 'mood) "")
                         'source (or (plist-get meta 'source) "")
                         'created (or (plist-get meta 'created) "")
                         'secs (plist-get meta 'secs))))
               (directory-files dir #t "\\.wav$"))))))

(define (tts-training-sample id)
  (let ((hit (filter (lambda (s) (equal? (plist-get s 'id) id)) (tts-training-samples))))
    (and (pair? hit) (car hit))))

(define (tts-training-takes id)
  "(tts-training-takes ID) -- the takes of sample ID as plists: path text engine exaggeration created, newest first"
  (let ((dir (tts-training--dir "takes/" id)))
    (if (not (file-exists? dir)) '()
        (reverse
          (map (lambda (p)
                 (let ((meta (or (tts-training--read-json (string-append (substring p 0 (- (string-length p) 4)) ".json")) '())))
                   (list 'path p 'id (tts-training--stem p)
                         'text (or (plist-get meta 'text) "")
                         'engine (or (plist-get meta 'engine) "")
                         'exaggeration (plist-get meta 'exaggeration)
                         'created (or (plist-get meta 'created) ""))))
               (directory-files dir #t "\\.wav$"))))))

;; ---- the commands the engines run

(define (tts-training--env)
  (let ((h (lambda (p) (sh-quote (tts-training--home p)))))
    (string-append "export UV_TOOL_DIR=" (h "uv-tools") " UV_CACHE_DIR=" (h "uv-cache")
                   " UV_PYTHON_INSTALL_DIR=" (h "uv-python") " HF_HOME=" (h "hf")
                   " XDG_CACHE_HOME=" (h "cache") " PYTORCH_ENABLE_MPS_FALLBACK=1 && ")))

(define (tts-training--engine-command engine voice out text)
  (let ((uv (or (executable-find "uv") "uv")) (uvx (or (executable-find "uvx") "uvx")))
    (string-append
      "mkdir -p " (sh-quote (tts-training--home "work")) " && cd " (sh-quote (tts-training--home "work")) " && "
      (tts-training--env)
      (if (equal? engine "chatterbox")
          (string-append (sh-quote uv) " run --no-project --python 3.11 --with chatterbox-tts --with peft python -I "
                         (sh-quote (string-append (tts-training--own-dir) "/chatterbox.py")) " "
                         (sh-quote voice) " " (sh-quote out) " " (sh-quote text) " "
                         (number->string tts-training-exaggeration) " " (if (> tts-training-exaggeration 0.7) "0.3" "0.5"))
          (string-append (if (equal? tts-training-token-command "") "" (string-append tts-training-token-command " "))
                         (sh-quote uvx) " pocket-tts generate --voice " (sh-quote voice)
                         " --text " (sh-quote text) " --output-path " (sh-quote out)))
      " 2>&1 | grep -E 'OK|Error|error' | tail -4")))

(define (tts-training--eq-command in out)
  (string-append "ffmpeg -y -v error -i " (sh-quote in) " -af " (sh-quote tts-training-eq) " -c:a pcm_s24le " (sh-quote out) " && echo OK"))

(effects! '(write execute))

(define *tts-training-jobs* (if (boundp '*tts-training-jobs*) *tts-training-jobs* '()))

(define (tts-training--log! text)
  (buffer-create "*tts-training-log*")
  (buffer-append! "*tts-training-log*" (string-append (format-time-string "%H:%M:%S ") text "\n")))

(define (tts-training-generate! id text engine &optional k)
  "(tts-training-generate! ID TEXT ENGINE [K]) -- speak TEXT in sample ID's voice with ENGINE (pocket or chatterbox), EQ it, keep it as a take; K gets the take's path or #f"
  (let* ((s (tts-training-sample id))
         (take (string-append (format-time-string "%Y%m%d-%H%M%S") "-" engine))
         (raw (tts-training--home "work/" take "-raw.wav"))
         (eq (tts-training--home "work/" take ".wav"))
         (dir (tts-training--dir "takes/" id "/"))
         (job (list id engine text)))
    (if (not s) (begin (message "No sample " id) (when k (k #f)))
        (begin
          (set! *tts-training-jobs* (cons job *tts-training-jobs*))
          (tts-training--redraw-page! id)
          (message (string-append "Speaking with " engine "…"))
          (shell-command->string
            (string-append (tts-training--engine-command engine (plist-get s 'path) raw text) "; " (tts-training--eq-command raw eq))
            "/tmp"
            (lambda (out)
              (set! *tts-training-jobs* (filter (lambda (j) (not (eq? j job))) *tts-training-jobs*))
              (let ((ok (and (string? out) (string-suffix? "OK" (string-trim out)) (file-exists? eq))))
                (if (not ok)
                    (begin (tts-training--log! (string-append engine " failed for " id ": " (or out "")))
                           (message (string-append engine " failed: see *tts-training-log*")))
                    (begin
                      (make-directory! dir)
                      (rename-file! eq (string-append dir take ".wav"))
                      (when (file-exists? raw) (delete-file! raw))
                      (write-file! (string-append dir take ".json")
                        (json-encode (list 'text text 'engine engine
                                           'exaggeration (and (equal? engine "chatterbox") tts-training-exaggeration)
                                           'created (format-time-string "%b %d %H:%M"))))
                      (message (string-append "New take with " engine))))
                (tts-training--redraw-page! id)
                (tts-training--refresh-list!)
                (when k (k (and ok (string-append dir take ".wav"))))))))))
  #t)

(define (tts-training-add-sample! src name mood source &optional k)
  "(tts-training-add-sample! SRC NAME MOOD SOURCE [K]) -- clean the sound file SRC into a new sample; K gets its id or #f"
  (let* ((id (string-append (format-time-string "%Y%m%d-%H%M%S") "-" (if (equal? mood "") "voice" mood)))
         (tmp (tts-training--home "work/" id ".wav")))
    (make-directory! (tts-training--home "work"))
    (shell-command->string
      (string-append "ffmpeg -y -v error -i " (sh-quote src) " -af " (sh-quote tts-training-sample-clean)
                     " -ac 1 -ar 24000 -c:a pcm_s16le " (sh-quote tmp) " && echo OK")
      "/tmp"
      (lambda (out)
        (let ((d (and (string? out) (string-suffix? "OK" (string-trim out)) (tts-training--duration tmp))))
          (if (not d)
              (begin (tts-training--log! (string-append "sample failed from " src ": " (or out "")))
                     (message "The sample could not be saved: see *tts-training-log*")
                     (when k (k #f)))
              (begin
                (make-directory! (tts-training--dir "samples"))
                (rename-file! tmp (tts-training--dir "samples/" id ".wav"))
                (write-file! (tts-training--dir "samples/" id ".json")
                  (json-encode (list 'name name 'mood mood 'source source 'secs d 'created (format-time-string "%b %d %H:%M"))))
                (message (string-append "New sample " name " · " (tts-training--clock d)))
                (tts-training--refresh-list!)
                (when k (k id)))))))))

(define (tts-training-delete-sample! id)
  "(tts-training-delete-sample! ID) -- remove sample ID and its takes"
  (for-each (lambda (p) (when (file-exists? p) (delete-file! p)))
            (append (list (tts-training--dir "samples/" id ".wav") (tts-training--dir "samples/" id ".json"))
                    (let ((d (tts-training--dir "takes/" id)))
                      (if (file-exists? d) (directory-files d #t) '()))))
  (let ((page (tts-training--page-name id))) (when (buffer-known? page) (buffer-kill! page)))
  (tts-training--refresh-list!))

;; ---- the listing

(define (tts-training--rows buf) (tts-training-samples))

(define (tts-training--cells buf row)
  (list (plist-get row 'name)
        (list (plist-get row 'mood) "c-dim")
        (tts-training--clock (plist-get row 'secs))
        (let ((n (length (tts-training-takes (plist-get row 'id))))) (if (= n 0) "" (number->string n)))
        (plist-get row 'created)
        (plist-get row 'source)))

(define (tts-training--refresh-list!)
  (when (buffer-known? *tts-training-buffer*) (list-refresh! *tts-training-buffer*)))

(define (tts-training--list)
  (if (equal? (buffer-local-value 'mode-name (current-buffer)) "tts-training-mode")
      (current-buffer)
      *tts-training-buffer*))

(define (tts-training--at)
  "the sample at hand: the page's own, else the listing's row"
  (let ((id (buffer-local-value 'tts-training-id (current-buffer))))
    (or (and id (tts-training-sample id))
        (and (buffer-known? *tts-training-buffer*) (list-current *tts-training-buffer*)))))

;; ---- a sample's page

(define (tts-training--page-name id) (string-append "*tts-training:" id "*"))

(define (tts-training--engine-label)
  (cond ((equal? tts-training-engine "both") "Pocket + Chatterbox")
        ((equal? tts-training-engine "chatterbox") "Chatterbox")
        (else "Pocket TTS")))

(define (tts-training--page-blocks s)
  (let* ((id (plist-get s 'id))
         (takes (tts-training-takes id))
         (jobs (filter (lambda (j) (equal? (car j) id)) *tts-training-jobs*)))
    (append
      (list (component 'ui/title (list 'text (plist-get s 'name) 'badge (plist-get s 'mood) 'tone "info"))
            (component 'ui/meta (list 'segs (list (list "" (tts-training--clock (plist-get s 'secs)))
                                                  '("c-sep" "  ·  ") (list "" (plist-get s 'created))
                                                  '("c-sep" "  ·  ") (list "" (string-append (number->string (length takes)) " takes"))
                                                  '("c-sep" "  ·  ") (list "c-dim" (string-append "speaks with " (tts-training--engine-label)
                                                                                                    (if (equal? tts-training-engine "pocket") ""
                                                                                                        (string-append ", expression " (number->string tts-training-exaggeration))))))))
            (component 'ui/actions (list 'actions (list (list "tts-training-test" "Speak a line" "t" "good")
                                                        (list "tts-training-engine" (string-append "Engine: " (tts-training--engine-label)) "e")
                                                        (list "tts-training-expression" (string-append "Expression " (number->string tts-training-exaggeration)) "x")
                                                        (list "tts-training-record" "Record a sample" "r")
                                                        (list "tts-training-import" "Import a file" "i")
                                                        (list "tts-training-rename" "Rename" "R")
                                                        (list "tts-training-delete" "Delete" "d" "bad"))))
            (component 'ui/group (list 'title "Sample"
                                       'body (list (component 'ui/audio (list 'path (plist-get s 'path) 'title "The voice it clones"
                                                                              'sub (if (equal? (plist-get s 'source) "") "recorded here" (plist-get s 'source))))))))
      (if (null? jobs) '()
          (list (component 'ui/group (list 'title "Speaking now"
                                           'body (map (lambda (j) (list 'tag "c-group" 'class "c-prose c-dim"
                                                                        'text (string-append (cadr j) ": “" (tts-training--snippet (caddr j) 90) "”")))
                                                      jobs)))))
      (list (component 'ui/group
              (list 'title (string-append "Takes  ·  " (number->string (length takes)))
                    'body (if (null? takes)
                              (list (list 'tag "c-group" 'class "c-prose c-dim" 'text "No takes yet. t speaks a line in this voice."))
                              (map (lambda (t)
                                     (component 'ui/audio
                                       (list 'path (plist-get t 'path)
                                             'title (tts-training--snippet (plist-get t 'text) 80)
                                             'sub (string-append (plist-get t 'engine)
                                                                 (if (plist-get t 'exaggeration) (string-append " · expression " (number->string (plist-get t 'exaggeration))) "")
                                                                 " · " (plist-get t 'created)))))
                                   takes))))))))

(define (tts-training--render-page! buf s)
  (buffer-set-read-only! buf #f)
  (anchor-page! buf (tts-training--page-blocks s))
  (buffer-set-local! buf 'footer-line-blocks
    (list (component 'ui/keys-bar
            (list 'main '(("t" "speak") ("e" "engine") ("x" "expression") ("r" "record") ("i" "import") ("R" "rename") ("d" "delete") ("g" "refresh"))))))
  (buffer-set-read-only! buf #t))

(define (tts-training--redraw-page! id)
  (let ((buf (tts-training--page-name id)) (s (tts-training-sample id)))
    (when (and s (buffer-known? buf)) (tts-training--render-page! buf s))))

(effects! '(write display))

(define (tts-training-show-detail! row)
  "(tts-training-show-detail! ROW) -- show sample ROW's page beside the listing"
  (when row
    (let* ((list-buf (tts-training--list))
           (buf (tts-training--page-name (plist-get row 'id))))
      (unless (buffer-known? buf)
        (buffer-create buf)
        (let ((g (and (buffer-known? list-buf) (buffer-group list-buf)))) (when g (buffer-move-to-group! buf g)))
        (with-current-buffer buf (lambda () (set-mode! "tts-training-detail-mode")))
        (desktop-skip! buf 'render-blocks)
        (desktop-skip! buf 'footer-line-blocks))
      (buffer-set-local! buf 'tts-training-id (plist-get row 'id))
      (tts-training--render-page! buf row)
      (display-buffer-detail! buf list-buf))))

;; ---- the recorder page

(define *tts-training-rec* (if (boundp '*tts-training-rec*) *tts-training-rec* (list 'mood "calm" 'status "")))

(define (tts-training--rec-get k) (plist-get *tts-training-rec* k))
(define (tts-training--rec-set! k v) (set! *tts-training-rec* (plist-put *tts-training-rec* k v)))

(define (tts-training--rec-state)
  (let ((mood (tts-training--rec-get 'mood)))
    (list 'mood (string-append mood "  ·  read this in a " mood " voice, close to the mic")
          'script (cadr (or (assoc mood tts-training-scripts) (car tts-training-scripts)))
          'status (tts-training--rec-get 'status)
          'keys "SPC record and stop · x throw away · m mood · q close   —   15 to 25 seconds, dry room, the bar green, not red")))

(define (tts-training--rec-post! data)
  (when (buffer-known? *tts-training-recorder*) (app-post! *tts-training-recorder* data)))

(define tts-training--recorder-html
  "<!doctype html><html><head><meta charset=\"utf-8\"><link rel=\"stylesheet\" href=\"recorder.css\"></head><body><script src=\"recorder.js\"></script></body></html>")

(define (tts-training--recorder-fill! name)
  (unless (equal? (buffer-text name) tts-training--recorder-html)
    (buffer-set-read-only! name #f)
    (buffer-delete-range! name 0 (buffer-size name))
    (buffer-append! name tts-training--recorder-html)
    (buffer-mark-saved! name)
    (buffer-set-read-only! name #t)))

(define (tts-training--save-recording! data mime secs)
  (let* ((raw (tts-training--home "work/rec-" (format-time-string "%Y%m%d-%H%M%S")
                                  (if (and (string? mime) (string-contains? mime "mp4")) ".m4a" ".webm")))
         (mood (tts-training--rec-get 'mood)))
    (make-directory! (tts-training--home "work"))
    (write-file! raw (base64-decode data))
    (tts-training--rec-set! 'status "Saving…")
    (tts-training-add-sample! raw (string-append mood " " (format-time-string "%b %d %H:%M")) mood ""
      (lambda (id)
        (when (file-exists? raw) (delete-file! raw))
        (tts-training--rec-set! 'status (if id "Kept. SPC records another, m changes the mood." "It could not be saved: see *tts-training-log*"))
        (tts-training--rec-post! (list 'state (tts-training--rec-state)))
        (when id (tts-training-show-detail! (tts-training-sample id)))))))

(define (tts-training--app-request buf method body)
  (and (equal? buf *tts-training-recorder*)
       (let ((o (if (equal? method "POST") (or (json-parse body) '()) '())))
         (when (equal? (plist-get o 'op) "save")
           (tts-training--save-recording! (plist-get o 'data) (plist-get o 'mime) (plist-get o 'secs)))
         (list 200 (json-encode (tts-training--rec-state))))))

(add-hook! 'app-request 'tts-training--app-request)

(define (tts-training-recorder-mode-setup)
  (let ((name (current-buffer)))
    (when (equal? name *tts-training-recorder*)
      (tts-training--recorder-fill! name)
      (buffer-set-local! name 'render-mode "app"))))

(define (tts-training-recorder!)
  "(tts-training-recorder!) -- the recorder page, shown beside the listing"
  (let ((name *tts-training-recorder*) (list-buf *tts-training-buffer*))
    (buffer-create name)
    (let ((g (and (buffer-known? list-buf) (buffer-group list-buf)))) (when (and g (not (equal? (buffer-group name) g))) (buffer-move-to-group! name g)))
    (unless (equal? (buffer-local-value 'mode-name name) "tts-training-recorder-mode")
      (with-current-buffer name (lambda () (set-mode! "tts-training-recorder-mode"))))
    (buffer-set-local! name 'app-directory (list (tts-training--own-dir)))
    (tts-training--recorder-fill! name)
    (desktop-skip! name 'footer-line-blocks)
    (buffer-set-local! name 'footer-line-blocks
      (list (component 'ui/keys-bar (list 'main '(("SPC" "record / stop") ("x" "throw away") ("m" "mood") ("q" "close"))))))
    (tts-training--rec-set! 'status "SPC starts recording")
    (app-reload! name)
    (buffer-set-local! name 'render-mode "app")
    (if (buffer-known? list-buf) (display-buffer-detail! name list-buf) (display-buffer-other-window! name))
    name))

;; ---- modes and commands

(define-list-mode! "tts-training-mode"
  (list
    'doc (string-append
           "Your voice samples, newest first. Moving the point shows the sample's page beside the list: the sample and every take made from it. "
           "t speaks a line in the voice, e picks the engine (Pocket TTS, Chatterbox or both), x the expression. "
           "r records a new sample on the recorder page, i imports a sound file, R renames, d deletes, / narrows the rows, g reads the samples again, q quits.")
    'buffer *tts-training-buffer*
    'transient #f
    'plain #t
    'rows tts-training--rows
    'key (lambda (buf row) (plist-get row 'id))
    'markable? (lambda (buf row) #f)
    'columns (lambda (buf) (list (list "sample" 24) (list "mood" 9) (list "length" 7) (list "takes" 6) (list "made" 13) (list "from" #f)))
    'cells tts-training--cells
    'layouts (list (list 'name 'narrow 'max-cols (lambda (buf) 70)
                         'columns (lambda (buf) (list (list "sample" 22) (list "length" 7) (list "takes" #f)))
                         'cells (lambda (buf row) (let ((c (tts-training--cells buf row))) (list (car c) (caddr c) (cadddr c)))))
                   (list 'name 'wide 'default #t))
    'preview (lambda (buf row) (tts-training-show-detail! row))
    'title (lambda (buf) "Voice samples")
    'noun "sample"
    'footer (lambda (buf) '(("t" "speak") ("e" "engine") ("x" "expression") ("r" "record") ("i" "import") ("R" "rename") ("d" "delete") ("/" "filter") ("g" "refresh") ("q" "quit")))
    'keys '(("RET" "tts-training-test") ("t" "tts-training-test") ("e" "tts-training-engine") ("x" "tts-training-expression")
            ("r" "tts-training-record") ("i" "tts-training-import") ("R" "tts-training-rename") ("d" "tts-training-delete")
            ("g" "tts-training-refresh") ("q" "quit-window"))))

(define-mode "tts-training-detail-mode" (lambda () (buffer-set-read-only! (current-buffer) #t)))
(mode-keys! "tts-training-detail-mode"
  '(("t" "tts-training-test") ("e" "tts-training-engine") ("x" "tts-training-expression") ("r" "tts-training-record")
    ("i" "tts-training-import") ("R" "tts-training-rename") ("d" "tts-training-delete") ("g" "tts-training-refresh")))
(mode-doc! "tts-training-detail-mode"
  "One voice sample: the sample itself and every take made from it, newest first, each with its player. t speaks a line in this voice, e picks the engine, x the expression, r records a new sample, i imports one, R renames, d deletes, g draws it again.")

(define-mode "tts-training-recorder-mode" tts-training-recorder-mode-setup)
(mode-keys! "tts-training-recorder-mode"
  '(("SPC" "tts-training-record-toggle") ("x" "tts-training-record-cancel") ("m" "tts-training-record-mood") ("q" "quit-window")))
(mode-doc! "tts-training-recorder-mode"
  "Record a voice sample. The page shows a script in the chosen mood: SPC starts recording, SPC again stops and keeps it as a new sample, x throws it away, m changes the mood. Keep the level bar green, not red.")

(define-command "tts-training" "Record voice samples and hear them cloned"
  (lambda ()
    (let ((buf (list-mode-show! "tts-training-mode")))
      (tts-training-show-detail! (list-current buf))
      buf)))

(define-command "tts-training-refresh" "Read the samples again"
  (lambda ()
    (tts-training--refresh-list!)
    (let ((s (tts-training--at))) (when s (tts-training--redraw-page! (plist-get s 'id)))))
  'modes '(tts-training-mode tts-training-detail-mode))

(define-command "tts-training-test" "Speak a line in the voice of the sample at point"
  (lambda ()
    (let ((s (tts-training--at)))
      (if (not s) (message "No sample here: r records one, i imports one")
          (read-string "Speak: "
            (lambda (text)
              (let ((text (if (or (not text) (equal? (string-trim text) "")) tts-training-text text)))
                (customize-save! 'tts-training-text text)
                (for-each (lambda (e) (tts-training-generate! (plist-get s 'id) text e))
                          (if (equal? tts-training-engine "both") '("pocket" "chatterbox") (list tts-training-engine)))))
            'initial tts-training-text))))
  'modes '(tts-training-mode tts-training-detail-mode))

(define-command "tts-training-engine" "Step the engine: Pocket TTS, Chatterbox, both"
  (lambda ()
    (customize-save! 'tts-training-engine
      (cond ((equal? tts-training-engine "pocket") "chatterbox") ((equal? tts-training-engine "chatterbox") "both") (else "pocket")))
    (message (string-append "Speaks with " (tts-training--engine-label)))
    (let ((s (tts-training--at))) (when s (tts-training--redraw-page! (plist-get s 'id)))))
  'modes '(tts-training-mode tts-training-detail-mode))

(define-command "tts-training-expression" "Step Chatterbox's expression: 0.3, 0.5, 0.7, 0.9"
  (lambda ()
    (customize-save! 'tts-training-exaggeration
      (cond ((< tts-training-exaggeration 0.4) 0.5) ((< tts-training-exaggeration 0.6) 0.7) ((< tts-training-exaggeration 0.8) 0.9) (else 0.3)))
    (message (string-append "Expression " (number->string tts-training-exaggeration) (if (equal? tts-training-engine "pocket") " (Chatterbox only: e picks it)" "")))
    (let ((s (tts-training--at))) (when s (tts-training--redraw-page! (plist-get s 'id)))))
  'modes '(tts-training-mode tts-training-detail-mode))

(define-command "tts-training-record" "Record a new voice sample"
  (lambda () (tts-training-recorder!))
  'modes '(tts-training-mode tts-training-detail-mode))

(define-command "tts-training-import" "Make a sample from a sound file"
  (lambda ()
    (read-string "Sound file: "
      (lambda (path)
        (let ((p (and path (expand-file-name (string-trim path)))))
          (if (not (and p (file-exists? p))) (message "No such file")
              (completing-read "Mood: " tts-training-moods
                (lambda (mood)
                  (tts-training-add-sample! p (tts-training--stem (file-name-nondirectory p)) (or mood "") (abbreviate-file-name p)
                    (lambda (id) (when id (tts-training-show-detail! (tts-training-sample id))))))))))
      'initial (string-append (expand-file-name "~/Downloads") "/")))
  'modes '(tts-training-mode tts-training-detail-mode))

(define-command "tts-training-rename" "Rename the sample at point"
  (lambda ()
    (let ((s (tts-training--at)))
      (when s
        (read-string "Name: "
          (lambda (name)
            (when (and name (not (equal? (string-trim name) "")))
              (let* ((jp (tts-training--dir "samples/" (plist-get s 'id) ".json"))
                     (meta (or (tts-training--read-json jp) '())))
                (write-file! jp (json-encode (plist-put meta 'name (string-trim name))))
                (tts-training--refresh-list!)
                (tts-training--redraw-page! (plist-get s 'id)))))
          'initial (plist-get s 'name)))))
  'modes '(tts-training-mode tts-training-detail-mode))

(define-command "tts-training-delete" "Delete the sample at point and its takes"
  (lambda ()
    (let ((s (tts-training--at)))
      (when s
        (y-or-n (string-append "Delete " (plist-get s 'name) " and its takes? ")
          (lambda () (tts-training-delete-sample! (plist-get s 'id)) (message "Deleted"))))))
  'modes '(tts-training-mode tts-training-detail-mode))

(define-command "tts-training-record-toggle" "Start recording, or stop and keep the sample"
  (lambda () (tts-training--rec-post! (list 'act "toggle")))
  'modes '(tts-training-recorder-mode))

(define-command "tts-training-record-cancel" "Stop recording and throw it away"
  (lambda () (tts-training--rec-post! (list 'act "cancel")))
  'modes '(tts-training-recorder-mode))

(define-command "tts-training-record-mood" "Read the script of the next mood"
  (lambda ()
    (let* ((m (tts-training--rec-get 'mood))
           (rest (member m tts-training-moods))
           (next (if (and rest (pair? (cdr rest))) (cadr rest) (car tts-training-moods))))
      (tts-training--rec-set! 'mood next)
      (tts-training--rec-set! 'status (string-append "Mood: " next ". SPC starts recording"))
      (tts-training--rec-post! (list 'state (tts-training--rec-state)))))
  'modes '(tts-training-recorder-mode))

(effects! '(read))
(public! 'tts-training-samples "(tts-training-samples) -- every voice sample as a plist: id path name mood source created secs, newest first")
(public! 'tts-training-takes "(tts-training-takes ID) -- the takes of sample ID: path text engine exaggeration created, newest first")
(effects! '(write execute))
(public! 'tts-training-generate! "(tts-training-generate! ID TEXT ENGINE [K]) -- speak TEXT in sample ID's voice with pocket or chatterbox, EQ it and keep it as a take; K gets its path or #f")
(public! 'tts-training-add-sample! "(tts-training-add-sample! SRC NAME MOOD SOURCE [K]) -- clean the sound file SRC into a new sample; K gets its id or #f")
(effects! '(destroy))
(public! 'tts-training-delete-sample! "(tts-training-delete-sample! ID) -- remove sample ID and its takes")
(effects! '(write display))
(public! 'tts-training-show-detail! "(tts-training-show-detail! ROW) -- show sample ROW's page beside the listing")
(public! 'tts-training-recorder! "(tts-training-recorder!) -- the recorder page beside the listing")

(provide 'tts-training)
