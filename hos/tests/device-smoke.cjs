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
  if (mode === 'install') {
    const hap = path.join(repo,'entry/build/default/outputs/default/entry-default-signed.hap');
    const result = hdc(['install','-r',hap],90000);
    fs.writeFileSync(path.join(out,'install.txt'),result);
    assert.match(result,/success/i); assert.doesNotMatch(result,/failed/i);
    const start = hdc(['shell','aa','start','-a',mod.mainElement,'-b',app.bundleName]);
    assert.match(start,/start ability successfully/i);
    const pid = hdc(['shell','pidof',app.bundleName]).trim(); assert.match(pid,/\d+/);
    fs.writeFileSync(path.join(out,'pid.txt'),pid);
    await sleep(1800); capture(); console.log('PASS: install, launch and PID.');
  } else if (mode === 'restore-address') {
    let list=layout();
    if (!find(list,'server-address')) { click(find(list,'connection-panel-toggle')); list=layout(); }
    if (String(find(list,'connect-button')?.text)==='断开') { click(find(list,'connect-button')); await sleep(300); }
    if (!process.env.JWB_SERVER) throw Error('Set JWB_SERVER');
    await input('server-address',process.env.JWB_SERVER); capture();
    console.log('PASS restored editable LAN address, disconnected');
  } else if (mode === 'modes') {
    if (process.env.JWB_SERVER) await input('server-address',process.env.JWB_SERVER);
    click(find(layout(),'connect-button'));
    await waitFor(list=>!!find(list,'create-confirm'),'create-options',30000);
    click(find(layout(),'mode-team')); click(find(layout(),'mode-code')); click(find(layout(),'mode-plan'));
    let list=layout('selected-options');
    assert.match(find(list,'selected-mode').text,/Team.*代码项目.*计划优先/);
    capture(); fs.copyFileSync(path.join(out,'screen.png'),path.join(out,'mode-picker.png'));
    click(find(list,'create-confirm'));
    await waitFor(list=>String(find(list,'session-mode')?.text).includes('Team'),'team-created',30000);
    click(find(layout(),'new-session'));
    click(find(layout(),'mode-agent')); click(find(layout(),'mode-work')); click(find(layout(),'mode-normal'));
    click(find(layout(),'create-confirm'));
    await waitFor(list=>String(find(list,'session-mode')?.text).includes('单 Agent'),'agent-created',30000);
    capture(); console.log('PASS connection, three mode selectors, team.code.plan and agent.work.normal creation; endpoint '+(process.env.JWB_SERVER || 'configured LAN default'));
  } else if (mode === 'queue') {
    await input('message-input','JiuWenBridge QA. No tools, no files. Write 1000 numbered long sentences about clouds. Start directly.');
    click(find(layout(),'send-button'));
    await waitFor(list=>!!find(list,'stop-button'),'running',20000);
    await input('message-input','JiuWenBridge QA. Focus on white clouds. Do not use tools.');
    click(find(layout(),'send-button'));
    await waitFor(list=>!!find(list,'queue-panel'),'queue-visible',15000);
    capture(); fs.copyFileSync(path.join(out,'screen.png'),path.join(out,'queue-visible.png'));
    const list=layout('supplement-button'); const steer=list.find(n=>idOf(n).startsWith('queue-steer-'));
    assert.ok(steer); assert.equal(String(steer.enabled),'true'); click(steer);
    await waitFor(list=>!find(list,'queue-panel'),'supplement-accepted',30000);
    click(find(layout(),'stop-button'));
    await waitFor(list=>!find(list,'stop-button'),'stopped',20000);
    capture(); console.log('PASS busy composer, local queue, steering action and stop on real device');
  } else if (mode === 'chat') {
    const started = hdc(['shell','aa','start','-a',mod.mainElement,'-b',app.bundleName]);
    assert.match(started,/start ability successfully/i);
    await sleep(1000);
    if (!process.env.JWB_SERVER) throw Error('Set JWB_SERVER to the computer LAN endpoint');
    await input('server-address',process.env.JWB_SERVER);
    click(find(layout(),'connect-button'));
    await waitFor(list=>!!find(list,'create-confirm'),'create-options',30000);
    click(find(layout(),'create-confirm'));
    await waitFor(list=>list.some(n=>idOf(n).startsWith('session-') && idOf(n)!=='session-notice'),'session-created',30000);
    await input('message-input','JiuWenBridge QA. Reply with PHONE-OK only. Do not use tools.');
    click(find(layout(),'send-button'));
    await waitFor(list=>list.some(n=>idOf(n).startsWith('message-') && idOf(n).includes(':') && String(n.text).includes('PHONE-OK')) && !!find(list,'send-button'),'reply-complete');
    capture(); console.log('PASS: LAN connection, server session creation, phone message/reply.');
  } else if (mode === 'capture') { capture(); }
  else throw Error('Unknown case');
}
main().catch(error=>{try{capture();}catch(_){} console.error(error.message);process.exitCode=1;});
