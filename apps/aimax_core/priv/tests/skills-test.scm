;;; skills-test.scm --- skills.scm: the skill catalog and the sanitized
;;; Codex home.
;;;
;;; Two tests stay in ExUnit: they build skill directories on disk, and
;;; this Scheme has make-directory! but no way to remove one.

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
  "an aimax-tools chat learns the skills exist"
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

(deftest 'the-api-lane-keeps-its-own-environment
  "only the codex lane reads a codex home"
  (lambda ()
    (check-false! (plist-get (agent-resolve-config '(connector "api")) 'env)
                  "the api lane adds nothing")))
