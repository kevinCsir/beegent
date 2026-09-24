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
  const manager=new SwarmManager(()=>new NodeTransport());
  try {
    await manager.connect(process.argv[2]);await manager.create();const session=manager.current();
    session.draft='JiuWenBridge 交互测试。请务必调用 ask_user_question 工具，询问我喜欢蓝色还是绿色，给这两个选项。收到回答后仅回复 INTERACTION-OK 和我选的颜色。不要调用任何其他工具，不要读取或修改文件，不要联网。';
    await manager.send();
    await until(()=>session.rich.hasPending()||session.state==='idle'||session.state==='error','question',80000);
    const row=Array.from(session.rich.interactions.values()).find(r=>r.interaction?.questions.length);
    assert.ok(row,'Model must actually produce a structured question');
    const q=row.interaction;
    console.log(JSON.stringify({event:'question',source:q.source,questionId:q.id,originalRequest:session.requestId,count:q.questions.length}));
    const answers=q.questions.map(question=>({question:question.question,selected_options:question.options?.length?[question.options[0].value||question.options[0].label]:[],custom_input:question.options?.length?'':'蓝色'}));
    await manager.answer(session.id,q.id,answers);
    await until(()=>session.state==='idle'||session.state==='error','reply completion',80000);
    assert.equal(q.status,'submitted');assert.equal(session.state,'idle');
    assert.ok(session.messages.some(r=>r.kind==='text'&&r.role==='assistant'&&r.text.includes('INTERACTION-OK')));
    console.log('PASS real Swarm question -> structured answer -> resumed assistant output');
    console.log(JSON.stringify({sessionId:session.id,status:'PASS'}));
  } finally {manager.dispose();}
}
main().catch(e=>{console.error(e.stack);process.exitCode=1;});