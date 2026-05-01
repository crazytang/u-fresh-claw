#!/usr/bin/env node
const http = require('http');
const fs = require('fs');
const path = require('path');
const { execFileSync, spawn } = require('child_process');

const HOST = '127.0.0.1';
const PORT = Number(process.env.CONFIG_PORT || 18788);
const ROOT_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(ROOT_DIR, 'data');
const STATE_DIR = path.join(DATA_DIR, '.openclaw');
const LOG_DIR = path.join(DATA_DIR, 'logs');
const CONFIG_PATH = path.join(STATE_DIR, 'openclaw.json');
const GATEWAY_META_PATH = path.join(STATE_DIR, 'config-center-gateway.json');
const GATEWAY_PORT_START = 18789;
const GATEWAY_PORT_END = 18799;
const IMAGE_EXTS = new Set(['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp']);
const WORKSPACE_DIR = path.join(STATE_DIR, 'workspace');
const PORTABLE_SKILLS_DIR = path.join(ROOT_DIR, 'skills-cn');
const BUNDLED_SKILLS_DIR = path.join(ROOT_DIR, 'app', 'core', 'node_modules', 'openclaw', 'skills');
let skillInstallBusy = false;
let skillUninstallBusy = false;
const SKILL_INSTALL_RETRY_DELAYS_MS = [7000, 18000, 35000, 55000];

process.env.npm_config_registry = process.env.npm_config_registry || 'https://registry.npmmirror.com';
process.env.npm_config_disturl = process.env.npm_config_disturl || 'https://npmmirror.com/mirrors/node';
process.env.npm_config_audit = process.env.npm_config_audit || 'false';
process.env.npm_config_fund = process.env.npm_config_fund || 'false';
process.env.npm_config_fetch_retries = process.env.npm_config_fetch_retries || '5';
process.env.npm_config_fetch_retry_mintimeout = process.env.npm_config_fetch_retry_mintimeout || '2000';
process.env.npm_config_fetch_retry_maxtimeout = process.env.npm_config_fetch_retry_maxtimeout || '20000';

function ensureDirs() {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  fs.mkdirSync(STATE_DIR, { recursive: true });
  fs.mkdirSync(LOG_DIR, { recursive: true });
}

function readJson(filePath, fallback) {
  try {
    if (!fs.existsSync(filePath)) return fallback;
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch {
    return fallback;
  }
}

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

function removeFile(filePath) {
  try {
    fs.unlinkSync(filePath);
  } catch {
    // ignore
  }
}

function getMimeByExt(ext) {
  return {
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.gif': 'image/gif',
    '.webp': 'image/webp',
    '.svg': 'image/svg+xml',
    '.bmp': 'image/bmp'
  }[ext] || 'application/octet-stream';
}

function listSupportImageCandidates(dirPath) {
  if (!fs.existsSync(dirPath)) return [];
  return fs.readdirSync(dirPath, { withFileTypes: true })
    .filter((entry) => entry.isFile())
    .map((entry) => entry.name)
    .filter((name) => !name.startsWith('._'))
    .filter((name) => IMAGE_EXTS.has(path.extname(name.toLowerCase())))
    .map((name) => ({
      name,
      lower: name.toLowerCase(),
      fullPath: path.join(dirPath, name)
    }));
}

function scoreSupportQrcodeCandidate(candidate, channel) {
  const lower = candidate.lower;
  const hasQrcodeHint = lower.includes('qrcode') || candidate.name.includes('二维码');
  const hasTelegramHint = lower.includes('telegram') || /(^|[^a-z])tg([^a-z]|$)/i.test(lower) || candidate.name.includes('电报');
  const hasWechatHint = lower.includes('wechat') || candidate.name.includes('微信');

  if (channel === 'telegram') {
    if (!hasTelegramHint) return -1;
    return (hasQrcodeHint ? 20 : 0) + (hasWechatHint ? -5 : 0);
  }

  if (hasTelegramHint) return -1;
  if (!(hasQrcodeHint || hasWechatHint)) return -1;
  return (hasQrcodeHint ? 20 : 0) + (hasWechatHint ? 5 : 0);
}

function findSupportQrcodeFile(channel = 'wechat') {
  const normalized = String(channel || 'wechat').toLowerCase() === 'telegram' ? 'telegram' : 'wechat';
  const searchDirs = [
    ROOT_DIR,
    path.join(__dirname, 'public', 'support')
  ];

  const allCandidates = searchDirs.flatMap((dirPath) => listSupportImageCandidates(dirPath));
  const ranked = allCandidates
    .map((candidate) => ({
      candidate,
      score: scoreSupportQrcodeCandidate(candidate, normalized)
    }))
    .filter((item) => item.score >= 0)
    .sort((a, b) => {
      if (b.score !== a.score) return b.score - a.score;
      return a.candidate.name.localeCompare(b.candidate.name, 'zh-CN');
    });

  if (ranked.length === 0) return null;
  return ranked[0].candidate.fullPath;
}

function isPidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function listListenerPids(port) {
  if (process.platform === 'win32') {
    try {
      const output = execFileSync(
        'cmd',
        ['/d', '/s', '/c', `netstat -ano -p tcp | findstr :${port}`],
        {
          encoding: 'utf8',
          stdio: ['ignore', 'pipe', 'ignore']
        }
      ).trim();

      if (!output) return [];

      return Array.from(
        new Set(
          output
            .split(/\r?\n/)
            .map((line) => line.trim())
            .filter(Boolean)
            .map((line) => {
              const parts = line.split(/\s+/);
              // Proto LocalAddress ForeignAddress State PID
              if (parts.length < 5) return 0;
              const localAddress = parts[1] || '';
              const state = parts[3] || '';
              const pidRaw = parts[4] || '';

              const m = localAddress.match(/:(\d+)$/);
              if (!m) return 0;
              if (Number(m[1]) !== Number(port)) return 0;
              // English + Chinese locale compatibility
              if (!/LISTENING|侦听/i.test(state)) return 0;

              const pid = Number(pidRaw);
              return Number.isInteger(pid) && pid > 0 ? pid : 0;
            })
            .filter((n) => Number.isInteger(n) && n > 0)
        )
      );
    } catch {
      return [];
    }
  }

  try {
    const output = execFileSync('lsof', ['-nP', '-ti', `tcp:${port}`, '-sTCP:LISTEN'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore']
    }).trim();

    if (!output) return [];

    return Array.from(
      new Set(
        output
          .split(/\r?\n/)
          .map((line) => Number(line.trim()))
          .filter((n) => Number.isInteger(n) && n > 0)
      )
    );
  } catch {
    return [];
  }
}

function bootoutGatewayServiceIfPresent() {
  if (process.platform !== 'darwin') return;
  try {
    const uid = typeof process.getuid === 'function' ? process.getuid() : null;
    if (!uid && uid !== 0) return;
    execFileSync('launchctl', ['bootout', `gui/${uid}/ai.openclaw.gateway`], {
      stdio: ['ignore', 'ignore', 'ignore']
    });
  } catch {
    // ignore when service does not exist
  }
}

function launchWeixinBind() {
  const macBindCore = path.join(ROOT_DIR, 'Mac-Weixin-Bind-Core.command');
  const macBind = path.join(ROOT_DIR, 'Mac-Weixin-Bind.command');
  const winBindCore = path.join(ROOT_DIR, 'Windows-Weixin-Bind-Core.bat');

  if (process.platform === 'darwin') {
    const script = fs.existsSync(macBindCore) ? macBindCore : macBind;
    if (!fs.existsSync(script)) {
      throw new Error(`Bind script not found: ${script}`);
    }

    try {
      fs.chmodSync(script, 0o755);
    } catch {
      // ignore
    }

    const child = spawn('open', ['-a', 'Terminal', script], {
      detached: true,
      stdio: 'ignore'
    });
    child.unref();
    return {
      platform: 'darwin',
      script,
      message: '已打开微信绑定终端，请在终端窗口扫码。'
    };
  }

  if (process.platform === 'win32') {
    if (!fs.existsSync(winBindCore)) {
      throw new Error(`Bind script not found: ${winBindCore}`);
    }
    const child = spawn('cmd', ['/c', 'start', '', winBindCore], {
      cwd: ROOT_DIR,
      detached: true,
      stdio: 'ignore',
      windowsHide: false
    });
    child.unref();
    return {
      platform: 'win32',
      script: winBindCore,
      message: '已打开微信绑定窗口，请在窗口内扫码。'
    };
  }

  throw new Error(`Unsupported platform for bind: ${process.platform}`);
}

function openSkillHub() {
  const skillHub = path.join(ROOT_DIR, 'SkillHub.html');
  if (!fs.existsSync(skillHub)) {
    throw new Error(`SkillHub not found: ${skillHub}`);
  }
  const skillHubUrl = `http://${HOST}:${PORT}/skillhub`;

  if (process.platform === 'darwin') {
    const child = spawn('open', [skillHubUrl], {
      detached: true,
      stdio: 'ignore'
    });
    child.unref();
    return { platform: 'darwin', path: skillHub, url: skillHubUrl, message: '已打开 SkillHub。' };
  }

  if (process.platform === 'win32') {
    const child = spawn('cmd', ['/c', 'start', '', skillHubUrl], {
      cwd: ROOT_DIR,
      detached: true,
      stdio: 'ignore',
      windowsHide: false
    });
    child.unref();
    return { platform: 'win32', path: skillHub, url: skillHubUrl, message: '已打开 SkillHub。' };
  }

  throw new Error(`Unsupported platform for skill hub: ${process.platform}`);
}

function findGatewayListeners() {
  const result = [];
  for (let port = GATEWAY_PORT_START; port <= GATEWAY_PORT_END; port += 1) {
    const pids = listListenerPids(port);
    if (pids.length > 0) {
      result.push({ port, pids, pid: pids[0] });
    }
  }
  return result;
}

function readConfig() {
  return readJson(CONFIG_PATH, {});
}

function isValidSkillId(value) {
  if (typeof value !== 'string') return false;
  const v = value.trim();
  return /^(@?[a-z0-9._-]+(?:\/[a-z0-9._-]+)?)$/i.test(v);
}

function compactCliError(output, code) {
  const lines = String(output || '')
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .filter((line) => !line.startsWith('[plugins]'));
  if (lines.length === 0) return `Install failed with exit code ${code}`;
  return lines[lines.length - 1];
}

function isRateLimitError(error) {
  const msg = String(error?.message || '');
  return /rate limit exceeded/i.test(msg) || /429/.test(msg);
}

function skillDirCandidates(skillId) {
  const raw = String(skillId || '').trim();
  const noAt = raw.replace(/^@/, '');
  const tail = raw.includes('/') ? raw.split('/').pop() : raw;
  const dashed = noAt.replace(/\//g, '-');
  return Array.from(new Set([raw, noAt, tail, dashed].filter(Boolean)));
}

function findInstalledSkillDir(skillId) {
  const base = path.join(WORKSPACE_DIR, 'skills');
  for (const name of skillDirCandidates(skillId)) {
    const candidate = path.join(base, name);
    try {
      if (fs.existsSync(candidate) && fs.statSync(candidate).isDirectory()) {
        return candidate;
      }
    } catch {
      // ignore
    }
  }
  return '';
}

function readSkillSummary(dirPath) {
  const skillMd = path.join(dirPath, 'SKILL.md');
  if (!fs.existsSync(skillMd)) return '';
  try {
    const text = fs.readFileSync(skillMd, 'utf8');
    const rawLines = text.split(/\r?\n/);
    let inFrontMatter = false;
    const lines = [];

    for (let i = 0; i < rawLines.length; i += 1) {
      const line = rawLines[i].trim();
      if (!line) continue;
      if (i === 0 && line === '---') {
        inFrontMatter = true;
        continue;
      }
      if (inFrontMatter) {
        if (line === '---') inFrontMatter = false;
        continue;
      }
      if (line === '---') continue;
      if (line.startsWith('#')) continue;
      if (line.startsWith('```')) continue;
      if (line.startsWith('>')) continue;
      if (line.startsWith('title:') || line.startsWith('description:')) continue;
      lines.push(line);
      if (lines.length >= 1) break;
    }
    return lines[0] || '';
  } catch {
    return '';
  }
}

function hasChinese(text) {
  return /[\u4e00-\u9fff]/.test(String(text || ''));
}

function toChineseSkillDescription(skillName, source, rawSummary) {
  const cleaned = String(rawSummary || '')
    .replace(/`/g, '')
    .replace(/\[(.*?)\]\((.*?)\)/g, '$1')
    .replace(/\s+/g, ' ')
    .trim();

  if (cleaned && hasChinese(cleaned)) {
    return cleaned;
  }

  const nameLabel = String(skillName || '该')
    .replace(/[-_]+/g, ' ')
    .trim();

  if (source === 'portable') {
    return `${nameLabel} 预装技能，可在当前 U 盘环境中直接调用。`;
  }
  if (source === 'workspace') {
    return `${nameLabel} 已安装技能，可在 OpenClaw 对话中直接使用。`;
  }
  return `${nameLabel} 内置技能，提供对应场景能力，可在 OpenClaw 对话中直接调用。`;
}

function collectSkillEntries(baseDir, source, removable) {
  if (!fs.existsSync(baseDir)) return [];
  const entries = fs.readdirSync(baseDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && !entry.name.startsWith('.'))
    .map((entry) => {
      const fullPath = path.join(baseDir, entry.name);
      let mtimeMs = 0;
      try {
        mtimeMs = fs.statSync(fullPath).mtimeMs || 0;
      } catch {
        // ignore
      }
      return {
        name: entry.name,
        path: fullPath,
        mtimeMs,
        source,
        removable,
        description: toChineseSkillDescription(
          entry.name,
          source,
          readSkillSummary(fullPath)
        )
      };
    });
  return entries;
}

function listInstalledSkills() {
  const workspaceDir = path.join(WORKSPACE_DIR, 'skills');
  const workspaceSkills = collectSkillEntries(workspaceDir, 'workspace', true);
  const portableSkills = collectSkillEntries(PORTABLE_SKILLS_DIR, 'portable', false);
  const bundledSkills = collectSkillEntries(BUNDLED_SKILLS_DIR, 'bundled', false);

  const priority = { workspace: 1, portable: 2, bundled: 3 };
  const merged = new Map();
  [...workspaceSkills, ...portableSkills, ...bundledSkills].forEach((item) => {
    const key = item.name;
    const existing = merged.get(key);
    if (!existing || priority[item.source] < priority[existing.source]) {
      merged.set(key, item);
    }
  });

  const skills = Array.from(merged.values())
    .sort((a, b) => a.name.localeCompare(b.name, 'zh-CN'));

  return {
    path: workspaceDir,
    count: skills.length,
    skills,
    sources: {
      workspace: workspaceSkills.length,
      portable: portableSkills.length,
      bundled: bundledSkills.length
    }
  };
}

function installSkill(skillId) {
  const entry = path.join(ROOT_DIR, 'app', 'core', 'node_modules', 'openclaw', 'openclaw.mjs');
  if (!fs.existsSync(entry)) {
    throw new Error(`OpenClaw entry not found: ${entry}`);
  }

  fs.mkdirSync(WORKSPACE_DIR, { recursive: true });

  const env = {
    ...process.env,
    OPENCLAW_HOME: DATA_DIR,
    OPENCLAW_STATE_DIR: STATE_DIR,
    OPENCLAW_CONFIG_PATH: CONFIG_PATH
  };

  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [
      entry,
      'skills',
      'install',
      skillId
    ], {
      cwd: WORKSPACE_DIR,
      env,
      stdio: ['ignore', 'pipe', 'pipe']
    });

    let output = '';
    const append = (chunk) => {
      output += chunk.toString('utf8');
      if (output.length > 24000) {
        output = output.slice(output.length - 24000);
      }
    };

    child.stdout.on('data', append);
    child.stderr.on('data', append);
    child.on('error', reject);
    child.on('close', (code) => {
      if (code === 0) {
        resolve({ ok: true, code, output });
      } else {
        reject(new Error(compactCliError(output, code)));
      }
    });
  });
}

function uninstallSkill(skillId) {
  const entry = path.join(ROOT_DIR, 'app', 'core', 'node_modules', 'openclaw', 'openclaw.mjs');
  if (!fs.existsSync(entry)) {
    throw new Error(`OpenClaw entry not found: ${entry}`);
  }

  fs.mkdirSync(WORKSPACE_DIR, { recursive: true });

  const env = {
    ...process.env,
    OPENCLAW_HOME: DATA_DIR,
    OPENCLAW_STATE_DIR: STATE_DIR,
    OPENCLAW_CONFIG_PATH: CONFIG_PATH
  };

  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [
      entry,
      'skills',
      'uninstall',
      skillId
    ], {
      cwd: WORKSPACE_DIR,
      env,
      stdio: ['ignore', 'pipe', 'pipe']
    });

    let output = '';
    const append = (chunk) => {
      output += chunk.toString('utf8');
      if (output.length > 24000) {
        output = output.slice(output.length - 24000);
      }
    };

    child.stdout.on('data', append);
    child.stderr.on('data', append);
    child.on('error', reject);
    child.on('close', (code) => {
      if (code === 0) {
        resolve({ ok: true, code, output });
      } else {
        reject(new Error(compactCliError(output, code)));
      }
    });
  });
}

async function uninstallSkillSafe(skillId) {
  const installed = findInstalledSkillDir(skillId);
  if (!installed) {
    return {
      ok: true,
      code: 0,
      output: `Skill already removed: ${skillId}`,
      alreadyRemoved: true
    };
  }

  const result = await uninstallSkill(skillId);
  const after = findInstalledSkillDir(skillId);
  if (!after) {
    return {
      ...result,
      alreadyRemoved: false
    };
  }
  throw new Error(`Skill uninstall not completed: ${skillId}`);
}

async function installSkillWithRetry(skillId) {
  const already = findInstalledSkillDir(skillId);
  if (already) {
    return {
      ok: true,
      code: 0,
      output: `Skill already installed: ${already}`,
      attempts: 0,
      retried: 0,
      totalDelayMs: 0,
      alreadyInstalled: true
    };
  }

  let attempts = 0;
  let totalDelayMs = 0;
  let lastError = null;

  for (let i = 0; i <= SKILL_INSTALL_RETRY_DELAYS_MS.length; i += 1) {
    attempts += 1;
    try {
      const result = await installSkill(skillId);
      return {
        ...result,
        attempts,
        retried: attempts - 1,
        totalDelayMs
      };
    } catch (err) {
      lastError = err;
      const canRetry = isRateLimitError(err) && i < SKILL_INSTALL_RETRY_DELAYS_MS.length;
      if (!canRetry) break;
      const jitter = Math.floor(Math.random() * 1200);
      const delayMs = SKILL_INSTALL_RETRY_DELAYS_MS[i] + jitter;
      totalDelayMs += delayMs;
      // eslint-disable-next-line no-await-in-loop
      await sleep(delayMs);
    }
  }

  const installedAfterRetries = findInstalledSkillDir(skillId);
  if (installedAfterRetries) {
    return {
      ok: true,
      code: 0,
      output: `Skill installed (detected locally): ${installedAfterRetries}`,
      attempts,
      retried: Math.max(0, attempts - 1),
      totalDelayMs,
      alreadyInstalled: true
    };
  }

  if (isRateLimitError(lastError)) {
    const waitSec = Math.max(60, Math.ceil(SKILL_INSTALL_RETRY_DELAYS_MS[SKILL_INSTALL_RETRY_DELAYS_MS.length - 1] / 1000));
    throw new Error(`ClawHub 下载限流：已自动重试 ${attempts - 1} 次仍失败，请约 ${waitSec} 秒后再试`);
  }
  throw lastError || new Error('Skill install failed');
}

function getDashboardToken(config) {
  return config?.gateway?.auth?.token || 'uclaw';
}

function buildStatus() {
  const listeners = findGatewayListeners();
  const cfg = readConfig();
  const token = getDashboardToken(cfg);
  const meta = readJson(GATEWAY_META_PATH, {});
  const metaPid = Number(meta.pid) || 0;
  const active = listeners[0] || null;
  const port = active ? active.port : (Number(meta.port) || null);
  const pid = active ? active.pid : metaPid;
  const running = listeners.length > 0 || isPidAlive(metaPid);

  return {
    running,
    port,
    pid,
    dashboardUrl: port ? `http://${HOST}:${port}/#token=${encodeURIComponent(token)}` : '',
    listeners,
    startedAt: meta.startedAt || null
  };
}

function ensureDefaultConfig() {
  if (fs.existsSync(CONFIG_PATH)) return;
  const config = {
    gateway: {
      auth: {
        mode: 'token',
        token: 'uclaw'
      }
    }
  };
  writeJson(CONFIG_PATH, config);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitForPort(port, retries = 32, intervalMs = 250) {
  for (let i = 0; i < retries; i += 1) {
    if (listListenerPids(port).length > 0) return true;
    // eslint-disable-next-line no-await-in-loop
    await sleep(intervalMs);
  }
  return false;
}

function getFreeGatewayPort() {
  for (let port = GATEWAY_PORT_START; port <= GATEWAY_PORT_END; port += 1) {
    if (listListenerPids(port).length === 0) return port;
  }
  throw new Error(`No free gateway port in ${GATEWAY_PORT_START}-${GATEWAY_PORT_END}`);
}

function startGatewayProcess(port) {
  const entry = path.join(ROOT_DIR, 'app', 'core', 'node_modules', 'openclaw', 'openclaw.mjs');
  if (!fs.existsSync(entry)) {
    throw new Error(`OpenClaw entry not found: ${entry}`);
  }

  const logPath = path.join(LOG_DIR, `gateway-${new Date().toISOString().replace(/[:.]/g, '-')}.log`);
  const fd = fs.openSync(logPath, 'a');

  const env = {
    ...process.env,
    OPENCLAW_HOME: DATA_DIR,
    OPENCLAW_STATE_DIR: STATE_DIR,
    OPENCLAW_CONFIG_PATH: CONFIG_PATH
  };

  const child = spawn(process.execPath, [
    entry,
    'gateway',
    'run',
    '--allow-unconfigured',
    '--force',
    '--port',
    String(port)
  ], {
    cwd: path.join(ROOT_DIR, 'app', 'core'),
    env,
    detached: true,
    stdio: ['ignore', fd, fd]
  });

  child.unref();
  fs.closeSync(fd);

  writeJson(GATEWAY_META_PATH, {
    pid: child.pid,
    port,
    startedAt: new Date().toISOString(),
    logPath
  });

  return { pid: child.pid, port, logPath };
}

async function startGateway() {
  const status = buildStatus();
  if (status.running) return status;

  ensureDirs();
  ensureDefaultConfig();

  const port = getFreeGatewayPort();
  startGatewayProcess(port);

  const ok = await waitForPort(port, 44, 250);
  if (!ok) {
    throw new Error('Gateway start timeout');
  }

  // Let gateway settle to avoid transient false-negative right after spawn.
  await sleep(1200);
  const settled = buildStatus();
  if (!settled.running) {
    throw new Error('Gateway started but not stable yet, please retry');
  }

  return settled;
}

async function stopGateway() {
  bootoutGatewayServiceIfPresent();

  const status = buildStatus();
  const meta = readJson(GATEWAY_META_PATH, {});
  const candidatePids = new Set();

  status.listeners.forEach((item) => item.pids.forEach((pid) => candidatePids.add(pid)));
  if (Number.isInteger(Number(meta.pid)) && Number(meta.pid) > 0) {
    candidatePids.add(Number(meta.pid));
  }

  const pids = Array.from(candidatePids);

  pids.forEach((pid) => {
    if (!isPidAlive(pid)) return;
    try {
      process.kill(pid, 'SIGTERM');
    } catch {
      // ignore
    }
  });

  for (let i = 0; i < 12; i += 1) {
    const alive = pids.some((pid) => isPidAlive(pid));
    if (!alive) break;
    // eslint-disable-next-line no-await-in-loop
    await sleep(200);
  }

  pids.forEach((pid) => {
    if (!isPidAlive(pid)) return;
    try {
      process.kill(pid, 'SIGKILL');
    } catch {
      // ignore
    }
  });

  removeFile(GATEWAY_META_PATH);
  return buildStatus();
}

async function restartGateway() {
  await stopGateway();
  return startGateway();
}

function sendJson(res, code, body) {
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
}

function serveStatic(reqPath, res) {
  let filePath;
  if (reqPath === '/') {
    filePath = path.join(__dirname, 'public/index.html');
  } else if (reqPath === '/skillhub') {
    filePath = path.join(ROOT_DIR, 'SkillHub.html');
  } else {
    filePath = path.join(__dirname, 'public', reqPath);
  }

  if (fs.existsSync(filePath) && fs.statSync(filePath).isFile()) {
    const ext = path.extname(filePath);
    const contentType = {
      '.html': 'text/html',
      '.css': 'text/css',
      '.js': 'application/javascript',
      '.json': 'application/json',
      '.png': 'image/png',
      '.jpg': 'image/jpeg',
      '.jpeg': 'image/jpeg',
      '.gif': 'image/gif',
      '.webp': 'image/webp',
      '.svg': 'image/svg+xml'
    }[ext] || 'text/plain';

    res.writeHead(200, { 'Content-Type': contentType });
    fs.createReadStream(filePath).pipe(res);
  } else {
    res.writeHead(404);
    res.end('Not Found');
  }
}

const server = http.createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') {
    res.writeHead(200);
    res.end();
    return;
  }

  const reqUrl = new URL(req.url, `http://${HOST}:${PORT}`);
  const reqPath = reqUrl.pathname;

  if (reqPath === '/api/config' && req.method === 'GET') {
    try {
      sendJson(res, 200, readConfig());
    } catch (err) {
      sendJson(res, 500, { error: err.message });
    }
    return;
  }

  if (reqPath === '/api/config' && req.method === 'POST') {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      try {
        const config = JSON.parse(body || '{}');
        const dir = path.dirname(CONFIG_PATH);
        if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
        fs.writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2));
        sendJson(res, 200, { ok: true });
      } catch (err) {
        sendJson(res, 500, { error: err.message });
      }
    });
    return;
  }

  if (reqPath === '/api/gateway/status' && req.method === 'GET') {
    sendJson(res, 200, buildStatus());
    return;
  }

  if (reqPath === '/api/gateway/stop' && req.method === 'POST') {
    stopGateway()
      .then((status) => sendJson(res, 200, { ok: true, status }))
      .catch((err) => sendJson(res, 500, { error: err.message }));
    return;
  }

  if (reqPath === '/api/gateway/restart' && req.method === 'POST') {
    restartGateway()
      .then((status) => sendJson(res, 200, { ok: true, status }))
      .catch((err) => sendJson(res, 500, { error: err.message }));
    return;
  }

  if (reqPath === '/api/weixin/bind' && req.method === 'POST') {
    try {
      const result = launchWeixinBind();
      sendJson(res, 200, { ok: true, ...result });
    } catch (err) {
      sendJson(res, 500, { error: err.message });
    }
    return;
  }

  if (reqPath === '/api/skills/open' && req.method === 'POST') {
    try {
      const result = openSkillHub();
      sendJson(res, 200, { ok: true, ...result });
    } catch (err) {
      sendJson(res, 500, { error: err.message });
    }
    return;
  }

  if (reqPath === '/api/skills/installed' && req.method === 'GET') {
    try {
      const result = listInstalledSkills();
      sendJson(res, 200, { ok: true, ...result });
    } catch (err) {
      sendJson(res, 500, { error: err.message });
    }
    return;
  }

  if (reqPath === '/api/skills/install' && req.method === 'POST') {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      let payload = {};
      try {
        payload = JSON.parse(body || '{}');
      } catch {
        sendJson(res, 400, { error: 'Invalid JSON body' });
        return;
      }

      const skillId = String(payload.skillId || payload.slug || '').trim();
      if (!isValidSkillId(skillId)) {
        sendJson(res, 400, { error: 'Invalid skillId, expected skill-id or @author/skill-name' });
        return;
      }

      if (skillInstallBusy || skillUninstallBusy) {
        sendJson(res, 429, { error: 'Another skill operation is running, please wait.' });
        return;
      }

      skillInstallBusy = true;
      installSkillWithRetry(skillId)
        .then((result) => {
          skillInstallBusy = false;
          sendJson(res, 200, {
            ok: true,
            skillId,
            message: result.alreadyInstalled
              ? `Skill ready: ${skillId} (already installed)`
              : `Skill installed: ${skillId}`,
            output: result.output,
            attempts: result.attempts,
            retried: result.retried,
            totalDelayMs: result.totalDelayMs,
            alreadyInstalled: !!result.alreadyInstalled
          });
        })
        .catch((err) => {
          skillInstallBusy = false;
          sendJson(res, 500, { error: err.message, skillId });
        });
    });
    return;
  }

  if (reqPath === '/api/skills/uninstall' && req.method === 'POST') {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      let payload = {};
      try {
        payload = JSON.parse(body || '{}');
      } catch {
        sendJson(res, 400, { error: 'Invalid JSON body' });
        return;
      }

      const skillId = String(payload.skillId || payload.slug || payload.name || '').trim();
      if (!isValidSkillId(skillId)) {
        sendJson(res, 400, { error: 'Invalid skillId, expected installed skill directory name' });
        return;
      }

      if (skillInstallBusy || skillUninstallBusy) {
        sendJson(res, 429, { error: 'Another skill operation is running, please wait.' });
        return;
      }

      skillUninstallBusy = true;
      uninstallSkillSafe(skillId)
        .then((result) => {
          skillUninstallBusy = false;
          sendJson(res, 200, {
            ok: true,
            skillId,
            message: result.alreadyRemoved
              ? `Skill already removed: ${skillId}`
              : `Skill uninstalled: ${skillId}`,
            output: result.output,
            alreadyRemoved: !!result.alreadyRemoved
          });
        })
        .catch((err) => {
          skillUninstallBusy = false;
          sendJson(res, 500, { error: err.message, skillId });
        });
    });
    return;
  }

  if (reqPath === '/api/support/qrcode' && req.method === 'GET') {
    try {
      const typeParam = (reqUrl.searchParams.get('type') || 'wechat').toLowerCase();
      const channel = typeParam === 'telegram' || typeParam === 'tg' ? 'telegram' : 'wechat';
      const filePath = findSupportQrcodeFile(channel);
      if (!filePath || !fs.existsSync(filePath)) {
        if (channel === 'telegram') {
          sendJson(res, 404, { error: 'Telegram 二维码未找到（文件名建议包含 telegram 或 tg）' });
        } else {
          sendJson(res, 404, { error: '客服二维码未找到（文件名建议包含“二维码”或微信）' });
        }
        return;
      }
      const ext = path.extname(filePath).toLowerCase();
      res.writeHead(200, {
        'Content-Type': getMimeByExt(ext),
        'Cache-Control': 'no-store'
      });
      fs.createReadStream(filePath).pipe(res);
    } catch (err) {
      sendJson(res, 500, { error: err.message });
    }
    return;
  }

  serveStatic(reqPath, res);
});

ensureDirs();

server.listen(PORT, HOST, () => {
  console.log(`\n🦞 U盘虾 Config Center`);
  console.log(`   http://${HOST}:${PORT}`);
  console.log(`\n   Config file: ${CONFIG_PATH}\n`);
});
