;;; llm-insert-test.scm --- where an inline LLM reply lands.
;;;
;;; M-o streams its answer at the buffer's agent mark, and that mark only
;;; remembers where the last reply ended. A prompt written below it was
;;; therefore answered above it. A reply is a block of its own, so it
;;; belongs after the block point sits in.

(domain! 'testing)
(effects! '(write))

(define t--li-buf "zz-llm-insert")

(define (t--li! text) (test-buffer! t--li-buf text) t--li-buf)

(define (t--li-done!) (when (buffer-known? t--li-buf) (buffer-kill! t--li-buf)))

(deftest 'a-reply-follows-the-block-point-is-in
  "the answer is a block of its own, below the one that asked"
  (lambda ()
    (t--li! "First paragraph.\n\nSecond paragraph.\n\nThird paragraph.")
    (check-equal! (llm-mode--insert-at t--li-buf 3) 16
                  "the end of the paragraph point is in")
    (check-equal! (llm-mode--insert-at t--li-buf 20) 35
                  "and never inside the next one")
    (t--li-done!)))

(deftest 'a-prompt-below-the-last-reply-is-answered-below-it
  "the mark ends the previous reply; a send aims it at this one"
  (lambda ()
    (t--li! "> hello\n\nHello there.\n\n> and again")
    (buffer-set-local! t--li-buf 'mode-name "morg-mode")
    (buffer-set-local! t--li-buf 'agent-saved-mark 21)
    (llm-mode--aim! t--li-buf
      (llm-mode--insert-at t--li-buf (buffer-size t--li-buf)))
    (check-equal! (buffer-local t--li-buf 'agent-saved-mark)
                  (buffer-size t--li-buf)
                  "below the new prompt, not below the old reply")
    (t--li-done!)))

(deftest 'a-fenced-block-is-never-split
  "an answer cannot land between two backtick lines"
  (lambda ()
    (t--li! "```scheme\n(+ 1 1)\n```\n\nAfter.")
    (check-equal! (llm-mode--insert-at t--li-buf 12) 21
                  "past the closing fence")
    (t--li-done!)))

(deftest 'between-two-blocks-point-is-already-the-place
  "there is nothing to move past"
  (lambda ()
    (t--li! "One.\n\nTwo.")
    (check-equal! (llm-mode--insert-at t--li-buf 5) 5 "the blank line itself")
    (t--li-done!)))

(deftest 'a-chats-mark-is-never-moved
  "there the mark owns the input region"
  (lambda ()
    (t--li! "transcript\n\n>>> you: draft")
    (buffer-set-local! t--li-buf 'mode-name "chat-mode")
    (buffer-set-local! t--li-buf 'agent-saved-mark 10)
    (llm-mode--aim! t--li-buf (buffer-size t--li-buf))
    (check-equal! (buffer-local t--li-buf 'agent-saved-mark) 10
                  "the chat's own mark is untouched")
    (t--li-done!)))
