---
name: explainer
description: Write an explainer for the user: a morg page with SVG diagrams, shown in preview in the other window. Load when the user asks you to explain, diagram or draw how something works.
---

# Write an explainer

An explainer is one morg file and its SVG diagrams in one directory. The
user reads it in preview mode in the editor. It never goes through the
browser reader, an HTML page or tldraw.

## Where it goes

`~/.compos/explainers/SLUG/`, with `SLUG.md` and one `.svg` file for each
diagram. SLUG is a short kebab-case name for the topic. Do not write an
explainer into the repository unless the user asks.

## Get the facts first

Every claim in the explainer must come from the code or the live editor,
not from memory. Read with `(code-outline BUF)`, `(code-read BUF LINE)` and
`(project-search-matches ROOT PATTERN)`. Give `file:line` for each part
you name, so the user can go there.

## The page

- One `#` title, then one paragraph that says the problem or the question.
- One `##` section for each idea: how it works today, the parts, the fix,
  the open questions.
- Put a diagram where a flow or a structure has more than three steps.
  Use a table for a list of parts. Use a `text` fence for a literal
  message or output.
- Plain ASCII. Short sentences. Explain at the level of commands, modes
  and functions the user knows.

A diagram is a Markdown image with a path relative to the page:

```markdown
![The send path today](before.svg)
```

The preview draws local images through `/local-image/`, so the SVG shows
inside the page.

## Diagrams

Write each SVG with `(write-file! PATH SVG)`. Draw flows top to bottom:
one box for each step, an arrow between boxes, a main line and a dim
second line in each box. Mark a step that goes wrong red and a step that
the fix adds green. Keep the width at 640 so the preview does not scale it.

This helper draws a flow. STEPS is a list of `(MAIN SUB TONE)`, where TONE
is `plain`, `bad` or `good`. Eval it once, then call it for each diagram:

```scheme
(define (xp--esc s)
  (string-replace (string-replace (string-replace s "&" "&amp;") "<" "&lt;") ">" "&gt;"))

(define (xp-flow-svg title steps)
  (let* ((w 640) (bw 520) (bh 58) (gap 30) (top 48) (x (/ (- w bw) 2))
         (h (+ top (* (length steps) (+ bh gap))))
         (box (lambda (i st)
                (let* ((y (+ top (* i (+ bh gap))))
                       (tone (caddr st))
                       (stroke (cond ((eq? tone 'bad) "#c0392b") ((eq? tone 'good) "#27ae60") (else "#555")))
                       (fill (cond ((eq? tone 'bad) "#fdecea") ((eq? tone 'good) "#eafaf1") (else "#ffffff"))))
                  (string-append
                    "<rect x='" (number->string x) "' y='" (number->string y) "' width='" (number->string bw)
                    "' height='" (number->string bh) "' rx='8' fill='" fill "' stroke='" stroke "' stroke-width='2'/>"
                    "<text x='320' y='" (number->string (+ y 25)) "' class='m'>" (xp--esc (car st)) "</text>"
                    "<text x='320' y='" (number->string (+ y 45)) "' class='s'>" (xp--esc (cadr st)) "</text>"
                    (if (< i (- (length steps) 1))
                        (let ((ay (+ y bh)))
                          (string-append "<line x1='320' y1='" (number->string (+ ay 2)) "' x2='320' y2='"
                                         (number->string (+ ay gap -6))
                                         "' stroke='#555' stroke-width='2' marker-end='url(#a)'/>"))
                        ""))))))
    (let loop ((i 0) (ss steps) (acc ""))
      (if (null? ss)
          (string-append
            "<svg xmlns='http://www.w3.org/2000/svg' width='" (number->string w) "' height='" (number->string h)
            "' viewBox='0 0 " (number->string w) " " (number->string h) "'>"
            "<defs><marker id='a' viewBox='0 0 10 10' refX='8' refY='5' markerWidth='7' markerHeight='7' orient='auto'>"
            "<path d='M0,0 L10,5 L0,10 z' fill='#555'/></marker>"
            "<style>text{font-family:-apple-system,system-ui,sans-serif;text-anchor:middle}"
            ".t{font-size:18px;font-weight:600;fill:#222}.m{font-size:15px;fill:#222}.s{font-size:12px;fill:#666}</style></defs>"
            "<rect width='100%' height='100%' fill='#fafafa'/>"
            "<text x='320' y='28' class='t'>" (xp--esc title) "</text>" acc "</svg>")
          (loop (+ i 1) (cdr ss) (string-append acc (box i (car ss))))))))

(write-file! (expand-path "~/.compos/explainers/SLUG/before.svg")
  (xp-flow-svg "Today"
    '(("You press C-c RET" "chat-companion-ask" plain)
      ("The source buffer is lost" "group-ask! does not record it" bad))))
```

For a shape that is not a flow, such as boxes side by side or a tree,
write the SVG yourself in the same style: the same colors, fonts and
640 width.

## Show it

Only show the explainer when the user asked for it. Write the page with
`(write-file! PATH TEXT)` before it has a buffer. After that, edit its
buffer. Then:

```scheme
(let ((b (visit PATH GROUP)))
  (with-frame-windows (lambda () (window-set-buffer! (get-other-window) b)))
  (enable-minor-mode! b "preview-mode")
  (preview-heal! b))
```

GROUP comes from `(chat-context)`. The focus stays in the chat. Keep the
buffer when you are done: the user is reading it.

## Check it

- `(with-frame-windows (lambda () (window-list)))` shows the page in a
  window of the user's frame.
- `(minor-mode-on? PATH "preview-mode")` is `#t`.
- Each diagram loads: `(dom-eval "Array.from(document.querySelectorAll('img')).map(i=>i.getAttribute('src')+' '+i.naturalWidth).join(' | ')")`
  lists a `/local-image/` source with a width that is not 0 for each one.
