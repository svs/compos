;;; emacs-names.scm --- the Emacs names agents and users reach for, as compos calls.
;;;
;;; When Emacs named a concept, compos takes the name (the ruling in
;;; emacs-names-scheme-spelling). Each name here is one an agent called
;;; and found unbound, for a concept compos already has under its own
;;; name. Each one is thin: it calls the compos name and keeps the Emacs
;;; argument order. drive-eval-friction counts the unbound calls again.

(domain! 'buffers)
(effects! '(read))

;;;###autoload
(define (buffer-file-name &optional buf)
  "(buffer-file-name [BUF]) - the file BUF visits, or #f; no BUF means the current buffer. The Emacs name of buffer-path."
  (buffer-path (or buf (current-buffer))))

(public! 'buffer-file-name "(buffer-file-name [BUF]) — the file path a buffer visits, or #f; Emacs name, calls buffer-path" 'buffers)

;;;###autoload
(define (get-buffer name)
  "(get-buffer NAME) - NAME when a buffer of that name is live or dormant, else #f. Buffers are their names in compos. The Emacs name of buffer-known?."
  (and (string? name) (buffer-known? name) name))

(public! 'get-buffer "(get-buffer NAME) — NAME when that buffer exists, else #f; Emacs name, calls buffer-known?" 'buffers)

;;;###autoload
(define (buffer-name &optional buf)
  "(buffer-name [BUF]) - the name of BUF, or of the current buffer; #f when no such buffer. Buffers are their names in compos."
  (let ((b (or buf (current-buffer)))) (and (string? b) (buffer-known? b) b)))

(public! 'buffer-name "(buffer-name [BUF]) — the name of a buffer or of the current buffer; Emacs name, calls current-buffer" 'buffers)

(domain! 'windows)
(effects! '(read))

;;;###autoload
(define (selected-window)
  "(selected-window) - the id of the window the user works in. The Emacs name of active-window."
  (active-window))

(public! 'selected-window "(selected-window) — the id of the active window; Emacs name, calls active-window" 'windows)

;;;###autoload
(define (window-width &optional win)
  "(window-width [WIN]) - the text columns of WIN, or of the selected window. The Emacs name of window-cols."
  (if win (window-cols win) (window-cols)))

(public! 'window-width "(window-width [WIN]) — the text columns of a window; Emacs name, calls window-cols" 'windows)

(domain! 'commands)
(effects! '(read))

;;;###autoload
(define (lookup-key keymap key)
  "(lookup-key KEYMAP KEY) - what KEY runs in KEYMAP and its parents: a command name, 'prefix, or #f. KEYMAP is a keymap name, a string or a symbol such as 'text-mode-map; global-map is the global map. The Emacs name of keymap-lookup."
  (let ((name (if (string? keymap) keymap (value->string keymap))))
    (keymap-lookup (if (equal? name "global-map") "global" name) key)))

(public! 'lookup-key "(lookup-key KEYMAP KEY) — the command a key runs in a keymap; Emacs name, calls keymap-lookup" 'commands)

(domain! 'files)
(effects! '(read))

;;;###autoload
(define (expand-file-name name &optional dir)
  "(expand-file-name NAME [DIR]) - NAME as an absolute path: ~ is the home directory, and a relative NAME is under DIR, or under default-directory. The Emacs name of expand-path."
  (if (or (string-prefix? "/" name) (string-prefix? "~" name))
      (expand-path name)
      (let ((d (or dir (default-directory))))
        (expand-path (if (string-suffix? "/" d) (string-append d name) (string-append d "/" name))))))

(public! 'expand-file-name "(expand-file-name NAME [DIR]) — a path made absolute, ~ expanded; Emacs name, calls expand-path" 'files)

;;;###autoload
(define (directory-files dir &optional full match)
  "(directory-files DIR [FULL MATCH]) - the names in the directory DIR, sorted, without . and ..; FULL true gives full paths, MATCH is a regexp the names must match. The Emacs name of ls, which gives each entry with its type, size and date."
  (let* ((names (sort (map (lambda (e) (plist-get e 'name)) (ls dir))))
         (names (if match (filter (lambda (n) (re-match? match n)) names) names)))
    (if full
        (map (lambda (n) (if (string-suffix? "/" dir) (string-append dir n) (string-append dir "/" n))) names)
        names)))

(public! 'directory-files "(directory-files DIR [FULL MATCH]) — the file names in a directory, list a folder; Emacs name, calls ls" 'files)

(domain! 'files)
(effects! '(destroy))

;;;###autoload
(define (delete-file path)
  "(delete-file PATH) - delete the file PATH, or an empty directory; #t or an error. The Emacs name of delete-file!."
  (delete-file! path))

(public! 'delete-file "(delete-file PATH) — delete a file; Emacs name, calls delete-file!" 'files)

(domain! 'data)
(effects! '(pure))

;;;###autoload
(define (string-search needle haystack &optional start)
  "(string-search NEEDLE HAYSTACK [START]) - the character index of the first NEEDLE in HAYSTACK at or after START, or #f. Emacs argument order: the needle first. string-index answers a byte offset with the haystack first."
  (let* ((from (if start (string-byte-length (substring haystack 0 start)) 0))
         (i (string-index haystack needle from)))
    (and i (string-length (substring-bytes haystack 0 i)))))


;; The stub installs under effects unknown; stamp it pure before the file loads.
;;;###autoload
(public! 'string-search "(string-search NEEDLE HAYSTACK [START]) — find a substring: its character index, or #f; Emacs name, calls string-index" 'data)
;;;###autoload
(catalog-meta! 'function 'string-search 'effects '(pure))

;;;###autoload
(define (split-string s &optional separators omit-nulls)
  "(split-string STRING [SEPARATORS OMIT-NULLS]) - STRING cut at each match of the regexp SEPARATORS. With no SEPARATORS it cuts at runs of white space and drops the empty parts; OMIT-NULLS true drops them always. The Emacs name of string-split, which cuts at a literal separator."
  (let* ((sep (or separators "\\s+"))
         (drop? (or omit-nulls (not separators)))
         (spans (re-find* sep s))
         (parts (let loop ((sp spans) (from 0) (acc '()))
                  (if (null? sp)
                      (reverse (cons (substring-bytes s from (string-byte-length s)) acc))
                      (let ((a (car (car sp))) (b (cadr (car sp))))
                        (if (= a b) (loop (cdr sp) from acc)
                            (loop (cdr sp) b (cons (substring-bytes s from a) acc))))))))
    (if drop? (filter (lambda (p) (not (equal? p ""))) parts) parts)))

(public! 'split-string "(split-string STRING [SEPARATORS OMIT-NULLS]) — split a string at a regexp, white space by default; Emacs name of string-split" 'data)

;;;###autoload
(define (mapcar fn lst)
  "(mapcar FN LIST) - the list of FN applied to each element of LIST. The Emacs name of map."
  (map fn lst))

(public! 'mapcar "(mapcar FN LIST) — apply a function to each element; Emacs name of map" 'data)

;;;###autoload
(define (make-list n init)
  "(make-list N INIT) - a list of N elements, each INIT."
  (let loop ((k n) (acc '())) (if (<= k 0) acc (loop (- k 1) (cons init acc)))))

(public! 'make-list "(make-list N INIT) — a list of N copies of a value" 'data)

;;;###autoload
(define (pp-to-string v)
  "(pp-to-string VALUE) - VALUE printed as Scheme text. The Emacs name of value->string."
  (value->string v))

(public! 'pp-to-string "(pp-to-string VALUE) — a value printed as text; Emacs name of value->string" 'data)

(domain! 'data)
(effects! '(read))

;;;###autoload
(define (format-time-string fmt &optional time)
  "(format-time-string FORMAT [TIME]) - TIME, epoch seconds, or now, as local time in the strftime FORMAT. The Emacs name of format-time, which takes the time first."
  (format-time (or time (current-time)) fmt))

(public! 'format-time-string "(format-time-string FORMAT [TIME]) — format a date and time; Emacs name, calls format-time" 'data)

;;;###autoload
(define (current-time-string &optional time)
  "(current-time-string [TIME]) - TIME, epoch seconds, or now, as text like \"Mon Nov 09 17:34:14 2026\"."
  (format-time (or time (current-time)) "%a %b %d %H:%M:%S %Y"))

(public! 'current-time-string "(current-time-string [TIME]) — the date and time now as text; Emacs name, calls format-time" 'data)

(domain! 'help)
(effects! '(read))

;;;###autoload
(define (symbol-file name &optional type)
  "(symbol-file 'NAME [TYPE]) - the file that defines NAME, a function, command, variable or mode: the package's file on load-path, or #f for a builtin or an unknown name. The package is the file name without .scm. TYPE 'defun looks only at functions and commands, 'defvar only at variables. It reads the catalog, as apropos does."
  (let* ((n (if (string? name) name (value->string name)))
         (kinds (cond ((eq? type 'defun) '("function" "command"))
                      ((eq? type 'defvar) '("setting" "variable"))
                      (else '("function" "command" "setting" "variable" "mode"))))
         (pkg (let loop ((ks kinds))
                (if (null? ks) #f
                    (let ((e (catalog-entry (car ks) n)))
                      (if (and e (plist-get e 'package)) (plist-get e 'package) (loop (cdr ks))))))))
    (let ((f (and pkg (not (equal? pkg "builtins")) (locate-library pkg))))
      (and f (let* ((build "/_build/dev/lib/compos_core/priv/")
                    (i (string-index f build))
                    (src (and i (string-append (substring-bytes f 0 i) "/apps/compos_core/priv/"
                                               (substring-bytes f (+ i (string-byte-length build)) (string-byte-length f))))))
               (if (and src (file-exists? src)) src f))))))

(public! 'symbol-file "(symbol-file 'NAME [TYPE]) — which file or package defines a function, command or variable; #f for a builtin; Emacs name, reads the catalog" 'help)

(provide 'emacs-names)
