;;; components.scm --- a discoverable vocabulary for block-mode views.
;;;
;;; Components are pure: props in, one renderer block out.  State and event
;;; handling remain in the owning mode.  The live catalog is authoritative;
;;; apropos-components is only a convenient filter over the main apropos.

(namespace! 'ui)

(define *components* '()) ; ((qualified props example fn) ...)

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
    (list 'tag "span"
          'class (string-append "c-badge " (component--get p 'class ""))
          'text (component--get p 'text ""))))

(defcomponent 'ui/empty
  "A quiet notice for a view with no rows or content."
  '((text string optional) (class string optional))
  '(text "nothing to show")
  (lambda (p)
    (list 'tag "div" 'class (string-append "c-empty " (component--get p 'class ""))
          'text (component--get p 'text "nothing to show"))))

(defcomponent 'ui/section
  "A section heading with an optional count."
  '((title string required) (count number optional) (class string optional))
  '(title "Changes" count 3)
  (lambda (p)
    (list 'tag "div" 'class (string-append "c-section " (component--get p 'class ""))
          'text (string-append
                  (component--get p 'title "")
                  (if (component--has? p 'count)
                      (string-append " (" (number->string (component--get p 'count 0)) ")")
                      "")))))

(defcomponent 'ui/row
  "A selectable list row made from text or styled segments."
  '((text string optional) (segs list optional) (click any optional)
    (class string optional) (lines list optional) (mark string optional))
  '(segs (("" "name") ("c-dim" "  detail")))
  (lambda (p)
    (append (list 'tag "div"
                  'class (string-append "c-row " (component--get p 'class "")))
            (if (component--has? p 'segs) (list 'segs (component--get p 'segs))
                (list 'text (component--get p 'text "")))
            (if (component--has? p 'click) (list 'click (component--get p 'click)) '())
            (if (component--has? p 'lines) (list 'lines (component--get p 'lines)) '())
            (if (component--has? p 'mark) (list 'mark (component--get p 'mark)) '()))))

(defcomponent 'ui/actions
  "A row of clickable actions with optional keyboard hints."
  '((actions list required) (class string optional))
  '(actions (("refresh" "Refresh" "g") ("add" "Add" "+")))
  (lambda (p)
    (list 'tag "div"
          'class (string-append "c-actions " (component--get p 'class ""))
          'children
          (map (lambda (action)
                 (list 'tag "div" 'class "c-action" 'click (car action)
                       'segs
                       (append
                         (if (> (length action) 2)
                             (list (list "c-action-key" (nth 2 action)))
                             '())
                         (list (list "c-action-label" (cadr action))))))
               (component--get p 'actions '())))))

(defcomponent 'ui/fold-head
  "A clickable heading with a disclosure caret."
  '((title string required) (open? boolean required) (click any optional)
    (badge string optional))
  '(title "Details" open? #t click "details")
  (lambda (p)
    (append
      (list 'tag "div" 'class "c-fold-head"
            'segs (append
                    (list (list "c-caret" (if (component--get p 'open? #f) "▾" "▸"))
                          (list "c-fold-title" (component--get p 'title "")))
                    (if (component--has? p 'badge)
                        (list (list "c-fold-badge" (component--get p 'badge))) '())))
      (if (component--has? p 'click) (list 'click (component--get p 'click)) '()))))

(defcomponent 'ui/card
  "A bordered container with an optional heading and body."
  '((title string optional) (open? boolean optional) (click any optional)
    (badge string optional) (body blocks optional) (class string optional)
    (lines list optional) (mark string optional))
  '(title "A card" open? #t body ((tag "div" text "hello")))
  (lambda (p)
    (append
      (list 'tag "div"
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
    (list 'tag "div" 'class "c-kv"
          'children
          (map (lambda (pair)
                 (list 'tag "div" 'class "c-kv-row"
                       'segs (list (list "c-kv-key" (car pair))
                                   (list "c-kv-value" (cadr pair)))))
               (component--get p 'pairs '())))))

;;; --- living gallery ----------------------------------------------------------

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

(define *block-click-handlers* '()) ; ((name fn) ...)

(define (on-block-click! name fn)
  (set! *block-click-handlers*
    (cons (list name fn)
          (remove (lambda (e) (equal? (car e) name)) *block-click-handlers*))))

(block-on-click!
  (lambda (buf id)
    (let loop ((hs *block-click-handlers*))
      (cond ((null? hs) #f)
            (((cadr (car hs)) buf id) #t)
            (else (loop (cdr hs)))))))

(define-style! 'components "
.c-section { font-family: var(--font-mono); font-size: 11px; font-weight: 600; letter-spacing: .08em; text-transform: uppercase; color: var(--dim-fg); padding: 12px 2px 6px; border-bottom: 1px solid var(--border-bg); }
.c-card { margin: 0 0 10px; border: 1px solid var(--border-bg); border-radius: 7px; overflow: hidden; }
.c-fold-head { display: flex; gap: 8px; padding: 6px 10px; background: var(--hl-line-bg); cursor: pointer; font-family: var(--font-mono); }
.c-caret, .c-dim, .c-kv-key { color: var(--dim-fg); }
.c-row { padding: 4px 10px; font-family: var(--font-mono); }
.c-row.current { background: var(--hl-line-bg); }
.c-actions { display: flex; flex-wrap: wrap; gap: 6px; padding: 4px 0 12px; }
.c-action { display: inline-flex; gap: 6px; align-items: center; padding: 4px 8px; border: 1px solid var(--border-bg); border-radius: 5px; cursor: pointer; font-family: var(--font-mono); font-size: 11px; }
.c-action:hover { background: var(--hl-line-bg); border-color: var(--dim-fg); }
.c-action-key { color: var(--accent-fg); font-weight: 600; }
.c-action-label { color: var(--fg); }
.c-empty { padding: 12px; color: var(--dim-fg); font-family: var(--font-mono); }
.c-badge { display: inline-block; border-radius: 999px; padding: 1px 7px; background: var(--hl-line-bg); font-size: 10px; }
.c-kv { padding: 7px 10px; font-family: var(--font-mono); font-size: 11px; }
.c-kv-row { display: grid; grid-template-columns: minmax(8ch, .35fr) 1fr; gap: 10px; }
")

(category! 'ui)
(public! 'defcomponent "(defcomponent NAME DOC PROPS EXAMPLE FN) — register a pure block-mode UI component")
(public! 'component "(component NAME PROPS) — instantiate a registered UI component")
(public! 'describe-component "(describe-component NAME) — show a component's props, example and owner")
(public! 'apropos-components "(apropos-components QUERY [FILTERS...]) — the main apropos filtered to UI components")
(public! 'on-block-click! "(on-block-click! NAME FN) — register a blocks mode's click handler; FN gets (BUF ID) and returns #t when the click was its own")
