#!/usr/bin/env node
'use strict';

// Package the maintained Skill and its script into one document for WorkSwarm.
// This only writes Markdown; it never starts a relay or connects to a backend.
const fs = require('node:fs');
const path = require('node:path');
const skillDir = path.join(__dirname, 'beegent-lan-relay');
const normalize = text => text.replace(/\r\n/g, '\n').trimEnd();
const instructions = normalize(fs.readFileSync(path.join(skillDir, 'SKILL.md'), 'utf8'));
const code = normalize(fs.readFileSync(path.join(skillDir, 'scripts', 'lan_relay.cjs'), 'utf8'));
const output = path.join(__dirname, 'beegent-lan-relay.md');
const document = instructions + '\n\n## 完整代码：scripts/lan_relay.cjs\n\n'
  + '将下面完整代码块保存为前文说明的脚本文件。此单文件由 `build-single-file.cjs` 生成；维护时修改多文件目录后重新生成。\n\n'
  + '```javascript\n' + code + '\n```\n';
fs.writeFileSync(output, document, 'utf8');
process.stdout.write(`Generated: ${output}\n`);
