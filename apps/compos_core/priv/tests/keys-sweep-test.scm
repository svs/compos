;;; keys-sweep-test.scm --- every key of every core mode leads to a live command
;;; through the ladder. The sweep enters each major mode and each minor
;;; mode in a fresh buffer and resolves each of its keys the way a press
;;; would. It reports every broken key at once.

(domain! 'testing)
(effects! '(write))

;; the table is read at check time: a list mode defines its flag
;; commands as it installs them. keymap:NAME is a prefix key that leads
;; to a keymap, live when the keymap exists.
(define (sweep--live? cmd names)
  (and (string? cmd)
       (or (and (member cmd names) #t)
           (and (string-prefix? "keymap:" cmd)
                (member (substring cmd 7 (string-length cmd)) (keymap-names))
                #t))))

(define (sweep--check-keymap km names seen)
  (if (or (not km) (member km seen) (not (member km (keymap-names))))
      '()
      (let ((own (let loop ((rows (keymap-bindings km)) (bad '()))
                   (if (null? rows)
                       (reverse bad)
                       (let* ((keys (car (car rows)))
                              (cmd (cadr (car rows))))
                         (loop (cdr rows)
                               (if (sweep--live? cmd names)
                                   bad
                                   (cons (list km keys cmd "no such command") bad))))))))
        (append own (sweep--check-keymap (keymap-parent km) names (cons km seen))))))

;; the keys a buffer answers that are not the global map's, resolved
(define (sweep--check-buffer buf names)
  (let loop ((rows (local-keys buf)) (bad '()))
    (if (null? rows)
        (reverse bad)
        (let* ((keys (car (car rows)))
               (cmd (cadr (car rows)))
               (hit (key-binding keys)))
          (loop (cdr rows)
                (cond ((not (sweep--live? cmd names))
                       (cons (list buf keys cmd "no such command") bad))
                      ((not (or (equal? hit cmd) (equal? hit 'prefix)
                                ;; a remap answers another command by design
                                (and (string? hit) (sweep--live? hit names))))
                       (cons (list buf keys cmd (string-append "resolves to " (if hit (if (string? hit) hit "prefix") "nothing"))) bad))
                      (else bad)))))))

(define sweep--skip-modes
  ;; modes whose setup needs a file, a process, a connection, or the
  ;; locals the command that opens them writes first
  '("Dired" "dired-mode" "pdf-reader-mode" "pdf-edit-mode" "browser-file-mode"
    "chat-mode" "spreadsheet-mode" "term-mode" "comint-shell-mode"
    "occur-ts-mode" "telemetry-detail-mode"))

(deftest 'every-major-mode-key-leads-to-a-live-command
  "inspect every major mode's keymap hierarchy; each of its keys leads to a live command"
  (lambda ()
    (let ((names (command-names)) (bad '()) (checked 0))
      (for-each
        (lambda (mode)
          (unless (string-prefix? "zz-" mode)
            (let ((km (mode-keymap mode)))
              (when km
                (set! checked (+ checked 1))
                (set! bad (append bad (sweep--check-keymap km names '())))))))
        (mode-names 'major))
      (check-true! (> checked 20) "the sweep checked the major mode keymaps")
      (check-equal! bad '() "every key of every mode leads to a live command"))))

(deftest 'every-minor-mode-key-leads-to-a-live-command
  "inspect every minor mode's keymap; each of its keys leads to a live command"
  (lambda ()
    (let ((names (command-names)) (bad '()))
      (for-each
        (lambda (mode)
          (unless (string-prefix? "zz-" mode)
            (let ((km (minor-mode-keymap mode)))
              (when km
                (set! bad (append bad (sweep--check-keymap km names '())))))))
        (mode-names 'minor))
      (check-equal! bad '() "every key of every minor mode leads to a live command"))))

(deftest 'every-named-keymap-binds-live-commands
  "the mode maps, the minor maps, the pseudo-buffer maps: all their commands exist"
  (lambda ()
    (let ((names (command-names)) (bad '()))
      (for-each
        (lambda (map)
          (unless (string-prefix? "zz-" map)
            (for-each
              (lambda (row)
                (unless (sweep--live? (cadr row) names)
                  (set! bad (cons (list map (car row) (cadr row)) bad))))
              (keymap-bindings map))))
        (keymap-names))
      (check-equal! bad '() "every keymap binding names a live command"))))

(deftest 'the-hard-paths-are-keymaps-now
  "a printable, the digits after C-u, the popup's keys and Transient's all come from a map"
  (lambda ()
    (check-equal! (key-binding "a") "self-insert-command" "a printable is a global binding")
    (check-equal! (key-binding "SPC") "self-insert-command" "and so is SPC")
    (check-equal! (keymap-lookup "universal-argument-map" "3") "digit-argument" "a digit after C-u")
    (check-equal! (keymap-lookup " *completion*" "x") "self-insert-command" "typing into the popup")
    (check-equal! (keymap-lookup " *completion*" "DEL") "completion-delete-backward" "DEL in the popup")
    (check-true! (member "transient-map" (keymap-names)) "Transient has a keymap")))

(deftest 'a-list-mode-answers-to-its-own-map-under-list-mode-map
  "the flags a list declares are on its map; every list's keys are the parent"
  (lambda ()
    (check-equal! (keymap-parent (mode-keymap "ibuffer-mode")) "list-mode-map" "the parent")
    (check-equal! (keymap-lookup (mode-keymap "ibuffer-mode") "d") "list-flag-D" "a declared flag key")
    (check-equal! (keymap-lookup (mode-keymap "ibuffer-mode") "<") "list-cycle-grouping" "grouping is reserved")
    (check-equal! (keymap-lookup (mode-keymap "ibuffer-mode") ">") "list-cycle-sorting" "sorting is reserved")
    (check-equal! (keymap-lookup (mode-keymap "ibuffer-mode") "/") "list-filter" "the filter, through the parent")
    (check-equal! (keymap-lookup "list-mode-map" "f") "list-facets" "facets on the parent map")
    (check-equal! (keymap-lookup (mode-keymap "ibuffer-mode") "?") "list-keys-toggle" "the keys card, through the parent")))
