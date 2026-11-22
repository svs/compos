;;; video-edit.scm --- cut screen recordings as a list of pieces.
;;;
;;; An edit is a text file, NAME.vedit: one line per piece you keep, START
;;; END FILE, played in order. Delete a line to drop a piece, move it to
;;; reorder, change a time to trim. Two lines set the whole edit: `audio
;;; clean` or `audio raw`, and `size 2160`, `1080` or `720`. ffmpeg does
;;; the work in a task: it finds the pauses, draws a filmstrip and a
;;; waveform per piece, and writes the finished mp4.

(require 'audio-edit)

(domain! 'files)
(effects! '(pure))

(defgroup 'video-edit "Cutting recordings into one video.")

(defcustom 'video-edit-pause-seconds 1.0
  "The shortest pause pause removal cuts, in seconds."
  'group 'video-edit 'type 'number)

(defcustom 'video-edit-pause-padding 0.15
  "How much of a pause stays on each side of a cut, in seconds."
  'group 'video-edit 'type 'number)

(defcustom 'video-edit-export-directory "~/Movies"
  "Where video-edit-export writes the finished video."
  'group 'video-edit 'type 'string)

;; ---- times

(define (video-edit-parse-time s)
  "(video-edit-parse-time S) -- seconds for \"1:23.5\", \"0:01:23\" or \"83.5\", else #f"
  (let ((parts (string-split s ":")))
    (and (pair? parts)
         (let loop ((ps parts) (acc 0))
           (if (null? ps) acc
               (let ((n (string->number (car ps))))
                 (and n (loop (cdr ps) (+ (* acc 60) n)))))))))

(define (video-edit-format-time secs)
  "(video-edit-format-time SECS) -- SECS as m:ss.s"
  (let* ((tenths (inexact->exact (round (* secs 10))))
         (m (quotient tenths 600))
         (rest (remainder tenths 600))
         (s (quotient rest 10))
         (t (remainder rest 10)))
    (string-append (number->string m) ":" (if (< s 10) "0" "") (number->string s) "." (number->string t))))

;; ---- the edit as data

(define (video-edit--piece line)
  "(START END PATH) for a piece line, else #f"
  (let* ((t (string-trim line))
         (words (string-split t " ")))
    (and (>= (length words) 3)
         (not (string-prefix? "#" t))
         (let ((a (video-edit-parse-time (car words)))
               (b (video-edit-parse-time (cadr words))))
           (and a b (> b a)
                (let* ((rest (substring t (+ (string-length (car words)) (string-length (cadr words)) 2) (string-length t)))
                       (hash (string-search " # " rest))
                       (path (string-trim (if hash (substring rest 0 hash) rest)))
                       (label (and hash (string-trim (substring rest (+ hash 3) (string-length rest))))))
                  (list a b (expand-file-name path) (and label (not (equal? label "")) label))))))))

;; An edit names its videos with `source PATH` lines and the stretches of
;; them it marks with `clip START END hidden|shown # NAME` lines below each
;; source. The video is every source, whole, minus its hidden clips. An edit
;; with no source line lists its pieces instead, START END PATH.

(define (video-edit-format-time-fine secs)
  "(video-edit-format-time-fine SECS) -- SECS as m:ss.cc, the precision a clip keeps"
  (let* ((cs (inexact->exact (round (* secs 100))))
         (m (quotient cs 6000)) (rest (remainder cs 6000))
         (s (quotient rest 100)) (c (remainder rest 100)))
    (string-append (number->string m) ":" (if (< s 10) "0" "") (number->string s) "." (if (< c 10) "0" "") (number->string c))))

(define (video-edit--source line)
  (let ((t (string-trim line)))
    (and (string-prefix? "source " t) (expand-file-name (string-trim (substring t 7 (string-length t)))))))

(define (video-edit--clip line)
  "(START END STATE NAME) for a clip line, else #f"
  (let* ((t (string-trim line))
         (hash (string-search " # " t))
         (head (if hash (substring t 0 hash) t))
         (name (and hash (string-trim (substring t (+ hash 3) (string-length t)))))
         (w (filter (lambda (x) (not (equal? x ""))) (string-split head " "))))
    (and (>= (length w) 3) (equal? (car w) "clip")
         (let ((a (video-edit-parse-time (cadr w))) (b (video-edit-parse-time (caddr w))))
           (and a b (> b a)
                (list a b (if (and (> (length w) 3) (equal? (cadddr w) "shown")) 'shown 'hidden)
                      (and name (not (equal? name "")) name)))))))

(define (video-edit-structure buf)
  "(video-edit-structure BUF) -- each source of BUF with what is under it: ((PATH CLIPS CUTS DUBS) ...). CUTS are times. CLIPS are the hidden segments, worked out from the cuts: a cut marked hidden hides its segment, to the next cut or the end; each is (START END hidden NAME LINE TEXT), LINE and TEXT the cut's own. A dub is (START END FILE LINE TEXT)."
  (let loop ((ls (string-split (buffer-text buf) "\n")) (n 1) (acc '()))
    (if (null? ls)
        (reverse (map video-edit--finish-source acc))
        (let ((src (video-edit--source (car ls))) (clip (video-edit--clip (car ls)))
              (cut (video-edit--cut-info (car ls))) (dub (video-edit--dub (car ls))))
          (cond (src (loop (cdr ls) (+ n 1) (cons (list src '() '() '()) acc)))
                ((and (pair? acc) (or clip cut dub))
                 (let ((s (car acc)))
                   (loop (cdr ls) (+ n 1)
                         (cons (list (car s)
                                     (if clip (cons (append clip (list n (car ls))) (cadr s)) (cadr s))
                                     (if cut (cons (append cut (list n (car ls))) (caddr s)) (caddr s))
                                     (if dub (cons (append dub (list n (car ls))) (cadddr s)) (cadddr s)))
                               (cdr acc)))))
                (else (loop (cdr ls) (+ n 1) acc)))))))

(define (video-edit--finish-source s)
  "a source as read, (PATH CLIP-LINES CUT-INFOS DUBS), made into (PATH CLIPS CUTS DUBS)"
  (let* ((path (car s))
         (cuts (sort (map (lambda (c) (list (car c) (if (cadr c) 1 0) (caddr c) (cadddr c) (list-ref c 4))) (caddr s))))
         (d (or (video-edit--dur path) 0))
         (hidden (let walk ((cs cuts) (acc '()))
                   (if (null? cs) (reverse acc)
                       (let* ((c (car cs)) (b (if (pair? (cdr cs)) (car (cadr cs)) d)))
                         (walk (cdr cs)
                               (if (and (= (cadr c) 1) (> b (+ (car c) 0.01)))
                                   (cons (list (car c) b 'hidden (caddr c) (cadddr c) (list-ref c 4)) acc)
                                   acc)))))))
    (list path (append hidden (reverse (cadr s))) (map car cuts) (reverse (cadddr s))
          ;; the muted segments, (START END): a cut marked muted silences its segment
          (let walk ((cs cuts) (acc '()))
            (if (null? cs) (reverse acc)
                (let* ((c (car cs)) (b (if (pair? (cdr cs)) (car (cadr cs)) d)))
                  (walk (cdr cs) (if (and (video-edit--cut-muted? (list-ref c 4)) (> b (+ (car c) 0.01))) (cons (list (car c) b) acc) acc))))))))

(define (video-edit--dub line)
  "(START END FILE) for a `dub START END FILE` line: a take recorded over the source, else #f"
  (let* ((t (string-trim line)) (w (string-split t " ")))
    (and (>= (length w) 4) (equal? (car w) "dub")
         (let ((a (video-edit-parse-time (cadr w))) (b (video-edit-parse-time (caddr w))))
           (and a b (> b a)
                (list a b (expand-file-name (string-trim (substring t (+ 4 (string-length (cadr w)) 1 (string-length (caddr w)) 1) (string-length t))))))))))

(define (video-edit--cut-info line)
  "(TIME HIDDEN? NAME) for a `cut TIME [hidden] [# NAME]` line, else #f: the cut and the state of the segment it starts"
  (let* ((t (string-trim line))
         (hash (string-search " # " t))
         (head (if hash (substring t 0 hash) t))
         (name (and hash (string-trim (substring t (+ hash 3) (string-length t)))))
         (w (filter (lambda (x) (not (equal? x ""))) (string-split head " "))))
    (and (>= (length w) 2) (equal? (car w) "cut")
         (let ((tm (video-edit-parse-time (cadr w))))
           (and tm (list tm (and (> (length w) 2) (equal? (caddr w) "hidden")) (and name (not (equal? name "")) name)))))))

(define (video-edit--cut line)
  "the time of a cut line, else #f"
  (let ((i (video-edit--cut-info line))) (and i (car i))))

(define (video-edit--cut-muted? line)
  "does the cut LINE mute its segment?"
  (let* ((t (string-trim line)) (hash (string-search " # " t)) (head (if hash (substring t 0 hash) t)))
    (and (video-edit--cut-info line) (member "muted" (string-split head " ")) #t)))

(define (video-edit--cut-text t hidden name &optional muted)
  (string-append "cut " (video-edit-format-time-fine t) (if hidden " hidden" "") (if muted " muted" "")
                 (if (and (string? name) (not (equal? name ""))) (string-append " # " name) "")))

(define (video-edit--split spans cuts)
  "SPANS cut at each of CUTS that falls inside one"
  (apply append
    (map (lambda (sp)
           (let loop ((cs (filter (lambda (c) (and (> c (+ (car sp) 0.05)) (< c (- (cadr sp) 0.05)))) cuts)) (from (car sp)) (acc '()))
             (if (null? cs) (reverse (cons (list from (cadr sp)) acc))
                 (loop (cdr cs) (car cs) (cons (list from (car cs)) acc)))))
         spans)))

(define video-edit--durations '())
(define (video-edit--dur path)
  (let ((hit (assoc path video-edit--durations)))
    (if hit (cdr hit)
        (let ((d (video-edit--duration path)))
          (when d (set! video-edit--durations (cons (cons path d) video-edit--durations)))
          d))))

(define (video-edit--minus a b cuts)
  "the spans of A..B outside the (START END) CUTS"
  (let loop ((cs (sort (map (lambda (c) (list (car c) (cadr c))) cuts))) (from a) (acc '()))
    (cond ((null? cs) (reverse (if (> (- b from) 0.05) (cons (list from b) acc) acc)))
          ((<= (cadr (car cs)) from) (loop (cdr cs) from acc))
          (else (loop (cdr cs) (max from (cadr (car cs)))
                      (if (> (- (car (car cs)) from) 0.05) (cons (list from (car (car cs))) acc) acc))))))

(define (video-edit-pieces buf)
  "(video-edit-pieces BUF) -- the edit's pieces in order, each (START END PATH NAME)"
  (let ((st (video-edit-structure buf)))
    (if (null? st)
        (filter pair? (map video-edit--piece (string-split (buffer-text buf) "\n")))
        (apply append
          (map (lambda (s)
                 (let ((d (video-edit--dur (car s)))
                       (hidden (filter (lambda (c) (equal? (caddr c) 'hidden)) (cadr s))))
                   (if (not d) '()
                       (map (lambda (span) (list (car span) (cadr span) (car s) #f)) (video-edit--split (video-edit--minus 0 d hidden) (caddr s))))))
               st)))))

(define (video-edit-clips? buf) (pair? (video-edit-structure buf)))

;; ---- undo is the edit buffer's own: every change below lands as one undo
;; group, so C-/ in the file and undo in the timeline, the page and the
;; transcript all take back the same steps.
(define (video-edit--one-step buf thunk)
  "run THUNK with BUF's changes as one undo step; a step inside a step joins it"
  (let ((depth (or (buffer-local-value 'video-edit-step-depth buf) 0)))
    (buffer-set-local! buf 'video-edit-step-depth (+ depth 1))
    (when (= depth 0) (undo-group! buf #t))
    (let ((r (ignore-errors thunk)))
      (buffer-set-local! buf 'video-edit-step-depth depth)
      (when (= depth 0) (undo-group! buf #f))
      r)))

(define (video-edit--refresh-views! buf)
  (video-edit--timeline-push! buf)
  (when (buffer-known? (video-edit--page-name buf)) (video-edit--page! buf))
  (when (and (boundp 'video-transcript--name) (buffer-known? (video-transcript--name buf))) (video-transcript--render! buf)))

(define (video-edit-undo! buf)
  "(video-edit-undo! BUF) -- the edit buffer's undo, then every view of it redrawn; #f when nothing is left"
  (let ((r (with-current-buffer buf (lambda () (undo!)))))
    (video-edit--refresh-views! buf)
    r))

(define (video-edit-redo! buf)
  "(video-edit-redo! BUF) -- the edit buffer's redo, then every view of it redrawn; #f when nothing waits"
  (let ((r (with-current-buffer buf (lambda () (redo!)))))
    (video-edit--refresh-views! buf)
    r))

(define (video-edit-add-clip! buf path a b state name)
  "(video-edit-add-clip! BUF PATH A B STATE NAME) -- hide A..B of the source PATH: cut it at A and B and mark the segments between hidden; NAME goes on the cut at A. A shown mark is a cut with a name."
  (if (equal? state 'hidden)
      (video-edit--set-hidden! buf path a b #t name)
      (begin (video-edit--ensure-cut! buf path a)
             (when (and (string? name) (not (equal? name "")))
               (let ((c (let find ((cs (video-edit--cut-lines buf path))) (cond ((null? cs) #f) ((< (abs (- (car (car cs)) a)) 0.02) (car cs)) (else (find (cdr cs)))))))
                 (when c (video-edit--set-line-text! buf (cadddr c) (list-ref c 4) (video-edit--cut-text (car c) (cadr c) name (video-edit--cut-muted? (list-ref c 4))))))))))

(define (video-edit--cut-lines buf path)
  "PATH's cut lines in BUF, by time: (TIME HIDDEN? NAME LINE TEXT)"
  (let loop ((ls (string-split (buffer-text buf) "\n")) (n 1) (here #f) (acc '()))
    (if (null? ls) (sort acc)
        (let ((s (video-edit--source (car ls))) (c (video-edit--cut-info (car ls))))
          (cond (s (loop (cdr ls) (+ n 1) (equal? s path) acc))
                ((and here c) (loop (cdr ls) (+ n 1) here (cons (list (car c) (cadr c) (caddr c) n (car ls)) acc)))
                (else (loop (cdr ls) (+ n 1) here acc)))))))

(define (video-edit--set-line-text! buf line old new)
  (with-current-buffer buf
    (lambda ()
      (let ((start (line-start-position line)))
        (buffer-delete-range! buf start (length (string-bytes old)))
        (buffer-insert! buf start new)))))

(define (video-edit--hidden-at? buf path t)
  "is the segment of PATH that holds T hidden?"
  (let loop ((cs (video-edit--cut-lines buf path)) (h #f))
    (cond ((null? cs) h)
          ((<= (car (car cs)) (+ t 0.001)) (loop (cdr cs) (cadr (car cs))))
          (else h))))

(define (video-edit--muted-at? buf path t)
  "is the segment of PATH that holds T muted?"
  (let loop ((cs (video-edit--cut-lines buf path)) (m #f))
    (cond ((null? cs) m)
          ((<= (car (car cs)) (+ t 0.001)) (loop (cdr cs) (video-edit--cut-muted? (list-ref (car cs) 4))))
          (else m))))

(define (video-edit-toggle-muted! buf path a b)
  "(video-edit-toggle-muted! BUF PATH A B) -- A..B of PATH all muted: give it its sound back; else mute it. Answers #t when it muted."
  (let* ((d (or (video-edit--dur path) b))
         (inside (lambda () (filter (lambda (c) (and (>= (car c) (- a 0.02)) (< (car c) (- b 0.02)))) (video-edit--cut-lines buf path))))
         (all-muted (and (video-edit--muted-at? buf path (+ a 0.01)) (let all ((xs (inside))) (or (null? xs) (and (video-edit--cut-muted? (list-ref (car xs) 4)) (all (cdr xs))))))))
    (video-edit--ensure-cut! buf path (max 0 a))
    (when (< b (- d 0.02)) (video-edit--ensure-cut! buf path b))
    (for-each (lambda (c) (video-edit--set-line-text! buf (cadddr c) (list-ref c 4) (video-edit--cut-text (car c) (cadr c) (caddr c) (not all-muted))))
              (reverse (inside)))
    (not all-muted)))

(define (video-edit-add-cut! buf path t)
  "(video-edit-add-cut! BUF PATH T) -- cut the source PATH at T: the segment there becomes two, both as it was"
  (let ((hidden (video-edit--hidden-at? buf path t)) (muted (video-edit--muted-at? buf path t)))
    (let loop ((ls (string-split (buffer-text buf) "\n")) (n 1))
      (cond ((null? ls) #f)
            ((equal? (video-edit--source (car ls)) path)
             (with-current-buffer buf
               (lambda ()
                 (let ((pos (line-start-position (+ n 1))))
                   (buffer-insert! buf (if (> pos 0) pos (buffer-size buf)) (string-append (video-edit--cut-text t hidden #f muted) "\n")))))
             #t)
            (else (loop (cdr ls) (+ n 1)))))))

(define (video-edit--ensure-cut! buf path t)
  (unless (let find ((cs (video-edit--cut-lines buf path))) (and (pair? cs) (or (< (abs (- (car (car cs)) t)) 0.02) (find (cdr cs)))))
    (video-edit-add-cut! buf path t)))

(define (video-edit--set-hidden! buf path a b hidden name)
  "cut PATH at A and B and set every segment between them hidden or not; NAME goes on the cut at A"
  (let ((d (or (video-edit--dur path) b)))
    (when (or hidden (> a 0.02)) (video-edit--ensure-cut! buf path (max 0 a)))
    (when (< b (- d 0.02)) (video-edit--ensure-cut! buf path b))
    (for-each
      (lambda (c)
        (when (and (>= (car c) (- a 0.02)) (< (car c) (- b 0.02)))
          (let ((nm (if (and name (< (abs (- (car c) a)) 0.02)) name (caddr c))))
            (unless (and (eq? (cadr c) hidden) (equal? nm (caddr c)))
              (video-edit--set-line-text! buf (cadddr c) (list-ref c 4) (video-edit--cut-text (car c) hidden nm (video-edit--cut-muted? (list-ref c 4))))))))
      (reverse (video-edit--cut-lines buf path)))))

(define (video-edit-remove-cut! buf path t)
  "(video-edit-remove-cut! BUF PATH T) -- remove PATH's cut nearest T, within half a second"
  (let loop ((ls (string-split (buffer-text buf) "\n")) (n 1) (here #f))
    (if (null? ls) #f
        (let ((s (video-edit--source (car ls))) (c (video-edit--cut (car ls))))
          (cond (s (loop (cdr ls) (+ n 1) (equal? s path)))
                ((and here c (< (abs (- c t)) 0.5))
                 (with-current-buffer buf
                   (lambda () (let ((start (line-start-position n)) (len (length (string-bytes (car ls)))))
                                (buffer-delete-range! buf start (min (+ len 1) (- (buffer-size buf) start))))))
                 #t)
                (else (loop (cdr ls) (+ n 1) here)))))))

(define (video-edit-add-dub! buf path a b file)
  "(video-edit-add-dub! BUF PATH A B FILE) -- lay the take FILE over A..B of the source PATH, under its source line"
  (let loop ((ls (string-split (buffer-text buf) "\n")) (n 1))
    (cond ((null? ls) #f)
          ((equal? (video-edit--source (car ls)) path)
           (with-current-buffer buf
             (lambda ()
               (let ((pos (line-start-position (+ n 1))))
                 (buffer-insert! buf (if (> pos 0) pos (buffer-size buf))
                   (string-append "dub " (video-edit-format-time-fine a) " " (video-edit-format-time-fine b) " " (abbreviate-file-name file) "\n")))))
           #t)
          (else (loop (cdr ls) (+ n 1))))))

(define (video-edit-remove-dub! buf path a)
  "(video-edit-remove-dub! BUF PATH A) -- take out PATH's take that starts nearest A; the original sound plays there again"
  (let ((s (let loop ((ss (video-edit-structure buf))) (cond ((null? ss) #f) ((equal? (car (car ss)) path) (car ss)) (else (loop (cdr ss)))))))
    (let ((d (and s (let loop ((ds (cadddr s))) (cond ((null? ds) #f) ((< (abs (- (car (car ds)) a)) 0.05) (car ds)) (else (loop (cdr ds))))))))
      (and d
           (with-current-buffer buf
             (lambda () (let ((start (line-start-position (list-ref d 3))) (len (length (string-bytes (list-ref d 4)))))
                          (buffer-delete-range! buf start (min (+ len 1) (- (buffer-size buf) start))) #t)))))))

(define (video-edit--takes-dir buf)
  "where the takes of the edit BUF are kept: a folder beside the edit file"
  (let* ((p (or (buffer-path buf) (expand-file-name "~/Movies/edit.vedit")))
         (name (file-name-nondirectory p)) (dot (string-rindex name ".")))
    (string-append (path-directory p) (if dot (substring name 0 dot) name) " takes/")))

(define (video-edit--take-url buf file)
  "FILE as the timeline asks for it: under the takes folder, beside the edit"
  (let ((dir (video-edit--takes-dir buf)))
    (string-append (file-name-nondirectory (substring dir 0 (- (string-length dir) 1))) "/" (file-name-nondirectory file))))

(define (video-edit--save-take! buf path a data mime)
  "write the recorded take DATA (base64) to the takes folder, make it a wav, and lay it in at A"
  (let* ((dir (video-edit--takes-dir buf))
         (stem (string-append "take " (file-name-nondirectory path) " " (video-edit-format-time-fine a)))
         (stem (list->string (map (lambda (c) (if (member c '(#\/ #\:)) #\- c)) (string->list stem))))
         (raw (string-append (video-edit--cache) "/" stem (if (and (string? mime) (string-contains? mime "mp4")) ".m4a" ".webm")))
         (wav (string-append dir stem ".wav"))
         (tmp (string-append (video-edit--cache) "/" stem ".wav")))
    (write-file! raw (base64-decode data))
    (video-edit--status! buf "Saving the take…")
    (shell-command->string (string-append "ffmpeg -y -v error -i " (sh-quote raw) " -ac 1 -ar 48000 -c:a pcm_s16le " (sh-quote tmp) " && echo OK") "/tmp"
      (lambda (o)
        ;; a browser's recording makes ffmpeg warn before it says OK: OK at the end is what counts
        (let ((d (and (string? o) (string-suffix? "OK" (string-trim o)) (video-edit--duration tmp))))
          (if (not d) (video-edit--status! buf "The take could not be saved")
              (begin
                (write-file! (string-append dir ".keep") "")
                (when (file-exists? wav) (delete-file! wav))
                (rename-file! tmp wav)
                (delete-file! raw)
                (video-edit-add-dub! buf path a (+ a d) wav)
                (video-edit--status! buf (string-append "Take laid in at " (video-edit-format-time a) " · " (video-edit-format-time d)))
                (video-edit--refresh-views! buf)
                (video-edit--transcribe-take! buf wav))))))))

(define (video-edit--transcribe-take! buf wav)
  "(video-edit--transcribe-take! BUF WAV) -- write the transcript of the take WAV in a task; the views show its words when it is ready"
  (when (and (boundp 'video-transcript--command) (file-exists? wav) (not (video-transcript-words wav)))
    (shell-command->string (video-transcript--command wav) "/tmp"
      (lambda (o)
        (video-edit--status! buf "Take transcribed")
        (video-edit--refresh-views! buf)))))

(define (video-edit-move-cut! buf path from to)
  "(video-edit-move-cut! BUF PATH FROM TO) -- move PATH's cut at FROM to TO; its segment's state and name are on its line and go with it"
  (let ((c (let find ((cs (video-edit--cut-lines buf path))) (cond ((null? cs) #f) ((< (abs (- (car (car cs)) from)) 0.02) (car cs)) (else (find (cdr cs)))))))
    (when c (video-edit--set-line-text! buf (cadddr c) (list-ref c 4) (video-edit--cut-text to (cadr c) (caddr c) (video-edit--cut-muted? (list-ref c 4)))))))

(define (video-edit-toggle-hidden! buf path a b)
  "(video-edit-toggle-hidden! BUF PATH A B) -- A..B of PATH all hidden: show it; else hide it. Answers #t when it hid."
  (let* ((cs (video-edit--cut-lines buf path))
         (inside (filter (lambda (c) (and (>= (car c) (- a 0.02)) (< (car c) (- b 0.02)))) cs))
         (all-hidden (and (video-edit--hidden-at? buf path (+ a 0.01)) (let all ((xs inside)) (or (null? xs) (and (cadr (car xs)) (all (cdr xs))))))))
    (video-edit--set-hidden! buf path a b (not all-hidden) #f)
    (not all-hidden)))

(define (video-edit-set-clip! buf clip state name)
  "(video-edit-set-clip! BUF CLIP STATE NAME) -- a hidden segment from video-edit-structure: STATE hidden keeps it hidden, anything else shows it; NAME names its cut"
  (let ((line (list-ref clip 4)) (old (list-ref clip 5)))
    (if (video-edit--cut-info old)
        (video-edit--set-line-text! buf line old (video-edit--cut-text (car clip) (equal? state 'hidden) name (video-edit--cut-muted? old)))
        ;; an old clip line, from before cuts carried their state
        (with-current-buffer buf
          (lambda ()
            (let ((start (line-start-position line)) (len (length (string-bytes old))))
              (buffer-delete-range! buf start (min (+ len 1) (- (buffer-size buf) start)))))))))

(define (video-edit--setting buf key default)
  (let loop ((ls (string-split (buffer-text buf) "\n")))
    (if (null? ls) default
        (let ((w (string-split (string-trim (car ls)) " ")))
          (if (and (= (length w) 2) (equal? (car w) key)) (cadr w) (loop (cdr ls)))))))

(define (video-edit--size buf) (or (string->number (video-edit--setting buf "size" "2160")) 2160))
(define (video-edit--clean? buf) (equal? (video-edit--setting buf "audio" "clean") "clean"))

(define (video-edit--line path a b &optional label)
  (string-append (video-edit-format-time a) " " (video-edit-format-time b) " " (abbreviate-file-name path)
                 (if (and (string? label) (not (equal? label ""))) (string-append " # " label) "")))

(define (video-edit--duration path)
  (let* ((i (ignore-errors (lambda () (media-info path))))
         (fm (and (pair? i) (plist-get i 'format))))
    (and fm (string->number (or (plist-get fm 'duration) "")))))

;; ---- the ffmpeg commands

(define (video-edit--cache) (expand-file-name audio-edit-cache-directory))

(define (video-edit--key path a b)
  (list->string (map (lambda (c) (if (or (char-alphabetic? c) (char-numeric? c)) c #\-))
                     (string->list (string-append path " " (number->string a) " " (number->string b))))))

(define (video-edit--strip-path path a b) (string-append (video-edit--cache) "/strip-" (video-edit--key path a b) ".jpg"))
(define (video-edit--wave-path path a b) (string-append (video-edit--cache) "/vwave-" (video-edit--key path a b) ".png"))
(define (video-edit--wide-wave-path path) (string-append (video-edit--cache) "/vwide-" (video-edit--key path 0 0) ".png"))
(define (video-edit--wide-wave-command path)
  "the waveform of all of PATH, 16000 wide: sharp when the source bar zooms in"
  (string-append "mkdir -p " (sh-quote (video-edit--cache)) " && ffmpeg -y -v error -i " (sh-quote path)
                 " -filter_complex 'aformat=channel_layouts=mono,volume=10dB,showwavespic=s=16000x240:colors=#5b8def:scale=sqrt' -frames:v 1 "
                 (sh-quote (video-edit--wide-wave-path path)) " ; echo OK"))

(define (video-edit--strip-command path a b)
  (let ((d (- b a)))
    (string-append "mkdir -p " (sh-quote (video-edit--cache))
                   " && ffmpeg -y -v error -ss " (number->string a) " -t " (number->string d) " -i " (sh-quote path)
                   " -an -vf " (sh-quote (string-append "fps=" (number->string (/ 8.0 (max d 0.5))) ",scale=240:-2,tile=8x1"))
                   " -frames:v 1 " (sh-quote (video-edit--strip-path path a b))
                   " && ffmpeg -y -v error -ss " (number->string a) " -t " (number->string d) " -i " (sh-quote path)
                   " -filter_complex 'aformat=channel_layouts=mono,showwavespic=s=1920x120:colors=#5b8def' -frames:v 1 "
                   (sh-quote (video-edit--wave-path path a b)) " ; echo OK")))

(define (video-edit--silence-command path a b noise)
  (string-append "ffmpeg -nostats -v info -ss " (number->string a) " -t " (number->string (- b a)) " -i " (sh-quote path)
                 " -vn -af silencedetect=noise=" (number->string noise) "dB:d=" (number->string video-edit-pause-seconds)
                 " -f null - 2>&1"))

(define (video-edit--silences out offset)
  "the (START END) pauses silencedetect printed, in file time"
  (let loop ((ls (string-split (if (string? out) out "") "\n")) (start #f) (acc '()))
    (if (null? ls) (reverse acc)
        (let* ((l (car ls))
               (si (string-search "silence_start: " l))
               (ei (string-search "silence_end: " l)))
          (cond (si (loop (cdr ls) (string->number (string-trim (substring l (+ si 15) (string-length l)))) acc))
                ((and ei start)
                 (let* ((rest (substring l (+ ei 13) (string-length l)))
                        (bar (string-search " " rest))
                        (end (string->number (if bar (substring rest 0 bar) rest))))
                   (loop (cdr ls) #f (if end (cons (list (+ offset start) (+ offset end)) acc) acc))))
                (else (loop (cdr ls) start acc)))))))

(define (video-edit--keep a b silences)
  "the spans of A..B outside SILENCES, each pause kept by the padding at both ends"
  (let ((pad video-edit-pause-padding))
    (let loop ((ss silences) (from a) (acc '()))
      (if (null? ss)
          (reverse (if (> (- b from) 0.3) (cons (list from b) acc) acc))
          (let* ((s (car ss)) (cut-a (+ (car s) pad)) (cut-b (- (cadr s) pad)))
            (if (<= cut-b cut-a) (loop (cdr ss) from acc)
                (loop (cdr ss) cut-b (if (> (- cut-a from) 0.3) (cons (list from cut-a) acc) acc))))))))

(define (video-edit--dubbed-path path dubs)
  (string-append (video-edit--cache) "/dubbed-" (video-edit--key (string-append path (apply string-append (map (lambda (d) (string-append " " (number->string (car d)) (caddr d))) dubs))) 0 0) ".wav"))

(define (video-edit--dubbed-command path out dubs &optional mutes)
  "the ffmpeg command that writes PATH's sound with each take of DUBS laid over its stretch, and silence over each of MUTES"
  (let* ((n (length dubs))
         (quiet (string-join (map (lambda (d) (string-append "between(t," (number->string (car d)) "," (number->string (cadr d)) ")")) (append dubs (or mutes '()))) "+"))
         (graph (string-append
                  "[0:a]aformat=sample_rates=48000:channel_layouts=stereo,volume=0:enable='" quiet "'[base];"
                  (let loop ((ds dubs) (i 1) (acc ""))
                    (if (null? ds) acc
                        (loop (cdr ds) (+ i 1)
                              (string-append acc "[" (number->string i) ":a]aformat=sample_rates=48000:channel_layouts=stereo,adelay="
                                             (number->string (inexact->exact (round (* 1000 (car (car ds)))))) ":all=1[d" (number->string i) "];"))))
                  "[base]" (let loop ((i 1) (acc "")) (if (> i n) acc (loop (+ i 1) (string-append acc "[d" (number->string i) "]"))))
                  "amix=inputs=" (number->string (+ n 1)) ":normalize=0:duration=first[out]")))
    (string-append "ffmpeg -y -v error -i " (sh-quote path)
                   (apply string-append (map (lambda (d) (string-append " -i " (sh-quote (caddr d)))) dubs))
                   " -filter_complex " (sh-quote graph) " -map '[out]' -c:a pcm_s16le " (sh-quote out))))

(define (video-edit-export-command buf out height preview?)
  "(video-edit-export-command BUF OUT HEIGHT PREVIEW?) -- the ffmpeg command that writes BUF's edit to OUT; it prints OK at the end"
  (let* ((pieces (video-edit-pieces buf))
         (files (let loop ((ps pieces) (acc '())) (if (null? ps) (reverse acc) (loop (cdr ps) (if (member (caddr (car ps)) acc) acc (cons (caddr (car ps)) acc))))))
         (index (lambda (f) (let loop ((fs files) (i 0)) (if (equal? (car fs) f) i (loop (cdr fs) (+ i 1))))))
         (n (length pieces))
         ;; a source with takes recorded over it gets its own sound track first:
         ;; its sound, quiet where a take is, with each take laid in at its place
         (dubbed (filter pair?
                   (map (lambda (path)
                          (let ((s (let loop ((ss (video-edit-structure buf))) (cond ((null? ss) #f) ((equal? (car (car ss)) path) (car ss)) (else (loop (cdr ss)))))))
                            (and s (or (pair? (cadddr s)) (pair? (list-ref s 4)))
                                 (list path (video-edit--dubbed-path path (append (cadddr s) (map (lambda (m) (list (car m) (cadr m) "mute")) (list-ref s 4)))) (cadddr s) (list-ref s 4)))))
                        files)))
         (audio-index (lambda (path)
                        (let loop ((ds dubbed) (j 0))
                          (cond ((null? ds) (index path))
                                ((equal? (car (car ds)) path) (+ (length files) j))
                                (else (loop (cdr ds) (+ j 1)))))))
         (H (number->string height))
         (W (number->string (* 2 (quotient (+ (* height 16) 17) 18))))
         (fps (if preview? "30" "60"))
         (graph
           (string-append
             (let loop ((ps pieces) (i 0) (acc ""))
               (if (null? ps) acc
                   (let* ((p (car ps)) (k (number->string (index (caddr p)))) (ka (number->string (audio-index (caddr p))))
                          (a (number->string (car p))) (b (number->string (cadr p))) (s (number->string i)))
                     (loop (cdr ps) (+ i 1)
                           ;; every piece to one picture and one sound, so videos of
                           ;; different sizes, rates and channels join
                           (string-append acc "[" k ":v]trim=start=" a ":end=" b ",setpts=PTS-STARTPTS,"
                                          "scale=" W ":" H ":force_original_aspect_ratio=decrease,pad=" W ":" H ":(ow-iw)/2:(oh-ih)/2,setsar=1,fps=" fps "[v" s "];"
                                          "[" ka ":a]atrim=start=" a ":end=" b ",asetpts=PTS-STARTPTS,aformat=sample_rates=48000:channel_layouts=stereo[a" s "];")))))
             (let loop ((i 0) (acc "")) (if (= i n) acc (loop (+ i 1) (string-append acc "[v" (number->string i) "][a" (number->string i) "]"))))
             "concat=n=" (number->string n) ":v=1:a=1[vc][ac];"
             "[vc]null[v];"
             "[ac]" (if (video-edit--clean? buf) (audio-edit-chain buf) "anull") "[a]"))
         (script (string-append (video-edit--cache) "/graph-" (video-edit--key out 0 n) ".txt"))
         (rate (cond ((>= height 2160) "14M") ((>= height 1080) "6M") (else "2500k"))))
    (write-file! script graph)
    (string-append "mkdir -p " (sh-quote (video-edit--cache))
                   (apply string-append (map (lambda (d) (string-append " && " (video-edit--dubbed-command (car d) (cadr d) (caddr d) (cadddr d)))) dubbed))
                   " && ffmpeg -y -v error"
                   (apply string-append (map (lambda (f) (string-append " -i " (sh-quote f))) files))
                   (apply string-append (map (lambda (d) (string-append " -i " (sh-quote (cadr d)))) dubbed))
                   " -filter_complex_script " (sh-quote script) " -map '[v]' -map '[a]'"
                   " -c:v h264_videotoolbox -b:v " rate " -c:a aac -b:a 192k -movflags +faststart "
                   ;; ffmpeg says only errors (-v error): a failure answers with them
                   (sh-quote out) " 2>&1 && echo OK")))

;; ---- the page

(define (video-edit--page-name buf) (string-append "*video-edit " (file-name-nondirectory (or (buffer-path buf) buf)) "*"))
(define (video-edit--preview-path buf) (string-append (video-edit--cache) "/preview-" (video-edit--key (or (buffer-path buf) buf) 0 0) ".mp4"))
(define (video-edit--out-path buf)
  (let* ((name (file-name-nondirectory (or (buffer-path buf) buf)))
         (dot (string-rindex name ".")))
    (string-append (expand-file-name video-edit-export-directory) "/" (if dot (substring name 0 dot) name) "-edit.mp4")))

(define (video-edit--html buf)
  (let* ((pieces (video-edit-pieces buf))
         (sel (buffer-local-value 'video-edit-selected (video-edit--page-name buf)))
         (total (apply + (map (lambda (p) (- (cadr p) (car p))) pieces)))
         (status (buffer-local-value 'video-edit-status buf))
         (preview (video-edit--preview-path buf))
         (out (video-edit--out-path buf)))
    (string-append
      "<!doctype html><html><head><meta charset=\"utf-8\"><style>"
      "body{font:14px/1.45 system-ui,sans-serif;margin:0;padding:18px 22px;max-width:none!important}"
      "h1{font-size:17px;margin:0 0 2px}.m{opacity:.6;margin-bottom:12px}"
      "video{display:block;width:100%;max-height:50vh;background:#000;border-radius:6px;margin-bottom:14px}"
      ".p{margin:0 0 12px}.h{font-weight:600}.h span{font-weight:400;opacity:.6;margin-left:8px}"
      ".s{display:block;width:100%;border-radius:5px}.w{display:block;width:100%;height:46px;object-fit:fill;opacity:.9}"
      ".x{opacity:.75;margin:8px 0}.p.sel{outline:3px solid #5b8def;outline-offset:4px;border-radius:6px}.keys{opacity:.6;margin-top:14px}"
      "</style></head><body>"
      "<h1>" (html-escape (file-name-nondirectory (or (buffer-path buf) buf))) "</h1>"
      "<div class=\"m\">" (number->string (length pieces)) " segments · " (video-edit-format-time total)
      " · audio " (if (video-edit--clean? buf) "cleaned" "raw") " · export " (number->string (video-edit--size buf)) "p</div>"
      (if (string? status) (string-append "<div class=\"x\">" (html-escape status) "</div>") "")
      (if (file-exists? preview) (string-append "<video controls preload=\"metadata\" src=\"" (html-escape preview) "\"></video>") "")
      (apply string-append
        (let loop ((ps pieces) (i 1) (acc '()))
          (if (null? ps) (reverse acc)
              (let* ((p (car ps)) (a (car p)) (b (cadr p)) (f (caddr p))
                     (strip (video-edit--strip-path f a b)) (wave (video-edit--wave-path f a b)))
                (loop (cdr ps) (+ i 1)
                  (cons (string-append
                          "<div class=\"p" (if (equal? sel i) " sel" "") "\"><div class=\"h\">" (number->string i) ". "
                          (if (cadddr p) (string-append (html-escape (cadddr p)) " · ") "")
                          (video-edit-format-time a) " → " (video-edit-format-time b)
                          "<span>" (video-edit-format-time (- b a)) " · " (html-escape (file-name-nondirectory f)) "</span></div>"
                          (if (file-exists? strip) (string-append "<img class=\"s\" src=\"" (html-escape strip) "\" alt=\"\">") "")
                          (if (file-exists? wave) (string-append "<img class=\"w\" src=\"" (html-escape wave) "\" alt=\"\">") "")
                          "</div>")
                        acc))))))
      (if (file-exists? out) (string-append "<div class=\"m\">Exported: " (html-escape (abbreviate-file-name out)) "</div>") "")
      "</body></html>")))

(defwrite-rule! 'video-edit-page
  "a video-edit page holds a view of an edit, not a file"
  #f
  (lambda (path source)
    (and source (string-prefix? "*video-edit " source))))

(effects! '(write display))

(define (video-edit--page! buf)
  "draw BUF's page, and the filmstrips and waveforms it lacks in a task"
  (let ((page (video-edit--page-name buf)))
    (buffer-create page)
    (buffer-set-local! page 'video-edit-source buf)
    (buffer-set-local! page 'footer-line-blocks
      (list (component 'ui/keys-bar (list 'main '(("n p" "select") ("R" "name") ("d" "delete") ("r" "preview") ("e" "export") ("L" "timeline") ("T" "transcript") ("g" "redraw"))))))
    (unless (equal? (buffer-local-value 'mode-name page) "video-edit-page-mode")
      (with-current-buffer page (lambda () (set-mode! "video-edit-page-mode"))))
    (when (and (buffer-group buf) (not (equal? (buffer-group page) (buffer-group buf)))) (buffer-move-to-group! page (buffer-group buf)))
    (buffer-set-local! page 'preview-renderer "html")
    (buffer-set-local! page 'preview-authored #t)
    (buffer-set-local! page 'render-mode "html")
    (buffer-set-read-only! page #f)
    (buffer-delete-range! page 0 (buffer-size page))
    (buffer-append! page (video-edit--html buf))
    (buffer-mark-saved! page)
    (buffer-set-read-only! page #t)
    page))

(define (video-edit--draw-missing! buf)
  (let ((todo (filter (lambda (p) (not (file-exists? (video-edit--strip-path (caddr p) (car p) (cadr p))))) (video-edit-pieces buf))))
    (let loop ((ps todo))
      (unless (null? ps)
        (let ((p (car ps)))
          (shell-command->string (video-edit--strip-command (caddr p) (car p) (cadr p)) "/tmp"
            (lambda (o) (video-edit--page! buf) (loop (cdr ps)))))))))

(define (video-edit--status! buf text)
  (buffer-set-local! buf 'video-edit-status text)
  (when (buffer-known? (video-edit--page-name buf)) (video-edit--page! buf))
  (video-edit--timeline-push! buf))

;; ---- editing the text

(define (video-edit--set-text! buf text)
  (with-current-buffer buf
    (lambda ()
      (let ((pt (point)))
        (buffer-delete-range! buf 0 (buffer-size buf))
        (buffer-insert! buf 0 text)
        (goto-char! (min pt (buffer-size buf)))))))

(define (video-edit--replace-pieces! buf f)
  "rewrite every piece line as the lines (F PIECE) answers; the other lines stay"
  (video-edit--set-text! buf
    (string-join
      (apply append
        (map (lambda (l)
               (let ((p (video-edit--piece l)))
                 (if p (map (lambda (q) (video-edit--line (caddr p) (car q) (cadr q) (cadddr p))) (f p)) (list l))))
             (string-split (buffer-text buf) "\n")))
      "\n")))

(define (video-edit-remove-pauses! buf)
  "(video-edit-remove-pauses! BUF) -- split every piece of BUF around its pauses, in a task"
  (let* ((pieces (video-edit-pieces buf))
         (files (let loop ((ps pieces) (acc '())) (if (null? ps) acc (loop (cdr ps) (if (member (caddr (car ps)) acc) acc (cons (caddr (car ps)) acc))))))
         (found '()))
    (video-edit--status! buf "Finding the pauses…")
    ;; one threshold per file, halfway between its hiss and its speech:
    ;; silencedetect reads every sample, so the hiss alone peaks well over
    ;; its average and a threshold near it finds no pause
    (let measure ((fs files) (noise '()))
      (if (pair? fs)
          (shell-command->string (audio-edit--levels-command (car fs)) "/tmp"
            (lambda (out)
              (let ((lv (audio-edit--parse-levels out)))
                (measure (cdr fs) (cons (list (car fs) (if (pair? lv) (max -60 (min -20 (/ (+ (car lv) (cadr lv)) 2))) -35)) noise)))))
          (let detect ((ps pieces))
            (if (pair? ps)
                (let* ((p (car ps)) (n (cadr (assoc (caddr p) noise))))
                  (shell-command->string (video-edit--silence-command (caddr p) (car p) (cadr p) (audio-edit--int n)) "/tmp"
                    (lambda (out)
                      (set! found (cons (list p (video-edit--keep (car p) (cadr p) (video-edit--silences out (car p)))) found))
                      (detect (cdr ps)))))
                (begin
                  (if (video-edit-clips? buf)
                      ;; each pause is a hidden clip, so t in the transcript brings it back
                      (for-each (lambda (hit)
                                  (let* ((p (car hit)) (keep (cadr hit)))
                                    (for-each (lambda (gap) (video-edit-add-clip! buf (caddr p) (car gap) (cadr gap) 'hidden "pause"))
                                              (video-edit--minus (car p) (cadr p) keep))))
                                (reverse found))
                      (video-edit--replace-pieces! buf (lambda (p) (let ((hit (assoc p found))) (if hit (cadr hit) (list (list (car p) (cadr p))))))))
                  (video-edit--status! buf (string-append "Pauses removed: now " (number->string (length (video-edit-pieces buf))) " segments"))
                  (when (buffer-known? (video-edit--page-name buf)) (video-edit--draw-missing! buf)))))))))

(define (video-edit--write! buf out height preview? done)
  (video-edit--status! buf (if preview? "Drawing the preview…" "Exporting…"))
  (let ((tmp (string-append (video-edit--cache) "/" (file-name-nondirectory out) ".part.mp4")))
    (shell-command->string (video-edit-export-command buf tmp height preview?) "/tmp"
      (lambda (o)
        (if (and (string? o) (string-suffix? "OK" (string-trim o))
                 (begin (when (file-exists? out) (delete-file! out)) (rename-file! tmp out)))
            (video-edit--status! buf (done out))
            (video-edit--status! buf (string-append "Failed: " (if (string? o) (string-trim o) ""))))))))

;; ---- commands

(define (video-edit-mode-setup)
  (buffer-set-local! (current-buffer) 'imenu-index-function 'video-edit--imenu-rows))
(define-mode "video-edit-mode" video-edit-mode-setup)

(define (video-edit-page-mode-setup) #t)
(define-mode "video-edit-page-mode" video-edit-page-mode-setup)

(define (video-edit--edit-buffer)
  "the edit the command acts on: this buffer, or the edit this page shows"
  (let ((b (current-buffer)))
    (if (equal? (buffer-local-value 'mode-name b) "video-edit-page-mode") (buffer-local-value 'video-edit-source b) b)))

(define (video-edit-new path)
  "(video-edit-new PATH) -- a new edit of the video PATH, NAME.vedit beside it, with the whole video as one segment; answers the edit's path"
  (let* ((path (expand-file-name path))
         (src (if (and (boundp 'cap-project?) (cap-project? path)) (cap--out-path (cap--strip path)) path))
         (dur (video-edit--duration src))
         (name (file-name-nondirectory src))
         (dot (string-rindex name "."))
         (edit (string-append (expand-file-name video-edit-export-directory) "/" (if dot (substring name 0 dot) name) ".vedit")))
    (unless (file-exists? edit)
      (write-file! edit (video-edit--form-text (list '((audio clean) (size 2160)) (list (list src '() '()))))))
    edit))

(define-command "video-edit-new" "Start an edit of a video: NAME.vedit, with the whole video as one segment"
  (lambda ()
    (read-file-name "Video to edit: "
      (lambda (path)
        (let ((edit (video-edit-new path)))
          (switch-to-buffer-here! (visit edit (buffer-group (current-buffer))))))))
  'modes '(video-edit-mode Dired cap-mode))

(define-command "video-edit-show-page" "Show the edit's page, with a filmstrip and a waveform per segment, in the other window"
  (lambda ()
    (let ((buf (video-edit--edit-buffer)))
      (display-buffer-other-window! (video-edit--page! buf))
      (video-edit--draw-missing! buf)))
  'modes '(video-edit-mode))

(define-command "video-edit-remove-pauses" "Cut every pause longer than video-edit-pause-seconds out of the edit"
  (lambda () (video-edit-remove-pauses! (video-edit--edit-buffer)))
  'modes '(video-edit-mode video-edit-page-mode))

(define-command "video-edit-cut" "Split the piece on this line at a time you type, in the video's own time"
  (lambda ()
    (let* ((buf (current-buffer)) (row (buffer-line-at-point buf)) (p (video-edit--piece (cadr row))))
      (if (not p) (message "No piece on this line")
          (read-string (string-append "Cut at (between " (video-edit-format-time (car p)) " and " (video-edit-format-time (cadr p)) "): ")
            (lambda (s)
              (let ((t (video-edit-parse-time (string-trim s))))
                (if (not (and t (> t (car p)) (< t (cadr p)))) (message "That time is not inside this piece")
                    (with-current-buffer buf
                      (lambda ()
                        (let* ((line (car row)) (start (line-start-position line)) (old (cadr row)))
                          (buffer-delete-range! buf start (length (string-bytes old)))
                          (buffer-insert! buf start (string-append (video-edit--line (caddr p) (car p) t) "\n" (video-edit--line (caddr p) t (cadr p))))))))))))))
  'modes '(video-edit-mode))

(define-command "video-edit-preview" "Write a 720p preview of the whole edit and play it on the page"
  (lambda ()
    (let ((buf (video-edit--edit-buffer)))
      (display-buffer-other-window! (video-edit--page! buf))
      (video-edit--write! buf (video-edit--preview-path buf) 720 #t (lambda (out) "Preview ready"))))
  'modes '(video-edit-mode video-edit-page-mode))

(define-command "video-edit-export" "Write the finished video to video-edit-export-directory"
  (lambda ()
    (let ((buf (video-edit--edit-buffer)))
      (video-edit--write! buf (video-edit--out-path buf) (video-edit--size buf) #f
        (lambda (out) (string-append "Exported: " (abbreviate-file-name out))))))
  'modes '(video-edit-mode video-edit-page-mode))

(mode-keys! "video-edit-mode"
  '(("C-c C-p" "video-edit-remove-pauses")
    ("C-c C-k" "video-edit-cut")
    ("C-c C-v" "video-edit-show-page")
    ("C-c C-r" "video-edit-preview")
    ("C-c C-e" "video-edit-export")))

(define (video-edit--piece-rows buf)
  "each piece of BUF with its line: (LINE TEXT PIECE)"
  (let loop ((ls (string-split (buffer-text buf) "\n")) (n 1) (acc '()))
    (if (null? ls) (reverse acc)
        (let ((p (video-edit--piece (car ls))))
          (loop (cdr ls) (+ n 1) (if p (cons (list n (car ls) p) acc) acc))))))

(define (video-edit--set-line! buf line old new)
  "replace LINE of BUF, whose text is OLD, by NEW; #f deletes the line"
  (with-current-buffer buf
    (lambda ()
      (let ((start (line-start-position line)) (len (length (string-bytes old))))
        (if new
            (begin (buffer-delete-range! buf start len) (buffer-insert! buf start new))
            (buffer-delete-range! buf start (min (+ len 1) (- (buffer-size buf) start))))))))

(define (video-edit--selected-row)
  (let* ((page (current-buffer)) (buf (video-edit--edit-buffer))
         (rows (if (video-edit-clips? buf) (map (lambda (p) (list #f #f p)) (video-edit-pieces buf)) (video-edit--piece-rows buf)))
         (sel (or (buffer-local-value 'video-edit-selected page) 1)))
    (and (pair? rows) (<= 1 sel (length rows)) (list buf (list-ref rows (- sel 1)) sel (length rows)))))

(define (video-edit--select! step)
  (let* ((page (current-buffer)) (buf (video-edit--edit-buffer))
         (n (length (video-edit-pieces buf)))
         (sel (or (buffer-local-value 'video-edit-selected page) 0))
         (next (max 1 (min n (+ sel step)))))
    (buffer-set-local! page 'video-edit-selected next)
    (video-edit--page! buf)
    (message (string-append "Segment " (number->string next) " of " (number->string n)))))

(define-command "video-edit-select-next" "Select the next segment"
  (lambda () (video-edit--select! 1)) 'modes '(video-edit-page-mode))
(define-command "video-edit-select-previous" "Select the previous segment"
  (lambda () (video-edit--select! -1)) 'modes '(video-edit-page-mode))

(define-command "video-edit-delete-piece" "Hide the selected segment"
  (lambda ()
    (let ((r (video-edit--selected-row)))
      (if (not r) (message "Select a segment with n or p")
          (let* ((buf (car r)) (row (cadr r)) (sel (caddr r)) (n (cadddr r)))
            (if (video-edit-clips? buf)
                (let ((p (caddr row))) (video-edit-add-clip! buf (caddr p) (car p) (cadr p) 'hidden "deleted"))
                (video-edit--set-line! buf (car row) (cadr row) #f))
            (buffer-set-local! (current-buffer) 'video-edit-selected (min sel (- n 1)))
            (video-edit--page! buf)
            (message (string-append "Hidden segment " (number->string sel)))))))
  'modes '(video-edit-page-mode))

(define-command "video-edit-rename-piece" "Name the selected segment"
  (lambda ()
    (let ((r (video-edit--selected-row)) (page (current-buffer)))
      (if (not r) (message "Select a segment with n or p")
          (let* ((buf (car r)) (row (cadr r)) (p (caddr row)))
           (if (video-edit-clips? buf) (message "Name clips in the transcript: C-c C-t, mark, c, R")
            (read-string (string-append "Name segment " (number->string (caddr r)) ": ")
              (lambda (name)
                (video-edit--set-line! buf (car row) (cadr row) (video-edit--line (caddr p) (car p) (cadr p) (string-trim name)))
                (video-edit--page! buf))))))))
  'modes '(video-edit-page-mode))

(define-command "video-edit-page-redraw" "Draw the page again from the edit"
  (lambda () (let ((buf (video-edit--edit-buffer))) (video-edit--page! buf) (video-edit--draw-missing! buf)))
  'modes '(video-edit-page-mode))

(define-command "video-edit-page-to-edit" "Show the edit this page draws, in the other window"
  (lambda () (display-buffer-other-window! (video-edit--edit-buffer)))
  'modes '(video-edit-page-mode))

;; ---- the project: the sources of an edit, in the order they play. Import
;; adds a video or a Cap recording at the end; a source moves as a block,
;; its clips and cuts with it.

(define (video-edit--blocks buf)
  "BUF's text as (HEAD BLOCK ...): HEAD the lines before the first source, each BLOCK a source line and the lines under it"
  (let loop ((ls (string-split (buffer-text buf) "\n")) (head '()) (blocks '()) (cur #f))
    (cond ((null? ls)
           (let ((blocks (if cur (cons (reverse cur) blocks) blocks)))
             (cons (reverse head) (reverse blocks))))
          ((video-edit--source (car ls))
           (loop (cdr ls) head (if cur (cons (reverse cur) blocks) blocks) (list (car ls))))
          (cur (loop (cdr ls) head blocks (cons (car ls) cur)))
          (else (loop (cdr ls) (cons (car ls) head) blocks cur)))))

(define (video-edit--set-blocks! buf hb)
  (let* ((lines (append (car hb) (apply append (cdr hb))))
         (lines (let trim ((r (reverse lines))) (if (and (pair? r) (equal? (car r) "")) (trim (cdr r)) (reverse r)))))
    (video-edit--set-text! buf (string-append (string-join lines "\n") "\n"))))

(define (video-edit-move-source! buf i dir)
  "(video-edit-move-source! BUF I DIR) -- move source I of BUF one place earlier (DIR -1) or later (DIR 1)"
  (let* ((hb (video-edit--blocks buf)) (bs (cdr hb)) (n (length bs)) (j (+ i dir)))
    (when (and (>= i 0) (>= j 0) (< i n) (< j n))
      (let ((x (list-ref bs i)) (y (list-ref bs j)))
        (video-edit--set-blocks! buf
          (cons (car hb)
                (let loop ((k 0) (r bs))
                  (if (null? r) '()
                      (cons (cond ((= k i) y) ((= k j) x) (else (car r))) (loop (+ k 1) (cdr r)))))))))))

(define (video-edit-remove-source! buf i)
  "(video-edit-remove-source! BUF I) -- take source I, its clips and cuts, out of BUF"
  (let ((hb (video-edit--blocks buf)))
    (video-edit--set-blocks! buf (cons (car hb) (let loop ((bs (cdr hb)) (k 0)) (cond ((null? bs) '()) ((= k i) (cdr bs)) (else (cons (car bs) (loop (cdr bs) (+ k 1))))))))))

(define (video-edit-add-source! buf path &optional done)
  "(video-edit-add-source! BUF PATH [DONE]) -- add the video PATH, or the Cap recording PATH joined into one video, at the end of BUF; DONE runs after"
  (let* ((path (expand-file-name path))
         (cap? (and (boundp 'cap-project?) (cap-project? path)))
         (video (if cap? (cap--out-path (cap--strip path)) path))
         (add (lambda ()
                              (video-edit--append-source! buf video)
                (video-edit--status! buf (string-append "Added " (file-name-nondirectory video)))
                (video-edit-prepare-source! buf video)
                (when done (done)))))
    (if (or (not cap?) (file-exists? video))
        (add)
        (let ((tmp (string-append (expand-file-name audio-edit-cache-directory) "/cap-export.mp4")))
          (video-edit--status! buf (string-append "Joining " (file-name-nondirectory path) "…"))
          (shell-command->string (cap-export-command (cap--strip path)) "/tmp"
            (lambda (o)
              (if (and (string? o) (string-prefix? "OK" o) (rename-file! tmp video))
                  (add)
                  (video-edit--status! buf (string-append "Could not join " (file-name-nondirectory path))))))))))

(define (video-edit-prepare-source! buf path)
  "(video-edit-prepare-source! BUF PATH) -- make what the timeline shows of PATH in a task: its filmstrip and waveform, then its transcript; each lands on the page when it is ready"
  (let ((d (video-edit--dur path)))
    (when d
      (let ((strip (lambda (k)
                     (if (file-exists? (video-edit--strip-path path 0 d)) (k)
                         (shell-command->string (video-edit--strip-command path 0 d) "/tmp"
                           (lambda (o) (video-edit--timeline-push! buf) (k))))))
            (words (lambda ()
                     (when (and (boundp 'video-transcript--command) (not (video-transcript-words path)))
                       (video-edit--status! buf (string-append "Writing the transcript of " (file-name-nondirectory path) "…"))
                       (shell-command->string (video-transcript--command path) "/tmp"
                         (lambda (o)
                           (video-edit--status! buf (string-append "Transcript ready: " (file-name-nondirectory path)))
                           (when (and (boundp 'video-transcript--name) (buffer-known? (video-transcript--name buf)))
                             (video-transcript--render! buf))))))))
        (let ((s (assoc path (cadr (video-edit-read buf)))))
          (when s (for-each (lambda (dub) (video-edit--transcribe-take! buf (caddr dub))) (caddr s))))
        (strip (lambda ()
                 (if (file-exists? (video-edit--wide-wave-path path)) (words)
                     (shell-command->string (video-edit--wide-wave-command path) "/tmp"
                       (lambda (o) (video-edit--timeline-push! buf) (words))))))))))

(define (video-edit-prepare-all! buf)
  "(video-edit-prepare-all! BUF) -- prepare every source of BUF, one after another"
  (let loop ((ss (video-edit-structure buf)))
    (unless (null? ss)
      (video-edit-prepare-source! buf (car (car ss)))
      (loop (cdr ss)))))

(define (video-edit--edits)
  "the open edits, the last used first"
  (filter (lambda (b) (equal? (buffer-local-value 'mode-name b) "video-edit-mode")) (buffer-list)))

(define-command "video-edit-import" "Add a video or a Cap recording to the end of this edit"
  (lambda ()
    (let ((edit (video-edit--edit-buffer)))
      (read-file-name "Import video or .cap: "
        (lambda (p) (video-edit-add-source! edit p (lambda () (video-edit--timeline-push! edit)))))))
  'modes '(video-edit-mode video-edit-page-mode video-edit-timeline-mode))

(define-command "video-edit-add-from-dired" "Add the marked files, or the file at point, to an open edit"
  (lambda ()
    (let* ((buf (current-buffer)) (dir (dired-dir buf))
           (marked (map car (list-marks buf)))
           (row (list-current buf))
           (names (if (pair? marked) marked (if row (list (if (string? row) row (plist-get row 'name))) '())))
           (paths (map (lambda (n) (expand-file-name n dir)) (filter string? names)))
           (edits (video-edit--edits)))
      (cond ((null? paths) (message "Mark files, or put point on one"))
            ((null? edits) (message "Open an edit first: M-x video-edit-new"))
            (else
             (completing-read "Add to edit: " edits
               (lambda (edit)
                 (let loop ((ps paths))
                   (if (null? ps) (video-edit--timeline-push! edit)
                       (video-edit-add-source! edit (car ps) (lambda () (loop (cdr ps)))))))
               'default (car edits))))))
  'modes '(Dired))

(mode-keys! "video-edit-mode" '(("C-c C-i" "video-edit-import")))

(define-command "video-edit-undo" "Take back the last change to the edit"
  (lambda () (let ((e (video-edit--edit-buffer)))
               (when (equal? (buffer-local-value 'mode-name (current-buffer)) "video-edit-timeline-mode") (set! e (buffer-local-value 'video-edit-timeline-of (current-buffer))))
               (when (and (boundp 'video-transcript--name) (buffer-local-value 'video-transcript-edit (current-buffer))) (set! e (buffer-local-value 'video-transcript-edit (current-buffer))))
               (message (if (video-edit-undo! e) "Undone" "Nothing to undo"))))
  'modes '(video-edit-mode video-edit-page-mode video-edit-timeline-mode video-transcript-mode))

(define-command "video-edit-redo" "Make again the change undo took back"
  (lambda () (let ((e (video-edit--edit-buffer)))
               (when (equal? (buffer-local-value 'mode-name (current-buffer)) "video-edit-timeline-mode") (set! e (buffer-local-value 'video-edit-timeline-of (current-buffer))))
               (when (and (boundp 'video-transcript--name) (buffer-local-value 'video-transcript-edit (current-buffer))) (set! e (buffer-local-value 'video-transcript-edit (current-buffer))))
               (message (if (video-edit-redo! e) "Redone" "Nothing to redo"))))
  'modes '(video-edit-mode video-edit-page-mode video-edit-timeline-mode video-transcript-mode))
(mode-keys! "Dired" '(("C-c C-v" "video-edit-add-from-dired")))

;; ---- the timeline: a page that runs its own script (nle.js) in the app
;; frame, plays the edit live and marks clips. It asks for the edit as data
;; and sends its changes back as operations; the edit file stays the truth.

(define (video-edit--timeline-name edit) (string-append "*timeline " (file-name-nondirectory (or (buffer-path edit) edit)) "*"))

(define (video-edit--own-dir)
  (let ((ds (filter (lambda (d) (string-suffix? "/video-edit" d)) (stdlib-dirs)))) (and (pair? ds) (car ds))))

(define (video-edit--timeline-state edit)
  "the edit as the timeline reads it"
  (let* ((st (video-edit-structure edit))
         (pieces (video-edit-pieces edit))
         (index (lambda (path) (let loop ((ss st) (i 0)) (cond ((null? ss) 0) ((equal? (car (car ss)) path) i) (else (loop (cdr ss) (+ i 1))))))))
    (list 'name (file-name-nondirectory (or (buffer-path edit) edit))
          ;; the timeline buffer's text scale: the transcript's size follows it
          'scale (let ((n (buffer-local-value 'text-scale (video-edit--timeline-name edit)))) (if (number? n) n 0))
          'status (or (buffer-local-value 'video-edit-status edit) "")
          'total (apply + (map (lambda (p) (- (cadr p) (car p))) pieces))
          'pieces (map (lambda (p) (list 'a (car p) 'b (cadr p) 'src (index (caddr p)))) pieces)
          'sources
          (map (lambda (s)
                 (let* ((path (car s)) (d (or (video-edit--dur path) 0))
                        (strip (video-edit--strip-path path 0 d)) (wave (video-edit--wave-path path 0 d))
                        (words (video-edit-words edit path)))
                   (list 'name (video-edit-title edit path)
                         'url (file-name-nondirectory path)
                         'dur d
                         'strip (if (file-exists? strip) (file-name-nondirectory strip) #f)
                         'wave (let ((w (video-edit--wide-wave-path path))) (cond ((file-exists? w) (file-name-nondirectory w)) ((file-exists? wave) (file-name-nondirectory wave)) (else #f)))
                         'clips (map (lambda (c) (list 'a (car c) 'b (cadr c) 'state (symbol->string (caddr c)) 'name (or (cadddr c) ""))) (cadr s))
                         'cuts (caddr s)
                         'marks (let ((src (assoc path (cadr (video-edit-read edit))))) (if src (filter pair? (map (lambda (c) (and (> (length c) 4) (list-ref c 4) (list (car c) (list-ref c 4)))) (cadr src))) '()))
                         'dubs (map (lambda (d) (list 'a (car d) 'b (cadr d) 'url (video-edit--take-url edit (caddr d)))) (cadddr s))
                         'mutes (map (lambda (m) (list 'a (car m) 'b (cadr m))) (list-ref s 4))
                         'words (if (pair? words) words '()))))
               st))))

(define (video-edit--timeline-dirs edit)
  (let loop ((ss (video-edit-structure edit)) (acc (if (buffer-path edit) (list (path-directory (buffer-path edit))) '())))
    (if (null? ss) (reverse acc)
        (loop (cdr ss) (let ((d (path-directory (car (car ss))))) (if (member d acc) acc (cons d acc)))))))

(define (video-edit--timeline-push! edit)
  (let ((tl (video-edit--timeline-name edit)))
    (when (and (buffer-known? tl) (boundp 'app-post!))
      ;; a source imported from a new folder: the page may read from it
      (buffer-set-local! tl 'app-directory (append (list (video-edit--own-dir) (video-edit--cache)) (video-edit--timeline-dirs edit)))
      (app-post! tl (video-edit--timeline-state edit)))))

(define (video-edit--find-clip edit i a b)
  (let ((s (list-ref (video-edit-structure edit) i)))
    (let loop ((cs (cadr s)))
      (cond ((null? cs) #f)
            ((and (< (abs (- (car (car cs)) a)) 0.006) (< (abs (- (cadr (car cs)) b)) 0.006)) (car cs))
            (else (loop (cdr cs)))))))

(define (video-edit--timeline-op! edit o)
  (let* ((kind (plist-get o 'op)) (i (or (plist-get o 'src) 0))
         (st (video-edit-structure edit))
         (path (and (< i (length st)) (car (list-ref st i))))
         (a (plist-get o 'a)) (b (plist-get o 'b))
         (state (let ((s (plist-get o 'state))) (and (string? s) (string->symbol s))))
         (name (plist-get o 'name)))
    (cond ((equal? kind "clip") (when path (video-edit-add-clip! edit path a b (or state 'hidden) name)))
          ((equal? kind "cut") (when path (video-edit-add-cut! edit path (plist-get o 't))))
          ((equal? kind "uncut") (when path (video-edit-remove-cut! edit path (plist-get o 't))))
          ((equal? kind "dub") (when path (video-edit--save-take! edit path (plist-get o 'a) (plist-get o 'data) (plist-get o 'mime))))
          ((equal? kind "undub") (when path (video-edit-remove-dub! edit path (plist-get o 'a))))
          ((equal? kind "toggle-hidden") (when path (video-edit-toggle-hidden! edit path a b)))
          ((equal? kind "toggle-muted") (when path (video-edit-toggle-muted! edit path a b)))
          ((equal? kind "move-cut") (when path (video-edit-move-cut! edit path (plist-get o 'from) (plist-get o 't))))
          ((equal? kind "at") (buffer-set-local! edit 'video-edit-playhead (list path (plist-get o 't))))
          ((equal? kind "move-source") (video-edit-move-source! edit i (or (plist-get o 'dir) 1)))
          ((equal? kind "remove-source") (video-edit-remove-source! edit i))
          ((equal? kind "import") (with-current-buffer edit (lambda () (run-command "video-edit-import"))))
          ((equal? kind "show-edit") (display-buffer-other-window! edit))
          ((equal? kind "log") (buffer-set-local! edit 'video-edit-log (list-head (cons (plist-get o 'what) (or (buffer-local-value 'video-edit-log edit) '())) (min 40 (+ 1 (length (or (buffer-local-value 'video-edit-log edit) '())))))))
          ((equal? kind "undo") (buffer-set-local! edit 'video-edit-status (if (video-edit-undo! edit) "Undone" "Nothing to undo")))
          ((equal? kind "redo") (buffer-set-local! edit 'video-edit-status (if (video-edit-redo! edit) "Redone" "Nothing to redo")))
          ((equal? kind "save") (with-current-buffer edit (lambda () (buffer-save!))) (buffer-set-local! edit 'video-edit-status "Saved"))
          ((equal? kind "set") (let ((c (video-edit--find-clip edit i a b))) (when c (video-edit-set-clip! edit c (or state (caddr c)) name))))
          ((equal? kind "del") (let ((c (video-edit--find-clip edit i a b))) (when c (video-edit-set-clip! edit c #f #f))))
          ((equal? kind "export")
           (video-edit--write! edit (video-edit--out-path edit) (video-edit--size edit) #f
             (lambda (out) (string-append "Exported: " (abbreviate-file-name out))))))
    (when (and (boundp 'video-transcript--name) (buffer-known? (video-transcript--name edit))) (video-transcript--paint! (video-transcript--name edit)))
    (when (buffer-known? (video-edit--page-name edit)) (video-edit--page! edit))))

;; ---- the timeline's policy. The page tells what it knows (the playhead:
;; video, time, playing) and asks for an action by name; Scheme decides what
;; the action does, changes the edit, keeps the selection, and answers the
;; edit with what the page should show: the selection, a place for the
;; playhead, a status line, a take to record.

(define (video-edit--tl-sel tl) (buffer-local-value 'video-edit-tl-sel tl))
(define (video-edit--tl tl key default) (let ((v (buffer-local-value (string->symbol (string-append "video-edit-tl-" key)) tl))) (if (null? v) default v)))
(define (video-edit--tl! tl key v) (buffer-set-local! tl (string->symbol (string-append "video-edit-tl-" key)) v))

(define (video-edit--zoom-around edit tl i t factor)
  "the source bar's window, scaled by FACTOR around T, kept inside the video; #f is the whole video"
  (let* ((d (video-edit--src-dur edit i)) (z (video-edit--tl tl "zoom" #f))
         (span (* factor (if (pair? z) (- (cadr z) (car z)) d))))
    (if (>= span (- d 0.01)) #f
        (let* ((span (max 1 span)) (a (max 0 (min (- d span) (- t (/ span 2))))))
          (list a (+ a span))))))

(define (video-edit--caret-move edit tl i dir edge)
  "the cursor moved a line (DIR) or to a line's edge (EDGE -1 or 1), as a word index in source I"
  (let* ((ws (video-edit-words edit (video-edit--src-path edit i)))
         (lines (if (pair? ws) (video-transcript--lines ws) '()))
         (caret (or (video-edit--tl tl "caret" #f) 0))
         ;; each line as its first word index and length
         (spans (let loop ((ls lines) (k 0) (acc '())) (if (null? ls) (reverse acc) (loop (cdr ls) (+ k (length (car ls))) (cons (list k (length (car ls))) acc)))))
         (ln (let loop ((ss spans) (n 0)) (cond ((null? ss) (max 0 (- n 1))) ((< caret (+ (car (car ss)) (cadr (car ss)))) n) (else (loop (cdr ss) (+ n 1))))))
         (here (and (pair? spans) (list-ref spans (min ln (- (length spans) 1))))))
    (cond ((not here) #f)
          (edge (if (< edge 0) (car here) (+ (car here) (cadr here) -1)))
          (else (let ((m (+ ln dir)))
                  (if (or (< m 0) (>= m (length spans))) caret
                      (let ((there (list-ref spans m))) (+ (car there) (min (- caret (car here)) (- (cadr there) 1))))))))))
(define (video-edit--tl-set-sel! tl sel) (buffer-set-local! tl 'video-edit-tl-sel sel))

(define (video-edit--src-path edit i) (let ((st (video-edit-structure edit))) (and (< i (length st)) (car (list-ref st i)))))
(define (video-edit--src-cuts edit i) (let ((st (video-edit-structure edit))) (if (< i (length st)) (caddr (list-ref st i)) '())))
(define (video-edit--src-dur edit i) (let ((p (video-edit--src-path edit i))) (or (and p (video-edit--dur p)) 0)))

(define (video-edit--segment-at edit i t)
  "the segment of source I that holds T: from the cut at or before it to the next cut, or the start and end"
  (let* ((cuts (video-edit--src-cuts edit i)) (d (video-edit--src-dur edit i))
         (a (let loop ((cs cuts) (best 0)) (cond ((null? cs) best) ((<= (car cs) (+ t 0.02)) (loop (cdr cs) (car cs))) (else best))))
         (b (let loop ((cs cuts)) (cond ((null? cs) d) ((> (car cs) (+ a 0.02)) (car cs)) (else (loop (cdr cs)))))))
    (list i a b)))

(define (video-edit--sel-range edit sel ctx)
  "the segment an action acts on: the chosen cut's, the chosen segment, else the one at the playhead"
  (cond ((and (pair? sel) (equal? (car sel) 'cut)) (video-edit--segment-at edit (cadr sel) (caddr sel)))
        ((and (pair? sel) (equal? (car sel) 'range)) (cdr sel))
        (else (video-edit--segment-at edit (car ctx) (cadr ctx)))))

(define (video-edit--choose-cut edit tl i t msg)
  (let ((r (video-edit--segment-at edit i t)))
    (video-edit--tl-set-sel! tl (list 'cut i t))
    (list 'seek (list 'src i 't t) 'status (string-append (or msg "") "Cut at " (video-edit-format-time t) " · segment " (video-edit-format-time (cadr r)) " → " (video-edit-format-time (caddr r))
                                                              " · h hide · m mute · r re-record · ⇧← ⇧→ move · ⌫ delete"))))

(define (video-edit--word-start edit i t dir)
  "the start of the word before (DIR -1) or after (1) T in source I"
  (let ((ws (video-edit-words edit (video-edit--src-path edit i))))
    (and (pair? ws)
         (if (> dir 0)
             (let loop ((w ws)) (cond ((null? w) #f) ((> (car (car w)) (+ t 0.03)) (- (car (car w)) 0.02)) (else (loop (cdr w)))))
             (let loop ((w ws) (best #f)) (cond ((null? w) best) ((< (car (car w)) (- t 0.03)) (loop (cdr w) (- (car (car w)) 0.02))) (else best)))))))

(define (video-edit--line-start edit i t dir)
  "the word in the transcript line above or below T's, at the same place in its line"
  (let* ((ws (video-edit-words edit (video-edit--src-path edit i)))
         (lines (if (pair? ws) (video-transcript--lines ws) '()))
         (n (let loop ((ls lines) (k 0)) (cond ((null? ls) #f) ((and (pair? (car ls)) (< t (+ (cadr (car (reverse (car ls)))) 0.01))) k) (else (loop (cdr ls) (+ k 1))))))
         (here (and n (list-ref lines n)))
         (col (and here (let loop ((w here) (c 0)) (cond ((null? w) c) ((>= (car (car w)) (- t 0.03)) c) (else (loop (cdr w) (+ c 1)))))))
         (m (and n (+ n dir))))
    (and m (>= m 0) (< m (length lines))
         (let ((there (list-ref lines m))) (- (car (list-ref there (min col (- (length there) 1)))) 0.02)))))

(define (video-edit-words edit path)
  "(video-edit-words EDIT PATH) -- the words said in the clip PATH as the edit plays it: the clip's own, and where a take is laid in, the take's words at their place"
  (let* ((own (and (boundp 'video-transcript-words) (video-transcript-words path)))
         (s (assoc path (cadr (video-edit-read edit))))
         (dubs (if s (caddr s) '())))
    (if (null? dubs) own
        (let* ((outside (filter (lambda (w) (not (let any ((ds dubs)) (and (pair? ds) (or (and (>= (/ (+ (car w) (cadr w)) 2) (car (car ds))) (< (/ (+ (car w) (cadr w)) 2) (cadr (car ds)))) (any (cdr ds)))))))
                                (or own '())))
               (taken (apply append
                        (map (lambda (d)
                               (let ((tw (video-transcript-words (caddr d))))
                                 (if (pair? tw)
                                     (filter (lambda (w) (< (car w) (cadr d)))
                                             (map (lambda (w) (list (+ (car d) (car w)) (+ (car d) (cadr w)) (caddr w))) tw))
                                     '())))
                             dubs))))
          ;; both are in time order: merge them by start, so words that share a start keep the order they were said in
          (let merge ((a outside) (b taken) (acc '()))
            (cond ((null? a) (append (reverse acc) b))
                  ((null? b) (append (reverse acc) a))
                  ((<= (car (car b)) (car (car a))) (merge a (cdr b) (cons (car b) acc)))
                  (else (merge (cdr a) b (cons (car a) acc)))))))))

(define video-edit-pause-min 1.0)

(define (video-edit--pauses edit i)
  "the pauses of source I: gaps of video-edit-pause-min seconds or more between two words, (START END NEXT-WORD)"
  (let ((ws (video-edit-words edit (video-edit--src-path edit i))))
    (if (not (pair? ws)) '()
        (let loop ((w ws) (acc '()))
          (if (or (null? w) (null? (cdr w))) (reverse acc)
              (let ((a (cadr (car w))) (b (car (cadr w))))
                (loop (cdr w) (if (>= (- b a) video-edit-pause-min) (cons (list a b (caddr (cadr w))) acc) acc))))))))

(define (video-edit--act! edit tl name ctx)
  "do the timeline action NAME; CTX is the page's playhead (SRC T PLAYING); answers what the page should show"
  (let* ((sel (video-edit--tl-sel tl)) (i (car ctx)) (t (cadr ctx))
         (on-cut (and (pair? sel) (equal? (car sel) 'cut) sel)))
    (cond
      ((equal? name "cut")
       (let ((path (video-edit--src-path edit i)))
         (video-edit-add-cut! edit path t)
         (video-edit--choose-cut edit tl i t "")))
      ((or (equal? name "next-point") (equal? name "previous-point"))
       ;; the stops: every cut, and each clip's start, which is where its first segment begins
       (let* ((stops (let loop ((ss (video-edit-structure edit)) (k 0) (acc '()))
                       (if (null? ss) (reverse acc)
                           (let ((cuts (caddr (car ss))))
                             (loop (cdr ss) (+ k 1)
                                   (append (reverse (sort (append (map (lambda (c) (list k c)) (if (and (pair? cuts) (< (car cuts) 0.02)) cuts (cons 0 cuts)))
                                                                  (map (lambda (p) (list k (car p) (cadr p))) (video-edit--pauses edit k)))))
                                           acc))))))
              ;; step from what is chosen, not from the frame the video settled on
              (i (cond (on-cut (cadr on-cut)) ((and (pair? sel) (equal? (car sel) 'range)) (cadr sel)) (else i)))
              (t (cond (on-cut (caddr on-cut)) ((and (pair? sel) (equal? (car sel) 'range)) (caddr sel)) (else t)))
              (after (lambda (s) (or (> (car s) i) (and (= (car s) i) (> (cadr s) (+ t 0.02))))))
              (before (lambda (s) (or (< (car s) i) (and (= (car s) i) (< (cadr s) (- t 0.02))))))
              (s (if (equal? name "next-point") (let find ((ss stops)) (cond ((null? ss) #f) ((after (car ss)) (car ss)) (else (find (cdr ss)))))
                     (let find ((ss (reverse stops))) (cond ((null? ss) #f) ((before (car ss)) (car ss)) (else (find (cdr ss))))))))
         (cond ((not s) (list 'status (if (equal? name "next-point") "No cut after this" "No cut before this")))
               ((pair? (cddr s))
                ;; a pause: it is chosen, as a stretch
                (video-edit--tl! tl "shown" (car s))
                (video-edit--tl-set-sel! tl (list 'range (car s) (cadr s) (caddr s)))
                (list 'seek (list 'src (car s) 't (cadr s))
                      'status (string-append "Pause " (number->string (video-edit--round (- (caddr s) (cadr s)))) " s at " (video-edit-format-time (cadr s)) " · h hides it · m mutes it")))
               ((member (cadr s) (video-edit--src-cuts edit (car s))) (video-edit--choose-cut edit tl (car s) (cadr s) ""))
               (else
                ;; a clip's start: its first segment is chosen
                (let ((r (video-edit--segment-at edit (car s) (cadr s))))
                  (video-edit--tl! tl "shown" (car s))
                  (video-edit--tl-set-sel! tl (cons 'range r))
                  (list 'seek (list 'src (car s) 't (cadr s))
                        'status (string-append "Start of clip " (number->string (+ (car s) 1)) " · segment " (video-edit-format-time (cadr r)) " → " (video-edit-format-time (caddr r)) " · h hide · m mute · r re-record")))))))
      ((or (equal? name "hide") (equal? name "mute"))
       (let* ((r (video-edit--sel-range edit sel ctx)) (path (video-edit--src-path edit (car r))))
         (if (equal? name "hide") (video-edit-toggle-hidden! edit path (cadr r) (caddr r)) (video-edit-toggle-muted! edit path (cadr r) (caddr r)))
         (list 'status (string-append name " toggled " (video-edit-format-time (cadr r)) " → " (video-edit-format-time (caddr r)) " · press it again to undo"))))
      ((or (equal? name "remove") (equal? name "remove-key"))
       (cond (on-cut (video-edit-remove-cut! edit (video-edit--src-path edit (cadr on-cut)) (caddr on-cut)) (video-edit--tl-set-sel! tl #f) (list 'status "Cut deleted"))
             ((and (pair? sel) (equal? (car sel) 'dub)) (video-edit-remove-dub! edit (video-edit--src-path edit (cadr sel)) (caddr sel)) (video-edit--tl-set-sel! tl #f) (list 'status "Take taken out"))
             ((and (pair? sel) (equal? (car sel) 'range)) (video-edit-toggle-hidden! edit (video-edit--src-path edit (cadr sel)) (caddr sel) (cadddr sel)) (list 'status "Segment toggled"))
             (else (list 'status "Nothing chosen · ⌥← ⌥→ goes to a cut"))))
      ((member name '("select-word-back" "select-word-on" "select-up" "select-down" "cut-nudge-back" "cut-nudge-on"))
       (if (not on-cut) (list 'status "Choose a cut first: ⌥← ⌥→, or click its ✂")
           (let* ((ci (cadr on-cut)) (ct (caddr on-cut)) (path (video-edit--src-path edit ci))
                  (nt (cond ((equal? name "select-word-back") (video-edit--word-start edit ci ct -1))
                            ((equal? name "select-word-on") (video-edit--word-start edit ci ct 1))
                            ((equal? name "select-up") (video-edit--line-start edit ci ct -1))
                            ((equal? name "select-down") (video-edit--line-start edit ci ct 1))
                            ((equal? name "cut-nudge-back") (- ct 0.1))
                            (else (+ ct 0.1)))))
             (if (not nt) (list 'status "No word there")
                 (let ((nt (max 0.05 (min (- (video-edit--src-dur edit ci) 0.05) nt))))
                   (video-edit-move-cut! edit path ct nt)
                   (video-edit--choose-cut edit tl ci nt "Moved · "))))))
      ((equal? name "record")
       (let ((r (video-edit--sel-range edit sel ctx)))
         (list 'record (list 'src (car r) 'a (cadr r) 'b (caddr r)) 'status (string-append "Re-recording " (video-edit-format-time (cadr r)) " → " (video-edit-format-time (caddr r))))))
      ((equal? name "select-cut") (video-edit--choose-cut edit tl i t ""))
      ((equal? name "select-range")
       (let ((b (or (cadddr ctx) t)))
         (video-edit--tl-set-sel! tl (list 'range i t b))
         (list 'status (string-append "Chosen " (video-edit-format-time t) " → " (video-edit-format-time b) " · h hide · m mute"))))
      ((equal? name "select-dub")
       (video-edit--tl-set-sel! tl (list 'dub i t))
       (list 'status (string-append "Take at " (video-edit-format-time t) " · ⌫ takes it out, the original sound comes back")))
      ((equal? name "select-segment")
       (let ((r (video-edit--segment-at edit i t)))
         (video-edit--tl! tl "shown" i)
         (video-edit--tl-set-sel! tl (cons 'range r))
         (list 'status (string-append "Segment " (video-edit-format-time (cadr r)) " → " (video-edit-format-time (caddr r)) " · h hide · m mute · r re-record"))))
      ((equal? name "clear") (video-edit--tl-set-sel! tl #f) (list 'status ""))
      ((string-prefix? "mark-" name)
       (let ((n (string->number (substring name 5 (string-length name)))))
         (if (not on-cut) (list 'status "Choose a cut first, then b and a number")
             (begin (video-edit-set-mark! edit (video-edit--src-path edit (cadr on-cut)) (caddr on-cut) n)
                    (list 'status (string-append "Cut at " (video-edit-format-time (caddr on-cut)) " is bookmark " (number->string n) " · M-" (number->string n) " comes back here"))))))
      ((string-prefix? "go-" name)
       (let* ((n (string->number (substring name 3 (string-length name)))) (m (video-edit-find-mark edit n)))
         (if m (video-edit--choose-cut edit tl (car m) (cadr m) (string-append "Bookmark " (number->string n) " · "))
             (list 'status (string-append "No bookmark " (number->string n) " · choose a cut and press b " (number->string n))))))
      ((equal? name "play") (video-edit--tl! tl "playing" (not (caddr ctx))) (list))
      ((member name '("scrub-back" "scrub-on" "frame-back" "frame-on"))
       (let ((d (cond ((equal? name "scrub-back") -1) ((equal? name "scrub-on") 1) ((equal? name "frame-back") (/ -1 30)) (else (/ 1 30)))))
         (when (string-prefix? "frame" name) (video-edit--tl! tl "playing" #f))
         (list 'seek (list 'src i 't (max 0 (min (video-edit--src-dur edit i) (+ t d)))))))
      ((or (equal? name "beginning") (equal? name "end"))
       (video-edit--tl! tl "playing" #f)
       (let* ((ps (video-edit-pieces edit)) (st (video-edit-structure edit))
              (idx (lambda (path) (let loop ((ss st) (k 0)) (cond ((null? ss) 0) ((equal? (car (car ss)) path) k) (else (loop (cdr ss) (+ k 1))))))))
         (if (null? ps) (list)
             (let ((p (if (equal? name "beginning") (car ps) (car (reverse ps)))))
               (list 'seek (list 'src (idx (caddr p)) 't (if (equal? name "beginning") (car p) (max (car p) (- (cadr p) 0.05)))))))))
      ((member name '("zoom-in" "zoom-out"))
       (video-edit--tl! tl "zoom" (video-edit--zoom-around edit tl i t (if (equal? name "zoom-in") 0.5 2))) (list))
      ((equal? name "zoom-whole") (video-edit--tl! tl "zoom" #f) (list))
      ((equal? name "zoom-to") (video-edit--tl! tl "zoom" (let ((b (cadddr ctx))) (if (and b (> b (+ t 0.5))) (list t b) #f))) (list))
      ((equal? name "zoom-clip")
       (let* ((r (video-edit--sel-range edit sel ctx)) (pad (max 0.5 (* 0.08 (- (caddr r) (cadr r))))))
         (video-edit--tl! tl "shown" (car r))
         (video-edit--tl! tl "zoom" (list (max 0 (- (cadr r) pad)) (min (video-edit--src-dur edit (car r)) (+ (caddr r) pad)))) (list)))
      ((equal? name "whole") (video-edit--tl! tl "whole" (not (video-edit--tl tl "whole" #f))) (list 'status (if (video-edit--tl tl "whole" #f) "Whole video: hidden parts play too" "The edit: hidden parts are skipped")))
      ((member name '("line-up" "line-down" "line-start" "line-end"))
       (let ((n (video-edit--caret-move edit tl (video-edit--tl tl "shown" i)
                                        (if (equal? name "line-up") -1 1)
                                        (cond ((equal? name "line-start") -1) ((equal? name "line-end") 1) (else #f)))))
         (when n (video-edit--tl! tl "caret" n) (video-edit--tl-set-sel! tl #f))
         (let* ((ws (and n (video-edit-words edit (video-edit--src-path edit (video-edit--tl tl "shown" i))))) (w (and (pair? ws) (< n (length ws)) (list-ref ws n))))
           (if w (list 'seek (list 'src (video-edit--tl tl "shown" i) 't (car w))) (list)))))
      ((equal? name "play-here")
       (video-edit--tl! tl "playing" #t)
       (let* ((shown (video-edit--tl tl "shown" i)) (n (video-edit--tl tl "caret" #f))
              (ws (and n (video-edit-words edit (video-edit--src-path edit shown)))) (w (and (pair? ws) (< n (length ws)) (list-ref ws n))))
         (if w (list 'seek (list 'src shown 't (car w))) (list))))
      ((equal? name "caret") (video-edit--tl! tl "caret" (inexact->exact (round (or (cadddr ctx) 0)))) (video-edit--tl-set-sel! tl #f) (list 'seek (list 'src i 't t)))
      ((equal? name "show") (video-edit--tl! tl "shown" i) (video-edit--tl! tl "zoom" #f) (list))
      (else (list 'status (string-append "No action " name))))))

(define (video-edit--view tl answer)
  "what the page shows, all of it Scheme's: the selection, the video shown, the zoom, whole mode, the cursor, playing or not, and the action's answer"
  (let ((sel (video-edit--tl-sel tl)) (seek (plist-get answer 'seek)))
    ;; going to another video shows it
    (when (and seek (not (equal? (plist-get seek 'src) (video-edit--tl tl "shown" 0)))) (video-edit--tl! tl "shown" (plist-get seek 'src)) (video-edit--tl! tl "zoom" #f))
    (append (list 'shown (video-edit--tl tl "shown" 0) 'zoom (let ((z (video-edit--tl tl "zoom" #f))) (if (pair? z) (list 'a (car z) 'b (cadr z)) #f))
                  'whole (if (video-edit--tl tl "whole" #f) #t #f) 'caret (video-edit--tl tl "caret" #f) 'playing (if (video-edit--tl tl "playing" #f) #t #f)
                  'sel (cond ((and (pair? sel) (equal? (car sel) 'cut)) (list 'kind "cut" 'src (cadr sel) 't (caddr sel)))
                             ((and (pair? sel) (equal? (car sel) 'range)) (list 'kind "range" 'src (cadr sel) 'a (caddr sel) 'b (cadddr sel)))
                             ((and (pair? sel) (equal? (car sel) 'dub)) (list 'kind "dub" 'src (cadr sel) 'a (caddr sel)))
                             (else #f)))
            answer)))

(define (video-edit--app-request buf method body)
  (let ((edit (buffer-local-value 'video-edit-timeline-of buf)))
    (and edit (buffer-known? edit)
         (begin
           (let* ((o (if (equal? method "POST") (or (json-parse body) '()) '()))
                  (_ (when (equal? (plist-get o 'op) "at") (video-edit--tl! buf "playing" #f)))
                  (act (and (equal? (plist-get o 'op) "act")
                            (video-edit--act! edit buf (plist-get o 'name) (list (or (plist-get o 'src) 0) (or (plist-get o 't) 0) (plist-get o 'playing) (plist-get o 'b))))))
             (when (and (equal? method "POST") (not act)) (video-edit--timeline-op! edit o))
             (list 200 (json-encode (append (video-edit--timeline-state edit) (list 'view (video-edit--view buf (or act '())))))))))))

(add-hook! 'app-request 'video-edit--app-request)

(define video-edit--timeline-html
  "<!doctype html><html><head><meta charset=\"utf-8\"><link rel=\"stylesheet\" href=\"nle.css\"></head><body><script src=\"nle.js\"></script></body></html>")

(define (video-edit--timeline-fill! name)
  "put the timeline's page into NAME: the frame loads it from the buffer's text, so an empty buffer is a blank frame"
  (unless (equal? (buffer-text name) video-edit--timeline-html)
    (buffer-set-read-only! name #f)
    (buffer-delete-range! name 0 (buffer-size name))
    (buffer-append! name video-edit--timeline-html)
    (buffer-mark-saved! name)
    (buffer-set-read-only! name #t)))

;; the mode puts the page back whenever it starts: after a restore, or after the
;; text was taken back, the frame draws again
(define (video-edit-timeline-mode-setup)
  (let ((name (current-buffer)))
    (buffer-set-local! name 'imenu-index-function 'video-edit--timeline-imenu-rows)
    (when (buffer-local-value 'video-edit-timeline-of name)
      (video-edit--timeline-fill! name)
      (buffer-set-local! name 'render-mode "app"))))
(define-mode "video-edit-timeline-mode" video-edit-timeline-mode-setup)

(define (video-edit-timeline! edit)
  "(video-edit-timeline! EDIT) -- the timeline of EDIT, shown in the other window; it draws the filmstrips it lacks in a task"
  (let* ((name (video-edit--timeline-name edit))
         (st (video-edit-structure edit))
         (dirs (let loop ((ss st) (acc '())) (if (null? ss) (reverse acc) (loop (cdr ss) (let ((d (path-directory (car (car ss))))) (if (member d acc) acc (cons d acc))))))))
    (buffer-create name)
    (when (and (buffer-group edit) (not (equal? (buffer-group name) (buffer-group edit)))) (buffer-move-to-group! name (buffer-group edit)))
    (unless (equal? (buffer-local-value 'mode-name name) "video-edit-timeline-mode")
      (with-current-buffer name (lambda () (set-mode! "video-edit-timeline-mode"))))
    (buffer-set-local! name 'video-edit-timeline-of edit)
    (buffer-set-local! name 'app-directory (append (list (video-edit--own-dir) (video-edit--cache)) dirs))
    (video-edit--timeline-fill! name)
    (desktop-skip! name 'footer-line-blocks)
    (buffer-set-local! name 'footer-line-blocks
      (list (component 'ui/keys-bar
              (list 'main '(("⌥← ⌥→" "cut to cut") ("← →" "scrub") ("↑ ↓" "line") ("SPC" "play") ("h" "hide") ("m" "mute") ("r" "re-record") ("c" "cut") ("⇧← ⇧→" "move cut") ("⌫" "delete") ("= -" "zoom") ("z" "zoom to it") ("0" "whole") ("+" "import") ("R" "name clip") ("p" "project file") ("⌘Z" "undo") ("⌘S" "save") ("e" "export") ("C-g" "keys back"))))))
    (app-reload! name)
    (buffer-set-local! name 'render-mode "app")
    (display-buffer-other-window! name)
    ;; a filmstrip and a waveform of each whole source, for the source bar
    (let loop ((ss st))
      (unless (null? ss)
        (let* ((p (car (car ss))) (d (video-edit--dur p)))
          (if (or (not d) (file-exists? (video-edit--strip-path p 0 d)))
              (loop (cdr ss))
              (shell-command->string (video-edit--strip-command p 0 d) "/tmp"
                (lambda (o) (video-edit--timeline-push! edit) (loop (cdr ss))))))))
    name))

;; The timeline's page runs in a frame of its own, and a key only reaches
;; it when that frame holds the keyboard. So the timeline buffer binds its
;; keys here as well: each one is posted to the page, which runs it as if
;; it had been typed there.
(define video-edit--timeline-keys
  ;; (KEY ACTION DOC): each key names an action; the page plays and draws, Scheme decides
  '(("SPC" "play" "Play or pause")
    ("RET" "play-here" "Play from the cursor")
    ("<left>" "scrub-back" "Scrub a second back")
    ("<right>" "scrub-on" "Scrub a second on")
    ("," "frame-back" "Step a frame back")
    ("." "frame-on" "Step a frame on")
    ("<up>" "line-up" "The transcript line above")
    ("<down>" "line-down" "The transcript line below")
    ("<home>" "line-start" "The start of the line")
    ("<end>" "line-end" "The end of the line")
    ("M-<" "beginning" "The beginning of the edit")
    ("M->" "end" "The end of the edit")
    ("M-<left>" "previous-point" "The cut before")
    ("M-<right>" "next-point" "The next cut")
    ("S-<left>" "select-word-back" "Move the chosen cut a word earlier")
    ("S-<right>" "select-word-on" "Move the chosen cut a word later")
    ("S-<up>" "select-up" "Move the chosen cut a line up")
    ("S-<down>" "select-down" "Move the chosen cut a line down")
    ("c" "cut" "Cut at the playhead")
    ("h" "hide" "Hide or show the segment")
    ("m" "mute" "Mute or unmute the segment")
    ("r" "record" "Re-record the segment")
    ("DEL" "remove" "Delete the chosen cut or take")
    ("<backspace>" "remove-key" "Delete the chosen cut or take")
    ("<escape>" "clear" "Let go of what is chosen")
    ("=" "zoom-in" "Zoom in around the playhead")
    ("-" "zoom-out" "Zoom out")
    ("z" "zoom-clip" "Zoom to the chosen segment")
    ("0" "zoom-whole" "Show the whole video")
    ("w" "whole" "Play the whole video, hidden parts too")
    ("e" "export-key" "Export the finished video")
    ("+" "import-key" "Add a video or a Cap recording")
    ("[" "source-earlier" "Move this video earlier")
    ("]" "source-later" "Move this video later")
    ("X" "drop-source" "Take this video out of the edit")
    ("p" "project-file" "Show the project file")
    ("b 1" "mark-1" "Bookmark the chosen cut as 1") ("b 2" "mark-2" "Bookmark the chosen cut as 2") ("b 3" "mark-3" "Bookmark the chosen cut as 3")
    ("b 4" "mark-4" "Bookmark the chosen cut as 4") ("b 5" "mark-5" "Bookmark the chosen cut as 5") ("b 6" "mark-6" "Bookmark the chosen cut as 6")
    ("b 7" "mark-7" "Bookmark the chosen cut as 7") ("b 8" "mark-8" "Bookmark the chosen cut as 8") ("b 9" "mark-9" "Bookmark the chosen cut as 9")
    ("M-1" "go-1" "Go to bookmark 1") ("M-2" "go-2" "Go to bookmark 2") ("M-3" "go-3" "Go to bookmark 3")
    ("M-4" "go-4" "Go to bookmark 4") ("M-5" "go-5" "Go to bookmark 5") ("M-6" "go-6" "Go to bookmark 6")
    ("M-7" "go-7" "Go to bookmark 7") ("M-8" "go-8" "Go to bookmark 8") ("M-9" "go-9" "Go to bookmark 9")))

(for-each
  (lambda (row)
    (let ((action (cadr row)))
      (define-command (string-append "video-edit-timeline-" action) (caddr row)
        (lambda () (app-post! (current-buffer) (list 'act action)))
        'modes '(video-edit-timeline-mode))))
  video-edit--timeline-keys)

(mode-keys! "video-edit-timeline-mode"
  (map (lambda (row) (list (car row) (string-append "video-edit-timeline-" (cadr row)))) video-edit--timeline-keys))

(define-command "video-edit-timeline" "Show the edit's timeline: play it live, skipping hidden clips, and mark clips"
  (lambda ()
    (let ((edit (video-edit--edit-buffer)))
      (if (not (video-edit-clips? edit)) (message "The timeline needs source lines in the edit")
          (video-edit-timeline! edit))))
  'modes '(video-edit-mode video-edit-page-mode))

(mode-keys! "video-edit-mode" '(("C-c C-l" "video-edit-timeline")))

(mode-keys! "video-edit-page-mode"
  '(("g" "video-edit-page-redraw")
    ("n" "video-edit-select-next")
    ("p" "video-edit-select-previous")
    ("<down>" "video-edit-select-next")
    ("<up>" "video-edit-select-previous")
    ("d" "video-edit-delete-piece")
    ("R" "video-edit-rename-piece")
    ("P" "video-edit-remove-pauses")
    ("r" "video-edit-preview")
    ("e" "video-edit-export")
    ("o" "video-edit-page-to-edit")))

(mode-doc! "video-edit-page-mode"
  "The page of a video edit: the preview player, and a filmstrip and a waveform per segment. `n` and `p` select a segment, `R` names it and `d` deletes it from the edit. `r` writes a 720p preview and plays it here, `e` exports the finished mp4, `P` cuts the pauses out of the edit, `g` draws the page again, `o` shows the edit's text.")

(mode-doc! "video-edit-mode"
  "An edit as text: one line per piece you keep, START END FILE, played in order. Delete a line to drop a piece, move it to reorder, change a time to trim. `audio clean` or `audio raw` and `size 2160`, `1080` or `720` set the whole edit. `C-c C-p` cuts the pauses out, `C-c C-k` splits the piece on this line at a time you type, `C-c C-v` shows the page with a filmstrip and a waveform per segment, `C-c C-r` writes a 720p preview and plays it there, `C-c C-e` exports the finished mp4.")

(set! *auto-mode-alist* (cons (list ".vedit" "video-edit-mode") (filter (lambda (e) (not (equal? (car e) ".vedit"))) *auto-mode-alist*)))

(effects! '(pure))
(public! 'video-edit-parse-time "(video-edit-parse-time S) — seconds for 1:23.5, 0:01:23 or 83.5, else #f")
(catalog-meta! 'function "video-edit-parse-time" 'domain 'files 'effects '(pure))
(public! 'video-edit-format-time "(video-edit-format-time SECS) — SECS as m:ss.s")
(catalog-meta! 'function "video-edit-format-time" 'domain 'files 'effects '(pure))
(effects! '(read))
(public! 'video-edit-pieces "(video-edit-pieces BUF) — the edit's pieces in order, each (START END PATH)")
(catalog-meta! 'function "video-edit-pieces" 'domain 'files 'effects '(read))
(effects! '(write execute))
(public! 'video-edit-new "(video-edit-new PATH) — a new edit of the video or Cap recording PATH as NAME.vedit, the whole video one segment; answers its path")
(catalog-meta! 'function "video-edit-new" 'domain 'files 'effects '(write execute))
(public! 'video-edit-remove-pauses! "(video-edit-remove-pauses! BUF) — split every piece of BUF around its pauses, in a task")
(catalog-meta! 'function "video-edit-remove-pauses!" 'domain 'files 'effects '(write execute))
(public! 'video-edit-export-command "(video-edit-export-command BUF OUT HEIGHT PREVIEW?) — the ffmpeg command that writes BUF's edit to OUT")
(catalog-meta! 'function "video-edit-export-command" 'domain 'files 'effects '(write execute))

(provide 'video-edit)

;; undo and redo in every view of an edit; in the edit's own text the
;; buffer's undo stays
(define video-edit--undo-keys '(("C-/" "video-edit-undo") ("C-_" "video-edit-undo") ("C-x u" "video-edit-undo") ("s-z" "video-edit-undo") ("C-?" "video-edit-redo") ("C-M-_" "video-edit-redo") ("s-Z" "video-edit-redo")))
(for-each (lambda (m) (mode-keys! m video-edit--undo-keys)) '("video-edit-timeline-mode" "video-edit-page-mode" "video-transcript-mode"))

;; ---- the edit as Scheme data. A .vedit file holds one form, read and never run:
;;
;;   (edit (audio clean) (size 2160)
;;     (source "~/Movies/a.mp4"
;;       (cut 0 hidden) (cut 7.86) (cut 53.79 hidden muted "tangent")
;;       (dub 57.19 72.97 "~/Movies/a takes/take.wav")))
;;
;; A cut is (cut SECONDS [hidden] [muted] ["NAME"]) and owns its segment, to
;; the next cut or the end. Every change reads the form, changes the data and
;; writes the form back: one undo step. A file in the older line form is read
;; the same, and written in this form on its first change.

(define (video-edit--round t) (/ (round (* 100 t)) 100))

(define (video-edit--parse-cut form)
  "(cut T . FLAGS) as (T HIDDEN MUTED NAME)"
  (let ((flags (cddr form)))
    (list (cadr form) (and (memq 'hidden flags) #t) (and (memq 'muted flags) #t)
          (let find ((fs flags)) (cond ((null? fs) #f) ((string? (car fs)) (car fs)) (else (find (cdr fs)))))
          (let find ((fs flags)) (cond ((null? fs) #f) ((and (pair? (car fs)) (eq? (car (car fs)) 'mark)) (cadr (car fs))) (else (find (cdr fs))))))))

(define (video-edit--legacy-data text)
  "an edit in the older line form, as data"
  (let loop ((ls (string-split text "\n")) (settings '()) (sources '()))
    (if (null? ls)
        (list (reverse settings) (reverse (map (lambda (s) (list (car s) (sort (cadr s)) (reverse (caddr s)))) sources)))
        (let* ((l (string-trim (car ls))) (w (string-split l " "))
               (src (video-edit--source l)) (cut (video-edit--cut-info l)) (dub (video-edit--dub l)))
          (cond (src (loop (cdr ls) settings (cons (list src '() '()) sources)))
                ((and cut (pair? sources))
                 (let ((s (car sources)))
                   (loop (cdr ls) settings (cons (list (car s) (cons (list (car cut) (cadr cut) (video-edit--cut-muted? l) (caddr cut)) (cadr s)) (caddr s)) (cdr sources)))))
                ((and dub (pair? sources))
                 (let ((s (car sources))) (loop (cdr ls) settings (cons (list (car s) (cadr s) (cons dub (caddr s))) (cdr sources)))))
                ((and (= (length w) 2) (member (car w) '("audio" "size")))
                 (loop (cdr ls) (cons (list (string->symbol (car w)) (or (string->number (cadr w)) (string->symbol (cadr w)))) settings) sources))
                (else (loop (cdr ls) settings sources)))))))

(define (video-edit-read buf)
  "(video-edit-read BUF) -- BUF's edit as data: (SETTINGS SOURCES); SETTINGS a list of (KEY VALUE), each source (PATH CUTS DUBS), a cut (T HIDDEN MUTED NAME), a dub (START END FILE), paths full"
  (let* ((text (buffer-text buf))
         (forms (and (string-search "(edit" text) (scheme-read text)))
         (edit (and (pair? forms) (let find ((fs forms)) (cond ((null? fs) #f) ((and (pair? (car fs)) (eq? (car (car fs)) 'edit)) (car fs)) (else (find (cdr fs))))))))
    (if (not edit)
        (video-edit--legacy-data text)
        (let loop ((xs (cdr edit)) (settings '()) (sources '()))
          (if (null? xs) (list (reverse settings) (reverse sources))
              (let ((x (car xs)))
                (cond ((and (pair? x) (eq? (car x) 'source))
                       (loop (cdr xs) settings
                             (cons (list (expand-file-name (cadr x))
                                         (sort (map video-edit--parse-cut (filter (lambda (y) (and (pair? y) (eq? (car y) 'cut))) (cddr x))))
                                         (map (lambda (y) (list (cadr y) (caddr y) (expand-file-name (cadddr y)))) (filter (lambda (y) (and (pair? y) (eq? (car y) 'dub))) (cddr x)))
                                         (let ((t (let find ((ys (cddr x))) (cond ((null? ys) #f) ((and (pair? (car ys)) (eq? (car (car ys)) 'title)) (car ys)) (else (find (cdr ys))))))) (and t (cadr t))))
                                   sources)))
                      ((pair? x) (loop (cdr xs) (cons x settings) sources))
                      (else (loop (cdr xs) settings sources)))))))))

(define (video-edit--form-text data)
  "DATA written as the edit form, one part a line"
  (let ((num (lambda (t) (number->string (video-edit--round t)))))
    (string-append
      ";; video-edit: the videos in play order and the cuts in them. A cut owns its segment,\n"
      ";; to the next cut or the end: (cut SECONDS [hidden] [muted] [\"NAME\"]).\n"
      "(edit"
      (apply string-append (map (lambda (s) (string-append "\n  " (format "~s" s))) (car data)))
      (apply string-append
        (map (lambda (s)
               (string-append "\n  (source " (format "~s" (abbreviate-file-name (car s)))
                 (if (and (> (length s) 3) (string? (cadddr s))) (string-append "\n    (title " (format "~s" (cadddr s)) ")") "")
                 (apply string-append (map (lambda (d) (string-append "\n    (dub " (num (car d)) " " (num (cadr d)) " " (format "~s" (abbreviate-file-name (caddr d))) ")")) (caddr s)))
                 (apply string-append (map (lambda (c) (string-append "\n    (cut " (num (car c)) (if (cadr c) " hidden" "") (if (caddr c) " muted" "")
                                                                     (if (and (string? (cadddr c)) (not (equal? (cadddr c) ""))) (string-append " " (format "~s" (cadddr c))) "")
                                                                     (if (and (> (length c) 4) (list-ref c 4)) (string-append " (mark " (number->string (list-ref c 4)) ")") "") ")"))
                                           (cadr s)))
                 ")"))
             (cadr data)))
      ")\n")))

(define (video-edit-write! buf data)
  "(video-edit-write! BUF DATA) -- put DATA into BUF as the edit form: one undo step"
  (video-edit--set-text! buf (video-edit--form-text (list (car data) (map (lambda (s) (list (car s) (sort (cadr s)) (caddr s) (and (> (length s) 3) (cadddr s)))) (cadr data))))))

(define (video-edit--update-source! buf path f)
  "rewrite the source PATH of BUF as (F CUTS DUBS) answers it, (CUTS DUBS)"
  (let ((data (video-edit-read buf)))
    (video-edit-write! buf (list (car data) (map (lambda (s) (if (equal? (car s) path) (append (cons (car s) (f (cadr s) (caddr s))) (list (and (> (length s) 3) (cadddr s)))) s)) (cadr data))))))

(define (video-edit--state-at cuts t)
  "the cut whose segment holds T, or #f before the first cut"
  (let loop ((cs cuts) (best #f)) (cond ((null? cs) best) ((<= (car (car cs)) (+ t 0.001)) (loop (cdr cs) (car cs))) (else best))))

;; the structure every view reads, now from the data
(define (video-edit-structure buf)
  "(video-edit-structure BUF) -- each source of BUF: ((PATH CLIPS CUTS DUBS MUTES) ...). CUTS are times; CLIPS are the hidden segments (START END hidden NAME #f #f); DUBS (START END FILE #f #f); MUTES (START END)."
  (map (lambda (s)
         (let* ((path (car s)) (cuts (cadr s)) (d (or (video-edit--dur path) 0))
                (spans (let walk ((cs cuts) (acc '()))
                         (if (null? cs) (reverse acc)
                             (walk (cdr cs) (cons (list (car (car cs)) (if (pair? (cdr cs)) (car (cadr cs)) d) (car cs)) acc))))))
           (list path
                 (filter pair? (map (lambda (sp) (and (cadr (caddr sp)) (> (cadr sp) (+ (car sp) 0.01)) (list (car sp) (cadr sp) 'hidden (cadddr (caddr sp)) #f #f))) spans))
                 (map car cuts)
                 (map (lambda (dd) (list (car dd) (cadr dd) (caddr dd) #f #f)) (caddr s))
                 (filter pair? (map (lambda (sp) (and (caddr (caddr sp)) (> (cadr sp) (+ (car sp) 0.01)) (list (car sp) (cadr sp)))) spans)))))
       (cadr (video-edit-read buf))))

(define (video-edit--setting buf key default)
  (let ((hit (assoc (string->symbol key) (car (video-edit-read buf)))))
    (if hit (let ((v (cadr hit))) (if (symbol? v) (symbol->string v) (number->string v))) default)))

(define (video-edit--hidden-at? buf path t)
  (let ((s (assoc path (cadr (video-edit-read buf))))) (let ((c (and s (video-edit--state-at (cadr s) t)))) (and c (cadr c)))))
(define (video-edit--muted-at? buf path t)
  (let ((s (assoc path (cadr (video-edit-read buf))))) (let ((c (and s (video-edit--state-at (cadr s) t)))) (and c (caddr c)))))

(define (video-edit-add-cut! buf path t)
  "(video-edit-add-cut! BUF PATH T) -- cut the source PATH at T: the segment there becomes two, both as it was"
  (video-edit--update-source! buf path
    (lambda (cuts dubs)
      (if (let any ((cs cuts)) (and (pair? cs) (or (< (abs (- (car (car cs)) t)) 0.02) (any (cdr cs))))) (list cuts dubs)
          (let ((c (video-edit--state-at cuts t)))
            (list (cons (list (video-edit--round t) (and c (cadr c)) (and c (caddr c)) #f) cuts) dubs))))))

(define (video-edit-remove-cut! buf path t)
  "(video-edit-remove-cut! BUF PATH T) -- remove PATH's cut nearest T, within half a second; its segment joins the one before"
  (video-edit--update-source! buf path
    (lambda (cuts dubs)
      (let ((near (let find ((cs cuts) (best #f) (bd 0.5)) (cond ((null? cs) best) ((< (abs (- (car (car cs)) t)) bd) (find (cdr cs) (car cs) (abs (- (car (car cs)) t)))) (else (find (cdr cs) best bd))))))
        (list (filter (lambda (c) (not (eq? c near))) cuts) dubs)))))

(define (video-edit-move-cut! buf path from to)
  "(video-edit-move-cut! BUF PATH FROM TO) -- move PATH's cut at FROM to TO; its state and name go with it"
  (video-edit--update-source! buf path
    (lambda (cuts dubs)
      (list (map (lambda (c) (if (< (abs (- (car c) from)) 0.02) (cons (video-edit--round to) (cdr c)) c)) cuts) dubs))))

(define (video-edit--set-flag! buf path a b which value name)
  "cut PATH at A and B and set WHICH (hidden or muted) to VALUE on every segment between; NAME goes on the cut at A"
  (let ((d (or (video-edit--dur path) b)))
    (video-edit--update-source! buf path
      (lambda (cuts dubs)
        (let* ((ensure (lambda (cuts t) (if (let any ((cs cuts)) (and (pair? cs) (or (< (abs (- (car (car cs)) t)) 0.02) (any (cdr cs))))) cuts
                                             (let ((c (video-edit--state-at cuts t))) (sort (cons (list (video-edit--round t) (and c (cadr c)) (and c (caddr c)) #f) cuts))))))
               (cuts (if (or value (> a 0.02)) (ensure cuts (max 0 a)) cuts))
               (cuts (if (< b (- d 0.02)) (ensure cuts b) cuts)))
          (list (map (lambda (c)
                       (if (and (>= (car c) (- a 0.02)) (< (car c) (- b 0.02)))
                           (list (car c)
                                 (if (eq? which 'hidden) value (cadr c))
                                 (if (eq? which 'muted) value (caddr c))
                                 (if (and name (< (abs (- (car c) a)) 0.02)) name (cadddr c))
                                 (and (> (length c) 4) (list-ref c 4)))
                           c))
                     cuts)
                dubs))))))

(define (video-edit--all? buf path a b which)
  "is all of A..B of PATH WHICH (hidden or muted)?"
  (let* ((s (assoc path (cadr (video-edit-read buf)))) (cuts (if s (cadr s) '()))
         (flag (lambda (c) (and c (if (eq? which 'hidden) (cadr c) (caddr c))))))
    (and (flag (video-edit--state-at cuts (+ a 0.01)))
         (let all ((cs cuts)) (or (null? cs) (and (or (not (and (> (car (car cs)) (+ a 0.01)) (< (car (car cs)) (- b 0.02)))) (flag (car cs))) (all (cdr cs))))))))

(define (video-edit-toggle-hidden! buf path a b)
  "(video-edit-toggle-hidden! BUF PATH A B) -- A..B all hidden: show it; else hide it. Answers #t when it hid."
  (let ((hide (not (video-edit--all? buf path a b 'hidden))))
    (video-edit--set-flag! buf path a b 'hidden hide #f)
    hide))

(define (video-edit-toggle-muted! buf path a b)
  "(video-edit-toggle-muted! BUF PATH A B) -- A..B all muted: give it its sound back; else mute it. Answers #t when it muted."
  (let ((mute (not (video-edit--all? buf path a b 'muted))))
    (video-edit--set-flag! buf path a b 'muted mute #f)
    mute))

(define (video-edit-add-clip! buf path a b state name)
  "(video-edit-add-clip! BUF PATH A B STATE NAME) -- hide A..B of PATH (STATE hidden); NAME goes on the cut at A"
  (if (equal? state 'hidden) (video-edit--set-flag! buf path a b 'hidden #t name)
      (video-edit--set-flag! buf path a b 'hidden #f name)))

(define (video-edit-set-clip! buf clip state name)
  "(video-edit-set-clip! BUF CLIP STATE NAME) -- a hidden segment from video-edit-structure: STATE hidden keeps it hidden, anything else shows it; NAME names its cut"
  (let ((path (let find ((ss (video-edit-structure buf))) (cond ((null? ss) #f) ((member clip (cadr (car ss))) (car (car ss))) (else (find (cdr ss)))))))
    (when path (video-edit--set-flag! buf path (car clip) (cadr clip) 'hidden (equal? state 'hidden) name))))

(define (video-edit-add-dub! buf path a b file)
  "(video-edit-add-dub! BUF PATH A B FILE) -- lay the take FILE over A..B of PATH"
  (video-edit--update-source! buf path (lambda (cuts dubs) (list cuts (append dubs (list (list (video-edit--round a) (video-edit--round b) file)))))))

(define (video-edit-remove-dub! buf path a)
  "(video-edit-remove-dub! BUF PATH A) -- take out PATH's take that starts nearest A"
  (video-edit--update-source! buf path (lambda (cuts dubs) (list cuts (filter (lambda (d) (not (< (abs (- (car d) a)) 0.05))) dubs)))))

(define (video-edit-move-source! buf i dir)
  "(video-edit-move-source! BUF I DIR) -- move source I one place earlier (-1) or later (1)"
  (let* ((data (video-edit-read buf)) (ss (cadr data)) (n (length ss)) (j (+ i dir)))
    (when (and (>= i 0) (>= j 0) (< i n) (< j n))
      (video-edit-write! buf (list (car data) (let loop ((k 0) (r ss)) (if (null? r) '() (cons (cond ((= k i) (list-ref ss j)) ((= k j) (list-ref ss i)) (else (car r))) (loop (+ k 1) (cdr r))))))))))

(define (video-edit-remove-source! buf i)
  "(video-edit-remove-source! BUF I) -- take source I, its cuts and takes, out of BUF"
  (let ((data (video-edit-read buf)))
    (video-edit-write! buf (list (car data) (let loop ((ss (cadr data)) (k 0)) (cond ((null? ss) '()) ((= k i) (cdr ss)) (else (cons (car ss) (loop (cdr ss) (+ k 1))))))))))

(define (video-edit-set-title! buf path title)
  "(video-edit-set-title! BUF PATH TITLE) -- the clip PATH is called TITLE in the project; #f or empty gives back its file name"
  (let ((data (video-edit-read buf)))
    (video-edit-write! buf (list (car data) (map (lambda (s) (if (equal? (car s) path) (list (car s) (cadr s) (caddr s) (and (string? title) (not (equal? (string-trim title) "")) (string-trim title))) s)) (cadr data))))))

(define (video-edit-title buf path)
  "(video-edit-title BUF PATH) -- what the clip PATH is called: its title, else its file name without the ending"
  (let* ((s (assoc path (cadr (video-edit-read buf)))) (t (and s (> (length s) 3) (cadddr s))))
    (or t (let* ((n (file-name-nondirectory path)) (dot (string-rindex n "."))) (if dot (substring n 0 dot) n)))))

(define (video-edit-set-mark! buf path t n)
  "(video-edit-set-mark! BUF PATH T N) -- bookmark N on PATH's cut at T; the number leaves any other cut"
  (let ((data (video-edit-read buf)))
    (video-edit-write! buf
      (list (car data)
            (map (lambda (s)
                   (append (list (car s)
                                 (map (lambda (c)
                                        (let ((here (and (equal? (car s) path) (< (abs (- (car c) t)) 0.02)))
                                              (had (and (> (length c) 4) (list-ref c 4))))
                                          (list (car c) (cadr c) (caddr c) (cadddr c) (cond (here n) ((equal? had n) #f) (else had)))))
                                      (cadr s))
                                 (caddr s))
                           (list (and (> (length s) 3) (cadddr s)))))
                 (cadr data))))))

(define (video-edit-find-mark buf n)
  "(video-edit-find-mark BUF N) -- the cut bookmarked N: (SOURCE-INDEX TIME), or #f"
  (let loop ((ss (cadr (video-edit-read buf))) (i 0))
    (if (null? ss) #f
        (let ((t (let find ((cs (cadr (car ss)))) (cond ((null? cs) #f) ((and (> (length (car cs)) 4) (equal? (list-ref (car cs) 4) n)) (car (car cs))) (else (find (cdr cs)))))))
          (if t (list i t) (loop (cdr ss) (+ i 1)))))))

(define (video-edit--append-source! buf video)
  (let ((data (video-edit-read buf)))
    (video-edit-write! buf (list (car data) (append (cadr data) (list (list (expand-file-name video) '() '() #f)))))))

;; every change to an edit's text is one undo step
(for-each
  (lambda (name)
    (advice-add! name 'around 'video-edit-one-step
      (lambda (next buf . args) (video-edit--one-step buf (lambda () (apply next (cons buf args)))))))
  '(video-edit-add-clip! video-edit-set-clip! video-edit-add-cut! video-edit-remove-cut! video-edit-move-cut! video-edit-toggle-hidden! video-edit-toggle-muted! video-edit-add-dub! video-edit-remove-dub! video-edit--set-text!))

;; ---- imenu: the edit's parts as an index. In the file a row goes to its
;; line; when the timeline is open it also puts the playhead there, and in
;; the timeline itself browsing the index moves the playhead as you go.
(define (video-edit--seek-thunk edit i t &optional select)
  "move the timeline's playhead to T in source I; SELECT #t also chooses what is there, a cut or a hidden part"
  (lambda ()
    (let ((tl (video-edit--timeline-name edit)))
      (when (buffer-known? tl) (app-post! tl (list 'seek (list 'src i 't t 'select (if select #t #f))))))))

(define (video-edit--imenu-rows-for edit line?)
  "the index of EDIT: videos, cuts and takes; LINE? keeps each row's line in the file, else 1"
  (let* ((lines (string-split (buffer-text edit) "\n"))
         (line-of (lambda (needle from) (let loop ((ls lines) (n 1)) (cond ((null? ls) 1) ((and (>= n from) (string-contains? (car ls) needle)) n) (else (loop (cdr ls) (+ n 1)))))))
         (num (lambda (t) (number->string (video-edit--round t))))
         (data (video-edit-read edit)))
    (let loop ((ss (cadr data)) (i 0) (acc '()))
      (if (null? ss) (reverse acc)
          (let* ((s (car ss)) (src-line (line-of (abbreviate-file-name (car s)) 1)) (at (lambda (needle) (if line? (line-of needle src-line) 1)))
                 (rows (append
                         (list (list (if line? src-line 1) "video" (string-append (number->string (+ i 1)) ". " (file-name-nondirectory (car s))) (video-edit-format-time (or (video-edit--dur (car s)) 0)) (video-edit--seek-thunk edit i 0)))
                         (map (lambda (c) (list (at (string-append "(cut " (num (car c)))) "cut"
                                                (string-append "✂ " (video-edit-format-time (car c)) (if (cadr c) " hidden" "") (if (caddr c) " muted" "") (if (cadddr c) (string-append " “" (cadddr c) "”") ""))
                                                "" (video-edit--seek-thunk edit i (car c) #t)))
                              (cadr s))
                         (map (lambda (d) (list (at (string-append "(dub " (num (car d)))) "take" (string-append "🎙 " (video-edit-format-time (car d)) " → " (video-edit-format-time (cadr d))) "" (video-edit--seek-thunk edit i (car d)))) (caddr s)))))
            (loop (cdr ss) (+ i 1) (append (reverse rows) acc)))))))

(define (video-edit--imenu-rows buf)
  (let ((rows (video-edit--imenu-rows-for buf #t)))
    (map (lambda (r) (if (> (length r) 4) r r)) rows)))

(define (video-edit--segment-rows edit)
  "every segment of EDIT: each video from cut to cut, the first from its start and the last to its end; hidden parts do not split them"
  (let ((n 0) (acc '()))
    (let loop ((ss (video-edit-structure edit)) (i 0))
      (unless (null? ss)
        (let* ((s (car ss)) (path (car s)) (d (or (video-edit--dur path) 0))
               (hidden (filter (lambda (c) (equal? (caddr c) 'hidden)) (cadr s)))
               (points (append (list 0) (filter (lambda (c) (and (> c 0.01) (< c (- d 0.01)))) (caddr s)) (list d)))
               (ws (video-edit-words edit path))
               (plays (filter (lambda (p) (equal? (caddr p) path)) (video-edit-pieces edit))))
          (let walk ((ps points))
            (when (and (pair? ps) (pair? (cdr ps)))
              (let* ((a (car ps)) (b (cadr ps))
                     (kept (apply + (map (lambda (p) (max 0 (- (min b (cadr p)) (max a (car p))))) plays)))
                     (in (if (pair? ws) (filter (lambda (w) (and (>= (car w) (- a 0.05)) (< (car w) b))) ws) '()))
                     (said (string-join (map caddr (list-head in (min 7 (length in)))) " ")))
                (when (> (- b a) 0.05)
                  (set! n (+ n 1))
                  (set! acc (cons (list 1 "segment"
                                        (string-append (number->string n) ". [" (number->string (+ i 1)) "] " (video-edit-format-time a) " → " (video-edit-format-time b)
                                                       "  " said)
                                        (video-edit-format-time (- b a))
                                        (let ((tl (video-edit--timeline-name edit)))
                                          (lambda () (when (buffer-known? tl) (app-post! tl (list 'seek (list 'src i 't a 'select "segment")))))))
                                  acc)))
                (walk (cdr ps)))))
          (loop (cdr ss) (+ i 1)))))
    (reverse acc)))

(define (video-edit--pause-rows edit)
  "each pause of EDIT, by clip, time, length and the word after it; picking one chooses it"
  (let ((tl (video-edit--timeline-name edit)))
    (let loop ((ss (video-edit-structure edit)) (i 0) (acc '()))
      (if (null? ss) (reverse acc)
          (loop (cdr ss) (+ i 1)
                (append (reverse (map (lambda (p)
                                        (list 1 "pause"
                                              (string-append "[" (number->string (+ i 1)) "] " (video-edit-format-time (car p)) "  ⏸ " (number->string (video-edit--round (- (cadr p) (car p)))) " s  before “" (caddr p) "”")
                                              ""
                                              (lambda () (when (buffer-known? tl) (app-post! tl (list 'seek (list 'src i 't (car p) 'b (cadr p) 'select "pause")))))))
                                      (video-edit--pauses edit i)))
                        acc))))))

(define (video-edit--timeline-imenu-rows buf)
  "the timeline's index: the edit's segments and parts, and each line of every transcript by its time"
  (let* ((edit (buffer-local-value 'video-edit-timeline-of buf))
         (lines (if (not (boundp 'video-transcript-words)) '()
                    (let loop ((ss (video-edit-structure edit)) (i 0) (acc '()))
                      (if (null? ss) (reverse acc)
                          (let ((ws (video-edit-words edit (car (car ss)))))
                            (loop (cdr ss) (+ i 1)
                                  (append (reverse (map (lambda (l)
                                                          (list 1 "line" (string-append "[" (number->string (+ i 1)) " " (video-edit-format-time (car (car l))) "] "
                                                                                         (string-join (map caddr (list-head l (min 9 (length l)))) " "))
                                                                "" (video-edit--seek-thunk edit i (car (car l)))))
                                                        (if (pair? ws) (video-transcript--lines ws) '())))
                                          acc))))))))
    (append (video-edit--segment-rows edit) (video-edit--pause-rows edit) (video-edit--imenu-rows-for edit #f) lines)))

(define (video-edit--imenu-setup!)
  (let ((b (current-buffer)))
    (buffer-set-local! b 'imenu-index-function
      (if (equal? (buffer-local-value 'mode-name b) "video-edit-timeline-mode") 'video-edit--timeline-imenu-rows 'video-edit--imenu-rows))))


;; ---- edits from before cuts carried their state: their clip lines become cuts
(define (video-edit-migrate-to-cuts! buf)
  "(video-edit-migrate-to-cuts! BUF) -- turn BUF's clip lines into cuts. Hidden parts are merged where they overlap; each place hiding starts or stops becomes a cut, snapped onto one of your cuts within a quarter second, and the cut that starts hiding is marked hidden. Answers how many clip lines went."
  (let* ((hb (video-edit--blocks buf)) (gone 0)
         (blocks
           (map (lambda (block)
                  (let* ((path (video-edit--source (car block)))
                         (rest (cdr block))
                         (clips (filter pair? (map video-edit--clip rest)))
                         (cuts (filter pair? (map video-edit--cut-info rest)))
                         (cut-times (map car cuts))
                         (d (or (video-edit--dur path) 0))
                         (snap (lambda (t) (let find ((cs cut-times) (best t) (bd 0.25))
                                             (cond ((null? cs) best) ((< (abs (- (car cs) t)) bd) (find (cdr cs) (car cs) (abs (- (car cs) t)))) (else (find (cdr cs) best bd))))))
                         ;; the hidden stretches: old cut flags and old clip lines, merged, edges snapped
                         (spans (append (map (lambda (c) (list (car c) (cadr c))) (filter (lambda (c) (equal? (caddr c) 'hidden)) clips))
                                        (let walk ((cs (sort (map (lambda (c) (list (car c) (if (cadr c) 1 0))) cuts))) (acc '()))
                                          (if (null? cs) acc
                                              (walk (cdr cs) (if (= (cadr (car cs)) 1) (cons (list (car (car cs)) (if (pair? (cdr cs)) (car (cadr cs)) d)) acc) acc))))))
                         (union (let merge ((cs (sort (map (lambda (s) (list (snap (car s)) (if (>= (cadr s) (- d 0.02)) d (snap (cadr s))))) spans))) (acc '()))
                                  (cond ((null? cs) (reverse acc))
                                        ((and (pair? acc) (<= (car (car cs)) (+ (cadr (car acc)) 0.02)))
                                         (merge (cdr cs) (cons (list (car (car acc)) (max (cadr (car acc)) (cadr (car cs)))) (cdr acc))))
                                        (else (merge (cdr cs) (cons (car cs) acc))))))
                         (times (let uniq ((ts (sort (filter (lambda (t) (and (>= t 0) (< t (- d 0.02))))
                                                             (append cut-times (apply append (map (lambda (u) (list (car u) (cadr u))) union))))))
                                           (acc '()))
                                  (cond ((null? ts) (reverse acc))
                                        ((and (pair? acc) (< (- (car ts) (car acc)) 0.02)) (uniq (cdr ts) acc))
                                        (else (uniq (cdr ts) (cons (car ts) acc))))))
                         (new-cuts
                           (let walk ((ts times) (acc '()))
                             (if (null? ts) (reverse acc)
                                 (let* ((a (car ts)) (b (if (pair? (cdr ts)) (cadr ts) d)) (mid (/ (+ a b) 2))
                                        (h (let any ((us union)) (and (pair? us) (or (and (>= mid (car (car us))) (< mid (cadr (car us)))) (any (cdr us))))))
                                        (old (let find ((cs cuts)) (cond ((null? cs) #f) ((< (abs (- (car (car cs)) a)) 0.02) (car cs)) (else (find (cdr cs))))))
                                        (named (let find ((cs clips)) (cond ((null? cs) #f) ((and (< (abs (- (snap (car (car cs))) a)) 0.02) (cadddr (car cs))) (cadddr (car cs))) (else (find (cdr cs))))))
                                        (name (or (and old (caddr old)) named)))
                                   (walk (cdr ts) (cons (video-edit--cut-text a h name) acc))))))
                         (others (filter (lambda (l) (not (or (video-edit--clip l) (video-edit--cut-info l) (equal? (string-trim l) "")))) rest)))
                    (set! gone (+ gone (length clips)))
                    (append (list (car block)) others new-cuts)))
                (cdr hb))))
    (when (> gone 0) (video-edit--set-blocks! buf (cons (car hb) blocks)))
    gone))

(define-command "video-edit-timeline-save" "Save the edit"
  (lambda () (let ((e (buffer-local-value 'video-edit-timeline-of (current-buffer))))
               (with-current-buffer e (lambda () (buffer-save!)))
               (message "Edit saved")))
  'modes '(video-edit-timeline-mode))
(mode-keys! "video-edit-timeline-mode" '(("s-s" "video-edit-timeline-save")))

(define-command "video-edit-timeline-rename" "Name the clip shown: the project calls it that"
  (lambda ()
    (let* ((tl (current-buffer)) (edit (buffer-local-value 'video-edit-timeline-of tl))
           (i (video-edit--tl tl "shown" 0)) (path (video-edit--src-path edit i)))
      (when path
        (read-string (string-append "Name for " (file-name-nondirectory path) " (empty: its file name): ")
          (lambda (s) (video-edit-set-title! edit path s) (video-edit--refresh-views! edit) (message (string-append "Clip " (number->string (+ i 1)) " is " (video-edit-title edit path))))
          'initial (video-edit-title edit path)))))
  'modes '(video-edit-timeline-mode))
(mode-keys! "video-edit-timeline-mode" '(("R" "video-edit-timeline-rename")))

;; a text scale step on the timeline buffer reaches its page at once
(advice-add! 'text-scale-apply! 'after 'video-edit-timeline-scale
  (lambda (buf n)
    (let ((edit (buffer-local-value 'video-edit-timeline-of buf)))
      (when (and edit (buffer-known? edit)) (video-edit--timeline-push! edit)))))
