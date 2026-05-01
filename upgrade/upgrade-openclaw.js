#!/usr/bin/env node

const fs = require('fs');
const http = require('http');
const https = require('https');
const path = require('path');
const { spawnSync } = require('child_process');

const requestedVersion = (process.argv[2] || '').trim();
let targetVersion = requestedVersion;
const registry = process.env.NPM_REGISTRY || 'https://registry.npmmirror.com';
const scriptDir = __dirname;
const rootDir = path.resolve(scriptDir, '..');
const coreDir = path.join(rootDir, 'oc', 'app', 'core');
const versionPattern = /^\d{4}\.\d{1,2}\.\d{1,2}(?:-[0-9A-Za-z.-]+)?$/;

function log(msg) {
  process.stdout.write(`${msg}\n`);
}

function die(msg) {
  process.stderr.write(`ERROR: ${msg}\n`);
  process.exit(1);
}

function ensureFile(filePath) {
  if (!fs.existsSync(filePath)) {
    die(`Missing file: ${filePath}`);
  }
}

function fetchJson(url, redirectCount = 0) {
  return new Promise((resolve, reject) => {
    const client = url.startsWith('http:') ? http : https;
    const req = client.get(url, { timeout: 15000 }, (res) => {
      const location = res.headers.location;
      if (
        location &&
        [301, 302, 303, 307, 308].includes(res.statusCode) &&
        redirectCount < 5
      ) {
        res.resume();
        const nextUrl = new URL(location, url).toString();
        resolve(fetchJson(nextUrl, redirectCount + 1));
        return;
      }

      let data = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => {
        data += chunk;
      });
      res.on('end', () => {
        if (res.statusCode < 200 || res.statusCode >= 300) {
          reject(new Error(`HTTP ${res.statusCode} from ${url}`));
          return;
        }

        try {
          resolve(JSON.parse(data));
        } catch (err) {
          reject(new Error(`Invalid JSON from ${url}: ${err.message}`));
        }
      });
    });

    req.on('timeout', () => {
      req.destroy(new Error(`Request timed out: ${url}`));
    });
    req.on('error', reject);
  });
}

async function resolveLatestVersion() {
  const baseUrl = registry.replace(/\/+$/, '');
  const latestUrl = `${baseUrl}/openclaw/latest`;
  const metadataUrl = `${baseUrl}/openclaw`;

  log('Latest OpenClaw version requested. Resolving from registry...');

  try {
    const latest = await fetchJson(latestUrl);
    if (latest?.version) {
      return latest.version;
    }
  } catch (err) {
    log(`Could not read ${latestUrl}: ${err.message}`);
  }

  const metadata = await fetchJson(metadataUrl);
  const latestVersion = metadata?.['dist-tags']?.latest;
  if (!latestVersion) {
    die(`Unable to resolve latest OpenClaw version from ${metadataUrl}`);
  }

  return latestVersion;
}

function patchFile(filePath, patchers) {
  ensureFile(filePath);
  const original = fs.readFileSync(filePath, 'utf8');
  let next = original;

  for (const { regex, replace } of patchers) {
    next = next.replace(regex, replace);
  }

  if (next !== original) {
    fs.writeFileSync(filePath, next, 'utf8');
    log(`Patched: ${path.relative(rootDir, filePath)}`);
  } else {
    log(`No change: ${path.relative(rootDir, filePath)}`);
  }
}

function resolveBundledRuntime() {
  const runtimeDir = path.join(rootDir, 'oc', 'app', 'runtime');
  const candidates = [];

  if (process.platform === 'win32') {
    candidates.push({
      node: path.join(runtimeDir, 'node-win-x64', 'node.exe'),
      npmCli: path.join(runtimeDir, 'node-win-x64', 'node_modules', 'npm', 'bin', 'npm-cli.js')
    });
  } else if (process.platform === 'darwin') {
    if (process.arch === 'arm64') {
      candidates.push({
        node: path.join(runtimeDir, 'node-mac-arm64', 'bin', 'node'),
        npmCli: path.join(runtimeDir, 'node-mac-arm64', 'lib', 'node_modules', 'npm', 'bin', 'npm-cli.js')
      });
      candidates.push({
        node: path.join(runtimeDir, 'node-mac-x64', 'bin', 'node'),
        npmCli: path.join(runtimeDir, 'node-mac-x64', 'lib', 'node_modules', 'npm', 'bin', 'npm-cli.js')
      });
    } else {
      candidates.push({
        node: path.join(runtimeDir, 'node-mac-x64', 'bin', 'node'),
        npmCli: path.join(runtimeDir, 'node-mac-x64', 'lib', 'node_modules', 'npm', 'bin', 'npm-cli.js')
      });
      candidates.push({
        node: path.join(runtimeDir, 'node-mac-arm64', 'bin', 'node'),
        npmCli: path.join(runtimeDir, 'node-mac-arm64', 'lib', 'node_modules', 'npm', 'bin', 'npm-cli.js')
      });
    }
  }

  for (const item of candidates) {
    if (fs.existsSync(item.node) && fs.existsSync(item.npmCli)) {
      return item;
    }
  }

  die('Bundled runtime Node/npm not found under oc/app/runtime. Refusing to use system Node.');
}

function runInstall() {
  const runtime = resolveBundledRuntime();
  log(`Using bundled node: ${runtime.node}`);
  log(`Using bundled npm-cli: ${runtime.npmCli}`);
  const args = [
    runtime.npmCli,
    'install',
    `openclaw@${targetVersion}`,
    '--save-exact',
    `--registry=${registry}`
  ];
  const result = spawnSync(runtime.node, args, {
    cwd: coreDir,
    stdio: 'inherit'
  });

  if (result.status !== 0) {
    die(`npm install failed with exit code ${result.status}`);
  }
}

function verify() {
  const corePkg = JSON.parse(fs.readFileSync(path.join(coreDir, 'package.json'), 'utf8'));
  const coreLock = JSON.parse(fs.readFileSync(path.join(coreDir, 'package-lock.json'), 'utf8'));
  const installedPkg = JSON.parse(
    fs.readFileSync(path.join(coreDir, 'node_modules', 'openclaw', 'package.json'), 'utf8')
  );

  const depVersion = corePkg?.dependencies?.openclaw;
  const lockRootDep = coreLock?.packages?.['']?.dependencies?.openclaw;
  const lockOpenclawVer = coreLock?.packages?.['node_modules/openclaw']?.version;
  const installedVersion = installedPkg?.version;

  const checks = [
    ['package.json dependency', depVersion],
    ['package-lock root dependency', lockRootDep],
    ['package-lock node_modules/openclaw', lockOpenclawVer],
    ['installed openclaw version', installedVersion]
  ];

  for (const [label, value] of checks) {
    if (value !== targetVersion) {
      die(`${label} expected ${targetVersion}, got ${value || 'EMPTY'}`);
    }
  }

  log(`Verification passed. OpenClaw ${installedVersion}`);
}

async function main() {
  if (!targetVersion || targetVersion === 'latest') {
    targetVersion = await resolveLatestVersion();
  }

  if (!versionPattern.test(targetVersion)) {
    die(`Invalid version format: ${targetVersion}`);
  }

  ensureFile(path.join(coreDir, 'package.json'));

  const updateSpecs = [
    {
      file: path.join(rootDir, 'oc', 'app', 'core', 'package.json'),
      patchers: [{ regex: /("openclaw"\s*:\s*")[^"]+(")/g, replace: `$1${targetVersion}$2` }]
    },
    {
      file: path.join(rootDir, 'oc', 'setup.sh'),
      patchers: [{ regex: /("openclaw"\s*:\s*")[^"]+(")/g, replace: `$1${targetVersion}$2` }]
    },
    {
      file: path.join(rootDir, 'oc', 'Mac-Install.command'),
      patchers: [{ regex: /("openclaw"\s*:\s*")[^"]+(")/g, replace: `$1${targetVersion}$2` }]
    },
    {
      file: path.join(rootDir, 'oc', 'Windows-Install.bat'),
      patchers: [{ regex: /("openclaw"\s*:\s*")[^"]+(")/g, replace: `$1${targetVersion}$2` }]
    },
    {
      file: path.join(rootDir, 'oc', 'lib', 'maintain.sh'),
      patchers: [
        {
          regex: /registry\.npmmirror\.com\/openclaw\/(?:latest|\d{4}\.\d{1,2}\.\d{1,2}(?:-[0-9A-Za-z.-]+)?)/g,
          replace: `registry.npmmirror.com/openclaw/${targetVersion}`
        },
        {
          regex: /openclaw@(?:latest|\d{4}\.\d{1,2}\.\d{1,2}(?:-[0-9A-Za-z.-]+)?)/g,
          replace: `openclaw@${targetVersion}`
        }
      ]
    },
    {
      file: path.join(rootDir, 'oc', 'Windows-Menu.bat'),
      patchers: [
        {
          regex: /registry\.npmmirror\.com\/openclaw\/(?:latest|\d{4}\.\d{1,2}\.\d{1,2}(?:-[0-9A-Za-z.-]+)?)/g,
          replace: `registry.npmmirror.com/openclaw/${targetVersion}`
        },
        {
          regex: /openclaw@(?:latest|\d{4}\.\d{1,2}\.\d{1,2}(?:-[0-9A-Za-z.-]+)?)/g,
          replace: `openclaw@${targetVersion}`
        }
      ]
    }
  ];

  log(`Target OpenClaw version: ${targetVersion}`);
  log(`Registry: ${registry}`);

  for (const spec of updateSpecs) {
    patchFile(spec.file, spec.patchers);
  }

  runInstall();
  verify();

  log('Done. Suggested verification:');
  log('  macOS: ./Mac-一键启动.command && ./oc/Mac-Diagnose.command');
  log('  Windows: Windows-一键启动.bat && oc\\Windows-Diagnose.bat');
}

main().catch((err) => {
  die(err.message);
});
