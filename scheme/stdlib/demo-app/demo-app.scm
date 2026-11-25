;;; demo-app.scm --- the model app: copy this file to start a new app.
;;;
;;; M-x demo-app opens a listing of house plants and a page per plant
;;; beside it. The data is in memory, so the file shows only what makes
;;; an app an app: a LISTING (one row per thing), a DETAIL (one buffer
;;; per row, beside the listing) and ACTIONS (the same verbs under the
;;; same keys on both). Every rule of the app-creator skill is here once.
;;;
;;; To make a new app: copy the file, rename demo-app to the app's name
;;; everywhere, and replace the data section with the app's own source.

(domain! 'ui)
(effects! '(pure))

;; Name the app once and name everything after it.
(define *demo-app-id* "demo-app")
(define *demo-app-mode* "demo-app-mode")
(define *demo-app-detail-mode* "demo-app-detail-mode")

;; The verbs: (KEY COMMAND LABEL [TONE]). Both keymaps, the listing's
;; keys card, the page's action bar and the page's keys card are made
;; from this one table, so a verb cannot be bound in one place and
;; missing from another.
(define demo-app-verbs
  '(("t" "demo-app-water" "Water" "good")
    ("s" "demo-app-star" "Star")
    ("z" "demo-app-snooze" "Snooze a day")
    ("g" "demo-app-refresh" "Refresh")))

(define (demo-app--keys-card extra)
  "the keys a buffer draws: every verb, then EXTRA"
  (append (map (lambda (v) (list (car v) (string-downcase (caddr v)))) demo-app-verbs) extra))

;;; ---------------------------------------------------------------- data
;; Replace this section with the app's own source. Rows are records
;; (plists), never printed lines.

(define *demo-app-plants*
  (if (boundp '*demo-app-plants*) *demo-app-plants*
      (list (list 'id "fern" 'name "Boston fern" 'room "bathroom" 'thirst 2 'since 3 'starred #f 'log '())
            (list 'id "monstera" 'name "Monstera" 'room "living room" 'thirst 7 'since 2 'starred #t 'log '())
            (list 'id "pothos" 'name "Golden pothos" 'room "kitchen" 'thirst 5 'since 5 'starred #f 'log '())
            (list 'id "cactus" 'name "Barrel cactus" 'room "window sill" 'thirst 21 'since 9 'starred #f 'log '())
            (list 'id "calathea" 'name "Calathea" 'room "bedroom" 'thirst 3 'since 1 'starred #f 'log '())
            (list 'id "fig" 'name "Fiddle-leaf fig" 'room "living room" 'thirst 8 'since 10 'starred #t 'log '()))))

(define (demo-app--due p) (- (plist-get p 'thirst) (plist-get p 'since)))

(define (demo-app--state p)
  "the plant's state as (WORD TONE)"
  (let ((d (demo-app--due p)))
    (cond ((< d 0) (list "thirsty" "bad"))
          ((= d 0) (list "due today" "warn"))
          (else (list (string-append "in " (number->string d) " d") "good")))))

(effects! '(read))
(define (demo-app-plants) *demo-app-plants*)
(define (demo-app-plant id)
  (find (lambda (p) (equal? (plist-get p 'id) id)) *demo-app-plants*))

;;; ------------------------------------------------------------- listing

(define (demo-app--rows buf) (demo-app-plants))

(define (demo-app--cells buf p)
  (let ((st (demo-app--state p)))
    (list (if (plist-get p 'starred) "*" "")
          (plist-get p 'name)
          (list (car st) (string-append "c-" (cadr st)))
          (list (plist-get p 'room) "c-dim"))))

(define (demo-app--listing)
  "the listing of the current group: one copy per group"
  (list-mode-group-buffer *demo-app-mode*))

;; imenu is chosen: the rows by the name a reader knows, kind plant,
;; the doc one line to choose by.
(define (demo-app--list-imenu buf)
  (map (lambda (p off)
         (list (with-current-buffer buf (lambda () (line-number-at-pos off)))
               "plant" (plist-get p 'name)
               (string-append (car (demo-app--state p)) " · " (plist-get p 'room))))
       (demo-app-plants) (list-offsets buf)))

(effects! '(write display))
(define-list-mode! *demo-app-mode*
  (list
    'doc (string-append
           "House plants, the model app. Moving the point shows the plant's page beside the list. "
           "t waters the plant, s stars it, z snoozes it a day, g redraws. "
           "/ narrows the rows, w watches, q quits. The same keys work on the page.")
    'buffer "*demo-app*"
    'transient #f
    'plain #t
    'rows demo-app--rows
    'key (lambda (buf p) (plist-get p 'id))
    'markable? (lambda (buf p) #f)
    'columns (lambda (buf) (list (list "" 2) (list "plant" 18) (list "water" 11) (list "room" #f)))
    'cells demo-app--cells
    'layouts (list (list 'name 'narrow 'max-cols (lambda (buf) 40)
                         'columns (lambda (buf) (list (list "plant" #f) (list "water" 11)))
                         'cells (lambda (buf p) (let ((c (demo-app--cells buf p))) (list (cadr c) (caddr c)))))
                   (list 'name 'wide 'default #t))
    'preview (lambda (buf p) (demo-app-show-detail! p))
    'title (lambda (buf) "House plants")
    'noun "plant"
    ;; the listing draws its keymap
    'footer (lambda (buf) (demo-app--keys-card '(("/" "filter") ("w" "watch") ("q" "quit"))))
    'keys (append (map (lambda (v) (list (car v) (cadr v))) demo-app-verbs)
                  '(("q" "quit-window")))))

;;; -------------------------------------------------------------- detail

(define-mode *demo-app-detail-mode* (lambda () (buffer-set-read-only! (current-buffer) #t)))
(mode-keys! *demo-app-detail-mode* (map (lambda (v) (list (car v) (cadr v))) demo-app-verbs))
(mode-doc! *demo-app-detail-mode*
  "One plant: its state, its actions and its log. t waters, s stars, z snoozes, g redraws; C-` walks the pages you opened, M-RET keeps this one.")
;; a page kept with M-RET takes the plant's name
(detail-name! *demo-app-detail-mode*
  (lambda (buf) (string-append "*" (or (buffer-local-value 'demo-app-name buf) buf) "*")))
;; a key the listing does not bind runs in the page beside it
(app-detail-keys! *demo-app-mode* *demo-app-detail-mode*)
;; this app knows when its data changes, so its buffers start watched
(app-watch-define! *demo-app-mode*)
(app-watch-define! *demo-app-detail-mode*)

(effects! '(pure))
(define (demo-app-detail-buffer p) (string-append "*demo-app:" (plist-get p 'id) "*"))

(define (demo-app--page-blocks p)
  "the page: header, action bar, facts in named parts, the log as rows, an end mark"
  (let ((st (demo-app--state p))
        (log (plist-get p 'log)))
    (list
      (component 'ui/title (list 'text (plist-get p 'name) 'badge (car st) 'tone (cadr st)))
      (component 'ui/meta (list 'segs (list (list "" (plist-get p 'room))
                                            '("c-sep" "  ·  ")
                                            (list "c-dim" (if (plist-get p 'starred) "starred" "not starred")))))
      ;; every button has a key, and the key is drawn on it
      (component 'ui/actions
        (list 'actions (map (lambda (v) (if (pair? (cdddr v))
                                            (list (cadr v) (caddr v) (car v) (cadddr v))
                                            (list (cadr v) (caddr v) (car v))))
                            demo-app-verbs)))
      (component 'ui/group
        (list 'title "Water"
              'body (list (list 'tag "c-group" 'class "c-prose"
                                'text (string-append "Wants water every " (number->string (plist-get p 'thirst))
                                                     " days. Last watered " (number->string (plist-get p 'since))
                                                     " days ago. t waters it now.")))))
      (component 'ui/group
        (list 'title (string-append "Log  ·  " (number->string (length log)))
              'body (if (null? log)
                        (list (list 'tag "c-group" 'class "c-prose c-dim" 'text "Nothing yet. t waters the plant."))
                        (map (lambda (e) (component 'ui/row (list 'segs (list (list "c-dim" (car e)) (list "" (string-append "  " (cadr e)))))))
                             log))))
      (list 'tag "c-group" 'class "c-dim" 'text "end"))))

(effects! '(write))
(define (demo-app--render-page! buf p)
  (buffer-set-read-only! buf #f)
  (anchor-page! buf (demo-app--page-blocks p))
  ;; every page draws its keymap, the same card the listing draws
  (buffer-set-local! buf 'footer-line-blocks
    (list (component 'ui/keys-bar
            (list 'main (demo-app--keys-card '(("C-`" "next page") ("M-RET" "keep") ("w" "watch")))))))
  (buffer-set-read-only! buf #t))

(define (demo-app--claim! buf role)
  "BUF joins the group the frame is in and the app instance"
  (let ((g (and (boundp 'group-here) (group-here))))
    (when (and g (not (equal? (buffer-group buf) g))) (buffer-move-to-group! buf g))
    (app-claim! buf *demo-app-id* role)))

(effects! '(write display))
(define (demo-app-show-detail! p)
  "(demo-app-show-detail! PLANT) -- draw PLANT's page and show it beside the listing"
  (when p
    (let ((buf (demo-app-detail-buffer p)))
      (unless (buffer-known? buf)
        (buffer-create buf)
        (with-current-buffer buf (lambda () (set-mode! *demo-app-detail-mode*)))
        (desktop-skip! buf 'render-blocks)
        (desktop-skip! buf 'footer-line-blocks))
      (demo-app--claim! buf 'detail)
      (buffer-set-local! buf 'demo-app-id (plist-get p 'id))
      (buffer-set-local! buf 'demo-app-name (plist-get p 'name))
      (demo-app--render-page! buf p)
      (display-buffer-detail! buf (demo-app--listing)))))

(effects! '(write))
(define (demo-app--redraw! id)
  "after a change: redraw the listing and the plant's page, when watched"
  (let ((list-buf (demo-app--listing))
        (p (demo-app-plant id)))
    (when (and (buffer-known? list-buf) (app-watching? list-buf)) (list-refresh! list-buf))
    (when p
      (let ((buf (demo-app-detail-buffer p)))
        (when (and (buffer-known? buf) (app-watching? buf)) (demo-app--render-page! buf p))))))

(define (demo-app--update! id f note)
  "the one door that changes a plant: apply F, log NOTE, redraw"
  (set! *demo-app-plants*
        (map (lambda (p) (if (equal? (plist-get p 'id) id)
                             (let ((q (f p))) (plist-put q 'log (cons (list (current-time-string) note) (plist-get q 'log))))
                             p))
             *demo-app-plants*))
  (demo-app--redraw! id))

;;; ------------------------------------------------------------- actions
;; One function per verb takes the record. Both keys reach it through
;; demo-app--at: the page's own plant, else the listing's row.

(effects! '(read))
(define (demo-app--at)
  (let ((id (buffer-local-value 'demo-app-id (current-buffer))))
    (or (and id (demo-app-plant id))
        (let ((l (demo-app--listing))) (and (buffer-known? l) (list-current l))))))

(effects! '(write))
(define (demo-app-water! id)
  "(demo-app-water! ID) -- water plant ID now"
  (demo-app--update! id (lambda (p) (plist-put p 'since 0)) "watered"))

(define (demo-app-star! id)
  "(demo-app-star! ID) -- star plant ID, or take its star away"
  (demo-app--update! id (lambda (p) (plist-put p 'starred (not (plist-get p 'starred)))) "star changed"))

(define (demo-app-snooze! id)
  "(demo-app-snooze! ID) -- put plant ID's next watering off a day"
  (demo-app--update! id (lambda (p) (plist-put p 'since (- (plist-get p 'since) 1))) "snoozed a day"))

(define (demo-app--act verb done)
  "run VERB on the plant at hand; every action answers with a message"
  (let ((p (demo-app--at)))
    (if (not p) (message "No plant here")
        (begin (verb (plist-get p 'id))
               (message (string-append (plist-get p 'name) ": " done))))))

(define-command "demo-app-water" "Water the plant at point"
  (lambda () (demo-app--act demo-app-water! "watered")))
(define-command "demo-app-star" "Star the plant at point, or take the star away"
  (lambda () (demo-app--act demo-app-star! "star changed")))
(define-command "demo-app-snooze" "Put the plant's next watering off a day"
  (lambda () (demo-app--act demo-app-snooze! "snoozed a day")))
(define-command "demo-app-refresh" "Redraw the plants and this page"
  (lambda ()
    (let ((l (demo-app--listing)))
      (when (buffer-known? l) (list-refresh! l))
      (let ((p (demo-app--at))) (when p (demo-app--redraw! (plist-get p 'id)))))))

;;; ---------------------------------------------------------- the way in
;; One command, named after the app. It opens in the window you are in:
;; no group of its own, no re-tiling.

(effects! '(write display))
;;;###autoload
(define-command "demo-app" "Open the model app: house plants, a page per plant"
  (lambda ()
    (let ((buf (demo-app--listing)))
      (buffer-create buf)
      (demo-app--claim! buf 'list)
      (with-current-buffer buf (lambda () (set-mode! *demo-app-mode*)))
      (buffer-set-local! buf 'imenu-index-function 'demo-app--list-imenu)
      (app-open! buf)
      (demo-app-show-detail! (list-current buf))
      buf)))

(effects! '(read))
(public! 'demo-app-plants "(demo-app-plants) -- every plant of the model app as a plist: id name room thirst since starred log")
(public! 'demo-app-plant "(demo-app-plant ID) -- the plant ID, or #f")
(effects! '(write))
(public! 'demo-app-water! "(demo-app-water! ID) -- water plant ID now")
(public! 'demo-app-star! "(demo-app-star! ID) -- star plant ID, or take its star away")
(public! 'demo-app-snooze! "(demo-app-snooze! ID) -- put plant ID's next watering off a day")
(effects! '(write display))
(public! 'demo-app-show-detail! "(demo-app-show-detail! PLANT) -- show PLANT's page beside the listing")

(provide 'demo-app)
