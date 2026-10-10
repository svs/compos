;;; decide-test.scm --- packages/decide.scm: one typed-decision API over
;;; three backends.
;;;
;;; No test here reaches a backend. What this package owns is which
;;; backend a call chooses, that the options a caller passes arrive, and
;;; that an answer reads the same whichever backend wrote it.

(domain! 'testing)
(effects! '(read))

(define t--decide-seen '())

;; a backend that answers nothing and records what it was handed
(define (t--decide-stub!)
  (set! t--decide-seen '())
  (set! decide--call-laya
    (lambda (state questions model timeout)
      (set! t--decide-seen (list 'laya state model timeout))
      '(answers () usage (0 0 laya))))
  (set! decide--call-jev
    (lambda (state questions model timeout)
      (set! t--decide-seen (list 'jev state model timeout))
      '(answers () usage (0 0 jev)))))

(deftest 'decide-the-options-a-caller-passes-arrive
  "a rest parameter this interpreter does not read is every option lost"
  (lambda ()
    (let ((held-laya decide--call-laya)
          (held-jev decide--call-jev))
      (t--decide-stub!)
      (decide "a passage" '(q (type "noul" instructions "is it?")) 'backend 'laya)
      (check-equal! (nth 0 t--decide-seen) 'laya "the backend a caller named")
      (decide "a passage" '(q (type "noul" instructions "is it?"))
              'backend 'laya 'timeout 7)
      (check-equal! (nth 3 t--decide-seen) 7 "and the timeout beside it")
      (decide "a passage" '(q (type "noul" instructions "is it?")) 'backend 'jev)
      (check-equal! (nth 0 t--decide-seen) 'jev "another backend, the same way")
      (set! decide--call-laya held-laya)
      (set! decide--call-jev held-jev))))

(deftest 'decide-a-backend-is-called-and-not-returned
  "the dispatch table answers (NAME FN), and the function is the second"
  (lambda ()
    (let ((held decide--call-laya))
      (t--decide-stub!)
      (let ((answer (decide "a passage" '(q (type "noul" instructions "is it?"))
                            'backend 'laya)))
        (check-true! (pair? answer) "a call answers a result")
        (check-equal! (nth 2 (plist-get answer 'usage)) 'laya
                      "and the usage names the backend that wrote it"))
      (set! decide--call-laya held))))

(deftest 'decide-a-laya-answer-reads-as-one-row-a-question
  "the daemon answers JSON, so an answer is a plist and not an alist"
  (lambda ()
    (let* ((result '(model "laya-rl-agent"
                     answers (department (type "choice" choice "billing"
                                          confidence 0.76
                                          action (act_probability 1.0))
                              refund (type "noul" noul 0.82 confidence 0.82))
                     usage (input_tokens 116 output_tokens 0)))
           (standard (decide--laya->standard result))
           (rows (plist-get standard 'answers)))
      (check-equal! (length rows) 2 "one row a question")
      (check-equal! (nth 0 (nth 0 rows)) 'department "the question is the key")
      (check-equal! (plist-get (nth 1 (nth 0 rows)) 'choice) "billing"
                    "and the answer is the standard shape")
      (check-equal! (plist-get (nth 1 (nth 1 rows)) 'noul) 0.82 "whatever its type")
      (check-equal! (plist-get standard 'usage) '(116 0 laya)
                    "the tokens the daemon counted, under the backend's name"))))

(deftest 'decide-a-laya-answer-that-is-not-there-is-no-answer
  "a daemon that refused must not read as a decision"
  (lambda ()
    (let ((standard (decide--laya->standard #f)))
      (check-equal! (plist-get standard 'answers) '() "no rows")
      (check-equal! (plist-get standard 'usage) '(0 0 laya) "and nothing spent"))))

(deftest 'decide-shell-gate-follows-the-policy
  "a recognised kind gets what decide-shell-policy says; a build passes, a read is refused"
  (lambda ()
    (let ((seen decide--shell-seen))
      (set! decide--shell-seen
            (list (list "zz-build" 'build) (list "zz-read" 'read) (list "zz-edit" 'edit)))
      (check-equal! (decide-shell-verdict "zz-build") #f "a build runs")
      (check-equal! (decide-shell-verdict "zz-read") (decide-refusal 'read) "a read is refused")
      (check-equal! (decide-shell-verdict "zz-edit") (decide-refusal 'edit) "an edit is refused")
      (set! decide--shell-seen seen))))

(deftest 'decide-shell-gate-asks-then-lets-the-approved-payload-through
  "an ask kind asks; unapproved it refuses, approved it runs, and only that payload"
  (lambda ()
    (let ((seen decide--shell-seen) (policy decide-shell-policy) (approved decide--shell-approved))
      (set! decide--shell-seen
            (list (list "(shell-command->string \"zz-edit\")" 'edit)
                  (list "(shell-command->string \"zz-other\")" 'edit)
                  (list "(shell-command->string \"zz-build\")" 'build)))
      (set! decide-shell-policy '((edit ask) (build allow)))
      (check-equal! (decide-shell-asks? "(shell-command->string \"zz-edit\")") #t "an edit asks")
      (check-equal! (decide-shell-asks? "(shell-command->string \"zz-build\")") #f "a build does not")
      (check-equal! (decide-shell-asks? "(+ 1 2)") #f "no shell, no ask")
      (check-equal! (decide-shell-verdict "(shell-command->string \"zz-edit\")") (decide-refusal 'edit) "unapproved, refused")
      (decide-shell-approve! "(shell-command->string \"zz-edit\")")
      (check-equal! (decide-shell-verdict "(shell-command->string \"zz-edit\")") #f "approved, runs")
      (check-equal! (decide-shell-verdict "(shell-command->string \"zz-other\")") (decide-refusal 'edit) "another payload still refused")
      (set! decide--shell-approved approved)
      (set! decide-shell-policy policy)
      (set! decide--shell-seen seen))))

(deftest 'decide-shell-gate-hook-lets-plain-scheme-through
  "a payload with no shell command never reaches a backend"
  (lambda ()
    (check-equal! (decide-shell-gate-hook "eval-scheme" '(code "(+ 1 2)")) #f "no shell, no verdict")
    (check-equal! (decide-shell-gate-hook "read-file" '(path "x")) #f "another tool is not gated here")))

(deftest 'decide-allow-git-silences-only-git
  "with decide-allow-git on, git verbs stop asking and the rest still ask"
  (lambda ()
    (let ((was decide-allow-git))
      (set! decide-allow-git #f)
      (check-equal! (and (permission-denied-verb? "git merge --ff-only main") #t) #t "git merge asks by default")
      (set! decide-allow-git #t)
      (check-equal! (permission-denied-verb? "git merge --ff-only main") #f "git merge runs when allowed")
      (check-equal! (permission-denied-verb? "git push origin main") #f "so does a push")
      (check-equal! (and (permission-denied-verb? "sendmail bob") #t) #t "mail still asks")
      (set! decide-allow-git was))))

(deftest 'decide-refusal-words
  "every refusal says what to do next"
  (lambda ()
    (check-equal! (string-contains? (decide-refusal 'denied) "ask what to do instead") #t "denied")
    (check-equal! (string-contains? (decide-refusal 'policy "rm -rf") "(rm -rf)") #t "policy names its rule")
    (check-equal! (string-contains? (decide-refusal 'read) "(grep PATTERN") #t "read names the editor call")
    (check-equal! (string-contains? (decide-refusal 'denied 'read) "(grep PATTERN") #t "a denied read names the editor call")
    (check-equal! (string-contains? (decide-refusal 'denied 'read) "ask what to do instead") #f "a denied read does not stop to ask")
    (check-equal! (string-contains? (decide-refusal 'denied 'edit) "(buffer-replace! BUF") #t "a denied edit names the editor call")
    (check-equal! (decide-refusal 'denied 'other) (decide-refusal 'denied) "any other denial still asks")))

;; The boot manifest lost decide.scm once, and the permission policy then
;; denied every agent action on an unbound name.
(deftest 'the-shell-gate-is-loaded-at-boot
  "the permission gate's shell check is defined and answers"
  (lambda ()
    (check-true! (decide-shell-calls? "(shell-command->string \"ls\")") "a shell call")
    (check-false! (decide-shell-calls? "(+ 1 2)") "plain arithmetic")))
