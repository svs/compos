;;; mode-icon-test.scm --- one glyph names a mode.
;;;
;;; Dired, ibuffer and the prompts all read the same registry, so a chat
;;; looks like a chat wherever it is listed. The glyphs are Nerd Font
;;; characters: one cell each, in the colour of the text.
;;;
;;; The two dired tests stay in ExUnit: they need a directory of files on
;;; disk, and this Scheme has no way to remove one.

(domain! 'testing)
(effects! '(write))

(define t--icon-chat "")
(define t--icon-dired "")
(define t--icon-elixir "")
(define t--icon-doc "")

(deftest 'a-mode-answers-with-its-own-icon
  "the registry names one glyph per mode"
  (lambda ()
    (check-equal! (mode-icon "chat-mode") t--icon-chat "chat")
    (check-equal! (mode-icon "Dired") t--icon-dired "dired")
    (check-equal! (mode-icon "elixir-mode") t--icon-elixir "elixir")))

(deftest 'a-mode-that-declares-none-reads-as-a-plain-document
  "every mode gets an icon, declared or not"
  (lambda ()
    (check-equal! (mode-icon "zz-no-such-mode") t--icon-doc "an unknown mode")
    (check-equal! (mode-icon #f) t--icon-doc "no mode at all")))

(deftest 'mode-icon-declares-one-and-declaring-again-replaces-it
  "one mode holds one glyph"
  (lambda ()
    (mode-icon! "zz-icon-mode" "")
    (check-equal! (mode-icon "zz-icon-mode") "" "the first glyph")
    (mode-icon! "zz-icon-mode" "")
    (check-equal! (mode-icon "zz-icon-mode") "" "the second replaces it")
    (set! *mode-icons*
      (remove (lambda (e) (equal? (car e) "zz-icon-mode")) *mode-icons*))))

(deftest 'mode-label-writes-the-icon-in-front-of-the-name
  "the label is the glyph, a space, and the name"
  (lambda ()
    (check-equal! (mode-label "chat-mode") " chat-mode" "a named mode")
    (check-equal! (mode-label #f) " Fundamental" "no mode at all")))

(deftest 'a-file-name-wears-the-icon-of-the-mode-it-would-open-in
  "the name decides the mode, and the mode decides the glyph"
  (lambda ()
    (check-equal! (file-icon "a.ex") t--icon-elixir "elixir")
    (check-equal! (file-icon "a.md") "" "markdown")
    (check-equal! (file-icon "a.rs") "" "rust")
    ;; a listing marks a directory with a trailing slash
    (check-equal! (file-icon "sub/") t--icon-dired "a directory")
    ;; a name no rule claims still gets an icon
    (check-equal! (file-icon "LICENSE") t--icon-doc "a name no rule claims")))

(deftest 'a-buffer-wears-the-icon-of-the-mode-it-is-in
  "the buffer reads its own mode-name"
  (lambda ()
    (test-buffer! "*zz-icon*" "")
    (buffer-set-local! "*zz-icon*" 'mode-name "chat-mode")
    (check-equal! (buffer-icon "*zz-icon*") t--icon-chat "a chat buffer")
    (buffer-kill! "*zz-icon*")))

(effects! '(read))

;; The one line of TEXT that names BUF, or #f.
(define (t--icon-row text buf)
  (let loop ((ls (string-split text "\n")))
    (cond ((null? ls) #f)
          ((string-contains? (car ls) buf) (car ls))
          (else (loop (cdr ls))))))

;; Where NEEDLE starts in S, counted in characters.
(define (t--icon-at s needle)
  (let loop ((i 0))
    (cond ((> (+ i (string-length needle)) (string-length s)) -1)
          ((equal? (substring s i (+ i (string-length needle))) needle) i)
          (else (loop (+ i 1))))))

(effects! '(write))

(deftest 'the-switcher-leads-each-rows-annotation-with-the-icon
  "the annotation follows the name, and the icon leads it"
  (lambda ()
    (test-buffer! "*zz-icon-chat*" "")
    (buffer-set-local! "*zz-icon-chat*" 'mode-name "chat-mode")
    (run-command "switch-to-buffer")
    (let ((row (t--icon-row (buffer-text "*switch*") "*zz-icon-chat*")))
      (check-true! (string? row) "the switcher lists the buffer")
      (when (string? row)
        (check-contains! row t--icon-chat "the row wears the chat icon")
        (check-true! (< (t--icon-at row "*zz-icon-chat*") (t--icon-at row t--icon-chat))
                     "the name comes first, then the icon")))
    (run-command "switch-quit")
    (buffer-kill! "*zz-icon-chat*")))

(deftest 'the-buffer-prompt-annotates-with-the-same-icon
  "one registry, read by the prompt too"
  (lambda ()
    (test-buffer! "*zz-icon-chat2*" "")
    (buffer-set-local! "*zz-icon-chat2*" 'mode-name "chat-mode")
    (let ((note (cadr (car (annotate 'buffer (list "*zz-icon-chat2*"))))))
      (check-contains! note t--icon-chat "the annotation wears the chat icon")
      (check-contains! note "chat-mode" "the annotation names the mode")
      (check-true! (< (t--icon-at note t--icon-chat) (t--icon-at note "chat-mode"))
                   "the icon leads the name"))
    (buffer-kill! "*zz-icon-chat2*")))
