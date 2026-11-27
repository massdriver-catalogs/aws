(() => {
  const studio = document.querySelector(".studio");
  const lab = studio.dataset.lab;
  const list = document.getElementById("messages");
  const form = document.getElementById("say");
  const text = document.getElementById("text");
  const send = document.getElementById("send");
  const stop = document.getElementById("stop");
  const state = document.getElementById("state");
  const game = document.getElementById("game");
  const intro = list.querySelector(".intro");

  let busy = false;
  let wasBusy = false;
  let lastSeen = "";
  let timer = null;
  let napping = false;

  // Opening the lab page again wakes the box, and keeps what was being typed.
  const draftKey = "gamelab-draft-" + lab;
  try {
    const draft = sessionStorage.getItem(draftKey);
    if (draft) text.value = draft;
    sessionStorage.removeItem(draftKey);
  } catch {}
  function nap() {
    napping = true;
    clearTimeout(timer);
    state.textContent = "Napping";
    document.getElementById("nap").hidden = false;
    send.disabled = true;
  }
  document.getElementById("wake").addEventListener("click", () => {
    try {
      if (text.value.trim()) sessionStorage.setItem(draftKey, text.value);
    } catch {}
    location.reload();
  });

  function reloadGame() {
    game.src = studio.dataset.play + "?t=" + Date.now();
  }
  document.getElementById("reload").addEventListener("click", reloadGame);

  // Safari on iPad only knows the prefixed names. The whole Play panel goes
  // full screen, so Reload and the way back stay in reach; a browser that
  // can't do it opens the game on its own page instead.
  const panel = game.closest(".play");
  const fullButton = document.getElementById("full");
  // Real full screen on an iPad stops the game and asks whether you meant to
  // type whenever a key is pressed, so there the panel just covers the page.
  const ipad = navigator.maxTouchPoints > 1 && /iPad|Macintosh/.test(navigator.userAgent);
  function isFull() { return document.fullscreenElement || document.webkitFullscreenElement || panel.classList.contains("cover"); }
  function cover(on) {
    panel.classList.toggle("cover", on);
    document.body.classList.toggle("covered", on);
    fullButton.textContent = on ? "Exit full screen" : "Full screen";
    game.focus();
  }
  fullButton.addEventListener("click", () => {
    if (panel.classList.contains("cover")) return cover(false);
    if (ipad) return cover(true);
    if (isFull()) {
      (document.exitFullscreen || document.webkitExitFullscreen).call(document);
      return;
    }
    const enter = panel.requestFullscreen || panel.webkitRequestFullscreen;
    if (!enter) {
      window.open(studio.dataset.play, "_blank", "noopener");
      return;
    }
    Promise.resolve(enter.call(panel)).catch(() => window.open(studio.dataset.play, "_blank", "noopener"));
  });
  ["fullscreenchange", "webkitfullscreenchange"].forEach((name) =>
    document.addEventListener(name, () => {
      fullButton.textContent = isFull() ? "Exit full screen" : "Full screen";
      game.focus();
    }));

  function el(tag, cls, content) {
    const node = document.createElement(tag);
    if (cls) node.className = cls;
    if (content !== undefined) node.textContent = content;
    return node;
  }

  // Agent replies are plain text with light markdown; only paragraphs and
  // bold survive, and everything goes in as text, never as HTML.
  function paragraphs(body) {
    const frag = document.createDocumentFragment();
    for (const chunk of body.split(/\n{2,}/)) {
      const p = el("p");
      const lines = chunk.replace(/^#+\s*/gm, "").replace(/^[-*]\s+/gm, "• ").split("\n");
      lines.forEach((line, i) => {
        line.split(/(\*\*[^*]+\*\*)/).forEach((piece) => {
          if (/^\*\*[^*]+\*\*$/.test(piece)) p.appendChild(el("strong", "", piece.slice(2, -2)));
          else if (piece) p.appendChild(document.createTextNode(piece.replace(/`/g, "")));
        });
        if (i < lines.length - 1) p.appendChild(document.createElement("br"));
      });
      frag.appendChild(p);
    }
    return frag;
  }

  function render(messages) {
    const key = JSON.stringify(messages);
    if (key === lastSeen) return;
    lastSeen = key;
    list.replaceChildren(intro);
    for (const m of messages) {
      const li = el("li", "msg " + (m.role === "user" ? "user" : "assistant"));
      if (m.text) li.appendChild(paragraphs(m.text));
      if (m.actions && m.actions.length) {
        const ul = el("ul", "actions");
        for (const a of m.actions.slice(-6)) ul.appendChild(el("li", "", a));
        if (m.actions.length > 6) ul.prepend(el("li", "more", "and " + (m.actions.length - 6) + " more steps"));
        li.appendChild(ul);
      }
      if (m.error) li.appendChild(el("p", "error", m.error));
      list.appendChild(li);
    }
    list.scrollTop = list.scrollHeight;
  }

  function setBusy(b) {
    busy = b;
    studio.classList.toggle("busy", b);
    state.textContent = b ? "Building..." : "Ready";
    stop.hidden = !b;
    send.disabled = b;
  }

  async function refresh() {
    try {
      const res = await fetch(`/labs/${lab}/chat`, { headers: { accept: "application/json" } });
      if (res.status === 401) return location.assign("/login");
      const data = await res.json();
      if (data.asleep) return nap();
      if (!res.ok) {
        state.textContent = data.error || "The lab isn't answering.";
        return;
      }
      render(data.messages);
      setBusy(data.busy);
      // A finished turn usually changed the game.
      if (wasBusy && !data.busy) reloadGame();
      wasBusy = data.busy;
    } catch {
      state.textContent = "Reconnecting...";
    } finally {
      clearTimeout(timer);
      if (!napping) timer = setTimeout(refresh, busy ? 1500 : 4000);
    }
  }

  async function post(path, body) {
    const res = await fetch(`/labs/${lab}/${path}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body || {}),
    });
    if (res.status === 401) location.assign("/login");
    if (!res.ok) {
      const data = await res.json().catch(() => ({}));
      if (data.asleep) {
        // The send woke the box; reopening the page waits for it.
        try {
          sessionStorage.setItem(draftKey, body && body.text ? body.text : "");
        } catch {}
        location.reload();
        return new Promise(() => {});
      }
      throw new Error(data.error || "That didn't work.");
    }
  }

  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    const words = text.value.trim();
    if (!words || busy) return;
    send.disabled = true;
    const pending = el("li", "msg user pending");
    pending.appendChild(paragraphs(words));
    list.appendChild(pending);
    list.scrollTop = list.scrollHeight;
    text.value = "";
    try {
      await post("chat", { text: words });
      wasBusy = true;
      setBusy(true);
    } catch (err) {
      pending.appendChild(el("p", "error", err.message));
      send.disabled = false;
    }
    refresh();
  });

  text.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      form.requestSubmit();
    }
  });

  stop.addEventListener("click", () => post("stop").catch(() => {}).finally(refresh));

  // Young players talk faster than they type. Tap Talk, say it, and when they
  // stop talking it sends on its own. Safari on iPad needs Siri and
  // Dictation turned on, and asks once to use the microphone.
  const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition;
  const mic = document.getElementById("mic");
  if (Recognition) {
    mic.hidden = false;
    let listening = null;
    mic.addEventListener("click", () => {
      if (listening) {
        listening.stop();
        return;
      }
      const rec = new Recognition();
      rec.lang = navigator.language || "en-US";
      rec.interimResults = true;
      rec.continuous = false;
      const before = text.value.trim();
      let heard = "";
      rec.onresult = (e) => {
        heard = Array.from(e.results).map((r) => r[0].transcript).join(" ").trim();
        text.value = (before ? before + " " : "") + heard;
      };
      rec.onerror = (e) => {
        if (e.error === "not-allowed" || e.error === "service-not-allowed") {
          text.placeholder = "The microphone is off. A grown-up can turn it on in Settings, or tap the 🎤 on the keyboard.";
        }
      };
      rec.onend = () => {
        listening = null;
        mic.classList.remove("listening");
        mic.setAttribute("aria-pressed", "false");
        mic.textContent = "🎤 Talk";
        if (heard && !busy) form.requestSubmit();
      };
      listening = rec;
      mic.classList.add("listening");
      mic.setAttribute("aria-pressed", "true");
      mic.textContent = "● Listening";
      rec.start();
    });
  }

  refresh();
})();
