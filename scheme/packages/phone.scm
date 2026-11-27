;;; phone.scm --- the phone client's policy
;;;
;;; The phone client (/m, Compos.Ui.MobileLive) shows one buffer at a
;;; time and has no keys. Its tab bar has four places: the chats, a new
;;; chat, the buffers and the groups. Each list here answers the rows the
;;; phone draws, and each action here is what a tap does. The phone's
;;; frame keeps the single layout, so what the phone shows never changes
;;; the windows of the same group on the desktop.

(domain! 'interaction)
(effects! '(read))

(define phone-list-max 200)

(define (phone--terms q)
  (filter (lambda (s) (not (equal? s "")))
          (string-split (string-downcase (string-trim (or q ""))) " ")))

(define (phone--match? terms . texts)
  (let ((hay (string-downcase (apply string-append (map (lambda (t) (string-append (or t "") " ")) texts)))))
    (let loop ((ts terms))
      (cond ((null? ts) #t)
            ((string-contains? hay (car ts)) (loop (cdr ts)))
            (else #f)))))

(define (phone--group-label g)
  (if (and (string? g) (group-resolve-id g)) (group-display-name g) ""))

(define (phone--recent-buffers)
  "(NAME GROUP) of every buffer, the most recent first"
  (map (lambda (r) (list (car r) (nth 2 r)))
       (car (cdr (buffer-rows (list 'sort 'recent 'limit phone-list-max 'fields '(name group)))))))

(define (phone-view buf)
  "(GROUP-LABEL CHAT?): what the phone's header shows for BUF"
  (list (phone--group-label (frame-group))
        (and buf (buffer-exists? buf) (chat-buffer? buf) #t)))

(define (phone-chats q cur)
  "((NAME TITLE SUB CURRENT?) ...): the chats, the most recent first.
   SUB is the chat's group and its state. Q narrows by words."
  (let* ((terms (phone--terms q))
         (chats (chat-list))
         (recent (filter (lambda (r) (member (car r) chats)) (phone--recent-buffers)))
         (seen (map car recent))
         (rest (map (lambda (c) (list c (buffer-group c)))
                    (filter (lambda (c) (not (member c seen))) chats))))
    (filter (lambda (row) (phone--match? terms (cadr row) (caddr row)))
            (map (lambda (r)
                   (let* ((name (car r))
                          (state (or (ignore-errors (lambda () (chats-row-label name))) ""))
                          (g (phone--group-label (cadr r))))
                     (list name name
                           (cond ((equal? state "") g)
                                 ((equal? g "") state)
                                 (else (string-append g " · " state)))
                           (equal? name cur))))
                 (append recent rest)))))

(define (phone-buffers q cur)
  "((SECTION ((NAME TITLE SUB CURRENT?) ...)) ...): the buffers that are
   not chats, this group's first, then the others. Q narrows by words."
  (let* ((terms (phone--terms q))
         (here (frame-group))
         (rows (filter (lambda (r) (not (chat-buffer? (car r)))) (phone--recent-buffers)))
         (row (lambda (r) (list (car r) (car r) (phone--group-label (cadr r)) (equal? (car r) cur))))
         (keep (lambda (rs) (filter (lambda (x) (phone--match? terms (cadr x) (caddr x))) (map row rs))))
         (mine (keep (filter (lambda (r) (and here (equal? (cadr r) here))) rows)))
         (others (keep (filter (lambda (r) (not (and here (equal? (cadr r) here)))) rows))))
    (filter (lambda (s) (pair? (cadr s)))
            (list (list (if here (phone--group-label here) "buffers") mine)
                  (list "other groups" others)))))

(define (phone-groups q)
  "((ID LABEL SUB CURRENT?) ...): the groups, the most recent first"
  (let ((here (frame-group)) (terms (phone--terms q)))
    (filter (lambda (row) (phone--match? terms (cadr row)))
            (map (lambda (id) (list id (group-display-name id) "" (equal? id here)))
                 (group-ids-mru)))))

(effects! '(write display))

(define (phone-attach!)
  "The phone's frame keeps one window, whatever its group's layout is,
   and it is in a group: the most recent one when it has none."
  (unless (frame-group)
    (let ((ids (group-ids-mru)))
      (when (pair? ids) (switch-to-group! (car ids)))))
  (unless (equal? (panes-frame-layout) 'single)
    (panes-frame-layout-set! 'single))
  #t)

(define (phone-show! name)
  "Show buffer NAME on the phone. A buffer of another group takes the
   phone to that group first. Answers NAME, or #f."
  (cond ((not (and (string? name) (buffer-exists? name)))
         (message "That buffer is gone") #f)
        (else
         (let ((g (buffer-group name)))
           (when (and (string? g) (group-resolve-id g) (not (equal? g (frame-group))))
             (switch-to-group! g)))
         (switch-to-buffer-here! name)
         (when (chat-buffer? name)
           (with-current-buffer name (lambda () (end-of-buffer!))))
         name)))

(define (phone-group! g)
  "Go to group G and show its chat. Answers the chat, or #f."
  (let ((id (group-resolve-id g)))
    (cond ((not id) (message "No such group") #f)
          (else (unless (equal? id (frame-group)) (switch-to-group! id))
                (phone-show! (group-chat id))))))

(define (phone-new-chat!)
  "Start a new chat in the phone's group and show it. Answers the chat."
  (phone-attach!)
  (let ((id (and (frame-group) (group-resolve-id (frame-group)))))
    (if (not id)
        (begin (message "No group for a chat") #f)
        (let ((buf (group-chat-new-name id))
              (record (group-record-by-id id)))
          (buffer-create buf)
          (group-chat-init! buf id)
          (when (boundp 'llm-default-bundle-apply!) (llm-default-bundle-apply! buf id))
          (chat-set-group! buf id)
          (unless (and record (group-record-primary-chat-id record))
            (group-record-update! id 'primary-chat-id (chat-stable-id! buf)))
          (when (boundp 'workspace-chat-inherit!) (workspace-chat-inherit! buf (group-name id)))
          (phone-show! buf)))))

(define (phone-send! chat text)
  "Send TEXT to CHAT, the chat the phone shows. Answers CHAT, or #f."
  (let ((text (string-trim (or text ""))))
    (cond ((equal? text "") #f)
          ((not (and (string? chat) (buffer-exists? chat) (chat-buffer? chat)))
           (message "Open a chat to send a message") #f)
          (else
           (phone-show! chat)
           (with-current-buffer chat
             (lambda ()
               (chat-replace-input! chat text)
               (run-command "agent-send")))
           chat))))

(public! 'phone-view "(phone-view BUF) -> (GROUP-LABEL CHAT?): what the phone's header shows for BUF")
(public! 'phone-chats "(phone-chats Q CUR) -> ((NAME TITLE SUB CURRENT?) ...): the chats, most recent first, narrowed by the words of Q")
(public! 'phone-buffers "(phone-buffers Q CUR) -> ((SECTION ROWS) ...): the buffers that are not chats, this group's first")
(public! 'phone-groups "(phone-groups Q) -> ((ID LABEL SUB CURRENT?) ...): the groups, most recent first")
(for-each (lambda (n) (catalog-meta! 'function n 'domain 'interaction 'effects '(read)))
          '("phone-view" "phone-chats" "phone-buffers" "phone-groups"))
(public! 'phone-attach! "(phone-attach!) -> the phone's frame keeps one window and is in a group")
(public! 'phone-show! "(phone-show! NAME) -> show buffer NAME on the phone, in its own group")
(public! 'phone-group! "(phone-group! G) -> go to group G and show its chat")
(public! 'phone-new-chat! "(phone-new-chat!) -> start a new chat in the phone's group and show it")
(public! 'phone-send! "(phone-send! CHAT TEXT) -> send TEXT to CHAT")
(for-each (lambda (n) (catalog-meta! 'function n 'domain 'interaction 'effects '(write display)))
          '("phone-attach!" "phone-show!" "phone-group!" "phone-new-chat!"))
(catalog-meta! 'function "phone-send!" 'domain 'interaction 'effects '(write spend))

(provide 'phone)
