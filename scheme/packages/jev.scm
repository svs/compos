;;; jev.scm --- TypeSafe JEV (System One) client for compos.
;;;
;;; JEV is TypeSafe's System One model: send state and typed questions,
;;; get structured answers with probabilities that code can use directly.
;;; Docs: https://docs.typesafe.ai — endpoint POST /v1/systemone.
;;;
;;; Key resolution, first hit wins:
;;;   1. the setting typesafe-api-key, which setup saves (decide.scm declares it),
;;;      else $TYPESAFE_API_KEY   (what the TypeSafe SDKs read)
;;;   2. $JEV_API_KEY
;;;   3. Doppler secret JEV_API_KEY in jev-doppler-project / jev-doppler-config,
;;;      when both are set
;;;
;;;   (jev-systemone STATE QUESTIONS [MODEL])  -> parsed reply plist, or #f
;;;   (jev-noul INSTRUCTIONS [CRITERIA])       -> a yes/no question
;;;   (jev-choice INSTRUCTIONS CRITERIA)       -> a pick-one question
;;;   (jev-score INSTRUCTIONS CRITERIA)        -> a rated question

(category! 'jev)

(defgroup 'jev "JEV: TypeSafe System One judgments from the editor.")

(defcustom 'jev-api-url "https://api.typesafe.ai/v1/systemone"
  "The TypeSafe System One evaluation endpoint." 'group 'jev)

(defcustom 'jev-model "jev-latest"
  "The JEV model to evaluate with." 'group 'jev)

(defcustom 'jev-doppler-project ""
  "Doppler project holding JEV_API_KEY, used when no env key is set."
  'group 'jev)

(defcustom 'jev-doppler-config ""
  "Doppler config under jev-doppler-project holding JEV_API_KEY."
  'group 'jev)

;;; --- questions ------------------------------------------------------------

(effects! '(pure))

(define (jev-noul instructions &optional criteria)
  (if criteria
      (list 'type "noul" 'instructions instructions 'criteria criteria)
      (list 'type "noul" 'instructions instructions)))

(define (jev-choice instructions criteria)
  (list 'type "choice" 'instructions instructions 'criteria criteria))

(define (jev-score instructions criteria)
  (list 'type "score" 'instructions instructions 'criteria criteria))

;;; --- the call -------------------------------------------------------------

(effects! '(read external execute))

(define (jev-api-key)
  ;; the key setup saves, else TYPESAFE_API_KEY from the environment
  (or (and (boundp 'typesafe-api-key) (secret-value 'typesafe-api-key))
      (getenv "TYPESAFE_API_KEY")
      (getenv "JEV_API_KEY")
      (and (not (equal? jev-doppler-project "")) (not (equal? jev-doppler-config ""))
           (doppler-secret-get jev-doppler-project jev-doppler-config "JEV_API_KEY"))
      #f))

(define (jev-systemone state questions &optional model)
  (let ((key (jev-api-key)))
    (and key
         (let ((reply (http-post jev-api-url
                                 (list 'state state
                                       'model (or model jev-model)
                                       'questions questions)
                                 (list 'headers
                                       (list 'authorization
                                             (string-append "Bearer " key))))))
           (and (http-ok? reply) (http-json reply))))))

;; The async door. http-post with a callback runs off the lane, so a caller in
;; a command never freezes the editor while JEV thinks. K gets the parsed reply
;; plist, or #f when there is no key and when the call fails.
(define (jev-ask state questions k &optional model)
  (let ((key (jev-api-key)))
    (if (not key)
        (k #f)
        (http-post jev-api-url
                   (list 'state state
                         'model (or model jev-model)
                         'questions questions)
                   (list 'headers
                         (list 'authorization (string-append "Bearer " key)))
                   (lambda (reply)
                     (k (and (http-ok? reply) (http-json reply))))))))

;; The answer to one question by its key, or #f. A reply that came back empty,
;; or came back without this question, answers #f rather than throwing.
(define (jev-answer reply question)
  (let ((answers (and reply (plist-get reply 'answers))))
    (and answers (plist-get answers question))))

;; The chosen option of a 'choice' answer, as a string, or #f.
(define (jev-answer-choice reply question)
  (let ((ans (jev-answer reply question)))
    (and ans (plist-get ans 'choice))))

;; A 'noul' answer is a probability and not a yes or a no, so the caller owns
;; the threshold. Answers the number, or #f.
(define (jev-answer-noul reply question)
  (let ((ans (jev-answer reply question)))
    (and ans (plist-get ans 'noul))))

;;; --- a quick round-trip ---------------------------------------------------

(define-command "jev" "Ask JEV the quickstart question and echo the answers"
  (lambda ()
    (let ((reply (jev-systemone
                   "Hi, I have been trying to connect my Stripe account for 3 days and it keeps failing. Im losing sales."
                   (list 'urgency (jev-noul "Does this message express urgency?")
                         'department (jev-choice "Which team should handle this?"
                                       '(billing "Payment or subscription issues"
                                         technical "Bugs or integration problems"
                                         sales "Pricing or account questions"))))))
      (if reply
          (message (format "~a" reply))
          (message "jev: no answer (is the key set?)")))))

;;; --- public surface -------------------------------------------------------

(effects! '(pure))
(public! 'jev-noul "(jev-noul INSTRUCTIONS [CRITERIA]) — a yes/no JEV question")
(public! 'jev-choice "(jev-choice INSTRUCTIONS CRITERIA) — a pick-one JEV question; criteria is a plist of option -> description")
(public! 'jev-score "(jev-score INSTRUCTIONS CRITERIA) — a rated JEV question; criteria is a list of level descriptions")

(effects! '(read external execute))
(public! 'jev-api-key "(jev-api-key) — the JEV API key: the typesafe-api-key setting or $TYPESAFE_API_KEY, then $JEV_API_KEY, then Doppler")
(public! 'jev-systemone "(jev-systemone STATE QUESTIONS [MODEL]) — evaluate STATE against QUESTIONS and return the parsed reply plist, or #f")
(public! 'jev "M-x jev — ask JEV the quickstart question and echo the answers")(public! 'jev-ask "(jev-ask STATE QUESTIONS K [MODEL]) — evaluate asynchronously; K gets the parsed reply plist, or #f")

(effects! '(pure))
(public! 'jev-answer "(jev-answer REPLY QUESTION) — the answer plist for one question key, or #f")
(public! 'jev-answer-choice "(jev-answer-choice REPLY QUESTION) — the chosen option of a choice answer, as a string, or #f")
(public! 'jev-answer-noul "(jev-answer-noul REPLY QUESTION) — the probability of a yes/no answer, or #f")


;;; --- jev-apropos: find the command with JEV --------------------------------

;; apropos does the wide pass: its literal search lands on the right namespace
;; (kill ... buffer -> kill-buffer, split ... window -> split-window-right) and
;; hands back a short candidate list in milliseconds. JEV then does the one
;; thing it is fast at — a small decision space — picking among those few, and
;; it is free to disagree with apropos's first candidate or reject them all
;; when no command fits (prose, not an action).

(defcustom 'jev-apropos-candidates 12
  "How many apropos hits to hand JEV to choose among."
  'group 'jev)

(defcustom 'jev-apropos-gate-threshold 0.30
  "Below this mean gate score jev-apropos answers #f: no command fits."
  'group 'jev)

(effects! '(pure))

(define (jev-apropos--truncate s n)
  (if (> (string-length s) n)
      (string-append (substring s 0 (- n 3)) "...")
      s))

(define (jev-apropos--candidate? e)
  (and (equal? (plist-get e 'kind) "command")
       (not (string-contains? (plist-get e 'name) "--"))))

(define (jev-apropos--describe e)
  (let* ((name (plist-get e 'name))
         (doc (plist-get e 'doc)))
    (jev-apropos--truncate
     (if (and doc (not (equal? name doc)))
         (string-append name ": " doc)
         (or name doc ""))
     200)))

(define (jev-apropos--criteria cands)
  (let loop ((xs cands) (acc '()))
    (if (null? xs)
        (reverse (cons "None of these does what the request asks." (cons 'none acc)))
        (loop (cdr xs)
              (cons (jev-apropos--describe (car xs))
                    (cons (string->symbol (plist-get (car xs) 'name)) acc))))))

(define (jev-apropos--gate-questions)
  (list 'gate-acts
        (jev-noul "Is the user being asked to do something in the editor — run a command, change a setting, or act on a buffer, file, or window — rather than only to explain or describe?")
        'gate-procedure
        (jev-noul "Would a careful compos user answer this by running a specific command or following a documented procedure, rather than from general understanding?")
        'gate-prose
        (jev-noul "Could a knowledgeable person fully satisfy this request in prose, without running any editor command or changing anything?")))

(effects! '(read external execute))

(define (jev-apropos--gate reply)
  (let ((a (jev-answer-noul reply 'gate-acts))
        (p (jev-answer-noul reply 'gate-procedure))
        (s (jev-answer-noul reply 'gate-prose)))
    (and a p s (/ (+ a p (- 1 s)) 3))))

(define (jev-apropos--result e)
  (let ((kind (plist-get e 'kind))
        (name (plist-get e 'name)))
    (list 'name name
          'kind kind
          'doc (or (plist-get e 'doc) name)
          'key (and (equal? kind "command")
                    (let ((k (key-for-command name)))
                      (and (not (equal? k "")) k)))
          'use (plist-get e 'use))))

;; namespace recall: apropos's semantic search misses ("search the buffer for
;; text" gives no command), but a literal match on command-name prefixes catches
;; it (isearch-*, buffer-*). Rare words rank first, so a discriminative prefix
;; like isearch- beats the long buffer-* tail.
(define jev-apropos--stopwords
  '("the" "a" "an" "for" "of" "to" "in" "on" "my" "me" "do" "how" "what"
    "this" "that" "with" "and" "or" "it" "is" "can" "should" "would" "could"
    "will" "from" "at" "by" "up" "down" "not" "be" "are" "was" "were" "i"))

(define (jev-apropos--words query)
  (let* ((s (string-downcase query))
         (spans (re-find* "[a-zA-Z0-9]+" s)))
    (filter (lambda (w)
              (and (>= (string-length w) 2)
                   (not (member w jev-apropos--stopwords))))
            (map (lambda (span) (substring-bytes s (car span) (cadr span))) spans))))

(define (jev-apropos--matches-for word)
  (filter (lambda (e)
            (and (jev-apropos--candidate? e)
                 (string-contains? (string-downcase (plist-get e 'name)) word)))
          (catalog)))

(define (jev-apropos--name-matches query)
  (let* ((words (jev-apropos--words query))
         (by-word (map (lambda (w) (cons w (jev-apropos--matches-for w))) words))
         (ranked (sort (map (lambda (p) (list (length (cdr p)) (car p))) by-word))))
    (let loop ((ws (map cadr ranked)) (acc '()))
      (if (null? ws)
          acc
          (loop (cdr ws) (append acc (cdr (assoc (car ws) by-word))))))))

(define (jev-apropos--dedupe xs)
  (let loop ((xs xs) (seen '()) (acc '()))
    (if (null? xs)
        (reverse acc)
        (let ((n (plist-get (car xs) 'name)))
          (if (member n seen)
              (loop (cdr xs) seen acc)
              (loop (cdr xs) (cons n seen) (cons (car xs) acc)))))))

(define (jev-apropos query &optional buf)
  ;; the commands only, and only the ones for BUF (command-applicable?): a
  ;; recipe is written for agents and answers data, and a mode's command does
  ;; nothing outside its buffers. apropos runs its semantic pass, so a
  ;; sentence finds the commands that do it and not the docs that hold its
  ;; words. JEV may answer none.
  (and (jev-api-key)
       (let* ((out (commands-out-of-scope (or buf (current-buffer))))
              (mine? (lambda (e) (and (jev-apropos--candidate? e) (not (member (plist-get e 'name) out)))))
              (hits (filter mine? (apropos query 'semantic #t 'kind "command")))
              (recall (filter mine? (jev-apropos--name-matches query)))
              (cands (take-n (jev-apropos--dedupe (append hits recall)) jev-apropos-candidates))
              (by-name (map (lambda (e) (cons (plist-get e 'name) e)) cands)))
         (and (pair? cands)
              (let* ((questions (append (list 'which (jev-choice "Which of these is the right command for this request?"
                                                                  (jev-apropos--criteria cands)))
                                        (jev-apropos--gate-questions)))
                     (reply (jev-systemone query questions)))
                (and reply
                     (let ((gate (jev-apropos--gate reply))
                           (winner (jev-answer-choice reply 'which)))
                       (and (number? gate)
                            (>= gate jev-apropos-gate-threshold)
                            winner
                            (assoc winner by-name)
                            (jev-apropos--result (cdr (assoc winner by-name)))))))))))

(effects! '(read external execute display))

(define (jev-apropos--markdown query hit)
  (string-append
   "**" query "** → `" (plist-get hit 'name) "`\n\n"
   (let ((k (plist-get hit 'key)))
     (if k (string-append "- key: `" k "`\n") ""))
   (let ((u (plist-get hit 'use)))
     (if u (string-append "- run: `" u "`\n") ""))
   "\n"
   (or (plist-get hit 'doc) "")))

(define (jev-apropos-page query hit)
  (help-doc! "jev-apropos" (jev-apropos--markdown query hit)))

(define (jev-apropos--show query)
  (let ((hit (jev-apropos query)))
    (if hit
        (jev-apropos-page query hit)
        (message "jev-apropos: nothing fits."))))

(define-command "jev-apropos" "Ask JEV which editor command to run for a request"
  (lambda ()
    (read-string "What do you want to do? "
                 (lambda (query)
                   (and query (not (equal? query ""))
                        (task-run! (lambda () (jev-apropos--show query))))))))

(effects! '(read external execute))
(public! 'jev-apropos "(jev-apropos QUERY) — apropos finds candidates, JEV picks the command; answers (name doc key use) or #f")

(effects! '(read external execute display))
(public! 'jev-apropos-page "(jev-apropos-page QUERY HIT) — render a jev-apropos hit as a *Help* page")

;;; The shell gate moved to decide.scm, with every other refusal. JEV
;;; still answers it: decide asks its first live backend, and that is JEV.
