;;; video-transcript.scm --- edit a video by its words.
;;;
;;; whisper.cpp writes down every word of an edit's sources with its time.
;;; The transcript shows them a sentence a line. Mark a stretch and `c`
;;; clips it: a hidden clip leaves the video, a shown one stays and is only
;;; marked. The clips live in the edit, as `clip` lines under their source,
;;; so the page, the preview and the export all follow them.

(require 'video-edit)

(domain! 'files)
(effects! '(pure))

(defgroup 'video-transcript "Transcripts of video edits.")

(defcustom 'video-transcript-whisper "~/.compos/mcp/whisper/whisper.cpp/build/bin/whisper-cli"
  "The whisper.cpp program that writes the transcript."
  'group 'video-transcript 'type 'string)

(defcustom 'video-transcript-model "~/Library/Application Support/superwhisper/ggml-small.en.bin"
  "The whisper model it uses: any ggml model file."
  'group 'video-transcript 'type 'string)

(defface! 'video-transcript-hidden 'fg "#9a9a9a" 'bg "rgba(224, 108, 117, 0.16)")
(defface! 'video-transcript-shown 'bg "rgba(91, 141, 239, 0.18)")
(defface! 'video-transcript-time 'fg "#8a8a8a")

(define (video-transcript--json path)
  (string-append (video-edit--cache) "/tx-" (video-edit--key path 0 0)))

;; whisper places a word roughly: its start can sit in the silence before
;; it and its end stretch over the pause after. The sound says where speech
;; is, so each word is moved onto it: a start in a silence goes to the
;; silence's end, an end in a silence to its start.
(define (video-transcript--snap words silences)
  (let ((in (lambda (t) (let loop ((ss silences)) (cond ((null? ss) #f) ((and (> t (car (car ss))) (< t (cadr (car ss)))) (car ss)) (else (loop (cdr ss))))))))
    (let loop ((ws words) (prev 0) (acc '()))
      (if (null? ws) (reverse acc)
          (let* ((w (car ws)) (a (car w)) (b (cadr w))
                 ;; a word whole inside a silence was heard where the speech resumes
                 (sa (in a)) (a2 (if sa (cadr sa) a)) (b (max b (+ a2 0.05)))
                 (sb (in b)) (b2 (if (and sb (> (car sb) a2)) (car sb) b))
                 (a3 (max a2 prev)) (b3 (max b2 (+ a3 0.05))))
            (loop (cdr ws) a3 (cons (list a3 b3 (caddr w)) acc)))))))

(define (video-transcript--silence-file path) (string-append (video-transcript--json path) ".silence"))

(define (video-transcript--silences path)
  "the silences of PATH as the transcript saved them, or ()"
  (let ((t (read-file (video-transcript--silence-file path))))
    (if (not (string? t)) '()
        (filter pair? (map (lambda (l) (let ((w (string-split l " "))) (and (= (length w) 2) (string->number (car w)) (string->number (cadr w)) (list (string->number (car w)) (string->number (cadr w))))))
                           (string-split t "\n"))))))

;; the words are read and moved onto the speech once, then kept until the
;; transcript or the silence map on disk changes
(define video-transcript--cache '())

(define (video-transcript-words path)
  "(video-transcript-words PATH) -- every word whisper heard in PATH, each (START END TEXT), moved onto the speech, or #f before the transcript exists"
  (let* ((j (string-append (video-transcript--json path) ".json"))
         (stamp (list (file-stat j) (file-stat (video-transcript--silence-file path))))
         (hit (assoc path video-transcript--cache)))
    (if (and hit (equal? (cadr hit) stamp))
        (caddr hit)
        (let* ((raw (video-transcript--raw-words path))
               (words (and raw (video-transcript--snap raw (video-transcript--silences path)))))
          (set! video-transcript--cache (cons (list path stamp words) (filter (lambda (e) (not (equal? (car e) path))) video-transcript--cache)))
          words))))

(define (video-transcript--raw-words path)
  (let ((t (read-file (string-append (video-transcript--json path) ".json"))))
    (and (string? t)
         (let ((j (json-parse t)))
           (filter pair?
             (map (lambda (w)
                    (let* ((o (plist-get w 'offsets)) (text (string-trim (or (plist-get w 'text) ""))))
                      (and o (not (equal? text "")) (not (string-prefix? "[" text))
                           (list (/ (plist-get o 'from) 1000.0) (/ (plist-get o 'to) 1000.0) text))))
                  (or (plist-get j 'transcription) '())))))))

(define (video-transcript--command path)
  (let ((wav (string-append (video-transcript--json path) ".wav")))
    (string-append "mkdir -p " (sh-quote (video-edit--cache))
                   " && ffmpeg -y -v error -i " (sh-quote path) " -vn -ac 1 -ar 16000 -c:a pcm_s16le " (sh-quote wav)
                   " && " (sh-quote (expand-file-name video-transcript-whisper))
                   " -m " (sh-quote (expand-file-name video-transcript-model))
                   " -f " (sh-quote wav) " -ml 1 -sow -oj -np -of " (sh-quote (video-transcript--json path))
                   " > /dev/null 2>&1; ffmpeg -nostats -v info -i " (sh-quote wav) " -af silencedetect=noise=-32dB:d=0.25 -f null - 2>&1"
                   " | awk '/silence_start/ {s=$NF} /silence_end/ {print s, $5}' > " (sh-quote (video-transcript--silence-file path))
                   "; rm -f " (sh-quote wav) "; echo OK")))

;; ---- the page of words

(define (video-transcript--name edit) (string-append "*transcript " (file-name-nondirectory (or (buffer-path edit) edit)) "*"))

(define (video-transcript--lines words)
  "WORDS cut into lines a reader can scan: a line ends at . ? !, at a pause over 0.7 s, at a comma after 12 words, or at 22 words"
  (let loop ((ws words) (line '()) (n 0) (acc '()))
    (if (null? ws)
        (reverse (if (pair? line) (cons (reverse line) acc) acc))
        (let* ((w (car ws))
               (last (and (pair? line) (car line)))
               (brk? (and last (or (re-match "[.?!]$" (caddr last))
                                   (> (- (car w) (cadr last)) 0.7)
                                   (and (>= n 12) (re-match ",$" (caddr last)))
                                   (>= n 22)))))
          (if brk?
              (loop (cdr ws) (list w) 1 (cons (reverse line) acc))
              (loop (cdr ws) (cons w line) (+ n 1) acc))))))

(define (video-transcript--bytes s) (length (string-bytes s)))

(define (video-transcript--rows edit path words)
  "WORDS as rows: each hidden clip's words make one row of their own, (CLIP WORDS); the words between are cut into lines, (#f WORDS)"
  (let* ((s (let loop ((ss (video-edit-structure edit))) (cond ((null? ss) #f) ((equal? (car (car ss)) path) (car ss)) (else (loop (cdr ss))))))
         (hidden (if s (filter (lambda (c) (equal? (caddr c) 'hidden)) (cadr s)) '()))
         (clip-of (lambda (w) (let ((m (/ (+ (car w) (cadr w)) 2)))
                                (let loop ((cs hidden)) (cond ((null? cs) #f) ((and (>= m (car (car cs))) (< m (cadr (car cs)))) (car cs)) (else (loop (cdr cs)))))))))
    (let loop ((ws words) (run '()) (clip #f) (acc '()))
      (let ((flush (lambda () (if (null? run) acc
                                  (if clip (cons (list clip (reverse run)) acc)
                                      (append (reverse (map (lambda (l) (list #f l)) (video-transcript--lines (reverse run)))) acc))))))
        (if (null? ws) (reverse (flush))
            (let ((c (clip-of (car ws))))
              (if (equal? c clip)
                  (loop (cdr ws) (cons (car ws) run) clip acc)
                  (loop (cdr ws) (list (car ws)) c (flush)))))))))

(define (video-transcript--render! edit)
  "draw EDIT's transcript, keeping where each word sits; answers the buffer"
  (let* ((name (video-transcript--name edit))
         (st (video-edit-structure edit))
         (text "") (pos 0) (map-acc '()) (times '()))
    (buffer-create name)
    (when (and (buffer-group edit) (not (equal? (buffer-group name) (buffer-group edit)))) (buffer-move-to-group! name (buffer-group edit)))
    (for-each
      (lambda (s)
        (let* ((path (car s)) (words (video-transcript-words path))
               (head (string-append "== " (file-name-nondirectory path) " ==\n")))
          (set! text (string-append text head)) (set! pos (+ pos (video-transcript--bytes head)))
          (if (not words)
              (let ((l "(no transcript yet: C-c C-t in the edit writes it)\n\n"))
                (set! text (string-append text l)) (set! pos (+ pos (video-transcript--bytes l))))
              (begin
                (for-each
                  (lambda (row)
                    (when (pair? (cadr row))
                      (let* ((line (cadr row)) (clip (car row))
                             (stamp (if clip
                                        (string-append "    ✂ " (or (cadddr clip) "hidden") " · " (video-edit-format-time (- (cadr clip) (car clip))) "  ")
                                        (string-append "[" (video-edit-format-time (car (car line))) "] "))))
                        (set! times (cons (list pos (+ pos (video-transcript--bytes stamp))) times))
                        (set! text (string-append text stamp)) (set! pos (+ pos (video-transcript--bytes stamp)))
                        (for-each
                          (lambda (w)
                            (let ((wt (string-append (caddr w) " ")))
                              (set! map-acc (cons (list pos (+ pos (video-transcript--bytes (caddr w))) (car w) (cadr w) path) map-acc))
                              (set! text (string-append text wt)) (set! pos (+ pos (video-transcript--bytes wt)))))
                          line)
                        (set! text (string-append text "\n")) (set! pos (+ pos 1)))))
                  (video-transcript--rows edit path words))
                (set! text (string-append text "\n")) (set! pos (+ pos 1))))))
      st)
    (buffer-set-local! name 'video-transcript-edit edit)
    (buffer-set-local! name 'footer-line-blocks
      (list (component 'ui/keys-bar (list 'main '(("C-SPC" "mark") ("DEL" "remove marked") ("k" "cut here") ("RET" "playhead here") ("t" "flip") ("R" "name") ("d" "unclip") ("C-c C-l" "timeline") ("C-c C-e" "export"))))))
    (buffer-set-local! name 'video-transcript-map (reverse map-acc))
    (buffer-set-local! name 'video-transcript-times (reverse times))
    (unless (equal? (buffer-local-value 'mode-name name) "video-transcript-mode")
      (with-current-buffer name (lambda () (set-mode! "video-transcript-mode"))))
    (with-current-buffer name
      (lambda ()
        (let ((pt (point)))
          (buffer-set-read-only! name #f)
          (buffer-delete-range! name 0 (buffer-size name))
          (buffer-insert! name 0 text)
          (buffer-mark-saved! name)
          (buffer-set-read-only! name #t)
          (goto-char! (min pt (buffer-size name))))))
    (video-transcript--paint! name)
    name))

(define (video-transcript--paint! name)
  "colour each clip's words: hidden struck down, shown lit"
  (let* ((edit (buffer-local-value 'video-transcript-edit name))
         (words (buffer-local-value 'video-transcript-map name))
         (clips (apply append (map (lambda (s) (map (lambda (c) (cons (car s) c)) (cadr s))) (video-edit-structure edit))))
         (ranges
           (apply append
             (map (lambda (c)
                    (let* ((path (car c)) (a (cadr c)) (b (caddr c)) (state (cadddr c))
                           (in (filter (lambda (w) (and (equal? (list-ref w 4) path) (< (caddr w) b) (> (cadddr w) a))) words)))
                      (if (null? in) '()
                          (list (list (car (car in)) (cadr (car (reverse in)))
                                      (if (equal? state 'shown) 'video-transcript-shown 'video-transcript-hidden))))))
                  clips))))
    (overlay-set! name 'video-transcript
      (append ranges (map (lambda (t) (list (car t) (cadr t) 'video-transcript-time)) (or (buffer-local-value 'video-transcript-times name) '()))))))

(define (video-transcript--word-at name pos before?)
  "the word at byte POS, else the next word (or, BEFORE?, the one before)"
  (let ((ws (buffer-local-value 'video-transcript-map name)))
    (if before?
        (let loop ((ws ws) (last #f)) (cond ((null? ws) last) ((> (car (car ws)) pos) last) (else (loop (cdr ws) (car ws)))))
        (let loop ((ws ws)) (cond ((null? ws) #f) ((>= (cadr (car ws)) pos) (car ws)) (else (loop (cdr ws))))))))

(define (video-transcript--clip-at name)
  "the clip of the edit around the word at point"
  (let* ((edit (buffer-local-value 'video-transcript-edit name))
         (w (video-transcript--word-at name (point) #f)))
    (and w
         (let loop ((ss (video-edit-structure edit)))
           (cond ((null? ss) #f)
                 ((equal? (car (car ss)) (list-ref w 4))
                  (let find ((cs (cadr (car ss))))
                    (cond ((null? cs) (loop (cdr ss)))
                          ((and (< (car (car cs)) (cadddr w)) (> (cadr (car cs)) (caddr w))) (car cs))
                          (else (find (cdr cs))))))
                 (else (loop (cdr ss))))))))

(effects! '(write display))

(define (video-transcript--changed! name)
  (let ((edit (buffer-local-value 'video-transcript-edit name)))
    (video-transcript--paint! name)
    (when (buffer-known? (video-edit--page-name edit)) (video-edit--page! edit))
    (video-edit--timeline-push! edit)))

(define (video-transcript--imenu-rows buf)
  "the transcript's index: each video, each line by its time, each hidden row; a row also moves the timeline's playhead"
  (let ((edit (buffer-local-value 'video-transcript-edit buf)))
    (let loop ((ls (string-split (buffer-text buf) "\n")) (n 1) (i -1) (acc '()))
      (if (null? ls) (reverse acc)
          (let* ((l (car ls)) (go (lambda (t) (video-edit--seek-thunk edit i t))))
            (cond ((string-prefix? "== " l) (loop (cdr ls) (+ n 1) (+ i 1) (cons (list n "video" (string-trim (substring l 3 (string-length l))) "" (video-edit--seek-thunk edit (+ i 1) 0)) acc)))
                  ((string-prefix? "[" l)
                   (let* ((close (string-search "]" l)) (t (and close (video-edit-parse-time (substring l 1 close)))))
                     (loop (cdr ls) (+ n 1) i (cons (list n "line" (string-trim (substring l 0 (min (string-length l) 70))) "" (and t (go t))) acc))))
                  ((string-prefix? "    ✂" l) (loop (cdr ls) (+ n 1) i (cons (list n "hidden" (string-trim l) "" #f) acc)))
                  (else (loop (cdr ls) (+ n 1) i acc))))))))

(define (video-transcript-mode-setup)
  (buffer-set-local! (current-buffer) 'imenu-index-function 'video-transcript--imenu-rows))
(define-mode "video-transcript-mode" video-transcript-mode-setup)

(define-command "video-transcript-clip" "Clip the marked words: they leave the video"
  (lambda ()
    (let* ((name (current-buffer)) (edit (buffer-local-value 'video-transcript-edit name))
           (a (video-transcript--word-at name (region-beginning) #f))
           (b (video-transcript--word-at name (max 0 (- (region-end) 1)) #t)))
      (if (not (and a b (equal? (list-ref a 4) (list-ref b 4)) (< (caddr a) (cadddr b))))
          (message "Mark words of one source first: C-SPC, then move")
          (begin
            (video-edit-add-clip! edit (list-ref a 4) (caddr a) (cadddr b) 'hidden #f)
            (video-transcript--changed! name)
            (message (string-append "Clipped " (video-edit-format-time (caddr a)) " to " (video-edit-format-time (cadddr b)) ": hidden"))))))
  'modes '(video-transcript-mode))

(define-command "video-transcript-toggle" "Turn the clip at point between hidden and shown"
  (lambda ()
    (let* ((name (current-buffer)) (edit (buffer-local-value 'video-transcript-edit name)) (c (video-transcript--clip-at name)))
      (if (not c) (message "No clip here")
          (let ((next (if (equal? (caddr c) 'hidden) 'shown 'hidden)))
            (video-edit-set-clip! edit c next (cadddr c))
            (video-transcript--changed! name)
            (message (string-append "Clip " (symbol->string next)))))))
  'modes '(video-transcript-mode))

(define-command "video-transcript-rename" "Name the clip at point"
  (lambda ()
    (let* ((name (current-buffer)) (edit (buffer-local-value 'video-transcript-edit name)) (c (video-transcript--clip-at name)))
      (if (not c) (message "No clip here")
          (read-string "Clip name: "
            (lambda (s) (video-edit-set-clip! edit c (caddr c) (string-trim s)) (video-transcript--changed! name))))))
  'modes '(video-transcript-mode))

(define-command "video-transcript-unclip" "Remove the clip at point: its words stay in the video"
  (lambda ()
    (let* ((name (current-buffer)) (edit (buffer-local-value 'video-transcript-edit name)) (c (video-transcript--clip-at name)))
      (if (not c) (message "No clip here")
          (begin (video-edit-set-clip! edit c #f #f) (video-transcript--changed! name) (message "Clip removed")))))
  'modes '(video-transcript-mode))

(define-command "video-transcript-cut" "Cut the video just before the word at point"
  (lambda ()
    (let* ((name (current-buffer)) (edit (buffer-local-value 'video-transcript-edit name))
           (w (video-transcript--word-at name (point) #f)))
      (if (not w) (message "No word here")
          (begin
            (video-edit-add-cut! edit (list-ref w 4) (max 0 (- (caddr w) 0.02)))
            (video-transcript--changed! name)
            (message (string-append "Cut before “" (car (last-pair (list (substring (buffer-text name) (car w) (cadr w))))) "”"))))))
  'modes '(video-transcript-mode))

(define-command "video-transcript-delete" "Remove the marked words from the video, or step back a character when nothing is marked"
  (lambda ()
    (if (and (mark) (not (= (mark) (point))))
        (run-command "video-transcript-clip")
        (run-command "backward-char")))
  'modes '(video-transcript-mode))

(define-command "video-transcript-goto" "Move the timeline's playhead to the word at point"
  (lambda ()
    (let* ((name (current-buffer)) (edit (buffer-local-value 'video-transcript-edit name))
           (w (video-transcript--word-at name (point) #f))
           (st (video-edit-structure edit))
           (i (let loop ((ss st) (i 0)) (cond ((null? ss) 0) ((equal? (car (car ss)) (and w (list-ref w 4))) i) (else (loop (cdr ss) (+ i 1))))))
           (tl (video-edit--timeline-name edit)))
      (cond ((not w) (message "No word here"))
            ((not (buffer-known? tl)) (message "Open the timeline first: C-c C-l"))
            (else (app-post! tl (list 'seek (list 'src i 't (caddr w))))
                  (message (string-append "Playhead at " (video-edit-format-time (caddr w))))))))
  'modes '(video-transcript-mode))

(define-command "video-transcript-refresh" "Draw the transcript again from the edit"
  (lambda () (video-transcript--render! (buffer-local-value 'video-transcript-edit (current-buffer))))
  'modes '(video-transcript-mode))

(define (video-transcript-open! edit)
  "(video-transcript-open! EDIT) -- write the transcripts EDIT's sources lack, in a task, and show the transcript in the other window"
  (let ((todo (filter (lambda (s) (not (video-transcript-words (car s)))) (video-edit-structure edit))))
    (display-buffer-other-window! (video-transcript--render! edit))
    (unless (null? todo) (message "Writing the transcript…"))
    (let loop ((ss todo))
      (unless (null? ss)
        (shell-command->string (video-transcript--command (car (car ss))) "/tmp"
          (lambda (o) (video-transcript--render! edit) (loop (cdr ss))))))))

(define-command "video-edit-transcript" "Show the edit's transcript, writing it first when it is missing"
  (lambda ()
    (let ((edit (video-edit--edit-buffer)))
      (if (not (video-edit-clips? edit)) (message "This edit lists pieces; a transcript needs source lines")
          (video-transcript-open! edit))))
  'modes '(video-edit-mode video-edit-page-mode))

(mode-keys! "video-transcript-mode"
  '(("c" "video-transcript-clip")
    ("k" "video-transcript-cut")
    ("DEL" "video-transcript-delete")
    ("<backspace>" "video-transcript-delete")
    ("RET" "video-transcript-goto")
    ("C-c C-l" "video-edit-timeline")
    ("t" "video-transcript-toggle")
    ("R" "video-transcript-rename")
    ("d" "video-transcript-unclip")
    ("g" "video-transcript-refresh")
    ("C-c C-v" "video-edit-show-page")
    ("C-c C-r" "video-edit-preview")
    ("C-c C-e" "video-edit-export")))

(mode-keys! "video-edit-mode" '(("C-c C-t" "video-edit-transcript")))
(mode-keys! "video-edit-page-mode" '(("T" "video-edit-transcript")))

(mode-doc! "video-transcript-mode"
  "An edit's words, a sentence a line, each at its time. Mark words with C-SPC and move, then `DEL` or `c` clips them: a hidden clip leaves the video and shows struck in red, a shown one stays and shows in blue. `k` cuts the video before the word at point and `RET` puts the timeline's playhead on it. `t` turns the clip at point between hidden and shown, `R` names it, `d` removes it. `g` draws again. `C-c C-v` the page, `C-c C-r` the preview, `C-c C-e` the export.")

(effects! '(read))
(public! 'video-transcript-words "(video-transcript-words PATH) — every word whisper heard in PATH, each (START END TEXT), or #f before the transcript exists")
(catalog-meta! 'function "video-transcript-words" 'domain 'files 'effects '(read))
(effects! '(write display execute))
(public! 'video-transcript-open! "(video-transcript-open! EDIT) — write the transcripts EDIT's sources lack and show the transcript in the other window")
(catalog-meta! 'function "video-transcript-open!" 'domain 'files 'effects '(write display execute))

(provide 'video-transcript)
