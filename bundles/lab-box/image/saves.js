// Lets a game remember things: saves that last between visits, and a
// high-score list. The game's sandboxed frame has no localStorage, so both go
// to the lab box. In a lab without Saves & scores, or if the box can't be
// reached, they're kept in memory until the game reloads, so a game works the
// same either way.
(function () {
  var script = document.currentScript;
  var base = script && script.src ? script.src.replace(/lib\/saves\.js(\?.*)?$/, "") : "";
  var api = base + "api/";
  var TOP = 10;
  var memory = { saves: {}, boards: {} };
  var lasting = null;

  function call(method, path, body) {
    var opts = { method: method, cache: "no-store" };
    if (body !== undefined) {
      // text/plain keeps it a simple request, so the browser sends it without asking first.
      opts.headers = { "content-type": "text/plain" };
      opts.body = JSON.stringify(body);
    }
    return fetch(api + path, opts).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (data) {
        return { ok: r.ok, status: r.status, data: data };
      });
    }, function () {
      return { ok: false, status: 0, data: {} };
    });
  }

  function warn(what, res) {
    if (res.status !== 503 && res.status !== 0) console.warn("Gamelab." + what + ": " + (res.data.error || res.status));
  }

  function copy(value) {
    return value === undefined ? null : JSON.parse(JSON.stringify(value));
  }

  // Names on the list are first names or nicknames: letters only, up to 12.
  function cleanName(name) {
    var clean = String(name == null ? "" : name).replace(/[^A-Za-z '-]/g, "").replace(/\s+/g, " ").trim();
    clean = clean.replace(/^[^A-Za-z]+/, "").slice(0, 12).trim();
    return clean || "Player";
  }

  function savesOn() {
    if (lasting !== null) return Promise.resolve(lasting);
    return call("GET", "status").then(function (res) {
      lasting = !!(res.ok && res.data.saves);
      return lasting;
    });
  }

  // save("level", { level: 3 }) or save({ level: 3 }) for the "main" slot.
  // Resolves true when the save will still be there next visit.
  function save(slot, data) {
    if (data === undefined && typeof slot !== "string") { data = slot; slot = "main"; }
    memory.saves[slot] = copy(data);
    return call("PUT", "save", { slot: slot, data: data }).then(function (res) {
      if (!res.ok) warn("save", res);
      return res.ok;
    });
  }

  // Resolves what was saved in the slot, or null if nothing was.
  function load(slot) {
    slot = slot || "main";
    return call("GET", "load?slot=" + encodeURIComponent(slot)).then(function (res) {
      if (res.ok) return res.data.data;
      if (res.status === 404) return null;
      warn("load", res);
      return slot in memory.saves ? copy(memory.saves[slot]) : null;
    });
  }

  function remember(board, name, score) {
    var list = memory.boards[board] || [];
    var entry = { name: name, score: score, at: Date.now() };
    var best = !list.length || score > list[0].score;
    list.push(entry);
    list.sort(function (a, b) { return b.score - a.score || a.at - b.at; });
    memory.boards[board] = list.slice(0, TOP);
    var rank = memory.boards[board].indexOf(entry) + 1 || null;
    return { rank: rank, best: best && rank === 1, scores: memory.boards[board].slice() };
  }

  // Resolves the top ten, best first: [{ name, score, at }].
  function scores(board) {
    board = board || "main";
    return call("GET", "scores?board=" + encodeURIComponent(board)).then(function (res) {
      if (res.ok) return res.data.scores;
      warn("scores", res);
      return (memory.boards[board] || []).slice();
    });
  }

  // Resolves { rank, best, scores }: rank is 1 to 10, or null if it didn't
  // make the list; best is true for a new top score.
  function addScore(name, score, board) {
    board = board || "main";
    name = cleanName(name);
    score = Math.max(0, Math.min(999999999, Math.floor(Number(score) || 0)));
    return call("POST", "scores", { name: name, score: score, board: board }).then(function (res) {
      if (res.ok) return { rank: res.data.rank, best: res.data.best, scores: res.data.scores };
      warn("addScore", res);
      return remember(board, name, score);
    });
  }

  var G = window.Gamelab || (window.Gamelab = {});
  G.savesOn = savesOn;
  G.save = save;
  G.load = load;
  G.scores = scores;
  G.addScore = addScore;
})();
