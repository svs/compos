;;; do-test.scm --- the palette's local backend: phrase in, one catalog command out.
;;;
;;; The model is a seam. These tests rebind *do--ask* and read what the
;;; pick does around it: the catalog prompt, the reply parser, and the
;;; name the palette gets.

(domain! 'testing)
(effects! '(write))

(define *do-test-asked* '())

(define (do-test-stub answer)
  (lambda (phrase k)
    (set! *do-test-asked* (cons phrase *do-test-asked*))
    (k (list 'ok answer))))

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

(deftest 'do-pick-answers-the-models-command-or-false
  "do-pick hands the palette the model's command, and #f when it has none"
  (lambda ()
    (let ((got 'unset))
      (set! *do--ask* (do-test-stub "undo"))
      (do-pick "take that back" (lambda (n) (set! got n)))
      (check-equal! got "undo" "the pick is the command")
      (set! *do--ask* (lambda (phrase k) (k (list 'error "no command for that"))))
      (do-pick "nonsense" (lambda (n) (set! got n)))
      (check-equal! got #f "an error is no pick")
      (set! *do--ask* #f))))
