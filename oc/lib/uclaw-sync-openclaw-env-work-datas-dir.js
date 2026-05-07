#!/usr/bin/env node
/**
 * Ensure cfg.env.WORK_DATAS_DIR in openclaw.json points at the portable workdatas folder.
 * Args: <configPath> <workDatasDir>  (second arg resolved to absolute; directory created if missing)
 * Preserves every other key under env.
 */
const fs = require('fs');
const path = require('path');

const configPath = process.argv[2];
const workDatasInput = process.argv[3] || '';

function stripBom(s) {
  if (s.charCodeAt(0) === 0xfeff) return s.slice(1);
  return s;
}

if (!configPath || !workDatasInput) process.exit(0);

let workAbs;
try {
  workAbs = path.resolve(workDatasInput);
  fs.mkdirSync(workAbs, { recursive: true });
} catch {
  process.exit(0);
}

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

let env = cfg.env;
if (env === undefined) {
  cfg.env = { WORK_DATAS_DIR: workAbs };
} else if (typeof env !== 'object' || env === null || Array.isArray(env)) {
  process.exit(0);
} else if (env.WORK_DATAS_DIR === workAbs) {
  process.exit(0);
} else {
  env.WORK_DATAS_DIR = workAbs;
}

try {
  fs.writeFileSync(configPath, JSON.stringify(cfg, null, 2) + '\n', 'utf8');
} catch {
  process.exit(0);
}
