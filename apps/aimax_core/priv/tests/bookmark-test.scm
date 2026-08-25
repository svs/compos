;;; bookmark-test.scm --- persistent bookmark policy.

(domain! 'testing)
(effects! '(write))

(define t--bm-held '())
(define t--bm-dir (string-append (aimax-home) "/zz-bookmark"))
(define t--bm-store (string-append t--bm-dir "/bookmarks.scd"))
(define t--bm-file (string-append t--bm-dir "/notes.txt"))

(define (t--bm-setup!)
  (set! t--bm-held
    (list *bookmarks* *bookmark-current-file* *bookmark-file-mtime*
          *bookmark-change-count* *bookmark-last-name* bookmark-save-frequency))
  (make-directory! t--bm-dir)
  (write-file! t--bm-file "alpha\nbeta target\ngamma\n")
  (set! *bookmarks* '())
  (set! *bookmark-current-file* t--bm-store)
  (set! *bookmark-file-mtime* 0)
  (set! *bookmark-change-count* 0)
  (set! *bookmark-last-name* #f)
  (set! bookmark-save-frequency 1))

(define (t--bm-teardown!)
  (for-each (lambda (buf)
              (when (buffer-exists? buf) (buffer-kill! buf)))
            (list t--bm-file *bookmark-list-buffer*
                  *bookmark-annotation-buffer* *bookmark-annotation-edit-buffer*))
  (when (file-exists? t--bm-store) (delete-file! t--bm-store))
  (when (file-exists? (string-append t--bm-store "~"))
    (delete-file! (string-append t--bm-store "~")))
  (when (file-exists? t--bm-file) (delete-file! t--bm-file))
  (when (file-directory? t--bm-dir) (delete-file! t--bm-dir))
  (set! *bookmarks* (nth 0 t--bm-held))
  (set! *bookmark-current-file* (nth 1 t--bm-held))
  (set! *bookmark-file-mtime* (nth 2 t--bm-held))
  (set! *bookmark-change-count* (nth 3 t--bm-held))
  (set! *bookmark-last-name* (nth 4 t--bm-held))
  (set! bookmark-save-frequency (nth 5 t--bm-held)))

(define (t--bm-record-at pos)
  (visit t--bm-file)
  (goto-char! pos)
  (bookmark--make-record))

(deftest 'bookmark-records-round-trip-through-scheme-data
  "a saved record returns with its context and annotation"
  (lambda ()
    (t--bm-setup!)
    (let ((record (bookmark--put (t--bm-record-at 11) 'annotation "Read this")))
      (bookmark-store! "target" record #t)
      (set! *bookmarks* #f)
      (let ((loaded (bookmark-get "target")))
        (check-equal! (bookmark--get loaded 'annotation "") "Read this"
                      "the annotation survives")
        (check-equal! (bookmark--get loaded 'position 0) 11
                      "the byte position survives")
        (check-true! (file-exists? t--bm-store) "the store exists")))
    (t--bm-teardown!)))

(deftest 'bookmark-context-repairs-a-position-after-an-edit
  "nearby text finds the location after text is inserted above it"
  (lambda ()
    (t--bm-setup!)
    (let* ((record (t--bm-record-at 11))
           (edited "new line\nalpha\nbeta target\ngamma\n"))
      (check-equal! (bookmark-relocated-position record edited) 20
                    "the target moves by the inserted bytes"))
    (t--bm-teardown!)))

(deftest 'bookmark-rename-and-delete-update-the-store
  "management verbs change both memory and persistent Scheme data"
  (lambda ()
    (t--bm-setup!)
    (bookmark-store! "old" (t--bm-record-at 6) #t)
    (check-true! (bookmark-rename! "old" "new") "rename succeeds")
    (check-false! (bookmark-get "old") "the old name is absent")
    (check-true! (bookmark-get "new") "the new name exists")
    (bookmark-delete! "new")
    (set! *bookmarks* #f)
    (check-false! (bookmark-get "new") "delete survives reload")
    (t--bm-teardown!)))

(deftest 'bookmark-list-renders-management-fields
  "the list shows names, locations, annotations, and its real mode"
  (lambda ()
    (t--bm-setup!)
    (bookmark-store! "target" (bookmark--put (t--bm-record-at 11)
                                              'annotation "Read this") #t)
    (list-mode-show! "bookmark-bmenu-mode")
    (check-equal! (buffer-local *bookmark-list-buffer* 'mode-name)
                  "bookmark-bmenu-mode" "the mode survives restore")
    (check-contains! (buffer-text *bookmark-list-buffer*) "target"
                     "the name is visible")
    (check-contains! (buffer-text *bookmark-list-buffer*) "notes.txt"
                     "the location is visible")
    (check-contains! (buffer-text *bookmark-list-buffer*) "●"
                     "the annotation mark is visible")
    (t--bm-teardown!)))

(deftest 'scheme-data-files-open-with-scheme-syntax
  ".scd marks data while retaining Scheme editing support"
  (lambda ()
    (check-equal! (auto-mode-for "bookmarks.scd") "scheme-mode"
                  "Scheme data gets Scheme syntax")))

(deftest 'malformed-bookmark-data-is-not-an-empty-store
  "a parse failure must stop a later save from replacing the file"
  (lambda ()
    (t--bm-setup!)
    (write-file! t--bm-store "(not closed\n")
    (check-false! (bookmark--read-file t--bm-store)
                  "invalid Scheme data is rejected")
    (t--bm-teardown!)))
