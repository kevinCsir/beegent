// Execute the same ArkTS domain sources on Node with a fake transport.
// Hvigor remains the authority for ArkTS/UI compilation.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const devEco = process.env.DEVECO_STUDIO_HOME || 'C:/Program Files/Huawei/DevEco Studio';
const ts = require(path.join(devEco, 'tools/hvigor/hvigor/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets/swarm');
const cache = new Map();
function load(name) {
  name = path.basename(name);
  if (cache.has(name)) return cache.get(name);
  const module = { exports: {} }; cache.set(name, module.exports);
  const file = name === 'CommunicationLog' ? path.join(root, '../diagnostics', name + '.ets') : path.join(root, name + '.ets');
  const source = fs.readFileSync(file, 'utf8');
  const js = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
  vm.runInThisContext('(function(require,module,exports){' + js + '\n})', { filename: name + '.ets' })(load, module, module.exports);
  return module.exports;
}
const { SwarmManager } = load('SwarmManager');
const { SwarmConnection } = load('SwarmConnection');
const { SwarmSession } = load('SwarmSession');
const { endpointOf, decodeFrame } = load('Protocol');
const tick = () => new Promise(resolve => setTimeout(resolve, 0));
class Fake {
  onText = () => {}; onClosed = () => {}; sent = []; opened = 0;
  async open() { this.opened++; }
  async send(text) { this.sent.push(JSON.parse(text)); }
  close() {}
  emit(event, payload) { this.onText(JSON.stringify({ type: 'event', event, payload })); }
  reply(req, payload = {}, ok = true) { this.onText(JSON.stringify({ type: 'res', id: req.id, ok, payload, error: ok ? undefined : 'denied' })); }
}
async function run() {
  assert.equal(endpointOf('192.168.1.10'), 'ws://192.168.1.10:19000/ws');
  assert.equal(endpointOf('wss://EXAMPLE.COM:443/ws'), 'wss://example.com:443/ws');
  assert.throws(() => endpointOf('ws://127.0.0.1:99999'));
  assert.throws(() => decodeFrame('null'));
  assert.throws(() => decodeFrame('{"type":"event","event":"chat.delta","payload":17}'));
  let fake = new Fake();
  const client = new SwarmConnection(() => fake);
  await Promise.all([client.connect('ws://a'), client.connect('ws://a')]);
  assert.equal(fake.opened, 1, 'concurrent connection attempts share a single handshake');
  const p1 = client.request('one', {}), p2 = client.request('two', {});
  fake.reply(fake.sent[1], { content: 'two' }); fake.reply(fake.sent[0], { content: 'one' });
  assert.equal((await p1).content, 'one'); assert.equal((await p2).content, 'two');
  const rejected = client.request('denied', {}); fake.reply(fake.sent[2], {}, false);
  await assert.rejects(rejected, error => error.definitive === true);
  const pending = client.request('unknown', {}); client.close();
  await assert.rejects(pending, error => error.definitive === false);
  // Old-socket callbacks cannot tear down a replacement connection.
  const old = fake; fake = new Fake(); await client.connect('ws://a');
  old.onClosed('stale close'); assert.equal(client.state, 'open'); client.close();
  let resolveOld;
  const slow = new Fake(); slow.open = () => new Promise(resolve => { resolveOld = resolve; });
  let current = slow;
  const cancellable = new SwarmConnection(() => current);
  const opening = cancellable.connect('ws://a');
  const cancelled = assert.rejects(opening);
  cancellable.close(); current = new Fake();
  await cancellable.connect('ws://b'); resolveOld(); await cancelled; await tick();
  assert.equal(cancellable.state, 'open'); cancellable.close();
  const session = new SwarmSession('a', 'ws://a', 'test');
  let renders = 0; session.onMessage = () => renders++;
  session.begin('turn-a', 'hello'); renders = 0;
  for (let i = 0; i < 100; i++) session.apply({ type: 'event', event: 'chat.delta', payload: { request_id: 'turn-a', output_phase_id: 'phase', content: 'x' } });
  assert.equal(renders, 1, 'burst only creates a row before batched flush');
  session.flush(); assert.equal(renders, 2); assert.equal(session.messages[1].text.length, 100);
  session.apply({ type: 'event', event: 'chat.final', payload: { request_id: 'turn-a', output_phase_id: 'phase', content: 'final', final_mode: 'patch_segment' } });
  session.apply({ type: 'event', event: 'chat.final', payload: { request_id: 'turn-a', content: '' } });
  assert.equal(session.messages[1].text, 'final'); assert.notEqual(session.state, 'idle');
  session.apply({ type: 'event', event: 'chat.processing_status', payload: { request_id: 'turn-a', is_processing: false } });
  assert.equal(session.state, 'idle');
  session.begin('turn-b', 'next');
  session.apply({ type: 'event', event: 'chat.processing_status', payload: { request_id: 'turn-a', is_processing: false } });
  assert.equal(session.state, 'sending', 'old completion cannot settle a new request');
  session.disconnected(); assert.equal(session.state, 'unknown');
  const wire = new Fake(); const manager = new SwarmManager(() => wire);
  await manager.connect('127.0.0.1');
  const createA = manager.create(); wire.reply(wire.sent.at(-1), { session_id: 'server-a' }); await createA;
  const a = manager.current(); a.draft = 'first'; const sendA = manager.send(); const reqA = wire.sent.at(-1); wire.reply(reqA, { accepted: true }); await sendA;
  const createB = manager.create(); wire.reply(wire.sent.at(-1), { session_id: 'server-b' }); await createB;
  const b = manager.current(); b.draft = 'second'; const sendB = manager.send(); const reqB = wire.sent.at(-1); wire.reply(reqB, { accepted: true }); await sendB;
  assert.equal(reqA.params.session_id, 'server-a'); assert.equal(reqB.params.session_id, 'server-b');
  wire.emit('chat.delta', { session_id: a.id, request_id: reqA.id, content: 'A' });
  wire.emit('chat.delta', { session_id: b.id, request_id: reqB.id, content: 'B' });
  a.flush(); b.flush(); assert.equal(a.messages.length, 0); assert.equal(a.disposed,true); assert.equal(manager.sessions.length,1); assert.equal(b.messages[1].text, 'B');
  const stopping = manager.stop(); const stopReq = wire.sent.at(-1); wire.reply(stopReq, { accepted: true }); await stopping;
  assert.equal(stopReq.params.intent, 'cancel'); assert.equal(b.state, 'stopping');
  wire.emit('chat.interrupt_result', { session_id: b.id, request_id: stopReq.id, intent: 'cancel', success: true });
  assert.equal(b.state, 'idle');
  wire.emit('chat.ask_user_question', { session_id: a.id, request_id: reqA.id });
  assert.equal(a.messages.length,0); assert.equal(manager.globalNotice,'');
  const count = wire.sent.length; manager.connection.close();
  assert.equal(manager.current(),undefined); assert.equal(b.timeline().length,0); assert.equal(manager.sessions.length,0); assert.equal(wire.sent.length, count, 'disconnect never retries a message');
  manager.dispose();
  console.log('PASS: address validation, malformed frames, concurrent connect, request correlation, stale sockets, cancellation, batching, finals, lifecycle, current-only routing and discarded-session isolation, stopping, interaction fallback, disconnect');
}
module.exports = { load };
if (require.main === module) run().catch(error => { console.error(error); process.exitCode = 1; });
