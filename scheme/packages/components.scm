;;; components.scm --- a discoverable vocabulary for block-mode views.
;;;
;;; Components are pure: props in, one renderer block out.  State and event
;;; handling remain in the owning mode.  The live catalog is authoritative;
;;; apropos-components is only a convenient filter over the main apropos.

(namespace! 'ui)

(define *components* (if (boundp '*components*) *components* '())) ; ((qualified props example fn) ...)

(define (component--get pl key &optional fallback)
  (let loop ((xs pl))
    (cond ((null? xs) fallback)
          ((null? (cdr xs)) fallback)
          ((equal? (car xs) key) (cadr xs))
          (else (loop (cdr (cdr xs)))))))

(define (component--has? pl key)
  (cond ((null? pl) #f)
        ((null? (cdr pl)) #f)
        ((equal? (car pl) key) #t)
        (else (component--has? (cdr (cdr pl)) key))))

(define (component--qualified name)
  (let ((n (catalog--string name)))
    (if (string-contains? n "/")
        n
        (string-append (catalog--string *loading-namespace*) "/" n))))

(define (component--short qualified)
  (car (reverse (string-split qualified "/"))))

(define (component--namespace qualified)
  (car (string-split qualified "/")))

(define (component--schema-name row) (car row))
(define (component--schema-required? row)
  (and (> (length row) 2) (equal? (nth 2 row) 'required)))

(define (component--validate qualified props schema)
  (let ((missing
          (filter (lambda (row)
                    (and (component--schema-required? row)
                         (not (component--has? props (component--schema-name row)))))
                  schema)))
    (if (null? missing)
        #t
        (list 'error
              (string-append qualified " requires prop "
                             (symbol->string (component--schema-name (car missing))))))))

(define (defcomponent name doc props example fn)
  (let* ((qualified (component--qualified name))
         (short (component--short qualified))
         (ns (component--namespace qualified)))
    (set! *components*
      (cons (list qualified props example fn)
            (remove (lambda (e) (equal? (car e) qualified)) *components*)))
    (catalog-register! 'component short doc
      'qualified-name qualified
      'namespace (string->symbol ns)
      'domain 'ui
      'effects '(pure)
      'props props
      'example example
      'use (string-append "(component '" qualified " PROPS)"))
    qualified))

(define (component-entry name)
  (let ((qualified (component--qualified name)))
    (let loop ((es *components*))
      (cond ((null? es) #f)
            ((equal? (car (car es)) qualified) (car es))
            (else (loop (cdr es)))))))

(define (component name props)
  (let ((e (component-entry name)))
    (if (not e)
        (list 'error (string-append "no component named " (catalog--string name)))
        (let ((valid (component--validate (car e) props (nth 1 e))))
          (if (equal? valid #t)
              (component--imenu-named (component--named (component--anchored ((nth 3 e) props) props) name) (car e) props)
              valid)))))

;; the page source names what drew it: the root block carries component="ui/card"
(define (component--named block name)
  (if (not (and (pair? block) (plist-get block 'tag)))
      block
      (plist-put block 'attrs
                 (cons (list "component" (catalog--string name))
                       (filter (lambda (a) (not (equal? (car a) "component")))
                               (or (plist-get block 'attrs) '()))))))

;; Any component can be a stop of anchor-mode: ANCHOR-NAME names it,
;; ANCHOR-KEYMAP is the keymap in force while point is inside it, and
;; ANCHOR-DATA is what those keys act on. They ride on the block it makes,
;; where anchor-blocks reads them; a component that sets one itself wins.
(define component--anchor-keys '(anchor-name anchor-keymap anchor-data imenu-name imenu-key))

(define (component--anchored block props)
  (if (not (pair? block))
      block
      (let loop ((ks component--anchor-keys) (blk block))
        (cond ((null? ks) blk)
              ((and (component--has? props (car ks)) (not (plist-get blk (car ks))))
               (loop (cdr ks) (append blk (list (car ks) (component--get props (car ks))))))
              (else (loop (cdr ks) blk))))))

(define (describe-component name)
  (let ((e (component-entry name)))
    (if (not e)
        #f
        (let ((c (catalog-entry 'component (car e))))
          (list 'name (car e) 'doc (catalog--get c 'doc)
                'package (catalog--get c 'package)
                'props (nth 1 e) 'example (nth 2 e)
                'effects '("pure"))))))

;; A schema row is (NAME TYPE required|optional [DOC]). DOC says what the
;; prop holds, for whoever writes props without reading the renderer.
(define (component--schema-type row) (if (> (length row) 1) (nth 1 row) 'any))
(define (component--schema-doc row) (if (> (length row) 3) (nth 3 row) #f))

(define (component--type-ok? type v)
  (cond ((equal? type 'string) (string? v))
        ((equal? type 'boolean) (or (eq? v #t) (eq? v #f)))
        ((equal? type 'number) (number? v))
        ((equal? type 'list) (or (null? v) (pair? v)))
        ((equal? type 'symbol) (symbol? v))
        (else #t)))

;; The strict check, for props somebody else wrote: every key declared,
;; every value of its declared type, every required one there. component
;; itself checks only the required ones, so a caller may pass extras.
(define (component-check name props)
  (let ((e (component-entry name)))
    (cond
      ((not e) (list (string-append "no component named " (catalog--string name))))
      ((not (or (null? props) (pair? props))) (list "props must be a list: (KEY VALUE ...)"))
      ((= 1 (modulo (length props) 2)) (list "props must pair every key with a value"))
      (else
       (let ((q (car e)) (schema (nth 1 e)))
         (let loop ((xs props) (out '()))
           (if (null? xs)
               (append (reverse out)
                       (map (lambda (r) (string-append q " requires " (symbol->string (car r))))
                            (filter (lambda (r) (and (component--schema-required? r)
                                                     (not (component--has? props (car r)))))
                                    schema)))
               (let* ((k (car xs))
                      (r (and (symbol? k) (find (lambda (r) (equal? (car r) k)) schema))))
                 (loop (cddr xs)
                       (cond ((not r) (cons (string-append q " has no prop " (value->string k)) out))
                             ((not (component--type-ok? (component--schema-type r) (cadr xs)))
                              (cons (string-append q " prop " (symbol->string k) " must be a "
                                                   (symbol->string (component--schema-type r)))
                                    out))
                             (else out)))))))))))

;; A chat draws only the components that say a reply may name them: their
;; props are data, so no prop may be raw blocks or a click. Their buttons
;; are the actions the component declares, never a command the reply names.
(define *chat-components* (if (boundp '*chat-components*) *chat-components* '()))

(define (component-chat! name)
  (let* ((e (component-entry name))
         (bad (and e (filter (lambda (r) (member (component--schema-type r) '(blocks any))) (nth 1 e)))))
    (cond ((not e) (error (string-append "component-chat!: no component named " (catalog--string name))))
          ((pair? bad) (error (string-append "component-chat!: " (car e) " takes "
                                             (symbol->string (car (car bad))) ", which is not data")))
          (else (unless (member (car e) *chat-components*)
                  (set! *chat-components* (append *chat-components* (list (car e)))))
                (car e)))))

(define (component-chat? name)
  (and (member (component--qualified name) *chat-components*) #t))

(define (chat-components)
  (map (lambda (q) (list q (catalog--get (catalog-entry 'component q) 'doc))) *chat-components*))

;; An action is (NAME LABEL KEY EFFECTS FN); FN gets the props. The first
;; is the default. Effects past read, display and external ask first.
;; A component names its own entry in imenu: its rule takes the props and
;; gives the entry's title, or #f for none. The block carries it as
;; imenu-name, and an imenu-name prop says it outright. anchor-imenu-rows
;; lists every block with a title and lines, the entries in it nested under it.
;; An imenu-key prop is the key that takes the entry, with M-, while imenu is
;; up and nowhere else: typing filters, M- acts.
(define *component-imenu* (if (boundp '*component-imenu*) *component-imenu* '()))

(define (component-imenu! name fn)
  (let ((q (component--qualified name)))
    (set! *component-imenu*
      (cons (list q fn) (remove (lambda (e) (equal? (car e) q)) *component-imenu*)))
    q))

(define (component--imenu-named block qualified props)
  (let ((rule (assoc qualified *component-imenu*)))
    (if (or (not rule) (not (pair? block)) (plist-get block 'imenu-name))
        block
        (let ((title ((cadr rule) props)))
          (if (and (string? title) (not (equal? (string-trim title) "")))
              (append block (list 'imenu-name title))
              block)))))

(define *component-actions* (if (boundp '*component-actions*) *component-actions* '()))

(define (component-actions! name actions)
  (let ((q (component--qualified name)))
    (set! *component-actions*
      (cons (list q actions) (remove (lambda (e) (equal? (car e) q)) *component-actions*)))
    q))

(define (component-actions name)
  (let ((hit (assoc (component--qualified name) *component-actions*)))
    (if hit (cadr hit) '())))

(define (apropos-components query &rest filters)
  (apply apropos (cons query (append (list 'kind 'component) filters))))

;;; --- the starter vocabulary --------------------------------------------------

(defcomponent 'ui/badge
  "A short status chip."
  '((text string required) (class string optional))
  '(text "ready" class "success")
  (lambda (p)
    (list 'tag "c-status"
          'class (string-append "c-badge " (component--get p 'class ""))
          'text (component--get p 'text ""))))

(defcomponent 'ui/empty
  "A quiet notice for a view with no rows or content."
  '((text string optional) (class string optional))
  '(text "nothing to show")
  (lambda (p)
    (list 'tag "c-empty" 'class (string-append "c-empty " (component--get p 'class ""))
          'text (component--get p 'text "nothing to show"))))

(defcomponent 'ui/section
  "A section heading with an optional count."
  '((title string required) (count number optional) (level number optional) (class string optional))
  '(title "Changes" count 3)
  (lambda (p)
    (list 'tag "c-headline" 'class (string-append "c-section " (component--get p 'class ""))
          'attrs (list (list "role" "heading")
                       (list "aria-level" (component--get p 'level 2))
                       (list "level" (component--get p 'level 2)))
          'text (string-append
                  (component--get p 'title "")
                  (if (component--has? p 'count)
                      (string-append " (" (number->string (component--get p 'count 0)) ")")
                      "")))))

(defcomponent 'ui/row
  "A selectable list row made from text or styled segments."
  '((tag string optional) (text string optional) (segs list optional) (click any optional)
    (class string optional) (lines list optional) (mark string optional))
  '(segs (("" "name") ("c-dim" "  detail")))
  (lambda (p)
    (append (list 'tag (component--get p 'tag "c-row")
                  'class (string-append "c-row " (component--get p 'class "")))
            (if (component--has? p 'segs) (list 'segs (component--get p 'segs))
                (list 'text (component--get p 'text "")))
            (if (component--has? p 'click) (list 'click (component--get p 'click)) '())
            (if (component--has? p 'lines) (list 'lines (component--get p 'lines)) '())
            (if (component--has? p 'mark) (list 'mark (component--get p 'mark)) '()))))

(defcomponent 'ui/actions
  "A row of clickable actions with keyboard hints. An action is (CLICK LABEL [KEY [CLASS]]); CLASS marks that one action, a tone such as good or bad."
  '((tag string optional) (actions list required) (class string optional))
  '(actions (("refresh" "Refresh" "g") ("add" "Add" "+") ("delete" "Delete" "d" "bad")))
  (lambda (p)
    (list 'tag (component--get p 'tag "c-toolbar")
          'class (string-append "c-actions " (component--get p 'class ""))
          'children
          (map (lambda (action)
                 (list 'tag "c-action"
                       'class (if (and (> (length action) 3) (nth 3 action)) (string-append "c-action " (nth 3 action)) "c-action")
                       'click (car action)
                       'segs
                       (append
                         (if (> (length action) 2)
                             (list (list "c-action-key" (nth 2 action)))
                             '())
                         (list (list "c-action-label" (cadr action))))))
               (component--get p 'actions '())))))

(defcomponent 'ui/tabs
  "One row of choices over the same view, with the current one marked. A tab is (CLICK LABEL [CURRENT? [KEY]]). As a part of the page the row brings its own keys: a tab's KEY takes it, and the arrows step."
  '((tabs list required) (class string optional))
  '(tabs (("history" "history" #t "1") ("job" "job" #f "2")))
  (lambda (p)
    (list 'tag "c-tabs"
          'class (string-append "c-tabs " (component--get p 'class ""))
          'children
          (map (lambda (tab)
                 (let ((id (car tab))
                       (label (cadr tab))
                       (current? (and (> (length tab) 2) (nth 2 tab)))
                       (key (and (> (length tab) 3) (nth 3 tab))))
                   (list 'tag "c-tab"
                         'class (if current? "c-tab c-tab-on" "c-tab")
                         'click id
                         'attrs (list (list "current" (if current? "true" "false")))
                         'segs (append (if key (list (list "c-tab-key c-action-key" key)) '())
                                       (list (list "c-tab-label c-action-label" label))))))
               (component--get p 'tabs '()))
          ;; in force once the row, or a part that holds it, is named
          'anchor-keymap "tabs-map"
          'anchor-data (list 'tabs (component--get p 'tabs '())))))

;; The keys of a tabs row: the anchor at point names its tabs, and a key
;; clicks one the way the mouse does
(define (tabs--here)
  (let* ((buf (current-buffer))
         (a (anchor-at buf (buffer-point buf)))
         (d (and a (anchor-data a))))
    (or (and (pair? d) (plist-get d 'tabs)) '())))

(define (tabs--take! tab)
  (run-hook-with-args-until-success 'block-click (current-buffer) (car tab)))

(define (tabs--key! key)
  ;; a key no tab of the row wears is the page's own again: the digits of
  ;; an app's tab bars (tab-bars.scm) reach past a row keyed otherwise
  (let loop ((ts (tabs--here)))
    (cond ((null? ts)
           (let* ((mode (buffer-local (current-buffer) 'mode-name))
                  (cmd (and mode (keymap-lookup (mode-keymap mode) key))))
             (if (and (string? cmd) (not (string-prefix? "tabs-key-" cmd)))
                 (run-command cmd)
                 (message (string-append "No tab on " key)))))
          ((and (> (length (car ts)) 3) (equal? (nth 3 (car ts)) key)) (tabs--take! (car ts)))
          (else (loop (cdr ts))))))

(define (tabs--step! d)
  (let* ((ts (tabs--here))
         (n (length ts))
         (i (let loop ((xs ts) (i 0))
              (cond ((null? xs) 0) ((and (> (length (car xs)) 2) (nth 2 (car xs))) i) (else (loop (cdr xs) (+ i 1)))))))
    (if (= n 0)
        (message "No tabs here")
        (tabs--take! (nth (modulo (+ i d n) n) ts)))))

(define-keymap! "tabs-map")
(define-command "tabs-next" "Take the next tab of the row at point" (lambda () (tabs--step! 1)))
(define-command "tabs-prev" "Take the previous tab of the row at point" (lambda () (tabs--step! -1)))
(define-key "tabs-map" "<right>" "tabs-next")
(define-key "tabs-map" "<left>" "tabs-prev")
(for-each (lambda (n)
            (let ((key (number->string n))
                  (command (string-append "tabs-key-" (number->string n))))
              (define-command command (string-append "Take the tab of the row at point keyed " key)
                (lambda () (tabs--key! key)))
              (define-key "tabs-map" key command)))
          '(1 2 3 4 5 6 7 8 9))

(defcomponent 'ui/fold-head
  "A clickable heading with a disclosure caret. ICON (an image url) or LETTER (a tile) leads the title; BADGE follows it, coloured by BADGE-CLASS, then the TAGS."
  '((title string required) (open? boolean required) (click any optional)
    (badge string optional) (badge-class string optional) (icon string optional)
    (letter string optional) (tags list optional))
  '(title "SteelEye" open? #t click "details" badge "B" badge-class "info" letter "S" tags ("Fintech" "Big co"))
  (lambda (p)
    (let ((caret (if (component--get p 'open? #f) "▾" "▸"))
          (rich? (or (component--has? p 'icon) (component--has? p 'letter) (component--has? p 'tags)
                     (component--has? p 'badge-class))))
      (append
        (list 'tag "c-headline" 'class "c-fold-head"
              'attrs (list (list "folded" (if (component--get p 'open? #f) "false" "true"))))
        (if rich?
            ;; a face of its own: drawn as parts, since a seg is text and a logo is not
            (list 'children
                  (append
                    (list (list 'tag "span" 'class "c-caret" 'text caret))
                    (cond ((component--has? p 'icon)
                           (list (list 'tag "img" 'class "c-fold-icon"
                                       'attrs (list (list "src" (component--get p 'icon)) (list "alt" "")
                                                    (list "referrerpolicy" "no-referrer")))))
                          ((component--has? p 'letter)
                           (list (list 'tag "span" 'class "c-fold-letter" 'text (component--get p 'letter))))
                          (else '()))
                    (list (list 'tag "span" 'class "c-fold-title" 'text (component--get p 'title "")))
                    (if (component--has? p 'badge)
                        (list (list 'tag "span" 'class (string-append "c-badge c-fold-grade " (component--get p 'badge-class ""))
                                    'text (component--get p 'badge)))
                        '())
                    (map (lambda (t) (list 'tag "span" 'class "c-fold-tag" 'text t))
                         (component--get p 'tags '()))))
            (list 'segs (append
                          (list (list "c-caret" caret)
                                (list "c-fold-title" (component--get p 'title "")))
                          (if (component--has? p 'badge)
                              (list (list "c-fold-badge" (component--get p 'badge))) '()))))
        (if (component--has? p 'click) (list 'click (component--get p 'click)) '())))))

(defcomponent 'ui/card
  "A bordered container with an optional heading and body. A titled card is a fold: its anchor-data carries (fold (TITLE OPEN?)). BADGE, BADGE-CLASS, ICON, LETTER and TAGS dress the heading as ui/fold-head does."
  '((tag string optional) (title string optional) (open? boolean optional) (click any optional)
    (badge string optional) (badge-class string optional) (icon string optional)
    (letter string optional) (tags list optional)
    (body blocks optional) (class string optional)
    (lines list optional) (mark string optional)
    (anchor-name string optional) (anchor-keymap string optional) (anchor-data list optional))
  '(title "A card" open? #t body ((tag "div" text "hello")))
  (lambda (p)
    (append
      (list 'tag (component--get p 'tag "c-card")
            'class (string-append "c-card " (component--get p 'class ""))
            'children
            (append
              (if (component--has? p 'title)
                  (list (component 'ui/fold-head
                          (append (list 'title (component--get p 'title)
                                        'open? (component--get p 'open? #t))
                                  (if (component--has? p 'click)
                                      (list 'click (component--get p 'click)) '())
                                  ;; the head's face: badge, logo or letter, tags
                                  (apply append
                                         (map (lambda (k) (if (component--has? p k) (list k (component--get p k)) '()))
                                              '(badge badge-class icon letter tags))))))
                  '())
              (if (component--get p 'open? #t) (component--get p 'body '()) '())))
      (if (component--has? p 'lines) (list 'lines (component--get p 'lines)) '())
      (if (component--has? p 'mark) (list 'mark (component--get p 'mark)) '())
      ;; the fold is the card's own: f on it folds and unfolds by its title
      (if (component--has? p 'title)
          (list 'anchor-data (append (list 'fold (list (component--get p 'title) (component--get p 'open? #t)))
                                     (component--get p 'anchor-data '())))
          '()))))

(defcomponent 'ui/kv
  "Key/value pairs for compact detail and audit views."
  '((pairs list required))
  '(pairs (("package" "components") ("effect" "pure")))
  (lambda (p)
    (list 'tag "c-properties" 'class "c-kv"
          'children
          (map (lambda (pair)
                 (list 'tag "c-field" 'class "c-kv-row"
                       'attrs (list (list "name" (car pair)))
                       'children (list
                         (list 'tag "c-label" 'class "c-kv-key" 'text (car pair))
                         (list 'tag "c-value" 'class "c-kv-value" 'text (cadr pair)))))
               (component--get p 'pairs '())))))

;;; --- living gallery ----------------------------------------------------------

(defcomponent 'ui/table
  "A small table: column titles over rows of cells. A column is (TITLE) or (TITLE right); a cell is text, or (TEXT CLASS) to colour it."
  '((columns list required) (rows list required) (class string optional))
  '(columns (("workflow") ("runs" right) ("state")) rows (("triage" "12" ("ok" "good")) ("todos" "9" ("failing" "bad"))))
  (lambda (p)
    (let* ((cols (component--get p 'columns '()))
           (align (lambda (col) (if (member 'right col) " c-num" "")))
           (cell (lambda (col c)
                   (let ((text (if (pair? c) (car c) c))
                         (class (if (and (pair? c) (pair? (cdr c))) (string-append " " (cadr c)) "")))
                     (list 'tag "c-td" 'class (string-append "c-td" (align col) class) 'text (or text ""))))))
      (list 'tag "c-table" 'class (string-append "c-table " (component--get p 'class ""))
            'children
            (cons (list 'tag "c-tr" 'class "c-tr c-thead"
                        'children (map (lambda (col) (list 'tag "c-th" 'class (string-append "c-th" (align col))
                                                           'text (car col)))
                                       cols))
                  (map (lambda (row)
                         (list 'tag "c-tr" 'class "c-tr"
                               'children (let loop ((cs cols) (xs row) (out '()))
                                           (if (or (null? cs) (null? xs)) (reverse out)
                                               (loop (cdr cs) (cdr xs) (cons (cell (car cs) (car xs)) out))))))
                       (component--get p 'rows '())))))))

(defcomponent 'ui/stat
  "One number with its label and a line under it. CLASS good, warn or bad colours the number."
  '((label string required) (value string required) (sub string optional) (class string optional))
  '(label "model p50" value "154ms" sub "p95 256ms" class "good")
  (lambda (p)
    (list 'tag "c-stat" 'class (string-append "c-stat " (component--get p 'class ""))
          'children (append (list (list 'tag "c-label" 'class "c-stat-label" 'text (component--get p 'label ""))
                                  (list 'tag "c-value" 'class "c-stat-value" 'text (component--get p 'value "")))
                            (if (component--has? p 'sub)
                                (list (list 'tag "c-text" 'class "c-stat-sub" 'text (component--get p 'sub)))
                                '())))))

(defcomponent 'ui/stats
  "A row of ui/stat tiles that wraps on a narrow window. STATS is a list of ui/stat props."
  '((stats list required) (class string optional))
  '(stats ((label "calls" value "398") (label "p50" value "154ms" class "good")))
  (lambda (p)
    (list 'tag "c-stats" 'class (string-append "c-stats " (component--get p 'class ""))
          'children (map (lambda (s) (component 'ui/stat s)) (component--get p 'stats '())))))

(defcomponent 'ui/keys-bar
  "The keymap a list-mode buffer carries: a card at the window's bottom corner with the main keys and `? all N`; expanded, the whole map as a grid per keymap."
  '((main list required) (grids list optional) (expanded boolean optional))
  '(main (("RET" "visit") ("SPC" "mark") ("q" "quit"))
    grids (("dired" (("RET" "dired-find-file") ("m" "dired-mark")))))
  (lambda (p)
    (let* ((expanded (component--get p 'expanded #f))
           (grids (component--get p 'grids '()))
           (n (apply + (map (lambda (g) (length (cadr g))) grids))))
      (list 'tag "c-keys-bar"
            'class (string-append "c-keys-bar" (if expanded " expanded" ""))
            'children
            (append
              (list (list 'tag "div" 'class "keys-line"
                          'children
                          (list (component 'ui/keymap
                                  (list 'keys (component--get p 'main '())
                                        'tag "div" 'class "keys-main"))
                                ;; a div: a span block draws no click
                                (list 'tag "div" 'class "keys-more"
                                      'click "list-keys-toggle"
                                      'attrs (list (list "title" (if expanded "fewer keys" "every key")))
                                      'segs (list (list "c-keymap-key c-action-key" "?" "c-action-key")
                                                  (list "keys-more-word"
                                                        (cond (expanded "fewer")
                                                              ((> n 0) (string-append "all " (number->string n)))
                                                              (else "more"))))))))
              (if expanded
                  (map (lambda (g)
                         (list 'tag "c-keys" 'class "c-keys"
                               'children
                               (cons (list 'tag "c-keys-head" 'class "c-keys-head"
                                           'segs (list (list "name" (car g))
                                                       (list "count" (number->string (length (cadr g))))))
                                     (map (lambda (r)
                                            (list 'tag "c-binding" 'class "c-binding"
                                                  'segs (list (list "c-keymap-key c-action-key" (car r) "c-action-key")
                                                              (list "do" (cadr r)))))
                                          (cadr g)))))
                       grids)
                  '()))))))

(defcomponent 'ui/keymap
  "The keys in force and what each one does."
  '((keys list required) (tag string optional) (class string optional))
  '(keys (("g" "revert-buffer") ("q" "quit-window" "Close the window")))
  (lambda (p)
    (list 'tag (component--get p 'tag "c-key-hints")
          'class (string-append "c-keymap " (component--get p 'class ""))
          'children
          (map (lambda (k)
                 (list 'tag "c-row" 'class "c-keymap-row"
                       'segs
                       (append
                         (list (list "c-keymap-key c-action-key" (car k) "c-action-key")
                               (list "c-keymap-cmd" (cadr k)))
                         (if (> (length k) 2)
                             (list (list "c-keymap-doc" (nth 2 k)))
                             '()))))
               (component--get p 'keys '())))))

(defcomponent 'ui/group
  "A labelled grouping of related blocks."
  '((title string optional) (body blocks optional) (tag string optional) (class string optional))
  '(title "Motion" body ((tag "c-text" text "n and p move by one row.")))
  (lambda (p)
    (list 'tag (component--get p 'tag "c-group")
          'class (string-append "c-group " (component--get p 'class ""))
          'attrs (if (component--has? p 'title)
                     (list (list "label" (component--get p 'title "")))
                     '())
          'children
          (append
            (if (component--has? p 'title)
                (list (component 'ui/section
                        (list 'title (component--get p 'title "") 'level 3)))
                '())
            (component--get p 'body '())))))

;; Reading views: a page of prose, not rows. Each takes TEXT or SEGS, where a
;; seg's class may be c-strong, c-dim, c-sep or a tone: c-good, c-warn,
;; c-bad, c-info.
(define (component--content p)
  (if (component--has? p 'segs) (list 'segs (component--get p 'segs))
      (list 'text (component--get p 'text ""))))

(define (component--click p)
  (if (component--has? p 'click) (list 'click (component--get p 'click)) '()))

(defcomponent 'ui/page
  "A page of reading: its blocks in a padded column of comfortable width."
  '((body blocks optional))
  '(body ((tag "c-group" class "c-prose" text "A paragraph.")))
  (lambda (p) (list 'tag "c-group" 'class "c-page" 'children (component--get p 'body '()))))

(defcomponent 'ui/title
  "A page title in large serif type, with an optional status badge beside it. LEVEL 2 is a smaller one."
  '((text string optional) (segs list optional) (badge string optional) (tone string optional)
    (level number optional) (click any optional))
  '(text "Backend Engineer at Thine" badge "new" tone "info")
  (lambda (p)
    (append
      (list 'tag "c-group"
            'class (string-append "c-title c-title-" (number->string (component--get p 'level 1)))
            'children (append (list (append (list 'tag "c-text" 'class "c-title-text") (component--content p)))
                              (if (component--has? p 'badge)
                                  (list (component 'ui/badge (list 'text (component--get p 'badge)
                                                                   'class (component--get p 'tone ""))))
                                  '())))
      (component--click p))))

(defcomponent 'ui/person-head
  "The head of a person's page: their photo round to the left of the lines it heads. TITLE, when there is one, is a line above the name, with BADGE in TONE beside it and TITLE-CLICK on it; then the name in large serif type. AFTER is segs drawn small after the name; BELOW is segs on a quiet line under it, such as their stars; CLICK opens their page."
  '((name string required) (avatar string optional) (after list optional) (below list optional) (click any optional)
    (title string optional) (badge string optional) (tone string optional) (title-click any optional))
  '(name "Kunal Roy Choudhury" avatar "https://github.com/octocat.png" title "Backend Engineer at Thine" badge "accepted → applied" tone "info")
  (lambda (p)
    (let* ((src (component--get p 'avatar ""))
           (top (if (equal? (component--get p 'title "") "")
                    '()
                    (list (component 'ui/title (append (list 'text (component--get p 'title))
                                                       (if (component--has? p 'badge) (list 'badge (component--get p 'badge) 'tone (component--get p 'tone "")) '())
                                                       (if (component--has? p 'title-click) (list 'click (component--get p 'title-click)) '()))))))
           (name (component 'ui/title (append (list 'level 1
                                                    'segs (cons (list "" (component--get p 'name ""))
                                                                (component--get p 'after '())))
                                              (if (component--has? p 'click) (list 'click (component--get p 'click)) '()))))
           (below (if (null? (component--get p 'below '())) '() (list (component 'ui/meta (list 'segs (component--get p 'below))))))
           (lines (list 'tag "div" 'class "c-person-lines" 'children (append top (list name) below))))
      (if (equal? src "")
          lines
          (list 'tag "div" 'class "c-person-head"
                'children (list (list 'tag "img" 'class "c-person-avatar"
                                      'attrs (list (list "src" src) (list "alt" "") (list "referrerpolicy" "no-referrer")))
                                lines))))))

(defcomponent 'ui/meta
  "A quiet line of facts under a title: dim, small, its items apart by dots."
  '((segs list required))
  '(segs (("" "applied") ("c-sep" " · ") ("c-warn" "potential") ("c-sep" " · ") ("" "2 days ago")))
  (lambda (p) (list 'tag "c-group" 'class "c-meta" 'segs (component--get p 'segs))))

(defcomponent 'ui/prose
  "A paragraph of reading text."
  '((text string optional) (segs list optional) (click any optional))
  '(segs (("c-strong" "Verdict ") ("" "clears the bar.")))
  (lambda (p) (append (list 'tag "c-group" 'class "c-prose") (component--content p) (component--click p))))

(defcomponent 'ui/bullet
  "One bulleted line of reading text; the bullet hangs, the text wraps under itself."
  '((text string optional) (segs list optional) (click any optional))
  '(text "No Kubernetes evidence on the CV")
  (lambda (p) (append (list 'tag "c-group" 'class "c-bullet") (component--content p) (component--click p))))

(defcomponent 'ui/callout
  "A box set apart from the page, with a small label: TONE note for an aside, paper for a letter."
  '((label string optional) (tone string optional) (body blocks optional) (tag string optional))
  '(label "Internal note" tone "note" body ((tag "c-group" class "c-prose" text "Not sent.")))
  (lambda (p)
    (list 'tag (component--get p 'tag "c-group")
          'class (string-append "c-callout c-callout-" (component--get p 'tone "note"))
          'children (append (if (component--has? p 'label)
                                (list (list 'tag "c-group" 'class "c-callout-label" 'text (component--get p 'label)))
                                '())
                            (component--get p 'body '())))))

(defcomponent 'ui/quote
  "Quoted text that keeps its own line breaks."
  '((text string required))
  '(text "first line\nsecond line")
  (lambda (p) (list 'tag "c-group" 'class "c-quote" 'text (component--get p 'text))))

(defcomponent 'ui/chips
  "A wrapping row of short tags."
  '((items list required))
  '(items ("backend" "fullstack" "startup"))
  (lambda (p)
    (list 'tag "c-group" 'class "c-chips"
          'children (map (lambda (t) (component 'ui/badge (list 'text t))) (component--get p 'items)))))

;; each one's imenu entry: a heading, group or card by its title, a callout by
;; its label, a person's head by who they are and their role
(for-each (lambda (r) (component-imenu! (car r) (cadr r)))
  (list (list 'ui/section (lambda (p) (component--get p 'title #f)))
        (list 'ui/group (lambda (p) (component--get p 'title #f)))
        (list 'ui/card (lambda (p) (component--get p 'title #f)))
        (list 'ui/callout (lambda (p) (component--get p 'label #f)))
        (list 'ui/person-head
              (lambda (p) (let ((title (component--get p 'title "")))
                            (string-append (component--get p 'name "")
                                           (if (equal? title "") "" (string-append " · " title))))))))

;; the ones whose props are plain data, so a chat reply may draw them
(for-each component-chat! '(ui/badge ui/kv ui/table ui/stat ui/stats ui/quote ui/chips))

(define *component-gallery-buffer* "*Components*")

(define (component-gallery-blocks)
  (fold (lambda (acc e)
          (let ((qualified (car e)) (example (nth 2 e)))
            (append acc
              (list (component 'ui/section (list 'title qualified))
                    (component 'ui/card
                      (list 'open? #t
                            'body (list
                                    (component qualified example)
                                    (component 'ui/kv
                                      (list 'pairs
                                        (list (list "props" (value->string (nth 1 e)))
                                              (list "example" (value->string example))))))))))))
        '() (reverse *components*)))

(mode-icon! "component-gallery-mode" "")

(define-mode "component-gallery-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-read-only! buf #t)
      (buffer-set-local! buf 'render-mode "blocks")
      (buffer-set-local! buf 'render-blocks (component-gallery-blocks)))))
(mode-keys! "component-gallery-mode" '(("q" "quit-window")))

(mode-doc! "component-gallery-mode"
  "Every registered block-mode UI component, rendered from its declared example.")

(define-command "component-gallery" "Show every registered UI component and its props"
  (lambda ()
    (buffer-create *component-gallery-buffer*)
    (switch-to-buffer! *component-gallery-buffer*)
    (buffer-set-read-only! *component-gallery-buffer* #f)
    (buffer-delete-range! *component-gallery-buffer* 0 (buffer-size *component-gallery-buffer*))
    (buffer-append! *component-gallery-buffer* "UI component gallery\n")
    (set-mode! "component-gallery-mode")))

(define-command "apropos-components" "Search UI components by words"
  (lambda ()
    (minibuffer-read "Components (words): " (history-items 'apropos-components)
      (lambda (query)
        (history-push! 'apropos-components query)
        (apropos-page query (list 'kind 'component))))))

;;; --- click routing -----------------------------------------------------------
;;; The primitive (block-on-click!) holds ONE handler for the whole editor.
;;; This registry fans it out: each blocks mode registers a named handler,
;;; and a handler returns #t when the click was its own.  Registration by
;;; name replaces the old handler, so a package reload does not stack
;;; duplicates.

(block-on-click!
  (lambda (buf id)
    (if (run-hook-with-args-until-success 'block-click buf id) #t #f)))

(define-style! 'components "
.c-section { font-family: var(--font-mono); font-size: .85em; font-weight: 600; letter-spacing: .08em; text-transform: uppercase; color: var(--dim-fg); padding: 12px 2px 6px; border-bottom: 1px solid var(--border-bg); }
.c-card { margin: 0 0 10px; border: 1px solid var(--border-bg); border-radius: 0; overflow: hidden; }
.c-card > :not(.c-fold-head) { margin-left: 10px; margin-right: 10px; }
.c-fold-head { display: flex; gap: 8px; padding: 6px 10px; background: var(--hl-line-bg); cursor: pointer; font-family: var(--font-mono); }
.c-fold-head > .c-caret, .c-fold-head > .c-fold-title, .c-fold-head > .c-badge, .c-fold-head > .c-fold-tag, .c-fold-head > .c-fold-letter { align-self: center; }
.c-fold-head > .c-fold-title { font-weight: 600; }
.c-fold-icon { width: 18px; height: 18px; flex: none; align-self: center; object-fit: contain; border-radius: 2px; background: var(--default-bg); }
.c-fold-letter { width: 18px; height: 18px; flex: none; display: inline-grid; place-items: center; border-radius: 2px; background: var(--accent-fg); color: var(--default-bg); font-size: 10px; font-weight: 700; }
/* on the head's tinted ground a badge needs its own: paper, a rule, ink */
.c-fold-head > .c-fold-grade { font-family: var(--font-mono); font-size: .8em; font-weight: 700; line-height: 1.5; letter-spacing: .04em; padding: 0 6px; color: var(--default-fg); background: var(--default-bg); border: 1px solid var(--dim-fg); }
.c-fold-head > .c-fold-grade.good { color: var(--ok-fg); border-color: var(--ok-fg); }
.c-fold-head > .c-fold-grade.info { color: var(--accent-fg); border-color: var(--accent-fg); }
.c-fold-tag { font-size: .8em; line-height: 1.5; color: var(--default-fg); background: var(--default-bg); border: 1px solid var(--border-bg); padding: 0 6px; }
.c-caret, .c-dim, .c-kv-key { color: var(--dim-fg); }
.c-row { padding: 4px 10px; font-family: var(--font-mono); }
.c-row.current { background: var(--hl-line-bg); }
.c-actions { display: flex; flex-wrap: wrap; gap: 6px; padding: 4px 0 12px; }
.c-tabs { display: flex; flex-wrap: wrap; gap: 4px; padding: 6px 0 0; margin: 0 0 10px; border-bottom: 1px solid var(--border-bg); }
.c-tab { display: inline-flex; gap: 6px; align-items: center; padding: 3px 10px; border: 1px solid transparent; border-bottom: none; border-radius: 0; cursor: pointer; font-family: var(--font-mono); font-size: .85em; color: var(--dim-fg); }
.c-tab:hover { background: var(--hl-line-bg); color: var(--fg); }
.c-tab-on { color: var(--fg); border-color: var(--border-bg); background: var(--hl-line-bg); }
.c-tab-key { color: var(--accent-fg); font-weight: 600; }
.c-tab-pick { color: var(--fg); outline: 1px solid var(--accent-fg); outline-offset: -1px; }
.c-action { display: inline-flex; gap: 6px; align-items: center; padding: 4px 8px; border: 1px solid var(--border-bg); border-radius: 0; cursor: pointer; font-family: var(--font-mono); font-size: .85em; }
.c-action:hover { background: var(--hl-line-bg); border-color: var(--dim-fg); }
.c-action-key { color: var(--accent-fg); font-weight: 600; }
.c-action-label { color: var(--fg); }
.c-empty { padding: 12px; color: var(--dim-fg); font-family: var(--font-mono); }
.c-badge { display: inline-block; border-radius: 0; padding: 1px 7px; background: var(--hl-line-bg); font-size: .77em; }
.c-kv { padding: 7px 10px; font-family: var(--font-mono); font-size: .85em; }
.c-kv-row { display: grid; grid-template-columns: minmax(8ch, .35fr) 1fr; gap: 10px; }
.c-group { display: block; margin: 0 0 10px; }
c-header.c-group { padding: 10px 14px; }
.c-table { display: table; width: 100%; border-collapse: collapse; font-family: var(--font-mono); font-size: .85em; }
.c-tr { display: table-row; }
.c-th, .c-td { display: table-cell; padding: 3px 10px; white-space: nowrap; border-bottom: 1px solid var(--border-bg); }
.c-th { color: var(--dim-fg); font-weight: 600; text-transform: uppercase; letter-spacing: .06em; font-size: .77em; }
.c-num { text-align: right; font-variant-numeric: tabular-nums; }
.c-td.good, .c-stat.good .c-stat-value { color: var(--success-fg, #2e8b57); }
.c-td.warn, .c-stat.warn .c-stat-value { color: var(--warning-fg, #b8860b); }
.c-td.bad, .c-stat.bad .c-stat-value { color: var(--alert-fg, #d13b32); font-weight: 600; }
.c-stats { display: flex; flex-wrap: wrap; gap: 8px; padding: 8px 0; }
.c-stat { display: flex; flex-direction: column; min-width: 11ch; padding: 6px 10px; border: 1px solid var(--border-bg); font-family: var(--font-mono); }
.c-stat-label { color: var(--dim-fg); font-size: .77em; text-transform: uppercase; letter-spacing: .06em; }
.c-stat-value { font-size: 1.4em; font-weight: 600; font-variant-numeric: tabular-nums; }
.c-stat-sub { color: var(--dim-fg); font-size: .77em; }
.c-keymap { display: flex; flex-wrap: wrap; gap: var(--s4) var(--s9); padding: 5px 12px; font-family: var(--font-mono); font-size: var(--fs-meta); line-height: 1.35; white-space: normal; color: var(--text-faint); }
.c-keymap-row { display: inline-flex; align-items: baseline; gap: var(--s4); min-width: 0; max-width: 100%; white-space: nowrap; }
/* the key is a c-action-key (layouts.ex): one element, one colour */
.c-keymap-key { display: inline-block; flex: none; font-size: var(--fs-meta); line-height: 1.2; }
.c-keymap-cmd { color: var(--text-faint); }
.c-keymap-doc { color: var(--text-dim); }
/* reading views: sizes in em, so a buffer's text scale carries them */
.c-page { padding: 10px 14px 32px; max-width: 88ch; font-family: var(--font-sans); line-height: 1.55; color: var(--default-fg); }
.c-page .c-table { font-family: var(--font-sans); font-size: .95em; margin: .3em 0 .9em; }
.c-page .c-th, .c-page .c-td { white-space: normal; padding: .45em .8em; vertical-align: top; }
.c-page .c-th { font-size: .75em; }
.c-title { display: flex; align-items: baseline; flex-wrap: wrap; gap: .6em; margin: .3em 0 .15em; }
.c-title-text { font-family: var(--font-serif, ui-serif, Georgia, serif); font-weight: 700; line-height: 1.2; color: var(--default-fg); }
.c-title-1 .c-title-text { font-size: 1.7em; }
.c-title-2 .c-title-text { font-size: 1.1em; }
.c-person-head { display: flex; gap: 14px; align-items: center; margin: .2em 0 .3em; }
.c-person-lines { display: flex; flex-direction: column; gap: .15em; min-width: 0; }
.c-person-lines > .c-title, .c-person-lines > .c-meta { margin: 0; }
.c-person-avatar { width: 64px; height: 64px; flex: none; border-radius: 50%; object-fit: cover; background: var(--hl-line-bg); }
.c-meta { font-family: var(--font-sans); font-size: .88em; line-height: 1.5; color: var(--dim-fg); margin: .15em 0 .5em; }
.c-prose { font-family: var(--font-sans); line-height: 1.6; margin: .15em 0 .7em; max-width: 75ch; }
.c-bullet { font-family: var(--font-sans); line-height: 1.6; margin: 0 0 .25em; padding-left: 1.3em; text-indent: -1.3em; max-width: 80ch; }
.c-bullet::before { content: '•'; display: inline-block; width: 1.3em; text-indent: 0; color: var(--accent-fg); }
.c-prose.current, .c-bullet.current, .c-meta.current, .c-title.current { background: var(--hl-line-bg); }
.c-callout { margin: .6em 0 1em; padding: .9em 1.2em; border-left: 3px solid var(--border-bg); background: var(--hl-line-bg); }
.c-callout-label { font-family: var(--font-mono); font-size: .77em; font-weight: 600; letter-spacing: .08em; text-transform: uppercase; color: var(--dim-fg); margin-bottom: .5em; }
.c-callout-note { background: color-mix(in srgb, var(--warn-fg) 9%, transparent); border-left-color: var(--warn-fg); }
.c-callout-note .c-callout-label { color: var(--warn-fg); }
.c-callout-paper { border: 1px solid var(--border-bg); font-family: var(--font-serif, ui-serif, Georgia, serif); font-size: 1.08em; padding: 1.3em 1.6em; }
.c-callout-paper .c-prose, .c-callout-paper .c-bullet { font-family: inherit; max-width: none; }
.c-quote { border-left: 2px solid var(--accent-fg); padding: .15em .8em; margin: .3em 0 .7em; white-space: pre-wrap; line-height: 1.55; }
.c-chips { display: flex; flex-wrap: wrap; gap: 4px; margin: .3em 0 .5em; }
.c-strong { font-weight: 700; color: var(--default-fg); }
.c-sep { color: var(--border-bg); }
.c-good { color: var(--ok-fg); font-weight: 600; }
.c-warn { color: var(--warn-fg); font-weight: 600; }
.c-bad { color: var(--alert-fg); font-weight: 600; }
.c-info { color: var(--accent-fg); font-weight: 600; }
.c-badge.good { color: var(--ok-fg); background: color-mix(in srgb, var(--ok-fg) 16%, transparent); }
.c-badge.warn { color: var(--warn-fg); background: color-mix(in srgb, var(--warn-fg) 16%, transparent); }
.c-badge.bad { color: var(--alert-fg); background: color-mix(in srgb, var(--alert-fg) 16%, transparent); }
.c-badge.info { color: var(--accent-fg); background: color-mix(in srgb, var(--accent-fg) 16%, transparent); }
.c-action.good { color: var(--ok-fg); border-color: var(--ok-fg); background: color-mix(in srgb, var(--ok-fg) 12%, transparent); }
.c-action.bad { color: var(--alert-fg); border-color: var(--alert-fg); }
.c-action.dim { color: var(--dim-fg); border-style: dashed; }
.c-action.good .c-action-label, .c-action.bad .c-action-label, .c-action.dim .c-action-label { color: inherit; }

")

(category! 'ui)
(domain! 'ui)
(effects! '(write))
(public! 'defcomponent "(defcomponent NAME DOC PROPS EXAMPLE FN) — register a pure block-mode UI component")
(effects! '(pure))
(public! 'component "(component NAME PROPS) — instantiate a registered UI component")
(effects! '(read))
(public! 'describe-component "(describe-component NAME) — a component's props, example and owner, or #f")
(public! 'component-check "(component-check NAME PROPS) — what is wrong with PROPS for NAME, as sentences; () when they fit")
(public! 'component-chat? "(component-chat? NAME) — #t when a chat reply may draw NAME")
(public! 'chat-components "(chat-components) — the components a chat reply may draw, as (NAME DOC)")
(public! 'component-actions "(component-actions NAME) — NAME's actions as (NAME LABEL KEY EFFECTS FN), the default first")
(effects! '(write))
(public! 'component-chat! "(component-chat! NAME) — let a chat reply draw NAME; its props must all be data")
(public! 'component-actions! "(component-actions! NAME ACTIONS) — declare NAME's actions, each (NAME LABEL KEY EFFECTS FN), the default first")
(public! 'component-imenu! "(component-imenu! NAME FN) — NAME's imenu entry: FN takes the props and gives the entry's title, or #f for none")
(effects! '(read))
(effects! '(read external spend))
(public! 'apropos-components "(apropos-components QUERY [FILTERS...]) — the main apropos filtered to UI components")

(domain! 'ui)
(effects! '(write display))

;; Semantic lists use stable row keys, never a stale DOM row number.
(add-hook! (list 'block-click 'semantic-list)
  (lambda (buf id)
    (if (and (list-opt buf 'composml) (string-prefix? "list:" id))
        (let ((i (list-index-of buf (list-entries buf) (substring id 5 (string-length id)))))
          (when i
            (list-goto-index! buf i)
            (let ((click (list-opt buf 'on-click)))
              (when click (click buf (nth i (list-entries buf))))))
          #t)
        #f)))

;; The dashboard is core chrome, and core loads before this registry exists.
;; Its handler is defined there and registered here.
;; By name, in a lambda: a hot reload of editor.scm redefines the handler,
;; and a registration by value would keep calling the old one.
(when (boundp 'dashboard-block-click)
  (add-hook! (list 'block-click 'dashboard) (lambda (buf id) (dashboard-block-click buf id))))
