;;; handheld.scm --- policy for the handheld client.
;;;
;;; The handheld client (/m) is the editor on a phone: one column, one
;;; window, and no chords. Elixir draws it and forwards each tap; this
;;; file decides what a tap does and what the sheets list.
;;;
;;; A thumb reaches four places from the bar at the bottom: the group's
;;; chat, the group's buffers, the groups, and the commands. The composer
;;; is the chat's input: a line of text goes to the group's chat. A tap on
;;; a line of a buffer moves point there; a tap on the line point is
;;; already on opens it, as RET does, so a list opens its row.

(category! 'interaction)
(domain! 'interaction)
(effects! '(read))

(defgroup 'handheld "The handheld client: the chat, the buffers, the groups and the commands on a phone.")

(define (handheld-doc-line cmd)
  (let ((doc (command-doc cmd)))
    (if (string? doc) (car (string-split doc "\n")) "")))

;;; --- the groups --------------------------------------------------------------
;;; Each row is (ID LABEL CURRENT?), most recent first.

(define (handheld-groups)
  (let ((here (frame-group)))
    (map (lambda (id) (list id (group-display-name id) (equal? id here)))
         (group-ids-mru))))

;;; --- the buffers ----------------------------------------------------------------
;;; Two sections, most recent first: the frame group's buffers, then every
;;; other buffer with its group named. Each row is (NAME TITLE SUB CURRENT?).

(define *handheld-buffers-max* 200)

(define (handheld-buffer-rows spec cur sub)
  (map (lambda (r)
         (let ((name (car r)))
           (list name (or (nth 2 r) name) (sub r) (equal? name cur))))
       (car (cdr (buffer-rows (append spec (list 'sort 'recent 'limit *handheld-buffers-max*
                                                 'fields '(name title mode group))))))))

(define (handheld-buffer-sub r)
  (let ((mode (or (nth 3 r) "")) (g (nth 4 r)))
    (if (and (string? g) (not (equal? g "")))
        (string-append mode " · " (group-display-name g))
        mode)))

;; ((SECTION ROWS) ...)
(define (handheld-buffers &optional cur)
  (let* ((g (frame-group))
         (here (if g (handheld-buffer-rows (list 'groups (list g)) cur (lambda (r) (or (nth 3 r) ""))) '()))
         (names (map car here))
         (rest (filter (lambda (row) (not (member (car row) names)))
                       (handheld-buffer-rows '() cur handheld-buffer-sub))))
    (filter (lambda (s) (pair? (car (cdr s))))
            (list (list (if g (group-display-name g) "buffers") here)
                  (list "everything else" rest)))))

;;; --- the commands ------------------------------------------------------------
;;; A command row is (NAME DOC). The sheet opens on two sections: the
;;; commands the phone ran last, then the commands the buffer's own
;;; keymaps bind. Typing searches every command.

(define *handheld-recents-max* 12)
(define *handheld-here-max* 40)
(define *handheld-search-max* 60)

(define (handheld-note-command! name)
  (when (and (string? name) (not (equal? name "")))
    (history-push! 'handheld name))
  name)

(define (handheld-command-row name) (list name (handheld-doc-line name)))

(define (handheld-recents)
  (let ((known (command-names)))
    (let loop ((names (append (history-items 'handheld) (history-items 'M-x)))
               (seen '()) (out '()) (n 0))
      (cond ((or (null? names) (>= n *handheld-recents-max*)) (reverse out))
            ((or (member (car names) seen) (not (member (car names) known)))
             (loop (cdr names) seen out n))
            (else (loop (cdr names) (cons (car names) seen)
                        (cons (handheld-command-row (car names)) out) (+ n 1)))))))

;; the commands BUF's own keymaps bind, the global map left out
(define (handheld-buffer-command-names buf)
  (let loop ((maps (filter (lambda (m) (not (equal? m "global"))) (buffer-keymaps buf)))
             (out '()))
    (if (null? maps)
        (reverse out)
        (loop (cdr maps)
              (let inner ((rows (keymap-bindings (car maps))) (out out))
                (if (null? rows)
                    out
                    (let ((cmd (car (cdr (car rows)))))
                      (inner (cdr rows)
                             (if (or (member cmd out)
                                     (equal? cmd "self-insert-command")
                                     (string-prefix? "keymap:" cmd))
                                 out
                                 (cons cmd out))))))))))

(define (handheld-buffer-commands buf)
  (let loop ((names (handheld-buffer-command-names buf)) (out '()) (n 0))
    (if (or (null? names) (>= n *handheld-here-max*))
        (reverse out)
        (loop (cdr names) (cons (handheld-command-row (car names)) out) (+ n 1)))))

;; ((SECTION ROWS) ...): the sheet with nothing typed
(define (handheld-commands buf)
  (filter (lambda (s) (pair? (car (cdr s))))
          (list (list "recent" (handheld-recents))
                (list "this buffer" (handheld-buffer-commands buf)))))

(define (handheld-terms text)
  (filter (lambda (s) (not (equal? s "")))
          (string-split (string-downcase (string-trim text)) " ")))

(define (handheld-terms-match? terms hay)
  (let loop ((ts terms))
    (cond ((null? ts) #t)
          ((string-contains? hay (car ts)) (loop (cdr ts)))
          (else #f))))

;; every command TEXT names: each term must match the name or the first
;; doc line. The buffer's own commands come first.
(define (handheld-search buf text)
  (let ((terms (handheld-terms text))
        (here (handheld-buffer-command-names buf)))
    (if (null? terms)
        '()
        (let loop ((names (command-names)) (near '()) (far '()) (n 0))
          (if (or (null? names) (>= n *handheld-search-max*))
              (map handheld-command-row (append (reverse near) (reverse far)))
              (let* ((name (car names))
                     (hay (string-downcase (string-append name " " (handheld-doc-line name)))))
                (cond ((not (handheld-terms-match? terms hay)) (loop (cdr names) near far n))
                      ((member name here) (loop (cdr names) (cons name near) far (+ n 1)))
                      (else (loop (cdr names) near (cons name far) (+ n 1))))))))))

;; What the header shows for BUF: (GROUP-LABEL CHAT?)
(define (handheld-view buf)
  (let ((g (frame-group)))
    (list (if g (group-display-name g) "")
          (and (chat-buffer? buf) #t))))

(effects! '(write))

;;; --- moving ------------------------------------------------------------------
;;; The phone moves inside the layout the group already has: a buffer a
;;; window shows is reached by selecting that window, and anything else
;;; comes into the window the phone draws. No pane is added or tiled.

(define (handheld-show! buf)
  (let ((w (window-showing buf)))
    (if w (select-window! w) (switch-to-buffer-here! buf))
    buf))

;; the group's chat, founded when the group has none; #f without a group
(define (handheld-chat!)
  (let* ((g (frame-group))
         (chat (and g (group-chat g))))
    (cond (chat (handheld-show! chat) (end-of-buffer!) chat)
          (else (message "This frame is in no group, so there is no chat") #f))))

;; A tap on a group: switch to it and show its chat. Returns the chat.
(define (handheld-group! g)
  (let ((id (group-resolve-id g)))
    (cond ((not id) (message "No such group") #f)
          (else (unless (equal? id (frame-group)) (switch-to-group! id))
                (handheld-chat!)))))

;; A tap on a buffer. One of another group takes the frame to that group
;; first, as switch-to-buffer! does, so the header and the chat follow.
(define (handheld-buffer! name)
  (let ((g (and (buffer-exists? name) (buffer-group name))))
    (cond ((not (buffer-exists? name))
           (message (string-append "No buffer named " name)) #f)
          ((or (not g) (equal? g (frame-group))) (handheld-show! name))
          (else (switch-to-buffer! name) name))))

;; Run a command by name and remember it. Returns #t, or #f for a name
;; that is not a command.
(define (handheld-run-command! name)
  (if (member name (command-names))
      (begin (handheld-note-command! name) (run-command name) #t)
      (begin (message (string-append "No command named " name)) #f)))

;; The composer: TEXT goes to the group's chat. Outside the chat, the
;; chat comes up first, so the answer is on the screen. Returns the chat
;; buffer, or #f when nothing received it.
(define (handheld-compose! text)
  (let ((text (string-trim text)))
    (if (equal? text "")
        (begin (message "Nothing to send") #f)
        (let ((buf (if (chat-buffer? (current-buffer)) (current-buffer) (handheld-chat!))))
          (when buf
            (chat-replace-input! buf text)
            (run-command "agent-send"))
          buf))))

;; The point rail: move point to the start of line N in the current
;; buffer. The client turns a drag position into N.
(define (handheld-scrub! n)
  (let* ((total (line-number-at-pos (buffer-size (current-buffer))))
         (line (max 1 (min total n))))
    (goto-char! (line-start-position line))
    line))

;; A tap on line N of the current buffer: point moves there, and a tap
;; on the line point is on presses RET. Returns 'move or 'open.
(define (handheld-tap-line! n)
  (if (= n (line-number-at-pos (point)))
      (begin (dispatch-keys (list "RET")) 'open)
      (begin (handheld-scrub! n) 'move)))

(effects! '(read))

(public! 'handheld-view
  "(handheld-view BUF) -> (GROUP-LABEL CHAT?): what the handheld header shows for BUF")
(public! 'handheld-groups
  "(handheld-groups) -> ((ID LABEL CURRENT?) ...): the groups, most recent first")
(public! 'handheld-buffers
  "(handheld-buffers [CUR]) -> ((SECTION ((NAME TITLE SUB CURRENT?) ...)) ...): the frame group's buffers, then every other one, most recent first; CUR is flagged")
(public! 'handheld-commands
  "(handheld-commands BUF) -> ((SECTION ((NAME DOC) ...)) ...): the commands the phone ran last, then the ones BUF's own keymaps bind")
(public! 'handheld-search
  "(handheld-search BUF TEXT) -> ((NAME DOC) ...): every command TEXT names, BUF's own first; empty TEXT is no rows")
(for-each (lambda (n) (catalog-meta! 'function n 'domain 'interaction 'effects '(read)))
          '("handheld-view" "handheld-groups" "handheld-buffers" "handheld-commands" "handheld-search"))
(public! 'handheld-note-command!
  "(handheld-note-command! NAME): remember NAME as a command the phone ran")
(catalog-meta! 'function "handheld-note-command!" 'domain 'interaction 'effects '(write))
(public! 'handheld-run-command!
  "(handheld-run-command! NAME): run the command NAME and remember it; #f when no such command")
(catalog-meta! 'function "handheld-run-command!" 'domain 'interaction 'effects '(write))
(public! 'handheld-chat!
  "(handheld-chat!): show the frame group's chat in the phone's window, founding it when there is none; returns the chat or #f")
(catalog-meta! 'function "handheld-chat!" 'domain 'interaction 'effects '(write display))
(public! 'handheld-group!
  "(handheld-group! GROUP): switch to GROUP and show its chat; returns the chat or #f")
(catalog-meta! 'function "handheld-group!" 'domain 'interaction 'effects '(write display))
(public! 'handheld-buffer!
  "(handheld-buffer! NAME): show NAME on the phone, selecting the window that shows it, else bringing it into this one")
(catalog-meta! 'function "handheld-buffer!" 'domain 'interaction 'effects '(write display))
(public! 'handheld-compose!
  "(handheld-compose! TEXT): send TEXT to the group's chat, showing the chat first; returns the chat or #f")
(catalog-meta! 'function "handheld-compose!" 'domain 'interaction 'effects '(write))
(public! 'handheld-tap-line!
  "(handheld-tap-line! N): move point to line N; on the line point is on, press RET. Returns move or open")
(catalog-meta! 'function "handheld-tap-line!" 'domain 'interaction 'effects '(write))
(public! 'handheld-scrub!
  "(handheld-scrub! N): move point to the start of line N; returns the line reached")
(catalog-meta! 'function "handheld-scrub!" 'domain 'interaction 'effects '(write))
