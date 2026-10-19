;;; ambient.scm --- the ambient page of what plays, and its stager.
;;;
;;; The page to glance at while a song plays: one photo fills the stage and
;;; breathes, and the facts swirl over it, a few at a time. For each song a
;;; stager, a cheap model, reads the facts the digger found and plans the
;;; page to suit the music: its mood, its pace, its photo and which facts to
;;; tell. Until the plan comes, the page shows what it has.

(define spotify-ambient-parent-package *loading-package*)
(define spotify-ambient-parent-namespace *loading-namespace*)
(define spotify-ambient-parent-domain *catalog-domain*)
(define spotify-ambient-parent-effects *catalog-effects*)

(package! 'spotify-ambient 'spotify)
(domain! 'spotify)
(effects! '(write))

(defcustom 'spotify-stage #t
  "Whether a stager plans the ambient page for each song: its mood, its pace, its photo and its facts."
  'group 'spotify 'type 'boolean)

;;; --- the stage ---------------------------------------------------------------

(define spotify--stage-seconds 9)
(define spotify--swirl-gap 12)
(define spotify--swirl-most 6)

(define (spotify--pace pace)
  ;; how much longer than medium everything takes
  (cond ((equal? pace "slow") 1.5) ((equal? pace "fast") 0.7) (else 1)))

(define (spotify--ambient-stage images pace)
  ;; one photo holds the stage and breathes, zooming slowly in and back out;
  ;; more than one take turns, each fading in as the one before fades out
  (let ((n (min 8 (length images))) (m (spotify--pace pace)))
    (cond ((= n 0) '())
          ((= n 1)
           (list (list 'tag "div" 'class "sp-montage sp-stage sp-hold"
                       'attrs (list (list "style" (string-append "background-image:url('" (car images) "');"
                                                                   "animation-duration:" (number->string (* 40 m)) "s"))))))
          (else
           (let ((s (* m spotify--stage-seconds)))
             (let loop ((is (list-head images n)) (i 0) (acc '()))
               (if (null? is) (reverse acc)
                   (let ((dx (list-ref '("3%" "-3%" "2%" "-2%") (remainder i 4)))
                         (dy (list-ref '("-2%" "2%" "2%" "-2%") (remainder i 4))))
                     (loop (cdr is) (+ i 1)
                           (cons (list 'tag "div" 'class "sp-montage sp-stage"
                                       'attrs (list (list "style" (string-append "background-image:url('" (car is) "');"
                                                                                   "--sp-dx:" dx ";--sp-dy:" dy ";"
                                                                                   "animation:sp-stage-" (number->string n) " "
                                                                                   (number->string (* n s)) "s linear infinite;"
                                                                                   "animation-delay:" (number->string (- (* i s) (* s 0.35))) "s"))))
                                 acc))))))))))

(define spotify--swirl-slots
  ;; where each fact drifts: left and top in percent, how far it drifts
  ;; in pixels, and the seconds of one drift. They take the left column and
  ;; the right in turn, so the two about at once never meet, and keep to the
  ;; top of the stage, clear of the title
  '((4 8 30 90) (56 14 30 95) (6 30 25 110) (58 34 25 105) (4 18 30 100) (56 4 30 85)))

(define (spotify--ambient-swirl facts headline pace)
  ;; the facts loose on the stage: each drifts slowly about a point of its
  ;; own, never turning, and fades in on its turn and out again, so one or
  ;; two are about at a time. HEADLINE, the index of the fact the stager put
  ;; first, is the largest
  (let* ((facts (if (> (length facts) spotify--swirl-most) (list-head facts spotify--swirl-most) facts))
         (facts (if (and (> (length facts) 1) (= 1 (remainder (length facts) 2))) (list-head facts (- (length facts) 1)) facts))
         (n (length facts)) (m (spotify--pace pace)))
    (let loop ((fs facts) (i 0) (acc '()))
      (if (null? fs) (reverse acc)
          (let* ((slot (list-ref spotify--swirl-slots (remainder i (length spotify--swirl-slots))))
                 (num (lambda (k) (number->string (list-ref slot k))))
                 (head (and headline (= i headline)))
                 (size (if head "1.8em" (list-ref '("1.3em" "1.1em" "1.2em") (remainder i 3))))
                 (life (if (< n 2) "opacity:1"
                           (string-append "animation:sp-swirl-" (number->string n) " " (number->string (* n m spotify--swirl-gap)) "s linear infinite;animation-delay:-" (number->string (* i m spotify--swirl-gap)) "s"))))
            (loop (cdr fs) (+ i 1)
                  (cons (list 'tag "div" 'class (if head "sp-swirl sp-swirl-head" "sp-swirl")
                              'attrs (list (list "style" (string-append "left:" (num 0) "%;top:" (num 1) "%;font-size:" size ";"
                                                                          life)))
                              'children (list (list 'tag "div" 'class "sp-swirl-in"
                                                    'attrs (list (list "style" (string-append "--sp-r:" (num 2) "px;animation-duration:" (number->string (* m (list-ref slot 3))) "s;animation-delay:-" (number->string (* i 17)) "s")))
                                                    'children (list (spotify--text "sp-fact-label" (car (car fs)))
                                                                    (spotify--text "sp-swirl-text" (cadr (car fs)))))))
                        acc)))))))

(define (spotify--ambient-css)
  ;; the stage's cycle for each count of photos: a turn is its share, the
  ;; photo fades in over the first third of it while the one before fades
  ;; out, and pans and zooms from its first frame to its last. A fact's life
  ;; for each count of facts: it fades in, stays about a turn and a half, and fades out
  (let ((pct (lambda (tenths) (string-append (number->string (quotient tenths 10)) "." (number->string (remainder tenths 10)) "%")))
        (from "transform: scale(1.04) translate(calc(var(--sp-dx) * -1), calc(var(--sp-dy) * -1));")
        (to "transform: scale(1.16) translate(var(--sp-dx), var(--sp-dy));"))
    (string-append
      (apply string-append
        (map (lambda (n)
               (let* ((turn (quotient 1000 n)) (fade (quotient (* turn 35) 100)))
                 (string-append "@keyframes sp-stage-" (number->string n) " { "
                                "0% { opacity: 0; " from " } "
                                (pct fade) " { opacity: 1; } "
                                (pct turn) " { opacity: 1; } "
                                (pct (+ turn fade)) " { opacity: 0; " to " } "
                                "100% { opacity: 0; " to " } }\n")))
             (list 2 3 4 5 6 7 8)))
      (apply string-append
        (map (lambda (n)
               (let* ((turn (quotient 1000 n)) (fade (quotient (* turn 35) 100)) (span (quotient (* turn (if (> n 2) 3 2)) 2)))
                 (string-append "@keyframes sp-swirl-" (number->string n) " { "
                                "0% { opacity: 0; } "
                                (pct fade) " { opacity: 1; } "
                                (pct span) " { opacity: 1; } "
                                (pct (+ span fade)) " { opacity: 0; } "
                                "100% { opacity: 0; } }\n")))
             (list 2 3 4 5 6 7 8 9 10 11 12)))
      "@keyframes sp-hold { from { transform: scale(1.02); } to { transform: scale(1.14) translate(-1.5%, -1%); } }\n"
      "@keyframes sp-drift { 0%, 100% { transform: translate3d(0, 0, 0); } 25% { transform: translate3d(var(--sp-r), calc(var(--sp-r) * -0.5), 0); } 50% { transform: translate3d(calc(var(--sp-r) * 0.3), calc(var(--sp-r) * -1), 0); } 75% { transform: translate3d(calc(var(--sp-r) * -0.7), calc(var(--sp-r) * -0.4), 0); } }\n"
      ".sp-ambient > .sp-stage { will-change: opacity, transform; }\n"
      ".sp-ambient > .sp-hold { opacity: 1; animation: sp-hold 40s ease-in-out infinite alternate; }\n"
      ".sp-ambient > .sp-ambient-veil { background: linear-gradient(180deg, rgba(0,0,0,.15), color-mix(in srgb, var(--sp-tint, #000) 35%, transparent) 45%, color-mix(in srgb, var(--sp-tint, #000) 80%, black) 100%); }\n"
      ".sp-swirl { position: absolute; z-index: 1; max-width: 38cqw; opacity: 0; pointer-events: none; will-change: transform, opacity; }\n"
      ".sp-swirl-in { animation: sp-drift 90s ease-in-out infinite; will-change: transform; display: flex; flex-direction: column; align-items: center; gap: 4px; text-align: center; }\n"
      ".sp-swirl .sp-fact-label { font-size: .5em; }\n"
      ".sp-swirl-text { font-weight: 600; line-height: 1.3; text-wrap: balance; color: white; text-shadow: 0 2px 18px rgba(0,0,0,.75); }\n"
      ".sp-swirl-head { max-width: 38cqw; }\n"
      ".sp-swirl-head .sp-swirl-text { font-weight: 800; letter-spacing: -.01em; }\n"
      ".sp-ambient:not(.sp-ambient-on) .sp-swirl, .sp-ambient:not(.sp-ambient-on) .sp-swirl-in, .sp-ambient:not(.sp-ambient-on) > .sp-stage { animation-play-state: paused; }\n"
      "@media (prefers-reduced-motion: reduce) { .sp-swirl-in { animation: none; } .sp-ambient > .sp-hold { animation-name: none; } }\n")))

(define-style! 'spotify-ambient (spotify--ambient-css))

(defcomponent 'spotify/ambient
  "The page of what plays, to glance at: one photo fills the stage and breathes, the facts swirl over it a few at a time, and the title sits under them. PACE is slow, medium or fast; HEADLINE the index of the fact told largest; TINT the colour of the veil. FACTS is ((LABEL TEXT) ...)."
  '((title string required) (artists string optional) (art string optional) (images list optional)
    (facts list optional) (headline number optional) (pace string optional) (tint string optional)
    (playing? boolean optional) (position string optional) (duration string optional))
  '(title "Windowpane" artists "Opeth" playing? #t pace "slow" headline 0 facts (("From" "Damnation · 2003") ("On the record" "Steven Wilson — producer")) position "2:10" duration "7:44")
  (lambda (p)
    (let* ((art (component--get p 'art ""))
           (tint (component--get p 'tint ""))
           (pace (component--get p 'pace "medium"))
           (facts (let ((fs (component--get p 'facts '()))) (if (> (length fs) 12) (list-head fs 12) fs))))
      (list 'tag "div" 'class (if (component--get p 'playing? #f) "sp-ambient sp-ambient-on" "sp-ambient")
            'attrs (list (list "style" (string-append (if (equal? art "") "" (string-append "--sp-art:url('" art "');"))
                                                        (if (equal? tint "") "" (string-append "--sp-tint:" tint ";")))))
            'children
            (append (spotify--ambient-stage (component--get p 'images '()) pace)
                    (list (list 'tag "div" 'class "sp-ambient-veil"))
                    (spotify--ambient-swirl facts (component--get p 'headline #f) pace)
                    (list (list 'tag "div" 'class "sp-ambient-main"
                                'children (list (list 'tag "div" 'class "sp-ambient-side"
                                                      'children (list (spotify--text "sp-ambient-title" (component--get p 'title ""))
                                                                      (spotify--text "sp-ambient-artists" (component--get p 'artists ""))
                                                                      (cell-part 'spotify/progress
                                                                        (spotify--progress "sp-np-progress" (component--get p 'position "") (component--get p 'duration "")))))))))))))

;;; --- the stager --------------------------------------------------------------

(define (spotify--stage-key name title) (string-append name " | " title))

(define (spotify--stage-prompt name album title facts)
  (string-append "You stage a music listener's ambient screen for the song now playing: " title " by " name
    ", from the album " album ". One photo fills the screen and a few facts drift slowly over it. "
    "Plan it to suit the music. Answer exactly these five lines and nothing else:\n"
    "MOOD: one or two words for the feel of the song\n"
    "PACE: slow, medium or fast, how quickly the screen moves\n"
    "PHOTO: artist or cover\n"
    "TINT: a dark hex colour that suits the mood, like #1a2a4a\n"
    "FACTS: the numbers of up to 8 facts below most worth telling, best first, comma separated\n\nFacts:\n"
    (let loop ((fs facts) (i 1) (acc '()))
      (if (null? fs) (string-join (reverse acc) "\n")
          (loop (cdr fs) (+ i 1) (cons (string-append (number->string i) ". " (car (car fs)) ": " (cadr (car fs))) acc))))))

(define (spotify--stage-parse answer count)
  ;; the plan from the stager's five lines, or #f when it named no facts
  (let* ((field (lambda (key)
                  (let loop ((ls (string-split (if (string? answer) answer "") "\n")))
                    (cond ((null? ls) "")
                          ((string-prefix? (string-append key ":") (string-upcase (string-trim (car ls))))
                           (let ((l (string-trim (car ls)))) (string-trim (substring l (+ (string-length key) 1) (string-length l)))))
                          (else (loop (cdr ls)))))))
         (pace (string-downcase (field "PACE")))
         (tint (field "TINT"))
         (picks (filter (lambda (i) (and (integer? i) (>= i 0) (< i count)))
                        (map (lambda (s) (let ((x (string->number (string-trim s)))) (and x (- x 1))))
                             (string-split (field "FACTS") ",")))))
    (and (pair? picks)
         (list 'mood (string-downcase (field "MOOD"))
               'pace (if (member pace '("slow" "medium" "fast")) pace "medium")
               'photo (if (equal? (string-downcase (field "PHOTO")) "cover") "cover" "artist")
               'tint (if (and (= (string-length tint) 7) (string-prefix? "#" tint)) tint "")
               'facts (if (> (length picks) 8) (list-head picks 8) picks)
               'count count))))

(define (spotify-stage-purge!)
  ;; a song's plan goes with the song: when the track changes every plan and
  ;; every ask is dropped, so nothing of a stager outlives its track
  (for-each (lambda (e) (site-app-cache-drop! 'spotify 'stages (car e))) (site-app-cache-entries 'spotify 'stages))
  (set! *spotify-asked* (filter (lambda (k) (not (string-prefix? "stage:" k))) *spotify-asked*))
  (spotify--cache-touch!))

(define (spotify--stage-playing? title)
  (equal? title (spotify--now-field 'title)))

(define (spotify-stage! name album title facts)
  ;; once a song, while it plays and when the digger has found enough to
  ;; choose from: ask the stager for the page's plan, file it under the song,
  ;; and draw it. An answer that lands after the song has gone is dropped
  (let ((key (spotify--stage-key name title)))
    (when (and spotify-stage (not (equal? name "")) (not (equal? title "")) (>= (length facts) 4) (spotify--stage-playing? title)
               (not (spotify--get 'stages key)) (spotify--ask! (string-append "stage:" key)))
      (llm-with-model (spotify--stage-prompt name album title facts) spotify-dig-model
        (lambda (answer)
          (let ((plan (spotify--stage-parse answer (length facts))))
            (when (and plan (spotify--stage-playing? title))
              (spotify--put! 'stages key plan)
              (spotify--redraw-artist-tabs!))))
        (lambda (err) #f)))))

(define (spotify--staged plan images cover facts)
  ;; the page's props as PLAN stages them: its photos, the one it chose first, its facts in the
  ;; stager's order and then whatever the digger found since, the first of
  ;; them told largest. Without a plan, the photos and the facts as found
  (if (not plan)
      (list 'images images 'facts facts 'pace "medium")
      (let ((photo (if (and (equal? (plist-get plan 'photo) "cover") (string? cover) (not (equal? cover "")))
                       cover
                       (and (pair? images) (car images))))
            (picked (filter pair? (map (lambda (i) (and (< i (length facts)) (list-ref facts i))) (plist-get plan 'facts))))
            (since (let ((c (plist-get plan 'count))) (if (< c (length facts)) (list-tail facts c) '()))))
        (list 'images (if photo (cons photo (filter (lambda (u) (not (equal? u photo))) images)) images) 'facts (append picked since) 'headline 0
              'pace (plist-get plan 'pace) 'tint (plist-get plan 'tint)))))

(public! 'spotify-stage-purge! "(spotify-stage-purge!) — drop every stager plan and ask; the track change runs it")
(public! 'spotify-stage! "(spotify-stage! NAME ALBUM TITLE FACTS) — once a song, ask the stager to plan the ambient page from FACTS, file the plan, and redraw")

(provide 'spotify-ambient)

;; Do not leak this extension's catalog context into the next package.
(package! spotify-ambient-parent-package spotify-ambient-parent-namespace)
(domain! spotify-ambient-parent-domain)
(effects! spotify-ambient-parent-effects)
