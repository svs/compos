;;; bookmark.scm --- persistent named locations, based on GNU Emacs bookmark.el.
;;;
;;; A bookmark records a file or buffer, a byte position, nearby text, and
;;; an optional annotation. Context text repairs the position after edits.
;;; The store is Scheme data under <compos-home>. The list supports marks, filters,
;;; delete flags, annotations, rename, relocation, sorting, and import/export.

(package! 'bookmark)
(category! 'navigation)
(domain! 'navigation)
(effects! '(read))

(defgroup 'bookmark "Persistent named locations in files and buffers.")

(defcustom 'bookmark-default-file (string-append (compos-home) "/bookmarks.scd")
  "The default file that stores bookmarks." 'group 'bookmark 'type 'file)

(defcustom 'bookmark-save-frequency 1
  "Save after this many changes. Use #f to save only with bookmark-save."
  'group 'bookmark 'type 'number)

(defcustom 'bookmark-search-size 24
  "The number of context bytes saved before and after a bookmark."
  'group 'bookmark 'type 'number)

(defcustom 'bookmark-sort-order "name"
  "The list order: name, modified, or created."
  'group 'bookmark 'type 'string)

(defcustom 'bookmark-use-annotations #f
  "Open an annotation editor after bookmark-set creates a bookmark."
  'group 'bookmark 'type 'boolean)

(defcustom 'bookmark-automatically-show-annotations #t
  "Show a bookmark annotation after a jump."
  'group 'bookmark 'type 'boolean)

(defcustom 'bookmark-watch-file "silent"
  "Reload a changed bookmark file. Use silent, notify, or #f."
  'group 'bookmark 'type 'string)

(defcustom 'bookmark-backup-file #t
  "Write the previous store content to a tilde backup before saving."
  'group 'bookmark 'type 'boolean)

(define *bookmark-list-buffer* "*Bookmark List*")
(define *bookmark-annotation-buffer* "*Bookmark Annotation*")
(define *bookmark-annotation-edit-buffer* "*Edit Bookmark Annotation*")

(define *bookmarks* #f)
(define *bookmark-current-file* #f)
(define *bookmark-file-mtime* 0)
(define *bookmark-change-count* 0)
(define *bookmark-last-name* #f)
(define *bookmark-show-locations* #t)
(define *bookmark-handlers* '())
(define *bookmark-mode-handlers* '())

;; .scd means Scheme data. The editor parses it but does not load it.
(set! *auto-mode-alist*
  (cons '(".scd" "scheme-mode")
        (filter (lambda (entry) (not (equal? (car entry) ".scd")))
                *auto-mode-alist*)))

(define (bookmark--get record key &optional fallback)
  (or (plist-get (or record '()) key) fallback))

(define (bookmark--put record key value)
  (let loop ((rest record) (out '()) (seen #f))
    (cond ((null? rest)
           (if seen (reverse out) (append (reverse out) (list key value))))
          ((null? (cdr rest)) (reverse (cons (car rest) out)))
          ((equal? (car rest) key)
           (loop (cdr (cdr rest)) (cons value (cons key out)) #t))
          (else
           (loop (cdr (cdr rest))
                 (cons (cadr rest) (cons (car rest) out)) seen)))))

(define (bookmark--valid? record)
  (and (pair? record)
       (string? (bookmark--get record 'name #f))
       (string? (bookmark--get record 'handler #f))))

(define (bookmark--normalize record)
  (let* ((now (current-time))
         (created (bookmark--get record 'created now))
         (modified (bookmark--get record 'modified created)))
    (bookmark--put (bookmark--put record 'created created) 'modified modified)))

(define (bookmark--store-file)
  (or *bookmark-current-file* bookmark-default-file))

(define (bookmark--read-file path)
  (let* ((text (read-file path))
         (forms (and (string? text) (scheme-read text)))
         (data (and (pair? forms) (car forms))))
    (if (and forms (or (null? data) (pair? data)))
        (map bookmark--normalize (filter bookmark--valid? data))
        #f)))

(define (bookmark--load-file! path merge?)
  (let* ((full (expand-path path))
         (loaded (if (file-exists? full) (bookmark--read-file full) '()))
         (old (if (and merge? (pair? *bookmarks*)) *bookmarks* '())))
    (when (not loaded) (error "File is not Scheme bookmark data" full))
    (set! *bookmarks*
      (if merge?
          (fold (lambda (rows record)
                  (cons record
                        (filter (lambda (r)
                                  (not (equal? (bookmark--get r 'name "")
                                               (bookmark--get record 'name ""))))
                                rows)))
                old (reverse loaded))
          loaded))
    (set! *bookmark-current-file* full)
    (set! *bookmark-file-mtime* (file-mtime full))
    (set! *bookmark-change-count* 0)
    *bookmarks*))

(define (bookmark--ensure-loaded!)
  (let ((path (bookmark--store-file)))
    (cond
      ((not *bookmarks*) (bookmark--load-file! path #f))
      ((and bookmark-watch-file
            (file-exists? path)
            (> (file-mtime path) *bookmark-file-mtime*))
       (if (equal? bookmark-watch-file "silent")
           (bookmark--load-file! path #f)
           (begin
             (message "The bookmark file changed. Run bookmark-load to reload.")
             *bookmarks*)))
      (else *bookmarks*))))

(domain! 'navigation)
(effects! '(write))

(define (bookmark--write-file! path)
  (let ((full (expand-path path)))
    (when (and bookmark-backup-file (file-exists? full))
      (let ((old (read-file full)))
        (when (string? old) (write-file! (string-append full "~") old))))
    (write-file! full
      (string-append
        ";;; bookmarks.scd --- compos Scheme data, format 1.\n"
        ";;; This file contains data. Edit the plist records if necessary.\n"
        (value->string (or *bookmarks* '())) "\n"))
    full))

(define (bookmark-save!)
  (bookmark--ensure-loaded!)
  (let ((path (bookmark--write-file! (bookmark--store-file))))
    (set! *bookmark-file-mtime* (file-mtime path))
    (set! *bookmark-change-count* 0)
    path))

(define (bookmark--refresh-list!)
  (when (buffer-exists? *bookmark-list-buffer*)
    (list-refresh! *bookmark-list-buffer*)))

(define (bookmark--changed!)
  (set! *bookmark-change-count* (+ *bookmark-change-count* 1))
  (let ((n bookmark-save-frequency))
    (when (or (equal? n #t)
              (and (number? n) (>= *bookmark-change-count* (max 1 n))))
      (bookmark-save!)))
  (bookmark--refresh-list!))

;; A bookmark on a buffer with no file — a chat, a listing — is addressed
;; by its name alone, so a rename orphans it and the jump reports a
;; missing location. Move the pointer with the buffer. This never loads
;; the store: a rename before the first read has nothing to fix.
(on-buffer-renamed!
  (lambda (old new)
    (when (pair? *bookmarks*)
      (let ((hits (filter (lambda (record)
                            (equal? (bookmark--get record 'buffer #f) old))
                          *bookmarks*)))
        (when (pair? hits)
          (set! *bookmarks*
            (map (lambda (record)
                   (if (equal? (bookmark--get record 'buffer #f) old)
                       (bookmark--put record 'buffer new)
                       record))
                 *bookmarks*))
          (bookmark--changed!))))))

(domain! 'navigation)
(effects! '(read))

(define (bookmark-all-names)
  (map (lambda (record) (bookmark--get record 'name ""))
       (bookmark--ensure-loaded!)))

(define (bookmark-get name)
  (let loop ((records (bookmark--ensure-loaded!)))
    (cond ((null? records) #f)
          ((equal? (string-downcase (bookmark--get (car records) 'name ""))
                   (string-downcase name))
           (car records))
          (else (loop (cdr records))))))

(define (bookmark--without name records)
  (filter (lambda (record)
            (not (equal? (string-downcase (bookmark--get record 'name ""))
                         (string-downcase name))))
          records))

(define (bookmark--handler kind)
  (let ((entry (assoc kind *bookmark-handlers*)))
    (and entry (cdr entry))))

(define (bookmark--mode-handler mode)
  (let ((entry (assoc mode *bookmark-mode-handlers*)))
    (and entry (cadr entry))))

(domain! 'navigation)
(effects! '(write))

(define (bookmark-register-handler! kind make-fn jump-fn location-fn)
  (set! *bookmark-handlers*
    (cons (cons kind (list make-fn jump-fn location-fn))
          (remove (lambda (entry) (equal? (car entry) kind))
                  *bookmark-handlers*)))
  kind)

(define (bookmark-register-mode-handler! mode kind)
  (set! *bookmark-mode-handlers*
    (cons (list mode kind)
          (remove (lambda (entry) (equal? (car entry) mode))
                  *bookmark-mode-handlers*)))
  kind)

(define (bookmark--context record)
  (let* ((buf (current-buffer))
         (text (buffer-text buf))
         (size (string-byte-length text))
         (pos (max 0 (min (point) size)))
         (n (max 0 bookmark-search-size))
         (before (max 0 (- pos n)))
         (after (min size (+ pos n))))
    (append record
      (list 'buffer buf
            'position pos
            'front (substring-bytes text pos after)
            'rear (substring-bytes text before pos)))))

(define (bookmark--default-record)
  (bookmark--context
    (list 'handler "file"
          'filename (buffer-path (current-buffer)))))

(define (bookmark--make-record)
  (let* ((mode (or (buffer-local (current-buffer) 'mode-name) "Fundamental"))
         (kind (bookmark--mode-handler mode))
         (handler (and kind (bookmark--handler kind))))
    (if handler
        (bookmark--normalize
          (bookmark--put ((car handler) (current-buffer)) 'handler kind))
        (bookmark--normalize (bookmark--default-record)))))

(define (bookmark-store! name record overwrite?)
  (bookmark--ensure-loaded!)
  (let ((old (bookmark-get name)))
    (if (and old (not overwrite?))
        #f
        (let* ((now (current-time))
               (created (if old (bookmark--get old 'created now) now))
               (named (bookmark--put record 'name name))
               (dated (bookmark--put
                        (bookmark--put named 'created created) 'modified now)))
          (set! *bookmarks* (cons dated (bookmark--without name *bookmarks*)))
          (set! *bookmark-last-name* name)
          (buffer-set-local! (current-buffer) 'bookmark-current name)
          (bookmark--changed!)
          dated))))

(define (bookmark-delete! name)
  (bookmark--ensure-loaded!)
  (let ((old (bookmark-get name)))
    (when old
      (set! *bookmarks* (bookmark--without name *bookmarks*))
      (when (equal? *bookmark-last-name* name) (set! *bookmark-last-name* #f))
      (bookmark--changed!))
    (and old #t)))

(define (bookmark-rename! old-name new-name)
  (let ((record (bookmark-get old-name)))
    (cond ((not record) #f)
          ((and (bookmark-get new-name) (not (equal? old-name new-name))) #f)
          (else
            (set! *bookmarks*
              (cons (bookmark--put (bookmark--put record 'name new-name)
                                   'modified (current-time))
                    (bookmark--without old-name *bookmarks*)))
            (when (equal? *bookmark-last-name* old-name)
              (set! *bookmark-last-name* new-name))
            (bookmark--changed!)
            #t))))

(define (bookmark-set-annotation! name text)
  (let ((record (bookmark-get name)))
    (when record
      (set! *bookmarks*
        (cons (bookmark--put
                (bookmark--put record 'annotation text)
                'modified (current-time))
              (bookmark--without name *bookmarks*)))
      (bookmark--changed!)
      text)))

(define (bookmark-relocate! name filename)
  (let ((record (bookmark-get name)))
    (when record
      (set! *bookmarks*
        (cons (bookmark--put
                (bookmark--put record 'filename (expand-path filename))
                'modified (current-time))
              (bookmark--without name *bookmarks*)))
      (bookmark--changed!)
      #t)))

;;; --- context relocation ------------------------------------------------------

(domain! 'navigation)
(effects! '(read))

(define (bookmark--slice-equal? text start value)
  (let ((end (+ start (string-byte-length value))))
    (and (>= start 0)
         (<= end (string-byte-length text))
         (equal? (substring-bytes text start end) value))))

(define (bookmark--context-at? text pos front rear)
  (and (bookmark--slice-equal? text pos front)
       (bookmark--slice-equal? text (- pos (string-byte-length rear)) rear)))

(define (bookmark--context-candidates text needle offset)
  (if (equal? needle "") '()
      (let loop ((from 0) (out '()))
        (let ((hit (string-index text needle from)))
          (if hit
              (loop (+ hit 1) (cons (+ hit offset) out))
              (reverse out))))))

(define (bookmark--nearest positions wanted)
  (let loop ((rest positions) (best #f))
    (cond ((null? rest) best)
          ((or (not best)
               (< (abs (- (car rest) wanted)) (abs (- best wanted))))
           (loop (cdr rest) (car rest)))
          (else (loop (cdr rest) best)))))

(define (bookmark--repeat text count)
  (let loop ((n count) (out ""))
    (if (<= n 0) out (loop (- n 1) (string-append out text)))))

(define (bookmark-relocated-position record text)
  (let* ((size (string-byte-length text))
         (saved (max 0 (min (bookmark--get record 'position 0) size)))
         (front (bookmark--get record 'front ""))
         (rear (bookmark--get record 'rear "")))
    (cond
      ((and (not (equal? front "")) (not (equal? rear ""))
            (bookmark--context-at? text saved front rear)) saved)
      (else
        (let* ((fronts (bookmark--context-candidates text front 0))
               (both (filter (lambda (pos)
                               (bookmark--slice-equal?
                                 text (- pos (string-byte-length rear)) rear))
                             fronts))
               (rears (bookmark--context-candidates
                        text rear (string-byte-length rear))))
          (or (bookmark--nearest both saved)
              (bookmark--nearest fronts saved)
              (bookmark--nearest rears saved)
              saved))))))

(define (bookmark-location record)
  (let ((kind (bookmark--get record 'handler "file")))
    (if (equal? kind "file")
        (or (bookmark--get record 'filename #f)
            (bookmark--get record 'buffer ""))
        (let ((handler (bookmark--handler kind)))
          (if handler
              ((nth 2 handler) record)
              (or (bookmark--get record 'filename #f)
                  (bookmark--get record 'buffer kind)))))))

(define (bookmark--open-file-record! record disposition)
  (let* ((origin (current-buffer))
         (filename (bookmark--get record 'filename #f))
         (saved-buffer (bookmark--get record 'buffer #f))
         (file? (and filename (file-exists? filename)))
         (buffer? (and saved-buffer (buffer-exists? saved-buffer))))
    (if (not (or file? buffer?))
        (begin
          (message (string-append "Bookmark location is missing: "
                                  (or filename saved-buffer "unknown")))
          #f)
        (begin
          (if file? (visit filename) (switch-to-buffer! saved-buffer))
          (let* ((target (current-buffer))
                 (pos (bookmark-relocated-position record (buffer-text target))))
            (cond
              ((equal? disposition "current") (goto-char! pos))
              (else
                (unless (equal? target origin) (switch-to-buffer! origin))
                (let ((win (display-buffer-other-window! target)))
                  (buffer-goto! target pos)
                  (when (equal? disposition "other")
                    (select-window! win)
                    (switch-to-buffer! target)
                    (goto-char! pos)))))
            target)))))

(define (bookmark--show-annotation-after-jump record)
  (let ((annotation (bookmark--get record 'annotation "")))
    (when (and bookmark-automatically-show-annotations
               (not (equal? (string-trim annotation) "")))
      (bookmark--show-annotation record))))

(define (bookmark-jump! name &optional disposition)
  (let ((record (bookmark-get name)))
    (if (not record)
        (begin (message (string-append "No bookmark named " name)) #f)
        (let* ((kind (bookmark--get record 'handler "file"))
               (handler (bookmark--handler kind))
               (where (or disposition "current"))
               (target (if (equal? kind "file")
                           (bookmark--open-file-record! record where)
                           (and handler ((nth 1 handler) record where)))))
          (if (not target)
              (begin
                (unless handler
                  (message (string-append "No bookmark handler for " kind)))
                #f)
              (begin
                (set! *bookmark-last-name* name)
                (bookmark--show-annotation-after-jump record)
                target))))))

;;; --- prompts and commands ----------------------------------------------------

(define (bookmark--name-note name)
  (let ((record (bookmark-get name)))
    (if record
        (list (bookmark--get record 'handler "file")
              (bookmark-location record)
              (bookmark--get record 'annotation ""))
        '())))

(marginalia! 'bookmark bookmark--name-note)

(define (bookmark--candidates)
  (annotate 'bookmark (bookmark-all-names)))

(define (bookmark--read prompt callback)
  (let ((names (bookmark-all-names)))
    (if (null? names)
        (message "No bookmarks")
        (minibuffer-read prompt (bookmark--candidates) callback))))

(define (bookmark--default-name)
  (or (buffer-local (current-buffer) 'bookmark-current)
      (buffer-short-label (current-buffer))))

(define (bookmark--set-command overwrite?)
  (let ((record (bookmark--make-record))
        (default (bookmark--default-name)))
    (minibuffer-read
      (string-append "Set bookmark (default " default "): ")
      (bookmark--candidates)
      (lambda (input)
        (let ((name (if (equal? (string-trim input) "") default input)))
          (if (bookmark-store! name record overwrite?)
              (begin
                (message (string-append "Set bookmark " name))
                (when bookmark-use-annotations
                  (bookmark-edit-annotation-name! name)))
              (message (string-append "Bookmark exists: " name))))))))

(domain! 'navigation)
(effects! '(write))

(define-command "bookmark-set" "Set or replace a named bookmark at point"
  (lambda () (bookmark--set-command #t)))

(define-command "bookmark-set-no-overwrite" "Set a bookmark unless its name exists"
  (lambda () (bookmark--set-command #f)))

(domain! 'navigation)
(effects! '(read write))

(define-command "bookmark-jump" "Jump to a named bookmark"
  (lambda () (bookmark--read "Jump to bookmark: " bookmark-jump!)))

(define-command "bookmark-jump-other-window" "Jump to a bookmark in another window"
  (lambda ()
    (bookmark--read "Jump in other window: "
      (lambda (name) (bookmark-jump! name "other")))))

(define-command "bookmark-jump-last" "Jump to the most recently used bookmark"
  (lambda ()
    (if *bookmark-last-name*
        (bookmark-jump! *bookmark-last-name*)
        (message "No bookmark was used in this session"))))

(domain! 'navigation)
(effects! '(write))

(define-command "bookmark-delete" "Delete one named bookmark"
  (lambda ()
    (bookmark--read "Delete bookmark: "
      (lambda (name)
        (y-or-n (string-append "Delete bookmark " name "?")
          (lambda ()
            (bookmark-delete! name)
            (message (string-append "Deleted bookmark " name)))
          (lambda () (message "Bookmark kept")))))))

(define-command "bookmark-delete-all" "Delete all bookmarks after confirmation"
  (lambda ()
    (bookmark--ensure-loaded!)
    (y-or-n "Delete every bookmark?"
      (lambda ()
        (set! *bookmarks* '())
        (bookmark--changed!)
        (message "Deleted all bookmarks"))
      (lambda () (message "Bookmarks kept")))))

(define-command "bookmark-rename" "Rename one bookmark"
  (lambda ()
    (bookmark--read "Rename bookmark: "
      (lambda (old)
        (minibuffer-read (string-append "Rename " old " to: ") '()
          (lambda (new)
            (cond ((equal? (string-trim new) "") (message "A name is required"))
                  ((bookmark-rename! old new)
                   (message (string-append "Renamed bookmark to " new)))
                  (else (message (string-append "Bookmark exists: " new))))))))))

(define-command "bookmark-relocate" "Point one bookmark at another file"
  (lambda ()
    (bookmark--read "Relocate bookmark: "
      (lambda (name)
        (read-file-name (string-append "Relocate " name " to: ")
          (lambda (path)
            (bookmark-relocate! name path)
            (message (string-append "Relocated " name))))))))

(define-command "bookmark-save" "Save bookmarks to the current bookmark file"
  (lambda ()
    (message (string-append "Saved bookmarks to " (bookmark-save!)))))

(define-command "bookmark-write" "Write bookmarks to another file"
  (lambda ()
    (bookmark--ensure-loaded!)
    (read-file-name "Write bookmarks to: "
      (lambda (path)
        (bookmark--write-file! path)
        (message (string-append "Wrote bookmarks to " (expand-path path)))))))

(define-command "bookmark-load" "Load a bookmark file and replace the current set"
  (lambda ()
    (read-file-name "Load bookmarks from: "
      (lambda (path)
        (bookmark--load-file! path #f)
        (bookmark--refresh-list!)
        (message (string-append "Loaded " (number->string (length *bookmarks*))
                                " bookmarks"))))))

(define-command "bookmark-load-merge" "Merge a bookmark file into the current set"
  (lambda ()
    (read-file-name "Merge bookmarks from: "
      (lambda (path)
        (bookmark--load-file! path #t)
        (bookmark--changed!)
        (message (string-append "Merged bookmarks from " (expand-path path)))))))

(define-command "bookmark-insert-location" "Insert a bookmark location at point"
  (lambda ()
    (bookmark--read "Insert bookmark location: "
      (lambda (name)
        (let ((location (bookmark-location (bookmark-get name))))
          (when location (insert! location)))))))

(define-command "bookmark-insert" "Insert a bookmarked file's contents at point"
  (lambda ()
    (bookmark--read "Insert bookmarked file: "
      (lambda (name)
        (let* ((record (bookmark-get name))
               (path (bookmark--get record 'filename #f))
               (text (and path (read-file path))))
          (if (string? text) (insert! text)
              (message "This bookmark has no readable file")))))))

;;; --- annotations -------------------------------------------------------------

(define (bookmark--replace-buffer! buf text read-only?)
  (buffer-create buf)
  (buffer-set-read-only! buf #f)
  (buffer-delete-range! buf 0 (buffer-size buf))
  (buffer-append! buf text)
  (buffer-set-read-only! buf read-only?))

(define (bookmark--show-annotation record)
  (let* ((name (bookmark--get record 'name ""))
         (annotation (bookmark--get record 'annotation "")))
    (bookmark--replace-buffer!
      *bookmark-annotation-buffer*
      (string-append name "\n" (bookmark--repeat "=" (string-length name))
                     "\n\n" (if (equal? (string-trim annotation) "")
                                    "No annotation.\n"
                                    (string-append annotation "\n")))
      #t)
    (buffer-set-local! *bookmark-annotation-buffer* 'bookmark-name name)
    (buffer-set-local! *bookmark-annotation-buffer* 'mode-name
                       "bookmark-annotation-view-mode")
    (with-current-buffer *bookmark-annotation-buffer*
      (lambda () (set-mode! "bookmark-annotation-view-mode")))
    (display-buffer *bookmark-annotation-buffer*)))

(define (bookmark-edit-annotation-name! name)
  (let ((record (bookmark-get name)))
    (when record
      (bookmark--replace-buffer!
        *bookmark-annotation-edit-buffer*
        (bookmark--get record 'annotation "") #f)
      (buffer-set-local! *bookmark-annotation-edit-buffer* 'bookmark-name name)
      (buffer-set-local! *bookmark-annotation-edit-buffer* 'mode-name
                         "bookmark-annotation-edit-mode")
      (switch-to-buffer! *bookmark-annotation-edit-buffer*)
      (set-mode! "bookmark-annotation-edit-mode")
      (goto-char! (buffer-size *bookmark-annotation-edit-buffer*)))))

(define-command "bookmark-show-annotation" "Show one bookmark annotation"
  (lambda ()
    (bookmark--read "Show annotation: "
      (lambda (name) (bookmark--show-annotation (bookmark-get name))))))

(define-command "bookmark-show-all-annotations" "Show every nonempty bookmark annotation"
  (lambda ()
    (let ((rows
            (filter (lambda (record)
                      (not (equal? (string-trim
                                     (bookmark--get record 'annotation "")) "")))
                    (bookmark--ensure-loaded!))))
      (bookmark--replace-buffer!
        *bookmark-annotation-buffer*
        (if (null? rows)
            "No bookmark annotations.\n"
            (string-join
              (map (lambda (record)
                     (let ((name (bookmark--get record 'name "")))
                       (string-append name "\n"
                         (bookmark--repeat "-" (string-length name)) "\n"
                         (bookmark--get record 'annotation "") "\n")))
                   rows)
              "\n"))
        #t)
      (buffer-set-local! *bookmark-annotation-buffer* 'mode-name
                         "bookmark-annotation-view-mode")
      (with-current-buffer *bookmark-annotation-buffer*
        (lambda () (set-mode! "bookmark-annotation-view-mode")))
      (display-buffer *bookmark-annotation-buffer*))))

(define-command "bookmark-edit-annotation" "Edit one bookmark annotation"
  (lambda ()
    (bookmark--read "Edit annotation: " bookmark-edit-annotation-name!)))

(define-command "bookmark-annotation-save" "Save this bookmark annotation"
  (lambda ()
    (let ((name (buffer-local (current-buffer) 'bookmark-name))
          (text (buffer-text (current-buffer))))
      (if (not name)
          (message "This buffer does not name a bookmark")
          (begin
            (bookmark-set-annotation! name text)
            (buffer-mark-saved! (current-buffer))
            (run-command "quit-window")
            (message (string-append "Saved annotation for " name)))))))

(define-command "bookmark-annotation-abort" "Discard this bookmark annotation edit"
  (lambda ()
    (buffer-mark-saved! (current-buffer))
    (run-command "quit-window")
    (message "Discarded annotation edit")))

(define-command "bookmark-annotation-edit-current" "Edit the displayed bookmark annotation"
  (lambda ()
    (let ((name (buffer-local (current-buffer) 'bookmark-name)))
      (if name (bookmark-edit-annotation-name! name)
          (message "This view does not name one bookmark")))))

(mode-icon! "bookmark-annotation-view-mode" "")
(define-mode "bookmark-annotation-view-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-read-only! buf #t)
      )))

(mode-keys! "bookmark-annotation-view-mode"
  '(
    ("q" "quit-window")
    ("e" "bookmark-annotation-edit-current")))

(mode-doc! "bookmark-annotation-view-mode"
  "A read-only bookmark annotation. Use q to close it.")

(mode-icon! "bookmark-annotation-edit-mode" "")
(define-mode "bookmark-annotation-edit-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-read-only! buf #f)
      )))

(mode-keys! "bookmark-annotation-edit-mode"
  '(
    ("C-c C-c" "bookmark-annotation-save")
    ("C-c C-k" "bookmark-annotation-abort")))

(mode-doc! "bookmark-annotation-edit-mode"
  "Edit a bookmark annotation. Use C-c C-c to save or C-c C-k to discard.")

;;; --- bookmark list -----------------------------------------------------------

(define (bookmark--sort records)
  (cond
    ((equal? bookmark-sort-order "created")
     (map cadr
       (sort (map (lambda (record)
                    (list (- 0 (bookmark--get record 'created 0)) record))
                  records))))
    ((equal? bookmark-sort-order "modified")
     (map cadr
       (sort (map (lambda (record)
                    (list (- 0 (bookmark--get record 'modified 0)) record))
                  records))))
    (else
      (map cadr
        (sort (map (lambda (record)
                     (list (string-downcase (bookmark--get record 'name "")) record))
                   records))))))

(define (bookmark--rows buf)
  (bookmark--sort (bookmark--ensure-loaded!)))

(define (bookmark--time-label record key)
  (let ((time (bookmark--get record key 0)))
    (if (> time 0) (format-time time "%Y-%m-%d %H:%M") "")))

(define (bookmark--cells buf record)
  (let ((annotation (bookmark--get record 'annotation "")))
    (append
      (list (if (equal? (string-trim annotation) "") "" (list "●" "accent"))
            (bookmark--get record 'handler "file")
            (list (bookmark--get record 'name "") "accent"))
      (if *bookmark-show-locations*
          (list (bookmark-location record))
          '())
      (list (number->string (bookmark--get record 'position 0))
            (list (bookmark--time-label record 'modified) "dim")))))

(define (bookmark--columns buf)
  (append
    (list (list "" 1) (list "type" 10) (list "bookmark" 28))
    (if *bookmark-show-locations* (list (list "location" #f)) '())
    (list (list "pos" 8 'right) (list "modified" 17))))

(define (bookmark--meta buf)
  (string-append (number->string (length (list-entries buf))) " bookmarks · "
                 "sorted by " bookmark-sort-order
                 (if *bookmark-show-locations* " · locations shown"
                     " · locations hidden")))

(define (bookmark--delete-key! buf name)
  (bookmark-delete! name))

(define-command "bookmark-bmenu-visit" "Visit the bookmark on this row"
  (lambda ()
    (let ((record (list-current (current-buffer))))
      (when record (bookmark-jump! (bookmark--get record 'name ""))))))

(define-command "bookmark-bmenu-other-window" "Visit this bookmark in another window"
  (lambda ()
    (let ((record (list-current (current-buffer))))
      (when record
        (bookmark-jump! (bookmark--get record 'name "") "other")))))

(define-command "bookmark-bmenu-view-marked" "Preview marked bookmarks in other windows"
  (lambda ()
    (let ((records (list-targets (current-buffer))))
      (for-each (lambda (record)
                  (bookmark-jump! (bookmark--get record 'name "") "preview"))
                records)
      (message (string-append "Displayed " (number->string (length records))
                              " bookmarks")))))

(define-command "bookmark-bmenu-show-annotation" "Show this row's annotation"
  (lambda ()
    (let ((record (list-current (current-buffer))))
      (when record (bookmark--show-annotation record)))))

(define-command "bookmark-bmenu-edit-annotation" "Edit this row's annotation"
  (lambda ()
    (let ((record (list-current (current-buffer))))
      (when record
        (bookmark-edit-annotation-name! (bookmark--get record 'name ""))))))

(define-command "bookmark-bmenu-rename" "Rename the bookmark on this row"
  (lambda ()
    (let ((record (list-current (current-buffer))))
      (when record
        (let ((old (bookmark--get record 'name "")))
          (minibuffer-read (string-append "Rename " old " to: ") '()
            (lambda (new)
              (if (bookmark-rename! old new)
                  (message (string-append "Renamed bookmark to " new))
                  (message (string-append "Bookmark exists: " new))))))))))

(define-command "bookmark-bmenu-relocate" "Relocate the bookmark on this row"
  (lambda ()
    (let ((record (list-current (current-buffer))))
      (when record
        (let ((name (bookmark--get record 'name "")))
          (read-file-name (string-append "Relocate " name " to: ")
            (lambda (path) (bookmark-relocate! name path))))))))

(define-command "bookmark-bmenu-locate" "Show this row's location"
  (lambda ()
    (let ((record (list-current (current-buffer))))
      (when record (message (bookmark-location record))))))

(define-command "bookmark-bmenu-toggle-locations" "Show or hide bookmark locations"
  (lambda ()
    (set! *bookmark-show-locations* (not *bookmark-show-locations*))
    (list-refresh! (current-buffer))))

(define-command "bookmark-bmenu-cycle-sort" "Cycle bookmark list sorting"
  (lambda ()
    (set! bookmark-sort-order
      (cond ((equal? bookmark-sort-order "name") "modified")
            ((equal? bookmark-sort-order "modified") "created")
            (else "name")))
    (list-refresh! (current-buffer))
    (message (string-append "Sorted bookmarks by " bookmark-sort-order))))

(define-command "bookmark-bmenu-refresh" "Reload and refresh the bookmark list"
  (lambda ()
    (set! *bookmarks* #f)
    (list-refresh! (current-buffer))))

(mode-icon! "bookmark-bmenu-mode" "")

(define-list-mode! "bookmark-bmenu-mode"
  (list
    'doc (string-append
           "Persistent named locations. RET visits and o uses another window. "
           "m marks rows and v previews the targets. d flags deletion and x "
           "executes it. r renames, R relocates, e edits an annotation, and a "
           "shows it. t hides locations, s cycles sorting, and / filters rows.")
    'buffer *bookmark-list-buffer*
    'category 'bookmark
    'rows bookmark--rows
    'key (lambda (buf record) (bookmark--get record 'name ""))
    'columns bookmark--columns
    'cells bookmark--cells
    'title (lambda (buf) "Bookmarks")
    'meta bookmark--meta
    'total (lambda (buf) (length (bookmark--ensure-loaded!)))
    'footer (lambda (buf)
              '(("RET" "visit") ("o" "other window") ("m" "mark")
                ("v" "view targets") ("d" "flag delete") ("x" "execute")
                ("a/e" "annotation") ("r/R" "rename/relocate")
                ("s" "sort") ("t" "locations") ("/" "filter")
                ("g" "reload") ("q" "quit")))
    'flags (list (list "d" "D" "delete" bookmark--delete-key! #t))
    'noun "bookmark"
    'keys '(("RET" "bookmark-bmenu-visit")
            ("o" "bookmark-bmenu-other-window")
            ("v" "bookmark-bmenu-view-marked")
            ("a" "bookmark-bmenu-show-annotation")
            ("A" "bookmark-show-all-annotations")
            ("e" "bookmark-bmenu-edit-annotation")
            ("r" "bookmark-bmenu-rename")
            ("R" "bookmark-bmenu-relocate")
            ("w" "bookmark-bmenu-locate")
            ("t" "bookmark-bmenu-toggle-locations")
            ("s" "bookmark-bmenu-cycle-sort")
            ("g" "bookmark-bmenu-refresh")
            ("q" "quit-window"))))

(mode-doc! "bookmark-bmenu-mode"
  "A persistent bookmark table with filtering, marks, annotations, and batch deletion.")

(add-display-rule! *bookmark-list-buffer* 'popup)
(add-display-rule! *bookmark-annotation-buffer* 'popup '(side bottom size 0.32))

(define-command "list-bookmarks" "Show the bookmark management table"
  (lambda () (list-mode-show! "bookmark-bmenu-mode")))

(define-command "bookmark-bmenu-list" "Show the bookmark management table"
  (lambda () (list-mode-show! "bookmark-bmenu-mode")))

;;; --- Emacs-compatible global keys -------------------------------------------

(define-key "ctl-x-r-map" "m" "bookmark-set")
(define-key "ctl-x-r-map" "M" "bookmark-set-no-overwrite")
(define-key "ctl-x-r-map" "b" "bookmark-jump")
(define-key "ctl-x-r-map" "l" "list-bookmarks")

(catalog-meta! 'command "bookmark-delete" 'domain 'navigation 'effects '(destroy))
(catalog-meta! 'command "bookmark-delete-all" 'domain 'navigation 'effects '(destroy))

;;; --- public data API ---------------------------------------------------------

(domain! 'navigation)
(effects! '(read))

(public! 'bookmark-all-names
  "(bookmark-all-names) -> every bookmark name in storage order")
(public! 'bookmark-get
  "(bookmark-get NAME) -> one bookmark record or #f")
(public! 'bookmark-location
  "(bookmark-location RECORD) -> the record's display location")
(public! 'bookmark-relocated-position
  "(bookmark-relocated-position RECORD TEXT) -> repaired byte position")

(effects! '(write))

(public! 'bookmark-store!
  "(bookmark-store! NAME RECORD OVERWRITE?) -> store a bookmark record")
(public! 'bookmark-rename!
  "(bookmark-rename! OLD NEW) -> rename a bookmark when NEW is free")
(public! 'bookmark-set-annotation!
  "(bookmark-set-annotation! NAME TEXT) -> update one annotation")
(public! 'bookmark-relocate!
  "(bookmark-relocate! NAME FILE) -> change a bookmark file")
(public! 'bookmark-save!
  "(bookmark-save!) -> save bookmarks and return the store path")
(public! 'bookmark-register-handler!
  "(bookmark-register-handler! KIND MAKE JUMP LOCATION) -> add a bookmark type")
(public! 'bookmark-register-mode-handler!
  "(bookmark-register-mode-handler! MODE KIND) -> use KIND for MODE bookmarks")

(effects! '(destroy))

(public! 'bookmark-delete!
  "(bookmark-delete! NAME) -> delete a bookmark and save when configured")

(effects! '(read write))

(public! 'bookmark-jump!
  "(bookmark-jump! NAME [DISPOSITION]) -> visit a bookmark")
