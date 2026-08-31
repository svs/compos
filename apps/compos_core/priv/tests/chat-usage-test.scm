;;; chat-usage-test.scm --- what a conversation costs, and what it occupies.
;;;
;;; Two different counts, from two different reports. A turn's tally adds
;;; up over the conversation (chat-usage-total); what the conversation
;;; occupies right now does not add up at all — the newest report replaces
;;; the last one (chat-context-tokens). Reading them the other way round
;;; gives a number several times too large.

(domain! 'testing)
(effects! '(write))

(define t--usage-buf "*zz-chat-usage*")

(deftest 'a-turns-tally-adds-up-over-the-conversation
  "chat-usage-total sums every turn the backend reported"
  (lambda ()
    (let ((buf (test-buffer! t--usage-buf "")))
      (chat-usage-note! buf '(input 100 output 20 cache-read 900 cache-write 50))
      (chat-usage-note! buf '(input 10 output 5 cache-read 1000 cache-write 0))
      (check-equal! (chat-usage-total buf)
                    '(input 110 output 25 cache-read 1900 cache-write 50)
                    "two turns, added")
      (check-equal! (chat-hit-rate (chat-usage-total buf)) "94%"
                    "and the share of input the cache served")
      (buffer-kill! buf))))

(deftest 'what-a-chat-occupies-is-a-snapshot-not-a-sum
  "the newest context report replaces the last one"
  (lambda ()
    (let ((buf (test-buffer! t--usage-buf "")))
      (chat-context-note! buf 51234 200000)
      (check-equal! (chat-context-tokens buf) '(used 51234 size 200000)
                    "what it holds, and the window it holds it in")

      (chat-context-note! buf 62000 200000)
      (check-equal! (chat-context-tokens buf) '(used 62000 size 200000)
                    "the later report replaces it; it is not 113234")

      ;; a backend that reports nothing must not zero a real count
      (chat-context-note! buf 0 200000)
      (check-equal! (chat-context-tokens buf) '(used 62000 size 200000)
                    "and an empty report changes nothing")
      (buffer-kill! buf))))

(deftest 'a-chat-nobody-has-run-reports-no-context
  "chat-context-tokens answers #f rather than a zero that reads as a count"
  (lambda ()
    (let ((buf (test-buffer! t--usage-buf "")))
      (check-false! (chat-context-tokens buf) "nothing reported yet")
      (buffer-kill! buf))))
