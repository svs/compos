;;; provenance.scm --- the history behind the text.
;;;
;;; M-x buffer-log opens *buffer-log*: one row per accepted revision of the
;;; buffer you were in, oldest first. The header names the recording state,
;;; the policy that set it, and the accepted head.
;;;
;;;   RET   describe this revision: actor, source, operation, hash
;;;   g / q refresh . bury
;;;
;;; The rows come from (buffer-history NAME). This buffer only names them;
;;; Aimax.Core.BufferHistory owns the history, and a change is what one actor
;;; did in one uninterrupted run.
;;;
;;; A delete reports how many bytes it removed, not the text. The removed text
;;; is still in the history, but reading it back means checking out the version
;;; before the delete, which a list of rows does not do.

(domain! 'buffers)
(effects! '(read))

(define *buffer-log-buffer* "*buffer-log*")

;; the buffer whose history the list shows. M-x buffer-log sets it from the
;; buffer you were in, because the list itself becomes the current buffer.
(define *buffer-log-target* #f)

;; the last scan, an alist of (ID . PLIST) — cells and verbs read this so
;; one g press sees one consistent snapshot
(define *buffer-log-rows* '())

(defface! 'prov-root 'fg "#26356b" 'weight "600")
(defface! 'prov-edit 'fg "#2e6b45")
(defface! 'prov-gap 'fg "#a83a2b" 'weight "600")
(defface! 'prov-actor 'fg "#7a5a1a")
(defface! 'prov-group 'fg "#5a3a7a")
(defface! 'prov-ins 'fg "#2e6b45")
(defface! 'prov-del 'fg "#a83a2b")
(defface! 'prov-heading 'fg "#26356b" 'weight "600")

;;; --- what a row knows ---------------------------------------------------------

;; plist-get throws on #f, so every read of a revision field goes through here
(define (prov-get plist key)
  (and (pair? plist) (plist-get plist key)))

(define (prov-status)
  (and *buffer-log-target*
       (buffer-known? *buffer-log-target*)
       (buffer-provenance-status *buffer-log-target*)))

(define (prov-scan!)
  (set! *buffer-log-rows*
    (if (and *buffer-log-target* (buffer-known? *buffer-log-target*))
        (map (lambda (rev) (cons (prov-get rev 'id) rev))
             (buffer-history *buffer-log-target*))
        '())))

(define (prov-plist id)
  (let ((e (assoc id *buffer-log-rows*)))
    (if e (cdr e) #f)))

(define (prov-index id)
  (let loop ((rows *buffer-log-rows*) (n 1))
    (cond ((null? rows) 0)
          ((equal? (car (car rows)) id) n)
          (else (loop (cdr rows) (+ n 1))))))

;;; --- how a row reads ----------------------------------------------------------

(define (prov-kind-face kind)
  (cond ((equal? kind "root") "prov-root")
        ((equal? kind "gap") "prov-gap")
        (else "prov-edit")))

;; where the work happened. groups.scm sets the buffer-local; the revision
;; keeps the name it had at the time, not the one the buffer wears now.
(define (prov-group-label rev)
  (or (prov-get (prov-get rev 'metadata) 'group) ""))

(define (prov-actor-label rev)
  (let ((actor (prov-get rev 'actor)))
    (or (prov-get actor 'display_name) (prov-get actor 'id) "?")))

;; A row is one line, so a newline or a tab in the text must not travel in it.
(define (prov-one-line s)
  (string-join (string-split (string-join (string-split s "\n") "\\n") "\t") "\\t"))

(define (prov-clip s n)
  (if (> (string-length s) n)
      (string-append (substring s 0 n) "...")
      s))

;; every operation's inserted text, then every operation's deleted text: what
;; a person would read back as "what happened here"
(define (prov-ops-of rev)
  (let ((op (prov-get rev 'operation)))
    (cond ((not op) '())
          ((prov-get op 'ops) (prov-get op 'ops))
          (else (list op)))))

(define (prov-text-of ops key)
  (apply string-append (map (lambda (o) (or (prov-get o key) "")) ops)))

;; the excerpt reads insertions first, because typing is the common case
(define (prov-excerpt rev)
  (let* ((ops (prov-ops-of rev))
         (ins (prov-text-of ops 'inserted))
         (del (cadr (prov-sum ops))))
    (cond ((and (equal? ins "") (= del 0)) "")
          ((= del 0) (prov-clip (prov-one-line ins) 60))
          ((equal? ins "") (string-append "-" (number->string del) "B"))
          (else (string-append (prov-clip (prov-one-line ins) 50)
                               "  -" (number->string del) "B")))))

;; the bytes one operation added and removed, as (INSERTED DELETED).
;; This dialect's cons wants a list tail, so a pair is a two-element list.
;; An insert knows its text; a delete knows only how much it took.
(define (prov-op-sizes op)
  (list (string-length (or (prov-get op 'inserted) ""))
        (or (prov-get op 'deleted) 0)))

(define (prov-sum ops)
  (let loop ((rest ops) (ins 0) (del 0))
    (if (null? rest)
        (list ins del)
        (let ((sizes (prov-op-sizes (car rest))))
          (loop (cdr rest) (+ ins (car sizes)) (+ del (cadr sizes)))))))

;; one operation names its position. A changeset names how many it holds,
;; because typing arrives as a batch and the positions move within it.
(define (prov-change rev)
  (let ((op (prov-get rev 'operation)))
    (if (not op)
        ""
        ;; One operation names its position, because that is the useful thing
        ;; to know about it. Several name how many, because their positions
        ;; move within the change.
        (let* ((ops (or (prov-get op 'ops) '()))
               (sizes (prov-sum ops))
               (amounts (string-append " +" (number->string (car sizes))
                                       " -" (number->string (cadr sizes)))))
          (cond
            ((null? ops) "")
            ((null? (cdr ops))
             (string-append "@" (number->string (or (prov-get (car ops) 'pos) 0))
                            amounts))
            (else (string-append (number->string (length ops)) " ops" amounts)))))))

(define (prov-when rev)
  (let ((ms (prov-get rev 'created_at)))
    (if ms (format-time (quotient ms 1000) "%H:%M:%S") "")))

(define (prov-short s)
  (if (and (string? s) (> (string-length s) 8)) (substring s 0 8) (or s "")))

(define (prov-ids buf)
  (prov-scan!)
  (map car *buffer-log-rows*))

(define (prov-cells buf id)
  (let ((rev (prov-plist id)))
    (if (not rev)
        (list (list "" "faint") (list "?" "prov-edit") (list "" "prov-actor")
              (list "" "prov-group") (list "" "dim") (list "" "faint")
              (list "" "faint"))
        (let ((kind (or (prov-get rev 'kind) "edit")))
          (list (list (number->string (prov-index id)) "faint")
                (list kind (prov-kind-face kind))
                (list (prov-actor-label rev) "prov-actor")
                (list (prov-group-label rev) "prov-group")
                (list (prov-change rev) "dim")
                (list (prov-excerpt rev) (prov-excerpt-face rev))
                (list (prov-when rev) "faint"))))))

;; green when the change only added, red when it only removed
(define (prov-excerpt-face rev)
  (let* ((ops (prov-ops-of rev))
         (ins (prov-text-of ops 'inserted))
         (del (cadr (prov-sum ops))))
    (cond ((and (equal? ins "") (> del 0)) "prov-del")
          ((equal? ins "") "faint")
          (else "prov-ins"))))

(define (prov-meta buf)
  (let ((st (prov-status)))
    (if (not st)
        "no buffer"
        (string-append (if (prov-get st 'enabled) "recording" "stopped")
                       " . policy " (or (prov-get st 'policy_source) "?")
                       (if (prov-get st 'gap) " . gap" "")
                       " . head " (prov-short (prov-get st 'head_id))))))

;;; --- the verbs ----------------------------------------------------------------

(define *revision-buffer* "*revision*")

(define (prov-op-lines ops)
  (apply string-append
    (map (lambda (o)
           (let ((ins (or (prov-get o 'inserted) ""))
                 (del (or (prov-get o 'deleted) 0)))
             (string-append
               "@" (number->string (or (prov-get o 'pos) 0)) "\n"
               (if (= del 0) ""
                   (string-append "  - " (number->string del) " bytes\n"))
               (if (equal? ins "") "" (string-append "  + " ins "\n")))))
         ops)))

;; the whole changeset, not a summary: every operation with the text it moved
(define (prov-render-revision! buf rev)
  (let* ((actor (prov-get rev 'actor))
         (ops (prov-ops-of rev))
         (group (prov-group-label rev))
         (body
           (string-append
             (or (prov-get rev 'kind) "edit") " " (or (prov-get rev 'id) "?") "\n"
             "parent   " (or (prov-get rev 'parent_id) "(none)") "\n"
             "actor    " (or (prov-get actor 'id) "?")
             " (" (or (prov-get actor 'kind) "?")
             ", " (or (prov-get actor 'assurance) "?") ")\n"
             "source   " (or (prov-get actor 'source) "?") "\n"
             (if (equal? group "") "" (string-append "group    " group "\n"))
             "counter  " (number->string (or (prov-get rev 'buffer_version) 0)) "\n"
             "lamport  " (number->string (or (prov-get rev 'lamport) 0)) "\n"
             "when     " (prov-when rev) "\n"
             "\n"
             (if (null? ops)
                 "no operations\n"
                 (string-append (prov-change rev) "\n\n" (prov-op-lines ops))))))
    (buffer-set-read-only! buf #f)
    (buffer-delete-range! buf 0 (buffer-size buf))
    (buffer-append! buf body)
    (buffer-goto! buf 0)
    (buffer-set-read-only! buf #t)))

(define (prov-revision-setup! buf)
  (local-set-key* buf "q" "quit-window")
  (let ((rev (buffer-local buf 'revision)))
    (when rev (prov-render-revision! buf rev))))

(mode-icon! "revision-mode" "")

(define-mode "revision-mode" (lambda () (prov-revision-setup! (current-buffer))))

(mode-doc! "revision-mode"
  "One revision of one buffer: its actor, its group, and every operation it holds, with the text each one inserted and deleted.")

(define-command "buffer-log-describe" "Show this revision in full, with the text it moved"
  (lambda ()
    (let* ((id (list-current *buffer-log-buffer*))
           (rev (and id (prov-plist id))))
      (if (not rev)
          (message "no revision on this line")
          (let ((buf *revision-buffer*))
            (buffer-create buf)
            (buffer-set-local! buf 'revision rev)
            (buffer-set-local! buf 'mode-name "revision-mode")
            (prov-revision-setup! buf)
            (display-buffer buf))))))

(define-command "buffer-log-refresh" "Redraw the revision list"
  (lambda () (list-refresh! *buffer-log-buffer*)))

;;; --- the hub -------------------------------------------------------------------

(mode-icon! "buffer-log-mode" "")

(define-list-mode! "buffer-log-mode"
  (list
    'doc (string-append
           "Every accepted revision of one buffer, oldest first. The header "
           "names the recording state, the policy that set it, and the "
           "accepted head. The text column shows what the change inserted, or "
           "what it deleted when it only deleted. `RET` opens the whole "
           "revision, with every operation and its text.")
    'buffer *buffer-log-buffer*
    'rows prov-ids
    'columns (lambda (buf)
               (list (list "#" 4) (list "kind" 6) (list "actor" 16)
                     (list "group" 12) (list "change" 14) (list "text" #f)
                     (list "when" 9)))
    'cells prov-cells
    'title (lambda (buf)
             (string-append "Provenance: " (or *buffer-log-target* "?")))
    'meta prov-meta
    'total (lambda (buf) (length (list-source-entries buf)))
    'no-marks #t
    'local-filter #t
    'footer (lambda (buf)
              '(("RET" "show") ("/" "filter") ("g" "refresh") ("q" "quit")))
    'keys '(("RET" "buffer-log-describe")
            ("g" "buffer-log-refresh")
            ("q" "quit-window"))))

(define-command "buffer-log" "Show the provenance of this buffer: every accepted revision"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (equal? buf *buffer-log-buffer*)
          (list-refresh! *buffer-log-buffer*)
          (begin
            (set! *buffer-log-target* buf)
            (list-mode-show! "buffer-log-mode"))))))

(global-set-key "C-x v l" "buffer-log")

(category! 'buffers)
;;; --- who owns a line ----------------------------------------------------------
;;; An agent commits its own work and leaves everyone else's alone. To do
;;; that it must ask one question about a range of lines: is all of this
;;; mine? These read (buffer-author-lines BUF), which reports bytes, so a
;;; line two actors touched answers with both of them.
;;;
;;; This Scheme has no dotted pairs, so an owner is the two-element list
;;; (AUTHOR BYTES).

(define (prov--rows-in rows first last)
  (filter (lambda (r) (and (>= (car r) first) (<= (car r) last))) rows))

(define (prov--add-bytes acc who bytes)
  (let ((hit (assoc who acc)))
    (if hit
        (cons (list who (+ (cadr hit) bytes))
              (filter (lambda (e) (not (equal? (car e) who))) acc))
        (cons (list who bytes) acc))))

;; ((AUTHOR BYTES) ...) for lines FIRST..LAST, the largest share first.
;; sort takes no comparator here, so the key leads and the order flips.
(define (lines-authors buf first last)
  (let loop ((rows (prov--rows-in (buffer-author-lines buf) first last)) (acc '()))
    (if (null? rows)
        (map (lambda (e) (list (cadr e) (car e)))
             (reverse (sort (map (lambda (e) (list (cadr e) (car e))) acc))))
        (loop (cdr rows)
              (prov--add-bytes acc (cadr (car rows)) (caddr (car rows)))))))

;; #t when every attributed byte in FIRST..LAST belongs to WHO. A range with
;; no attribution answers #f: text nobody claims is not yours to commit.
(define (lines-mine? buf first last who)
  (let ((owners (lines-authors buf first last)))
    (and (pair? owners)
         (null? (filter (lambda (e) (not (equal? (car e) who))) owners)))))

;; The lines WHO owns outright: every actor named on the line is WHO. Rows
;; arrive in line order, so one walk groups them.
(define (prov--sole-lines rows who)
  (let loop ((rs rows) (line #f) (sole #f) (acc '()))
    (cond
      ((null? rs)
       (reverse (if (and line sole) (cons line acc) acc)))
      ((equal? (car (car rs)) line)
       (loop (cdr rs) line (and sole (equal? (cadr (car rs)) who)) acc))
      (else
       (loop (cdr rs)
             (car (car rs))
             (equal? (cadr (car rs)) who)
             (if (and line sole) (cons line acc) acc))))))

;; consecutive lines join, so the answer reads like a hunk list
(define (prov--runs lines)
  (let loop ((ls lines) (run #f) (acc '()))
    (cond
      ((null? ls) (reverse (if run (cons run acc) acc)))
      ((not run) (loop (cdr ls) (list (car ls) (car ls)) acc))
      ((= (car ls) (+ 1 (cadr run))) (loop (cdr ls) (list (car run) (car ls)) acc))
      (else (loop (cdr ls) (list (car ls) (car ls)) (cons run acc))))))

(define (author-line-runs buf who)
  (prov--runs (prov--sole-lines (buffer-author-lines buf) who)))

(public! 'lines-authors
  "(lines-authors BUF FIRST LAST) -> ((AUTHOR BYTES) ...) who wrote lines FIRST..LAST, largest share first")
(public! 'lines-mine?
  "(lines-mine? BUF FIRST LAST WHO) -> #t when every attributed byte in those lines is WHO's")
(public! 'author-line-runs
  "(author-line-runs BUF WHO) -> ((FIRST LAST) ...) the line runs WHO owns outright")

(public! 'buffer-log-target "(buffer-log-target) — the buffer *buffer-log* shows, or #f")

(define (buffer-log-target) *buffer-log-target*)
