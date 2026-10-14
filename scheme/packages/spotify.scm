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

(domain! 'spotify)
(effects! '(write))

(defgroup 'spotify "The Spotify web player, as an app in the editor.")

(defcustom 'spotify-url "https://open.spotify.com/"
  "The page the player runs in." 'group 'spotify)

(defcustom 'spotify-user ""
  "Your Spotify user id, the last part of your profile's /user/ID link. The Playlists section reads that profile."
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
    (artists string optional) (album string optional) (duration string optional) (playing? boolean optional)
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
              (spotify--text "sp-dur" (component--get p 'duration (tag 2))))))))

(defcomponent 'spotify/tile
  "A playlist, album or artist as a row: the cover (round for an artist), the name, and under it the kind and what the site says of it. BADGE is the kind, TAGS the subtitle."
  '((title string required) (icon string optional) (badge string optional) (tags list optional)
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
                                                            (if year (list (spotify--text "sp-year" year)) '())
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

(defcomponent 'spotify/now-playing
  "The player bar: the cover, the title over its artists with a heart when it is liked, the time and a progress bar, and the controls as keys. Each control's CLICK is spotify:COMMAND."
  '((title string optional) (artists string optional) (art string optional) (playing? boolean optional)
    (liked? boolean optional) (position string optional) (duration string optional) (class string optional))
  '(title "Windowpane" artists "Opeth" playing? #t liked? #t position "2:10" duration "7:44")
  (lambda (p)
    (let* ((title (component--get p 'title ""))
           (pos (component--get p 'position ""))
           (dur (component--get p 'duration ""))
           (total (spotify--seconds dur))
           (pct (if (> total 0) (min 100 (quotient (* 100 (spotify--seconds pos)) total)) 0))
           (playing? (component--get p 'playing? #f)))
      (list 'tag "div" 'class (string-append "sp-now " (component--get p 'class ""))
            'children
            (if (equal? title "")
                (list (spotify--text "sp-now-idle" "Nothing playing. p on a row plays it."))
                ;; the cover and the title open the Now Playing page
                (list (plist-put (spotify--cover "sp-now-art sp-now-open" (component--get p 'art "") title) 'click "spotify:spotify-now-page")
                      (list 'tag "div" 'class "sp-main sp-now-open" 'click "spotify:spotify-now-page"
                            'children (list (list 'tag "span" 'class "sp-name"
                                                  'children (append (list (spotify--text "" title))
                                                                    (if (component--get p 'liked? #f) (list (spotify--text "sp-liked" " ♥")) '())))
                                            (spotify--text "sp-by" (component--get p 'artists ""))))

                      (list 'tag "div" 'class "sp-now-time"
                            'children (list (spotify--text "sp-dur" pos)
                                            (list 'tag "span" 'class "sp-bar"
                                                  'children (list (list 'tag "span" 'class "sp-bar-fill"
                                                                        'attrs (list (list "style" (string-append "width:" (number->string pct) "%"))))))
                                            (spotify--text "sp-dur" dur)))
                      (component 'ui/actions
                        (list 'class "sp-controls"
                              'actions (list (list "spotify:spotify-previous" "⏮" ",")
                                             (list "spotify:spotify-play-pause" (if playing? "⏸" "▶") "P" "good")
                                             (list "spotify:spotify-next" "⏭" ".")
                                             (list "spotify:spotify-like" (if (component--get p 'liked? #f) "♥" "♡") "l"))))))))))

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

(defcomponent 'spotify/np-hero
  "The head of the Now Playing page: the cover large on a blur of itself, whether it plays, the title, the artists, the album and its release, a progress bar and the controls. A click on the album is CLICK."
  '((title string required) (artists string optional) (art string optional) (album string optional)
    (released string optional) (click string optional) (playing? boolean optional) (liked? boolean optional)
    (position string optional) (duration string optional))
  '(title "Windowpane" artists "Opeth" album "Damnation" released "April 22, 2003" playing? #t position "2:10" duration "7:44")
  (lambda (p)
    (let* ((art (component--get p 'art ""))
           (pos (component--get p 'position ""))
           (dur (component--get p 'duration ""))
           (total (spotify--seconds dur))
           (pct (if (> total 0) (min 100 (quotient (* 100 (spotify--seconds pos)) total)) 0))
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
                          (list (list 'tag "div" 'class "sp-np-progress"
                                      'children (list (spotify--text "sp-dur" pos)
                                                      (list 'tag "span" 'class "sp-bar"
                                                            'children (list (list 'tag "span" 'class "sp-bar-fill"
                                                                                  'attrs (list (list "style" (string-append "width:" (number->string pct) "%"))))))
                                                      (spotify--text "sp-dur" dur)))
                                (component 'ui/actions
                                  (list 'class "sp-np-controls"
                                        'actions (list (list "spotify:spotify-previous" "⏮  previous" ",")
                                                       (list "spotify:spotify-play-pause" (if playing? "⏸  pause" "▶  play") "P" "good")
                                                       (list "spotify:spotify-next" "⏭  next" ".")
                                                       (list "spotify:spotify-like" (if liked? "♥  liked" "♡  like") "l"))))))))))))

(defcomponent 'spotify/artist-card
  "Who the artist is: their photo as a banner with the name, the verified mark and the monthly listeners over it, then the bio in paragraphs."
  '((name string required) (image string optional) (listeners string optional) (verified? boolean optional) (bio string optional))
  '(name "Opeth" listeners "1,022,069 monthly listeners" verified? #t bio "Swedish progressive titans.")
  (lambda (p)
    (let ((image (component--get p 'image ""))
          (paras (filter (lambda (s) (not (equal? (string-trim s) "")))
                         (string-split (component--get p 'bio "") "\n"))))
      (list 'tag "div" 'class "sp-artist"
            'children
            (cons (list 'tag "div" 'class "sp-artist-banner"
                        'attrs (if (equal? image "") '() (list (list "style" (string-append "background-image:url('" image "')"))))
                        'children (append (if (component--get p 'verified? #f) (list (spotify--text "sp-verified" "✔ Verified artist")) '())
                                          (list (spotify--text "sp-artist-name" (component--get p 'name ""))
                                                (spotify--text "sp-artist-listeners" (component--get p 'listeners "")))))
                  (map (lambda (s) (list 'tag "p" 'class "sp-bio" 'text (string-trim s))) paras))))))

(defcomponent 'spotify/gig
  "One concert: the date as a calendar leaf, the city, the venue and the time. CLICK opens it."
  '((month string optional) (day string optional) (city string required) (venue string optional) (when string optional) (click string optional))
  '(month "Nov" day "1" city "Santiago" venue "Movistar Arena" when "Sun 7:00 PM")
  (lambda (p)
    (list 'tag "div" 'class "sp-gig" 'click (component--get p 'click "")
          'children (list (list 'tag "span" 'class "sp-gig-date"
                                'children (list (spotify--text "sp-gig-month" (component--get p 'month ""))
                                                (spotify--text "sp-gig-day" (component--get p 'day ""))))
                          (list 'tag "div" 'class "sp-main"
                                'children (list (spotify--text "sp-name" (component--get p 'city ""))
                                                (spotify--text "sp-by" (string-append (component--get p 'venue "")
                                                                                       (let ((w (component--get p 'when ""))) (if (equal? w "") "" (string-append "  ·  " w)))))))))))

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
.sp-track:hover, .sp-tile:hover, .current > .sp-track, .current > .sp-tile, .sp-track.current, .sp-tile.current { background: var(--hl-line-bg); }
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
.sp-now { display: flex; align-items: center; gap: 14px; padding: 10px 12px; margin: 0 0 10px; border: 1px solid var(--border-bg); border-radius: 10px; font-family: var(--font-sans); font-size: 13px; }
.sp-now-art { flex: none; width: 52px; height: 52px; border-radius: 6px; object-fit: cover; background: var(--hl-line-bg); }
.sp-now-idle { color: var(--dim-fg); }
.sp-liked { color: var(--ok-fg); }
.sp-now-time { display: flex; align-items: center; gap: 8px; flex: 0 1 34%; min-width: 120px; }
.sp-bar { flex: 1; height: 4px; border-radius: 2px; background: var(--border-bg); overflow: hidden; }
.sp-bar-fill { display: block; height: 100%; background: var(--ok-fg); }
.sp-controls { flex: none; }

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
")

;;; --- the player ---------------------------------------------------------------
;;; Your own Spotify tab. The reader tab site-app keeps is hidden from the tab
;;; list, so the first open.spotify.com tab there is the one you listen in.

(domain! 'spotify)
(effects! '(write external))

(define (spotify--tab? t)
  (let ((u (plist-get t 'url)))
    (and (string? u) (string-prefix? "https://open.spotify.com" u)
         (not (equal? (chrome--tab-id t) (site-app-tab 'spotify))))))

;; Every control starts here. With no player tab open we open one and say so,
;; because a command that silently does nothing reads like a broken editor.
(define (spotify-tab k)
  ;; every Chrome window, not only the editor's: the player is wherever you
  ;; left it. The tab in front in its window wins, else the newest
  (chrome-call "tabs" '()
    (lambda (r)
      (let* ((hits (filter spotify--tab? (or (plist-get r 'tabs) '())))
             (front (filter (lambda (t) (eq? (plist-get t 'active) #t)) hits)))
        (cond ((pair? front) (k (car front)))
              ((pair? hits) (k (car (reverse hits))))
              (else
               (tab-open spotify-url)
               (message "Opened the Spotify tab — sign in there, then try again")))))))

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
    "return JSON.stringify({title:t('[data-testid=context-item-link]'),artists:as.filter(function(a,i){return as.indexOf(a)===i}).join(', '),"
    "art:img?img.src:'',playing:/pause/i.test(pp&&pp.getAttribute('aria-label')||''),"
    "position:t('[data-testid=playback-position]'),duration:t('[data-testid=playback-duration]'),"
    "albumHref:href(al),artistHref:href(ar),"
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
  ;; every section's bar redraws; the Now Playing page too, and it reads the
  ;; album and the artist when the music moved on to new ones
  (let ((moved (or (not (equal? (plist-get now 'albumHref) (plist-get *spotify-now* 'albumHref)))
                   (not (equal? (plist-get now 'artistHref) (plist-get *spotify-now* 'artistHref))))))
    (set! *spotify-now* now)
    (for-each (lambda (b) (buffer-set-local! b 'list-layout-cache #f) (list-refresh! b)) (spotify--list-buffers))
    (when (and (boundp 'spotify--now-draw!) (buffer-exists? *spotify-now-buffer*))
      (spotify--now-draw!)
      (when moved (spotify--context!)))))

(define (spotify--quiet-eval code k)
  ;; the player if it is open, else K gets #f: a refresh never opens a tab
  (chrome-call "tabs" '()
    (lambda (r)
      (let* ((hits (filter spotify--tab? (or (plist-get r 'tabs) '())))
             (front (filter (lambda (t) (eq? (plist-get t 'active) #t)) hits))
             (t (cond ((pair? front) (car front)) ((pair? hits) (car (reverse hits))) (else #f))))
        (if t (tab-eval-main t code k) (k #f))))))

(define (spotify-now-refresh! &optional k)
  (spotify--quiet-eval spotify--now-json-js
    (lambda (v)
      (let ((now (and (string? v) (> (string-length v) 1) (json-parse v))))
        (when (and (pair? now) (not (equal? now *spotify-now*))) (spotify--now-set! now))
        (when k (k now))))))

;; Spotify cannot tell the editor its track changed, so while a section is on
;; screen the bar reads the player every few seconds, and stops when none is.
(defcustom 'spotify-now-seconds 5
  "Seconds between two reads of the player while a Spotify section is on screen." 'group 'spotify)

(define *spotify-ticking* #f)

(define (spotify--shown?)
  (let ((shown (get-visible-buffers)))
    (pair? (filter (lambda (b) (member b shown)) (cons "*spotify-now*" (spotify--list-buffers))))))

(define (spotify--tick! ignored)
  ;; off until the read answers: a player that never does stops the ticks,
  ;; and the next draw of the bar starts them again
  (set! *spotify-ticking* #f)
  (when (spotify--shown?)
    (spotify-now-refresh!
      (lambda (now)
        (unless *spotify-ticking*
          (set! *spotify-ticking* #t)
          (debounce! 'spotify-now (* 1000 spotify-now-seconds) spotify--tick! #f))))))

(define (spotify--ticker-start!)
  (unless *spotify-ticking*
    (set! *spotify-ticking* #t)
    (debounce! 'spotify-now 500 spotify--tick! #f)))

(define (spotify--now-props)
  (let ((n *spotify-now*))
    (list 'title (or (plist-get n 'title) "") 'artists (or (plist-get n 'artists) "")
          'art (or (plist-get n 'art) "") 'playing? (eq? (plist-get n 'playing) #t)
          'liked? (eq? (plist-get n 'liked) #t)
          'position (or (plist-get n 'position) "") 'duration (or (plist-get n 'duration) ""))))

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
  ;; button still on the old page does not count. Gives up after ten seconds
  (string-append
    "(function(){var path=" (json-encode path) ",sel=" (json-encode selector) ";"
    "var moving=location.pathname!==path,old=moving?document.querySelector('main section'):null;"
    "var go=function(){var b=Array.from(document.querySelectorAll(sel)).filter(function(e){return !(old&&old.isConnected&&old.contains(e))})[0];"
    "if(b){b.click();return true}return false};"
    "if(moving){history.pushState({},'',path);dispatchEvent(new PopStateEvent('popstate',{state:{}}))}"
    "if(go())return 'playing';"
    "var t,obs=new MutationObserver(function(){if(go()){obs.disconnect();clearTimeout(t)}});"
    "obs.observe(document.body,{subtree:true,childList:true,attributes:true});"
    "t=setTimeout(function(){obs.disconnect()},10000);return 'queued';})()"))

(define (spotify--play! path selector what)
  (spotify-tab
    (lambda (t)
      (tab-eval-main t (spotify--play-js path selector)
        (lambda (v)
          (if (member v (list "playing" "queued"))
              (begin
                (message (string-append "Playing " what))
                ;; the bar shows the choice at once; i reads the player back
                (spotify--now-set! (plist-put (plist-put *spotify-now* 'title what) 'playing #t)))
              (message (string-append "Spotify: the player did not answer for " what))))))))

(define (spotify--section-path page)
  (let ((path (plist-get page 'path))) (if (procedure? path) (path) path)))

(define (spotify--play-track! context label href name)
  ;; in its list when the row carries its button's label, else on its own page.
  ;; A JSON string is a CSS string too, quotes and backslashes escaped
  (if (and (string? label) (string-prefix? "Play " label))
      (spotify--play! context (string-append "main button[aria-label=" (json-encode label) "]") name)
      (spotify--play! href spotify--entity-play name)))

(define (spotify--play-row! buf row)
  (let ((name (site-app-field row 'name)))
    (if (equal? (site-app-field row 'kind) "track")
        (spotify--play-track! (spotify--section-path (site-app-current-page buf))
                              (site-app-field row 'play) (site-app-field row 'href) name)
        (spotify--play! (site-app-field row 'href) spotify--entity-play name))))

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

;;; --- the app ------------------------------------------------------------------

(domain! 'web)
(effects! '(write external display))

(define *spotify-rows-sheet* (locate-library "web/parsers/spotify-rows.xsl"))
(define *spotify-detail-sheet* (locate-library "web/parsers/spotify-detail.xsl"))
(define *spotify-artist-sheet* (locate-library "web/parsers/spotify-artist.xsl"))

;; what a page shows once it has drawn: its track rows, or its cards
(define spotify--wait "main [data-testid=tracklist-row], main [data-encore-id=card]")

(define *spotify-query* "")

(define (spotify--row buf row)
  ;; a list row is a row, not a fold: the card's fold marker stays off it
  (let* ((f (lambda (k) (site-app-field row k)))
         ;; a card has a shelf, even a song's (a music video); a track row has none
         (block (if (and (equal? (f 'kind) "track") (not (plist-get row 'shelf)))
                    (component 'spotify/track
                      (list 'title (f 'name) 'icon (f 'art) 'badge (f 'index) 'artists (f 'artists)
                            'album (f 'album) 'duration (f 'duration) 'playing? (spotify--playing? (f 'name))))
                    (component 'spotify/tile
                      (list 'title (f 'name) 'icon (f 'art) 'badge (f 'kind) 'tags (list (f 'sub)))))))
    (let strip ((ps block) (acc '()))
      (cond ((or (null? ps) (null? (cdr ps))) (reverse acc))
            ((eq? (car ps) 'anchor-data) (strip (cddr ps) acc))
            (else (strip (cddr ps) (cons (cadr ps) (cons (car ps) acc))))))))

(define (spotify--section id label key path wait)
  (list 'id id 'label label 'key key 'path path
        'live #t 'wait wait
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
  (let ((f (buffer-local (site-app-page-buffer 'spotify 'results) 'site-app-filter)))
    (if (member f (list "tracks" "albums" "artists" "playlists")) f "tracks")))

(define (spotify--define-app!)
 (define-site-app
  (list 'name 'spotify
        'title "Spotify"
        'base-url "https://open.spotify.com"
        'home "/"
        'home-page 'home
        'detail-mode "spotify-detail-mode"
        'detail-name (lambda (row) (site-app-field row 'name))
        ;; the player bar heads every section
        'list-head (lambda (buf)
                     (spotify--ticker-start!)
                     (list (component 'spotify/search-bar (list 'query *spotify-query*))
                           (component 'spotify/now-playing (spotify--now-props))))
        ;; on an item's page: a track plays, a tile opens beside the list
        'card-keys (list (list "sp-track" (list (list "RET" "spotify-play" "play") (list "p" "spotify-play" "play")))
                         (list "sp-tile" (list (list "RET" "spotify-open" "open") (list "p" "spotify-play" "play"))))
        'pages
        (list (spotify--section 'home "Home" "1" "/" "main [data-encore-id=card]")
              (spotify--section 'liked "Liked Songs" "2" "/collection/tracks" "main [data-testid=tracklist-row]")
              (spotify--section 'playlists "Playlists" "3"
                                (lambda () (if (equal? spotify-user "") "/" (string-append "/user/" spotify-user "/playlists")))
                                "main [data-encore-id=card]")
              ;; a search reads one category's page, the tab that is on: Songs,
              ;; Albums, Artists or Playlists. Each draws whole, with its details
              (append (list 'tabs-sheet (locate-library "web/parsers/spotify-search-tabs.xsl"))
                      (spotify--section 'results "Search" "4"
                                        (lambda () (string-append "/search/" (url-encode *spotify-query*)
                                                                  "/" (spotify--search-category)))
                                        spotify--wait)))))
 (spotify--bind-keys!))

;; a control in the player bar is clicked as spotify:COMMAND
(add-hook! (list 'block-click 'spotify)
  (lambda (buf id)
    (if (and (string? id) (string-prefix? "spotify:" id))
        (begin (run-command (substring id 8 (string-length id))) #t)
        #f)))

;;; --- commands -----------------------------------------------------------------

;;;###autoload
(define-command "spotify" "Open Spotify as an app: Home, Liked Songs, Playlists and Search"
  (lambda ()
    (site-app-open! 'spotify)
    (spotify-now-refresh!)))

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
  (lambda () (spotify--control! (spotify--click-js "control-button-playpause" "play/pause") 'playing)))

(define-command "spotify-next" "Play the next track"
  (lambda () (spotify--control! (spotify--click-js "control-button-skip-forward" "next") #f)))

(define-command "spotify-previous" "Play the previous track"
  (lambda () (spotify--control! (spotify--click-js "control-button-skip-back" "previous") #f)))

(define-command "spotify-like" "Save the current track to your library, or take it out"
  (lambda () (spotify--control! (spotify--click-sel-js spotify--like-sel "liked") 'liked)))

;;;###autoload
(define-command "spotify-now-playing" "Say what is playing, and redraw the player bar"
  (lambda ()
    (spotify-now-refresh!
      (lambda (now)
        (message (if (and (pair? now) (not (equal? (plist-get now 'title) "")))
                     (string-append (plist-get now 'title) " — " (plist-get now 'artists))
                     "nothing playing"))))))

(define-command "spotify-volume-up" "Raise the player's volume"
  (lambda () (spotify--eval (spotify--volume-js "0.1") (lambda (v) (message (if (string? v) v "Spotify: no answer"))))))

(define-command "spotify-volume-down" "Lower the player's volume"
  (lambda () (spotify--eval (spotify--volume-js "-0.1") (lambda (v) (message (if (string? v) v "Spotify: no answer"))))))

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

(define *spotify-now-buffer* "*spotify-now*")
(define *spotify-albums* '())    ; (HREF . what the album page says)
(define *spotify-artists* '())   ; (HREF . what the artist page says)
(define *spotify-news* '())      ; (ARTIST . stories)
(define *spotify-asked* '())     ; what has been asked for, so it is asked once

(define (spotify--without x xs) (filter (lambda (y) (not (equal? y x))) xs))
(define (spotify--cached alist key) (let ((hit (assoc key alist))) (and hit (cdr hit))))
(define (spotify--now-field k) (or (plist-get *spotify-now* k) ""))

;; the reader tab reads one page at a time, so the album and the artist are
;; read one after the other, and each only once
(define (spotify--read-page! href sheet k)
  ;; an album or an artist page is read once its tracks have drawn: its cards
  ;; draw first, and a read at the first card misses the popular tracks
  (site-app-navigate! 'spotify (string-append "https://open.spotify.com" href) "main [data-testid=tracklist-row]"
    (lambda (tab answer) (k (and answer (site-app-parse sheet (plist-get answer 'html)))))))

(define (spotify--ask! key) (if (member key *spotify-asked*) #f (begin (set! *spotify-asked* (cons key *spotify-asked*)) #t)))

(define (spotify--news-of! artist)
  ;; a web search, off the lane; a failed one may be asked again
  (when (and (not (equal? artist "")) (spotify--ask! (string-append "news:" artist)))
    (task-run!
      (lambda () (mcp-call! 'google-search "search" (json-encode (list 'query (string-append artist " music news") 'num 8))))
      (lambda (ok text)
        (let ((items (and ok (string? text) (string-prefix? "[" (string-trim text)) (json-parse text))))
          (if (not ok)
              (set! *spotify-asked* (spotify--without (string-append "news:" artist) *spotify-asked*))
              (set! *spotify-news* (cons (cons artist (if (pair? items) items '())) *spotify-news*)))
          (spotify--now-draw!)))
      30000)))

(define *spotify-reading* #f)

(define (spotify--context!)
  ;; what the page needs that it has not read: the album, then the artist, then
  ;; the news. One read at a time: the reader tab has one page, and a second
  ;; read would take it from under the first. When the chain ends it looks
  ;; again, for music that moved on while it read
  (let ((album (spotify--now-field 'albumHref))
        (artist (spotify--now-field 'artistHref))
        (artist-name (car (string-split (spotify--now-field 'artists) ","))))
    (spotify--news-of! artist-name)
    (unless *spotify-reading*
      (let* ((done (lambda () (set! *spotify-reading* #f) (spotify--now-draw!)))
             (step (lambda (href sheet store! k)
                     (spotify--read-page! href sheet
                       (lambda (data)
                         (store! data)
                         (unless data (set! *spotify-asked* (spotify--without href *spotify-asked*)))
                         (spotify--now-draw!)
                         (k)))))
             (read-artist
               (lambda ()
                 (if (and (not (equal? artist "")) (spotify--ask! artist))
                     (step artist *spotify-artist-sheet*
                           (lambda (data) (set! *spotify-artists* (cons (cons artist data) *spotify-artists*)))
                           (lambda () (done) (spotify--context!)))
                     (done)))))
        (set! *spotify-reading* #t)
        (if (and (not (equal? album "")) (spotify--ask! album))
            (step album *spotify-detail-sheet*
                  (lambda (data) (set! *spotify-albums* (cons (cons album data) *spotify-albums*)))
                  read-artist)
            (read-artist))))))

(define (spotify--album-facts href)
  ;; (NAME RELEASED) from the album page's head: the whole date, else the year
  (let* ((data (spotify--cached *spotify-albums* href))
         (hero (and data (let ((s (site-app-real (plist-get data 'section)))) (and (pair? s) (car s)))))
         (tags (if hero (or (plist-get hero 'tags) '()) '()))
         (released (or (find (lambda (t) (string-prefix? "Released " t)) tags)
                       (find (lambda (t) (re-match? "^[0-9]{4}$" t)) tags) "")))
    (list (if hero (spotify--card-title hero) "") released)))

(define (spotify--section-title text) (list 'tag "div" 'class "sp-np-section" 'text text))
(define (spotify--quiet text) (list 'tag "div" 'class "sp-np-empty" 'text text))
(define (spotify--host url)
  (let* ((rest (if (string-index url "://") (substring url (+ 3 (string-index url "://")) (string-length url)) url))
         (host (car (string-split rest "/"))))
    (if (string-prefix? "www." host) (substring host 4 (string-length host)) host)))

(define (spotify--now-blocks)
  (let* ((title (spotify--now-field 'title))
         (album-href (spotify--now-field 'albumHref))
         (artist-href (spotify--now-field 'artistHref))
         (album (spotify--album-facts album-href))
         (artist (spotify--cached *spotify-artists* artist-href))
         (name (if artist (plist-get artist 'name) (car (string-split (spotify--now-field 'artists) ","))))
         (news (spotify--cached *spotify-news* name)))
    (if (equal? title "")
        (list (spotify--quiet "Nothing is playing. Play something with p in any Spotify section."))
        (append
          (list (component 'spotify/np-hero
                  (list 'title title 'artists (spotify--now-field 'artists) 'art (spotify--hires (spotify--now-field 'art))
                        'album (car album) 'released (cadr album)
                        'click (string-append "spotify-open:" album-href "|" (car album))
                        'playing? (eq? (plist-get *spotify-now* 'playing) #t) 'liked? (eq? (plist-get *spotify-now* 'liked) #t)
                        'position (spotify--now-field 'position) 'duration (spotify--now-field 'duration))))
          (cond
            ((not artist) (list (spotify--quiet (string-append "Reading " name "'s page…"))))
            (else
             (let ((popular (let ((ps (or (plist-get artist 'popular) '()))) (if (> (length ps) 5) (list-head ps 5) ps)))
                   (tour (let ((ts (filter (lambda (g) (equal? (plist-get g 'artist) name)) (or (plist-get artist 'tour) '()))))
                           (if (> (length ts) 6) (list-head ts 6) ts)))
                   (discog (or (plist-get artist 'discog) '())))
               (append
                 (if (null? popular) '()
                     (cons (spotify--section-title "Popular")
                           (map (lambda (t)
                                  (plist-put (component 'spotify/track
                                               (list 'title (plist-get t 'name) 'icon (plist-get t 'art) 'badge (plist-get t 'index)
                                                     'artists (let ((n (or (plist-get t 'plays) ""))) (if (equal? n "") "" (string-append n " plays"))) 'duration (plist-get t 'duration)
                                                     'playing? (equal? (plist-get t 'name) title)))
                                             'click (string-append "spotify-play:" artist-href "|" (or (plist-get t 'play) ""))))
                                popular)))
                 (if (null? tour) '()
                     (cons (spotify--section-title "On tour")
                           (map (lambda (g)
                                  (component 'spotify/gig
                                    (list 'month (plist-get g 'month) 'day (plist-get g 'day) 'city (plist-get g 'city)
                                          'venue (plist-get g 'venue) 'when (plist-get g 'when)
                                          'click (string-append "spotify-url:https://open.spotify.com" (plist-get g 'href)))))
                                tour)))
                 (list (spotify--section-title "About")
                       (component 'spotify/artist-card
                         (list 'name name 'image (or (plist-get artist 'image) "") 'listeners (or (plist-get artist 'listeners) "")
                               'verified? (equal? (plist-get artist 'verified) "yes") 'bio (or (plist-get artist 'bio) ""))))
                 (if (null? discog) '()
                     (list (spotify--section-title "Discography")
                           (component 'ui/group
                             (list 'class "sp-shelf"
                                   'body (map (lambda (d)
                                                (plist-put (component 'spotify/tile
                                                             (list 'title (plist-get d 'name) 'icon (plist-get d 'art)
                                                                   'badge (plist-get d 'kind) 'tags (list (plist-get d 'sub))))
                                                           'click (string-append "spotify-open:" (plist-get d 'href) "|" (plist-get d 'name))))
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
                          (component 'spotify/news-item
                            (list 'title (or (plist-get n 'title) "") 'source (spotify--host (or (plist-get n 'link) ""))
                                  'date date 'snippet body 'click (string-append "spotify-url:" (or (plist-get n 'link) ""))))))
                      news)))))))

(define (spotify--now-draw!)
  (let ((buf *spotify-now-buffer*))
    (when (buffer-exists? buf)
      (let ((text (string-append (spotify--now-field 'title) "\n" (spotify--now-field 'artists) "\n")))
        (buffer-set-text! buf text #t)
        (buffer-set-locals! buf
          (list 'render-mode "blocks"
                'render-blocks (list (component 'ui/page (list 'body (spotify--now-blocks))))))))))

(define-mode "spotify-now-mode" (lambda () (buffer-set-read-only! (current-buffer) #t)))
(mode-doc! "spotify-now-mode" "What plays now, with its album, the artist's popular tracks, tour dates, bio, discography and news. P plays or pauses, . and , skip, l likes, = and - set the volume, g reads the artist again, q quits.")

;;;###autoload
(define-command "spotify-now-page" "Show what is playing, with the artist's tours, bio, discography and news"
  (lambda ()
    (let ((buf *spotify-now-buffer*)
          (from (current-buffer)))
      (unless (buffer-exists? buf)
        (buffer-create buf)
        (with-current-buffer buf (lambda () (set-mode! "spotify-now-mode"))))
      (site-app-join-group! buf)
      (spotify--now-draw!)
      (if (equal? from buf) #t (display-buffer-detail! buf from))
      (spotify-now-refresh! (lambda (now) (spotify--context!))))))

(define-command "spotify-now-reload" "Read the album, the artist and the news of what plays again"
  (lambda ()
    (let ((album (spotify--now-field 'albumHref)) (artist (spotify--now-field 'artistHref))
          (name (car (string-split (spotify--now-field 'artists) ","))))
      (set! *spotify-asked* (filter (lambda (k) (not (member k (list album artist (string-append "news:" name))))) *spotify-asked*))
      (set! *spotify-albums* (filter (lambda (a) (not (equal? (car a) album))) *spotify-albums*))
      (set! *spotify-artists* (filter (lambda (a) (not (equal? (car a) artist))) *spotify-artists*))
      (set! *spotify-news* (filter (lambda (a) (not (equal? (car a) name))) *spotify-news*))
      (spotify--now-draw!)
      (spotify--context!))))

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
                 (site-app-show-detail! (spotify--section-ready! 'home)
                   (list 'key href 'href href 'name (if (equal? (cadr p) "") href (cadr p)))))
               #t))
            ((string-prefix? "spotify-play:" id)
             (let ((p (split (after "spotify-play:"))))
               (spotify--play-track! (car p) (cadr p) "" (if (string-prefix? "Play " (cadr p)) (substring (cadr p) 5 (string-length (cadr p))) ""))
               #t))
            ((string-prefix? "spotify-url:" id) (tab-open (after "spotify-url:")) #t)
            (else #f)))))

;;; --- keys ---------------------------------------------------------------------
;;; The same keys in every section and on every item's page. `C-c S` reaches
;;; the player from anywhere; lowercase `C-c s` is the scratch buffer's.

(define *spotify-keys*
  (list (list "p" "spotify-play") (list "P" "spotify-play-pause")
        (list "." "spotify-next") (list "," "spotify-previous")
        (list "l" "spotify-like") (list "i" "spotify-now-playing")
        (list "=" "spotify-volume-up") (list "-" "spotify-volume-down")
        (list "/" "spotify-search") (list "N" "spotify-now-page")))

(define (spotify--bind-keys!)
  ;; define-site-app makes each section's keymap afresh, / as its status
  ;; filter, so these go on after it every time
  (for-each (lambda (mode)
              (for-each (lambda (k) (define-key (mode-keymap mode) (car k) (cadr k))) *spotify-keys*))
            (cons "spotify-now-mode" (cons "spotify-detail-mode"
                  (map (lambda (page) (site-app-page-mode 'spotify (plist-get page 'id)))
                       (site-app-pages (site-app-spec 'spotify))))))
  (define-key (mode-keymap "spotify-now-mode") "g" "spotify-now-reload")
  (define-key (mode-keymap "spotify-now-mode") "q" "quit-window"))

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
              ;; the tab you were on stays on; the first search is for songs
              (buffer-set-local! buf 'site-app-filter (spotify--search-category))
              (buffer-set-local! buf 'site-app-rows '())
              (list-refresh! buf)
              (if pane
                  (with-frame-windows (lambda () (window-set-buffer! pane buf)))
                  (switch-to-buffer! buf))
              (site-app-read-page! 'spotify (site-app-page (site-app-spec 'spotify) 'results))))))))
(define-key "spotify-map" "g" "spotify")
(define-key "spotify-map" "N" "spotify-now-page")
(define-key "spotify-map" "<up>" "spotify-volume-up")
(define-key "spotify-map" "<down>" "spotify-volume-down")

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
        (begin (tab-open spotify-url) "No Spotify tab was open. I opened one — sign in, then ask again.")
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
    "pause, next, previous, now-playing, like, search, volume. "
    "query names music in words, like \"blackwater park opeth\". "
    "level is 0-100, for volume.")
  '((action "string" "play, pause, next, previous, now-playing, like, search or volume")
    (query "string" "the music to find, in words" optional)
    (level "number" "volume from 0 to 100" optional))
  (lambda (args)
    (spotify--do (or (plist-get args 'action) "now-playing")
                 (plist-get args 'query)
                 (plist-get args 'level)))
  '(write external))
