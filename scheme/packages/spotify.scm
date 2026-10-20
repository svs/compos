;;; spotify.scm --- Spotify as a website app.
;;;
;;; The web player is the site. site-app reads its pages in a hidden reader
;;; tab -- Home, Liked Songs, your playlists, a search -- and draws them
;;; here with the components below. Music never plays in the reader: playing
;;; a row drives your own player tab, where Chrome already knows who you are.
;;; No API keys, no OAuth, no proxy.
;;;
;;; The player is a web page, so its buttons are DOM nodes. Spotify names
;;; them with `data-testid`, the most stable handle the page gives us. The
;;; sheets that read the pages are web/parsers/spotify-rows.xsl and
;;; web/parsers/spotify-detail.xsl.

(package! 'spotify)
(require 'site-app)
(require 'cell)

(domain! 'spotify)
(effects! '(write))

(defgroup 'spotify "The Spotify web player, as an app in the editor.")

(defcustom 'spotify-url "https://open.spotify.com/"
  "The page the player runs in." 'group 'spotify)

(defcustom 'spotify-player "auto"
  "Where the music plays. auto: the desktop app while it runs, else the web player; desktop or web: always that one. Browsing, search and likes always read the web page." 'group 'spotify)

(defcustom 'spotify-user ""
  "Your Spotify user id, the last part of your profile's /user/ID link. The Playlists section reads that profile."
  'group 'spotify)

(defcustom 'spotify-own-group #f
  "Whether Spotify lives in a group of its own, so calling it goes there. Off, it opens in whatever group you are in."
  'group 'spotify 'type 'boolean)

(defcustom 'spotify-dig #t
  "Whether an agent keeps digging up facts about what plays while the ambient page is on screen."
  'group 'spotify 'type 'boolean)

(defcustom 'spotify-dig-source 'google
  "Where the digger reads: 'google, the search server; 'exa, Exa's search with page text (EXA_API_KEY); 'browser, a search page read in your own Chrome."
  'group 'spotify 'type 'choice)

(defcustom 'spotify-dig-model "claude-haiku-4-5-20251001"
  "The cheap model that turns what the digger reads into facts."
  'group 'spotify)

(defcustom 'spotify-dig-seconds 75
  "Seconds between two digs while the ambient page is on screen."
  'group 'spotify)

;;; --- the components -----------------------------------------------------------
;;; Pure: props in, one block out. A track and a tile take the props a ui/card
;;; takes (title, icon, badge, tags), so site-app can draw them on an item's
;;; page as it draws any card, keys and anchors included.

(domain! 'ui)
(effects! '(pure))

(define (spotify--seconds text)
  ;; "4:05" or "1:02:03" as seconds; anything else is 0
  (if (re-match? "^[0-9]+(:[0-9]+)*$" (or text ""))
      (fold (lambda (sum n) (+ (* sum 60) n)) 0 (map string->number (string-split text ":")))
      0))

(define (spotify--img class src)
  (list 'tag "img" 'class class
        'attrs (list (list "src" src) (list "alt" "") (list "loading" "lazy") (list "referrerpolicy" "no-referrer"))))

;; a cover, or the title's first letter where the page drew none
(define (spotify--cover class src title)
  (if (and (string? src) (not (equal? src "")))
      (spotify--img class src)
      (list 'tag "span" 'class (string-append class " sp-blank")
            'text (if (> (string-length (or title "")) 0) (string-upcase (substring title 0 1)) "♪"))))

(define (spotify--text class text) (list 'tag "span" 'class class 'text (or text "")))

(define (spotify--card-base p tag class children)
  ;; the ui/card a site-app page asks for, keeping its anchor and keys, drawn as ours
  (plist-put (plist-put (plist-put (component 'ui/card p) 'tag tag) 'class class) 'children children))

(defcomponent 'spotify/track
  "One track as a row: its number (an equaliser when it is the one playing), the cover, the title over its artists, the album and the length. TAGS is (ARTISTS ALBUM DURATION) and BADGE the number, as site-app hands a card; the named props win."
  '((title string required) (icon string optional) (badge string optional) (tags list optional)
    (artists string optional) (album string optional) (duration string optional) (released string optional) (playing? boolean optional)
    (open? boolean optional) (body blocks optional) (class string optional) (lines list optional) (mark string optional)
    (anchor-name string optional) (anchor-keymap string optional) (anchor-data list optional))
  '(title "Windowpane" artists "Opeth" album "Damnation" duration "7:44" badge "1")
  (lambda (p)
    (let* ((tags (component--get p 'tags '()))
           (tag (lambda (i) (if (> (length tags) i) (nth i tags) "")))
           (playing? (component--get p 'playing? #f)))
      (spotify--card-base p "div" (string-append "sp-track" (if playing? " sp-playing" ""))
        (list (spotify--text "sp-idx" (if playing? "▶" (component--get p 'badge "")))
              (spotify--cover "sp-art" (component--get p 'icon "") (component--get p 'title ""))
              (list 'tag "div" 'class "sp-main"
                    'children (list (spotify--text "sp-name" (component--get p 'title ""))
                                    (spotify--text "sp-by" (component--get p 'artists (tag 0)))))
              (spotify--text "sp-album" (component--get p 'album (tag 1)))
              (spotify--text "sp-date" (component--get p 'released ""))
              (spotify--text "sp-dur" (component--get p 'duration (tag 2))))))))

(defcomponent 'spotify/tile
  "A playlist, album or artist as a row: the cover (round for an artist), the name, and under it the kind and what the site says of it. BADGE is the kind, TAGS the subtitle."
  '((title string required) (icon string optional) (badge string optional) (tags list optional) (released string optional)
    (open? boolean optional) (body blocks optional) (class string optional) (lines list optional) (mark string optional)
    (anchor-name string optional) (anchor-keymap string optional) (anchor-data list optional))
  '(title "Discover Weekly" badge "playlist" tags ("Your shortcut to hidden gems"))
  (lambda (p)
    (let* ((kind (component--get p 'badge ""))
           (line (let ((t (component--get p 'tags '()))) (if (pair? t) (car t) "")))
           ;; an album's line is "2016 • The Pineapple Thief": the year is a pill of its own
           (year (and (re-match? "^[0-9]{4} • " line) (substring line 0 4)))
           (sub (if year (substring line 7 (string-length line)) line)))
      (spotify--card-base p "div" (string-append "sp-tile sp-kind-" kind)
        (list (spotify--cover "sp-cover" (component--get p 'icon "") (component--get p 'title ""))
              (list 'tag "div" 'class "sp-main"
                    'children (list (spotify--text "sp-name" (component--get p 'title ""))
                                    (list 'tag "span" 'class "sp-by"
                                          'children (append (if (equal? kind "") '() (list (spotify--text "sp-chip" kind)))
                                                            (let ((day (component--get p 'released "")))
                                                              (cond ((not (equal? day "")) (list (spotify--text "sp-year" day)))
                                                                    (year (list (spotify--text "sp-year" year)))
                                                                    (else '())))
                                                            (list (spotify--text "sp-sub" sub)))))))))))

(define (spotify--facts tags skip)
  ;; the header's short facts, "Made for" joined to the name it introduces.
  ;; The release and the label have a line of their own, and the bare year
  ;; goes when the whole date is there
  (let* ((dated? (pair? (filter (lambda (t) (string-prefix? "Released " t)) tags)))
         (keep? (lambda (t) (and (not (equal? t "")) (not (equal? t skip)) (<= (string-length t) 70)
                                 (not (spotify--release-line? t))
                                 (not (and dated? (re-match? "^[0-9]{4}$" t)))))))
    (let loop ((ts (filter keep? tags)) (acc '()))
      (cond ((null? ts) (reverse acc))
            ((and (pair? (cdr ts)) (re-match? "(?i)( |^)(for|by)$" (car ts)))
             (loop (cddr ts) (cons (string-append (car ts) " " (cadr ts)) acc)))
            (else (loop (cdr ts) (cons (car ts) acc)))))))

(define (spotify--release-line? t)
  (or (string-prefix? "Released " t) (string-prefix? "℗" t)))

(defcomponent 'spotify/hero
  "The head of a playlist, album, artist or song page: a large cover on the page's own colour, the kind over a large name, the description, the facts, and the play key. BADGE is the kind, BADGE-CLASS the colour, TAGS what the header says; a tag over 70 characters is the description."
  '((title string required) (icon string optional) (badge string optional) (badge-class string optional) (tags list optional)
    (open? boolean optional) (body blocks optional) (class string optional) (lines list optional) (mark string optional)
    (anchor-name string optional) (anchor-keymap string optional) (anchor-data list optional))
  '(title "Invisible Cinema" badge "Album" badge-class "#383030" tags ("Aaron Parks" "2008" "10 songs" "55 min"))
  (lambda (p)
    (let* ((kind (component--get p 'badge ""))
           (tint (component--get p 'badge-class ""))
           (tags (component--get p 'tags '()))
           (desc (filter (lambda (t) (> (string-length t) 70)) tags))
           (facts (spotify--facts tags kind)))
      (plist-put
        (spotify--card-base p "div" "sp-hero"
          (list (spotify--cover "sp-hero-art" (component--get p 'icon "") (component--get p 'title ""))
                (list 'tag "div" 'class "sp-hero-main"
                      'children (append
                                  (if (equal? kind "") '() (list (spotify--text "sp-hero-kind" kind)))
                                  (list (spotify--text "sp-hero-name" (component--get p 'title "")))
                                  (map (lambda (d) (spotify--text "sp-hero-desc" d)) desc)
                                  (if (null? facts) '() (list (spotify--text "sp-hero-facts" (string-join facts "  •  "))))
                                  (let ((release (filter spotify--release-line? tags)))
                                    (if (null? release) '() (list (spotify--text "sp-hero-release" (string-join release "  ·  ")))))
                                  (list (list 'tag "span" 'class "sp-hero-play"
                                              'children (list (spotify--text "sp-play-dot" "▶") (spotify--text "sp-key" "p") (spotify--text "" "play"))))))))
        'attrs (if (re-match? "^#[0-9A-Fa-f]{6}" tint) (list (list "style" (string-append "--sp-tint:" tint))) '())))))

(defcomponent 'spotify/search-bar
  "The search field over every section: a magnifier, the last query or the prompt to search, and its key. A click, like the key, asks for a search; CLICK is the id it sends."
  '((query string optional) (click string optional) (key string optional) (class string optional))
  '(query "blackwater park" click "spotify:spotify-search" key "/")
  (lambda (p)
    (let ((q (component--get p 'query "")))
      (list 'tag "div" 'class (string-append "sp-search " (component--get p 'class ""))
            'click (component--get p 'click "spotify:spotify-search")
            'children (list (spotify--text "sp-search-icon" "⌕")
                            (spotify--text (if (equal? q "") "sp-search-text sp-search-empty" "sp-search-text")
                                           (if (equal? q "") "What do you want to play?" q))
                            (spotify--text "sp-key" (component--get p 'key "/")))))))

(define (spotify--controls p long?)
  ;; previous, play or pause, next, shuffle, repeat, like: each with its key,
  ;; shuffle and repeat lit when they are on. LONG? spells the words out
  (let* ((playing? (component--get p 'playing? #f))
         (liked? (component--get p 'liked? #f))
         (shuffle (component--get p 'shuffle "off"))
         (repeat (component--get p 'repeat "off"))
         (say (lambda (glyph word) (if long? (string-append glyph "  " word) glyph))))
    (list (list "spotify:spotify-shuffle"
                (say "⇄" (cond ((equal? shuffle "smart") "smart shuffle") ((equal? shuffle "on") "shuffle on") (else "shuffle")))
                "S" (if (equal? shuffle "off") "" "good"))
          (list "spotify:spotify-previous" (say "⏮" "previous") ",")
          (list "spotify:spotify-play-pause" (if playing? (say "⏸" "pause") (say "▶" "play")) "P" "good")
          (list "spotify:spotify-next" (say "⏭" "next") ".")
          (list "spotify:spotify-repeat"
                (cond ((equal? repeat "one") (say "↻¹" "repeat one")) ((equal? repeat "all") (say "↻" "repeat all")) (else (say "↻" "repeat")))
                "R" (if (equal? repeat "off") "" "good"))
          (list "spotify:spotify-like" (if liked? (say "♥" "liked") (say "♡" "like")) "l")
          ;; follow the artist: lit once the editor has seen that you do
          (if (equal? (component--get p 'following "") "yes")
              (list "spotify:spotify-follow" (say "✓" "following") "F" "good")
              (list "spotify:spotify-follow" (say "+" "follow") "F")))))

(defcomponent 'spotify/now-playing
  "The player bar: the cover, where it plays from, the title over its artists and album with a heart when it is liked, the time and a progress bar, and the controls as keys. Each control's CLICK is spotify:COMMAND."
  '((title string optional) (artists string optional) (album string optional) (from string optional) (art string optional) (playing? boolean optional)
    (liked? boolean optional) (following string optional) (position string optional) (duration string optional) (shuffle string optional) (repeat string optional) (class string optional))
  '(title "Windowpane" artists "Opeth" album "Damnation" playing? #t liked? #t position "2:10" duration "7:44")
  (lambda (p)
    (let* ((title (component--get p 'title ""))
           (art (component--get p 'art ""))
           (artists (component--get p 'artists ""))
           (album (component--get p 'album ""))
           (from (component--get p 'from "")))
      (list 'tag "div" 'class (string-append "sp-now " (component--get p 'class ""))
            'attrs (if (equal? art "") '() (list (list "style" (string-append "--sp-art:url('" art "')"))))
            'children
            (if (equal? title "")
                (list (spotify--text "sp-now-idle" "Nothing playing. p on a row plays it."))
                ;; the names own the top row; the time and the controls share the one below,
                ;; so a narrow pane never squeezes the title away
                (list (list 'tag "div" 'class "sp-now-in"
                            'children
                            (list (plist-put (spotify--cover "sp-now-art sp-now-open" art title) 'click "spotify:spotify-now-context")
                                  ;; the cover and the names open the Now Playing page
                                  (list 'tag "div" 'class "sp-now-main sp-now-open" 'click "spotify:spotify-now-context"
                                        'children
                                        (append
                                          (if (equal? from "") '() (list (spotify--text "sp-now-from" from)))
                                          (list (spotify--text (if (component--get p 'liked? #f) "sp-now-title sp-now-liked" "sp-now-title") title)
                                                (spotify--text "sp-now-by"
                                                               (if (equal? album "") artists
                                                                   (if (equal? artists "") album (string-append artists "  ·  " album)))))))
                                  (spotify--progress "sp-now-time" (component--get p 'position "") (component--get p 'duration ""))
                                  (component 'ui/actions
                                    (list 'class "sp-controls"
                                          'actions (spotify--controls p #f)))))))))))

;;; --- release dates ------------------------------------------------------------
;;; Search and list pages do not show when a song came out. The player's embed
;;; page does, as plain HTML a fetch reads without the browser in ~0.4s, so
;;; each row asks once, off the lane, and every list redraws as answers land.

(domain! 'spotify)
(effects! '(read external))

;; What a page around the music read is kept in site-app's caches, by store.
;; The ones that persist go to spotify-cache.json and come back next session
(define (spotify--get store key) (site-app-cache-get 'spotify store key))
(define (spotify--put! store key value) (site-app-cache-put! 'spotify store key value))
(define (spotify--links href)
  ;; (HREF ALBUM-HREF ARTIST-HREF) of a track, once its page named them
  (let ((v (spotify--get 'links href))) (and (pair? v) v)))

(for-each (lambda (s) (site-app-cache-store! 'spotify (car s) (cdr s)))
  (list (list 'dates 'persist #t 'keep? (lambda (e) (string? (cadr e))))   ; (HREF "12 Aug 2016"): #f while asked, "" when unknown
        (list 'searches 'persist #t 'max 50)   ; (QUERY ROWS)
        (list 'artists 'persist #t)            ; (HREF what the artist page says)
        (list 'albums 'persist #t)             ; (HREF what the album page says)
        (list 'news 'persist #t)               ; (ARTIST stories)
        (list 'briefs 'persist #t) (list 'listen 'persist #t) (list 'liners 'persist #t)
        (list 'links 'persist #t)              ; (HREF (HREF ALBUM-HREF ARTIST-HREF))
        (list 'covers 'persist #t)             ; (HREF COVER)
        (list 'photos)                         ; (NAME URLS)
        (list 'following)))                    ; (ARTIST-HREF #t|#f)

(define *spotify-months* '("Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"))

(define (spotify--day iso)
  ;; "2016-08-12..." as "12 Aug 2016"
  (let ((parts (string-split (if (>= (string-length iso) 10) (substring iso 0 10) iso) "-")))
    (if (and (= (length parts) 3) (string->number (cadr parts)) (string->number (caddr parts)))
        (string-append (number->string (string->number (caddr parts))) " "
                       (nth (- (string->number (cadr parts)) 1) *spotify-months*) " " (car parts))
        "")))

(define (spotify--release-iso html)
  (let ((parts (string-split html "\"releaseDate\":{\"isoString\":\"")))
    (if (pair? (cdr parts)) (substring (cadr parts) 0 (min 10 (string-length (cadr parts)))) "")))

(define (spotify--redraw-lists! ignored)
  (for-each (lambda (b) (buffer-set-local! b 'list-layout-cache #f) (list-refresh! b)) (spotify--list-buffers)))

(define (spotify--date-of href)
  ;; the date if known, else #f; the first ask starts the read
  (let ((hit (spotify--get 'dates href)))
    (cond ((site-app-cache-has? 'spotify 'dates href) hit)
          ((not (and (string? href) (re-match? "^/(track|album)/[A-Za-z0-9]+$" href))) #f)
          (else
           (spotify--put! 'dates href #f)
           (task-run!
             (lambda ()
               ;; an album's embed leaves its date out once it is out; its
               ;; first track's carries it
               (let* ((html (http-text (string-append "https://open.spotify.com/embed" href)))
                      (iso (if (string? html) (spotify--release-iso html) ""))
                      (first (and (equal? iso "") (string? html)
                                  (let ((parts (string-split html "\"uri\":\"spotify:track:")))
                                    (and (pair? (cdr parts)) (car (string-split (cadr parts) "\"")))))))
                 (if first
                     (let ((track (http-text (string-append "https://open.spotify.com/embed/track/" first))))
                       (if (string? track) (spotify--release-iso track) ""))
                     iso)))
             (lambda (ok iso)
               (spotify--put! 'dates href (if (and ok (string? iso)) (spotify--day iso) ""))
               ;; many land at once: one redraw for the lot
               (debounce! 'spotify-dates 250 spotify--redraw-lists! #f))
             15000)
           #f))))

;;; --- the Now Playing page -----------------------------------------------------
;;; What plays, large, and around it the artist: the album it is from and when
;;; it came out, the artist's popular tracks, where they play next, who they
;;; are, what they made, and what is being said about them. The player gives
;;; the track; the album and artist pages are read in the reader tab, and the
;;; news is a web search. Each is read once per album or artist.

(domain! 'ui)
(effects! '(pure))

(define (spotify--hires src)
  ;; a cover in the bar is 64px; the same image comes at 640
  (if (string? src) (re-replace-all "00004851|00001e02" src "0000b273") ""))

(define (spotify--progress class pos dur)
  (let* ((total (spotify--seconds dur))
         (pct (if (> total 0) (min 100 (quotient (* 100 (spotify--seconds pos)) total)) 0)))
    (list 'tag "div" 'class class
          'children (list (spotify--text "sp-dur" pos)
                          (list 'tag "span" 'class "sp-bar"
                                'children (list (list 'tag "span" 'class "sp-bar-fill"
                                                      'attrs (list (list "style" (string-append "width:" (number->string pct) "%"))))))
                          (spotify--text "sp-dur" dur)))))



(defcomponent 'spotify/np-hero
  "The head of the Now Playing page: the cover large on a blur of itself, whether it plays, the title, the artists, the album and its release, a progress bar and the controls. A click on the album is CLICK."
  '((title string required) (artists string optional) (art string optional) (album string optional)
    (released string optional) (click string optional) (playing? boolean optional) (liked? boolean optional) (following string optional)
    (position string optional) (duration string optional) (shuffle string optional) (repeat string optional))
  '(title "Windowpane" artists "Opeth" album "Damnation" released "April 22, 2003" playing? #t position "2:10" duration "7:44")
  (lambda (p)
    (let* ((art (component--get p 'art ""))
           (pos (component--get p 'position ""))
           (dur (component--get p 'duration ""))
           (playing? (component--get p 'playing? #f))
           (liked? (component--get p 'liked? #f))
           (album (component--get p 'album ""))
           (released (component--get p 'released "")))
      (list 'tag "div" 'class "sp-np-hero"
            'attrs (if (equal? art "") '() (list (list "style" (string-append "--sp-art:url('" art "')"))))
            'children
            (list (spotify--cover "sp-np-art" art (component--get p 'title ""))
                  (list 'tag "div" 'class "sp-np-main"
                        'children
                        (append
                          (list (spotify--text "sp-np-state" (if playing? "Now playing" "Paused"))
                                (spotify--text "sp-np-title" (component--get p 'title ""))
                                (spotify--text "sp-np-artists" (component--get p 'artists "")))
                          (if (equal? album "") '()
                              (list (list 'tag "span" 'class "sp-np-album"
                                          'click (component--get p 'click "")
                                          'children (append (list (spotify--text "sp-np-album-name" album))
                                                            (if (equal? released "") '()
                                                                (list (spotify--text "sp-np-released" released)))))))
                          (list (cell-part 'spotify/progress (spotify--progress "sp-np-progress" pos dur))
                                (component 'ui/actions
                                  (list 'class "sp-np-controls"
                                        'actions (spotify--controls p #t)))))))))))

(define spotify--montage-seconds 7)

(define (spotify--montage images &optional seconds)
  ;; the banner's layers, one a photo: each fades in on its turn of the
  ;; cycle as the one before fades out. One photo is the banner alone.
  ;; SECONDS is each photo's turn
  (let ((n (min 8 (length images)))
        (s (or seconds spotify--montage-seconds)))
    (if (< n 2) '()
        (let loop ((is (list-head images n)) (i 0) (acc '()))
          (if (null? is) (reverse acc)
              (loop (cdr is) (+ i 1)
                    (cons (list 'tag "div" 'class "sp-montage"
                                'attrs (list (list "style" (string-append "background-image:url('" (car is) "');"
                                                                            "animation:sp-fade-" (number->string n) " "
                                                                            (number->string (* n s)) "s linear infinite;"
                                                                            "animation-delay:" (number->string (* i s)) "s"))))
                          acc)))))))

(define (spotify--montage-css)
  ;; a cycle for each count of photos: a photo's turn is its share of the
  ;; cycle, and its fade in takes the first third of the turn, while the one
  ;; before fades out
  (let ((pct (lambda (tenths) (string-append (number->string (quotient tenths 10)) "." (number->string (remainder tenths 10)) "%"))))
    (apply string-append
      (map (lambda (n)
             (let* ((turn (quotient 1000 n)) (fade (quotient turn 3)))
               (string-append "@keyframes sp-fade-" (number->string n) " { "
                              "0% { opacity: 0; transform: scale(1); } "
                              (pct fade) " { opacity: 1; } "
                              (pct turn) " { opacity: 1; } "
                              (pct (+ turn fade)) " { opacity: 0; transform: scale(1.08); } "
                              "100% { opacity: 0; transform: scale(1.08); } }\n")))
           (list 2 3 4 5 6 7 8)))))

(define-style! 'spotify-montage (spotify--montage-css))

(defcomponent 'spotify/artist-card
  "Who the artist is: their photo as a banner with the name, the verified mark and the monthly listeners over it, then the bio in paragraphs. IMAGES, when it holds more than one photo, makes the banner a montage: each photo drifts in and dissolves into the next."
  '((name string required) (image string optional) (images list optional) (listeners string optional) (verified? boolean optional) (bio string optional))
  '(name "Opeth" listeners "1,022,069 monthly listeners" verified? #t bio "Swedish progressive titans.")
  (lambda (p)
    (let ((image (component--get p 'image ""))
          (paras (filter (lambda (s) (not (equal? (string-trim s) "")))
                         (string-split (component--get p 'bio "") "\n"))))
      (list 'tag "div" 'class (if (null? paras) "sp-artist" "sp-artist sp-artist-split")
            'children
            (cons (list 'tag "div" 'class "sp-artist-banner"
                        'attrs (if (equal? image "") '() (list (list "style" (string-append "background-image:url('" image "')"))))
                        'children (append (spotify--montage (component--get p 'images '()))
                                          (if (component--get p 'verified? #f) (list (spotify--text "sp-verified" "✔ Verified artist")) '())
                                          (list (spotify--text "sp-artist-name" (component--get p 'name ""))
                                                (spotify--text "sp-artist-listeners" (component--get p 'listeners "")))))
                  (if (null? paras) '()
                      (list (list 'tag "div" 'class "sp-bio-box"
                                  'children (map (lambda (s) (list 'tag "p" 'class "sp-bio" 'text (string-trim s))) paras)))))))))


(defcomponent 'spotify/gig
  "One concert: the date as a calendar leaf, the city, the venue and the time. CLICK opens it."
  '((month string optional) (day string optional) (city string required) (venue string optional) (when string optional) (click string optional))
  '(month "Nov" day "1" city "Santiago" venue "Movistar Arena" when "Sun 7:00 PM")
  (lambda (p)
    (list 'tag "div" 'class "sp-gig" 'click (component--get p 'click "")
          'children (list (list 'tag "div" 'class "sp-main"
                                'children (list (spotify--text "sp-name" (component--get p 'city ""))
                                                (spotify--text "sp-by" (component--get p 'venue ""))))))))

(defcomponent 'spotify/person
  "One person on the record: their photo, else their initials, their name and what they did. CREW? draws the card small, for who made the record rather than played on it. CLICK opens their page."
  '((name string required) (roles string optional) (image string optional) (crew? boolean optional) (click string optional))
  '(name "Eric Harland" roles "drums" image "")
  (lambda (p)
    (let ((name (component--get p 'name "")) (image (component--get p 'image "")))
      (list 'tag "div" 'class (if (component--get p 'crew? #f) "sp-person sp-person-crew" "sp-person")
            'click (component--get p 'click "")
            'children (list (if (equal? image "")
                                (spotify--text "sp-person-face" (spotify--initials name))
                                (spotify--img "sp-person-face" image))
                            (list 'tag "div" 'class "sp-person-text"
                                  'children (list (spotify--text "sp-person-name" name)
                                                  (spotify--text "sp-person-roles" (component--get p 'roles "")))))))))

(defcomponent 'spotify/news-item
  "One story about the artist: its headline, where it ran and when, and the first lines. CLICK opens it."
  '((title string required) (source string optional) (date string optional) (snippet string optional) (click string optional))
  '(title "Opeth announce Deliverance reissue" source "opeth.com" date "7 days ago" snippet "Limited Edition Ash Grey 2LP.")
  (lambda (p)
    (list 'tag "div" 'class "sp-news" 'click (component--get p 'click "")
          'children (list (list 'tag "span" 'class "sp-news-meta"
                                'children (list (spotify--text "sp-news-source" (component--get p 'source ""))
                                                (spotify--text "sp-news-date" (component--get p 'date ""))))
                          (spotify--text "sp-news-title" (component--get p 'title ""))
                          (spotify--text "sp-news-snippet" (component--get p 'snippet ""))))))

(define-style! 'spotify "
.sp-track, .sp-tile { display: flex; align-items: center; gap: 12px; padding: 5px 8px; border-radius: 6px; font-family: var(--font-sans); font-size: 13px; min-width: 0; }
.semantic-list > .semantic-item.sp-track { display: flex; align-items: center; gap: 12px; padding: 6px 10px; border-left: 0; border-radius: 6px; }
.sp-track:hover, .sp-tile:hover { background: var(--hl-line-bg); } .current > .sp-track, .current > .sp-tile, .sp-track.current, .sp-tile.current { background: color-mix(in srgb, var(--ok-fg) 22%, var(--hl-line-bg)); box-shadow: inset 3px 0 0 var(--ok-fg); }
.sp-idx { flex: none; width: 2ch; text-align: right; color: var(--dim-fg); font-variant-numeric: tabular-nums; }
.sp-playing .sp-idx, .sp-playing .sp-name { color: var(--ok-fg); }
.sp-art { flex: none; width: 36px; height: 36px; border-radius: 4px; object-fit: cover; background: var(--hl-line-bg); }
.sp-cover { flex: none; width: 48px; height: 48px; border-radius: 6px; object-fit: cover; background: var(--hl-line-bg); }
.sp-kind-artist .sp-cover { border-radius: 50%; }
.sp-blank { display: inline-grid; place-items: center; font-weight: 700; color: var(--dim-fg); }
.sp-main { display: flex; flex-direction: column; gap: 2px; min-width: 0; flex: 1; }
.sp-name { font-weight: 600; color: var(--default-fg); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.sp-by { color: var(--dim-fg); font-size: .9em; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; display: flex; gap: 8px; align-items: baseline; }
.sp-album { flex: 0 1 30%; min-width: 0; color: var(--dim-fg); font-size: .9em; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.sp-date { flex: none; width: 11ch; text-align: right; color: var(--dim-fg); font-size: .85em; font-variant-numeric: tabular-nums; white-space: nowrap; }
.sp-dur { flex: none; color: var(--dim-fg); font-size: .85em; font-variant-numeric: tabular-nums; }
.sp-chip { flex: none; font-size: .78em; text-transform: uppercase; letter-spacing: .06em; color: var(--accent-fg); }
.sp-sub { overflow: hidden; text-overflow: ellipsis; }
/* tiles are cards: a grid of covers wherever they gather, a list section or a shelf on a page */
:is(.semantic-list, c-group):has(> .sp-tile) { display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 6px; align-items: start; }
:is(.semantic-list, c-group):has(> .sp-tile) > :not(.sp-tile) { grid-column: 1 / -1; }
.semantic-list > .semantic-item.sp-tile, .sp-tile { display: flex; flex-direction: column; align-items: stretch; gap: 8px; padding: 10px 10px 14px; border-radius: 8px; border-left: 0; }
.sp-tile .sp-cover { width: 100%; height: auto; aspect-ratio: 1; border-radius: 6px; box-shadow: 0 6px 18px rgba(0,0,0,.35); font-size: 40px; }
.sp-tile .sp-main { gap: 4px; }
.sp-tile .sp-by { display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; white-space: normal; line-height: 1.35; }
.sp-tile .sp-chip { margin-right: 6px; }

.sp-hero { display: flex; align-items: flex-end; gap: 22px; padding: 22px; margin: 0 0 14px; border-radius: 10px; font-family: var(--font-sans);
  background: linear-gradient(180deg, var(--sp-tint, var(--hl-line-bg)) 0%, transparent 100%); }
.sp-hero-art { flex: none; width: 168px; height: 168px; border-radius: 8px; object-fit: cover; box-shadow: 0 8px 28px rgba(0,0,0,.45); background: var(--hl-line-bg); font-size: 64px; }
.sp-hero-main { display: flex; flex-direction: column; gap: 8px; min-width: 0; }
.sp-hero-kind { font-size: .8em; font-weight: 600; text-transform: uppercase; letter-spacing: .08em; color: var(--default-fg); opacity: .8; }
.sp-hero-name { font-size: 2.6em; font-weight: 800; line-height: 1.05; letter-spacing: -.02em; color: var(--default-fg); overflow-wrap: anywhere; }
.sp-hero-desc { color: var(--dim-fg); font-size: .95em; }
.sp-hero-release { color: var(--dim-fg); font-size: .82em; }
.sp-year { flex: none; font-size: .78em; font-weight: 600; padding: 0 6px; border-radius: 999px; border: 1px solid var(--border-bg); color: var(--default-fg); font-variant-numeric: tabular-nums; }
.sp-hero-facts { color: var(--default-fg); font-size: .9em; opacity: .85; }
.sp-hero-play { display: inline-flex; align-items: center; gap: 8px; margin-top: 6px; color: var(--dim-fg); font-size: .85em; }
.sp-play-dot { display: inline-grid; place-items: center; width: 34px; height: 34px; border-radius: 50%; background: var(--ok-fg); color: var(--default-bg); font-size: 14px; }
.sp-key { font-family: var(--font-mono); border: 1px solid var(--border-bg); border-radius: 4px; padding: 0 5px; }
.sp-search { display: flex; align-items: center; gap: 10px; padding: 9px 14px; margin: 0 0 8px; border-radius: 999px; background: var(--hl-line-bg); border: 1px solid transparent; font-family: var(--font-sans); font-size: 14px; cursor: text; }
.sp-search:hover { border-color: var(--border-bg); }
.sp-search-icon { flex: none; font-size: 17px; color: var(--dim-fg); }
.sp-search-text { flex: 1; min-width: 0; color: var(--default-fg); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.sp-search-empty { color: var(--dim-fg); }
/* the player bar: the names own the top row, the time and the controls the row below; in a narrow pane each takes a row of its own */
.sp-now { container-type: inline-size; position: relative; overflow: hidden; isolation: isolate; margin: 0 0 10px; border: 1px solid var(--border-bg); border-radius: 12px; background: var(--hl-line-bg); font-family: var(--font-sans); font-size: 13px; }
.sp-now::before { content: ''; position: absolute; inset: -40px; z-index: -1; background: var(--sp-art, none) center / cover; filter: blur(40px) saturate(1.4); opacity: .3; }
.sp-now > .sp-now-idle { display: block; padding: 12px 14px; }
.sp-now-in { display: grid; grid-template-columns: 72px minmax(0, 1fr) auto; grid-template-areas: 'art main main' 'art time ctrl'; column-gap: 16px; row-gap: 8px; align-items: center; padding: 12px 14px; }
.sp-now-art { grid-area: art; width: 72px; height: 72px; border-radius: 8px; object-fit: cover; background: var(--hl-line-bg); box-shadow: 0 6px 18px rgba(0,0,0,.35); font-size: 28px; }
.sp-now-main { grid-area: main; display: flex; flex-direction: column; gap: 3px; min-width: 0; }
.sp-now-from { color: var(--dim-fg); font-size: .72em; font-weight: 600; text-transform: uppercase; letter-spacing: .1em; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.sp-now-title { font-size: 1.3em; font-weight: 700; line-height: 1.2; color: var(--default-fg); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.sp-now-liked::after { content: '  ♥'; color: var(--ok-fg); }
.sp-now-by { color: var(--dim-fg); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
@container (max-width: 520px) {
  .sp-now-in { grid-template-columns: 56px minmax(0, 1fr); grid-template-areas: 'art main' 'time time' 'ctrl ctrl'; }
  .sp-now-art { width: 56px; height: 56px; }
  .sp-now-in > .sp-controls { justify-self: center; }
}
.sp-now-idle { color: var(--dim-fg); }
.sp-liked { color: var(--ok-fg); }
.sp-now-time { grid-area: time; display: flex; align-items: center; gap: 8px; min-width: 0; }
.sp-bar { flex: 1; height: 4px; border-radius: 2px; background: var(--border-bg); overflow: hidden; }
.sp-bar-fill { display: block; height: 100%; background: var(--ok-fg); }
.sp-controls { grid-area: ctrl; justify-self: end; }

.sp-np-hero { position: relative; overflow: hidden; display: flex; align-items: flex-end; gap: 28px; padding: 32px; margin: 0 0 22px; border-radius: 14px; font-family: var(--font-sans); isolation: isolate; background: var(--hl-line-bg); }
.sp-np-hero::before { content: ''; position: absolute; inset: -60px; z-index: -1; background: var(--sp-art) center / cover; filter: blur(48px) saturate(1.5) brightness(.75); opacity: .9; }
.sp-np-hero::after { content: ''; position: absolute; inset: 0; z-index: -1; background: linear-gradient(180deg, transparent 30%, rgba(0,0,0,.45)); }
.sp-np-art { flex: none; width: 240px; height: 240px; border-radius: 10px; object-fit: cover; box-shadow: 0 18px 50px rgba(0,0,0,.55); font-size: 90px; }
.sp-np-main { display: flex; flex-direction: column; gap: 8px; min-width: 0; flex: 1; color: #fff; }
.sp-np-state { font-size: .75em; font-weight: 700; letter-spacing: .14em; text-transform: uppercase; opacity: .85; }
.sp-np-title { font-size: 3em; font-weight: 800; line-height: 1.02; letter-spacing: -.025em; overflow-wrap: anywhere; }
.sp-np-artists { font-size: 1.15em; font-weight: 600; opacity: .95; }
.sp-np-album { display: flex; flex-wrap: wrap; gap: 10px; align-items: baseline; font-size: .92em; opacity: .85; cursor: pointer; }
.sp-np-album:hover .sp-np-album-name { text-decoration: underline; }
.sp-np-released { font-size: .9em; opacity: .8; }
.sp-np-progress { display: flex; align-items: center; gap: 10px; margin-top: 10px; max-width: 520px; }
.sp-np-progress .sp-dur { color: rgba(255,255,255,.8); }
.sp-np-progress .sp-bar { height: 5px; background: rgba(255,255,255,.25); }
.sp-np-progress .sp-bar-fill { background: #fff; }
.sp-np-controls { margin-top: 6px; }
.sp-np-section { margin: 26px 0 10px; font-family: var(--font-sans); font-size: 1.35em; font-weight: 800; letter-spacing: -.01em; color: var(--default-fg); }
.sp-artist { border-radius: 12px; overflow: hidden; background: var(--hl-line-bg); font-family: var(--font-sans); }
.sp-artist-banner { min-height: 220px; display: flex; flex-direction: column; justify-content: flex-end; gap: 4px; padding: 22px; color: #fff; background: linear-gradient(180deg, var(--hl-line-bg), var(--hl-line-bg)) center / cover; background-size: cover; background-position: center 25%; box-shadow: inset 0 -120px 80px -40px rgba(0,0,0,.65); }
.sp-verified { font-size: .78em; font-weight: 600; color: #8ab4ff; }
.sp-artist-name { font-size: 2.2em; font-weight: 800; letter-spacing: -.02em; line-height: 1.05; }
.sp-artist-listeners { font-size: .9em; opacity: .9; }
.sp-bio { margin: 0; padding: 12px 22px 0; line-height: 1.6; color: var(--default-fg); max-width: 72ch; }
.sp-bio:last-child { padding-bottom: 20px; }
.sp-gig { display: flex; align-items: center; gap: 14px; padding: 8px 10px; border-radius: 8px; font-family: var(--font-sans); cursor: pointer; }
.sp-gig:hover, .sp-news:hover { background: var(--hl-line-bg); }
.sp-gig-date { flex: none; width: 52px; display: flex; flex-direction: column; align-items: center; border-radius: 8px; overflow: hidden; border: 1px solid var(--border-bg); }
.sp-gig-month { width: 100%; text-align: center; font-size: .7em; font-weight: 700; text-transform: uppercase; letter-spacing: .08em; background: var(--ok-fg); color: var(--default-bg); padding: 1px 0; }
.sp-gig-day { font-size: 1.35em; font-weight: 800; padding: 2px 0 4px; color: var(--default-fg); }
.sp-news { display: flex; flex-direction: column; gap: 3px; padding: 10px 12px; border-radius: 8px; font-family: var(--font-sans); cursor: pointer; }
.sp-news-meta { display: flex; gap: 10px; font-size: .78em; color: var(--dim-fg); text-transform: uppercase; letter-spacing: .05em; }
.sp-news-source { font-weight: 700; color: var(--accent-fg); }
.sp-news-title { font-weight: 700; color: var(--default-fg); line-height: 1.35; }
.sp-news-snippet { color: var(--dim-fg); font-size: .9em; line-height: 1.5; }
.sp-np-empty { color: var(--dim-fg); font-family: var(--font-sans); padding: 6px 10px; }
.sp-now-open { cursor: pointer; }
.sp-artist-banner { position: relative; overflow: hidden; }
/* the photo beside the bio */
.sp-artist-split { display: grid; grid-template-columns: minmax(240px, 45%) minmax(0, 1fr); align-items: stretch; }
.sp-artist-split > .sp-artist-banner { min-height: 300px; }
.sp-bio-box { max-height: 300px; overflow-y: auto; padding-bottom: 14px; }
.sp-bio-box > .sp-bio { padding: 12px 22px 0; }
.sp-bio-box > .sp-bio:first-child { padding-top: 20px; }
/* an artist's page: the tour runs down a sidebar beside the news */
.c-page:has(> .sp-part-on-tour) { display: grid; grid-template-columns: minmax(0, 1fr) minmax(220px, 30%); grid-auto-flow: row dense; column-gap: 18px; align-items: start; }
.c-page:has(> .sp-part-on-tour) > * { grid-column: 1 / -1; }
.c-page:has(> .sp-part-on-tour) > .sp-part-news { grid-column: 1; }
.c-page:has(> .sp-part-on-tour) > .sp-part-on-tour { grid-column: 2; position: sticky; top: 0; }
.sp-part-on-tour .sp-gig { padding: 6px 4px; gap: 10px; }
.sp-artist-banner > :not(.sp-montage) { position: relative; z-index: 1; }
.sp-montage { position: absolute; inset: 0; z-index: 0; opacity: 0; background-size: cover; background-position: center 25%; will-change: opacity, transform; }
.sp-montage::after { content: ''; position: absolute; inset: 0; background: linear-gradient(180deg, rgba(0,0,0,0) 40%, rgba(0,0,0,.65)); }
.sp-part:has(> .sp-person) { display: grid; grid-template-columns: repeat(auto-fill, minmax(140px, 1fr)); gap: 14px; align-items: start; }
.sp-part:has(> .sp-person) > :not(.sp-person) { grid-column: 1 / -1; }
.sp-part:has(> .sp-person-crew) { grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 4px 14px; }
.sp-person { display: flex; flex-direction: column; gap: 8px; padding: 8px; border-radius: 10px; font-family: var(--font-sans); cursor: pointer; min-width: 0; }
.sp-person:hover { background: var(--hl-line-bg); }
.sp-person-face { width: 100%; aspect-ratio: 1; object-fit: cover; object-position: center 25%; border-radius: 50%; display: flex; align-items: center; justify-content: center; background: var(--hl-line-bg); color: var(--dim-fg); font-size: 2em; font-weight: 700; box-shadow: 0 6px 18px rgba(0,0,0,.25); }
.sp-person-text { display: flex; flex-direction: column; gap: 2px; text-align: center; min-width: 0; }
.sp-person-name { font-weight: 700; color: var(--default-fg); }
.sp-person-roles { font-size: .85em; color: var(--dim-fg); line-height: 1.4; }
.sp-person-crew { flex-direction: row; align-items: center; gap: 10px; padding: 4px 8px; }
.sp-person-crew .sp-person-face { width: 36px; height: 36px; flex: none; font-size: .85em; box-shadow: none; }
.sp-person-crew .sp-person-text { text-align: left; }
/* the ambient page, to glance at: the photos fill the stage, the cover sits large beside one fact at a time */
.sp-ambient { container-type: inline-size; position: relative; overflow: hidden; isolation: isolate; min-height: 82vh; display: flex; align-items: flex-end; border-radius: 14px; font-family: var(--font-sans); color: white; background: black; }
.sp-ambient::before { content: ''; position: absolute; inset: -80px; z-index: -2; background: var(--sp-art, none) center / cover; filter: blur(60px) saturate(1.3) brightness(.6); }
.sp-ambient > .sp-montage { z-index: -1; background-position: center 30%; filter: brightness(.9); }
.sp-ambient > .sp-montage::after { display: none; }
.sp-ambient-veil { position: absolute; inset: 0; z-index: 0; pointer-events: none; background: linear-gradient(180deg, rgba(0,0,0,0) 35%, rgba(0,0,0,.55) 65%, rgba(0,0,0,.85)); }
.sp-ambient-main { position: relative; z-index: 1; display: flex; flex-direction: column; align-items: center; gap: 32px; width: 100%; padding: 40px; text-align: center; }
.sp-ambient-side { width: 100%; max-width: 760px; min-width: 0; display: flex; flex-direction: column; align-items: center; gap: 6px; }
.sp-ambient-title { font-size: 2.3em; font-weight: 800; line-height: 1.05; letter-spacing: -.02em; overflow-wrap: anywhere; }
.sp-ambient-artists { font-size: 1.1em; font-weight: 600; opacity: .8; }
.sp-fact-label { font-size: .78em; font-weight: 700; letter-spacing: .16em; text-transform: uppercase; color: rgba(255,255,255,.65); }
.sp-ambient .sp-np-progress { width: 100%; max-width: 420px; margin-top: 22px; opacity: .6; }
.sp-ambient .sp-np-progress .sp-bar { height: 3px; }
")

;;; --- the player ---------------------------------------------------------------
;;; Your own Spotify tab. The reader tab site-app keeps is hidden from the tab
;;; list, so the first open.spotify.com tab there is the one you listen in.

(domain! 'spotify)
(effects! '(write external))

(define (spotify--tab? t)
  ;; one tab plays and reads: the app's own, remembered across sessions. A
  ;; second web player would take the sound from it
  (equal? (chrome--tab-id t) (site-app-tab 'spotify)))

;; Every control starts here. With no player tab open we open one and say so,
;; because a command that silently does nothing reads like a broken editor.
(define (spotify-tab k)
  ;; the app's one tab, wherever it is; gone, a fresh one opens out of sight
  ;; and is remembered
  (site-app-find-tab! 'spotify k))

;; The page's own world: Spotify's CSP refuses a string evaluated in the
;; isolated one, and both worlds see the same DOM.
(define (spotify--eval code k) (spotify-tab (lambda (t) (tab-eval-main t code k))))

;; selectors name testids bare, so the JS carries no quotes of its own
(define (spotify--click-sel-js sel what)
  (string-append
    "(function(){var b=document.querySelector(" (json-encode sel) ");"
    "if(!b)return 'no player controls — is the tab loaded?';"
    "b.click();return '" what "';})()"))

(define (spotify--click-js testid what)
  (spotify--click-sel-js (string-append "[data-testid=" testid "]") what))

(define spotify--like-sel
  "[data-testid=now-playing-widget] [data-testid=add-button],[data-testid=now-playing-bar] [data-testid=add-button]")

;; What the bar shows, as one JSON string: the track, its artists and cover,
;; whether it plays, where it is, and whether it is liked.
(define spotify--now-json-js
  (string-append
    "(function(){var w=document.querySelector('[data-testid=now-playing-widget]');"
    "var t=function(s){var e=document.querySelector(s);return e?(e.innerText||e.textContent||'').trim():''};"
    "var as=Array.from(document.querySelectorAll('[data-testid=context-item-info-artist]')).map(function(e){return (e.innerText||'').trim()});"
    "var img=w&&w.querySelector('img');"
    "var pp=document.querySelector('[data-testid=control-button-playpause]');"
    "var add=w&&w.querySelector('[data-testid=add-button]');"
    "var al=document.querySelector('[data-testid=context-item-link]');var ar=document.querySelector('[data-testid=context-item-info-artist]');"
    "var href=function(a){return a?(a.getAttribute('href')||'').split('?')[0]:''};"
    "var sh=Array.from(document.querySelectorAll('[data-testid=player-controls] button')).filter(function(e){return /shuffle/i.test(e.getAttribute('aria-label')||'')})[0];"
    "var shs=!sh||sh.getAttribute('aria-disabled')==='true'?'off':(function(l){return /^enable/i.test(l)?'off':/smart/i.test(l)?'smart':(/^disable/i.test(l)||!/subdued/.test(sh.className))?'on':'off'})(sh.getAttribute('aria-label')||'');"
    "var rp=document.querySelector('[data-testid=control-button-repeat]');var rc=rp?rp.getAttribute('aria-checked'):'false';"
    "return JSON.stringify({title:t('[data-testid=context-item-link]'),artists:as.filter(function(a,i){return as.indexOf(a)===i}).join(', '),"
    "art:img?img.src:'',playing:/pause/i.test(pp&&pp.getAttribute('aria-label')||''),"
    "position:t('[data-testid=playback-position]'),duration:t('[data-testid=playback-duration]'),"
    "albumHref:href(al),artistHref:href(ar),"
    "shuffle:shs,"
    "repeat:rc==='true'?'all':(rc==='mixed'?'one':'off'),"
    "liked:!!(add&&add.getAttribute('aria-checked')==='true')});})()"))

(define (spotify--volume-js delta)
  (string-append
    "(function(){var m=document.querySelector('video,audio');"
    "if(!m)return 'no sound yet';"
    "m.volume=Math.min(1,Math.max(0,m.volume+(" delta ")));"
    "return 'volume '+Math.round(m.volume*100)+'%';})()"))

(define *spotify-now* '())

(define (spotify--list-buffers)
  (filter buffer-exists?
          (map (lambda (page) (site-app-page-buffer 'spotify (plist-get page 'id)))
               (site-app-pages (site-app-spec 'spotify)))))

(define (spotify--now-set! now)
  ;; every section's bar redraws. Music that starts brings Now Playing up
  (let ((started (and (eq? (plist-get now 'playing) #t) (not (eq? (plist-get *spotify-now* 'playing) #t))))
        (changed (not (equal? (plist-get now 'trackHref) (plist-get *spotify-now* 'trackHref)))))
    (set! *spotify-now* now)
    (for-each (lambda (b) (buffer-set-local! b 'list-layout-cache #f) (list-refresh! b)) (spotify--list-buffers))
    (cell-set! 'spotify/track (spotify--track-of now))
    (cell-set! 'spotify/position (spotify--position-of now))
    (when changed (spotify-stage-purge!))
    (when started (spotify--now-up!))
    (when (and changed (not started)) (spotify--follow-track!))))

(define (spotify--section-pane)
  ;; the window showing a section, if one does
  (with-frame-windows
    (lambda ()
      (find (lambda (w) (member (window-buffer w) (spotify--list-buffers)))
            (map car (window-list))))))

;; The app is two panes: a section, and the page beside it. Whatever opens
;; from either takes the page pane; nothing opens a third
(define (spotify--section-list)
  ;; the section on screen, else Home
  (let ((pane (spotify--section-pane)))
    (or (and pane (with-frame-windows (lambda () (window-buffer pane))))
        (spotify--section-ready! 'home))))

(define (spotify--page-pane from)
  ;; the window showing FROM when it is one of the app's pages, else the one
  ;; showing any of them
  (with-frame-windows
    (lambda ()
      (let ((ws (map car (window-list))))
        (or (find (lambda (w) (equal? (window-buffer w) from)) (if (spotify--detail? from) ws '()))
            (find (lambda (w) (spotify--detail? (window-buffer w))) ws))))))

(define (spotify--now-up!)
  ;; music that starts turns the section on screen to Now Playing; the focus
  ;; stays where it is, and nothing changes while no section shows
  (when (spotify--section-pane) (spotify--playing-section! #f)))

(define (spotify--now-context!)
  ;; what plays now, as the playlist or album it plays from, in the detail
  ;; beside the section. The list it was played from, while the track is in
  ;; it; else an open page that lists the track; else the track alone
  (let* ((title (spotify--now-field 'title))
         (lists? (lambda (b) (and (buffer-exists? b) (spotify--detail? b) (not (equal? title ""))
                                  (string-index (buffer-text b) title) #t)))
         (o (and *spotify-origin*
                 (or (not (buffer-exists? (cadr *spotify-origin*))) (lists? (cadr *spotify-origin*)))
                 *spotify-origin*))
         (shown (get-visible-buffers))
         (list-buf (or (find (lambda (b) (member b shown)) (spotify--list-buffers))
                       (spotify--section-ready! 'home)))
         (kept (if o
                   (and (buffer-exists? (cadr o)) (cadr o))
                   (find lists? (buffer-list))))
         (path (if o (car o) (spotify--now-field 'trackHref))))
    (cond (kept (unless (member kept shown)
                  (with-frame-windows (lambda () (display-buffer-detail! kept list-buf))))
                kept)
          ((not (equal? path ""))
           (with-frame-windows
             (lambda ()
               (site-app-show-detail! list-buf
                 (list 'key path 'href path 'kind ""
                       'name (if o (if (pair? (cddr o)) (caddr o) (spotify--origin-name (cadr o))) (spotify--now-field 'title)))))))
          (else (message "Nothing is playing") #f))))

;; Whether a page would draw as it last did. What an artist tab shows comes from the
;; artist's read, brief, news and photos; an album tab from the notes; so a
;; redraw that none of them prompted leaves the page alone
(define (spotify--playing-row b)
  ;; the ambient page is of what plays, not of the row under point: the
  ;; Now Playing row that plays, else the row drawn
  (let* ((href (spotify--now-field 'trackHref))
         (list-buf (site-app-page-buffer 'spotify 'playing))
         (rows (if (buffer-exists? list-buf) (site-app-rows list-buf) '())))
    (or (and (string? href) (not (equal? href ""))
             (find (lambda (r) (equal? (site-app-field r 'href) href)) rows))
        (buffer-local b 'site-app-row))))

(define (spotify--tab-inputs b &optional given)
  ;; GIVEN the row about to be drawn; else the one drawn
  (let* ((active (buffer-local b 'site-app-active))
         (row (spotify--as-track b (if (equal? active "ambient") (spotify--playing-row b) (or given (buffer-local b 'site-app-row)))))
         (href (or (site-app-field row 'href) "")))
    (cond
      ((equal? active "ambient")
       (let* ((artist-href (spotify--artist-href row (spotify--links href)))
              (artist (spotify--get 'artists artist-href))
              (name (let ((n (and artist (plist-get artist 'name))))
                      (if (and (string? n) (not (equal? n ""))) n (spotify--row-artist row)))))
         (let* ((now (spotify--row-now row))
                (album (or (plist-get now 'album) ""))
                (key (string-append (car (string-split (or (plist-get now 'artists) "") ",")) " | " album)))
           (list active href artist-href artist (spotify--get 'photos name) (spotify--get 'briefs name)
                 (spotify--get 'news name) (spotify--get 'liners key) (spotify--get 'facts (spotify--dig-key name album))
                 (spotify--get 'albums (or (plist-get now 'albumHref) ""))
                 (spotify--get 'stages (spotify--stage-key name (or (plist-get now 'title) "")))
                 (eq? (plist-get *spotify-now* 'playing) #t)))))
      ((equal? active "artist")
       (let* ((links (spotify--links href))
              (artist-href (spotify--artist-href row links))
              (artist (spotify--get 'artists artist-href))
              (name (let ((n (and artist (plist-get artist 'name))))
                      (if (and (string? n) (not (equal? n ""))) n (spotify--row-artist row)))))
         ;; the artist's page is the artist's, whichever of their songs plays
         (list active artist-href artist (and (member artist-href *spotify-failed*) #t)
               (spotify--get 'briefs name) (spotify--get 'news name)
               (spotify--get 'photos name))))
      (else
       (let* ((key (string-append (car (string-split (or (site-app-field row 'artists) "") ",")) " | " (or (site-app-field row 'album) ""))))
         (list active href key (spotify--get 'liners key) (spotify--now-field 'trackHref)
               (spotify--get 'albums (or (plist-get (spotify--row-now row) 'albumHref) ""))
               (buffer-local b 'site-app-data)))))))

(define (spotify--same-inputs? a b)
  (and (pair? b) (= (length a) (length b))
       (let loop ((x a) (y b))
         (or (null? x)
             (and (if (string? (car x)) (equal? (car x) (car y)) (eq? (car x) (car y)))
                  (loop (cdr x) (cdr y)))))))

(define (spotify--redraw-artist-tabs!)
  ;; every read ends here, so this is where what it read goes to disk
  (spotify--cache-touch!)
  (for-each (lambda (b)
              (when (member (buffer-local b 'site-app-active) '("ambient" "artist" "album"))
                (let ((now (spotify--tab-inputs b)))
                  (unless (spotify--same-inputs? now (buffer-local b 'sp-drawn))
                    (buffer-set-local! b 'sp-drawn now)
                    (site-app-draw! b)))))
            (filter spotify--detail? (buffer-list))))

;; an album row has no track, artist or album field of its own; its page does.
;; Where a page wants a track (to find the artist, or the album's notes) the
;; album's first track stands for it
(define (spotify--deep-find x pre)
  (cond ((string? x) (and (string-prefix? pre x) x))
        ((pair? x) (or (spotify--deep-find (car x) pre) (spotify--deep-find (cdr x) pre)))
        (else #f)))

(define (spotify--as-track buf row)
  (let ((href (or (site-app-field row 'href) ""))
        (d (buffer-local buf 'site-app-data)))
    (cond
      ;; a track from a list that did not carry its album: the page of the track names it
      ((and (string-prefix? "/track/" href) (equal? (or (site-app-field row 'album) "") ""))
       (let* ((hero (and d (let ((s (site-app-real (plist-get d 'section)))) (and (pair? s) (car s)))))
              (tags (or (and hero (plist-get hero 'tags)) '()))
              (album (cond ((and (> (length tags) 2) (equal? (car tags) "Song")) (caddr tags))
                           ((equal? href (spotify--now-field 'trackHref)) (spotify--now-field 'album))
                           (else ""))))
         (if (and (string? album) (not (equal? album ""))) (plist-put row 'album album) row)))
      ((or (not (string-prefix? "/album/" href)) (not d)) row)
      (else
        (let* ((t (spotify--deep-find d "/track/"))
               (hero (let ((s (site-app-real (plist-get d 'section)))) (and (pair? s) (car s))))
               (tags (or (and hero (plist-get hero 'tags)) '()))
               (artist (if (> (length tags) 1) (cadr tags) "")))
          (if t
              (plist-put (plist-put (plist-put row 'href t) 'album (or (site-app-field row 'name) "")) 'artists artist)
              row))))))

(define *spotify-tries* '())   ; (HREF N): how many reads of an artist's page have come back empty

(define (spotify--wikipedia-artist name)
  ;; the artist as Wikipedia has them, when Spotify's page will not read: a
  ;; name, a photo and a bio, no tour. The page is found by a search and kept
  ;; only when its title carries the artist's last name
  (let* ((ua (list 'headers (list (list "User-Agent" "compos-spotify/1.0 (svs@svs.io)"))))
         (found (http-get-json (string-append "https://en.wikipedia.org/w/api.php?action=query&format=json&list=search&srlimit=1&srsearch="
                                              (url-encode (string-append name " musician"))) ua))
         (hits (and found (plist-get (plist-get found 'query) 'search)))
         (title (and (pair? hits) (plist-get (car hits) 'title)))
         (title (and (string? title) (spotify--has? title (car (reverse (string-split name " ")))) title))
         (sum (and title (http-get-json (string-append "https://en.wikipedia.org/api/rest_v1/page/summary/"
                                                       (url-encode (re-replace-all " " title "_"))) ua))))
    (and sum (string? (plist-get sum 'extract))
         (list 'name name
               'image (let ((t (plist-get sum 'originalimage))) (or (and t (plist-get t 'source)) ""))
               'listeners "" 'verified "no" 'bio (plist-get sum 'extract) 'tour '() 'source "wikipedia"))))

(define (spotify--artist-read! href name)
  ;; an artist's page, and when it will not read, another way: the read once
  ;; more (the page may have been slow to draw), then the artist from
  ;; Wikipedia. Only when all of that comes back empty is the page given up
  (let ((tries (let ((e (assoc href *spotify-tries*))) (if e (cadr e) 0))))
    (spotify--read-page! href *spotify-artist-sheet*
      (lambda (data)
        (cond
          (data
           (spotify--put! 'artists href data)
           (spotify--redraw-artist-tabs!))
          ((< tries 1)
           (set! *spotify-tries* (cons (list href (+ tries 1)) *spotify-tries*))
           (set! *spotify-asked* (spotify--without href *spotify-asked*))
           (when (spotify--ask! href) (spotify--artist-read! href name)))
          (else
           (task-run!
             (lambda () (spotify--wikipedia-artist name))
             (lambda (ok found)
               (if (and ok (pair? found))
                   (spotify--put! 'artists href found)
                   (set! *spotify-failed* (cons href *spotify-failed*)))
               (spotify--redraw-artist-tabs!))
             30000)))))))

(define (spotify--row-artist row)
  ;; the first artist a row names: its own, else the shelf it sits on ("More by X")
  (let ((a (string-trim (car (string-split (or (site-app-field row 'artists) "") ","))))
        (shelf (or (site-app-field row 'shelf) "")))
    (cond ((not (equal? a "")) a)
          ((string-prefix? "More by " shelf) (substring shelf 8 (string-length shelf)))
          (else ""))))

(define (spotify--artist-href row links)
  ;; the artist is read once, by name: a page already read of that name stands for
  ;; every row of theirs; only an artist not yet read asks a track whose page it is
  (let* ((name (spotify--row-artist row))
         (known (and (not (equal? name ""))
                     (find (lambda (e) (equal? (plist-get (cadr e) 'name) name))
                           (site-app-cache-entries 'spotify 'artists)))))
    (cond (known (car known)) (links (caddr links)) (else ""))))

(define (spotify--artist-draw buf b)
  ;; the artist of the track on BUF's row: their photo over the bio (the
  ;; brief once it is written), then their tours and the news
  (let* ((row (spotify--as-track buf (buffer-local buf 'site-app-row)))
         (href (or (site-app-field row 'href) ""))
         (links (spotify--links href))
         (artist-href (spotify--artist-href row links))
         (artist (spotify--get 'artists artist-href))
         (name (let ((n (and artist (plist-get artist 'name))))
                 (if (and (string? n) (not (equal? n ""))) n (spotify--row-artist row))))
         (page (cond ((and (equal? artist-href "") (string-prefix? "/track/" href))
                      (spotify--track-links! href)
                      (list (spotify--quiet "Finding the artist…")))
                     ((equal? artist-href "") '())
                     (else
                      (when (and (not artist) (not (equal? artist-href "")) (spotify--ask! artist-href))
                        (spotify--artist-read! artist-href name))
                      (spotify--news-of! name)
                      (when (and artist (spotify--ask! (string-append "brief:" name)))
                        (spotify--brief! name artist))
                      (if (and (not artist) (member artist-href *spotify-failed*))
                          (list (spotify--quiet (string-append "Spotify did not show " name "'s page.")))
                          (spotify--artist-blocks name artist))))))
    (car (spotify--claim-all b page))))

;; one artist's photos at a time: Wikimedia refuses a burst, and every
;; artist tab drawing at once is one
(define *spotify-photos-busy* #f)
;; a refusal waits a minute before the next artist is asked
(define *spotify-photos-after* -1000000000000000)

(define (spotify--photos! name)
  ;; the artist's photos for the montage: their Wikipedia page's, then their
  ;; Commons category's. The page is found by a search, kept only when its
  ;; title carries the artist's last name, so a namesake lends no faces
  (when (and (not (equal? name "")) (not *spotify-photos-busy*) (> (monotonic-ms) *spotify-photos-after*)
             (spotify--ask! (string-append "photos:" name)))
    (set! *spotify-photos-busy* #t)
    (task-run!
      (lambda ()
        (let* ((ua (list 'headers (list (list "User-Agent" "compos-spotify/1.0 (svs@svs.io)"))))
               (found (http-get-json (string-append "https://en.wikipedia.org/w/api.php?action=query&format=json&list=search&srlimit=1&srsearch="
                                                    (url-encode (string-append name " musician")))
                                     ua))
               (hits (and found (plist-get (plist-get found 'query) 'search)))
               (title (and (pair? hits) (plist-get (car hits) 'title)))
               (title (and (string? title) (spotify--has? title (car (reverse (string-split name " ")))) title))
               (pages (lambda (j) (let loop ((x (let ((p (and j (plist-get (plist-get j 'query) 'pages)))) (if (pair? p) p '()))) (acc '()))
                                    (if (null? x) (reverse acc) (loop (cddr x) (cons (cadr x) acc))))))
               ;; photographs, big enough for the banner: no logos, maps or covers
               (photos (lambda (j)
                         (filter string?
                           (map (lambda (p) (let* ((ii (plist-get p 'imageinfo)) (i (and (pair? ii) (car ii))))
                                              (and i (member (plist-get i 'mime) '("image/jpeg" "image/png")) (> (or (plist-get i 'width) 0) 500)
                                                   (plist-get i 'thumburl))))
                                (pages j)))))
               (ask (lambda (host query) (http-get-json (string-append "https://" host "/w/api.php?action=query&format=json&redirects=1&prop=imageinfo&iiprop=url%7Csize%7Cmime&iiurlwidth=1280&" query) ua)))
               ;; Deezer's portrait of the artist, whatever Wikipedia has
               (deezer (let* ((j (http-get-json (string-append "https://api.deezer.com/search/artist?limit=1&q=" (url-encode name))))
                              (d (and j (plist-get j 'data)))
                              (a (and (pair? d) (car d))))
                         (if (and a (equal? (string-downcase (or (plist-get a 'name) "")) (string-downcase name))
                                  (string? (plist-get a 'picture_xl)))
                             (list (plist-get a 'picture_xl))
                             '()))))
          ;; no answer to the search is a refusal, asked again later; no page is Deezer's photo alone
          (cond ((not found) 'refused)
                ((not title) deezer)
                (else
              (fold (lambda (acc u) (if (member u acc) acc (append acc (list u)))) '()
                    (append deezer
                            (photos (ask "en.wikipedia.org" (string-append "generator=images&gimlimit=30&titles=" (url-encode title))))
                            (photos (ask "commons.wikimedia.org" (string-append "generator=categorymembers&gcmtype=file&gcmlimit=20&gcmtitle="
                                                                                (url-encode (string-append "Category:" title)))))))))))
      (lambda (ok urls)
        (set! *spotify-photos-busy* #f)
        (if (and ok (or (null? urls) (pair? urls)))
            (begin
              (spotify--put! 'photos name urls)
              (spotify--redraw-artist-tabs!))
            (begin
              (set! *spotify-photos-after* (+ (monotonic-ms) 60000))
              (set! *spotify-asked* (spotify--without (string-append "photos:" name) *spotify-asked*)))))
      30000)))

(define (spotify--artist-images name artist)
  ;; Spotify's photo first, then the rest; asking for the rest the first time
  (let ((main (or (and artist (plist-get artist 'image)) ""))
        (more (spotify--get 'photos name)))
    (unless more (spotify--photos! name))
    (append (if (equal? main "") '() (list main)) (or more '()))))

;; the artist, then the news, then the tour: the news is where the walk goes first,
;; and the tour is the sidebar beside it (the page's layout puts it there)
(define (spotify--news-first card tour news) (append card news tour))

(define (spotify--artist-blocks name artist)
  (let* ((brief (spotify--get 'briefs name))
         (news (spotify--get 'news name))
         (tour (let ((ts (filter (lambda (g) (equal? (plist-get g 'artist) name)) (or (and artist (plist-get artist 'tour)) '()))))
                 (if (> (length ts) 8) (list-head ts 8) ts))))
    (spotify--news-first
      (if artist
          (list (spotify--lined (component 'spotify/artist-card
                  (list 'name name 'image (or (plist-get artist 'image) "") 'images (spotify--artist-images name artist)
                        'listeners (or (plist-get artist 'listeners) "")
                        'verified? (equal? (plist-get artist 'verified) "yes")
                        'bio (if (string? brief) brief (or (plist-get artist 'bio) ""))))
                  name))
          (list (spotify--quiet (string-append "Reading " name "'s page…"))))
      (if (null? tour) '()
          (spotify--part "On tour"
                (map (lambda (g)
                       (spotify--lined (component 'spotify/gig
                         (list 'month (plist-get g 'month) 'day (plist-get g 'day) 'city (plist-get g 'city)
                               'venue (plist-get g 'venue) 'when (plist-get g 'when)
                               'click (string-append "spotify-url:https://open.spotify.com" (plist-get g 'href))))
                         (string-append (plist-get g 'month) " " (plist-get g 'day) " " (plist-get g 'city))))
                     tour)))
      (spotify--part "News"
            (cond ((not news) (list (spotify--quiet (string-append "Looking for news about " name "…"))))
                  ((null? news) (list (spotify--quiet "No news found.")))
                  (else
                   (map (lambda (n)
                          (let* ((snippet (or (plist-get n 'snippet) ""))
                                 (at (string-index snippet " ... "))
                                 (date (if (and at (< at 20)) (substring snippet 0 at) ""))
                                 (body (if (and at (< at 20)) (substring snippet (+ at 5) (string-length snippet)) snippet)))
                            (spotify--lined (component 'spotify/news-item
                              (list 'title (or (plist-get n 'title) "") 'source (spotify--host (or (plist-get n 'link) ""))
                                    'date date 'snippet body 'click (string-append "spotify-url:" (or (plist-get n 'link) ""))))
                              (or (plist-get n 'title) ""))))
                        news)))))))

(define *spotify-mb-agent* (list 'headers (list (list "User-Agent" "compos-spotify/1.0 (svs@svs.io)"))))

(define (spotify--has? text part)
  (and (string? text) (string? part) (not (equal? part ""))
       (string-index (string-downcase text) (string-downcase part)) #t))

(define (spotify--liner-put! key props)
  ;; what a source found joins what the others did, and the album tabs draw again
  (let loop ((ps props) (liner (or (spotify--get 'liners key) '())))
    (if (null? ps)
        (spotify--put! 'liners key liner)
        (loop (cddr ps) (plist-put liner (car ps) (cadr ps)))))
  (spotify--redraw-artist-tabs!))

(define (spotify--mb-personnel release)
  ;; MusicBrainz's credits, the release's and every recording's, as
  ;; ((NAME ROLES ID KIND) ...): the players first, then who made the record
  (let* ((rels (append (or (plist-get release 'relations) '())
                       (apply append
                         (map (lambda (medium)
                                (apply append
                                  (map (lambda (t) (or (plist-get (plist-get t 'recording) 'relations) '()))
                                       (or (plist-get medium 'tracks) '()))))
                              (or (plist-get release 'media) '())))))
         (role (lambda (r)
                 (let ((type (or (plist-get r 'type) "")) (attrs (or (plist-get r 'attributes) '())))
                   ;; MusicBrainz files a drum kit under its family
                   (cond ((member type '("instrument" "vocal"))
                          (if (null? attrs) type (re-replace-all "membranophone" (string-join attrs ", ") "drums")))
                         ((equal? type "audio") "engineer")
                         (else type)))))
         (plays? (lambda (r) (member (plist-get r 'type) '("instrument" "vocal" "performer"))))
         (gather (lambda (keep kind)
                   (fold (lambda (acc r)
                           (let* ((name (plist-get (plist-get r 'artist) 'name)) (id (plist-get (plist-get r 'artist) 'id)) (what (role r)) (hit (assoc name acc)))
                             (cond ((not (and (string? name) (keep r))) acc)
                                   ((not hit) (append acc (list (list name (list what) id kind))))
                                   ((member what (cadr hit)) acc)
                                   (else (map (lambda (e) (if (equal? (car e) name) (list name (append (cadr e) (list what)) (list-ref e 2) kind) e)) acc)))))
                         '() rels))))
    (append (gather plays? 'player) (gather (lambda (r) (not (plays? r))) 'crew))))

(define (spotify--wiki-sections text)
  ;; a Wikipedia extract as ((TITLE PARAGRAPHS) ...), without the lists the
  ;; other sources say better
  (let loop ((lines (string-split text "\n")) (title "") (paras '()) (out '()))
    (let ((close (lambda () (if (null? paras) out (append out (list (list title (reverse paras))))))))
      (cond ((null? lines)
             (filter (lambda (s) (not (member (car s) '("Track listing" "Personnel" "References" "External links" "Charts" "See also" "Notes" "Credits" "Release history")))) (close)))
            ((re-match? "^==[^=].*==$" (string-trim (car lines)))
             (loop (cdr lines) (string-trim (re-replace-all "=" (string-trim (car lines)) "")) '() (close)))
            ((or (equal? (string-trim (car lines)) "") (string-prefix? "=" (string-trim (car lines))))
             (loop (cdr lines) title paras out))
            (else (loop (cdr lines) title (cons (string-trim (car lines)) paras) out))))))

(define spotify--ld-type (string->symbol "@type"))

(define (spotify--stars rating)
  ;; AllMusic's n of 10 as stars of 5
  ;; the rating is a string or a number, and not always a whole one
  (let ((n (cond ((number? rating) rating) ((string? rating) (string->number rating)) (else #f))))
    (if (not n) ""
        (let* ((whole (length (filter (lambda (i) (>= n (* 2 i))) '(1 2 3 4 5))))
               (half (and (< whole 5) (>= (- n (* 2 whole)) 1))))
          (string-append (apply string-append (map (lambda (i) "★") (iota whole)))
                         (if half "½" ""))))))

(define (spotify--allmusic-paras html)
  ;; the review as the page sets it, a paragraph each; its schema.org copy
  ;; runs them all together
  (let* ((parts (string-split html "class=\"editorialAuthorLink\""))
         (after (and (pair? (cdr parts)) (string-split (car (reverse parts)) "</h3>")))
         (body (and after (pair? (cdr after)) (car (string-split (cadr after) "</div>"))))
         (clean (lambda (p)
                  (string-trim
                    (re-replace-all "&nbsp;"
                      (re-replace-all "&#0?39;"
                        (re-replace-all "&quot;"
                          (re-replace-all "&amp;" (re-replace-all "<[^>]*>" p "") "&")
                          "\"")
                        "'")
                      " ")))))
    (if body
        (filter (lambda (s) (not (equal? s ""))) (map clean (cdr (string-split body "<p>"))))
        '())))

(define (spotify--allmusic-read! key url)
  ;; AllMusic answers no plain request; your Chrome reads it, and the page's
  ;; own schema.org data holds the review and its rating
  (if (not (browser-connected?))
      (spotify--liner-put! key (list 'allmusic-done #t))
      (browser-snapshot url
        (lambda (html)
          (let* ((blocks (if (string? html)
                             (map (lambda (b) (json-parse (car (string-split b "</script>"))))
                                  (cdr (string-split html "<script type=\"application/ld+json\">")))
                             '()))
                 (of (lambda (type) (find (lambda (j) (and (pair? j) (equal? (plist-get j spotify--ld-type) type))) blocks)))
                 (review (of "Review"))
                 (album (of "MusicAlbum")))
            (spotify--liner-put! key
              (list 'review (let ((paras (if (string? html) (spotify--allmusic-paras html) '())))
                              (if (pair? paras)
                                  (string-join paras "\n")
                                  (and review (plist-get review 'reviewBody))))
                    'rating (and review (plist-get (plist-get review 'reviewRating) 'ratingValue))
                    'genre (if (and album (pair? (plist-get album 'genre))) (string-join (plist-get album 'genre) ", ") "")
                    'allmusic-done #t))))
        "h1")))

(define (spotify--wiki-text artist album)
  ;; the album's Wikipedia page as plain text, when it names the artist
  (let* ((wq (http-get-json (string-append "https://en.wikipedia.org/w/api.php?action=query&list=search&format=json&srlimit=5&srsearch="
                                           (url-encode (string-append album " " artist " album")))
                            *spotify-mb-agent*))
         (hits (or (and wq (plist-get (plist-get wq 'query) 'search)) '()))
         ;; the album's own page before a page that only shares its name
         (hit (or (find (lambda (h) (and (spotify--has? (plist-get h 'title) album) (spotify--has? (plist-get h 'title) "album"))) hits)
                  (find (lambda (h) (spotify--has? (plist-get h 'title) album)) hits)))
         (title (and hit (plist-get hit 'title)))
         (j (and title (http-get-json (string-append "https://en.wikipedia.org/w/api.php?action=query&prop=extracts&explaintext=1&format=json&titles=" (url-encode title))
                                      *spotify-mb-agent*)))
         (pages (and j (plist-get (plist-get j 'query) 'pages)))
         (page (and (pair? pages) (cadr pages)))
         (text (and page (plist-get page 'extract))))
    (and (spotify--has? text (car (reverse (string-split artist " "))))
         (not (spotify--has? text "may refer to"))
         (list title text))))

(define (spotify--mb-release artist album)
  ;; the album's first MusicBrainz release, with every credit. The search
  ;; asks by title only and keeps a release credited to the artist's surname:
  ;; Spotify's "Nik Bärtsch" is MusicBrainz's "Nik Bärtsch's Ronin"
  (let* ((surname (car (reverse (string-split artist " "))))
         (found (http-get-json (string-append "https://musicbrainz.org/ws/2/release/?fmt=json&limit=15&query="
                                              (url-encode (string-append "release:\"" album "\"")))
                               *spotify-mb-agent*))
         (rs (filter (lambda (r) (and (spotify--has? (plist-get r 'title) album)
                                      (find (lambda (c) (spotify--has? (plist-get c 'name) surname)) (or (plist-get r 'artist-credit) '()))))
                     (or (and found (plist-get found 'releases)) '()))))
    (and (pair? rs)
         (http-get-json (string-append "https://musicbrainz.org/ws/2/release/" (plist-get (car rs) 'id)
                                       "?fmt=json&inc=artist-rels+recordings+recording-level-rels+labels")
                        *spotify-mb-agent*))))

(define (spotify--liner! key album artist)
  ;; the album's liner notes, from three places: AllMusic's review,
  ;; MusicBrainz's credits and release, Wikipedia's background
  (task-run!
    (lambda ()
      (let* ((search (spotify--mcp-search (json-encode (list 'query (string-append "allmusic " artist " " album " album") 'num 5))))
             (hits (if (and (string? search) (string-prefix? "[" (string-trim search))) (json-parse search) '()))
             (am (find (lambda (h) (and (spotify--has? (plist-get h 'link) "allmusic.com/album/") (spotify--has? (plist-get h 'title) album))) hits))
             (release (spotify--mb-release artist album))
             (wiki (spotify--wiki-text artist album))
             (li (and release (plist-get release 'label-info))))
        (list 'allmusic (and am (plist-get am 'link)) 'allmusic-snippet (and am (plist-get am 'snippet))
              'label (if (pair? li) (or (plist-get (plist-get (car li) 'label) 'name) "") "")
              'date (or (and release (plist-get release 'date)) "")
              'country (or (and release (plist-get release 'country)) "")
              'personnel (if release (spotify--mb-personnel release) '())
              'musicbrainz (and release (string-append "https://musicbrainz.org/release/" (plist-get release 'id)))
              'wiki (if wiki (spotify--wiki-sections (cadr wiki)) '())
              'wiki-url (and wiki (string-append "https://en.wikipedia.org/wiki/" (re-replace-all " " (car wiki) "_"))))))
    (lambda (ok liner)
      (if (not ok)
          (set! *spotify-asked* (spotify--without (string-append "liner:" key) *spotify-asked*))
          (begin
            (spotify--liner-put! key (append liner (list 'done #t)))
            (if (plist-get liner 'allmusic)
                (spotify--allmusic-read! key (plist-get liner 'allmusic))
                (spotify--liner-put! key (list 'allmusic-done #t))))))
    60000))

(define (spotify--row-now row)
  ;; a row's track as the Now Playing page's plist
  (let ((links (spotify--links (or (site-app-field row 'href) ""))))
    (list 'title (or (site-app-field row 'name) "") 'artists (or (site-app-field row 'artists) "")
          'art (spotify--row-cover row) 'duration (or (site-app-field row 'duration) "") 'album (or (site-app-field row 'album) "")
          'albumHref (if links (cadr links) "") 'artistHref (if links (caddr links) ""))))

(define (spotify--para text) (list 'tag "p" 'class "sp-bio" 'text text 'sp-line text))

(define (spotify--reflow text)
  ;; a long paragraph as a few, a handful of sentences each: AllMusic sets
  ;; many a review as one
  (if (< (string-length text) 600)
      (list text)
      (let loop ((ss (string-split (re-replace-all "([.!?][\"”)]?) (?=[A-Z\"“])" text "\\1\n") "\n")) (cur "") (out '()))
        (if (null? ss)
            (reverse (if (equal? cur "") out (cons cur out)))
            (let ((next (if (equal? cur "") (car ss) (string-append cur " " (car ss)))))
              (if (>= (string-length next) 350)
                  (loop (cdr ss) "" (cons next out))
                  (loop (cdr ss) next out)))))))

(define (spotify--part title blocks)
  ;; a part of the page: its heading and what is under it, one anchor. Its
  ;; class names it too (sp-part-on-tour), for a page that lays parts out
  (if (null? blocks) '()
      (list (spotify--lined (component 'ui/group (list 'class (string-append "sp-part sp-part-" (re-replace-all "[^a-z0-9]+" (string-downcase title) "-"))
                                                         'body (cons (spotify--section-title title) blocks)))
                            title))))

;; Searching the web for the pages: the Google search server when this chat has
;; it, else DuckDuckGo's plain page, so a page never goes without for lack of a
;; search. Answers the same JSON, [{title, link, snippet}...]
(define (spotify--ddg-hits html)
  (let loop ((chunks (cdr (string-split html "result__a"))) (acc '()))
    (if (null? chunks) (reverse acc)
        (let* ((c (car chunks))
               (m (re-match "href=\"([^\"]*)\"[^>]*>([^<]*(?:<[^/][^>]*>[^<]*)*)</a>" c))
               (raw (and m (cadr m)))
               (u (and raw (re-match "uddg=([^&\"]+)" raw)))
               (link (cond (u (url-decode (cadr u))) ((and raw (string-prefix? "http" raw)) raw) (else #f)))
               (title (and m (string-trim (string-replace (string-replace (string-replace (re-replace-all "<[^>]*>" (caddr m) "") "&amp;" "&") "&#x27;" "'") "&quot;" "\""))))
               (sn (re-match "result__snippet[^>]*>(.*?)</a>" c))
               (snippet (if sn (string-trim (re-replace-all "<[^>]*>" (cadr sn) "")) "")))
          (loop (cdr chunks) (if (and link title (not (equal? title ""))) (cons (list 'title title 'link link 'snippet snippet) acc) acc))))))

(define (spotify--mcp-search args)
  ;; ARGS the search server's JSON: {query, num}
  (let ((r (mcp-call! 'google-search "search" args)))
    (if (and (string? r) (string-prefix? "[" (string-trim r))) r
        (let* ((a (json-parse args))
               (n (or (plist-get a 'num) 8))
               (html (http-text (string-append "https://html.duckduckgo.com/html/?q=" (url-encode (plist-get a 'query)))))
               (hits (if (string? html) (spotify--ddg-hits html) '())))
          (if (null? hits) "[]" (json-encode (if (> (length hits) n) (list-head hits n) hits)))))))

(define *spotify-review-skip*
  '("allmusic.com" "wikipedia.org" "spotify.com" "apple.com" "youtube.com" "amazon." "discogs.com"
    "bandcamp.com" "facebook.com" "instagram.com" "deezer.com" "tidal.com" "last.fm" "ecmrecords.com"))

(define (spotify--reviews! key album artist)
  ;; the album's reviews around the web, beyond AllMusic's
  (when (spotify--ask! (string-append "reviews:" key))
    (task-run!
      (lambda ()
        (let* ((search (spotify--mcp-search
                         (json-encode (list 'query (string-append "\"" album "\" " artist " album review") 'num 10))))
               (hits (if (and (string? search) (string-prefix? "[" (string-trim search))) (json-parse search) '()))
               (kept (filter (lambda (h) (let ((link (plist-get h 'link)))
                                           ;; about this album, not another of the artist's
                                           (and (string? link) (not (find (lambda (s) (spotify--has? link s)) *spotify-review-skip*))
                                                (spotify--has? (string-append (or (plist-get h 'title) "") " " link) album))))
                             hits)))
          (if (> (length kept) 6) (list-head kept 6) kept)))
      (lambda (ok items)
        (if ok
            (spotify--liner-put! key (list 'reviews items 'reviews-done #t))
            (set! *spotify-asked* (spotify--without (string-append "reviews:" key) *spotify-asked*))))
      30000)))

(define (spotify--review-card n)
  (spotify--lined (component 'spotify/news-item
                    (list 'title (or (plist-get n 'title) "") 'source (spotify--host (or (plist-get n 'link) ""))
                          'date "" 'snippet (or (plist-get n 'snippet) "")
                          'click (string-append "spotify-url:" (or (plist-get n 'link) ""))))
                  (or (plist-get n 'title) "")))

(define (spotify--faces! key liner)
  ;; who played, with their faces: one Wikidata question for everyone, by
  ;; MusicBrainz id, answers each one's photo and Wikipedia page. Notes read
  ;; before the ids were kept read their release again for them
  (task-run!
    (lambda ()
      (let* ((people (or (plist-get liner 'personnel) '()))
             (people (if (or (null? people) (find (lambda (p) (> (length p) 2)) people)) people
                         (let* ((mb (plist-get liner 'musicbrainz))
                                (release (and (string? mb)
                                              (http-get-json (string-append (re-replace-all "musicbrainz.org/release/" mb "musicbrainz.org/ws/2/release/")
                                                                            "?fmt=json&inc=artist-rels+recordings+recording-level-rels")
                                                             *spotify-mb-agent*))))
                           (if release (spotify--mb-personnel release) people))))
             (ids (filter string? (map (lambda (p) (and (> (length p) 2) (list-ref p 2))) people)))
             (q (string-append "SELECT ?mbid ?img ?article WHERE { VALUES ?mbid { "
                               (string-join (map (lambda (i) (string-append "\"" i "\"")) ids) " ")
                               " } ?item wdt:P434 ?mbid . OPTIONAL { ?item wdt:P18 ?img } "
                               "OPTIONAL { ?article schema:about ?item ; schema:isPartOf <https://en.wikipedia.org/> } }"))
             (ans (and (pair? ids)
                       (http-get-json (string-append "https://query.wikidata.org/sparql?format=json&query=" (url-encode q))
                                      (list 'headers (append (plist-get *spotify-mb-agent* 'headers)
                                                             (list (list "Accept" "application/sparql-results+json")))))))
             (value (lambda (row k) (let ((v (plist-get row k))) (and v (plist-get v 'value))))))
        (list 'personnel people
              'faces (map (lambda (row)
                            (list (value row 'mbid)
                                  (let ((img (value row 'img))) (and img (string-append (re-replace-all "^http:" img "https:") "?width=320")))
                                  (value row 'article)))
                          (if ans (or (plist-get (plist-get ans 'results) 'bindings) '()) '())))))
    (lambda (ok found)
      (if ok
          (spotify--liner-put! key (append found (list 'faces-done #t)))
          (set! *spotify-asked* (spotify--without (string-append "faces:" key) *spotify-asked*))))
    30000))

(define (spotify--initials name)
  (let ((words (filter (lambda (w) (not (equal? w ""))) (string-split (or name "") " "))))
    (string-upcase (apply string-append (map (lambda (w) (substring w 0 1))
                                             (if (> (length words) 1) (list (car words) (car (reverse words))) words))))))

(define (spotify--person-card p faces)
  ;; one credit as a card: the face Wikidata knows, the roles, and a click to
  ;; their Wikipedia page, else their MusicBrainz one
  (let* ((name (car p))
         (roles (string-join (cadr p) ", "))
         (id (and (> (length p) 2) (list-ref p 2)))
         (face (and id (assoc id faces)))
         (link (cond ((and face (list-ref face 2)) (list-ref face 2))
                     (id (string-append "https://musicbrainz.org/artist/" id))
                     (else #f))))
    (spotify--lined (component 'spotify/person
                      (list 'name name 'roles roles 'image (or (and face (cadr face)) "")
                            'crew? (and (> (length p) 3) (eq? (list-ref p 3) 'crew))
                            'click (if link (string-append "spotify-url:" link) "")))
                    (string-append name " — " roles))))

(define (spotify--liner-blocks album liner)
  ;; the notes, a part each: AllMusic's review, the reviews around the web,
  ;; who played, and each part of the Wikipedia page
  (let ((review (plist-get liner 'review))
        (people (or (plist-get liner 'personnel) '()))
        (facts (filter (lambda (s) (and (string? s) (not (equal? s ""))))
                       (list (plist-get liner 'label) (plist-get liner 'date) (plist-get liner 'country) (plist-get liner 'genre))))
        (sources (filter string? (list (plist-get liner 'allmusic) (plist-get liner 'musicbrainz) (plist-get liner 'wiki-url))))
        (stars (spotify--stars (plist-get liner 'rating))))
    (append
      (if (null? facts) '() (list (spotify--para (string-join facts " · "))))
      (spotify--part (if (equal? stars "") "AllMusic" (string-append "AllMusic  " stars))
        (cond ((string? review) (map spotify--para (apply append (map spotify--reflow (filter (lambda (s) (not (equal? (string-trim s) ""))) (string-split review "\n"))))))
              ((not (plist-get liner 'allmusic-done)) (list (spotify--quiet "Reading AllMusic's review…")))
              ((string? (plist-get liner 'allmusic-snippet)) (list (spotify--para (plist-get liner 'allmusic-snippet))))
              (else '())))
      (spotify--part "Reviews"
        (cond ((not (plist-get liner 'reviews-done)) (list (spotify--quiet "Looking for reviews…")))
              (else (map spotify--review-card (or (plist-get liner 'reviews) '())))))
      ;; who played as faces; who made the record, smaller, after them
      (let ((faces (or (plist-get liner 'faces) '()))
            (crew? (lambda (p) (and (> (length p) 3) (eq? (list-ref p 3) 'crew)))))
        (append
          (spotify--part "Personnel" (map (lambda (p) (spotify--person-card p faces)) (filter (lambda (p) (not (crew? p))) people)))
          (spotify--part "Production" (map (lambda (p) (spotify--person-card p faces)) (filter crew? people)))))
      (apply append
        (map (lambda (s) (spotify--part (if (equal? (car s) "") "Background" (car s)) (map spotify--para (apply append (map spotify--reflow (cadr s))))))
             (or (plist-get liner 'wiki) '())))
      ;; each source a line RET reads beside the page
      (spotify--part "Sources"
        (map (lambda (u)
               (plist-put (spotify--quiet (string-append (cond ((spotify--has? u "allmusic") "AllMusic")
                                                               ((spotify--has? u "musicbrainz") "MusicBrainz")
                                                               (else "Wikipedia"))
                                                         " ↗"))
                          'click (string-append "spotify-url:" u)))
             sources)))))

(define (spotify--album-draw buf b)
  ;; the album of the track on BUF's row, as its liner notes: the cover,
  ;; AllMusic's review, who played, the release, and the story behind it
  (let* ((row (spotify--as-track buf (buffer-local buf 'site-app-row)))
         (href (or (site-app-field (buffer-local buf 'site-app-row) 'href) ""))
         (album (or (site-app-field row 'album) ""))
         (artist (car (string-split (or (site-app-field row 'artists) "") ",")))
         (key (string-append artist " | " album))
         (liner (spotify--get 'liners key)))
    (when (and (not liner) (not (equal? album "")) (spotify--ask! (string-append "liner:" key)))
      (spotify--liner! key album artist))
    (when (and liner (not (plist-get liner 'reviews-done)))
      (spotify--reviews! key album artist))
    (when (and liner (plist-get liner 'done) (pair? (plist-get liner 'personnel))
               (not (plist-get liner 'faces-done)) (spotify--ask! (string-append "faces:" key)))
      (spotify--faces! key liner))
    (car (spotify--claim-all b
      (append
        (if (string-prefix? "/track/" href)
            (list (car (spotify--track-page (spotify--row-now row) (equal? href (spotify--now-field 'trackHref)))))
            '())
        (cond ((equal? album "") (list (spotify--quiet "No album for this row.")))
              ((not (and liner (plist-get liner 'done))) (list (spotify--quiet (string-append "Reading the notes for " album "…"))))
              (else (spotify--liner-blocks album liner))))))))

(define (spotify--weave lists)
  ;; one from each list in turn, until all are spent
  (let loop ((ls (filter pair? lists)) (acc '()))
    (if (null? ls) (reverse acc)
        (loop (filter pair? (map cdr ls)) (append (reverse (map car ls)) acc)))))

(define (spotify--html-text html)
  (let* ((t (re-replace-all "(?is)<(script|style)[^>]*>.*?</(script|style)>" html " "))
         (t (re-replace-all "<[^>]+>" t " "))
         (t (re-replace-all "\\s+" t " ")))
    (if (> (string-length t) 9000) (substring t 0 9000) t)))

;;; The digger: while the ambient page is on screen a cheap model keeps
;;; reading about what plays, one angle at a time, and files what it finds
;;; as facts for the page, by artist and album

(define *spotify-dig-busy* #f)
(define *spotify-digging* #f)

(define *spotify-dig-angles*
  '("the song itself" "how and where the album was recorded" "early life and training"
    "collaborators and the musicians on the record" "instruments and sound" "the scene, genre and city around them"
    "awards, charts and reception" "surprising trivia" "what they did next and are doing now" "influences and who they influenced"))

(define (spotify--dig-key name album) (string-append name " | " album))

(define (spotify--dig-search query)
  ;; what the digger reads, as plain text, from spotify-dig-source
  (cond ((eq? spotify-dig-source 'exa)
         (let* ((key (key-resolve "@EXA_API_KEY"))
                (j (and (string? key)
                        (http-post-json "https://api.exa.ai/search"
                          (json-encode (list 'query query 'numResults 5 'contents (list 'text (list 'maxCharacters 1500))))
                          (list 'headers (list (list "x-api-key" key) (list "Content-Type" "application/json"))))))
                (rs (and j (plist-get j 'results))))
           (if (pair? rs)
               (string-join (map (lambda (r) (string-append (or (plist-get r 'title) "") "\n" (or (plist-get r 'text) ""))) rs) "\n\n")
               "")))
        ((eq? spotify-dig-source 'browser)
         (let ((html (app-await (lambda (k) (browser-snapshot (string-append "https://html.duckduckgo.com/html/?q=" (url-encode query)) k)))))
           (if (string? html) (spotify--html-text html) "")))
        (else
         (let ((r (spotify--mcp-search (json-encode (list 'query query 'num 8))))) (if (string? r) r "")))))

(define (spotify--dig-prompt name album title angle known text)
  (string-append "You find facts for a music listener's ambient screen. Now playing: " title " by " name
    ", from the album " album ". This time look at: " angle ".\n"
    "From the sources below only, write up to 4 NEW facts that are not already known. One per line: LABEL | FACT. "
    "LABEL is one to three words, like The song, The album, The artist, In the studio, Trivia. "
    "FACT is one striking sentence under 120 characters, readable at a glance. No markdown. "
    "If the sources say nothing new, answer NONE.\n\nAlready known:\n" (string-join known "\n")
    "\n\nSources:\n" text))

(define (spotify--dig-parse answer)
  (filter pair?
    (map (lambda (line)
           (let ((at (string-index line "|")))
             (if (and at (> at 0))
                 (let ((label (string-trim (substring line 0 at)))
                       (fact (string-trim (re-replace-all "[*_]" (substring line (+ at 1) (string-length line)) ""))))
                   (if (and (> (string-length fact) 12) (<= (string-length label) 30)) (list label fact) '()))
                 '())))
         (string-split (if (string? answer) answer "") "\n"))))

(define (spotify--dig! name album title)
  ;; one round: an angle, a search, and the model's new facts
  (let* ((key (spotify--dig-key name album))
         (have (or (spotify--get 'facts key) '()))
         (round (or (spotify--get 'dig-round key) 0)))
    (when (and spotify-dig (not *spotify-dig-busy*) (not (equal? name "")) (< (length have) 80))
      (set! *spotify-dig-busy* #t)
      (spotify--put! 'dig-round key (+ round 1))
      (let ((angle (list-ref *spotify-dig-angles* (modulo round (length *spotify-dig-angles*)))))
        (task-run!
          (lambda () (spotify--dig-search (string-append name " " (if (= 0 (modulo round 3)) title album) " " angle)))
          (lambda (ok text)
            (if (not (and ok (string? text) (> (string-length text) 40)))
                (set! *spotify-dig-busy* #f)
                (llm-with-model
                  (spotify--dig-prompt name album title angle (map cadr have) (if (> (string-length text) 9000) (substring text 0 9000) text))
                  spotify-dig-model
                  (lambda (answer)
                    (set! *spotify-dig-busy* #f)
                    (let* ((known (map cadr (or (spotify--get 'facts key) '())))
                           (new (filter (lambda (f) (not (member (cadr f) known))) (spotify--dig-parse answer))))
                      (when (pair? new)
                        (spotify--put! 'facts key (append (or (spotify--get 'facts key) '()) new))
                        (spotify--redraw-artist-tabs!))))
                  (lambda (err) (set! *spotify-dig-busy* #f)))))
          60000)))))

(define (spotify--dig-name)
  (let* ((a (spotify--get 'artists (spotify--now-field 'artistHref)))
         (n (and a (plist-get a 'name))))
    (if (and (string? n) (not (equal? n ""))) n (car (string-split (spotify--now-field 'artists) ",")))))

(define (spotify--dig-tick! ignored)
  ;; the next round, while the ambient page is on screen; off screen it stops
  (set! *spotify-digging* #f)
  (when (and spotify-dig (buffer-exists? *spotify-now-detail*)
             (equal? (buffer-local *spotify-now-detail* 'site-app-active) "ambient")
             (member *spotify-now-detail* (get-visible-buffers)))
    (spotify--dig! (spotify--dig-name) (spotify--now-field 'album) (spotify--now-field 'title))
    (spotify--dig-start!)))

(define (spotify--dig-start!)
  (unless *spotify-digging*
    (set! *spotify-digging* #t)
    (debounce! 'spotify-dig (* 1000 spotify-dig-seconds) spotify--dig-tick! #f)))

(define (spotify--ambient-facts name artist now liner dug)
  ;; what the page tells, newest digging first, woven with what was read:
  ;; the record, who played, the bio, the tour and the news
  (let* ((text (or (spotify--get 'briefs name) (and artist (plist-get artist 'bio)) ""))
         (text (re-replace-all "[*_]" (if (string? text) text "") ""))
         (sentences (map (lambda (s) (list "The artist" s))
                         (filter (lambda (s) (let ((l (string-length s))) (and (> l 20) (< l 140))))
                                 (map string-trim (string-split (re-replace-all "([.!?])\\s+" text "\\1\n") "\n")))))
         (album (spotify--album-facts (or (plist-get now 'albumHref) "")))
         (album-name (if (equal? (car album) "") (or (plist-get now 'album) "") (car album)))
         (record (filter (lambda (s) (and (string? s) (not (equal? s ""))))
                         (list (cadr album) (and liner (plist-get liner 'label)) (and liner (plist-get liner 'genre)))))
         (people (map (lambda (p) (list "On the record" (string-append (car p) " — " (string-join (cadr p) ", "))))
                      (let ((ps (filter (lambda (p) (not (and (> (length p) 3) (eq? (list-ref p 3) 'crew))))
                                        (or (and liner (plist-get liner 'personnel)) '()))))
                        (if (> (length ps) 6) (list-head ps 6) ps))))
         (tour (map (lambda (g) (list "On tour" (string-append (plist-get g 'month) " " (plist-get g 'day) " · " (plist-get g 'city)
                                                               (if (string? (plist-get g 'venue)) (string-append " · " (plist-get g 'venue)) ""))))
                    (let ((ts (filter (lambda (g) (equal? (plist-get g 'artist) name)) (or (and artist (plist-get artist 'tour)) '()))))
                      (if (> (length ts) 2) (list-head ts 2) ts))))
         (news (map (lambda (n) (list "In the news" (or (plist-get n 'title) "")))
                    (let ((ns (or (spotify--get 'news name) '()))) (if (> (length ns) 3) (list-head ns 3) ns))))
         (fresh (let ((d (reverse dug))) (if (> (length d) 8) (list-head d 8) d))))
    (append (if (equal? album-name "") '()
                (list (list "From" (string-join (cons album-name record) " · "))))
            (spotify--weave (list fresh sentences people tour news)))))

(define (spotify--ambient-images name artist now liner)
  ;; the stage's photos: the artist's, the faces of who played, then the
  ;; covers of their records, so there are always several to change between
  (let* ((photos (if (equal? name "") '() (spotify--artist-images name artist)))
         (cover (spotify--hires (plist-get now 'art)))
         (covers (map (lambda (d) (spotify--hires (plist-get d 'art))) (or (and artist (plist-get artist 'discog)) '())))
         (faces (map cadr (or (and liner (plist-get liner 'faces)) '())))
         (all (filter (lambda (u) (and (string? u) (string-prefix? "http" u)))
                      (append photos faces (list cover) covers))))
    (fold (lambda (acc u) (if (member u acc) acc (append acc (list u)))) '() all)))

(define (spotify--ambient-draw buf b)
  ;; the page to glance at: the photos, the cover, and one fact at a time.
  ;; It reads the artist, the album's notes and the news, and digs for more
  (let* ((row (spotify--as-track buf (spotify--playing-row buf)))
         (now (spotify--row-now row))
         (href (or (site-app-field row 'href) ""))
         (artist-href (spotify--artist-href row (spotify--links href)))
         (artist (spotify--get 'artists artist-href))
         (name (let ((n (and artist (plist-get artist 'name))))
                 (if (and (string? n) (not (equal? n ""))) n (spotify--row-artist row))))
         (title (or (plist-get now 'title) ""))
         (album (or (plist-get now 'album) ""))
         (first-artist (car (string-split (or (plist-get now 'artists) "") ",")))
         (key (string-append first-artist " | " album))
         (liner (spotify--get 'liners key))
         (dug (or (spotify--get 'facts (spotify--dig-key name album)) '())))
    (cond ((and (equal? artist-href "") (string-prefix? "/track/" href)) (spotify--track-links! href))
          ((and (not artist) (not (equal? artist-href "")) (spotify--ask! artist-href)) (spotify--artist-read! artist-href name)))
    (spotify--album-read! (or (plist-get now 'albumHref) ""))
    (when (and (not liner) (not (equal? album "")) (spotify--ask! (string-append "liner:" key)))
      (spotify--liner! key album first-artist))
    (spotify--news-of! name)
    (when (null? dug) (spotify--dig! name album title))
    (spotify--dig-start!)
    (let ((facts (spotify--ambient-facts name artist now liner dug))
          (cover (spotify--hires (plist-get now 'art))))
      (spotify-stage! name album title facts)
      (car (spotify--claim-all b
        (list (spotify--lined (component 'spotify/ambient
                (append (list 'title title 'artists (or (plist-get now 'artists) "") 'art cover
                              'playing? (eq? (plist-get *spotify-now* 'playing) #t)
                              'position (car (cell-ref 'spotify/position)) 'duration (or (plist-get now 'duration) ""))
                        (spotify--staged (spotify--get 'stages (spotify--stage-key name title))
                                         (spotify--ambient-images name artist now liner) cover facts)))
                title)))))))

(define *spotify-ambient-tab*
  (list 'id "ambient" 'label "ambient" 'from '() 'draw (lambda (buf b) (spotify--ambient-draw buf b))))

(define *spotify-album-tab*
  (list 'id "album" 'label "album" 'from '() 'draw (lambda (buf b) (spotify--album-draw buf b))))

(define *spotify-artist-tab*
  (list 'id "artist" 'label "artist" 'from '() 'draw (lambda (buf b) (spotify--artist-draw buf b))))

(define (spotify--now-path)
  ;; the list that plays: the one it was played from while the track is in
  ;; it, else the track's album
  (let* ((o *spotify-origin*)
         (title (spotify--now-field 'title))
         (from (and o (cadr o)))
         (fresh (and o (or (not (buffer-exists? from)) (not (spotify--detail? from))
                           (and (not (equal? title "")) (string-index (buffer-text from) title))))))
    (if fresh (car o) (spotify--now-field 'albumHref))))

;; An album's track list carries no cover per track: they share the album's. When
;; the list that plays is the album that plays, its rows take the cover (and the
;; album's name) the player reports
(define (spotify--fill-covers! buf rows)
  (let ((art (spotify--now-field 'art)) (album (spotify--now-field 'album)))
    ;; and they share its page and its artist's: no read per track to learn them
    (when (and (pair? rows) (equal? (spotify--now-path) (spotify--now-field 'albumHref))
               (not (equal? (spotify--now-field 'artistHref) "")))
      (for-each (lambda (r)
                  (let ((h (or (site-app-field r 'href) "")))
                    (when (and (string-prefix? "/track/" h) (not (spotify--links h))
                               (equal? (car (string-split (or (site-app-field r 'artists) "") ","))
                                       (car (string-split (spotify--now-field 'artists) ","))))
                      (spotify--put! 'links h (list h (spotify--now-field 'albumHref) (spotify--now-field 'artistHref))))))
                rows))
    (when (and (pair? rows) (not (equal? art "")) (equal? (spotify--now-path) (spotify--now-field 'albumHref)))
      (let* ((missing? (lambda (r) (and (equal? (site-app-field r 'kind) "track")
                                     (or (equal? (or (site-app-field r 'art) "") "") (equal? (or (site-app-field r 'album) "") "")))))
             (filled (map (lambda (r) (if (missing? r) (plist-put (plist-put r 'art (if (equal? (or (site-app-field r 'art) "") "") art (site-app-field r 'art))) 'album (if (equal? (or (site-app-field r 'album) "") "") album (site-app-field r 'album))) r)) rows)))
        (when (find missing? rows)
          (buffer-set-local! buf 'site-app-rows filled)
          (buffer-set-local! buf 'list-layout-cache #f)
          (list-refresh! buf))))))

(define (spotify--show-playing-row! buf)
  ;; point on the row that plays and its page beside the list; #f when the
  ;; list does not hold it
  (let* ((href (spotify--now-field 'trackHref))
         (row (find (lambda (r) (equal? (site-app-field r 'href) href)) (site-app-rows buf))))
    (when row
      (spotify--goto-playing! buf)
      (with-frame-windows (lambda () (site-app-show-detail! buf row))))
    (and row #t)))

(define (spotify--follow-track!)
  ;; on Now Playing the list and the page beside it follow the music; a
  ;; track from another list reads that list
  (let ((buf (site-app-page-buffer 'spotify 'playing)))
    (when (and (buffer-exists? buf) (member buf (get-visible-buffers)))
      (unless (spotify--show-playing-row! buf)
        (spotify--playing-section! #f)))))

(define (spotify--playing-section! focus?)
  ;; the section pane turns to Now Playing and the pane beside it to the page
  ;; of what plays; the list is read again when the music moved to another
  ;; list, and its fill brings the page. FOCUS? takes the focus there
  (let* ((path (spotify--now-path))
         (buf (spotify--section-ready! 'playing))
         (pane (spotify--section-pane))
         (moved (not (equal? path (buffer-local buf 'spotify-playing-path)))))
    (cond ((equal? path "") (message "Nothing is playing"))
          (else
           (buffer-set-local! buf 'spotify-playing-path path)
           (cond (focus? (spotify--go-section! 'playing))
                 (pane (with-frame-windows (lambda () (window-set-buffer! pane buf)))))
           (if (or moved (null? (site-app-rows buf)))
               (site-app-read-page! 'spotify (site-app-page (site-app-spec 'spotify) 'playing))
               (or (spotify--show-playing-row! buf) (spotify--goto-playing! buf)))))))

(define (spotify--window-of buf)
  (with-frame-windows
    (lambda () (find (lambda (w) (equal? (window-buffer w) buf)) (map car (window-list))))))

(define (spotify--goto-playing! buf)
  ;; point on the track that plays, when the page lists it
  (let* ((title (spotify--now-field 'title))
         (lines (string-split (buffer-text buf) "\n"))
         (at (let walk ((ls lines) (n 1))
               (cond ((null? ls) #f)
                     ((and (> n 1) (string-index (car ls) title)) n)
                     (else (walk (cdr ls) (+ n 1)))))))
    (when (and at (not (equal? title ""))) (buffer-goto-line! buf at))))

(define (spotify--go-section! id)
  ;; a section takes the pane that shows one, and the focus goes there
  (let ((pane (spotify--section-pane)))
    (when pane (select-window! pane))
    (site-app-open! 'spotify id)))

;; what the list played from is called: the page's own name when it is one buffer
;; for every page, else the buffer's
(define (spotify--origin-label buf)
  (let* ((row (and (buffer-exists? buf) (buffer-local buf 'site-app-row)))
         (n (and row (spotify--detail? buf) (site-app-field row 'name))))
    (if (and (string? n) (not (equal? n ""))) n (spotify--origin-name buf))))

(define (spotify--origin-name buf)
  ;; *spotify: Daily Mix 2* as Daily Mix 2
  (let ((parts (string-split buf ": ")))
    (apply string-append (string-split (if (pair? (cdr parts)) (cadr parts) (car parts)) "*"))))

(define (spotify--track-of now) (plist-put now 'position ""))
(define (spotify--position-of now) (list (or (plist-get now 'position) "") (or (plist-get now 'duration) "")))

(define (spotify--quiet-eval code k)
  ;; the player if it is open, else K gets #f: a refresh never opens a tab
  (chrome-call "tabs" '()
    (lambda (r)
      (let* ((hits (filter spotify--tab? (or (plist-get r 'tabs) '())))
             (front (filter (lambda (t) (eq? (plist-get t 'active) #t)) hits))
             (t (cond ((pair? front) (car front)) ((pair? hits) (car (reverse hits))) (else #f))))
        (if t (tab-eval-main t code k) (k #f))))))

(domain! 'spotify)
(effects! '(write external execute))

;; The desktop app plays and the web page browses. The app answers
;; AppleScript at once and with no page to break, so the transport (play,
;; skip, volume, shuffle, repeat) and the read of what plays go to it; what
;; AppleScript cannot do (browse, search, like) stays on the page.

;; the Linux app answers through MPRIS: each control as a playerctl line
;; that says what its AppleScript says
(define spotify--mpris
  (list (list 'playpause "case $(playerctl -p spotify status) in Playing) playerctl -p spotify pause; echo paused;; *) playerctl -p spotify play; echo playing;; esac")
        (list 'next "playerctl -p spotify next && echo next")
        (list 'previous "playerctl -p spotify previous && echo previous")
        (list 'shuffle "case $(playerctl -p spotify shuffle) in On) playerctl -p spotify shuffle Off; echo 'shuffle off';; *) playerctl -p spotify shuffle On; echo 'shuffle on';; esac")
        (list 'repeat "case $(playerctl -p spotify loop) in None) playerctl -p spotify loop Playlist; echo 'repeat on';; *) playerctl -p spotify loop None; echo 'repeat off';; esac")
        (list 'volume-up "playerctl -p spotify volume 0.1+ >/dev/null && printf 'volume %.0f%%' $(playerctl -p spotify volume | awk '{print $1 * 100}')")
        (list 'volume-down "playerctl -p spotify volume 0.1- >/dev/null && printf 'volume %.0f%%' $(playerctl -p spotify volume | awk '{print $1 * 100}')")
        ;; the ten fields of spotify--desktop-now-as, tab between
        (list 'now (string-append
                     "IFS=; T=$(printf '\\t')\n"
                     "m=$(playerctl -p spotify metadata --format '{{lc(status)}}'$T'{{title}}'$T'{{artist}}'$T'{{album}}'$T'{{mpris:trackid}}'$T'{{mpris:artUrl}}'$T'{{duration(position)}}'$T'{{duration(mpris:length)}}') || exit 0\n"
                     "case $(playerctl -p spotify shuffle 2>/dev/null) in On) s=true;; *) s=false;; esac\n"
                     "case $(playerctl -p spotify loop 2>/dev/null) in Track|Playlist) l=true;; *) l=false;; esac\n"
                     "printf '%s\\t%s\\t%s\\n' $m $s $l"))))

(define (spotify--desktop! body k)
  ;; K gets the app's answer, or #f when it is not running or refused us.
  ;; BODY is AppleScript for the Mac, or (APPLESCRIPT LINUX): LINUX is a
  ;; key of spotify--mpris or a shell line, #f where MPRIS cannot do it
  (let* ((as (if (pair? body) (car body) body))
         (linux (and (pair? body) (cadr body)))
         (sh (if (symbol? linux) (cadr (assq linux spotify--mpris)) linux)))
    (shell-command->string
      (string-append "if command -v osascript >/dev/null 2>&1; then osascript -e "
                     (sh-quote (string-append "if application \"Spotify\" is running then\ntell application \"Spotify\"\n"
                                              as "\nend tell\nelse\nreturn \"-off-\"\nend if"))
                     " 2>&1\nelif command -v playerctl >/dev/null 2>&1 && playerctl -p spotify status >/dev/null 2>&1; then\n"
                     (or sh "echo -off-")
                     "\nelse echo -off-\nfi")
      (compos-home)
      (lambda (out)
        (let ((v (string-trim (or out ""))))
          (k (and (not (equal? v "-off-")) (not (string-contains? v "execution error"))
                  (not (string-prefix? "No player" v)) v)))))))

(define (spotify--via! body web k)
  ;; the desktop app where spotify-player allows it and it answers; else WEB
  (if (equal? spotify-player "web")
      (web)
      (spotify--desktop! body
        (lambda (v)
          (cond (v (k v))
                ((equal? spotify-player "desktop") (message "Spotify: the desktop app is not running"))
                (else (web)))))))

(define (spotify--route! body web)
  ;; a control: the app's answer is said, and the bar reads it back
  (spotify--via! body web (lambda (v) (message v) (spotify-now-refresh!))))

(define (spotify--uri href)
  ;; /playlist/ID, or the whole link, as spotify:playlist:ID; #f for a page with no uri
  (let* ((path (car (string-split (or href "") "?")))
         (parts (reverse (filter (lambda (p) (not (equal? p ""))) (string-split path "/")))))
    (and (>= (length parts) 2)
         (member (cadr parts) '("track" "album" "playlist" "artist" "episode" "show"))
         (string-append "spotify:" (cadr parts) ":" (car parts)))))

(define (spotify--mmss expr)
  (string-append "((" expr ") div 60 as string) & \":\" & text -2 thru -1 of (\"0\" & ((" expr ") mod 60 as string))"))

(define spotify--desktop-now-as
  (string-append
    "set t to current track\n"
    "return (player state as string) & tab & (name of t) & tab & (artist of t) & tab & (album of t) & tab & (id of t) & tab & (artwork url of t) & tab & "
    (spotify--mmss "(player position) div 1") " & tab & " (spotify--mmss "(duration of t) div 1000")
    " & tab & (shuffling as string) & tab & (repeating as string)"))

(define (spotify--desktop-now v)
  ;; the app's line as the plist the page's read gives. The heart is the
  ;; page's to know, so it stays while the track does
  (let ((f (string-split v "\t")))
    (and (= (length f) 10)
         (let ((href (or (spotify--path-of-uri (list-ref f 4)) "")))
           (list 'title (list-ref f 1) 'artists (list-ref f 2) 'album (list-ref f 3)
                 'art (list-ref f 5) 'playing (equal? (list-ref f 0) "playing")
                 'position (list-ref f 6) 'duration (list-ref f 7)
                 'albumHref (spotify--track-link href cadr) 'artistHref (spotify--track-link href caddr) 'trackHref href
                 'shuffle (if (equal? (list-ref f 8) "true") "on" "off")
                 'repeat (if (equal? (list-ref f 9) "true") "all" "off")
                 'liked (and (equal? href (plist-get *spotify-now* 'trackHref)) (eq? (plist-get *spotify-now* 'liked) #t))
                 'source "desktop")))))

(define (spotify--path-of-uri uri)
  ;; spotify:track:ID, or the Linux app's /com/spotify/track/ID, as /track/ID
  (let ((p (string-split (or uri "") ":")))
    (cond ((= (length p) 3) (string-append "/" (cadr p) "/" (caddr p)))
          ((string-prefix? "/com/spotify/" (or uri "")) (substring uri 12 (string-length uri)))
          (else #f))))

(define (spotify--track-link href pick)
  (let ((links (spotify--links href)))
    (if links (pick links) "")))

(define (spotify--meta html name)
  ;; the content of <meta name=NAME>, or ""
  (let ((parts (string-split html (string-append "name=\"" name "\" content=\""))))
    (if (pair? (cdr parts)) (car (string-split (cadr parts) "\"")) "")))

(define (spotify--href-of url)
  ;; https://open.spotify.com/artist/ID as /artist/ID
  (let ((parts (string-split url "open.spotify.com")))
    (if (pair? (cdr parts)) (cadr parts) "")))

(define (spotify--track-links! href)
  ;; the desktop app names no album or artist page, so the bio could never
  ;; be read; the track's public page names both
  (let ((key (string-append "links:" href)))
    (when (and (not (equal? href "")) (not (spotify--links href)) (spotify--ask! key))
      (task-run! (lambda () (http-text (string-append "https://open.spotify.com" href)))
        (lambda (ok html)
          (if (and ok (string? html))
              (let ((album (spotify--href-of (spotify--meta html "music:album")))
                    (artist (spotify--href-of (spotify--meta html "music:musician"))))
                (spotify--put! 'links href (list href album artist))
                (when (equal? href (plist-get *spotify-now* 'trackHref))
                  (spotify--now-set! (plist-put (plist-put *spotify-now* 'albumHref album) 'artistHref artist)))
                (spotify--redraw-artist-tabs!))
              (set! *spotify-asked* (spotify--without key *spotify-asked*))))
        15000))))

(define (spotify--now-take! now k)
  (when (and (pair? now) (not (equal? now *spotify-now*)))
    (spotify--now-set! now))
  (when (and (pair? now) (equal? (plist-get now 'albumHref) ""))
    (spotify--track-links! (or (plist-get now 'trackHref) "")))
  (when k (k now)))

(define (spotify-now-refresh! &optional k)
  (spotify--via! (list spotify--desktop-now-as 'now)
    (lambda ()
      (spotify--quiet-eval spotify--now-json-js
        (lambda (v)
          (spotify--now-take! (and (string? v) (> (string-length v) 1) (json-parse v)) k))))
    (lambda (v) (spotify--now-take! (spotify--desktop-now v) k))))

(define (spotify--desktop-play! uri context what web)
  ;; the app plays a uri, in its list when there is one; WEB when it cannot
  (let ((origin (current-buffer))
        (path (spotify--path-of-uri (or context uri))))
  (spotify--via! (list (string-append "play track " (json-encode uri)
                                      (if context (string-append " in context " (json-encode context)) "")
                                      "\nreturn \"playing\"")
                     ;; MPRIS opens a track, not a track in its list
                     (and (not context) (string-append "playerctl -p spotify open " (sh-quote uri) " && echo playing")))
    web
    (lambda (v)
      (when path (set! *spotify-origin* (list path origin (spotify--origin-label origin))))
      (message (string-append "Playing " what))
      (spotify--now-set! (plist-put *spotify-now* 'playing #t))
      (spotify-now-refresh!)))))

(effects! '(write external))

;; Spotify cannot tell the editor its track changed, so while a section is on
;; screen the bar reads the player every few seconds, and stops when none is.
(defcustom 'spotify-now-seconds 5
  "Seconds between two reads of the player while a Spotify section is on screen." 'group 'spotify)

(define *spotify-ticking* #f)

(define (spotify--shown?)
  ;; a section or one of its pages is on screen
  (let ((shown (get-visible-buffers)))
    (pair? (filter (lambda (b) (or (member b (spotify--list-buffers)) (spotify--detail? b))) shown))))

(define (spotify--tick! ignored)
  ;; the timer fires on the UI lane. The read and the redraw run on the
  ;; player's own lane, so a slow answer does not hold a key
  (run-on-lane! 'spotify spotify--read-player!))

(define (spotify--read-player!)
  ;; a shown app reads the player; a hidden one only looks every two seconds
  ;; whether it shows again, so coming back finds the music where it is. A
  ;; player that never answers is asked again by the watchdog. The flag
  ;; stays set for the whole read: the redraw draws the list head, and a
  ;; head that saw it clear started a second loop at half a second
  (set! *spotify-ticking* #t)
  (if (spotify--shown?)
      (begin
        (debounce! 'spotify-now-watchdog (* 3000 spotify-now-seconds)
          (lambda (ignored) (set! *spotify-ticking* #f) (spotify--ticker-start!)) #f)
        (spotify-now-refresh!
          (lambda (now)
            (debounce! 'spotify-now (* 1000 spotify-now-seconds) spotify--tick! #f))))
      (debounce! 'spotify-now 2000 spotify--tick! #f)))

(define (spotify--ticker-start!)
  (unless *spotify-ticking*
    (set! *spotify-ticking* #t)
    (debounce! 'spotify-now 500 spotify--tick! #f)))

(define (spotify--context-props)
  ;; the list that plays, as a tile: what kind it is, its name and cover
  (let* ((path (spotify--now-path))
         (o *spotify-origin*)
         (album? (equal? path (spotify--now-field 'albumHref)))
         (kind (cond ((string-prefix? "/album/" path) "Album") ((string-prefix? "/playlist/" path) "Playlist")
                     ((string-prefix? "/artist/" path) "Artist") ((string-prefix? "/collection/tracks" path) "Liked Songs")
                     (else "")))
         (from (and o (equal? path (car o)) (cadr o)))
         (name (cond (album? (spotify--now-field 'album))
                     ((equal? kind "Liked Songs") "Liked Songs")
                     ((and from o (pair? (cddr o)) (not (equal? (caddr o) ""))) (caddr o))
                     (else ""))))
    (list 'kind (if (equal? kind "") "queue" kind) 'name name
          'art (spotify--now-field 'art)
          'sub (if album? (spotify--now-field 'artists) ""))))

(define (spotify--context-line)
  ;; where the music plays from, in a few words
  (let* ((c (spotify--context-props))
         (kind (plist-get c 'kind))
         (name (plist-get c 'name)))
    (cond ((equal? (spotify--now-field 'title) "") "")
          ((and (equal? kind "Album") (equal? name (spotify--now-field 'album))) "Playing the album")
          ((equal? kind "Liked Songs") "Playing Liked Songs")
          ((equal? name "") (string-append "Playing from " (string-downcase kind)))
          (else (string-append "Playing from " (string-downcase kind) ": " name)))))

(define (spotify--now-props)
  (let ((n *spotify-now*))
    (list 'title (or (plist-get n 'title) "") 'artists (or (plist-get n 'artists) "") 'album (or (plist-get n 'album) "") 'from (spotify--context-line)
          'art (or (plist-get n 'art) "") 'playing? (eq? (plist-get n 'playing) #t)
          'liked? (eq? (plist-get n 'liked) #t)
          'following (let ((v (spotify--following (or (plist-get n 'artistHref) "")))) (cond ((eq? v #t) "yes") ((eq? v #f) "no") (else "")))
          'position (or (plist-get n 'position) "") 'duration (or (plist-get n 'duration) "")
          'shuffle (or (plist-get n 'shuffle) "off") 'repeat (or (plist-get n 'repeat) "off"))))

(define (spotify--loaded?)
  (let ((title (plist-get *spotify-now* 'title)))
    (and (string? title) (not (equal? title "")))))

(define (spotify--playing? name)
  (let ((title (plist-get *spotify-now* 'title)))
    (and (string? title) (not (equal? title "")) (equal? title name))))

;; A control answers in words, and the bar follows. What the click certainly
;; changed (FLIP, a key of the bar) is drawn at once; the rest is read back.
(define (spotify--control! code flip)
  (spotify--eval code
    (lambda (v)
      (message (if (string? v) v "Spotify: no answer"))
      (if flip
          (spotify--now-set! (plist-put *spotify-now* flip (not (eq? (plist-get *spotify-now* flip) #t))))
          (spotify-now-refresh!)))))

;;; --- playing a row ------------------------------------------------------------
;;; The player opens the page the row came from and presses its button there,
;;; so a liked song plays on through your likes and an album through the album.

(define (spotify--path url)
  (let ((base "https://open.spotify.com"))
    (if (and (string? url) (string-prefix? base url)) (substring url (string-length base) (string-length url)) url)))

(define spotify--entity-play "main [data-testid=play-button]")

(define (spotify--play-js path selector)
  ;; In place, no reload: the player's router follows a pushed history entry,
  ;; and an observer presses the button the moment the new page draws it. A
  ;; button still on the old page does not count. The promise answers once
  ;; it pressed, or '' after ten seconds
  (string-append
    "new Promise(function(done){var path=" (json-encode path) ",sel=" (json-encode selector) ";"
    "var moving=location.pathname!==path,old=moving?document.querySelector('main section'):null;"
    "var go=function(){var b=Array.from(document.querySelectorAll(sel)).filter(function(e){return !(old&&old.isConnected&&old.contains(e))})[0];"
    "if(b){b.click();done('playing');return true}return false};"
    "if(moving){history.pushState({},'',path);dispatchEvent(new PopStateEvent('popstate',{state:{}}))}"
    "if(go())return;"
    "var t,obs=new MutationObserver(function(){if(go()){obs.disconnect();clearTimeout(t)}});"
    "obs.observe(document.body,{subtree:true,childList:true,attributes:true});"
    "t=setTimeout(function(){obs.disconnect();done('')},10000);})"))

(define (spotify--play! path selector what)
  ;; a page plays in the desktop app; a row the page alone knows, on the page
  (let ((uri (and (equal? selector spotify--entity-play) (spotify--uri path))))
    (if uri
        (spotify--desktop-play! uri #f what (lambda () (spotify--play-web! path selector what)))
        (spotify--play-web! path selector what))))

(define (spotify--play-web! path selector what)
  ;; Chrome gives sound only to a page a person has pressed, and b.click()
  ;; is not a person; a real mouse click never reaches the hidden tab. The
  ;; debugger's userGesture makes the press count as the person's
  (let ((origin (current-buffer)))
    (spotify-tab
      (lambda (t)
        (tab-cdp t "Runtime.evaluate"
          (list 'expression (spotify--play-js path selector)
                'userGesture #t 'awaitPromise #t 'returnByValue #t)
          (lambda (r)
            (if (equal? (plist-get (plist-get (plist-get r 'result) 'result) 'value) "playing")
                (begin
                  (set! *spotify-origin* (list path origin (spotify--origin-label origin)))
                  (message (string-append "Playing " what))
                  ;; the bar shows it playing at once; the next read names the track
                  (spotify--now-set! (plist-put *spotify-now* 'playing #t)))
                (message (string-append "Spotify: the player did not answer for " what)))))))))

(define (spotify--section-path page)
  (let ((path (plist-get page 'path))) (if (procedure? path) (path) path)))

(define (spotify--play-track! context label href name)
  ;; in its list when the row carries its button's label, else on its own page.
  ;; A JSON string is a CSS string too, quotes and backslashes escaped
  (let ((uri (spotify--uri href))
        (web (lambda ()
               (if (and (string? label) (string-prefix? "Play " label))
                   (spotify--play-web! context (string-append "main button[aria-label=" (json-encode label) "]") name)
                   (spotify--play-web! href spotify--entity-play name)))))
    (if uri (spotify--desktop-play! uri (spotify--uri context) name web) (web))))

(define (spotify--play-row! buf row)
  (let ((name (site-app-field row 'name)))
    (if (equal? (site-app-field row 'kind) "track")
        (spotify--play-track! (spotify--section-path (site-app-current-page buf))
                              (site-app-field row 'play) (site-app-field row 'href) name)
        (spotify--play! (site-app-field row 'href) spotify--entity-play name))))

(define *spotify-now-title* "Now Playing")
(define *spotify-now-detail* (string-append "*spotify: " *spotify-now-title* "*"))

(define (spotify--now-row? row)
  (let ((href (spotify--now-field 'trackHref)))
    (and (not (equal? href "")) (equal? (site-app-field row 'href) href))))

;; the page of what plays: one buffer, drawn again for each track
(register-minor-mode! "spotify-now-mode" (lambda (buf) #t) (lambda (buf) #t))
(mode-doc! "spotify-now-mode" "The page of the track that plays. It is one page: when the music moves on, it draws the next track in place.")

(define (spotify--now-minor!)
  (when (equal? (current-buffer) *spotify-now-detail*)
    (unless (minor-mode-on? (current-buffer) "spotify-now-mode")
      (enable-minor-mode! (current-buffer) "spotify-now-mode"))))

(define (spotify--detail? buf)
  (and (eq? (buffer-local buf 'site-app-name) 'spotify) (buffer-local buf 'site-app-row) #t))

(define (spotify--card-title node)
  (let ((kids (site-app-real (plist-get node 'children))))
    (if (pair? kids) (or (plist-get (car kids) 'text) "") "")))

(define (spotify--play-here! buf)
  ;; on an item's page: the track or tile at point, else the page itself
  (let* ((row (buffer-local buf 'site-app-row))
         (page-href (site-app-field row 'href))
         (node (site-app-card-at buf))
         (class (and node (plist-get node 'class))))
    (cond ((equal? class "sp-track")
           (spotify--play-track! page-href (plist-get node 'play) (plist-get node 'href) (spotify--card-title node)))
          ((equal? class "sp-tile")
           (spotify--play! (plist-get node 'href) spotify--entity-play (spotify--card-title node)))
          (else (spotify--play! page-href spotify--entity-play (site-app-field row 'name))))))

;;; --- reading pages fast -------------------------------------------------------
;;; A plain fetch of the player gets an empty shell: the page draws itself in
;;; JavaScript. So pages are read in the hidden reader tab, and a full load of
;;; the player there costs seconds. Instead the reader keeps the player running
;;; and moves inside it the way a click on a link does, then hands back the
;;; page once rows or cards the old page did not have have drawn: ~0.1-1s.
;;; One read at a time, in order; a reader not on the player yet, or a move
;;; that fails, falls back to a full load.

(domain! 'web)
(effects! '(read external))

(define (spotify--move-js id path wait)
  ;; a hidden button whose click moves the player to PATH and, when the new
  ;; page has drawn, leaves a mark for tab-press to wait on
  (string-append
    "(function(){var id=" (json-encode id) ",path=" (json-encode path) ",wait=" (json-encode wait) ";"
    "var old=document.getElementById('compos-go-'+id);if(old)old.remove();"
    "var b=document.createElement('button');b.id='compos-go-'+id;b.style.display='none';"
    "b.onclick=function(){"
    "var all=function(){return Array.from(document.querySelectorAll(wait))};"
    "var text=function(){return all().map(function(e){return e.innerText}).join('|')};"
    "var moving=location.pathname!==path;var seen=new Set(moving?all():[]);var before=moving?text():null;"
    "var mark=function(){if(document.getElementById('compos-ready-'+id))return;var i=document.createElement('i');i.id='compos-ready-'+id;i.hidden=true;document.body.appendChild(i)};"
    "var kind=(path.match(/^\\/(album|artist|playlist|track)\\//)||[])[1];"
    "var page=kind?document.querySelector('main [data-testid='+kind+'-page]'):true;"
    "var ready=function(){if(location.pathname!==path)return false;"
    "if(kind){var p=document.querySelector('main [data-testid='+kind+'-page]');if(!p||(moving&&p===page&&text()===before))return false}"
    "var es=all();if(!es.length)return false;"
    "return !moving||es.some(function(e){return !seen.has(e)})||text()!==before};"
    "if(moving){history.pushState({},'',path);dispatchEvent(new PopStateEvent('popstate',{state:{}}))}"
    "if(ready()){mark();return}"
    "var obs=new MutationObserver(function(){if(ready()){obs.disconnect();setTimeout(mark,150)}});"
    "obs.observe(document.body,{subtree:true,childList:true,characterData:true});"
    "setTimeout(function(){obs.disconnect();mark()},9000)};"
    "document.body.appendChild(b);return 'armed';})()"))

(define *spotify-moves* 0)
(define *spotify-move-queue* '())
(define *spotify-moving* #f)

(define *spotify-move-epoch* 0)   ; which job is running; a reply of an older one is dropped
(define *spotify-move-k* #f)     ; the running job's K, so a stalled one can be answered
(define spotify--move-seconds 30)

(define (spotify--move-stalled! epoch)
  ;; the browser never answered the running job (a tab closed, discarded or
  ;; wedged, a reply lost): answer it with nothing and go on, so one lost
  ;; reply cannot stop every read behind it
  (when (and *spotify-moving* (= epoch *spotify-move-epoch*))
    (let ((k *spotify-move-k*))
      (set! *spotify-move-k* #f)
      (spotify--move-next!)
      (when k (k #f #f)))))

(define (spotify--move-next!)
  (set! *spotify-move-epoch* (+ *spotify-move-epoch* 1))
  (if (null? *spotify-move-queue*)
      (set! *spotify-moving* #f)
      (let ((job (car *spotify-move-queue*)))
        (set! *spotify-move-queue* (cdr *spotify-move-queue*))
        (set! *spotify-moving* #t)
        (debounce! 'spotify-move-dog (* 1000 spotify--move-seconds) spotify--move-stalled! *spotify-move-epoch*)
        (job))))

(define (spotify--embed-tracks path)
  ;; every track of a playlist or album, from its embed page: the web page draws
  ;; only the rows on screen, and a hidden tab draws no more however it scrolls
  (let* ((html (http-text (string-append "https://open.spotify.com/embed" path)))
         (parts (and (string? html) (string-split html "id=\"__NEXT_DATA__\" type=\"application/json\">")))
         (data (and parts (pair? (cdr parts)) (json-parse (car (string-split (cadr parts) "</script>")))))
         (tracks (let dig ((v data) (ks '(props pageProps state data entity trackList)))
                   (if (or (null? ks) (not (pair? v))) v (dig (plist-get v (car ks)) (cdr ks))))))
    (if (pair? tracks) tracks '())))

(define (spotify--mmss ms)
  (let* ((s (quotient (if (integer? ms) ms 0) 1000)) (r (remainder s 60)))
    (string-append (number->string (quotient s 60)) ":" (if (< r 10) "0" "") (number->string r))))

(define (spotify--rows-drawn html)
  (- (length (string-split html "data-testid=\"tracklist-row\"")) 1))

(define (spotify--rows-total html)
  ;; the rows the page's grid says it holds, its head row aside; 0 when it names none
  (let ((p (string-split html "aria-rowcount=\"")))
    (if (pair? (cdr p))
        (let ((n (string->number (car (string-split (cadr p) "\""))))) (if n (- n 1) 0))
        0)))

(define (spotify--with-all-rows html tracks)
  ;; HTML with a row, as the page draws one, for each of TRACKS it left out. They
  ;; go after its last row, before the shelves under the list
  (let* ((rows (let loop ((ts tracks) (i 1) (acc '()))
                 (if (null? ts)
                     (apply string-append (reverse acc))
                     (let* ((t (car ts))
                            (href (or (spotify--path-of-uri (plist-get t 'uri)) ""))
                            (n (number->string i)))
                       (loop (cdr ts) (+ i 1)
                             (if (or (not (string-prefix? "/track/" href)) (string-index html (string-append "href=\"" href "\"")))
                                 acc
                                 (cons (string-append "<div role=\"row\" aria-rowindex=\"" n "\"><div data-testid=\"tracklist-row\">"
                                                      "<div role=\"gridcell\"><span>" n "</span></div>"
                                                      "<div role=\"gridcell\"><a href=\"" href "\">" (html-escape (plist-get t 'title)) "</a>"
                                                      "<a href=\"/artist/\">" (html-escape (plist-get t 'subtitle)) "</a></div>"
                                                      "<div role=\"gridcell\"><span data-encore-id=\"text\">" (spotify--mmss (plist-get t 'duration)) "</span></div>"
                                                      "</div></div>")
                                       acc)))))))
         (mark "data-testid=\"tracklist-row\"")
         (parts (string-split html mark))
         (head (string-join (reverse (cdr (reverse parts))) mark))
         (tail (car (reverse parts)))
         (secs (string-split tail "<section"))
         (shelf (let loop ((ss (cdr secs)) (before (car secs)))
                  (cond ((null? ss) #f)
                        ((string-index (car ss) "data-testid=\"component-shelf\"") (list before (string-join ss "<section")))
                        (else (loop (cdr ss) (string-append before "<section" (car ss)))))))
         (tail (if shelf
                   (string-append (car shelf) rows "<section" (cadr shelf))
                   (let ((m (string-split tail "</main>")))
                     (if (pair? (cdr m)) (string-append (car m) rows "</main>" (string-join (cdr m) "</main>")) (string-append tail rows))))))
    (if (null? (cdr parts)) html (string-append head mark tail))))

(define (spotify--fill-rows path html k)
  ;; K gets HTML with the rows a playlist or album page did not draw
  (if (and (or (string-prefix? "/playlist/" path) (string-prefix? "/album/" path))
           (> (spotify--rows-total html) (spotify--rows-drawn html)))
      ;; all of it in the task, so a page that would not fill still reaches K as it was
      (task-run! (lambda () (let ((tracks (spotify--embed-tracks path)))
                              (if (pair? tracks) (spotify--with-all-rows html tracks) html)))
        (lambda (ok filled) (k (if (and ok (string? filled)) filled html)))
        15000)
      (k html)))

(define (spotify-navigate! name url wait k)
  ;; site-app's 'navigate for Spotify: K gets (TAB ANSWER) as a full load gives
  (set! *spotify-move-queue*
    (append *spotify-move-queue*
      (list (lambda ()
              (let ((finish (lambda (tab answer) (k tab answer) (spotify--move-next!)))
                    (full (lambda () (site-app-navigate-direct! name url wait
                                       (lambda (tab answer) (k tab answer) (spotify--move-next!))))))
                (site-app-find-tab! name
                  (lambda (tab)
                    (set! *spotify-moves* (+ *spotify-moves* 1))
                    (let ((id (number->string *spotify-moves*)))
                      (tab-eval-main tab (spotify--move-js id (spotify--path url) (or wait spotify--wait))
                        (lambda (armed)
                          (if (not (equal? armed "armed"))
                              (full)
                              (tab-press tab (string-append "#compos-go-" id)
                                (lambda (html)
                                  (if html
                                      (spotify--fill-rows (spotify--path url) html
                                        (lambda (html) (finish tab (list 'tab tab 'url url 'html html))))
                                      (full)))
                                (string-append "#compos-ready-" id)))))))))))))
  (unless *spotify-moving* (spotify--move-next!)))

;;; --- the cache ----------------------------------------------------------------
;;; Every search's albums and every release date are kept, here and on disk,
;;; so a search asked before shows at once, after a restart too. g reads again.
;;; So is all that a page around the music read: artists, albums, news,
;;; briefs, what to hear next, liner notes, the tracks' links and covers.

(define (spotify--cache-touch!) (site-app-cache-touch! 'spotify))

(define (spotify--search-keep! buf rows)
  ;; site-app's after-fill on the Search section: keep what this query found
  (when (and (pair? rows) (not (equal? *spotify-query* "")))
    (spotify--put! 'searches *spotify-query* rows)))

;;; --- imenu --------------------------------------------------------------------

;; M-g i on a section: every row a stop, and the highlight landing on one
;; shows its page beside the list, as the arrows do. Each section read is a
;; tab, ← and → walk them. Home's rows sit on shelves: each shelf is an entry
;; with its rows under it, taken by M-1, M-2, ...

(domain! 'navigation)
(effects! '(read))

;; Spotify runs a shelf's blurb into its title: "Non-stop music … . Recommended Stations"
(define (spotify--shelf-title shelf)
  (car (reverse (string-split shelf ". "))))

;; the shelves' keys in order: 1 to 9, 0, then the letters
(define (spotify--imenu-key i)
  (cond ((< i 9) (number->string (+ i 1)))
        ((= i 9) "0")
        ((< i 36) (substring "abcdefghijklmnopqrstuvwxyz" (- i 10) (- i 9)))
        (else #f)))

(define (spotify--row-shelf row)
  (let ((s (site-app-field row 'shelf))) (and (string? s) (not (equal? s "")) s)))

(define (spotify--imenu-show! buf)
  ;; BUF takes the pane that shows a section; the focus stays where it is
  (let ((pane (spotify--section-pane)))
    (when (and pane (not (equal? (with-frame-windows (lambda () (window-buffer pane))) buf)))
      (with-frame-windows (lambda () (window-display! (lambda () (display-buffer-in-window! pane buf))))))))

(define (spotify--imenu-visit buf line &optional from from-line)
  ;; the row at LINE of section BUF current, and its page beside the list. A row
  ;; of another section puts back the line imenu took in FROM, the one it was asked in
  (lambda ()
    (when from (buffer-goto-line! from from-line))
    (spotify--imenu-show! buf)
    (buffer-goto-line! buf line)
    (list-update-selection! buf)
    (list-preview! buf)))

(define (spotify--section-imenu-rows buf label from from-line)
  ;; the rows of one section, all of kind LABEL so the section is a tab of imenu.
  ;; Each drawn row (an anchor) is paired with the shelf of the row it draws
  (let* ((paired (let pair ((as (anchor-list buf)) (rs (site-app-rows buf)) (out '()))
                   (if (null? as)
                       (reverse out)
                       (let ((tail (let find ((r rs))
                                     (cond ((null? r) #f)
                                           ((equal? (site-app-field (car r) 'name) (anchor-name (car as))) r)
                                           (else (find (cdr r)))))))
                         (pair (cdr as) (if tail (cdr tail) rs)
                               (cons (list (car as) (and tail (spotify--row-shelf (car tail)))) out)))))))
    (let loop ((ps paired) (shelf #f) (n 0) (out '()))
      (if (null? ps)
          (reverse out)
          (let* ((a (car (car ps)))
                 (s (cadr (car ps)))
                 (line (with-current-buffer buf (lambda () (line-number-at-pos (anchor-start a)))))
                 (data (or (anchor-data a) '()))
                 (new? (and s (not (equal? s shelf))))
                 (title (and s (spotify--shelf-title s)))
                 (go (spotify--imenu-visit buf line from from-line))
                 (out (if new? (cons (list line label title s go "" (spotify--imenu-key n)) out) out))
                 ;; a row on a shelf nests under it
                 (row (list line label (string-append (if s "   " "") (anchor-name a))
                            (or (plist-get data 'doc) "") go (or title "") #f)))
            (loop (cdr ps) (or s shelf) (if new? (+ n 1) n) (cons row out)))))))

(define (spotify-list-imenu-rows src)
  ;; every section read so far is a tab, in the app's order; ← and → walk them
  (let ((line (car (buffer-line-at-point src))))
    (apply append
           (map (lambda (page)
                  (let ((b (site-app-page-buffer 'spotify (plist-get page 'id))))
                    (if (and (buffer-exists? b) (pair? (anchor-list b)))
                        (spotify--section-imenu-rows b (plist-get page 'label) (if (equal? b src) #f src) line)
                        '())))
                (site-app-pages (site-app-spec 'spotify))))))

(define (spotify-list-imenu-snapshot buf)
  ;; what imenu puts back when it is cancelled: the section, its row, and the row's page beside it
  (spotify--imenu-visit buf (car (buffer-line-at-point buf))))

(define (spotify--imenu! buf)
  ;; imenu opens on the tab of the section it is asked in
  (buffer-set-local! buf 'anchor-imenu-index 'spotify-list-imenu-rows)
  (buffer-set-local! buf 'imenu-snapshot 'spotify-list-imenu-snapshot)
  (buffer-set-local! buf 'imenu-tab
    (plist-get (site-app-page (site-app-spec 'spotify) (buffer-local buf 'site-app-page)) 'label)))

;;; --- the app ------------------------------------------------------------------

(domain! 'web)
(effects! '(write external display))

(define *spotify-rows-sheet* (locate-library "web/parsers/spotify-rows.xsl"))
(define *spotify-detail-sheet* (locate-library "web/parsers/spotify-detail.xsl"))
(define *spotify-artist-sheet* (locate-library "web/parsers/spotify-artist.xsl"))

;; what a page shows once it has drawn: its track rows, or its cards
(define spotify--wait "main [data-testid=tracklist-row], main [data-encore-id=card]")

(define *spotify-query* "")

(define (spotify--row-cover row)
  ;; Spotify draws its equaliser over the cover of the row that plays, and
  ;; the page read takes that as the art: the player's cover stands in, and
  ;; stays known for the row once the music moves on
  (let ((art (or (site-app-field row 'art) ""))
        (href (or (site-app-field row 'href) "")))
    (cond ((not (string-index art "equaliser")) art)
          ((equal? href (spotify--now-field 'trackHref))
           (let ((now (spotify--now-field 'art)))
             (unless (or (equal? now "") (site-app-cache-has? 'spotify 'covers href))
               (spotify--put! 'covers href now))
             now))
          (else (or (spotify--get 'covers href) "")))))

(define (spotify--row buf row)
  ;; a list row is a row, not a fold: the card's fold marker stays off it
  (let* ((f (lambda (k) (site-app-field row k)))
         ;; a card has a shelf, even a song's (a music video); a track row has none
         (block (if (and (equal? (f 'kind) "track") (not (plist-get row 'shelf)))
                    (component 'spotify/track
                      (list 'title (f 'name) 'icon (spotify--row-cover row) 'badge (f 'index) 'artists (f 'artists)
                            'album (f 'album) 'duration (f 'duration) 'playing? (spotify--playing? (f 'name))
                            'released (or (spotify--date-of (f 'href)) "")))
                    (component 'spotify/tile
                      (list 'title (f 'name) 'icon (f 'art) 'badge (f 'kind) 'tags (list (f 'sub))
                            'released (or (and (equal? (f 'kind) "album") (spotify--date-of (f 'href))) ""))))))
    (let strip ((ps block) (acc '()))
      (cond ((or (null? ps) (null? (cdr ps))) (reverse acc))
            ((eq? (car ps) 'anchor-data) (strip (cddr ps) acc))
            (else (strip (cddr ps) (cons (cadr ps) (cons (car ps) acc))))))))

(define (spotify--cards section)
  (plist-put section 'columns (list (list 'label "title" 'width 34 'field 'name)
                                    (list 'label "details" 'width 40 'field 'sub 'face "dim")
                                    (list 'label "kind" 'width 9 'field 'kind 'face "dim"))))

(define (spotify--section id label key path wait)
  (list 'id id 'label label 'key key 'path path
        'live #t 'wait wait
        'after-fill (lambda (buf rows) (spotify--imenu! buf))
        'sheet *spotify-rows-sheet*
        'detail-sheet *spotify-detail-sheet*
        'detail-wait spotify--wait
        'row (lambda (buf row) (spotify--row buf row))
        'columns (list (list 'label "#" 'width 3 'field 'index 'face "dim")
                       (list 'label "title" 'width 34 'field 'name)
                       (list 'label "by" 'width 26 'field 'artists 'face "dim")
                       (list 'label "kind" 'width 9 'field 'kind 'face "dim")
                       (list 'label "time" 'width #f 'field 'duration 'face "dim"))))

(define (spotify--search-category)
  ;; a search is for albums
  "albums")

(define (spotify--define-app!)
 (define-site-app
  (list 'name 'spotify
        'title "Spotify"
        'base-url "https://open.spotify.com"
        'home "/"
        'home-page 'home
        'detail-mode "spotify-detail-mode"
        ;; Spotify lives in a group of its own when spotify-own-group says so
        'own-group spotify-own-group
        ;; one tab plays and reads; a Spotify tab already open is that tab
        'adopt #t
        ;; a page whose inputs are as they were at its last draw is not drawn again
        'drawn-same? (lambda (buf row) (spotify--same-inputs? (spotify--tab-inputs buf row) (buffer-local buf 'sp-drawn)))
        'drawn! (lambda (buf) (buffer-set-local! buf 'sp-drawn (spotify--tab-inputs buf)))
        ;; a track's or album's page does not change by the minute: what it read stands for an hour
        'fresh-ms 3600000
        ;; pages are read by moving the running player, not by loading it again
        'navigate (lambda (name url wait k) (spotify-navigate! name url wait k))
        ;; what plays has one page, which follows the music
        ;; one detail buffer for each section; what it read of other rows stays in the app's cache
        'detail-buffer (lambda (row)
                           (let ((p (site-app-field row 'detail-page)))
                             (cond ((equal? p "home") "Home") ((equal? p "liked") "Liked Songs")
                                   ((equal? p "playlists") "Playlists") ((equal? p "results") "Search")
                                   (else *spotify-now-title*))))
        'detail-name (lambda (row) (if (spotify--now-row? row) *spotify-now-title* (site-app-field row 'name)))
        ;; the player bar heads every section
        'list-head (lambda (buf)
                     (spotify--ticker-start!)
                     (list (component 'spotify/search-bar (list 'query *spotify-query*))
                           (component 'spotify/now-playing (spotify--now-props))))
        ;; on an item's page: a track plays, a tile opens beside the list
        'card-keys (list (list "sp-track" (list (list "RET" "spotify-play" "play") (list "p" "spotify-play" "play")))
                         (list "sp-tile" (list (list "RET" "spotify-open" "open") (list "p" "spotify-play" "play"))))
        'pages
        (list ;; Now Playing is the list that plays, on the track that plays
              (append (list 'shortcut "N" 'after-fill (lambda (buf rows) (spotify--imenu! buf) (spotify--fill-covers! buf rows) (or (spotify--show-playing-row! buf) (spotify--goto-playing! buf)))
                            'detail-composed (list *spotify-ambient-tab* *spotify-artist-tab* *spotify-album-tab*) 'detail-default "ambient"
                            ;; a track row holds what the artist and album tabs need; an album row
                            ;; holds only its name, so its page is read for its tracks and artist
                            'detail-lazy (lambda (row) (string-prefix? "/track/" (or (site-app-field row 'href) "")))
                            'detail-count-from-one #t)
                      (spotify--section 'playing "Now Playing" "0"
                        (lambda () (let ((p (spotify--now-path))) (if (equal? p "") "/collection/tracks" p)))
                        "main [data-testid=tracklist-row]"))
              (plist-put (spotify--section 'home "Home" "1" "/" "main [data-encore-id=card]") 'shortcut "H")
              (plist-put (spotify--section 'liked "Liked Songs" "2" "/collection/tracks" "main [data-testid=tracklist-row]") 'shortcut "L")
              (plist-put (spotify--cards (spotify--section 'playlists "Playlists" "3"
                                (lambda () (if (equal? spotify-user "") "/" (string-append "/user/" spotify-user "/playlists")))
                                "main [data-encore-id=card]")) 'shortcut "P")
              ;; a search reads Spotify's albums page for the query, which draws whole
              (append (list 'shortcut "/" 'after-fill (lambda (buf rows) (spotify--imenu! buf) (spotify--search-keep! buf rows)))
              (spotify--section 'results "Search" "4"
                                (lambda () (string-append "/search/" (url-encode *spotify-query*)
                                                          "/" (spotify--search-category)))
                                "main [data-encore-id=card]")))))
 (spotify--bind-keys!))

;; a control in the player bar is clicked as spotify:COMMAND
(add-hook! (list 'block-click 'spotify)
  (lambda (buf id)
    (if (and (string? id) (string-prefix? "spotify:" id))
        (begin (run-command (substring id 8 (string-length id))) #t)
        #f)))

;;; --- commands -----------------------------------------------------------------

;;;###autoload
(define-command "spotify" "Open Spotify as an app: Home, Liked Songs, Playlists and Search, laid out by role"
  (lambda ()
    ;; Home is made ready, not shown where you stand: the app's windows join
    ;; the ones on screen, its lists, its pages and its player each in its
    ;; own, and the layout fits them. Every call brings that back.
    (let ((spec (site-app-spec 'spotify)))
      (when (plist-get spec 'own-group)
        (frame-tab! (app-group (or (plist-get spec 'title) "Spotify"))))
      (let ((home (spotify--section-ready! 'home)))
        (when (null? (site-app-rows home))
          (site-app-find-tab! 'spotify
            (lambda (tab) (site-app-read-page! 'spotify (site-app-page spec 'home)))))
        (app-layout! "spotify")
        (let ((win (app-window-of home)))
          (when (and win (window-buffer win)) (select-window! win)))
        (spotify-now-refresh!)))))

(define-command "spotify-play" "Play the row, track or page at point in your Spotify tab"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (spotify--detail? buf)
          (spotify--play-here! buf)
          (let ((row (list-current buf)))
            (if row (spotify--play-row! buf row) (message "No row here")))))))

(define-command "spotify-open" "Open the playlist, album or artist at point beside the list"
  (lambda ()
    (let* ((buf (current-buffer))
           (node (site-app-card-at buf))
           (href (and node (plist-get node 'href)))
           (list-buf (buffer-local buf 'site-app-list)))
      (if (and href list-buf (buffer-exists? list-buf))
          (site-app-show-detail! list-buf (list 'key href 'href href 'name (spotify--card-title node) 'kind (plist-get node 'tier)))
          (message "Nothing to open here")))))

;;;###autoload
(define-command "spotify-play-pause" "Play or pause the Spotify tab"
  (lambda () (spotify--route! (list "playpause\nreturn player state as string" 'playpause)
                (lambda () (spotify--control! (spotify--click-js "control-button-playpause" "play/pause") 'playing)))))

(define-command "spotify-next" "Play the next track"
  (lambda () (spotify--route! (list "next track\nreturn \"next\"" 'next)
                (lambda () (spotify--control! (spotify--click-js "control-button-skip-forward" "next") #f)))))

(define-command "spotify-previous" "Play the previous track"
  (lambda () (spotify--route! (list "previous track\nreturn \"previous\"" 'previous)
                (lambda () (spotify--control! (spotify--click-js "control-button-skip-back" "previous") #f)))))

(define spotify--shuffle-js
  "(function(){var b=Array.from(document.querySelectorAll('[data-testid=player-controls] button')).filter(function(e){return /shuffle/i.test(e.getAttribute('aria-label')||'')})[0];if(!b)return 'no shuffle button — is the tab loaded?';var st=b.getAttribute('aria-disabled')==='true'?'off':(function(l){return /^enable/i.test(l)?'off':/smart/i.test(l)?'smart':(/^disable/i.test(l)||!/subdued/.test(b.className))?'on':'off'})(b.getAttribute('aria-label')||'');b.click();return st==='off'?'shuffle on':'shuffle off'})()")

(define spotify--repeat-js
  "(function(){var b=document.querySelector('[data-testid=control-button-repeat]');if(!b)return 'no repeat button — is the tab loaded?';var c=b.getAttribute('aria-checked');b.click();return c==='false'?'repeat all':(c==='true'?'repeat one':'repeat off')})()")

(define-command "spotify-shuffle" "Shuffle on or off (smart shuffle too, where Spotify offers it)"
  (lambda () (spotify--route! (list "set shuffling to not shuffling\nif shuffling then return \"shuffle on\"\nreturn \"shuffle off\"" 'shuffle)
                (lambda () (spotify--control! spotify--shuffle-js #f)))))

(define-command "spotify-repeat" "Repeat: off, then the whole list, then the one track"
  (lambda () (spotify--route! (list "set repeating to not repeating\nif repeating then return \"repeat on\"\nreturn \"repeat off\"" 'repeat)
                (lambda () (spotify--control! spotify--repeat-js #f)))))

(define (spotify--on-page! href sel js k)
  ;; the player tab moves to HREF's page, runs JS there once SEL has drawn, and K
  ;; gets its answer; the music plays on, as the move does not reload the player
  (site-app-navigate! 'spotify (string-append "https://open.spotify.com" href) sel
    (lambda (tab answer)
      (if (not tab)
          (k #f)
          (tab-eval-main tab js (lambda (v) (k (if (string? v) v #f))))))))

(define (spotify--like-track! href k)
  ;; the heart on the track's own page. K gets #t when it is saved now, #f when
  ;; it is not, the string of the trouble when the page would not answer
  (let ((sel "main [data-testid=action-bar-row] [data-testid=add-button]"))
    (spotify--on-page! href "main [data-testid=action-bar-row]" (spotify--click-sel-js sel "clicked")
      (lambda (v)
        (if (not (equal? v "clicked"))
            (k (or v "the track's page did not open"))
            ;; read back apart from the click: the bridge does not wait on the page
            (spotify--on-page! href "main [data-testid=action-bar-row]"
              (string-append "(function(){var b=document.querySelector(" (json-encode sel) ");return b?String(b.getAttribute('aria-checked')):'none'})()")
              (lambda (s) (k (equal? s "true")))))))))

(define (spotify--row-track buf)
  ;; the track at point in a list, when it is not the one that plays
  (and (not (spotify--detail? buf))
       (let* ((row (list-current buf))
              (href (and row (or (site-app-field row 'href) ""))))
         (and href (string-prefix? "/track/" href)
              (not (equal? href (spotify--now-field 'trackHref)))
              (list href (or (site-app-field row 'name) ""))))))

(define-command "spotify-like" "Save the track at point, else the one that plays, to your library, or take it out"
  (lambda ()
    (let ((row (spotify--row-track (current-buffer)))
          (href (plist-get *spotify-now* 'trackHref)))
      (cond
        (row
         (spotify--like-track! (car row)
           (lambda (v) (message (cond ((eq? v #t) (string-append "Liked " (cadr row)))
                                      ((eq? v #f) (string-append "Took " (cadr row) " out of Liked Songs"))
                                      (else (string-append "Spotify: " v)))))))
        ((and (equal? (plist-get *spotify-now* 'source) "desktop") (string? href) (not (equal? href "")))
         ;; the app plays it, so its heart is on the track's own page
         (spotify--like-track! href
           (lambda (v)
             (if (boolean? v)
                 (begin (message (if v "liked" "unliked")) (spotify--now-set! (plist-put *spotify-now* 'liked v)))
                 (message (string-append "Spotify: " v))))))
        (else (spotify--control! (spotify--click-sel-js spotify--like-sel "liked") 'liked))))))

(define (spotify--following href)
  ;; #t, #f, or 'unknown before the artist's page was asked
  (if (site-app-cache-has? 'spotify 'following href) (spotify--get 'following href) 'unknown))

(define spotify--action-bar "main [data-testid=action-bar-row]")

(define (spotify--follow-js click?)
  ;; the follow button has no testid: it is the action bar's button that says so
  (string-append
    "(function(){var r=document.querySelector(" (json-encode spotify--action-bar) ");"
    "var b=r&&Array.from(r.querySelectorAll('button')).find(function(b){return /^(Follow|Following)$/.test(b.innerText.trim())});"
    "if(!b)return 'none';" (if click? "b.click();return 'clicked';" "return b.innerText.trim();") "})()"))

(define (spotify--artist-here buf)
  ;; the artist whose page this is, else the one that plays: (HREF NAME)
  (let* ((row (and (spotify--detail? buf) (buffer-local buf 'site-app-row)))
         (href (and row (or (site-app-field row 'href) ""))))
    (if (and href (string-prefix? "/artist/" href))
        (list href (or (site-app-field row 'name) ""))
        (let ((now (spotify--now-field 'artistHref)))
          (and (not (equal? now "")) (list now (spotify--now-field 'artists)))))))

(define (spotify--follow-set! href v)
  (spotify--put! 'following href v)
  (when (equal? href (spotify--now-field 'artistHref)) (spotify--now-set! *spotify-now*)))

(define-command "spotify-follow" "Follow the artist of this page, else the one that plays, or stop following them"
  (lambda ()
    (let ((artist (spotify--artist-here (current-buffer))))
      (if (not artist)
          (message "No artist here")
          (spotify--on-page! (car artist) spotify--action-bar (spotify--follow-js #t)
            (lambda (v)
              (if (not (equal? v "clicked"))
                  (message (string-append "Spotify: " (if (equal? v "none") "no follow button on the artist's page" (or v "the artist's page did not open"))))
                  (spotify--on-page! (car artist) spotify--action-bar (spotify--follow-js #f)
                    (lambda (s)
                      (spotify--follow-set! (car artist) (equal? s "Following"))
                      (message (if (equal? s "Following")
                                   (string-append "Following " (cadr artist))
                                   (string-append "Stopped following " (cadr artist)))))))))))))

;;;###autoload
(define-command "spotify-now-playing" "Say what is playing, and redraw the player bar"
  (lambda ()
    (spotify-now-refresh!
      (lambda (now)
        (message (if (and (pair? now) (not (equal? (plist-get now 'title) "")))
                     (string-append (plist-get now 'title) " — " (plist-get now 'artists))
                     "nothing playing"))))))

(define-command "spotify-volume-up" "Raise the player's volume"
  (lambda () (spotify--route! (list "set sound volume to (sound volume + 10)\nreturn \"volume \" & sound volume & \"%\"" 'volume-up)
                (lambda () (spotify--eval (spotify--volume-js "0.1") (lambda (v) (message (if (string? v) v "Spotify: no answer"))))))))

(define-command "spotify-volume-down" "Lower the player's volume"
  (lambda () (spotify--route! (list "set sound volume to (sound volume - 10)\nreturn \"volume \" & sound volume & \"%\"" 'volume-down)
                (lambda () (spotify--eval (spotify--volume-js "-0.1") (lambda (v) (message (if (string? v) v "Spotify: no answer"))))))))

;;;###autoload
(define-command "spotify-search" "Search Spotify and show the results in the app"
  (lambda ()
    (minibuffer-read "Spotify: " '()
      (lambda (q)
        (if (equal? (string-trim q) "")
            (message "Nothing to search for")
            (let ((buf (site-app-page-buffer 'spotify 'results)))
              (set! *spotify-query* (string-trim q))
              (site-app-open! 'spotify 'results)
              ;; a section already read shows as it stands; a new query reads it again
              (when (pair? (site-app-rows buf))
                (site-app-read-page! 'spotify (site-app-page (site-app-spec 'spotify) 'results)))))))))

(domain! 'spotify)
(effects! '(write external))

;; the pages a read came back from empty: no one asks again until a reload,
;; since every read ends in a redraw and a redraw asks for what is missing
(define *spotify-failed* '())
(define *spotify-asked* '())     ; what has been asked for, so it is asked once

(define (spotify--without x xs) (filter (lambda (y) (not (equal? y x))) xs))
(define (spotify--now-field k) (or (plist-get *spotify-now* k) ""))

;; the reader tab reads one page at a time, so the album and the artist are
;; read one after the other, and each only once
(define (spotify--read-page! href sheet k)
  ;; an album page is read once its tracks have drawn; an artist's once its
  ;; discography has, which comes after the popular tracks, the bio and the name.
  ;; A read that came back without a name is no read
  (let ((artist? (equal? sheet *spotify-artist-sheet*)))
    (site-app-navigate! 'spotify (string-append "https://open.spotify.com" href)
      (if artist? "main section[aria-label=Discography] [data-encore-id=card]" "main [data-testid=tracklist-row]")
      (lambda (tab answer)
        (let ((data (and answer (site-app-parse sheet (plist-get answer 'html)))))
          (k (and data
                  (if artist?
                      ;; an artist read is an artist: a name, and the listeners only an artist page counts
                      (and (not (equal? (plist-get data 'name) "")) (not (equal? (or (plist-get data 'listeners) "") "")))
                      ;; an album read is an album: its head says Album, Single, EP or Compilation
                      (let ((hero (let ((s (site-app-real (plist-get data 'section)))) (and (pair? s) (car s)))))
                        (and hero (re-match? "(?i)album|single|ep|compilation" (or (plist-get hero 'tier) "")))))
                  data)))))))

(define (spotify--ask! key) (if (member key *spotify-asked*) #f (begin (set! *spotify-asked* (cons key *spotify-asked*)) #t)))

(define (spotify--news-of! artist)
  ;; a web search, off the lane; a failed one may be asked again
  (when (and (not (equal? artist "")) (spotify--ask! (string-append "news:" artist)))
    (task-run!
      (lambda () (spotify--mcp-search (json-encode (list 'query (string-append artist " music news") 'num 8))))
      (lambda (ok text)
        (let ((items (and ok (string? text) (string-prefix? "[" (string-trim text)) (json-parse text))))
          (if (not ok)
              (set! *spotify-asked* (spotify--without (string-append "news:" artist) *spotify-asked*))
              (spotify--put! 'news artist (if (pair? items) items '())))
          (spotify--redraw-artist-tabs!)))
      30000)))

(define (spotify--album-read! href)
  ;; the album's page, for the name and release in the head of its track's page
  (when (and (string-prefix? "/album/" href) (not (spotify--get 'albums href)) (spotify--ask! href))
    (spotify--read-page! href *spotify-detail-sheet*
      (lambda (data)
        (if data
            (spotify--put! 'albums href data)
            (set! *spotify-asked* (spotify--without href *spotify-asked*)))
        (spotify--redraw-artist-tabs!)))))

(define (spotify--album-facts href)
  ;; (NAME RELEASED) from the album page's head: the whole date, else the year
  (let* ((data (spotify--get 'albums href))
         (hero (and data (let ((s (site-app-real (plist-get data 'section)))) (and (pair? s) (car s)))))
         (tags (if hero (or (plist-get hero 'tags) '()) '()))
         (released (or (find (lambda (t) (string-prefix? "Released " t)) tags)
                       (find (lambda (t) (re-match? "^[0-9]{4}$" t)) tags) "")))
    (list (if hero (spotify--card-title hero) "") released)))


(define (spotify--section-title text) (list 'tag "div" 'class "sp-np-section" 'text text 'sp-line text))
(define (spotify--quiet text) (list 'tag "div" 'class "sp-np-empty" 'text text 'sp-line text))
(define (spotify--host url)
  (let* ((rest (if (string-index url "://") (substring url (+ 3 (string-index url "://")) (string-length url)) url))
         (host (car (string-split rest "/"))))
    (if (string-prefix? "www." host) (substring host 4 (string-length host)) host)))

(define (spotify--brief-prompt name bio search)
  (string-append "Write a short bio of " name " for the listener who follows their music. Use only what the sources say.\n"
    "Plain text, no headings or markdown. Two short paragraphs: who " name " is, and what they are doing now.\n\n"
    "Artist page:\n" bio "\n\n"
    "Background search:\n" search))

(define (spotify--brief! name artist)
  (task-run!
    (lambda () (spotify--mcp-search (json-encode (list 'query (string-append name " musician biography background") 'num 6))))
    (lambda (ok text)
      (if ok
          (llm (spotify--brief-prompt name (or (plist-get artist 'bio) "") (if (string? text) text ""))
               (lambda (answer) (spotify--put! 'briefs name answer) (spotify--redraw-artist-tabs!)))
          (set! *spotify-asked* (spotify--without (string-append "brief:" name) *spotify-asked*))))
    30000))

(define (spotify--brief-blocks name artist)
  (when (and artist (spotify--ask! (string-append "brief:" name)))
    (spotify--brief! name artist))
  (let ((hit (spotify--get 'briefs name)))
    (cond (hit (cons (spotify--section-title "Brief")
                     (map (lambda (line) (spotify--lined (list 'tag "p" 'class "sp-bio" 'text line) line))
                          (filter (lambda (s) (not (equal? s ""))) (string-split hit "\n")))))
          ((member (string-append "brief:" name) *spotify-asked*) (list (spotify--quiet "Writing the brief…")))
          (else '()))))

(define (spotify--taste)
  (let ((text (if (buffer-exists? "*spotify-liked*") (buffer-text "*spotify-liked*") "")))
    (if (> (string-length text) 4000) (substring text 0 4000) text)))

(define (spotify--listen-prompt name bio)
  (string-append "Name five albums by this artist or their projects that this listener has not heard yet, grounded in the liked songs and the artist page. Use only what the sources say. One per line, exactly in the form: Artist | Album. No other text.\n\n"
    "Liked songs:\n" (spotify--taste) "\n\n"
    "Artist page:\n" bio))

(define (spotify--listen-resolve line)
  (let* ((parts (string-split line "|"))
         (artist (string-trim (car parts)))
         (album (string-trim (cadr parts)))
         (found (http-get-json (string-append "https://musicbrainz.org/ws/2/release-group/?query="
                                  (url-encode (string-append "releasegroup:\"" album "\" AND artist:\"" artist "\"")) "&fmt=json&limit=1")
                  (list 'headers (list (list "User-Agent" "compos-spotify/1.0 (svs@svs.io)")))))
         (groups (or (and found (plist-get found 'release-groups)) '())))
    (list 'artist artist 'album album
          'cover (if (pair? groups) (string-append "https://coverartarchive.org/release-group/" (plist-get (car groups) 'id) "/front-250") "")
          'href (string-append "/search/" (url-encode (string-append artist " " album))))))

(define (spotify--listen! name artist)
  (llm (spotify--listen-prompt name (or (plist-get artist 'bio) ""))
       (lambda (answer)
         (task-run!
           (lambda ()
             (map spotify--listen-resolve
                  (filter (lambda (s) (string-index s "|")) (map string-trim (string-split answer "\n")))))
           (lambda (ok items)
             (if ok
                 (spotify--put! 'listen name items)
                 (set! *spotify-asked* (spotify--without (string-append "listen:" name) *spotify-asked*)))
             (spotify--redraw-artist-tabs!))
           120000))))

(define (spotify--listen-blocks name artist)
  (when (and artist (spotify--ask! (string-append "listen:" name)))
    (spotify--listen! name artist))
  (let ((hit (and (site-app-cache-has? 'spotify 'listen name) (list name (spotify--get 'listen name)))))
    (cond ((and hit (pair? (cadr hit)))
           (cons (spotify--section-title "Listen next")
                 (map (lambda (it)
                        (spotify--lined (plist-put (component 'spotify/tile
                                                     (list 'title (plist-get it 'album) 'icon (plist-get it 'cover)
                                                           'badge "album" 'tags (list (plist-get it 'artist))))
                                                   'click (string-append "spotify-url:https://open.spotify.com" (plist-get it 'href)))
                                        (plist-get it 'album)))
                      (cadr hit))))
          (hit '())
          ((member (string-append "listen:" name) *spotify-asked*) (list (spotify--quiet "Finding what to hear next…")))
          (else '()))))

(define *spotify-origin* #f)

(define (spotify--origin-line)
  (let ((o *spotify-origin*))
    (if (and o (equal? (car o) (spotify--now-field 'albumHref)))
        (let* ((parts (string-split (cadr o) ": "))
               (label (apply string-append (string-split (if (pair? (cdr parts)) (cadr parts) (car parts)) "*"))))
          (list (spotify--quiet (string-append "Playing from " label))))
        '())))

(define (spotify--track-page now playing?)
  ;; the page of the track NOW: its head, then its artist; PLAYING? when it
  ;; is the one that plays, which says where it plays from
  (let* ((field (lambda (k) (let ((v (plist-get now k))) (if (string? v) v ""))))
         (title (field 'title))
         (album-href (field 'albumHref))
         (artist-href (field 'artistHref))
         (album (begin (spotify--album-read! album-href) (spotify--album-facts album-href)))
         (artist (spotify--get 'artists artist-href))
         (name (let ((n (and artist (plist-get artist 'name))))
                 (if (and (string? n) (not (equal? n ""))) n (car (string-split (field 'artists) ",")))))
         (news (spotify--get 'news name)))
    (if (equal? title "")
        (list (spotify--quiet "Nothing is playing. Play something with p in any Spotify section."))
        (append
          (list (spotify--lined (component 'spotify/np-hero
                  (list 'title title 'artists (field 'artists) 'art (spotify--hires (field 'art))
                        'album (if (equal? (car album) "") (field 'album) (car album)) 'released (cadr album)
                        'click (string-append "spotify-open:" album-href "|" (car album))
                        'playing? (eq? (plist-get now 'playing) #t) 'liked? (eq? (plist-get now 'liked) #t)
                        'following (plist-get (spotify--now-props) 'following)
                        'position (field 'position) 'duration (field 'duration)
                        'shuffle (or (plist-get now 'shuffle) "off") 'repeat (or (plist-get now 'repeat) "off")))
                                (string-append title " — " (field 'artists))))
          (if playing? (spotify--origin-line) '())
          (spotify--brief-blocks name artist)
          (spotify--listen-blocks name artist)
          (cond
            ((and (not artist) (member artist-href *spotify-failed*))
             (list (spotify--quiet (string-append "Spotify did not show " name "'s page."))))
            ((not artist) (list (spotify--quiet (string-append "Reading " name "'s page…"))))
            (else
             (let ((tour (let ((ts (filter (lambda (g) (equal? (plist-get g 'artist) name)) (or (plist-get artist 'tour) '()))))
                           (if (> (length ts) 6) (list-head ts 6) ts)))
                   (discog (or (plist-get artist 'discog) '())))
               (append
                 (if (null? tour) '()
                     (cons (spotify--section-title "On tour")
                           (map (lambda (g)
                                  (spotify--lined (component 'spotify/gig
                                    (list 'month (plist-get g 'month) 'day (plist-get g 'day) 'city (plist-get g 'city)
                                          'venue (plist-get g 'venue) 'when (plist-get g 'when)
                                          'click (string-append "spotify-url:https://open.spotify.com" (plist-get g 'href))))
                                    (string-append (plist-get g 'month) " " (plist-get g 'day) " " (plist-get g 'city))))
                                tour)))
                 (list (spotify--section-title "About")
                       (spotify--lined (component 'spotify/artist-card
                         (list 'name name 'image (or (plist-get artist 'image) "") 'images (spotify--artist-images name artist)
                               'listeners (or (plist-get artist 'listeners) "")
                               ;; the brief says what the bio says: the card keeps the bio only until a brief is written
                               'verified? (equal? (plist-get artist 'verified) "yes")
                               'bio (if (spotify--get 'briefs name) "" (or (plist-get artist 'bio) ""))))
                         name))
                 (if (null? discog) '()
                     (list (spotify--section-title "Discography")
                           (component 'ui/group
                             (list 'class "sp-shelf"
                                   'body (map (lambda (d)
                                                (spotify--lined (plist-put (component 'spotify/tile
                                                             (list 'title (plist-get d 'name) 'icon (plist-get d 'art)
                                                                   'badge (plist-get d 'kind) 'tags (list (plist-get d 'sub))))
                                                           'click (string-append "spotify-open:" (plist-get d 'href) "|" (plist-get d 'name)))
                                                  (plist-get d 'name)))
                                              discog)))))))))
          (list (spotify--section-title "News"))
          (cond ((not news) (list (spotify--quiet (string-append "Looking for news about " name "…"))))
                ((null? news) (list (spotify--quiet "No news found.")))
                (else
                 (map (lambda (n)
                        (let* ((snippet (or (plist-get n 'snippet) ""))
                               (at (string-index snippet " ... "))
                               (date (if (and at (< at 20)) (substring snippet 0 at) ""))
                               (body (if (and at (< at 20)) (substring snippet (+ at 5) (string-length snippet)) snippet)))
                          (spotify--lined (component 'spotify/news-item
                            (list 'title (or (plist-get n 'title) "") 'source (spotify--host (or (plist-get n 'link) ""))
                                  'date date 'snippet body 'click (string-append "spotify-url:" (or (plist-get n 'link) ""))))
                            (or (plist-get n 'title) ""))))
                      news)))))))

(define (spotify--lined block text) (append block (list 'sp-line (or text ""))))

(define (spotify--link-of block)
  (let ((c (plist-get block 'click)))
    (and (string? c) (string-prefix? "spotify-url:" c) (substring c 12 (string-length c)))))

(define (spotify--open-url! url from)
  ;; a review or a story reads in the page pane, where FROM was, so the app
  ;; stays two panes; Spotify's own pages (a concert) open in its tab
  (if (spotify--has? url "open.spotify.com")
      (tab-open url)
      (let ((page (browse url))
            (pane (spotify--page-pane from)))
        (if pane
            (begin
              ;; the list's later pages land here again
              (buffer-set-local! page 'detail-of (buffer-local from 'detail-of))
              (with-frame-windows (lambda () (window-set-buffer! pane page))))
            (display-buffer-detail! page from)))))

(define (spotify--claim-all b blocks)
  ;; BLOCKS on B's lines, one line a part, as (CLAIMED CLICKS): CLICKS is
  ;; ((LINE CLICK) ...), what RET does on each line
  (let* ((clicks '())
         (claim (lambda (block)
                  (let* ((text (or (plist-get block 'sp-line) ""))
                         ;; a line with a web link is one RET follows
                         (n (b 'line text (spotify--link-of block)))
                         (click (plist-get block 'click)))
                    (when (and (string? click) (not (equal? click ""))) (set! clicks (cons (list n click) clicks)))
                    (site-app-claim block n n (if (equal? text "") #f text)))))
         (claimed (map (lambda (block)
                         (cond ((not (equal? (plist-get block 'tag) "c-group")) (claim block))
                               ((plist-get block 'sp-line)
                                ;; a part (spotify--part): one anchor, named by its heading
                                (let* ((first (+ 1 (b 'count #f #f)))
                                       (kids (map (lambda (k)
                                               ;; a line that opens something is a stop of its own
                                               (let ((c (claim k)) (click (plist-get k 'click)))
                                                 (let ((c (if (and (string? click) (not (equal? click ""))) c (plist-put c 'anchor-name #f))))
                                                   ;; the tour is the page's sidebar: a second column to cross to
                                                   (if (equal? (plist-get block 'sp-line) "On tour") (plist-put c 'anchor-data '(column 2)) c))))
                                                  (or (plist-get block 'children) '()))))
                                  (plist-put (site-app-claim (plist-put block 'children kids) first (max first (b 'count #f #f))
                                                             (plist-get block 'sp-line))
                             'anchor-data (if (equal? (plist-get block 'sp-line) "On tour") '(column 2) #f))))
                               (else
                                ;; a shelf: each release is a part of its own
                                (let* ((first (+ 1 (b 'count #f #f)))
                                       (kids (map claim (or (plist-get block 'children) '()))))
                                  (site-app-claim (plist-put block 'children kids) first (max first (b 'count #f #f)))))))
                       blocks)))
    (list claimed clicks)))

(cell-define! 'spotify/track '())
(cell-define! 'spotify/position '("" ""))
;; the clock on the page of what plays
(cell-part-bind! *spotify-now-detail* 'spotify/progress '(spotify/position)
  (lambda () (let ((p (cell-ref 'spotify/position))) (spotify--progress "sp-np-progress" (car p) (cadr p)))))


(define-command "spotify-now-context" "Go to Now Playing: the list that plays, on the track that plays"
  (lambda () (spotify--playing-section! #t)))

(define-command "spotify-detail-follow" "Follow the link on this line: a review or a story reads beside the page"
  (lambda ()
    (let* ((buf (current-buffer))
           (hit (site-app-detail-link-at buf))
           (href (and hit (caddr hit))))
      (if (and (string? href) (string-prefix? "http" href) (not (spotify--has? href "open.spotify.com")))
          (spotify--open-url! href buf)
          (run-command "site-app-detail-follow")))))

(define-command "spotify-go-home" "Go to Spotify Home"
  (lambda () (spotify--go-section! 'home)))

(define-command "spotify-go-liked" "Go to your liked songs"
  (lambda () (spotify--go-section! 'liked)))

(define-command "spotify-go-playlists" "Go to your Spotify playlists"
  (lambda () (spotify--go-section! 'playlists)))

;; a click on the page: a release opens beside the list, a popular track plays
;; in the artist's list, a concert or a story opens in the browser
(add-hook! (list 'block-click 'spotify-now)
  (lambda (buf id)
    (let ((after (lambda (prefix) (substring id (string-length prefix) (string-length id))))
          (split (lambda (s) (let ((parts (string-split s "|"))) (list (car parts) (if (pair? (cdr parts)) (cadr parts) ""))))))
      (cond ((not (string? id)) #f)
            ((string-prefix? "spotify-open:" id)
             (let* ((p (split (after "spotify-open:"))) (href (car p)))
               (unless (equal? href "")
                 (site-app-show-detail! (spotify--section-list)
                   (list 'key href 'href href 'name (if (equal? (cadr p) "") href (cadr p)))))
               #t))
            ((string-prefix? "spotify-play:" id)
             (let ((p (split (after "spotify-play:"))))
               (spotify--play-track! (car p) (cadr p) "" (if (string-prefix? "Play " (cadr p)) (substring (cadr p) 5 (string-length (cadr p))) ""))
               #t))
            ((string-prefix? "spotify-url:" id) (spotify--open-url! (after "spotify-url:") buf) #t)
            (else #f)))))

;;; --- keys ---------------------------------------------------------------------
;;; The same keys in every section and on every item's page. `C-c S` reaches
;;; the player from anywhere; lowercase `C-c s` is the scratch buffer's.

(define *spotify-keys*
  (list (list "p" "spotify-play") (list "SPC" "spotify-play-pause")
        (list "." "spotify-next") (list "," "spotify-previous")
        (list "l" "spotify-like") (list "i" "spotify-now-playing")
        (list "=" "spotify-volume-up") (list "-" "spotify-volume-down")
        (list "/" "spotify-search") (list "M-0" "spotify-now-context")
        ;; N goes to the list that plays, H home, P your playlists
        (list "N" "spotify-now-context") (list "H" "spotify-go-home") (list "L" "spotify-go-liked") (list "P" "spotify-go-playlists")
        (list "S" "spotify-shuffle") (list "R" "spotify-repeat") (list "F" "spotify-follow")
          (list "<down>" "list-next") (list "<up>" "list-prev")))

(define (spotify--bind-keys!)
  ;; define-site-app makes each section's keymap afresh, / as its status
  ;; filter, so these go on after it every time
  (for-each (lambda (mode)
              (for-each (lambda (k) (define-key (mode-keymap mode) (car k) (cadr k))) *spotify-keys*))
            (cons "spotify-detail-mode"
                  (map (lambda (page) (site-app-page-mode 'spotify (plist-get page 'id)))
                       (site-app-pages (site-app-spec 'spotify)))))
  ;; a page is not a list: its arrows step from part to part
  (define-key (mode-keymap "spotify-detail-mode") "<down>" "site-app-detail-next")
  (define-key (mode-keymap "spotify-detail-mode") "<up>" "site-app-detail-prev")
  (define-key (mode-keymap "spotify-detail-mode") "RET" "spotify-detail-follow"))

(define (spotify--own-nav!)
  ;; detail-mode's N and P walk the list beside the page, and its map is
  ;; nearer than the mode's: here N goes to what plays and P to the playlists
  (local-remap*! (current-buffer) "index-next-item" "spotify-now-context")
  (local-remap*! (current-buffer) "index-previous-item" "spotify-go-playlists"))

(add-hook! 'spotify-detail-mode-hook 'spotify--own-nav!)
(add-hook! 'spotify-detail-mode-hook 'spotify--now-minor!)

(spotify--define-app!)

(define-key "spotify-map" "s" "spotify-play-pause")
(define-key "spotify-map" "n" "spotify-next")
(define-key "spotify-map" "p" "spotify-previous")
(define-key "spotify-map" "i" "spotify-now-playing")
(define-key "spotify-map" "l" "spotify-like")
(define (spotify--section-ready! id)
  ;; what site-app-open! does to a section, without showing it anywhere
  (let ((buf (site-app-page-buffer 'spotify id))
        (mode (site-app-page-mode 'spotify id)))
    (unless (buffer-exists? buf) (buffer-create buf))
    (site-app-join-group! buf)
    (buffer-set-local! buf 'site-app-spec (site-app-spec 'spotify))
    (buffer-set-local! buf 'site-app-page id)
    (unless (buffer-derived-mode? buf mode)
      (with-current-buffer buf (lambda () (set-mode! mode))))
    buf))

(define-command "spotify-search" "Search Spotify and show the results in the app"
  (lambda ()
    (minibuffer-read "Spotify: " '()
      (lambda (q)
        (if (equal? (string-trim q) "")
            (message "Nothing to search for")
            (let* ((buf (spotify--section-ready! 'results))
                   ;; the pane already showing a section takes the results, so
                   ;; a search from an item's page leaves that page where it is
                   (pane (with-frame-windows
                           (lambda ()
                             (find (lambda (w) (member (window-buffer w) (spotify--list-buffers)))
                                   (map car (window-list)))))))
              (set! *spotify-query* (string-trim q))
              ;; a search asked before shows what it found at once; g reads it again
              (let ((kept (spotify--get 'searches *spotify-query*)))
                (buffer-set-local! buf 'site-app-rows (or kept '()))
                (buffer-set-local! buf 'list-layout-cache #f)
                (list-refresh! buf)
                (if pane
                    (with-frame-windows (lambda () (window-set-buffer! pane buf)))
                    (switch-to-buffer! buf))
                (if kept
                    (message (string-append (number->string (length kept)) " albums for " *spotify-query* " · g reads again"))
                    (site-app-read-page! 'spotify (site-app-page (site-app-spec 'spotify) 'results))))))))))
(define-key "spotify-map" "g" "spotify")
(define-key "spotify-map" "N" "spotify-now-context")
(define-key "spotify-map" "S" "spotify-shuffle")
(define-key "spotify-map" "R" "spotify-repeat")

;; what earlier sessions found
(site-app-cache-load! 'spotify)

;;; --- the assistant's tool -----------------------------------------------------
;;; A key press answers in the echo area whenever the page gets round to it.
;;; A tool has to RETURN what the page said inside the turn that asked, so
;;; these wait, and each answer is a sentence a person could read out loud.

(domain! 'spotify)
(effects! '(write external))

(define (spotify--eval-sync code)
  (let* ((r (browser-call-sync "tabs" '() 2000))
         (all (if (plist-get r 'ok) (filter spotify--tab? (or (plist-get r 'tabs) '())) '()))
         ;; the same player the keys use: the one in front, else the newest
         (front (filter (lambda (t) (eq? (plist-get t 'active) #t)) all))
         (hits (if (pair? front) front (reverse all))))
    (if (null? hits)
        (begin (site-app-find-tab! 'spotify (lambda (t) #t)) "No Spotify tab was open. I opened one — sign in, then ask again.")
        (let ((r (browser-call-sync "eval" (list 'tab (chrome--tab-id (car hits)) 'code code 'world "main") 4000)))
          (if (plist-get r 'ok)
              (let ((v (plist-get r 'value))) (if (string? v) v "done"))
              (string-append "the player did not answer: " (or (plist-get r 'error) "unknown error")))))))

(define spotify--now-text-js
  (string-append
    "(function(){var q=function(s){var e=document.querySelector(s);return e&&(e.innerText||e.textContent||'').trim()};"
    "var t=q('[data-testid=context-item-link]');var a=q('[data-testid=context-item-info-artist]');"
    "return t?(a?t+' — '+a:t):'nothing playing';})()"))

;; "Pause the music" must never start it, so the button is read before it is pressed
(define (spotify--want-js want)
  (string-append
    "(function(){var b=document.querySelector('[data-testid=control-button-playpause]');"
    "if(!b)return 'no player controls — is the tab loaded?';"
    "var playing=/pause/i.test(b.getAttribute('aria-label')||'');var want=" (json-encode want) ";"
    "if(want==='play'&&!playing){b.click();return 'playing'}"
    "if(want==='pause'&&playing){b.click();return 'paused'}"
    "return playing?'already playing':'already paused';})()"))

(define (spotify--goto-search-js q)
  (string-append "(function(){location.href='https://open.spotify.com/search/'+encodeURIComponent("
                 (json-encode q) ");return 'searching';})()"))

;; Only main counts (the sidebar has play buttons too), and the words you
;; said outrank the order Spotify chose.
(define (spotify--play-match-js q)
  (string-append
    "(function(){var root=document.querySelector('main')||document;"
    "var bs=Array.from(root.querySelectorAll('button[data-testid=play-button]'));if(!bs.length)return '';"
    "var ws=" (json-encode q) ".split(/\\s+/).filter(function(w){return w.length>2}).map(function(w){return w.toLowerCase()});"
    "var hit=bs.filter(function(e){var l=(e.getAttribute('aria-label')||'').toLowerCase();return ws.some(function(w){return l.indexOf(w)>=0})})[0];"
    "var b=hit||bs[0];b.click();return b.getAttribute('aria-label')||'the first result';})()"))

;; Each try is a real round trip to the page, so the loop paces itself and
;; stops the moment a result appears.
(define (spotify-play-query q)
  (spotify--eval-sync (spotify--goto-search-js q))
  (let loop ((n 25))
    (if (= n 0)
        (string-append "I searched for " q " but no result appeared in time")
        (let ((r (spotify--eval-sync (spotify--play-match-js q))))
          (if (or (equal? r "") (string-prefix? "the player did not answer" r))
              (loop (- n 1))
              (string-append "playing " r))))))

(define (spotify--do action query level)
  (cond
    ((equal? action "now-playing") (spotify--eval-sync spotify--now-text-js))
    ((equal? action "next") (spotify--eval-sync (spotify--click-js "control-button-skip-forward" "next track")))
    ((equal? action "previous") (spotify--eval-sync (spotify--click-js "control-button-skip-back" "previous track")))
    ((equal? action "pause") (spotify--eval-sync (spotify--want-js "pause")))
    ((equal? action "like") (spotify--eval-sync (spotify--click-sel-js spotify--like-sel "liked")))
    ((equal? action "shuffle") (spotify--eval-sync spotify--shuffle-js))
    ((equal? action "repeat") (spotify--eval-sync spotify--repeat-js))
    ((equal? action "volume")
     (if (number? level)
         (spotify--eval-sync (string-append "(function(){var m=document.querySelector('video,audio');"
                                            "if(!m)return 'no sound yet — start something playing first';"
                                            "m.volume=Math.min(1,Math.max(0," (number->string level) "/100));"
                                            "return 'volume '+Math.round(m.volume*100)+'%';})()"))
         "tell me a level from 0 to 100"))
    ((equal? action "search")
     (if (string? query)
         (begin (spotify--eval-sync (spotify--goto-search-js query))
                (string-append "the tab is showing results for " query))
         "tell me what to search for"))
    ((equal? action "play")
     (if (and (string? query) (not (equal? query "")))
         (spotify-play-query query)
         (spotify--eval-sync (spotify--want-js "play"))))
    (else (string-append "I do not know how to " action))))

(define-tool! 'spotify
  (string-append
    "Control the Spotify web player in the user's browser and report what happened. "
    "action: play (with query: find that music and start it; without: resume), "
    "pause, next, previous, now-playing, like, shuffle, repeat, search, volume. "
    "query names music in words, like \"blackwater park opeth\". "
    "level is 0-100, for volume.")
  '((action "string" "play, pause, next, previous, now-playing, like, shuffle, repeat, search or volume")
    (query "string" "the music to find, in words" optional)
    (level "number" "volume from 0 to 100" optional))
  (lambda (args)
    (spotify--do (or (plist-get args 'action) "now-playing")
                 (plist-get args 'query)
                 (plist-get args 'level)))
  '(write external))

;; The ambient page and the stager that plans it for each song.
(require 'spotify-ambient "spotify/visualisers/ambient.scm")
