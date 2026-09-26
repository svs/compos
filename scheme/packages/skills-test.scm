;;; skills-test.scm --- skills.scm: the skill catalog and the sanitized
;;; Codex home.
;;;
;;; The two directory tests came here from ExUnit. A test builds its own
;;; skill directory under (compos-home) and removes it with
;;; shell-command->string, so nothing is left behind.

(domain! 'testing)
(effects! '(read))

(define (t--skill-names entries) (map (lambda (e) (plist-get e 'name)) entries))

(effects! '(write))

(deftest 'the-loader-scans-priv-skills-into-the-catalog
  "a skill is a catalog kind like any other"
  (lambda ()
    (check-true! (assoc "code-editing" (skills)) "the listing names it")
    (let ((entry (catalog-entry 'skill "code-editing")))
      (check-equal! (plist-get entry 'kind) "skill" "the kind")
      (check-contains! (plist-get entry 'doc) "Load before the first code edit" "the doc"))))

(deftest 'a-skill-returns-the-body-without-the-frontmatter
  "the frontmatter is for the loader, not for the reader"
  (lambda ()
    (let ((body (skill "code-editing")))
      (check-contains! body "code-outline" "the body")
      (check-contains! body "smallest edit" "more of the body")
      (check-false! (string-contains? body "description:") "no frontmatter"))))

(deftest 'an-unknown-skill-answers-with-the-available-names
  "a miss names what there is"
  (lambda ()
    (check-contains! (skill "zz-none") "no such skill" "the miss")
    (check-contains! (skill "zz-none") "code-editing" "and the names")))

(deftest 'skills-note-indexes-every-skill-one-line-each
  "the index tells the agent how to load one"
  (lambda ()
    (let ((note (skills-note)))
      (check-contains! note "(skill \"code-editing\")" "the call to load one")
      (check-contains! note "Load a skill with eval-scheme" "the instruction"))))

(deftest 'skills-note-without-hides-an-active-skill
  "a skill already loaded is not offered again"
  (lambda ()
    (check-false! (string-contains? (skills-note-without "code-editing")
                                    "(skill \"code-editing\")")
                  "the active skill is not in the on-demand index")))

(deftest 'the-chat-system-prompt-carries-the-index
  "an compos-tools chat learns the skills exist"
  (lambda ()
    (test-buffer! "*zz-sk-chat*" "")
    (check-contains! (chat-tool-system "*zz-sk-chat*") "SKILLS" "the section")
    (buffer-kill! "*zz-sk-chat*")))

(deftest 'codex-config-with-env-points-at-the-sanitized-home
  "codex reads our skills, and never our keys"
  (lambda ()
    (let ((env (plist-get (codex-config-with-env '(backend "codex-app-server")) 'env)))
      (check-true! (assoc "CODEX_HOME" env) "the home is named")
      (check-equal! (assoc "OPENAI_API_KEY" env) '("OPENAI_API_KEY" #f) "the key is scrubbed"))
    (check-true! (file-exists? (string-append (codex-home) "/skills/code-editing/SKILL.md"))
                 "the skill is rendered into the home")))

(deftest 'agent-resolve-config-gives-every-codex-thread-the-sanitized-env
  "one resolution point, so no thread misses it"
  (lambda ()
    (check-true! (assoc "CODEX_HOME"
                        (plist-get (agent-resolve-config '(connector "codex-app-server")) 'env))
                 "the home is named")))

(deftest 'codex-home-sanitized-false-leaves-the-config-alone
  "the sweep is a setting, and off means off"
  (lambda ()
    (customize-set! 'codex-home-sanitized #f)
    (check-false! (plist-get (codex-config-with-env '(backend "codex-app-server")) 'env)
                  "no environment is added")
    (customize-set! 'codex-home-sanitized #t)))

(deftest 'dsh-config-with-env-points-at-the-sanitized-home
  "the harness reads our skills and our key, and never the user's ~/.dsh"
  (lambda ()
    (let ((env (plist-get (dsh-config-with-env '(sanitize "dsh")) 'env)))
      (check-true! (assoc "DSH_HOME" env) "the home is named"))
    (check-true! (file-exists? (string-append (dsh-home) "/skills/code-editing/SKILL.md"))
                 "the skill is rendered into the home")
    (check-true! (file-exists? (string-append (dsh-home) "/profiles/acp/package.json"))
                 "the editor owns the profile")))

(deftest 'the-dsh-profile-patch-turns-the-harnesss-own-tools-off
  "the editor names every tool through MCP, so the harness adds none"
  (lambda ()
    (let ((patch (dsh-profile-patch)))
      (check-false! (string-contains? patch "system-prompt")
                    "the harness keeps its own persona")
      (for-each
        (lambda (id)
          (check-contains! patch (string-append "- id: " id "\n  disabled: true")
                           (string-append id " is off")))
        dsh-disabled-plugins))))

(deftest 'agent-resolve-config-gives-every-harness-thread-the-sanitized-env
  "one resolution point, so no thread misses it"
  (lambda ()
    (check-true! (assoc "DSH_HOME"
                        (plist-get (agent-resolve-config '(connector "deepseek")) 'env))
                 "the home is named")))

(deftest 'dsh-home-sanitized-false-leaves-the-config-alone
  "the sweep is a setting, and off means off"
  (lambda ()
    (customize-set! 'dsh-home-sanitized #f)
    (check-false! (plist-get (dsh-config-with-env '(sanitize "dsh")) 'env)
                  "no environment is added")
    (customize-set! 'dsh-home-sanitized #t)))

(deftest 'the-api-lane-keeps-its-own-environment
  "only the codex lane reads a codex home"
  (lambda ()
    (check-false! (plist-get (agent-resolve-config '(connector "api")) 'env)
                  "the api lane adds nothing")))

;;; --- the catalog reads directories, so these tests build one ----------------

(define t--skill-dir (string-append (compos-home) "/skills/zz-user-skill"))

(define (t--skill-write! body)
  (write-file! (string-append t--skill-dir "/SKILL.md")
               (string-append "---\nname: zz-user-skill\n"
                              "description: A user skill for the test.\n---\n\n"
                              body "\n")))

(deftest 'a-user-skill-in-the-home-joins-the-catalog-and-wins-by-name
  "the home directory is a source like priv/skills, and it is read last"
  (lambda ()
    (shell-command->string (string-append "mkdir -p " t--skill-dir))
    (t--skill-write! "The user's own instructions.")
    (skills-scan!)
    (check-true! (assoc "zz-user-skill" (skills)) "the listing names it")
    (check-contains! (skill "zz-user-skill") "The user's own instructions." "the body")

    ;; the body comes off disk at every call, so an edit needs no rescan
    (t--skill-write! "Changed on disk after the scan.")
    (check-contains! (skill "zz-user-skill") "Changed on disk after the scan."
                     "the body after the edit")

    (shell-command->string (string-append "rm -rf " t--skill-dir))
    (skills-scan!)
    (check-false! (assoc "zz-user-skill" (skills)) "and it leaves no row")))

(deftest 'codex-finds-a-projects-own-skill-and-the-config-turns-it-off
  "a project's .agents/skills is foreign to the catalog, and config.toml disables it by path"
  (lambda ()
    (let* ((dir (string-append (compos-home) "/zz-codex-project"))
           (file (string-append dir "/.agents/skills/zz-foreign/SKILL.md")))
      (write-file! file "---\nname: zz-foreign\ndescription: not ours\n---\n")
      (check-true! (member file (codex-foreign-skills dir)) "the project's skill is found")
      (let ((toml (codex-config-toml (list file))))
        (check-contains! toml "[[skills.config]]" "one entry")
        (check-contains! toml (string-append "path = \"" file "\"") "by its path")
        (check-contains! toml "enabled = false" "turned off"))
      (delete-file! file))))

(deftest 'a-group-skill-reaches-only-the-groups-chats
  "<group-home>/skills joins the index and (skill NAME) inside the group, and nowhere else"
  (lambda ()
    (let* ((id (group-record-create! "zz-skills-group"))
           (file (string-append (group-home-dir id) "/skills/zz-group-skill/SKILL.md"))
           (inside "*zz-skills-inside*")
           (outside "*zz-skills-outside*"))
      (write-file! file
                   "---\nname: zz-group-skill\ndescription: A group skill.\n---\n\nThe group's own.\n")
      (skills-scan!)
      (buffer-create inside)
      (buffer-add-group! inside id)
      (buffer-create outside)
      (check-contains! (skills-note-for inside #f) "zz-group-skill" "the group's index names it")
      (check-contains! (skills-note-for inside #f) "code-editing" "beside the global skills")
      (check-false! (string-contains? (skills-note-for outside #f) "zz-group-skill")
                    "another buffer's index does not")
      (check-contains! (with-current-buffer inside (lambda () (skill "zz-group-skill")))
                       "The group's own." "the body inside the group")
      (check-contains! (with-current-buffer outside (lambda () (skill "zz-group-skill")))
                       "no such skill" "and a miss outside it")
      (check-false! (assoc "zz-group-skill" *skills*) "the global catalog stays as it was")
      (buffer-kill! inside)
      (buffer-kill! outside)
      (delete-file! file)
      (group-record-delete! id)
      (skills-scan!))))

(deftest 'the-sweep-keeps-codexs-own-state-dirs-and-still-drops-a-stale-skill
  "codex writes under .system, which carries no SKILL.md of its own"
  (lambda ()
    ;; its own home, never (codex-home): the sweep deletes what it does not
    ;; recognise, and in a live editor that is the person's real codex state
    (let* ((home (string-append (compos-home) "/zz-codex-home"))
           (system (string-append home "/skills/.system/imagegen"))
           (stale (string-append home "/skills/zz-stale")))
      (shell-command->string (string-append "rm -rf " home))
      (shell-command->string (string-append "mkdir -p " system))
      (shell-command->string (string-append "mkdir -p " stale))
      (write-file! (string-append stale "/SKILL.md") "gone soon")

      (skills-render-into! home)

      (check-true! (file-exists? system) "the .system directory survives the sweep")
      (check-false! (file-exists? (string-append stale "/SKILL.md"))
                    "and the stale skill does not")
      (check-true! (file-exists? (string-append home "/skills/code-editing/SKILL.md"))
                   "the bundled skills are rendered in its place")

      (shell-command->string (string-append "rm -rf " home)))))
