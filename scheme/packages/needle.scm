;;; needle.scm --- Needle 3, the tool caller that runs on this machine.
;;;
;;; Needle answers one question: given the functions this editor offers,
;;; which of them does a sentence ask for, and what fills their
;;; arguments. It is a 121M model, it answers in tens of milliseconds,
;;; and nothing leaves this machine.
;;;
;;; The whole catalog cannot be offered at once. Needle reads five tools
;;; well; past five its own retrieval picks five and the rest are
;;; unreachable, which reads as a wrong route and never as a failure. So
;;; a route is two steps with one model: the same engine embeds the
;;; sentence, takes the five nearest rows of the catalog, binds those
;;; five as the tool set, and answers.
;;;
;;; Both steps are in one daemon because binding a tool set is only
;;; cheap in the process that already holds the weights: 13 ms in
;;; process, 54 ms through a worker, 60 ms through a fresh server.
;;;
;;; priv/python/needle-daemon.py is that process, and the endpoint
;;; registry owns it, so M-x sockets shows it and the model list starts
;;; and stops it. uv installs the package on the first start and the
;;; package fetches its own weights, so a machine that never asks Needle
;;; anything pays nothing.

(require 'endpoint)

(domain! 'llm)
(effects! '(write external execute))

(defgroup 'needle "Needle: the on-device tool caller.")

(defcustom 'needle-uv (expand-path "~/.local/bin/uv")
  "The uv that installs and runs the engine's package." 'group 'needle)
(defcustom 'needle-root (string-append (compos-home) "/needle")
  "Where the daemon caches the catalog's vectors." 'group 'needle)
(defcustom 'needle-threshold 0.7
  "A call at or above this confidence is acted on. Below it, it is confirmed."
  'group 'needle)
;; One. Measured over 46 labelled requests, the model does not improve
;; on the retriever's own first choice; it loses to it. Five candidates
;; routed 10, three routed 13, two routed 13, one routed 17. So the
;; words pick the tool and the model fills its arguments.
(defcustom 'needle-candidates 1
  "How many catalog rows a route offers the model. One lets the words pick the tool."
  'group 'needle)

;; Needle 3 is trained so every depth from 2 to 20 layers is a
;; deployable model, and a shallower rung answers faster. Measured over
;; the same 46 requests: the full model answered in 31 ms and routed 17,
;; the 8-layer rung in 13 ms and routed 17, the 4-layer rung in 10 ms
;; and routed 18 -- every request retrieval put a tool in front of.
;;
;; The rung is built once, outside the editor, because it wants the
;; training extras this package does not carry:
;;
;;   uv run --with 'cactus-needle[train]' --with numpy \
;;     needle build --layers 4 --out ~/.compos/needle/d4.cact
;;
;; A missing rung is not an error: the daemon answers with the full
;; model, 20 ms slower.
(defcustom 'needle-ladder (string-append (compos-home) "/needle/d4.cact")
  "A shallower rung of the ladder to answer with. A missing file uses the full model."
  'group 'needle)

(define *needle-endpoint* "needle")

;; The first start installs the package and reads the weights, and the
;; first index embeds the whole catalog. Both are one-time and both are
;; slow, so the timeout is the catalog's and not a question's.
(define needle-timeout 300000)

(define (needle-script) (priv-path "python/needle-daemon.py"))

(define (needle-spec)
  (list 'command needle-uv
        'args (list "run" "--quiet" "--with" "cactus-needle" "--with" "numpy"
                    "python" (needle-script))
        'framing "line"
        'serves "models"
        'env (list 'NEEDLE_TELEMETRY "0" 'DO_NOT_TRACK "1"
                   'NEEDLE_ROOT needle-root
                   'NEEDLE_WEIGHTS needle-ladder
                   'NEEDLE_DAEMON_LOG (string-append (compos-home) "/needle-daemon.log")
                   'PYTHONUNBUFFERED "1")))

(endpoint-register! *needle-endpoint* (needle-spec))

;;; --- the daemon ------------------------------------------------------------------

(define (needle-running?) (endpoint-connected? *needle-endpoint*))

;; whether this machine can run Needle at all: uv installs the rest
(define (needle-available?)
  (and (file-exists? needle-uv) (file-exists? (needle-script)) #t))

;; The spec is built again here, so a person who customizes needle-uv
;; gets that uv on the next start and not the one this file loaded with.
(define (needle-start!)
  (endpoint-register! *needle-endpoint* (needle-spec))
  (endpoint-ensure! *needle-endpoint*))

(define (needle-stop!) (endpoint-stop! *needle-endpoint*))

(define (needle-ask-daemon req k)
  (endpoint-ask-json *needle-endpoint* req needle-timeout k))

(define (needle-ensure-ask req k)
  (unless (needle-running?) (needle-start!))
  (needle-ask-daemon req k))

;;; --- the catalog -------------------------------------------------------------------

;; What the daemon embeds: one row a catalogued name, carrying the doc it
;; is ranked by and the signature its arguments are read from. The whole
;; catalog entry embeds badly, so only these three fields go over.
;; Only what a call can name. A key, a mode, a variable and a note are
;; catalogued for a person to read; offering one as a tool spends a slot
;; of five on something the editor cannot invoke.
(define (needle-rows)
  (map (lambda (r)
         (let ((p (nth 1 r)))
           (list 'name (plist-get p 'name)
                 'doc (or (plist-get p 'doc) "")
                 'sig (or (plist-get p 'sig) "")
                 'acts (if (needle-acts? (plist-get p 'effects)) 1 0))))
       (filter (lambda (r)
                 (let ((p (nth 1 r)))
                   (and (plist-get p 'name)
                        (member (plist-get p 'kind) '("function" "command")))))
               (apropos--rows-cached))))

;; Whether a row does anything. file-icon is pure and was beating visit
;; for "open /etc/hosts"; file-relative-name only reads and was beating
;; it too. Neither can open anything. This does not remove them, because
;; a read is a tool a person asks for -- "read a buffer" is buffer-text
;; -- so it breaks the tie and does not decide the set.
(define (needle-acts? effects)
  (and (pair? effects)
       (pair? (filter (lambda (e) (member e '("write" "execute" "destroy"))) effects))))

;; Embed the catalog. The daemon keeps the vectors on disk under the
;; catalog's generation, so this costs 30 s once and nothing after.
(define (needle-index! k)
  (needle-ensure-ask
    (list 'op "index" 'generation (value->string (catalog-generation)) 'rows (needle-rows))
    k))

;;; --- asking ------------------------------------------------------------------------

;; TOOLS is a list of plists, each with name, description and
;; parameters. K gets the reply plist.
(define (needle-ask tools query k)
  (needle-ensure-ask (list 'op "ask" 'tools tools 'query query)
    (lambda (reply) (k (needle-reply reply)))))

;; One sentence against the whole catalog: the model picks the rows and
;; then answers with them. K gets the reply plist, which also names the
;; candidates it chose, so a caller can show what it considered.
(define (needle-route query k)
  (needle-ensure-ask (list 'op "route" 'query query 'k needle-candidates)
    (lambda (reply) (k (needle-reply reply)))))

;; endpoint-ask-json answers in the shape an http reply answers, so the
;; body is where the daemon's own answer is.
(define (needle-reply reply)
  (let ((body (and (pair? reply) (plist-get reply 'json))))
    (cond ((not (pair? body))
           (list 'ok #f 'error (or (and (pair? reply) (plist-get reply 'error))
                                   "needle: the daemon did not answer")))
          ((plist-get body 'ok) body)
          (else body))))

;;; --- reading the answer ---------------------------------------------------------------

(define (needle-field reply key) (and (pair? reply) (plist-get reply key)))

(define (needle-calls reply) (or (needle-field reply 'calls) '()))
(define (needle-held reply) (or (needle-field reply 'held) '()))
(define (needle-reasoning reply) (or (needle-field reply 'reasoning) ""))
(define (needle-confidence reply) (or (needle-field reply 'confidence) 0))
(define (needle-candidates-of reply) (or (needle-field reply 'candidates) '()))

;; Three bands, and the middle one is the point. 'act runs the calls,
;; 'confirm shows them with their reasoning and asks, and 'refuse says
;; this sentence asks for nothing these tools do. The engine has already
;; withheld the calls it can prove wrong; the score covers the rest.
(define (needle-verdict reply)
  (let ((calls (needle-calls reply)))
    (cond ((and (pair? calls) (>= (needle-confidence reply) needle-threshold)) 'act)
          ((or (pair? calls) (pair? (needle-held reply))) 'confirm)
          (else 'refuse))))

;;; --- the commands -----------------------------------------------------------------------

(define-command "needle-server" "Start the Needle daemon, or say where it stands"
  (lambda ()
    (if (needle-running?)
        (message "needle: the daemon runs")
        (begin
          (needle-start!)
          (needle-ask-daemon '(op "ping")
            (lambda (r)
              (message (if (plist-get (needle-reply r) 'ok)
                           "needle: the daemon runs"
                           (string-append "needle: no answer - see "
                                          (compos-home) "/needle-daemon.log")))))))))

(define-command "needle-server-stop" "Stop the Needle daemon and free the weights"
  (lambda ()
    (needle-stop!)
    (message "needle: the daemon is stopped")))

(define-command "needle-index" "Embed the catalog so a sentence can reach it"
  (lambda ()
    (message "needle: embedding the catalog ...")
    (needle-index!
      (lambda (r)
        (let ((body (needle-reply r)))
          (message (if (plist-get body 'ok)
                       (string-append "needle: " (value->string (plist-get body 'rows))
                                      " rows indexed")
                       (string-append "needle: " (value->string (plist-get body 'error))))))))))

;;; --- the catalog entry -------------------------------------------------------------------

(category! 'system)
(domain! 'llm)
(effects! '(read))

(public! 'needle-available?
  "(needle-available?) - #t when this machine has the uv and the daemon Needle needs")
(public! 'needle-running?
  "(needle-running?) - #t when the Needle daemon holds its pipe open")
(public! 'needle-calls
  "(needle-calls REPLY) - the calls Needle stands behind, as a list")
(public! 'needle-held
  "(needle-held REPLY) - the calls the engine withheld, for a caller that confirms")
(public! 'needle-reasoning
  "(needle-reasoning REPLY) - how Needle derived each argument from the sentence")
(public! 'needle-confidence
  "(needle-confidence REPLY) - the calibrated score of the whole answer, 0 to 1")
(public! 'needle-candidates-of
  "(needle-candidates-of REPLY) - the catalog rows a route offered the model")
(public! 'needle-verdict
  "(needle-verdict REPLY) - 'act, 'confirm or 'refuse, by needle-threshold")

(effects! '(write external execute))

(public! 'needle-start!
  "(needle-start!) - start the Needle daemon, or keep the one that runs")
(public! 'needle-stop!
  "(needle-stop!) - stop the daemon and free the weights it holds")
(public! 'needle-index!
  "(needle-index! K) - embed the catalog; K gets the reply naming how many rows")
(public! 'needle-ask
  "(needle-ask TOOLS QUERY K) - ask a tool set what QUERY asks for; K gets the reply plist")
(public! 'needle-route
  "(needle-route QUERY K) - ask the whole catalog: the model picks the rows and answers with them")
(public! 'needle-server
  "M-x needle-server - start the on-device tool caller, or say where it stands")
(public! 'needle-server-stop
  "M-x needle-server-stop - stop the Needle daemon")
(public! 'needle-index
  "M-x needle-index - embed the catalog so a sentence can reach it")
