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

(define (define-theme name faces)
  (set! *themes* (cons (list name faces) *themes*)))

;; a theme built on another (dup #33): BASE's faces, with OVERRIDES
;; replacing every face they name. The base must be defined first.
(define (define-theme-from name base overrides)
  (let* ((b (assoc base *themes*))
         (named (map car overrides))
         (kept (filter (lambda (f) (not (member (car f) named)))
                       (if b (car (cdr b)) '()))))
    (define-theme name (append overrides kept))))

(define (theme-names) (map car *themes*))

(define (theme-file) (string-append (aimax-config-dir) "/theme.scm"))

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
  (assoc face (theme-faces *current-theme*)))

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

(define (defface! face &rest attrs)
  (set! *face-defaults*
        (cons (cons face attrs)
              (filter (lambda (d) (not (equal? (car d) face))) *face-defaults*)))
  (if (theme-face-spec face)
      #f
      (apply set-face-attribute! (cons face attrs))))

(define (load-theme name)
  (let ((t (assoc name *themes*)))
    (if t
        (begin
          (set! *current-theme* name)
          ;; the package defaults first: a face the new theme does not name
          ;; falls back to its default, not to the last theme's color
          (for-each (lambda (d) (apply set-face-attribute! d)) *face-defaults*)
          (for-each (lambda (spec) (apply set-face-attribute! spec)) (cadr t))
          (persist-theme! name)
          (run-hooks 'theme-change-hook)
          (message (string-append "Loaded theme " name)))
        (message (string-append "No such theme: " name)))))

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
    (list 'default 'bg "#e6e0d2" 'fg "#1b1a17")
    (list 'window 'bg "#fdfcf8")
    (list 'window-inactive 'bg "#f4f0e6")
    (list 'modeline 'bg "#eae5da" 'fg "#57534a")
    (list 'modeline-active 'bg "#e7e9f1" 'fg "#1b1a17")
    (list 'cursor 'bg "#26356b")
    (list 'region 'bg "#e7e9f1")
    (list 'accent 'fg "#26356b")
    (list 'link 'fg "#26356b" 'decoration "underline")
    (list 'llm-response 'fg "#26356b" 'style "italic")
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
    (list 'nm-date 'fg "#8a8a8a")
    (list 'nm-author 'fg "#26356b")
    (list 'nm-tags 'fg "#9a9a72")
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
    (list 'chrome 'gap "6px" 'radius "5px"
          'border "1px solid #d5cdb9"
          'shadow "0 2px 10px rgba(27, 26, 23, 0.07)")))

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
    (list 'default 'bg "#100f0c" 'fg "#efe9dc")
    (list 'window 'bg "#201d18")
    (list 'window-inactive 'bg "#161410")
    (list 'modeline 'bg "#2c2822" 'fg "#b3aa99")
    (list 'modeline-active 'bg "#282f4a" 'fg "#efe9dc")
    (list 'cursor 'bg "#9fb0ea")
    (list 'region 'bg "#282f4a")
    (list 'accent 'fg "#9fb0ea")
    (list 'link 'fg "#9fb0ea" 'decoration "underline")
    (list 'llm-response 'fg "#9fb0ea" 'style "italic")
    (list 'dim 'fg "#a79d8c")
    (list 'select 'bg "#282f4a")
    (list 'hl-line 'bg "#262218")
    (list 'linenum 'fg "#4a443a")
    (list 'border 'bg "#39342b")
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
    (list 'chrome 'gap "6px" 'radius "5px"
          'border "1px solid #39342b"
          'shadow "0 2px 14px rgba(0, 0, 0, 0.35)")))

(define-theme "aimax-dark"
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
    (list 'default 'bg "#1e1f22" 'fg "#d6d8de")
    (list 'window 'bg "#23242a")
    (list 'window-inactive 'bg "#1e1f22")
    (list 'modeline 'bg "#2f3140" 'fg "#8b8fa3")
    (list 'modeline-active 'bg "#3b4261" 'fg "#d6d8de")
    (list 'cursor 'bg "#c0caf5")
    (list 'region 'bg "#31436e")
    (list 'accent 'fg "#7aa2f7")
    (list 'link 'fg "#7aa2f7" 'decoration "underline")
    (list 'llm-response 'fg "#7aa2f7" 'style "italic")
    (list 'dim 'fg "#8b8fa3")
    (list 'select 'bg "#2c3a5e")
    (list 'hl-line 'bg "#26272e")
    (list 'linenum 'fg "#4a4d59")
    (list 'border 'bg "#15161a")
    (list 'warn 'fg "#e0af68")
    ;; the list faces: a column label and a rule are fainter than
    ;; `dim`, and a list says good and bad in one word
    (list 'faint 'fg "#4a4d59")
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
    (list 'chrome 'gap "6px" 'radius "5px"
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
    (list 'default 'bg "#1e1e2e" 'fg "#cdd6f4")
    (list 'window 'bg "#181825")
    (list 'window-inactive 'bg "#11111b")
    (list 'modeline 'bg "#313244" 'fg "#a6adc8")
    (list 'modeline-active 'bg "#45475a" 'fg "#cdd6f4")
    (list 'cursor 'bg "#f5e0dc")
    (list 'region 'bg "#45475a")
    (list 'accent 'fg "#cba6f7")
    (list 'link 'fg "#89b4fa" 'decoration "underline")
    (list 'llm-response 'fg "#cba6f7" 'style "italic")
    (list 'dim 'fg "#6c7086")
    (list 'select 'bg "#313244")
    (list 'hl-line 'bg "#232338")
    (list 'linenum 'fg "#45475a")
    (list 'border 'bg "#11111b")
    (list 'warn 'fg "#fab387")
    ;; the list faces: a column label and a rule are fainter than
    ;; `dim`, and a list says good and bad in one word
    (list 'faint 'fg "#45475a")
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
    (list 'chrome 'gap "6px" 'radius "5px"
          'border "1px solid #11111b"
          'shadow "0 2px 14px rgba(0, 0, 0, 0.4)")))

;; built on aimax-dark: it inherits the strings, types, cursor, warn and
;; diff faces and overrides the rest of the palette
(define-theme-from "tokyo-night" "aimax-dark"
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
    (list 'window 'bg "#16161e")
    (list 'window-inactive 'bg "#1a1b26")
    (list 'modeline 'bg "#24283b" 'fg "#565f89")
    (list 'modeline-active 'bg "#414868" 'fg "#c0caf5")
    (list 'region 'bg "#33467c")
    (list 'dim 'fg "#565f89")
    (list 'select 'bg "#292e42")
    (list 'hl-line 'bg "#1f2029")
    (list 'linenum 'fg "#3b4261")
    (list 'border 'bg "#101014")
    (list 'chrome 'gap "6px" 'radius "5px"
          'border "1px solid #101014"
          'shadow "0 2px 14px rgba(0, 0, 0, 0.4)")))

(define-command "load-theme" "Prompt for a color theme and apply it"
  (lambda ()
    (minibuffer-read "Load theme: " (history-order 'theme (theme-names))
      (lambda (name)
        (history-push! 'theme name)
        (load-theme name)))))

;;; boot: reapply the persisted theme choice (written by load-theme)
(if (file-exists? (theme-file)) (load (theme-file)))

(category! 'faces)
(public! 'load-theme "(load-theme NAME) — switch color theme (persists)")
(public! 'defface! "(defface! FACE ATTR VALUE ...) — a package's default face; the theme wins")
(public! 'theme-faces "(theme-faces NAME) -> the theme's face specs")
(public! 'theme-dark? "(theme-dark?) -> #t when the current theme has a dark default background")
(public! '*themes* "The theme registry: ((name . spec) ...)")

(catalog-meta! 'function "theme-dark?" 'domain 'faces 'effects '(read))
