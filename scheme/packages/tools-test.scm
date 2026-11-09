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
