;;; provenance.scm --- the history behind the text.
;;;
;;; M-x buffer-log opens *buffer-log*: one row per accepted revision of the
;;; buffer you were in, oldest first. The header names the recording state,
;;; the policy that set it, and the accepted head.
;;;
;;;   RET   describe this revision: actor, source, operation, hash
;;;   g / q refresh . bury
;;;
;;; The rows come from (buffer-provenance-history NAME). This buffer only
;;; names them; Aimax.Core.ProvenanceStore owns the history.

(domain! 'buffers)
(effects! '(read))

(define *buffer-log-buffer* "*buffer-log*")

;; the buffer whose history the list shows. M-x buffer-log sets it from the
;; buffer you were in, because the list itself becomes the current buffer.
(define *buffer-log-target* #f)

;; the last scan, an alist of (ID . PLIST) — cells and verbs read this so
;; one g press sees one consistent snapshot
(define *buffer-log-rows* '())

(set-face-attribute! 'prov-root 'fg "#26356b" 'weight "600")
(set-face-attribute! 'prov-edit 'fg "#2e6b45")
(set-face-attribute! 'prov-gap 'fg "#a83a2b" 'weight "600")
(set-face-attribute! 'prov-actor 'fg "#7a5a1a")

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
             (buffer-provenance-history *buffer-log-target*))
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

(define (prov-actor-label rev)
  (let ((actor (prov-get rev 'actor)))
    (or (prov-get actor 'display_name) (prov-get actor 'id) "?")))

;; an edit says what it did; a root and a gap say how much text they hold
(define (prov-change rev)
  (let ((op (prov-get rev 'operation)))
    (if op
        (let ((ins (or (prov-get op 'inserted) ""))
              (del (or (prov-get op 'deleted) ""))
              (pos (or (prov-get op 'pos) 0)))
          (string-append "@" (number->string pos)
                         " +" (number->string (string-length ins))
                         " -" (number->string (string-length del))))
        (let ((bytes (prov-get rev 'snapshot_bytes)))
          (if bytes
              (string-append "snapshot " (number->string bytes) "B")
              "")))))

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
              (list "" "dim") (list "" "faint") (list "" "faint"))
        (let ((kind (or (prov-get rev 'kind) "edit")))
          (list (list (number->string (prov-index id)) "faint")
                (list kind (prov-kind-face kind))
                (list (prov-actor-label rev) "prov-actor")
                (list (prov-change rev) "dim")
                (list (prov-when rev) "faint")
                (list (prov-short (prov-get rev 'content_hash)) "faint"))))))

(define (prov-meta buf)
  (let ((st (prov-status)))
    (if (not st)
        "no buffer"
        (string-append (if (prov-get st 'enabled) "recording" "stopped")
                       " . policy " (or (prov-get st 'policy_source) "?")
                       (if (prov-get st 'gap) " . gap" "")
                       " . head " (prov-short (prov-get st 'head_id))))))

;;; --- the verbs ----------------------------------------------------------------

(define-command "buffer-log-describe" "Describe the revision on this line"
  (lambda ()
    (let* ((id (list-current *buffer-log-buffer*))
           (rev (and id (prov-plist id))))
      (if (not rev)
          (message "no revision on this line")
          (let ((actor (prov-get rev 'actor)))
            (message
              (string-append
                (or (prov-get rev 'kind) "edit") " " (prov-short id)
                " . parent " (prov-short (prov-get rev 'parent_id))
                " . " (prov-change rev)
                " . actor " (or (prov-get actor 'id) "?")
                " (" (or (prov-get actor 'kind) "?")
                ", " (or (prov-get actor 'assurance) "?") ")"
                " . source " (or (prov-get actor 'source) "?")
                " . hash " (prov-short (prov-get rev 'content_hash)))))))))

(define-command "buffer-log-refresh" "Redraw the revision list"
  (lambda () (list-refresh! *buffer-log-buffer*)))

;;; --- the hub -------------------------------------------------------------------

(mode-icon! "buffer-log-mode" "")

(define-list-mode! "buffer-log-mode"
  (list
    'doc (string-append
           "Every accepted revision of one buffer, oldest first. The header "
           "names the recording state, the policy that set it, and the "
           "accepted head. `RET` describes the revision on the line.")
    'buffer *buffer-log-buffer*
    'rows prov-ids
    'columns (lambda (buf)
               (list (list "#" 4) (list "kind" 6) (list "actor" 22)
                     (list "change" 18) (list "when" 10) (list "hash" #f)))
    'cells prov-cells
    'title (lambda (buf)
             (string-append "Provenance: " (or *buffer-log-target* "?")))
    'meta prov-meta
    'total (lambda (buf) (length (list-source-entries buf)))
    'no-marks #t
    'local-filter #t
    'footer (lambda (buf)
              '(("RET" "describe") ("/" "filter") ("g" "refresh") ("q" "quit")))
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
(public! 'buffer-log-target "(buffer-log-target) — the buffer *buffer-log* shows, or #f")

(define (buffer-log-target) *buffer-log-target*)
