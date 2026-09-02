;;; IRC codec and client policy tests.

(deftest 'irc-parses-prefix-and-trailing
  "IRC parsing keeps the prefix, command, parameters, and trailing text."
  (lambda ()
    (let ((m (irc-parse ":nick!user@host PRIVMSG #compos :hello world\r\n")))
      (check-equal! (plist-get m 'prefix) "nick!user@host" "prefix")
      (check-equal! (plist-get m 'command) "PRIVMSG" "command")
      (check-equal! (plist-get m 'params) (list "#compos") "params")
      (check-equal! (plist-get m 'trailing) "hello world" "trailing"))))

(deftest 'irc-parse-drops-a-bare-cr
  "The line framing splits on newline, so a frame ends in a bare CR; the
parser drops it from the last field."
  (lambda ()
    (let ((m (irc-parse ":a!u@h JOIN :#chan\r")))
      (check-equal! (plist-get m 'trailing) "#chan" "trailing"))
    (let ((m (irc-parse ":s MODE #chan +Cnst\r")))
      (check-equal! (plist-get m 'params) (list "#chan" "+Cnst") "params"))))

(deftest 'irc-formats-trailing-message
  "IRC formatting emits uppercase commands and IRC line endings."
  (lambda ()
    (check-equal! (irc-format "privmsg" (list "#compos") "hello world")
                  "PRIVMSG #compos :hello world\r\n" "formatted message")))

;;; --- formatting -------------------------------------------------------------
;;; Every rule answers one row: the line's text, and the (START END FACE)
;;; spans that colour it, in bytes from the start of that line.

(tests-need-a-disposable-editor!
  "makes IRC buffers, switches to them, and appends transcript lines")

(define (t--irc-columns!)
  (set! irc-show-time #f)
  (set! irc-verbose #f)
  (set! irc-nick-width 12)
  (set! irc-nick "composguest")
  (set! *irc-cur* #f))

;; a server "t" that is connected, with every byte it is sent kept here
(define *t-irc-sent* '())

(define (t--irc-fake! name)
  (t--irc-columns!)
  (set! *t-irc-sent* '())
  (set! *irc-send* (lambda (ep text) (set! *t-irc-sent* (append *t-irc-sent* (list text)))))
  (irc-conn-set! name (list 'endpoint (irc-endpoint name) 'host "h" 'port "6667"
                            'nick "composguest" 'status "ready" 'registered #t))
  (set! *irc-cur* name))

(define (t--irc-clean! name)
  (for-each buffer-kill! (irc-buffers name))
  (when (buffer-known? (irc-channels-buffer name)) (buffer-kill! (irc-channels-buffer name)))
  (set! *irc-conns* (remove (lambda (e) (equal? (car e) name)) *irc-conns*))
  (set! *irc-send* (lambda (ep text) (endpoint-send! ep text)))
  (set! *irc-cur* #f)
  (set! irc-verbose #f))

(define (t--irc-frame! name line)
  (irc-handle-frame! name (irc-parse line)))

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

(deftest 'irc-shows-only-the-kinds-you-name
  "Three kinds carry what people say, and those three are the default.
Verbose shows every kind."
  (lambda ()
    (t--irc-columns!)
    (check-equal! irc-line-types (list "said" "action" "note") "the default kinds")
    (check-true! (irc-shows? (irc-row-kind (irc-said "oskarw" "hello"))) "said")
    (check-true! (irc-shows? (irc-row-kind (irc-action "oskarw" "waves"))) "action")
    (check-true! (irc-shows? (irc-row-kind (irc-note "joining #emacs"))) "note")
    (check-false! (irc-shows? (irc-row-kind (irc-flow "-->" "oskarw" "joined"))) "flow")
    (check-false! (irc-shows? (irc-row-kind (irc-server "platinum.libera.chat" "hi")))
                  "server")
    (set! irc-verbose #t)
    (check-true! (irc-shows? "flow") "verbose shows a join")
    (check-true! (irc-shows? "server") "verbose shows the server")
    (set! irc-verbose #f)))

;;; --- buffers ----------------------------------------------------------------

(deftest 'irc-paints-the-line-it-appends
  "Every appended line carries its spans at the offset it landed on, and a
kind you did not name never lands."
  (lambda ()
    (t--irc-fake! "t")
    (let ((buf (irc-buffer! "t" "#x")))
      (check-equal! (irc-buf-server buf) "t" "the buffer knows its server")
      (check-equal! (irc-buf-target buf) "#x" "and its channel")
      (irc-display buf (irc-said "oskarw" "one"))
      (let ((base (irc-mark buf)))
        (irc-display buf (irc-said "oskarw" "two"))
        (check-true! (string-suffix? "      oskarw  one\n      oskarw  two\n" (buffer-text buf))
                     "both lines, in order")
        (check-true! (member (list (+ base 6) (+ base 12) (irc-nick-face "oskarw"))
                             (buffer-overlays buf))
                     "the second nick is painted where it landed"))
      (let ((size (buffer-size buf)))
        (irc-display buf (irc-flow "-->" "oskarw" "joined"))
        (check-equal! (buffer-size buf) size "a kind you did not name never lands")))
    (t--irc-clean! "t")))

(deftest 'irc-numeric-keeps-its-params
  "A numeric drops your nick and keeps the rest of its params before its text."
  (lambda ()
    (t--irc-columns!)
    (check-true! (string-suffix? "36 IRC Operators online"
                                 (irc-row-text (irc-message (irc-parse ":s.libera.chat 252 me 36 :IRC Operators online"))))
                 "params then text")
    (check-true! (string-suffix? "me sets mode +iw"
                                 (irc-row-text (irc-message (irc-parse ":me MODE me :+iw"))))
                 "a mode on yourself reads the trailing")))

(deftest 'irc-routes-a-frame-to-its-buffer
  "A channel message goes to the channel, a private message to the person,
and the rest to the server buffer."
  (lambda ()
    (check-equal! (irc-route (irc-parse ":a!u@h PRIVMSG #chan :hi")) "#chan" "channel talk")
    (check-equal! (irc-route (irc-parse ":a!u@h PRIVMSG composguest :hi")) "a" "a private message")
    (check-equal! (irc-route (irc-parse ":a!u@h JOIN :#chan")) "#chan" "a join with trailing")
    (check-equal! (irc-route (irc-parse ":s.libera.chat 332 me #chan :topic")) "#chan" "the topic")
    (check-equal! (irc-route (irc-parse ":s.libera.chat 479 me #chan :Illegal channel name")) "#chan"
                  "an error about a channel")
    (check-false! (irc-route (irc-parse ":s.libera.chat NOTICE me :hi")) "a server notice")
    (check-false! (irc-route (irc-parse ":s.libera.chat 001 me :welcome")) "a numeric")))

(deftest 'irc-typed-text-goes-to-the-channel
  "RET takes the input past the mark, sends it to the channel, and draws it
as yours."
  (lambda ()
    (t--irc-fake! "t")
    (let ((buf (irc-buffer! "t" "#x")))
      (with-current-buffer buf (lambda () (end-of-buffer!) (insert! "hello there")))
      (check-equal! (irc-input-text buf) "hello there" "the input is what you typed")
      (irc-send-input! buf)
      (check-equal! *t-irc-sent* (list "PRIVMSG #x :hello there\r\n") "sent to the channel")
      (check-equal! (irc-input-text buf) "" "the input clears")
      (check-true! (string-suffix? " composguest  hello there\n" (buffer-text buf))
                   "and the transcript shows it as yours"))
    (let ((srv (irc-buffer! "t" #f)))
      (with-current-buffer srv (lambda () (end-of-buffer!) (insert! "hello")))
      (irc-send-input! srv)
      (check-equal! (length *t-irc-sent*) 1 "a server buffer sends no text")
      (check-true! (string-contains? (buffer-text srv) "this is the server buffer")
                   "and says why"))
    (t--irc-clean! "t")))

(deftest 'irc-slash-commands
  "/join opens the channel buffer, /me sends an action, /nick changes the
nick when the server confirms, and an unknown word goes raw."
  (lambda ()
    (t--irc-fake! "t")
    (let ((srv (irc-buffer! "t" #f)))
      (irc-input! srv "/join emacs")
      (check-equal! *t-irc-sent* (list "JOIN #emacs\r\n") "join, with the # you left off")
      (check-true! (buffer-known? (irc-target-buffer "t" "#emacs")) "the channel buffer exists")
      (check-equal! (current-buffer) (irc-target-buffer "t" "#emacs") "and is where you are"))
    (let ((chan (irc-buffer! "t" "#emacs")))
      (set! *t-irc-sent* '())
      (irc-input! chan "/me waves")
      (check-equal! *t-irc-sent* (list "PRIVMSG #emacs :\x01;ACTION waves\x01;\r\n") "an action")
      (check-true! (string-suffix? "*  composguest waves\n" (buffer-text chan)) "drawn as one")
      (set! *t-irc-sent* '())
      (irc-input! chan "/whois skulk")
      (check-equal! *t-irc-sent* (list "WHOIS skulk\r\n") "an unknown word goes raw")
      (set! *t-irc-sent* '())
      (irc-input! chan "/nick bob")
      (check-equal! *t-irc-sent* (list "NICK bob\r\n") "a nick change is asked")
      (check-equal! (irc-self-nick "t") "composguest" "and not taken before the server says")
      (t--irc-frame! "t" ":composguest!u@h NICK :bob")
      (check-equal! (irc-self-nick "t") "bob" "the server confirms")
      (check-equal! (irc-nick-face "bob") "irc-self" "and bob is you now"))
    (t--irc-clean! "t")))

(deftest 'irc-quiet-by-default
  "A join lands in the channel buffer only when verbose is on."
  (lambda ()
    (t--irc-fake! "t")
    (let* ((chan (irc-buffer! "t" "#x"))
           (size (buffer-size chan)))
      (t--irc-frame! "t" ":oskarw!u@h JOIN :#x")
      (check-equal! (buffer-size chan) size "quiet drops the join")
      (t--irc-frame! "t" ":oskarw!u@h PRIVMSG #x :hello")
      (check-true! (string-suffix? "oskarw  hello\n" (buffer-text chan)) "and keeps the talk")
      (set! irc-verbose #t)
      (t--irc-frame! "t" ":oskarw!u@h JOIN :#x")
      (check-true! (string-suffix? "-->  oskarw joined\n" (buffer-text chan)) "verbose shows it")
      (set! irc-verbose #f))
    (t--irc-clean! "t")))

(deftest 'irc-join-waits-for-registration
  "A join before 001 waits in the record and goes out when the server
registers you, with the entry's own channels."
  (lambda ()
    (t--irc-fake! "t")
    (irc-conn-put! "t" 'registered #f)
    (irc-join! "t" "#early" "")
    (check-equal! *t-irc-sent* '() "nothing sent before 001")
    (check-true! (string-contains? (buffer-text (irc-target-buffer "t" "#early")) "once the server")
                 "and the buffer says so")
    (t--irc-frame! "t" ":s.libera.chat 001 composguest :Welcome")
    (check-equal! *t-irc-sent* (list "JOIN #early\r\n") "001 sends the join")
    (check-true! (irc-registered? "t") "and you are registered")
    (set! *t-irc-sent* '())
    (irc-join! "t" "#late" "")
    (check-equal! *t-irc-sent* (list "JOIN #late\r\n") "a join after 001 goes at once")
    (t--irc-clean! "t")))

(deftest 'irc-nick-in-use-tries-another
  "433 makes the client try the nick with an underscore."
  (lambda ()
    (t--irc-fake! "t")
    (irc-buffer! "t" #f)
    (t--irc-frame! "t" ":s.libera.chat 433 * composguest :Nickname is already in use.")
    (check-equal! *t-irc-sent* (list "NICK composguest_\r\n") "the next nick is asked")
    (check-equal! (irc-self-nick "t") "composguest_" "and is the one you are")
    (t--irc-clean! "t")))

(deftest 'irc-list-fills-the-channel-list
  "The 322 rows of /list collect until 323 and show as a list, busiest first."
  (lambda ()
    (t--irc-fake! "t")
    (irc-buffer! "t" #f)
    (t--irc-frame! "t" ":s.libera.chat 321 me Channel :Users  Name")
    (t--irc-frame! "t" ":s.libera.chat 322 me #small 3 :a small room")
    (t--irc-frame! "t" ":s.libera.chat 322 me #big 300 :the big room")
    (t--irc-frame! "t" ":s.libera.chat 323 me :End of /LIST")
    (let ((buf (irc-channels-buffer "t")))
      (check-true! (buffer-known? buf) "the list buffer exists")
      (check-equal! (list-entries buf)
                    (list (list "#big" "300" "the big room") (list "#small" "3" "a small room"))
                    "busiest first")
      (check-equal! (buffer-local buf 'mode-name) "irc-channels-mode" "in its mode"))
    (t--irc-clean! "t")))

(deftest 'irc-servers-list-shows-status
  "A server row shows off until the connection is ready."
  (lambda ()
    (t--irc-columns!)
    (check-equal! (car (car (irc-servers-cells #f "libera"))) "○" "off before a connect")
    (check-equal! (car (cadr (irc-servers-cells #f "libera"))) "libera" "the name")
    (t--irc-fake! "libera")
    (check-equal! (car (car (irc-servers-cells #f "libera"))) "●" "ready after")
    (t--irc-clean! "libera")))

(deftest 'irc-replays-a-frame-on-the-clock-it-arrived-on
  "A redraw draws each frame with the time the server sent it, in the
buffer it belongs to, and your own line stays yours."
  (lambda ()
    (t--irc-fake! "t")
    (set! irc-show-time #t)
    (let ((hit (irc-replay-frame "t" (list "00:23:18" "in" ":oskarw!~u@h PRIVMSG #emacs :hello\r"))))
      (check-equal! (car hit) "#emacs" "the channel")
      (check-equal! (irc-row-text (cadr hit)) "00:23       oskarw  hello"
                    "the frame keeps the clock it arrived on"))
    (let ((mine (irc-replay-frame "t" (list "00:24:01" "out" "PRIVMSG #emacs :hi\r"))))
      (check-equal! (car mine) "#emacs" "a line you sent goes to its channel")
      (check-equal! (irc-row-text (cadr mine))
                    (string-append "00:24 " (string-pad-left "composguest" 12) "  hi")
                    "and comes back as yours")
      (check-equal! (irc-row-kind (cadr mine)) "said" "and it is a said line"))
    (check-false! (irc-replay-frame "t" (list "00:24:02" "in" "PING :x\r"))
                  "a keepalive draws nothing")
    (check-false! (irc-replay-frame "t" (list "00:24:03" "note" "connected"))
                  "the connection's own note draws nothing")
    (set! *irc-clock* #f)
    (set! irc-show-time #f)
    (t--irc-clean! "t")))

(deftest 'irc-mode-paints-a-restored-transcript
  "The mode setup paints the transcript again from the 'irc-paint local."
  (lambda ()
    (t--irc-fake! "t")
    (let ((buf (irc-buffer! "t" "#x")))
      (irc-display buf (irc-said "oskarw" "one"))
      (let ((before (buffer-overlays buf)))
        (overlay-clear! buf 'all)
        (check-false! (member (car before) (buffer-overlays buf)) "the paint is gone")
        (with-current-buffer buf (lambda () (set-mode! "irc-mode")))
        (check-true! (member (car before) (buffer-overlays buf)) "and the setup brings it back")))
    (t--irc-clean! "t")))
