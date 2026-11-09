// fullscreen.js -- toggle-frame-fullscreen (vscode.scm) asks for
// fullscreen through the editor root's data-fullscreen: "TOKEN" or
// "TOKEN lock", from frame chrome. A new token toggles fullscreen in
// this tab. With "lock", the Keyboard Lock API also takes the keys the
// browser keeps (Cmd-W, Cmd-T, Cmd-N, Cmd-1..9, Ctrl-Tab); keySpec in
// app.js still decides which of them the editor gets. Leaving fullscreen
// gives the keys back. Chrome needs the keystroke that ran the command:
// a tab with no recent key or click stays as it is.
(() => {
  let seen = null;

  function toggle(lock) {
    if (document.fullscreenElement) {
      document.exitFullscreen().catch(() => {});
      return;
    }
    document.documentElement.requestFullscreen()
      .then(() => {
        if (lock && navigator.keyboard && navigator.keyboard.lock) {
          return navigator.keyboard.lock();
        }
      })
      .catch(() => {});
  }

  // the token the page holds when it loads is an old request: keep it.
  // The script runs after the body, so the editor root is there.
  function check() {
    const root = document.getElementById("editor");
    if (!root) return;
    const value = root.dataset.fullscreen || "";
    if (seen === null) { seen = value; return; }
    if (value === seen) return;
    seen = value;
    if (value) toggle(value.split(" ")[1] === "lock");
  }

  document.addEventListener("fullscreenchange", () => {
    if (!document.fullscreenElement && navigator.keyboard && navigator.keyboard.unlock) {
      navigator.keyboard.unlock();
    }
  });

  new MutationObserver(check).observe(document.documentElement, {
    subtree: true, attributes: true, attributeFilter: ["data-fullscreen"],
  });
  check();
})();
