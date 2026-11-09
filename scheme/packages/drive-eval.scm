;;; drive-eval.scm --- replay real chat tasks and score models on rounds, time and success.
;;;
;;; (drive-eval) gives each case to a fresh chat, once a model, up to
;;; drive-eval-parallel runs at once, and waits for each turn end. A case is a task a user
;;; really asked: its source is the prompt from the chat log, its start
;;; state is a fixture (a scratch buffer, a file in /tmp, a test group) or
;;; none, and its check reads the end state and the reply. A row says
;;; success, rounds (the model replies of the turn), tool calls, wall ms
;;; from the send to the turn end, and the chat-perf steps of the turn.
;;; The table goes to *drive-eval*, the rows to *drive-eval-rows*, and the
;;; event drive-eval done carries the first line. (drive-eval-mine) lists
;;; more candidate tasks from the chat logs.
;;;
;;; *drive-eval-cases* are one-step tasks. *drive-eval-hard-cases* are
;;; harness tasks of several steps, each with a check a skipped step fails:
;;; (drive-eval '(haiku opus) 'hard 3).

(domain! 'chat)
(effects! '(read))

(define *drive-eval-models*
  '((haiku "claude-code" "haiku")
    (sonnet "claude-code" "sonnet")
    (opus "claude-code" "opus")
    ;; a fourth item names the preset the chat starts on
    (haiku-driver "claude-code" "haiku" "Driver")
    ;; a fifth item adds execute* options: the Driver without recall.scm
    (haiku-driver-cold "claude-code" "haiku" "Driver" (recall #f))
    (haiku-driver-recall "claude-code" "haiku" "Driver" (recall #t))
    ;; the palette's lane: Driver's tools and cuts on the direct API
    (haiku-api "api" "claude-haiku-5-5" "Driver API" (recall #f))
    (haiku-api-recall "api" "claude-haiku-5-5" "Driver API" (recall #t))
    (deepseek-driver "opencode-go" "opencode-go/deepseek-v4.1-flash" "Driver")))

(define drive-eval-timeout-s 300)

(defcustom 'drive-eval-parallel 4
  "How many drive-eval runs go at once. Runs on an OpenCode connector still go one at a time."
  'group 'chat 'type 'number)

(defcustom 'drive-eval-prompts 'original
  "Which prompts drive-eval gives each case: original, the prompt as written; reworded, the two held-out rewordings; all, the three."
  'group 'chat 'type 'symbol)

;; the two models the gap lines of the report compare, the driver first
(define drive-eval-gap-pair '(haiku-driver opus))


(define *drive-eval-rows* '())

(define (drive-eval--has? text part)
  (and (string? text) (string? part) (string-contains? text part)))

(define (drive-eval--package-of name)
  (let ((hit (filter (lambda (r) (equal? (plist-get r 'name) name)) (apropos name))))
    (and (pair? hit) (plist-get (car hit) 'package))))

;; the first whole number in TEXT, or #f
(define (drive-eval--number text)
  (let ((m (and (string? text) (re-match "[0-9]+" text))))
    (and (pair? m) (string->number (car m)))))

;; the names a fixture's side state takes from its buffer: "*drive-eval:move:haiku*"
;; gives the tag move-haiku, the file /tmp/drive-eval-move-haiku.txt and the
;; group drive-eval-move-haiku
(define (drive-eval--tag fb)
  (string-join (string-split (substring fb 12 (- (string-length fb) 1)) ":") "-"))
(define (drive-eval--file fb) (string-append "/tmp/drive-eval-" (drive-eval--tag fb) ".txt"))
(define (drive-eval--group fb) (string-append "drive-eval-" (drive-eval--tag fb)))

;; (NAME SOURCE FIXTURE PROMPT CHECK [HOOKS]): PROMPT takes the fixture
;; buffer name; CHECK takes the fixture text at the end, or #f, the reply
;; and the fixture buffer name; HOOKS is a plist of 'setup and 'cleanup,
;; each called with the fixture buffer name.
(define *drive-eval-cases*
  (list
    (list 'setting "what is this 6kb limit we keep hitting on evals?" #f
          (lambda (b) "What is the current value of the setting tool-result-max-bytes? Answer with the number only.")
          (lambda (text reply . _) (drive-eval--has? reply (number->string tool-result-max-bytes))))
    (list 'package "what does app-dismiss do?" #f
          (lambda (b) "Which package defines the function app-dismiss? Answer with the package name only.")
          (lambda (text reply . _) (drive-eval--has? reply (drive-eval--package-of "app-dismiss"))))
    (list 'count "how many windows in this group?" "alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta"
          (lambda (b) (string-append "How many lines does the buffer " b " hold? Answer with the number only."))
          (lambda (text reply . _) (drive-eval--has? reply "7")))
    (list 'quote "bring the quote back from the buffer" "Notes from the call.\nQuote: ship small, ship often\nNext steps: none.\n"
          (lambda (b) (string-append "The buffer " b " holds one line that starts with Quote:. Reply with the words after Quote: only."))
          (lambda (text reply . _) (drive-eval--has? reply "ship small, ship often")))
    (list 'logo "we need to update the logo in the README." "# compos\n\n![logo](images/old-logo.png)\n\nAn editor on the BEAM.\n"
          (lambda (b) (string-append "In the buffer " b ", change the logo image to images/compos-logo.png. Edit the buffer only; it is not a file."))
          (lambda (text reply . _) (equal? text "# compos\n\n![logo](images/compos-logo.png)\n\nAn editor on the BEAM.\n")))
    (list 'check "see these cardboard todos check which are done" "- [ ] write the copy\n- [ ] ship the build\n- [ ] tell the team\n"
          (lambda (b) (string-append "In the buffer " b ", the item ship the build is done. Change its [ ] to [x] and change nothing else."))
          (lambda (text reply . _) (equal? text "- [ ] write the copy\n- [x] ship the build\n- [ ] tell the team\n")))))

;; Held-out prompts: two rewordings of each case, the same task and the same
;; check, so a recipe learned from one wording cannot just match the words.
;; (NAME PROMPT1 PROMPT2), each PROMPT taking the fixture buffer name.
(define *drive-eval-rewordings*
  (list
    (list 'setting
          (lambda (b) "Tell me the number the setting tool-result-max-bytes holds now. Reply with the number and nothing else.")
          (lambda (b) "I need the value of tool-result-max-bytes. Give only the number."))
    (list 'package
          (lambda (b) "Some package defines app-dismiss. Name that package and nothing more.")
          (lambda (b) "Find the package where the function app-dismiss is defined. Reply with its name only."))
    (list 'count
          (lambda (b) (string-append "Count the lines in the buffer " b ". Reply with the count only."))
          (lambda (b) (string-append "What is the line count of buffer " b "? Just the number.")))
    (list 'quote
          (lambda (b) (string-append "Find the line of the buffer " b " that begins with Quote: and give me the text after Quote:, nothing more."))
          (lambda (b) (string-append "What does the Quote: line in " b " say? Reply with only the words that follow Quote:.")))
    (list 'logo
          (lambda (b) (string-append "The buffer " b " shows images/old-logo.png as its logo. Point it at images/compos-logo.png instead. The buffer has no file; change the buffer only."))
          (lambda (b) (string-append "Swap the logo path in " b " for images/compos-logo.png. Do not save anything; " b " is not a file.")))
    (list 'check
          (lambda (b) (string-append "Mark ship the build as done in the buffer " b ": its [ ] becomes [x]. Leave every other line as it is."))
          (lambda (b) (string-append "Tick off the item ship the build in " b " by changing its box to [x]. Touch no other line.")))
    (list 'lines
          (lambda (b) (string-append "Count the lines of text in the buffer " b " and reply with that number only."))
          (lambda (b) (string-append "How many lines long is " b "? Only the number, please.")))
    (list 'line-of
          (lambda (b) (string-append "In the buffer " b ", on which line is the word needle? The first line is line 1. Reply with the line number only."))
          (lambda (b) (string-append "Find needle in " b " and tell me its line number, counting from 1. Only the number.")))
    (list 'save
          (lambda (b) (string-append "The file " (drive-eval--file b) " has the line version = 1. Make it version = 2, save the file, then check that the file on disk shows version = 2."))
          (lambda (b) (string-append "Bump version = 1 to version = 2 in " (drive-eval--file b) ", write it to disk, and verify the saved file.")))
    (list 'local
          (lambda (b) (string-append "Give the buffer " b " its own fill-column of 72 and check that it took. Only that buffer: no global change and no saved setting."))
          (lambda (b) (string-append "Set fill-column to 72 locally in " b " and read it back. Leave the global value and the saved settings alone.")))
    (list 'move
          (lambda (b) (string-append "Put the buffer " b " in the group " (drive-eval--group b) " and check that this is now its only group."))
          (lambda (b) (string-append "Take " b " out of its group and into " (drive-eval--group b) ", then verify it belongs to that group alone.")))
    (list 'prune
          (lambda (b) (string-append "Remove every line that begins with # from the buffer " b ", then reply with how many lines remain. The number only."))
          (lambda (b) (string-append "Strip the # comment lines out of " b " and tell me how many lines are left. Just the number.")))))

;; the case a variant came from: lines.r2 gives lines
(define (drive-eval--base name)
  (let ((s (symbol->string name)))
    (string->symbol (car (string-split s ".")))))

;; CASE as the prompts drive-eval-prompts picks: the original keeps its name,
;; rewording N is the same case named NAME.rN with that prompt
(define (drive-eval--variants c which)
  (let* ((rw (assq (car c) *drive-eval-rewordings*))
         (re (if rw
                 (map (lambda (p i)
                        (append (list (string->symbol (string-append (symbol->string (car c)) ".r" (number->string i)))
                                      (cadr c) (caddr c) p)
                                (list-tail c 4)))
                      (cdr rw) '(1 2))
                 '())))
    (cond ((eq? which 'reworded) re)
          ((eq? which 'all) (cons c re))
          (else (list c)))))

(define drive-eval--needle-text
  (string-join
    (let loop ((i 1) (acc '()))
      (if (> i 40)
          (reverse acc)
          (loop (+ i 1) (cons (string-append "item " (number->string i) (if (= i 27) " needle" "")) acc))))
    "\n"))

;; Harness cases: several steps each, and a check that a skipped step
;; fails. Sources are the task kinds users ask (the chat logs hold too few
;; haiku failures to mine).
(define *drive-eval-hard-cases*
  (list
    ;; 6 rounds for haiku on 2026-11-09; the trailing newline makes a
    ;; split on newlines count 8
    (list 'lines "how many lines in BUF" "alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\n"
          (lambda (b) (string-append "How many lines does the buffer " b " hold? Answer with the number only."))
          (lambda (text reply . _) (equal? (drive-eval--number reply) 7)))
    ;; the obvious search answers a byte offset or a 0-based index
    (list 'line-of "which line has it" drive-eval--needle-text
          (lambda (b) (string-append "Which line number of the buffer " b " holds the word needle? Lines count from 1. Answer with the number only."))
          (lambda (text reply . _) (equal? (drive-eval--number reply) 27)))
    ;; edit, save, and confirm on disk: a skipped save fails
    (list 'save "edit this line, save it and confirm" #f
          (lambda (b) (string-append "Open the file " (drive-eval--file b)
                                     ", change the line version = 1 to version = 2, save the file, and confirm that the file on disk says version = 2."))
          (lambda (text reply b) (equal? (read-file (drive-eval--file b)) "name = demo\nversion = 2\nmode = fast\n"))
          (list 'setup (lambda (b) (write-file! (drive-eval--file b) "name = demo\nversion = 1\nmode = fast\n"))
                'cleanup (lambda (b)
                           (let ((p (drive-eval--file b)))
                             (when (buffer-known? p) (buffer-kill! p))
                             (delete-file! p)))))
    ;; set a setting on one buffer, not globally and not in custom.scm
    (list 'local "set a setting and read it back" "some text\n"
          (lambda (b) (string-append "In the buffer " b ", set the buffer-local variable fill-column to 72, then read it back to confirm. Do not change it anywhere else and do not save a setting."))
          (lambda (text reply b) (equal? (buffer-local-value 'fill-column b) 72)))
    ;; move a buffer to another group and confirm the membership
    (list 'move "move this to another group" "notes for the move\n"
          (lambda (b) (string-append "Move the buffer " b " into the group named " (drive-eval--group b)
                                     ", then confirm that it is a member of that group and of no other."))
          (lambda (text reply b) (equal? (buffer-group b) (group-resolve-id (drive-eval--group b))))
          (list 'setup (lambda (b) (group-record-create! (drive-eval--group b)))
                'cleanup (lambda (b) (when (group-resolve-id (drive-eval--group b))
                                       (group-kill! (drive-eval--group b))))))
    ;; an edit and a count of its result: both must be right
    (list 'prune "drop the comment lines and count the rest" "# head\nalpha\n# note\nbeta\ngamma\n# end\ndelta\n"
          (lambda (b) (string-append "In the buffer " b ", delete every line that starts with #, then tell me how many lines are left. Answer with the number only."))
          (lambda (text reply . _) (and (equal? text "alpha\nbeta\ngamma\ndelta\n")
                                        (equal? (drive-eval--number reply) 4))))))

;; a fixture as lines: each line ends in a newline
(define (drive-eval--lines . xs) (apply string-append (map (lambda (x) (string-append x "\n")) xs)))
(define (drive-eval--path fb suffix) (string-append "/tmp/drive-eval-" (drive-eval--tag fb) suffix))
;; a fixture directory and all it holds: delete-file! takes only an empty one
(define (drive-eval--rmdir d)
  (when (file-directory? d)
    (for-each (lambda (f) (let ((x (string-append d "/" f)))
                            (if (file-directory? x) (drive-eval--rmdir x) (delete-file! x))))
              (filter (lambda (f) (not (member f '("." "..")))) (directory-files d)))
    (delete-file! d)))

;; Held-out harness tasks from real user chats: SOURCE is the user's own first
;; prompt, word for word. recall never learns from a chat that opens with one
;; of them, and none of them is one of the 12 cases or their rewordings.
(define *drive-eval-unseen-cases*
  (list
    (list 'unwrap "dear lord please get rid of the linebreaks in the document"
          (drive-eval--lines "The editor runs on the BEAM." "It is scripted in Scheme," "and every command is a function.")
          (lambda (b) (string-append "The buffer " b " holds one paragraph broken over three lines. Join them into one line, with one space where each line break was. Keep the final newline."))
          (lambda (text reply . _) (equal? text (drive-eval--lines "The editor runs on the BEAM. It is scripted in Scheme, and every command is a function."))))
    (list 'headings "rewrite those points as narrowable morg headings"
          (drive-eval--lines "- research the visa" "- book the hotel" "- pack the bags")
          (lambda (b) (string-append "In the buffer " b ", turn each bullet line that starts with a dash and a space into a heading that starts with a star and a space. Change nothing else."))
          (lambda (text reply . _) (equal? text (drive-eval--lines "* research the visa" "* book the hotel" "* pack the bags"))))
    (list 'apartment "hello pls add 601 as the apartment number"
          (drive-eval--lines "Name: Siddharth" "Apartment:" "Building: Marina Tower" "City: Dubai")
          (lambda (b) (string-append "The buffer " b " is a form. Fill in 601 as the apartment number, so that its line reads Apartment: 601. Change no other line."))
          (lambda (text reply . _) (equal? text (drive-eval--lines "Name: Siddharth" "Apartment: 601" "Building: Marina Tower" "City: Dubai"))))
    ;; the second compos.el must stay
    (list 'title "change the title to compos, not compos.el"
          (drive-eval--lines "# compos.el" "" "An editor on the BEAM. See compos.el/docs for more.")
          (lambda (b) (string-append "In the buffer " b ", change the title on the first line to compos instead of compos.el. Change no other line."))
          (lambda (text reply . _) (equal? text (drive-eval--lines "# compos" "" "An editor on the BEAM. See compos.el/docs for more."))))
    (list 'today "how many emails did i get today?"
          (drive-eval--lines "2026-11-09 10:02  Plane  Your weekly digest" "2026-11-08 18:40  Uber  Your trip receipt"
                             "2026-11-09 08:15  Priya  Re: interview" "2026-11-07 09:00  GitHub  New PR"
                             "2026-11-09 12:30  DMARC  Report for wrok.ae" "2026-11-08 07:10  Substack  New post")
          (lambda (b) (string-append "The buffer " b " lists mails, one per line, each starting with its date. How many mails came on 2026-11-09? Answer with the number only."))
          (lambda (text reply . _) (equal? (drive-eval--number reply) 3)))
    (list 'dmarc "mark all the dmarc mails for deletion"
          (drive-eval--lines "inbox  Plane  Your weekly digest" "inbox  google.com  DMARC aggregate report" "inbox  Priya  Re: interview"
                             "inbox  yahoo.com  DMARC aggregate report" "inbox  Uber  Your trip receipt")
          (lambda (b) (string-append "The buffer " b " lists mails, one per line, the tag first. Mark every DMARC mail for deletion: change its tag from inbox to delete. Leave the other lines as they are."))
          (lambda (text reply . _) (equal? text (drive-eval--lines "inbox  Plane  Your weekly digest" "delete  google.com  DMARC aggregate report" "inbox  Priya  Re: interview"
                                                                  "delete  yahoo.com  DMARC aggregate report" "inbox  Uber  Your trip receipt"))))
    (list 'sender "can you find out who are the biggest senders clogging my inbox pls?"
          (drive-eval--lines "From: news@substack.com" "From: priya@thine.ai" "From: deals@artstation.com" "From: news@substack.com"
                             "From: deals@artstation.com" "From: news@substack.com" "From: alerts@github.com")
          (lambda (b) (string-append "The buffer " b " has one From: line per mail. Which sender sent the most mails? Answer with the address only."))
          (lambda (text reply . _) (and (drive-eval--has? reply "news@substack.com") (not (drive-eval--has? reply "artstation")))))
    ;; a line of spaces is blank, and so is the last empty line
    (list 'loc "how many loc in elixir?"
          (drive-eval--lines "defmodule Demo do" "  " "  def a, do: 1" "" "  def b, do: 2" "end" "")
          (lambda (b) (string-append "How many non-blank lines does the buffer " b " hold? A line of only spaces is blank. Answer with the number only."))
          (lambda (text reply . _) (equal? (drive-eval--number reply) 4)))
    (list 'csv "make a smaple csv that will serve as an example. you can make it reasonable complex."
          (drive-eval--lines "| city | rain |" "|------|------|" "| Mumbai | 2400 |" "| Pune | 700 |")
          (lambda (b) (string-append "The buffer " b " holds a markdown table. Replace it with the same table as CSV: the header line city,rain, then one line per row, no spaces around the commas and no separator line."))
          (lambda (text reply . _) (equal? (string-trim (or text "")) (string-trim (drive-eval--lines "city,rain" "Mumbai,2400" "Pune,700")))))
    (list 'rainfall "make a table with average rainfall in mumbai per month"
          (drive-eval--lines "month,mm" "Jan,1" "Feb,0" "Mar,1" "Apr,2" "May,11" "Jun,505" "Jul,840" "Aug,585" "Sep,340" "Oct,64" "Nov,13" "Dec,3")
          (lambda (b) (string-append "The buffer " b " holds Mumbai rainfall per month as CSV. Which month has the most rain? Answer with the month as the buffer writes it."))
          (lambda (text reply . _) (and (drive-eval--has? reply "Jul") (not (drive-eval--has? reply "Jun")) (not (drive-eval--has? reply "Aug")))))
    (list 'uber "uber should be marked as expenses now and in future."
          (drive-eval--lines "2026-11-01  Uber  23.50  ?" "2026-11-02  Spotify  11.99  personal" "2026-11-03  Uber  41.00  ?" "2026-11-04  Careem  18.00  ?")
          (lambda (b) (string-append "The buffer " b " is a ledger: date, payee, amount, category. Set the category of every Uber line to expenses. Change no other line."))
          (lambda (text reply . _) (equal? text (drive-eval--lines "2026-11-01  Uber  23.50  expenses" "2026-11-02  Spotify  11.99  personal" "2026-11-03  Uber  41.00  expenses" "2026-11-04  Careem  18.00  ?"))))
    (list 'due "how much to pay CNS?"
          (drive-eval--lines "CNS Facility Services" "Invoice 2026-114" "" "Cleaning, October   AED 3,800" "Repairs             AED 450"
                             "Paid on account     AED -1,000" "" "Total due: AED 3,250")
          (lambda (b) (string-append "The buffer " b " is an invoice. How much is due? Answer with the amount as the invoice writes it."))
          (lambda (text reply . _) (or (drive-eval--has? reply "3,250") (drive-eval--has? reply "3250"))))
    ;; a second Yash is the trap
    (list 'met "when did we meet yashowardhan?"
          (drive-eval--lines "2026-10-03  call with Priya Raman" "2026-10-15  coffee with Yashowardhan Shinde" "2026-10-21  call with Yash Gupta" "2026-11-02  lunch with Kaustubh")
          (lambda (b) (string-append "The buffer " b " is a meeting log. On which date did we meet Yashowardhan? Answer with the date only."))
          (lambda (text reply . _) (and (drive-eval--has? reply "2026-10-15") (not (drive-eval--has? reply "2026-10-21")))))
    (list 'latest "who did we recently apply to saral?"
          (drive-eval--lines "2026-10-30  Saral  Ananya Rao" "2026-11-05  Thine  Megh Patel" "2026-11-06  Saral  Rohit Singh" "2026-10-12  Saral  Darshan Baid")
          (lambda (b) (string-append "The buffer " b " logs who we put forward to which client, one per line, the date first. Who did we put forward to Saral most recently? Answer with the name only."))
          (lambda (text reply . _) (and (drive-eval--has? reply "Rohit Singh") (not (drive-eval--has? reply "Megh")))))
    (list 'rename "rename ats-ash mcp to ats-dev if it's on localhost."
          (drive-eval--lines "(mcp-server 'ats-ash \"http://localhost:4001/mcp\")" "(mcp-server 'fireflies \"https://api.fireflies.ai/mcp\")" ";; ats-ash tools: ats-ash/search, ats-ash/approve")
          (lambda (b) (string-append "In the buffer " b ", rename ats-ash to ats-dev everywhere it appears. Change nothing else."))
          (lambda (text reply . _) (equal? text (drive-eval--lines "(mcp-server 'ats-dev \"http://localhost:4001/mcp\")" "(mcp-server 'fireflies \"https://api.fireflies.ai/mcp\")" ";; ats-dev tools: ats-dev/search, ats-dev/approve"))))
    (list 'sort "we should have sort by mode here so same mode windows get grouped. secondary sort by name always"
          (drive-eval--lines "chat-mode  zeta" "morg-mode  notes" "chat-mode  alpha" "dired-mode  src" "morg-mode  journal")
          (lambda (b) (string-append "Each line of the buffer " b " is a mode and a name. Sort the lines by mode, and by name within one mode. Keep each line as it is."))
          (lambda (text reply . _) (equal? text (drive-eval--lines "chat-mode  alpha" "chat-mode  zeta" "dired-mode  src" "morg-mode  journal" "morg-mode  notes"))))
    (list 'drop-line "remove the ring from columns layout."
          (drive-eval--lines "layout: columns" "- column left" "- ring" "- column middle" "- column right")
          (lambda (b) (string-append "The buffer " b " lists the parts of the columns layout. Remove the ring from it: delete that whole line. Keep every other line."))
          (lambda (text reply . _) (equal? text (drive-eval--lines "layout: columns" "- column left" "- column middle" "- column right"))))
    (list 'visa "make a tab for visa info"
          (drive-eval--lines "# Trip to Japan" "" "## Flights" "EK 318, 12 Dec" "" "## Hotels" "Park Hyatt, 3 nights")
          (lambda (b) (string-append "In the buffer " b ", add a section at the end: the heading ## Visa, and under it the line Apply by 20 Nov. Keep everything above as it is."))
          (lambda (text reply . _)
            (let ((old (drive-eval--lines "# Trip to Japan" "" "## Flights" "EK 318, 12 Dec" "" "## Hotels" "Park Hyatt, 3 nights")))
              (and (string? text) (string-prefix? old text)
                   (string-suffix? (string-trim (drive-eval--lines "## Visa" "Apply by 20 Nov")) (string-trim text))))))
    (list 'weather "we want weeather also on the itinerary."
          (drive-eval--lines "## Day 1" "Arrive Tokyo" "" "## Day 2" "Kyoto by train" "" "## Day 3" "Fly home")
          (lambda (b) (string-append "In the itinerary buffer " b ", add the line Weather: TBD right after each ## Day heading. Change nothing else."))
          (lambda (text reply . _) (equal? text (drive-eval--lines "## Day 1" "Weather: TBD" "Arrive Tokyo" "" "## Day 2" "Weather: TBD" "Kyoto by train" ""
                                                                  "## Day 3" "Weather: TBD" "Fly home"))))
    ;; a file by what it holds, not by its name
    (list 'statement "is there a mashreq bank statement recently in ~/Downloads? it'll be a pdf or spreadsheet" #f
          (lambda (b) (string-append "Which file in the directory " (drive-eval--path b "-dl") " is a bank statement from Mashreq? Answer with the file name only."))
          (lambda (text reply . _) (and (drive-eval--has? reply "doc-2") (not (drive-eval--has? reply "doc-3"))))
          (list 'setup (lambda (b)
                         (let ((d (drive-eval--path b "-dl")))
                           (drive-eval--rmdir d)
                           (make-directory! d)
                           (write-file! (string-append d "/doc-1.txt") (drive-eval--lines "Uber" "Trip receipt, 2 Nov 2026" "Total AED 41.00"))
                           (write-file! (string-append d "/doc-2.txt") (drive-eval--lines "Mashreq Bank" "Statement of account, October 2026" "Closing balance AED 12,400"))
                           (write-file! (string-append d "/doc-3.txt") (drive-eval--lines "Emirates NBD" "A new credit card offer for you"))))
                'cleanup (lambda (b) (drive-eval--rmdir (drive-eval--path b "-dl")))))
    ;; a new file: a skipped save fails
    (list 'journal "new-journal should add the date and time for disambiguation. we don't save it in the frontmatter do we?" #f
          (lambda (b) (string-append "Create the file " (drive-eval--path b "-journal.md") " with two lines, # Journal 2026-11-09 and then Started the day. Save it to disk and confirm that the file is there."))
          (lambda (text reply b)
            (let ((p (drive-eval--path b "-journal.md")))
              (and (file-exists? p)
                   (equal? (string-trim (read-file p)) (string-trim (drive-eval--lines "# Journal 2026-11-09" "Started the day."))))))
          (list 'setup (lambda (b) (let ((p (drive-eval--path b "-journal.md"))) (when (file-exists? p) (delete-file! p))))
                'cleanup (lambda (b)
                           (let ((p (drive-eval--path b "-journal.md")))
                             (when (buffer-known? p) (buffer-kill! p))
                             (when (file-exists? p) (delete-file! p))))))
    (list 'mkdir "dired cant create directories?" #f
          (lambda (b) (string-append "Create the directory " (drive-eval--path b "-mk") "/notes/2026, with any parent directory it needs, and confirm that it exists."))
          (lambda (text reply b) (file-directory? (string-append (drive-eval--path b "-mk") "/notes/2026")))
          (list 'setup (lambda (b) (drive-eval--rmdir (drive-eval--path b "-mk")))
                'cleanup (lambda (b) (drive-eval--rmdir (drive-eval--path b "-mk")))))))

(define (drive-eval--tool-uses m)
  (length (filter (lambda (b) (and (pair? b) (equal? (car b) "tool-use")))
                  (or (plist-get m 'blocks) '()))))

;; the records of the last turn, oldest first; REC is newest first
(define (drive-eval--turn rec)
  (let loop ((rs rec) (acc '()))
    (cond ((null? rs) acc)
          ((equal? (plist-get (car rs) 'role) "user") acc)
          (else (loop (cdr rs) (cons (car rs) acc))))))

;; (ROUNDS TOOLS) of the last turn of a chat record
(define (drive-eval--count rec)
  (let ((said (filter (lambda (m) (equal? (plist-get m 'role) "assistant")) (drive-eval--turn rec))))
    (list (length said) (apply + (map drive-eval--tool-uses said)))))

(define (drive-eval-mine &optional n max-tools)
  (filter (lambda (x) x)
    (map (lambda (f)
           (let ((r (ignore-errors (lambda () (chat-log-read f)))))
             (and r
                  (let* ((ps (plist-get r 'prompts))
                         (p (if (pair? ps) (car ps) ps))
                         (rec (plist-get r 'record))
                         (k (if (list? rec) (apply + (map drive-eval--tool-uses rec)) 0)))
                    (and (string? p) (> k 0) (<= k (or max-tools 10)) (< (string-length p) 160)
                         (not (string-prefix? "drive-eval" (or (plist-get (plist-get r 'header) 'title) "")))
                         (list k p f))))))
         (let ((fs (reverse (chat-log-files))))
           (list-head fs (min (or n 300) (length fs)))))))

(public! 'drive-eval-mine
  "(drive-eval-mine [N MAX-TOOLS]) -- (TOOLS PROMPT PATH) for the newest N archived chats whose first prompt is short and took at most MAX-TOOLS tool calls: candidate drive-eval cases")

(domain! 'chat)
(effects! '(write external spend))

;; the results subagent-wait gives at the turn end, or #f after SECS.
;; wait-until stops at about 10 s whatever it is asked, so wait in steps
;; up to the deadline.
(define (drive-eval--await slug secs)
  (let ((box #f)
        (deadline (+ (monotonic-ms) (* 1000 secs))))
    (subagent-wait slug (lambda (v) (set! box (list v))))
    (let loop ()
      (cond (box (car box))
            ((>= (monotonic-ms) deadline) #f)
            (else (wait-until (lambda () box) (- deadline (monotonic-ms)) 50) (loop))))))

(define (drive-eval--hook c key fb)
  (let ((f (and (> (length c) 5) (plist-get (list-ref c 5) key))))
    (when f (ignore-errors (lambda () (f fb))))))

;; one case on one model:
;; (CASE MODEL OK ROUNDS TOOLS MS STOP-REASON STEPS REPLY BYTES SLUG FRICTION REP)
;; STEPS is the chat-perf view of the turn, (LABEL MS) per round and tool.
;; REP, from 1, names the fixture and the chat, so runs at once share nothing.
(define (drive-eval--run c m &optional rep)
  (let* ((name (symbol->string (car c)))
         (label (symbol->string (car m)))
         (n (number->string (or rep 1)))
         (fixture (list-ref c 2))
         (fb (string-append "*drive-eval:" name ":" label ":" n "*"))
         (title (string-append "drive-eval " name " " label " " n)))
    (when fixture
      (unless (buffer-known? fb) (buffer-create fb))
      (buffer-set-text! fb fixture))
    (drive-eval--hook c 'setup fb)
    (let* ((t0 (monotonic-ms))
           (slug (execute* ((list-ref c 3) fb)
                           (append
                             (list 'connector (cadr m) 'model (caddr m) 'notify #f
                                   'permission-mode 'auto 'title title)
                             (if (> (length m) 3) (list 'bundle (list-ref m 3)) '())
                             ;; a fifth item adds execute* options: (recall #f)
                             (if (> (length m) 4) (list-ref m 4) '()))))
           (rs (drive-eval--await slug drive-eval-timeout-s))
           (ms (- (monotonic-ms) t0))
           (r (and (pair? rs) (car rs)))
           (buf (or (and r (plist-get r 'buffer)) title))
           (reply (or (and r (plist-get r 'text)) ""))
           (counts (if (buffer-known? buf) (drive-eval--count (chat-record buf)) '(0 0)))
           (friction (if (buffer-known? buf)
                         (or (ignore-errors (lambda () (drive-eval-friction (drive-eval--turn (chat-record buf))))) '())
                         '()))
           (steps (if (boundp 'agent-perf-turn) (agent-perf-turn slug) '()))
           (text (and fixture (buffer-known? fb) (buffer-text fb)))
           (bytes (if (buffer-known? buf)
                      (string-byte-length (prompt-parts-text (chat-prompt-parts buf)))
                      0))
           (ok (and r (ignore-errors (lambda () ((list-ref c 4) text reply fb))) #t)))
      (ignore-errors (lambda () (agent-kill! slug)))
      (when (buffer-known? buf) (buffer-kill! buf))
      (drive-eval--hook c 'cleanup fb)
      (when (and fixture (buffer-known? fb)) (buffer-kill! fb))
      (list (car c) (car m) ok (car counts) (cadr counts) ms
            (and r (plist-get r 'stop-reason)) steps reply bytes slug friction (or rep 1)))))

(define (drive-eval--of rows label) (filter (lambda (r) (eq? (cadr r) label)) rows))
(define (drive-eval--fmt x) (number->string (/ (round (* 10 x)) 10)))

(define (drive-eval--median xs)
  (if (null? xs)
      0
      (let* ((s (sort xs)) (n (length s)))
        (if (= 1 (remainder n 2))
            (list-ref s (quotient n 2))
            (/ (+ (list-ref s (- (quotient n 2) 1)) (list-ref s (quotient n 2))) 2)))))

;; a run the harness broke, not the model: it counts in no pass rate and no median
(define (drive-eval--harness? r) (and (memq (list-ref r 6) '(error harness-error)) #t))
(define (drive-eval--real rows) (filter (lambda (r) (not (drive-eval--harness? r))) rows))

(define (drive-eval--passed rows)
  (let ((real (drive-eval--real rows)) (bad (length (filter drive-eval--harness? rows))))
    (string-append (number->string (length (filter (lambda (r) (list-ref r 2)) real)))
                   "/" (number->string (length real))
                   (if (> bad 0) (string-append " +" (number->string bad) "e") ""))))

(define (drive-eval--score all)
  (define rows (drive-eval--real all))
  (string-append
    (drive-eval--passed all) " ok, median "
    (drive-eval--fmt (drive-eval--median (map (lambda (r) (list-ref r 3)) rows))) " rounds, "
    (drive-eval--fmt (drive-eval--median (map (lambda (r) (list-ref r 4)) rows))) " tools, "
    (drive-eval--fmt (/ (drive-eval--median (map (lambda (r) (list-ref r 5)) rows)) 1000)) " s"))

;; the runs of one case on one model: passed/runs, then the medians
(define (drive-eval--cell all)
  (define rows (drive-eval--real all))
  (string-append (drive-eval--passed all) " "
                 (drive-eval--fmt (drive-eval--median (map (lambda (r) (list-ref r 3)) rows))) "r "
                 (drive-eval--fmt (drive-eval--median (map (lambda (r) (list-ref r 4)) rows))) "t "
                 (drive-eval--fmt (/ (drive-eval--median (map (lambda (r) (list-ref r 5)) rows)) 1000)) "s"
                 (let ((fs (filter (lambda (r) (> (length r) 11)) rows)))
                   (if (null? fs) ""
                       (string-append " " (drive-eval--fmt (drive-eval--median (map (lambda (r) (drive-eval-wasted (list-ref r 11))) fs))) "w")))))

(define (drive-eval--short label)
  (let ((p "mcp__compos__"))
    (if (string-contains? label p)
        (string-join (string-split label p) "")
        label)))

;; one failed run: its reply, and where its rounds and seconds went
(define (drive-eval--failure r)
  (let ((reply (string-trim (or (list-ref r 8) ""))))
    (string-append
      (symbol->string (car r)) " " (symbol->string (cadr r)) ": "
      (number->string (list-ref r 3)) "r " (drive-eval--fmt (/ (list-ref r 5) 1000)) "s, replied "
      (value->string (substring reply 0 (min 60 (string-length reply))))
      "\n    "
      (string-join (map (lambda (s) (string-append (drive-eval--short (car s)) " " (number->string (cadr s))))
                        (or (list-ref r 7) '()))
                   ", "))))

;; one side of a gap line: (PASS-RATE ROUNDS SECONDS WASTED), the medians of ROWS
(define (drive-eval--side all)
  (define rows (drive-eval--real all))
  (let ((fs (filter (lambda (r) (and (> (length r) 11) (list-ref r 11))) rows)))
    (list (if (null? rows) 0 (/ (* 100.0 (length (filter (lambda (r) (list-ref r 2)) rows))) (length rows)))
          (drive-eval--median (map (lambda (r) (list-ref r 3)) rows))
          (/ (drive-eval--median (map (lambda (r) (list-ref r 5)) rows)) 1000.0)
          (drive-eval--median (map (lambda (r) (drive-eval-wasted (list-ref r 11))) fs)))))

(define (drive-eval--signed x)
  (string-append (if (> x 0) "+" "") (drive-eval--fmt x)))

(define (drive-eval--side-text s)
  (string-append (drive-eval--fmt (car s)) "% " (drive-eval--fmt (cadr s)) "r "
                 (drive-eval--fmt (caddr s)) "s " (drive-eval--fmt (cadddr s)) "w"))

;; per case, the original and its rewordings together, the driver against the
;; strong model of drive-eval-gap-pair: pass rate, median rounds, seconds and
;; wasted rounds, then driver minus strong. Empty unless both models ran.
(define (drive-eval--gap rows cases)
  (let* ((a (car drive-eval-gap-pair)) (b (cadr drive-eval-gap-pair))
         (ra (drive-eval--of rows a)) (rb (drive-eval--of rows b)))
    (if (or (null? ra) (null? rb))
        ""
        (let* ((bases (fold (lambda (acc c) (let ((x (drive-eval--base (car c)))) (if (memq x acc) acc (append acc (list x))))) '() cases))
               (line (lambda (label xa xb)
                       (let ((sa (drive-eval--side xa)) (sb (drive-eval--side xb)))
                         (string-append
                           (string-pad-right label 10)
                           (string-pad-right (drive-eval--side-text sa) 28)
                           (string-pad-right (drive-eval--side-text sb) 28)
                           (drive-eval--signed (- (car sa) (car sb))) "% "
                           (drive-eval--signed (- (cadr sa) (cadr sb))) "r "
                           (drive-eval--signed (- (caddr sa) (caddr sb))) "s "
                           (drive-eval--signed (- (cadddr sa) (cadddr sb))) "w"))))
               (of-base (lambda (rs x) (filter (lambda (r) (eq? (drive-eval--base (car r)) x)) rs))))
          (string-append
            "\nGap: " (symbol->string a) " against " (symbol->string b)
            ", each case with its rewordings: pass rate, median rounds, seconds, wasted rounds; then the gap\n"
            (string-pad-right "case" 10) (string-pad-right (symbol->string a) 28) (string-pad-right (symbol->string b) 28) "gap\n"
            (string-join (map (lambda (x) (line (symbol->string x) (of-base ra x) (of-base rb x))) bases) "\n")
            "\n" (line "all" ra rb) "\n")))))

(define (drive-eval--text rows models cases)
  (let ((labels (map car models))
        (failed (filter (lambda (r) (not (list-ref r 2))) rows)))
    (string-append
      "drive-eval: "
      (string-join (map (lambda (l) (string-append (symbol->string l) " " (drive-eval--score (drive-eval--of rows l))
                                                     " prompt " (number->string (fold (lambda (acc r) (if (> (length r) 9) (max acc (list-ref r 9)) acc)) 0 (drive-eval--of rows l))) "B")) labels) "; ")
      "\n\n" (string-pad-right "case" 12)
      (string-join (map (lambda (l) (string-pad-right (symbol->string l) 28)) labels) "")
      "\n"
      (string-join
        (map (lambda (c)
               (string-append
                 (string-pad-right (symbol->string (car c)) 12)
                 (string-join
                   (map (lambda (l)
                          (let ((rs (filter (lambda (r) (and (eq? (car r) (car c)) (eq? (cadr r) l))) rows)))
                            (string-pad-right (if (pair? rs) (drive-eval--cell rs) "-") 28)))
                        labels)
                   "")))
             cases)
        "\n")
      "\n\npassed/runs, then medians. +Ne: runs the harness broke, left out of every rate and median. r: model replies in the turn; t: tool calls; s: send to turn end; w: tool rounds wasted on the harness. NAME.rN is a held-out rewording.\n"
      (or (ignore-errors (lambda () (drive-eval--gap rows cases))) "")
      (if (null? failed)
          ""
          (string-append "\nFailures, with the steps of each turn (ms)\n"
                         (string-join (map drive-eval--failure failed) "\n") "\n"))
      (let ((fr (filter (lambda (r) (> (length r) 11)) rows)))
        (if (null? fr)
            ""
            (drive-eval-friction-text (map (lambda (r) (list (car r) (cadr r) (list-ref r 11))) fr)))))))

(define (drive-eval--case x)
  (if (symbol? x)
      (or (assq x *drive-eval-cases*) (assq x *drive-eval-hard-cases*) (assq x *drive-eval-unseen-cases*))
      x))

;; Run every case on every model REPS times, drive-eval-parallel runs at
;; once, in a task. MODELS and CASES take names or whole entries; CASES
;; 'hard is the harness set, 'all both sets. PROMPTS picks original,
;; reworded or all, and defaults to drive-eval-prompts.
(define drive-eval-results-file (string-append (getenv "HOME") "/.compos/drive-eval/results.txt"))

;; the table so far, after each run: into *drive-eval* and into
;; drive-eval-results-file, so a buffer on that file in auto-revert shows the
;; rows as they come. A report that throws never stops the run.
(define (drive-eval--progress! rows ms cs &optional id)
  (let ((text (string-append (if id (string-append "[" id "] ") "")
                             (or (ignore-errors (lambda () (drive-eval--text rows ms cs)))
                                 "drive-eval: running"))))
    (ignore-errors (lambda () (write-file! drive-eval-results-file text)))
    (when id (ignore-errors (lambda () (write-file! (drive-eval-run-file id) text))))
    (ignore-errors (lambda ()
                     (unless (buffer-known? "*drive-eval*") (buffer-create "*drive-eval*"))
                     (buffer-set-text! "*drive-eval*" text)))
    text))

;; ~/.compos/drive-eval/ID.txt: the table of one run, as results.txt holds the latest
(define (drive-eval-run-file id)
  (string-append (getenv "HOME") "/.compos/drive-eval/" id ".txt"))

;; The runs going now, ((ID PLIST) ...): each its own queue, rows and cancel
;; flag, so two chats can run drive-eval at once. Every write holds the lock
;; drive-eval. A reload keeps them: the defines below read the old value.
(define *drive-eval-runs* (if (boundp '*drive-eval-runs*) *drive-eval-runs* '()))
;; OpenCode runs going now, over every run: one at a time
(define *drive-eval--opencode* (if (boundp '*drive-eval--opencode*) *drive-eval--opencode* 0))
;; counts the runs, so two that start in one millisecond still get two ids
(define *drive-eval--serial* (if (boundp '*drive-eval--serial*) *drive-eval--serial* 0))
;; #t while any run goes
(define *drive-eval-running* (pair? *drive-eval-runs*))

(define (drive-eval--state id) (let ((x (assoc id *drive-eval-runs*))) (and x (cadr x))))
(define (drive-eval--put! id key val)
  (let ((st (drive-eval--state id)))
    (when st (set! *drive-eval-runs* (alist-put *drive-eval-runs* id (plist-put st key val))))))
(define (drive-eval--locked thunk) (with-scheme-lock 'drive-eval thunk))

(define (drive-eval--opencode? m) (string-prefix? "opencode" (cadr m)))

(define (drive-eval--range from to)
  (if (> from to) '() (cons from (drive-eval--range (+ from 1) to))))

;; (JOB . REST) for the first job of Q a worker may start, or #f: an OpenCode
;; job waits while another OpenCode run goes
(define (drive-eval--pick q)
  (let loop ((xs q) (before '()))
    (cond ((null? xs) #f)
          ((or (not (drive-eval--opencode? (cadr (car xs)))) (= 0 *drive-eval--opencode*))
           (cons (car xs) (append (reverse before) (cdr xs))))
          (else (loop (cdr xs) (cons (car xs) before))))))

;; the next job of run ID, (CASE MODEL REP), taken off its queue; #f after a
;; cancel or when none may start. A worker that gets #f stops: the queue only
;; shrinks, and a held OpenCode job goes to the worker that runs OpenCode now.
(define (drive-eval--take! id)
  (drive-eval--locked
    (lambda ()
      (let ((st (drive-eval--state id)))
        (and st (not (plist-get st 'cancel))
             (let ((hit (drive-eval--pick (plist-get st 'queue))))
               (and hit
                    (begin
                      (drive-eval--put! id 'queue (cdr hit))
                      (when (drive-eval--opencode? (cadr (car hit)))
                        (set! *drive-eval--opencode* (+ *drive-eval--opencode* 1)))
                      (car hit)))))))))

;; one job; a run that raises gives a row marked harness-error, and the error
;; goes to *Messages* under drive-eval
(define (drive-eval--job j)
  (or (report-errors "drive-eval" (lambda () (drive-eval--run (car j) (cadr j) (caddr j))))
      (list (car (car j)) (car (cadr j)) #f 0 0 0 'harness-error '()
            "the harness raised an error; see *Messages*" 0 #f '() (caddr j))))

(define (drive-eval--worker id ms cs)
  (let loop ()
    (let ((j (drive-eval--take! id)))
      (when j
        (let ((row (drive-eval--job j)))
          (drive-eval--locked
            (lambda ()
              (when (drive-eval--opencode? (cadr j))
                (set! *drive-eval--opencode* (- *drive-eval--opencode* 1)))
              (let ((rows (cons row (plist-get (drive-eval--state id) 'done))))
                (drive-eval--put! id 'done rows)
                (drive-eval--progress! (reverse rows) ms cs id)))))
        (loop)))))

;; Answers the run id: "de-", the clock and a count. The event drive-eval done says
;; "ID ..." with the first line of the table, "ID cancelled after N of M
;; runs: ..." after drive-eval-cancel!.
(define (drive-eval &optional models cases reps prompts)
  (let* ((ms (map (lambda (x) (if (symbol? x) (assq x *drive-eval-models*) x)) (or models *drive-eval-models*)))
         (base (cond ((eq? cases 'hard) *drive-eval-hard-cases*)
                     ((eq? cases 'unseen) *drive-eval-unseen-cases*)
                     ((eq? cases 'all) (append *drive-eval-cases* *drive-eval-hard-cases*))
                     (cases (map drive-eval--case cases))
                     (else *drive-eval-cases*)))
         (cs (apply append (map (lambda (c) (drive-eval--variants c (or prompts drive-eval-prompts))) base)))
         (n (or reps 1))
         ;; repeat 1 of every case first, so a cancelled run still covers the set
         (jobs (apply append
                 (map (lambda (i) (apply append (map (lambda (c) (map (lambda (m) (list c m i)) ms)) cs)))
                      (drive-eval--range 1 n))))
         (p (max 1 (min drive-eval-parallel (length jobs))))
         (limit (* 1000 (+ 120 (* drive-eval-timeout-s (length jobs)))))
         (id (drive-eval--locked
               (lambda ()
                 (set! *drive-eval--serial* (+ *drive-eval--serial* 1))
                 (string-append "de-" (number->string (abs (monotonic-ms))) "-" (number->string *drive-eval--serial*))))))
    (drive-eval--locked
      (lambda ()
        (set! *drive-eval-runs* (alist-put *drive-eval-runs* id (list 'queue jobs 'done '() 'cancel #f 'jobs (length jobs))))
        (set! *drive-eval-running* #t)))
    (task-run!
      (lambda ()
        (drive-eval--progress! '() ms cs id)
        (let ((ws (map (lambda (k) (task-spawn (lambda () (drive-eval--worker id ms cs)))) (drive-eval--range 1 p))))
          (for-each (lambda (w) (ignore-errors (lambda () (task-await w limit)))) ws)
          (reverse (plist-get (drive-eval--state id) 'done))))
      (lambda (ok? rows)
        (let ((cancelled (plist-get (or (drive-eval--state id) '()) 'cancel)))
          (drive-eval--locked
            (lambda ()
              (if ok?
                  (set! *drive-eval-runs* (filter (lambda (x) (not (equal? (car x) id))) *drive-eval-runs*))
                  ;; a timed-out run: its workers stop at their next take
                  (drive-eval--put! id 'cancel #t))
              (set! *drive-eval-running* (pair? *drive-eval-runs*))))
          (if (not ok?)
              (let ((why (string-append id " drive-eval failed: " (value->string rows))))
                (message why)
                (event-publish! "drive-eval" 'done why))
              ;; the rows land first, and a report that throws still wakes the
              ;; listener: a silent callback looked like a dead run
              (let* ((text (begin
                             (set! *drive-eval-rows* rows)
                             (or (ignore-errors (lambda () (drive-eval--text rows ms cs)))
                                 "drive-eval: the report failed; the rows are in *drive-eval-rows*")))
                     (head (string-append id " "
                                          (if cancelled
                                              (string-append "cancelled after " (number->string (length rows)) " of "
                                                             (number->string (length jobs)) " runs: ")
                                              "")
                                          (car (string-split text "\n")))))
                (unless (buffer-known? "*drive-eval*") (buffer-create "*drive-eval*"))
                (buffer-set-text! "*drive-eval*" (string-append "[" id "] " text))
                (ignore-errors (lambda () (write-file! drive-eval-results-file (string-append "[" id "] " text))))
                (ignore-errors (lambda () (write-file! (drive-eval-run-file id) (string-append "[" id "] " text))))
                (message head)
                (event-publish! "drive-eval" 'done head)))))
      (+ limit 60000))
    id))

;; stop run ID between runs: the runs going now end, no new one starts, and
;; drive-eval done says ID cancelled with the table so far. Without ID it
;; stops the one run going, and names the runs when there are more.
(define (drive-eval-cancel! &optional id)
  (let ((ids (map car *drive-eval-runs*)))
    (cond ((and id (not (member id ids))) (string-append "drive-eval: no run " id " is going"))
          ((and (not id) (null? ids)) "drive-eval: no run is going")
          ((and (not id) (> (length ids) 1))
           (string-append "drive-eval: several runs go; name one: " (string-join ids " ")))
          (else
           (let ((k (or id (car ids))))
             (drive-eval--locked (lambda () (drive-eval--put! k 'cancel #t)))
             (string-append "drive-eval: " k " cancelled; the runs going now finish, then drive-eval done reports"))))))

(public! 'drive-eval
  "(drive-eval [MODELS CASES REPS PROMPTS]) -- answers a run id; give each case, a real chat task, to a fresh chat on each model REPS times, drive-eval-parallel at once, and score passes, median rounds, tool calls and seconds; CASES 'hard is the harness set, 'all both; PROMPTS original, reworded (two held-out rewordings) or all, default drive-eval-prompts; the table and the haiku-driver/opus gap go to *drive-eval*, the event drive-eval done says the score")
(public! 'drive-eval-cancel!
  "(drive-eval-cancel! [ID]) -- stop drive-eval run ID, or the one run going, between runs: the runs going now end, no new one starts, and drive-eval done says ID cancelled; each run's table is in ~/.compos/drive-eval/ID.txt")
(public! 'drive-eval-run-file
  "(drive-eval-run-file ID) -- the path of run ID's table, ~/.compos/drive-eval/ID.txt; builds the path only")
(catalog-meta! 'function "drive-eval-run-file" 'domain 'chat 'effects '(pure))

;;; Friction: the tool calls of a run that did no work, and why.
;;; A passing run can still lose rounds to the harness; the score hides it.

(domain! 'chat)
(effects! '(pure))

(define drive-eval-friction-kinds
  '((schema-load "ToolSearch: a round to load a tool schema")
    (no-tool "a call to a tool that does not exist")
    (wrong-args "wrong argument names")
    (unbound "an unbound or guessed name")
    (read-gate "the read eval refused the code")
    (error "the call raised an error")
    (repeated "the same call again")
    (dead-discovery "a search whose answer the run did not use")
    (oversized "a result over 20 KB")
    (empty "an empty result")))

(define (drive-eval--str x) (if (string? x) x (value->string x)))

(define (drive-eval--discovery? call)
  (let ((name (list-ref call 1)) (input (list-ref call 2)))
    (or (string-contains? name "apropos") (string-contains? name "describe")
        (string-contains? input "\"(apropos ") (string-contains? input "\"(describe-function "))))

(define (drive-eval--calls rec)
  "the tool calls of REC, oldest first, as (ROUND NAME INPUT RESULT ERROR?)"
  (let ((results (filter (lambda (b) (and (pair? b) (equal? (car b) "tool-result")))
                         (apply append (map (lambda (m) (or (plist-get m 'blocks) '())) rec)))))
    (let loop ((ms rec) (round 0) (acc '()))
      (if (null? ms)
          (reverse acc)
          (let ((uses (filter (lambda (b) (and (pair? b) (equal? (car b) "tool-use")))
                              (or (plist-get (car ms) 'blocks) '()))))
            (if (null? uses)
                (loop (cdr ms) round acc)
                (loop (cdr ms) (+ round 1)
                      (append (reverse
                                (map (lambda (u)
                                       (let ((r (find (lambda (x) (equal? (cadr x) (cadr u))) results)))
                                         (list round (caddr u) (drive-eval--str (cadddr u))
                                               (if r (drive-eval--str (caddr r)) "")
                                               (and r (> (length r) 3) (cadddr r) #t))))
                                     uses))
                              acc))))))))

(define (drive-eval--names call)
  "the names a discovery call answered: each name of an apropos row, and the name a describe asked for"
  (let* ((parts (string-split (list-ref call 3) "name \""))
         (found (map (lambda (p) (let ((i (string-index p "\""))) (if i (substring-bytes p 0 i) "")))
                     (if (pair? parts) (cdr parts) '())))
         (asked (let ((j (ignore-errors (lambda () (json-parse (list-ref call 2))))))
                  (if (and (pair? j) (string? (plist-get j 'name))) (list (plist-get j 'name)) '()))))
    (filter (lambda (s) (> (string-length s) 2)) (append asked found))))

(define (drive-eval--kind call earlier later)
  (let* ((name (list-ref call 1))
         (input (list-ref call 2))
         (t (string-trim (list-ref call 3)))
         (low (string-downcase (substring t 0 (min 200 (string-length t))))))
    (cond ((string-suffix? "ToolSearch" name) 'schema-load)
          ((string-contains? t "No such tool available") 'no-tool)
          ((or (string-contains? t "you sent {") (string-contains? t "InputValidationError")) 'wrong-args)
          ((or (string-contains? low "is unbound") (string-contains? low "unbound variable")) 'unbound)
          ((string-prefix? "refused:" t) 'read-gate)
          ((or (list-ref call 4) (string-prefix? "error" low)) 'error)
          ((any (lambda (c) (and (equal? (list-ref c 1) name) (equal? (list-ref c 2) input))) earlier) 'repeated)
          ((and (drive-eval--discovery? call) (pair? later)
                (let ((ns (drive-eval--names call)))
                  (not (any (lambda (c) (any (lambda (n) (string-contains? (list-ref c 2) n)) ns)) later))))
           'dead-discovery)
          ((> (string-length t) 20000) 'oversized)
          ((member t '("" "()" "\"\"")) 'empty)
          (else #f))))

(define (drive-eval-friction rec)
  "each tool call of REC, oldest first, as (KIND ROUND NAME INPUT RESULT ERROR?); KIND #f is a useful call"
  (let loop ((cs (drive-eval--calls rec)) (earlier '()) (acc '()))
    (if (null? cs)
        (reverse acc)
        (let ((later (filter (lambda (x) (not (drive-eval--discovery? x))) (cdr cs))))
          (loop (cdr cs) (cons (car cs) earlier)
                (cons (cons (drive-eval--kind (car cs) earlier later) (car cs)) acc))))))

(define (drive-eval--rounds fr)
  (fold (lambda (acc f) (if (member (cadr f) acc) acc (cons (cadr f) acc))) '() fr))

(define (drive-eval--lost fr)
  "((KIND SHARE CALL) ...): each call of a round where every call was wasted, with its share of that round"
  (apply append
    (map (lambda (r)
           (let ((in (filter (lambda (f) (= (cadr f) r)) fr)))
             (if (every car in)
                 (map (lambda (f) (list (car f) (/ 1.0 (length in)) f)) in)
                 '())))
         (drive-eval--rounds fr))))

(define (drive-eval-wasted fr)
  "the rounds of a friction list where every tool call was wasted"
  (length (filter (lambda (r) (every car (filter (lambda (f) (= (cadr f) r)) fr))) (drive-eval--rounds fr))))

(define (drive-eval--clip s n)
  (let ((s (string-join (string-split (drive-eval--str s) "\n") " ")))
    (if (> (string-length s) n) (string-append (substring s 0 n) "...") s)))

(define (drive-eval-friction-text runs)
  "RUNS is ((CASE LABEL FRICTION) ...): the rounds wasted, and the kinds ranked by rounds lost, each with one real call"
  (let* ((frs (map caddr runs))
         (rounds (apply + (map (lambda (fr) (length (drive-eval--rounds fr))) frs)))
         (lost (apply append (map (lambda (run) (map (lambda (l) (cons run l)) (drive-eval--lost (caddr run)))) runs)))
         (calls (apply append (map (lambda (run) (map (lambda (f) (cons run f)) (caddr run))) runs)))
         (rows (filter (lambda (x) (> (cadr x) 0))
                 (map (lambda (k)
                        (let ((ls (filter (lambda (l) (eq? (cadr l) (car k))) lost)))
                          (list (car k)
                                (apply + (map caddr ls))
                                (length (filter (lambda (c) (eq? (cadr c) (car k))) calls))
                                (if (pair? ls) (car ls) (find (lambda (c) (eq? (cadr c) (car k))) calls))
                                (cadr k))))
                      drive-eval-friction-kinds)))
         (ranked (map cadr (sort (map (lambda (r) (list (- (cadr r)) r)) rows)))))
    (string-append
      "\nFriction: " (number->string (apply + (map drive-eval-wasted frs))) " of " (number->string rounds)
      " tool rounds wasted in " (number->string (length runs)) " runs\n"
      "rounds lost, wasted calls, kind; then one real call -> its result\n"
      (string-join
        (map (lambda (x)
               (let* ((ex (list-ref x 3))
                      (run (car ex))
                      (f (if (= (length ex) 4) (cadddr ex) (cdr ex))))
                 (string-append
                   (string-pad-right (drive-eval--fmt (cadr x)) 6) (string-pad-right (number->string (caddr x)) 5)
                   (symbol->string (car x)) ": " (list-ref x 4) "\n      "
                   (symbol->string (car run)) " " (symbol->string (cadr run)) ": "
                   (list-ref f 2) " " (drive-eval--clip (list-ref f 3) 90)
                   " -> " (drive-eval--clip (list-ref f 4) 110))))
             ranked)
        "\n")
      "\n")))

(domain! 'chat)
(effects! '(read))

(define (drive-eval-friction-logs since)
  "((CASE LABEL FRICTION) ...), oldest first, from the archived drive-eval chats whose log began at or after SINCE, epoch seconds"
  (let ((fs (filter (lambda (f) (>= (or (drive-eval--number (last (string-split f "/"))) 0) since)) (chat-log-files))))
    (filter (lambda (x) x)
      (map (lambda (f)
             (let* ((r (ignore-errors (lambda () (chat-log-read f))))
                    (title (or (and r (plist-get (plist-get r 'header) 'title)) ""))
                    (ws (string-split title " ")))
               (and (string-prefix? "drive-eval " title) (>= (length ws) 3)
                    (list (string->symbol (cadr ws)) (string->symbol (caddr ws))
                          (drive-eval-friction (or (plist-get r 'record) '()))))))
           (map cadr (sort (map (lambda (f) (list (or (drive-eval--number (last (string-split f "/"))) 0) f)) fs)))))))

(define (drive-eval-friction-fill rows since)
  "ROWS with the friction of each run that lacks it, from the archived chats since SINCE: the Nth run of a case on a model takes the Nth log of that title"
  (let ((logs (drive-eval-friction-logs since)))
    (let loop ((rs rows) (seen '()) (acc '()))
      (if (null? rs)
          (reverse acc)
          (let* ((r (car rs))
                 (key (list (car r) (cadr r)))
                 (n (length (filter (lambda (k) (equal? k key)) seen)))
                 (mine (filter (lambda (l) (and (eq? (car l) (car r)) (eq? (cadr l) (cadr r)))) logs))
                 (fr (cond ((> (length r) 11) (list-ref r 11))
                           ((> (length mine) n) (caddr (list-ref mine n)))
                           (else #f))))
            (loop (cdr rs) (cons key seen)
                  (cons (if (and fr (<= (length r) 11))
                            (append r (list-head '(#f #f #f #f #f #f #f #f #f #f) (- 10 (length r))) (list #f fr))
                            r)
                        acc)))))))

(public! 'drive-eval-friction-fill
  "(drive-eval-friction-fill ROWS SINCE) -- drive-eval rows, each with the friction of its run; a row from before friction takes it from the archived chat logs since SINCE, epoch seconds")
(public! 'drive-eval-friction
  "(drive-eval-friction REC) -- each tool call of a chat record, oldest first, as (KIND ROUND NAME INPUT RESULT ERROR?); KIND names why the call was wasted (schema-load, no-tool, wrong-args, unbound, read-gate, error, repeated, dead-discovery, oversized, empty) or is #f")
(public! 'drive-eval-friction-text
  "(drive-eval-friction-text RUNS) -- RUNS is ((CASE LABEL FRICTION) ...); the friction report: rounds wasted, kinds ranked by rounds lost, one real call each")
(public! 'drive-eval-friction-logs
  "(drive-eval-friction-logs SINCE) -- ((CASE LABEL FRICTION) ...) from the archived drive-eval chats whose log began at or after SINCE, epoch seconds")

