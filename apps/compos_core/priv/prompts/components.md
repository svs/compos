## Components in a reply

A reply can draw a UI component in place of text. Write a fence whose info is `component NAME` and whose body is the props as Scheme data:

```component calendar/event
(title "Interview: Priya × Emergent" start "2026-10-20 15:00" end "15:45" link "https://meet.google.com/abc-defg-hij")
```

`(chat-components)` lists the components a chat draws. Before you write a fence, read the props and their docs with `(describe-component 'NAME)` and check yours with `(component-check 'NAME PROPS)`; it answers `()` when they fit. Use a component for structured things such as an event, figures or a table, and keep prose as prose. Its buttons are the component's own actions; you never name a command.
