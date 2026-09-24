// Deterministic protocol fixture. Loopback only; never invokes a model or executes tools.
const http=require('node:http');
const {WebSocketServer}=require((process.env.DEVECO_STUDIO_HOME||'C:/Program Files/Huawei/DevEco Studio')+'/tools/hvigor/hvigor/node_modules/ws');
const fs=require('node:fs');
const port=Number(process.env.JWB_FIXTURE_PORT||19095);
const events=[]; let session=0;
const server=http.createServer((req,res)=>{
  if(req.url==='/report.txt'){res.writeHead(200,{'Content-Type':'text/plain','Content-Length':25});res.end('JiuWenBridge file fixture.');events.push({download:true});return;}
  if(req.url==='/evidence'){res.setHeader('Content-Type','application/json');res.end(JSON.stringify(events));return;}
  res.writeHead(404);res.end();
});
const wss=new WebSocketServer({server});
wss.on('connection',ws=>ws.on('message',buffer=>{
  const req=JSON.parse(buffer);events.push(req);
  if(req.method==='session.create'){ws.send(JSON.stringify({type:'res',id:req.id,ok:true,payload:{session_id:'fixture-'+(++session)}}));return;}
  ws.send(JSON.stringify({type:'res',id:req.id,ok:true,payload:{accepted:true}}));
  const sid=req.params.session_id;
  const emit=(event,payload={})=>ws.send(JSON.stringify({type:'event',event,payload:{session_id:sid,request_id:req.id,...payload}}));
  if(req.params.answers){
    emit('runtime.accepted');emit('chat.final',{content:'**REPLY-ACCEPTED**\n\n服务器已收到你的结构化回复。'});emit('chat.processing_status',{is_processing:false});return;
  }
  if(req.method==='chat.interrupt'){emit('chat.interrupt_result',{success:true});return;}
  if(req.method!=='chat.send')return;
  const text=req.params.content||'';emit('chat.processing_status',{is_processing:true});
  if(text.includes('question')){
    emit('chat.ask_user_question',{request_id:'fixture-question-'+session,source:'permission_interrupt',questions:[{question:'测试审批，不会执行任何操作。是否允许？',options:[{label:'允许',value:'allow'},{label:'拒绝',value:'deny'}],card_id:'fixture-card'}]});return;
  }
  if(text.includes('file')){
    emit('chat.file',{files:[{name:'report.txt',mime_type:'text/plain',download_url:'/report.txt',size:25}]});
  }else if(text.includes('base64')){
    emit('chat.media',{media_items:[{filename:'inline.txt',mime_type:'text/plain',base64_data:Buffer.from('Inline base64 fixture.').toString('base64')}]});
  }else if(text.includes('unknown')){
    emit('chat.future_widget',{content:'FALLBACK-VISIBLE'});
  }else{
    emit('chat.reasoning',{content:'这是测试思考过程。'});emit('chat.tool_call',{tool_call:{id:'tool-'+req.id,name:'读取测试信息',arguments:'不访问真实文件'}});
    emit('chat.tool_result',{tool_result:{tool_call_id:'tool-'+req.id,result:'测试工具已完成',success:true}});
    emit('chat.final',{content:'# Markdown 测试\n\n这是 **加粗**、*斜体* 和 `行内代码`。\n\n- 第一项\n- 第二项\n\n> 引用内容\n\n```typescript\nconst message = "HELLO";\n```\n\n[示例链接](https://example.com)'});
  }
  emit('chat.processing_status',{is_processing:false});
}));
server.listen(port,'127.0.0.1',()=>console.log('FIXTURE_READY '+port));
const deadline=setTimeout(()=>{wss.clients.forEach(ws=>ws.terminate());server.close();},10*60*1000);
process.on('SIGTERM',()=>{clearTimeout(deadline);wss.clients.forEach(ws=>ws.terminate());server.close();});
