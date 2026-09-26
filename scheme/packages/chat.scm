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

(define (chat-conversation-turn? turn)
  (and (member (plist-get turn 'role) (list "user" "assistant")) #t))

(define (chat-model-record buf)
  (filter chat-conversation-turn? (chat-record buf)))

(define (chat-drop-oldest-conversation-turns record n)
  (reverse
    (let loop ((turns (reverse record)) (left n) (kept '()))
      (cond ((null? turns) (reverse kept))
            ((and (> left 0) (chat-conversation-turn? (car turns)))
             (loop (cdr turns) (- left 1) kept))
            (else (loop (cdr turns) left (cons (car turns) kept)))))))

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
  (quotient (fold (lambda (acc t) (+ acc (chat-turn-bytes t))) 0 (chat-model-record buf)) 4))

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
          (let ((txt (chat-turn-display t))
                (role (plist-get t 'role)))
            (if (equal? txt "")
                acc
                (string-append acc
                  (cond ((equal? role "user") "### You\n")
                        ((equal? role "status") "### Status\n")
                        (else "### Assistant\n"))
                  txt "\n\n"))))
        "" turns))

(define (chat-model-flatten buf)
  (and (buffer-local buf 'agent-saved-mark)
       (pair? (chat-model-record buf))
       (let loop ((turns (reverse (chat-record-turns (chat-model-record buf))))
                  (text ""))
         (if (null? turns)
             (string-append text (chat-prompt-marker))
             (loop (cdr turns)
                   (string-append text
                     (if (equal? (car (car turns)) "user")
                         (chat-prompt-marker)
                         (chat-reply-marker))
                     (cadr (car turns)) "\n"))))))

;; is there a head to summarize at all? A chat shorter than its own keep
;; window has nothing to compact, and neither has one already compacting.
(define (chat-can-compact? buf)
  (and (not (buffer-local buf 'chat-compacting))
       (let ((all (chat-model-record buf)))
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
  (let* ((all (chat-model-record buf))
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
    (when (and (buffer-exists? buf) (> (length (chat-model-record buf)) n))
      (buffer-set-local! buf 'chat-wire-turns
        (append (chat-drop-oldest-conversation-turns all n)
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
                                     (number->string (length (chat-model-record buf)))
                                     " turns, and it keeps the last "
                                     (number->string
                                       (chat-compact-keep-count (chat-model-record buf))))))
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
  (+ (or (plist-get total key) 0) (or (plist-get u key) 0)))

(define (chat-usage-note! buf u)
  (let ((cost (plist-get u 'cost))
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

;; What the conversation occupies right now: tokens held, and the window
;; they are held in. The backend reports this as the turn runs, so it is a
;; count and not an estimate over the transcript. It is a snapshot, so the
;; latest one replaces the last; only chat-usage-total adds up.
(define (chat-context-note! buf used size)
  (when (and (number? used) (> used 0))
    (buffer-set-local! buf 'chat-context-used used)
    (when (and (number? size) (> size 0))
      (buffer-set-local! buf 'chat-context-size size))
    (agent-update-modeline! buf)))

;; 247773 of 1000000 reads as 248k/1M. The modeline has room for the shape
;; of the answer, not for its digits.
(define (chat-tokens-short n)
  (cond ((>= n 1000000)
         (let ((m (quotient n 1000000))
               (frac (quotient (remainder n 1000000) 100000)))
           (if (= frac 0)
               (string-append (number->string m) "M")
               (string-append (number->string m) "." (number->string frac) "M"))))
        ((>= n 1000)
         (string-append (number->string (quotient (+ n 500) 1000)) "k"))
        (else (number->string n))))

;; what the modeline says: how full this conversation is
(define (chat-context-label buf)
  (let ((ctx (chat-context-tokens buf)))
    (and ctx
         (let ((used (plist-get ctx 'used))
               (size (plist-get ctx 'size)))
           (string-append (chat-tokens-short used)
                          (if size (string-append "/" (chat-tokens-short size)) ""))))))

;; (used U size S), or #f when no backend has reported one
(define (chat-context-tokens buf)
  (let ((used (buffer-local buf 'chat-context-used)))
    (and (number? used)
         (list 'used used 'size (buffer-local buf 'chat-context-size)))))

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
                   (let* ((buf (agent-buf slug))
                          (author (string-append "agent:" slug))
                          ;; the tool call IS this author's burst, so its end
                          ;; is where what it wrote reaches disk, and jj
                          (call (lambda ()
                                  (if (boundp (quote jj-with-burst))
                                      (jj-with-burst author
                                        (lambda () (llm-tool-call name args)))
                                      (llm-tool-call name args)))))
                     ;; this lane sends tool results as text
                     (tool-result-text
                       (if (and buf (buffer-exists? buf))
                           (with-current-buffer buf
                             (lambda () (with-edit-author author call)))
                           (with-edit-author author call)))))))
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
         ;; This is the agent's full ambient context, including quiet buffers.
         ;; User-facing lists apply buffer-context-only? at their own boundary.
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
      'companion-tab (if (boundp (quote companion-tab)) (companion-tab chat) #f)
      'prompt (if (and (boundp (quote chat-prompt-frozen?))
                       (chat-prompt-frozen? chat))
                  'frozen
                  'prospective))))

(define (chat-live-system-prompt-source-parts buf &optional tools?)
  (append
    (if (and tools?
             (boundp (quote chat-tool-system-parts)))
        (chat-tool-system-parts buf)
        '())
    (list (list "chat-preamble" (chat-preamble buf))
          (list "code" (chat-code-prompt buf)))))

(define (chat-live-system-prompt-parts buf &optional tools?)
  (let* ((source (chat-live-system-prompt-source-parts buf tools?))
         (parts (if (boundp (quote prompt-section-parts))
                    (prompt-section-parts source)
                    source)))
    (if (boundp (quote prompt-parts-enabled))
        (prompt-parts-enabled buf parts)
        parts)))

(define (chat-system-prompt-parts buf &optional tools?)
  (let* ((target (or (buffer-ref buf) buf))
         (live (chat-live-system-prompt-parts target tools?)))
    (if (boundp (quote chat-prompt-snapshot-parts))
        (chat-prompt-snapshot-parts target 'direct live)
        live)))

;; A model can run its tools and end the turn with no text, which leaves
;; the user asking "done?". The direct lane then sends this once, in the
;; same turn. "" turns the nudge off.
(defvar 'chat-empty-reply-nudge
  "You ended your turn without a reply. In two or three sentences, tell the user what you did and what is left.")

;; A steer moves an ACP turn's close off the model result and onto an idle
;; signal the adapter can lose. The turn then never closes on the wire and
;; the chat says "streaming" at an agent that stopped. The runtime waits
;; this many seconds after the result for the close, then ends the turn
;; itself. 0 turns the recovery off. A model can think for a minute
;; and send no event while it thinks, so 45 seconds cancelled turns that
;; still worked. 180 matches the wait for a silent first event.
(defvar 'chat-steer-settle-seconds 180)

;; The other silence. A connector can take the prompt and say nothing at
;; all: no text, no tool, no result, no end. Such a turn never closes on
;; the wire and the chat waits at "waiting..." for good. The runtime waits
;; this many seconds for the connector's FIRST event, then ends the turn
;; and reconnects the session. 0 turns the recovery off.
(defvar 'chat-silent-turn-seconds 180)

(define (chat-thread-context slug display)
  (let* ((name (agent-buf slug))
         (buf (or (buffer-ref name) name))
         (healed (chat-heal! buf))
         (tools? (and (boundp (quote chat-use-tools)) chat-use-tools)))
    (unless (= healed 0)
      (message (string-append "healed this chat: dropped " (number->string healed)
                              " orphaned tool " (if (= healed 1) "block" "blocks"))))
    (list 'turns (reverse (chat-model-record buf))
          'system (prompt-parts-text (chat-system-prompt-parts buf tools?))
          'tools (if tools? (chat-tools buf) '())
          'dispatcher (chat-tool-dispatch slug)
          'empty-reply-nudge chat-empty-reply-nudge
          'steer-settle-seconds chat-steer-settle-seconds
          'silent-turn-seconds chat-silent-turn-seconds)))

(domain! 'chat)
(effects! '(read))
(public! 'chat-context
  "(chat-context [BUF]) — chat identity, group, companions, workspace, visible context, and prompt state")
(public! 'chat-context-tokens
  "(chat-context-tokens BUF) — (used U size S): what this chat occupies of its context window, as the backend counted it")
(public! 'chat-live-system-prompt-parts
  "(chat-live-system-prompt-parts BUF [TOOLS?]) — current direct prompt sections before the conversation freeze")
(public! 'chat-live-system-prompt-source-parts
  "(chat-live-system-prompt-source-parts BUF [TOOLS?]) — unfiltered direct prompt fragments")
(effects! '(write))
(public! 'chat-system-prompt-parts
  "(chat-system-prompt-parts BUF [TOOLS?]) — named system-prompt sections in their exact send order")

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
           (rich? (equal? (buffer-local buf 'render-mode) "blocks")))
      ;; "plain", not #f: the chosen view is identity (S11), and a cleared
      ;; local reads as "never chosen" — which the setup would re-default
      (buffer-set-local! buf 'render-mode (if rich? "plain" "blocks"))
      (chat-view-sync! buf)
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
        "openrouter:x-ai/grok-4.7"
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

(domain! 'chat)
(effects! '(write))

;; Set a chat's title by renaming its buffer in place.
(define (chat-title buf title)
  (let ((name (string-trim title)))
    (cond ((equal? name "") #f)
          ;; a chat that already wears this name is titled all the same:
          ;; the local is what says so, and the auto-titler reads it
          ((equal? name buf) (buffer-set-local! name 'chat-title name) #t)
          ((rename-buffer! buf name)
           ;; a title, once set, is the chat's own: the auto-titler names
           ;; a chat that has none, and never renames one that has
           (buffer-set-local! name 'chat-title name)
           #t)
          (else #f))))

(public! 'chat-title
  "(chat-title BUF TITLE) — set a chat's title by renaming its buffer")

(define (chat-title--first-summary buf)
  ;; the label the chat wore first: chat-summary-log is newest-first, so
  ;; its last entry is the opening sentence. A chat that has one summary
  ;; and no log yet answers with that.
  (let ((log (buffer-local buf 'chat-summary-log)))
    (if (pair? log)
        (cadr (car (reverse log)))
        (buffer-local buf 'chat-summary))))

;; A chat's title is the first label its running summary wrote, and a
;; title does not move: the summary keeps saying what the work is doing
;; now, the title keeps saying what the chat is. The lists and the bar
;; show this. chat-title, typed, renames the buffer and wins over it.
(public! 'chat-title-of
  "(chat-title-of BUF) — the chat's fixed title: the first label its running summary wrote")
(define (chat-title-of buf)
  (let ((t (buffer-local buf 'chat-title)))
    (if (and (string? t) (not (equal? t "")))
        t
        (chat-title--first-summary buf))))

(define-command "chat-title" "Set the current chat's title"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (not (chat-buffer? buf))
          (message "not a chat buffer")
          (minibuffer-read "Chat title: " '()
            (lambda (title)
              ;; empty input takes the chat's first running summary, the
              ;; sentence that already names the work
              (let ((name (if (equal? (string-trim title) "")
                              (chat-title--first-summary buf)
                              title)))
                (cond ((not name)
                       (message "No summary yet; type a title"))
                      ((chat-title buf name)
                       (message (string-append "Chat title: " (buffer-name buf))))
                      (else
                       (message "Chat title cannot be empty or is already taken"))))))))))

;; the title names the chat, so the key that sets it lives on chat-mode's
;; own map beside C-c C-k and C-c C-v; M-x still reaches it from anywhere,
;; where the chat-buffer? guard turns it away.
(mode-keys! "chat-mode" '(("C-c C-t" "chat-title")))


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

;; the pre-group flat archive. A chat with no group — none of them once —
;; still lands here, and it stays the fallback so an old archive keeps
;; reading back.
(define (chat-log-legacy-dir) (string-append (compos-home) "/chats"))

;; the directory THIS chat archives to: a member of a group logs into
;; that group's home (group-home-dir, groups.scm), so C-c C-h group-home
;; shows every chat the group ever had, beside whatever else it saved.
;; A chat with no group falls back to the flat legacy archive.
(define (chat-log-dir-for buf)
  (let ((g (and buf (buffer-group buf))))
    (if g
        (string-append (group-home-dir g) "/chats")
        (chat-log-legacy-dir))))

(define (chat-log-files-in dir)
  (if (not (file-exists? dir))
      '()
      (map (lambda (name) (string-append dir "/" name))
           (filter (lambda (name) (string-suffix? ".chat" name))
                   (list-dir dir)))))

(define (chat-log-files)
  (apply append
    (map chat-log-files-in
         (cons (chat-log-legacy-dir)
               (map (lambda (g) (string-append (group-home-dir g) "/chats"))
                    (group-ids))))))

(effects! '(read))
(public! 'chat-log-files
  "(chat-log-files) — every archived conversation as a .chat path")

;; Reset deliberately forgets 'chat-log-id, so recovery cannot depend on the
;; current buffer remembering which conversation came before it.  Present the
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
                        (let* ((buf (visit-in-group path g))
                               (title (and buf (buffer-local buf 'chat-title))))
                          ;; chat-file-init! restores the title local from the
                          ;; archive header. Give the revived chat that name
                          ;; again instead of leaving it named after its file.
                          (when (and (string? title) (not (equal? title "")))
                            (chat-title buf title))
                          buf)
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
            (if (file-exists? (string-append (chat-log-dir-for buf) "/" id ".chat"))
                (loop (+ n 1))
                (begin (buffer-set-local! buf 'chat-log-id id) id)))))))

(public! 'chat-log-path
  "(chat-log-path BUF) — the file this conversation logs itself to")
(define (chat-log-path buf)
  (string-append (chat-log-dir-for buf) "/" (chat-log-id! buf) ".chat"))

(public! 'chat-log-save!
  "(chat-log-save! BUF) — write this conversation to its group's home, else <compos-home>/chats, as a .chat file")
(define (chat-log-save! buf)
  (let ((text (chat-file-text buf)))
    (when text
      (write-file! (chat-log-path buf) text)
      ;; the size a buffer list prints beside this chat. The writer knows
      ;; it; without this every draw of the table stats the log file of
      ;; every chat in the workspace to find the same number out again.
      (buffer-set-local! buf 'chat-log-size (string-byte-length text)))))

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

;; ---------------------------------------------------------------------------
;; The running summary: one sentence that says what this chat is doing.
;; agent.scm nudges chat-summary-note-tool! on every tool call; the debounce
;; folds a burst into one cheap-model completion, in the background and in
;; silence -- the paragraph only lands in the chat-summary buffer-local. It
;; rides the .chat header line into the archive, and chat-file-init! seeds it
;; back on restore, so a chats list can say what an archived chat was doing
;; from its first line alone.

(domain! 'chat)
(effects! '(write external spend))

(defcustom 'chat-summary-model "claude-haiku-4-5"
  "The cheap model that keeps each chat's one-sentence running summary."
  'group 'chat 'type 'string)

(define *chat-summary-debounce-ms* 10000)
(define *chat-summary-tail-lines* 60)

;; How long a chat's running summary may be. A longer answer is cut at a word. One sentence of a turn summary usually fits inside it.
(define chat-summary-max-bytes 180)

(defcustom 'chat-title-max-bytes 56
  "How long a chat's title may be. The name is a label, not a sentence."
  'group 'chat 'type 'integer)

(defcustom 'chat-title-min-bytes 25
  "The shortest opening prompt that earns a title when JEV cannot judge one. Below it the chat stays untitled and the next prompt tries again."
  'group 'chat 'type 'integer)

;; How many words a chat's title may hold. The card writer answers with a factual title of three to eight words; a chat shows a label.
(define chat-title-max-words 6)

;; one line, because the .chat header is one line
;; N bytes at most, cut at the last word inside the budget so the line
;; ends on a word and not mid-syllable
(define (chat-summary--clip s n)
  (if (<= (string-byte-length s) n)
      s
      (let* ((head (substring-bytes s 0 n))
             (sp (string-rindex head " ")))
        (string-trim (if (and sp (> sp (quotient n 2)))
                         (substring-bytes head 0 sp)
                         head)))))

;; Words that cannot end a label. The clip below is a hard cut at a word
;; count, and a hard cut is what left this chat wearing "A user requests a
;; correction to": a title hanging on its preposition.
(define chat-title--dangling
  '("a" "an" "and" "as" "at" "but" "by" "for" "from" "in" "into" "is"
    "its" "of" "on" "or" "that" "the" "their" "this" "to" "was" "were"
    "with"))

(define (chat-title--trim-dangling words)
  (if (or (null? words) (null? (cdr words)))
      words
      (let ((last (string-downcase (car (reverse words)))))
        (if (member last chat-title--dangling)
            (chat-title--trim-dangling (reverse (cdr (reverse words))))
            words))))

;; A chat's title is a label, not a sentence. The card writer is asked for
;; three to six words; anything longer is clipped here, and then trimmed
;; back to a word that can end a phrase, so a clipped label still names
;; something instead of trailing off.
(define (chat-title--short s)
  (let ((words (filter (lambda (w) (not (equal? w "")))
                       (string-split (string-trim s) " "))))
    (string-join (chat-title--trim-dangling
                   (chat-take words chat-title-max-words))
                 " ")))

;; The bar and the buffer name hold one line, and the card writer answers
;; in one sentence or two: the first names the work, the second elaborates.
;; Take the first, so the line is short because it says less, and not
;; because something cut it.
(define (chat-summary--first-sentence s)
  (let* ((t (string-trim s))
         (i (string-index t ". ")))
    (if i (substring-bytes t 0 (+ i 1)) t)))

(define (chat-summary--flatten s)
  (let loop ((cur s))
    (let ((next (re-replace "[\\s][\\s]+|[\\n\\t\\r]" cur " ")))
      (if (equal? next cur)
          ;; the bar, the buffer name and the .chat header all show this
          ;; line whole, so a model that answers in two sentences must not
          ;; be the thing that decides how wide they are
          (chat-summary--clip (string-trim cur) chat-summary-max-bytes)
          (loop next)))))

;; the tail of the rendered transcript, cut on line boundaries so a
;; multibyte character never splits
(define (chat-summary--tail buf)
  (let* ((lines (string-split
                  (chat-turns-text (reverse (chat-model-record buf))) "\n"))
         (n (length lines)))
    (let loop ((ls lines) (extra (- n *chat-summary-tail-lines*)))
      (if (and (pair? ls) (> extra 0))
          (loop (cdr ls) (- extra 1))
          (string-join ls "\n")))))

;; The passage a card writer is asked to name. The transcript is the wrong
;; passage: it is mostly tool output, greps and source, so a model that
;; names a passage faithfully names that -- one chat came out
;; "Explanation of a specific term", which is a fair title for a slab of
;; Elixir and tells you nothing about the chat. A chat's subject is in what
;; the person asked for. So the passage is the user's own turns: the first,
;; which says what the chat is for, and the most recent, which say what it
;; is on now.
(define *chat-summary-brief-bytes* 1200)

(define (chat-summary--recent-asks asks budget)
  ;; walked newest-first so the newest asks are the ones that survive the
  ;; budget, and consed back into the order they were said in
  (let loop ((rev (reverse asks)) (left budget) (kept '()))
    (if (or (null? rev) (<= left 0))
        kept
        (let* ((a (string-trim (car rev)))
               (n (+ 1 (string-length a))))
          (if (equal? a "")
              (loop (cdr rev) left kept)
              (loop (cdr rev) (- left n) (cons a kept)))))))

(define (chat-summary--brief buf)
  ;; the record is newest-first; a passage reads in the order it was said
  (let* ((turns (reverse (chat-record-turns (chat-model-record buf))))
         (asks (map (lambda (p) (car (cdr p)))
                    (filter (lambda (p) (equal? (car p) "user")) turns))))
    (if (null? asks)
        (chat-summary--tail buf)
        (let* ((recent (chat-summary--recent-asks asks *chat-summary-brief-bytes*))
               (opening (string-trim (car asks)))
               (lines (if (or (null? recent) (equal? opening (car recent)))
                          recent
                          (cons opening recent)))
               (text (string-join lines "\n")))
          (if (equal? (string-trim text) "") (chat-summary--tail buf) text)))))

;;; --- the two moments ------------------------------------------------------
;;; A chat learns two things about itself, at two moments, from the same
;;; on-device card writer.
;;;
;;; The first prompt names it. The passage is that prompt: it is what the
;;; person came to do, and a name that moves under you is worse than a
;;; plain one, so this runs once and never again.
;;;
;;; Every finished turn says what the agent just did. The passage is that
;;; turn alone -- the ask, the reply, and the tools it ran -- so the line
;;; is about the work that just happened and not about the chat, which
;;; the title already names. One line per turn, kept in the summary log.

;; How much of a finished turn the card writer reads when it says what the agent did.
(define chat-summary-turn-bytes 1400)

(define (chat-summary--first-ask buf)
  ;; the record is newest-first, so the first ask is at the far end
  (let loop ((ts (reverse (chat-record buf))))
    (cond ((null? ts) #f)
          ((and (equal? (plist-get (car ts) 'role) "user")
                (not (equal? (string-trim (chat-turn-display (car ts))) "")))
           (string-trim (chat-turn-display (car ts))))
          (else (loop (cdr ts))))))

;; the newest turn of work: every turn back to the ask that started it,
;; put back in the order it happened
(define (chat-summary--last-turns buf)
  (let loop ((ts (chat-record buf)) (acc '()))
    (cond ((null? ts) acc)
          ((equal? (plist-get (car ts) 'role) "user") (cons (car ts) acc))
          (else (loop (cdr ts) (cons (car ts) acc))))))

(define (chat-summary--uniq l)
  (let loop ((l l) (seen '()))
    (cond ((null? l) (reverse seen))
          ((member (car l) seen) (loop (cdr l) seen))
          (else (loop (cdr l) (cons (car l) seen))))))

(define (chat-summary--blocks-fold turns kind f init)
  (fold (lambda (acc t)
          (fold (lambda (a b) (if (equal? (car b) kind) (f a b) a))
                acc (or (plist-get t 'blocks) '())))
        init turns))

;; A passage, not a dump. The tool names go in as one sentence of prose:
;; the card writer names passages of text, and a block of raw arguments
;; and results is a passage about Elixir, which is how a chat once came
;; out called "Explanation of a specific term".
(define (chat-summary--turn-passage buf)
  (let* ((ts (chat-summary--last-turns buf))
         (asked (and (pair? ts) (equal? (plist-get (car ts) 'role) "user")))
         (ask (if asked (string-trim (chat-turn-display (car ts))) ""))
         ;; assistant turns only: a landed summary is recorded as status,
         ;; and feeding a summary back in is how a line eats itself
         (work (filter (lambda (t) (equal? (plist-get t 'role) "assistant"))
                       (if asked (cdr ts) ts)))
         (prose (string-trim
                  (chat-summary--blocks-fold work "text"
                    (lambda (a b) (string-append a (car (cdr b)) "\n")) "")))
         (tools (chat-summary--uniq
                  (chat-summary--blocks-fold work "tool-use"
                    (lambda (a b) (append a (list (nth 2 b)))) '()))))
    (string-trim
      (string-append
        (if (equal? ask "")
            ""
            (string-append "The person asked: " (chat-summary--clip ask 400) "\n\n"))
        (chat-summary--clip prose chat-summary-turn-bytes)
        (if (null? tools)
            ""
            (string-append "\n\nThe assistant ran " (string-join tools ", ") "."))))))

(define (chat-title--card-ready?)
  (and (boundp 'title-card) (title-ready?)))

(public! 'chat-title-first-prompt!
  "(chat-title-first-prompt! BUF [FORCE?]) -- name a chat from its first prompt, once")
(define (chat-title--long-enough? ask)
  (>= (string-byte-length (string-trim ask)) chat-title-min-bytes))

;; A hello is not a subject. K gets #t once the chat has said something to
;; name it by, and agent.scm asks again on every user message while
;; chat-title is unset, so the first substantive turn is the one that
;; titles. JEV judges it when there is a key to reach it with; without one
;; the length of the ask stands in for the judgement.
(define (chat-title--substantive? ask k)
  (if (and (boundp 'jev-ask) (boundp 'jev-noul))
      (jev-ask ask
        (list 'substantive
              (jev-noul (string-append
                          "Does this passage state a task, a question, or a"
                          " problem the writer wants addressed? Answer no"
                          " when it is only a greeting, thanks, or small"
                          " talk.")))
        (lambda (reply)
          (let ((p (and reply (jev-answer-noul reply 'substantive))))
            (k (if p (>= p 0.5) (chat-title--long-enough? ask))))))
      (k (chat-title--long-enough? ask))))

(define (chat-title--land-card! buf ask force?)
  (title-card ask
    (lambda (card)
      (when (and (pair? card) (buffer-known? buf)
                 (or force? (not (string? (buffer-local buf 'chat-title)))))
        (chat-title buf (chat-title--short
                          (chat-summary--clip
                            (chat-summary--flatten (car card))
                            chat-title-max-bytes)))))))

(define (chat-title-first-prompt! buf &optional force?)
  (and (buffer-known? buf)
       (or force? (not (string? (buffer-local buf 'chat-title))))
       (chat-title--card-ready?)
       ;; the passage is every ask the chat has made, which at the first
       ;; prompt is that prompt and nothing else -- so this is one door,
       ;; not a special case. It matters when chat-retitle forces it: a
       ;; chat's subject is the whole run of asks, and the opening line
       ;; alone named this one "Desertant integration testing summary"
       ;; where the full brief named it "Desertant title and chat summary
       ;; integration".
       (let ((ask (chat-summary--brief buf)))
         (and (string? ask) (not (equal? (string-trim ask) ""))
              (begin
                ;; a forced retitle is the user naming the chat on purpose:
                ;; it asks for no permission from the greeting gate.
                (if force?
                    (chat-title--land-card! buf ask force?)
                    (chat-title--substantive? ask
                      (lambda (yes)
                        (when yes (chat-title--land-card! buf ask force?)))))
                #t)))))

(public! 'chat-summary-turn!
  "(chat-summary-turn! BUF) -- land a one-line summary of the turn that just finished")
(define (chat-summary-turn! buf)
  (and (buffer-known? buf)
       (chat-title--card-ready?)
       (let ((passage (chat-summary--turn-passage buf)))
         (and (not (equal? passage ""))
              (begin
                (title-card passage
                  (lambda (card)
                    (when (and (pair? card) (buffer-known? buf))
                      (let* ((desc (and (pair? (cdr card)) (car (cdr card))))
                             (text (if (and (string? desc)
                                            (not (equal? (string-trim desc) "")))
                                       desc
                                       (car card))))
                        (chat-summary-land! buf
                          (chat-summary--flatten
                            (chat-summary--first-sentence text)))))))
                #t)))))

(define (chat-summary-refresh! buf &optional force?)
  (when (buffer-known? buf)
    (let* ((titled (string? (buffer-local buf 'chat-title)))
           ;; the name is a label: one clipped line, and only for a chat
           ;; that has none -- unless the user asked for a fresh one
           (retitle
             (lambda (b t)
               (let ((name (and (string? t)
                                (not (equal? (string-trim t) ""))
                                (or force? (not titled))
                                (chat-title--short
                                  (chat-summary--clip
                                    (chat-summary--flatten t)
                                    chat-title-max-bytes)))))
                 (if (and name (chat-title b name)) name b))))
           (land
             (lambda (b text)
               (when (and (string? text) (not (equal? text "")) (buffer-known? b))
                 (let ((flat (chat-summary--flatten
                               (chat-summary--first-sentence text))))
                   (unless (equal? flat (buffer-local b 'chat-summary))
                     (chat-summary-land! b flat))))))
           ;; The on-device card writer can be missing, still loading, or
           ;; answer nothing for a passage it could not parse. Every one of
           ;; those is the same case to a chat: fall back to the cheap
           ;; hosted model rather than leave the summary stale.
           (fallback!
             (lambda ()
               (llm-with-model
                 (string-append
                   "You maintain a one-sentence label for a work chat between a person"
                   " and a coding agent. The label names the task the chat is on, the"
                   " way a title does: what kind of work, on what. Do not report steps"
                   " taken, findings, or status. Rewrite the label only when the task"
                   " changed. One sentence, plain text, no markdown, five or six words."
                   " Answer with the sentence only.\n\nCurrent label:\n"
                   (or (buffer-local buf 'chat-summary) "(none yet)")
                   "\n\nWhat the person has asked for, oldest first:\n"
                   (chat-summary--brief buf))
                 chat-summary-model
                 (lambda (text)
                   (let ((b (if force? (retitle buf text) buf)))
                     (land b text)))))))
      ;; The on-device card writer returns TITLE and DESCRIPTION. TITLE
      ;; names the chat, once. DESCRIPTION is the running summary, and it
      ;; does move. The rename comes first, so the summary lands in the
      ;; buffer that now wears the name.
      (if (and (boundp 'title-card) (title-ready?))
          (title-card (chat-summary--brief buf)
            (lambda (card)
              (cond ((not (buffer-known? buf)) #f)
                    ((pair? card)
                     (let* ((title (car card))
                            (desc (and (pair? (cdr card)) (cadr card)))
                            (b (retitle buf title)))
                       (land b (if (and (string? desc)
                                        (not (equal? (string-trim desc) "")))
                                   desc
                                   title))))
                    (else (fallback!)))))
          (fallback!)))))

(define *chat-summary-log-max* 200)

;; One hook for both facts a chat learns about itself. It runs as (BUF KIND
;; TEXT), KIND being 'title or 'summary: the title fires once, when the chat
;; takes the first label it will keep, and the summary fires on every fresh
;; paragraph. A list, a bar, or an index that wants to follow what a chat is
;; doing adds itself here instead of polling the buffer-local.
(public! 'chat-summary-hook
  "chat-summary-hook — runs (BUF KIND TEXT) when a chat's title or running summary lands; KIND is 'title or 'summary")

;; a fresh paragraph: the bar shows it, the log keeps it, the archive
;; takes it
(define (chat-summary-land! buf text)
  (buffer-set-local! buf 'chat-summary text)
  ;; the first label a chat writes is its title, and it is fixed from
  ;; here on. A chat whose log predates the title takes the oldest entry
  ;; the log holds, so the title is still the label it wore first.
  (let ((titled (string? (buffer-local buf 'chat-title))))
    (unless titled
      (buffer-set-local! buf 'chat-title
        (chat-title--short (or (chat-title--first-summary buf) text)))
      (run-hook-with-args 'chat-summary-hook buf 'title (buffer-local buf 'chat-title))))
  (run-hook-with-args 'chat-summary-hook buf 'summary text)
  (let ((log (or (buffer-local buf 'chat-summary-log) '())))
    (buffer-set-local! buf 'chat-summary-log
      (take (cons (list (current-time) text) log) *chat-summary-log-max*)))
  ;; A summary is transcript status: ordered where it lands, durable in the
  ;; record, but filtered from every model-facing conversation path.
  (chat-record-push! buf "status" (list (list "text" text)) #f)
  (when (buffer-local buf 'agent-saved-mark)
    (when (boundp 'agent-adopt-prose-tail!) (agent-adopt-prose-tail! buf))
    (let* ((rendered (string-append "\n" text "\n\n"))
           (start (chat-render! buf rendered))
           (end (+ start (string-byte-length rendered))))
      (agent-block-push! buf start end "status" '())
      (when (boundp 'agent-add-overlay!)
        (agent-add-overlay! buf start end "agent-meta"))))
  ;; the bar shows the paragraph now, not after the next command
  (dashboard--sync! buf)
  ;; between turns no save is coming -- the archive takes the fresh
  ;; paragraph now; mid-turn the turn-end save carries it
  (unless (buffer-local buf 'chat-turn-active)
    (chat-log-save! buf)))

;; The bar shows the latest line. The log shows every line, the chat's
;; summaries and the repo's open changes in one order of time.
(public! 'buffer-summary-log-entries
  "(buffer-summary-log-entries BUF) -- ((SECS KIND TEXT) ...) oldest first; KIND is summary or jj")
(define (buffer-summary-log-entries buf)
  (let ((summaries (map (lambda (e) (list (car e) 'summary (cadr e)))
                        (let ((log (buffer-local buf 'chat-summary-log))
                              (now (buffer-local buf 'chat-summary)))
                          ;; a chat from before the log has one undated
                          ;; paragraph: the one the bar shows
                          (cond ((pair? log) log)
                                ((and (string? now) (not (equal? now ""))) (list (list 0 now)))
                                (else '())))))
        (changes (map (lambda (e) (list (car e) 'jj (cadr e)))
                          (jj-line-history buf))))
    (sort (append summaries changes))))

(define (buffer-summary-log--markdown buf)
  (string-append
    "# Summary log: " buf "\n\n"
    (let ((entries (buffer-summary-log-entries buf)))
      (if (null? entries)
          "_No summary and no jj change yet._\n"
          (string-join
            (map (lambda (e)
                   (let ((kind (cadr e)))
                     (string-append
                       "**" (if (> (car e) 0) (format-time (car e) "%H:%M") "--:--") "**"
                       (if (equal? kind 'summary)
                           ""
                           (string-append " " (symbol->string kind)))
                       "  \n" (caddr e) "\n")))
                 entries)
            "\n")))))

(define (buffer-summary-log! buf)
  (help-doc! (string-append "Summary log: " buf) (buffer-summary-log--markdown buf)))

(define-command "buffer-summary-log"
  "Show this buffer's summaries and jj changes, interleaved by time"
  (lambda () (buffer-summary-log! (current-buffer))))

;; the wide segment of the bar opens the log for the window's buffer
(add-hook! (list 'block-click 'summary-log)
  (lambda (buf id)
    (and (equal? id "summary-log")
         (begin (buffer-summary-log! buf) #t))))

(public! 'chat-summary-note-tool!
  "(chat-summary-note-tool! BUF) -- refresh the chat's running summary once the tool-call burst settles")
(define (chat-summary-note-tool! buf)
  (debounce! (string-append "chat-summary:" buf) *chat-summary-debounce-ms*
             chat-summary-refresh! buf))

;; Title a chat again. The reader types the title, or leaves the answer
;; blank to ask the model. The model path names the chat from its first
;; prompt again and lands a fresh running summary. Every other path titles
;; a chat once; this is the one that overrules a title already there.
;; AFTER runs when the answer is in.
(define (chat-retitle! buf &optional after)
  (minibuffer-read
    (string-append "Title for " buf " (blank asks the model): ")
    '()
    (lambda (name)
      (if (equal? (string-trim name) "")
          (begin
            (message "chat-retitle: asking the model")
            ;; the same two moments, both forced: the name comes from the
            ;; first prompt again and the line from the newest turn. Only
            ;; when the card writer is away does the hosted model answer.
            (or (and (chat-title-first-prompt! buf #t)
                     (chat-summary-turn! buf))
                (chat-summary-refresh! buf #t)))
          (chat-title buf name))
      (when after (after)))))

(define-command "chat-retitle" "Title this chat again; a blank title asks the model"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (not (or (chat-buffer? buf) (buffer-local buf 'agent-saved-mark)))
          (message "not a chat buffer")
          (chat-retitle! buf)))))

(domain! 'chat)
(effects! '(write external execute))

;;; --- where a chat works -------------------------------------------------------
;;; root of the buffer the chat was started from), buffer-directory answers from
;;; it, and the modeline's context slot, relative paths and the project root all
;;; move with it. The agent process is the other half: an ACP session is told its
;;; cwd once, at session/new (agent-config-buffer-cwd, agent-connectors.scm), so
;;; a live thread only moves by reconnecting. An idle thread reconnects at once;
;;; a turn in flight is left alone and the move happens at its end, because
;;; killing a running session to change a directory throws the reply away.

(define (chat-cwd-of buf) (buffer-local buf 'chat-directory))

(define (chat-cwd-set! buf dir)
  (let ((slash (if (string-suffix? dir "/") dir (string-append dir "/"))))
    ;; both locals: 'chat-directory is the chat's identity, 'default-directory is
    ;; what a re-stamp would read if this buffer is ever set up again
    (buffer-set-local! buf 'default-directory slash)
    (buffer-set-local! buf 'chat-directory slash)
    slash))

(define (chat-cwd-move-runtime! buf)
  (let ((slug (buffer-local buf 'agent-slug)))
    (cond
      ;; an isolated thread's cwd is its worktree and wins over the chat's
      ;; directory — say so rather than pretend the agent moved
      ((buffer-local buf 'workspace-root) 'workspace)
      ((not (and slug (member slug (agent-list)))) 'none)
      ((member (agent-status slug) '(running starting needs_attention))
       (buffer-set-local! buf 'chat-cwd-pending #t)
       'deferred)
      (else
        (buffer-set-local! buf 'chat-cwd-pending #f)
        ;; a fresh session in the new directory; chat-attach! replays the
        ;; transcript, so the conversation continues
        (agent-reconnect! slug
          (or (buffer-local buf 'agent-connector) *default-connector*)
          (or (buffer-local buf 'agent-model) ""))
        'moved))))

(define (chat-cwd-note what dir)
  (cond ((equal? what 'not-a-chat) "not a chat buffer")
        ((equal? what 'no-such-directory)
         (string-append "no such directory: " dir))
        (else
         (string-append "chat directory: " (abbreviate-file-name dir)
           (cond ((equal? what 'moved) " — agent restarted there")
                 ((equal? what 'deferred) " — agent moves when this turn ends")
                 ((equal? what 'workspace) " — agent keeps its own workspace")
                 (else " — no agent attached"))))))

(define (chat-cwd-target? buf)
  (or (chat-buffer? buf) (buffer-local buf 'agent-saved-mark)))

(define (chat-cwd-move! buf dir)
  (if (not (chat-cwd-target? buf))
      (list 'not-a-chat "")
      (let ((dir (expand-path (normalize-file-input (string-trim dir)))))
        (if (not (file-directory? dir))
            (list 'no-such-directory dir)
            (list (begin (chat-cwd-set! buf dir)
                         (chat-cwd-move-runtime! buf))
                  dir)))))

;; one listener, registered by name, so a reload replaces it instead of
;; stacking a second one
(add-hook! (list 'agent-turn-end "chat-cwd")
  (lambda (slug stop-reason ok?)
    (let ((buf (agent-buf slug)))
      (when (and (string? buf) (buffer-exists? buf)
                 (buffer-local buf 'chat-cwd-pending))
        (message (chat-cwd-note (chat-cwd-move-runtime! buf)
                                (or (chat-cwd-of buf) (buffer-directory buf))))))))

(define-command "chat-cwd" "Set this chat's working directory, and move its agent there"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (not (chat-cwd-target? buf))
          (message (chat-cwd-note 'not-a-chat ""))
          (read-file-name-initial "Chat working directory: " (buffer-directory buf)
            (lambda (input)
              (let ((r (chat-cwd-move! buf input)))
                (message (chat-cwd-note (car r) (cadr r))))))))))

(public! 'chat-cwd-of "(chat-cwd-of BUF) -> the directory this chat works in")
(public! 'chat-cwd-set!
  "(chat-cwd-set! BUF DIR) -> move it; the agent takes it at its next attach")
(public! 'chat-cwd-move-runtime!
  "(chat-cwd-move-runtime! BUF) -> reconnect the thread in the chat's directory: 'moved, 'deferred, 'workspace or 'none")
(public! 'chat-cwd-target?
  "(chat-cwd-target? BUF) -> #t when BUF is a chat the cwd can be moved for")
(public! 'chat-cwd-move!
  "(chat-cwd-move! BUF DIR) -> validate, set and move in one call: (STATUS DIR), STATUS 'not-a-chat, 'no-such-directory, 'moved, 'deferred, 'workspace or 'none")
(public! 'chat-cwd-note
  "(chat-cwd-note STATUS DIR) -> the one-line report for a chat-cwd-move! result")
