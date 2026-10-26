;;; apps.scm --- app identity over buffers and windows.
;;;
;;; An app is more than one buffer: a home, its lists, its details. The
;;; editor has no handle on that set, so moving an app to a group has
;;; nothing to enumerate. Screen position, window count and name prefixes
;;; all lie the moment two instances of the same app are open at once.
;;;
;;; So the app names itself. Every buffer it opens carries an 'app-id
;;; local naming the instance, not the kind, and an 'app-role saying what
;;; that buffer is. Locals persist with the desktop, so the set survives
;;; a restart.

;; a move retags an app's buffers through group membership
(require 'groups)

(domain! 'windows)
(effects! '(read))

(define (app-id buf)
  ;; a site app's buffers name their app in 'site-app-name, the one
  ;; truth for them; any other app tags its buffers with app-claim!
  (and buf (buffer-known? buf)
       (let ((nm (buffer-local buf 'site-app-name)))
         (cond ((symbol? nm) (symbol->string nm))
               ((string? nm) nm)
               (else (buffer-local buf 'app-id))))))

(define (app-role buf)
  (and buf (buffer-known? buf) (buffer-local buf 'app-role)))

;; Every buffer of the instance, shown or not. The hidden ones are the
;; point: a detail nobody is looking at is still part of the app, and
;; leaving it behind splits the instance across two groups.
(define (app-buffers id)
  (and id (filter (lambda (buf) (equal? (app-id buf) id)) (buffer-list))))

;; ((WINDOW-ID BUFFER-NAME) ...), the shape window-list answers, for the
;; instance's visible windows alone. This is for layout work; a move
;; reads app-buffers instead.
(define (app-windows id)
  (and id (filter (lambda (w) (equal? (app-id (cadr w)) id)) (window-list))))

(public! 'app-id "(app-id BUF) — the app instance BUF belongs to, or #f")
(public! 'app-role "(app-role BUF) — BUF's part in its app: home, list, detail, aux")
(public! 'app-buffers "(app-buffers ID) — every buffer of app instance ID, shown or not")
(public! 'app-windows "(app-windows ID) — ((WINDOW-ID BUFFER-NAME) ...) for the instance's visible windows")

(effects! '(write))

(define (app-claim! buf id role)
  (and (buffer-known? buf) id
       (begin (buffer-set-local! buf 'app-id id)
              (buffer-set-local! buf 'app-role role)
              id)))

;; Retag the whole instance at once. The frame is untouched: every window
;; still shows what it showed, focus and point included. Membership
;; moved, not the user's view of it. Closing the windows afterwards is a
;; separate, louder act, and belongs to whoever asked for it.
(define (app-move-buffers! id group)
  (let ((bufs (or (app-buffers id) '())))
    (and (pair? bufs) group
         (let ((gid (buffer-move-to-group! (car bufs) group)))
           (for-each (lambda (buf) (buffer-move-to-group! buf gid)) (cdr bufs))
           bufs))))

(public! 'app-claim! "(app-claim! BUF ID ROLE) — mark BUF as part of app instance ID")
(public! 'app-move-buffers! "(app-move-buffers! ID GROUP) — move every buffer of instance ID to GROUP, leaving the frame as it is")

(effects! '(write display))

;; An app with a home of its own: a group named for it, made the first time.
;; Its buffers always belong there, whatever other group you also put them
;; in, and calling the app takes you there.
(define (app-group title)
  (let ((rec (group-record-by-name title)))
    (if rec (car rec) (group-record-create! title))))

(define (app-join-group! buf title)
  (let ((id (app-group title)))
    (when (and id (buffer-exists? buf) (not (buffer-in-group? buf id)))
      (buffer-add-group! buf id))
    id))

(public! 'app-group "(app-group TITLE) — the id of the app's own group, named TITLE; made the first time")
(public! 'app-join-group! "(app-join-group! BUF TITLE) — BUF joins the app's own group; answers its id")

;;; Opening an app shows its listing in the window you called it from
;;; and its detail in the pane beside it, as display-buffer-detail! puts
;;; every later page. Nothing else moves: no pane is re-tiled and no
;;; saved layout comes back; arranging the app is the separate
;;; app-layout command, and app-left / app-right move it.
(define (app-open! listing &optional detail)
  (let* ((l (and (boundp 'panes--ensure-layout!) (panes--ensure-layout!)))
         (here (and l (panes-focus l)))
         (lw (cond ((equal? (window-buffer (active-window)) listing) (active-window))
                   (here (panes-display-in-pane! listing here))
                   (else (switch-to-buffer-here! listing) (active-window)))))
    (when detail (display-buffer-detail! detail listing))
    lw))

(public! 'app-open! "(app-open! LISTING &optional DETAIL) — show LISTING in the window you are in and DETAIL in the pane beside it; no pane re-tiles, no layout is restored")

;; An app's buffers fall in three roles: its index (the home and its
;; lists), its pages, and the rest, like a player. Each role takes one
;; window; its other buffers wait in that window's history.
(define (app-role-class buf)
  (let* ((r (app-role buf))
         (r (if (string? r) (string->symbol r) r)))
    (cond ((memq r '(home list)) 'index)
          ((eq? r 'detail) 'detail)
          (else 'other))))

;; The mode a role's pane holds. A page's kind is its own mode, derived
;; from the app's detail mode, so the pane holds that family.
(define (app-class-mode buf)
  (if (eq? (app-role-class buf) 'detail)
      (or (buffer-local buf 'detail-family) (buffer-local buf 'mode-name))
      (buffer-local buf 'mode-name)))

;; the window that holds BUF, on screen or waiting behind its pane
(define (app-window-of buf)
  (or (window-showing buf)
      (let ((row (find (lambda (r) (equal? (cadr r) buf)) (panes-waiting-windows))))
        (and row (car row)))))

;; Lay the app out by role, on demand and never on open: its index window
;; goes to the app's starting pane (the first unless app-start-pane! named
;; another), its pages' window to the next pane and the rest to the one
;; after, a pane added while the layout has room. Each shows the buffer of
;; its role you see now, else the last one used. A window that was in front
;; of such a pane stays behind it; no other pane moves or re-tiles, and the
;; focus stays on its window. Answers the buffers it placed, or #f when the
;; app has nothing open in this group.
(define *app-start-panes* (if (boundp '*app-start-panes*) *app-start-panes* '()))

(define (app-start-pane id)
  (let ((hit (assoc id *app-start-panes*))) (if hit (cdr hit) 0)))

(define (app-start-pane! id index)
  (set! *app-start-panes*
        (cons (cons id index) (filter (lambda (p) (not (equal? (car p) id))) *app-start-panes*)))
  index)

(define (app-layout! id &optional start)
  (let* ((group (frame-group))
         (mine (filter (lambda (b)
                         (and (equal? (app-id b) id)
                              (or (not group) (buffer-in-group? b group))))
                       (buffer-list-mru)))
         (shown (map cadr (window-list)))
         (classes (filter (lambda (c) (pair? (cdr c)))
                          (map (lambda (class)
                                 (cons class (filter (lambda (b) (eq? (app-role-class b) class)) mine)))
                               '(index detail other))))
         ;; a role shows the one of its buffers you see now, else its last used
         (rows (map (lambda (c) (list (or (find (lambda (b) (member b shown)) (cdr c)) (cadr c)) c))
                    classes))
         (l0 (panes--ensure-layout!))
         (focus (app--front l0 (panes-focus l0))))
    (and (pair? rows)
         (let loop ((l l0) (rs rows) (i (or start (app-start-pane id))) (placed '()))
           (let* ((ids (panes-pane-ids l))
                  (slot (and (pair? rs)
                             (cond ((< i (length ids)) (list l (list-ref ids i)))
                                   ((panes-under-capacity? l) (panes-add-pane l))
                                   (else #f)))))
             (if slot
                 (let* ((l (car slot)) (pid (cadr slot)) (top (car (car rs)))
                        (key (panes-find l top))
                        (made (if key
                                  (list (panes-move-window l key pid 0) key)
                                  (panes-add-window l pid top (app-class-mode top)))))
                   (loop (car made) (cdr rs) (+ i 1) (cons (car rs) placed)))
                 (let ((p (and focus (panes-pane-of l focus))))
                   (panes-apply! (if p (panes-set-focus l p) l))
                   (for-each app--gather-role! (reverse placed))
                   (map car (reverse placed)))))))))

;; the role's window shows TOP and holds the rest of its role behind it,
;; and keeps its role: the next page of any list opens there
(define (app--gather-role! row)
  (let* ((top (car row))
         (theirs (cdr (cadr row)))
         (win (app-window-of top)))
    (when (and win (window-exists? win))
      (unless (equal? (window-buffer win) top) (window-set-buffer! win top))
      (for-each
        (lambda (w)
          (unless (equal? w win)
            (set-window-prev-buffers! w
              (filter (lambda (b) (not (member b theirs))) (window-prev-buffers w)))))
        (display--work-windows))
      (set-window-prev-buffers! win
        (append (filter (lambda (b) (not (equal? b top))) theirs)
                (filter (lambda (b) (not (member b theirs))) (window-prev-buffers win))))
      (window-mode-preference! win (app-class-mode top)))))

(public! 'app-layout! "(app-layout! ID &optional START) — on demand: app ID's index window to pane START (app-start-pane ID by default), its pages' to the next, the rest after; no other pane moves; answers the buffers placed")
(public! 'app-start-pane "(app-start-pane ID) — the pane index app-layout! starts app ID at; 0 unless named")
(public! 'app-start-pane! "(app-start-pane! ID INDEX) — app-layout! starts app ID at pane INDEX")
(public! 'app-role-class "(app-role-class BUF) — BUF's role in app-layout!: index, detail or other")

(define-command "app-layout"
  "Lay this app out: its lists in one window, its pages in another, the rest in a third"
  (lambda ()
    (let ((id (app-id (current-buffer))))
      (cond ((not id) (message "This buffer belongs to no app"))
            ((not (app-layout! id)) (message "Nothing of this app to lay out"))))))
(catalog-meta! 'command "app-layout" 'domain 'windows 'effects '(write display))

(define (app--forget-windows! id shown)
  ;; a dismissed app leaves no windows behind: the model dropped them, its
  ;; buffers stay alive, and the next visit opens what it needs
  (when shown
    (for-each (lambda (b) (detail-window-forget! b)) (app-buffers id)))
  shown)

;; Put the app away: its windows leave the screen and its buffers stay alive,
;; so a player keeps playing. The columns it held go to what else is on
;; screen, then to the group's most recent buffers.
(define (app-dismiss! id)
  (let* ((group (frame-group))
         (layout (panes-layout))
         (room (if layout (panes-pane-count layout) (length (display--work-windows))))
         ;; under the window model the app leaves every stack, else a redraw brings it back
         ;; the model forgets the app: its buffers leave every stack and the
         ;; windows of its modes close, so nothing of it is reopened in place
         (modes (filter (lambda (m) m)
                        (map (lambda (b) (buffer-local b 'mode-name)) (app-buffers id))))
         (kept (if layout
                   (let* ((layout (panes-validate layout buffer-known?))
                          (l (fold (lambda (l b) (if (equal? (app-id b) id) (panes-drop-buffer l b) l))
                                   layout (panes-buffers layout))))
                     (fold (lambda (l k) (if (member (panes-window-mode l k) modes) (panes-remove-window l k) l))
                           l (panes-window-keys l)))
                   #f))
         (screen (if kept
                     (map caddr (panes-visible kept))
                     (filter (lambda (b) (and b (not (equal? (app-id b) id))))
                             (map window-buffer (display--work-windows)))))
         (held (if kept (panes-buffers kept) '()))
         (fill (filter (lambda (b)
                         (and (not (equal? (app-id b) id))
                              (not (member b screen))
                              (not (member b held))
                              (fill-candidate? b)
                              (or (not group) (buffer-in-group? b group))))
                       (buffer-list-mru))))
    (app--forget-windows!
     id
     (cond ((not (pair? (app-windows id))) #f)
          (kept
           (let loop ((l kept) (fill fill))
             (if (or (null? fill) (>= (panes-pane-count l) room))
                 (and (pair? (panes-panes l)) (begin (panes-apply! l) (map caddr (panes-visible l))))
                 (let* ((added (panes-add-pane l))
                        (made (panes-add-window (car added) (cadr added) (car fill) (panes--buffer-mode (car fill)))))
                   (loop (car made) (cdr fill))))))
          (else
           (let* ((more (append screen fill))
                  (panes (take more (min room (length more)))))
             (and (pair? panes) (begin (panes-tile-default! panes) panes))))))))

(public! 'app-dismiss! "(app-dismiss! ID) — take app ID off the screen; its buffers stay alive and its columns go to other work")

(define-command "app-dismiss"
  "Put this app away: its windows leave the screen, its buffers keep running"
  (lambda ()
    (let ((id (app-id (current-buffer))))
      (cond ((not id) (message "This buffer belongs to no app"))
            ((not (app-dismiss! id)) (message "Nothing else to show in its place"))))))
(catalog-meta! 'command "app-dismiss" 'domain 'windows 'effects '(write display))

(define (app-push-read! id)
  (minibuffer-read "Push app to group: " (group-names)
    (lambda (input)
      (let ((name (string-trim input)))
        (if (equal? name "")
            (message "Group needs a name")
            (let ((gid (or (group-resolve-id name) (group-record-create! name))))
              (app-move-buffers! id gid)
              (message (string-append "App pushed to " name))))))))

(define-command "app-pull"
  "Pull this app into this group: every one of its buffers comes along"
  (lambda ()
    (let ((id (app-id (current-buffer))))
      (cond ((not id) (message "This buffer belongs to no app"))
            ((not (app-move-buffers! id (frame-group))) (message "Nothing of this app to pull"))
            (else (message "App pulled into this group"))))))
(catalog-meta! 'command "app-pull" 'domain 'windows 'effects '(write display))

(define-command "app-push"
  "Push this app to another group: every one of its buffers goes there"
  (lambda ()
    (let ((id (app-id (current-buffer))))
      (if id (app-push-read! id) (message "This buffer belongs to no app")))))
(catalog-meta! 'command "app-push" 'domain 'windows 'effects '(write display))

;;; The app's own windows, and nothing else: app-swap-windows trades the
;;; panes of its listing's window and its pages' window, each pane keeping
;;; its place and size; app-hide-detail-buffers takes its pages off the
;;; screen, each of their windows going back to what it showed before or
;;; closing, the pages alive for the next RET. Other apps' windows stay, and
;;; the focus stays on its window.
(effects! '(pure))

(define (app--front l pid)
  (let ((ws (plist-get (panes-pane l pid) 'windows)))
    (and (pair? ws) (plist-get (car ws) 'key))))

(define (app-swap-layout l a b)
  (let ((pa (and a (panes-pane-of l a))) (pb (and b (panes-pane-of l b))))
    (and pa pb (not (equal? pa pb))
         (panes-move-window (panes-move-window l a pb 0) b pa 0))))

(effects! '(write display))

(define (app--role-key id class)
  (let ((row (find (lambda (w) (eq? (app-role-class (cadr w)) class)) (or (app-windows id) '()))))
    (and row (car row))))

(define (app--apply-focused! l key)
  (let ((p (and key (panes-pane-of l key))))
    (panes-apply! (if p (panes-set-focus l p) l))))

(define (app-swap-windows! id)
  (let* ((l (panes--ensure-layout!))
         (focus (app--front l (panes-focus l)))
         (swapped (app-swap-layout l (app--role-key id 'index) (app--role-key id 'detail))))
    (and swapped (begin (app--apply-focused! swapped focus) #t))))

(define (app-hide-detail-buffers! id)
  (let* ((l (panes--ensure-layout!))
         (focus (app--front l (panes-focus l)))
         (pages (filter (lambda (b) (eq? (app-role-class b) 'detail)) (or (app-buffers id) '())))
         (held (filter (lambda (b) (panes-find l b)) pages))
         (kept (fold (lambda (l b) (panes-drop-buffer l b)) l held)))
    (and (pair? held)
         (begin
           ;; a focus whose window closed goes to the listing
           (app--apply-focused! kept (if (and focus (panes-pane-of kept focus)) focus (app--role-key id 'index)))
           held))))

(define-command "app-swap-windows"
  "Swap this app's listing and page windows between their panes"
  (lambda ()
    (let ((id (app-id (current-buffer))))
      (cond ((not id) (message "This buffer belongs to no app"))
            ((not (app-swap-windows! id)) (message "This app needs its listing and a page in two panes"))))))
(catalog-meta! 'command "app-swap-windows" 'domain 'windows 'effects '(write display))

(define-command "app-hide-detail-buffers"
  "Hide this app's pages: each of their windows goes back to what it showed before, or closes"
  (lambda ()
    (let ((id (app-id (current-buffer))))
      (cond ((not id) (message "This buffer belongs to no app"))
            ((not (app-hide-detail-buffers! id)) (message "No page of this app is open"))))))
(catalog-meta! 'command "app-hide-detail-buffers" 'domain 'windows 'effects '(write display))

(public! 'app-swap-layout "(app-swap-layout LAYOUT A B) — LAYOUT with windows A and B in each other's panes, at the front; #f when they share a pane; pure")
(public! 'app-swap-windows! "(app-swap-windows! ID) — app ID's listing and page windows trade panes; the focus stays on its window")
(public! 'app-hide-detail-buffers! "(app-hide-detail-buffers! ID) — app ID's pages leave the screen, their windows going back or closing; answers the pages hidden")

(effects! '(read))

;; The page open beside a listing, or #f. The detail contract already
;; remembers which window a listing opens its rows into, so this is that
;; window's buffer and not a guess from the name.
(define (app-detail-here &optional buf)
  (let* ((owner (or buf (current-buffer)))
         (win (and owner (boundp 'detail-window) (detail-window owner))))
    (and win (window-buffer win))))

(public! 'app-detail-here "(app-detail-here [LISTING]) — the page open beside the listing, or #f")

(effects! '(write))

(define (app--detail-shim! cmd)
  ;; One command per mirrored key, named after what it runs, so C-h b in the
  ;; listing says where the key goes instead of hiding it behind a lambda.
  (let ((name (string-append "app-detail-" cmd)))
    (define-command name
      (string-append "Run " cmd " in the page beside this listing")
      (lambda ()
        (let ((page (app-detail-here)))
          (if page
              (with-current-buffer page (lambda () (run-command cmd)))
              (message "No page is open beside this listing")))))
    name))

;; In an app the listing and the page are one surface. A key the listing does
;; not claim belongs to the page beside it, so the page's own verbs work from
;; the row that opened them and the focus never leaves the list. Keys the
;; listing already answers are left alone: the listing wins its own map.
;;
;; Answers the keys it mirrored.
(define app--listing-own-keys
  ;; Moving between rows belongs to the listing even where its map leaves the
  ;; key to the global one; mirroring these would scroll the page instead.
  '("<up>" "<down>" "C-n" "C-p" "<prior>" "<next>" "<home>" "<end>"))

(define (app-detail-keys! list-mode detail-mode)
  (let ((lmap (mode-keymap list-mode))
        (dmap (mode-keymap detail-mode)))
    (and lmap dmap
         (fold (lambda (done pair)
                 (let ((keys (car pair)) (cmd (cadr pair)))
                   (if (or (keymap-lookup lmap keys)
                           (member keys app--listing-own-keys)
                           (string-prefix? "keymap:" cmd))
                       done
                       (begin (define-key lmap keys (app--detail-shim! cmd))
                              (cons keys done)))))
               '() (keymap-bindings dmap)))))

(public! 'app-detail-keys! "(app-detail-keys! LIST-MODE DETAIL-MODE) — a key the listing does not bind runs in the page beside it; answers the keys mirrored")

(effects! '(read))

;; Turn a callback API into a value. STARTER is given a continuation and
;; answers whatever that continuation is handed, or #f at the deadline.
;;
;; This BLOCKS the lane it runs on, so it belongs inside a task-run! or a
;; task-spawn, never on a keypress. Used that way it replaces the retry
;; chains an app otherwise grows one per asynchronous call, each with its
;; own debounce key, its own countdown, and its own way of going quiet.
(define (app-await starter &optional seconds)
  (let ((done #f) (value #f))
    (starter (lambda (v) (set! value v) (set! done #t)))
    (wait-until (lambda () done) (* 1000 (or seconds 20)) 50)
    value))

;; A pause inside a task. wait-until on a predicate that never answers is
;; the sleep this Scheme has.
(define (app-pause ms)
  (wait-until (lambda () #f) ms ms)
  #t)

(public! 'app-await "(app-await STARTER &optional SECONDS) — run STARTER with a continuation and answer what it is given; blocks, so call it inside a task")
(public! 'app-pause "(app-pause MS) — pause inside a task")
