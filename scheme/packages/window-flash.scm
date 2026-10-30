;;; window-flash.scm --- a chat says where it stands as it comes to the
;;; front. Cycling a pane (pane-next-window, pane-previous-window) to a chat
;;; flashes a card over its window for a moment: the chat's title, its last
;;; summary and its state. Other buffers flash nothing.

(require 'panes-mode)

(domain! 'windows)
(effects! '(read))

(define (window-flash--state buf)
  (let* ((s (buffer-local buf 'chat-goal-status))
         (s (cond ((symbol? s) (symbol->string s)) ((string? s) s) (else "idle"))))
    (if (buffer-local buf 'chat-turn-active) (string-append s " · running") s)))

(define (window-flash-card buf)
  "(TITLE SUMMARY STATE) a window flashes for the chat BUF, or #f for any other buffer."
  (and (equal? (buffer-local buf 'mode-name) "chat-mode")
       (let ((s (buffer-local buf 'chat-summary)))
         (list (or (chat-title-of buf) buf)
               (if (string? s) s "")
               (window-flash--state buf)))))

(effects! '(write))

(define window-flash-ms 15000)
(define window-flash--nonce 0)
(define window-flash--buf #f)

(define (window-flash--clear! buf)
  (when (and buf (buffer-known? buf)) (buffer-set-locals! buf '(window-flash #f))))

(define (window-flash! win buf)
  "Flash the chat BUF's card over window WIN, which shows it; #f for a
   buffer that is not a chat. The card stays for window-flash-ms after
   the last flash and fades at its end; the next flash replaces it."
  (unless (equal? window-flash--buf buf) (window-flash--clear! window-flash--buf))
  (set! window-flash--buf #f)
  (let ((card (window-flash-card buf)))
    (and card
         (begin
           (set! window-flash--nonce (+ window-flash--nonce 1))
           (set! window-flash--buf buf)
           (buffer-set-locals! buf (list 'window-flash (cons win (cons window-flash--nonce card))))
           (debounce! 'window-flash window-flash-ms
             (lambda (b) (window-flash--clear! b) (set! window-flash--buf #f)) buf)
           #t))))

(public! 'window-flash-card "(window-flash-card BUF) -> (TITLE SUMMARY STATE) a window flashes for the chat BUF, or #f")
(catalog-meta! 'function "window-flash-card" 'effects '(read))
(public! 'window-flash! "(window-flash! WIN BUF) -> flash the chat BUF's title, last summary and state over window WIN for a moment; #f for other buffers")
(catalog-meta! 'function "window-flash!" 'effects '(write display))

(define-style! 'window-flash "
.window-flash { position: absolute; inset: 0; z-index: 6; display: grid; place-items: center;
  pointer-events: none; container-type: size; animation: window-flash .12s ease-out, window-flash-out .6s ease-in 14.4s forwards; }
.window-flash-card { display: flex; flex-direction: column; align-items: center; gap: .5em;
  max-width: 82%; max-height: 80%; overflow: hidden; padding: .9em 1.3em; border-radius: 12px;
  background: color-mix(in srgb, var(--window-bg, #fdfcf8) 88%, transparent);
  box-shadow: 0 6px 30px rgba(0,0,0,.18); backdrop-filter: blur(3px); text-align: center; }
.window-flash-title { font-size: clamp(20px, 5.5cqi, 64px); font-weight: 650; line-height: 1.1;
  color: var(--accent-fg, #26356b); overflow-wrap: anywhere; }
.window-flash-summary { font-size: clamp(13px, 2.4cqi, 26px); line-height: 1.3; color: inherit;
  overflow: hidden; display: -webkit-box; -webkit-line-clamp: 4; -webkit-box-orient: vertical; }
.window-flash-state { font: 600 clamp(11px, 1.6cqi, 18px) var(--font-mono); text-transform: uppercase;
  letter-spacing: .06em; padding: .2em .7em; border-radius: 999px; color: var(--dim-fg, #8a857a);
  border: 1px solid currentColor; }
.window-flash-state.working { color: var(--accent-fg, #26356b); }
.window-flash-state.success { color: var(--ok-fg, #2e6b45); }
.window-flash-state.blocked { color: var(--error-fg, #9b2c2c); }
.window-flash-state.needs-you { color: var(--warn-fg, #7a5a1a); }
@keyframes window-flash { from { opacity: 0; transform: scale(.96); } to { opacity: 1; transform: none; } }
@keyframes window-flash-out { to { opacity: 0; } }
")

(provide 'window-flash)
