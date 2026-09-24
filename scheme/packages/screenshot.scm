;;; screenshot.scm --- highlight parts of the editor and capture them as PNG.
;;;
;;; A target is a buffer name (the window that shows it), a component
;;; symbol such as 'card or 'ui/card (every element it rendered), 'frame
;;; (the whole editor tab), or a CSS selector string.
;;;
;;; A highlight is a labelled box drawn over the page. A shot keeps the
;;; boxes, so highlight what matters and then shoot the frame, or shoot one
;;; target cropped to its box. The capture goes through the compos
;;; extension's CDP bridge, at the screen's pixel ratio.
;;;
;;; screenshot-pick works like an inspector: the component under the cursor
;;; lights up, scrolling or the arrows grow and shrink it to the enclosing
;;; component, and a click saves it.

(namespace! 'screenshot)
(domain! 'ui)
(effects! '(write external))

(defgroup 'screenshot "Screenshots of the editor.")

(defcustom 'screenshot-directory "~/Desktop"
  "Where a screenshot lands when no path is given."
  'group 'screenshot)

(defcustom 'screenshot-padding 8
  "CSS pixels of margin kept around a cropped target."
  'group 'screenshot)

(defcustom 'screenshot-highlight-color "#ff3b6b"
  "The colour of highlight boxes and their labels."
  'group 'screenshot)

(defcustom 'screenshot-copy #t
  "Also put each screenshot on the clipboard as an image."
  'group 'screenshot)

(define (screenshot--component-class sym)
  (let ((n (car (reverse (string-split (symbol->string sym) "/")))))
    (string-append "c-" n ", .c-" n)))

(define (screenshot-selector target)
  (cond ((equal? target 'frame) "html")
        ((symbol? target) (screenshot--component-class target))
        ((buffer-known? target)
         (string-append "c-window[data-buffer=" (json-encode target) "]"))
        (else target)))

(define (screenshot--label target)
  (if (symbol? target) (symbol->string target) (file-name-nondirectory target)))

;; the union box of every visible element SELECTOR matches, in page pixels
(define (screenshot--rect selector)
  (let ((v (dom-eval (string-append
    "(()=>{let l=1e9,t=1e9,r=-1e9,b=-1e9,n=0;"
    "for(const e of document.querySelectorAll(" (json-encode selector) ")){"
    "const q=e.getBoundingClientRect();if(!q.width||!q.height)continue;n++;"
    "l=Math.min(l,q.left);t=Math.min(t,q.top);r=Math.max(r,q.right);b=Math.max(b,q.bottom)}"
    "if(!n)return null;l=Math.max(0,l);t=Math.max(0,t);r=Math.min(innerWidth,r);b=Math.min(innerHeight,b);"
    "return JSON.stringify({x:l+scrollX,y:t+scrollY,width:r-l,height:b-t,count:n})})()"))))
    (and (string? v) (json-parse v))))

(define (screenshot-highlight! target &optional label)
  (let ((sel (screenshot-selector target)))
    (dom-eval (string-append
      "(()=>{let L=document.getElementById('compos-shot-layer');"
      "if(!L){L=document.createElement('div');L.id='compos-shot-layer';"
      "L.style.cssText='position:fixed;inset:0;pointer-events:none;z-index:2147483647';"
      "document.body.appendChild(L)}"
      "const c=" (json-encode screenshot-highlight-color) ",lab=" (json-encode (or label (screenshot--label target))) ";let n=0;"
      "for(const e of document.querySelectorAll(" (json-encode sel) ")){"
      "const q=e.getBoundingClientRect();if(!q.width||!q.height)continue;n++;"
      "const d=document.createElement('div');"
      "d.style.cssText=`position:absolute;left:${q.left}px;top:${q.top}px;width:${q.width}px;height:${q.height}px;`+"
      "`box-sizing:border-box;border:2px solid ${c};border-radius:6px;box-shadow:0 0 0 4px ${c}33`;"
      "const t=document.createElement('span');t.textContent=lab;"
      "t.style.cssText=`position:absolute;left:6px;top:6px;background:${c};color:#fff;font:600 11px system-ui;padding:2px 6px;border-radius:4px`;"
      "d.appendChild(t);L.appendChild(d)}return n})()"))))

(define (screenshot-clear!)
  (dom-eval "(()=>{const L=document.getElementById('compos-shot-layer');if(L)L.remove();return true})()"))

(define (screenshot--default-path)
  (string-append (expand-path screenshot-directory) "/compos-"
                 (format-time (current-time) "%Y%m%d-%H%M%S") ".png"))

(define (screenshot--clip r)
  (let ((p screenshot-padding))
    (list 'format "png"
          'clip (list 'x (max 0 (- (plist-get r 'x) p))
                      'y (max 0 (- (plist-get r 'y) p))
                      'width (+ (plist-get r 'width) p p)
                      'height (+ (plist-get r 'height) p p)
                      'scale 1))))

(define (screenshot--params target)
  (if (equal? target 'frame)
      (list 'format "png")
      (let ((r (screenshot--rect (screenshot-selector target))))
        (and r (screenshot--clip r)))))

(defvar 'screenshot--last #f "The path of the last screenshot saved.")

(define (screenshot-path) screenshot--last)

;; the page writes the PNG to the clipboard; Chrome allows it while the
;; editor tab has focus, which a click in the picker gives
(define (screenshot--copy! data)
  (tab-cdp (dom--editor-tab) "Runtime.evaluate"
    (list 'expression
          (string-append "(async () => { const b = await (await fetch('data:image/png;base64," data
                         "')).blob(); await navigator.clipboard.write([new ClipboardItem({'image/png': b})]); })()")
          'awaitPromise #t 'userGesture #t)
    (lambda (r) r)))

;; a command runs before the page has drawn its prompt away: wait until the
;; minibuffer layer is gone and the page has painted, then call K
(define (screenshot--settle k)
  (tab-cdp (dom--editor-tab) "Runtime.evaluate"
    (list 'expression
          (string-append "(async () => { const t = Date.now() + 1500;"
                         " while (document.querySelector('.mb-modal-layer') && Date.now() < t)"
                         " await new Promise(r => setTimeout(r, 16));"
                         " await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))); })()")
          'awaitPromise #t)
    (lambda (r) (k))))

(define (screenshot--capture params path k)
  (screenshot--settle
    (lambda ()
      (tab-cdp (dom--editor-tab) "Page.captureScreenshot" params
        (lambda (r)
          (let ((data (plist-get (plist-get r 'result) 'data)))
            (if (string? data)
                (begin (write-file! path (base64-decode data))
                       (variable-set! 'screenshot--last path)
                       (when screenshot-copy (screenshot--copy! data))
                       (k path))
                (k #f))))))))

(define (screenshot! target &optional path k)
  (let ((params (screenshot--params target))
        (path (or path (screenshot--default-path)))
        (k (or k (lambda (v) v))))
    (if (not params)
        (begin (k #f) #f)
        (begin (screenshot--capture params path k) path))))

(define (screenshot--pick-js)
  (string-append
    "(()=>{if(window.__composPickCancel)window.__composPickCancel();"
    "const c=" (json-encode screenshot-highlight-color) ";let result=null,wake=null;"
    "const L=document.createElement('div');L.id='compos-pick-layer';"
    "L.style.cssText='position:fixed;inset:0;pointer-events:none;z-index:2147483647';"
    "const B=document.createElement('div');"
    "B.style.cssText=`position:absolute;display:none;box-sizing:border-box;border:2px solid ${c};border-radius:6px;background:${c}14;box-shadow:0 0 0 4px ${c}33;transition:all 60ms ease-out`;"
    "const T=document.createElement('span');"
    "T.style.cssText=`position:absolute;left:-2px;white-space:nowrap;background:${c};color:#fff;font:600 11px system-ui;padding:2px 6px;border-radius:4px`;"
    "B.appendChild(T);L.appendChild(B);"
    "const H=document.createElement('div');H.textContent='Click to capture  |  scroll or arrows: bigger / smaller  |  Esc: cancel';"
    "H.style.cssText='position:absolute;left:50%;bottom:16px;transform:translateX(-50%);background:#111d;color:#fff;font:500 12px system-ui;padding:6px 10px;border-radius:6px';"
    "L.appendChild(H);document.body.appendChild(L);"
    "const root=document.documentElement,oldCur=root.style.cursor;root.style.cursor='crosshair';"
    "let base=null,up=0,cur=null;"
    "const same=(a,b)=>a.left===b.left&&a.top===b.top&&a.width===b.width&&a.height===b.height;"
    "const chain=e=>{const a=[];let last=null;for(;e&&e!==document.documentElement;e=e.parentElement){"
    "if(!e.tagName.startsWith('C-')||e.tagName==='C-CURSOR')continue;const q=e.getBoundingClientRect();"
    "if(!q.width||!q.height||(last&&same(q,last)))continue;last=q;a.push(e)}return a};"
    "const name=e=>{const t=e.tagName.toLowerCase().slice(2),b=e.getAttribute('data-buffer'),n=e.getAttribute('name');"
    "return b?`${t} ${b.split('/').pop()}`:n?`${t} ${n}`:t};"
    "const show=()=>{const a=chain(base);if(!a.length){B.style.display='none';cur=null;return}"
    "up=Math.max(0,Math.min(up,a.length-1));cur=a[up];const q=cur.getBoundingClientRect();"
    "Object.assign(B.style,{display:'block',left:q.left+'px',top:q.top+'px',width:q.width+'px',height:q.height+'px'});"
    "T.textContent=`${name(cur)}  ${Math.round(q.width)} x ${Math.round(q.height)}`;T.style.top=q.top<24?'2px':'-22px'};"
    "const eat=ev=>{ev.preventDefault();ev.stopPropagation();ev.stopImmediatePropagation()};"
    "const move=ev=>{const e=document.elementFromPoint(ev.clientX,ev.clientY);if(e!==base){base=e;up=0}show()};"
    "const wheel=ev=>{eat(ev);up+=ev.deltaY<0?1:-1;show()};"
    "const pick=()=>{const q=cur.getBoundingClientRect();done({x:q.left+scrollX,y:q.top+scrollY,width:q.width,height:q.height,label:name(cur)})};"
    "const key=ev=>{eat(ev);if(ev.type!=='keydown')return;if(ev.key==='Escape')done(null);"
    "else if(ev.key==='ArrowUp'){up++;show()}else if(ev.key==='ArrowDown'){up--;show()}else if(ev.key==='Enter'&&cur)pick()};"
    "const click=ev=>{eat(ev);if(cur)pick()};"
    "const evs=[['mousemove',move],['wheel',wheel],['keydown',key],['keyup',key],['keypress',key],['click',click],"
    "['mousedown',eat],['mouseup',eat],['pointerdown',eat],['pointerup',eat],['dblclick',eat],['contextmenu',ev=>{eat(ev);done(null)}]];"
    "const opt={capture:true,passive:false};for(const[n,f]of evs)window.addEventListener(n,f,opt);"
    "function done(v){for(const[n,f]of evs)window.removeEventListener(n,f,opt);L.remove();root.style.cursor=oldCur;"
    "window.__composPickCancel=null;requestAnimationFrame(()=>requestAnimationFrame(()=>{result=v?JSON.stringify(v):'cancel';if(wake)wake(result)}))}"
    "window.__composPickCancel=()=>done(null);"
    "window.__composPickWait=ms=>result?Promise.resolve(result):new Promise(r=>{wake=r;setTimeout(()=>r('pending'),ms)});"
    "return true})()"))

;; long-polls the picker in short rounds, so the bridge never times out;
;; a click answers at once. K gets the picked box, or #f on cancel.
(define (screenshot--pick-wait k)
  (tab-cdp (dom--editor-tab) "Runtime.evaluate"
    (list 'expression "window.__composPickWait?window.__composPickWait(10000):'cancel'"
          'awaitPromise #t 'returnByValue #t)
    (lambda (r)
      (let ((v (plist-get (plist-get (plist-get r 'result) 'result) 'value)))
        (cond ((equal? v "pending") (screenshot--pick-wait k))
              ((and (string? v) (not (equal? v "cancel"))) (k (json-parse v)))
              (else (k #f)))))))

(define (screenshot-pick! &optional path k)
  (let ((path (or path (screenshot--default-path)))
        (k (or k (lambda (v) v))))
    (dom-eval (screenshot--pick-js))
    (screenshot--pick-wait
      (lambda (box)
        (if box
            (screenshot--capture (screenshot--clip box) path k)
            (k 'cancelled))))
    path))


(define (screenshot--report path)
  (message (cond ((equal? path 'cancelled) "Screenshot cancelled")
                 (path (string-append "Screenshot: " (abbreviate-file-name path)))
                 (else "Screenshot: nothing to capture"))))

(define (screenshot--selector? text)
  (let loop ((i 0))
    (and (< i (string-length text))
         (or (member (substring text i (+ i 1)) '("." "#" "[" " " ">" ":" "*"))
             (loop (+ i 1))))))

;; typed input: a buffer name, a CSS selector, or else a component name
(define (screenshot--read-target text)
  (cond ((buffer-known? text) text)
        ((screenshot--selector? text) text)
        (else (string->symbol text))))

(define-command "screenshot-pick" "Point at a component or window, then click to save a PNG of it"
  (lambda () (screenshot-pick! #f #f screenshot--report)))

(define-command "screenshot-frame" "Save a PNG of the whole editor, highlights included"
  (lambda () (screenshot! 'frame #f screenshot--report)))

(define-command "screenshot-window" "Save a PNG of the selected window"
  (lambda () (screenshot! (current-buffer) #f screenshot--report)))

(define-command "screenshot-target" "Save a PNG of a buffer's window, a component, or a CSS selector"
  (lambda ()
    (completing-read "Screenshot: " (buffer-list)
      (lambda (text) (screenshot! (screenshot--read-target text) #f screenshot--report)))))

(define-command "screenshot-highlight" "Box a buffer's window, a component, or a CSS selector for the next shot"
  (lambda ()
    (completing-read "Highlight: " (buffer-list)
      (lambda (text)
        (let ((n (screenshot-highlight! (screenshot--read-target text))))
          (message (string-append "Highlighted " (number->string (or n 0)))))))))

(define-command "screenshot-path" "Show the path of the last screenshot"
  (lambda ()
    (message (if screenshot--last
                 (string-append "Last screenshot: " (abbreviate-file-name screenshot--last))
                 "No screenshot yet"))))

(define-command "screenshot-clear" "Remove every screenshot highlight"
  (lambda () (screenshot-clear!) (message "Highlights cleared")))

(public! 'screenshot!
  "(screenshot! TARGET [PATH] [K]) — save a PNG of TARGET: a buffer name, a component symbol, 'frame or a CSS selector; answers PATH at once, K gets PATH or #f once written")
(public! 'screenshot-highlight!
  "(screenshot-highlight! TARGET [LABEL]) — draw a labelled box over TARGET for the next shot; the number boxed")
(public! 'screenshot-clear!
  "(screenshot-clear!) — remove every highlight box")
(public! 'screenshot-pick!
  "(screenshot-pick! [PATH] [K]) — highlight the component under the cursor; a click saves a PNG of it, Esc cancels; K gets PATH, #f, or 'cancelled")
(public! 'screenshot-path
  "(screenshot-path) — the path of the last screenshot saved, or #f")
(public! 'screenshot-selector
  "(screenshot-selector TARGET) — the CSS selector a screenshot TARGET stands for")

(catalog-meta! 'function "screenshot!" 'domain 'ui 'effects '(write external))
(catalog-meta! 'function "screenshot-highlight!" 'domain 'ui 'effects '(write display))
(catalog-meta! 'function "screenshot-clear!" 'domain 'ui 'effects '(write display))
(catalog-meta! 'function "screenshot-pick!" 'domain 'ui 'effects '(write external display))
(catalog-meta! 'function "screenshot-path" 'domain 'ui 'effects '(read))
(catalog-meta! 'function "screenshot-selector" 'domain 'ui 'effects '(pure))
