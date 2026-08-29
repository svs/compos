;;; buffer-cache-test.scm --- the buffer cache.
;;;
;;; Content fetched from a slow source keeps a stamp, goes stale by TTL,
;;; refreshes off the UI lane through a continuation, and never doubles an
;;; in-flight fetch.

(domain! 'testing)
(effects! '(write))

(define *zz-cache-fetches* 0)
(define *zz-cache-k* #f)
(define *zz-cache-buf* "*zz-cache*")
(define *zz-cache-list-buf* "*zz-cache-list*")

(define (t--cache-kill! buf)
  (when (buffer-known? buf) (buffer-kill! buf)))

(deftest 'a-refresh-fetches-once-renders-on-arrival-and-stamps-the-buffer
  "one flight at a time, and the stamp follows the render"
  (lambda ()
    (set! *zz-cache-fetches* 0)
    (set! *zz-cache-k* #f)
    (buffer-create *zz-cache-buf*)
    (cache-declare! *zz-cache-buf*
      (lambda (buf k)
        (set! *zz-cache-fetches* (+ *zz-cache-fetches* 1))
        (set! *zz-cache-k* k))
      (lambda (buf data)
        (buffer-delete-range! buf 0 (buffer-size buf))
        (buffer-append! buf data))
      60)

    ;; no stamp yet: stale, and the age has nothing to say
    (check-true! (cache-stale? *zz-cache-buf*) "a buffer that never rendered is stale")
    (check-false! (cache-age-label *zz-cache-buf*) "the age has nothing to say")

    ;; one refresh, and a second while in flight does not double the fetch
    (cache-refresh! *zz-cache-buf*)
    (cache-refresh! *zz-cache-buf*)
    (check-equal! *zz-cache-fetches* 1 "the second refresh finds the flight open")

    ;; the data lands: render ran, the stamp is fresh, the flight is over
    (*zz-cache-k* "rows from the network")
    (check-equal! (buffer-text *zz-cache-buf*) "rows from the network" "the render ran")
    (check-false! (cache-stale? *zz-cache-buf*) "the stamp is fresh")
    (check-equal! (cache-age-label *zz-cache-buf*) "just now" "the age reads")

    ;; a failed fetch (#f) keeps the cache and still ends the flight
    (buffer-set-local! *zz-cache-buf* 'cache-time #f)
    (cache-refresh! *zz-cache-buf*)
    (*zz-cache-k* #f)
    (check-equal! (buffer-text *zz-cache-buf*) "rows from the network"
                  "a failed fetch keeps what the buffer had")
    (check-false! (buffer-local *zz-cache-buf* 'cache-inflight) "the flight is over")

    (t--cache-kill! *zz-cache-buf*)))

(deftest 'the-wake-rule-draws-fresh-data-and-refetches-stale-data
  "a wake inside the TTL costs nothing; past it, the source answers again"
  (lambda ()
    (set! *zz-cache-fetches* 0)
    (buffer-create *zz-cache-buf*)
    (cache-declare! *zz-cache-buf*
      (lambda (buf k)
        (set! *zz-cache-fetches* (+ *zz-cache-fetches* 1))
        (k "fresh"))
      (lambda (buf data) #t)
      60)
    (cache-stamp! *zz-cache-buf*)

    ;; inside the TTL a wake costs nothing
    (cache-wake! *zz-cache-buf*)
    (check-equal! *zz-cache-fetches* 0 "a fresh buffer fetches nothing")

    ;; past the TTL a wake fetches again
    (buffer-set-local! *zz-cache-buf* 'cache-time (- (current-time) 3600))
    (cache-wake! *zz-cache-buf*)
    (check-equal! *zz-cache-fetches* 1 "a stale buffer fetches")

    ;; a TTL of #f never goes stale by age
    (cache-declare! *zz-cache-buf*
      (lambda (buf k)
        (set! *zz-cache-fetches* (+ *zz-cache-fetches* 1))
        (k "x"))
      (lambda (buf data) #t)
      #f)
    (buffer-set-local! *zz-cache-buf* 'cache-time (- (current-time) 999999))
    (cache-wake! *zz-cache-buf*)
    (check-equal! *zz-cache-fetches* 1 "a TTL of #f never ages out")

    (t--cache-kill! *zz-cache-buf*)))

(define *zz-cl-fetches* 0)

;; define-list-mode! writes to four registries. Three are Scheme, and this
;; clears them. The fourth is the M-x command table, which is Elixir and
;; has no removal: the name stays until the next restart.
(define (t--cache-forget-list-mode! name)
  (set! *list-modes* (remove (lambda (e) (equal? (car e) name)) *list-modes*))
  (set! *mode-setups* (remove (lambda (e) (equal? (car e) name)) *mode-setups*))
  (set! *mode-docs* (remove (lambda (e) (equal? (car e) name)) *mode-docs*))
  (set! *catalog* (remove (lambda (e) (equal? (plist-get e 'name) name)) *catalog*))
  name)

(deftest 'a-list-with-cache-fetch-fills-from-the-source-and-wakes-from-its-rows
  "the first open fetches; a wake inside the TTL redraws what it has"
  (lambda ()
    (set! *zz-cl-fetches* 0)
    (let ((here (current-buffer)))
      (define-list-mode! "zz-cache-list-mode"
        (list
          'buffer *zz-cache-list-buf*
          'rows (lambda (buf) (or (buffer-local buf 'list-entries) '()))
          'cache-fetch (lambda (buf k)
                         (set! *zz-cl-fetches* (+ *zz-cl-fetches* 1))
                         (k '("alpha" "beta")))
          'cache-ttl 60
          'columns (lambda (buf) (list (list "name" #f)))
          'cells (lambda (buf row) (list row))
          'title (lambda (buf) "Cached")
          'no-marks #t))
      (list-mode-show! "zz-cache-list-mode")

      ;; the first open had no rows, so the cache fetched them
      (check-equal! *zz-cl-fetches* 1 "the first open fetches")
      (check-contains! (buffer-text *zz-cache-list-buf*) "alpha" "the rows landed")

      ;; a wake inside the TTL redraws the cached rows and fetches nothing
      (with-current-buffer *zz-cache-list-buf*
        (lambda () (set-mode! "zz-cache-list-mode")))
      (check-equal! *zz-cl-fetches* 1 "a wake inside the TTL fetches nothing")
      (check-contains! (buffer-text *zz-cache-list-buf*) "alpha" "the cached rows still draw")

      ;; a wake past the TTL fetches again
      (buffer-set-local! *zz-cache-list-buf* 'cache-time (- (current-time) 3600))
      (with-current-buffer *zz-cache-list-buf*
        (lambda () (set-mode! "zz-cache-list-mode")))
      (check-equal! *zz-cl-fetches* 2 "a wake past the TTL fetches")

      (t--cache-kill! *zz-cache-list-buf*)
      (t--cache-forget-list-mode! "zz-cache-list-mode")
      (switch-to-buffer! here))))
