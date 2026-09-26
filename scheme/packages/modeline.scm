;;; modeline.scm --- the modeline dashboard and the buffer-name grammar.
;;;
;;; The dashboard is the line under a window and the panel above its text:
;;; mode, state, groups, model and lane, built when a window shows the
;;; buffer and by the events that change it, never once per command. The
;;; buffer-name grammar renders every buffer and group name the same way
;;; in every chrome. This file loads from init.scm after chat-mode.scm.

(domain! 'ui)
(effects! '(unknown))

;;; --- the modeline dashboard -----------------------------------------------------
;;; modeline-expand toggles a popup that says everything about HERE: the
;;; buffer, its modes, its group — and the LLM ledger with a spend
;;; sparkline. The modeline is the summary; this is the expansion.
;;; Clicking the modeline's name opens it too.


(define-style! 'dashboard "
.ml-fact-v.preset-compos::before {
  content: \"\"; display: inline-block; width: 12px; height: 12px;
  margin-right: 4px; vertical-align: -1px;
  background: url(/images/compos-logo.png) center / contain no-repeat;
}
.dash { font-family: var(--font-sans); padding: 2px 6px 8px; }
.dash-head { display: flex; align-items: flex-end; gap: 16px;
             padding: 10px 16px 12px; border-bottom: 1px solid var(--border-bg, #e2dbc9); }
.dash-name { font-family: var(--font-serif); font-size: 24px; letter-spacing: -0.4px; }
.dash-file { font-family: var(--font-mono); font-size: 11px; color: var(--dim-fg, #8a857a);
             padding-top: 4px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.dash-headmain { min-width: 0; }
.dash-sp { flex: 1; }
.dash-pills { display: flex; flex-wrap: wrap; justify-content: flex-end; gap: 6px; }
.dash-pill { padding: 2px 9px; border-radius: 0; border: 1px solid var(--border-bg, #cbc4b1);
             color: var(--dim-fg, #57534a); font-family: var(--font-mono); font-size: 10.5px;
             white-space: nowrap; }
.dash-pill.warn { border-color: var(--diff-hunk-fg, #7a5a1a); color: var(--diff-hunk-fg, #7a5a1a); }
.dash-pill.good { border-color: var(--diff-add-fg, #2e6b45); color: var(--diff-add-fg, #2e6b45); }
.dash-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); }
.dash-cell { padding: 12px 18px 14px; display: flex; flex-direction: column; gap: 8px;
             border-right: 1px solid var(--border-bg, #e2dbc9); min-width: 0; }
.dash-cell:last-child { border-right: none; }
.dash-title { font-family: var(--font-mono); font-size: 9.5px; letter-spacing: 0.18em;
              text-transform: uppercase; color: var(--dim-fg, #8a857a); }
.dash-big { font-family: var(--font-mono); font-size: 13px; font-weight: 600;
            color: var(--accent-fg, #26356b); }
.dash-row { display: flex; align-items: baseline; gap: 8px;
            font-family: var(--font-mono); font-size: 11.5px; }
.dash-k { color: var(--dim-fg, #8a857a); flex: 0 0 auto; }
.dash-row .dash-sp { border-bottom: 1px dotted var(--border-bg, #cfc8b6);
                     transform: translateY(-3px); }
.dash-v { color: var(--default-fg, #1b1a17); text-align: right; min-width: 0;
          overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.dash-v.dim { color: var(--dim-fg, #b3ac9c); }
.dash-v.good { color: var(--diff-add-fg, #2e6b45); }
.dash-v.warn { color: var(--diff-hunk-fg, #7a5a1a); }
.dash-chips { display: flex; flex-wrap: wrap; gap: 5px; }
.dash-chip { padding: 2px 8px; border-radius: 0; background: var(--window-bg, #fdfcf8);
             border: 1px solid var(--border-bg, #e2dbc9); font-family: var(--font-mono);
             font-size: 10.5px; color: var(--dim-fg, #57534a); }
.dash-chip.dim { color: var(--faint-fg, #b3ac9c); border-style: dashed; }
.dash-chiprow { display: flex; flex-wrap: wrap; align-items: baseline; gap: 5px; }
.dash-chipkey { flex: 0 0 auto; font-family: var(--font-mono); font-size: 9.5px;
                letter-spacing: .14em; text-transform: uppercase;
                color: var(--dim-fg, #8a857a); }
/* The headline wears the group's colour, but not at full strength: the row
   sits over every line of the buffer, and a saturated fill there shouts down
   the text it heads. --dash-ink is the group's colour bent towards the page's
   own grey, so the badge, the bottom edge and the chosen verbosity still read
   as the group's paint while standing a step back. The window's focus ring
   below keeps the pure colour, because that one has to carry across the
   frame. */
/* The window you are in wears the accent on the TOP edge of its header
   line: the same 2px line that marks a current row, so a window at rest
   draws the same box with the line turned transparent and nothing in the
   layout moves. The bottom edge is the frame's own hairline. */
.dash-persistent { --dash-ink: color-mix(in srgb,
                     var(--buffer-group-color, var(--accent-fg, #26356b)) 58%,
                     var(--dim-fg, #8a857a));
                   display: flex; align-items: center; gap: var(--s9); min-width: 0;
                   overflow: hidden;
                   padding: 5px var(--s8) 5px var(--s6);
                   border-top: 1px solid transparent;
                   border-bottom: var(--border);
                   background: var(--surface-chrome); cursor: pointer; }
/* the current mark is a 1px accent seam on the header line, mixed toward
   the chrome so it reads as a seam, not a stripe */
.window.active .dash-persistent {
  border-top: 1px solid color-mix(in srgb, var(--accent) 55%, var(--surface-chrome)); }
.window.inactive .dash-persistent { background: var(--surface-sunken); }
/* every keyed segment shows its whole value; only the wide one gives way */
.dseg { display: flex; flex-direction: column; gap: 1px; flex: 0 0 auto;
        font-family: var(--font-mono); }
.dseg-r { align-items: flex-end; }
.dseg-inline { flex-direction: row; align-items: baseline; gap: 7px; }
.dseg-k { font-size: var(--fs-micro); letter-spacing: var(--ls-label);
          text-transform: uppercase;
          color: var(--text-dim); white-space: nowrap; }
.dseg-v { font-size: var(--fs-meta); color: var(--text-strong); white-space: nowrap; }
.dseg-strong { font-weight: 600; }
/* The state tag: cua or focus, small and tracked, at the end of the header
   line. The window's ground says the same thing (layouts.ex): a current cua
   window sits, a current focus window floats. The tag keeps the state's
   name as a class so that rule can read it. */

/* The one switcher: a square action cell, no fill, dim until the pointer
   is on it. Same shape as every other action in the frame. */
.dseg-action { display: inline-flex; align-items: center; justify-content: center;
               flex: 0 0 auto; width: 24px; height: 24px;
               border: 1px solid transparent; cursor: default; user-select: none;
               font: var(--fw-reg) 13px/1 var(--font-mono); color: var(--text-dim); }
.dseg-action:hover { color: var(--text-strong); }
/* The frame names its current group once. A window in that group does not
   repeat it: the client marks the header line with data-pin only when the
   buffer's group is not the frame's, and only then the pin shows. */
.dash-persistent:not([data-pin]) > .dseg-group-badge { display: none; }
/* a mode that gave itself a glyph shows the glyph at the size of a word */
.dseg-glyph { font-size: 16px; line-height: 1; }
.dseg-group-current { color: var(--dash-ink, var(--buffer-group-color, var(--default-fg, #1b1a17))); }
/* The group leads the headline from the window's own edge. The negative left
   margin cancels the headline padding, so the chip touches the border and
   nothing sits left of it. It is filled with the group's own colour, so its
   text takes the window background to stay legible, and the key goes away in
   the paint: the colour is the label. */
/* The group leads the header line as a square pin: the accent's own wash
   for a ground, and the group's colour on the text, so the pin still says
   which group without a filled chip shouting over the title. A window at
   rest hollows the pin to a hairline. */
.dseg-group-badge { flex: 0 0 auto; display: flex; align-items: center;
                    padding: 3px var(--s6) 4px; min-width: 0;
                    border: 1px solid transparent;
                    background: var(--accent-wash); }
.window.inactive .dseg-group-badge { background: transparent;
                    border-color: var(--edge-soft); }
.dseg-group-badge .dseg { flex: 0 1 auto; min-width: 0; }
.dseg-group-badge .dseg-k { display: none; }
.dseg-group-badge .dseg-v { font-size: var(--fs-meta);
                            color: var(--buffer-group-color, var(--accent));
                            white-space: nowrap; overflow: hidden;
                            text-overflow: ellipsis; }
.dseg-group-badge .dseg-group-current { color: var(--buffer-group-color, var(--accent)); }
.dseg-group-badge .f-dim, .dseg-group-badge .f-faint {
  color: var(--buffer-group-color, var(--accent)); opacity: .7; }
.window.inactive .dseg-group-badge .dseg-v,
.window.inactive .dseg-group-badge .dseg-group-current { color: var(--text-faint); }
/* the chip is its own edge; a rule beside it says nothing */
.dash-persistent .dseg-group-badge + .dseg-rule { display: none; }
/* A window at rest keeps both of its bars whole: the ink steps down
   (layouts.ex remaps the text tokens on .window.inactive), nothing hides,
   so selecting a window reflows nothing. */
.dseg-rule { width: var(--hair); height: 13px; flex: 0 0 auto;
             background: var(--edge); }
.dseg-gap { flex: 1 1 auto; }
.dseg-stack { display: flex; flex-direction: column; gap: 3px; flex: 0 0 auto; }
.dseg-wide { flex: 1 1 0; min-width: 0; }
/* The headline wraps at the title: the badge and the title (with the
   open jj change) ride the top row, and the verbosity picker stays on
   that row at its end. The metadata -- mode, model, lane -- wraps onto
   a second row of its own beneath the title, so a narrow window stacks
   the rest below the title instead of squeezing it. dseg-meta is the
   row Scheme builds for the metadata; the picker is ordered ahead of
   it, and the title keeps growing to fill the top row. */
.dash-persistent { flex-wrap: nowrap; column-gap: 16px; }
.dash-persistent:has(.dseg-meta) { flex-wrap: wrap; row-gap: 4px; }
.dseg-fill, .dseg-verbosity, .dash-state-mark, .dseg-action { order: 1; }
.dseg-meta { order: 2; flex: 0 1 100%; display: flex; align-items: baseline;
             gap: 16px; min-width: 0; }
.dash-persistent .dseg,
.dash-persistent .dseg-stack { flex-direction: row; align-items: baseline; gap: 6px; }
.dash-persistent .dseg-stack { gap: 16px; }
.dash-persistent .dseg-v { white-space: nowrap; }
/* The title is a name in a bar, not a heading: mono at the UI size,
   semibold, one line, its exact characters. The mode's glyph leads it in
   the accent, and a hairline carries the eye from the name to the tail. */
.dash-persistent .dseg-chat-title { flex: 0 1 auto; min-width: 8ch; display: flex; align-items: baseline; gap: var(--s4); }
.dash-persistent .dseg-chat-title[glyph]::before {
  content: attr(glyph); flex: none; font-family: var(--font-mono);
  font-size: var(--fs-ui); color: var(--accent); }
/* Space age: light, wide-tracked mono. A chat's title is a sentence and
   goes to tracked capitals; a buffer name is case-significant and keeps
   its case, tracked the same. */
.dash-persistent .dseg-chat-title .dseg-v {
  display: block; font-weight: 300; line-height: 1.3;
  font-family: var(--font-mono); font-size: var(--fs-small); letter-spacing: 0.14em;
  color: var(--text-strong); white-space: nowrap;
  overflow: hidden; text-overflow: ellipsis; -webkit-line-clamp: unset; }
.dash-persistent .dseg-chat-title:not(.dseg-title-mono) .dseg-v { text-transform: uppercase; }
.dash-persistent .dseg-chat-title .dseg-strong { font-weight: 300; }
/* a file's name, with its directory below it: small, muted, ~ for home.
   The two lines sit tight, so the header line grows as little as it can. */
.dseg-title-stack { display: flex; flex-direction: column; min-width: 0; gap: 0; }
.dash-persistent .dseg-chat-title .dseg-title-stack .dseg-v { line-height: 1.1; }
.dash-persistent .dseg-chat-title .dseg-title-stack .dseg-strong { font-weight: 600; }
.dash-persistent .dseg-chat-title .dseg-path {
  display: block; font-family: var(--font-mono); font-size: 9px;
  line-height: 1.1; color: var(--text-dim); white-space: nowrap;
  overflow: hidden; text-overflow: ellipsis; }
.window.inactive .dash-persistent .dseg-chat-title .dseg-path { color: var(--text-faint); }
/* the file name of the window you are in glows in the accent */
.window.active .dash-persistent .dseg-chat-title .dseg-title-stack .dseg-v {
  color: var(--accent);
  text-shadow: 0 0 6px color-mix(in srgb, var(--accent) 55%, transparent); }
/* the fill only pushes the tail to the end; it draws no line */
.dseg-fill { flex: 1 1 auto; min-width: 8px; }
/* the open jj change takes the free width of the row, so the fill steps aside */
.dash-persistent .dseg-wide[name=jj] { flex: 1 1 0; min-width: 0; }
.dash-persistent:has(.dseg-wide[name=jj]) .dseg-fill { display: none; }
/* the state needs no word: a floating window says it */
.dash-state-mark { display: none; }
/* the verbosity switch: three tracked words, the current one in ink with
   an accent seam under it. Square, no fill, no icon. */
.dseg-verbosity { display: inline-flex; align-items: baseline; gap: var(--s6); flex: none;
                  font-size: var(--fs-micro); letter-spacing: var(--ls-label); text-transform: uppercase; }
.dseg-verb { color: var(--text-dim); padding: 1px 0 2px; border-bottom: 1px solid transparent; cursor: default; }
.dseg-verb:hover { color: var(--text-strong); }
.dseg-verb.on { color: var(--text-strong); border-bottom-color: var(--accent); }
.dash-persistent:has(.dseg-chat-title) .dseg-rule { display: none; }
/* the chip is a label, not a column: it never wraps and never grows */
.dash-persistent .dseg-group-badge .dseg-v {
  white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 24ch; }

.dseg-wide .dseg-v { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
")

(define (dash--row k v &optional cls)
  (list 'tag "div" 'class "dash-row"
        'segs (list (list "dash-k" k) (list "dash-sp" "")
                    (list (string-append "dash-v" (if cls (string-append " " cls) "")) v))))

(define (dash--chip m) (list 'tag "span" 'class "dash-chip" 'text m))

(define (dash--pill text cls)
  (list 'tag "span" 'class (string-append "dash-pill" (if cls (string-append " " cls) ""))
        'text text))

(define (dash--section title children)
  (list 'tag "div" 'class "dash-cell"
        'children (cons (list 'tag "div" 'class "dash-title" 'text title) children)))

(define (dash--head buf)
  (list 'tag "div" 'class "dash-head"
        'children
        (list
          (list 'tag "div" 'class "dash-headmain"
                'children
                (append
                  (list (list 'tag "div" 'class "dash-name" 'text (buffer-short-label buf)))
                  (let ((p (buffer-path buf)))
                    (if p (list (list 'tag "div" 'class "dash-file" 'text p)) '()))))
          (list 'tag "span" 'class "dash-sp" 'text "")
          (list 'tag "div" 'class "dash-pills"
                'children
                (append
                  (list (dash--pill (if (buffer-modified? buf) "modified" "saved")
                                    (if (buffer-modified? buf) "warn" "good")))
                  (if (buffer-read-only? buf) (list (dash--pill "read-only" #f)) '())
                  (list (dash--pill
                          (string-append (number->string (buffer-size buf)) " B") #f)))))))

(define (dash--chip-row key chips)
  (list 'tag "div" 'class "dash-chiprow"
        'children (cons (list 'tag "div" 'class "dash-chipkey" 'text key) chips)))

;; A keymap is read as the mode of the same name: "cua-mode-map" is
;; cua-mode. The buffer's own map wears the buffer's name, and the global
;; map is nobody's mode.
(define (dash--map-mode name)
  (if (string-suffix? "-map" name)
      (substring name 0 (- (string-length name) 4))
      name))

;; A mode name in the card is that mode's switch. The panel used to name the
;; modes and the window template drew a second, clickable modes card beside
;; it -- two cards, one subject. The card is built here now, and the name
;; carries the toggle the second card had.
(define (dash--mode-toggle name class)
  (list 'tag "c-action" 'class class
        'text (dashboard--mode-name name)
        'click (string-append "dash-mode:" name)
        'attrs (list (list "title" (string-append "toggle " name)))))

;; Every mode that answers here. The modeline shows the major mode and the
;; buffer's minor modes; other maps answer with nothing said -- cua-mode's,
;; the editing state's, a global minor map -- and the card names those as
;; the hidden ones. The state is the last fact: the movement state gives
;; the Cmd-arrows to the window focus, the editing state to the caret.
(define (dash--modes buf)
  (let* ((major (or (buffer-local buf 'mode-name) "Fundamental"))
         (minors (or (buffer-local buf 'minor-modes) '()))
         (shown (cons major minors))
         (maps (append (or (buffer-minor-maps buf) '())
                       (or (buffer-keymaps buf) '())
                       (or (global-minor-maps) '())))
         (hidden (dedupe-names
                   (filter (lambda (m)
                             (and (not (member m shown))
                                  (not (equal? m buf))
                                  (not (equal? m "global"))))
                           (map dash--map-mode maps)))))
    (dash--section "modes"
      (append
        (list (dash--mode-toggle major "dash-big dash-toggle"))
        (list (dash--chip-row "shown"
                (if (pair? minors)
                    (map (lambda (m) (dash--mode-toggle m "dash-chip dash-chip-on")) minors)
                    (list (dash--chip "none")))))
        (if (pair? hidden)
            (list (dash--chip-row "hidden"
                    (map (lambda (m)
                           (list 'tag "span" 'class "dash-chip dim"
                                 'text (dashboard--mode-name m)))
                         hidden)))
            '())
        (list (dash--row "read-only" (if (buffer-read-only? buf) "yes" "no"))
              (dash--row "state" (dash--state buf)))))))

(define (dash--group buf)
  (let* ((ids (if (chat-buffer? buf)
                  (let ((g (chat-group-id buf))) (if g (list g) '()))
                  (buffer-group-ids buf)))
         (current (frame-local 'current-group))
         (primary (cond ((and current (member current ids)) current)
                        ((pair? ids) (car ids))
                        (else #f))))
    (if (null? ids)
        (dash--section "group"
          (list (dash--row "group" "none" "dim")
                (dash--row "join" "C-c g" "dim")))
        (dash--section (if (null? (cdr ids)) "group" "groups")
          (append
            ;; C-x ? is the unabridged counterpart to the compact modeline:
            ;; every membership is named, with the frame's current one first.
            (list (list 'tag "div" 'class "dash-chips"
                        'children
                        (map (lambda (g) (dash--chip (group-label g)))
                             (if (and current (member current ids))
                                 (cons current
                                       (remove (lambda (g) (equal? g current)) ids))
                                 ids))))
            ;; the members are the group list's work (M-x group-members),
            ;; not this panel's: the panel says where HERE stands
            (list (dash--row "members"
                             (number->string (length (group-buffers-mru primary))))
                  (dash--row "companion" (group-noise primary))
                  (dash--row "layout" (if (group-layout primary) "saved" "default")))
            (let ((m (group-meta primary)))
              (if m (list (dash--row "about" m)) '())))))))

;; the ledger, folded by day: today's cost and the total come from the
;; same rows
(define (dash--day-costs rows)
  (let loop ((rs rows) (acc '()))
    (if (null? rs)
        acc
        (let* ((r (car rs))
               (day (plist-get r 'day))
               (cost (or (plist-get r 'cost) 0))
               (hit (assoc day acc)))
          (loop (cdr rs)
                (if hit
                    (cons (list day (+ (cadr hit) cost))
                          (remove (lambda (e) (equal? (car e) day)) acc))
                    (cons (list day cost) acc)))))))

;; The chat that speaks for HERE: this buffer when it is one, else its
;; group's chat. The cost, the presets and the tool surface all live on
;; that buffer, so every card asks this one question.
(define (dash--here-chat buf)
  (if (chat-buffer? buf)
      buf
      (let ((g (buffer-group buf)))
        (and g (group-primary-chat g)))))

;; what HERE cost: the buffer's own chat, or its group's chat
(define (dash--here-cost buf)
  (or (buffer-local buf 'chat-cost)
      (let ((c (dash--here-chat buf)))
        (and c (buffer-local c 'chat-cost)))))

;; the model HERE would talk to, and through which lane: a chat's own
;; agent-model, a writing buffer's llm-model, else the global default.
;; The lane is acp when a connector is attached, api otherwise.
(define (dash--model buf)
  (or (buffer-local buf 'agent-model)
      (buffer-local buf 'llm-model)
      (llm-model)))

(define (dash--lane buf)
  (let ((c (buffer-local buf 'agent-connector)))
    (if (and c (not (equal? c "api")))
        (string-append "acp · " c)
        "api")))

;; the tool presets in force here: the buffer's own, or its group chat's
(define (dash--presets buf)
  (let ((p (or (buffer-local buf 'chat-presets)
               (let ((c (dash--here-chat buf)))
                 (and c (buffer-local c 'chat-presets))))))
    (and (pair? p)
         (string-join (map (lambda (x) (value->string x)) p) " · "))))

;; A preset shows on the mode line as one glyph. The compos preset has no
;; glyph: it wears the compos logo, drawn by the preset-compos class.
(define *preset-icons* '())
(define (preset-icon! name glyph)
  (set! *preset-icons* (alist-put *preset-icons* name glyph)))

(define (dash--preset-icon p)
  (let ((e (assoc p *preset-icons*)))
    (if e (cadr e) (string-upcase (substring (value->string p) 0 1)))))

;; the presets as (GLYPHS TONE): compos leads as the logo, the rest follow
(define (dash--preset-icons buf)
  (let ((p (or (buffer-local buf 'chat-presets)
               (let ((c (dash--here-chat buf)))
                 (and c (buffer-local c 'chat-presets))))))
    (and (pair? p)
         (let ((rest (remove (lambda (x) (equal? x 'compos)) p)))
           (list (string-join (map dash--preset-icon rest) " ")
                 (if (member 'compos p) "preset-compos" ""))))))

;;; The tools HERE can call. A chat freezes its tool list at its first
;;; send, so the frozen list is what the model sees; before that, the
;;; live surface is what the next send will freeze. The card names the
;;; state, so a stale list is visible where the chat is, not only in the
;;; modeline.
;;;
;;; This asks the live surface, which starts a preset's MCP servers. The
;;; panel builds only when it opens and when its fingerprint moves, so
;;; the question costs the same as the modeline already costs per turn.

(define (dash--tool-state chat)
  (cond ((pair? (buffer-local chat 'chat-tool-specs))
         (list (if (and (boundp (quote chat-tools-stale?))
                        (chat-tools-stale? chat))
                   "stale"
                   "frozen")
               (buffer-local chat 'chat-tool-specs)))
        ((boundp (quote chat-live-tool-specs))
         (list "live" (chat-live-tool-specs chat)))
        (else (list "none" '()))))

;; A preset whose server is not ready serves no tools yet. Name those
;; servers: "0 tools" with a preset set is otherwise unexplainable.
(define (dash--pending-servers chat)
  (if (not (boundp (quote chat-active-servers)))
      '()
      (let ((remote (filter (lambda (s) (not (equal? s 'compos)))
                            (chat-active-servers chat))))
        (map (lambda (s) (value->string s))
             (filter (lambda (s)
                       (let ((d (conn-detail 'mcp (value->string s))))
                         (not (and (pair? d)
                                   (equal? (plist-get d 'status) "ready")))))
                     remote)))))

;; twenty names, then a count: a server with fifty tools must not push
;; the ledger off the panel
(define (dash--tool-chips names)
  (let ((n (length names)))
    (list 'tag "div" 'class "dash-chips"
          'children
          (append
            (map dash--chip (if (> n 20) (take names 20) names))
            (if (> n 20)
                (list (dash--chip (string-append "+" (number->string (- n 20))
                                                 " more")))
                '())))))

(define (dash--tools buf)
  (let ((chat (dash--here-chat buf)))
    (if (not chat)
        (dash--section "tools"
          (list (dash--row "chat" "none" "dim")
                (dash--row "open" "C-c c" "dim")))
        (let* ((st (dash--tool-state chat))
               (state (car st))
               (names (map car (car (cdr st))))
               (n (length names))
               (ps (dash--presets buf)))
          (dash--section "tools"
            (append
              (list (list 'tag "div" 'class "dash-big"
                          'text (string-append (number->string n)
                                               (if (= n 1) " tool" " tools")))
                    (dash--row "presets" (or ps "none") (if ps #f "dim"))
                    (dash--row "list" state
                               (cond ((equal? state "stale") "warn")
                                     ((equal? state "frozen") "good")
                                     (else "dim"))))
              (if (equal? state "stale")
                  (list (dash--row "adopt" "C-c t"))
                  '())
              ;; a server that is not ready serves nothing, and the count
              ;; above says so without saying why. Name it at any count:
              ;; a surface missing one server still looks complete.
              (let ((pending (dash--pending-servers chat)))
                (if (pair? pending)
                    (list (dash--row "waiting on"
                                     (string-join pending " · ") "warn"))
                    '()))
              (if (pair? names) (list (dash--tool-chips names)) '())
              (list (dash--row "servers" "M-x mcp-hub" "dim"))))))))

(define (dash--llm buf)
  (let* ((rows (llm-cost-report))
         (days (sort-by-car (dash--day-costs rows)))
         (total (fold (lambda (a d) (+ a (cadr d))) 0 days))
         (today (if (pair? days) (car (reverse days)) #f))
         (here (dash--here-cost buf)))
    (dash--section "llm"
      (append
        (list (list 'tag "div" 'class "dash-big" 'text (dash--model buf))
              (dash--row "lane" (dash--lane buf)))
        (if here (list (dash--row "this chat" (format-usd here))) '())
        (list (dash--row "today, all" (if today (format-usd (cadr today)) "$0") #f)
              (dash--row "total, all" (format-usd total))
              (dash--row "ledger" "M-x llm-costs" "dim"))))))

;; an ISO day as one integer (20260816): the dialect has no string<?
(define (dash--day-int d)
  (or (string->number (string-join (string-split d "-") "")) 0))

(define (sort-by-car xs)
  (let loop ((rest xs) (out '()))
    (if (null? rest)
        out
        (loop (cdr rest)
              (let ins ((ys out))
                (cond ((null? ys) (list (car rest)))
                      ((< (dash--day-int (car (car rest)))
                          (dash--day-int (car (car ys))))
                       (cons (car rest) ys))
                      (else (cons (car ys) (ins (cdr ys))))))))))

(define (last-n xs n)
  (let ((k (length xs)))
    (if (<= k n) xs (list-tail xs (- k n)))))

;; the expansion is a panel INSIDE the buffer's window, pinned above
;; the text — the buffer stays editable beneath it. The state is one
;; buffer-local; the blocks are derived and never saved.
;; the panel PULLS like the bar: everything per-buffer (position,
;; modes, read-only) renders in the view from live state. Only the
;; cross-buffer cards ship as blocks: the group's detail and the
;; ledger. post-command! keeps those honest.
(define (dashboard-blocks buf)
  (list (dash--head buf)
        (dash--modes buf)
        (dash--group buf)
        (dash--tools buf)
        (dash--llm buf)))

;; The card's mode names are switches. The click arrives through the block
;; registry, which components.scm owns: core loads first, so that package
;; registers this handler once the registry exists.
(define (dashboard-block-click buf id)
  (and (string? id)
       (cond ((string-prefix? "dash-mode:" id)
              (modeline-toggle-mode! (substring id 10 (string-length id)))
              #t)
             ;; the header line's one switcher opens the narrow about HERE
             ((equal? id "buffer-switcher")
              (with-current-buffer buf (lambda () (run-command "buffer-switcher")))
              #t)
             ;; the header line's i opens the panel C-x ? opens
             ((equal? id "modeline-expand")
              (with-current-buffer buf (lambda () (run-command "modeline-expand")))
              #t)
             ;; a verbosity word in the header line
             ((string-prefix? "agent-verbosity-" id)
              (with-current-buffer buf (lambda () (run-command id)))
              #t)
             ;; the keys card's `?` grows or folds it
             ((equal? id "list-keys-toggle")
              (with-current-buffer buf (lambda () (run-command "list-keys-toggle")))
              #t)
             (else #f))))

(define (dashboard--group-ids buf)
  (if (chat-buffer? buf)
      (let ((g (chat-group-id buf))) (if g (list g) '()))
      (buffer-group-ids buf)))

(define (dashboard--mode-name name)
  (let ((s (if (symbol? name) (symbol->string name) name)))
    (if (and (string? s) (string-suffix? "-mode" s))
        (substring s 0 (- (string-length s) 5))
        (or s "Fundamental"))))

;; The compact dashboard stays at the top of the window. It keeps the LLM
;; context and every group visible in one line, then opens the full panel.
;; PRESET-CELL, when given, is (list PRESET): the sync reads the preset
;; once for both the line and the blocks, because the read walks the
;; saved bundles against the live setup
(define (dashboard-one-line buf &optional preset-cell)
  (let* ((ids (dashboard--group-ids buf))
         (modes (cons (or (buffer-local buf 'mode-name) "Fundamental")
                      (or (buffer-local buf 'minor-modes) '())))
         (mode-text (string-join (map dashboard--mode-name modes) " · "))
         (preset (if preset-cell (car preset-cell) (dash--preset buf)))
         (groups (if (pair? ids)
                     (string-join (map group-label ids) " · ")
                     "none")))
    (string-append "mode " mode-text
                   "   state " (dash--state buf)
                   "   groups " groups
                   (if preset
                       (string-append "   preset " preset)
                       (string-append "   llm " (dash--model buf)
                                      "   lane " (dash--lane buf))))))

;;; The same facts, keyed. A flat run of tokens spends one weight on
;;; every word, so nothing reads first. Each segment puts a whisper-sized
;;; key over its value, and the value carries the line. Place goes left,
;;; machine state goes right, and a hairline rule separates them.

(define (dash--seg key segs align &optional extra-class)
  (list 'tag "c-field"
        'class (string-append
                (if (equal? align 'right) "dseg dseg-r" "dseg")
                (if extra-class (string-append " " extra-class) ""))
        'attrs (if key (list (list "name" key)) '())
        'children
        (append
          (if key
              (list (list 'tag "c-label" 'class "dseg-k" 'text key))
              '())
          (list (list 'tag "c-value" 'class "dseg-v" 'segs segs)))))

(define (dash--seg-rule)
  (list 'tag "span" 'class "dseg-rule"))

;; The header names the major mode. The expanded modes card lists minors.
(define (dash--mode-segs buf)
  (let* ((mode (buffer-local buf 'mode-name))
         (icon (mode-own-icon mode)))
    ;; A mode that gave itself a glyph shows the glyph alone. The key above
    ;; it already says MODE, so the word underneath was saying it twice, and
    ;; the room it took belongs to the segments that carry a value.
    (if icon
        (list (list "dseg-strong dseg-glyph" icon))
        (list (list "dseg-strong"
                    (dashboard--mode-name (or mode "Fundamental")))))))

;; the last group is where you are; the ones before it are the path
(define (dash--group-segs buf)
  (let ((labels (map group-label (dashboard--group-ids buf))))
    (if (null? labels)
        '()
        (let loop ((rest labels) (out '()))
          (if (null? (cdr rest))
              (reverse (cons (list "dseg-strong dseg-group-current" (car rest)) out))
              (loop (cdr rest)
                    (cons (list "f-faint" " / ")
                          (cons (list "f-dim" (car rest)) out))))))))

;; The group owns the top-left corner of the headline: a filled badge in the
;; group's own colour, flush with the window's left edge, ahead of everything
;; the buffer says about itself. The key stays in the markup for a reader and
;; goes away in the paint — the colour is the label. The segment keeps the
;; name 'group, so a narrow window still drops or keeps it by that name.
;; A buffer in no group gets no badge: the headline says nothing rather than
;; saying none, and the title takes the corner instead.
(define (dash--group-badge buf)
  (let ((segs (dash--group-segs buf)))
    (and (pair? segs)
         (list 'tag "div" 'class "dseg-group-badge"
               'children
               (list (dash--seg "group" segs 'left "dseg-inline"))))))

;; "openrouter:sonnet" reads as one word until the provider steps back
(define (dash--model-segs buf)
  (let* ((model (dash--model buf))
         (parts (string-split model ":")))
    (if (> (length parts) 1)
        (list (list "f-dim" (string-append (car parts) ":"))
              (list "dseg-strong" (string-join (cdr parts) ":")))
        (list (list "dseg-strong" model)))))

;; the open jj change of the buffer's repo: jj.scm keeps a cache by root,
;; so a chat that lives in the repo shows the line as well as a file does
(define (dash--vcs buf)
  (jj-modeline-line buf))

;; The two states of an editable buffer, in one word, and the word says
;; where the Cmd-arrows go. "focus" gives them to the window; "editing"
;; gives them to the caret. The caret map is the whole question, so the
;; word reads that map and not the editing-state flag: a mode that refuses
;; the caret map keeps the window chords in the editing state, and a chat
;; is such a mode, so a chat says focus while you type in it. A read-only
;; buffer never leaves focus.
;; The editing state decides: while the caret map is armed the caret shows
;; and the window sits; in the movement state (a landing, ESC, C-g) the
;; caret is gone and the window floats. A chat refuses the caret map and
;; says focus however much you type in it. The client draws the caret from
;; the same state (data-editing), so the caret and the ground never
;; disagree.
(define (dash--state buf)
  (if (member "editing-caret-map" (buffer-minor-maps buf)) "editing" "focus"))

;; The state is a small tag at the end of the header line, and the window's
;; ground says it again: a cua window sits, a focus window floats. The tag
;; carries the state's name as a class so the window rule can read it, and
;; it sits outside the narrow-window keep list, because a window too narrow
;; for the title still has to say whether the arrows move it. The design's
;; words: an editing buffer is a cua buffer and stays put; every other
;; buffer is a focus buffer and can be moved.
(define (dash--state-mark buf)
  (let ((st (dash--state buf)))
    (list 'tag "c-tag"
          'class (string-append "dash-state-mark dash-state-" st)
          'text (if (equal? st "editing") "cua" "focus"))))

;; The one switcher: a single action at the end of the header line that
;; opens a narrow about this buffer. The design keeps one icon, not three.
(define (dash--switcher buf)
  (list 'tag "c-action" 'class "dseg-action" 'text "i"
        'click "modeline-expand"
        'attrs (list (list "target" "modeline-expand")
                     (list "title" "about this buffer (C-x ?)"))))

;; The window's mode line carries the state: the mode, the model and the
;; lane, each a key and a value, ranked so a narrow window sheds the lane
;; first and the model next. A preset names the whole setup and stands
;; alone. The header line carries identity only, so these live here.
;; Each fact is (KEY VALUE TONE RANK); the client draws one c-fact each.
(define (dash--modeline-facts buf preset-cell)
  (let* ((preset (if preset-cell (car preset-cell) (dash--preset buf)))
         (mode (or (buffer-local buf 'mode-name) "Fundamental"))
         (icon (mode-own-icon mode))
         (mode-text (dashboard--mode-name mode)))
    (append
      (list (list "mode" (if icon (string-append icon " " mode-text) mode-text) "glyph" 0))
      (if preset
          (list (list "preset" preset "" 1))
          (list (list "llm" (dash--model buf) "" 1)
                (list "lane" (dash--lane buf) "ok" 2)))
      (let ((icons (dash--preset-icons buf)))
        (if icons
            (list (list "tools" (car icons) (cadr icons) 1))
            '())))))

;; What a buffer can say about itself, as rows for the switcher's narrow:
;; the dashboard panel, the summary log of a chat, and for an agent
;; transcript how much of it to show. Each row is (LABEL COMMAND).
(define (buffer-switcher-rows buf)
  (append
    (list (list "buffer info" "modeline-expand"))
    (if (chat-buffer? buf) (list (list "summary log" "buffer-summary-log")) '())
    (if (chat-rich-view? buf)
        (list (list "transcript: info" "agent-verbosity-info")
              (list "transcript: log" "agent-verbosity-log")
              (list "transcript: debug" "agent-verbosity-debug"))
        '())))

(define-command "buffer-switcher"
  "About this buffer: its info, its log, or how much of its transcript to show"
  (lambda ()
    (let* ((buf (current-buffer))
           (rows (buffer-switcher-rows buf)))
      (completing-read "about this buffer: " (map car rows)
        (lambda (label)
          (let ((row (assoc label rows)))
            (when row
              (with-current-buffer buf (lambda () (run-command (cadr row)))))))
        'require-match #t))))

(define (dash--preset buf)
  (and (boundp (quote llm-config-preset-name))
       (llm-config-preset-name buf)))

;; the chat's title: the first label its running summary wrote. The bar
;; names the chat, and a name that changes under you names nothing --
;; the paragraph the summary says now is a click away, in the log.
(define (dash--summary buf)
  (and (chat-buffer? buf)
       (let ((s (if (boundp (quote chat-title-of))
                    (chat-title-of buf)
                    (buffer-local buf 'chat-title))))
         (and (string? s) (not (equal? s "")) s))))

;;; What a mode's headline keeps when its window is narrow. Where narrow
;;; starts is narrow-cols, the system's answer; a mode declares only WHICH
;;; of the segments survive it. The names are mode, group, llm and wide. A
;;; mode that declares nothing keeps every segment and lets the row clip.
(define (define-mode-headline! mode narrow) (mode-put! mode 'headline narrow))
(define (mode-headline mode) (mode-get mode 'headline))

;; Chat identity is visible at every width. CSS wraps metadata beneath
;; the title per pane; a buffer-wide cache must not choose a pane's width.
(define-mode-headline! "chat-mode" #f)

;; The minor modes first, then the major mode: the same walk buffer-layout
;; makes, so one buffer answers with one declaration. WIDTH is the columns
;; of the window showing BUF; a wide window keeps everything and answers #f.
(define (dash--headline-keep buf width)
  (and (< width narrow-cols)
       (let loop ((names (append (or (buffer-local buf 'minor-modes) '())
                                 (let ((m (buffer-local buf 'mode-name)))
                                   (if m (list m) '())))))
         (if (null? names)
             #f
             (let ((keep (mode-headline (car names))))
               (or keep (loop (cdr names))))))))

;; The rules separate whatever survives. They are not segments: dropping a
;; segment must never leave the rule that stood beside it dangling.
(define (dash--ruled blocks)
  (if (null? blocks)
      '()
      (cons (car blocks)
            (let loop ((rest (cdr blocks)))
              (if (null? rest)
                  '()
                  (cons (dash--seg-rule)
                        (cons (car rest) (loop (cdr rest)))))))))

(define (dashboard-line-blocks buf &optional preset-cell)
  (let* ((vcs (dash--vcs buf))
         ;; every buffer names itself: a chat's own title when it wrote one,
         ;; and the buffer's name when it has none. The name comes through
         ;; whole, so a system buffer is *Messages* and never messages.
         ;; a file names itself by its file name, with its directory below
         (file (if (dash--summary buf) (list #f #f) (dash--file-parts buf)))
         (title (or (dash--summary buf)
                    (and (car file)
                         (if (peek-buffer? buf) (string-append "peek · " (car file)) (car file)))
                    (buffer-modeline-name buf)))
         (preset (if preset-cell (car preset-cell) (dash--preset buf)))
         ;; every segment carries its name, so a narrow window keeps the
         ;; ones its mode declared and drops the rest
         ;; The header line is identity: the group pin, the title, the open
         ;; change. The mode, the model and the lane are state, and state
         ;; lives on the mode line (dash--modeline-facts). PRESET is read
         ;; here so one read serves both bars.
         (cells
           (append
             (list
               (list 'group (dash--group-badge buf)))
             ;; the wide segments wrap to two lines with the key inline. The
             ;; title leads; the open jj change of the repo follows it, kept
             ;; fresh by jj.scm, and steps back when a chat writes a summary.
             ;; A click on either opens the log of every line it showed.
             ;; the title is a name in a bar: mono, one line, led by the
             ;; mode's own glyph in the accent
             (append (list (list 'wide
                             (dash--wide-seg #f title
                               (if (dash--summary buf)
                                   "dseg-chat-title"
                                   "dseg-chat-title dseg-title-mono")
                               (mode-own-icon (buffer-local buf 'mode-name))
                               (cadr file))))
                     (if (and vcs (not (dash--summary buf)))
                         (list (list 'wide (dash--wide-seg "jj" vcs))) '()))))
         (width (buffer-cols buf))
         (keep (dash--headline-keep buf width))
         ;; KEEP says which segments survive a narrow window; NARROW? says
         ;; whether the window is narrow enough to stack the metadata beneath
         ;; the title at all. A wide window shares one row with every segment.
         (narrow? (< width narrow-cols)))
    ;; the state tag and the switcher ride last, after everything the
    ;; buffer says about itself, and no keep list can drop them
    (let* ((group? (lambda (cell) (equal? (car cell) 'group)))
           (wide? (lambda (cell) (equal? (car cell) 'wide)))
           (tail (remove group? cells))
           (ordered (append (filter group? cells)
                            (filter wide? tail)
                            (remove wide? tail)))
           (kept (if keep
                     (filter (lambda (cell) (member (car cell) keep)) ordered)
                     ordered))
           ;; a cell that built no block says nothing, so it takes no slot:
           ;; outside a group there is no badge. The group badge leads at
           ;; every width and the chat title follows it, on the headline's
           ;; top row. The metadata -- mode, model, lane -- wraps onto its
           ;; own row beneath the title, and the verbosity picker stays on
           ;; the top row. CSS reads dseg-meta to place that second row.
           (top (filter (lambda (cell) (and (cadr cell) (or (group? cell) (wide? cell)))) kept))
           (meta (filter (lambda (cell) (and (cadr cell) (not (or (group? cell) (wide? cell))))) kept)))
      (dash--assemble-headline top meta narrow? buf))))

;; TOP is the badge and the title; META is mode/model/lane. A narrow window
;; stacks META on a second row beneath the title (dseg-meta); a wide window
;; keeps every surviving segment on one row, ruled together.
;; How much of an agent transcript to show: three tracked words at the
;; end of the header line, the current one in ink with an accent seam.
;; Any other buffer has no such switch and draws nothing here.
(define (dash--verbosity buf)
  (and (chat-rich-view? buf)
       (let ((now (or (buffer-local buf 'agent-verbosity) "info")))
         (list 'tag "div" 'class "dseg-verbosity"
               'children
               (map (lambda (level)
                      (list 'tag "div"
                            'class (string-append "dseg-verb" (if (equal? level now) " on" ""))
                            'text level
                            'click (string-append "agent-verbosity-" level)
                            'attrs (list (list "title" (string-append "show " level)))))
                    '("info" "log" "debug"))))))

;; the hairline that carries the eye from the title to the tail
(define (dash--fill) (list 'tag "div" 'class "dseg-fill"))

(define (dash--assemble-headline top meta narrow? buf)
  (let ((tail (filter (lambda (b) b)
                      (list (dash--fill) (dash--verbosity buf)
                            (dash--state-mark buf) (dash--switcher buf)))))
    (if narrow?
        (append
          (dash--ruled (map cadr top))
          (if (pair? meta)
              (list (list 'tag "div" 'class "dseg-meta" 'children (map cadr meta)))
              '())
          tail)
        (append
          (dash--ruled (append (map cadr top) (map cadr meta)))
          tail))))

(define (dash--wide-seg key text &optional title-class glyph dir)
  (let* ((base (dash--seg key (list (list (if title-class "dseg-strong" "f-dim") text))
                          'left (string-append "dseg-inline dseg-wide"
                                   (if title-class (string-append " " title-class) ""))))
         ;; a file's directory sits under its name, small and muted
         (children (if dir
                       (list (list 'tag "c-group" 'class "dseg-title-stack"
                                   'children (append (plist-get base 'children)
                                                     (list (list 'tag "c-text" 'class "dseg-path"
                                                                 'text dir)))))
                       (plist-get base 'children))))
    (list 'tag "c-action"
          'class (plist-get base 'class)
          'children children
          'click "summary-log"
          'attrs (append (if key (list (list "name" key)) '())
                         (if glyph (list (list "glyph" glyph)) '())
                         (list (list "target" "summary-log")
                               (list "title" "open the summary log"))))))

;; the file or directory a buffer shows, as (NAME DIR): the last segment of
;; its path, and the path above it with the home directory written as ~.
;; A buffer that is not a file gives (#f #f).
(define (dash--file-parts buf)
  (let* ((path (or (buffer-path buf)
                   (and (string-prefix? "/" buf) buf)))
         (bare (and (string? path) (> (string-length path) 1)
                    (if (string-suffix? "/" path)
                        (substring path 0 (- (string-length path) 1))
                        path)))
         (name (and bare (file-name-nondirectory bare))))
    (if (and name (not (equal? name "")))
        (let ((dir (substring bare 0 (- (string-length bare) (string-length name) 1))))
          (list name (if (equal? dir "") "/" (abbreviate-file-name dir))))
        (list #f #f))))

;; The modeline names the buffer the short way: project coordinates inside
;; a project, "~" for the home directory outside one. The buffer name keeps
;; the absolute path, and the modeline's tooltip still says it.
;; A buffer with no file can still name one: "*chat:/Users/me/notes.md*".
;; Write the home directory as ~ wherever it appears in the name.
(define (abbreviate-home-in text)
  (let ((home (getenv "HOME")))
    (if (and (string? text) (string? home) (> (string-length home) 1))
        (string-join (string-split text home) "~")
        text)))

;; A chat is known by its title, not by *chat:GROUP:N*. A titled chat
;; wears its title as its buffer name already; an untitled one keeps its
;; derived name until its running summary writes the first label.
(define (buffer-modeline-chat-name buf)
  (let ((label (and (chat-buffer? buf)
                    (boundp 'chat-prompt-label)
                    (chat-prompt-label buf))))
    (if (and (string? label) (not (equal? label "")))
        label
        (abbreviate-home-in buf))))

(define (buffer-modeline-name buf)
  (let* ((path (buffer-path buf))
         (root (buffer-project-root buf))
         (name (cond ((not (string? path)) (buffer-modeline-chat-name buf))
                     ((and (string? root) (not (equal? root ""))
                           (string-prefix? (string-append root "/") path))
                      (substring path (+ 1 (string-length root)) (string-length path)))
                     (else (abbreviate-file-name path)))))
    ;; a peek says so where the name is: the one mark the feature has
    (if (peek-buffer? buf)
        (string-append "peek · " name)
        name)))

;; A file names its project beside its modeline name. A chat has no file,
;; so that same context slot names the directory where its tools run.
(define (buffer-modeline-context buf)
  (if (chat-buffer? buf)
      (abbreviate-file-name (buffer-directory buf))
      (buffer-project-label buf)))

;;; --- the buffer-name grammar --------------------------------------------------
;;; A name renders. Every chrome that shows a buffer or a group draws the
;;; same small markup and never the raw characters: *Messages* was always
;;; meant to read as a bold "Messages", and the naming convention the
;;; editor already had IS the grammar.
;;;
;;;   *text*   strong        :key:  one icon; :mode: is the buffer's own
;;;   ~text~   dim           \\x     a literal x
;;;   `text`   mono
;;;
;;; The delimiters are the ones a name does not carry by accident.
;;; Markdown's _ is absent on purpose: editor_live.ex and __init__.py would
;;; each lose a word to it. A delimiter that never closes is text, and so is
;;; :key: for an icon nobody registered, which keeps a name like
;;; notmuch:thread:0005 whole.
;;;
;;; A format string says what a name is made of, so a mode changes its own
;;; without touching a renderer: set the buffer-local name-format, or
;;; buffer-name-format for the rest. name-format-expand fills the
;;; %-directives and name-segments parses the result; both are pure. The
;;; value is the ((CLASS TEXT) ...) list the modeline extra already speaks,
;;; so Scheme names the classes and the client draws one span each.

(define *name-icons* '())            ; ((KEY GLYPH) ...) what :key: reaches

(define (name-icon! key glyph)
  (set! *name-icons* (alist-put *name-icons* key glyph)))

;; a caller's own icons come first: :mode: belongs to the buffer, not here
(define (name--icon key icons)
  (let ((e (or (assoc key icons) (assoc key *name-icons*))))
    (and e (cadr e))))

;; the character position of CH in TEXT at or after FROM, or #f. string-index
;; counts bytes where substring counts characters, and a name carries icons:
;; the scan must count characters or the two disagree.
(define (name--index text ch from)
  (let ((n (string-length text)))
    (let loop ((i from))
      (cond ((>= i n) #f)
            ((equal? (substring text i (+ i 1)) ch) i)
            (else (loop (+ i 1)))))))

(define (name--class ch)
  (cond ((equal? ch "*") "bn-strong")
        ((equal? ch "~") "bn-dim")
        ((equal? ch "`") "bn-code")
        ((equal? ch ":") "bn-icon")
        (else #f)))

(define (name--flush plain out)
  (if (equal? plain "") out (cons (list "bn-text" plain) out)))

(define (name--drop-empty segs)
  (filter (lambda (s) (not (equal? (cadr s) ""))) segs))

(define (name--trim-left s)
  (let ((n (string-length s)))
    (let loop ((i 0))
      (cond ((>= i n) "")
            ((equal? (substring s i (+ i 1)) " ") (loop (+ i 1)))
            (else (substring s i n))))))

(define (name--trim-right s)
  (let loop ((n (string-length s)))
    (cond ((= n 0) "")
          ((equal? (substring s (- n 1) n) " ") (loop (- n 1)))
          (else (substring s 0 n)))))

(define (name--edge segs trim)
  (if (null? segs)
      '()
      (cons (list (car (car segs)) (trim (cadr (car segs)))) (cdr segs))))

;; A mode that declares no icon leaves the space that stood beside it, and a
;; name never begins or ends on one. Drop the empty segments first, so that
;; space is an edge by the time the edges are trimmed.
(define (name--tidy segs)
  (let* ((a (name--drop-empty segs))
         (b (name--edge a name--trim-left))
         (c (reverse (name--edge (reverse b) name--trim-right))))
    (name--drop-empty c)))

(define (name-segments spec &optional icons)
  (let* ((text (if (string? spec) spec ""))
         (icons (or icons '()))
         (n (string-length text)))
    (name--tidy
      (let loop ((i 0) (plain "") (out '()))
        (if (>= i n)
            (reverse (name--flush plain out))
            (let ((ch (substring text i (+ i 1))))
              (cond
                ((and (equal? ch "\\") (< (+ i 1) n))
                 (loop (+ i 2)
                       (string-append plain (substring text (+ i 1) (+ i 2)))
                       out))
                ((name--class ch)
                 (let ((close (name--index text ch (+ i 1))))
                   ;; no partner, or an empty body: the delimiter is text
                   (if (or (not close) (= close (+ i 1)))
                       (loop (+ i 1) (string-append plain ch) out)
                       (let ((body (substring text (+ i 1) close)))
                         (if (equal? ch ":")
                             (let ((glyph (name--icon body icons)))
                               (if glyph
                                   (loop (+ close 1) ""
                                         (cons (list "bn-icon" glyph)
                                               (name--flush plain out)))
                                   (loop (+ i 1) (string-append plain ch) out)))
                             (loop (+ close 1) ""
                                   (cons (list (name--class ch) body)
                                         (name--flush plain out))))))))
                (else (loop (+ i 1) (string-append plain ch) out)))))))))

;; VALS is ((KEY VALUE) ...) over one-character keys. An unknown directive
;; stays as it was written, so a name that carries a per cent sign survives.
(define (name-format-expand format vals)
  (let* ((text (if (string? format) format ""))
         (n (string-length text)))
    (let loop ((i 0) (out ""))
      (if (>= i n)
          out
          (let ((ch (substring text i (+ i 1))))
            (if (and (equal? ch "%") (< (+ i 1) n))
                (let* ((key (substring text (+ i 1) (+ i 2)))
                       (e (assoc key vals)))
                  (cond ((equal? key "%") (loop (+ i 2) (string-append out "%")))
                        (e (loop (+ i 2) (string-append out (or (cadr e) ""))))
                        (else (loop (+ i 2) (string-append out ch key)))))
                (loop (+ i 1) (string-append out ch))))))))

;; the same name as one string, for a tooltip and for a caller with no spans
(define (name-text segments)
  (string-join (map cadr segments) ""))

;; How a buffer names itself: the mode's icon, then the compact name, whose
;; own asterisks make a special buffer bold. A mode with something else to
;; say sets the buffer-local name-format instead. %n is that compact name,
;; %N the buffer name, %m the mode, %p the project or the working directory.
(define buffer-name-format ":mode: %n")

(define (buffer-name-segments buf)
  (name-segments
    (name-format-expand
      (or (buffer-local buf 'name-format) buffer-name-format)
      (list (list "n" (buffer-modeline-name buf))
            (list "N" buf)
            (list "m" (or (buffer-local buf 'mode-name) "Fundamental"))
            (list "p" (buffer-modeline-context buf))))
    (list (list "mode" (buffer-icon buf)))))

;; Events invalidate hidden presentation. Any frame can supply a reader.
(define (dashboard--sync! buf)
  (when (buffer-exists? buf)
    (desktop-skip! buf 'dashboard-dirty)
    (if (member buf (map cadr (window-list-all)))
        (dashboard--render! buf)
        (unless (buffer-local buf 'dashboard-dirty)
          (buffer-set-local! buf 'dashboard-dirty #t)))))

(define (dashboard--catchup! buf)
  (when (and (buffer-exists? buf) (buffer-local buf 'dashboard-dirty))
    (dashboard--sync! buf)))

(define (dashboard--catchup-visible!)
  (for-each (lambda (w) (dashboard--catchup! (cadr w))) (window-list)))

(add-hook! 'buffer-shown-hook 'dashboard--catchup!)
(add-hook! 'window-configuration-change-hook 'dashboard--catchup-visible!)
;; The state tag lives in this line and the window's ground reads it, so a
;; buffer that enters or leaves the editing state renders its line again at
;; once: a cua window sits, a focus window floats. Nothing else invalidates
;; the line when the state's maps go in or out.
(add-hook! 'editing-state-hook 'dashboard--sync!)

;; The dashboard line reads the model, lane and preset from locals, so an
;; llm-config change re-renders the headline. llm-config runs this hook on
;; exit; the handler refreshes the configured buffer and its session.
(define (dashboard--llm-config-changed! buf)
  (when (buffer-exists? buf)
    (dashboard--sync! buf)
    (let ((session (llm-config-session buf)))
      (when (and session (not (equal? session buf)))
        (dashboard--sync! session)))))

(add-hook! 'llm-config-changed-hook 'dashboard--llm-config-changed!)

(define (dashboard--render! buf)
  (desktop-skip! buf 'dashboard-line)
  (desktop-skip! buf 'dashboard-line-blocks)
  (desktop-skip! buf 'modeline-name)
  (desktop-skip! buf 'modeline-name-segments)
  (desktop-skip! buf 'modeline-project)
  (desktop-skip! buf 'modeline-facts)
  ;; one preset read for the line, the blocks and the facts; one change for
  ;; the six locals, so the frame refreshes once for the sync
  (let ((preset-cell (list (dash--preset buf))))
    (buffer-set-locals! buf
      (list 'dashboard-dirty #f
            'dashboard-line (dashboard-one-line buf preset-cell)
            'dashboard-line-blocks (dashboard-line-blocks buf preset-cell)
            ;; the state the window's mode line draws: mode, llm, lane
            'modeline-facts (dash--modeline-facts buf preset-cell)
            'modeline-name (buffer-modeline-name buf)
            ;; the same name as the spans that draw it: the client shows
            ;; these and falls back to the plain string only without them
            'modeline-name-segments (buffer-name-segments buf)
            ;; The project stands beside a file name. A chat shows its
            ;; working directory in the same context slot.
            'modeline-project (buffer-modeline-context buf)))))

;; The dirty flag is transient. Restore requests a sync again, and the
;; window hooks materialize only pending presentation. Group catchup can
;; call sync first; clearing the flag keeps these hooks from duplicating it.

;; The fingerprint reads locals only — never the live tool surface. It
;; runs after every command, and asking the surface there would start
;; MCP servers on a cursor move. The frozen list and the presets are the
;; state that moves the tools card, and both are locals.
(define (dash--fingerprint buf)
  (let ((chat (dash--here-chat buf)))
    (list (buffer-local buf 'mode-name)
          (buffer-local buf 'minor-modes)
          ;; the modes card names every map that answers here, and the
          ;; editing state adds and drops maps as you type
          (buffer-minor-maps buf)
          (dashboard--group-ids buf)
          (frame-local 'current-group)
          (buffer-local buf 'agent-model)
          (buffer-local buf 'agent-connector)
          (buffer-local buf 'llm-model)
          (and chat (buffer-local chat 'chat-presets))
          (and chat (map car (or (buffer-local chat 'chat-tool-specs) '()))))))

(define (dashboard-panel-open! buf)
  (desktop-skip! buf 'modeline-expanded)
  (desktop-skip! buf 'modeline-dash-blocks)
  (desktop-skip! buf 'modeline-dash-fp)
  (buffer-set-locals! buf
    (list 'modeline-dash-fp (dash--fingerprint buf)
          'modeline-dash-blocks (dashboard-blocks buf)
          'modeline-expanded #t)))

;; #t when a panel was open and is not any more, so a caller that closes
;; one of several things -- keyboard-quit does -- knows it closed this.
(define (dashboard-panel-close! buf)
  (and (buffer-local buf 'modeline-expanded)
       (begin
         (buffer-set-locals! buf
           (list 'modeline-expanded #f 'modeline-dash-blocks #f))
         #t)))

(define-command "modeline-expand"
  "Toggle this buffer's expanded modeline panel"
  (lambda ()
    (let ((buf (current-buffer)))
      (unless (dashboard-panel-close! buf)
        (dashboard-panel-open! buf)))))

;; The headerline and the panel are derived state, rebuilt only when
;; something says it changed. When something forgot to say so, this is
;; the way to make the buffer say it again.
(define-command "buffer-dashboard-refresh"
  "Rebuild this buffer's dashboard line and panel from scratch"
  (lambda ()
    (let ((buf (current-buffer)))
      (dashboard--render! buf)
      (when (buffer-local buf 'modeline-expanded)
        (buffer-set-locals! buf
          (list 'modeline-dash-fp (dash--fingerprint buf)
                'modeline-dash-blocks (dashboard-blocks buf))))
      (message "Dashboard refreshed"))))

(catalog-meta! 'command "buffer-dashboard-refresh" 'domain 'buffers 'effects '(write))

;; before every command and every self-insert: packages that must act
;; before the buffer changes (the chat keeps point in its input) hang
;; on pre-command-hook
(define (pre-command!)
  (run-hooks 'pre-command-hook))

;; after every command: an expanded panel that no longer matches its
;; buffer rebuilds itself — modes, group, model all change under it
(define (post-command!)
  (let ((buf (current-buffer)))
    ;; The dashboard is not rebuilt here. It is derived state, and a
    ;; keystroke derives nothing new: it was recomputed for every command
    ;; in the buffer the command ran in, at 16ms a key, and the line it
    ;; produced was almost always the line already there. It is rebuilt
    ;; when a window shows a dirty buffer (dashboard--catchup!), and the
    ;; event that changes a live buffer's line -- a jj change, a summary,
    ;; a restore, a group move -- calls dashboard--sync! on it itself.
    (list-post-command! buf)
    ;; a list on screen shows what is, not what was: the command may have
    ;; killed a buffer the list beside it still names
    (for-each (lambda (w)
                (unless (equal? (cadr w) buf)
                  (list-post-command! (cadr w))))
              (window-list))
    (when (buffer-local buf 'modeline-expanded)
      (let ((fp (dash--fingerprint buf)))
        (unless (equal? fp (buffer-local buf 'modeline-dash-fp))
          (buffer-set-local! buf 'modeline-dash-fp fp)
          (buffer-set-local! buf 'modeline-dash-blocks (dashboard-blocks buf)))))
    ;; the extension seam: packages react to the command that just ran
    ;; (paredit paints the matching delimiter here)
    (run-hooks 'post-command-hook)))

;; members in MRU order; buffers never visited this session trail
;; behind. A group is a SET: the list dedupes by name, whatever the
;; sources produce.
(define (dedupe-names xs)
  (let loop ((xs xs) (seen '()) (out '()))
    (cond ((null? xs) (reverse out))
          ((member (car xs) seen) (loop (cdr xs) seen out))
          (else (loop (cdr xs) (cons (car xs) seen) (cons (car xs) out))))))

(define (chat-buffer? b)
  (equal? (buffer-local b 'mode-name) "chat-mode"))

;;; --- the public API of this file ----------------------------------------------
;;; The catalog scope of each entry is the one it had in editor.scm.

(domain! 'windows)
(effects! '(write))
(category! 'windows)
(public! 'define-mode-headline!
  "(define-mode-headline! MODE '(mode group llm wide)) — which headline segments MODE keeps in a narrow window")
(domain! 'unknown)
(effects! '(unknown))
(category! 'interaction)
(catalog-meta! 'function "define-mode-headline!" 'domain 'windows 'effects '(write))
(public! 'buffer-modeline-name "(buffer-modeline-name BUF) — BUF's name for the modeline: project-relative, or ~ for home")
(public! 'name-segments "(name-segments SPEC [ICONS]) — the ((CLASS TEXT) ...) spans SPEC draws: *strong* ~dim~ `mono` :icon:; ICONS is ((KEY GLYPH) ...) the caller adds")
(public! 'name-format-expand "(name-format-expand FORMAT VALS) — fill a name format's %-directives from ((KEY VALUE) ...)")
(public! 'name-text "(name-text SEGMENTS) — the rendered name as one plain string")
(public! 'name-icon! "(name-icon! KEY GLYPH) — register the icon :KEY: reaches in a name")
(public! 'preset-icon! "(preset-icon! 'NAME GLYPH) — the glyph a tool preset shows on the mode line")
(catalog-meta! 'function "preset-icon!" 'domain 'interaction 'effects '(write))
(public! 'buffer-name-segments "(buffer-name-segments BUF) — the spans that draw BUF's name, from the buffer-local name-format or buffer-name-format")
(catalog-meta! 'function "name-segments" 'domain 'interaction 'effects '(pure))
(catalog-meta! 'function "name-format-expand" 'domain 'interaction 'effects '(pure))
(catalog-meta! 'function "name-text" 'domain 'interaction 'effects '(pure))
(catalog-meta! 'function "name-icon!" 'domain 'interaction 'effects '(write))
(catalog-meta! 'function "buffer-name-segments" 'domain 'interaction 'effects '(read))

(domain! 'unknown)
(effects! '(unknown))
