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

;;; --- pair insertion ----------------------------------------------------------

(define (par--atom-char? c)
  (and c
       (not (par--ws? c)) (not (par--opener? c)) (not (par--closer? c))
       (not (equal? c "\"")) (not (equal? c ";"))))

;; True when the byte at I is the X of a #\X character literal.
(define (par--char-lit-at? text i)
  (and (equal? (par--ch text (- i 1)) "\\")
       (equal? (par--ch text (- i 2)) "#")))

;; Insert OPEN CLOSE at P with a separating space on each side that
;; touches another datum. Leave point between the pair.
(define (paredit--pair! text p open close)
  (let* ((prev (par--ch text (- p 1)))
         (next (par--ch text p))
         (pre (if (and prev
                       (not (par--prefix? prev))
                       (not (equal? prev "#"))
                       (or (par--atom-char? prev)
                           (par--closer? prev)
                           (equal? prev "\"")))
                  " " ""))
         (post (if (and next
                        (or (par--atom-char? next)
                            (par--opener? next)
                            (equal? next "\"")))
                   " " "")))
    (insert! (string-append pre open close post))
    (goto-char! (+ p (string-byte-length pre) 1))))

(define (paredit--open! open close)
  (paredit--with-text
    (lambda (buf text p)
      (if (equal? (par--mode (par--ctx text p)) 'code)
          (paredit--pair! text p open close)
          (insert! open)))))

(define-command "paredit-open-round" "Insert a balanced ( ) pair"
  (lambda () (paredit--open! "(" ")")))
(define-command "paredit-open-square" "Insert a balanced [ ] pair"
  (lambda () (paredit--open! "[" "]")))

;; Never insert an unbalanced closer: move past the enclosing closer,
;; and remove blank space that sits against it.
(define (paredit--close! closer)
  (paredit--with-text
    (lambda (buf text p)
      (if (not (equal? (par--mode (par--ctx text p)) 'code))
          (insert! closer)
          (let ((c (par-close text p)))
            (if (not c)
                (message "No enclosing list")
                (let loop ((w c))
                  (if (and (> w p) (par--ws? (par--ch text (- w 1))))
                      (loop (- w 1))
                      ;; deleting the space must not pull the closer into
                      ;; a line comment
                      (if (and (< w c)
                               (equal? (par--mode (par--ctx text w)) 'code))
                          (begin (delete-between! w c) (goto-char! (+ w 1)))
                          (goto-char! (+ c 1)))))))))))

(define-command "paredit-close-round" "Move past the enclosing closer"
  (lambda () (paredit--close! ")")))
(define-command "paredit-close-square" "Move past the enclosing closer"
  (lambda () (paredit--close! "]")))

(define-command "paredit-doublequote" "Insert a balanced string quote"
  (lambda ()
    (paredit--with-text
      (lambda (buf text p)
        (let ((st (par--ctx text p)))
          (cond ((equal? (par--mode st) 'string)
                 ;; at the closing quote step out; inside, insert \"
                 (if (equal? (par--ch text p) "\"")
                     (forward-char!)
                     (insert! "\\\"")))
                ((not (equal? (par--mode st) 'code)) (insert! "\""))
                (else (paredit--pair! text p "\"" "\""))))))))

;;; --- balanced deletion -------------------------------------------------------

(define-command "paredit-backward-delete" "Delete backward, keeping the text balanced"
  (lambda ()
    (paredit--with-text
      (lambda (buf text p)
        (if (= p 0)
            #f
            (let ((st (par--ctx text p))
                  (prev (par--ch text (- p 1)))
                  (next (par--ch text p)))
              (cond
                ((equal? (par--mode st) 'string)
                 (if (and (equal? prev "\"") (equal? (par--extra st) (- p 1)))
                     ;; just inside the opening quote
                     (if (equal? next "\"")
                         (delete-between! (- p 1) (+ p 1))
                         (backward-char!))
                     (delete-char! -1)))
                ((not (equal? (par--mode st) 'code)) (delete-char! -1))
                ((par--char-lit-at? text (- p 1)) (delete-char! -1))
                ;; an empty pair behind point goes as one step
                ((and (par--closer? prev)
                      (par--opener? (par--ch text (- p 2)))
                      (not (par--char-lit-at? text (- p 2))))
                 (delete-between! (- p 2) p))
                ((par--closer? prev) (backward-char!))
                ((equal? prev "\"")
                 (if (equal? (par--ch text (- p 2)) "\"")
                     (delete-between! (- p 2) p)
                     (backward-char!)))
                ((par--opener? prev)
                 (if (and next (par--closer? next))
                     (delete-between! (- p 1) (+ p 1))
                     (backward-char!)))
                (else (delete-char! -1)))))))))

(define-command "paredit-forward-delete" "Delete forward, keeping the text balanced"
  (lambda ()
    (paredit--with-text
      (lambda (buf text p)
        (if (>= p (string-byte-length text))
            #f
            (let ((st (par--ctx text p))
                  (prev (par--ch text (- p 1)))
                  (next (par--ch text p)))
              (cond
                ((equal? (par--mode st) 'string)
                 (if (equal? next "\"")
                     ;; before the closing quote: an empty string goes whole
                     (if (equal? (par--extra st) (- p 1))
                         (delete-between! (- p 1) (+ p 1))
                         (forward-char!))
                     (delete-char! 1)))
                ((not (equal? (par--mode st) 'code)) (delete-char! 1))
                ((par--char-lit-at? text p) (delete-char! 1))
                ((par--opener? next)
                 (if (par--closer? (par--ch text (+ p 1)))
                     (delete-between! p (+ p 2))
                     (forward-char!)))
                ((par--closer? next)
                 (if (and (par--opener? prev)
                          (not (par--char-lit-at? text (- p 1))))
                     (delete-between! (- p 1) (+ p 1))
                     (forward-char!)))
                ((equal? next "\"")
                 (if (equal? (par--ch text (+ p 1)) "\"")
                     (delete-between! p (+ p 2))
                     (forward-char!)))
                (else (delete-char! 1)))))))))

;;; --- balanced kill-line ------------------------------------------------------

;; At the end of a line, C-k kills the newline.
(define (paredit--kill-eol! p eol n)
  (if (and (= p eol) (< eol n))
      (kill-region-1 p (+ p 1))
      #f))

(define-command "paredit-kill" "Kill to the end of the line, balanced"
  (lambda ()
    (paredit--with-text
      (lambda (buf text p)
        (let* ((n (string-byte-length text))
               (nl (string-index text "\n" p))
               (eol (if nl nl n))
               (st (par--ctx text p)))
          (cond
            ((equal? (par--mode st) 'string)
             ;; kill the string body, never its closing quote
             (let ((limit (min (- (par--string-end text p) 1) eol)))
               (if (> limit p)
                   (kill-region-1 p limit)
                   (paredit--kill-eol! p eol n))))
            ((not (equal? (par--mode st) 'code))
             (run-command "kill-line"))
            (else
             ;; whole datums that start before eol, then stop
             (let loop ((i p) (last p))
               (if (>= i eol)
                   (if (> last p)
                       (kill-region-1 p last)
                       (paredit--kill-eol! p eol n))
                   (let ((c (par--ch text i)))
                     (cond
                       ((or (equal? c " ") (equal? c "\t")) (loop (+ i 1) last))
                       ((par--closer? c)
                        (if (> last p) (kill-region-1 p last) #f))
                       ((equal? c ";") (kill-region-1 p eol))
                       ((and (equal? c "#") (equal? (par--ch text (+ i 1)) "|"))
                        (let ((e (par--block-comment-end text i)))
                          (loop e e)))
                       (else
                        (let ((e (par-scan-forward text i)))
                          (if e
                              (loop e e)
                              (if (> last p) (kill-region-1 p last) #f)))))))))))))))

;;; --- structure: slurp, barf, splice, raise, wrap -----------------------------
;;; Each edit is one buffer-replace-range! call, so one undo step.
;;; buffer-replace-range! ignores the read-only flag, so guard it here.

(define (paredit--structural fn)
  (paredit--with-text
    (lambda (buf text p)
      (if (buffer-read-only? buf)
          (message "Buffer is read-only")
          (fn buf text p)))))

(define-command "paredit-slurp-forward" "Pull the next expression into this list"
  (lambda ()
    (paredit--structural
      (lambda (buf text p)
        (let ((c (par-close text p)))
          (if (not c)
              (message "No enclosing list")
              (let ((e (par-scan-forward text (+ c 1))))
                (if (not e)
                    (message "Nothing to slurp")
                    (begin
                      (buffer-replace-range! buf c (- e c)
                        (string-append (substring-bytes text (+ c 1) e)
                                       (par--ch text c)))
                      (goto-char! p))))))))))

(define-command "paredit-barf-forward" "Push the last expression out of this list"
  (lambda ()
    (paredit--structural
      (lambda (buf text p)
        (let ((o (par-up text p)))
          (if (not o)
              (message "No enclosing list")
              (let ((e (par--list-end text o)))
                (if (not e)
                    (message "Unclosed list")
                    (let* ((c (- e 1))
                           (starts (par--starts-before text (+ o 1) c)))
                      (if (null? starts)
                          (message "Nothing to barf")
                          (let ((prev-e (if (null? (cdr starts))
                                            (+ o 1)
                                            (par-scan-forward text (cadr starts)))))
                            (buffer-replace-range! buf prev-e (- (+ c 1) prev-e)
                              (string-append (par--ch text c)
                                             (substring-bytes text prev-e c)))
                            (goto-char! (min p prev-e)))))))))))))

(define-command "paredit-slurp-backward" "Pull the previous expression into this list"
  (lambda ()
    (paredit--structural
      (lambda (buf text p)
        (let ((o (par-up text p)))
          (if (not o)
              (message "No enclosing list")
              (let ((s (par-scan-backward text o)))
                (if (not s)
                    (message "Nothing to slurp")
                    (buffer-replace-range! buf s (- (+ o 1) s)
                      (string-append (par--ch text o)
                                     (substring-bytes text s o)))))))))))

(define-command "paredit-barf-backward" "Push the first expression out of this list"
  (lambda ()
    (paredit--structural
      (lambda (buf text p)
        (let ((o (par-up text p)))
          (if (not o)
              (message "No enclosing list")
              (let ((s1 (par--skip text (+ o 1))))
                (if (or (>= s1 (string-byte-length text))
                        (par--closer? (par--ch text s1)))
                    (message "Nothing to barf")
                    (let* ((e1 (par-scan-forward text s1))
                           (s2 (par--skip text e1)))
                      (buffer-replace-range! buf o (- s2 o)
                        (string-append (substring-bytes text (+ o 1) e1) " ("))
                      (goto-char! (max (+ e1 1)
                                       (+ p (- (+ e1 1) s2)))))))))))))

(define-command "paredit-splice" "Remove the enclosing pair of delimiters"
  (lambda ()
    (paredit--structural
      (lambda (buf text p)
        (let ((o (par-up text p)))
          (if (not o)
              (message "No enclosing list")
              (let ((e (par--list-end text o)))
                (if (not e)
                    (message "Unclosed list")
                    (begin
                      (buffer-replace-range! buf o (- e o)
                        (substring-bytes text (+ o 1) (- e 1)))
                      (goto-char! (- p 1)))))))))))

(define-command "paredit-raise" "Replace the enclosing list with this expression"
  (lambda ()
    (paredit--structural
      (lambda (buf text p)
        (let ((o (par-up text p)))
          (if (not o)
              (message "No enclosing list")
              (let ((e (par--list-end text o))
                    (de (par-scan-forward text p)))
                (if (or (not e) (not de))
                    (message "Nothing to raise")
                    (let ((ds (par-scan-backward text de)))
                      (buffer-replace-range! buf o (- e o)
                        (substring-bytes text ds de))
                      (goto-char! o))))))))))

(define-command "paredit-wrap-round" "Wrap the next expression in a pair"
  (lambda ()
    (paredit--structural
      (lambda (buf text p)
        (let ((e (par-scan-forward text p)))
          (if (not e)
              (message "Nothing to wrap")
              (let ((s (par--skip text p)))
                (buffer-replace-range! buf s (- e s)
                  (string-append "(" (substring-bytes text s e) ")"))
                (goto-char! (+ s 1)))))))))

;;; --- the mode ----------------------------------------------------------------
;;; Keys stay bound when the mode is off (there is no unbind primitive).
;;; Each key runs a dispatcher that falls through to the default
;;; behavior, the evil.scm shape.

;; (KEY COMMAND FALLBACK): FALLBACK is a command name, 'insert for
;; self-insert of KEY, or #f for a quiet no-op.
(define *paredit-keys*
  '(("(" "paredit-open-round" insert)
    (")" "paredit-close-round" insert)
    ("[" "paredit-open-square" insert)
    ("]" "paredit-close-square" insert)
    ("\"" "paredit-doublequote" insert)
    ("DEL" "paredit-backward-delete" "delete-backward-char")
    ("<delete>" "paredit-forward-delete" "delete-char")
    ("C-d" "paredit-forward-delete" "delete-char")
    ("C-k" "paredit-kill" "kill-line")
    ("C-M-f" "paredit-forward" "forward-sexp")
    ("C-M-b" "paredit-backward" "backward-sexp")
    ("C-M-u" "paredit-backward-up" "backward-up-list")
    ("C-M-d" "paredit-down" "down-list")
    ("C-M-k" "paredit-kill-sexp" #f)
    ("C-M-SPC" "paredit-mark-sexp" #f)
    ;; the canonical paredit chords; macOS keeps Ctrl-arrows for Mission
    ;; Control, so the arrow forms below reach only a remapped OS
    ("C-)" "paredit-slurp-forward" #f)
    ("C-(" "paredit-slurp-backward" #f)
    ("C-}" "paredit-barf-forward" #f)
    ("C-{" "paredit-barf-backward" #f)
    ("C-<right>" "paredit-slurp-forward" "forward-word")
    ("C-<left>" "paredit-barf-forward" "backward-word")
    ("M-s" "paredit-splice" #f)
    ("M-r" "paredit-raise" #f)
    ("M-(" "paredit-wrap-round" #f)))

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

(define (paredit--setup! buf) #t)

(define (paredit--teardown! buf)
  (overlay-clear! buf 'paren))

;;; --- show-paren --------------------------------------------------------------
;;; After every command: point beside a delimiter lights the pair.

(define (paredit--paren-pair text p)
  (let ((prev (par--ch text (- p 1)))
        (next (par--ch text p)))
    (cond
      ((and prev (par--closer? prev) (not (par--char-lit-at? text (- p 1))))
       (let ((os (par--openers (par--ctx text (- p 1)))))
         (if (null? os) #f (list (car os) (- p 1)))))
      ((and next (par--opener? next) (not (par--char-lit-at? text p)))
       (let ((e (par--list-end text p)))
         (if e (list p (- e 1)) #f)))
      (else #f))))

(define (paredit--show-paren!)
  (let ((buf (current-buffer)))
    (when (minor-mode-on? buf "paredit-mode")
      (let* ((text (buffer-text buf))
             (p (point))
             (pair (and (equal? (par--mode (par--ctx text p)) 'code)
                        (paredit--paren-pair text p))))
        (if pair
            (overlay-set! buf 'paren
              (list (list (car pair) (+ (car pair) 1) "paren-match")
                    (list (cadr pair) (+ (cadr pair) 1) "paren-match")))
            (overlay-clear! buf 'paren))))))

(add-hook! 'post-command-hook 'paredit--show-paren!)

(define-style! 'paredit "
.f-paren-match{background:color-mix(in srgb, var(--accent-fg,#4a6a8a) 32%, transparent);border-radius:2px}
")

(register-minor-mode! "paredit-mode" paredit--setup! paredit--teardown!)
;; the mode's keys are its map, in force while the mode is on
(minor-mode-keys! "paredit-mode"
  (map (lambda (entry) (list (car entry) (string-append "paredit--key-" (car entry))))
       *paredit-keys*))

(define-command "paredit-mode" "Toggle structural s-expression editing"
  (lambda ()
    (if (toggle-minor-mode! "paredit-mode")
        (message "paredit-mode enabled")
        (message "paredit-mode disabled"))))

;;; --- enablement --------------------------------------------------------------

(defgroup 'paredit "Structural s-expression editing.")

(defcustom 'paredit-in-scheme-mode #t
  "Enable paredit-mode in scheme-mode buffers."
  'group 'paredit 'type 'boolean)

(define (paredit--scheme-mode-hook!)
    (when paredit-in-scheme-mode
      (enable-minor-mode! (current-buffer) "paredit-mode")))

(add-hook! 'scheme-mode-hook 'paredit--scheme-mode-hook!)

(public! 'par-scan-forward
  "(par-scan-forward TEXT POS) — byte end of the datum at or after POS, or #f")
(public! 'par-scan-backward
  "(par-scan-backward TEXT POS) — byte start of the datum before POS, or #f")
(public! 'par-up "(par-up TEXT POS) — enclosing opener position, or #f")
(public! 'par-close "(par-close TEXT POS) — enclosing closer position, or #f")
