---
title: Slides in compos
theme: compos
transition: slide
---

<!-- build: up -->
# Slides in compos

A Markdown buffer, presented

???

Welcome. Press `s` to hide these notes, or keep them open while you present.

---

<!-- transition: zoom -->
## How it works??!

+ A line of `---` starts the next slide
+ A `+` item is a **step**: it waits for your key
+ Edit this buffer and the deck redraws, live
+ Click to go on; click the left third to go back
+ `s` shows the speaker notes · `o` overview · `f` fullscreen · `?` every key

???

These are speaker notes. Everything under a line of `???` stays off the slide and shows in the notes panel when you press `s`.

Notes can be as long as you like: the panel scrolls. They are Markdown too, so **bold**, `code` and lists work:

- what to say first
- the demo to run
- the question to ask the room

---

<!-- transition: cube -->
## Transitions

| Directive | Effect |
|---|---|
| `slide` `up` | push the deck along |
| `fade` `blur` | dissolve |
| `zoom` `flip` `cube` | depth |
| `iris` `wipe` | reveal |
| `morph` | magic move |

One per slide: `<!-- transition: cube -->` {step fade}

---

<!-- transition: flip; step: zoom -->
## Animations

End a block with `{step pop}` and it waits for a key. {step pop}

End it with `{blur}` and it animates as the slide arrives. {step blur}

`fade` `up` `down` `left` `right` `zoom` `pop` `spin` `blur` `flip` `drop` `type` {step drop}

---

<!-- transition: morph; class: center -->
## Magic move

<div class='row'><div id='a' class='box'>A</div><div id='b' class='box alt'>B</div><div id='c' class='box ghost'>C</div></div>

Blocks with the same `#id`, heading or text glide to their new place

---

<!-- transition: morph; class: center -->
<div class='row'><div id='c' class='box ghost big'>C</div><div id='a' class='box'>A</div></div>

## Magic move

---

<!-- transition: iris; class: center; bg: linear-gradient(135deg, #ff3cac, #784ba0 50%, #2b86c5) -->
# Backgrounds {zoom}

Any colour, gradient or image: `<!-- bg: ... -->` {up}

---

<!-- transition: fade; class: center; bg: https://images.unsplash.com/photo-1506905925346-21bda4d32df4?w=1920&q=80 -->
# Above the clouds {blur}

A photo fills the slide, and a shade keeps the words readable {up}

---

<!-- transition: zoom; bg: https://images.unsplash.com/photo-1519681393784-d120267933ba?w=1920&q=80 -->
## Night shift

`<!-- bg: https://…/stars.jpg -->` {step fade}

---

<!-- transition: slide -->
## Images

![Forest](https://images.unsplash.com/photo-1441974231531-c6227db76b6e?w=800&q=80) ![Lake](https://images.unsplash.com/photo-1493246507139-91e8fad9978e?w=800&q=80) ![Beach](https://images.unsplash.com/photo-1507525428034-b723cf961d3e?w=800&q=80)

A row of `![alt](url)` sits side by side {step up}

---

<!-- transition: fade -->
## Image size

![Lake](https://images.unsplash.com/photo-1493246507139-91e8fad9978e?w=1600&q=80 =fullx360)

`![alt](url =full)` fills the width. `=640`, `=x300` and `=100%x360` set width, height or both; a bare number is px {step up}

---

<!-- transition: blur; class: cols -->
## Picture and words

![Earth](https://images.unsplash.com/photo-1451187580459-43490279c0fa?w=1000&q=80)

- One image beside the text
- `class: cols` does the split
- Any URL or local path works

---

<!-- transition: blur; class: cols -->
## Layouts

```scheme
;; present any Markdown buffer
(slides-present! "deck.md")
```

- `class: cols` splits the page
- `title` `center` `top` `big` `accent`
- `theme:` dark, light, paper, neon, ocean, compos

---

<!-- transition: wipe; focus: on; step: left -->
## Focus

+ One point at a time
+ The newest one stays bright
+ The others step back

---

<!-- transition: zoom; class: accent center -->
# Thanks {pop}

Press `o` to see every slide at once {step type}
