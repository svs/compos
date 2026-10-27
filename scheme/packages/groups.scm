;;; groups.scm --- Buffer groups, saved layouts, and companion chats.

;;;; A group is a durable context with a stable record and opaque ID.
;;;; Work buffers contain one group ID and may name their role in it.
;;;; Chats contain one owning group ID and always have the role "chat".
;;;; This package owns membership, switching, layouts, records, and chats.

(domain! 'buffers)
(effects! '(write))

;;; --- durable group records and buffer-local membership -------------------------
;;; Every buffer keeps its one group in 'group-id, and nothing else names it.
;;; Work buffers may add 'group-roles, a role in that one group; chats one 'chat-id. The older 'group and 'companion-of names migrate on
;;; the first membership read; a 'group-ids list from an old desktop is folded
;;; into 'group-id by a one-shot migration on restore (migrations.scm).
;;; Group records persist independently, including empty and chatless groups.
;;; (group-buffers g) derives live membership from buffer-local identity.





(defvar '*group-records* '())

;; Groups are first class, so they keep their own recency cache. The shared
;; mru-list is one ring for buffers and groups together: the buffer visits
;; between two group switches push every older group off the end, and the
;; ring is rebuilt each boot from the buffer history, which carries no group
;; marks at all. This list holds group ids only, and it persists.
(defvar '*group-mru* '())

(defcustom 'group-mru-limit 50
  "How many groups the recency cache remembers. Past the limit the oldest
is forgotten and that group falls back to creation order in the switcher."
  'group 'groups 'type 'number)
(defvar '*group-next-id* 0)
(define *group-colors* 6)              ; how many slots the group scale has

;; The theme owns the colour of a group; a package owns its weight. Each
;; slot has an entry in every palette, so a theme switch re-tints every
;; group at once.
(defface! 'group-color-1 'weight "700")
(defface! 'group-color-2 'weight "700")
(defface! 'group-color-3 'weight "700")
(defface! 'group-color-4 'weight "700")
(defface! 'group-color-5 'weight "700")
(defface! 'group-color-6 'weight "700")

(define (group-record-id record) (nth 0 record))
(define (group-record-name record) (nth 1 record))
(define (group-record-meta record) (nth 2 record))
(define (group-record-layout record) (nth 3 record))
(define (group-record-noise record) (nth 4 record))
(define (group-record-primary-chat-id record) (nth 5 record))
;; the group's slot on the colour scale, 1 to *group-colors*, the seventh
;; field. A slot survives a theme switch where a hex could not.
(define (group-record-color record)
  (and (> (length record) 6) (nth 6 record)))
;; the id of the group this one popped out of; dissolve merges back into it
(define (group-record-parent record)
  (and (> (length record) 7) (nth 7 record)))

;; the path a group was founded from, or #f for a name a person typed.
;; The group is found by its origin as well as by its name, so a caller
;; holding the path still reaches it after the name shortened.
(define (group-record-origin record)
  (and (> (length record) 8) (nth 8 record)))

;; per-group overrides, the ninth field. A record written before group
;; settings existed is shorter and answers none.
(define (group-record-settings record)
  (and (> (length record) 9) (nth 9 record)))

(define (group-home-slug s)
  (let loop ((r s))
    (let ((next (re-replace "[^A-Za-z0-9._-]" r "-")))
      (if (equal? next r) r (loop next)))))

;; the durable directory a group saves its chats and other artifacts
;; under. A group founded from a path (Dired, a project root) keeps its
;; home IN that path, tucked into .compos beside it — the same way a
;; project's annotations travel with its repo (annotate.scm). A group
;; with no origin path gets a home under compos-home, keyed by its id so
;; a rename never orphans what it already saved.
(define (group-home-dir g)
  ;; always under the editor's home, never in the group's directory: a
  ;; project stays clean, and a group's cwd can change without moving it.
  (string-append (compos-home) "/groups/"
                 (group-home-slug (or (group-resolve-id g) "group"))))

;; VALUE names a group, or is a colour slot already. -> the face name for
;; that slot, or "accent" for anything off the scale.
(define (group-color-face value)
  (let* ((record (and value
                      (or (group-record-by-id value)
                          (group-record-by-name value))))
         (slot (if record (group-record-color record) value)))
    (if (group-color-slot? slot)
        (string-append "group-color-" (number->string slot))
        "accent")))

;; #t for a slot the scale has a face for
(define (group-color-slot? slot)
  (and (number? slot) (>= slot 1) (<= slot *group-colors*)))

;; The render paths that take a colour value rather than a face name: the
;; frame style and the modeline. The hex is the current theme's, read back
;; through the face, so it changes with the theme.
(define (group-color-hex slot)
  (and (group-color-slot? slot)
       (face-color (string->symbol (string-append "group-color-"
                                                  (number->string slot)))
                   'fg)))

(define (buffer-color-group buf)
  (if (chat-buffer? buf)
      (chat-group-id buf)
      (buffer-group buf)))

(define (buffer-filename-face buf)
  (let ((group (buffer-color-group buf)))
    (and group (group-color-face group))))

;; a buffer candidate wears its group's color; any other candidate, or a
;; buffer with no group, leaves the answer to the next key
(add-hook! '(candidate-face groups)
  (lambda (category name)
    (and (equal? category 'buffer) (buffer-known? name)
         (buffer-filename-face name))))

(define (group-next-color)
  (+ 1 (modulo (- *group-next-id* 1) *group-colors*)))

;;; --- pseudo groups ----------------------------------------------------------
;;
;; A pseudo group has a name and members, and no record of its own. A
;; function answers the members each time somebody asks, so the
;; membership follows the editor and not the buffer locals. "Last chats"
;; is the first one: the chats you used most recently.
;;
;; The lookups below answer a pseudo group with a record of the normal
;; shape, so the name, the colour, the label and the switcher need no
;; special case. The record never joins *group-records*, so save,
;; restore, rename, dissolve and magic grouping never see one. Only
;; membership diverts: group-buffers calls the function.

(defvar '*pseudo-group-records* '())    ; records, in the order declared
(defvar '*pseudo-group-members* '())    ; (ID . FN)

;; define-pseudo-group! writes this prefix, so a string that carries it
;; names a pseudo group and never a group a person founded.
(define (pseudo-group-id? value)
  (and (string? value) (string-prefix? "pseudo:" value)))

(define (pseudo-record-by-id id)
  (let loop ((records *pseudo-group-records*))
    (cond ((null? records)
           ;; a mode group may not be read yet: refresh once, then look again
           (and (string-prefix? "pseudo:mode-" id)
                (not (equal? (mode-groups-key) *mode-groups-key*))
                (begin (mode-groups-refresh!) (pseudo-record-by-id id))))
          ((equal? (group-record-id (car records)) id) (car records))
          (else (loop (cdr records))))))

(define (pseudo-record-by-name name)
  (let loop ((records *pseudo-group-records*))
    (cond ((null? records)
           (and (string-prefix? "mode: " name)
                (not (equal? (mode-groups-key) *mode-groups-key*))
                (begin (mode-groups-refresh!) (pseudo-record-by-name name))))
          ((equal? (group-record-name (car records)) name) (car records))
          (else (loop (cdr records))))))

;; Name the group, and give FN the job of answering its members. FN
;; answers buffer names, best first. A second call with the same name
;; replaces the function, so a reload declares the group once more.
(define (define-pseudo-group! name fn)
  (let* ((id (string-append "pseudo:" (group-home-slug name)))
         (record (list id name #f #f "quiet" #f (group-next-color) #f #f '())))
    (set! *pseudo-group-records*
          (append (remove (lambda (r) (equal? (group-record-id r) id))
                          *pseudo-group-records*)
                  (list record)))
    (set! *pseudo-group-members*
          (cons (list id fn)
                (remove (lambda (e) (equal? (car e) id))
                        *pseudo-group-members*)))
    id))

;; take a pseudo group away again
(define (undefine-pseudo-group! g)
  (let* ((record (if (pseudo-group-id? g)
                     (pseudo-record-by-id g)
                     (pseudo-record-by-name g)))
         (id (and record (group-record-id record))))
    (when id
      (set! *pseudo-group-records*
            (remove (lambda (r) (equal? (group-record-id r) id))
                    *pseudo-group-records*))
      (set! *pseudo-group-members*
            (remove (lambda (e) (equal? (car e) id)) *pseudo-group-members*)))
    id))

(define (pseudo-group-ids)
  (mode-groups-refresh!)
  (map group-record-id *pseudo-group-records*))

(define (pseudo-group-names)
  (mode-groups-refresh!)
  (map group-record-name *pseudo-group-records*))

;; the members now: the function's answer, less the buffers that went
(define (pseudo-group-buffers g)
  (let ((entry (assoc (and (pseudo-group-id? g) g) *pseudo-group-members*)))
    (cond ((not entry) '())
          ;; a mode group reads the buffer list itself: every name is known
          ((member g *mode-group-ids*) ((cadr entry)))
          (else (filter buffer-known? ((cadr entry)))))))

;; every pseudo group BUF belongs to now
(define (buffer-pseudo-group-ids buf)
  (filter (lambda (id) (and (member buf (pseudo-group-buffers id)) #t))
          (pseudo-group-ids)))

(defcustom 'last-chats-limit 3
  "How many chats the Last chats pseudo group gathers."
  'group 'groups 'type 'number)

;; The chats you used most recently, the most recent first. The recency
;; ring holds every buffer, so the walk stops when it has enough chats.
(define (last-chats)
  (let loop ((rest (buffer-list-mru)) (out '()) (n 0))
    (cond ((or (null? rest) (>= n last-chats-limit)) (reverse out))
          ((and (buffer-known? (car rest)) (chat-buffer? (car rest)))
           (loop (cdr rest) (cons (car rest) out) (+ n 1)))
          (else (loop (cdr rest) out n)))))

(define-pseudo-group! "Last chats" last-chats)

;; Modes as groups: a major mode that mode-groups-min buffers share is a
;; pseudo group of its own, named "mode: org" for org-mode. Nothing
;; declares them; the pseudo readers refresh the set, and only when the
;; buffer list has moved since the last look. One batched read of the
;; mode names pays for the whole table.
(defcustom 'mode-groups-min 2
  "How many buffers a major mode needs to be a group. 0 turns mode groups off."
  'group 'groups 'type 'number)

(defcustom 'mode-groups-exclude '("fundamental-mode")
  "Major modes that never become a group."
  'group 'groups 'type 'list)

(defvar '*mode-groups-key* #f)       ; the buffer list the table was read from
(defvar '*mode-groups-table* '())    ; ((MODE BUF ...) ...), most recent first
(defvar '*mode-group-ids* '())       ; the pseudo ids mode groups hold now

(define (mode-group-name mode)
  (string-append "mode: "
                 (if (string-suffix? "-mode" mode)
                     (substring mode 0 (- (string-length mode) 5))
                     mode)))

(define (mode-group-buffers mode)
  ;; read now, from the buffer rows: the table below only decides which
  ;; modes are groups
  (map car (cadr (buffer-rows (list 'modes (list mode) 'context-only #t)))))

(define (mode-groups-key)
  ;; the count per mode changes only when a mode gains or loses a buffer,
  ;; not on every switch as the buffer list's order does
  (sort (map (lambda (run) (list (car run) (length (cdr run))))
             (cadr (buffer-rows (list 'hidden #t 'context-only #t 'bucket 'mode))))))

(define (mode-groups-read)
  ;; ((MODE BUF ...) ...), the modes in the order of their most recent buffer
  (cadr (buffer-rows (list 'context-only #t 'bucket 'mode))))

(define (mode-groups-refresh!)
  (let ((key (mode-groups-key)))
    (unless (equal? key *mode-groups-key*)
      ;; the key goes first, so a define below that reads the records
      ;; finds the table current instead of refreshing again
      (set! *mode-groups-key* key)
      (let* ((table (filter (lambda (row) (not (member (car row) mode-groups-exclude)))
                            (mode-groups-read)))
             (wanted (if (> mode-groups-min 0)
                         (filter (lambda (row) (>= (length (cdr row)) mode-groups-min)) table)
                         '())))
        (set! *mode-groups-table* table)
        (let ((ids (map (lambda (row)
                          (let* ((mode (car row))
                                 (id (string-append "pseudo:"
                                                    (group-home-slug (mode-group-name mode)))))
                            ;; an existing one keeps its colour
                            (if (member id *mode-group-ids*)
                                id
                                (define-pseudo-group! (mode-group-name mode)
                                                      (lambda () (mode-group-buffers mode))))))
                        wanted)))
          (for-each undefine-pseudo-group!
                    (filter (lambda (id) (not (member id ids))) *mode-group-ids*))
          (set! *mode-group-ids* ids))))))

;; buffer-goto-group: stand in this buffer's own group; pseudo groups never count.
(define (buffer-goto-group! b id)
  (unless (equal? id (frame-group)) (switch-to-group! id))
  (let ((w (window-showing b)))
    (if (and w (window-exists? w))
        (select-window! w)
        (switch-to-buffer! b)))
  id)

(define-command "buffer-goto-group"
  "Stand in this buffer's own group and focus the buffer there"
  (lambda ()
    (let* ((b (current-buffer))
           (id (group-home-of b)))
      (if id
          (buffer-goto-group! b id)
          (message (string-append b " is in no group"))))))

(define (group-record-by-id id)
  (if (pseudo-group-id? id)
      (pseudo-record-by-id id)
      ;; a record leads with its id, so the builtin assoc finds it
      (assoc id *group-records*)))

(define *group-name-table* '(#f))   ; (RECORDS (KEY RECORD) ...)

;; ((KEY RECORD) ...): each record's name, then its origin, in record order,
;; so one assoc answers what the walk below used to. Rebuilt only when the
;; records change; eq? compares them by content.
(define (group-name-table)
  (let ((records *group-records*))
    (if (eq? (car *group-name-table*) records)
        (cdr *group-name-table*)
        (let ((table (reverse (fold (lambda (out r)
                                      (cons (list (group-record-origin r) r)
                                            (cons (list (group-record-name r) r) out)))
                                    '() records))))
          (set! *group-name-table* (cons records table))
          table))))

(define (group-record-by-name name)
  (let ((hit (assoc name (group-name-table))))
    (if hit (cadr hit) (pseudo-record-by-name name))))

;; the record wearing exactly NAME, other than EXCEPT-ID, or #f
(define (group-record-wearing name except-id)
  (let loop ((records *group-records*))
    (cond ((null? records) #f)
          ((and (equal? (group-record-name (car records)) name)
                (not (equal? (group-record-id (car records)) except-id)))
           (car records))
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

;; A group's name is already the shortest one that reads apart (see
;; group-assign-path-name!). A string that names no group yet, a project
;; root on a card, wears its last segment.
(define (group-short-name g)
  (let ((name (group-display-name g)))
    (cond ((equal? name "") "")
          ((group-resolve-id g) name)
          (else (car (reverse (string-split name "/")))))))

(define (group-display-label-in g frame)
  (let ((name (group-short-name g)))
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

;;; --- the shortest name that reads apart --------------------------------------
;;; A group founded from a path (a directory in Dired, a file, a project
;;; root) is named by the last segment of that path: journal, not
;;; /Users/svs/docs/journal. When two groups would wear one name, both
;;; lengthen by a segment until they read apart: docs/journal and
;;; work/journal (Emacs uniquify, forward style). The path stays on the
;;; record as its origin, so the group is still found by the path.

(define (group-path-name? s)
  (and (string? s) (or (string-prefix? "/" s) (string-prefix? "~" s))))

(define (group--path-parts path)
  (filter (lambda (part) (not (equal? part ""))) (string-split path "/")))

;; the last N segments of PATH, joined by /
(define (group--path-tail path n)
  (let* ((parts (group--path-parts path))
         (drop (max 0 (- (length parts) n))))
    (string-join (list-tail parts drop) "/")))

(define (group--set-name! id name)
  (set! *group-records*
    (map (lambda (record)
           (if (equal? (group-record-id record) id)
               (append (list (group-record-id record) name) (list-tail record 2))
               record))
         *group-records*)))

;; give ID the shortest tail of PATH no other group wears. A group that
;; wears that tail for a path of its own lengthens by one segment too, so
;; the pair reads apart. A path with no free tail wears the whole path.
(define (group-assign-path-name! id path)
  (let ((parts (length (group--path-parts path))))
    (let loop ((n 1))
      (let* ((name (group--path-tail path n))
             (other (group-record-wearing name id)))
        (cond ((not other) (group--set-name! id name))
              ((>= n parts) (group--set-name! id path))
              (else
                (let ((origin (group-record-origin other)))
                  (when (and origin (not (equal? origin path)))
                    (group--set-name! (group-record-id other)
                                      (group--path-tail origin (+ n 1)))))
                (loop (+ n 1))))))))

;; every path-founded group takes the shortest name free now: a group
;; that lengthened to read apart from one since deleted shortens again
;; (Emacs uniquify-after-kill-buffer-p)
(define (group-reshorten-path-names!)
  (for-each
    (lambda (record)
      (let ((origin (group-record-origin record)))
        (when origin (group-assign-path-name! (group-record-id record) origin))))
    *group-records*))

;; a record from before origins: a path name becomes an origin, and the
;; group takes its short name
(define (group-migrate-path-names!)
  (for-each
    (lambda (record)
      (when (and (group-path-name? (group-record-name record))
                 (not (group-record-origin record)))
        (let ((id (group-record-id record))
              (path (group-record-name record)))
          (group-record-update! id 'origin path)
          (group-assign-path-name! id path))))
    *group-records*))

(define (group-record-create! name)
  (let ((clean (string-trim name)))
    (cond ((equal? clean "") #f)
          ((group-record-by-name clean) #f)
          (else
            (let* ((id (group-new-id!))
                   (path? (group-path-name? clean))
                   (record (list id clean #f #f "quiet" #f (group-next-color)
                                 #f (and path? clean))))
              (set! *group-records* (append *group-records* (list record)))
              (when path? (group-assign-path-name! id clean))
              ;; the founding frame owns it; that counts only if the frame is isolated
              (group-frame-own! id (selected-frame))
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
;; C-c g list and on the reader's screen. buffer-group already drops
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
                          (group-record-color record))
                      (if (equal? field 'parent) new-value
                          (group-record-parent record))
                      (if (equal? field 'origin) new-value
                          (group-record-origin record))
                      (if (equal? field 'settings) new-value
                          (group-record-settings record)))))
          *group-records*))
      (desktop-dirty!)
      (when (member field '(name color))
        (group-frame-styles-refresh!)
        (modeline-groups-refresh!)))))

(define (group-record-delete! value)
  (let ((id (group-resolve-id value)))
    (when id
      (group-frame-context-remove-id! id)
      (set! *group-mru* (remove (lambda (x) (equal? x id)) *group-mru*))
      (set! *group-records*
        (remove (lambda (record) (equal? (group-record-id record) id))
                *group-records*))
      (group-reshorten-path-names!)
      (desktop-dirty!)
      (modeline-groups-refresh!))))

;; Field 6 held a raw hex before it held a slot, and a hex cannot follow a
;; theme. A record written then takes the slot its hex stood for; a record
;; with no colour at all takes the slot its position gives it.
(define *group-colors-legacy*
  '("#d05a47" "#3f7cac" "#4f8a5b" "#9b6ab3" "#c28a2c" "#347f7a"))

(define (group-color-slot value index)
  (if (group-color-slot? value)
      value
      (let loop ((rest *group-colors-legacy*) (slot 1))
        (cond ((null? rest) (+ 1 (modulo index *group-colors*)))
              ((equal? (car rest) value) slot)
              (else (loop (cdr rest) (+ slot 1)))))))

(define (group-record-colors-restore records)
  (let loop ((rest records) (index 0) (out '()))
    (if (null? rest)
        (reverse out)
        (let* ((record (car rest))
               (slot (group-color-slot (group-record-color record) index)))
          (loop (cdr rest) (+ index 1)
                (cons (append (take record 6)
                              (list slot
                                    (group-record-parent record)
                                    (group-record-origin record)
                                    (group-record-settings record)))
                      out))))))

(define (group-state-restore! saved)
  (when (and (pair? saved) (pair? (cdr saved)))
    (set! *group-next-id* (car saved))
    (set! *group-records* (group-record-colors-restore (car (cdr saved))))
    (group-migrate-path-names!)
    (modeline-groups-refresh!)))

(define *group-frame-context-keys* '(current-group previous-group pinned-group))

(define (group-frame-style-set! frame value)
  (let* ((id (group-resolve-id value))
         (record (and id (group-record-by-id id))))
    (set-frame-group-style!
      (and record (group-display-label-in id frame))
      (and record (group-color-hex (group-record-color record)))
      frame)))

(define (group-frame-styles-refresh!)
  (for-each
    (lambda (frame)
      ;; the accent is read in the theme that frame wears
      (with-theme-frame frame
        (lambda () (group-frame-style-set! frame (frame-local-in frame 'current-group)))))
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

;; Registered before groups-v2, so it restores after it: the records are
;; already in place when the cache lands.
(persist-global! 'group-mru
  (lambda () *group-mru*)
  (lambda (saved)
    (when (pair? saved) (set! *group-mru* (take saved group-mru-limit)))))

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

;; the buffers a membership verb takes: ordinary work, and a chat. A chat
;; is not work, it is the conversation, but it belongs to a group the way
;; any buffer does (docs/groups.md), so it moves and it leaves.
(define (group-membership-buffer? b)
  (or (group-work-buffer? b) (chat-buffer? b)))

;; the group's own scratch, its blank pane. It refuses kill-buffer
;; while its group exists (docs/groups.md), but move and remove act on
;; it as its own buffer: the group recreates a blank pane when its
;; layout needs one.
(define (group-scratch-buffer? b)
  (let ((g (buffer-group b)))
    (and g (equal? (buffer-group-role b g) "scratch"))))

(define (buffer-context-only? b)
  (and (buffer-known? b)
       (equal? (buffer-local b 'context-only) #t)))

(define (buffer-context-only! b)
  (when (buffer-known? b)
    (buffer-set-local! b 'context-only #t))
  b)

(define (buffer-promote! b)
  (when (buffer-context-only? b)
    (buffer-set-local! b 'context-only #f))
  b)

(define (buffer-user-switchable? b)
  (and (group-work-buffer? b)
       (not (buffer-context-only? b))))

(define (group-migrate-chat-state! b id)
  (let ((record (group-record-by-id id)))
    (when (and record (not (group-record-meta record))
               (buffer-local b 'group-meta))
      (group-record-update! id 'meta (buffer-local b 'group-meta)))
    (when (buffer-local b 'group-noise)
      (group-record-update! id 'noise (buffer-local b 'group-noise)))
    (when (and record (not (group-record-primary-chat-id record)))
      (group-record-update! id 'primary-chat-id (chat-stable-id! b)))))

;; Every buffer, a chat or not, keeps its ONE group in 'group-id. The older
;; 'group and 'companion-of names are read once and folded in.
;;
;; The id a buffer holds may outlive the record. A read must never erase the membership: the record table can be
;; transiently wrong (a reload window, a stale lane view, a restore in
;; progress), and a clear here made every such moment a permanent loss.
;; An id that does not resolve is inert — the read answers #f and the
;; local keeps the id. Only group-kill! and group-dissolve! clear
;; members, and they sweep explicitly.
;; write a buffer's one group, in one change. A role is a role in one
;; group, so a move leaves it behind. The older names are cleared only
;; where a buffer still holds one: a buffer that never had them gains no key.
(define (buffer-group-store! b id)
  (buffer-set-locals! b
    (append (list 'group-id id)
            (if (and (buffer-local b 'group-roles)
                     (not (equal? (buffer-local b 'group-id) id)))
                (list 'group-roles #f)
                '())
            (if (buffer-local b 'group) (list 'group #f) '())
            (if (buffer-local b 'companion-of) (list 'companion-of #f) '()))))

(define (buffer-group-id-of b)
  (let ((held (buffer-local b 'group-id)))
    (cond
      (held
        (let ((valid (group-resolve-id held)))
          (when (and valid (not (equal? valid held)))
            (buffer-set-local! b 'group-id valid))
          valid))
      (else
        (let ((legacy (or (buffer-local b 'group) (buffer-local b 'companion-of))))
          (and legacy
               (let ((id (group-ensure-record! legacy)))
                 (buffer-group-store! b id)
                 (when (chat-buffer? b) (group-migrate-chat-state! b id))
                 id)))))))

(define (chat-group-id b) (buffer-group-id-of b))

;; the groups a work buffer is in, as a list of the one; a chat answers none
;; here, its group is chat-group-id's
(define (buffer-group b)
  ;; one group, in one field, whatever the buffer is
  (buffer-group-id-of b))

;; ALWAYS a string. This is a marginalia field, and marginalia measures
;; its columns with string-length: one #f here breaks the annotation of
;; every candidate beside it. A buffer can name a group whose record is
;; gone, and group-name answers #f for that id — so drop the nameless
;; ones rather than pass them on.
(define (buffer-group-summary b)
  (let ((id (buffer-color-group b)))
    (let ((name (and id (group-display-label id))))
      (if (string? name) name "ungrouped"))))

;; Names and the primary membership color are cached for the render path.
;; The compact label is frame-relative. The color always belongs to the buffer.
(define (buffer-modeline-group-refresh! b)
  (let* ((group (buffer-color-group b))
         (name (let ((n (and group (group-name group)))) (and (string? n) n)))
         (record (and group (group-record-by-id group)))
         (color (and record (group-color-hex (group-record-color record)))))
    (modeline-cache-set! b 'group name 'group-color color)
    name))

;; A membership change rewrites the headline too: its group segment reads
;; the buffer's own group. post-command! syncs the buffer the
;; command ran in and no other, and a move takes every marked buffer at
;; once — the rest kept drawing the group they had just left. The sweep
;; above stays out of this: it runs over every buffer there is, and a
;; dashboard apiece is what made a keystroke cost 175ms once.
(define (buffer-group-display-refresh! b)
  (buffer-modeline-group-refresh! b)
  ;; A compound move refreshes after entering its final group. A hidden
  ;; buffer catches up when shown, rather than building an unseen dashboard.
  (if (or *group-current-inhibit*
          (not (member b (map cadr (window-list-all)))))
      (buffer-mark-dirty! b 'group-display)
      (begin
        (buffer-clear-dirty! b 'group-display)
        (dashboard--sync! b))))

;; a move under *group-current-inhibit* marks the buffer again, so it
;; waits for the next show after the move
(define (group--display-on-refresh! b keys)
  (when (memq 'group-display keys)
    (buffer-group-display-refresh! b)))

(add-hook! 'buffer-refresh-hook 'group--display-on-refresh!)

(define (modeline-groups-refresh!)
  ;; the list can name a buffer that sleeps or died: a local set there exits
  (for-each buffer-modeline-group-refresh! (filter buffer-exists? (buffer-list)))
  #t)

;; Install derived color locals for buffers that predate this package reload.
(modeline-groups-refresh!)

(define (buffer-in-group? b value)
  (let ((id (group-resolve-id value)))
    (and id (equal? (buffer-color-group b) id))))

;; buffer-joined-group!: B is in group ID now, by any way in. Every join
;; passes here: the group's config takes the buffer (group-config.scm),
;; and group-joined-hook runs with (B ID).
(define (buffer-joined-group! b id)
  (when (boundp 'group-configure-buffer!)
    (group-configure-buffer! b))
  (run-hook-with-args 'group-joined-hook b id))

(define (chat-set-group! b value)
  (let ((id (and value (group-ensure-record! value))))
    ;; Publish ownership atomically; readers never see half a move.
    (buffer-group-store! b id)
    (buffer-group-display-refresh! b)
    (group-current-recalculate!)
    ;; the group's shared config is the chat's starting setup: what the
    ;; user has already chosen here stays (group-config.scm)
    (when id (buffer-joined-group! b id))
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
          ;; a chat holds ONE group and only `move` changes it: joining is
          ;; how a new chat gets its group, never how a live one travels.
          ((chat-buffer? b)
           (if (chat-group-id b) #f (chat-set-group! b id)))
          ;; already a member: nothing moves, the label still refreshes
          ((buffer-in-group? b id)
           (buffer-group-display-refresh! b)
           id)
          ;; ONE group at a time. Joining is leaving: a buffer that lived
          ;; somewhere else moves here rather than answering two questions
          ;; about where it lives. Only an explicit verb gets this far.
          (else
            ;; the store takes the roles it left with it
            (buffer-group-store! b id)
            (buffer-group-display-refresh! b)
            (group-current-recalculate!)
            ;; joining is adopting: the group's config is this buffer's
            ;; default now (group-config.scm)
            (buffer-joined-group! b id)
            id))))

(define (buffer-add-group-as! b value role)
  (let ((id (buffer-add-group! b value)))
    (and id (buffer-set-group-role! b id role) id)))

(define (buffer-move-to-group! b value)
  (let ((id (and value (group-ensure-record! value))))
    (if (chat-buffer? b)
        (chat-set-group! b id)
        (begin
          (buffer-group-store! b id)
          (buffer-group-display-refresh! b)
          ;; the destination's config takes over from the old group's
          (when id (buffer-joined-group! b id))))
    (group-current-recalculate!)
    id))

(define (buffer-remove-group! b value)
  (let ((id (group-resolve-id value)))
    (when id
      (when (equal? (buffer-group-id-of b) id)
        (buffer-group-store! b #f))
      (buffer-group-display-refresh! b))
    (group-current-recalculate!)))

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
  (let ((short (group-short-name g)))
    (cond ((equal? short "") "")
          ((group-pinned? g) (string-append short " " *group-pin-icon*))
          (else short))))


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

;; The parent is the group a pop-out came from. Only a live parent counts:
;; a dissolved or renamed-away parent makes the child an ordinary group.
(define (group-parent g)
  (let ((record (and (group-resolve-id g)
                     (group-record-by-id (group-resolve-id g)))))
    (and record (group-resolve-id (group-record-parent record)))))

(define (group-parent-set! g parent)
  (let ((id (group-resolve-id g)))
    (when id (group-record-update! id 'parent (group-resolve-id parent)))))

;; The record's tenth field is the extension slot. Group parentage is a
;; field of its own, and anything that hangs off a group but has not
;; earned a field lives here, as a plist of SYMBOL VALUE pairs. One
;; store, so a reader never has to ask a second one.
(define (group-setting-plist g)
  (let* ((id (group-resolve-id g))
         (record (and id (group-record-by-id id)))
         (settings (and record (group-record-settings record))))
    (if (pair? settings) settings '())))

(define (group-setting g key)
  (let loop ((rest (group-setting-plist g)))
    (cond ((null? rest) #f)
          ((null? (cdr rest)) #f)
          ((equal? (car rest) key) (car (cdr rest)))
          (else (loop (cdr (cdr rest)))))))

(define (group-setting-set! g key value)
  (let ((id (group-resolve-id g)))
    (when id
      (let loop ((rest (group-setting-plist g)) (kept '()))
        (cond ((or (null? rest) (null? (cdr rest)))
               (group-record-update! id 'settings
                 (append (reverse kept) (list key value))))
              ((equal? (car rest) key) (loop (cdr (cdr rest)) kept))
              (else (loop (cdr (cdr rest))
                          (cons (car (cdr rest)) (cons (car rest) kept)))))))
    id))


;; --- Workspaces: a group belongs to one frame -----------------------------
;; A frame is a workspace. The group a frame founds is that frame's own, so
;; the rail, the tabs and the switcher of another frame stay clean of work
;; you did somewhere else. A group whose frame is gone belongs to no one:
;; the next frame to enter it adopts it, so a closed window strands nothing.

(define (group-frame-owner g)
  (group-setting g 'frame))

(define (group-frame-alive? frame)
  (and frame (member frame (frame-list)) #t))

(define (group-frame-own! g frame)
  (let ((id (group-resolve-id g)))
    (when (and id frame) (group-setting-set! id 'frame frame))
    id))

(define (group-frame-isolating? frame)
  ;; an isolated live frame keeps the groups it owns to itself
  (and (group-frame-alive? frame) (frame-local-in frame 'isolated) #t))

(define (group-unowned? g)
  ;; a group made before workspaces, or one whose frame has gone
  (not (group-frame-alive? (group-frame-owner g))))

(define (group-of-frame? g frame)
  ;; frames share every group. Only isolation separates them: an isolated
  ;; frame shows only the groups it owns, and keeps them from the others.
  (let ((owner (group-frame-owner g)))
    (or (equal? owner frame)
        (and (not (group-frame-isolating? owner))
             (not (frame-local-in frame 'isolated))))))

(define (group-here? g)
  (group-of-frame? g (selected-frame)))

(define (group-elsewhere-frame g)
  ;; the live frame that owns G, when that frame is not this one and
  ;; isolation keeps G there
  (let ((owner (group-frame-owner g)))
    (and (group-frame-alive? owner)
         (not (equal? owner (selected-frame)))
         (or (group-frame-isolating? owner) (frame-isolated?))
         owner)))

(define (group-adopt-here! g)
  ;; entering an unowned group makes it this workspace's own
  (let ((id (group-resolve-id g)))
    (when (and id (group-unowned? id)) (group-frame-own! id (selected-frame)))
    id))

(define (frame-isolated?)
  ;; an isolated frame shows only the groups it owns
  (and (frame-local 'isolated) #t))

(define-command "frame-isolate"
  "Toggle whether this frame shows only its own groups and wears its own theme"
  (lambda ()
    (if (frame-isolated?)
        (begin
          (set-frame-local! 'isolated #f)
          ;; its own theme goes with it
          (frame-theme-apply! #f)
          (desktop-dirty!)
          (frame-group-label-refresh!)
          (message "Frame shares groups again"))
        (let ((id (frame-group)))
          ;; the group in view comes along, so the frame is never empty
          (when id (group-frame-own! id (selected-frame)))
          (set-frame-local! 'isolated #t)
          (desktop-dirty!)
          (frame-group-label-refresh!)
          (message "Frame isolated: only its own groups")))))

(define (group-frame-raise! frame)
  ;; a frame that lives in a browser tab comes to the front by its tab. No
  ;; other client can be raised from here yet, so say so and move nothing.
  (if (not (browser-connected?))
      (begin (message "That group is open in another window") #f)
      (begin
        (browser-frames
          (lambda (bound)
            (let loop ((rest bound))
              (cond ((null? rest)
                     (message "That group is open in another window"))
                    ((equal? (plist-get (car rest) 'frame) frame)
                     (tab-activate (plist-get (car rest) 'tab)))
                    (else (loop (cdr rest)))))))
        #t)))

;;; --- frame names, and groups that move between frames ----------------------

;; frame id -> the name the user gave it. A client reattaches to its frame
;; id after a restart, so the name lasts as long as the frame does.
(define *frame-names* '())

(define (frame-name &optional frame)
  (let ((kv (assoc (or frame (selected-frame)) *frame-names*)))
    (and kv (cadr kv))))

(define (frame-label frame)
  (or (frame-name frame) frame))

(define (frame-name-set! frame name)
  ;; an empty name gives the frame back its id
  (set! *frame-names*
    (append (if (and (string? name) (not (equal? name "")))
                (list (list frame name))
                '())
            (remove (lambda (e) (equal? (car e) frame)) *frame-names*)))
  (desktop-dirty!)
  (frame-name frame))

(define (frame-by-label label)
  (let loop ((frames (frame-list)))
    (cond ((null? frames) #f)
          ((equal? (frame-label (car frames)) label) (car frames))
          (else (loop (cdr frames))))))

(persist-global! 'frame-names
  (lambda () *frame-names*)
  (lambda (saved) (set! *frame-names* (if (list? saved) saved '()))))

(define (frame-targets)
  ;; the other frames a group can go to: the ones a client shows, or named
  (let ((here (selected-frame)))
    (filter (lambda (f)
              (and (not (equal? f here))
                   (or (> (frame-clients f) 0) (frame-name f))))
            (frame-list))))

(define (group-in-frame! frame thunk)
  ;; run THUNK as FRAME's own work, then come back
  (let ((home (selected-frame)))
    (select-frame! frame)
    (unwind-protect (lambda () (with-frame-windows thunk))
      (lambda () (select-frame! home)))))



(define (group-move-to-frame! g frame)
  ;; G belongs to FRAME and FRAME stands in it. A frame that stands in G
  ;; too keeps it: frames share groups.
  (let ((id (group-resolve-id g)))
    (when id
      (group-frame-own! id frame)
      (group-in-frame! frame (lambda () (switch-to-group! id)))
      (desktop-dirty!))
    id))

(define (group-take-rows)
  ;; (LABEL ID) for every group another live frame keeps
  (let loop ((ids (group-ids-mru-all)) (out '()))
    (if (null? ids)
        (reverse out)
        (let ((away (group-elsewhere-frame (car ids))))
          (loop (cdr ids)
                (if away
                    (cons (list (string-append (group-name (car ids)) " — " (frame-label away))
                                (car ids))
                          out)
                    out))))))

(define-command "frame-rename" "Name this frame; an empty name gives it back its id"
  (lambda ()
    (minibuffer-read "Frame name: " '()
      (lambda (name)
        (frame-name-set! (selected-frame) name)
        (message (if (frame-name)
                     (string-append "Frame named " (frame-name))
                     "Frame name cleared"))))))

(define-command "group-take" "Move a group another frame keeps into this frame"
  (lambda ()
    (let ((rows (group-take-rows)))
      (if (null? rows)
          (message "No other frame keeps a group")
          (minibuffer-read "Take group: " (map car rows)
            (lambda (label)
              (let ((row (assoc label rows)))
                (if row
                    (group-move-to-frame! (cadr row) (selected-frame))
                    (message "No such group")))))))))

(define-command "group-send-to-frame" "Move this frame's group to another frame"
  (lambda ()
    (let ((id (frame-group))
          (targets (frame-targets)))
      (cond ((not id) (message "This frame stands in no group"))
            ((null? targets) (message "No other frame"))
            (else
              (minibuffer-read "Send group to frame: " (map frame-label targets)
                (lambda (label)
                  (let ((frame (frame-by-label label)))
                    (if frame
                        (begin (group-move-to-frame! id frame)
                               (message (string-append "Sent " (group-name id)
                                                       " to " (frame-label frame))))
                        (message "No such frame"))))))))))

;; A group's layout is its window model (panes.scm): the newest layout of
;; the group on any frame, kept in its record. A record from before holds a
;; window tree, which reads as none. The model holds buffer ids, so a
;; rename needs nothing.
(define (group-layout g)
  (let* ((id (group-resolve-id g))
         (record (and id (group-record-by-id id)))
         (saved (and record (group-record-layout record))))
    (and (pair? saved) (panes-layout? saved) (pair? (plist-get saved 'panes)) saved)))

(define (group-layout-set! g layout)
  (let ((id (group-resolve-id g)))
    (when (and id (pair? layout) (panes-layout? layout))
      (group-record-update! id 'layout (panes-strip-handles layout)))
    layout))

;; the frame's model of G becomes G's layout
(define (group-layout-save! g)
  (let* ((id (group-resolve-id g)) (l (and id (panes-layout-of id))))
    (and l (group-layout-set! id l))))




;; a group's window arrangement rides its chat too, as one opaque
;; window-tree value: capture on leave, restore on switch




;; switch the frame to a group: save the layout you leave, then bring
;; the group's saved layout back exactly as you left it. A group with
;; no saved layout opens its most recent member full-frame.
;; a group that never saved a layout still ARRIVES arranged: its most
;; recent work buffers fill the frame's target layout (three columns by
;; default), with the group chat last when its noise is "loud". One
;; member alone fills the frame. A scratch is never a pane.
;; the buffers a group with no saved layout shows, left to right: its
;; documents up to the layout's capacity, its chat beside them when the group
;; is loud, the chat alone when it has no documents, *scratch* when it has nothing
(define (group-default-panes g)
  (let* ((docs (filter group-primary-fill? (group-docs g)))
         (chat (if (pair? docs) (group-primary-chat g) (group-chat g)))
         (loud (and chat (pair? docs) (equal? (group-noise g) "loud")))
         (capacity (or (and (panes-current-layout) (panes-layout-capacity (panes-current-layout))) 2))
         (work (take docs (min (length docs) (if loud (- capacity 1) capacity)))))
    (cond ((pair? work) (if loud (append work (list chat)) work))
          (chat (list chat))
          (else
            (unless (buffer-exists? "*scratch*")
              (buffer-create "*scratch*"))
            (list "*scratch*")))))


;; a restored window whose buffer is an empty, unmodified, pathlike
;; shell — and whose file exists — re-reads from disk. The layout
;; recreated the NAME; the content lives in the file.


;; Answers #t when every pane it saw already belonged to the group, #f
;; when it had to evict one. A caller that saves the layout back must ask:
;; an eviction is a LOSS, and writing it over the saved tree makes one
;; visit destroy the arrangement for good.
(define (group-restore-sanitize! g)
  (let* ((id (group-resolve-id g))
         (clean #t)
         (members (group-user-buffers-mru id))
         (pool (if (pair? members) members (list (group-chat id))))
         (shown
           (filter (lambda (buf) (buffer-in-group? buf id))
                   (map cadr (window-list)))))
    (for-each
      (lambda (window)
        (let ((win (car window))
              (buf (cadr window)))
          (set-window-prev-buffers! win (window-eligible-history win))
          (let ((rec (window-restore win)))
            (when (and rec (equal? (car rec) 'other)
                       (not (window-history-member? win (cadr rec))))
              (set-window-restore! win #f)))
          (unless (buffer-in-group? buf id)
            (set! clean #f)
            ;; the fill rule picks; sealed: with no member to show, the
            ;; pane goes rather than show a foreign buffer
            (let* ((action (window-fill-decide
                             (list 'shown shown
                                   'others (> (length (window-list)) 1))
                             pool))
                   (what (car action)))
              (cond ((equal? what 'show)
                     (window-set-buffer! win (cadr action))
                     (set! shown (cons (cadr action) shown)))
                    ((equal? what 'delete)
                     (delete-window-id! win))
                    (else
                     (window-set-buffer! win (car pool))))))))
      (window-list))
    clean))

;; Scheme owns both sides of the modeline's group context: the frame's current
;; group name and every buffer's membership names. The renderer only compacts
;; those facts for the width available in the bar.
(define (frame-group-label-refresh!)
  (group-frame-style-set! (selected-frame) (frame-local 'current-group))
  (modeline-groups-refresh!))

;; a reattached frame keeps its group in *frame-locals*, but the Elixir
;; frame behind it is new and its label is empty — so push it on attach
;; A group's colour is a slot, so a theme switch changes the hex the frame
;; style and the modeline locals hold. Both are caches; re-derive them.
(define (group-colors-retheme!)
  (group-frame-styles-refresh!)
  (modeline-groups-refresh!))

(add-hook! 'theme-change-hook 'group-colors-retheme!)
(add-hook! 'frame-attach-hook 'frame-group-label-refresh!)

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

;; App windows are identified by app-id.
;; An app can assign the same id to its listing, detail, and auxiliary buffers.
(domain! 'windows)
(effects! '(read))
(define (app-windows id)
  "Return visible windows whose buffers belong to app ID."
  (filter (lambda (row)
            (equal? (app-id (cadr row)) id))
          (window-list)))

(domain! 'buffers)
(effects! '(write display))
(define (app-move-buffers id destination)
  "Move every known buffer of app ID to DESTINATION, including visible app windows."
  (let ((buffers (filter (lambda (buf)
                           (and (buffer-known? buf)
                                (equal? (app-id buf) id)))
                         (buffer-list))))
    (group-move-buffers-to! buffers destination)
    buffers))

(define *scenes* '())             ; ((group-name spec) ...) — by NAME, not id:
                                  ; a declaration outlives the record it names

(define (define-scene! name spec)
  (set! *scenes* (alist-put *scenes* name spec))
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
(define (scene-open! name &optional destination)
  (let ((spec (scene-spec name)))
    (if (not spec)
        (begin (message (string-append "No scene named " name)) #f)
        (let* ((from (frame-group))
               (target (if (equal? destination "") from (or destination name)))
               (id (and target (group-ensure-record! target)))
               ;; An ungrouped scene has no group companion to materialise.
               (spec (if id spec
                         (append (list (car spec) (cadr spec))
                           (filter (lambda (pane)
                                     (not (equal? (scene--declared-pane pane) 'group-chat)))
                                   (cddr spec))))))
          ;; leaving a group snapshots it, exactly as switching does: the
          ;; way back to where you were must stay exact
          (when (and from (not (equal? from id))) (group-frame-leave! from))
          (set-frame-local! 'current-group id)
          (frame-group-label-refresh!)
          (let* ((resolved (scene--resolve id spec))
                 (anchor (layout--pane #f (car (cdr (cdr resolved)))))
                 (panes (apply-layout! anchor resolved)))
            ;; a pane the scene built is a member by construction
            (when id
              (for-each (lambda (b)
                          (if (chat-buffer? b)
                              (chat-set-group! b id)
                              (buffer-add-group! b id)))
                        panes))
            ;; `as` is a role on this buffer's membership in this group.
            ;; Bind after the layout has materialised every ensure pane.
            (for-each
              (lambda (declared)
                (let* ((role (scene--role declared))
                       (pane (scene--pane id declared))
                       (buf (and role (layout--pane anchor pane))))
                  (when (and id buf)
                    (if (chat-buffer? buf)
                        (chat-set-group! buf id)
                        (buffer-add-group-as! buf id role)))))
              (cdr (cdr spec)))
            (when id (group-mru-note! id))
            (windows-shown-catchup!)
            panes)))))

(define-command "scene" "Open a declared scene: its group, its arrangement"
  (lambda ()
    (let ((names (scene-names)))
      (if (null? names)
          (message "No scenes declared")
          (minibuffer-read "Scene: " names scene-open!)))))

(public! 'define-scene! "(define-scene! NAME SPEC) — declare a group's arrangement; write each pane as (as ROLE PANE), where PANE is \"NAME\", (ensure \"NAME\" \"COMMAND\"), or group-chat")
(public! 'scene-open! "(scene-open! NAME [DESTINATION]) — build the scene in DESTINATION; omitted uses NAME, empty uses the current group")


(define *group-current-inhibit* #f)

;; #t while a look is on screen. The inhibit above covers the draw; this
;; covers the whole time the look stays up, which is when the damage was
;; done: the frame's windows then say nothing about the group you stand in,
;; and every notification that reads them would move you into the group you
;; are merely looking at -- and save layouts under that answer.
(define *group-look-active* #f)

;; The groups stack in the order of their tabs, so a switch moves the
;; whole desk: to a later tab it goes down, to an earlier one up. A
;; group without a tab is new, and comes from below.
(define (group-slide-direction from to)
  (let walk ((ids (map car (car (frame-tabs)))))
    (cond ((null? ids) "down")
          ((equal? (car ids) to) (if (member from (cdr ids)) "up" "down"))
          ((equal? (car ids) from) "down")
          (else (walk (cdr ids))))))

;; the frame takes the layout of group ID: SAVED, the arrangement the group
;; kept, or the default. The one seam every restore goes through, so the
;; window model (panes-mode.scm) arranges the group's windows here instead of
;; rebuilding them
(define (group-layout-enter! id saved)
  ;; the frame shows group ID: its model on this frame, else its layout
  ;; (the record; SAVED is the same), else a default layout of its
  ;; members. The windows of the group it leaves wait hidden; none dies
  (window-log-note! "panes enter group" id)
  (cond ((panes-layout) (panes-apply! (panes-validate (panes-layout) buffer-known?)))
        ((panes--seed! id))
        (else (panes-apply! (panes--default-layout (group-default-panes id)))))
  (layout-modeline!))

(define (switch-to-group! g)
  (let ((id (begin (group-migrate-live!) (group-resolve-id g))))
    (if (not id)
        (message "No such group")
        (begin
          ;; a group no live frame owns joins the workspace that enters it
          (group-adopt-here! id)
          (set! *group-current-inhibit* #t)
          (let ((from (frame-group)))
            (when (and from (not (equal? from id)))
              ;; a switch the switcher previewed is on screen already
              (unless (group-preview-shown? id)
                (client-slide! (group-slide-direction from id)))
              (group-frame-leave! from)))
          (set-frame-local! 'current-group id)
          ;; An explicit switch moves an active pin. The frame stays pinned,
          ;; but it does not trap the user in the old group.
          (when (group-pinned) (set-frame-local! 'pinned-group id))
          ;; a switch changes no buffer's group, name or color: the frame's
          ;; style is all that moves, not every buffer's modeline label
          (group-frame-style-set! (selected-frame) id)
          (group-layout-enter! id (group-layout id))
          (set! *group-current-inhibit* #f)
          (group-current-recalculate!)
          (group-mru-note! id)
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

(define (group-context-group buf)
  ;; the group a pane shows: a chat's own, a work buffer's one group, or #f
  ;; for a work buffer in none.
  (cond ((chat-buffer? buf) (chat-group-id buf))
        ((group-work-buffer? buf) (buffer-group buf))
        (else 'outside)))

;; A float is a visit, not a place: a card or a prompt's table floating
;; over the group's panes says nothing about the group the frame is in.
(define (group-visible-groups)
  ;; the group of every pane that takes part, in window order
  (let ((float (float-window)))
    (filter (lambda (g) (not (eq? g 'outside)))
            (map (lambda (window)
                   (if (or (equal? (car window) float)
                           (float--class? (car (cdr window))))
                       'outside
                       (group-context-group (car (cdr window)))))
                 (window-list)))))

(define (group-visible-common rows)
  ;; #f when no pane takes part; the one group every pane shows; else 'none
  (cond ((null? rows) #f)
        ((and (car rows)
              (null? (filter (lambda (g) (not (equal? g (car rows)))) (cdr rows))))
         (car rows))
        (else 'none)))

(define (group-current-choice common current)
  (cond ((not common) current)
        ((eq? common 'none) #f)
        (else common)))

;; #t when ID is a pseudo group and every pane shows a member of it
(define (group-pseudo-here? id)
  (and (pseudo-group-id? id)
       (let ((members (pseudo-group-buffers id))
             (float (float-window)))
         (let loop ((rows (window-list)))
           (cond ((null? rows) #t)
                 ((or (equal? (car (car rows)) float)
                      (float--class? (cadr (car rows))))
                  (loop (cdr rows)))
                 ((member (cadr (car rows)) members) (loop (cdr rows)))
                 (else #f))))))

(define (group-current-recalculate!)
  ;; A look is not your work. While one is on screen nothing it shows is
  ;; promoted, entered, or saved: you are standing where you were standing.
  (if *group-look-active*
      (frame-group)
      (begin
        ;; A buffer shown by any path is no longer context-only.
        (for-each (lambda (row) (buffer-promote! (cadr row))) (window-list))
        (unless *group-current-inhibit*
          (let* ((pinned (group-pinned))
                 (rows (group-visible-groups))
                 (current (frame-group))
                 (next (cond (pinned pinned)
                             ;; A pseudo group holds the frame while its
                             ;; members fill the panes. The members carry
                             ;; no mark, so the rows above cannot see it.
                             ((group-pseudo-here? current) current)
                             (else (group-current-choice
                                     (group-visible-common rows) current)))))
            (unless (equal? next current)
              ;; Leaving a group because a pane shows a foreign buffer saves the
              ;; layout as it is, foreign pane and all (docs/groups.md, Save):
              ;; a switch from a frame in no group has nothing to save, and
              ;; coming back must find what you had.
              (when (and current (not next)) (group-frame-leave! current))
              (set-frame-local! 'current-group next)
              (frame-group-label-refresh!))
            next)))))

(add-hook! 'window-state-change-hook 'group-current-recalculate!)

;;; --- go to a buffer where it lives ----------------------------------------------
;;; A list says "take me to this buffer". The buffer can belong to
;;; another group, and a switch alone would show it as a foreign buffer
;;; over the group the frame stands in. The frame enters the buffer's
;;; group first, so the buffer takes a pane of its own group. A buffer
;;; of the current group, and a buffer no group holds, opens where it is.

;; "here" for a verb run from a list. A table of buffers belongs to no
;; group, so showing one takes the frame out of the group the verb
;; means: the group it last left is that group.
(define (group-here)
  (let loop ((ids (append (list (frame-group) (frame-local 'previous-group))
                          (group-ids-mru))))
    (if (null? ids)
        #f
        ;; the MRU keeps ids whose record is gone: a name that resolves
        ;; now is the only one a verb can act on
        (let ((id (and (car ids) (group-resolve-id (car ids)))))
          (if id id (loop (cdr ids)))))))

;; the group to enter for B: the one at hand when B is a member of it,
;; else B's first membership, else #f
(define (group-home-of b)
  (let ((g (group-context-group b)))
    (and (not (eq? g 'outside)) g)))

;; An explicit pick goes to the pane that prefers its mode, else this one.
;; Nothing swaps: the panes stay where they are.
(define (switch-to-buffer-in-chosen-pane! b)
  (let ((home (group-home-of b)))
    (when (and home (not (equal? home (frame-group))))
      (switch-to-group! home))
    (begin
      (let* ((pane (active-window))
             (mode (buffer-local b 'mode-name))
             (preferred (or (window-showing-mode mode) (window-showing b))))
        (when (and preferred (not (equal? preferred pane)))
          (select-window! preferred))
        (switch-to-buffer-here! b)
        (set-window-restore! (active-window) #f)
        (active-window)))))

(public! 'switch-to-buffer-in-chosen-pane!
  "(switch-to-buffer-in-chosen-pane! BUFFER) — explicit choice: show BUFFER in the pane that prefers its mode, else this one, within BUFFER's group; no pane moves")

(define (switch-to-buffer-in-group! b)
  (let ((id (group-home-of b)))
    (when (and id (not (equal? id (frame-group))))
      (switch-to-group! id))
    (let ((w (window-showing b)))
      (if (and w (window-exists? w))
          (select-window! w)
          (switch-to-buffer! b)))
    id))

;;; --- a sealed group ---------------------------------------------------------------
;;; A display of a buffer from outside the group is a display of category
;;; foreign (docs/DISPLAY-BUFFER.md). A pinned frame keeps the old way and
;;; shows a foreign buffer in the selected window.

;; BUF would take the frame out of its group if a pane showed it
(define (group-foreign-buffer? buf)
  (let ((id (frame-group)))
    (and id
         (not (group-pinned))
         (not *group-current-inhibit*)
         (not (float--class? buf))
         (let ((g (group-context-group buf)))
           (and (not (eq? g 'outside)) (not (equal? g id)))))))

;; through the name, so a reload of the predicate reaches the seam
(set! display-foreign? (lambda (name) (group-foreign-buffer? name)))

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

;; The group a buffer created now joins: the group of the buffer shown
;; in the window that ran the command, and the frame's group only when
;; that buffer has none. One rule decides every spawn; a package that
;; makes a buffer by hand asks here instead of reading the frame's group.
(define (group-spawn-target &optional buf)
  (let ((here (current-buffer)))
    (or (and here
             (not (equal? here buf))
             (buffer-known? here)
             (buffer-group here))
        (frame-group))))

(public! 'group-spawn-target
  "(group-spawn-target [BUF]) -> the group a new buffer joins: the group of the buffer in the window that made it, else the frame's group")
(catalog-meta! 'function "group-spawn-target" 'domain 'buffers 'effects '(read))

(define (buffer-join-here! buf)
  ;; A buffer opens in the group it was launched from: the group of the
  ;; window that opened it, else the frame's. It joins that group on the way
  ;; in, so nothing you open carries the frame off to another group's saved
  ;; layout. A special view answers no membership, and a chat keeps the group
  ;; that is its identity, so neither joins.
  (let ((id (and (not *group-current-inhibit*) (group-spawn-target buf))))
    (and id
         (buffer-known? buf)
         (not (chat-buffer? buf))
         (not (eq? (group-context-group buf) 'outside))
         (not (buffer-in-group? buf id))
         (buffer-add-group! buf id))))

(public! 'buffer-join-here!
  "(buffer-join-here! BUF) -> put BUF in the group it was launched from; the group id, or #f when it cannot join")
(catalog-meta! 'function "buffer-join-here!" 'domain 'buffers 'effects '(write))

;; Creation is the shared placement boundary. Commands do not each need to
;; remember this rule, and waking a dormant buffer does not run the hook.
;; A new buffer joins the group of the window that made it. That membership is
;; INHERITED: nobody asked for it, and a board or a listing sheds it
;; before it covers the group's pane. A membership a package asks for is
;; not inherited, and every explicit path below clears the mark.
(add-hook! 'buffer-created-hook
  (lambda (buf)
    ;; A new buffer lands where the work that opened it lives: the group
    ;; of the buffer shown in the window that ran the command, and the
    ;; frame's group only when that buffer has none. An agent's chat is a
    ;; current buffer like any other, so a file it opens joins the chat's
    ;; group.
    (let ((group (group-spawn-target buf)))
      (when (and group (group-work-buffer? buf))
        (buffer-add-group! buf group)))
    ;; A buffer an agent makes is the agent's work, in a group or not. It
    ;; stays out of the user's walk and fill until something shows it.
    (when (and (group-work-buffer? buf)
               (agent-edit-author? (current-edit-author)))
      (buffer-context-only! buf))))

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
             (equal? (group-visible-common (group-visible-groups)) id)))))

;; the frame leaves FROM: FROM's frame, sizes and selected window with it,
;; is saved as the one record a return puts back, and FROM becomes the
;; previous group
(define (group-frame-leave! from)
  (when (and from (group-resolve-id from)) (group-layout-save! from))
  (set-frame-local! 'previous-group from))

;; a group is UNCOVERED when no window is holding another buffer's place
;; for it. Its own members may be special surfaces too (a mail view, a
;; dired listing), and those are part of the group's arrangement rather
;; than a cover on it.
(define (group-uncovered? g)
  ;; Emacs asks the WINDOW, not the buffer. quit-restore records what a
  ;; display did: 'other means it took a window that was showing something
  ;; else, which is exactly what a cover is, and quit-window is waiting to
  ;; put the old buffer back. A pane that belongs to g is not covering g.
  (let loop ((windows (window-list)))
    (cond ((null? windows) #t)
          ((let* ((row (car windows))
                  (rec (window-restore (car row))))
             (and rec
                  (equal? (car rec) 'other)
                  (not (buffer-in-group? (cadr row) g))))
           #f)
          (else (loop (cdr windows))))))

;; found a group from what is on screen: every window's buffer joins,
;; the layout is saved, and the group chat holds the durable state
(define (group-found-from-windows! name)
  ;; the windows as they stand found the group: their buffers, chats too,
  ;; MOVE into it, and the screen is adopted as its layout. Adding left
  ;; them in the old group as well, so both groups came out mixed, and a
  ;; chat that already had a group refused the add and stayed behind.
  (let ((clean (string-trim name)))
    (cond ((equal? clean "")
           (message "Group needs a name")
           #f)
          ((group-record-by-name clean)
           (message (string-append "Group " clean " already exists"))
           #f)
          (else
            (let ((id (group-record-create! clean)))
              (group-move-into! (group-visible-work-buffers) id #t)
              id)))))

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

;; C-c d from a grouped buffer; in the board, the marked groups or the row
(define-command "group-describe"
  "Ask the LLM to write this group's description"
  (lambda ()
    (if (in-groups-board?)
        (groups--act! "describing" group-describe!)
        (let ((g (buffer-group (current-buffer))))
          (if g (group-describe! g) (message "Not in a group"))))))

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
                  (string-join (map buffer-short-label (take members 3)) " · ")
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
(define (group-ids-mru-split)
  ;; (MINE AWAY), both in MRU order: MINE is the groups this frame shows,
  ;; every group unless isolation separates it; AWAY is the groups another
  ;; live frame owns and isolation keeps from this one
  ;;
  ;; The frame tab bar calls this on every render, so it settles the frame
  ;; once for the whole pass and reads the records in one sweep. Going
  ;; through group-here? per id cost two linear scans of the group records
  ;; each -- group-setting resolves the id and then looks the record up
  ;; again -- plus a frame-list call per group, to decide which of them may
  ;; appear in a bar of frame-tabs-limit slots.
  (let* ((here (selected-frame))
         (frames (frame-list))
         (isolated (frame-isolated?))
         (isolating (filter (lambda (f) (frame-local-in f 'isolated)) frames))
         (owner-of (lambda (record)
                     (let loop ((rest (group-record-settings record)))
                       (cond ((not (pair? rest)) #f)
                             ((null? (cdr rest)) #f)
                             ((equal? (car rest) 'frame) (cadr rest))
                             (else (loop (cddr rest)))))))
         (mine '())
         (away '()))
    (for-each (lambda (record)
                (let* ((owner (owner-of record))
                       (alive (and owner (member owner frames) #t))
                       (kept (and alive (member owner isolating) #t)))
                  (cond ((or (equal? owner here) (and (not isolated) (not kept)))
                         (set! mine (cons (group-record-id record) mine)))
                        (alive (set! away (cons (group-record-id record) away))))))
              *group-records*)
    (let ((all (group-ids-mru-all)))
      (list (filter (lambda (id) (and (member id mine) #t)) all)
            (filter (lambda (id) (and (member id away) #t)) all)))))

(define (group-ids-mru)
  (car (group-ids-mru-split)))

(define (group-mru-note! value)
  (let ((id (group-resolve-id value)))
    ;; a walk of the tabs looks at groups; only where it lands counts
    (when (and id (not (frame-local 'tab-walk)))
      (set! *group-mru*
            (take (cons id (remove (lambda (x) (equal? x id)) *group-mru*))
                    group-mru-limit))
      (desktop-dirty!)
      (mru-note-group! id))
    id))

;; the cached order, minus the groups that have since been deleted
(define (group-mru-ids)
  (filter (lambda (id) (and (group-record-by-id id) #t)) *group-mru*))

;; the group marks left in the shared buffer/group ring. A group switched
;; to before this cache existed is only found here.
(define (group-mru-history-ids)
  (let loop ((rows (mru-list)) (found '()))
    (if (null? rows)
        (reverse found)
        (let* ((row (car rows))
               (id (and (equal? (car row) "group")
                        (group-resolve-id (car (cdr row))))))
          (loop (cdr rows)
                (if (and id (not (member id found)))
                    (cons id found)
                    found))))))

(define (group-ids-mru-all)
  (let* ((cached (group-mru-ids))
         (stream (filter (lambda (id) (not (member id cached)))
                         (group-mru-history-ids)))
         (recent (append cached stream)))
    (append recent
            (filter (lambda (id) (not (member id recent))) (group-ids)))))

;; The active groups: every group with an open buffer, in the order the
;; MRU gives (most recent first, then creation order). Derived from the
;; buffers on every call and never stored: the buffer list already knows
;; every open buffer, and each buffer knows its groups. The MRU only
;; orders the answer; it truncates, so it never decides membership.
(define (active-groups)
  ;; a group is active while a WORK buffer of it is open: its chat alone
  ;; does not keep it active
  (let ((open (fold (lambda (out b)
                      (let ((id (and (buffer-known? b) (not (chat-buffer? b)) (buffer-group b))))
                        (if (or (not id) (member id out)) out (cons id out))))
                    '()
                    (buffer-list))))
    (filter (lambda (id) (member id open)) (group-ids-mru))))

(public! 'active-groups
  "(active-groups) — every group with an open buffer, most recent first")

;;; --- the frame tab rail ---------------------------------------------------
;;; The frame modeline carries the groups the frame last stood in, and
;;; counts the ones it left out. By default the most recent group leads,
;;; so a recent context is one step away; 'held keeps the rail still. A
;;; tab is one click to another context; the count opens the board with
;;; the rest.

(defcustom 'frame-tabs-limit 10
  "How many groups the frame modeline shows as tabs. The rest count as one more."
  'group 'groups 'type 'number)

(defcustom 'frame-tabs-order 'mru
  "The order of the frame tabs: 'mru puts the most recent group first, 'held keeps each tab in its place."
  'group 'groups 'type 'choice)

(define (frame-tab-rank id mru)
  (let loop ((rest mru) (i 0))
    (cond ((null? rest) 1000000)
          ((equal? (car rest) id) i)
          (else (loop (cdr rest) (+ i 1))))))

;; the tab the MRU ranks last: the one the frame stood in longest ago
(define (frame-tab-coldest ids mru)
  (let loop ((rest ids) (cold #f) (rank -1))
    (if (null? rest)
        cold
        (let ((r (frame-tab-rank (car rest) mru)))
          (if (> r rank)
              (loop (cdr rest) (car rest) r)
              (loop (cdr rest) cold rank))))))

;; The rail holds still. A tab keeps its place for as long as its group
;; is on the rail, so standing in another group does not reshuffle the
;; row under the pointer. The order changes only when a group the cut
;; left out comes in, and then in one slot only: the coldest tab steps
;; aside for it. The frame keeps the order it last showed.
(define (frame-tab-order-held here mru)
  (let* ((limit (max 1 frame-tabs-limit))
         ;; a group that is gone leaves the rail, and a rail longer than
         ;; a shrunken limit loses its coldest tabs first
         (kept (filter (lambda (id) (member id mru))
                       (or (frame-local 'tab-order) '())))
         (kept (let trim ((row kept))
                 (if (<= (length row) limit)
                     row
                     (trim (let ((cold (frame-tab-coldest row mru)))
                             (remove (lambda (id) (equal? id cold)) row))))))
         ;; the first call, and every later gap, fills from the MRU
         (filled (let fill ((rest mru) (row kept))
                   (if (or (null? rest) (>= (length row) limit))
                       row
                       (fill (cdr rest)
                             (if (member (car rest) row)
                                 row
                                 (append row (list (car rest))))))))
         (order (cond ((or (not here) (member here filled)) filled)
                      ((< (length filled) limit) (append filled (list here)))
                      (else (let ((cold (frame-tab-coldest filled mru)))
                              (map (lambda (id) (if (equal? id cold) here id))
                                   filled))))))
    (set-frame-local! 'tab-order order)
    order))

;; Most recent first: the group the frame stands in leads, the group it
;; left last comes next. A walk of tab steps holds the row still, like
;; alt-tab, so M-S-<right> goes on through the recent groups. The page
;; ends the walk when the modifiers come up (group-tab-walk-end); a lost
;; release ends it at the first other command.
(define (group-tab-walk-commit!)
  (when (frame-local 'tab-walk)
    (set-frame-local! 'tab-walk #f)
    (group-mru-note! (frame-group)))
  (frame-chrome-set! "tabs-walk" ""))

(define (frame-tab-order-recent here mru)
  (let ((held (filter (lambda (id) (member id mru))
                      (or (frame-local 'tab-order) '()))))
    (if (and (frame-local 'tab-walk)
             (member (last-command) '("group-tab-left" "group-tab-right"))
             (member here held))
        held
        (let* ((row (if (and here (not (member here mru))) (cons here mru) mru))
               (order (take row (max 1 frame-tabs-limit))))
          (set-frame-local! 'tab-order order)
          order))))

(define (frame-tab-order here mru)
  (if (eq? frame-tabs-order 'held)
      (frame-tab-order-held here mru)
      (frame-tab-order-recent here mru)))

;; (((ID LABEL CURRENT?) ...) MORE)
(define (group-tab-step! dir)
  (let* ((here (frame-group))
         (tabs (car (frame-tabs)))
         (ids (map car tabs)))
    (let find ((rest ids) (i 0))
      (cond ((null? rest) #f)
            ((equal? (car rest) here)
             (let ((j (+ i dir)))
               (if (or (< j 0) (>= j (length ids)))
                   #f
                   (let ((to (nth j ids)))
                     ;; the page sees the walk open, and ends it on release
                     (set-frame-local! 'tab-walk #t)
                     (frame-chrome-set! "tabs-walk" "1")
                     (switch-to-group! to)
                     to))))
            (else (find (cdr rest) (+ i 1)))))))

(define-command "group-tab-left" "Switch to the group shown immediately to the left in the top bar"
  (lambda () (or (group-tab-step! -1) (message "No group to the left"))))

(define-command "group-tab-right" "Switch to the group shown immediately to the right in the top bar"
  (lambda () (or (group-tab-step! 1) (message "No group to the right"))))

(define-command "group-tab-walk-end" "End a walk of the group tabs: the top bar sorts most recent first again"
  (lambda () (group-tab-walk-commit!)))
(catalog-meta! 'command "group-tab-walk-end" 'domain 'buffers 'effects '(write display))

(global-set-key "M-S-<left>" "group-tab-left")
(global-set-key "M-S-<right>" "group-tab-right")

;; The chord moves between groups where you are not editing. In a buffer
;; you ARE editing it extends the selection one word, which is what the
;; chord means on macOS, and cua-mode's map answers it there (cua.scm).
;; The chord never arms a buffer it lands on, so a landing still moves
;; between groups. Press ESC to leave the editing state, or use the group
;; prefix, to move between groups from an armed buffer.
(editing-neutral-commands! '("group-tab-left" "group-tab-right"))

;; A group name renders like a buffer name: the same grammar, so *chat:mail*
;; reads as a bold "chat:mail" on the rail and nowhere shows its asterisks.
(defcustom 'group-name-format "%n"
  "How a group names itself on the tab rail: %n the short name, %N the full one. Add :group: for the icon."
  'group 'appearance)

(define (group-name-segments g)
  (name-segments
    (name-format-expand group-name-format
      (list (list "n" (group-short-name g))
            (list "N" (group-display-name g))))))

(define (frame-tabs)
  ;; a walk whose release never came ends at the first other command
  (when (and (frame-local 'tab-walk)
             (not (member (last-command) '("group-tab-left" "group-tab-right"))))
    (group-tab-walk-commit!))
  (let* ((here (frame-group))
         (mru (group-ids-mru))
         (shown (frame-tab-order here mru)))
    (list (map (lambda (id)
                 (list id (group-short-name id) (equal? id here)
                       (group-name-segments id)))
               shown)
          (max 0 (- (length mru) (length shown))))))

;; A click on a tab: stand in that group. Already there, nothing moves.
(define (frame-tab! g)
  (let ((id (group-resolve-id g)))
    (cond ((not id) (message "No such group") #f)
          ((equal? id (frame-group)) id)
          (else (switch-to-group! id) id))))

(public! 'frame-tabs
  "(frame-tabs) -> (((ID LABEL CURRENT? SEGMENTS) ...) MORE) — the groups the frame modeline shows as tabs, in the order frame-tabs-order gives, and how many the limit left out; SEGMENTS is the rendered name")
(public! 'group-name-segments
  "(group-name-segments GROUP) — the spans that draw GROUP's name, from group-name-format")
(catalog-meta! 'function "group-name-segments" 'domain 'buffers 'effects '(read))
(catalog-meta! 'function "frame-tabs" 'domain 'buffers 'effects '(write))
(public! 'frame-tab!
  "(frame-tab! GROUP) — stand in GROUP; returns its id, or #f when no group answers to it")
(catalog-meta! 'function "frame-tab!" 'domain 'buffers 'effects '(write display))

;; A homogeneous frame already shows the group where the user stands.
;; In a mixed frame, put the selected foreign buffer's groups before the
;; remaining MRU groups so one RET enters its context.
(define (group-switch-candidate-ids)
  (let* ((current (frame-group))
         (recent (filter (lambda (id) (not (equal? id current)))
                         (group-ids-mru)))
         (mine (buffer-group (current-buffer))))
    (if (group-visible-homogeneous? current)
        recent
        (append (filter (lambda (id) (equal? id mine)) recent)
                (filter (lambda (id) (not (equal? id mine))) recent)))))

;; a seed buffer is a work buffer of yours: a special listing (the
;; telemetry, ibuffer) seeds nothing. The switcher's new-group action
;; asks this; group-new never seeds itself from the current buffer.
(define (group-seed-buffer? buf)
  (group-work-buffer? buf))

(define (group-switch-new-action)
  (let ((buf (current-buffer))
        (current (frame-group)))
    (cond ((not (group-seed-buffer? buf))
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
(define (group-buffer-rows)
  ;; the group list is the buffer list, bucketed: (GROUPS MODES), where
  ;; GROUPS is ((GROUP-KEY BUF ...) ...) over every buffer that is not
  ;; context-only and MODES is ((MODE BUF ...) ...) over every buffer a
  ;; name shows, each bucket most recent first
  (list (cadr (buffer-rows (list 'hidden #t 'bucket 'group)))
        (cadr (buffer-rows (list 'context-only #t 'bucket 'mode)))))


(define (group-members-index &optional rows)
  ;; ((ID BUF ...) ...), every group's members, most recent first: the
  ;; buffer rows bucketed by the group key their locals hold, so this
  ;; resolves one key per group, not one buffer at a time. An alias key,
  ;; a stale id or a legacy row (key "slow") goes through
  ;; buffer-group, which migrates it. A context-only buffer
  ;; is in no group.
  (let* ((buckets (car (or rows (group-buffer-rows))))
         (records *group-records*)
         (index '())
         (extra '()))
    (for-each
      (lambda (bucket)
        (let* ((key (car bucket))
               ;; a record's first field is its id: one assoc for the
               ;; usual key, the full resolve for a name or an origin
               (valid (and (not (equal? key "slow"))
                           (if (assoc key records) key (group-resolve-id key)))))
          (cond ((and valid (equal? valid key))
                 (set! index (cons bucket index)))
                ;; a deleted group: no member, and nothing to write
                ((and (not (equal? key "slow")) (not valid)) #f)
                (else
                  (for-each (lambda (b)
                              (let ((id (buffer-group b)))
                                (when id (set! extra (cons (list id b) extra)))))
                            (cdr bucket))))))
      buckets)
    ;; the rare rows the slow path settled join their group's cell
    (fold (lambda (index pair)
            (let ((cell (assoc (car pair) index)))
              (cond ((not cell) (cons pair index))
                    ((member (cadr pair) (cdr cell)) index)
                    (else (cons (append cell (list (cadr pair)))
                                (remove (lambda (c) (equal? (car c) (car pair))) index))))))
          index (reverse extra))))

;; with no kernel index: one metadata read of every buffer
(define (group-members-index-scan names)
  ;; one metadata snapshot of every buffer, not three buffer-local reads a
  ;; buffer: with hundreds of buffers the per-buffer reads were most of the
  ;; group switcher's wait. A row that still needs a write (a legacy key, a
  ;; stale id) takes buffer-group, which migrates it.
  (let* ((rows (buffer-read-many names '()
                 '("context-only" "mode-name" "group-id" "group" "companion-of")))
         (resolved '())
         (resolve (lambda (id)
                    (let ((hit (assoc id resolved)))
                      (if hit
                          (cadr hit)
                          (let ((valid (group-resolve-id id)))
                            (set! resolved (cons (list id valid) resolved))
                            valid)))))
         (group-of
           (lambda (row)
             (let ((buf (car row))
                   (mode (list-ref row 2))
                   (held (list-ref row 3))
                   (legacy (or (list-ref row 4) (list-ref row 5))))
               ;; every buffer's one group is 'group-id; a chat without one
               ;; and the older fields take the slow read, which migrates them
               (cond ((or held (equal? mode "chat-mode"))
                      (let ((valid (and held (resolve held))))
                        (cond ((and valid (equal? valid held)) valid)
                              ;; a deleted group: no member, and nothing to write
                              ((and held (not valid)) #f)
                              (else (buffer-group buf)))))
                     (legacy (buffer-group buf))
                     (else #f))))))
    (let* ((live (filter (lambda (row) (not (equal? (cadr row) #t))) rows))
           ;; (ID N BUF): sorted by id, and by N within one id, so each group
           ;; keeps its buffers in list order without a list rebuild a buffer
           (triples
             (sort (let walk ((rows live) (n 0) (out '()))
                     (if (null? rows)
                         out
                         (walk (cdr rows) (+ n 1)
                               (let ((id (group-of (car rows))))
                                 (if id (cons (list id n (car (car rows))) out) out))))))))
      (let group ((triples (reverse triples)) (index '()))
        (cond ((null? triples) index)
              ((and (pair? index) (equal? (car (car index)) (car (car triples))))
               (group (cdr triples)
                      (cons (cons (car (car index)) (cons (list-ref (car triples) 2) (cdr (car index))))
                            (cdr index))))
              (else (group (cdr triples)
                           (cons (list (car (car triples)) (list-ref (car triples) 2)) index))))))))

(define (group-members-in index g)
  ;; a pseudo group is in no index unless the caller put it there: its
  ;; function says its members
  (let ((cell (assoc (if (pseudo-group-id? g) g (group-resolve-id g)) index)))
    (cond (cell (cdr cell))
          ((pseudo-group-id? g) (pseudo-group-buffers g))
          (else '()))))

;; The facts beside a card say what the group holds and the shape it
;; opens in. They list no members: the card is for choosing a group.
(define (group-switch-facts hint shape)
  (list (list "holds" hint)
        (list "opens" shape)))

(define (group-switch-candidate-in index g &optional label)
  (let* ((n (length (group-members-in index g)))
         (hint (if (= n 0)
                   "no buffers"
                   (string-append (number->string n) " buffer" (if (= n 1) "" "s")))))
    ;; the card names the group and counts it, and wears no member chips
    (list (or label (group-name g))
          hint
          "container"
          '()
          ""
          (group-switch-facts hint (group-preview-shape-in index g)))))

(define (group-switch-away-candidate row)
  ;; the same card, with the count replaced by where the group is: it lives
  ;; in another workspace, so picking it goes there instead of switching here
  (cons (car row) (cons "in another window" (cdr (cdr row)))))

(define (group-switch-candidate g)
  (group-switch-candidate-in (group-members-index) g))


(define (pseudo-group-cells &optional rows)
  ;; ((ID BUF ...) ...) for every pseudo group, the empty ones left out.
  ;; A mode group is the buffer rows bucketed by mode, read once for all
  ;; of them; the others ask their own members.
  (let* ((ids (pseudo-group-ids))
         (by-id (map (lambda (run)
                       (cons (string-append "pseudo:" (group-home-slug (mode-group-name (car run))))
                             (cdr run)))
                     (cadr (or rows (group-buffer-rows))))))
    (filter (lambda (cell) (pair? (cdr cell)))
            (map (lambda (id)
                   (let ((hit (and (member id *mode-group-ids*) (assoc id by-id))))
                     (if hit hit (cons id (pseudo-group-buffers id)))))
                 ids))))

(define (group-switch-prompt-rows)
  ;; ((CANDIDATE ...) . ((LABEL ID) ...)): the rows the prompt draws,
  ;; and the group each label means. The prompt hands a selection back as its
  ;; label and nothing else, and two groups may wear one name, so a repeated
  ;; name takes a counter and every verb here resolves through these pairs
  ;; instead of the name index, which answers with the first group of that
  ;; name and so showed another group's buffers.
  (let* ((current (frame-group))
         ;; the pseudo groups' members, read once; the empty ones are left out
         ;; the group list is the buffer list, bucketed: one read of the
         ;; buffer rows makes every group's cell, real and pseudo
         (brows (group-buffer-rows))
         (pseudo-cells (pseudo-group-cells brows))
         (index (append pseudo-cells (group-members-index brows)))
         (split (group-ids-mru-split))
         (all (car split))
         (away (cadr split))
         (recent (append (filter (lambda (id) (not (equal? id current))) all)
                         (filter (lambda (id) (equal? id current)) all)))
         (mine (buffer-group (current-buffer)))
         (mine-recent (filter (lambda (id) (equal? id mine)) recent))
         (others (filter (lambda (id) (not (equal? id mine))) recent))
         (seen '())
         (rows '())
         (candidate
           (lambda (g)
             (let* ((name (group-name g))
                    (taken (length (filter (lambda (s) (equal? s name)) seen)))
                    (label (if (= taken 0)
                               name
                               (string-append name " #" (number->string (+ taken 1))))))
               (set! seen (cons name seen))
               (set! rows (cons (list label g) rows))
               (group-switch-candidate-in index g label))))
         ;; the pseudo groups come after every real one, the empty ones left out
         (pseudo (map car pseudo-cells))
         (here-candidates
           (map candidate (append (if (group-visible-homogeneous? current)
                                      recent (append mine-recent others))
                                  pseudo)))
         (candidates
           (append here-candidates
                   (map (lambda (g) (group-switch-away-candidate (candidate g)))
                        away))))
    (cons candidates (reverse rows))))

(define (switch-to-group-candidates)
  (car (group-switch-prompt-rows)))

(define (group-switch-run-new-action! action &optional typed)
  (let* ((label (car action))
         (buf (car (cdr action)))
         (source (car (cdr (cdr action))))
         (create! (lambda (name)
                    (if buf
                        (group-create-with-buffer! name buf source)
                        (group-create-and-enter! name '() #f)))))
    (cond ((and typed (not (equal? typed "")) (group-record-by-name typed))
           (message (string-append "Group " typed " already exists")))
          ((and typed (not (equal? typed ""))) (create! typed))
          (else (group-read-new-name (string-append label ": ") create!)))))

;; What the highlight shows while you move through the groups: the
;; WHOLE group, not one buffer of it — the arrangement you would land
;; in. The members a preview arranges are the work, so a look at a
;; group is a look at what you would work on.
(define (group-preview-members-in index g)
  (filter (lambda (b)
            ;; the work, not a companion: the group's chat and a scratch
            ;; that belongs to a buffer are not where the work is
            (and (group-work-buffer? b)
                 (not (buffer-local b 'scratch-owner))))
          (group-members-in index g)))

;; One index per prompt: group-buffers-mru scans every buffer twice per
;; group, and the highlight moved one group per key.
(define (group-preview-members g)
  (group-preview-members-in (group-members-index) g))

;; The shape a group opens in, for the rail: the panes of its saved
;; layout, else the panes arrival would build for it.
(define (group-preview-shape-in index g)
  (let* ((saved (group-layout g))
         (panes (if saved
                    (panes-pane-count saved)
                    ;; two is the most a card says, so stop looking at two.
                    ;; A mode group's members share one mode, so its first
                    ;; ones speak for all: a group of 200 chats is not
                    ;; walked to the end to learn it holds no work buffer
                    (let count ((bufs (let ((all (group-members-in index g)))
                                        (if (member g *mode-group-ids*) (take all 3) all)))
                                (n 0))
                      (cond ((or (= n 2) (null? bufs)) n)
                            ((and (group-work-buffer? (car bufs))
                                  (not (buffer-local (car bufs) 'scratch-owner)))
                             (count (cdr bufs) (+ n 1)))
                            (else (count (cdr bufs) n)))))))
    (cond ((= panes 0) "nothing yet")
          ((= panes 1) "one pane")
          (else (string-append (number->string panes) " panes")))))


;; Draw G in the frame, and answer the buffers the look woke. A look is
;; not an arrival: it writes no winner entry, leaves the frame's own
;; group alone, and saves no layout, and the prompt puts the windows
;; back when it closes. A dormant member wakes for the look and sleeps
;; again after; buffer-sleep! refuses a buffer that is on screen, so the
;; group you actually enter stays awake.
;; what the last look drew: (GROUP BUFFERS). A look is a whole frame, so a
;; look that would draw what is already on screen draws nothing at all
(define *group-preview-last* #f)

(define (group-preview-shown? g)
  (and *group-preview-last*
       (equal? (car *group-preview-last*) g)
       (equal? (cadr *group-preview-last*) (map cadr (window-list)))))

(define (group-preview-forget!)
  (set! *group-preview-last* #f)
  (set! *group-look-active* #f))

(define (group-preview-draw! index g)
  ;; the look draws the group's model: on this frame, else its layout,
  ;; else the default a switch would build. What it shows wakes for the
  ;; look; the switcher sleeps it again
  (if (group-preview-shown? g)
      '()
      (let* ((layout (or (panes-layout-of g)
                         (group-layout g)
                         (panes--default-layout (group-default-panes g))))
             (layout (panes-validate layout buffer-known?))
             (standing *group-current-inhibit*)
             (asleep (filter (lambda (b) (and (buffer-known? b) (not (buffer-exists? b))))
                             (map caddr (panes-visible layout)))))
        (set! *group-current-inhibit* #t)
        ;; and it stays set until the frame is yours again: the look outlives
        ;; the draw, and so must the silence around it
        (set! *group-look-active* #t)
        (panes-look! layout g)
        (set! *group-current-inhibit* standing)
        (set! *group-preview-last* (list g (map cadr (window-list))))
        (let ((woken (filter buffer-exists? asleep)))
          (for-each restore-buffer-runtime! woken)
          woken))))

;; In the groups board a verb acts on the row; anywhere else it prompts.
(define (in-groups-board?)
  (equal? (list-mode-of (current-buffer)) "groups-mode"))

;; M-m in the group prompt: the buffer you came from joins the group under
;; the highlight, and the prompt stays open. The switcher already knows the
;; group; asking for it again in a second prompt is the step this removes.
;; The key is M-m, not m: the prompt's letters narrow the list, and a bare
;; letter cannot be both a filter and a verb.
;; The open group prompt as (LABEL ID) rows. A selection comes back
;; as its label alone, so this is the one place that says which group the
;; highlight means. Empty while no group prompt is up, which is also how a key
;; bound in the minibuffer's own map knows it is somewhere else.
(define *group-switch-rows* '())

;; the arrangement you came from, put back. A verb that destroys what the look
;; is showing calls this first, so no window is left naming a dead buffer.
(define *group-switch-restore* #f)

(define (group-switch-row label)
  ;; a selection is a string or nothing, and nothing here is nil as often as
  ;; it is #f: both are false to this lookup
  (and (string? label) (assoc (string-trim label) *group-switch-rows*)))

(define (group-switch-id label)
  (let ((row (group-switch-row label)))
    (and row (cadr row))))

(define (group-switch-highlighted)
  (and (minibuffer-active?)
       (group-switch-id (minibuffer-selected))))

(define-command "group-switch-move-buffer"
  "Move the buffer you came from into the group under the highlight"
  (lambda ()
    (let ((g (group-switch-highlighted)))
      (if (not g)
          (message "No group here")
          (with-invoking-buffer
            (lambda ()
              (let ((buf (current-buffer)))
                (cond ((not (group-membership-buffer? buf))
                       (message "The current buffer is not a work buffer"))
                      (else
                       (buffer-move-family-to-group! buf g)
                       (message (string-append (buffer-modeline-name buf)
                                               " moved to "
                                               (group-name g))))))))))))

(define-command "group-switch-kill"
  "Kill the group under the highlight; outside the group prompt, kill the line"
  (lambda ()
    (let ((g (group-switch-highlighted)))
      (if (not g)
          ;; C-k sits in the minibuffer's own map, so every other prompt keeps
          ;; the editing key it has always had
          (run-command "kill-line")
          (with-invoking-buffer
            (lambda ()
              ;; the look is showing this group and its buffers are about to
              ;; die: the arrangement you came from goes back first
              (when *group-switch-restore* (*group-switch-restore*))
              (group-kill! g)
              ;; the killed row leaves the list without closing the prompt
              (let ((rows (group-switch-prompt-rows)))
                (set! *group-switch-rows* (cdr rows))
                (minibuffer-set-candidates! (car rows)))))))))

(local-set-key* (minibuffer-buffer) "M-m" "group-switch-move-buffer")
(local-set-key* (minibuffer-buffer) "C-k" "group-switch-kill")

(define-command "group-switch-new" "Create a group from the group switcher, named by what you typed"
  (lambda ()
    (let ((action (frame-local 'group-switch-new-action))
          (state (minibuffer-state)))
      (when (and state action)
        ;; the filter you typed to look for the group names the new one
        (let ((typed (string-trim (or (plist-get state 'input) ""))))
          ;; Cancel restores the invoking arrangement before the name prompt.
          (minibuffer-cancel!)
          (group-switch-run-new-action! action typed))))))


(define-command "group-switch" "Switch to a group and restore its layout"
  (lambda ()
    (if (in-groups-board?)
        ;; the board lists every group, this frame's and the rest. A row
        ;; an isolated frame keeps goes to that frame.
        (let* ((g (groups--current))
               (away (and g (group-elsewhere-frame g))))
          (cond ((not g) #f)
                (away (group-frame-raise! away))
                (else (switch-to-group! g))))
        (let* ((action (group-switch-new-action))
               ;; the window the prompt opened from, the source of every look
               (home (active-window))
               (prompt-rows (group-switch-prompt-rows))
               (candidates (car prompt-rows))
               ;; built by the first look: a prompt that never looks never pays
               (index #f)
               ;; #f once the prompt closed: a look that was still
               ;; waiting must not draw after it
               (open #t)
               (woken '())
               ;; a look replaces the whole frame (preview-show ... 'frame),
               ;; and its end puts back the whole frame you came from. A
               ;; prompt that never looked closes without repainting anything
               (show-here!
                 (lambda ()
                   (when (preview-slot)
                     (group-preview-forget!)
                     (preview-end #f))))
               (sleep-woken!
                 (lambda ()
                   (for-each (lambda (buf) (buffer-sleep! buf)) woken)
                   (set! woken '())))
               (restore!
                 (lambda () (show-here!) (sleep-woken!)))
               (close!
                 (lambda ()
                   (set! open #f)
                   (set-frame-local! 'group-switch-new-action #f)
                   (buffer-minor-maps! (minibuffer-buffer)
                     (remove (lambda (m) (equal? m "group-switch-modal-map"))
                             (buffer-minor-maps (minibuffer-buffer))))
                   (set! *group-switch-rows* '())
                   (set! *group-switch-restore* #f)
                   (group-preview-forget!)))
               (preview-now!
                 (lambda (name)
                   (when open
                     (let ((id (group-switch-id name)))
                       (if id
                           ;; HOME names the look's source every time: a look whose
                           ;; source is the window the last look selected is a new
                           ;; look to preview-show, which then puts the frame you
                           ;; came from back before it draws, one flash per highlight
                           (preview-show
                             (lambda ()
                               (unless index (set! index (group-members-index)))
                               (set! woken (append (group-preview-draw! index id) woken)))
                             'frame home)
                           ;; An unmatched filter leaves the invoking windows intact.
                           (show-here!))))))
               ;; a look per highlight that RESTS: C-n held down moves the
               ;; highlight faster than a frame draws, and each look is a
               ;; draw (and a wake, for a dormant member)
               (preview!
                 (lambda (name)
                   ;; 0 keeps the frame still: the card already says what a
                   ;; group holds, and a look is a whole-frame draw per
                   ;; highlight, panes and all
                   (when (and (number? group-switch-preview-ms)
                              (> group-switch-preview-ms 0))
                     (debounce! "group-switch-preview" group-switch-preview-ms
                                preview-now! name)))))
          (set! *group-switch-rows* (cdr prompt-rows))
          (set! *group-switch-restore* restore!)
          (begin
              (minibuffer-read-preview "Switch group: " candidates
                preview!
                (lambda (name)
                  (let ((id (group-switch-id name)))
                    (close!)
                    ;; the switch saves the layout you leave, so put the
                    ;; windows back before it looks: a preview is not the
                    ;; arrangement you were working in
                    (show-here!)
                    (cond ((and id (group-elsewhere-frame id))
                           ;; an isolated frame keeps the group: go to that
                           ;; frame rather than pull its windows into this one
                           (group-frame-raise! (group-elsewhere-frame id)))
                          (id (switch-to-group! id))
                          ;; a name no group has makes that group
                          ((and name (not (equal? (string-trim name) "")))
                           (group-switch-run-new-action! action (string-trim name)))
                          (else #f)))
                  (sleep-woken!))
                (lambda ()
                  (close!)
                  (show-here!)
                  (sleep-woken!))
                #f
                group-switch-style)
              (set-frame-local! 'group-switch-new-action action)
              (buffer-minor-maps! (minibuffer-buffer)
                (cons "group-switch-modal-map"
                      (buffer-minor-maps (minibuffer-buffer)))))))))

(defcustom 'group-switch-preview-ms 120
  "How long the highlight rests on a group before the switcher previews it, in milliseconds. 0 turns the look off and leaves the frame still."
  'group 'groups 'type 'number)

(defcustom 'group-switch-style "modal"
  "The shape the group switcher takes: \"modal\", \"popup\", or \"minibuffer\"."
  'group 'groups 'type 'string)

;; Emacs-style toggle: the frame's previous group and its current one
;; trade places. switch-to-group! writes 'previous-group on every switch.
(define-command "group-switch-last" "Switch back to the group this frame just left"
  (lambda ()
    (let ((back (group-resolve-id (frame-local 'previous-group))))
      (cond ((not back) (message "No previous group"))
            ((equal? back (frame-group)) (message "Already in that group"))
            (else (switch-to-group! back))))))
(domain! 'groups)
(effects! '(write display))

;;; --- Alt-Tab inside a group -----------------------------------------------
;;; Each window cycles its preferred mode within the group. The preference
;;; follows its work buffer through temporary covers. An explicit cycle mode
;;; overrides automatic selection. Cycling always stays in the selected window.
;;;
;;; The buffer arrives in the window you are in. The walk never selects
;;; another window and never moves the frame to another group: a buffer you
;;; can already see stays where it is, and your focus stays where you put it.
;;;
;;; The first press lands on the buffer you came from; each further press,
;;; with no other command between, goes one deeper. Any other command ends
;;; the walk, so the next press starts again from where you now are. Two
;;; buffers and the key flips between them, the way Alt-Tab flips between two
;;; windows.

(define *window-mode-preferences* '())
(define *group-cycle-ring* '())
(define *group-cycle-pos* 0)

;; A pane's mode preference. It steers ROUTING only: window-preferred-mode
;; reads it to decide which pane a display belongs in. It used to steer the
;; walk as well, under the name window-cycle-mode, and the walk no longer
;; has a mode to prefer -- it goes everywhere (below).
(define (window-mode-preference id)
  (let ((hit (assoc id *window-mode-preferences*)))
    (and hit (cadr hit))))

;; #f removes the override and restores the automatic preference.
(define (window-mode-preference! id mode)
  (set! *window-mode-preferences*
        (filter (lambda (r) (not (equal? (car r) id))) *window-mode-preferences*))
  (when mode
    (set! *window-mode-preferences* (cons (list id mode) *window-mode-preferences*)))
  mode)

;; the group we walk: the frame says which one, and a buffer that is not the
;; frame's own falls back to its first membership
(define (group-cycle-group)
  (let ((here (frame-group)))
    (if (and here (buffer-in-group? (current-buffer) here))
        here
        (buffer-group (current-buffer)))))

;; a buffer with no group walks the other buffers with no group
(define (group-cycle-member? b gid)
  (if gid (buffer-in-group? b gid) (not (buffer-group b))))

;; The walk order: this buffer first, then the rest of the GROUP, most
;; recently used first. This is the escape hatch, so it skips nothing a
;; buffer can be: a chat, a dired, a list, a view, the group scratch are
;; all places you go. It used to walk the pane's kind alone, which left
;; most of a group unreachable from the key meant to reach all of it.
;;
;; The walk holds every buffer the USER has in the group, a dormant one
;; too: a step onto it wakes it. It leaves out a buffer only an agent
;; opened (a context buffer), and the names that are not a buffer you can
;; stand in -- a hidden buffer and a float.
;; With MODE-ONLY the ring keeps the buffers of this buffer's major mode
;; (a derived mode counts). A buffer with no mode walks the others with none.
(define (group-cycle-ring &optional mode-only)
  (let* ((gid (group-cycle-group))
         (here (current-buffer))
         (mode (buffer-local here 'mode-name)))
    (define (same-mode? b)
      (or (not mode-only)
          (if mode (buffer-derived-mode? b mode) (not (buffer-local b 'mode-name)))))
    (cons here
          (filter (lambda (b)
                    (and (group-cycle-member? b gid)
                         (same-mode? b)
                         (not (string-prefix? " " b))
                         (not (buffer-context-only? b))
                         (not (float--class? b))
                         (not (equal? b here))))
                  (buffer-list-mru)))))

(define (group-cycle! dir &optional mode-only)
  (unless (member (last-command)
                  (if mode-only
                      '("group-next-mode-buffer" "group-previous-mode-buffer")
                      '("group-next-buffer" "group-previous-buffer")))
    (set! *group-cycle-ring* (group-cycle-ring mode-only))
    (set! *group-cycle-pos* 0))
  ;; a buffer killed mid-walk leaves the ring, and the place holds
  (let ((live (filter buffer-known? *group-cycle-ring*)))
    (unless (= (length live) (length *group-cycle-ring*))
      (set! *group-cycle-ring* live)
      (when (>= *group-cycle-pos* (length live))
        (set! *group-cycle-pos* 0))))
  (let ((n (length *group-cycle-ring*)))
    (if (< n 2)
        (message (if mode-only
                     "No other buffer of this mode in this group"
                     "No other buffer to cycle in this group"))
        (begin
          (set! *group-cycle-pos* (modulo (+ *group-cycle-pos* dir) n))
          (window-display!
            (lambda ()
              (switch-to-buffer-here! (list-ref *group-cycle-ring* *group-cycle-pos*))
              (active-window)))))))

(define-command "group-next-buffer"
  "Walk every buffer in this group, most recently used first"
  (lambda () (group-cycle! 1)))

(define-command "group-previous-buffer"
  "Walk every buffer in this group, the other way"
  (lambda () (group-cycle! -1)))

(define-command "group-next-mode-buffer"
  "Walk this buffer's mode in this group, most recently used first"
  (lambda () (group-cycle! 1 #t)))

(define-command "group-previous-mode-buffer"
  "Walk this buffer's mode in this group, the other way"
  (lambda () (group-cycle! -1 #t)))

(domain! 'windows)
(effects! '(write display))

;; A buffer's major mode, the one thing consolidation groups by.
(define (mode-consolidate-mode-of buf)
  ;; a buffer that never set a mode is fundamental, and consolidates like any other
  (and (buffer-known? buf) (or (buffer-local buf 'mode-name) "fundamental-mode")))

(define (consolidate!)
  (panes-consolidate!))

;; The mode a window holds: that of the buffer it shows, else the one it
;; was given, else that of its nearest work buffer beneath temporary covers.
;; A window waiting off the screen holds the mode the panes model gives it.
(define (mode-consolidate-window-mode win)
  (let ((shown (window-buffer-any win))
        (held (and (window-exists? win) (window-mode-preference win)))
        (l (and (not (window-exists? win)) (panes-layout))))
    (cond ((and l (panes-window l win)) (panes-window-mode l win))
          ((and shown (buffer-known? shown) (not (window-preference-cover? shown)))
           ;; what the pane shows wins over a preference left from before
           (mode-consolidate-mode-of shown))
          (held
            held)
          (else
            (let loop ((buffers (window-prev-buffers win)))
              (cond ((null? buffers) #f)
                    ((and (buffer-known? (car buffers))
                          (not (window-preference-cover? (car buffers))))
                     (mode-consolidate-mode-of (car buffers)))
                    (else (loop (cdr buffers)))))))))

(define-command "consolidate"
  "Give every major mode of this group one window: behind its pane, or on the layout ring"
  (lambda () (consolidate!)))

(define (mode-consolidate!)
  (let ((me (active-window)))
    (if (not (window-buffer me))
        (begin (message "Nothing to consolidate in this pane") #f)
        ;; the window model regroups its stacks: every buffer of the mode
        ;; this window shows, by the buffer's own mode, joins that mode's window
        ;; a stack that mixes in other modes gives those up too, else they
        ;; stay behind in the window this mode claims
        (let* ((m (panes--buffer-mode (window-buffer me)))
               (l (panes--ensure-layout!))
               (touched (filter (lambda (k) (find (lambda (b) (equal? (panes--buffer-mode b) m)) (panes-window-buffers l k)))
                                (panes-window-keys l)))
               (modes (cons m (filter (lambda (x) x)
                                      (map panes--buffer-mode
                                           (apply append (map (lambda (k) (panes-window-buffers l k)) touched))))))
               ;; the group's buffers of the mode that no window holds join too
               (extra (filter (lambda (b) (equal? (panes--buffer-mode b) m))
                              (group-buffers (frame-group) #t)))
               (after (panes-consolidate l panes--buffer-mode modes extra)))
          (panes-apply! after)
          (when (window-exists? me) (select-window! me))
          (message (string-append "Consolidated " m))
          me))))

(define-command "mode-consolidate"
  "Gather every buffer of this pane's major mode into this pane"
  mode-consolidate!)
(global-set-key "C-x C" "consolidate")
(public! 'consolidate!
  "(consolidate!) — give every major mode of the group one window; each mode's window waits behind its pane")

;;; Jump to mode: C-x m picks a major mode among this frame's windows and
;;; goes to its window, bringing it to the front of its pane or the ring.

;; every window of this frame: the pane rows when the group has panes,
;; else the panes on screen and the ring behind them
(define (jump-to-mode-windows)
  (append (layout-pane-windows) (layout-hidden-windows)))

;; (MODE WINDOW BUFFER) once per mode, in window order
(define (jump-to-mode-choices)
  (let loop ((wins (jump-to-mode-windows)) (acc '()))
    (if (null? wins)
        (reverse acc)
        (let* ((w (car wins))
               (m (mode-consolidate-window-mode w)))
          (loop (cdr wins)
                (if (and m (not (assoc m acc)))
                    (cons (list m w (window-buffer-any w)) acc)
                    acc))))))

(define (jump-to-mode! mode)
  (let ((hit (assoc mode (jump-to-mode-choices))))
    (and hit
         (panes-raise-window! (cadr hit)))))

(define-command "jump-to-mode"
  "Pick a major mode among this frame's windows and go to its window"
  (lambda ()
    (let ((choices (jump-to-mode-choices)))
      (if (null? choices)
          (message "No mode windows in this frame")
          (minibuffer-read "Mode: "
            (map (lambda (ch) (list (car ch) (buffer-modeline-name (caddr ch)))) choices)
            (lambda (pick)
              (let ((name (if (pair? pick) (car pick) pick)))
                (or (jump-to-mode! name)
                    (message (string-append "no window of mode " name))))))))))
(global-set-key "C-x m" "jump-to-mode")
(public! 'jump-to-mode!
  "(jump-to-mode! MODE) — go to the window of MODE in this frame, bringing it to the front of its pane; #f when no window holds it")

(domain! 'groups)
(effects! '(write display))

;; An empty answer restores the automatic preference. This names the mode a
;; pane PREFERS to show, which is a routing question. It used to name the
;; mode the pane's cycle key walked as well, and the walk has no mode now.
(define-command "window-mode-preference" "Set the mode this pane prefers to show"
  (lambda ()
    (let ((id (active-window)))
      (minibuffer-read "Preferred mode (empty for automatic): " '()
        (lambda (name)
          (let ((mode (if (equal? (string-trim name) "") #f (string-trim name))))
            (window-mode-preference! id mode)
            (message (if mode
                         (string-append "This pane prefers " mode)
                         "This pane takes its preferred mode from what it shows"))))))))

;; C-` walks the buffers of this buffer's mode in the group. The arrows
;; belong to window.scm: they walk the panes and this window's buffers.
(global-set-key "C-`" "group-next-mode-buffer")

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

(define-command "group-noise-cycle" "Cycle the companion noise of the marked groups"
  (lambda ()
    (groups--act! "cycled"
      (lambda (g)
        (let ((cur (group-noise g)))
          (group-noise-set! g (cond ((equal? cur "off") "quiet")
                                    ((equal? cur "quiet") "loud")
                                    (else "off"))))))))

;; A group with a parent came from a pop-out. Dissolving it merges the
;; members back: each work buffer joins the parent. A group with no live
;; parent dissolves as before, and the buffers keep only their other groups.
(define (group-dissolve! g)
  (let* ((found (begin (group-migrate-live!) (group-resolve-id g)))
         (id (if (pseudo-group-id? found)
                 (begin (message "A pseudo group has nothing to dissolve") #f)
                 found))
         (parent (and id (group-parent id))))
    (when id
      (for-each
        (lambda (b)
          (if (chat-buffer? b)
              (when (equal? (chat-group-id b) id)
                (buffer-set-local! b 'group-id #f))
              (begin
                (when parent (buffer-add-group! b parent))
                (buffer-remove-group! b id))))
        (group-buffers id))
      (let ((stood (equal? (frame-local 'current-group) id)))
        (when stood (set-frame-local! 'current-group #f))
        (group-record-delete! id)
        (if (and stood parent)
            (switch-to-group! parent)
            (frame-group-label-refresh!)))
      #t)))

(define-command "group-dissolve" "Dissolve a group; its members merge into the parent group when one exists"
  (lambda ()
    (if (in-groups-board?)
        (groups--act! "dissolved" group-dissolve!)
        (let ((g (frame-group)))
          (if g
              (begin (group-dissolve! g)
                     (message (string-append "Dissolved group " (group-name g))))
              (message "Not in a group"))))))

;; kill a whole context: every member buffer dies, except a modified
;; file buffer — unsaved work never dies silently
(define (group-kill! g)
  (let* ((id (begin (group-migrate-live!) (group-resolve-id g)))
         (name (or (group-name id) ""))
         (members (if id (group-known-buffers id) '()))
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
    ;; A member belongs to ONE group, so no member is spared by living
    ;; somewhere else as well. Unsaved work is the only thing that survives.
    (for-each
      (lambda (b)
        (if (and (buffer-path b) (buffer-modified? b))
            (set! survivors (cons b survivors))
            (buffer-kill! b)))
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

;; The group whose last buffer BUF is, or #f. The group's scratch is its
;; blank pane, not a member that counts: a group that holds only BUF and
;; its scratch empties when BUF dies.
(define (group-last-buffer-of b)
  (let ((g (and (group-membership-buffer? b)
                (not (group-scratch-buffer? b))
                (group-resolve-id (buffer-group b)))))
    ;; Count every member, dormant ones too, and never through a list's
    ;; filter: group-buffers sees only the live buffers, so a group whose
    ;; other members slept looked empty and a yes killed it.
    (and g
         (null? (filter (lambda (other)
                          (and (not (equal? other b))
                               (not (string-prefix? " " other))
                               (not (group-scratch-buffer? other))))
                        (map car (cadr (buffer-rows (list 'groups (list g)
                                                          'hidden #t
                                                          'context-only #t))))))
         g)))

;; A kill of the last buffer of a group asks once, and a yes kills
;; the group with it. A no kills nothing.
(advice-add! 'kill-buffer-confirm! 'around 'group-last-buffer
  (lambda (next target done)
    (let ((g (and (buffer-known? target) (group-last-buffer-of target))))
      (if (not g)
          (next target done)
          (y-or-n (string-append target " is the last buffer of group "
                                 (group-name g) ". Kill it and dissolve the group?")
            ;; group-kill! takes the frame out of the group before its
            ;; members die. A kill of TARGET first ran the kill repair
            ;; inside the dying group: its stand-in window buffer joined the
            ;; group and died with it, and the window showed a dead buffer.
            ;; Unsaved work survives group-kill!; the plain kill then asks.
            (lambda ()
              (group-kill! g)
              (if (buffer-known? target)
                  (next target done)
                  (when done (done #t))))
            (lambda ()
              (message "Not killed")
              (when done (done #f))))))))

(defgroup 'groups "Work contexts: groups of buffers and their layouts.")

(defcustom 'magic-grouping #f
  "When enabled, let JEV place chats and other buffers after a summary lands."
  'group 'groups 'type 'boolean)

;; JEV's first grouping decision is made from the first running summary.
;; The hook is deliberately installed here, after the group primitives exist.
(define (jev-group-option i)
  (string->symbol (string-append "g" (number->string i))))

(define (jev-group-options ids)
  (let loop ((rest ids) (i 0) (out '()))
    (if (null? rest) (reverse out)
        (loop (cdr rest) (+ i 1) (cons (list (jev-group-option i) (car rest)) out)))))

(define (jev-buffer-group &optional buf summary k)
  "Return JEV's suggested existing group id for BUF, or #f. With K, answer asynchronously."
  (let* ((target (or buf (current-buffer)))
         (text (or summary
                   (buffer-local target 'chat-summary)
                   (buffer-local target 'chat-title)
                   ""))
         (ids (group-ids))
         ;; A group name is free text: it repeats (two groups called
         ;; browse), and it holds spaces and stars (JEV / LAYA,
         ;; *amazon*). So it cannot be an option key -- the keys are g0,
         ;; g1, ... the way notmuch's are t0 and k0. Three things follow:
         ;; criteria encodes as the object the endpoint requires (a plist
         ;; of strings encodes as an array, and every call 422'd on
         ;; body.questions.group.choice.criteria), the name moves into the
         ;; description where it belongs, and the answer resolves to one
         ;; id rather than a name two groups answer to.
         (options (jev-group-options ids))
         (criteria (append
                     (apply append
                       (map (lambda (row)
                              (let ((id (nth 1 row)))
                                (list (car row)
                                      (string-append (group-name id) " - "
                                                     (or (group-meta id) "(no description)")))))
                            options))
                     (list 'none "No existing group matches this summary.")))
         (state (string-append
                  "Chat summary:\n" text
                  "\n\nExisting groups and their descriptions:\n"
                  (if (null? ids) "(none)"
                      (string-join
                        (map (lambda (id)
                               (string-append "- " (group-name id)
                                              ": " (or (group-meta id) "(no description)")))
                             ids)
                        "\n"))))
         (question (list 'group
                         (jev-choice
                           "Which existing group best matches this chat summary? Choose none unless the match is clear."
                           criteria)))
         ;; the choice comes back as the option key, so read the id off it
         (chosen (lambda (reply)
                   (let ((pick (and reply (jev-answer-choice reply 'group))))
                     (cond ((not (string? pick)) #f)
                           ((equal? pick "none") "none")
                           (else (let ((hit (assoc (string->symbol pick) options)))
                                   (and hit (nth 1 hit)))))))))
    (if (or (not (string? text)) (equal? (string-trim text) "") (null? ids)
            (not (and (boundp 'jev-systemone) (boundp 'jev-answer-choice))))
        (if k (k #f) #f)
        (if k
            (jev-ask state question (lambda (reply) (k (chosen reply))))
            (chosen (jev-systemone state question))))))

(public! 'jev-buffer-group
  "(jev-buffer-group BUF SUMMARY K) — ask JEV which existing group matches SUMMARY; K gets its id, \"none\", or #f")
(catalog-meta! 'function "jev-buffer-group" 'domain 'jev 'effects '(read external execute spend))

(define (buffer-magic-group! buf destination)
  (let ((id (and destination (group-resolve-id destination))))
    (and id
         (begin
           (buffer-move-to-group! buf id)
           (message (string-append "JEV moved " buf " to " (group-name id)))
           id))))

(public! 'buffer-magic-group!
  "(buffer-magic-group! BUF GROUP) — move BUF's membership to GROUP without changing the visible frame")
(catalog-meta! 'function "buffer-magic-group!" 'domain 'buffers 'effects '(write))

(define-command "buffer-magic-group" "Classify the current buffer with JEV and move it when a group matches"
  (lambda () (buffer-magic-group-current! (current-buffer))))

;; With no explicit arguments, classify the current buffer from its summary.
(define (buffer-magic-group-current! &optional buf)
  (let ((target (or buf (current-buffer))))
    (let ((summary (or (buffer-local target 'chat-summary)
                       (buffer-local target 'chat-title))))
      (if (and (string? summary) (not (equal? (string-trim summary) "")))
          (jev-buffer-group target summary
            (lambda (choice)
              (if (and choice (not (equal? choice "none")))
                  (buffer-magic-group! target choice)
                  (message "JEV left the current buffer in place"))))
          (message "The current buffer has no summary yet")))))

(public! 'buffer-magic-group-current!
  "(buffer-magic-group-current! [BUF]) — classify BUF, defaulting to the current buffer")

(catalog-meta! 'command "buffer-magic-group" 'domain 'buffers 'effects '(write))

(define (group-magic-first-summary! buf kind summary)
  (when (and magic-grouping
             (equal? kind 'summary)
             (buffer-known? buf)
             (not (buffer-local buf 'magic-grouping-done))
             (not (buffer-local buf 'magic-grouping-pending)))
    (buffer-set-local! buf 'magic-grouping-pending #t)
    (message (string-append "JEV is checking the first summary for " buf "…"))
    (jev-buffer-group buf summary
      (lambda (choice)
        (buffer-set-local! buf 'magic-grouping-pending #f)
        (buffer-set-local! buf 'magic-grouping-done #t)
        (cond ((or (not choice) (equal? choice "none"))
               (message (string-append "JEV left " buf " in its current group")))
              ((equal? choice (group-name (buffer-group buf)))
               (message (string-append "JEV confirmed " buf " in " choice)))
              ((buffer-magic-group! buf choice) #t)
              (else (message (string-append "JEV chose unknown group " choice))))))))

(add-hook! 'chat-summary-hook 'group-magic-first-summary!)



(defcustom 'group-after-kill "follow"
  "After you kill the group you stand in: \"follow\" enters the most recent other group, or the home page when no group is left; \"stay\" shows the next buffer and no group."
  'group 'groups 'type 'string)

;; The kill left the frame in no group. It enters the most recent group
;; that is left: the next context, not a lone buffer. With no group left,
;; the frame shows the home page.
(define (group-kill-follow!)
  (let ((killed *group-killed*))
    ;; one kill, one follow: a reload registers the handler again
    (set! *group-killed* #f)
    (when (and killed (caddr killed) (equal? group-after-kill "follow"))
      (let ((next (let ((ids (group-ids-mru))) (and (pair? ids) (car ids)))))
        (cond
          (next
           (switch-to-group! next)
           (message (string-append "Killed group " (cadr killed) ". Now in "
                                   (or (group-name next) ""))))
          ;; the home page is setup-wizard.scm's, found by name: a reload
          ;; of either file keeps the link
          ((boundp 'compos-home!)
           (delete-other-windows!)
           (compos-home!)
           (message (string-append "Killed group " (cadr killed)))))))))

(add-hook! 'group-kill-hook 'group-kill-follow!)

;;; --- the graveyard: killed groups a person can revive ------------------------
;;; A kill buries what the record knew and what the members were: the
;;; name, the meta, the layout, the noise, the chat id, the color, and
;;; each member's name and file. Revive makes the record again and brings
;;; back every member it can: a buffer that still exists joins; a file
;;; that still exists is visited; a member with neither is missing, and
;;; the revival says how many. The graveyard keeps the last twenty and
;;; persists with the desktop.

(defvar '*group-graveyard* '() 'persist #t)
(define *group-graveyard-depth* 20)

;; (NAME META LAYOUT NOISE CHAT-ID COLOR KILLED-AT ((BUFFER PATH) ...) SETTINGS)
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
               (map (lambda (b) (list b (buffer-path b))) members)
               (group-record-settings record)))))

(define (group-bury! tomb)
  (when tomb
    (set! *group-graveyard*
      (take (cons tomb
                    (remove (lambda (t) (equal? (car t) (car tomb))) *group-graveyard*))
              *group-graveyard-depth*))
    (desktop-dirty!)))

(define (group-tombstone-members tomb) (nth 7 tomb))

;;; A tombstone written before group settings existed has no eighth field.
(define (group-tombstone-settings tomb)
  (if (> (length tomb) 8) (or (nth 8 tomb) '()) '()))

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
              (group-record-update! id 'settings (group-tombstone-settings tomb))
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

(define-command "group-kill" "Kill every buffer in the current group; in the board, the marked groups"
  (lambda ()
    (if (in-groups-board?)
        (groups--act! "killed" group-kill!)
        (let ((g (frame-group)))
          (if g (group-kill! g) (message "Not in a group"))))))

;; rename a context: every member retags, and the durable state
;; follows. The chat buffer keeps its NAME (there is no buffer
;; rename); membership is by role, so a live chat stays the group's.
;; An unshown chat is found by name, so its identity is copied onto
;; the new name's chat instead.
(define (group-rename! old new)
  (let ((id (begin (group-migrate-live!) (group-resolve-id old)))
        (clean (string-trim new)))
    (cond ((not id) (message "No such group"))
          ((pseudo-group-id? id)
           (message "A pseudo group keeps the name its definition gives it"))
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

(define-command "group-rename" "Rename the current group; in the board, the group at point"
  (lambda ()
    (let ((g (if (in-groups-board?) (groups--current) (frame-group))))
      (cond ((and (not g) (not (in-groups-board?))) (message "Not in a group"))
            (g
             (minibuffer-read (string-append "Rename " (group-label g) " to: ") '()
               (lambda (new)
                 (group-rename! g (string-trim new))
                 (when (buffer-exists? *groups-buffer*)
                   (list-refresh! *groups-buffer*)))))))))

(define-command "groups-refresh" "Refresh the groups board"
  (lambda () (list-refresh! *groups-buffer*)))

(define-command "groups" "Open the groups list: every buffer group as a board, to switch, describe, set noise"
  (lambda () (list-mode-show! "groups-mode")))

(define-list-mode! "groups-mode"
  (list
    'doc (string-append
           "Every buffer group as a table: members, companion noise, "
           "metadata. RET switches to the group and restores its layout; "
           "d writes its description with the LLM; n cycles noise; "
           "x dissolves; K kills the members. `SPC` marks a group, `*` marks "
           "every one, and the verbs act on the marked groups — or on the "
           "row at point when nothing is marked. `/` narrows as you type "
           "and `\\` widens by one.")
    'buffer *groups-buffer*
    'rows (lambda (buf) (list-keep buf (group-names-all)))
    'columns (lambda (buf)
               (list (list "" 1)
                     (list "group" 24)
                     (list "buffers" 7 'right)
                     (list "noise" 6)
                     (list "members" #f)))
    'cells group-cells
    'title (lambda (buf) "Groups")
    'meta groups-meta
    'total (lambda (buf) (length (group-names-all)))
    'footer (lambda (buf)
              '(("RET" "switch") ("SPC" "mark") ("*" "all") ("r" "rename")
                ("d" "describe") ("n" "noise") ("x" "dissolve")
                ("K" "kill buffers") ("b" "members") ("/" "filter")
                ("g" "refresh") ("q" "quit")))
    'key (lambda (buf g) g)
    'noun "group"
    'keys '(("RET" "group-switch") ("r" "group-rename")
            ("d" "group-describe")
            ("n" "group-noise-cycle") ("x" "group-dissolve")
            ("K" "group-kill") ("b" "group-members")
            ("g" "groups-refresh") ("q" "quit-window"))))

(define (group-members-of names id)
  ;; Which of NAMES belong to group ID, in the order given.
  ;;
  ;; Membership lives on the buffer. The kernel's group index names the
  ;; few buffers that can belong (group-index-candidates). One batched read brings back the locals that decide it, and the
  ;; test is then membership in ID's own handful of aliases -- its id, its
  ;; name, its origin -- rather than group-resolve-id re-scanning every
  ;; group record for every buffer. A stale id resolves to nothing, so it
  ;; simply fails to match. The legacy locals, anything the cheap read
  ;; cannot settle: those few fall through to buffer-group, which also
  ;; migrates them.
  (if (not id)
      '()
      (let* ((record (group-record-by-id id))
             (aliases (filter (lambda (s) s)
                              (list id
                                    (and record (group-record-name record))
                                    (and record (group-record-origin record)))))
             (mine? (lambda (s) (and s (member s aliases) #t)))
             (slow? (lambda (b) (equal? id (buffer-group b)))))
        (map car
             (filter
               (lambda (row)
                 (let ((b (list-ref row 0))
                       (gid (list-ref row 2))
                       (legacy (or (list-ref row 3) (list-ref row 4))))
                   (cond (legacy (slow? b))
                         ;; every buffer's one group, a chat or not
                         ((string? gid) (mine? gid))
                         (else #f))))
               (buffer-read-many
                 (group-index-candidates names aliases) '()
                 '("mode-name" "group-id" "group" "companion-of")))))))

(define (group-index-candidates names keys)
  ;; the buffer rows carry the group key each buffer's locals name, so the
  ;; rule above reads a handful of rows, not every buffer; a key the rows
  ;; cannot settle ("slow") is always a candidate
  (let ((hits (map car (cadr (buffer-rows (list 'names names 'hidden #t 'context-only #t
                                                'groups (cons "slow" keys)))))))
    (dedupe-names (filter (lambda (n) (member n hits)) names))))

(define (group-buffers g &optional all)
  ;; the live buffers of G; with ALL, also the ones whose memory waits
  ;; on disk, which buffer-list does not name
  (let ((id (group-resolve-id g)))
    (cond ((pseudo-group-id? id) (pseudo-group-buffers id))
          ((and all id)
           (map car (cadr (buffer-rows (list 'groups (list id) 'hidden #t 'context-only #t 'fields '(name))))))
          (else (group-members-of (buffer-list) id)))))

;; group-buffers answers the live members only. A kill must reach the
;; dormant ones too: they stay asleep in the listings, and a group killed
;; without them leaves them behind with no group.
(define (group-known-buffers g)
  (let ((id (group-resolve-id g)))
    (if (pseudo-group-id? id)
        (pseudo-group-buffers id)
        (group-members-of (map car (cadr (buffer-rows (list 'hidden #t 'fields '()))))
                          id))))

;; Members in MRU order; buffers never visited this session trail.
;; A group is a set, so the list dedupes by name.
(define (group-buffers-mru g)
  (let ((id (group-resolve-id g)))
    ;; a pseudo group answers in its own order, and that order is the point
    (if (pseudo-group-id? id)
        (pseudo-group-buffers id)
        (let ((mru (group-members-of (buffer-list-mru) id)))
          (dedupe-names
            (append mru
                    (remove (lambda (b) (member b mru))
                            (group-buffers id))))))))

(define (group-user-buffers-mru g)
  (filter (lambda (b) (not (buffer-context-only? b)))
          (group-buffers-mru g)))

(define *group-dying* #f)

;; The pool (editor.scm window-fill-buffers): in a group, the group's
;; members; out of one, the ring. The switcher's members section and the
;; windows' fill read the same list.
(define (group-primary-fill? b)
  (and (not (chat-buffer? b)) (not (group-scratch-buffer? b))))

(define (group-fill-buffers group)
  (let ((members (filter fill-candidate? (group-user-buffers-mru group))))
    (append (filter group-primary-fill? members)
            (filter (lambda (b) (not (group-primary-fill? b))) members))))

(set! window-fill-source
  (lambda ()
    (let ((g (frame-group)))
      (if g (group-fill-buffers g)
          (filter (lambda (b) (not (buffer-context-only? b))) (buffer-list-mru))))))




(set! window-fill-primary?
  (lambda (b) (or (not (frame-group)) (group-primary-fill? b))))
(set! window-fill-member?
  (lambda (b) (or (not (frame-group)) (buffer-in-group? b (frame-group)))))

(set! window-history-member?
  (lambda (win b)
    (let ((group (or (frame-group) (buffer-group (window-buffer win))))
          (owner (buffer-group b)))
      (or (equal? owner group)
          (and (not owner) (window-preference-cover? b))))))

;; the next buffer for a window in no group: the first of the pool that
;; is not the dying buffer
;; A kill pulls the next buffer into the window, and a dormant one wakes
;; whole there: text, then its mode, keys and overlays, as a display does.
(define (group-kill-show! win name)
  (let ((restoring (not (buffer-exists? name))))
    (window-set-buffer! win name)
    (when restoring (restore-buffer-runtime! name))))

(define (group-kill-plain-replacement name)
  (let ((action (window-fill-decide (list 'dying name) (window-fill-buffers))))
    (and (equal? (car action) 'show) (cadr action))))

;; the group's most recent chat other than NAME, still alive
(define (group-kill-last-chat group name)
  (let ((id (group-resolve-id group)))
    (and id
         (let loop ((bs (buffer-list-mru)))
           (cond ((null? bs) #f)
                 ((and (not (equal? (car bs) name))
                       (buffer-exists? (car bs))
                       (chat-buffer? (car bs))
                       (equal? (chat-group-id (car bs)) id))
                  (car bs))
                 (else (loop (cdr bs))))))))

;; the scratch the group already has, other than NAME
(define (group-kill-existing-scratch group name)
  (let ((s (group-buffer-as group 'scratch)))
    (and s (not (equal? s name)) (buffer-known? s) s)))

;; The pane's own history wins, then hidden group work, then existing companions.
(define (group-kill-previous-member group name win frame)
  (let ((action (window-fill-decide
                  (window-fill-snapshot win name 'restore #f 'others #f)
                  (group-fill-buffers group))))
    (and (equal? (car action) 'show) (cadr action))))

;; what a killed buffer's window may show in its group: a member of the
;; group, one of the group's chats, or the group's scratch — never a
;; buffer from outside the group
(define (group-kill-keeper? shown group)
  (let ((id (group-resolve-id group)))
    (and id shown (buffer-known? shown)
         (or (and (chat-buffer? shown) (equal? (chat-group-id shown) id))
             (equal? shown (group-buffer-as group 'scratch))
             (and (fill-candidate? shown) (buffer-in-group? shown id))))))

(define (group-dying? group)
  (and *group-dying* (equal? (group-resolve-id group) *group-dying*)))

;; how many windows FRAME has
(define (group-kill-frame-window-count frame)
  (length (filter (lambda (row) (equal? (caddr row) frame)) (window-list-all))))

;; The group a killed buffer's window refills from: the frame's group,
;; else the dying buffer's own group. A frame that already lost its group
;; still never takes a buffer from the whole ring. A group-kill takes its
;; frame out first, and the window falls to the next buffer.
(define (group-kill-window-group frame name)
  (or (group-resolve-id (frame-local-in frame 'current-group))
      (let ((g (group-context-group name)))
        (and (string? g)
             (group-resolve-id g)
             (not (group-dying? g))
             (group-resolve-id g)))))

;; What a group window shows in place of NAME when no member is left: the
;; group's chat. A scratch is no stand-in; it is made for nobody.
(define (group-kill-blank group name)
  (or (group-kill-last-chat group name)
      (let ((chat (group-chat group)))
        (and chat (not (equal? chat name)) chat))))

;; The window of a killed buffer stays in its group (user ruling,
;; 2026-09-03): it shows the member it showed before, most recent first
;; from its own history (user ruling, 2026-09-03: a window refills MRU),
;; else hidden ordinary group work, then an existing chat or scratch; it closes
;; only when the group has none of these — a group that is dying. A
;; buffer from another group never comes in, and a member another window
;; of the frame shows is not shown twice.
;;
;; Before the kill, a window in a group moves to that buffer, so the core
;; needs no stand-in. After the kill, a window the core had to fill on
;; its own is checked: a member, a chat of the group or its scratch may
;; stay; anything else gives way to the group's scratch (made now, from a
;; member that survived), else the window closes. The last window
;; of a frame cannot close: it shows *scratch*. A window in no group
;; keeps the core's fallback.
;;
;; The selection stays in the window that was selected: the core hands
;; it to another window while the buffer dies, and that window was the
;; popup.
(define (group-buffer-kill-repair name)
  ;; The kill is the last moment the buffer can still answer for itself.
  ;; A chat that spawned children leaves its slot behind, marked gone: the
  ;; children keep running and keep naming a parent that is no longer here.
  (when (boundp 'subagent-chat-killed!) (subagent-chat-killed! name))
  (let ((places
          (fold
            (lambda (found row)
              (if (equal? (cadr row) name)
                  (let ((frame (caddr row)))
                    (cons (list (car row) frame (group-kill-window-group frame name))
                          found))
                  found))
            '()
            (window-list-all)))
        (active (active-window)))
    ;; Every group window leaves the dying buffer now, before the core
    ;; refills it from the global ring. A foreign stand-in, even for one
    ;; turn, lets the derived group of that frame drop to none.
    (for-each
      (lambda (place)
        (let ((win (car place))
              (frame (cadr place))
              (group (caddr place)))
          (when (and group (not (group-dying? group)))
            (let* ((member (group-kill-previous-member group name win frame))
                   ;; the chat is the pool of last resort: it takes the place
                   ;; unless another window of this frame already shows it
                   ;; (two windows on one chat looked like a window that would
                   ;; not close); then the window goes, and a lone window
                   ;; shows the chat twice rather than nothing
                   (blank (and (not member) (group-kill-blank group name)))
                   (action (if member
                               (list 'show member)
                               (window-fill-decide
                                 (window-fill-snapshot win name 'restore #f 'previous '()
                                   'others (> (group-kill-frame-window-count frame) 1))
                                 (if blank (list blank) '())))))
              (cond ((equal? (car action) 'show) (group-kill-show! win (cadr action)))
                    ((equal? (car action) 'delete) (delete-window-id! win))
                    (blank (window-set-buffer! win blank)))))))
      places)
    (lambda ()
      (for-each
        (lambda (place)
          (let ((win (car place))
                (frame (cadr place))
                (group (caddr place)))
            (when (and (frame-of-window win) (window-exists? win))
              (let ((shown (window-buffer win)))
                (cond ((not group)
                       (unless (fill-candidate? shown)
                         (let ((replacement (group-kill-plain-replacement name)))
                           (when replacement (group-kill-show! win replacement))))
                       ;; nothing is open: the sole window of a frame fell
                       ;; to a buffer that is nobody's work. It shows the
                       ;; home page instead.
                       (when (and (boundp 'compos-home!)
                                  (member (window-buffer win) '("*scratch*" "*Messages*"))
                                  (= (group-kill-frame-window-count frame) 1))
                         (select-window! win)
                         (compos-home!)))
                      ((group-kill-keeper? shown group) #t)
                      (else
                        (let* ((blank (and (not (group-dying? group))
                                           (group-kill-blank group name)))
                               (action (window-fill-decide
                                         (window-fill-snapshot win name 'restore #f 'previous '()
                                           'others (> (group-kill-frame-window-count frame) 1))
                                         (if blank (list blank) '()))))
                          (cond ((equal? (car action) 'show) (group-kill-show! win (cadr action)))
                                ((equal? (car action) 'delete) (delete-window-id! win))
                                (else
                                  (unless (buffer-exists? "*scratch*") (buffer-create "*scratch*"))
                                  (window-set-buffer! win "*scratch*"))))))))))
        places)
      (when (and (assoc active places) (window-exists? active)
                 (not (equal? (active-window) active)))
        (select-window! active)))))

(add-hook! '(buffer-kill-repair groups) 'group-buffer-kill-repair)

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

;; The buffers the walk below already normalized. group-ids runs on
;; every frame-tabs call, so on every render that moved the buffer order,
;; and the walk touched every buffer each time: 50 ms per keystroke with
;; a hundred buffers. A buffer is migrated once; a buffer born later gets
;; its turn on the next call, and a killed one drops out of the list.
(define *group-migrated-buffers* '())

(define (group-migrate-live!)
  (let ((live (buffer-list)))
    ;; Most calls see exactly the same catalog. Avoid N membership scans
    ;; through the N-entry migration list when no buffer was added or lost.
    (unless (equal? live *group-migrated-buffers*)
      (for-each
        (lambda (buf)
          (unless (member buf *group-migrated-buffers*)
            (buffer-group buf)
            (buffer-modeline-group-refresh! buf)))
        live)
      (set! *group-migrated-buffers* live)))
  #t)

(define (group-ids)
  (group-migrate-live!)
  (map group-record-id *group-records*))

;; Most recently used first, as the frame tabs are; a group the MRU has
;; never seen keeps its record order at the end.
(define (group-names)
  (group-migrate-live!)
  (let* ((ranked (filter (lambda (r) r)
                         (map (lambda (id)
                                (find (lambda (r) (equal? (group-record-id r) id))
                                      *group-records*))
                              (group-ids-mru-all))))
         (rest (filter (lambda (r) (not (memq r ranked))) *group-records*)))
    (map group-record-name (append ranked rest))))

;; the groups a reader chooses between: the founded ones, then the
;; pseudo groups. A destination prompt keeps to group-names, because a
;; buffer cannot join a group that computes its own members.
(define (group-names-all)
  (append (group-names) (pseudo-group-names)))

;; the group's chat counts by NAME as well as by mode: a chat made by
;; group-chat but never shown has no mode yet, and it is still not a
;; work buffer
(define (group-docs g)
  (remove (lambda (b) (or (chat-buffer? b) (equal? b (group-chat-name g))))
          (group-user-buffers-mru g)))

;; Every group by size, as (COUNT NAME ID). sort takes no comparator here and
;; orders terms ascending, so the count goes in negated and comes back out
;; positive: most members first, ties by name. The empty groups land in the
;; tail, which is what a candidate scan reads.
(define (group-counts)
  (map (lambda (r) (list (- (car r)) (cadr r) (caddr r)))
       (sort (map (lambda (id)
                    (list (- (length (group-buffers id))) (group-name id) id))
                  (group-ids)))))

;; group-counts as one name-and-count column with a total line under it.
(define (group-counts-report)
  (let ((rows (group-counts)))
    (string-join
      (append
        (map (lambda (r)
               (string-append (string-pad-right (cadr r) 20)
                              (string-pad-left (number->string (car r)) 3)))
             rows)
        (list (string-append "-- " (number->string (length rows)) " groups, "
                             (number->string (apply + (map car rows)))
                             " buffers")))
      "\n")))

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
      (buffer-set-local! buf 'agent-saved-mark 0)
      (buffer-set-local! buf 'agent-marker-bytes 0))
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
(add-hook! 'buffer-renamed-hook
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
              ;; the named default first, so a group's own config overrides it
              (when (boundp (quote llm-default-bundle-apply!))
                (llm-default-bundle-apply! buf id))
              (chat-set-group! buf id)
              (group-record-update! id 'primary-chat-id (chat-stable-id! buf))
              (when (boundp (quote workspace-chat-inherit!))
                (workspace-chat-inherit! buf (group-name id)))
              buf))
          (else #f))))

;; A new conversation replaces the selected view. Creating a buffer does
;; not create panes or rearrange the buffers already on screen.
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
          ;; the named default first, so a group's own config overrides it
          (when (boundp (quote llm-default-bundle-apply!))
            (llm-default-bundle-apply! buf id))
          (chat-set-group! buf id)
          (group-record-update! id 'primary-chat-id (chat-stable-id! buf))
          (when (boundp (quote workspace-chat-inherit!))
            (workspace-chat-inherit! buf (group-name id)))
          ;; a group's chats share one window: the chat pane. A new chat
          ;; replaces the chat already there rather than take a pane of its own.
          (let ((pane (window-showing-mode "chat-mode")))
            (when pane (select-window! pane)))
          (switch-to-buffer-here! buf)
          (set-window-restore! (active-window) #f)
          (end-of-buffer!)
          buf))))

(define-command "group-chat" "Show or create the current group's primary chat"
  (lambda ()
    (let ((id (or (frame-local 'current-group)
                  (buffer-group (current-buffer)))))
      (if (not (group-resolve-id id))
          (message "No current group")
          (group-chat-show! id)))))

(define-command "group-home" "Open Dired at the current group's home directory"
  (lambda ()
    (let ((g (group-here)))
      (if (not g)
          (message "No current group")
          (let ((dir (group-home-dir g)))
            (make-directory! (string-append dir "/chats"))
            (dired-open dir))))))

(define (group-chat-buffer-show! buf)
  (let ((shown (window-showing buf))
        ;; the group's chat pane: one window holds every chat, so a second
        ;; chat takes the first one's place instead of a pane of its own.
        (pane (window-showing-mode "chat-mode")))
    (cond
      (shown (select-window! shown))
      (pane (select-window! pane) (switch-to-buffer-here! buf))
      (else
        ;; The chat joins the frame beside the panes already on it. A
        ;; collapse to one window and a split in two is only right for a
        ;; frame that shows one thing: a three-pane scene -- a mail index
        ;; and its preview -- lost the preview every time its chat opened,
        ;; and the group then had two buffers to tile instead of three.
        ;;
        ;; The frame's chosen layout is the frame's to keep: a C-x l pick
        ;; survives a pane opening, so the chat arranges by that name and
        ;; the width decides only for a frame that never chose.
        (panes-tile-default! (append (panes-shown-buffers) (list buf)))
        (let ((chat-window (window-showing buf)))
          (when chat-window (select-window! chat-window)))
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

(add-hook! (list 'preview-link "reply") chat-inject-reply!)

;; ask the group without leaving the current buffer: the minibuffer prompt
;; becomes a group-chat turn, point stays put, the reply lands on the right
(define (group-ask! g)
  (let ((src (current-buffer)) (pos (point)))
  (minibuffer-read (string-append "Ask " (group-display-name g) ": ") (history-items 'companion-ask)
    (lambda (prompt)
      (history-push! 'companion-ask prompt)
      (let* ((back (active-window))
             (chat (group-chat-new! g)))
        ;; a fresh chat each ask; it may cover SRC, the send names it first anyway
        (with-current-buffer chat
          (lambda ()
            (buffer-set-local! chat 'editor-context-source (list src pos))
            (insert! prompt)
            (run-command "agent-send")))
        (when (window-exists? back)
          (select-window! back)))))))

;; the group a joining buffer gets by default: the group the frame
;; stands in, else the most recent group in history. The buffer's own
;; group is never the default — joining it is a no-op. The answer is a
;; display name, because the prompt and the candidate list show it.
(define (group-join-default buf)
  ;; the frame leaves a group the moment a window shows an ungrouped
  ;; buffer (window-configuration-changed!), so "the group you last stood
  ;; in" is the MRU's head more often than the frame's slot
  (let loop ((ids (append (list (frame-group)
                                (group-resolve-id (frame-local 'previous-group)))
                          (group-ids-mru))))
    (cond ((null? ids) #f)
          ((and (car ids) (not (buffer-in-group? buf (car ids))))
           (group-name (car ids)))
          (else (loop (cdr ids))))))

(define (group-visible-work-buffers)
  (dedupe-names
    (filter group-membership-buffer?
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
              (for-each
                (lambda (buf)
                  (buffer-add-group! buf id)
                  ;; the mark that chose this buffer is spent, the same as
                  ;; `add`. A switcher mark dies with its list, but
                  ;; `buffer-select` writes the mark on the buffer and
                  ;; nothing else clears it: an unspent mark founds the
                  ;; NEXT group too, which reads as `new` moving a buffer
                  ;; nobody named, with your windows as its layout.
                  (buffer-set-local! buf 'buffer-selected #f))
                buffers)
              (when layout (group-layout-set! id layout))
              (switch-to-group! id)
              id)))))

;; a new name is typed, not chosen: the prompt offers no candidates.
;; Offered the existing names, RET on one answered "already exists".
(define (group-read-new-name prompt receive)
  (minibuffer-read prompt '()
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

;; The seed of `new` (docs/groups.md): a marked selection is the seed.
;; With none the seed is empty and the group opens on its scratch: `new`
;; founds a place to work, it never moves the buffer you were in.
(define-command "group-new" "Create and enter an empty group, or seed it with the selection"
  (lambda ()
    (let ((selected (group-command-selected-buffers)))
      (group-read-new-name "New group: "
        (lambda (name)
          (if (null? selected)
              (group-create-and-enter! name '() #f)
              ;; a marked set is an arrangement: the windows as they
              ;; stand become the group's first layout
              (group-create-and-enter! name selected (panes-layout))))))))

;; The "visible" verb: the windows as they stand are the seed, with no
;; marking. A group picked from the list takes the visible work buffers, and
;; the windows stay as they are. A new name founds a group from them, with
;; the windows as its first layout, and enters it.
(define-command "group-from-visible"
  "Move the visible windows, chats included, to a group: pick one, or type a new name to found it from these windows"
  (lambda ()
    (let ((buffers (group-visible-work-buffers)))
      (if (null? buffers)
          (message "No work buffers visible")
          (minibuffer-read (string-append "Move " (number->string (length buffers))
                                          (if (= (length buffers) 1) " window" " windows")
                                          " to (pick or type new): ")
                           (group-names)
            (lambda (input)
              (let* ((name (string-trim input))
                     (id (and (not (equal? name "")) (group-resolve-id name))))
                (cond ((equal? name "") (message "Group needs a name"))
                      (id (group-confirm-target! id
                            (lambda () (group-move-buffers-to! buffers id #t))))
                      (else (group-found-from-windows! name))))))))))

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

(define (buffer-family--eligible? name)
  (and (buffer-known? name)
       (group-work-buffer? name)))

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
    ;; The buffer named by the command is always the explicit subject, even
    ;; when its mode marks the listing special. Attached companions still
    ;; have to pass the ordinary eligibility gate: a special companion must
    ;; not travel with its owner.
    (dedupe-names
      (filter (lambda (name)
                (or (equal? name buf)
                    (buffer-family--eligible? name)))
              candidates))))

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

(define (switch-buffer-to-group! buf id)
  (switch-to-group! id)
  (let ((window (window-showing buf)))
    (if window (select-window! window) (switch-to-buffer! buf))))

;; the project root a buffer belongs to, or #f when it belongs to none
(define (group--project-root-of buf)
  (let ((root (buffer-project-root buf)))
    (and (string? root) (not (equal? root "")) root)))

(define (group-buffer-context-switch! buf)
  (let ((id (buffer-group buf))
        (root (group--project-root-of buf)))
    (cond
      ;; A project is a context that already exists. Enter it under the
      ;; root's name and take the project's other open buffers along.
      ;; Only a buffer with no project has to invent a name.
      ((and (not id) root)
       (let ((id (group-ensure-record! root)))
         (for-each
           (lambda (x)
             (when (and (group-work-buffer? x)
                        (not (buffer-group x))
                        (equal? (group--project-root-of x) root))
               (buffer-add-group! x id)))
           (buffer-list))
         (switch-buffer-to-group! buf id)))
      ((not id)
       (group-read-new-name "Start a group with this buffer: "
         (lambda (name) (group-create-with-buffer! name buf #f))))
      ;; A buffer belongs to ONE group, so there is never a group to
      ;; choose between. This used to be the system's only prompt.
      (else (switch-buffer-to-group! buf id)))))

(set! buffer-context-switch! group-buffer-context-switch!)

(define (group-all-work-buffers)
  (filter buffer-user-switchable? (buffer-list)))

;; The selection a membership verb acts on: SPC marks in every list,
;; marks in ibuffer, and `buffer-select` are views of one selection. A
;; command invoked from a list must not lose selections made on ordinary
;; buffers, and a repeated name is acted on once.
(define (group-command-selected-buffers)
  (let* ((buf (current-buffer))
         (mode (buffer-local buf 'mode-name))
         (marked (cond ((equal? mode "switch-mode")
                        (list-live-marked buf *list-mark-char*))
                       ;; every table of buffers marks the same way: the
                       ;; chats table is the buffers table over the chats
                       ((and (list-mode-of buf)
                             (equal? (list-opt buf 'category) 'buffer))
                        (filter buffer-known? (filter string? (list-targets buf))))
                       (else '())))
         (selected (filter (lambda (candidate)
                             (buffer-local candidate 'buffer-selected))
                           (buffer-list-mru))))
    (filter group-membership-buffer? (dedupe-names (append marked selected)))))

;; With no selection at all, the command means the current buffer.
(define (group-command-work-buffers)
  (let ((buf (current-buffer))
        (chosen (group-command-selected-buffers)))
    (cond ((pair? chosen) chosen)
          ((group-membership-buffer? buf) (list buf))
          (else '()))))

;; The prompt takes a typed name as well as a listed one, and a name it
;; does not know is a group to found — the same answer the "New group"
;; row gives. group-ensure-record! still refuses an id, so a dangling
;; membership cannot found a group named after itself.
(define (group-add-buffers-to! buffers destination)
  (let ((id (if (pseudo-group-id? (group-resolve-id destination))
                #f
                (group-ensure-record! destination)))
        (changed 0)
        (skipped 0))
    (if (not id)
        (message (if (group-resolve-id destination)
                     "That group computes its own members"
                     "No destination group"))
        (begin
          (for-each
            (lambda (buf)
              ;; a buffer holds ONE group, so joining this one is leaving
              ;; the last. A chat that already has a group is skipped:
              ;; only `move` sends a live chat somewhere else.
              (if (and (buffer-known? buf)
                       (group-membership-buffer? buf)
                       (buffer-add-group! buf id))
                  (begin
                    (buffer-set-local! buf 'buffer-selected #f)
                    (set! changed (+ changed 1)))
                  (set! skipped (+ skipped 1))))
            buffers)
          (message
            (string-append (number->string changed) " buffer"
                           (if (= changed 1) "" "s") " now in "
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

;; RET takes the default: the group the frame stands in, else the one it
;; last left, so a stray buffer joins the group you work in with one
;; press. A typed name joins that group, or founds it.
(define (group-add-read-destination! buffers)
  (let* ((default (group-join-default (current-buffer)))
         (names (filter (lambda (g) (not (equal? g default))) (group-names))))
    (minibuffer-read
      (if default
          (string-append "Put buffers in group (default " default "): ")
          "Put buffers in group: ")
      (append (if default (list (list default "last visited")) '())
              (list (list "New group" "create without entering"))
              names)
      (lambda (input)
        (let ((destination (if (equal? (string-trim input) "")
                               (or default "")
                               (string-trim input))))
          (cond
            ((equal? destination "") (message "Group needs a name"))
            ((equal? destination "New group")
             (group-read-new-name "New destination group: "
               (lambda (name)
                 (let ((id (group-record-create! name)))
                   (when id (group-add-buffers-to! buffers id))))))
;; a buffer holds one group, so this join is a move, and one
            ;; `move` back undoes it (docs/groups.md): no confirmation
            ;; stands between RET and the join
            (else
              (let ((id (or (group-resolve-id destination)
                            (group-record-create! destination))))
                (if id
                    (group-add-buffers-to! buffers id)
                    (message "Group needs a name"))))))))))

;; A move must show: a pane of the group the frame stands in stops
;; showing a buffer that left. The sweep is the same one a group switch
;; runs; the switch that follows saves what it leaves.
(define (group-move-sweep! here to)
  (when (and here (not (equal? here to)))
    (group-restore-sanitize! here)))

;; Put the buffers a move brought here on screen, and let the frame's own
;; layout algorithm place them: the one you were on becomes the main pane,
;; the rest join the stack. The arrangement is then this group's, so it is
;; what the group shows the next time you enter it.
(define (group-move-show! id buffers)
  (let ((mine (filter buffer-known? buffers)))
    (when (pair? mine)
      (for-each (lambda (buf)
                  (unless (member buf (panes-shown-buffers))
                    (display-buffer buf)))
                mine)
      (let ((w (window-showing (car mine))))
        (when w (select-window! w))))))

;; The screen already IS the destination's arrangement when every pane
;; shows a buffer of that group, or one of the buffers that is joining
;; it, and at least one joining buffer is on screen. The move is then a
;; membership change alone: the group adopts the windows as they stand,
;; and the arrangement the user made stays. A pane that carries no
;; context -- a float, a special buffer, a buffer no group holds -- says
;; nothing, so it does not stop the adoption. A pane of another group
;; does: that screen belongs to a different context, and the move leaves
;; it for the destination.
(define (group-move-screen-is-destination? id eligible)
  (let ((float (float-window)))
    (let loop ((rows (window-list)) (moving #f))
      (if (null? rows)
          moving
          (let* ((row (car rows))
                 (win (car row))
                 (buf (cadr row)))
            (cond ((or (equal? win float) (float--class? buf))
                   (loop (cdr rows) moving))
                  ((member buf eligible) (loop (cdr rows) #t))
                  ((buffer-in-group? buf id) (loop (cdr rows) moving))
                  ((not (group-membership-buffer? buf)) (loop (cdr rows) moving))
                  ((not (buffer-group buf)) (loop (cdr rows) moving))
                  (else #f)))))))

;; Enter ID without touching one window. The frame already shows the
;; group's own arrangement, so there is nothing to restore, and the
;; arrangement on screen becomes the one the group remembers. A restore
;; would rebuild the panes for the same picture and take the landing --
;; the window the person works in -- with them.
(define (group-enter-adopting! id)
  (let ((from (frame-group)))
    (when (and from (not (equal? from id)))
      (set-frame-local! 'previous-group from)))
  (set-frame-local! 'current-group id)
  (when (group-pinned) (set-frame-local! 'pinned-group id))
  (frame-group-label-refresh!)
  ;; no window changes, so the change path records nothing: the screen
  ;; becomes the group's arrangement here
  (group-layout-save! id)
  (group-mru-note! id)
  (windows-shown-catchup!))

;; The window half of a move, shared by both move paths: the selection
;; move and the move of the buffer you stand on. MEMBERS join TO, and the
;; frame enters TO. KEEP-WINDOWS? states that the screen already belongs
;; to the destination; the screen itself can say the same.
(define (group-move-into! members to &optional keep-windows?)
  (let ((here (frame-group))
        (adopt? (or keep-windows?
                    (group-move-screen-is-destination? to members))))
    (set! *group-current-inhibit* #t)
    (for-each (lambda (member) (buffer-move-to-group! member to)) members)
    ;; The old group repairs the panes the buffers left, unless the frame
    ;; shows nothing but buffers of the destination and the buffers that
    ;; are moving. The destination then adopts these windows as they are.
    (unless adopt? (group-move-sweep! here to))
    (set! *group-current-inhibit* #f)
    ;; Moving is a context change as well as a membership change: after the
    ;; buffers leave, enter the destination so the user is not left looking
    ;; at the old group's repaired layout.
    (if adopt?
        (group-enter-adopting! to)
        (begin
          (switch-to-group! to)
          ;; The destination's saved layout was made before these buffers
          ;; joined it, so entering the group draws it as it was and the
          ;; move looks like it did nothing. What moved is what you want
          ;; to see.
          (group-move-show! to members)))
    ;; A headline names the buffer's groups relative to the group the frame
    ;; stands in, and the frame entered another one. Re-derive it for every
    ;; buffer that moved: post-command! syncs the current buffer alone.
    (for-each (lambda (member)
                (when (buffer-known? member) (buffer-group-display-refresh! member)))
              members)
    (group-current-recalculate!)
    (run-hooks 'group-membership-hook)))

(define (group-move-buffers-to! buffers destination &optional keep-windows?)
  (let ((id (group-ensure-record! destination)))
    (cond
      ((not id) (message "No destination group"))
      (else
        (let ((eligible
               (filter (lambda (buf)
                         (and (buffer-known? buf)
                              (group-membership-buffer? buf)
                              (not (group-scratch-buffer? buf))))
                       buffers)))
          (group-move-into! eligible id keep-windows?)
          (message (string-append "Moved " (number->string (length eligible))
                                  " buffer"
                                  (if (= (length eligible) 1) "" "s")
                                  " to " (group-name id)))
          (length eligible))))))

;; The membership half of a move, for the group the frame already stands
;; in. `move` proper enters the destination when it is done; here there
;; is nothing to enter, and a restore of this group's saved layout would
;; take the windows away from under the user.
(define (group-move-buffers-here! buffers)
  (let ((id (group-here)))
    (if (not id)
        (begin (message "There is no group here") #f)
        (let ((eligible
                (filter (lambda (buf)
                          (and (buffer-known? buf)
                               (group-membership-buffer? buf)
                               (not (group-scratch-buffer? buf))))
                        buffers)))
          (for-each (lambda (buf) (buffer-move-to-group! buf id)) eligible)
          (run-hooks 'group-membership-hook)
          (message (string-append "Moved " (number->string (length eligible))
                                  " buffer" (if (= (length eligible) 1) "" "s")
                                  " to " (group-name id)))
          (length eligible)))))

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

;; The buffers a membership verb acts on for BUF. A chat and a group
;; scratch act on themselves: their family is the whole group, and moving
;; or removing that family would sweep every work buffer along. Any other
;; buffer acts on its family, minus the group's shared scratch, which is a
;; pane rather than a member.
(define (group-membership-targets buf)
  (if (or (chat-buffer? buf) (group-scratch-buffer? buf))
      (list buf)
      (remove group-scratch-buffer? (buffer-family buf))))

(define (buffer-move-family-to-group! buf destination)
  ;; a legacy owner-companion pair still moves as one
  (let ((family (group-membership-targets buf))
        (to (group-resolve-id destination)))
    (cond ((not to) (message "No destination group"))
          ((null? family) (message "Nothing to move"))
          (else
            ;; A single-buffer move has the same window semantics as a
            ;; selection move: the destination becomes current, and it adopts
            ;; the screen when the screen is already its own.
            (group-move-into! family to)
            (message (string-append "Moved " (number->string (length family))
                                    " buffer"
                                    (if (= (length family) 1) "" "s")
                                    " to " (group-name to)))
            family))))

(define-command "group-add" "Put the selected buffers, else this buffer, in a group"
  (lambda ()
    (let ((buffers (group-command-work-buffers)))
      (if (null? buffers)
          (message "No work buffer selected, and the current buffer is not one")
          (group-add-read-destination! buffers)))))

(define (buffer-move-read-destination! buf)
  (group-read-or-create! "Move buffer to group: "
    (lambda (group) (buffer-move-family-to-group! buf group))))

;; A selection moves as a set; the current buffer alone moves with its
;; family. A group scratch moves as its own buffer, and its group makes
;; a new blank pane when its layout needs one.
(define-command "group-move" "Move the selected buffers, else this buffer, to one group"
  (lambda ()
    (let ((buf (current-buffer))
          (selected (group-command-selected-buffers)))
      (cond ((pair? selected) (group-move-read-destination! selected))
            ((not (group-membership-buffer? buf))
             (message "The current buffer is not a work buffer"))
            (else (buffer-move-read-destination! buf))))))

(define (pull-buffer-candidates here)
  "The work buffers outside HERE, annotated as every buffer prompt is: mode, groups, project, path."
  (annotate 'buffer
            (filter (lambda (buf)
                      (and (group-membership-buffer? buf)
                           (not (group-scratch-buffer? buf))
                           (not (buffer-in-group? buf here))))
                    (buffer-list))))

(define-command "pull-buffer-here" "Pull a buffer from wherever it is into this group, and show it here"
  (lambda ()
    (let ((here (group-here)))
      (if (not here)
          (message "There is no group here")
          (minibuffer-read* "Pull buffer here: "
            (pull-buffer-candidates here)
            (list
              (list 'confirm
                (lambda (name)
                  (when (buffer-known? name)
                    (group-move-buffers-here! (group-membership-targets name))
                    (switch-to-buffer! name))))))))))
(catalog-meta! 'command "pull-buffer-here" 'domain 'buffers 'effects '(write))

(define (buffer-family-remove-group! buf id)
  (let ((members (filter (lambda (member) (buffer-in-group? member id))
                         (group-membership-targets buf))))
    (for-each (lambda (member) (buffer-remove-group! member id)) members)
    (when (pair? members) (run-hooks 'group-membership-hook))
    (message
      (if (null? members)
          "No buffer left the group"
          (string-append "Removed " (number->string (length members))
                         " buffer" (if (= (length members) 1) "" "s")
                         " from " (group-display-name id))))
    members))

(define-command "remove-group-from-buffer"
  "Take this buffer out of its group; y removes, n keeps"
  (lambda ()
    (let* ((buf (current-buffer))
           (id (buffer-group buf)))
      (if (not id)
          (message "The buffer is not in a group")
          (y-or-n (string-append "Remove " buf " from " (group-display-name id) "?")
                  (lambda () (buffer-family-remove-group! buf id)))))))

;; The other direction. One group is named by where the command runs, and
;; the buffers are the rows. A chat is a row like any other. A group
;; scratch is removed from the buffer side instead
;; (remove-group-from-buffer).
(define (group-remove-candidates names pending)
  (map
    (lambda (name)
      (list name
            (if (member name pending)
                "remove on C-g · RET keeps"
                "keep · RET removes")))
    names))

(define (group-remove-buffers! g names)
  (for-each
    (lambda (name)
      (when (buffer-in-group? name g) (buffer-remove-group! name g)))
    names)
  (when (pair? names) (run-hooks 'group-membership-hook))
  (message
    (if (null? names)
        "No buffer left the group"
        (string-append "Removed " (number->string (length names))
                       " buffer" (if (= (length names) 1) "" "s")
                       " from " (group-display-name g))))
  names)

(define (group-remove-read! g names pending)
  (minibuffer-read*
    (string-append "Toggle removal from " (group-display-name g)
                   " (C-g applies): ")
    (group-remove-candidates names pending)
    (list
      (list 'confirm
        (lambda (name)
          (group-remove-read! g names
            (cond ((member name pending)
                   (remove (lambda (held) (equal? held name)) pending))
                  ((member name names) (append pending (list name)))
                  (else pending)))))
      (list 'cancel (lambda () (group-remove-buffers! g pending)))
      (list 'style #f))))

(define-command "remove-buffers-from-group"
  "Toggle buffers out of this group; C-g applies"
  (lambda ()
    (let* ((g (if (in-groups-board?)
                  (groups--current)
                  (or (buffer-group (current-buffer)) (frame-group))))
           (names (if g
                      (remove group-scratch-buffer? (group-buffers-mru g))
                      '())))
      (cond ((not g) (message "Not in a group"))
            ((null? names) (message "The group has no buffer to remove"))
            (else (group-remove-read! g names '()))))))

(define (group-move-read-destination! buffers &optional keep-windows?)
  (minibuffer-read "Move buffers to group: "
    (cons (list "New group" "create without entering") (group-names))
    (lambda (destination)
      (if (equal? destination "New group")
          (group-read-new-name "New destination group: "
            (lambda (name)
              (let ((id (group-record-create! name)))
                (when id (group-move-buffers-to! buffers id keep-windows?)))))
          (let ((id (or (group-resolve-id destination)
                        (group-record-create! destination))))
            (group-confirm-target! id
              (lambda () (group-move-buffers-to! buffers id keep-windows?))))))))

;; `members` (docs/groups.md): the switcher, narrowed to one group. In the
;; board it is the group at point; elsewhere the current buffer's group.
(define-command "group-members" "Open the switcher on this group's members"
  (lambda ()
    (let ((g (if (in-groups-board?)
                 (groups--current)
                 (or (buffer-group (current-buffer)) (frame-group)))))
      (cond ((not g) (when (not (in-groups-board?)) (message "Not in a group")))
            ((boundp 'switch-open!) (switch-open! (list 'locked (group-name g))))
            (else (message (string-append (group-display-name g) ": "
                                          (string-join (group-buffers-mru g) " · "))))))))

;; make an existing conversation a group's chat: pick a buffer, join its
;; group (founding one named after it if it has none)
(define-command "chat-adopt" "Make this chat the companion of a chosen buffer"
  (lambda ()
    (let ((chat (current-buffer)))
      (minibuffer-read "Companion for buffer: "
        (annotate 'buffer (filter (lambda (b) (not (equal? b chat))) (buffer-list-mru)))
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
(define-command "chat-companion-ask" "Ask a new group chat about this buffer without leaving it"
  (lambda ()
    (let ((cur (current-buffer)))
      (if (chat-buffer? cur)
          (run-command "agent-send")
          (group-ask! (group-ensure! cur))))))



(mode-icon! "groups-mode" "")
;; the same glyph is what :group: reaches in a name format
(name-icon! "group" (mode-icon "groups-mode"))

;; C-x g switches groups; the other group verbs live under C-x C-g.
;; C-x G is the switcher's groups view (switch.scm).
(define (group-keymap-install!)
  (define-key "mode-specific-map" "g" "group-add")
  (define-key "mode-specific-map" "d" "group-describe")

  (define-key "ctl-x-map" "g" "group-switch")

  (define-key "buffer-group-map" "C-g" "group-switch-last")
  (define-key "buffer-group-map" "g" "buffer-goto-group")
  (define-key "buffer-group-map" "b" "group-members")
  (define-key "buffer-group-map" "p" "group-pin")
  (define-key "buffer-group-map" "a" "group-add")
  (define-key "buffer-group-map" "m" "group-move")
  (define-key "buffer-group-map" "n" "group-new")
  (define-key "buffer-group-map" "r" "remove-group-from-buffer")
  (define-key "buffer-group-map" "v" "group-from-visible"))

(group-keymap-install!)

;; Remove the previous vocabulary from hot-reloaded sessions: the names
;; docs/groups.md folded into group-add, group-move, the two removals,
;; group-switch, group-new, group-members, and the -at-point twins.
(for-each undefine-command
  '("group-pull-buffer" "group-push-buffer" "group-push-visible"
    "group-push-selected" "group-pop"
    "switch-to-group" "buffer-add-to-group" "buffer-move-to-group"
    "buffer-remove-from-group" "group-join"
    "group-new-with-buffer" "group-new-from-buffer"
    "group-rename-at-point" "group-kill-at-point" "group-describe-at-point"
    "group-list" "group-show-all" "group-chat-new"
    "switch-group" "ibuffer-group" "find-file-in-group"
    "opencode-in-group"))


(public! 'group-ids "(group-ids) -> durable opaque group IDs")
(public! 'group-name "(group-name ID) -> the current display name")
(public! 'buffer-context-only? "(buffer-context-only? NAME) — #t when NAME belongs to context but stays out of user buffer lists")
(public! 'buffer-context-only! "(buffer-context-only! NAME) — keep NAME as editable context without listing it")
(public! 'buffer-promote! "(buffer-promote! NAME) — make a context-only buffer user-switchable")
(catalog-meta! 'function "buffer-context-only?" 'domain 'buffers 'effects '(read))
(catalog-meta! 'function "buffer-context-only!" 'domain 'buffers 'effects '(write))
(catalog-meta! 'function "buffer-promote!" 'domain 'buffers 'effects '(write))
(public! 'buffer-in-group? "(buffer-in-group? NAME ID) -> membership")
(public! 'buffer-group-role "(buffer-group-role BUFFER GROUP) -> semantic role string or #f; chats answer \"chat\"")
(public! 'group-visible-homogeneous?
  "(group-visible-homogeneous? GROUP) -> #t when GROUP is the frame's derived current group")
(public! 'group-pinned "(group-pinned) -> the pinned frame group ID, or #f")
(public! 'group-current-recalculate!
  "(group-current-recalculate!) -> derive the frame's current group from its visible buffers")
(public! 'group-ids-mru "(group-ids-mru) -> this frame's group IDs in most-recently-used order")
(public! 'group-ids-mru-all "(group-ids-mru-all) -> every group ID, every frame, most recent first")
(public! 'group-frame-owner "(group-frame-owner G) -> the frame that keeps G, or #f")
(public! 'group-frame-own! "(group-frame-own! G FRAME) — make G belong to FRAME")
(public! 'group-here? "(group-here? G) -> #t when G belongs to this frame or to none")
(public! 'group-elsewhere-frame "(group-elsewhere-frame G) -> the other live frame that keeps G, or #f")
(public! 'group-adopt-here! "(group-adopt-here! G) — an unowned G joins this frame")
(public! 'frame-isolated? "(frame-isolated?) — #t when this frame shows only the groups it owns")
(public! 'frame-name "(frame-name [FRAME]) -> the name the user gave FRAME, or #f")
(public! 'frame-label "(frame-label FRAME) -> FRAME's name, else its id")
(public! 'frame-name-set! "(frame-name-set! FRAME NAME) — name FRAME; an empty NAME clears it")
(public! 'frame-by-label "(frame-by-label LABEL) -> the frame whose name or id is LABEL, or #f")
(public! 'group-move-to-frame! "(group-move-to-frame! G FRAME) — G belongs to FRAME and FRAME stands in it; a frame that stood in G steps off")
(public! 'buffer-family
  "(buffer-family BUFFER) -> the group-relative work family, including its shared scratch companion")
(public! 'buffer-add-group-as! "(buffer-add-group-as! BUFFER GROUP ROLE) — join GROUP with a semantic role")
(public! 'group-record-create! "(group-record-create! NAME) -> new stable ID or #f")
(public! 'group-parent "(group-parent G) -> the live parent group id, or #f")
(public! 'group-parent-set! "(group-parent-set! G PARENT) — record PARENT as the group G popped out of")
(public! 'group-setting "(group-setting G KEY) -> the group record's KEY, or #f")
(public! 'group-setting-set! "(group-setting-set! G KEY VALUE) — durable per-group state in the group record")
(catalog-meta! 'function "group-setting" 'domain 'buffers 'effects '(read))
(catalog-meta! 'function "group-setting-set!" 'domain 'buffers 'effects '(write))
(public! 'group-read-or-create!
  "(group-read-or-create! PROMPT RECEIVE) — read an existing group or create the typed name")
(public! 'switch-to-buffer-in-group!
  "(switch-to-buffer-in-group! B) — enter B's group, then focus B there; returns the group id or #f")
(public! 'group-here "(group-here) -> the group a verb run from a list means: the frame's, else the one it last left")
(public! 'group-home-of "(group-home-of B) -> the group to enter for B: this one when B is a member, else B's first")
(public! 'group-add-buffers-to! "(group-add-buffers-to! BUFFERS GROUP) — join GROUP; returns how many joined")
(public! 'group-move-buffers-here! "(group-move-buffers-here! BUFFERS) — move BUFFERS to the frame's current group, without a switch")
(public! 'buffer-group "(buffer-group NAME) -> the buffer's group tag or #f")
(effects! '(read))
(public! 'group-home-dir
  "(group-home-dir G) -> ~/.compos/groups/<id>, the directory G saves its chats, config and skills under"
  'buffers)
(public! 'buffer-color-group
  "(buffer-color-group NAME) -> the buffer-owned group that supplies its color, or #f"
  'buffers)
(public! 'group-color-face
  "(group-color-face G) -> the face name for G's colour slot, or \"accent\""
  'buffers)
(public! 'group-color-hex
  "(group-color-hex SLOT) -> the hex SLOT wears under the current theme, or #f"
  'buffers)
(public! 'buffer-filename-face
  "(buffer-filename-face NAME) -> the group color face for a buffer filename, or #f"
  'buffers)
(effects! '(write))
(public! 'group-buffers "(group-buffers G [ALL]) -> names of the live buffers of group G; ALL adds the ones unloaded to disk")
(public! 'define-pseudo-group!
  "(define-pseudo-group! NAME FN) — a group whose members FN answers, best first")
(public! 'undefine-pseudo-group! "(undefine-pseudo-group! G) — take a pseudo group away again")
(public! 'pseudo-group-buffers "(pseudo-group-buffers G) -> the members a pseudo group has now")
(public! 'pseudo-group-ids "(pseudo-group-ids) -> the id of every pseudo group")
(public! 'group-names-all "(group-names-all) -> every group name, the pseudo groups last")
(public! 'last-chats "(last-chats) -> the chats you used most recently, most recent first")
(public! 'mode-group-buffers "(mode-group-buffers MODE) -> the buffers in MODE, most recent first")
(public! 'mode-groups-refresh! "(mode-groups-refresh!) -- bring the mode groups up to the buffer list")
(public! 'buffer-goto-group! "(buffer-goto-group! B G) -- stand in G, then focus B there")
(public! 'group-buffers-as "(group-buffers-as GROUP ROLE) -> buffers with that group-relative role")
(public! 'group-buffer-as "(group-buffer-as GROUP ROLE) -> most recent buffer with ROLE, or #f")
(public! 'group-window-as "(group-window-as GROUP ROLE) -> visible window for ROLE, or #f")
(public! 'scene-buffer "(scene-buffer ROLE) -> current scene/group buffer with ROLE, or #f")
(public! 'scene-window "(scene-window ROLE) -> current scene/group window with ROLE, or #f")
(public! 'group-counts "(group-counts) -> (COUNT NAME ID) for every group, most members first")
(public! 'group-counts-report "(group-counts-report) -> group-counts as a name-and-count column with a total")
(public! 'group-chat "(group-chat G) — find or create G's chat buffer; returns its name")
(public! 'group-chat-show! "(group-chat-show! G) — open/focus G's chat pane; returns its name")
(public! 'chat-inject-reply!
  "(chat-inject-reply! TEXT) — put TEXT in this chat, or the current group's chat, without sending")
(public! 'chat-reply-link
  "(chat-reply-link LABEL REPLY) — a Markdown action link that fills a chat reply")

(catalog-meta! 'command "group-describe" 'domain 'buffers 'effects '(write external spend))
(catalog-meta! 'command "group-kill" 'domain 'buffers 'effects '(destroy))
(catalog-meta! 'command "groups" 'domain 'buffers 'effects '(read))
(catalog-meta! 'command "group-members" 'domain 'buffers 'effects '(read display))
(for-each
  (lambda (name) (catalog-meta! 'command name 'domain 'buffers 'effects '(write)))
  '("group-add" "group-move" "remove-group-from-buffer"
    "remove-buffers-from-group" "group-new" "group-rename"
    "group-from-visible"
    "group-dissolve" "group-revive"))
(for-each
  (lambda (name) (catalog-meta! 'command name 'domain 'windows 'effects '(write display)))
  '("group-switch" "group-switch-last"))
(catalog-meta! 'function "buffer-group" 'domain 'buffers 'effects '(read))
(catalog-meta! 'function "buffer-color-group" 'domain 'buffers 'effects '(read))
(catalog-meta! 'function "group-color-face" 'domain 'buffers 'effects '(read))
(catalog-meta! 'function "group-color-hex" 'domain 'buffers 'effects '(read))
(catalog-meta! 'function "buffer-filename-face" 'domain 'buffers 'effects '(read))
(catalog-meta! 'function "group-buffers" 'domain 'buffers 'effects '(read))
(catalog-meta! 'function "define-pseudo-group!" 'domain 'buffers 'effects '(write))
(catalog-meta! 'function "undefine-pseudo-group!" 'domain 'buffers 'effects '(write))
(catalog-meta! 'function "pseudo-group-buffers" 'domain 'buffers 'effects '(read))
(catalog-meta! 'function "pseudo-group-ids" 'domain 'buffers 'effects '(read))
(catalog-meta! 'function "group-names-all" 'domain 'buffers 'effects '(read))
(catalog-meta! 'function "last-chats" 'domain 'chat 'effects '(read))
(catalog-meta! 'function "mode-group-buffers" 'domain 'buffers 'effects '(read))
(catalog-meta! 'function "mode-groups-refresh!" 'domain 'buffers 'effects '(write))
(catalog-meta! 'function "buffer-goto-group!" 'domain 'buffers 'effects '(write display))
(catalog-meta! 'command "buffer-goto-group" 'domain 'groups 'effects '(write display))
(catalog-meta! 'function "group-counts" 'domain 'buffers 'effects '(read))
(catalog-meta! 'function "group-counts-report" 'domain 'buffers 'effects '(read))
(catalog-meta! 'function "group-chat" 'domain 'buffers 'effects '(write))
(catalog-meta! 'function "group-chat-show!" 'domain 'buffers 'effects '(write))
(catalog-meta! 'function "chat-inject-reply!" 'domain 'chat 'effects '(write display))
(catalog-meta! 'function "chat-reply-link" 'domain 'chat 'effects '(pure))

(group-current-recalculate!)
(message "groups.scm loaded")

;; the groups a running daemon holds from before origins
(group-migrate-path-names!)

;; the groups a running daemon holds from before colours were slots. A
;; fresh boot has no records yet and the desktop restore does this instead.
(set! *group-records* (group-record-colors-restore *group-records*))
(group-frame-styles-refresh!)
(modeline-groups-refresh!)

