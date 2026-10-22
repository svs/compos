;;; movie-test.scm --- Provenance movie reconstruction.

(domain! 'testing)
(effects! '(pure))

(define (t--movie-change created ops)
  (list 'created_at created
        'actor (list 'id "agent:test" 'display_name "test agent")
        'operation (list 'ops ops)))

(define (t--movie-op pos inserted deleted)
  (list 'pos pos 'inserted inserted 'deleted deleted))

(deftest 'movie-reconstructs-forward-and-backward-deletes
  "the movie reconstructs every accepted text state"
  (lambda ()
    (let* ((history
             (list
               (t--movie-change 1000 (list (t--movie-op 0 "hello" 0)))
               (t--movie-change 2000 (list (t--movie-op 5 "!" 0)))
               (t--movie-change 3000 (list (t--movie-op 5 "" -2)))))
           (frames (movie-frames history)))
      (check-equal! (map (lambda (f) (movie-get f 'text)) frames)
                    '("hello" "hello!" "hel!")
                    "each change becomes one text state"))))

(deftest 'movie-delay-scales-and-clamps-the-recorded-timeline
  "the movie uses recorded time without making short or long gaps unusable"
  (lambda ()
    (let* ((history
             (list
               (t--movie-change 1000 (list (t--movie-op 0 "a" 0)))
               (t--movie-change 21000 (list (t--movie-op 1 "b" 0)))))
           (movie "zz-movie-delay"))
      (test-buffer! movie "")
      (buffer-set-local! movie 'movie-frames (movie-frames history))
      (check-equal! (movie-delay movie 0) 1000 "20 seconds plays in one second at 20x")
      (buffer-kill! movie))))
