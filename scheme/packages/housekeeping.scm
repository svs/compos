;;; housekeeping.scm --- sweeps of the buffer store: the graveyard, and
;;; history logs that repeat a checkpoint.
;;
;; A kill never erases: the checkpoint and the history log move to the
;; graveyard (buffers/dead, docs/dead) and a burial line keeps id -> name.
;; Nothing emptied the graveyard, and it held 1.6 GB on 2026-10-08. The
;; sweep deletes the bytes of entries older than `graveyard-keep-days`;
;; the burial line stays, so the record of what was killed survives.
;;
;; A mode that renders a record kept elsewhere (chat-mode, diff-mode,
;; pdf-reader-mode, browse-mode) keeps no history, and its checkpoint
;; carries the text. The logs such buffers wrote before their mode said
;; so are redundant; the second sweep deletes them.

(domain! 'buffers)
(effects! '(pure))

(defcustom 'graveyard-keep-days 30
  "Days a killed buffer's checkpoint and history log stay in the graveyard before the sweep deletes them.")

(effects! '(destroy))

(define-command "graveyard-sweep"
  "Delete graveyard entries older than graveyard-keep-days; the burial log stays"
  (lambda ()
    (let ((n (buffer-store-sweep-graveyard! graveyard-keep-days)))
      (message (string-append "graveyard: deleted " (number->string n)
                              " entries older than "
                              (number->string graveyard-keep-days) " days")))))

(define-command "history-sweep-redundant"
  "Delete history logs of dormant buffers whose checkpoint carries the text"
  (lambda ()
    (let ((n (buffer-store-sweep-redundant-history!)))
      (message (string-append "history: deleted " (number->string n)
                              " redundant logs")))))

(define (housekeeping-sweep! arg)
  (buffer-store-sweep-graveyard! graveyard-keep-days)
  (buffer-store-sweep-redundant-history!))

;; once per boot, a minute in: off the boot path, before the day is out
(debounce! "housekeeping-boot" 60000 housekeeping-sweep! #f)
