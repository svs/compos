;;; IRC codec and client policy tests.

(deftest 'irc-parses-prefix-and-trailing
  "IRC parsing keeps the prefix, command, parameters, and trailing text."
  (lambda ()
    (let ((m (irc-parse ":nick!user@host PRIVMSG #compos :hello world\r\n")))
      (check-equal! (plist-get m 'prefix) "nick!user@host" "prefix")
      (check-equal! (plist-get m 'command) "PRIVMSG" "command")
      (check-equal! (plist-get m 'params) (list "#compos") "params")
      (check-equal! (plist-get m 'trailing) "hello world" "trailing"))))

(deftest 'irc-formats-trailing-message
  "IRC formatting emits uppercase commands and IRC line endings."
  (lambda ()
    (check-equal! (irc-format "privmsg" (list "#compos") "hello world")
                  "PRIVMSG #compos :hello world\r\n" "formatted message")))

;;; --- formatting -------------------------------------------------------------
;;; Every rule answers one row: the line's text, and the (START END FACE)
;;; spans that colour it, in bytes from the start of that line.

(tests-need-a-disposable-editor!
  "repoints *irc-buffer* and appends transcript lines")

(define (t--irc-columns!)
  (set! irc-show-time #f)
  (set! irc-nick-width 12)
  (set! irc-nick "composguest"))

(deftest 'irc-aligns-the-nick-column
  "A said line right-aligns the nick, and colours the nick, not the padding."
  (lambda ()
    (t--irc-columns!)
    (let ((row (irc-said "oskarw" "hello")))
      (check-equal! (irc-row-text row) "      oskarw  hello" "line text")
      (check-equal! (car (irc-row-spans row))
                    (list 6 12 (irc-nick-face "oskarw"))
                    "the nick span"))))

(deftest 'irc-keeps-one-colour-per-nick
  "A nick keeps its colour whatever its case, and your own nick is your own."
  (lambda ()
    (t--irc-columns!)
    (check-equal! (irc-nick-face "oskarw") (irc-nick-face "OskarW") "case folds")
    (check-equal! (irc-nick-face "composguest") "irc-self" "your own nick")
    (check-true! (string-prefix? "irc-nick-" (irc-nick-face "skulk"))
                 "anyone else comes from the palette")))

(deftest 'irc-marks-a-mention-and-a-link
  "Text that names you is highlighted, and a URL underlines where it sits."
  (lambda ()
    (t--irc-columns!)
    (let ((row (irc-said "skulk" "composguest: see https://bpa.st/x")))
      (check-true! (member (list 14 47 "irc-mention") (irc-row-spans row))
                   "the whole text is highlighted")
      (check-true! (member (list 31 47 "irc-url") (irc-row-spans row))
                   "the URL keeps its own span"))
    (check-false! (member (list 14 19 "irc-mention")
                          (irc-row-spans (irc-said "skulk" "hello")))
                  "a line that names nobody stays plain")))

(deftest 'irc-clock-leads-the-line
  "With the clock on, a line starts HH:MM and the stamp is dim."
  (lambda ()
    (t--irc-columns!)
    (set! irc-show-time #t)
    (let ((row (irc-said "oskarw" "hello")))
      (check-true! (re-match? "^[0-9][0-9]:[0-9][0-9] " (irc-row-text row)) "the clock")
      (check-equal! (car (irc-row-spans row)) (list 0 5 "irc-time") "the stamp span"))
    (set! irc-show-time #f)))

(deftest 'irc-marks-what-the-client-says
  "The client speaks between marks: -!- for a note, * for an action."
  (lambda ()
    (t--irc-columns!)
    (let ((note (irc-note "joining #emacs")))
      (check-equal! (irc-row-text note) "         -!-  joining #emacs" "note text")
      (check-true! (member (list 9 12 "irc-marker") (irc-row-spans note)) "the mark")
      (check-true! (member (list 14 28 "irc-note") (irc-row-spans note)) "a quiet body"))
    (let ((act (irc-action "oskarw" "waves")))
      (check-equal! (irc-row-text act) "           *  oskarw waves" "action text")
      (check-true! (member (list 14 26 "irc-action") (irc-row-spans act)) "italic body")
      (check-true! (member (list 14 20 (irc-nick-face "oskarw")) (irc-row-spans act))
                   "the nick keeps its colour inside the sentence"))))

(deftest 'irc-paints-the-line-it-appends
  "Every appended line carries its spans at the offset it landed on."
  (lambda ()
    (t--irc-columns!)
    (let ((was *irc-buffer*))
      (set! *irc-buffer* "*irc-format-test*")
      (buffer-create *irc-buffer*)
      (overlay-clear! *irc-buffer* 'all)
      (set! *irc-spans* '())
      (set! *irc-chunk* 0)
      (set! *irc-chunk-rows* 0)
      (irc-display (irc-said "oskarw" "one"))
      (let ((base (buffer-size *irc-buffer*)))
        (irc-display (irc-said "oskarw" "two"))
        (check-equal! (buffer-text *irc-buffer*)
                      "      oskarw  one\n      oskarw  two\n"
                      "both lines")
        (check-true! (member (list (+ base 6) (+ base 12) (irc-nick-face "oskarw"))
                             (buffer-overlays *irc-buffer*))
                     "the second nick is painted where it landed"))
      (let ((size (buffer-size *irc-buffer*)))
        (irc-display (irc-flow "-->" "oskarw" "joined"))
        (check-equal! (buffer-size *irc-buffer*) size
                      "a kind you did not name never lands"))
      (buffer-kill! *irc-buffer*)
      (set! *irc-buffer* was)
      (set! *irc-spans* '()))))

(deftest 'irc-shows-only-the-kinds-you-name
  "Three kinds carry what people say, and those three are the default."
  (lambda ()
    (t--irc-columns!)
    (check-equal! irc-line-types (list "said" "action" "note") "the default kinds")
    (check-true! (irc-shows? (irc-row-kind (irc-said "oskarw" "hello"))) "said")
    (check-true! (irc-shows? (irc-row-kind (irc-action "oskarw" "waves"))) "action")
    (check-true! (irc-shows? (irc-row-kind (irc-note "joining #emacs"))) "note")
    (check-false! (irc-shows? (irc-row-kind (irc-flow "-->" "oskarw" "joined"))) "flow")
    (check-false! (irc-shows? (irc-row-kind (irc-server "platinum.libera.chat" "hi")))
                  "server")
    (let ((was irc-line-types))
      (set! irc-line-types (append irc-line-types (list "flow")))
      (check-true! (irc-shows? (irc-row-kind (irc-flow "-->" "oskarw" "joined")))
                   "naming a kind brings it back")
      (set! irc-line-types was))))

(deftest 'irc-replays-a-frame-on-the-clock-it-arrived-on
  "A redraw draws each frame with the time the server sent it, and your own
line stays yours."
  (lambda ()
    (t--irc-columns!)
    (set! irc-show-time #t)
    (let ((row (irc-replay-frame (list "00:23:18" "in" ":oskarw!~u@h PRIVMSG #emacs :hello\r"))))
      (check-equal! (irc-row-text row) "00:23       oskarw  hello"
                    "the frame keeps the clock it arrived on")
      (check-equal! (car (irc-row-spans row)) (list 0 5 "irc-time") "the stamp span"))
    (let ((mine (irc-replay-frame (list "00:24:01" "out" "PRIVMSG #emacs :hi\r"))))
      (check-equal! (irc-row-text mine)
                    (string-append "00:24 " (string-pad-left irc-nick 12) "  hi")
                    "a line you sent comes back as yours")
      (check-equal! (irc-row-kind mine) "said" "and it is a said line"))
    (check-false! (irc-replay-frame (list "00:24:02" "in" "PING :x\r"))
                  "a keepalive draws nothing")
    (set! *irc-clock* #f)
    (set! irc-show-time #f)))
