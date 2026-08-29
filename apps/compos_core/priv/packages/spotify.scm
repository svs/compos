;;; spotify.scm --- the web player is a tab, and this is its remote control.
;;;
;;; The music plays in Chrome, where it already knows who you are. compos
;;; does not play it and does not proxy it: it finds the tab and presses the
;;; buttons. chrome.scm supplies the wire (tab-list, tab-eval, tab-open), so
;;; this file is policy only — no new Elixir, no API keys, no OAuth.
;;;
;;; The player is a web page, so the buttons are DOM nodes. Spotify names
;;; them with `data-testid`, which is the most stable handle the page gives
;;; us. If Spotify renames one, one string in this file changes.

(defgroup 'spotify "The Spotify web player, driven from the editor.")

(defcustom 'spotify-url "https://open.spotify.com/"
  "The page the player runs in." 'group 'spotify)

;;; --- finding the tab ----------------------------------------------------------

(define (spotify--tab? t)
  (let ((u (chrome--get t 'url)))
    (and (string? u) (string-prefix? "https://open.spotify.com" u))))

;; Every command starts here. With no player tab open we open one and say so,
;; because a command that silently does nothing reads like a broken editor.
(define (spotify-tab k)
  (tab-list
    (lambda (tabs)
      (let ((hits (filter spotify--tab? (or tabs '()))))
        (if (null? hits)
            (begin
              (tab-open spotify-url)
              (message "Opened the Spotify tab — sign in there, then try again"))
            (k (car hits)))))))

;; The page's own world, not the isolated one. The isolated world runs the
;; code as a string, and an extension may not do that under MV3: Spotify
;; answers "Evaluating a string as JavaScript violates the following Content
;; Security Policy directive". Chrome injects a main-world call itself, so
;; the same code runs there. Both worlds see the same DOM, which is all a
;; button press needs.
(define (spotify--eval code k) (spotify-tab (lambda (t) (tab-eval-main t code k))))

(define (spotify--say v) (message (if (string? v) v "Spotify: no answer")))

;;; --- the same verbs, waited on ------------------------------------------------
;;; A key press can answer in the echo area whenever the page gets round to it.
;;; The assistant cannot: a tool has to RETURN what the page said, inside the
;;; turn that asked. These are the waiting versions, and every one of them says
;;; something a person could read out loud.

(define (spotify--tab-id-sync)
  (let ((r (browser-call-sync "tabs" '() 2000)))
    (if (chrome--get r 'ok)
        (let ((hits (filter spotify--tab? (or (chrome--get r 'tabs) '()))))
          (if (null? hits) #f (chrome--tab-id (car hits))))
        #f)))

(define (spotify--eval-sync code)
  (let ((id (spotify--tab-id-sync)))
    (if (not id)
        (begin (tab-open spotify-url) "No Spotify tab was open. I opened one — sign in, then ask again.")
        (let ((r (browser-call-sync "eval" (list 'tab id 'code code 'world "main") 4000)))
          (if (chrome--get r 'ok)
              (let ((v (chrome--get r 'value))) (if (string? v) v "done"))
              (string-append "the player did not answer: "
                             (or (chrome--get r 'error) "unknown error")))))))

;;; --- the buttons --------------------------------------------------------------
;;; One JS expression per verb. Each one reports back in words, so the echo
;;; area says what happened instead of staying empty.

(define (spotify--click-sel-js sel what)
  (string-append
    "(function(){var b=document.querySelector(" (json-encode sel) ");"
    "if(!b)return 'no player controls — is the tab loaded?';"
    "b.click();return '" what "';})()"))

(define (spotify--click-js testid what)
  (spotify--click-sel-js (string-append "[data-testid=\"" testid "\"]") what))

;; The player names the block around the track two ways, and only one of them
;; exists before the first track plays.
(define spotify--now-sel
  "[data-testid=\"now-playing-widget\"],[data-testid=\"now-playing-bar\"]")

;; The track first, because the bar's own aria-label is the furniture ("Now
;; playing bar") and says nothing about the music.
(define spotify--now-js
  (string-append
    "(function(){"
    "var q=function(s){var e=document.querySelector(s);"
    "return e&&(e.innerText||e.textContent||'').trim()};"
    "var t=q('[data-testid=\"context-item-link\"]');"
    "var a=q('[data-testid=\"context-item-info-artist\"]');"
    "if(t)return a?t+' — '+a:t;"
    "var w=document.querySelector(" (json-encode spotify--now-sel) ");"
    "var l=w&&w.getAttribute('aria-label');"
    "if(l&&l.indexOf('Now playing')!==0)return l;"
    "return 'nothing playing';})()"))

(define-command "spotify-play-pause" "Play or pause the Spotify tab"
  (lambda ()
    (spotify--eval (spotify--click-js "control-button-playpause" "play/pause") spotify--say)))

(define-command "spotify-next" "Play the next track"
  (lambda ()
    (spotify--eval (spotify--click-js "control-button-skip-forward" "next") spotify--say)))

(define-command "spotify-previous" "Play the previous track"
  (lambda ()
    (spotify--eval (spotify--click-js "control-button-skip-back" "previous") spotify--say)))

(define spotify--like-sel
  (string-append "[data-testid=\"now-playing-widget\"] [data-testid=\"add-button\"],"
                 "[data-testid=\"now-playing-bar\"] [data-testid=\"add-button\"]"))

(define-command "spotify-like" "Save the current track to your library"
  (lambda ()
    (spotify--eval (spotify--click-sel-js spotify--like-sel "liked") spotify--say)))

(define-command "spotify-now-playing" "Say what is playing"
  (lambda () (spotify--eval spotify--now-js spotify--say)))

;;; --- volume -------------------------------------------------------------------
;;; The volume slider is a custom widget, so we set the media element instead.
;;; The player's own slider does not move, but the sound does.

(define (spotify--volume-js delta)
  (string-append
    "(function(){var m=document.querySelector('video,audio');"
    "if(!m)return 'no sound yet';"
    "m.volume=Math.min(1,Math.max(0,m.volume+(" delta ")));"
    "return 'volume '+Math.round(m.volume*100)+'%';})()"))

(define-command "spotify-volume-up" "Raise the player's volume"
  (lambda () (spotify--eval (spotify--volume-js "0.1") spotify--say)))

(define-command "spotify-volume-down" "Lower the player's volume"
  (lambda () (spotify--eval (spotify--volume-js "-0.1") spotify--say)))

;;; --- search and reach ---------------------------------------------------------

(define (spotify--search-js q)
  (string-append
    "(function(){location.href='https://open.spotify.com/search/'"
    "+encodeURIComponent(" (json-encode q) ");return 'searching';})()"))

(define-command "spotify-search" "Search Spotify in its own tab"
  (lambda ()
    (minibuffer-read "Spotify: " '()
      (lambda (q)
        (if (equal? q "")
            (message "Nothing to search for")
            (spotify-tab
              (lambda (t)
                (tab-eval t (spotify--search-js q) (lambda (v) #t))
                (tab-activate t)
                (message (string-append "Spotify: " q)))))))))

(define-command "spotify" "Bring the Spotify tab to the front"
  (lambda ()
    (spotify-tab (lambda (t) (tab-activate t) (message "Spotify")))))

;;; --- saying it in words -------------------------------------------------------
;;; "play blackwater park", "louder", "what is this?" — the assistant reaches
;;; the player through one tool, and every branch of it answers in a sentence.

;; Play and pause are not the same key twice. "Pause the music" must never
;; start it, so we read the button before we press it.
(define (spotify--want-js want)
  (string-append
    "(function(){var b=document.querySelector('[data-testid=\"control-button-playpause\"]');"
    "if(!b)return 'no player controls — is the tab loaded?';"
    "var playing=/pause/i.test(b.getAttribute('aria-label')||'');"
    "var want=" (json-encode want) ";"
    "if(want==='play'&&!playing){b.click();return 'playing'}"
    "if(want==='pause'&&playing){b.click();return 'paused'}"
    "return playing?'already playing':'already paused';})()"))

(define (spotify--goto-search-js q)
  (string-append
    "(function(){location.href='https://open.spotify.com/search/'"
    "+encodeURIComponent(" (json-encode q) ");return 'searching';})()"))

;; The sidebar has play buttons too, and its playlists are not what you asked
;; for. Only the main region counts, and the words you said outrank the order
;; Spotify chose.
(define (spotify--play-match-js q)
  (string-append
    "(function(){var root=document.querySelector('main')||document;"
    "var bs=Array.from(root.querySelectorAll('button')).filter(function(e){"
    "return e.dataset&&e.dataset.testid==='play-button'});"
    "if(!bs.length)return '';"
    "var ws=" (json-encode q) ".split(/\\s+/).map(function(w){return w.replace(/[^\\w]/g,'')})"
    ".filter(function(w){return w.length>2});"
    "var hit=ws.length?bs.filter(function(e){var l=e.getAttribute('aria-label')||'';"
    "return ws.some(function(w){return new RegExp(w,'i').test(l)})})[0]:null;"
    "var b=hit||bs[0];b.click();return b.getAttribute('aria-label')||'the first result';})()"))

;; Search, then wait for the results to draw. Each try is a real round trip to
;; the page, so the loop paces itself and stops the moment a button appears.
(define (spotify-play-query q)
  (spotify--eval-sync (spotify--goto-search-js q))
  (let loop ((n 25))
    (if (= n 0)
        (string-append "I searched for " q " but no result appeared in time")
        (let ((r (spotify--eval-sync (spotify--play-match-js q))))
          (if (or (equal? r "") (string-prefix? "the player did not answer" r))
              (loop (- n 1))
              (string-append "playing " r))))))

(define (spotify--volume-set-js pct)
  (string-append
    "(function(){var m=document.querySelector('video,audio');"
    "if(!m)return 'no sound yet — start something playing first';"
    "m.volume=Math.min(1,Math.max(0," (number->string pct) "/100));"
    "return 'volume '+Math.round(m.volume*100)+'%';})()"))

(define (spotify--do action query level)
  (cond
    ((equal? action "now-playing") (spotify--eval-sync spotify--now-js))
    ((equal? action "next") (spotify--eval-sync (spotify--click-js "control-button-skip-forward" "next track")))
    ((equal? action "previous") (spotify--eval-sync (spotify--click-js "control-button-skip-back" "previous track")))
    ((equal? action "pause") (spotify--eval-sync (spotify--want-js "pause")))
    ((equal? action "play-pause") (spotify--eval-sync (spotify--want-js "toggle")))
    ((equal? action "like") (spotify--eval-sync (spotify--click-sel-js spotify--like-sel "liked")))
    ((equal? action "volume")
     (if (number? level)
         (spotify--eval-sync (spotify--volume-set-js level))
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
    (spotify--do (or (custom--plist-get args 'action) "now-playing")
                 (custom--plist-get args 'query)
                 (custom--plist-get args 'level)))
  '(write external))

;;; --- keys ---------------------------------------------------------------------
;;; `C-c S` is the player's prefix. Lowercase `C-c s` belongs to the
;;; editor-wide scratch buffer command.

(global-set-key "C-c S s" "spotify-play-pause")
(global-set-key "C-c S n" "spotify-next")
(global-set-key "C-c S p" "spotify-previous")
(global-set-key "C-c S i" "spotify-now-playing")
(global-set-key "C-c S l" "spotify-like")
(global-set-key "C-c S /" "spotify-search")
(global-set-key "C-c S g" "spotify")
(global-set-key "C-c S <up>" "spotify-volume-up")
(global-set-key "C-c S <down>" "spotify-volume-down")
