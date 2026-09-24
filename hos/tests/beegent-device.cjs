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
function layout(label = 'layout') {
  const name = `${++step}-${label}.json`;
  const remote = `/data/local/tmp/jwb-${runId}-${step}.json`;
  hdc(['shell','uitest','dumpLayout','-b',app.bundleName,'-p',remote]);
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
async function main() {
  const before=layout('home'); assert.ok(find(before,'sidebar-toggle'));
  click(find(before,'connection-panel-toggle')); await sleep(350);
  assert.ok(find(layout('connection-dialog'),'connection-dialog')); capture(); fs.copyFileSync(path.join(out,'screen.png'),path.join(out,'connection.png'));
  click(find(layout(),'connect-button'));
  await waitFor(list=>!find(list,'connection-dialog'),'connected',30000);
  click(find(layout(),'sidebar-toggle'));
  const loaded=await waitFor(list=>list.some(n=>idOf(n).startsWith('remote-session-')&&idOf(n)!=='remote-session-list'),'sessions',30000);
  capture(); fs.copyFileSync(path.join(out,'screen.png'),path.join(out,'sidebar.png'));
  const first=loaded.find(n=>idOf(n).startsWith('remote-session-')&&idOf(n)!=='remote-session-list'); click(first);
  await waitFor(list=>!!find(list,'message-list'),'history',30000);
  await sleep(700); capture(); fs.copyFileSync(path.join(out,'screen.png'),path.join(out,'history.png'));
  console.log('PASS beegent connection dialog, real LAN connection, server session sidebar and history display; no chat sent');
}
main().catch(error=>{try{capture();}catch(_){} console.error(error.message);process.exitCode=1;});
