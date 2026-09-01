;;; agenda.scm --- the morg agenda: a week of dated entries, as cards.
;;;
;;; morg files carry org-style timestamps: <2026-08-17>, <2026-08-17 Mon>,
;;; <2026-08-17 14:00>. A heading line with a timestamp is an entry on
;;; that date. A body line that starts with SCHEDULED: or DEADLINE: makes
;;; an entry for the nearest heading above it. A scheduled or deadline
;;; entry whose date passed and whose state is not DONE shows on today,
;;; marked late.
;;;
;;; The buffer text is the plain agenda listing — one line per entry. The
;;; card view is a projection of the same lines (render-mode "blocks",
;;; the diff-mode pattern), composed from catalogued ui/* components.
;;; The scan caches per file by mtime; an open buffer reads live instead,
;;; so unsaved edits appear.
;;;
;;; OFFSET RULE: every index into file or buffer text is a BYTE offset —
;;; use string-byte-length and substring-bytes, never string-length or
;;; substring.
;;;
;;; Keys (buffer-local):
;;;   n/p next/previous entry · RET visit the entry · TAB fold the day
;;;   [ / ] previous/next week · . back to today
;;;   g refresh · q quit · C-c C-v the plain listing

(domain! 'writing)
(effects! '(read))

(defcustom 'morg-agenda-files '()
  "Files and directories the agenda reads. A directory contributes every .md file under it.")

(defcustom 'morg-agenda-days 7
  "The number of days the agenda shows, starting today.")

;;; --- civil dates -------------------------------------------------------------
;;; Days since 1970-01-01 ("z") is the working representation. The two
;;; conversions are the standard era arithmetic. dow 0 is Sunday.

(define (agenda--z y m d)
  (let* ((y2 (if (<= m 2) (- y 1) y))
         (era (quotient (if (>= y2 0) y2 (- y2 399)) 400))
         (yoe (- y2 (* era 400)))
         (mp (modulo (+ m 9) 12))
         (doy (+ (quotient (+ (* 153 mp) 2) 5) (- d 1)))
         (doe (- (+ (* yoe 365) (quotient yoe 4) doy) (quotient yoe 100))))
    (- (+ (* era 146097) doe) 719468)))

(define (agenda--civil z)
  (let* ((z2 (+ z 719468))
         (era (quotient (if (>= z2 0) z2 (- z2 146096)) 146097))
         (doe (- z2 (* era 146097)))
         (yoe (quotient (- (+ doe (quotient doe 36524))
                          (+ (quotient doe 1460) (quotient doe 146096)))
                        365))
         (y (+ yoe (* era 400)))
         (doy (- doe (- (+ (* 365 yoe) (quotient yoe 4)) (quotient yoe 100))))
         (mp (quotient (+ (* 5 doy) 2) 153))
         (d (+ (- doy (quotient (+ (* 153 mp) 2) 5)) 1))
         (m (+ mp (if (< mp 10) 3 -9))))
    (list (if (<= m 2) (+ y 1) y) m d)))

(define (agenda--dow z) (modulo (+ z 4) 7))

(define *agenda-day-names*
  (list "Sunday" "Monday" "Tuesday" "Wednesday" "Thursday" "Friday" "Saturday"))
(define *agenda-month-names*
  (list "January" "February" "March" "April" "May" "June" "July"
        "August" "September" "October" "November" "December"))

;; local time comes from the system; everything after is pure arithmetic
(define (agenda--today-z)
  (let* ((s (string-trim (shell-command->string "date +%F")))
         (p (string-split s "-"))
         (y (string->number (car p)))
         (m (string->number (cadr p)))
         (d (string->number (caddr p))))
    (if (and (number? y) (number? m) (number? d))
        (agenda--z y m d)
        0)))

(define (agenda--day-label z)
  (let ((c (agenda--civil z)))
    (string-append (nth (agenda--dow z) *agenda-day-names*) " "
                   (number->string (caddr c)) " "
                   (nth (- (cadr c) 1) *agenda-month-names*))))

;;; --- the scan ----------------------------------------------------------------

;; first active timestamp on LINE -> (z time-or-#f), else #f
(define (agenda--timestamp line)
  (let ((g (re-groups "<([0-9]{4})-([0-9]{2})-([0-9]{2})([^>]*)>" line 0)))
    (and g
         (let* ((sub (lambda (r) (substring-bytes line (car r) (cadr r))))
                (y (string->number (sub (nth 1 g))))
                (m (string->number (sub (nth 2 g))))
                (d (string->number (sub (nth 3 g))))
                (rest (sub (nth 4 g)))
                (tg (re-groups "([0-9]{1,2}:[0-9]{2})" rest 0)))
           (and (number? y) (number? m) (number? d)
                (list (agenda--z y m d)
                      (and tg (substring-bytes rest
                                               (car (nth 1 tg))
                                               (cadr (nth 1 tg))))))))))

;; every <...> timestamp removed, for a clean title
(define (agenda--strip-stamps s)
  (let ((g (re-groups "<[0-9]{4}-[0-9]{2}-[0-9]{2}[^>]*>" s 0)))
    (if (not g)
        s
        (agenda--strip-stamps
          (string-append (substring-bytes s 0 (car (car g)))
                         (substring-bytes s (cadr (car g))
                                          (string-byte-length s)))))))

;; heading line -> (todo title tags): #s, the keyword, trailing :tags:
;; and timestamps all stripped from the title
(define (agenda--heading-parts line)
  (let* ((len (lambda (s) (string-byte-length s)))
         (hg (re-groups "^#{1,6}[ \t]+" line 0))
         (bare (if hg (substring-bytes line (cadr (car hg)) (len line)) line))
         (kw (re-groups "^(TODO|DONE)[ \t]+" bare 0))
         (todo (and kw (substring-bytes bare (car (nth 1 kw)) (cadr (nth 1 kw)))))
         (rest (if kw (substring-bytes bare (cadr (car kw)) (len bare)) bare))
         (tg (re-groups "[ \t]((:[A-Za-z0-9_@-]+)+:)[ \t]*$" rest 0))
         (tags (and tg (substring-bytes rest (car (nth 1 tg)) (cadr (nth 1 tg)))))
         (body (if tg (substring-bytes rest 0 (car (car tg))) rest)))
    (list todo (string-trim (agenda--strip-stamps body)) tags)))

;; -> "scheduled" | "deadline" | #f
(define (agenda--planning-kind line)
  (let ((g (re-groups "^[ \t]*(SCHEDULED|DEADLINE):" line 0)))
    (and g (string-downcase
             (substring-bytes line (car (nth 1 g)) (cadr (nth 1 g)))))))

(define (agenda--basename path)
  (car (reverse (string-split path "/"))))

;; every dated entry in TEXT, in file order. The walk is fence-aware
;; through morg's own line predicates, so a # inside a code block is not
;; a heading. HEAD is (pos todo title tags) of the nearest heading.
(define (agenda--text-entries path text)
  (let loop ((ls (split-lines text)) (pos 0) (in #f) (head #f) (acc '()))
    (if (null? ls)
        (reverse acc)
        (let* ((line (car ls))
               (next (+ pos (string-byte-length line) 1)))
          (cond
            ((and in (morg-fence-close? line))
             (loop (cdr ls) next #f head acc))
            (in (loop (cdr ls) next in head acc))
            ((morg-fence-info line)
             (loop (cdr ls) next (morg-fence-info line) head acc))
            ((re-match "^#{1,6}[ \t]" line)
             (let* ((parts (agenda--heading-parts line))
                    (ts (agenda--timestamp line)))
               (loop (cdr ls) next #f
                     (cons pos parts)
                     (if ts
                         (cons (list 'z (car ts) 'time (cadr ts) 'kind "plain"
                                     'todo (car parts) 'title (cadr parts)
                                     'tags (caddr parts) 'file path 'pos pos)
                               acc)
                         acc))))
            ((agenda--planning-kind line)
             (let ((k (agenda--planning-kind line))
                   (ts (agenda--timestamp line)))
               (loop (cdr ls) next #f head
                     (if ts
                         (cons (list 'z (car ts) 'time (cadr ts) 'kind k
                                     'todo (and head (cadr head))
                                     'title (if head (caddr head)
                                                (agenda--basename path))
                                     'tags (and head (nth 3 head))
                                     'file path 'pos (if head (car head) pos))
                               acc)
                         acc))))
            (else (loop (cdr ls) next #f head acc)))))))

;; per-file cache keyed by mtime; an open buffer may hold unsaved edits,
;; so it reads live and skips the cache
(define *agenda-cache* '()) ; ((path mtime entries) ...)

(define (agenda--file-entries path)
  (if (buffer-exists? path)
      (agenda--text-entries path (buffer-text path))
      (let ((mt (file-mtime path))
            (hit (assoc path *agenda-cache*)))
        (if (and hit (equal? (cadr hit) mt))
            (caddr hit)
            (let* ((text (read-file path))
                   (es (if (string? text) (agenda--text-entries path text) '())))
              (set! *agenda-cache*
                (cons (list path mt es)
                      (remove (lambda (e) (equal? (car e) path)) *agenda-cache*)))
              es)))))

;; the configured files, plus .md files under the configured directories
;; (recursive; dot-entries are skipped)
(define (agenda--files)
  (let loop ((specs (map expand-path morg-agenda-files)) (acc '()))
    (cond ((null? specs) (reverse acc))
          ((file-directory? (car specs))
           (loop (cdr specs) (append (reverse (agenda--dir-files (car specs))) acc)))
          ((file-exists? (car specs)) (loop (cdr specs) (cons (car specs) acc)))
          (else (loop (cdr specs) acc)))))

(define (agenda--dir-files dir)
  (fold (lambda (acc n)
          (cond ((string-prefix? "." n) acc)
                ((string-suffix? "/" n)
                 (append acc
                   (agenda--dir-files
                     (string-append dir "/"
                       (substring-bytes n 0 (- (string-byte-length n) 1))))))
                ((or (string-suffix? ".md" n) (string-suffix? ".markdown" n))
                 (append acc (list (string-append dir "/" n))))
                (else acc)))
        '() (list-dir dir)))

;;; --- the week ----------------------------------------------------------------

(define (morg-todos--text-entries path text)
  (let loop ((lines (split-lines text)) (pos 0) (in-fence #f) (entries '()))
    (if (null? lines)
        (reverse entries)
        (let* ((line (car lines))
               (next (+ pos (string-byte-length line) 1)))
          (cond
            ((and in-fence (morg-fence-close? line))
             (loop (cdr lines) next #f entries))
            (in-fence
             (loop (cdr lines) next in-fence entries))
            ((morg-fence-info line)
             (loop (cdr lines) next (morg-fence-info line) entries))
            ((re-match "^\#{1,6}[ \t]" line)
             (let ((parts (agenda--heading-parts line)))
               (loop
                (cdr lines) next #f
                (if (equal? (car parts) "TODO")
                    (cons (list 'title (cadr parts)
                                'tags (caddr parts)
                                'file path
                                'pos pos)
                          entries)
                    entries))))
            (else
             (loop (cdr lines) next #f entries)))))))

(define (morg-todos--file-entries path)
  (let ((text (if (buffer-exists? path)
                  (buffer-text path)
                  (read-file path))))
    (if (string? text)
        (morg-todos--text-entries path text)
        '())))

(define (morg-todos--rows buf)
  (fold (lambda (entries path)
          (append entries (morg-todos--file-entries path)))
        '()
        (agenda--files)))

(define (morg-todos--key buf row)
  (string-append (plist-get row 'file) ":"
                 (number->string (plist-get row 'pos))))

(define (morg-todos--cells buf row)
  (list (plist-get row 'title)
        (or (plist-get row 'tags) "")
        (agenda--basename (plist-get row 'file))))

(define (agenda--iota start n)
  (let loop ((i 0) (acc '()))
    (if (>= i n) (reverse acc) (loop (+ i 1) (cons (+ start i) acc)))))

;; the 1-ary sort orders by term; the key list is (rank minutes title):
;; late first (most late first), then timed by clock, then the rest
(define (agenda--minutes t)
  (if (not t)
      100000
      (let* ((p (string-split t ":"))
             (h (string->number (car p)))
             (m (string->number (cadr p))))
        (if (and (number? h) (number? m)) (+ (* h 60) m) 100000))))

(define (agenda--day-sort es)
  (map cadr
       (sort (map (lambda (e)
                    (list (list (let ((l (plist-get e 'late)))
                                  (if l (- 0 l) 1))
                                (agenda--minutes (plist-get e 'time))
                                (or (plist-get e 'title) ""))
                          e))
                  es))))

;; -> ((z entry ...) ...), one element per shown day, starting at START.
;; When the view starts on today, a scheduled or deadline entry whose
;; date passed and whose state is not DONE lands on today with 'late set
;; to the day count. A shifted week shows every entry on its own day.
(define (agenda--week files today start ndays)
  (let* ((all (fold (lambda (acc f) (append acc (agenda--file-entries f)))
                    '() files))
         (collapse? (= start today))
         (shown
           (fold (lambda (acc e)
                   (let* ((z (plist-get e 'z))
                          (late? (and collapse?
                                      (< z today)
                                      (member (plist-get e 'kind)
                                              (list "scheduled" "deadline"))
                                      (not (equal? (plist-get e 'todo) "DONE")))))
                     (cond (late? (cons (append (list 'late (- today z)) e) acc))
                           ((and (>= z start) (< z (+ start ndays)))
                            (cons e acc))
                           (else acc))))
                 '() all)))
    (map (lambda (day)
           (cons day
                 (agenda--day-sort
                   (filter (lambda (e)
                             (if (plist-get e 'late)
                                 (= day today)
                                 (= (plist-get e 'z) day)))
                           shown))))
         (agenda--iota start ndays))))

;;; --- the view ----------------------------------------------------------------
;;; One pass builds four projections of the same week: the plain text, the
;;; line->entry index RET reads, the fold ranges of the closed days, and
;;; the component blocks the card view draws.

(effects! '(write))

(define *agenda-buffer* "*Agenda*")

(define (agenda--badge-word kind)
  (if (equal? kind "deadline") "DEADLINE" "SCHEDULED"))

(define (agenda--entry-text e)
  (string-append "  "
    (let ((late (plist-get e 'late)) (kind (plist-get e 'kind)))
      (cond (late (string-append (agenda--badge-word kind) " "
                                 (number->string late) "d late  "))
            ((equal? kind "plain") "")
            (else (string-append (agenda--badge-word kind) "  "))))
    (let ((t (plist-get e 'time))) (if t (string-append t "  ") ""))
    (let ((todo (plist-get e 'todo))) (if todo (string-append todo "  ") ""))
    (or (plist-get e 'title) "")
    (let ((tags (plist-get e 'tags))) (if tags (string-append "  " tags) ""))
    "  — " (agenda--basename (plist-get e 'file))))

(define (agenda--entry-row e line)
  (component 'ui/row
    (list 'class (if (equal? (plist-get e 'todo) "DONE")
                     "agenda-row agenda-row-done" "agenda-row")
          'click (string-append "e-" (number->string line))
          'lines (list line line) 'mark "current"
          'segs
          (append
            (list (list "agenda-time" (or (plist-get e 'time) "")))
            (let ((late (plist-get e 'late)) (kind (plist-get e 'kind)))
              (cond (late (list (list "agenda-badge agenda-late"
                                      (string-append (agenda--badge-word kind) " "
                                                     (number->string late) "d"))))
                    ((equal? kind "deadline")
                     (list (list "agenda-badge agenda-deadline" "DEADLINE")))
                    ((equal? kind "scheduled")
                     (list (list "agenda-badge agenda-scheduled" "SCHEDULED")))
                    (else '())))
            (let ((todo (plist-get e 'todo)))
              (cond ((equal? todo "TODO")
                     (list (list "agenda-badge agenda-todo" "TODO")))
                    ((equal? todo "DONE")
                     (list (list "agenda-badge agenda-done" "DONE")))
                    (else '())))
            (list (list "agenda-title" (or (plist-get e 'title) "")))
            (let ((tags (plist-get e 'tags)))
              (if tags (list (list "agenda-tags" tags)) '()))
            (list (list "agenda-file"
                        (agenda--basename (plist-get e 'file))))))))

(define (agenda--render! buf)
  (let* ((today (agenda--today-z))
         ;; the week offset in days: [ and ] move it, . zeroes it. It is
         ;; a plain local, so the selected week survives refresh and a
         ;; desktop restore of the mode.
         (start (+ today (or (buffer-local buf 'agenda-start-offset) 0)))
         (ndays (if (number? morg-agenda-days) morg-agenda-days 7))
         (files (agenda--files))
         (week (agenda--week files today start ndays))
         (closed (or (buffer-local buf 'agenda-closed-days) '()))
         (header (string-append "Agenda — " (agenda--day-label start))))
    (let loop ((days week)
               (text (string-append header "\n"))
               (line 2)
               (index '())
               (dlines '())
               (folds '())
               (blocks '()))
      (if (pair? days)
          (let* ((day (car (car days)))
                 (es (cdr (car days)))
                 (today? (= day today))
                 (head-line (agenda--day-label day))
                 (closed? (member day closed))
                 (dstart (string-byte-length text))
                 (r (let eloop ((es2 es)
                                (t2 (string-append text head-line "\n"))
                                (l2 (+ line 1)) (ix index) (rows '()))
                      (if (null? es2)
                          (list t2 l2 ix (reverse rows))
                          (let ((e (car es2)))
                            (eloop (cdr es2)
                                   (string-append t2 (agenda--entry-text e) "\n")
                                   (+ l2 1)
                                   (cons (list l2 (plist-get e 'file)
                                               (plist-get e 'pos))
                                         ix)
                                   (cons (agenda--entry-row e l2) rows))))))
                 (t3 (nth 0 r)) (l3 (nth 1 r))
                 (eol (+ dstart (string-byte-length head-line)))
                 (dend (string-byte-length t3)))
            (loop (cdr days) t3 l3 (nth 2 r)
                  (cons (list line day) dlines)
                  (if (and closed? (pair? es))
                      (cons (list eol (- dend 1)) folds)
                      folds)
                  (cons (component 'ui/card
                          (list 'class (if today?
                                           "agenda-day agenda-today"
                                           "agenda-day")
                                'title head-line
                                'badge (string-append
                                         (number->string (length es))
                                         (if today? " · today" ""))
                                'open? (not (and closed? #t))
                                'click (string-append "d-" (number->string day))
                                'lines (list line (- l3 1)) 'mark "current"
                                'body (nth 3 r)))
                        blocks)))
          (let ((p (buffer-point buf)))
            (buffer-set-read-only! buf #f)
            (buffer-delete-range! buf 0 (buffer-size buf))
            (buffer-append! buf text)
            (buffer-set-read-only! buf #t)
            ;; the rewrite must not move point: a fold toggle re-renders,
            ;; and the next toggle reads the day at point
            (buffer-goto! buf (min p (buffer-size buf)))
            (buffer-set-local! buf 'agenda-index (reverse index))
            (buffer-set-local! buf 'agenda-day-lines (reverse dlines))
            (buffer-set-local! buf 'render-blocks
              (if (pair? files)
                  (cons (list 'tag "div" 'class "agenda-header" 'text header)
                        (reverse blocks))
                  (list (component 'ui/empty
                          (list 'text "no agenda files — set them with (customize-save! 'morg-agenda-files (list \"~/notes\"))"
                                'class "agenda-empty")))))
            (fold-set! buf 'agenda (reverse folds)))))))

;;; --- where point is -----------------------------------------------------------

(define (agenda--line-number buf pos)
  (let loop ((ls (split-lines (buffer-text buf))) (n 1) (at 0))
    (cond ((null? ls) n)
          ((> (+ at (string-byte-length (car ls))) pos) n)
          (else (loop (cdr ls) (+ n 1) (+ at (string-byte-length (car ls)) 1))))))

(define (agenda--entry-at buf line)
  (assoc line (or (buffer-local buf 'agenda-index) '())))

;; the day whose header sits at or above LINE
(define (agenda--day-at buf line)
  (fold (lambda (acc d) (if (<= (car d) line) (cadr d) acc))
        #f (or (buffer-local buf 'agenda-day-lines) '())))

;;; --- commands ----------------------------------------------------------------

(define (agenda--visit! hit)
  (visit (cadr hit))
  (goto-char! (caddr hit)))

(define-command "agenda-visit" "Open the entry's file at its heading"
  (lambda ()
    (let* ((buf (current-buffer))
           (hit (agenda--entry-at buf (agenda--line-number buf (point)))))
      (if hit (agenda--visit! hit) (message "no entry here")))))

(define (agenda--step dir)
  (let* ((buf (current-buffer))
         (here (agenda--line-number buf (point)))
         (lines (map car (or (buffer-local buf 'agenda-index) '())))
         (cand (filter (lambda (l) (if (> dir 0) (> l here) (< l here))) lines))
         (best (fold (lambda (acc l)
                       (if (or (not acc) (if (> dir 0) (< l acc) (> l acc)))
                           l acc))
                     #f cand)))
    (if best
        (goto-char! (line-start-position best))
        (message "no more entries"))))

(define-command "agenda-next" "Move point to the next entry"
  (lambda () (agenda--step 1)))
(define-command "agenda-prev" "Move point to the previous entry"
  (lambda () (agenda--step -1)))

(define (agenda--toggle-day! buf day)
  (let ((closed (or (buffer-local buf 'agenda-closed-days) '())))
    (buffer-set-local! buf 'agenda-closed-days
      (if (member day closed)
          (filter (lambda (d) (not (equal? d day))) closed)
          (cons day closed)))
    (agenda--render! buf)))

(define-command "agenda-toggle-day" "Fold or unfold the day at point"
  (lambda ()
    (let* ((buf (current-buffer))
           (day (agenda--day-at buf (agenda--line-number buf (point)))))
      (if day (agenda--toggle-day! buf day) (message "no day here")))))

(define-command "agenda-refresh" "Re-read the agenda files"
  (lambda () (agenda--render! (current-buffer))))

(define (agenda--set-offset! buf off)
  (buffer-set-local! buf 'agenda-start-offset off)
  (agenda--render! buf))

(define-command "agenda-week-next" "Show the next week"
  (lambda ()
    (let ((buf (current-buffer)))
      (agenda--set-offset! buf
        (+ (or (buffer-local buf 'agenda-start-offset) 0) 7)))))

(define-command "agenda-week-prev" "Show the previous week"
  (lambda ()
    (let ((buf (current-buffer)))
      (agenda--set-offset! buf
        (- (or (buffer-local buf 'agenda-start-offset) 0) 7)))))

(define-command "agenda-today" "Return the agenda to the week that starts today"
  (lambda () (agenda--set-offset! (current-buffer) 0)))

(define-command "agenda-toggle-view" "Toggle between the cards and the plain listing"
  (lambda ()
    (let* ((buf (current-buffer))
           (rich? (equal? (buffer-local buf 'render-mode) "blocks")))
      (buffer-set-local! buf 'render-mode (if rich? #f "blocks"))
      (message (if rich? "plain agenda" "agenda cards")))))

;; the click registry (components.scm): a day header folds its day, an
;; entry row opens its file
(on-block-click! 'agenda
  (lambda (buf id)
    (and (buffer-local buf 'agenda-index)
         (cond ((string-prefix? "d-" id)
                (let ((z (string->number
                           (substring-bytes id 2 (string-byte-length id)))))
                  (when (number? z) (agenda--toggle-day! buf z)))
                #t)
               ((string-prefix? "e-" id)
                (let* ((l (string->number
                            (substring-bytes id 2 (string-byte-length id))))
                       (hit (and (number? l) (agenda--entry-at buf l))))
                  (when hit (agenda--visit! hit)))
                #t)
               (else #f)))))

;;; --- the mode ----------------------------------------------------------------

(define (agenda--install-keys!)
  (local-remap! "next-line" "agenda-next")
  (local-remap! "previous-line" "agenda-prev")
  
  )

(mode-icon! "morg-agenda-mode" "")

(define-mode "morg-agenda-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (agenda--install-keys!)
      (buffer-set-read-only! buf #t)
      ;; the text regenerates from the files, so the desktop keeps the
      ;; locals (the closed days) and not the content or the projections
      (buffer-set-local! buf 'transient #t)
      (buffer-set-local! buf 'desktop-skip-locals
        '(render-blocks agenda-index agenda-day-lines))
      (buffer-set-local! buf 'render-mode "blocks")
      (agenda--render! buf))))

(mode-keys! "morg-agenda-mode"
  '(
    ("n" "agenda-next")
    ("p" "agenda-prev")
    ("TAB" "agenda-toggle-day")
    ("RET" "agenda-visit")
    ("[" "agenda-week-prev")
    ("]" "agenda-week-next")
    ("." "agenda-today")
    ("g" "agenda-refresh")
    ("q" "quit-window")
    ("C-c C-v" "agenda-toggle-view")))

(mode-doc! "morg-agenda-mode"
  "The week from your morg files, as day cards. `n` and `p` step over entries, `TAB` folds a day, and `RET` opens the entry's file. `[` and `]` move by one week; `.` returns to today. `g` re-reads the files. `C-c C-v` shows the plain listing.")

(define-command "morg-agenda" "Show the agenda: dated entries from your morg files"
  (lambda ()
    (buffer-create *agenda-buffer*)
    (switch-to-buffer! *agenda-buffer*)
    (set-mode! "morg-agenda-mode")))

(domain! 'writing)
(effects! '(read write))

(define *morg-todos-buffer* "*Morg TODOs*")

(define-command "morg-todos-visit" "Open the TODO at point"
  (lambda ()
    (let ((row (list-current *morg-todos-buffer*)))
      (if row
          (agenda--visit!
           (list 0 (plist-get row 'file) (plist-get row 'pos)))
          (message "No TODO at point")))))

(define-command "morg-todos-refresh" "Re-read all Morg TODO files"
  (lambda () (list-mode-show! "morg-todos-mode")))

(define-list-mode! "morg-todos-mode"
  (list
    'buffer *morg-todos-buffer*
    'columns (lambda (buf)
               (list (list "TODO" #f)
                     (list "TAGS" 18)
                     (list "FILE" 24)))
    'cells morg-todos--cells
    'key morg-todos--key
    'rows morg-todos--rows
    'render (lambda (buf row) (plist-get row 'title))
    'footer (lambda (buf)
              '(("RET" "open") ("g" "refresh") ("q" "quit")))
    'noun "TODO"
    'keys '(("RET" "morg-todos-visit")
            ("g" "morg-todos-refresh")
            ("q" "quit-window"))
    'doc "All unfinished TODO headings from morg-agenda-files."))

(define-command "morg-todos" "Show all unfinished TODOs from your Morg files"
  (lambda ()
    (buffer-create *morg-todos-buffer*)
    (switch-to-buffer! *morg-todos-buffer*)
    (set-mode! "morg-todos-mode")
    *morg-todos-buffer*))

(global-set-key "C-c a" "morg-agenda")

;; a stale agenda catches up when the switcher shows it again; the mtime
;; cache keeps the catch-up cheap
(on-buffer-shown!
  (lambda (b)
    (when (and (equal? b *agenda-buffer*) (buffer-local b 'agenda-index))
      (agenda--render! b))))

;;; --- the stylesheet -----------------------------------------------------------
;;; Structure comes from ui/* components; these names only dress it.

(define-style! 'agenda "
.agenda-header { font-family: var(--font-serif); font-size: 20px; padding: 8px 2px 12px; }
.agenda-day { margin: 0 0 10px; }
.agenda-day .c-fold-head { font-family: var(--font-sans); font-weight: 600; }
.agenda-day .c-fold-badge { color: var(--dim-fg); font-weight: 400; font-size: 11px; margin-left: auto; }
.agenda-today .c-fold-head { border-left: 3px solid #a03020; }
.agenda-row { display: flex; align-items: baseline; gap: 10px; }
.agenda-time { font-family: var(--font-mono); color: var(--dim-fg); min-width: 5ch; text-align: right; }
.agenda-badge { border-radius: 999px; padding: 0 8px; font-size: 10px; font-family: var(--font-mono); white-space: nowrap; background: var(--hl-line-bg); }
.agenda-todo { color: #a03020; border: 1px solid #a03020; background: transparent; }
.agenda-done { color: var(--dim-fg); border: 1px solid var(--border-bg); background: transparent; }
.agenda-late { color: #fff8f0; background: #a03020; }
.agenda-deadline { color: #a03020; border: 1px solid #a03020; background: transparent; }
.agenda-scheduled { color: var(--dim-fg); border: 1px solid var(--border-bg); background: transparent; }
.agenda-title { flex: 1; font-family: var(--font-sans); }
.agenda-row-done .agenda-title { text-decoration: line-through; color: var(--dim-fg); }
.agenda-tags, .agenda-file { font-family: var(--font-mono); font-size: 11px; color: var(--dim-fg); }
.agenda-empty { padding: 16px; }
")
