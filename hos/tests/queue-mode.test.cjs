const assert = require('node:assert/strict');
const { load } = require('./core.test.cjs');
const { SwarmManager } = load('SwarmManager');
const { SessionMode } = load('SessionMode');
const tick = () => new Promise(resolve => setTimeout(resolve, 0));
class Wire {
  sent = []; onText = () => {}; onClosed = () => {};
  async open() {} async send(text) { this.sent.push(JSON.parse(text)); } close() {}
  reply(req, payload = {}, ok = true) { this.onText(JSON.stringify({ type: 'res', id: req.id, ok, payload, error: ok ? undefined : 'denied' })); }
  event(session, event, payload = {}) { this.onText(JSON.stringify({ type: 'event', event, payload: { session_id: session.id, ...payload } })); }
}
async function main() {
  const wire = new Wire(); const manager = new SwarmManager(() => wire);
  try {
    await manager.connect('127.0.0.1');
    let n = 0;
    for (const role of ['agent', 'team']) for (const profile of ['work','code']) for (const style of ['normal','plan']) {
      const mode = new SessionMode(role,profile,style);
      const create = manager.create(mode); const req = wire.sent.at(-1);
      assert.equal(req.params.mode, `${role}.${profile}.${style}`); assert.equal(req.params.work_mode, profile);
      wire.reply(req, { session_id: 's'+(++n) }); await create;
      mode.role = 'bad'; assert.equal(manager.current().mode.role, role, 'session snapshots options');
      const s = manager.current(); s.draft='mode test'; const send = manager.send(); const sent = wire.sent.at(-1);
      assert.equal(sent.params.mode,req.params.mode); wire.reply(sent); await send;
      wire.event(s, 'chat.processing_status', {request_id:sent.id,is_processing:false});
    }
    console.log('PASS eight mode combinations retained on create and chat');
    const fresh=manager.create(new SessionMode()); wire.reply(wire.sent.at(-1),{session_id:'queue'}); await fresh; const a = manager.current();
    a.draft='original'; const sending=manager.send(); const original=wire.sent.at(-1); wire.reply(original); await sending;
    wire.event(a,'chat.processing_status',{request_id:original.id,execution_id:'exec-a',is_processing:true});
    wire.event(a,'chat.output_phase',{request_id:original.id,output_phase_id:'p1'});
    wire.event(a,'chat.delta',{request_id:original.id,output_phase_id:'p1',content:'before'});
    const count=wire.sent.length;
    a.draft='first queued'; await manager.send(); a.draft='second queued'; await manager.send();
    assert.equal(wire.sent.length,count); assert.equal(a.queue.length,2);
    manager.moveQueued(a.queue[1].id,-1); assert.equal(a.queue[0].content,'second queued');
    manager.editQueued(a.queue[1].id); assert.equal(a.draft,'first queued'); await manager.send();
    const task=a.queue[0]; const steer=manager.supplement(task.id); const steerReq=wire.sent.at(-1);
    assert.equal(steerReq.params.input_mode,'steer'); assert.equal(steerReq.params.expected_execution_id,'exec-a');
    wire.reply(steerReq,{accepted:true}); await tick(); assert.equal(task.status,'sending','gateway ACK is not runtime admission');
    await manager.supplement(task.id); assert.equal(wire.sent.at(-1).id,steerReq.id,'double tap cannot duplicate');
    // Boundary can precede ACK; output ordering must still be before / user / after.
    wire.event(a,'chat.input_received',{request_id:original.id,input_request_id:steerReq.id,content:task.content});
    wire.event(a,'chat.output_phase',{request_id:original.id,output_phase_id:'p2'});
    wire.event(a,'chat.delta',{request_id:original.id,output_phase_id:'p2',content:'after'});
    wire.event(a,'chat.final',{request_id:original.id,output_phase_id:'p1',content:'old final must be ignored'});
    wire.event(a,'runtime.accepted',{request_id:steerReq.id,input_boundary:'stream'}); await steer;
    wire.event(a,'chat.processing_status',{request_id:steerReq.id,is_processing:false});
    assert.equal(a.state,'running'); assert.equal(a.executionId,'exec-a');
    a.flush(); const userIndex=a.messages.findIndex(m=>m.id===steerReq.id);
    assert.equal(a.messages[userIndex-1].text,'before'); assert.equal(a.messages[userIndex+1].text,'after');
    wire.event(a,'chat.input_received',{request_id:original.id,input_request_id:steerReq.id,content:task.content});
    assert.equal(a.messages.filter(m=>m.id===steerReq.id).length,1);
    console.log('PASS queue/edit/reorder, bound steering, ACK separation, interleaved output and duplicate boundary');
    // Current-page queue still drains on task completion.
    wire.event(a,'chat.processing_status',{request_id:original.id,is_processing:false});
    const next=wire.sent.at(-1); assert.equal(next.params.session_id,a.id); assert.equal(next.params.content,'first queued');
    wire.reply(next); await tick(); assert.equal(a.queue.length,0);
     a.draft='kept after stop'; await manager.send();
    const stopping=manager.stop(); const stop=wire.sent.at(-1); wire.reply(stop); await stopping;
    wire.event(a,'chat.interrupt_result',{request_id:stop.id,success:true});
    wire.event(a,'chat.processing_status',{request_id:next.id,is_processing:false});
    assert.equal(a.queue.length,1); assert.equal(a.queuePaused,true); assert.equal(wire.sent.at(-1),stop);
    manager.toggleQueue(); const resumed=wire.sent.at(-1); assert.equal(resumed.params.content,'kept after stop');
    wire.reply(resumed); await tick();
    wire.event(a,'chat.processing_status',{request_id:resumed.id,execution_id:'exec-b',is_processing:true});
    a.draft='rejected input'; await manager.send(); const failedTask=a.queue[0];
    const rejected=manager.supplement(failedTask.id); const rejectedReq=wire.sent.at(-1);
    wire.reply(rejectedReq); wire.event(a,'chat.error',{request_id:rejectedReq.id,error:'target changed',code:'SESSION_INPUT_TARGET_CHANGED'}); await rejected;
    assert.equal(failedTask.status,'failed'); assert.equal(a.state,'running'); assert.equal(a.queuePaused,true);
    manager.removeQueued(failedTask.id);
    a.draft='uncertain input'; await manager.send(); const unknownTask=a.queue[0];
    const uncertain=manager.supplement(unknownTask.id); const uncertainReq=wire.sent.at(-1); wire.reply(uncertainReq);
    manager.connection.close(); await uncertain;
    assert.equal(a.disposed,true); assert.equal(a.queue.length,0); assert.equal(a.timeline().length,0); assert.equal(manager.current(),undefined);
    const sentCount=wire.sent.length; await manager.connect('127.0.0.1'); await tick(); assert.equal(wire.sent.length,sentCount);
    manager.editQueued(unknownTask.id); assert.equal(a.draft,'');
    console.log('PASS current-page auto drain, discarded queue on disconnect, stop/pause/resume, rejection isolation, disconnect without replay');
  } finally { manager.dispose(); }
}
main().catch(error=>{ console.error(error); process.exitCode=1; });
