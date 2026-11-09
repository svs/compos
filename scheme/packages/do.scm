;;; do.scm --- a small local model picks the command for a sentence.
;;;
;;; The palette's local backend (command-palette-decide-backend 'local).
;;; A small model on this machine reads the whole command catalog and
;;; answers with one command name for a sentence such as "split this
;;; window vertically". The editor checks the name against the catalog,
;;; so the model cannot invent a command. The model never writes Scheme:
;;; it picks, and the palette runs it and learns the words.
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

(defcustom 'do-warm-on-load #t
  "Ask the model one throwaway question at load, so the catalog prefix is cached."
  'group 'llm 'type 'boolean)

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

;;; --- the pick: the palette's local backend ----------------------------------------

;; K gets the one catalog command the model picks for PHRASE, or #f. The
;; palette asks this when command-palette-decide-backend is local.
(effects! '(external))
(define (do-pick phrase k)
  (do--ask phrase (lambda (r) (k (and (equal? (car r) 'ok) (cadr r))))))

(when do-warm-on-load (do-warm!))

(public! 'do-pick "(do-pick PHRASE K) — K gets the command a small local model picks for PHRASE, or #f")
