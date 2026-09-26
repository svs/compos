;;; theme-test.scm --- faces and themes: what a theme owns, what a default owns.

(domain! 'testing)
(effects! '(write))

(define (theme-test-face-attr face attr)
  (face-attribute face attr))

(define (theme-test-restore!)
  (load-theme "compos-dark"))

;; two small themes that name the same face with different attribute sets
(define-theme "tt-theme-a" (list (list 'tt-face 'fg "#111111" 'bg "#eeeeee")))
(define-theme "tt-theme-b" (list (list 'tt-face 'fg "#222222")))

(deftest 'load-theme-clears-an-attribute-the-next-theme-does-not-set
  "theme A sets fg and bg; theme B sets fg only; after B the bg is gone"
  (lambda ()
    (load-theme "tt-theme-a")
    (check-equal! (theme-test-face-attr 'tt-face 'bg) "#eeeeee" "A set the background")
    (load-theme "tt-theme-b")
    (check-equal! (theme-test-face-attr 'tt-face 'fg) "#222222" "B set the foreground")
    (check-false! (theme-test-face-attr 'tt-face 'bg) "B does not name bg, so it is unset")
    (theme-test-restore!)))

(deftest 'defface-applies-the-attributes-the-theme-does-not-name
  "the theme names the colour, the package names the weight, and both hold"
  (lambda ()
    (load-theme "tt-theme-b")
    (defface! 'tt-face 'fg "#999999" 'weight "700")
    (check-equal! (theme-test-face-attr 'tt-face 'fg) "#222222" "the theme keeps its colour")
    (check-equal! (theme-test-face-attr 'tt-face 'weight) "700" "the default supplies the weight")
    ;; and the next load keeps the default under the theme
    (load-theme "tt-theme-a")
    (check-equal! (theme-test-face-attr 'tt-face 'weight) "700" "load-theme reapplies the default")
    (check-equal! (theme-test-face-attr 'tt-face 'fg) "#111111" "and the theme wins the colour")
    (theme-test-restore!)))

(deftest 'the-default-face-size-is-the-setting-and-survives-a-theme
  "buffer text reads at default-font-size in every theme"
  (lambda ()
    (check-equal! (theme-test-face-attr 'default 'size) default-font-size
                  "the default face carries the setting")
    (load-theme "tt-theme-a")
    (check-equal! (theme-test-face-attr 'default 'size) default-font-size
                  "a theme load keeps the size: no theme names one")
    (check-equal! default-font-size "20.8px"
                  "the stock size is the reading size")
    (theme-test-restore!)))

(deftest 'an-empty-size-remap-reads-at-the-default-face
  "a prose mode that sets 'size \"\" emits no --default-size: the text inherits default-font-size"
  (lambda ()
    (let ((buf "*tt-empty-size*"))
      (buffer-create buf)
      (face-remap-in! buf 'default (list 'family "Spectral" 'size "" 'line-height "1.7"))
      (let ((style (buffer-local buf 'style)))
        (check-contains! style "--default-family:Spectral;" "the family still emits")
        (check-contains! style "--default-line-height:1.7;" "the line height still emits")
        (check-false! (string-contains? style "--default-size") "the empty size emits nothing"))
      (face-remap-in! buf 'default (list 'size "20px"))
      (check-contains! (buffer-local buf 'style) "--default-size:20px;" "a named size emits")
      (buffer-kill! buf))))

(deftest 'every-bundled-theme-colours-the-headings
  "a heading is never paper's navy on a dark ground: each theme names its own"
  (lambda ()
    (for-each
      (lambda (theme)
        (load-theme theme)
        (for-each
          (lambda (face)
            (let ((fg (theme-test-face-attr face 'fg)))
              (check-true! (string? fg)
                           (string-append theme " colours " (symbol->string face)))
              (unless (equal? theme "paper")
                (check-false! (equal? fg "#26356b")
                              (string-append theme " does not wear paper's navy on " (symbol->string face))))))
          '(org-level-1 org-level-2 org-level-3 org-level-4)))
      '("paper" "compos" "paper-night" "compos-dark" "catppuccin-mocha" "tokyo-night"
        "zenburn" "ascii" "crt" "paperized" "brut" "maharaja"))
    (theme-test-restore!)))

(deftest 'a-theme-preview-shows-faces-and-writes-nothing
  "theme-apply! changes the faces on screen; only load-theme writes the theme file"
  (lambda ()
    (let ((saved (and (file-exists? (theme-file)) (read-file (theme-file)))))
      (check-true! (theme-apply! "tt-theme-a") "a theme applies")
      (check-equal! (theme-test-face-attr 'tt-face 'bg) "#eeeeee" "its faces are on screen")
      (check-equal! *current-theme* "tt-theme-a" "and it is current")
      (check-equal! (and (file-exists? (theme-file)) (read-file (theme-file))) saved
                    "the theme file is as it was: a preview persists nothing")
      (check-false! (theme-apply! "tt-no-such-theme") "no such theme: #f, faces untouched")
      (check-equal! *current-theme* "tt-theme-a" "the current theme stands")
      (theme-test-restore!)
      (check-contains! (read-file (theme-file)) "compos-dark" "load-theme wrote its choice"))))

(deftest 'inherit-and-priority-reach-the-face-table
  "a default may name a parent face and a priority"
  (lambda ()
    (defface! 'tt-child 'inherit 'tt-face 'priority 7)
    (check-equal! (theme-test-face-attr 'tt-child 'inherit) "tt-face" "inherit is stored as the parent's name")
    (check-equal! (theme-test-face-attr 'tt-child 'priority) 7 "priority is stored")
    (face-clear! 'tt-child)
    (check-false! (member "tt-child" (face-list)) "face-clear! forgets the face")))

(deftest 'the-emacs-face-names-inherit-the-compos-faces
  "font-lock-keyword-face draws with ts-keyword, and success with ok"
  (lambda ()
    (check-equal! (theme-test-face-attr 'font-lock-keyword-face 'inherit) "ts-keyword" "keyword")
    (check-equal! (theme-test-face-attr 'success 'inherit) "ok" "success")
    (check-equal! (theme-test-face-attr 'mode-line 'inherit) "modeline" "mode-line")))

(deftest 'a-font-slot-is-a-setting-on-a-face
  "mono-font-family names the family of the 'mono face, which the page reads as --font-mono"
  (lambda ()
    (let ((stock mono-font-family))
      (check-equal! stock "" "the stock slot is empty, so the page keeps its own stack")
      (customize-set! 'mono-font-family "'Fira Code', ui-monospace, monospace")
      (check-equal! (theme-test-face-attr 'mono 'family) "'Fira Code', ui-monospace, monospace"
                    "the setting reaches the face")
      (load-theme "tt-theme-a")
      (check-equal! (theme-test-face-attr 'mono 'family) "'Fira Code', ui-monospace, monospace"
                    "a theme load keeps the font: no theme names a family here")
      (customize-set! 'mono-font-family stock)
      (theme-test-restore!))))

(define (theme-test-channels hex)
  (let* ((digits '(("0" 0) ("1" 1) ("2" 2) ("3" 3) ("4" 4) ("5" 5) ("6" 6) ("7" 7)
                   ("8" 8) ("9" 9) ("a" 10) ("b" 11) ("c" 12) ("d" 13) ("e" 14) ("f" 15)))
         (digit (lambda (s) (let ((hit (assoc (string-downcase s) digits)))
                              (if hit (car (cdr hit)) 0))))
         (byte (lambda (i) (+ (* 16 (digit (substring hex i (+ i 1))))
                              (digit (substring hex (+ i 1) (+ i 2)))))))
    (list (byte 1) (byte 3) (byte 5))))

(define (theme-test-distance a b)
  (let loop ((x (theme-test-channels a)) (y (theme-test-channels b)) (sum 0))
    (if (null? x) sum
        (loop (cdr x) (cdr y) (+ sum (abs (- (car x) (car y))))))))

(deftest 'a-dark-theme-shows-the-row-under-point
  "hl-line stands off the window background, and select and region stand off hl-line"
  (lambda ()
    (for-each
      (lambda (theme)
        (load-theme theme)
        (let ((win (theme-test-face-attr 'window 'bg))
              (hl (theme-test-face-attr 'hl-line 'bg))
              (sel (theme-test-face-attr 'select 'bg))
              (reg (theme-test-face-attr 'region 'bg)))
          (check-true! (> (theme-test-distance win hl) 75)
                       (string-append theme ": the row under point is visible on the window"))
          (check-true! (> (theme-test-distance hl sel) 30)
                       (string-append theme ": a search match is not the row under point"))
          (check-true! (> (theme-test-distance hl reg) 30)
                       (string-append theme ": a selection is not the row under point"))
          (check-true! (> (theme-test-distance sel reg) 20)
                       (string-append theme ": a search match is not a selection"))))
      ;; brut is light, and the same rule holds: a row under point that
      ;; does not stand off the sheet is a row you cannot find
      '("compos" "paper-night" "compos-dark" "catppuccin-mocha" "tokyo-night"
        "zenburn" "ascii" "crt" "brut" "maharaja"))
    (theme-test-restore!)))

;; a theme may carry a stylesheet as well as a palette. It goes on under
;; one name, so the theme you leave takes its CSS with it.
(define-theme "tt-theme-skinned" (list (list 'tt-face 'fg "#333333")))
(define-theme-skin! "tt-theme-skinned" ".tt-probe{color:red}")

(deftest 'a-theme-skin-goes-on-with-the-theme-and-off-with-it
  "the skinned theme installs its CSS; the next theme replaces it with nothing"
  (lambda ()
    (theme-apply! "tt-theme-skinned")
    (check-contains! (style-css 'theme-skin) ".tt-probe" "the skin is on the page")
    (theme-apply! "tt-theme-a")
    (check-equal! (style-css 'theme-skin) "" "a theme with no skin wears no skin")
    (theme-test-restore!)))

(deftest 'the-crazy-themes-carry-their-own-fonts
  "ascii and crt set one font for the whole application; paperized sets a typewriter"
  (lambda ()
    (load-theme "ascii")
    (check-contains! (theme-test-face-attr 'mono 'family) "Menlo" "ascii names the mono stack")
    (check-equal! (theme-test-face-attr 'sans 'inherit) "mono" "and sans is the same font")
    (check-contains! (style-css 'theme-skin) "dashed" "ascii types its rules")
    (load-theme "crt")
    (check-contains! (style-css 'theme-skin) "repeating-linear-gradient" "crt ships its scan lines")
    (load-theme "paperized")
    (check-contains! (theme-test-face-attr 'mono 'family) "Courier Prime" "paperized types")
    (check-contains! (style-css 'theme-skin) "feTurbulence" "paperized ships its fibre")
    (check-false! (theme-dark?) "paperized is a light theme")
    (load-theme "brut")
    (check-contains! (theme-test-face-attr 'sans 'family) "Archivo" "brut sets a grotesque")
    (check-contains! (style-css 'theme-skin) "box-shadow" "brut ships its hard shadows")
    (check-false! (theme-dark?) "brut is a light theme")
    (load-theme "zenburn")
    (check-equal! (style-css 'theme-skin) "" "zenburn is palette only")
    (check-true! (theme-dark?) "zenburn is a dark theme")
    (theme-test-restore!)))

;;; --- the terminal's faces ------------------------------------------------

(define theme-test-ansi-faces
  '(ansi-color-black ansi-color-red ansi-color-green ansi-color-yellow
    ansi-color-blue ansi-color-magenta ansi-color-cyan ansi-color-white
    ansi-color-bright-black ansi-color-bright-red ansi-color-bright-green
    ansi-color-bright-yellow ansi-color-bright-blue ansi-color-bright-magenta
    ansi-color-bright-cyan ansi-color-bright-white))

(deftest 'the-terminal-takes-its-look-from-faces
  "the PTY pane reads faces, so every theme carries a terminal and 16 colours"
  (lambda ()
    (for-each
      (lambda (theme)
        (theme-apply! theme)
        (for-each
          (lambda (attr)
            (check-true! (string? (theme-test-face-attr 'terminal attr))
                         (string-append theme ": the terminal face names "
                                        (symbol->string attr))))
          '(bg fg family size))
        (for-each
          (lambda (face)
            (check-true! (or (string? (theme-test-face-attr face 'fg))
                             (theme-test-face-attr face 'inherit))
                         (string-append theme " colours " (symbol->string face))))
          theme-test-ansi-faces))
      '("paper" "compos" "paper-night" "compos-dark" "catppuccin-mocha" "tokyo-night"
        "zenburn" "ascii" "crt" "paperized" "brut" "maharaja"))
    (theme-test-restore!)))
