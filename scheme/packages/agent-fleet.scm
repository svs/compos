;;; agent-fleet.scm --- Chat fleet list, archive, and attention UI.
;;;
;;; This module owns the *chat-list* application and the actions across chat
;;; buffers. Runtime lifecycle and transcript rendering remain in agent.scm.

(domain! 'chat)
(effects! '(write))
(category! 'chat)

;; one list over the chats: the application's buffer, which every fleet
;; action reads its targets from. docs/CHAT-LIST.md is the contract.
(define *chat-list-buffer* "*chat-list*")
(define (chat-list-buffer) (mode-list-buffer "chat-mode"))


(define (agent-threads)
  (map (lambda (b) (list (buffer-local b 'agent-slug) (chat-row-status b)))
       (filter (lambda (b) (buffer-local b 'agent-slug)) (chat-list-bufs))))

(define (agent-status-rank s)
  (cond ((equal? s 'needs_attention) 0)
        ((equal? s 'running) 1)
        ((equal? s 'starting) 1)
        ((equal? s 'idle) 2)
        ((equal? s 'api) 2)
        (else 3)))

(define (agent-status-glyph s)
  (cond ((equal? s 'needs_attention) "!")
        ((equal? s 'running) "*")
        ((equal? s 'starting) "*")
        ((equal? s 'idle) "-")
        ((equal? s 'api) "-")
        (else "x")))

;; Every chat, most recently used first. The order is the editor's one
;; MRU, so a view that sorts by recency reads it and sorts nothing: the
;; chat you were last in leads the table. The MRU names sleeping chats
;; too, and (buffer-list) catches a chat nobody has shown yet.
(define (chat-list-buf? b)
  (and (not (string-prefix? " " b))
       (or (buffer-local b 'agent-slug) (chat-buffer? b))))

(define (chat-list-bufs)
  ;; the chats and the agents, most recent first, from one snapshot
  (mode-list-buffers "chat-mode"))

;; the ibuffer row kind asks this three times for one row (dot, label,
;; face), and a read from a chat buffer's own process is far slower than
;; from a plain one. The second and third ask of the same row reuse the
;; first's answer instead of paying its cost again.
(define *chat-row-status-memo* (list #f #f))

;; a list reads every chat's agent in one snapshot
(ibuffer-prefetch-local! 'agent-slug)

(define (chat-row-status b)
  (if (equal? (car *chat-row-status-memo*) b)
      (cadr *chat-row-status-memo*)
      (let* ((slug (ibuffer-row-local b 'agent-slug))
             (status (if slug (agent-status slug) 'api)))
        (set! *chat-row-status-memo* (list b status))
        status)))

(define (agents-sorted &optional bufs)
  (let ((bs (or bufs (chat-list-bufs))))
    (let loop ((rank 0) (acc '()))
      (if (> rank 3) (reverse acc)
          (loop (+ rank 1)
                (let inner ((bs bs) (acc acc))
                  (cond ((null? bs) acc)
                        ((= (agent-status-rank (chat-row-status (car bs))) rank)
                         (inner (cdr bs) (cons (car bs) acc)))
                        (else (inner (cdr bs) acc)))))))))

(category! 'chat)

(effects! '(read))

(defcustom 'chats-archived-limit 15
  "How many saved chats the candidate prompt shows below the live ones."
  'group 'chat 'type 'integer)

(define (chats-live-log-paths)
  (let loop ((bs (chat-list-bufs)) (acc '()))
    (if (null? bs)
        acc
        (let ((id (buffer-local (car bs) 'chat-log-id)))
          (loop (cdr bs)
                (if id
                    (cons (string-append (chat-log-dir-for (car bs)) "/" id ".chat") acc)
                    acc))))))

(define (chats-archived-rows)
  (if (not (boundp (quote chat-log-files-newest)))
      '()
      (let ((live (chats-live-log-paths)))
        (take (filter (lambda (path)
                          (and (not (buffer-known? path))
                               (not (member path live))))
                        (chat-log-files-newest))
                chats-archived-limit))))

(define (chats-archived-row? e)
  (and (string? e) (not (buffer-known? e))))

;; The name of a saved chat is the sentence its header carries, not the
;; group slug its file is named for. The header is line one, and an
;; archived file no longer changes, so one read per path answers for the
;; whole session.
(define *chats-archived-summaries* '())

(define (chats-archived-summary--read path)
  (let ((text (ignore-errors (lambda () (read-file path)))))
    (and (string? text)
         (let* ((nl (string-index text "\n"))
                (head (chat-parse-header
                        (if nl (substring-bytes text 0 nl) text)))
                ;; the title if the file carries one; a file written
                ;; before titles existed answers with its last summary
                (s (and head (or (plist-get head 'title)
                                 (plist-get head 'summary)))))
           (and (string? s) (not (equal? s "")) s)))))

(define (chats-archived-summary path)
  (let ((hit (assoc path *chats-archived-summaries*)))
    (if hit
        (cadr hit)
        (let ((title (chats-archived-summary--read path)))
          (set! *chats-archived-summaries*
                (cons (list path title) *chats-archived-summaries*))
          title))))

(define (chats-archived-title path)
  (or (chats-archived-summary path)
      (let* ((leaf (chat-log-leaf path))
             (title (re-replace "\\.chat$" (re-replace "^[0-9]+-" leaf "") "")))
        (if (equal? title "") leaf title))))

;;; --- the chat rows in the ibuffer template --------------------------------------
;;; *chats* is the ibuffer table over the chat buffers: the same sections,
;;; sort, folds, marks and keys, with the chat verbs added. The table
;;; asks a row's kind what to show; the chat kind and the archived kind
;;; are registered here. C-x C-c opens it in a window, as C-x C-b opens
;;; the buffers; C-x c is the same rows as a prompt.

;;; --- last activity ------------------------------------------------------------
;;; The editor keeps no clock on a chat. This table notes the time the
;;; last event batch reached each chat. It starts empty at boot, so a
;;; chat with no event since the restart shows the time it was last seen.

(define *chats-activity* '())

(define (chats-note-activity! b)
  (when (string? b)
    (set! *chats-activity* (alist-put *chats-activity* b (current-time)))))

(define (chats-activity-at b)
  (let ((e (assoc b *chats-activity*)))
    (and e (cadr e))))

(define (chats-age-label t)
  (ibuffer-age-label (and t (- (current-time) t))))

;;; --- one row's facts ----------------------------------------------------------

;; the state in the words the row shows: what the chat waits for
(define (chats-state-label status)
  (cond ((equal? status 'needs_attention) "your turn")
        ((equal? status 'running) "streaming")
        ((equal? status 'starting) "starting")
        ((equal? status 'idle) "idle")
        ((equal? status 'api) "idle")
        (else "stopped")))

;; The colours a chat's state wears. They are this package's defaults,
;; so a theme can say otherwise, and they are the ones the design names:
;; a live chat teal, a stopped one coral, an idle one out of the way.
(defface! 'chat-live 'fg "#6fb8a5")
(defface! 'chat-stopped 'fg "#e08d78")
(defface! 'chat-idle 'fg "#4a4660")
(defface! 'chat-archived 'fg "#3a3746")

(define (chats-state-face status)
  (cond ((equal? status 'needs_attention) "alert")
        ((or (equal? status 'running) (equal? status 'starting)) "chat-live")
        ((equal? status 'dead) "chat-stopped")
        (else "chat-idle")))

(define (chats-model b)
  (or (buffer-local b 'agent-model) (buffer-local b 'llm-model) ""))

;; the size of a chat is the size of its transcript on disk -- the
;; number dired would show for that file: what the size column shows,
;; what the size sort reads, what a heading adds up. A chat that has
;; not written its file yet has no size to show
(define (chats-filesize b)
  ;; the number the writer left behind. Two syscalls per chat row, on
  ;; every draw of every buffer table, to learn a size the save already
  ;; knew. The stat stays as the answer for a chat written before this
  ;; local existed, and for one whose log another process changed.
  (or (buffer-local b 'chat-log-size)
      ;; the id the chat already carries, never a fresh one: drawing a row
      ;; must not name a file the chat has not asked for
      (let ((id (buffer-local b 'chat-log-id)))
        (and (string? id)
             (let ((p (string-append (chat-log-dir-for b) "/" id ".chat")))
               (and (file-exists? p) (file-size p)))))))

(define (chats-summary b)
  (let ((s (buffer-local b 'chat-summary)))
    (and (string? s) (not (equal? s "")) s)))

;; the row names the chat by its title -- the name somebody gave it, or
;; the first label its summary wrote -- else its buffer name. The table
;; is the broad form, in a window or in the wide C-x c popup, so the
;; whole title stands; only the narrow candidate line clips.
(define (chats-title b) (chat-prompt-full-label b))

;; a chat needing a reply wears its alert glyph in the name itself, so it
;; survives even a narrow table that drops the dot and label columns
(define (chats-alert-name b)
  (if (equal? (chat-row-status b) 'needs_attention)
      (string-append "! " (chats-title b))
      (chats-title b)))

(define (chats-metadata-text b)
  ;; Keep metadata separate from transcript snippets so search results can
  ;; explain which source matched without scanning the text again.
  (string-append (chats-title b) " "
                 (or (chats-summary b) "") " "
                 (chats-model b) " "
                 (chats-state-label (chat-row-status b)) " "
                 (or (buffer-local b 'agent-slug) "")))

(define (chats-match-text b)
  (string-append (chats-metadata-text b) " " (or (chat-list-hit b) "")))

(ibuffer-kind! 'chat
  (list 'when? (lambda (b) (and (buffer-known? b) (chat-buffer? b)))
        ;; a round dot, lit by what the chat is doing: the eye reads a
        ;; colour before it reads a word, and the live one pulses
        'dot (lambda (b)
               (let ((s (chat-row-status b)))
                 (list (if (equal? s 'needs_attention) "!" "●")
                       (chats-state-face s))))
        'name (lambda (b) (list "" (chats-alert-name b)))
        ;; by name, never by value: a reload redefines the function and a
        ;; kind registered with the old one keeps calling it
        'size (lambda (b) (chats-filesize b))
        ;; a chat found by a word in its text says which word, in place of
        ;; the state: you searched for the words, not for the state
        'label (lambda (b)
                 (let ((hit (chat-list-hit b)))
                   (if hit
                       (chat-prompt-clip hit)
                       (chats-state-label (chat-row-status b)))))
        'last (lambda (b)
                (let ((t (chats-activity-at b)))
                  (if t (chats-age-label t) (ibuffer-last-label b))))
        ;; by name, not by value: a reload redefines chats-match-text after
        ;; this form runs, and a captured procedure would stay the old one
        'match (lambda (b) (chats-metadata-text b))
        'face (lambda (b)
                (if (equal? (chat-row-status b) 'needs_attention) "alert" "accent"))
        'modified? (lambda (b) #f)))

;; a saved conversation is a file no buffer holds
(ibuffer-kind! 'archived
  (list 'when? (lambda (b) (and (not (buffer-known? b)) (string-suffix? ".chat" b)))
        'dot (lambda (b) (list "●" "chat-archived"))
        'name (lambda (b) (list "" (chats-archived-title b)))
        ;; the row is the file, so its size is the file's own
        'size (lambda (b) (and (file-exists? b) (file-size b)))
        'label (lambda (b) "archived")
        'match (lambda (b) (string-append (chats-archived-title b) " archived"))
        'face (lambda (b) "dim")
        'modified? (lambda (b) #f)))

(effects! '(write))

;; The chat list is a still picture. A streaming turn hands the fleet an
;; event batch many times a second, and a list that redraws under the
;; reader re-sorts its rows and carries the cursor off the chat they were
;; reading. So no event ever draws it. The modeline carries the news
;; instead, and g draws the list again when the reader asks for it.
(define (agents-refresh!)
  (when (buffer-known? (chat-list-buffer))
    (list-refresh! (chat-list-buffer))))

;; a verb ran on the chat at point, so the row it acted on is stale and so
;; is the pane that previews it: the list draws again and looks again
(define (agents-relist!)
  (when (buffer-known? (chat-list-buffer))
    (list-refresh! (chat-list-buffer))
    (chat-list-preview!)))

;; A list that never draws LIES. The state column reads agent-status at draw
;; time, so a chat that finished keeps the word "streaming" until somebody
;; presses g. Two things make drawing it safe here. The draw happens on the
;; state CHANGE, twice a turn instead of many times a second. And it is a
;; REDRAW, not a refresh: the rows stay as they were fetched, so nothing
;; re-sorts and no cursor moves. Only the words a column reads from live
;; state change.
(define *agents-state-last* '())

(define (agents-state-moved? slug)
  (let ((now (agent-status slug))
        (was (alist-get *agents-state-last* slug)))
    (and (not (equal? now was))
         (begin (set! *agents-state-last* (alist-put *agents-state-last* slug now))
                #t))))

(define (agents-restate!)
  (when (buffer-known? (chat-list-buffer))
    (list-redraw! (chat-list-buffer))))

;; the fleet's surfaces after an event batch: the modeline answers every
;; batch, and the list answers the state changes inside it.
(define (agents-note-event! &optional slug)
  (when slug (chats-note-activity! (agent-buf slug)))
  ;; a status that moved is news for more than this list: the event log
  ;; publishes it on the chat's topic
  (when (and slug (agents-state-moved? slug))
    (run-hook-with-args 'agent-status-hook slug)
    (agents-restate!))
  (agents-modeline-refresh!))

(define (agents-current-buf)
  (let ((row (list-current (chat-list-buffer))))
    (and (string? row) row)))

(define (agents-current-slug)
  (let ((b (agents-current-buf)))
    (and b (buffer-local b 'agent-slug))))

;; the chats a verb acts on: the row at point, or every chat under it
;; when that row is a group. A chat the editor put to sleep is still a
;; chat the list shows, and its locals still answer, so the question is
;; buffer-known?: buffer-exists? dropped every dormant row, which left
;; nearly every verb saying there was no chat here.
(define (agents-targets)
  ;; the list the key was pressed in; *chat-list*<2> is no other list
  (let ((here (current-buffer)))
    (filter buffer-known?
            (ibuffer-targets (if (equal? (mode-list-of here) "chat-mode") here (chat-list-buffer))))))

;; the slug of a chat whose runtime is up. A dormant chat keeps its slug
;; local, so the local alone does not say there is a runtime to answer.
(define (agents-runtime-slug b)
  (let ((slug (buffer-local b 'agent-slug)))
    (and slug (not (equal? (agent-status slug) 'dead)) slug)))

(define (agents-report verb bs)
  (message (if (= (length bs) 1)
               (string-append verb " " (car bs))
               (string-append verb " " (number->string (length bs)) " chats"))))

(define-command "chat-retitle-at-point" "Title the chat at point again; a blank title asks the model"
  (lambda ()
    (let ((b (ibuffer-current (chat-list-buffer))))
      (if (not (and (string? b) (buffer-known? b)))
          (message "no chat here")
          (chat-retitle! b agents-relist!)))))

(catalog-meta! 'command "chat-retitle-at-point" 'domain 'chat 'effects '(write external spend))

(define (agents-live-slug buf)
  (let ((slug (or (buffer-local buf 'agent-slug) (chat-ensure-runtime! buf))))
    (if (equal? (agent-status slug) 'dead) (agent-revive! slug) slug)))

(define-command "agents-steer" "Send a steering message to the chat at point"
  (lambda ()
    (let ((bs (agents-targets)))
      (if (null? bs)
          (message "no chat here")
          (minibuffer-read
            (if (= (length bs) 1)
                (string-append "Steer " (car bs) ": ")
                (string-append "Steer " (number->string (length bs)) " chats: "))
            '()
            (lambda (msg)
              (unless (equal? msg "")
                (for-each (lambda (b) (agent-send-msg! (agents-live-slug b) msg)) bs)
                (agents-relist!)
                (agents-report "steered" bs))))))))

(define (agents-answer! exact prefix verb)
  (let* ((targets (agents-targets))
         (bs (filter agents-runtime-slug targets)))
    (cond ((null? targets) (message "no chat here"))
          ;; the row is a chat, it is just not awake to be asking: say
          ;; which chat, not that there is nothing here
          ((null? bs)
           (message (string-append (chats-title (car targets))
                                   " is asleep: nothing is asking")))
          (else
           (for-each (lambda (b)
                       (agent-answer-permission! (agents-runtime-slug b) exact prefix))
                     bs)
           (agents-relist!)
           (agents-report verb bs)))))

(define-command "agents-allow" "Allow the pending permission of the chat at point"
  (lambda () (agents-answer! "allow_once" "allow" "allowed")))

(define-command "agents-deny" "Deny the pending permission of the chat at point"
  (lambda () (agents-answer! "reject_once" "reject" "denied")))

(define (agent-note-stopped! slug)
  (unless (equal? (agent-status slug) 'dead)
    (let ((buf (agent-buf slug)))
      (agent-clear-waiting! buf)
      (agent-block-drop-kind! buf "permission")
      (let ((start (agent-render! slug "\n[agent stopped]\n" "agent-meta")))
        (agent-block-push! buf start (agent-mark slug) "meta" '())))))

;; A revived chat drops the "[agent stopped]" lines its stops left behind
;; (the owner, 2026-09-19): the transcript says what was said, and a stop
;; the chat came back from is not part of that. Each marker is a meta block
;; of exactly that text; tool output that quotes it stays.
(define (agent-drop-stopped-markers! buf)
  (let* ((text (buffer-text buf))
         (marks (filter (lambda (blk)
                          (and (equal? (nth 2 blk) "meta")
                               (equal? (string-trim (substring-bytes text (car blk) (cadr blk)))
                                       "[agent stopped]")))
                        (or (buffer-local buf 'agent-blocks) '())))
         ;; last first, so each cut leaves the earlier offsets as they were
         (spans (reverse (sort (map (lambda (blk) (list (car blk) (cadr blk))) marks)))))
    (for-each (lambda (s) (agent-excise-range! buf (car s) (cadr s))) spans)
    (when (and (pair? spans) (boundp (quote chat-view-sync!)))
      (chat-view-sync! buf))
    (length spans)))

(define (agent-release-windows! buf)
  (let* ((others (filter (lambda (b) (and (not (equal? b buf))
                                          (not (string-prefix? "*agent" b))))
                         (buffer-list-mru)))
         (repl (if (null? others) "*scratch*" (car others))))
    (for-each
      (lambda (w)
        (when (equal? (car (cdr w)) buf)
          (window-set-buffer! (car w) repl)))
      (window-list-all))))

(define (agents-kill-runtime! b)
  (let ((slug (agents-runtime-slug b)))
    (and slug
         (begin (agent-note-stopped! slug)
                (llm-session-close! slug)
                ;; the chat remembers it was running, so chats-start-all has
                ;; something durable to read instead of a list in memory
                (buffer-set-local! b 'chat-was-running #t)
                #t))))

(define (agents-archive! b)
  (let ((here (active-window)))
    (agents-kill-runtime! b)
    (agent-release-windows! b)
    (buffer-kill! b)
    (when (window-exists? here) (select-window! here))))

(define-command "agents-refresh" "Refresh the chat list"
  (lambda () (agents-refresh!)))

(define-command "chats-archive"
  "Archive the chat at point: the runtime stops, the buffer goes, the file stays"
  (lambda ()
    (let ((bs (agents-targets)))
      (if (null? bs)
          (message "no chat here")
          (begin
            (for-each agents-archive! bs)
            (agents-relist!)
            (agents-report "archived" bs))))))

;; k stops the runtime and keeps the transcript: the chat stays in the
;; list, readable, and the next message you send revives it
(define-command "chats-kill-runtime"
  "Stop the runtime of the chat at point and keep its transcript"
  (lambda ()
    (let* ((targets (agents-targets))
           (bs (filter agents-kill-runtime! targets)))
      (cond ((null? targets) (message "no chat here"))
            ((null? bs)
             (message (string-append (chats-title (car targets))
                                     " is already stopped")))
            (else (agents-relist!) (agents-report "stopped" bs))))))

;; the other half of agents-kill-runtime!: give a dormant chat its
;; runtime back and send it nothing. agent-continue! is this plus a
;; message, so a chat started here is the same chat a send would revive.
(define (agents-start-runtime! b)
  (buffer-set-local! b 'chat-was-running #f)
  (and (not (agents-runtime-slug b))
       (let ((slug (chat-ensure-runtime! b)))
         (and slug
              (begin (when (equal? (agent-status slug) 'dead)
                       (agent-revive! slug))
                     #t)))))

;; every chat at once, for when you want the filesystem quiet. stop-all
;; closes every runtime and keeps every transcript; start-all opens again
;; exactly the ones it closed, so a chat you left dormant on purpose stays
;; that way and a hundred old conversations never wake together.
;;
;; which chats those are is the chat's own answer, not a list kept here:
;; agents-kill-runtime! leaves chat-was-running on the buffer, and that
;; local survives a daemon restart the way chat-turn-active does. So a
;; restart between the two commands loses nothing.
(define (chats-was-running-bufs)
  (filter (lambda (b) (buffer-local b 'chat-was-running)) (chat-list-bufs)))

(define-command "chats-stop-all"
  "Stop every chat runtime and keep the transcripts"
  (lambda ()
    (let ((bs (filter agents-kill-runtime! (chat-list-bufs))))
      (if (null? bs)
          (message "no chat is running")
          (begin (agents-relist!) (agents-report "stopped" bs))))))

(define-command "chats-start-all"
  "Start every chat whose runtime was stopped"
  (lambda ()
    (let ((targets (chats-was-running-bufs)))
      (if (null? targets)
          (message "no chat is waiting to be started")
          (let ((bs (filter agents-start-runtime! targets)))
            (if (null? bs)
                (message "every stopped chat is running again")
                (begin (agents-relist!) (agents-report "started" bs))))))))

;;; --- the chats, as a candidate prompt -------------------------------------
;;; The chat list is the application; this is the same chats drawn as a
;;; plain candidate prompt, for a surface that can only draw one.
;;; You know a chat by what it is about, so every
;;; row leads with its title -- the name somebody gave it, or the sentence
;;; its running summary wrote -- and the title is what you type at. The
;;; buffer name and the status follow as the annotation, which tells two
;;; chats apart when they read alike. The saved conversations come under
;;; the live ones, and RET on one reads its file back.

(define *chat-prompt-label-width* 62)

(define (chat-prompt-clip s)
  (if (> (string-length s) *chat-prompt-label-width*)
      (string-append (substring s 0 (- *chat-prompt-label-width* 3)) "...")
      s))

;; a titled chat wears its title as its buffer name (chat-title renames
;; it). A derived *chat:group* name is not a title, so the chat's own
;; title -- the first label its running summary wrote -- stands in.
;; The whole title: a broad list shows it in full.
(define (chat-prompt-full-label b)
  (if (not (string-prefix? "*" b))
      b
      (let ((s (chat-title-of b)))
        (if (and (string? s) (not (equal? s ""))) s b))))

;; the narrow form: one candidate line beside an annotation, so it clips
(define (chat-prompt-label b) (chat-prompt-clip (chat-prompt-full-label b)))

;; a row is (LABEL ANNOTATION KIND TARGET); the prompt gets the first
;; three, and the annotation's first two fields are typeable kinds, so
;; "run" narrows to the running chats and "saved" to the archive
(define (chat-prompt-live-row b)
  (list (chat-prompt-label b)
        (string-append (symbol->string (chat-row-status b)) "  " b)
        "chat"
        b))

(define (chat-prompt-saved-row path)
  (list (chat-prompt-clip (chats-archived-title path))
        (string-append "archived  " (format-time (file-mtime path) "%Y-%m-%d %H:%M"))
        "saved"
        path))

;; attention first, then the order you last used them: the chat you were
;; last in is the one you come back to
(define (chat-prompt-live-bufs) (chat-list-bufs))

(define (chat-prompt-tag r)
  (if (equal? (nth 2 r) "saved") (chat-log-leaf (nth 3 r)) (nth 3 r)))

;; two chats can wear one sentence, and the prompt answers with the
;; label: a repeat takes its buffer name and stays its own row
(define (chat-prompt-unique-rows rows)
  (let loop ((rs rows) (seen '()) (out '()))
    (if (null? rs)
        (reverse out)
        (let* ((r (car rs))
               (label (if (member (car r) seen)
                          (string-append (car r) "  (" (chat-prompt-tag r) ")")
                          (car r))))
          (loop (cdr rs) (cons label seen) (cons (cons label (cdr r)) out))))))

;; a heading row is (LABEL "" "separator"): the prompt steps over it and
;; drops it when its section empties, as C-x b does
(define (chat-prompt-separator label) (list label "" "separator"))

(define (chat-prompt-separator? r) (equal? (nth 2 r) "separator"))

(define (chat-prompt-section label rows)
  (if (pair? rows) (cons (chat-prompt-separator label) rows) '()))

;; the rows in sections by group, the way C-x b is: this group's chats
;; first, then the other groups by name, then the chats no group claims,
;; then the archived conversations
(define (chat-prompt-sectioned-rows live saved current)
  (let* ((tagged (map (lambda (r) (cons (buffer-group (nth 3 r)) r)) live))
         (rows-of (lambda (id)
                    (map cdr (filter (lambda (t) (equal? (car t) id)) tagged))))
         (named (sort (map (lambda (id)
                             (list (string-downcase (or (group-name id) "")) id))
                           (filter (lambda (id) (not (equal? id current)))
                                   (group-ids)))))
         (ordered (append (if current (list current) '()) (map cadr named)))
         (ungrouped (map cdr (filter (lambda (t) (not (member (car t) ordered)))
                                     tagged))))
    (append
      (fold (lambda (out id)
              (append out
                (chat-prompt-section
                  (or (group-name id) id)
                  (rows-of id))))
            '() ordered)
      (chat-prompt-section "ungrouped" ungrouped)
      (chat-prompt-section "archived" saved))))

(define (chat-prompt-rows &optional current)
  (let ((rows (chat-prompt-unique-rows
                (append (map chat-prompt-live-row (chat-prompt-live-bufs))
                        (map chat-prompt-saved-row (chats-archived-rows))))))
    (chat-prompt-sectioned-rows
      (filter (lambda (r) (equal? (nth 2 r) "chat")) rows)
      (filter (lambda (r) (equal? (nth 2 r) "saved")) rows)
      current)))

(define-command "chat-switch-prompt"
  "Switch to a chat by its title; with a prefix, show it in another window"
  (lambda ()
    (let* ((other-window? (and (current-prefix-arg) #t))
           (here (or (window-buffer (active-window)) (current-buffer)))
           (rows (chat-prompt-rows
                   (or (buffer-group here)
                       (frame-group))))
           ;; a heading is not a chat: typing its label names nothing
           (row-of (lambda (label)
                     (let ((r (assoc label rows)))
                       (and r (not (chat-prompt-separator? r)) r))))
           ;; the preview wakes a sleeping chat; every one nobody picked
           ;; goes back to sleep (the switcher's contract)
           (woken '())
           (sleep-woken! (lambda (keep)
                           (for-each (lambda (b)
                                       (unless (equal? b keep) (buffer-sleep! b)))
                                     woken)
                           (set! woken '()))))
      (if (null? rows)
          (message "No chats")
          (minibuffer-read-preview
            "Chat: "
            (map (lambda (r) (list (nth 0 r) (nth 1 r) (nth 2 r))) rows)
            ;; Choosing a row does not display or wake its buffer.
            (lambda (label) #f)
            (lambda (label)
              (let ((r (row-of label)))
                (cond
                  ((not r) (message "No chat by that name"))
                  ((equal? (nth 2 r) "saved")
                   (visit-in-group (nth 3 r) (frame-group))
                   (end-of-buffer!))
                  (other-window?
                   (let ((win (display-buffer-other-window! (nth 3 r))))
                     (when win (select-window! win))))
                  (else (switch-to-buffer! (nth 3 r)) (end-of-buffer!)))
                (sleep-woken! (and r (nth 3 r)))))
            (lambda () (sleep-woken! #f))
            ;; the status and the buffer name match what you type, so a
            ;; chat is found by its title first and by its state second
            2)))))


(define (agents-attention)
  (let loop ((ts (agent-threads)) (acc '()))
    (cond ((null? ts) (reverse acc))
          ((equal? (car (cdr (car ts))) 'needs_attention)
           (loop (cdr ts) (cons (car (car ts)) acc)))
          (else (loop (cdr ts) acc)))))

(define *agents-attention-last* #f)

(define (agents-modeline-refresh!)
  (let* ((att (agents-attention))
         (text (if (null? att) #f (string-append "! " (string-join att " ")))))
    ;; unchanged is not news: the old refresh repainted the modeline of
    ;; every frame on every event batch to say the same thing
    (unless (equal? text *agents-attention-last*)
      (set! *agents-attention-last* text)
      (global-mode-string-set! 'agents-attention
        (if text (list "ml-attention" text) #f)))))

(define-command "agent-goto-attention" "Jump to the first thread needing attention"
  (lambda ()
    (let ((att (agents-attention)))
      (if (null? att)
          (message "no agent needs attention")
          (begin (switch-to-buffer! (agent-buf (car att)))
                 (end-of-buffer!))))))

(define-key "agent-map" "n" "agent-open")

;; C-x C-b is the buffers in a window; C-x C-c is the chats. There is one
;; chat list and one arrival, so both keys reach the same application.
(define-key "ctl-x-map" "C-c" "chat-list")

(define-key "agent-map" "a" "agent-goto-attention")

;; C-x b is the buffers; C-x c is the chats — each the minibuffer form
;; of its own table. The control counterparts open the applications:
;; C-x C-b the buffers in a window, C-x C-c the chat list in its group.
;; chat-switch-prompt, the candidate prompt, stays for the surfaces that
;; draw only a prompt.
(global-set-key "C-x c" "chat-prompt")

(category! 'chat)
(catalog-meta! 'command "chats-archive" 'domain 'chat 'effects '(destroy))
(catalog-meta! 'command "chats-kill-runtime" 'domain 'chat 'effects '(destroy))
(catalog-meta! 'command "chats-stop-all" 'domain 'chat 'effects '(destroy))
(catalog-meta! 'command "chats-start-all" 'domain 'chat 'effects '(write external execute))
(public! 'chats-note-activity!
  "(chats-note-activity! BUF) — stamp the time of the last event that reached the chat BUF")
(public! 'chats-state-label
  "(chats-state-label STATUS) — the words a chat list row shows for a runtime status")


;;; ------------------------------------------------------------ the chat list
;; The chat list is the mode list of chat-mode (mode-list.scm): ibuffer
;; over the chats. What is the chats' own is here: the agents that are no
;; chat buffer, the rows at rest, the state and model sections, the saved
;; conversations under the live ones, the transcript a filter reads, and
;; the verbs on the chat at point.
(category! 'chat)
(effects! '(write display))

(defcustom 'chat-list-recent-limit 40
  "How many chats the chat list shows at rest. A search reads every chat.")

(define (chat-list--read-text b)
  (let* ((id (buffer-local b 'chat-log-id))
         (raw (if (buffer-exists? b)
                  (buffer-text b)
                  (and (string? id)
                       (let ((path (string-append (chat-log-dir-for b) "/" id ".chat")))
                         (and (file-exists? path)
                              (ignore-errors (lambda () (read-file path)))))))))
    (string-downcase (if (string? raw) raw ""))))

(define (chat-list-hit b) (mode-list-hit "chat-mode" b))
(define (chat-list-search-reset!) (mode-list-search-reset!))

(define (chat-list-search-hits q)
  ;; the transcript search at once, for a caller that waits for it
  (let ((q (string-downcase (string-trim q))))
    (if (< (string-length q) 3)
        '()
        (car (mode-list--scan (chat-list-bufs) chat-list--read-text q '())))))

(define (chats-live-note members)
  (let ((live (length (filter (lambda (b)
                                (and (buffer-known? b)
                                     (member (chat-row-status b) '(running starting))))
                              (filter string? members)))))
    (if (> live 0) (string-append (number->string live) " live") "")))

(mode-icon! "chat-list-mode" "")

(mode-list-define! "chat-mode"
  (list
    ;; an agent is listed with the chats even where its buffer is no chat
    'member-locals '("agent-slug")
    'member? (lambda (row) (or (equal? (cadr row) "chat-mode") (and (list-ref row 2) #t)))
    'recent-limit (lambda () chat-list-recent-limit)
    'defaults '(sort recent grouping group)
    ;; a chat you archived is still a chat you switch to: the saved
    ;; conversations come under the live ones, and RET reads one back
    'extra-rows (lambda (buf)
                  (ibuffer-section buf "archived" "archived" (chats-archived-rows) "faint" #t))
    'text (lambda (b) (chat-list--read-text b))
    'visit-row (lambda (path) (visit-in-group path (group-here)) (end-of-buffer!))
    'after-visit (lambda (b) (end-of-buffer!))
    'opts
      (list
        'doc (string-append
               "The chats, as ibuffer lists buffers: the recent ones at rest, the "
               "chat you used last at the top. f filters every chat, by title, "
               "state, model, and by a word somebody said in it. < cycles the "
               "sections (group, none: the most recent first), > the order, t "
               "turns the sections off and on. RET enters the chat; on a saved "
               "conversation at the bottom, RET reads it back. SPC marks, as in "
               "ibuffer. s steers the chat at point or the marked ones, y and d "
               "answer a permission, r gives a title, k kills, a archives, "
               "+ starts a chat, g reads the "
               "chats again, and q gives the frame back.")
        'category 'chat
        'title (lambda (buf) "Chats")
        'noun "chat"
        'section-note (lambda (buf members) (chats-live-note members))
        ;; the list stands still: g draws it again when you ask
        'stamp #f
        'keys '(("s" "agents-steer") ("y" "agents-allow") ("d" "agents-deny")
                ("a" "chats-archive") ("r" "chat-retitle-at-point")
                ("g" "agents-refresh")
                ("+" "agent-open")))))

(define (chat-list-preview!) (ibuffer-preview! (chat-list-buffer)))

(define (chat-list-back!)
  ;; leave the list the way q leaves it
  (let ((view (chat-list-buffer)))
    (mode-list-search-reset!)
    (when (buffer-known? view)
      (listing-preview-dismiss! view)
      (unless (transient-frame-exit! 'ibuffer)
        (when (window-showing view) (listing-quit! view))))))

(define (chat-list-open! &optional standing)
  (mode-list "chat-mode" standing))

(define-command "ichat" "Open the chat buffer listing here"
  (lambda () (chat-list-open!)))

(define-command "chat-list"
  "Switch to a chat, by its name or by a word somebody said in it"
  (lambda () (chat-list-open!)))

;;; --- the minibuffer form ------------------------------------------------------
;;; C-x c is these rows in the minibuffer's form, the way C-x b is the
;;; buffers': a popup under the work with its filter line already open.
;;; You type, the rows narrow, RET takes the row and the popup goes.
;;; The form keeps its own view buffer, so the sort, folds and grouping
;;; of the application on C-x C-c stay what you set them to — the
;;; application has one state and this borrows none of it.

(define *chat-prompt-buffer* " *chats*")
(add-display-rule! *chat-prompt-buffer* 'shaped '(side bottom size 0.4))
(ibuffer-view! *chat-prompt-buffer* 'sort 'recent 'grouping 'group)

(define (chat-prompt-open!)
  ;; a heading is folded by the prompt line itself, so PICK only ever
  ;; sees a chat: a live one by name, an archived one by its .chat path
  (ibuffer-prompt! 'chat-list *chat-prompt-buffer* "chat-list-mode" "Chat: "
    (lambda (row close!)
      (ibuffer-pick! row close!)
      (group-current-recalculate!))
    "minibuffer"))

(define-command "chat-prompt"
  "Switch to a chat with the plain minibuffer list"
  (lambda () (chat-prompt-open!)))

;; the name is gone but the words are not: you remember what the chat said
(define-command "chat-where"
  "Switch to the chat where this was said"
  (lambda ()
    (minibuffer-read "Chat where: " '()
      (lambda (words) (chat-list-open! (string-trim words))))))

(define-command "chat-finder"
  "Find chats by a keyword in their content"
  (lambda ()
    (minibuffer-read "Chat keyword: " '()
      (lambda (keyword)
        (let ((q (string-trim keyword)))
          (if (equal? q "")
              (message "Enter a keyword")
              (chat-list-open! q)))))))


(category! 'chat)
(catalog-meta! 'command "chat-list" 'domain 'chat 'effects '(write display))
(catalog-meta! 'command "chat-where" 'domain 'chat 'effects '(write display))
(catalog-meta! 'command "chat-finder" 'domain 'chat 'effects '(write display))
(public! 'chat-list-open!
  "(chat-list-open! [SEARCH]) — open the chat list, with SEARCH standing")
