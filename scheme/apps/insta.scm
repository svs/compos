;;; insta.scm --- the Instagram feed as an app: one row per post, one page per post.
;;;
;;; The rows come from Instagram's own web API, called from inside a tab of
;;; the user's Chrome that is already on instagram.com, so the feed is the
;;; account's own and nothing of the browser moves. Any instagram.com tab
;;; will do; the app never opens or focuses one by itself.

;; the major modes this file defines: a buffer restored in one loads the file
;;;###autoload
(autoload-modes "insta-mode" "insta-detail-mode")

(domain! 'web)
(effects! '(pure))

(define *insta-buffer* "*insta*")
(define *insta-log* "*insta-log*")
(define *insta-app-id* "insta")

(define (insta--text v) (if (string? v) v (if v (value->string v) "")))
(define (insta--n v) (if (number? v) (number->string v) (insta--text v)))
(define (insta--put plist key value)
  (cond ((null? plist) (list key value))
        ((equal? (car plist) key) (cons key (cons value (cddr plist))))
        (else (cons (car plist) (cons (cadr plist) (insta--put (cddr plist) key value))))))
(define (insta--clip s n)
  (if (> (string-length s) n) (string-append (substring s 0 (- n 1)) "…") s))

;; The feed, cut down in the tab to what a row and a page need. MAX-ID pages.
(define (insta--feed-js max-id)
  (string-append
    "(()=>{const c=(document.cookie.match(/csrftoken=([^;]+)/)||[])[1];"
    "const x=new XMLHttpRequest();x.open('POST','/api/v1/feed/timeline/',false);"
    "x.setRequestHeader('x-ig-app-id','936619743392459');x.setRequestHeader('x-csrftoken',c);"
    "x.setRequestHeader('content-type','application/x-www-form-urlencoded');"
    "x.send('is_async_ads_rti=0&is_pull_to_refresh=0&reason="
    (if max-id "pagination&max_id=" "cold_start_fetch")
    (if max-id (url-encode max-id) "")
    "');if(x.status!==200)return 'ERROR '+x.status;const d=JSON.parse(x.responseText);"
    "const now=Date.now()/1000;const ago=t=>{const s=now-t;return s<3600?Math.round(s/60)+'m':s<86400?Math.round(s/3600)+'h':Math.round(s/86400)+'d'};"
    "const img=m=>{const v=((m.image_versions2||(m.carousel_media&&m.carousel_media[0].image_versions2))||{}).candidates||[];return v.length?v[0].url:''};"
    "const posts=(d.feed_items||[]).map(i=>i.media_or_ad).filter(m=>m&&m.user&&m.code).map(m=>({"
    "id:m.id,pk:String(m.pk),code:m.code,user:m.user.username,name:m.user.full_name||'',ago:ago(m.taken_at),"
    "caption:(m.caption&&m.caption.text)||'',line:((m.caption&&m.caption.text)||'').replace(/\\s+/g,' ').slice(0,240),"
    "likes:m.like_count||0,comments:m.comment_count||0,"
    "kind:m.media_type===2?'video':m.media_type===8?'album':'photo',ad:!!(m.ad_id||m.ad_action),"
    "img:img(m),alt:m.accessibility_caption||'',liked:!!m.has_liked,saved:!!m.has_viewer_saved}));"
    "return JSON.stringify({next:d.more_available?(d.next_max_id||''):'',posts})})()"))

(define (insta--comments-js pk)
  (string-append
    "(()=>{const x=new XMLHttpRequest();x.open('GET','/api/v1/media/" pk
    "/comments/?can_support_threading=true&permalink_enabled=false',false);"
    "x.setRequestHeader('x-ig-app-id','936619743392459');x.send();"
    "if(x.status!==200)return 'ERROR '+x.status;const d=JSON.parse(x.responseText);"
    "return JSON.stringify((d.comments||[]).slice(0,40).map(c=>({user:c.user.username,text:c.text,likes:c.comment_like_count||0})))})()"))

(define (insta--like-js pk like?)
  (string-append
    "(()=>{const c=(document.cookie.match(/csrftoken=([^;]+)/)||[])[1];"
    "const x=new XMLHttpRequest();x.open('POST','/api/v1/web/likes/" pk
    (if like? "/like/" "/unlike/") "',false);"
    "x.setRequestHeader('x-ig-app-id','936619743392459');x.setRequestHeader('x-csrftoken',c);"
    "x.send();return String(x.status)})()"))

(define (insta--post-url post)
  (string-append "https://www.instagram.com/p/" (plist-get post 'code) "/"))

(effects! '(write display))
(define (insta-join-group! buf &optional role)
  (when (buffer-exists? buf)
    (app-claim! buf *insta-app-id* (or role 'aux))
    (buffer-join-here! buf))
  buf)
(define (insta-log! text)
  (unless (buffer-exists? *insta-log*) (buffer-create *insta-log*))
  (buffer-append! *insta-log* (string-append text "\n")))

;;; --- the tab ---------------------------------------------------------------

(effects! '(read external execute))
(define (insta--tab k)
  "Give K the id of an open instagram.com tab, or #f."
  (tab-list
    (lambda (tabs)
      (let loop ((rest tabs))
        (cond ((null? rest) (k #f))
              ((string-prefix? "https://www.instagram.com/" (insta--text (plist-get (car rest) 'url)))
               (k (plist-get (car rest) 'id)))
              (else (loop (cdr rest))))))))
(define (insta--call js k)
  "Run JS in the Instagram tab; K gets the parsed answer, or #f."
  (insta--tab
    (lambda (tab)
      (if (not tab)
          (begin (message "Open instagram.com in Chrome, then press g") (k #f))
          (tab-eval tab js
            (lambda (text)
              (let ((v (and (string? text) (not (string-prefix? "ERROR" text)) (json-parse text))))
                (unless v
                  (insta-log! (string-append "Instagram call failed: " (insta--clip (insta--text text) 300)))
                  (message (string-append "Instagram did not answer. See " *insta-log*)))
                (k v))))))))

;;; --- the listing -----------------------------------------------------------

(effects! '(write external display))
(define (insta--rows buf) (or (buffer-local buf 'insta-rows) '()))
(define (insta--set-rows! rows)
  (buffer-set-local! *insta-buffer* 'insta-rows rows)
  (list-refresh! *insta-buffer*)
  rows)
(define (insta--row-by-id id)
  (let loop ((rows (insta--rows *insta-buffer*)))
    (cond ((null? rows) #f)
          ((equal? (plist-get (car rows) 'id) id) (car rows))
          (else (loop (cdr rows))))))
(define (insta--update-row! row)
  (insta--set-rows!
    (map (lambda (old) (if (equal? (plist-get old 'id) (plist-get row 'id)) row old))
         (insta--rows *insta-buffer*))))

(define (insta-fetch! more? k)
  "Read the feed; with MORE? the next page after the rows already here."
  (let ((next (and more? (buffer-local *insta-buffer* 'insta-next))))
    (if (and more? (not next))
        (begin (message "No more posts in the feed") (k #f))
        (insta--call (insta--feed-js next)
          (lambda (d)
            (when d
              (let ((n (plist-get d 'next)))
                (buffer-set-local! *insta-buffer* 'insta-next
                                   (and (string? n) (not (equal? n "")) n))))
            (k (and d (plist-get d 'posts))))))))

(define (insta-sync! &optional more? pages)
  "Fetch the feed and redraw the listing; with MORE? add the next page.
The feed answers a few posts a page, so a read goes on, up to five pages,
until the listing holds a dozen."
  (insta-listing!)
  (message (if more? "Reading more of the Instagram feed..." "Reading the Instagram feed..."))
  (let ((frame (selected-frame)))
    (insta-fetch! more?
      (lambda (posts)
        (when posts
          (insta--set-rows! (if more? (append (insta--rows *insta-buffer*) posts) posts))
          (with-selected-frame frame
            (lambda ()
              (unless more? (insta-show-detail! (list-current *insta-buffer*)))
              (if (and (< (length (insta--rows *insta-buffer*)) 12) (< (or pages 0) 5)
                       (buffer-local *insta-buffer* 'insta-next))
                  (insta-sync! #t (+ 1 (or pages 0)))
                  (message (string-append (number->string (length (insta--rows *insta-buffer*)))
                                          " posts in the feed"))))))))))

;;; --- the post page ---------------------------------------------------------

(define insta-detail-css
  "<style>:root{color-scheme:light dark}html{font-size:clamp(13px,.8vw,30px)}body{margin:0;padding:1.2rem 1.4rem;font:1rem/1.55 system-ui,sans-serif;color:var(--default-fg)}.h{font-size:1.15rem}.h b{font-weight:700}.dim{color:var(--dim-fg)}.ad{color:var(--warn-fg);font-size:.8rem;border:1px solid currentColor;border-radius:999px;padding:0 .5em;margin-left:.4em}img{display:block;max-width:100%;max-height:70vh;margin:.8rem 0;border-radius:.4rem}.stats{margin:.4rem 0 .8rem}.on{color:var(--alert-fg)}.cap{white-space:pre-wrap}h3{font-size:.95rem;margin:1.4rem 0 .4rem;color:var(--dim-fg)}.c{margin:.35rem 0}.c b{margin-right:.4em}.end{border-top:1px solid var(--border-bg);margin-top:1.6rem;padding-top:.3rem;color:var(--dim-fg);font-size:.8rem}</style>")

(define (insta-detail-buffer row)
  (string-append "*insta:" (plist-get row 'code) "*"))

(define (insta--comments-html comments)
  (cond ((eq? comments 'loading) "<p class='dim'>Reading the comments...</p>")
        ((null? comments) "<p class='dim'>No comments.</p>")
        (else (apply string-append
                (map (lambda (c)
                       (string-append "<div class='c'><b>" (html-escape (insta--text (plist-get c 'user)))
                                      "</b>" (html-escape (insta--text (plist-get c 'text)))
                                      (if (and (number? (plist-get c 'likes)) (> (plist-get c 'likes) 0))
                                          (string-append " <span class='dim'>♥ " (insta--n (plist-get c 'likes)) "</span>")
                                          "")
                                      "</div>"))
                     comments)))))

(define (insta-render-detail! buf row)
  "Draw ROW's page into BUF, with its anchors: the post, the caption, the comments."
  (let* ((comments (or (buffer-local buf 'insta-comments) 'loading))
         (head (string-append
                 insta-detail-css
                 "<div class='h'><b>" (html-escape (plist-get row 'user)) "</b> "
                 "<span class='dim'>" (html-escape (insta--text (plist-get row 'name)))
                 " · " (insta--text (plist-get row 'ago)) " · " (insta--text (plist-get row 'kind)) "</span>"
                 (if (plist-get row 'ad) "<span class='ad'>ad</span>" "") "</div>"
                 (if (equal? (insta--text (plist-get row 'img)) "") ""
                     (string-append "<img referrerpolicy='no-referrer' src='" (html-escape (plist-get row 'img))
                                    "' alt='" (html-escape (insta--text (plist-get row 'alt))) "'>"))
                 "<div class='stats'><span class='" (if (plist-get row 'liked) "on" "dim") "'>♥</span> "
                 (insta--n (plist-get row 'likes)) " likes · " (insta--n (plist-get row 'comments)) " comments"
                 (if (plist-get row 'saved) " · saved" "") "</div>"))
         (cap (string-append
                "<div class='cap'>" (html-escape (insta--text (plist-get row 'caption))) "</div>"
                (if (equal? (insta--text (plist-get row 'alt)) "") ""
                    (string-append "<p class='dim'>" (html-escape (plist-get row 'alt)) "</p>"))))
         (com (string-append "<h3>Comments</h3>" (insta--comments-html comments)))
         (end "<div class='end'>end</div>")
         (a (string-byte-length head))
         (b (+ a (string-byte-length cap)))
         (c (+ b (string-byte-length com))))
    (buffer-set-local! buf 'insta-post row)
    (buffer-set-text! buf (string-append head cap com end) #t)
    (buffer-set-local! buf 'preview-renderer "html")
    (enable-minor-mode! buf "preview-mode")
    (preview-heal! buf)
    (anchor-set! buf (list (list "post" 0 a) (list "caption" a b) (list "comments" b c)))
    (enable-minor-mode! buf "anchor-mode")
    buf))

(define (insta--fetch-comments! buf)
  (let ((row (buffer-local buf 'insta-post)))
    (when row
      (insta--call (insta--comments-js (plist-get row 'pk))
        (lambda (comments)
          (when (and (buffer-exists? buf) (list? comments))
            (buffer-set-local! buf 'insta-comments comments)
            (insta-render-detail! buf (buffer-local buf 'insta-post))))))))

(define (insta-show-detail! row)
  "Show ROW in its own page beside the listing."
  (when row
    (let* ((buf (insta-detail-buffer row))
           (fresh? (not (buffer-exists? buf))))
      (when fresh? (buffer-create buf))
      (insta-join-group! buf 'detail)
      (unless (buffer-derived-mode? buf "insta-detail-mode")
        (with-current-buffer buf (lambda () (set-mode! "insta-detail-mode"))))
      (insta-render-detail! buf row)
      (when fresh? (insta--fetch-comments! buf))
      (display-buffer-detail! buf *insta-buffer*)
      buf)))

;;; --- actions: the same on the listing and the page --------------------------

(define (insta--row-here)
  (if (buffer-derived-mode? (current-buffer) "insta-mode")
      (list-current (current-buffer))
      (let ((post (buffer-local (current-buffer) 'insta-post)))
        (and post (or (insta--row-by-id (plist-get post 'id)) post)))))

(define (insta-like! row)
  "Like ROW, or take the like back when it is already liked."
  (let ((like? (not (plist-get row 'liked))))
    (message (if like? "Liking..." "Taking the like back..."))
    (insta--tab
      (lambda (tab)
        (if (not tab)
            (message "Open instagram.com in Chrome, then try again")
            (tab-eval tab (insta--like-js (plist-get row 'pk) like?)
              (lambda (status)
                (if (equal? status "200")
                    (let* ((n (or (plist-get row 'likes) 0))
                           (new (insta--put (insta--put row 'liked like?)
                                            'likes (if like? (+ n 1) (max 0 (- n 1)))))
                           (buf (insta-detail-buffer row)))
                      (insta--update-row! new)
                      (when (buffer-exists? buf) (insta-render-detail! buf new))
                      (message (string-append (if like? "Liked " "Unliked ") (plist-get row 'user) "'s post")))
                    (begin
                      (insta-log! (string-append "like " (plist-get row 'code) ": " (insta--text status)))
                      (message (string-append "Like failed. See " *insta-log*)))))))))))

(define-command "insta-open" "Show the post on this row beside the listing"
  (lambda () (insta-show-detail! (insta--row-here))))
(define-command "insta-like" "Like this post, or take the like back"
  (lambda () (let ((row (insta--row-here))) (if row (insta-like! row) (message "No post here")))))
(define-command "insta-open-browser" "Open this post on instagram.com"
  (lambda () (let ((row (insta--row-here))) (if row (tab-open (insta--post-url row)) (message "No post here")))))
(define-command "insta-copy-link" "Copy this post's link"
  (lambda ()
    (let ((row (insta--row-here)))
      (when row (kill-new (insta--post-url row)) (message (insta--post-url row))))))
(define-command "insta-refresh" "Read the feed again, or this post's comments"
  (lambda ()
    (if (buffer-derived-mode? (current-buffer) "insta-detail-mode")
        (insta--fetch-comments! (current-buffer))
        (insta-sync!))))
(define-command "insta-more" "Add the next page of the feed"
  (lambda () (insta-sync! #t)))

;;; --- modes -----------------------------------------------------------------

(define (insta--cells buf row)
  (list (plist-get row 'user)
        (list (insta--text (plist-get row 'ago)) "dim")
        (list (string-append (if (plist-get row 'liked) "♥ " "") (insta--n (plist-get row 'likes))) "dim")
        (list (if (plist-get row 'ad) "ad" (insta--text (plist-get row 'kind))) "dim")
        (insta--text (plist-get row 'line))))
(define (insta--narrow-cells buf row)
  (list (plist-get row 'user) (insta--text (plist-get row 'line))))

(define-list-mode! "insta-mode"
  (list
    'doc "Your Instagram feed, one row per post. Moving shows the post beside the list. RET shows it, l likes it or takes the like back, o opens it on instagram.com, w copies its link, g reads the feed again, M adds the next page, / narrows the rows, q quits."
    'buffer *insta-buffer*
    'transient #f
    'local-filter #t
    'noun "post"
    'rows insta--rows
    'key (lambda (buf row) (plist-get row 'id))
    'columns (lambda (buf)
      (list (list "who" 22) (list "age" 4) (list "likes" 8) (list "kind" 6) (list "caption" #f)))
    'cells insta--cells
    'layouts (list (list 'name 'narrow 'max-cols (lambda (buf) 70)
                         'columns (lambda (buf) (list (list "who" 20) (list "caption" #f)))
                         'cells insta--narrow-cells)
                   (list 'name 'wide 'default #t))
    'title (lambda (buf) "Instagram")
    'meta (lambda (buf) (string-append (number->string (length (insta--rows buf))) " posts"))
    'total (lambda (buf) (length (insta--rows buf)))
    'footer (lambda (buf)
      '(("RET" "post") ("l" "like") ("o" "browser") ("w" "link") ("g" "refresh") ("M" "more") ("/" "filter") ("q" "quit")))
    'preview (lambda (buf row) (insta-show-detail! row))
    'debounce #t
    'keys '(("RET" "insta-open") ("l" "insta-like") ("o" "insta-open-browser")
            ("w" "insta-copy-link") ("g" "insta-refresh") ("M" "insta-more") ("q" "quit-window"))))

(define-mode "insta-detail-mode"
  (lambda ()
    (insta-join-group! (current-buffer) 'detail)
    (buffer-set-read-only! (current-buffer) #t)))
(mode-doc! "insta-detail-mode"
  "One Instagram post: the picture, the caption and the comments. l likes it or takes the like back, o opens it on instagram.com, w copies its link, g reads the comments again, q quits. M-<down> and M-<up> walk the parts.")
(mode-keys! "insta-detail-mode"
  '(("l" "insta-like") ("o" "insta-open-browser") ("w" "insta-copy-link")
    ("g" "insta-refresh") ("q" "quit-window")))
(detail-name! "insta-detail-mode"
  (lambda (buf)
    (let ((row (buffer-local buf 'insta-post)))
      (string-append "*" (if row (plist-get row 'user) "insta") " post*"))))

;;; --- entry -----------------------------------------------------------------

(define (insta-listing!)
  "The listing buffer, made and joined to this group."
  (unless (buffer-exists? *insta-buffer*) (buffer-create *insta-buffer*))
  (insta-join-group! *insta-buffer* 'home)
  (unless (buffer-derived-mode? *insta-buffer* "insta-mode")
    (with-current-buffer *insta-buffer* (lambda () (set-mode! "insta-mode"))))
  *insta-buffer*)

;;;###autoload
(define-command "insta" "Open the Instagram feed app"
  (lambda ()
    (let ((buf (insta-listing!)))
      (app-open! buf)
      (if (pair? (insta--rows buf))
          (insta-show-detail! (list-current buf))
          (insta-sync!)))))

(public! 'insta-sync! "(insta-sync! [MORE?]) — read the Instagram feed into *insta*; MORE? adds the next page")
(public! 'insta-fetch! "(insta-fetch! MORE? K) — K gets the feed's posts as plists, or #f")
(public! 'insta-show-detail! "(insta-show-detail! ROW) — show one post's page beside the listing")
(public! 'insta-like! "(insta-like! ROW) — like ROW, or take the like back")
(public! 'insta "(insta) — open the Instagram feed app")
