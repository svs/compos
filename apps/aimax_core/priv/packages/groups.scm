;;; groups.scm --- Buffer groups, saved layouts, and companion chats.

;;;; A group is a durable context with a stable record and opaque ID.
;;;; Work buffers contain group ID sets. Chats contain one owning group ID.
;;;; This package owns membership, switching, layouts, records, and chats.

(domain! 'buffers)
(effects! '(write))

;;; --- durable group records and buffer-local membership -------------------------
;;; Work buffers use 'group-ids. Chats use one 'group-id and one 'chat-id. —
;;; Old 'group and 'companion-of — locals migrate on the first membership read.
;;; Group records persist independently, including empty and chatless groups.
;;; (group-buffers g) derives live membership from buffer-local identity.





(define *group-records* '())
(define *group-next-id* 0)

(define (group-record-id record) (nth 0 record))
(define (group-record-name record) (nth 1 record))
(define (group-record-meta record) (nth 2 record))
(define (group-record-layout record) (nth 3 record))
(define (group-record-noise record) (nth 4 record))
(define (group-record-primary-chat-id record) (nth 5 record))

(define (group-record-by-id id)
  (let loop ((records *group-records*))
    (cond ((null? records) #f)
          ((equal? (group-record-id (car records)) id) (car records))
          (else (loop (cdr records))))))

(define (group-record-by-name name)
  (let loop ((records *group-records*))
    (cond ((null? records) #f)
          ((equal? (group-record-name (car records)) name) (car records))
          (else (loop (cdr records))))))

(define (group-resolve-id value)
  (and value
       (let ((record (or (group-record-by-id value)
                         (group-record-by-name value))))
         (and record (group-record-id record)))))

(define (group-name value)
  (let ((record (and value
                     (or (group-record-by-id value)
                         (group-record-by-name value)))))
    (and record (group-record-name record))))

(define (group-new-id!)
  (set! *group-next-id* (+ *group-next-id* 1))
  (string-append "grp:" (number->string (current-time)) ":"
                 (number->string *group-next-id*)))

(define (group-record-create! name)
  (let ((clean (string-trim name)))
    (cond ((equal? clean "") #f)
          ((group-record-by-name clean) #f)
          (else
            (let* ((id (group-new-id!))
                   (record (list id clean #f #f "quiet" #f)))
              (set! *group-records* (append *group-records* (list record)))
              id)))))

;; group-new-id! writes this prefix, so a string that carries it is an id
;; and never a name a person chose.
(define (group-id-string? value)
  (and (string? value) (string-prefix? "grp:" value)))

;; An id that answers no record is a dangling reference, not a new name.
;; Every membership is an id now, and a buffer can hold one whose record
;; is gone — a restart restores the buffer locals, and the records ride a
;; different lane. Founding a group from it puts "grp:1787432485:1" in the
;; C-c g list and on the reader's screen. buffer-group-ids already drops
;; such an id on read; the write path must refuse it the same way.
(define (group-ensure-record! value)
  (or (group-resolve-id value)
      (and (string? value)
           (not (group-id-string? value))
           (group-record-create! value))))

(define (group-record-update! value field new-value)
  (let ((id (group-resolve-id value)))
    (when id
      (set! *group-records*
        (map
          (lambda (record)
            (if (not (equal? (group-record-id record) id))
                record
                (list id
                      (if (equal? field 'name) new-value (group-record-name record))
                      (if (equal? field 'meta) new-value (group-record-meta record))
                      (if (equal? field 'layout) new-value (group-record-layout record))
                      (if (equal? field 'noise) new-value (group-record-noise record))
                      (if (equal? field 'primary-chat-id) new-value
                          (group-record-primary-chat-id record)))))
          *group-records*)))))

(define (group-record-delete! value)
  (let ((id (group-resolve-id value)))
    (when id
      (group-frame-context-remove-id! id)
      (set! *group-records*
        (remove (lambda (record) (equal? (group-record-id record) id))
                *group-records*)))))

(define (group-state-restore! saved)
  (when (and (pair? saved) (pair? (cdr saved)))
    (set! *group-next-id* (car saved))
    (set! *group-records* (car (cdr saved)))))

(persist-global! 'groups-v2
  (lambda () (list *group-next-id* *group-records*))
  group-state-restore!)

(define *group-frame-context-keys* '(current-group previous-group))

(define (group-frame-context-id locals key)
  (let ((entry (assoc key
                 (filter (lambda (item)
                           (and (pair? item) (pair? (cdr item))))
                         locals))))
    (and entry (group-resolve-id (car (cdr entry))))))

(define (group-frame-context-state)
  (let ((live (frame-list)))
    (let loop ((entries *frame-locals*) (out '()))
      (if (null? entries)
          (reverse out)
          (let* ((entry (car entries))
                 (valid? (and (pair? entry)
                              (pair? (cdr entry))
                              (member (car entry) live)))
                 (locals (if valid? (car (cdr entry)) '()))
                 (current (and (pair? locals)
                               (group-frame-context-id locals 'current-group)))
                 (previous (and (pair? locals)
                                (group-frame-context-id locals 'previous-group)))
                 (saved (append
                          (if current (list (list 'current-group current)) '())
                          (if previous (list (list 'previous-group previous)) '()))))
            (loop (cdr entries)
                  (if (and valid? (pair? saved))
                      (cons (list (car entry) saved) out)
                      out)))))))

(define (group-frame-context-restore! saved)
  (when (pair? saved)
    (for-each
      (lambda (entry)
        (when (and (pair? entry)
                   (pair? (cdr entry))
                   (member (car entry) (frame-list)))
          (let* ((frame (car entry))
                 (raw (car (cdr entry)))
                 (pairs (if (pair? raw)
                            (filter (lambda (item)
                                      (and (pair? item) (pair? (cdr item))))
                                    raw)
                            '()))
                 (current (assoc 'current-group pairs))
                 (previous (assoc 'previous-group pairs))
                 (restored
                   (append
                     (if (and current (string? (car (cdr current))))
                         (list (list 'current-group (car (cdr current))))
                         '())
                     (if (and previous (string? (car (cdr previous))))
                         (list (list 'previous-group (car (cdr previous))))
                         '())))
                 (old (assoc frame *frame-locals*))
                 (locals (if old (car (cdr old)) '()))
                 (runtime
                   (filter
                     (lambda (item)
                       (not (and (pair? item)
                                 (member (car item) *group-frame-context-keys*))))
                     locals))
                 (others
                   (filter (lambda (item)
                             (not (and (pair? item)
                                       (equal? (car item) frame))))
                           *frame-locals*)))
            (set! *frame-locals*
              (cons (list frame (append restored runtime)) others)))))
      saved)
    ;; every restored frame stands in its group again, so each modeline
    ;; must say so without waiting for the next switch
    (for-each
      (lambda (entry)
        (when (and (pair? entry) (member (car entry) (frame-list)))
          (let* ((frame (car entry))
                 (fr (assoc frame *frame-locals*))
                 (locals (if fr (car (cdr fr)) '()))
                 (kv (assoc 'current-group locals)))
            (set-frame-group-label!
              (or (and kv (group-name (car (cdr kv)))) #f)
              frame))))
      saved)))


(define (group-frame-context-remove-id! id)
  (set! *frame-locals*
    (map
      (lambda (entry)
        (if (and (pair? entry)
                 (pair? (cdr entry))
                 (pair? (car (cdr entry))))
            (list (car entry)
              (filter
                (lambda (item)
                  (not
                    (and (pair? item)
                         (pair? (cdr item))
                         (member (car item) *group-frame-context-keys*)
                         (equal? (group-resolve-id (car (cdr item))) id))))
                (car (cdr entry))))
            entry))
      *frame-locals*)))

(persist-global! 'group-frame-contexts
  group-frame-context-state
  group-frame-context-restore!)

(define (group-work-buffer? b)
  (and (buffer-known? b)
       (not (chat-buffer? b))
       (not (string-prefix? " " b))))

(define (group-migrate-chat-state! b id)
  (let ((record (group-record-by-id id)))
    (when (and record (not (group-record-meta record))
               (buffer-local b 'group-meta))
      (group-record-update! id 'meta (buffer-local b 'group-meta)))
    (when (and record (not (group-record-layout record))
               (buffer-local b 'group-layout))
      (group-record-update! id 'layout (buffer-local b 'group-layout)))
    (when (buffer-local b 'group-noise)
      (group-record-update! id 'noise (buffer-local b 'group-noise)))
    (when (and record (not (group-record-primary-chat-id record)))
      (group-record-update! id 'primary-chat-id (chat-stable-id! b)))))

;; A chat names ONE group, and the id it holds may outlive the record:
;; dissolve sweeps (group-buffers id), which only sees live buffers, so a
;; sleeping chat keeps pointing at a group nobody can name. Resolve on
;; every read and clear what no longer answers — buffer-group-ids has
;; always done this for work buffers, and a chat must not be the one
;; place a dangling id survives.
(define (chat-group-id b)
  (let ((held (buffer-local b 'group-id)))
    (if held
        (let ((valid (group-resolve-id held)))
          (cond ((not valid) (buffer-set-local! b 'group-id #f) #f)
                (else
                  (unless (equal? valid held)
                    (buffer-set-local! b 'group-id valid))
                  valid)))
        (let ((legacy (or (buffer-local b 'group)
                          (buffer-local b 'companion-of))))
          (and legacy
               (let ((id (group-ensure-record! legacy)))
                 (buffer-set-local! b 'group-id id)
                 (buffer-set-local! b 'group #f)
                 (buffer-set-local! b 'companion-of #f)
                 (group-migrate-chat-state! b id)
                 id))))))

(define (buffer-group-ids b)
  (if (chat-buffer? b)
      '()
      (let ((ids (buffer-local b 'group-ids)))
        (if (pair? ids)
            (let ((normalized
                    (fold (lambda (out id)
                            (let ((valid (group-resolve-id id)))
                              (if (or (not valid) (member valid out))
                                  out
                                  (append out (list valid)))))
                          '() ids)))
              (unless (equal? normalized ids)
                (buffer-set-local! b 'group-ids normalized))
              (buffer-set-local! b 'group #f)
              (buffer-set-local! b 'companion-of #f)
              normalized)
            (let ((legacy (or (buffer-local b 'group)
                              (buffer-local b 'companion-of))))
              (if legacy
                  (let ((id (group-ensure-record! legacy)))
                    (buffer-set-local! b 'group-ids (list id))
                    (buffer-set-local! b 'group #f)
                    (buffer-set-local! b 'companion-of #f)
                    (list id))
                  '()))))))

(define (buffer-groups b) (buffer-group-ids b))

(define (buffer-group b)
  (if (chat-buffer? b)
      (chat-group-id b)
      (let* ((ids (buffer-group-ids b))
             (current (frame-local 'current-group)))
        (cond ((and current (member current ids)) current)
              ((pair? ids) (car ids))
              (else #f)))))

;; ALWAYS a string. This is a marginalia field, and marginalia measures
;; its columns with string-length: one #f here breaks the annotation of
;; every candidate beside it. A buffer can name a group whose record is
;; gone, and group-name answers #f for that id — so drop the nameless
;; ones rather than pass them on.
(define (buffer-group-summary b)
  (let ((names (if (chat-buffer? b)
                   (let ((id (chat-group-id b)))
                     (if id (list (group-name id)) '()))
                   (map group-name (buffer-group-ids b)))))
    (let ((known (filter string? names)))
      (if (pair? known) (string-join known ", ") "ungrouped"))))

(define (buffer-in-group? b value)
  (let ((id (group-resolve-id value)))
    (if (and id
             (if (chat-buffer? b)
                 (equal? (chat-group-id b) id)
                 (member id (buffer-group-ids b))))
        #t
        #f)))

(define (chat-set-group! b value)
  (let ((id (and value (group-ensure-record! value))))
    (buffer-set-local! b 'group-id id)
    (buffer-set-local! b 'group #f)
    (buffer-set-local! b 'companion-of #f)
    id))

(define (buffer-add-group! b value)
  (let ((id (group-ensure-record! value)))
    (cond ((not id) #f)
          ((chat-buffer? b) #f)
          ((buffer-in-group? b id) id)
          (else
            (buffer-set-local! b 'group-ids
              (append (buffer-group-ids b) (list id)))
            (buffer-set-local! b 'group #f)
            (buffer-set-local! b 'companion-of #f)
            id))))

(define (buffer-move-to-group! b value)
  (let ((id (and value (group-ensure-record! value))))
    (if (chat-buffer? b)
        (chat-set-group! b id)
        (begin
          (buffer-set-local! b 'group-ids (if id (list id) '()))
          (buffer-set-local! b 'group #f)
          (buffer-set-local! b 'companion-of #f)))
    id))

(define (buffer-remove-group! b value)
  (let ((id (group-resolve-id value)))
    (when id
      (if (chat-buffer? b)
          (when (equal? (chat-group-id b) id)
            (buffer-set-local! b 'group-id #f))
          (buffer-set-local! b 'group-ids
            (remove (lambda (x) (equal? x id)) (buffer-group-ids b)))))))

(define (buffer-replace-group! b old new)
  (let ((old-id (group-resolve-id old))
        (new-id (group-ensure-record! new)))
    (when (and old-id new-id (buffer-in-group? b old-id))
      (buffer-add-group! b new-id)
      (buffer-remove-group! b old-id))))

;; the group column in a buffer prompt. A group founded by a file buffer
;; carries the full path as its name; show the last segment.
;;
;; Every prompt and message names a group the way a person named it. The
;; opaque ID belongs to the code and must never reach the screen. A caller
;; can hold an ID whose record is gone, so fall back to what it passed.
(define (group-display-name g)
  (or (group-name g) (and (string? g) g) ""))

;; The short name a card wears. A project root is not a group yet, so it
;; keeps its own basename rather than going blank.
(define (group-label g)
  (let ((name (group-display-name g)))
    (if (equal? name "")
        ""
        (car (reverse (string-split name "/"))))))


;; a group's metadata lives on its chat buffer: the chat is the group's
;; durable surface, so 'group-meta rides chat-identity-locals and
;; survives reset, restart, and save
;; the buffer that holds a group's durable state ('group-meta,
;; 'group-layout): its chat. A chat made by group-chat but never shown
(define (chat-stable-id! buf)
  (or (buffer-local buf 'chat-id)
      (let ((id (string-append "chat:" (number->string (current-time)) ":"
                               (number->string (+ *group-next-id* 1)))))
        (set! *group-next-id* (+ *group-next-id* 1))
        (buffer-set-local! buf 'chat-id id)
        id)))

(define (group-primary-chat g)
  (let* ((id (group-resolve-id g))
         (record (and id (group-record-by-id id)))
         (primary (and record (group-record-primary-chat-id record))))
    (and primary
         (let loop ((buffers (buffer-list)))
           (cond ((null? buffers) #f)
                 ((and (chat-buffer? (car buffers))
                       (equal? (chat-group-id (car buffers)) id)
                       (equal? (buffer-local (car buffers) 'chat-id) primary))
                  (car buffers))
                 (else (loop (cdr buffers))))))))

(define (group-meta g)
  (let ((record (and (group-resolve-id g)
                     (group-record-by-id (group-resolve-id g)))))
    (and record (group-record-meta record))))

(define (group-meta-set! g text)
  (group-record-update! (group-ensure-record! g) 'meta text))


(define (group-layout g)
  (let* ((record (and (group-resolve-id g)
                      (group-record-by-id (group-resolve-id g))))
         (saved (and record (group-record-layout record))))
    (if (and (pair? saved) (equal? (car saved) 'per-frame))
        (let ((entry (assoc (selected-frame) (cdr saved))))
          (and entry (car (cdr entry))))
        saved)))

(define (group-layout-set! g tree)
  (let* ((id (group-ensure-record! g))
         (record (and id (group-record-by-id id)))
         (saved (and record (group-record-layout record)))
         (entries (if (and (pair? saved) (equal? (car saved) 'per-frame))
                      (cdr saved)
                      '()))
         (frame (selected-frame))
         (others (filter (lambda (entry)
                           (not (equal? (car entry) frame)))
                         entries)))
    (when id
      (group-record-update! id 'layout
        (cons 'per-frame (cons (list frame tree) others)))
      tree)))

(define (group-layout-save! g)
  (group-layout-set! g (window-tree)))





;; a group's window arrangement rides its chat too, as one opaque
;; window-tree value: capture on leave, restore on switch




;; switch the frame to a group: save the layout you leave, then bring
;; the group's saved layout back exactly as you left it. A group with
;; no saved layout opens its most recent member full-frame.
;; a group that never saved a layout still ARRIVES arranged: the most
;; recent work buffer on the left, and on the right the group chat
;; (companion noise "loud") or the next work buffer. One member alone
;; fills the frame.
(define (group-default-layout! g)
  (let* ((docs (group-docs g))
         (chat (group-primary-chat g))
         (main (cond ((pair? docs) (car docs))
                     (chat chat)
                     (else
                       (unless (buffer-exists? "*scratch*")
                         (buffer-create "*scratch*"))
                       "*scratch*")))
         (loud (equal? (group-noise g) "loud"))
         (side (cond ((and loud chat (pair? docs)) chat)
                     ((and (pair? docs) (pair? (cdr docs))) (car (cdr docs)))
                     (else #f))))
    (delete-other-windows!)
    (switch-to-buffer! main)
    (when side
      (split-window! 'h 0.6)
      (other-window!)
      (switch-to-buffer! side)
      (let ((window (window-showing main)))
        (when window (select-window! window))))))

;; a restored window whose buffer is an empty, unmodified, pathlike
;; shell — and whose file exists — re-reads from disk. The layout
;; recreated the NAME; the content lives in the file.


(define (group-restore-prune! g)
  (for-each
    (lambda (w)
      (let ((b (car (cdr w))))
        (when (and (buffer-local b 'transient)
                   (not (equal? (buffer-group b) g))
                   (> (length (window-list)) 1))
          (delete-window-id! (car w)))))
    (window-list)))

;; the modeline names the group the FRAME stands in, and only Scheme can
;; turn a record id into a name — so every move that changes where the
;; frame stands, or what its group is called, pushes the label out.
(define (frame-group-label-refresh!)
  (set-frame-group-label! (or (group-name (frame-local 'current-group)) #f)))

;; a reattached frame keeps its group in *frame-locals*, but the Elixir
;; frame behind it is new and its label is empty — so push it on attach
(add-hook! 'frame-attach-hook frame-group-label-refresh!)

;;; --- scenes: a declared group arrangement -------------------------------------
;;; A scene is a DECLARATION, not a script: the group, the arrangement, and
;;; how to build each pane, as data.
;;;
;;;   (define-scene! "mail"
;;;     '(h 0.32 (ensure "*notmuch*" "notmuch-index")
;;;              (ensure "*notmuch-show*" "notmuch-preview")
;;;              group-chat))
;;;
;;; Running it always gives the same frame, in the same group. Run it twice
;;; and nothing moves; kill any pane's buffer and the next run builds it
;;; back. That is the whole contract, and it is why a scene declares its
;;; panes with `ensure` — a name plus the command that makes it.
;;;
;;; The spec is the mode-layout grammar (DIR RATIO PANE ...), plus one pane
;;; of its own: group-chat, the group's own chat, made if it does not exist.
;;; Every pane a scene realises JOINS its group, so a scene's buffers are
;;; members by construction rather than by hand.
;;;
;;; A scene is NOT what group switching does. switch-to-group! takes you
;;; back to the layout you left behind; a scene asserts one. Two different
;;; questions — "where was I" and "build me this" — so two verbs.

(define *scenes* '())             ; ((group-name spec) ...) — by NAME, not id:
                                  ; a declaration outlives the record it names

(define (define-scene! name spec)
  (set! *scenes*
    (cons (list name spec)
          (remove (lambda (e) (equal? (car e) name)) *scenes*)))
  name)

(define (scene-spec g)
  (let* ((name (or (group-name g) g))
         (e (and (string? name) (assoc name *scenes*))))
    (and e (car (cdr e)))))

(define (scene-names) (map car *scenes*))

;; group-chat is the one pane the generic engine cannot name: the buffer
;; depends on the group, and it may have to be made. Resolve it here, then
;; hand the engine a spec it already understands.
(define (scene--pane id pane)
  (if (equal? pane 'group-chat)
      (or (group-chat id) "")
      pane))

(define (scene--resolve id spec)
  (if (not (pair? spec))
      (scene--pane id spec)
      (append (list (car spec) (car (cdr spec)))
              (map (lambda (pane) (scene--pane id pane)) (cdr (cdr spec))))))

;; Realise a scene. The frame stands in the scene's group BEFORE any pane
;; is built, so every buffer a pane's command opens lands in that group
;; rather than in whichever one you came from.
(define (scene-open! name)
  (let ((spec (scene-spec name)))
    (if (not spec)
        (begin (message (string-append "No scene named " name)) #f)
        (let ((id (begin (layout-abort!) (group-ensure-record! name)))
              (from (frame-group)))
          ;; leaving a group snapshots it, exactly as switching does: the
          ;; way back to where you were must stay exact
          (when (and from (not (equal? from (group-resolve-id name))))
            (group-layout-save-if-shown! from)
            (set-frame-local! 'previous-group from))
          (set-frame-local! 'current-group id)
          (frame-group-label-refresh!)
          (let* ((resolved (scene--resolve id spec))
                 (anchor (layout--pane #f (car (cdr (cdr resolved)))))
                 (panes (apply-layout! anchor resolved)))
            ;; a pane the scene built is a member by construction
            (for-each (lambda (b)
                        (if (chat-buffer? b)
                            (chat-set-group! b id)
                            (buffer-add-group! b id)))
                      panes)
            (mru-note-group! id)
            (windows-shown-catchup!)
            panes)))))

(define-command "scene" "Open a declared scene: its group, its arrangement"
  (lambda ()
    (let ((names (scene-names)))
      (if (null? names)
          (message "No scenes declared")
          (minibuffer-read "Scene: " names scene-open!)))))

(public! 'define-scene! "(define-scene! NAME SPEC) — declare a group's arrangement; SPEC is (DIR RATIO PANE ...) where a PANE is \"NAME\", (ensure \"NAME\" \"COMMAND\"), or group-chat")
(public! 'scene-open! "(scene-open! NAME) — stand in the scene's group and build its arrangement, making any missing pane")

(define (switch-to-group! g)
  (let ((id (begin (group-migrate-live!) (group-resolve-id g))))
    (if (not id)
        (message "No such group")
        (begin
          (winner-save!)
          (set! *winner-inhibit* #t)
          (let ((from (frame-group)))
            (when (and from (not (equal? from id)))
              (group-layout-save-if-shown! from)
              (set-frame-local! 'previous-group from)))
          (set-frame-local! 'current-group id)
          (frame-group-label-refresh!)
          (let ((saved (group-layout id)))
            (if saved
                (begin
                  (window-tree-set! saved)
                  (group-restore-prune! id))
                (begin
                  (group-default-layout! id)
                  (group-layout-save! id))))
          (set! *winner-inhibit* #f)
          (mru-note-group! id)
          (windows-shown-catchup!)
          (message (string-append "Switched to group " (group-name id)))))))

;; the group the FRAME stands in. Switching sets it; a detour through
;; an ungrouped buffer (scratch, help) does not lose it. The buffer's
;; own group is the fallback for a frame that never switched.
(define (frame-group)
  (let* ((current (frame-local 'current-group))
         (resolved (group-resolve-id current)))
    (if resolved
        (begin
          (unless (equal? current resolved)
            (set-frame-local! 'current-group resolved))
          resolved)
        (let ((ids (if (chat-buffer? (current-buffer))
                       (let ((id (chat-group-id (current-buffer))))
                         (if id (list id) '()))
                       (buffer-group-ids (current-buffer)))))
          (if (and (pair? ids) (null? (cdr ids))) (car ids) #f)))))

;; a layout snapshot is only true when the group is on screen: saving
;; a scratch detour AS the group's arrangement would overwrite the
;; real one


;; a group's layout is captured only from INSIDE the group: the
;; buffer you act from is a member. What happens on any other surface
;; — the board, a listing, a detour — never rewrites it, so the last
;; arrangement made IN the group is the one that comes back.
(define (group-visible-homogeneous? g)
  (let ((id (group-resolve-id g))
        (work (group-visible-work-buffers)))
    (and id
         (pair? work)
         (null? (filter (lambda (b) (not (buffer-in-group? b id))) work)))))

(define (group-layout-save-if-shown! g)
  (when (group-visible-homogeneous? g)
    (group-layout-save! g)))

;; a group is UNCOVERED when no window shows a transient surface from
;; outside it — a board, a listing. Its own members are transient too
;; (a mail view, a dired listing), and they are part of the group's
;; arrangement, not a cover on it.
(define (group-uncovered? g)
  (let loop ((windows (window-list)))
    (cond ((null? windows) #t)
          ((let ((b (car (cdr (car windows)))))
             (and (buffer-local b 'transient)
                  (not (buffer-in-group? b g))))
           #f)
          (else (loop (cdr windows))))))

;; NAME is about to take a pane. When it comes from outside the group
;; on screen, the arrangement it covers goes on record first. Only an
;; uncovered arrangement counts: a second board must not overwrite the
;; snapshot the first one earned. A group with no holder yet gets no
;; snapshot — displaying a buffer must not create a chat.
(define (group-layout-save-before-cover! name)
  (let ((id (frame-group)))
    (when (and id
               (not (buffer-in-group? name id))
               (group-visible-homogeneous? id)
               (group-uncovered? id))
      (group-layout-save! id))))

;; found a group from what is on screen: every window's buffer joins,
;; the layout is saved, and the group chat holds the durable state
(define (group-found-from-windows! name)
  (group-create-and-enter! name (group-visible-work-buffers) (window-tree)))

;; the LLM reads the member list and writes one sentence of metadata
(define (group-describe! g)
  (message "LLM writing group description...")
  (llm (string-append
         "These buffers form one working group in an editor.\n"
         "Write one sentence that says what the group is for.\n"
         "Return ONLY the sentence.\n\n"
         (string-join (group-buffers-mru g) "\n"))
       (lambda (text)
         (group-meta-set! g (string-trim text))
         (when (buffer-exists? *groups-buffer*)
           (list-refresh! *groups-buffer*))
         (message (string-append (group-label g) ": " (string-trim text))))))

;; C-c d from a grouped buffer
(define-command "group-describe"
  "Ask the LLM to write this group's description"
  (lambda ()
    (let ((g (buffer-group (current-buffer))))
      (if g (group-describe! g) (message "Not in a group")))))

;;; --- the groups board: C-x G --------------------------------------------------
;;; The command-palette design's second panel as a list: one row per group —
;;; members, companion noise, metadata. RET switches (layout and all),
;;; d asks the LLM to describe, n cycles noise, x dissolves.

(define *groups-buffer* "*groups*")

;; companion noise policy, an identity local on the group chat:
;; "off" (no companion window), "quiet" (notify on finish), "loud"
;; (lives in a window). Display rules read it; the board sets it.
(define (group-noise g)
  (let ((record (and (group-resolve-id g)
                     (group-record-by-id (group-resolve-id g)))))
    (let ((noise (and record (group-record-noise record))))
      (if (member noise '("off" "quiet" "loud")) noise "quiet"))))

(define (group-noise-set! g v)
  (group-record-update! (group-ensure-record! g) 'noise
    (if (member v '("off" "quiet" "loud")) v "quiet")))



;; a group with a modified member has unsaved work in it
(define (group-dirty? g)
  (pair? (filter buffer-modified? (group-buffers g))))

(define (group-noise-face n)
  (cond ((equal? n "loud") "warn")
        ((equal? n "off") "faint")
        (else "dim")))

;; the members read as the group's contents, then what the group is for
(define (group-cells buf g)
  (let ((members (group-buffers-mru g)))
    (list (if (group-dirty? g) (list "●" "warn") "")
          (list (group-label g) "accent")
          (list (number->string (length members)) "dim")
          (list (group-noise g) (group-noise-face (group-noise g)))
          (list (string-append
                  (string-join (map buffer-short-label (take-n members 3)) " · ")
                  (let ((m (group-meta g)))
                    (if m (string-append "  —  " m) "")))
                "faint"))))

(define (groups-meta buf)
  (let* ((rows (list-entries buf))
         (n (length rows))
         (bufs (fold (lambda (acc g) (+ acc (length (group-buffers g)))) 0 rows))
         (dirty (length (filter group-dirty? rows))))
    (string-append (number->string n) (if (= n 1) " group" " groups")
                   " · " (number->string bufs) " buffers"
                   " · " (number->string dirty) " modified"
                   " · most recent first")))

(define (groups--current)
  (let ((g (list-current (current-buffer))))
    (or g (begin (message "no group on this line") #f))))

(define-command "group-switch" "Switch to a group and restore its layout"
  (lambda ()
    (if (equal? (list-mode-of (current-buffer)) "groups-mode")
        (let ((g (groups--current)))
          (when g (switch-to-group! g)))
        (let* ((previous (frame-local 'previous-group))
               (previous-name (and (group-resolve-id previous)
                                   (group-name previous)))
               (others (filter (lambda (name)
                                 (not (equal? name previous-name)))
                               (group-names)))
               (candidates (if previous-name
                               (cons (list previous-name "previous group") others)
                               others)))
          (if (null? candidates)
              (message "No groups")
              (minibuffer-read "Switch group: " candidates
                (lambda (name)
                  (let ((id (group-resolve-id (string-trim name))))
                    (if id
                        (switch-to-group! id)
                        (message "No such group"))))))))))

;; a verb here acts on every marked group, or on the row at point when
;; nothing is marked — the rule every list follows. The marks go when the
;; verb has run, because a mark on a group that no longer exists outlives
;; every refresh.
(define (groups--act! word verb)
  (let* ((buf (current-buffer))
         (targets (list-targets buf)))
    (if (null? targets)
        (message "no group on this line")
        (begin (for-each verb targets)
               (for-each (lambda (g) (list-unmark-key! buf g)) targets)
               (list-refresh! buf)
               (message (string-append word " " (number->string (length targets))
                                       " " (list-noun buf (length targets))))))))

(define-command "group-describe-at-point" "LLM-describe the marked groups"
  (lambda () (groups--act! "describing" group-describe!)))

(define-command "group-noise-cycle" "Cycle the companion noise of the marked groups"
  (lambda ()
    (groups--act! "cycled"
      (lambda (g)
        (let ((cur (group-noise g)))
          (group-noise-set! g (cond ((equal? cur "off") "quiet")
                                    ((equal? cur "quiet") "loud")
                                    (else "off"))))))))

(define (group-dissolve! g)
  (let ((id (begin (group-migrate-live!) (group-resolve-id g))))
    (when id
      (for-each
        (lambda (b)
          (if (chat-buffer? b)
              (when (equal? (chat-group-id b) id)
                (buffer-set-local! b 'group-id #f))
              (buffer-remove-group! b id)))
        (group-buffers id))
      (when (equal? (frame-local 'current-group) id)
        (set-frame-local! 'current-group #f))
      (group-record-delete! id)
      (frame-group-label-refresh!)
      #t)))

(define-command "group-dissolve" "Dissolve a group without killing its buffers"
  (lambda ()
    (groups--act! "dissolved" group-dissolve!)))

;; kill a whole context: every member buffer dies, except a modified
;; file buffer — unsaved work never dies silently
(define (group-kill! g)
  (let* ((id (begin (group-migrate-live!) (group-resolve-id g)))
         (name (or (group-name id) ""))
         (members (if id (group-buffers id) '()))
         (survivors '()))
    (for-each
      (lambda (b)
        (cond
          ((and (buffer-path b) (buffer-modified? b))
           (set! survivors (cons b survivors)))
          ((and (not (chat-buffer? b))
                (pair? (cdr (buffer-group-ids b))))
           (set! survivors (cons b survivors)))
          (else (buffer-kill! b))))
      members)
    (for-each
      (lambda (b)
        (when (buffer-known? b) (buffer-remove-group! b id)))
      survivors)
    (when (equal? (frame-local 'current-group) id)
      (set-frame-local! 'current-group #f))
    (when id (group-record-delete! id))
    (message
      (if (pair? survivors)
          (string-append "Killed group " name ". Kept "
                         (number->string (length survivors)) " buffers")
          (string-append "Killed group " name)))))

(define-command "group-kill" "Kill every buffer in the current group"
  (lambda ()
    (let ((g (frame-group)))
      (if g (group-kill! g) (message "Not in a group")))))

;; rename a context: every member retags, and the durable state
;; follows. The chat buffer keeps its NAME (there is no buffer
;; rename); membership is by role, so a live chat stays the group's.
;; An unshown chat is found by name, so its identity is copied onto
;; the new name's chat instead.
(define (group-rename! old new)
  (let ((id (begin (group-migrate-live!) (group-resolve-id old)))
        (clean (string-trim new)))
    (cond ((not id) (message "No such group"))
          ((equal? clean "") (message "Group needs a name"))
          ((group-record-by-name clean)
           (message (string-append "Group " clean " already exists")))
          (else
            (let ((before (group-name id)))
              (group-record-update! id 'name clean)
              (frame-group-label-refresh!)
              (message (string-append "Renamed group " before " to " clean)))))))

(define-command "group-rename" "Rename the current group"
  (lambda ()
    (let ((g (frame-group)))
      (if (not g)
          (message "Not in a group")
          (minibuffer-read (string-append "Rename " (group-label g) " to: ") '()
            (lambda (new) (group-rename! g (string-trim new))))))))

(define-command "group-rename-at-point" "Rename the group at point"
  (lambda ()
    (let ((g (groups--current)))
      (when g
        (minibuffer-read (string-append "Rename " (group-label g) " to: ") '()
          (lambda (new)
            (group-rename! g (string-trim new))
            (when (buffer-exists? *groups-buffer*)
              (list-refresh! *groups-buffer*))))))))

(define-command "group-kill-at-point" "Kill every buffer of the marked groups"
  (lambda () (groups--act! "killed" group-kill!)))

(define-command "groups-refresh" "Refresh the groups board"
  (lambda () (list-refresh! *groups-buffer*)))

(define-command "groups" "The groups board: switch, describe, set noise"
  (lambda () (list-mode-show! "groups-mode")))

(define-list-mode! "groups-mode"
  (list
    'doc (string-append
           "Every buffer group as a table: members, companion noise, "
           "metadata. RET switches to the group and restores its layout; "
           "d writes its description with the LLM; n cycles noise; "
           "x dissolves; K kills the members. `m` marks a group, `*` marks "
           "every one, and the verbs act on the marked groups — or on the "
           "row at point when nothing is marked. `/` narrows as you type "
           "and `\\` widens by one.")
    'buffer *groups-buffer*
    'rows (lambda (buf) (list-keep buf (group-names)))
    'columns (lambda (buf)
               (list (list "" 1)
                     (list "group" 24)
                     (list "buffers" 7 'right)
                     (list "noise" 6)
                     (list "members" #f)))
    'cells group-cells
    'title (lambda (buf) "Groups")
    'meta groups-meta
    'total (lambda (buf) (length (group-names)))
    'footer (lambda (buf)
              '(("RET" "switch") ("m" "mark") ("*" "all") ("r" "rename")
                ("d" "describe") ("n" "noise") ("x" "dissolve")
                ("K" "kill buffers") ("/" "filter") ("g" "refresh")
                ("q" "quit")))
    'key (lambda (buf g) g)
    'noun "group"
    'keys '(("RET" "group-switch") ("r" "group-rename-at-point")
            ("d" "group-describe-at-point")
            ("n" "group-noise-cycle") ("x" "group-dissolve")
            ("K" "group-kill-at-point")
            ("g" "groups-refresh") ("q" "quit-window"))))

(define (group-buffers g)
  (let ((id (group-resolve-id g)))
    (if id
        (filter (lambda (b) (buffer-in-group? b id)) (buffer-list))
        '())))

;; Members in MRU order; buffers never visited this session trail.
;; A group is a set, so the list dedupes by name.
(define (group-buffers-mru g)
  (let* ((id (group-resolve-id g))
         (mru (if id
                  (filter (lambda (b) (buffer-in-group? b id))
                          (buffer-list-mru))
                  '())))
    (dedupe-names
      (append mru (remove (lambda (b) (member b mru)) (group-buffers id))))))

(define (group-migrate-live!)
  (for-each
    (lambda (buf)
      (if (chat-buffer? buf)
          (chat-group-id buf)
          (buffer-group-ids buf)))
    (buffer-list))
  #t)

(define (group-ids)
  (group-migrate-live!)
  (map group-record-id *group-records*))

(define (group-names)
  (group-migrate-live!)
  (map group-record-name *group-records*))

;; the group's chat counts by NAME as well as by mode: a chat made by
;; group-chat but never shown has no mode yet, and it is still not a
;; work buffer
(define (group-docs g)
  (remove (lambda (b) (or (chat-buffer? b) (equal? b (group-chat-name g))))
          (group-buffers-mru g)))

;; a buffer with no group founds one named after itself
(define (group-ensure! b)
  (or (buffer-group b)
      (let ((id (or (group-resolve-id b) (group-record-create! b))))
        (when id
          (if (chat-buffer? b)
              (chat-set-group! b id)
              (buffer-add-group! b id)))
        id)))

;; a fresh group chat is a rich surface from birth: help on top (a "meta"
;; card in the agent design), then the >>> you: input region
(define (group-chat-init! buf g)
  (let ((id (group-resolve-id g)))
    (with-current-buffer buf
      (lambda () (set-mode! "chat-mode")))
    (chat-surface-init! buf (string-append "companion · " (group-name id))
      (string-append
        "RET sends · C-c w hops to the document · "
        "C-c m model · C-c C-v plain view\n"
        "it reads the live buffers before it speaks, "
        "and edits them in place when you ask\n"))))

(define (group-chat-name g)
  (string-append "*chat:" (group-name g) "*"))

;; the group's chat = its most recently used chat-mode member; created on
;; demand already tagged, so a killed chat is simply remade next time
;; Total by contract: a NAME that has no record yet gets one. Asking a
;; group for its chat is asking for the group, and the caller that names
;; it ("*chat:mail*" for the mail scene) means it to exist. Resolving
;; only, this answered #f and every caller then handed #f to
;; switch-to-buffer!.
(define (group-chat g)
  (let* ((id (group-ensure-record! g))
         (primary (and id (group-primary-chat id)))
         (chats (and id (filter chat-buffer? (group-buffers-mru id)))))
    (cond (primary primary)
          ((and chats (pair? chats))
           (let ((buf (car chats)))
             (group-record-update! id 'primary-chat-id (chat-stable-id! buf))
             buf))
          (id
            (let ((buf (group-chat-name id)))
              (unless (buffer-exists? buf)
                (buffer-create buf)
                (group-chat-init! buf id))
              (chat-set-group! buf id)
              (group-record-update! id 'primary-chat-id (chat-stable-id! buf))
              (when (boundp (quote workspace-chat-inherit!))
                (workspace-chat-inherit! buf (group-name id)))
              buf))
          (else #f))))

;; ensure the two-pane layout (work left, group chat right) and select the
;; chat window; returns the chat buffer name
(define (group-chat-new-name g)
  (let loop ((n 2))
    (let ((name (string-append "*chat:" (group-name g) ":"
                               (number->string n) "*")))
      (if (buffer-known? name) (loop (+ n 1)) name))))

(define (group-chat-new! g)
  (let ((id (group-resolve-id g)))
    (if (not id)
        #f
        (let ((buf (group-chat-new-name id)))
          (buffer-create buf)
          (group-chat-init! buf id)
          (chat-set-group! buf id)
          (group-record-update! id 'primary-chat-id (chat-stable-id! buf))
          (when (boundp (quote workspace-chat-inherit!))
            (workspace-chat-inherit! buf (group-name id)))
          (group-chat-buffer-show! buf)
          buf))))

(define-command "group-chat" "Show or create the current group's primary chat"
  (lambda ()
    (let ((id (or (frame-local 'current-group)
                  (buffer-group (current-buffer)))))
      (if (not (group-resolve-id id))
          (message "No current group")
          (group-chat-show! id)))))

(define-command "group-chat-new" "Create a new primary chat in the current group"
  (lambda ()
    (let ((id (or (frame-local 'current-group)
                  (buffer-group (current-buffer)))))
      (if (not (group-resolve-id id))
          (message "No current group")
          (group-chat-new! id)))))

(define (group-chat-buffer-show! buf)
  (let ((w (window-showing buf)))
    (if w
        (select-window! w)
        (begin
          (delete-other-windows!)
          (split-window! 'h 0.6)
          (other-window!)
          (switch-to-buffer! buf))))
  (set-mode! "chat-mode")
  (end-of-buffer!)
  buf)

(define (group-chat-show! g)
  (let ((buf (group-chat g)))
    (and buf (group-chat-buffer-show! buf))))

;; ask the group without leaving the current buffer: the minibuffer prompt
;; becomes a group-chat turn, point stays put, the reply lands on the right
(define (group-ask! g)
  (minibuffer-read (string-append "Ask " (group-display-name g) ": ") (history-items 'companion-ask)
    (lambda (prompt)
      (history-push! 'companion-ask prompt)
      (let ((back (active-window)))
        (group-chat-show! g)
        (insert! prompt)
        (run-command "agent-send")
        (when (window-exists? back)
          (select-window! back))))))

;; the group a joining buffer gets by default: the group the frame
;; stands in, else the most recent group in history. The buffer's own
;; group is never the default — joining it is a no-op. The answer is a
;; display name, because the prompt and the candidate list show it.
(define (group-join-default buf)
  (let loop ((ids (list (frame-group)
                        (group-resolve-id (frame-local 'previous-group)))))
    (cond ((null? ids) #f)
          ((and (car ids) (not (buffer-in-group? buf (car ids))))
           (group-name (car ids)))
          (else (loop (cdr ids))))))

(define (group-visible-work-buffers)
  (dedupe-names
    (filter group-work-buffer?
      (map (lambda (window) (car (cdr window))) (window-list)))))

(define (group-create-and-enter! name buffers layout)
  (let ((clean (string-trim name)))
    (cond ((equal? clean "")
           (message "Group needs a name")
           #f)
          ((group-record-by-name clean)
           (message (string-append "Group " clean " already exists"))
           #f)
          (else
            (let ((id (group-record-create! clean)))
              (for-each (lambda (buf) (buffer-add-group! buf id)) buffers)
              (when layout (group-layout-set! id layout))
              (switch-to-group! id)
              id)))))

(define (group-read-new-name prompt receive)
  (minibuffer-read prompt (group-names)
    (lambda (input)
      (let ((name (string-trim input)))
        (cond ((equal? name "") (message "Group needs a name"))
              ((group-record-by-name name)
               (message (string-append "Group " name " already exists")))
              (else (receive name)))))))

(define-command "group-new" "Create and enter an empty group"
  (lambda ()
    (group-read-new-name "New group: "
      (lambda (name) (group-create-and-enter! name '() #f)))))

(define-command "group-new-from-buffer"
  "Create and enter a group that contains the current work buffer"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (not (group-work-buffer? buf))
          (message "The current buffer is not a work buffer")
          (group-read-new-name "New group from buffer: "
            (lambda (name) (group-create-and-enter! name (list buf) #f)))))))

(define-command "group-new-from-visible"
  "Create and enter a group that contains the visible work buffers"
  (lambda ()
    (let ((buffers (group-visible-work-buffers))
          (layout (window-tree)))
      (group-read-new-name "New group from visible buffers: "
        (lambda (name) (group-create-and-enter! name buffers layout))))))

(define (group-all-work-buffers)
  (filter group-work-buffer? (buffer-list)))

;;; --- one buffer prompt, in sections ------------------------------------------
;;; C-x b lists EVERY buffer. It does not scope, and it never hides one:
;;; a prompt you have to escape from is a prompt that lies about what it
;;; knows. The order carries the meaning instead — the current group's
;;; members come first under "in this group", everything else follows
;;; under "other buffers". A separator is a heading, not a choice: the
;;; selection steps over it and RET never confirms one.
;;;
;;; Three verbs on one candidate:
;;;   RET    go there; one window changes and nothing else moves
;;;   C-RET  enter that buffer's group, its saved layout and all
;;;   S-RET  bring that buffer HERE, into the current group
;;;
;;; Filtering keeps the sections: each one ranks inside itself, and a
;;; section whose rows all lose the filter drops its heading too.

;; HERE is always passed in, never read from current-buffer. While a
;; prompt is open current-buffer answers with the minibuffer's own text,
;; so a pool rebuilt mid-prompt would stop excluding the buffer you
;; started in, and that buffer would appear as a candidate for itself.
(define (group-switch-all-buffers-but here)
  (filter (lambda (b)
            (and (not (equal? b here))
                 (not (string-prefix? " " b))))
          (buffer-list-mru)))

(define (group-switch-separator label) (list label "" "separator"))

;; annotate the WHOLE pool once, then split it: the marginalia columns
;; line up across both sections, because they were measured over both
(define (group-switch-candidates id here)
  (let* ((all (group-switch-all-buffers-but here))
         (rows (annotate 'buffer all))
         (mine (filter (lambda (row)
                         (and id (buffer-in-group? (car row) id)))
                       rows))
         (others (filter (lambda (row)
                           (not (and id (buffer-in-group? (car row) id))))
                         rows)))
    (append
      (if (pair? mine)
          (cons (group-switch-separator "in this group") mine)
          '())
      (if (pair? others)
          (cons (group-switch-separator
                  (if (pair? mine) "other buffers" "all buffers"))
                others)
          '()))))

(define (group-switch-adopt! buf id)
  (cond ((not id) (message "No current group"))
        ((not (group-work-buffer? buf)) (message "Chats cannot be pulled"))
        (else
          (buffer-add-group! buf id)
          (switch-to-buffer! buf)
          (message (string-append "Pulled " buf " into " (group-name id))))))

(define (group-switch-confirm! buf id)
  (let ((context (let ((x *mb-confirm-context*))
                   (set! *mb-confirm-context* #f)
                   x))
        (adopt (let ((x *mb-confirm-adopt*))
                 (set! *mb-confirm-adopt* #f)
                 x)))
    (when (buffer-known? buf)
      (cond (adopt (group-switch-adopt! buf id))
            (context (buffer-context-switch! buf))
            (else (switch-to-buffer! buf))))))

(define-command "group-switch-to-buffer"
  "Switch to a buffer; C-RET enters its group, S-RET pulls it into this one"
  (lambda ()
    (set! *mb-confirm-context* #f)
    (set! *mb-confirm-adopt* #f)
    (let* ((here (current-buffer))
           (id (group-resolve-id (frame-local 'current-group)))
           (candidates (group-switch-candidates id here))
           (woken '())
           (sleep-woken!
             (lambda (keep)
               (for-each (lambda (buf)
                           (unless (equal? buf keep) (buffer-sleep! buf)))
                         woken)
               (set! woken '()))))
      (if (null? candidates)
          (message "No other buffer available")
          (minibuffer-read-preview "Switch buffer: " candidates
            (lambda (buf)
              (when (buffer-known? buf)
                (let ((sleeping (not (buffer-exists? buf))))
                  (window-preview-buffer! buf)
                  (when (and sleeping (buffer-exists? buf))
                    (restore-buffer-runtime! buf)
                    (set! woken (cons buf woken))))))
            (lambda (buf)
              (group-switch-confirm! buf id)
              (sleep-woken! buf))
            (lambda ()
              (set! *mb-confirm-context* #f)
              (set! *mb-confirm-adopt* #f)
              (when (buffer-known? here) (window-preview-buffer! here))
              (sleep-woken! #f))
            ;; The mode, group, and project match the input. The icon is
            ;; the first field, so the match hint covers four fields.
            4)))))

(define (group-pull-buffers! buffers value)
  (let ((id (group-resolve-id value))
        (changed 0)
        (unchanged 0)
        (skipped 0))
    (if (not id)
        (message "No current group")
        (begin
          (for-each
            (lambda (buf)
              (cond ((not (and (buffer-known? buf) (group-work-buffer? buf)))
                     (set! skipped (+ skipped 1)))
                    ((buffer-in-group? buf id)
                     (set! unchanged (+ unchanged 1)))
                    (else
                      (buffer-add-group! buf id)
                      (set! changed (+ changed 1)))))
            buffers)
          (message
            (string-append "Pulled " (number->string changed) " buffer"
                           (if (= changed 1) "" "s") " into "
                           (group-name id)
                           (if (= unchanged 0) ""
                               (string-append "; " (number->string unchanged)
                                              " already there"))
                           (if (= skipped 0) ""
                               (string-append "; skipped "
                                              (number->string skipped)))))
          changed))))

(define-command "group-pull-buffer"
  "Pull selected or marked live work buffers into the current group"
  (lambda ()
    (let ((id (frame-local 'current-group))
          (source (current-buffer)))
      (cond
        ((not (group-resolve-id id))
         (message "No current group"))
        ((equal? (buffer-local source 'mode-name) "switch-mode")
         (let ((buffers (group-command-work-buffers)))
           (if (null? buffers)
               (message "No work buffer selected")
               (group-pull-buffers! buffers id))))
        (else
          (minibuffer-read "Pull buffer here: "
            (annotate 'buffer (group-all-work-buffers))
            (lambda (buf)
              (if (not (group-work-buffer? buf))
                  (message "No work buffer selected")
                  (group-pull-buffers! (list buf) id)))))))))

(define (group-command-work-buffers)
  (let ((buf (current-buffer)))
    (filter group-work-buffer?
      (if (equal? (buffer-local buf 'mode-name) "switch-mode")
          (map car (list-targets buf))
          (list buf)))))

;; The prompt takes a typed name as well as a listed one, and a name it
;; does not know is a group to found — the same answer the "New group"
;; row gives. group-ensure-record! still refuses an id, so a dangling
;; membership cannot found a group named after itself.
(define (group-push-buffers-to! buffers destination)
  (let ((id (group-ensure-record! destination))
        (changed 0)
        (skipped 0))
    (if (not id)
        (message "No destination group")
        (begin
          (for-each
            (lambda (buf)
              (if (and (buffer-known? buf) (group-work-buffer? buf))
                  (begin
                    (buffer-add-group! buf id)
                    (set! changed (+ changed 1)))
                  (set! skipped (+ skipped 1))))
            buffers)
          (message
            (string-append "Pushed " (number->string changed) " buffer"
                           (if (= changed 1) "" "s") " to "
                           (group-name id)
                           (if (= skipped 0) ""
                               (string-append "; skipped "
                                              (number->string skipped)))))
          ;; a list that shows membership is now stale, and the marks that
          ;; chose these buffers are spent. The push happens under a
          ;; minibuffer callback, so no caller can refresh after it.
          (run-hooks 'group-membership-hook)
          changed))))

(define (group-push-read-destination! buffers)
  (minibuffer-read "Push buffers to group: "
    (cons (list "New group" "create without entering") (group-names))
    (lambda (destination)
      (if (equal? destination "New group")
          (group-read-new-name "New destination group: "
            (lambda (name)
              (let ((id (group-record-create! name)))
                (when id (group-push-buffers-to! buffers id)))))
          (group-push-buffers-to! buffers destination)))))

(define-command "group-push-buffer"
  "Push the current or marked work buffers to another group"
  (lambda ()
    (let ((buffers (group-command-work-buffers)))
      (if (null? buffers)
          (message "No work buffer selected")
          (group-push-read-destination! buffers)))))

(define (group-pop-replacement id popped)
  (let* ((popped-buffers (if (pair? popped) popped (list popped)))
         (work (filter (lambda (b)
                         (and (not (member b popped-buffers))
                              (group-work-buffer? b)))
                       (group-buffers-mru id))))
    (cond ((pair? work) (car work))
          ((group-primary-chat id) (group-primary-chat id))
          (else
            (unless (buffer-exists? "*scratch*") (buffer-create "*scratch*"))
            "*scratch*"))))

(define (group-pop-buffers! buffers value)
  (let* ((id (group-resolve-id value))
         (source (current-buffer))
         (switcher? (equal? (buffer-local source 'mode-name) "switch-mode"))
         (eligible
           (if id
               (filter (lambda (buf)
                         (and (buffer-known? buf)
                              (group-work-buffer? buf)
                              (buffer-in-group? buf id)))
                       buffers)
               '()))
         (skipped (- (length buffers) (length eligible))))
    (cond
      ((not id) (message "No current group"))
      ((null? eligible) (message "No current-group work buffer selected"))
      (else
        (when switcher? (switch-restore-home! source))
        (for-each (lambda (buf) (buffer-remove-group! buf id)) eligible)
        (if switcher?
            (let ((home (buffer-local source 'switch-here))
                  (window (switch-home-window source)))
              (for-each (lambda (buf) (list-unmark-key! source buf)) eligible)
              (when (and window (member home eligible))
                (window-preview-buffer!
                  (group-pop-replacement id eligible) window))
              (switch-close! source #f))
            (when (member source eligible)
              (switch-to-buffer! (group-pop-replacement id eligible))))
        (message
          (string-append "Popped " (number->string (length eligible))
                         " buffer" (if (= (length eligible) 1) "" "s")
                         " from " (group-name id)
                         (if (= skipped 0) ""
                             (string-append "; skipped "
                                            (number->string skipped)))))
        (length eligible)))))

(define (group-pop-buffer! buf id)
  (group-pop-buffers! (list buf) id))



(define-command "group-pop"
  "Pop the current or marked work buffers from the current group"
  (lambda ()
    (let ((id (frame-local 'current-group))
          (buffers (group-command-work-buffers)))
      (if (not (group-resolve-id id))
          (message "No current group")
          (group-pop-buffers! buffers id)))))

;; C-c g : join a group. RET takes the default — so a stray buffer
;; moves into the group you last stood in with one press. A typed
;; name joins that group, or founds it.
(define-command "group-join" "Join a group; RET takes the last visited group; a new name founds one"
  (lambda ()
    (let* ((buf (current-buffer))
           (default (group-join-default buf))
           (names (filter (lambda (g) (not (equal? g default))) (group-names))))
      (minibuffer-read
        (if default
            (string-append "Join group (default " (group-label default) "): ")
            "Join group: ")
        (if default
            (cons (list default "last visited") names)
            names)
        (lambda (input)
          (let ((g (if (equal? (string-trim input) "")
                       (or default "")
                       input)))
            (cond
              ((equal? g "") (message "Group needs a name"))
              ;; a group is a set — joining twice is a no-op that says so
              ((buffer-in-group? buf g)
               (message (string-append buf " is already in " (group-label g))))
              (else
                (buffer-add-group! buf g)
                (message (string-append buf " joined group " (group-label g)))))))))))

(define-command "group-remove" "Remove the current buffer from its group"
  (lambda ()
    (let* ((buf (current-buffer)) (g (buffer-group buf)))
      (if g
          (begin
            (buffer-remove-group! buf g)
            (message (string-append buf " left group " (group-display-name g))))
          (message "Not in a group")))))

(define-command "group-list" "List the current buffer's group members"
  (lambda ()
    (let ((g (buffer-group (current-buffer))))
      (if g
          (message (string-append (group-display-name g) ": "
                     (string-join (group-buffers-mru g) " · ")
                     (let ((m (group-meta g)))
                       (if m (string-append " — " m) ""))))
          (message "Not in a group")))))

;; make an existing conversation a group's chat: pick a buffer, join its
;; group (founding one named after it if it has none)
(define-command "chat-adopt" "Make this chat the companion of a chosen buffer"
  (lambda ()
    (let ((chat (current-buffer)))
      (minibuffer-read "Companion for buffer: "
        (filter (lambda (b) (not (equal? b chat))) (buffer-list-mru))
        (lambda (doc)
          (if (not (buffer-exists? doc))
              (message (string-append "No buffer " doc))
              (let ((g (group-ensure! doc)))
                ;; joining the group is the whole act; the layout is
                ;; group-chat-show!'s job, and it is the only place that
                ;; knows what a chat's two panes look like
                (chat-set-group! chat g)
                ;; the document takes this window first, so the layout
                ;; builder lands the chat beside it rather than on it
                (switch-to-buffer! doc)
                (group-chat-show! g)
                (message (string-append chat " now accompanies " (group-display-name g))))))))))

;; C-c w toggles sides: in a work buffer it opens (or refocuses) the group
;; chat, grouping the buffer by itself first if needed; in the chat it hops
;; to the group's most recent work buffer; in a groupless chat it adopts
(define-command "chat-companion" "Toggle between a work buffer and its group chat"
  (lambda ()
    (let* ((cur (current-buffer))
           (g (buffer-group cur)))
      (cond ((and (chat-buffer? cur) g)
             (let ((docs (group-docs g)))
               (if (null? docs)
                   (message (string-append "Group " (group-display-name g) " has no work buffers"))
                   (let ((w (window-showing (car docs))))
                     (if w
                         (select-window! w)
                         (switch-to-buffer! (car docs)))))))
            ((chat-buffer? cur) (run-command "chat-adopt"))
            (else (group-chat-show! (group-ensure! cur)))))))

;; C-c RET in a work buffer: talk to the group chat without leaving it.
;; (In a chat buffer it just sends, exactly like RET.)
(define-command "chat-companion-ask" "Ask the group chat without leaving this buffer"
  (lambda ()
    (let ((cur (current-buffer)))
      (if (chat-buffer? cur)
          (run-command "agent-send")
          (group-ask! (group-ensure! cur))))))


(mode-icon! "groups-mode" "")

(global-set-key "C-c g" "group-join")
(global-set-key "C-c d" "group-describe")
(global-set-key "C-x G" "groups")
(global-set-key "C-x b" "group-switch-to-buffer")
(global-set-key "C-x g" "group-switch")

(public! 'group-ids "(group-ids) -> durable opaque group IDs")
(public! 'group-name "(group-name ID) -> the current display name")
(public! 'buffer-group-ids "(buffer-group-ids NAME) -> work memberships")
(public! 'buffer-in-group? "(buffer-in-group? NAME ID) -> membership")
(public! 'group-record-create! "(group-record-create! NAME) -> new stable ID or #f")
(public! 'buffer-group "(buffer-group NAME) -> the buffer's group tag or #f")
(public! 'group-buffers "(group-buffers G) -> names of the buffers tagged 'group G")
(public! 'group-chat "(group-chat G) — find or create G's chat buffer; returns its name")
(public! 'group-chat-show! "(group-chat-show! G) — open/focus G's chat pane; returns its name")

(catalog-meta! 'command "group-describe" 'domain 'buffers 'effects '(write external spend))
(catalog-meta! 'command "group-describe-at-point" 'domain 'buffers 'effects '(write external spend))
(catalog-meta! 'command "group-kill" 'domain 'buffers 'effects '(destroy))
(catalog-meta! 'command "group-kill-at-point" 'domain 'buffers 'effects '(destroy))
(catalog-meta! 'command "groups" 'domain 'buffers 'effects '(read))
(catalog-meta! 'function "buffer-group" 'domain 'buffers 'effects '(read))
(catalog-meta! 'function "group-buffers" 'domain 'buffers 'effects '(read))
(catalog-meta! 'function "group-chat" 'domain 'buffers 'effects '(write))
(catalog-meta! 'function "group-chat-show!" 'domain 'buffers 'effects '(write))

(message "groups.scm loaded")
