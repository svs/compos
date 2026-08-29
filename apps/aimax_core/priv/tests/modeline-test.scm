;;; modeline-test.scm — buffer modelines keep compact names.

(domain! 'testing)
(effects! '(write execute))

(define t--modeline-root
  (string-append (aimax-home) "/zz-modeline-project"))

(define (t--modeline-reset!)
  (shell-command->string (string-append "rm -rf " t--modeline-root)))

(deftest 'a-project-file-keeps-a-project-relative-buffer-modeline-name
  "the buffer modeline stays compact while the frame bar owns the full path"
  (lambda ()
    (t--modeline-reset!)
    (make-directory! (string-append t--modeline-root "/.git"))
    (let ((path (string-append t--modeline-root "/lib/example.scm")))
      (make-directory! (string-append t--modeline-root "/lib"))
      (write-file! path "(display \"example\")\n")
      (visit path)
      (dashboard--sync! path)
      (check-equal! (buffer-modeline-name path) "lib/example.scm"
                    "the buffer modeline policy returns project coordinates")
      (check-equal! (buffer-local path 'modeline-name) "lib/example.scm"
                    "the rendered buffer modeline stores the compact name")
      (buffer-kill! path))
    (t--modeline-reset!)))

(deftest 'a-non-file-buffer-keeps-its-buffer-name-in-the-modeline
  "the file path policy does not rename a non-file buffer"
  (lambda ()
    (let ((buf "*zz-modeline-non-file*"))
      (test-buffer! buf "")
      (check-equal! (buffer-modeline-name buf) buf
                    "the non-file buffer keeps its name")
      (buffer-kill! buf))))
