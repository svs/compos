;;; models.scm --- the model hosts on this machine, and on the network.
;;;
;;; M-x local-models lists the models every host in models-hosts holds, and
;;; says which of them a host keeps loaded in memory now.
;;;
;;;   RET   show what the model is: family, parameters, quantization
;;;   s     load the model; it stays loaded for models-keep-alive
;;;   k     unload the model now
;;;   i     install another model on this line's host: it pulls the name
;;;   d     uninstall the model, after a confirmation
;;;   S     start this line's server or daemon; K stops the daemon
;;;   h     add a host; H forgets the host on this line
;;;   g / q refresh, bury. / filters.
;;;
;;; Ollama is the one backend. A host is a URL, or "ssh:NAME" for a
;;; machine we reach with a shell. Ollama binds its own loopback, so a
;;; machine on the network usually holds models that no HTTP request from
;;; here can see; over ssh the same API answers through curl. Both forms
;;; end in models--request, and a second backend goes behind it, not
;;; beside it. Nothing here runs the ollama command, except the S that
;;; starts the server on this machine.
;;;
;;; A host whose address ends in /v1 is an OpenAI-shaped server instead -
;;; mlx_lm.server, llama-server, vllm. The list reads its models and says
;;; it is serving them; loading and installing are not in that API, so
;;; those keys say so rather than sending a request that cannot land.
;;;
;;; A host "endpoint:NAME" is a daemon this editor starts itself: a
;;; program behind a pipe that answers one JSON line a request. Those
;;; hosts are not typed in: a package registers its daemon once in the
;;; endpoint registry and says there that it serves models, and this list
;;; reads that registry. laya, the decision model, is the first.
;;;
;;; The host named "disk" is no server at all: it is the model files this
;;; machine keeps. A model that only runs inside a program - laya, under
;;; decide.scm - is still in the list, with the word that says nothing is
;;; holding it up.

(domain! 'llm)
(effects! '(read external))

(define *models-buffer* "*models*")
(define *models-detail-buffer* "*model*")

;; why the last scan answered nothing, so the meta line can say it
(define *models-error* #f)

;; one (LABEL MESSAGE) per host that did not answer the last scan
(define *models-errors* '())

(define (models--note-error! host message)
  (let ((why (or message "no answer")))
    (set! *models-error* why)
    (set! *models-errors*
          (append *models-errors*
                  (list (list (models--host-label host) why))))))

(defgroup 'models "Models: the local model hosts and the models they hold.")

(defcustom 'models-host "http://localhost:11434"
  "The model host the list talks to." 'group 'models)

(defcustom 'models-hosts (list "http://localhost:11434")
  "Every model host the list shows, in the order it shows them." 'group 'models)

(defcustom 'models-disk-roots
  (list "~/.cache/huggingface/hub" (string-append (compos-home) "/models"))
  "Where this machine keeps model files, for the host named disk."
  'group 'models)

(defcustom 'models-keep-alive "10m"
  "How long a model you load stays in the host memory." 'group 'models)

;; Seconds before the model list asks the host again.
(define models-cache-ttl 15)

;; Seconds to wait for an install. A large model takes minutes.
(define models-pull-timeout 3600)

(defface! 'models-loaded 'fg "#2e6b45" 'weight "600")
(face-clear! 'models-name)
(defface! 'models-name 'inherit 'default 'weight "600")
(defface! 'models-size 'fg "#7a5a1a")

;;; --- the host -------------------------------------------------------------------
;;; A host is a URL. "localhost", "box.local" and "10.0.0.4:8080" are all
;;; names a person types, so the scheme and the default port fill in. A
;;; name that already carries a port or a path keeps it. "ssh:marilyn"
;;; and "ssh:marilyn:8089" name a machine we hold a shell on, and the
;;; requests to it run there, against its own loopback.

(define *models-default-port* "11434")

(define (models--strip-slash url)
  (if (string-suffix? "/" url)
      (substring url 0 (- (string-length url) 1))
      url))

;; the text after the scheme: "box.local:8080/v1" of "http://box.local:8080/v1"
(define (models--rest url)
  (let ((parts (string-split url "://")))
    (if (> (length parts) 1) (cadr parts) url)))

(define (models--host-url host)
  (let* ((h (string-trim (or host "")))
         (h (if (or (equal? h "") (equal? h "local")) "localhost" h))
         (h (if (string-contains? h "://") h (string-append "http://" h)))
         (h (models--strip-slash h))
         (rest (models--rest h)))
    (if (or (string-contains? rest ":") (string-contains? rest "/"))
        h
        (string-append h ":" *models-default-port*))))

(define (models-base) (models--host-url models-host))

;; "disk" is this machine's model files, and no server at all. A model
;; file is not a running model: laya loads inside a python process for one
;; question and is gone, and an mlx model waits in the cache until
;; something loads it. The list says what is there; it does not pretend a
;; file is a service.
(define (models--disk? host)
  (equal? (string-trim (or host "")) "disk"))

;; "endpoint:laya" is a daemon behind a pipe: this editor spawns it, and
;; it answers JSON lines rather than HTTP. A person never types one of
;; these; the endpoint registry names them.
(define (models--endpoint-name host)
  (let ((h (string-trim (or host ""))))
    (if (string-prefix? "endpoint:" h)
        (substring h 9 (string-length h))
        #f)))

;; The daemons are not a list of ours. A package registers its daemon in
;; the endpoint registry, the editor's one place for a long-lived
;; connection, and says there that it serves models. A daemon therefore
;; appears in this list the moment its package loads, and leaves with it.
(define (models--daemon-hosts)
  (map (lambda (n) (string-append "endpoint:" n))
       (filter (lambda (n)
                 (let ((spec (endpoint-spec n)))
                   (and (pair? spec) (equal? (plist-get spec 'serves) "models"))))
               (endpoint-names))))

(define *models-daemon-hosts* models--daemon-hosts)

;; what a host is, and so what it can be asked to do
(define (models--kind host)
  (cond ((models--disk? host) 'disk)
        ((models--endpoint-name host) 'daemon)
        ((models--openai? host) 'openai)
        (else 'ollama)))

;; A daemon load builds the weights, which costs seconds; the timeout
;; covers that, in the milliseconds endpoint-ask counts.
(define models-daemon-timeout 600000)

;; (TARGET PORT PATH) for an ssh host, and #f for a URL. The path is the
;; part after the port: "ssh:marilyn:8089/v1" is an OpenAI-shaped server
;; on that machine, and "ssh:marilyn" is its ollama.
(define (models--ssh-spec host)
  (let ((h (string-trim (or host ""))))
    (if (string-prefix? "ssh:" h)
        (let* ((rest (substring h 4 (string-length h)))
               (cut (string-split rest "/"))
               (parts (string-split (nth 0 cut) ":")))
          (list (nth 0 parts)
                (if (> (length parts) 1) (nth 1 parts) *models-default-port*)
                (if (> (length cut) 1)
                    (string-append "/" (string-join (cdr cut) "/"))
                    "")))
        #f)))

;; An OpenAI-shaped server - mlx_lm.server, llama-server, vllm - keeps its
;; models at /v1/models and has no route to pull or delete one. A host
;; whose address ends in /v1 is one of those: the list reads it and does
;; not manage it.
(define (models--openai? host)
  (if (or (models--disk? host) (models--endpoint-name host))
      #f
      (models--openai-url? host)))

(define (models--openai-url? host)
  (let ((ssh (models--ssh-spec host)))
    (if ssh
        (string-suffix? "/v1" (nth 2 ssh))
        (string-suffix? "/v1" (models--host-url host)))))

;; the short name the host column carries: "marilyn", "localhost",
;; "127.0.0.1:8127". A port the person had to give is part of the name,
;; because one machine runs more than one model server.
;; this machine is "local", the word the host prompt already takes, so
;; the column has room for the port that tells two servers apart
(define (models--short-name name)
  (if (or (equal? name "localhost") (equal? name "127.0.0.1")) "local" name))

(define (models--port-label name port)
  (let ((n (models--short-name name)))
    (if (equal? port *models-default-port*)
        n
        (string-append n ":" port))))

(define (models--host-label host)
  (or (models--endpoint-name host)
      (if (models--disk? host) "disk" (models--server-label host))))

(define (models--server-label host)
  (let ((ssh (models--ssh-spec host)))
    (if ssh
        (models--port-label (nth 0 ssh) (nth 1 ssh))
        (let* ((hostport (nth 0 (string-split (models--rest (models--host-url host)) "/")))
               (parts (string-split hostport ":")))
          (models--port-label (nth 0 parts)
                              (if (> (length parts) 1) (nth 1 parts)
                                  *models-default-port*))))))

;; every host the list asks: the ones a person kept, the default one
;; first when it is not among them, and then every daemon the endpoint
;; registry holds. A daemon needs no saving, because its package names it.
(define (models-host-list)
  (let* ((hs (if (pair? models-hosts) models-hosts (list models-host)))
         (hs (if (member models-host hs) hs (cons models-host hs))))
    (append hs (filter (lambda (h) (not (member h hs))) (*models-daemon-hosts*)))))

(define (models--local? host)
  (and (not (models--disk? host))
       (not (models--ssh-spec host))
       (let ((url (models--host-url host)))
         (or (string-contains? url "//localhost")
             (string-contains? url "//127.0.0.1")))))

;;; --- the requests ---------------------------------------------------------------
;;; One door to a host: the host, the method, the path, a JSON body or
;;; #f, the seconds to wait, and K. K always gets an http reply plist, so
;;; a refused connection, a 404 and an ssh that answers nothing all read
;;; the same way. Tests replace this seam.
;;;
;;; A body names the model under both "model" and "name". Ollama renamed
;;; that field, and a host older than the rename still reads "name". A
;;; field the host does not know costs nothing: its JSON decoder drops it.

(define (models--sh-quote s)
  (string-append "'" (string-replace s "'" "'\\''") "'"))

;; one curl on the other machine, against that machine's own loopback,
;; writing the status code on a line of its own after the body
(define (models--ssh-curl ssh method path body seconds)
  (string-append
    "curl -s -m " (number->string seconds) " -X " method
    " -H 'Content-Type: application/json'"
    (if body (string-append " -d " (models--sh-quote (json-encode body))) "")
    " -w '\\n%{http_code}' http://127.0.0.1:" (nth 1 ssh) (nth 2 ssh) path))

;; the shell output read back as the plist an http reply answers, so
;; every caller above reads one shape
(define (models--ssh-reply out)
  (let* ((text (string-trim (or out "")))
         (lines (string-split text "\n"))
         (status (string->number (string-trim (nth (- (length lines) 1) lines))))
         (body (string-join (reverse (cdr (reverse lines))) "\n")))
    (if (not (number? status))
        (list 'ok #f 'status #f 'body text
              'error (if (equal? text "") "no answer over ssh" text))
        (let ((ok (and (>= status 200) (< status 300))))
          (append (list 'ok ok 'status status 'body body 'json (json-parse body))
                  (if ok
                      '()
                      (list 'error (if (equal? body "")
                                       (string-append "HTTP " (number->string status))
                                       body))))))))

(define (models--request host method path body seconds k)
  (let ((ssh (models--ssh-spec host)))
    (if ssh
        (let ((cmd (if (equal? (ssh-command) "") "ssh" (ssh-command))))
          (shell-command->string
            (string-append cmd " -o BatchMode=yes -o ConnectTimeout=5 "
                           (nth 0 ssh) " "
                           (models--sh-quote
                             (models--ssh-curl ssh method path body seconds)))
            (default-directory)
            (lambda (out) (k (models--ssh-reply out)))))
        (http-request (string-append (models--host-url host) path)
                      (append (list 'method method
                                    'timeout (* 1000 seconds)
                                    'headers (list 'user-agent "compos"))
                              (if body (list 'json body) '()))
                      k))))

(define *models-request* models--request)

(define (models--model-body name &rest extra)
  (append (list 'model name 'name name) extra))

;; plist-get stops the interpreter when it is handed #f, and JSON answers
;; leave out what they have nothing to say about
(define (models--text v) (if (string? v) v ""))

;;; --- what the host holds ----------------------------------------------------------
;;; /api/tags names every installed model. /api/ps names the ones in
;;; memory. One row per installed model, and a row for a loaded model the
;;; tags do not name, because a host can hold one.

(define (models--entry name size params quant loaded vram until)
  (list 'name name 'size size 'params params 'quant quant
        'loaded loaded 'vram vram 'until until))

(define (models--name obj)
  (let ((n (or (plist-get obj 'name) (plist-get obj 'model))))
    (models--text n)))

(define (models--models json)
  (let ((ms (plist-get json 'models)))
    (if (pair? ms) ms '())))

;; an OpenAI-shaped answer: data is the list, and id is the name
(define (models--openai-models json)
  (let ((ms (plist-get json 'data)))
    (if (pair? ms) ms '())))

;; A server that serves a file names the file. The path is the machine's
;; business, and the name at the end of it is the model.
(define (models--openai-name id)
  (if (string-prefix? "/" id)
      (let ((parts (string-split id "/")))
        (nth (- (length parts) 1) parts))
      id))

(define (models--openai-entry m)
  (append (models--entry (models--openai-name
                           (models--text (or (plist-get m 'id)
                                             (plist-get m 'name))))
                         #f "" "" #f #f "")
          ;; the server is up and will answer for this name; it does not
          ;; say which one it holds in memory, so the row does not either
          (list 'note "serving")))

;; "2026-09-17T18:04:33.12+05:30" -> "18:04", the host clock. A person
;; reads the clock, not the timestamp.
(define (models--clock stamp)
  (if (and (string? stamp) (> (string-length stamp) 16))
      (substring stamp 11 16)
      ""))

(define (models--loaded-row obj)
  (list (models--name obj)
        (plist-get obj 'size_vram)
        (models--clock (plist-get obj 'expires_at))))

(define (models--installed-entry m loaded)
  (let* ((name (models--name m))
         (d (plist-get m 'details))
         (r (assoc name loaded)))
    (models--entry name
                   (plist-get m 'size)
                   (models--text (plist-get d 'parameter_size))
                   (models--text (plist-get d 'quantization_level))
                   (if r #t #f)
                   (if r (nth 1 r) #f)
                   (if r (nth 2 r) ""))))

(define (models--merge installed loaded)
  (let* ((names (map models--name installed))
         (extra (filter (lambda (r) (not (member (car r) names))) loaded)))
    (append (map (lambda (m) (models--installed-entry m loaded)) installed)
            (map (lambda (r)
                   (models--entry (car r) (nth 1 r) "" "" #t (nth 1 r) (nth 2 r)))
                 extra))))

;; loaded first, then by name: what the host is doing now is the answer
;; the list is open for
(define (models--sort entries)
  (map cadr
       (sort (map (lambda (e)
                    (list (string-append (if (plist-get e 'loaded) "0" "1")
                                         (models--host-label (plist-get e 'host))
                                         " "
                                         (plist-get e 'name))
                          e))
                  entries))))

;; the host a row came from, and the host a command acts on
(define (models--entry-host e)
  (or (plist-get e 'host) models-host))

;; one host: its installed models, each row carrying the host it came
;; from, because every verb after this acts on that host and not on the
;; one a variable happens to name.
;;; --- what this machine keeps on disk --------------------------------------------
;;; du answers what the cache holds, one directory per model. The scan is
;;; its own seam, because it is a shell and not a request.

;; "…/hub/models--aac6fef--laya-mlx" is the cache's spelling of
;; "aac6fef/laya-mlx", and a plain directory is its own name.
(define (models--disk-name path)
  (let* ((parts (filter (lambda (p) (not (equal? p ""))) (string-split path "/")))
         (base (nth (- (length parts) 1) parts)))
    (if (string-prefix? "models--" base)
        (string-join (string-split (substring base 8 (string-length base)) "--") "/")
        base)))

;; A cache keeps its own bookkeeping beside the models it holds. Those
;; directories are not models: the shared blobs of the huggingface cache
;; are the bytes of the models above them, counted once each already.
(define *models-disk-skip* '("blobs" "refs" "snapshots" ".locks" "tmp"
                            "datasets" "modules" "version.txt"))

(define (models--disk-row line)
  (let ((parts (string-split (string-trim line) "\t")))
    (if (< (length parts) 2)
        #f
        (let ((kb (string->number (string-trim (nth 0 parts))))
              (path (string-trim (nth 1 parts))))
          (let ((name (models--disk-name path)))
            (if (or (not (number? kb)) (member name *models-disk-skip*))
                #f
                (append (models--entry name (* kb 1024) "" "" #f #f "")
                        (list 'note "on disk" 'path path))))))))

(define (models--disk-rows out)
  (filter (lambda (e) e)
          (map models--disk-row (string-split (string-trim (or out "")) "\n"))))

(define (models--disk-command)
  (string-append "du -sk "
                 (string-join (map (lambda (r) (string-append r "/*/"))
                                   models-disk-roots)
                              " ")
                 " 2>/dev/null"))

(define (models--disk-scan k)
  (shell-command->string (models--disk-command) (compos-home)
    (lambda (out) (k (models--disk-rows out)))))

(define *models-disk-scan* models--disk-scan)

(define (models--openai-fetch host k)
  (*models-request* host "GET" "/models" #f 10
    (lambda (reply)
      (if (not (http-ok? reply))
          (begin (models--note-error! host (http-message reply)) (k '()))
          (k (map (lambda (m)
                    (append (models--openai-entry m) (list 'host host)))
                  (models--openai-models (http-json reply))))))))

(define (models--host-fetch host k)
  (cond ((models--disk? host)
         (*models-disk-scan*
           (lambda (rows)
             (k (map (lambda (e) (append e (list 'host host))) rows)))))
        ((models--endpoint-name host) (models--daemon-fetch host k))
        ((models--openai? host) (models--openai-fetch host k))
        (else (models--ollama-fetch host k))))

;; a daemon's own answer: the checkpoints this machine holds, and which
;; of them it built. A stopped daemon still has a line, because a list
;; that hid what is not running is a list you cannot start anything from.
(define (models--daemon-fetch host k)
  (let ((name (models--endpoint-name host)))
    (if (not (*models-daemon-running?* name))
        (k (list (append (models--entry name #f "" "" #f #f "")
                         (list 'note "stopped" 'host host))))
        (*models-daemon-ask* name '(op "models")
          (lambda (reply)
            (if (not (http-ok? reply))
                (begin (models--note-error! host (http-message reply)) (k '()))
                (k (map (lambda (m)
                          (append (models--daemon-entry m) (list 'host host)))
                        (models--models (http-json reply))))))))))

(define (models--daemon-entry m)
  (append (models--entry (models--text (plist-get m 'name))
                         (plist-get m 'size) "" ""
                         (if (plist-get m 'loaded) #t #f) #f "")
          (list 'note "on disk" 'path (models--text (plist-get m 'path)))))

(define (models--daemon-ask name req k)
  (endpoint-ask-json name req models-daemon-timeout k))

;; the two seams a daemon is reached through: whether it holds its pipe
;; open, and the one request. A test replaces these and needs no daemon.
(define *models-daemon-ask* models--daemon-ask)
(define *models-daemon-running?* endpoint-connected?)

(define (models--ollama-fetch host k)
  (*models-request* host "GET" "/api/tags" #f 10
    (lambda (tags)
      (if (not (http-ok? tags))
          (begin (models--note-error! host (http-message tags)) (k '()))
          (*models-request* host "GET" "/api/ps" #f 10
            (lambda (ps)
              (k (map (lambda (e) (append e (list 'host host)))
                      (models--merge
                        (models--models (http-json tags))
                        (map models--loaded-row
                             (models--models (http-json ps))))))))))))

;; the hosts in order, one after the other: a host that does not answer
;; costs its own timeout and nothing else
(define (models--fetch-hosts hosts acc k)
  (if (null? hosts)
      (k (models--sort acc))
      (models--host-fetch (car hosts)
        (lambda (es) (models--fetch-hosts (cdr hosts) (append acc es) k)))))

(define (models--fetch buf k)
  (set! *models-error* #f)
  (set! *models-errors* '())
  (models--fetch-hosts (models-host-list) '() k))

;; the names the host holds in memory now. Another package asks this to
;; know what a request costs nothing to start.
(define (models-loaded k)
  (*models-request* models-host "GET" "/api/ps" #f 10
    (lambda (reply)
      (k (map models--name (models--models (http-json reply)))))))

;;; --- the list ---------------------------------------------------------------------

;; integer arithmetic all the way: a float prints its own rounding error
(define (models--scaled bytes unit suffix)
  (let* ((tenths (quotient (* 10 bytes) unit))
         (whole (quotient tenths 10))
         (frac (remainder tenths 10)))
    (string-append (number->string whole) "." (number->string frac) suffix)))

(define (models--size-label bytes)
  (cond ((not (number? bytes)) "")
        ((>= bytes 1073741824) (models--scaled bytes 1073741824 " GB"))
        ((>= bytes 1048576) (models--scaled bytes 1048576 " MB"))
        (else (string-append (number->string bytes) " B"))))

(define (models--state e)
  (if (not (plist-get e 'loaded))
      (or (plist-get e 'note) "")
      (models--loaded-state e)))

(define (models--loaded-state e)
  (if (plist-get e 'loaded)
      (let ((vram (models--size-label (plist-get e 'vram)))
            (until (plist-get e 'until)))
        (string-append "loaded"
                       (if (equal? vram "") "" (string-append " " vram))
                       (if (equal? until "") "" (string-append " until " until))))
      ""))

(define (models--cells buf e)
  (let ((loaded (plist-get e 'loaded)))
    (list (list (if loaded "*" "") "models-loaded")
          (list (models--host-label (models--entry-host e)) "dim")
          (list (plist-get e 'name) "models-name")
          (list (models--size-label (plist-get e 'size)) "models-size")
          (list (plist-get e 'params) "dim")
          (list (plist-get e 'quant) "dim")
          (list (models--state e) (if loaded "models-loaded" "dim")))))

;; a host as a person wrote it: an ssh host is not a URL and printing
;; one for it would name a machine that does not exist
(define (models--host-name host)
  (if (or (models--disk? host) (models--endpoint-name host) (models--ssh-spec host))
      host
      (models--host-url host)))

(define (models--host-line)
  (let ((hs (models-host-list)))
    (if (= (length hs) 1)
        (models--host-name (car hs))
        (string-append (number->string (length hs)) " hosts"))))

(define (models--errors-label)
  (string-join (map (lambda (e)
                      (string-append " - " (nth 0 e) ": no answer: " (nth 1 e)))
                    *models-errors*)
               ""))

(define (models--meta buf)
  (let* ((es (list-entries buf))
         (loaded (length (filter (lambda (e) (plist-get e 'loaded)) es))))
    (string-append
      (models--host-line)
      " - " (number->string (length es)) " models, "
      (number->string loaded) " loaded"
      (models--errors-label)
      (let ((age (cache-age-label buf)))
        (if age (string-append " - " age) "")))))

(define (models--current)
  (let ((e (list-current *models-buffer*)))
    (if e e (begin (message "no model on this line") #f))))

;;; --- load, unload, install, uninstall ----------------------------------------------

(effects! '(write external))

;; Ollama holds models: it loads them, pulls them and deletes them. A
;; daemon behind a pipe loads and unloads one too, and installs nothing.
;; An OpenAI-shaped server only answers, and disk only keeps files. The
;; verbs a host has no route for stop here and say so.
(define (models--says-no host what)
  (message (string-append (models--host-label host) " " what))
  #f)

(define (models--loads? host)
  (let ((kind (models--kind host)))
    (cond ((member kind '(ollama daemon)) #t)
          ((equal? kind 'disk)
           (models--says-no host "holds model files; what loads one is its own program"))
          (else (models--says-no host "serves models; it does not load them")))))

(define (models--manages? host)
  (let ((kind (models--kind host)))
    (cond ((equal? kind 'ollama) #t)
          ((equal? kind 'daemon)
           (models--says-no host "is a daemon: it loads and unloads, and installs nothing"))
          ((equal? kind 'disk)
           (models--says-no host "holds model files; what loads one is its own program"))
          (else (models--says-no host
                  "serves models; it does not load, install or delete them")))))

(define (models--report! verb name reply)
  (if (http-ok? reply)
      (message (string-append name ": " verb))
      (message (string-append name ": " verb " failed - "
                              (or (http-message reply) "no answer"))))
  (when (buffer-known? *models-buffer*) (cache-refresh! *models-buffer*)))

;; An empty prompt with a keep_alive loads the model and answers as soon
;; as it is in memory. keep_alive 0 is the same call the other way.
(define (models--keep-alive! host name value verb)
  (*models-request* host "POST" "/api/generate"
    (models--model-body name 'keep_alive value 'stream #f)
    600
    (lambda (reply) (models--report! verb name reply))))

;; one op on a daemon, started first if it is down: a person who asks for
;; a model loaded is asking for the program that holds it
(define (models--daemon-op! host op name verb)
  (let ((ep (models--endpoint-name host)))
    (if (not (endpoint-spec ep))
        (message (string-append ep ": no package registered this daemon"))
        (begin
          (unless (*models-daemon-running?* ep) (endpoint-ensure! ep))
          (*models-daemon-ask* ep (list 'op op 'model name)
            (lambda (reply) (models--report! verb name reply)))))))

(define-command "models-start" "Load the model on this line into the host memory"
  (lambda ()
    (let ((e (models--current)))
      (when (and e (models--loads? (models--entry-host e)))
        (let ((host (models--entry-host e))
              (name (plist-get e 'name)))
          (cond ((equal? (plist-get e 'note) "stopped") (models--serve-host! host))
                ((equal? (models--kind host) 'daemon)
                 (message (string-append "loading " name "..."))
                 (models--daemon-op! host "load" name "loaded"))
                (else
                 (message (string-append "loading " name "..."))
                 (models--keep-alive! host name models-keep-alive "loaded"))))))))

(define-command "models-stop" "Unload the model on this line from the host memory"
  (lambda ()
    (let ((e (models--current)))
      (when (and e (models--loads? (models--entry-host e)))
        (let ((host (models--entry-host e))
              (name (plist-get e 'name)))
          (if (equal? (models--kind host) 'daemon)
              (models--daemon-op! host "unload" name "unloaded")
              (models--keep-alive! host name 0 "unloaded")))))))

(define-command "models-install" "Install another model on this line's host"
  (lambda ()
    (let* ((e (list-current *models-buffer*))
           (host (if e (models--entry-host e) models-host))
           (label (models--host-label host)))
      (when (models--manages? host)
        (read-string (string-append "Install model on " label ": ")
          (lambda (input)
            (let ((name (string-trim input)))
              (unless (equal? name "")
                (message (string-append "pulling " name " on " label
                                        ", this takes minutes..."))
                (*models-request* host "POST" "/api/pull"
                  (models--model-body name 'stream #f)
                  models-pull-timeout
                  (lambda (reply)
                    (models--report! "installed" name reply)))))))))))

(effects! '(destroy external))

(define-command "models-uninstall" "Uninstall the model on this line from the host"
  (lambda ()
    (let ((e (models--current)))
      (when (and e (models--manages? (models--entry-host e)))
        (let ((name (plist-get e 'name)))
          (yes-or-no? (string-append "Uninstall " name " from "
                                     (models--host-name (models--entry-host e)) "? ")
            (lambda (ok)
              (when ok
                (*models-request* (models--entry-host e) "DELETE" "/api/delete"
                  (models--model-body name) 60
                  (lambda (reply)
                    (models--report! "uninstalled" name reply)))))))))))

;;; --- another host, and the server on this one --------------------------------------

(effects! '(write))

;; The list shows every host at once, so adding a host is the whole act:
;; nothing has to become current for its models to appear.
(define (models--add-host! h)
  (unless (member h models-hosts)
    (customize-save! 'models-hosts (append models-hosts (list h))))
  (when (buffer-known? *models-buffer*) (cache-refresh! *models-buffer*)))

(define-command "models-add-host" "Add a model host to the list"
  (lambda ()
    (read-string "Add host (name, URL, ssh:NAME, an address ending /v1, or disk): "
      (lambda (input)
        (let ((h (string-trim input)))
          (unless (equal? h "")
            (models--add-host! h)
            (message (string-append "models: " (models--host-name h)))))))))

(define-command "models-forget-host" "Drop this line's host from the list"
  (lambda ()
    (let ((e (models--current)))
      (when e
        (let ((host (models--entry-host e)))
          (cond ((not (member host models-hosts))
                 (message (string-append (models--host-label host)
                                         " comes from the daemon registry;"
                                         " it leaves when its package does")))
                ((< (length models-hosts) 2) (message "the last host stays"))
                (else
                 (customize-save! 'models-hosts
                                  (filter (lambda (h) (not (equal? h host)))
                                          models-hosts))
                 (message (string-append "models: forgot "
                                         (models--host-name host)))
                 (cache-refresh! *models-buffer*))))))))

(define-command "models-set-host" "Make one host the one models-base names"
  (lambda ()
    (minibuffer-read* "Default model host: "
      (map (lambda (h) (list h "")) models-hosts)
      (list (list 'confirm
                  (lambda (input)
                    (let ((h (string-trim input)))
                      (unless (equal? h "")
                        (customize-save! 'models-host h)
                        (models--add-host! h)
                        (message (string-append "models: "
                                                (models--host-name h)))))))))))

(effects! '(write external execute))

;; A host on the network is that machine's own business, so only the local
;; server starts from here. nohup keeps it after the editor stops: a
;; model server outlives the editor that asked for it. The sleep gives
;; the server time to bind its port before the version request.
(define (models--serve-command)
  (string-append
    "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" "
    "nohup ollama serve >> " (compos-home) "/ollama.log 2>&1 & sleep 2"))

(define (models--local-host)
  (let ((hs (filter models--local? (models-host-list))))
    (if (pair? hs) (car hs) #f)))

;; A daemon starts from its registered spec and answers before this says
;; it runs: python takes a moment to import, and a message that ran ahead
;; of the first answer would be a guess.
(define (models--serve-daemon! host)
  (let ((ep (models--endpoint-name host)))
    (if (not (endpoint-spec ep))
        (message (string-append ep ": no package registered this daemon"))
        (begin
          (message (string-append "starting " ep "..."))
          (endpoint-ensure! ep)
          (*models-daemon-ask* ep '(op "ping")
            (lambda (reply)
              (if (http-ok? reply)
                  (models--report! "the daemon runs" ep reply)
                  (message (string-append ep ": "
                                          (or (http-message reply) "no answer")
                                          " - see " (compos-home) "/" ep "-daemon.log")))))))))

(define (models--serve-ollama! host)
  (message "starting ollama...")
  (shell-command->string (models--serve-command) (default-directory)
    (lambda (out)
      (*models-request* host "GET" "/api/version" #f 10
        (lambda (reply)
          (if (http-ok? reply)
              (models--report! "the server runs" (models--host-url host) reply)
              (message (string-append "ollama did not start - see "
                                      (compos-home) "/ollama.log"))))))))

(define (models--serve-host! host)
  (if (equal? (models--kind host) 'daemon)
      (models--serve-daemon! host)
      (models--serve-ollama! host)))

(define-command "models-serve" "Start the server or daemon this line's host is"
  (lambda ()
    (let* ((e (list-current *models-buffer*))
           (host (and e (models--entry-host e))))
      (if (and host (equal? (models--kind host) 'daemon))
          (models--serve-daemon! host)
          (let ((local (models--local-host)))
            (if local
                (models--serve-ollama! local)
                (message "no host here is this machine - start the server there")))))))

(define-command "models-unserve" "Stop the daemon this line's host is"
  (lambda ()
    (let ((e (models--current)))
      (when e
        (let ((host (models--entry-host e)))
          (if (not (equal? (models--kind host) 'daemon))
              (message (string-append (models--host-label host)
                                      " did not start from here, so it does not stop here"))
              (let ((ep (models--endpoint-name host)))
                (endpoint-stop! ep)
                (message (string-append ep ": the daemon is stopped"))
                (cache-refresh! *models-buffer*))))))))

;;; --- what a model is ----------------------------------------------------------------
;;; /api/show answers what the file holds. The detail goes to the window
;;; the list opens its rows into, and the list keeps the point.

(effects! '(write display))

(define (models--pad s n)
  (if (>= (string-length s) n) s (models--pad (string-append s " ") n)))

(define (models--line label v)
  (if (and (string? v) (not (equal? v "")))
      (string-append (models--pad label 15) v "\n")
      ""))

(define (models--block label v)
  (if (and (string? v) (not (equal? v "")))
      (string-append "\n" label "\n" v "\n")
      ""))

(define (models--detail-text name json)
  (let ((d (plist-get json 'details)))
    (string-append
      name "\n\n"
      (models--line "family" (plist-get d 'family))
      (models--line "parameters" (plist-get d 'parameter_size))
      (models--line "quantization" (plist-get d 'quantization_level))
      (models--line "format" (plist-get d 'format))
      (models--block "parameters" (plist-get json 'parameters))
      (models--block "template" (plist-get json 'template)))))

;; A host with no /api/show still has an answer: the row is what this
;; machine knows about that model, and showing it beats a message saying
;; the host cannot be asked.
(define (models--row-text e)
  (string-append
    (plist-get e 'name) "\n\n"
    (models--line "host" (models--host-name (models--entry-host e)))
    (models--line "state" (models--state e))
    (models--line "size" (models--size-label (plist-get e 'size)))
    (models--line "params" (plist-get e 'params))
    (models--line "quant" (plist-get e 'quant))
    (models--line "path" (plist-get e 'path))))

(define (models--show-text! name text)
  (unless (buffer-exists? *models-detail-buffer*)
    (buffer-create *models-detail-buffer*))
  (buffer-delete-range! *models-detail-buffer* 0
                        (buffer-size *models-detail-buffer*))
  (buffer-insert! *models-detail-buffer* 0 text)
  (display-buffer-detail! *models-detail-buffer* *models-buffer*))

(define (models--show-detail! name json)
  (models--show-text! name (models--detail-text name json)))

(define-command "models-show" "Show what the model on this line is"
  (lambda ()
    (let ((e (models--current)))
      (when e
        (let ((host (models--entry-host e))
              (name (plist-get e 'name)))
          (if (not (equal? (models--kind host) 'ollama))
              (models--show-text! name (models--row-text e))
              (*models-request* host "POST" "/api/show"
                (models--model-body name) 30
                (lambda (reply)
                  (if (http-ok? reply)
                      (models--show-detail! name (http-json reply))
                      (message (string-append name ": "
                                              (or (http-message reply)
                                                  "no answer"))))))))))))

;;; --- the list buffer ------------------------------------------------------------------

(effects! '(read external))

(define-command "models-refresh" "Ask the host for its models again"
  (lambda ()
    (message "asking the host...")
    (cache-refresh! *models-buffer*)))

(define-list-mode! "models-mode"
  (list
    'doc (string-append
           "Every model each host holds - the ones in models-hosts, and "
           "every daemon the endpoint registry names - with the loaded "
           "ones first. `RET` shows what a model is, `s` loads it into "
           "that host's memory, `k` unloads it, `i` installs another, `d` "
           "uninstalls one. `S` starts this line's server or daemon, and "
           "`K` stops the daemon. `h` adds a host, `H` forgets this "
           "line's host.")
    'buffer *models-buffer*
    'rows (lambda (buf) (list-entries buf))
    'cache-fetch models--fetch
    'cache-ttl models-cache-ttl
    'columns (lambda (buf)
               (list (list "" 1) (list "host" 12) (list "model" 22)
                     (list "size" 8) (list "params" 8) (list "quant" 7)
                     (list "state" #f)))
    'cells models--cells
    'title (lambda (buf) "Models")
    'meta models--meta
    'total (lambda (buf) (length (list-entries buf)))
    ;; no local-filter here: it caches the source rows once, and the next
    ;; answer from the host would never reach the table. / still filters.
    'no-marks #t
    'key (lambda (buf e)
           (string-append (models--host-label (models--entry-host e)) " "
                          (plist-get e 'name)))
    'footer (lambda (buf)
              '(("RET" "show") ("s" "load") ("k" "unload") ("S" "start host")
                ("K" "stop daemon") ("i" "install") ("d" "uninstall")
                ("h" "add host") ("H" "forget host")
                ("g" "refresh") ("q" "quit")))
    'keys '(("RET" "models-show") ("s" "models-start") ("k" "models-stop")
            ("i" "models-install") ("d" "models-uninstall")
            ("S" "models-serve") ("K" "models-unserve")
            ("h" "models-add-host") ("H" "models-forget-host")
            ("g" "models-refresh") ("q" "quit-window"))))

(define-command "local-models" "List the models every model host holds"
  (lambda () (list-mode-show! "models-mode")))

;;; --- the public surface -----------------------------------------------------------------

(category! 'system)
(domain! 'llm)
(effects! '(read external))

(public! 'local-models
  "M-x local-models - list the models every model host holds, and which of them each keeps loaded")
(public! 'models-base
  "(models-base) - the URL of the model host the list talks to")
(public! 'models-loaded
  "(models-loaded K) - K gets the names of the models the host holds in memory now")

(effects! '(write external))

(public! 'models-install
  "M-x models-install - install another model on the current host")
(public! 'models-set-host
  "M-x models-set-host - name the host models-base and models-loaded talk to")
(public! 'models-add-host
  "M-x models-add-host - add a host to the model list: a name, a URL, ssh:NAME, an OpenAI-shaped address ending /v1, or disk for this machine's model files. A daemon needs no adding: registering it as an endpoint that serves models puts it here.")
(public! 'models-serve
  "M-x models-serve - start the server or daemon this line's host is: ollama on this machine, or a registered model daemon")
(public! 'models-unserve
  "M-x models-unserve - stop the daemon this line's host is")

(defrecipe! "which local models are running" "(local-models)")
(defrecipe! "install a local model" "(run-command \"models-install\")")
