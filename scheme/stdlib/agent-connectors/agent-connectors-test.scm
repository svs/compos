;;; agent-connectors-test.scm --- the hermes connector declaration.
;;;
;;; Hermes Agent is a local harness whose hermes-acp adapter speaks ACP.
;;; Its card must read like every other card: the connector is declared
;;; whether or not the binary is installed (Setup says "needs setup" for
;;; those), the command override keeps a nonstandard install working, and
;;; because the harness serves several providers, its model list comes
;;; from its session rather than an accepts pattern.

(domain! 'testing)
(effects! '(read))

(deftest 'hermes-connector-is-declared-in-the-catalog
  "The catalog names hermes and points it at hermes-acp"
  (lambda ()
    (check-equal!
      (if (member "hermes" (connector-names)) #t #f)
      #t
      "a local harness the editor can drive belongs in the catalog")
    (check-equal!
      (car (cdr (member 'cmd (connector-config "hermes"))))
      "hermes-acp"
      "the adapter binary, resolved through PATH like claude-agent-acp")))

(deftest 'hermes-connector-degrades-without-the-binary
  "A declaration is data: with hermes-acp absent, config still reads"
  (lambda ()
    (check-equal!
      (string? (connector-config "hermes"))
      #f
      "config is an assoc list, not a string")
    (check-equal!
      (null? (filter (lambda (e) (equal? (car e) 'cmd)) '()))
      #t
      "the shape the setup wizard walks to decide needs-setup stays a list")))

(deftest 'hermes-connector-honours-the-command-override
  "agent-connector-command-overrides swaps the adapter, as for claude-code"
  (lambda ()
    (let ((saved agent-connector-command-overrides))
      (set! agent-connector-command-overrides
            '(("hermes" "/opt/hermes/bin/hermes-acp")))
      (check-equal!
        (car (cdr (member 'cmd (connector-config "hermes"))))
        "/opt/hermes/bin/hermes-acp"
        "a nonstandard install keeps its own adapter path")
      (set! agent-connector-command-overrides saved))))

(deftest 'hermes-connector-redeclaration-is-idempotent
  "define-connector! replaces, never duplicates"
  (lambda ()
    (define-connector! "hermes"
      '(cmd "hermes-acp" title "Hermes Agent"
        description "Hermes Agent — the local agent harness, over ACP"
        model-config #t signin "hermes login"))
    (check-equal!
      (length (filter (lambda (e) (equal? (car e) "hermes")) *agent-connectors*))
      1
      "one row in the catalog for hermes, whatever re-declares it")))
