// appearance.js -- tells the editor the system's light or dark
// appearance (prefers-color-scheme), when the editor hook mounts and when
// the system changes it. theme-follow-system (appearance.scm) decides
// what the theme does. One listener for the page; each mount gives it the
// hook to push through, so a reconnect adds no second listener.
(() => {
  const query = window.matchMedia ? matchMedia("(prefers-color-scheme: dark)") : null;
  let hook = null;

  function send() {
    if (!hook || !query) return;
    try {
      Promise.resolve(hook.pushEvent("appearance", { dark: query.matches })).catch(() => {});
    } catch (_) {}
  }

  if (query) query.addEventListener("change", send);

  window.composAppearance = {
    watch(h) { hook = h; send(); },
  };
})();
