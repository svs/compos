;;; paredit.scm --- structural s-expression editing.
;;;
;;; The scanner is pure Scheme over the buffer text, in byte offsets.
;;; It tolerates unbalanced text in the middle of an edit, and it needs
;;; no grammar. Commands act through buffer-replace-range!, so one
;;; command makes one undo step.
;;;
;;; M-x paredit-mode toggles the mode in one buffer. scheme-mode buffers
;;; enable it through their mode hook (see paredit-in-scheme-mode).

(package! 'paredit)
(category! 'edit)
(domain! 'edit)
(effects! '(write))

;;; --- the scanner -------------------------------------------------------------
;;; Pure functions from (TEXT POS) to a byte offset or #f. Delimiters
;;; are ASCII bytes, so byte comparison is UTF-8-safe: a continuation
;;; byte never equals "(".

(define (par--ch text i)
  (if (and (>= i 0) (< i (string-byte-length text)))
      (substring-bytes text i (+ i 1))
      #f))

(define (par--opener? c) (or (equal? c "(") (equal? c "[")))
(define (par--closer? c) (or (equal? c ")") (equal? c "]")))
(define (par--ws? c) (or (equal? c " ") (equal? c "\t") (equal? c "\n")))
(define (par--prefix? c)
  (or (equal? c "'") (equal? c "`") (equal? c ",") (equal? c "@")))

;; The scan anchor: the last column-0 "(" at or before POS, else 0.
;; The anchor bounds each scan to one top-level form. A "\n(" inside a
;; multi-line string defeats the heuristic (the Emacs caveat).
(define (par--anchor text pos)
  (if (<= pos 0)
      0
      (let ((idx (string-rindex (substring-bytes text 0 pos) "\n(")))
        (if idx (+ idx 1) 0))))

;; Walk TEXT from START to LIMIT. Return (MODE OPENERS EXTRA): MODE is
;; 'code, 'string, 'line-comment, or a block-comment depth; OPENERS
;; lists unclosed opener positions, innermost first; EXTRA is the start
;; of the current string or comment, else #f.
(define (par--state text start limit)
  (let loop ((i start) (mode 'code) (openers '()) (extra #f))
    (if (>= i limit)
        (list mode openers extra)
        (let ((c (par--ch text i)))
          (cond
            ((equal? mode 'string)
             (cond ((equal? c "\\") (loop (+ i 2) mode openers extra))
                   ((equal? c "\"") (loop (+ i 1) 'code openers #f))
                   (else (loop (+ i 1) mode openers extra))))
            ((equal? mode 'line-comment)
             (if (equal? c "\n")
                 (loop (+ i 1) 'code openers #f)
                 (loop (+ i 1) mode openers extra)))
            ((number? mode)
             (cond ((and (equal? c "#") (equal? (par--ch text (+ i 1)) "|"))
                    (loop (+ i 2) (+ mode 1) openers extra))
                   ((and (equal? c "|") (equal? (par--ch text (+ i 1)) "#"))
                    (loop (+ i 2) (if (= mode 1) 'code (- mode 1)) openers
                          (if (= mode 1) #f extra)))
                   (else (loop (+ i 1) mode openers extra))))
            ((equal? c "\"") (loop (+ i 1) 'string openers i))
            ((equal? c ";") (loop (+ i 1) 'line-comment openers i))
            ((and (equal? c "#") (equal? (par--ch text (+ i 1)) "|"))
             (loop (+ i 2) 1 openers i))
            ((and (equal? c "#") (equal? (par--ch text (+ i 1)) "\\"))
             ;; #\X is an atom: the delimiter byte after #\ is not a delimiter
             (loop (+ i 3) mode openers extra))
            ((par--opener? c) (loop (+ i 1) mode (cons i openers) extra))
            ((par--closer? c)
             (loop (+ i 1) mode (if (null? openers) openers (cdr openers)) extra))
            (else (loop (+ i 1) mode openers extra)))))))

(define (par--mode st) (car st))
(define (par--openers st) (cadr st))
(define (par--extra st) (caddr st))

;; The scan state at POS, from the nearest top-level anchor.
(define (par--ctx text pos)
  (par--state text (par--anchor text pos) pos))

;; Position after a "|#" that closes the "#|" at I.
(define (par--block-comment-end text i)
  (let ((n (string-byte-length text)))
    (let loop ((i (+ i 2)) (depth 1))
      (cond ((>= i n) n)
            ((and (equal? (par--ch text i) "#")
                  (equal? (par--ch text (+ i 1)) "|"))
             (loop (+ i 2) (+ depth 1)))
            ((and (equal? (par--ch text i) "|")
                  (equal? (par--ch text (+ i 1)) "#"))
             (if (= depth 1) (+ i 2) (loop (+ i 2) (- depth 1))))
            (else (loop (+ i 1) depth))))))

;; Position after the closing quote of the string body starting at I
;; (I is inside the string, after the opening quote).
(define (par--string-end text i)
  (let ((n (string-byte-length text)))
    (let loop ((i i))
      (cond ((>= i n) n)
            ((equal? (par--ch text i) "\\") (loop (+ i 2)))
            ((equal? (par--ch text i) "\"") (+ i 1))
            (else (loop (+ i 1)))))))

;; First position at or after I that starts a datum or a closer. Skips
;; whitespace and comments.
(define (par--skip text i)
  (let ((n (string-byte-length text)))
    (let loop ((i i))
      (if (>= i n)
          i
          (let ((c (par--ch text i)))
            (cond ((par--ws? c) (loop (+ i 1)))
                  ((equal? c ";")
                   (let ((nl (string-index text "\n" i)))
                     (if nl (loop (+ nl 1)) n)))
                  ((and (equal? c "#") (equal? (par--ch text (+ i 1)) "|"))
                   (loop (par--block-comment-end text i)))
                  (else i)))))))

;; Position after the closer that matches the opener at AT, or #f when
;; the list never closes.
(define (par--list-end text at)
  (let ((n (string-byte-length text)))
    (let loop ((i (+ at 1)) (mode 'code) (depth 1))
      (if (>= i n)
          #f
          (let ((c (par--ch text i)))
            (cond
              ((equal? mode 'string)
               (cond ((equal? c "\\") (loop (+ i 2) mode depth))
                     ((equal? c "\"") (loop (+ i 1) 'code depth))
                     (else (loop (+ i 1) mode depth))))
              ((equal? mode 'line-comment)
               (loop (+ i 1) (if (equal? c "\n") 'code mode) depth))
              ((number? mode)
               (cond ((and (equal? c "#") (equal? (par--ch text (+ i 1)) "|"))
                      (loop (+ i 2) (+ mode 1) depth))
                     ((and (equal? c "|") (equal? (par--ch text (+ i 1)) "#"))
                      (loop (+ i 2) (if (= mode 1) 'code (- mode 1)) depth))
                     (else (loop (+ i 1) mode depth))))
              ((equal? c "\"") (loop (+ i 1) 'string depth))
              ((equal? c ";") (loop (+ i 1) 'line-comment depth))
              ((and (equal? c "#") (equal? (par--ch text (+ i 1)) "|"))
               (loop (+ i 2) 1 depth))
              ((and (equal? c "#") (equal? (par--ch text (+ i 1)) "\\"))
               (loop (+ i 3) mode depth))
              ((par--opener? c) (loop (+ i 1) mode (+ depth 1)))
              ((par--closer? c)
               (if (= depth 1) (+ i 1) (loop (+ i 1) mode (- depth 1))))
              (else (loop (+ i 1) mode depth))))))))

;; End of the atom whose body continues at I.
(define (par--atom-end text i)
  (let ((n (string-byte-length text)))
    (let loop ((i i))
      (if (>= i n)
          i
          (let ((c (par--ch text i)))
            (if (or (par--ws? c) (par--opener? c) (par--closer? c)
                    (equal? c "\"") (equal? c ";"))
                i
                (loop (+ i 1))))))))

;; End of the datum at or after I, or #f at a closer or end of text.
;; I must be in code context.
(define (par-scan-forward text i)
  (let* ((n (string-byte-length text))
         (s (par--skip text i)))
    (if (>= s n)
        #f
        (let ((c (par--ch text s)))
          (cond ((par--closer? c) #f)
                ((par--prefix? c) (par-scan-forward text (+ s 1)))
                ((par--opener? c) (par--list-end text s))
                ((equal? c "\"") (par--string-end text (+ s 1)))
                ((and (equal? c "#") (par--opener? (par--ch text (+ s 1))))
                 (par--list-end text (+ s 1)))
                ((and (equal? c "#") (equal? (par--ch text (+ s 1)) "\\"))
                 (par--atom-end text (+ s 3)))
                (else (par--atom-end text (+ s 1))))))))

;; Starts of the datums between FROM and POS, innermost-last first.
(define (par--starts-before text from pos)
  (let loop ((i from) (acc '()))
    (let ((s (par--skip text i)))
      (if (or (>= s pos) (>= s (string-byte-length text)))
          acc
          (let ((c (par--ch text s)))
            (if (par--closer? c)
                acc
                (let ((e (par-scan-forward text s)))
                  (if (or (not e) (= e s))
                      acc
                      (loop e (cons s acc))))))))))

;; Start of the datum before POS at the same depth, or #f.
(define (par-scan-backward text pos)
  (let* ((st (par--ctx text pos))
         (from (if (null? (par--openers st))
                   (par--anchor text pos)
                   (+ (car (par--openers st)) 1)))
         (starts (par--starts-before text from pos)))
    (if (null? starts) #f (car starts))))

;; The enclosing opener position, or #f at top level.
(define (par-up text pos)
  (let ((os (par--openers (par--ctx text pos))))
    (if (null? os) #f (car os))))

;; The byte position of the closer of the enclosing list, or #f.
(define (par-close text pos)
  (let ((o (par-up text pos)))
    (if o
        (let ((e (par--list-end text o)))
          (if e (- e 1) #f))
        #f)))

;; Position inside the next nested list after POS, or #f.
(define (par-down text pos)
  (let ((n (string-byte-length text)))
    (let loop ((i pos))
      (let ((s (par--skip text i)))
        (if (>= s n)
            #f
            (let ((c (par--ch text s)))
              (cond ((par--closer? c) #f)
                    ((par--opener? c) (+ s 1))
                    ((par--prefix? c) (loop (+ s 1)))
                    ((equal? c "\"") (loop (par--string-end text (+ s 1))))
                    ((and (equal? c "#") (par--opener? (par--ch text (+ s 1))))
                     (+ s 2))
                    ((and (equal? c "#") (equal? (par--ch text (+ s 1)) "\\"))
                     (loop (par--atom-end text (+ s 3))))
                    (else (loop (par--atom-end text (+ s 1)))))))))))

;;; --- motion commands ---------------------------------------------------------

(define (paredit--with-text fn)
  (let ((buf (current-buffer)))
    (fn buf (buffer-text buf) (point))))

(define-command "paredit-forward" "Move forward across one expression"
  (lambda ()
    (paredit--with-text
      (lambda (buf text p)
        (let ((st (par--ctx text p)))
          (cond ((equal? (par--mode st) 'string)
                 (goto-char! (par--string-end text p)))
                ((not (equal? (par--mode st) 'code))
                 (message "In a comment"))
                (else
                 (let ((e (par-scan-forward text p)))
                   (if e
                       (goto-char! e)
                       (let ((s (par--skip text p)))
                         (if (and (< s (string-byte-length text))
                                  (par--closer? (par--ch text s)))
                             (goto-char! (+ s 1))
                             (message "No next expression"))))))))))))

(define-command "paredit-backward" "Move backward across one expression"
  (lambda ()
    (paredit--with-text
      (lambda (buf text p)
        (let ((st (par--ctx text p)))
          (cond ((equal? (par--mode st) 'string)
                 (goto-char! (par--extra st)))
                ((not (equal? (par--mode st) 'code))
                 (message "In a comment"))
                (else
                 (let ((s (par-scan-backward text p)))
                   (cond (s (goto-char! s))
                         ((not (null? (par--openers st)))
                          (goto-char! (car (par--openers st))))
                         (else (message "No previous expression")))))))))))

(define-command "paredit-backward-up" "Move to the enclosing opener"
  (lambda ()
    (paredit--with-text
      (lambda (buf text p)
        (let ((st (par--ctx text p)))
          (if (equal? (par--mode st) 'string)
              (goto-char! (par--extra st))
              (let ((o (par-up text p)))
                (if o (goto-char! o) (message "At top level")))))))))

(define-command "paredit-down" "Move into the next nested list"
  (lambda ()
    (paredit--with-text
      (lambda (buf text p)
        (let ((d (par-down text p)))
          (if d (goto-char! d) (message "No nested list here")))))))

(define-command "paredit-mark-sexp" "Set the mark after this expression"
  (lambda ()
    (paredit--with-text
      (lambda (buf text p)
        (let ((e (par-scan-forward text p)))
          (if e
              (begin (set-mark! e) (message "Mark set"))
              (message "No expression here")))))))

(define-command "paredit-kill-sexp" "Kill the expression after point"
  (lambda ()
    (paredit--with-text
      (lambda (buf text p)
        (let ((e (par-scan-forward text p)))
          (if e
              (kill-region-1 p e)
              (message "No expression here")))))))

;;; --- the mode ----------------------------------------------------------------
;;; Keys stay bound when the mode is off (there is no unbind primitive).
;;; Each key runs a dispatcher that falls through to the default
;;; behavior, the evil.scm shape.

;; (KEY COMMAND FALLBACK): FALLBACK is a command name, 'insert for
;; self-insert of KEY, or #f for a quiet no-op.
(define *paredit-keys*
  '(("C-M-f" "paredit-forward" "forward-sexp")
    ("C-M-b" "paredit-backward" "backward-sexp")
    ("C-M-u" "paredit-backward-up" "backward-up-list")
    ("C-M-d" "paredit-down" "down-list")
    ("C-M-k" "paredit-kill-sexp" #f)
    ("C-M-SPC" "paredit-mark-sexp" #f)))

(for-each
  (lambda (entry)
    (let ((key (car entry)) (cmd (cadr entry)) (fallback (caddr entry)))
      (define-command (string-append "paredit--key-" key)
        (lambda ()
          (cond ((minor-mode-on? (current-buffer) "paredit-mode")
                 (run-command cmd))
                ((equal? fallback 'insert) (insert! key))
                ((string? fallback) (run-command fallback))
                (else #f))))))
  *paredit-keys*)

(define (paredit--setup! buf)
  (for-each
    (lambda (entry)
      (local-set-key* buf (car entry)
                      (string-append "paredit--key-" (car entry))))
    *paredit-keys*))

(define (paredit--teardown! buf) #f)

(register-minor-mode! "paredit-mode" paredit--setup! paredit--teardown!)

(define-command "paredit-mode" "Toggle structural s-expression editing"
  (lambda ()
    (if (toggle-minor-mode! "paredit-mode")
        (message "paredit-mode enabled")
        (message "paredit-mode disabled"))))

(public! 'par-scan-forward
  "(par-scan-forward TEXT POS) — byte end of the datum at or after POS, or #f")
(public! 'par-scan-backward
  "(par-scan-backward TEXT POS) — byte start of the datum before POS, or #f")
(public! 'par-up "(par-up TEXT POS) — enclosing opener position, or #f")
(public! 'par-close "(par-close TEXT POS) — enclosing closer position, or #f")
