// Device smoke runner. Run each case through the external supervisor.
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const assert = require('node:assert/strict');
const mode = process.argv[2];
const target = process.env.JWB_DEVICE;
const out = process.env.JWB_TEST_OUT;
const hdcPath = process.env.JWB_HDC || 'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe';
const repo = path.resolve(__dirname, '..');
const app = JSON.parse(fs.readFileSync(path.join(repo,'AppScope/app.json5'),'utf8')).app;
const mod = JSON.parse(fs.readFileSync(path.join(repo,'entry/src/main/module.json5'),'utf8')).module;
if (!target || !out) throw Error('Set JWB_DEVICE and JWB_TEST_OUT');
fs.mkdirSync(out, { recursive: true });
const runId = Date.now().toString(36);
function hdc(args, timeout = 12000) {
  return execFileSync(hdcPath, ['-t', target, ...args], { encoding: 'utf8', timeout, windowsHide: true });
}
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
function nodes(root) {
  const result = [];
  function visit(value) {
    if (!value || typeof value !== 'object') return;
    if (value.attributes) result.push(value.attributes);
    for (const [key, child] of Object.entries(value)) if (key !== 'attributes') visit(child);
  }
  visit(root); return result;
}
let step = 0;
function layout(label = 'layout', all = false) {
  const name = `${++step}-${label}.json`;
  const remote = `/data/local/tmp/jwb-${runId}-${step}.json`;
  hdc(['shell','uitest','dumpLayout',...(all ? [] : ['-b',app.bundleName]),'-p',remote]);
  const local = path.join(out,name);
  hdc(['file','recv',remote,local]);
  hdc(['shell','rm',remote]);
  return nodes(JSON.parse(fs.readFileSync(local,'utf8')));
}
function idOf(node) { return node.id || node.resourceId || ''; }
function find(list, id) { return list.find(node => idOf(node) === id); }
function center(node) {
  if (!node) throw Error('Control missing');
  const values = String(node.bounds).match(/-?\d+/g)?.map(Number);
  if (!values || values.length !== 4) throw Error('Invalid bounds');
  return [Math.round((values[0]+values[2])/2),Math.round((values[1]+values[3])/2)].map(String);
}
function click(node) { hdc(['shell','uitest','uiInput','click',...center(node)]); }
async function input(id, text) {
  let control = find(layout('before-input'), id); assert.ok(control, id);
  click(control);
  hdc(['shell','uitest','uiInput','keyEvent','2072','2017']);
  hdc(['shell','uitest','uiInput','keyEvent','2055']);
  control = find(layout('focused-input'), id);
  hdc(['shell','uitest','uiInput','inputText',...center(control),text]);
  await sleep(350);
  const after = find(layout('after-input'), id);
  assert.ok(after?.text?.includes(text), 'Input text entered correctly');
  hdc(['shell','uitest','uiInput','keyEvent','Back']);
  await sleep(400);
}
async function waitFor(predicate, label, timeout = 65000) {
  const started = Date.now();
  while (Date.now()-started < timeout) {
    const list = layout(label);
    if (predicate(list)) return list;
    const error = find(list,'connection-error');
    if (error?.text) throw Error(error.text);
    await sleep(800);
  }
  throw Error('Timed out waiting for '+label);
}
function capture() {
  const remote = `/data/local/tmp/jwb-${runId}.png`;
  hdc(['shell','uitest','screenCap','-p',remote]);
  hdc(['file','recv',remote,path.join(out,'screen.png')]);
  hdc(['shell','rm',remote]);
  layout('final');
}
function screenshot(name) { capture(); fs.copyFileSync(path.join(out,'screen.png'),path.join(out,name+'.png')); }
async function send(text) { await input('message-input',text); click(find(layout(),'send-button')); await sleep(600); }
async function main() {
  if(mode==='rich'||mode==='files') {
    let initial=layout();
    if(!find(initial,'server-address')) { click(find(initial,'connection-panel-toggle')); initial=layout(); }
    if(String(find(initial,'connect-button')?.text)==='断开') { click(find(initial,'connect-button')); await sleep(300); }
    await input('server-address',process.env.JWB_SERVER);
    click(find(layout(),'connect-button'));
    await waitFor(list=>!!find(list,'create-confirm'),'create',20000);
    click(find(layout(),'create-confirm'));
    await waitFor(list=>!!find(list,'message-input'),'ready',20000);
    if(mode==='files') { await send('file'); await waitFor(list=>!!find(list,'attachment-share'),'attachment',10000); screenshot('attachment'); return; }
    await send('markdown');
    await waitFor(list=>list.some(n=>String(n.text).includes('Markdown 测试')),'markdown',10000);
    screenshot('markdown');
    let list=layout(); const toggle=find(list,'steps-toggle');
    if(toggle) { click(toggle); screenshot('expanded-steps'); click(find(layout(),'steps-toggle')); }
    await send('question');
    await waitFor(list=>!!find(list,'question-submit'),'question',10000);
    list=layout(); const deny=list.find(n=>String(n.text).includes('○ 拒绝')); assert.ok(deny,'deny option');click(deny);
    click(find(layout(),'question-submit'));
    await waitFor(list=>list.some(n=>String(n.text).includes('REPLY-ACCEPTED')),'answer-received',12000);
    screenshot('question-answered');
    await send('unknown');
    await waitFor(list=>list.some(n=>String(n.text).includes('FALLBACK-VISIBLE')),'fallback',10000);
    screenshot('fallback');
    await send('file');
    await waitFor(list=>!!find(list,'attachment-share'),'attachment',10000);
    screenshot('attachment');
    console.log('PASS native Markdown, steps, permission rejection response, fallback and attachment card');
  } else if(mode==='share'||mode==='open'||mode==='save') {
    click(layout().filter(n=>idOf(n)==='attachment-'+mode).at(-1)); await sleep(2400);
    layout('system-'+mode,true); screenshot('system-'+mode);
    const errors=find(layout(),'connection-error'); if(errors?.text)throw Error(errors.text);
    console.log('SYSTEM_PANEL '+mode+' captured; inspect global layout');
  } else if(mode==='file') { await send('file'); screenshot('file');
  } else if(mode==='back') {
    hdc(['shell','uitest','uiInput','keyEvent','Back']);await sleep(500);screenshot('back');
  } else if(mode==='base64') {
    await send('base64');await waitFor(list=>list.some(n=>String(n.text).includes('inline.txt')),'base64-card',10000);screenshot('base64');
  } else throw Error('Unknown mode');
}
main().catch(error=>{try{capture();}catch(_){}console.error(error.stack);process.exitCode=1;});