;;; irc.scm
(package! 'irc)
(domain! 'network)
(effects! '(write external execute))
(define *irc-buffer* "*irc*")
(define *irc-endpoint* "irc")
(define *irc-channel* "#emacs")
(define *irc-follow* 0)
;; a replay draws the clock the frame arrived with, not the clock now
(define *irc-clock* #f)
(define *irc-names* 0)

(defcustom 'irc-host "irc.libera.chat" "The IRC server the client connects to." 'group 'network 'type 'string)
(defcustom 'irc-port "6667" "The IRC server port. The transport speaks plain IRC, not TLS." 'group 'network 'type 'string)
(defcustom 'irc-nick "composguest" "The nickname the client registers with." 'group 'network 'type 'string)
;;; A transcript shows the line kinds you name here and drops the rest as
;;; they arrive. Three carry what people say, and they are the default:
;;; "said", "action" and "note", which is the client speaking. Add "flow"
;;; for joins, parts and quits, "server" for server notices, "channel" for
;;; a channel list row.
(defcustom 'irc-line-types (list "said" "action" "note")
  "The line kinds the transcript shows. The rest are dropped as they arrive."
  'group 'network 'type 'list)

(defcustom 'irc-show-time #t "Show the clock column at the left of every line." 'group 'network 'type 'boolean)
(defcustom 'irc-nick-width 12 "Columns the nick column takes. A longer nick is clipped." 'group 'network 'type 'number)

;;; The look: a dim clock, a nick that keeps its colour, and plain text for
;;; what people said. Everything the client itself says stays quiet.
(defface! 'irc-time 'fg "#8a857a")
(defface! 'irc-marker 'fg "#b3ac9c")
(defface! 'irc-note 'fg "#8a857a" 'style "italic")
(defface! 'irc-action 'style "italic")
(defface! 'irc-self 'fg "#26356b" 'weight "700")
(defface! 'irc-mention 'fg "#a03020" 'weight "600")
;; underline only: a link takes the colour of the line it sits in, so a
;; span that carries two foregrounds never has to pick one
(defface! 'irc-url 'decoration "underline")
(defface! 'irc-header 'weight "700")
(defface! 'irc-channel 'fg "#26356b" 'weight "600")
(defface! 'irc-nick-1 'fg "#d05a47")
(defface! 'irc-nick-2 'fg "#3f7cac")
(defface! 'irc-nick-3 'fg "#4f8a5b")
(defface! 'irc-nick-4 'fg "#9b6ab3")
(defface! 'irc-nick-5 'fg "#c28a2c")
(defface! 'irc-nick-6 'fg "#347f7a")
(defface! 'irc-nick-7 'fg "#a8577a")
(defface! 'irc-nick-8 'fg "#7a7f2c")

(define (irc-chomp s)
  (let ((n (string-length s)))
    (if (and (> n 0) (member (substring s (- n 1) n) '("\n" "\r" " ")))
        (irc-chomp (substring s 0 (- n 1)))
        s)))

;;; Overlays are tagged and a tag is replaced whole, so the spans live in
;;; chunks: a new line repaints its own chunk and leaves the scrollback
;;; alone. The buffer moves the byte offsets on its own.
(define *irc-spans* '())
(define *irc-chunk* 0)
(define *irc-chunk-rows* 0)
(define *irc-chunk-size* 120)

(define (irc-tag)
  (string->symbol (string-append "irc-" (number->string *irc-chunk*))))

(define (irc-paint! base spans)
  (set! *irc-spans* (append *irc-spans* (irc-shift spans base)))
  (overlay-set! *irc-buffer* (irc-tag) *irc-spans*)
  (set! *irc-chunk-rows* (+ *irc-chunk-rows* 1))
  (when (>= *irc-chunk-rows* *irc-chunk-size*)
    (set! *irc-chunk* (+ *irc-chunk* 1))
    (set! *irc-chunk-rows* 0)
    (set! *irc-spans* '())))

(define (irc-display row)
  (when (irc-shows? (irc-row-kind row))
    (let ((follow? (= (buffer-point *irc-buffer*) *irc-follow*))
          (base (buffer-size *irc-buffer*)))
      (buffer-append! *irc-buffer* (string-append (irc-row-text row) "\n"))
      (irc-paint! base (irc-row-spans row))
      (when follow?
        (with-current-buffer *irc-buffer* (lambda () (end-of-buffer!)))
        (set! *irc-follow* (buffer-point *irc-buffer*))))))

(define (irc-nick-of prefix)
  (if (string? prefix) (car (string-split prefix "!")) "server"))

(define (irc-quiet? command)
  (member command '("002" "003" "004" "005" "250" "251" "252" "253" "254" "255"
                    "265" "266" "333" "372" "375" "376" "MODE" "PONG")))

;; A nick keeps one colour for the whole session: a small palette, a stable
;; hash, and your own nick always looks like yours.
(define (irc-clip s w)
  (if (> (string-length s) w) (substring s 0 w) s))

(define (irc-hash s)
  (let loop ((i 0) (h 7))
    (if (>= i (string-byte-length s))
        h
        (loop (+ i 1) (modulo (+ (* h 31) (string-byte s i)) 100003)))))

(define (irc-nick-face who)
  (if (equal? (string-downcase who) (string-downcase irc-nick))
      "irc-self"
      (string-append "irc-nick-"
                     (number->string (+ 1 (modulo (irc-hash (string-downcase who)) 8))))))

;;; A row is one line of text and the (START END FACE) spans that colour it,
;;; in bytes from the start of that line. Every rule below returns one, and
;;; nothing else formats the buffer. A tree-sitter query over a structured
;;; log line answers in the same shape.
;;; A row is one line of text, the (START END FACE) spans that colour it in
;;; bytes from the start of that line, and the kind of line it is. Every rule
;;; answers one, and nothing else formats the buffer. A tree-sitter query over
;;; a structured log line answers in the same shape.
(define (irc-row text spans kind) (list text spans kind))
(define (irc-row-text row) (car row))
(define (irc-row-spans row) (cadr row))
(define (irc-row-kind row) (caddr row))

(define (irc-shows? kind)
  (if (member kind irc-line-types) #t #f))
(define (irc-row-text row) (car row))
(define (irc-row-spans row) (cadr row))

(define (irc-shift spans n)
  (map (lambda (s) (list (+ n (car s)) (+ n (cadr s)) (caddr s))) spans))

(define (irc-stamp)
  (if irc-show-time
      (string-append (or *irc-clock* (format-time (current-time) "%H:%M")) " ")
      ""))

;; the clock, a right-aligned mark column, then the text: the layout every
;; IRC client has drawn since 1993, with the columns doing the alignment
(define (irc-line kind mark mark-face text spans)
  (let* ((stamp (irc-stamp))
         (m (irc-clip mark irc-nick-width))
         (col (string-pad-left m irc-nick-width))
         (head (string-append stamp col "  "))
         (sb (string-byte-length stamp))
         (mb (string-byte-length col))
         (cb (string-byte-length head)))
    (irc-row (string-append head text)
             (append
              (if (equal? stamp "") '() (list (list 0 (- sb 1) "irc-time")))
              (if (equal? m "")
                  '()
                  (list (list (+ sb (- mb (string-byte-length m))) (+ sb mb) mark-face)))
              (irc-shift spans cb))
             kind)))

(define (irc-urls text)
  (map (lambda (r) (list (car r) (cadr r) "irc-url"))
       (re-find* "(https?|irc)://[^ ]+" text)))

(define (irc-mention? text)
  (string-contains? (string-downcase text) (string-downcase irc-nick)))

(define (irc-body text face)
  (append (if face (list (list 0 (string-byte-length text) face)) '())
          (irc-urls text)))

(define (irc-plain t)
  (string-trim (apply string-append (string-split t "\x01;"))))

(define (irc-arg ps i)
  (if (> (length ps) i) (list-ref ps i) ""))

(define (irc-said who text)
  (irc-line "said" who (irc-nick-face who) text
            (irc-body text (and (irc-mention? text) "irc-mention"))))

(define (irc-note text)
  (irc-line "note" "-!-" "irc-marker" text (irc-body text "irc-note")))

;; an action is the nick inside the sentence, in italic, the way /me reads
;; an action is the nick inside the sentence, in italic, the way /me reads
(define (irc-action who text)
  (let ((body (string-append who " " text)))
    (irc-line "action" "*" "irc-marker" body
              (append (list (list 0 (string-byte-length body) "irc-action")
                            (list 0 (string-byte-length who) (irc-nick-face who)))
                      (irc-urls body)))))

;; joins, parts and quits: a dim line that still names the nick in colour
;; joins, parts and quits: a dim line that still names the nick in colour
(define (irc-flow mark who text)
  (let ((body (string-append who " " text)))
    (irc-line "flow" mark "irc-marker" body
              (list (list 0 (string-byte-length who) (irc-nick-face who))
                    (list (string-byte-length who) (string-byte-length body) "irc-note")))))

;; a server speaks between dashes, and only its first label fits the column
;; a server speaks between dashes, and only its first label fits the column
(define (irc-server who text)
  (irc-line "server" (string-append "-" (car (string-split who ".")) "-") "irc-marker"
            text (irc-body text "irc-note")))

(define (irc-channel-row name users topic)
  (let* ((col (string-pad-right name 24))
         (cnt (string-pad-left users 6))
         (head (string-append "  " col cnt "  "))
         (a (string-byte-length col))
         (b (string-byte-length cnt)))
    (irc-row (string-append head topic)
             (list (list 2 (+ 2 (string-byte-length name)) "irc-channel")
                   (list (+ 2 a) (+ 2 a b) "irc-marker"))
             "channel")))

(define (irc-banner text)
  (irc-row text (list (list 0 (string-byte-length text) "irc-header")) "note"))

(define (irc-message m)
  (let* ((c (plist-get m 'command))
         (n (irc-nick-of (plist-get m 'prefix)))
         (t (irc-plain (or (plist-get m 'trailing) "")))
         (ps (or (plist-get m 'params) '())))
    (cond ((irc-quiet? c) #f)
          ((equal? c "PRIVMSG")
           (if (string-prefix? "ACTION " t)
               (irc-action n (substring t 7 (string-length t)))
               (irc-said n t)))
          ((equal? c "NOTICE") (irc-server n t))
          ((equal? c "JOIN") (irc-flow "-->" n "joined"))
          ((equal? c "PART") (irc-flow "<--" n "left"))
          ((equal? c "QUIT") (irc-flow "<--" n "quit"))
          ((equal? c "NICK") (irc-flow "-!-" n (string-append "is now " t)))
          ((equal? c "KICK") (irc-flow "-!-" (irc-arg ps 1) (string-append "was kicked by " n)))
          ((or (equal? c "TOPIC") (equal? c "332")) (irc-note (string-append "topic: " t)))
          ((equal? c "353")
           (set! *irc-names* (+ *irc-names* (length (string-split t " "))))
           #f)
          ((equal? c "366")
           (let ((k *irc-names*))
             (set! *irc-names* 0)
             (irc-note (string-append (number->string k) " users in " (irc-arg ps 1)))))
          ((equal? c "001") (irc-note (string-append "connected to " irc-host " as " irc-nick)))
          ((equal? c "321") (irc-note "channel list"))
          ((equal? c "323") (irc-note "end of channel list"))
          ((equal? c "322") (irc-channel-row (irc-arg ps 1) (irc-arg ps 2) t))
          (else (irc-note (if (equal? t "") c t))))))

(define (irc-event name kind text)
  (when (equal? name *irc-endpoint*)
    (if (equal? kind "frame")
        (let ((m (irc-parse text)))
          (if (equal? (plist-get m 'command) "PING")
              (endpoint-send! name (irc-format "PONG" '() (or (plist-get m 'trailing) "")))
              (let ((row (irc-message m)))
                (when row (irc-display row)))))
        (irc-display (irc-note (irc-chomp text))))))

(on-endpoint-event! *irc-endpoint* irc-event)

(define (irc-reset!)
  (unless (buffer-known? *irc-buffer*) (buffer-create *irc-buffer*))
  (let ((n (buffer-size *irc-buffer*)))
    (when (> n 0) (buffer-delete-range! *irc-buffer* 0 n)))
  (overlay-clear! *irc-buffer* 'all)
  (set! *irc-spans* '())
  (set! *irc-chunk* 0)
  (set! *irc-chunk-rows* 0)
  (set! *irc-follow* 0)
  (set! *irc-names* 0)
  (irc-display (irc-banner (string-append "IRC  " irc-host ":" irc-port "  " *irc-channel*)))
  (irc-display (irc-row "" '() "note")))

;;; The transcript is drawn, and the frames are what the server said, so the
;;; whole buffer can be drawn again from them: a settings change, a new rule,
;;; or a kind you just turned on reaches the scrollback and not only the next
;;; line. The connection keeps the last frames it received, so a redraw
;;; reaches back exactly that far and says how far that was.
(define (irc-replay-frame e)
  (let ((at (car e)) (dir (cadr e)) (text (caddr e)))
    (set! *irc-clock* (substring at 0 5))
    (let* ((m (irc-parse text))
           (c (plist-get m 'command)))
      (cond ((equal? c "PING") #f)
            ((equal? dir "out")
             (and (equal? c "PRIVMSG")
                  (irc-said irc-nick (irc-plain (or (plist-get m 'trailing) "")))))
            (else (irc-message m))))))

(define (irc-redraw!)
  (let ((frames (endpoint-log *irc-endpoint*)))
    (irc-reset!)
    (for-each (lambda (e)
                (let ((row (irc-replay-frame e)))
                  (when row (irc-display row))))
              frames)
    (set! *irc-clock* #f)
    (length frames)))

(define-command "irc-connect" "Connect to Libera.Chat anonymously"
  (lambda ()
    (irc-reset!)
    (endpoint-stop! *irc-endpoint*)
    (endpoint-register! *irc-endpoint* (list 'host irc-host 'port irc-port 'framing "line"))
    (endpoint-ensure! *irc-endpoint*)
    (endpoint-send! *irc-endpoint* (irc-format "NICK" (list irc-nick)))
    (endpoint-send! *irc-endpoint* (irc-format "USER" (list irc-nick "0" "*") irc-nick))
    (message (string-append "IRC connecting to " irc-host))))

(define-command "irc-join" "Join an IRC channel"
  (lambda ()
    (minibuffer-read "Join channel: " #f
      (lambda (channel)
        (set! *irc-channel* (string-trim channel))
        (endpoint-send! *irc-endpoint* (irc-format "JOIN" (list *irc-channel*)))
        (irc-display (irc-note (string-append "joining " *irc-channel*)))))))

(define-command "irc-send" "Send a message, or a /raw command, to the current IRC channel"
  (lambda ()
    (minibuffer-read (string-append *irc-channel* " ") #f
      (lambda (text)
        (let ((line (string-trim text)))
          (unless (equal? line "")
            (if (string-prefix? "/" line)
                (let ((raw (substring line 1 (string-length line))))
                  (endpoint-send! *irc-endpoint* (string-append raw "\r\n"))
                  (irc-display (irc-note raw)))
                (begin
                  (endpoint-send! *irc-endpoint* (irc-format "PRIVMSG" (list *irc-channel*) line))
                  (irc-display (irc-said irc-nick line))))))))))

(define-command "irc-redraw" "Draw the whole transcript again from the frames the server sent"
  (lambda ()
    (let ((n (irc-redraw!)))
      (message (string-append "IRC redrew the last " (number->string n) " frames")))))

(define-command "irc" "Open the IRC client buffer"
  (lambda ()
    (unless (buffer-known? *irc-buffer*) (buffer-create *irc-buffer*))
    (switch-to-buffer! *irc-buffer*)
    (set-mode! "irc-mode")))

(define-mode "irc-mode"
  (lambda ()
    ;; the buffer is a transcript, so it is read-only; you type in the
    ;; minibuffer, the way every client has always asked you to
    (buffer-set-read-only! (current-buffer) #t)
    (local-set-key "C-c C-c" "irc-connect")
    (local-set-key "C-c C-j" "irc-join")
    (local-set-key "g" "irc-redraw")
    (local-set-key "RET" "irc-send")))

(public! 'irc "M-x irc — open the IRC client buffer")
(public! 'irc-connect "M-x irc-connect — connect to Libera.Chat anonymously")
(public! 'irc-redraw "M-x irc-redraw — draw the transcript again from the frames the server sent")
