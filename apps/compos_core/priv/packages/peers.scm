;;; peers.scm --- syncing a buffer with another replica.
;;;
;;; A peer is a home, named by the socket that home listens on: a local path
;;; for a daemon on this machine, "host:/path" for one over ssh.
;;;
;;; The exchange is two questions and two answers:
;;;
;;;   what do you have?          (buffer-version-token BUF)
;;;   what am I missing?         (buffer-updates-since BUF TOKEN)
;;;   here is what you missed    (buffer-merge! BUF UPDATES)
;;;
;;; Both sides ask, so neither leads. The bytes are the same in both
;;; directions and the same as the log holds, so a wire and a file carry the
;;; history in one form.
;;;
;;; Nothing here polls. A sync happens when somebody asks for one, because
;;; deciding when is a policy question nobody has answered yet.

(domain! 'buffers)
(effects! '(read external))

(define (peers--quote s) (string-append "\"" s "\""))

;; What the peer would answer if we asked it about BUF. The peer runs the same
;; editor, so the question is the same call we would make locally.
(define (peer-token peer buf)
  (let ((answer (peer-eval peer (string-append "(buffer-version-token " (peers--quote buf) ")"))))
    (if (equal? answer "#f") #f (peers--unread answer))))

;; peer-eval returns the peer's printed result, so a string comes back with
;; its quotes still on.
(define (peers--unread printed)
  (if (and (> (string-length printed) 1)
           (equal? (substring printed 0 1) "\""))
      (substring printed 1 (- (string-length printed) 1))
      printed))

(effects! '(write external))

;; Take what the peer has and we do not.
(define (peer-pull! peer buf)
  (let* ((mine (buffer-version-token buf))
         (theirs (peer-eval peer
                   (string-append "(buffer-updates-since " (peers--quote buf) " "
                                  (if mine (peers--quote mine) "#f") ")"))))
    (buffer-merge! buf (peers--unread theirs))))

;; Give the peer what we have and it does not.
(define (peer-push! peer buf)
  (let* ((theirs (peer-token peer buf))
         (ours (buffer-updates-since buf theirs)))
    (peer-eval peer
      (string-append "(buffer-merge! " (peers--quote buf) " " (peers--quote ours) ")"))))

;; One exchange, both ways. Pull first: merging what they have before sending
;; ours means the push carries one set of changes instead of two round trips
;; converging on the same thing.
(define (peer-sync! peer buf)
  (peer-pull! peer buf)
  (peer-push! peer buf)
  buf)

(public! 'peer-token
  "(peer-token PEER BUF) — what the replica at PEER knows about BUF, as its version token")
(public! 'peer-pull!
  "(peer-pull! PEER BUF) — take the changes PEER has and this replica does not")
(public! 'peer-push!
  "(peer-push! PEER BUF) — send PEER the changes this replica has and it does not")
(public! 'peer-sync!
  "(peer-sync! PEER BUF) — one exchange both ways, after which both replicas agree")

(define-command "sync-buffer-with-peer"
  "Exchange this buffer's changes with another replica"
  (lambda ()
    (let ((buf (current-buffer)))
      (minibuffer-read "Peer socket: " '()
        (lambda (peer)
          (let ((peer (string-trim peer)))
            (if (equal? peer "")
                (message "no peer, no sync")
                (begin
                  (peer-sync! peer buf)
                  (message (string-append "synced " buf " with " peer))))))))))
