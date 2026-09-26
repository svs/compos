;;; themes.scm --- theming, all in userland Scheme.
;;;
;;; The core knows exactly one primitive: (set-face-attribute! face attr val ...).
;;; Everything else — the theme registry, define-theme, load-theme, the
;;; palettes — is Scheme. Faces map to CSS custom properties (--face-attr)
;;; consumed by the frontend.
;;;
;;; Semantic faces: default (bg fg) · window (bg) · modeline (bg fg)
;;;   modeline-active (bg fg) · cursor (bg) · region (bg) · accent (fg)
;;;   dim (fg) · select (bg)

(define *themes* '())

;; A reload re-runs every define-theme in this file. Consing each time
;; listed "ascii" five times in the theme prompt, so a name already in the
;; registry is replaced where it stands and the order never moves.
(define (define-theme name faces)
  (set! *themes*
        (if (assoc name *themes*)
            (map (lambda (t) (if (equal? (car t) name) (list name faces) t))
                 *themes*)
            (cons (list name faces) *themes*))))

;; a theme built on another (dup #33): BASE's faces, with OVERRIDES
;; replacing every face they name. The base must be defined first.
(define (define-theme-from name base overrides)
  (let* ((b (assoc base *themes*))
         (named (map car overrides))
         (kept (filter (lambda (f) (not (member (car f) named)))
                       (if b (car (cdr b)) '()))))
    (define-theme name (append overrides kept))))

;;; --- a theme's own stylesheet ------------------------------------------
;;; Faces carry colour. A skin carries everything a colour cannot say: a
;;; paper grain, an inverted status line, a phosphor glow. The theme owns
;;; it, so `define-style!` writes it under ONE name and a theme without a
;;; skin writes the empty string. The page then holds exactly one skin.

(define *theme-skins* '())              ; ((NAME CSS) ...)

(define (define-theme-skin! name css)
  (set! *theme-skins*
        (cons (list name css)
              (filter (lambda (s) (not (equal? (car s) name))) *theme-skins*))))

;; the CSS NAME wears, or "" for a theme with no skin
(define (theme-skin name)
  (let ((s (assoc name *theme-skins*))) (if s (cadr s) "")))

(define (theme-names) (map car *themes*))

(define (theme-file) (string-append (compos-config-dir) "/theme.scm"))

;; the chosen theme survives daemon restarts as policy, not raw faces:
;; the NAME is written to <home>/theme.scm and re-derived at boot, so
;; theme edits in this file apply on restart instead of stale face values
(define (persist-theme! name)
  (write-file! (theme-file) (string-append "(load-theme \"" name "\")\n")))

;;; --- face defaults ------------------------------------------------------------
;;; A package declares the faces it draws with. The theme owns the color.
;;; `defface!` applies a default only when the current theme does not name
;;; the face, so a package load never overwrites the theme. A package
;;; reload re-runs its declarations; with plain `set-face-attribute!` at
;;; the top level, the package's light color replaced the dark theme's
;;; color every time.

(define *current-theme* #f)
(define *face-defaults* '())            ; ((FACE ATTR VALUE ...) ...)

(define (theme-faces name)
  (let ((t (assoc name *themes*))) (if t (cadr t) '())))

;; #f when no theme is loaded, or when the theme leaves this face alone
(define (theme-face-spec face)
  (assoc face (theme-faces (theme-current))))

;; the value a face wears now, theme first and the package default after,
;; which is the order defface! resolves them in. #f when neither names ATTR.
(define (face-color face attr)
  (let* ((spec (theme-face-spec face))
         (themed (and spec (plist-get (cdr spec) attr))))
    (or themed
        (let ((default (assoc face *face-defaults*)))
          (and default (plist-get (cdr default) attr))))))

(define (theme--hex-digit text at)
  (let ((digit (substring-bytes (string-downcase text) at (+ at 1))))
    (let loop ((digits (string-split "0123456789abcdef" "")) (value 0))
      (cond
        ((null? digits) #f)
        ((equal? (car digits) digit) value)
        (else (loop (cdr digits) (+ value 1)))))))

(define (theme--hex-byte text at)
  (let ((high (theme--hex-digit text at))
        (low (theme--hex-digit text (+ at 1))))
    (and high low (+ (* high 16) low))))

;; Apps cannot read the editor's CSS variables across their origin boundary.
;; Give them the theme's appearance without naming specific palettes.
(define (theme-dark?)
  (let* ((spec (theme-face-spec 'default))
         (background (and spec (plist-get (cdr spec) 'bg))))
    (and (string? background)
         (re-match "^#[0-9A-Fa-f]{6}$" background)
         (let ((red (theme--hex-byte background 1))
               (green (theme--hex-byte background 3))
               (blue (theme--hex-byte background 5)))
           (< (+ (* red 299) (* green 587) (* blue 114)) 128000)))))

;; the keys of a plist (K V K V ...)
(define (theme--plist-keys plist)
  (if (or (null? plist) (null? (cdr plist)))
      '()
      (cons (car plist) (theme--plist-keys (cddr plist)))))

;; the pairs of PLIST whose key is not in KEYS
(define (theme--plist-without plist keys)
  (if (or (null? plist) (null? (cdr plist)))
      '()
      (let ((rest (theme--plist-without (cddr plist) keys)))
        (if (member (car plist) keys)
            rest
            (cons (car plist) (cons (cadr plist) rest))))))

;; A default applies attribute by attribute, as in Emacs: the theme sets
;; the colour of ts-keyword and the package sets its weight, and both
;; hold. Only an attribute the theme names for this face is skipped.
(define (defface! face &rest attrs)
  (set! *face-defaults*
        (cons (cons face attrs)
              (filter (lambda (d) (not (equal? (car d) face))) *face-defaults*)))
  (let* ((spec (theme-face-spec face))
         (named (if spec (theme--plist-keys (cdr spec)) '()))
         (free (theme--plist-without attrs named)))
    (if (null? free)
        #f
        (apply set-face-attribute! (cons face free)))))

;; the members of A, then the members of B that are not in A
(define (theme--union a b)
  (append a (filter (lambda (x) (not (member x a))) b)))

;; put NAME's faces on screen, and nothing else: no file, no message. The
;; theme prompt previews through this as the highlight moves. -> #t, or
;; #f for a name that is no theme
(define (theme--ops t base)
  ;; the face-batch! that takes the faces from BASE's to theme T's
  (append
    (map (lambda (f) (list 'clear f))
         (theme--union (map car *face-defaults*)
                       (theme--union (map car (theme-faces base))
                                     (map car (cadr t)))))
    (map (lambda (d) (cons 'set d)) *face-defaults*)
    (map (lambda (spec) (cons 'set spec)) (cadr t))))

(define (theme-apply! name)
  (let ((t (assoc name *themes*)))
    (and t
         (begin
           ;; a face starts empty: an attribute the last theme set and this
           ;; one does not must not survive. set-face-attribute! merges, so
           ;; every face either theme or a default names is cleared first,
           ;; then the package defaults apply, then the theme on top.
           ;;
           ;; The three passes go to the editor as ONE change (face-batch!).
           ;; Hundreds of single writes each rendered the page, and a
           ;; render between the clear and the defaults showed a default
           ;; face with no size and a 'ui face with no zoom: every window
           ;; reflowed and its scroll moved.
           (face-batch! (theme--ops t *current-theme*))
           (set! *current-theme* name)
           ;; the skin goes on after the faces, always under one name, so
           ;; the theme you leave takes its stylesheet with it
           (define-style! 'theme-skin (theme-skin name))
           (run-hooks 'theme-change-hook)
           #t))))

;; --- a frame's own theme -------------------------------------------------
;; An isolated frame wears its own theme. Its faces are ops the editor
;; replays over the global faces when that frame renders, so the other
;; frames keep the global theme. The name is a frame local, so it survives
;; with the desktop and goes back on when a client attaches.

(define *theme-frame* #f)  ; the frame a render path colours, else the selected one

(define (frame-theme &optional frame)
  ;; the theme FRAME wears on its own, or #f when it wears the global one.
  ;; themes.scm loads before window.scm defines frame locals, and a face
  ;; read at load comes here: until then, every frame wears the global theme.
  (let ((name (and (boundp 'frame-local-in)
                   (frame-local-in (or frame (selected-frame)) 'theme))))
    (and name (assoc name *themes*) name)))

(define (theme-current)
  ;; the theme on screen in the frame being coloured
  (or (frame-theme (or *theme-frame* (selected-frame))) *current-theme*))

(define (with-theme-frame frame thunk)
  ;; THUNK reads faces as FRAME wears them
  (let ((before *theme-frame*))
    (set! *theme-frame* frame)
    (let ((value (thunk)))
      (set! *theme-frame* before)
      value)))

(define (frame-theme--push! frame)
  (let ((name (frame-theme frame)))
    (if name
        (frame-faces-set! (theme--ops (assoc name *themes*) *current-theme*)
                          (theme-skin name) frame)
        (frame-faces-set! #f #f frame))))

(define (frame-theme-apply! name &optional frame)
  ;; FRAME wears NAME on its own; NAME #f gives it the global theme again
  (let ((frame (or frame (selected-frame))))
    (and (or (not name) (assoc name *themes*))
         (begin
           (set-frame-local-in! frame 'theme name)
           (desktop-dirty!)
           (frame-theme--push! frame)
           (run-hooks 'theme-change-hook)
           #t))))

(define (frame-themes-refresh!)
  ;; the global faces moved: each frame theme is replayed over the new ones
  (for-each (lambda (frame) (when (frame-theme frame) (frame-theme--push! frame)))
            (frame-list)))

(define (frame-theme-attach!)
  (when (frame-theme) (frame-theme--push! (selected-frame))))

(add-hook! 'theme-change-hook 'frame-themes-refresh!)
(add-hook! 'frame-attach-hook 'frame-theme-attach!)

(define (theme--isolated? &optional frame)
  ;; FRAME wears its own theme. The boot load of theme.scm runs before
  ;; window.scm defines frame locals: then no frame is isolated.
  (and (boundp 'frame-local-in)
       (frame-local-in (or frame (selected-frame)) 'isolated)))

(define (theme--put! name frame)
  ;; an isolated frame takes the theme alone; any other frame takes it globally
  (if (theme--isolated? frame)
      (frame-theme-apply! name frame)
      (theme-apply! name)))

(define (load-theme name)
  (if (theme--isolated?)
      (if (frame-theme-apply! name)
          (message (string-append "Loaded theme " name " in this frame"))
          (message (string-append "No such theme: " name)))
      (load-theme--global name)))

(define (load-theme--global name)
  (if (theme-apply! name)
      (begin
        (persist-theme! name)
        (message (string-append "Loaded theme " name)))
      (message (string-append "No such theme: " name))))

;;; --- palettes ---------------------------------------------------------------

(define-theme "paper"                ; the design default (light) — restorable
  (list
    ;; every theme must set the ts-* faces: load-theme only writes the
    ;; faces a theme names, so a theme without them keeps the previous
    ;; theme's syntax colors on screen
    (list 'ts-keyword 'fg "#26356b")
    (list 'ts-function 'fg "#1b1a17")
    (list 'ts-string 'fg "#3d6b4f")
    (list 'ts-comment 'fg "#8a857a")
    (list 'ts-number 'fg "#7a5a1a")
    (list 'ts-constant 'fg "#7a5a1a")
    (list 'ts-type 'fg "#7a5a1a")
    (list 'ts-module 'fg "#7a5a1a")
    (list 'ts-operator 'fg "#57534a")
    (list 'ts-punctuation 'fg "#57534a")
    (list 'ts-tag 'fg "#26356b")
    (list 'ts-attribute 'fg "#7a5a1a")
    (list 'ts-variable 'fg "#3b3a35")
    (list 'ts-property 'fg "#57534a")
    (list 'ts-escape 'fg "#7a5a1a")
    (list 'default 'bg "#e6e0d2" 'fg "#1b1a17")
    (list 'window 'bg "#fdfcf8")
    (list 'paper 'bg "#efeadf")
    (list 'body 'fg "#3f3b33")
    (list 'border-soft 'bg "#e2dbc9")
    (list 'window-inactive 'bg "#f4f0e6")
    (list 'modeline 'bg "#eae5da" 'fg "#57534a")
    (list 'modeline-active 'bg "#e7e9f1" 'fg "#1b1a17")
    (list 'cursor 'bg "#26356b")
    (list 'region 'bg "#e7e9f1")
    (list 'accent 'fg "#26356b")
    (list 'link 'fg "#26356b" 'decoration "underline")
    (list 'llm-response 'fg "#26356b" 'style "italic")
    (list 'llm-prompt 'inherit 'llm-response)
    (list 'diff-block 'fg "#7a5a1a" 'style "italic")
    (list 'diff-block-source 'fg "#8a857a" 'style "italic")
    (list 'dim 'fg "#8a857a")
    (list 'select 'bg "#e7e9f1")
    (list 'hl-line 'bg "#f5f1e6")
    (list 'linenum 'fg "#b3ac9c")
    (list 'border 'bg "#cbc4b1")
    (list 'warn 'fg "#7a5a1a")
    ;; the list faces: a column label and a rule are fainter than
    ;; `dim`, and a list says good and bad in one word
    (list 'faint 'fg "#b3ac9c")
    (list 'ok 'fg "#2e6b45")
    (list 'alert 'fg "#a83a2b")
    (list 'org-level-1 'fg "#26356b" 'weight "700")
    (list 'org-level-2 'fg "#7a5a1a" 'weight "600")
    (list 'org-level-3 'fg "#3d6b4f" 'weight "600")
    (list 'org-level-4 'fg "#6b3d5b" 'weight "600")
    ;; the group scale: six colours a group is allotted by slot, told
    ;; apart at a glance and readable against this theme's background
    (list 'group-color-1 'fg "#a4402f")
    (list 'group-color-2 'fg "#26356b")
    (list 'group-color-3 'fg "#3d6b4f")
    (list 'group-color-4 'fg "#6b3d5b")
    (list 'group-color-5 'fg "#7a5a1a")
    (list 'group-color-6 'fg "#1f5f5c")
    (list 'org-todo 'fg "#a03020" 'weight "700")
    (list 'org-done 'fg "#3d6b4f" 'decoration "line-through")
    (list 'org-priority 'fg "#7a5a1a" 'weight "600")
    (list 'org-date 'fg "#26356b" 'style "italic")
    (list 'org-tag 'fg "#8a857a")
    (list 'org-checkbox 'fg "#26356b" 'weight "600")
    (list 'org-cookie 'fg "#7a5a1a")
    (list 'org-meta 'fg "#8a857a")
    (list 'fold-marker 'fg "#8a857a")
    ;; the mail faces: the index columns and the show-view header
    (list 'nm-date 'fg "#676257")
    (list 'nm-author 'fg "#515c86" 'weight "400" 'style "italic")
    (list 'nm-tags 'fg "#64603a")
    (list 'nm-subject 'fg "#4a4741")
    (list 'nm-marked 'fg "#a03020")
    (list 'nm-hdr 'fg "#26356b")
    (list 'nm-sep 'fg "#9a9a72")
    ;; window chrome: gap between panels, rounded cards, soft shadow
    (list 'diff-file 'fg "#26356b" 'weight "600")
    (list 'diff-hunk 'fg "#7a5a1a")
    (list 'diff-add 'fg "#20502f" 'bg "rgba(61, 107, 79, 0.13)")
    (list 'diff-del 'fg "#7d2418" 'bg "rgba(160, 48, 32, 0.11)")
    (list 'diff-add-word 'bg "rgba(61, 107, 79, 0.30)")
    (list 'diff-del-word 'bg "rgba(160, 48, 32, 0.26)")
    (list 'code-scope 'bg "rgba(38, 53, 107, 0.07)")
    ;; shadow lifts the current pane; shadow-deep is the floating one, a
    ;; window that can move (the design's shadow-modal)
    (list 'chrome 'gap "5px" 'radius "0"
          'border "1px solid #cbc4b1"
          'shadow "0 14px 40px rgba(27, 26, 23, 0.13)"
          'shadow-deep "0 22px 60px rgba(27, 26, 23, 0.13)")))

(define-theme "paper-night"          ; the design's warm dark
  (list
    (list 'ts-keyword 'fg "#9fb0ea")
    (list 'ts-function 'fg "#efe9dc")
    (list 'ts-string 'fg "#79bd93")
    (list 'ts-comment 'fg "#a79d8c")
    (list 'ts-number 'fg "#d5ac66")
    (list 'ts-constant 'fg "#d5ac66")
    (list 'ts-type 'fg "#d5ac66")
    (list 'ts-module 'fg "#d5ac66")
    (list 'ts-operator 'fg "#9a9182")
    (list 'ts-punctuation 'fg "#9a9182")
    (list 'ts-tag 'fg "#9fb0ea")
    (list 'ts-attribute 'fg "#d5ac66")
    (list 'ts-variable 'fg "#d8d0c0")
    (list 'ts-property 'fg "#c2b8a3")
    (list 'ts-escape 'fg "#d5ac66")
    ;; the grounds are the design's own: canvas, paper, paper-soft (a
    ;; raised popup), paper-dim (a sunken bar), hl (the selected row)
    (list 'default 'bg "#080807" 'fg "#efe9dc")
    (list 'window 'bg "#23201a")
    (list 'paper 'bg "#1c1a15")
    (list 'body 'fg "#d6cfc0")
    (list 'border-soft 'bg "#37312a")
    (list 'window-inactive 'bg "#1a1813")
    (list 'modeline 'bg "#1c1a15" 'fg "#b3aa99")
    (list 'modeline-active 'bg "#282f4a" 'fg "#efe9dc")
    (list 'cursor 'bg "#9fb0ea")
    (list 'region 'bg "#445281")
    (list 'accent 'fg "#9fb0ea")
    (list 'link 'fg "#9fb0ea" 'decoration "underline")
    (list 'llm-response 'fg "#9fb0ea" 'style "italic")
    (list 'llm-prompt 'inherit 'llm-response)
    (list 'diff-block 'fg "#d5ac66" 'style "italic")
    (list 'diff-block-source 'fg "#a79d8c" 'style "italic")
    (list 'dim 'fg "#a79d8c")
    (list 'select 'bg "#282f4a")
    (list 'hl-line 'bg "#2a251a")
    (list 'linenum 'fg "#4a443a")
    (list 'border 'bg "#4a4238")
    (list 'warn 'fg "#d5ac66")
    ;; the list faces: a column label and a rule are fainter than
    ;; `dim`, and a list says good and bad in one word
    (list 'faint 'fg "#8d8474")
    (list 'ok 'fg "#79bd93")
    (list 'alert 'fg "#e08d78")
    (list 'org-level-1 'fg "#9fb0ea" 'weight "700")
    (list 'org-level-2 'fg "#d5ac66" 'weight "600")
    (list 'org-level-3 'fg "#79bd93" 'weight "600")
    (list 'org-level-4 'fg "#c99ac2" 'weight "600")
    ;; the group scale: six colours a group is allotted by slot, told
    ;; apart at a glance and readable against this theme's background
    (list 'group-color-1 'fg "#e08d78")
    (list 'group-color-2 'fg "#9fb0ea")
    (list 'group-color-3 'fg "#79bd93")
    (list 'group-color-4 'fg "#c99ac2")
    (list 'group-color-5 'fg "#d5ac66")
    (list 'group-color-6 'fg "#7cc3bd")
    (list 'org-todo 'fg "#e0705a" 'weight "700")
    (list 'org-done 'fg "#79bd93" 'decoration "line-through")
    (list 'org-priority 'fg "#d5ac66" 'weight "600")
    (list 'org-date 'fg "#9fb0ea" 'style "italic")
    (list 'org-tag 'fg "#a79d8c")
    (list 'org-checkbox 'fg "#9fb0ea" 'weight "600")
    (list 'org-cookie 'fg "#d5ac66")
    (list 'org-meta 'fg "#a79d8c")
    (list 'fold-marker 'fg "#a79d8c")
    ;; the mail faces: the index columns and the show-view header
    (list 'nm-date 'fg "#a79d8c")
    (list 'nm-author 'fg "#9fb0ea")
    (list 'nm-tags 'fg "#9a9182")
    (list 'nm-marked 'fg "#e08d78")
    (list 'nm-hdr 'fg "#9fb0ea")
    (list 'nm-sep 'fg "#9a9182")
    (list 'diff-file 'fg "#9fb0ea" 'weight "600")
    (list 'diff-hunk 'fg "#d5ac66")
    (list 'diff-add 'fg "#9fd8b0" 'bg "rgba(121, 189, 147, 0.13)")
    (list 'diff-del 'fg "#eb9282" 'bg "rgba(224, 112, 90, 0.13)")
    (list 'diff-add-word 'bg "rgba(121, 189, 147, 0.32)")
    (list 'diff-del-word 'bg "rgba(224, 112, 90, 0.30)")
    (list 'code-scope 'bg "rgba(213, 172, 102, 0.10)")
    (list 'chrome 'gap "5px" 'radius "0"
          'border "1px solid #4a4238"
          'shadow "0 14px 40px rgba(0, 0, 0, 0.7)"
          'shadow-deep "0 22px 60px rgba(0, 0, 0, 0.7)")))

;; tokyo-night's base: the old compos-dark, which the block below extends
(define-theme "tokyo-night"
  (list
    (list 'ts-keyword 'fg "#7aa2f7")
    (list 'ts-function 'fg "#d6d8de")
    (list 'ts-string 'fg "#9ece6a")
    (list 'ts-comment 'fg "#8b8fa3")
    (list 'ts-number 'fg "#e0af68")
    (list 'ts-constant 'fg "#e0af68")
    (list 'ts-type 'fg "#2ac3de")
    (list 'ts-module 'fg "#2ac3de")
    (list 'ts-operator 'fg "#8b8fa3")
    (list 'ts-punctuation 'fg "#8b8fa3")
    (list 'ts-tag 'fg "#7aa2f7")
    (list 'ts-attribute 'fg "#e0af68")
    (list 'ts-variable 'fg "#c8ccd4")
    (list 'ts-property 'fg "#a9b1d6")
    (list 'ts-escape 'fg "#e0af68")
    (list 'default 'bg "#1e1f22" 'fg "#d6d8de")
    ;; headings: every theme names them, as it names the ts-* faces
    (list 'org-level-1 'fg "#7aa2f7" 'weight "700")
    (list 'org-level-2 'fg "#e0af68" 'weight "600")
    (list 'org-level-3 'fg "#9ece6a" 'weight "600")
    (list 'org-level-4 'fg "#bb9af7" 'weight "600")
    (list 'window 'bg "#23242a")
    ;; the group scale: six colours a group is allotted by slot, told
    ;; apart at a glance and readable against this theme's background
    (list 'group-color-1 'fg "#f7768e")
    (list 'group-color-2 'fg "#7aa2f7")
    (list 'group-color-3 'fg "#9ece6a")
    (list 'group-color-4 'fg "#bb9af7")
    (list 'group-color-5 'fg "#e0af68")
    (list 'group-color-6 'fg "#7dcfff")
    (list 'window-inactive 'bg "#1e1f22")
    (list 'modeline 'bg "#2f3140" 'fg "#8b8fa3")
    (list 'modeline-active 'bg "#3b4261" 'fg "#d6d8de")
    (list 'cursor 'bg "#c0caf5")
    (list 'region 'bg "#3f5488")
    (list 'accent 'fg "#7aa2f7")
    (list 'link 'fg "#7aa2f7" 'decoration "underline")
    (list 'llm-response 'fg "#7aa2f7" 'style "italic")
    (list 'llm-prompt 'inherit 'llm-response)
    (list 'diff-block 'fg "#e0af68" 'style "italic")
    (list 'diff-block-source 'fg "#8b8fa3" 'style "italic")
    (list 'dim 'fg "#8b8fa3")
    (list 'select 'bg "#3a4c7a")
    (list 'hl-line 'bg "#454754")
    (list 'linenum 'fg "#4a4d59")
    (list 'border 'bg "#15161a")
    (list 'warn 'fg "#e0af68")
    ;; the list faces: a column label and a rule are fainter than
    ;; `dim`, and a list says good and bad in one word. Faint is still
    ;; text: the line-number grey is a mark, not a word.
    (list 'faint 'fg "#6f7387")
    (list 'ok 'fg "#9ece6a")
    (list 'alert 'fg "#f7768e")
    ;; the mail faces: the index columns and the show-view header
    (list 'nm-date 'fg "#8b8fa3")
    (list 'nm-author 'fg "#7aa2f7")
    (list 'nm-tags 'fg "#8b8fa3")
    (list 'nm-marked 'fg "#f7768e")
    (list 'nm-hdr 'fg "#7aa2f7")
    (list 'nm-sep 'fg "#8b8fa3")
    (list 'diff-file 'fg "#7aa2f7" 'weight "600")
    (list 'diff-hunk 'fg "#e0af68")
    (list 'diff-add 'fg "#9ece6a" 'bg "rgba(158, 206, 106, 0.13)")
    (list 'diff-del 'fg "#f7768e" 'bg "rgba(247, 118, 142, 0.13)")
    (list 'diff-add-word 'bg "rgba(158, 206, 106, 0.30)")
    (list 'diff-del-word 'bg "rgba(247, 118, 142, 0.28)")
    (list 'code-scope 'bg "rgba(122, 162, 247, 0.10)")
    (list 'chrome 'gap "5px" 'radius "0"
          'border "1px solid #15161a"
          'shadow "0 2px 14px rgba(0, 0, 0, 0.4)")))

(define-theme "catppuccin-mocha"
  (list
    (list 'ts-keyword 'fg "#cba6f7")
    (list 'ts-function 'fg "#89b4fa")
    (list 'ts-string 'fg "#a6e3a1")
    (list 'ts-comment 'fg "#6c7086")
    (list 'ts-number 'fg "#fab387")
    (list 'ts-constant 'fg "#fab387")
    (list 'ts-type 'fg "#f9e2af")
    (list 'ts-module 'fg "#f9e2af")
    (list 'ts-operator 'fg "#89dceb")
    (list 'ts-punctuation 'fg "#9399b2")
    (list 'ts-tag 'fg "#89b4fa")
    (list 'ts-attribute 'fg "#f9e2af")
    (list 'ts-variable 'fg "#cdd6f4")
    (list 'ts-property 'fg "#b4befe")
    (list 'ts-escape 'fg "#f2cdcd")
    (list 'default 'bg "#1e1e2e" 'fg "#cdd6f4")
    (list 'org-level-1 'fg "#89b4fa" 'weight "700")
    (list 'org-level-2 'fg "#fab387" 'weight "600")
    (list 'org-level-3 'fg "#a6e3a1" 'weight "600")
    (list 'org-level-4 'fg "#cba6f7" 'weight "600")
    ;; the group scale: six colours a group is allotted by slot, told
    ;; apart at a glance and readable against this theme's background
    (list 'group-color-1 'fg "#f38ba8")
    (list 'group-color-2 'fg "#89b4fa")
    (list 'group-color-3 'fg "#a6e3a1")
    (list 'group-color-4 'fg "#cba6f7")
    (list 'group-color-5 'fg "#fab387")
    (list 'group-color-6 'fg "#94e2d5")
    (list 'window 'bg "#181825")
    (list 'window-inactive 'bg "#11111b")
    (list 'modeline 'bg "#313244" 'fg "#a6adc8")
    (list 'modeline-active 'bg "#45475a" 'fg "#cdd6f4")
    (list 'cursor 'bg "#f5e0dc")
    (list 'region 'bg "#4d5c9b")
    (list 'accent 'fg "#cba6f7")
    (list 'link 'fg "#89b4fa" 'decoration "underline")
    (list 'llm-response 'fg "#cba6f7" 'style "italic")
    (list 'llm-prompt 'inherit 'llm-response)
    (list 'diff-block 'fg "#fab387" 'style "italic")
    (list 'diff-block-source 'fg "#6c7086" 'style "italic")
    (list 'dim 'fg "#6c7086")
    (list 'select 'bg "#3e4a7d")
    (list 'hl-line 'bg "#3b3d52")
    (list 'linenum 'fg "#45475a")
    (list 'border 'bg "#11111b")
    (list 'warn 'fg "#fab387")
    ;; the list faces: a column label and a rule are fainter than
    ;; `dim`, and a list says good and bad in one word
    (list 'faint 'fg "#7f849c")
    (list 'ok 'fg "#a6e3a1")
    (list 'alert 'fg "#f38ba8")
    ;; the mail faces: the index columns and the show-view header
    (list 'nm-date 'fg "#7f849c")
    (list 'nm-author 'fg "#89b4fa")
    (list 'nm-tags 'fg "#9399b2")
    (list 'nm-marked 'fg "#f38ba8")
    (list 'nm-hdr 'fg "#89b4fa")
    (list 'nm-sep 'fg "#9399b2")
    (list 'diff-file 'fg "#89b4fa" 'weight "600")
    (list 'diff-hunk 'fg "#fab387")
    (list 'diff-add 'fg "#a6e3a1" 'bg "rgba(166, 227, 161, 0.13)")
    (list 'diff-del 'fg "#f38ba8" 'bg "rgba(243, 139, 168, 0.13)")
    (list 'diff-add-word 'bg "rgba(166, 227, 161, 0.30)")
    (list 'diff-del-word 'bg "rgba(243, 139, 168, 0.28)")
    (list 'code-scope 'bg "rgba(137, 180, 250, 0.10)")
    (list 'chrome 'gap "5px" 'radius "0"
          'border "1px solid #11111b"
          'shadow "0 2px 14px rgba(0, 0, 0, 0.4)")))

;; built on the old compos-dark: it inherits the strings, types, cursor, warn and
;; diff faces and overrides the rest of the palette
(define-theme-from "tokyo-night" "tokyo-night"
  (list
    (list 'ts-keyword 'fg "#bb9af7")
    (list 'ts-function 'fg "#7aa2f7")
    (list 'ts-comment 'fg "#565f89")
    (list 'ts-number 'fg "#ff9e64")
    (list 'ts-constant 'fg "#ff9e64")
    (list 'ts-operator 'fg "#89ddff")
    (list 'ts-punctuation 'fg "#565f89")
    (list 'ts-tag 'fg "#f7768e")
    (list 'default 'bg "#1a1b26" 'fg "#c0caf5")
    (list 'org-level-1 'fg "#7aa2f7" 'weight "700")
    (list 'org-level-2 'fg "#ff9e64" 'weight "600")
    (list 'org-level-3 'fg "#9ece6a" 'weight "600")
    (list 'org-level-4 'fg "#bb9af7" 'weight "600")
    (list 'window 'bg "#16161e")
    (list 'window-inactive 'bg "#1a1b26")
    (list 'modeline 'bg "#24283b" 'fg "#565f89")
    (list 'modeline-active 'bg "#414868" 'fg "#c0caf5")
    (list 'region 'bg "#3d59a1")
    (list 'dim 'fg "#565f89")
    (list 'select 'bg "#3f4a78")
    (list 'hl-line 'bg "#333854")
    (list 'linenum 'fg "#3b4261")
    (list 'border 'bg "#101014")
    (list 'chrome 'gap "5px" 'radius "0"
          'border "1px solid #101014"
          'shadow "0 2px 14px rgba(0, 0, 0, 0.4)")))

;;; --- compos: the logo's inks ------------------------------------------------
;; compos and compos-dark: the logo's inks. Cyan, magenta and yellow are
;; the highlights; the colours where two inks overlap (navy, red, green)
;; carry the text that must stay readable.
(define-theme-from "compos" "paper"
  (list
    (list 'ts-keyword 'fg "#c8106c")
    (list 'ts-function 'fg "#00708f")
    (list 'ts-string 'fg "#2f7d32")
    (list 'ts-comment 'fg "#8a857a")
    (list 'ts-number 'fg "#c62a1c")
    (list 'ts-constant 'fg "#c62a1c")
    (list 'ts-type 'fg "#283593")
    (list 'ts-module 'fg "#283593")
    (list 'ts-operator 'fg "#57534a")
    (list 'ts-punctuation 'fg "#57534a")
    (list 'ts-tag 'fg "#c8106c")
    (list 'ts-attribute 'fg "#00708f")
    (list 'ts-variable 'fg "#3b3a35")
    (list 'ts-property 'fg "#57534a")
    (list 'ts-escape 'fg "#c62a1c")
    (list 'default 'bg "#e9e4d8" 'fg "#1b1a17")
    (list 'window 'bg "#fbf9f4")
    (list 'paper 'bg "#f1ece1")
    (list 'window-inactive 'bg "#f5f1e8")
    (list 'modeline 'bg "#ebe6db" 'fg "#57534a")
    (list 'modeline-active 'bg "#cdeef7" 'fg "#1b1a17")
    (list 'cursor 'bg "#00a3cc")
    (list 'region 'bg "#fbe38a")
    (list 'select 'bg "#d2eef7")
    (list 'hl-line 'bg "#ede4c8")
    (list 'accent 'fg "#00708f")
    (list 'link 'fg "#00708f" 'decoration "underline")
    (list 'agent-you 'bg "#fff0b0" 'fg "#c8106c")
    (list 'llm-response 'fg "#283593" 'style "italic")
    (list 'llm-prompt 'inherit 'llm-response)
    (list 'diff-block 'fg "#c8106c" 'style "italic")
    (list 'warn 'fg "#9a7400")
    (list 'ok 'fg "#2f7d32")
    (list 'alert 'fg "#c62a1c")
    (list 'org-level-1 'fg "#c8106c" 'weight "700")
    (list 'org-level-2 'fg "#00708f" 'weight "600")
    (list 'org-level-3 'fg "#283593" 'weight "600")
    (list 'org-level-4 'fg "#c62a1c" 'weight "600")
    (list 'group-color-1 'fg "#e0147a")
    (list 'group-color-2 'fg "#00708f")
    (list 'group-color-3 'fg "#9a7400")
    (list 'group-color-4 'fg "#283593")
    (list 'group-color-5 'fg "#c62a1c")
    (list 'group-color-6 'fg "#2f7d32")
    (list 'org-todo 'fg "#e0147a" 'weight "700")
    (list 'org-done 'fg "#2f7d32" 'decoration "line-through")
    (list 'org-date 'fg "#00708f" 'style "italic")
    (list 'org-checkbox 'fg "#c8106c" 'weight "600")
    (list 'nm-author 'fg "#283593" 'weight "400" 'style "italic")
    (list 'nm-marked 'fg "#e0147a")
    (list 'nm-hdr 'fg "#c8106c")
    (list 'diff-file 'fg "#c8106c" 'weight "600")
    (list 'diff-hunk 'fg "#00708f")
    (list 'diff-add 'fg "#1f5a22" 'bg "rgba(47, 125, 50, 0.13)")
    (list 'diff-del 'fg "#8f0d4d" 'bg "rgba(224, 20, 122, 0.11)")
    (list 'diff-add-word 'bg "rgba(47, 125, 50, 0.30)")
    (list 'diff-del-word 'bg "rgba(224, 20, 122, 0.26)")
    (list 'code-scope 'bg "rgba(0, 163, 204, 0.07)")))

(define-theme-from "compos-dark" "paper-night"
  (list
    (list 'ts-keyword 'fg "#ff4fa3")
    (list 'ts-function 'fg "#3cc6ea")
    (list 'ts-string 'fg "#f7c600")
    (list 'ts-comment 'fg "#8a8795")
    (list 'ts-number 'fg "#ff7059")
    (list 'ts-constant 'fg "#ff7059")
    (list 'ts-type 'fg "#8f9bff")
    (list 'ts-module 'fg "#8f9bff")
    (list 'ts-operator 'fg "#a7a3b0")
    (list 'ts-punctuation 'fg "#8a8795")
    (list 'ts-tag 'fg "#ff4fa3")
    (list 'ts-attribute 'fg "#3cc6ea")
    (list 'ts-variable 'fg "#e4e0d8")
    (list 'ts-property 'fg "#c9c5cf")
    (list 'ts-escape 'fg "#ff7059")
    (list 'default 'bg "#0c0c10" 'fg "#f1ede4")
    (list 'window 'bg "#16161c")
    (list 'paper 'bg "#121217")
    (list 'body 'fg "#dcd8cf")
    (list 'border-soft 'bg "#2c2b35")
    (list 'window-inactive 'bg "#121217")
    (list 'modeline 'bg "#121217" 'fg "#a7a3b0")
    (list 'modeline-active 'bg "#0d4f63" 'fg "#f1ede4")
    (list 'cursor 'bg "#3cc6ea")
    (list 'region 'bg "#4a3d00")
    (list 'select 'bg "#3a1630")
    (list 'hl-line 'bg "#2d2c3c")
    (list 'linenum 'fg "#46444f")
    (list 'border 'bg "#2c2b35")
    (list 'accent 'fg "#3cc6ea")
    (list 'link 'fg "#3cc6ea" 'decoration "underline")
    (list 'agent-you 'bg "#3a3208" 'fg "#ff4fa3")
    (list 'llm-response 'fg "#8f9bff" 'style "italic")
    (list 'llm-prompt 'inherit 'llm-response)
    (list 'diff-block 'fg "#ff4fa3" 'style "italic")
    (list 'diff-block-source 'fg "#8a8795" 'style "italic")
    (list 'dim 'fg "#8a8795")
    (list 'faint 'fg "#6c6977")
    (list 'warn 'fg "#f7c600")
    (list 'ok 'fg "#5ccb6a")
    (list 'alert 'fg "#ff7059")
    (list 'org-level-1 'fg "#ff4fa3" 'weight "700")
    (list 'org-level-2 'fg "#3cc6ea" 'weight "600")
    (list 'org-level-3 'fg "#f7c600" 'weight "600")
    (list 'org-level-4 'fg "#8f9bff" 'weight "600")
    (list 'group-color-1 'fg "#ff4fa3")
    (list 'group-color-2 'fg "#3cc6ea")
    (list 'group-color-3 'fg "#f7c600")
    (list 'group-color-4 'fg "#8f9bff")
    (list 'group-color-5 'fg "#ff7059")
    (list 'group-color-6 'fg "#5ccb6a")
    (list 'org-todo 'fg "#ff4fa3" 'weight "700")
    (list 'org-done 'fg "#5ccb6a" 'decoration "line-through")
    (list 'org-priority 'fg "#f7c600" 'weight "600")
    (list 'org-date 'fg "#3cc6ea" 'style "italic")
    (list 'org-tag 'fg "#8a8795")
    (list 'org-checkbox 'fg "#ff4fa3" 'weight "600")
    (list 'org-cookie 'fg "#f7c600")
    (list 'org-meta 'fg "#8a8795")
    (list 'fold-marker 'fg "#8a8795")
    (list 'nm-date 'fg "#8a8795")
    (list 'nm-author 'fg "#3cc6ea")
    (list 'nm-tags 'fg "#a7a3b0")
    (list 'nm-marked 'fg "#ff4fa3")
    (list 'nm-hdr 'fg "#ff4fa3")
    (list 'nm-sep 'fg "#6c6977")
    (list 'diff-file 'fg "#ff4fa3" 'weight "600")
    (list 'diff-hunk 'fg "#3cc6ea")
    (list 'diff-add 'fg "#8fe09a" 'bg "rgba(92, 203, 106, 0.13)")
    (list 'diff-del 'fg "#ff8fc3" 'bg "rgba(255, 79, 163, 0.13)")
    (list 'diff-add-word 'bg "rgba(92, 203, 106, 0.32)")
    (list 'diff-del-word 'bg "rgba(255, 79, 163, 0.30)")
    (list 'code-scope 'bg "rgba(60, 198, 234, 0.08)")
    (list 'chrome 'gap "5px" 'radius "0"
          'border "1px solid #2c2b35"
          'shadow "0 14px 40px rgba(0, 0, 0, 0.7)"
          'shadow-deep "0 22px 60px rgba(0, 0, 0, 0.7)")))

;; a message you typed wears its ink: a magenta edge and magenta words on
;; the yellow ground agent-you gives it
(define compos-theme-skin
  ".ag-user { color: var(--agent-you-fg); box-shadow: inset 3px 0 var(--agent-you-fg); }")
(define-theme-skin! "compos" compos-theme-skin)
(define-theme-skin! "compos-dark" compos-theme-skin)

;;; --- zenburn: the low-contrast classic --------------------------------------
;;; Jani Nurminen's palette, as Emacs has worn it since 2003. A grey-green
;;; ground, a bone foreground, and colours that are all one step muted, so
;;; nothing on the screen is brighter than anything else by much.

(define-theme "zenburn"
  (list
    (list 'ts-keyword 'fg "#f0dfaf" 'weight "600")
    (list 'ts-function 'fg "#efef8f")
    (list 'ts-string 'fg "#cc9393")
    (list 'ts-comment 'fg "#7f9f7f" 'style "italic")
    (list 'ts-number 'fg "#8cd0d3")
    (list 'ts-constant 'fg "#dca3a3")
    (list 'ts-type 'fg "#dfdfbf")
    (list 'ts-module 'fg "#dfdfbf")
    (list 'ts-operator 'fg "#f0dfaf")
    (list 'ts-punctuation 'fg "#9fafaf")
    (list 'ts-tag 'fg "#e89393")
    (list 'ts-attribute 'fg "#dfaf8f")
    (list 'ts-variable 'fg "#dcdccc")
    (list 'ts-property 'fg "#dfaf8f")
    (list 'ts-escape 'fg "#dca3a3")
    (list 'default 'bg "#2b2b2b" 'fg "#dcdccc")
    (list 'window 'bg "#3f3f3f")
    (list 'paper 'bg "#383838")
    (list 'window-inactive 'bg "#363636")
    (list 'body 'fg "#c8c8b8")
    (list 'border-soft 'bg "#4f4f4f")
    (list 'border 'bg "#5f5f5f")
    (list 'modeline 'bg "#2b2b2b" 'fg "#8fb28f")
    (list 'modeline-active 'bg "#4a4a4a" 'fg "#dcdccc")
    (list 'cursor 'bg "#ffffef")
    (list 'region 'bg "#4f6384")
    (list 'select 'bg "#6e6e5a")
    (list 'hl-line 'bg "#5b5b5b")
    (list 'linenum 'fg "#6f6f6f")
    (list 'accent 'fg "#94bff3")
    (list 'link 'fg "#94bff3" 'decoration "underline")
    (list 'llm-response 'fg "#94bff3" 'style "italic")
    (list 'llm-prompt 'inherit 'llm-response)
    (list 'diff-block 'fg "#dfaf8f" 'style "italic")
    (list 'diff-block-source 'fg "#7f9f7f" 'style "italic")
    (list 'dim 'fg "#9fafaf")
    (list 'faint 'fg "#7f8f8f")
    (list 'warn 'fg "#dfaf8f")
    (list 'ok 'fg "#7f9f7f")
    (list 'alert 'fg "#e37170")
    (list 'org-level-1 'fg "#dfaf8f" 'weight "700")
    (list 'org-level-2 'fg "#f0dfaf" 'weight "600")
    (list 'org-level-3 'fg "#8fb28f" 'weight "600")
    (list 'org-level-4 'fg "#94bff3" 'weight "600")
    (list 'group-color-1 'fg "#dca3a3")
    (list 'group-color-2 'fg "#94bff3")
    (list 'group-color-3 'fg "#7f9f7f")
    (list 'group-color-4 'fg "#dc8cc3")
    (list 'group-color-5 'fg "#f0dfaf")
    (list 'group-color-6 'fg "#8cd0d3")
    (list 'org-todo 'fg "#e37170" 'weight "700")
    (list 'org-done 'fg "#7f9f7f" 'decoration "line-through")
    (list 'org-priority 'fg "#dfaf8f" 'weight "600")
    (list 'org-date 'fg "#94bff3" 'style "italic")
    (list 'org-tag 'fg "#9fafaf")
    (list 'org-checkbox 'fg "#8fb28f" 'weight "600")
    (list 'org-cookie 'fg "#f0dfaf")
    (list 'org-meta 'fg "#7f9f7f")
    (list 'fold-marker 'fg "#dfaf8f")
    (list 'nm-date 'fg "#9fafaf")
    (list 'nm-author 'fg "#94bff3")
    (list 'nm-tags 'fg "#7f9f7f")
    (list 'nm-subject 'fg "#dcdccc")
    (list 'nm-marked 'fg "#e37170")
    (list 'nm-hdr 'fg "#f0dfaf")
    (list 'nm-sep 'fg "#6f6f6f")
    (list 'diff-file 'fg "#f0dfaf" 'weight "600")
    (list 'diff-hunk 'fg "#8cd0d3")
    (list 'diff-add 'fg "#9fc59f" 'bg "rgba(127, 159, 127, 0.18)")
    (list 'diff-del 'fg "#e0a3a3" 'bg "rgba(227, 113, 112, 0.16)")
    (list 'diff-add-word 'bg "rgba(127, 159, 127, 0.38)")
    (list 'diff-del-word 'bg "rgba(227, 113, 112, 0.34)")
    (list 'code-scope 'bg "rgba(148, 191, 243, 0.08)")
    (list 'chrome 'gap "5px" 'radius "0"
          'border "1px solid #5f5f5f"
          'shadow "0 2px 14px rgba(0, 0, 0, 0.35)"
          'shadow-deep "0 16px 40px rgba(0, 0, 0, 0.5)")))

;;; --- ascii: everything is typed ---------------------------------------------
;;; No colour and no paint. The screen has one font and a scale of greys,
;;; and every line on it is a character: a dash for a rule, a dot for a
;;; soft one, a + where two rules cross. A keyword is not blue, it is
;;; bold. A comment is not green, it leans. This is what the editor looks
;;; like when the only thing it can draw is text.

(define-theme "ascii"
  (list
    ;; the only scale there is: weight and slant carry what colour would
    (list 'ts-keyword 'fg "#ffffff" 'weight "700")
    (list 'ts-function 'fg "#e4e4e4" 'weight "500")
    (list 'ts-string 'fg "#a8a8a8")
    (list 'ts-comment 'fg "#6c6c6c" 'style "italic")
    (list 'ts-number 'fg "#e4e4e4")
    (list 'ts-constant 'fg "#e4e4e4")
    (list 'ts-type 'fg "#e4e4e4" 'weight "500")
    (list 'ts-module 'fg "#e4e4e4" 'weight "500")
    (list 'ts-operator 'fg "#8a8a8a")
    (list 'ts-punctuation 'fg "#6c6c6c")
    (list 'ts-tag 'fg "#ffffff" 'weight "700")
    (list 'ts-attribute 'fg "#a8a8a8")
    (list 'ts-variable 'fg "#c6c6c6")
    (list 'ts-property 'fg "#a8a8a8")
    (list 'ts-escape 'fg "#ffffff")
    (list 'default 'bg "#101010" 'fg "#c6c6c6")
    (list 'window 'bg "#101010")
    (list 'paper 'bg "#101010")
    (list 'window-inactive 'bg "#0b0b0b")
    (list 'body 'fg "#ababab")
    (list 'border-soft 'bg "#4a4a4a")
    (list 'border 'bg "#767676")
    (list 'modeline 'bg "#101010" 'fg "#8a8a8a")
    (list 'modeline-active 'bg "#101010" 'fg "#ffffff")
    (list 'cursor 'bg "#ffffff")
    (list 'region 'bg "#666666")
    (list 'select 'bg "#4a4a4a")
    (list 'hl-line 'bg "#333333")
    (list 'linenum 'fg "#4a4a4a")
    (list 'accent 'fg "#ffffff")
    (list 'link 'fg "#ffffff" 'decoration "underline")
    (list 'llm-response 'fg "#e4e4e4" 'style "italic")
    (list 'llm-prompt 'inherit 'llm-response)
    (list 'diff-block 'fg "#a8a8a8" 'style "italic")
    (list 'diff-block-source 'fg "#6c6c6c" 'style "italic")
    (list 'dim 'fg "#8a8a8a")
    (list 'faint 'fg "#5a5a5a")
    ;; three words a list must say, and one grey scale to say them in
    (list 'warn 'fg "#e4e4e4" 'weight "600")
    (list 'ok 'fg "#a8a8a8")
    (list 'alert 'fg "#ffffff" 'weight "700")
    (list 'org-level-1 'fg "#ffffff" 'weight "700")
    (list 'org-level-2 'fg "#e4e4e4" 'weight "700")
    (list 'org-level-3 'fg "#c6c6c6" 'weight "600")
    (list 'org-level-4 'fg "#a8a8a8" 'weight "600")
    ;; six groups, six steps of grey
    (list 'group-color-1 'fg "#ffffff")
    (list 'group-color-2 'fg "#d4d4d4")
    (list 'group-color-3 'fg "#ababab")
    (list 'group-color-4 'fg "#8a8a8a")
    (list 'group-color-5 'fg "#6c6c6c")
    (list 'group-color-6 'fg "#545454")
    (list 'org-todo 'fg "#ffffff" 'weight "700")
    (list 'org-done 'fg "#6c6c6c" 'decoration "line-through")
    (list 'org-priority 'fg "#ffffff" 'weight "700")
    (list 'org-date 'fg "#a8a8a8")
    (list 'org-tag 'fg "#6c6c6c")
    (list 'org-checkbox 'fg "#ffffff" 'weight "700")
    (list 'org-cookie 'fg "#a8a8a8")
    (list 'org-meta 'fg "#6c6c6c")
    (list 'fold-marker 'fg "#8a8a8a")
    (list 'nm-date 'fg "#6c6c6c")
    (list 'nm-author 'fg "#e4e4e4")
    (list 'nm-tags 'fg "#8a8a8a")
    (list 'nm-subject 'fg "#c6c6c6")
    (list 'nm-marked 'fg "#ffffff" 'weight "700")
    (list 'nm-hdr 'fg "#ffffff" 'weight "600")
    (list 'nm-sep 'fg "#4a4a4a")
    ;; a diff says add and remove with the sign and the ground, not a hue
    (list 'diff-file 'fg "#ffffff" 'weight "700")
    (list 'diff-hunk 'fg "#a8a8a8")
    (list 'diff-add 'fg "#ffffff" 'bg "rgba(255, 255, 255, 0.11)")
    (list 'diff-del 'fg "#8a8a8a" 'bg "rgba(255, 255, 255, 0.04)")
    (list 'diff-add-word 'bg "rgba(255, 255, 255, 0.26)")
    (list 'diff-del-word 'bg "rgba(255, 255, 255, 0.12)")
    (list 'code-scope 'bg "rgba(255, 255, 255, 0.05)")
    ;; one font for the whole application, because a teletype has one
    (list 'mono 'family "Menlo, 'DejaVu Sans Mono', 'Liberation Mono', 'Courier New', monospace")
    (list 'sans 'inherit 'mono)
    (list 'serif 'inherit 'mono)
    ;; a gap, because an ASCII screen draws each box and the boxes do not
    ;; share a rule
    (list 'chrome 'gap "7px" 'radius "0"
          'border "1px dashed #767676"
          'shadow "none"
          'shadow-deep "none")))

;; the + where two typed rules cross, as one small drawing, placed at the
;; four corners of every box
(define ascii-plus
  "url(\"data:image/svg+xml,%3Csvg%20xmlns=%27http://www.w3.org/2000/svg%27%20width=%279%27%20height=%279%27%3E%3Cpath%20d=%27M0%204.5H9M4.5%200V9%27%20stroke=%27%23767676%27%20stroke-width=%271%27/%3E%3C/svg%3E\")")

(define-theme-skin! "ascii" (string-append "
/* Nothing is painted. A box is four dashed rules with a + at each corner,
   the way a person draws one with the keys they have. */
.window, .window.active, .window.inactive,
.window.active:has(.dash-state-focus),
.window.active:has(.dash-state-editing) { box-shadow: none; }
.window { border: 1px dashed var(--border-soft-bg); }
.window.active { border-color: var(--border-bg); }
.window::before {
  content: ''; position: absolute; inset: 0; z-index: 7;
  pointer-events: none;
  background-image: " ascii-plus ", " ascii-plus ", " ascii-plus ", " ascii-plus ";
  background-repeat: no-repeat;
  background-position: left top, right top, left bottom, right bottom;
}
/* a mode line is a dashed rule with words under it */
.modeline, .window.active .modeline {
  background: transparent;
  border-top: 1px dashed var(--border-soft-bg);
}
/* a heading is typed, so it is upper case and ruled underneath */
.buffer-header {
  background: transparent;
  border-bottom: 1px dashed var(--border-bg);
  text-transform: uppercase; letter-spacing: 0.1em;
}
/* the soft rules inside a pane are dotted, never faint grey bands */
.buffer-footer, .dash-live, .dash-top, .echo-bar, .echo-area {
  background: transparent;
  border-color: var(--border-soft-bg);
  border-style: dotted;
}
/* a tab is a word between brackets, not a chip */
.ml-tab-on { text-decoration: underline; }
"))

;;; --- crt: the green phosphor tube -------------------------------------------
;;; One font. One ground. Sixteen colours, and it spends six of them. A
;;; mode line is an inverted strip, the glass blooms around every lit
;;; pixel, and the scan lines never stop. Nothing lifts, nothing rounds,
;;; nothing eases.

(define-theme "crt"
  (list
    ;; the ANSI eight, bright half, on black
    (list 'ts-keyword 'fg "#ffffff" 'weight "700")
    (list 'ts-function 'fg "#5fffff")
    (list 'ts-string 'fg "#ffff5f")
    (list 'ts-comment 'fg "#00a52b" 'style "italic")
    (list 'ts-number 'fg "#ff5fff")
    (list 'ts-constant 'fg "#ff5fff")
    (list 'ts-type 'fg "#5fffff")
    (list 'ts-module 'fg "#5fffff")
    (list 'ts-operator 'fg "#33ff33")
    (list 'ts-punctuation 'fg "#00c231")
    (list 'ts-tag 'fg "#ffffff")
    (list 'ts-attribute 'fg "#ffff5f")
    (list 'ts-variable 'fg "#33ff33")
    (list 'ts-property 'fg "#33ff33")
    (list 'ts-escape 'fg "#ff5fff")
    ;; every ground is the same ground: a terminal has one
    (list 'default 'bg "#000000" 'fg "#33ff33")
    (list 'window 'bg "#000000")
    (list 'paper 'bg "#000000")
    (list 'window-inactive 'bg "#000000")
    (list 'body 'fg "#2be02b")
    (list 'border-soft 'bg "#0d4f18")
    (list 'border 'bg "#00a52b")
    (list 'modeline 'bg "#00a52b" 'fg "#000000")
    (list 'modeline-active 'bg "#33ff33" 'fg "#000000")
    (list 'cursor 'bg "#33ff33")
    (list 'region 'bg "#0f7a26")
    (list 'select 'bg "#10561b")
    (list 'hl-line 'bg "#0a3d12")
    (list 'linenum 'fg "#0d6b21")
    (list 'accent 'fg "#5fffff")
    (list 'link 'fg "#5fffff" 'decoration "underline")
    (list 'llm-response 'fg "#5fffff")
    (list 'llm-prompt 'inherit 'llm-response)
    (list 'diff-block 'fg "#ffff5f")
    (list 'diff-block-source 'fg "#00a52b")
    (list 'dim 'fg "#00a52b")
    (list 'faint 'fg "#0d6b21")
    (list 'warn 'fg "#ffff5f")
    (list 'ok 'fg "#33ff33")
    (list 'alert 'fg "#ff5f5f")
    (list 'org-level-1 'fg "#ffffff" 'weight "700")
    (list 'org-level-2 'fg "#5fffff" 'weight "700")
    (list 'org-level-3 'fg "#ffff5f" 'weight "700")
    (list 'org-level-4 'fg "#ff5fff" 'weight "700")
    (list 'group-color-1 'fg "#ff5f5f")
    (list 'group-color-2 'fg "#5fffff")
    (list 'group-color-3 'fg "#33ff33")
    (list 'group-color-4 'fg "#ff5fff")
    (list 'group-color-5 'fg "#ffff5f")
    (list 'group-color-6 'fg "#ffffff")
    (list 'org-todo 'fg "#ff5f5f" 'weight "700")
    (list 'org-done 'fg "#00a52b" 'decoration "line-through")
    (list 'org-priority 'fg "#ffff5f" 'weight "700")
    (list 'org-date 'fg "#5fffff")
    (list 'org-tag 'fg "#00a52b")
    (list 'org-checkbox 'fg "#ffff5f" 'weight "700")
    (list 'org-cookie 'fg "#ffff5f")
    (list 'org-meta 'fg "#00a52b")
    (list 'fold-marker 'fg "#ffff5f")
    (list 'nm-date 'fg "#00a52b")
    (list 'nm-author 'fg "#5fffff")
    (list 'nm-tags 'fg "#ffff5f")
    (list 'nm-subject 'fg "#33ff33")
    (list 'nm-marked 'fg "#ff5f5f")
    (list 'nm-hdr 'fg "#ffffff")
    (list 'nm-sep 'fg "#00a52b")
    (list 'diff-file 'fg "#ffffff" 'weight "700")
    (list 'diff-hunk 'fg "#5fffff")
    (list 'diff-add 'fg "#33ff33" 'bg "rgba(51, 255, 51, 0.12)")
    (list 'diff-del 'fg "#ff5f5f" 'bg "rgba(255, 95, 95, 0.12)")
    (list 'diff-add-word 'bg "rgba(51, 255, 51, 0.30)")
    (list 'diff-del-word 'bg "rgba(255, 95, 95, 0.28)")
    (list 'code-scope 'bg "rgba(51, 255, 51, 0.07)")
    ;; one font for the whole application, because a terminal has one
    (list 'mono 'family "Menlo, 'DejaVu Sans Mono', 'Liberation Mono', 'Courier New', monospace")
    (list 'sans 'inherit 'mono)
    (list 'serif 'inherit 'mono)
    (list 'chrome 'gap "0" 'radius "0"
          'border "1px solid #00a52b"
          'shadow "none"
          'shadow-deep "none")))

(define-theme-skin! "crt" "
/* No pane lifts: a terminal has no depth. Every box is rules. */
.window, .window.active, .window.inactive,
.window.active:has(.dash-state-focus),
.window.active:has(.dash-state-editing) { box-shadow: none; }
.window { border: 1px solid var(--border-soft-bg); }
.window.active { border-color: var(--border-bg); }
/* the status line curses draws: the ink and the ground change places */
.modeline, .window.active .modeline, .buffer-header {
  background: var(--modeline-bg);
  color: var(--modeline-fg);
  border-top: 0; border-bottom: 0;
  letter-spacing: 0;
}
.window.active .modeline, .window.active .buffer-header {
  background: var(--modeline-active-bg);
  color: var(--modeline-active-fg);
}
.modeline .ml-icon, .modeline .ml-group-item, .modeline .ml-state-modified,
.modeline .ml-segment, .modeline .ml-strong, .modeline .ml-extra .ml-segment {
  color: inherit;
}
.modeline .ml-dot { background: var(--modeline-fg); }
.window.active .modeline .ml-dot { background: var(--modeline-active-fg); }
/* phosphor: the glass blooms a little around every lit pixel */
.buf, .ag-prose, .echo { text-shadow: 0 0 6px color-mix(in srgb, var(--default-fg) 42%, transparent); }
/* the scan lines, over everything, catching nothing */
.windows::after {
  content: ''; position: absolute; inset: 0; z-index: 45;
  pointer-events: none;
  background: repeating-linear-gradient(to bottom,
    rgba(0, 0, 0, 0.26) 0 1px, rgba(0, 0, 0, 0) 1px 3px);
}
")

;;; --- paperized: the sheet, the grain, and the ink ---------------------------
;;; The desk is woven, the pane is a sheet laid on it, and the sheet has a
;;; grain that catches the light at the corners. The hand writes in three
;;; inks: black for the text, blue for what it points at, red for what it
;;; marks. A selection is a highlighter stroke. The margin numbers are
;;; pencil, so they lean.

(define-theme "paperized"
  (list
    (list 'ts-keyword 'fg "#2b3a67" 'weight "600")
    (list 'ts-function 'fg "#1f1a14")
    (list 'ts-string 'fg "#3b6b46")
    (list 'ts-comment 'fg "#9a8f77" 'style "italic")
    (list 'ts-number 'fg "#8a5a1f")
    (list 'ts-constant 'fg "#8a5a1f")
    (list 'ts-type 'fg "#6b3d5b")
    (list 'ts-module 'fg "#6b3d5b")
    (list 'ts-operator 'fg "#6b6151")
    (list 'ts-punctuation 'fg "#8f8470")
    (list 'ts-tag 'fg "#2b3a67")
    (list 'ts-attribute 'fg "#8a5a1f")
    (list 'ts-variable 'fg "#3a332b")
    (list 'ts-property 'fg "#6b6151")
    (list 'ts-escape 'fg "#a5342a")
    ;; the desk, the sheet, and the sheet laid over it
    (list 'default 'bg "#d9d0b8" 'fg "#241f1a")
    (list 'window 'bg "#fbf7ec")
    (list 'paper 'bg "#f3ecda")
    (list 'window-inactive 'bg "#efe7d2")
    (list 'body 'fg "#40382f")
    (list 'border-soft 'bg "#e3dac2")
    (list 'border 'bg "#c7bb9e")
    (list 'modeline 'bg "#f3ecda" 'fg "#6b6151")
    (list 'modeline-active 'bg "#f8f2e2" 'fg "#241f1a")
    (list 'cursor 'bg "#a5342a")
    ;; the highlighter: one pass of the pen, and the ink still reads
    (list 'region 'bg "#f6e08a")
    (list 'select 'bg "#f8e9ae")
    (list 'hl-line 'bg "#f6efdc")
    (list 'linenum 'fg "#b6a988")
    (list 'accent 'fg "#2b3a67")
    (list 'link 'fg "#2b3a67" 'decoration "underline")
    (list 'llm-response 'fg "#2b3a67" 'style "italic")
    (list 'llm-prompt 'inherit 'llm-response)
    (list 'diff-block 'fg "#8a5a1f" 'style "italic")
    (list 'diff-block-source 'fg "#9a8f77" 'style "italic")
    (list 'dim 'fg "#9a8f77")
    (list 'faint 'fg "#b6a988")
    (list 'warn 'fg "#8a5a1f")
    (list 'ok 'fg "#3b6b46")
    (list 'alert 'fg "#a5342a")
    (list 'org-level-1 'fg "#241f1a" 'weight "700")
    (list 'org-level-2 'fg "#2b3a67" 'weight "600")
    (list 'org-level-3 'fg "#3b6b46" 'weight "600")
    (list 'org-level-4 'fg "#6b3d5b" 'weight "600")
    (list 'group-color-1 'fg "#a5342a")
    (list 'group-color-2 'fg "#2b3a67")
    (list 'group-color-3 'fg "#3b6b46")
    (list 'group-color-4 'fg "#6b3d5b")
    (list 'group-color-5 'fg "#8a5a1f")
    (list 'group-color-6 'fg "#1f5f5c")
    (list 'org-todo 'fg "#a5342a" 'weight "700")
    (list 'org-done 'fg "#3b6b46" 'decoration "line-through")
    (list 'org-priority 'fg "#a5342a" 'weight "600")
    (list 'org-date 'fg "#2b3a67" 'style "italic")
    (list 'org-tag 'fg "#9a8f77" 'style "italic")
    (list 'org-checkbox 'fg "#2b3a67" 'weight "600")
    (list 'org-cookie 'fg "#8a5a1f")
    (list 'org-meta 'fg "#9a8f77" 'style "italic")
    (list 'fold-marker 'fg "#9a8f77")
    (list 'nm-date 'fg "#6b6151")
    (list 'nm-author 'fg "#2b3a67" 'style "italic")
    (list 'nm-tags 'fg "#8a5a1f")
    (list 'nm-subject 'fg "#241f1a")
    (list 'nm-marked 'fg "#a5342a")
    (list 'nm-hdr 'fg "#2b3a67")
    (list 'nm-sep 'fg "#c7bb9e")
    (list 'diff-file 'fg "#2b3a67" 'weight "600")
    (list 'diff-hunk 'fg "#8a5a1f")
    (list 'diff-add 'fg "#28522f" 'bg "rgba(59, 107, 70, 0.14)")
    (list 'diff-del 'fg "#7d2418" 'bg "rgba(165, 52, 42, 0.12)")
    (list 'diff-add-word 'bg "rgba(59, 107, 70, 0.30)")
    (list 'diff-del-word 'bg "rgba(165, 52, 42, 0.26)")
    (list 'code-scope 'bg "rgba(43, 58, 103, 0.06)")
    ;; the typewriter wrote the text; the press set everything else
    ;; American Typewriter is proportional: it wears a typewriter face but it
    ;; has no fixed advance. A terminal draws one glyph per cell, so a
    ;; proportional fallback ragged every column. Courier New is the
    ;; typewriter this theme wants AND a monospace, and it ships with macOS.
    (list 'mono 'family "'Courier Prime', 'Courier New', 'Nimbus Mono PS', 'IBM Plex Mono', monospace")
    (list 'serif 'family "'Iowan Old Style', 'Palatino Linotype', Palatino, Spectral, Georgia, serif")
    (list 'sans 'inherit 'serif)
    (list 'chrome 'gap "9px" 'radius "0"
          'border "1px solid #c7bb9e"
          'shadow "0 1px 2px rgba(74, 58, 36, 0.14), 0 9px 22px rgba(74, 58, 36, 0.16)"
          'shadow-deep "0 2px 4px rgba(74, 58, 36, 0.16), 0 22px 48px rgba(74, 58, 36, 0.22)")))

;; the fibre: grey fractal noise, tiled, multiplied into the sheet. One
;; data URI, so the texture costs no file and no request.
(define paper-noise
  "url(\"data:image/svg+xml,%3Csvg%20xmlns=%27http://www.w3.org/2000/svg%27%20width=%27200%27%20height=%27200%27%3E%3Cfilter%20id=%27p%27%3E%3CfeTurbulence%20type=%27fractalNoise%27%20baseFrequency=%270.8%27%20numOctaves=%274%27%20stitchTiles=%27stitch%27/%3E%3CfeColorMatrix%20type=%27saturate%27%20values=%270%27/%3E%3C/filter%3E%3Crect%20width=%27200%27%20height=%27200%27%20filter=%27url(%23p)%27%20opacity=%270.38%27/%3E%3C/svg%3E\")")

(define-theme-skin! "paperized"
  (string-append "
/* the desk: the same pulp, pressed harder */
.windows {
  background-image: " paper-noise ";
  background-size: 200px 200px;
  background-blend-mode: multiply;
}
/* The sheet. Paper is fibre and mottle: noise at the scale of a
   character, and the places where the pulp settled thick or thin. No
   rules, no hatching. A sheet has no lines on it until someone draws one.

   The grain is a layer of its own, not the pane background-image. Four
   rules in the stylesheet set the `background` SHORTHAND on a window, one
   per state, and a shorthand resets background-image to none: the pane in
   front of you kept coming back flat. A pseudo-element under the text
   cannot be reset by any of them. */
.window::after {
  content: \"\"; position: absolute; inset: 0; z-index: 0;
  pointer-events: none; mix-blend-mode: multiply;
  background-image:
    " paper-noise ",
    radial-gradient(ellipse at 84% 88%, rgba(150, 122, 78, 0.16) 0%, rgba(150, 122, 78, 0) 58%),
    radial-gradient(ellipse at 12% 18%, rgba(160, 134, 88, 0.12) 0%, rgba(160, 134, 88, 0) 50%),
    radial-gradient(ellipse at 52% 46%, rgba(150, 122, 78, 0.07) 0%, rgba(150, 122, 78, 0) 62%);
  background-size: 200px 200px, auto, auto, auto;
}
/* the text, the bars and the rows ride above the grain */
.window > * { position: relative; z-index: 1; }
/* the minibuffer and the echo area are cut from the same sheet */
.echo-bar, .echo-area, .mb-panel, .buffer-footer {
  background-image: " paper-noise ";
  background-size: 200px 200px;
  background-blend-mode: multiply;
}
/* a sheet has a lit top edge and a shadow under it, always */
.window.active {
  box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.72), var(--chrome-shadow);
}
.window.inactive { box-shadow: 0 1px 2px rgba(74, 58, 36, 0.10); }
/* the chrome is written on the sheet, not printed on a band */
.modeline, .window.active .modeline {
  background: transparent;
  border-top: 1px solid var(--border-soft-bg);
}
.buffer-header {
  background: transparent;
  border-bottom: 1px solid var(--border-bg);
  font-family: var(--font-serif);
  font-weight: 600; font-style: italic; letter-spacing: 0.01em;
  font-size: 12.5px; text-transform: none;
}
/* pencil in the margin leans; ink on the page does not */
.linenum { font-style: italic; }
.buf { text-rendering: optimizeLegibility; }
"))
;;; --- brut: the black rule and the hard shadow -------------------------------
;;; Neobrutalism. Every surface is a flat colour on an amber desk, every box
;;; wears a thick black rule, and a box that lifts drops a solid black shadow
;;; with no blur. Nothing is rounded, nothing fades, nothing is translucent.
;;; The colours are the ones a poster is printed in: one red, one blue, one
;;; green, one violet, and no tints between them.

(define-theme "brut"
  (list
    ;; the syntax is printed, not shaded: flat ink and a heavy weight
    (list 'ts-keyword 'fg "#d1002e" 'weight "700")
    (list 'ts-function 'fg "#2b53ff" 'weight "700")
    (list 'ts-string 'fg "#146b32")
    (list 'ts-comment 'fg "#7d7868" 'style "italic")
    (list 'ts-number 'fg "#8b31c7" 'weight "600")
    (list 'ts-constant 'fg "#8b31c7" 'weight "600")
    (list 'ts-type 'fg "#b34a00" 'weight "700")
    (list 'ts-module 'fg "#b34a00" 'weight "700")
    (list 'ts-operator 'fg "#000000" 'weight "700")
    (list 'ts-punctuation 'fg "#4a4a4a")
    (list 'ts-tag 'fg "#d1002e" 'weight "700")
    (list 'ts-attribute 'fg "#8b31c7")
    (list 'ts-variable 'fg "#000000")
    (list 'ts-property 'fg "#b34a00")
    (list 'ts-escape 'fg "#d1002e" 'weight "700")
    ;; the desk is a flat yellow, the panes are white cards on it
    (list 'default 'bg "#ecd47f" 'fg "#000000")
    (list 'window 'bg "#fffdf7")
    (list 'paper 'bg "#fffdf7")
    (list 'window-inactive 'bg "#efeadb")
    (list 'body 'fg "#1a1a1a")
    ;; there is one rule, and it is black
    (list 'border-soft 'bg "#000000")
    (list 'border 'bg "#000000")
    (list 'modeline 'bg "#efeadb" 'fg "#3a3a3a")
    (list 'modeline-active 'bg "#ecd47f" 'fg "#000000")
    (list 'cursor 'bg "#000000")
    ;; a selection is a highlighter, a match is the other highlighter
    (list 'region 'bg "#b8ff3d")
    (list 'select 'bg "#ff9ecb")
    (list 'hl-line 'bg "#f9eab0")
    (list 'linenum 'fg "#8c8676")
    (list 'accent 'fg "#2b53ff")
    (list 'link 'fg "#2b53ff" 'decoration "underline")
    (list 'llm-response 'fg "#2b53ff")
    (list 'llm-prompt 'inherit 'llm-response)
    (list 'diff-block 'fg "#b34a00" 'weight "600")
    (list 'diff-block-source 'fg "#7d7868")
    (list 'dim 'fg "#5c5648")
    (list 'faint 'fg "#8c8676")
    (list 'warn 'fg "#b34a00" 'weight "700")
    (list 'ok 'fg "#146b32" 'weight "700")
    (list 'alert 'fg "#d1002e" 'weight "700")
    (list 'org-level-1 'fg "#d1002e" 'weight "800")
    (list 'org-level-2 'fg "#2b53ff" 'weight "800")
    (list 'org-level-3 'fg "#146b32" 'weight "700")
    (list 'org-level-4 'fg "#8b31c7" 'weight "700")
    ;; six groups, six poster colours, no tints
    (list 'group-color-1 'fg "#d1002e")
    (list 'group-color-2 'fg "#2b53ff")
    (list 'group-color-3 'fg "#146b32")
    (list 'group-color-4 'fg "#8b31c7")
    (list 'group-color-5 'fg "#b34a00")
    (list 'group-color-6 'fg "#00807a")
    (list 'org-todo 'fg "#d1002e" 'weight "800")
    (list 'org-done 'fg "#146b32" 'decoration "line-through")
    (list 'org-priority 'fg "#b34a00" 'weight "800")
    (list 'org-date 'fg "#2b53ff" 'weight "600")
    (list 'org-tag 'fg "#5c5648")
    (list 'org-checkbox 'fg "#146b32" 'weight "800")
    (list 'org-cookie 'fg "#8b31c7" 'weight "600")
    (list 'org-meta 'fg "#7d7868")
    (list 'fold-marker 'fg "#d1002e" 'weight "700")
    (list 'nm-date 'fg "#5c5648")
    (list 'nm-author 'fg "#2b53ff" 'weight "600")
    (list 'nm-tags 'fg "#146b32")
    (list 'nm-subject 'fg "#000000")
    (list 'nm-marked 'fg "#d1002e" 'weight "800")
    (list 'nm-hdr 'fg "#b34a00" 'weight "700")
    (list 'nm-sep 'fg "#000000")
    (list 'diff-file 'fg "#000000" 'weight "800")
    (list 'diff-hunk 'fg "#2b53ff" 'weight "600")
    (list 'diff-add 'fg "#0f4f24" 'bg "#ddffb0")
    (list 'diff-del 'fg "#8f0020" 'bg "#ffd4e5")
    (list 'diff-add-word 'bg "#b8ff3d")
    (list 'diff-del-word 'bg "#ff9ecb")
    (list 'code-scope 'bg "#f7eecd")
    ;; a poster is set in a grotesque, and the prose is set in it too
    (list 'sans 'family "'Archivo', 'Inter', 'Helvetica Neue', Helvetica, Arial, sans-serif")
    (list 'serif 'inherit 'sans)
    ;; the rule is three pixels of black, the lift is a solid shadow, and
    ;; the gap is wide enough to see the shadow fall
    (list 'chrome 'gap "10px" 'radius "0"
          'border "3px solid #000000"
          'shadow "5px 5px 0 #000000"
          'shadow-deep "9px 9px 0 #000000")))

(define-theme-skin! "brut" "
/* A box is a black rule and a shadow with no blur. Both are constants
   here, not steps on a scale: neobrutalism has one rule weight and one
   shadow, and the only thing that changes is whether a box has them. */
.window {
  border: 3px solid var(--border-bg);
  box-shadow: 4px 4px 0 var(--border-bg);
}
.window.inactive { box-shadow: 4px 4px 0 var(--border-bg); }
.window.active { box-shadow: 6px 6px 0 var(--border-bg); }
.window.active:has(.dash-state-focus) {
  box-shadow: 10px 10px 0 var(--border-bg);
  border-color: var(--border-bg);
}
.window.active:has(.dash-state-editing) { box-shadow: 6px 6px 0 var(--border-bg); }
/* the desk shows between the cards, so the cards need room to drop */
.windows { gap: 12px; padding: 4px 12px 12px 4px; }

/* A mode line is the amber strip, ruled off the sheet above it. The bar
   stays light on purpose: every fact in it draws in dim or faint ink, and
   a knocked-out bar would leave the facts unreadable. The rule carries
   the weight, not an inversion. */
.modeline {
  border-top: 3px solid var(--border-bg);
  text-transform: uppercase; letter-spacing: 0.06em; font-weight: 700;
}
/* a heading is a printed label: the same strip, ruled underneath */
.buffer-header {
  border-bottom: 3px solid var(--border-bg);
  text-transform: uppercase; letter-spacing: 0.08em; font-weight: 800;
}
.buffer-footer, .dash-live, .dash-top { border-color: var(--border-bg); }

/* a tab is a chip with a rule round it; the one you are on is filled */
.ml-tab {
  border: 2px solid var(--border-bg); padding: 1px 8px;
  text-transform: uppercase; letter-spacing: 0.05em; font-weight: 700;
}
.ml-tab-on {
  background: var(--accent-fg); color: var(--window-bg);
  box-shadow: 3px 3px 0 var(--border-bg); text-decoration: none;
}

/* the echo area is the strip under the desk, ruled off from it */
.echo-bar, .echo-area { border-color: var(--border-bg); border-width: 3px; }

/* a prompt is the loudest box on the screen: the thickest rule and the
   deepest drop, because a modal stops everything behind it */
.mb-panel {
  border: 4px solid var(--border-bg);
  box-shadow: 12px 12px 0 var(--border-bg);
}
.mb-head, .mb-sep { border-color: var(--border-bg); }
.mb-head-title, .mb-sep-label, .mb-label {
  text-transform: uppercase; letter-spacing: 0.08em; font-weight: 800;
}
.mb-cand.selected, .mb-rail-row.selected {
  background: var(--region-bg); border-left-color: var(--border-bg);
}
.mb-preview { border-left: 3px solid var(--border-bg); }

/* the transient is the same box, and its keys are printed keycaps */
.transient-key, .transient-legend-key, .ag-kind, .transient-chip {
  border: 2px solid var(--border-bg); background: var(--hl-line-bg);
  color: var(--default-fg); font-weight: 800;
}
.transient-item.selected { background: var(--region-bg); }
.transient-head, .transient-group-title {
  border-color: var(--border-bg);
  text-transform: uppercase; letter-spacing: 0.08em; font-weight: 800;
}

/* the transcript's cards are cards: a rule and a drop, like everything */
.ag-user {
  border: 3px solid var(--border-bg);
  box-shadow: 4px 4px 0 var(--border-bg);
}
.ag-tool, .ag-thought, .ag-perm, .ag-question {
  border: 3px solid var(--border-bg) !important;
  box-shadow: 4px 4px 0 var(--border-bg);
}
.ag-btn {
  border: 2px solid var(--border-bg); background: var(--window-bg);
  box-shadow: 3px 3px 0 var(--border-bg); font-weight: 800;
}
.ag-label, .ag-title { text-transform: uppercase; letter-spacing: 0.06em; }
.ag-prose code, .ag-prose pre {
  border: 2px solid var(--border-bg);
}
")

;;; --- maharaja: the printed plate, ink and five colours ----------------------
;;; Amar Chitra Katha, on newsprint. The page is turmeric cream, the rule
;;; around a panel is printed ink, and every panel drops a hard shadow the
;;; way a plate sits proud of the page under it. A quiet panel wears a
;;; gold caption strip; the panel in hand wears the hero's blue. Five
;;; printer's colours carry the rest: crimson, royal blue, parrot green,
;;; royal purple, and the ochre a comic book uses for skin and sand alike.

(define-theme "maharaja"
  (list
    (list 'ts-keyword 'fg "#163a7a" 'weight "700")
    (list 'ts-function 'fg "#241407")
    (list 'ts-string 'fg "#1f6b3d")
    (list 'ts-comment 'fg "#8a7550")
    (list 'ts-number 'fg "#8a5a12")
    (list 'ts-constant 'fg "#8a5a12")
    (list 'ts-type 'fg "#8a5a12")
    (list 'ts-module 'fg "#8a5a12")
    (list 'ts-operator 'fg "#5c4a2e")
    (list 'ts-punctuation 'fg "#5c4a2e")
    (list 'ts-tag 'fg "#c62828" 'weight "700")
    (list 'ts-attribute 'fg "#6a2f8f")
    (list 'ts-variable 'fg "#2e2210")
    (list 'ts-property 'fg "#5c4a2e")
    (list 'ts-escape 'fg "#8a5a12")
    (list 'default 'bg "#f4e4c1" 'fg "#241407")
    (list 'window 'bg "#faf1dc")
    (list 'paper 'bg "#f0dfb8")
    (list 'body 'fg "#3a2814")
    (list 'border-soft 'bg "#e3cd9a")
    (list 'window-inactive 'bg "#ede0bd")
    ;; a quiet panel wears the caption strip; the panel in hand wears the
    ;; hero's blue, cream lettering, the way a title box breaks the page
    (list 'modeline 'bg "#e3cd9a" 'fg "#4a3510")
    (list 'modeline-active 'bg "#163a7a" 'fg "#f4e4c1")
    (list 'cursor 'bg "#c62828")
    (list 'region 'bg "#f6d98a")
    (list 'accent 'fg "#163a7a")
    (list 'link 'fg "#0e7373" 'decoration "underline")
    (list 'llm-response 'fg "#163a7a" 'style "italic")
    (list 'llm-prompt 'inherit 'llm-response)
    (list 'diff-block 'fg "#8a5a12" 'style "italic")
    (list 'diff-block-source 'fg "#8a7550" 'style "italic")
    (list 'dim 'fg "#8a7550")
    (list 'select 'bg "#f0c07a")
    (list 'hl-line 'bg "#ecdcae")
    (list 'linenum 'fg "#c2ab7a")
    (list 'border 'bg "#241407")
    (list 'warn 'fg "#c1571a")
    (list 'faint 'fg "#c2ab7a")
    (list 'ok 'fg "#1f6b3d")
    (list 'alert 'fg "#c62828")
    (list 'org-level-1 'fg "#c62828" 'weight "700")
    (list 'org-level-2 'fg "#163a7a" 'weight "600")
    (list 'org-level-3 'fg "#1f6b3d" 'weight "600")
    (list 'org-level-4 'fg "#6a2f8f" 'weight "600")
    ;; the group scale: five printer's colours and the ochre, the palette
    ;; a plate is actually run in
    (list 'group-color-1 'fg "#c62828")
    (list 'group-color-2 'fg "#163a7a")
    (list 'group-color-3 'fg "#1f6b3d")
    (list 'group-color-4 'fg "#6a2f8f")
    (list 'group-color-5 'fg "#8a5a12")
    (list 'group-color-6 'fg "#0e7373")
    (list 'org-todo 'fg "#c62828" 'weight "700")
    (list 'org-done 'fg "#1f6b3d" 'decoration "line-through")
    (list 'org-priority 'fg "#8a5a12" 'weight "600")
    (list 'org-date 'fg "#163a7a" 'style "italic")
    (list 'org-tag 'fg "#8a7550")
    (list 'org-checkbox 'fg "#163a7a" 'weight "600")
    (list 'org-cookie 'fg "#8a5a12")
    (list 'org-meta 'fg "#8a7550")
    (list 'fold-marker 'fg "#8a7550")
    (list 'nm-date 'fg "#6b5c3e")
    (list 'nm-author 'fg "#163a7a" 'weight "400" 'style "italic")
    (list 'nm-tags 'fg "#8a5a12")
    (list 'nm-subject 'fg "#2e2210")
    (list 'nm-marked 'fg "#c62828" 'weight "700")
    (list 'nm-hdr 'fg "#163a7a" 'weight "700")
    (list 'nm-sep 'fg "#b39a68")
    (list 'diff-file 'fg "#163a7a" 'weight "600")
    (list 'diff-hunk 'fg "#8a5a12")
    (list 'diff-add 'fg "#1a5c33" 'bg "rgba(31, 107, 61, 0.14)")
    (list 'diff-del 'fg "#8f1c1c" 'bg "rgba(198, 40, 40, 0.12)")
    (list 'diff-add-word 'bg "rgba(31, 107, 61, 0.32)")
    (list 'diff-del-word 'bg "rgba(198, 40, 40, 0.28)")
    (list 'code-scope 'bg "rgba(22, 58, 122, 0.08)")
    ;; a plate sits proud of the page: square corners, ink around every
    ;; edge, a hard shadow with no blur
    (list 'chrome 'gap "6px" 'radius "3px"
          'border "2px solid #241407"
          'shadow "0 10px 26px rgba(36, 20, 7, 0.22)"
          'shadow-deep "0 18px 46px rgba(36, 20, 7, 0.30)")))

;; the desk between the panels: a jali screen cut in stone, ink on cream
(define maharaja-jali
  "url(\"data:image/svg+xml,%3Csvg%20xmlns=%27http://www.w3.org/2000/svg%27%20width=%2764%27%20height=%2764%27%3E%3Cg%20fill=%27none%27%20stroke=%27%23241407%27%20stroke-width=%271%27%20opacity=%270.10%27%3E%3Cpath%20d=%27M32%200%20L64%2032%20L32%2064%20L0%2032%20Z%27/%3E%3Cpath%20d=%27M32%2012%20L52%2032%20L32%2052%20L12%2032%20Z%27/%3E%3Ccircle%20cx=%2732%27%20cy=%2732%27%20r=%276%27/%3E%3Cpath%20d=%27M32%200%20L32%2012%20M32%2052%20L32%2064%20M0%2032%20L12%2032%20M52%2032%20L64%2032%27/%3E%3C/g%3E%3C/svg%3E\")")

;; the same lattice, cut fine, for a caption strip that has only a few
;; pixels to carve in
(define maharaja-jali-fine
  "url(\"data:image/svg+xml,%3Csvg%20xmlns=%27http://www.w3.org/2000/svg%27%20width=%2724%27%20height=%2724%27%3E%3Cg%20fill=%27none%27%20stroke=%27%23241407%27%20stroke-width=%270.75%27%20opacity=%270.14%27%3E%3Cpath%20d=%27M12%200%20L24%2012%20L12%2024%20L0%2012%20Z%27/%3E%3Ccircle%20cx=%2712%27%20cy=%2712%27%20r=%272.5%27/%3E%3C/g%3E%3C/svg%3E\")")

;; every panel is bossed at its four corners: a carved rosette, gold at
;; the centre, the way a haveli door is fitted with a brass medallion
(define maharaja-medallion
  "url(\"data:image/svg+xml,%3Csvg%20xmlns=%27http://www.w3.org/2000/svg%27%20width=%2722%27%20height=%2722%27%3E%3Cg%20fill=%27none%27%20stroke=%27%23241407%27%20stroke-width=%271%27%3E%3Ccircle%20cx=%2711%27%20cy=%2711%27%20r=%279%27/%3E%3Ccircle%20cx=%2711%27%20cy=%2711%27%20r=%275.5%27/%3E%3Cpath%20d=%27M11%202%20L11%205.5%20M11%2016.5%20L11%2020%20M2%2011%20L5.5%2011%20M16.5%2011%20L20%2011%20M4.6%204.6%20L7.1%207.1%20M14.9%2014.9%20L17.4%2017.4%20M4.6%2017.4%20L7.1%2014.9%20M14.9%207.1%20L17.4%204.6%27/%3E%3C/g%3E%3Ccircle%20cx=%2711%27%20cy=%2711%27%20r=%272%27%20fill=%27%23b3821a%27%20stroke=%27%23241407%27%20stroke-width=%271%27/%3E%3C/svg%3E\")")

(define-theme-skin! "maharaja" (string-append "
/* the desk between the panels: a jali screen, cut in stone */
.windows {
  background-image: " maharaja-jali ";
  background-size: 64px 64px;
}
/* a panel is ink around the edge and a hard drop, never a soft lift */
.window, .window.active, .window.inactive,
.window.active:has(.dash-state-focus),
.window.active:has(.dash-state-editing) { box-shadow: none; }
.window {
  border: 2px solid var(--border-bg);
  box-shadow: 4px 4px 0 rgba(36, 20, 7, 0.55);
}
.window.inactive { box-shadow: 2px 2px 0 rgba(36, 20, 7, 0.30); }
.window.active { box-shadow: 5px 5px 0 var(--accent-fg); }
.window.active:has(.dash-state-focus) { box-shadow: 6px 6px 0 var(--accent-fg); }
/* the medallion at each corner, on every panel alike */
.window::before {
  content: ''; position: absolute; inset: 0; z-index: 7;
  pointer-events: none;
  background-image: " maharaja-medallion ", " maharaja-medallion ", " maharaja-medallion ", " maharaja-medallion ";
  background-repeat: no-repeat;
  background-position: 2px 2px, calc(100% - 24px) 2px, 2px calc(100% - 24px), calc(100% - 24px) calc(100% - 24px);
}
/* the page behind the words: a cover painting's colours, turned down
   past where they'd name themselves, the way a plate's ground still
   warms the paper under the ink. Jungle green, gold, a touch of
   crimson and peacock, each pooling where a painted cover pools it. */
.buf {
  background-image:
    radial-gradient(ellipse at 14% 18%, rgba(31, 107, 61, 0.05) 0%, rgba(31, 107, 61, 0) 55%),
    radial-gradient(ellipse at 88% 12%, rgba(198, 40, 40, 0.035) 0%, rgba(198, 40, 40, 0) 50%),
    radial-gradient(ellipse at 50% 92%, rgba(217, 164, 65, 0.06) 0%, rgba(217, 164, 65, 0) 60%),
    radial-gradient(ellipse at 92% 88%, rgba(22, 58, 122, 0.035) 0%, rgba(22, 58, 122, 0) 55%);
}
/* the caption strip: gold quiet, the hero's blue when the panel speaks,
   carved fine because a strip has only a few pixels to give it */
.modeline, .window.active .modeline {
  border-top: 2px solid var(--border-bg);
  background-image: " maharaja-jali-fine ";
  text-transform: uppercase; letter-spacing: 0.06em; font-weight: 700;
}
/* the title panel: a caption box ruled off the page, set in full caps */
.buffer-header {
  border-bottom: 2px solid var(--border-bg);
  background-image: " maharaja-jali-fine ";
  text-transform: uppercase; letter-spacing: 0.05em; font-weight: 700;
}
/* a tab is a paper tag stitched to the strip; the open one is inked in */
.ml-tab {
  border: 1px solid var(--border-bg); padding: 1px 7px;
  text-transform: uppercase; letter-spacing: 0.04em; font-weight: 600;
}
.ml-tab-on {
  background: var(--accent-fg); color: var(--window-bg);
  border-color: var(--accent-fg);
}
.buffer-footer, .dash-live, .dash-top, .echo-bar, .echo-area { border-color: var(--border-bg); }
.echo-bar, .echo-area {
  border-width: 2px;
  background-image: " maharaja-jali-fine ";
}
/* a prompt is the splash panel: the thickest rule and the deepest drop */
.mb-panel {
  border: 3px solid var(--border-bg); box-shadow: 8px 8px 0 rgba(36, 20, 7, 0.45);
  background-image: " maharaja-jali-fine ";
}
.mb-head-title, .mb-sep-label, .mb-label {
  text-transform: uppercase; letter-spacing: 0.06em; font-weight: 700;
}
"))

;;; --- the faces a package can count on -------------------------------------
;;; The theme owns the colours. These defaults own the shape of the syntax
;;; faces and give the Emacs names a home, so a package written for Emacs
;;; finds font-lock-keyword-face and a list can say "success". Each Emacs
;;; name inherits the compos face that draws the same thing; a theme that
;;; names the compos face restyles both.

;; syntax: weight and slant are shape, and a theme may override them
(defface! 'ts-keyword 'weight "600")
(defface! 'ts-function 'weight "500")
(defface! 'ts-comment 'style "italic")
(defface! 'ts-type 'weight "500")
(defface! 'ts-module 'weight "500")
(defface! 'ts-tag 'weight "600")

;; the capture heads a grammar emits beyond the ones every theme colours;
;; each takes the colour of the nearest face a theme does name
(defface! 'ts-label 'inherit 'ts-keyword)
(defface! 'ts-conditional 'inherit 'ts-keyword)
(defface! 'ts-repeat 'inherit 'ts-keyword)
(defface! 'ts-include 'inherit 'ts-keyword)
(defface! 'ts-exception 'inherit 'ts-keyword)
(defface! 'ts-parameter 'inherit 'ts-variable)
(defface! 'ts-field 'inherit 'ts-property)
(defface! 'ts-constructor 'inherit 'ts-type)
(defface! 'ts-boolean 'inherit 'ts-constant)
(defface! 'ts-float 'inherit 'ts-number)
(defface! 'ts-character 'inherit 'ts-string)
(defface! 'ts-namespace 'inherit 'ts-module)
(defface! 'ts-delimiter 'inherit 'ts-punctuation)
(defface! 'ts-method 'inherit 'ts-function)
(defface! 'ts-macro 'inherit 'ts-function)

;; the Emacs faces, on the compos faces that draw the same thing
(defface! 'font-lock-keyword-face 'inherit 'ts-keyword)
(defface! 'font-lock-function-name-face 'inherit 'ts-function)
(defface! 'font-lock-string-face 'inherit 'ts-string)
(defface! 'font-lock-comment-face 'inherit 'ts-comment)
(defface! 'font-lock-doc-face 'inherit 'ts-comment)
(defface! 'font-lock-constant-face 'inherit 'ts-constant)
(defface! 'font-lock-type-face 'inherit 'ts-type)
(defface! 'font-lock-variable-name-face 'inherit 'ts-variable)
(defface! 'font-lock-builtin-face 'inherit 'ts-keyword)
(defface! 'font-lock-preprocessor-face 'inherit 'ts-attribute)
(defface! 'font-lock-warning-face 'inherit 'alert)
(defface! 'mode-line 'inherit 'modeline)
(defface! 'mode-line-active 'inherit 'modeline-active)
(defface! 'modeline-inactive 'inherit 'window-inactive)
(defface! 'mode-line-inactive 'inherit 'modeline-inactive)
(defface! 'header-line 'inherit 'modeline)
(defface! 'line-number 'inherit 'linenum)
;; The row under point. On a dark ground a 3-4 point lift off the window
;; background reads as nothing, so every theme keeps a ladder against its
;; own `window' bg: hl-line near 1.6:1, select above it, region above that.
(defface! 'highlight 'inherit 'hl-line)
(defface! 'shadow 'inherit 'dim)
(defface! 'error 'inherit 'alert)
(defface! 'warning 'inherit 'warn)
(defface! 'success 'inherit 'ok)
(defface! 'minibuffer-prompt 'inherit 'accent)
(defface! 'isearch 'inherit 'region)
(defface! 'lazy-highlight 'inherit 'select)
(defface! 'match 'inherit 'select)
(defface! 'vertical-border 'inherit 'border)
(defface! 'bold 'weight "700")
(defface! 'italic 'style "italic")
(defface! 'underline 'decoration "underline")
(defface! 'bold-italic 'weight "700" 'style "italic")
(defface! 'fixed-pitch 'family "var(--font-mono)")
(defface! 'variable-pitch 'family "var(--font-sans)")

;; The three grounds and inks the design names that no theme named yet.
;; `paper` is the ground a pane and the chrome bars share: it sits between
;; the frame canvas and a raised popup. A theme that does not name it keeps
;; the window ground, so nothing moves. `body` is prose: one step back from
;; the strongest ink and one step ahead of a label. `border-soft` is a
;; separator inside a pane, lighter than the frame's own border.
(defface! 'paper 'bg "var(--window-bg)")
(defface! 'body 'fg "color-mix(in srgb, var(--default-fg) 66%, var(--dim-fg))")
(defface! 'border-soft 'bg "color-mix(in srgb, var(--border-bg) 55%, var(--window-bg))")

;; the chat transcript reads these by variable; each is a compos face
(defface! 'agent-meta 'inherit 'dim)
(defface! 'agent-thought 'inherit 'dim)
(defface! 'agent-queued 'inherit 'faint)
(defface! 'agent-tool 'inherit 'accent)
(defface! 'agent-permission 'inherit 'warn)

;; The transcript's three grounds. The stylesheet reads them by variable,
;; and no theme named them, so every theme wore the light-theme literals
;; in editor.css: a blue wash on the card you typed in, and two washes of
;; black on a dark pane. Each one is now a step from the pane the theme
;; itself supplies, so a dark theme gets a dark step. A theme that wants
;; to say something else names the face.
(defface! 'agent-you 'bg "color-mix(in srgb, var(--accent-fg) 12%, var(--window-bg))")
(defface! 'agent-code 'bg "color-mix(in srgb, var(--default-bg) 62%, var(--window-bg))")
(defface! 'agent-card 'border "var(--border-soft-bg)")

;; The terminal is a face, not a constant. The xterm pane reads these
;; variables when it opens, and again after a theme change, so `M-x shell'
;; wears the theme the editor wears. Each ANSI colour takes the theme face
;; that draws the same thing. A theme that wants its own palette names the
;; ansi-color-* faces, as Emacs does.
(defface! 'terminal 'bg "var(--window-bg)" 'fg "var(--default-fg)"
                    'family "var(--font-mono)" 'size "var(--default-size)")
(defface! 'terminal-cursor 'bg "var(--cursor-bg)")
(defface! 'terminal-select 'bg "var(--select-bg)")

;; A theme names three chromatic colours that mean something: alert, ok and
;; warn. They are the ANSI red, green and yellow. A theme does not name a
;; blue, a magenta and a cyan that stay apart, so each of those three is the
;; theme's accent pulled toward a fixed hue. The theme supplies the tint and
;; the anchor keeps the six hues distinct. A theme that wants exact terminal
;; colours names the ansi-color-* faces itself.
(defface! 'ansi-color-black 'fg "color-mix(in srgb, var(--default-fg) 30%, var(--default-bg))")
(defface! 'ansi-color-red 'inherit 'alert)
(defface! 'ansi-color-green 'inherit 'ok)
(defface! 'ansi-color-yellow 'inherit 'warn)
(defface! 'ansi-color-blue 'fg "color-mix(in srgb, var(--accent-fg) 70%, #4f8fd6)")
(defface! 'ansi-color-magenta 'fg "color-mix(in srgb, var(--accent-fg) 45%, #c072d8)")
(defface! 'ansi-color-cyan 'fg "color-mix(in srgb, var(--accent-fg) 45%, #3fb6c2)")
(defface! 'ansi-color-white 'fg "color-mix(in srgb, var(--default-fg) 80%, var(--default-bg))")

;; A bright colour is the same hue with more contrast against the paper,
;; so each one steps toward the theme's own strongest ink. This holds for
;; a light theme and for a dark theme.
(defface! 'ansi-color-bright-black 'inherit 'dim)
(defface! 'ansi-color-bright-red 'fg "color-mix(in srgb, var(--ansi-color-red-fg) 75%, var(--default-fg))")
(defface! 'ansi-color-bright-green 'fg "color-mix(in srgb, var(--ansi-color-green-fg) 75%, var(--default-fg))")
(defface! 'ansi-color-bright-yellow 'fg "color-mix(in srgb, var(--ansi-color-yellow-fg) 75%, var(--default-fg))")
(defface! 'ansi-color-bright-blue 'fg "color-mix(in srgb, var(--ansi-color-blue-fg) 75%, var(--default-fg))")
(defface! 'ansi-color-bright-magenta 'fg "color-mix(in srgb, var(--ansi-color-magenta-fg) 75%, var(--default-fg))")
(defface! 'ansi-color-bright-cyan 'fg "color-mix(in srgb, var(--ansi-color-cyan-fg) 75%, var(--default-fg))")
(defface! 'ansi-color-bright-white 'fg "var(--default-fg)")

;; the prompt previews: the theme under the highlight goes on screen as
;; you move, a rest at a time; RET keeps it and writes it, C-g puts the
;; theme you had back
(define theme-preview-ms 80)

(define (theme--preview! pick)
  ;; PICK is (NAME FRAME): debounce! hands the callback one value
  (let ((n (string-trim (car pick))))
    (when (assoc n *themes*) (theme--put! n (cadr pick)))))

(define-command "load-theme" "Choose a color theme, previewing each as you move; RET keeps it"
  (lambda ()
    (let* ((frame (selected-frame))
           (own? (and (frame-local-in frame 'isolated) #t))
           (before (if own? (frame-theme frame) *current-theme*))
           (now (lambda () (if own? (frame-theme frame) *current-theme*))))
      (minibuffer-read-preview "Load theme: " (history-order 'theme (theme-names))
        (lambda (name)
          (debounce! "theme-preview" theme-preview-ms theme--preview! (list name frame)))
        (lambda (name)
          (let ((n (string-trim name)))
            (history-push! 'theme n)
            (load-theme n)))
        (lambda ()
          (when (and (or own? before) (not (equal? before (now))))
            (theme--put! before frame))
          (message (string-append "Kept theme " (or before *current-theme* ""))))))))

;;; boot: reapply the persisted theme choice (written by load-theme).
;;; A home with no choice yet boots into the design's warm dark.
(if (file-exists? (theme-file))
    (load (theme-file))
    (theme-apply! "paper-night"))

(category! 'faces)
(public! 'load-theme "(load-theme NAME) — switch color theme (persists)")
(public! 'theme-apply! "(theme-apply! NAME) — put NAME's faces on screen without persisting; #t, or #f for no such theme")
(public! 'frame-theme-apply! "(frame-theme-apply! NAME [FRAME]) — FRAME wears NAME on its own; NAME #f gives it the global theme again")
(public! 'frame-theme "(frame-theme [FRAME]) -> the theme FRAME wears on its own, or #f")
(public! 'theme-current "(theme-current) -> the theme on screen in this frame")
(public! 'defface! "(defface! FACE ATTR VALUE ...) — a package's default face, attribute by attribute; an attribute the theme names wins. 'inherit names a face or a list of faces; 'priority orders overlapping overlays")
(public! 'face-clear! "(face-clear! FACE) — forget every attribute of FACE")
(public! 'theme-faces "(theme-faces NAME) -> the theme's face specs")
(public! 'define-theme-skin! "(define-theme-skin! NAME CSS) — the stylesheet NAME wears beside its faces; a theme load installs exactly one")
(public! 'theme-skin "(theme-skin NAME) -> the CSS NAME wears, or \"\" for a theme with no skin")
(public! 'theme-dark? "(theme-dark?) -> #t when the current theme has a dark default background")
(public! 'face-color "(face-color FACE ATTR) -> the value FACE wears now, theme first and the package default after; #f when neither names ATTR")
(public! '*themes* "The theme registry: ((name . spec) ...)")

(catalog-meta! 'function "theme-dark?" 'domain 'faces 'effects '(read))
(catalog-meta! 'function "face-color" 'domain 'faces 'effects '(read))
