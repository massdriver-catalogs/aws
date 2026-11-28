// Writes every diagram in specs.mjs as <dir>/diagrams/<id>.svg and <id>.dark.svg.
// Run from the repository root: node scripts/diagrams/build.mjs

import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import specs from "./specs.mjs";
import { flowchart, sequence } from "./render.mjs";

for (const spec of specs) {
  const dir = join(spec.out, "diagrams");
  mkdirSync(dir, { recursive: true });
  for (const theme of ["light", "dark"]) {
    const render = spec.type === "seq" ? sequence : flowchart;
    const file = join(dir, `${spec.id}${theme === "dark" ? ".dark" : ""}.svg`);
    writeFileSync(file, render({ ...spec, id: `${spec.out.replace(/[^a-z0-9]+/gi, "-")}-${spec.id}` }, theme));
    console.log(file);
  }
}
