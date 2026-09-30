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
(define (chat-list-buffer)
  (let ((here (window-buffer (active-window)))
        (view (frame-local 'chat-list-view)))
    (cond ((equal? (buffer-local here 'mode-name) "chat-list-mode") here)
          ;; a frame that saw the app before this session can still hold a
          ;; view name that no longer exists; the singleton is the truth
          ((and (string? view) (buffer-known? view)) view)
          (else *chat-list-buffer*))))


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
  (let ((mru (filter chat-list-buf? (buffer-list-mru))))
    (append mru
            (filter (lambda (b) (and (chat-list-buf? b) (not (member b mru))))
                    (buffer-list)))))

;; the ibuffer row kind asks this three times for one row (dot, label,
;; face), and a read from a chat buffer's own process is far slower than
;; from a plain one. The second and third ask of the same row reuse the
;; first's answer instead of paying its cost again.
(define *chat-row-status-memo* (list #f #f))

(define (chat-row-status b)
  (if (equal? (car *chat-row-status-memo*) b)
      (cadr *chat-row-status-memo*)
      (let* ((slug (buffer-local b 'agent-slug))
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
  (filter buffer-known? (ibuffer-targets (chat-list-buffer))))

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
;; The chat list is an application: one state, one buffer, one group, one
;; arrival. You open it to switch to a chat whose name you half remember,
;; and it leaves as soon as you pick one. docs/CHAT-LIST.md is the contract.
(category! 'chat)
(effects! '(write display))

;; chat-list-buffer resolves the invoking group's view (defined above).
(define *chat-list-group-name* "chat-list")
(define *chat-list-groupings* '(none group state model))

(defcustom 'chat-list-recent-limit 40
  "How many chats the chat list shows at rest. A search reads every chat.")

(define (chat-list-query)
  (if (buffer-known? (chat-list-buffer))
      (list-query (chat-list-buffer))
      ""))

;; at rest the list is the recent chats; the moment you type, the scope is
;; every chat, so the limit bounds the resting list and never the search
(define (chat-list-scope)
  (let ((all (chat-list-bufs)))
    (if (equal? (chat-list-query) "")
        (take all chat-list-recent-limit)
        all)))
(ibuffer-scope! 'chat-list (lambda () (chat-list-scope)))

;; A keyword search reads the text of every alive chat. Alive is every chat
;; that is not archived: an awake one answers from its buffer and a sleeping
;; one from its log file, so the search wakes nothing. Typing narrows, so a
;; query that extends the last one searches only what the last one found.
(define *chat-list-hits* '())        ; (QUERY (BUF SNIPPET) ...)
(define *chat-list-text-cache* '())  ; (BUF TEXT), lowercase, one search burst

(define (chat-list--read-text b)
  (let* ((id (buffer-local b 'chat-log-id))
         (raw (if (buffer-exists? b)
                  (buffer-text b)
                  (and (string? id)
                       (let ((path (string-append (chat-log-dir-for b) "/" id ".chat")))
                         (and (file-exists? path)
                              (ignore-errors (lambda () (read-file path)))))))))
    (string-downcase (if (string? raw) raw ""))))

(define (chat-list-text b)
  (let ((memo (assoc b *chat-list-text-cache*)))
    (if memo (cadr memo)
        (let ((text (chat-list--read-text b)))
          (set! *chat-list-text-cache* (cons (list b text) *chat-list-text-cache*))
          text))))

;; the row shows why it matched, so the words around the hit stand in for
;; the line: a transcript holds no short lines to quote
(define (chat-list-snippet text at)
  ;; string-index answers in bytes, so the window is in bytes as well
  (let* ((from (max 0 (- at 40)))
         (to (min (string-byte-length text) (+ at 80))))
    (string-join (string-split (substring-bytes text from to) "\n") " ")))

(define (chat-list-search-hits q)
  (let* ((q (string-downcase (string-trim q)))
         (last (if (pair? *chat-list-hits*) (car *chat-list-hits*) ""))
         ;; a longer query can only match where the shorter one did
         (pool (if (and (>= (string-length last) 3)
                        (string-prefix? last q))
                   (map car (cdr *chat-list-hits*))
                   (chat-list-bufs))))
    (set! *chat-list-hits*
      (cons q
            (if (< (string-length q) 3)
                '()
                (fold (lambda (out b)
                        (let* ((text (chat-list-text b))
                               (at (string-index text q)))
                          (if at
                              (append out (list (list b (chat-list-snippet text at))))
                              out)))
                      '()
                      pool))))
    (cdr *chat-list-hits*)))

(define (chat-list-hit b)
  (let ((e (assoc b (if (pair? *chat-list-hits*) (cdr *chat-list-hits*) '()))))
    (and e (cadr e))))

(define (chat-list-search-reset!)
  (chat-list--cancel-search!)
  (set! *chat-list-hits* '())
  (set! *chat-list-text-cache* '()))

;; Full transcripts never run on the key-dispatch lane. The worker reads
;; immutable inputs and returns data; only the accepted callback publishes it.
(define *chat-list-search-generation* 0)
(define *chat-list-search-request* #f)
(define *chat-list-search-task* #f)

(define (chat-list--cancel-search!)
  (set! *chat-list-search-request* #f)
  (debounce-cancel! "chat-list-search")
  (when *chat-list-search-task* (task-cancel! *chat-list-search-task*))
  (set! *chat-list-search-task* #f))

(define (chat-list--scan q cache)
  (let loop ((rows (chat-list-bufs)) (texts cache) (hits '()))
    (if (null? rows) (list (reverse hits) texts)
        (let* ((b (car rows))
               (memo (assoc b texts))
               (text (if memo (cadr memo) (chat-list--read-text b)))
               (at (string-index text q)))
          (loop (cdr rows)
                (if memo texts (cons (list b text) texts))
                (if at (cons (list b (chat-list-snippet text at)) hits) hits))))))

(define (chat-list--search-current? request)
  (and (equal? request *chat-list-search-request*)
       (let ((mb (minibuffer-state)))
         (or (not mb)
             (and (equal? *mb-list-buffer* (chat-list-buffer))
                  (equal? (cadr request)
                          (string-downcase (string-trim (plist-get mb 'input)))))))
       (window-showing (chat-list-buffer))
       (equal? (cadr request) (string-downcase (string-trim (list-query (chat-list-buffer)))))))

(define (chat-list--search-start! request)
  (when (chat-list--search-current? request)
    (let ((q (cadr request)) (cache *chat-list-text-cache*))
      (set! *chat-list-search-task*
        (task-run!
          (lambda () (chat-list--scan q cache))
          (lambda (ok result)
            (when (chat-list--search-current? request)
              (set! *chat-list-search-task* #f)
              (when ok
                (set! *chat-list-text-cache* (cadr result))
                (set! *chat-list-hits* (cons q (car result)))
                ;; Transcript matches can add rows that the title filter
                ;; rejected. Start from the source and keep the selected row.
                (list-filter-forget! (chat-list-buffer))
                (list-redraw! (chat-list-buffer))
                (chat-list-preview!)))))))))

(define (chat-list--search-later! q)
  (chat-list--cancel-search!)
  (let ((q (string-downcase (string-trim q))))
    ;; Old snippets must not participate in this query's immediate matches
    ;; or survive as cached display cells after their search was cleared.
    (when (pair? *chat-list-hits*) (list-filter-row-forget! (chat-list-buffer)))
    (set! *chat-list-hits* '())
    (when (>= (string-length q) 3)
      (set! *chat-list-search-generation* (+ 1 *chat-list-search-generation*))
      (let ((request (list *chat-list-search-generation* q)))
        (set! *chat-list-search-request* request)
        (debounce! "chat-list-search" (+ ibuffer-filter-delay-ms 100)
                   chat-list--search-start! request)))))

;; a section is a group, a state or a model, and none is the flat list in
;; most recently used order: the order you last used a chat is the one the
;; half-remembered name arrives in
;; a chat that is running is the one thing about a section you want
;; before you open it; a section with none says only how many it holds
(define (chats-live-note members)
  (let ((live (length (filter (lambda (b)
                                (and (buffer-known? b)
                                     (member (chat-row-status b) '(running starting))))
                              (filter string? members)))))
    (if (> live 0) (string-append (number->string live) " live") "")))

;; Search headings only describe match provenance, not mutable groups.
;; Avoid collecting per-buffer sizes/status just to label search results.
(define (chat-list-match-section label key rows)
  (if (null? rows) '()
      (cons (list label "" "match" key (length rows) 0 0 "faint" rows) rows)))

(define (chat-list-match? buf row input)
  (if (ibuffer-heading? row)
      (let loop ((members (ibuffer-heading-members row)))
        (and (pair? members)
             (or (chat-list-match? buf (car members) input) (loop (cdr members)))))
      (or (ibuffer-match? buf row input)
          (let ((hit (chat-list-hit row)))
            (and hit (completion-match? hit input 'substring))))))

(define (chat-list-rank buf rows)
  (let ((q (list-query buf)))
    (if (or (equal? q "") (not (buffer-local buf 'chat-list-search))) rows
        (let split ((rest (filter string? rows)) (titles '()) (metadata '()) (transcripts '()))
          (if (null? rest)
              (append
                (chat-list-match-section "Title matches" "match:title" (reverse titles))
                (chat-list-match-section "Metadata matches" "match:metadata" (reverse metadata))
                (chat-list-match-section "Transcript matches" "match:transcript" (reverse transcripts)))
              (let ((b (car rest)))
                (cond ((completion-match? (ibuffer-row-title b) q 'substring)
                       (split (cdr rest) (cons b titles) metadata transcripts))
                      ((completion-match?
                         (string-append b " " (chats-metadata-text b)) q 'substring)
                       (split (cdr rest) titles (cons b metadata) transcripts))
                      (else (split (cdr rest) titles metadata (cons b transcripts))))))))))

;;; --- the snapshot ---------------------------------------------------------
;;; One batch read carries every fact a chat row shows: the title, summary,
;;; model, transcript size, and group. Sectioning and sorting read it. A
;;; runtime status is asked once per chat here and carried along, so the
;;; sectioning no longer calls ibuffer-note-kinds! or walks each buffer's
;;; group membership per row.

(define *chat-list-snapshots* '())

;; a snapshot row: (NAME TITLE SUMMARY MODEL SIZE GROUP-ID). A chat's runtime
;; status stays out of the snapshot: the default grouping never reads it,
;; and the state grouping asks it through the existing memo.
(define (chat-list-table-row r)
  (let* ((name (car r))
         (title (let ((t (nth 4 r))) (if (and (string? t) (not (equal? t ""))) t #f)))
         (summary (nth 5 r))
         (model (or (nth 6 r) (nth 7 r) ""))
         (size (or (nth 9 r) (chats-filesize name)))
         (ids (nth 10 r))
         (ids (cond ((string? ids) (list ids)) ((pair? ids) ids) (else '())))
         (label (or title (and (string? summary) (not (equal? summary "")) summary) name)))
    (list name label summary model (or size #f) (if (pair? ids) (car ids) #f))))

(define (chat-list-table-load! buf names)
  (let ((raw (buffer-read-many names '(path)
               '(mode-name agent-slug chat-title chat-summary agent-model llm-model
                 chat-log-id chat-log-size group-id group-ids group))))
    (set! *chat-list-snapshots*
      (take (cons (cons buf (map chat-list-table-row raw))
                    (remove (lambda (e) (equal? (car e) buf)) *chat-list-snapshots*)) 16))
    ;; the cell path asks ibuffer-row-kind per row; note it from the
    ;; mode-name this read already holds, so it never re-asks a buffer
    (set! *ibuffer-kind-notes*
      (map (lambda (r) (list (car r) (if (equal? (nth 2 r) "chat-mode") 'chat 'buffer)))
           raw))))

(define (chat-list-table-data buf name)
  (let ((view (assoc buf *chat-list-snapshots*)))
    (and view (assoc name (cdr view)))))

(define (chat-list-row-name r) (car r))
(define (chat-list-row-title r) (nth 1 r))
(define (chat-list-row-summary r) (nth 2 r))
(define (chat-list-row-model r) (nth 3 r))
(define (chat-list-row-size r) (nth 4 r))
(define (chat-list-row-group r) (nth 5 r))

;; a heading built from snapshot facts: count, bytes, face, members
(define (chat-list-heading buf label key members face)
  (list label "" (if (ibuffer-folded? key buf) "folded" "separator") key
        (length members) 0
        (fold (lambda (n b)
                (+ n (or (let ((d (chat-list-table-data buf b)))
                           (and d (chat-list-row-size d)))
                         0)))
              0 members)
        face members))

(define (chat-list-sort-members buf members)
  (let ((order (ibuffer-sort buf))
        (row-of (lambda (b) (or (chat-list-table-data buf b)
                                (list b b "" "" #f #f)))))
    (cond ((equal? order 'size)
           (map cadr (sort (map (lambda (b)
                                  (list (- 0 (or (chat-list-row-size (row-of b)) 0)) b))
                                members))))
          ((equal? order 'name)
           (map cadr (sort (map (lambda (b)
                                  (list (string-downcase (chat-list-row-title (row-of b))) b))
                                members))))
          (else members))))

(define (chat-list-section buf label key members face)
  (if (null? members) '()
      (let ((ordered (chat-list-sort-members buf members)))
        (if (ibuffer-folded? key buf)
            (list (chat-list-heading buf label key ordered face))
            (cons (chat-list-heading buf label key ordered face) ordered)))))

;; rows sectioned by group from the snapshot: the ibuffer bucketing, but
;; membership is a snapshot lookup, never a per-buffer group read
(define (chat-list-group-sections buf)
  (apply append
    (map (lambda (bucket)
           (chat-list-section buf (car bucket) (nth 1 bucket) (nth 2 bucket) (nth 3 bucket)))
         (ibuffer-group-buckets (ibuffer-scope-names buf) (frame-group)
           (lambda (b)
             (let ((d (chat-list-table-data buf b)))
               (let ((g (and d (chat-list-row-group d))))
                 (if g (list g) '()))))))))

(define (chat-list-keyed-sections buf key-of)
  (let* ((names (ibuffer-scope-names buf))
         (keys (dedupe-names (map key-of names)))
         (named (map cadr (sort (map (lambda (k) (list (string-downcase k) k)) keys)))))
    (apply append
      (map (lambda (k)
             (chat-list-section buf k k
               (filter (lambda (b) (equal? (key-of b) k)) names) "faint"))
           named))))

(define (chat-list-rows buf)
  (ibuffer-columns-clear!)
  (let ((grouping (ibuffer-grouping buf)))
    (chat-list-table-load! buf (ibuffer-scope-names buf))
    (append
      (cond
        ((equal? grouping 'none)
         (let ((members (map chat-list-row-name (cdr (assoc buf *chat-list-snapshots*)))))
           (chat-list-sort-members buf members)))
        ((equal? grouping 'state)
         (chat-list-keyed-sections buf
           (lambda (b) (chats-state-label (chat-row-status b)))))
        ((equal? grouping 'model)
         (chat-list-keyed-sections buf
           (lambda (b)
             (let ((m (let ((d (chat-list-table-data buf b))) (and d (chat-list-row-model d)))))
               (if (or (not m) (equal? m "")) "no model" m)))))
        (else (chat-list-group-sections buf)))
      ;; a chat you archived is still a chat you switch to: the saved
      ;; conversations come under the live ones, and RET on one reads its
      ;; file back
      (ibuffer-section buf "archived" "archived" (chats-archived-rows) "faint" #t))))

;; A flat list is reached by recency, so the group a chat belongs to is a
;; column of the row and not a heading over it. ibuffer-field-live?
;; already rules the column out while the sections are the groups, which
;; is the one arrangement that says it twice.
(define *chat-list-narrow-fields* '((last 4 right end)))
(define *chat-list-compact-fields*
  '((size 6 right end) (mode 10 left end) (group 14 left end) (last 4 right end)))
(define *chat-list-wide-fields*
  '((size 7 right end) (mode 14 left end) (group 18 left end) (last 4 right end)))

;; ibuffer's own column and cell readers memoise on the field count, and
;; the compact list and the wide one here hold the same number of fields,
;; so read the fields straight rather than through the memo.
(define (chat-list-fields buf all)
  (filter (lambda (f) (ibuffer-field-live? buf (ibuffer-field-tag f))) all))

;; no fitting: a group named after a saved-chat file is 32 characters
;; wide, and growing the column to it took the room the title needs. The
;; column holds its width and clips.
(define (chat-list-columns buf all)
  (ibuffer-columns buf (map ibuffer-field-column (chat-list-fields buf all))))

(define (chat-list-cells buf b all)
  (let ((fields (chat-list-fields buf all)))
    (if (ibuffer-heading? b)
        (ibuffer-heading-cells buf b (length fields))
        (append (ibuffer-cell-head buf b)
                (map (lambda (f)
                       (let ((tag (ibuffer-field-tag f)))
                         (list (ibuffer-field-fill (ibuffer-field-cell b tag))
                               (if (member tag '(mode group)) "dim" "faint"))))
                     fields)))))

(mode-icon! "chat-list-mode" "")
(define-list-mode! "chat-list-mode"
  (ibuffer-mode-opts
    (list
      'transient #f
      'composml-root (lambda (buf) (list 'tag "chat-list"))
      'composml-record (lambda (buf entry) (ibuffer-composml-record buf entry))
      'doc (string-append
             "The chat list opens here. The rows "
             "are the recent chats, most recently used first. The list has the "
             "focus; n and p select rows and read the chat itself in the other "
             "window — the buffer, not a copy of it. "
             "f opens the filter line: the filter "
             "reads the title first and the state second, and it reads every "
             "chat, not only the recent ones. A word that nobody put in a "
             "title is found in the text of every alive chat, and the row "
             "shows the words around it. C-g closes the filter and leaves the "
             "list standing. RET enters the chat's own group and raises the "
             "window that holds it; q leaves and changes nothing. The list "
             "rests flat, the chat you used last at the top of it, and every "
             "row wears the name of the group its chat belongs to. t turns "
             "the sections on and off, and < cycles what a section is: none, "
             "group, state, model -- the group column steps aside while the "
             "sections are the groups. > cycles the "
             "order inside a section: most recent first, by name, or by the "
             "size of the transcript on disk. The verbs act on the chat at point "
             "and leave the list standing: s steers it, y and d answer the "
             "permission it waits on, r gives it a title, k stops its "
             "runtime and keeps the transcript, a archives it, g draws the "
             "list again and + starts a new chat. The last section holds "
             "the newest saved conversations; RET on one reads its file "
             "back and revives the chat.")
      'buffer (chat-list-buffer)
      'category 'chat
      'title (lambda (buf) "Chats")
      'noun "chat"
      ;; what a section of chats is worth saying beyond how many: how
      ;; many of them are running right now
      'section-note (lambda (buf members) (chats-live-note members))
      'rows (lambda (buf) (chat-list-rows buf))
      'layouts
        (list
          (list 'name 'narrow
                'max-cols (lambda (buf) (- ibuffer-narrow-cols 1))
                'columns (lambda (buf) (chat-list-columns buf *chat-list-narrow-fields*))
                'cells (lambda (buf b) (chat-list-cells buf b *chat-list-narrow-fields*))
                'meta (lambda (buf) (ibuffer-compact-meta buf))
                'footer (lambda (buf) (ibuffer-footer buf ibuffer-compact-footer)))
          (list 'name 'compact
                'max-cols (lambda (buf) (- ibuffer-compact-cols 1))
                'columns (lambda (buf) (chat-list-columns buf *chat-list-compact-fields*))
                'cells (lambda (buf b) (chat-list-cells buf b *chat-list-compact-fields*))
                'meta (lambda (buf) (ibuffer-compact-meta buf))
                'footer (lambda (buf) (ibuffer-footer buf ibuffer-compact-footer)))
          (list 'name 'wide
                'default #t
                'columns (lambda (buf) (chat-list-columns buf *chat-list-wide-fields*))
                'cells (lambda (buf b) (chat-list-cells buf b *chat-list-wide-fields*))
                'meta (lambda (buf) (ibuffer-wide-meta buf))
                'footer (lambda (buf) (ibuffer-footer buf ibuffer-wide-footer))))
      'order-filtered chat-list-rank
      'match chat-list-match?
      'regroup (lambda (buf) (run-command "chat-list-regroup"))
      'resort (lambda (buf) (run-command "chat-list-resort"))
      ;; row movement fills the pane the list opened beside itself; the
      ;; minibuffer form, which has no pane, still gets its card
      'preview (lambda (buf b) (chat-list-preview-row! buf b))
      ;; The table stamps itself with the buffer count and redraws after
      ;; any command that moved it, so a buffer opened anywhere -- by a
      ;; chat you are not even reading -- rebuilt this list under the
      ;; cursor. An application is not a table: it stands still, and g
      ;; draws it again when you ask. No stamp, no redraw behind you.
      'stamp #f
      ;; the picker acts on one chat, the one at point: no marks, and no
      ;; flag-then-run, which is a table's idea and not an application's
      'markable? (lambda (buf e) #f)
      'flags '()
      ;; n moves and p turns the row preview off and on (the owner's
      ;; ruling, 2026-09-19), so the answer keys are y and d, and k stops a
      ;; runtime without touching the transcript the way the table's k
      ;; would kill the buffer outright
      'keys '(("C-x o" "listing-peek-open-other") ("s-RET" "listing-peek-open-other")
              ("C-x n n" "ibuffer-narrow-group") ("C-x n w" "ibuffer-widen-group")
              ("f" "chat-list-filter") ("RET" "chat-list-visit")
              ("p" "ibuffer-toggle-preview")
              ("q" "chat-list-quit")
              ("s" "agents-steer") ("y" "agents-allow") ("d" "agents-deny")
              ("a" "chats-archive") ("r" "chat-retitle-at-point")
              ("k" "chats-kill-runtime") ("g" "agents-refresh")
              ("t" "chat-list-toggle-groups")
              ("+" "agent-open")))))
;; The list rests flat, the chat you used last at the top: you reach for
;; a chat by when you last used it, not by which group it sits in. The
;; group is still a fact about the chat, so every row wears its name; /
;; cycles the sections on when you want them, and the column steps aside
;; then. The defaults live in one place because chat-list-view! registers
;; the view again the first time the buffer is made, and a bare
;; (ibuffer-view! buf) there replaced this entry -- the first list of a
;; session opened under ibuffer's defaults instead of its own.
(define (chat-list-view-defaults! &optional buf)
  (ibuffer-view! (or buf (chat-list-buffer)) 'sort 'recent 'grouping 'none))
(chat-list-view-defaults!)

;; ---- the application

(define (chat-list-group) (group-ensure-record! *chat-list-group-name*))

(define (chat-list-view!)
  ;; one list, and it opens in the window you called it from. A view per
  ;; group -- what ibuffer does -- made a *chat-list*<n> for every group
  ;; the frame ever stood in, so which list you got depended on where you
  ;; were standing. There is one, it comes to the current window, and it
  ;; joins the group that window is in.
  (let ((buf *chat-list-buffer*))
    (unless (buffer-known? buf)
      (buffer-create buf)
      (chat-list-view-defaults! buf))
    buf))

(define (chat-list-arrive!)
  ;; the list opens in the window you called it from, in the group you
  ;; called it from.
  ;;
  ;; The list takes one window and previews with a floating card, the
  ;; same way ibuffer does — one preview surface for both listings. It
  ;; used to cover the frame and split a 2/3 + 1/3 pane for the chat
  ;; instead; a pane of its own meant there was never a neighbour for a
  ;; card to lie over, and covering the frame put a chat from one group
  ;; and a buffer from another side by side in one viewport.
  ;;
  ;; Taking a window is still only fair if the frame comes back, so the
  ;; list is a transient frame mode (layouts.scm): it records the
  ;; arrangement it found and gives that back whole when it leaves.
  ;; Re-arming rather than entering matters because the list can stop
  ;; standing without leaving through q — a listing takes its window, a
  ;; layout is applied — and the tree it promised to restore is then a
  ;; tree of windows that no longer exist.
  (let ((buf (chat-list-view!)))
    (unless (transient-frame-standing? 'chat-list) (chat-list-release-hold!))
    (transient-frame-rearm! 'chat-list (frame-local 'chat-list-view))
    ;; the resting sort and grouping in one place: this said 'grouping
    ;; 'group and ran on every arrival, so the list came up in sections
    ;; whatever the view registered and docs/CHAT-LIST.md promised
    (chat-list-view-defaults! buf)
    (set-frame-local! 'chat-list-view buf)
    ;; arriving is an explicit request to look, so a card dismissed on
    ;; this row last time does not silence the preview on this one
    (buffer-set-local! buf 'listing-peek-dismissed-row #f)
    (with-layout-suppressed (lambda () (switch-to-buffer-here! buf)))
    ;; the group is settled only now: a frame with no group yet gets one
    ;; as the windows change, and a list left ownerless is a list no
    ;; group ever reuses. It belongs to the group you opened it in
    (group-current-recalculate!)
    ;; one list serves every group, so the row it was left on is a row in
    ;; the group it was left in. Coming in from elsewhere is a first
    ;; arrival in this group: say so, and the opener starts at the top
    (let* ((group (frame-group))
           (fresh (and group (not (equal? (buffer-group buf) group)))))
      (buffer-set-local! buf 'chat-list-fresh-group fresh)
      (when fresh (buffer-move-to-group! buf group)))
    buf))

(defcustom 'chat-list-preview-delay-ms 150
  "Milliseconds of idle time before the chat list previews the selected row."
  'group 'chat 'type 'number)

;; Timer bookkeeping is not display state: changing it must not emit
;; frame updates. Keep one pending request per frame on the Scheme lane.
(define *chat-list-preview-requests* '())
(define *chat-list-preview-generation* 0)

;; A peek owns its display state, never a chat runtime or identity.
(define (chat-preview-project--locals! copy source)
  (let ((mark (buffer-local source 'agent-saved-mark)))
    (if (and (buffer-exists? source) (number? mark))
        (buffer-set-locals! copy
          (list 'render-mode "blocks"
                'agent-blocks (or (buffer-local source 'agent-blocks) '())
                'agent-saved-mark mark
                'agent-marker-bytes (or (buffer-local source 'agent-marker-bytes) 0)
                'agent-verbosity (or (buffer-local source 'agent-verbosity) "info")))
        ;; Saved chat files contain a header and an optional wire record.
        ;; Reconstruct only the presentation, without reopening the chat.
        (let* ((raw (buffer-text copy))
               (nl (string-index raw "\n"))
               (header (chat-parse-header (if nl (substring-bytes raw 0 nl) raw)))
               (end (or (chat-file-record-at raw) (string-byte-length raw)))
               (turns (if header (chat-parse-transcript (substring-bytes raw 0 end))
                          (list (list "assistant" raw)))))
          (let loop ((rest turns) (offset 0) (texts '()) (blocks '()))
            (if (null? rest)
                (begin
                  (buffer-replace-range! copy 0 (buffer-size copy)
                    (string-join (reverse texts) ""))
                  (buffer-set-locals! copy
                    (list 'render-mode "blocks" 'agent-blocks blocks
                          'agent-saved-mark offset 'agent-marker-bytes 0)))
                (let* ((turn (car rest)) (role (car turn)) (body (cadr turn))
                       (text (if (equal? role "user")
                                 (string-append "\n>>> you: " body "\n\n")
                                 (string-append body "\n")))
                       (next (+ offset (string-byte-length text)))
                       (kind (cond ((equal? role "user") "user")
                                   ((equal? role "status") "status") (else "prose"))))
                  (loop (cdr rest) next (cons text texts)
                    (cons (append (list offset next kind)
                                  (if (equal? role "user") (list body) '())) blocks)))))))))

;; the copy draws as a rich chat: its tree comes from the projected model
(define (chat-preview-live-tree? copy source)
  ;; A live chat keeps its own view tree current: chat-view-sync! runs on every
  ;; event batch, shown or not. listing-preview-copy! has already carried that
  ;; tree into the copy, so there is nothing left to build.
  (and (buffer-exists? source)
       (number? (buffer-local source 'agent-saved-mark))
       (equal? (buffer-local copy 'render-mode) "blocks")
       (pair? (buffer-local copy 'render-blocks))))

(define (chat-preview-project! copy source)
  ;; Rebuilding the transcript view inside the copy cost the whole chat on
  ;; every row move, which is what made previews crawl. Take the tree the
  ;; source already carried across, and project only a chat that has none:
  ;; a saved chat file, or one that has never rendered.
  (if (chat-preview-live-tree? copy source)
      (buffer-set-locals! copy
        (list 'render-input "agent-saved-mark"
              'agent-saved-mark (buffer-local source 'agent-saved-mark)
              'agent-marker-bytes (or (buffer-local source 'agent-marker-bytes) 0)
              'agent-verbosity (or (buffer-local source 'agent-verbosity) "info")))
      (begin
        (chat-preview-project--locals! copy source)
        (chat-view-sync! copy))))

(define (chat-list--preview-request)
  (let ((entry (assoc (selected-frame) *chat-list-preview-requests*)))
    (and entry (cadr entry))))

(define (chat-list--preview-key)
  (string-append "chat-list-preview:" (selected-frame)))

(define (chat-list--cancel-preview!)
  (let ((frame (selected-frame)))
    (set! *chat-list-preview-requests*
      (filter (lambda (entry) (not (equal? (car entry) frame)))
              *chat-list-preview-requests*)))
  (debounce-cancel! (chat-list--preview-key)))

;; Compatibility callbacks cannot resurrect previews after a live reload.
(define (chat-list--preview-now! request) #f)
(define (chat-list-preview-row! owner row)
  ;; one preview surface for both listings: the row at point floats the
  ;; same read-only card ibuffer floats, laid over a neighbouring window
  ;; rather than a pane of the list's own. A heading is not a chat and an
  ;; archived row is a path, not a buffer: ibuffer-preview! leaves the
  ;; card showing what it last held rather than blanking it.
  (ibuffer-preview! owner row))

(define (chat-list-preview!)
  (let ((owner (chat-list-buffer)))
    (chat-list-preview-row! owner (list-current owner))))

;; the application leaves the way it arrived: with one move. RET lands you
;; in the chat, in the chat's own group, because switching to a chat is
;; switching to where that chat lives. C-g puts the frame back.
(define (chat-list-clear-search!)
  (chat-list--cancel-preview!)
  (chat-list-search-reset!)
  (when (buffer-known? (chat-list-buffer))
    (buffer-set-local! (chat-list-buffer) 'chat-list-search #f)
    (list-clear-query! (chat-list-buffer))))

;; the list owns the focus, so every way back into it is the same move
(define (chat-list-focus!)
  (let ((w (if (equal? (window-buffer (active-window)) (chat-list-buffer))
               (active-window) (window-showing (chat-list-buffer)))))
    (when (and w (window-exists? w)) (select-window! w))))

(define (chat-list-release-hold!)
  ;; the bookkeeping half of leaving, with no window moved: the frame
  ;; gets its own pin back and the list stops holding a pane.
  (when (frame-local 'chat-list-pinned)
    (set-frame-local! 'pinned-group (frame-local 'chat-list-prior-pin))
    (set-frame-local! 'chat-list-prior-pin #f)
    (set-frame-local! 'chat-list-held-group #f)
    (set-frame-local! 'chat-list-pinned #f))
  (set-frame-local! 'chat-list-preview-window #f))

(define (chat-list-uncover!)
  ;; the list took a window, so leaving hands the whole arrangement back.
  ;; With nothing recorded there is nothing to restore and the ordinary
  ;; listing quit reveals whatever the window held before.
  ;;
  ;; The card goes first. A card saves the arrangement it lay over, and
  ;; that arrangement has the list in it: dismissed after the frame is
  ;; given back, its restore lands on top and puts the list back on
  ;; screen -- which is what made leaving take two q's, the second one
  ;; finding no record left and deleting the window instead of giving
  ;; the frame back.
  (listing-preview-dismiss! (chat-list-buffer))
  (chat-list-release-hold!)
  (unless (transient-frame-exit! 'chat-list)
    (listing-quit! (chat-list-buffer))))

(define (chat-list-keep! keep)
  (chat-list-clear-search!)
  ;; the frame goes back to what the list covered, and the chat you
  ;; picked lands in it — you leave in the arrangement you were working
  ;; in, not in the list's two panes
  (chat-list-uncover!)
  (listing-visit! (chat-list-buffer) keep)
  (when (equal? (window-buffer (active-window)) keep) (end-of-buffer!)))

(define (chat-list-back!)
  (chat-list-clear-search!)
  (chat-list-uncover!))

;; a saved conversation is a file and has no group of its own, so reading
;; it back lands it where you stood when you asked for it
(define (chat-list-revive! path)
  (chat-list-back!)
  (visit-in-group path (group-here))
  (end-of-buffer!))

(define (chat-list-leave! keep)
  (cond ((and (string? keep) (buffer-known? keep)) (chat-list-keep! keep))
        ((and (string? keep) (file-exists? keep)) (chat-list-revive! keep))
        (else (chat-list-back!))))

;; one filter line over one list: what you type reads the titles, and the
;; same words read the text of every alive chat
(define (chat-list-filter-line! &optional standing)
  (let* ((input (list-query (chat-list-buffer)))
         (apply-query (lambda (q)
                 (with-buffer-display-update (chat-list-buffer) (lambda ()
                   (buffer-set-local! (chat-list-buffer) 'chat-list-search q)
                   ;; Only crossing between the recent scope and all chats
                   ;; changes the source. Subsequent keys filter that snapshot.
                   (let ((was-empty (equal? (list-query (chat-list-buffer)) "")))
                     (list-set-query! (chat-list-buffer) q
                       (not (equal? was-empty (equal? q "")))))
                   (ibuffer-goto-first-row! (chat-list-buffer))
                   (chat-list-preview!)))))
         (generation 0)
         (narrow (lambda (q)
                   (set! input q)
                   ;; Input itself is already in the minibuffer. Coalesce the
                   ;; expensive table draw, not the characters the user types.
                   (set! generation (+ generation 1))
                   (chat-list--search-later! q)
                   (chat-list--cancel-preview!)
                   (let ((ticket generation))
                     (debounce! "chat-list-filter" ibuffer-filter-delay-ms
                       (lambda (input)
                         (let ((mb (minibuffer-state)))
                           (when (and (= ticket generation) mb
                                      (equal? *mb-list-buffer* (chat-list-buffer))
                                      (equal? (plist-get mb 'input) input))
                             (apply-query input)))) q))))
         (done (lambda (&optional keep-search)
                 (set! generation (+ generation 1))
                 (debounce-cancel! "chat-list-filter")
                 (unless keep-search (chat-list--cancel-search!))
                 (set! *mb-list-flush* #f)
                 (set! *mb-list-buffer* #f) (set! *mb-list-prompt* #f))))
    (when (and (string? standing) (not (equal? standing "")))
      (set! input standing)
      (apply-query standing))
    (set! *mb-list-buffer* (chat-list-buffer))
    (set! *mb-list-prompt* "Chat: ")
    (minibuffer-read* "Chat: " '()
      (list (list 'change narrow)
            (list 'confirm
                  (lambda (q)
                    (unless (equal? q (list-query (chat-list-buffer))) (apply-query q))
                    (done)
                    (let ((row (list-current (chat-list-buffer))))
                      (if (ibuffer-heading? row)
                          (begin
                            (ibuffer-toggle-fold! (ibuffer-heading-key row) (chat-list-buffer))
                            (chat-list-focus!))
                          (chat-list-leave! row)))))
            ;; the filter is one line over the list, not the life of the
            ;; application: closing it hands the list back its focus
            (list 'cancel
                  (lambda ()
                    ;; Closing the editor keeps its value. Only the filter
                    ;; pop command removes the narrowing from the list.
                    (unless (equal? input (list-query (chat-list-buffer)))
                      (apply-query input))
                    (done #t)
                    (chat-list-preview!)
                    (chat-list-focus!)))
            (list 'legend *ibuffer-prompt-legend*)
            (list 'style "filter")))
    ;; Motion must act on the typed query, even inside the redraw delay.
    ;; Invalidate the pending draw so it cannot move selection back later.
    (set! *mb-list-flush*
      (lambda ()
        (set! generation (+ generation 1))
        (debounce-cancel! "chat-list-filter")
        (unless (equal? input (list-query (chat-list-buffer))) (apply-query input))))
    (unless (equal? input "") (minibuffer-change! input))))

(define (chat-list-open! &optional standing)
  (let ((view (chat-list-arrive!)))
    (buffer-set-local! (chat-list-buffer) 'ibuffer-scope 'chat-list)
    ;; the window form floats a card like ibuffer. A home window is what
    ;; the minibuffer form previews into instead of a card, and setting
    ;; it here is what silenced this list's preview altogether
    (buffer-set-local! (chat-list-buffer) 'ibuffer-prompt-home-window #f)
    (list-clear-query! (chat-list-buffer))
    (with-current-buffer (chat-list-buffer)
      (lambda () (with-list-mode-skip-render (lambda () (set-mode! "chat-list-mode")))))
    ;; the chat list is a table, not a picker: a group row takes the
    ;; highlight and the verbs read it as every chat under it
    (buffer-set-local! (chat-list-buffer) 'ibuffer-heading-rows #t)
    (ibuffer-refresh! (chat-list-buffer))
    ;; the list keeps the row it was left on, but only where that row is
    ;; still yours to keep: one list serves every group, and the first
    ;; time it comes to this group it is standing on somebody else's
    ;; row. A heading is not a chat either — arriving on one leaves the
    ;; pane with nothing to show, and grouping by group puts a heading
    ;; first. Either way, fall through to the top of the list
    (let ((row (list-current (chat-list-buffer))))
      (when (or (buffer-local (chat-list-buffer) 'chat-list-fresh-group)
                (not (and (string? row) (not (ibuffer-heading? row)))))
        (ibuffer-goto-first-row! (chat-list-buffer))))
    ;; arriving is an explicit request to look. A card dismissed with q
    ;; shuts the preview for that row until the selection changes, and
    ;; that local outlives leaving — so coming back to the row you left
    ;; on showed no preview at all until you moved off it and back
    (buffer-set-local! (chat-list-buffer) 'listing-peek-dismissed-row #f)
    (chat-list-preview!)
    ;; the list stands on its own keys; a filter line only opens when you
    ;; ask for one, by / or by arriving with words already typed
    (if (and (string? standing) (not (equal? standing "")))
        (chat-list-filter-line! standing)
        (chat-list-focus!))))

(define-command "chat-list-filter"
  "Narrow the chat list by a word in a title or in a chat"
  (lambda () (chat-list-filter-line!)))

(define-command "chat-list-visit"
  "Enter the chat at point in its own group; on a heading, open the section"
  (lambda ()
    (let ((row (list-current (chat-list-buffer))))
      (if (ibuffer-heading? row)
          (ibuffer-toggle-fold! (ibuffer-heading-key row) (chat-list-buffer))
          (chat-list-leave! row)))))

(define-command "chat-list-quit"
  "Close the preview, else leave the chat list and change nothing"
  (lambda ()
    ;; q puts away the card first, like every other list: the card floats
    ;; in the list's own window, so dismissing it leaves the list and the
    ;; arrangement as they were. The next q leaves.
    (if (equal? (listing-preview-owner) (chat-list-buffer))
        (listing-peek-dismiss!)
        (chat-list-leave! #f))))

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


(define-command "chat-list-toggle-groups"
  "Turn the chat list's sections on or off; off is the flat list, most recent first"
  (lambda ()
    (let* ((buf (chat-list-buffer))
           (grouping (ibuffer-grouping buf)))
      (if (equal? grouping 'none)
          ;; back to the sections you last had, not to a fixed default
          (let ((back (or (buffer-local buf 'chat-list-grouping-was) 'group)))
            (ibuffer-set-grouping! back buf)
            (message (string-append "grouped by " (symbol->string back))))
          (begin
            (buffer-set-local! buf 'chat-list-grouping-was grouping)
            ;; groups off means the one list you half-remember a name in:
            ;; flat, and the chat you used last at the top of it
            (ibuffer-set-sort! 'recent buf)
            (ibuffer-set-grouping! 'none buf)
            (message "ungrouped — most recent first"))))))

(define-command "chat-list-regroup"
  "Cycle what a section of the chat list is: none, group, state, model"
  (lambda ()
    (let ((next (ibuffer-cycle-after (ibuffer-grouping (chat-list-buffer))
                                     *chat-list-groupings*)))
      (ibuffer-set-grouping! next (chat-list-buffer))
      (message (string-append "grouped by " (symbol->string next))))))

(define-command "chat-list-resort"
  "Cycle the order inside a section: recent, name, size on disk"
  (lambda ()
    (let ((next (ibuffer-cycle-after (ibuffer-sort (chat-list-buffer))
                                     '(recent name size))))
      (ibuffer-set-sort! next (chat-list-buffer))
      (message (string-append "sorted by " (symbol->string next))))))

(category! 'chat)
(catalog-meta! 'command "chat-list" 'domain 'chat 'effects '(write display))
(catalog-meta! 'command "chat-list-filter" 'domain 'chat 'effects '(write display))
(catalog-meta! 'command "chat-list-visit" 'domain 'chat 'effects '(write display))
(catalog-meta! 'command "chat-list-quit" 'domain 'chat 'effects '(write display))
(catalog-meta! 'command "chat-where" 'domain 'chat 'effects '(write display))
(catalog-meta! 'command "chat-finder" 'domain 'chat 'effects '(write display))

(catalog-meta! 'command "chat-list-toggle-groups" 'domain 'chat 'effects '(write display))
(public! 'chat-list-open!
  "(chat-list-open! [SEARCH]) — open the chat list application, with SEARCH standing")
