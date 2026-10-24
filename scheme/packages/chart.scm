;;; chart.scm --- charts from a Scheme spec, drawn as an SVG image.
;;;
;;; A chart is a plist. chart-svg turns it into SVG text; chart-save!
;;; writes that text to a file; chart-show! writes it and shows the image
;;; in the other window, where browser-file-mode views it. chart-block
;;; gives the same chart as a block for a page, drawn in the theme's colors.
;;;
;;;   (chart-show! '(type line title "Requests" x-label "day"
;;;                  series (("api" (3 5 4 8 7)) ("web" (2 2 3 4 6)))))
;;;
;;; SPEC keys:
;;;   type        line, area, bar or scatter; line is the default
;;;   series      ((NAME DATA) ...); DATA is (Y ...) or ((X Y) ...)
;;;   data        one series without a name, the same as series (("" DATA))
;;;   categories  the x labels of a bar chart or of a line over named steps
;;;   title, x-label, y-label  text
;;;   name        the file name chart-show! uses; the title by default
;;;   width, height            pixels; 520 by 300
;;;   y-zero      #t keeps 0 on the y axis; bar and area always keep it
;;;   y-format, x-format       procedures from a number to its label
;;;   theme       auto follows the system, or light or dark
;;;
;;; The colors are a fixed categorical order, checked for color blindness.
;;; Series take them in order and never cycle: a chart takes 8 series at
;;; most. Two or more series get a legend; a line or area chart with 4 or
;;; fewer also labels each line at its end.

(domain! 'charts)

;;; Numbers

(effects! '(pure))

(define (chart--pow10 e) (expt 10 e))

(define (chart--nice x round?)
  (let* ((e (floor (log x 10)))
         (p (chart--pow10 e))
         (f (/ x p))
         (nf (if round?
                 (cond ((< f 1.5) 1) ((< f 3) 2) ((< f 7) 5) (else 10))
                 (cond ((<= f 1) 1) ((<= f 2) 2) ((<= f 5) 5) (else 10)))))
    (* nf p)))

(define (chart--decimals step)
  (max 0 (- 0 (floor (log step 10)))))

(define (chart--round-to v d)
  (if (= d 0)
      (round v)
      (let ((p (chart--pow10 d))) (/ (round (* v p)) (* 1.0 p)))))

;; Ticks at 1, 2 or 5 times a power of ten that cover LO..HI. Integer
;; steps answer integers, so the labels have no fraction.
(define (chart-ticks lo hi &optional n)
  (let* ((n (if n n 5))
         (pad (if (= lo hi) (if (zero? lo) 1 (* 0.1 (abs lo))) 0))
         (lo (- lo pad))
         (hi (+ hi pad))
         (range (chart--nice (- hi lo) #f))
         (step (chart--nice (/ range (max 1 (- n 1))) #t))
         (d (chart--decimals step))
         (gmin (* (floor (/ lo step)) step))
         (gmax (* (ceiling (/ hi step)) step))
         (count (round (/ (- gmax gmin) step))))
    (map (lambda (i) (chart--round-to (+ gmin (* i step)) d))
         (iota (+ count 1)))))

(define (chart--pad-zeros s n)
  (if (< (string-length s) n) (chart--pad-zeros (string-append "0" s) n) s))

;; X with D digits after the point, as text.
(define (chart--fixed x d)
  (if (= d 0)
      (number->string (round x))
      (let* ((p (chart--pow10 d))
             (r (round (* x p)))
             (a (abs r)))
        (string-append (if (< r 0) "-" "")
                       (number->string (quotient a p)) "."
                       (chart--pad-zeros (number->string (remainder a p)) d)))))

;; A label maker for TICKS: big values read as k, M or B, and every label
;; shows as many digits as the step needs.
(define (chart--tick-format ticks)
  (let* ((top (fold (lambda (m v) (max m (abs v))) 0 ticks))
         (step (if (> (length ticks) 1) (abs (- (cadr ticks) (car ticks))) 1))
         (unit (cond ((>= top 1000000000) '(1000000000 "B"))
                     ((>= top 1000000) '(1000000 "M"))
                     ((>= top 10000) '(1000 "k"))
                     (else '(1 ""))))
         (u (car unit))
         (d (if (zero? step) 0 (chart--decimals (/ step u)))))
    (lambda (v)
      (if (zero? v) "0" (string-append (chart--fixed (/ v u) d) (cadr unit))))))

(define (chart--n v) (number->string (/ (round (* v 10)) 10.0)))

;; The lists side by side: (chart--zip '(1 2) '(a b)) is ((1 a) (2 b)).
(define (chart--zip &rest lists)
  (if (or (null? lists) (memq '() lists) (null? (car lists)))
      '()
      (cons (map car lists) (apply chart--zip (map cdr lists)))))

;; Call F on the items of LISTS in step, as Scheme's own for-each does.
(define (chart--each f &rest lists)
  (for-each (lambda (row) (apply f row)) (apply chart--zip lists)))

(define (chart--scale d0 d1 r0 r1)
  (let ((span (if (= d0 d1) 1 (- d1 d0))))
    (lambda (v) (+ r0 (* (- r1 r0) (/ (- v d0) span))))))

;;; The spec

(define (chart--opt spec key default)
  (let ((tail (memq key spec)))
    (if (and tail (pair? (cdr tail)) (not (eq? (cadr tail) #f)))
        (cadr tail)
        default)))

(define (chart--type spec)
  (let ((t (chart--opt spec 'type 'line)))
    (if (string? t) (string->symbol t) t)))

(define (chart--series spec)
  (let ((series (chart--opt spec 'series #f))
        (data (chart--opt spec 'data #f)))
    (cond (series series)
          (data (list (list "" data)))
          (else (error "chart: the spec has no series and no data")))))

(define (chart--label-text x)
  (cond ((string? x) x) ((symbol? x) (symbol->string x)) (else (format "~a" x))))

(define (chart--name s) (chart--label-text (car s)))

;; DATA as ((X Y) ...); a bare Y takes its index as X.
(define (chart--points data)
  (let loop ((xs data) (i 0) (acc '()))
    (cond ((null? xs) (reverse acc))
          ((number? (car xs)) (loop (cdr xs) (+ i 1) (cons (list i (car xs)) acc)))
          (else (loop (cdr xs) (+ i 1) (cons (list (car (car xs)) (cadr (car xs))) acc))))))

;; The x values of every series in the order they first appear.
(define (chart--collect-x all)
  (fold (lambda (seen p) (if (member (car p) seen) seen (append seen (list (car p)))))
        '() (apply append all)))

(define (chart--index-of x xs)
  (let loop ((xs xs) (i 0))
    (cond ((null? xs) #f) ((equal? (car xs) x) i) (else (loop (cdr xs) (+ i 1))))))

;;; Nodes

;; A chart is drawn as nodes, (TAG ATTRS KIDS); a kid is a node or text.
;; chart--xml writes them as SVG text, chart--block as a page block.
(define (chart--el tag attrs &rest kids) (list tag attrs kids))

(define (chart--xml node)
  (if (string? node)
      (html-escape node)
      (let ((tag (car node)) (attrs (cadr node)) (kids (caddr node)))
        (string-append "<" tag
                       (apply string-append
                              (map (lambda (a) (string-append " " (car a) "=\"" (html-escape (cadr a)) "\"")) attrs))
                       (if (null? kids)
                           "/>"
                           (string-append ">" (apply string-append (map chart--xml kids)) "</" tag ">"))))))

(define (chart--block node)
  (let* ((tag (car node)) (attrs (cadr node)) (kids (caddr node))
         (cls (assoc "class" attrs))
         (base (append (list 'tag tag)
                       (if cls (list 'class (cadr cls)) '())
                       (list 'attrs (filter (lambda (a) (not (equal? (car a) "class"))) attrs)))))
    (cond ((null? kids) base)
          ((and (null? (cdr kids)) (string? (car kids))) (append base (list 'text (car kids))))
          (else (append base (list 'children
                                   (map (lambda (k) (if (string? k) (list 'tag "tspan" 'text k) (chart--block k)))
                                        kids)))))))

;;; Colors

(define *chart-palette-light*
  '("#2a78d6" "#eb6834" "#1baf7a" "#eda100" "#e87ba4" "#008300" "#4a3aa7" "#e34948"))
(define *chart-palette-dark*
  '("#3987e5" "#d95926" "#199e70" "#c98500" "#d55181" "#008300" "#9085e9" "#e66767"))

(define (chart--ink surface edge t1 t2 muted grid base palette)
  (apply string-append
    (append
      (list ".chart-sf{fill:" surface "}.chart-ring{stroke:" surface "}.chart-bd{stroke:" edge "}"
            ".chart-t1{fill:" t1 "}.chart-t2{fill:" t2 "}.chart-mu{fill:" muted "}"
            ".chart-grid{stroke:" grid "}.chart-base{stroke:" base "}")
      (map (lambda (row)
             (let ((c (car row)) (n (number->string (+ 1 (cadr row)))))
               (string-append ".chart-f" n "{fill:" c "}.chart-k" n "{stroke:" c "}")))
           (chart--zip palette (iota (length palette)))))))

(define (chart--style theme)
  (let ((light (chart--ink "#fcfcfb" "rgba(11,11,11,0.10)" "#0b0b0b" "#52514e" "#898781" "#e1e0d9" "#c3c2b7"
                           *chart-palette-light*))
        (dark (chart--ink "#1a1a19" "rgba(255,255,255,0.10)" "#ffffff" "#c3c2b7" "#898781" "#2c2c2a" "#383835"
                          *chart-palette-dark*)))
    (string-append
      ".chart text{font-family:system-ui,-apple-system,'Segoe UI',sans-serif;font-size:12px}"
      ".chart .chart-tn{font-variant-numeric:tabular-nums}.chart .chart-ti{font-size:14px;font-weight:600}"
      (cond ((eq? theme 'dark) dark)
            ((eq? theme 'light) light)
            (else (string-append light "@media (prefers-color-scheme: dark){" dark "}"))))))

;; The same ink from the theme's own CSS variables, for a chart drawn in a
;; page: it follows the editor's theme and changes with it.
(define *chart-palette-editor*
  '("var(--group-color-2-fg, #2a78d6)" "var(--group-color-5-fg, #eb6834)" "var(--group-color-3-fg, #1baf7a)"
    "var(--group-color-4-fg, #eda100)" "var(--group-color-6-fg, #e87ba4)" "var(--group-color-1-fg, #008300)"
    "var(--ansi-color-yellow-fg, #4a3aa7)" "var(--ansi-color-magenta-fg, #e34948)"))

(define (chart--editor-style)
  (string-append
    ".chart{display:block;width:100%;max-width:640px;height:auto}"
    ".chart text{font-family:inherit;font-size:12px}"
    ".chart .chart-tn{font-variant-numeric:tabular-nums}.chart .chart-ti{font-size:14px;font-weight:600}"
    (chart--ink "var(--default-bg)" "var(--border-bg)" "var(--default-fg)" "var(--dim-fg)"
                "var(--faint-fg, var(--dim-fg))" "var(--border-soft-bg, var(--border-bg))" "var(--border-bg)"
                *chart-palette-editor*)))

;;; Drawing

(define (chart--text x y cls anchor s &optional attrs)
  (chart--el "text" (append (list (list "x" (chart--n x)) (list "y" (chart--n y)) (list "class" cls)
                               (list "text-anchor" anchor))
                         (if attrs attrs '()))
             s))

(define (chart--width-of s) (* 6.6 (string-length s)))

(define (chart--widest strings)
  (fold (lambda (m s) (max m (chart--width-of s))) 0 strings))

;; The legend items, ((X Y NAME INDEX) ...), laid out from LEFT and
;; wrapped before RIGHT.
(define (chart--legend-items names left right top)
  (let loop ((ns names) (i 0) (x left) (y top) (acc '()))
    (if (null? ns)
        (reverse acc)
        (let* ((w (+ 16 (chart--width-of (car ns)) 16))
               (wrap? (and (> (+ x w) right) (> x left)))
               (x (if wrap? left x))
               (y (if wrap? (+ y 18) y)))
          (loop (cdr ns) (+ i 1) (+ x w) y (cons (list x y (car ns) i) acc))))))

(define (chart--legend-svg items)
  (apply append
    (map (lambda (it)
           (let ((x (car it)) (y (cadr it)) (i (+ 1 (car (cdr (cddr it))))))
             (list (chart--el "rect" (list (list "x" (chart--n x)) (list "y" (chart--n (- y 9)))
                                           (list "width" "10") (list "height" "10") (list "rx" "2")
                                           (list "class" (string-append "chart-f" (number->string i)))))
                   (chart--text (+ x 16) y "chart-t2" "start" (caddr it)))))
         items)))

;; A bar from the baseline Y0 to Y1 with its far end rounded.
(define (chart--bar-path x w y0 y1)
  (let* ((h (abs (- y1 y0)))
         (r (min 4 (/ w 2) h))
         (yr (if (< y1 y0) (+ y1 r) (- y1 r))))
    (string-append "M" (chart--n x) "," (chart--n y0) "V" (chart--n yr)
                   "Q" (chart--n x) "," (chart--n y1) " " (chart--n (+ x r)) "," (chart--n y1)
                   "H" (chart--n (- (+ x w) r))
                   "Q" (chart--n (+ x w)) "," (chart--n y1) " " (chart--n (+ x w)) "," (chart--n yr)
                   "V" (chart--n y0) "Z")))

(define (chart--poly pts)
  (let loop ((ps pts) (first? #t) (acc '()))
    (if (null? ps)
        (apply string-append (reverse acc))
        (loop (cdr ps) #f
              (cons (string-append (if first? "M" "L") (chart--n (car (car ps)))
                                   "," (chart--n (cadr (car ps))))
                    acc)))))

;; The end labels of lines, ((Y NAME) ...), pushed apart to 14px.
(define (chart--spread labels top bottom)
  (let loop ((ls (sort labels)) (floor-y top) (acc '()))
    (if (null? ls)
        (reverse acc)
        (let ((y (min bottom (max floor-y (car (car ls))))))
          (loop (cdr ls) (+ y 14) (cons (cons y (cdr (car ls))) acc))))))

;; The points of every series, with x as a category index when the chart
;; has categories: a bar chart, given categories, or x values that are
;; not numbers. Answers (CATEGORY? CATEGORIES POINTS).
(define (chart--layout-data type given all)
  (let* ((category? (or given (eq? type 'bar)
                        (fold (lambda (any p) (or any (not (number? (car p)))))
                              #f (apply append all))))
         (cats (cond (given given) (category? (chart--collect-x all)) (else '()))))
    (list category? cats
          (if category?
              (map (lambda (pts)
                     (fold (lambda (acc p)
                             (let ((i (if (and given (number? (car p)))
                                          (car p)
                                          (chart--index-of (car p) cats))))
                               (if i (append acc (list (list i (cadr p)))) acc)))
                           '() pts))
                   all)
              all))))

;; The marks of every series, as nodes.
(define (chart--marks type all names count sx sy base-y band cat-labels yfmt)
  (let ((out '()))
    (define (emit! node) (set! out (cons node out)))
    (cond
      ((eq? type 'bar)
       (let* ((group-w (* band 0.7))
              (w (max 1 (/ (- group-w (* 2 (- count 1))) count))))
         (chart--each
           (lambda (pts k name)
             (for-each
               (lambda (p)
                 (let ((x (+ (- (sx (car p)) (/ group-w 2)) (* k (+ w 2))))
                       (cat (if (< (car p) (length cat-labels)) (list-ref cat-labels (car p)) "")))
                   (emit! (chart--el "path" (list (list "class" (string-append "chart-f" (number->string (+ k 1))))
                                                  (list "d" (chart--bar-path x w base-y (sy (cadr p)))))
                                     (chart--el "title" '()
                                                (string-append (if (string=? name "") "" (string-append name ", "))
                                                               cat ": " (yfmt (cadr p))))))))
               pts))
           all (iota count) names)))
      ((eq? type 'scatter)
       (chart--each
         (lambda (pts k)
           (for-each
             (lambda (p)
               (emit! (chart--el "circle" (list (list "cx" (chart--n (sx (car p)))) (list "cy" (chart--n (sy (cadr p))))
                                                (list "r" "4") (list "stroke-width" "2")
                                                (list "class" (string-append "chart-ring chart-f" (number->string (+ k 1))))))))
             pts))
         all (iota count)))
      (else
       (chart--each
         (lambda (pts k)
           (let ((xy (map (lambda (p) (list (sx (car p)) (sy (cadr p)))) pts))
                 (n (number->string (+ k 1))))
             (when (and (eq? type 'area) (pair? xy))
               (emit! (chart--el "path" (list (list "class" (string-append "chart-f" n)) (list "fill-opacity" "0.14")
                                              (list "d" (string-append (chart--poly xy)
                                                                       "L" (chart--n (car (car (reverse xy)))) "," (chart--n base-y)
                                                                       "L" (chart--n (car (car xy))) "," (chart--n base-y) "Z"))))))
             (emit! (chart--el "path" (list (list "class" (string-append "chart-k" n)) (list "fill" "none")
                                            (list "stroke-width" "2") (list "stroke-linejoin" "round")
                                            (list "stroke-linecap" "round") (list "d" (chart--poly xy)))))
             (when (= (length xy) 1)
               (emit! (chart--el "circle" (list (list "cx" (chart--n (car (car xy)))) (list "cy" (chart--n (cadr (car xy))))
                                                (list "r" "4") (list "class" (string-append "chart-f" n))))))))
         all (iota count))))
    (reverse out)))

(define (chart--tree spec inline?)
  (let* ((type (chart--type spec))
         (series (chart--series spec))
         (count (length series))
         (_ (when (> count 8)
              (error "chart: 8 series at most; fold the rest into Other or draw small multiples")))
         (names (map chart--name series))
         (data (chart--layout-data type (chart--opt spec 'categories #f)
                                   (map (lambda (s) (chart--points (cadr s))) series)))
         (category? (car data))
         (cats (cadr data))
         (all (caddr data))
         (cat-labels (map chart--label-text cats))
         (ys (map cadr (apply append all)))
         (_ (when (null? ys) (error "chart: the series hold no points")))
         (keep-zero? (or (memq type '(bar area)) (chart--opt spec 'y-zero #f)))
         (ylo (fold min (car ys) ys))
         (yhi (fold max (car ys) ys))
         (yticks (chart-ticks (if keep-zero? (min 0 ylo) ylo) (if keep-zero? (max 0 yhi) yhi) 5))
         (ymin (car yticks))
         (ymax (car (reverse yticks)))
         (yfmt (chart--opt spec 'y-format (chart--tick-format yticks)))
         (ylabels (map yfmt yticks))
         (xs (if category? '() (map car (apply append all))))
         (xticks (if category? '() (chart-ticks (fold min (car xs) xs) (fold max (car xs) xs) 6)))
         (xfmt (chart--opt spec 'x-format (chart--tick-format xticks)))
         (width (chart--opt spec 'width 520))
         (height (chart--opt spec 'height 300))
         (title (chart--opt spec 'title #f))
         (x-label (chart--opt spec 'x-label #f))
         (y-label (chart--opt spec 'y-label #f))
         (theme (chart--opt spec 'theme 'auto))
         (theme (if (string? theme) (string->symbol theme) theme))
         (direct? (and (memq type '(line area)) (<= 2 count 4)))
         (legend? (>= count 2))
         (left0 20)
         (top0 (+ 16 (if title 22 0)))
         (legend (if legend? (chart--legend-items names left0 (- width 20) (+ top0 12)) '()))
         (top (+ 10 (if legend? (+ 8 (cadr (car (reverse legend)))) top0)))
         (left (+ 20 (if y-label 18 0) (chart--widest ylabels) 8))
         (right (- width 24 (if direct? (+ 10 (chart--widest names)) 0)))
         (bottom (- height 20 18 (if x-label 18 0)))
         (sy (chart--scale ymin ymax bottom top))
         (band (/ (- right left) (max 1 (length cats))))
         (sx (if category?
                 (lambda (i) (+ left (* band (+ i 0.5))))
                 (chart--scale (car xticks) (car (reverse xticks)) left right)))
         (base-y (sy (if (<= ymin 0 ymax) 0 ymin)))
         (out '()))
    (define (emit! &rest nodes) (set! out (append (reverse nodes) out)))
    (define (hline y cls)
      (emit! (chart--el "line" (list (list "x1" (chart--n left)) (list "x2" (chart--n right))
                                     (list "y1" (chart--n y)) (list "y2" (chart--n y))
                                     (list "class" cls) (list "stroke-width" "1")))))
    (emit! (chart--el "title" '() (or title "chart")))
    (unless inline? (emit! (chart--el "style" '() (chart--style theme))))
    ;; The card: rounded, with a hairline edge and a soft shadow under it.
    (emit! (chart--el "defs" '()
                      (chart--el "filter" '(("id" "chart-lift") ("x" "-5%") ("y" "-5%") ("width" "110%") ("height" "120%"))
                                 (chart--el "feDropShadow" '(("dx" "0") ("dy" "1.5") ("stdDeviation" "2.5")
                                                              ("flood-color" "#000") ("flood-opacity" "0.14"))))))
    (emit! (chart--el "rect" (list (list "class" "chart-sf chart-bd") (list "x" "5") (list "y" "4")
                                   (list "width" (number->string (- width 10))) (list "height" (number->string (- height 12)))
                                   (list "rx" "12") (list "stroke-width" "1") (list "filter" "url(#chart-lift)"))))
    (when title (emit! (chart--text left0 32 "chart-t1 chart-ti" "start" title)))
    (when legend? (apply emit! (chart--legend-svg legend)))
    ;; The grid and the y labels
    (chart--each (lambda (v s)
                (hline (sy v) "chart-grid")
                (emit! (chart--text (- left 8) (+ (sy v) 4) "chart-mu chart-tn" "end" s)))
              yticks ylabels)
    (hline base-y "chart-base")
    ;; The x labels. Categories thin out when they do not fit their band.
    (if category?
        (let ((every (max 1 (ceiling (/ (+ 8 (chart--widest cat-labels)) band)))))
          (chart--each (lambda (s i)
                      (when (= 0 (remainder i every))
                        (emit! (chart--text (sx i) (+ bottom 18) "chart-mu" "middle" s))))
                    cat-labels (iota (length cat-labels))))
        (for-each (lambda (v) (emit! (chart--text (sx v) (+ bottom 18) "chart-mu chart-tn" "middle" (xfmt v))))
                  xticks))
    (when x-label
      (emit! (chart--text (/ (+ left right) 2) (- height 18) "chart-t2" "middle" x-label)))
    (when y-label
      (let ((cy (/ (+ top bottom) 2)))
        (emit! (chart--text 22 cy "chart-t2" "middle" y-label
                            (list (list "transform" (string-append "rotate(-90 22 " (chart--n cy) ")")))))))
    (apply emit! (chart--marks type all names count sx sy base-y band cat-labels yfmt))
    (when direct?
      (for-each (lambda (l) (emit! (chart--text (+ right 10) (+ (car l) 4) "chart-t2" "start" (cadr l))))
                (chart--spread
                  (fold (lambda (acc row)
                          (let ((pts (car row)) (name (cadr row)))
                            (if (null? pts) acc (cons (list (sy (cadr (car (reverse pts)))) name) acc))))
                        '() (chart--zip all names))
                  (+ top 4) bottom)))
    (list "svg"
          (list (list "xmlns" "http://www.w3.org/2000/svg") (list "width" (number->string width))
                (list "height" (number->string height))
                (list "viewBox" (string-append "0 0 " (number->string width) " " (number->string height)))
                (list "role" "img") (list "class" "chart"))
          (reverse out))))

(define (chart-svg spec) (chart--xml (chart--tree spec #f)))

;; The chart as a block for a page: the SVG lives in the page itself, so its
;; colors are the theme's and change with it.
(define (chart-block spec) (chart--block (chart--tree spec #t)))

;;; Files and showing

(effects! '(write))

(defgroup 'chart "Charts drawn from a Scheme spec.")

(define-style! 'chart (chart--editor-style))

(defcustom 'chart-directory "~/.compos/charts"
  "Where chart-show! writes the SVG file of a chart."
  'group 'chart 'type 'string)

(define (chart--home path)
  (if (string-prefix? "~/" path) (string-append (getenv "HOME") (substring path 1 (string-length path))) path))

(define (chart--slug s)
  (let* ((clean (re-replace-all "[^a-z0-9]+" (string-downcase s) "-"))
         (parts (filter (lambda (p) (not (string=? p ""))) (string-split clean "-"))))
    (if (null? parts) "chart" (string-join parts "-"))))

(define (chart-path spec)
  (string-append (chart--home chart-directory) "/"
                 (chart--slug (chart--label-text (chart--opt spec 'name (chart--opt spec 'title "chart"))))
                 ".svg"))

(define (chart-save! spec path)
  (let ((path (chart--home path)))
    (write-file! path (chart-svg spec))
    path))

(effects! '(write display))

;; Write the chart and show it in the other window. The focus stays.
(define (chart-show! spec &optional path)
  (let ((path (chart-save! spec (if path path (chart-path spec))))
        (group (buffer-group (current-buffer))))
    (with-frame-windows
      (lambda ()
        (window-set-buffer! (get-other-window)
                            (if (buffer-known? path) path (visit path group)))))
    path))

(effects! '(pure))
(public! 'chart-svg
  "(chart-svg SPEC) — the SVG text of the chart SPEC describes: a plist of type (line area bar scatter), series ((NAME DATA) ...), data, categories, title, x-label, y-label, width, height, y-zero, y-format, x-format, theme")
(public! 'chart-block
  "(chart-block SPEC) — the chart SPEC describes as a page block: inline SVG in the theme's colors, which follow a theme change")
(public! 'chart-ticks
  "(chart-ticks LO HI [N]) — about N round tick values that cover LO..HI, in steps of 1, 2 or 5 times a power of ten")
(effects! '(write))
(public! 'chart-path "(chart-path SPEC) — the file chart-show! writes for SPEC, named from its name or title under chart-directory")
(public! 'chart-save! "(chart-save! SPEC PATH) — write the chart SPEC describes to PATH as SVG; return the path")
(effects! '(write display))
(public! 'chart-show! "(chart-show! SPEC [PATH]) — write the chart as SVG and show the image in the other window; focus stays; return the path")
