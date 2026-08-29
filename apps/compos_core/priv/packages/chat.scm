;;;; chat.scm — the conversation of record
;;;;
;;;; What a chat SENT, and everything that reads or rewrites it: the
;;;; record itself, compaction, healing, the tool surface, the usage
;;;; ledger, and the context the direct lane pulls at every turn start.
;;;;
;;;; This is policy, so it is a package. editor.scm supplies the
;;;; mechanism these functions stand on — buffers, buffer-locals,
;;;; commands, the minibuffer — and knows nothing about a turn, a tool
;;;; call, or a token. The rest of chat (the buffer, the backends, .chat
;;;; files, groups) still lives in editor.scm and follows here.
;;;;
;;;; Load order: packages load after the stdlib and alphabetically, so
;;;; agent.scm loads first. Nothing here is called at load time and
;;;; nothing here calls agent.scm at load time — every crossing is a
;;;; runtime one. The two registrations below hand the direct lane its
;;;; context fn and its record fn, and both are primitives.
;;;;
;;;; Desktop restore runs after every package loads, so a restored chat
;;;; finds these definitions in place.

(package! 'chat)
(category! 'chat)
(domain! 'chat)
(effects! '(read))

;;; --- the conversation of record ------------------------------------------------
;;; ONE list per chat, 'chat-wire-turns, newest first. It is what the model
;;; saw, not what the buffer shows. A turn is a plist:
;;;
;;;   (role "user"|"assistant" blocks BLOCKS wire WIRE)
;;;
;;; BLOCKS is a list of
;;;   ("text" STRING)
;;;   ("tool-use" ID NAME INPUT-JSON)
;;;   ("tool-result" ID OUTPUT ERROR?)
;;; WIRE is the exact user text that was sent, present only when it differs
;;; from the display text (the editor context preamble, a seed transcript).
;;;
;;; The api lane replays this list verbatim. Because the record holds the
;;; tool calls and the tool results too, every turn resends the SAME prefix
;;; and the provider's prompt cache hits. Rendered text can never be the
;;; record: it drops the blocks, and no reconstruction of it matches what
;;; was sent.

(define (chat-record buf) (or (buffer-local buf 'chat-wire-turns) '()))

(define (chat-record-push! buf role blocks wire)
  (buffer-set-local! buf 'chat-wire-turns
    (cons (append (list 'role role 'blocks blocks)
                  (if (and (string? wire) (not (equal? wire ""))) (list 'wire wire) '()))
          (chat-record buf))))

;; the display text of a turn: its text blocks, joined. A turn made only of
;; tool calls or tool results has none — it is wire, not conversation.
(define (chat-turn-display t)
  (let loop ((bs (or (plist-get t 'blocks) '())) (acc ""))
    (cond ((null? bs) acc)
          ((equal? (car (car bs)) "text")
           (loop (cdr bs) (string-append acc (car (cdr (car bs))))))
          (else (loop (cdr bs) acc)))))

;; the same view over any record: (role text) pairs in the record's own
;; order. Replay reads parsed .chat records that never lived in a buffer,
;; so this half takes the record itself.
(define (chat-record-turns record)
  (let loop ((ts record) (acc '()))
    (if (null? ts)
        (reverse acc)
        (let ((txt (chat-turn-display (car ts))))
          (loop (cdr ts)
                (if (equal? txt "")
                    acc
                    (cons (list (plist-get (car ts) 'role) txt) acc)))))))

;; the conversation as (role text) pairs, newest first — what every display
;; surface reads: .chat files, the seed transcript, the input history.
(define (chat-turns buf)
  (chat-record-turns (chat-record buf)))

;; a turn that is only prose — every caller with text and no blocks
(define (chat-turn-push! buf role text)
  (chat-record-push! buf role (list (list "text" text)) #f))

;;; --- parallel agent work -------------------------------------------------------
;;; The runtime supplies cheap shared-world Scheme tasks. Chat chooses the
;;; useful policy: fan out at most four jobs, await them in input order, then
;;; move to the next batch. A task can use the normal agent tool path — apropos,
;;; code-read and buffer edits — and each target buffer remains its own serial
;;; authority.

(define (chat--parallel-batch f xs)
  (let* ((tasks (map (lambda (x) (task-spawn (lambda () (f x)))) xs))
         (values (map task-await tasks)))
    (for-each task-cancel! tasks)
    values))

(define (chat-parallel-map f xs)
  (let loop ((remaining xs) (out '()))
    (if (null? remaining)
        out
        (let ((batch (chat-take remaining 4)))
          (loop (chat-drop remaining 4)
                (append out (chat--parallel-batch f batch)))))))

(public! 'chat-parallel-map
  "(chat-parallel-map FN ITEMS) — apply FN in up to four concurrent shared-world Scheme tasks; return results in input order")

;; Backends that do NOT write the record themselves get it from the event
;; stream instead: an ACP adapter runs its turn in a subprocess, and its
;; events are all we see. A stateless backend replays the record, so it
;; writes the record — and recording its events too would double every
;; turn.
(define (chat-record-event! buf role blocks)
  (unless (chat-stateless? buf)
    (chat-record-push! buf role blocks #f)))

;; does this chat's backend hold the conversation, or do we?
(define (chat-stateless? buf)
  (and (boundp (quote connector-can?))
       (connector-can? (or (buffer-local buf 'agent-connector) "api") 'stateless)))

;;; --- compaction ------------------------------------------------------------------
;;; A conversation that never ends grows without bound, and every turn
;;; resends all of it. The head of the record becomes one summary and the
;;; recent turns stay verbatim — the recent turns are what the model is
;;; working on, and they are also what the cache holds.
;;;
;;; You ask for it: M-x chat-compact. It ran by itself until the prompt
;;; cache started working, and then the arithmetic changed. A cached
;;; prefix costs a tenth of a fresh one, so resending a long chat is
;;; cheap, while a compaction pays for the summary AND rewrites the cache.
;;; Below roughly twenty more turns it does not pay for itself, and it
;;; spends real conversation to save a tenth of a cent.
;;;
;;; The reason that remains is the model's input limit: past it every
;;; request fails, and no cache rate helps. That is a wall to see coming,
;;; not a threshold to cross silently. So the editor SUGGESTS compaction,
;;; at a share of what this chat's own model accepts (chat-compact-limit),
;;; and the user decides.
;;;
;;; It is never silent. The transcript shows a line where the head went,
;;; and the summary is a turn like any other: it saves, restores, and
;;; replays with the rest of the record.

;;; (The two knobs are defcustoms in packages/tools.scm — defcustom itself
;;; is userland and loads after this file.)

(define (chat-block-bytes b)
  (fold (lambda (acc v) (+ acc (if (string? v) (string-byte-length v) 0))) 0 b))

(define (chat-turn-bytes t)
  (+ (fold (lambda (acc b) (+ acc (chat-block-bytes b))) 0 (or (plist-get t 'blocks) '()))
     (string-byte-length (or (plist-get t 'wire) ""))))

;; four bytes to the token: close enough to decide WHEN, and no tokenizer
;; in the editor can be closer than the provider's own count
(define (chat-record-tokens buf)
  (quotient (fold (lambda (acc t) (+ acc (chat-turn-bytes t))) 0 (chat-record buf)) 4))

;; A turn the kept window can open on: a message the user wrote. The
;; results of a tool round carry the "user" role too, and a window that
;; opened on one of those cut the round in half — the results stayed, and
;; the call that made them went into the summary. The provider rejects
;; that request: "no tool call found for function call output".
(define (chat-user-message-turn? t)
  (and (equal? (plist-get t 'role) "user")
       (not (equal? (chat-turn-display t) ""))))

;; how many of the newest turns to keep: at least chat-compact-keep, then
;; on to the next user message, so the kept window opens the way a
;; conversation does rather than mid-exchange
(define (chat-compact-keep-count all)
  (let loop ((ts all) (n 0))
    (cond ((null? ts) n)
          ((and (>= n chat-compact-keep)
                (chat-user-message-turn? (car ts)))
           (+ n 1))
          (else (loop (cdr ts) (+ n 1))))))

(define (chat-take xs n)
  (if (or (null? xs) (<= n 0)) '() (cons (car xs) (chat-take (cdr xs) (- n 1)))))

(define (chat-drop xs n)
  (if (or (null? xs) (<= n 0)) xs (chat-drop (cdr xs) (- n 1))))

;; record turns (oldest first) as the portable transcript the summarizer reads
(define (chat-turns-text turns)
  (fold (lambda (acc t)
          (let ((txt (chat-turn-display t)))
            (if (equal? txt "")
                acc
                (string-append acc
                  (if (equal? (plist-get t 'role) "user") "### You\n" "### Assistant\n")
                  txt "\n\n"))))
        "" turns))

;; is there a head to summarize at all? A chat shorter than its own keep
;; window has nothing to compact, and neither has one already compacting.
(define (chat-can-compact? buf)
  (and (not (buffer-local buf 'chat-compacting))
       (let ((all (chat-record buf)))
         (> (length all) (chat-compact-keep-count all)))))

;; the model this chat sends to — its own, or the editor's default
(define (chat-model buf)
  (or (buffer-local buf 'agent-model) (llm-model)))

;; The record size at which the editor mentions compaction, or #f when it
;; stays quiet. A flat count set by the user wins. Otherwise it is a share
;; of what THIS chat's model accepts, because that limit is the only hard
;; one: a model whose catalog entry we cannot read gets no suggestion,
;; which is honest — we do not know where its wall is.
(define (chat-compact-limit buf)
  (cond ((> chat-compact-threshold 0) chat-compact-threshold)
        ((<= chat-compact-percent 0) #f)
        (else
         (let ((limit (llm-context-limit (chat-model buf))))
           (and limit (quotient (* limit chat-compact-percent) 100))))))

;; big enough that the editor mentions it — a suggestion, not a trigger
(define (chat-should-compact? buf)
  (let ((limit (chat-compact-limit buf)))
    (and limit
         (> (chat-record-tokens buf) limit)
         (chat-can-compact? buf))))

;; The summary call is async, and the record can grow while it is in
;; flight. So the head is identified by COUNT at request time and replaced
;; only if the record still ends with it: a turn that landed meanwhile
;; stays put, and a reset that emptied the record cancels the whole thing.
(define (chat-compact! buf slug)
  (let* ((all (chat-record buf))
         (keep (chat-compact-keep-count all))
         (head (chat-drop all keep))
         (n (length head)))
    (buffer-set-local! buf 'chat-compacting n)
    (llm (string-append
           "Summarize this conversation between a user and the assistant "
           "inside their editor. Keep every decision, file name, command, "
           "and open question. Drop the pleasantries. Write notes the "
           "assistant can act on, not prose about the conversation. No "
           "preamble.\n\n"
           (chat-turns-text (reverse head)))
         (lambda (summary) (chat-compact-apply! buf slug n summary)))))

(define (chat-compact-apply! buf slug n summary)
  (buffer-set-local! buf 'chat-compacting #f)
  (let ((all (chat-record buf)))
    (when (and (buffer-exists? buf) (> (length all) n))
      (buffer-set-local! buf 'chat-wire-turns
        (append (chat-take all (- (length all) n))
                (list (list 'role "user"
                            'blocks (list (list "text"
                              (string-append
                                "[Earlier in this conversation, compacted to notes:]\n\n"
                                summary)))))))
      ;; say so where the reader can see it. A restored chat can have a
      ;; record and no runtime, and agent-render! is keyed by slug: with
      ;; no slug there is no transcript to write the line into, and the
      ;; echo area carries the whole news.
      (when slug
        (let ((start (agent-render! slug
                       (string-append "\n[compacted " (number->string n)
                                      " earlier turns into a summary]\n")
                       "agent-meta")))
          (agent-block-push! buf start (agent-mark slug) "meta" '())))
      (message (string-append "compacted " (number->string n) " turns")))))

(define-command "chat-compact" "Summarize this chat's older turns, keeping the recent ones"
  (lambda ()
    (let ((buf (current-buffer)))
      (cond ((not (or (chat-buffer? buf) (buffer-local buf 'agent-saved-mark)))
             (message "not a chat buffer"))
            ((buffer-local buf 'chat-compacting)
             (message "a compaction is already in flight"))
            ((not (chat-can-compact? buf))
             (message (string-append "nothing to compact: this chat is "
                                     (number->string (length (chat-record buf)))
                                     " turns, and it keeps the last "
                                     (number->string
                                       (chat-compact-keep-count (chat-record buf))))))
            (else
             (let* ((all (chat-record buf))
                    (n (- (length all) (chat-compact-keep-count all))))
               (chat-compact! buf (buffer-local buf 'agent-slug))
               (message (string-append "compacting " (number->string n)
                                       " earlier turns…"))))))))

;; a chat saved before the record existed carries (role text) pairs — read
;; them once, as text turns, and drop the old local
(define (chat-record-migrate! buf)
  (let ((old (buffer-local buf 'chat-turns)))
    (when (and old (null? (chat-record buf)))
      (buffer-set-local! buf 'chat-wire-turns
        (map (lambda (t) (list 'role (car t) 'blocks (list (list "text" (car (cdr t))))))
             old))
      (buffer-set-local! buf 'chat-turns #f))))

;;; --- healing the record ----------------------------------------------------------
;;; A tool call and its result are one unit on the wire. The provider
;;; rejects a result whose call it cannot see, and it rejects a call whose
;;; result never came. The record can lose one half: compaction can cut
;;; between the two turns, an aborted turn stops after the call, and an
;;; old .chat file can carry either shape.
;;;
;;; One 400 then wedges the whole chat, because every later turn replays
;;; the same broken prefix. So the record heals itself before each send,
;;; and M-x chat-heal is the manual door. Healing drops blocks; it never
;;; invents a result the tool did not return.

;; every tool-result id in the record
(define (chat-result-ids turns)
  (fold (lambda (acc t)
          (fold (lambda (acc b)
                  (if (equal? (car b) "tool-result") (cons (car (cdr b)) acc) acc))
                acc
                (or (plist-get t 'blocks) '())))
        '() turns))

;; a turn with new blocks, keeping its role and its wire text
(define (chat-turn-with-blocks t blocks)
  (append (list 'role (plist-get t 'role) 'blocks blocks)
          (let ((w (plist-get t 'wire)))
            (if (and (string? w) (not (equal? w ""))) (list 'wire w) '()))))

;; One pass, oldest first. `seen` grows with every tool-use we keep, so a
;; tool-result survives only when its call is still in the record before
;; it. `results` holds every result id, so a tool-use with no result goes.
;; Returns (TURNS DROPPED) with TURNS oldest first.
(define (chat-heal-turns turns results)
  (let loop ((ts turns) (seen '()) (acc '()) (dropped 0))
    (if (null? ts)
        (list (reverse acc) dropped)
        (let ((t (car ts)))
          (let bloop ((bs (or (plist-get t 'blocks) '()))
                      (seen seen)
                      (kept '())
                      (dropped dropped))
            (if (null? bs)
                (loop (cdr ts) seen
                      (if (null? kept) acc (cons (chat-turn-with-blocks t (reverse kept)) acc))
                      dropped)
                (let* ((b (car bs))
                       (kind (car b))
                       (id (if (null? (cdr b)) #f (car (cdr b)))))
                  (cond ((equal? kind "tool-use")
                         (if (member id results)
                             (bloop (cdr bs) (cons id seen) (cons b kept) dropped)
                             (bloop (cdr bs) seen kept (+ dropped 1))))
                        ((equal? kind "tool-result")
                         (if (member id seen)
                             (bloop (cdr bs) seen (cons b kept) dropped)
                             (bloop (cdr bs) seen kept (+ dropped 1))))
                        (else (bloop (cdr bs) seen (cons b kept) dropped))))))))))

;; repair the record in place. Returns the number of blocks it dropped,
;; and writes nothing when the record is already whole — an untouched
;; local keeps the buffer clean of a no-op change.
(define (chat-heal! buf)
  (let* ((turns (reverse (chat-record buf)))
         (r (chat-heal-turns turns (chat-result-ids turns)))
         (dropped (car (cdr r))))
    (when (> dropped 0)
      (buffer-set-local! buf 'chat-wire-turns (reverse (car r))))
    dropped))

(define-command "chat-heal" "Repair this chat's record: drop tool calls and results that lost their other half"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (not (or (chat-buffer? buf) (buffer-local buf 'agent-saved-mark)))
          (message "not a chat buffer")
          (let ((n (chat-heal! buf)))
            (message (if (= n 0)
                         "this chat's record is whole"
                         (string-append "healed this chat: dropped "
                                        (number->string n) " orphaned tool "
                                        (if (= n 1) "block" "blocks")))))))))

(define (chat-clear-waiting! buf)
  (let ((w (buffer-local buf 'chat-waiting)))
    (when w
      (let* ((start (car w))
             (end (car (cdr w)))
             (size (buffer-size buf))
             ;; Positions are runtime state and may be stale after edits or
             ;; an interrupted legacy turn. Delete only the exact chrome we
             ;; put there; never trust the range enough to delete prose.
             (valid? (and (>= start 0) (>= end start) (<= end size)
                          (equal? (substring-bytes (buffer-text buf) start end)
                                  "⋯ thinking\n"))))
        (when valid?
          (buffer-delete-range! buf start (- end start))
          (buffer-set-local! buf 'agent-saved-mark
            (- (chat-mark buf) (- end start)))))
      (chat-blocks-drop! buf "waiting")
      (buffer-set-local! buf 'chat-waiting #f))))

;; presets (packages/mcp.scm) add MCP tool specs per chat; usage lands in
;; buffer-locals so every chat knows what it cost (persists with the chat)
(define (chat-extra-specs buf)
  (if (boundp (quote chat-extra-tool-specs))
      (chat-extra-tool-specs buf)
      '()))

;;; The tool list is part of the cache prefix, so a chat freezes it at its
;;; first send. An MCP server finishing its handshake mid-conversation used
;;; to change the list under a running chat, and every cached token went
;;; with it. The frozen list is conversation state: it survives a restart,
;;; and a reset starts a new one.
;;;
;;; C-c t adopts the live set. That costs exactly one cache miss, and it is
;;; the user's choice to spend — the modeline says when the two differ.

(define (chat-live-tool-specs buf)
  (chat-extra-specs buf))

;;; An EMPTY surface is not a freeze. A preset's MCP server answers
;;; nothing while it still handshakes, and the first send can arrive in
;;; that window. Freezing that answer gave the chat no tools for the rest
;;; of its life, silently — the model then says it cannot search the web,
;;; and every later turn agrees with it. An empty list is also nothing to
;;; protect: there is no tool prefix in the cache to lose. So the chat
;;; keeps asking until the surface has at least one tool, and freezes
;;; that. ('() is truthy in this dialect, so the test is `pair?`.)

(define (chat-tools buf)
  (let ((frozen (buffer-local buf 'chat-tool-specs)))
    (if (pair? frozen)
        frozen
        (let ((specs (chat-live-tool-specs buf)))
          (when (pair? specs)
            (buffer-set-local! buf 'chat-tool-specs specs))
          specs))))

(define (chat-tool-names specs) (map car specs))

;; has the editor's tool surface moved since this chat froze its own?
(define (chat-tools-stale? buf)
  (let ((frozen (buffer-local buf 'chat-tool-specs)))
    (and (pair? frozen)
         (not (equal? (chat-tool-names frozen)
                      (chat-tool-names (chat-live-tool-specs buf))))
         #t)))

;; Adopt the live surface without UI. Preset commands use this too: choosing
;; a different surface is already an explicit choice to invalidate the prompt
;; cache, so leaving an API chat on its old frozen list makes the command a
;; silent no-op until the user discovers C-c t.
(define (chat-adopt-live-tools! buf)
  (let ((specs (chat-live-tool-specs buf)))
    (buffer-set-local! buf 'chat-tool-specs specs)
    (when (boundp (quote agent-update-modeline!)) (agent-update-modeline! buf))
    (length specs)))

(define-command "chat-refresh-tools" "Adopt the editor's current tool list in this chat"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (not (buffer-local buf 'agent-saved-mark))
          (message "not a chat buffer")
          (let ((n (chat-adopt-live-tools! buf)))
            (message (string-append "tools refreshed: " (number->string n)
                                    " — the next turn rewrites the prompt cache")))))))

;; the chat's running totals, so C-c $ can state a hit rate over the whole
;; conversation rather than the last turn alone
(define (chat-usage-total buf)
  (or (buffer-local buf 'chat-usage-total)
      '(input 0 output 0 cache-read 0 cache-write 0)))

(define (chat-usage-add total u key)
  (+ (or (plist-get total key) 0) (or (custom--plist-get u key) 0)))

(define (chat-usage-note! buf u)
  (let ((cost (custom--plist-get u 'cost))
        (total (chat-usage-total buf)))
    (buffer-set-local! buf 'chat-last-usage u)
    (buffer-set-local! buf 'chat-usage-total
      (list 'input (chat-usage-add total u 'input)
            'output (chat-usage-add total u 'output)
            'cache-read (chat-usage-add total u 'cache-read)
            'cache-write (chat-usage-add total u 'cache-write)))
    (when cost
      (buffer-set-local! buf 'chat-cost
        (+ (or (buffer-local buf 'chat-cost) 0) cost)))
    ;; every turn, priced or not: the modeline also carries the tool-drift
    ;; hint, and an unpriced model must not hide it
    (agent-update-modeline! buf)))

;; the share of billed input that came from the cache, as a percentage
;; string, or #f when nothing was billed yet
(define (chat-hit-rate total)
  (let ((read (or (plist-get total 'cache-read) 0))
        (fresh (or (plist-get total 'input) 0)))
    (if (= (+ read fresh) 0)
        #f
        (string-append
          (number->string (quotient (* 100 read) (+ read fresh))) "%"))))

;;; --- the direct lane's turn context ---------------------------------------------
;;; Backend.ReqLLM pulls this fresh at every turn start: the transcript
;;; truth (the record), the per-send system preamble (group pull-context
;;; can never go stale), and the chat's tool surface (registry + presets).

;; the tool dispatcher the direct lane hands the loop — per slug, so every
;; buffer edit a tool call makes is attributed to the thread (see
;; buffer-authors). Each closure is kept in this global alist because the
;; backend's turn task holds it OUTSIDE the store: a frame only reachable
;; from Elixir is one the interpreter's GC collects mid-turn.
(define *chat-dispatchers* '())

(define (chat-tool-dispatch slug)
  (let ((e (assoc slug *chat-dispatchers*)))
    (if e
        (car (cdr e))
        (let ((d (lambda (name args)
                   (let ((buf (agent-buf slug)))
                     (if (and buf (buffer-exists? buf))
                         (with-current-buffer buf
                           (lambda ()
                             (with-edit-author (string-append "agent:" slug)
                               (lambda () (llm-tool-call name args)))))
                         (with-edit-author (string-append "agent:" slug)
                           (lambda () (llm-tool-call name args))))))))
          (set! *chat-dispatchers* (cons (list slug d) *chat-dispatchers*))
          d))))

;; the mcp package loads after this file, and a user can unload it. The
;; note names the servers THIS chat holds, never the whole registry.
(define (chat-mcp-note buf)
  (if (and (boundp (quote mcp-system-note)) (boundp (quote chat-active-servers)))
      (let ((note (mcp-system-note (chat-active-servers buf))))
        (if (equal? note "") "" (string-append note "\n\n")))
      ""))

;; The record, oldest first, exactly as it was sent. The backend appends
;; the new user message itself and records it in the same breath, so there
;; is no in-flight turn to strip here: `display` is now unused, and the
;; dedup hack it used to need is gone with it.
;; Prompt composition is data before it is text.  A named fragment makes
;; ordering, duplication and cache stability inspectable without parsing the
;; final prose.  mcp.scm loads after this package and supplies the tool-side
;; fragments when it is present.
(define (chat-context &optional buf)
  (let* ((chat (or buf (current-buffer)))
         (group (buffer-group chat))
         (members (if group (group-buffers group) '()))
         (companions (if group (group-docs group) '())))
    (list
      'chat chat
      'agent (or (buffer-local chat 'agent-slug) #f)
      'connector (or (buffer-local chat 'agent-connector) "api")
      'model (or (buffer-local chat 'agent-model) (llm-model))
      'group (or group #f)
      'group-name (if group (group-display-name group) #f)
      'group-members members
      'companions companions
      'roles (if group
                 (map (lambda (name)
                        (list name (or (buffer-group-role name group) #f)))
                      companions)
                 '())
      'directory (or (buffer-local chat 'default-directory) (default-directory))
      'visible-context (editor-context chat)
      'prompt (if (and (boundp (quote chat-prompt-frozen?))
                       (chat-prompt-frozen? chat))
                  'frozen
                  'prospective))))

(define (chat-live-system-prompt-parts buf &optional tools?)
  (append
    (if (and tools?
             (boundp (quote chat-tool-system-parts)))
        (chat-tool-system-parts buf)
        '())
    (list (list "chat-preamble" (chat-preamble buf)))))

(define (chat-system-prompt-parts buf &optional tools?)
  (let ((live (chat-live-system-prompt-parts buf tools?)))
    (if (boundp (quote chat-prompt-snapshot-parts))
        (chat-prompt-snapshot-parts buf 'direct live)
        live)))

(define (chat-thread-context slug display)
  (let* ((buf (agent-buf slug))
         (healed (chat-heal! buf))
         (tools? (and (boundp (quote chat-use-tools)) chat-use-tools)))
    (unless (= healed 0)
      (message (string-append "healed this chat: dropped " (number->string healed)
                              " orphaned tool " (if (= healed 1) "block" "blocks"))))
    (list 'turns (reverse (chat-record buf))
          'system (prompt-parts-text (chat-system-prompt-parts buf tools?))
          'tools (if tools? (chat-tools buf) '())
          'dispatcher (chat-tool-dispatch slug))))

(domain! 'chat)
(effects! '(read))
(public! 'chat-context
  "(chat-context [BUF]) — chat identity, group, companions, workspace, visible context, and prompt state")
(public! 'chat-live-system-prompt-parts
  "(chat-live-system-prompt-parts BUF [TOOLS?]) — current direct prompt fragments before the conversation freeze")
(effects! '(write))
(public! 'chat-system-prompt-parts
  "(chat-system-prompt-parts BUF [TOOLS?]) — named system-prompt fragments in their exact send order")

(llm-session-context-fn! (lambda (slug display) (chat-thread-context slug display)))

;; ...and the other half of that seam: the turn task appends to the record
;; every message it puts on the wire, synchronously, in the order it sends
;; them. Reading and writing from one process is what makes the replayed
;; prefix byte-identical.
(llm-session-record-fn!
  (lambda (slug role blocks wire)
    (let ((buf (agent-buf slug)))
      (when (buffer-exists? buf)
        (chat-record-push! buf role blocks wire))
      #t)))

(define-command "chat-toggle-view" "Toggle between rich and plain chat transcript"
  (lambda ()
    (let* ((buf (current-buffer))
           (rich? (equal? (buffer-local buf 'render-mode) "agent")))
      ;; "plain", not #f: the chosen view is identity (S11), and a cleared
      ;; local reads as "never chosen" — which the setup would re-default
      (buffer-set-local! buf 'render-mode (if rich? "plain" "agent"))
      (message (if rich? "plain transcript" "rich transcript")))))

;;; (chat auto-titling died with the bare *chat* surface: a group chat is
;;; named for its group, and there is only one chat interface)

;; Models offered by C-c m / M-x chat-set-model — the seed "favorites" list.
;; ReqLLM's credential-aware inventory (llm-available-models) fills the rest,
;; so a provider with its key set appears here with no code change. Override
;; the favorites in ~/.compos/ai-config.scm:
;;   (set! *llm-models* (list "openai:gpt-5.6-luna" "deepseek:deepseek-chat" ...))
(define *llm-models*
  (list "openai:gpt-5.6-luna"
        "openrouter:anthropic/claude-sonnet-5"
        "claude-sonnet-5"
        "claude-opus-5"
        "claude-haiku-4-5-20251001"))

;; the same switch, keeping the connector: in place when the running
;; backend can take the model, a seeded fresh session otherwise
(define-command "chat-set-model" "Choose this chat's model"
  (lambda ()
    (let* ((buf (current-buffer))
           (slug (buffer-local buf 'agent-slug))
           (cname (or (buffer-local buf 'agent-connector) "api")))
      (if (not (or slug (buffer-local buf 'agent-saved-mark)))
          (message "not a chat buffer")
          (minibuffer-read
            (string-append "Model (now "
                           (or (buffer-local buf 'agent-model)
                               (if (connector-can? cname 'stateless)
                                   (llm-model)
                                   "connector default"))
                           "): ")
            (chat-model-options buf cname)
            (lambda (m)
              (unless (equal? (string-trim m) "")
                (if slug
                    (message
                      (string-append cname " · " m
                        (if (equal? (chat-switch! buf #f m) 'in-place)
                            " — switched in place"
                            " — fresh session, the chat carries over")))
                    ;; no runtime yet: the model is just an identity local
                    (begin
                      (buffer-set-local! buf 'agent-model m)
                      (agent-update-modeline! buf)
                      (message (string-append cname " · " m))))
                (when (boundp (quote workspace-llm-defaults-note!))
                  (workspace-llm-defaults-note! buf)))))))))

;; send the region to the chat buffer as context, then open it
(define-command "chat-send-region" "Add the region to the chat buffer as context"
  (lambda ()
    (let ((text (region-text)))
      (if (equal? text "")
          (message "No region")
          (begin
            (run-command "chat")
            (insert! (string-append "```\n" text "\n```\n"))
            (message "Region added to chat"))))))

;;; --- the conversation is named for its group ------------------------------------
;;; A chat's name is DERIVED, never invented: *chat:<group>*, and a group
;;; founded on one buffer carries that buffer's name. So a chat reads as the
;;; work it accompanies, and it follows that work when the name moves.
;;; groups.scm owns the derivation (group-chat-name) and the re-derive
;;; (group-chat-rederive!).
;;;
;;; A small model used to read the recent turns and title the chat. That is
;;; gone: it cost a call every third turn, it made the name drift away from
;;; the buffer it accompanies, and a stale title stranded every store that
;;; named the chat.
;;;
;;; M-x buffer-rename still works on a chat and the name sticks: a name the
;;; person typed is not derived, so no re-derive replaces it.

(domain! 'chat)
(effects! '(read))

(defgroup 'chat "Chats: the conversation of record.")

;; What counts as a turn on this surface: the chat lane records the user's
;; messages, and llm-mode's M-o records one response range per send. One
;; number, so one count covers every chat surface.
(define (chat-turn-count buf)
  (let ((record (chat-record buf)))
    (if (pair? record)
        (length (filter (lambda (t) (equal? (plist-get t 'role) "user")) record))
        (length (or (buffer-local buf 'llm-responses) '())))))

(category! 'chat)
(public! 'chat-turn-count
  "(chat-turn-count BUF) — how many user turns a chat surface holds")

;;; --- the chat log: every conversation, saved -------------------------------------
;;; Every chat writes itself to <compos-home>/chats/<id>.chat when a turn
;;; ends. The file is the same .chat format that C-x C-s writes, so it
;;; opens in the editor, revives, and feeds the acceptance replay below.
;;; One conversation is one file: 'chat-log-id is a conversation local,
;;; so a reset keeps the old file as an archive and the next turn starts
;;; a new file. agent.scm calls chat-log-save! on turn-end and on error.

(domain! 'chat)
(effects! '(write))

(define (chat-log-dir) (string-append (compos-home) "/chats"))

(define (chat-log-files)
  (if (not (file-exists? (chat-log-dir)))
      '()
      (map (lambda (name) (string-append (chat-log-dir) "/" name))
           (filter (lambda (name) (string-suffix? ".chat" name))
                   (list-dir (chat-log-dir))))))

(effects! '(read))
(public! 'chat-log-files
  "(chat-log-files) — every archived conversation as a .chat path")

;; Reset deliberately forgets 'chat-log-id, so recovery cannot depend on the
;; current buffer remembering which conversation came before it.  Present the
;; local archive newest first instead; the timestamped basenames are unique and
;; concise enough for completion, while the callback resolves the full path.
(define (chat-log-files-newest)
  (map cadr
    (sort
      (map (lambda (path) (list (- 0 (file-mtime path)) path))
           (chat-log-files)))))

(define (chat-log-leaf path)
  (cadr (path-split path)))

(define (chat-log-path-by-leaf leaf paths)
  (let ((matches
          (filter (lambda (path) (equal? (chat-log-leaf path) leaf)) paths)))
    (and (pair? matches) (car matches))))

(define-command "chat-restore" "Restore a locally archived conversation"
  (lambda ()
    (let ((paths (chat-log-files-newest))
          (g (frame-group)))
      (if (null? paths)
          (message "No archived chats")
          (minibuffer-read* "Restore chat: " (map chat-log-leaf paths)
            (list
              (list 'confirm
                (lambda (leaf)
                  (let ((path (chat-log-path-by-leaf leaf paths)))
                    (if path
                        (visit-in-group path g)
                        (message "No such archived chat")))))))))))

;; a group title becomes a file name: keep word characters, dot and dash
(define (chat-log-name g)
  (let loop ((s g))
    (let ((r (re-replace "[^A-Za-z0-9._-]" s "-")))
      (if (equal? r s) s (loop r)))))

;; this conversation's id, assigned on first save. The time prefix sorts
;; the directory by age; the suffix loop keeps two same-second chats with
;; the same title in two files.
(define (chat-log-id! buf)
  (or (buffer-local buf 'chat-log-id)
      (let ((base (string-append
                    (number->string (current-time)) "-"
                    (chat-log-name (or (buffer-group buf)
                                       (buffer-local buf 'agent-slug)
                                       "chat")))))
        (let loop ((n 0))
          (let ((id (if (= n 0)
                        base
                        (string-append base "-" (number->string n)))))
            (if (file-exists? (string-append (chat-log-dir) "/" id ".chat"))
                (loop (+ n 1))
                (begin (buffer-set-local! buf 'chat-log-id id) id)))))))

(public! 'chat-log-path
  "(chat-log-path BUF) — the file this conversation logs itself to")
(define (chat-log-path buf)
  (string-append (chat-log-dir) "/" (chat-log-id! buf) ".chat"))

(public! 'chat-log-save!
  "(chat-log-save! BUF) — write this conversation to <compos-home>/chats as a .chat file")
(define (chat-log-save! buf)
  (let ((text (chat-file-text buf)))
    (when text
      (write-file! (chat-log-path buf) text))))

;;; --- replay: a saved chat drives the editor again --------------------------------
;;; A .chat file becomes a scripted stub session: the user turns are the
;;; prompts, and everything the assistant did after each prompt is one
;;; stub turn — chunks, tool calls, tool results. The acceptance tests
;;; send the prompts through the real key path and compare the surface
;;; and the rebuilt record with the file. A chat that does not replay
;;; names the affordance the editor is missing.

(effects! '(pure))

;; one recorded block -> stub events, newest first onto ACC
(define (chat-replay-block-events b acc)
  (let ((kind (car b)))
    (cond
      ((equal? kind "text")
       (cons (list 'type 'chunk 'text (car (cdr b))) acc))
      ;; ("tool-use" ID NAME INPUT-JSON) -> a running tool card
      ((equal? kind "tool-use")
       (cons (list 'type 'tool-call
                   'id (car (cdr b))
                   'name (car (cdr (cdr b)))
                   'input (if (pair? (cdr (cdr (cdr b))))
                              (or (car (cdr (cdr (cdr b)))) "")
                              "")
                   'kind "tool" 'status "pending")
             acc))
      ;; ("tool-result" ID OUTPUT ERROR?) -> the card completes
      ((equal? kind "tool-result")
       (cons (list 'type 'tool-update
                   'id (car (cdr b))
                   'status (if (and (pair? (cdr (cdr (cdr b))))
                                    (car (cdr (cdr (cdr b)))))
                               "failed" "completed")
                   'output (if (pair? (cdr (cdr b)))
                               (or (car (cdr (cdr b))) "")
                               ""))
             acc))
      (else acc))))

;; RECORD (oldest first) -> (prompts (P ...) script (EVENTS ...)), aligned:
;; script turn N plays when prompt N is sent. Tool results ride user-role
;; turns on the wire, so they land in the stub turn that is open, not in a
;; new prompt. Assistant content before the first prompt (a seed
;; transcript) does not replay.
(define (chat-replay-plan record)
  (let loop ((ts record) (prompts '()) (script '()) (cur '()) (open #f))
    (if (null? ts)
        (list 'prompts (reverse prompts)
              'script (reverse (if open (cons (reverse cur) script) script)))
        (let* ((t (car ts))
               (role (plist-get t 'role))
               (blocks (or (plist-get t 'blocks) '())))
          (cond
            ((equal? role "user")
             (let ((cur1 (if open
                             (fold (lambda (acc b)
                                     (if (equal? (car b) "tool-result")
                                         (chat-replay-block-events b acc)
                                         acc))
                                   cur blocks)
                             cur))
                   (text (chat-turn-display t)))
               (if (equal? text "")
                   (loop (cdr ts) prompts script cur1 open)
                   (loop (cdr ts)
                         (cons text prompts)
                         (if open (cons (reverse cur1) script) script)
                         '()
                         #t))))
            ((equal? role "assistant")
             (loop (cdr ts) prompts script
                   (if open
                       (fold (lambda (acc b) (chat-replay-block-events b acc))
                             cur blocks)
                       cur)
                   open))
            (else (loop (cdr ts) prompts script cur open)))))))

(effects! '(read))

;; PATH -> the replay plan plus the expected conversation, or #f when the
;; file does not read. A v1 file (or a hand-written one) has only the
;; transcript: its turns replay as plain text turns.
(define (chat-replay-file path)
  (let ((text (read-file path)))
    (and text
         (let* ((nl (string-index text "\n"))
                (line (if nl (substring-bytes text 0 nl) text))
                (header (chat-parse-header line))
                (recorded (chat-file-record text))
                (record
                  (or recorded
                      (map (lambda (t)
                             (list 'role (car t)
                                   'blocks (list (list "text" (car (cdr t))))))
                           (chat-parse-transcript
                             (substring-bytes text (or nl 0)
                               (or (chat-file-record-at text)
                                   (string-byte-length text))))))))
           (append (chat-replay-plan record)
                   (list 'turns (chat-record-turns record)
                         'record record
                         'header (or header '())))))))

(define (chat-log-read path)
  (let ((plan (chat-replay-file path)))
    (and plan
         (list 'path path
               'header (plist-get plan 'header)
               'prompts (plist-get plan 'prompts)
               'turns (plist-get plan 'turns)
               'record (plist-get plan 'record)))))

(effects! '(read))
(public! 'chat-log-read
  "(chat-log-read PATH) — an archived chat as path, header, prompts, display turns, and full record")

(effects! '(write))
(public! 'chat-replay-start!
  "(chat-replay-start! PATH) — replay a saved .chat on a scripted stub backend; sends the first prompt and returns (slug S prompts ALL turns EXPECTED)")

(define (chat-replay-start! path)
  (let ((plan (chat-replay-file path)))
    (cond
      ((not plan) (error "chat-replay: cannot read" path))
      ((null? (plist-get plan 'prompts))
       (error "chat-replay: no user turns in" path))
      (else
        (let* ((prompts (plist-get plan 'prompts))
               (slug (execute* (car prompts)
                       (list 'backend "stub"
                             'script (plist-get plan 'script)))))
          (list 'slug slug
                'prompts prompts
                'turns (plist-get plan 'turns)))))))
