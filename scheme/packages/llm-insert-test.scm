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

;; a document in no group, so no group's LLM setup reaches its chat
(define (t--li-doc! name text)
  (test-buffer! name text)
  (buffer-set-local! name 'group-id #f)
  (buffer-set-local! name 'group-ids '())
  name)

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

(deftest 'an-addressable-block-follows-edits
  "a block id resolves to its current range after surrounding edits"
  (lambda ()
    (t--li! "xxalpha")
    (let ((id (block-create! t--li-buf 'paragraph 2 7)))
      (block-close-end! t--li-buf id)
      (buffer-insert! t--li-buf 0 "Q")
      (buffer-insert! t--li-buf 5 "!")
      (let ((resolved (block-resolve (block-address t--li-buf id))))
        (check-equal! (plist-get resolved 'start) 3 "start follows edits above")
        (check-equal! (plist-get resolved 'end) 9 "end follows edits within")
        (check-equal! (block-text-at t--li-buf
                        (plist-get resolved 'start)
                        (plist-get resolved 'end))
                      "al!pha"
                      "the address still selects the block")))
    (t--li-done!)))

(deftest 'a-new-prompt-stops-at-an-older-result-boundary
  "a shared Morg paragraph is cut so the new prompt cannot cross an old block"
  (lambda ()
    (t--li! "xx\n\noldNew prompt")
    (let ((old (block-create! t--li-buf 'llm-response 0 7 #f 'complete '())))
      (block-close-end! t--li-buf old)
      (let* ((turn (llm-mode--begin-turn! t--li-buf 7 17 "test-model"))
             (prompt (block-resolve-id t--li-buf (plist-get turn 'prompt))))
        (check-equal! (list (plist-get prompt 'start) (plist-get prompt 'end))
                      '(7 17) "the prompt starts at the old result boundary")
        (check-equal! (block-text-at t--li-buf 7 17) "New prompt"
                      "only newly typed text becomes the prompt")))
    (t--li-done!)))

(deftest 'send-reserves-thinking-and-result-blocks-immediately
  "a turn exposes transient activity and a durable result before the request starts"
  (lambda ()
    (t--li! "First\n\nPrompt")
    (let* ((turn (llm-mode--begin-turn! t--li-buf 9 13 "test-model"))
           (prompt (block-resolve-id t--li-buf (plist-get turn 'prompt)))
           (response (block-resolve-id t--li-buf (plist-get turn 'response)))
           (thinking-id (plist-get turn 'thinking))
           (result-id (plist-get turn 'result))
           (thinking (block-resolve-id t--li-buf thinking-id))
           (result (block-resolve-id t--li-buf result-id)))
      (check-equal! (plist-get prompt 'kind) 'llm-prompt "the active Morg block")
      (check-equal! (block-text-at t--li-buf
                      (plist-get prompt 'start) (plist-get prompt 'end))
                    "Prompt" "only the prompt block is claimed")
      (check-equal! (map (lambda (child) (plist-get child 'kind))
                         (block-children t--li-buf (plist-get response 'id)))
                    '(llm-thinking llm-result)
                    "activity and result are separately addressable children")
      (check-equal! (list (plist-get thinking 'state) (plist-get result 'state))
                    '(streaming pending) "only thinking is active initially")
      (check-equal! (plist-get (plist-get thinking 'metadata) 'label)
                    "Thinking · test-model" "the spinner names the model")
      (check-true!
        (let loop ((ovs (buffer-overlays t--li-buf)))
          (and (pair? ovs)
               (or (string-prefix? "chrome-b:llm-thinking-spinner:" (caddr (car ovs)))
                   (loop (cdr ovs)))))
        "a prominent thinking chrome stands at the reserved result")
      ;; a chat that owns the session and points at the document is the
      ;; whole registration: the turn is data on it
      (test-buffer! "zz-li-chat" "")
      (buffer-set-local! "zz-li-chat" 'agent-slug "inline-block-test")
      (buffer-set-local! "zz-li-chat" 'inline-target t--li-buf)
      (llm-inline-begin! "inline-block-test" (plist-get response 'id) 13 13)
      (llm-inline-events! "inline-block-test"
        (list (list 'type 'thought 'text "checking the types\nmore detail")))
      (check-equal!
        (plist-get (plist-get (block-resolve-id t--li-buf thinking-id) 'metadata)
                   'label)
        "Thinking · checking the types" "reasoning updates the interim block")
      (llm-inline-events! "inline-block-test"
        (list (list 'type 'tool-call 'title "inspect schema")))
      (check-equal!
        (plist-get (plist-get (block-resolve-id t--li-buf thinking-id) 'metadata)
                   'label)
        "Running · inspect schema" "tool calls reuse the interim block")
      (buffer-kill! "zz-li-chat")
      (llm-mode--retire-thinking! t--li-buf (plist-get response 'id))
      (check-equal! (plist-get (block-resolve-id t--li-buf thinking-id) 'state)
                    'deleted "interim activity is not preserved")
      (check-equal! (plist-get (block-resolve-id t--li-buf result-id) 'state)
                    'pending "the result address survives the transition"))
    (t--li-done!)))

(deftest 'a-response-contains-addressable-morg-blocks
  "paragraphs and Scheme fences are direct children of the LLM response"
  (lambda ()
    (t--li! "Answer.\n\n```scheme\n(+ 1 1)\n```")
    (let* ((response-id
             (block-create! t--li-buf 'llm-response
               0 (buffer-size t--li-buf) #f 'complete '()))
           (_closed (block-close-end! t--li-buf response-id)))
      (llm-mode--adopt-response-children! t--li-buf response-id)
      (let ((children (block-children t--li-buf response-id)))
        (check-equal! (map (lambda (child) (plist-get child 'kind)) children)
                      '(paragraph scheme)
                      "the response has typed nested blocks")
        (check-equal! (map (lambda (child) (plist-get child 'parent)) children)
                      (list response-id response-id)
                      "both children address their containing response")
        (let ((scheme (cadr children)))
          (check-equal! (block-text-at t--li-buf
                          (plist-get scheme 'start) (plist-get scheme 'end))
                        "```scheme\n(+ 1 1)\n```"
                        "the nested Scheme address resolves exactly"))))
    (t--li-done!)))

(deftest 'a-whole-block-replacement-keeps-the-address
  "delete then insert at the same boundary gives the id the replacement"
  (lambda ()
    (t--li! "xxalpha")
    (let ((id (block-create! t--li-buf 'paragraph 2 7)))
      (block-close-end! t--li-buf id)
      (buffer-delete-range! t--li-buf 2 5)
      (buffer-insert! t--li-buf 2 "omega")
      (let ((resolved (block-resolve-id t--li-buf id)))
        (check-equal! (list (plist-get resolved 'start)
                            (plist-get resolved 'end))
                      '(2 7)
                      "both boundaries surround the replacement")
        (check-equal! (block-text-at t--li-buf 2 7) "omega"
                      "the same id selects the new text")))
    (t--li-done!)))

(deftest 'the-first-addressable-send-keeps-legacy-responses
  "an upgraded document retains every old response highlight"
  (lambda ()
    (t--li! "Old\n\nPrompt")
    (buffer-set-local! t--li-buf 'llm-responses '((0 3)))
    (llm-mode--begin-turn! t--li-buf 7 11)
    (check-equal! (llm-mode--response-ranges t--li-buf)
                  '((0 3))
                  "the empty pending address exists but does not paint")
    (t--li-done!)))

(deftest 'addressable-block-ranges-never-cross
  "nesting is valid, crossing and escaping a parent are rejected"
  (lambda ()
    (t--li! "0123456789")
    (let ((parent (block-create! t--li-buf 'outer 1 8)))
      (check-true!
        (block-create! t--li-buf 'inner 2 5 parent 'complete '())
        "a contained child is valid")
      (check-false!
        (ignore-errors
          (lambda () (block-create! t--li-buf 'crossing 6 9)))
        "crossing an existing block is rejected")
      (check-false!
        (ignore-errors
          (lambda () (block-create! t--li-buf 'escaped 0 3 parent)))
        "a child cannot escape its parent"))
    (t--li-done!)))

(deftest 'C-g-cancels-the-addressed-turn-and-restores-the-prompt
  "cancellation retires the transient prompt face without losing either address"
  (lambda ()
    (t--li! "Prompt")
    (with-current-buffer t--li-buf
      (lambda ()
        (enable-minor-mode! t--li-buf "llm-mode")
        (llm-mode--begin-turn! t--li-buf 2 6)
        (run-command "llm-mode-abort")))
    (let ((records (block-records t--li-buf)))
      (check-equal! (map (lambda (record) (plist-get record 'state)) records)
                    '(complete cancelled deleted cancelled)
                    "prompt/result cancel and transient thinking is retired")
      (check-false! (buffer-local t--li-buf 'llm-active-prompt)
                    "no prompt remains active")
      (check-false!
        (let loop ((ovs (buffer-overlays t--li-buf)))
          (and (pair? ovs)
               (or (string-prefix? "chrome-b:llm-thinking-spinner:" (caddr (car ovs)))
                   (loop (cdr ovs)))))
        "the thinking spinner is gone"))
    (t--li-done!)))

(deftest 'an-orphaned-pending-response-cannot-grow-over-the-document
  "mode setup collapses an empty abandoned marker and removes its face"
  (lambda ()
    (t--li! "")
    (let ((id (block-create! t--li-buf 'llm-response 0 0 #f 'pending '())))
      (buffer-insert! t--li-buf 0 "whole document")
      (enable-minor-mode! t--li-buf "llm-mode")
      (let ((response (block-resolve-id t--li-buf id)))
        (check-equal! (plist-get response 'state) 'cancelled
                      "the orphan is retired")
        (check-equal! (list (plist-get response 'start)
                            (plist-get response 'end))
                      '(0 0)
                      "the abandoned empty response stays empty")
        (check-equal! (llm-mode--response-ranges t--li-buf) '()
                      "it contributes no response range")
        (check-false!
          (let loop ((ovs (buffer-overlays t--li-buf)))
            (and (pair? ovs)
                 (or (equal? (caddr (car ovs)) "llm-response")
                     (loop (cdr ovs)))))
          "the whole buffer has no response face")))
    (t--li-done!)))

(deftest 'legacy-response-ranges-cannot-overlap-addressable-turns
  "a stale broad legacy face yields to the exact response block"
  (lambda ()
    (t--li! "012345")
    (buffer-set-local! t--li-buf 'llm-legacy-responses '((0 6)))
    (let ((id (block-create! t--li-buf 'llm-response 2 4 #f 'complete '())))
      (block-close-end! t--li-buf id)
      (enable-minor-mode! t--li-buf "llm-mode")
      (check-equal! (buffer-local t--li-buf 'llm-legacy-responses) '()
                    "the overlapping legacy range is removed")
      (check-equal! (llm-mode--response-ranges t--li-buf) '((2 4))
                    "only the exact addressable response remains"))
    (t--li-done!)))

(deftest 'm-o-talks-through-a-hidden-chat-of-its-own
  "one chat per document, named after it, made on the first send and not shown"
  (lambda ()
    (let ((doc (t--li-doc! "zz-doc-companion.md" "hello\n")))
      (buffer-set-local! doc 'llm-connector "api")
      (buffer-set-local! doc 'llm-companion-opts '(backend "stub" script ()))
      (let ((c (llm-mode--companion! doc)))
        (check-equal! c "*chat:zz-doc-companion.md*" "named after the document")
        (check-true! (buffer-exists? c) "it exists")
        (check-false! (window-showing c) "and stays hidden")
        (check-equal! (buffer-local c 'mode-name) "chat-mode" "it is a chat")
        (check-equal! (buffer-local doc 'llm-companion) c "the document knows its chat")
        (check-equal! (buffer-local c 'inline-target) doc "the chat knows its document")
        (check-equal! (buffer-local c 'chat-companion-of) doc "as identity")
        (check-equal! (buffer-local doc 'llm-session-id) (buffer-local c 'agent-slug)
                      "the document's session is the chat's")
        (check-true! (and (member (buffer-local c 'agent-slug) (agent-list)) #t) "and it is live")
        (check-equal! (llm-mode--companion! doc) c "asked again, the same chat")
        (llm-session-close! (buffer-local c 'agent-slug))
        (buffer-kill! c)
        (buffer-kill! doc)))))

(deftest 'a-documents-chat-takes-its-modes-chat-parts
  "the chat knows its source and takes the chat part of its mode, the parents and its minor modes"
  (lambda ()
    (define-mode "zz-facet-base-mode" (lambda () #t))
    (define-mode "zz-facet-mode" (lambda () #t))
    (mode-parent! "zz-facet-mode" "zz-facet-base-mode")
    (mode-chat-setup! "zz-facet-base-mode" (lambda (chat src) (prompt-part-set! chat "zz-base" src)))
    (mode-chat-setup! "zz-facet-mode" (lambda (chat src) (prompt-part-set! chat "zz-own" "own")))
    (let ((doc (t--li-doc! "zz-doc-facets" "hello\n")))
      (with-current-buffer doc (lambda () (set-mode! "zz-facet-mode")))
      (buffer-set-local! doc 'llm-connector "api")
      (buffer-set-local! doc 'llm-companion-opts '(backend "stub" script ()))
      (let* ((c (llm-mode--companion! doc))
             (parts (map car (prompt-buffer-parts c))))
        (check-equal! (buffer-local c 'mode-name) "chat-mode" "it stays a chat, with a chat's keys")
        (check-equal! (buffer-local c 'chat-facets) '("zz-facet-base-mode" "zz-facet-mode") "the parent first")
        (check-true! (and (member "chat-source" parts) #t) "it knows its source")
        (check-true! (and (member "zz-base" parts) (member "zz-own" parts) #t) "and takes each mode's part")
        (llm-session-close! (buffer-local c 'agent-slug))
        (buffer-kill! c)
        (buffer-kill! doc)))))

(deftest 'a-new-chat-opens-with-its-most-specific-modes-prompt
  "the mode's own opening beats its parent's; one may be made from the source"
  (lambda ()
    (define-mode "zz-open-base-mode" (lambda () #t))
    (define-mode "zz-open-mode" (lambda () #t))
    (mode-parent! "zz-open-mode" "zz-open-base-mode")
    (set! *chat-openings* (alist-delete (alist-delete *chat-openings* "zz-open-mode") "zz-open-base-mode"))
    (mode-chat-opening! "zz-open-base-mode" "base")
    (let ((doc (t--li-doc! "zz-doc-opening" "hello\n")))
      (with-current-buffer doc (lambda () (set-mode! "zz-open-mode")))
      (check-equal! (chat-opening-prompt doc) "base" "the parent's, when the mode has none")
      (mode-chat-opening! "zz-open-mode" (lambda (src) (string-append "about " src)))
      (check-equal! (chat-opening-prompt doc) "about zz-doc-opening" "the mode's own, made from the source")
      (buffer-kill! doc))))

(deftest 'm-o-lands-the-reply-in-the-document-and-the-hidden-chat-records-it
  "one transport end to end: the stub's chunk streams into the document at
   the response block, and the document's chat holds the turn"
  (lambda ()
    (let ((doc (t--li-doc! "zz-doc-roundtrip.md" "Say hi.\n")))
      (buffer-set-local! doc 'llm-connector "api")
      (buffer-set-local! doc 'llm-companion-opts
        '(backend "stub" script (((type chunk text "hi there.")))))
      (with-current-buffer doc
        (lambda ()
          (goto-char! (buffer-size doc))
          (run-command "llm-send-buffer")))
      (let ((c (buffer-local doc 'llm-companion)))
        (check-true! (and c (buffer-exists? c) #t) "the send made the document's chat")
        (wait-until (lambda () (string-contains? (buffer-text doc) "hi there.")) 5000)
        (check-true! (string-contains? (buffer-text doc) "hi there.")
                     "the reply landed in the document")
        (check-false! (window-showing c) "and the chat stayed hidden")
        (wait-until (lambda () (string-contains? (buffer-text c) "hi there.")) 3000)
        (check-true! (string-contains? (buffer-text c) "hi there.")
                     "and the chat holds the reply too, for when it is shown")
        (llm-session-close! (buffer-local c 'agent-slug))
        (buffer-kill! c)
        (buffer-kill! doc)))))

;;; --- C-u M-o: where the reply goes ------------------------------------------

(deftest 'c-u-m-o-opens-the-send-menu
  "the prefix asks where the reply goes; a bare M-o never asks"
  (lambda ()
    (let ((doc (t--li-doc! "zz-doc-menu.md" "Say hi.\n")))
      (with-current-buffer doc
        (lambda ()
          (set-prefix-arg! '(4))
          (run-command "llm-send-buffer")
          (set-prefix-arg! #f)))
      (let ((state (transient--active)))
        (check-equal! (and state (plist-get state 'prefix)) "llm-send-to"
                      "C-u M-o opens the send menu")
        (check-equal! (and state (plist-get state 'scope)) doc
                      "over the document that asked")
        (check-false! (buffer-local doc 'llm-companion)
                      "and nothing was sent yet"))
      (run-command "transient-quit-all")
      (check-false! (transient--active) "the menu closes")
      (buffer-kill! doc))))

(deftest 'the-chat-target-shows-the-chat-and-leaves-the-document-alone
  "the reply arrives in the document's chat, shown in the other window"
  (lambda ()
    (let ((doc (t--li-doc! "zz-doc-chat-target.md" "Say hi.\n")))
      (buffer-set-local! doc 'llm-connector "api")
      (buffer-set-local! doc 'llm-companion-opts
        '(backend "stub" script (((type chunk text "hi there.")))))
      (let ((c (with-frame-windows (lambda () (llm-send-in-chat! doc)))))
        (check-equal! c "*chat:zz-doc-chat-target.md*" "the send made the document's chat")
        (check-true! (and (with-frame-windows (lambda () (window-showing c))) #t)
                     "the chat is shown")
        (wait-until (lambda () (string-contains? (buffer-text c) "hi there.")) 5000)
        (check-true! (string-contains? (buffer-text c) "hi there.")
                     "the reply landed in the chat")
        (check-equal! (buffer-text doc) "Say hi.\n" "and the document is untouched")
        (llm-session-close! (buffer-local c 'agent-slug))
        (buffer-kill! c)
        (buffer-kill! doc)))))

(deftest 'the-new-document-target-carries-the-prompt-and-the-reply
  "a document of its own holds the prompt and the reply, with a chat of its own"
  (lambda ()
    (let ((doc (t--li-doc! "zz-doc-new-target.md" "Say hi.\n")))
      (buffer-set-local! doc 'llm-connector "api")
      (buffer-set-local! doc 'llm-companion-opts
        '(backend "stub" script (((type chunk text "hi there.")))))
      (let ((new (with-frame-windows (lambda () (llm-send-in-new-document! doc)))))
        (check-equal! new "*llm:zz-doc-new-target.md*" "named after the source document")
        (check-true! (string-contains? (buffer-text new) "Say hi.") "it carries the prompt")
        (check-true! (and (with-frame-windows (lambda () (window-showing new))) #t)
                     "and is shown")
        (wait-until (lambda () (string-contains? (buffer-text new) "hi there.")) 5000)
        (check-true! (string-contains? (buffer-text new) "hi there.")
                     "the reply landed in the new document")
        (check-equal! (buffer-text doc) "Say hi.\n" "the source document is untouched")
        (check-false! (buffer-local doc 'llm-companion) "and has no chat of its own from this")
        (let ((c (buffer-local new 'llm-companion)))
          (check-equal! c "*chat:*llm:zz-doc-new-target.md**" "the new document has its own chat")
          (llm-session-close! (buffer-local c 'agent-slug))
          (buffer-kill! c))
        (buffer-kill! new)
        (buffer-kill! doc)))))
