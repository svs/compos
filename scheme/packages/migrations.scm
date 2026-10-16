;;; migrations.scm --- every old-to-new conversion, run once.
;;;
;;; A saved desktop or a home directory can carry a shape the code no
;;; longer writes: an old local, marker bytes in the text, a mode under
;;; its old name, a file under its old name. Each such shape gets ONE
;;; migration here, named and dated, and the reader in its package sees
;;; only the current shape.
;;;
;;; A buffer migration runs on restore, before the mode setup, and stamps
;;; the buffer ('migrations, a persisted local), so it runs once per
;;; buffer and never again. A migration checks the old shape itself: a
;;; buffer made in this process has no stamp, and the pass runs every
;;; migration on it after the next restart.
;;;
;;; A home migration runs once per home, on the first restore of a
;;; process, when every package has loaded; <compos-home>/migrations
;;; holds the names that ran.
;;;
;;; The cut-off: a migration lives 90 days from its SINCE date. After
;;; that the code, its registration and its test go; a desktop older than
;;; the cut-off is restored as it is. M-x list-migrations shows the dates.
;;;
;;; A body names its package's functions and globals at run time, never
;;; at load: this file loads before the packages, and a reload must
;;; reach the new definitions.

(domain! 'desktop)
(effects! '(write))

;;; --- the registries --------------------------------------------------------------

;; ((NAME SINCE FN) ...) in registration order
(define *buffer-migrations* '())

(public! 'define-buffer-migration!
  "(define-buffer-migration! NAME SINCE FN) - register FN as the one-shot migration NAME; SINCE is its date, YYYY-MM-DD; FN takes the buffer")
(define (define-buffer-migration! name since fn)
  (set! *buffer-migrations*
    (append (filter (lambda (m) (not (equal? (car m) name))) *buffer-migrations*)
            (list (list name since fn)))))

(public! 'buffer-migrations-done
  "(buffer-migrations-done BUF) - the names of the migrations that ran on BUF")
(define (buffer-migrations-done buf)
  (or (buffer-local buf 'migrations) '()))

;; one migration that throws does not stop the restore or the others
(define (migration--run! m buf)
  (unless (ignore-errors (lambda () ((car (cdr (cdr m))) buf) #t))
    (message (string-append "migration " (symbol->string (car m))
                            " failed on " buf))))

(public! 'migrate-buffer!
  "(migrate-buffer! BUF) - run every registered migration BUF has not seen, and stamp it; return the names that ran")
(define (migrate-buffer! buf)
  (migrate-home-once!)
  (let* ((done (buffer-migrations-done buf))
         (due (filter (lambda (m) (not (member (car m) done))) *buffer-migrations*)))
    (when (pair? due)
      (for-each (lambda (m) (migration--run! m buf)) due)
      (buffer-set-local! buf 'migrations (append done (map car due))))
    (map car due)))

(add-hook! 'buffer-restore-hook 'migrate-buffer!)

;; ((NAME SINCE FN) ...) in registration order; FN takes nothing
(define *home-migrations* '())

;; the stamp file; a test points it at a directory of its own
(define *home-migrations-file* #f)
(define (home-migrations-file)
  (or *home-migrations-file* (string-append (compos-home) "/migrations")))

(public! 'define-home-migration!
  "(define-home-migration! NAME SINCE FN) - register FN as the one-shot migration NAME of the home directory; SINCE is its date, YYYY-MM-DD")
(define (define-home-migration! name since fn)
  (set! *home-migrations*
    (append (filter (lambda (m) (not (equal? (car m) name))) *home-migrations*)
            (list (list name since fn)))))

(public! 'home-migrations-done
  "(home-migrations-done) - the names of the migrations that ran on this home")
(define (home-migrations-done)
  (let ((text (read-file (home-migrations-file))))
    (if (string? text)
        (map string->symbol
             (filter (lambda (l) (not (equal? l "")))
                     (map string-trim (string-split text "\n"))))
        '())))

(define (home-migration--run! m)
  (unless (ignore-errors (lambda () ((car (cdr (cdr m)))) #t))
    (message (string-append "migration " (symbol->string (car m)) " failed"))))

(public! 'migrate-home!
  "(migrate-home!) - run every registered home migration this home has not seen, and stamp it; return the names that ran")
(define (migrate-home!)
  (let* ((done (home-migrations-done))
         (due (filter (lambda (m) (not (member (car m) done))) *home-migrations*)))
    (when (pair? due)
      (for-each home-migration--run! due)
      (write-file! (home-migrations-file)
        (string-append
          (string-join (map symbol->string (append done (map car due))) "\n")
          "\n")))
    (map car due)))

;; once per process, on the first restore: every package has loaded by then
(define *home-migrated?* #f)
(define (migrate-home-once!)
  (unless *home-migrated?*
    (set! *home-migrated?* #t)
    (migrate-home!)))
