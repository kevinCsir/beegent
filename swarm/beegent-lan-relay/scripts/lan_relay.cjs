#!/usr/bin/env node
'use strict';
const net = require('node:net');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');

const script = fs.realpathSync(__filename);
const action = process.argv[2] || 'status';
const options = {};
const allowed = new Set(['listen-host', 'message-port', 'file-port', 'backend-port', 'download-port', 'max-connections']);
function port(name, fallback) {
  const raw = options[name] === undefined ? String(fallback) : options[name];
  if (!/^\d+$/.test(raw) || Number(raw) < 1 || Number(raw) > 65535) throw new Error(`Invalid --${name}`);
  return Number(raw);
}
function config() {
  const listenHost = options['listen-host'] || '0.0.0.0';
  if (net.isIP(listenHost) !== 4) throw new Error('--listen-host must be an IPv4 address');
  const result = { listenHost, messagePort: port('message-port', 29000), filePort: port('file-port', 25173),
    backendPort: port('backend-port', 19000), downloadPort: port('download-port', 5173),
    maxConnections: port('max-connections', 128) };
  if (result.messagePort === result.filePort) throw new Error('External ports must differ');
  if ([result.messagePort, result.filePort].some(p => [result.backendPort, result.downloadPort].includes(p))) {
    throw new Error('Use external ports different from both backend ports');
  }
  return result;
}
const base = process.platform === 'win32'
  ? (process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local'))
  : process.platform === 'darwin' ? path.join(os.homedir(), 'Library', 'Application Support')
    : (process.env.XDG_STATE_HOME && path.isAbsolute(process.env.XDG_STATE_HOME)
      ? process.env.XDG_STATE_HOME : path.join(os.homedir(), '.local', 'state'));
const stateDir = path.join(base, 'beegent', 'lan-relay-node');
const stateFile = path.join(stateDir, 'state.json');
const lockDir = path.join(stateDir, 'operation.lock');
const logFile = path.join(stateDir, 'relay.log');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const print = value => process.stdout.write(JSON.stringify(value, null, 2) + '\n');
function readState() {
  try {
    const s = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
    if (s.version !== 1 || !Number.isInteger(s.pid) || s.pid <= 0 ||
        !Number.isInteger(s.controlPort) || s.controlPort < 1 || s.controlPort > 65535 ||
        typeof s.token !== 'string' || !/^[a-f0-9]{64}$/.test(s.token) || typeof s.script !== 'string') {
      throw new Error('Invalid relay state; inspect state.json before recovery');
    }
    return s;
  } catch (e) { if (e.code === 'ENOENT') return null; throw e; }
}
function alive(pid) {
  try { process.kill(pid, 0); return true; }
  catch (e) { if (e.code === 'ESRCH') return false; return true; }
}
function rpc(s, command) {
  return new Promise((resolve, reject) => {
    const socket = net.connect({ host: '127.0.0.1', port: s.controlPort });
    let data = '', done = false;
    const timer = setTimeout(() => finish(new Error('Control request timed out')), 2500);
    function finish(error, result) {
      if (done) return; done = true; clearTimeout(timer); socket.destroy();
      if (error) reject(error); else resolve(result);
    }
    socket.on('connect', () => socket.write(JSON.stringify({ token: s.token, command }) + '\n'));
    socket.on('error', e => finish(e));
    socket.on('close', () => { if (!done) finish(new Error('Control connection closed')); });
    socket.on('data', chunk => {
      data += chunk.toString('utf8');
      if (data.length > 16384) return finish(new Error('Control response too large'));
      if (!data.includes('\n')) return;
      try {
        const r = JSON.parse(data.split('\n')[0]);
        if (!r.ok || r.pid !== s.pid || r.instance !== s.instance || r.script !== s.script) {
          throw new Error('Control identity mismatch');
        }
        finish(null, r);
      } catch (e) { finish(e); }
    });
  });
}
function bind(server, host, portNumber) {
  return new Promise((resolve, reject) => {
    const fail = error => { server.off('listening', success); reject(error); };
    const success = () => { server.off('error', fail); resolve(); };
    server.once('error', fail); server.once('listening', success);
    server.listen({ host, port: portNumber });
  });
}

async function run() {
  if (!process.send) throw new Error('Use start, not run directly');
  const c = config();
  const instance = crypto.randomBytes(16).toString('hex');
  const token = crypto.randomBytes(32).toString('hex');
  const sockets = new Set(), servers = [];
  let ready = false, stopping = false, seq = 0, active = 0;
  function log(message) {
    if (fs.existsSync(logFile) && fs.statSync(logFile).size >= 4 * 1024 * 1024) {
      for (let i = 2; i >= 1; i--) {
        const src = i === 1 ? logFile : `${logFile}.${i - 1}`;
        const dst = `${logFile}.${i}`;
        if (fs.existsSync(dst)) fs.unlinkSync(dst);
        if (fs.existsSync(src)) fs.renameSync(src, dst);
      }
    }
    fs.appendFileSync(logFile, `${new Date().toISOString()} ${message}\n`, { mode: 0o600 });
  }
  function track(socket) {
    sockets.add(socket); socket.once('close', () => sockets.delete(socket)); return socket;
  }
  async function shutdown(code = 0) {
    if (stopping) return; stopping = true; ready = false;
    const force = setTimeout(() => process.exit(code || 1), 4000);
    for (const socket of sockets) socket.destroy();
    await Promise.all(servers.map(server => new Promise(resolve => {
      if (!server.listening) return resolve(); server.close(resolve);
    })));
    try {
      const current = readState();
      if (current && current.instance === instance) fs.unlinkSync(stateFile);
      log(`STOP pid=${process.pid}`);
    } catch (e) { process.stderr.write(`Cleanup failed: ${e.message}\n`); code = 1; }
    clearTimeout(force); process.exit(code);
  }
  function fatal(error) {
    try { log(`FATAL ${error.code || error.message}`); } catch (_) {}
    if (process.connected) process.send({ error: error.code || error.message });
    void shutdown(1);
  }
  process.on('SIGINT', () => void shutdown());
  process.on('SIGTERM', () => void shutdown());
  process.on('uncaughtException', fatal);
  process.on('unhandledRejection', fatal);
  process.on('disconnect', () => { if (!ready) void shutdown(1); });
  function relay(name, listenPort, targetPort) {
    const server = net.createServer({ allowHalfOpen: true, pauseOnConnect: true }, client => {
      if (!ready || stopping || active >= c.maxConnections) { client.destroy(); return; }
      track(client); active++;
      const id = ++seq;
      const upstream = track(net.connect({ host: '127.0.0.1', port: targetPort, allowHalfOpen: true }));
      const timer = setTimeout(() => upstream.destroy(new Error('Upstream connect timeout')), 5000);
      client.once('close', () => {
        active--; clearTimeout(timer);
        if (!client.readableEnded || !client.writableFinished) upstream.destroy();
        log(`${name} #${id} close received=${client.bytesRead} sent=${client.bytesWritten}`);
      });
      upstream.once('close', () => {
        clearTimeout(timer);
        if (!upstream.readableEnded || !upstream.writableFinished) client.destroy();
      });
      client.on('error', e => { log(`${name} #${id} client error ${e.code || e.message}`); upstream.destroy(); });
      upstream.on('error', e => { log(`${name} #${id} upstream error ${e.code || e.message}`); client.destroy(); });
      upstream.once('connect', () => {
        clearTimeout(timer);
        if (client.destroyed) { upstream.destroy(); return; }
        log(`${name} #${id} open ${client.remoteAddress}:${client.remotePort} -> 127.0.0.1:${targetPort}`);
        client.pipe(upstream); upstream.pipe(client); client.resume();
      });
      // No idle timeout: a WebSocket may legitimately stay silent for a long time.
    });
    servers.push(server); server.on('error', fatal);
    return bind(server, c.listenHost, listenPort);
  }
  const control = net.createServer(socket => {
    track(socket); socket.setTimeout(2500, () => socket.destroy());
    socket.on('error', () => {});
    let data = '', handled = false;
    socket.on('data', chunk => {
      if (handled) return;
      data += chunk.toString('utf8');
      if (data.length > 4096) { socket.destroy(); return; }
      if (!data.includes('\n')) return;
      handled = true;
      try {
        const q = JSON.parse(data.split('\n')[0]);
        if (q.token !== token || !['status', 'stop'].includes(q.command) || !ready) { socket.destroy(); return; }
        const response = { ok: true, pid: process.pid, instance, script, ready, config: c, active, logFile };
        socket.end(JSON.stringify(response) + '\n', () => {
          if (q.command === 'stop') { socket.destroy(); void shutdown(); }
        });
      } catch (_) { socket.destroy(); }
    });
  });
  servers.push(control); control.on('error', fatal);
  try {
    await bind(control, '127.0.0.1', 0);
    await relay('messages', c.messagePort, c.backendPort);
    await relay('files', c.filePort, c.downloadPort);
    if (stopping) return;
    const state = { version: 1, pid: process.pid, instance, script, token,
      controlPort: control.address().port, config: c, startedAt: new Date().toISOString() };
    fs.writeFileSync(stateFile, JSON.stringify(state, null, 2), { flag: 'wx', mode: 0o600 });
    log(`READY messages ${c.listenHost}:${c.messagePort} -> 127.0.0.1:${c.backendPort}`);
    log(`READY files ${c.listenHost}:${c.filePort} -> 127.0.0.1:${c.downloadPort}`);
    ready = true;
    if (!process.connected) { await shutdown(1); return; }
    process.send({ ready: true, pid: process.pid });
  } catch (e) { fatal(e); }
}

async function manage() {
  fs.mkdirSync(stateDir, { recursive: true, mode: 0o700 });
  try { fs.mkdirSync(lockDir, { mode: 0o700 }); }
  catch (e) {
    if (e.code === 'EEXIST') throw new Error(`Another management command is active, or a previous command was interrupted. Inspect before removing: ${lockDir}`);
    throw e;
  }
  try {
    fs.writeFileSync(path.join(lockDir, 'owner.json'), JSON.stringify({ pid: process.pid, script, action, at: new Date().toISOString() }));
    let state = readState(), status = null;
    if (state) {
      try { status = await rpc(state, 'status'); }
      catch (e) {
        if (alive(state.pid)) throw new Error(`Recorded PID still exists but control failed (${e.message}). Inspect process identity; do not kill by PID alone. State: ${stateFile}`);
        if (action === 'start') { fs.unlinkSync(stateFile); state = null; }
        else { print({ running: false, staleState: true, stateFile, logFile }); return; }
      }
    }
    if (action === 'status') { print(status || { running: false, stateFile, logFile }); return; }
    if (action === 'stop') {
      if (!state) { print({ running: false }); return; }
      await rpc(state, 'stop');
      for (let i = 0; i < 60; i++) {
        const current = readState();
        if (!current || current.instance !== state.instance) { print({ stopped: true, pid: state.pid }); return; }
        await delay(100);
      }
      throw new Error('Stop was requested but shutdown was not confirmed; inspect relay.log');
    }
    const requested = config();
    if (status) {
      print({ ...status, reused: true, requestedConfigMatches: JSON.stringify(status.config) === JSON.stringify(requested),
        note: 'Already running; stop then start to change configuration.' }); return;
    }
    const args = [script, 'run'];
    for (const [key, value] of Object.entries(options)) args.push(`--${key}`, value);
    const child = spawn(process.execPath, args, {
      detached: true, windowsHide: true, stdio: ['ignore', 'ignore', 'ignore', 'ipc']
    });
    try {
      await new Promise((resolve, reject) => {
        const timer = setTimeout(() => finish(new Error('Startup timed out')), 12000);
        let finished = false;
        function finish(error) {
          if (finished) return; finished = true; clearTimeout(timer);
          if (error) reject(error); else resolve();
        }
        child.once('error', e => finish(e));
        child.once('exit', code => finish(new Error(`Relay exited during startup: ${code}; inspect ${logFile}`)));
        child.on('message', m => { if (m.ready) finish(); else if (m.error) finish(new Error(m.error)); });
      });
      const started = readState();
      if (!started || started.pid !== child.pid) throw new Error('Startup state mismatch');
      print(await rpc(started, 'status'));
      child.disconnect(); child.unref();
    } catch (e) {
      // This handle is the child just spawned, never an unverified PID from a file.
      if (child.exitCode === null && child.signalCode === null) child.kill();
      if (child.connected) child.disconnect();
      child.unref(); throw e;
    }
  } finally {
    fs.unlinkSync(path.join(lockDir, 'owner.json'));
    fs.rmdirSync(lockDir);
  }
}

(async () => {
  if (Number(process.versions.node.split('.')[0]) < 18) throw new Error('Node.js 18+ required');
  if (!['start', 'status', 'stop', 'run'].includes(action)) throw new Error('Usage: node lan_relay.cjs start|status|stop [options]');
  const argv = process.argv.slice(3);
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i].replace(/^--/, '');
    if (!argv[i].startsWith('--') || !allowed.has(key) || argv[i + 1] === undefined || argv[i + 1].startsWith('--') || key in options) {
      throw new Error(`Invalid argument: ${argv[i]}`);
    }
    options[key] = argv[i + 1];
  }
  if (['status', 'stop'].includes(action) && argv.length) throw new Error('status/stop use recorded state; do not pass port options');
  if (action === 'run') await run(); else await manage();
})().catch(e => { process.stderr.write(`ERROR: ${e.message}\n`); process.exitCode = 1; });
