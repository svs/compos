# File viewing

File extension policy stays in Scheme. The UI only supplies a signed URL for
files that a browser can render safely.

## Native editor modes

- JSON opens in `json-mode`. Valid compact JSON is indented and stays editable.
- HTML and HTM open as source. `preview-mode` supplies an inert rendered page.
- Markdown, Org, and text use the existing document modes and preview policy.
- PDF uses `pdf-reader-mode`, which supplies pages, navigation, zoom, and search.
- Source file extensions continue to use their tree-sitter modes.

JSON formatting is lexical. It preserves `null`, booleans, number spelling,
string escapes, and object key order. Invalid JSON stays unchanged.

## Browser file mode

`browser-file-mode` opens these common browser-native formats:

| Kind | Extensions |
|---|---|
| Images | PNG, APNG, JPG, JPEG, JFIF, GIF, WebP, AVIF, BMP, ICO, SVG |
| Audio | MP3, WAV, OGG, OGA, Opus, WebA, M4A, AAC, FLAC |
| Video | MP4, WebM, OGV, MOV, M4V |

The mode is read-only and uses an inert iframe. The file route accepts only a
signed absolute path and an image, audio, or video MIME type. It sends no CORS
header and rejects structured text, archives, executables, and unknown types.
It answers a byte range with 206, because a player does not read a video from
the top: it reads the index at the end, then seeks. WebKit will not play a
file at all from a server that answers the whole of it to a range request.

## The buffer holds none of the file

A visit binds the buffer to the path and never reads the bytes. The browser
reads the file from disk through the signed route, so a 900 MB screen
recording opens as fast as a thumbnail, writes an empty checkpoint, and costs
no later boot anything. Reading one was how a 189 MB recording crashed the
editor.

Three things follow. `large-file-warning-threshold` and `preview-max-file-size`
do not apply to these files, because neither of them is a cost here. Nothing
in such a buffer can be written over the file: the `unread-file` write rule
refuses it, and no answer sets that rule aside. And auto-revert leaves these
buffers alone, because catching one up with its file would read the bytes the
viewer exists to avoid.

`file-shown-from-disk?` answers which paths open this way, and
`buffer-unread-file?` which buffers hold no bytes of their file.
