;;; agent-refactor-test.scm --- Hold the agent module boundaries stable.
;;;
;;; These tests cover small state transforms that integration tests reach only
;;; indirectly. They let agent.scm move into focused modules without changing
;;; transcript offsets, restore behavior, or fleet rows.

(domain! 'testing)
(effects! '(write))

(deftest 'agent-excision-repairs-every-transcript-offset
  "deleting transcript chrome repairs blocks, overlays, folds, and marks"
  (lambda ()
    (let ((buf (test-buffer! "*zz-agent-excise*" "abcdefghijklmnopqrst")))
      (buffer-set-local! buf 'agent-blocks
        '((0 4 "prose")
          (4 10 "tool" "tc" "Read" "read" "running" 8)
          (5 8 "waiting")
          (8 12 "meta")))
      (buffer-set-local! buf 'agent-overlays
        '((1 3 "agent-meta") (5 8 "agent-tool") (10 12 "agent-meta")))
      (overlay-set! buf 'agent (buffer-local buf 'agent-overlays))
      (buffer-set-local! buf 'agent-folds '((4 10 #f) (5 8 #f)))
      (buffer-set-local! buf 'agent-waiting '(8 10))
      (buffer-set-local! buf 'agent-prose-from 9)
      (buffer-set-local! buf 'agent-saved-mark 20)

      (agent-excise-range! buf 5 8)

      (check-equal! (buffer-text buf) "abcdeijklmnopqrst"
                    "the text loses only the selected bytes")
      (check-equal! (buffer-local buf 'agent-blocks)
        '((0 4 "prose")
          (4 7 "tool" "tc" "Read" "read" "running" 5)
          (5 9 "meta"))
        "blocks shift, empty blocks drop, and the tool body moves")
      (check-equal! (buffer-local buf 'agent-overlays)
        '((1 3 "agent-meta") (7 9 "agent-meta"))
        "overlays shift and the empty overlay drops")
      (check-equal! (buffer-local buf 'agent-folds) '((4 7 #f))
                    "folds follow the edited transcript")
      (check-equal! (buffer-local buf 'agent-waiting) '(5 7)
                    "the waiting range moves")
      (check-equal! (buffer-local buf 'agent-prose-from) 6
                    "the pending prose start moves")
      (check-equal! (buffer-local buf 'agent-saved-mark) 17
                    "the input mark moves")
      (buffer-kill! buf))))

(deftest 'agent-excision-counts-bytes-after-multibyte-text
  "offset repair uses byte positions when multibyte text comes first"
  (lambda ()
    (let ((buf (test-buffer! "*zz-agent-excise-utf8*" "αabcdefghij")))
      (buffer-set-local! buf 'agent-blocks '((2 10 "prose")))
      (buffer-set-local! buf 'agent-saved-mark 12)

      (agent-excise-range! buf 4 7)

      (check-equal! (buffer-text buf) "αabfghij"
                    "the byte range removes cde")
      (check-equal! (agent-blocks buf) '((2 7 "prose"))
                    "the prose range shifts by three bytes")
      (check-equal! (buffer-local buf 'agent-saved-mark) 9
                    "the input mark shifts by three bytes")
      (buffer-kill! buf))))

(deftest 'agent-restore-sweeps-the-spinner-and-adopts-pending-prose
  "restore removes stale chrome and reveals the durable prose tail"
  (lambda ()
    (let* ((buf (test-buffer! "*zz-agent-restore*"
                  "done\npartial⋯ thinking\n"))
           (waiting "⋯ thinking\n")
           (end (buffer-size buf))
           (start (- end (string-byte-length waiting))))
      (buffer-set-local! buf 'agent-blocks
        (list (list 0 5 "prose") (list start end "waiting")))
      (buffer-set-local! buf 'agent-prose-from 5)
      (buffer-set-local! buf 'agent-saved-mark start)

      (agent-sweep-waiting! buf)
      (agent-adopt-prose-tail! buf)

      (check-equal! (buffer-text buf) "done\npartial"
                    "restore removes the stale spinner text")
      (check-equal! (agent-blocks buf) '((0 12 "prose"))
                    "restore joins the pending tail to prose")
      (check-false! (buffer-local buf 'agent-prose-from)
                    "no pending prose remains")
      (buffer-kill! buf))))

(deftest 'agent-fleet-orders-statuses-and-filters-attention
  "the fleet keeps attention first and reports only attention slugs"
  (lambda ()
    (let ((old-list chat-list-bufs)
          (old-status chat-row-status)
          (old-threads agent-threads))
      (set-symbol-value! 'chat-list-bufs
        (lambda () '("idle" "attention" "dead" "running" "api")))
      (set-symbol-value! 'chat-row-status
        (lambda (buf)
          (cond ((equal? buf "attention") 'needs_attention)
                ((equal? buf "running") 'running)
                ((equal? buf "idle") 'idle)
                ((equal? buf "api") 'api)
                (else 'dead))))
      (let ((sorted (agents-sorted)))
        (set-symbol-value! 'agent-threads
          (lambda ()
            '((a1 idle) (a2 needs_attention) (a3 running)
              (a4 needs_attention))))
        (let ((attention (agents-attention)))
          (set-symbol-value! 'chat-list-bufs old-list)
          (set-symbol-value! 'chat-row-status old-status)
          (set-symbol-value! 'agent-threads old-threads)
          (check-equal! sorted
            '("attention" "running" "idle" "api" "dead")
            "the fleet uses the documented status order")
          (check-equal! attention '(a2 a4)
            "the attention list keeps only attention slugs"))))))

(deftest 'agent-archive-rows-exclude-live-and-open-chats
  "the archive keeps newest unseen logs and applies its limit"
  (lambda ()
    (let* ((live-buf (test-buffer! "*zz-agent-live-chat*" ""))
           (known "/tmp/zz-agent-known.chat")
           (old-files chat-log-files-newest)
           (old-limit chats-archived-limit))
      (test-buffer! known "")
      (buffer-set-local! live-buf 'mode-name "chat-mode")
      (buffer-set-local! live-buf 'chat-log-id "zz-agent-live")
      (let ((live (string-append (chat-log-dir) "/zz-agent-live.chat")))
        (set-symbol-value! 'chat-log-files-newest
          (lambda ()
            (list live "/tmp/zz-agent-one.chat" known
                  "/tmp/zz-agent-two.chat" "/tmp/zz-agent-three.chat")))
        (set-symbol-value! 'chats-archived-limit 2)
        (let ((rows (chats-archived-rows)))
          (set-symbol-value! 'chat-log-files-newest old-files)
          (set-symbol-value! 'chats-archived-limit old-limit)
          (buffer-kill! live-buf)
          (buffer-kill! known)
          (check-equal! rows
            '("/tmp/zz-agent-one.chat" "/tmp/zz-agent-two.chat")
            "live and open logs stay out before the limit applies"))))))

(deftest 'agent-eval-tool-title-uses-the-form-head
  "an eval-scheme call titles by the head of its code, not the tool name"
  (lambda ()
    (check-equal!
      (agent-tool-title
        (list 'name "compos/eval-scheme"
              'input (json-encode (list 'code "(code-read \"/x/web.scm\" 10)"))))
      "code-read: \"/x/web.scm\" 10"
      "the head symbol is the shown name, the rest is the argument")
    (check-equal!
      (agent-tool-title
        (list 'name "mcp__compos__eval-scheme"
              'input (json-encode (list 'code "(buffer-list)"))))
      "buffer-list"
      "a no-argument form titles as its head alone")
    (check-equal!
      (agent-tool-title
        (list 'name "compos/eval-scheme"
              'input (json-encode (list 'code "not a form"))))
      "compos/eval-scheme: not a form"
      "code that is not a call keeps the tool-name title")
    (check-equal!
      (agent-tool-title
        (list 'name "mcp__compos__apropos"
              'input (json-encode (list 'query "rename buffer"))))
      "compos:apropos: rename buffer"
      "a non-eval tool keeps its name")))

(deftest 'agent-sexp-head-split-recognises-call-forms
  "the head split takes only a plain leading symbol"
  (lambda ()
    (check-equal! (agent-sexp-head-split "(define (f x)\n  (+ x 1))")
                  '("define" "(f x)\n  (+ x 1)")
                  "a multi-line form splits at the first separator")
    (check-equal! (agent-sexp-head-split "((kind \"cmd\"))") #f
                  "a list of lists has no head symbol")
    (check-equal! (agent-sexp-head-split "plain text") #f
                  "prose is not a form")))

(deftest 'a-tool-close-keeps-the-backend-duration
  "the completing close stores duration-ms; a #f close never erases it"
  (lambda ()
    (let ((buf (test-buffer! "*zz-agent-duration*" "abcdefghij")))
      (buffer-set-local! buf 'agent-blocks
        '((0 6 "tool" "tc" "Read" "read" "running" 4)))
      (agent-block-close-tool! buf "tc" 8 "done" 1234)
      (check-equal! (agent-blocks buf)
        '((0 8 "tool" "tc" "Read" "read" "done" 4 1234))
        "the close appends the duration")
      (agent-block-close-tool! buf "tc" 9 "done" #f)
      (check-equal! (agent-blocks buf)
        '((0 9 "tool" "tc" "Read" "read" "done" 4 1234))
        "a close without a duration keeps the stored one")
      (agent-excise-range! buf 1 3)
      (check-equal! (agent-blocks buf)
        '((0 7 "tool" "tc" "Read" "read" "done" 2 1234))
        "excision repairs offsets and keeps the duration")
      (buffer-kill! buf))))
