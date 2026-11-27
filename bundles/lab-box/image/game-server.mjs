// Nothing is cached, so the Play panel shows the agent's latest change on
// every reload.
import { createHash, createHmac, randomBytes } from "node:crypto";
import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import { createServer } from "node:http";
import { extname, join, normalize, sep } from "node:path";

const GAME_DIR = process.env.GAME_DIR || "/home/player/game";
const LIB_DIR = "/opt/gamelab/lib";
const PORT = Number(process.env.GAME_PORT || 8080);
const PREFIX = "/play/";
const API = PREFIX + "api/";
const TABLE = process.env.GAMELAB_TABLE || "";
const REGION = process.env.GAMELAB_TABLE_REGION || process.env.AWS_REGION || "";

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

// Saves and scores live in the lab's own DynamoDB table, so they last across
// reloads, restarts and sleeps. The game's sandboxed frame has no lasting
// browser storage, so this is the only way a game remembers anything.

const LIMITS = {
  body: 16 * 1024, // bytes in a request
  data: 12 * 1024, // bytes of one save, as JSON
  slots: 20, // save slots per lab
  top: 10, // scores kept on each board
  writesPerMinute: 120,
};
const SLOT_RE = /^[A-Za-z0-9_-]{1,32}$/;
// First names and nicknames only: letters, so no numbers, emails or addresses.
const NAME_RE = /^[A-Za-z][A-Za-z '-]{0,11}$/;

let creds = null;

async function credentials() {
  if (creds && creds.expires - Date.now() > 5 * 60 * 1000) return creds;
  const uri = process.env.AWS_CONTAINER_CREDENTIALS_RELATIVE_URI;
  if (uri) {
    const r = await fetch("http://169.254.170.2" + uri, { signal: AbortSignal.timeout(3000) });
    if (!r.ok) throw new Error(`credentials: HTTP ${r.status}`);
    const c = await r.json();
    creds = { key: c.AccessKeyId, secret: c.SecretAccessKey, token: c.Token, expires: Date.parse(c.Expiration) };
  } else {
    creds = {
      key: process.env.AWS_ACCESS_KEY_ID,
      secret: process.env.AWS_SECRET_ACCESS_KEY,
      token: process.env.AWS_SESSION_TOKEN,
      expires: Date.now() + 60 * 60 * 1000,
    };
  }
  if (!creds.key || !creds.secret) throw new Error("no AWS credentials");
  return creds;
}

const sha256 = (s) => createHash("sha256").update(s).digest("hex");
const hmac = (k, s) => createHmac("sha256", k).update(s).digest();

// One DynamoDB API call, signed with Signature Version 4.
async function dynamo(op, input) {
  const c = await credentials();
  const host = `dynamodb.${REGION}.amazonaws.com`;
  const body = JSON.stringify(input);
  const amzDate = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d+/, "");
  const day = amzDate.slice(0, 8);
  const headers = {
    "content-type": "application/x-amz-json-1.0",
    host,
    "x-amz-date": amzDate,
    "x-amz-target": `DynamoDB_20120810.${op}`,
  };
  if (c.token) headers["x-amz-security-token"] = c.token;
  const names = Object.keys(headers).sort();
  const signed = names.join(";");
  const canonical = ["POST", "/", "", ...names.map((n) => `${n}:${headers[n]}`), "", signed, sha256(body)].join("\n");
  const scope = `${day}/${REGION}/dynamodb/aws4_request`;
  const toSign = ["AWS4-HMAC-SHA256", amzDate, scope, sha256(canonical)].join("\n");
  let key = hmac("AWS4" + c.secret, day);
  for (const part of [REGION, "dynamodb", "aws4_request"]) key = hmac(key, part);
  const signature = createHmac("sha256", key).update(toSign).digest("hex");
  headers.authorization = `AWS4-HMAC-SHA256 Credential=${c.key}/${scope}, SignedHeaders=${signed}, Signature=${signature}`;
  delete headers.host;

  const r = await fetch(`https://${host}/`, { method: "POST", headers, body, signal: AbortSignal.timeout(5000) });
  const out = await r.json().catch(() => ({}));
  if (!r.ok) {
    if (r.status === 403 || r.status === 400) creds = null;
    throw new Error(`${op}: ${out.__type || r.status} ${out.message || out.Message || ""}`.trim());
  }
  return out;
}

const writes = { tokens: LIMITS.writesPerMinute, at: Date.now() };

function canWrite() {
  const now = Date.now();
  writes.tokens = Math.min(LIMITS.writesPerMinute, writes.tokens + ((now - writes.at) / 60000) * LIMITS.writesPerMinute);
  writes.at = now;
  if (writes.tokens < 1) return false;
  writes.tokens -= 1;
  return true;
}

function json(res, code, value) {
  res.writeHead(code, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    // The game's sandboxed frame has an opaque origin, so every call is cross-origin.
    "access-control-allow-origin": "*",
  });
  res.end(JSON.stringify(value));
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    // Reads to the end even when it's too big, so the answer can say so
    // instead of cutting the connection.
    req.on("data", (c) => {
      size += c.length;
      if (size <= LIMITS.body) chunks.push(c);
    });
    req.on("end", () => {
      if (size > LIMITS.body) return reject(Object.assign(new Error("too big"), { code: 413 }));
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}"));
      } catch {
        reject(Object.assign(new Error("not JSON"), { code: 400 }));
      }
    });
    req.on("error", reject);
  });
}

function boardOf(value) {
  const board = value == null || value === "" ? "main" : String(value);
  return SLOT_RE.test(board) ? board : null;
}

async function topScores(board, limit = LIMITS.top) {
  const out = await dynamo("Query", {
    TableName: TABLE,
    KeyConditionExpression: "pk = :pk AND begins_with(sk, :b)",
    ExpressionAttributeValues: { ":pk": { S: "score" }, ":b": { S: board + "#" } },
    ScanIndexForward: false,
    Limit: limit,
  });
  return (out.Items || []).map((i) => ({
    name: i.name.S,
    score: Number(i.score.N),
    at: Number(i.at.N),
    id: i.sk.S,
  }));
}

const publicScore = ({ name, score, at }) => ({ name, score, at });

async function api(req, res, route, url) {
  if (route === "ping") {
    res.writeHead(204, { "cache-control": "no-store", "access-control-allow-origin": "*" });
    return res.end();
  }
  if (route === "status") return json(res, 200, { saves: !!TABLE });
  if (!TABLE) return json(res, 503, { error: "Saves & scores aren't on in this lab.", saves: false });

  const reading = req.method === "GET" || req.method === "HEAD";
  if (!reading && !canWrite()) return json(res, 429, { error: "Saving too fast. Try again in a moment." });

  if (route === "load" && reading) {
    const slot = url.searchParams.get("slot") || "main";
    if (!SLOT_RE.test(slot)) return json(res, 400, { error: "A slot is letters, digits, - and _, up to 32." });
    const out = await dynamo("GetItem", { TableName: TABLE, Key: { pk: { S: "save" }, sk: { S: slot } } });
    if (!out.Item) return json(res, 404, { error: "Nothing saved there yet.", slot });
    return json(res, 200, { slot, data: JSON.parse(out.Item.data.S), savedAt: Number(out.Item.at.N) });
  }

  if (route === "saves" && reading) {
    const out = await dynamo("Query", {
      TableName: TABLE,
      KeyConditionExpression: "pk = :pk",
      ExpressionAttributeValues: { ":pk": { S: "save" } },
      ProjectionExpression: "sk, #at",
      ExpressionAttributeNames: { "#at": "at" },
    });
    return json(res, 200, { slots: (out.Items || []).map((i) => ({ slot: i.sk.S, savedAt: Number(i.at.N) })) });
  }

  if (route === "save" && (req.method === "PUT" || req.method === "POST")) {
    const body = await readBody(req);
    const slot = body.slot == null ? "main" : String(body.slot);
    if (!SLOT_RE.test(slot)) return json(res, 400, { error: "A slot is letters, digits, - and _, up to 32." });
    if (body.data === undefined) return json(res, 400, { error: "Send what to save as data." });
    const data = JSON.stringify(body.data);
    if (Buffer.byteLength(data) > LIMITS.data) return json(res, 413, { error: "That save is too big. Save less." });
    const existing = await dynamo("Query", {
      TableName: TABLE,
      KeyConditionExpression: "pk = :pk",
      ExpressionAttributeValues: { ":pk": { S: "save" } },
      ProjectionExpression: "sk",
    });
    const slots = (existing.Items || []).map((i) => i.sk.S);
    if (!slots.includes(slot) && slots.length >= LIMITS.slots) {
      return json(res, 409, { error: `This lab already has ${LIMITS.slots} save slots. Reuse one.` });
    }
    const at = Date.now();
    await dynamo("PutItem", {
      TableName: TABLE,
      Item: { pk: { S: "save" }, sk: { S: slot }, data: { S: data }, at: { N: String(at) } },
    });
    return json(res, 200, { ok: true, slot, savedAt: at });
  }

  if (route === "scores" && reading) {
    const board = boardOf(url.searchParams.get("board"));
    if (!board) return json(res, 400, { error: "A board is letters, digits, - and _, up to 32." });
    return json(res, 200, { board, scores: (await topScores(board)).map(publicScore) });
  }

  if (route === "scores" && req.method === "POST") {
    const body = await readBody(req);
    const board = boardOf(body.board);
    const name = String(body.name ?? "").trim().replace(/\s+/g, " ");
    const score = Number(body.score);
    if (!board) return json(res, 400, { error: "A board is letters, digits, - and _, up to 32." });
    if (!NAME_RE.test(name)) return json(res, 400, { error: "Use a first name or nickname: letters only, up to 12." });
    if (!Number.isInteger(score) || score < 0 || score > 999999999) {
      return json(res, 400, { error: "A score is a whole number from 0 to 999999999." });
    }
    const at = Date.now();
    // Sorted by score, then the earlier of two equal scores first.
    const id = `${board}#${String(score).padStart(10, "0")}#${String(99999999999999 - at).padStart(14, "0")}${randomBytes(3).toString("hex")}`;
    const before = await topScores(board);
    const best = before.length === 0 || score > before[0].score;
    if (before.length < LIMITS.top || score > before[before.length - 1].score) {
      await dynamo("PutItem", {
        TableName: TABLE,
        Item: {
          pk: { S: "score" },
          sk: { S: id },
          name: { S: name },
          score: { N: String(score) },
          at: { N: String(at) },
        },
      });
    }
    // Only the top ten are kept, so a board never grows.
    const all = await topScores(board, LIMITS.top + 5);
    for (const extra of all.slice(LIMITS.top)) {
      await dynamo("DeleteItem", { TableName: TABLE, Key: { pk: { S: "score" }, sk: { S: extra.id } } });
    }
    const top = all.slice(0, LIMITS.top);
    const rank = top.findIndex((s) => s.id === id) + 1 || null;
    return json(res, 200, { ok: true, board, rank, best: best && rank === 1, scores: top.map(publicScore) });
  }

  return json(res, 404, { error: "No such call." });
}

createServer(async (req, res) => {
  const url = new URL(req.url, "http://lab");
  let path;
  try {
    path = decodeURIComponent(url.pathname);
  } catch {
    return send(res, 400, "Bad address.\n");
  }

  if (path === "/healthz" || path === "/play/healthz") return send(res, 200, "ok\n");
  if (path.startsWith(API)) {
    if (req.method === "OPTIONS") {
      res.writeHead(204, {
        "access-control-allow-origin": "*",
        "access-control-allow-methods": "GET, POST, PUT",
        "access-control-allow-headers": "content-type",
        "access-control-max-age": "600",
      });
      return res.end();
    }
    try {
      return await api(req, res, path.slice(API.length), url);
    } catch (err) {
      if (err.code === 413) return json(res, 413, { error: "That's too much to send at once." });
      if (err.code === 400) return json(res, 400, { error: "Send JSON." });
      console.error(`game server: api ${path}: ${err.message}`);
      return json(res, 502, { error: "Couldn't reach the saves right now. Try again." });
    }
  }
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
  console.error(`game server: ${GAME_DIR} at :${PORT}${PREFIX}, saves ${TABLE ? "in " + TABLE : "off"}`);
});
