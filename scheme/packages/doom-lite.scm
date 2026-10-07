;;; doom-lite.scm --- a first-person shooter drawn in a buffer.
;;;
;;; M-x doom-lite opens *doom-lite*. The buffer holds a level, a player, eight
;;; monsters, and two pickups. One tick moves the monsters and redraws.
;;; A key moves the player and redraws at once.
;;;
;;; The renderer is a raycaster. For each screen column the caster walks
;;; the grid (a DDA) until it meets a wall, and answers the perpendicular
;;; distance. The column height is the view height divided by that
;;; distance. Monsters and pickups draw after the walls, far one first,
;;; and a sprite hides behind a nearer wall.
;;;
;;; The arithmetic is fixed point. The interpreter has no sine and no
;;; square root, so this file carries a 256 entry sine table scaled by
;;; 1024, and every position, direction and distance is an integer of
;;; 1024 units per map cell. The caster needs no square root.
;;;
;;; The blocks view draws the walls as one rect per column inside one
;;; SVG. The buffer text carries the same state as a small map and a
;;; status line, so a reader without the blocks view still sees the game,
;;; and a test reads the text.
;;;
;;; Every number the game needs is a buffer-local, so the desktop saves a
;;; game in progress and the mode setup fn draws it again after a
;;; restart. Only the render blocks and the frame timing are runtime.

(domain! 'games)
(effects! '(read write display))

(defgroup 'doom-lite "A first-person shooter drawn in a buffer.")

(defcustom 'doom-lite-tick-ms 120
  "Milliseconds between two monster ticks of a shown *doom-lite* buffer."
  'group 'doom-lite 'type 'number)

(defcustom 'doom-lite-columns 120
  "How many rays the renderer casts. More columns give a sharper wall and cost more per frame."
  'group 'doom-lite 'type 'number)

;; How far one turn key turns, in units of a 256 unit circle.
(define doom-lite-turn-step 7)

(defcustom 'doom-lite-move-step 190
  "How far one move key moves, in fixed point units of 1024 per map cell."
  'group 'doom-lite 'type 'number)

;;; --- constants ----------------------------------------------------------------

(define *doom-lite-buffer* "*doom-lite*")

;; one map cell is this many fixed point units
(define *doom-lite-fp* 1024)

;; the SVG view box: the caster fills doom-lite-columns of width 1
(define *doom-lite-view-h* 80)

;; the caster gives up after this many cells and reports a far wall
(define *doom-lite-max-steps* 40)

(define *doom-lite-start-health* 100)
(define *doom-lite-start-ammo* 50)

;; sin(2*pi*i/256) * 1024, for i in 0..255
(define *doom-lite-sin*
  '(0 25 50 75 100 125 150 175 200 224 249 273 297 321 345 369
    392 415 438 460 483 505 526 548 569 590 610 630 650 669 688 706
    724 742 759 775 792 807 822 837 851 865 878 891 903 915 926 936
    946 955 964 972 980 987 993 999 1004 1009 1013 1016 1019 1021 1023 1024
    1024 1024 1023 1021 1019 1016 1013 1009 1004 999 993 987 980 972 964 955
    946 936 926 915 903 891 878 865 851 837 822 807 792 775 759 742
    724 706 688 669 650 630 610 590 569 548 526 505 483 460 438 415
    392 369 345 321 297 273 249 224 200 175 150 125 100 75 50 25
    0 -25 -50 -75 -100 -125 -150 -175 -200 -224 -249 -273 -297 -321 -345 -369
    -392 -415 -438 -460 -483 -505 -526 -548 -569 -590 -610 -630 -650 -669 -688 -706
    -724 -742 -759 -775 -792 -807 -822 -837 -851 -865 -878 -891 -903 -915 -926 -936
    -946 -955 -964 -972 -980 -987 -993 -999 -1004 -1009 -1013 -1016 -1019 -1021 -1023 -1024
    -1024 -1024 -1023 -1021 -1019 -1016 -1013 -1009 -1004 -999 -993 -987 -980 -972 -964 -955
    -946 -936 -926 -915 -903 -891 -878 -865 -851 -837 -822 -807 -792 -775 -759 -742
    -724 -706 -688 -669 -650 -630 -610 -590 -569 -548 -526 -505 -483 -460 -438 -415
    -392 -369 -345 -321 -297 -273 -249 -224 -200 -175 -150 -125 -100 -75 -50 -25))

;; the level. A space is floor; 1 to 4 name a wall colour. 24 by 24.
(define *doom-lite-map*
  '("111111111111111111111111"
    "1        2       1     1"
    "1  333   2   1   1  4  1"
    "1  3 3   2   1   1  4  1"
    "1  3 3       1      4  1"
    "1  333   22221      4  1"
    "1                      1"
    "1     4444   1111111   1"
    "1     4  4         1   1"
    "1     4  4   333   1   1"
    "1            3 3   1   1"
    "1  22222     333   1   1"
    "1  2             111   1"
    "1  2   1111            1"
    "1  2   1  1   4444444  1"
    "1      1  1   4     4  1"
    "1  3333   1   4     4  1"
    "1     3       4444  4  1"
    "1     3   2222         1"
    "1     3   2      33333 1"
    "1         2            1"
    "1   11111 2   1111111  1"
    "1                      1"
    "111111111111111111111111"))

(define *doom-lite-map-size* 24)

;; the cell the player starts in, and the cells the monsters start in
(define *doom-lite-start-cell* '(4 6))
(define *doom-lite-monster-cells*
  '((18 2) (20 10) (6 12) (16 18) (3 20) (21 16) (15 6) (11 22)))
(define *doom-lite-item-cells* '((8 20 "ammo") (22 6 "health")))

;; wall colour by tile byte: (TILE R G B)
(define *doom-lite-wall-rgb*
  '((49 152 152 168)
    (50 150 104 66)
    (51 96 132 96)
    (52 160 74 62)))

(define *doom-lite-hex-digits* "0123456789abcdef")

;;; --- small arithmetic ---------------------------------------------------------

(define (doom-lite--fpm a b) (quotient (* a b) *doom-lite-fp*))

(define (doom-lite--fpd a b) (quotient (* a *doom-lite-fp*) b))

(define (doom-lite--sin a) (nth (modulo a 256) *doom-lite-sin*))

(define (doom-lite--cos a) (doom-lite--sin (+ a 64)))

(define (doom-lite--clamp n low high) (max low (min n high)))

(define (doom-lite--cell->fp c) (+ (* c *doom-lite-fp*) (quotient *doom-lite-fp* 2)))

;; the byte at map cell X Y; outside the map is a wall
(define (doom-lite--tile x y)
  (if (or (< x 0) (< y 0) (>= x *doom-lite-map-size*) (>= y *doom-lite-map-size*))
      49
      (string-byte (nth y *doom-lite-map*) x)))

(define (doom-lite--wall? x y) (not (= (doom-lite--tile x y) 32)))

(define (doom-lite--open-fp? fx fy)
  (not (doom-lite--wall? (quotient fx *doom-lite-fp*) (quotient fy *doom-lite-fp*))))

(define (doom-lite--hex2 n)
  (let* ((v (doom-lite--clamp n 0 255))
         (hi (quotient v 16))
         (lo (modulo v 16)))
    (string-append (substring *doom-lite-hex-digits* hi (+ hi 1))
                   (substring *doom-lite-hex-digits* lo (+ lo 1)))))

(define (doom-lite--color r g b)
  (string-append "#" (doom-lite--hex2 r) (doom-lite--hex2 g) (doom-lite--hex2 b)))

;;; --- the plist the game state is made of --------------------------------------

(define (doom-lite--get pl key &optional fallback)
  (let loop ((xs (if (pair? pl) pl '())))
    (cond ((null? xs) fallback)
          ((null? (cdr xs)) fallback)
          ((equal? (car xs) key) (car (cdr xs)))
          (else (loop (cdr (cdr xs)))))))

(define (doom-lite--put pl key value)
  (let loop ((xs (if (pair? pl) pl '())) (out '()) (done #f))
    (cond ((null? xs)
           (if done (reverse out) (append (reverse out) (list key value))))
          ((null? (cdr xs)) (reverse out))
          ((equal? (car xs) key)
           (loop (cdr (cdr xs)) (cons value (cons key out)) #t))
          (else (loop (cdr (cdr xs))
                      (cons (car (cdr xs)) (cons (car xs) out))
                      done)))))

;;; --- the caster ---------------------------------------------------------------

;; Walk the grid from PX PY along RDX RDY until a wall stops the ray.
;; The answer is (DISTANCE SIDE TILE): the perpendicular distance in
;; fixed point cells, 0 for a vertical face and 1 for a horizontal one,
;; and the byte of the wall the ray met.
(define (doom-lite--cast px py rdx rdy)
  (let* ((mx0 (quotient px *doom-lite-fp*))
         (my0 (quotient py *doom-lite-fp*))
         (far (* 8192 *doom-lite-fp*))
         (ddx (if (= rdx 0) far (abs (doom-lite--fpd *doom-lite-fp* rdx))))
         (ddy (if (= rdy 0) far (abs (doom-lite--fpd *doom-lite-fp* rdy))))
         (sx (if (< rdx 0) -1 1))
         (sy (if (< rdy 0) -1 1))
         (sdx0 (if (< rdx 0)
                   (doom-lite--fpm (- px (* mx0 *doom-lite-fp*)) ddx)
                   (doom-lite--fpm (- (* (+ mx0 1) *doom-lite-fp*) px) ddx)))
         (sdy0 (if (< rdy 0)
                   (doom-lite--fpm (- py (* my0 *doom-lite-fp*)) ddy)
                   (doom-lite--fpm (- (* (+ my0 1) *doom-lite-fp*) py) ddy))))
    (let loop ((mx mx0) (my my0) (sdx sdx0) (sdy sdy0) (n 0))
      (if (> n *doom-lite-max-steps*)
          (list (* *doom-lite-max-steps* *doom-lite-fp*) 0 49)
          (let* ((x-first (< sdx sdy))
                 (nmx (if x-first (+ mx sx) mx))
                 (nmy (if x-first my (+ my sy)))
                 (nsdx (if x-first (+ sdx ddx) sdx))
                 (nsdy (if x-first sdy (+ sdy ddy)))
                 (side (if x-first 0 1))
                 (tile (doom-lite--tile nmx nmy)))
            (if (= tile 32)
                (loop nmx nmy nsdx nsdy (+ n 1))
                (list (if (= side 0) (- nsdx ddx) (- nsdy ddy)) side tile)))))))

;; how bright a wall is at DIST, as a percent; a horizontal face is darker
(define (doom-lite--shade dist side)
  (let* ((raw (quotient (* 700 *doom-lite-fp*) (+ (* 5 *doom-lite-fp*) (* 2 (max 1 dist)))))
         (pct (doom-lite--clamp raw 16 100)))
    (if (= side 1) (quotient (* pct 72) 100) pct)))

(define (doom-lite--wall-rgb tile)
  (let loop ((xs *doom-lite-wall-rgb*))
    (cond ((null? xs) '(140 140 140))
          ((= (car (car xs)) tile) (cdr (car xs)))
          (else (loop (cdr xs))))))

(define (doom-lite--wall-color tile side dist)
  (let ((rgb (doom-lite--wall-rgb tile))
        (pct (doom-lite--shade dist side)))
    (doom-lite--color (quotient (* (nth 0 rgb) pct) 100)
                 (quotient (* (nth 1 rgb) pct) 100)
                 (quotient (* (nth 2 rgb) pct) 100))))

;;; --- blocks -------------------------------------------------------------------

(define (doom-lite--kids items)
  (fold (lambda (acc x)
          (cond ((null? x) acc)
                ((and (pair? x) (pair? (car x))) (append acc x))
                (else (append acc (list x)))))
        '() items))

(define (doom-lite--div class &rest children)
  (list 'tag "div" 'class class 'children (doom-lite--kids children)))

(define (doom-lite--txt class text)
  (list 'tag "span" 'class class 'text text))

(define (doom-lite--rect x y w h fill &optional opacity)
  (list 'tag "rect" 'class "doom-lite-r"
        'attrs (append
                 (list (list "x" (number->string x))
                       (list "y" (number->string y))
                       (list "width" (number->string (max 0 w)))
                       (list "height" (number->string (max 0 h)))
                       (list "fill" fill))
                 (if opacity (list (list "fill-opacity" opacity)) '()))))

;;; --- the walls ----------------------------------------------------------------

;; Cast one ray per column. The answer is (blocks BLOCKS z DISTANCES):
;; the wall rects, and the distance each column stands at, which the
;; sprite pass reads to hide a monster behind a wall.
(define (doom-lite--wall-pass px py dx dy plx ply w h)
  (let loop ((x 0) (rects '()) (zbuf '()))
    (if (>= x w)
        (list 'blocks (reverse rects) 'z (reverse zbuf))
        (let* ((camx (- (quotient (* 2 *doom-lite-fp* x) w) *doom-lite-fp*))
               (rdx (+ dx (doom-lite--fpm plx camx)))
               (rdy (+ dy (doom-lite--fpm ply camx)))
               (hit (doom-lite--cast px py rdx rdy))
               (dist (max 96 (nth 0 hit)))
               (side (nth 1 hit))
               (tile (nth 2 hit))
               (lh (min (* h 4) (quotient (* h *doom-lite-fp*) dist)))
               (y0 (quotient (- h lh) 2)))
          (loop (+ x 1)
                (cons (doom-lite--rect x y0 1 lh (doom-lite--wall-color tile side dist)) rects)
                (cons dist zbuf))))))

;; the ceiling and the floor, each in four bands so the far ground is darker
(define (doom-lite--ground w h)
  (let ((half (quotient h 2)))
    (let loop ((i 0) (out '()))
      (if (= i 4)
          (reverse out)
          (let* ((bh (quotient half 4))
                 (sky (+ 14 (* i 5)))
                 (gnd (+ 20 (* (- 3 i) 7))))
            (loop (+ i 1)
                  (cons (doom-lite--rect 0 (+ half (* i bh)) w (+ bh 1)
                                    (doom-lite--color (+ gnd 16) (+ gnd 8) gnd)
                                    #f)
                        (cons (doom-lite--rect 0 (* i bh) w (+ bh 1)
                                          (doom-lite--color sky sky (+ sky 10))
                                          #f)
                              out))))))))

;;; --- the sprites --------------------------------------------------------------

(define (doom-lite--imp-blocks sx sh sw y0 hurt)
  (let* ((body-h (quotient (* sh 70) 100))
         (head-h (max 1 (quotient (* sh 30) 100)))
         (head-w (max 1 (quotient (* sw 55) 100)))
         (eye-w (max 1 (quotient (* sw 14) 100)))
         (eye-h (max 1 (quotient (* sh 8) 100)))
         (eye-y (+ y0 (quotient (* sh 10) 100)))
         (skin (if hurt "#d05a3a" "#7a4230")))
    (list (doom-lite--rect (- sx (quotient sw 2)) (+ y0 head-h) sw body-h "#5a3226" #f)
          (doom-lite--rect (- sx (quotient head-w 2)) y0 head-w head-h skin #f)
          (doom-lite--rect (- sx (quotient (* sw 26) 100)) eye-y eye-w eye-h "#ffcf3a" #f)
          (doom-lite--rect (+ sx (quotient (* sw 12) 100)) eye-y eye-w eye-h "#ffcf3a" #f))))

(define (doom-lite--item-blocks sx sh sw y0 kind)
  (let ((c (if (equal? kind "health") "#c93a3a" "#3fae63"))
        (bh (max 1 (quotient (* sh 40) 100)))
        (bw (max 1 (quotient (* sw 60) 100))))
    (list (doom-lite--rect (- sx (quotient bw 2)) (+ y0 (quotient (* sh 55) 100)) bw bh c #f)
          (doom-lite--rect (- sx (quotient bw 6)) (+ y0 (quotient (* sh 45) 100))
                      (max 1 (quotient bw 3)) (quotient bh 2) "#f2f2f2" #f))))

;; Project one sprite into screen space. The answer is (TY BLOCKS), or #f
;; when the sprite stands behind the camera or behind a wall.
(define (doom-lite--sprite px py dx dy plx ply w h zbuf ex ey draw)
  (let* ((relx (- ex px))
         (rely (- ey py))
         (det (- (doom-lite--fpm plx dy) (doom-lite--fpm dx ply))))
    (if (= det 0)
        #f
        (let* ((a (- (doom-lite--fpm dy relx) (doom-lite--fpm dx rely)))
               (b (+ (- (doom-lite--fpm ply relx)) (doom-lite--fpm plx rely)))
               (ty (doom-lite--fpd b det)))
          (if (< ty 192)
              #f
              (let* ((tx (doom-lite--fpd a det))
                     (sx (quotient (* w (+ *doom-lite-fp* (doom-lite--fpd tx ty)))
                                   (* 2 *doom-lite-fp*)))
                     (sh (min (* h 4) (quotient (* h *doom-lite-fp*) ty)))
                     (sw (max 1 (quotient (* sh 2) 3)))
                     (y0 (quotient (- h sh) 2)))
                (if (or (< sx (- 0 sw)) (> sx (+ w sw)))
                    #f
                    (let ((z (if (and (>= sx 0) (< sx w)) (nth sx zbuf) (* 99 *doom-lite-fp*))))
                      (if (>= ty z) #f (list ty (draw sx sh sw y0)))))))))))

(define (doom-lite--sprite-pass buf px py dx dy plx ply w h zbuf)
  (let* ((monsters (filter (lambda (m) (doom-lite--get m 'alive))
                           (or (buffer-local buf 'doom-lite-monsters) '())))
         (items (filter (lambda (i) (doom-lite--get i 'alive))
                        (or (buffer-local buf 'doom-lite-items) '())))
         (hurt-until (or (buffer-local buf 'doom-lite-hurt-until) 0))
         (tick (or (buffer-local buf 'doom-lite-tick) 0))
         (pairs
          (append
            (map (lambda (m)
                   (doom-lite--sprite px py dx dy plx ply w h zbuf
                                 (doom-lite--get m 'x) (doom-lite--get m 'y)
                                 (lambda (sx sh sw y0)
                                   (doom-lite--imp-blocks sx sh sw y0
                                     (> (doom-lite--get m 'hurt 0) tick)))))
                 monsters)
            (map (lambda (i)
                   (doom-lite--sprite px py dx dy plx ply w h zbuf
                                 (doom-lite--get i 'x) (doom-lite--get i 'y)
                                 (lambda (sx sh sw y0)
                                   (doom-lite--item-blocks sx sh sw y0
                                     (doom-lite--get i 'kind "ammo")))))
                 items))))
    (fold (lambda (acc p) (append acc (nth 1 p)))
          '()
          (reverse (sort (filter (lambda (p) p) pairs))))))

;;; --- the gun ------------------------------------------------------------------

(define (doom-lite--gun-blocks firing)
  (let ((barrel "#4a4a52")
        (stock "#6b4a2a"))
    (list 'tag "svg" 'class "doom-lite-gun-svg"
          'attrs (list (list "viewBox" "0 0 100 40")
                       (list "preserveAspectRatio" "xMidYMax meet"))
          'children
          (doom-lite--kids
            (list (doom-lite--rect 44 14 12 26 barrel #f)
                  (doom-lite--rect 46 6 8 10 barrel #f)
                  (doom-lite--rect 38 26 24 14 stock #f)
                  (doom-lite--rect 47 2 6 5 "#8a8a94" #f)
                  (if firing
                      (list (doom-lite--rect 44 0 12 5 "#ffd24a" #f)
                            (doom-lite--rect 47 0 6 3 "#fff6c0" #f))
                      '()))))))

;;; --- the head-up display ------------------------------------------------------

(define (doom-lite--hud buf)
  (let* ((health (or (buffer-local buf 'doom-lite-health) 0))
         (ammo (or (buffer-local buf 'doom-lite-ammo) 0))
         (kills (or (buffer-local buf 'doom-lite-kills) 0))
         (total (length (or (buffer-local buf 'doom-lite-monsters) '())))
         (msg (or (buffer-local buf 'doom-lite-message) "")))
    (doom-lite--div "doom-lite-hud"
      (doom-lite--txt "doom-lite-label" "health")
      (doom-lite--txt (if (< health 34) "doom-lite-crit" "doom-lite-ok") (number->string health))
      (doom-lite--txt "doom-lite-label" "ammo")
      (doom-lite--txt "doom-lite-ammo" (number->string ammo))
      (doom-lite--txt "doom-lite-label" "kills")
      (doom-lite--txt "doom-lite-ok" (string-append (number->string kills) "/"
                                          (number->string total)))
      (doom-lite--txt "doom-lite-spacer" "")
      (doom-lite--txt "doom-lite-msg" msg))))

;;; --- one frame ----------------------------------------------------------------

(define (doom-lite--blocks buf)
  (let* ((w (max 24 doom-lite-columns))
         (h *doom-lite-view-h*)
         (px (or (buffer-local buf 'doom-lite-px) 0))
         (py (or (buffer-local buf 'doom-lite-py) 0))
         (ang (or (buffer-local buf 'doom-lite-angle) 0))
         (tick (or (buffer-local buf 'doom-lite-tick) 0))
         (dx (doom-lite--cos ang))
         (dy (doom-lite--sin ang))
         (plx (quotient (* (- 0 dy) 66) 100))
         (ply (quotient (* dx 66) 100))
         (walls (doom-lite--wall-pass px py dx dy plx ply w h))
         (zbuf (doom-lite--get walls 'z))
         (sprites (doom-lite--sprite-pass buf px py dx dy plx ply w h zbuf))
         (firing (> (or (buffer-local buf 'doom-lite-fire-until) 0) tick))
         (pain (> (or (buffer-local buf 'doom-lite-pain-until) 0) tick))
         (over (buffer-local buf 'doom-lite-over)))
    (list (doom-lite--div "doom-lite-root"
            (doom-lite--div "doom-lite-view"
              (list 'tag "svg" 'class "doom-lite-svg"
                    'attrs (list (list "viewBox"
                                       (string-append "0 0 " (number->string w)
                                                      " " (number->string h)))
                                 (list "preserveAspectRatio" "none"))
                    'children
                    (doom-lite--kids
                      (list (doom-lite--ground w h)
                            (doom-lite--get walls 'blocks)
                            sprites
                            (if pain
                                (doom-lite--rect 0 0 w h "#c0392b" "0.35")
                                '())
                            (if over
                                (doom-lite--rect 0 0 w h "#000000" "0.55")
                                '()))))
              (doom-lite--gun-blocks firing)
              (if over
                  (doom-lite--div "doom-lite-over"
                    (doom-lite--txt "" (if (equal? over "won") "level clear" "you died"))
                    (doom-lite--txt "doom-lite-over-sub" "press r to start again"))
                  '()))
            (doom-lite--hud buf)))))

;;; --- the buffer text ----------------------------------------------------------

;; an 11 by 11 map around the player, so a reader without the blocks view
;; still sees where everything stands
(define (doom-lite--minimap buf)
  (let* ((px (or (buffer-local buf 'doom-lite-px) 0))
         (py (or (buffer-local buf 'doom-lite-py) 0))
         (cx (quotient px *doom-lite-fp*))
         (cy (quotient py *doom-lite-fp*))
         (monsters (filter (lambda (m) (doom-lite--get m 'alive))
                           (or (buffer-local buf 'doom-lite-monsters) '())))
         (items (filter (lambda (i) (doom-lite--get i 'alive))
                        (or (buffer-local buf 'doom-lite-items) '())))
         (at? (lambda (xs x y)
                (let loop ((xs xs))
                  (cond ((null? xs) #f)
                        ((and (= (quotient (doom-lite--get (car xs) 'x) *doom-lite-fp*) x)
                              (= (quotient (doom-lite--get (car xs) 'y) *doom-lite-fp*) y)) #t)
                        (else (loop (cdr xs))))))))
    (let rows ((dy -5) (out '()))
      (if (> dy 5)
          (reverse out)
          (let ((y (+ cy dy)))
            (rows (+ dy 1)
                  (cons (let cols ((dx -5) (line ""))
                          (if (> dx 5)
                              line
                              (let ((x (+ cx dx)))
                                (cols (+ dx 1)
                                      (string-append
                                        line
                                        (cond ((and (= x cx) (= y cy)) "@")
                                              ((at? monsters x y) "M")
                                              ((at? items x y) "+")
                                              ((doom-lite--wall? x y) "#")
                                              (else ".")))))))
                        out)))))))

(define (doom-lite--text buf)
  (let* ((health (or (buffer-local buf 'doom-lite-health) 0))
         (ammo (or (buffer-local buf 'doom-lite-ammo) 0))
         (kills (or (buffer-local buf 'doom-lite-kills) 0))
         (total (length (or (buffer-local buf 'doom-lite-monsters) '())))
         (ang (or (buffer-local buf 'doom-lite-angle) 0))
         (over (buffer-local buf 'doom-lite-over))
         (msg (or (buffer-local buf 'doom-lite-message) "")))
    (string-join
      (append
        (list (string-append "DOOM LITE   health " (number->string health)
                             "   ammo " (number->string ammo)
                             "   kills " (number->string kills) "/"
                             (number->string total)
                             "   facing " (number->string ang))
              "")
        (doom-lite--minimap buf)
        (list ""
              (if over
                  (string-append (if (equal? over "won") "LEVEL CLEAR" "YOU DIED")
                                 " - r starts again")
                  msg)
              "w a s d move, arrows turn, SPC fires, r restarts, q buries"))
      "\n")))

;;; --- drawing ------------------------------------------------------------------

;; The text changes far less often than the frame, so compare it first. A
;; buffer replacement that changes nothing still costs a revision.
(define (doom-lite--replace-text! buf text)
  (unless (equal? (buffer-local buf 'doom-lite-text) text)
    (buffer-set-local! buf 'doom-lite-text text)
    (buffer-replace-range! buf 0 (buffer-size buf) text)))

(define (doom-lite--render! buf)
  (when (buffer-exists? buf)
    (doom-lite--replace-text! buf (doom-lite--text buf))
    (buffer-set-local! buf 'render-blocks (doom-lite--blocks buf))))

;;; --- starting a game ----------------------------------------------------------

(define (doom-lite--monster x y)
  (list 'x (doom-lite--cell->fp x) 'y (doom-lite--cell->fp y)
        'hp 100 'alive #t 'hurt 0))

(define (doom-lite--item x y kind)
  (list 'x (doom-lite--cell->fp x) 'y (doom-lite--cell->fp y) 'kind kind 'alive #t))

(define (doom-lite--new-game! buf)
  (buffer-set-locals! buf
    (list 'doom-lite-px (doom-lite--cell->fp (nth 0 *doom-lite-start-cell*))
          'doom-lite-py (doom-lite--cell->fp (nth 1 *doom-lite-start-cell*))
          'doom-lite-angle 0
          'doom-lite-health *doom-lite-start-health*
          'doom-lite-ammo *doom-lite-start-ammo*
          'doom-lite-kills 0
          'doom-lite-tick 0
          'doom-lite-over #f
          'doom-lite-message "find the eight monsters"
          'doom-lite-fire-until 0
          'doom-lite-pain-until 0
          'doom-lite-monsters (map (lambda (c) (doom-lite--monster (nth 0 c) (nth 1 c)))
                              *doom-lite-monster-cells*)
          'doom-lite-items (map (lambda (c) (doom-lite--item (nth 0 c) (nth 1 c) (nth 2 c)))
                           *doom-lite-item-cells*))))

;;; --- the player ---------------------------------------------------------------

(define (doom-lite--playing? buf)
  (and (buffer-exists? buf)
       (buffer-derived-mode? buf "doom-lite-mode")
       (not (buffer-local buf 'doom-lite-over))))

;; Move along X and along Y one at a time, so a player who walks into a
;; corner slides along the wall instead of stopping dead.
(define (doom-lite--move! buf mx my)
  (let* ((px (buffer-local buf 'doom-lite-px))
         (py (buffer-local buf 'doom-lite-py))
         (nx (if (doom-lite--open-fp? (+ px mx) py) (+ px mx) px))
         (ny (if (doom-lite--open-fp? nx (+ py my)) (+ py my) py)))
    (buffer-set-locals! buf (list 'doom-lite-px nx 'doom-lite-py ny))
    (doom-lite--pick-up! buf)))

(define (doom-lite--walk! buf sign)
  (when (doom-lite--playing? buf)
    (let* ((ang (buffer-local buf 'doom-lite-angle))
           (step (* sign doom-lite-move-step)))
      (doom-lite--move! buf
                   (doom-lite--fpm (doom-lite--cos ang) step)
                   (doom-lite--fpm (doom-lite--sin ang) step))
      (doom-lite--render! buf))))

(define (doom-lite--strafe! buf sign)
  (when (doom-lite--playing? buf)
    (let* ((ang (buffer-local buf 'doom-lite-angle))
           (step (* sign doom-lite-move-step)))
      (doom-lite--move! buf
                   (doom-lite--fpm (doom-lite--cos (+ ang 64)) step)
                   (doom-lite--fpm (doom-lite--sin (+ ang 64)) step))
      (doom-lite--render! buf))))

(define (doom-lite--turn! buf sign)
  (when (doom-lite--playing? buf)
    (buffer-set-local! buf 'doom-lite-angle
                       (modulo (+ (buffer-local buf 'doom-lite-angle)
                                  (* sign doom-lite-turn-step))
                               256))
    (doom-lite--render! buf)))

;; the squared distance between two fixed point points, in FP squared units
(define (doom-lite--dist2 ax ay bx by)
  (let ((dx (- ax bx)) (dy (- ay by)))
    (+ (* dx dx) (* dy dy))))

(define (doom-lite--pick-up! buf)
  (let* ((px (buffer-local buf 'doom-lite-px))
         (py (buffer-local buf 'doom-lite-py))
         (near (quotient (* *doom-lite-fp* *doom-lite-fp*) 2))
         (taken '()))
    (buffer-set-local! buf 'doom-lite-items
      (map (lambda (i)
             (if (and (doom-lite--get i 'alive)
                      (< (doom-lite--dist2 px py (doom-lite--get i 'x) (doom-lite--get i 'y)) near))
                 (begin (set! taken (cons (doom-lite--get i 'kind "ammo") taken))
                        (doom-lite--put i 'alive #f))
                 i))
           (or (buffer-local buf 'doom-lite-items) '())))
    (for-each
      (lambda (kind)
        (if (equal? kind "health")
            (begin (buffer-set-local! buf 'doom-lite-health
                                      (min 100 (+ (buffer-local buf 'doom-lite-health) 25)))
                   (buffer-set-local! buf 'doom-lite-message "you took a medikit"))
            (begin (buffer-set-local! buf 'doom-lite-ammo
                                      (+ (buffer-local buf 'doom-lite-ammo) 25))
                   (buffer-set-local! buf 'doom-lite-message "you took a shell box"))))
      taken)))

;;; --- firing -------------------------------------------------------------------

;; The shot goes down the middle of the view. A monster is hit when its
;; sprite covers the middle column and no wall stands in front of it.
(define (doom-lite--target buf)
  (let* ((w (max 24 doom-lite-columns))
         (h *doom-lite-view-h*)
         (px (buffer-local buf 'doom-lite-px))
         (py (buffer-local buf 'doom-lite-py))
         (ang (buffer-local buf 'doom-lite-angle))
         (dx (doom-lite--cos ang))
         (dy (doom-lite--sin ang))
         (plx (quotient (* (- 0 dy) 66) 100))
         (ply (quotient (* dx 66) 100))
         (wall (nth 0 (doom-lite--cast px py dx dy)))
         (mid (quotient w 2)))
    (let loop ((ms (or (buffer-local buf 'doom-lite-monsters) '()))
               (i 0) (best #f) (best-ty 0))
      (if (null? ms)
          best
          (let* ((m (car ms))
                 (relx (- (doom-lite--get m 'x) px))
                 (rely (- (doom-lite--get m 'y) py))
                 (det (- (doom-lite--fpm plx dy) (doom-lite--fpm dx ply)))
                 (a (- (doom-lite--fpm dy relx) (doom-lite--fpm dx rely)))
                 (b (+ (- (doom-lite--fpm ply relx)) (doom-lite--fpm plx rely)))
                 (ty (if (= det 0) 0 (doom-lite--fpd b det)))
                 (tx (if (= det 0) 0 (doom-lite--fpd a det)))
                 (sx (if (> ty 0)
                         (quotient (* w (+ *doom-lite-fp* (doom-lite--fpd tx ty)))
                                   (* 2 *doom-lite-fp*))
                         -999))
                 (sh (if (> ty 0) (quotient (* h *doom-lite-fp*) ty) 0))
                 (half (max 1 (quotient (quotient (* sh 2) 3) 2)))
                 (hit? (and (doom-lite--get m 'alive)
                            (> ty 192)
                            (< ty wall)
                            (< (abs (- sx mid)) half))))
            (if (and hit? (or (not best) (< ty best-ty)))
                (loop (cdr ms) (+ i 1) i ty)
                (loop (cdr ms) (+ i 1) best best-ty)))))))

(define (doom-lite--damage-monster! buf index amount)
  (let ((kills 0))
    (buffer-set-local! buf 'doom-lite-monsters
      (let loop ((ms (or (buffer-local buf 'doom-lite-monsters) '())) (i 0) (out '()))
        (cond ((null? ms) (reverse out))
              ((= i index)
               (let* ((m (car ms))
                      (hp (- (doom-lite--get m 'hp 0) amount))
                      (dead (<= hp 0)))
                 (when dead (set! kills 1))
                 (loop (cdr ms) (+ i 1)
                       (cons (doom-lite--put
                               (doom-lite--put
                                 (doom-lite--put m 'hp (max 0 hp))
                                 'alive (not dead))
                               'hurt (+ (or (buffer-local buf 'doom-lite-tick) 0) 2))
                             out))))
              (else (loop (cdr ms) (+ i 1) (cons (car ms) out))))))
    (when (= kills 1)
      (buffer-set-local! buf 'doom-lite-kills (+ (buffer-local buf 'doom-lite-kills) 1)))
    kills))

(define (doom-lite--fire! buf)
  (when (doom-lite--playing? buf)
    (let ((ammo (buffer-local buf 'doom-lite-ammo))
          (tick (or (buffer-local buf 'doom-lite-tick) 0)))
      (if (<= ammo 0)
          (buffer-set-local! buf 'doom-lite-message "out of shells")
          (let ((target (doom-lite--target buf)))
            (buffer-set-locals! buf
              (list 'doom-lite-ammo (- ammo 1) 'doom-lite-fire-until (+ tick 2)))
            (if target
                (let ((killed (doom-lite--damage-monster! buf target 40)))
                  (buffer-set-local! buf 'doom-lite-message
                                     (if (= killed 1) "monster down" "you hit it")))
                (buffer-set-local! buf 'doom-lite-message "you missed"))
            (doom-lite--check-over! buf))))
    (doom-lite--render! buf)))

(define (doom-lite--check-over! buf)
  (cond ((<= (buffer-local buf 'doom-lite-health) 0)
         (buffer-set-locals! buf (list 'doom-lite-over "died" 'doom-lite-health 0)))
        ((null? (filter (lambda (m) (doom-lite--get m 'alive))
                        (or (buffer-local buf 'doom-lite-monsters) '())))
         (buffer-set-local! buf 'doom-lite-over "won"))))

;;; --- the monsters -------------------------------------------------------------

;; A monster walks toward the player when the player is inside twelve
;; cells, and bites when it stands within one cell.
(define (doom-lite--monsters-move! buf)
  (let* ((px (buffer-local buf 'doom-lite-px))
         (py (buffer-local buf 'doom-lite-py))
         (tick (buffer-local buf 'doom-lite-tick))
         (bite 0)
         (step 48)
         (sight (* 12 *doom-lite-fp*)))
    (buffer-set-local! buf 'doom-lite-monsters
      (map (lambda (m)
             (if (not (doom-lite--get m 'alive))
                 m
                 (let* ((mx (doom-lite--get m 'x))
                        (my (doom-lite--get m 'y))
                        (dx (- px mx))
                        (dy (- py my))
                        (reach (+ (abs dx) (abs dy))))
                   (cond
                     ((< reach (quotient (* 3 *doom-lite-fp*) 2))
                      (when (= (modulo tick 5) 0) (set! bite (+ bite 7)))
                      m)
                     ((> reach sight) m)
                     (else
                       (let* ((sx (cond ((> dx step) step)
                                        ((< dx (- 0 step)) (- 0 step))
                                        (else 0)))
                              (sy (cond ((> dy step) step)
                                        ((< dy (- 0 step)) (- 0 step))
                                        (else 0)))
                              (nx (if (doom-lite--open-fp? (+ mx sx) my) (+ mx sx) mx))
                              (ny (if (doom-lite--open-fp? nx (+ my sy)) (+ my sy) my)))
                         (doom-lite--put (doom-lite--put m 'x nx) 'y ny)))))))
           (or (buffer-local buf 'doom-lite-monsters) '())))
    (when (> bite 0)
      (buffer-set-locals! buf
        (list 'doom-lite-health (max 0 (- (buffer-local buf 'doom-lite-health) bite))
              'doom-lite-pain-until (+ tick 2)
              'doom-lite-message "a monster bit you"))
      (doom-lite--check-over! buf))))

;;; --- the tick -----------------------------------------------------------------

(define (doom-lite--arm! buf ms)
  (debounce! (string-append "doom-lite-tick:" buf) ms doom-lite--tick buf))

(define (doom-lite--tick buf)
  (when (and (buffer-exists? buf) (buffer-derived-mode? buf "doom-lite-mode"))
    (if (and (window-showing buf) (not (buffer-local buf 'doom-lite-over)))
        (begin
          (buffer-set-local! buf 'doom-lite-tick (+ (or (buffer-local buf 'doom-lite-tick) 0) 1))
          (doom-lite--monsters-move! buf)
          (doom-lite--render! buf)
          (doom-lite--arm! buf doom-lite-tick-ms))
        (doom-lite--arm! buf (* 8 doom-lite-tick-ms)))))

;;; --- the mode -----------------------------------------------------------------

(define *doom-lite-runtime-locals* '(render-blocks doom-lite-text))

(define (doom-lite--setup! buf)
  (buffer-set-read-only! buf #t)
  (buffer-set-local! buf 'render-mode "blocks")
  (for-each (lambda (k) (desktop-skip! buf k)) *doom-lite-runtime-locals*)
  (unless (buffer-local buf 'doom-lite-px) (doom-lite--new-game! buf))
  (doom-lite--render! buf)
  (doom-lite--arm! buf doom-lite-tick-ms))

(mode-icon! "doom-lite-mode" "☠")

(define-mode "doom-lite-mode"
  (lambda () (doom-lite--setup! (current-buffer))))

(mode-keys! "doom-lite-mode"
  '(("w" "doom-lite-forward")
    ("s" "doom-lite-back")
    ("a" "doom-lite-strafe-left")
    ("d" "doom-lite-strafe-right")
    ("<up>" "doom-lite-forward")
    ("<down>" "doom-lite-back")
    ("<left>" "doom-lite-turn-left")
    ("<right>" "doom-lite-turn-right")
    ("," "doom-lite-turn-left")
    ("." "doom-lite-turn-right")
    ("SPC" "doom-lite-fire")
    ("f" "doom-lite-fire")
    ("r" "doom-lite-restart")
    ("q" "quit-window")))

(mode-doc! "doom-lite-mode"
  "A first-person shooter in a buffer. w and s walk, a and d strafe, the left and right arrows turn, SPC fires, r starts the level again. Kill the eight monsters before they kill you. The blocks view draws the level; the text holds a small map and the status line.")

(define-style! 'doom-lite "
.doom-lite-root { position: relative; display: flex; flex-direction: column; height: 100%; min-height: 260px; background: #05050a; }
.doom-lite-view { position: relative; flex: 1; min-height: 200px; overflow: hidden; }
.doom-lite-svg { position: absolute; inset: 0; width: 100%; height: 100%; display: block; shape-rendering: crispEdges; }
.doom-lite-gun-svg { position: absolute; left: 0; right: 0; bottom: 0; width: 100%; height: 34%; display: block; }
.doom-lite-over { position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 6px; color: #f0d6a0; font-size: 26px; font-weight: 700; letter-spacing: .22em; text-transform: uppercase; }
.doom-lite-over-sub { font-size: 11px; letter-spacing: .18em; color: #b09a78; font-weight: 500; }
.doom-lite-hud { display: flex; align-items: baseline; gap: 10px; padding: 6px 12px; border-top: 1px solid var(--border-bg); background: #0d0d14; font-size: 11px; letter-spacing: .16em; text-transform: uppercase; font-weight: 600; }
.doom-lite-label { color: #6a6a7a; }
.doom-lite-ok { color: #7fd08a; }
.doom-lite-crit { color: #e2564a; }
.doom-lite-ammo { color: #e8b64a; }
.doom-lite-spacer { flex: 1; }
.doom-lite-msg { color: #9a9ab0; letter-spacing: .1em; text-transform: none; font-weight: 500; }
")

;;; --- the commands -------------------------------------------------------------

;;;###autoload
(define-command "doom-lite" "Play Doom in a buffer"
  (lambda ()
    (buffer-create *doom-lite-buffer*)
    (switch-to-buffer! *doom-lite-buffer*)
    (unless (buffer-derived-mode? *doom-lite-buffer* "doom-lite-mode")
      (set-mode! "doom-lite-mode"))))

(define-command "doom-lite-forward" "Walk forward"
  (lambda () (doom-lite--walk! (current-buffer) 1)))

(define-command "doom-lite-back" "Walk backward"
  (lambda () (doom-lite--walk! (current-buffer) -1)))

(define-command "doom-lite-strafe-left" "Step to the left"
  (lambda () (doom-lite--strafe! (current-buffer) -1)))

(define-command "doom-lite-strafe-right" "Step to the right"
  (lambda () (doom-lite--strafe! (current-buffer) 1)))

(define-command "doom-lite-turn-left" "Turn to the left"
  (lambda () (doom-lite--turn! (current-buffer) -1)))

(define-command "doom-lite-turn-right" "Turn to the right"
  (lambda () (doom-lite--turn! (current-buffer) 1)))

(define-command "doom-lite-fire" "Fire the shotgun"
  (lambda () (doom-lite--fire! (current-buffer))))

(define-command "doom-lite-restart" "Start the level again"
  (lambda ()
    (let ((buf (current-buffer)))
      (when (buffer-derived-mode? buf "doom-lite-mode")
        (doom-lite--new-game! buf)
        (doom-lite--render! buf)
        (doom-lite--arm! buf 0)))))
