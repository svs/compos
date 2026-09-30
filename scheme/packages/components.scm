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
          (if (equal? valid #t) ((nth 3 e) props) valid)))))

(define (describe-component name)
  (let ((e (component-entry name)))
    (if (not e)
        #f
        (let ((c (catalog-entry 'component (car e))))
          (list 'name (car e) 'doc (catalog--get c 'doc)
                'package (catalog--get c 'package)
                'props (nth 1 e) 'example (nth 2 e)
                'effects '("pure"))))))

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
  "A row of clickable actions with optional keyboard hints."
  '((tag string optional) (actions list required) (class string optional))
  '(actions (("refresh" "Refresh" "g") ("add" "Add" "+")))
  (lambda (p)
    (list 'tag (component--get p 'tag "c-toolbar")
          'class (string-append "c-actions " (component--get p 'class ""))
          'children
          (map (lambda (action)
                 (list 'tag "c-action" 'class "c-action" 'click (car action)
                       'segs
                       (append
                         (if (> (length action) 2)
                             (list (list "c-action-key" (nth 2 action)))
                             '())
                         (list (list "c-action-label" (cadr action))))))
               (component--get p 'actions '())))))

(defcomponent 'ui/tabs
  "One row of choices over the same view, with the current one marked."
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
               (component--get p 'tabs '())))))

(defcomponent 'ui/fold-head
  "A clickable heading with a disclosure caret."
  '((title string required) (open? boolean required) (click any optional)
    (badge string optional))
  '(title "Details" open? #t click "details")
  (lambda (p)
    (append
      (list 'tag "c-headline" 'class "c-fold-head"
            'attrs (list (list "folded" (if (component--get p 'open? #f) "false" "true")))
            'segs (append
                    (list (list "c-caret" (if (component--get p 'open? #f) "▾" "▸"))
                          (list "c-fold-title" (component--get p 'title "")))
                    (if (component--has? p 'badge)
                        (list (list "c-fold-badge" (component--get p 'badge))) '())))
      (if (component--has? p 'click) (list 'click (component--get p 'click)) '()))))

(defcomponent 'ui/card
  "A bordered container with an optional heading and body."
  '((tag string optional) (title string optional) (open? boolean optional) (click any optional)
    (badge string optional) (body blocks optional) (class string optional)
    (lines list optional) (mark string optional))
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
                                  (if (component--has? p 'badge)
                                      (list 'badge (component--get p 'badge)) '()))))
                  '())
              (if (component--get p 'open? #t) (component--get p 'body '()) '())))
      (if (component--has? p 'lines) (list 'lines (component--get p 'lines)) '())
      (if (component--has? p 'mark) (list 'mark (component--get p 'mark)) '()))))

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
.c-section { font-family: var(--font-mono); font-size: 11px; font-weight: 600; letter-spacing: .08em; text-transform: uppercase; color: var(--dim-fg); padding: 12px 2px 6px; border-bottom: 1px solid var(--border-bg); }
.c-card { margin: 0 0 10px; border: 1px solid var(--border-bg); border-radius: 0; overflow: hidden; }
.c-fold-head { display: flex; gap: 8px; padding: 6px 10px; background: var(--hl-line-bg); cursor: pointer; font-family: var(--font-mono); }
.c-caret, .c-dim, .c-kv-key { color: var(--dim-fg); }
.c-row { padding: 4px 10px; font-family: var(--font-mono); }
.c-row.current { background: var(--hl-line-bg); }
.c-actions { display: flex; flex-wrap: wrap; gap: 6px; padding: 4px 0 12px; }
.c-tabs { display: flex; flex-wrap: wrap; gap: 4px; padding: 6px 0 0; margin: 0 0 10px; border-bottom: 1px solid var(--border-bg); }
.c-tab { display: inline-flex; gap: 6px; align-items: center; padding: 3px 10px; border: 1px solid transparent; border-bottom: none; border-radius: 0; cursor: pointer; font-family: var(--font-mono); font-size: 11px; color: var(--dim-fg); }
.c-tab:hover { background: var(--hl-line-bg); color: var(--fg); }
.c-tab-on { color: var(--fg); border-color: var(--border-bg); background: var(--hl-line-bg); }
.c-tab-key { color: var(--accent-fg); font-weight: 600; }
.c-action { display: inline-flex; gap: 6px; align-items: center; padding: 4px 8px; border: 1px solid var(--border-bg); border-radius: 0; cursor: pointer; font-family: var(--font-mono); font-size: 11px; }
.c-action:hover { background: var(--hl-line-bg); border-color: var(--dim-fg); }
.c-action-key { color: var(--accent-fg); font-weight: 600; }
.c-action-label { color: var(--fg); }
.c-empty { padding: 12px; color: var(--dim-fg); font-family: var(--font-mono); }
.c-badge { display: inline-block; border-radius: 0; padding: 1px 7px; background: var(--hl-line-bg); font-size: 10px; }
.c-kv { padding: 7px 10px; font-family: var(--font-mono); font-size: 11px; }
.c-kv-row { display: grid; grid-template-columns: minmax(8ch, .35fr) 1fr; gap: 10px; }
.c-group { display: block; margin: 0 0 10px; }
.c-table { display: table; width: 100%; border-collapse: collapse; font-family: var(--font-mono); font-size: 11px; }
.c-tr { display: table-row; }
.c-th, .c-td { display: table-cell; padding: 3px 10px; white-space: nowrap; border-bottom: 1px solid var(--border-bg); }
.c-th { color: var(--dim-fg); font-weight: 600; text-transform: uppercase; letter-spacing: .06em; font-size: 10px; }
.c-num { text-align: right; font-variant-numeric: tabular-nums; }
.c-td.good, .c-stat.good .c-stat-value { color: var(--success-fg, #2e8b57); }
.c-td.warn, .c-stat.warn .c-stat-value { color: var(--warning-fg, #b8860b); }
.c-td.bad, .c-stat.bad .c-stat-value { color: var(--alert-fg, #d13b32); font-weight: 600; }
.c-stats { display: flex; flex-wrap: wrap; gap: 8px; padding: 8px 0; }
.c-stat { display: flex; flex-direction: column; min-width: 11ch; padding: 6px 10px; border: 1px solid var(--border-bg); font-family: var(--font-mono); }
.c-stat-label { color: var(--dim-fg); font-size: 10px; text-transform: uppercase; letter-spacing: .06em; }
.c-stat-value { font-size: 18px; font-weight: 600; font-variant-numeric: tabular-nums; }
.c-stat-sub { color: var(--dim-fg); font-size: 10px; }
.c-keymap { display: flex; flex-wrap: wrap; gap: var(--s4) var(--s9); padding: 5px 12px; font-family: var(--font-mono); font-size: var(--fs-meta); line-height: 1.35; white-space: normal; color: var(--text-faint); }
.c-keymap-row { display: inline-flex; align-items: baseline; gap: var(--s4); min-width: 0; max-width: 100%; white-space: nowrap; }
/* the key is a c-action-key (layouts.ex): one element, one colour */
.c-keymap-key { display: inline-block; flex: none; font-size: var(--fs-meta); line-height: 1.2; }
.c-keymap-cmd { color: var(--text-faint); }
.c-keymap-doc { color: var(--text-dim); }

")

(category! 'ui)
(domain! 'ui)
(effects! '(write))
(public! 'defcomponent "(defcomponent NAME DOC PROPS EXAMPLE FN) — register a pure block-mode UI component")
(effects! '(pure))
(public! 'component "(component NAME PROPS) — instantiate a registered UI component")
(effects! '(read))
(public! 'describe-component "(describe-component NAME) — a component's props, example and owner, or #f")
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
