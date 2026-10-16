;;; models-test.scm --- packages/models.scm: the models a local host holds.
;;;
;;; Every test that talks to a host replaces a seam - *models-request* for
;;; a server, *models-disk-scan* for the files, and the two daemon seams -
;;; so no test needs a model server, and none starts a daemon.

(domain! 'testing)
(effects! '(write))

(define t--models-held '())

(define (t--models-reply json)
  (list 'ok #t 'status 200 'body "" 'json json))

(define (t--models-tags)
  (list 'models
        (list (list 'name "llama3:8b" 'size 4661224676
                    'details (list 'family "llama" 'parameter_size "8.0B"
                                   'quantization_level "Q4_0"))
              (list 'name "qwen2.5:0.5b" 'size 394998579
                    'details (list 'parameter_size "0.5B"
                                   'quantization_level "Q4_K_M")))))

(define (t--models-ps)
  (list 'models
        (list (list 'name "qwen2.5:0.5b" 'size_vram 1073741824
                    'expires_at "2026-09-17T18:04:33.12+05:30"))))

;; the calls the last test made, newest first
(define t--models-calls '())

(define (t--models-stub!)
  (set! t--models-calls '())
  (set! *models-request*
    (lambda (host method path body seconds k)
      (set! t--models-calls (cons (list method path body host) t--models-calls))
      (k (cond ((equal? path "/api/tags") (t--models-reply (t--models-tags)))
               ((equal? path "/api/ps") (t--models-reply (t--models-ps)))
               (else (t--models-reply '())))))))

;; the requests the last test sent to a daemon, newest first
(define t--daemon-calls '())

;; a daemon that runs and answers with these checkpoints
(define (t--models-daemon-stub! models)
  (set! t--daemon-calls '())
  (set! *models-daemon-running?* (lambda (name) #t))
  (set! *models-daemon-ask*
    (lambda (name req k)
      (set! t--daemon-calls (cons (list name req) t--daemon-calls))
      (k (t--models-reply (list 'ok #t 'models models))))))

(define (t--models-setup!)
  (set! t--models-held
        (list *models-request* models-host *models-error* models-hosts
              *models-daemon-hosts* *models-daemon-ask* *models-daemon-running?*))
  (set! models-host "http://localhost:11434")
  (set! models-hosts (list "http://localhost:11434"))
  (set! *models-error* #f)
  (set! *models-errors* '())
  ;; the daemons a package registered are real; a test says which hosts
  ;; it is about, so the registry does not walk into every other test
  (set! *models-daemon-hosts* (lambda () '()))
  (t--models-stub!))

(define (t--models-teardown!)
  (set! *models-request* (nth 0 t--models-held))
  (set! models-host (nth 1 t--models-held))
  (set! *models-error* (nth 2 t--models-held))
  (set! models-hosts (nth 3 t--models-held))
  (set! *models-daemon-hosts* (nth 4 t--models-held))
  (set! *models-daemon-ask* (nth 5 t--models-held))
  (set! *models-daemon-running?* (nth 6 t--models-held))
  (set! t--daemon-calls '())
  (set! *models-errors* '())
  (when (buffer-exists? *models-buffer*) (buffer-kill! *models-buffer*))
  (when (buffer-exists? *models-detail-buffer*)
    (buffer-kill! *models-detail-buffer*)))

(define (t--models-show!)
  (list-mode-show! "models-mode")
  (wait-until (lambda () (string-contains? (buffer-text *models-buffer*) "llama3"))
              3000))

(deftest 'models-a-host-is-a-url
  "a name a person types becomes the URL the requests go to"
  (lambda ()
    (check-equal! (models--host-url "") "http://localhost:11434" "nothing is this machine")
    (check-equal! (models--host-url "local") "http://localhost:11434" "so is local")
    (check-equal! (models--host-url "box.local") "http://box.local:11434"
                  "a bare name takes the scheme and the port")
    (check-equal! (models--host-url "10.0.0.4:8080") "http://10.0.0.4:8080"
                  "a port the person gave stays")
    (check-equal! (models--host-url "http://box:11434/") "http://box:11434"
                  "the trailing slash goes")
    (check-equal! (models--host-url "https://gpu.example.com/ollama")
                  "https://gpu.example.com/ollama"
                  "a path means a proxy, and no port is added")))

(deftest 'models-labels-read-as-a-person-reads-them
  "bytes become GB, and a timestamp becomes a clock"
  (lambda ()
    (check-equal! (models--size-label 4661224676) "4.3 GB" "a model in GB")
    (check-equal! (models--size-label 268435456) "256.0 MB" "a small one in MB")
    (check-equal! (models--size-label #f) "" "no size, no label")
    (check-equal! (models--clock "2026-09-17T18:04:33.12+05:30") "18:04" "the clock")
    (check-equal! (models--clock #f) "" "no expiry, no clock")))

(deftest 'models-the-loaded-ones-come-first
  "the list answers what the host is doing now, before what it could do"
  (lambda ()
    (let* ((rows (models--sort
                   (models--merge (models--models (t--models-tags))
                                  (map models--loaded-row
                                       (models--models (t--models-ps))))))
           (first (nth 0 rows))
           (second (nth 1 rows)))
      (check-equal! (length rows) 2 "one row per installed model")
      (check-equal! (plist-get first 'name) "qwen2.5:0.5b" "the loaded one is first")
      (check-true! (plist-get first 'loaded) "and it says it is loaded")
      (check-equal! (plist-get first 'vram) 1073741824 "with the memory it holds")
      (check-equal! (plist-get first 'until) "18:04" "and when it goes")
      (check-equal! (plist-get second 'name) "llama3:8b" "the other one follows")
      (check-false! (plist-get second 'loaded) "and it is not loaded")
      (check-equal! (plist-get second 'params) "8.0B" "it reads its own details"))))

(deftest 'models-a-loaded-model-the-tags-do-not-name-still-gets-a-row
  "a host can hold a model in memory that it does not list"
  (lambda ()
    (let ((rows (models--merge '() (list (list "ghost:7b" 700000000 "18:09")))))
      (check-equal! (length rows) 1 "the row is there")
      (check-equal! (plist-get (nth 0 rows) 'name) "ghost:7b" "under its own name")
      (check-true! (plist-get (nth 0 rows) 'loaded) "and it is loaded"))))

(deftest 'models-the-list-shows-what-the-host-holds
  "the table, the state column, and the meta line"
  (lambda ()
    (t--models-setup!)
    (check-true! (t--models-show!) "the rows arrive")
    (let* ((text (buffer-text *models-buffer*))
           (lines (string-split text "\n")))
      (check-true! (string-contains? text "qwen2.5:0.5b") "the loaded model is there")
      (check-true! (string-contains? text "4.3 GB") "a size reads as a size")
      (check-true! (string-contains? text "loaded 1.0 GB until 18:04")
                   "the state says what the host holds and for how long")
      (check-true! (string-contains? text "2 models, 1 loaded")
                   "the meta counts both")
      (check-true! (string-contains? text "http://localhost:11434")
                   "and names the host"))
    (t--models-teardown!)))

(deftest 'models-a-host-that-does-not-answer-says-so
  "a refused connection is the answer, not an empty table with no reason"
  (lambda ()
    (t--models-setup!)
    (set! *models-request*
      (lambda (host method path body seconds k)
        (k (list 'ok #f 'status #f 'body "" 'error "connection refused"))))
    (list-mode-show! "models-mode")
    (wait-until (lambda () (string-contains? (buffer-text *models-buffer*)
                                             "connection refused"))
                3000)
    (check-true! (string-contains? (buffer-text *models-buffer*)
                                   "no answer: connection refused")
                 "the meta line carries the reason")
    (check-equal! (length (list-entries *models-buffer*)) 0 "and the table is empty")
    (t--models-teardown!)))

(deftest 'models-load-and-unload-are-one-request-each
  "s and k send the same call with the other keep_alive"
  (lambda ()
    (t--models-setup!)
    (check-true! (t--models-show!) "the rows arrive")
    (set! t--models-calls '())
    (with-current-buffer *models-buffer* (lambda () (run-command "models-start")))
    (let ((call (nth 0 (reverse t--models-calls))))
      (check-equal! (nth 0 call) "POST" "a load is a POST")
      (check-equal! (nth 1 call) "/api/generate" "to generate, with no prompt")
      (check-equal! (plist-get (nth 2 call) 'keep_alive) models-keep-alive
                    "and it names how long the model stays")
      (check-equal! (plist-get (nth 2 call) 'model) "qwen2.5:0.5b"
                    "the model on the line")
      (check-equal! (plist-get (nth 2 call) 'name) "qwen2.5:0.5b"
                    "under the old field name as well, for an older host"))
    (set! t--models-calls '())
    (with-current-buffer *models-buffer* (lambda () (run-command "models-stop")))
    (let ((call (nth 0 (reverse t--models-calls))))
      (check-equal! (nth 1 call) "/api/generate" "an unload is the same call")
      (check-equal! (plist-get (nth 2 call) 'keep_alive) 0 "with keep_alive 0"))
    (t--models-teardown!)))

(deftest 'models-what-a-model-is-goes-to-its-own-buffer
  "RET asks the host to show the model, and renders the answer"
  (lambda ()
    (t--models-setup!)
    (check-true! (t--models-show!) "the rows arrive")
    (set! *models-request*
      (lambda (host method path body seconds k)
        (k (t--models-reply
             (list 'details (list 'family "qwen2" 'parameter_size "0.5B"
                                  'quantization_level "Q4_K_M")
                   'parameters "stop token")))))
    (with-current-buffer *models-buffer* (lambda () (run-command "models-show")))
    (let ((text (buffer-text *models-detail-buffer*)))
      (check-true! (string-contains? text "qwen2.5:0.5b") "the name heads the page")
      (check-true! (string-contains? text "family         qwen2") "the family")
      (check-true! (string-contains? text "quantization   Q4_K_M") "the quantization")
      (check-true! (string-contains? text "stop token") "and the parameters"))
    (t--models-teardown!)))

(deftest 'models-an-ssh-host-is-a-shell-not-a-socket
  "ssh:NAME names a machine the requests run on, against its own loopback"
  (lambda ()
    (check-equal! (models--ssh-spec "ssh:marilyn") (list "marilyn" "11434" "")
                  "the port fills in")
    (check-equal! (models--ssh-spec "ssh:marilyn:8089/v1")
                  (list "marilyn" "8089" "/v1")
                  "and the port and path a person gave stay")
    (check-false! (models--ssh-spec "http://box:11434") "a URL is not an ssh host")
    (check-equal! (models--host-label "ssh:marilyn") "marilyn"
                  "the host column names the machine")
    (check-equal! (models--host-label "http://box.local:11434") "box.local"
                  "and the host of a URL, without the port")
    (check-false! (models--local? "ssh:marilyn") "an ssh host is another machine")
    (check-true! (models--local? "localhost") "and localhost is this one")
    (check-true! (string-contains?
                   (models--ssh-curl (list "marilyn" "11434" "") "GET" "/api/tags" #f 10)
                   "http://127.0.0.1:11434/api/tags")
                 "the request runs there, against that machine's loopback")))

(deftest 'models-the-ssh-answer-reads-as-an-http-reply
  "the status code on the last line, the body above it"
  (lambda ()
    (let ((r (models--ssh-reply "{\"models\":[]}\n200")))
      (check-true! (http-ok? r) "200 is an answer")
      (check-equal! (plist-get (http-json r) 'models) '() "and the body is its JSON"))
    (let ((r (models--ssh-reply "ssh: connect to host marilyn: refused")))
      (check-false! (http-ok? r) "a shell that says nothing is no answer")
      (check-true! (string-contains? (http-message r) "refused") "and it says why"))
    (let ((r (models--ssh-reply "not found\n404")))
      (check-false! (http-ok? r) "a 404 is not an answer either"))))

(deftest 'models-every-host-in-one-list
  "the list asks every host, and each row says which host holds it"
  (lambda ()
    (t--models-setup!)
    (set! models-hosts (list "http://localhost:11434" "ssh:marilyn"))
    (set! *models-request*
      (lambda (host method path body seconds k)
        (k (t--models-reply
             (if (equal? path "/api/ps")
                 (list 'models '())
                 (list 'models
                       (list (list 'name (string-append (models--host-label host) ":1b")
                                   'size 1073741824
                                   'details (list 'parameter_size "1.0B"
                                                  'quantization_level "Q4_K_M")))))))))
    (list-mode-show! "models-mode")
    (wait-until (lambda () (string-contains? (buffer-text *models-buffer*) "marilyn:1b"))
                3000)
    (let ((text (buffer-text *models-buffer*)))
      (check-true! (string-contains? text "local:1b") "the model on this machine")
      (check-true! (string-contains? text "marilyn:1b") "and the one on the ssh host")
      (check-true! (string-contains? text "2 hosts") "the meta counts the hosts")
      (check-true! (string-contains? text "2 models") "and the models they hold"))
    (let ((rows (list-entries *models-buffer*)))
      (check-equal! (length rows) 2 "one row per model")
      (check-true! (member "ssh:marilyn" (map models--entry-host rows))
                   "and a row carries the host it came from"))
    (t--models-teardown!)))

(deftest 'models-an-openai-shaped-server-is-read-and-not-managed
  "a /v1 address answers with its models, and the verbs that change a host stop"
  (lambda ()
    (check-true! (models--openai? "http://127.0.0.1:8127/v1")
                 "an address ending /v1 is an OpenAI-shaped server")
    (check-false! (models--openai? "http://localhost:11434") "an ollama host is not")
    (check-true! (models--openai? "ssh:marilyn:8089/v1") "and one over ssh is")
    (check-equal! (models--host-label "http://127.0.0.1:8127/v1") "local:8127"
                  "this machine, and the port that tells two servers apart")
    (check-equal! (models--openai-name "/Users/svs/.compos/models/title") "title"
                  "a served file reads as the model at the end of the path")
    (t--models-setup!)
    (set! models-host "http://127.0.0.1:8127/v1")
    (set! models-hosts (list "http://127.0.0.1:8127/v1"))
    (set! *models-request*
      (lambda (host method path body seconds k)
        (set! t--models-calls (cons (list method path body host) t--models-calls))
        (k (t--models-reply (list 'data (list (list 'id "desert-ant/title")))))))
    (list-mode-show! "models-mode")
    (wait-until (lambda () (string-contains? (buffer-text *models-buffer*) "desert-ant"))
                3000)
    (check-true! (string-contains? (buffer-text *models-buffer*) "serving")
                 "the row says the server answers for that model")
    (check-equal! (nth 1 (nth 0 (reverse t--models-calls))) "/models"
                  "the models come from /v1/models, and nothing asks ollama's paths")
    (set! t--models-calls '())
    (with-current-buffer *models-buffer* (lambda () (run-command "models-start")))
    (check-equal! t--models-calls '()
                  "and a load sends nothing to a server that only answers")
    (t--models-teardown!)))

(deftest 'models-the-disk-holds-models-no-server-runs
  "a model file is in the list, and it does not claim to be a service"
  (lambda ()
    (check-true! (models--disk? "disk") "disk names this machine's files")
    (check-false! (models--disk? "http://localhost:11434") "a URL does not")
    (check-false! (models--openai? "disk") "and disk is no OpenAI server")
    (check-false! (models--local? "disk") "nor a server to start")
    (check-equal! (models--disk-name
                    "/Users/svs/.cache/huggingface/hub/models--aac6fef--laya-mlx/")
                  "aac6fef/laya-mlx"
                  "the cache spells a repo id with dashes; the list spells it back")
    (check-equal! (models--disk-name "/Users/svs/.compos/models/title/") "title"
                  "and a plain directory is its own name")
    (let ((rows (models--disk-rows
                  "3584\t/Users/svs/.cache/huggingface/hub/models--aac6fef--laya-mlx/\nnot a row\n822872\t/Users/svs/.cache/huggingface/hub/blobs/\n286720\t/Users/svs/.compos/models/title/")))
      (check-equal! (length rows) 2
                    "one row per model: not a bad line, and not the cache's own blobs")
      (check-equal! (plist-get (nth 0 rows) 'name) "aac6fef/laya-mlx" "the model")
      (check-equal! (plist-get (nth 0 rows) 'size) 3670016 "its size in bytes")
      (check-false! (plist-get (nth 0 rows) 'loaded) "a file is not loaded")
      (check-equal! (models--state (nth 0 rows)) "on disk" "and the state says so"))))

(deftest 'models-a-disk-row-sends-no-request
  "the verbs that change a host stop at a file"
  (lambda ()
    (t--models-setup!)
    (set! models-host "disk")
    (set! models-hosts (list "disk"))
    (set! *models-disk-scan*
      (lambda (k)
        (k (models--disk-rows
             "3584\t/Users/svs/.cache/huggingface/hub/models--aac6fef--laya-mlx/"))))
    (list-mode-show! "models-mode")
    (wait-until (lambda () (string-contains? (buffer-text *models-buffer*) "laya")) 3000)
    (let ((text (buffer-text *models-buffer*)))
      (check-true! (string-contains? text "laya-mlx") "the model is in the list")
      (check-true! (string-contains? text "on disk") "and it says no server holds it"))
    (set! t--models-calls '())
    (with-current-buffer *models-buffer* (lambda () (run-command "models-start")))
    (check-equal! t--models-calls '() "a load sends nothing to a directory")
    (set! *models-disk-scan* models--disk-scan)
    (t--models-teardown!)))

(deftest 'models-a-daemon-host-comes-from-the-endpoint-registry
  "a package registers its daemon once, and the list reads that registry"
  (lambda ()
    (endpoint-register! "t-models-daemon" '(command "cat" framing "line" serves "models"))
    (endpoint-register! "t-models-other" '(command "cat" framing "line"))
    (check-true! (member "endpoint:t-models-daemon" (models--daemon-hosts))
                 "a daemon that says it serves models is a host")
    (check-false! (member "endpoint:t-models-other" (models--daemon-hosts))
                  "and one that says nothing is not")
    (check-true! (member "endpoint:t-models-daemon" (models-host-list))
                 "so it is in the list with no host saved anywhere")))

(deftest 'models-a-daemon-is-a-kind-of-its-own
  "a program behind a pipe is not a URL, and not a file"
  (lambda ()
    (check-equal! (models--endpoint-name "endpoint:laya") "laya" "the daemon's name")
    (check-false! (models--endpoint-name "http://localhost:11434") "a URL is not one")
    (check-equal! (models--kind "endpoint:laya") 'daemon "the kind")
    (check-equal! (models--kind "disk") 'disk "beside the files")
    (check-equal! (models--kind "http://127.0.0.1:8127/v1") 'openai "and the servers")
    (check-equal! (models--kind "http://localhost:11434") 'ollama "and ollama")
    (check-equal! (models--host-label "endpoint:laya") "laya"
                  "the host column names the daemon")
    (check-equal! (models--host-name "endpoint:laya") "endpoint:laya"
                  "and nothing prints a URL for a pipe")
    (check-false! (models--openai? "endpoint:laya") "a daemon is no OpenAI server")
    (check-false! (models--local? "endpoint:laya") "nor the ollama on this machine")))

(deftest 'models-a-stopped-daemon-still-has-a-line
  "a list that hid what is not running is a list you cannot start from"
  (lambda ()
    (t--models-setup!)
    (set! *models-daemon-running?* (lambda (name) #f))
    (models--host-fetch "endpoint:t-laya"
      (lambda (rows)
        (check-equal! (length rows) 1 "the daemon has a row")
        (check-equal! (plist-get (nth 0 rows) 'name) "t-laya" "under its own name")
        (check-equal! (models--state (nth 0 rows)) "stopped" "and it says it is stopped")))
    (t--models-teardown!)))

(deftest 'models-a-running-daemon-lists-the-checkpoints-it-holds
  "the daemon answers what this machine keeps, and which of it is built"
  (lambda ()
    (t--models-setup!)
    (t--models-daemon-stub!
      (list (list 'name "aac6fef/laya-mlx" 'loaded #t 'size 846231836
                  'path "/Users/svs/.cache/huggingface/hub/models--aac6fef--laya-mlx")))
    (models--host-fetch "endpoint:t-laya"
      (lambda (rows)
        (check-equal! (length rows) 1 "one row per checkpoint")
        (check-equal! (plist-get (nth 0 rows) 'name) "aac6fef/laya-mlx" "the model")
        (check-true! (plist-get (nth 0 rows) 'loaded) "the daemon holds it")
        (check-equal! (models--state (nth 0 rows)) "loaded" "and the state says so")
        (check-equal! (models--size-label (plist-get (nth 0 rows) 'size)) "807.0 MB"
                      "with what it costs on disk")))
    (check-equal! (plist-get (nth 1 (nth 0 t--daemon-calls)) 'op) "models"
                  "the list asks the daemon for its models and nothing else")
    (t--models-teardown!)))

(deftest 'models-a-daemon-loads-and-unloads-and-installs-nothing
  "s and k are one request each; i has no route and sends none"
  (lambda ()
    (t--models-setup!)
    (set! models-host "endpoint:t-laya")
    (set! models-hosts (list "endpoint:t-laya"))
    (endpoint-register! "t-laya" '(command "cat" framing "line" serves "models"))
    (t--models-daemon-stub!
      (list (list 'name "aac6fef/laya-mlx" 'loaded #f 'size 846231836 'path "")))
    (list-mode-show! "models-mode")
    (wait-until (lambda () (string-contains? (buffer-text *models-buffer*) "laya-mlx")) 3000)
    (check-true! (string-contains? (buffer-text *models-buffer*) "laya-mlx")
                 "the checkpoint is in the list")
    ;; the answer to a load refreshes the table, so the newest call is
    ;; that refresh: the verb is the first call, not the last
    (set! t--daemon-calls '())
    (with-current-buffer *models-buffer* (lambda () (run-command "models-start")))
    (let ((req (nth 1 (nth 0 (reverse t--daemon-calls)))))
      (check-equal! (plist-get req 'op) "load" "s loads it in the daemon")
      (check-equal! (plist-get req 'model) "aac6fef/laya-mlx" "the model on the line"))
    (set! t--daemon-calls '())
    (with-current-buffer *models-buffer* (lambda () (run-command "models-stop")))
    (check-equal! (plist-get (nth 1 (nth 0 (reverse t--daemon-calls))) 'op) "unload"
                  "and k unloads it")
    (set! t--daemon-calls '())
    (with-current-buffer *models-buffer* (lambda () (run-command "models-install")))
    (check-equal! t--daemon-calls '()
                  "i has no route on a daemon, so it sends nothing")
    (set! t--daemon-calls '())
    (set! t--models-calls '())
    (with-current-buffer *models-buffer* (lambda () (run-command "models-unserve")))
    (check-false! (member "unload"
                          (map (lambda (c) (plist-get (nth 1 c) 'op)) t--daemon-calls))
                  "K stops the program; it does not ask the program to unload")
    (check-equal! t--models-calls '() "and no server is asked anything")
    (t--models-teardown!)))
