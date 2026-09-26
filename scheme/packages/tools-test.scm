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
