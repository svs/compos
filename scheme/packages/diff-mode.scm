;;; diff-mode.scm --- the diff buffer, over any backend.
;;;
;;; The whole mode is one pipeline:
;;;
;;;   (buffer-text buf)              ; the truth
;;;     -> (diff-layout buf)         ; parse + one line scan
;;;     -> (diff--blocks buf)        ; render, with fold state as input
;;;     -> the client draws blocks; CSS does the rest
;;;
;;; diff-mode does not know where changes come from. A backend supplies
;;; them:
;;;
;;;   (define-diff-backend "git"
;;;     (list 'read    (lambda (buf cb) ...)     ; cb gets (SECTIONS COMMITS)
;;;           'head    (lambda (buf cb) ...)     ; cb gets the HEAD plist
;;;           'resolve (lambda (buf file) ...)   ; absolute path, for RET
;;;           'show    (lambda (buf commit) ...))) ; open one revision
;;;
;;; SECTIONS is ((LABEL (FILE ...)) ...), in the order to show. FILE is the
;;; plist the git-diff primitive returns — file-a, file-b, binary?, hunks —
;;; plus an optional 'status override ("untracked"). COMMITS is a list of
;;; git-log plists; it renders as the closing "Recent commits" section.
;;;
;;; THE LOAD-BEARING DECISION: the buffer text is the plain unified diff.
;;; It is the byte-addressable source of truth: point motion, RET, folds and
;;; desktop restore work on it, and every view derives from it. A refresh
;;; writes text; nothing else is stored except what the text cannot say:
;;;
;;;   'diff-backend      which backend feeds this buffer ("git")
;;;   'diff-root         the tree the backend reads
;;;   'diff-scope        subtree to limit the diff to, "" for the whole tree
;;;   'diff-watch        #t when the buffer follows the filesystem
;;;   'diff-sections     the section labels of the last render
;;;   'diff-overrides    (KEY STATUS) the text cannot express ("untracked")
;;;   'diff-commits      (LINE SHA SHORT DATE AUTHOR SUBJECT) per commit row
;;;   'diff-head         ('branch B|#f 'detached? BOOL 'sha S 'subject S)
;;;   'diff-seen         every card key already shown once
;;;   'diff-open-cards   the card keys whose card is open
;;;   'diff-closed-hunks the hunk keys the reader folded
;;;   'render-blocks     the drawn projection, rebuilt on every change
;;;
;;; OFFSET RULE: point is a BYTE offset. This file works in LINE numbers and
;;; converts with line-start-position, which is O(log n) on the rope.
;;;
;;; Keys: n/p hunk · N/P file · TAB fold · RET visit · g refresh
;;;       w watch · m merge conflicts only · q quit · C-c C-v the plain unified view

;;; --- backends ------------------------------------------------------------------

(define *diff-backends* '())

(define (define-diff-backend name props)
  (set! *diff-backends* (cons (list name props) *diff-backends*)))

(define (diff--backend-fn buf key)
  (let ((b (assoc (buffer-local buf 'diff-backend) *diff-backends*)))
    (and b (diff--get (cadr b) key))))

;;; --- plists ------------------------------------------------------------------

(define (diff--get pl key)
  (cond ((null? pl) #f)
        ((null? (cdr pl)) #f)
        ((equal? (car pl) key) (cadr pl))
        (else (diff--get (cdr (cdr pl)) key))))

;; every git primitive answers (error "message") on failure, and a real
;; result never starts with that symbol
(define (diff--error? v)
  (and (pair? v) (equal? (car v) 'error)))

(define (diff--count-lines s) (- (length (string-split s "\n")) 1))

;;; --- the unified text --------------------------------------------------------
;;; Written by a refresh, in the exact form diff-parse reads back: the text
;;; round-trips, so the layout below works the same on text we generated and
;;; on text a backend fetched whole (a commit).

(define (diff--name f)
  (let ((b (diff--get f 'file-b))
        (a (diff--get f 'file-a)))
    (cond ((and b (not (equal? b "/dev/null"))) b)
          ((and a (not (equal? a "/dev/null"))) a)
          (else "?"))))

(define (diff--side prefix p)
  (if (or (not p) (equal? p "/dev/null"))
      "/dev/null"
      (string-append prefix p)))

(define (diff--file-header f)
  (let ((n (diff--name f)))
    (string-append
      "diff --git a/" n " b/" n "\n"
      "--- " (diff--side "a/" (diff--get f 'file-a)) "\n"
      "+++ " (diff--side "b/" (diff--get f 'file-b)) "\n"
      (if (diff--get f 'binary?)
          (string-append "Binary files a/" n " and b/" n " differ\n")
          ""))))

(define (diff--line-text l)
  (string-append
    (cond ((equal? (car l) 'add) "+")
          ((equal? (car l) 'del) "-")
          (else " "))
    (cadr l)
    "\n"))

(define (diff--hunk-text h)
  (string-append
    (diff--get h 'header) "\n"
    (string-join (map diff--line-text (diff--get h 'lines)) "")))

;; -> (TEXT COMMIT-INDEX): the whole buffer text, and the line each commit
;; row lands on — the one thing worth remembering while writing
(define (diff--build sections commits)
  (let sloop ((ss sections) (line 1) (chunks '()))
    (if (null? ss)
        (diff--build-commits commits line chunks)
        (let ((sec (car (car ss)))
              (files (cadr (car ss))))
          (if (null? files)
              (sloop (cdr ss) line chunks)
              (let ((label (string-append (if (null? chunks) "" "\n")
                                          sec " (" (number->string (length files)) ")\n\n")))
                (let floop ((fs files)
                            (line (+ line (diff--count-lines label)))
                            (chunks (cons label chunks)))
                  (if (null? fs)
                      (sloop (cdr ss) line chunks)
                      (let ((head (diff--file-header (car fs))))
                        (let hloop ((hs (diff--get (car fs) 'hunks))
                                    (line (+ line (diff--count-lines head)))
                                    (chunks (cons head chunks)))
                          (if (or (not hs) (null? hs))
                              (floop (cdr fs) line chunks)
                              (let ((t (diff--hunk-text (car hs))))
                                (hloop (cdr hs)
                                       (+ line (diff--count-lines t))
                                       (cons t chunks))))))))))))))

(define (diff--build-commits commits line chunks)
  (if (null? commits)
      (list (string-join (reverse chunks) "") '())
      (let ((head (string-append (if (null? chunks) "" "\n") "Recent commits\n\n")))
        (let loop ((cs commits)
                   (line (+ line (diff--count-lines head)))
                   (chunks (cons head chunks))
                   (cidx '()))
          (if (null? cs)
              (list (string-join (reverse chunks) "") (reverse cidx))
              (let* ((c (car cs))
                     (short (diff--get c 'short-sha))
                     (date (substring (diff--get c 'date) 0 10))
                     (author (diff--get c 'author))
                     (subject (diff--get c 'subject))
                     (row (string-append "  " short "  " date "  " author "  " subject "\n")))
                (loop (cdr cs) (+ line 1) (cons row chunks)
                      (cons (list line (diff--get c 'sha) short date author subject)
                            cidx))))))))

;;; --- keys and sections --------------------------------------------------------
;;; A file can be in two sections at once (partially staged), so a card is
;;; identified by SECTION and FILE, never by file alone.

(define (diff--key section file) (string-append section "|" file))
(define (diff--hunk-key section file n)
  (string-append section "|" file "|" (number->string n)))

;; the labels of the last render, plus the fixed history section
(define (diff--section-line? buf l)
  (let loop ((ss (cons "Recent commits" (or (buffer-local buf 'diff-sections) '()))))
    (cond ((null? ss) #f)
          ((string-prefix? (car ss) l) (car ss))
          (else (loop (cdr ss))))))

;;; --- layout -------------------------------------------------------------------
;;; The one derived view of the buffer: parse the text, walk it once for
;;; line numbers, and marry the two — the parse and the scan see the same
;;; "diff --git" lines in the same order. Everything else (blocks, folds,
;;; navigation, RET) asks the layout. Nothing stores it: the text is the
;;; truth and this is how you question it.
;;;
;;; -> one plist per card, in document order:
;;;   (key K section S file NAME status ST start L end E f FILEPLIST
;;;    hunks ((n N line L end E header H old-start OS new-start NS lines LS) ...))

;; The layout is a pure function of the text, and the text has exactly two
;; writers: diff--apply! and diff-show!. Both clear 'diff-layout-cache, so
;; every other caller — blocks, folds, n/p motion, RET — reads the parse
;; once per text, not once per keypress.
(define (diff-layout buf)
  (or (buffer-local buf 'diff-layout-cache)
      (let ((l (diff--layout-parse buf)))
        (buffer-set-local! buf 'diff-layout-cache l)
        l)))

;; -> ((LINE SECTION) ...), the section label lines in reverse document
;; order. The layout scans the text once and asks this list for every card.
(define (diff--section-marks buf)
  (let loop ((ls (split-lines (buffer-text buf))) (line 1) (marks '()))
    (if (null? ls)
        marks
        (let ((next (diff--section-line? buf (car ls))))
          (loop (cdr ls) (+ line 1)
                (if next (cons (list line next) marks) marks))))))

(define (diff--section-before-line marks target)
  (let loop ((ms marks))
    (cond ((null? ms) "")
          ((< (car (car ms)) target) (cadr (car ms)))
          (else (loop (cdr ms))))))

(define (diff--layout-hunks buf section file hunks)
  (let loop ((hs hunks) (n 0) (acc '()))
    (if (null? hs)
        (reverse acc)
        (let* ((h (car hs))
               (start (diff--line-number buf (diff--get h 'start-byte)))
               (stop-byte (max (diff--get h 'start-byte)
                               (- (diff--get h 'end-byte) 1)))
               (end (diff--line-number buf stop-byte)))
          (loop (cdr hs) (+ n 1)
            (cons (list 'n n
                        'line start
                        'end end
                        'header (diff--get h 'header)
                        'old-start (diff--get h 'old-start)
                        'new-start (diff--get h 'new-start)
                        'patch (diff--get h 'patch)
                        'lines (diff--get h 'lines))
                  acc))))))

(define (diff--layout-card buf f overrides marks)
  (let* ((start (diff--line-number buf (diff--get f 'start-byte)))
         (stop-byte (max (diff--get f 'start-byte)
                         (- (diff--get f 'end-byte) 1)))
         (end (diff--line-number buf stop-byte))
         (section (diff--section-before-line marks start))
         (name (diff--name f))
         (key (diff--key section name))
         (override (assoc key overrides)))
    (list 'key key 'section section 'file name
          'status (if override (cadr override) (diff--file-status f))
          'start start 'end end 'f f
          'hunks (diff--layout-hunks buf section name
                                    (or (diff--get f 'hunks) '())))))

(define (diff--layout-parse buf)
  (let ((overrides (or (buffer-local buf 'diff-overrides) '()))
        (marks (diff--section-marks buf)))
    (map (lambda (f) (diff--layout-card buf f overrides marks))
         (diff-parse (buffer-text buf)))))

;; cur while scanning: (SECTION FILEPLIST START-LINE HUNK-LINES-reversed)
(define (diff--close-card cur end overrides)
  (let* ((sec (car cur))
         (f (cadr cur))
         (name (diff--name f))
         (key (diff--key sec name))
         (o (assoc key overrides)))
    (list 'key key 'section sec 'file name
          'status (if o (cadr o) (diff--file-status f))
          'start (caddr cur) 'end end 'f f
          'hunks (diff--zip-hunks (or (diff--get f 'hunks) '())
                                  (reverse (list-ref cur 3))
                                  end))))

(define (diff--zip-hunks phunks lines end)
  (let loop ((hs phunks) (ls lines) (i 0) (acc '()))
    (if (or (null? hs) (null? ls))
        (reverse acc)
        (loop (cdr hs) (cdr ls) (+ i 1)
              (cons (list 'n i
                          'line (car ls)
                          'end (if (null? (cdr ls)) end (- (cadr ls) 1))
                          'header (diff--get (car hs) 'header)
                          'old-start (diff--get (car hs) 'old-start)
                          'new-start (diff--get (car hs) 'new-start)
                          'lines (diff--get (car hs) 'lines))
                    acc)))))

;; what the diff itself can say; "untracked" is a backend word and arrives
;; through 'diff-overrides
(define (diff--file-status f)
  (let ((a (diff--get f 'file-a))
        (b (diff--get f 'file-b)))
    (cond ((or (not a) (equal? a "/dev/null")) "added")
          ((or (not b) (equal? b "/dev/null")) "deleted")
          ((not (equal? a b)) "renamed")
          ((diff--get f 'binary?) "binary")
          (else "modified"))))

;;; --- rows ---------------------------------------------------------------------
;;; One hunk's diff lines, paired into side-by-side rows. A row:
;;;   (kind old-no new-no old new old-words new-words old-line new-line)
;;; old-line/new-line are BUFFER lines, so the view can mark the row point
;;; is on without asking anyone.

(defcustom 'diff-context-run 6
  "Unchanged rows in a row before the middle collapses to one separator."
  'group 'diff 'type 'number)

(define (diff--row kind ono nno old new ow nw oline nline)
  (list 'kind kind 'old-no ono 'new-no nno 'old old 'new new
        'old-words ow 'new-words nw 'old-line oline 'new-line nline))

(define (diff--nth l i)
  (cond ((null? l) #f)
        ((= i 0) (car l))
        (else (diff--nth (cdr l) (- i 1)))))

(define (diff--take-kind ls k)
  (let loop ((ls ls) (acc '()))
    (if (or (null? ls) (not (equal? (car (car ls)) k)))
        (reverse acc)
        (loop (cdr ls) (cons (cadr (car ls)) acc)))))

(define (diff--drop-kind ls k)
  (if (or (null? ls) (not (equal? (car (car ls)) k))) ls (diff--drop-kind (cdr ls) k)))

;; A run writes every deletion and then every addition, so a paired row's two
;; halves sit apart in the text: the deletions occupy B.., the additions the
;; |dels| lines after them.
(define (diff--pair dels adds o n b)
  (let ((nd (length dels))
        (na (length adds)))
    (let loop ((i 0) (acc '()))
      (if (>= i (max nd na))
          (reverse acc)
          (let ((d (diff--nth dels i))
                (a (diff--nth adds i)))
            (loop (+ i 1)
                  (cons (cond
                          ((not d) (diff--row 'add #f (+ n i) #f a #f #f #f (+ b nd i)))
                          ((not a) (diff--row 'del (+ o i) #f d #f #f #f (+ b i) #f))
                          (else
                            (let ((w (diff-word-range d a)))
                              (diff--row 'mod (+ o i) (+ n i) d a
                                         (and w (car w)) (and w (cadr w))
                                         (+ b i) (+ b nd i)))))
                        acc)))))))

(define (diff--rows lines old-start new-start hline)
  (let loop ((ls lines) (o old-start) (n new-start) (b (+ hline 1)) (acc '()))
    (cond
      ((null? ls) (diff--collapse (reverse acc)))
      ((equal? (car (car ls)) 'ctx)
       (loop (cdr ls) (+ o 1) (+ n 1) (+ b 1)
             (cons (diff--row 'ctx o n (cadr (car ls)) (cadr (car ls)) #f #f b b) acc)))
      ((equal? (car (car ls)) 'del)
       (let* ((dels (diff--take-kind ls 'del))
              (r1 (diff--drop-kind ls 'del))
              (adds (diff--take-kind r1 'add))
              (r2 (diff--drop-kind r1 'add)))
         (loop r2 (+ o (length dels)) (+ n (length adds))
               (+ b (length dels) (length adds))
               (append (reverse (diff--pair dels adds o n b)) acc))))
      (else
        (let* ((adds (diff--take-kind ls 'add))
               (r1 (diff--drop-kind ls 'add)))
          (loop r1 o (+ n (length adds)) (+ b (length adds))
                (append (reverse (diff--pair '() adds o n b)) acc)))))))

;; a long run of unchanged rows becomes one separator: the reader came for
;; the changes
(define (diff--collapse rows)
  (let loop ((rs rows) (run '()) (acc '()))
    (cond ((null? rs) (append (reverse acc) (diff--flush-run run)))
          ((equal? (diff--get (car rs) 'kind) 'ctx)
           (loop (cdr rs) (cons (car rs) run) acc))
          (else
            (loop (cdr rs) '()
                  (cons (car rs) (append (reverse (diff--flush-run run)) acc)))))))

(define (diff--flush-run run)
  (let ((rows (reverse run))
        (n (length run)))
    (if (<= n diff-context-run)
        rows
        (let ((keep (quotient diff-context-run 2)))
          (append (diff--first-n rows keep)
                  (list (list 'kind 'gap 'count (- n (* 2 keep))))
                  (diff--last-n rows keep))))))

(define (diff--first-n l n)
  (if (or (= n 0) (null? l)) '() (cons (car l) (diff--first-n (cdr l) (- n 1)))))

(define (diff--last-n l n) (reverse (diff--first-n (reverse l) n)))

;;; --- blocks -------------------------------------------------------------------
;;; (map render (diff-layout buf)) — the client draws div/pre/span blocks
;;; with a class, optional segs, an optional anchor, an optional click id,
;;; and an optional buffer-line range that marks the block while point is
;;; inside it. The client knows no diff words; every class name and every
;;; piece of text the view shows is chosen HERE.

(define (diff--reblock! buf)
  (buffer-set-local! buf 'render-blocks (diff--blocks buf)))

;;; A merge conflict is a card whose status came back "conflict" (git.scm
;;; tags it). The bar above the cards names how many there are and doubles
;;; as the button: click it, or press `m`, to see only those and nothing
;;; else — the sections, the other cards, the commit log all drop out.

(define (diff--conflict-cards layout)
  (filter (lambda (c) (equal? (diff--get c 'status) "conflict")) layout))

(define (diff--has-conflicts? layout) (pair? (diff--conflict-cards layout)))

(define (diff--conflict-bar buf layout)
  (let ((n (length (diff--conflict-cards layout))))
    (if (= n 0)
        '()
        (list (list 'tag "div" 'class "diff-conflict-bar" 'click "diff-conflict-toggle"
                    'segs (list (list "diff-conflict-icon" "⚠")
                                (list "diff-conflict-label"
                                      (string-append (number->string n) " merge conflict"
                                                     (if (= n 1) "" "s")))
                                (list "diff-conflict-hint"
                                      (if (buffer-local buf 'diff-conflict-only)
                                          "show all" "show conflicts only"))))))))

(define (diff--keymap-item key label)
  (list 'tag "span" 'class "diff-keymap-item"
        'children
        (list (list 'tag "span" 'class "diff-key" 'text key)
              (list 'tag "span" 'class "diff-key-label" 'text label))))

(define (diff--keymap-block)
  (list 'tag "div" 'class "diff-keymap"
        'children
        (list (diff--keymap-item "n/p" "hunks/files")
              (diff--keymap-item "N/P" "files")
              (diff--keymap-item "TAB" "fold hunk")
              (diff--keymap-item "f" "fold file")
              (diff--keymap-item "F" "fold all")
              (diff--keymap-item "s" "stage")
              (diff--keymap-item "RET" "open")
              (diff--keymap-item "g" "refresh")
              (diff--keymap-item "w" "watch")
              (diff--keymap-item "?" "explain")
              (diff--keymap-item "ESC" "clear selection"))))

(define (diff--active-tab buf visible commits)
  (or (buffer-local buf 'diff-tab)
      (if (and (null? visible) (pair? commits)) "history" "changes")))

;; Magit leads with the state of HEAD, so this does too: the branch you are
;; on and the commit you are at, or that you are on no branch at all. A
;; detached head is the one thing a reader must not have to work out from
;; silence, so it says so in words. Nothing shows until the backend answers.
(define (diff--head-block buf)
  (let ((h (buffer-local buf 'diff-head)))
    (if (not (pair? h)) '()
      (let* ((branch (diff--get h 'branch))
             (sha (or (diff--get h 'sha) ""))
             (subject (or (diff--get h 'subject) ""))
             (where (if (string? branch) branch "detached"))
             (at (string-trim (string-append sha " " subject))))
        ;; ui/kv carries no class of its own, and this line needs one to
        ;; be styled and found. A tagged block with a class is what every
        ;; other line of this view uses.
        (list (list 'tag "div" 'class "diff-head"
                    'text (string-trim (string-append "Head:  " where "  " at)))))))) 

(define (diff--tabs-block active change-count commit-count)
  (component 'ui/tabs
    (list 'class "diff-tabs"
          'tabs
          (list (list "diff-tab-changes"
                      (string-append "Changes (" (number->string change-count) ")")
                      (equal? active "changes") "1")
                (list "diff-tab-history"
                      (string-append "History (" (number->string commit-count) ")")
                      (equal? active "history") "2")))))

(define (diff--blocks buf)
  (let* ((layout (diff-layout buf))
         (only? (and (buffer-local buf 'diff-conflict-only) (diff--has-conflicts? layout)))
         (visible (if only? (diff--conflict-cards layout) layout))
         (commits (if only? '() (or (buffer-local buf 'diff-commits) '())))
         (active (diff--active-tab buf visible commits))
         (msg (diff--preamble buf))
         (content
           (if (equal? active "history")
               (if (null? commits)
                   (list (component 'ui/empty '(text "no previous commits" class "diff-empty")))
                   (diff--commit-blocks commits))
               (append
                 (diff--conflict-bar buf layout)
                 (if (or only? (equal? msg "")) '()
                     (list (list 'tag "pre" 'class "diff-message" 'text msg)))
                 (if (null? visible)
                     (list (component 'ui/empty '(text "no changes" class "diff-empty")))
                     (diff--section-blocks buf visible))))))
    (append
      (list (diff--keymap-block))
      (diff--head-block buf)
      (list (diff--tabs-block active (length visible) (length commits)))
      content)))

;; everything above the first card or section header: a revision's own
;; header and message, already in the shape a reader wants. Generated
;; working-tree text starts with a section header, so this is "" there.
;; The first card starts where the diff grammar found the first file.
(define (diff--preamble buf)
  (let ((first (and (pair? (diff-layout buf)) (diff--get (car (diff-layout buf)) 'start))))
    (let loop ((ls (split-lines (buffer-text buf))) (n 1) (acc '()))
      (cond ((null? ls) (string-trim (string-join (reverse acc) "\n")))
            ((or (and first (>= n first))
                 (diff--section-line? buf (car ls)))
             (string-trim (string-join (reverse acc) "\n")))
            (else (loop (cdr ls) (+ n 1) (cons (car ls) acc)))))))

(define (diff--count-section layout sec)
  (length (filter (lambda (c) (equal? (diff--get c 'section) sec)) layout)))

;; A reblock rebuilds only the cards whose inputs changed. The signature
;; is everything a card's block reads: open state, its own closed hunks,
;; and its text range. A fold toggle therefore rebuilds ONE card; the
;; other cards reuse their block from 'diff-card-cache. diff--apply!
;; clears the cache, because new text invalidates every range.
(define (diff--card-sig c open closed)
  (let ((key (diff--get c 'key)))
    (list (and (member key open) #t)
          (diff--get c 'selection-active)
          (filter (lambda (hk) (string-prefix? (string-append key "|") hk)) closed)
          (diff--get c 'start)
          (diff--get c 'end))))

(define (diff--section-blocks buf layout)
  (let ((open (or (buffer-local buf 'diff-open-cards) '()))
        (closed (or (buffer-local buf 'diff-closed-hunks) '()))
        (cache (or (buffer-local buf 'diff-card-cache) '()))
        (selection-active
          (not (equal? (buffer-local buf 'diff-selection) 'none))))
    (let loop ((cs layout) (sec #f) (acc '()) (nc '()))
      (if (null? cs)
          (begin
            (buffer-set-local! buf 'diff-card-cache (reverse nc))
            (reverse acc))
          (let* ((c (append (car cs)
                           (list 'selection-active selection-active)))
                 (s (diff--get c 'section))
                 (key (diff--get c 'key))
                 (sig (diff--card-sig c open closed))
                 (hit (assoc key cache))
                 (blk (if (and hit (equal? (cadr hit) sig))
                          (caddr hit)
                          (diff--card-block c open closed)))
                 (acc (if (and (not (equal? s sec)) (not (equal? s "")))
                          (cons (component 'ui/section
                                  (list 'title s
                                        'count (diff--count-section layout s)
                                        'class "diff-section"))
                                acc)
                          acc)))
            (loop (cdr cs) s (cons blk acc) (cons (list key sig blk) nc)))))))

(define (diff--card-block c open closed)
  (let* ((key (diff--get c 'key))
         (open? (member key open))
         (a (diff--get (diff--get c 'f) 'file-a))
         (old (and a (not (equal? a "/dev/null"))
                   (not (equal? a (diff--get c 'file)))
                   a)))
    (list 'tag "div" 'class "diff-card"
          'anchor (string-append "card-" key)
          'lines (list (diff--get c 'start) (diff--get c 'end)) 'mark (if (diff--get c 'selection-active) "current" #f)
          'children
          (cons
            (list 'tag "div" 'class "diff-card-head" 'click key
                  'lines (list (diff--get c 'start) (diff--get c 'start))
                  'mark (if (diff--get c 'selection-active) "current" #f)
                  'segs (append
                          (list (list "diff-caret" (if open? "▾" "▸"))
                                (list "diff-status" (diff--get c 'status))
                                (list "diff-file" (diff--get c 'file)))
                          (if old
                              (list (list "diff-oldfile" (string-append "← " old)))
                              '())))
            (if open? (list (diff--hunks-block c closed)) '())))))

(define (diff--hunks-block c closed)
  (list 'tag "div" 'class "diff-hunks"
        'children
        (cond ((diff--get (diff--get c 'f) 'binary?)
               (list (list 'tag "div" 'class "diff-binary" 'text "binary file")))
              ((null? (diff--get c 'hunks))
               (list (list 'tag "div" 'class "diff-binary" 'text "no diff content")))
              (else (map (lambda (h) (diff--hunk-block c h closed))
                         (diff--get c 'hunks))))))

(define (diff--hunk-block c h closed)
  (let* ((key (diff--get c 'key))
         (hkey (diff--hunk-key (diff--get c 'section) (diff--get c 'file)
                               (diff--get h 'n)))
         (open? (not (member hkey closed))))
    (list 'tag "div" 'class "diff-hunk"
          'anchor (string-append key "-" (number->string (diff--get h 'n)))
          'lines (list (diff--get h 'line) (diff--get h 'end)) 'mark (if (diff--get c 'selection-active) "current" #f)
          'children
          (cons
            (list 'tag "div" 'class "diff-hunk-head"
                  'segs (list (list "diff-caret" (if open? "▾" "▸"))
                              (list "" (diff--get h 'header))))
            (if open?
                (list (list 'tag "div" 'class "diff-grid"
                            'children (diff--row-blocks
                                        (diff--rows (diff--get h 'lines)
                                                    (diff--get h 'old-start)
                                                    (diff--get h 'new-start)
                                                    (diff--get h 'line))
                                        (diff--hunk-syntax (diff--get c 'file) h))))
                '())))))

;;; --- syntax -------------------------------------------------------------------
;;; Each side of a hunk is code in the file's language. The file name names
;;; its mode (auto-mode-alist), the mode names the language, and the
;;; fence-kind registry answers the loaded grammar for it, or #f.

(define (diff--file-ts-lang file)
  (let ((mode (and (string? file) (auto-mode-for file))))
    (and (string? mode)
         (string-suffix? "-mode" mode)
         (fence-kind-ts-lang (substring mode 0 (- (string-length mode) 5))))))

;; the text of one side: the context lines and the lines of KIND
(define (diff--side-lines lines kind)
  (map cadr (filter (lambda (l) (or (equal? (car l) 'ctx) (equal? (car l) kind))) lines)))

;; -> (OLD-RUNS NEW-RUNS OLD-START NEW-START), or #f for a language with no
;; grammar. A side parses as one text, so a string over two lines keeps
;; its colour; each RUNS holds one list of (START END SCOPE) per line.
(define (diff--hunk-syntax file h)
  (let ((lang (diff--file-ts-lang file)))
    (and lang
         (list (ts-highlight-lines lang (diff--side-lines (diff--get h 'lines) 'del))
               (ts-highlight-lines lang (diff--side-lines (diff--get h 'lines) 'add))
               (diff--get h 'old-start)
               (diff--get h 'new-start)))))

;; the runs for file line NO on one side, or '()
(define (diff--line-runs syntax old? no)
  (if (and syntax (number? no))
      (let ((runs (if old? (car syntax) (cadr syntax)))
            (i (- no (list-ref syntax (if old? 2 3)))))
        (if (and (>= i 0) (< i (length runs))) (list-ref runs i) '()))
      '()))

(define (diff--row-blocks rows &optional syntax)
  (let loop ((rs rows) (acc '()))
    (if (null? rs)
        (reverse acc)
        (let ((r (car rs)))
          (if (equal? (diff--get r 'kind) 'gap)
              (loop (cdr rs)
                    (cons (list 'tag "div" 'class "diff-gap"
                                'text (string-append "· · ·  "
                                        (number->string (diff--get r 'count))
                                        " unchanged lines"))
                          acc))
              (loop (cdr rs)
                    (cons (diff--cell r "new" syntax)
                          (cons (diff--cell r "old" syntax) acc))))))))

(define (diff--cell r side &optional syntax)
  (let* ((old? (equal? side "old"))
         (kind (symbol->string (diff--get r 'kind)))
         (no (diff--get r (if old? 'old-no 'new-no)))
         (text (diff--get r (if old? 'old 'new)))
         (words (diff--get r (if old? 'old-words 'new-words)))
         (runs (diff--line-runs syntax old? no))
         (bline (diff--get r (if old? 'old-line 'new-line))))
    (list 'tag "div"
          'class (string-append "diff-side " side " k-" kind)
          'lines (and (number? bline) (list bline bline)) 'mark "at-point"
          'children
          (append
            (list (list 'tag "span" 'class "diff-no"
                        'text (if (number? no) (number->string no) "")))
            (if (string? text)
                (list (list 'tag "span" 'class "diff-text"
                            'segs (diff--text-segs text words runs)))
                '())))))

;; The syntax runs and the word-diff emphasis as flat segs: a run wears
;; its f-ts-* face, and the changed words add "hl". Empty pieces are
;; omitted.
(define (diff--text-segs text words &optional runs)
  (if (and (not words) (or (not runs) (null? runs)))
      (list (list "" text))
      (let* ((len (string-byte-length text))
             (hl (and words (list (min (car words) len) (min (cadr words) len)))))
        (apply append
          (map (lambda (p) (diff--split-hl text p hl))
               (diff--pieces (or runs '()) 0 len '()))))))

;; RUNS as (START END CLASS) pieces that cover 0..LEN, the gaps in ""
(define (diff--pieces runs pos len acc)
  (cond
    ((null? runs)
     (reverse (if (< pos len) (cons (list pos len "") acc) acc)))
    (else
     (let* ((r (car runs))
            (s (max pos (min (car r) len)))
            (e (min (cadr r) len)))
       (diff--pieces (cdr runs) (max s e) len
         (append (if (> e s) (list (list s e (string-append "f-ts-" (caddr r)))) '())
                 (if (> s pos) (list (list pos s "")) '())
                 acc))))))

;; one piece as segs, split where the changed words start and end
(define (diff--split-hl text p hl)
  (let* ((s (car p)) (e (cadr p)) (cls (caddr p))
         (hs (if hl (max s (min (car hl) e)) e))
         (he (if hl (max hs (min (cadr hl) e)) e))
         (hcls (if (equal? cls "") "hl" (string-append cls " hl"))))
    (append
      (if (> hs s) (list (list cls (substring-bytes text s hs))) '())
      (if (> he hs) (list (list hcls (substring-bytes text hs he))) '())
      (if (> e he) (list (list cls (substring-bytes text he e))) '()))))

(define (diff--commit-blocks commits)
  (if (null? commits)
      '()
      (list (list 'tag "div" 'class "diff-section" 'text "Recent commits")
            (list 'tag "div" 'class "diff-log"
                  'children (map diff--commit-row commits)))))

(define (diff--commit-row c)
  (list 'tag "div" 'class "diff-commit"
        'anchor (string-append "commit-" (caddr c))
        'lines (list (car c) (car c)) 'mark (if (diff--get c 'selection-active) "current" #f)
        'segs (list (list "diff-sha" (caddr c))
                    (list "diff-date" (list-ref c 3))
                    (list "diff-author" (list-ref c 4))
                    (list "diff-subject" (list-ref c 5)))))

;;; --- render ------------------------------------------------------------------
;;; Recent commits always close the buffer, so a clean tree is never an empty
;;; screen: what the tree did last is the thing left to look at.

(define (diff--apply! buf sections commits)
  (when (buffer-exists? buf)
    (let* ((seen (or (buffer-local buf 'diff-seen) '()))
           (old-open (or (buffer-local buf 'diff-open-cards) '()))
           (built (diff--build sections commits))
           (old-point (buffer-point buf)))
      (buffer-set-local! buf 'diff-sections (map car sections))
      (buffer-set-local! buf 'diff-commits (cadr built))
      (buffer-set-local! buf 'diff-overrides (diff--overrides sections))
      ;; new text moves every card's range: no cached block or layout
      ;; survives it
      (buffer-set-local! buf 'diff-card-cache '())
      (buffer-set-local! buf 'diff-layout-cache #f)
      (buffer-delete-range! buf 0 (buffer-size buf))
      (buffer-append! buf (car built))
      ;; Controlled state: a card the reader closed stays closed across a
      ;; refresh, and one never shown opens. 'diff-seen survives the restart
      ;; that empties a transient buffer's text, so closed cards stay closed
      ;; there too.
      (let ((keys (map (lambda (c) (diff--get c 'key)) (diff-layout buf))))
        (buffer-set-local! buf 'diff-open-cards
          (filter (lambda (k) (if (member k seen) (member k old-open) #t)) keys))
        (buffer-set-local! buf 'diff-seen keys)
        (when (not (buffer-local buf 'diff-tab))
          (buffer-set-local! buf 'diff-tab
            (if (and (null? keys) (pair? commits)) "history" "changes"))))
      ;; refresh keeps the reader where they were, clamped to the new text
      (buffer-goto! buf (min old-point (buffer-size buf)))
      (diff--fontify! buf)
      (diff--refold! buf)
      (diff--reblock! buf))))

;; the statuses the text cannot express, keyed like the cards
(define (diff--overrides sections)
  (let loop ((ss sections) (acc '()))
    (if (null? ss)
        (reverse acc)
        (loop (cdr ss)
              (let floop ((fs (cadr (car ss))) (acc acc))
                (if (null? fs)
                    acc
                    (floop (cdr fs)
                           (let ((st (diff--get (car fs) 'status)))
                             (if st
                                 (cons (list (diff--key (car (car ss))
                                                        (diff--name (car fs)))
                                             st)
                                       acc)
                                 acc)))))))))

;; The scope, as a path relative to the root. "" means the whole tree and
;; reads as no scope at all.
(define (diff-scope buf)
  (let ((p (buffer-local buf 'diff-scope)))
    (if (or (not p) (equal? p "")) #f p)))

(define (diff-refresh buf)
  (let ((read (diff--backend-fn buf 'read))
        (head (diff--backend-fn buf 'head)))
    ;; the head answers on its own schedule and draws on its own: it is one
    ;; line about the repo, and it must not wait behind the whole diff
    (when head
      (head buf (lambda (h)
                  (when (buffer-known? buf)
                    (buffer-set-local! buf 'diff-head h)
                    (diff--reblock! buf)))))
    (when read
      ;; never inline: the Session draws the editor, and the backend answers
      ;; in its own time
      (read buf (lambda (sections commits) (diff--apply! buf sections commits))))))

;;; --- fontification (the plain view) -------------------------------------------

(define (diff--fontify! buf)
  (let loop ((ls (split-lines (buffer-text buf))) (pos 0) (acc '()))
    (if (null? ls)
        (overlay-set! buf 'diff (reverse acc))
        (let* ((l (car ls))
               (len (string-byte-length l))
               (face (diff--line-face l)))
          (loop (cdr ls)
                (+ pos len 1)
                (if face (cons (list pos (+ pos len) face) acc) acc))))))

(define (diff--line-face l)
  (cond ((string-prefix? "diff --git " l) 'diff-file)
        ((string-prefix? "--- " l) 'diff-file)
        ((string-prefix? "+++ " l) 'diff-file)
        ((string-prefix? "Binary files " l) 'diff-file)
        ((string-prefix? "@@" l) 'diff-hunk)
        ((string-prefix? "+" l) 'diff-add)
        ((string-prefix? "-" l) 'diff-del)
        (else #f)))

;;; --- folds --------------------------------------------------------------------
;;; One state, two projections: the same open/closed sets drive the card
;;; view and become hidden byte ranges under the 'diff tag for the plain
;;; view, so TAB means the same thing in both.

(define (diff--refold! buf)
  (let ((open (or (buffer-local buf 'diff-open-cards) '()))
        (closed (or (buffer-local buf 'diff-closed-hunks) '())))
    (fold-set! buf 'diff
      (let loop ((cs (diff-layout buf)) (acc '()))
        (cond
          ((null? cs) (reverse acc))
          ((not (member (diff--get (car cs) 'key) open))
           (loop (cdr cs)
                 (diff--fold-body buf (diff--get (car cs) 'start)
                                  (diff--get (car cs) 'end) acc)))
          (else
            (let ((c (car cs)))
              (loop (cdr cs)
                    (let hloop ((hs (diff--get c 'hunks)) (acc acc))
                      (cond ((null? hs) acc)
                            ((member (diff--hunk-key (diff--get c 'section)
                                                     (diff--get c 'file)
                                                     (diff--get (car hs) 'n))
                                     closed)
                             (hloop (cdr hs)
                                    (diff--fold-body buf (diff--get (car hs) 'line)
                                                     (diff--get (car hs) 'end) acc)))
                            (else (hloop (cdr hs) acc))))))))))))

;; hide lines FROM+1..TO, keeping FROM — the header stays readable
(define (diff--fold-body buf from to acc)
  (let ((start (+ (line-start-position from)
                  (string-byte-length (diff--line-at-n buf from))))
        (end (diff--line-end buf to)))
    (if (> end start) (cons (list start end) acc) acc)))

(define (diff--line-at-n buf n)
  (let ((ls (split-lines (buffer-text buf))))
    (if (<= n (length ls)) (list-ref ls (- n 1)) "")))

(define (diff--line-end buf n)
  (min (buffer-size buf)
       (+ (line-start-position n) (string-byte-length (diff--line-at-n buf n)))))

;;; --- where point is -----------------------------------------------------------

;; The rope answers from its line index. A walk over split-lines costs the
;; whole text per call, and the layout calls this for every file and hunk.
;; A newline byte counts as the start of the next line: a card's end-byte
;; is exclusive, and the fold ranges read the line after it.
(define (diff--line-number buf pos)
  (with-current-buffer buf (lambda () (line-number-at-pos (+ pos 1)))))

(define (diff--card-at layout line)
  (let loop ((cs layout))
    (cond ((null? cs) #f)
          ((and (>= line (diff--get (car cs) 'start))
                (<= line (diff--get (car cs) 'end)))
           (car cs))
          (else (loop (cdr cs))))))

(define (diff--hunk-at-line card line)
  (let loop ((hs (diff--get card 'hunks)))
    (cond ((null? hs) #f)
          ((and (>= line (diff--get (car hs) 'line))
                (<= line (diff--get (car hs) 'end)))
           (car hs))
          (else (loop (cdr hs))))))

;; the commit whose row point is on, or #f
(define (diff--commit-at buf line)
  (let loop ((cs (or (buffer-local buf 'diff-commits) '())))
    (cond ((null? cs) #f)
          ((equal? (car (car cs)) line) (car cs))
          (else (loop (cdr cs))))))

;;; --- navigation ---------------------------------------------------------------

(define (diff--goto-line! n)
  (goto-char! (line-start-position n)))

;; the rows n/p step through: hunks in a diff, commits in the log view
(define (diff--hunk-lines buf)
  (let* ((layout (diff-layout buf))
         (open (or (buffer-local buf 'diff-open-cards) '()))
         (closed (or (buffer-local buf 'diff-closed-hunks) '()))
         (hs
           (apply append
             (map
               (lambda (c)
                 (if (member (diff--get c 'key) open)
                     (filter
                       (lambda (line)
                         (let ((h (diff--hunk-at-line c line)))
                           (not (member
                                  (diff--hunk-key (diff--get c 'section)
                                                  (diff--get c 'file)
                                                  (diff--get h 'n))
                                  closed))))
                       (map (lambda (h) (diff--get h 'line))
                            (diff--get c 'hunks)))
                     '()))
               layout))))
    (cond ((equal? (buffer-local buf 'diff-tab) "history")
           (map car (or (buffer-local buf 'diff-commits) '())))
          ((pair? hs) hs)
          (else (diff--file-lines buf)))))

(define (diff--file-lines buf)
  (map (lambda (c) (diff--get c 'start)) (diff-layout buf)))

(define (diff--next-in lines cur)
  (let loop ((ls lines))
    (cond ((null? ls) #f)
          ((> (car ls) cur) (car ls))
          (else (loop (cdr ls))))))

(define (diff--prev-in lines cur)
  (let loop ((ls lines) (best #f))
    (cond ((null? ls) best)
          ((>= (car ls) cur) best)
          (else (loop (cdr ls) (car ls))))))

(define (diff--select-point! buf)
  (buffer-set-local! buf 'diff-selection 'point)
  (diff--reblock! buf))

(define-command "diff-clear-selection" "Clear the selected diff scope; ? will explain the whole diff"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-local! buf 'diff-selection 'none)
      (set-mark! #f)
      (diff--reblock! buf)
      (message "diff selection cleared"))))

(define-command "diff-next-hunk" "Move to the next hunk"
  (lambda ()
    (let* ((buf (current-buffer))
           (n (diff--next-in (diff--hunk-lines buf) (diff--line-number buf (point)))))
      (if n (begin (diff--goto-line! n) (diff--select-point! buf)) (message "no next hunk")))))

(define-command "diff-prev-hunk" "Move to the previous hunk"
  (lambda ()
    (let* ((buf (current-buffer))
           (n (diff--prev-in (diff--hunk-lines buf) (diff--line-number buf (point)))))
      (if n (begin (diff--goto-line! n) (diff--select-point! buf)) (message "no previous hunk")))))

(define-command "diff-next-file" "Move to the next file"
  (lambda ()
    (let* ((buf (current-buffer))
           (n (diff--next-in (diff--file-lines buf) (diff--line-number buf (point)))))
      (if n (begin (diff--goto-line! n) (diff--select-point! buf)) (message "no next file")))))

(define-command "diff-prev-file" "Move to the previous file"
  (lambda ()
    (let* ((buf (current-buffer))
           (n (diff--prev-in (diff--file-lines buf) (diff--line-number buf (point)))))
      (if n (begin (diff--goto-line! n) (diff--select-point! buf)) (message "no previous file")))))

;;; --- visiting the source ------------------------------------------------------
;;; The target line is the hunk's new-start plus the context and added rows
;;; above point inside the hunk. Deleted rows do not exist in the new file,
;;; so they do not count. -> (FILE LINE|#f), or #f outside any card.

(define (diff--target layout line)
  (let ((card (diff--card-at layout line)))
    (and card
         (let ((h (diff--hunk-at-line card line)))
           (if (not h)
               (list (diff--get card 'file) #f)
               (let loop ((ls (diff--get h 'lines))
                          (k (- line (diff--get h 'line) 1))
                          (out (diff--get h 'new-start)))
                 (if (or (<= k 0) (null? ls))
                     (list (diff--get card 'file) out)
                     (loop (cdr ls) (- k 1)
                           (if (equal? (car (car ls)) 'del) out (+ out 1))))))))))

(define-command "diff-visit" "Open the file this row belongs to, at its line"
  (lambda ()
    (let* ((buf (current-buffer))
           (line (diff--line-number buf (point)))
           (commit (diff--commit-at buf line))
           (target (diff--target (diff-layout buf) line))
           (show (diff--backend-fn buf 'show))
           (resolve (diff--backend-fn buf 'resolve)))
      (cond ((and commit show) (show buf commit))
            ((not target) (message "no file here"))
            ((not resolve) (message "this diff has no files to open"))
            (else
              (let ((path (resolve buf (car target))))
                (if (and path (file-exists? path))
                    (begin
                      (browse-visit path)
                      (when (cadr target)
                        (diff--goto-line! (max 1 (cadr target)))))
                    (message (string-append "gone: " (car target))))))))))

;;; --- one revision, as the same cards ------------------------------------------
;;; A backend's `show` fetches the text of one revision and hands it here.
;;; The text IS a unified diff with a message in front, so the same pipeline
;;; renders it — the preamble becomes the message block on top.

(define (diff-show! name text)
  (buffer-create name)
  (buffer-set-read-only! name #f)
  (buffer-delete-range! name 0 (buffer-size name))
  (buffer-set-local! name 'diff-layout-cache #f)
  (buffer-set-local! name 'diff-card-cache '())
  (buffer-append! name (if (string? text) text "could not read that revision\n"))
  (pop-to-buffer name)
  ;; name it: an agent's pop-to-buffer displays nothing, and a bare set-mode!
  ;; would then land the diff mode on whatever buffer the caller stood in
  (with-current-buffer name (lambda () (set-mode! "diff-show")))
  (buffer-goto! name 0)
  name)

;; a revision that is already written: no refresh, no watching, every card
;; open
(mode-icon! "diff-show" "")

(mode-parent! "diff-show" "special-mode")
(define-mode "diff-show"
  (lambda ()
    (let ((buf (current-buffer)))
      (diff--install-keys!)
      (buffer-set-read-only! buf #t)
      (buffer-set-local! buf 'desktop-skip-locals
        '(render-blocks diff-card-cache diff-layout-cache))
      (buffer-set-local! buf 'render-mode "blocks")
      (buffer-set-local! buf 'ts-lang "diff")
      (buffer-set-local! buf 'diff-commits '())
      (buffer-set-local! buf 'diff-tab "changes")
      (buffer-set-local! buf 'diff-open-cards
        (map (lambda (c) (diff--get c 'key)) (diff-layout buf)))
      (diff--fontify! buf)
      (diff--refold! buf)
      (diff--reblock! buf))))
(keymap-parent! (mode-keymap "diff-show") (mode-keymap "diff-mode"))

(mode-doc! "diff-show"
  "One commit, already written. Every card starts open. `n` and `p` step over hunks, and `RET` opens the file at that line. Nothing refreshes, because a commit does not change.")

(define (diff--changes-text buf)
  (let* ((text (buffer-text buf))
         (commits (or (buffer-local buf 'diff-commits) '())))
    (if (null? commits)
        (string-trim text)
        (let ((change-lines (max 0 (- (car (car commits)) 3))))
          (string-trim
            (string-join
              (diff--first-n (split-lines text) change-lines)
              "\n"))))))

(define (diff--file-patch card)
  (let* ((f (diff--get card 'f))
         (head (or (diff--get f 'patch-head) ""))
         (hunks (or (diff--get f 'hunks) '())))
    (string-append head
      (string-join (map (lambda (h) (or (diff--get h 'patch) "")) hunks) ""))))

(define (diff--explain-text buf)
  (if (equal? (buffer-local buf 'diff-selection) 'none)
      (diff--changes-text buf)
      (let* ((layout (diff-layout buf))
             (line (diff--line-number buf (buffer-point buf)))
             (card (diff--card-at layout line))
             (hunk (and card (diff--hunk-at-line card line))))
        (cond (hunk
               (string-append (or (diff--get (diff--get card 'f) 'patch-head) "")
                              (or (diff--get hunk 'patch) "")))
              (card (diff--file-patch card))
              (else (diff--changes-text buf))))))

(define (diff--explanation-buffer buf)
  (string-append "*explain: " buf "*"))

(define (diff--explanation-prompt changes)
  (string-append
    "Explain this unified diff to a developer. Describe its purpose, behavior changes, important files, risks, and useful review checks. Be concise and do not invent missing context.\n\n"
    "```diff\n" changes "\n```"))

(define (diff--write-explanation! out text)
  (when (buffer-exists? out)
    (buffer-set-read-only! out #f)
    (buffer-delete-range! out 0 (buffer-size out))
    (buffer-append! out
      (string-append "# Diff explanation\n\n"
                     (if (and (string? text) (not (equal? text "")))
                         text
                         "The LLM returned no explanation.")
                     "\n"))
    (with-current-buffer out (lambda () (set-mode! "markdown-mode")))
    (buffer-set-read-only! out #t)))

(domain! 'files)
(effects! '(write display external spend))

(define-command "diff-explain" "Ask the LLM to explain this diff"
  (lambda ()
    (let* ((source (current-buffer))
           (changes (diff--explain-text source))
           (out (diff--explanation-buffer source)))
      (if (equal? changes "")
          (message "no changes to explain")
          (begin
            (buffer-create out)
            (buffer-child! source out)
            (diff--write-explanation! out "Explaining the diff…")
            (display-buffer-other-window! out)
            (message "LLM is explaining the diff")
            (llm (diff--explanation-prompt changes)
              (lambda (answer)
                (if (buffer-exists? out)
                    (begin
                      (diff--write-explanation! out answer)
                      (message "Diff explanation ready"))
                    (message "Diff explanation discarded")))))))))

(domain! 'unknown)
(effects! '(unknown))

(define (diff--stage-finish! buf result label)
  (if (diff--error? result)
      (message (string-append "stage failed: " (cadr result)))
      (begin
        (message (string-append "staged " label))
        (diff-refresh buf))))

(domain! 'git)
(effects! '(write display external execute))

(define-command "diff-stage" "Stage the hunk at point, or the current file"
  (lambda ()
    (let* ((buf (current-buffer))
           (line (diff--line-number buf (point)))
           (card (diff--card-at (diff-layout buf) line))
           (hunk (and card (diff--hunk-at-line card line)))
           (stage-file (diff--backend-fn buf 'stage-file))
           (stage-hunk (diff--backend-fn buf 'stage-hunk)))
      (cond
        ((not card) (message "no change here"))
        ((equal? (diff--get card 'section) "Staged changes")
         (message "this change is already staged"))
        ((and hunk (> line (diff--get card 'start)) stage-hunk)
         (stage-hunk buf card hunk
           (lambda (result)
             (diff--stage-finish! buf result (diff--get card 'file)))))
        (stage-file
         (stage-file buf card
           (lambda (result)
             (diff--stage-finish! buf result (diff--get card 'file)))))
        (else (message "this diff cannot stage changes"))))))

(domain! 'unknown)
(effects! '(unknown))

;;; --- folding ------------------------------------------------------------------

(define-command "diff-toggle-fold" "Fold or unfold the hunk at point, else the file"
  (lambda ()
    (let* ((buf (current-buffer))
           (line (diff--line-number buf (point)))
           (card (diff--card-at (diff-layout buf) line)))
      (if (not card)
          (message "nothing to fold here")
          (let ((hunk (diff--hunk-at-line card line)))
            ;; on the file header, or in a card with no hunks, TAB means the
            ;; file. Inside a hunk it means that hunk — magit's rule.
            (if (and hunk (> line (diff--get card 'start)))
                (begin (diff-toggle-hunk! buf (diff--get card 'section)
                                          (diff--get card 'file)
                                          (diff--get hunk 'n))
                       (diff--goto-line! (diff--get hunk 'line)))
                (begin (diff-toggle-card! buf (diff--get card 'key))
                       (diff--goto-line! (diff--get card 'start)))))))))

(domain! 'files)
(effects! '(write display))

(define-command "diff-toggle-file" "Fold or unfold the file at point"
  (lambda ()
    (let* ((buf (current-buffer))
           (line (diff--line-number buf (point)))
           (card (diff--card-at (diff-layout buf) line)))
      (if card
          (begin
            (diff-toggle-card! buf (diff--get card 'key))
            (diff--goto-line! (diff--get card 'start)))
          (message "no file here")))))

(define (diff-toggle-all! buf)
  (let* ((keys (map (lambda (c) (diff--get c 'key)) (diff-layout buf)))
         (open (or (buffer-local buf 'diff-open-cards) '()))
         (all-open? (and (pair? keys)
                         (null? (filter (lambda (key) (not (member key open))) keys)))))
    (buffer-set-local! buf 'diff-open-cards (if all-open? '() keys))
    (diff--refold! buf)
    (diff--reblock! buf)))

(define-command "diff-toggle-all" "Fold all files, or unfold all files"
  (lambda ()
    (let* ((buf (current-buffer))
           (line (diff--line-number buf (point)))
           (card (diff--card-at (diff-layout buf) line)))
      (diff-toggle-all! buf)
      (when card (diff--goto-line! (diff--get card 'start))))))

(define (diff-select-tab! buf tab)
  (buffer-set-local! buf 'diff-tab tab)
  (diff--reblock! buf))

(define-command "diff-show-changes" "Show the changes tab"
  (lambda () (diff-select-tab! (current-buffer) "changes")))

(define-command "diff-show-history" "Show the previous commits tab"
  (lambda () (diff-select-tab! (current-buffer) "history")))

(domain! 'unknown)
(effects! '(unknown))

;; also the click target: the card header in the rich view calls this
(define (diff-toggle-card! buf key)
  (buffer-set-local! buf 'diff-selection 'point)
  (let ((open (or (buffer-local buf 'diff-open-cards) '())))
    (buffer-set-local! buf 'diff-open-cards
      (if (member key open)
          (filter (lambda (k) (not (equal? k key))) open)
          (cons key open)))
    (diff--refold! buf)
    (diff--reblock! buf)))

;; hunks default to open, so the local records the CLOSED ones: a refresh
;; that renumbers nothing keeps them closed and everything else visible
(define (diff-toggle-hunk! buf section file n)
  (buffer-set-local! buf 'diff-selection 'point)
  (let ((key (diff--hunk-key section file n))
        (closed (or (buffer-local buf 'diff-closed-hunks) '())))
    (buffer-set-local! buf 'diff-closed-hunks
      (if (member key closed)
          (filter (lambda (k) (not (equal? k key))) closed)
          (cons key closed)))
    (diff--refold! buf)
    (diff--reblock! buf)))

;; the top bar's button: narrow the view to conflicted files, or back. A
;; buffer with nothing in conflict has no bar to click, so `m` says so.
(define (diff-toggle-conflicts! buf)
  (if (diff--has-conflicts? (diff-layout buf))
      (begin
        (buffer-set-local! buf 'diff-conflict-only (not (buffer-local buf 'diff-conflict-only)))
        (diff--reblock! buf))
      (message "no merge conflicts")))

(define-command "diff-toggle-conflicts" "Show only merge-conflicted files, or show everything again"
  (lambda () (diff-toggle-conflicts! (current-buffer))))

;; the click registry (components.scm) fans the one click primitive out to
;; every blocks mode. The id is ours only in a diff buffer.
(add-hook! (list 'block-click 'diff)
  (lambda (buf id)
    (and (buffer-local buf 'diff-backend)
         (begin
           (cond ((equal? id "diff-conflict-toggle") (diff-toggle-conflicts! buf))
                 ((equal? id "diff-tab-changes") (diff-select-tab! buf "changes"))
                 ((equal? id "diff-tab-history") (diff-select-tab! buf "history"))
                 (else (diff-toggle-card! buf id)))
           #t))))

;;; --- watching -----------------------------------------------------------------

(define-command "diff-toggle-watch" "Follow the filesystem, or stop"
  (lambda ()
    (let* ((buf (current-buffer))
           (root (buffer-local buf 'diff-root))
           (on? (buffer-local buf 'diff-watch)))
      (cond ((not root) (message "this diff has no tree to watch"))
            (on?
              (unwatch-path! root 'deep)
              (buffer-set-local! buf 'diff-watch #f)
              (message "watch off"))
            (else
              (watch-path! root 'deep)
              (buffer-set-local! buf 'diff-watch #t)
              (message "watch on"))))))

;; a stale diff catches up the moment the switcher shows it again
(add-hook! 'buffer-shown-hook
  (lambda (b)
    (when (and (buffer-local b 'diff-stale)
               (buffer-local b 'diff-watch))
      (buffer-set-local! b 'diff-stale #f)
      (diff-refresh b))))

;; One handler for every diff buffer. Only the buffers ON SCREEN
;; refresh: re-rendering a background diff on every file change held
;; the session for seconds at a time. A hidden buffer marks itself
;; stale; showing it again, the next fs change while visible, or `g`
;; catches it up.
(add-hook! 'fs-change-hook
  (lambda (root)
    (for-each
      (lambda (b)
        (when (and (equal? (buffer-local b 'diff-root) root)
                   (buffer-local b 'diff-watch))
          (if (window-showing b)
              (begin
                (buffer-set-local! b 'diff-stale #f)
                (diff-refresh b))
              (buffer-set-local! b 'diff-stale #t))))
      (buffer-list))))

;;; --- the plain view -----------------------------------------------------------

(define-command "diff-toggle-view" "Toggle between the cards and the plain diff"
  (lambda ()
    (let* ((buf (current-buffer))
           (rich? (equal? (buffer-local buf 'render-mode) "blocks")))
      (buffer-set-local! buf 'render-mode (if rich? #f "blocks"))
      (message (if rich? "plain diff" "diff cards")))))

;;; --- the mode -----------------------------------------------------------------

(define (diff--install-keys!)
  (local-remap! "next-line" "diff-next-hunk")
  (local-remap! "previous-line" "diff-prev-hunk")
  
  
  )

(define-command "diff-revert" "Re-read the diff from its backend"
  (lambda () (diff-refresh (current-buffer))))

(mode-icon! "diff-mode" "")

(mode-parent! "diff-mode" "special-mode")
(define-mode "diff-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (diff--install-keys!)
      (buffer-set-read-only! buf #t)
      ;; the text is git's answer, regenerated on every refresh: a history
      ;; of it says nothing the repository does not
      (buffer-provenance-discard! buf "mode:diff-mode" "mode-policy" "mode")
      ;; the text regenerates from the backend, so the desktop saves the
      ;; locals and not the content — and not the drawn projection either:
      ;; diff-refresh below rebuilds render-blocks from git on restore
      (buffer-set-local! buf 'desktop-skip-locals
        '(render-blocks diff-card-cache diff-layout-cache))
      (buffer-set-local! buf 'render-mode "blocks")
      (buffer-set-local! buf 'ts-lang "diff")
      ;; Restore lands here with the locals and no text. Re-arm the watch
      ;; and re-read; the open cards survive because diff--apply! only opens
      ;; cards it has not shown before.
      (when (and (buffer-local buf 'diff-watch) (buffer-local buf 'diff-root))
        (watch-path! (buffer-local buf 'diff-root) 'deep))
      (diff-refresh buf))))

(mode-keys! "diff-mode"
  '(
    ("n" "diff-next-hunk")
    ("p" "diff-prev-hunk")
    ("N" "diff-next-file")
    ("P" "diff-prev-file")
    ("TAB" "diff-toggle-fold")
    ("f" "diff-toggle-file")
    ("F" "diff-toggle-all")
    ("1" "diff-show-changes")
    ("2" "diff-show-history")
    ("?" "diff-explain")
    ("ESC" "diff-clear-selection")
    ("s" "diff-stage")
    ("RET" "diff-visit")
    ("g" "diff-revert")
    ("w" "diff-toggle-watch")
    ("m" "diff-toggle-conflicts")
    ("q" "quit-window")
    ("C-c C-v" "diff-toggle-view")))

(mode-doc! "diff-mode"
  "The top keymap lists the main commands. Tabs separate changes from previous commits. Key 1 shows changes and key 2 shows history. TAB folds a hunk, f folds its file, and F folds all files. n and p step over visible hunks, or files when every hunk is folded. N and P always step over files. RET opens the file at that line. Question mark explains the selected hunk or file; ESC clears the selection so question mark explains the whole diff. s stages the hunk at point, or its file from the header. g re-reads the diff, and w follows the tree.")

;;; --- the stylesheet -----------------------------------------------------------
;;; The mode ships its own CSS; the client renders structure and knows none
;;; of these names.

(define-style! 'diff "
.diff-keymap { display: flex; flex-wrap: wrap; gap: 6px 16px; padding: 4px 2px 8px; font-family: var(--font-mono); font-size: 11px; color: var(--dim-fg, #8a857a); }
.diff-keymap-item { display: inline-flex; gap: 5px; align-items: baseline; }
.diff-key { color: var(--accent-fg, #26356b); font-weight: 600; }
.diff-head { margin: 0 0 8px; font-family: var(--font-mono); font-size: 12px; color: var(--dim-fg, #8a857a); }
.diff-tabs { margin: 0 0 10px; }
.diff-message { font-family: var(--font-mono); font-size: 12px; line-height: 1.55; margin: 0 0 12px; padding: 10px 12px; border-radius: 0; white-space: pre-wrap; overflow-wrap: anywhere; background: var(--hl-line-bg, rgba(0,0,0,0.03)); border-left: 2px solid var(--diff-file-fg, rgba(0,0,0,0.2)); }
.diff-conflict-bar { position: sticky; top: 0; z-index: 3; display: flex; align-items: center; gap: 10px; cursor: pointer; padding: 8px 12px; margin: 0 0 10px; border-radius: 0; font-family: var(--font-mono); font-size: 12px; background: var(--diff-conflict-bg, rgba(168, 58, 43, 0.12)); border: 1px solid var(--alert-fg, #a83a2b); }
.diff-conflict-icon { color: var(--alert-fg, #a83a2b); }
.diff-conflict-label { font-weight: 600; color: var(--alert-fg, #a83a2b); }
.diff-conflict-hint { margin-left: auto; color: var(--dim-fg, #8a857a); font-size: 11px; }
.diff-section { font-family: var(--font-mono); font-size: 11px; font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase; color: var(--dim-fg, #8a857a); padding: 12px 2px 6px; margin-top: 4px; border-bottom: 1px solid var(--border-bg, rgba(0,0,0,0.10)); }
.blocks-scroll > .diff-section:first-child { margin-top: 0; padding-top: 2px; }
.diff-log { font-family: var(--font-mono); font-size: 12px; padding-top: 6px; }
.diff-commit { display: flex; gap: 12px; padding: 3px 10px; border-radius: 0; white-space: nowrap; }
.diff-commit.current { background: var(--hl-line-bg, rgba(0,0,0,0.05)); }
.diff-sha { color: var(--diff-hunk-fg, #7a5a1a); flex: none; }
.diff-date { color: var(--dim-fg, #8a857a); flex: none; }
.diff-author { color: var(--accent-fg, #26356b); flex: none; min-width: 10ch; }
.diff-subject { overflow: hidden; text-overflow: ellipsis; }
.diff-empty { font-family: var(--font-mono); font-size: 12px; padding: 12px; color: var(--dim-fg, #8a857a); }
.diff-card { margin: 0 0 10px; border-radius: 0; border: 1px solid var(--diff-file-fg, rgba(0,0,0,0.14)); overflow: hidden; }
.diff-card.current { box-shadow: 0 0 0 2px var(--accent-fg, #26356b) inset; }
.diff-card-head.current { background: var(--hl-line-bg, rgba(38,53,107,0.12)); box-shadow: inset 3px 0 0 var(--accent-fg, #26356b); color: var(--accent-fg, inherit); }
.diff-card-head { display: flex; align-items: baseline; gap: 8px; cursor: pointer; padding: 6px 10px; user-select: none; font-family: var(--font-mono); font-size: 12px; background: var(--hl-line-bg, rgba(0,0,0,0.03)); }
.diff-caret { color: var(--dim-fg, #8a857a); width: 1ch; }
.diff-status { font-size: 10px; letter-spacing: 0.08em; text-transform: uppercase; color: var(--dim-fg, #8a857a); min-width: 8ch; }
.diff-file { font-weight: 600; color: var(--diff-file-fg, inherit); }
.diff-oldfile { color: var(--dim-fg, #8a857a); font-size: 11px; }
.diff-binary { padding: 8px 12px; font-family: var(--font-mono); font-size: 11.5px; color: var(--dim-fg, #8a857a); }
.diff-hunk.current { background: var(--hl-line-bg, rgba(0,0,0,0.04)); }
.diff-hunk.current > .diff-hunk-head { border-left: 3px solid var(--accent-fg, #26356b); }
.diff-hunk-head { display: flex; gap: 6px; cursor: default; padding: 4px 10px; font-family: var(--font-mono); font-size: 11px; color: var(--diff-hunk-fg, #6a675e); background: var(--diff-hunk-bg, transparent); border-top: 1px solid var(--border-bg, rgba(0,0,0,0.08)); }
.diff-grid { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); font-family: var(--font-mono); font-size: 12px; line-height: 1.5; }
.diff-side { display: flex; gap: 8px; padding: 0 8px; min-width: 0; }
.diff-side.old { border-right: 1px solid var(--border-bg, rgba(0,0,0,0.08)); }
.diff-side.at-point { box-shadow: inset 2px 0 0 var(--cursor-bg, #26356b); filter: brightness(0.97) saturate(1.15); }
.diff-no { color: var(--linenum-fg, #b3ac9c); min-width: 4ch; text-align: right; flex: none; user-select: none; }
.diff-text { flex: 1; min-width: 0; white-space: pre-wrap; overflow-wrap: anywhere; }
.diff-side.k-del.old, .diff-side.k-mod.old { background: var(--diff-del-bg, rgba(160, 48, 32, 0.10)); color: var(--diff-del-fg, inherit); }
.diff-side.k-add.new, .diff-side.k-mod.new { background: var(--diff-add-bg, rgba(61, 107, 79, 0.12)); color: var(--diff-add-fg, inherit); }
.diff-side .hl { border-radius: 0; padding: 0 1px; }
.diff-side.old .hl { background: var(--diff-del-word-bg, rgba(160, 48, 32, 0.28)); }
.diff-side.new .hl { background: var(--diff-add-word-bg, rgba(61, 107, 79, 0.30)); }
.diff-gap { grid-column: 1 / -1; padding: 2px 10px; font-family: var(--font-mono); font-size: 10.5px; color: var(--dim-fg, #8a857a); background: var(--hl-line-bg, rgba(0,0,0,0.02)); }
")

(public! 'define-diff-backend "(define-diff-backend NAME PROPS) — register a diff source; PROPS is ('read FN 'resolve FN 'show FN)")
(public! 'diff-layout "(diff-layout BUF) — the parsed, line-annotated cards of a diff buffer, derived from its text")
(public! 'diff-refresh "(diff-refresh BUF) — re-read a diff buffer from its backend, off the Session")
(public! 'diff-show! "(diff-show! NAME TEXT) — open unified-diff TEXT as cards in a read-only buffer NAME")
(public! 'diff-toggle-card! "(diff-toggle-card! BUF KEY) — fold or unfold one card; KEY is \"SECTION|FILE\"")
(public! 'diff-toggle-hunk! "(diff-toggle-hunk! BUF SECTION FILE N) — fold or unfold one hunk")
