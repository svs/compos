;;; laya.scm --- the laya decision model, held open as a daemon.
;;;
;;; Laya answers typed questions about a passage: a choice, a score, a
;;; yes or no, with a confidence. It is a 421M decision transformer and
;;; not a language model, so no ollama and no OpenAI-shaped server can
;;; hold it. The daemon is ours: priv/python/laya-daemon.py keeps one
;;; checkpoint in memory and answers one JSON line a request.
;;;
;;; The daemon is an endpoint, the editor's own registry of long-lived
;;; connections. Nothing here keeps a second list of running programs:
;;; M-x sockets already shows it, M-x local-models starts and stops it on the
;;; host line endpoint:laya, and decide.scm asks it for an answer.
;;;
;;; The checkpoints are the ones this machine already holds - the
;;; huggingface cache, and laya-model-roots. The daemon reads that cache;
;;; it carries no list of model names of its own.

(domain! 'llm)
(effects! '(write external execute))

(defgroup 'laya "Laya: the on-device decision model, and the daemon that holds it.")

(defcustom 'laya-python (expand-path "~/.asdf/installs/python/3.12.0/bin/python3")
  "The python that holds the laya-mlx package." 'group 'laya)

(defcustom 'laya-model-roots (list (string-append (compos-home) "/models"))
  "Where this machine keeps laya checkpoints, besides the huggingface cache."
  'group 'laya)
(defcustom 'laya-model ""
  "Which checkpoint answers a question that names none. Empty means the one this machine holds."
  'group 'laya)

(define *laya-endpoint* "laya")

;; A checkpoint load costs seconds and a question costs milliseconds, so
;; the first question of a cold daemon waits for the weights.
(define laya-timeout 600000)

(define (laya-script) (priv-path "python/laya-daemon.py"))

;; 'serves "models" is how the model list finds this daemon: it reads the
;; endpoint registry and shows every daemon that answers for models, so
;; nobody has to name this one twice.
(define (laya-spec)
  (list 'command laya-python
        'args (list (laya-script))
        'framing "line"
        'serves "models"
        'env (list 'LAYA_DAEMON_LOG (string-append (compos-home) "/laya-daemon.log")
                   'LAYA_MODEL_DIRS (string-join laya-model-roots ":")
                   'PYTHONUNBUFFERED "1")))

(endpoint-register! *laya-endpoint* (laya-spec))

;;; --- the daemon ------------------------------------------------------------------

(define (laya-running?) (endpoint-connected? *laya-endpoint*))

;; whether this machine can run laya at all: the python that holds the
;; package, and the daemon beside this file
(define (laya-available?)
  (and (file-exists? laya-python) (file-exists? (laya-script)) #t))

;; The spec is built again here, so a person who customizes laya-python
;; gets that python on the next start and not the one this file loaded with.
(define (laya-start!)
  (endpoint-register! *laya-endpoint* (laya-spec))
  (endpoint-ensure! *laya-endpoint*))

(define (laya-stop!) (endpoint-stop! *laya-endpoint*))

;; One request, one answer, in the shape an http reply answers: the
;; daemon follows the JSON line convention endpoint.scm reads.
(define (laya-ask req k)
  (endpoint-ask-json *laya-endpoint* req laya-timeout k))

;; the caller wants the answer, not the daemon: start it and then ask
(define (laya-ensure-ask req k)
  (unless (laya-running?) (laya-start!))
  (laya-ask req k))

(define (laya-models k) (laya-ask '(op "models") k))

(define (laya-load! name k) (laya-ensure-ask (list 'op "load" 'model name) k))

(define (laya-unload! name k)
  (laya-ask (if name (list 'op "unload" 'model name) '(op "unload")) k))

(define (laya-predict state questions model k)
  (let ((want (cond ((and (string? model) (not (equal? model ""))) model)
                    ((equal? laya-model "") #f)
                    (else laya-model))))
    (laya-ensure-ask
      (append (list 'op "predict" 'state state 'questions questions)
              (if want (list 'model want) '()))
      k)))

;;; --- the commands ------------------------------------------------------------------

(define-command "laya-server" "Start the laya daemon, or say where it stands"
  (lambda ()
    (if (laya-running?)
        (message "laya: the daemon runs")
        (begin
          (laya-start!)
          (laya-ask '(op "models")
            (lambda (reply)
              (if (plist-get reply 'ok)
                  (message (string-append
                             "laya: the daemon runs - "
                             (number->string
                               (length (or (plist-get (plist-get reply 'json) 'models) '())))
                             " checkpoint(s)"))
                  (message (string-append "laya: " (or (plist-get reply 'error) "no answer")
                                          " - see " (compos-home) "/laya-daemon.log")))))))))

(define-command "laya-server-stop" "Stop the laya daemon and free the weights"
  (lambda ()
    (laya-stop!)
    (message "laya: the daemon is stopped")))

;;; --- the catalog ------------------------------------------------------------------

(category! 'system)
(domain! 'llm)
(effects! '(read external))

(public! 'laya-running?
  "(laya-running?) - #t when the laya daemon holds its pipe open")
(public! 'laya-available?
  "(laya-available?) - #t when this machine has the python and the daemon laya needs")
(public! 'laya-models
  "(laya-models K) - K gets the reply naming every laya checkpoint this machine holds")

(effects! '(write external execute))

(public! 'laya-start!
  "(laya-start!) - start the laya daemon, or keep the one that runs")
(public! 'laya-stop!
  "(laya-stop!) - stop the laya daemon and free the weights it holds")
(public! 'laya-load!
  "(laya-load! NAME K) - build one checkpoint in the daemon; K gets the reply")
(public! 'laya-unload!
  "(laya-unload! NAME K) - drop one checkpoint, or all of them when NAME is #f")
(public! 'laya-predict
  "(laya-predict STATE QUESTIONS MODEL K) - answer typed questions about STATE; K gets the reply. MODEL #f means laya-model, and an empty laya-model means the checkpoint this machine holds.")
(public! 'laya-server
  "M-x laya-server - start the on-device decision model, or say where it stands")
(public! 'laya-server-stop
  "M-x laya-server-stop - stop the laya daemon")

(defrecipe! "start the on-device decision model" "(run-command \"laya-server\")")
