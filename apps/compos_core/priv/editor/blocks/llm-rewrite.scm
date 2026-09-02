;;; llm-rewrite.scm --- region -> LLM -> a diff block that waits.
;;;
;;; gptel's other half, as an action over the diff block: the model
;;; rewrites a passage, and its version lands as a diff block below the
;;; passage (diff-block.scm owns the block: its states, its fence, its
;;; verbs). This file owns only the LLM policy — the directives, the
;;; prompt, the reply cleaning, and the review loop C-c e opens.

(define llm-rewrite-parent-package *loading-package*)
(define llm-rewrite-parent-namespace *loading-namespace*)
(define llm-rewrite-parent-domain *catalog-domain*)
(define llm-rewrite-parent-effects *catalog-effects*)

(package! 'llm-rewrite 'editor)
(domain! 'llm)
(effects! '(write external spend))

(define *llm-rewrite-prose-modes*
  '("text-mode" "markdown-mode" "morg-mode" "org-mode" "chat-mode"))

;; The instructions the prompt offers. Prose and code want opposite things
;; from a model, so the buffer's mode decides which set leads.
(define *llm-rewrite-prose-directives*
  '("Rewrite this passage to be clearer and more direct. Keep the author's voice."
    "Say this in fewer words, and lose nothing."
    "Correct the grammar and the spelling. Change nothing else."
    "Say this in plain language."))

(define *llm-rewrite-code-directives*
  '("Refactor this code. Keep its behaviour, its interface, and the file's style."
    "Name these things for what they are."
    "Handle the cases this code misses."
    "Document this: a docstring for what it is, comments only for what the code cannot say."))

(define (llm-rewrite--prose? buf)
  (let ((mode (buffer-local buf 'mode-name)))
    (or (not mode) (member mode *llm-rewrite-prose-modes*))))

(define (llm-rewrite-directives buf)
  (if (llm-rewrite--prose? buf)
      (append *llm-rewrite-prose-directives* *llm-rewrite-code-directives*)
      (append *llm-rewrite-code-directives* *llm-rewrite-prose-directives*)))

(define (llm-rewrite-prompt buf directive passage)
  (string-append
    "You rewrite one passage of a document open in a text editor"
    (let ((mode (buffer-local buf 'mode-name)))
      (if mode (string-append " (" mode ")") ""))
    ".\n\nInstruction: " directive
    "\n\nPassage:\n" passage
    "\n\nReply with ONLY the rewritten passage. No commentary, no quotes and "
    "no code fences. Keep the indentation of every line, and add no heading, "
    "preface or trailing blank line."))

(define (llm-rewrite--drop-blank-front lines)
  (if (and (pair? lines) (equal? (string-trim (car lines)) ""))
      (llm-rewrite--drop-blank-front (cdr lines))
      lines))

(define (llm-rewrite--trim-blank-edges lines)
  (reverse (llm-rewrite--drop-blank-front
             (reverse (llm-rewrite--drop-blank-front lines)))))

;; The passage it answers has no fence, so the rewrite gains none; blank
;; edges go, and the first line's own indentation stays.
(define (llm-rewrite-clean reply)
  (let* ((lines (llm-rewrite--trim-blank-edges (string-split reply "\n")))
         (fenced (and (>= (length lines) 2)
                      (string-prefix? "```" (car lines))
                      (string-prefix? "```" (car (reverse lines))))))
    (string-join
      (if fenced
          (llm-rewrite--trim-blank-edges (reverse (cdr (reverse (cdr lines)))))
          lines)
      "\n")))

;;; --- ask and land ------------------------------------------------------------

(define (llm-rewrite--ask! buf passage directive land)
  (message "LLM rewriting...")
  (llm (llm-rewrite-prompt buf directive passage)
    (lambda (reply)
      (let ((new (llm-rewrite-clean reply)))
        (cond ((not (buffer-exists? buf))
               (message "Rewrite discarded — its buffer was killed"))
              ((equal? new "") (message "The model returned nothing"))
              (else (land new)))))))

(define (llm-rewrite--propose! buf start end original new directive)
  (if (equal? (diff-block-propose! buf start end original new directive) 'ok)
      (message (string-append
                 "Rewrite waiting below the passage in "
                 (buffer-modeline-name buf)
                 " · there " (key-for-command "llm-rewrite") " decides and "
                 (key-for-command "diff-block-cycle" buf)
                 " shows the diff"))
      (message "Rewrite dropped — that passage has changed")))

(define (llm-rewrite--refine! buf new directive)
  (let ((r (diff-block-update! buf new directive)))
    (cond ((equal? r 'gone) (message "The waiting rewrite is gone"))
          ((equal? r 'edited)
           (message "The rewrite has been edited — the new version was dropped"))
          (else (message (string-append "Rewrite refined · "
                                        (key-for-command "llm-rewrite")
                                        " decides"))))))

;; An empty answer at the prompt takes the instruction the mode leads with.
(define (llm-rewrite--directive buf input)
  (let ((typed (string-trim input)))
    (if (equal? typed "") (car (llm-rewrite-directives buf)) typed)))

(define (llm-rewrite--start! buf)
  (let* ((start (and (mark) (region-beginning)))
         (end (and start (region-end)))
         (old (and start (block-text-at buf start end))))
    (if (or (not old) (equal? old ""))
        (message "No region — set the mark first (C-SPC)")
        (begin
          ;; the region is consumed: the command has it, so the selection
          ;; does not linger under the caret
          (set-mark! #f)
          (minibuffer-read "Rewrite region: " (llm-rewrite-directives buf)
            (lambda (input)
              (let ((directive (llm-rewrite--directive buf input)))
                (llm-rewrite--ask! buf old directive
                  (lambda (new)
                    (llm-rewrite--propose! buf start end old new directive))))))))))

;;; --- the review loop ---------------------------------------------------------
;; One key decides. The block's own keys live only in the buffer that
;; holds it, and a key nobody can reach from the window they are looking
;; at is no key at all — so the same C-c e that made the rewrite also
;; ends it. The verbs are exact answers, which leaves an instruction that
;; happens to start with "keep" an instruction.

(define *llm-rewrite-keep-answer* "keep it")
(define *llm-rewrite-back-answer* "put it back")

(define (llm-rewrite--review! buf p answer)
  (let ((state (diff-block-answer-state answer)))
    (cond
      ((equal? answer "") (message "Rewrite still waiting"))
      ((equal? answer *llm-rewrite-keep-answer*) (diff-block-accept! buf))
      ((equal? answer *llm-rewrite-back-answer*) (diff-block-reject! buf))
      (state (diff-block-set-state! buf state))
      (else
        (llm-rewrite--ask! buf (diff-block-theirs p) answer
          (lambda (new) (llm-rewrite--refine! buf new answer)))))))

(define (llm-rewrite--again! buf p)
  (if (not (diff-block--spans buf))
      (begin (diff-block-release! buf)
             (message "The waiting rewrite is gone"))
      (minibuffer-read
        "Rewrite waiting (keep it / put it back / show … / a new instruction): "
        (append (list *llm-rewrite-keep-answer* *llm-rewrite-back-answer*)
                (diff-block-state-answers (diff-block-state p))
                (llm-rewrite-directives buf))
        (lambda (input)
          (llm-rewrite--review! buf p (string-trim input))))))

(define-command "llm-rewrite"
  "Rewrite the region with the LLM into a diff block below it; with one waiting, decide it or ask again"
  (lambda ()
    (let* ((buf (current-buffer))
           (p (diff-block-pending buf)))
      (if p (llm-rewrite--again! buf p) (llm-rewrite--start! buf)))))

(define-key "mode-specific-map" "e" "llm-rewrite")
(catalog-meta! 'command "llm-rewrite"
  'domain "llm" 'effects '("write" "external" "spend"))

;; Do not leak this action's catalog context into the loader.
(package! llm-rewrite-parent-package llm-rewrite-parent-namespace)
(domain! llm-rewrite-parent-domain)
(effects! llm-rewrite-parent-effects)
