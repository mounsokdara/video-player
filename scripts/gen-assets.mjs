#!/usr/bin/env node
import { readdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join, resolve } from 'node:path';

const args = process.argv.slice(2);
const check = args.includes('--check');
const app = resolve(args.find((a) => !a.startsWith('--')) ?? '.');
const pubspec = join(app, 'pubspec.yaml');

if (!existsSync(pubspec)) { console.error(`gen-assets: ${pubspec} not found`); process.exit(1); }
if (!existsSync(join(app, 'assets'))) { console.log('gen-assets: no assets/ folder, nothing to do'); process.exit(0); }

const dirs = [];
const walk = (rel) => {
  const ents = readdirSync(join(app, rel), { withFileTypes: true });
  if (ents.some((e) => e.isFile() && !e.name.startsWith('.'))) dirs.push(rel);
  for (const e of ents) if (e.isDirectory() && !e.name.startsWith('.')) walk(`${rel}/${e.name}`);
};
walk('assets');
dirs.sort();
const q = (s) => (/[\s#:'"]/.test(s) ? JSON.stringify(s) : s);
const gen = dirs.map((d) => `    - ${q(d + '/')}`);

const raw = readFileSync(pubspec, 'utf8');
const nl = raw.includes('\r\n') ? '\r\n' : '\n';
const lines = raw.split(/\r?\n/);
while (lines.length && lines[lines.length - 1] === '') lines.pop();

let out;
const fi = lines.findIndex((l) => /^flutter:\s*$/.test(l));
if (fi < 0) {
  out = [...lines, '', 'flutter:', '  assets:', ...gen];            // no flutter: section at all
} else {
  let end = lines.length;                                            // end of the flutter: section
  for (let i = fi + 1; i < lines.length; i++) if (/^\S/.test(lines[i]) && !lines[i].startsWith('#')) { end = i; break; }
  let ai = -1;
  for (let i = fi + 1; i < end; i++) if (/^  assets:\s*(\[\s*\])?\s*(#.*)?$/.test(lines[i])) { ai = i; break; }
  if (ai < 0) {
    let at = fi + 1;                                                 // no assets: key -> add it
    if (/^  uses-material-design:/.test(lines[at] ?? '')) at++;
    out = [...lines.slice(0, at), '  assets:', ...gen, ...lines.slice(at)];
  } else {
    // Replace every assets/... entry (and any old BEGIN/END marker comments); keep other
    // entries (e.g. packages/...) and other comments; stop at the first non-list line.
    let j = ai + 1;
    const keep = [];
    for (; j < end; j++) {
      const l = lines[j];
      if (/^    #\s*(BEGIN|END) auto-assets/.test(l)) continue;
      const m = /^    -\s*["']?(.+?)["']?\s*(#.*)?$/.exec(l);
      if (m) { if (!m[1].startsWith('assets/')) keep.push(l); continue; }
      if (/^    #/.test(l)) { keep.push(l); continue; }
      break;                                                         // "  fonts:", blank line, ...
    }
    out = [...lines.slice(0, ai), '  assets:', ...gen, ...keep, ...lines.slice(j)];
  }
}
const next = out.join(nl) + nl;
if (next === raw) { console.log(`gen-assets: pubspec.yaml up to date (${dirs.length} asset folders)`); process.exit(0); }
if (check) { console.error('gen-assets: pubspec.yaml is out of date, run: node gen-assets.mjs'); process.exit(1); }
writeFileSync(pubspec, next);
console.log(`gen-assets: updated pubspec.yaml with ${dirs.length} asset folders:\n  ${dirs.join('\n  ')}`);
