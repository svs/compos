# Markdown: the rendered page

`Compos.Core.Markdown.Html` draws a Markdown buffer as the page a reader sees in the preview (an iframe) and in the rows renderer. The parser is tree-sitter; the renderer keeps these rules.

## Invariants

1. Every element says the byte it was drawn from (`data-src="START-STOP"`), and every run of text says where it began (`data-s`). A reader moving the caret asks the page where it landed, and the page answers exactly.
2. The page does not change when the caret moves. A caret mark is drawn as a span inside the structure; it never changes how the source parses.
3. The newline that ends a block is the end of the block, not a line inside it: drawn as a byte a caret can stand on, never as a break. A newline the author typed inside a paragraph is a line the reader has to see.
4. Markup is consumed and what it marked is drawn: the delimiters of emphasis, a fence's backticks, a link's destination are `@silent`.
5. A caller can upgrade one complete paragraph (a URL alone on a line becomes an embed). The renderer keeps that policy outside itself.

## Pictures and captions

Markdown has no caption syntax of its own. The page uses the shape most renderers agree on: a picture on a line of its own, and under it a line that is only emphasis.

```markdown
![alt](picture.png)
*The caption.*
```

1. That paragraph draws as `<figure data-src><img …><figcaption data-src>The caption.</figcaption></figure>`. The caption is not emphasis on the page: no `<em>`; the stylesheet sets it small, centred, and dim under the picture.
2. The line between the picture and the caption is a byte a caret can stand on, drawn without a break.
3. Anything else in the paragraph keeps it a paragraph: text before the picture, plain words under it, a line after the caption.
4. A picture alone stays a paragraph with an image.
5. The rows renderer (writing-mode, `markdown-paint`) paints the caption line as emphasis; it does not build a figure.

Tests: `apps/compos_core/test/compos/markdown_html_test.exs`.
