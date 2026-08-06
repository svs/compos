;;; tools.scm --- LLM tool registry: gptel-style native tool use.
;;;
;;; (define-tool! 'name "description" params handler) registers a tool the
;;; internal LLM can call. params is a list of (pname "type" "description")
;;; entries — append 'optional to mark a param optional. The handler gets a
;;; flat plist of the call arguments and returns a value (strings pass
;;; through; anything else is printed).
;;;
;;; (llm-with-tools prompt handler) runs the tool loop with every registered
;;; tool; handler receives the final text. The wire loop is Elixir mechanism
;;; (LLM.complete_tools); which tools exist, what they say, and what they do
;;; is all here. External ACP agents will get this same registry over MCP.

(define *llm-tools* '())

(define (define-tool! name description params handler)
  (set! *llm-tools*
    (cons (list name (list 'description description 'params params 'handler handler))
          (remove (lambda (t) (equal? (car t) name)) *llm-tools*)))
  name)

(define (llm-tool-specs)
  (map (lambda (t)
         (list (symbol->string (car t))
               (custom--plist-get (cadr t) 'description)
               (custom--plist-get (cadr t) 'params)))
       (reverse *llm-tools*)))

(define (llm-tool-call name args)
  (let ((t (assoc (string->symbol name) *llm-tools*)))
    (if t
        ((custom--plist-get (cadr t) 'handler) args)
        (string-append "no such tool: " name))))

;; the standing context every tool-enabled request carries — the "skill"
(define *llm-system*
  (string-append
    "You are the assistant inside ai-max, an Emacs-style editor scripted in "
    "Scheme, and you can act on the live editor through tools. "
    "Appearance and behavior are controlled by customizable variables and "
    "faces; changes made through the customize tools persist across "
    "restarts. To change how something looks: discover the knob with "
    "describe-variables (try patterns like \"font\" or \"theme\"), set it "
    "with customize-save, then confirm briefly what you changed. "
    "eval-scheme is the escape hatch for everything else — buffers, modes, "
    "keybindings; values print write-style. Keep replies short; the user is "
    "in an editor, not a browser."))

(define (llm-with-tools prompt handler)
  (llm-tools prompt *llm-system* (llm-tool-specs) llm-tool-call handler))

;;; --- the built-in toolbox ----------------------------------------------------

(define-tool! 'eval-scheme
  "Evaluate Scheme in the live editor session. Full editor API: buffers, windows, faces, modes, customize. Returns the printed value."
  (list (list 'code "string" "Scheme source to evaluate"))
  (lambda (args)
    (value->string (eval-string (custom--plist-get args 'code)))))

(define-tool! 'describe-variables
  "Search customizable variables by regex over names and docstrings. Returns plists of name, current value, default, doc, group, type."
  (list (list 'pattern "string" "Regex, e.g. \"font\" or \"org\""))
  (lambda (args)
    (value->string (customize-apropos (custom--plist-get args 'pattern)))))

(define-tool! 'customize-save
  "Set a customizable variable and persist it to custom.scm (survives restarts). Value is a Scheme expression — strings need quotes, e.g. \"\\\"17px\\\"\"."
  (list (list 'name "string" "Variable name, e.g. org-font-family")
        (list 'value "string" "Scheme expression for the new value"))
  (lambda (args)
    (let ((name (string->symbol (custom--plist-get args 'name)))
          (value (eval-string (custom--plist-get args 'value))))
      (customize-save! name value)
      (string-append "saved " (custom--plist-get args 'name)
                     " = " (value->string value)))))

(define-tool! 'customize-save-face
  "Set one face attribute globally and persist it (wins over themes). Attributes: fg, bg, family, size, weight, style, decoration."
  (list (list 'face "string" "Face name, e.g. default, modeline, org-level-1")
        (list 'attribute "string" "Attribute name")
        (list 'value "string" "CSS value, e.g. #c04040 or 15px or Spectral"))
  (lambda (args)
    (customize-save-face! (string->symbol (custom--plist-get args 'face))
                          (string->symbol (custom--plist-get args 'attribute))
                          (custom--plist-get args 'value))
    (string-append "saved face " (custom--plist-get args 'face))))

(define-tool! 'list-themes
  "List the available color themes."
  '()
  (lambda (args) (value->string (map car *themes*))))

(define-tool! 'load-theme
  "Switch to a color theme by name (persists across restarts)."
  (list (list 'name "string" "Theme name from list-themes"))
  (lambda (args)
    (load-theme (custom--plist-get args 'name))
    "ok"))

;; chat integration: chat-send routes through llm-with-tools when this is on
(defcustom 'chat-use-tools #t
  "When true, the *chat* buffer's LLM can act on the editor via tools."
  'group 'chat 'type 'boolean)
