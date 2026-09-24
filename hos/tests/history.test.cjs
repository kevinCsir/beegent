const assert=require('node:assert/strict');
const {load}=require('./core.test.cjs');
const {SwarmManager}=load('SwarmManager');
class Wire {
  sent=[]; onText=()=>{}; onClosed=()=>{}; async open(){} close(){} async send(s){this.sent.push(JSON.parse(s));}
  reply(req,payload){this.onText(JSON.stringify({type:'res',id:req.id,ok:true,payload}));}
  emit(req,payload){this.onText(JSON.stringify({type:'event',event:'history.message',payload:{session_id:req.params.session_id,request_id:req.id,cursor:req.params.cursor,...payload}}));}
}
const tick=()=>new Promise(r=>setImmediate(r));
async function main(){
 const w=new Wire(),m=new SwarmManager(()=>w); await m.connect('127.0.0.1');
 const listing=m.listSessions(); w.reply(w.sent.at(-1),{sessions:[{session_id:'s',title:'原有会话',mode:'agent.code.plan'}],total:1}); await listing;
 assert.equal(m.remoteSessions[0].title,'原有会话');
 const opening=m.openSession(m.remoteSessions[0]); w.reply(w.sent.at(-1),{session_id:'s',title:'原有会话',mode:'agent.code.plan',is_processing:false}); await tick();
 let req=w.sent.at(-1); assert.equal(req.method,'history.get'); assert.equal(req.params.cursor,null); w.reply(req,{accepted:true});
 w.emit(req,{session_id:'other',message:{role:'user',content:'wrong'}});
 w.emit(req,{message:{id:'u',request_id:'r',role:'user',content:'hello',timestamp:1}});
 const record={id:'a',request_id:'r',role:'assistant',event_type:'chat.final',timestamp:2};
 w.emit(req,{message:{...record,content:'world',_part:{record_id:'a',part_idx:1,total_parts:2}}});
 w.emit(req,{message:{...record,content:'hello ',_part:{record_id:'a',part_idx:0,total_parts:2}}});
 w.emit(req,{message:{role:'assistant',event_type:'context.usage',content:'',timestamp:3,usage:{tokens:123}}});
 w.emit(req,{status:'done',has_more:true,next_cursor:'older',snapshot_id:'snapshot',snapshot_end:30}); await opening;
 const s=m.current(); assert.equal(s.mode.wire(),'agent.code.plan'); assert.deepEqual(s.timeline().map(x=>x.text),['hello','hello world']); assert.equal(s.historyLoading,false);
 const older=m.olderHistory(); w.reply(w.sent.at(-1),{session_id:'s',is_processing:false}); await tick(); req=w.sent.at(-1); assert.equal(req.params.cursor,'older'); w.reply(req,{accepted:true});
 w.emit(req,{message:{id:'old',request_id:'old',role:'user',content:'older message',timestamp:0.1}});
 w.emit(req,{status:'done',has_more:false,next_cursor:null,snapshot_id:'snapshot',snapshot_end:30}); await older;
 assert.equal(s.timeline()[0].text,'older message'); assert.equal(s.historyCursor,null);
 s.begin('new','live'); s.apply({type:'event',event:'chat.final',payload:{request_id:'new',content:'answer'}}); s.flush();
 assert.equal(s.timeline().at(-1).text,'answer'); assert.equal(s.timeline()[0].text,'older message');
 s.state='idle';
 const refreshed=m.openSession({session_id:'s'}); w.reply(w.sent.at(-1),{session_id:'s',is_processing:false}); await tick(); req=w.sent.at(-1); w.reply(req,{accepted:true});
 w.emit(req,{message:{id:'server',request_id:'new',role:'assistant',event_type:'chat.final',content:'server truth',timestamp:20}});
 w.emit(req,{status:'done',has_more:false,next_cursor:null,snapshot_id:'new-snapshot',snapshot_end:100}); await refreshed;
 assert.equal(s.timeline().length,0); assert.equal(s.disposed,true); assert.notEqual(s,m.current());
 assert.deepEqual(m.current().timeline().map(x=>x.text),['server truth'],'reopened idle session uses server snapshot rather than local transcript');
 const reload=m.openSession({session_id:'s'}); w.reply(w.sent.at(-1),{session_id:'s'}); await tick(); req=w.sent.at(-1); w.reply(req,{accepted:true});
 m.connection.close(); await reload; assert.equal(m.remoteSessions.length,0); assert.equal(s.historyLoading,false);
 w.emit(req,{message:{role:'user',content:'late',timestamp:10}}); assert.ok(!s.timeline().some(x=>x.text==='late'));
 await m.connect('127.0.0.1'); assert.equal(m.current(),undefined); assert.equal(m.sessions.length,0);
 const lateList=m.listSessions(); const lateReq=w.sent.at(-1); m.clearList();
 w.reply(lateReq,{sessions:[{session_id:'late-list'}],total:1}); await lateList;
 assert.equal(m.remoteSessions.length,0,'closed drawer cannot be repopulated by late response');
 await m.connect('127.0.0.2'); assert.equal(m.sessions.length,0); assert.equal(m.current(),undefined);
 m.dispose(); console.log('PASS server list, history correlation, split assembly, pagination, mode restore, usage hiding, live append, disconnect and endpoint isolation');
}
main().catch(e=>{console.error(e);process.exitCode=1});

