;;; help-page-test.scm --- what the help pages are made of.
;;;
;;; The apropos page, the component gallery, the name under point, and the
;;; audit that every mode says what it is for.
;;;
;;; Twenty tests stay in ExUnit: C-h m, C-h b, C-h k and M-? are key
;;; behaviour, and the scroll tests read a rendered window.

(domain! 'testing)
(effects! '(write))

(deftest 'the-apropos-page-groups-hits-by-kind-and-keeps-a-docstring-on-one-row
  "a docstring with a newline and a pipe still reads as one table row"
  (lambda ()
    (define-command "zz-apr" "First line.\nSecond | line." (lambda () #t))
    (apropos-page "zz-apr")
    (let ((text (buffer-text "*Help*")))
      (check-contains! text "## Commands" "the kind heading")
      ;; the owner/effects trailer closes the row; the package that owns a
      ;; runtime define depends on load order, so match only its shape
      (check-contains! text "- **`zz-apr`** — First line. Second \\| line. *("
                       "one row, the pipe escaped"))
    (when (buffer-known? "*Help*") (buffer-kill! "*Help*"))
    (test-forget-catalog! "command" "zz-apr")))

(deftest 'the-component-gallery-renders-every-registered-example
  "a component with a broken example is a component nobody can use"
  (lambda ()
    (run-command "component-gallery")
    (check-equal! (buffer-local "*Components*" 'render-mode) "blocks" "the gallery renders blocks")
    (let ((blocks (value->string (buffer-local "*Components*" 'render-blocks))))
      (check-contains! blocks "ui/card" "a component")
      (check-contains! blocks "c-badge" "and another")
      (check-false! (string-contains? blocks "error") "and none of them failed"))
    (when (buffer-known? "*Components*") (buffer-kill! "*Components*"))))

(deftest 'symbol-at-point-reads-the-name-around-point
  "and stops at the edges, the way Emacs does"
  (lambda ()
    (let ((buf (test-buffer! "*zz-help-sym*" "a (split-window! 2) b"))
          (here (current-buffer)))
      (with-current-buffer buf
        (lambda ()
          ;; inside the name
          (goto-char! 7)
          (check-equal! (symbol-at-point) "split-window!" "inside the name")
          ;; just after its last character — Emacs answers here too
          (goto-char! 16)
          (check-equal! (symbol-at-point) "split-window!" "just past its end")
          ;; on the space before it
          (goto-char! 2)
          (check-false! (symbol-at-point) "on the space before it")))
      (when (buffer-known? here) (switch-to-buffer! here))
      (buffer-kill! buf))))

(deftest 'symbol-at-point-survives-a-point-inside-a-multi-byte-character
  "one byte of an em dash floors to an empty string, and that must not raise"
  (lambda ()
    ;; substring-bytes floors both ends to a character boundary, so one
    ;; byte of an em dash comes back empty — and string-index rejects an
    ;; empty pattern. M-? over prose used to abort the whole command here.
    (let ((buf (test-buffer! "*zz-help-sym*" "a — b"))
          (here (current-buffer)))
      (with-current-buffer buf
        (lambda ()
          (let loop ((p 0))
            (when (<= p 7)
              (goto-char! p)
              (symbol-at-point)
              (loop (+ p 1))))))
      (check-true! #t "every byte offset answered without raising")
      (when (buffer-known? here) (switch-to-buffer! here))
      (buffer-kill! buf))))

(deftest 'the-locals-page-lists-what-the-buffer-knows
  "the keys say what you can press; the locals say what the buffer knows"
  (lambda ()
    (let ((buf (test-buffer! "*zz-help-locals*" "text"))
          (here (current-buffer)))
      (buffer-set-local! buf 'zz-flavour "vanilla")
      (buffer-set-local! buf 'zz-rows '(1 2 3 4 5 6))
      (with-current-buffer buf (lambda () (run-command "describe-buffer-locals")))
      (let ((text (buffer-text "*Help*")))
        (check-contains! text "# Buffer locals" "the page")
        (check-contains! text "`zz-flavour`" "the name of a local")
        (check-contains! text "\"vanilla\"" "its value")
        (check-contains! text "(6 items)"
                         "a long value says its size, not its contents")
        (check-false! (string-contains? text "## Everywhere")
                      "and the page is locals, not keys"))
      (when (buffer-known? "*Help*") (buffer-kill! "*Help*"))
      (when (buffer-known? here) (switch-to-buffer! here))
      (buffer-kill! buf))))

(deftest 'every-mode-says-what-it-is-for
  "a mode with no doc still gets its key table, so the gap is invisible"
  (lambda ()
    ;; zz- modes are test fixtures: another file's define-mode outlives it
    ;; in the same interpreter, and the audit is about the modes we ship
    (check-equal!
      (filter (lambda (m) (and (not (mode-doc m)) (not (string-prefix? "zz-" m))))
              (map car *mode-setups*))
      '() "every mode calls mode-doc!")))
