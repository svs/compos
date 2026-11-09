;;; tools-test.scm --- the read-file tool answers text, an image, or a refusal.
;;;
;;; A screenshot read as text sent raw bytes to the MCP proxy. The proxy
;;; could not encode them, and the call never answered.

(domain! 'testing)
(effects! '(write))

(define t--png-b64 "iVBORw0KGgoAAAAN//4=")

(deftest 'read-file-tool-answers-image-content
  "an image file becomes one text block and one image block"
  (lambda ()
    (let ((path "/tmp/compos-read-file-tool-test.png"))
      (write-file! path (base64-decode t--png-b64))
      (let* ((r (read-file-tool path #f))
             (blocks (cadr r))
             (image (nth 1 blocks)))
        (check-true! (tool-content? r) "an image is tool content")
        (check-equal! (plist-get image 'type) "image" "the second block is the image")
        (check-equal! (plist-get image 'mimeType) "image/png" "the extension names the type")
        (check-equal! (plist-get image 'data) t--png-b64 "the bytes travel as base64")
        (check-true! (string-prefix? mcp-proxy-content-prefix
                                     (mcp-proxy-dispatch "read-file"
                                       (json-encode (list 'path path))))
                     "the proxy receives content blocks, not text"))
      (delete-file! path))))

(deftest 'read-file-tool-refuses-binary
  "a binary file that is not an image gives an error, not raw bytes"
  (lambda ()
    (let ((path "/tmp/compos-read-file-tool-test.bin"))
      (write-file! path (base64-decode t--png-b64))
      (check-true! (string-contains? (read-file-tool path #f) "is a binary file")
                   "the tool refuses the bytes")
      (delete-file! path))))

(deftest 'read-file-tool-keeps-text
  "a text file reads as before, with optional line numbers"
  (lambda ()
    (let ((path "/tmp/compos-read-file-tool-test.txt"))
      (write-file! path "alpha\nbeta\n")
      (check-equal! (read-file-tool path #f) "alpha\nbeta\n" "raw text")
      (check-true! (string-prefix? "1\talpha" (read-file-tool path #t)) "numbered text")
      (delete-file! path))))

(deftest 'tool-result-text-describes-content
  "a text-only lane reads the text blocks and a note for each other block"
  (lambda ()
    (let ((r (tool-content (list (list 'type "text" 'text "image a.png")
                                 (list 'type "image" 'mimeType "image/png" 'data "x")))))
      (check-equal! (tool-result-text r)
                    "image a.png\n[image content: this backend reads text only]"
                    "the note replaces the image")
      (check-equal! (tool-result-text "plain") "plain" "text passes as is"))))

;;; An agent call ran select-frame! around each tool. That moved the frame
;;; order and the window points of the person's frame, and agent edits broke.
(deftest 'agent-call-runs-in-the-chat-frame-and-moves-no-frame
  "a tool call sees the chat's frame; the frame order stays as it was"
  (lambda ()
    (let ((home (selected-frame)))
      (with-frame
        (lambda (frame)
          (buffer-create "*t-agent-chat*")
          (switch-to-buffer! "*t-agent-chat*")
          (select-frame! home)
          (let ((order (frame-list)))
            (check-equal! (mcp-proxy--chat-frame "*t-agent-chat*") frame
                          "the chat frame is the frame that shows the chat")
            (check-equal! (mcp-proxy--in-chat-frame "*t-agent-chat*"
                            (lambda () (selected-frame)))
                          frame "the call sees the chat's frame")
            (check-equal! (selected-frame) home "the frame comes back after the call")
            (check-equal! (frame-list) order "the frame order does not change")
            (check-equal! (mcp-proxy--in-chat-frame "*t-no-such-chat*"
                            (lambda () (selected-frame)))
                          home "a chat that no frame shows keeps the current frame"))))
      (kill-buffer-confirm! "*t-agent-chat*" #f))))

;; The caller is per call: a person's eval has no agent, an agent's eval
;; finds its chat, and a slug with no chat is no agent at all.
(deftest 'llm-tool-buffer-follows-the-edit-author
  "the agent chat of a call comes from the edit author of that call"
  (lambda ()
    (buffer-create "*t-ltb-chat*")
    (buffer-set-local! "*t-ltb-chat*" 'agent-slug "zz-ltb")
    (check-false! (llm-tool-buffer) "a person's call has no agent chat")
    (check-equal! (with-edit-author "agent:zz-ltb" (lambda () (llm-tool-buffer)))
                  "*t-ltb-chat*" "an agent's call finds its chat")
    (check-false! (with-edit-author "agent:zz-ltb-none" (lambda () (llm-tool-buffer)))
                  "a slug with no chat is no agent chat")
    (check-false! (llm-tool-buffer) "nothing stays set after the call")
    (kill-buffer-confirm! "*t-ltb-chat*" #f)))

(deftest 'error-hint-tells-a-daemon-fault-from-a-code-error
  "a daemon fault gets a hint that the fault is not in the caller's code"
  (lambda ()
    (check-true! (string-contains? (tool--error-hint "zz-prim: daemon fault (UndefinedFunctionError): gone" "(zz-prim)")
                                   "not in your code")
                 "a daemon fault says the caller's code is not at fault")
    (check-false! (string-contains? (tool--error-hint "zz-prim: bad value" "(zz-prim)") "daemon")
                  "an ordinary error gets no daemon hint")))

(deftest 'a-near-miss-name-is-named-with-its-route
  "an unbound name one ! or plural away from a real one is named, never run for the caller"
  (lambda ()
    (let ((read (eval-read-refusal "(buffer-texts \"x\")"))
          (write (eval-read-refusal "(chat-stable-id \"x\")")))
      (check-contains! read "buffer-text is" "the plural slip names the real name")
      (check-contains! read "send it here" "a read stays in eval-scheme-read")
      (check-contains! write "chat-stable-id! is" "the missing ! is named")
      (check-contains! write "run it with eval-scheme" "a write names the eval-scheme route"))
    (check-contains! (tool--error-hint "unbound variable: buffer-texts" "")
                     "buffer-text is" "eval-scheme says the same")))

(deftest 'the-read-eval-refuses-a-procedure-it-cannot-see
  "a procedure is a global name, a lambda, or a local bound to one; a procedure from a call result or data is refused"
  (lambda ()
    (for-each (lambda (code)
                (check-contains! (eval-read-refusal code) "cannot see which procedure" code))
              '("(apply (car (list buffer-text)) '(\"x\"))"
                "(map (cadr (list 1 2)) '(1))"
                "((car (list car)) '(1))"
                "(let ((f (car (list car)))) (f '(1)))"
                "(map (lambda (g) (apply g '())) (list car))"))
    (for-each (lambda (code) (check-false! (eval-read-refusal code) code))
              '("(apply + 1 '(2 3))"
                "(map (lambda (x) (car x)) '((1)))"
                "(vector-map char->integer (string->list \"ab\"))"
                "(let loop ((i 0)) (if (< i 3) (loop (+ i 1)) i))"
                "(let ((get (lambda (k) (plist-get '(a 1) k)))) (get 'a))"
                "(let* ((f car) (g f)) (g '(1)))"
                "(list #\\newline (char=? #\\a #\\a))"))))

(deftest 'apropos-without-vectors-still-finds-a-sentence
  "a sentence no row holds whole still finds the rows with its rare words"
  (lambda ()
    (check-equal! (plist-get (car (apropos "chat buffer from stable id" 'lexical #t)) 'name)
                  "chat-stable-id!" "the partial match comes first")))

(deftest 'a-tool-call-with-wrong-arguments-names-the-real-ones
  "a model that guesses argument names gets one line back, never a reader crash and never the whole catalog"
  (lambda ()
    (let ((wrong (llm-tool-call "eval-scheme" '(query "(+ 1 2)")))
          (none (llm-tool-call "eval-scheme" '()))
          (aprop (llm-tool-call "apropos" '(code "x")))
          (blank (llm-tool-call "apropos" '(query "  "))))
      (check-true! (string-prefix? "error: eval-scheme takes {code}; you sent {query}" wrong)
                   "a wrong name is named beside the real one")
      (check-true! (string-contains? none "missing code") "a missing argument is named")
      (check-true! (string-prefix? "error: apropos takes {query}" aprop) "apropos names its arguments")
      (check-true! (< (string-length blank) 200) "a blank query never answers the catalog")
      (check-equal! (llm-tool-call "eval-scheme" '(code "(+ 1 2)")) "3" "a right call runs"))))

(deftest 'a-failed-embedding-sync-tells-the-user-once
  "each retry fails again, and the user hears it one time"
  (lambda ()
    (let ((said 0))
      (with-stub '*apropos--embedding-sync-told* #f
        (lambda ()
          (with-stub 'message (lambda (s) (set! said (+ said 1)) s)
            (lambda ()
              (apropos--sync-failed! "no key")
              (apropos--sync-failed! "no key")))))
      (check-equal! said 1 "two failures, one message"))))
