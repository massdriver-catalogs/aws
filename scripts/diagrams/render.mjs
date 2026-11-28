// Renders the README diagrams to SVG, once for light and once for dark themes.
// GitHub picks one with <picture> and prefers-color-scheme, so each diagram ships as <name>.svg and <name>.dark.svg.

const THEMES = {
  light: {
    bg: "#ffffff",
    surface: "#ffffff",
    well: "#f9fafb",
    wellStroke: "#e5e7eb",
    stroke: "#d1d5db",
    text: "#111827",
    body: "#4b5563",
    muted: "#6b7280",
    accent: "#0d9488",
    accentSoft: "#e7f4f2",
    line: "#9ca3af",
    halo: "#ffffff",
  },
  dark: {
    bg: "#0d1117",
    surface: "#111113",
    well: "#0a0a0b",
    wellStroke: "#27272a",
    stroke: "#3f3f46",
    text: "#fafafa",
    body: "#a1a1aa",
    muted: "#8b8b94",
    accent: "#2dd4bf",
    accentSoft: "#0f2422",
    line: "#71717a",
    halo: "#0d1117",
  },
};

const FONT = "ui-monospace, SFMono-Regular, 'SF Mono', Menlo, Consolas, 'Liberation Mono', monospace";
const CHAR = 0.61; // monospace advance, as a fraction of the font size

const SIZES = { heading: 10.5, name: 13, body: 11.5, muted: 10.5, label: 10.5 };
const STEP = { heading: 17, name: 18, body: 16, muted: 15, label: 14 };

export const textWidth = (s, kind = "body") => s.length * SIZES[kind] * CHAR;

const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

function style(t) {
  return `<style>
  text { font-family: ${FONT}; }
  .bg { fill: ${t.bg}; }
  .surface { fill: ${t.surface}; stroke: ${t.stroke}; stroke-width: 1.25; }
  .accent { fill: ${t.accentSoft}; stroke: ${t.accent}; stroke-width: 1.5; }
  .ghost { fill: ${t.surface}; stroke: ${t.stroke}; stroke-width: 1.25; stroke-dasharray: 4 3; }
  .well { fill: ${t.well}; stroke: ${t.wellStroke}; stroke-width: 1.25; }
  .heading { fill: ${t.muted}; font-size: ${SIZES.heading}px; font-weight: 700; letter-spacing: 0.08em; }
  .name { fill: ${t.text}; font-size: ${SIZES.name}px; font-weight: 600; }
  .body { fill: ${t.body}; font-size: ${SIZES.body}px; }
  .muted { fill: ${t.muted}; font-size: ${SIZES.muted}px; }
  .label { fill: ${t.body}; font-size: ${SIZES.label}px; }
  .labelAccent { fill: ${t.accent}; font-size: ${SIZES.label}px; font-weight: 600; }
  .chip { fill: ${t.well}; stroke: ${t.wellStroke}; stroke-width: 1; }
  .halo { paint-order: stroke; stroke: ${t.halo}; stroke-width: 4px; stroke-linejoin: round; }
  .edge { fill: none; stroke: ${t.line}; stroke-width: 1.4; }
  .edgeAccent { fill: none; stroke: ${t.accent}; stroke-width: 1.6; }
  .edgeThick { fill: none; stroke: ${t.accent}; stroke-width: 2.6; }
  .dashed { stroke-dasharray: 5 4; }
  .head { fill: ${t.line}; }
  .headAccent { fill: ${t.accent}; }
  .lifeline { stroke: ${t.stroke}; stroke-width: 1.25; stroke-dasharray: 3 4; }
  .activation { fill: ${t.accentSoft}; stroke: ${t.accent}; stroke-width: 1; }
  .frame { fill: none; stroke: ${t.stroke}; stroke-width: 1.25; }
  .frameTab { fill: ${t.well}; stroke: ${t.stroke}; stroke-width: 1.25; }
  .divider { stroke: ${t.stroke}; stroke-width: 1.25; stroke-dasharray: 5 4; }
  .note { fill: ${t.accentSoft}; stroke: ${t.accent}; stroke-width: 1; }
  .badge { fill: ${t.accent}; }
  .badgeText { fill: ${t.bg}; font-size: 9.5px; font-weight: 700; }
</style>`;
}

function defs(uid) {
  return `<defs>${["", "Accent"]
    .map(
      (k) =>
        `<marker id="${uid}-head${k}" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path class="head${k}" d="M0 .6 7.6 4 0 7.4z"/></marker>`,
    )
    .join("")}</defs>`;
}

function svg(uid, w, h, label, theme, body) {
  const t = THEMES[theme];
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${h}" width="${w}" height="${h}" role="img" aria-label="${esc(label)}">
<title>${esc(label)}</title>
${style(t)}
${defs(uid)}
<rect class="bg" x="0" y="0" width="${w}" height="${h}" rx="10"/>
${body}
</svg>
`;
}

const text = (x, y, s, cls, anchor = "start") =>
  `<text class="${cls}" x="${x.toFixed(1)}" y="${y.toFixed(1)}"${anchor !== "start" ? ` text-anchor="${anchor}"` : ""}>${esc(s)}</text>`;

// ---------------------------------------------------------------------------------------------------------------
// Flowcharts

const PAD_X = 14;
const PAD_TOP = 22;

// A node's lines: the first is its name, the rest are muted. A line can be [kind, text].
function nodeLines(n) {
  return n.lines.map((l, i) => (Array.isArray(l) ? l : [i === 0 ? "name" : "muted", l]));
}

export function nodeSize(n) {
  const lines = nodeLines(n);
  if (n.heading) lines.unshift(["heading", n.heading.toUpperCase()]);
  const w = Math.max(...lines.map(([k, s]) => textWidth(s, k))) + PAD_X * 2 + (n.kind === "store" ? 0 : 0);
  let h = PAD_TOP - 4;
  lines.forEach(([k]) => (h += STEP[k]));
  h += 6;
  if (n.kind === "store") h += 8;
  if (n.kind === "decision") return { w: w + 40, h: h + 22 };
  return { w: Math.ceil(w), h: Math.ceil(h) };
}

function drawNode(n) {
  const out = [];
  const { x, y, w, h } = n;
  const kind = n.kind || "box";
  const cx = x + w / 2;
  if (kind === "store") {
    const ry = 6;
    const cls = n.tone === "accent" ? "accent" : "surface";
    out.push(
      `<path class="${cls}" d="M${x} ${y + ry} A${w / 2} ${ry} 0 0 1 ${x + w} ${y + ry} V${y + h - ry} A${w / 2} ${ry} 0 0 1 ${x} ${y + h - ry} Z"/>`,
      `<path class="${cls}" d="M${x} ${y + ry} A${w / 2} ${ry} 0 0 0 ${x + w} ${y + ry}" style="fill:none"/>`,
    );
  } else if (kind === "decision") {
    out.push(`<path class="surface" d="M${cx} ${y} L${x + w} ${y + h / 2} L${cx} ${y + h} L${x} ${y + h / 2} Z"/>`);
  } else if (kind === "actor") {
    out.push(`<rect class="${n.tone === "accent" ? "accent" : "surface"}" x="${x}" y="${y}" width="${w}" height="${h}" rx="${Math.min(h / 2, 18)}"/>`);
  } else if (kind === "external") {
    out.push(`<rect class="ghost" x="${x}" y="${y}" width="${w}" height="${h}" rx="6"/>`);
  } else {
    const cls = n.tone === "accent" ? "accent" : n.tone === "ghost" ? "ghost" : "surface";
    out.push(`<rect class="${cls}" x="${x}" y="${y}" width="${w}" height="${h}" rx="6"/>`);
  }
  const lines = nodeLines(n);
  if (n.heading) lines.unshift(["heading", n.heading.toUpperCase()]);
  const center = kind === "decision" || kind === "actor" || n.center;
  let ty = y + PAD_TOP + (kind === "store" ? 8 : 0) + Math.max(0, (h - nodeSize(n).h) / 2);
  if (kind === "decision" || kind === "actor") {
    const total = lines.reduce((a, [k]) => a + STEP[k], 0);
    ty = y + h / 2 - total / 2 + 13;
  }
  for (const [k, s] of lines) {
    out.push(text(center ? cx : x + PAD_X, ty, s, k, center ? "middle" : "start"));
    ty += STEP[k];
  }
  return out.join("\n");
}

function drawGroup(g) {
  return [
    `<rect class="well" x="${g.x}" y="${g.y}" width="${g.w}" height="${g.h}" rx="8"/>`,
    text(g.x + 12, g.y + 18, g.label.toUpperCase(), "heading"),
  ].join("\n");
}

const SIDES = {
  left: (b, f) => [b.x, b.y + b.h * f, -1, 0],
  right: (b, f) => [b.x + b.w, b.y + b.h * f, 1, 0],
  top: (b, f) => [b.x + b.w * f, b.y, 0, -1],
  bottom: (b, f) => [b.x + b.w * f, b.y + b.h, 0, 1],
};

function center(b) {
  return [b.x + b.w / 2, b.y + b.h / 2];
}

function autoSides(a, b) {
  const [ax, ay] = center(a);
  const [bx, by] = center(b);
  const dx = bx - ax;
  const dy = by - ay;
  // Prefer horizontal links when the boxes don't overlap horizontally.
  const hGap = Math.max(b.x - (a.x + a.w), a.x - (b.x + b.w));
  const vGap = Math.max(b.y - (a.y + a.h), a.y - (b.y + b.h));
  if (hGap > 12 && (hGap >= vGap || vGap < 12)) return dx > 0 ? ["right", "left"] : ["left", "right"];
  return dy > 0 ? ["bottom", "top"] : ["top", "bottom"];
}

function bezierPoint(p0, p1, p2, p3, t) {
  const u = 1 - t;
  return [
    u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0],
    u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1],
  ];
}

export function flowchart(spec, theme) {
  const boxes = {};
  for (const [id, n] of Object.entries(spec.nodes)) {
    const size = nodeSize(n);
    boxes[id] = { ...n, id, w: n.w || size.w, h: n.h || size.h };
  }
  for (const g of spec.groups || []) boxes[g.id] = { ...g, group: true };

  // Pick sides, then spread the edges that share a side along it.
  const edges = spec.edges.map((e, i) => {
    const a = boxes[e.from];
    const b = boxes[e.to];
    if (!a || !b) throw new Error(`${spec.id}: unknown node in edge ${e.from} -> ${e.to}`);
    const [fs, ts] = e.sides || autoSides(a, b);
    return { ...e, i, a, b, fs, ts };
  });
  const ports = {};
  for (const e of edges) {
    (ports[`${e.from}:${e.fs}`] ||= []).push({ e, end: "from", other: e.b });
    (ports[`${e.to}:${e.ts}`] ||= []).push({ e, end: "to", other: e.a });
  }
  for (const [key, list] of Object.entries(ports)) {
    const side = key.split(":")[1];
    const horiz = side === "left" || side === "right";
    list.sort((p, q) => {
      const [px, py] = center(p.other);
      const [qx, qy] = center(q.other);
      return horiz ? py - qy : px - qx;
    });
    list.forEach((p, k) => {
      p.e[p.end === "from" ? "ff" : "tf"] = list.length === 1 ? 0.5 : 0.2 + (0.6 * k) / (list.length - 1);
    });
  }

  const edgeSvg = [];
  const labelSvg = [];
  let maxX = 0;
  let maxY = 0;
  for (const e of edges) {
    const [x0, y0, nx0, ny0] = SIDES[e.fs](e.a, e.from_f ?? e.ff);
    const [x3, y3, nx3, ny3] = SIDES[e.ts](e.b, e.to_f ?? e.tf);
    const dist = Math.hypot(x3 - x0, y3 - y0);
    const k = Math.max(24, Math.min(90, dist * 0.45));
    const p0 = [x0, y0];
    const p1 = [x0 + nx0 * k, y0 + ny0 * k];
    const p2 = [x3 + nx3 * (k + 6), y3 + ny3 * (k + 6)];
    const p3 = [x3 + nx3 * 2, y3 + ny3 * 2];
    const cls = e.style === "thick" ? "edgeThick" : e.tone === "accent" || e.style === "dashed" ? "edgeAccent" : "edge";
    const head = cls === "edge" ? "" : "Accent";
    const dash = e.style === "dashed" ? " dashed" : "";
    const d = `M${p0[0].toFixed(1)} ${p0[1].toFixed(1)} C${p1[0].toFixed(1)} ${p1[1].toFixed(1)}, ${p2[0].toFixed(1)} ${p2[1].toFixed(1)}, ${p3[0].toFixed(1)} ${p3[1].toFixed(1)}`;
    edgeSvg.push(`<path class="${cls}${dash}" d="${d}" marker-end="url(#${spec.id}-head${head})"/>`);
    for (let t = 0; t <= 1; t += 0.05) {
      const [bx, by] = bezierPoint(p0, p1, p2, p3, t);
      maxX = Math.max(maxX, bx);
      maxY = Math.max(maxY, by);
    }
    if (e.label) {
      const [lx, ly] = e.labelAt || bezierPoint(p0, p1, p2, p3, e.t ?? 0.5);
      const lines = Array.isArray(e.label) ? e.label : [e.label];
      const cls2 = head ? "labelAccent" : "label";
      const lw = Math.max(...lines.map((s) => textWidth(s, "label")));
      maxX = Math.max(maxX, lx + (e.dx || 0) + lw / 2);
      const cx = lx + (e.dx || 0);
      const cy = ly + (e.dy || 0);
      const ch = lines.length * STEP.label + 6;
      labelSvg.push(`<rect class="chip" x="${(cx - lw / 2 - 6).toFixed(1)}" y="${(cy - ch / 2).toFixed(1)}" width="${(lw + 12).toFixed(1)}" height="${ch}" rx="4"/>`);
      lines.forEach((s, j) => {
        labelSvg.push(text(cx, cy + 4 + (j - (lines.length - 1) / 2) * STEP.label, s, cls2, "middle"));
      });
    }
  }

  const all = Object.values(boxes);
  const W = Math.ceil(Math.max(maxX, ...all.map((b) => b.x + b.w)) + 16);
  const H = Math.ceil(Math.max(maxY, ...all.map((b) => b.y + b.h)) + 16);
  const body = [
    ...(spec.groups || []).map(drawGroup),
    ...edgeSvg,
    ...Object.values(boxes).filter((b) => !b.group).map(drawNode),
    ...labelSvg,
  ].join("\n");
  return svg(spec.id, spec.width || W, spec.height || H, spec.label, theme, body);
}

// ---------------------------------------------------------------------------------------------------------------
// Sequence diagrams

function wrap(s, max) {
  const words = s.split(" ");
  const lines = [];
  let cur = "";
  for (const w of words) {
    if (cur && (cur + " " + w).length > max) {
      lines.push(cur);
      cur = w;
    } else cur = cur ? cur + " " + w : w;
  }
  if (cur) lines.push(cur);
  return lines;
}

function flatten(steps, depth = 0, out = []) {
  for (const s of steps) {
    out.push({ ...s, depth });
    if (s.block) s.sections.forEach((sec, i) => {
      out.push({ section: true, label: sec.label, first: i === 0, block: s, depth });
      flatten(sec.steps, depth + 1, out);
    });
  }
  return out;
}

export function sequence(spec, theme) {
  const MAXC = spec.wrap || 44;
  const parts = spec.participants.map((p) => ({ ...p, lines: p.label.split("\n") }));
  const idx = Object.fromEntries(parts.map((p, i) => [p.id, i]));
  const headW = parts.map((p) => Math.max(...p.lines.map((l) => textWidth(l, "name"))) + 28);

  // Column gaps: wide enough for each head, and for each message between neighbours.
  const gaps = parts.slice(1).map((_, i) => Math.max(150, (headW[i] + headW[i + 1]) / 2 + 24));
  const msgs = [];
  const collect = (steps) =>
    steps.forEach((s) => {
      if (s.msg) msgs.push(s);
      if (s.block) s.sections.forEach((sec) => collect(sec.steps));
    });
  collect(spec.steps);
  for (const m of msgs) {
    const [f, t] = [idx[m.msg[0]], idx[m.msg[1]]];
    const lines = wrap(m.msg[2], f === t ? 30 : MAXC);
    const need = Math.max(...lines.map((l) => textWidth(l, "body"))) + 34;
    if (f === t) {
      if (f < gaps.length && gaps[f] < need + 30) gaps[f] = need + 30;
    } else {
      const [a, b] = [Math.min(f, t), Math.max(f, t)];
      const span = gaps.slice(a, b).reduce((x, y) => x + y, 0);
      if (span < need) for (let i = a; i < b; i++) gaps[i] += (need - span) / (b - a);
    }
  }
  const left = Math.max(30, headW[0] / 2 + 20);
  const xs = [left];
  gaps.forEach((g) => xs.push(xs[xs.length - 1] + g));
  const lastSelf = msgs.some((m) => m.msg[0] === m.msg[1] && idx[m.msg[0]] === parts.length - 1);
  let W = xs[xs.length - 1] + Math.max(headW[headW.length - 1] / 2 + 20, lastSelf ? 260 : 0);

  const headH = Math.max(...parts.map((p) => p.lines.length)) * STEP.name + 20;
  const out = [];
  const top = 16;
  let y = top + headH + 26;
  let n = 0;
  const frames = [];

  const drawHead = (yy) =>
    parts.forEach((p, i) => {
      const w = headW[i];
      const h = headH;
      const x = xs[i] - w / 2;
      out.push(`<rect class="${p.actor ? "accent" : "surface"}" x="${x}" y="${yy}" width="${w}" height="${h}" rx="${p.actor ? h / 2 : 6}"/>`);
      p.lines.forEach((l, j) =>
        out.push(text(xs[i], yy + h / 2 + 5 + (j - (p.lines.length - 1) / 2) * STEP.name, l, j === 0 ? "name" : "muted", "middle")),
      );
    });

  const walk = (steps, depth) => {
    for (const s of steps) {
      if (s.msg) {
        const [f, t] = [idx[s.msg[0]], idx[s.msg[1]]];
        const self = f === t;
        const lines = wrap(s.msg[2], self ? 30 : MAXC);
        n += 1;
        const label = spec.autonumber ? lines : lines;
        const textTop = y;
        const cls = s.reply ? "edge dashed" : "edgeAccent";
        const head = s.reply ? "" : "Accent";
        if (self) {
          const x = xs[f];
          label.forEach((l, j) => out.push(text(x + 40, textTop + j * STEP.body + 10, l, "body halo")));
          const ly = textTop + label.length * STEP.body + 4;
          out.push(`<path class="${cls}" d="M${x} ${ly} H${x + 30} V${ly + 16} H${x + 4}" marker-end="url(#${spec.id}-head${head})"/>`);
          if (spec.autonumber) out.push(badge(x + 2, textTop + 6, n));
          y = ly + 30;
        } else {
          const [x1, x2] = [xs[f], xs[t]];
          const mid = (x1 + x2) / 2;
          label.forEach((l, j) => out.push(text(mid, textTop + j * STEP.body + 10, l, "body halo", "middle")));
          const ly = textTop + label.length * STEP.body + 6;
          const dir = x2 > x1 ? 1 : -1;
          out.push(`<path class="${cls}" d="M${x1} ${ly} H${x2 - dir * 3}" marker-end="url(#${spec.id}-head${head})"/>`);
          if (spec.autonumber) out.push(badge(x1 + dir * 14, ly, n));
          y = ly + 24;
        }
      } else if (s.note) {
        const [a, b] = s.note.over.map((p) => idx[p]);
        const raw = s.note.text.split("\n");
        const want = Math.max(...raw.map((l) => textWidth(l, "body"))) + 28;
        const span = Math.abs(xs[b] - xs[a]) + 80;
        const half = Math.max(span, want) / 2;
        const mid = (xs[a] + xs[b]) / 2;
        const x1 = Math.max(8, mid - half);
        const x2 = x1 + half * 2;
        const lines = s.note.text.split("\n").flatMap((l) => wrap(l, Math.floor((x2 - x1 - 24) / (SIZES.body * CHAR))));
        const h = lines.length * STEP.body + 14;
        out.push(`<rect class="note" x="${x1}" y="${y}" width="${x2 - x1}" height="${h}" rx="5"/>`);
        lines.forEach((l, j) => out.push(text((x1 + x2) / 2, y + 18 + j * STEP.body, l, "body", "middle")));
        y += h + 16;
      } else if (s.block) {
        const frame = { kind: s.block, top: y, sections: [], depth };
        frames.push(frame);
        y += 30;
        s.sections.forEach((sec, i) => {
          if (i > 0) {
            frame.sections.push({ y: y - 6, label: sec.label });
            y += 22;
          } else frame.label = sec.label;
          walk(sec.steps, depth + 1);
        });
        frame.bottom = y - 4;
        y += 14;
      }
    }
  };

  const badge = (x, yy, k) =>
    `<circle class="badge" cx="${x}" cy="${yy}" r="8"/>` + text(x, yy + 3.4, String(k), "badgeText", "middle");

  // Draw lifelines first so everything else sits on top: walk twice, once to measure.
  const saved = out.length;
  walk(spec.steps, 0);
  const bodyEnd = y;
  out.splice(saved);
  frames.length = 0;
  y = top + headH + 26;
  n = 0;

  const lifeTop = top + headH;
  const lifeBottom = bodyEnd + 6;
  parts.forEach((p, i) => out.push(`<line class="lifeline" x1="${xs[i]}" y1="${lifeTop}" x2="${xs[i]}" y2="${lifeBottom}"/>`));
  const framesAt = out.length;
  walk(spec.steps, 0);

  const frameSvg = frames.map((f) => {
    const inset = f.depth * 8;
    const x1 = 8 + inset;
    const x2 = W - 8 - inset;
    const tag = f.kind;
    const tw = textWidth(tag, "heading") + 18;
    const parts2 = [
      `<rect class="frame" x="${x1}" y="${f.top}" width="${x2 - x1}" height="${f.bottom - f.top}" rx="6"/>`,
      `<path class="frameTab" d="M${x1} ${f.top + 6} Q${x1} ${f.top} ${x1 + 6} ${f.top} H${x1 + tw} V${f.top + 14} L${x1 + tw - 8} ${f.top + 20} H${x1} Z"/>`,
      text(x1 + 8, f.top + 14, tag.toUpperCase(), "heading"),
    ];
    if (f.label) parts2.push(text(x1 + tw + 10, f.top + 14, f.label, "labelAccent"));
    for (const s of f.sections) {
      parts2.push(`<line class="divider" x1="${x1}" y1="${s.y}" x2="${x2}" y2="${s.y}"/>`);
      parts2.push(text(x1 + 10, s.y + 15, s.label, "labelAccent"));
    }
    return parts2.join("\n");
  });
  out.splice(framesAt, 0, ...frameSvg);

  drawHead(top);
  drawHead(lifeBottom + 4);
  const H = lifeBottom + 4 + headH + 16;
  return svg(spec.id, Math.ceil(W), Math.ceil(H), spec.label, theme, out.join("\n"));
}
