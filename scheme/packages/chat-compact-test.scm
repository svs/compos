;;; chat-compact-test.scm --- compaction replaces the head with the status
;;; lines the chat already holds, and lists the tool results it saved.

(domain! 'testing)
(effects! '(write))

(define (t--cturn role text)
  (list 'role role 'blocks (list (list "text" text))))

(define (t--ctool id ref)
  (list 'role "assistant"
        'blocks (list (list "tool-use" id "eval-scheme" "{}")
                      (list "tool-result" id ref #f))))

;; N asks, oldest first: the ask, the reply, then the status line that
;; lands after the turn. Answered newest first, as the record is.
(define (t--crecord n extra-head)
  (let loop ((i 1) (acc '()))
    (if (> i n)
        acc
        (loop (+ i 1)
              (append (list (t--cturn "status" (string-append "did " (number->string i)))
                            (t--cturn "assistant" (string-append "reply " (number->string i))))
                      (if (= i 1) extra-head '())
                      (list (t--cturn "user" (string-append "ask " (number->string i))))
                      acc)))))

(define (t--with-compact-buffer record thunk)
  (let ((buf " *chat-compact-test*")
        (old chat-compact-keep))
    (buffer-create buf)
    (buffer-set-local! buf 'chat-wire-turns record)
    (set-symbol-value! 'chat-compact-keep 2)
    (let ((r (ignore-errors (lambda () (thunk buf) 'ran))))
      (set-symbol-value! 'chat-compact-keep old)
      (buffer-kill! buf)
      (check-equal! r 'ran "the test body ran without an error"))))

(define (t--compacted-text buf)
  (let ((t (find (lambda (t) (string-prefix? "[Earlier" (chat-turn-display t)))
                 (chat-record buf))))
    (and t (chat-turn-display t))))

(deftest 'chat-compact-uses-the-status-lines
  "the head becomes its status lines at once, oldest first, and the kept turns stay"
  (lambda ()
    (t--with-compact-buffer (t--crecord 5 '())
      (lambda (buf)
        (check-equal! (chat-compact! buf #f) 'done "status lines compact without a model call")
        (let ((text (t--compacted-text buf)))
          (check-true! (string? text) "one turn holds the compacted head")
          (check-true! (string-contains? text "- did 1\n- did 2\n- did 3") "the head's lines, oldest first")
          (check-false! (string-contains? text "did 5") "a kept turn's line stays out")
          (check-false! (string-contains? text "ask 1") "the head's text is gone"))
        (let ((said (map cadr (chat-turns buf))))
          (check-true! (member "ask 5" said) "the newest ask is kept verbatim")
          (check-false! (member "ask 1" said) "the oldest ask is gone"))
        (check-false! (buffer-local-value 'chat-compacting buf) "nothing is in flight")))))

(deftest 'chat-compact-lists-saved-tool-results
  "a tool result the head saved to a file is named in the compacted turn"
  (lambda ()
    (let ((ref (string-append
                 "[The tool result is 9000 bytes of JSON. It is not in this message: "
                 "the editor saved it to /tmp/r/1-x.json. Read a part with eval-scheme-read.]\n"
                 "shape: {a: 1}")))
      (t--with-compact-buffer (t--crecord 5 (list (t--ctool "t1" ref)))
        (lambda (buf)
          (chat-compact! buf #f)
          (check-true! (string-contains? (t--compacted-text buf)
                                         "- /tmp/r/1-x.json: 9000 bytes of JSON")
                       "the file and its size are listed"))))))
