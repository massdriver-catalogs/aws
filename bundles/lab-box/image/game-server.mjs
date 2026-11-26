// Nothing is cached, so the Play panel shows the agent's latest change on
// every reload.
import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import { createServer } from "node:http";
import { extname, join, normalize, sep } from "node:path";

const GAME_DIR = process.env.GAME_DIR || "/home/player/game";
const LIB_DIR = "/opt/gamelab/lib";
const PORT = Number(process.env.GAME_PORT || 8080);
const PREFIX = "/play/";

const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".svg": "image/svg+xml",
  ".webp": "image/webp",
  ".ico": "image/x-icon",
  ".mp3": "audio/mpeg",
  ".ogg": "audio/ogg",
  ".wav": "audio/wav",
  ".woff2": "font/woff2",
  ".ttf": "font/ttf",
  ".glb": "model/gltf-binary",
  ".gltf": "model/gltf+json",
  ".wasm": "application/wasm",
  ".txt": "text/plain; charset=utf-8",
};

function send(res, code, body) {
  res.writeHead(code, { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" });
  res.end(body);
}

// Resolves a request path inside root, or null if it would leave it or touch
// a hidden file such as .env or .git.
function resolve(root, rel) {
  const clean = normalize("/" + rel).slice(1);
  if (clean.split(sep).some((p) => p.startsWith("."))) return null;
  const full = join(root, clean);
  return full === root || full.startsWith(root + sep) ? full : null;
}

async function serveFile(res, file, head) {
  let info;
  try {
    info = await stat(file);
    if (info.isDirectory()) {
      file = join(file, "index.html");
      info = await stat(file);
    }
  } catch {
    return send(res, 404, "Not here yet.\n");
  }
  res.writeHead(200, {
    "content-type": TYPES[extname(file).toLowerCase()] || "application/octet-stream",
    "content-length": info.size,
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
  });
  if (head) return res.end();
  createReadStream(file).pipe(res);
}

createServer(async (req, res) => {
  const url = new URL(req.url, "http://lab");
  const path = decodeURIComponent(url.pathname);

  if (path === "/healthz" || path === "/play/healthz") return send(res, 200, "ok\n");
  if (req.method !== "GET" && req.method !== "HEAD") return send(res, 405, "Games here are read-only.\n");
  if (path === "/" || path === "/play") {
    res.writeHead(302, { location: PREFIX });
    return res.end();
  }
  if (!path.startsWith(PREFIX)) return send(res, 404, "Games are under /play/.\n");

  const rel = path.slice(PREFIX.length);
  const file = rel.startsWith("lib/") ? resolve(LIB_DIR, rel.slice(4)) : resolve(GAME_DIR, rel);
  if (!file) return send(res, 404, "Not here.\n");
  return serveFile(res, file, req.method === "HEAD");
}).listen(PORT, "0.0.0.0", () => {
  console.error(`game server: ${GAME_DIR} at :${PORT}${PREFIX}`);
});
