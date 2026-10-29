;;; llm-presets.scm --- the LLM Presets app: every saved setup, one page each.
;;;
;;; C-c b switches a chat between presets. This app manages them: the
;;; listing has a row per preset and a row per chat, and each preset has a
;;; page with every field. An edit on the page is the page's draft until
;;; C-c C-c saves it; the chats that ran the old preset follow the new one.

(package! "llm-presets")
(domain! 'llm)
(effects! '(read))

(defface! 'llm-presets-name 'fg "var(--default-fg)" 'weight "600")
(defface! 'llm-presets-changed 'fg "var(--warn-fg)")
(defface! 'llm-presets-mark 'fg "var(--accent-fg)")

(define *llm-presets-buffer* "*llm-presets*")

(define *llm-presets-fields*
  '((section "Model")
    (field connector "backend")
    (field model "model")
    (field effort "effort")
    (section "Tools")
    (field presets "toolsets")
    (field sandbox "sandbox")
    (section "Behaviour")
    (field permission "asks")
    (field agent-mode "agent mode")
    (field prompt-disabled "prompt sections")))

(define (llm-presets--setup b)
  "preset B as a whole setup"
  (llm-config--fill b '()))

(define (llm-presets--names) (map llm-bundle-name *llm-bundles*))

(define (llm-presets--chats) (filter chat-buffer? (buffer-list)))

(define (llm-presets--chat-preset chat)
  "the saved preset CHAT runs now, or #f when it runs its own setup"
  (llm-config-preset-name chat))

(define (llm-presets--followers name)
  "the chats that run preset NAME now"
  (filter (lambda (c) (equal? (llm-presets--chat-preset c) name)) (llm-presets--chats)))

(define (llm-presets--default? name)
  (let ((d llm-default-bundle))
    (cond ((string? d) (equal? d name))
          ((pair? d) (let ((b (llm-bundle-named name)))
                       (and b (llm-config--same? (llm-presets--setup b) (llm-presets--setup d)))))
          (else #f))))

(define (llm-presets--group-default? name g)
  (let ((v (and g (group-setting g 'llm))))
    (cond ((string? v) (equal? v name))
          ((pair? v) (let ((b (llm-bundle-named name)))
                       (and b (llm-config--same? (llm-presets--setup b) (llm-presets--setup v)))))
          (else #f))))

(define (llm-presets--detail-buffer name) (string-append "*llm-preset:" name "*"))

(define (llm-presets--draft name)
  "the draft of preset NAME's page, or #f when no page is open"
  (let ((buf (llm-presets--detail-buffer name)))
    (and (buffer-exists? buf) (buffer-local buf 'llm-presets-draft))))

(define (llm-presets--changes name)
  "the fields the page of NAME changed and did not save"
  (let ((draft (llm-presets--draft name)) (b (llm-bundle-named name)))
    (if (and draft b) (llm-config--changes draft (llm-presets--setup b)) '())))

(define (llm-presets--list)
  "the listing at hand: this one, the one this page belongs to, else the first"
  (if (equal? (buffer-local (current-buffer) 'mode-name) "llm-presets-mode")
      (current-buffer)
      (or (buffer-local (current-buffer) 'llm-presets-list) *llm-presets-buffer*)))

(define (llm-presets--chat)
  "the chat this app acts for: the one it was opened from, else #f"
  (let ((c (and (buffer-exists? (llm-presets--list))
                (buffer-local (llm-presets--list) 'llm-presets-chat))))
    (and c (buffer-exists? c) c)))

;; --- listing ----------------------------------------------------------------

(define (llm-presets--tab buf) (car (or (list-tab-current buf) (list "presets"))))

(define (llm-presets--rows buf)
  ;; the chats count once per draw, not once per row
  (let ((on (map (lambda (c) (list c (llm-presets--chat-preset c))) (llm-presets--chats))))
    (buffer-set-local! buf 'llm-presets-on on)
    (append (map (lambda (n) (list 'preset n)) (llm-presets--names))
            (map (lambda (e) (list 'chat (car e))) on))))

(define (llm-presets--count buf name)
  (length (filter (lambda (e) (equal? (cadr e) name))
                  (or (buffer-local buf 'llm-presets-on) '()))))

(define (llm-presets--keep buf)
  "the columns this width holds, by heading; the last one takes the rest"
  (let ((w (list-view-width buf)) (chats? (equal? (llm-presets--tab buf) "chats")))
    (cond ((< w 70) (if chats? '("chat" "preset") '("preset" "" "model")))
          ((< w 110) (if chats? '("chat" "preset" "was" "model")
                         '("preset" "" "model" "effort" "chats" "toolsets")))
          (else #f))))

(define (llm-presets--all-columns buf)
  (if (equal? (llm-presets--tab buf) "chats")
      (list (list "chat" #f) (list "group" 14) (list "preset" 16) (list "was" 14)
            (list "backend" 12) (list "model" 24) (list "effort" 8))
      (list (list "preset" 16) (list "" 4) (list "backend" 12) (list "model" 24)
            (list "effort" 8) (list "chats" 5) (list "toolsets" #f))))

(define (llm-presets--pick buf xs)
  "XS, one per column, cut to the columns this width holds"
  (let ((keep (llm-presets--keep buf)))
    (if (not keep) xs
        (let loop ((cs (llm-presets--all-columns buf)) (xs xs) (out '()))
          (cond ((null? cs) (reverse out))
                ((member (car (car cs)) keep) (loop (cdr cs) (cdr xs) (cons (car xs) out)))
                (else (loop (cdr cs) (cdr xs) out)))))))

(define (llm-presets--columns buf)
  (let* ((cs (llm-presets--pick buf (llm-presets--all-columns buf)))
         (last (car (reverse cs))))
    (append (filter (lambda (c) (not (eq? c last))) cs) (list (list (car last) #f)))))

(define (llm-presets--marks buf name)
  (string-append (if (llm-presets--default? name) "★" "")
                 (if (llm-presets--group-default? name (buffer-group buf)) "G" "")
                 (if (pair? (llm-presets--changes name)) "•" "")))

(define (llm-presets--preset-cells buf name)
  (let ((s (llm-presets--setup (llm-bundle-named name))))
    (list (list name "llm-presets-name")
          (list (llm-presets--marks buf name) "llm-presets-mark")
          (list (llm-config--field-text 'connector s) "dim")
          (list (llm-config--field-text 'model s) "default")
          (list (llm-config--field-text 'effort s) "dim")
          (list (let ((n (llm-presets--count buf name))) (if (= n 0) "-" (number->string n))) "dim")
          (list (llm-config--field-text 'presets s) "dim"))))

(define (llm-presets--chat-cells buf chat)
  (let* ((s (llm-config--current chat))
         (on (llm-presets--chat-preset chat))
         (was (buffer-local chat 'llm-preset))
         (g (buffer-group chat)))
    (list (list chat "default")
          (list (or (and g (group-name g)) "") "dim")
          (if on (list on "llm-presets-name") (list "own setup" "faint"))
          (if (and (string? was) (not (equal? was on)) (llm-bundle-named was))
              (list was "llm-presets-changed")
              (list "" "faint"))
          (list (llm-config--field-text 'connector s) "dim")
          (list (llm-config--field-text 'model s) "default")
          (list (llm-config--field-text 'effort s) "dim"))))

(define (llm-presets--cells buf r)
  (llm-presets--pick buf (if (eq? (car r) 'chat)
                             (llm-presets--chat-cells buf (cadr r))
                             (llm-presets--preset-cells buf (cadr r)))))

(define (llm-presets--meta buf)
  (let* ((d llm-default-bundle)
         (g (buffer-group buf))
         (gv (and g (group-setting g 'llm))))
    (string-append (number->string (length *llm-bundles*)) " presets · new chats: "
                   (cond ((string? d) d) ((pair? d) "a setup of their own") (else "backend default"))
                   (if (string? gv) (string-append " · " (group-name g) ": " gv) "")
                   (let ((c (llm-presets--chat))) (if c (string-append " · a applies to " c) "")))))

;; --- the page of one preset -------------------------------------------------

(define (llm-presets--page-rows buf)
  (let ((name (buffer-local buf 'llm-preset-name)))
    (append *llm-presets-fields*
            (list (list 'section "Used by"))
            (let ((cs (llm-presets--followers name)))
              (if (null? cs) (list (list 'note "no chat runs it"))
                  (map (lambda (c) (list 'chat c)) cs)))
            (list (list 'note (string-append "default for new chats: "
                                             (if (llm-presets--default? name) "yes" "no")))
                  (let ((g (buffer-group buf)))
                    (list 'note (string-append "default in group " (or (and g (group-name g)) "-") ": "
                                               (if (llm-presets--group-default? name g) "yes" "no"))))))))

(define (llm-presets--page-cells buf r)
  (let* ((name (buffer-local buf 'llm-preset-name))
         (draft (buffer-local buf 'llm-presets-draft))
         (saved (llm-presets--setup (or (llm-bundle-named name) '()))))
    (cond
      ((eq? (car r) 'section) (list (list (cadr r) "llm-presets-name") (list "" "faint") (list "" "faint")))
      ((eq? (car r) 'field)
       (let* ((key (cadr r))
              (changed? (not (llm-config--field-same? key draft saved))))
         (list (list (caddr r) "dim")
               (list (llm-config--field-text key draft) (if changed? "llm-presets-changed" "default"))
               (list (if changed? (string-append "saved: " (llm-config--field-text key saved)) "") "faint"))))
      ((eq? (car r) 'chat) (list (list "chat" "dim") (list (cadr r) "default") (list "" "faint")))
      (else (list (list "" "faint") (list (cadr r) "faint") (list "" "faint"))))))

(define (llm-presets--page-meta buf)
  (let* ((name (buffer-local buf 'llm-preset-name))
         (n (length (llm-presets--followers name)))
         (ch (llm-presets--changes name)))
    (string-append
      (if (null? ch) "saved"
          (string-append (number->string (length ch)) " unsaved · C-c C-c saves"
                         (if (> n 0) (string-append ", " (number->string n)
                                                    (if (= n 1) " chat follows" " chats follow"))
                             "")
                         " · C-c C-k reverts"))
      " · RET on a field changes it")))

(define (llm-presets--draw! buf) (list-render! buf #t))

(define (llm-presets-refresh!)
  (let ((l (llm-presets--list)))
    (when (buffer-exists? l) (list-refresh! l)))
  (for-each llm-presets--draw! (mode-group-buffers "llm-presets-detail-mode")))

(domain! 'llm)
(effects! '(write display))

(define (llm-presets-show-detail! name)
  "show the page of preset NAME beside the listing"
  (when (and name (llm-bundle-named name))
    (let ((list-buf (llm-presets--list))
          (buf (llm-presets--detail-buffer name)))
      (unless (buffer-known? buf)
        (buffer-create buf)
        (let ((g (buffer-group list-buf)))
          (when g (buffer-move-to-group! buf g))))
      (buffer-set-local! buf 'llm-presets-list list-buf)
      (buffer-set-local! buf 'llm-preset-name name)
      (unless (buffer-local buf 'llm-presets-draft)
        (buffer-set-local! buf 'llm-presets-draft (llm-presets--setup (llm-bundle-named name))))
      (if (equal? (list-mode-of buf) "llm-presets-detail-mode")
          (llm-presets--draw! buf)
          (with-current-buffer buf (lambda () (set-mode! "llm-presets-detail-mode"))))
      (display-buffer-detail! buf list-buf)
      buf)))

(define (llm-presets--store buf)
  "the page's draft as a picker store: (GET SET)"
  (list (lambda (key) (llm-bundle-get (buffer-local buf 'llm-presets-draft) key #f))
        (lambda (key value)
          (buffer-set-local! buf 'llm-presets-draft
            (llm-bundle-put (buffer-local buf 'llm-presets-draft) key value))
          (llm-presets-refresh!))))

(define (llm-presets--name-here)
  "the preset this command is about: the page's own, else the listing's row"
  (or (buffer-local (current-buffer) 'llm-preset-name)
      (let* ((l (llm-presets--list))
             (r (and (buffer-exists? l) (list-current l))))
        (and r (eq? (car r) 'preset) (cadr r)))))

(define (llm-presets--on-preset fn)
  (let ((name (llm-presets--name-here)))
    (if name (fn name) (message "no preset on this line"))))

(define (llm-presets--keep-order! order)
  "put the presets back in ORDER, a list of names; the others go last"
  (let ((placed (filter (lambda (b) b) (map llm-bundle-named order))))
    (set! *llm-bundles*
      (append placed (filter (lambda (b) (not (member (llm-bundle-name b) order))) *llm-bundles*)))))

(define (llm-presets--page-for name)
  (let ((buf (llm-presets--detail-buffer name)))
    (and (buffer-exists? buf) buf)))

;; --- reading a field --------------------------------------------------------

(define (llm-presets--pick-from! store prompt key rows)
  (llm-config-read! prompt (llm-config-current-first rows (or ((car store) key) ""))
    (lambda (choice) (unless (equal? choice "") ((cadr store) key choice)))
    (lambda () #f)))

(define (llm-presets--pick-sections! buf store preselect)
  (let* ((chat (or (llm-presets--chat) (car (append (llm-presets--chats) (list #f)))))
         (parts (if chat (chat-prompt-source-parts chat) '()))
         (off (or ((car store) 'prompt-disabled) '())))
    (if (null? parts)
        (message "no chat to read the prompt sections from")
        (minibuffer-read* "Prompt section: "
          (map (lambda (p) (list (car p) (if (member (car p) off) "○ off" "● on"))) parts)
          (append
            (list (list 'confirm
                        (lambda (name)
                          (unless (equal? name "")
                            ((cadr store) 'prompt-disabled
                              (if (member name off)
                                  (filter (lambda (x) (not (equal? x name))) off)
                                  (cons name off)))
                            (llm-presets--pick-sections! buf store name))))
                  (list 'cancel (lambda () #f))
                  (list 'style "palette")
                  (list 'legend '(("RET" "toggle") ("C-g" "done"))))
            (if preselect (list (list 'preselect preselect)) '()))))))

(define (llm-presets--edit-field! buf key)
  (let ((store (llm-presets--store buf))
        (chat (or (llm-presets--chat) buf)))
    (cond
      ((eq? key 'connector) (llm-config--read-backend chat (lambda () #f) store))
      ((eq? key 'model) (llm-config--read-model chat (lambda () #f) store))
      ((eq? key 'effort) (llm-config--read-effort chat (lambda () #f) store))
      ((eq? key 'presets) (llm-config--pick-preset-loop! #f store))
      ((eq? key 'sandbox)
       (llm-presets--pick-from! store "Sandbox: " 'sandbox
         (list (list "on" "shell commands write only in the chat's directory, temp and tool caches")
               (list "off" "shell commands write anywhere")
               (list "group" "as the chat's group says, else agent-sandbox"))))
      ((eq? key 'permission)
       (llm-presets--pick-from! store "Asks: " 'permission
         (map (lambda (m) (list (symbol->string m) (chat-permission-mode-note m))) *permission-modes*)))
      ((eq? key 'agent-mode)
       (let ((modes (map (lambda (m) (list (car m) (or (nth 2 m) "")))
                         (chat-mode-options chat ((car store) 'connector)))))
         (if (null? modes)
             (message "this backend has no session modes")
             (llm-presets--pick-from! store "Agent mode: " 'agent-mode modes))))
      ((eq? key 'prompt-disabled) (llm-presets--pick-sections! buf store #f))
      (else (message "this field has no editor")))))

;; --- actions ----------------------------------------------------------------

(effects! '(write))

(define (llm-presets-save! name)
  "save the page of NAME as the preset; the chats on the old one follow"
  (let ((page (llm-presets--page-for name)) (old (llm-bundle-named name)))
    (cond ((not (and page old)) (message (string-append "no page for " name)))
          ((null? (llm-presets--changes name)) (message (string-append name " has no unsaved changes")))
          (else
            (let ((followers (llm-presets--followers name))
                  (order (llm-presets--names)))
              (llm-bundle-save! name (buffer-local page 'llm-presets-draft))
              (llm-presets--keep-order! order)
              (let ((new (llm-bundle-named name)))
                (for-each (lambda (c) (llm-bundle-apply! c new) (llm-config-changed! c)) followers))
              (llm-presets-refresh!)
              (message (string-append "saved " name
                                      (let ((n (length followers)))
                                        (cond ((= n 0) "")
                                              ((= n 1) " · 1 chat follows")
                                              (else (string-append " · " (number->string n) " chats follow")))))))))))

(define (llm-presets-revert! name)
  (let ((page (llm-presets--page-for name)))
    (when page
      (buffer-set-local! page 'llm-presets-draft (llm-presets--setup (llm-bundle-named name)))
      (llm-presets-refresh!)
      (message (string-append name " is as saved again")))))

(define (llm-presets-apply! name chat)
  "run preset NAME, as saved, in CHAT"
  (let ((b (llm-bundle-named name)))
    (when (and b chat (buffer-exists? chat))
      (llm-bundle-apply! chat b)
      (buffer-set-local! chat 'llm-preset name)
      (llm-config-remember! (llm-presets--setup b))
      (llm-config-changed! chat)
      (llm-presets-refresh!)
      (message (string-append chat " now runs " name
                              (if (pair? (llm-presets--changes name)) " (as saved; the page has unsaved changes)" ""))))))

(define (llm-presets--read-name prompt initial k)
  (minibuffer-read* prompt '()
    (list (list 'confirm (lambda (v)
                           (let ((n (string-trim v)))
                             (cond ((equal? n "") #f)
                                   ((llm-bundle-named n) (message (string-append "a preset " n " exists")))
                                   (else (k n))))))
          (list 'cancel (lambda () #f))
          (list 'initial initial))))

(define (llm-presets--add! name setup)
  (let ((order (llm-presets--names)))
    (llm-bundle-save! name setup)
    (llm-presets--keep-order! order)
    (llm-presets-refresh!)
    (llm-presets-show-detail! name)))

(define (llm-presets-rename! old new)
  (let ((b (llm-bundle-named old)) (order (llm-presets--names)))
    (when b
      (llm-bundle-save! new b)
      (llm-bundle-forget! old)
      (llm-presets--keep-order! (map (lambda (n) (if (equal? n old) new n)) order))
      (for-each (lambda (id) (when (equal? (group-setting id 'llm) old) (group-config-set! id 'llm new)))
                (group-ids))
      (when (equal? llm-default-bundle old) (customize-save! 'llm-default-bundle new))
      (for-each (lambda (c) (when (equal? (buffer-local c 'llm-preset) old) (buffer-set-local! c 'llm-preset new)))
                (llm-presets--chats))
      (let ((page (llm-presets--page-for old)))
        (when page (buffer-kill! page)))
      (llm-presets-refresh!)
      (llm-presets-show-detail! new)
      (message (string-append old " is now " new)))))

(define (llm-presets-delete! name)
  (llm-bundle-forget! name)
  (for-each (lambda (id) (when (equal? (group-setting id 'llm) name) (group-config-set! id 'llm #f)))
            (group-ids))
  (when (equal? llm-default-bundle name) (customize-save! 'llm-default-bundle ""))
  (let ((page (llm-presets--page-for name)))
    (when page (buffer-kill! page)))
  (llm-presets-refresh!)
  (message (string-append "preset " name " deleted")))

(define-command "llm-presets-edit-field" "Change the field on this line of the preset's page"
  (lambda ()
    (let* ((buf (current-buffer)) (r (list-current buf)))
      (cond ((and r (eq? (car r) 'field)) (llm-presets--edit-field! buf (cadr r)))
            ((and r (eq? (car r) 'chat)) (message (string-append (cadr r) " runs this preset")))
            (else (message "no field on this line"))))))

(define-command "llm-presets-save" "Save the preset's page; the chats that ran it follow"
  (lambda () (llm-presets--on-preset llm-presets-save!)))

(define-command "llm-presets-revert" "Throw away the unsaved changes on the preset's page"
  (lambda () (llm-presets--on-preset llm-presets-revert!)))

(define-command "llm-presets-apply" "Run the preset in the chat this app was opened from; on a chat row, pick a preset for that chat"
  (lambda ()
    (let* ((l (llm-presets--list))
           (r (and (equal? (current-buffer) l) (list-current l))))
      (if (and r (eq? (car r) 'chat))
          (llm-config-read! (string-append "Preset for " (cadr r) ": ")
            (map (lambda (n) (list n "")) (llm-presets--names))
            (lambda (n) (unless (equal? n "") (llm-presets-apply! n (cadr r))))
            (lambda () #f))
          (llm-presets--on-preset
            (lambda (name)
              (let ((c (llm-presets--chat)))
                (if c (llm-presets-apply! name c)
                    (message "this app was not opened from a chat; a on a chat row picks its preset")))))))))

(define-command "llm-presets-new" "Make a new preset from the default setup"
  (lambda ()
    (llm-presets--read-name "New preset: " ""
      (lambda (n)
        (llm-presets--add! n (llm-presets--setup (or (llm-default-bundle-record) '())))))))

(define-command "llm-presets-duplicate" "Copy the preset, as its page shows it, under a new name"
  (lambda ()
    (llm-presets--on-preset
      (lambda (name)
        (llm-presets--read-name "Copy as: " (string-append name " copy")
          (lambda (n)
            (llm-presets--add! n (or (llm-presets--draft name)
                                     (llm-presets--setup (llm-bundle-named name))))))))))

(define-command "llm-presets-rename" "Rename the preset; groups, the default and chats keep it"
  (lambda ()
    (llm-presets--on-preset
      (lambda (name)
        (llm-presets--read-name (string-append "Rename " name " to: ") name
          (lambda (n) (llm-presets-rename! name n)))))))

(define-command "llm-presets-delete" "Delete the preset"
  (lambda ()
    (llm-presets--on-preset
      (lambda (name)
        (let ((n (length (llm-presets--followers name))))
          (yes-or-no? (string-append "Delete preset " name
                                     (if (> n 0) (string-append "? " (number->string n)
                                                                (if (= n 1) " chat runs" " chats run")
                                                                " it and keep its setup")
                                         "?"))
            (lambda (yes) (when yes (llm-presets-delete! name)))))))))

(define-command "llm-presets-make-default" "New chats start with this preset"
  (lambda ()
    (llm-presets--on-preset
      (lambda (name)
        (customize-save! 'llm-default-bundle name)
        (llm-presets-refresh!)
        (message (string-append "new chats start with " name))))))

(define-command "llm-presets-make-group-default" "New chats of this group start with this preset"
  (lambda ()
    (llm-presets--on-preset
      (lambda (name)
        (let ((id (group-llm! name (buffer-group (llm-presets--list)))))
          (llm-presets-refresh!)
          (message (string-append (group-name id) ": new chats start with " name)))))))

(define-command "llm-presets-show" "Show the preset on this line as its page beside the list"
  (lambda () (llm-presets--on-preset llm-presets-show-detail!)))

(define-command "llm-presets-refresh" "Redraw the presets"
  (lambda () (llm-presets-refresh!)))

(define *llm-presets-shared-keys*
  '(("a" "llm-presets-apply") ("+" "llm-presets-new") ("C" "llm-presets-duplicate")
    ("R" "llm-presets-rename") ("D" "llm-presets-delete") ("*" "llm-presets-make-default")
    ("G" "llm-presets-make-group-default") ("C-c C-c" "llm-presets-save")
    ("C-c C-k" "llm-presets-revert") ("g" "llm-presets-refresh") ("q" "quit-window")))

(define-list-mode! "llm-presets-mode"
  (list
    'doc (string-append
           "The LLM presets. The presets tab has a row per saved setup: backend, model, effort, "
           "how many chats run it and its toolsets; ★ marks the default for new chats, G this "
           "group's default and • a page with unsaved changes. The chats tab has a row per chat "
           "and the preset it runs; was names the preset it left. Moving the point shows the "
           "preset's page beside the list, RET shows it too. a runs the preset in the chat the "
           "app was opened from, or on a chat row picks the chat's preset. + makes a preset, "
           "C copies it, R renames it, D deletes it, * makes it the default for new chats, G "
           "this group's default. C-c C-c saves its page, C-c C-k reverts it. <left> and "
           "<right> step the tabs, / narrows, g redraws, q quits.")
    'buffer *llm-presets-buffer*
    'transient #f
    'rows llm-presets--rows
    'key (lambda (buf r) (string-append (symbol->string (car r)) ":" (cadr r)))
    'tabs (list (list "presets" (lambda (buf r) (eq? (car r) 'preset)))
                (list "chats" (lambda (buf r) (eq? (car r) 'chat))))
    'preview (lambda (buf r) (when (eq? (car r) 'preset) (llm-presets-show-detail! (cadr r))))
    'columns llm-presets--columns
    'cells llm-presets--cells
    'title (lambda (buf) "LLM Presets")
    'meta llm-presets--meta
    'noun "preset"
    'no-marks #t
    'local-filter #t
    'footer (lambda (buf)
              '(("RET" "page") ("a" "apply") ("+" "new") ("C" "copy") ("R" "rename")
                ("D" "delete") ("*" "default") ("G" "group default") ("<left>/<right>" "tab")
                ("/" "filter") ("q" "quit")))
    'keys (cons '("RET" "llm-presets-show") *llm-presets-shared-keys*)))

(define-list-mode! "llm-presets-detail-mode"
  (list
    'doc (string-append
           "One LLM preset: its model, tools and behaviour, then the chats that run it. RET on a "
           "field changes it. A change stays on this page, marked, until C-c C-c saves it; the "
           "chats that ran the preset then follow. C-c C-k throws the changes away. a runs the "
           "preset in the chat the app was opened from, C copies it, R renames it, D deletes it, "
           "* makes it the default for new chats, G this group's default, + makes a new one, "
           "g redraws, q quits.")
    'transient #f
    'rows llm-presets--page-rows
    'key (lambda (buf r) (string-append (symbol->string (car r)) ":"
                                        (let ((v (cadr r))) (if (symbol? v) (symbol->string v) v))))
    'separator? (lambda (buf r) (eq? (car r) 'section))
    'section? (lambda (buf r) (eq? (car r) 'section))
    'columns (lambda (buf) (list (list "field" 16) (list "value" #f) (list "" 28)))
    'cells llm-presets--page-cells
    'title (lambda (buf) (string-append "Preset " (or (buffer-local buf 'llm-preset-name) "")))
    'meta llm-presets--page-meta
    'noun "field"
    'no-marks #t
    'footer (lambda (buf)
              '(("RET" "change") ("C-c C-c" "save") ("C-c C-k" "revert") ("a" "apply")
                ("C" "copy") ("R" "rename") ("D" "delete") ("*" "default") ("q" "quit")))
    'keys (cons '("RET" "llm-presets-edit-field") *llm-presets-shared-keys*)))

(define-command "llm-presets" "Manage the LLM presets: a page per preset, and the chats that run them"
  (lambda ()
    (let* ((from (current-buffer))
           (buf (list-mode-show! "llm-presets-mode")))
      (when (chat-buffer? from) (buffer-set-local! buf 'llm-presets-chat from))
      (list-refresh! buf)
      (with-current-buffer buf
        (lambda ()
          (let ((r (list-current buf)))
            (when (and r (eq? (car r) 'preset)) (llm-presets-show-detail! (cadr r))))))
      buf)))

(effects! '(write))
(public! 'llm-presets-save! "(llm-presets-save! NAME) — save the open page of preset NAME; the chats on the old preset follow")
(public! 'llm-presets-apply! "(llm-presets-apply! NAME CHAT) — run preset NAME, as saved, in CHAT")
(public! 'llm-presets-rename! "(llm-presets-rename! OLD NEW) — rename a preset; groups, the default and chats keep it")
(public! 'llm-presets-delete! "(llm-presets-delete! NAME) — delete a preset and clear the defaults that named it")
(effects! '(write display))
(public! 'llm-presets-show-detail! "(llm-presets-show-detail! NAME) — show the page of preset NAME beside the presets listing")
