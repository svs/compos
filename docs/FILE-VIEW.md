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

Use `C-x C-q` to leave the browser viewer and expose the file bytes as text.
This is useful for inspection, but ordinary editing cannot safely modify a
binary file.
