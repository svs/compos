// media-stop.js -- a sound or a video stops when its buffer goes.
// A playing <audio> or <video> plays on after LiveView takes it out of
// the page: killing the buffer, or showing another buffer in its window,
// would leave the sound running with nothing on screen to stop it. Every
// media element that leaves the document is paused here.
(() => {
  function stop(node) {
    if (node.nodeType !== 1) return;
    if (node.matches("audio, video")) node.pause();
    node.querySelectorAll("audio, video").forEach((m) => m.pause());
  }

  new MutationObserver((records) => {
    for (const r of records) r.removedNodes.forEach(stop);
  }).observe(document.documentElement, { subtree: true, childList: true });
})();
