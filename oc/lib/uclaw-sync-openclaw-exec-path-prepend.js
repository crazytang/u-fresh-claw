#!/usr/bin/env node
/**
 * Sync tools.exec.pathPrepend in openclaw.json for portable Node/Python runtimes.
 * Args: <configPath> <nodePrependDir> <pythonPrependDir>  (last two may be empty)
 * Recognizes and replaces paths under .../runtime/node-mac-* | node-win-* and
 * .../runtime/python-mac-* | python-win-*; keeps other entries; Node dir first, then Python.
 */
const fs = require('fs');

const configPath = process.argv[2];
const nodePrepend = process.argv[3] || '';
const pyPrepend = process.argv[4] || '';

function stripBom(s) {
  if (s.charCodeAt(0) === 0xfeff) return s.slice(1);
  return s;
}

function toSlash(p) {
  return String(p).replace(/\\/g, '/');
}

function isPortableNodeEntry(p) {
  if (typeof p !== 'string') return false;
  const n = toSlash(p);
  return n.includes('/runtime/node-mac-') || n.includes('/runtime/node-win-');
}

function isPortablePythonEntry(p) {
  if (typeof p !== 'string') return false;
  const n = toSlash(p);
  return n.includes('/runtime/python-mac-') || n.includes('/runtime/python-win-');
}

function normPath(p) {
  return String(p).replace(/[/\\]+$/, '') || String(p);
}

function arraysEqual(a, b) {
  if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

if (!configPath) process.exit(0);

let raw;
try {
  raw = stripBom(fs.readFileSync(configPath, 'utf8'));
} catch {
  process.exit(0);
}

let cfg;
try {
  cfg = JSON.parse(raw);
} catch {
  process.exit(0);
}

const prev = Array.isArray(cfg.tools?.exec?.pathPrepend)
  ? cfg.tools.exec.pathPrepend.slice()
  : [];

const kept = prev.filter((p) => !isPortableNodeEntry(p) && !isPortablePythonEntry(p));

const prefix = [];
if (nodePrepend) prefix.push(normPath(nodePrepend));
if (pyPrepend) prefix.push(normPath(pyPrepend));

const seen = new Set(prefix.map(normPath));
const rest = [];
for (const p of kept) {
  const n = normPath(String(p));
  if (seen.has(n)) continue;
  seen.add(n);
  rest.push(p);
}

const merged = prefix.concat(rest);

if (arraysEqual(merged, prev)) {
  process.exit(0);
}

if (!cfg.tools) cfg.tools = {};
if (!cfg.tools.exec) cfg.tools.exec = {};

if (merged.length === 0) {
  if (Object.prototype.hasOwnProperty.call(cfg.tools.exec, 'pathPrepend')) {
    delete cfg.tools.exec.pathPrepend;
  }
} else {
  cfg.tools.exec.pathPrepend = merged;
}

try {
  fs.writeFileSync(configPath, JSON.stringify(cfg, null, 2) + '\n', 'utf8');
} catch {
  process.exit(0);
}
