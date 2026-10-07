;;; title.scm --- the on-device card writer: a title and a description for a passage.
;;;
;;; A 350M Granite fine-tune (desert-ant-labs/title) that names a passage of
;;; text: a factual title of three to eight words and a one- or two-sentence
;;; description. It runs on MLX, so Apple silicon and nowhere else.
;;;
;;; There is no transport code here, on purpose. mlx_lm.server speaks the
;;; OpenAI chat API and req_llm's vllm provider is exactly that shape, so a
;;; local model is a model string like any other and keys.scm carries its
;;; address. What this file owns is the part that cannot be config: the
;;; prompt the card writer is asked with, and the tolerant parse of its two
;;; labelled lines.
;;;
;;; chat.scm's running summary uses it whenever it is ready, which is the
;;; point of installing it: a label and a title for every chat, on device,
;;; for no money and no round trip.

(domain! 'llm)
(effects! '(read external execute))

(defgroup 'title "Title: the on-device model that names a passage of text.")

(defcustom 'title-model-directory (string-append (compos-home) "/models/title")
  "The MLX model folder the card writer serves. Nothing is downloaded: populate it with the weights."
  'group 'title 'type 'string)

(defcustom 'title-server-command (string-append (getenv "HOME") "/.local/bin/mlx_lm.server")
  "The mlx_lm.server executable. An absolute path, because the daemon's PATH is not a login shell's."
  'group 'title 'type 'string)

(defcustom 'title-server-port 8127
  "The loopback port the card writer answers on." 'group 'title 'type 'integer)

;; Which model writes the cards. "local" is the on-device fine-tune in
;; title-model-directory; "default" is the session model; anything else is a
;; model id. It defaults away from local on evidence: the 350M returns
;; byte-identical cards for the trained prompt and a rewritten one, so the
;; prompt below is unreadable to it and no wording fixes the titles. A real
;; model reads the prompt. The trade is money and a round trip per turn --
;; that is what "local" is still here for.
(defcustom 'title-model "default"
  "The model that writes cards: \"default\" for the session model, \"local\" for the on-device fine-tune, or a model id."
  'group 'title 'type 'string)

;; The token cap on one card. It stops a degenerate run, a real failure mode for a small instruct model given unusual input.
(define title-max-tokens 96)

;;; --- the address ----------------------------------------------------------------

;; The provider is self-hosted, so the address is ours to state and the key is
;; a formality: mlx_lm.server never reads it, and req_llm requires a non-empty
;; one. Both live beside every other provider's, in keys.scm.
(define (title--base-url)
  (string-append "http://127.0.0.1:" (number->string title-server-port) "/v1"))

(define (title--local-model) (string-append "vllm:" title-model-directory))

(define (title--local?) (equal? title-model "local"))

(define (title--model)
  (cond ((title--local?) (title--local-model))
        ((equal? title-model "default") (llm-model))
        (else title-model)))

(register-llm-base-url! "vllm" (title--base-url))
(register-llm-key! "vllm" "local")

;;; --- the server -----------------------------------------------------------------

;; Loading is expensive and generation is cheap, so the server loads once and
;; stays warm. Started at most once a session and never waited for: a start
;; answers #f for this round, because the model is still loading, and the
;; caller's next refresh finds it ready. Once ready, no probe runs again.
(define *title-server-ready* #f)
(define *title-server-started* #f)

(define (title-installed?)
  (file-exists? (string-append title-model-directory "/config.json")))

(define (title--listening?)
  (not (equal? "" (string-trim
    (shell-command->string
      (string-append "lsof -nP -iTCP:" (number->string title-server-port) " -sTCP:LISTEN -t")
      (compos-home))))))

(define (title--start!)
  (shell-command->string
    (string-append "nohup " title-server-command
                   " --model " title-model-directory
                   " --host 127.0.0.1 --port " (number->string title-server-port)
                   " --temp 0.0 --max-tokens " (number->string title-max-tokens)
                   " >" (compos-home) "/title-server.log 2>&1 &")
    (compos-home))
  (message "title: the on-device card writer is loading"))

(define (title-ready?)
  (if (not (title--local?))
      ;; a hosted model has nothing to install and nothing to warm: it is
      ;; ready the moment there is an id to call. Callers gate on this, so
      ;; answering #f here is what used to make chat.scm fall back.
      (let ((m (title--model))) (and (string? m) (not (equal? m ""))))
      (and (title-installed?)
           (or *title-server-ready*
               (cond ((title--listening?) (set! *title-server-ready* #t) #t)
                     (*title-server-started* #f)
                     (else (set! *title-server-started* #t) (title--start!) #f))))))

;;; --- the prompt -----------------------------------------------------------------

;; The prompt the card writer is asked with. It diverges from the fine-tune's
;; trained string: it asks for a title that names the problem or the task, and
;; a description of what was investigated and what was fixed.
;;
;; MEASURED, and the measurement matters more than the wording: this model
;; does not read the instruction. At temp 0.0 the trained prompt and this one
;; return byte-identical cards on real passages -- a chat about titling, and a
;; coding turn with tools. Asking it harder makes it worse, not better: a
;; longer version of this prompt had the 350M echo the instructions back as
;; the card ("Writing a noun phrase about a task"), and naming files,
;; functions and errors in the rules had it title the rules instead of the
;; passage. Every content noun in the prompt becomes an answer.
;;
;; So this string states the intent and buys nothing at runtime. The title
;; shape is changed downstream, not here -- chat.scm's chat-title--short is
;; what clipped "A user requests a correction to the summarizer" into a
;; six-word fragment -- and the hosted fallback in chat-summary-refresh! is
;; the prompt that a model actually obeys. Retrain against this string to make
;; it real. It says passage and not clip because the model is not
;; clip-specific.
(define (title--prompt text)
  (string-append
    "Write a card for the passage below, as exactly two lines and nothing"
    " else. Begin the first line with TITLE: and the second with DESC:.\n"
    "TITLE: three to six words naming the problem or the task. A noun phrase,"
    " not a sentence about the speaker: the issue itself, never A user...,"
    " The person..., or A request....\n"
    "DESC: one or two sentences saying what was investigated and what was"
    " fixed. Name the files, functions, commands and errors involved, so"
    " someone can find this by searching for them. If nothing was fixed, say"
    " what was investigated and what was found.\n"
    "Plain text only: no markdown, no bold, no emoji, no hashtags, no hype."
    " Write in the same language as the passage.\n\nPASSAGE:\n"
    text))

;; Tolerant, the same way the SDK's parse is: a card model that drifts off
;; format should degrade to a usable title rather than to nothing. DESC and
;; DESCRIPTION are both taken -- the training data uses DESC, but base-model
;; habits leak the longer spelling through.
(define (title--parse raw)
  (let loop ((lines (string-split raw "\n")) (title "") (desc ""))
    (if (null? lines)
        (list title desc)
        (let* ((line (string-trim (car lines)))
               (up (string-upcase line))
               (rest (lambda (n) (string-trim (substring line n (string-length line))))))
          (cond ((string-prefix? "TITLE:" up) (loop (cdr lines) (rest 6) desc))
                ((string-prefix? "DESCRIPTION:" up) (loop (cdr lines) title (rest 12)))
                ((string-prefix? "DESC:" up) (loop (cdr lines) title (rest 5)))
                ((and (equal? title "") (not (equal? line "")))
                 (loop (cdr lines) line desc))
                ;; positional fallback: a model that answers with the two
                ;; lines and no labels at all is still answering. Line one
                ;; titled, so line two describes -- dropping it is how the
                ;; running summary silently went empty on the hosted model.
                ((and (equal? desc "") (not (equal? line "")))
                 (loop (cdr lines) title line))
                (else (loop (cdr lines) title desc)))))))

;;; --- the card -------------------------------------------------------------------

(define (title-card text k)
  (if (not (title-ready?))
      (k #f)
      (llm-with-model (title--prompt text) (title--model)
        (lambda (raw) (k (and (string? raw) (not (equal? raw "")) (title--parse raw)))))))

;;;###autoload
(define-command "title-server"
  "Start the on-device card writer, or say where it stands"
  (lambda ()
    (message
      (cond ((not (title--local?))
             (string-append "title: cards are written by " (title--model)))
            ((not (title-installed?))
             (string-append "title: no model in " title-model-directory))
            ((title-ready?) (string-append "title: ready on " (title--base-url)))
            (else "title: loading")))))

(public! 'title-card
  "(title-card TEXT K) - K gets (TITLE DESCRIPTION) for a passage of text, or #f when the on-device model is not ready")
(public! 'title-ready?
  "(title-ready?) - #t when the card writer is installed and serving; starts it once when it is not")
(public! 'title-installed?
  "(title-installed?) - #t when the MLX model folder holds a model")
