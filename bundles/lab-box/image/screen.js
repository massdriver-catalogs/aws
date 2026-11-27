// Kids play on iPads as often as laptops. Loaded first in every game, this
// makes the page behave like an app: it fills the screen in either
// orientation, never scrolls or zooms when a finger drags or double-taps,
// draws sharp on Retina screens, and offers big on-screen buttons that press
// the same keys a keyboard would.
(function () {
  var head = document.head || document.getElementsByTagName("head")[0];

  var viewport = document.querySelector('meta[name="viewport"]');
  if (!viewport) {
    viewport = document.createElement("meta");
    viewport.name = "viewport";
    head.appendChild(viewport);
  }
  viewport.content = "width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover";

  var style = document.createElement("style");
  style.textContent =
    "html,body{margin:0;padding:0;width:100%;height:100%;height:100dvh;overflow:hidden;" +
    "overscroll-behavior:none;touch-action:none;-webkit-user-select:none;user-select:none;" +
    "-webkit-touch-callout:none;-webkit-tap-highlight-color:transparent;}" +
    "canvas{display:block;touch-action:none;}" +
    ".gl-pad{position:fixed;bottom:calc(16px + env(safe-area-inset-bottom));display:flex;gap:12px;z-index:9999;}" +
    ".gl-pad.gl-left{left:calc(16px + env(safe-area-inset-left));}" +
    ".gl-pad.gl-right{right:calc(16px + env(safe-area-inset-right));}" +
    ".gl-btn{width:72px;height:72px;border-radius:50%;border:3px solid rgba(255,255,255,.7);" +
    "background:rgba(255,255,255,.18);color:#fff;font:700 28px system-ui,sans-serif;" +
    "display:grid;place-items:center;touch-action:none;}" +
    ".gl-btn.gl-down{background:rgba(255,255,255,.45);}";
  head.appendChild(style);

  ["gesturestart", "gesturechange", "dblclick"].forEach(function (name) {
    document.addEventListener(name, function (e) { e.preventDefault(); }, { passive: false });
  });
  document.addEventListener("touchmove", function (e) { e.preventDefault(); }, { passive: false });

  var touch = "ontouchstart" in window || navigator.maxTouchPoints > 0;

  // fitCanvas sizes a canvas to the whole screen at the device's pixel
  // density, and again whenever the screen turns. onResize gets the size in
  // CSS pixels; draw in those units, the scale is already applied.
  function fitCanvas(canvas, onResize) {
    var ctx = canvas.getContext("2d");
    function fit() {
      var dpr = Math.min(window.devicePixelRatio || 1, 2);
      var w = window.innerWidth, h = window.innerHeight;
      canvas.style.width = w + "px";
      canvas.style.height = h + "px";
      canvas.width = Math.round(w * dpr);
      canvas.height = Math.round(h * dpr);
      if (ctx) ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      if (onResize) onResize(w, h);
    }
    window.addEventListener("resize", fit);
    window.addEventListener("orientationchange", function () { setTimeout(fit, 250); });
    fit();
    return ctx;
  }

  function press(key, down) {
    var codes = { ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39, ArrowDown: 40, " ": 32, Enter: 13 };
    var code = key === " " ? "Space" : key;
    var init = { key: key, code: code, keyCode: codes[key] || 0, which: codes[key] || 0, bubbles: true };
    window.dispatchEvent(new KeyboardEvent(down ? "keydown" : "keyup", init));
    document.dispatchEvent(new KeyboardEvent(down ? "keydown" : "keyup", init));
  }

  // touchButtons shows round buttons only on touch screens. Each one holds
  // its key down while a finger is on it, so the game's keyboard code works
  // unchanged. Example: touchButtons({ left: ["ArrowLeft", "ArrowRight"], right: [" "] }).
  function touchButtons(layout) {
    if (!touch) return;
    var labels = { ArrowLeft: "◀", ArrowRight: "▶", ArrowUp: "▲", ArrowDown: "▼", " ": "●", Enter: "★" };
    ["left", "right"].forEach(function (side) {
      var keys = (layout && layout[side]) || [];
      if (!keys.length) return;
      var pad = document.createElement("div");
      pad.className = "gl-pad gl-" + side;
      keys.forEach(function (key) {
        var b = document.createElement("div");
        b.className = "gl-btn";
        b.textContent = labels[key] || key;
        b.addEventListener("pointerdown", function (e) { e.preventDefault(); b.classList.add("gl-down"); press(key, true); });
        ["pointerup", "pointercancel", "pointerleave"].forEach(function (n) {
          b.addEventListener(n, function () { if (b.classList.contains("gl-down")) { b.classList.remove("gl-down"); press(key, false); } });
        });
        pad.appendChild(b);
      });
      (document.body || document.documentElement).appendChild(pad);
    });
  }

  window.Gamelab = { fitCanvas: fitCanvas, touchButtons: touchButtons, touch: touch };
})();
