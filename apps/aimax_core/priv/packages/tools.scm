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
    "eval-scheme is the escape hatch for everything else. IMPORTANT: the "
    "language is ai-max's own small Scheme, NOT Emacs Lisp — elisp names "
    "like get-buffer, set-buffer, goto-char, point-max, insert, "
    "save-excursion, with-current-buffer do not exist. Core API: "
    "(buffer-list) names; (buffer-text NAME); (buffer-append! NAME TEXT) "
    "append to any buffer — the usual way to add text; (buffer-create NAME); "
    "(visit PATH) opens a file; (switch-to-buffer! NAME); (current-buffer); "
    "(insert! TEXT) at point in the current buffer; (message TEXT) echoes; "
    "(run-command \"name\") runs any M-x command. File buffers are named by "
    "full path. Before writing code with a name you are not sure exists, "
    "check it with apropos-api, and read any function's real source with "
    "describe-function. Keep replies short; the user is in an editor, not "
    "a browser."))

(define (llm-with-tools prompt handler)
  (llm-tools prompt *llm-system* (llm-tool-specs) llm-tool-call handler))

;;; --- the built-in toolbox ----------------------------------------------------

(define-tool! 'eval-scheme
  "Evaluate Scheme in the live editor session. Full editor API: buffers, windows, faces, modes, customize. NOT Emacs Lisp — verify unfamiliar names with apropos-api first. Returns the printed value."
  (list (list 'code "string" "Scheme source to evaluate"))
  (lambda (args)
    (value->string (eval-string (custom--plist-get args 'code)))))

;; Emacs-grade introspection: most of the editor is userland Scheme, and
;; closures carry their AST — so a function's real source is one call away.
(define (describe-function name)
  (cond ((boundp name)
         (function-source (symbol-value name)))
        ((command-fn name)
         (string-append "M-x command:\n" (function-source (command-fn name))))
        (else (string-append "no function or command named "
                             (symbol->string name)))))

(define-tool! 'describe-function
  "Read a function's actual implementation. Userland functions and M-x commands return their full Scheme source (most of the editor — dired, org, chat, modes — is userland); builtins are Elixir and return only a marker. Use it to understand how something works before changing it."
  (list (list 'name "string" "Function or command name, e.g. chat-send or face-remap!"))
  (lambda (args)
    (describe-function (string->symbol (custom--plist-get args 'name)))))

(define-tool! 'apropos-api
  "Search the editor's Scheme API by regex: every global function/variable and every M-x command. Use this to find the right name before writing eval-scheme code."
  (list (list 'pattern "string" "Regex over names, e.g. \"buffer\" or \"window|frame\""))
  (lambda (args)
    (let ((pat (custom--plist-get args 'pattern)))
      (value->string
        (list 'globals (filter (lambda (n) (re-match? pat n)) (global-names))
              'commands (filter (lambda (n) (re-match? pat n)) (command-names)))))))

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

;;; --- document tools (companion chats) ----------------------------------------
;;; Pull-style context: the model reads the live buffer when it needs it —
;;; never stale, and long documents cost tokens only when actually read.

(define-tool! 'read-doc
  "Read the live text of an editor buffer (may have unsaved changes — always fresher than the file on disk). Call this before commenting on or editing a document; never rely on an earlier read after the user may have typed."
  (list (list 'buffer "string" "Buffer name, e.g. the document named in the system context"))
  (lambda (args)
    (let ((b (custom--plist-get args 'buffer)))
      (if (buffer-exists? b)
          (buffer-text b)
          (string-append "no such buffer: " b)))))

(define-tool! 'edit-doc
  "Edit a buffer by exact replacement: old must occur exactly once and is replaced by new. Edits the live buffer, never the file on disk. Copy old verbatim from read-doc; widen it with surrounding text if it is not unique."
  (list (list 'buffer "string" "Buffer name")
        (list 'old "string" "Exact existing text, unique in the buffer")
        (list 'new "string" "Replacement text"))
  (lambda (args)
    (let ((b (custom--plist-get args 'buffer))
          (old (custom--plist-get args 'old))
          (new (custom--plist-get args 'new)))
      (cond ((not (buffer-exists? b)) (string-append "no such buffer: " b))
            ((equal? old "") "error: old must be non-empty")
            (else
              (let ((hits (- (length (string-split (buffer-text b) old)) 1)))
                (cond ((equal? hits 0)
                       "error: old text not found — read-doc and copy it exactly")
                      ((> hits 1)
                       (string-append "error: old text occurs "
                                      (number->string hits)
                                      " times — include surrounding text to make it unique"))
                      (else
                        (let ((pos (string-index (buffer-text b) old)))
                          (buffer-delete-range! b pos (string-byte-length old))
                          (buffer-insert! b pos new)
                          "edited")))))))))

;; chat integration: chat-send routes through llm-with-tools when this is on
(defcustom 'chat-use-tools #t
  "When true, the *chat* buffer's LLM can act on the editor via tools."
  'group 'chat 'type 'boolean)
