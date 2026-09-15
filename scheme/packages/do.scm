;;; do.scm --- say what you want; a small local model runs the command.
;;;
;;; M-x asks for a command's name. The palette (Cmd-p) matches words in
;;; command docs. This prompt takes a sentence: "split this window
;;; vertically". A small model on this machine reads the whole command
;;; catalog and answers with one command name. The editor checks the name
;;; against the catalog, so the model cannot invent a command. It then
;;; runs the command as a key would. The model never writes Scheme: it
;;; picks, and the editor acts. Composition stays with the large agents.
;;;
;;; Three answers cost no model call: a phrase that IS a command name, a
;;; phrase this prompt ran before (the memory persists with the desktop),
;;; and an empty prompt, which lists that memory.
;;;
;;; The catalog rides in the system prompt, so the server keeps its prefix
;;; in the KV cache. The first call after a boot or a catalog change pays
;;; the prefill once; do-warm! pays it early, off the user's keystroke.
;;;
;;; Two servers speak here. llama-server (llama.cpp, the default) takes a
;;; raw prompt on /completion and answers in about 0.35s on this machine.
;;; Ollama takes chat messages on /api/chat and answers in about 0.75s,
;;; because it re-checks the cached prefix on every request.

(domain! 'interaction)
(effects! '(read))

(defcustom 'do-backend "llama-cpp"
  "Which local server answers: llama-cpp (its /completion API) or ollama (its /api/chat API)."
  'group 'llm 'type 'string)

(defcustom 'do-endpoint "http://127.0.0.1:8089"
  "The local server for do-backend. Ollama listens on 11434, llama-server on 8089."
  'group 'llm 'type 'string)

(defcustom 'do-model "qwen3:4b"
  "The model name: the Ollama tag for ollama, a label for llama-cpp (one model per server)."
  'group 'llm 'type 'string)

(defcustom 'do-debounce-ms 150
  "How long the Do prompt waits after a keystroke before it asks the model."
  'group 'llm 'type 'number)

(defcustom 'do-warm-on-load #t
  "Ask the model one throwaway question at load, so the catalog prefix is cached."
  'group 'llm 'type 'boolean)

;; A command with one of these effects asks before it runs.
(define *do-confirm-effects* '("destroy"))

;;; --- the catalog, as the model reads it -----------------------------------------

(define *do--prompt-gen* #f)
(define *do--prompt* "")
(define *do--names* '())

(define *do--head*
  (string-append
    "You are the command dispatcher for the Compos editor (an Emacs). "
    "The user states an intent in plain words. Choose the ONE command that does it. "
    "Emacs conventions: 'split vertically' = split-window-below; 'side by side' = split-window-right. "
    "Reply with JSON {\"command\": NAME}.\n\nCOMMANDS:\n"))

(define (do--take xs n)
  (if (or (null? xs) (= n 0)) '() (cons (car xs) (do--take (cdr xs) (- n 1)))))

;; Nine words of doc per command keep the prompt near 14k tokens.
(define (do--short-doc doc)
  (string-join (do--take (string-split doc " ") 9) " "))

(define (do--line name)
  (let ((doc (command-doc name)))
    (if (equal? doc "") name (string-append name ": " (do--short-doc doc)))))

(define (do--refresh-catalog!)
  (let ((gen (catalog-generation)))
    (when (not (equal? gen *do--prompt-gen*))
      (set! *do--names* (command-names))
      (set! *do--prompt* (string-append *do--head* (string-join (map do--line *do--names*) "\n")))
      (set! *do--prompt-gen* gen))))

(define (do--catalog-prompt) (do--refresh-catalog!) *do--prompt*)
(define (do--catalog-names) (do--refresh-catalog!) *do--names*)

;;; --- the model call --------------------------------------------------------------

(define (do--ollama-body phrase)
  ;; The assistant turn starts the answer, so the model generates only the
  ;; name and stops at the closing quote: four tokens instead of ten. A
  ;; grammar would force a leading quote on the name and skew the pick.
  (json-encode
    (list 'model do-model
          'stream #f
          'think #f
          'keep_alive "24h"
          'messages (list (list 'role "system" 'content (do--catalog-prompt))
                          (list 'role "user" 'content phrase)
                          (list 'role "assistant" 'content "{\"command\": \""))
          'options (list 'temperature 0 'num_predict 16 'num_ctx 16384 'stop (list "\"")))))

;; The same prompt as one string, in Qwen3's chat template. The empty
;; think block is what the template writes when thinking is off.
(define (do--llama-prompt phrase)
  (string-append "<|im_start|>system\n" (do--catalog-prompt) "<|im_end|>\n"
                 "<|im_start|>user\n" phrase "<|im_end|>\n"
                 "<|im_start|>assistant\n<think>\n\n</think>\n\n{\"command\": \""))

(define (do--llama-body phrase)
  (json-encode
    (list 'prompt (do--llama-prompt phrase)
          'n_predict 16
          'temperature 0
          'stop (list "\"")
          'cache_prompt #t)))

(define (do--llama?) (equal? do-backend "llama-cpp"))

(define (do--request-url)
  (string-append do-endpoint (if (do--llama?) "/completion" "/api/chat")))

(define (do--request-body phrase)
  (if (do--llama?) (do--llama-body phrase) (do--ollama-body phrase)))

;; The name in a reply: the bare text before the closing quote, or the
;; command field when a model answers with the whole JSON object.
(define (do--reply-name content)
  (let ((text (string-trim content)))
    (if (string-prefix? "{" text)
        (let ((parsed (json-parse text))) (and parsed (plist-get parsed 'command)))
        (string-trim (car (string-split text "\""))))))

;; The reply, as (ok NAME) or (error TEXT). command-fn checks the name
;; against the live catalog: the model is not constrained by a grammar,
;; so a name it invents stops here, not as an undefined command.
(define (do--parse-reply r)
  (if (not (plist-get r 'ok))
      (list 'error (let ((e (plist-get r 'error)))
                     (if (string? e) (string-append do-model ": " e) "the model did not answer")))
      (let* ((json (or (plist-get r 'json) (json-parse (plist-get r 'body))))
             (msg (and json (plist-get json 'message)))
             ;; llama-server answers {"content": ...}; Ollama {"message": {"content": ...}}
             (content (and json (or (plist-get json 'content)
                                    (and msg (plist-get msg 'content)))))
             (name (and (string? content) (do--reply-name content))))
        (if (and (string? name) (command-fn name))
            (list 'ok name)
            (list 'error (string-append "no command for that"
                                        (if (string? content) (string-append ": " content) "")))))))

(define (do--ask-server phrase k)
  (http-request (do--request-url)
    (list 'method "post"
          'headers (list 'content-type "application/json")
          'body (do--request-body phrase)
          'timeout 60000)
    (lambda (r) (k (do--parse-reply r)))))

;; The seam a test rebinds: (lambda (phrase k) ...) calling K with the reply.
(define *do--ask* #f)
(define (do--ask phrase k) ((or *do--ask* do--ask-server) phrase k))

(effects! '(external))
(define (do-warm!)
  (do--ask "warm up" (lambda (r) #f)))

;;; --- memory: a phrase that ran once runs again for free ----------------------------

(effects! '(write))
(defvar '*do-memory* '())          ; ((PHRASE COMMAND) ...), newest first

(persist-global! 'do-memory
  (lambda () *do-memory*)
  (lambda (v) (set! *do-memory* (if (list? v) v '()))))

(define (do--normalize phrase) (string-downcase (string-trim phrase)))

(define (do-remember! phrase name)
  (let ((key (do--normalize phrase)))
    (set! *do-memory*
      (do--take (cons (list key name)
                      (remove (lambda (e) (equal? (car e) key)) *do-memory*))
                200))))

(define (do-forget! phrase)
  (let ((key (do--normalize phrase)))
    (set! *do-memory* (remove (lambda (e) (equal? (car e) key)) *do-memory*))))

(effects! '(read))
(define (do-recall phrase)
  (let ((e (assoc (do--normalize phrase) *do-memory*)))
    (and e (cadr e))))

;;; --- resolve: phrase -> (SOURCE NAME) ----------------------------------------------
;;; SOURCE is exact, memory or model. An (error TEXT) says why there is no name.

(define (do--resolve phrase k)
  (let ((text (string-trim phrase)))
    (cond ((equal? text "") (k (list 'error "say what you want")))
          ((command-fn text) (k (list 'exact text)))
          ((do-recall text) (k (list 'memory (do-recall text))))
          (else (do--ask text
                  (lambda (r) (k (if (equal? (car r) 'ok) (list 'model (cadr r)) r))))))))

(define (do--effects name)
  (let ((e (catalog-entry 'command name)))
    (if e
        (map (lambda (x) (if (symbol? x) (symbol->string x) x))
             (or (plist-get e 'effects) '()))
        '())))

(define (do--needs-confirm? name)
  (let loop ((effs (do--effects name)))
    (cond ((null? effs) #f)
          ((member (car effs) *do-confirm-effects*) #t)
          (else (loop (cdr effs))))))

;;; --- the panel ----------------------------------------------------------------------

(define (do--source-label source)
  (cond ((equal? source 'exact) "command")
        ((equal? source 'memory) "remembered")
        (else do-model)))

;; One proposal row: the command is the label, so RET on it runs it.
(define (do--row name source)
  (list name
        (string-append (do--source-label source) "  " (key-for-command name) "  " (command-doc name))
        "command"))

(define (do--resting-rows)
  (let loop ((entries *do-memory*) (seen '()) (rows '()))
    (cond ((or (null? entries) (>= (length rows) 12)) (reverse rows))
          ((member (cadr (car entries)) seen) (loop (cdr entries) seen rows))
          (else
            (let ((phrase (car (car entries))) (name (cadr (car entries))))
              (loop (cdr entries) (cons name seen)
                    (cons (list name
                                (string-append "\"" phrase "\"  " (key-for-command name) "  " (command-doc name))
                                "command")
                          rows)))))))

(define *do--input* "")            ; what the prompt holds, kept for confirm

(define (do--live? input)
  (let ((st (minibuffer-state)))
    (and st
         (equal? (plist-get st 'prompt) "Do: ")
         (equal? (plist-get st 'input) input))))

(define (do--refresh input)
  (if (equal? (string-trim input) "")
      (when (do--live? input) (minibuffer-set-candidates! (do--resting-rows)))
      (do--resolve input
        (lambda (r)
          (when (do--live? input)
            (minibuffer-set-candidates!
              (if (equal? (car r) 'error) '() (list (do--row (cadr r) (car r))))))))))

(effects! '(write execute))
(define (do--run! phrase name)
  (when (not (equal? (do--normalize phrase) name))
    (do-remember! phrase name))
  (history-push! 'do phrase)
  (history-push! 'M-x name)
  (message (string-append "→ " name))
  (run-command name))

(define (do--run-or-confirm! phrase name)
  (if (do--needs-confirm? name)
      (minibuffer-read (string-append "Run " name "? ") '("yes" "no")
        (lambda (a) (when (equal? a "yes") (do--run! phrase name))))
      (do--run! phrase name)))

;; RET brings the selected row's label, or the typed text when no row fits.
(define (do--confirm choice)
  (let ((phrase (if (equal? (string-trim *do--input*) "") choice *do--input*)))
    (if (command-fn choice)
        (do--run-or-confirm! phrase choice)
        (begin
          (message (string-append "asking " do-model " …"))
          (do--resolve choice
            (lambda (r)
              (if (equal? (car r) 'error)
                  (message (cadr r))
                  (do--run-or-confirm! choice (cadr r)))))))))

(effects! '(write execute external))
(define-command "do"
  "Say what you want; a local model picks the command and runs it"
  (lambda ()
    (set! *do--input* "")
    (minibuffer-read* "Do: " (do--resting-rows)
      (list (list 'confirm do--confirm)
            (list 'change
              (lambda (input)
                (set! *do--input* input)
                (debounce! (string-append "do:" (selected-frame)) do-debounce-ms do--refresh input)))
            (list 'filter #f)
            (list 'style "palette")
            (list 'legend (list (list "RET" "run") (list "C-g" "cancel")))))))

(effects! '(write))
(define-command "do-forget"
  "Forget every phrase the Do prompt remembers"
  (lambda ()
    (set! *do-memory* '())
    (message "do: memory cleared")))

(global-set-key "s-k" "do")

(when do-warm-on-load (do-warm!))
