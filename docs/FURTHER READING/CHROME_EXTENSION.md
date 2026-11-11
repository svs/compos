# Chrome extension

The extension connects compos to your own Chrome: M-x and C-x in any page,
`compos` in the address bar, and the `tab-*` / `browser-snapshot` calls that read
pages with your logins. Its source is `extension/`; `extension/README.md`
covers what it does in detail.

## Where it is

Every compos start copies the extension to one fixed folder:

    ~/.compos/chrome-extension

(`$COMPOS_HOME/chrome-extension` when `COMPOS_HOME` is set, and
`~/.compos-dev/chrome-extension` for a dev build from the checkout.) This is the same
whether compos runs from a checkout or from the release binary, and it does not
move between versions. The release carries the extension in
`priv/extension`; a checkout uses `extension/`. `Compos.Core.ChromeExtension`
does the copy.

## Install

1. Open `chrome://extensions`.
2. Turn on **Developer mode**, top right.
3. **Load unpacked**, and choose `~/.compos/chrome-extension`.
   In the macOS file picker, Cmd-Shift-G takes a typed path, and
   Cmd-Shift-. shows hidden folders such as `.compos`.

`M-x setup` walks the same steps and shows when the extension has connected;
`(browser-connected?)` answers the same from Scheme.

## Update

A new compos build rewrites `~/.compos/chrome-extension` at start. Press the
reload arrow on the extension's card in `chrome://extensions` to load it.

## Developing the extension

To see your edits without restarting compos, load `extension/` from the
checkout instead. Do not load both: two copies each claim the page.
