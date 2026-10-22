// doom.js --- the page script of M-x doom (doom.scm). doom-install and
// every open copy it beside doom.html, and the app server serves it
// from there with the engine and the IWAD.
(function () {
  var statusEl = document.getElementById("status");
  var canvas = document.getElementById("canvas");

  function say(text) {
    if (!text) return;
    statusEl.firstChild.nodeValue = text;
  }

  // The canvas must hold the keyboard, or SDL sees nothing. A click
  // anywhere in the frame gives it back.
  function focusCanvas() { try { canvas.focus(); } catch (e) {} }
  canvas.addEventListener("contextmenu", function (e) { e.preventDefault(); });
  window.addEventListener("click", focusCanvas);
  window.addEventListener("focus", focusCanvas);

  window.Module = {
    canvas: canvas,
    noInitialRun: true,
    preRun: [function () {
      Module.FS.createPreloadedFile("", "doom1.wad", "doom1.wad", true, true);
      Module.FS.createPreloadedFile("", "default.cfg", "default.cfg", true, true);
    }],
    print: function (text) { console.log(text); },
    printErr: function (text) { console.error(text); },
    setStatus: function (text) { say(text || "starting"); },
    onRuntimeInitialized: function () {
      statusEl.className = "gone";
      focusCanvas();
      // the engine glue defines callMain as a plain global, not on Module
      var main = window.callMain || Module.callMain;
      main(["-iwad", "doom1.wad", "-window", "-nogui", "-nomusic",
            "-config", "default.cfg"]);
      setTimeout(focusCanvas, 300);
    },
    onAbort: function (what) { statusEl.className = ""; say("doom stopped: " + what); }
  };

  window.addEventListener("error", function (e) {
    statusEl.className = "";
    say("doom failed to start");
    console.error(e && e.error);
  });
})();
