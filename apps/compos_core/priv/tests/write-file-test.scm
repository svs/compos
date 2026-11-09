;;; write-file-test.scm --- write-file: the typed name, a directory answer, the written directory.

(domain! 'testing)
(effects! '(write))

(define t--wf-dir (string-append (compos-home) "/write-file-test"))

; fresh means empty: a file a previous run left behind turns a plain
; write into an overwrite question, and the test then waits on a prompt
(define (t--wf-fresh-dir name)
  (let ((d (string-append t--wf-dir "/" name)))
    (shell-command->string (string-append "rm -rf " (sh-quote d)))
    (make-directory! d)
    d))

(define (t--wf-cleanup! &rest names)
  (for-each (lambda (n) (when (buffer-exists? n) (buffer-kill! n))) names))

(deftest 'a-directory-answer-writes-the-buffer-name-into-it
  "write-file-target adds the buffer's own name to a directory; a file path stays"
  (lambda ()
    (let ((d (t--wf-fresh-dir "target"))
          (buf "*zz-wf-target*"))
      (test-buffer! buf "text\n")
      (buffer-set-local! buf 'mode-name "scheme-mode")
      (check-equal! (write-file-target buf d)
                    (string-append d "/" (write-file-default-name buf))
                    "a directory takes the buffer's default name")
      (check-true! (string-prefix? (string-append d "/zz-wf-target.")
                                   (write-file-target buf d))
                   "the name is the stem plus the mode extension")
      (check-equal! (write-file-target buf (string-append d "/"))
                    (write-file-target buf d)
                    "a trailing slash names the same directory")
      (check-equal! (write-file-target buf (string-append d "/own.txt"))
                    (string-append d "/own.txt")
                    "a file path is the answer as typed")
      (t--wf-cleanup! buf))))

(deftest 'a-written-buffer-becomes-the-file-and-works-in-its-directory
  "after the write the current buffer is the file, and its directory is the file's"
  (lambda ()
    (let* ((d (t--wf-fresh-dir "plain"))
           (buf "*zz-wf-plain*")
           (p (string-append d "/note.txt")))
      (test-buffer! buf "hello\n")
      (with-current-buffer buf
        (lambda () (write-buffer-to-file! buf p)))
      (check-equal! (buffer-path p) p "the new buffer visits the written file")
      (check-equal! (read-file p) "hello\n" "the file holds the text")
      (check-equal! (buffer-directory p) (string-append d "/")
                    "the buffer works in the written directory")
      (check-false! (buffer-exists? buf) "the nameless buffer is gone")
      (t--wf-cleanup! p))))

(deftest 'a-directory-answer-lands-the-buffer-name-in-that-directory
  "write-buffer-to-file! with a directory writes DIR/<name>, as Emacs does"
  (lambda ()
    (let* ((d (t--wf-fresh-dir "landing"))
           (buf "*zz-wf-landing*")
           (p (string-append d "/zz-wf-landing")))
      (test-buffer! buf "landed\n")
      (with-current-buffer buf
        (lambda () (write-buffer-to-file! buf d)))
      (check-equal! (buffer-path p) p "the buffer name became the file name")
      (check-equal! (read-file p) "landed\n" "the file holds the text")
      (t--wf-cleanup! p))))

(deftest 'a-written-chat-keeps-the-written-directory
  "a chat written on purpose records that directory as its own, and the header carries it"
  (lambda ()
    (let* ((d (t--wf-fresh-dir "chat"))
           (buf "*zz-wf-chat*")
           (p (string-append d "/zz-wf-chat.chat")))
      (test-buffer! buf "plain chat text\n")
      (buffer-set-local! buf 'agent-slug "zz-wf")
      (with-current-buffer buf
        (lambda () (write-buffer-to-file! buf p)))
      (check-equal! (buffer-local-value 'chat-directory p) (string-append d "/")
                    "the written directory is chat identity")
      (check-equal! (buffer-directory p) (string-append d "/")
                    "the chat works in the written directory")
      (buffer-set-local! p 'agent-connector "api")
      (check-true! (string-contains? (chat-header-line p)
                                     (string-append " directory \"" d "/\""))
                   "the .chat header names the directory")
      (let ((header (chat-parse-header (chat-header-line p))))
        (check-equal! (plist-get header 'directory) (string-append d "/")
                      "the header reads back"))
      (t--wf-cleanup! p))))
