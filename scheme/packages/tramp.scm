;;; tramp.scm --- remote files over ssh (/ssh:host:/path), TRAMP-lite.
;;;
;;; The file operations the kernel calls (list-dir, directory-entries,
;;; file-stat, delete-file!, make-directory!, rename-file!, copy-file!,
;;; trash-file!, set-file-mode!, touch-file!, make-symlink!) branch on the
;;; /ssh: prefix here, and remote-visit opens a remote file as an ordinary
;;; buffer. Loaded from init.scm before dired, which lists directories.

(domain! 'files)
(effects! '(read))

;;; --- remote files (/ssh:host:/path — TRAMP-lite) ---------------------------
;;; Transport is two primitives (remote-read / remote-write; ssh underneath,
;;; so ~/.ssh/config aliases, agent and ControlMaster all apply). Everything
;;; else is policy here: a remote buffer is an ordinary file buffer whose
;;; path starts with /ssh: — modes, undo, revert (kill + re-visit) and
;;; desktop restore (re-fetch via visit) just work; only visit and
;;; save-buffer branch on the prefix.

(define (remote-path? p) (string-prefix? "/ssh:" p))

;; "/ssh:user@host:/path" -> (host path), #f if malformed
(define (remote-parse p)
  (let ((rest (substring p 5 (string-length p))))
    (let ((i (string-index rest ":")))
      (and i (> i 0)
           (list (substring rest 0 i)
                 (substring rest (+ i 1) (string-length rest)))))))

;; One ls -lA round-trip per directory feeds both list-dir and file-stat:
;; listing a dir re-fetches and caches, stat lookups ride the cache — so a
;; dired refresh costs one ssh call, not one per file.
(define *remote-ls-cache* '())   ; ((dir ((name (perms size date)) ...)) ...)
(define *remote-ls-errors* '())  ; ((dir message) ...)

(define (remote-dir-key d)       ; ".../log/" -> ".../log", but keep ":/" roots
  (if (and (string-suffix? "/" d) (not (string-suffix? ":/" d)))
      (substring d 0 (- (string-length d) 1))
      d))

(define (remote-ls! dir0)
  (let ((dir (remote-dir-key dir0)))
    (let ((hp (remote-parse dir)))
      (if (not hp)
          '()
          (let ((r (remote-list-dir (car hp) (cadr hp))))
            (if (and (pair? r) (symbol? (car r)))   ; (error MSG)
                (begin
                  (set! *remote-ls-errors* (alist-put *remote-ls-errors* dir (cadr r)))
                  (message (cadr r))
                  '())
                (begin
                  (set! *remote-ls-errors*
                    (filter (lambda (e) (not (equal? (car e) dir)))
                            *remote-ls-errors*))
                  (set! *remote-ls-cache* (alist-put *remote-ls-cache* dir r))
                  r)))))))

(define (remote-ls-cached dir0)
  (let ((c (assoc (remote-dir-key dir0) *remote-ls-cache*)))
    (if c (cadr c) (remote-ls! dir0))))

(define (remote-sh! host cmd)
  (let ((r (remote-sh host cmd)))
    (if (pair? r) (begin (message (cadr r)) #f) #t)))

;; list-dir / file-stat / delete-file! / make-directory! grow a remote
;; branch under the same names and contracts — dired, file completion and
;; friends work on /ssh: paths without knowing it.
(define (list-dir dir)
  (if (remote-path? dir)
      (map car (remote-ls! dir))
      (local-list-dir dir)))

(define (remote-entry-type perms)
  (cond ((string-prefix? "d" perms) "directory")
        ((string-prefix? "l" perms) "symlink")
        ((string-prefix? "-" perms) "regular")
        (else "other")))

(define (remote-entry-info entry)
  (let* ((name (car entry))
         (st (cadr entry))
         (n (string->number (cadr st))))
    (list 'name name
          'type (remote-entry-type (car st))
          'bytes (if (number? n) n 0)
          'mtime 0
          'size (cadr st)
          'date (caddr st)
          'perms (car st))))

(define (directory-entries dir)
  (if (remote-path? dir)
      (let ((entries (remote-ls! dir))
            (failure (assoc (remote-dir-key dir) *remote-ls-errors*)))
        (if failure
            (list 'error (cadr failure))
            (map remote-entry-info entries)))
      (local-directory-entries dir)))

(define (file-stat p0)
  (if (remote-path? p0)
      (let ((parts (path-split (remote-dir-key p0))))
        (let ((entries (remote-ls-cached (car parts)))
              (base (cadr parts)))
          (let ((e (or (assoc base entries)
                       (assoc (string-append base "/") entries))))
            (if e (cadr e) (list "----------" "?" "?")))))
      (local-file-stat p0)))

(define (delete-file! p)
  (if (remote-path? p)
      (let ((hp (remote-parse p)))
        (let ((q (sh-quote (cadr hp))))
          ;; parity with the local primitive: files rm, dirs rmdir (empty only)
          (remote-sh! (car hp)
            (string-append "if [ -L " q " ]; then rm -- " q
                           "; elif [ -d " q " ]; then rmdir -- " q
                           "; else rm -- " q "; fi"))))
      (local-delete-file! p)))

(define (make-directory! p)
  (if (remote-path? p)
      (let ((hp (remote-parse p)))
        (remote-sh! (car hp) (string-append "mkdir -p -- " (sh-quote (cadr hp)))))
      (local-make-directory! p)))

(define (rename-file! source destination)
  (cond
    ((and (remote-path? source) (remote-path? destination))
     (let ((from (remote-parse source)) (to (remote-parse destination)))
       (if (not (equal? (car from) (car to)))
           (begin (message "Remote rename requires one host") #f)
           (and (remote-sh! (car from)
                  (string-append "mkdir -p -- "
                                 (sh-quote (path-directory (cadr to)))
                                 " && test ! -e " (sh-quote (cadr to))
                                 " && mv -- " (sh-quote (cadr from))
                                 " " (sh-quote (cadr to))))
                destination))))
    ((or (remote-path? source) (remote-path? destination))
     (message "Copy between local and remote paths first")
     #f)
    (else
      (let ((done (local-rename-file! source destination)))
        ;; the buffer moved with its file: window histories follow it
        (when (and done (boundp 'window-records-renamed!))
          (window-records-renamed! (expand-path source) (expand-path destination)))
        done))))

(define (copy-file! source destination)
  (cond
    ((and (remote-path? source) (remote-path? destination))
     (let ((from (remote-parse source)) (to (remote-parse destination)))
       (if (not (equal? (car from) (car to)))
           (begin (message "Remote copy requires one host") #f)
           (and (remote-sh! (car from)
                  (string-append "mkdir -p -- "
                                 (sh-quote (path-directory (cadr to)))
                                 " && test ! -e " (sh-quote (cadr to))
                                 " && cp -R -- " (sh-quote (cadr from))
                                 " " (sh-quote (cadr to))))
                destination))))
    ((or (remote-path? source) (remote-path? destination))
     (message "Local and remote copy is not available")
     #f)
    (else (local-copy-file! source destination))))

(define (trash-file! p)
  (if (remote-path? p)
      (let* ((hp (remote-parse p))
             (q (sh-quote (cadr hp))))
        (remote-sh! (car hp)
          (string-append
            "trash=\"$HOME/.local/share/Trash/files\"; mkdir -p -- \"$trash\"; "
            "base=$(basename -- " q "); target=\"$trash/$base\"; n=1; "
            "while [ -e \"$target\" ]; do target=\"$trash/$base.$n\"; n=$((n+1)); done; "
            "mv -- " q " \"$target\"")))
      (local-trash-file! p)))

(define (set-file-mode! p mode)
  (if (remote-path? p)
      (let ((hp (remote-parse p)))
        (remote-sh! (car hp)
          (string-append "chmod -- " (sh-quote mode) " " (sh-quote (cadr hp)))))
      (local-set-file-mode! p mode)))

(define (touch-file! p)
  (if (remote-path? p)
      (let ((hp (remote-parse p)))
        (remote-sh! (car hp) (string-append "touch -- " (sh-quote (cadr hp)))))
      (local-touch-file! p)))

(define (make-symlink! target link)
  (cond
    ((and (remote-path? target) (remote-path? link))
     (let ((from (remote-parse target)) (to (remote-parse link)))
       (if (not (equal? (car from) (car to)))
           (begin (message "Remote link requires one host") #f)
           (remote-sh! (car from)
             (string-append "ln -s -- " (sh-quote (cadr from))
                            " " (sh-quote (cadr to)))))))
    ((remote-path? link)
     (let ((to (remote-parse link)))
       (remote-sh! (car to)
         (string-append "ln -s -- " (sh-quote target)
                        " " (sh-quote (cadr to))))))
    ((remote-path? target)
     (message "A local link cannot target a remote path")
     #f)
    (else (local-make-symlink! target link))))

(define (remote-visit path)
  (if (buffer-exists? path)
      (begin
        (switch-to-buffer! path)
        (current-buffer))
      (let ((hp (remote-parse path)))
        (if (not hp)
            (begin
              (message "Remote path is /ssh:HOST:/PATH")
              #f)
            (let ((r (remote-read (car hp) (cadr hp))))
              (cond
                ((equal? r 'directory) (dired-open path))
                ((pair? r)   ; (error MSG) — unreachable host, unreadable file
                 (message (string-append path ": " (cadr r)))
                 #f)
                (else
                  (begin
                    ;; find-file names the buffer after the path and records
                    ;; it as the buffer's file (no such local file — empty)
                    (find-file path)
                    (when (string? r)
                      (buffer-insert! path 0 r)
                      (buffer-mark-saved! path))
                    (switch-to-buffer! path)
                    (goto-char! 0)
                    (auto-mode path)
                    (run-hooks 'find-file-hook)
                    (if (equal? r 'absent) (message "(New remote file)"))
                    (current-buffer)))))))))

(domain! 'unknown)
(effects! '(unknown))
