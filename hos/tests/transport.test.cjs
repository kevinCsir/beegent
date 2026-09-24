const assert=require('node:assert/strict');
const fs=require('node:fs'); const path=require('node:path'); const vm=require('node:vm');
const ts=require('C:/Program Files/Huawei/DevEco Studio/tools/hvigor/hvigor/node_modules/typescript');
const listeners=new Map(); const socket={on:(type,fn)=>listeners.set(type,fn),connect:async()=>true,close:async()=>true,send:async()=>true};
const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/swarm/HarmonyTransport.ets'),'utf8');
const js=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS}}).outputText;
const mod={exports:{}};
vm.runInThisContext('(function(require,module,exports){'+js+'\n})')(name=>name==='@kit.NetworkKit'?{webSocket:{createWebSocket:()=>socket}}:name==='../diagnostics/CommunicationLog'?{CommunicationLog:{record:()=>{}}}:{},mod,mod.exports);
async function main(){
 const t=new mod.exports.HarmonyTransport(); let opened=false;
 const pending=t.open('ws://test').then(()=>{opened=true;});
 await new Promise(r=>setTimeout(r,0)); assert.equal(opened,false,'initiation is not connection');
 listeners.get('open')(undefined,{}); await pending; assert.equal(opened,true);
 const failed=t.open('ws://test'); listeners.get('error')({code:123}); await assert.rejects(failed,/123/);
 const closed=t.open('ws://test'); t.close(); await assert.rejects(closed,/关闭/);
 console.log('PASS Harmony transport waits for open and rejects pre-handshake error/close');
}
main().catch(e=>{console.error(e);process.exitCode=1;});
