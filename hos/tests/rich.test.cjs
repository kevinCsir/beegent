const assert = require('node:assert/strict');
const { load } = require('./core.test.cjs');
const { SwarmSession } = load('SwarmSession');
const { SwarmManager } = load('SwarmManager');
const { SessionMode } = load('SessionMode');
const { markdown, inline } = load('Markdown');
const { downloadAddress } = load('RichMessage');
const tick = () => new Promise(r => setTimeout(r, 0));
class Wire {
  sent=[]; onText=()=>{}; onClosed=()=>{};
  async open() {} close() {} async send(text) { this.sent.push(JSON.parse(text)); }
  emit(event,payload) { this.onText(JSON.stringify({type:'event',event,payload})); }
  reply(req,ok=true) { this.onText(JSON.stringify({type:'res',id:req.id,ok,error:ok?undefined:'denied',payload:{session_id:'s'}})); }
}
async function main() {
  const s = new SwarmSession('s','ws://192.168.43.217:19000/ws','test'); s.begin('r','hello');
  const emit=(event,payload={})=>s.apply({type:'event',event,payload:{request_id:'r',...payload}});
  emit('chat.reasoning',{content:'thinking'});
  emit('chat.tool_call',{tool_call:{id:'t',name:'read_file',arguments:{path:'hello'}}});
  emit('chat.delta',{content:'# Answer'});
  let group=s.messages.find(m=>m.kind==='steps'); assert.equal(group.collapse,true,'first body delta collapses steps immediately'); assert.equal(group.collapseVersion,1); emit('chat.delta',{content:' more'}); assert.equal(group.collapseVersion,1,'later deltas do not override manual expansion'); assert.equal(group.answerId,s.messages.find(m=>m.role==='assistant'&&m.kind==='text').answerId);
  emit('chat.tool_result',{tool_result:{tool_call_id:'t',result:'done',success:true}});
  assert.equal(group.collapse,true,'completed group collapses after body');
  emit('chat.tool_call',{tool_call:{id:'next',name:'test'}});
  emit('chat.tool_result',{tool_result:{tool_call_id:'next',error:'failed'}});
  emit('chat.final',{content:'Next answer'});
  assert.equal(s.messages.filter(m=>m.kind==='text'&&m.role==='assistant').length,2,'tools separate body segments');
  assert.equal(s.messages.filter(m=>m.kind==='steps').at(-1).collapse,true,'body starts collapsed even with a failed step; step status remains available');
  emit('chat.tool_result',{tool_result:{result:'no ID'}});
  emit('chat.custom_widget',{content:'unknown content'});
  assert.ok(s.messages.some(m=>m.kind==='notice'&&m.text.includes('unknown content')));
  emit('chat.file',{files:[{name:'report.txt',download_url:'/api/file?id=x'},{name:'local.doc',path:'C:/private/local.doc'}]});
  const files=s.messages.find(m=>m.kind==='attachments').attachments;
  assert.equal(files[0].url,'http://192.168.43.217:19000/api/file?id=x'); assert.equal(files[1].available,false);
  assert.equal(downloadAddress('file:///etc/passwd',s.endpoint),'');
  assert.equal(downloadAddress('//evil.test/a',s.endpoint),'');
  assert.equal(inline('[bad](javascript:alert)')[0].url,'');
  const blocks=markdown('# Heading\n\n**bold** and `code`\n\n> quote\n\n- item\n\n```ts\nconst x=1;\n```');
  assert.deepEqual(blocks.map(b=>b.kind),['heading','paragraph','quote','list','code']);
  s.flush();
  const w=new Wire(), m=new SwarmManager(()=>w); await m.connect('127.0.0.1');
  const create=m.create(new SessionMode('agent','work','plan')); w.reply(w.sent.at(-1)); await create;
  const session=m.current(); session.draft='plan'; const sending=m.send(); w.reply(w.sent.at(-1)); await sending;
  let uiChanges=0; const oldChange=m.onChange; m.onChange=()=>uiChanges++;
  const beforeUsage=session.messages.length;
  for(const event of ['context.usage','chat.usage_metadata','chat.usage_summary']) {
    w.emit(event,{session_id:'s',request_id:'old-turn',metadata:{tokens:42},usage:{total_tokens:42}});
    w.emit(event,{session_id:'not-loaded',request_id:'orphan',metadata:{tokens:41}});
  }
  assert.equal(session.messages.length,beforeUsage);assert.equal(uiChanges,0,'usage never notifies UI');
  assert.equal(session.usage,undefined,'usage is discarded rather than retained');
  assert.equal(m.unassignedUsage,undefined);assert.equal(m.globalNotice,'');
  w.emit('connection.ack',{session_id:'placeholder',protocol_version:'1.0'});
  w.emit('task.global_running',{running:true,count:2});
  assert.equal(m.connection.acknowledgement.protocol_version,'1.0'); assert.equal(m.globalTaskState.count,2);
  assert.equal(m.globalNotice,'');assert.equal(session.messages.length,beforeUsage);assert.equal(uiChanges,0);
  m.onChange=oldChange;
  const original=session.requestId;
  const question=(id,source,extra={})=>w.emit('chat.ask_user_question',{session_id:'s',request_id:id,source,
    questions:[{question:'Choose?',options:[{label:'Allow',value:'allow'},{label:'Deny',value:'deny'}],card_id:'card-1'}],...extra});
  question('q','permission_interrupt');
  assert.equal(session.state,'waiting','question ID may differ from turn ID');
  session.draft='queued followup'; await m.send(); assert.equal(session.queue.length,1);
  const answer=m.answer('s','q',[{question:'Choose?',selected_options:['deny']}]); const req=w.sent.at(-1);
  assert.equal(req.method,'chat.send'); assert.equal(req.params.query,''); assert.equal(req.params.request_id,'q');
  assert.equal(req.params.answers[0].card_id,'card-1'); assert.equal(req.params.mode,'agent.work.plan');
  w.reply(req); await tick(); assert.equal(session.rich.interactions.get('q').interaction.status,'sending','gateway ACK is not runtime acceptance');
  w.emit('runtime.accepted',{session_id:'s',request_id:req.id}); await answer;
  assert.equal(session.rich.interactions.get('q').interaction.status,'submitted');
  assert.equal(session.queue.length,1,'interaction reply bypasses queued conversation');
  w.emit('chat.processing_status',{session_id:'s',request_id:req.id,is_processing:false});
  assert.equal(session.queue.length,0,'queue resumes only after completion'); w.reply(w.sent.at(-1)); await tick();
    const planActions=[{kind:'execute',value:'plan_execute',requires_input:'no',label:'执行'},
    {kind:'skip',value:'plan_skip',requires_input:'empty',label:'跳过'},
    {kind:'revise',value:'plan_revise',requires_input:'yes',label:'下一步'}];
  const planPayload={plan_approval_kind:'plan_approval',plan_content:'a plan',plan_actions:planActions,
    questions:[{question:'Execute?',options:[{label:'批准',value:'approve'},{label:'拒绝',value:'reject'}]}]};
  question('plan','confirm_interrupt',planPayload);
  await assert.rejects(m.answer('s','plan',[{question:'Execute?',selected_options:['approve']}]),/计划操作/);
  await assert.rejects(m.answer('s','plan',[{question:'Execute?',selected_options:['plan_revise'],custom_input:' '}]),/修改意见/);
  const plan=m.answer('s','plan',[{question:'Execute?',selected_options:['plan_execute']}]); const resume=w.sent.at(-1); const count=w.sent.length;
  w.emit('chat.processing_status',{session_id:'s',request_id:resume.id,is_processing:false});
  assert.equal(w.sent.length,count,'no execution before successful reply');
  w.reply(resume); await plan;
  assert.equal(w.sent.length,count+1,'completion before ACK still starts approved plan exactly once');
  assert.equal(w.sent.at(-1).params.mode,'agent.work.normal'); w.reply(w.sent.at(-1)); await tick();
  session.mode.style='plan';question('skip','confirm_interrupt',planPayload);
  const skip=m.answer('s','skip',[{question:'Execute?',selected_options:['plan_skip']}]);const skipReq=w.sent.at(-1);w.reply(skipReq);await skip;
  const skipCount=w.sent.length;w.emit('chat.processing_status',{session_id:'s',request_id:skipReq.id,is_processing:false});
  assert.equal(w.sent.length,skipCount);assert.equal(session.mode.style,'plan');assert.equal(session.state,'idle');
  question('revise','confirm_interrupt',planPayload);
  const revise=m.answer('s','revise',[{question:'Execute?',selected_options:['plan_revise'],custom_input:'Only output text'}]);
  const reviseReq=w.sent.at(-1);assert.equal(reviseReq.params.answers[0].custom_input,'Only output text');w.reply(reviseReq);await revise;
  assert.equal(session.mode.style,'plan');
  w.emit('chat.processing_status',{session_id:'s',request_id:reviseReq.id,is_processing:false});
  question('cancel-plan','confirm_interrupt',planPayload);
  const pendingPlan=m.answer('s','cancel-plan',[{question:'Execute?',selected_options:['plan_execute']}]);const pendingReq=w.sent.at(-1);w.reply(pendingReq);await pendingPlan;
  const stop=m.stop();const stopReq=w.sent.at(-1);w.reply(stopReq);await stop;w.emit('chat.interrupt_result',{session_id:'s',request_id:stopReq.id,success:true});
  const stopCount=w.sent.length;w.emit('chat.processing_status',{session_id:'s',request_id:pendingReq.id,is_processing:false});assert.equal(w.sent.length,stopCount,'stop cancels deferred Plan execution');
  question('fail','confirm_interrupt'); const failed=m.answer('s','fail',[{question:'Choose?',selected_options:['deny']}]); w.reply(w.sent.at(-1),false); await failed;
  assert.equal(session.rich.interactions.get('fail').interaction.status,'failed');
  const uncertain=m.answer('s','fail',[{question:'Choose?',selected_options:['deny']}]); m.connection.close(); await uncertain;
  assert.equal(session.disposed,true); assert.equal(session.rich.interactions.size,0);
  assert.equal(session.timeline().length,0); assert.equal(m.current(),undefined);
  await assert.rejects(m.answer('s','fail',[{question:'Choose?',selected_options:['allow']}]),/已提交或已失效/);
  m.dispose(); console.log('PASS rich timeline, tool correlation/collapse, body segmentation, unknown events, attachment sources, Markdown, question routing, runtime receipts, queue isolation, Plan ACK race, rejection and uncertain delivery');
}
main().catch(e=>{console.error(e);process.exitCode=1;});
