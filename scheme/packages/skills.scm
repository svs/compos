;;; skills.scm --- the skill catalog: working instructions loaded on demand.
;;;
;;; A skill is one directory that holds SKILL.md: frontmatter (name,
;;; description) and a body of working instructions. The canonical list is
;;; the catalog. The loader scans priv/skills, then ~/.compos/skills as a
;;; user overlay — the same name wins. Every consumer derives from it:
;;;
;;;   - (skills) lists name and description; (skill NAME) returns the body.
;;;   - A group adds its own skills on top (see group skills below).
;;;   - The chat system prompt carries a one-line index (skills-note,
;;;     appended by chat-tool-system in packages/mcp.scm).
;;;   - The sanitized Codex home renders the same list, so a
;;;     codex-app-server thread sees ONLY these skills — never the user's
;;;     own ~/.codex state (codex-config-with-env, called by
;;;     agent-resolve-config).
;;;
;;; Codex also finds skills of its own (a project's .agents/skills, the
;;; user's ~/.agents/skills, its system skills); the sanitized home's
;;; config.toml turns each of them off (codex-skills-disable!).

(domain! 'chat)
(effects! '(read))

;;; --- the catalog ---------------------------------------------------------------

;; (name description dir), newest registration wins by name
(define *skills* '())

;; -> (name description body), any of the first two #f when the
;; frontmatter does not say
(define (skills--parse text)
  (let ((lines (string-split text "\n")))
    (if (or (null? lines) (not (equal? (string-trim (car lines)) "---")))
        (list #f #f text)
        (let loop ((ls (cdr lines)) (name #f) (desc #f))
          (cond ((null? ls) (list name desc text))
                ((equal? (string-trim (car ls)) "---")
                 (list name desc (string-trim (string-join (cdr ls) "\n"))))
                ((string-prefix? "name:" (car ls))
                 (loop (cdr ls)
                       (string-trim (substring (car ls) 5 (string-length (car ls))))
                       desc))
                ((string-prefix? "description:" (car ls))
                 (loop (cdr ls) name
                       (string-trim (substring (car ls) 12 (string-length (car ls))))))
                (else (loop (cdr ls) name desc)))))))

(define (skills--roots)
  (list (string-append (compos-priv-dir) "/skills")
        (string-append (compos-home) "/skills")))

(define (skills--register root entry entries)
  (let* ((dirname (substring entry 0 (- (string-length entry) 1)))
         (dir (string-append root "/" dirname))
         (file (string-append dir "/SKILL.md"))
         (text (and (file-exists? file) (read-file file))))
    (if text
        (let* ((parsed (skills--parse text))
               (name (or (car parsed) dirname))
               (desc (or (cadr parsed) "")))
          (cons (list name desc dir)
                (remove (lambda (s) (equal? (car s) name)) entries)))
        entries)))

;; ENTRIES with every skill under ROOTS registered over it, in order
(define (skills--scan-roots roots entries)
  (for-each
    (lambda (root)
      (when (file-exists? root)
        (for-each
          (lambda (entry)
            (when (string-suffix? "/" entry)
              (set! entries (skills--register root entry entries))))
          (list-dir root))))
    roots)
  entries)

(define (skills-scan!)
  (set! *skills* (skills--scan-roots (skills--roots) '()))
  (set! *group-skills* '())
  (for-each
    (lambda (s)
      ;; explicit stamps: a runtime rescan must not inherit whatever
      ;; domain/effects/package scope the caller stands in
      (catalog-register! 'skill (car s) (cadr s)
                         'domain 'chat 'effects '(pure)
                         'package 'skills 'namespace 'skills))
    *skills*)
  (skills-note-build!)
  (length *skills*))

;;; --- group skills ----------------------------------------------------------------
;;; A group adds the skills in its home, <group-home>/skills, and in its
;;; directory's .claude/skills. They stay out of the global catalog: only
;;; the group's chats see them, in their index and through (skill NAME).
;;; The home wins over .claude, and both win over the global catalog.

(define (skills-group-roots g)
  (let* ((id (and g (group-resolve-id g)))
         (record (and id (group-record-by-id id)))
         (origin (and record (group-record-origin record))))
    (if (not id)
        '()
        (append
          (if (and origin (file-directory? origin))
              (list (string-append origin "/.claude/skills"))
              '())
          (list (string-append (group-home-dir id) "/skills"))))))

;; group id -> #f, or (entries note notes-without) when the group has
;; skills of its own. Scanned on the first ask; skills-scan! drops them.
(define *group-skills* '())

(define (skills--group g)
  (let* ((id (and g (group-resolve-id g)))
         (hit (and id (assoc id *group-skills*))))
    (cond
      ((not id) #f)
      (hit (cadr hit))
      (else
        (let* ((own (skills--scan-roots (skills-group-roots id) '()))
               (entries (skills--scan-roots (skills-group-roots id) *skills*))
               (set (if (null? own) #f (cons entries (skills--notes entries)))))
          (set! *group-skills* (cons (list id set) *group-skills*))
          set)))))

;; the skills the current buffer's chat can load
(define (skills--here)
  (let ((set (skills--group (buffer-group (current-buffer)))))
    (if set (car set) *skills*)))

(define (skills)
  (map (lambda (s) (list (car s) (cadr s))) (reverse (skills--here))))

(define (skill name)
  (let* ((n (if (symbol? name) (symbol->string name) name))
         (entries (skills--here))
         (s (assoc n entries)))
    (if s
        (caddr (skills--parse (read-file (string-append (caddr s) "/SKILL.md"))))
        (string-append "no such skill: " n "; available: "
                       (string-join (map car (reverse entries)) ", ")))))

;; The index a system prompt carries: one line per skill, nothing more —
;; the body loads on demand. The string is built ONCE per scan:
;; skills-note runs on the turn-start path, and per-call allocation there
;; loses the cross-lane flush race (see agent-resolve-config).
(define *skills-note* "")
(define *skills-notes-without* '())

(define (skills-note) *skills-note*)

(define (skills-note-format entries)
  (if (null? entries)
      ""
      (string-append
        "SKILLS — working instructions on demand:\n"
        (string-join
          (map (lambda (s)
                 (string-append "  (skill \"" (car s) "\")  " (cadr s)))
               (reverse entries))
          "\n")
        "\nLoad a skill with eval-scheme before you start its task.")))

(define (skills--notes entries)
  (list (skills-note-format entries)
        ;; contextual variants, built once. Turn-start reads must not
        ;; allocate them.
        (map (lambda (excluded)
               (list (car excluded)
                     (skills-note-format
                       (remove (lambda (s) (equal? (car s) (car excluded)))
                               entries))))
             entries)))

(define (skills-note-build!)
  (let ((notes (skills--notes *skills*)))
    (set! *skills-note* (car notes))
    (set! *skills-notes-without* (cadr notes))))

(define (skills-note-without name)
  (let* ((n (if (symbol? name) (symbol->string name) name))
         (hit (assoc n *skills-notes-without*)))
    (if hit
        (cadr hit)
        *skills-note*)))

;; The index BUF's chat carries: the global one, or its group's when the
;; group has skills of its own. WITHOUT names an active skill to leave
;; out, or is #f.
(define (skills-note-for buf without)
  (let* ((set (skills--group (and buf (buffer-known? buf) (buffer-group buf))))
         (note (if set (cadr set) *skills-note*))
         (withouts (if set (caddr set) *skills-notes-without*))
         (hit (and without (assoc without withouts))))
    (if hit (cadr hit) note)))

(skills-scan!)

(public! 'skills "(skills) — every skill as (NAME DESCRIPTION)")
(public! 'skill "(skill NAME) — the working instructions of one skill")
(public! 'skills-note "(skills-note) — the one-line-per-skill index a system prompt carries")
(public! 'skills-note-without
  "(skills-note-without NAME) — the cached skill index without one active skill")
(public! 'skills-note-for
  "(skills-note-for BUF WITHOUT) — the skill index BUF's chat carries: the global one, or its group's; WITHOUT is an active skill to leave out, or #f")
(public! 'skills-group-roots
  "(skills-group-roots G) — the directories G takes skills from: <dir>/.claude/skills, then <group-home>/skills")
(effects! '(write))
(public! 'skills-scan!
  "(skills-scan!) — rescan priv/skills and ~/.compos/skills into the catalog, and drop every group's skills to rescan on the next ask")

;;; --- the sanitized Codex home --------------------------------------------------
;;; codex reads its per-user state — config, auth, global instructions,
;;; skills — from CODEX_HOME. The editor gives it a home it owns instead
;;; of ~/.codex, so the user's personal config and skills never reach an
;;; editor thread. auth.json is copied in once so the subscription login
;;; still works, and the skill catalog is rendered in so the thread's
;;; skills are exactly the canonical list.

(defcustom 'codex-home-sanitized #t
  "Give codex-app-server threads an editor-owned CODEX_HOME with the catalog's skills. Set #f to let codex read ~/.codex."
  'group 'chat 'type 'boolean)

(defcustom 'codex-scrub-env '("OPENAI_API_KEY" "OPENAI_BASE_URL")
  "Environment variables removed from a codex-app-server subprocess. Auth then always comes from the sanitized home's auth.json."
  'group 'chat 'type 'list)

(define (codex-home) (string-append (compos-home) "/codex-home"))

;; rendered once per daemon; a skills-scan! or reload starts fresh
(define *codex-home-ready* #f)

(define (skills-render-into! home)
  ;; the rendered set must EQUAL the catalog. A skill that left the
  ;; catalog loses its SKILL.md here, so codex cannot load it again.
  ;; No subprocess: this runs inside the session lane, and a shell call
  ;; costs a second the send path does not have.
  (let ((dir (string-append home "/skills")))
    (when (file-exists? dir)
      (for-each
        (lambda (entry)
          (when (and (string-suffix? "/" entry)
                     (not (assoc (substring entry 0 (- (string-length entry) 1))
                                 *skills*)))
            ;; only a SKILL.md that exists: codex keeps its own state
            ;; directories here (.system), and a raise on a missing file
            ;; would fail every send to a codex thread
            (let ((f (string-append dir "/" entry "SKILL.md")))
              (when (file-exists? f)
                (delete-file! f)))))
        (list-dir dir)))
    (for-each
      (lambda (s)
        (let ((text (read-file (string-append (caddr s) "/SKILL.md"))))
          (when text
            (write-file! (string-append dir "/" (car s) "/SKILL.md") text))))
      *skills*)))

(define (codex-home-ensure!)
  (unless *codex-home-ready*
    (let ((home (codex-home)))
      (skills-render-into! home)
      ;; login once through the real codex; copy, do not symlink — codex
      ;; rewrites auth.json on token refresh, and a rename-over-symlink
      ;; would silently fork the user's session file
      (let ((auth (string-append home "/auth.json")))
        (unless (file-exists? auth)
          (let ((src (read-file "~/.codex/auth.json")))
            (when src (write-file! auth src)))))
      (set! *codex-home-ready* #t)
      home)))

;; agent-resolve-config calls this for every codex-app-server thread:
;; point the subprocess at the sanitized home and scrub the variables
;; that would change its behavior. A #f value deletes the variable.
(define (codex-config-with-env conf)
  (if (not codex-home-sanitized)
      conf
      (begin
        (codex-home-ensure!)
        (codex-skills-disable! (plist-get conf 'cwd))
        (append
          (list 'env
                (append (list (list "CODEX_HOME" (codex-home)))
                        (map (lambda (v) (list v #f)) codex-scrub-env)
                        (or (plist-get conf 'env) '())))
          conf))))

;;; Codex finds skills of its own beside CODEX_HOME/skills: .agents/skills
;;; in every directory from the cwd up to the git root, ~/.agents/skills,
;;; /etc/codex/skills, and the system skills it keeps in skills/.system.
;;; The sanitized home's config.toml turns each of them off by path, so a
;;; thread sees the catalog and nothing else. Every thread shares the home,
;;; so the list only grows: a path turned off for one cwd stays off for
;;; the next. Codex reads the file as the process starts, and this runs
;;; before the backend opens it.

(define *codex-disabled* '())

;; every <root>/*/SKILL.md
(define (codex--skill-files root)
  (let ((out '()))
    (when (file-exists? root)
      (for-each
        (lambda (entry)
          (when (string-suffix? "/" entry)
            (let ((f (string-append root "/" entry "SKILL.md")))
              ;; codex may record either name of a linked skill, so
              ;; both go in
              (when (file-exists? f)
                (let ((real (file-realpath f)))
                  (set! out (cons f out))
                  (when (and (string? real) (not (equal? real f)))
                    (set! out (cons real out))))))))
        (list-dir root)))
    (reverse out)))

(define (codex--trim-slash d)
  (if (and (> (string-length d) 1) (string-suffix? "/" d))
      (substring d 0 (- (string-length d) 1))
      d))

;; CWD and each parent up to its git root; CWD alone outside a repository
(define (codex--dirs-up cwd)
  (let ((top (let ((r (git-root cwd))) (and (string? r) (codex--trim-slash r)))))
    (let loop ((d (codex--trim-slash cwd)) (acc '()))
      (let ((acc (cons d acc)))
        (if (or (not top) (equal? d top) (<= (string-length d) (string-length top)))
            (reverse acc)
            (loop (string-join (reverse (cdr (reverse (string-split d "/")))) "/")
                  acc))))))

(define (codex-foreign-skills cwd)
  (apply append
    (map codex--skill-files
      (append
        (list (string-append (codex-home) "/skills/.system")
              (string-append (expand-path "~") "/.agents/skills")
              "/etc/codex/skills")
        (if cwd
            (map (lambda (d) (string-append d "/.agents/skills")) (codex--dirs-up cwd))
            '())))))

(define (codex--toml-string s)
  (string-append "\""
                 (string-join (string-split (string-join (string-split s "\\") "\\\\") "\"")
                              "\\\"")
                 "\""))

(define (codex-config-toml paths)
  (string-append
    "# compos writes this file. A codex thread sees the editor's skills only.\n"
    (string-join
      (map (lambda (p)
             (string-append "\n[[skills.config]]\npath = " (codex--toml-string p)
                            "\nenabled = false\n"))
           paths)
      "")))

(define (codex-skills-disable! cwd)
  (let ((new (remove (lambda (p) (member p *codex-disabled*))
                     (codex-foreign-skills cwd))))
    (unless (null? new)
      (set! *codex-disabled* (append *codex-disabled* new))
      (write-file! (string-append (codex-home) "/config.toml")
                   (codex-config-toml *codex-disabled*)))
    *codex-disabled*))

(public! 'codex-home-ensure!
  "(codex-home-ensure!) — render the sanitized Codex home: catalog skills plus a copied auth.json")
(public! 'codex-config-with-env
  "(codex-config-with-env CONF) — the codex thread config with the sanitized CODEX_HOME environment")
(public! 'codex-skills-disable!
  "(codex-skills-disable! CWD) — turn off, in the sanitized home's config.toml, every skill codex would find beside the catalog; the paths turned off")
(public! 'codex-foreign-skills
  "(codex-foreign-skills CWD) — the SKILL.md paths codex finds on its own: .agents/skills up to the git root, ~/.agents/skills, /etc/codex/skills, skills/.system")
(effects! '(pure))
(public! 'codex-home "(codex-home) — the editor-owned CODEX_HOME directory")

;;; --- the sanitized DeepSeek Harness home ---------------------------------------
;;; The harness reads its per-user state — settings, provider keys, skills,
;;; profiles — from DSH_HOME. The editor gives it a home it owns instead of
;;; ~/.dsh, so the user's personal config never reaches an editor thread.
;;; The home also carries the profile, and the profile carries the patch
;;; that turns the harness's own tools off: the editor names every tool
;;; through MCP, so a tool the editor did not name has no way in. The
;;; harness keeps its own persona, and a project's own .agents/skills stays
;;; native here, the same as for codex.

(effects! '(write))

(defcustom 'dsh-home-sanitized #t
  "Give DeepSeek Harness threads an editor-owned DSH_HOME with the catalog's skills. Set #f to let the harness read ~/.dsh."
  'group 'chat 'type 'boolean)

(defcustom 'dsh-disabled-plugins
  '("tool-bash" "tool-pwsh" "tool-jobs"
    "tool-fs" "tool-fs-search" "tool-str-replace-editor"
    "tool-web" "tool-todo" "tool-goal" "tool-ralph" "tool-workflow"
    "tool-subagent" "tool-subagent-control" "tool-subagent-list-agents"
    "tool-subagent-fork"
    ;; not spelled tool-, but it serves exit_plan_mode
    "plan-mode")
  "DeepSeek Harness plugins an editor thread turns off, by entry id. Each one adds a tool the editor did not name. tool-skill stays on: what it reads is the editor's own catalog."
  'group 'chat 'type 'list)

(define (dsh-home) (string-append (compos-home) "/dsh-home"))

;; rendered once per daemon; a reload of this file starts fresh
(define *dsh-home-ready* #f)

;; the profile names its bundles, so the harness never writes its own
(define dsh-profile-manifest
  "{\n  \"name\": \"dsh-profile-acp\",\n  \"private\": true,\n  \"dependencies\": {},\n  \"dsh\": {\n    \"profile\": {\n      \"bundles\": [\"@deepseek-ai/dsh-base\", \"@deepseek-ai/dsh-acp-app\"],\n      \"patchReload\": \"startup\"\n    }\n  }\n}\n")

(define (dsh-profile-patch)
  (string-append
    "# compos writes this file. The editor names every tool the thread has,\n"
    "# so the harness adds none of its own.\n"
    (string-join
      (map (lambda (id) (string-append "- id: " id "\n  disabled: true"))
           dsh-disabled-plugins)
      "\n")
    "\n"))

;; the editor's key chain is the one source: the harness resolves the name,
;; and dsh-config-with-env puts the value in the subprocess environment.
(define (dsh-settings)
  (string-append
    "# compos writes this file.\n"
    "llm-pi-ai:\n"
    "  providers:\n"
    "    deepseek-official:\n"
    "      apiKeyEnv: DEEPSEEK_API_KEY\n"))

(define (dsh-home-ensure!)
  (unless *dsh-home-ready*
    (let ((home (dsh-home)))
      (skills-render-into! home)
      (write-file! (string-append home "/profiles/acp/package.json")
                   dsh-profile-manifest)
      (write-file! (string-append home "/profiles/acp/compos.patch.yml")
                   (dsh-profile-patch))
      (if (llm-key "deepseek")
          (write-file! (string-append home "/settings.yaml") (dsh-settings))
          ;; no registered key: fall back to the credentials the harness
          ;; wrote for itself, copied once, so a thread still authenticates
          (let ((creds (string-append home "/.credentials.yaml")))
            (unless (file-exists? creds)
              (let ((src (read-file "~/.dsh/.credentials.yaml")))
                (when src (write-file! creds src))))))
      (set! *dsh-home-ready* #t)
      home)))

;; agent-resolve-config calls this for every thread whose connector declares
;; 'sanitize "dsh": point the subprocess at the editor's home and hand it
;; the key by name. A #f value deletes the variable.
(define (dsh-config-with-env conf)
  (if (not dsh-home-sanitized)
      conf
      (begin
        (dsh-home-ensure!)
        (append
          (list 'env
                (append (list (list "DSH_HOME" (dsh-home)))
                        (let ((k (llm-key "deepseek")))
                          (if k (list (list "DEEPSEEK_API_KEY" k)) '()))
                        (or (plist-get conf 'env) '())))
          conf))))

(public! 'dsh-home-ensure!
  "(dsh-home-ensure!) — render the sanitized DeepSeek Harness home: catalog skills, the editor's profile and its patch")
(public! 'dsh-config-with-env
  "(dsh-config-with-env CONF) — the harness thread config with the sanitized DSH_HOME environment")
(effects! '(pure))
(public! 'dsh-home "(dsh-home) — the editor-owned DSH_HOME directory")
