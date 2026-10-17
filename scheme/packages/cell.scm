;;; cell.scm --- named cells, their watchers, and the view parts they redraw.

(package! 'cell)

(domain! 'ui)
(effects! '(write))

(define *cells* '())

(define (cell--entry name) (assq name *cells*))

(define (cell--put! name value watchers)
  (set! *cells* (cons (list name value watchers)
                      (filter (lambda (e) (not (eq? (car e) name))) *cells*))))

(define (cell-define! name value)
  (unless (cell--entry name) (cell--put! name value '()))
  name)

(define (cell-set! name value)
  (let* ((e (cell--entry name))
         (old (and e (cadr e)))
         (watchers (if e (caddr e) '())))
    (if (and e (equal? old value))
        #f
        (begin
          (cell--put! name value watchers)
          (for-each (lambda (w) ((cadr w) value old)) watchers)
          #t))))

(define (cell-watch! name key fn)
  (cell-define! name #f)
  (let ((e (cell--entry name)))
    (cell--put! name (cadr e)
                (append (filter (lambda (w) (not (equal? (car w) key))) (caddr e))
                        (list (list key fn))))
    key))

(define (cell-unwatch! name key)
  (let ((e (cell--entry name)))
    (when e
      (cell--put! name (cadr e) (filter (lambda (w) (not (equal? (car w) key))) (caddr e))))))

(domain! 'ui)
(effects! '(pure))

(define (cell-part id node) (plist-put node 'cell-part id))

(define (cell--swap tree id node)
  (cond ((not (pair? tree)) tree)
        ((symbol? (car tree))
         (if (eq? (plist-get tree 'cell-part) id)
             node
             (let loop ((xs tree) (out '()))
               (cond ((null? xs) (reverse out))
                     ((null? (cdr xs)) (reverse (cons (car xs) out)))
                     ((memq (car xs) '(children body))
                      (loop (cddr xs) (cons (cell--swap (cadr xs) id node) (cons (car xs) out))))
                     (else (loop (cddr xs) (cons (cadr xs) (cons (car xs) out))))))))
        (else (map (lambda (x) (cell--swap x id node)) tree))))

(domain! 'ui)
(effects! '(write))

(define (cell-part-redraw! buf id render)
  (when (buffer-exists? buf)
    (let ((tree (buffer-local buf 'render-blocks)))
      (when (pair? tree)
        (buffer-set-local! buf 'render-blocks (cell--swap tree id (cell-part id (render))))))))

(define (cell-part-bind! buf id cells render)
  (for-each (lambda (c) (cell-watch! c (list 'part buf id) (lambda (v old) (cell-part-redraw! buf id render))))
            cells)
  id)
