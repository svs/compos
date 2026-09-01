# Faces

A face is a named set of display attributes. The editor holds one table,
`name -> attrs`, shared by every frame. Scheme owns the names, the
defaults, and the themes. `Compos.Ui.FaceCSS` is the one place a face
becomes CSS.

## Attributes

| attribute    | CSS                      |
|--------------|--------------------------|
| `fg`         | `color`                  |
| `bg`         | `background`             |
| `weight`     | `font-weight` (`"700"`)  |
| `style`      | `font-style` (`"italic"`)|
| `family`     | `font-family`            |
| `size`       | `font-size`              |
| `decoration` | `text-decoration`        |
| `inherit`    | a face, or a list of faces |
| `priority`   | an integer, default 0    |

Any other attribute becomes a CSS variable `--NAME-ATTR` and nothing
else. `chrome` uses `gap`, `radius`, `border`, `shadow` this way.

A face writes only the attributes it sets. An unset attribute means
"leave it alone", as in Emacs. A span that carries two faces keeps the
syntax colour of one under the background of the other.

`inherit` supplies an attribute the face does not set. The first face
in a list wins. The class rule reads the parent's variable, so a
per-buffer remap of the parent reaches the child.

`priority` orders the class rules. Two overlays on one span resolve by
rule order, so the face with the higher priority wins. Ties break by
name.

## Defaults and themes

`(defface! FACE ATTR VALUE ...)` is a package's default. It applies
attribute by attribute: an attribute the current theme names for this
face is skipped, every other one is set. A package reload re-runs its
`defface!` forms without touching the theme's colours.

`(define-theme NAME SPECS)` registers a theme. `(load-theme NAME)`
clears every face the outgoing theme, the incoming theme, or a default
names, applies the defaults, then applies the theme on top. An attribute
the last theme set and this one does not is gone. The theme name is
persisted; the faces are derived again at boot, never restored from the
desktop.

## Syntax faces

Tree-sitter emits a span with the class `ts-SCOPE`, where SCOPE is the
capture name cut at its first dot. A face named `ts-SCOPE` styles that
span. Every theme colours the common scopes. `themes.scm` declares the
weight and slant of those as defaults, and gives the rarer scopes
(`ts-label`, `ts-parameter`, `ts-constructor`, ...) an `inherit` to the
nearest common one.

## Emacs names

`themes.scm` declares the Emacs face names as inherits of the compos
faces that draw the same thing: `font-lock-keyword-face` inherits
`ts-keyword`, `mode-line` inherits `modeline`, `success` inherits `ok`,
`shadow` inherits `dim`, and so on. `bold`, `italic`, `underline`,
`fixed-pitch`, `variable-pitch` are plain defaults. A package written
for Emacs can name them and get the theme's colour.

## Reading faces

`(face-attribute FACE ATTR)` returns the value the face sets, or `#f`.
`(face-list)` returns every face name. `(face-clear! FACE)` forgets a
face.
