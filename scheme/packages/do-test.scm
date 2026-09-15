;;; do-test.scm --- the Do prompt: phrase in, one catalog command out.
;;;
;;; The model is a seam. These tests rebind *do--ask* and read what the
;;; resolver does around it: the free paths that skip the model, the
;;; memory, the reply parser, and the confirm rule.

(domain! 'testing)
(effects! '(write))

(define *do-test-asked* '())

(define (do-test-stub answer)
  (lambda (phrase k)
    (set! *do-test-asked* (cons phrase *do-test-asked*))
    (k (list 'ok answer))))

(define (do-test-resolve phrase)
  (let ((got #f))
    (do--resolve phrase (lambda (r) (set! got r)))
    got))

(define-command "zz-do-test-destroyer" "A test command that destroys" (lambda () #f))
(catalog-meta! 'command "zz-do-test-destroyer" 'effects '(destroy))

(deftest 'do-runs-an-exact-command-name-without-the-model
  "a phrase that is a command name resolves as exact and asks nothing"
  (lambda ()
    (set! *do--ask* (do-test-stub "undo"))
    (set! *do-test-asked* '())
    (check-equal! (do-test-resolve "kill-buffer") (list 'exact "kill-buffer") "the name is the answer")
    (check-equal! *do-test-asked* '() "the model was not asked")
    (set! *do--ask* #f)))

(deftest 'do-asks-the-model-for-a-sentence
  "a sentence goes to the model and its name comes back as model"
  (lambda ()
    (set! *do--ask* (do-test-stub "undo"))
    (set! *do-test-asked* '())
    (do-forget! "take that back")
    (check-equal! (do-test-resolve "take that back") (list 'model "undo") "the model's pick")
    (check-equal! *do-test-asked* (list "take that back") "the model saw the phrase")
    (set! *do--ask* #f)))

(deftest 'do-remembers-a-phrase-and-skips-the-model-next-time
  "a remembered phrase resolves from memory, case and spaces aside"
  (lambda ()
    (set! *do--ask* (do-test-stub "undo"))
    (set! *do-test-asked* '())
    (do-remember! "take that back" "undo")
    (check-equal! (do-test-resolve "  Take That Back ") (list 'memory "undo") "memory answers")
    (check-equal! *do-test-asked* '() "the model was not asked")
    (do-forget! "take that back")
    (check-equal! (do-recall "take that back") #f "forget clears it")
    (set! *do--ask* #f)))

(deftest 'do-catalog-prompt-lists-every-command-with-a-short-doc
  "the system prompt names each command with its doc, and the names list matches"
  (lambda ()
    (check-true! (string-contains? (do--catalog-prompt) "\nkill-buffer: Kill a buffer")
                 "a command and its doc are one line")
    (check-true! (if (member "kill-buffer" (do--catalog-names)) #t #f) "the enum holds the name")
    (check-equal! (length (do--catalog-names)) (length (command-names)) "every command is offered")))

(deftest 'do-parses-the-ollama-reply-and-rejects-unknown-names
  "the reply parser reads message.content as JSON and checks the name"
  (lambda ()
    (check-equal! (do--parse-reply
                    (list 'ok #t 'status 200 'body "{\"message\":{\"content\":\"undo\"}}"))
                  (list 'ok "undo") "the bare name after the assistant prefix passes")
    (check-equal! (do--parse-reply
                    (list 'ok #t 'status 200 'body "{\"message\":{\"content\":\" undo\\\"}\"}}"))
                  (list 'ok "undo") "a closing quote and brace are dropped")
    (check-equal! (do--parse-reply
                    (list 'ok #t 'status 200
                          'body "{\"message\":{\"content\":\"{\\\"command\\\":\\\"undo\\\"}\"}}"))
                  (list 'ok "undo") "a whole JSON object still passes")
    (check-equal! (car (do--parse-reply
                         (list 'ok #t 'status 200
                               'body "{\"message\":{\"content\":\"{\\\"command\\\":\\\"no-such-thing\\\"}\"}}")))
                  'error "a name outside the catalog is an error")
    (check-equal! (car (do--parse-reply (list 'ok #f 'error "connection refused")))
                  'error "a failed request is an error")))

(deftest 'do-reads-a-llama-server-reply-too
  "llama-server answers with a top-level content field"
  (lambda ()
    (check-equal! (do--parse-reply (list 'ok #t 'status 200 'body "{\"content\":\"undo\"}"))
                  (list 'ok "undo") "the content field is the name")))

(deftest 'do-llama-prompt-carries-the-catalog-and-the-phrase
  "the raw prompt holds the catalog, the phrase, and the opened answer"
  (lambda ()
    (let ((p (do--llama-prompt "close it")))
      (check-true! (string-contains? p "\nkill-buffer: Kill a buffer") "the catalog is in the system turn")
      (check-true! (string-contains? p "<|im_start|>user\nclose it<|im_end|>") "the phrase is the user turn")
      (check-true! (string-suffix? "{\"command\": \"" p) "the assistant turn is opened"))))

(deftest 'do-asks-before-a-destroying-command
  "only a command whose effects include a confirm effect needs confirmation"
  (lambda ()
    (check-true! (do--needs-confirm? "zz-do-test-destroyer") "destroy asks")
    (check-false! (do--needs-confirm? "undo") "undo runs at once")))

(deftest 'do-row-is-a-labelled-candidate
  "a proposal row carries the command as its label, so RET runs it"
  (lambda ()
    (let ((row (do--row "undo" 'model)))
      (check-equal! (car row) "undo" "the label is the command")
      (check-equal! (length row) 3 "label, hint, kind"))))
