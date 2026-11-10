;;; linear.scm — Linear as a compos app.
;;;
;;; M-x linear lists issues under status tabs: open, backlog, todo, in
;;; progress, closed; / filters by team, assignee and priority. Moving onto a
;;; row shows that issue's page beside the list, one page per issue. The
;;; same keys act on the row and the page:
;;; s status, a assignee, p priority, c comment, n new issue, o open in Linear,
;;; g reread.
;;;
;;; Data: Linear's GraphQL API with a personal API key, the secret setting
;;; linear-api-key: the setting, else LINEAR_API_KEY, else ~/.compos/linear-key.
;;; Make one at Linear > Settings > Security & access > Personal API keys.
;;; Every call is async; nothing waits on the lane.

(domain! 'linear)
(effects! '(write))

(defgroup 'linear "Linear: issues, their status, assignees and comments.")

(defcustom 'linear-api-key #f
  "Linear: a personal API key for its GraphQL API."
  'type 'secret 'group 'linear 'env "LINEAR_API_KEY"
  'key-page "https://linear.app/settings/account/security")

(effects! '(write external display))

(define linear-api "https://api.linear.app/graphql")
(define *linear-buffer* "*linear*")

;;; --- plumbing ---------------------------------------------------------------

(define (linear--s v) (cond ((string? v) v) ((number? v) (number->string v)) ((not v) "") (else (format "~a" v))))
(define (linear--day iso) (let ((s (linear--s iso))) (if (>= (string-length s) 10) (substring s 0 10) s)))

(define (linear--log text)
  (unless (buffer-exists? "*linear-log*") (buffer-create "*linear-log*"))
  (buffer-append! "*linear-log*" (string-append (format-time (current-time) "%Y-%m-%d %H:%M") " " text "\n")))

;; every app buffer joins the frame's group, so the group keeps the layout
(define (linear--join! buf)
  (let ((g (frame-group)))
    (when (and g (not (buffer-in-group? buf g))) (buffer-add-group! buf g)))
  buf)

;; one GraphQL call; K gets the data plist, or #f with the failure logged
;;;###autoload
(define (linear-gql query vars k)
  (http-post linear-api
    (if (pair? vars) (list 'query query 'variables vars) (list 'query query))
    (list 'headers (list 'authorization (or (secret-value 'linear-api-key) "")))
    (lambda (reply)
      (let* ((j (and (pair? reply) (plist-get reply 'json)))
             (errs (and (pair? j) (plist-get j 'errors)))
             (data (and (pair? j) (plist-get j 'data))))
        (when (or errs (not data))
          (linear--log (string-append "graphql failed: "
                                      (if errs (json-encode errs) (linear--s (and (pair? reply) (plist-get reply 'status))))
                                      " — " (substring query 0 (min 60 (string-length query)))))
          (message "Linear: request failed (see *linear-log*)"))
        (k (and (not errs) data))))))

;;; --- teams, their states and members (read once) -----------------------------

(define *linear-teams* #f)

(define (linear--with-teams k)
  (if *linear-teams*
      (k *linear-teams*)
      (linear-gql "{ viewer { id name } teams { nodes { id key name states { nodes { id name type position } } members { nodes { id name displayName } } } } }" '()
        (lambda (d)
          (when d
            (set! *linear-teams*
              (list 'viewer (plist-get d 'viewer)
                    'teams (plist-get (plist-get d 'teams) 'nodes))))
          (k *linear-teams*)))))

(define (linear--teams) (or (and *linear-teams* (plist-get *linear-teams* 'teams)) '()))
(define (linear--team key)
  (let ((hit (filter (lambda (t) (or (equal? (plist-get t 'key) key) (equal? (plist-get t 'id) key))) (linear--teams))))
    (and (pair? hit) (car hit))))
(define (linear--nodes v k) (or (and v (plist-get (plist-get v k) 'nodes)) '()))

;;; --- the listing ---------------------------------------------------------------

(define linear--issue-fields
  "id identifier title priority priorityLabel url updatedAt state { name type } assignee { id name } team { id key }")


;; the status tabs, by Linear's state types: open is todo and in progress, not backlog;
;; closed is read on its own when its tab is taken
(define *linear-views*
  (list (list "open" '("unstarted" "started"))
        (list "backlog" '("triage" "backlog"))
        (list "todo" '("unstarted"))
        (list "in progress" '("started"))
        (list "closed" '("completed" "canceled" "duplicate"))))
(define (linear--view buf) (list-tab buf "open"))
(define (linear--view-types buf) (cadr (or (assoc (linear--view buf) *linear-views*) (car *linear-views*))))
(define (linear--closed? buf) (equal? (linear--view buf) "closed"))
(define (linear--type row) (linear--s (plist-get (plist-get row 'state) 'type)))

(define (linear--filter closed? &optional d)
  (append (list 'state (list 'type (list (if closed? 'in 'nin) (list "completed" "canceled" "duplicate"))))
          (let ((t (and d (plist-get d 'team)))) (if t (list 'team (list 'key (list 'eq t))) '()))
          (let ((pr (and d (plist-get d 'project)))) (if pr (list 'project (list 'name (list 'eq pr))) '()))
          (if (and d (equal? (plist-get d 'assignee) "me")) (list 'assignee (list 'isMe (list 'eq #t))) '())))

;;; --- per-group defaults --------------------------------------------------------
;;; A group can pin the list to a team, a project and an assignee ("me") in its
;;; group.scm: (group-defaults! 'linear-team "SMA" 'linear-project "DM queue"
;;; 'linear-assignee "me"). M-x linear-group-defaults sets them. A group with
;;; defaults gets its own listing, read already narrowed, and new issues land in
;;; its team and project.

(define (linear-group-defaults &optional g)
  (let ((g (or g (frame-group))))
    (and g
         (let ((team (group-setting g 'linear-team))
               (project (group-setting g 'linear-project))
               (assignee (group-setting g 'linear-assignee)))
           (and (or team project assignee) (list 'team team 'project project 'assignee assignee))))))

(define (linear--defaults-label d)
  (string-join (filter (lambda (s) (and s (not (equal? s ""))))
                       (list (plist-get d 'team) (plist-get d 'project)
                             (and (equal? (plist-get d 'assignee) "me") "mine")))
               " · "))

;; K gets the id of the project named NAME, or #f
(define (linear--project-id name k)
  (if (not name) (k #f)
      (linear-gql "query($n: String!) { projects(first: 1, filter: { name: { eq: $n } }) { nodes { id } } }"
        (list 'n name)
        (lambda (d) (let ((ns (linear--nodes d 'projects))) (k (and (pair? ns) (plist-get (car ns) 'id))))))))

(define (linear--read! buf)
  ;; open and closed are read apart, each with its own generation, so a tab
  ;; change mid-read drops neither
  (let* ((closed (linear--closed? buf))
         (set (if closed 'linear-closed 'linear-open))
         (gkey (if closed 'linear-gen-closed 'linear-gen-open))
         (gen (+ 1 (or (buffer-local buf gkey) 0))) (t0 (monotonic-ms)))
    (buffer-set-local! buf gkey gen)
    (buffer-set-local! buf 'linear-loading #t)
    (list-refresh! buf)
    (linear-gql (string-append "query($f: IssueFilter) { issues(first: 250, filter: $f, orderBy: updatedAt) { nodes { " linear--issue-fields " } } }")
      (list 'f (linear--filter closed (buffer-local buf 'linear-defaults)))
      (lambda (d)
        (when (and (buffer-exists? buf) (equal? (buffer-local buf gkey) gen))
          (buffer-set-local! buf 'linear-loading #f)
          (when d (buffer-set-local! buf set (linear--nodes d 'issues)))
          (list-refresh! buf)
          (message (string-append "Linear: " (number->string (length (or (buffer-local buf set) '())))
                                  (if closed " closed" " open") " issues in " (number->string (- (monotonic-ms) t0)) " ms")))))))

(define (linear-rows buf)
  (let ((types (linear--view-types buf)))
    (filter (lambda (r) (member (linear--type r) types))
            (or (buffer-local buf (if (linear--closed? buf) 'linear-closed 'linear-open)) '()))))
(public! 'linear-rows "(linear-rows BUF) -- the Linear issues the listing BUF holds, as plists" 'linear)
(catalog-meta! 'function 'linear-rows 'effects '(read))
(define (linear-key buf row) (plist-get row 'identifier))
(define (linear-title buf)
  (string-append "Linear   " (let ((d (buffer-local buf 'linear-defaults))) (if d (string-append (linear--defaults-label d) "   ") "")) (linear--view buf) (if (buffer-local buf 'linear-loading) " — reading…" "")))

(define (linear--state-tone type)
  (cond ((equal? type "started") "warn") ((equal? type "completed") "good")
        ((member type '("canceled" "duplicate")) "bad") ((member type '("backlog" "triage")) "dim") (else "")))
(define (linear--prio-tone p) (cond ((equal? p 1) "bad") ((equal? p 2) "warn") (else "dim")))
(define (linear--prio-short p) (cond ((equal? p 1) "!!!") ((equal? p 2) "!!") ((equal? p 3) "!") ((equal? p 4) "·") (else "")))

(define (linear-columns buf)
  (list (list "issue" 10) (list "status" 14) (list "pri" 4) (list "assignee" 16) (list "updated" 11) (list "title" #f 'left 'end)))

(define (linear-cells buf row)
  (let ((st (plist-get row 'state)))
    (list (list (linear--s (plist-get row 'identifier)) "dim")
          (list (linear--s (and st (plist-get st 'name))) (let ((t (linear--state-tone (and st (plist-get st 'type))))) (if (equal? t "") "default" t)))
          (list (linear--prio-short (plist-get row 'priority)) (linear--prio-tone (plist-get row 'priority)))
          (list (linear--s (let ((a (plist-get row 'assignee))) (if a (plist-get a 'name) "—"))) "dim")
          (list (linear--day (plist-get row 'updatedAt)) "dim")
          (linear--s (plist-get row 'title)))))

;;; --- the issue page ----------------------------------------------------------------

(define (linear--issue-buffer row) (string-append "*linear:" (linear--s (plist-get row 'identifier)) "*"))

(define linear--detail-actions
  '(("linear:state" "Status" "s") ("linear:assign" "Assign" "a") ("linear:priority" "Priority" "p")
    ("linear:comment" "Comment" "c") ("linear:open" "Open in Linear ↗" "o") ("linear:refresh" "Refresh" "g")))

(define (linear--issue-pairs i)
  (filter (lambda (kv) (not (equal? (cadr kv) "")))
    (list (list "team" (linear--s (and (plist-get i 'team) (plist-get (plist-get i 'team) 'name))))
          (list "priority" (linear--s (plist-get i 'priorityLabel)))
          (list "assignee" (linear--s (let ((a (plist-get i 'assignee))) (if a (plist-get a 'name) "unassigned"))))
          (list "creator" (linear--s (and (plist-get i 'creator) (plist-get (plist-get i 'creator) 'name))))
          (list "project" (linear--s (and (plist-get i 'project) (plist-get (plist-get i 'project) 'name))))
          (list "labels" (string-join (map (lambda (l) (linear--s (plist-get l 'name))) (linear--nodes i 'labels)) ", "))
          (list "created" (linear--day (plist-get i 'createdAt)))
          (list "updated" (linear--day (plist-get i 'updatedAt))))))

(define (linear--comment-block c)
  (component 'ui/callout
    (list 'label (string-append (linear--s (and (plist-get c 'user) (plist-get (plist-get c 'user) 'name))) " · " (linear--day (plist-get c 'createdAt)))
          'tone "note"
          'body (linear--md-blocks (plist-get c 'body)))))

;; Linear writes Markdown. Draw it as blocks: headings, bullets, quotes,
;; code and paragraphs, with **bold**, `code` and [links](url) inline.
(define (linear--inline text)
  ;; a backslash only escapes the character after it
  (let* ((text (string-replace text "\\" ""))
         (t (re-replace-all "\\[([^\\]]+)\\]\\([^)]+\\)" text "\\1"))
         (t (re-replace-all "(^|[^*])\\*([^*\\s][^*]*)\\*(?!\\*)" t "\\1\\2"))
         (bold (string-split t "**")))
    (let loop ((parts bold) (strong? #f) (out '()))
      (if (null? parts) (reverse out)
          (loop (cdr parts) (not strong?)
                (append (reverse
                          (let code ((cs (string-split (car parts) "`")) (c? #f) (acc '()))
                            (if (null? cs) (reverse acc)
                                (code (cdr cs) (not c?)
                                      (if (equal? (car cs) "") acc
                                          (cons (list (cond (c? "c-info") (strong? "c-strong") (else "")) (car cs)) acc))))))
                        out))))))

(define (linear--plain text) (apply string-append (map cadr (linear--inline text))))

;; a Markdown table: its first row heads the columns, the --- row goes
(define (linear--table-cells l)
  (let* ((s (string-trim l))
         (s (if (string-prefix? "|" s) (substring s 1 (string-length s)) s))
         (s (if (string-suffix? "|" s) (substring s 0 (- (string-length s) 1)) s)))
    (map string-trim (string-split s "|"))))

(define (linear--rule-row? cells)
  (null? (remove (lambda (c) (equal? (string-replace (string-replace c "-" "") ":" "") "")) cells)))

(define (linear--table-block lines)
  (let ((rows (remove linear--rule-row? (map linear--table-cells lines))))
    (component 'ui/table (list 'columns (map (lambda (c) (list (linear--plain c))) (car rows))
                               'rows (map (lambda (r) (map linear--plain r)) (cdr rows))))))

(define (linear--md-blocks md)
  (let loop ((ls (string-split (linear--s md) "\n")) (para '()) (fence #f) (out '()))
    (let ((flush (lambda (out)
                   (if (null? para) out
                       (cons (component 'ui/prose (list 'segs (linear--inline (string-join (reverse para) " ")))) out)))))
      (cond
        ((null? ls)
         (reverse (if fence (cons (component 'ui/quote (list 'text (string-join (reverse fence) "\n"))) out) (flush out))))
        (fence
         (if (string-prefix? "```" (string-trim (car ls)))
             (loop (cdr ls) '() #f (cons (component 'ui/quote (list 'text (string-join (reverse fence) "\n"))) out))
             (loop (cdr ls) '() (cons (car ls) fence) out)))
        (else
         (let* ((raw (car ls)) (l (string-trim raw)) (out1 (flush out)))
           (cond
             ((string-prefix? "```" l) (loop (cdr ls) '() '() out1))
             ((equal? l "") (loop (cdr ls) '() #f out1))
             ((member l '("---" "***" "___")) (loop (cdr ls) '() #f out1))
             ;; a line that is only **bold** heads what follows
             ((and (> (string-length l) 4) (string-prefix? "**" l) (string-suffix? "**" l)
                   (not (string-contains? (substring l 2 (- (string-length l) 2)) "**")))
              (loop (cdr ls) '() #f (cons (component 'ui/title (list 'level 2 'text (linear--plain l))) out1)))
             ((string-prefix? "|" l)
              (let take ((rest ls) (rows '()))
                (if (and (pair? rest) (string-prefix? "|" (string-trim (car rest))))
                    (take (cdr rest) (cons (car rest) rows))
                    (loop rest '() #f (cons (linear--table-block (reverse rows)) out1)))))
             ((string-prefix? "#" l)
              (loop (cdr ls) '() #f (cons (component 'ui/title (list 'level 2 'text (string-trim (re-replace "^#+" l "")))) out1)))
             ((string-prefix? ">" l)
              (loop (cdr ls) '() #f (cons (component 'ui/quote (list 'text (string-trim (substring l 1 (string-length l))))) out1)))
             ((or (string-prefix? "* " l) (string-prefix? "- " l) (string-prefix? "+ " l))
              (let ((indent (- (string-length raw) (string-length (re-replace "^\\s+" raw "")))))
                (loop (cdr ls) '() #f
                      (cons (component 'ui/bullet (list 'segs (append (if (> indent 1) (list (list "c-dim" "– ")) '())
                                                                      (linear--inline (substring l 2 (string-length l))))))
                            out1))))
             ((re-match? "^[0-9]+[.)] " l)
              (loop (cdr ls) '() #f (cons (component 'ui/bullet (list 'segs (linear--inline l))) out1)))
             (else (loop (cdr ls) (cons l para) #f out)))))))))

(define (linear--issue-blocks row i)
  (let* ((it (or i row))
         (st (plist-get it 'state))
         (comments (if i (linear--nodes i 'comments) '()))
         (desc (linear--s (and i (plist-get i 'description)))))
    (list
      (component 'ui/section (list 'title (string-append (linear--s (plist-get it 'identifier)) "  " (linear--s (plist-get it 'title)))))
      (component 'ui/badge (list 'text (linear--s (and st (plist-get st 'name))) 'class (linear--state-tone (and st (plist-get st 'type)))))
      (component 'ui/actions (list 'actions linear--detail-actions))
      (component 'ui/card (list 'title "Issue" 'open? #t 'body (list (component 'ui/kv (list 'pairs (linear--issue-pairs it))))))
      (component 'ui/card (list 'title "Description" 'open? #t
                                'body (list (cond ((not i) (component 'ui/empty (list 'text "reading…")))
                                                  ((equal? desc "") (component 'ui/empty (list 'text "no description")))
                                                  (else (component 'ui/page (list 'body (linear--md-blocks desc))))))))
      (component 'ui/card (list 'title "Comments" 'open? #t 'badge (if i (number->string (length comments)) "")
                                'body (cond ((not i) (list (component 'ui/empty (list 'text "reading…"))))
                                            ((null? comments) (list (component 'ui/empty (list 'text "no comments"))))
                                            (else (map linear--comment-block comments)))))
      (list 'tag "c-group" 'class "c-dim" 'text "— end —"))))

;; the text agents read, with anchors on its parts: header, description, comments
(define (linear--issue-text row i)
  (let* ((it (or i row))
         (st (plist-get it 'state))
         (head (string-append (linear--s (plist-get it 'identifier)) "  " (linear--s (plist-get it 'title)) "\n"
                              (linear--s (and st (plist-get st 'name))) " · " (linear--s (plist-get it 'priorityLabel)) " · "
                              (linear--s (let ((a (plist-get it 'assignee))) (if a (plist-get a 'name) "unassigned"))) "\n"
                              (linear--s (plist-get it 'url)) "\n\n"))
         (desc (string-append "Description\n" (if i (linear--s (plist-get i 'description)) "reading…") "\n\n"))
         (com (string-append "Comments\n"
                             (string-join (map (lambda (c) (string-append "— " (linear--s (and (plist-get c 'user) (plist-get (plist-get c 'user) 'name)))
                                                                         " " (linear--day (plist-get c 'createdAt)) "\n" (linear--s (plist-get c 'body))))
                                               (if i (linear--nodes i 'comments) '())) "\n\n")
                             "\n\nend\n")))
    (list head desc com)))

(define (linear--issue-draw! buf)
  (let* ((row (buffer-local buf 'linear-row)) (i (buffer-local buf 'linear-issue))
         (parts (linear--issue-text row i))
         (h (string-byte-length (car parts))) (d (string-byte-length (cadr parts))) (c (string-byte-length (caddr parts))))
    (buffer-set-text! buf (apply string-append parts) #t)
    (buffer-set-local! buf 'render-mode "blocks")
    (buffer-set-local! buf 'render-blocks (linear--issue-blocks row i))
    (anchor-set! buf (list (list "header" 0 h) (list "description" h (+ h d)) (list "comments" (+ h d) (+ h d c))))))

(define (linear--issue-read! buf)
  (let ((row (buffer-local buf 'linear-row)))
    (linear-gql "query($id: String!) { issue(id: $id) { id identifier title description priority priorityLabel url createdAt updatedAt state { name type } assignee { id name } creator { name } team { id key name } project { name } labels { nodes { name } } comments(first: 100) { nodes { body createdAt user { name } } } } }"
      (list 'id (plist-get row 'id))
      (lambda (d)
        (when (and d (buffer-exists? buf))
          (let ((i (plist-get d 'issue)))
            (when i
              (set! i (append i '()))
              (buffer-set-local! buf 'linear-issue i)
              (buffer-set-local! buf 'linear-read-at (monotonic-ms))
              (linear--issue-draw! buf))))))))

(define (linear-issue-show! listing row)
  (when row
    (let ((buf (linear--issue-buffer row)))
      (unless (buffer-exists? buf) (buffer-create buf))
      (linear--join! buf)
      (unless (buffer-derived-mode? buf "linear-detail-mode")
        (with-current-buffer buf (lambda () (set-mode! "linear-detail-mode"))))
      (enable-minor-mode! buf "anchor-mode")
      (buffer-set-local! buf 'linear-row row)
      (buffer-set-local! buf 'linear-listing listing)
      (app-claim! buf "linear" 'detail)
      (linear--issue-draw! buf)
      (if (buffer-exists? listing) (display-buffer-detail! buf listing) (switch-to-buffer! buf))
      ;; a read under a minute old stands
      (let ((at (buffer-local buf 'linear-read-at)))
        (when (or (not at) (> (- (monotonic-ms) at) 60000)) (linear--issue-read! buf)))
      buf)))

;;; --- verbs, the same on the listing and its pages ---------------------------------

(define (linear--row-at buf)
  (if (buffer-derived-mode? buf "linear-mode") (list-current buf) (buffer-local buf 'linear-row)))

(define (linear--after-change! buf row what)
  (message (string-append "Linear: " (linear--s (plist-get row 'identifier)) " " what))
  (let* ((listing (if (buffer-derived-mode? buf "linear-mode") buf (buffer-local buf 'linear-listing)))
         (page (linear--issue-buffer row)))
    (when (buffer-exists? page) (linear--issue-read! page))
    (when (and listing (buffer-exists? listing)) (linear--read! listing))))

(define (linear--update! buf input what)
  (let ((row (linear--row-at buf)))
    (if (not row) (message "No issue here")
        (linear-gql "mutation($id: String!, $input: IssueUpdateInput!) { issueUpdate(id: $id, input: $input) { success } }"
          (list 'id (plist-get row 'id) 'input input)
          (lambda (d) (when d (linear--after-change! buf row what)))))))

(define (linear--row-team row)
  (let ((t (plist-get row 'team))) (and t (linear--team (plist-get t 'id)))))

(define (linear-set-state! buf)
  (let ((row (linear--row-at buf)))
    (linear--with-teams
      (lambda (_)
        (let* ((team (and row (linear--row-team row)))
               (states (map caddr (sort (map (lambda (s) (list (or (plist-get s 'position) 0) (plist-get s 'name) s)) (linear--nodes team 'states))))))
          (if (not team) (message "No issue here")
              (completing-read (string-append (linear--s (plist-get row 'identifier)) " status: ") (map (lambda (s) (plist-get s 'name)) states)
                (lambda (name)
                  (let ((hit (filter (lambda (s) (equal? (plist-get s 'name) name)) states)))
                    (when (pair? hit) (linear--update! buf (list 'stateId (plist-get (car hit) 'id)) (string-append "→ " name)))))
                'require-match #t)))))))

(define (linear-assign! buf)
  (let ((row (linear--row-at buf)))
    (linear--with-teams
      (lambda (_)
        (let* ((team (and row (linear--row-team row)))
               (members (linear--nodes team 'members))
               (names (cons "(unassign)" (map (lambda (m) (plist-get m 'name)) members))))
          (if (not team) (message "No issue here")
              (completing-read (string-append (linear--s (plist-get row 'identifier)) " assignee: ") names
                (lambda (name)
                  (if (equal? name "(unassign)")
                      (linear--update! buf (list 'assigneeId #f) "unassigned")
                      (let ((hit (filter (lambda (m) (equal? (plist-get m 'name) name)) members)))
                        (when (pair? hit) (linear--update! buf (list 'assigneeId (plist-get (car hit) 'id)) (string-append "→ " name))))))
                'require-match #t)))))))

(define linear--priorities '(("Urgent" 1) ("High" 2) ("Medium" 3) ("Low" 4) ("No priority" 0)))

(define (linear-set-priority! buf)
  (let ((row (linear--row-at buf)))
    (if (not row) (message "No issue here")
        (completing-read (string-append (linear--s (plist-get row 'identifier)) " priority: ") (map car linear--priorities)
          (lambda (name)
            (let ((hit (assoc name linear--priorities)))
              (when hit (linear--update! buf (list 'priority (cadr hit)) (string-append "priority " name)))))
          'require-match #t))))

(define (linear-comment! buf)
  (let ((row (linear--row-at buf)))
    (if (not row) (message "No issue here")
        (read-string (string-append "Comment on " (linear--s (plist-get row 'identifier)) ": ")
          (lambda (text)
            (unless (equal? (string-trim text) "")
              (linear-gql "mutation($input: CommentCreateInput!) { commentCreate(input: $input) { success } }"
                (list 'input (list 'issueId (plist-get row 'id) 'body text))
                (lambda (d) (when d (linear--after-change! buf row "commented"))))))))))

(define (linear-new-issue! buf)
  (linear--with-teams
    (lambda (_)
      (let* ((listing (if (buffer-derived-mode? buf "linear-mode") buf (buffer-local buf 'linear-listing)))
             (d (or (and listing (buffer-local listing 'linear-defaults)) (linear-group-defaults)))
             (scope (or (and listing (linear--facet listing "team")) (and d (plist-get d 'team))))
             (mine (or (and listing (equal? (linear--facet listing "assignee") "me")) (and d (equal? (plist-get d 'assignee) "me"))))
             (go (lambda (team)
                   (read-string (string-append "New " (plist-get team 'key) " issue: ")
                     (lambda (title)
                       (unless (equal? (string-trim title) "")
                        (linear--project-id (and d (plist-get d 'project)) (lambda (project-id)
                         (linear-gql "mutation($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { identifier } } }"
                           (list 'input (append (list 'teamId (plist-get team 'id) 'title title)
                                                (if project-id (list 'projectId project-id) '())
                                                (if mine (list 'assigneeId (plist-get (plist-get *linear-teams* 'viewer) 'id)) '())))
                           (lambda (d)
                             (when d
                               (message (string-append "Linear: created " (linear--s (plist-get (plist-get (plist-get d 'issueCreate) 'issue) 'identifier))))
                               (when (and listing (buffer-exists? listing)) (linear--read! listing)))))))))))))
        (if (linear--team scope)
            (go (linear--team scope))
            (completing-read "Team: " (map (lambda (t) (plist-get t 'key)) (linear--teams))
              (lambda (k) (let ((t (linear--team k))) (when t (go t))))
              'require-match #t))))))

(define (linear-open-web! buf)
  (let ((row (linear--row-at buf)))
    (if (and row (plist-get row 'url)) (tab-open (plist-get row 'url)) (message "No issue here"))))

(define (linear-refresh! buf)
  (if (buffer-derived-mode? buf "linear-mode")
      (linear--read! buf)
      (begin (buffer-set-local! buf 'linear-issue #f) (linear--issue-draw! buf) (linear--issue-read! buf))))

;; the status tabs head the list, each with its count under the filters /
;; set; the closed count shows once that tab has been read
(define (linear--view-count buf v)
  (let ((set (buffer-local buf (if (equal? (car v) "closed") 'linear-closed 'linear-open))))
    (and set (length (filter (lambda (r) (and (member (linear--type r) (cadr v)) (linear--passes? buf r))) set)))))

(define (linear--view-set! buf name)
  (list-tab-set! buf name)
  (if (and (equal? name "closed") (not (buffer-local buf 'linear-closed)))
      (linear--read! buf)
      (list-refresh! buf)))

(define (linear--view-step! buf step)
  (list-tab-step! buf (map car *linear-views*) step "open")
  (linear--view-set! buf (linear--view buf)))

(define (linear--tab-blocks buf)
  (let ((view (linear--view buf)))
    (list (component 'ui/tabs
            (list 'class "linear-tabs"
                  'tabs (map (lambda (v)
                               (let ((n (linear--view-count buf v)))
                                 (list (string-append "linear-tab-" (car v))
                                       (if n (string-append (car v) " " (number->string n)) (car v))
                                       (equal? (car v) view))))
                             *linear-views*))))))

(add-hook! (list 'block-click 'linear-tabs)
  (lambda (buf id)
    (and (string? id) (string-prefix? "linear-tab-" id) (buffer-exists? buf)
         (let ((name (substring id 11 (string-length id))))
           (and (assoc name *linear-views*) (begin (linear--view-set! buf name) #t))))))

;; imenu on the list offers the status tabs; leaving it without a pick puts the tab back
(define (linear--imenu-rows buf)
  (map (lambda (v)
         (let ((n (linear--view-count buf v)))
           (list 1 "tab" (car v) (if n (string-append (number->string n) " issues") "")
                 (lambda () (linear--view-set! buf (car v))))))
       *linear-views*))

(define (linear--imenu-snapshot buf)
  (let ((was (linear--view buf)))
    (lambda () (unless (equal? (linear--view buf) was) (linear--view-set! buf was)))))

(define (linear--imenu-setup!)
  (buffer-set-local! (current-buffer) 'imenu-index-function 'linear--imenu-rows)
  (buffer-set-local! (current-buffer) 'imenu-snapshot 'linear--imenu-snapshot))
(add-hook! 'linear-mode-hook 'linear--imenu-setup!)

;; / filters with tabs: Team, Assignee, Priority, and Status, which is the tab
(define (linear--facet buf kind) (let ((f (assoc kind (list-filters buf)))) (and f (cadr f))))
(define (linear--viewer-id) (and *linear-teams* (plist-get (plist-get *linear-teams* 'viewer) 'id)))

(define (linear--row-filter buf row f)
  (let ((k (car f)) (v (cadr f)))
    (cond ((equal? k "team") (equal? (linear--s (plist-get (plist-get row 'team) 'key)) v))
          ((equal? k "assignee")
           (let ((a (plist-get row 'assignee)))
             (cond ((equal? v "me") (and a (equal? (plist-get a 'id) (linear--viewer-id))))
                   ((equal? v "none") (not a))
                   (else (and a (equal? (plist-get a 'id) v))))))
          ((equal? k "priority") (equal? (linear--s (plist-get row 'priority)) v))
          (else #t))))

(define (linear--passes? buf row)
  (null? (remove (lambda (f) (linear--row-filter buf row f))
                 (filter (lambda (f) (member (car f) '("team" "assignee" "priority"))) (list-filters buf)))))

(define (linear--all-rows buf) (append (or (buffer-local buf 'linear-open) '()) (or (buffer-local buf 'linear-closed) '())))

(define (linear--distinct xs)
  (fold (lambda (acc x) (if (or (not x) (member x acc)) acc (append acc (list x)))) '() xs))

(define *linear-facets*
  (list (list 'label "Team" 'kind "team"
              'options (lambda (buf)
                         (map (lambda (k) (list k k))
                              (sort (linear--distinct (map (lambda (r) (plist-get (plist-get r 'team) 'key)) (linear--all-rows buf)))))))
        (list 'label "Assignee" 'kind "assignee"
              'options (lambda (buf)
                         (append (list (list "Me" "me") (list "Unassigned" "none"))
                                 (map (lambda (a) (list (plist-get a 'name) (plist-get a 'id)))
                                      (linear--distinct (map (lambda (r) (plist-get r 'assignee)) (linear--all-rows buf)))))))
        (list 'label "Priority" 'kind "priority"
              'options (lambda (buf) (map (lambda (p) (list (car p) (number->string (cadr p)))) linear--priorities)))
        (list 'label "Status" 'kind "status"
              'options (lambda (buf) (map (lambda (v) (list (car v) (car v))) (cdr *linear-views*)))
              'get (lambda (buf) (let ((v (linear--view buf))) (if (equal? v "open") #f v)))
              'set (lambda (buf v) (linear--view-set! buf (or v "open"))))))

(add-hook! (list 'block-click 'linear)
  (lambda (buf id)
    (and (buffer-local buf 'linear-row)
         (cond ((equal? id "linear:state") (linear-set-state! buf) #t)
               ((equal? id "linear:assign") (linear-assign! buf) #t)
               ((equal? id "linear:priority") (linear-set-priority! buf) #t)
               ((equal? id "linear:comment") (linear-comment! buf) #t)
               ((equal? id "linear:open") (linear-open-web! buf) #t)
               ((equal? id "linear:refresh") (linear-refresh! buf) #t)
               (else #f)))))

;;; --- modes and commands -----------------------------------------------------------

(define-command "linear-open" "Show the issue on this row beside the list"
  (lambda () (let ((buf (current-buffer))) (linear-issue-show! buf (list-current buf))))
  'modes '(linear-mode))
(define-command "linear-set-state" "Change this issue's status" (lambda () (linear-set-state! (current-buffer))) 'modes '(linear-mode linear-detail-mode))
(define-command "linear-assign" "Change who this issue is assigned to" (lambda () (linear-assign! (current-buffer))) 'modes '(linear-mode linear-detail-mode))
(define-command "linear-set-priority" "Change this issue's priority" (lambda () (linear-set-priority! (current-buffer))) 'modes '(linear-mode linear-detail-mode))
(define-command "linear-comment" "Comment on this issue" (lambda () (linear-comment! (current-buffer))) 'modes '(linear-mode linear-detail-mode))
(define-command "linear-new-issue" "Create a Linear issue in the team at hand" (lambda () (linear-new-issue! (current-buffer))) 'modes '(linear-mode linear-detail-mode))
(define-command "linear-open-web" "Open this issue in Linear" (lambda () (linear-open-web! (current-buffer))) 'modes '(linear-mode linear-detail-mode))
(define-command "linear-refresh" "Read this again from Linear" (lambda () (linear-refresh! (current-buffer))) 'modes '(linear-mode linear-detail-mode))
(define-command "linear-next-view" "Show the next status tab: open, backlog, todo, in progress, closed" (lambda () (linear--view-step! (current-buffer) 1)) 'modes '(linear-mode))
(define-command "linear-prev-view" "Show the previous status tab" (lambda () (linear--view-step! (current-buffer) -1)) 'modes '(linear-mode))

(define-list-mode! "linear-mode"
  (list 'doc "Linear issues, newest change first: the id, status, priority (!!! urgent, !! high, ! medium, · low), assignee, last update and title. The status tabs, each with its count, head the list: open (todo and in progress; backlog and triage stay out), backlog, todo, in progress, closed; left and right (or v) step them, a click takes one, and imenu picks one. / filters with tabs, Team, Assignee, Priority and Status, each led by All; words that match no choice filter the text, and status: or team: narrow by field. Moving or RET shows the issue beside the list. s status, a assignee, p priority, c comment, n new issue (in the team and for the assignee the filter shows), o opens it in Linear, g rereads, q quits."
        'transient #f
        ;; the plain text table, as Todos draws, not the drawn grid
        'default-view "bare"
        'noun "issue"
        'rows (lambda (buf) (list-keep buf (linear-rows buf)))
        'key linear-key
        'columns linear-columns
        'cells linear-cells
        'title linear-title
        'head-blocks linear--tab-blocks
        'filter linear--row-filter
        'facets *linear-facets*
        'total (lambda (buf) (length (linear-rows buf)))
        'preview linear-issue-show!
        'debounce #t
        'filters (list (list "status:" (lambda (buf row) (linear--s (plist-get (plist-get row 'state) 'name))) "the status")
                       (list "team:" (lambda (buf row) (linear--s (plist-get (plist-get row 'team) 'key))) "the team key"))
        'footer (lambda (b) (list (list "←→" "status") (list "RET" "issue") (list "s" "status") (list "a" "assign") (list "p" "priority")
                                  (list "c" "comment") (list "n" "new") (list "o" "Linear") (list "/" "filter") (list "g" "refresh") (list "q" "quit")))
        'keys (list (list "RET" "linear-open")
                    (list "v" "linear-next-view") (list "<right>" "linear-next-view") (list "<left>" "linear-prev-view")
                    (list "s" "linear-set-state") (list "a" "linear-assign") (list "p" "linear-set-priority")
                    (list "c" "linear-comment") (list "n" "linear-new-issue") (list "o" "linear-open-web")
                    (list "g" "linear-refresh") (list "q" "quit-window"))))

(define-mode "linear-detail-mode" (lambda () #f))

(mode-keys! "linear-detail-mode"
  '(("s" "linear-set-state") ("a" "linear-assign") ("p" "linear-set-priority") ("c" "linear-comment")
    ("n" "linear-new-issue") ("o" "linear-open-web") ("g" "linear-refresh") ("q" "quit-window")))

(mode-doc! "linear-detail-mode"
  "A Linear issue beside the list: its status, details, description and comments. s status, a assignee, p priority, c comment, n new issue, o opens it in Linear, g rereads.")

(detail-name! "linear-detail-mode"
  (lambda (buf) (let ((row (buffer-local buf 'linear-row))) (string-append "*" (linear--s (and row (plist-get row 'identifier))) "*"))))

(register-context-provider! "linear-detail-mode"
  (lambda (buf) (string-append "Linear issue page " buf " is open. Read it with (buffer-outline BUF) and (buffer-section BUF NAME).")))

(define (linear-listing!)
  (let* ((g (frame-group))
         (d (linear-group-defaults g))
         (buf (if d (string-append "*linear — " (group-name g) "*") *linear-buffer*)))
    (unless (buffer-exists? buf) (buffer-create buf))
    (linear--join! buf)
    (unless (buffer-derived-mode? buf "linear-mode")
      (with-current-buffer buf (lambda () (set-mode! "linear-mode"))))
    (buffer-set-local! buf 'linear-defaults d)
    (app-claim! buf "linear" 'listing)
    buf))

;; pick the frame group's team, project and assignee; each may be left open
(define (linear-group-defaults-set!)
  (let ((g (frame-group)))
    (if (not g) (message "Linear: no group here")
        (linear--with-teams
          (lambda (_)
            (completing-read "Team (any): " (cons "any" (map (lambda (t) (plist-get t 'key)) (linear--teams)))
              (lambda (team)
                (let ((t (linear--team team)))
                  ;; every project: a team's own list misses projects shared across teams
                  (linear-gql "{ projects(first: 100) { nodes { name } } }" '()
                    (lambda (dd)
                      (let ((names (map (lambda (p) (plist-get p 'name)) (linear--nodes dd 'projects))))
                        (completing-read "Project (any): " (cons "any" names)
                          (lambda (project)
                            (completing-read "Assignee (anyone): " '("anyone" "me")
                              (lambda (who)
                                (group-config-set! g 'linear-team (and t team))
                                (group-config-set! g 'linear-project (and (not (equal? project "any")) project))
                                (group-config-set! g 'linear-assignee (and (equal? who "me") "me"))
                                (message (string-append "Linear defaults for " (group-name g) ": "
                                                        (let ((d (linear-group-defaults g))) (if d (linear--defaults-label d) "none"))
                                                        ". M-x linear opens them.")))
                              'require-match #t))
                          'require-match #t))))))
              'require-match #t))))))

(define-command "linear-group-defaults" "Pin this group's Linear list to a team, project and assignee"
  (lambda () (linear-group-defaults-set!)))

;;;###autoload
(define-command "linear" "Open the Linear app: your open issues, one page per issue"
  (lambda ()
    (let ((buf (linear-listing!)))
      (app-open! buf)
      (linear--with-teams (lambda (_) (linear--read! buf))))))

;;; Webhook. Linear pushes each issue and comment change to /hooks/linear-KEY
;;; through the tunnel. The unguessable path is the check (Linear signs its
;;; posts with an HMAC compos cannot check yet), and the handler trusts no
;;; field of the body: it reads the issue again from the API. Each change is a
;;; linear event, kind issue-update, comment-create and so on, and redraws the
;;; open list and the issue's page.

(define (linear--webhook-issue-id j)
  (let ((d (plist-get j 'data)))
    (cond ((equal? (plist-get j 'type) "Comment") (or (plist-get d 'issueId) (plist-get (plist-get d 'issue) 'id)))
          ((equal? (plist-get j 'type) "Issue") (plist-get d 'id))
          (else #f))))

(define (linear--publish-change! id j source)
  (linear-gql "query($id: String!) { issue(id: $id) { id identifier title url updatedAt state { name type } assignee { name } team { key } } }"
    (list 'id id)
    (lambda (d)
      (let* ((i (and d (plist-get d 'issue)))
             (it (or i (plist-get j 'data) '()))
             (type (linear--s (or (plist-get j 'type) "Issue")))
             (action (linear--s (or (plist-get j 'action) "update"))))
        (event-publish! "linear" (string->symbol (string-downcase (string-append type "-" action)))
          (list 'id id
                'identifier (linear--s (plist-get it 'identifier))
                'title (linear--s (plist-get it 'title))
                'state (linear--s (and i (plist-get (plist-get i 'state) 'name)))
                'assignee (linear--s (and i (plist-get i 'assignee) (plist-get (plist-get i 'assignee) 'name)))
                'team (linear--s (and i (plist-get (plist-get i 'team) 'key)))
                'url (linear--s (and i (plist-get i 'url)))
                'actor (linear--s (and (plist-get j 'actor) (plist-get (plist-get j 'actor) 'name)))
                'source source))
        (when i
          (linear--seen! (plist-get i 'updatedAt))
          (let ((page (linear--issue-buffer i)))
            (when (buffer-exists? page) (linear--issue-read! page))))))))

;;;###autoload
(define (linear-webhook-handle key events)
  (let ((ids '()))
    (for-each (lambda (e)
                (let* ((j (plist-get e 'data)) (id (and (pair? j) (linear--webhook-issue-id j))))
                  (when (and id (not (member id ids)))
                    (set! ids (cons id ids))
                    (linear--publish-change! id j "webhook"))))
              events)
    (when (and (pair? ids) (buffer-exists? *linear-buffer*)) (linear--read! *linear-buffer*))))

(define (linear--hook-url)
  (let ((w (webhook-get "linear")))
    (and w webhooks-tunnel-host (string-append "https://" webhooks-tunnel-host (plist-get w 'path)))))

(define (linear-webhook-setup! k)
  (unless (webhook-get "linear")
    (define-webhook! "linear" (list 'path (string-append "/hooks/linear-" (substring (content-hash (format "~a ~a" (current-time) (monotonic-ms))) 0 32))
                                    'data 'json 'public #t))
    (webhook-attach-workflow! "linear" 'linear-webhook-handle)
    (webhooks--keep! "linear"))
  (let ((url (linear--hook-url)))
    (if (not url) (k (list 'error "no tunnel host"))
        (linear-gql "{ webhooks { nodes { id url enabled } } }" '()
          (lambda (d)
            (let ((have (filter (lambda (w) (equal? (plist-get w 'url) url)) (linear--nodes d 'webhooks))))
              (cond ((not d) (k (list 'error "could not list Linear's webhooks")))
                    ((pair? have) (k (list 'url url 'linear (plist-get (car have) 'id) 'new #f)))
                    (else
                     (linear-gql "mutation($input: WebhookCreateInput!) { webhookCreate(input: $input) { success webhook { id enabled } } }"
                       (list 'input (list 'url url 'label "compos" 'allPublicTeams #t 'resourceTypes (list "Issue" "Comment")))
                       (lambda (d2)
                         (let ((w (and d2 (plist-get (plist-get d2 'webhookCreate) 'webhook))))
                           (k (if w (list 'url url 'linear (plist-get w 'id) 'new #t) (list 'error "webhookCreate failed"))))))))))))))

(define-command "linear-webhook-setup" "Have Linear tell compos about every issue and comment change, through the webhook tunnel"
  (lambda ()
    (linear-webhook-setup!
      (lambda (r)
        (message (if (plist-get r 'error)
                     (string-append "Linear webhook: " (plist-get r 'error) " (see *linear-log*)")
                     (string-append "Linear webhook " (if (plist-get r 'new) "registered: " "already registered: ") (plist-get r 'url))))))))

;;; Sweep. While the computer is off, Linear's pushes are lost. Every 15
;;; minutes, and once at boot when a run was missed, every issue changed since
;;; the last change seen is published as if it had been pushed.

(define linear--seen-file (expand-file-name "~/.compos/linear-last-seen"))

(define (linear--last-seen)
  (and (file-exists? linear--seen-file)
       (let ((s (string-trim (read-file linear--seen-file)))) (and (not (equal? s "")) s))))

(define (linear--seen! iso)
  (let ((last (linear--last-seen)))
    (when (and (string? iso) (or (not last) (string>? iso last)))
      (write-file! linear--seen-file iso))))

(define (linear-sweep! &optional k)
  (let ((since (linear--last-seen)))
    (linear-gql "query($f: IssueFilter, $n: Int) { issues(first: $n, filter: $f, orderBy: updatedAt) { nodes { id updatedAt } } }"
      (if since (list 'f (list 'updatedAt (list 'gt since)) 'n 250) (list 'n 1))
      (lambda (d)
        (let ((ns (linear--nodes d 'issues)))
          (cond ((not d) (when k (k #f)))
                ;; the first sweep only marks where the record starts
                ((not since) (when (pair? ns) (linear--seen! (plist-get (car ns) 'updatedAt))) (when k (k 0)))
                (else
                 (for-each (lambda (n) (linear--publish-change! (plist-get n 'id) (list 'type "Issue" 'action "update") "sweep")) ns)
                 (when (and (pair? ns) (buffer-exists? *linear-buffer*)) (linear--read! *linear-buffer*))
                 (when k (k (length ns))))))))))

;;;###autoload
(define (linear-sweep-run event) (linear-sweep!))

(effects! '(write external))
(public! 'linear-gql
  "(linear-gql QUERY VARS K) — one Linear GraphQL call; K gets the data plist, or #f with the failure in *linear-log*")
(public! 'linear-sweep!
  "(linear-sweep! [K]) — publish a linear event for every issue changed since the last change seen; K gets the count")
(public! 'linear-webhook-setup!
  "(linear-webhook-setup! K) — make the linear webhook endpoint and register it on Linear; K gets (url URL linear ID new BOOL) or (error TEXT)")
(public! 'linear
  "M-x linear — Linear issues as an app: a list, one page per issue, status/assign/priority/comment/new")

(provide 'linear)
