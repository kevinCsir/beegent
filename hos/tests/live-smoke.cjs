// Opt-in integration test: creates clearly labelled test conversations on the supplied server.
const assert = require('node:assert/strict');
const { load } = require('./core.test.cjs');
const { SwarmManager } = load('SwarmManager');
class NodeTransport {
  onText = () => {}; onClosed = () => {};
  open(url) {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(url);
      this.ws.addEventListener('open', resolve, { once: true });
      this.ws.addEventListener('error', () => { reject(new Error('WebSocket failure')); this.onClosed('network error'); });
      this.ws.addEventListener('close', () => this.onClosed('closed'));
      this.ws.addEventListener('message', event => this.onText(String(event.data)));
    });
  }
  async send(text) { this.ws.send(text); }
  close() { if (this.ws) this.ws.close(); }
}
async function until(predicate, label, timeout = 60000) {
  const start = Date.now();
  while (!predicate()) {
    if (Date.now() - start > timeout) throw new Error('Timed out: ' + label);
    await new Promise(resolve => setTimeout(resolve, 100));
  }
}
async function main() {
  if (!process.argv[2]) throw new Error('Usage: node tests/live-smoke.cjs ws://host:19000/ws');
  const manager = new SwarmManager(() => new NodeTransport());
  const word = 'BRIDGE-OAK-9283';
  try {
    await manager.connect(process.argv[2]);
    await manager.create(); const a = manager.current();
    a.draft = 'JiuWenBridge QA. For this conversation, the codeword is ' + word + '. Reply with that codeword only. Do not use tools or write files.';
    await manager.send();
    await manager.create(); const b = manager.current();
    b.draft = 'JiuWenBridge QA. Reply with SECOND only. Do not use any tools.';
    await manager.send();
    await until(() => a.state === 'idle' && b.state === 'idle', 'two sessions complete');
    assert.ok(a.messages.some(row => row.role === 'assistant' && row.text.includes(word)));
    assert.ok(b.messages.some(row => row.role === 'assistant' && row.text.includes('SECOND')));
    assert.ok(!b.messages.some(row => row.role === 'assistant' && row.text.includes(word)));
    console.log('PASS: server session IDs, two sessions sharing one WS, streamed replies');
    const turnStart = a.messages.length;
    manager.select(a.id); a.draft = 'What is the codeword from my previous message? Reply with it only. Do not use tools.';
    await manager.send();
    await until(() => a.state === 'idle', 'second turn');
    assert.ok(a.messages.slice(turnStart).some(row => row.kind === 'text' && row.role === 'assistant' && row.text.includes(word)));
    console.log('PASS: same-session multi-turn context');
    const before = a.messages.length;
    a.draft = 'Do not use any tools. Write a numbered list of 500 short sentences about trees. Start immediately.';
    await manager.send();
    await until(() => a.messages.length > before + 1 || a.state === 'idle', 'long output starts');
    if (a.state === 'idle') throw new Error('Stop test inconclusive: generation already complete');
    await manager.stop();
    await until(() => a.state === 'idle', 'stop confirmation', 30000);
    console.log('PASS: chat.interrupt cancel confirmed');
    console.log(JSON.stringify({ sessionIds: [a.id, b.id], status: 'PASS', transport: 'desktop WebSocket, not device UI' }));
  } finally { manager.dispose(); }
}
main().catch(error => { console.error(error.message); process.exitCode = 1; });
