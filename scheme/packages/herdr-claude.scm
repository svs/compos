;;; herdr-claude.scm --- Claude Code in a compos terminal.
;;;
;;; The Claude specifics of herdr-agent-mode (herdr-agent.scm). Claude Code
;;; reports its status as claude-code (OSC 7501), and its hooks call
;;; priv/agent-hook claude-code EVENT. SessionStart answers with the chat
;;; prompt; PreToolUse denies the tools that the claude-code connector
;;; refuses, and allows the compos MCP tools. Claude Code keeps its own
;;; choice of model.
;;;
;;; Setup, once per user: the two hooks in ~/.claude/settings.json, and the
;;; compos MCP server at user scope (claude mcp add --scope user compos --
;;; priv/native/compos-mcp-shim).

(domain! 'agents)
(effects! '(read))

(register-minor-mode! "herdr-claude-mode" (lambda (buf) #t))

(define (herdr-claude-answer event buf tool)
  (cond
    ((equal? event "SessionStart")
     (list 'hookSpecificOutput
           (list 'hookEventName "SessionStart"
                 'additionalContext (herdr-agent-context buf))))
    ((equal? event "PreToolUse")
     (let ((verdict (herdr-agent-tool-verdict buf tool)))
       (cond ((equal? verdict 'deny)
              (list 'hookSpecificOutput
                    (list 'hookEventName "PreToolUse"
                          'permissionDecision "deny"
                          'permissionDecisionReason (herdr-agent-refusal tool))))
             ((equal? verdict 'allow)
              (list 'hookSpecificOutput
                    (list 'hookEventName "PreToolUse" 'permissionDecision "allow")))
             (else #f))))
    (else #f)))

(define-herdr-harness! "claude-code"
  'mode "herdr-claude-mode"
  'connector "claude-code"
  ;; through the name, so a reload of the answer takes effect
  'answer (lambda (event buf tool) (herdr-claude-answer event buf tool))
  ;; the ACP adapter takes the list as the SDK option disallowedTools
  'refused-tools (lambda (conf)
                   (or (plist-get (plist-get (plist-get (plist-get conf 'meta) 'claudeCode)
                                             'options)
                                  'disallowedTools)
                       '()))
  'compos-tool? (lambda (tool) (string-prefix? "mcp__compos__" tool)))
