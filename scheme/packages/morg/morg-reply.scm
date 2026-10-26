;;; morg-reply.scm --- an agent's reply in a morg document is a quote.
;;;
;;; C-RET writes the agent's reply as a quote whose first line is
;;; `> [!agent]`, so who wrote it lives in the file and survives a save and
;;; a reopen. The user's own writing stays plain, and a quote the user wrote
;;; is not a reply. With point in a reply its keys act on it:
;;;   c    copy it, without the quote marks
;;;   e    edit it: it becomes the user's prose
;;;   r    rewrite it: ask the agent again and replace it
;;;   d    dismiss it
;;;   s    split it: a chat of its own, in the document's group
;;;   RET  answer it: a new paragraph below, which C-RET sends
;;;   TAB  fold it to its first line;  n / p  the next or previous reply
;;;   C-x n n  show only the reply

(define morg-reply-parent-package *loading-package*)
(define morg-reply-parent-namespace *loading-namespace*)
(define morg-reply-parent-domain *catalog-domain*)
(define morg-reply-parent-effects *catalog-effects*)

(require 'chat-mode "chat-mode.scm")
(require 'morg "morg.scm")

(package! 'morg-reply 'morg)
(domain! 'writing)
(effects! '(pure))

(define morg-reply-header "> [!agent]")

;; TEXT as a reply: the header, then each line behind "> "; a blank line
;; reads ">" so the quote stays one
(define (morg-reply-quote text)
  (let ((body (string-trim text)))
    (if (equal? body "")
        text
        (string-append morg-reply-header "\n"
          (string-join
            (map (lambda (l) (if (equal? (string-trim l) "") ">" (string-append "> " l)))
                 (split-lines body))
            "\n")))))

;; a reply's text as plain prose: no header, no quote marks
(define (morg-reply-unquote text)
  (string-join
    (map (lambda (l)
           (cond ((string-prefix? "> " l) (substring-bytes l 2 (string-byte-length l)))
                 ((string-prefix? ">" l) (substring-bytes l 1 (string-byte-length l)))
                 (else l)))
         (cdr (split-lines text)))
    "\n"))

(effects! '(read))

;; every reply in BUF as (START END), in order. A reply runs from its
;; header line to the last quote line that follows it.
(define (morg-replies buf)
  (let loop ((ls (morg-lines buf)) (open #f) (last 0) (acc '()))
    (if (null? ls)
        (reverse (if open (cons (list open last) acc) acc))
        (let* ((l (car ls))
               (text (cadr l))
               (end (+ (car l) (string-byte-length text))))
          (cond ((string-prefix? morg-reply-header text)
                 (loop (cdr ls) (car l) end (if open (cons (list open last) acc) acc)))
                ((and open (string-prefix? ">" text)) (loop (cdr ls) open end acc))
                (else (loop (cdr ls) #f 0 (if open (cons (list open last) acc) acc))))))))

;; the reply that holds POS, as (START END), or #f
(define (morg-reply-at buf pos)
  (let loop ((rs (morg-replies buf)))
    (cond ((null? rs) #f)
          ((and (<= (car (car rs)) pos) (<= pos (cadr (car rs)))) (car rs))
          (else (loop (cdr rs))))))

(define (morg-reply-text buf r)
  (with-current-buffer buf (lambda () (buffer-substring (car r) (cadr r)))))

(define-keymap! "morg-reply-map")
(for-each (lambda (kv) (define-key "morg-reply-map" (car kv) (cadr kv)))
  '(("c" "morg-reply-copy") ("e" "morg-reply-edit") ("r" "morg-reply-rewrite")
    ("d" "morg-reply-dismiss") ("s" "morg-reply-split") ("RET" "morg-reply-answer")
    ("TAB" "morg-reply-fold") ("n" "morg-reply-next") ("p" "morg-reply-previous")
    ("C-x n n" "morg-reply-narrow")))

(morg-point-map-provider! 'reply
  (lambda (buf pos) (and (morg-reply-at buf pos) "morg-reply-map")))

(effects! '(write))

(llm-reply-format! "morg-mode" morg-reply-quote)

;; run K with the buffer and the reply at point, or say there is none
(define (morg-reply--at-point k)
  (let* ((buf (current-buffer))
         (r (morg-reply-at buf (point))))
    (if r (k buf r) (message "No agent reply here"))))

;; the reply and the blank line that separates it from what follows
(define (morg-reply--delete! buf r)
  (let* ((text (buffer-text buf))
         (size (string-byte-length text))
         (end (let loop ((e (cadr r)) (n 0))
                (if (and (< n 2) (< e size) (equal? (substring-bytes text e (+ e 1)) "\n"))
                    (loop (+ e 1) (+ n 1))
                    e))))
    (buffer-delete-range! buf (car r) (- end (car r)))))

(define-command "morg-reply-copy" "Copy the agent reply at point, without its quote marks"
  (lambda ()
    (morg-reply--at-point
      (lambda (buf r)
        (kill-new (morg-reply-unquote (morg-reply-text buf r)))
        (message "Reply copied")))))

(define-command "morg-reply-edit" "Make the agent reply at point your own prose"
  (lambda ()
    (morg-reply--at-point
      (lambda (buf r)
        (buffer-replace-range! buf (car r) (- (cadr r) (car r))
          (morg-reply-unquote (morg-reply-text buf r)))
        (goto-char! (car r))))))

(define-command "morg-reply-dismiss" "Delete the agent reply at point"
  (lambda ()
    (morg-reply--at-point
      (lambda (buf r)
        (morg-reply--delete! buf r)
        (message "Reply dismissed")))))

(define-command "morg-reply-rewrite" "Ask the agent again and replace the reply at point"
  (lambda ()
    (morg-reply--at-point
      (lambda (buf r)
        (morg-reply--delete! buf r)
        ;; the text above the reply asked for it; ask again from its end
        (let ((at (max 0 (- (car r) 2))))
          (goto-char! at)
          (llm-send-at-point! buf at))))))

(define-command "morg-reply-split" "Split the agent reply at point into a chat of its own"
  (lambda ()
    (morg-reply--at-point
      (lambda (buf r)
        (let ((text (morg-reply-text buf r))
              (g (group-ensure! buf)))
          (if (and g (group-chat-new! g))
              (insert! (string-append "About this reply in " buf ":\n\n" text "\n\n"))
              (message "No group for a chat")))))))

(define-command "morg-reply-answer" "Answer the agent reply at point in a new paragraph below it"
  (lambda ()
    (morg-reply--at-point
      (lambda (buf r)
        (buffer-insert! buf (cadr r) "\n\n")
        (goto-char! (+ (cadr r) 2))
        (message "Write your answer; C-RET sends it")))))

(define-command "morg-reply-fold" "Fold the agent reply at point to its first line, or unfold it"
  (lambda ()
    (morg-reply--at-point
      (lambda (buf r)
        (let ((head-end (+ (car r) (string-byte-length morg-reply-header))))
          (when (< head-end (cadr r))
            (fold-toggle! buf 'morg-reply (list head-end (cadr r)))))))))

(define-command "morg-reply-narrow" "Show only the agent reply at point; C-x n w widens"
  (lambda ()
    (morg-reply--at-point
      (lambda (buf r) (buffer-narrow! buf (car r) (cadr r))))))

(define (morg-reply--go! pick)
  (let* ((buf (current-buffer))
         (r (pick (morg-replies buf) (point))))
    (if r (goto-char! (car r)) (message "No more agent replies"))))

(define-command "morg-reply-next" "Go to the next agent reply"
  (lambda ()
    (morg-reply--go!
      (lambda (rs pos)
        (let ((after (filter (lambda (r) (> (car r) pos)) rs)))
          (and (pair? after) (car after)))))))

(define-command "morg-reply-previous" "Go to the previous agent reply"
  (lambda ()
    (morg-reply--go!
      (lambda (rs pos)
        (let* ((here (morg-reply-at (current-buffer) pos))
               (from (if here (car here) pos))
               (before (filter (lambda (r) (< (car r) from)) rs)))
          (and (pair? before) (car (reverse before))))))))

(public! 'morg-replies
  "(morg-replies BUF) — every agent reply quote in BUF as (START END), in order")
(public! 'morg-reply-at
  "(morg-reply-at BUF POS) — the agent reply quote that holds POS as (START END), or #f")
(public! 'morg-reply-quote
  "(morg-reply-quote TEXT) — TEXT as an agent reply: a `> [!agent]` line, then the text behind `> `")
(public! 'morg-reply-unquote
  "(morg-reply-unquote TEXT) — a reply quote's text as plain prose")

;; Do not leak this extension's catalog context into user packages.
(package! morg-reply-parent-package morg-reply-parent-namespace)
(domain! morg-reply-parent-domain)
(effects! morg-reply-parent-effects)
