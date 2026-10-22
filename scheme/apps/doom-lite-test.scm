;;; doom-lite-test.scm --- the game mechanism: the caster, the player, the monsters.
;;;
;;; The tests call the commands and the game functions and read the state
;;; back. No test names a key: a binding is a preference, and doom-lite-mode's
;;; keys can move without breaking the game.

(domain! 'testing)
(effects! '(write))

(define *doom-lite-test-buffer* "*zz-doom-lite*")

;; a buffer in doom-lite-mode with a new game in it
(define (doom-lite-test-start!)
  (test-buffer! *doom-lite-test-buffer* "")
  (delete-other-windows!)
  (switch-to-buffer! *doom-lite-test-buffer*)
  (set-mode! "doom-lite-mode")
  (doom-lite--new-game! *doom-lite-test-buffer*)
  (doom-lite--render! *doom-lite-test-buffer*)
  *doom-lite-test-buffer*)

(define (doom-lite-test-end! buf) (buffer-kill! buf))

;; every rect the render blocks hold, at any depth
(define (doom-lite-test-rect-count b)
  (fold (lambda (acc c) (+ acc (doom-lite-test-rect-count c)))
        (if (equal? (doom-lite--get b 'tag) "rect") 1 0)
        (doom-lite--get b 'children '())))

(define (doom-lite-test-rects blocks)
  (fold (lambda (acc b) (+ acc (doom-lite-test-rect-count b))) 0 blocks))

;;; --- the caster ---------------------------------------------------------------

(deftest 'the-caster-stops-at-a-wall-and-names-it
  "a ray from an open cell meets a wall, and reports its byte and a distance"
  (lambda ()
    ;; cell (4 6) sits in the open row 6; due east the ray crosses the map
    (let* ((px (doom-lite--cell->fp 4))
           (py (doom-lite--cell->fp 6))
           (hit (doom-lite--cast px py 1024 0)))
      (check-true! (> (nth 0 hit) 0) "the wall stands at a positive distance")
      (check-true! (< (nth 0 hit) (* *doom-lite-max-steps* *doom-lite-fp*))
                   "and the ray found it before it gave up")
      (check-false! (= (nth 2 hit) 32) "the byte it reports is a wall, not floor"))))

(deftest 'the-caster-answers-a-nearer-wall-for-a-nearer-cell
  "walk toward a wall and the distance the caster reports falls"
  (lambda ()
    (let* ((py (doom-lite--cell->fp 6))
           (far (nth 0 (doom-lite--cast (doom-lite--cell->fp 4) py 1024 0)))
           (near (nth 0 (doom-lite--cast (doom-lite--cell->fp 10) py 1024 0))))
      (check-true! (< near far) "the wall is nearer from the nearer cell"))))

(deftest 'a-wall-is-a-wall-and-a-space-is-floor
  "the map reader answers the level, and outside the level is solid"
  (lambda ()
    (check-true! (doom-lite--wall? 0 0) "the border is a wall")
    (check-false! (doom-lite--wall? 4 6) "the start cell is floor")
    (check-true! (doom-lite--wall? -1 6) "west of the map is solid")
    (check-true! (doom-lite--wall? 99 6) "east of the map is solid")))

;;; --- the frame ----------------------------------------------------------------

(deftest 'the-renderer-draws-one-column-per-ray
  "the wall pass answers one rect and one distance for each column"
  (lambda ()
    (let* ((w 40)
           (pass (doom-lite--wall-pass (doom-lite--cell->fp 4) (doom-lite--cell->fp 6)
                                  1024 0 (quotient (* 0 66) 100) (quotient (* 1024 66) 100)
                                  w *doom-lite-view-h*)))
      (check-equal! (length (doom-lite--get pass 'blocks)) w "one rect per column")
      (check-equal! (length (doom-lite--get pass 'z)) w "one distance per column")
      (check-true! (fold (lambda (ok d) (and ok (> d 0))) #t (doom-lite--get pass 'z))
                   "and every distance is positive"))))

(deftest 'the-mode-fills-the-buffer-with-a-frame-and-a-map
  "starting the game gives the buffer text a status line and render blocks"
  (lambda ()
    (let ((buf (doom-lite-test-start!)))
      (check-true! (string-contains? (buffer-text buf) "DOOM LITE") "the text names the game")
      (check-true! (string-contains? (buffer-text buf) "health 100")
                   "and it shows the starting health")
      (check-true! (string-contains? (buffer-text buf) "@")
                   "and the small map shows the player")
      (check-true! (> (doom-lite-test-rects (buffer-local buf 'render-blocks)) 40)
                   "the blocks hold the columns of the view")
      (doom-lite-test-end! buf))))

;;; --- the player ---------------------------------------------------------------

(deftest 'a-wall-stops-the-player
  "walking into a wall leaves the player where they stood"
  (lambda ()
    (let ((buf (doom-lite-test-start!)))
      ;; face west and walk into the border of the level
      (buffer-set-locals! buf (list 'doom-lite-px (doom-lite--cell->fp 1)
                                    'doom-lite-py (doom-lite--cell->fp 6)
                                    'doom-lite-angle 128))
      (let loop ((i 0)) (when (< i 12) (doom-lite--walk! buf 1) (loop (+ i 1))))
      (check-true! (doom-lite--open-fp? (buffer-local buf 'doom-lite-px) (buffer-local buf 'doom-lite-py))
                   "the player still stands on floor")
      (check-true! (>= (quotient (buffer-local buf 'doom-lite-px) *doom-lite-fp*) 1)
                   "and never crossed the west wall")
      (doom-lite-test-end! buf))))

(deftest 'walking-forward-moves-the-player
  "an open direction lets the player through"
  (lambda ()
    (let ((buf (doom-lite-test-start!)))
      (buffer-set-locals! buf (list 'doom-lite-px (doom-lite--cell->fp 4)
                                    'doom-lite-py (doom-lite--cell->fp 6)
                                    'doom-lite-angle 0))
      (let ((before (buffer-local buf 'doom-lite-px)))
        (doom-lite--walk! buf 1)
        (check-true! (> (buffer-local buf 'doom-lite-px) before) "the player moved east"))
      (doom-lite-test-end! buf))))

(deftest 'turning-keeps-the-angle-inside-the-circle
  "the turn commands answer an angle in 0 to 255"
  (lambda ()
    (let ((buf (doom-lite-test-start!)))
      (buffer-set-local! buf 'doom-lite-angle 0)
      (doom-lite--turn! buf -1)
      (check-true! (and (>= (buffer-local buf 'doom-lite-angle) 0)
                        (< (buffer-local buf 'doom-lite-angle) 256))
                   "turning left past zero stays in the circle")
      (let loop ((i 0)) (when (< i 40) (doom-lite--turn! buf 1) (loop (+ i 1))))
      (check-true! (and (>= (buffer-local buf 'doom-lite-angle) 0)
                        (< (buffer-local buf 'doom-lite-angle) 256))
                   "and so does turning right past the top")
      (doom-lite-test-end! buf))))

(deftest 'the-player-picks-up-what-they-walk-over
  "standing on a medikit raises health and takes the item off the map"
  (lambda ()
    (let ((buf (doom-lite-test-start!)))
      (buffer-set-locals! buf
        (list 'doom-lite-px (doom-lite--cell->fp 4) 'doom-lite-py (doom-lite--cell->fp 6)
              'doom-lite-health 50
              'doom-lite-items (list (doom-lite--item 4 6 "health"))))
      (doom-lite--pick-up! buf)
      (check-equal! (buffer-local buf 'doom-lite-health) 75 "the medikit healed the player")
      (check-equal! (length (filter (lambda (i) (doom-lite--get i 'alive))
                                    (buffer-local buf 'doom-lite-items)))
                    0 "and the item is gone from the map")
      (doom-lite-test-end! buf))))

;;; --- firing -------------------------------------------------------------------

(deftest 'a-shot-in-front-of-a-monster-hits-it
  "the shot costs a shell, wounds the monster, and three shots kill it"
  (lambda ()
    (let ((buf (doom-lite-test-start!)))
      (buffer-set-locals! buf
        (list 'doom-lite-px (doom-lite--cell->fp 4) 'doom-lite-py (doom-lite--cell->fp 6)
              'doom-lite-angle 0 'doom-lite-ammo 10
              'doom-lite-monsters (list (doom-lite--monster 8 6))))
      (doom-lite--fire! buf)
      (check-equal! (buffer-local buf 'doom-lite-ammo) 9 "the shot cost one shell")
      (check-equal! (doom-lite--get (car (buffer-local buf 'doom-lite-monsters)) 'hp) 60
                    "and it wounded the monster")
      (doom-lite--fire! buf)
      (doom-lite--fire! buf)
      (check-false! (doom-lite--get (car (buffer-local buf 'doom-lite-monsters)) 'alive)
                    "three shots kill it")
      (check-equal! (buffer-local buf 'doom-lite-kills) 1 "the kill count rose")
      (check-equal! (buffer-local buf 'doom-lite-over) "won" "and the level is clear")
      (doom-lite-test-end! buf))))

(deftest 'a-shot-with-the-monster-behind-the-player-misses
  "the shot goes where the player looks"
  (lambda ()
    (let ((buf (doom-lite-test-start!)))
      (buffer-set-locals! buf
        (list 'doom-lite-px (doom-lite--cell->fp 4) 'doom-lite-py (doom-lite--cell->fp 6)
              'doom-lite-angle 128 'doom-lite-ammo 10
              'doom-lite-monsters (list (doom-lite--monster 8 6))))
      (doom-lite--fire! buf)
      (check-equal! (doom-lite--get (car (buffer-local buf 'doom-lite-monsters)) 'hp) 100
                    "the monster behind the player is unhurt")
      (check-equal! (buffer-local buf 'doom-lite-message) "you missed" "and the shot missed")
      (doom-lite-test-end! buf))))

(deftest 'an-empty-gun-fires-nothing
  "with no shells the shot does not happen"
  (lambda ()
    (let ((buf (doom-lite-test-start!)))
      (buffer-set-locals! buf
        (list 'doom-lite-px (doom-lite--cell->fp 4) 'doom-lite-py (doom-lite--cell->fp 6)
              'doom-lite-angle 0 'doom-lite-ammo 0
              'doom-lite-monsters (list (doom-lite--monster 8 6))))
      (doom-lite--fire! buf)
      (check-equal! (buffer-local buf 'doom-lite-ammo) 0 "the count stays at zero")
      (check-equal! (doom-lite--get (car (buffer-local buf 'doom-lite-monsters)) 'hp) 100
                    "and the monster is unhurt")
      (doom-lite-test-end! buf))))

;;; --- the monsters -------------------------------------------------------------

(deftest 'a-monster-walks-toward-the-player
  "a monster inside its sight closes the distance"
  (lambda ()
    (let ((buf (doom-lite-test-start!)))
      (buffer-set-locals! buf
        (list 'doom-lite-px (doom-lite--cell->fp 4) 'doom-lite-py (doom-lite--cell->fp 6)
              'doom-lite-tick 1
              'doom-lite-monsters (list (doom-lite--monster 12 6))))
      (let ((before (doom-lite--get (car (buffer-local buf 'doom-lite-monsters)) 'x)))
        (doom-lite--monsters-move! buf)
        (check-true! (< (doom-lite--get (car (buffer-local buf 'doom-lite-monsters)) 'x) before)
                     "the monster came west, toward the player"))
      (doom-lite-test-end! buf))))

(deftest 'a-monster-that-reaches-the-player-bites
  "health falls when a monster stands next to the player"
  (lambda ()
    (let ((buf (doom-lite-test-start!)))
      (buffer-set-locals! buf
        (list 'doom-lite-px (doom-lite--cell->fp 4) 'doom-lite-py (doom-lite--cell->fp 6)
              'doom-lite-tick 5 'doom-lite-health 100
              'doom-lite-monsters (list (doom-lite--monster 4 6))))
      (doom-lite--monsters-move! buf)
      (check-true! (< (buffer-local buf 'doom-lite-health) 100) "the bite hurt the player")
      (doom-lite-test-end! buf))))

(deftest 'the-game-ends-when-the-player-dies
  "health at zero closes the game and the player stops moving"
  (lambda ()
    (let ((buf (doom-lite-test-start!)))
      (buffer-set-locals! buf
        (list 'doom-lite-px (doom-lite--cell->fp 4) 'doom-lite-py (doom-lite--cell->fp 6)
              'doom-lite-angle 0 'doom-lite-tick 5 'doom-lite-health 5
              'doom-lite-monsters (list (doom-lite--monster 4 6))))
      (doom-lite--monsters-move! buf)
      (check-equal! (buffer-local buf 'doom-lite-health) 0 "the last bite took it all")
      (check-equal! (buffer-local buf 'doom-lite-over) "died" "the game is over")
      (let ((before (buffer-local buf 'doom-lite-px)))
        (doom-lite--walk! buf 1)
        (check-equal! (buffer-local buf 'doom-lite-px) before "and a dead player stays put"))
      (doom-lite-test-end! buf))))

;;; --- the lifecycle ------------------------------------------------------------

(deftest 'restarting-gives-a-whole-new-level
  "the restart command puts back the health, the shells and the monsters"
  (lambda ()
    (let ((buf (doom-lite-test-start!)))
      (buffer-set-locals! buf (list 'doom-lite-health 3 'doom-lite-ammo 0 'doom-lite-kills 6
                                    'doom-lite-over "died"))
      (doom-lite--new-game! buf)
      (check-equal! (buffer-local buf 'doom-lite-health) 100 "health is full again")
      (check-equal! (buffer-local buf 'doom-lite-ammo) 50 "the shells are back")
      (check-equal! (buffer-local buf 'doom-lite-kills) 0 "the kill count is zero")
      (check-false! (buffer-local buf 'doom-lite-over) "and the game is open")
      (check-equal! (length (filter (lambda (m) (doom-lite--get m 'alive))
                                    (buffer-local buf 'doom-lite-monsters)))
                    (length *doom-lite-monster-cells*) "every monster stands again")
      (doom-lite-test-end! buf))))

