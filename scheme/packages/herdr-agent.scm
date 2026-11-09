;;; herdr-agent.scm --- an agent in a terminal works as a compos chat does.
;;;
;;; Every terminal gives its shell an agent slug and the sockets of this
;;; daemon (term-environment-functions, comint.scm). When an agent starts
;;; in the terminal, the terminal turns on herdr-agent-mode and the mode of
;;; the agent's harness, such as herdr-claude-mode (herdr-claude.scm).
;;;
;;; herdr-agent-mode holds what every harness shares: the slug, the chat
;;; prompt of the terminal's group, and the tools that the harness's
;;; connector refuses. A harness mode holds how its harness speaks: the
;;; shape of its hook answers and the names of its tools.
;;;
;;; A harness says that it started in two ways, and the first one wins: its
;;; hook calls the daemon (priv/agent-hook), or it reports its status with
;;; OSC 7501 (term-status). The modes turn off when the agent exits. A mode
;;; that you turn off stays off until the agent exits.

(domain! 'agents)
(effects! '(read))

;;; --- the harnesses ------------------------------------------------------------

;; (define-herdr-harness! NAME 'mode MODE 'connector CONNECTOR 'answer FN
;;                        ['refused-tools FN] ['compos-tool? PRED])
;; NAME is the app name the harness reports with OSC 7501 and passes to
;; priv/agent-hook. FN takes (EVENT BUF TOOL) and answers the plist that
;; the hook prints as JSON, or #f for no answer.
(define (define-herdr-harness! name &rest opts)
  (registry-register! 'herdr-harness name opts))

(define (herdr-harness name) (registry-lookup 'herdr-harness name))
(define (herdr-harness-get name key) (plist-get (or (herdr-harness name) '()) key))

;;; --- the slug and the environment --------------------------------------------

;; one slug per terminal. It stays with the buffer, so the next session in
;; the shell writes as the same author. The buffer's name can change, as a
;; session title renames the shell; the slug does not.
(define (herdr-agent-slug buf)
  (or (buffer-local-value 'herdr-agent-slug buf)
      (let ((slug (string-append "term-" (number->string (random 1000000000)))))
        (buffer-set-local! buf 'herdr-agent-slug slug)
        slug)))

;; the terminal whose shell has SLUG, or #f
(define (herdr-agent-terminal slug)
  (find (lambda (b) (equal? (buffer-local-value 'herdr-agent-slug b) slug)) (buffer-list)))

(add-hook! '(term-environment-functions herdr-agent)
  (lambda (buf)
    (let ((sock (compos-socket-path)))
      (list (list "COMPOS_AGENT" (herdr-agent-slug buf))
            (list "COMPOS_SOCK" sock)
            (list "COMPOS_MCP_SOCK" (string-append sock "-mcp"))))))

;;; --- what every harness shares -----------------------------------------------

(define (herdr-agent-bundle buf)
  (let ((g (buffer-group buf)))
    (or (and g (llm-group-bundle g)) llm-default-bundle)))

;; the tools that the harness's connector refuses in a chat. Each connector
;; keeps the list in its own shape, so the harness reads it ('refused-tools)
(define (herdr-agent-refused-tools harness)
  (let ((read (herdr-harness-get harness 'refused-tools)))
    (if read (read (connector-config (herdr-harness-get harness 'connector))) '())))

;; deny for a tool that a chat refuses, allow for a compos tool, whose
;; call the daemon's own gate decides; #f leaves the tool to the harness
(define (herdr-agent-tool-verdict buf tool)
  (let* ((harness (buffer-local-value 'herdr-agent-harness buf))
         (compos? (or (herdr-harness-get harness 'compos-tool?) (lambda (t) #f))))
    (cond ((member tool (herdr-agent-refused-tools harness)) 'deny)
          ((compos? tool) 'allow)
          (else #f))))

(define (herdr-agent-refusal tool)
  (string-append tool " is off in a compos terminal, as in a compos chat. "
                 "Use the compos MCP tools: read-file and code-read to read, "
                 "eval-scheme to edit, save, and run commands."))

;; the prompt that a chat of this terminal's group gets, and where the agent is
(define (herdr-agent-context buf)
  (let* ((presets (or (plist-get (herdr-agent-bundle buf) 'presets) '(compos)))
         (parts (agent-live-system-prompt-parts (list 'presets presets)))
         (g (buffer-group buf))
         (where (string-append "You run in the compos terminal " buf
                               (if g (string-append ", in the group " (group-name g)) "")
                               ". Your agent slug is " (herdr-agent-slug buf)
                               ". An edit through the compos tools carries that author.")))
    (string-join (append (map cadr parts) (list where)) "\n\n")))

;;; --- the modes ---------------------------------------------------------------

(register-minor-mode! "herdr-agent-mode"
  (lambda (buf) #t)
  ;; a turn-off that herdr-agent-stop! did not ask for is yours: it holds
  ;; until the agent exits
  (lambda (buf)
    (unless (buffer-local-value 'herdr-agent-stopping buf)
      (buffer-set-local! buf 'herdr-agent-declined #t))))

(define (herdr-agent-start! buf harness)
  (when (and (herdr-harness harness)
             (not (buffer-local-value 'herdr-agent-declined buf)))
    (buffer-set-local! buf 'herdr-agent-harness harness)
    (unless (minor-mode-on? buf "herdr-agent-mode")
      (enable-minor-mode! buf "herdr-agent-mode"))
    (let ((mode (herdr-harness-get harness 'mode)))
      (when (and mode (not (minor-mode-on? buf mode)))
        (enable-minor-mode! buf mode)))))

(define (herdr-agent-stop! buf)
  (let ((mode (herdr-harness-get (buffer-local-value 'herdr-agent-harness buf) 'mode)))
    (buffer-set-local! buf 'herdr-agent-stopping #t)
    (when (and mode (minor-mode-on? buf mode)) (disable-minor-mode! buf mode))
    (when (minor-mode-on? buf "herdr-agent-mode") (disable-minor-mode! buf "herdr-agent-mode"))
    (buffer-set-locals! buf (list 'herdr-agent-stopping #f 'herdr-agent-declined #f
                                  'herdr-agent-harness #f))))

(define (herdr-agent-on? buf)
  (and (minor-mode-on? buf "herdr-agent-mode") (buffer-local-value 'herdr-agent-harness buf)))

;; OSC 7501: the harness names itself in its status
(add-hook! '(terminal-status-hook herdr-agent)
  (lambda (buf status was)
    (let ((app (and status (plist-get status 'app))))
      (when (and app (herdr-harness app) (not (herdr-agent-on? buf)))
        (herdr-agent-start! buf app)))))

(add-hook! '(terminal-turn-end-hook herdr-agent)
  (lambda (buf app outcome msg)
    (when (member outcome '(exited "exited"))
      (herdr-agent-stop! buf))))

;;; --- the door ------------------------------------------------------------------

;; priv/agent-hook calls this: HARNESS EVENT, the shell's SLUG, the TOOL
;; name or "". The answer is base64 JSON, or empty for no answer.
(define (herdr-agent-hook harness event slug tool)
  (let* ((buf (herdr-agent-terminal slug))
         (answer (herdr-harness-get harness 'answer))
         (out (and buf answer
                   (begin (unless (herdr-agent-on? buf) (herdr-agent-start! buf harness))
                          (herdr-agent-on? buf))
                   (answer event buf (or tool "")))))
    (base64-encode (if out (json-encode out) ""))))
