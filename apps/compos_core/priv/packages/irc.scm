;;; irc.scm --- an IRC client, the way rcirc works in Emacs.
;;;
;;; `M-x irc` lists the servers you keep. RET on a row connects, and opens
;;; the server buffer. A server has one buffer, and every channel and every
;;; private conversation has one buffer of its own. Each buffer is a
;;; transcript with a prompt at its foot: type a line, press RET, and the
;;; line goes to the channel. A line that starts with "/" is a command for
;;; the client: /join, /part, /msg, /me, /nick, /list, /quit, and the rest
;;; (/help lists them). A word the client does not know goes to the server
;;; as a raw command, so /whois works without a rule here.
;;;
;;; The transcript is quiet by default. It shows what people say, and what
;;; the client says. Joins, parts, modes, and server notices arrive and are
;;; dropped. /verbose shows them, and redraws the scrollback from the frames
;;; the connection kept.
;;;
;;; Elixir parses and formats one line (Compos.Core.IRC); the endpoint
;;; package owns the socket. Everything else is here.
(package! 'irc)
(domain! 'network)
(effects! '(write external execute))

;;; --- settings ---------------------------------------------------------------

(defcustom 'irc-servers
  (list (list 'name "libera" 'host "irc.libera.chat" 'port "6667")
        (list 'name "oftc" 'host "irc.oftc.net" 'port "6667"))
  "The servers *irc-servers* lists. Each entry is a plist: 'name, 'host, 'port, an optional 'nick, and optional 'channels to join on connect."
  'group 'network 'type 'list)
(defcustom 'irc-nick "composguest" "The nickname for a server whose entry names none." 'group 'network 'type 'string)

;;; A transcript shows the line kinds you name here and drops the rest as
;;; they arrive. Three carry what people say, and they are the default:
;;; "said", "action" and "note", which is the client speaking. Add "flow"
;;; for joins, parts and quits, "server" for server notices and numerics.
(defcustom 'irc-line-types (list "said" "action" "note")
  "The line kinds the transcript shows. The rest are dropped as they arrive."
  'group 'network 'type 'list)
(defcustom 'irc-verbose #f
  "Show every line the server sends, not only the kinds irc-line-types names."
  'group 'network 'type 'boolean)
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
(defface! 'irc-up 'fg "#4f8a5b" 'weight "700")
(defface! 'irc-nick-1 'fg "#d05a47")
(defface! 'irc-nick-2 'fg "#3f7cac")
(defface! 'irc-nick-3 'fg "#4f8a5b")
(defface! 'irc-nick-4 'fg "#9b6ab3")
(defface! 'irc-nick-5 'fg "#c28a2c")
(defface! 'irc-nick-6 'fg "#347f7a")
(defface! 'irc-nick-7 'fg "#a8577a")
(defface! 'irc-nick-8 'fg "#7a7f2c")

;;; --- small helpers ----------------------------------------------------------

(define (irc-find pred lst)
  (cond ((null? lst) #f)
        ((pred (car lst)) (car lst))
        (else (irc-find pred (cdr lst)))))

(define (irc-chomp s)
  (let ((n (string-length s)))
    (if (and (> n 0) (member (substring s (- n 1) n) '("\n" "\r" " ")))
        (irc-chomp (substring s 0 (- n 1)))
        s)))

(define (irc-clip s w)
  (if (> (string-length s) w) (substring s 0 w) s))

(define (irc-arg ps i)
  (if (> (length ps) i) (list-ref ps i) ""))

(define (irc-tail ps) (if (pair? ps) (cdr ps) '()))

(define (irc-words s)
  (filter (lambda (w) (not (equal? w ""))) (string-split s " ")))

;; "/join #emacs key" -> ("join" "#emacs key")
(define (irc-split-command line)
  (let* ((ws (irc-words line))
         (word (if (pair? ws) (car ws) ""))
         (rest (if (pair? ws)
                   (string-trim (substring line (+ (string-index line word) (string-length word))
                                           (string-length line)))
                   "")))
    (list (string-downcase word) rest)))

(define (irc-channel? s)
  (and (string? s) (> (string-length s) 0)
       (member (substring s 0 1) '("#" "&" "+" "!"))
       #t))

(define (irc-nick-of prefix)
  (if (string? prefix) (car (string-split prefix "!")) "server"))

;; a person has a user@host; a server has only its name
(define (irc-person? prefix)
  (and (string? prefix) (string-contains? prefix "!")))

;;; --- connections ------------------------------------------------------------
;;; One record per server you connected to this session: the endpoint name,
;;; the host and port, the nick the server knows you by, and the status the
;;; endpoint last reported. The record is the truth about "connected": the
;;; status event writes it, and nobody asks the endpoint twice.

(define *irc-conns* '())

;; an endpoint name is [a-z0-9-]; a server name is what you typed
(define (irc-endpoint name)
  (string-append "irc-" (re-replace-all "[^a-z0-9]" (string-downcase name) "-")))

(define (irc-conn name)
  (let ((e (assoc name *irc-conns*)))
    (and e (cadr e))))

(define (irc-conn-set! name conn)
  (set! *irc-conns*
    (cons (list name conn)
          (remove (lambda (e) (equal? (car e) name)) *irc-conns*)))
  conn)

(define (irc-plist-put pl key value)
  (let loop ((rest pl) (out '()))
    (cond ((null? rest) (append (reverse out) (list key value)))
          ((equal? (car rest) key) (append (reverse out) (list key value) (cddr rest)))
          (else (loop (cddr rest) (cons (cadr rest) (cons (car rest) out)))))))

(define (irc-conn-put! name key value)
  (let ((c (or (irc-conn name) '())))
    (irc-conn-set! name (irc-plist-put c key value))))

(define (irc-conn-get name key)
  (let ((c (irc-conn name)))
    (and c (plist-get c key))))

(define (irc-server-entry name)
  (irc-find (lambda (s) (equal? (plist-get s 'name) name)) irc-servers))

(define (irc-entry-nick s)
  (or (plist-get s 'nick) irc-nick))

(define (irc-status name)
  (or (irc-conn-get name 'status) "off"))

(define (irc-connected? name)
  (equal? (irc-status name) "ready"))

;; the nick the server NAME knows you by; the default when you never connected
(define (irc-self-nick name)
  (or (and name (irc-conn-get name 'nick))
      (let ((s (and name (irc-server-entry name))))
        (if s (irc-entry-nick s) irc-nick))))

(define (irc-server-of-endpoint ep)
  (let ((e (irc-find (lambda (e) (equal? (plist-get (cadr e) 'endpoint) ep)) *irc-conns*)))
    (and e (car e))))

;; the seam the tests replace: every byte to a server leaves through here
(define *irc-send* (lambda (ep text) (endpoint-send! ep text)))

(define (irc-send! name text)
  (let ((ep (irc-conn-get name 'endpoint)))
    (if (and ep (irc-connected? name))
        (begin (*irc-send* ep text) #t)
        #f)))

;;; --- faces for a nick -------------------------------------------------------
;;; A nick keeps one colour for the whole session: a small palette, a stable
;;; hash, and your own nick always looks like yours. *irc-cur* names the
;;; server whose lines are being drawn, so "yours" is the nick that server
;;; knows.

(define *irc-cur* #f)

(define (irc-hash s)
  (let loop ((i 0) (h 7))
    (if (>= i (string-byte-length s))
        h
        (loop (+ i 1) (modulo (+ (* h 31) (string-byte s i)) 100003)))))

(define (irc-nick-face who)
  (if (equal? (string-downcase who) (string-downcase (irc-self-nick *irc-cur*)))
      "irc-self"
      (string-append "irc-nick-"
                     (number->string (+ 1 (modulo (irc-hash (string-downcase who)) 8))))))

;;; --- rows -------------------------------------------------------------------
;;; A row is one line of text, the (START END FACE) spans that colour it in
;;; bytes from the start of that line, and the kind of line it is. Every rule
;;; answers one, and nothing else formats the buffer.

(define (irc-row text spans kind) (list text spans kind))
(define (irc-row-text row) (car row))
(define (irc-row-spans row) (cadr row))
(define (irc-row-kind row) (caddr row))

(define (irc-shows? kind)
  (if (or irc-verbose (member kind irc-line-types)) #t #f))

(define (irc-shift spans n)
  (map (lambda (s) (list (+ n (car s)) (+ n (cadr s)) (caddr s))) spans))

;; a replay draws the clock the frame arrived with, not the clock now
(define *irc-clock* #f)

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
  (string-contains? (string-downcase text) (string-downcase (irc-self-nick *irc-cur*))))

(define (irc-body text face)
  (append (if face (list (list 0 (string-byte-length text) face)) '())
          (irc-urls text)))

(define (irc-plain t)
  (string-trim (apply string-append (string-split t "\x01;"))))

(define (irc-said who text)
  (irc-line "said" who (irc-nick-face who) text
            (irc-body text (and (irc-mention? text) "irc-mention"))))

(define (irc-note text)
  (irc-line "note" "-!-" "irc-marker" text (irc-body text "irc-note")))

;; an action is the nick inside the sentence, in italic, the way /me reads
(define (irc-action who text)
  (let ((body (string-append who " " text)))
    (irc-line "action" "*" "irc-marker" body
              (append (list (list 0 (string-byte-length body) "irc-action")
                            (list 0 (string-byte-length who) (irc-nick-face who)))
                      (irc-urls body)))))

;; joins, parts and quits: a dim line that still names the nick in colour
(define (irc-flow mark who text)
  (let ((body (string-append who " " text)))
    (irc-line "flow" mark "irc-marker" body
              (list (list 0 (string-byte-length who) (irc-nick-face who))
                    (list (string-byte-length who) (string-byte-length body) "irc-note")))))

;; a server speaks between dashes, and only its first label fits the column
(define (irc-server who text)
  (irc-line "server" (string-append "-" (car (string-split who ".")) "-") "irc-marker"
            text (irc-body text "irc-note")))

(define (irc-banner text)
  (irc-row text (list (list 0 (string-byte-length text) "irc-header")) "note"))

;;; --- what a frame means -----------------------------------------------------
;;; irc-route names the buffer a frame belongs in: a channel, a person, or
;;; #f for the server buffer. irc-message turns the frame into a row.

(define (irc-route m)
  (let* ((c (plist-get m 'command))
         (ps (or (plist-get m 'params) '()))
         (t (or (plist-get m 'trailing) ""))
         (first (if (equal? (irc-arg ps 0) "") t (irc-arg ps 0))))
    (cond ((member c '("PRIVMSG" "NOTICE"))
           (cond ((irc-channel? first) first)
                 ((irc-person? (plist-get m 'prefix)) (irc-nick-of (plist-get m 'prefix)))
                 (else #f)))
          ((member c '("JOIN" "PART" "KICK" "MODE" "TOPIC"))
           (and (irc-channel? first) first))
          ((member c '("332" "333" "366" "324" "329" "482"))
           (and (irc-channel? (irc-arg ps 1)) (irc-arg ps 1)))
          ((equal? c "353")
           (and (irc-channel? (irc-arg ps 2)) (irc-arg ps 2)))
          ;; an error about a channel: "479 me #chan :Illegal channel name"
          ((re-match? "^[45][0-9][0-9]$" c)
           (and (irc-channel? (irc-arg ps 1)) (irc-arg ps 1)))
          (else #f))))

(define *irc-names* 0)

(define (irc-message m)
  (let* ((c (plist-get m 'command))
         (n (irc-nick-of (plist-get m 'prefix)))
         (t (irc-plain (or (plist-get m 'trailing) "")))
         (ps (or (plist-get m 'params) '())))
    (cond ((member c '("PING" "PONG")) #f)
          ((equal? c "PRIVMSG")
           (if (string-prefix? "ACTION " t)
               (irc-action n (substring t 7 (string-length t)))
               (irc-said n t)))
          ((equal? c "NOTICE") (irc-server n t))
          ((equal? c "JOIN") (irc-flow "-->" n "joined"))
          ((equal? c "PART") (irc-flow "<--" n (if (equal? t "") "left" (string-append "left: " t))))
          ((equal? c "QUIT") (irc-flow "<--" n (if (equal? t "") "quit" (string-append "quit: " t))))
          ((equal? c "NICK") (irc-flow "-!-" n (string-append "is now " (if (equal? t "") (irc-arg ps 0) t))))
          ((equal? c "MODE")
           (irc-flow "-!-" n (string-append "sets mode "
                                            (if (equal? t "") (string-join (irc-tail ps) " ") t))))
          ((equal? c "KICK") (irc-flow "-!-" (irc-arg ps 1) (string-append "was kicked by " n)))
          ((or (equal? c "TOPIC") (equal? c "332")) (irc-note (string-append "topic: " t)))
          ((equal? c "353")
           (set! *irc-names* (+ *irc-names* (length (irc-words t))))
           #f)
          ((equal? c "366")
           (let ((k *irc-names*))
             (set! *irc-names* 0)
             (irc-note (string-append (number->string k) " users in " (irc-arg ps 1)))))
          ((equal? c "001") (irc-note (string-append "connected as " (irc-arg ps 0))))
          ((equal? c "433") (irc-note (string-append "nick " (irc-arg ps 1) " is in use")))
          ((equal? c "ERROR") (irc-note (string-append "error: " t)))
          ((re-match? "^[45][0-9][0-9]$" c)
           (irc-note (string-append (string-join (irc-tail ps) " ") (if (equal? t "") "" (string-append " " t)))))
;; a numeric names you first; the rest of its params and its text are the line
          (else (irc-server n (irc-numeric-text ps t))))))

(define (irc-numeric-text ps t)
  (let ((rest (string-join (irc-tail ps) " ")))
    (cond ((equal? rest "") t)
          ((equal? t "") rest)
          (else (string-append rest " " t)))))

;;; --- buffers ----------------------------------------------------------------
;;; Layout: [transcript ... mark][live input]. 'irc-mark is a stay marker:
;;; the transcript appends AT it and advances it; a keystroke there lands
;;; after it, in the input. 'irc-server and 'irc-target say whose buffer
;;; this is. 'irc-paint keeps the painted spans, chunk by chunk, so the
;;; mode setup can paint a restored transcript again.

(define (irc-server-buffer name) (string-append "*irc:" name "*"))
(define (irc-target-buffer name target) (string-append "*irc:" name "/" target "*"))
(define (irc-buffer-name name target)
  (if target (irc-target-buffer name target) (irc-server-buffer name)))

(define (irc-buf-server buf) (buffer-local buf 'irc-server))
(define (irc-buf-target buf) (buffer-local buf 'irc-target))

(define (irc-buffer? buf) (if (irc-buf-server buf) #t #f))

;; the buffer for a server and a target, made and put in irc-mode once
(define (irc-buffer! name target)
  (let ((buf (irc-buffer-name name target)))
    (unless (buffer-known? buf)
      (buffer-create buf)
      (buffer-set-local! buf 'irc-server name)
      (buffer-set-local! buf 'irc-target target)
      (buffer-set-local! buf 'irc-mark 0)
      (buffer-set-local! buf 'irc-paint '())
      (with-current-buffer buf (lambda () (set-mode! "irc-mode")))
      (irc-display buf (irc-banner (if target
                                      (string-append target " on " name)
                                      (string-append name)))))
    buf))

;; every buffer that belongs to server NAME
(define (irc-buffers name)
  (filter (lambda (b) (equal? (irc-buf-server b) name)) (buffer-list)))

(define (irc-mark buf)
  (min (or (buffer-local buf 'irc-mark) 0) (buffer-size buf)))

(define (irc-input-text buf)
  (substring-bytes (buffer-text buf) (irc-mark buf) (buffer-size buf)))

(define (irc-clear-input! buf)
  (let ((m (irc-mark buf)))
    (buffer-delete-range! buf m (- (buffer-size buf) m))))

;;; Overlays are tagged and a tag is replaced whole, so the spans live in
;;; chunks: a new line repaints its own chunk and leaves the scrollback
;;; alone. The buffer moves the byte offsets on its own.
(define *irc-chunk-size* 120)

(define (irc-tag n)
  (string->symbol (string-append "irc-" (number->string n))))

;; 'irc-paint is ((CHUNK ROWS SPANS) ...), the current chunk first
(define (irc-paint! buf base spans)
  (let* ((paint (or (buffer-local buf 'irc-paint) '()))
         (head (if (pair? paint) (car paint) (list 0 0 '())))
         (rest (if (pair? paint) (cdr paint) '()))
         (n (car head))
         (rows (+ 1 (cadr head)))
         (sp (append (caddr head) (irc-shift spans base)))
         (full (list n rows sp)))
    (overlay-set! buf (irc-tag n) sp)
    (buffer-set-local! buf 'irc-paint
      (if (>= rows *irc-chunk-size*)
          (cons (list (+ n 1) 0 '()) (cons full rest))
          (cons full rest)))))

(define (irc-repaint! buf)
  (for-each (lambda (c) (overlay-set! buf (irc-tag (car c)) (caddr c)))
            (or (buffer-local buf 'irc-paint) '())))

;; append one row to the transcript of BUF, when its kind shows
(define (irc-display buf row)
  (when (and row (irc-shows? (irc-row-kind row)))
    (let ((base (irc-mark buf)))
      (buffer-insert-at-local! buf 'irc-mark (string-append (irc-row-text row) "\n"))
      (irc-paint! buf base (irc-row-spans row)))))

(define (irc-note! buf text)
  (irc-display buf (irc-note text)))

;; the transcript goes; the typed input stays
(define (irc-reset! buf)
  (let ((m (irc-mark buf)))
    (when (> m 0) (buffer-delete-range! buf 0 m))
    (buffer-set-local! buf 'irc-mark 0)
    (overlay-clear! buf 'all)
    (buffer-set-local! buf 'irc-paint '())))

(define (irc-modeline! buf)
  (let ((name (irc-buf-server buf))
        (target (irc-buf-target buf)))
    (buffer-set-local! buf 'modeline-info
      (string-append (or name "irc")
                     (if target (string-append " " target) "")
                     " · " (irc-self-nick name)
                     (if (irc-connected? name) "" " · off")))))

(define-mode "irc-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-marker-local! buf 'irc-mark 'stay)
      (unless (buffer-local buf 'irc-mark)
        (buffer-set-local! buf 'irc-mark (buffer-size buf)))
      (buffer-set-read-only! buf #f)
      ;; a restored transcript gets its colours back from the locals
      (irc-repaint! buf)
      (irc-modeline! buf))))

(mode-keys! "irc-mode"
  '(("RET" "irc-send")
    ("S-RET" "newline")))

;;; --- frames in --------------------------------------------------------------

(define (irc-nick-taken! name m)
  (let ((next (string-append (irc-arg (plist-get m 'params) 1) "_")))
    (irc-conn-put! name 'nick next)
    (irc-send! name (irc-format "NICK" (list next)))
    (irc-note! (irc-buffer! name #f) (string-append "trying " next))))

;; the frames a command changes state with, before they draw
(define (irc-effects! name m)
  (let ((c (plist-get m 'command))
        (n (irc-nick-of (plist-get m 'prefix)))
        (ps (or (plist-get m 'params) '()))
        (t (or (plist-get m 'trailing) "")))
    (cond ((equal? c "001")
           (irc-conn-put! name 'nick (irc-arg ps 0))
           (irc-conn-put! name 'registered #t)
           (for-each irc-modeline! (irc-buffers name))
           (irc-flush-joins! name))
          ((equal? c "433") (irc-nick-taken! name m))
          ((and (equal? c "NICK")
                (equal? (string-downcase n) (string-downcase (irc-self-nick name))))
           (irc-conn-put! name 'nick (if (equal? t "") (irc-arg ps 0) t))
           (for-each irc-modeline! (irc-buffers name)))
          (else #f))))

(define (irc-handle-frame! name m)
  (set! *irc-cur* name)
  (cond ((equal? (plist-get m 'command) "PING")
         (irc-send! name (irc-format "PONG" '() (or (plist-get m 'trailing) ""))))
        ((irc-list-frame? m) (irc-list-collect! name m))
        (else
         (irc-effects! name m)
         (irc-display (irc-buffer! name (irc-route m)) (irc-message m)))))

(define (irc-handle-status! name text)
  (irc-conn-put! name 'status text)
  (for-each irc-modeline! (irc-buffers name))
  (irc-note! (irc-buffer! name #f)
             (cond ((equal? text "ready")
                    (string-append "connected to " (irc-conn-get name 'host)))
                   (else text))))

(define (irc-event ep kind text)
  (let ((name (irc-server-of-endpoint ep)))
    (when name
      (cond ((equal? kind "frame") (irc-handle-frame! name (irc-parse text)))
            ((equal? kind "status") (irc-handle-status! name text))
            (else (irc-note! (irc-buffer! name #f) (irc-chomp text)))))))

(on-endpoint-event! "irc" irc-event)

;;; --- redraw -----------------------------------------------------------------
;;; The transcript is drawn, and the frames are what the server said, so the
;;; whole buffer can be drawn again from them: a settings change, a new rule,
;;; or a kind you just turned on reaches the scrollback and not only the next
;;; line. The connection keeps the last frames it received, so a redraw
;;; reaches back exactly that far and says how far that was.

;; the buffer and the row one logged frame draws, or #f
(define (irc-replay-frame name e)
  (let ((at (car e)) (dir (cadr e)) (text (caddr e)))
    (set! *irc-clock* (substring at 0 5))
    (set! *irc-cur* name)
    (let* ((m (irc-parse text))
           (c (plist-get m 'command))
           (ps (or (plist-get m 'params) '()))
           (t (irc-plain (or (plist-get m 'trailing) ""))))
      ;; the log also keeps the connection's own notes; they are not frames
      (cond ((not (member dir '("in" "out"))) #f)
            ((member c '("PING" "PONG")) #f)
            ((irc-list-frame? m) #f)
            ((equal? dir "out")
             (and (equal? c "PRIVMSG")
                  (list (irc-arg ps 0)
                        (if (string-prefix? "ACTION " t)
                            (irc-action (irc-self-nick name) (substring t 7 (string-length t)))
                            (irc-said (irc-self-nick name) t)))))
            (else (list (irc-route m) (irc-message m)))))))

(define (irc-redraw! name)
  (let ((frames (endpoint-log (or (irc-conn-get name 'endpoint) (irc-endpoint name)))))
    (for-each (lambda (b)
                (irc-reset! b)
                (irc-display b (irc-banner (let ((t (irc-buf-target b)))
                                             (if t (string-append t " on " name) name)))))
              (irc-buffers name))
    (for-each (lambda (e)
                (let ((hit (irc-replay-frame name e)))
                  (when hit (irc-display (irc-buffer! name (car hit)) (cadr hit)))))
              frames)
    (set! *irc-clock* #f)
    (length frames)))

;;; --- connect ----------------------------------------------------------------

(define (irc-connect! name)
  (let ((s (irc-server-entry name)))
    (unless s (error (string-append "irc: no server named " name)))
    (let* ((ep (irc-endpoint name))
           (host (plist-get s 'host))
           (port (or (plist-get s 'port) "6667"))
           (nick (irc-entry-nick s))
           (buf (irc-buffer! name #f)))
      (irc-conn-set! name (list 'endpoint ep 'host host 'port port 'nick nick
                                'status "connecting" 'registered #f 'pending '()))
      (endpoint-stop! ep)
      (endpoint-register! ep (list 'host host 'port port 'framing "line"))
      (endpoint-ensure! ep)
      (*irc-send* ep (irc-format "NICK" (list nick)))
      (*irc-send* ep (irc-format "USER" (list nick "0" "*") nick))
      (irc-note! buf (string-append "connecting to " host ":" port " as " nick))
      (for-each irc-modeline! (irc-buffers name))
      buf)))

(define (irc-disconnect! name reason)
  (irc-send! name (irc-format "QUIT" '() (or reason "bye")))
  (let ((ep (irc-conn-get name 'endpoint)))
    (when ep (endpoint-stop! ep)))
  (irc-conn-put! name 'status "off")
  (for-each irc-modeline! (irc-buffers name)))

;;; --- the channel list -------------------------------------------------------
;;; /list asks the server, the 322 rows collect until 323, and then a list
;;; buffer shows them: RET on a row joins it.

(define *irc-lists* '())

(define (irc-list-frame? m)
  (member (plist-get m 'command) '("321" "322" "323")))

(define (irc-channels-buffer name) (string-append "*irc:" name " channels*"))

(define (irc-list-collect! name m)
  (let ((c (plist-get m 'command))
        (ps (or (plist-get m 'params) '()))
        (t (or (plist-get m 'trailing) "")))
    (cond ((equal? c "321")
           (set! *irc-lists* (cons (list name '()) (remove (lambda (e) (equal? (car e) name)) *irc-lists*))))
          ((equal? c "322")
           (let ((rows (or (let ((e (assoc name *irc-lists*))) (and e (cadr e))) '())))
             (set! *irc-lists*
               (cons (list name (cons (list (irc-arg ps 1) (irc-arg ps 2) (irc-plain t)) rows))
                     (remove (lambda (e) (equal? (car e) name)) *irc-lists*)))))
          ((equal? c "323")
           (let ((rows (or (let ((e (assoc name *irc-lists*))) (and e (cadr e))) '())))
             (set! *irc-lists* (remove (lambda (e) (equal? (car e) name)) *irc-lists*))
             (irc-channels-show! name (irc-sort-channels rows)))))))

(define (irc-users n)
  (let ((k (string->number n)))
    (if (number? k) k 0)))

;; sort takes no comparator: the key leads, and a negative count puts the
;; busiest channel first
(define (irc-sort-channels rows)
  (map cdr (sort (map (lambda (r) (cons (- 0 (irc-users (cadr r))) r)) rows))))

(define (irc-channels-show! name rows)
  (let ((buf (irc-channels-buffer name)))
    (buffer-create buf)
    (buffer-set-local! buf 'irc-server name)
    (buffer-set-local! buf 'irc-channel-rows rows)
    (with-current-buffer buf (lambda () (set-mode! "irc-channels-mode")))
    (list-refresh! buf)
    (pop-to-buffer buf)
    buf))

(define-list-mode! "irc-channels-mode"
  (list
    'doc "The channels a server listed for /list, most users first. RET joins the row's channel. `/` filters."
    'rows (lambda (buf) (or (buffer-local buf 'irc-channel-rows) '()))
    'columns (lambda (buf) (list (list "channel" 24) (list "users" 6) (list "topic" #f)))
    'cells (lambda (buf e)
             (list (list (car e) "irc-channel")
                   (list (cadr e) "irc-marker")
                   (list (caddr e) "irc-note")))
    'title (lambda (buf) (string-append "Channels on " (or (irc-buf-server buf) "irc")))
    'meta (lambda (buf) (string-append (number->string (length (list-entries buf))) " channels"))
    'total (lambda (buf) (length (list-source-entries buf)))
    'no-marks #t
    'local-filter #t
    'key (lambda (buf e) (car e))
    'footer (lambda (buf) '(("RET" "join") ("/" "filter") ("g" "refresh") ("q" "quit")))
    'keys '(("RET" "irc-channels-join") ("g" "irc-channels-refresh") ("q" "quit-window"))))

(define-command "irc-channels-join" "Join the channel on this row"
  (lambda ()
    (let* ((buf (current-buffer))
           (e (list-current buf))
           (name (irc-buf-server buf)))
      (if (and e name)
          (irc-join! name (car e) "")
          (message "no channel on this line")))))

;; `g` asks the server again, with the pattern the /list that made this
;; buffer used; the rows land when 323 closes the reply
(define-command "irc-channels-refresh" "Ask the server for this channel list again"
  (lambda ()
    (let* ((buf (current-buffer))
           (name (irc-buf-server buf)))
      (if (and name (irc-connected? name))
          (let ((pat (or (irc-conn-get name 'list-pattern) "")))
            (message (string-append "asking " name " for the channel list"))
            (irc-send! name (string-append "LIST" (if (equal? pat "") "" (string-append " " pat)))))
          (message "not connected: /connect")))))

;;; --- the servers list -------------------------------------------------------

(define *irc-servers-buffer* "*irc-servers*")

(define (irc-status-glyph status)
  (cond ((equal? status "ready") "●")
        ((member status '("connecting" "busy")) "◐")
        ((equal? status "error") "✖")
        (else "○")))

(define (irc-joined name)
  (filter (lambda (t) t) (map irc-buf-target (irc-buffers name))))

(define (irc-servers-cells buf name)
  (let* ((s (or (irc-server-entry name) '()))
         (status (irc-status name))
         (face (if (equal? status "ready") "irc-up" "irc-note")))
    (list (list (irc-status-glyph status) face)
          (list name "irc-channel")
          (list (string-append (or (plist-get s 'host) "?") ":" (or (plist-get s 'port) "6667")) "irc-note")
          (list (irc-self-nick name) (if (equal? status "ready") "irc-self" "irc-note"))
          (list (string-join (irc-joined name) " ") "irc-note"))))

(define-list-mode! "irc-servers-mode"
  (list
    'doc (string-append
           "The IRC servers you keep. RET connects and opens the server buffer; "
           "on a connected row it opens the buffer. `a` adds a server, `d` removes "
           "the row, `k` disconnects it, `g` redraws.")
    'buffer *irc-servers-buffer*
    'rows (lambda (buf) (map (lambda (s) (plist-get s 'name)) irc-servers))
    'columns (lambda (buf)
               (list (list "" 1) (list "server" 12) (list "host" 26)
                     (list "nick" 14) (list "channels" #f)))
    'cells irc-servers-cells
    'title (lambda (buf) "IRC")
    'meta (lambda (buf)
            (string-append (number->string (length irc-servers)) " servers, "
                           (number->string (length (filter irc-connected? (map (lambda (s) (plist-get s 'name)) irc-servers))))
                           " connected"))
    'total (lambda (buf) (length irc-servers))
    'no-marks #t
    'footer (lambda (buf)
              '(("RET" "connect") ("a" "add") ("d" "remove") ("k" "disconnect")
                ("g" "refresh") ("q" "quit")))
    'keys '(("RET" "irc-servers-connect") ("a" "irc-servers-add")
            ("d" "irc-servers-remove") ("k" "irc-servers-disconnect")
            ("g" "irc-servers-refresh") ("q" "quit-window"))))

(define (irc-servers-refresh!)
  (when (buffer-known? *irc-servers-buffer*)
    (list-refresh! *irc-servers-buffer*)))

(define (irc-servers-current)
  (or (list-current *irc-servers-buffer*)
      (begin (message "no server on this line") #f)))

(define-command "irc-servers-connect" "Connect to the server on this row and open its buffer"
  (lambda ()
    (let ((name (irc-servers-current)))
      (when name
        (unless (irc-connected? name) (irc-connect! name))
        (irc-servers-refresh!)
        (switch-to-buffer! (irc-buffer! name #f))))))

(define-command "irc-servers-disconnect" "Disconnect the server on this row"
  (lambda ()
    (let ((name (irc-servers-current)))
      (when name
        (irc-disconnect! name "bye")
        (irc-servers-refresh!)
        (message (string-append name " disconnected"))))))

(define-command "irc-servers-add" "Add a server to the list"
  (lambda ()
    (minibuffer-read "Server name: " #f
      (lambda (name)
        (minibuffer-read "Host: " #f
          (lambda (host)
            (minibuffer-read "Port (6667): " #f
              (lambda (port)
                (minibuffer-read (string-append "Nick (" irc-nick "): ") #f
                  (lambda (nick)
                    (irc-servers-add! (string-trim name) (string-trim host)
                                      (irc-or (string-trim port) "6667")
                                      (irc-or (string-trim nick) irc-nick))
                    (irc-servers-refresh!)))))))))))

(define (irc-or s default) (if (equal? s "") default s))

(define (irc-servers-add! name host port nick)
  (customize-save! 'irc-servers
    (append (remove (lambda (s) (equal? (plist-get s 'name) name)) irc-servers)
            (list (list 'name name 'host host 'port port 'nick nick)))))

(define (irc-servers-remove! name)
  (customize-save! 'irc-servers
    (remove (lambda (s) (equal? (plist-get s 'name) name)) irc-servers)))

(define-command "irc-servers-remove" "Remove the server on this row from the list"
  (lambda ()
    (let ((name (irc-servers-current)))
      (when name
        (irc-servers-remove! name)
        (irc-servers-refresh!)
        (message (string-append name " removed"))))))

(define-command "irc-servers-refresh" "Redraw the server list"
  (lambda () (irc-servers-refresh!)))

(define-command "irc" "List your IRC servers; RET connects"
  (lambda () (list-mode-show! "irc-servers-mode")))

;;; --- the prompt -------------------------------------------------------------
;;; RET takes the input past the mark. Text goes to the buffer's target as
;;; a message. A line that starts with "/" runs a client command; a word the
;;; client does not know goes to the server as a raw command.

(define (irc-say! buf text)
  (let ((name (irc-buf-server buf))
        (target (irc-buf-target buf)))
    (cond ((not target)
           (irc-note! buf "this is the server buffer: /join CHANNEL, or /msg NICK TEXT"))
          ((not (irc-send! name (irc-format "PRIVMSG" (list target) text)))
           (irc-note! buf "not connected: /connect"))
          (else
           (set! *irc-cur* name)
           (irc-display buf (irc-said (irc-self-nick name) text))))))

(define (irc-raw! buf text)
  (unless (irc-send! (irc-buf-server buf) (string-append text "\r\n"))
    (irc-note! buf "not connected: /connect")))

;; the server takes a JOIN only after 001; one sent before it fails with
;; "illegal channel name", so a join waits in the record until then
(define (irc-registered? name)
  (if (irc-conn-get name 'registered) #t #f))

(define (irc-join-send! name channel key)
  (irc-send! name (irc-format "JOIN" (if (equal? key "") (list channel) (list channel key)))))

(define (irc-flush-joins! name)
  (let ((pending (or (irc-conn-get name 'pending) '()))
        (auto (or (plist-get (or (irc-server-entry name) '()) 'channels) '())))
    (irc-conn-put! name 'pending '())
    (for-each (lambda (j)
                (irc-join-send! name (car j) (cadr j))
                (irc-note! (irc-buffer! name (car j)) (string-append "joining " (car j))))
              (append pending (map (lambda (ch) (list ch "")) auto)))))

(define (irc-join! name channel key)
  (let ((buf (irc-buffer! name channel)))
    (cond ((not (irc-connected? name))
           (irc-note! buf "not connected: /connect"))
          ((not (irc-registered? name))
           (irc-conn-put! name 'pending
             (append (or (irc-conn-get name 'pending) '()) (list (list channel key))))
           (irc-note! buf (string-append "joining " channel " once the server registers you")))
          (else
           (irc-join-send! name channel key)
           (irc-note! buf (string-append "joining " channel))))
    (switch-to-buffer! buf)
    buf))

(define (irc-need-target buf what)
  (or (irc-buf-target buf)
      (begin (irc-note! buf (string-append what " needs a channel: this is the server buffer")) #f)))

;; (WORD DOC FN); FN gets the buffer and the rest of the line
(define *irc-commands* '())

(define (irc-defcommand! word doc fn)
  (set! *irc-commands*
    (append (remove (lambda (e) (equal? (car e) word)) *irc-commands*)
            (list (list word doc fn)))))

(irc-defcommand! "join" "/join CHANNEL [KEY] — join a channel and open its buffer"
  (lambda (buf rest)
    (let ((ws (irc-words rest)))
      (if (null? ws)
          (irc-note! buf "/join CHANNEL")
          (irc-join! (irc-buf-server buf)
                     (if (irc-channel? (car ws)) (car ws) (string-append "#" (car ws)))
                     (if (pair? (cdr ws)) (cadr ws) ""))))))

(irc-defcommand! "part" "/part [CHANNEL] [REASON] — leave a channel"
  (lambda (buf rest)
    (let* ((ws (irc-words rest))
           (chan (if (and (pair? ws) (irc-channel? (car ws))) (car ws) (irc-buf-target buf)))
           (reason (if (and (pair? ws) (irc-channel? (car ws)))
                       (string-join (cdr ws) " ")
                       rest)))
      (if (not chan)
          (irc-note! buf "/part CHANNEL")
          (let ((target (irc-buffer! (irc-buf-server buf) chan)))
            (irc-raw! buf (string-append "PART " chan (if (equal? reason "") "" (string-append " :" reason))))
            (irc-note! target (string-append "left " chan)))))))

(irc-defcommand! "msg" "/msg NICK TEXT — send a private message"
  (lambda (buf rest)
    (let ((ws (irc-words rest)))
      (if (or (null? ws) (null? (cdr ws)))
          (irc-note! buf "/msg NICK TEXT")
          (let* ((name (irc-buf-server buf))
                 (to (car ws))
                 (text (string-trim (substring rest (+ (string-index rest to) (string-length to)) (string-length rest)))))
            (if (irc-send! name (irc-format "PRIVMSG" (list to) text))
                (begin
                  (set! *irc-cur* name)
                  (irc-display (irc-buffer! name to) (irc-said (irc-self-nick name) text)))
                (irc-note! buf "not connected: /connect")))))))

(irc-defcommand! "query" "/query NICK — open a private conversation"
  (lambda (buf rest)
    (let ((ws (irc-words rest)))
      (if (null? ws)
          (irc-note! buf "/query NICK")
          (switch-to-buffer! (irc-buffer! (irc-buf-server buf) (car ws)))))))

(irc-defcommand! "me" "/me TEXT — send an action"
  (lambda (buf rest)
    (let ((name (irc-buf-server buf))
          (target (irc-need-target buf "/me")))
      (when target
        (if (irc-send! name (irc-format "PRIVMSG" (list target) (string-append "\x01;ACTION " rest "\x01;")))
            (begin
              (set! *irc-cur* name)
              (irc-display buf (irc-action (irc-self-nick name) rest)))
            (irc-note! buf "not connected: /connect"))))))

(irc-defcommand! "nick" "/nick NAME — change your nick"
  (lambda (buf rest)
    (let ((ws (irc-words rest)))
      (if (null? ws)
          (irc-note! buf (string-append "you are " (irc-self-nick (irc-buf-server buf))))
          (irc-raw! buf (string-append "NICK " (car ws)))))))

(irc-defcommand! "topic" "/topic [TEXT] — show the topic, or set it"
  (lambda (buf rest)
    (let ((target (irc-need-target buf "/topic")))
      (when target
        (irc-raw! buf (string-append "TOPIC " target (if (equal? rest "") "" (string-append " :" rest))))))))

(irc-defcommand! "names" "/names — count the people in the channel"
  (lambda (buf rest)
    (let ((target (irc-need-target buf "/names")))
      (when target (irc-raw! buf (string-append "NAMES " target))))))

(irc-defcommand! "list" "/list [PATTERN] — list the server's channels in a buffer"
  (lambda (buf rest)
    (irc-note! buf "asking for the channel list")
    (let ((name (irc-buf-server buf)))
      (when name (irc-conn-put! name 'list-pattern rest)))
    (irc-raw! buf (string-append "LIST" (if (equal? rest "") "" (string-append " " rest))))))

(irc-defcommand! "quit" "/quit [REASON] — disconnect from the server"
  (lambda (buf rest)
    (irc-disconnect! (irc-buf-server buf) (if (equal? rest "") #f rest))
    (irc-note! buf "disconnected")
    (irc-servers-refresh!)))

(irc-defcommand! "connect" "/connect — connect to this buffer's server again"
  (lambda (buf rest)
    (irc-connect! (irc-buf-server buf))
    (irc-servers-refresh!)))

(irc-defcommand! "verbose" "/verbose — show every line the server sends, or stop showing them"
  (lambda (buf rest)
    (irc-toggle-verbose! (irc-buf-server buf))))

(irc-defcommand! "raw" "/raw TEXT — send TEXT to the server as it is"
  (lambda (buf rest)
    (irc-raw! buf rest)))

(irc-defcommand! "help" "/help — list the commands"
  (lambda (buf rest)
    (for-each (lambda (e) (irc-note! buf (cadr e))) *irc-commands*)
    (irc-note! buf "any other /WORD goes to the server as a raw command")))

(define (irc-command! buf line)
  (let* ((parts (irc-split-command line))
         (word (car parts))
         (rest (cadr parts))
         (e (assoc word *irc-commands*)))
    (if e
        ((caddr e) buf rest)
        (irc-raw! buf (string-append (string-upcase word)
                                     (if (equal? rest "") "" (string-append " " rest)))))))

(define (irc-input! buf line)
  (if (string-prefix? "/" line)
      (irc-command! buf (substring line 1 (string-length line)))
      (irc-say! buf line)))

;; what RET does: take the input, clear it, act on it
(define (irc-send-input! buf)
  (let ((line (string-trim (irc-input-text buf))))
    (irc-clear-input! buf)
    (unless (equal? line "") (irc-input! buf line))
    line))

(define-command "irc-send" "Send the line at the prompt: text to the channel, a /command to the client"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (irc-buffer? buf)
          (irc-send-input! buf)
          (message "not an IRC buffer")))))

(define (irc-toggle-verbose! name)
  (set! irc-verbose (not irc-verbose))
  (when name
    (let ((n (irc-redraw! name)))
      (message (string-append "IRC " (if irc-verbose "verbose" "quiet")
                              ", redrew " (number->string n) " frames")))))

(define-command "irc-toggle-verbose" "Show every line the server sends, or only what people say"
  (lambda ()
    (irc-toggle-verbose! (irc-buf-server (current-buffer)))))

(define-command "irc-redraw" "Draw this server's transcripts again from the frames the connection kept"
  (lambda ()
    (let ((name (irc-buf-server (current-buffer))))
      (if name
          (message (string-append "IRC redrew " (number->string (irc-redraw! name)) " frames"))
          (message "not an IRC buffer")))))

;;; --- catalog ----------------------------------------------------------------

(mode-icon! "irc-mode" "")
(mode-icon! "irc-servers-mode" "")

(public! 'irc "M-x irc — list your IRC servers; RET connects and opens the server buffer")
(public! 'irc-servers "irc-servers — the servers M-x irc lists, as ('name 'host 'port ['nick]) plists")
(public! 'irc-toggle-verbose "M-x irc-toggle-verbose — show every line the server sends, or only what people say")
(public! 'irc-redraw "M-x irc-redraw — draw the transcripts again from the frames the connection kept")
(public! 'irc-connect! "(irc-connect! NAME) — connect to the server NAME from irc-servers and open its buffer")
(public! 'irc-join! "(irc-join! NAME CHANNEL KEY) — join CHANNEL on server NAME and open its buffer")
