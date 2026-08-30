;;; groups.scm --- Buffer groups, saved layouts, and companion chats.

;;;; A group is a durable context with a stable record and opaque ID.
;;;; Work buffers contain group ID sets and may name their role in each group.
;;;; Chats contain one owning group ID and always have the role "chat".
;;;; This package owns membership, switching, layouts, records, and chats.

(domain! 'buffers)
(effects! '(write))

;;; --- durable group records and buffer-local membership -------------------------
;;; Work buffers use 'group-ids plus 'group-roles. Chats use one 'group-id
;;; and one 'chat-id. —
;;; Old 'group and 'companion-of — locals migrate on the first membership read.
;;; Group records persist independently, including empty and chatless groups.
;;; (group-buffers g) derives live membership from buffer-local identity.





(define *group-records* '())
(define *group-next-id* 0)
(define *group-colors*
  '("#d05a47" "#3f7cac" "#4f8a5b" "#9b6ab3" "#c28a2c" "#347f7a"))

(defface! 'group-color-1 'fg "#d05a47" 'weight "700")
(defface! 'group-color-2 'fg "#3f7cac" 'weight "700")
(defface! 'group-color-3 'fg "#4f8a5b" 'weight "700")
(defface! 'group-color-4 'fg "#9b6ab3" 'weight "700")
(defface! 'group-color-5 'fg "#c28a2c" 'weight "700")
(defface! 'group-color-6 'fg "#347f7a" 'weight "700")

(define (group-record-id record) (nth 0 record))
(define (group-record-name record) (nth 1 record))
(define (group-record-meta record) (nth 2 record))
(define (group-record-layout record) (nth 3 record))
(define (group-record-noise record) (nth 4 record))
(define (group-record-primary-chat-id record) (nth 5 record))
(define (group-record-color record)
  (and (> (length record) 6) (nth 6 record)))

(define (group-color-face value)
  (let* ((record (and value
                      (or (group-record-by-id value)
                          (group-record-by-name value))))
         (color (if record (group-record-color record) value)))
    (cond ((equal? color "#d05a47") "group-color-1")
          ((equal? color "#3f7cac") "group-color-2")
          ((equal? color "#4f8a5b") "group-color-3")
          ((equal? color "#9b6ab3") "group-color-4")
          ((equal? color "#c28a2c") "group-color-5")
          ((equal? color "#347f7a") "group-color-6")
          (else "accent"))))

(define (buffer-color-group buf)
  (if (chat-buffer? buf)
      (chat-group-id buf)
      (let ((ids (buffer-group-ids buf)))
        (and (pair? ids) (car ids)))))

(define (buffer-filename-face buf)
  (let ((group (buffer-color-group buf)))
    (and group (group-color-face group))))

(define candidate-face-for-base
  (if (boundp 'candidate-face-for-base)
      candidate-face-for-base
      candidate-face-for))

(set! candidate-face-for
  (lambda (category name)
    (if (and (equal? category 'buffer) (buffer-known? name))
        (or (buffer-filename-face name)
            (candidate-face-for-base category name))
        (candidate-face-for-base category name))))

(define (group-next-color)
  (nth (modulo (- *group-next-id* 1) (length *group-colors*)) *group-colors*))

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

(define *group-pin-icon* "")

(define (group-pinned-in frame)
  (let* ((held (frame-local-in frame 'pinned-group))
         (id (group-resolve-id held)))
    id))

(define (group-pinned)
  (let* ((held (frame-local 'pinned-group))
         (id (group-resolve-id held)))
    (when (and held (not id)) (set-frame-local! 'pinned-group #f))
    id))

(define (group-pinned? g)
  (let ((id (group-resolve-id g)))
    (and id (equal? id (group-pinned)))))

(define (group-display-name g)
  (or (group-name g) (and (string? g) g) ""))

(define (group-display-label-in g frame)
  (let ((name (group-display-name g)))
    (if (and (not (equal? name ""))
             (equal? (group-resolve-id g) (group-pinned-in frame)))
        (string-append name " " *group-pin-icon*)
        name)))

(define (group-display-label g)
  (group-display-label-in g (selected-frame)))

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
                   (record (list id clean #f #f "quiet" #f (group-next-color))))
              (set! *group-records* (append *group-records* (list record)))
              (desktop-dirty!)
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
                          (group-record-primary-chat-id record))
                      (if (equal? field 'color) new-value
                          (group-record-color record)))))
          *group-records*))
      (desktop-dirty!)
      (when (member field '(name color))
        (group-frame-styles-refresh!)
        (modeline-groups-refresh!)))))

(define (group-record-delete! value)
  (let ((id (group-resolve-id value)))
    (when id
      (group-frame-context-remove-id! id)
      (set! *group-records*
        (remove (lambda (record) (equal? (group-record-id record) id))
                *group-records*))
      (desktop-dirty!)
      (modeline-groups-refresh!))))

(define (group-record-colors-restore records)
  (let loop ((rest records) (index 0) (out '()))
    (if (null? rest)
        (reverse out)
        (let* ((record (car rest))
               (color (or (group-record-color record)
                          (nth (modulo index (length *group-colors*))
                               *group-colors*))))
          (loop (cdr rest) (+ index 1)
                (cons (append (take-n record 6) (list color)) out))))))

(define (group-state-restore! saved)
  (when (and (pair? saved) (pair? (cdr saved)))
    (set! *group-next-id* (car saved))
    (set! *group-records* (group-record-colors-restore (car (cdr saved))))
    (modeline-groups-refresh!)))

(define *group-frame-context-keys* '(current-group previous-group pinned-group))

(define (group-frame-style-set! frame value)
  (let* ((id (group-resolve-id value))
         (record (and id (group-record-by-id id))))
    (set-frame-group-style!
      (and record (group-display-label-in id frame))
      (and record (group-record-color record))
      frame)))

(define (group-frame-styles-refresh!)
  (for-each
    (lambda (frame)
      (group-frame-style-set! frame (frame-local-in frame 'current-group)))
    (frame-list)))

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
                 (pinned (and (pair? locals)
                              (group-frame-context-id locals 'pinned-group)))
                 (saved (append
                          (if current (list (list 'current-group current)) '())
                          (if previous (list (list 'previous-group previous)) '())
                          (if pinned (list (list 'pinned-group pinned)) '()))))
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
                 (pinned (assoc 'pinned-group pairs))
                 (restored
                   (append
                     (if (and current (string? (car (cdr current))))
                         (list (list 'current-group (car (cdr current))))
                         '())
                     (if (and previous (string? (car (cdr previous))))
                         (list (list 'previous-group (car (cdr previous))))
                         '())
                     (if (and pinned (string? (car (cdr pinned))))
                         (list (list 'pinned-group (car (cdr pinned))))
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
            (group-frame-style-set! frame (and kv (car (cdr kv)))))))
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

;; persist-global! restores the most recently registered entry first. Group
;; frame contexts resolve their IDs through the record table, so register the
;; records after the contexts and restore them before the contexts.
(persist-global! 'groups-v2
  (lambda () (list *group-next-id* *group-records*))
  group-state-restore!)

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
                    (buffer-set-local! b 'group-inherited #f)
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
                     (if id (list (group-display-label id)) '()))
                   (map group-display-label (buffer-group-ids b)))))
    (let ((known (filter string? names)))
      (if (pair? known) (string-join known ", ") "ungrouped"))))

;; Names and the primary membership color are cached for the render path.
;; The compact label is frame-relative. The color always belongs to the buffer.
(define (buffer-modeline-group-refresh! b)
  (let ((names (if (chat-buffer? b)
                   (let ((id (chat-group-id b)))
                     (if id (list (group-name id)) '()))
                   (map group-name (buffer-group-ids b)))))
    (let* ((known (filter string? names))
           (group (buffer-color-group b))
           (record (and group (group-record-by-id group)))
           (color (and record (group-record-color record))))
      (unless (equal? (buffer-local b 'modeline-groups) known)
        (buffer-set-local! b 'modeline-groups known))
      (unless (equal? (buffer-local b 'modeline-group-color) color)
        (buffer-set-local! b 'modeline-group-color color))
      known)))

(define (modeline-groups-refresh!)
  (for-each buffer-modeline-group-refresh! (buffer-list))
  #t)

;; Install derived color locals for buffers that predate this package reload.
(modeline-groups-refresh!)

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
    ;; A chat has ownership, not ordinary work-buffer memberships. Remove
    ;; any creation-time membership before the chat mode declared its type.
    (buffer-set-local! b 'group-ids '())
    (buffer-set-local! b 'group-roles '())
    (buffer-set-local! b 'group #f)
    (buffer-set-local! b 'companion-of #f)
    (buffer-modeline-group-refresh! b)
    (when (boundp 'group-current-recalculate!)
      (group-current-recalculate!))
    id))

;; A role belongs to the membership, not globally to the buffer: one buffer
;; can be `source` in one group and `reference` in another. Strings are kept
;; in the local so desktop files are readable; callers may use symbols.
(define (group-role-name role)
  (cond ((string? role) role)
        ((symbol? role) (symbol->string role))
        (else #f)))

(define (buffer-group-role b value)
  (let ((id (group-resolve-id value)))
    (cond ((not id) #f)
          ((chat-buffer? b)
           (and (equal? (chat-group-id b) id) "chat"))
          (else
            (let ((entry (assoc id (or (buffer-local b 'group-roles) '()))))
              (and entry (car (cdr entry))))))))

(define (buffer-set-group-role! b value role)
  (let ((id (group-resolve-id value))
        (name (group-role-name role)))
    (cond ((or (not id) (not name)) #f)
          ;; A chat's relationship is ownership rather than ordinary work
          ;; membership, but semantically it is always the group's chat.
          ((chat-buffer? b)
           (and (equal? (chat-group-id b) id) "chat"))
          ((not (buffer-in-group? b id)) #f)
          (else
            (let ((others
                    (remove (lambda (entry) (equal? (car entry) id))
                            (or (buffer-local b 'group-roles) '()))))
              (buffer-set-local! b 'group-roles
                (append others (list (list id name))))
              name)))))

(define (buffer-add-group! b value)
  (let ((id (group-ensure-record! value)))
    (cond ((not id) #f)
          ((chat-buffer? b) #f)
          ;; already a member, but asking for it is still a declaration:
          ;; the membership stops being one the buffer merely inherited
          ((buffer-in-group? b id)
           (buffer-set-local! b 'group-inherited #f)
           (buffer-modeline-group-refresh! b)
           id)
          (else
            (buffer-set-local! b 'group-ids
              (append (buffer-group-ids b) (list id)))
            (buffer-set-local! b 'group #f)
            (buffer-set-local! b 'group-inherited #f)
            (buffer-set-local! b 'companion-of #f)
            (buffer-modeline-group-refresh! b)
            (when (boundp 'group-current-recalculate!)
              (group-current-recalculate!))
            id))))

(define (buffer-add-group-as! b value role)
  (let ((id (buffer-add-group! b value)))
    (and id (buffer-set-group-role! b id role) id)))

(define (buffer-move-to-group! b value)
  (let ((id (and value (group-ensure-record! value))))
    (if (chat-buffer? b)
        (chat-set-group! b id)
        (begin
          (buffer-set-local! b 'group-ids (if id (list id) '()))
          (buffer-set-local! b 'group-roles '())
          (buffer-set-local! b 'group #f)
          (buffer-set-local! b 'group-inherited #f)
          (buffer-set-local! b 'companion-of #f)
          (buffer-modeline-group-refresh! b)))
    (when (boundp 'group-current-recalculate!)
      (group-current-recalculate!))
    id))

(define (buffer-remove-group! b value)
  (let ((id (group-resolve-id value)))
    (when id
      (if (chat-buffer? b)
          (when (equal? (chat-group-id b) id)
            (buffer-set-local! b 'group-id #f))
          (begin
            (buffer-set-local! b 'group-ids
              (remove (lambda (x) (equal? x id)) (buffer-group-ids b)))
            (buffer-set-local! b 'group-roles
              (remove (lambda (entry) (equal? (car entry) id))
                      (or (buffer-local b 'group-roles) '())))))
      (buffer-modeline-group-refresh! b))
    (when (boundp 'group-current-recalculate!)
      (group-current-recalculate!))))

(define (buffer-replace-group! b old new)
  (let ((old-id (group-resolve-id old))
        (new-id (group-ensure-record! new))
        (role (buffer-group-role b old)))
    (when (and old-id new-id (buffer-in-group? b old-id))
      (if role
          (buffer-add-group-as! b new-id role)
          (buffer-add-group! b new-id))
      (buffer-remove-group! b old-id))))

;; the group column in a buffer prompt. A group founded by a file buffer
;; carries the full path as its name; show the last segment.
;;
;; Every prompt and message names a group the way a person named it. The
;; opaque ID belongs to the code and must never reach the screen. A caller
;; can hold an ID whose record is gone, so fall back to what it passed.
;; The short name a card wears. A project root is not a group yet, so it
;; keeps its own basename rather than going blank.
(define (group-label g)
  (let ((name (group-display-name g)))
    (if (equal? name "")
        ""
        (let ((short (car (reverse (string-split name "/")))))
          (if (group-pinned? g)
              (string-append short " " *group-pin-icon*)
              short)))))


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
                 ((and (equal? (group-resolve-id
                                 (buffer-local (car buffers) 'group-id))
                               id)
                       (equal? (buffer-local (car buffers) 'chat-id)
                               primary))
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

;; A saved layout names its buffers, because a name IS the buffer handle
;; here. Membership escapes renames by riding the buffer ('group-ids), but
;; a layout points the other way: the group holds it, so the group must
;; hear the rename. rename-buffer! already tells every owner of name-keyed
;; state; this makes the group records one of them.
(define (group-layout-rename layout old new)
  (cond ((not layout) layout)
        ((and (pair? layout) (equal? (car layout) 'per-frame))
         (cons 'per-frame
               (map (lambda (entry)
                      (list (car entry)
                            (window-tree-rename (car (cdr entry)) old new)))
                    (cdr layout))))
        (else (window-tree-rename layout old new))))

(on-buffer-renamed!
  (lambda (old new)
    (for-each
      (lambda (record)
        (let ((layout (group-record-layout record)))
          (when layout
            (group-record-update! (group-record-id record) 'layout
              (group-layout-rename layout old new)))))
      *group-records*)))





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
         (chat (if (pair? docs) (group-primary-chat g) (group-chat g)))
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


(define (group-restore-sanitize! g)
  (let* ((id (group-resolve-id g))
         (members (group-buffers-mru id))
         (pool (if (pair? members) members (list (group-chat id))))
         (shown
           (filter (lambda (buf) (buffer-in-group? buf id))
                   (map cadr (window-list)))))
    (for-each
      (lambda (window)
        (let ((win (car window))
              (buf (cadr window)))
          (unless (buffer-in-group? buf id)
            (let ((hidden
                    (filter (lambda (candidate)
                              (not (member candidate shown)))
                            pool)))
              (cond ((pair? hidden)
                     (window-set-buffer! win (car hidden))
                     (set! shown (cons (car hidden) shown)))
                    ((> (length (window-list)) 1)
                     (delete-window-id! win))
                    (else
                     (window-set-buffer! win (car pool))))))))
      (window-list))))

;; Scheme owns both sides of the modeline's group context: the frame's current
;; group name and every buffer's membership names. The renderer only compacts
;; those facts for the width available in the bar.
(define (frame-group-label-refresh!)
  (group-frame-style-set! (selected-frame) (frame-local 'current-group))
  (modeline-groups-refresh!))

;; a reattached frame keeps its group in *frame-locals*, but the Elixir
;; frame behind it is new and its label is empty — so push it on attach
(add-hook! 'frame-attach-hook frame-group-label-refresh!)

;;; --- scenes: a declared group arrangement -------------------------------------
;;; A scene is a DECLARATION, not a script: the group, the arrangement, and
;;; how to build each pane, as data.
;;;
;;;   (define-scene! "mail"
;;;     '(h 0.32 (as index (ensure "*notmuch*" "notmuch-index"))
;;;              (as show (ensure "*notmuch-show*" "notmuch-preview"))
;;;              (as chat group-chat)))
;;;
;;; Running it always gives the same frame, in the same group. Run it twice
;;; and nothing moves; kill any pane's buffer and the next run builds it
;;; back. That is the whole contract, and it is why a scene declares its
;;; panes with `ensure` — a name plus the command that makes it.
;;;
;;; The spec is the mode-layout grammar (DIR RATIO PANE ...), plus `(as ROLE
;;; PANE)`: a semantic, group-relative name for that pane. `group-chat` is
;;; the group's own chat, made if it does not exist.
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
(define (scene--as? pane)
  (and (pair? pane) (equal? (car pane) 'as)
       (pair? (cdr pane)) (pair? (cdr (cdr pane)))))

(define (scene--role pane)
  (and (scene--as? pane) (group-role-name (car (cdr pane)))))

(define (scene--declared-pane pane)
  (if (scene--as? pane) (car (cdr (cdr pane))) pane))

(define (scene--pane id pane)
  (let ((pane (scene--declared-pane pane)))
    (if (equal? pane 'group-chat)
        (or (group-chat id) "")
        pane)))

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
            ;; `as` is a role on this buffer's membership in this group.
            ;; Bind after the layout has materialised every ensure pane.
            (for-each
              (lambda (declared)
                (let* ((role (scene--role declared))
                       (pane (scene--pane id declared))
                       (buf (and role (layout--pane anchor pane))))
                  (when buf
                    (if (chat-buffer? buf)
                        (chat-set-group! buf id)
                        (buffer-add-group-as! buf id role)))))
              (cdr (cdr spec)))
            (mru-note-group! id)
            (windows-shown-catchup!)
            panes)))))

(define-command "scene" "Open a declared scene: its group, its arrangement"
  (lambda ()
    (let ((names (scene-names)))
      (if (null? names)
          (message "No scenes declared")
          (minibuffer-read "Scene: " names scene-open!)))))

(public! 'define-scene! "(define-scene! NAME SPEC) — declare a group's arrangement; write each pane as (as ROLE PANE), where PANE is \"NAME\", (ensure \"NAME\" \"COMMAND\"), or group-chat")
(public! 'scene-open! "(scene-open! NAME) — stand in the scene's group and build its arrangement, making any missing pane")

;; A layout names buffers, and a member killed since it was saved is a
;; name with nothing behind it. The window restore makes a buffer for
;; every name it finds, so a killed file came back as an empty buffer
;; carrying the path of a file that still holds its text. Visit the file
;; first: the same rule the desktop restore keeps.
(define (group-revive-layout-files! saved)
  (for-each (lambda (b)
              (when (and (not (buffer-known? b)) (file-exists? b))
                (visit b)))
            (window-tree-buffers saved)))

(define *group-current-inhibit* #f)

(define (switch-to-group! g)
  (let ((id (begin (group-migrate-live!) (group-resolve-id g))))
    (if (not id)
        (message "No such group")
        (begin
          (winner-save!)
          (set! *winner-inhibit* #t)
          (set! *group-current-inhibit* #t)
          (let ((from (frame-group)))
            (when (and from (not (equal? from id)))
              (group-layout-save-if-shown! from)
              (set-frame-local! 'previous-group from)))
          (set-frame-local! 'current-group id)
          ;; An explicit switch moves an active pin. The frame stays pinned,
          ;; but it does not trap the user in the old group.
          (when (group-pinned) (set-frame-local! 'pinned-group id))
          (frame-group-label-refresh!)
          (let ((saved (group-layout id)))
            (if saved
                (begin
                  (group-revive-layout-files! saved)
                  (window-tree-set! saved)
                  (group-restore-sanitize! id)
                  (group-layout-save! id))
                (begin
                  (group-default-layout! id)
                  (group-layout-save! id))))
          (set! *group-current-inhibit* #f)
          (set! *winner-inhibit* #f)
          (group-current-recalculate!)
          (mru-note-group! id)
          (windows-shown-catchup!)
          (message (string-append "Switched to group " (group-name id)))))))

;; The visible frame derives its current group. The stored frame-local is the
;; last calculated answer, not an independent standing context.
(define (frame-group)
  (let* ((current (frame-local 'current-group))
         (resolved (group-resolve-id current)))
    (cond (resolved
           (unless (equal? current resolved)
             (set-frame-local! 'current-group resolved))
           resolved)
          (else
            (when current (set-frame-local! 'current-group #f))
            #f))))

(define (group-context-memberships buf)
  (cond ((chat-buffer? buf)
         (let ((id (chat-group-id buf))) (if id (list id) '())))
        ((buffer-local buf 'transient) #f)
        ((group-work-buffer? buf) (buffer-group-ids buf))
        (else #f)))

(define (group-visible-membership-rows)
  (filter (lambda (ids) ids)
          (map (lambda (window)
                 (group-context-memberships (car (cdr window))))
               (window-list))))

(define (group-common-memberships rows)
  (if (null? rows)
      #f
      (fold (lambda (common ids)
              (filter (lambda (id) (member id ids)) common))
            (car rows)
            (cdr rows))))

(define (group-current-choice common current)
  (cond ((not common) current)
        ((null? common) #f)
        ((and current (member current common)) current)
        (else
          (let ((recent (filter (lambda (id) (member id common))
                                (group-ids-mru))))
            (if (pair? recent) (car recent) (car common))))))

(define (group-current-recalculate!)
  (unless *group-current-inhibit*
    (let* ((pinned (group-pinned))
           (rows (group-visible-membership-rows))
           (current (frame-group))
           (next (if pinned
                     pinned
                     (group-current-choice (group-common-memberships rows) current))))
      (unless (equal? next current)
        (set-frame-local! 'current-group next)
        (frame-group-label-refresh!))
      next)))

(set! window-state-changed! group-current-recalculate!)

(define-command "group-pin"
  "Toggle a frame pin that keeps the current group through window changes"
  (lambda ()
    (let ((pinned (group-pinned)))
      (if pinned
          (let ((name (group-name pinned)))
            (set-frame-local! 'pinned-group #f)
            (desktop-dirty!)
            (group-current-recalculate!)
            (frame-group-label-refresh!)
            (message (string-append "Unpinned group " name)))
          (let ((id (or (frame-group) (buffer-group (current-buffer)))))
            (if (not id)
                (message "No group to pin")
                (begin
                  (set-frame-local! 'pinned-group id)
                  (set-frame-local! 'current-group id)
                  (desktop-dirty!)
                  (frame-group-label-refresh!)
                  (message (string-append "Pinned group " (group-name id))))))))))

;; Creation is the shared placement boundary. Commands do not each need to
;; remember this rule, and waking a dormant buffer does not run the hook.
;; A new buffer joins the group the frame is in. That membership is
;; INHERITED: nobody asked for it, and a board or a listing sheds it
;; before it covers the group's pane. A membership a package asks for is
;; not inherited, and every explicit path below clears the mark.
(on-buffer-created!
  (lambda (buf)
    (let ((group (frame-group)))
      (when (and group (group-work-buffer? buf))
        (buffer-add-group! buf group)
        (buffer-set-local! buf 'group-inherited group)))))

;; a layout snapshot is only true when the group is on screen: saving
;; a scratch detour AS the group's arrangement would overwrite the
;; real one


;; a group's layout is captured only from INSIDE the group: the
;; buffer you act from is a member. What happens on any other surface
;; — the board, a listing, a detour — never rewrites it, so the last
;; arrangement made IN the group is the one that comes back.
(define (group-visible-homogeneous? g)
  (let ((id (group-resolve-id g))
        (pinned (group-pinned)))
    (and id
         (equal? (frame-group) id)
         ;; A pin preserves context, not homogeneity. Do not save a layout
         ;; that contains foreign work merely because the frame is pinned.
         (or (not pinned)
             (let ((common (group-common-memberships
                             (group-visible-membership-rows))))
               (and common (member id common)))))))

(define (group-layout-save-if-shown! g)
  (when (and (group-visible-homogeneous? g) (group-uncovered? g))
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
    ;; Creation runs before a board declares itself transient. Remove the
    ;; membership creation handed it, and only that one: doppler, sentry
    ;; and browse each name their own group, and a board that sheds a
    ;; declared membership leaves those buffers in no group at all.
    (when (buffer-local name 'transient)
      (let ((inherited (buffer-local name 'group-inherited)))
        (when inherited
          (for-each (lambda (group)
                      (when (equal? group (group-resolve-id inherited))
                        (buffer-remove-group! name group)))
                    (buffer-group-ids name)))))
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
          (list (group-label g) (group-color-face g))
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

;; Group navigation uses the same recency stream as buffer navigation.
;; Groups without a history entry trail in record order.
(define (group-ids-mru)
  (let loop ((rows (mru-list)) (found '()))
    (if (null? rows)
        (let ((recent (reverse found)))
          (append recent
                  (filter (lambda (id) (not (member id recent)))
                          (group-ids))))
        (let* ((row (car rows))
               (id (and (equal? (car row) "group")
                        (group-resolve-id (car (cdr row))))))
          (loop (cdr rows)
                (if (and id (not (member id found)))
                    (cons id found)
                    found))))))

;; The active groups: every group with an open buffer, in the order the
;; MRU gives (most recent first, then creation order). Derived from the
;; buffers on every call and never stored: the buffer list already knows
;; every open buffer, and each buffer knows its groups. The MRU only
;; orders the answer; it truncates, so it never decides membership.
(define (active-groups)
  (let ((open (fold (lambda (out b)
                      (fold (lambda (out id) (if (member id out) out (cons id out)))
                            out
                            (if (buffer-known? b) (buffer-group-ids b) '())))
                    '()
                    (buffer-list))))
    (filter (lambda (id) (member id open)) (group-ids-mru))))

(public! 'active-groups
  "(active-groups) — every group with an open buffer, most recent first")

(define (group-buffer-memberships buf)
  (if (chat-buffer? buf)
      (let ((id (chat-group-id buf))) (if id (list id) '()))
      (buffer-group-ids buf)))

;; A homogeneous frame already shows the group where the user stands.
;; In a mixed frame, put the selected foreign buffer's groups before the
;; remaining MRU groups so one RET enters its context.
(define (group-switch-candidate-ids)
  (let* ((current (frame-group))
         (recent (filter (lambda (id) (not (equal? id current)))
                         (group-ids-mru)))
         (mine (group-buffer-memberships (current-buffer))))
    (if (group-visible-homogeneous? current)
        recent
        (append (filter (lambda (id) (member id mine)) recent)
                (filter (lambda (id) (not (member id mine))) recent)))))

(define (group-switch-new-action)
  (let ((buf (current-buffer))
        (current (frame-group)))
    (cond ((not (group-work-buffer? buf))
           (list "Start an empty group" #f #f))
          ((and current (buffer-in-group? buf current))
           (list "Move this buffer into a new group" buf current))
          (else
            (list "Start a new group with this buffer" buf #f)))))

;; The members of every group in one pass: ((ID BUF ...) ...). Members
;; come in MRU order, and the buffers never visited this session trail,
;; the order group-buffers-mru gives. The switcher lists every group at
;; once, and one scan of every buffer per group cost the prompt 1.7s at
;; 25 groups and 80 buffers.
(define (group-members-index)
  (let loop ((bufs (dedupe-names (append (buffer-list-mru) (buffer-list))))
             (index '()))
    (if (null? bufs)
        (map (lambda (cell) (cons (car cell) (reverse (cdr cell)))) index)
        (loop (cdr bufs)
              (let add ((ids (group-buffer-memberships (car bufs)))
                        (index index))
                (if (null? ids)
                    index
                    (add (cdr ids)
                         (group-members-index-push index (car ids) (car bufs)))))))))

(define (group-members-index-push index id buf)
  (let ((cell (assoc id index)))
    (if cell
        (cons (cons id (cons buf (cdr cell)))
              (remove (lambda (c) (equal? (car c) id)) index))
        (cons (list id buf) index))))

(define (group-members-in index g)
  (let ((cell (assoc (group-resolve-id g) index)))
    (if cell (cdr cell) '())))

(define (group-switch-candidate-in index g)
  (let ((names (map buffer-modeline-name (group-members-in index g))))
    (list (group-name g)
          (if (pair? names) (string-join names " · ") "no buffers"))))

(define (group-switch-candidate g)
  (group-switch-candidate-in (group-members-index) g))

(define (switch-to-group-candidates)
  (let* ((current (frame-group))
         (recent (filter (lambda (id) (not (equal? id current)))
                         (group-ids-mru)))
         (mine (group-buffer-memberships (current-buffer)))
         (mine-recent (filter (lambda (id) (member id mine)) recent))
         (others (filter (lambda (id) (not (member id mine))) recent))
         (action (group-switch-new-action))
         (action-row (list (car action) "new context"))
         (index (group-members-index))
         (candidate (lambda (g) (group-switch-candidate-in index g))))
    (if (group-visible-homogeneous? current)
        (append (map candidate recent) (list action-row))
        (append (map candidate mine-recent)
                (list action-row)
                (map candidate others)))))

(define (group-switch-run-new-action! action)
  (let ((label (car action))
        (buf (car (cdr action)))
        (source (car (cdr (cdr action)))))
    (group-read-new-name (string-append label ": ")
      (lambda (name)
        (if buf
            (group-create-with-buffer! name buf source)
            (group-create-and-enter! name '() #f))))))

;; What the highlight shows while you move through the groups: the
;; group's most recent member, in the window the prompt came from. The
;; look uses window-preview-buffer!, so the MRU ring does not move and a
;; cancel leaves the history as it was. A dormant member wakes for the
;; look, and sleeps again when the prompt closes; buffer-sleep! refuses a
;; buffer that is on screen, so the group you actually enter stays awake.
(define (group-peek-buffer-in index g)
  (let loop ((members (group-members-in index g)))
    (cond ((null? members) #f)
          ;; the work, not a companion: the group's chat and a scratch
          ;; that belongs to a buffer are not where the work is
          ((and (group-work-buffer? (car members))
                (not (buffer-local (car members) 'scratch-owner)))
           (car members))
          (else (loop (cdr members))))))

;; One index per prompt: group-buffers-mru scans every buffer twice per
;; group, and the highlight moved one group per key.
(define (group-peek-buffer g)
  (group-peek-buffer-in (group-members-index) g))

(define-command "switch-to-group" "Switch to a group and restore its layout"
  (lambda ()
    (if (equal? (list-mode-of (current-buffer)) "groups-mode")
        (let ((g (groups--current)))
          (when g (switch-to-group! g)))
        (let* ((action (group-switch-new-action))
               (candidates (switch-to-group-candidates))
               (index (group-members-index))
               (here (current-buffer))
               ;; #f once the prompt closed: a look that was still
               ;; waiting must not draw after it
               (open #t)
               (woken '())
               (show-here!
                 (lambda ()
                   (when (buffer-known? here) (window-preview-buffer! here))))
               (sleep-woken!
                 (lambda ()
                   (for-each (lambda (buf) (buffer-sleep! buf)) woken)
                   (set! woken '())))
               (peek-now!
                 (lambda (name)
                   (when open
                   (let ((buf (group-peek-buffer-in index (string-trim name))))
                     (if (and buf (buffer-known? buf))
                         (let ((sleeping (not (buffer-exists? buf))))
                           (window-preview-buffer! buf)
                           (when (and sleeping (buffer-exists? buf))
                             (restore-buffer-runtime! buf)
                             (set! woken (cons buf woken))))
                         ;; the new-context row previews nothing: it names
                         ;; no group yet, so the window shows what it showed
                         (show-here!))))))
               ;; a look per highlight that RESTS: C-n held down moves the
               ;; highlight faster than a window draws, and each look is a
               ;; draw (and a wake, for a dormant member)
               (peek!
                 (lambda (name)
                   (debounce! "group-switch-peek" group-switch-peek-ms peek-now! name))))
          (if (null? candidates)
              (message "No groups")
              (minibuffer-read-preview "Switch group: " candidates
                peek!
                (lambda (name)
                  (set! open #f)
                  ;; the switch saves the layout you leave, so put the
                  ;; window back before it looks: a peek is not the
                  ;; arrangement you were working in
                  (show-here!)
                  (let ((id (group-resolve-id (string-trim name))))
                    (cond (id (switch-to-group! id))
                          ((equal? name (car action))
                           (group-switch-run-new-action! action))
                          (else (message "No such group"))))
                  (sleep-woken!))
                (lambda ()
                  (set! open #f)
                  (show-here!)
                  (sleep-woken!))))))))

(defcustom 'group-switch-peek-ms 120
  "How long the highlight rests on a group before the switcher previews it, in milliseconds."
  'group 'groups 'type 'number)

;; Compatibility name for existing configuration.
(define-command "group-switch" "Switch to a group and restore its layout"
  (lambda () (run-command "switch-to-group")))

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
         (survivors '())
         (stood (and id (equal? (frame-local 'current-group) id)))
         (tomb (and id (group-tombstone id members))))
    ;; The frame leaves the group before its members die. The kill
    ;; repair fills a window from the frame's current group; a frame
    ;; still standing in the dying group got the group's chat, a buffer
    ;; made for a group with seconds to live. Out of the group, the
    ;; window falls to the next buffer, as any kill does.
    (when stood (set-frame-local! 'current-group #f))
    (set! *group-dying* id)
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
    (set! *group-dying* #f)
    (begin
      (when id (group-record-delete! id))
      (group-bury! tomb)
      (frame-group-label-refresh!)
      (message
        (if (pair? survivors)
            (string-append "Killed group " name ". Kept "
                           (number->string (length survivors)) " buffers")
            (string-append "Killed group " name)))
      ;; what the hook handlers may ask about the kill that just happened
      (set! *group-killed* (list id name stood))
      (run-hooks 'group-kill-hook))))

;; the last kill: (ID NAME STOOD?), for group-kill-hook handlers. STOOD?
;; says whether the selected frame stood in the killed group.
(define *group-killed* #f)

(defgroup 'groups "Work contexts: groups of buffers and their layouts.")

(defcustom 'group-after-kill "follow"
  "After you kill the group you stand in: \"follow\" enters the group of the buffer the window fell to, with that group's layout; \"stay\" shows the buffer and no group."
  'group 'groups 'type 'string)

;; The kill left the window on the next buffer. The frame follows that
;; buffer into its group: the next context, not a lone buffer. A buffer
;; in no group leaves the frame in no group, showing that buffer.
(define (group-kill-follow!)
  (let ((killed *group-killed*))
    ;; one kill, one follow: a reload registers the handler again
    (set! *group-killed* #f)
    (when (and killed (caddr killed) (equal? group-after-kill "follow"))
      (let* ((ids (group-buffer-memberships (current-buffer)))
             (recent (filter (lambda (g) (member g ids)) (group-ids-mru)))
             (next (and (pair? recent) (car recent))))
        (when next
          (switch-to-group! next)
          (message (string-append "Killed group " (cadr killed) ". Now in "
                                  (or (group-name next) ""))))))))

(add-hook! 'group-kill-hook group-kill-follow!)

;;; --- the graveyard: killed groups a person can revive ------------------------
;;; A kill buries what the record knew and what the members were: the
;;; name, the meta, the layout, the noise, the chat id, the color, and
;;; each member's name and file. Revive makes the record again and brings
;;; back every member it can: a buffer that still exists joins; a file
;;; that still exists is visited; a member with neither is missing, and
;;; the revival says how many. The graveyard keeps the last twenty and
;;; persists with the desktop.

(define *group-graveyard* '())
(define *group-graveyard-depth* 20)

;; (NAME META LAYOUT NOISE CHAT-ID COLOR KILLED-AT ((BUFFER PATH) ...))
(define (group-tombstone id members)
  (let ((record (group-record-by-id id)))
    (and record
         (list (group-record-name record)
               (group-record-meta record)
               (group-record-layout record)
               (group-record-noise record)
               (group-record-primary-chat-id record)
               (group-record-color record)
               (current-time)
               (map (lambda (b) (list b (buffer-path b))) members)))))

(define (group-bury! tomb)
  (when tomb
    (set! *group-graveyard*
      (take-n (cons tomb
                    (remove (lambda (t) (equal? (car t) (car tomb))) *group-graveyard*))
              *group-graveyard-depth*))
    (desktop-dirty!)))

(define (group-tombstone-members tomb) (nth 7 tomb))

;; every member the tombstone names that can come back: a known buffer,
;; or a file that still exists
(define (group-revive-member! id m)
  (let ((b (car m)) (path (car (cdr m))))
    (cond ((buffer-known? b) (buffer-add-group! b id) #t)
          ((and (string? path) (file-exists? path)) (visit path id) #t)
          (else #f))))

(define (group-revive! name)
  (let ((tomb (assoc name *group-graveyard*)))
    (cond ((not tomb) (message (string-append "No killed group named " name)) #f)
          ((group-record-by-name name)
           (message (string-append "A group named " name " is open")) #f)
          (else
            (set! *group-graveyard*
              (remove (lambda (t) (equal? (car t) name)) *group-graveyard*))
            (let ((id (group-record-create! name)))
              (group-record-update! id 'meta (nth 1 tomb))
              (group-record-update! id 'layout (nth 2 tomb))
              (group-record-update! id 'noise (or (nth 3 tomb) "quiet"))
              (group-record-update! id 'primary-chat-id (nth 4 tomb))
              (when (nth 5 tomb) (group-record-update! id 'color (nth 5 tomb)))
              (let* ((members (group-tombstone-members tomb))
                     (back (filter (lambda (m) (group-revive-member! id m)) members))
                     (missing (- (length members) (length back))))
                (desktop-dirty!)
                (switch-to-group! id)
                (message
                  (string-append "Revived group " name ": "
                                 (number->string (length back)) " members back"
                                 (if (> missing 0)
                                     (string-append ", " (number->string missing) " missing")
                                     "")))
                id))))))

(define (group-graveyard-candidates)
  (map (lambda (tomb)
         (list (car tomb)
               (let ((names (map car (group-tombstone-members tomb))))
                 (if (pair? names) (string-join names " · ") "no members"))))
       *group-graveyard*))

(define-command "group-revive"
  "Revive a killed group: its record, layout, and every member that still exists"
  (lambda ()
    (if (null? *group-graveyard*)
        (message "No killed groups")
        (minibuffer-read "Revive group: " (group-graveyard-candidates)
          (lambda (name) (group-revive! (string-trim name)))))))

(public! 'group-revive!
  "(group-revive! NAME) — make the killed group NAME again, with every member that still exists; #f when none was killed by that name")

(persist-global! 'group-graveyard
  (lambda () *group-graveyard*)
  (lambda (saved) (when (pair? saved) (set! *group-graveyard* saved))))

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
              ;; the chat is named for the group, so it follows the group
              (group-chat-rederive! id)
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

;; A grouped frame never falls through to the global MRU when a visible
;; buffer dies. Capture each affected frame before the core removes the
;; buffer. Afterward, fill its windows from that frame's current group only.
(define (group-kill-visible-in-frame frame)
  (map cadr
    (filter (lambda (row) (equal? (caddr row) frame))
            (window-list-all))))

(define *group-dying* #f)

(define (group-kill-replacement group frame)
  (let* ((visible (group-kill-visible-in-frame frame))
         (members (group-buffers-mru group))
         (hidden (filter (lambda (buf) (not (member buf visible))) members)))
    (cond ((pair? hidden) (car hidden))
          ((pair? members) (car members))
          ;; no chat for a group that is being killed: the window falls
          ;; to the next buffer instead
          ((equal? (group-resolve-id group) *group-dying*) #f)
          (else (group-chat group)))))

(define (group-buffer-kill-repair name)
  (let ((places
          (fold
            (lambda (found row)
              (let* ((frame (caddr row))
                     (group (and (equal? (cadr row) name)
                                 (frame-local-in frame 'current-group))))
                (if (group-resolve-id group)
                    (cons (list (car row) frame group) found)
                    found)))
            '()
            (window-list-all))))
    (lambda ()
      (for-each
        (lambda (place)
          (let ((win (car place))
                (frame (cadr place))
                (group (caddr place)))
            (when (frame-of-window win)
              (let ((replacement (group-kill-replacement group frame)))
                (when replacement
                  (window-set-buffer! win replacement))))))
        places))))

(set! buffer-kill-repair group-buffer-kill-repair)

;; Semantic membership lookup. This is the vocabulary a scene, a person and
;; an agent share: "show" resolves without knowing a buffer name or position.
(define (group-buffers-as g role)
  (let ((id (group-resolve-id g))
        (name (group-role-name role)))
    (if (and id name)
        (filter (lambda (b) (equal? (buffer-group-role b id) name))
                (group-buffers-mru id))
        '())))

(define (group-buffer-as g role)
  (let ((buffers (group-buffers-as g role)))
    (and (pair? buffers) (car buffers))))

(define (group-window-as g role)
  (let ((buffers (group-buffers-as g role)))
    (let loop ((windows (window-list)))
      (cond ((null? windows) #f)
            ((member (car (cdr (car windows))) buffers) (car (car windows)))
            (else (loop (cdr windows)))))))

(define (scene-buffer role)
  (let ((id (frame-local 'current-group)))
    (and id (group-buffer-as id role))))

(define (scene-window role)
  (let ((id (frame-local 'current-group)))
    (and id (group-window-as id role))))

(define (group-migrate-live!)
  (for-each
    (lambda (buf)
      (if (chat-buffer? buf)
          (chat-group-id buf)
          (buffer-group-ids buf))
      (buffer-modeline-group-refresh! buf))
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
;; card in the agent design), then the >>> you: input region. Build the
;; surface before mode setup, because setup sees the marker and installs the
;; rich chat runtime. An identity-only buffer from an old restore heals here.
(define (group-chat-init! buf g)
  (let ((id (group-resolve-id g))
        (setup? (or (not (chat-buffer? buf))
                    (not (buffer-local buf 'agent-saved-mark)))))
    (when (and (= (buffer-size buf) 0)
               (not (buffer-local buf 'agent-saved-mark)))
      (chat-surface-init! buf (string-append "companion · " (group-name id))
        (string-append
          "RET sends · C-c w hops to the document · "
          "C-c m model · C-c C-v plain view\n"
          "it reads the live buffers before it speaks, "
          "and edits them in place when you ask\n")))
    (when setup?
      (with-current-buffer buf
        (lambda () (set-mode! "chat-mode"))))
    buf))

;; A chat is named for its group, and a group founded on a file buffer is
;; named for the path. A path makes a buffer name nobody can read, so the
;; chat takes the file name. It keeps as much of the directory as it needs
;; to stay unique. The chat's group, directory and identity do not change.
(define (group-chat--parts p)
  (filter (lambda (s) (not (equal? s ""))) (string-split p "/")))

(define (group-chat--free? name id)
  (or (not (buffer-known? name))
      (equal? (chat-group-id name) id)))

;; A chat is named for where it lives, never for what was said in it.
;; Files in a project answer to the project. A group a person named
;; answers to that name. Anything else answers to the short name of the
;; buffer it accompanies. project.scm loads after this file, so ask for
;; the project only when the function is there.
(define (group-chat--project-name label)
  (and (boundp (quote project-root-from))
       (boundp (quote project-name))
       (let ((root (project-root-from label)))
         (and (string? root) (project-name root)))))

(define (group-chat--base label)
  (if (not (string-prefix? "/" label))
      label
      (or (group-chat--project-name label)
          (let ((parts (group-chat--parts label)))
            (if (null? parts) label (string-join (last-n parts 1) "/"))))))

;; Two groups can want one name — two files in one project, two projects
;; with one directory name. The wanted name goes to whoever is free, and
;; the next chat takes the next path segment with it until it is free
;; again. A name a person types is not derived, so a rename outranks all
;; of this.
(define (group-chat-name g)
  (let* ((id (group-resolve-id g))
         (label (or (group-name (or id g)) g))
         (base (string-append "*chat:" (group-chat--base label) "*")))
    (if (or (not (string-prefix? "/" label)) (group-chat--free? base id))
        base
        (let* ((parts (group-chat--parts label))
               (depth (length parts)))
          (let loop ((n 2))
            (let ((name (string-append "*chat:"
                                       (string-join (last-n parts n) "/")
                                       "*")))
              (cond ((>= n depth) name)
                    ((group-chat--free? name id) name)
                    (else (loop (+ n 1))))))))))

;; A chat's name is DERIVED, never invented, so it follows the group it
;; accompanies. The chat remembers the last name it derived; only that
;; name is replaced. A name the person typed is not derived, so M-x
;; buffer-rename on a chat sticks and no re-derive takes it back.
(define (group-chat--derived? buf)
  ;; A chat named before this rule carries no memory of a derived name, so
  ;; it cannot say whether a person typed it or the old namer invented it.
  ;; Treat it as derivable once. After the re-derive it carries the name,
  ;; and from then on a name a person types is the one that is kept.
  (or (not (buffer-local buf 'chat-derived-name))
      (equal? buf (buffer-local buf 'chat-derived-name))))

(define (group-chat--claim-name! buf)
  (buffer-set-local! buf 'chat-derived-name buf)
  buf)

(define (group-chat-rederive! g)
  (let* ((id (group-resolve-id g))
         (buf (and id (group-primary-chat id)))
         (want (and buf (buffer-known? buf) (group-chat-name id))))
    (cond ((not want) #f)
          ((equal? buf want) (group-chat--claim-name! buf))
          ((not (group-chat--derived? buf)) buf)
          ((buffer-known? want) buf)
          ((rename-buffer! buf want) (group-chat--claim-name! want))
          (else buf))))

;; the same re-derive, asked for by the reader that is about to show the chat
(define (group-chat--heal-name! buf id)
  (or (group-chat-rederive! id) buf))

;; A group founded on one buffer is NAMED for that buffer, so the buffer's
;; name is the group's name. Renaming the buffer must move both, or the
;; group keeps a label for a buffer nobody can find and the chat beside it
;; still reads as the old work. The chat then re-derives, which renames it
;; too, which the layout sweep above follows in turn.
(on-buffer-renamed!
  (lambda (old new)
    (unless (chat-buffer? new)
      (for-each
        (lambda (record)
          (when (and (equal? (group-record-name record) old)
                     (not (group-record-by-name new)))
            (group-record-update! (group-record-id record) 'name new)
            (group-chat-rederive! (group-record-id record))))
        *group-records*))))

;; Every chat the old namer titled, back to the name of its group. A chat
;; with no memory of a derived name predates the rule, and group-chat
;; re-derives it the next time its group asks. This does the same sweep
;; for every group at once, so a title nobody is about to open moves too.
;; A dormant chat has no process to rename, so it waits for its group.
(define (group-chat-derive-all!)
  (let ((moved '()))
    (for-each
      (lambda (record)
        (let* ((id (group-record-id record))
               (buf (group-primary-chat id)))
          (when (and buf (buffer-exists? buf)
                     (not (buffer-local buf 'chat-derived-name)))
            (let ((want (group-chat-rederive! id)))
              (unless (equal? want buf)
                (set! moved (cons (list buf want) moved)))))))
      *group-records*)
    (reverse moved)))

(define-command "chat-derive-names"
  "Rename every chat to the name of the group it accompanies"
  (lambda ()
    (let ((moved (group-chat-derive-all!)))
      (if (null? moved)
          (message "Every chat already carries the name of its group")
          (message
            (string-append
              (number->string (length moved)) " chats renamed: "
              (string-join (map (lambda (m) (car (cdr m))) moved) ", ")))))))

(category! 'chat)
(public! 'group-chat-derive-all!
  "(group-chat-derive-all!) — rename every chat to its group's name; return the (OLD NEW) pairs")

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
    (cond (primary
           (group-chat-init! (group-chat--heal-name! primary id) id))
          ((and chats (pair? chats))
           (let ((buf (car chats)))
             (group-chat-init! buf id)
             (group-record-update! id 'primary-chat-id (chat-stable-id! buf))
             buf))
          (id
            (let ((buf (group-chat-name id)))
              (unless (buffer-exists? buf)
                (buffer-create buf))
              (group-chat--claim-name! buf)
              (group-chat-init! buf id)
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

;; An action link can fill a chat reply without sending it. A link inside a
;; chat targets that chat. A document link targets the receiving group's chat.
(define (chat-inject-reply! text)
  (let* ((here (current-buffer))
         (group (or (frame-group) (buffer-group here)))
         (target (if (chat-buffer? here) here (and group (group-chat group)))))
    (if (not target)
        (message "No chat receives this reply")
        (begin
          (with-current-buffer target
            (lambda () (chat-replace-input! target text)))
          (group-chat-buffer-show! target)
          (message "Reply added to chat")
          target))))

(define (chat-reply-link label reply)
  (string-append "[" label "](compos:reply/" (url-encode reply) ")"))

(on-preview-link! "reply" chat-inject-reply!)

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

;; Read one existing group, or create the typed name. Commands use this
;; reader when the group is their destination rather than their subject.
(define (group-read-or-create! prompt receive)
  (minibuffer-read prompt (group-names)
    (lambda (input)
      (let ((name (string-trim input)))
        (if (equal? name "")
            (message "Group needs a name")
            (receive (or (group-resolve-id name)
                         (group-ensure-record! name))))))))

;; C-u M-x opencode and the group-prefix command use the same destination
;; reader as files and projects.  Enter the group first so a new terminal
;; inherits that group's working directory and layout context.
(set! opencode-group-reader
  (lambda (receive)
    (group-read-or-create! "Open OpenCode in group: "
      (lambda (group)
        (switch-to-group! group)
        (receive group)))))

(define-command "group-new" "Create and enter an empty group"
  (lambda ()
    (group-read-new-name "New group: "
      (lambda (name) (group-create-and-enter! name '() #f)))))

(define-command "buffer-new" "Create a buffer in the current group"
  (lambda ()
    (let ((group (frame-group)))
      (minibuffer-read "New buffer: " '()
        (lambda (input)
          (let ((name (string-trim input)))
            (cond ((equal? name "") (message "Buffer needs a name"))
                  ((buffer-known? name)
                   (message (string-append "Buffer " name " already exists")))
                  (else
                    (buffer-create name)
                    (when group (buffer-add-group! name group))
                    (switch-to-buffer! name)))))))))

(define-command "group-new-from-visible"
  "Create and enter a group that contains the visible work buffers"
  (lambda ()
    (let ((buffers (group-visible-work-buffers))
          (layout (window-tree)))
      (group-read-new-name "New group from visible buffers: "
        (lambda (name) (group-create-and-enter! name buffers layout))))))

(define (buffer-family--eligible? name)
  (and (buffer-known? name)
       (group-work-buffer? name)
       (not (buffer-local name 'transient))))

;; A grouped scratch belongs to its group. A chat or that scratch therefore
;; resolves through the group's work buffers. An ordinary work buffer keeps a
;; narrow family: itself and the group's scratch. The legacy owner pointers
;; remain a fallback for buffers that have not reached the group migration yet.
(define (buffer-family buf)
  (let* ((group (buffer-group buf))
         (role (and group (buffer-group-role buf group)))
         (through-group? (and group
                              (or (chat-buffer? buf) (equal? role "scratch"))))
         (owner (or (buffer-local buf 'scratch-owner) buf))
         (legacy-scratch (and (buffer-known? owner)
                              (buffer-local owner 'scratch-buffer)))
         (group-scratches (if group (group-buffers-as group 'scratch) '()))
         (candidates
           (cond (through-group? (group-buffers-mru group))
                 (group
                   (append (list buf)
                           group-scratches
                           (if (and legacy-scratch
                                    (buffer-known? legacy-scratch))
                               (list legacy-scratch)
                               '())))
                 (else
                   (append (list owner)
                           (if (and legacy-scratch
                                    (buffer-known? legacy-scratch))
                               (list legacy-scratch)
                               '())
                           (if (equal? owner buf) '() (list buf)))))))
    (dedupe-names (filter buffer-family--eligible? candidates))))

(define (group-create-with-buffer! name buf source)
  (let ((id (group-record-create! name))
        (family (buffer-family buf))
        (source-id (group-resolve-id source)))
    (if (not id)
        (message (string-append "Could not create group " name))
        (begin
          (set! *group-current-inhibit* #t)
          (for-each
            (lambda (member)
              (if source-id
                  (buffer-move-to-group! member id)
                  (buffer-add-group! member id)))
            family)
          (set! *group-current-inhibit* #f)
          (switch-to-group! id)
          (let ((window (window-showing buf)))
            (if window (select-window! window) (switch-to-buffer! buf)))
          id))))

(define-command "group-new-with-buffer"
  "Create and enter a group with the current buffer family"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (not (group-work-buffer? buf))
          (message "The current buffer is not a work buffer")
          (group-read-new-name "New group with buffer: "
            (lambda (name) (group-create-with-buffer! name buf #f)))))))

;; Compatibility name for older configuration.
(define-command "group-new-from-buffer"
  "Create and enter a group with the current buffer family"
  (lambda () (run-command "group-new-with-buffer")))

(define (switch-buffer-to-group! buf id)
  (switch-to-group! id)
  (let ((window (window-showing buf)))
    (if window (select-window! window) (switch-to-buffer! buf))))

;; the project root a buffer belongs to, or #f when it belongs to none
(define (group--project-root-of buf)
  (let ((root (buffer-project-root buf)))
    (and (string? root) (not (equal? root "")) root)))

(define (group-buffer-context-switch! buf)
  (let ((ids (group-buffer-memberships buf))
        (root (group--project-root-of buf)))
    (cond
      ;; A project is a context that already exists. Enter it under the
      ;; root's name and take the project's other open buffers along.
      ;; Only a buffer with no project has to invent a name.
      ((and (null? ids) root)
       (let ((id (group-ensure-record! root)))
         (for-each
           (lambda (x)
             (when (and (group-work-buffer? x)
                        (null? (group-buffer-memberships x))
                        (equal? (group--project-root-of x) root))
               (buffer-add-group! x id)))
           (buffer-list))
         (switch-buffer-to-group! buf id)))
      ((null? ids)
       (group-read-new-name "Start a group with this buffer: "
         (lambda (name) (group-create-with-buffer! name buf #f))))
      ((null? (cdr ids)) (switch-buffer-to-group! buf (car ids)))
      (else
        (let ((ordered (filter (lambda (id) (member id ids)) (group-ids-mru))))
          (minibuffer-read "Switch buffer to group: " (map group-name ordered)
            (lambda (name)
              (let ((id (group-resolve-id name)))
                (when id (switch-buffer-to-group! buf id))))))))))

(set! buffer-context-switch! group-buffer-context-switch!)

(define (group-all-work-buffers)
  (filter group-work-buffer? (buffer-list)))

;;; --- one buffer prompt, in sections ------------------------------------------
;;; C-x b lists the current group's buffers first, then every other buffer.
;;; Without a current group, the prompt lists all buffers in one section.
;;; A separator is a heading, not a choice: the selection steps over it and
;;; RET never confirms one.
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
          (dedupe-names
            (append (window-buffer-history) (buffer-list-mru)))))

(define (group-switch-separator label) (list label "" "separator"))

;; annotate the WHOLE pool once, then split it: the marginalia columns
;; line up across both sections, because they were measured over both
(define (group-buffer-switch-candidates id here)
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
        ((not (group-work-buffer? buf)) (message "Chats cannot be added"))
        (else
          (buffer-add-group! buf id)
          (switch-to-buffer! buf)
          (message (string-append "Added " buf " to " (group-name id))))))

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
            (else
              (switch-to-buffer! buf))))))

(define-command "group-switch-buffer"
  "Switch to a buffer; C-RET enters its group, S-RET adds it to this one"
  (lambda ()
    (set! *mb-confirm-context* #f)
    (set! *mb-confirm-adopt* #f)
    (let* ((here (current-buffer))
           (id (group-resolve-id (frame-local 'current-group)))
           (candidates (group-buffer-switch-candidates id here))
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
            4 #f #f
            ;; Collection reuses ibuffer. It receives only the candidates
            ;; that survived the prompt's narrowing; headings are not buffers.
            (lambda (rows)
              (when (buffer-known? here) (window-preview-buffer! here))
              (sleep-woken! #f)
              (let ((buffers (filter buffer-known? (map car rows))))
                (if (null? buffers)
                    (message "No buffer candidates to collect")
                    (ibuffer-open-buffers! buffers)))))))))

(define (group-command-work-buffers)
  ;; C-SPC in the switcher and `buffer-select` are two views of the same
  ;; selection.  A command invoked from the switcher must not lose selections
  ;; made on ordinary buffers, and a repeated name must still be acted on once.
  ;; With no selection at all, the command means the current buffer.
  (let* ((buf (current-buffer))
         (marked (if (equal? (buffer-local buf 'mode-name) "switch-mode")
                     (list-live-marked buf *list-mark-char*)
                     '()))
         (selected (filter (lambda (candidate)
                             (buffer-local candidate 'buffer-selected))
                           (buffer-list-mru)))
         (chosen (filter group-work-buffer?
                         (dedupe-names (append marked selected)))))
    (cond ((pair? chosen) chosen)
          ((group-work-buffer? buf) (list buf))
          (else '()))))

(define (group-selected-visible-work-buffers)
  (filter (lambda (buf) (buffer-local buf 'buffer-selected))
          (group-visible-work-buffers)))

(define (group-command-selected-or-visible-buffers)
  (let* ((visible (group-visible-work-buffers))
         (selected (group-selected-visible-work-buffers)))
    (if (pair? selected) selected visible)))

;; The prompt takes a typed name as well as a listed one, and a name it
;; does not know is a group to found — the same answer the "New group"
;; row gives. group-ensure-record! still refuses an id, so a dangling
;; membership cannot found a group named after itself.
(define (group-add-buffers-to! buffers destination)
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
                    (buffer-set-local! buf 'buffer-selected #f)
                    (set! changed (+ changed 1)))
                  (set! skipped (+ skipped 1))))
            buffers)
          (message
            (string-append "Added " (number->string changed) " buffer"
                           (if (= changed 1) "" "s") " to "
                           (group-name id)
                           (if (= skipped 0) ""
                               (string-append "; skipped "
                                              (number->string skipped)))))
          ;; a list that shows membership is now stale, and the marks that
          ;; chose these buffers are spent. The add happens under a
          ;; minibuffer callback, so no caller can refresh after it.
          (run-hooks 'group-membership-hook)
          changed))))

(define (group-confirm-target! id continue)
  (if (not id)
      (message "Group needs a name")
      (let ((members (group-buffers-mru id)))
        (if (null? members)
            (continue)
            (y-or-n
              (string-append "Target group " (group-name id) " contains:\n"
                             (string-join members "\n")
                             "\nContinue? ")
              continue)))))

(define (group-add-read-destination! buffers)
  (minibuffer-read "Add buffers to group: "
    (cons (list "New group" "create without entering") (group-names))
    (lambda (destination)
      (if (equal? destination "New group")
          (group-read-new-name "New destination group: "
            (lambda (name)
              (let ((id (group-record-create! name)))
                (when id (group-add-buffers-to! buffers id)))))
          (let ((id (or (group-resolve-id destination)
                        (group-record-create! destination))))
            (group-confirm-target! id
              (lambda () (group-add-buffers-to! buffers id))))))))

(define (group-move-buffers-to! buffers destination)
  (let ((id (group-ensure-record! destination)))
    (cond
      ((not id) (message "No destination group"))
      (else
        (let ((eligible
               (filter (lambda (buf)
                         (and (buffer-known? buf)
                              (group-work-buffer? buf)))
                       buffers)))
          (for-each (lambda (buf) (buffer-move-to-group! buf id)) eligible)
          (run-hooks 'group-membership-hook)
          (message (string-append "Moved " (number->string (length eligible))
                                  " buffer"
                                  (if (= (length eligible) 1) "" "s")
                                  " to " (group-name id)))
          (length eligible))))))

(define (buffer-add-family-to-group! buf destination)
  (let ((family (buffer-family buf))
        (id (group-resolve-id destination)))
    (if (not id)
        (message "No destination group")
        (begin
          (for-each (lambda (member) (buffer-add-group! member id)) family)
          (run-hooks 'group-membership-hook)
          (message (string-append "Added " (number->string (length family))
                                  " buffer"
                                  (if (= (length family) 1) "" "s")
                                  " to " (group-name id)))
          family))))

(define (buffer-move-family-to-group! buf destination)
  (let ((family (buffer-family buf))
        (to (group-resolve-id destination)))
    (cond ((not to) (message "No destination group"))
          (else
            (set! *group-current-inhibit* #t)
            (for-each (lambda (member) (buffer-move-to-group! member to)) family)
            (set! *group-current-inhibit* #f)
            (group-current-recalculate!)
            (run-hooks 'group-membership-hook)
            (message (string-append "Moved " (number->string (length family))
                                    " buffer"
                                    (if (= (length family) 1) "" "s")
                                    " to " (group-name to)))
            family))))

(define-command "buffer-add-to-group" "Add the selected buffers to a group"
  (lambda ()
    (let ((buffers (group-command-work-buffers)))
      (if (null? buffers)
          (message "No work buffer selected, and the current buffer is not one")
          (group-add-read-destination! buffers)))))

(define (buffer-move-read-destination! buf)
  (group-read-or-create! "Move buffer to group: "
    (lambda (group) (buffer-move-family-to-group! buf group))))

(define-command "buffer-move-to-group" "Move the current buffer family to one group"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (not (group-work-buffer? buf))
          (message "The current buffer is not a work buffer")
          (buffer-move-read-destination! buf)))))

(define (buffer-family-remove-groups! buf ids)
  (for-each
    (lambda (id)
      (for-each
        (lambda (member)
          (when (buffer-in-group? member id)
            (buffer-remove-group! member id)))
        (buffer-family buf)))
    ids)
  (when (pair? ids) (run-hooks 'group-membership-hook))
  (message
    (if (null? ids)
        "No group memberships changed"
        (string-append "Removed " (number->string (length ids))
                       " group membership"
                       (if (= (length ids) 1) "" "s"))))
  ids)

(define (buffer-remove-candidates ids pending)
  (map
    (lambda (id)
      (list (group-name id)
            (if (member id pending)
                "remove on C-g · RET keeps"
                "keep · RET removes")))
    ids))

(define (buffer-remove-read! buf ids pending)
  (minibuffer-read* "Toggle group removal (C-g applies): "
    (buffer-remove-candidates ids pending)
    (list
      (list 'confirm
        (lambda (name)
          (let ((id (group-resolve-id name)))
            (buffer-remove-read!
              buf ids
              (if (and id (member id pending))
                  (remove (lambda (held) (equal? held id)) pending)
                  (if id (append pending (list id)) pending))))))
      (list 'cancel (lambda () (buffer-family-remove-groups! buf pending)))
      (list 'style #f))))

(define-command "buffer-remove-from-group"
  "Remove one or more group memberships from the current buffer family"
  (lambda ()
    (let* ((buf (current-buffer))
           (ids (group-buffer-memberships buf)))
      (cond ((null? ids) (message "The buffer is not in a group"))
            (else (buffer-remove-read! buf ids '()))))))

(define (group-move-read-destination! buffers)
  (minibuffer-read "Move buffers to group: "
    (cons (list "New group" "create without entering") (group-names))
    (lambda (destination)
      (if (equal? destination "New group")
          (group-read-new-name "New destination group: "
            (lambda (name)
              (let ((id (group-record-create! name)))
                (when id (group-move-buffers-to! buffers id)))))
          (let ((id (or (group-resolve-id destination)
                        (group-record-create! destination))))
            (group-confirm-target! id
              (lambda () (group-move-buffers-to! buffers id))))))))

(define-command "group-move-visible"
  "Move selected buffers, or all visible work buffers, to another group"
  (lambda ()
    (let ((buffers (group-command-selected-or-visible-buffers)))
      (if (null? buffers)
          (message "No work buffers selected or visible")
          (group-move-read-destination! buffers)))))

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

(define-command "group-remove" "Select group memberships to remove from this buffer"
  (lambda () (run-command "buffer-remove-from-group")))

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

(define-command "group-show-all"
  "Tile every buffer in the current group with the adaptive layout"
  (lambda () (run-command "tile-all")))


(mode-icon! "groups-mode" "")

(define (group-keymap-install!)
  (global-set-key "C-c g" "group-join")
  (global-set-key "C-c d" "group-describe")
  (global-set-key "C-x G" "groups")
  (global-set-key "C-x b" "group-switch-buffer")
  (global-set-key "C-x g" "switch-to-group")

  ;; A previous release bound the prefix itself. Remove it during hot reload.
  (global-unset-key "C-x C-g")
  (global-set-key "C-x C-g g" "switch-to-group")
  (global-set-key "C-x C-g a" "buffer-add-to-group")
  (global-set-key "C-x C-g m" "buffer-move-to-group")
  (global-set-key "C-x C-g r" "buffer-remove-from-group")
  (global-set-key "C-x C-g n" "group-new")
  (global-set-key "C-x C-g v" "group-new-from-visible")
  (global-set-key "C-x C-g l" "groups")
  (global-set-key "C-x C-g s" "tile-all")
  (global-set-key "C-x C-g o" "opencode-in-group")
  (global-set-key "C-x C-g p" "group-pin"))

(group-keymap-install!)

;; Remove the previous membership vocabulary from hot-reloaded sessions.
(for-each undefine-command
  '("group-pull-buffer" "group-push-buffer" "group-push-visible"
    "group-push-selected" "group-pop"))

(public! 'group-ids "(group-ids) -> durable opaque group IDs")
(public! 'group-name "(group-name ID) -> the current display name")
(public! 'buffer-group-ids "(buffer-group-ids NAME) -> work memberships")
(public! 'buffer-in-group? "(buffer-in-group? NAME ID) -> membership")
(public! 'buffer-group-role "(buffer-group-role BUFFER GROUP) -> semantic role string or #f; chats answer \"chat\"")
(public! 'group-visible-homogeneous?
  "(group-visible-homogeneous? GROUP) -> #t when GROUP is the frame's derived current group")
(public! 'group-pinned "(group-pinned) -> the pinned frame group ID, or #f")
(public! 'group-current-recalculate!
  "(group-current-recalculate!) -> derive the frame's current group from its visible buffers")
(public! 'group-ids-mru "(group-ids-mru) -> all group IDs in most-recently-used order")
(public! 'buffer-family
  "(buffer-family BUFFER) -> the group-relative work family, including its shared scratch companion")
(public! 'buffer-add-group-as! "(buffer-add-group-as! BUFFER GROUP ROLE) — join GROUP with a semantic role")
(public! 'group-record-create! "(group-record-create! NAME) -> new stable ID or #f")
(public! 'group-read-or-create!
  "(group-read-or-create! PROMPT RECEIVE) — read an existing group or create the typed name")
(public! 'buffer-group "(buffer-group NAME) -> the buffer's group tag or #f")
(effects! '(read))
(public! 'buffer-color-group
  "(buffer-color-group NAME) -> the buffer-owned group that supplies its color, or #f"
  'buffers)
(public! 'buffer-filename-face
  "(buffer-filename-face NAME) -> the group color face for a buffer filename, or #f"
  'buffers)
(effects! '(write))
(public! 'group-buffers "(group-buffers G) -> names of the buffers tagged 'group G")
(public! 'group-buffers-as "(group-buffers-as GROUP ROLE) -> buffers with that group-relative role")
(public! 'group-buffer-as "(group-buffer-as GROUP ROLE) -> most recent buffer with ROLE, or #f")
(public! 'group-window-as "(group-window-as GROUP ROLE) -> visible window for ROLE, or #f")
(public! 'scene-buffer "(scene-buffer ROLE) -> current scene/group buffer with ROLE, or #f")
(public! 'scene-window "(scene-window ROLE) -> current scene/group window with ROLE, or #f")
(public! 'group-chat "(group-chat G) — find or create G's chat buffer; returns its name")
(public! 'group-chat-show! "(group-chat-show! G) — open/focus G's chat pane; returns its name")
(public! 'chat-inject-reply!
  "(chat-inject-reply! TEXT) — put TEXT in this chat, or the current group's chat, without sending")
(public! 'chat-reply-link
  "(chat-reply-link LABEL REPLY) — a Markdown action link that fills a chat reply")

(catalog-meta! 'command "group-describe" 'domain 'buffers 'effects '(write external spend))
(catalog-meta! 'command "group-describe-at-point" 'domain 'buffers 'effects '(write external spend))
(catalog-meta! 'command "group-kill" 'domain 'buffers 'effects '(destroy))
(catalog-meta! 'command "group-kill-at-point" 'domain 'buffers 'effects '(destroy))
(catalog-meta! 'command "groups" 'domain 'buffers 'effects '(read))
(catalog-meta! 'function "buffer-group" 'domain 'buffers 'effects '(read))
(catalog-meta! 'function "buffer-color-group" 'domain 'buffers 'effects '(read))
(catalog-meta! 'function "buffer-filename-face" 'domain 'buffers 'effects '(read))
(catalog-meta! 'function "group-buffers" 'domain 'buffers 'effects '(read))
(catalog-meta! 'function "group-chat" 'domain 'buffers 'effects '(write))
(catalog-meta! 'function "group-chat-show!" 'domain 'buffers 'effects '(write))
(catalog-meta! 'function "chat-inject-reply!" 'domain 'chat 'effects '(write display))
(catalog-meta! 'function "chat-reply-link" 'domain 'chat 'effects '(pure))

(group-current-recalculate!)
(message "groups.scm loaded")
