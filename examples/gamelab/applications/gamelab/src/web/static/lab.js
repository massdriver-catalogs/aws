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

  function reloadGame() {
    game.src = studio.dataset.play + "?t=" + Date.now();
  }
  document.getElementById("reload").addEventListener("click", reloadGame);

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
      timer = setTimeout(refresh, busy ? 1500 : 4000);
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

  refresh();
})();
