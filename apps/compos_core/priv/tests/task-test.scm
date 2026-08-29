;;; task-test.scm --- shared-world Scheme task policy.

(domain! 'testing)
(effects! '(read write execute))

(deftest 'scheme-tasks-capture-lexical-data-and-preserve-result-order
  "four task closures run over the shared world"
  (lambda ()
    (let* ((tasks
             (map (lambda (n)
                    (task-spawn (lambda () (* n n))))
                  '(1 2 3 4)))
           (values (map task-await tasks)))
      (for-each task-cancel! tasks)
      (check-equal! values '(1 4 9 16) "task results retain input order"))))

(deftest 'chat-parallel-map-is-the-four-way-agent-policy
  "chat can opt ordinary Scheme work into bounded parallel tasks"
  (lambda ()
    (check-equal!
      (chat-parallel-map (lambda (n) (+ n 10)) '(1 2 3 4))
      '(11 12 13 14)
      "parallel map returns each task result")))

(define *scheme-lock-active* #f)
(define *scheme-lock-overlapped* #f)

(deftest 'with-scheme-lock-serializes-shared-cache-builds
  "one lock key admits one Scheme process at a time"
  (lambda ()
    (set! *scheme-lock-active* #f)
    (set! *scheme-lock-overlapped* #f)
    (chat-parallel-map
      (lambda (n)
        (with-scheme-lock 'task-test-cache
          (lambda ()
            (when *scheme-lock-active*
              (set! *scheme-lock-overlapped* #t))
            (set! *scheme-lock-active* #t)
            (wait-until (lambda () #f) 20 20)
            (set! *scheme-lock-active* #f)
            n)))
      '(1 2 3 4))
    (check-false! *scheme-lock-overlapped*
                  "the lock excludes concurrent Scheme processes")))

(deftest 'apropos-is-safe-in-parallel-tasks
  "read-only discovery has no shared per-search scratch state"
  (lambda ()
    (check-equal!
      (chat-parallel-map
        (lambda (query) (pair? (apropos query)))
        '("buffer read" "code read" "replace code" "apropos"))
      '(#t #t #t #t)
      "all concurrent searches return hits")))
