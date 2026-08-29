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
