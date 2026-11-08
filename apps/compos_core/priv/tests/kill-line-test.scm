;;; kill-line-test.scm --- what kill-line! takes.
;;;
;;; From point to the line end; at the line end, the newline alone; at the
;;; buffer end, nothing. A carriage return is text like any other. A
;;; read-only buffer refuses.

(domain! 'testing)
(effects! '(write))

(define t--kl-buf "*zz-kill-line*")

(define (t--kl text pos)
  (when (buffer-known? t--kl-buf) (buffer-kill! t--kl-buf))
  (buffer-create t--kl-buf)
  (buffer-append! t--kl-buf text)
  (with-current-buffer t--kl-buf
    (lambda ()
      (goto-char! pos)
      (let* ((killed (kill-line!))
             (r (list killed (buffer-text t--kl-buf) (point))))
        (buffer-kill! t--kl-buf)
        r))))

(deftest 'kill-line-takes-the-rest-of-the-line-or-the-newline
  "mid line, line end, buffer end, carriage return, multibyte"
  (lambda ()
    (check-equal! (t--kl "abc\ndef" 1) '("bc" "a\ndef" 1) "mid line")
    (check-equal! (t--kl "abc\ndef" 3) '("\n" "abcdef" 3) "at the line end")
    (check-equal! (t--kl "abc\ndef" 7) '("" "abc\ndef" 7) "at the buffer end")
    (check-equal! (t--kl "ab\r\ncd" 0) '("ab\r" "\ncd" 0) "a carriage return is text")
    (check-equal! (t--kl "xé😀\ny" 1) '("é😀" "x\ny" 1) "multibyte")))

(deftest 'kill-line-refuses-a-read-only-buffer
  "read-only raises, even at the buffer end"
  (lambda ()
    (when (buffer-known? t--kl-buf) (buffer-kill! t--kl-buf))
    (buffer-create t--kl-buf)
    (buffer-append! t--kl-buf "abc")
    (buffer-set-read-only! t--kl-buf #t)
    (let ((mid (with-current-buffer t--kl-buf
                 (lambda () (goto-char! 1) (ignore-errors (lambda () (kill-line!) 'no-error)))))
          (end (with-current-buffer t--kl-buf
                 (lambda () (goto-char! 3) (ignore-errors (lambda () (kill-line!) 'no-error))))))
      (check-equal! (list mid end (buffer-text t--kl-buf)) '(#f #f "abc") "refused, text kept"))
    (buffer-set-read-only! t--kl-buf #f)
    (buffer-kill! t--kl-buf)))
