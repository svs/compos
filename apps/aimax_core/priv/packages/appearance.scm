;;; appearance.scm --- the chrome the user sets: rendered-page typography.
;;;
;;; The client reads the 'preview face for every rendered page — browse,
;;; markdown previews, help. The values live HERE, as settings: these
;;; defaults are one taste, and customize-save! or init.scm replaces
;;; them like any other setting. M-x preview-font-toggle flips between
;;; the serif and the monospace stacks.

(domain! 'ui)
(effects! '(write))

(define *preview-serif* "Spectral,Georgia,serif")
(define *preview-mono* "'IBM Plex Mono',ui-monospace,Menlo,monospace")

(defcustom 'preview-font-family *preview-serif*
  "Font family for rendered pages: previews, browse, help."
  'group 'appearance
  'set (lambda (v) (set-face-attribute! 'preview 'family v)))

(defcustom 'preview-font-size "16.5px"
  "Font size for rendered pages."
  'group 'appearance
  'set (lambda (v) (set-face-attribute! 'preview 'size v)))

;; defcustom stores the value; the face must say it too, on load and
;; after a restart
(set-face-attribute! 'preview
  'family preview-font-family
  'size preview-font-size)

(define-command "preview-font-toggle"
  "Switch rendered pages between the serif and the monospace stacks"
  (lambda ()
    (let ((mono? (string-contains? preview-font-family "Mono")))
      (customize-set! 'preview-font-family
                      (if mono? *preview-serif* *preview-mono*))
      (customize-set! 'preview-font-size (if mono? "16.5px" "14.5px"))
      (message (if mono? "rendered pages: serif" "rendered pages: monospace")))))

(category! 'ui)
(public! 'preview-font-toggle
  "(run-command \"preview-font-toggle\") — flip rendered pages between serif and monospace")
