;;; buffer-link-test.scm --- links that route back through this daemon

(domain! 'testing)
(effects! '(read))

(deftest 'an-compos-link-names-the-buffer-line-and-exact-daemon-socket
  "custom-protocol links return to the daemon that created them"
  (lambda ()
    (check-equal!
      (compos-link "/tmp/a file.md" 34)
      (string-append
        "compos://open?path=%2Ftmp%2Fa%20file.md&socket="
        (url-encode (compos-socket-path))
        "&line=34")
      "the path and socket are safe URL fields and the line is preserved")))

(deftest 'a-buffer-link-includes-the-machine-hostname-and-port
  "buffer-link and copy-buffer-link carry the machine hostname, port, buffer, and line"
  (lambda ()
    (let ((expected-base (string-replace (editor-url) "://localhost"
                                         (string-append "://" (system-name)))))
      (check-equal!
        (buffer-link "/tmp/a file.md" 34)
        (string-append expected-base "/b/%2Ftmp%2Fa%20file.md?line=34")
        "buffer-link uses the machine hostname and port")
      (let ((buf (test-buffer! "zz-link-test-buf" "one\ntwo\n")))
        (with-current-buffer buf
          (lambda ()
            (goto-char! 4)
            (run-command "copy-buffer-link")
            (check-equal! (kill-top)
                          (string-append expected-base "/b/zz-link-test-buf?line=2")
                          "copy-buffer-link copies the host, port, buffer, and line")))
        (buffer-kill! buf)))))
