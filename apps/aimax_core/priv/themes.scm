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

(define (theme-names) (map car *themes*))

(define (load-theme name)
  (let ((t (assoc name *themes*)))
    (if t
        (begin
          (for-each (lambda (spec) (apply set-face-attribute! spec)) (cadr t))
          (message (string-append "Loaded theme " name)))
        (message (string-append "No such theme: " name)))))

;;; --- palettes ---------------------------------------------------------------

(define-theme "paper"                ; the design default (light) — restorable
  (list
    (list 'default 'bg "#e6e0d2" 'fg "#1b1a17")
    (list 'window 'bg "#fdfcf8")
    (list 'window-inactive 'bg "#f4f0e6")
    (list 'modeline 'bg "#eae5da" 'fg "#57534a")
    (list 'modeline-active 'bg "#e7e9f1" 'fg "#1b1a17")
    (list 'cursor 'bg "#26356b")
    (list 'region 'bg "#e7e9f1")
    (list 'accent 'fg "#26356b")
    (list 'dim 'fg "#8a857a")
    (list 'select 'bg "#e7e9f1")
    (list 'hl-line 'bg "#f5f1e6")
    (list 'linenum 'fg "#b3ac9c")
    (list 'border 'bg "#cbc4b1")
    (list 'warn 'fg "#7a5a1a")))

(define-theme "paper-night"          ; the design's warm dark
  (list
    (list 'default 'bg "#100f0c" 'fg "#efe9dc")
    (list 'window 'bg "#201d18")
    (list 'window-inactive 'bg "#161410")
    (list 'modeline 'bg "#2c2822" 'fg "#b3aa99")
    (list 'modeline-active 'bg "#282f4a" 'fg "#efe9dc")
    (list 'cursor 'bg "#9fb0ea")
    (list 'region 'bg "#282f4a")
    (list 'accent 'fg "#9fb0ea")
    (list 'dim 'fg "#a79d8c")
    (list 'select 'bg "#282f4a")
    (list 'hl-line 'bg "#262218")
    (list 'linenum 'fg "#4a443a")
    (list 'border 'bg "#39342b")
    (list 'warn 'fg "#d5ac66")))

(define-theme "aimax-dark"
  (list
    (list 'default 'bg "#1e1f22" 'fg "#d6d8de")
    (list 'window 'bg "#23242a")
    (list 'window-inactive 'bg "#1e1f22")
    (list 'modeline 'bg "#2f3140" 'fg "#8b8fa3")
    (list 'modeline-active 'bg "#3b4261" 'fg "#d6d8de")
    (list 'cursor 'bg "#c0caf5")
    (list 'region 'bg "#31436e")
    (list 'accent 'fg "#7aa2f7")
    (list 'dim 'fg "#8b8fa3")
    (list 'select 'bg "#2c3a5e")
    (list 'hl-line 'bg "#26272e")
    (list 'linenum 'fg "#4a4d59")
    (list 'border 'bg "#15161a")
    (list 'warn 'fg "#e0af68")))

(define-theme "catppuccin-mocha"
  (list
    (list 'default 'bg "#1e1e2e" 'fg "#cdd6f4")
    (list 'window 'bg "#181825")
    (list 'window-inactive 'bg "#11111b")
    (list 'modeline 'bg "#313244" 'fg "#a6adc8")
    (list 'modeline-active 'bg "#45475a" 'fg "#cdd6f4")
    (list 'cursor 'bg "#f5e0dc")
    (list 'region 'bg "#45475a")
    (list 'accent 'fg "#cba6f7")
    (list 'dim 'fg "#6c7086")
    (list 'select 'bg "#313244")
    (list 'hl-line 'bg "#232338")
    (list 'linenum 'fg "#45475a")
    (list 'border 'bg "#11111b")
    (list 'warn 'fg "#fab387")))

(define-theme "tokyo-night"
  (list
    (list 'default 'bg "#1a1b26" 'fg "#c0caf5")
    (list 'window 'bg "#16161e")
    (list 'window-inactive 'bg "#1a1b26")
    (list 'modeline 'bg "#24283b" 'fg "#565f89")
    (list 'modeline-active 'bg "#414868" 'fg "#c0caf5")
    (list 'cursor 'bg "#c0caf5")
    (list 'region 'bg "#33467c")
    (list 'accent 'fg "#7aa2f7")
    (list 'dim 'fg "#565f89")
    (list 'select 'bg "#292e42")
    (list 'hl-line 'bg "#1f2029")
    (list 'linenum 'fg "#3b4261")
    (list 'border 'bg "#101014")
    (list 'warn 'fg "#e0af68")))

(define-command "load-theme"
  (lambda ()
    (minibuffer-read "Load theme: " (theme-names)
      (lambda (name) (load-theme name)))))
