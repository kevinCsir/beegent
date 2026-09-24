const assert = require('node:assert/strict');
const { load } = require('./core.test.cjs');
const { SwarmManager } = load('SwarmManager');
const { SessionMode } = load('SessionMode');
class Transport {
  onText=()=>{}; onClosed=()=>{};
  open(url) { return new Promise((resolve,reject)=> {
    this.ws=new WebSocket(url);
    this.ws.onopen=resolve; this.ws.onerror=()=>reject(Error('WebSocket error'));
    this.ws.onclose=()=>this.onClosed('closed'); this.ws.onmessage=e=>this.onText(String(e.data));
  }); }
  async send(text) { this.ws.send(text); } close() { this.ws?.close(); }
}
async function until(fn,label,ms=60000) { const end=Date.now()+ms; while(!fn()) { if(Date.now()>end) throw Error('Timed out '+label); await new Promise(r=>setTimeout(r,80)); } }
async function main() {
  const m=new SwarmManager(()=>new Transport());
  try {
    await m.connect(process.argv[2] || 'ws://127.0.0.1:19000/ws');
    for(const role of ['agent','team']) for(const profile of ['work','code']) for(const style of ['normal','plan']) {
      const mode=new SessionMode(role,profile,style); await m.create(mode); const s=m.current();
      const meta=await m.connection.request('session.get_metadata',{session_id:s.id});
      const saved=meta.metadata || meta;
      assert.equal(saved.mode,mode.wire()); assert.equal(saved.work_mode,profile);
      console.log('PASS real session.create metadata '+mode.wire());
    }
    await m.create(); const s=m.current();
    s.draft='JiuWenBridge QA. Do not use tools, files or external services. Write 350 numbered short sentences about clouds. Start directly.';
    await m.send();
    await until(()=>s.executionId && s.state==='running','running execution');
    s.draft='This is a supplement: focus on white clouds. Continue without tools.'; await m.send();
    const task=s.queue[0];
    await m.supplement(task.id);
    assert.equal(task.status,'accepted',task.error || 'steer not accepted');
    await until(()=>s.messages.some(row=>row.text===task.content),'ordered user boundary');
    console.log('PASS real steer receipt and stream boundary; current execution '+s.executionId);
    await m.stop(); await until(()=>s.state==='idle','stop');
    m.toggleQueue();
    s.draft='JiuWenBridge QA. Reply QUEUE-FIRST only. Do not use any tools.'; await m.send();
    s.draft='JiuWenBridge QA. Reply QUEUE-SECOND only. Do not use any tools.'; await m.send();
    await until(()=>s.state==='idle' && s.queue.length===0,'automatic queue drain');
    assert.ok(s.messages.some(row=>row.role==='assistant'&&row.text.includes('QUEUE-SECOND')));
    console.log('PASS real automatic queue drain, session '+s.id);
  } finally { m.dispose(); }
}
main().catch(e=>{ console.error(e.stack); process.exitCode=1; });
