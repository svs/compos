;;; chart.scm --- charts from a Scheme spec, drawn as an SVG image.
;;;
;;; A chart is a plist. chart-svg turns it into SVG text; chart-save!
;;; writes that text to a file; chart-show! writes it and shows the image
;;; in the other window, where browser-file-mode views it.
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
;;;   width, height            pixels; 640 by 360
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

;;; Colors

(define *chart-palette-light*
  '("#2a78d6" "#eb6834" "#1baf7a" "#eda100" "#e87ba4" "#008300" "#4a3aa7" "#e34948"))
(define *chart-palette-dark*
  '("#3987e5" "#d95926" "#199e70" "#c98500" "#d55181" "#008300" "#9085e9" "#e66767"))

(define (chart--ink surface t1 t2 muted grid base palette)
  (apply string-append
    (append
      (list ".sf{fill:" surface "}.ring{stroke:" surface "}"
            ".t1{fill:" t1 "}.t2{fill:" t2 "}.mu{fill:" muted "}"
            ".grid{stroke:" grid "}.base{stroke:" base "}")
      (map (lambda (c i)
             (let ((n (number->string (+ i 1))))
               (string-append ".f" n "{fill:" c "}.k" n "{stroke:" c "}")))
           palette (iota (length palette))))))

(define (chart--style theme)
  (let ((light (chart--ink "#fcfcfb" "#0b0b0b" "#52514e" "#898781" "#e1e0d9" "#c3c2b7"
                           *chart-palette-light*))
        (dark (chart--ink "#1a1a19" "#ffffff" "#c3c2b7" "#898781" "#2c2c2a" "#383835"
                          *chart-palette-dark*)))
    (string-append
      "<style>text{font-family:system-ui,-apple-system,'Segoe UI',sans-serif;font-size:12px}"
      ".tn{font-variant-numeric:tabular-nums}.ti{font-size:14px;font-weight:600}"
      (cond ((eq? theme 'dark) dark)
            ((eq? theme 'light) light)
            (else (string-append light "@media (prefers-color-scheme: dark){" dark "}")))
      "</style>")))

;;; Drawing

(define (chart--text x y cls anchor s &optional extra)
  (string-append "<text x='" (chart--n x) "' y='" (chart--n y) "' class='" cls
                 "' text-anchor='" anchor "'" (if extra extra "") ">"
                 (html-escape s) "</text>"))

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
  (apply string-append
    (map (lambda (it)
           (let ((x (car it)) (y (cadr it)) (i (+ 1 (cadddr it))))
             (string-append
               "<rect x='" (chart--n x) "' y='" (chart--n (- y 9))
               "' width='10' height='10' rx='2' class='f" (number->string i) "'/>"
               (chart--text (+ x 16) y "t2" "start" (caddr it)))))
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
